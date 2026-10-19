--[[- dc.sched — 主控调度器

职责：
  * 维护节点表（在线/离线/忙闲/统计）
  * 维护作业队列（同一时刻只跑一个作业，避免小集群互相抢算力）
  * 拉模型派发：节点 pull → 主控 assign；没有待办任务就回 idle
  * 容错：节点失联或任务长时间无进展 → 任务重派（最多 maxTries 次）
  * 作业收尾：全部任务结束 → reduce → format → 回调 onFinished

时间有两套：
  * util.mono()  单调秒，用于超时判定（os.clock）
  * util.now()   墙钟毫秒，用于展示与"最后在线时间"
]]

local util  = dc_require("dc.util")
local proto = dc_require("dc.protocol")
local jobs  = dc_require("dc.jobs")
local net   = dc_require("dc.net")
local state = dc_require("dc.state")
local xfer  = dc_require("dc.xfer")

local M = {}

local Sched = {}
M.Sched = Sched

local C = util.colours or {}

local function colour(name, fallback)
    return (C and C[name]) or fallback
end

--- 统一的日志出口。
-- 注意必须是"方法"：下面所有调用点写的是 self:log(...)，
-- 如果把它当成普通字段（function(text, colour)）就会把 self 当正文打出去。
function Sched:log(text, colour)
    if self.logFn then self.logFn(text, colour) end
end

local STATE_TEXT = {
    queued = "排队", running = "执行中", done = "完成",
    failed = "失败", cancelled = "取消",
}

--- 调度器的可调项与默认值（主控会先用 settings 里的持久化值覆盖，再用命令行覆盖）
M.DEFAULTS = {
    workerTimeout   = 12,    -- 秒：节点多久没有消息就判定离线
    taskTimeout     = 90,    -- 秒：任务多久没有进展就重派（自适应开启时作为初始值）
    taskTimeoutMin  = 15,    -- 秒：自适应超时的下限
    taskTimeoutMax  = 900,   -- 秒：自适应超时的上限
    adaptiveTimeout = true,  -- 是否按历史任务时长自动收紧/放宽超时
    maxTries        = 3,     -- 单个任务最多被派发几次
    pollInterval    = 1.5,   -- 秒：节点空闲时的轮询间隔
    maxParallel     = 1,     -- 同时执行几个作业（多作业并发）
    redundancy      = 0,     -- >0：剩余任务数 <= 该值时冗余派发抢尾（straggler 抑制）
    verbose         = false, -- 是否打印每一次任务派发
    snapshot        = true,  -- 是否把未完成作业写快照（断点续算）
    snapshotInterval = 15,   -- 秒：没有变化时的兜底快照间隔
    autoResume      = true,  -- 启动时自动接上上次没跑完的作业
    cache           = true,  -- 是否使用结果缓存
    cloud           = true,  -- 是否启用云端卸载（HTTP 计算服务）
    cloudFirst      = true,  -- true=优先用云端；false=本机节点都忙时才用云端
    cloudChunk      = 65536, -- 字节：云端请求超过它就分块上传（HTTP 单请求有上限）
    twoLevelReduce  = true,  -- 结果很多时把 reduce 也拆成并行任务（两级汇总）
    reduceThreshold = 300,   -- 结果数超过这个值才启用两级汇总
    reduceGroupSize = 100,   -- 每个 reduce 任务处理多少条结果
    standby         = false, -- 本机默认以待命主控启动（主控掉线就接管）
    beatInterval    = 3,     -- 秒：在岗主控的心跳间隔
    takeoverAfter   = 15,    -- 秒：多久收不到心跳就接管
    reHelloAfter    = 8,     -- 秒：节点多久没听到主控就重发 hello
    rediscoverAfter = 25,    -- 秒：节点多久没听到主控就重新搜索（接管后靠它换主）
    monitor         = "",    -- monitor 外设名（""=自动找；"off"=不用）
    monitorScale    = 0.5,   -- monitor 字号缩放（0.5=分辨率翻倍）
    fileChannel     = true,  -- 大负载（>inlineLimit）走文件通道，不塞进一条消息
    inlineLimit     = 8192,  -- 字节：负载/结果超过它就改走文件通道
}

M.CFG_META = {
    workerTimeout   = "节点失联判定（秒）",
    taskTimeout     = "任务初始超时（秒）",
    taskTimeoutMin  = "自适应超时下限（秒）",
    taskTimeoutMax  = "自适应超时上限（秒）",
    adaptiveTimeout = "按历史耗时自适应超时",
    maxTries        = "单任务最多派发次数",
    pollInterval    = "节点空闲轮询间隔（秒）",
    maxParallel     = "同时执行的作业数",
    redundancy      = "抢尾冗余派发阈值（0=关）",
    verbose         = "打印每次任务派发",
    snapshot        = "把未完成作业写快照（断点续算）",
    snapshotInterval = "兜底快照间隔（秒）",
    autoResume      = "启动时自动接上未完成作业",
    cache           = "使用结果缓存",
    cloud           = "启用云端卸载（HTTP 计算服务）",
    cloudFirst      = "优先用云端（关闭=本机空闲时不用云端）",
    cloudChunk      = "云端请求超过多少字节就分块上传",
    twoLevelReduce  = "结果多时并行 reduce（两级汇总）",
    reduceThreshold = "超过多少条结果启用两级汇总",
    reduceGroupSize = "每个 reduce 任务处理多少条结果",
    standby         = "本机作为待命主控启动",
    beatInterval    = "在岗主控心跳间隔（秒）",
    takeoverAfter   = "收不到心跳多久后接管（秒）",
    reHelloAfter    = "节点重发 hello 的静默阈值（秒）",
    rediscoverAfter = "节点重新搜索主控的静默阈值（秒）",
    monitor         = "大屏显示器名（空=自动找）",
    monitorScale    = "大屏字号缩放",
    fileChannel     = "大负载走文件通道",
    inlineLimit     = "超过多少字节改走文件通道",
}

