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

-- power.lua-style fake: records the modes it was asked to apply and answers
-- read() with the last applied mode. The real power.lua (ini + redstone writes)
-- is exercised in t_power.lua and in the app-switch group below.
local function newNoopPower(mode)
    local p = { calls = {}, mode = mode or 1 }
    function p.read() return p.mode end
    function p.apply(value)
        p.calls[#p.calls + 1] = value
        p.mode = value
        return true
    end
    return p
end

local function newPowerRedstone()
    local rs = { calls = {} }
    function rs.setOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setOutput", side, value }
        return true
    end
    function rs.setAnalogOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setAnalogOutput", side, value }
        return true
    end
    return rs
end

local function newSpeaker()
    local p = { sounds = {} }
    function p.find(kind)
        if kind == "speaker" then
            return { playSound = function(name)
                p.sounds[#p.sounds + 1] = name
            end }
        end
        return nil
    end
    return p
end

-- Config loading -------------------------------------------------------------

local function writeText(path, text)
    local f = fs.open(path, "w")
    f.write(text)
    f.close()
end

local function readText(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

-- power.lua bound to a test ini path, so the app's configuration source is
-- exercised without ever touching the staged PowerGrid.ini fixture.
local function powerAt(path, redstone, peripheralApi)
    return {
        WATCHDOG_KEYS = H.power.WATCHDOG_KEYS,
        config = function() return H.power.config({ path = path }) end,
        read = function() return H.power.read({ path = path }) end,
        apply = function(value)
            return H.power.apply(value, {
                path = path,
                redstone = redstone,
                peripheral = peripheralApi,
            })
        end,
    }
end

H.group("app-config")
local configPath = "/tests/app_config.ini"
writeText(configPath, "# app config fixture\n" ..
    "mode=1\n" ..
    "watchdog.low=3\n" ..
    "watchdog.high=12\n" ..
    "watchdog.window=120\n" ..
    "watchdog.poll=10\n" ..
    "watchdog.input_side=bottom\n" ..
    "watchdog.alarm_side=right\n")

local app = A.new({
    power = powerAt(configPath, newRedstone(15), newSpeaker()),
    redstone = newRedstone(15),
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.num(app.state.cfg.low, 3, "the ini feeds the state machine")
H.num(app.state.cfg.high, 12, "the ini high is applied")
H.num(app.state.cfg.window, 120, "the ini window is applied")
H.eq(app.state.cfg.alarm_side, "right", "the ini alarm side is applied")
H.eq(app.state.cfg.input_side, "bottom", "the ini input side is applied")
H.eq(app.state.cfg.enabled, true, "a missing enabled key defaults to true")
H.eq(app.state.problem_count, 0, "a valid ini has no problems")
H.isType(app.ini, "table", "the parse report is kept")
H.eq(app.ini.format, "keyvalue", "the fixture really is key=value")
H.eq(app.ini.mode, 1, "the report carries the mode")
H.eq(app.ini.path, configPath, "the report carries the path")

-- A missing ini keeps the monitor on every default, and says so.
local missingLog = newLog()
local appMissing = A.new({
    path = "/tests/no_config_here.ini",
    power = powerAt("/tests/no_config_here.ini", newRedstone(15), newSpeaker()),
    redstone = newRedstone(15),
    logger = missingLog,
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.eq(appMissing.ini.format, "missing", "a missing ini is reported")
H.eq(appMissing.ini.mode_error, "FILE_NOT_FOUND", "a missing ini keeps the archived code")
H.num(appMissing.state.cfg.low, 2, "a missing ini uses the defaults")
H.eq(appMissing.state.cfg.enabled, true, "a missing ini still enables the monitor")
H.eq(A.start(appMissing), "running", "a missing ini still starts")
H.eq(count(missingLog, "WATCHDOG_CONFIG_FAIL code=FILE_NOT_FOUND"), 1,
    "the missing ini is logged")

local appDirect = A.new({
    config = { low = 4, high = 9, window = 30, poll = 5 },
    redstone = newRedstone(15),
    logger = newLog(),
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.num(appDirect.state.cfg.low, 4, "explicit config overrides the ini")
H.eq(appDirect.ini, nil, "no parse report for an explicit config")
H.eq(appDirect.status, "new", "a fresh app is not started")

local badPath = "/tests/app_config_bad.ini"
writeText(badPath, "mode=1\n" ..
    "watchdog.low=99\n" ..
    "watchdog.high=abc\n" ..
    "watchdog.window=0\n" ..
    "watchdog.bogus=7\n" ..
    "stray line\n")
local badLog = newLog()
local appBad = A.new({
    power = powerAt(badPath, newRedstone(15), newSpeaker()),
    redstone = newRedstone(15),
    logger = badLog,
    clock = newClock(0).now,
    watchdog = H.watchdog,
})
H.ok(appBad.state.problem_count >= 3, "invalid ini values are collected",
    appBad.state.problem_count)
H.eq(A.start(appBad), "running", "a bad ini still starts with defaults")
H.eq(count(badLog, "WATCHDOG_CONFIG_BAD key=watchdog.low value=99 fallback=2"), 1,
    "the low fallback line is exact")
H.contains(findLine(badLog, "WATCHDOG_CONFIG_BAD key=watchdog.high"),
    "fallback=10", "the high fallback line names the default")
H.eq(count(badLog, "WATCHDOG_CONFIG_BAD key=watchdog.bogus value=7 fallback=ignored"), 1,
    "unknown keys are reported")
H.eq(count(badLog, "WATCHDOG_CONFIG_BAD line=stray line fallback=ignored"), 1,
    "malformed lines are reported")
H.eq(count(badLog, "WATCHDOG_CONFIG path=" .. badPath ..
    " format=keyvalue mode=1"), 1, "the parse summary is logged")
H.num(appBad.state.cfg.low, 2, "invalid low fell back to the default")
H.num(appBad.state.cfg.high, 10, "invalid high fell back to the default")
H.num(appBad.state.cfg.window, 300, "invalid window fell back to the default")
H.eq(readText("/PowerGrid.ini"), "1\n", "the staged fixture is still untouched")

-- Alarm relay ----------------------------------------------------------------

H.group("app-relay")
local clock = newClock(0)
local rs = newRedstone(15)
local log = newLog()
local appR = A.new({
    config = { low = 2, high = 10, window = 30, poll = 10, alarm_side = "left",
        input_side = "bottom" },
    redstone = rs,
    logger = log,
    clock = clock.now,
    power = newNoopPower(1),
    watchdog = H.watchdog,
})
H.eq(A.start(appR), "running", "start arms the monitor")
H.eq(appR.relay_writes, 1, "the relay is initialised once")
H.eq(#rs.calls, 1, "exactly one relay write at start")
H.eq(rs.calls[1].side, "left", "the alarm side is left")
H.eq(rs.calls[1].value, false, "the relay starts in the safe state")
H.eq(count(log, "WATCHDOG_START"), 1, "start is logged")
H.contains(findLine(log, "WATCHDOG_START"), "input=bottom", "start log has the input side")
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
    power = newNoopPower(1),
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
H.contains(appSrc, "WATCHDOG_SWITCH_FAIL", "driver has the switch failure keyword")
H.contains(appSrc, "WATCHDOG_SWITCH", "driver has the switch keyword")
H.contains(appSrc, "WATCHDOG_RESTORE", "driver has the restore keyword")
H.contains(appSrc, "WATCHDOG_RESTORE_SKIP", "driver has the restore skip keyword")
H.contains(appSrc, "switchPower", "driver exposes switchPower")
H.contains(appSrc, "restorePower", "driver exposes restorePower")
H.contains(appSrc, "WATCHDOG_STATUS", "driver has the status keyword")
H.contains(appSrc, "WATCHDOG_CONFIG", "driver has the config summary keyword")
H.contains(appSrc, "POWERGRID_WATCHDOG_TEST", "driver has the test guard")
H.contains(appSrc, "iniConfig", "driver reads its config through power.lua")
H.lacks(appSrc, "settings", "driver reads no CraftOS settings")
H.lacks(appSrc, "powergrid.watchdog.", "driver uses the ini key names, not the old ones")
H.lacks(appSrc, "io.open", "driver never opens a file itself")
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
local iniKeys = H.power.WATCHDOG_KEYS
H.eq(iniKeys.low, "watchdog.low", "ini key for low")
H.eq(iniKeys.alarm_side, "watchdog.alarm_side", "ini key for alarm side")
H.eq(iniKeys.switch_to, "watchdog.switch_to", "ini key for switch_to")
H.eq(iniKeys.restore, "watchdog.restore", "ini key for restore")
H.eq(countKeys(iniKeys), 9, "nine ini keys")
H.eq(A.iniKeys(H.power), iniKeys, "the driver reuses the power.lua mapping")
H.eq(countKeys(A.iniKeys(nil)), 0, "no mapping without a power module")
H.eq(A.KEYS, nil, "the old CraftOS settings key table is gone")
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

-- Power switch and restore ----------------------------------------------------

H.group("app-switch")
local P = H.power
local modePath = "/tests/watchdog_mode.ini"

local function writeMode(value)
    local f = fs.open(modePath, "w")
    f.write(tostring(value) .. "\n")
    f.close()
end

local function modeText()
    local f = fs.open(modePath, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

-- A power table backed by the real power.lua, but writing a test-only ini so the
-- staged PowerGrid.ini fixture is never touched.
local function rigPower(redstone, peripheralApi)
    return {
        WATCHDOG_KEYS = P.WATCHDOG_KEYS,
        config = function() return P.config({ path = modePath }) end,
        read = function() return P.read({ path = modePath }) end,
        apply = function(value)
            return P.apply(value, {
                path = modePath,
                redstone = redstone,
                peripheral = peripheralApi,
            })
        end,
    }
end

writeMode(1)
local swingLevel = 1
local relayA = newRedstone(1)
local powerRsA = newPowerRedstone()
local speakerA = newSpeaker()
local logA = newLog()
local appA = A.new({
    config = { low = 2, high = 10, window = 30, poll = 10, switch_to = 2,
        restore = true },
    redstone = relayA,
    logger = logA,
    clock = newClock(0).now,
    read = function() return swingLevel end,
    power = rigPower(powerRsA, speakerA),
    watchdog = H.watchdog,
})
H.eq(A.start(appA), "running", "switch scenario starts")
H.eq(#powerRsA.calls, 0, "start never drives the power output")
H.num(A.readMode(appA), 1, "readMode sees the pre-alarm mode")
H.contains(findLine(logA, "WATCHDOG_START"), "switch_to=2", "start log has switch_to")
H.contains(findLine(logA, "WATCHDOG_START"), "restore=1", "start log has restore")
H.eq(A.tick(appA, 0), "none", "no switch before the window")
H.eq(A.tick(appA, 10), "none", "still waiting")
H.eq(A.tick(appA, 20), "none", "still waiting")
H.eq(#powerRsA.calls, 0, "no power write before the window")
H.eq(modeText(), "1\n", "the mode file still holds the main grid")
H.eq(A.tick(appA, 30), "alarm", "the window fires the alarm")
H.eq(modeText(), "2\n", "the mode file now holds the backup mode")
H.eq(#powerRsA.calls, 2, "exactly one setOutput + one setAnalogOutput")
H.eq(powerRsA.calls[1][1], "setOutput", "setOutput comes first")
H.eq(powerRsA.calls[1][2], "back", "power writes the back side")
H.eq(powerRsA.calls[1][3], true, "the power output goes on")
H.eq(powerRsA.calls[2][1], "setAnalogOutput", "then the analog output")
H.num(powerRsA.calls[2][3], 2, "the analog level is the backup mode")
H.eq(speakerA.sounds[1], "create:confirm", "the speaker chirped")
H.num(appA.switches, 1, "one switch counted")
H.num(appA.switch_from, 1, "the pre-alarm mode was captured")
H.eq(appA.switched, true, "the switch is recorded")
H.eq(appA.last_mode, 2, "the cached mode follows the switch")
H.eq(count(logA, "WATCHDOG_SWITCH from=1 to=2 reason=low level=1"), 1,
    "the switch log line is exact")
H.eq(relayA.calls[#relayA.calls].side, "left", "the alarm relay fired too")
H.eq(A.tick(appA, 40), "none", "the alarm is one-shot")
H.eq(#powerRsA.calls, 2, "no extra power write while latched")
writeMode(3)
H.eq(A.tick(appA, 50), "none", "still latched")
H.eq(modeText(), "3\n", "the watchdog does not fight a manual change")
H.eq(#powerRsA.calls, 2, "no per-poll correction write")
swingLevel = 12
H.eq(A.tick(appA, 60), "clear", "recovery clears")
H.eq(modeText(), "1\n", "recovery restores the pre-alarm mode")
H.eq(#powerRsA.calls, 4, "the restore writes twice as well")
H.eq(powerRsA.calls[3][1], "setOutput", "restore setOutput")
H.eq(powerRsA.calls[3][3], true, "restore output on")
H.num(powerRsA.calls[4][3], 1, "restore analog level is the pre-alarm mode")
H.eq(count(logA, "WATCHDOG_RESTORE to=1"), 1, "the restore log line is exact")
H.num(appA.restores, 1, "one restore counted")
H.eq(appA.switched, false, "the switch record is cleared")
H.eq(appA.switch_from, nil, "no stale pre-alarm mode")
H.eq(A.tick(appA, 70), "none", "healthy samples stay quiet")
H.eq(#powerRsA.calls, 4, "no power write on healthy polls")

-- Already in the target mode: logged noop, no write, nothing to restore.
writeMode(2)
local levelB = 1
local powerRsB = newPowerRedstone()
local logB = newLog()
local appB = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10, switch_to = 2,
        restore = true },
    redstone = newRedstone(1),
    logger = logB,
    clock = newClock(0).now,
    read = function() return levelB end,
    power = rigPower(powerRsB, newSpeaker()),
    watchdog = H.watchdog,
})
A.start(appB)
A.tick(appB, 0)
H.eq(A.tick(appB, 10), "alarm", "the noop scenario alarms")
H.eq(count(logB, "WATCHDOG_SWITCH to=2 noop"), 1, "already in the target mode is a noop")
H.eq(#powerRsB.calls, 0, "a noop switch writes nothing")
H.eq(appB.switches, 0, "a noop is not counted as a switch")
H.eq(appB.switched, false, "a noop records no switch")
levelB = 12
H.eq(A.tick(appB, 20), "clear", "the noop scenario recovers")
H.eq(count(logB, "WATCHDOG_RESTORE_SKIP reason=no_switch"), 1, "nothing to restore")
H.eq(modeText(), "2\n", "the backup mode stays")
H.eq(#powerRsB.calls, 0, "no restore write without a switch")

-- restore=false: the backup mode is kept after recovery.
writeMode(1)
local levelC = 1
local powerRsC = newPowerRedstone()
local logC = newLog()
local appC = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10, switch_to = 2,
        restore = false },
    redstone = newRedstone(1),
    logger = logC,
    clock = newClock(0).now,
    read = function() return levelC end,
    power = rigPower(powerRsC, newSpeaker()),
    watchdog = H.watchdog,
})
A.start(appC)
A.tick(appC, 0)
H.eq(A.tick(appC, 10), "alarm", "restore=false still switches on alarm")
H.eq(modeText(), "2\n", "restore=false switched to the backup mode")
H.eq(#powerRsC.calls, 2, "restore=false switched once")
levelC = 12
H.eq(A.tick(appC, 20), "clear", "restore=false still clears the alarm")
H.eq(count(logC, "WATCHDOG_RESTORE_SKIP reason=restore_disabled"), 1,
    "restore=false is logged as a skip")
H.eq(modeText(), "2\n", "restore=false keeps the backup mode")
H.eq(#powerRsC.calls, 2, "restore=false writes nothing on recovery")
H.eq(appC.restores, 0, "no restore counted when disabled")
H.eq(appC.switched, false, "the switch record is closed")

-- enabled=false: neither the relay nor the power mode is touched.
writeMode(1)
local relayD = newRedstone(0)
local powerRsD = newPowerRedstone()
local logD = newLog()
local appD = A.new({
    config = { enabled = false, switch_to = 2 },
    redstone = relayD,
    logger = logD,
    clock = newClock(0).now,
    read = function() return 0 end,
    power = rigPower(powerRsD, newSpeaker()),
    watchdog = H.watchdog,
})
H.eq(A.start(appD), "disabled", "a disabled monitor does not arm")
H.eq(A.tick(appD, 0), "disabled", "a disabled monitor does not sample")
H.eq(#powerRsD.calls, 0, "disabled never switches power")
H.eq(#relayD.calls, 0, "disabled never drives the relay")
H.eq(modeText(), "1\n", "disabled leaves the mode alone")
H.eq(appD.switches, 0, "disabled counts no switch")

-- Failure paths: missing module, unreadable mode, failed write.
writeMode(1)
local logE = newLog()
local appE = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10, switch_to = 2 },
    redstone = newRedstone(1),
    logger = logE,
    clock = newClock(0).now,
    read = function() return 1 end,
    power = false,
    watchdog = H.watchdog,
})
A.start(appE)
A.tick(appE, 0)
H.eq(A.tick(appE, 10), "alarm", "the alarm still fires without a power module")
H.eq(count(logE, "WATCHDOG_SWITCH_FAIL reason=no_power_module"), 1,
    "a missing power module is logged")
H.eq(appE.switched, false, "no switch is recorded without a module")
H.eq(modeText(), "1\n", "no power write without a module")

local logF = newLog()
local appF = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10, switch_to = 2 },
    redstone = newRedstone(1),
    logger = logF,
    clock = newClock(0).now,
    read = function() return 1 end,
    power = {
        read = function() return nil, "FILE_NOT_FOUND" end,
        apply = function() error("must not be called") end,
    },
    watchdog = H.watchdog,
})
A.start(appF)
A.tick(appF, 0)
H.eq(A.tick(appF, 10), "alarm", "the alarm fires with an unreadable mode")
H.eq(count(logF, "WATCHDOG_SWITCH_FAIL reason=read_fail code=FILE_NOT_FOUND"), 1,
    "an unreadable mode is logged")
H.eq(appF.switched, false, "an unreadable mode records no switch")

local logG = newLog()
local appG = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10, switch_to = 2 },
    redstone = newRedstone(1),
    logger = logG,
    clock = newClock(0).now,
    read = function() return 1 end,
    power = {
        read = function() return 1 end,
        apply = function() return nil, "WRITE_FAILED" end,
    },
    watchdog = H.watchdog,
})
A.start(appG)
A.tick(appG, 0)
H.eq(A.tick(appG, 10), "alarm", "the alarm fires when the write fails")
H.eq(count(logG, "WATCHDOG_SWITCH_FAIL reason=write_failed code=WRITE_FAILED"), 1,
    "a failed write is logged")
H.eq(appG.switched, false, "a failed write records no switch")

-- Configuration comes from the ini only --------------------------------------

H.group("app-ini-config")
local iniPath = "/tests/app_ini_config.ini"
local iniText = "# monitoring box\n" ..
    "mode=1\n" ..
    "watchdog.enabled=true\n" ..
    "watchdog.low=3\n" ..
    "watchdog.high=9\n" ..
    "watchdog.window=20\n" ..
    "watchdog.poll=5\n" ..
    "watchdog.input_side=back\n" ..
    "watchdog.alarm_side=left\n" ..
    "watchdog.switch_to=3\n" ..
    "watchdog.restore=false\n"
writeText(iniPath, iniText)

local iniRelay = newRedstone(1)
local iniPowerRs = newPowerRedstone()
local iniLog = newLog()
local iniLevel = 1

-- The CraftOS settings store deliberately says "disabled"; the monitor must
-- ignore it completely and follow the ini.
local savedSettings = _G.settings
_G.settings = {
    get = function() return "false" end,
    set = function() return true end,
    save = function() return true end,
}
local appIni = A.new({
    power = powerAt(iniPath, iniPowerRs, newSpeaker()),
    redstone = iniRelay,
    logger = iniLog,
    clock = newClock(0).now,
    read = function() return iniLevel end,
    watchdog = H.watchdog,
})
_G.settings = savedSettings

H.eq(appIni.state.cfg.enabled, true, "the ini wins over a disabled settings store")
H.num(appIni.state.cfg.low, 3, "ini low is used")
H.num(appIni.state.cfg.high, 9, "ini high is used")
H.num(appIni.state.cfg.window, 20, "ini window is used")
H.num(appIni.state.cfg.poll, 5, "ini poll is used")
H.num(appIni.state.cfg.switch_to, 3, "ini switch_to is used")
H.eq(appIni.state.cfg.restore, false, "ini restore is used")
H.eq(appIni.ini.format, "keyvalue", "the report says key=value")

H.eq(A.start(appIni), "running", "the ini-configured monitor starts")
H.eq(count(iniLog, "WATCHDOG_CONFIG path=" .. iniPath ..
    " format=keyvalue mode=1"), 1, "the ini summary is logged")
H.eq(iniRelay.calls[1].side, "left", "the ini alarm side is used")
H.eq(A.tick(appIni, 0), "none", "no alarm before the ini window")
H.eq(A.tick(appIni, 10), "none", "still waiting")
H.eq(A.tick(appIni, 20), "alarm", "the ini window fires the alarm")
H.eq(count(iniLog, "WATCHDOG_SWITCH from=1 to=3 reason=low level=1"), 1,
    "the ini switch target is used")
local expectedModeLine = "mode=3\n"
local afterSwitch = readText(iniPath) or ""
H.eq(afterSwitch, (iniText:gsub("mode=1\n", expectedModeLine, 1)),
    "the switch rewrote only the mode line")
H.num(appIni.switches, 1, "one switch from the ini configuration")
iniLevel = 12
H.eq(A.tick(appIni, 40), "clear", "recovery still works")
H.eq(count(iniLog, "WATCHDOG_RESTORE_SKIP reason=restore_disabled"), 1,
    "ini restore=false keeps the backup")
H.eq(readText(iniPath), afterSwitch, "restore=false left the mode line alone")

H.group("app-legacy-ini")
local legacyPath = "/tests/app_legacy.ini"
writeText(legacyPath, "1\n")
local legacyLog = newLog()
local legacyPowerRs = newPowerRedstone()
local legacyApp = A.new({
    power = powerAt(legacyPath, legacyPowerRs, newSpeaker()),
    redstone = newRedstone(1),
    logger = legacyLog,
    clock = newClock(0).now,
    read = function() return 0 end,
    watchdog = H.watchdog,
})
H.eq(legacyApp.ini.format, "legacy", "a bare number is the legacy format")
H.num(legacyApp.ini.mode, 1, "the legacy mode is parsed")
H.num(legacyApp.state.cfg.low, 2, "legacy files get the default low")
H.num(legacyApp.state.cfg.switch_to, 2, "legacy files get the default switch target")
H.eq(legacyApp.state.problem_count, 0, "legacy files have no problems")
H.eq(A.start(legacyApp), "running", "the legacy monitor starts")
H.eq(A.tick(legacyApp, 0), "none", "legacy: no alarm yet")
H.eq(A.tick(legacyApp, 300), "alarm", "legacy: the default window fires the alarm")
H.eq(readText(legacyPath), "2\n", "legacy apply keeps the bare number format")
