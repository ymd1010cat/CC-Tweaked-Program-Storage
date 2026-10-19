-- dcnet.lua - dcnet under unixshell (package bin, resolved through the PATH).
--
--   dcnet master [opts]           master console (TUI)
--   dcnet master --headless       master as a log-only daemon
--   dcnet worker [ID] [NAME]      worker console
--   dcnet worker --headless       worker as a log-only daemon
--   dcnet status | jobs | net | config | version | help
--
-- The command is run by ush as (args, stage); this file also accepts the plain
-- vararg form so it can be started by a CraftOS shell for a quick check.
-- All paths and the module loader are resolved from this file, so the package
-- works from any mount point (<store>/usr/pkgs/dcnet).

local first, second = ...
local argv = {}
if type(first) == "table" then
    argv = first
    stage = second
else
    local n = select("#", ...)
    for i = 1, n do argv[#argv + 1] = tostring((select(i, ...))) end
end

local function self_dir()
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source or ""
    src = tostring(src):gsub("^@", "")
    if src == "" then
        local prog = (shell and shell.getRunningProgram and shell.getRunningProgram())
            or (arg and arg[0]) or ""
        src = tostring(prog)
    end
    return src:match("^(.*)/bin/[^/]+$") or "/usr/pkgs/dcnet"
end

local PKG = self_dir()
_G.DCNET_PKG = PKG

local function say(text)
    local s = tostring(text)
    if stage and type(stage.write) == "function" then
        stage.write(s .. "\n")
    else
        print(s)
    end
end

local function read_conf(path)
    local out = {}
    if type(fs) ~= "table" or not fs.exists(path) then return out end
    local f = fs.open(path, "r")
    if not f then return out end
    local ok, text = pcall(f.readAll)
    f.close()
    if not ok or type(text) ~= "string" then return out end
    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local k, v = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
        if k and v ~= "" then
            v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
            out[k] = v
        end
    end
    return out
end

-- --config= wins; then /etc/dcnet.conf; then the built-in defaults.
local conf_path = "/etc/dcnet.conf"
for _, a in ipairs(argv) do
    local v = tostring(a):match("^%-%-config=(.+)$")
    if v then conf_path = v end
end
local conf = read_conf(conf_path)

local function current_user()
    local user, home = "root", "/"
    local ok, vars = pcall(require, "vars")
    if ok and type(vars) == "table" and type(vars.get) == "function" then
        user = vars.get("USER") or user
        home = vars.get("HOME") or home
    end
    local ok2, perm = pcall(require, "perm")
    if ok2 and type(perm) == "table" and type(perm.get_current_user) == "function" then
        user = perm.get_current_user() or user
    end
    if (home == nil or home == "" or home == "/") and user ~= "root" then
        home = "/home/" .. tostring(user)
    end
    return user, home
end

local user, home = current_user()

local root = conf.root or rawget(_G, "DCNET_ROOT")
local transport = conf.transport
local key = conf.key
local worker_file = conf.worker_file
local rest = {}
local keep_cmd_line = (tostring(argv[1]) == "cmd")
for _, a in ipairs(argv) do
    local s = tostring(a)
    local k, v = s:match("^%-%-([%w_%-]+)=(.*)$")
    if keep_cmd_line then
        rest[#rest + 1] = s
    elseif k == "root" then
        root = v
    elseif k == "transport" then
        transport = v
    elseif k == "key" then
        key = v
    elseif k == "worker_file" then
        worker_file = v
    elseif k == "config" then
        -- already consumed
    else
        rest[#rest + 1] = s
    end
end
argv = rest

if root == nil or root == "" then
    if user == "root" then
        root = "/var/lib/dcnet"
    else
        root = home .. "/.dcnet"
    end
end
if transport == nil or transport == "" then transport = "rednet" end
if worker_file == nil or worker_file == "" then worker_file = root .. "/worker.lua" end

_G.DCNET_ROOT = root
_G.DCNET_TRANSPORT = transport
_G.DCNET_KEY = key
_G.DCNET_WORKER_FILE = worker_file

local function ensure_dir(path)
    if type(fs) ~= "table" then return false end
    if fs.exists(path) then return true end
    local acc = ""
    for seg in tostring(path):gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then
            local ok = pcall(fs.makeDir, acc)
            if not ok then return false end
        end
    end
    return fs.exists(path)
end

local modules = {}
local function load_module(name)
    if modules[name] ~= nil then return modules[name] end
    local short = tostring(name):match("^dc%.(.+)$")
    if not short then error("dcnet: bad module name " .. tostring(name), 0) end
    local path = PKG .. "/lib/dcnet/" .. short .. ".lua"
    local fn, err = loadfile(path)
    if not fn then error("dcnet: cannot load " .. path .. ": " .. tostring(err), 0) end
    local env = setmetatable({}, { __index = _G })
    env.dc_require = load_module
    if type(require) == "function" then env.require = require end
    if setfenv then pcall(setfenv, fn, env) end
    local mod = fn()
    if mod == nil then mod = true end
    modules[name] = mod
    return mod
end
_G.dc_require = load_module

local cmd = argv[1] or "help"

local function usage()
    return {
        "usage: dcnet COMMAND [options]",
        "  master [--headless] [--standby] [-v] [--KEY=VALUE ...]",
        "  worker [ID] [NAME] [--headless] [--KEY=VALUE ...]",
        "  status            state root, jobs and recent history",
        "  cmd <line>        queue a command for the running master",
        "  log [N]           last N lines of the master log",
        "  jobs              list the jobs directory",
        "  net               transport and modems",
        "  config            resolved paths and settings",
        "  version           dcnet version",
        "  help              this message",
        "",
        "config: " .. conf_path .. " (root=/var/lib/dcnet for root, ~/.dcnet otherwise)",
    }
end

if cmd == "help" or cmd == "-h" or cmd == "--help" then
    for _, line in ipairs(usage()) do say(line) end
    return 0
end

local writable = ensure_dir(root)
if writable then
    for _, sub in ipairs({ "jobs", "out", "state", "logs", "cache", "ctl" }) do
        ensure_dir(root .. "/" .. sub)
    end
    -- The packaged worker is the seed for "push"; the master sends this file and
    -- a node saves a pushed upgrade to the same writable path.
    if type(fs) == "table" and not fs.exists(worker_file) and fs.exists(PKG .. "/share/worker.lua") then
        local src = fs.open(PKG .. "/share/worker.lua", "r")
        if src then
            local data = src.readAll()
            src.close()
            local dst = fs.open(worker_file, "w")
            if dst then
                dst.write(data)
                dst.close()
            end
        end
    end
end

local util = load_module("dc.util")

local function defaults()
    local out = {}
    local dir = PKG .. "/jobs"
    if type(fs) ~= "table" or not fs.exists(dir) then return out end
    for _, name in ipairs(fs.list(dir) or {}) do
        if tostring(name):match("%.lua$") then
            local f = fs.open(dir .. "/" .. name, "r")
            if f then
                local ok, text = pcall(f.readAll)
                f.close()
                if ok and text then out[name] = text end
            end
        end
    end
    return out
end

local function cfg_from_conf(known)
    local out = {}
    for k, v in pairs(conf) do
        local dv = known and known[k]
        if dv ~= nil then
            if type(dv) == "number" then
                out[k] = tonumber(v) or dv
            elseif type(dv) == "boolean" then
                out[k] = (v == "true" or v == "1" or v == "on" or v == "yes")
            else
                out[k] = v
            end
        end
    end
    return out
end

if cmd == "version" then
    say("dcnet " .. tostring(util.VERSION))
    return 0
elseif cmd == "config" then
    say("config: " .. conf_path)
    say("root: " .. tostring(root) .. (writable and "" or "  (not writable)"))
    say("transport: " .. tostring(transport))
    say("worker_file: " .. tostring(worker_file))
    say("key: " .. (key and #key >= 8 and "set" or "off"))
    say("jobs: " .. tostring(util.JOB_DIR))
    say("control: " .. tostring(rawget(_G, "DCNET_CTL") or (root .. "/ctl")))
    return 0
elseif cmd == "jobs" then
    say("jobs: " .. tostring(util.JOB_DIR))
    local names = util.listDir(util.JOB_DIR)
    table.sort(names)
    if #names == 0 then
        say("  (none)")
    else
        for _, name in ipairs(names) do
            say("  " .. tostring(name))
        end
    end
    return 0
elseif cmd == "net" then
    local net = load_module("dc.net")
    say("transport: " .. tostring(net.transport or transport))
    local modems = net.findModems()
    if #modems == 0 then
        say("modems: none")
    else
        say("modems: " .. tostring(net.describe(modems)))
        for _, md in ipairs(modems) do
            say("  " .. tostring(md.name) .. (md.wireless and " (wireless)" or " (wired)"))
        end
    end
    return 0
elseif cmd == "status" then
    say("dcnet " .. tostring(util.VERSION))
    say("root: " .. tostring(root) .. (writable and "" or "  (not writable)"))
    say("transport: " .. tostring(transport))
    local names = util.listDir(util.JOB_DIR)
    table.sort(names)
    say("jobs: " .. tostring(#names))
    local ctl = util.listDir(rawget(_G, "DCNET_CTL") or (root .. "/ctl"))
    say("queued commands: " .. tostring(#ctl))
    local ok, state = pcall(load_module, "dc.state")
    if ok and type(state) == "table" and type(state.history) == "function" then
        local list, total = state.history(5)
        say("history: " .. tostring(#list) .. " shown / " .. tostring(total or #list) .. " total")
        for _, e in ipairs(list) do
            say(string.format("  #%-3d %-12s %-4s %s",
                e.id or 0, tostring(e.name or "?"),
                tostring(e.state or "?"), tostring(e.summary or "")))
        end
    end
    return 0
elseif cmd == "cmd" then
    local parts = {}
    for i = 2, #argv do parts[#parts + 1] = tostring(argv[i]) end
    local line = table.concat(parts, " ")
    if line == "" then
        say("usage: dcnet cmd <line>")
        return 2
    end
    local dir = rawget(_G, "DCNET_CTL") or (root .. "/ctl")
    if not ensure_dir(dir) then
        say("dcnet: cannot create " .. tostring(dir))
        return 1
    end
    local stamp = (os.epoch and os.epoch("utc")) or (os.time() * 1000)
    local name = tostring(math.floor(stamp)) .. "-" ..
        string.format("%06d-%06d.cmd", os.getComputerID() or 0, math.random(1, 999999))
    local f = fs.open(dir .. "/" .. name, "w")
    if not f then
        say("dcnet: cannot write " .. tostring(dir))
        return 1
    end
    f.write(line .. "\n")
    f.close()
    say("queued: " .. line)
    return 0
elseif cmd == "log" then
    local n = tonumber(argv[2]) or 20
    local path = root .. "/logs/master.log"
    if not fs.exists(path) then
        say("dcnet: no master log at " .. path)
        return 1
    end
    local f = fs.open(path, "r")
    if not f then
        say("dcnet: cannot read " .. path)
        return 1
    end
    local lines = {}
    while true do
        local line = f.readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    f.close()
    local from = math.max(1, #lines - n + 1)
    for i = from, #lines do say(lines[i]) end
    return 0
elseif cmd == "master" then
    if not writable then
        say("dcnet: root is not writable: " .. tostring(root) .. " (run as root or set root= in " .. conf_path .. ")")
        return 1
    end
    local flags, cfg = {}, {}
    for i = 2, #argv do
        local s = tostring(argv[i])
        if s == "--headless" or s == "headless" then
            flags.headless = true
        elseif s == "-v" or s == "--verbose" then
            flags.verbose = true
        elseif s == "standby" or s == "--standby" then
            flags.standby = true
        elseif s == "active" or s == "--active" then
            flags.standby = false
        else
            local k, v = s:match("^%-%-([%w_]+)=(.*)$")
            if k then cfg[k] = v end
        end
    end
    local sched = load_module("dc.sched")
    for k, v in pairs(cfg_from_conf(sched.DEFAULTS)) do cfg[k] = v end
    if flags.verbose then cfg.verbose = true end
    if flags.standby ~= nil then cfg.standby = flags.standby end
    for k, v in pairs(cfg) do
        local dv = sched.DEFAULTS[k]
        if dv ~= nil then
            if type(dv) == "number" then cfg[k] = tonumber(v) or dv
            elseif type(dv) == "boolean" then cfg[k] = (v == true or v == "true" or v == "1") end
        end
    end
    local master = load_module("dc.master")
    local ok = master.run({
        defaultJobs = defaults(),
        cfg = cfg,
        headless = flags.headless == true,
    })
    return ok and 0 or 1
elseif cmd == "worker" then
    if not writable then
        say("dcnet: root is not writable: " .. tostring(root) .. " (run as root or set root= in " .. conf_path .. ")")
        return 1
    end
    local worker = load_module("dc.worker")
    local opts = cfg_from_conf(worker.DEFAULTS)
    for i = 2, #argv do
        local s = tostring(argv[i])
        if s == "--headless" or s == "--daemon" or s == "headless" then
            opts.headless = true
        elseif tonumber(s) and not opts.master then
            opts.master = tonumber(s)
        elseif s:sub(1, 1) ~= "-" and not opts.name then
            opts.name = s
        else
            local k, v = s:match("^%-%-([%w_]+)=(.*)$")
            if k then
                local dv = worker.DEFAULTS[k]
                if type(dv) == "number" then opts[k] = tonumber(v) or dv
                elseif type(dv) == "boolean" then opts[k] = (v == "true" or v == "1")
                else opts[k] = v end
            end
        end
    end
    local ok = worker.run(opts)
    return ok and 0 or 1
end

for _, line in ipairs(usage()) do say(line) end
say("dcnet: unknown command: " .. tostring(cmd))
return 1
