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
        -- app files are `return function(M, node, args) ... end`
        local ok, app = pcall(chunk)
        if not ok or type(app) ~= "function" then
            node:log("APP_LOAD_ERROR name=%s err=%s", tostring(name), tostring(app))
        else
            node:log("APP start name=%s args=%s", name, tostring(args))
            -- apps run as coroutine tasks so blocking-style code works
            -- (os.sleep / os.pullEvent / the rednet shim's receive)
            node:add_task(name, function()
                local ok2, err2 = pcall(app, M, node, args or "")
                if not ok2 then node:log("APP_ERROR %s", tostring(err2)) end
            end)
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
