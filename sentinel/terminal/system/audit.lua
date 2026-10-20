-- Sentinel terminal side of the audit trail.
-- Deploy: /system/audit.lua
--
-- Client mode: every event is signed and serialised to
-- /audit_queue/<nonce>.evt, then retransmitted every RESEND_INTERVAL seconds
-- until a valid audit_ack for that nonce arrives. An event that cannot be
-- signed is never queued (it could never be accepted).
-- Standalone mode: there is no audit server and no PSK; log() is a no-op.

local M = {}

local PROTOCOL = "secure_auth_v4"
local AUDIT_CHANNEL = 2
local RESEND_INTERVAL = 10
local QUEUE_DIR = "/audit_queue"

local function currentMode()
    local ok, config = pcall(dofile, "/auth/mode.lua")
    if ok and type(config) == "table" then
        return config.mode or "client"
    end
    return "client"
end

local mode = currentMode()

-- The PSK module (and its file) only exists on client terminals, so it is
-- loaded on first use and never required in standalone mode.
local pskModule = nil
local pskTried = false

local function getPsk()
    if pskTried then return pskModule end
    pskTried = true
    local ok, module = pcall(dofile, "/auth/psk.lua")
    if ok and type(module) == "table" then
        pskModule = module
    end
    return pskModule
end

local function readTerminalId()
    if fs.exists("/auth/terminal_id.txt") then
        local handle = fs.open("/auth/terminal_id.txt", "r")
        if handle then
            local raw = handle.readAll()
            handle.close()
            local id = raw:gsub("%s+", "")
            if id ~= "" then return id end
        end
    end
    local label = os.getComputerLabel()
    if type(label) == "string" and label ~= "" then return label end
    return "computer_" .. tostring(os.getComputerID())
end

local function modemNames()
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then return names end
    return {}
end

-- Returns a wired modem name, or nil plus "no modem" / "wireless modem".
local function findModem()
    local found = nil
    local sawModem = false
    for _, name in ipairs(modemNames()) do
        local ok, kind = pcall(peripheral.getType, name)
        if ok and kind == "modem" then
            sawModem = true
            local wok, wireless = pcall(peripheral.call, name, "isWireless")
            if not (wok and wireless) and not found then
                found = name
            end
        end
    end
    if found then return found end
    if sawModem then return nil, "wireless modem" end
    return nil, "no modem"
end

local function ensureQueueDir()
    if not fs.exists(QUEUE_DIR) then
        pcall(fs.makeDir, QUEUE_DIR)
    end
end

local function queuePath(nonce)
    return QUEUE_DIR .. "/" .. nonce .. ".evt"
end

local function transmit(modem, event)
    return pcall(peripheral.call, modem, "transmit", AUDIT_CHANNEL, 0, event)
end

function M.log(username, action)
    if mode == "standalone" then return true end

    -- A missing PSK makes the event unverifiable, so it must not be queued.
    local psk = getPsk()
    if not psk then return false end
    local okKey = pcall(psk.get)
    if not okKey then return false end

    local terminalId = readTerminalId()
    local timestamp = tostring(os.epoch("utc"))
    local nonce = tostring(math.random()) .. timestamp
    local signed = terminalId .. "|" .. tostring(username) .. "|" .. tostring(action)
        .. "|" .. timestamp .. "|" .. nonce

    local okSign, sig = pcall(psk.sign, signed)
    if not okSign then return false end

    local event = {
        protocol = PROTOCOL,
        type = "audit_event",
        terminal_id = terminalId,
        username = username,
        action = action,
        timestamp = timestamp,
        nonce = nonce,
        sig = sig,
    }

    ensureQueueDir()
    local handle = fs.open(queuePath(nonce), "w")
    if not handle then return false end
    handle.write(textutils.serialize(event))
    handle.close()

    local modem = findModem()
    if modem then
        transmit(modem, event)
    end
    return true
end

local function queueFiles()
    local files = {}
    if not fs.exists(QUEUE_DIR) then return files end
    local ok, listing = pcall(fs.list, QUEUE_DIR)
    if not ok or type(listing) ~= "table" then return files end
    for _, name in ipairs(listing) do
        if name:sub(-4) == ".evt" then
            files[#files + 1] = name
        end
    end
    table.sort(files)
    return files
end

local function resendOnce()
    local modem = findModem()
    if not modem then return end
    for _, name in ipairs(queueFiles()) do
        local handle = fs.open(QUEUE_DIR .. "/" .. name, "r")
        if handle then
            local raw = handle.readAll()
            handle.close()
            local ok, event = pcall(textutils.unserialize, raw)
            if ok and type(event) == "table" then
                transmit(modem, event)
            end
        end
    end
end

-- An ack is accepted only when it is addressed to this terminal and its
-- signature over "nonce|terminal_id" verifies with our own PSK.
local function onMessage(message)
    if type(message) ~= "table" then return end
    if message.protocol ~= PROTOCOL or message.type ~= "audit_ack" then return end
    local nonce = message.nonce
    if type(nonce) ~= "string" or nonce == "" then return end
    if nonce:find("/", 1, true) or nonce:find("..", 1, true) then return end

    local terminalId = readTerminalId()
    if message.terminal_id ~= terminalId then return end
    if type(message.sig) ~= "string" then return end

    local psk = getPsk()
    if not psk then return end
    local ok, valid = pcall(psk.verify, nonce .. "|" .. terminalId, message.sig)
    if not ok or not valid then return end

    local path = queuePath(nonce)
    if fs.exists(path) then
        fs.delete(path)
    end
end

local function resendLoop()
    while true do
        resendOnce()
        sleep(RESEND_INTERVAL)
    end
end

local function ackLoop()
    while true do
        local event, side, channel, senderReply, message = os.pullEvent()
        if event == "modem_message" and channel == AUDIT_CHANNEL then
            onMessage(message)
        end
    end
end

function M.start()
    if mode == "standalone" then
        return false, "standalone"
    end

    local psk = getPsk()
    if not psk then return false, "no psk" end
    local okKey = pcall(psk.get)
    if not okKey then return false, "no psk" end

    local modem, reason = findModem()
    if not modem then return false, reason end

    if not pcall(peripheral.call, modem, "open", AUDIT_CHANNEL) then
        return false, "no modem"
    end

    parallel.waitForAll(resendLoop, ackLoop)
    return false, "stopped"
end

return M
