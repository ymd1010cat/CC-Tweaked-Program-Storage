--[[- dc.master — 主控

进程结构（parallel，四个协作协程）：

  netLoop    "dccomp" 协议的唯一接收循环：hello / pull / result / progress / bye
  pushLoop   "dcpush" 协议的唯一接收循环：新节点拉取 worker.lua 的 fetch + 传输确认
  tickLoop   定时器：调度超时检查、推送状态机、状态栏刷新
  uiLoop     命令行（read），处理 run / status / push / halt 等指令

「唯一接收循环」很重要：CC 的 parallel 会把同一个事件分发给所有 filter 匹配的
协程，如果开两个 rednet.receive("dccomp") 循环，同一条消息会被处理两次。
]]

local util    = dc_require("dc.util")
local proto   = dc_require("dc.protocol")
local net     = dc_require("dc.net")
local jobs    = dc_require("dc.jobs")
local xfer    = dc_require("dc.xfer")
local sched   = dc_require("dc.sched")
local console = dc_require("dc.console")
local state   = dc_require("dc.state")
local cloud   = dc_require("dc.cloud")
local panel   = dc_require("dc.panel")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local COMMANDS = {
    "help", "status", "workers", "jobs", "run", "run!", "queue", "result",
    "cancel", "pause", "resume", "pri", "limit", "redun", "set", "cfg", "net",
    "state", "cache", "history", "top", "cloud", "mon", "repo", "pull", "pullall",
    "setkey", "key", "standby",
    "push", "kick", "halt", "reboot", "save", "clear", "quit",
}

