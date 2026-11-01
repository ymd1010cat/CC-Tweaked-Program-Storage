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
    input    terminal

The two UI capabilities are deliberately separate. `input` is the event side:
`api.input.pullEvent(...)` (a gated function; the host supplies the raw pull
through `opts.input`, a table `{ pullEvent = fn, keys = <keys api> }` or just
the pull function) and `api.input.keys` (the key-name table). `terminal` is the
screen side: `api.terminal` is the host's terminal object (`opts.terminal`,
normally the ROM's `term`), or a refusing table when the capability is missing.
An app can therefore ask for the keyboard without the screen, or the screen
without the keyboard; neither implies the other, and nothing else in the api
grew a screen or an event source.

Both are opt-in and additive: a package that never declares them gets refusing
stubs and keeps exactly the api it had before the capabilities existed (the
fields are new, nothing was moved or renamed). A manifest with no
`capabilities` at all declares the empty list, so every capability is denied --
there is no implicit legacy grant, and that is the P2 behaviour unchanged.

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
on. A capability the decision file does not mention is denied as well: this is
how an app that later declares `input` / `terminal` stays ungranted until
someone runs `permissions.reset(app)`, instead of a stale file silently
acquiring new permissions.

`api.sys` is a separate, host-supplied introspection surface, not a capability:
the host passes `sys = <table>` or `sys = function(record) -> table|nil` and only
the apps it returns a table for get anything. The four host functions are
`status()` (kernel status), `apps()` (this runtime's status().apps), `perms(app)`
(that app's decisions) and `launch(name)` (start another app). Anything not
supplied answers `nil, "system unavailable: <fn>"` with `APP_SYS_UNAVAILABLE`, so
an app never gets a nil-index by asking.

`install(name)`, `uninstall(name)` and `list()` are the other half of that
surface, and this runtime builds them rather than the host, because they are the
only system calls gated on the calling app's own capabilities: install and
uninstall need `fs.write`, list needs `fs.read`, and a refusal is the usual
`nil, "capability denied: <cap>"` plus `APP_CAP_DENIED` -- never a raise. They
forward to one `kernel/installer.lua` instance, built by startup.lua and passed
as `opts.installer`; with no instance they answer `nil, "installer unavailable"`
(the installer app's T1 wording), so a machine without the installer still
boots. A name is one package name -- letters, digits, '_' and '-', at most
A.APP_NAME_MAX bytes -- and `uninstall` refuses a package that lives under the
system root with `nil, "system app"` and `APP_SYS_PROTECT name=...`, because
image packages move only through an OTA (DECISIONS.md 1.2(c)). Every call logs
exactly one `APP_INSTALL name=... ok=...` / `APP_UNINSTALL name=... ok=...` /
`APP_LIST n=...` line.

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

An app body's return value is kept: `status().apps[i].result` and the record's
`result` field hold what `main.lua` returned when its coroutine finished (the
`APP_EXIT` line repeats it). The desktop event loop (kernel/desktop.lua) reads
`"quit"` out of it to hand the machine back to the shell; the runtime itself
only records the word and never acts on it.

A refused start is never silent: every `start` that answers `nil, err` also
writes one `APP_START_DENIED name=.. reason=no_such_app|killed|already_running|..`
line. The `already_running` case is what a desktop app launching *itself* looks
like, so "press Enter on the launcher again" leaves a record instead of nothing.

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
A.CAPS = { "fs.read", "fs.write", "net.rpv", "net.rednet", "redstone", "peripheral",
    "http", "input", "terminal" }

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
        -- O3: the UI hosts. `input` is a table { pullEvent = fn, keys = api } (a
        -- bare function is accepted as the pull), `terminal` is a term-like table.
        input = o.input,
        terminal = o.terminal,
    }
    self.records = {}
    self.index = {}
    self.ticks = 0
    self.perms = nil
    -- kernel/installer.lua, built once by startup.lua (T4); the system surface
    -- forwards install/uninstall/list to it, and its absence is a normal answer
    self.installer = o.installer
    return self
end

-- ---------------------------------------------------------------------------
-- permissions (first start asks kernel/permissions.lua; see the header)
-- ---------------------------------------------------------------------------

-- Re-point the runtime's log sink. The desktop phase installs a file-only
-- logger here (`startup.P.quiet_log`): an APP_LOG line printed to the console
-- lands on the desktop frame, which is why the frame used to look "not ready".
function A:set_log(fn)
    if fn ~= nil and type(fn) ~= "function" then
        return nil, "log sink must be a function"
    end
    self.sink = fn
    return true
end

function A:set_permissions(perms)
    if perms ~= nil and type(perms) ~= "table" then
        return nil, "permissions must be a table"
    end
    self.perms = perms
    self:log("APP_PERMS_ATTACHED root=" .. short(perms and perms.root or "-", 40))
    return true
end

-- Ask the permission table about one record and fold the answers into its cap
-- set, before the entry file is loaded so the api is built from the granted set.
--
-- -> true when the start may go ahead, nil + reason when it may not. The one "not
-- a denial" refusal is `permission pending: <cap>`: the table queued it for the
-- user (permissions rule 6), so the app is deferred, not refused -- and
-- `perms_applied` is cleared so the retry after the answer re-asks.
function A:apply_permissions(record)
    if not self.perms then return true end
    if record.perms_applied then return true end
    record.perms_applied = true
    local called, decisions, info = pcall(self.perms.ensure, self.perms, record.name,
        record.manifest.capabilities, { dir = record.dir, known = A.CAPS })
    if not called then
        self:log("APP_PERMS_FAIL app=" .. record.name .. " err=" .. short(decisions, 40))
        decisions = nil
    end
    if type(decisions) ~= "table" then
        if called and type(info) == "table" and info.source == "ask" then
            local cap = tostring(info.pending_cap or "?")
            record.perms_applied = false
            self:log("APP_PERM_PENDING app=" .. record.name .. " cap=" .. short(cap, 24))
            return nil, "permission pending: " .. cap
        end
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

A.SYS_FUNCTIONS = { "status", "apps", "perms", "launch", "install", "uninstall",
    "list", "ota_list", "ota_apply", "rescan",
    -- Android-style permission surface (kernel/permissions.lua rules 6): the
    -- launcher answers a queued request, Settings lists and toggles decisions
    "perms_answer", "perms_set", "perms_list" }
-- the three installer entries above are served by this runtime (see the
-- installer bridge section); the four before them come from the host table
A.SYS_INSTALLER = {
    install = { cap = "fs.write", method = "sys_install" },
    uninstall = { cap = "fs.write", method = "sys_uninstall" },
    list = { cap = "fs.read", method = "sys_list" },
}
-- the desktop OTA surface (T5): the launcher never touches a source file
-- itself -- the kernel reads the medium, parses the meta with kernel/ota.lua and
-- applies a package through the same installer object as api.sys.install
A.SYS_OTA = {
    ota_list = { cap = "fs.read", method = "sys_ota_list" },
    ota_apply = { cap = "fs.write", method = "sys_ota_apply" },
}
-- T7: a pocket computer has no disk drive. The internal /pkgs directory is the
-- only package source: nothing else is ever mounted.
A.OTA_INTERNAL = "/pkgs"
-- T15: launch and rescan are runtime-served too, so a package installed at run
-- time is launchable without a reboot: `launch` rescans once when the name is
-- unknown, and `rescan` is exposed for a caller that wants to ask first.
A.SYS_RUNTIME = {
    launch = { cap = nil, method = "sys_launch" },
    rescan = { cap = "fs.read", method = "sys_rescan" },
}
-- The permission surface. Capability free (no capability means "may decide
-- permissions"), gated like every bridge: only a package the host gave a system
-- surface reaches it, so a user package can never grant itself anything.
A.SYS_PERMS = {
    perms_answer = { cap = nil, method = "sys_perms_answer" },
    perms_set = { cap = nil, method = "sys_perms_set" },
    perms_list = { cap = nil, method = "sys_perms_list" },
}
-- same ceiling as kernel/installer.lua's NAME_MAX
A.APP_NAME_MAX = 40

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
        local bridge = A.SYS_INSTALLER[name]
        if bridge == nil then bridge = A.SYS_OTA[name] end
        if bridge == nil then bridge = A.SYS_RUNTIME[name] end
        if bridge == nil then bridge = A.SYS_PERMS[name] end
        if bridge then
            -- the installer bridge is the runtime's own function: it has to ask
            -- this record's cap set before anything reaches the installer. It
            -- also rides on the same entitlement as the rest of api.sys -- a
            -- package the host gave no system surface is not an installer.
            local method = bridge.method
            if host == nil then
                api[name] = function() return self:sys_unavailable(record, name) end
            else
                api[name] = function(...) return self[method](self, record, ...) end
            end
        else
            local fn = host and host[name]
            if type(fn) == "function" then
                api[name] = function(...) return fn(...) end
            else
                api[name] = function() return self:sys_unavailable(record, name) end
            end
        end
    end
    return api
end

-- ---------------------------------------------------------------------------
-- the installer bridge: api.sys.install / uninstall / list (T4)
-- ---------------------------------------------------------------------------

-- What a caller may name: one package name, never a path. The pattern is
-- deliberately narrower than a manifest name (no '.'), so `..`, `a/b` and every
-- absolute path are refused before the name is joined onto a root.
function A.app_name_ok(name)
    if type(name) ~= "string" or name == "" or #name > A.APP_NAME_MAX then
        return false
    end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return false end
    if name:find("..", 1, true) then return false end
    return name:match("^[%w_%-]+$") ~= nil
end

function A:installer_of()
    local inst = self.installer
    if type(inst) ~= "table" then return nil end
    return inst
end

-- is `name` an image package? Read from the installer's own system root so the
-- answer matches the object that would otherwise be asked to delete it.
function A:app_is_system(name, inst)
    local fsx = (inst and inst.fs) or self.fs
    local root = inst and inst.system_root or nil
    if type(root) ~= "string" or root == "" then root = "/system/system" end
    if type(fsx) ~= "table" or type(fsx.exists) ~= "function" then return false end
    local called, exists = pcall(fsx.exists, join(root, name .. ".app"))
    return called and exists == true
end

function A:sys_install(record, name)
    if not record.caps["fs.write"] then return self:denied(record, "fs.write") end
    local inst = self:installer_of()
    local label = "APP_INSTALL name=" .. short(name)
    if not inst or type(inst.install) ~= "function" then
        self:log(label .. " ok=false")
        return nil, "installer unavailable"
    end
    if not A.app_name_ok(name) then
        self:log(label .. " ok=false")
        return nil, "bad name"
    end
    local called, ok, info = pcall(inst.install, inst, name)
    if not called then ok, info = false, tostring(ok) end
    self:log(label .. " ok=" .. tostring(ok == true))
    if ok ~= true then return nil, tostring(info) end
    return true, info
end

function A:sys_uninstall(record, name)
    if not record.caps["fs.write"] then return self:denied(record, "fs.write") end
    local inst = self:installer_of()
    local label = "APP_UNINSTALL name=" .. short(name)
    if not inst or type(inst.uninstall) ~= "function" then
        self:log(label .. " ok=false")
        return nil, "installer unavailable"
    end
    if not A.app_name_ok(name) then
        self:log(label .. " ok=false")
        return nil, "bad name"
    end
    -- an image package leaves only through an OTA image (DECISIONS.md 1.2(c)),
    -- and that rule is enforced here too: naming a package that also exists
    -- under /apps does not turn a system package into a removable one
    if self:app_is_system(name, inst) then
        self:log("APP_SYS_PROTECT name=" .. short(name))
        self:log(label .. " ok=false")
        return nil, "system app"
    end
    local called, ok, info = pcall(inst.uninstall, inst, name)
    if not called then ok, info = false, tostring(ok) end
    self:log(label .. " ok=" .. tostring(ok == true))
    if ok ~= true then return nil, tostring(info) end
    return true, info
end

-- ---------------------------------------------------------------------------
-- the permission surface: ask once (rule 6), then manage it in Settings
-- ---------------------------------------------------------------------------

-- the question the desktop has to put on screen, or nil when nothing is queued
function A:perm_pending()
    if not self.perms or type(self.perms.next_request) ~= "function" then return nil end
    local ok, item = pcall(self.perms.next_request, self.perms)
    if not ok or type(item) ~= "table" then return nil end
    return item
end

-- The launcher's answer to a queued request (A = allowed, D = denied). The write
-- happens in kernel/permissions.lua; this only records who did it.
function A:sys_perms_answer(record, app, cap, verdict)
    if not self.perms then return nil, "no permission table" end
    local ok, err = self.perms:answer(app, cap, verdict)
    self:log("APP_PERM_ANSWER app=" .. short(app, 24) .. " cap=" .. short(cap, 24)
        .. " by=" .. short(record.name, 24) .. " ok=" .. tostring(ok == true))
    if not ok then return nil, tostring(err) end
    return true
end

-- The Settings toggle. Only a capability the package declares may be written: the
-- manifest stays the ceiling, exactly as it is for a grant.
function A:sys_perms_set(record, app, cap, verdict)
    if not self.perms then return nil, "no permission table" end
    local target = self.index[tostring(app)]
    if target == nil then return nil, "no such app" end
    local caps = target.manifest.capabilities or {}
    local declared = false
    for i = 1, #caps do
        if caps[i] == cap then declared = true break end
    end
    if not declared then return nil, "not declared" end
    local granted = (verdict == true or verdict == "granted" or verdict == "allowed")
    local ok, err = self.perms:set(target.name, cap, granted)
    if not ok then return nil, tostring(err) end
    -- the next start re-reads the file; a running app keeps the set it started with
    target.perms_applied = false
    return true
end

-- Every scanned package with its declared capabilities and their current state
-- ("granted" | "denied" | "ask"), read from /etc/perms, never from a cache.
function A:sys_perms_list(record)
    if not self.perms then return nil, "no permission table" end
    local out = {}
    for i = 1, #self.records do
        local rec = self.records[i]
        local caps = rec.manifest.capabilities or {}
        out[#out + 1] = {
            name = rec.name,
            version = rec.manifest.version,
            dir = rec.dir,
            state = rec.state,
            caps = caps,
            states = self.perms:states(rec.name, caps),
        }
    end
    return true, out
end

-- ---------------------------------------------------------------------------
-- the desktop OTA surface (T5)
-- ---------------------------------------------------------------------------

-- What the source medium offers: the packages in `/pkgs`, on this computer's
-- own storage. A pocket computer has no disk drive, so there is no other
-- medium to consult.
function A:sys_ota_list(record)
    if not record.caps["fs.read"] then return self:denied(record, "fs.read") end
    local fsx = self.fs
    local entries = {}
    local internal = self.opts.ota_internal or A.OTA_INTERNAL
    local called, names = pcall(fsx.list, internal)
    local listing = (called and type(names) == "table") and names or {}
    table.sort(listing)
    for i = 1, #listing do
        local dir = join(internal, listing[i])
        if listing[i]:sub(-4) == ".app" then
            local dcalled, is_dir = pcall(fsx.isDir, dir)
            if dcalled and is_dir then
                local name = listing[i]:sub(1, -5)
                local version = "?"
                local inst = self:installer_of()
                if inst and type(inst.read_manifest) == "function" then
                    local vcalled, manifest = pcall(inst.read_manifest, inst, dir)
                    if vcalled and type(manifest) == "table" then
                        version = tostring(manifest.version or "?")
                    end
                end
                entries[#entries + 1] = {
                    name = name, version = version, kind = "package",
                    source = "internal",
                }
            end
        end
    end
    if #entries == 0 then
        -- the reason stays `no source`; the log records exactly what was checked
        self:log("APP_OTA_LIST ok=false reason=no_source checked=" .. internal)
        return nil, "no source"
    end
    self:log("APP_OTA_LIST ok=true entries=" .. tostring(#entries)
        .. " source=internal")
    return true, { source = "internal", entries = entries }
end

function A:sys_ota_apply(record, name)
    if not record.caps["fs.write"] then return self:denied(record, "fs.write") end
    if name == "image" then
        self:log("APP_OTA_APPLY name=image ok=false reason=recovery_only")
        return nil, "image ota needs recovery"
    end
    -- a package entry is an ordinary install of the source package: same object,
    -- same validation, same error text as api.sys.install
    local ok, info = self:sys_install(record, name)
    self:log("APP_OTA_APPLY name=" .. short(name) .. " ok=" .. tostring(ok == true))
    return ok, info
end

-- T15: re-read the app roots. Running instances are kept as they are (their
-- state, coroutine and capabilities are untouched); a record whose directory has
-- disappeared is dropped only when it is not running.
function A:rescan()
    -- both app roots, always: the image packages and the user packages (a test
    -- runtime may have its own apps_root, so add it when it is a third path)
    local roots = { "/system/system", "/apps" }
    local own = self.apps_root
    if type(own) == "string" and own ~= "/system/system" and own ~= "/apps" then
        roots[#roots + 1] = own
    end
    local before = {}
    for i = 1, #self.records do before[self.records[i].name] = true end
    for i = 1, #roots do
        local root = roots[i]
        local called, exists = pcall(self.fs.exists, root)
        if called and exists then self:scan(root) end
    end
    local added, removed = 0, 0
    for i = 1, #self.records do
        local record = self.records[i]
        if not before[record.name] then added = added + 1 end
    end
    local keep = {}
    for i = 1, #self.records do
        local record = self.records[i]
        local dir = record.dir
        local present = false
        if type(dir) == "string" then
            local called, exists = pcall(self.fs.exists, dir)
            present = (called and exists) == true
        else
            for r = 1, #roots do
                local called, exists = pcall(self.fs.exists,
                    roots[r] .. "/" .. tostring(record.name) .. ".app")
                if called and exists then present = true break end
            end
        end
        if present or record.state == "running" then
            keep[#keep + 1] = record
        else
            removed = removed + 1
            self.index[record.name] = nil
            self:log("APP_RESCAN_DROP name=" .. tostring(record.name))
        end
    end
    self.records = keep
    self:log("APP_RESCAN count=" .. tostring(#self.records)
        .. " added=" .. tostring(added) .. " removed=" .. tostring(removed))
    return true, { count = #self.records, added = added, removed = removed }
end

function A:sys_rescan(record)
    if not record.caps["fs.read"] then return self:denied(record, "fs.read") end
    return self:rescan()
end

-- launch: a name the table does not know yet triggers one rescan (a package may
-- have been installed a moment ago), then the normal start path runs
function A:sys_launch(record, name)
    if type(name) ~= "string" or name == "" then return nil, "bad name" end
    if self.index[name] == nil then
        self:log("APP_LAUNCH_RESCAN name=" .. short(name) .. " reason=unknown")
        self:rescan()
    end
    if self.index[name] == nil then
        self:log("APP_LAUNCH_MISS name=" .. short(name))
        return nil, "no such app"
    end
    local ok, err = self:start(name)
    if not ok then return nil, tostring(err) end
    return true, { name = name }
end

function A:sys_list(record)
    if not record.caps["fs.read"] then return self:denied(record, "fs.read") end
    local inst = self:installer_of()
    if not inst or type(inst.list) ~= "function" then
        self:log("APP_LIST n=0")
        return nil, "installer unavailable"
    end
    local called, entries = pcall(inst.list, inst)
    if not called then
        self:log("APP_LIST n=0")
        return nil, tostring(entries)
    end
    if type(entries) ~= "table" then
        self:log("APP_LIST n=0")
        return nil, "list failed"
    end
    self:log("APP_LIST n=" .. tostring(#entries))
    return entries
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
        denied_caps = {},
        error = nil,
        hook_errors = {},
        -- what the entry body returned when its coroutine finished (D1: the
        -- desktop loop reads `"quit"` out of it to leave the desktop)
        result = nil,
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
    -- per-capability tally: the aggregate counter cannot tell a missing keyboard
    -- from a refused file write, and `status()` needs to (O3)
    record.denied_caps[cap] = (record.denied_caps[cap] or 0) + 1
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
        -- "is this path a directory": read-only, so it rides on fs.read. pkgget
        -- needs it to tell a mounted /disk (a drive) from a file (T22).
        isDir = gate(self, record, "fs.read",
            fsx and type(fsx.isDir) == "function" and function(path)
                return fsx.isDir(path)
            end or nil),
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
    -- O3: the two UI capabilities. Both shapes already exist in this api and are
    -- reused on purpose: `pullEvent` is a gated function like api.fs.read, while
    -- `keys` and the whole terminal are gated tables like api.peripheral, so a
    -- denied app still gets a table it can index instead of a nil-index.
    local input = self.hosts.input
    if type(input) == "function" then input = { pullEvent = input } end
    api.input = {
        pullEvent = gate(self, record, "input", input and input.pullEvent),
        keys = tree(self, record, "input", input and input.keys),
    }
    api.terminal = tree(self, record, "terminal", self.hosts.terminal)
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
    if not record then
        -- D1-fix: a refusal is never silent -- the desktop shows the launcher's
        -- message and /kernel.log has the one line that says why
        self:log("APP_START_DENIED name=" .. short(name, 40) .. " reason=no_such_app")
        return nil, "no such app: " .. tostring(name)
    end
    if record.state == "killed" then
        self:log("APP_START_DENIED name=" .. record.name .. " reason=killed")
        return nil, "app is killed: " .. name
    end
    if record.state == "running" or record.state == "paused" then
        -- this is also the launcher-launched-itself path: the desktop is already
        -- running, so starting it again is refused and recorded, not ignored
        self:log("APP_START_DENIED name=" .. record.name .. " reason=already_running"
            .. " state=" .. tostring(record.state))
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
    local allowed, deny_reason = self:apply_permissions(record)
    if allowed == nil then
        self:log("APP_START_DENIED name=" .. record.name
            .. " reason=" .. short(deny_reason, 40))
        return nil, deny_reason
    end
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
    record.result = nil
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
    local ok, ret = coroutine.resume(record.co)
    if not ok then
        record.state = "crashed"
        record.error = tostring(ret)
        record.co = nil
        self:log("APP_CRASH app=" .. record.name .. " err=" .. short(ret))
        return false
    end
    if coroutine.status(record.co) == "dead" then
        -- the body's return value is the app's exit word: the desktop loop
        -- reads "quit" out of it, everything else is reported verbatim
        record.result = ret
        record.state = "stopped"
        record.co = nil
        self:log("APP_EXIT app=" .. record.name .. " tick=" .. tostring(self.ticks)
            .. " result=" .. short(ret, 24))
        self:call_hook(record, "on_stop")
    end
    return true
end

-- `skip` is an optional name -> true map: the desktop event loop uses it to keep
-- an app it parked (a launched app that cannot own the console) out of the
-- scheduler, so a background app can never paint over the foreground screen
-- (D1-fix: the installer's own `s <pkg>` frame used to land on every tick the
-- launcher did not repaint on).
function A:tick(skip)
    self.ticks = self.ticks + 1
    local advanced = 0
    for i = 1, #self.records do
        local record = self.records[i]
        if record.state == "running" and record.co and not (skip and skip[record.name]) then
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
            denied_caps = copy_map(record.denied_caps),
            capabilities = copy_list(record.manifest.capabilities),
            grants = copy_map(record.perms),
            result = record.result,
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
