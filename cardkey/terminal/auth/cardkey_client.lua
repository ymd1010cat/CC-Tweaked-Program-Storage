-- CardKey terminal protocol client (cardkey_v1).
-- Deploy path: /auth/cardkey_client.lua
-- The terminal has no key material and no card key database: this module only
-- forwards a typed code to the card key server and reports what came back.

local netcheck = dofile("/system/netcheck.lua")

local M = {}

local CHANNEL = 3
local PROTOCOL = "cardkey_v1"
local VERIFY_TIMEOUT = 8
local WRITE_TIMEOUT = 30

-- Server ids learned by netcheck, cached per client object. The set is only
-- refreshed after a failed exchange (see DECISIONS.md), never per request.
local knownServers = nil

local function trimCode(code)
    if type(code) ~= "string" then
        return ""
    end
    local trimmed = string.match(code, "^%s*(.-)%s*$")
    return trimmed or ""
end

local function peripheralNames()
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then
        return names
    end
    return {}
end

local function isModem(name)
    local ok, yes = pcall(peripheral.hasType, name, "modem")
    if ok then
        return yes == true
    end
    local okType, kind = pcall(peripheral.getType, name)
    return okType and kind == "modem"
end

local function isWireless(name)
    local ok, yes = pcall(peripheral.call, name, "isWireless")
    return ok and yes == true
end

-- Returns (modemName) for the wired modem to transmit on, else (nil, reason).
local function findWiredModem()
    local names = peripheralNames()
    local sawModem = false
    for i = 1, #names do
        local name = names[i]
        if isModem(name) then
            sawModem = true
            if not isWireless(name) then
                return name, nil
            end
        end
    end
    if sawModem then
        return nil, "wireless modem not allowed"
    end
    return nil, "no modem"
end

local function makeNonce()
    return tostring(math.random(1, 1000000000)) .. "-" .. tostring(os.epoch("utc"))
end

local function serverIsKnown(serverId)
    return knownServers ~= nil and serverId ~= nil and knownServers[serverId] == true
end

local function refreshNetwork()
    local ok, ids, reason = netcheck.check(3)
    if ok then
        knownServers = ids
        return true, nil
    end
    knownServers = nil
    return false, reason
end

local function ensureNetwork()
    if knownServers ~= nil then
        return true, nil
    end
    return refreshNetwork()
end

local function invalidateNetwork()
    knownServers = nil
end

-- One request/reply exchange. Returns:
--   true, replyTable
--   false, reason            (transport/timeout/unknown server)
--   false, reason, replyTable (server refused; reply carries detail)
local function exchange(kind, code, timeout, expectedType)
    local modem, modemReason = findWiredModem()
    if modem == nil then
        return false, modemReason
    end

    local networkOk, networkReason = ensureNetwork()
    if not networkOk then
        return false, "network check: " .. tostring(networkReason)
    end

    local replyChannel = math.random(1000, 9999)
    local nonce = makeNonce()
    local terminalId = tostring(os.getComputerID())
    local request = {
        protocol = PROTOCOL,
        type = kind,
        code = code,
        nonce = nonce,
        terminal_id = terminalId,
    }
    if kind == "write_request" then
        request.reservation_id = terminalId .. "-" .. nonce
    end

    local opened = pcall(peripheral.call, modem, "open", replyChannel)
    if not opened then
        return false, "cannot open channel"
    end

    local sent = pcall(peripheral.call, modem, "transmit", CHANNEL, replyChannel, request)
    if not sent then
        pcall(peripheral.call, modem, "close", replyChannel)
        return false, "no modem"
    end

    local timer = os.startTimer(timeout)
    local unknownServer = false
    local reply = nil
    while reply == nil do
        local event, side, channel, replyChannelIn, message = os.pullEvent()
        if event == "modem_message" then
            -- Accept only our own reply: same modem side, same reply channel,
            -- same protocol and type, our nonce, and a server netcheck has seen.
            if side == modem and channel == replyChannel and type(message) == "table"
                and message.protocol == PROTOCOL and message.type == expectedType
                and message.nonce == nonce then
                if serverIsKnown(message.server_id) then
                    reply = message
                else
                    unknownServer = true
                end
            end
        elseif event == "timer" and side == timer then
            break
        end
    end
    pcall(peripheral.call, modem, "close", replyChannel)

    if reply == nil then
        -- The cached server id may be stale (server restarted): recheck next time.
        invalidateNetwork()
        if unknownServer then
            return false, "answer from unknown server"
        end
        return false, "server timeout"
    end

    if reply.success ~= true then
        local reason = reply.message
        if type(reason) ~= "string" or reason == "" then
            reason = "refused"
        end
        return false, reason, reply
    end

    return true, reply
end

-- check(code) -> (true, {uses_left, uses_total}) | (false, reason)
function M.check(code)
    local trimmed = trimCode(code)
    if trimmed == "" then
        return false, "empty code"
    end
    local ok, reply = exchange("verify_request", trimmed, VERIFY_TIMEOUT, "verify_response")
    if not ok then
        return false, reply
    end
    return true, {
        uses_left = reply.uses_left,
        uses_total = reply.uses_total,
    }
end

-- write(code) -> (true, {uses_left, uses_total, charged, files, dirs, bytes})
--             | (false, reason, detail)
function M.write(code)
    local trimmed = trimCode(code)
    if trimmed == "" then
        return false, "empty code"
    end
    local ok, replyOrReason, refused = exchange("write_request", trimmed, WRITE_TIMEOUT,
        "write_response")
    if not ok then
        local detail = nil
        if type(refused) == "table" then
            detail = refused.detail
        end
        return false, replyOrReason, detail
    end
    local reply = replyOrReason
    return true, {
        uses_left = reply.uses_left,
        uses_total = reply.uses_total,
        charged = reply.charged,
        files = reply.files,
        dirs = reply.dirs,
        bytes = reply.bytes,
    }
end

return M
