--[[- dc.cloud — 云端卸载：把任务通过 HTTP 发给外部计算服务

思路：**云端端点 = 一种虚拟 worker**。它不 pull，而是主控在有空闲槽位时主动 POST
一个任务过去；结果通过 `http_success`/`http_failure` 事件回来，再走调度器原本的
记账流程（超时、重派、统计都白拿）。因此：

  * 云端慢/挂了 → 任务超时被重新入队 → 本机节点自然接手（**自动回落**）
  * 连不上端点 → 端点进入冷却（指数退避），任务立刻回队，不再反复撞墙
  * 端点完成数会出现在 `workers` 表里（名字是 cloud:<名字>），和真节点一起排行

协议（v1，POST + JSON）：

    请求  { "dcnet":1, "job":"cloudprimes", "task":7,
            "payload": {...}, "args": {...} }
    成功  { "ok":true,  "data": {...} }
    失败  { "ok":false, "err":"原因" }

具体怎么打包/解析由**作业**决定（job.cloud.build / job.cloud.parse，都在主控上跑），
所以云端只要会 HTTP+JSON，不需要懂 dcnet 的任何细节。

前提：本机 `http` 可用（单人游戏默认开；服务器上可能被 http_enable 关掉）。
]]

local util = dc_require("dc.util")

local M = {}

M.FILE    = util.ROOT .. "/cloud.dat"
M.VERSION = 1

-- ── JSON ────────────────────────────────────────────────────────────────

function M.encode(value)
    if not (textutils and textutils.serializeJSON) then
        return nil, "textutils.serializeJSON is missing (CC too old)"
    end
    local ok, out = pcall(textutils.serializeJSON, value)
    if not ok then return nil, "JSON encode failed: " .. tostring(out) end
    return out
end

function M.decode(text)
    if not (textutils and textutils.unserializeJSON) then
        return nil, "textutils.unserializeJSON is missing (CC too old)"
    end
    local ok, out = pcall(textutils.unserializeJSON, text)
    if not ok then return nil, "JSON decode failed: " .. tostring(out) end
    return out
end

function M.httpReady()
    local ok = (type(http) == "table") and (type(http.post) == "function")
    if not ok then return false, "http unavailable (http_enable may be off)" end
    if not (textutils and textutils.serializeJSON and textutils.unserializeJSON) then
        return false, "JSON support missing"
    end
    return true
end

-- ── 端点表（持久化） ────────────────────────────────────────────────────

