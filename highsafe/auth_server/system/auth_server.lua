-- auth_server.lua -- HighSafe authentication service (protocol secure_auth_v4).
-- Deploy path: /system/auth_server.lua
--
-- Broadcasts a heartbeat on channel 1 once per second and answers
-- salt_request / auth_request messages from registered terminals.
--
-- Trust model: the terminal id in a request is only believed once the request
-- carries a valid signature made with that terminal's key, so an unknown id
-- gets no reply at all (there is nothing to sign with). Unknown usernames get
-- the dummy salt "ffffffffffffffff" signed normally, so a client cannot tell
-- "no such user" from "wrong password" before it submits a derivation.

local M = {}

local PROTOCOL = "secure_auth_v4"
local CHANNEL = 1
local HEARTBEAT_INTERVAL = 1

local SERVER_ID_PATH = "/auth/server_id"
local SERVER_ID_LENGTH = 24
local CRYPTO_PATH = "/auth/server_crypto.lua"
local USER_MANAGER_PATH = "/auth/user_manager.lua"

local FAKE_SALT = "ffffffffffffffff"
local REPLAY_TTL_MS = 15000
local REPLAY_MAX_TERMINALS = 64
local REPLAY_MAX_NONCES = 32

local ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

local modem = nil
local serverId = nil

local cryptoModule = nil
local cryptoLoaded = false
local userManagerModule = nil
local userManagerLoaded = false

-- [terminalId] = array of { kind = "salt"|"auth", nonce = string, at = ms }
-- The kind is part of the identity: a normal login reuses the same nonce_c for
-- its salt_request and its auth_request, and only repeats of the same stage are
-- replays.
local replayMemory = {}

local function nowMs()
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then
        return value
    end
    return math.floor(os.clock() * 1000)
end

