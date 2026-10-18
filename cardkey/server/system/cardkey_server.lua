-- cardkey_server.lua -- cardkey_v1 service: modem requests, charging, logging.
-- Deploy as /system/cardkey_server.lua on the card key server.
--
-- The service never prints: the admin console owns the screen. Everything it
-- has to say goes to /auth/cardkey_server.log, and fatal wiring problems go to
-- /auth/cardkey_fault.flag for the console to show.
--
-- The file is loadable without starting: loadfile(path)("test") returns the
-- module; os.run({}, path) (no arguments) boots the service.

local M = {}

local LOG_PATH = "/auth/cardkey_server.log"
local FAULT_PATH = "/auth/cardkey_fault.flag"
local SERVER_ID_PATH = "/auth/cardkey_server_id"
local ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local REPLAY_CAP = 2000

local function nowMs()
    return os.epoch("utc")
end

function M.log(message)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(message) .. "\n"
    local f = fs.open(LOG_PATH, "a")
    if f then
        f.write(line)
        f.close()
    end
end

function M.fault(message)
    local text = tostring(message):gsub("[\r\n]+", " ")
    local f = fs.open(FAULT_PATH, "wb")
    if f then
        f.write(text .. "\n")
        f.close()
    end
    M.log("ERROR fault: " .. text)
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- server id
---------------------------------------------------------------------------

