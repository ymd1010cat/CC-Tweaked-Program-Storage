-- harness.lua -- assertions, fakes and fixtures for the itn-pass offline suite.
-- Staged as /tests/harness.lua and loaded by /tests/run.lua.
--
-- Only hardware is faked here (modem peripherals, disk drives, wall clock,
-- timers, console I/O). The modules under test are the real staged ones,
-- loaded from their deploy paths with dofile/loadfile.

local H = {}

local realPrint = print
local realEpoch = os.epoch
local realStartTimer = os.startTimer
local realPullEvent = os.pullEvent
local realSleep = os.sleep
local realDate = os.date
local realOpen = fs.open
local realFreeSpace = fs.getFreeSpace
local hadFreeSpace = realFreeSpace ~= nil
local realDisk = disk
local realPeripheral = peripheral
local realTermClear = term.clear
local realTermCursor = term.setCursorPos
-- BIOS print() calls the global write(), which the suite replaces to capture
-- module output. Test results therefore go straight to the terminal.
local realTermWrite = term.write

H.pass = 0
H.fail = 0
H.current = ""
H.groups = {}
H.groupCount = 0
H.out = {}
H.capture = false
H.inputs = {}
H.events = {}
H.timers = 0

-- Fake wall clock in milliseconds (os.epoch("utc") contract).
H.now = 1600000000000
-- Fake free space reported by fs.getFreeSpace(mount).
H.freeSpace = 1000000000
-- When set, os.date("%Y%m%d-%H%M%S") returns exactly this string.
H.stamp = nil

-- Writes one line straight to the terminal, bypassing the print/write stubs.
-- The same line is appended to /logs/suite.log: CraftOS-PC buffers redirected
-- stdout, so the log file is what the runner reads for its verdict.
function H.emit(text)
    local line = tostring(text)
    realTermWrite(line .. "\n")
    local log = fs.open("/logs/suite.log", "a")
    if log then
        log.write(line .. "\n")
        log.close()
    end
end

function H.say(text)
    H.emit(text)
end

-- A group is one module area; the count is reported as OFFLINE_GROUPS.
function H.group(name)
    if H.current ~= name then
        H.groupCount = H.groupCount + 1
        H.groups[H.groupCount] = name
        H.current = name
    end
end

function H.check(name, ok, detail)
    if ok then
        H.pass = H.pass + 1
        H.emit("TEST " .. name .. " ok=true")
    else
        H.fail = H.fail + 1
        H.emit("TEST " .. name .. " ok=false")
        H.emit("TEST_FAIL " .. name .. ": " .. tostring(detail or ""))
    end
    -- Progress marker: a hung run leaves this file pointing at the test that
    -- was executing, which is the only clue left when stdout is still buffered.
    local marker = fs.open("/logs/last_check.txt", "wb")
    if marker then
        marker.write(name .. " ok=" .. tostring(ok))
        if not ok then
            marker.write(" " .. tostring(detail or ""))
        end
        marker.close()
    end
    return ok
end

