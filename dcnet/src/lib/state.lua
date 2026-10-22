--[[- dc.state — 持久化层

三件事都落在这一个模块里，因为它们都是"把运行状态写到磁盘"：

  1. 作业快照（断点续算）：把未完成的作业连同**已完成任务的结果**存下来，
     主控重启后原样接上，长作业不用从头再算。
  2. 结果缓存：同名作业 + 同参数 → 命中缓存直接出结果，不再占用集群算力。
  3. 运行历史：每个作业结束追加一行，供 `history` 指令查看。

所有数据都用 textutils.serialize 存成文本，方便人肉查看与备份。
]]

local util = dc_require("dc.util")

local M = {}

M.DIR       = util.ROOT .. "/state"
M.SNAP      = M.DIR .. "/jobs.dat"
M.CACHE_DIR = util.ROOT .. "/cache"
M.HISTORY   = util.ROOT .. "/history.log"
M.SNAP_VERSION = 1

function M.ensureDirs()
    util.ensureDir(M.DIR)
    util.ensureDir(M.CACHE_DIR)
end

-- ── 1. 作业快照 ─────────────────────────────────────────────────────────

--- 把"还没跑完"的作业（含已完成任务的结果）写成快照。
-- 正在执行的任务会退回待办：节点那边的情况没法保证，重开主控后由别的节点重算。
function M.snapshot(sched)
    M.ensureDirs()
    local snap = {
        version = M.SNAP_VERSION,
        savedAt = util.now(),
        nextJobId = sched.nextJobId,
        jobOrder = {},
        jobs = {},
    }
    for _, id in ipairs(sched.jobOrder) do
        local job = sched.jobs[id]
        if job and (job.state == "queued" or job.state == "running") then
            snap.jobOrder[#snap.jobOrder + 1] = id
            local tasks = {}
            for tid, t in pairs(job.tasks) do
                tasks[tid] = {
                    state = (t.state == "done") and "done" or "pending",
                    payload = t.payload,
                    result = t.result,
                    ms = t.ms,
                    tries = t.tries or 0,
                    err = t.err,
                    reduce = t.reduce or nil,     -- 两级汇总的中间任务
                }
            end
            snap.jobs[id] = {
                id = id, name = job.name, args = job.args,
                source = job.source, hash = job.hash,
                priority = job.priority, paused = job.paused,
                submittedAt = job.submittedAt, order = job.order, tasks = tasks,
            }
        end
    end
    local ok, err = util.writeFile(M.SNAP, textutils.serialize(snap))
    if not ok then return false, err end
    return true, snap
end

function M.hasSnapshot()
    return util.exists(M.SNAP)
end

--- 读取快照并重建到调度器里（由主控在启动时调用）。
-- 返回恢复的作业数；第二个返回值是出错信息（如果有）。
function M.restore(sched, jobsModule)
    if not util.exists(M.SNAP) then return 0, "no snapshot" end
    local raw, err = util.readFile(M.SNAP)
    if not raw then return 0, err end

    local ok, snap = pcall(textutils.unserialize, raw)
    if not ok or type(snap) ~= "table" or snap.version ~= M.SNAP_VERSION then
        return 0, "unrecognized snapshot format (version mismatch or corrupt file)"
    end

    local restored, skipped = 0, {}
    for _, id in ipairs(snap.jobOrder or {}) do
        local sj = snap.jobs[id]
        if type(sj) == "table" then
            local def, derr = jobsModule.loadSource(sj.source, "@restore-" .. tostring(id))
            if not def then
                skipped[#skipped + 1] = string.format("#%d %s (cannot load source: %s)",
                    id, tostring(sj.name), tostring(derr))
            else
                def.hash = sj.hash or def.hash
                def.source = sj.source
                local job = {
                    id = id, name = sj.name, def = def, args = sj.args,
                    priority = sj.priority or 0, paused = sj.paused or false,
                    source = sj.source, hash = sj.hash,
                    tasks = {}, order = {}, queue = {}, qhead = 1,
                    counts = { pending = 0, running = 0, done = 0, failed = 0 },
                    state = "queued",
                    submittedAt = sj.submittedAt or util.now(),
                    restored = true,
                    phase = "map",
                    total = #(sj.order or {}),
                }
                for i, tid in ipairs(sj.order or {}) do
                    local st = sj.tasks[tid] or { state = "pending" }
                    local t = {
                        id = tid, payload = st.payload, state = "pending",
                        tries = st.tries or 0, reduce = st.reduce or nil,
                    }
                    if st.reduce then job.phase = "reduce" end
                    if st.state == "done" and st.result ~= nil then
                        t.state, t.result, t.ms = "done", st.result, st.ms
                        job.counts.done = job.counts.done + 1
                    else
                        job.counts.pending = job.counts.pending + 1
                        job.queue[#job.queue + 1] = tid
                    end
                    job.tasks[tid] = t
                    job.order[i] = tid
                end
                sched.jobs[id] = job
                sched.jobOrder[#sched.jobOrder + 1] = id
                sched.nextJobId = math.max(sched.nextJobId, id + 1)
                restored = restored + 1
            end
        end
    end
    return restored, nil, skipped
end

function M.clearSnapshot()
    if util.exists(M.SNAP) then fs.delete(M.SNAP) end
end

-- ── 1b. 节点累计贡献（跨会话） ───────────────────────────────────────────

M.WORKERS = M.DIR .. "/workers.dat"

function M.loadWorkers()
    local raw = util.readFile(M.WORKERS)
    if not raw then return {} end
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

function M.saveWorkers(data)
    M.ensureDirs()
    return util.writeFile(M.WORKERS, textutils.serialize(data or {}))
end

--- 把当前会话的增量累加到历史贡献里
function M.mergeWorkers(lifetime, workers)
    lifetime = lifetime or {}
    for id, w in pairs(workers or {}) do
        local e = lifetime[id]
        if not e then
            e = { name = w.name, done = 0, fail = 0, totalMs = 0, firstSeen = util.now() }
            lifetime[id] = e
        end
        e.name = w.name or e.name
        local dDone = (w.done or 0) - (w.countedDone or 0)
        local dFail = (w.fail or 0) - (w.countedFail or 0)
        if dDone > 0 then e.done = (e.done or 0) + dDone end
        if dFail > 0 then e.fail = (e.fail or 0) + dFail end
        w.countedDone, w.countedFail = w.done or 0, w.fail or 0
        e.lastSeen = util.now()
    end
    return lifetime
end

-- ── 2. 结果缓存 ─────────────────────────────────────────────────────────

--- 缓存键 = 作业源码 + 归一化后的参数（键排序，保证同参数同键）
function M.cacheKey(source, args)
    local parts = {}
    for _, k in ipairs(util.sortedKeys(args or {})) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(args[k])
    end
    return util.hash((source or "") .. "|" .. table.concat(parts, "&"))
end

function M.cachePath(key) return M.CACHE_DIR .. "/" .. key .. ".txt" end

function M.cacheGet(key)
    if not key then return nil end
    local raw = util.readFile(M.cachePath(key))
    if not raw then return nil end
    local ok, entry = pcall(textutils.unserialize, raw)
    if not ok or type(entry) ~= "table" then return nil end
    return entry
end

function M.cachePut(key, entry)
    if not key then return false end
    M.ensureDirs()
    return util.writeFile(M.cachePath(key), textutils.serialize(entry))
end

function M.cacheList()
    local out = {}
    for _, name in ipairs(util.listDir(M.CACHE_DIR)) do
        if name:sub(-4) == ".txt" then
            local entry = M.cacheGet(name:sub(1, -5))
            out[#out + 1] = { key = name:sub(1, -5), entry = entry }
        end
    end
    table.sort(out, function(a, b) return (a.entry and a.entry.at or 0) > (b.entry and b.entry.at or 0) end)
    return out
end

function M.cacheClear()
    local n = 0
    for _, name in ipairs(util.listDir(M.CACHE_DIR)) do
        if name:sub(-4) == ".txt" then
            fs.delete(M.CACHE_DIR .. "/" .. name)
            n = n + 1
        end
    end
    return n
end

-- ── 大数据池：任务负载/结果超过内联阈值时走文件通道 ────────────────────
--
-- 命名约定（接收端按名字决定落盘位置，所以名字必须能自证用途）：
--     task-<作业> -<任务>.dat   主控 → 节点的任务负载
--     res-<作业> -<任务>.dat    节点 → 主控的任务结果

M.POOL_DIR = util.ROOT .. "/pool"
M.POOL_TTL = 900               -- 秒：池子里的文件超过这个时间可以清掉

function M.ensurePool()
    util.ensureDir(M.POOL_DIR)
end

--- 池子文件名是否合法（防止别人往任意路径写文件）
function M.validPoolName(name)
    name = tostring(name or "")
    if #name > 60 or name:find("%.%.") or name:find("[/\\]") then return false end
    return (name:match("^task%-[%w_%-]+%.dat$") ~= nil
        or name:match("^res%-[%w_%-]+%.dat$") ~= nil)
end

function M.poolPath(name)
    return M.POOL_DIR .. "/" .. name
end

--- 写一个值到池子，返回值名；失败返回 nil, err
function M.poolPut(name, value)
    M.ensurePool()
    local ok, data = pcall(textutils.serialize, value)
    if not ok then return nil, "serialization failed: " .. tostring(data) end
    local wrote, err = util.writeFile(M.poolPath(name), data)
    if not wrote then return nil, err end
    return name, #data
end

--- 从池子读一个值；读完默认删掉
function M.poolGet(name, keep)
    if not M.validPoolName(name) then return nil, "invalid pool file name" end
    local raw = util.readFile(M.poolPath(name))
    if not raw then return nil, "not in pool: " .. tostring(name) end
    local ok, value = pcall(textutils.unserialize, raw)
    if not ok or value == nil then return nil, "cannot parse pool file: " .. tostring(name) end
    if not keep and fs.exists(M.poolPath(name)) then fs.delete(M.poolPath(name)) end
    return value
end

function M.poolList()
    local out = {}
    for _, name in ipairs(util.listDir(M.POOL_DIR)) do
        if name:sub(-4) == ".dat" then
            out[#out + 1] = { name = name, size = fs.getSize(M.poolPath(name)) or 0 }
        end
    end
    return out
end

--- 清掉过期的池子文件（传输中断留下的残file），返回清理数量
function M.poolClean(nowMs)
    nowMs = nowMs or util.now()
    local n = 0
    for _, f in ipairs(M.poolList()) do
        local mt = fs.attributes(M.poolPath(f.name))
        local mtime = (type(mt) == "table" and mt.modified) or 0
        if mtime > 0 and (nowMs / 1000 - mtime) > M.POOL_TTL then
            fs.delete(M.poolPath(f.name))
            n = n + 1
        end
    end
    return n
end

-- ── 3. 运行历史 ─────────────────────────────────────────────────────────

function M.appendHistory(job)
    M.ensureDirs()
    local line = textutils.serialize({
        at = util.now(),
        id = job.id, name = job.name, state = job.state,
        done = job.counts and job.counts.done or 0,
        failed = job.counts and job.counts.failed or 0,
        ms = job.durationMs or 0,
        args = job.args,
        summary = job.resultText and util.trunc((job.resultText:gsub("\n", " ")), 120) or nil,
    })
    local h = fs.open(M.HISTORY, "a")
    if h then
        h.write(line .. "\n")
        h.close()
        return true
    end
    return false
end

function M.history(limit)
    local raw = util.readFile(M.HISTORY)
    if not raw then return {} end
    local out = {}
    for line in raw:gmatch("[^\n]+") do
        local ok, entry = pcall(textutils.unserialize, line)
        if ok and type(entry) == "table" then out[#out + 1] = entry end
    end
    -- 最新的排前面
    local recent = {}
    for i = #out, math.max(1, #out - (limit or 10) + 1), -1 do recent[#recent + 1] = out[i] end
    return recent, #out
end

return M
