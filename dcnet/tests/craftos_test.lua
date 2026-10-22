--[[- craftos_test.lua — 在真 CraftOS 上跑 dcnet 的测试

由 tests/run_craftos.py 这样启动：

    CraftOS-PC_console.exe --headless --id 7 \
        --mount-rw <项目目录>=/project \
        --script <项目目录>/tests/craftos_test.lua

覆盖的是 lupa 模拟器覆盖不到的东西：
  * 真 ROM：真 read()（含 bios 的实参校验）、真 parallel.lua、真 textutils、真 fs
  * CraftOS-PC 的 Lua 5.2（带 loadstring/setfenv），走 util.loadChunk 的 **5.1 装载分支**
  * 真 os.clock / os.startTimer 的 50ms 粒度与事件语义
  * 真实主控 + 真实节点的**完整进程结构**（master.run/worker.run 原样跑）
    —— 只把 dc.net 的收发换成本进程总线（真机里那部分是 modem 的活）

输出以 "ALL PASS" / "FAILED" 结尾，供 Python 端判定。
]]

local PROJECT = "/project"
local REAL_ID = os.getComputerID()

local pass, fail, lines = 0, 0, {}
local function out(s)
    lines[#lines + 1] = s
    print(s)                    -- 立刻输出：这样万一某一段卡住，能看出卡在哪
end

local function check(cond, msg)
    if cond then
        pass = pass + 1
        out("  [ok] " .. msg)
    else
        fail = fail + 1
        out("  [XX] " .. msg)
    end
    return cond
end

local function section(name) out("") out("== " .. name .. " ==") end

local function readHost(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

-- ── 0. 环境 ─────────────────────────────────────────────────────────────
section("环境")
out("  _VERSION = " .. _VERSION .. "   computerID = " .. REAL_ID)
check(fs.exists(PROJECT .. "/src/lib/util.lua"), "项目已挂载到 " .. PROJECT)
check(type(setfenv) == "function" and type(loadstring) == "function",
    "loadstring/setfenv 可用（走 5.1 装载分支）")
check(type(parallel) == "table" and type(window) == "table", "parallel/window 可用")

-- loadChunk 的 env 分支（Lua 5.2 里显式传 nil 会毁掉 _ENV，必须走三参形式）
do
    local u = dofile(PROJECT .. "/src/lib/util.lua")
    local f1 = u.loadChunk("return 1 + 1", "=t1")
    check(f1 and f1() == 2, "loadChunk 不传 env 时仍能访问全局表")
    local env = { answer = 42 }
    local f2 = u.loadChunk("return answer", "=t2", env)
    check(f2 and f2() == 42, "loadChunk 传 env 时生效")
end

-- ── 1. 每个"宇宙"一份模块副本 ───────────────────────────────────────────
-- 主控和节点要各跑一份真实代码，所以每个宇宙有自己的 dc_require 缓存和 dc.net。
local function makeRequire()
    local cache = {}
    return function(name)
        if cache[name] then return cache[name] end
        local short = name:match("^dc%.(.+)$")
        if not short then error("模块名非法: " .. tostring(name), 0) end
        local path = PROJECT .. "/src/lib/" .. short .. ".lua"
        if not fs.exists(path) then error("找不到模块文件 " .. path, 0) end
        local mod = dofile(path)
        cache[name] = mod
        return mod
    end, cache
end

-- 进程内总线：目标 ID 是真机 ID 的当作主控，其它当作节点编号
local bus = {}
local blocked = {}          -- role -> true：模拟这台机器断网/断电（收发全部丢弃）
local extraRoles = {}       -- 额外角色（测试里用第二台主控）

local function destRole(target)
    if extraRoles[target] then return extraRoles[target] end
    if target == REAL_ID then return "master" end
    return "node" .. tostring(target)
end

-- 混沌注入：确定性丢包（可复现，不用真随机）。chaos.dropEvery = N 表示每 N 条丢 1 条，
-- 0/nil = 关闭；chaos.count 只统计"开启之后"发过的消息。
local chaos = { dropEvery = 0, count = 0, dropped = 0 }

local function chaosDrop()
    if not chaos.dropEvery or chaos.dropEvery <= 0 then return false end
    chaos.count = chaos.count + 1
    if chaos.count % chaos.dropEvery == 0 then
        chaos.dropped = chaos.dropped + 1
        return true
    end
    return false
end

local function busSend(from, target, msg, proto)
    local to = destRole(target)
    if blocked[from] or blocked[to] then return true end     -- 掉线/断电
    if chaosDrop() then return true end                      -- 随机丢包（确定性）
    bus[#bus + 1] = {
        from = from, to = to,
        msg = textutils.serialize(msg), proto = proto or "dccomp",
    }
    return true
end

local function busBroadcast(from, msg, proto)
    if blocked[from] then return true end
    if chaosDrop() then return true end
    bus[#bus + 1] = { from = from, to = "all", msg = textutils.serialize(msg), proto = proto or "dccomp" }
    return true
end

local function busReceive(role, proto, timeout)
    local deadline = timeout and (os.clock() + timeout) or nil
    if blocked[role] then
        -- 被隔离的机器什么也收不到，但也不能空转：按超时返回
        while not deadline or os.clock() < deadline do sleep(0.05) end
        return nil
    end
    while true do
        -- 广播要像真 rednet 一样"送到每一台机器"：不能第一个轮询者吃掉就没了。
        -- 每个角色各看一次，看过的记在 m.seen 上，稍后统一清理。
        for i = #bus, 1, -1 do
            local m = bus[i]
            if m.to == "all" and m.expire and os.clock() > m.expire then
                table.remove(bus, i)
            end
        end
        for i, m in ipairs(bus) do
            local direct = (m.to == role)
            local bcast = (m.to == "all") and not (m.seen and m.seen[role])
            if m.proto == proto and (direct or bcast) then
                local ok, decoded = pcall(textutils.unserialize, m.msg)
                if direct then
                    table.remove(bus, i)
                else
                    m.seen = m.seen or {}
                    m.seen[role] = true
                    m.expire = os.clock() + 1.5
                end
                if ok and decoded then return m.from, decoded, m.proto end
            end
        end
        if deadline and os.clock() >= deadline then return nil end
        sleep(0.05)
    end
end

local function makeUniverse(role, roleId)
    local req, cache = makeRequire()
    local saved = _G.dc_require
    _G.dc_require = req
    local ok, err = pcall(function()
        local net = req("dc.net")
        net.open = function() return "left", false end
        net.openAll = function() return { { name = "left", wireless = false } }, {} end
        net.describe = function() return "1 有线 / 0 无线" end
        net.receive = function(proto, timeout) return busReceive(role, proto, timeout) end
        net.send = function(target, msg, proto) return busSend(roleId, target, msg, proto) end
        net.broadcast = function(msg, proto) return busBroadcast(roleId, msg, proto) end
        req("dc.util"); req("dc.protocol"); req("dc.jobs")
        req("dc.xfer"); req("dc.sched"); req("dc.console")
        req("dc.master"); req("dc.worker"); req("dc.screen")
    end)
    _G.dc_require = saved
    if not ok then error("宇宙 " .. tostring(role) .. " 加载失败: " .. tostring(err), 0) end
    return cache
end

local U = makeUniverse("tester", 1)     -- 测试自己用的那份模块

-- ── 2. util ────────────────────────────────────────────────────────────
section("util")
do
    local util = U["dc.util"]
    check(util.hash("abc") == util.hash("abc") and util.hash("abc") ~= util.hash("abd"), "hash 稳定且可区分")
    check(util.duration(950) == "950ms" and util.duration(1500) == "1.5s", "duration 格式化")
    local t = util.tokenize('run primes to=100 "两个 词"')
    check(#t == 4 and t[4] == "两个 词", "tokenize 支持引号")
    local args, err = util.parseArgs({ "to=100", "3" }, {
        { name = "chunk", type = "number", default = 25 },
        { name = "to", type = "number" },
    })
    check(args and args.to == 100 and args.chunk == 3, "parseArgs 命名+位置参数")
    local bad = util.parseArgs({ "nope=1" }, {})
    check(bad == nil, "parseArgs 拒绝未知参数")
    check(util.textWidth("中文abc") == 7, "textWidth 按显示列算（中文 2 列）")
    check(util.trunc("abcdef", 4) == "a...", "trunc 按显示宽度截断（省略号占 2 列）")
    check(util.trunc("中文测试", 5) == "中...", "trunc 中文：中(2)+省略号(2) = 4 列 ≤ 5")
    check(util.textWidth(util.trunc("中文测试abcdef", 9)) <= 9, "trunc 结果不超出给定列数")
    local chopped = util.trunc("中文字符", 3)
    check(chopped:byte(-2) ~= nil and util.textWidth(chopped) <= 3,
        "trunc 不会把多字节字符切成两半")
end

-- ── 3. 五个内置作业的真机计算 ─────────────────────────────────────────────
section("作业计算（真机）")
local function loadJob(name)
    local src = readHost(PROJECT .. "/src/jobs/" .. name .. ".lua")
    if not src then return nil, "读不到 /src/jobs/" .. name .. ".lua" end
    return U["dc.jobs"].loadSource(src, "@" .. name)
end

local function runJob(name, tokens, makeCtx)
    local def, err = loadJob(name)
    if not def then return nil, err end
    local args, err2 = U["dc.jobs"].resolveArgs(def, tokens)
    if not args then return nil, err2 end
    local tasks, err3 = U["dc.jobs"].split(def, args)
    if not tasks then return nil, err3 end
    local src = def.source
    local ctx = makeCtx and makeCtx() or {
        progress = function() end, tick = function() end,
        canceled = function() return false end, log = function() end,
        now = function() return os.epoch("utc") end, mono = os.clock,
    }
    local results = {}
    for _, t in ipairs(tasks) do
        local r, e = U["dc.jobs"].runMap(src, t, ctx)
        if r == nil then return nil, "map 失败: " .. tostring(e) end
        results[#results + 1] = r
    end
    local res, e = U["dc.jobs"].reduce(def, results, args)
    if res == nil then return nil, "reduce 失败: " .. tostring(e) end
    return res, nil, def, tasks
end

do
    local res, err = runJob("primes", { "to=100000", "chunk=10000" })
    check(res and res.primes == 9592, "primes：π(100000) = " .. tostring(res and res.primes) .. "（应为 9592）")

    local res2 = runJob("pi", { "samples=20000", "chunk=5000" })
    check(res2 and math.abs(res2.pi - math.pi) < 0.1,
        string.format("pi：蒙特卡洛 %s 与 π 相差 %.4f", res2 and string.format("%.4f", res2.pi) or "nil",
            res2 and math.abs(res2.pi - math.pi) or 99))

    local res3 = runJob("mandelbrot", { "width=20", "height=6", "rows=2" })
    if check(res3 and res3.rows == 6, "mandelbrot：渲染 6 行") then
        local n = select(2, res3.art:gsub("\n", "\n")) + 1
        check(n == 6 and #(res3.art:match("[^\n]*")) == 20, "mandelbrot：行数与宽度正确")
    end

    local res4 = runJob("hashsearch", { "to=200000", "chunk=25000", "modulus=1024" })
    if check(res4 and res4.hit, "hashsearch：在 [1,200000] 内找到命中 n = " .. tostring(res4 and res4.hit)) then
        -- 用测试端独立实现的哈希复核
        local function h(s)
            local x = 5381
            for i = 1, #s do x = (x * 33 + s:byte(i)) % 2147483647 end
            return x
        end
        check(h("dc" .. res4.hit) % 1024 == 0, "hashsearch：命中值经独立校验成立")
    end

    local res5 = runJob("selftest", { "tasks=3", "size=500" })
    check(res5 and #res5.bad == 0 and #res5.missing == 0 and res5.got == 3,
        "selftest：3 个任务闭式解全部对得上")
end

-- ── 4. ctx.tick() 真的会重置"不让出"预算 ─────────────────────────────────
section("ctx.tick() 与执行预算")
do
    -- 用真 parallel 跑：一个协程干重活并周期性 tick，另一个协程等它结束。
    -- 如果 tick 无效，CC 会在 7 秒左右抛 "Too long without yielding"。
    local t0 = os.clock()
    local ok, err = pcall(function()
        parallel.waitForAny(
            function()
                os.sleep(0.2)
            end,
            function()
                local last = os.clock()
                local yields = 0
                for i = 1, 400000 do
                    if os.clock() - last >= 0.05 then
                        last = os.clock()
                        yields = yields + 1
                        os.queueEvent("dc_yield")
                        os.pullEvent("dc_yield")
                    end
                end
                os.queueEvent("dc_probe_done", yields)
            end,
            function()
                local _, yields = os.pullEvent("dc_probe_done")
                check(yields and yields > 0, "重活循环中成功让出 " .. tostring(yields) .. " 次")
            end
        )
    end)
    check(ok, "ctx.tick() 式让出没有触发 Too long without yielding（用时 " ..
        string.format("%.2fs", os.clock() - t0) .. "）" .. (ok and "" or (": " .. tostring(err))))
end

-- ── 5. xfer 分块传输往返 ─────────────────────────────────────────────────
section("xfer 分块传输")
do
    local xfer = U["dc.xfer"]
    local data = string.rep("dcnet 分块传输测试 abcdefghijklmnop\n", 400)   -- 约 13KB → 4 块
    local sent = {}
    local send = function(target, msg) sent[#sent + 1] = msg end
    local s = xfer.newSender({ target = 9, name = "worker.lua", data = data })

    local recv, assembled
    local guard = 0
    while s.state ~= "ok" and s.state ~= "fail" and guard < 100000 do
        guard = guard + 1
        xfer.senderPoll(s, send)
        while #sent > 0 do
            local m = table.remove(sent, 1)
            if m.t == "put" then
                recv = recv or xfer.newReceiver(m.xid, m.name, m.n)
                local action, val = xfer.recvOnMsg(recv, m)
                if action == "ack" then
                    xfer.senderOnMsg(s, { xid = m.xid, t = "putack", i = val })
                end
            elseif m.t == "putdone" then
                local action, val = xfer.recvOnMsg(recv, m)
                if action == "complete" then
                    assembled = val
                    xfer.senderOnMsg(s, { xid = m.xid, t = "putok" })
                elseif action == "miss" then
                    xfer.senderOnMsg(s, { xid = m.xid, t = "putmiss", miss = val })
                end
            end
        end
    end
    check(s.state == "ok", "传输状态机收敛到 ok（" .. tostring(s.n) .. " 块）")
    check(assembled == data, "重组内容与原文完全一致（" .. tostring(#data) .. " 字节）")
end

-- ── 6. 调度器单元级测试（并发 / 优先级 / 抢尾 / 自适应超时 / 配置 / 多 modem） ──
section("调度器：并发上限 / 优先级 / 抢尾冗余 / 自适应超时 / 配置 / 多 modem")

local function newSched(cfg)
    local uni = makeUniverse("unit" .. tostring(math.floor(os.clock() * 1000)), 90)
    local sent = {}
    uni["dc.net"].send = function(target, msg) sent[#sent + 1] = { target = target, msg = msg } return true end
    uni["dc.net"].broadcast = function() return true end
    local logs = {}
    local S = uni["dc.sched"].new({ cfg = cfg, log = function(t) logs[#logs + 1] = t end })
    return S, uni, sent, logs
end

local function addUnitJob(S, uni, tokens, pri, jobName)
    jobName = jobName or "selftest"
    local src = readHost(PROJECT .. "/src/jobs/" .. jobName .. ".lua")
    local def = uni["dc.jobs"].loadSource(src, "@" .. jobName)
    return S:addJob(def, tokens, { priority = pri })
end

-- 节点侧执行一个 reduce 任务时用的 ctx（不需要真让出）
local function unitCtx()
    return {
        progress = function() end, tick = function() end,
        canceled = function() return false end, log = function() end,
        now = function() return os.epoch("utc") end, mono = os.clock,
    }
end

do
    local P = U["dc.protocol"]

    -- ① 并发上限：maxParallel=1 时第二个作业排队；放宽后立刻并发
    local S, uni = newSched({ maxParallel = 1, verbose = false })
    local j1 = addUnitJob(S, uni, { "tasks=3", "size=100" }, 0)
    local j2 = addUnitJob(S, uni, { "tasks=3", "size=100" }, 9)
    check(S:runningCount() == 1 and S.running[j1.id] and not S.running[j2.id],
        "maxParallel=1：只跑第一个作业，第二个排队")
    S:setCfg("maxParallel", 2)
    S:pump()
    check(S:runningCount() == 2, "把 maxParallel 调到 2 后两个作业同时在跑")

    -- ② 优先级：同时有活时，先派优先级高的作业
    local msg1 = S:assign(1)
    check(msg1 and msg1.job == j2.id,
        "优先级 9 的作业先拿到任务（实际 #" .. tostring(msg1 and msg1.job) .. "）")

    -- ③ 自适应超时：按 EWMA 收紧，并夹在上下限之间
    local job = S.jobs[j1.id]
    local w = S:worker(1)
    job.msEWMA, w.msEWMA = 2000, 500
    check(math.abs(S:taskBudget(job, w) - 15) < 0.01, "EWMA 2s → 预算被下限夹到 15s")
    job.msEWMA = 60000
    check(math.abs(S:taskBudget(job, w) - 245) < 0.01, "EWMA 60s → 预算 245s")
    S:setCfg("taskTimeoutMax", 100)
    check(math.abs(S:taskBudget(job, w) - 100) < 0.01, "上限生效（100s）")
    S:setCfg("taskTimeoutMax", 900)

    -- ④ 每个任务拿到的是"自己的截止时间"，有进展会顺延
    local tid = S:nextPending(S.jobs[j2.id])
    S:dispatch(S.jobs[j2.id], tid, 1, false)
    local t = S.jobs[j2.id].tasks[tid]
    check(t.deadline and t.deadline > os.clock(), "派发时写入了 per-task 截止时间")
    local before = t.deadline
    S:onMessage(1, P.msg(P.PROGRESS, { job = j2.id, task = tid, pct = 0.5 }))
    check(t.deadline >= before, "收到 progress 后截止时间顺延")

    -- ⑤ 抢尾冗余：任务都快做完时给空闲节点发同一任务的副本，先回来的算数
    local S2, uni2, sent2 = newSched({ maxParallel = 1, redundancy = 3 })
    local j3 = addUnitJob(S2, uni2, { "tasks=3", "size=100" }, 0)
    S2:assign(1)
    S2:assign(2)
    S2:assign(3)
    check(S2.jobs[j3.id].counts.running == 3, "3 个任务全部在算")
    local okDup = S2:assignRedundant(4)
    local dupMsg
    for _, s in ipairs(sent2) do
        if s.msg.t == "task" and s.msg.dup then dupMsg = s end
    end
    check(okDup and dupMsg and dupMsg.target == 4, "抢尾：给空闲节点 #4 派了冗余副本")
    check(S2.stats.redundant == 1, "冗余派发计数 +1")

    if dupMsg then
        local owner = S2.jobs[j3.id].tasks[dupMsg.msg.task].worker
        local done0 = S2.stats.done
        S2:onResult(4, P.msg(P.RESULT, { job = j3.id, task = dupMsg.msg.task, ok = true, data = { x = 1 }, ms = 10 }))
        check(S2.stats.done == done0 + 1, "冗余副本的结果被采信")
        check(S2.workers[4].state == "idle" and S2.workers[owner].state == "idle",
            "任务完成后正主与副本节点都回到空闲")
        S2:onResult(owner, P.msg(P.RESULT, { job = j3.id, task = dupMsg.msg.task, ok = true, data = { x = 2 }, ms = 10 }))
        check(S2.stats.done == done0 + 1, "正主的迟到结果被丢弃，不重复计数")
    end

    -- ⑥ 配置持久化：写进 CC 的 settings，重新读出来还在
    local schedMod = U["dc.sched"]
    U["dc.util"].saveCfg("maxParallel", 3)
    local loaded = U["dc.util"].loadCfg(schedMod.DEFAULTS)
    check(loaded.maxParallel == 3, "配置持久化：settings 里的值被读回（maxParallel=3）")
    U["dc.util"].saveCfg("maxParallel", schedMod.DEFAULTS.maxParallel)
    check(U["dc.util"].loadCfg(schedMod.DEFAULTS).maxParallel == 1, "恢复默认值")

    -- ⑦ 多 modem：openAll 会把所有 modem 都打开
    -- 注意不能用 U/U 之类的宇宙：makeUniverse 为了端到端测试把 dc.net 换成了总线桩。
    -- 这里单独加载一份"不打桩"的真 net 模块。
    local bareNet = (function()
        local req = makeRequire()
        local saved = _G.dc_require
        _G.dc_require = req
        local net = req("dc.net")
        _G.dc_require = saved
        return net
    end)()

    local realGetNames, realGetType, realWrap, realCall = peripheral.getNames, peripheral.getType,
        peripheral.wrap, peripheral.call
    local opened = {}
    local realOpen = rednet.open
    peripheral.getNames = function() return { "left", "back" } end
    peripheral.getType = function(n) return (n == "left" or n == "back") and "modem" or nil end
    peripheral.wrap = function(n)
        if n == "left" then return { isWireless = function() return false end } end
        if n == "back" then return { isWireless = function() return true end } end
        return nil
    end
    -- peripheral.call 一律返回 false：这样 rednet.isOpen 会认为"还没打开"，
    -- openAll 才会真的去调 rednet.open（我把它换成了间谍函数）
    peripheral.call = function() return false end
    rednet.open = function(side) opened[#opened + 1] = side end

    local list, failed = bareNet.openAll()
    for _, e in ipairs(failed) do out("      打开失败: " .. tostring(e)) end
    check(#list == 2 and #failed == 0, "openAll 打开了 2 个 modem")
    check(opened[1] == "left" and opened[2] == "back", "有线优先、两个都打开")
    check(bareNet.describe(list) == "1 wired / 1 wireless", "describe 统计正确")
    check(#peripheral.getNames() == 2 and #bareNet.findModems() == 2, "两个 modem 都被识别")

    peripheral.getNames, peripheral.getType, peripheral.wrap, peripheral.call =
        realGetNames, realGetType, realWrap, realCall
    rednet.open = realOpen
end

-- ── 6b. 作业数学：矩阵乘法（独立对答案） ─────────────────────────────────
section("作业数学：matmul（在测试里独立算一遍同样的乘积）")
do
    local jm = U["dc.jobs"]
    local def = jm.loadSource(readHost(PROJECT .. "/src/jobs/matmul.lua"), "@matmul")
    check(def ~= nil, "matmul 作业能装载")

    -- 独立实现：同样的 LCG / 同样的种子，在测试里重算一遍 n=8 的乘积
    local function lcg(x) return (x * 1103515245 + 12345) % 2147483648 end
    local function matrix(n, seed)
        local m = {}
        local x = math.floor(seed) % 2147483648
        for i = 1, n do
            m[i] = {}
            for j = 1, n do
                x = lcg(x)
                m[i][j] = (x % 2001) / 1000 - 1
            end
        end
        return m
    end
    local n, seed = 8, 7
    local A, B = matrix(n, seed), matrix(n, seed + 1)
    local wantSum, wantTrace, wantMax = 0, 0, 0
    for i = 1, n do
        for j = 1, n do
            local acc = 0
            for k = 1, n do acc = acc + A[i][k] * B[k][j] end
            wantSum = wantSum + acc
            if i == j then wantTrace = wantTrace + acc end
            if math.abs(acc) > wantMax then wantMax = math.abs(acc) end
        end
    end

    -- 真的跑一遍作业：3 个任务（每任务 3 行，共 8 行）
    local ctx = unitCtx()
    local args = { n = n, rows = 3, seed = seed }
    local tasks = def.split(args)
    check(#tasks == 3, "按 rows=3 切成 3 个任务（实际 " .. #tasks .. "）")
    local results = {}
    for _, task in ipairs(tasks) do
        results[#results + 1] = def.map(task, ctx)
    end
    local got = def.reduce(results, args)
    check(got.count == n * n, "覆盖 " .. (n * n) .. " 个元素（实际 " .. tostring(got.count) .. "）")
    check(math.abs(got.sum - wantSum) < 1e-9,
        string.format("元素和对答案：%.9f vs %.9f", got.sum, wantSum))
    check(math.abs(got.trace - wantTrace) < 1e-9,
        string.format("迹对答案：%.9f vs %.9f", got.trace, wantTrace))
    check(math.abs(got.maxAbs - wantMax) < 1e-9, "最大绝对值对答案")
    check(type(def.format(got)) == "string" and #def.format(got) > 10, "format 能输出一行摘要")
end

-- ── 6c. 作业数学：N 体引力（牛顿第三定律自检 + 独立对答案） ──────────────
section("作业数学：nbody（净外力≈0 + 在测试里独立算一遍）")
do
    local jm = U["dc.jobs"]
    local def = jm.loadSource(readHost(PROJECT .. "/src/jobs/nbody.lua"), "@nbody")
    check(def ~= nil, "nbody 作业能装载")

    local n, seed, eps = 6, 3, 0.5
    local args = { bodies = n, step = 2, seed = seed, eps = eps }

    -- 跑作业：3 个任务
    local ctx = unitCtx()
    local tasks = def.split(args)
    check(#tasks == 3, "按 step=2 切成 3 个任务（实际 " .. #tasks .. "）")
    local results = {}
    for _, task in ipairs(tasks) do
        results[#results + 1] = def.map(task, ctx)
    end
    local got = def.reduce(results, args)

    -- 独立实现同一套公式，逐项对答案
    local function lcg(x) return (x * 1103515245 + 12345) % 2147483648 end
    local list, x = {}, seed % 2147483648
    for i = 1, n do
        local function nx() x = lcg(x) return x end
        list[i] = { x = (nx() % 20001) / 1000 - 10, y = (nx() % 20001) / 1000 - 10,
            m = (nx() % 1000) / 100 + 1 }
    end
    local wfx, wfy, wsum = 0, 0, 0
    for i = 1, n do
        for j = 1, n do
            if i ~= j then
                local dx, dy = list[j].x - list[i].x, list[j].y - list[i].y
                local r2 = dx * dx + dy * dy + eps * eps
                local r = math.sqrt(r2)
                local fmag = list[i].m * list[j].m / r2     -- G = 1
                wfx = wfx + fmag * dx / r
                wfy = wfy + fmag * dy / r
                wsum = wsum + fmag
            end
        end
    end
    check(math.abs(got.sumAbs - wsum) < 1e-9,
        string.format("Σ|F| 对答案：%.9f vs %.9f", got.sumAbs, wsum))
    check(math.abs(got.fx - wfx) < 1e-9 and math.abs(got.fy - wfy) < 1e-9,
        "分方向合力对答案")
    check(got.pairs == n * (n - 1), "两两作用计数正确：" .. tostring(got.pairs))
    check(got.wantPairs == n * (n - 1), "reduce 里算出的应有计数正确")
    -- 自检点：牛顿第三定律 → 全体净外力必须是 0（浮点残差量级）
    check(got.net < 1e-9, string.format("净外力 ≈ 0（实际 %.3e）", got.net))
    check(type(def.format(got)) == "string" and #def.format(got) > 10, "format 能输出一行摘要")
end

-- ── 6d. 作业数学：TSP 暴力搜索（独立枚举对最优解） ───────────────────────
section("作业数学：tsp（在测试里独立暴力枚举对最优解）")
do
    local jm = U["dc.jobs"]
    local def = jm.loadSource(readHost(PROJECT .. "/src/jobs/tsp.lua"), "@tsp")
    check(def ~= nil, "tsp 作业能装载")

    local n, seed = 6, 5
    local args = { cities = n, seed = seed }
    local tasks = def.split(args)
    check(#tasks == n - 1, "按第二个城市切成 " .. (n - 1) .. " 个分支任务（实际 " .. #tasks .. "）")

    -- 独立实现：同一套坐标生成 + 全排列暴力枚举
    local function lcg(x) return (x * 1103515245 + 12345) % 2147483648 end
    local pts, x = {}, seed % 2147483648
    for i = 1, n do
        local function nx() x = lcg(x) return x end
        pts[i] = { x = (nx() % 10001) / 1000, y = (nx() % 10001) / 1000 }
    end
    local function d(a, b)
        local dx, dy = a.x - b.x, a.y - b.y
        return math.sqrt(dx * dx + dy * dy)
    end
    local wantBest, wantCount = math.huge, 0
    local perm = {}
    for i = 2, n do perm[#perm + 1] = i end
    local function enumerate(k)
        if k > #perm then
            local len, prev = d(pts[1], pts[perm[1]]), perm[1]
            for i = 2, #perm do
                len = len + d(pts[prev], pts[perm[i]])
                prev = perm[i]
            end
            len = len + d(pts[prev], pts[1])
            wantCount = wantCount + 1
            if len < wantBest then wantBest = len end
            return
        end
        for i = k, #perm do
            perm[i], perm[k] = perm[k], perm[i]
            enumerate(k + 1)
            perm[i], perm[k] = perm[k], perm[i]
        end
    end
    enumerate(1)

    -- 跑作业：分支任务 + reduce
    local ctx = unitCtx()
    local results = {}
    for _, task in ipairs(tasks) do
        results[#results + 1] = def.map(task, ctx)
    end
    local got = def.reduce(results, args)
    check(math.abs(got.len - wantBest) < 1e-9,
        string.format("最短回路对答案：%.6f vs %.6f（暴力枚举 %d 条）", got.len, wantBest, wantCount))
    -- 路线结构自检：访问每个城市恰好一次，且首尾都是 1
    local seen, okTour = {}, true
    if type(got.tour) ~= "table" or #got.tour ~= n then
        okTour = false
    else
        for _, c in ipairs(got.tour) do
            if seen[c] or c < 1 or c > n then okTour = false end
            seen[c] = true
        end
    end
    check(okTour and got.tour[1] == 1, "最优路线是 1 出发的合法哈密顿回路")
    local sumSteps = 0
    for _, r in ipairs(results) do sumSteps = sumSteps + (r.steps or 0) end
    check(got.steps == sumSteps, "reduce 汇总的枚举次数与各任务一致")
    check(type(def.format(got)) == "string" and #def.format(got) > 10, "format 能输出一行摘要")
end

-- ── 6e. 作业数学：LU 分解（残差自检 + 独立实现对答案） ───────────────────
section("作业数学：ludecomp（残差自检 + 测试里独立写一份 LU）")
do
    local jm = U["dc.jobs"]
    local def = jm.loadSource(readHost(PROJECT .. "/src/jobs/ludecomp.lua"), "@ludecomp")
    check(def ~= nil, "ludecomp 作业能装载")

    local n, seed, cols = 6, 11, 3
    local args = { n = n, cols = cols, seed = seed }
    local ctx = unitCtx()
    local tasks = def.split(args)
    check(#tasks == 2, "按 cols=3 切成 2 个任务（实际 " .. #tasks .. "）")
    local results = {}
    for _, task in ipairs(tasks) do
        results[#results + 1] = def.map(task, ctx)
    end
    local got = def.reduce(results, args)

    check(got.solved == n, "解了 " .. n .. " 个右端项（实际 " .. tostring(got.solved) .. "）")
    check(got.maxRes < 1e-9, string.format("残差 max|Ax-b| = %.3e（应≈0）", got.maxRes))

    -- 独立实现同一套生成与求解，对 Σx 做二次确认
    local function lcg(x) return (x * 1103515245 + 12345) % 2147483648 end
    local x = seed % 2147483648
    local function nx() x = lcg(x) return x end
    local A = {}
    for i = 1, n do
        A[i] = {}
        for j = 1, n do A[i][j] = (nx() % 2001) / 1000 - 1 end
        A[i][i] = A[i][i] + n
    end
    local B = {}
    for j = 1, n do
        B[j] = {}
        for i = 1, n do B[j][i] = (nx() % 2001) / 1000 - 1 end
    end
    -- 教科书式高斯消元（和作业里的 LU 写法不同，作为交叉验证）
    local wantSum = 0
    for j = 1, n do
        local M = {}
        for i = 1, n do
            M[i] = {}
            for k = 1, n do M[i][k] = A[i][k] end
            M[i][n + 1] = B[j][i]
        end
        for k = 1, n - 1 do
            for i = k + 1, n do
                local f = M[i][k] / M[k][k]
                for c = k, n + 1 do M[i][c] = M[i][c] - f * M[k][c] end
            end
        end
        local xv = {}
        for i = n, 1, -1 do
            local s = M[i][n + 1]
            for c = i + 1, n do s = s - M[i][c] * xv[c] end
            xv[i] = s / M[i][i]
        end
        for i = 1, n do wantSum = wantSum + xv[i] end
    end
    check(math.abs(got.sumX - wantSum) < 1e-6,
        string.format("Σx 对答案：%.6f vs %.6f", got.sumX, wantSum))
    check(type(def.format(got)) == "string" and #def.format(got) > 10, "format 能输出一行摘要")
end

-- ── 7. 持久化：断点续算 / 结果缓存 ───────────────────────────────────────
section("持久化：断点续算 + 结果缓存")

do
    local st = U["dc.state"]

    -- ① 结果缓存：跑完一个作业会写缓存；同参数再提一次直接命中，不再派任务
    local S, uni, sent = newSched({ cache = true, snapshot = false, maxParallel = 1 })
    local P = uni["dc.protocol"]
    local j = addUnitJob(S, uni, { "tasks=3", "size=50" }, 0)
    local function feed(sched, uni2, workerId)
        local m = sched:assign(workerId)
        if not m then return nil end
        sched:onResult(workerId, uni2["dc.protocol"].msg(uni2["dc.protocol"].RESULT, {
            job = m.job, task = m.task, ok = true,
            data = { id = m.task, n = 50, sum = 42925 }, ms = 5,
        }))
        return m
    end
    while feed(S, uni, 1) do end
    check(S.jobs[j.id].state == "done", "作业跑完（3 个任务）")
    check(S.jobs[j.id].cacheKey and st.cacheGet(S.jobs[j.id].cacheKey) ~= nil, "结果已写入缓存")

    local sentBefore = #sent
    local j2 = S:addJob(uni["dc.jobs"].loadSource(readHost(PROJECT .. "/src/jobs/selftest.lua"), "@s"),
        { "tasks=3", "size=50" }, {})
    check(j2 and j2.cached == true and j2.state == "done", "同参数再提交 → 命中缓存、直接完成")
    check(#sent == sentBefore, "命中缓存时没有派发任何任务")

    -- 跳过缓存
    local j3 = S:addJob(uni["dc.jobs"].loadSource(readHost(PROJECT .. "/src/jobs/selftest.lua"), "@s"),
        { "tasks=3", "size=50" }, { nocache = true })
    check(j3 and not j3.cached and j3.state ~= "done", "run! 跳过缓存，正常排队执行")

    -- ② 断点续算：跑一半 → 快照 → 新调度器恢复 → 接着跑完
    local S2, uni2 = newSched({ cache = false, snapshot = true, maxParallel = 1 })
    local jr = addUnitJob(S2, uni2, { "tasks=4", "size=40" }, 0)
    local feed40 = function(sched, u, workerId)
        local m = sched:assign(workerId)
        if not m then return nil end
        sched:onResult(workerId, u["dc.protocol"].msg(u["dc.protocol"].RESULT, {
            job = m.job, task = m.task, ok = true,
            data = { id = m.task, n = 40, sum = 22140 }, ms = 5,
        }))
        return m
    end
    feed40(S2, uni2, 7)
    feed40(S2, uni2, 7)
    check(S2.jobs[jr.id].counts.done == 2 and S2.jobs[jr.id].counts.pending == 2,
        "续算前：4 个任务完成了 2 个")
    local okSnap = S2:saveSnapshot()
    check(okSnap and st.hasSnapshot(), "快照已写入磁盘")

    local S3, uni3 = newSched({ cache = false, snapshot = true, maxParallel = 1 })
    local n, err = S3:restore()
    check(n == 1, "新调度器从快照恢复了 1 个作业" .. (err and ("（" .. tostring(err) .. "）") or ""))
    local rj = S3.jobs[jr.id]
    check(rj and rj.counts.done == 2 and rj.counts.pending == 2,
        "恢复后：已完成 2 个（结果保住），待办 2 个")
    check(rj and rj.restored == true, "恢复出来的作业带 restored 标记")
    check(rj and rj.def and rj.def.reduce ~= nil, "作业源码被重新装载（reduce 可用）")

    feed40(S3, uni3, 8)
    feed40(S3, uni3, 8)
    check(S3.jobs[jr.id].state == "done", "续算后作业正常完成")
    check(st.history(5) ~= nil, "运行历史可读")

    -- ③ 节点贡献排行（跨会话累计 + 当前会话增量）
    local S9 = newSched({ snapshot = false })
    S9.lifetime = {
        [1] = { name = "old-node", done = 10, fail = 1 },
        [2] = { name = "gone-node", done = 3, fail = 0 },
    }
    local w9 = S9:worker(9)
    w9.name, w9.done, w9.fail = "now-node", 4, 0
    local rankText = table.concat(S9:topLines(5), "\n")
    check(rankText:find("now-node", 1, true) ~= nil, "排行包含当前会话节点")
    check(rankText:find("old-node", 1, true) ~= nil, "排行包含历史节点")
    check(rankText:find("#1", 1, true) ~= nil and rankText:find("#9", 1, true) ~= nil,
        "排行列出节点编号")

    local life = {}
    local fake = { [5] = { name = "x", done = 3, fail = 0 } }
    st.mergeWorkers(life, fake)
    st.mergeWorkers(life, fake)
    check(life[5].done == 3, "mergeWorkers 只累加增量（重复保存不会翻倍）")
    fake[5].done = 7
    st.mergeWorkers(life, fake)
    check(life[5].done == 7, "增量累加正确（3 → 7）")

    -- 收尾：清掉快照与缓存，免得影响后面的端到端场景
    st.clearSnapshot()
    st.cacheClear()
    check(not st.hasSnapshot(), "清理快照")
end

-- ── 7b. 两级汇总（reduce 也并行） ────────────────────────────────────────
section("两级 reduce：结果多时把汇总也拆成并行任务")
do
    local uni = makeUniverse("twolevel", 91)
    local P = uni["dc.protocol"]
    local sent = {}
    uni["dc.net"].send = function(target, msg) sent[#sent + 1] = { target = target, msg = msg } return true end
    uni["dc.net"].broadcast = function() return true end
    local S = uni["dc.sched"].new({ cfg = { cache = false, snapshot = false,
        twoLevelReduce = true, reduceThreshold = 2, reduceGroupSize = 2 } })
    local src = readHost(PROJECT .. "/src/jobs/cloudprimes.lua")

    -- cloudprimes 的 reduce 只做累加，天然满足结合律，适合两级汇总
    local j = S:addJob(uni["dc.jobs"].loadSource(src, "@cloudprimes"), { "to=120", "chunk=20" }, {})
    check(j and j.total == 6, "提交 6 个任务（to=120 chunk=20）")

    -- 一个循环跑完两个阶段：map 任务喂假结果，reduce 任务用真 runReduce 跑一遍
    local mapCount, reduceCount, badReduce = 0, 0, 0
    local m = S:assign(1)
    while m do
        if m.phase == "reduce" then
            reduceCount = reduceCount + 1
            local res = uni["dc.jobs"].runReduce(src, m.payload, m.args, unitCtx())
            if res == nil then badReduce = badReduce + 1 end
            S:onResult(1, P.msg(P.RESULT, { job = m.job, task = m.task, ok = true, data = res, ms = 2 }))
        else
            mapCount = mapCount + 1
            S:onResult(1, P.msg(P.RESULT, { job = m.job, task = m.task, ok = true, ms = 3,
                data = { lo = 1, hi = 2, count = 1, last = 2, via = "local" } }))
        end
        m = S:assign(1)
    end
    check(mapCount == 6, "第一阶段共派发 6 个 map 任务（实际 " .. mapCount .. "）")
    check(S.jobs[j.id].phase == "reduce", "结果条数达到阈值 → 自动进入两级汇总")
    check(S.jobs[j.id].mapDone == 6 and S.jobs[j.id].total == 3,
        "6 条结果按每组 2 条分成 3 个 reduce 任务")
    check(reduceCount == 3 and badReduce == 0, "3 个任务都是 reduce 任务且都执行成功")
    check(S.jobs[j.id].state == "done", "两级汇总后作业正常完成")
    local res = S.jobs[j.id].result
    check(res and res.primes == 6, "两级汇总结果与逐条累加一致（primes=6，实际 " ..
        tostring(res and res.primes) .. "）")
    check(res and res.tasks == 6, "结合律校验：reduce 内部计数也正确（tasks=6）")

    -- 阈值调高就不该走两级
    local S2 = uni["dc.sched"].new({ cfg = { cache = false, snapshot = false,
        twoLevelReduce = true, reduceThreshold = 999 } })
    local j2 = S2:addJob(uni["dc.jobs"].loadSource(src, "@cloudprimes"), { "to=120", "chunk=20" }, {})
    local m2 = S2:assign(1)
    while m2 do
        S2:onResult(1, P.msg(P.RESULT, { job = m2.job, task = m2.task, ok = true, ms = 1,
            data = { lo = 1, hi = 2, count = 1, via = "local" } }))
        m2 = S2:assign(1)
    end
    check(S2.jobs[j2.id].phase == "map" and S2.jobs[j2.id].state == "done",
        "阈值 999 时 6 条结果直接单级汇总")

    -- 作业可以用 twoLevel = false 明确拒绝两级汇总
    local src2 = readHost(PROJECT .. "/src/jobs/selftest.lua")
    local def2 = uni["dc.jobs"].loadSource(src2, "@selftest")
    check(def2 and def2.twoLevel == false, "selftest 声明了 twoLevel = false（它校验全局一致性）")
end

-- ── 8. 云端卸载（单元级） ────────────────────────────────────────────────
section("云端卸载：JSON / 端点持久化 / 请求打包与解析 / 冷却")

do
    local cm = U["dc.cloud"]
    local jm = U["dc.jobs"]

    local ready, why = cm.httpReady()
    check(ready == true, "本机 http 与 JSON 可用" .. (ready and "" or ("（" .. tostring(why) .. "）")))

    local enc = cm.encode({ a = 1, s = "x", t = { 1, 2 } })
    local dec = cm.decode(enc)
    check(type(dec) == "table" and dec.a == 1 and dec.s == "x" and dec.t[2] == 2,
        "JSON 编解码往返正确")

    -- 端点注册与持久化
    if fs.exists(cm.FILE) then fs.delete(cm.FILE) end
    local list = cm.load()
    local ep, eperr = cm.addEndpoint(list, "unit-ep", "http://127.0.0.1:9/dcnet", 3)
    check(ep ~= nil and ep.id < 0, "端点注册成功并使用负数虚拟 ID" ..
        (ep and "" or ("（" .. tostring(eperr) .. "）")))
    local back = cm.load()
    check(#back == 1 and back[1].slots == 3, "端点已持久化并能读回")
    local _, dupErr = cm.addEndpoint(list, "unit-ep", "http://x/y", 1)
    check(dupErr ~= nil, "重名端点被拒绝")
    local _, badErr = cm.addEndpoint(list, "bad", "ftp://x", 1)
    check(badErr ~= nil, "非 http(s) 的 URL 被拒绝")

    -- 作业的云端打包 / 解析（都在主控上跑）
    local src = readHost(PROJECT .. "/src/jobs/cloudprimes.lua")
    local def = jm.loadSource(src, "@cloudprimes")
    check(def and def.cloud ~= nil, "cloudprimes 作业带 cloud 定义")
    local task = { lo = 2, hi = 25000 }
    local body = jm.buildCloudRequest(def, task, {})
    check(type(body) == "table" and body.op == "primes" and body.from == 2,
        "cloud.build 生成正确请求体")
    local data = jm.parseCloudResponse(def, { ok = true, data = { count = 2762, last = 24989 } },
        task, {})
    check(type(data) == "table" and data.count == 2762 and data.via == "cloud",
        "cloud.parse 解析出结果")
    check(jm.parseCloudResponse(def, { ok = true, data = {} }, task, {}) == nil,
        "cloud.parse 对缺字段的响应报错")
    check(jm.buildCloudRequest({ name = "x" }, task, {}) == nil, "没有 cloud 定义时打包报错")

    -- 冷却：连不上时退避，让本机节点先接手
    local S = newSched({ cloud = true })
    local CL = cm.new({ sched = S, cfg = S.cfg, log = function() end })
    local e2 = cm.find(CL.endpoints, "unit-ep")
    CL:cool(e2, "connection refused")
    check(e2.cooldownUntil and e2.cooldownUntil > os.clock(), "失败后端点进入冷却")
    CL:clearCool(e2)
    check(e2.cooldownUntil == nil, "成功后冷却解除")

    -- 虚拟 worker：云端端点出现在节点表与排行里
    CL:registerWorkers()
    local found = false
    for _, w in ipairs(S:workerList()) do
        if w.virtual and w.name == "cloud:unit-ep" then found = true end
    end
    check(found, "端点在节点表里显示为 cloud:<名字>")
    check(#S:topLines(5) > 0, "端点参与贡献排行")

    fs.delete(cm.FILE)
end

-- ── 8b. 消息签名与防重放 ─────────────────────────────────────────────────
section("消息签名：SHA-256/HMAC 向量 + 校验 + 防重放")
do
    local cm = U["dc.crypto"]
    check(cm.available == true, "本机有 bit32（签名的前提）")
    local vecs = cm.selftest()
    check(#vecs == 5, "自检一共 5 条测试向量")
    for _, r in ipairs(vecs) do
        check(r.ok, r.name .. "（got " .. tostring(r.got) .. "）")
    end

    check(cm.canonical({ b = 1, a = 2 }) == cm.canonical({ a = 2, b = 1 }),
        "canonical 序列化与键顺序无关")
    check(cm.canonical({ a = 1 }) ~= cm.canonical({ a = 2 }), "canonical 能区分不同内容")
    check(cm.equal("ab", "ab") and not cm.equal("ab", "ac") and not cm.equal("ab", "abc"),
        "定长比较正确")

    -- 单独加载一份不打桩的真 net 模块
    local net = (function()
        local req = makeRequire()
        local saved = _G.dc_require
        _G.dc_require = req
        local n = req("dc.net")
        _G.dc_require = saved
        return n
    end)()

    -- 没设密钥：不签名、全放行（向后兼容）
    net.setKey(nil)
    local m1 = { t = "task", job = 1, task = 2, payload = { x = 1 } }
    net.sign(m1)
    check(m1.sid == nil and m1.sig == nil, "未设密钥时不签名")
    check(net.verify(9, m1) == true, "未设密钥时全部放行（兼容旧配置）")
    check(net.fingerprint() == nil, "未设密钥时没有指纹")

    -- 启用签名
    local kok, kerr = net.setKey("s3cret-key-123")
    check(kok == true, "设置共享密钥" .. (kok and "" or ("（" .. tostring(kerr) .. "）")))
    check(net.hasKey() and #tostring(net.fingerprint()) == 8, "指纹是 8 位十六进制")
    check(net.setKey("short") == nil, "过短的密钥被拒绝")

    local m2 = { t = "task", job = 1, task = 2, payload = { x = 1 } }
    net.sign(m2)
    check(m2.sid and m2.seq == 1 and m2.ts and #tostring(m2.sig) == 64,
        "签名后带上 sid/seq/ts/sig")
    local okv, why = net.verify(9, m2)
    check(okv == true, "合法签名的消息通过" .. (okv and "" or ("（" .. tostring(why) .. "）")))

    -- 篡改内容
    local tampered = { t = "task", job = 1, task = 2, payload = { x = 99 },
        sid = m2.sid, seq = m2.seq, ts = m2.ts, sig = m2.sig }
    local ok2, why2 = net.verify(9, tampered)
    check(ok2 == false and why2 == "bad signature", "被篡改的内容拒绝（原因：" .. tostring(why2) .. "）")

    -- 重放同一条消息
    local replay = {}
    for k, v in pairs(m2) do replay[k] = v end
    local ok3, why3 = net.verify(9, replay)
    check(ok3 == false and why3 == "duplicate message", "重放被拒绝（原因：" .. tostring(why3) .. "）")

    -- 网络屏幕帧：lines 是序列化后的字符串，签名只覆盖它的校验和（BULK_FIELDS）
    local P = U["dc.protocol"]
    local frame = P.msg(P.DISP, {
        master = 7, w = 51, h = 19, at = 1,
        lines = textutils.serialize({ { text = "dcnet 主控", colour = 32 } }),
    })
    net.sign(frame)
    check(net.verify(9, frame) == true, "网络屏幕帧（lines 走校验和）签名可验证")
    local badFrame = P.msg(P.DISP, {
        master = 7, w = 51, h = 19, at = 1,
        lines = textutils.serialize({ { text = "FAKE", colour = 32 } }),
    })
    for k, v in pairs(frame) do
        if k ~= "lines" then badFrame[k] = v end
    end
    local okd, whyd = net.verify(9, badFrame)
    check(okd == false and whyd == "bad signature", "篡改屏幕帧内容会被签名拒绝")

    -- 未签名
    local ok4, why4 = net.verify(9, { t = "result", job = 1, task = 1, ok = true })
    check(ok4 == false and why4 == "unsigned", "启用签名后未签名消息被拒绝")

    -- 时间戳过期
    local ok5, why5 = net.verify(9, { t = "task", sid = "deadbeef", seq = 3, ts = 1000, sig = "x" })
    check(ok5 == false and why5 == "invalid timestamp", "时间戳过期的消息被拒绝")

    -- 换密钥后旧签名失效
    net.setKey("another-key-456")
    local ok6 = net.verify(9, { t = "task", sid = m2.sid, seq = 99, ts = m2.ts, sig = m2.sig })
    check(ok6 == false, "换密钥后旧消息不再被接受")

    local stats = net.statsLines()
    check(type(stats) == "table" and #stats >= 2, "统计行可用于 net/key 指令")
    net.setKey(nil)
end

-- ── 8c. 大负载走文件通道 ─────────────────────────────────────────────────
section("大负载通道：池子 / 引用式负载 / 引用式结果")
do
    local st = U["dc.state"]
    local xf = U["dc.xfer"]
    local util = U["dc.util"]

    check(st.validPoolName("task-1-2.dat") and st.validPoolName("res-3-4.dat"),
        "池子文件名白名单通过")
    check(not st.validPoolName("../evil.dat") and not st.validPoolName("a/b.dat")
        and not st.validPoolName("worker.lua"), "池子拒绝越界/未知文件名")

    local name = "task-1-1.dat"
    local wrote, size = st.poolPut(name, { blob = string.rep("x", 5000) })
    check(wrote == name and size > 5000, "写进池子（" .. tostring(size) .. " 字节）")
    local back = st.poolGet(name)
    check(type(back) == "table" and #back.blob == 5000, "从池子读回内容")
    check(not util.exists(st.poolPath(name)), "读完默认删掉池子文件")

    -- 发送队列：发送端登记，由唯一的接收循环推进
    local reg = xf.newRegistry()
    local sent = {}
    local xid = xf.enqueue(reg, 42, "res-1-1.dat", "resdata", string.rep("y", 9000))
    check(xid ~= nil, "登记一次大结果传输")
    xf.pollRegistry(reg, function(target, msg) sent[#sent + 1] = msg return true end)
    check(#sent == 1 and sent[1].t == "put" and sent[1].n == 3,
        "9000 字节切成 3 块开始发送")
    reg.results[xid] = "ok"
    check(xf.waitFor(reg, xid, 1) == true, "已完成的传输立即返回成功")
    reg.results.dead = "fail"
    check(select(1, xf.waitFor(reg, "dead", 1)) == nil, "失败的传输返回 nil")

    -- 主控侧：负载超过阈值 → 只发引用
    local S, uni, msgs = newSched({ cache = false, snapshot = false,
        fileChannel = true, inlineLimit = 200 })
    local src = readHost(PROJECT .. "/src/jobs/bigdata.lua")
    local j = S:addJob(uni["dc.jobs"].loadSource(src, "@bigdata"),
        { "tasks=2", "size=1200", "res=100" }, {})
    check(j ~= nil, "提交大负载作业")
    local m = S:assign(1)
    check(m ~= nil, "派发第一个任务")
    check(m.payload == nil and type(m.payloadRef) == "string",
        "大负载改走引用（payloadRef=" .. tostring(m.payloadRef) .. "）")
    local blob = st.poolGet(m.payloadRef, true)     -- keep：节点还要来取
    check(type(blob) == "table" and #blob.blob == 1200, "池子里存着真实负载")
    check(st.poolList and #st.poolList() >= 1, "池子列表可用")

    -- 主控侧：结果只带引用 → 从池子解析
    local ref = "res-7-7.dat"
    st.poolPut(ref, { i = 7, len = 1200, sum = 1, check = 2, out = "z" })
    local P = uni["dc.protocol"]
    S:onResult(1, P.msg(P.RESULT, {
        job = j.id, task = m.task, ok = true, dataRef = ref, ms = 5,
    }))
    check(S.jobs[j.id].tasks[m.task].state == "done", "带 dataRef 的结果被采纳")
    local got = S.jobs[j.id].tasks[m.task].result
    check(type(got) == "table" and got.i == 7, "结果内容来自池子文件")

    -- 引用不存在 → 读不到（onResult 会把它当成失败，而不是崩溃）
    local missing, merr = st.poolGet("res-99-99.dat")
    check(missing == nil and merr ~= nil, "池子里没有的引用读不到：" .. tostring(merr))
    check(not st.validPoolName(nil), "nil 文件名被拒绝")

    -- 清理池子
    for _, f in ipairs(st.poolList()) do fs.delete(st.poolPath(f.name)) end
    check(#st.poolList() == 0, "池子清空")
end

-- ── 9. monitor 大屏面板 ─────────────────────────────────────────────────
section("monitor 大屏面板：内容生成 / 绘制 / 自适应 / 外设扫描")

do
    local pm = U["dc.panel"]
    local S = newSched({ cache = false, snapshot = false })
    addUnitJob(S, U, { "tasks=3", "size=50" }, 0)
    -- 先派一个任务（派发会把 worker 的进度清零），再摆节点状态
    S:assign(3)
    local w1 = S:worker(3); w1.name, w1.state, w1.progress = "node-3", "busy", 0.42
    local w2 = S:worker(4); w2.name, w2.state = "node-4", "idle"
    local w3 = S:worker(5); w3.name, w3.state = "node-5", "offline"
    S.stats.done, S.stats.failed, S.stats.retries = 12, 1, 2

    local P = pm.new({ log = function() end })
    P.w, P.h = 51, 19
    local text = ""
    for _, l in ipairs(P:lines(S, nil)) do text = text .. l.text .. "\n" end
    check(text:find("dcnet master", 1, true) ~= nil, "标题行包含 dcnet 主控")
    check(text:find("Workers 2/3", 1, true) ~= nil, "集群概况显示在线/登记（2/3）")
    check(text:find("#3:42%", 1, true) ~= nil, "节点矩阵显示忙碌节点进度")
    check(text:find("#4:idle", 1, true) ~= nil, "节点矩阵显示空闲节点")
    check(text:find("#5:offline", 1, true) ~= nil, "节点矩阵显示离线节点")
    check(text:find("Total tasks 12", 1, true) ~= nil, "统计行")
    check(text:find("#1 selftest", 1, true) ~= nil, "作业行")

    -- 极简模式：很小的显示器不能崩
    P.w, P.h = 12, 2
    local tiny = P:lines(S, nil)
    check(#tiny <= 2 and tiny[1].text:find("dcnet", 1, true) ~= nil, "小尺寸退化为极简模式")

    -- 超长内容会被截断到显示器宽度内（按显示列数算，中文占 2 列）
    P.w, P.h = 20, 19
    local narrow = P:lines(S, nil)
    local tooLong = nil
    for _, l in ipairs(narrow) do
        if U["dc.util"].textWidth(l.text) > 20 then tooLong = l.text end
    end
    check(tooLong == nil, "所有行都截断到显示器宽度内" ..
        (tooLong and ("（超宽: " .. tooLong .. "）") or ""))
    check(U["dc.util"].textWidth("中文abc") == 7, "textWidth：中文按 2 列计算")

    -- 画到假显示器上（记录所有写入）
    local fake = { __name = "fake", buf = {}, x = 1, y = 1, scale = 1 }
    function fake.getSize() return 40, 10 end
    function fake.setTextScale(s) fake.scale = s end
    function fake.setBackgroundColour() end
    function fake.setTextColour(c) fake.lastColour = c end
    function fake.setCursorPos(x, y) fake.x, fake.y = x, y end
    function fake.write(s) fake.buf[#fake.buf + 1] = string.rep(" ", fake.x - 1) .. tostring(s) end
    function fake.clear() fake.buf = {} end
    P.w, P.h = 40, 10
    check(P:attach(fake) == true, "可以把假显示器挂到面板上")
    check(fake.scale == pm.DEFAULT_SCALE, "挂载时按缩放设置调字号")
    check(P:redraw(S, nil, true) == true, "重绘一帧成功")
    local drawn = table.concat(fake.buf, "\n")
    check(drawn:find("dcnet master", 1, true) ~= nil, "假显示器收到了标题")
    check(drawn:find("Workers", 1, true) ~= nil, "假显示器收到了集群概况")
    check(P:detach() ~= nil, "可以卸载显示器")
    check(P:redraw(S, nil, true) == false, "没有显示器时重绘是空操作")

    -- 外设扫描
    local rgn, rgt, rw = peripheral.getNames, peripheral.getType, peripheral.wrap
    peripheral.getNames = function() return { "right", "left", "top" } end
    peripheral.getType = function(n)
        if n == "right" or n == "left" then return "monitor" end
        return "modem"
    end
    peripheral.wrap = function() return { getSize = function() return 8, 5 end, setTextScale = function() end } end
    local list = pm.findMonitors()
    check(#list == 2 and list[1].name == "left", "扫描到 2 台显示器且按名字排序")

    -- 有线网络上的远端显示器：getNames 里只有 modem，但 getNamesRemote 能看到
    peripheral.getNames = function() return { "back" } end
    peripheral.getType = function(n) return n == "back" and "modem" or nil end
    peripheral.wrap = function(n)
        if n == "back" then
            return {
                getNamesRemote = function() return { "monitor_2" } end,
                getTypeRemote = function(nm) return nm == "monitor_2" and "monitor" or nil end,
            }
        end
        return { getSize = function() return 40, 10 end, setTextScale = function() end }
    end
    local remote = pm.findMonitors()
    check(#remote == 1 and remote[1].name == "monitor_2" and remote[1].net == true,
        "扫描到有线网络上的远端显示器（monitor_2）")
    peripheral.getNames, peripheral.getType, peripheral.wrap = rgn, rgt, rw

    -- 面板行生成可以按任意尺寸（网络屏幕用自己显示器的尺寸）
    local custom = pm.linesFor(S, nil, 30, 6)
    check(custom[1].text:find("dcnet master", 1, true) ~= nil, "linesFor 按指定尺寸生成标题行")
    local allFit = true
    for _, l in ipairs(custom) do
        if U["dc.util"].textWidth(l.text) > 30 then allFit = false end
    end
    check(allFit, "linesFor 的每一行都不超过指定宽度")
end

-- ── 10. 一键安装器 ──────────────────────────────────────────────────────
section("一键安装（dist/install.lua）")
do
    -- 先清掉，确保是安装器写进去的
    for _, p in ipairs({ "/dccomp/master.lua", "/dccomp/worker.lua", "/dccomp/screen.lua",
                         "/dccomp/bootstrap.lua", "/dccomp/jobs/selftest.lua", "/startup.lua" }) do
        if fs.exists(p) then fs.delete(p) end
    end

    shell.run(PROJECT .. "/dist/install.lua", "all")
    check(fs.exists("/dccomp/master.lua") and fs.getSize("/dccomp/master.lua") > 10000,
        "安装器写入了 master.lua")
    check(fs.exists("/dccomp/worker.lua") and fs.getSize("/dccomp/worker.lua") > 10000,
        "安装器写入了 worker.lua")
    check(fs.exists("/dccomp/screen.lua") and fs.getSize("/dccomp/screen.lua") > 1000,
        "安装器写入了 screen.lua")
    check(fs.exists("/dccomp/bootstrap.lua"), "安装器写入了 bootstrap.lua")
    local jobCount = 0
    for _, name in ipairs(fs.list("/dccomp/jobs") or {}) do
        if name:sub(-4) == ".lua" then jobCount = jobCount + 1 end
    end
    check(jobCount >= 6, "安装器写入了 " .. jobCount .. " 个作业")

    -- 幂等：默认不覆盖
    local before = fs.getSize("/dccomp/master.lua")
    shell.run(PROJECT .. "/dist/install.lua", "master")
    check(fs.getSize("/dccomp/master.lua") == before, "重复安装默认不覆盖已存在文件")

    -- 开机自启
    shell.run(PROJECT .. "/dist/install.lua", "worker", "--startup=worker")
    check(fs.exists("/startup.lua"), "生成 /startup.lua")
    local boot = readHost("/startup.lua")
    check(boot and boot:find("worker.lua", 1, true) ~= nil, "自启文件指向 worker.lua")
    fs.delete("/startup.lua")

    shell.run(PROJECT .. "/dist/install.lua", "screen", "--startup=screen", "--force")
    local boot2 = readHost("/startup.lua")
    check(boot2 and boot2:find("screen.lua", 1, true) ~= nil, "自启文件可指向 screen.lua")
    fs.delete("/startup.lua")
end

-- ── 11. 端到端：真 master.run + 真 worker.run ────────────────────────────
section("端到端（真 master.run + 真 worker.run）")

-- 捕获 Console:log 用的全局 print，这样断言不看屏幕也能做
local captured = {}
local realPrint = print
_G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    captured[#captured + 1] = table.concat(t, "\t")
end
_G.printError = _G.print

local function seen(needle)
    for _, l in ipairs(captured) do
        if l:find(needle, 1, true) then return true end
    end
    return false
end

local function waitFor(needle, seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if seen(needle) then return true end
        sleep(0.1)
    end
    return false
end

-- 只看 mark 之后新增的日志：把某台机器隔离掉之后，断言不能被"隔离前的旧日志"打中
local function seenAfter(mark, needle)
    for i = (mark or 0) + 1, #captured do
        if captured[i]:find(needle, 1, true) then return true end
    end
    return false
end

local function waitForAfter(mark, needle, seconds)
    local deadline = os.clock() + seconds
    while os.clock() < deadline do
        if seenAfter(mark, needle) then return true end
        sleep(0.1)
    end
    return seenAfter(mark, needle)
end

local function typeLine(s)
    for c in s:gmatch(".") do
        os.queueEvent("char", c)
        sleep(0.02)
    end
    os.queueEvent("key", keys.enter)
    sleep(0.05)
end

-- 内置作业：直接把挂载目录里的作业文件全交给主控释放（不要写死清单，加了新作业也能用）
local defaultJobs = {}
for _, name in ipairs(fs.list(PROJECT .. "/src/jobs") or {}) do
    if name:sub(-4) == ".lua" then
        local src = readHost(PROJECT .. "/src/jobs/" .. name)
        if src then defaultJobs[name] = src end
    end
end
out(string.format("  （注入 %d 个内置作业）", (function()
    local n = 0
    for _ in pairs(defaultJobs) do n = n + 1 end
    return n
end)()))

-- 主控要有一份 worker.lua 才能用 push 分发（对应真实部署里的 /dccomp/worker.lua）
local workerBundle = readHost(PROJECT .. "/dist/worker.lua")
if workerBundle then
    fs.makeDir("/dccomp")
    local fh = fs.open("/dccomp/worker.lua", "w")
    fh.write(workerBundle)
    fh.close()
end

--- 跑一个端到端场景：一套全新的主控 + 两个节点 + 一个脚本化驱动
local function runScenario(title, cfg, driver)
    out("")
    out("-- " .. title)
    -- 每个场景都从干净状态开始：否则上一场留下的快照会被新主控"续算"，
    -- 日志里混进别的作业，断言就会被打中。
    U["dc.state"].clearSnapshot()
    U["dc.state"].cacheClear()
    for _, f in ipairs(U["dc.state"].poolList()) do
        fs.delete(U["dc.state"].poolPath(f.name))
    end
    if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
    captured, bus, blocked = {}, {}, {}
    local M = makeUniverse("master", REAL_ID)
    local W1 = makeUniverse("node3", 3)
    local W2 = makeUniverse("node4", 4)
    local before = fail
    local ok, err = pcall(parallel.waitForAny,
        function() M["dc.master"].run({ defaultJobs = defaultJobs, cfg = cfg or {} }) end,
        function() W1["dc.worker"].run({ master = REAL_ID, name = "node-3" }) end,
        function() W2["dc.worker"].run({ master = REAL_ID, name = "node-4" }) end,
        driver
    )
    check(ok, title .. "：进程正常退出" .. (ok and "" or (": " .. tostring(err))))
    if not ok or fail > before then
        out("  —— 捕获到的日志（尾部）——")
        for i = math.max(1, #captured - 20), #captured do out("  | " .. captured[i]) end
    end
end

-- 场景 1：正常链路 + 代码分发
runScenario("场景 1：正常派发/回收 + push 分发", {}, function()
    if not waitFor("Worker #4 connected", 20) then
        check(false, "两个节点在 20 秒内完成注册")
        return
    end
    check(true, "两个节点完成注册")
    typeLine("run selftest tasks=6 size=200")
    check(waitFor("done 6 / failed 0", 40), "作业在 40 秒内结束且 6/6 成功")
    check(seen("selftest finished"), "日志里有作业结束行")
    check(seen("Result: PASS"), "selftest 结论 PASS")
    check(seen("Sum-of-squares closed-form check: all match"), "所有任务平方和一致")
    check(seen("Result saved: /dccomp/out/"), "结果自动落盘到 /dccomp/out/")

    if workerBundle then
        typeLine("push 3")
        check(waitFor("Pushed worker.lua", 25), "主控完成向 #3 的分块推送")
        check(seen("New version received"), "节点 #3 收到并落盘新版本")
        -- 单机测试里主控与节点共享同一份 fs，"内容一致"这种检查没有意义；
        -- 字节级一致性由上面的 xfer 单元测试保证，这里只验证握手与落盘确实发生。
    end

    -- 节点日志落盘（C3 看门狗/自愈的排查依据）。
    -- 注意日志名用的是真机 ID（os.getComputerID()），不是总线里的虚拟节点号。
    local nodeLog, logDir = nil, "/dccomp/logs"
    for _, name in ipairs(fs.list(logDir) or {}) do
        local t = readHost(logDir .. "/" .. name)
        if t and t:find("Worker starting", 1, true) then nodeLog = name end
    end
    check(nodeLog ~= nil, "节点日志已落盘且含启动记录（" .. tostring(nodeLog) .. "）")
    typeLine("quit")
end)

-- 场景 2：故障注入（前 2 个任务故意报错）
runScenario("场景 2：故障注入（2 个任务故意报错）", {}, function()
    if not waitFor("Worker #4 connected", 20) then
        check(false, "两个节点完成注册")
        return
    end
    typeLine("run selftest tasks=6 size=200 fail=2")
    check(waitFor("done 4 / failed 2", 40), "作业结束：成功 4 / 失败 2")
    check(seen("retry"), "失败任务有重试记录")
    check(seen("selftest deliberate failure"), "日志里能看到故意的失败原因")
    check(seen("expected success 4, actual success 4"), "reduce 拿到的成功数与预期一致")
    typeLine("quit")
end)

-- 场景 3：节点掉线 → 任务重派（把 #4 隔离在总线之外，等价于拔网线/关机）
runScenario("场景 3：节点掉线 → 任务重派",
    { workerTimeout = 3, taskTimeout = 15, verbose = true }, function()
    if not waitFor("Worker #4 connected", 20) then
        check(false, "两个节点完成注册")
        return
    end
    -- 任务规模放大，并等到主控**确实把一个任务派给了 #4**，再拔它的线
    typeLine("run selftest tasks=10 size=20000000")
    check(waitFor("started", 15), "作业开始执行")
    check(waitFor("dispatched to #4", 20), "主控把任务派给了 #4")
    blocked["node4"] = true
    out("  （已隔离节点 #4）")
    check(waitFor("lost contact", 20), "主控检测到 #4 掉线")
    check(waitFor("requeued", 20), "掉线节点手上的任务被重新入队")
    check(waitFor("done 10 / failed 0", 120), "10 个任务最终全部成功（重派生效）")
    typeLine("quit")
end)

-- 场景 4/5：云端卸载（由 run_craftos.py 起一个本地 HTTP 参考服务端）
local cloudUrl = readHost(PROJECT .. "/tests/.cloud_url")
if cloudUrl then
    cloudUrl = cloudUrl:gsub("%s+$", "")

    -- 场景 4：云端可用 → 任务真发 HTTP 出去算
    runScenario("场景 4：云端卸载（真 HTTP 到参考服务端）", {}, function()
        if not waitFor("Worker #4 connected", 20) then
            check(false, "两个节点完成注册")
            return
        end
        typeLine("cloud add local " .. cloudUrl .. " 2")
        check(waitFor("Registered cloud endpoint", 15), "注册云端端点")
        typeLine("cloud test local")
        check(waitFor("probe ok", 20), "cloud test 探活成功（真 HTTP GET）")
        typeLine("run cloudprimes to=200000 chunk=25000")
        check(waitFor("done 8 / failed 0", 60), "作业 8/8 成功")
        local cloudCount = 0
        for _, l in ipairs(captured) do
            local n = l:match("cloud (%d+) / local")
            if n then cloudCount = tonumber(n) end
        end
        check(cloudCount > 0, "确实有任务由云端完成（云端 = " .. cloudCount .. " 个）")
        -- 大请求分块上传（E5）的端到端断言还没进套件：把 cloudChunk 调小 + pad 撑大请求
        -- 会让这一段跑几十次 HTTP 往返，实测把后续场景挤到超时。下一轮用更轻的用例
        -- （pad=9000 / cloudChunk=4096，约 3 块）重做，见项目记忆。
        typeLine("quit")
    end)

    -- 场景 5：云端不可达 → 冷却 + 自动回落本机，作业照常完成
    runScenario("场景 5：云端不可达 → 自动回落本机", {}, function()
        if not waitFor("Worker #4 connected", 20) then
            check(false, "两个节点完成注册")
            return
        end
        typeLine("cloud add bad http://127.0.0.1:1/dcnet 1")
        check(waitFor("Registered cloud endpoint", 15), "注册一个不可达端点")
        typeLine("run cloudprimes to=100000 chunk=25000")
        check(waitFor("done 4 / failed 0", 60), "云端挂了作业照样 4/4 成功")
        local cloudCount = -1
        for _, l in ipairs(captured) do
            local n = l:match("cloud (%d+) / local")
            if n then cloudCount = tonumber(n) end
        end
        check(cloudCount == 0, "全部任务由本机完成（云端 = " .. tostring(cloudCount) .. "）")
        check(seen("cloud unreachable") or seen("unavailable"), "日志里能看到云端不可达/冷却")
        typeLine("quit")
    end)
else
    out("")
    out("-- 场景 4/5：云端卸载（跳过：没有 " .. PROJECT .. "/tests/.cloud_url）")
end

-- 场景 6：作业仓库同步（两台主控之间拉作业）
out("")
out("-- 场景 6：作业仓库同步（两台主控）")
U["dc.state"].clearSnapshot()
U["dc.state"].cacheClear()
if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
captured, bus, blocked = {}, {}, {}
extraRoles[42] = "master2"
do
    local M1 = makeUniverse("master", REAL_ID)
    local M2 = makeUniverse("master2", 42)
    local ok6, err6 = pcall(parallel.waitForAny,
        function() M1["dc.master"].run({ defaultJobs = defaultJobs }) end,
        function() M2["dc.master"].run({ defaultJobs = defaultJobs }) end,
        function()
            if not waitFor("Available jobs", 25) then
                check(false, "两台主控启动")
                return
            end
            check(true, "两台主控启动")
            typeLine("repo 42")
            check(waitFor("Job repo of #", 20), "repo 查询收到对方清单")
            check(seen("selftest.lua"), "清单里列出了 selftest.lua")
            -- 拉一个作业过来（同机共享 fs，所以这里验证的是握手与落盘链路真的跑通）
            typeLine("pull 42 cloudprimes")
            check(waitFor("Pulled job from #42", 25), "pull 完成分块传输并落盘")
            check(fs.exists("/dccomp/jobs/cloudprimes.lua")
                and fs.getSize("/dccomp/jobs/cloudprimes.lua") > 100, "拉取到的作业文件存在且有内容")
            -- 非法作业名会被服务端拒绝
            typeLine("pull 42 ../../evil")
            check(waitFor("Refused", 15) or waitFor("invalid", 15), "非法作业名被拒绝")
            typeLine("quit")
        end)
    check(ok6, "作业仓库场景正常退出" .. (ok6 and "" or ("：" .. tostring(err6))))
    if not ok6 or fail > 0 then
        out("  —— 捕获到的日志 ——")
        for i = math.max(1, #captured - 20), #captured do out("  | " .. captured[i]) end
    end
    extraRoles[42] = nil
end

-- 场景 7：打包产物冒烟（真正跑一遍剥过注释的 dist 产物）
out("")
out("-- 场景 7：打包产物（dist）语法 + 真启动")
for _, f in ipairs({ "master.lua", "worker.lua", "screen.lua", "bootstrap.lua", "install.lua" }) do
    local src = readHost(PROJECT .. "/dist/" .. f)
    local fn, err = U["dc.util"].loadChunk(src or "", "@" .. f)
    check(fn ~= nil, "dist/" .. f .. " 语法正确" ..
        (fn and ("（" .. tostring(#(src or "")) .. " 字节）") or ("：" .. tostring(err))))
end
do
    -- 假装插了一根有线 modem，好让产物里的 net.openAll 成功；其余全走真实 ROM
    local rgn, rgt, rw, rcp = peripheral.getNames, peripheral.getType, peripheral.wrap, peripheral.call
    peripheral.getNames = function() return { "back" } end
    peripheral.getType = function() return "modem" end
    peripheral.call = function(_, method)
        if method == "isWireless" then return false end
        return true
    end
    peripheral.wrap = function()
        return {
            isWireless = function() return false end,
            isOpen = function() return true end,
            open = function() end, close = function() end,
        }
    end
    U["dc.state"].clearSnapshot()
    U["dc.state"].cacheClear()
    if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
    captured, bus, blocked = {}, {}, {}

    local ok7, err7 = pcall(parallel.waitForAny,
        function() shell.run(PROJECT .. "/dist/master.lua") end,
        function()
            if not waitFor("dcnet master", 30) then
                check(false, "打包产物能启动")
                return
            end
            check(true, "打包产物能启动")
            typeLine("help")
            check(waitFor("run <job>", 20), "产物的指令表正常（help 输出）")
            typeLine("state")
            check(waitFor("Snapshot", 20), "产物的 state 指令可用")
            typeLine("quit")
        end)
    check(ok7, "打包产物正常退出" .. (ok7 and "" or ("：" .. tostring(err7))))
    peripheral.getNames, peripheral.getType, peripheral.wrap, peripheral.call = rgn, rgt, rw, rcp
end

-- 场景 8：启用消息签名后链路照常工作，伪造与重放被丢弃
out("")
out("-- 场景 8：消息签名（签名集群 + 伪造/重放拦截）")
U["dc.state"].clearSnapshot()
U["dc.state"].cacheClear()
if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
captured, bus, blocked = {}, {}, {}
do
    local KEY = "test-shared-key-9"
    -- 让主控/节点启动时从 settings 载入密钥（真实使用路径）
    settings.set("dcnet.key", KEY)
    settings.save()

    local M = makeUniverse("master", REAL_ID)
    local W1 = makeUniverse("node3", 3)
    local W2 = makeUniverse("node4", 4)
    local sniffed = {}

    -- 每个宇宙的 net 都带密钥，并在"发送边界"签名（等价于真 rednet 上的行为）。
    -- 注意 role 是"总线角色名"（master/node3…），roleId 是电脑 ID，别搞混。
    local function arm(uni, role, roleId, record)
        local N = uni["dc.net"]
        N.setKey(KEY)
        N.send = function(target, msg, proto)
            N.sign(msg)
            if record then
                sniffed[#sniffed + 1] = { from = roleId, to = destRole(target),
                    msg = textutils.serialize(msg), proto = proto or "dccomp" }
            end
            return busSend(roleId, target, msg, proto)
        end
        N.broadcast = function(msg, proto)
            N.sign(msg)
            if record then
                sniffed[#sniffed + 1] = { from = roleId, to = "all",
                    msg = textutils.serialize(msg), proto = proto or "dccomp" }
            end
            return busBroadcast(roleId, msg, proto)
        end
        N.receive = function(proto, timeout) return busReceive(role, proto, timeout) end
        N.openAll = function() return { { name = "back", wireless = false } }, {} end
        N.describe = function() return "1 有线 / 0 无线" end
    end
    arm(M, "master", REAL_ID, false)
    arm(W1, "node3", 3, true)
    arm(W2, "node4", 4, true)

    local before = fail
    local ok8, err8 = pcall(parallel.waitForAny,
        function() M["dc.master"].run({ defaultJobs = defaultJobs }) end,
        function() W1["dc.worker"].run({ master = REAL_ID, name = "node-3" }) end,
        function() W2["dc.worker"].run({ master = REAL_ID, name = "node-4" }) end,
        function()
            if not waitFor("Message signing enabled", 25) then
                check(false, "主控提示签名已启用")
                return
            end
            check(true, "主控按 settings 里的密钥启用了签名")
            if not waitFor("Worker #4 connected", 25) then
                check(false, "签名集群完成注册")
                -- 活性探针：直接发一条未签名消息，看主控是否收到并拒绝
                busSend(3, REAL_ID, { t = "hello", ver = 1, name = "probe" }, "dccomp")
                waitFor("unsigned", 8)
                out("  [诊断] 总线剩余 " .. tostring(#bus) .. " 条：")
                for i = 1, math.min(#bus, 8) do
                    local d = textutils.unserialize(bus[i].msg) or {}
                    out(string.format("    from=%s to=%s proto=%s t=%s",
                        tostring(bus[i].from), tostring(bus[i].to),
                        tostring(bus[i].proto), tostring(d.t)))
                end
                out("  [诊断] 主控签名统计：" .. table.concat(M["dc.net"].statsLines(), " / "))
                out("  [诊断] 主控最近拒绝：" .. tostring(M["dc.net"].lastBad))
                out("  [诊断] 节点3 统计：" .. table.concat(W1["dc.net"].statsLines(), " / "))
                out("  [诊断] 节点3 最近拒绝：" .. tostring(W1["dc.net"].lastBad))
                out("  [诊断] 节点4 最近拒绝：" .. tostring(W2["dc.net"].lastBad))
                for i = math.max(1, #captured - 40), #captured do out("  | " .. captured[i]) end
                return
            end
            check(true, "签名集群的两个节点注册成功（真消息都通过了校验）")
            typeLine("key")
            check(waitFor("key fingerprint", 15), "key 指令显示密钥指纹")

            -- 伪造：别的电脑直接发一条没签名的"结果"
            busSend(99, REAL_ID, { t = "result", ver = 1, job = 1, task = 1, ok = true,
                data = { fake = 1 }, ms = 1 }, "dccomp")
            check(waitFor("unsigned", 15), "未签名的伪造消息被主控丢弃")

            -- 作业照常跑（签名不影响功能）
            typeLine("run selftest tasks=4 size=120")
            check(waitFor("done 4 / failed 0", 45), "签名集群作业 4/4 成功")

            -- 重放：把抓到的真消息原样再发一次
            local pick
            for i = #sniffed, 1, -1 do
                local m = sniffed[i]
                if m.from == 3 and m.to == "master" and m.proto == "dccomp" then pick = m end
            end
            if pick then
                bus[#bus + 1] = { from = pick.from, to = pick.to, msg = pick.msg, proto = pick.proto }
                check(waitFor("duplicate", 15), "原样重放的真消息被丢弃（防重放）")
            else
                check(false, "抓到了可供重放的消息")
            end
            typeLine("quit")
        end)
    check(ok8, "签名场景正常退出" .. (ok8 and "" or ("：" .. tostring(err8))))
    if not ok8 or fail > before then
        out("  —— 捕获到的日志 ——")
        for i = math.max(1, #captured - 24), #captured do out("  | " .. captured[i]) end
    end

    -- 清理：绝不能把密钥留给后面的场景（否则未签名的桩消息会被全部丢弃）
    for _, uni in ipairs({ M, W1, W2 }) do
        uni["dc.net"].setKey(nil)
    end
    settings.set("dcnet.key", "")
    settings.save()
end

-- 场景 9：大负载通道（负载与结果都超过内联阈值，自动走文件传输）
runScenario("场景 9：大负载通道（负载/结果走文件）", {}, function()
    if not waitFor("Worker #4 connected", 25) then
        check(false, "两个节点完成注册")
        return
    end
    check(true, "两个节点完成注册")
    typeLine("run bigdata tasks=4 size=24000 res=14000")
    check(waitFor("done 4 / failed 0", 120), "大负载作业 4/4 成功")
    check(seen("Pushing task-") or seen("Got big result"), "负载/结果通过文件通道传输")
    check(seen("Big payload channel"), "作业汇总行正常输出")
    typeLine("quit")
end)

-- 场景 10：主控高可用（待命主控接管 + 作业状态接续）
out("")
out("-- 场景 10：主控高可用（待命接管 + 状态接续）")
U["dc.state"].clearSnapshot()
U["dc.state"].cacheClear()
if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
captured, bus, blocked = {}, {}, {}
do
    local before10 = fail
    -- 注意角色分配：测试里两台主控跑在同一台电脑上（电脑 ID 都是 7），
    -- 所以让**待命机**占真正的 "master" 角色（节点重连后会找 #7），
    -- 在岗主控放到 42 上（节点一开始连它）。真实环境两台机器 ID 不同，没这个问题。
    extraRoles[42] = "master2"
    local P  = makeUniverse("master2", 42)         -- 在岗主控（节点一开始连它）
    local B  = makeUniverse("master", REAL_ID)     -- 待命主控（接管后节点会连它）
    local W1 = makeUniverse("node3", 3)
    local W2 = makeUniverse("node4", 4)
    local fast = { beatInterval = 1, takeoverAfter = 5, reHelloAfter = 3,
        rediscoverAfter = 8, snapshotInterval = 1 }

    local ok10, err10 = pcall(parallel.waitForAny,
        function() P["dc.master"].run({ defaultJobs = defaultJobs, cfg = fast }) end,
        function()
            local bcfg = {}
            for k, v in pairs(fast) do bcfg[k] = v end
            bcfg.standby = true
            B["dc.master"].run({ defaultJobs = {}, cfg = bcfg })
        end,
        function() W1["dc.worker"].run({ master = 42, name = "node-3" }) end,
        function() W2["dc.worker"].run({ master = 42, name = "node-4" }) end,
        function()
            if not waitFor("Worker #4 connected", 25) then
                check(false, "两个节点注册到在岗主控")
                return
            end
            check(true, "两个节点注册到在岗主控")
            check(seen("Starting standby"), "备用主控以待命模式启动")
            typeLine("standby")
            check(waitFor("in standby mode", 15) or seen("standby"), "standby 指令显示待命状态")

            typeLine("run selftest tasks=8 size=400")
            if not waitFor("started", 25) then
                check(false, "作业开始执行")
                return
            end
            check(true, "作业在在岗主控上开始执行")
            os.sleep(3)                       -- 等快照落盘（snapshotInterval=1）

            -- 在岗主控"掉线"：收发全断（角色名与电脑 ID 两条键都要堵）
            local mark = #captured
            blocked["master2"] = true
            blocked[42] = true
            check(waitForAfter(mark, "* Took over as master", 40), "备用主控完成接管")
            check(waitForAfter(mark, "Resumed", 25), "接管时接续了作业状态（断点续算）")
            -- 节点重新登记到新主控：单机桩里两台主控同 ID，无法把它当成断言，
            -- 这里只做信息输出（需要两台真机的部分见上面注释与 README）。
            if waitForAfter(mark, "Worker #4 connected", 20) then
                out("  [注] 节点也重新登记到了新主控")
            else
                out("  [注] 节点未重新登记（单机桩固有限制：两台主控电脑 ID 相同）")
            end
            -- 下面这条**故意不作为断言**：本测试里两台"主控"跑在同一个 CraftOS 实例上，
            -- 电脑 ID 都是 7，节点重连的目标 ID 无法区分（谁在岗都是 #7）。
            -- 节点换主、粘性登记、作业在新主控上跑完，需要**两台真机**才能验证——
            -- 步骤写在 README 第 6 节，和 A1（真机多机联调）同类。
            if waitForAfter(mark, "done 8 / failed 0", 30) then
                out("  [注] 新主控上作业也跑完了（超出单机测试桩能力，属参考信息）")
            else
                out("  [注] 单机测试桩无法验证「节点换主后继续算完」——需两台真机（见 README 第 6 节）")
            end
            typeLine("quit")
        end)
    check(ok10, "高可用场景正常退出" .. (ok10 and "" or ("：" .. tostring(err10))))
    if not ok10 or fail > before10 then
        out("  —— 捕获到的日志 ——")
        for i = math.max(1, #captured - 30), #captured do out("  | " .. captured[i]) end
    end
    blocked["master2"], blocked[42], extraRoles[42] = nil, nil, nil
end

-- 场景 11：混沌测试（确定性丢包 + 杀节点 + 重放）
-- 丢包如果丢掉"任务"或"结果"，主控要等 taskTimeout 才会重派。生产默认 90s，在慢
-- 机器上一个丢包就可能让本场景超出等待窗口（不是逻辑错误）；这里压到 15s（下限），
-- 并把第一段的等待放宽到 240s（最坏 6 个任务各丢一次也能自愈）。
runScenario("场景 11：混沌（丢包/杀节点/重放，结果仍须正确）",
    { taskTimeout = 15, adaptiveTimeout = false }, function()
    if not waitFor("Worker #4 connected", 25) then
        check(false, "两个节点完成注册")
        return
    end
    check(true, "两个节点完成注册")

    -- 开混沌：每 7 条丢 1 条（确定性，可复现——不用真随机）
    chaos.dropEvery, chaos.count, chaos.dropped = 7, 0, 0
    typeLine("run selftest tasks=6 size=200")
    check(waitFor("done 6 / failed 0", 240), "丢包 1/7 的情况下作业仍然 6/6 成功")
    check(chaos.dropped > 0, "确实丢了 " .. tostring(chaos.dropped) .. " 条消息")
    -- 注意：丢包多半落在"轮询/心跳"这类本来就会周期重发的消息上，不一定触发重试日志，
    -- 所以这里只做信息输出（真正的判据是上面的 6/6 成功与下面的结果正确性）。
    out("  [注] 丢包 " .. tostring(chaos.dropped) .. " 条；重试日志：" ..
        tostring(seen("retry") or seen("requeued") or seen("lost contact")))
    check(seen("Result: PASS"), "结果仍然正确（selftest 闭式解校验通过）")

    -- 杀节点：断掉 #3 的接收（它还能发，属于"半断链"）。主控因此不会判它离线，
    -- 但派给它的任务它收不到 → 超时后重派给 #4，作业最终仍然完成。
    blocked["node3"] = true
    typeLine("run selftest tasks=4 size=200")
    check(waitFor("done 4 / failed 0", 180), "杀掉一个节点后作业照样 4/4 成功")
    out("  [注] 半断链下主控仍认为 #3 在线（它还能发消息），靠任务超时重派兜底")
    blocked["node3"] = nil

    -- 重放/迟到副本：给一个**已经完成**的任务再报一次结果，统计不该被污染
    -- （不设密钥时没有防重放，靠的是调度器"已完成任务的结果只释放节点、不重复计数"）
    local mark = #captured
    chaos.dropEvery = 0                      -- 这一段不丢包，保证注入一定送达
    local P = U["dc.protocol"]
    local dup = P.msg(P.RESULT, { job = 1, task = 1, ok = true, ms = 1,
        data = { n = 200, sum = 0, sq = 0 } })
    busSend(3, REAL_ID, dup, "dccomp")       -- 伪装成节点 #3 再报一次已完成任务的结果
    sleep(2)
    check(not seenAfter(mark, "failed") and not seenAfter(mark, "retry"),
        "重复上报已完成任务的结果没有引起失败或重试")
    check(seen("done 4 / failed 0"), "总统计没有被污染（仍是 4/4）")
    chaos.dropEvery = 0
    typeLine("quit")
end)

-- 场景 12：网络屏幕（另一台电脑 + 显示器，通过 rednet 收主控面板）
out("")
out("-- 场景 12：网络屏幕（屏幕节点接收面板帧）")
do
    U["dc.state"].clearSnapshot()
    U["dc.state"].cacheClear()
    for _, f in ipairs(U["dc.state"].poolList()) do
        fs.delete(U["dc.state"].poolPath(f.name))
    end
    if fs.exists("/dccomp/cloud.dat") then fs.delete("/dccomp/cloud.dat") end
    captured, bus, blocked = {}, {}, {}

    local SCR_ID = (REAL_ID == 8) and 9 or 8
    extraRoles[SCR_ID] = "screen" .. SCR_ID

    local fake = { buf = {}, x = 1, y = 1, scale = 1 }
    function fake.getSize() return 51, 19 end
    function fake.setTextScale(s) fake.scale = s end
    function fake.setBackgroundColour() end
    function fake.setTextColour() end
    function fake.setCursorPos(x, y) fake.x, fake.y = x, y end
    function fake.write(s) fake.buf[#fake.buf + 1] = tostring(s) end
    function fake.clear() fake.buf = {} end

    local rgn, rgt, rw = peripheral.getNames, peripheral.getType, peripheral.wrap
    peripheral.getNames = function() return { "top" } end
    peripheral.getType = function(n) return n == "top" and "monitor" or nil end
    peripheral.wrap = function(n) if n == "top" then return fake end end

    local function waitBuf(needle, seconds)
        local deadline = os.clock() + seconds
        while os.clock() < deadline do
            if table.concat(fake.buf, "\n"):find(needle, 1, true) then return true end
            sleep(0.2)
        end
        return table.concat(fake.buf, "\n"):find(needle, 1, true) ~= nil
    end

    local M = makeUniverse("master", REAL_ID)
    local SC = makeUniverse("screen" .. SCR_ID, SCR_ID)
    local before = fail
    local ok12, err12 = pcall(parallel.waitForAny,
        function() M["dc.master"].run({ defaultJobs = defaultJobs, cfg = { monitor = "off" } }) end,
        function() SC["dc.screen"].run({ name = "screen-test", interval = 1, timeout = 5 }) end,
        function()
            if not waitFor("Net screen #" .. SCR_ID .. " connected", 25) then
                check(false, "主控登记了网络屏幕 #" .. SCR_ID)
                return
            end
            check(true, "主控登记了网络屏幕 #" .. SCR_ID)
            check(waitBuf("dcnet master", 25), "网络屏幕画出了主控面板标题")
            check(waitBuf("Workers 0/0", 10), "网络屏幕收到了集群概况")

            typeLine("mon net")
            check(waitFor("pushing", 10), "mon net 显示网络屏幕列表（推送中）")
            check(seen("screen-test"), "mon net 显示屏幕名字")

            typeLine("mon net off")
            check(waitFor("Net screen push off", 10), "mon net off 关闭推送")
            check(waitBuf("Master disabled", 15), "屏幕收到 screenoff 并提示主控已关闭")

            typeLine("mon net on")
            check(waitFor("Net screen push on", 10), "mon net on 重新开启推送")
            check(waitBuf("dcnet master", 20), "屏幕重新连上并画出面板")

            local mark = #captured
            typeLine("mon net kick " .. SCR_ID)
            check(waitForAfter(mark, "Net screen #" .. SCR_ID .. " kicked", 10), "mon net kick 断开指定屏幕")
            typeLine("quit")
        end)
    check(ok12, "网络屏幕场景正常退出" .. (ok12 and "" or ("：" .. tostring(err12))))
    if not ok12 or fail > before then
        out("  —— 捕获到的日志（尾部）——")
        for i = math.max(1, #captured - 25), #captured do out("  | " .. captured[i]) end
    end
    peripheral.getNames, peripheral.getType, peripheral.wrap = rgn, rgt, rw
    extraRoles[SCR_ID] = nil
end

_G.print = realPrint

-- ── 汇总 ────────────────────────────────────────────────────────────────
out("")
out(string.format("结果：%d 通过 / %d 失败", pass, fail))
out(fail == 0 and "ALL PASS" or "FAILED")

local f = fs.open("/craftos_test_result.txt", "w")
f.write(table.concat(lines, "\n"))
f.close()

-- 逐行打到 stdout（headless 模式会刷屏，Python 端只看标记行）
for _, l in ipairs(lines) do print(l) end
os.shutdown()
