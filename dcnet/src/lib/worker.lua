--[[- dc.worker — 运算节点

进程结构（CC 的 parallel，四个协作协程）：

  netLoop   唯一的 dccomp 接收循环：收 welcome / task / idle / cancel / halt
  workLoop  等任务 → 执行 map → 回传结果；执行期间靠 ctx.tick() 让出
  beatLoop  定时器：空闲时 pull（同时充当心跳）、失联时重新找主控、刷新界面
  pushLoop  唯一的 dcpush 接收循环：接收主控推送的新版 worker.lua

为什么必须 ctx.tick()：
  CC:Tweaked 限制"连续不让出"的执行时长（TimeoutState.TIMEOUT = 7 秒），
  超过就抛 "Too long without yielding" 并关掉电脑。ctx.tick() 的做法是
  os.queueEvent + os.pullEvent 投递一个自己的事件，这在 CC 内部算"收到新事件"，
  会把 7 秒预算**重置**，所以它既让出执行权、又保证永远不会撞上超时。
  内部按 50ms 节流，顺带上报进度、接收 cancel、维持心跳。
]]

local util    = dc_require("dc.util")
local proto   = dc_require("dc.protocol")
local net     = dc_require("dc.net")
local jobs    = dc_require("dc.jobs")
local console = dc_require("dc.console")
local xfer    = dc_require("dc.xfer")
local state   = dc_require("dc.state")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local YIELD_INTERVAL = 0.05     -- 秒：ctx.tick 的最小让出间隔
local REPORT_INTERVAL = 0.7     -- 秒：进度上报节流（进度消息可能被高频调用）

--- 节点侧可持久化的配置（写在节点的 settings 里）
M.DEFAULTS = {
    maxRestarts  = 5,   -- 异常后最多自动重启几次
    restartDelay = 5,   -- 重启间隔（秒）
    rebootAfter  = 0,   -- 多久联系不上主控就重启电脑（秒，0=关）
}
M.CFG_META = {
    maxRestarts  = "max auto restarts after error",
    restartDelay = "auto restart interval (s)",
    rebootAfter  = "reboot after master lost (s, 0=off)",
}

