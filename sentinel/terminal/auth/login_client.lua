-- Sentinel client login: challenge/response over the auth modem.
-- Deploy: /auth/login_client.lua
--
-- Wire contract (secure_auth_v4):
--   H  = sha256(password .. salt)
--   H' = sha256(H .. "|" .. nonce_c .. "|" .. nonce_s)
-- Only H' crosses the wire; the password never leaves this terminal.

local sha256 = dofile("/sha256.lua")
local psk = dofile("/auth/psk.lua")
local netcheck = dofile("/system/netcheck.lua")

local M = {}

local PROTOCOL = "secure_auth_v4"
local AUTH_CHANNEL = 1
local EXCHANGE_TIMEOUT = 8
local PRECHECK_SECONDS = 2
local REPLY_MIN = 1000
local REPLY_MAX = 9999

local function loadAudit()
    local ok, module = pcall(dofile, "/system/audit.lua")
    if ok and type(module) == "table" and type(module.log) == "function" then
        return module
    end
    return { log = function() return false end }
end

local audit = loadAudit()

local function makeNonce()
    return tostring(math.random()) .. tostring(os.epoch("utc"))
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

local function findWiredModem()
    for _, name in ipairs(modemNames()) do
        local ok, kind = pcall(peripheral.getType, name)
        if ok and kind == "modem" then
            local wok, wireless = pcall(peripheral.call, name, "isWireless")
            if not (wok and wireless) then return name end
        end
    end
    return nil
end

-- Wait for a reply addressed to our own reply channel. A modem_message event
-- is (side, channel, replyChannel, message, distance): "channel" is the
-- channel the packet was sent on, which is our random reply channel. The side
-- name and the sender's reply channel say nothing about this terminal.
-- salt_response does not carry nonce_c in the spec, so the nonce check is only
-- applied when the server echoed one.
local function waitForReply(ourChannel, expectedType, terminalId, nonceC)
    local timer = os.startTimer(EXCHANGE_TIMEOUT)
    while true do
        local event, side, channel, senderReply, message = os.pullEvent()
        if event == "timer" and (side == timer or senderReply == timer) then
            return nil
        elseif event == "modem_message" and channel == ourChannel
            and type(message) == "table" then
            if message.protocol == PROTOCOL
                and message.type == expectedType
                and message.terminal_id == terminalId
                and (message.nonce_c == nil or message.nonce_c == nonceC) then
                return message
            end
        end
    end
end

-- Returns salt, nonceS, nonceC or nil plus an error code and detail.
local function requestSalt(modem, ourChannel, terminalId, username)
    local nonceC = makeNonce()
    local okSign, sig = pcall(psk.sign, terminalId .. "|" .. username .. "|" .. nonceC)
    if not okSign then return nil, nil, nil, "psk", tostring(sig) end

    local request = {
        protocol = PROTOCOL,
        type = "salt_request",
        terminal_id = terminalId,
        username = username,
        nonce_c = nonceC,
        sig = sig,
    }
    if not pcall(peripheral.call, modem, "transmit", AUTH_CHANNEL, ourChannel, request) then
        return nil, nil, nil, "timeout", nil
    end

    local response = waitForReply(ourChannel, "salt_response", terminalId, nonceC)
    if not response then return nil, nil, nil, "salt_timeout", nil end
    if type(response.server_id) ~= "string" or type(response.salt) ~= "string"
        or type(response.nonce_s) ~= "string" then
        return nil, nil, nil, "salt_signature", nil
    end

    local signed = response.server_id .. "|" .. username .. "|" .. response.salt
        .. "|" .. nonceC .. "|" .. response.nonce_s
    if not psk.verify(signed, response.sig) then
        return nil, nil, nil, "salt_signature", nil
    end
    return response.salt, response.nonce_s, nonceC, nil, nil
end