local function randomText(length)
    local out = {}
    for i = 1, length do
        local index = math.random(1, #ALNUM)
        out[i] = ALNUM:sub(index, index)
    end
    return table.concat(out)
end

-- Randomness is only seeded here, once per boot; library modules must not
-- reseed (the card key project depends on that rule, keep the style uniform).
local function seedRandom()
    local okEpoch, epoch = pcall(os.epoch, "utc")
    if not okEpoch or type(epoch) ~= "number" then
        epoch = os.clock() * 1000
    end
    local computerId = 0
    local okId, value = pcall(os.getComputerID)
    if okId and type(value) == "number" then
        computerId = value
    end
    local seed = math.floor(epoch) + computerId * 7919 + math.floor(os.clock() * 1000)
    math.randomseed(seed)
end

local function ensureServerId()
    if fs.exists(SERVER_ID_PATH) then
        local handle = fs.open(SERVER_ID_PATH, "r")
        if handle then
            local text = handle.readAll()
            handle.close()
            if type(text) == "string" then
                text = text:gsub("%s+", "")
                if #text >= 8 then
                    return text
                end
            end
        end
    end
    local id = randomText(SERVER_ID_LENGTH)
    local dir = fs.getDir(SERVER_ID_PATH)
    if dir and dir ~= "" and not fs.exists(dir) then
        pcall(fs.makeDir, dir)
    end
    local handle = fs.open(SERVER_ID_PATH, "w")
    if handle then
        handle.write(id)
        handle.close()
    end
    return id
end

-- First wired modem wins; a wireless-only machine is not usable for this
-- protocol, because the heartbeat must be visible on the wired network.
local function findWiredModem()
    local wirelessSide = nil
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, isWireless = pcall(peripheral.call, name, "isWireless")
            if ok and isWireless == false then
                return name
            end
            if wirelessSide == nil then
                wirelessSide = name
            end
        end
    end
    return nil, wirelessSide
end

-- Stop without dropping to a shell; the root console keeps running next to it.
local function halt()
    while true do
        os.pullEvent("terminate")
    end
end

local function getCrypto()
    if cryptoLoaded then return cryptoModule end
    cryptoLoaded = true
    local ok, mod = pcall(dofile, CRYPTO_PATH)
    if ok and type(mod) == "table" then
        cryptoModule = mod
    end
    return cryptoModule
end

local function getUserManager()
    if userManagerLoaded then return userManagerModule end
    userManagerLoaded = true
    local ok, mod = pcall(dofile, USER_MANAGER_PATH)
    if ok and type(mod) == "table" then
        userManagerModule = mod
    end
    return userManagerModule
end

-- Calls an optional user_manager function. A missing module or a thrown error
-- degrades to "no such user", which keeps the request loop alive on a machine
-- with a broken deploy instead of killing the service.
local function userManagerCall(name, ...)
    local mod = getUserManager()
    if not mod then return nil end
    local fn = mod[name]
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if results[1] ~= true then return nil end
    return results[2], results[3]
end

local function newNonce()
    return tostring(math.random()) .. tostring(nowMs())
end

local function pruneReplay(now)
    local terminals = {}
    for terminalId in pairs(replayMemory) do
        terminals[#terminals + 1] = terminalId
    end
    for i = 1, #terminals do
        local terminalId = terminals[i]
        local entries = replayMemory[terminalId]
        local kept = {}
        for j = 1, #entries do
            if now - entries[j].at <= REPLAY_TTL_MS then
                kept[#kept + 1] = entries[j]
            end
        end
        if #kept == 0 then
            replayMemory[terminalId] = nil
        else
            replayMemory[terminalId] = kept
        end
    end
    -- Keep the table bounded: drop the terminal that was heard from longest ago.
    local count, victim, victimAt = 0, nil, nil
    for terminalId, entries in pairs(replayMemory) do
        count = count + 1
        local newest = entries[#entries] and entries[#entries].at or 0
        if victimAt == nil or newest < victimAt then
            victim, victimAt = terminalId, newest
        end
    end
    if count > REPLAY_MAX_TERMINALS and victim ~= nil then
        replayMemory[victim] = nil
    end
end

-- True when the (stage, nonce) pair is new and has been recorded, false when it
-- was already seen inside the TTL window.
local function recordNonce(terminalId, kind, nonce, now)
    local kept = {}
    local existing = replayMemory[terminalId]
    if existing then
        for i = 1, #existing do
            local entry = existing[i]
            if now - entry.at <= REPLAY_TTL_MS then
                kept[#kept + 1] = entry
            end
        end
    end
    for i = 1, #kept do
        if kept[i].kind == kind and kept[i].nonce == nonce then
            replayMemory[terminalId] = kept
            return false
        end
    end
    kept[#kept + 1] = { kind = kind, nonce = nonce, at = now }
    while #kept > REPLAY_MAX_NONCES do
        table.remove(kept, 1)
    end
    replayMemory[terminalId] = kept
    return true
end

local function reply(replyChannel, message)
    if type(replyChannel) ~= "number" then return false end
    if not modem then return false end
    return pcall(modem.transmit, replyChannel, replyChannel, message)
end

local function isFilledString(value)
    return type(value) == "string" and value ~= ""
end

local function handleSaltRequest(message, replyChannel, now)
    local terminalId = message.terminal_id
    local username = message.username
    local nonceC = message.nonce_c
    if not isFilledString(terminalId) or not isFilledString(username)
            or not isFilledString(nonceC) then
        return
    end
    local crypto = getCrypto()
    if not crypto then return end
    local expected = terminalId .. "|" .. username .. "|" .. nonceC
    if not crypto.verify(terminalId, expected, message.sig) then return end
    if not recordNonce(terminalId, "salt", nonceC, now) then return end

    local salt = userManagerCall("getSalt", username)
    if not isFilledString(salt) then
        salt = FAKE_SALT
    end
    local nonceS = newNonce()
    local signed = serverId .. "|" .. username .. "|" .. salt .. "|" .. nonceC .. "|" .. nonceS
    local sig = crypto.sign(terminalId, signed)
    if not sig then return end
    reply(replyChannel, {
        protocol = PROTOCOL,
        type = "salt_response",
        server_id = serverId,
        terminal_id = terminalId,
        salt = salt,
        nonce_s = nonceS,
        sig = sig,
    })
end

local function handleAuthRequest(message, replyChannel, now)
    local terminalId = message.terminal_id
    local username = message.username
    local derived = message.derived
    local nonceC = message.nonce_c
    local nonceS = message.nonce_s
    if not isFilledString(terminalId) or not isFilledString(username)
            or not isFilledString(derived) or not isFilledString(nonceC)
            or not isFilledString(nonceS) then
        return
    end
    local crypto = getCrypto()
    if not crypto then return end
    local expected = terminalId .. "|" .. username .. "|" .. derived
        .. "|" .. nonceC .. "|" .. nonceS
    if not crypto.verify(terminalId, expected, message.sig) then return end
    if not recordNonce(terminalId, "auth", nonceC, now) then return end

    local passed, role = userManagerCall("verifyDerived", username, derived, nonceC, nonceS)
    local success = passed == true
    if success and not isFilledString(role) then
        role = "guest"
    end
    local signed = serverId .. "|" .. nonceC .. "|" .. nonceS .. "|" .. tostring(success)
        .. "|" .. tostring(role or "")
    local sig = crypto.sign(terminalId, signed)
    if not sig then return end
    reply(replyChannel, {
        protocol = PROTOCOL,
        type = "auth_response",
        server_id = serverId,
        terminal_id = terminalId,
        nonce_c = nonceC,
        nonce_s = nonceS,
        success = success,
        role = success and role or nil,
        message = success and "OK" or "Invalid credentials",
        sig = sig,
    })
end

local function heartbeatLoop()
    local beat = {
        protocol = PROTOCOL,
        type = "heartbeat",
        server_id = serverId,
    }
    while true do
        if modem then
            pcall(modem.transmit, CHANNEL, CHANNEL, beat)
        end
        os.sleep(HEARTBEAT_INTERVAL)
    end
end

local function requestLoop()
    while true do
        local now = nowMs()
        pruneReplay(now)
        local event, _side, channel, replyChannel, message = os.pullEvent("modem_message")
        -- Named locals on purpose: ("modem_message", side, channel,
        -- replyChannel, message, distance).
        if event == "modem_message" and channel == CHANNEL
                and type(message) == "table" and message.protocol == PROTOCOL then
            if message.type == "salt_request" then
                handleSaltRequest(message, replyChannel, now)
            elseif message.type == "auth_request" then
                handleAuthRequest(message, replyChannel, now)
            end
        end
    end
end

function M.run()
    seedRandom()
    serverId = ensureServerId()

    pcall(function()
        term.clear()
        term.setCursorPos(1, 1)
    end)
    print("Auth Server")
    print("Protocol:  " .. PROTOCOL)
    print("Server ID: " .. serverId)

    local side, wirelessSide = findWiredModem()
    if not side then
        if wirelessSide then
            print("FATAL: wireless modem is not supported")
        else
            print("FATAL: no wired modem")
        end
        print("Attach a wired modem and reboot.")
        halt()
    end

    modem = peripheral.wrap(side)
    if type(modem) ~= "table" or type(modem.open) ~= "function" then
        print("FATAL: modem " .. tostring(side) .. " is not usable")
        halt()
    end
    local opened, openError = pcall(modem.open, CHANNEL)
    if not opened then
        print("FATAL: cannot open channel " .. tostring(CHANNEL))
        print(tostring(openError))
        halt()
    end

    parallel.waitForAny(heartbeatLoop, requestLoop)
end

M.run()

return M
