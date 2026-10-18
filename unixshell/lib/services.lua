-- services.lua - /etc/rc.d startup scripts and the service(8) command
--
-- A service is one file in /etc/rc.d. The file name carries the start order:
--
--     ^(%d+)[-_]([%w_%-]+)%.(sh|lua)$
--
-- so "20-clock.sh" is started after "10-net.sh" and before "30-print.lua".
-- Files that do not match the pattern are listed but never executed.
--
-- A unit is a Lua chunk, not a shell script, because ush is written in Lua and
-- only a Lua chunk can be loaded inside the running VM without forking a second
-- shell. The chunk is compiled with its own environment and may define:
--
--     function start()   required, called to bring the service up
--     function stop()    optional, called to take it down
--     function status()  optional, returns a short state string
--     name, description, order   optional metadata (order defaults to the
--                                number in the file name)
--
-- The environment is a whitelist: print, sleep, string, table, math, the date
-- and time functions of os, the read only side of fs, plus the control API
-- service.start(name) / service.stop(name) / service.restart(name), which call
-- back into this module. Filesystem writes, shell commands and the terminal
-- primitives are out of reach, so a unit cannot damage the system or deadlock
-- the line editor.
--
-- Boot integration: startup.lua calls services.boot() once per boot, before the
-- first session. Every unit is started in order inside a pcall, and a unit that
-- fails is logged and skipped, so one broken service never stops the boot. The
-- units started in this boot are remembered in /etc/rc.d/run/<name>.started,
-- which keeps the watchdog from starting them twice when the shell is
-- relaunched. "service stop" clears the marker of the unit.
--
-- /var/log/service.log records "[time] unit=... action=... result=... boot=..."
-- and is rotated through lib/logrotate.lua (2000 lines, 2 generations).
local services = {}

local RCD = "/etc/rc.d"
local LOG = "/var/log/service.log"
local RUN_DIR = RCD .. "/run"
local MAX_UNITS = 64

services.rc_dir = RCD
services.log_file = LOG
services.run_dir = RUN_DIR
services.default_order = 50

local function ensure_dir(path)
    if fs.exists(path) then return true end
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
    return fs.exists(path)
end

local function timestamp()
    local ok, t = pcall(require, "time")
    if ok and t and t.format then return t.format("%Y-%m-%d %H:%M:%S") end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function boot_id()
    local ok, b = pcall(require, "boot")
    if ok and b and b.epoch then return b.epoch() end
    return math.floor(os.time())
end

local function started_same_boot(name)
    local ok, b = pcall(require, "boot")
    local path = RUN_DIR .. "/" .. name .. ".started"
    if not fs.exists(path) then return false end
    local f = fs.open(path, "r")
    if not f then return false end
    local line = f.readLine()
    f.close()
    local saved = tonumber(line)
    if not saved then return false end
    if ok and b and b.epoch then
        return math.abs(saved - b.epoch()) <= 60
    end
    return true
end

-- ------------------------------------------------------------------
-- Unit discovery
-- ------------------------------------------------------------------

function services.parse_name(file_name)
    if type(file_name) ~= "string" then return nil end
    local order, name = file_name:match("^(%d+)[-_]([%w_%-]+)%.sh$")
    if not order then
        order, name = file_name:match("^(%d+)[-_]([%w_%-]+)%.lua$")
    end
    if not order then return nil end
    return { order = tonumber(order), name = name, file = file_name }
end