--- opts: { log = function(text, colour), onFinished = function(job), cfg = {...} }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Sched })
    self.cfg = {}
    for k, v in pairs(M.DEFAULTS) do self.cfg[k] = v end
    for k, v in pairs(opts.cfg or {}) do self.cfg[k] = v end

    self.logFn      = opts.log or function() end
    self.onFinished = opts.onFinished

    self.workers   = {}      -- id -> worker
    self.jobs      = {}      -- id -> job
    self.jobOrder  = {}      -- 作业提交顺序
    self.running   = {}      -- jobId -> true：正在执行的作业（可并发多个）
    self.paused    = false   -- 全局暂停派发
    self.nextJobId = 1
    self.stats     = { done = 0, failed = 0, retries = 0, redundant = 0 }
    self.dirty     = false   -- 有状态变化，等下一次 tick 写快照
    self.lastSnap  = 0
    self.lifetime  = state.loadWorkers()   -- 跨会话的节点贡献统计
    return self
end

--- 保存快照（断点续算）
function Sched:saveSnapshot()
    if not self.cfg.snapshot then return false, "快照已关闭" end
    local ok, err = state.snapshot(self)
    if ok then
        self.dirty, self.lastSnap = false, util.mono()
    end
    -- 顺便把节点贡献累加进历史统计（跨会话保留）
    self.lifetime = state.mergeWorkers(self.lifetime, self.workers)
    state.saveWorkers(self.lifetime)
    return ok, err
end

