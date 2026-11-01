-- t_watchdog_app.lua - driver tests for watchdog_app.lua.
--
-- The driver is exercised with a fake redstone API, a fake logger, a fake
-- settings API and a fake clock, so the suite proves what it writes (relay side
-- and value), what it logs, and - most importantly for the project scope - that
-- it never writes the power output or the controller config.

local H = ...

local A = H.app

local function newLog()
    local log = { lines = {}, info_n = 0, warn_n = 0, error_n = 0 }
    function log.write(tag, message, ...)
        local args = { ... }
        local text = tostring(message or "")
        for i = 1, #args do text = text .. tostring(args[i]) end
        log.lines[#log.lines + 1] = "[" .. tostring(tag) .. "] " .. text
        return true
    end
    function log.info(message, ...)
        log.info_n = log.info_n + 1
        return log.write("info", message, ...)
    end
    function log.warn(message, ...)
        log.warn_n = log.warn_n + 1
        return log.write("warn", message, ...)
    end
    function log.error(message, ...)
        log.error_n = log.error_n + 1
        return log.write("error", message, ...)
    end
    return log
end

local function count(rawLog, needle)
    local n = 0
    for i = 1, #rawLog.lines do
        if rawLog.lines[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function findLine(rawLog, needle)
    for i = 1, #rawLog.lines do
        if rawLog.lines[i]:find(needle, 1, true) then return rawLog.lines[i] end
    end
    return ""
end

local function newRedstone(level)
    local rs = { calls = {}, level = level, input_side = nil }
    function rs.getAnalogInput(side)
        rs.input_side = side
        return rs.level
    end
    function rs.setOutput(side, value)
        rs.calls[#rs.calls + 1] = { side = side, value = value }
        return true
    end
    return rs
end

local function newClock(start)
    local c = { t = start or 0 }
    function c.now() return c.t end
    return c
end

local function countKeys(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

-- Config loading -------------------------------------------------------------

H.group("app-config")
local fake = { store = {
    ["powergrid.watchdog.enabled"] = "true",
    ["powergrid.watchdog.low"] = "3",
    ["powergrid.watchdog.high"] = "12",
    ["powergrid.watchdog.window"] = "120",
    ["powergrid.watchdog.poll"] = "10",
    ["powergrid.watchdog.input_side"] = "back",
    ["powergrid.watchdog.alarm_side"] = "right",
} }
function fake.get(key) return fake.store[key] end

local raw, used = A.readConfig(fake)
H.eq(used, true, "readConfig reports a usable settings API")
H.eq(raw.low, "3", "readConfig returns the raw value")
H.eq(raw.alarm_side, "right", "readConfig reads the alarm side")
H.eq(raw.enabled, "true", "readConfig reads enabled")
local emptyRaw, emptyUsed = A.readConfig({})
H.eq(emptyUsed, false, "an API without get is not used")
H.eq(countKeys(emptyRaw), 0, "no raw options without an API")

local app = A.new({
    settings = fake,
    redstone = newRedstone(15),
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.num(app.state.cfg.low, 3, "settings feed the state machine")
H.num(app.state.cfg.high, 12, "settings high applied")
H.num(app.state.cfg.window, 120, "settings window applied")
H.eq(app.state.cfg.alarm_side, "right", "settings alarm side applied")
H.eq(app.state.cfg.enabled, true, "settings enabled applied")
H.eq(app.state.problem_count, 0, "valid settings have no problems")

local appDirect = A.new({
    config = { low = 4, high = 9, window = 30, poll = 5 },
    redstone = newRedstone(15),
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.num(appDirect.state.cfg.low, 4, "explicit config overrides settings")
H.eq(appDirect.status, "new", "a fresh app is not started")

local badLog = newLog()
local appBad = A.new({
    config = { low = 9, high = 5, window = 0, poll = -1 },
    redstone = newRedstone(15),
    logger = badLog,
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.ok(appBad.state.problem_count >= 3, "invalid config collected", appBad.state.problem_count)
H.eq(A.start(appBad), "running", "a bad config still starts with defaults")
H.eq(count(badLog, "WATCHDOG_CONFIG_BAD"), appBad.state.problem_count,
    "one config line per problem")
H.num(appBad.state.cfg.low, 2, "invalid low fell back to the default")
H.num(appBad.state.cfg.high, 10, "invalid high fell back to the default")
H.num(appBad.state.cfg.window, 300, "invalid window fell back to the default")
H.num(appBad.state.cfg.poll, 10, "invalid poll fell back to the default")

-- Alarm relay ----------------------------------------------------------------

H.group("app-relay")
local clock = newClock(0)
local rs = newRedstone(15)
local log = newLog()
local appR = A.new({
    config = { low = 2, high = 10, window = 30, poll = 10, alarm_side = "left",
        input_side = "back" },
    redstone = rs,
    logger = log,
    clock = clock.now,
    watchdog = H.watchdog,
})
H.eq(A.start(appR), "running", "start arms the monitor")
H.eq(appR.relay_writes, 1, "the relay is initialised once")
H.eq(#rs.calls, 1, "exactly one relay write at start")
H.eq(rs.calls[1].side, "left", "the alarm side is left")
H.eq(rs.calls[1].value, false, "the relay starts in the safe state")
H.eq(count(log, "WATCHDOG_START"), 1, "start is logged")
H.contains(findLine(log, "WATCHDOG_START"), "input=back", "start log has the input side")
H.contains(findLine(log, "WATCHDOG_START"), "window=30", "start log has the window")

rs.level = 1
H.eq(A.tick(appR, 0), "none", "a short dip is not an alarm")
H.eq(#rs.calls, 1, "no relay write while the streak is short")
H.eq(A.tick(appR, 10), "none", "still waiting")
H.eq(A.tick(appR, 20), "none", "still waiting")
H.eq(#rs.calls, 1, "still no relay write")
H.eq(A.tick(appR, 30), "alarm", "window reached -> alarm")
H.eq(appR.relay, true, "relay is on")
H.eq(#rs.calls, 2, "one relay write for the alarm")
H.eq(rs.calls[2].side, "left", "alarm writes the alarm side")
H.eq(rs.calls[2].value, true, "alarm writes true")
H.eq(count(log, "WATCHDOG_ALARM"), 1, "the alarm is logged once")
H.contains(findLine(log, "WATCHDOG_ALARM"), "side=left", "alarm log has the side")
H.contains(findLine(log, "WATCHDOG_ALARM"), "window=30", "alarm log has the window")
H.eq(log.error_n >= 1, true, "the alarm is logged at error level")
H.num(appR.state.alarms, 1, "one alarm counted")

H.eq(A.tick(appR, 40), "none", "the alarm is one-shot")
H.eq(count(log, "WATCHDOG_ALARM"), 1, "no repeated alarm log")
H.eq(#rs.calls, 2, "no repeated relay write")

rs.level = 12
H.eq(A.tick(appR, 50), "clear", "a healthy sample clears")
H.eq(appR.relay, false, "relay off after recovery")
H.eq(#rs.calls, 3, "one relay write for the recovery")
H.eq(rs.calls[3].value, false, "recovery writes false")
H.eq(count(log, "WATCHDOG_CLEAR"), 1, "the recovery is logged")
H.num(appR.state.recoveries, 1, "one recovery counted")
H.eq(appR.polls, 6, "six polls so far")

local otherSides = 0
local trueWrites = 0
for i = 1, #rs.calls do
    if rs.calls[i].side ~= "left" then otherSides = otherSides + 1 end
    if rs.calls[i].value == true then trueWrites = trueWrites + 1 end
end
H.eq(otherSides, 0, "only the alarm side is ever written")
H.eq(trueWrites, 1, "exactly one relay-on write")

local statusText = A.statusLine(appR)
H.contains(statusText, "WATCHDOG state=ok", "status line starts with the summary")
H.contains(statusText, "relay=off", "status line has the relay state")
H.contains(statusText, "polls=6", "status line has the poll count")
H.contains(statusText, "read_fail=0", "status line has the read failures")
H.eq(count(log, "WATCHDOG_STATUS"), 0, "status is only logged on demand")
A.report(appR)
H.eq(count(log, "WATCHDOG_STATUS"), 1, "report logs one status line")

-- Disabled -------------------------------------------------------------------

H.group("app-disabled")
local rsOff = newRedstone(1)
local logOff = newLog()
local appOff = A.new({
    config = { enabled = false },
    redstone = rsOff,
    logger = logOff,
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.eq(A.start(appOff), "disabled", "disabled start returns disabled")
H.eq(#rsOff.calls, 0, "disabled never drives the relay")
H.eq(count(logOff, "WATCHDOG_DISABLED"), 1, "disabled is logged once")
H.eq(count(logOff, "WATCHDOG_START"), 0, "disabled does not log a start")
H.eq(A.tick(appOff, 0), "disabled", "disabled tick reports disabled")
H.eq(#rsOff.calls, 0, "disabled tick writes nothing")
H.eq(appOff.polls, 0, "disabled tick does not count a poll")
H.eq(appOff.state.checks, 0, "disabled tick does not sample")

-- Read failures --------------------------------------------------------------

H.group("app-read-fail")
local logFail = newLog()
local appFail = A.new({
    config = {},
    redstone = newRedstone(1),
    logger = logFail,
    clock = newClock(0).now,
    read = function() return nil, "no sensor" end,
    watchdog = H.watchdog,
})
A.start(appFail)
H.eq(A.tick(appFail, 0), "read_fail", "nil reading is a read failure")
H.eq(appFail.read_errors, 1, "read failure counted")
H.eq(count(logFail, "WATCHDOG_READ_FAIL"), 1, "the first read failure is logged")
H.eq(A.tick(appFail, 10), "read_fail", "second failure reported too")
H.eq(appFail.read_errors, 2, "second failure counted")
H.eq(count(logFail, "WATCHDOG_READ_FAIL"), 1, "repeat failures are counted, not logged")

local appRaise = A.new({
    config = {},
    redstone = newRedstone(1),
    logger = newLog(),
    clock = newClock(0).now,
    read = function() error("boom") end,
    watchdog = H.watchdog,
})
A.start(appRaise)
H.eq(A.tick(appRaise, 0), "read_fail", "a raising reader is contained")
H.eq(appRaise.read_errors, 1, "raising reader counted")

local appNoRs = A.new({
    config = {},
    redstone = {},
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.eq(A.tick(appNoRs, 0), "read_fail", "missing redstone API is a read failure")
H.eq(A.applyAlarm(appNoRs, true), false, "applyAlarm reports a missing API")

-- Windows and the main loop --------------------------------------------------

H.group("app-reader-and-run")
local rsDefault = newRedstone(7)
local appDefault = A.new({
    config = { input_side = "top" },
    redstone = rsDefault,
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.num(appDefault.read(), 7, "the default reader returns the analog input")
H.eq(rsDefault.input_side, "top", "the default reader uses input_side")

local runClock = newClock(0)
local runRs = newRedstone(1)
local runLog = newLog()
local sleeps = 0
local function sleepFn(seconds)
    sleeps = sleeps + 1
    if sleeps > 3 then error("stop_loop") end
    runClock.t = runClock.t + (seconds or 0)
end
local appRun = A.new({
    config = { low = 2, high = 10, window = 30, poll = 10 },
    redstone = runRs,
    logger = runLog,
    clock = runClock.now,
    sleep = sleepFn,
    watchdog = H.watchdog,
})
local okRun, runErr = pcall(A.run, appRun)
H.eq(okRun, false, "the injected sleep breaks the loop on purpose")
H.contains(tostring(runErr), "stop_loop", "the loop error is the injected one")
H.eq(sleeps, 4, "the loop slept between polls")
H.eq(appRun.state.alarms, 1, "the loop raised an alarm")
H.eq(appRun.relay, true, "the loop left the relay on")
H.num(appRun.polls, 4, "the loop polled four times")
H.eq(count(runLog, "WATCHDOG_ALARM"), 1, "the loop logged the alarm")

-- Static source checks -------------------------------------------------------

H.group("app-static-source")
local appSrc = H.readAll("/watchdog_app.lua") or ""
local wdSrc = H.readAll("/watchdog.lua") or ""
H.contains(appSrc, "WATCHDOG_START", "driver has the start keyword")
H.contains(appSrc, "WATCHDOG_ALARM", "driver has the alarm keyword")
H.contains(appSrc, "WATCHDOG_CLEAR", "driver has the clear keyword")
H.contains(appSrc, "WATCHDOG_DISABLED", "driver has the disabled keyword")
H.contains(appSrc, "WATCHDOG_CONFIG_BAD", "driver has the config keyword")
H.contains(appSrc, "WATCHDOG_READ_FAIL", "driver has the read failure keyword")
H.contains(appSrc, "WATCHDOG_RELAY_FAIL", "driver has the relay failure keyword")
H.contains(appSrc, "WATCHDOG_STATUS", "driver has the status keyword")
H.contains(appSrc, "POWERGRID_WATCHDOG_TEST", "driver has the test guard")
H.lacks(appSrc, "applyPower", "driver never calls applyPower")
H.lacks(appSrc, "PowerGrid.ini", "driver never opens the controller config")
H.lacks(appSrc, "setAnalogOutput", "driver never writes an analog power level")
H.lacks(appSrc, "setOutput(\"back\"", "driver never writes the back side")
H.lacks(appSrc, "turtle.", "driver drives no turtle")
H.lacks(wdSrc, "redstone.", "the pure module has no redstone calls")
H.lacks(wdSrc, "os.clock", "the pure module reads no clock")
H.lacks(wdSrc, "fs.open", "the pure module opens no files")
H.lacks(wdSrc, "dofile", "the pure module loads nothing")
H.lacks(wdSrc, "require(", "the pure module depends on nothing")
H.lacks(wdSrc, "print(", "the pure module prints nothing")

-- Autostart guard ------------------------------------------------------------

H.group("app-autostart-guard")
H.eq(A.KEYS.low, "powergrid.watchdog.low", "settings key for low")
H.eq(A.KEYS.alarm_side, "powergrid.watchdog.alarm_side", "settings key for alarm side")
H.eq(countKeys(A.KEYS), 7, "seven settings keys")
local savedArg = _G.arg
local savedShell = _G.shell
local savedFlag = _G.POWERGRID_WATCHDOG_TEST
_G.POWERGRID_WATCHDOG_TEST = nil
_G.arg = { [0] = "/watchdog_app.lua" }
_G.shell = { getRunningProgram = function() return "/watchdog_app.lua" end }
H.eq(A.isMainProgram(), true, "autostarts when this file is the program")
_G.arg = { [0] = "/startup.lua" }
H.eq(A.isMainProgram(), false, "no autostart when another program runs")
_G.arg = { [0] = "/watchdog_app.lua" }
_G.shell = { getRunningProgram = function() return "/startup.lua" end }
H.eq(A.isMainProgram(), false, "no autostart when the running program differs")
_G.POWERGRID_WATCHDOG_TEST = true
_G.shell = { getRunningProgram = function() return "/watchdog_app.lua" end }
H.eq(A.isMainProgram(), false, "the test flag always wins")
_G.POWERGRID_WATCHDOG_TEST = nil
_G.arg = nil
H.eq(A.isMainProgram(), false, "no autostart without arg")
_G.arg, _G.shell, _G.POWERGRID_WATCHDOG_TEST = savedArg, savedShell, savedFlag

-- Real logger / default module resolution ------------------------------------

H.group("app-real-logger")
local appReal = A.new({
    config = { low = 2, high = 10, window = 5, poll = 1,
        alarm_side = "right", input_side = "top" },
})
H.isType(appReal.logger.info, "function", "logger.lua is resolved by default")
H.isType(appReal.watchdog.sample, "function", "watchdog.lua is resolved by default")
H.eq(A.start(appReal), "running", "the default stack starts")
local reportLine = A.report(appReal)
H.contains(reportLine, "WATCHDOG state=", "report returns the status text")
local mainLog = H.readAll("/Main.log") or ""
H.contains(mainLog, "WATCHDOG_START", "the real logger wrote the start line")
H.contains(mainLog, "WATCHDOG_STATUS", "the real logger wrote the status line")
H.contains(mainLog, "[info]", "the logger tag format is kept")
H.contains(mainLog, "input=top", "the start line carries the configured side")
H.ok(mainLog:find("%[info%] %d%d%d%d%.%d%d%.%d%d %d%d:%d%d") ~= nil,
    "the real log line uses [tag] YYYY.MM.DD HH:MM")
H.lacks(mainLog, "[error]", "no error line on a healthy start")