--- 跑一轮节点（内部实现）。正常停止返回 true；异常返回 false, 原因
--- opts: { master = number|nil, name = string|nil, rebootAfter = number }
local function runOnce(opts)
    opts = opts or {}

    -- 日志落盘：节点出问题时不至于什么都没留下
    local LOG = util.ROOT .. "/logs/node-" .. os.getComputerID() .. ".log"
    local function fileLog(text)
        util.appendLog(LOG, util.logLine(text))
    end
    fileLog("Worker starting v" .. util.VERSION)

    -- ── 1. 网络 ──────────────────────────────────────────────────────
    -- 打开所有 modem：节点如果挂在多段网络上（或多插了一个无线），都能收到主控
    local modems, failedModems = net.openAll()
    if #modems == 0 then
        printError("[dcnet] No modem detected")
        print("[dcnet] Attach a network cable to a wired modem and check peripheral.getNames().")
        fileLog("no modem detected")
        return false, "no modem detected"
    end

    -- headless（psh 包）：不占终端，日志只写文件；交互终端下仍是原来的三区界面。
    local ui
    if opts.headless then
        ui = console.null({ title = "dcnet worker", hasPrompt = false, logFile = LOG })
    else
        ui = console.new({ title = "dcnet worker", hasPrompt = false })
    end
    ui:log(string.format("dcnet worker v%s", util.VERSION), col("lime", 32))
    ui:log(string.format("Network: opened %s (%s)  ID #%d",
        net.describe(modems),
        (function()
            local t = {}
            for _, md in ipairs(modems) do t[#t + 1] = md.name end
            return table.concat(t, ",")
        end)(),
        os.getComputerID()))
    for _, e in ipairs(failedModems or {}) do
        ui:log("  Failed to open modem: " .. e, col("orange", 2))
    end

    local S = {
        id       = os.getComputerID(),
        name     = opts.name or os.getComputerLabel() or ("node-" .. os.getComputerID()),
        master   = tonumber(opts.master),
        wireless = (modems[1] and modems[1].wireless) or false,
        cfg      = { pollInterval = 1.5, taskTimeout = 90, fileChannel = true, inlineLimit = 8192 },
        have     = nil,
        cache    = {},
        cacheOrder = {},
        state    = "connecting",   -- connecting | idle | busy
        task     = nil,
        inbox    = {},
        running  = true,
        lastMasterMsg = util.now(),
        idleUntil = 0,
        lastPull = 0,
        done = 0, fail = 0, totalMs = 0,
        progress = 0, note = "",
        curLabel = "",
    }

    -- ── 2. 找主控 ────────────────────────────────────────────────────
    local function discover()
        for _ = 1, 6 do
            net.broadcast(proto.msg(proto.WHO, {}), util.PROTO_CTRL)
            local sender, msg = net.receive(util.PROTO_CTRL, 1.2)
            if msg and proto.valid(msg) and msg.t == proto.IAM then
                S.master = tonumber(msg.master) or sender
                return true
            end
        end
        return false
    end

    local function hello()
        S.state = "connecting"
        net.send(S.master, proto.msg(proto.HELLO, {
            name = S.name, wireless = S.wireless, have = S.have,
        }), util.PROTO_CTRL)
        S.lastMasterMsg = util.now()
    end

    if not S.master then
        ui:log("Looking for master...")
        if not discover() then
            ui:log("No master found.", col("red", 16384))
            ui:log("Check that: 1) master runs on the same wired network; 2) cables are connected.")
            ui:log("You can also pass worker <masterID> explicitly.")
            fileLog("master not found")
            return false, "master not found"
        end
    end
    ui:log("Found master #" .. tostring(S.master))
    fileLog("Found master #" .. tostring(S.master))
    hello()

    -- ── 3. 界面 ──────────────────────────────────────────────────────
    local function statusText()
        local st = ({ connecting = "handshake", idle = "idle", busy = "computing" })[S.state] or S.state
        local cur = ""
        if S.state == "busy" then
            cur = string.format("  %s %d%%", util.trunc(S.curLabel, 18), math.floor((S.progress or 0) * 100))
        end
        return string.format("Worker #%d %s | Master #%s | %s%s | done %d failed %d",
            S.id, util.trunc(S.name, 10), tostring(S.master or "?"), st, cur, S.done, S.fail)
    end

    local function refresh()
        ui:setStatus(statusText())
    end

    -- ── 4. 任务执行 ──────────────────────────────────────────────────
    local function trimCache()
        while #S.cacheOrder > 3 do
            local old = table.remove(S.cacheOrder, 1)
            S.cache[old] = nil
        end
    end

    -- 统一的 dcpush 发送队列（由 pushLoop 推进）
    local M0 = { reg = xfer.newRegistry() }

    --- 向主控拉一个大负载到本地池子（拿不到就返回 nil, err）。
    -- 期间用无过滤 pullEvent：CC 的 parallel 会把事件分发给所有协程，不会抢别人的。
    local function fetchPool(name, timeout)
        local deadline = util.mono() + (timeout or 45)
        local lastAsk = 0
        while util.mono() < deadline do
            if util.mono() > lastAsk + 3 then
                lastAsk = util.mono()
                net.send(S.master, proto.msg(proto.FETCH, {
                    xid = net.newXid("gett"), what = "taskdata", name = name,
                }), util.PROTO_PUSH)
            end
            os.startTimer(0.5)
            local ev = { os.pullEvent() }
            if ev[1] == "dcpool" and ev[2] == name and util.exists(state.poolPath(name)) then
                return state.poolGet(name)
            end
        end
        return nil, "timed out waiting for payload"
    end

    local function runTask(msg)
        -- 大负载任务：负载不在消息里，而是池子里的文件，按需向主控拉取
        if msg.payloadRef and msg.payload == nil then
            local value, ferr = fetchPool(msg.payloadRef)
            if value == nil then
                S.state = "idle"
                S.curLabel = nil
                net.send(S.master, proto.msg(proto.RESULT, {
                    job = msg.job, task = msg.task, ok = false,
                    err = "task payload fetch failed: " .. tostring(ferr), ms = 0,
                }), util.PROTO_CTRL)
                ui:log(string.format("Task %d.%d payload fetch failed: %s",
                    msg.job or 0, msg.task or 0, tostring(ferr)), col("red", 16384))
                return
            end
            msg.payload = value
        end

        local t0 = util.mono()
        S.state = "busy"
        S.progress, S.note = 0, ""
        S.curLabel = string.format("%d.%d", msg.job or 0, msg.task or 0)

        local src = msg.src or S.cache[msg.hash]
        -- 主控声明的源码哈希必须对得上才执行（防止传输被改、也防止缓存串味）
        if src and msg.hash and util.hash(src) ~= msg.hash then
            S.state = "idle"
            S.curLabel = nil
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false,
                err = "job source verification failed (hash mismatch)", ms = 0,
            }), util.PROTO_CTRL)
            ui:log(string.format("Task %d.%d hash mismatch, refusing to run",
                msg.job or 0, msg.task or 0), col("red", 16384))
            S.cache[msg.hash] = nil
            return
        end
        if not src then
            S.state = "idle"
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false,
                err = "job source not found locally (hash " .. tostring(msg.hash) .. ")", ms = 0,
            }), util.PROTO_CTRL)
            ui:log(string.format("Task %d.%d missing job source", msg.job or 0, msg.task or 0), col("red", 16384))
            return
        end
        if msg.src and not S.cache[msg.hash] then
            S.cache[msg.hash] = msg.src
            S.cacheOrder[#S.cacheOrder + 1] = msg.hash
            trimCache()
            ui:log(string.format("Received job source %s (%s)", tostring(msg.name), util.bytes(#msg.src)))
        end
        S.have = msg.hash

        local cur = { job = msg.job, task = msg.task, cancelled = false }
        S.task = cur
        local lastYield, lastReport = util.mono(), util.mono()

        local function report(force)
            local now = util.mono()
            if not force and now - lastReport < REPORT_INTERVAL then return end
            lastReport = now
            net.send(S.master, proto.msg(proto.PROGRESS, {
                job = msg.job, task = msg.task,
                pct = S.progress, note = S.note,
            }), util.PROTO_CTRL)
        end

        local ctx = {
            worker = S.id, job = msg.job, task = msg.task,
            payload = msg.payload,
            now = util.now, mono = util.mono,
            --- 上报进度（0..1）。为了防止刷爆网络，内部节流到 REPORT_INTERVAL 一次
            progress = function(pct, note)
                S.progress = math.max(0, math.min(1, tonumber(pct) or S.progress))
                if note then S.note = tostring(note) end
                report(false)
            end,
            --- 写一行到节点本地日志
            log = function(text) ui:log("  " .. tostring(text), col("lightGray", 1024)) end,
            --- 任务是否已被主控取消（下一次 ctx.tick() 之后生效）
            canceled = function() return cur.cancelled end,
            --- 让出执行权：热循环里必须周期性调用（内部按 50ms 节流）
            tick = function()
                local now = util.mono()
                if now - lastYield < YIELD_INTERVAL then return end
                lastYield = now
                report(false)
                os.queueEvent("dc_yield")
                os.pullEvent("dc_yield")
            end,
        }

        local res, err
        if msg.phase == "reduce" then
            -- 两级汇总的中间任务：在这台节点上跑 def.reduce
            res, err = jobs.runReduce(src, msg.payload, msg.args, ctx)
        else
            res, err = jobs.runMap(src, msg.payload, ctx)
        end
        local ms = math.floor((util.mono() - t0) * 1000)
        S.task = nil

        if cur.cancelled then
            ui:log(string.format("Task %d.%d cancelled (%.1fs)", msg.job or 0, msg.task or 0, ms / 1000),
                col("orange", 2))
        elseif res == nil and err then
            S.fail = S.fail + 1
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false, err = err, ms = ms,
            }), util.PROTO_CTRL)
            ui:log(string.format("Task %d.%d failed: %s", msg.job or 0, msg.task or 0, tostring(err)),
                col("red", 16384))
        else
            S.done = S.done + 1
            S.totalMs = S.totalMs + ms
            -- 结果太大就先把数据推给主控，再发一条只带名字的结果（大负载走文件通道）
            local dataRef
            if S.cfg.fileChannel ~= false then
                local okEnc, encoded = pcall(textutils.serialize, res)
                if okEnc and type(encoded) == "string"
                    and #encoded > (S.cfg.inlineLimit or 8192) then
                    local name = string.format("res-%d-%d.dat", msg.job or 0, msg.task or 0)
                    if state.poolPut(name, res) then
                        local xid = xfer.enqueue(M0.reg, S.master, name, "resdata", encoded)
                        if xid then
                            local okPush, perr = xfer.waitFor(M0.reg, xid, 60)
                            if okPush then
                                dataRef = name
                                ui:log(string.format("Task %d.%d result %s, sent via file channel",
                                    msg.job or 0, msg.task or 0, util.bytes(#encoded)),
                                    col("lightGray", 1024))
                            else
                                ui:log("Result push failed, using inline: " .. tostring(perr), col("orange", 2))
                            end
                        end
                    end
                end
            end
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = true,
                data = dataRef and nil or res, dataRef = dataRef, ms = ms,
            }), util.PROTO_CTRL)
            ui:log(string.format("Task %d.%d done (%s)", msg.job or 0, msg.task or 0, util.duration(ms)),
                col("lime", 32))
        end

        S.state = "idle"
        S.progress, S.note, S.curLabel = 0, "", ""
        refresh()
    end

    -- ── 5. 三个协程 ──────────────────────────────────────────────────
    local function netLoop()
        while S.running do
            local sender, msg = net.receive(util.PROTO_CTRL, 2)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("Dropped message from #%s: %s", tostring(sender), tostring(why)),
                        col("orange", 2))
                    S.dropped = (S.dropped or 0) + 1
                else
                local fromMaster = (sender == S.master)
                if fromMaster then S.lastMasterMsg = util.now() end

                if msg.t == proto.WELCOME and fromMaster then
                    local vok, verr = proto.compatible(msg)
                    if not vok then
                        ui:log("Master protocol version incompatible: " .. tostring(verr), col("red", 16384))
                        ui:log("Upgrade worker and master to the same version.", col("red", 16384))
                        S.running = false
                        return
                    end
                    if type(msg.cfg) == "table" then
                        S.cfg.pollInterval = msg.cfg.pollInterval or S.cfg.pollInterval
                        S.cfg.taskTimeout  = msg.cfg.taskTimeout or S.cfg.taskTimeout
                        if msg.cfg.fileChannel ~= nil then
                            S.cfg.fileChannel = msg.cfg.fileChannel
                        end
                        S.cfg.inlineLimit = msg.cfg.inlineLimit or S.cfg.inlineLimit
                        S.cfg.reHelloAfter = msg.cfg.reHelloAfter or S.cfg.reHelloAfter
                        S.cfg.rediscoverAfter = msg.cfg.rediscoverAfter or S.cfg.rediscoverAfter
                    end
                    if S.state == "connecting" then
                        S.state = "idle"
                        ui:log("Registered with master, waiting for tasks.", col("lime", 32))
                        refresh()
                    end

                elseif msg.t == proto.TASK and fromMaster then
                    S.inbox[#S.inbox + 1] = msg
                    os.queueEvent("dc_inbox")

                elseif msg.t == proto.IDLE and fromMaster then
                    S.idleUntil = util.mono() + math.max(0.2, tonumber(msg.wait) or S.cfg.pollInterval)

                elseif msg.t == proto.CANCEL and fromMaster then
                    -- 只置标志位：map 在下一次 ctx.tick() 时才会看到
                    if S.task and S.task.job == msg.job and S.task.task == msg.task then
                        S.task.cancelled = true
                    end

                elseif msg.t == proto.HALT and fromMaster then
                    S.running = false
                    net.send(S.master, proto.msg(proto.BYE, {
                        reason = msg.shutdown and "shutdown"
                            or (msg.reboot and "reboot" or "halt"),
                    }), util.PROTO_CTRL)
                    if msg.shutdown then
                        ui:log("Shutdown command from master, powering off...",
                            col("orange", 2))
                        os.sleep(0.6)          -- 给上面那条 bye 留出发送时间
                        if os.shutdown then os.shutdown() end
                        return
                    end
                    if msg.reboot then
                        ui:log("Reboot command from master, rebooting...", col("orange", 2))
                        ui:log("(/startup.lua starts the new worker.lua on reboot)",
                            col("lightGray", 1024))
                        os.sleep(0.6)          -- 给上面那条 bye 留出发送时间
                        os.reboot()            -- 不会返回
                    end
                    ui:log("Halt command from master, worker exiting.", col("orange", 2))
                    return

                elseif msg.t == proto.PING and fromMaster then
                    net.send(S.master, proto.msg(proto.PONG, {}), util.PROTO_CTRL)

                elseif msg.t == proto.IAM then
                    -- 重新搜索主控时，应答可能被 netLoop 先收到（discover 与 netLoop 都在
                    -- 收 dccomp 频道）。这里也认一次，否则换了主控永远登记不上。
                    local who = tonumber(msg.master) or sender
                    if who and who ~= S.master then
                        S.master = who
                        S.lastMasterMsg = util.now()
                        ui:log("Found master #" .. tostring(who) .. ", re-registering...", col("lime", 32))
                        hello()
                    end
                end
                end
            end
        end
    end

    local function workLoop()
        while S.running do
            local msg = table.remove(S.inbox, 1)
            if msg then
                runTask(msg)
            else
                os.pullEvent("dc_inbox")
            end
        end
    end

    -- 接收主控推送的文件（新版本代码 / 任务负载），同时驱动本机发出的传输。
    -- 这里必须是**唯一**的 dcpush 接收循环（见 xfer.lua 的说明）。
    local function pushLoop()
        local recvs = {}          -- xid -> 接收端状态
        while S.running do
            local sender, msg = net.receive(util.PROTO_PUSH, xfer.RECV_WAIT)
            local got = (msg and proto.valid(msg) and msg.xid and net.verify(sender, msg))
            if got then
                if msg.t == proto.PUT or msg.t == proto.PUTDONE then
                    local r = recvs[msg.xid]
                    if not r and msg.t == proto.PUT then
                        r = xfer.newReceiver(msg.xid, msg.name, msg.n)
                        recvs[msg.xid] = r
                    end
                    if r then
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
                            if state.validPoolName(name) and name:match("^task%-") then
                                -- 大负载任务：落进池子并唤醒等它的任务
                                state.poolPut(name, nil)      -- 占位，下面直接写原始数据
                                local ok, err = util.writeFile(state.poolPath(name), value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    os.queueEvent("dcpool", name)
                                else
                                    ui:log("Payload write failed: " .. tostring(err), col("red", 16384))
                                end
                            elseif name == "worker.lua" and #value <= 512 * 1024 then
                                local ok, err = util.writeFile(util.WORKER_FILE, value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    ui:log(string.format("New version received (%s); reboot to apply",
                                        util.bytes(#value)), col("lime", 32))
                                else
                                    ui:log("Write failed: " .. tostring(err), col("red", 16384))
                                end
                            else
                                ui:log("Refusing unknown file: " .. name, col("red", 16384))
                            end

                        elseif xfer.recvExpired(r) then
                            recvs[msg.xid] = nil
                        end
                    end
                else
                    -- 我方发送端的确认帧
                    local s = M0.reg.senders[msg.xid]
                    if s then xfer.senderOnMsg(s, msg) end
                end
            end
            -- 推进发送队列并唤醒等待者
            if xfer.pollRegistry(M0.reg, net.send) then xfer.notify() end
        end
    end

    local function beatLoop()
        local lastUi = 0
        while S.running do
            os.sleep(0.5)
            local nowMs, mono = util.now(), util.mono()

            -- 主控失联：重发 hello，仍然没有回应就重新广播找主控
            -- （阈值可由主控下发，方便测试和按网络情况调整；接管后靠"重新搜索"换主）
            --
            -- 注意：**忙的时候也要重新搜索**。否则主控掉线、备用机接管后，正在算任务的
            -- 节点会一直把结果发给已经死掉的主控，直到当前任务算完才发现没人接活。
            local silent = nowMs - S.lastMasterMsg
            local reHello = (S.cfg.reHelloAfter or 8) * 1000
            local reDiscover = (S.cfg.rediscoverAfter or 25) * 1000
            if silent > reDiscover then
                ui:log("Lost master, searching again...", col("orange", 2))
                S.master = nil
                if discover() then
                    ui:log("Master found again #" .. tostring(S.master))
                    hello()
                    S.lastMasterMsg = util.now()
                else
                    S.state = "connecting"
                    -- 没找到就 3 秒后再试（把时钟往前拨，不写成一堆 if）
                    S.lastMasterMsg = util.now() - (reDiscover - 3000)
                end
            elseif silent > reHello and S.state ~= "busy" then
                hello()
            end

            -- 看门狗：长时间找不到主控就重启电脑（需要开机自启才能回到集群）
            local rebootAfter = tonumber(opts.rebootAfter) or 0
            if rebootAfter > 0 and S.master == nil
                and (nowMs - (S.lastMasterMsg or nowMs)) > rebootAfter * 1000 then
                ui:log(string.format("No master for %d s, rebooting per watchdog...", rebootAfter),
                    col("orange", 2))
                fileLog("watchdog: master unreachable, rebooting")
                sleep(0.5)
                os.reboot()
            end

            -- 空闲就拉任务（pull 同时是心跳）
            if S.state == "idle" and S.master and mono >= (S.idleUntil or 0)
                and (mono - S.lastPull) > S.cfg.pollInterval then
                S.lastPull = mono
                net.send(S.master, proto.msg(proto.PULL, { have = S.have }), util.PROTO_CTRL)
            end

            if nowMs - lastUi > 400 then
                lastUi = nowMs
                refresh()
            end
        end
    end

    -- ── 6. 启动 ──────────────────────────────────────────────────────
    refresh()
    ui:log(string.format("Worker name: %s (use label set <name> to rename)", S.name))

    -- 共享密钥（可选）：设了就启用消息签名与防重放
    local savedKey = rawget(_G, "DCNET_KEY") or settings.get("dcnet.key")
    if savedKey and savedKey ~= "" then
        local kok, kerr = net.setKey(savedKey)
        if kok then
            ui:log("Message signing enabled (key fingerprint " .. tostring(net.fingerprint()) .. ")",
                col("lime", 32))
        else
            ui:log("Failed to enable message signing: " .. tostring(kerr), col("orange", 2))
        end
    end
    ui:log("Press Ctrl+T to stop the worker.")

    local ok, err = pcall(parallel.waitForAny, netLoop, workLoop, beatLoop, pushLoop)
    if not opts.headless then term.redirect(term.native()) end
    if not ok then
        printError("[dcnet] Worker crashed: " .. tostring(err))
        fileLog("worker crashed: " .. tostring(err))
        return false, tostring(err)
    end
    print("[dcnet] Worker stopped.")
    fileLog("worker stopped normally")
    return true
end

--- 带看门狗的外层：异常不退出，隔几秒自动重连；连不上主控太久可选重启电脑。
-- opts: { master, name, maxRestarts = 5, restartDelay = 5, rebootAfter = 0 }
function M.run(opts)
    opts = opts or {}
    -- 配置优先级：默认值 < settings 持久化值 < 传进来的 opts
    local cfg = util.loadCfg(M.DEFAULTS, M.CFG_META)
    for k, v in pairs(opts) do cfg[k] = v end

    local maxRestarts = tonumber(cfg.maxRestarts) or 5
    local delay = tonumber(cfg.restartDelay) or 5
    local restarts = 0

    while true do
        local ok, err = runOnce(cfg)
        if ok then return true end

        restarts = restarts + 1
        util.appendLog(util.ROOT .. "/logs/node-" .. os.getComputerID() .. ".log",
            util.logLine(string.format("Restart %d after error: %s", restarts, tostring(err))))

        if restarts > maxRestarts then
            printError(string.format("[dcnet] Worker failed %d times in a row, no auto-restart: %s",
                restarts, tostring(err)))
            return false, err
        end
        print(string.format("[dcnet] Worker error (%s), auto-restart in %d s (%d/%d)",
            tostring(err), delay, restarts, maxRestarts))
        sleep(delay)
    end
end

return M
