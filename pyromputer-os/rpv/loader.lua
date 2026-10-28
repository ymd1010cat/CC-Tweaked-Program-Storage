--[[- rpv.lua ? RPV1 (Rednet Protocol Version 1) library entry point.

This is the ONLY file an external program needs to load. It finds the module
directory itself, loads every module in dependency order and returns the merged
library table.

Inside a CC:Tweaked computer with this layout:

    /rpv.lua            <- this file
    /rpv/*.lua          <- the modules
    /my-program.lua     <- your program

your program does:

    local rpv = require("rpv")          -- or: local rpv = dofile("rpv.lua")
    local node = rpv.node_new({         -- config table; no role.txt needed
        role = "host",
        ifaces = { { side = "left", name = "LAN", cidr = "10.0.1.2/24",
                     channel = 4001, mtu = 256, linktype = "wireless" } },
        gw = "10.0.1.1",
    })
    node:setup()                        -- opens modems, installs routes, starts tick
    node:bind(4100, function(data, src, sport) print(src, data) end)

    while true do node:run_once() end   -- your main loop (or use node:after/timers)

See rpv/API.md for the full public API, and /examples for complete programs that
use nothing but this entry point (they are installed as startup.lua and create
their own node, with no bootstrap and no config file).
]]
local M = { RPV_VERSION = "RPV1" }

-- module files are `return function(M) ... end`: they enrich the shared table
local MODULES = { "crypto", "util", "ip", "route", "arp", "link", "icmp", "udp", "conn", "fabric", "wan", "services", "dv", "nat", "mcast", "qos", "wansec", "compat", "topo" }
local NODE_MODULE = "node"

-- work out where we were loaded from, so require("rpv") works from any cwd and
-- from any install directory (/rpv.lua, /lib/rpv.lua, ./rpv.lua, ...)
local function own_dir()
    local src = (debug and debug.getinfo) and debug.getinfo(1, "S").source or ""
    local path = src:gsub("^@", "")
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    if dir and dir ~= "" then return dir .. "/" end
    return ""
end

local dir = own_dir()
local function find_module(name)
    local candidates = {
        dir .. "rpv/" .. name .. ".lua",   -- <dir>/rpv/<name>.lua  (normal layout)
        dir .. name .. ".lua",             -- <dir>/<name>.lua      (flat layout)
        "rpv/" .. name .. ".lua",
        name .. ".lua",
    }
    for _, p in ipairs(candidates) do
        if fs.exists(p) then return p end
    end
    return nil
end

for _, name in ipairs(MODULES) do
    local path = find_module(name)
    if not path then error("rpv: cannot find module '" .. name .. "' (looked in " .. (dir ~= "" and dir or "./") .. "rpv/)") end
    local fn = assert(loadfile(path), "rpv: cannot load " .. path)
    local ret = fn(M)
    -- module convention: the file itself is the module (`local M = ...` ... `return M`).
    -- `return function(M)` would silently enrich nothing, so fail loudly here.
    if type(ret) == "function" then
        error("rpv: module " .. path .. " returns a function; use `local M = ...` + `return M`")
    end
end
do
    local path = find_module(NODE_MODULE)
    if not path then error("rpv: cannot find module 'node'") end
    assert(loadfile(path), "rpv: cannot load " .. path)(M)
end

-- ---- public conveniences ---------------------------------------------------
M.version = M.RPV_VERSION
M.modules = MODULES
M.lib = true                      -- marks "loaded through the library entry point"
M.new_node = M.node_new           -- alias

-- Enable the rednet compatibility shim (see poc/compat/rednet.lua): legacy
-- programs keep calling the global `rednet` API, backed by routed rpv UDP.
-- Returns the shim table (also installed as _G.rednet unless install_global=false).
function M.install_rednet_shim(node, opts)
    opts = opts or {}
    local path = opts.path or (dir .. "compat/rednet.lua")
    if not fs.exists(path) then path = "compat/rednet.lua" end
    if not fs.exists(path) then error("rpv: rednet shim not installed (expected compat/rednet.lua)") end
    local fn = assert(loadfile(path), "rpv: cannot load " .. path)
    fn(M)
    local shim = M.rednet_shim_new(node, {
        dir_ip = opts.dir_ip and M.ip2int(opts.dir_ip) or nil,
        port = tonumber(opts.port) or 4100,
    })
    if opts.install_global ~= false then _G.rednet = shim end
    return shim
end

return M
