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
        printError("[dcnet] No modem detected")
        print("[dcnet] Wired setup: put a wired modem beside the computer, cable into the modem,")
        print("[dcnet] chain all machines on one cable; add more modems to bridge more networks.")
        return false
    end

    -- ── 示例作业 ─────────────────────────────────────────────────────
    util.ensureDir(util.JOB_DIR)
    util.ensureDir(util.OUT_DIR)
    util.ensureDir(util.CONTROL_DIR)
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
    ui:setStatus("Master starting...")
    ui:log(string.format("dcnet master v%s   local ID #%d", util.VERSION, os.getComputerID()),
        col("lime", 32))
    ui:log(string.format("Network: opened %s (%s)", net.describe(modems),
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
            ui:log("Message signing enabled (key fingerprint " .. tostring(net.fingerprint()) ..
                "), unsigned/replay messages dropped", col("lime", 32))
        else
            ui:log("Failed to enable signing: " .. tostring(kerr), col("orange", 2))
        end
    end
    for _, e in ipairs(failedModems or {}) do
        ui:log("  Failed to open modem: " .. e, col("orange", 2))
    end
    if #created > 0 then
        ui:log("Installed sample jobs to " .. util.JOB_DIR .. ": " .. table.concat(created, ", "),
            col("lightBlue", 512))
    end
    local avail = jobs.list()
    ui:log(string.format("Available jobs %d: %s", #avail,
        table.concat((function()
            local t = {}
            for _, j in ipairs(avail) do t[#t + 1] = j.name end
            return t
        end)(), " ")))
    ui:log("Type help for commands.")

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
                string.format("# job %d  %s", job.id, job.name),
                string.format("# params: %s", jobs.paramHelp(job.def)),
                string.format("# state: %s  tasks %d ok / %d failed  elapsed %s",
                    job.state, job.counts.done, job.counts.failed, util.duration(job.durationMs)),
                "",
                job.resultText or tostring(job.error or ""),
            }
            local ok = util.writeFile(path, table.concat(lines, "\n") .. "\n")
            if ok then ui:log("Result saved: " .. path, col("lightGray", 1024)) end
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
        screens = {},               -- 网络屏幕：id -> { id, name, w, h, lastSeen, ... }
    }

    -- ── 云端卸载 ─────────────────────────────────────────────────────
    local CL = cloud.new({
        sched = S, cfg = S.cfg,
        log = function(text, colour) ui:log(text, colour) end,
    })
    CL:registerWorkers()
    if not CL.ok then
        ui:log("Cloud offload unavailable: " .. tostring(CL.reason), col("orange", 2))
    elseif #CL.endpoints > 0 then
        local names = {}
        for _, ep in ipairs(CL.endpoints) do names[#names + 1] = ep.name end
        ui:log(string.format("Cloud endpoints %d: %s (cloud for details)", #CL.endpoints,
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
            if not ok then ui:log("Failed to attach monitor: " .. tostring(which), col("orange", 2)) end
        else
            ok, which = pcall(PN.attachAuto, PN)
            if ok and which then
                ui:log("Auto-attached monitor: " .. tostring(which) .. " (mon off to disable)",
                    col("lightBlue", 512))
            end
        end
    end
    if PN:attached() then PN:redraw(S, CL, true) end

    -- ── 网络屏幕（另一台电脑 + 显示器） ────────────────────────────────
    -- CC 的有线网络会把"贴着有线调制解调器的显示器"暴露成外设（monitor_0），
    -- 那种屏幕 mon 就能直接挂上；但**贴在别的电脑侧面**的显示器主控看不到。
    -- 这种屏幕由 screen.lua 当转发器：屏幕端广播 screen（带尺寸）当心跳，
    -- 主控把面板文字行推回去（disp），屏幕端只负责画。
    local SCREEN_MAX      = 16     -- 同时最多接几块网络屏幕
    local SCREEN_TIMEOUT  = 15     -- 秒：屏幕多久没有消息就摘掉
    local SCREEN_INTERVAL = 1.0    -- 秒：每块屏幕最多多久推一帧

    local function screenFrame(scr)
        return {
            master = M0.masterId,
            w = scr.w, h = scr.h,
            -- 序列化成字符串：设了密钥时整帧参与 HMAC 太贵，net.BULK_FIELDS 只把
            -- 它的校验和放进签名（和作业源码、分块数据同一套取舍）。
            lines = textutils.serialize(panel.linesFor(S, CL, scr.w, scr.h)),
            at = util.now(),
        }
    end

    local function sendFrame(scr, force)
        if not S.cfg.netScreen then return end
        local now = util.mono()
        if not force and (now - (scr.lastFrame or 0)) < SCREEN_INTERVAL then return end
        scr.lastFrame = now
        scr.frames = (scr.frames or 0) + 1
        local ok, err = net.send(scr.id, proto.msg(proto.DISP, screenFrame(scr)), util.PROTO_CTRL)
        if not ok and now - (scr.lastWarn or 0) > 10 then
            scr.lastWarn = now
            ui:log(string.format("Push to net screen #%d failed: %s", scr.id, tostring(err)),
                col("orange", 2))
        end
    end

    local function screenHello(sender, msg)
        if not S.cfg.netScreen then
            net.send(sender, proto.msg(proto.SCREENOFF, { why = "off" }), util.PROTO_CTRL)
            return
        end
        local vok, verr = proto.compatible(msg)
        if not vok then
            net.send(sender, proto.msg(proto.SCREENOFF, { why = "ver" }), util.PROTO_CTRL)
            ui:log(string.format("Net screen #%s protocol incompatible: %s", tostring(sender),
                tostring(verr)), col("orange", 2))
            return
        end
        local w = math.max(1, math.floor(tonumber(msg.w) or 51))
        local h = math.max(1, math.floor(tonumber(msg.h) or 19))
        local name = util.trunc(tostring(msg.name or ("screen-" .. tostring(sender))), 24)
        local scr = M0.screens[sender]
        if not scr then
            local n = 0
            for _ in pairs(M0.screens) do n = n + 1 end
            if n >= SCREEN_MAX then
                net.send(sender, proto.msg(proto.SCREENOFF, { why = "full" }), util.PROTO_CTRL)
                return
            end
            scr = { id = sender, firstSeen = util.now() }
            M0.screens[sender] = scr
            ui:log(string.format("Net screen #%d connected: %s (%dx%d)", sender, name, w, h),
                col("lime", 32))
        elseif scr.w ~= w or scr.h ~= h then
            ui:log(string.format("Net screen #%d size changed: %dx%d -> %dx%d", sender,
                scr.w or 0, scr.h or 0, w, h), col("lightBlue", 512))
        end
        scr.name, scr.w, scr.h = name, w, h
        scr.lastSeen, scr.seenAt = util.mono(), util.now()
        sendFrame(scr, true)
    end

    local function screenBye(sender, msg)
        if M0.screens[sender] then
            M0.screens[sender] = nil
            ui:log(string.format("Net screen #%d left: %s", sender, tostring(msg.reason or "none")),
                col("lightGray", 1024))
        end
    end

    local function pumpScreens()
        if not S.cfg.netScreen then return end
        local now = util.mono()
        for id, scr in pairs(M0.screens) do
            if now - (scr.lastSeen or 0) > SCREEN_TIMEOUT then
                M0.screens[id] = nil
                ui:log(string.format("Net screen #%d offline (no msg for %.0f s)", id,
                    now - (scr.lastSeen or now)), col("orange", 2))
            else
                sendFrame(scr)
            end
        end
    end

    local function screenLines()
        local out = {}
        local ids = {}
        for id in pairs(M0.screens) do ids[#ids + 1] = id end
        table.sort(ids)
        out[#out + 1] = string.format("Net screens: %s (%d/%d)",
            S.cfg.netScreen and "pushing" or "off", #ids, SCREEN_MAX)
        for _, id in ipairs(ids) do
            local s = M0.screens[id]
            out[#out + 1] = string.format("  #%-3d %-16s %3dx%-3d  %7s ago  %d frames",
                id, s.name or "?", s.w or 0, s.h or 0,
                util.duration(util.now() - (s.seenAt or util.now())), s.frames or 0)
        end
        if #ids == 0 then
            out[#out + 1] = "  (run screen.lua on the screen computer to connect)"
        end
        return out
    end

    -- ── 推送文件（worker.lua / 作业 / 大负载） ────────────────────────
    -- 发送端统一登记到 M0.reg，由唯一的 dcpush 接收循环推进（见 xfer.lua 的说明）。
    local function startPush(target, path, what)
        local data, err = util.readFile(path)
        if not data then
            ui:log("Push failed: " .. tostring(err), col("red", 16384))
            return nil
        end
        local name = util.basename(path)
        local xid, eerr = xfer.enqueue(M0.reg, target, name, what or "worker", data,
            function(state, self)
                if state ~= "ok" then
                    ui:log(string.format("Push %s to #%d failed: %s",
                        self.name, self.target, tostring(self.err)), col("red", 16384))
                elseif what == "worker" then
                    ui:log(string.format("Pushed %s to worker #%d (%s)",
                        self.name, self.target, util.bytes(#data)), col("lime", 32))
                    ui:log("  Worker still runs old code; reboot #" .. self.target .. " to load the new version",
                        col("lightGray", 1024))
                else
                    ui:log(string.format("Pushed %s to #%d (%s)",
                        self.name, self.target, util.bytes(#data)), col("lightGray", 1024))
                end
            end)
        if not xid then
            ui:log("Push failed: " .. tostring(eerr), col("red", 16384))
            return nil
        end
        ui:log(string.format("Pushing %s -> #%d (%s)",
            name, target, util.bytes(#data)), col("lightGray", 1024))
        return xid
    end

    -- ── 指令 ─────────────────────────────────────────────────────────
    local function cmdHelp()
        local lines = {
            "  help                    Show this help",
            "  status                  Job overview + worker list",
            "  workers                 Worker list only",
            "  jobs                    List jobs under /dccomp/jobs",
            "  run <job> [params..] [pri=N]",
            "                          Submit a job, e.g. run primes to=2000000 pri=5",
            "  run! <job> ...          Same but skip result cache (force)",
            "  queue                   Show job queue",
            "  result [job id]         Show a job result (default=latest done)",
            "  cancel <job id>         Cancel a job",
            "  pause [job id]          Pause dispatch (no id=all)",
            "  resume [job id]         Resume dispatch",
            "  pri <job id> <priority> Set priority (higher grabs tasks first)",
            "  limit [N]               Max jobs in parallel",
            "  redun [N]               Redundant tail threshold (0=off, tames slow tails)",
            "  set <key> <value>       Change config and persist (cfg lists all)",
            "  cfg                     Show all active config",
            "  net                     Show modem / network status",
            "  state [save|clear]      Snapshot state / write now / clear",
            "  cache [clear]           Result cache list / clear",
            "  history [N]             Recent job run history",
            "  top [N]                 Worker total contribution ranking",
            "  cloud                   Cloud endpoint list and status",
            "  cloud add <name> <url> [parallel] Register an HTTP compute service (persisted)",
            "  cloud del <name>        Delete endpoint",
            "  cloud test <name>       Probe (one GET)",
            "  mon [name|off]          Attach/close local monitor panel (persisted)",
            "  mon net [on|off|kick ID] Net screen: another computer + monitor as panel",
            "  setkey <key>            Enable signing (anti-spoof/replay, same everywhere)",
            "  key                     Show signing state, key fingerprint, drop stats",
            "  standby [on|off]        Standby master: take over and resume if active dies",
            "  repo <master id>        Query another master's job repo",
            "  pull <master id> <job names...> Pull jobs from it (adds .lua)",
            "  pullall <master id>     Pull only missing ones (repo first)",
            "  push [worker id..]      Push " .. util.WORKER_FILE .. " to workers (upgrade)",
            "  reboot [worker id..]    Reboot workers (load new code after push)",
            "  kick <worker id>        Make one worker exit",
            "  halt                    Make all workers exit",
            "  save <job id> [path]    Save result to a file",
            "  clear                   Redraw the UI",
            "  quit                    Close master (workers stay, reconnect on restart)",
        }
        for _, l in ipairs(lines) do ui:log(l) end
    end

    local function cmdJobList()
        local list = jobs.list()
        if #list == 0 then
            ui:log("(no job files under " .. util.JOB_DIR .. ")")
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
                ui:log(string.format("              params: %s", table.concat(parts, "  ")))
            end
        end
    end

    local function cmdRun(toks, nocache)
        local name = toks[1]
        if not name then
            ui:log("Usage: run <job> [params..] [pri=N] (jobs lists available)", col("orange", 2))
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
            ui:log("Load job failed: " .. tostring(err), col("red", 16384))
            return
        end
        local job, err2 = S:addJob(def, rest, { priority = pri, nocache = nocache })
        if not job then
            ui:log("Submit failed: " .. tostring(err2), col("red", 16384))
        elseif S:onlineCount() == 0 then
            ui:log("Note: no worker online; job queues until one connects.", col("orange", 2))
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
            ui:log("No finished job yet.", col("orange", 2))
            return
        end
        ui:log(string.format("Job #%d %s (%s) params: %s", job.id, job.name,
            job.state, jobs.paramHelp(job.def)), col("lightBlue", 512))
        ui:log(string.format("Tasks %d ok / %d failed, elapsed %s",
            job.counts.done, job.counts.failed, util.duration(job.durationMs or 0)))
        for _, line in ipairs(S:failedTaskLines(job.id, 5)) do ui:log(line, col("red", 16384)) end
        if job.resultText then
            for _, line in ipairs(util.split(job.resultText, "\n")) do ui:log("  " .. line) end
        elseif job.error then
            ui:log("  " .. job.error, col("red", 16384))
        else
            ui:log("  (job has not finished yet)", col("orange", 2))
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
            if not id then ui:log("Usage: cancel <job id>", col("orange", 2)) else
                local ok, err = S:cancel(id)
                if not ok then ui:log("Cancel failed: " .. tostring(err), col("red", 16384)) end
            end
        elseif c == "pause" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, true)
                if not ok then ui:log("Pause failed: " .. tostring(err), col("red", 16384)) end
            else
                S.paused = true
                ui:log("Paused all dispatch (running tasks unaffected).", col("orange", 2))
            end
        elseif c == "resume" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, false)
                if not ok then ui:log("Resume failed: " .. tostring(err), col("red", 16384)) end
            else
                S.paused = false
                ui:log("Dispatch resumed.", col("lime", 32))
            end
        elseif c == "pri" then
            local id, pri = tonumber(toks[1]), tonumber(toks[2])
            if not id or not pri then ui:log("Usage: pri <job id> <priority>", col("orange", 2))
            else
                local ok, err = S:setPriority(id, pri)
                if not ok then ui:log("Set failed: " .. tostring(err), col("red", 16384)) end
            end
        elseif c == "limit" or c == "redun" then
            local key = (c == "limit") and "maxParallel" or "redundancy"
            local v = toks[1]
            if not v then
                ui:log(string.format("%s = %s", key, tostring(S.cfg[key])), col("lightBlue", 512))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then ui:log("Set failed: " .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s (persisted)", key, tostring(S.cfg[key])), col("lime", 32))
                    S:pump()
                end
            end
        elseif c == "set" then
            local key, v = toks[1], toks[2]
            if not key or v == nil then
                ui:log("Usage: set <key> <value> (cfg lists all keys)", col("orange", 2))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then
                    ui:log("Set failed: " .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s (persisted, survives reboot)", key, tostring(S.cfg[key])),
                        col("lime", 32))
                end
            end
        elseif c == "cfg" then
            ui:logLines(util.cfgLines(S.cfg, sched.CFG_META))
        elseif c == "net" then
            ui:log(string.format("Opened modems: %s", net.describe(modems)))
            for _, md in ipairs(modems) do
                ui:log(string.format("  %-8s %s", md.name, md.wireless and "wireless" or "wired"))
            end
            ui:log(string.format("Online workers %d / registered %d", S:onlineCount(), S:workerCount()))
            local screenCount = 0
            for _ in pairs(M0.screens) do screenCount = screenCount + 1 end
            ui:log(string.format("Net screens %d (mon net to list / toggle)", screenCount))
            if net.hasKey() then
                ui:log("Message signing: enabled, key fingerprint " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("Message signing: off (setkey <key> enables)", col("orange", 2))
            end
            ui:logLines(net.statsLines())
        elseif c == "state" then
            local sub = toks[1]
            if sub == "clear" then
                state.clearSnapshot()
                ui:log("Snapshot cleared (no resume on next start).", col("lime", 32))
            elseif sub == "save" then
                local ok, err = S:saveSnapshot()
                ui:log(ok and "Snapshot written." or ("Snapshot failed: " .. tostring(err)),
                    ok and col("lime", 32) or col("red", 16384))
            else
                local size = util.exists(state.SNAP) and fs.getSize(state.SNAP) or 0
                ui:log(string.format("Snapshot: %s (%s)", state.SNAP,
                    size > 0 and util.bytes(size) or "none"))
                local pending = 0
                for _, j in pairs(S.jobs) do
                    if j.state == "queued" or j.state == "running" then pending = pending + 1 end
                end
                ui:log(string.format("Unfinished jobs %d; auto-write every >=3s on change, fallback %ds",
                    pending, S.cfg.snapshotInterval))
                ui:log("  state save writes now / state clear wipes / set snapshot false off")
            end
        elseif c == "cache" then
            if toks[1] == "clear" then
                ui:log(string.format("Cleared %d result cache entries.", state.cacheClear()), col("lime", 32))
            else
                local list = state.cacheList()
                ui:log(string.format("Result cache %d entries (%s):", #list, state.CACHE_DIR))
                for i = 1, math.min(#list, 8) do
                    local e = list[i].entry
                    ui:log(string.format("  %s  %-10s %s ago", list[i].key, tostring(e and e.job or "?"),
                        util.duration(util.now() - ((e and e.at) or util.now()))))
                end
                ui:log("  cache clear wipes / run! skips cache / set cache false off")
            end
        elseif c == "repo" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            if not id then
                ui:log("Usage: repo <master id> (lists its jobs)", col("orange", 2))
            else
                net.send(id, proto.msg(proto.REPO, {}), util.PROTO_CTRL)
                ui:log("Querying job repo of #" .. id .. "...", col("lightBlue", 512))
            end
        elseif c == "pull" or c == "pullall" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            local names = {}
            if c == "pullall" then
                if not id or not M0.lastRepo or M0.lastRepo.target ~= id then
                    ui:log("Usage: repo <master id> first, then pullall <master id>", col("orange", 2))
                    id = nil
                else
                    for _, j in ipairs(M0.lastRepo.jobs) do
                        local name = tostring(j.name or "")
                        if not util.exists(util.JOB_DIR .. "/" .. name) then names[#names + 1] = name end
                    end
                    if #names == 0 then
                        ui:log("All its jobs already exist locally.", col("lime", 32))
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
                ui:log("Usage: pull <master id> <job names...> (adds .lua)", col("orange", 2))
                id = nil
            end
            for _, name in ipairs(names) do
                -- 借 dcpush 协议做分块传输，对方在主控上会走 "FETCH what=job" 分支
                net.send(id, proto.msg(proto.FETCH, {
                    xid = net.newXid("job"), what = "job", name = name,
                }), util.PROTO_PUSH)
                ui:log("Requesting job " .. name .. " ...", col("lightBlue", 512))
            end
        elseif c == "standby" then
            local sub = tostring(toks[1] or "")
            if sub == "on" or sub == "true" then
                util.saveCfg("standby", true)
                S.cfg.standby = true
                ui:log("Set as standby master (next start): watch heartbeat, take over if active dies",
                    col("lime", 32))
            elseif sub == "off" or sub == "false" then
                util.saveCfg("standby", false)
                S.cfg.standby = false
                ui:log("Standby cleared (next start runs as active master)", col("lime", 32))
            else
                ui:log(string.format("HA: node #%d is in %s mode%s",
                    M0.masterId, M0.mode == "standby" and "standby" or "active",
                    M0.activeMaster and (", last saw active master #" .. tostring(M0.activeMaster)) or ""))
                ui:log(string.format("  Heartbeat %ss, takeover after %ss (set beatInterval / takeoverAfter)",
                    tostring(S.cfg.beatInterval), tostring(S.cfg.takeoverAfter)))
                ui:log("  standby on|off: start in standby by default (persisted)")
                if M0.mode == "standby" then
                    ui:log(string.format("  Silent for %.1f s", util.mono() - M0.lastBeatAt))
                elseif M0.tookOver and M0.tookOver > 0 then
                    ui:log("  This master took over (original went offline)", col("orange", 2))
                end
            end
        elseif c == "setkey" then
            local k = toks[1]
            if not k then
                ui:log("Usage: setkey <shared key> (min 8 chars; same key on all)",
                    col("orange", 2))
                ui:log("  setkey off disables signing; on workers use set dcnet.key <key>",
                    col("lightGray", 1024))
            elseif k == "off" or k == "none" then
                net.setKey(nil)
                settings.set("dcnet.key", "")
                settings.save()
                ui:log("Signing off (anyone on the subnet can impersonate master/worker)", col("orange", 2))
            else
                local ok2, kerr = net.setKey(k)
                if not ok2 then
                    ui:log("Set failed: " .. tostring(kerr), col("red", 16384))
                else
                    settings.set("dcnet.key", k)
                    settings.save()
                    ui:log("Signing enabled, key fingerprint " .. tostring(net.fingerprint()),
                        col("lime", 32))
                    ui:log("  Other machines need the same key (master setkey / worker set dcnet.key)," ..
                        "just match the fingerprint", col("lightGray", 1024))
                end
            end
        elseif c == "key" then
            if net.hasKey() then
                ui:log("Message signing: enabled, key fingerprint " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("Signing off (any program on the subnet can impersonate)", col("orange", 2))
                ui:log("  Use setkey <shared key> to enable; optional on one machine", col("lightGray", 1024))
            end
            ui:logLines(net.statsLines())
            if M0.dropped then ui:log("  Dropped " .. M0.dropped .. " messages in total") end
        elseif c == "mon" then
            local sub = toks[1]
            if sub == "off" then
                local old = PN:detach()
                util.saveCfg("monitor", "off")
                S.cfg.monitor = "off"
                ui:log("Local panel closed" .. (old and (" (" .. tostring(old) .. ")") or ""),
                    col("lime", 32))
            elseif sub == "net" then
                local action = toks[2]
                if action == "on" or action == "off" then
                    S.cfg.netScreen = (action == "on")
                    util.saveCfg("netScreen", S.cfg.netScreen)
                    if not S.cfg.netScreen then
                        for id in pairs(M0.screens) do
                            net.send(id, proto.msg(proto.SCREENOFF, { why = "off" }),
                                util.PROTO_CTRL)
                        end
                        M0.screens = {}
                        ui:log("Net screen push off (screens show 'master closed')",
                            col("orange", 2))
                    else
                        ui:log("Net screen push on (run screen.lua on the screen computer)",
                            col("lime", 32))
                    end
                elseif action == "kick" then
                    local id = tonumber((tostring(toks[3] or ""):gsub("^#", "")))
                    if not id then
                        ui:log("Usage: mon net kick <screen id> (mon net lists them)", col("orange", 2))
                    elseif not M0.screens[id] then
                        ui:log("No such net screen: #" .. id, col("orange", 2))
                    else
                        M0.screens[id] = nil
                        net.send(id, proto.msg(proto.SCREENOFF, { why = "kick" }), util.PROTO_CTRL)
                        ui:log("Net screen #" .. id .. " kicked (reconnects on next heartbeat)",
                            col("lime", 32))
                    end
                else
                    ui:logLines(screenLines())
                    ui:log("  mon net on|off toggles / mon net kick <ID> drops one",
                        col("lightGray", 1024))
                end
            elseif sub then
                local ok, err = PN:attach(sub)
                if not ok then
                    ui:log("Attach failed: " .. tostring(err), col("red", 16384))
                else
                    util.saveCfg("monitor", sub)
                    S.cfg.monitor = sub
                    PN:redraw(S, CL, true)
                    ui:log("Attached monitor " .. tostring(PN.name) ..
                        string.format(" (%dx%d)", PN.w, PN.h), col("lime", 32))
                end
            else
                if PN:attached() then
                    ui:log(string.format("Panel: %s (%dx%d, scale %.2f)",
                        tostring(PN.name), PN.w, PN.h, PN.scale), col("lightBlue", 512))
                else
                    ui:log("No local monitor attached.")
                end
                local list = panel.findMonitors()
                if #list == 0 then
                    ui:log("  No monitor peripheral (attach to master, or use screen.lua)")
                else
                    for _, m in ipairs(list) do
                        ui:log("  Monitors: " .. m.name .. (m.net and " (wired network)" or "") ..
                            " (attach: mon " .. m.name .. ")")
                    end
                end
                ui:logLines(screenLines())
                ui:log("  mon <name> attach local / mon off close local / mon net net screens")
            end
        elseif c == "cloud" then
            local sub = toks[1]
            if sub == "add" then
                local name, url, slots = toks[2], toks[3], toks[4]
                if not name or not url then
                    ui:log("Usage: cloud add <name> <url> [parallel]", col("orange", 2))
                else
                    local ep, err = cloud.addEndpoint(CL.endpoints, name, url, slots)
                    if not ep then
                        ui:log("Add failed: " .. tostring(err), col("red", 16384))
                    else
                        CL:registerWorkers()
                        ui:log(string.format("Registered cloud endpoint %s -> %s (%d parallel, persisted)",
                            ep.name, ep.url, ep.slots), col("lime", 32))
                    end
                end
            elseif sub == "del" then
                local ep, err = cloud.removeEndpoint(CL.endpoints, toks[2])
                if not ep then
                    ui:log("Delete failed: " .. tostring(err), col("red", 16384))
                else
                    S.workers[ep.id] = nil
                    ui:log("Deleted endpoint " .. tostring(ep.name), col("lime", 32))
                end
            elseif sub == "test" then
                local name = toks[2]
                if not name then
                    ui:log("Usage: cloud test <name>", col("orange", 2))
                else
                    local sent, terr = CL:test(name, function(ok2, data, e)
                        if ok2 then
                            local info = type(data) == "table" and data.status or data
                            ui:log(string.format("Endpoint %s probe ok: %s", name,
                                util.trunc(tostring(info), 60)), col("lime", 32))
                        else
                            ui:log(string.format("Endpoint %s probe failed: %s", name, tostring(e)),
                                col("red", 16384))
                        end
                    end)
                    if not sent then ui:log("Probe not sent: " .. tostring(terr), col("red", 16384)) end
                end
            else
                ui:logLines(CL:lines())
            end
        elseif c == "top" then
            ui:logLines(S:topLines(tonumber(toks[1]) or 10))
        elseif c == "history" then
            local n = tonumber(toks[1]) or 10
            local list, total = state.history(n)
            ui:log(string.format("Run history (latest %d / total %d):", #list, total))
            for _, e in ipairs(list) do
                ui:log(string.format("  #%-3d %-12s %-4s ok%d fail%d  %s  %s", e.id, tostring(e.name),
                    e.state == "done" and "done" or "failed", e.done or 0, e.failed or 0,
                    util.duration(e.ms or 0), util.trunc(tostring(e.summary or ""), 36)))
            end
        elseif c == "push" then
            local list = targetWorkers(toks)
            if #list == 0 then ui:log("No workers to push to.", col("orange", 2)) else
                for _, w in ipairs(list) do startPush(w.id, util.WORKER_FILE, "worker") end
                ui:log(string.format("Begin push to %d workers: %s...", #list, util.WORKER_FILE))
            end
        elseif c == "kick" then
            local id = tonumber((toks[1] or ""):gsub("^#", ""))
            if not id then ui:log("Usage: kick <worker id>", col("orange", 2))
            else
                net.send(id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
                ui:log("Told worker #" .. id .. " to exit.", col("orange", 2))
            end
        elseif c == "halt" then
            local list = targetWorkers(toks)
            for _, w in ipairs(list) do
                net.send(w.id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
            end
            M0.halted = true
            ui:log(string.format("Told %d workers to exit.", #list), col("orange", 2))
        elseif c == "reboot" then
            -- 配合 push 使用：节点重启后，startup 文件里的 shell.run 会拉起新代码
            local list = targetWorkers(toks)
            if #list == 0 then ui:log("No workers to reboot.", col("orange", 2)) else
                for _, w in ipairs(list) do
                    net.send(w.id, proto.msg(proto.HALT, { reboot = true }), util.PROTO_CTRL)
                end
                ui:log(string.format("Told %d workers to reboot.", #list), col("orange", 2))
                ui:log("  Note: workers need /startup.lua autorun to rejoin the cluster.",
                    col("lightGray", 1024))
            end
        elseif c == "save" then
            local id = tonumber(toks[1])
            local job = id and S.jobs[id] or lastFinishedJob()
            if not job or not job.resultText then
                ui:log("No result to save.", col("orange", 2))
            else
                local path = toks[2] or string.format("%s/job-%d-%s.txt", util.OUT_DIR, job.id, job.name)
                local ok = util.writeFile(path, job.resultText .. "\n")
                ui:log(ok and ("Saved: " .. path) or "Save failed", ok and col("lime", 32) or col("red", 16384))
            end
        elseif c == "clear" then
            ui:rebuild()
        elseif c == "quit" or c == "exit" then
            ui:log("Master exiting. Workers keep waiting and reconnect on restart.", col("orange", 2))
            M0.quit = true
        else
            ui:log("Unknown command: " .. c .. " (type help)", col("orange", 2))
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
                    ui:log(string.format("Dropped #%s message: %s", tostring(sender), tostring(why)),
                        col("orange", 2))
                    M0.dropped = (M0.dropped or 0) + 1
                elseif msg.t == proto.BEAT then
                    -- 在岗主控的心跳：记下来；如果对方 ID 更小，我们就该让位
                    M0.lastBeatAt = util.mono()
                    M0.activeMaster = tonumber(msg.id) or sender
                    if M0.mode == "active" and M0.activeMaster and M0.activeMaster < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("Master #%d active (lower ID), this node goes standby",
                            M0.activeMaster), col("orange", 2))
                    end
                elseif msg.t == proto.TAKEOVER then
                    local who = tonumber(msg.id) or sender
                    M0.activeMaster = who
                    if M0.mode == "standby" then
                        ui:log(string.format("Master #%d took over, staying standby", who),
                            col("lightGray", 1024))
                    elseif who ~= M0.masterId and who < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("#%d announced takeover (lower ID), going standby", who),
                            col("orange", 2))
                    end
                elseif msg.t == proto.SCREEN or msg.t == proto.SCREENBYE then
                    -- 网络屏幕：只有在岗主控应答（待命主控静默，屏幕会自动找在岗的）
                    if M0.mode == "active" then
                        if msg.t == proto.SCREEN then screenHello(sender, msg)
                        else screenBye(sender, msg) end
                    end
                elseif M0.mode == "standby" and msg.t ~= proto.REPO then
                    -- 待命期间不回应节点、不派任务（避免和真正的主控抢活）
                    -- 例外：作业仓库查询是只读的，顺手回一下没坏处（落到下面的分支）
                    ui:log(string.format("Standby: ignoring #%s %s", tostring(sender),
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
                    ui:log(string.format("#%d queried job repo, replied %d jobs", sender, #list),
                        col("lightGray", 1024))

                elseif msg.t == proto.REPOINFO then
                    local list = msg.jobs or {}
                    M0.lastRepo = { target = sender, jobs = list, at = util.now() }
                    ui:log(string.format("Job repo of #%d (%d):", sender, #list), col("lightBlue", 512))
                    for _, j in ipairs(list) do
                        local name = tostring(j.name or "?")
                        local have = util.exists(util.JOB_DIR .. "/" .. name)
                        ui:log(string.format("  %-18s %8s  %s%s", name, util.bytes(j.size or 0),
                            util.trunc(tostring(j.summary or ""), 28), have and "  [have]" or ""))
                    end
                    ui:log("  pull <master id> <job names...> / pullall <master id> missing only")

                else
                    local ok, err = pcall(S.onMessage, S, sender, msg)
                    if not ok then
                        ui:log("Message error: " .. tostring(err), col("red", 16384))
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
                    ui:log(string.format("Dropped transfer from #%s: %s", tostring(sender), tostring(why)),
                        col("orange", 2))
                elseif msg.t == proto.FETCH then
                    local what = tostring(msg.what or "worker")
                    if what == "job" then
                        -- 作业仓库：把 /dccomp/jobs/<name> 发出去（只认安全文件名）
                        local name = tostring(msg.name or "")
                        local path = util.JOB_DIR .. "/" .. name
                        if not name:match("^[%w_%-_%.]+%.lua$") or name:find("%.%.") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "invalid job name" }),
                                util.PROTO_PUSH)
                            ui:log("Refused invalid job name: " .. name, col("red", 16384))
                        elseif not util.exists(path) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "no such job" }),
                                util.PROTO_PUSH)
                        else
                            ui:log(string.format("Worker #%d requests job %s...", sender, name),
                                col("lightBlue", 512))
                            startPush(sender, path, "job")
                        end

                    elseif what == "taskdata" then
                        -- 大负载任务：节点按需来取（池子里的 task-*.dat）
                        local name = tostring(msg.name or "")
                        if not state.validPoolName(name) or not name:match("^task%-") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "invalid payload name" }),
                                util.PROTO_PUSH)
                        elseif not util.exists(state.poolPath(name)) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "payload not found" }),
                                util.PROTO_PUSH)
                        else
                            startPush(sender, state.poolPath(name), "taskdata")
                        end

                    elseif not util.exists(util.WORKER_FILE) then
                        net.send(sender, proto.msg(proto.REFERR, {
                            xid = msg.xid, err = "master has no " .. util.WORKER_FILE,
                        }), util.PROTO_PUSH)
                        ui:log("  x " .. util.WORKER_FILE .. " missing, cannot distribute", col("red", 16384))
                    else
                        ui:log(string.format("Worker #%d requests %s...", sender, what),
                            col("lightBlue", 512))
                        startPush(sender, util.WORKER_FILE, "worker")
                    end

                elseif msg.t == proto.PUT or msg.t == proto.PUTDONE then
                    -- 接收端：别人推给我们，或我们主动拉回来的（PUT 分块 + PUTDONE 收尾）
                    local r = recvs[msg.xid]
                    if not r and msg.t == proto.PUT then
                        r = xfer.newReceiver(msg.xid, msg.name, msg.n)
                        recvs[msg.xid] = r
                        ui:log(string.format("Receiving from #%d: chunked %s (%s chunks)",
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
                                ui:log("Refused unknown file: " .. name, col("red", 16384))
                            else
                                local ok, err = util.writeFile(dest, value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    if state.validPoolName(name) then
                                        ui:log(string.format("Got big result from #%d: %s (%s)",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                        os.queueEvent("dcpool", name)   -- 通知等待大结果的作业
                                    else
                                        ui:log(string.format("Pulled job from #%d: %s (%s)",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                    end
                                else
                                    ui:log("Write failed: " .. tostring(err), col("red", 16384))
                                end
                            end
                        end
                    end

                elseif msg.t == proto.REFERR then
                    ui:log(string.format("#%d refused the pull: %s", sender, tostring(msg.err)),
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
                if not ok then ui:log("HTTP event error: " .. tostring(err), col("red", 16384)) end
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
        ui:log(string.format("* Took over as master (%s): node #%d is active", why, M0.masterId),
            col("lime", 32))
        net.broadcast(proto.msg(proto.TAKEOVER, { id = M0.masterId }), util.PROTO_CTRL)
        -- 从快照接续：已算完的任务带着结果回来，没算完的重新排队
        local restored, err, skipped = state.restore(S, jobs)
        if restored and restored > 0 then
            ui:log(string.format("Resumed %d jobs (completed task results reused)", restored),
                col("lightBlue", 512))
        elseif err then
            ui:log("Resume failed: " .. tostring(err), col("orange", 2))
        elseif skipped then
            ui:log(string.format("%d jobs not resumed (job file missing)", skipped),
                col("orange", 2))
        else
            ui:log("No jobs to resume.", col("lightGray", 1024))
        end
        broadcastBeat()
    end

    -- 外壳转交命令的队列：<root>/ctl/*.cmd。ush 只把命令行写进这个目录，
    -- master 在后台（通常 --headless）按文件名顺序取走并执行。这样系统外壳
    -- 不需要自己成为 dcnet 的进程，只负责传话。
    local function pollControl()
        local dir = util.CONTROL_DIR
        if not fs.exists(dir) then return end
        local names = fs.list(dir) or {}
        table.sort(names)
        for _, name in ipairs(names) do
            if tostring(name):match("%.cmd$") then
                local path = dir .. "/" .. name
                local f = fs.open(path, "r")
                local line = f and f.readAll() or nil
                if f then f.close() end
                pcall(fs.delete, path)
                if line then line = util.trim(line) end
                if line and line ~= "" then
                    local ok, err = pcall(dispatch, line)
                    if not ok then
                        ui:log("Control command failed: " .. tostring(err), col("red", 16384))
                    end
                end
            end
        end
    end

    local finished = {}
    local function tickLoop()
        local lastStatus = 0
        while not M0.quit do
            pollControl()
            os.sleep(0.5)
            if M0.mode == "standby" then
                -- 待命：只盯着心跳，超时就接管
                local silence = util.mono() - M0.lastBeatAt
                if silence > (S.cfg.takeoverAfter or 15) then
                    takeover(string.format("no master heartbeat for %.0f s", silence))
                end
            else
                S:tick()
                if util.mono() - M0.lastBeatSent > (S.cfg.beatInterval or 3) then
                    broadcastBeat()
                end
            end
            CL:pump()
            PN:redraw(S, CL)
            pumpScreens()
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
                    ui:log(string.format("Push %s -> #%d unacked (chunk %d/%d)",
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
                if not ok then ui:log("Command error: " .. tostring(err), col("red", 16384)) end
            end
        end
    end

    -- ── 启动 ─────────────────────────────────────────────────────────
    ui:log(string.format("Config: parallel %d, redundant %d, task timeout %s%s (set / cfg)",
        S.cfg.maxParallel, S.cfg.redundancy, tostring(S.cfg.taskTimeout),
        S.cfg.adaptiveTimeout and " s+adaptive" or " s"))

    -- 待命主控：不接活，只盯在岗主控的心跳，超时就接管并接续作业状态
    if S.cfg.standby then
        M0.mode = "standby"
        S.paused = true
        ui:log(string.format("Starting standby: #%d watches heartbeat, takes over after %.0f s",
            M0.masterId, S.cfg.takeoverAfter or 15), col("lightBlue", 512))
    end

    -- 断点续算：把上次没跑完的作业接上（待命时不做——那是接管时的事）
    if M0.mode == "active" and S.cfg.autoResume and state.hasSnapshot() then
        local n, err, skipped = S:restore()
        if n and n > 0 then
            ui:log(string.format("Restored %d unfinished jobs from snapshot", n), col("lime", 32))
        elseif err then
            ui:log("Snapshot not restored: " .. tostring(err), col("orange", 2))
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
        printError("[dcnet] Master crashed: " .. tostring(err))
        return false
    end
    print("[dcnet] Master stopped.")
    return true
end

return M
