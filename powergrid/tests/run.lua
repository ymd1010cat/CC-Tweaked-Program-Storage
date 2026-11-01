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

-- watchdog_app.lua autostarts only when it is the running program; this flag
-- makes a dofile from a test always load the module instead.
_G.POWERGRID_WATCHDOG_TEST = true

local function readAll(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local iniBefore = readAll("/PowerGrid.ini")
H.note("PowerGrid.ini before: " .. tostring(iniBefore and iniBefore:gsub("[\r\n]+", "|")))

local okW, watchdog = pcall(dofile, "/watchdog.lua")
H.group("module-load")
H.ok(okW, "watchdog.lua loads", H.errText(watchdog))
H.isType(watchdog, "table", "watchdog.lua returns a table")
if type(watchdog) == "table" then
    H.isType(watchdog.new, "function", "watchdog.new exported")
    H.isType(watchdog.sample, "function", "watchdog.sample exported")
    H.isType(watchdog.status, "function", "watchdog.status exported")
    H.isType(watchdog.sanitize, "function", "watchdog.sanitize exported")
    H.isType(watchdog.DEFAULTS, "table", "watchdog.DEFAULTS exported")
    H.eq(watchdog.VERSION, "1.0", "watchdog version")
end

local okA, app = pcall(dofile, "/watchdog_app.lua")
H.ok(okA, "watchdog_app.lua loads", H.errText(app))
H.isType(app, "table", "watchdog_app.lua returns a table")
if type(app) == "table" then
    H.isType(app.new, "function", "app.new exported")
    H.isType(app.start, "function", "app.start exported")
    H.isType(app.tick, "function", "app.tick exported")
    H.isType(app.run, "function", "app.run exported")
    H.isType(app.applyAlarm, "function", "app.applyAlarm exported")
    H.isType(app.iniKeys, "function", "app.iniKeys exported")
    H.isType(app.statusLine, "function", "app.statusLine exported")
    H.isType(app.report, "function", "app.report exported")
    H.eq(app.KEYS, nil, "no CraftOS settings key table on the driver")
    H.eq(app.VERSION, "1.1", "watchdog_app version")
    H.ne(app.isMainProgram(), true, "no autostart inside the suite")
end

H.watchdog = watchdog
H.app = app
H.readAll = readAll
H.iniBefore = iniBefore

local okP, power = pcall(dofile, "/power.lua")
H.group("power-module-load")
H.ok(okP, "power.lua loads", H.errText(power))
H.isType(power, "table", "power.lua returns a table")
if type(power) == "table" then
    H.isType(power.apply, "function", "power.apply exported")
    H.isType(power.read, "function", "power.read exported")
    H.isType(power.validate, "function", "power.validate exported")
    H.isType(power.describe, "function", "power.describe exported")
    H.isType(power.config, "function", "power.config exported")
    H.isType(power.parse, "function", "power.parse exported")
    H.isType(power.setModeInText, "function", "power.setModeInText exported")
    H.isType(power.WATCHDOG_KEYS, "table", "power.WATCHDOG_KEYS exported")
    H.eq(power.VERSION, "1.1", "power version")
end
H.power = power

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

-- The controller keeps its own files: the watchdog must not have rewritten the
-- power config, and startup.lua must still keep all of its non-power behaviour
-- (the detailed delegation checks live in t_power.lua).
H.group("suite-integrity")
local iniAfter = readAll("/PowerGrid.ini")
H.eq(iniAfter, iniBefore, "PowerGrid.ini byte-identical after the suite")
H.eq((iniAfter or ""):gsub("%s+$", ""), "1", "PowerGrid.ini still the single value 1")
H.ok(not fs.exists("/.settings"), "no .settings written by the suite")
local startupSource = readAll("/tests/startup_source.lua") or ""
H.contains(startupSource, "Power Grid Controller v2.1",
    "controller startup.lua version marker kept")
H.contains(startupSource, "power_api.apply(power)",
    "controller startup.lua applies power through power.lua")
H.lacks(startupSource, "local function applyPower",
    "controller startup.lua no longer duplicates the helper")
H.lacks(startupSource, "watchdog",
    "controller startup.lua has no watchdog hook")
local watchdogSrc = readAll("/watchdog.lua") or ""
H.contains(watchdogSrc, "WATCHDOG state=", "status text lives in watchdog.lua")
H.contains(watchdogSrc, "switch_to", "the pure module carries the switch target")

H.summary()
if H.log then
    H.log.flush()
    H.log.close()
end
pcall(os.shutdown)