function M.load()
    local raw = util.readFile(M.FILE)
    if not raw then return {} end
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or type(data) ~= "table" then return {} end
    local list = {}
    for i, ep in ipairs(data) do
        if type(ep) == "table" and ep.url then
            ep.id = ep.id or -i
            ep.slots = tonumber(ep.slots) or 1
            list[#list + 1] = ep
        end
    end
    return list
end

function M.save(list)
    util.ensureDir(util.ROOT)
    local out = {}
    for _, ep in ipairs(list or {}) do
        out[#out + 1] = {
            id = ep.id, name = ep.name, url = ep.url, slots = ep.slots,
            sent = ep.sent, ok = ep.ok, fail = ep.fail, totalMs = ep.totalMs,
            addedAt = ep.addedAt,
        }
    end
    return util.writeFile(M.FILE, textutils.serialize(out))
end

function M.find(list, name)
    for _, ep in ipairs(list or {}) do
        if ep.name == name then return ep end
    end
    return nil
end

--- 给端点分配一个稳定的负数 id（避免和真电脑 ID 撞车，也便于在 workers 表里显示）
local function nextId(list)
    local used = {}
    for _, ep in ipairs(list) do used[ep.id] = true end
    local i = -1
    while used[i] do i = i - 1 end
    return i
end

function M.addEndpoint(list, name, url, slots, log)
    if not name or name == "" then return nil, "endpoint name cannot be empty" end
    if not url or not tostring(url):match("^https?://") then
        return nil, "URL must start with http:// or https://"
    end
    if M.find(list, name) then return nil, "endpoint name already exists: " .. name end
    local ep = {
        id = nextId(list), name = name, url = tostring(url),
        slots = math.max(1, math.floor(tonumber(slots) or 1)),
        addedAt = util.now(), sent = 0, ok = 0, fail = 0, totalMs = 0,
    }
    list[#list + 1] = ep
    M.save(list)
    return ep
end

function M.removeEndpoint(list, name)
    for i, ep in ipairs(list) do
        if ep.name == name then
            table.remove(list, i)
            M.save(list)
            return ep
        end
    end
    return nil, "no such endpoint: " .. tostring(name)
end

-- ── 云端实例 ────────────────────────────────────────────────────────────

local Cloud = {}
M.Cloud = Cloud

--- opts: { sched=, cfg=, log= }
function M.new(opts)
    local self = setmetatable({}, { __index = Cloud })
    self.sched = opts.sched
    self.cfg = opts.cfg or {}
    self.log = opts.log or function() end
    self.endpoints = M.load()
    self.inflight = {}     -- handle -> { ep, job, task, startedAt[, chunkXid, chunkIndex, chunkLast] }
    self.chunks = {}       -- xid -> 分块上传的进行中状态
    self.tests = {}        -- handle -> function(ok, data, err)
    self.ok, self.reason = M.httpReady()
    self.sent, self.okCount, self.failCount = 0, 0, 0
    return self
end

function Cloud:enabled()
    return self.ok and (self.cfg.cloud ~= false)
end

function Cloud:find(name)
    return M.find(self.endpoints, name)
end

function Cloud:countInflight(ep)
    local n = 0
    for _, req in pairs(self.inflight) do
        if req.ep == ep then n = n + 1 end
    end
    return n
end

function Cloud:totalInflight()
    local n = 0
    for _ in pairs(self.inflight) do n = n + 1 end
    return n
end

--- 打包一个任务的请求体（由作业的 job.cloud.build 决定）
function Cloud:buildBody(job, task)
    local jobs = dc_require("dc.jobs")
    return jobs.buildCloudRequest(job.def, task, job.args)
end

--- 解析响应（由作业的 job.cloud.parse 决定）
function Cloud:parseResponse(job, task, decoded)
    local jobs = dc_require("dc.jobs")
    return jobs.parseCloudResponse(job.def, decoded, task)
end

--- 发一个请求。返回 handle 或 nil, err
-- 注意 CC 的签名不同：http.get(url, headers, binary) / http.post(url, body, headers, binary)
function Cloud:post(ep, bodyStr, headers, method)
    method = method or "POST"
    local hdrs = { ["Content-Type"] = "application/json" }
    for k, v in pairs(headers or {}) do hdrs[k] = v end
    local ok, handle, err
    if method == "GET" then
        ok, handle, err = pcall(http.get, ep.url, hdrs, true)
    else
        ok, handle, err = pcall(http.post, ep.url, bodyStr, hdrs, true)
    end
    if not ok then return nil, tostring(handle) end
    if not handle then return nil, tostring(err or "request could not be sent") end
    return handle
end

--- 冷却：连不上端点时退避，避免反复撞墙（让本机节点先接手）
function Cloud:cool(ep, why)
    ep.failures = (ep.failures or 0) + 1
    local backoff = math.min(300, 10 * (2 ^ math.min(ep.failures - 1, 5)))
    ep.cooldownUntil = util.mono() + backoff
    ep.lastError = why
    self.log(string.format("Cloud endpoint %s unavailable (%s), no retry for %d s", ep.name, tostring(why),
        backoff), 16384)
end

function Cloud:clearCool(ep)
    if ep.cooldownUntil or ep.failures then
        ep.failures, ep.cooldownUntil, ep.lastError = 0, nil, nil
    end
end

--- 由主控的 tick 循环调用：有槽位就取任务发出去
function Cloud:pump()
    if not self:enabled() then return end
    local now = util.mono()
    for _, ep in ipairs(self.endpoints) do
        while self:countInflight(ep) < (ep.slots or 1) do
            if ep.cooldownUntil and now < ep.cooldownUntil then break end
            -- 溢出模式：本机还有空闲节点时先不用云端
            if self.cfg.cloudFirst == false and self.sched:hasIdleLocal() then break end

            local job, tid = self.sched:takeTaskForCloud(ep.id, ep.name)
            if not job then break end
            local task = job.tasks[tid]

            local body, berr = self:buildBody(job, task)
            if not body then
                self.sched:externalResult(ep.id, job.id, tid, false, nil,
                    "cloud request build failed: " .. tostring(berr), 0)
            else
                local bodyStr = body
                if type(body) ~= "string" then
                    local enc, eerr = M.encode(body)
                    bodyStr, berr = enc, eerr
                end
                if not bodyStr then
                    self.sched:externalResult(ep.id, job.id, tid, false, nil,
                        "cloud request encode failed: " .. tostring(berr), 0)
                elseif #bodyStr > (tonumber(self.cfg.cloudChunk) or 65536) then
                    -- 大请求：切成 N 块逐块 POST，最后一块带 commit，服务器拼装后再执行。
                    -- HTTP 单请求有大小上限（http_max_upload），分块是唯一通用解法。
                    local xid = "cl-" .. tostring(M.randomHex and M.randomHex(6) or os.clock())
                    local limit = tonumber(self.cfg.cloudChunk) or 65536
                    self.chunks[xid] = {
                        ep = ep, job = job.id, task = tid, body = bodyStr,
                        i = 0, n = math.ceil(#bodyStr / limit), limit = limit,
                    }
                    if self.cfg.verbose then
                        self.log(string.format("  cloud request %s exceeds %d bytes, uploading in %d chunks",
                            util.bytes(#bodyStr), limit, self.chunks[xid].n), 1024)
                    end
                    self:sendNextChunk(xid)
                else
                    local handle, herr = self:post(ep, bodyStr)
                    if not handle then
                        self:cool(ep, herr)
                        self.sched:externalResult(ep.id, job.id, tid, false, nil,
                            "cloud unreachable: " .. tostring(herr), 0)
                    else
                        ep.sent = (ep.sent or 0) + 1
                        self.sent = self.sent + 1
                        self.inflight[handle] = {
                            ep = ep, job = job.id, task = tid, startedAt = now,
                        }
                    end
                end
            end
        end
    end
end

--- 发下一块（分块上传用）。返回 true 表示已发出
function Cloud:sendNextChunk(xid)
    local c = self.chunks[xid]
    if not c then return false end
    c.i = c.i + 1
    local from = (c.i - 1) * c.limit + 1
    local part = c.body:sub(from, c.i * c.limit)
    local msg = { dcnet = M.PROTO_VERSION, xid = xid, i = c.i, n = c.n, chunk = part }
    if c.i >= c.n then msg.commit = true end
    local bodyStr, eerr = M.encode(msg)
    if not bodyStr then
        self.chunks[xid] = nil
        self.sched:externalResult(c.ep.id, c.job, c.task, false, nil,
            "cloud chunk encode failed: " .. tostring(eerr), 0)
        return false
    end
    local handle, herr = self:post(c.ep, bodyStr)
    if not handle then
        self.chunks[xid] = nil
        self:cool(c.ep, herr)
        self.sched:externalResult(c.ep.id, c.job, c.task, false, nil,
            "cloud chunk upload failed: " .. tostring(herr), 0)
        return false
    end
    c.ep.sent = (c.ep.sent or 0) + 1
    self.sent = self.sent + 1
    self.inflight[handle] = {
        ep = c.ep, job = c.job, task = c.task, startedAt = util.mono(),
        chunkXid = xid, chunkIndex = c.i, chunkLast = (c.i >= c.n),
    }
    return true
end

--- 处理 http_success / http_failure 事件
function Cloud:onEvent(ev)
    local name, url, a, b = ev[1], ev[2], ev[3], ev[4]
    if name == "http_success" then
        local handle = a
        local test = self.tests[handle]
        local body = ""
        if handle and handle.readAll then
            local ok, data = pcall(handle.readAll)
            body = ok and tostring(data or "") or ""
            pcall(function() handle.close() end)
        end
        if test then
            self.tests[handle] = nil
            local decoded = M.decode(body)
            test(true, decoded or body)
            return
        end
        local req = self.inflight[handle]
        if not req then return end
        self.inflight[handle] = nil
        local ms = math.floor((util.mono() - req.startedAt) * 1000)
        local job = self.sched.jobs[req.job]
        local decoded, derr = M.decode(body)
        if not job then return end
        if not decoded then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                "cloud response is not valid JSON: " .. tostring(derr), ms)
            return
        end
        -- 分块上传：还没到最后一块就继续发下一块；最后一块的响应才是任务结果
        if req.chunkXid then
            local c = self.chunks[req.chunkXid]
            if not c then return end
            self:clearCool(req.ep)
            if not req.chunkLast then
                if type(decoded) == "table" and decoded.ok == false then
                    self.chunks[req.chunkXid] = nil
                    req.ep.fail = (req.ep.fail or 0) + 1
                    self.failCount = self.failCount + 1
                    self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                        "cloud rejected chunk: " .. tostring(decoded.err or "?"), ms)
                else
                    self:sendNextChunk(req.chunkXid)
                end
                return
            end
            self.chunks[req.chunkXid] = nil
        end
        self:clearCool(req.ep)
        req.ep.totalMs = (req.ep.totalMs or 0) + ms
        local task = job.tasks[req.task]
        if type(decoded) == "table" and decoded.ok == false then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.failCount = self.failCount + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                tostring(decoded.err or "cloud returned failure"), ms)
            return
        end
        local data, perr = self:parseResponse(job, task, decoded)
        if data == nil then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.failCount = self.failCount + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                "cloud response parse failed: " .. tostring(perr), ms)
            return
        end
        req.ep.ok = (req.ep.ok or 0) + 1
        self.okCount = self.okCount + 1
        self.sched:externalResult(req.ep.id, req.job, req.task, true, data, nil, ms)

    elseif name == "http_failure" then
        local handle = b
        local test = handle and self.tests[handle]
        if test then
            self.tests[handle] = nil
            test(false, nil, tostring(a))
            return
        end
        local req = handle and self.inflight[handle]
        if not req then return end
        self.inflight[handle] = nil
        req.ep.fail = (req.ep.fail or 0) + 1
        self.failCount = self.failCount + 1
        self:cool(req.ep, a)
        -- 任务打回队列：本机节点会接手（自动回落）
        self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
            "cloud request failed: " .. tostring(a), 0)
    end
end

--- 探活：GET 一次（服务端应实现 GET /health 之类）
function Cloud:test(name, onDone)
    local ep = self:find(name)
    if not ep then return nil, "no such endpoint: " .. tostring(name) end
    if not self.ok then return nil, self.reason end
    local handle, err = self:post(ep, nil, nil, "GET")
    if not handle then
        self:cool(ep, err)
        return nil, err
    end
    self.tests[handle] = function(ok, data, e)
        if ok then self:clearCool(ep) end
        onDone(ok, data, e)
    end
    return true
end

--- 状态展示
function Cloud:lines()
    local out = {}
    if not self.ok then
        out[#out + 1] = "Cloud offload unavailable: " .. tostring(self.reason)
        return out
    end
    if self.cfg.cloud == false then
        out[#out + 1] = "Cloud offload is off (set cloud true to enable)"
    end
    out[#out + 1] = string.format("endpoints %d, inflight %d, total ok %d / failed %d",
        #self.endpoints, self:totalInflight(), self.okCount, self.failCount)
    if #self.endpoints == 0 then
        out[#out + 1] = "  cloud add <name> <url> [slots] to register an HTTP service"
    end
    for _, ep in ipairs(self.endpoints) do
        local state = "ready"
        if ep.cooldownUntil and util.mono() < ep.cooldownUntil then
            state = string.format("cooling %ds (%s)",
                math.ceil(ep.cooldownUntil - util.mono()), tostring(ep.lastError or "?"))
        end
        out[#out + 1] = string.format("  %-10s %-34s slots %d inflight %d ok %d failed %d %s",
            ep.name, util.trunc(ep.url, 34), ep.slots or 1, self:countInflight(ep),
            ep.ok or 0, ep.fail or 0, state)
    end
    return out
end

--- 把端点注册成虚拟 worker，让它们出现在 workers 表与 top 排行里
function Cloud:registerWorkers()
    for _, ep in ipairs(self.endpoints) do
        local w = self.sched:worker(ep.id)
        w.name = "cloud:" .. ep.name
        w.virtual = true
        w.state = "idle"
        w.totalMs = ep.totalMs or 0
        w.done = ep.ok or 0
        w.fail = ep.fail or 0
    end
end

return M
