-- audit_server.lua -- Sentinel audit server.
-- Verifies signed audit events on channel 2, appends each accepted event to a
-- hash-chained segment log, rotates segments, archives finished ones to a
-- floppy disk and pulses the redstone swap mechanism.
-- Deploy as /system/audit_server.lua.

local M = {}

local CONFIG_PATH = "/auth/audit_config.lua"
local SHA_PATH = "/sha256.lua"
local CRYPTO_PATH = "/auth/server_crypto.lua"
local RETRY_MARKER = "/swap.retry"

-- Boot defaults. /auth/audit_config.lua overrides any of these keys.
local DEFAULTS = {
    main_channel = 2,
    protocol = "secure_auth_v5",
    main_modem_side = nil,
    heartbeat_interval = 5,
    logs_dir = "/logs",
    max_segment_lines = 500,
    local_keep_segments = 2,
    min_free_space = 8192,
    archive_retry_interval = 30,
    rate_per_sec = 5,
    nonce_window = 10000,
    dedup_window_ms = 2000,
    dedup_burst_max = 5,
    dedup_cleanup_interval = 10000,
    redstone_side = "back",
    pulse_seconds = 2,
    swap_wait_seconds = 5,
    max_consecutive_errors = 5,
    fault_flag = "/auth/audit_fault.flag",
    error_log = "/auth/audit_error.log",
    restart_delay_seconds = 3,
    swap_fault = 0,
}

-- All server state lives here; the module never touches a global.
local state = {
    cfg = nil,
    sha = nil,
    crypto = nil,
    modemSide = nil,
    hash = "GENESIS",
    segNo = 1,
    segLines = 0,
    nonces = {},
    rate = {},
    dedup = {},
    lastCleanup = 0,
    consecutive = 0,
    faulted = false,
}

----------------------------------------------------------------------------
-- generic helpers
----------------------------------------------------------------------------

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Milliseconds since the epoch; the fallback only matters on broken clocks.
local function nowMs()
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then
        return value
    end
    return math.floor(os.clock() * 1000)
end

