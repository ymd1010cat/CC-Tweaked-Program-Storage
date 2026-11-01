-- run.lua - driver for the powergrid offline suite.
--
-- Loads the modules under test, then every /tests/t_*.lua module in sorted
-- order, passing the harness as its only argument (so adding a new t_*.lua
-- needs no edit here). Ends by shutting the computer down: CraftOS-PC only
-- flushes the filesystem when the computer stops, and run-tests.ps1 waits for
-- TEST_DONE in /logs/suite.log.

local H = dofile("/tests/harness.lua")
H.openLog("/logs/suite.log")
H.emit("POWERGRID_SUITE start")

-- switch.lua autostarts only when it is the running program; this flag makes a
-- dofile from a test always load the module instead.
_G.POWERGRID_SWITCH_TEST = true

local function readAll(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local iniBefore = readAll("/PowerGrid.ini")
H.note("PowerGrid.ini before: " .. tostring(iniBefore and iniBefore:gsub("[\r\n]+", "|")))

local okP, power = pcall(dofile, "/power.lua")
H.group("power-module-load")
H.ok(okP, "power.lua loads", H.errText(power))
H.isType(power, "table", "power.lua returns a table")
if type(power) == "table" then
    H.isType(power.apply, "function", "power.apply exported")
    H.isType(power.read, "function", "power.read exported")
    H.isType(power.validate, "function", "power.validate exported")
    H.isType(power.describe, "function", "power.describe exported")
    H.isType(power.parse, "function", "power.parse exported")
    H.isType(power.setModeInText, "function", "power.setModeInText exported")
    H.isType(power.boot, "function", "power.boot exported")
    H.isType(power.errorLine, "function", "power.errorLine exported")
    H.isType(power.normalizeCode, "function", "power.normalizeCode exported")
    H.isType(power.legacyOf, "function", "power.legacyOf exported")
    H.isType(power.LEGACY_CODES, "table", "power.LEGACY_CODES exported")
    H.isType(power.DESCRIPTIONS, "table", "power.DESCRIPTIONS exported")
    H.eq(power.DEFAULT_MODE, 1, "power.DEFAULT_MODE is the main grid")
    H.eq(power.VERSION, "1.3", "power version")
    H.eq(power.WATCHDOG_KEYS, nil, "no watchdog section keys in power.lua")
    H.eq(power.config, nil, "no watchdog config reader in power.lua")
end
H.power = power
H.readAll = readAll
H.iniBefore = iniBefore

local okS, switch = pcall(dofile, "/switch.lua")
H.group("switch-module-load")
H.ok(okS, "switch.lua loads", H.errText(switch))
H.isType(switch, "table", "switch.lua returns a table")
if type(switch) == "table" then
    H.isType(switch.run, "function", "switch.run exported")
    H.isType(switch.parseArgs, "function", "switch.parseArgs exported")
    H.isType(switch.report, "function", "switch.report exported")
    H.isType(switch.loadPower, "function", "switch.loadPower exported")
    H.eq(switch.VERSION, "1.0", "switch version")
    H.ne(switch.isMainProgram(), true, "no autostart inside the suite")
end
H.switch = switch

local names = {}
for _, name in ipairs(fs.list("/tests") or {}) do
    if name:match("^t_.*%.lua$") then names[#names + 1] = name end
end
table.sort(names)
H.note("test modules: " .. table.concat(names, ","))

for _, name in ipairs(names) do
    local path = "/tests/" .. name
    local chunk, loadErr = loadfile(path)
    if not chunk then
        H.group("load:" .. name)
        H.ok(false, "loadfile " .. name, tostring(loadErr))
    else
        local okRun, err = pcall(chunk, H)
        if not okRun then
            H.group("crash:" .. name)
            H.ok(false, "module " .. name .. " completed", H.errText(err))
        end
    end
end

-- The controller keeps its own files: the suite must not have rewritten the
-- power config, and startup.lua must keep its behaviour (the detailed delegation
-- checks live in t_power.lua).
H.group("suite-integrity")
local iniAfter = readAll("/PowerGrid.ini")
H.eq(iniAfter, iniBefore, "PowerGrid.ini byte-identical after the suite")
H.eq((iniAfter or ""):gsub("%s+$", ""), "1", "PowerGrid.ini still the single value 1")
H.ok(not fs.exists("/.settings"), "no .settings written by the suite")
local startupSource = readAll("/tests/startup_source.lua") or ""
H.contains(startupSource, "Power Grid Controller v2.1",
    "controller startup.lua version marker kept")
H.contains(startupSource, "power_api.boot()",
    "controller startup.lua boots through power.lua")
H.contains(startupSource, "CONFIG_ERROR",
    "controller startup.lua logs config problems instead of a blue screen")
H.lacks(startupSource, "configError",
    "controller startup.lua no longer treats config errors as fatal")
H.lacks(startupSource, "watchdog",
    "controller startup.lua has no watchdog hook")

H.summary()
if H.log then
    H.log.flush()
    H.log.close()
end
pcall(os.shutdown)
