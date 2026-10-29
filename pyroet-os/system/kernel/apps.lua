--[[- pyroet-os/system/kernel/apps.lua -- Pyroet OS app runtime: packages, capabilities, lifecycles.

A package is a directory named `<name>.app` holding:

    manifest.lua    return { name = "probe", version = "0.1.0",
                             entry = "main.lua",
                             capabilities = { "fs.read" } }
    main.lua        the app body: runs inside its own coroutine
    lifecycle.lua   optional: return { on_start = ..., on_pause = ...,
                                       on_resume = ..., on_stop = ... }

`manifest.entry` is loaded and called once per start as `chunk(manifest, api)`
inside a fresh coroutine. `main.lua` may loop forever (`while true do
api.yield() end`); the scheduler pulls it forward one step per `tick()`.

Capabilities (the whole list, no inheritance):

    fs.read  fs.write  net.rpv  net.rednet  redstone  peripheral  http

An app gets a restricted API table. A capability it did not declare is still
present as a *callable* stub, so a buggy app gets `nil, "capability denied:
<cap>"` and an `APP_CAP_DENIED app=... cap=...` log line instead of a crash or a
nil-index -- the 404 semantics the design asks for. A capability that was
granted but that the host did not supply answers `nil, "capability unavailable:
<cap>"`. Neither path raises: apps are untrusted code and a denial is a normal
result, not an exception.

Declaring is not granting: `rt:set_permissions(perms)` hands the runtime a
kernel/permissions.lua instance, and the first `start` of an app asks that
module for its decisions. A capability the user denied is removed from the
record's cap set, so it takes exactly the same `capability denied` stub path as
an undeclared one -- a denied app still starts and still runs, it just cannot
reach the host object. Without a permission table the runtime keeps the old
behaviour (a declared capability is granted), which is what the P2 tests rely
on.

`api.sys` is a separate, host-supplied introspection surface, not a capability:
the host passes `sys = <table>` or `sys = function(record) -> table|nil` and only
the apps it returns a table for get anything. The four functions are `status()`
(kernel status), `apps()` (this runtime's status().apps), `perms(app)` (that
app's decisions) and `launch(name)` (start another app). Anything not supplied
answers `nil, "system unavailable: <fn>"` with `APP_SYS_UNAVAILABLE`, so an app
never gets a nil-index by asking.

Quotas, per app, refusing rather than clamping:

    starts       manifest.max_starts or opts.max_starts (default 8)
    write bytes  opts.write_limit, counted on fs.write / fs.append payloads

Both log `APP_QUOTA_START_DENIED` / `APP_QUOTA_WRITE_DENIED` and return
`nil, "quota exceeded: starts"` / `nil, "quota exceeded: fs.write"`.

Lifecycle: `on_start` runs on start, `on_pause` / `on_resume` on pause/resume,
`on_stop` on natural exit, on kill, and never twice. A failing hook is logged as
`APP_HOOK_FAIL` and does not abort the transition (the app body is independent
of its hooks). `kill` drops the coroutine: it is never scheduled again, and a
killed app cannot be started again.

Usage:

    local apps = dofile("/system/kernel/apps.lua")
    local rt = apps.new({ log = print, fs = fs, rpv = rpv, write_limit = 4096 })
    rt:scan("/apps")                       -- load every /apps/*.app
    rt:start("hello")
    while true do rt:tick(); os.sleep(0.05) end

No non-ASCII bytes in this file.
]]

local A = {}

A.VERSION = "1.0"
A.DEFAULT_MAX_STARTS = 8
A.CAPS = { "fs.read", "fs.write", "net.rpv", "net.rednet", "redstone", "peripheral", "http" }

local CAP_SET = {}
for i = 1, #A.CAPS do CAP_SET[A.CAPS[i]] = true end

local HOOK_NAMES = { "on_start", "on_pause", "on_resume", "on_stop" }

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function join(dir, name)
    local head = tostring(dir):gsub("/+$", "")
    if head == "" then head = "/" end
    return head .. "/" .. name
end

local function copy_list(list)
    local out = {}
    if type(list) == "table" then
        for i = 1, #list do out[i] = list[i] end
    end
    return out
end

local function copy_map(map)
    local out = {}
    if type(map) == "table" then
        for key, value in pairs(map) do out[key] = value end
    end
    return out
end

function A.cap_known(name)
    return CAP_SET[name] == true
end

-- ---------------------------------------------------------------------------
-- manifest parsing (pure: no fs, no loadfile, safe to unit test)
-- ---------------------------------------------------------------------------

function A.validate_manifest(raw, dir)
    if type(raw) ~= "table" then return nil, "manifest must return a table" end

    local name = raw.name
    if type(name) ~= "string" or name == "" then
        return nil, "manifest.name must be a non-empty string"
    end
    if not name:match("^[%w_%.%-]+$") then
        return nil, "manifest.name may only contain letters, digits, '_', '.' and '-'"
    end
    if name:find("..", 1, true) then
        return nil, "manifest.name must not contain '..'"
    end

    local version = raw.version
    if version == nil then version = "0.0.0" end
    if type(version) ~= "string" or version == "" then
        return nil, "manifest.version must be a non-empty string"
    end
    if #version > 32 then return nil, "manifest.version is longer than 32 bytes" end

    local entry = raw.entry
    if entry == nil then entry = "main.lua" end
    if type(entry) ~= "string" or entry == "" then
        return nil, "manifest.entry must be a non-empty string"
    end
    if entry:find("/", 1, true) or entry:find("\\", 1, true) then
        return nil, "manifest.entry must not contain a path separator"
    end
    if entry == "." or entry == ".." then
        return nil, "manifest.entry must be a plain file name"
    end

    local caps = raw.capabilities
    if caps == nil then caps = {} end
    if type(caps) ~= "table" then
        return nil, "manifest.capabilities must be a list"
    end
    local list, seen = {}, {}
    for i = 1, #caps do
        local cap = caps[i]
        if type(cap) ~= "string" then
            return nil, "manifest.capabilities[" .. i .. "] must be a string"
        end
        if not A.cap_known(cap) then
            return nil, "unknown capability '" .. cap .. "'"
        end
        if not seen[cap] then
            seen[cap] = true
            list[#list + 1] = cap
        end
    end

    local max_starts = raw.max_starts
    if max_starts ~= nil then
        if type(max_starts) ~= "number" or max_starts < 1 then
            return nil, "manifest.max_starts must be a positive number"
        end
        max_starts = math.floor(max_starts)
    end

    return {
        name = name,
        version = version,
        entry = entry,
        capabilities = list,
        max_starts = max_starts,
        dir = dir,
        raw = raw,
    }
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------

function A.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = A })
    self.opts = o
    self.fs = o.fs or rawget(_G, "fs")
    self.loadfile = o.loadfile or rawget(_G, "loadfile")
    self.sink = o.log
    self.logs = {}
    self.apps_root = o.apps_root or "/apps"
    self.max_starts = o.max_starts or A.DEFAULT_MAX_STARTS
    self.write_limit = o.write_limit
    self.hosts = {
        fs = self.fs,
        rpv = o.rpv,
        rednet = o.rednet,
        redstone = o.redstone,
        peripheral = o.peripheral,
        http = o.http,
    }
    self.records = {}
    self.index = {}
    self.ticks = 0
    self.perms = nil
    return self
end

-- ---------------------------------------------------------------------------
-- permissions (first start asks kernel/permissions.lua; see the header)
-- ---------------------------------------------------------------------------

function A:set_permissions(perms)
    if perms ~= nil and type(perms) ~= "table" then
        return nil, "permissions must be a table"
    end
    self.perms = perms
    self:log("APP_PERMS_ATTACHED root=" .. short(perms and perms.root or "-", 40))
    return true
end

-- Ask the permission table about one record and fold the answers into its cap
-- set. Runs before the entry file is loaded, so the app's api is built from the
-- granted set and nothing has to be re-gated later.
function A:apply_permissions(record)
    if not self.perms then return true end
    if record.perms_applied then return true end
    record.perms_applied = true
    local called, decisions = pcall(self.perms.ensure, self.perms, record.name,
        record.manifest.capabilities, { dir = record.dir, known = A.CAPS })
    if not called then
        self:log("APP_PERMS_FAIL app=" .. record.name .. " err=" .. short(decisions, 40))
        decisions = nil
    end
    if type(decisions) ~= "table" then
        -- fail closed: an app whose decisions could not be established runs with
        -- every capability denied, exactly like a denial (never like a grant)
        self:log("APP_PERMS_FAIL app=" .. record.name .. " err=undecided")
        decisions = {}
    end
    record.perms = decisions
    local granted, denied = 0, 0
    for i = 1, #record.manifest.capabilities do
        local cap = record.manifest.capabilities[i]
        if decisions[cap] == true then
            granted = granted + 1
        else
            record.caps[cap] = nil
            denied = denied + 1
        end
    end
    self:log("APP_PERMS_APPLIED app=" .. record.name .. " granted=" .. tostring(granted)
        .. " denied=" .. tostring(denied))
    return true
end

-- ---------------------------------------------------------------------------
-- system introspection surface (host supplied, capability free)
-- ---------------------------------------------------------------------------

A.SYS_FUNCTIONS = { "status", "apps", "perms", "launch" }

function A:sys_unavailable(record, name)
    self:log("APP_SYS_UNAVAILABLE app=" .. record.name .. " fn=" .. name)
    return nil, "system unavailable: " .. name
end

-- `opts.sys` may be one table for every app or a function(record) -> table|nil
-- so the host can hand the full surface to the launcher and nothing to an app
-- that has no business starting other apps.
function A:sys_for(record)
    local sys = self.opts.sys
    if type(sys) == "function" then
        local called, value = pcall(sys, record)
        if not called then
            self:log("APP_SYS_FAIL app=" .. record.name .. " err=" .. short(value, 40))
            return nil
        end
        sys = value
    end
    if type(sys) ~= "table" then return nil end
    return sys
end

function A:sys_api(record)
    local host = self:sys_for(record)
    local api = {}
    for i = 1, #A.SYS_FUNCTIONS do
        local name = A.SYS_FUNCTIONS[i]
        local fn = host and host[name]
        if type(fn) == "function" then
            api[name] = function(...) return fn(...) end
        else
            api[name] = function() return self:sys_unavailable(record, name) end
        end
    end
    return api
end

-- ---------------------------------------------------------------------------
-- logging
-- ---------------------------------------------------------------------------

function A:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then
        local ok = pcall(self.sink, line)
        if not ok then self.sink = nil end
    end
    return line
end

function A:lines()
    return self.logs
end

function A:text()
    return table.concat(self.logs, "\n")
end

function A:count(fragment)
    local n = 0
    for i = 1, #self.logs do
        if self.logs[i]:find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

function A:has_line(fragment)
    return self:count(fragment) > 0
end

-- ---------------------------------------------------------------------------
-- loading
-- ---------------------------------------------------------------------------

function A:read_manifest(dir)
    if not self.fs then return nil, "no file system" end
    local path = join(dir, "manifest.lua")
    if not self.fs.exists(path) then return nil, "missing manifest.lua" end
    local ok, chunk, err = pcall(self.loadfile, path)
    if not ok then return nil, "manifest load failed: " .. tostring(chunk) end
    if not chunk then return nil, "manifest load failed: " .. tostring(err) end
    local ok2, raw, err2 = pcall(chunk)
    if not ok2 then return nil, "manifest chunk failed: " .. tostring(raw) end
    if raw == nil then return nil, "manifest returned nil: " .. tostring(err2) end
    return A.validate_manifest(raw, dir)
end

function A:load(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil, "app directory required"
    end
    local manifest, err = self:read_manifest(dir)
    if not manifest then
        self:log("APP_LOAD_FAIL dir=" .. short(dir, 40) .. " err=" .. short(err))
        return nil, err
    end
    if self.index[manifest.name] then
        self:log("APP_LOAD_FAIL dir=" .. short(dir, 40)
            .. " err=duplicate_name:" .. manifest.name)
        return nil, "duplicate app name: " .. manifest.name
    end
    local entry_path = join(dir, manifest.entry)
    if not (self.fs and self.fs.exists(entry_path)) then
        self:log("APP_LOAD_FAIL dir=" .. short(dir, 40)
            .. " err=missing_entry:" .. manifest.entry)
        return nil, "missing entry file: " .. manifest.entry
    end
    local record = {
        name = manifest.name,
        dir = dir,
        manifest = manifest,
        entry_path = entry_path,
        state = "loaded",
        co = nil,
        api = nil,
        hooks = nil,
        caps = {},
        starts = 0,
        write_bytes = 0,
        denied = 0,
        error = nil,
        hook_errors = {},
    }
    for i = 1, #manifest.capabilities do
        record.caps[manifest.capabilities[i]] = true
    end
    self.records[#self.records + 1] = record
    self.index[record.name] = record
    self:log("APP_LOAD name=" .. record.name .. " version=" .. manifest.version
        .. " caps=" .. (#manifest.capabilities > 0
            and table.concat(manifest.capabilities, ",") or "-"))
    return record
end

function A:scan(root)
    local base = root or self.apps_root
    if not (self.fs and self.fs.exists(base) and self.fs.isDir(base)) then
        self:log("APP_SCAN_MISSING root=" .. short(base, 40))
        return 0, 0
    end
    local names = self.fs.list(base) or {}
    table.sort(names)
    local loaded, failed = 0, 0
    for i = 1, #names do
        local name = names[i]
        if name:sub(-4) == ".app" then
            local dir = join(base, name)
            if self.fs.isDir(dir) then
                local record = self:load(dir)
                if record then loaded = loaded + 1 else failed = failed + 1 end
            else
                self:log("APP_SCAN_IGNORE path=" .. short(dir, 40) .. " reason=not_directory")
            end
        end
    end
    self:log("APP_SCAN root=" .. short(base, 40)
        .. " loaded=" .. tostring(loaded) .. " failed=" .. tostring(failed))
    return loaded, failed
end

function A:app(name)
    return self.index[name]
end

-- read-only view of the records (the boot chain uses it to read the permission
-- table before anything is started); edits to the array do not reach the runtime
function A:entries()
    local out = {}
    for i = 1, #self.records do out[i] = self.records[i] end
    return out
end

-- ---------------------------------------------------------------------------
-- capability plumbing
-- ---------------------------------------------------------------------------

function A:denied(record, cap)
    self:log("APP_CAP_DENIED app=" .. record.name .. " cap=" .. cap)
    record.denied = record.denied + 1
    return nil, "capability denied: " .. cap
end

function A:unavailable(record, cap)
    self:log("APP_CAP_UNAVAILABLE app=" .. record.name .. " cap=" .. cap)
    return nil, "capability unavailable: " .. cap
end

local function denying_table(self, record, cap, method)
    local function refuse()
        return self[method](self, record, cap)
    end
    return setmetatable({}, {
        __index = function() return refuse end,
        __call = function() return refuse() end,
    })
end

local function gate(self, record, cap, fn)
    if not record.caps[cap] then
        return function() return self:denied(record, cap) end
    end
    if type(fn) ~= "function" then
        return function() return self:unavailable(record, cap) end
    end
    return function(...) return fn(...) end
end

local function tree(self, record, cap, host)
    if not record.caps[cap] then
        return denying_table(self, record, cap, "denied")
    end
    if host == nil then
        return denying_table(self, record, cap, "unavailable")
    end
    return host
end

local function read_text(fsx, path)
    local handle = fsx.open(path, "r")
    if not handle then return nil, "cannot open " .. tostring(path) end
    local text
    if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
    handle.close()
    return text or ""
end

local function write_text(fsx, path, data)
    local handle = fsx.open(path, "w")
    if not handle then return nil, "cannot open " .. tostring(path) .. " for write" end
    local ok, err = pcall(handle.write, data)
    handle.close()
    if not ok then return nil, "write failed: " .. tostring(err) end
    return true
end

local function append_text(fsx, path, data)
    local handle = fsx.open(path, "a")
    if not handle then return write_text(fsx, path, data) end
    local ok, err = pcall(handle.write, data)
    handle.close()
    if not ok then return nil, "append failed: " .. tostring(err) end
    return true
end

-- quota-checked writer: refuse before the bytes reach the disk, never clamp
function A:writer(record, cap, fn)
    return function(path, data)
        if not record.caps[cap] then return self:denied(record, cap) end
        if type(fn) ~= "function" then return self:unavailable(record, cap) end
        local payload = tostring(data == nil and "" or data)
        if self.write_limit and (record.write_bytes + #payload) > self.write_limit then
            self:log("APP_QUOTA_WRITE_DENIED app=" .. record.name
                .. " limit=" .. tostring(self.write_limit)
                .. " used=" .. tostring(record.write_bytes)
                .. " want=" .. tostring(#payload))
            return nil, "quota exceeded: fs.write"
        end
        local ok, err = fn(path, payload)
        if ok then record.write_bytes = record.write_bytes + #payload end
        return ok, err
    end
end

function A:build_api(record)
    local fsx = self.hosts.fs
    local api = {}
    api.name = record.name
    api.version = record.manifest.version
    api.manifest = {
        name = record.manifest.name,
        version = record.manifest.version,
        entry = record.manifest.entry,
        capabilities = copy_list(record.manifest.capabilities),
    }
    api.fs = {
        read = gate(self, record, "fs.read", fsx and function(path)
            return read_text(fsx, path)
        end),
        list = gate(self, record, "fs.read", fsx and function(path)
            return fsx.list(path)
        end),
        exists = gate(self, record, "fs.read", fsx and function(path)
            return fsx.exists(path)
        end),
        size = gate(self, record, "fs.read", fsx and function(path)
            return fsx.getSize(path)
        end),
        -- free space is read-only information about the medium, so it rides on
        -- fs.read; a host without the call answers "capability unavailable"
        getFreeSpace = gate(self, record, "fs.read",
            fsx and type(fsx.getFreeSpace) == "function" and function(path)
                return fsx.getFreeSpace(path)
            end or nil),
        write = self:writer(record, "fs.write", fsx and function(path, data)
            return write_text(fsx, path, data)
        end),
        append = self:writer(record, "fs.write", fsx and function(path, data)
            return append_text(fsx, path, data)
        end),
        delete = gate(self, record, "fs.write", fsx and function(path)
            return fsx.delete(path)
        end),
        makeDir = gate(self, record, "fs.write", fsx and function(path)
            return fsx.makeDir(path)
        end),
    }
    api.net = {
        rpv = tree(self, record, "net.rpv", self.hosts.rpv),
        rednet = tree(self, record, "net.rednet", self.hosts.rednet),
    }
    api.redstone = tree(self, record, "redstone", self.hosts.redstone)
    api.peripheral = tree(self, record, "peripheral", self.hosts.peripheral)
    api.http = tree(self, record, "http", self.hosts.http)
    api.sys = self:sys_api(record)
    api.log = function(message)
        self:log("APP_LOG app=" .. record.name .. " msg=" .. short(message, 80))
    end
    api.yield = function()
        return coroutine.yield()
    end
    api.sleep = function(ticks)
        local n = math.floor(tonumber(ticks) or 1)
        if n < 1 then n = 1 end
        if n > 60 then n = 60 end
        for _ = 1, n do coroutine.yield() end
    end
    return api
end

-- lifecycle hooks: lifecycle.lua wins, manifest functions are the fallback
function A:hooks_for(record)
    local hooks = {}
    local path = join(record.dir, "lifecycle.lua")
    if self.fs and self.fs.exists(path) then
        local ok, chunk, err = pcall(self.loadfile, path)
        if not ok or not chunk then
            self:log("APP_HOOK_FILE_FAIL app=" .. record.name
                .. " err=" .. short(err or chunk))
        else
            local ok2, ret = pcall(chunk, record.manifest, record.api)
            if not ok2 then
                self:log("APP_HOOK_FILE_FAIL app=" .. record.name .. " err=" .. short(ret))
            elseif type(ret) ~= "table" then
                self:log("APP_HOOK_FILE_FAIL app=" .. record.name .. " err=not_a_table")
            else
                for i = 1, #HOOK_NAMES do
                    local name = HOOK_NAMES[i]
                    if type(ret[name]) == "function" then hooks[name] = ret[name] end
                end
            end
        end
    end
    for i = 1, #HOOK_NAMES do
        local name = HOOK_NAMES[i]
        if hooks[name] == nil and type(record.manifest.raw[name]) == "function" then
            hooks[name] = record.manifest.raw[name]
        end
    end
    return hooks
end

function A:call_hook(record, name)
    local hook = record.hooks and record.hooks[name]
    if type(hook) ~= "function" then return true end
    local ok, err = pcall(hook, record.manifest, record.api)
    if not ok then
        record.hook_errors[#record.hook_errors + 1] = name .. ": " .. tostring(err)
        self:log("APP_HOOK_FAIL app=" .. record.name .. " hook=" .. name
            .. " err=" .. short(err))
        return nil, tostring(err)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function A:start(name)
    local record = self.index[name]
    if not record then return nil, "no such app: " .. tostring(name) end
    if record.state == "killed" then return nil, "app is killed: " .. name end
    if record.state == "running" or record.state == "paused" then
        return nil, "app already running: " .. name
    end
    local limit = record.manifest.max_starts or self.max_starts
    if limit and record.starts >= limit then
        self:log("APP_QUOTA_START_DENIED app=" .. name
            .. " limit=" .. tostring(limit)
            .. " starts=" .. tostring(record.starts))
        return nil, "quota exceeded: starts"
    end
    -- declared is not granted: ask the permission table before the entry is
    -- loaded, so the api below is built from the granted set
    self:apply_permissions(record)
    local ok, chunk, err = pcall(self.loadfile, record.entry_path)
    if not ok or not chunk then
        self:log("APP_START_FAIL app=" .. name .. " err=" .. short(err or chunk))
        return nil, "cannot load entry: " .. tostring(err or chunk)
    end
    local api = self:build_api(record)
    record.api = api
    record.hooks = self:hooks_for(record)
    record.starts = record.starts + 1
    record.state = "running"
    record.error = nil
    record.co = coroutine.create(function()
        -- entry convention: the file returns the body, `return function(m, api)`
        -- (a file that does its work at chunk level and returns nothing is fine
        -- too, the second call is simply skipped)
        local body = chunk(record.manifest, api)
        if type(body) == "function" then
            return body(record.manifest, api)
        end
        return body
    end)
    self:log("APP_START name=" .. name .. " starts=" .. tostring(record.starts)
        .. " caps=" .. (#record.manifest.capabilities > 0
            and table.concat(record.manifest.capabilities, ",") or "-"))
    self:call_hook(record, "on_start")
    return true
end

-- one scheduling step for one app; returns true when the coroutine advanced
function A:step(name)
    local record = self.index[name]
    if not record then return nil, "no such app: " .. tostring(name) end
    if record.state ~= "running" or not record.co then return false end
    if coroutine.status(record.co) ~= "suspended" then return false end
    local ok, err = coroutine.resume(record.co)
    if not ok then
        record.state = "crashed"
        record.error = tostring(err)
        record.co = nil
        self:log("APP_CRASH app=" .. record.name .. " err=" .. short(err))
        return false
    end
    if coroutine.status(record.co) == "dead" then
        record.state = "stopped"
        record.co = nil
        self:log("APP_EXIT app=" .. record.name .. " tick=" .. tostring(self.ticks))
        self:call_hook(record, "on_stop")
    end
    return true
end

function A:tick()
    self.ticks = self.ticks + 1
    local advanced = 0
    for i = 1, #self.records do
        local record = self.records[i]
        if record.state == "running" and record.co then
            if self:step(record.name) then advanced = advanced + 1 end
        end
    end
    return advanced
end

function A:pause(name)
    local record = self.index[name]
    if not record then return nil, "no such app: " .. tostring(name) end
    if record.state ~= "running" then
        return nil, "app is not running: " .. name .. " (" .. tostring(record.state) .. ")"
    end
    record.state = "paused"
    self:call_hook(record, "on_pause")
    self:log("APP_PAUSE name=" .. name)
    return true
end

function A:resume(name)
    local record = self.index[name]
    if not record then return nil, "no such app: " .. tostring(name) end
    if record.state == "killed" then return nil, "app is killed: " .. name end
    if record.state ~= "paused" then
        return nil, "app is not paused: " .. name .. " (" .. tostring(record.state) .. ")"
    end
    record.state = "running"
    self:call_hook(record, "on_resume")
    self:log("APP_RESUME name=" .. name)
    return true
end

function A:kill(name)
    local record = self.index[name]
    if not record then return nil, "no such app: " .. tostring(name) end
    if record.state == "killed" then return true end
    self:call_hook(record, "on_stop")
    record.co = nil
    record.state = "killed"
    self:log("APP_KILL name=" .. name .. " starts=" .. tostring(record.starts))
    return true
end

function A:status()
    local counts = { loaded = 0, running = 0, paused = 0, stopped = 0, crashed = 0, killed = 0 }
    local list = {}
    for i = 1, #self.records do
        local record = self.records[i]
        counts[record.state] = (counts[record.state] or 0) + 1
        list[#list + 1] = {
            name = record.name,
            version = record.manifest.version,
            state = record.state,
            starts = record.starts,
            write_bytes = record.write_bytes,
            denied = record.denied,
            capabilities = copy_list(record.manifest.capabilities),
            grants = copy_map(record.perms),
            error = record.error,
            hook_errors = copy_list(record.hook_errors),
        }
    end
    return {
        version = A.VERSION,
        ticks = self.ticks,
        count = #self.records,
        counts = counts,
        apps = list,
    }
end

return A