-- Runs a block whose unexpected error is reported as one failed assertion
-- named after the block, so a crash still points at a concrete test.
function H.scenario(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        H.check(name .. ".crash", false, tostring(err))
    end
    return ok
end

----------------------------------------------------------------------------
-- console capture
----------------------------------------------------------------------------

function H.captureLine(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    H.out[#H.out + 1] = table.concat(parts, "\t")
end

function H.beginCapture()
    H.out = {}
    H.capture = true
end

function H.endCapture()
    H.capture = false
    return table.concat(H.out, "\n")
end

function H.setInputs(...)
    H.inputs = {}
    local args = { ... }
    for i = 1, #args do
        H.inputs[i] = args[i]
    end
end

function H.pushEvent(...)
    if select("#", ...) == 1 and type((...)) == "table" then
        H.events[#H.events + 1] = (...)
    else
        H.events[#H.events + 1] = { ... }
    end
end

function H.clearEvents()
    H.events = {}
end

function H.setNow(ms)
    H.now = ms
end

function H.advance(ms)
    H.now = H.now + ms
end

function H.setFreeSpace(bytes)
    H.freeSpace = bytes
end

----------------------------------------------------------------------------
-- global stub installation
----------------------------------------------------------------------------

function H.install()
    os.epoch = function()
        return H.now
    end
    os.startTimer = function(seconds)
        H.timers = H.timers + 1
        return H.timers
    end
    os.pullEvent = function()
        local ev = table.remove(H.events, 1)
        if ev then
            return ev[1], ev[2], ev[3], ev[4], ev[5]
        end
        -- No queued event means "the peer never answered": hand back the last
        -- armed timer, which is the timeout path every module expects.
        return "timer", H.timers
    end
    os.sleep = function() end
    os.date = function(fmt, t)
        if H.stamp ~= nil and fmt == "%Y%m%d-%H%M%S" then
            return H.stamp
        end
        return realDate(fmt, t)
    end
    print = function(...)
        if not H.capture then
            return realPrint(...)
        end
        H.captureLine(...)
        -- bios.print() sums the value write() returns, so never return nil.
        return 1
    end
    write = function(...)
        H.captureLine(...)
        return 1
    end
    read = function()
        return table.remove(H.inputs, 1)
    end
    fs.getFreeSpace = function(path)
        return H.freeSpace
    end
    term.clear = function() end
    term.setCursorPos = function() end
end

-- Puts every stubbed global back; used between groups so one module's fakes
-- cannot leak into the next.
function H.resetStubs()
    H.clearEvents()
    H.inputs = {}
    H.out = {}
    H.capture = false
    H.stamp = nil
    H.freeSpace = 1000000000
    fs.open = realOpen
    disk = realDisk
    peripheral = realPeripheral
end

function H.restore()
    H.resetStubs()
    os.epoch = realEpoch
    os.startTimer = realStartTimer
    os.pullEvent = realPullEvent
    os.sleep = realSleep
    os.date = realDate
    if hadFreeSpace then
        fs.getFreeSpace = realFreeSpace
    else
        fs.getFreeSpace = nil
    end
    term.clear = realTermClear
    term.setCursorPos = realTermCursor
end

----------------------------------------------------------------------------
-- peripheral fake (modems and disk drives live here)
----------------------------------------------------------------------------

-- spec fields:
--   names          list returned by peripheral.getNames()
--   types          name -> "modem" / "drive"
--   wireless       name -> true for wireless modems
--   remotes        name -> list of remote peripheral names
--   remotesError   name -> true makes getNamesRemote() raise
--   openError      open() raises
--   transmitError  transmit() raises
--   onTransmit     function(H, name, channel, replyChannel, message)
function H.installPeripheral(spec)
    spec = spec or {}
    local types = spec.types or {}
    local wireless = spec.wireless or {}
    local remotes = spec.remotes or {}
    local rec = { sent = {}, opens = 0, closes = 0, names = spec.names or {} }

    local api = {}
    api.getNames = function()
        return rec.names
    end
    api.hasType = function(name, kind)
        return types[name] == kind
    end
    api.getType = function(name)
        return types[name]
    end
    api.isPresent = function(name)
        return types[name] ~= nil
    end
    api.wrap = function(name)
        return api
    end
    api.call = function(name, method, ...)
        if method == "isWireless" then
            return wireless[name] == true
        end
        if method == "getNamesRemote" then
            if spec.remotesError and spec.remotesError[name] then
                error("no remote network")
            end
            return remotes[name] or {}
        end
        if method == "open" then
            if spec.openError then
                error("peripheral detached")
            end
            rec.opens = rec.opens + 1
            return true
        end
        if method == "close" then
            rec.closes = rec.closes + 1
            return true
        end
        if method == "transmit" then
            if spec.transmitError then
                error("modem gone")
            end
            local channel, replyChannel, message = ...
            rec.sent[#rec.sent + 1] = {
                name = name,
                channel = channel,
                replyChannel = replyChannel,
                message = message,
            }
            if spec.onTransmit then
                spec.onTransmit(H, name, channel, replyChannel, message)
            end
            return true
        end
        error("unsupported peripheral method: " .. tostring(method))
    end
    peripheral = api
    return rec
end

----------------------------------------------------------------------------
-- disk fake
----------------------------------------------------------------------------

-- cfg fields: present (function), presentDefault (bool), presentError (bool),
--             mount (function), mountPath (string), total, used.
function H.installDisk(cfg)
    cfg = cfg or {}
    local api = {}
    if cfg.presentError then
        api.isPresent = function()
            error("peripheral detached")
        end
    elseif cfg.present then
        api.isPresent = cfg.present
    else
        api.isPresent = function()
            return cfg.presentDefault == true
        end
    end
    if cfg.mount then
        api.getMountPath = cfg.mount
    else
        api.getMountPath = function()
            return cfg.mountPath
        end
    end
    if cfg.total ~= nil then
        api.getDiskSpaceTotal = function()
            return cfg.total
        end
    end
    if cfg.used ~= nil then
        api.getDiskSpaceUsed = function()
            return cfg.used
        end
    end
    disk = api
    return api
end

----------------------------------------------------------------------------
-- filesystem helpers
----------------------------------------------------------------------------

function H.readFile(path)
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "rb")
    if not f then
        return nil
    end
    local text = f.readAll()
    f.close()
    return text
end

function H.writeFile(path, text)
    local f = assert(fs.open(path, "wb"))
    f.write(text)
    f.close()
    return true
end

function H.ensureDir(path)
    if path == nil or path == "" or path == "/" then
        return true
    end
    if fs.exists(path) then
        return fs.isDir(path)
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then
        parent = "/"
    end
    if parent ~= "/" then
        H.ensureDir(parent)
    end
    pcall(fs.makeDir, path)
    return fs.exists(path)
end

function H.rmTree(path)
    if path == "/" then
        error("refusing to remove /")
    end
    if not fs.exists(path) then
        return
    end
    if fs.isDir(path) then
        for _, name in ipairs(fs.list(path)) do
            local child = (path == "/") and ("/" .. name) or (path .. "/" .. name)
            H.rmTree(child)
        end
        fs.delete(path)
    else
        fs.delete(path)
    end
end

-- Loads a module from a deploy path. Modules that boot themselves when run
-- without arguments (the server and the admin console) get a dummy argument.
function H.load(path, ...)
    local chunk = assert(loadfile(path))
    return chunk(...)
end

return H
