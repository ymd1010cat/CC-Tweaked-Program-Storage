--[[- pyroet-os/system/kernel/init.lua -- Pyroet OS kernel: service manager.

Owns three things and nothing else:

  1. the service registry (`register(name, spec)`) with its declared dependencies,
  2. topological start order and failure isolation on start,
  3. health aggregation (`status()`), which is what the bootloader's readiness
     check (DECISIONS.md 2.7) reads before the first frame and the commit.

Failure isolation is deliberate: one service raising from `start` is recorded as
`KERNEL_SERVICE_FAIL` and everything that declared a dependency on it is skipped
as `KERNEL_SERVICE_SKIP`; unrelated services still start, and the aggregate
health turns `degraded` instead of taking the kernel down. A kernel whose every
registered service failed is `failed` (fatal for the boot chain), because that is
no longer an isolated fault.

Spec (all fields optional except `start`):

    {
      start  = function(kernel) return true end,       -- false/nil = failure
      stop   = function(kernel) end,                   -- best effort, reverse order
      health = function(kernel) return true end,       -- true/"ok", "degraded", false
      deps   = { "other", "service" },
    }

A start that returns nothing at all is treated as FAILED: a service has to say
it is up, otherwise a typo'd `start` silently reports success.

Usage:

    local kernel = dofile("/system/kernel/init.lua")
    local k = kernel.new({ log = print })
    k:register("net", { deps = {}, start = function() return true end })
    k:register("ui",  { deps = { "net" }, start = function() return true end })
    local status = k:start_all()
    if status.health == "failed" then os.reboot() end

`log` receives one ASCII line per event; every line is also kept in `k.logs` so
callers (and tests) can inspect what happened without a file system.

No non-ASCII bytes in this file.
]]

local K = {}

K.VERSION = "1.0"

local STATES = { "registered", "running", "failed", "skipped", "stopped" }

local function is_state(value)
    for i = 1, #STATES do
        if STATES[i] == value then return true end
    end
    return false
end

-- one ASCII line, never newline-broken, so log lines stay greppable
local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function copy_list(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------

function K.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = K })
    self.opts = o
    self.sink = o.log
    self.logs = {}
    self.records = {}
    self.index = {}
    self.order = nil
    self.started = false
    self.stopped = false
    self.last_status = nil
    return self
end

function K.noop()
    return true
end

-- ---------------------------------------------------------------------------
-- logging
-- ---------------------------------------------------------------------------

function K:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then
        local ok = pcall(self.sink, line)
        if not ok then
            -- a broken sink must not take the kernel with it; keep the ring only
            self.sink = nil
        end
    end
    return line
end

function K:lines()
    return self.logs
end

function K:text()
    return table.concat(self.logs, "\n")
end

-- plain substring count (no patterns), which is what a test wants
function K:count(fragment)
    local n = 0
    for i = 1, #self.logs do
        if self.logs[i]:find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

function K:has_line(fragment)
    return self:count(fragment) > 0
end

-- ---------------------------------------------------------------------------
-- registry
-- ---------------------------------------------------------------------------