--- 节点累计贡献排行（含历史会话）
function Sched:topLines(limit)
    local rows = {}
    for id, e in pairs(self.lifetime or {}) do
        rows[#rows + 1] = { id = id, name = e.name, done = e.done or 0, fail = e.fail or 0,
            totalMs = e.totalMs or 0, lastSeen = e.lastSeen }
    end
    -- 还没落盘的当前会话增量也算上，免得刚跑完看不到
    local seen = {}
    for _, r in ipairs(rows) do seen[r.id] = r end
    for id, w in pairs(self.workers) do
        local r = seen[id]
        if not r then
            r = { id = id, name = w.name, done = 0, fail = 0, totalMs = 0 }
            rows[#rows + 1] = r
            seen[id] = r
        end
        r.done = r.done + ((w.done or 0) - (w.countedDone or 0))
        r.fail = r.fail + ((w.fail or 0) - (w.countedFail or 0))
    end
    table.sort(rows, function(a, b)
        if a.done ~= b.done then return a.done > b.done end
        return a.id < b.id
    end)

    local out = { string.format("%-7s %-12s %8s %8s %10s", "节点", "名称", "累计完成", "累计失败", "最近在线") }
    for i = 1, math.min(#rows, limit or 10) do
        local r = rows[i]
        out[#out + 1] = string.format("%-7s %-12s %8d %8d %10s", "#" .. r.id,
            util.trunc(r.name or "-", 12), r.done, r.fail,
            r.lastSeen and util.duration(util.now() - r.lastSeen) .. "前" or "-")
    end
    if #rows == 0 then out[#out + 1] = "（还没有节点贡献记录）" end
    return out
end

--- 从快照恢复（主控启动时调用）
function Sched:restore()
    local n, err, skipped = state.restore(self, jobs)
    for _, s in ipairs(skipped or {}) do
        self:log("  无法恢复 " .. s, colour("red", 16384))
    end
    if n > 0 then self:pump() end
    return n, err
end

--- 修改运行时配置（用于主控的 set / limit 指令）
function Sched:setCfg(key, value)
    if self.cfg[key] == nil then return nil, "未知配置项: " .. tostring(key) end
    local old = self.cfg[key]
    if type(old) == "number" then
        local n = tonumber(value)
        if not n then return nil, "需要数字" end
        self.cfg[key] = n
    elseif type(old) == "boolean" then
        if value == true or value == "true" or value == "on" or value == "1" then
            self.cfg[key] = true
        elseif value == false or value == "false" or value == "off" or value == "0" then
            self.cfg[key] = false
        else
            return nil, "需要 true/false"
        end
    else
        self.cfg[key] = tostring(value)
    end
    return true, old
end

-- ── 节点 ────────────────────────────────────────────────────────────────

function Sched:worker(id, msg)
    local w = self.workers[id]
    if not w then
        w = {
            id = id, joinedAt = util.now(), done = 0, fail = 0, totalMs = 0,
            state = "idle", lastSeen = util.now(),
        }
        self.workers[id] = w
    end
    if msg then w.lastSeen = util.now() end
    return w
end

function Sched:workerCount()
    local n = 0
    for _ in pairs(self.workers) do n = n + 1 end
    return n
end

function Sched:onlineCount()
    local n = 0
    for _, w in pairs(self.workers) do
        if w.state ~= "offline" then n = n + 1 end
    end
    return n
end

function Sched:workerList()
    local list = {}
    for _, w in pairs(self.workers) do list[#list + 1] = w end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Sched:workerLines()
    local out = {
        string.format("%-7s %-12s %-6s %6s %6s %9s %8s  %s",
            "节点", "名称", "状态", "完成", "失败", "累计耗时", "均速", "当前"),
    }
    for _, w in ipairs(self:workerList()) do
        local speed = "-"
        if w.done > 0 and w.totalMs > 0 then
            speed = string.format("%.1f/s", w.done / (w.totalMs / 1000))
        end
        local cur = "-"
        if w.state == "busy" and w.job and w.task then
            cur = string.format("#%d.%d %d%%", w.job, w.task, math.floor((w.progress or 0) * 100))
        elseif w.state == "offline" then
            cur = "离线 " .. util.duration(util.now() - (w.lastSeen or 0))
        end
        out[#out + 1] = string.format("%-7s %-12s %-6s %6d %6d %9s %8s  %s",
            w.virtual and "云端" or ("#" .. w.id),
            util.trunc(w.name or "-", 12),
            w.virtual and "云端" or (w.state == "busy" and "忙碌" or (w.state == "offline" and "离线" or "空闲")),
            w.done, w.fail,
            util.duration(w.totalMs), speed, cur)
    end
    if #out == 1 then out[#out + 1] = "（还没有节点连接）" end
    return out
end

-- ── 作业 ────────────────────────────────────────────────────────────────

--- opts: { priority = number }
function Sched:addJob(def, tokens, opts)
    local args, err = jobs.resolveArgs(def, tokens)
    if not args then return nil, err end
    local taskList, err2 = jobs.split(def, args)
    if not taskList then return nil, err2 end

    local id = self.nextJobId
    self.nextJobId = id + 1

    local job = {
        id = id, name = def.name, def = def, args = args,
        priority = (opts and tonumber(opts.priority)) or 0,
        paused = false,
        phase = "map",
        source = def.source, hash = def.hash,
        tasks = {}, order = {}, queue = {}, qhead = 1,
        counts = { pending = 0, running = 0, done = 0, failed = 0 },
        state = "queued",
        submittedAt = util.now(),
        total = #taskList,
    }
    for i, payload in ipairs(taskList) do
        job.tasks[i] = { id = i, payload = payload, state = "pending", tries = 0 }
        job.order[i] = i
        job.queue[#job.queue + 1] = i
        job.counts.pending = job.counts.pending + 1
    end

    -- 结果缓存：同源码 + 同参数 → 直接出结果，不占集群算力
    local nocache = opts and opts.nocache
    if self.cfg.cache and not nocache then
        job.cacheKey = state.cacheKey(job.source, args)
        local hit = state.cacheGet(job.cacheKey)
        if hit and hit.text then
            job.state = "done"
            job.cached = true
            job.resultText = hit.text
            job.cacheAt = hit.at
            job.startedAt, job.finishedAt = util.mono(), util.now()
            job.durationMs = 0
            job.counts.done, job.counts.pending = job.total, 0
            self.jobs[id] = job
            self.jobOrder[#self.jobOrder + 1] = id
            self:log(string.format("作业 #%d %s 命中结果缓存（%s 前算过），直接出结果",
                id, job.name, util.duration(util.now() - (hit.at or util.now()))), colour("lime", 32))
            for _, line in ipairs(util.split(job.resultText, "\n")) do
                self:log("  " .. line, colour("white", 1))
            end
            if self.onFinished then self.onFinished(job) end
            return job
        end
    end

    self.jobs[id] = job
    self.jobOrder[#self.jobOrder + 1] = id
    self.dirty = true
    self:log(string.format("作业 #%d %s 已提交：%d 个任务  %s",
        id, job.name, job.total, jobs.paramHelp(def)), colour("lime", 32))
    if #(job.source or "") > 8000 then
        self:log(string.format("  注意：作业源码 %s 偏大，每个任务下发时会附带源码，建议拆小",
            util.bytes(#job.source)), colour("orange", 2))
    end
    self:pump()
    return job
end

--- 激活队列里的作业，直到达到 maxParallel。
-- 排队顺序 = 提交顺序；一旦跑起来，抢任务时按优先级（高者先拿）。
function Sched:pump()
    local running = 0
    for _ in pairs(self.running) do running = running + 1 end
    local limit = math.max(1, self.cfg.maxParallel or 1)
    if running >= limit then return end
    for _, id in ipairs(self.jobOrder) do
        local job = self.jobs[id]
        if job and job.state == "queued" then
            job.state = "running"
            job.startedAt = util.mono()
            self.running[id] = true
            running = running + 1
            self:log(string.format("作业 #%d %s 开始执行（%d 个任务，优先级 %d）",
                id, job.name, job.total, job.priority or 0), colour("lightBlue", 512))
            if running >= limit then return end
        end
    end
end

--- 正在执行的作业，按（优先级降序, 提交顺序）排列
function Sched:runningJobs()
    local list = {}
    for _, id in ipairs(self.jobOrder) do
        if self.running[id] then list[#list + 1] = self.jobs[id] end
    end
    table.sort(list, function(a, b)
        local pa, pb = a.priority or 0, b.priority or 0
        if pa ~= pb then return pa > pb end
        return a.id < b.id
    end)
    return list
end

function Sched:runningCount()
    local n = 0
    for _ in pairs(self.running) do n = n + 1 end
    return n
end

--- 本机（非云端虚拟节点）有没有空闲节点
function Sched:hasIdleLocal()
    for _, w in pairs(self.workers) do
        if not w.virtual and w.state == "idle" then return true end
    end
    return false
end

--- 给云端端点取一个任务（云端是 push 模型，不走 pull）。
-- 返回 job, tid；任务在这一刻就算"已派发"，deadline 照常生效。
function Sched:takeTaskForCloud(workerId, epName)
    if self.paused then return nil end
    for _, job in ipairs(self:runningJobs()) do
        local want = job.def and job.def.cloud and job.def.cloud.endpoint
        if job.state == "running" and not job.paused and job.def and job.def.cloud
            and (want == nil or want == "any" or want == epName) then
            local tid = self:nextPending(job)
            if tid then
                local t = job.tasks[tid]
                local w = self:worker(workerId)
                t.state, t.worker, t.tries = "running", workerId, t.tries + 1
                t.startedAt, t.lastProgressAt = util.mono(), util.mono()
                t.deadline = t.startedAt + self:taskBudget(job, w, t)
                job.counts.pending = math.max(0, job.counts.pending - 1)
                job.counts.running = job.counts.running + 1
                w.task, w.job, w.state = tid, job.id, "busy"
                w.taskStartedAt = util.mono()
                self.dirty = true
                return job, tid
            end
        end
    end
    return nil
end

--- 外部（云端）结果注入：走和真节点完全一样的记账流程
function Sched:externalResult(workerId, jobId, tid, ok, data, err, ms)
    return self:onResult(workerId, proto.msg(proto.RESULT, {
        job = jobId, task = tid, ok = ok and true or false,
        data = data, err = err, ms = ms or 0,
    }))
end

--- 取该作业队列里下一个待办任务（内部队列游标）
function Sched:nextPending(job)
    while job.qhead <= #job.queue do
        local cand = job.queue[job.qhead]
        job.qhead = job.qhead + 1
        local t = cand and job.tasks[cand]
        if t and t.state == "pending" then return cand end
    end
    return nil
end

--- 计算一个任务的超时预算（秒）。
-- 自适应开启时：取作业与节点的任务耗时 EWMA 的 4 倍 + 5 秒，再夹在上下限之间。
function Sched:taskBudget(job, w, t)
    local base = self.cfg.taskTimeout
    if self.cfg.adaptiveTimeout then
        local m = 0
        if job.msEWMA then m = math.max(m, job.msEWMA) end
        if w and w.msEWMA then m = math.max(m, w.msEWMA) end
        if t and t.ms then m = math.max(m, t.ms) end
        if m > 0 then base = m * 4 / 1000 + 5 end
    end
    -- 走文件通道的任务要把传输时间算进来，否则自适应预算被压到下限后，
    -- 任务会在传大负载的中途被判超时、反复重派（表现为"偶尔特别慢"）。
    if t and t.payloadRef and t.payloadBytes then
        base = base + xfer.estimateSeconds(t.payloadBytes)
    end
    return math.max(self.cfg.taskTimeoutMin, math.min(self.cfg.taskTimeoutMax, base))
end

--- 把任务 job.tasks[tid] 派给某个节点。
-- isDup = true 表示冗余派发（同一任务的第二份，先回来的算数）
function Sched:dispatch(job, tid, workerId, isDup)
    local t = job.tasks[tid]
    local w = self:worker(workerId)

    if not isDup then
        t.state, t.worker, t.tries = "running", workerId, t.tries + 1
        t.startedAt, t.lastProgressAt = util.mono(), util.mono()
        t.deadline = t.startedAt + self:taskBudget(job, w, t)
        job.counts.pending = math.max(0, job.counts.pending - 1)
        job.counts.running = job.counts.running + 1
    else
        t.dups = t.dups or {}
        t.dups[#t.dups + 1] = workerId
        self.stats.redundant = self.stats.redundant + 1
    end

    w.task, w.job, w.state = tid, job.id, "busy"
    w.taskStartedAt, w.progress, w.note = util.mono(), 0, ""
    w.dup = isDup or nil

    -- 大负载走文件通道：把负载写进池子，只把名字发给节点（节点自己来取），
    -- 避免把几十 KB 塞进一条 modem 消息里。
    local useFile = false
    if self.cfg.fileChannel ~= false and t.payload ~= nil then
        local ok, encoded = pcall(textutils.serialize, t.payload)
        local size = ok and #encoded or 0
        if size > (self.cfg.inlineLimit or 8192) then
            local name = string.format("task-%d-%d.dat", job.id, tid)
            local wrote, wsize = state.poolPut(name, t.payload)
            if wrote then
                t.payloadRef = name
                t.payloadBytes = #encoded
                useFile = true
                if self.cfg.verbose then
                    self:log(string.format("  任务 %d.%d 负载 %s，改走文件通道（%s）",
                        job.id, tid, util.bytes(size), name), colour("lightGray", 1024))
                end
            end
            if not wrote then
                self:log("负载落盘失败，退回内联：" .. tostring(wsize), colour("orange", 2))
            end
        end
    end

    local msg = proto.msg(proto.TASK, {
        job = job.id, task = tid, name = job.name,
        hash = job.hash,
        payloadRef = useFile and t.payloadRef or nil,
        phase = t.reduce and "reduce" or nil,
        timeout = math.floor(t.deadline - util.mono()),
        tries = t.tries, dup = isDup or nil,
    })
    -- 注意不能写 `useFile and nil or t.payload`：Lua 里 nil 是假值，or 会兜底成 t.payload，
    -- 结果负载既内联又发引用（节点就用内联那份，永远不会来拉文件）。
    if not useFile then msg.payload = t.payload end
    -- reduce 任务需要 args 才能重算汇总
    if t.reduce then msg.args = job.args end
    if w.have ~= job.hash then msg.src = job.source end

    net.send(workerId, msg, util.PROTO_CTRL)
    self.dirty = true
    if self.cfg.verbose or t.tries > 1 or isDup then
        self:log(string.format("  → 任务 %d.%d 派发给 #%d（第 %d 次%s）",
            job.id, tid, workerId, t.tries, isDup and "，冗余" or ""), colour("yellow", 256))
    end
    return msg
end

--- 取一个待办任务派给节点；没有就返回 nil
function Sched:assign(workerId)
    if self.paused then return nil end
    for _, job in ipairs(self:runningJobs()) do
        if job.state == "running" and not job.paused then
            local tid = self:nextPending(job)
            if tid then return self:dispatch(job, tid, workerId, false) end
        end
    end
    return nil
end

--- 抢尾：任务快做完时，把还在算的任务复制一份给空闲节点，谁先回来算谁的。
-- 返回 true 表示已经派了冗余任务。
function Sched:assignRedundant(workerId)
    local tail = self.cfg.redundancy or 0
    if self.paused or tail <= 0 then return false end
    for _, job in ipairs(self:runningJobs()) do
        if job.state == "running" and not job.paused then
            local left = job.counts.pending + job.counts.running
            if job.counts.pending == 0 and left > 0 and left <= tail then
                for _, tid in ipairs(job.order) do
                    local t = job.tasks[tid]
                    if t.state == "running" and t.worker ~= workerId then
                        local dup = false
                        for _, id in ipairs(t.dups or {}) do
                            if id == workerId then dup = true end
                        end
                        if not dup then
                            self:dispatch(job, tid, workerId, true)
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- 把一个任务打回待办队列（重试）或标记失败
function Sched:requeue(jobId, tid, why)
    local job = self.jobs[jobId]
    if not job then return end
    local t = job.tasks[tid]
    if not t or t.state == "done" or t.state == "failed" then return end

    local oldWorker = t.worker

    if t.state == "running" then
        job.counts.running = math.max(0, job.counts.running - 1)
    elseif t.state == "pending" then
        job.counts.pending = math.max(0, job.counts.pending - 1)
    end

    if oldWorker then
        local w = self.workers[oldWorker]
        if w and w.task == tid then
            w.task, w.job = nil, nil
            w.state = (w.state == "offline") and "offline" or "idle"
        end
    end
    -- 冗余副本也要一起收回，否则那些节点会一直显示"忙碌"
    for _, id in ipairs(t.dups or {}) do
        local dw = self.workers[id]
        if dw and dw.task == tid then
            dw.task, dw.job, dw.dup = nil, nil, nil
            dw.state = (dw.state == "offline") and "offline" or "idle"
        end
    end
    t.dups = nil

    if t.tries >= self.cfg.maxTries then
        t.state, t.err = "failed", why
        job.counts.failed = job.counts.failed + 1
        self.stats.failed = self.stats.failed + 1
        local w = oldWorker and self.workers[oldWorker]
        if w then w.fail = w.fail + 1 end
        self:log(string.format("  x 任务 %d.%d 失败：%s（已派发 %d 次）",
            jobId, tid, why, t.tries), colour("red", 16384))
    else
        t.state, t.worker = "pending", nil
        job.queue[#job.queue + 1] = tid
        job.counts.pending = job.counts.pending + 1
        self.stats.retries = self.stats.retries + 1
        self:log(string.format("  ~ 任务 %d.%d 重新入队：%s", jobId, tid, why),
            colour("orange", 2))
    end
    self.dirty = true
    self:checkDone(job)
end

function Sched:checkDone(job)
    if job.state ~= "running" then return end
    if job.counts.pending > 0 or job.counts.running > 0 then return end
    -- 结果多的时候先把 reduce 也切成并行任务，等它们回来再收尾
    if self:maybeTwoLevel(job) then return end
    self:finalize(job)
end

--- 收集已成功任务的结果（按任务顺序）
function Sched:collectResults(job)
    local out = {}
    for _, tid in ipairs(job.order) do
        local t = job.tasks[tid]
        if t and t.state == "done" and t.result ~= nil then out[#out + 1] = t.result end
    end
    return out
end

--- 两级汇总：结果条数超过阈值时，把 "把所有结果 reduce 成一个" 这件事
--- 也拆成 K 个任务发给节点并行做，主控最后只对 K 个中间结果做一次 reduce。
-- 前提：该作业的 reduce 满足结合律（求和/计数这类天然满足）。
function Sched:maybeTwoLevel(job)
    if job.phase ~= "map" then return false end
    if not self.cfg.twoLevelReduce then return false end
    if job.def.twoLevel == false then return false end
    if type(job.def.reduce) ~= "function" then return false end

    local results = self:collectResults(job)
    local threshold = self.cfg.reduceThreshold or 300
    if #results < threshold then return false end

    local groupSize = math.max(2, self.cfg.reduceGroupSize or 100)
    local groups = {}
    for i = 1, #results, groupSize do
        local g = {}
        for j = i, math.min(i + groupSize - 1, #results) do g[#g + 1] = results[j] end
        groups[#groups + 1] = g
    end

    job.phase = "reduce"
    job.mapDone = #results
    job.tasks, job.order, job.queue, job.qhead = {}, {}, {}, 1
    job.total = #groups
    job.counts = { pending = #groups, running = 0, done = 0, failed = 0 }
    for i, g in ipairs(groups) do
        job.tasks[i] = { id = i, reduce = true, payload = { __reduce = g }, state = "pending", tries = 0 }
        job.order[i] = i
        job.queue[i] = i
    end
    self:log(string.format("作业 #%d 进入两级汇总：%d 条结果分成 %d 组并行 reduce",
        job.id, #results, #groups), colour("lightBlue", 512))
    self.dirty = true
    return true
end

function Sched:finalize(job)
    job.finishedAt = util.now()
    job.durationMs = math.floor((util.mono() - (job.startedAt or util.mono())) * 1000)
    self.running[job.id] = nil

    if job.counts.done == 0 then
        job.state = "failed"
        job.error = "所有任务都失败了"
    else
        local results = {}
        for _, tid in ipairs(job.order) do
            local t = job.tasks[tid]
            if t.state == "done" and t.result ~= nil then results[#results + 1] = t.result end
        end
        local res, err = jobs.reduce(job.def, results, job.args)
        if err then
            job.state, job.error = "failed", err
        else
            job.state = "done"
            job.result = res
            job.resultText = jobs.format(job.def, res, job.args)
            if job.cacheKey then
                state.cachePut(job.cacheKey, {
                    text = job.resultText, at = util.now(),
                    job = job.name, args = job.args,
                })
            end
        end
    end

    self:log(string.format("作业 #%d %s 结束：成功 %d / 失败 %d，用时 %s",
        job.id, job.name, job.counts.done, job.counts.failed, util.duration(job.durationMs)),
        job.state == "done" and colour("lime", 32) or colour("red", 16384))
    if job.state == "done" and job.resultText then
        for _, line in ipairs(util.split(job.resultText, "\n")) do
            self:log("  " .. line, colour("white", 1))
        end
    elseif job.error then
        self:log("  " .. job.error, colour("red", 16384))
    end

    for _, w in pairs(self.workers) do
        if w.job == job.id then w.job, w.task, w.state = nil, nil, "idle" end
    end

    if self.onFinished then self.onFinished(job) end
    state.appendHistory(job)
    self.dirty = true
    self:pump()
end

function Sched:cancel(jobId)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    if job.state ~= "queued" and job.state ~= "running" then
        return nil, "作业已经结束"
    end
    job.state = "cancelled"
    job.finishedAt = util.now()
    self.running[jobId] = nil

    for _, t in pairs(job.tasks) do
        if t.state == "running" and t.worker then
            net.send(t.worker, proto.msg(proto.CANCEL, { job = jobId, task = t.id }), util.PROTO_CTRL)
            local w = self.workers[t.worker]
            if w then w.task, w.job, w.state = nil, nil, "idle" end
        end
        if t.state ~= "done" then
            t.state, t.err = "failed", "已取消"
        end
    end
    job.counts = { pending = 0, running = 0, done = 0, failed = #job.order }
    self:log(string.format("作业 #%d %s 已取消", jobId, job.name), colour("orange", 2))
    self:pump()
    return true
end

-- ── 消息处理 ────────────────────────────────────────────────────────────

--- 返回 true 表示消息已被处理
function Sched:onMessage(sender, msg)
    if not proto.valid(msg) then return false end

    if msg.t == proto.WHO then
        net.send(sender, proto.msg(proto.IAM, {
            master = os.getComputerID(), version = util.VERSION,
        }), util.PROTO_CTRL)
        return true
    end

    local w = self:worker(sender, msg)

    if msg.t == proto.HELLO then
        local vok, verr = proto.compatible(msg)
        if not vok then
            self:log(string.format("节点 #%d 协议版本不兼容：%s", sender, tostring(verr)),
                colour("red", 16384))
            self:log("  请把该节点升级到与主控同一版本（主控执行 push，或重新拷贝 worker.lua）",
                colour("red", 16384))
            return true
        end
        local known = w.name ~= nil
        w.name     = msg.name or w.name or ("#" .. sender)
        w.wireless = msg.wireless
        w.have     = msg.have
        if w.state == "offline" then w.state = "idle" end
        self:log(string.format("节点 #%d 已%s：%s（%s）", sender,
            known and "重新连接" or "连接", w.name,
            w.wireless and "无线" or "有线"), colour("lime", 32))
        net.send(sender, proto.msg(proto.WELCOME, {
            master = os.getComputerID(),
            cfg = {
                pollInterval = self.cfg.pollInterval,
                taskTimeout  = self.cfg.taskTimeout,
                fileChannel  = self.cfg.fileChannel,
                inlineLimit  = self.cfg.inlineLimit,
                reHelloAfter = self.cfg.reHelloAfter,
                rediscoverAfter = self.cfg.rediscoverAfter,
            },
        }), util.PROTO_CTRL)
        return true
    end

    if msg.t == proto.PULL then
        if msg.have then w.have = msg.have end
        if w.state == "offline" then w.state = "idle" end
        if w.task then return true end            -- 还在忙，忽略重复的 pull
        if not (self:assign(sender) or self:assignRedundant(sender)) then
            net.send(sender, proto.msg(proto.IDLE, { wait = self.cfg.pollInterval }), util.PROTO_CTRL)
        end
        return true
    end

    if msg.t == proto.PROGRESS then
        local job = self.jobs[msg.job]
        local t = job and job.tasks[msg.task]
        if t and t.state == "running" and t.worker == sender then
            t.lastProgressAt = util.mono()
            t.deadline = t.lastProgressAt + self:taskBudget(job, w, t)   -- 有进展就顺延
            w.progress = tonumber(msg.pct) or w.progress
            w.note = msg.note
        end
        return true
    end

    if msg.t == proto.RESULT then
        return self:onResult(sender, msg)
    end

    if msg.t == proto.BYE then
        w.state, w.task, w.job = "offline", nil, nil
        self:log(string.format("节点 #%d 主动下线：%s", sender, tostring(msg.reason or "无")),
            colour("orange", 2))
        return true
    end

    return msg.t == proto.PONG
end

function Sched:onResult(sender, msg)
    local w = self:worker(sender, msg)
    local job = self.jobs[msg.job]
    if not job then return true end
    local t = job.tasks[msg.task]
    if not t then return true end

    -- 大结果走文件通道：节点先把数据推到主控，再发一条只带名字的结果
    if msg.ok and msg.data == nil and msg.dataRef then
        local value, derr = state.poolGet(msg.dataRef)
        if value == nil then
            msg.ok, msg.err = false, "结果文件读取失败: " .. tostring(derr)
        else
            msg.data = value
        end
    end
    if t.state == "done" or t.state == "failed" then
        -- 重复上报，或冗余副本的迟到结果：只把这个节点放回空闲
        if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end
        return true
    end

    -- 冗余副本报错不算数：正主还在算，直接把这个副本撤掉
    if t.worker ~= sender and t.state == "running" and not msg.ok then
        if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end
        for i, id in ipairs(t.dups or {}) do
            if id == sender then table.remove(t.dups, i) break end
        end
        return true
    end

    if t.state == "running" then
        job.counts.running = math.max(0, job.counts.running - 1)
    elseif t.state == "pending" then
        -- 任务已被打回队列，但这份结果仍然可用：采信并把队列里的副本抹掉
        local removed = 0
        for i = job.qhead, #job.queue do
            if job.queue[i] == t.id then
                job.queue[i] = false
                removed = removed + 1
            end
        end
        if removed > 0 then
            job.counts.pending = math.max(0, job.counts.pending - removed)
        end
    end

    local ms = tonumber(msg.ms) or 0
    w.totalMs = w.totalMs + ms
    if ms > 0 then w.msEWMA = w.msEWMA and (w.msEWMA * 0.7 + ms * 0.3) or ms end
    if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end

    -- 结果到手：正主和所有冗余副本一起放回空闲（副本可能还在算，结果会被丢弃）
    local owner = self.workers[t.worker]
    if owner and owner.task == t.id then
        owner.task, owner.job, owner.dup, owner.state = nil, nil, nil, "idle"
    end
    for _, id in ipairs(t.dups or {}) do
        local dw = self.workers[id]
        if dw and dw.task == t.id then
            dw.task, dw.job, dw.dup, dw.state = nil, nil, nil, "idle"
        end
    end
    t.dups = nil

    if msg.ok then
        t.state, t.result, t.ms = "done", msg.data, ms
        job.counts.done = job.counts.done + 1
        if ms > 0 then job.msEWMA = job.msEWMA and (job.msEWMA * 0.7 + ms * 0.3) or ms end
        w.done = w.done + 1
        self.stats.done = self.stats.done + 1
        if self.cfg.verbose or job.total <= 40 then
            self:log(string.format("  <- 任务 %d.%d 完成于 #%d（%s）",
                job.id, t.id, sender, util.duration(ms)), colour("lightGray", 1024))
        end
    else
        local why = "节点报错: " .. tostring(msg.err or "未知")
        if t.tries >= self.cfg.maxTries then
            t.state, t.err = "failed", why
            job.counts.failed = job.counts.failed + 1
            self.stats.failed = self.stats.failed + 1
            w.fail = w.fail + 1
            self:log(string.format("  x 任务 %d.%d 失败：%s", job.id, t.id, why), colour("red", 16384))
        else
            t.state, t.worker = "pending", nil
            job.queue[#job.queue + 1] = t.id
            job.counts.pending = job.counts.pending + 1
            self.stats.retries = self.stats.retries + 1
            self:log(string.format("  ~ 任务 %d.%d 重试：%s", job.id, t.id, why), colour("orange", 2))
        end
    end

    self:checkDone(job)
    self.dirty = true
    return true
end

-- ── 周期维护 ────────────────────────────────────────────────────────────

function Sched:tick()
    local nowMs, mono = util.now(), util.mono()

    for id, w in pairs(self.workers) do
        if not w.virtual and w.state ~= "offline"
            and (nowMs - (w.lastSeen or 0)) > self.cfg.workerTimeout * 1000 then
            w.state = "offline"
            self:log(string.format("节点 #%d 失去联系（>%ds）", id, self.cfg.workerTimeout),
                colour("red", 16384))
            if w.task and w.job then
                local job = self.jobs[w.job]
                local t = job and job.tasks[w.task]
                if t and t.state == "running" and t.worker == id then
                    self:requeue(w.job, w.task, "节点离线")
                elseif t and t.dups then
                    -- 掉线的只是冗余副本，正主还在算，不用重派
                    for i, wid in ipairs(t.dups) do
                        if wid == id then table.remove(t.dups, i) break end
                    end
                end
            end
            w.task, w.job, w.dup = nil, nil, nil
        end
    end

    for _, job in pairs(self.jobs) do
        if job.state == "running" then
            for tid, t in pairs(job.tasks) do
                if t.state == "running" and t.deadline and mono > t.deadline then
                    self:requeue(job.id, tid, string.format("超过 %.0fs 无进展",
                        t.deadline - (t.lastProgressAt or t.startedAt or mono)))
                end
            end
        end
    end

    self:pump()

    -- 断点续算：有变化就（至少间隔 3 秒）写一次快照
    if self.cfg.snapshot then
        local now = util.mono()
        local gap = now - (self.lastSnap or 0)
        if (self.dirty and gap >= 3) or gap >= (self.cfg.snapshotInterval or 15) then
            local ok, err = self:saveSnapshot()
            if not ok and not self.snapWarned then
                self.snapWarned = true
                self:log("快照写入失败：" .. tostring(err), colour("red", 16384))
            end
        end
    end
end

function Sched:setPriority(jobId, pri)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    job.priority = tonumber(pri) or 0
    self:log(string.format("作业 #%d 优先级改为 %d", jobId, job.priority), colour("yellow", 256))
    return true
end

function Sched:pauseJob(jobId, on)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    job.paused = on and true or false
    self:log(string.format("作业 #%d %s", jobId, job.paused and "已暂停派发" or "已恢复派发"),
        colour("orange", 2))
    return true
end

-- ── 展示 ────────────────────────────────────────────────────────────────

function Sched:activeJob()
    local list = self:runningJobs()
    return list[1]
end

function Sched:progress(job)
    if not job or job.total == 0 then return 0 end
    return (job.counts.done + job.counts.failed) / job.total
end

function Sched:statusLine()
    local running = self:runningCount()
    local parts = {
        string.format("主控 #%d", os.getComputerID()),
        string.format("节点 %d/%d", self:onlineCount(), self:workerCount()),
    }
    local queued = 0
    for _, j in pairs(self.jobs) do
        if j.state == "queued" then queued = queued + 1 end
    end

    local job = self:activeJob()
    if job then
        local pct = self:progress(job)
        parts[#parts + 1] = string.format("#%d %s %s %d%% %d/%d%s", job.id, job.name,
            util.bar(pct, 8), math.floor(pct * 100),
            job.counts.done + job.counts.failed, job.total,
            job.counts.failed > 0 and (" 失败" .. job.counts.failed) or "")
    end
    if running > 1 then
        parts[#parts + 1] = string.format("并发 %d/%d", running, math.max(1, self.cfg.maxParallel or 1))
    end
    if queued > 0 then
        parts[#parts + 1] = "队列 " .. queued
    elseif running == 0 then
        parts[#parts + 1] = "空闲"
    end
    if self.cfg.redundancy and self.cfg.redundancy > 0 then
        parts[#parts + 1] = "抢尾 " .. self.cfg.redundancy
    end
    if self.paused then parts[#parts + 1] = "已暂停" end
    return table.concat(parts, " | ")
end

function Sched:jobLines(jobId)
    local out = {}
    local list = {}
    if jobId then
        list[1] = self.jobs[jobId]
    else
        for _, id in ipairs(self.jobOrder) do list[#list + 1] = self.jobs[id] end
    end
    for _, job in ipairs(list) do
        if job then
            local pct = self:progress(job)
            local elapsed = job.durationMs or (util.now() - job.submittedAt)
            out[#out + 1] = string.format("#%-3d %-12s %-6s pri%-3d %s %3d%%  任务 %d/%d 失败 %d  用时 %s%s",
                job.id, job.name, STATE_TEXT[job.state] or job.state,
                job.priority or 0, util.bar(pct, 12), math.floor(pct * 100),
                job.counts.done + job.counts.failed, job.total, job.counts.failed,
                util.duration(elapsed), job.paused and "  [已暂停]" or "")
        end
    end
    if #out == 0 then out[1] = "（还没有作业）" end
    return out
end

function Sched:failedTaskLines(jobId, limit)
    local job = self.jobs[jobId]
    if not job then return {} end
    local out = {}
    for _, tid in ipairs(job.order) do
        local t = job.tasks[tid]
        if t.state == "failed" then
            out[#out + 1] = string.format("  任务 %d 失败：%s", tid, tostring(t.err))
            if #out >= (limit or 5) then break end
        end
    end
    return out
end

return M