-- Returns ok, role, error code, detail. The auth stage uses its own fresh
-- nonce_c; the salt stage nonce was only for that exchange.
local function requestAuth(modem, ourChannel, terminalId, username, password,
    salt, nonceS)
    local nonceC = makeNonce()
    local inner = sha256.hash(password .. salt)
    local derived = sha256.hash(inner .. "|" .. nonceC .. "|" .. nonceS)
    local signedRequest = terminalId .. "|" .. username .. "|" .. derived
        .. "|" .. nonceC .. "|" .. nonceS
    local okSign, sig = pcall(psk.sign, signedRequest)
    if not okSign then return false, nil, "psk", tostring(sig) end

    local request = {
        protocol = PROTOCOL,
        type = "auth_request",
        terminal_id = terminalId,
        username = username,
        derived = derived,
        nonce_c = nonceC,
        nonce_s = nonceS,
        sig = sig,
    }
    if not pcall(peripheral.call, modem, "transmit", AUTH_CHANNEL, ourChannel, request) then
        return false, nil, "timeout", nil
    end

    local response = waitForReply(ourChannel, "auth_response", terminalId, nonceC)
    if not response then return false, nil, "timeout", nil end
    if type(response.server_id) ~= "string" or type(response.sig) ~= "string" then
        return false, nil, "signature", nil
    end

    local signed = response.server_id .. "|" .. nonceC .. "|" .. nonceS
        .. "|" .. tostring(response.success) .. "|" .. tostring(response.role or "")
    if not psk.verify(signed, response.sig) then
        return false, nil, "signature", nil
    end
    if response.success ~= true then
        return false, nil, "credentials", nil
    end
    return true, response.role or "guest", nil, nil
end

-- Full network authentication. Returns ok, role, error code, detail.
local function authenticate(username, password)
    local called, passed, ids, reason = pcall(netcheck.check, PRECHECK_SECONDS)
    if not called then
        passed = false
        reason = "check interrupted"
    end
    if not passed then
        return false, nil, "network", tostring(reason or "check interrupted")
    end

    local modem = findWiredModem()
    if not modem then return false, nil, "timeout", nil end

    local ourChannel = math.random(REPLY_MIN, REPLY_MAX)
    if not pcall(peripheral.call, modem, "open", ourChannel) then
        return false, nil, "timeout", nil
    end

    local terminalId = readTerminalId()
    local salt, nonceS, _, saltError, saltDetail =
        requestSalt(modem, ourChannel, terminalId, username)
    if not salt then
        pcall(peripheral.call, modem, "close", ourChannel)
        return false, nil, saltError, saltDetail
    end

    local ok, role, authError, authDetail =
        requestAuth(modem, ourChannel, terminalId, username, password, salt, nonceS)
    pcall(peripheral.call, modem, "close", ourChannel)
    if not ok then return false, nil, authError, authDetail end
    return true, role, nil, nil
end

local function describeError(code, detail)
    if code == "network" then
        return "[Error] network check: " .. tostring(detail)
    elseif code == "salt_timeout" then
        return "[Error] salt timeout"
    elseif code == "salt_signature" then
        return "[Error] salt signature invalid"
    elseif code == "credentials" then
        return "[Error] Invalid credentials"
    elseif code == "signature" then
        return "[Error] signature invalid"
    elseif code == "psk" then
        return "[Error] " .. tostring(detail)
    end
    return "[Error] Server timeout."
end

function M.login()
    term.clear()
    term.setCursorPos(1, 1)
    print("Secure Terminal")
    print("")
    write("Username: ")
    local username = read()
    if username == nil or username == "" then return nil end
    write("Password: ")
    local password = read("*")
    if password == nil or password == "" then return nil end

    print("Authenticating...")
    local ok, role, code, detail = authenticate(username, password)
    if ok then
        audit.log(username, "LOGIN_SUCCESS")
        return { name = username, role = role }
    end

    if code == "psk" then
        print(describeError(code, detail))
        return nil
    end
    if code == "credentials" or code == "signature" or code == "salt_signature" then
        audit.log(username, "LOGIN_FAIL")
    else
        audit.log(username, "LOGIN_FAIL_TIMEOUT")
    end
    print(describeError(code, detail))
    return nil
end

function M.verifyPassword(username, password)
    if type(username) ~= "string" or username == "" then return false end
    if type(password) ~= "string" or password == "" then return false end
    local ok = authenticate(username, password)
    return ok == true
end

return M