--- opts: { defaultJobs = { ["primes.lua"] = "源码", ... }, cfg = {...} }
function M.run(opts)
    opts = opts or {}

    -- ── 网络 ─────────────────────────────────────────────────────────
    -- 打开所有 modem：一条网段挂一个，就能把互相隔离的多段有线网络桥接起来
    local modems, failedModems = net.openAll()
    if #modems == 0 then
        printError("[dcnet] 没有检测到调制解调器（modem）")
        print("[dcnet] 有线网络接法：电脑旁放有线调制解调器，调制解调器上接网络线缆，")
        print("[dcnet] 所有机器串到同一段线缆上即可；要多网段就给主控挂多个 modem。")
        return false
    end

    -- ── 示例作业 ─────────────────────────────────────────────────────
    util.ensureDir(util.JOB_DIR)
    util.ensureDir(util.OUT_DIR)
    local created = jobs.installDefaults(opts.defaultJobs)

    -- ── 界面 ─────────────────────────────────────────────────────────
    -- headless：ush 包可以用 `dcnet master --headless` 当后台服务跑，
    -- 日志落到 <root>/logs/master.log，不碰终端。
    local ui
    if opts.headless then
        ui = console.null({ title = "dcnet master", logFile = util.ROOT .. "/logs/master.log" })
    else
        ui = console.new({ title = "dcnet master" })
    end
    ui:setStatus("主控启动中…")
    ui:log(string.format("dcnet 主控 v%s   本机 ID #%d", util.VERSION, os.getComputerID()),
        col("lime", 32))
    ui:log(string.format("网络：已打开 %s（%s）", net.describe(modems),
        (function()
            local t = {}
            for _, md in ipairs(modems) do t[#t + 1] = md.name end
            return table.concat(t, ",")
        end)()))

    -- 共享密钥（可选）：设了就启用消息签名与防重放
    local savedKey = rawget(_G, "DCNET_KEY") or settings.get("dcnet.key")
    if savedKey and savedKey ~= "" then
        local kok, kerr = net.setKey(savedKey)
        if kok then
            ui:log("消息签名已启用（密钥指纹 " .. tostring(net.fingerprint()) ..
                "），未签名/重复消息会被丢弃", col("lime", 32))
        else
            ui:log("启用消息签名失败：" .. tostring(kerr), col("orange", 2))
        end
    end
    for _, e in ipairs(failedModems or {}) do
        ui:log("  打开 modem 失败：" .. e, col("orange", 2))
    end
    if #created > 0 then
        ui:log("已释放示例作业到 " .. util.JOB_DIR .. "：" .. table.concat(created, ", "),
            col("lightBlue", 512))
    end
    local avail = jobs.list()
    ui:log(string.format("可用作业 %d 个：%s", #avail,
        table.concat((function()
            local t = {}
            for _, j in ipairs(avail) do t[#t + 1] = j.name end
            return t
        end)(), " ")))
    ui:log("输入 help 查看指令。")

    -- ── 调度器 ───────────────────────────────────────────────────────
    -- 配置优先级：默认值 < settings 里的持久化值 < 命令行参数
    local cfg = util.loadCfg(sched.DEFAULTS, sched.CFG_META)
    for k, v in pairs(opts.cfg or {}) do cfg[k] = v end

    local S = sched.new({
        cfg = cfg,
        log = function(text, colour) ui:log(text, colour) end,
        onFinished = function(job)
            -- 结果落盘，便于主控重启后查阅
            local path = string.format("%s/job-%d-%s.txt", util.OUT_DIR, job.id, job.name)
            local lines = {
                string.format("# 作业 %d  %s", job.id, job.name),
                string.format("# 参数: %s", jobs.paramHelp(job.def)),
                string.format("# 状态: %s  任务 %d 成功 / %d 失败  用时 %s",
                    job.state, job.counts.done, job.counts.failed, util.duration(job.durationMs)),
                "",
                job.resultText or tostring(job.error or ""),
            }
            local ok = util.writeFile(path, table.concat(lines, "\n") .. "\n")
            if ok then ui:log("结果已保存：" .. path, col("lightGray", 1024)) end
        end,
    })

    local M0 = {
        ui = ui, sched = S,
        reg = xfer.newRegistry(),   -- 分块传输的发送队列（由唯一的接收循环推进）
        quit = false,
        halted = false,
        -- 高可用：standby 只盯心跳不干活；active 才接受节点注册、派任务
        masterId = os.getComputerID(),
        mode = "active",
        lastBeatAt = util.mono(),   -- 最近一次听到在岗主控心跳的时刻
        lastBeatSent = 0,
        activeMaster = nil,
        tookOver = 0,
    }

    -- ── 云端卸载 ─────────────────────────────────────────────────────
    local CL = cloud.new({
        sched = S, cfg = S.cfg,
        log = function(text, colour) ui:log(text, colour) end,
    })
    CL:registerWorkers()
    if not CL.ok then
        ui:log("云端卸载不可用：" .. tostring(CL.reason), col("orange", 2))
    elseif #CL.endpoints > 0 then
        local names = {}
        for _, ep in ipairs(CL.endpoints) do names[#names + 1] = ep.name end
        ui:log(string.format("云端端点 %d 个：%s（cloud 查看详情）", #CL.endpoints,
            table.concat(names, ",")), col("lightBlue", 512))
    end

    -- ── 大屏面板 ─────────────────────────────────────────────────────
    local PN = panel.new({
        log = function(text, colour) ui:log(text, colour) end,
        scale = tonumber(S.cfg.monitorScale) or panel.DEFAULT_SCALE,
    })
    local monCfg = tostring(S.cfg.monitor or "")
    if monCfg ~= "off" then
        local ok, which
        if monCfg ~= "" then
            ok, which = PN:attach(monCfg)
            if not ok then ui:log("挂载显示器失败：" .. tostring(which), col("orange", 2)) end
        else
            ok, which = pcall(PN.attachAuto, PN)
            if ok and which then
                ui:log("已自动挂载显示器：" .. tostring(which) .. "（mon off 可关闭）",
                    col("lightBlue", 512))
            end
        end
    end
    if PN:attached() then PN:redraw(S, CL, true) end

    -- ── 推送文件（worker.lua / 作业 / 大负载） ────────────────────────
    -- 发送端统一登记到 M0.reg，由唯一的 dcpush 接收循环推进（见 xfer.lua 的说明）。
    local function startPush(target, path, what)
        local data, err = util.readFile(path)
        if not data then
            ui:log("推送失败：" .. tostring(err), col("red", 16384))
            return nil
        end
        local name = util.basename(path)
        local xid, eerr = xfer.enqueue(M0.reg, target, name, what or "worker", data,
            function(state, self)
                if state ~= "ok" then
                    ui:log(string.format("推送 %s 到 #%d 失败：%s",
                        self.name, self.target, tostring(self.err)), col("red", 16384))
                elseif what == "worker" then
                    ui:log(string.format("已推送 %s 给节点 #%d（%s）",
                        self.name, self.target, util.bytes(#data)), col("lime", 32))
                    ui:log("  节点仍在跑旧代码，需要 reboot #" .. self.target .. " 才会加载新版本",
                        col("lightGray", 1024))
                else
                    ui:log(string.format("已把 %s 推给 #%d（%s）",
                        self.name, self.target, util.bytes(#data)), col("lightGray", 1024))
                end
            end)
        if not xid then
            ui:log("推送失败：" .. tostring(eerr), col("red", 16384))
            return nil
        end
        ui:log(string.format("开始推送 %s → #%d（%s）",
            name, target, util.bytes(#data)), col("lightGray", 1024))
        return xid
    end

    -- ── 指令 ─────────────────────────────────────────────────────────
    local function cmdHelp()
        local lines = {
            "  help                    显示本帮助",
            "  status                  作业总览 + 节点列表",
            "  workers                 只看节点列表",
            "  jobs                    列出 /dccomp/jobs 下的作业",
            "  run <作业> [参数..] [pri=N]",
            "                          提交作业，例如 run primes to=2000000 pri=5",
            "  run! <作业> ...         同上但跳过结果缓存（强制重算）",
            "  queue                   查看作业队列",
            "  result [作业号]          查看某个作业的结果（缺省=最近完成的）",
            "  cancel <作业号>          取消作业",
            "  pause [作业号]           暂停派发（不带作业号=全部）",
            "  resume [作业号]          恢复派发",
            "  pri <作业号> <优先级>    调整优先级（高者先抢任务）",
            "  limit [N]               同时执行几个作业（并发上限）",
            "  redun [N]               抢尾冗余派发阈值（0=关，抑制慢节点拖尾）",
            "  set <配置项> <值>        改配置并持久化（cfg 看全部）",
            "  cfg                     显示当前生效的全部配置",
            "  net                     显示 modem / 网络情况",
            "  state [save|clear]      断点续算快照的状态 / 立即写 / 清除",
            "  cache [clear]           结果缓存列表 / 清空",
            "  history [N]             最近的作业运行历史",
            "  top [N]                 节点累计贡献排行（跨会话）",
            "  cloud                   云端端点列表与状态",
            "  cloud add <名字> <url> [并发]   注册一个 HTTP 计算服务（持久化）",
            "  cloud del <名字>        删除端点",
            "  cloud test <名字>       探活（GET 一次）",
            "  mon [名字|off]          挂载/关闭 monitor 大屏面板（持久化）",
            "  setkey <密钥>           启用消息签名（防冒充/防重放，各机器设成一样）",
            "  key                     查看签名状态、密钥指纹与丢弃统计",
            "  standby [on|off]        待命主控：在岗主控掉线时自动接管并接续作业",
            "  repo <主控ID>           查询另一台主控的作业仓库",
            "  pull <主控ID> <作业名…> 从它那里拉作业（自动补 .lua）",
            "  pullall <主控ID>        只拉本地没有的（先 repo 看清单）",
            "  push [节点ID..]          把 " .. util.WORKER_FILE .. " 推给节点（升级用）",
            "  reboot [节点ID..]        让节点重启电脑（配合 push 加载新代码）",
            "  kick <节点ID>            让某个节点退出",
            "  halt                    让所有节点退出",
            "  save <作业号> [路径]     结果另存为文件",
            "  clear                   重绘界面",
            "  quit                    关闭主控（节点会保留，重启主控后自动重连）",
        }
        for _, l in ipairs(lines) do ui:log(l) end
    end

    local function cmdJobList()
        local list = jobs.list()
        if #list == 0 then
            ui:log("（" .. util.JOB_DIR .. " 下没有作业文件）")
            return
        end
        for _, j in ipairs(list) do
            local def = j.ok and jobs.loadName(j.name) or nil
            ui:log(string.format("  %-12s %s", j.name, j.summary))
            if def and j.params and #j.params > 0 then
                local parts = {}
                for _, p in ipairs(j.params) do
                    parts[#parts + 1] = string.format("%s=%s", p.name, tostring(p.default))
                end
                ui:log(string.format("              参数：%s", table.concat(parts, "  ")))
            end
        end
    end

    local function cmdRun(toks, nocache)
        local name = toks[1]
        if not name then
            ui:log("用法：run <作业名> [参数..] [pri=N]（用 jobs 查看可用作业）", col("orange", 2))
            return
        end
        -- pri=N / prio=N 是调度器选项，不属于作业参数，先摘出来
        local rest, pri = {}, 0
        for i = 2, #toks do
            local v = tostring(toks[i]):match("^prio?=(%-?%d+)$")
            if v then pri = tonumber(v) or 0 else rest[#rest + 1] = toks[i] end
        end
        local def, err = jobs.loadName(name)
        if not def then
            ui:log("加载作业失败：" .. tostring(err), col("red", 16384))
            return
        end
        local job, err2 = S:addJob(def, rest, { priority = pri, nocache = nocache })
        if not job then
            ui:log("提交失败：" .. tostring(err2), col("red", 16384))
        elseif S:onlineCount() == 0 then
            ui:log("提示：当前没有节点在线，作业会排队等待节点接入。", col("orange", 2))
        end
    end

    local function lastFinishedJob()
        for i = #S.jobOrder, 1, -1 do
            local j = S.jobs[S.jobOrder[i]]
            if j and (j.state == "done" or j.state == "failed") then return j end
        end
        return nil
    end

    local function cmdResult(toks)
        local id = tonumber(toks[1])
        local job = id and S.jobs[id] or lastFinishedJob()
        if not job then
            ui:log("还没有完成的作业。", col("orange", 2))
            return
        end
        ui:log(string.format("作业 #%d %s（%s）参数：%s", job.id, job.name,
            job.state, jobs.paramHelp(job.def)), col("lightBlue", 512))
        ui:log(string.format("任务 %d 成功 / %d 失败，用时 %s",
            job.counts.done, job.counts.failed, util.duration(job.durationMs or 0)))
        for _, line in ipairs(S:failedTaskLines(job.id, 5)) do ui:log(line, col("red", 16384)) end
        if job.resultText then
            for _, line in ipairs(util.split(job.resultText, "\n")) do ui:log("  " .. line) end
        elseif job.error then
            ui:log("  " .. job.error, col("red", 16384))
        else
            ui:log("  （作业还没有结束）", col("orange", 2))
        end
    end

    local function targetWorkers(toks)
        local list = {}
        if #toks == 0 then
            for _, w in ipairs(S:workerList()) do
                if w.state ~= "offline" then list[#list + 1] = w end
            end
        else
            for _, t in ipairs(toks) do
                -- 注意括号：gsub 返回 (字符串, 替换次数)，不加括号会把次数当成 tonumber 的进制
                local id = tonumber((tostring(t):gsub("^#", "")))
                if id and S.workers[id] then list[#list + 1] = S.workers[id] end
            end
        end
        return list
    end

    local function dispatch(line)
        local toks = util.tokenize(line)
        local c = toks[1]
        if not c then return end
        table.remove(toks, 1)

        if c == "help" or c == "?" then
            cmdHelp()
        elseif c == "status" or c == "st" then
            ui:logLines(S:jobLines())
            ui:logLines(S:workerLines())
        elseif c == "workers" then
            ui:logLines(S:workerLines())
        elseif c == "jobs" then
            cmdJobList()
        elseif c == "run" or c == "run!" then
            cmdRun(toks, c == "run!")
        elseif c == "queue" or c == "q" then
            ui:logLines(S:jobLines())
        elseif c == "result" or c == "res" then
            cmdResult(toks)
        elseif c == "cancel" then
            local id = tonumber(toks[1])
            if not id then ui:log("用法：cancel <作业号>", col("orange", 2)) else
                local ok, err = S:cancel(id)
                if not ok then ui:log("取消失败：" .. tostring(err), col("red", 16384)) end
            end
        elseif c == "pause" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, true)
                if not ok then ui:log("暂停失败：" .. tostring(err), col("red", 16384)) end
            else
                S.paused = true
                ui:log("已暂停全部派发（正在执行的任务不受影响）。", col("orange", 2))
            end
        elseif c == "resume" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, false)
                if not ok then ui:log("恢复失败：" .. tostring(err), col("red", 16384)) end
            else
                S.paused = false
                ui:log("已恢复派发。", col("lime", 32))
            end
        elseif c == "pri" then
            local id, pri = tonumber(toks[1]), tonumber(toks[2])
            if not id or not pri then ui:log("用法：pri <作业号> <优先级>", col("orange", 2))
            else
                local ok, err = S:setPriority(id, pri)
                if not ok then ui:log("设置失败：" .. tostring(err), col("red", 16384)) end
            end
        elseif c == "limit" or c == "redun" then
            local key = (c == "limit") and "maxParallel" or "redundancy"
            local v = toks[1]
            if not v then
                ui:log(string.format("%s = %s", key, tostring(S.cfg[key])), col("lightBlue", 512))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then ui:log("设置失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s（已持久化）", key, tostring(S.cfg[key])), col("lime", 32))
                    S:pump()
                end
            end
        elseif c == "set" then
            local key, v = toks[1], toks[2]
            if not key or v == nil then
                ui:log("用法：set <配置项> <值>（用 cfg 看全部配置项）", col("orange", 2))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then
                    ui:log("设置失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s（已持久化，重启后仍生效）", key, tostring(S.cfg[key])),
                        col("lime", 32))
                end
            end
        elseif c == "cfg" then
            ui:logLines(util.cfgLines(S.cfg, sched.CFG_META))
        elseif c == "net" then
            ui:log(string.format("已打开 modem：%s", net.describe(modems)))
            for _, md in ipairs(modems) do
                ui:log(string.format("  %-8s %s", md.name, md.wireless and "无线" or "有线"))
            end
            ui:log(string.format("在线节点 %d / 登记 %d", S:onlineCount(), S:workerCount()))
            if net.hasKey() then
                ui:log("消息签名：已启用，密钥指纹 " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("消息签名：未启用（setkey <密钥> 可以打开）", col("orange", 2))
            end
            ui:logLines(net.statsLines())
        elseif c == "state" then
            local sub = toks[1]
            if sub == "clear" then
                state.clearSnapshot()
                ui:log("已清除快照（下次启动不再续算）。", col("lime", 32))
            elseif sub == "save" then
                local ok, err = S:saveSnapshot()
                ui:log(ok and "快照已写入。" or ("快照失败：" .. tostring(err)),
                    ok and col("lime", 32) or col("red", 16384))
            else
                local size = util.exists(state.SNAP) and fs.getSize(state.SNAP) or 0
                ui:log(string.format("快照：%s（%s）", state.SNAP,
                    size > 0 and util.bytes(size) or "无"))
                local pending = 0
                for _, j in pairs(S.jobs) do
                    if j.state == "queued" or j.state == "running" then pending = pending + 1 end
                end
                ui:log(string.format("未完成作业 %d 个；有变化时每 ≥3s 自动写一次，兜底 %ds",
                    pending, S.cfg.snapshotInterval))
                ui:log("  state save 立即写 / state clear 清除 / set snapshot false 关闭")
            end
        elseif c == "cache" then
            if toks[1] == "clear" then
                ui:log(string.format("已清除 %d 条结果缓存。", state.cacheClear()), col("lime", 32))
            else
                local list = state.cacheList()
                ui:log(string.format("结果缓存 %d 条（%s）：", #list, state.CACHE_DIR))
                for i = 1, math.min(#list, 8) do
                    local e = list[i].entry
                    ui:log(string.format("  %s  %-10s %s前", list[i].key, tostring(e and e.job or "?"),
                        util.duration(util.now() - ((e and e.at) or util.now()))))
                end
                ui:log("  cache clear 清空 / run! 跳过缓存 / set cache false 关闭")
            end
        elseif c == "repo" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            if not id then
                ui:log("用法：repo <主控ID>（列出对方有哪些作业）", col("orange", 2))
            else
                net.send(id, proto.msg(proto.REPO, {}), util.PROTO_CTRL)
                ui:log("已向 #" .. id .. " 查询作业仓库…", col("lightBlue", 512))
            end
        elseif c == "pull" or c == "pullall" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            local names = {}
            if c == "pullall" then
                if not id or not M0.lastRepo or M0.lastRepo.target ~= id then
                    ui:log("用法：先 repo <主控ID> 看清单，再 pullall <主控ID>", col("orange", 2))
                    id = nil
                else
                    for _, j in ipairs(M0.lastRepo.jobs) do
                        local name = tostring(j.name or "")
                        if not util.exists(util.JOB_DIR .. "/" .. name) then names[#names + 1] = name end
                    end
                    if #names == 0 then
                        ui:log("对方的作业本地都有了。", col("lime", 32))
                        id = nil
                    end
                end
            elseif id then
                for i = 2, #toks do
                    local name = tostring(toks[i])
                    if not name:match("%.lua$") then name = name .. ".lua" end
                    names[#names + 1] = name
                end
            end
            if id and #names == 0 then
                ui:log("用法：pull <主控ID> <作业名…>（自动补 .lua）", col("orange", 2))
                id = nil
            end
            for _, name in ipairs(names) do
                -- 借 dcpush 协议做分块传输，对方在主控上会走 "FETCH what=job" 分支
                net.send(id, proto.msg(proto.FETCH, {
                    xid = net.newXid("job"), what = "job", name = name,
                }), util.PROTO_PUSH)
                ui:log("请求拉取作业 " .. name .. " …", col("lightBlue", 512))
            end
        elseif c == "standby" then
            local sub = tostring(toks[1] or "")
            if sub == "on" or sub == "true" then
                util.saveCfg("standby", true)
                S.cfg.standby = true
                ui:log("已设为待命主控（下次启动生效）：只盯心跳，在岗主控掉线就接管",
                    col("lime", 32))
            elseif sub == "off" or sub == "false" then
                util.saveCfg("standby", false)
                S.cfg.standby = false
                ui:log("已取消待命设置（下次启动直接当在岗主控）", col("lime", 32))
            else
                ui:log(string.format("高可用：本机 #%d 当前是 %s 模式%s",
                    M0.masterId, M0.mode == "standby" and "待命" or "在岗",
                    M0.activeMaster and ("，最近看到在岗主控 #" .. tostring(M0.activeMaster)) or ""))
                ui:log(string.format("  心跳间隔 %ss，接管阈值 %ss（set beatInterval / takeoverAfter 可调）",
                    tostring(S.cfg.beatInterval), tostring(S.cfg.takeoverAfter)))
                ui:log("  standby on|off：本机默认以待命模式启动（会持久化）")
                if M0.mode == "standby" then
                    ui:log(string.format("  已静默 %.1f 秒", util.mono() - M0.lastBeatAt))
                elseif M0.tookOver and M0.tookOver > 0 then
                    ui:log("  本机是接管上来的（原主控掉线）", col("orange", 2))
                end
            end
        elseif c == "setkey" then
            local k = toks[1]
            if not k then
                ui:log("用法：setkey <共享密钥>（至少 8 位；各机器设成同一个才会互相接受）",
                    col("orange", 2))
                ui:log("  setkey off 关闭签名；节点上用 CC 自带的 set dcnet.key <密钥>",
                    col("lightGray", 1024))
            elseif k == "off" or k == "none" then
                net.setKey(nil)
                settings.set("dcnet.key", "")
                settings.save()
                ui:log("已关闭消息签名（同网段任何人都能冒充主控/节点）", col("orange", 2))
            else
                local ok2, kerr = net.setKey(k)
                if not ok2 then
                    ui:log("设置失败：" .. tostring(kerr), col("red", 16384))
                else
                    settings.set("dcnet.key", k)
                    settings.save()
                    ui:log("已启用消息签名，密钥指纹 " .. tostring(net.fingerprint()),
                        col("lime", 32))
                    ui:log("  其它机器要用同一个密钥（主控 setkey / 节点 set dcnet.key），" ..
                        "核对指纹一致即可", col("lightGray", 1024))
                end
            end
        elseif c == "key" then
            if net.hasKey() then
                ui:log("消息签名：已启用，密钥指纹 " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("消息签名：未启用（同网段任何程序都能冒充主控或节点）", col("orange", 2))
                ui:log("  用 setkey <共享密钥> 打开；自己单机玩可以不开", col("lightGray", 1024))
            end
            ui:logLines(net.statsLines())
            if M0.dropped then ui:log("  本机总计丢弃 " .. M0.dropped .. " 条消息") end
        elseif c == "mon" then
            local sub = toks[1]
            if sub == "off" then
                local old = PN:detach()
                util.saveCfg("monitor", "off")
                S.cfg.monitor = "off"
                ui:log("已关闭大屏面板" .. (old and ("（" .. tostring(old) .. "）") or ""),
                    col("lime", 32))
            elseif sub then
                local ok, err = PN:attach(sub)
                if not ok then
                    ui:log("挂载失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg("monitor", sub)
                    S.cfg.monitor = sub
                    PN:redraw(S, CL, true)
                    ui:log("已挂载显示器 " .. tostring(PN.name) ..
                        string.format("（%dx%d）", PN.w, PN.h), col("lime", 32))
                end
            else
                if PN:attached() then
                    ui:log(string.format("大屏：%s（%dx%d，缩放 %.2f）",
                        tostring(PN.name), PN.w, PN.h, PN.scale), col("lightBlue", 512))
                else
                    ui:log("当前没有挂载显示器。")
                end
                local list = panel.findMonitors()
                if #list == 0 then
                    ui:log("  没有检测到 monitor 外设（把显示器贴到主控侧面即可）")
                else
                    for _, m in ipairs(list) do
                        ui:log("  可用显示器：" .. m.name .. "（mon " .. m.name .. " 挂载）")
                    end
                end
                ui:log("  mon <名字> 挂载 / mon off 关闭（会持久化）；cfg 里的 monitor 也能改")
            end
        elseif c == "cloud" then
            local sub = toks[1]
            if sub == "add" then
                local name, url, slots = toks[2], toks[3], toks[4]
                if not name or not url then
                    ui:log("用法：cloud add <名字> <url> [并发数]", col("orange", 2))
                else
                    local ep, err = cloud.addEndpoint(CL.endpoints, name, url, slots)
                    if not ep then
                        ui:log("添加失败：" .. tostring(err), col("red", 16384))
                    else
                        CL:registerWorkers()
                        ui:log(string.format("已注册云端端点 %s → %s（%d 并发，已持久化）",
                            ep.name, ep.url, ep.slots), col("lime", 32))
                    end
                end
            elseif sub == "del" then
                local ep, err = cloud.removeEndpoint(CL.endpoints, toks[2])
                if not ep then
                    ui:log("删除失败：" .. tostring(err), col("red", 16384))
                else
                    S.workers[ep.id] = nil
                    ui:log("已删除端点 " .. tostring(ep.name), col("lime", 32))
                end
            elseif sub == "test" then
                local name = toks[2]
                if not name then
                    ui:log("用法：cloud test <名字>", col("orange", 2))
                else
                    local sent, terr = CL:test(name, function(ok2, data, e)
                        if ok2 then
                            local info = type(data) == "table" and data.status or data
                            ui:log(string.format("端点 %s 探活成功：%s", name,
                                util.trunc(tostring(info), 60)), col("lime", 32))
                        else
                            ui:log(string.format("端点 %s 探活失败：%s", name, tostring(e)),
                                col("red", 16384))
                        end
                    end)
                    if not sent then ui:log("探活没发出去：" .. tostring(terr), col("red", 16384)) end
                end
            else
                ui:logLines(CL:lines())
            end
        elseif c == "top" then
            ui:logLines(S:topLines(tonumber(toks[1]) or 10))
        elseif c == "history" then
            local n = tonumber(toks[1]) or 10
            local list, total = state.history(n)
            ui:log(string.format("运行历史（最近 %d / 共 %d 条）：", #list, total))
            for _, e in ipairs(list) do
                ui:log(string.format("  #%-3d %-12s %-4s 成功%d 失败%d  %s  %s", e.id, tostring(e.name),
                    e.state == "done" and "完成" or "失败", e.done or 0, e.failed or 0,
                    util.duration(e.ms or 0), util.trunc(tostring(e.summary or ""), 36)))
            end
        elseif c == "push" then
            local list = targetWorkers(toks)
            if #list == 0 then ui:log("没有可推送的节点。", col("orange", 2)) else
                for _, w in ipairs(list) do startPush(w.id, util.WORKER_FILE, "worker") end
                ui:log(string.format("开始向 %d 个节点推送 %s…", #list, util.WORKER_FILE))
            end
        elseif c == "kick" then
            local id = tonumber((toks[1] or ""):gsub("^#", ""))
            if not id then ui:log("用法：kick <节点ID>", col("orange", 2))
            else
                net.send(id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
                ui:log("已通知节点 #" .. id .. " 退出。", col("orange", 2))
            end
        elseif c == "halt" then
            local list = targetWorkers(toks)
            for _, w in ipairs(list) do
                net.send(w.id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
            end
            M0.halted = true
            ui:log(string.format("已通知 %d 个节点退出。", #list), col("orange", 2))
        elseif c == "reboot" then
            -- 配合 push 使用：节点重启后，startup 文件里的 shell.run 会拉起新代码
            local list = targetWorkers(toks)
            if #list == 0 then ui:log("没有可重启的节点。", col("orange", 2)) else
                for _, w in ipairs(list) do
                    net.send(w.id, proto.msg(proto.HALT, { reboot = true }), util.PROTO_CTRL)
                end
                ui:log(string.format("已通知 %d 个节点重启。", #list), col("orange", 2))
                ui:log("  注意：节点电脑必须有 /startup.lua 之类的开机自启，才能自动回到集群。",
                    col("lightGray", 1024))
            end
        elseif c == "save" then
            local id = tonumber(toks[1])
            local job = id and S.jobs[id] or lastFinishedJob()
            if not job or not job.resultText then
                ui:log("没有可保存的结果。", col("orange", 2))
            else
                local path = toks[2] or string.format("%s/job-%d-%s.txt", util.OUT_DIR, job.id, job.name)
                local ok = util.writeFile(path, job.resultText .. "\n")
                ui:log(ok and ("已保存：" .. path) or "保存失败", ok and col("lime", 32) or col("red", 16384))
            end
        elseif c == "clear" then
            ui:rebuild()
        elseif c == "quit" or c == "exit" then
            ui:log("主控退出。节点会继续等待，重新运行 master.lua 后会自动重连。", col("orange", 2))
            M0.quit = true
        else
            ui:log("未知指令：" .. c .. "（输入 help 查看帮助）", col("orange", 2))
        end
    end

    -- ── Tab 补全 ─────────────────────────────────────────────────────
    -- CC 的 read 会把补全函数的返回值**追加**到当前行尾，所以这里返回"后缀"：
    -- 输入 "run pr" + Tab → 候选 primes → 返回 "imes" → 行变成 "run primes"。
    local function suffixes(text, candidates)
        local cur = text:match("%S*$") or ""
        local out = {}
        for _, c in ipairs(candidates) do
            if c:sub(1, #cur) == cur then out[#out + 1] = c:sub(#cur + 1) end
        end
        return out
    end

    local function complete(text)
        local toks = util.tokenize(text)
        if #toks <= 1 and not text:match("%s$") then
            return suffixes(text, COMMANDS)
        end
        if toks[1] == "run" and not text:match("%s$") and #toks == 2 then
            local names = {}
            for _, j in ipairs(jobs.list()) do names[#names + 1] = j.name end
            return suffixes(text, names)
        end
        return {}
    end

    -- ── 协程 ─────────────────────────────────────────────────────────
    local function netLoop()
        while not M0.quit do
            local sender, msg = net.receive(util.PROTO_CTRL, 2)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("丢弃 #%s 的消息：%s", tostring(sender), tostring(why)),
                        col("orange", 2))
                    M0.dropped = (M0.dropped or 0) + 1
                elseif msg.t == proto.BEAT then
                    -- 在岗主控的心跳：记下来；如果对方 ID 更小，我们就该让位
                    M0.lastBeatAt = util.mono()
                    M0.activeMaster = tonumber(msg.id) or sender
                    if M0.mode == "active" and M0.activeMaster and M0.activeMaster < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("主控 #%d 在岗（ID 更小），本机退回待命模式",
                            M0.activeMaster), col("orange", 2))
                    end
                elseif msg.t == proto.TAKEOVER then
                    local who = tonumber(msg.id) or sender
                    M0.activeMaster = who
                    if M0.mode == "standby" then
                        ui:log(string.format("主控 #%d 已接管，本机继续待命", who),
                            col("lightGray", 1024))
                    elseif who ~= M0.masterId and who < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("#%d 宣布接管（ID 更小），本机退回待命", who),
                            col("orange", 2))
                    end
                elseif M0.mode == "standby" and msg.t ~= proto.REPO then
                    -- 待命期间不回应节点、不派任务（避免和真正的主控抢活）
                    -- 例外：作业仓库查询是只读的，顺手回一下没坏处（落到下面的分支）
                    ui:log(string.format("待命模式：忽略 #%s 的 %s", tostring(sender),
                        tostring(msg.t)), col("gray", 128))
                elseif msg.t == proto.REPO then
                    -- 别人问我们有哪些作业（作业仓库）
                    local list = {}
                    for _, j in ipairs(jobs.list()) do
                        local path = util.JOB_DIR .. "/" .. j.name .. ".lua"
                        list[#list + 1] = {
                            name = j.name .. ".lua",
                            size = util.exists(path) and fs.getSize(path) or 0,
                            summary = j.summary,
                        }
                    end
                    net.send(sender, proto.msg(proto.REPOINFO, { jobs = list }), util.PROTO_CTRL)
                    ui:log(string.format("#%d 查询了作业仓库，已回复 %d 个作业", sender, #list),
                        col("lightGray", 1024))

                elseif msg.t == proto.REPOINFO then
                    local list = msg.jobs or {}
                    M0.lastRepo = { target = sender, jobs = list, at = util.now() }
                    ui:log(string.format("#%d 的作业仓库（%d 个）：", sender, #list), col("lightBlue", 512))
                    for _, j in ipairs(list) do
                        local name = tostring(j.name or "?")
                        local have = util.exists(util.JOB_DIR .. "/" .. name)
                        ui:log(string.format("  %-18s %8s  %s%s", name, util.bytes(j.size or 0),
                            util.trunc(tostring(j.summary or ""), 28), have and "  [已有]" or ""))
                    end
                    ui:log("  pull <主控ID> <作业名…> 拉取 / pullall <主控ID> 只拉本地没有的")

                else
                    local ok, err = pcall(S.onMessage, S, sender, msg)
                    if not ok then
                        ui:log("处理消息出错：" .. tostring(err), col("red", 16384))
                    end
                end
            end
        end
    end

    local function pushLoop()
        local recvs = {}          -- xid -> 接收端（别人推给我们，或我们主动拉回来的）
        while not M0.quit do
            local sender, msg = net.receive(util.PROTO_PUSH, xfer.RECV_WAIT)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("丢弃 #%s 的传输消息：%s", tostring(sender), tostring(why)),
                        col("orange", 2))
                elseif msg.t == proto.FETCH then
                    local what = tostring(msg.what or "worker")
                    if what == "job" then
                        -- 作业仓库：把 /dccomp/jobs/<name> 发出去（只认安全文件名）
                        local name = tostring(msg.name or "")
                        local path = util.JOB_DIR .. "/" .. name
                        if not name:match("^[%w_%-_%.]+%.lua$") or name:find("%.%.") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "非法作业名" }),
                                util.PROTO_PUSH)
                            ui:log("拒绝分发非法作业名：" .. name, col("red", 16384))
                        elseif not util.exists(path) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "没有这个作业" }),
                                util.PROTO_PUSH)
                        else
                            ui:log(string.format("节点 #%d 请求拉取作业 %s…", sender, name),
                                col("lightBlue", 512))
                            startPush(sender, path, "job")
                        end

                    elseif what == "taskdata" then
                        -- 大负载任务：节点按需来取（池子里的 task-*.dat）
                        local name = tostring(msg.name or "")
                        if not state.validPoolName(name) or not name:match("^task%-") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "非法负载名" }),
                                util.PROTO_PUSH)
                        elseif not util.exists(state.poolPath(name)) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "负载不存在" }),
                                util.PROTO_PUSH)
                        else
                            startPush(sender, state.poolPath(name), "taskdata")
                        end

                    elseif not util.exists(util.WORKER_FILE) then
                        net.send(sender, proto.msg(proto.REFERR, {
                            xid = msg.xid, err = "主控上没有 " .. util.WORKER_FILE,
                        }), util.PROTO_PUSH)
                        ui:log("  × " .. util.WORKER_FILE .. " 不存在，无法分发", col("red", 16384))
                    else
                        ui:log(string.format("节点 #%d 请求拉取 %s…", sender, what),
                            col("lightBlue", 512))
                        startPush(sender, util.WORKER_FILE, "worker")
                    end

                elseif msg.t == proto.PUT or msg.t == proto.PUTDONE then
                    -- 接收端：别人推给我们，或我们主动拉回来的（PUT 分块 + PUTDONE 收尾）
                    local r = recvs[msg.xid]
                    if not r and msg.t == proto.PUT then
                        r = xfer.newReceiver(msg.xid, msg.name, msg.n)
                        recvs[msg.xid] = r
                        ui:log(string.format("开始接收 #%d 的分块传输 %s（%s 块）",
                            sender, tostring(msg.name), tostring(msg.n)), col("lightGray", 1024))
                    end
                    if not r then
                        -- 收尾消息但没有对应的接收端（比如对方重启了）：忽略即可
                        -- 注意不能 return，那会把整个 pushLoop 结束掉
                    else
                        local action, value = xfer.recvOnMsg(r, msg)
                        if action == "ack" then
                            net.send(sender, proto.msg(proto.PUTACK, { xid = msg.xid, i = value }),
                                util.PROTO_PUSH)
                        elseif action == "miss" then
                            net.send(sender, proto.msg(proto.PUTMISS, { xid = msg.xid, miss = value }),
                                util.PROTO_PUSH)
                        elseif action == "complete" then
                            recvs[msg.xid] = nil
                            local name = tostring(r.name or "")
                            local dest
                            if state.validPoolName(name) then
                                dest = state.poolPath(name)      -- 节点推来的大结果
                            elseif name:match("^[%w_%-_%.]+%.lua$") and not name:find("%.%.") then
                                dest = util.JOB_DIR .. "/" .. name
                            end
                            if not dest then
                                ui:log("拒绝保存未知文件：" .. name, col("red", 16384))
                            else
                                local ok, err = util.writeFile(dest, value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    if state.validPoolName(name) then
                                        ui:log(string.format("已从 #%d 收到大结果 %s（%s）",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                        os.queueEvent("dcpool", name)   -- 通知等待大结果的作业
                                    else
                                        ui:log(string.format("已从 #%d 拉取作业 %s（%s）",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                    end
                                else
                                    ui:log("写入失败：" .. tostring(err), col("red", 16384))
                                end
                            end
                        end
                    end

                elseif msg.t == proto.REFERR then
                    ui:log(string.format("#%d 拒绝了拉取请求：%s", sender, tostring(msg.err)),
                        col("orange", 2))

                else
                    -- 传输确认：按 xid 找到对应的发送端
                    local s = M0.reg.senders[msg.xid]
                    if s then xfer.senderOnMsg(s, msg) end
                end
            end
            -- 顺便推进发送队列并向等待者发信号
            if xfer.pollRegistry(M0.reg, net.send) then xfer.notify() end
        end
    end

    local function httpLoop()
        while not M0.quit do
            local ev = table.pack(os.pullEventRaw())
            if ev[1] == "http_success" or ev[1] == "http_failure" then
                local ok, err = pcall(CL.onEvent, CL, ev)
                if not ok then ui:log("处理 HTTP 事件出错：" .. tostring(err), col("red", 16384)) end
            end
        end
    end

    -- ── 高可用：接管 ─────────────────────────────────────────────────
    local function broadcastBeat()
        M0.lastBeatSent = util.mono()
        local jobs = 0
        for _, j in pairs(S.jobs) do
            if j.state == "running" or j.state == "queued" then jobs = jobs + 1 end
        end
        net.broadcast(proto.msg(proto.BEAT, {
            id = M0.masterId, jobs = jobs, workers = S:onlineCount(),
        }), util.PROTO_CTRL)
    end

    local function takeover(why)
        M0.mode = "active"
        M0.tookOver = util.now()
        S.paused = false
        ui:log(string.format("★ 接管主控（%s）：本机 #%d 现在在岗", why, M0.masterId),
            col("lime", 32))
        net.broadcast(proto.msg(proto.TAKEOVER, { id = M0.masterId }), util.PROTO_CTRL)
        -- 从快照接续：已算完的任务带着结果回来，没算完的重新排队
        local restored, err, skipped = state.restore(S, jobs)
        if restored and restored > 0 then
            ui:log(string.format("已接续 %d 个作业（完成的任务结果直接沿用）", restored),
                col("lightBlue", 512))
        elseif err then
            ui:log("接续作业失败：" .. tostring(err), col("orange", 2))
        elseif skipped then
            ui:log(string.format("有 %d 个作业无法接续（缺少作业文件）", skipped),
                col("orange", 2))
        else
            ui:log("没有需要接续的作业。", col("lightGray", 1024))
        end
        broadcastBeat()
    end

    local finished = {}
    local function tickLoop()
        local lastStatus = 0
        while not M0.quit do
            os.sleep(0.5)
            if M0.mode == "standby" then
                -- 待命：只盯着心跳，超时就接管
                local silence = util.mono() - M0.lastBeatAt
                if silence > (S.cfg.takeoverAfter or 15) then
                    takeover(string.format("已 %.0f 秒没有主控心跳", silence))
                end
            else
                S:tick()
                if util.mono() - M0.lastBeatSent > (S.cfg.beatInterval or 3) then
                    broadcastBeat()
                end
            end
            CL:pump()
            PN:redraw(S, CL)
            state.poolClean()

            -- 推动分块传输（发送端登记在 M0.reg 里，由 pushLoop/tickLoop 一起推进）
            local done = xfer.pollRegistry(M0.reg, net.send)
            if done then
                xfer.notify()
                for xid, st in pairs(done) do
                    M0.reg.results[xid] = st
                end
            end
            for _, s in pairs(M0.reg.senders) do
                if not s.warned and (util.mono() - s.startedAt) > 8 then
                    s.warned = true
                    ui:log(string.format("推送 %s → #%d 迟迟没有确认（第 %d/%d 块）",
                        s.name, s.target, math.min(s.next, s.n), s.n), col("orange", 2))
                end
            end

            local now = util.now()
            if now - lastStatus > 800 then
                lastStatus = now
                ui:setStatus(S:statusLine())
            end
        end
    end

    local function uiLoop()
        while not M0.quit do
            ui:setStatus(S:statusLine())
            local line = ui:prompt("dcnet> ", complete)
            if line and util.trim(line) ~= "" then
                local ok, err = pcall(dispatch, line)
                if not ok then ui:log("指令出错：" .. tostring(err), col("red", 16384)) end
            end
        end
    end

    -- ── 启动 ─────────────────────────────────────────────────────────
    ui:log(string.format("配置：并发 %d，抢尾冗余 %d，任务超时 %s%s（set 改配置 / cfg 看全部）",
        S.cfg.maxParallel, S.cfg.redundancy, tostring(S.cfg.taskTimeout),
        S.cfg.adaptiveTimeout and " 秒+自适应" or " 秒"))

    -- 待命主控：不接活，只盯在岗主控的心跳，超时就接管并接续作业状态
    if S.cfg.standby then
        M0.mode = "standby"
        S.paused = true
        ui:log(string.format("以待命主控模式启动：#%d 只盯心跳，%.0f 秒收不到就接管",
            M0.masterId, S.cfg.takeoverAfter or 15), col("lightBlue", 512))
    end

    -- 断点续算：把上次没跑完的作业接上（待命时不做——那是接管时的事）
    if M0.mode == "active" and S.cfg.autoResume and state.hasSnapshot() then
        local n, err, skipped = S:restore()
        if n and n > 0 then
            ui:log(string.format("已从快照恢复 %d 个未完成作业（断点续算）", n), col("lime", 32))
        elseif err then
            ui:log("快照未恢复：" .. tostring(err), col("orange", 2))
        end
    end

    ui:setStatus(S:statusLine())
    local ok, err = pcall(parallel.waitForAny, netLoop, pushLoop, tickLoop, uiLoop, httpLoop)
    ui:close()
    if not opts.headless then
        term.clear()
        term.setCursorPos(1, 1)
    end
    if not ok then
        printError("[dcnet] 主控异常终止：" .. tostring(err))
        return false
    end
    print("[dcnet] 主控已停止。")
    return true
end

return M