function K:register(name, spec)
    if type(name) ~= "string" or not name:match("^[%w_%.%-]+$") then
        return nil, "invalid service name: " .. tostring(name)
    end
    if self.started then
        return nil, "kernel already started, cannot register " .. name
    end
    if self.index[name] then
        return nil, "duplicate service: " .. name
    end
    if type(spec) ~= "table" then
        return nil, "service spec must be a table: " .. name
    end
    if type(spec.start) ~= "function" then
        return nil, "service start must be a function: " .. name
    end
    if spec.stop ~= nil and type(spec.stop) ~= "function" then
        return nil, "service stop must be a function: " .. name
    end
    if spec.health ~= nil and type(spec.health) ~= "function" then
        return nil, "service health must be a function: " .. name
    end
    local deps = spec.deps
    if deps == nil then deps = {} end
    if type(deps) ~= "table" then
        return nil, "service deps must be a list: " .. name
    end
    local list = {}
    local seen = {}
    for i = 1, #deps do
        local dep = deps[i]
        if type(dep) ~= "string" or dep == "" then
            return nil, "service dep must be a name: " .. name
        end
        if dep == name then
            return nil, "service cannot depend on itself: " .. name
        end
        if not seen[dep] then
            seen[dep] = true
            list[#list + 1] = dep
        end
    end
    local record = {
        name = name,
        spec = spec,
        deps = list,
        state = "registered",
        error = nil,
    }
    self.records[#self.records + 1] = record
    self.index[name] = record
    self:log("KERNEL_REGISTER name=" .. name
        .. " deps=" .. (#list > 0 and table.concat(list, ",") or "-"))
    return record
end

function K:get(name)
    return self.index[name]
end

function K:names()
    local out = {}
    for i = 1, #self.records do out[i] = self.records[i].name end
    return out
end

-- ---------------------------------------------------------------------------
-- start order (DFS over declared deps, cycle aware)
-- ---------------------------------------------------------------------------

function K:start_order()
    local order, done, mark = {}, {}, {}
    local cycles, stack, cycle_member = {}, {}, {}

    local function visit(name)
        local record = self.index[name]
        if not record then return end
        if done[name] then return end
        if mark[name] == "visiting" then
            -- found a back edge: every node from `name` up the stack is in it
            cycles[#cycles + 1] = name
            local hit = false
            for i = 1, #stack do
                if stack[i] == name then hit = true end
                if hit then cycle_member[stack[i]] = true end
            end
            return
        end
        mark[name] = "visiting"
        stack[#stack + 1] = name
        for i = 1, #record.deps do
            local dep = record.deps[i]
            if not self.index[dep] then
                if record.state == "registered" then
                    record.state = "failed"
                    record.error = "unknown dependency '" .. dep .. "'"
                    self:log("KERNEL_UNKNOWN_DEP name=" .. name .. " dep=" .. dep)
                    self:log("KERNEL_SERVICE_FAIL name=" .. name
                        .. " err=unknown_dependency:" .. short(dep, 24))
                end
            else
                visit(dep)
            end
        end
        stack[#stack] = nil
        mark[name] = "done"
        done[name] = true
        order[#order + 1] = name
    end

    for i = 1, #self.records do visit(self.records[i].name) end

    for name in pairs(cycle_member) do
        local record = self.index[name]
        if record and record.state == "registered" then
            record.state = "failed"
            record.error = "dependency cycle"
            self:log("KERNEL_DEP_CYCLE name=" .. name)
            self:log("KERNEL_SERVICE_FAIL name=" .. name .. " err=dependency_cycle")
        end
    end
    return order
end

-- ---------------------------------------------------------------------------
-- start / stop
-- ---------------------------------------------------------------------------

function K:start_all()
    if self.started then
        self:log("KERNEL_ALREADY_STARTED services=" .. tostring(#self.records))
        return self:status()
    end
    self.started = true
    local order = self:start_order()
    self.order = order

    for i = 1, #order do
        local name = order[i]
        local record = self.index[name]
        if record and record.state == "registered" then
            local blocked = nil
            for j = 1, #record.deps do
                local dep = self.index[record.deps[j]]
                if not dep or dep.state ~= "running" then
                    blocked = record.deps[j]
                    break
                end
            end
            if blocked then
                record.state = "skipped"
                record.error = "dependency not running: " .. blocked
                self:log("KERNEL_SERVICE_SKIP name=" .. name .. " missing=" .. blocked)
            else
                local ok, ret, err = pcall(record.spec.start, self)
                if not ok then
                    record.state = "failed"
                    record.error = tostring(ret)
                    self:log("KERNEL_SERVICE_FAIL name=" .. name .. " err=" .. short(ret))
                elseif ret == nil or ret == false then
                    record.state = "failed"
                    record.error = tostring(err == nil and "start returned no value" or err)
                    self:log("KERNEL_SERVICE_FAIL name=" .. name .. " err=" .. short(record.error))
                else
                    record.state = "running"
                    record.error = nil
                    self:log("KERNEL_SERVICE_START name=" .. name)
                end
            end
        end
    end

    local status = self:status()
    self.last_status = status
    if status.health == "ok" then
        self:log("KERNEL_READY services=" .. tostring(status.counts.running))
    else
        self:log("KERNEL_DEGRADED health=" .. status.health
            .. " running=" .. tostring(status.counts.running)
            .. " failed=" .. tostring(status.counts.failed)
            .. " skipped=" .. tostring(status.counts.skipped))
    end
    return status
end

function K:stop_all()
    local order = self.order
    if not order then
        order = self:names()
    end
    local called = 0
    for i = #order, 1, -1 do
        local record = self.index[order[i]]
        if record and record.state == "running" then
            called = called + 1
            local ok, err = pcall(record.spec.stop or K.noop, self)
            record.state = "stopped"
            if ok then
                self:log("KERNEL_SERVICE_STOP name=" .. record.name)
            else
                record.error = tostring(err)
                self:log("KERNEL_SERVICE_STOP_FAIL name=" .. record.name
                    .. " err=" .. short(err))
            end
        end
    end
    self.stopped = true
    self:log("KERNEL_STOPPED services=" .. tostring(called))
    return called
end

-- ---------------------------------------------------------------------------
-- status / health aggregation
-- ---------------------------------------------------------------------------

local function probe_health(self, record)
    if type(record.spec.health) ~= "function" then return "ok", nil end
    local ok, ret = pcall(record.spec.health, self)
    if not ok then
        self:log("KERNEL_SERVICE_HEALTH_FAIL name=" .. record.name
            .. " err=" .. short(ret))
        return "failed", tostring(ret)
    end
    if ret == nil or ret == true or ret == "ok" then return "ok", nil end
    if ret == false or ret == "failed" then
        self:log("KERNEL_SERVICE_HEALTH_FAIL name=" .. record.name .. " err=reported_failed")
        return "failed", "reported failed"
    end
    if ret ~= "degraded" then
        self:log("KERNEL_SERVICE_HEALTH_UNKNOWN name=" .. record.name
            .. " value=" .. short(ret, 24))
    end
    return "degraded", nil
end

function K:status()
    local counts = { registered = 0, running = 0, failed = 0, skipped = 0, stopped = 0 }
    local services = {}
    for i = 1, #self.records do
        local record = self.records[i]
        if not is_state(record.state) then record.state = "registered" end
        counts[record.state] = (counts[record.state] or 0) + 1
        local entry = {
            name = record.name,
            state = record.state,
            deps = copy_list(record.deps),
            error = record.error,
            healthy = nil,
        }
        if record.state == "running" then
            local healthy, err = probe_health(self, record)
            entry.healthy = healthy
            if err then entry.error = err end
        end
        services[#services + 1] = entry
    end

    local health = "ok"
    if self.started and not self.stopped and counts.running == 0 and #self.records > 0 then
        health = "failed"
    elseif counts.failed > 0 or counts.skipped > 0 then
        health = "degraded"
    end
    if health == "ok" then
        for i = 1, #services do
            local healthy = services[i].healthy
            if healthy and healthy ~= "ok" then
                health = "degraded"
                break
            end
        end
    end
    return {
        version = K.VERSION,
        health = health,
        fatal = health == "failed",
        started = self.started,
        stopped = self.stopped,
        counts = counts,
        services = services,
    }
end

return K