-- Units in start order; entries that do not match the naming rule are reported
-- in the second return value.
function services.list()
    local units, bad = {}, {}
    if not fs.exists(RCD) then return units, bad end
    for _, entry in ipairs(fs.list(RCD)) do
        if entry ~= "run" and fs.isDir(RCD .. "/" .. entry) then
            bad[#bad + 1] = { file = entry, reason = "directory" }
        else
            local parsed = services.parse_name(entry)
            if parsed then
                parsed.path = RCD .. "/" .. entry
                units[#units + 1] = parsed
            elseif not fs.isDir(RCD .. "/" .. entry) then
                bad[#bad + 1] = { file = entry, reason = "expected NNN-name.sh" }
            end
        end
    end
    table.sort(units, function(a, b)
        if a.order == b.order then return a.name < b.name end
        return a.order < b.order
    end)
    if #units > MAX_UNITS then
        local trimmed = {}
        for i = 1, MAX_UNITS do trimmed[i] = units[i] end
        units = trimmed
    end
    return units, bad
end

function services.exists(name)
    return services.path_of(name) ~= nil
end

-- Resolve "name", "NNN-name" or "NNN-name.sh" to a path in /etc/rc.d.
function services.path_of(name)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("/", 1, true) then
        if fs.exists(name) and not fs.isDir(name) then return name end
        return nil
    end
    if fs.exists(RCD .. "/" .. name) and not fs.isDir(RCD .. "/" .. name) then
        return RCD .. "/" .. name
    end
    for _, unit in ipairs(services.list()) do
        if unit.name == name or (unit.order .. "-" .. unit.name) == name then
            return unit.path
        end
    end
    return nil
end

function services.units()
    local out = {}
    for _, unit in ipairs(services.list()) do
        out[unit.name] = unit
    end
    return out
end

-- ------------------------------------------------------------------
-- Loading a unit in a sandbox
-- ------------------------------------------------------------------

local service_api = {}

local function make_env()
    local env = setmetatable({}, { __index = services.sandbox })
    env.service = service_api
    return env
end

-- Units may read the file system but never write to it: a start up script that
-- rewrites /etc before the shell is even up could only be repaired by hand.
local function open_read_only(path, mode)
    mode = mode or "r"
    if mode ~= "r" and mode ~= "rb" then
        error("fs.open: /etc/rc.d units may open files read only", 2)
    end
    return fs.open(path, mode)
end

services.sandbox = {
    print = print, tostring = tostring, tonumber = tonumber, type = type,
    ipairs = ipairs, pairs = pairs, select = select, pcall = pcall,
    error = error, table = table, string = string, math = math,
    sleep = sleep, write = write, os = {
        date = os.date, time = os.time, clock = os.clock, epoch = os.epoch,
        day = os.day,
    },
    fs = {
        exists = fs.exists, list = fs.list, isDir = fs.isDir,
        isReadOnly = fs.isReadOnly, getSize = fs.getSize,
        getFreeSpace = fs.getFreeSpace, getCapacity = fs.getCapacity,
        open = open_read_only, combine = fs.combine, getName = fs.getName,
        getDir = fs.getDir,
    },
}

-- Load a unit file and return its environment, or nil plus the reason. The
-- environment is what the chunk ran in, so the functions it defined as globals
-- (start, stop, status, name, description, order) are its fields.
function services.load(path)
    if not fs.exists(path) then return nil, "no such file: " .. tostring(path) end
    local f = fs.open(path, "r")
    if not f then return nil, "cannot read " .. tostring(path) end
    local text = f.readAll()
    f.close()

    local env = make_env()
    local chunk, err = load(text or "", "@" .. path, "t", env)
    if not chunk then return nil, "syntax error: " .. tostring(err) end
    local ok, call_err = pcall(chunk)
    if not ok then return nil, "error at load time: " .. tostring(call_err) end
    return env
end

local function unit_of(path)
    local env, err = services.load(path)
    if not env then return nil, err end
    if type(env.start) ~= "function" then
        return nil, "no start() function"
    end
    return env
end

-- ------------------------------------------------------------------
-- Logging
-- ------------------------------------------------------------------

function services.log(action, name, result, note)
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.check then
        pcall(lr.check, LOG, { max_lines = 2000, keep = 2 })
    end
    ensure_dir("/var/log")
    local f = fs.open(LOG, "a")
    if not f then return false end
    local parts = {
        "[" .. timestamp() .. "]",
        "unit=" .. tostring(name),
        "action=" .. tostring(action),
        "result=" .. tostring(result),
        "boot=" .. tostring(boot_id()),
    }
    if note then parts[#parts + 1] = 'note="' .. tostring(note) .. '"' end
    f.write(table.concat(parts, " ") .. "\n")
    f.close()
    return true
end

function services.logs(n, filter)
    n = n or 20
    local out = {}
    if not fs.exists(LOG) then return out end
    local f = fs.open(LOG, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        if not filter or line:find(filter, 1, true) then
            out[#out + 1] = line
            if #out > n then table.remove(out, 1) end
        end
    end
    f.close()
    return out
end

-- ------------------------------------------------------------------
-- Start / stop / restart / status
-- ------------------------------------------------------------------

local function mark_started(name)
    ensure_dir(RUN_DIR)
    local f = fs.open(RUN_DIR .. "/" .. name .. ".started", "w")
    if not f then return false end
    f.write(tostring(boot_id()) .. "\n")
    f.close()
    return true
end

local function clear_started(name)
    local path = RUN_DIR .. "/" .. name .. ".started"
    if fs.exists(path) then return fs.delete(path) end
    return true
end

local function run_unit(unit, action, name)
    if action == "status" then
        if type(unit.status) == "function" then
            local ok, res = pcall(unit.status)
            if not ok then return false, "status() failed: " .. tostring(res) end
            if res == nil then return true, "unknown" end
            if type(res) == "boolean" then return true, res and "running" or "stopped" end
            return true, tostring(res)
        end
        return true, "unknown"
    end
    local fn = unit[action]
    if type(fn) ~= "function" then
        return false, name .. ": no " .. action .. "() function"
    end
    local ok, err = pcall(fn)
    if not ok then return false, tostring(err) end
    return true, nil
end

-- Bring a unit up. Skips a unit that is already up in this boot unless opts.force
-- is set, so the watchdog can call it on every relaunch.
function services.start(name, opts)
    opts = opts or {}
    local path = services.path_of(name)
    if not path then return false, name .. ": no such service" end
    local unit, err = unit_of(path)
    if not unit then
        services.log("start", name, "error", err)
        return false, name .. ": " .. tostring(err)
    end
    local unit_name = unit.name or name:match("([%w_%-]+)$") or name
    if started_same_boot(unit_name) and not opts.force then
        return false, unit_name .. ": already started in this boot"
    end
    local ok, why = run_unit(unit, "start", unit_name)
    if not ok then
        services.log("start", unit_name, "error", tostring(why))
        clear_started(unit_name)
        return false, unit_name .. ": " .. tostring(why)
    end
    mark_started(unit_name)
    services.log("start", unit_name, "ok", opts.boot and "boot" or "manual")
    return true, unit_name
end

-- Take a unit down. The "started in this boot" marker is cleared even when the
-- stop function reports a failure, so the unit can be brought up again.
function services.stop(name, opts)
    opts = opts or {}
    local path = services.path_of(name)
    if not path then return false, name .. ": no such service" end
    local unit, err = unit_of(path)
    if not unit then
        services.log("stop", name, "error", err)
        return false, name .. ": " .. tostring(err)
    end
    local unit_name = unit.name or name:match("([%w_%-]+)$") or name
    local was_up = started_same_boot(unit_name)
    if type(unit.stop) ~= "function" then
        clear_started(unit_name)
        if not was_up then
            return false, unit_name .. ": not running (and no stop() function)"
        end
        services.log("stop", unit_name, "ok", "no stop() function")
        return true, unit_name
    end
    local ok, why = run_unit(unit, "stop", unit_name)
    clear_started(unit_name)
    if not ok then
        services.log("stop", unit_name, "error", tostring(why))
        return false, unit_name .. ": " .. tostring(why)
    end
    services.log("stop", unit_name, "ok", opts.boot and "shutdown" or "manual")
    return true, unit_name
end

function services.restart(name, opts)
    local ok = services.stop(name, opts)
    local started, detail = services.start(name, { force = true })
    if not started then return false, detail end
    return true, detail, ok
end

function services.state(name)
    local path = services.path_of(name)
    if not path then return nil end
    local unit, err = unit_of(path)
    local state = "unknown"
    if not unit then
        state = "broken"
    else
        local ok, res = run_unit(unit, "status", name)
        if ok then state = res or "unknown" end
    end
    return {
        name = name, path = path,
        up = started_same_boot(name), state = state,
        loaded = unit ~= nil, error = err,
    }
end

-- Rows for the "service" listing. The second return value carries the entries
-- of /etc/rc.d that were skipped because they do not follow the NNN-name.sh
-- naming rule (same shape as services.list()).
function services.status()
    local rows = {}
    local units, bad = services.list()
    for _, unit in ipairs(units) do
        local loaded, err = unit_of(unit.path)
        local state = "unknown"
        if not loaded then
            state = "broken"
        else
            local ok, res = run_unit(loaded, "status", unit.name)
            if ok then state = res or "unknown" end
        end
        rows[#rows + 1] = {
            name = unit.name, order = unit.order, path = unit.path,
            up = started_same_boot(unit.name), state = state,
            loaded = loaded ~= nil, error = err,
        }
    end
    return rows, bad or {}
end

-- Start everything that is not up yet, in order. No failure stops the boot.
function services.boot(opts)
    opts = opts or {}
    local result = { started = {}, failed = {}, skipped = {}, missing = false }
    if not fs.exists(RCD) then
        result.missing = true
        ensure_dir(RCD)
        return result
    end
    for _, unit in ipairs(services.list()) do
        if started_same_boot(unit.name) then
            result.skipped[#result.skipped + 1] = unit.name
        else
            local ok, detail = services.start(unit.name, { boot = true })
            if ok then
                result.started[#result.started + 1] = unit.name
            elseif type(detail) == "string" and detail:find("already started", 1, true) then
                result.skipped[#result.skipped + 1] = unit.name
            else
                result.failed[#result.failed + 1] =
                    { name = unit.name, reason = tostring(detail) }
            end
        end
    end
    return result
end

-- Shut the units down in reverse order; used by "service shutdown".
function services.shutdown()
    local done, failed = {}, {}
    local units = services.list()
    for i = #units, 1, -1 do
        local unit = units[i]
        local ok, detail = services.stop(unit.name, { boot = true })
        if ok then
            done[#done + 1] = unit.name
        elseif type(detail) == "string" and detail:find("not running", 1, true) then
            -- nothing to do, the unit was not up
        else
            failed[#failed + 1] = { name = unit.name, reason = tostring(detail) }
        end
    end
    return done, failed
end

-- Control API handed to unit scripts.
service_api.start = function(name) return services.start(name, { force = true }) end
service_api.stop = function(name) return services.stop(name) end
service_api.restart = function(name) return services.restart(name) end
service_api.status = function(name) return services.state(name) end
service_api.list = function() return services.status() end

-- ------------------------------------------------------------------
-- service(8) command
-- ------------------------------------------------------------------

local USAGE = {
    "usage: service                       list units in /etc/rc.d",
    "       service NAME start|stop|restart|status",
    "       service start|stop|restart|status NAME",
    "       service boot                  start every unit that is not up",
    "       service shutdown              stop every unit, reverse order",
    "       service log [N] [FILTER]      show the last N log lines",
}

local ACTIONS = {
    start = true, stop = true, restart = true, status = true,
    boot = true, shutdown = true, list = true, log = true, help = true,
}

function services.main(args, stage)
    stage = stage or { write = function(s) print(s) end }
    local function emit(text) stage.write(text .. "\n") end
    args = args or {}

    local action, name, extra = nil, nil, false
    for _, a in ipairs(args) do
        if a == "-h" or a == "--help" then
            action = "help"
        elseif a:sub(1, 1) == "-" then
            emit("service: " .. a .. ": unknown option")
            return 1
        elseif ACTIONS[a] and not action then
            action = a
        elseif not name then
            name = a
        else
            extra = true
        end
    end
    if extra then
        emit("service: too many arguments")
        return 1
    end

    if action == "help" then
        for _, line in ipairs(USAGE) do emit(line) end
        return 0
    end

    if action == nil or action == "list" then
        local rows, bad = services.status()
        if #rows == 0 then
            emit("service: no units in " .. RCD)
        else
            emit(string.format("%-12s %-6s %-9s %s", "SERVICE", "ORDER", "BOOT", "STATE"))
            for _, r in ipairs(rows) do
                emit(string.format("%-12s %-6d %-9s %s",
                    r.name, r.order, r.up and "started" or "-", r.state))
            end
        end
        for _, b in ipairs(bad) do
            emit("service: " .. RCD .. "/" .. b.file .. ": skipped (" .. b.reason .. ")")
        end
        return 0
    end

    if action == "log" then
        local n, filter = 20, nil
        if name then
            if tonumber(name) then n = tonumber(name) else filter = name end
        end
        local lines = services.logs(n, filter)
        if #lines == 0 then
            emit("service: no log entries")
            return 0
        end
        for _, line in ipairs(lines) do emit(line) end
        return 0
    end

    if action == "boot" then
        local res = services.boot()
        for _, n in ipairs(res.started) do emit("service: " .. n .. " started") end
        for _, n in ipairs(res.skipped) do emit("service: " .. n .. " already up") end
        for _, item in ipairs(res.failed) do
            emit("service: " .. item.name .. " failed: " .. item.reason)
        end
        if #res.started == 0 and #res.failed == 0 and #res.skipped == 0 then
            emit("service: no units to start")
        end
        return #res.failed > 0 and 1 or 0
    end

    if action == "shutdown" then
        local done, failed = services.shutdown()
        for _, n in ipairs(done) do emit("service: " .. n .. " stopped") end
        for _, item in ipairs(failed) do
            emit("service: " .. item.name .. " failed: " .. item.reason)
        end
        if #done == 0 and #failed == 0 then emit("service: nothing was up") end
        return #failed > 0 and 1 or 0
    end

    if action == "status" and not name then
        return services.main({ "list" }, stage)
    end

    if not name then
        emit("service: " .. tostring(action) .. ": needs a service name")
        return 1
    end

    if action == "status" then
        local row = services.state(name)
        if not row then
            emit("service: " .. name .. ": no such service")
            return 3
        end
        emit(string.format("%-12s %-9s %s", row.name, row.up and "started" or "-", row.state))
        if row.error then emit("service: " .. tostring(row.error)) end
        return 0
    end

    local ok, detail
    if action == "start" then
        ok, detail = services.start(name)
    elseif action == "stop" then
        ok, detail = services.stop(name)
    else
        ok, detail = services.restart(name)
    end
    if ok then
        emit("service: " .. tostring(detail) .. " " ..
             (action == "stop" and "stopped" or (action == "restart" and "restarted" or "started")))
        return 0
    end
    emit("service: " .. tostring(detail))
    if tostring(detail):find("no such service", 1, true) then return 3 end
    if tostring(detail):find("already started", 1, true) then return 0 end
    return 1
end

return services
