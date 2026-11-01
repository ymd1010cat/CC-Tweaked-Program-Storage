-- switch.lua - tiny command line front end for power.lua.
--
-- The project has no software watchdog any more: a physical watchdog (redstone
-- timer, pressure plate, player, another computer) decides when to switch. This
-- program is the smallest way to make that decision land in the controller:
--
--   switch 2     -- main grid (1) / backup battery (2) / external (3) / off (0)
--
-- It validates the argument, calls power.apply(mode) (which rewrites the mode
-- line of PowerGrid.ini, drives the "back" analog output and chirps the
-- speaker) and prints the result. A write failure is reported the same way the
-- controller reports it (CONFIG_WRITE_FAILED), without a blue screen: this little
-- tool must stay usable from scripts.
--
-- It also works as a module:
--   local switch = dofile("switch.lua")
--   switch.run({ "2" })              -- uses require/dofile power.lua
--   switch.run({ "2" }, { power = p })  -- injected power module (tests)

local M = {}

M.VERSION = "1.0"
M.USAGE = "usage: switch <0-3>"

-- Resolve power.lua without hard-failing.
local function loadPower()
    if type(require) == "function" then
        local ok, mod = pcall(require, "power")
        if ok and type(mod) == "table" then return mod end
    end
    local ok, mod = pcall(dofile, "/power.lua")
    if ok and type(mod) == "table" then return mod end
    return nil
end
M.loadPower = loadPower

-- args -> mode, or nil, error text.
function M.parseArgs(args)
    local raw = args and args[1]
    if raw == nil then
        return nil, M.USAGE
    end
    local mode = tonumber(raw)
    if mode == nil then
        return nil, "mode must be a number 0-3, got: " .. tostring(raw)
    end
    if mode ~= math.floor(mode) or mode < 0 or mode > 3 then
        return nil, "mode must be an integer 0-3, got: " .. tostring(raw)
    end
    return mode
end

-- Switch the grid. Returns mode on success, or nil, error text.
function M.run(args, opts)
    if type(opts) ~= "table" then opts = {} end
    local mode, err = M.parseArgs(args)
    if mode == nil then
        return nil, err
    end
    local power = opts.power
    if power == nil then power = loadPower() end
    if type(power) ~= "table" or type(power.apply) ~= "function" then
        return nil, "MISSING_LIBRARY name=power file=power.lua (cannot switch the grid)"
    end
    local ok, applyErr = power.apply(mode, opts.powerOpts)
    if ok == nil then
        return nil, "CONFIG_WRITE_FAILED (" .. tostring(applyErr) ..
            "): the redstone output was still driven to " .. tostring(mode)
    end
    return mode
end

-- One line for the console.
function M.report(mode, err)
    if mode ~= nil then
        return "Power mode set to " .. tostring(mode) .. "."
    end
    return "switch: " .. tostring(err)
end

-- Only autostart when this very file is the program being run.
local function isMainProgram()
    if _G.POWERGRID_SWITCH_TEST then return false end
    local args = _G.arg
    if type(args) ~= "table" or type(args[0]) ~= "string" then return false end
    if type(_G.shell) ~= "table" or type(_G.shell.getRunningProgram) ~= "function" then
        return false
    end
    local ok, running = pcall(_G.shell.getRunningProgram)
    if not ok or type(running) ~= "string" then return false end
    if running ~= args[0] then return false end
    return running:find("switch", 1, true) ~= nil
end
M.isMainProgram = isMainProgram

if isMainProgram() then
    local mode, err = M.run(_G.arg)
    local line = M.report(mode, err)
    if type(print) == "function" then
        pcall(print, line)
    end
    if mode == nil and line:find("usage", 1, true) ~= nil then
        -- keep the usage text visible for a bare `switch`
        if type(print) == "function" then pcall(print, M.USAGE) end
    end
end

return M