-- UTC log stamp for an epoch-millisecond value.
local function utcStamp(ms)
    local ok, text = pcall(os.date, "!%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
    if ok and type(text) == "string" then
        return text
    end
    return "0000-00-00 00:00:00"
end

local function writeFile(path, data)
    local handle = fs.open(path, "w")
    if not handle then
        return false
    end
    handle.write(data)
    handle.close()
    return true
end

local function appendLine(path, line)
    local handle = fs.open(path, "a")
    if not handle then
        return false
    end
    handle.write(line .. "\n")
    handle.close()
    return true
end

local function readAll(path)
    if not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function lineCount(path)
    local data = readAll(path)
    if type(data) ~= "string" then
        return 0
    end
    return select(2, data:gsub("\n", ""))
end

local function ensureDir(path)
    if fs.exists(path) then
        return fs.isDir(path)
    end
    local ok = pcall(fs.makeDir, path)
    return ok and fs.isDir(path)
end

-- "Sleep forever" used by the fatal paths and by the supervisor.
local function haltForever()
    while true do
        os.sleep(3600)
    end
end

----------------------------------------------------------------------------
-- fault flag and error log
----------------------------------------------------------------------------

local function faultPath()
    if state.cfg and state.cfg.fault_flag then
        return state.cfg.fault_flag
    end
    return DEFAULTS.fault_flag
end

local function errorPath()
    if state.cfg and state.cfg.error_log then
        return state.cfg.error_log
    end
    return DEFAULTS.error_log
end

-- Format pinned by the spec: "reason: <text>" then "time: <epoch ms>".
local function writeFaultFlag(reason)
    local data = "reason: " .. reason .. "\n"
        .. "time: " .. tostring(math.floor(nowMs())) .. "\n"
    writeFile(faultPath(), data)
end

-- Unrecoverable boot misconfiguration: flag, one clear line, then stop.
local function fatal(reason)
    writeFaultFlag(reason)
    print("FATAL: " .. reason)
    haltForever()
end

-- Supervisor and runtime messages: screen plus /auth/audit_error.log.
local function logError(message)
    local line = "[" .. utcStamp(nowMs()) .. "] " .. message
    print(line)
    appendLine(errorPath(), line)
end

----------------------------------------------------------------------------
-- configuration
----------------------------------------------------------------------------

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then
        return nil, "missing " .. CONFIG_PATH
    end
    local chunk, loadErr = loadfile(CONFIG_PATH)
    if not chunk then
        return nil, "invalid config: " .. tostring(loadErr)
    end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then
        return nil, "invalid config table"
    end
    local merged = {}
    for key, value in pairs(DEFAULTS) do
        merged[key] = value
    end
    for key, value in pairs(cfg) do
        merged[key] = value
    end
    return merged
end

-- Rewrites the whole config file, sorted, with values re-serialised. This is
-- the in-place swap_fault rewrite: no other file is ever rewritten.
local function saveConfig(cfg)
    local keys = {}
    for key in pairs(cfg) do
        if type(cfg[key]) ~= "function" then
            keys[#keys + 1] = tostring(key)
        end
    end
    table.sort(keys)
    local out = {
        "-- audit_config.lua -- Sentinel audit server configuration.",
        "-- Deploy as /auth/audit_config.lua. Rewritten in place by the",
        "-- server when the redstone swap mechanism faults or recovers.",
        "return {",
    }
    for _, key in ipairs(keys) do
        out[#out + 1] = "    " .. key .. " = "
            .. textutils.serialize(cfg[key]) .. ","
    end
    out[#out + 1] = "}"
    out[#out + 1] = ""
    return writeFile(CONFIG_PATH, table.concat(out, "\n"))
end

local function setSwapFault(value)
    if not state.cfg then
        return
    end
    state.cfg.swap_fault = value
    if not saveConfig(state.cfg) then
        logError("cannot rewrite " .. CONFIG_PATH)
    end
end

----------------------------------------------------------------------------
-- segment logs and hash chain
----------------------------------------------------------------------------

local function segmentName(number)
    return string.format("seg_%04d.log", number)
end

local function segmentPath(number)
    return state.cfg.logs_dir .. "/" .. segmentName(number)
end

local function listSegments()
    local result = {}
    if not fs.exists(state.cfg.logs_dir) then
        return result
    end
    for _, name in ipairs(fs.list(state.cfg.logs_dir)) do
        local digits = name:match("^seg_(%d+)%.log$")
        if digits then
            result[#result + 1] = { number = tonumber(digits), name = name }
        end
    end
    table.sort(result, function(a, b) return a.number < b.number end)
    return result
end

local function readChainState()
    local data = readAll(state.cfg.logs_dir .. "/chain.state")
    if type(data) ~= "string" then
        return "GENESIS"
    end
    data = trim(data)
    if #data == 64 and data:match("^[0-9a-fA-F]+$") then
        return data:lower()
    end
    return "GENESIS"
end

local function writeChainState(hash)
    return writeFile(state.cfg.logs_dir .. "/chain.state", hash)
end

-- Top screen line after every write: "seg_NNNN  hash=<first 12 hex>".
local function showStatus()
    if type(term) ~= "table" or type(term.write) ~= "function" then
        return
    end
    local label = "seg_" .. string.format("%04d", state.segNo)
        .. "  hash=" .. state.hash:sub(1, 12)
    pcall(function()
        term.setCursorPos(1, 1)
        term.clearLine()
        term.write(label)
    end)
end

local function initLogs()
    state.hash = readChainState()
    local segments = listSegments()
    if #segments == 0 then
        state.segNo = 1
        state.segLines = 0
        writeFile(segmentPath(1), "")
    else
        local last = segments[#segments]
        state.segNo = last.number
        state.segLines = lineCount(state.cfg.logs_dir .. "/" .. last.name)
    end
end

-- Appends one chained line for an already-built body prefix.
local function appendBody(body)
    if state.segLines >= state.cfg.max_segment_lines then
        state.segNo = state.segNo + 1
        state.segLines = 0
        writeFile(segmentPath(state.segNo), "")
    end
    local hash = state.sha.hash(state.hash .. "|" .. body)
    local line = body .. " PREV=" .. state.hash .. " HASH=" .. hash
    if not appendLine(segmentPath(state.segNo), line) then
        error("cannot write " .. segmentPath(state.segNo))
    end
    state.segLines = state.segLines + 1
    state.hash = hash
    writeChainState(hash)
    showStatus()
    return hash
end

----------------------------------------------------------------------------
-- peripheral helpers
----------------------------------------------------------------------------

local function loadModule(path)
    local ok, module = pcall(dofile, path)
    if not ok or type(module) ~= "table" then
        return nil
    end
    return module
end

local function listPeripheralNames()
    if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
        return {}
    end
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then
        return {}
    end
    return names
end

local function peripheralType(name)
    if type(peripheral) ~= "table" then
        return nil
    end
    if type(peripheral.getType) == "function" then
        local ok, kind = pcall(peripheral.getType, name)
        if ok then
            return kind
        end
        return nil
    end
    if type(peripheral.call) == "function" then
        local ok, kind = pcall(peripheral.call, name, "getType")
        if ok then
            return kind
        end
    end
    return nil
end

local function transmit(side, channel, replyChannel, message)
    if side == nil then
        return false, "no modem side"
    end
    if type(peripheral.call) ~= "function" then
        return false, "no peripheral API"
    end
    local ok, err = pcall(peripheral.call, side, "transmit", channel,
        replyChannel, message)
    if not ok then
        return false, tostring(err)
    end
    return true
end

local function isWiredModem(name)
    if peripheralType(name) ~= "modem" then
        return false
    end
    local ok, wireless = pcall(peripheral.call, name, "isWireless")
    return ok and wireless == false
end

-- nil => automatic: first wired modem by sorted name. A configured side that
-- is missing or only wireless counts as "no wired modem" (never guessed).
local function findWiredModem(cfg)
    local names = listPeripheralNames()
    table.sort(names)
    local wired = {}
    for _, name in ipairs(names) do
        if isWiredModem(name) then
            wired[#wired + 1] = name
        end
    end
    if cfg.main_modem_side ~= nil then
        for _, name in ipairs(wired) do
            if name == cfg.main_modem_side then
                return name
            end
        end
        return nil
    end
    return wired[1]
end

local function findDrive()
    local names = listPeripheralNames()
    table.sort(names)
    for _, name in ipairs(names) do
        if peripheralType(name) == "drive" then
            return name
        end
    end
    return nil
end

-- Disk snapshot used to decide whether the swap mechanism actually moved a
-- disk: "no-drive" / "empty" / "id:<diskID>" / "unknown".
local function diskSnapshot()
    local driveName = findDrive()
    if not driveName then
        return "no-drive"
    end
    local ok, id = pcall(peripheral.call, driveName, "getDiskID")
    if not ok then
        return "unknown"
    end
    if id == nil or id == false then
        return "empty"
    end
    return "id:" .. tostring(id)
end

local function setSignal(level)
    if type(redstone) ~= "table" or type(redstone.setOutput) ~= "function" then
        return false
    end
    return pcall(redstone.setOutput, state.cfg.redstone_side, level)
end

----------------------------------------------------------------------------
-- redstone swap
----------------------------------------------------------------------------

-- One pulse. Returns false without pulsing when there is no drive at all.
local function pulseOnce()
    local before = diskSnapshot()
    if before == "no-drive" then
        return false, "no drive"
    end
    if not setSignal(1) then
        return false, "redstone unavailable"
    end
    os.sleep(state.cfg.pulse_seconds)
    setSignal(0)
    os.sleep(state.cfg.swap_wait_seconds)
    local after = diskSnapshot()
    if after ~= before then
        return true, after
    end
    return false, "disk did not change"
end

-- One attempt, plus at most one automatic retry gated by /swap.retry: the
-- marker records that the retry was already granted.
local function attemptSwap(allowRetry)
    if diskSnapshot() == "no-drive" then
        return false, "no drive"
    end
    local ok, reason = pulseOnce()
    if not ok and allowRetry and not fs.exists(RETRY_MARKER) then
        writeFile(RETRY_MARKER, "retry granted\n")
        ok, reason = pulseOnce()
    end
    return ok, reason
end

-- Full swap flow used by the archive loop: success clears swap_fault and the
-- retry marker, failure raises signal 2 and writes swap_fault = 1.
function M.swap()
    local ok, reason = attemptSwap(true)
    if ok then
        setSwapFault(0)
        if fs.exists(RETRY_MARKER) then
            pcall(fs.delete, RETRY_MARKER)
        end
    else
        setSwapFault(1)
        setSignal(2)
    end
    return ok, reason
end

----------------------------------------------------------------------------
-- archive
----------------------------------------------------------------------------

-- First /disk* mount with at least min_free_space bytes free.
local function findDiskMount()
    local names = fs.list("/")
    local mounts = {}
    for _, name in ipairs(names) do
        if name:match("^disk") then
            local path = "/" .. name
            if fs.isDir(path) then
                mounts[#mounts + 1] = path
            end
        end
    end
    table.sort(mounts)
    for _, path in ipairs(mounts) do
        local ok, free = pcall(fs.getFreeSpace, path)
        if ok and type(free) == "number" and free >= state.cfg.min_free_space then
            return path
        end
    end
    return nil
end

-- Copy, verify by size, and only then allow the caller to delete the source.
local function copyFile(source, target)
    local data = readAll(source)
    if type(data) ~= "string" then
        return false
    end
    if not writeFile(target, data) then
        return false
    end
    local sourceSize = fs.getSize(source)
    local targetSize = fs.getSize(target)
    if sourceSize ~= nil and sourceSize == targetSize then
        return true
    end
    pcall(fs.delete, target)
    return false
end

-- Copies every segment except the newest local_keep_segments ones to disk.
local function archiveOnce()
    local segments = listSegments()
    local keep = state.cfg.local_keep_segments
    if keep < 0 then
        keep = 0
    end
    if #segments <= keep then
        return 0
    end
    local mount = findDiskMount()
    if not mount then
        return 0, "no archive disk"
    end
    local moved = 0
    for index = 1, #segments - keep do
        local segment = segments[index]
        local source = state.cfg.logs_dir .. "/" .. segment.name
        local target = mount .. "/" .. segment.name
        if fs.exists(source) and copyFile(source, target) then
            pcall(fs.delete, source)
            moved = moved + 1
        end
    end
    return moved
end

-- One archive iteration: archive, and pulse the swap when files moved.
function M.archiveTick()
    local moved = archiveOnce()
    if moved > 0 then
        M.swap()
    end
    return moved
end

-- Copying half of one iteration (used by tests and diagnostics).
function M.archiveOnce()
    return archiveOnce()
end

----------------------------------------------------------------------------
-- event pipeline
----------------------------------------------------------------------------

local function nonceSeen(terminalId, nonce)
    local entry = state.nonces[terminalId]
    if not entry then
        return false
    end
    return entry.map[nonce] ~= nil
end

-- Bounded per-terminal nonce memory: over nonce_window entries, sort by time
-- and drop the oldest half.
local function nonceRecord(terminalId, nonce, now)
    local entry = state.nonces[terminalId]
    if not entry then
        entry = { map = {}, list = {} }
        state.nonces[terminalId] = entry
    end
    if entry.map[nonce] then
        return
    end
    entry.map[nonce] = now
    entry.list[#entry.list + 1] = { nonce = nonce, time = now }
    local window = state.cfg.nonce_window
    if window < 0 then
        window = 0
    end
    if #entry.list > window then
        table.sort(entry.list, function(a, b) return a.time < b.time end)
        local keep = {}
        local map = {}
        local first = math.floor(#entry.list / 2) + 1
        for index = first, #entry.list do
            keep[#keep + 1] = entry.list[index]
            map[entry.list[index].nonce] = entry.list[index].time
        end
        entry.list = keep
        entry.map = map
    end
end

-- Fixed one-second window per terminal.
local function rateAllow(terminalId, now)
    local entry = state.rate[terminalId]
    if not entry or now - entry.windowStart >= 1000
        or now < entry.windowStart then
        state.rate[terminalId] = { windowStart = now, count = 1 }
        return true
    end
    if entry.count >= state.cfg.rate_per_sec then
        return false
    end
    entry.count = entry.count + 1
    return true
end

local function dedupKey(terminalId, username, action)
    return terminalId .. "|" .. username .. "|" .. action
end

-- at most dedup_burst_max identical (terminal, user, action) events inside
-- dedup_window_ms; old entries are swept once per dedup_cleanup_interval.
local function dedupAllow(key, now)
    if now - state.lastCleanup >= state.cfg.dedup_cleanup_interval
        or now < state.lastCleanup then
        state.lastCleanup = now
        local horizon = now - 2 * state.cfg.dedup_window_ms
        for existing, entry in pairs(state.dedup) do
            if entry.first < horizon then
                state.dedup[existing] = nil
            end
        end
    end
    local entry = state.dedup[key]
    if not entry or now - entry.first > state.cfg.dedup_window_ms
        or now < entry.first then
        state.dedup[key] = { first = now, count = 1 }
        return true
    end
    if entry.count >= state.cfg.dedup_burst_max then
        return false
    end
    entry.count = entry.count + 1
    return true
end

local function cleanField(value)
    return (value:gsub("[\r\n]", " "))
end

-- The ack is signed with the terminal's own key, string nonce|terminal.
local function sendAck(terminalId, nonce)
    local sig = state.crypto.sign(terminalId, nonce .. "|" .. terminalId)
    if type(sig) ~= "string" then
        return
    end
    transmit(state.modemSide, state.cfg.main_channel, state.cfg.main_channel, {
        protocol = state.cfg.protocol,
        type = "audit_ack",
        terminal_id = terminalId,
        nonce = nonce,
        sig = sig,
    })
end

-- The whole accept pipeline. Returns true when the event is logged or when an
-- already-accepted duplicate gets its ack repeated, or false plus an internal
-- reason. The reason is never transmitted: audit-side rejections are silent.
function M.handleEvent(channel, message)
    local cfg = state.cfg
    if not cfg or not state.sha or not state.crypto then
        return false, "not booted"
    end
    if channel ~= cfg.main_channel then
        return false, "channel"
    end
    if type(message) ~= "table" then
        return false, "malformed"
    end
    if message.protocol ~= cfg.protocol then
        return false, "protocol"
    end
    if message.type ~= "audit_event" then
        return false, "type"
    end

    local terminalId = message.terminal_id
    local username = message.username
    local role = message.role
    local action = message.action
    local nonce = message.nonce
    local stamp = message.timestamp
    if type(stamp) == "number" then
        stamp = tostring(stamp)
    end
    if type(terminalId) ~= "string" or type(username) ~= "string"
        or type(role) ~= "string"
        or type(action) ~= "string" or type(nonce) ~= "string"
        or type(stamp) ~= "string" then
        return false, "malformed"
    end
    local timestampMs = tonumber(stamp)
    if not timestampMs or timestampMs < 0 then
        return false, "malformed"
    end

    -- Signature first: sha256(key .. "|" .. data) is checked by the crypto
    -- module, which owns the terminal key store.
    local data = terminalId .. "|" .. username .. "|" .. role .. "|"
        .. action .. "|" .. stamp .. "|" .. nonce
    local ok, valid = pcall(state.crypto.verify, terminalId, data, message.sig)
    if not ok or valid ~= true then
        return false, "signature"
    end

    -- A duplicate with a valid signature whose nonce is still in the window
    -- was accepted before: answer it with the same ack and log nothing, so a
    -- lost ack cannot make the terminal resend forever. A duplicate that does
    -- not verify never reaches this branch (it stays silent).
    local now = nowMs()
    if nonceSeen(terminalId, nonce) then
        sendAck(terminalId, nonce)
        return true, "replay-acked"
    end
    if not rateAllow(terminalId, now) then
        return false, "rate"
    end
    if not dedupAllow(dedupKey(terminalId, username, action), now) then
        return false, "dedup"
    end

    local body = "[" .. utcStamp(timestampMs) .. "] TERMINAL="
        .. cleanField(terminalId) .. " USER=" .. cleanField(username)
        .. " ROLE=" .. cleanField(role) .. " ACTION=" .. cleanField(action)
    appendBody(body)
    nonceRecord(terminalId, nonce, now)
    sendAck(terminalId, nonce)
    return true
end

----------------------------------------------------------------------------
-- supervision and the three loops
----------------------------------------------------------------------------

function M.heartbeatTick()
    local sent, err = transmit(state.modemSide, state.cfg.main_channel,
        state.cfg.main_channel, {
            protocol = state.cfg.protocol,
            type = "audit_heartbeat",
        })
    if not sent then
        error("modem transmit failed: " .. tostring(err))
    end
end

local function heartbeatLoop(iterOk)
    while true do
        if state.faulted then
            haltForever()
        end
        M.heartbeatTick()
        iterOk()
        os.sleep(state.cfg.heartbeat_interval)
    end
end

local function archiveLoop(iterOk)
    while true do
        if state.faulted then
            haltForever()
        end
        M.archiveTick()
        iterOk()
        os.sleep(state.cfg.archive_retry_interval)
    end
end

local function listenLoop(iterOk)
    while true do
        if state.faulted then
            haltForever()
        end
        local _, side, channel, _, message = os.pullEvent("modem_message")
        if state.faulted then
            haltForever()
        end
        M.handleEvent(channel, message)
        iterOk()
    end
end

-- Runs one loop body forever. A returned body logs "exited; restarting"; an
-- error counts against max_consecutive_errors, and the counter is reset by
-- any successful iteration (iterOk) so lifetime errors cannot fault us.
function M.supervise(name, fn)
    local function markOk()
        state.consecutive = 0
    end
    while true do
        if state.faulted then
            haltForever()
        end
        local ok, err = pcall(fn, markOk)
        if ok then
            logError(name .. " exited; restarting")
        else
            state.consecutive = state.consecutive + 1
            logError(name .. " error: " .. tostring(err))
            if state.consecutive >= state.cfg.max_consecutive_errors then
                state.faulted = true
                writeFaultFlag(name .. " error: " .. tostring(err))
                setSignal(2)
                haltForever()
            end
        end
        os.sleep(state.cfg.restart_delay_seconds)
    end
end

----------------------------------------------------------------------------
-- boot
----------------------------------------------------------------------------

local function recoverySwap()
    print("SWAP FAULT DETECTED ON BOOT")
    print("Attempting recovery swap...")
    local ok = attemptSwap(false)
    local refreshed = loadConfig()
    if refreshed then
        state.cfg = refreshed
    end
    if ok then
        if fs.exists(RETRY_MARKER) then
            pcall(fs.delete, RETRY_MARKER)
        end
        setSwapFault(0)
        print("RECOVERY SUCCESSFUL")
        print("swap_fault reset to 0.")
    else
        print("RECOVERY FAILED")
        print("Server will run in fault mode.")
        print("Set swap_fault = 0 in /auth/audit_config.lua to clear.")
        -- A failed recovery leaves the machine in fault mode: raise the same
        -- lamp as the normal failure path, whatever the reason was.
        setSignal(2)
    end
end

function M.boot()
    state.cfg = nil
    state.sha = nil
    state.crypto = nil
    state.modemSide = nil
    state.hash = "GENESIS"
    state.segNo = 1
    state.segLines = 0
    state.nonces = {}
    state.rate = {}
    state.dedup = {}
    state.lastCleanup = 0
    state.consecutive = 0
    state.faulted = false

    local cfg = loadConfig()
    if not cfg then
        writeFile(DEFAULTS.fault_flag, "reason: invalid config\n"
            .. "time: " .. tostring(math.floor(nowMs())) .. "\n")
        print("FATAL: cannot load " .. CONFIG_PATH)
        haltForever()
    end
    state.cfg = cfg

    print("Audit Server")
    print("Channel: " .. tostring(cfg.main_channel))
    print("Logs:    " .. tostring(cfg.logs_dir))

    local sha = loadModule(SHA_PATH)
    if not sha or type(sha.hash) ~= "function" then
        fatal("cannot load " .. SHA_PATH)
    end
    state.sha = sha

    local crypto = loadModule(CRYPTO_PATH)
    if not crypto or type(crypto.verify) ~= "function"
        or type(crypto.sign) ~= "function" then
        fatal("cannot load " .. CRYPTO_PATH)
    end
    state.crypto = crypto

    if not ensureDir(cfg.logs_dir) then
        fatal("cannot create " .. tostring(cfg.logs_dir))
    end
    initLogs()

    local modemSide = findWiredModem(cfg)
    if not modemSide then
        fatal("no wired modem")
    end
    local opened = pcall(peripheral.call, modemSide, "open", cfg.main_channel)
    if not opened then
        fatal("no wired modem")
    end
    state.modemSide = modemSide

    if cfg.swap_fault == 1 then
        recoverySwap()
    end

    print("Ready.")
    return true
end

function M.main()
    M.boot()
    parallel.waitForAny(
        function() M.supervise("heartbeat", heartbeatLoop) end,
        function() M.supervise("archive", archiveLoop) end,
        function() M.supervise("listen", listenLoop) end
    )
end

function M.snapshot()
    return diskSnapshot()
end

function M.status()
    return {
        hash = state.hash,
        segment = state.segNo,
        segment_name = segmentName(state.segNo),
        consecutive_errors = state.consecutive,
        faulted = state.faulted,
        modem_side = state.modemSide,
    }
end

return M
