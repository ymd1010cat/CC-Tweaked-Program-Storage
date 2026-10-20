-- Sentinel network presence check.
-- Deploy: /system/netcheck.lua
--
-- Listens on the auth channel through a wired modem for one window and counts
-- the distinct server ids that are broadcasting heartbeats. Exactly one server
-- is acceptable; zero or several means the terminal must not log in.

local M = {}

local PROTOCOL = "secure_auth_v4"
local AUTH_CHANNEL = 1

local function modemNames()
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then return names end
    return {}
end

local function isModem(name)
    local ok, kind = pcall(peripheral.getType, name)
    return ok and kind == "modem"
end

local function isWireless(name)
    local ok, wireless = pcall(peripheral.call, name, "isWireless")
    return ok and wireless == true
end

-- Returns a wired modem name, or nil plus "no modem" / "wireless modem".
local function findWiredModem()
    local found = nil
    local sawModem = false
    for _, name in ipairs(modemNames()) do
        if isModem(name) then
            sawModem = true
            if not isWireless(name) and not found then
                found = name
            end
        end
    end
    if found then return found end
    if sawModem then return nil, "wireless modem" end
    return nil, "no modem"
end

function M.check(listenSec)
    listenSec = listenSec or 3

    local modem, reason = findWiredModem()
    if not modem then
        return false, {}, reason
    end

    local opened = pcall(peripheral.call, modem, "open", AUTH_CHANNEL)
    if not opened then
        return false, {}, "check interrupted"
    end

    local seen = {}
    local ids = {}
    local timer = os.startTimer(listenSec)

    while true do
        -- modem_message is (side, channel, replyChannel, message, distance).
        local event, side, channel, senderReply, message = os.pullEvent()
        if event == "timer" and (side == timer or senderReply == timer) then
            break
        elseif event == "modem_message" and type(message) == "table" then
            if message.protocol == PROTOCOL
                and message.type == "heartbeat"
                and type(message.server_id) == "string"
                and not seen[message.server_id] then
                seen[message.server_id] = true
                ids[#ids + 1] = message.server_id
            end
        end
    end

    pcall(peripheral.call, modem, "close", AUTH_CHANNEL)
    table.sort(ids)

    if #ids == 1 then
        return true, ids, "ok"
    elseif #ids == 0 then
        return false, ids, "no server detected"
    end
    return false, ids, "multiple servers: " .. tostring(#ids)
end

return M
