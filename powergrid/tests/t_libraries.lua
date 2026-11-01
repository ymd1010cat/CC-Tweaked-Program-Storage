-- t_libraries.lua - missing library handling for startup.lua and watchdog_app.lua.
--
-- The real startup.lua program is executed with an injected require/shell/term,
-- so a missing library is simulated without deleting any file. Every case stops
-- in the missing-library guard before the menu loop, so the suite never hangs.

local H = ...

local A = H.app

local function newBsod()
    local b = { calls = {} }
    function b.show(options)
        b.calls[#b.calls + 1] = options
        return false
    end
    return b
end

local function newLogger()
    local log = { lines = {} }
    function log.write(tag, message, ...)
        local args = { ... }
        local text = tostring(message or "")
        for i = 1, #args do text = text .. tostring(args[i]) end
        log.lines[#log.lines + 1] = "[" .. tostring(tag) .. "] " .. text
        return true
    end
    function log.info(message, ...) return log.write("info", message, ...) end
    function log.warn(message, ...) return log.write("warn", message, ...) end
    function log.error(message, ...) return log.write("error", message, ...) end
    return log
end

local function countLines(rawLog, needle)
    local n = 0
    for i = 1, #rawLog.lines do
        if rawLog.lines[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function countIn(text, needle)
    local n = 0
    local pos = 1
    while true do
        local found = text:find(needle, pos, true)
        if found == nil then break end
        n = n + 1
        pos = found + #needle
    end
    return n
end

local function newTermBuffer()
    local buf = { lines = {}, text = "" }
    function buf.write(text)
        buf.text = buf.text .. tostring(text)
        buf.lines[#buf.lines + 1] = tostring(text)
        return buf
    end
    function buf.clear() buf.clears = (buf.clears or 0) + 1; return buf end
    function buf.clearLine() return buf end
    function buf.setCursorPos() return buf end
    function buf.setCursorBlink() return buf end
    function buf.setTextColor() return buf end
    function buf.setBackgroundColor() return buf end
    function buf.getSize() return 51, 19 end
    function buf.getCursorPos() return 1, 1 end
    return buf
end

-- Run /tests/startup_source.lua with the given libraries available. Returns
-- ok/err plus what the blue screen, the logger and the terminal saw.
local function runStartup(libs)
    local savedRequire = _G.require
    local savedShell = _G.shell
    local savedTerm = _G.term
    local requireCalls = {}
    _G.require = function(name)
        requireCalls[#requireCalls + 1] = name
        local mod = libs[name]
        if mod == nil then
            error("module '" .. name .. "' not found", 0)
        end
        return mod
    end
    _G.shell = { run = function() return true end }
    local buf = newTermBuffer()
    _G.term = buf
    local chunk, loadErr = loadfile("/tests/startup_source.lua")
    local ok, err
    if chunk == nil then
        ok, err = false, loadErr
    else
        ok, err = pcall(chunk)
    end
    _G.require = savedRequire
    _G.shell = savedShell
    _G.term = savedTerm
    return {
        ok = ok,
        err = H.errText(err),
        term = buf,
        requireCalls = requireCalls,
    }
end

-- Missing power.lua: blue screen that names the file and explains the effect.

H.group("libs-missing-power")
local bsodA, loggerA = newBsod(), newLogger()
local runA = runStartup({ bsod = bsodA, logger = loggerA, power = nil })
H.eq(runA.ok, false, "startup stops when power.lua is missing")
H.eq(#bsodA.calls, 1, "exactly one blue screen")
local optsA = bsodA.calls[1]
H.eq(optsA.error, "MISSING_LIBRARY", "the blue screen code is MISSING_LIBRARY")
H.eq(optsA.title, "Missing library", "the blue screen title is readable")
H.eq(optsA.file, "power", "the blue screen names the missing file")
H.contains(optsA.extra, "MISSING_LIBRARY name=power", "the extra carries the token")
H.contains(optsA.extra, "power.lua is not in /", "the extra names power.lua")
H.contains(optsA.extra, "cannot be read or written",
    "the extra explains that the mode is unusable")
H.contains(optsA.extra, "Put power.lua back in / and restart.",
    "the extra says what to do")
H.eq(countLines(loggerA, "MISSING_LIBRARY name=power"), 1,
    "the logger also records the missing library")
H.contains(runA.err, "MISSING_LIBRARY power", "the raised error is greppable")
H.lacks(runA.err, "module 'power' not found", "no bare require error escapes")

-- Missing logger.lua: the blue screen still works, no second crash.

H.group("libs-missing-logger")
local bsodB = newBsod()
local runB = runStartup({ bsod = bsodB, logger = nil, power = {} })
H.eq(runB.ok, false, "startup stops when logger.lua is missing")
H.eq(#bsodB.calls, 1, "the blue screen is still shown")
H.eq(bsodB.calls[1].file, "logger", "the blue screen names logger")
H.contains(bsodB.calls[1].extra, "MISSING_LIBRARY name=logger",
    "the extra carries the token")
H.contains(bsodB.calls[1].extra, "logger.lua is not in /", "the extra names logger.lua")
H.contains(runB.err, "MISSING_LIBRARY logger", "the raised error is greppable")
H.lacks(runB.err, "attempt to", "the missing logger cannot cause a second crash")
H.lacks(runB.err, "module 'logger' not found", "no bare require error escapes")

-- Missing bsod.lua: readable terminal fallback, never a bare module error.

H.group("libs-missing-bsod")
local loggerC = newLogger()
local runC = runStartup({ bsod = nil, logger = loggerC, power = {} })
H.eq(runC.ok, false, "startup stops when bsod.lua is missing")
H.contains(runC.err, "MISSING_LIBRARY bsod", "the raised error carries the token")
H.lacks(runC.err, "module 'bsod' not found",
    "the bare module error is not the message")
H.contains(runC.term.text, "Missing library", "the fallback prints a readable title")
H.contains(runC.term.text, "MISSING_LIBRARY name=bsod",
    "the fallback prints the missing token")
H.contains(runC.term.text, "Put the missing file(s) back in / and restart.",
    "the fallback says what to do")
H.eq(countLines(loggerC, "MISSING_LIBRARY name=bsod"), 1,
    "an available logger still records the missing library")

-- Several libraries missing: one screen lists them all.

H.group("libs-multiple")
local bsodD = newBsod()
local runD = runStartup({ bsod = bsodD, logger = nil, power = nil })
H.eq(#bsodD.calls, 1, "one blue screen lists every missing library")
H.eq(bsodD.calls[1].file, "logger, power", "the file field lists both")
H.contains(bsodD.calls[1].extra, "MISSING_LIBRARY name=logger", "logger is listed")
H.contains(bsodD.calls[1].extra, "MISSING_LIBRARY name=power", "power is listed")
H.contains(bsodD.calls[1].extra, "Put these files back in / and restart.",
    "one instruction covers all of them")
H.contains(runD.err, "MISSING_LIBRARY logger, power",
    "the raised error lists both libraries")

H.group("libs-all-missing")
local runE = runStartup({ bsod = nil, logger = nil, power = nil })
H.contains(runE.err, "MISSING_LIBRARY bsod, logger, power",
    "the fallback names all three libraries")
H.contains(runE.term.text, "MISSING_LIBRARY name=bsod", "the terminal lists bsod")
H.contains(runE.term.text, "MISSING_LIBRARY name=logger", "the terminal lists logger")
H.contains(runE.term.text, "MISSING_LIBRARY name=power", "the terminal lists power")
H.lacks(runE.err, "module 'bsod' not found", "still no bare module error")

-- Source pinning.

H.group("libs-source")
local src = H.readAll("/tests/startup_source.lua") or ""
H.contains(src, "MISSING_LIBRARY", "startup has the missing-library token")
H.contains(src, "loadLibrary", "startup loads libraries through the helper")
H.lacks(src, 'local bsod = require("bsod")', "no bare require for bsod")
H.lacks(src, 'local logger = require("logger")', "no bare require for logger")
H.lacks(src, 'local power_api = require("power")', "no bare require for power")
H.eq(countIn(src, "bsod.show("), 2,
    "two blue screens: missing libraries and a write failure")
H.eq(countIn(src, "MISSING_LIBRARY name="), 2,
    "the per-library token is built in the guard and in the log loop")

-- Watchdog degradation.

H.group("watchdog-missing-libs")
local logP = newLogger()
local appP = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10 },
    redstone = { setOutput = function() return true end },
    logger = logP,
    clock = function() return 0 end,
    read = function() return 15 end,
    power = false,
    watchdog = H.watchdog,
})
H.eq(appP.power_fallback, true, "the app records the power fallback")
H.eq(appP.logger_fallback, false, "an injected logger is not a fallback")
H.eq(A.start(appP), "running", "a missing power module still starts")
H.eq(countLines(logP, "MISSING_LIBRARY name=power fallback=alarm_only"), 1,
    "the power degradation is logged")
H.eq(countLines(logP, "WATCHDOG_SWITCH_FAIL"), 0,
    "no switch failure is logged before any alarm")

local savedTerm = _G.term
local bufL = newTermBuffer()
_G.term = bufL
local appL = A.new({
    config = { low = 2, high = 10, window = 10, poll = 10 },
    redstone = { setOutput = function() return true end },
    logger = false,
    clock = function() return 0 end,
    read = function() return 15 end,
    power = false,
    watchdog = H.watchdog,
})
local startMode = A.start(appL)
_G.term = savedTerm

H.eq(startMode, "running", "a missing logger still starts")
H.eq(appL.logger_fallback, true, "the app records the logger fallback")
H.eq(appL.logger, A.PRINT_LOGGER, "the built-in printer took over")
H.contains(bufL.text, "MISSING_LIBRARY name=logger fallback=print",
    "the logger degradation is printed")
H.contains(bufL.text, "MISSING_LIBRARY name=power fallback=alarm_only",
    "the power degradation is printed too")
H.contains(bufL.text, "WATCHDOG_START", "the start line is still printable")
H.contains(bufL.text, "[info]", "the fallback keeps the logger tag shape")
