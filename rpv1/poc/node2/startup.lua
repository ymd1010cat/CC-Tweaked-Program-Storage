--[[- RPV1 bootstrap (Rednet Protocol Version 1).
--
-- Naming: the project is called RPV1 (Rednet Protocol Version 1). The code keeps
-- the historical `rpv` prefix for file/directory names, config keys and the
-- rednet protocol string; only the display name and version label are RPV1.
--
-- Loads the rpv library, sets up the node from role.txt, optionally installs the
-- rednet shim and runs an app as a coroutine task. Also provides the M4
-- operational bits:
--
--   * routes.txt is loaded at boot and hot-reloaded when it changes
--   * a boot watchdog: an uncaught error is written to crash.log and the computer
--     reboots itself (crash_after=<sec> + crash-once are debug hooks used by the
--     watchdog harness)
--
-- Copy layout expected inside the computer:
--     startup.lua  role.txt  [routes.txt]  rpv/*.lua  apps/*.lua  [compat/*.lua]
--
-- Apps come in two shapes: round 1 scripts are `return function(M, node, args)`
-- and round 2 app modules are tables with a `new` constructor (apps/router.lua).
-- The app loader below normalises both, so role.txt's `app=` key is unchanged.
--]]
local M = { RPV_VERSION = "RPV1" }

local function load_module(path)
    local fn = assert(loadfile(path), "cannot load " .. path)
    local ret = fn(M)
    if type(ret) == "function" then
        error("module " .. path .. " returns a function; the convention is `local M = ...` + `return M`")
    end
    return ret
end

-- ===== app loader ==========================================================
-- app_entry(loaded) normalises what loadfile("apps/<name>.lua") returned into a
-- run(M, node, args) function:
--   * a function is used as-is (round 1 form);
--   * a table with a `new` constructor (round 2 module form) is built with
--     App.new{ rpv = M, node = node, args = args, setup = false } -- the
--     bootstrap already ran node:setup(), so the app must not run it twice --
--     then start() is called and run() when the instance provides one. Apps such
--     as the router register their own node tasks from start() and need no run().
-- Returns nil plus a reason when the value is not a runnable app.
local function app_entry(loaded)
    if type(loaded) == "function" then return loaded end
    if type(loaded) ~= "table" or type(loaded.new) ~= "function" then
        return nil, "unsupported app return type (" .. type(loaded) .. ")"
    end
    return function(M_, node, args)
        local inst = loaded.new({ rpv = M_, node = node, args = args, setup = false })
        if type(inst) ~= "table" then
            error("app.new returned " .. type(inst), 0)
        end
        if type(inst.start) == "function" then
            local started = inst.start(inst)
            if started == false then error("app.start returned false", 0) end
        elseif type(inst.run) ~= "function" then
            error("app has neither start() nor run()", 0)
        end
        if type(inst.run) == "function" then inst.run(inst) end
        return inst
    end
end
M.app_entry = app_entry

-- The offline suite (tests/t_router.lua, group "startup-loader") loads this file
-- with RPV_BOOT_TEST set to exercise app_entry without role.txt, modems or the
-- reboot watchdog. A real computer never sets the flag, so boot carries on.
if type(_G) == "table" and _G.RPV_BOOT_TEST then return M end

for _, mod in ipairs({ "crypto", "util", "ip", "route", "arp", "link", "icmp", "udp", "conn", "fabric", "wan", "services", "dv", "nat", "mcast", "qos", "wansec", "compat", "topo" }) do
    load_module("rpv/" .. mod .. ".lua")
end
load_module("rpv/node.lua")

local node = M.node_new("role.txt")

-- boot watchdog state: if a previous boot crashed, say so on the next one
local crash_marker = "crash-once"
if fs.exists("crash.log") then
    node:log("WATCHDOG_RECOVERED previous boot crashed, see crash.log")
end

node:setup()

-- rednet compatibility shim (M3): legacy programs keep using the global
-- `rednet` API; with shim=1 it is backed by rpv (routed, no flooding).
if node.cfg.shim == "1" then
    load_module("compat/rednet.lua")
    local dir_ip = node.cfg.shim_dir and M.ip2int(node.cfg.shim_dir)
        or (node.cfg.gw and M.ip2int(node.cfg.gw))
    _G.rednet = M.rednet_shim_new(node, { dir_ip = dir_ip, port = tonumber(node.cfg.shim_port) or 4100 })
    node:log("SHIM_INSTALLED dir=%s", dir_ip and M.int2ip(dir_ip) or "none")
end

if node.cfg.app then
    local name, args = node.cfg.app:match("^([^:]+):?(.*)$")
    local chunk = loadfile("apps/" .. name .. ".lua")
    if not chunk then
        node:log("APP_NOT_FOUND name=%s", tostring(name))
    else
        -- app files are `return function(M, node, args)` scripts or table modules;
        -- app_entry turns either shape into the run(M, node, args) form used below
        local ok, loaded = pcall(chunk)
        if not ok then
            node:log("APP_LOAD_ERROR name=%s err=%s", tostring(name), tostring(loaded))
        else
            local entry, why = app_entry(loaded)
            if not entry then
                node:log("APP_LOAD_ERROR name=%s err=%s", tostring(name), tostring(why))
            else
                node:log("APP start name=%s args=%s", name, tostring(args))
                -- apps run as coroutine tasks so blocking-style code works
                -- (os.sleep / os.pullEvent / the rednet shim's receive)
                node:add_task(name, function()
                    local ok2, err2 = pcall(entry, M, node, args or "")
                    if not ok2 then node:log("APP_ERROR %s", tostring(err2)) end
                end)
            end
        end
    end
end

-- ---- watchdog ----
local function run()
    if node.cfg.crash_after and not fs.exists(crash_marker) then
        -- deliberate crash used by the watchdog harness (once per computer)
        local f = fs.open(crash_marker, "w")
        f.writeLine(tostring(os.epoch and os.epoch("utc") or os.clock()))
        f.close()
        os.sleep(tonumber(node.cfg.crash_after))
        error("deliberate crash for watchdog test")
    end
    node:run()
end

local ok, err = xpcall(run, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
if not ok then
    local cf = fs.open("crash.log", "a")
    cf.writeLine(string.format("%.3f [%d] BOOT_CRASH %s", os.clock(), os.getComputerID(), tostring(err)))
    cf.close()
    node:log("BOOT_CRASH %s", tostring(err))
    if node.cfg.no_reboot == "1" then
        node:log("BOOT_CRASH no_reboot=1, staying down")
    else
        node:log("BOOT_REBOOT in 3s")
        os.sleep(3)
        os.reboot()
    end
end