function M.loadServerId()
    if fs.exists(SERVER_ID_PATH) then
        local f = fs.open(SERVER_ID_PATH, "rb")
        if f then
            local raw = f.readAll()
            f.close()
            raw = (raw or ""):gsub("%s+", "")
            if #raw == 24 and raw:match("^[A-Za-z0-9]+$") then
                return raw
            end
        end
    end
    local out = {}
    for i = 1, 24 do
        local idx = math.random(1, #ID_ALPHABET)
        out[i] = ID_ALPHABET:sub(idx, idx)
    end
    local fresh = table.concat(out)
    local f = fs.open(SERVER_ID_PATH, "wb")
    if f then
        f.write(fresh .. "\n")
        f.close()
    end
    return fresh
end

---------------------------------------------------------------------------
-- modem selection
---------------------------------------------------------------------------
-- A wired modem reports its own network through getNamesRemote(). That is the
-- only way to tell the terminal network from the drive network: getNames()
-- merges every hub, so a drive looks visible from both modems.

local function isWireless(name)
    local ok, value = pcall(peripheral.call, name, "isWireless")
    if not ok then
        return nil
    end
    return value == true
end

function M.pickModem(conf)
    local suffix = "; set modem_side in /auth/cardkey_config.lua"
    local configured = conf and conf.modem_side
    if configured ~= nil then
        local name = tostring(configured)
        local okPresent, present = pcall(peripheral.isPresent, name)
        local okType, isModem = pcall(peripheral.hasType, name, "modem")
        if not okPresent or not present or not okType or not isModem then
            return nil, "modem_side '" .. name .. "' is not a modem"
        end
        if isWireless(name) == true then
            return nil, "modem_side '" .. name .. "' is not a wired modem"
        end
        return name
    end

    local modems = {}
    local names = peripheral.getNames()
    if type(names) == "table" then
        for _, name in ipairs(names) do
            local okType, isModem = pcall(peripheral.hasType, name, "modem")
            if okType and isModem and isWireless(name) ~= true then
                modems[#modems + 1] = tostring(name)
            end
        end
    end
    table.sort(modems)

    if #modems == 0 then
        return nil, "no wired modem found - attach a wired modem and reboot"
    end
    if #modems == 1 then
        return modems[1]
    end

    local candidates, unknown = {}, 0
    for _, name in ipairs(modems) do
        local okNames, remotes = pcall(peripheral.call, name, "getNamesRemote")
        if not okNames or type(remotes) ~= "table" then
            unknown = unknown + 1
        else
            local hasDrive = false
            for _, remote in ipairs(remotes) do
                local okType, isDrive = pcall(peripheral.hasType, remote, "drive")
                if okType and isDrive then
                    hasDrive = true
                    break
                end
            end
            if not hasDrive then
                candidates[#candidates + 1] = name
            end
        end
    end

    if unknown > 0 then
        return nil, "cannot tell which wired modem is the terminal network (" ..
            tostring(#modems) .. " wired modems, " .. tostring(unknown) ..
            " could not report their network)" .. suffix
    end
    if #candidates == 0 then
        return nil, "every wired modem carries a drive; the terminal network is not attached" ..
            suffix
    end
    if #candidates == 1 then
        return candidates[1]
    end
    return nil, "several wired modems could be the terminal network (" ..
        table.concat(candidates, ", ") .. ")" .. suffix
end

---------------------------------------------------------------------------
-- request context
---------------------------------------------------------------------------

function M.newContext(conf, store, writer, serverId)
    return {
        cfg = conf,
        store = store,
        writer = writer,
        server_id = serverId,
        now = nowMs,
        seen = {},
        seenOrder = {},
        fails = {},
        termLock = {},
        globalFails = 0,
        globalLock = 0,
    }
end

local function pruneSeen(ctx, now)
    local keep = {}
    for i = 1, #ctx.seenOrder do
        local entry = ctx.seenOrder[i]
        if entry.expiry > now then
            keep[#keep + 1] = entry
        elseif ctx.seen[entry.nonce] == entry.expiry then
            ctx.seen[entry.nonce] = nil
        end
    end
    ctx.seenOrder = keep
end

local function replayCheck(ctx, nonce, now)
    local expiry = ctx.seen[nonce]
    if expiry and expiry > now then
        return false
    end
    if expiry then
        ctx.seen[nonce] = nil
    end
    local ttl = tonumber(ctx.cfg.challenge_ttl_ms) or 15000
    local newExpiry = now + ttl
    ctx.seen[nonce] = newExpiry
    ctx.seenOrder[#ctx.seenOrder + 1] = {nonce = nonce, expiry = newExpiry}
    while #ctx.seenOrder > REPLAY_CAP do
        local first = table.remove(ctx.seenOrder, 1)
        if first and ctx.seen[first.nonce] == first.expiry then
            ctx.seen[first.nonce] = nil
        end
    end
    return true
end

local function lockoutSeconds(ctx, terminal, now)
    local untilMs = ctx.termLock[terminal]
    if type(untilMs) == "number" and untilMs > now then
        return math.ceil((untilMs - now) / 1000)
    end
    if type(ctx.globalLock) == "number" and ctx.globalLock > now then
        return math.ceil((ctx.globalLock - now) / 1000)
    end
    return nil
end

local function noteFailure(ctx, terminal, now)
    local perMax = tonumber(ctx.cfg.max_fail_per_terminal) or 10
    local lockMs = tonumber(ctx.cfg.lockout_ms) or 60000
    local globMax = tonumber(ctx.cfg.max_fail_global) or 60
    local globMs = tonumber(ctx.cfg.global_lockout_ms) or 30000

    ctx.fails[terminal] = (ctx.fails[terminal] or 0) + 1
    ctx.globalFails = (ctx.globalFails or 0) + 1

    if ctx.fails[terminal] >= perMax then
        ctx.termLock[terminal] = now + lockMs
        ctx.fails[terminal] = nil
        M.log("LOCKED terminal=" .. terminal .. " seconds=" .. tostring(math.floor(lockMs / 1000)))
    end
    if ctx.globalFails >= globMax then
        ctx.globalLock = now + globMs
        ctx.globalFails = 0
        M.log("LOCKED terminal=global seconds=" .. tostring(math.floor(globMs / 1000)))
    end
end

local function noteSuccess(ctx, terminal)
    ctx.fails[terminal] = nil
    ctx.globalFails = 0
end

---------------------------------------------------------------------------
-- replies
---------------------------------------------------------------------------

local function baseReply(ctx, kind, nonce)
    return {
        protocol = ctx.cfg.protocol,
        type = kind,
        server_id = ctx.server_id,
        nonce = nonce or "",
    }
end

local function verifyReply(ctx, nonce, success, message, rec)
    local out = baseReply(ctx, "verify_response", nonce)
    out.success = success and true or false
    out.message = message
    if rec then
        out.uses_left = rec.uses_left
        out.uses_total = rec.uses_total
    end
    return out
end

local function writeReply(ctx, nonce, success, message, fields)
    local out = baseReply(ctx, "write_response", nonce)
    out.success = success and true or false
    out.message = message
    if fields then
        for key, value in pairs(fields) do
            out[key] = value
        end
    end
    return out
end

---------------------------------------------------------------------------
-- handlers
---------------------------------------------------------------------------

local function handleVerify(ctx, message)
    local nonce = message.nonce
    local terminal = tostring(message.terminal_id or "unknown")
    local now = ctx.now()
    if type(nonce) ~= "string" or nonce == "" then
        return verifyReply(ctx, nonce, false, "malformed request")
    end
    if not replayCheck(ctx, nonce, now) then
        M.log("DENY terminal=" .. terminal .. " reason=duplicate request")
        return verifyReply(ctx, nonce, false, "duplicate request")
    end
    local wait = lockoutSeconds(ctx, terminal, now)
    if wait then
        M.log("LOCKED terminal=" .. terminal .. " blocked=1")
        return verifyReply(ctx, nonce, false, "too many attempts, wait " .. tostring(wait) .. "s")
    end
    local code = trim(message.code)
    if code == "" then
        return verifyReply(ctx, nonce, false, "empty code")
    end
    local rec, reason = ctx.store.lookup(code)
    if rec then
        noteSuccess(ctx, terminal)
        M.log("CHECK terminal=" .. terminal .. " success=1 uses_left=" ..
            tostring(rec.uses_left))
        return verifyReply(ctx, nonce, true, "OK", rec)
    end
    noteFailure(ctx, terminal, now)
    M.log("DENY terminal=" .. terminal .. " reason=" .. tostring(reason))
    return verifyReply(ctx, nonce, false, reason)
end

local function handleWrite(ctx, message)
    local nonce = message.nonce
    local terminal = tostring(message.terminal_id or "unknown")
    local now = ctx.now()
    if type(nonce) ~= "string" or nonce == "" then
        return writeReply(ctx, nonce, false, "malformed request", {charged = false})
    end
    local resId = message.reservation_id
    if type(resId) ~= "string" or resId == "" then
        return writeReply(ctx, nonce, false, "missing reservation id", {charged = false})
    end
    if not replayCheck(ctx, nonce, now) then
        M.log("DENY terminal=" .. terminal .. " reason=duplicate request")
        return writeReply(ctx, nonce, false, "duplicate request", {charged = false})
    end
    local wait = lockoutSeconds(ctx, terminal, now)
    if wait then
        M.log("LOCKED terminal=" .. terminal .. " blocked=1")
        return writeReply(ctx, nonce, false,
            "too many attempts, wait " .. tostring(wait) .. "s", {charged = false})
    end
    local code = trim(message.code)
    if code == "" then
        return writeReply(ctx, nonce, false, "empty code", {charged = false})
    end

    local grant, reserveReason = ctx.store.reserve(code, resId)
    if not grant then
        noteFailure(ctx, terminal, now)
        M.log("DENY terminal=" .. terminal .. " reason=" .. tostring(reserveReason))
        return writeReply(ctx, nonce, false, reserveReason, {charged = false})
    end
    M.log("GRANT terminal=" .. terminal .. " reservation=" .. resId ..
        " fp=" .. tostring(grant.fp))

    -- pcall keeps the return positions: (ok, first, second, third, ...).
    -- writer.write returns (true, info) or (false, reason, detail).
    local called, wrote, writeResult, writeExtra = pcall(ctx.writer.write)
    if not called then
        ctx.store.release(resId)
        M.log("WRITEFAIL terminal=" .. terminal .. " reservation=" .. resId ..
            " reason=exception " .. tostring(wrote))
        return writeReply(ctx, nonce, false, "disk write error",
            {charged = false, detail = tostring(wrote)})
    end
    if not wrote then
        ctx.store.release(resId)
        M.log("WRITEFAIL terminal=" .. terminal .. " reservation=" .. resId ..
            " reason=" .. tostring(writeResult) .. " detail=" .. tostring(writeExtra))
        local text = tostring(writeResult or "disk write error")
        if writeExtra ~= nil and tostring(writeExtra) ~= "" then
            text = text .. ": " .. tostring(writeExtra)
        end
        return writeReply(ctx, nonce, false, "disk write error",
            {charged = false, detail = text})
    end
    local info = writeResult or {}

    local rec, charged = ctx.store.commit(resId)
    if not rec then
        M.log("ERROR commit failed reservation=" .. resId ..
            " reason=" .. tostring(charged))
        return writeReply(ctx, nonce, false, "no such reservation", {charged = false})
    end
    M.log("WRITE! reservation=" .. resId .. " files=" .. tostring(info.files) ..
        " dirs=" .. tostring(info.dirs) .. " bytes=" .. tostring(info.bytes))
    M.log("COMMIT! reservation=" .. resId .. " charged=" ..
        (charged and "1" or "0") .. " uses_left=" .. tostring(rec.uses_left))
    noteSuccess(ctx, terminal)
    return writeReply(ctx, nonce, true,
        charged and "OK" or "written, use not charged", {
            charged = charged,
            uses_left = rec.uses_left,
            uses_total = rec.uses_total,
            files = info.files,
            dirs = info.dirs,
            bytes = info.bytes,
        })
end

function M.handleMessage(ctx, message)
    if type(message) ~= "table" then
        return nil
    end
    if message.protocol ~= ctx.cfg.protocol then
        return nil
    end
    if message.type == "verify_request" then
        return handleVerify(ctx, message)
    end
    if message.type == "write_request" then
        return handleWrite(ctx, message)
    end
    return nil
end

---------------------------------------------------------------------------
-- service boot
---------------------------------------------------------------------------

function M.start()
    local okStore, store = pcall(dofile, "/auth/cardkey_store.lua")
    if not okStore then
        M.fault("cannot load /auth/cardkey_store.lua: " .. tostring(store))
        return
    end
    local okWriter, writer = pcall(dofile, "/system/disk_writer.lua")
    if not okWriter then
        M.fault("cannot load /system/disk_writer.lua: " .. tostring(writer))
        return
    end
    local okConfig, conf = pcall(dofile, "/auth/cardkey_config.lua")
    if not okConfig or type(conf) ~= "table" then
        M.fault("cannot load /auth/cardkey_config.lua: " .. tostring(conf))
        return
    end

    local serverId = M.loadServerId()
    local side, modemError = M.pickModem(conf)
    if not side then
        M.fault(modemError)
        return
    end
    if fs.exists(FAULT_PATH) then
        fs.delete(FAULT_PATH)
    end

    local opened, openError = pcall(peripheral.call, side, "open", conf.channel)
    if not opened then
        M.fault("cannot open modem channel " .. tostring(conf.channel) .. ": " ..
            tostring(openError))
        return
    end

    local st = store.stats()
    M.log("START server_id=" .. serverId .. " channel=" .. tostring(conf.channel) ..
        " keys_usable=" .. tostring(st.alive) .. " keys_total=" .. tostring(st.total))

    local ctx = M.newContext(conf, store, writer, serverId)
    local heartbeatInterval = tonumber(conf.heartbeat_interval) or 2

    local function heartbeatLoop()
        while true do
            local payload = {
                protocol = conf.protocol,
                type = "heartbeat",
                server_id = serverId,
            }
            local okSend, sendError = pcall(peripheral.call, side, "transmit",
                conf.channel, conf.channel, payload)
            if not okSend then
                M.log("ERROR heartbeat: " .. tostring(sendError))
            end
            os.sleep(heartbeatInterval)
        end
    end

    local function requestLoop()
        while true do
            local _, msgSide, channel, replyChannel, message = os.pullEvent("modem_message")
            if msgSide == side and channel == conf.channel then
                local okHandle, reply = pcall(M.handleMessage, ctx, message)
                if not okHandle then
                    M.log("ERROR handler: " .. tostring(reply))
                elseif reply then
                    local okSend, sendError = pcall(peripheral.call, side, "transmit",
                        replyChannel, conf.channel, reply)
                    if not okSend then
                        M.log("ERROR transmit: " .. tostring(sendError))
                    end
                end
            end
        end
    end

    local function housekeepingLoop()
        while true do
            os.sleep(5)
            pruneSeen(ctx, ctx.now())
            local okPrune, dropped = pcall(store.prune)
            if not okPrune then
                M.log("ERROR prune: " .. tostring(dropped))
            end
        end
    end

    parallel.waitForAny(heartbeatLoop, requestLoop, housekeepingLoop)
end

local arg = ...
if arg == nil then
    M.start()
end
return M
