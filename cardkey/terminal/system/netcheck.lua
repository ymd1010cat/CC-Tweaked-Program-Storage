-- CardKey terminal network check: listen on channel 3 and count card key servers.
-- Deploy path: /system/netcheck.lua
-- A server is identified by the server_id inside its heartbeat; only distinct
-- ids are counted, so hearing one server three times still means one server.

local M = {}

local CHANNEL = 3
local PROTOCOL = "cardkey_v1"

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

-- Returns (modemName) when a wired modem exists, else (nil, reason).
-- Wireless modems are skipped; only a terminal with no wired modem reports it.
local function pickModem()
    local names = peripheralNames()
    local sawModem = false
    local wired = nil
    for i = 1, #names do
        local name = names[i]
        if isModem(name) then
            sawModem = true
            if not isWireless(name) and wired == nil then
                wired = name
            end
        end
    end
    if wired ~= nil then
        return wired, nil
    end
    if sawModem then
        return nil, "wireless modem"
    end
    return nil, "no modem"
end

local function countIds(ids)
    local count = 0
    for _ in pairs(ids) do
        count = count + 1
    end
    return count
end

-- check(listenSec) -> ok, ids, reason
-- ids maps every distinct server_id heard in the window to true.
function M.check(listenSec)
    listenSec = tonumber(listenSec) or 3

    local modem, modemReason = pickModem()
    if modem == nil then
        return false, {}, modemReason
    end

    local opened = pcall(peripheral.call, modem, "open", CHANNEL)
    if not opened then
        return false, {}, "cannot open channel"
    end

    local ids = {}
    local timer = os.startTimer(listenSec)
    local listening = true
    while listening do
        local event, side, channel, replyChannel, message = os.pullEvent()
        if event == "modem_message" then
            if side == modem and channel == CHANNEL and type(message) == "table"
                and message.protocol == PROTOCOL and message.type == "heartbeat" then
                local serverId = message.server_id
                if type(serverId) == "string" and serverId ~= "" then
                    ids[serverId] = true
                end
            end
        elseif event == "timer" and side == timer then
            listening = false
        end
    end
    pcall(peripheral.call, modem, "close", CHANNEL)

    local seen = countIds(ids)
    if seen == 0 then
        return false, ids, "no card key server detected"
    end
    if seen >= 2 then
        return false, ids, "multiple servers: " .. tostring(seen)
    end
    return true, ids, nil
end

return M
