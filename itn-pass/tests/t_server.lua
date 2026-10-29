-- t_server.lua -- itnpass_server: protocol, replay, lockout, write transaction.
--
-- The store is the real staged module; only the disk writer is a stub, so the
-- transaction order (reserve -> write -> commit, release on failure) is what
-- gets exercised.

local STORE = "/auth/itnpass_store.lua"
local DB = "/auth/itnpass_passes.db"
local PEPPER_PATH = "/auth/itnpass_pepper.txt"
local CONFIG = "/auth/itnpass_config.lua"
local LOG = "/auth/itnpass_server.log"
local FAULT = "/auth/itnpass_fault.flag"
local PEPPER = string.rep("Cd4", 16)

local function run(H)
    local server = H.load("/system/itnpass_server.lua", "test")

    local function log()
        return H.readFile(LOG) or ""
    end

    local function freshStore()
        if fs.exists(DB) then fs.delete(DB) end
        if fs.exists(LOG) then fs.delete(LOG) end
        H.writeFile(PEPPER_PATH, PEPPER .. "\n")
        return dofile(STORE)
    end

    local function conf(overrides)
        local base = dofile(CONFIG)
        local out = {}
        for k, v in pairs(base) do out[k] = v end
        for k, v in pairs(overrides or {}) do out[k] = v end
        return out
    end

    local function ctxFor(store, writer, overrides)
        return server.newContext(conf(overrides), store, writer, "TEST-SRV")
    end

    local function writerOk(info)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            return true, info or { files = 2, dirs = 1, bytes = 9000 }
        end
        return w
    end

    local function writerFail(reason, detail)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            return false, reason, detail
        end
        return w
    end

    local function writerError(message)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            error(message)
        end
        return w
    end

    local seq = 0
    local function nextNonce(tag)
        seq = seq + 1
        return (tag or "n") .. "-" .. tostring(seq)
    end

    local function verify(ctx, fields)
        local msg = {
            protocol = "itnpass_v1",
            type = "verify_request",
            terminal_id = "T-1",
        }
        for k, v in pairs(fields or {}) do msg[k] = v end
        return server.handleMessage(ctx, msg)
    end

    local function writeReq(ctx, fields)
        local msg = {
            protocol = "itnpass_v1",
            type = "write_request",
            terminal_id = "T-1",
        }
        for k, v in pairs(fields or {}) do msg[k] = v end
        return server.handleMessage(ctx, msg)
    end

    ------------------------------------------------------------------------
    -- protocol filter and verify responses
    ------------------------------------------------------------------------
    H.group("server.proto")
    local store = freshStore()
    local ctx = ctxFor(store, writerOk())
    H.check("server.load_returns_module",
        type(server.handleMessage) == "function" and type(server.start) == "function")
    H.check("server.load_does_not_boot", not fs.exists(FAULT))
    H.check("server.ignores_non_table", server.handleMessage(ctx, "hello") == nil)
    H.check("server.ignores_nil", server.handleMessage(ctx, nil) == nil)
    H.check("server.ignores_other_protocol", server.handleMessage(ctx, {
        protocol = "other_v1", type = "verify_request", nonce = "x",
    }) == nil)
    H.check("server.ignores_unknown_type", server.handleMessage(ctx, {
        protocol = "itnpass_v1", type = "heartbeat", nonce = "x",
    }) == nil)

    local codes, pending = store.mint(2, 2, "srv")
    store.commitBatch(pending)
    local code = codes[1]

    local n = nextNonce("v")
    local reply = verify(ctx, { nonce = n, code = code })
    H.check("server.verify_type", reply.type == "verify_response")
    H.check("server.verify_protocol_echo", reply.protocol == "itnpass_v1")
    H.check("server.verify_server_id", reply.server_id == "TEST-SRV")
    H.check("server.verify_nonce_echo", reply.nonce == n, tostring(reply.nonce))
    H.check("server.verify_ok", reply.success == true and reply.message == "OK",
        tostring(reply.message))
    H.check("server.verify_uses_fields", reply.uses_left == 2 and reply.uses_total == 2,
        tostring(reply.uses_left))
    H.check("server.verify_does_not_charge",
        select(1, store.lookup(code)).uses_left == 2)
    H.check("server.verify_logs_check",
        log():find("ITNP_CHECK terminal=T-1 success=1 uses_left=2", 1, true) ~= nil)

    reply = verify(ctx, { code = code })
    H.check("server.verify_missing_nonce",
        reply.success == false and reply.message == "malformed request",
        tostring(reply.message))
    H.check("server.verify_missing_nonce_empty_echo", reply.nonce == "")
    H.check("server.verify_missing_nonce_no_uses", reply.uses_left == nil)

    reply = verify(ctx, { nonce = nextNonce("v"), code = "" })
    H.check("server.verify_empty_code", reply.message == "empty code",
        tostring(reply.message))
    reply = verify(ctx, { nonce = nextNonce("v"), code = "   " })
    H.check("server.verify_blank_code", reply.message == "empty code")

    reply = verify(ctx, { nonce = nextNonce("v"), code = "23456789ABCDEFGH" })
    H.check("server.verify_unknown_code",
        reply.success == false and reply.message == "unknown code",
        tostring(reply.message))
    H.check("server.verify_unknown_logged",
        log():find("ITNP_DENY terminal=T-1 reason=unknown code", 1, true) ~= nil)
    reply = verify(ctx, { nonce = nextNonce("v"), code = "bad" })
    H.check("server.verify_invalid_code_format",
        reply.message == "invalid code format", tostring(reply.message))

    ------------------------------------------------------------------------
    -- replay window
    ------------------------------------------------------------------------
    H.group("server.replay")
    store = freshStore()
    codes, pending = store.mint(1, 2, "")
    store.commitBatch(pending)
    ctx = ctxFor(store, writerOk())
    local replayMsg = {
        protocol = "itnpass_v1",
        type = "verify_request",
        nonce = nextNonce("dup"),
        code = codes[1],
        terminal_id = "T-R",
    }
    local first = server.handleMessage(ctx, replayMsg)
    local second = server.handleMessage(ctx, replayMsg)
    H.check("server.replay_first_ok", first.success == true, tostring(first.message))
    H.check("server.replay_second_denied",
        second.success == false and second.message == "duplicate request",
        tostring(second.message))
    H.check("server.replay_logged",
        log():find("ITNP_DENY terminal=T-R reason=duplicate request", 1, true) ~= nil)
    H.check("server.replay_does_not_count_as_failure",
        next(ctx.fails) == nil and ctx.termLock["T-R"] == nil)
    H.advance(15001)
    local third = server.handleMessage(ctx, replayMsg)
    H.check("server.replay_allowed_after_ttl", third.success == true,
        tostring(third.message))

    ------------------------------------------------------------------------
    -- per terminal lockout
    ------------------------------------------------------------------------
    H.group("server.lockout")
    store = freshStore()
    codes, pending = store.mint(1, 2, "")
    store.commitBatch(pending)
    local goodCode = codes[1]
    ctx = ctxFor(store, writerOk(), {
        max_fail_per_terminal = 3,
        lockout_ms = 60000,
        max_fail_global = 1000,
    })
    local last
    for i = 1, 3 do
        last = verify(ctx, {
            nonce = nextNonce("bad"),
            code = "23456789ABCDEFGH",
            terminal_id = "LOCK",
        })
    end
    H.check("server.lockout_third_reply_is_plain_deny",
        last.success == false and last.message == "unknown code",
        tostring(last.message))
    H.check("server.lockout_logged",
        log():find("ITNP_LOCKED terminal=LOCK seconds=60", 1, true) ~= nil)
    local blocked = verify(ctx, {
        nonce = nextNonce("ok"),
        code = goodCode,
        terminal_id = "LOCK",
    })
    H.check("server.lockout_blocks_even_valid_code",
        blocked.success == false and blocked.message == "too many attempts, wait 60s",
        tostring(blocked.message))
    H.check("server.lockout_block_logged",
        log():find("ITNP_LOCKED terminal=LOCK blocked=1", 1, true) ~= nil)
    H.check("server.lockout_does_not_charge",
        select(1, store.lookup(goodCode)).uses_left == 2)
    local otherTerm = verify(ctx, {
        nonce = nextNonce("ok"),
        code = goodCode,
        terminal_id = "OTHER",
    })
    H.check("server.lockout_is_per_terminal", otherTerm.success == true,
        tostring(otherTerm.message))
    H.advance(60001)
    local allowed = verify(ctx, {
        nonce = nextNonce("ok"),
        code = goodCode,
        terminal_id = "LOCK",
    })
    H.check("server.lockout_expires", allowed.success == true,
        tostring(allowed.message))

    ------------------------------------------------------------------------
    -- global lockout
    ------------------------------------------------------------------------
    H.group("server.global_lock")
    store = freshStore()
    codes, pending = store.mint(1, 1, "")
    store.commitBatch(pending)
    ctx = ctxFor(store, writerOk(), {
        max_fail_per_terminal = 100,
        max_fail_global = 2,
        global_lockout_ms = 30000,
    })
    verify(ctx, { nonce = nextNonce("g"), code = "23456789ABCDEFGH", terminal_id = "T-A" })
    verify(ctx, { nonce = nextNonce("g"), code = "23456789ABCDEFGH", terminal_id = "T-B" })
    local gReply = verify(ctx, {
        nonce = nextNonce("g"),
        code = codes[1],
        terminal_id = "T-C",
    })
    H.check("server.global_lockout",
        gReply.success == false and gReply.message == "too many attempts, wait 30s",
        tostring(gReply.message))
    H.check("server.global_lockout_logged",
        log():find("ITNP_LOCKED terminal=global seconds=30", 1, true) ~= nil)
    H.advance(30001)
    gReply = verify(ctx, {
        nonce = nextNonce("g"),
        code = codes[1],
        terminal_id = "T-C",
    })
    H.check("server.global_lockout_expires", gReply.success == true,
        tostring(gReply.message))

    ------------------------------------------------------------------------
    -- write transaction
    ------------------------------------------------------------------------
    H.group("server.write")
    store = freshStore()
    codes, pending = store.mint(2, 2, "")
    store.commitBatch(pending)
    local w = writerOk()
    ctx = ctxFor(store, w)
    n = nextNonce("w")
    local resId = "T-1-" .. n
    local wr = writeReq(ctx, {
        nonce = n,
        code = codes[1],
        reservation_id = resId,
        terminal_id = "T-1",
    })
    H.check("server.write_ok", wr.success == true and wr.message == "OK",
        tostring(wr.message))
    H.check("server.write_type", wr.type == "write_response")
    H.check("server.write_nonce_echo", wr.nonce == n)
    H.check("server.write_charged", wr.charged == true)
    H.check("server.write_counts",
        wr.files == 2 and wr.dirs == 1 and wr.bytes == 9000,
        tostring(wr.files) .. "/" .. tostring(wr.bytes))
    H.check("server.write_uses_left", wr.uses_left == 1 and wr.uses_total == 2,
        tostring(wr.uses_left))
    H.check("server.write_charged_in_store",
        select(1, store.lookup(codes[1])).uses_left == 1)
    H.check("server.write_calls_writer_once", w.calls == 1, w.calls)
    local text = log()
    H.check("server.write_grant_log",
        text:find("ITNP_GRANT terminal=T-1 reservation=" .. resId, 1, true) ~= nil)
    H.check("server.write_write_log",
        text:find("ITNP_WRITE reservation=" .. resId
            .. " files=2 dirs=1 bytes=9000", 1, true) ~= nil)
    H.check("server.write_commit_log",
        text:find("ITNP_COMMIT reservation=" .. resId
            .. " charged=1 uses_left=1", 1, true) ~= nil)

    wr = writeReq(ctx, { nonce = nextNonce("w"), code = codes[2], terminal_id = "T-1" })
    H.check("server.write_missing_reservation",
        wr.success == false and wr.message == "missing reservation id"
        and wr.charged == false, tostring(wr.message))
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = codes[2],
        reservation_id = "",
        terminal_id = "T-1",
    })
    H.check("server.write_empty_reservation",
        wr.message == "missing reservation id", tostring(wr.message))
    wr = writeReq(ctx, { code = codes[2], reservation_id = "r", terminal_id = "T-1" })
    H.check("server.write_missing_nonce",
        wr.message == "malformed request" and wr.charged == false
        and wr.nonce == "", tostring(wr.message))
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = "",
        reservation_id = "r2",
        terminal_id = "T-1",
    })
    H.check("server.write_empty_code",
        wr.message == "empty code" and wr.charged == false, tostring(wr.message))

    local callsBefore = w.calls
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = "23456789ABCDEFGH",
        reservation_id = "r3",
        terminal_id = "T-1",
    })
    H.check("server.write_unknown_code",
        wr.success == false and wr.message == "unknown code" and wr.charged == false,
        tostring(wr.message))
    H.check("server.write_unknown_code_skips_writer", w.calls == callsBefore)

    local singleCodes, singlePending = store.mint(1, 1, "")
    store.commitBatch(singlePending)
    local single = singleCodes[1]
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = single,
        reservation_id = "single-1",
        terminal_id = "T-2",
    })
    H.check("server.write_last_use_charged_to_zero",
        wr.success == true and wr.uses_left == 0 and wr.charged == true,
        tostring(wr.uses_left))
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = single,
        reservation_id = "single-2",
        terminal_id = "T-2",
    })
    H.check("server.write_used_up",
        wr.success == false and wr.message == "used up" and wr.charged == false,
        tostring(wr.message))

    local heldCodes, heldPending = store.mint(1, 1, "")
    store.commitBatch(heldPending)
    local held = heldCodes[1]
    store.reserve(held, "other-hold")
    callsBefore = w.calls
    wr = writeReq(ctx, {
        nonce = nextNonce("w"),
        code = held,
        reservation_id = "T-3-x",
        terminal_id = "T-3",
    })
    H.check("server.write_in_use_elsewhere",
        wr.success == false and wr.message == "in use on another terminal"
        and wr.charged == false, tostring(wr.message))
    H.check("server.write_in_use_skips_writer", w.calls == callsBefore)

    ------------------------------------------------------------------------
    -- writer failure keeps the use uncharged
    ------------------------------------------------------------------------
    H.group("server.writefail")
    store = freshStore()
    codes, pending = store.mint(1, 1, "")
    store.commitBatch(pending)
    code = codes[1]
    local wf = writerFail("no drive", "no disk drive is visible; check the drive network")
    ctx = ctxFor(store, wf)
    n = nextNonce("wf")
    resId = "T-1-" .. n
    wr = writeReq(ctx, {
        nonce = n,
        code = code,
        reservation_id = resId,
        terminal_id = "T-1",
    })
    H.check("server.writefail_message",
        wr.success == false and wr.message == "disk write error", tostring(wr.message))
    H.check("server.writefail_charged_false", wr.charged == false)
    H.check("server.writefail_detail",
        wr.detail == "no drive: no disk drive is visible; check the drive network",
        tostring(wr.detail))
    H.check("server.writefail_not_charged",
        select(1, store.lookup(code)).uses_left == 1)
    H.check("server.writefail_reservation_released",
        select(2, store.lookup(code)) == nil)
    H.check("server.writefail_logged",
        log():find("ITNP_WRITE_FAIL terminal=T-1 reservation=" .. resId
            .. " reason=no drive", 1, true) ~= nil)
    H.check("server.writefail_no_commit_log",
        log():find("ITNP_COMMIT reservation=" .. resId, 1, true) == nil)
    local grantAt = log():find("ITNP_GRANT terminal=T-1 reservation=" .. resId, 1, true)
    local failAt = log():find("ITNP_WRITE_FAIL terminal=T-1 reservation=" .. resId, 1, true)
    H.check("server.writefail_grant_precedes_failure",
        grantAt ~= nil and failAt ~= nil and grantAt < failAt,
        tostring(grantAt) .. "/" .. tostring(failAt))

    local we = writerError("drive exploded")
    ctx = ctxFor(store, we)
    n = nextNonce("wx")
    resId = "T-1-" .. n
    wr = writeReq(ctx, {
        nonce = n,
        code = code,
        reservation_id = resId,
        terminal_id = "T-1",
    })
    H.check("server.write_exception_message",
        wr.success == false and wr.message == "disk write error", tostring(wr.message))
    H.check("server.write_exception_detail",
        tostring(wr.detail):find("drive exploded", 1, true) ~= nil,
        tostring(wr.detail))
    H.check("server.write_exception_not_charged",
        select(1, store.lookup(code)).uses_left == 1)
    H.check("server.write_exception_released",
        select(2, store.lookup(code)) == nil)
    H.check("server.write_exception_logged",
        log():find("reason=exception", 1, true) ~= nil)

    ------------------------------------------------------------------------
    -- server id, fault flag and log
    ------------------------------------------------------------------------
    H.group("server.fault")
    if fs.exists(FAULT) then fs.delete(FAULT) end
    server.fault("line one\nline two")
    H.check("server.fault_file_text",
        H.readFile(FAULT) == "line one line two\n", tostring(H.readFile(FAULT)))
    H.check("server.fault_logged",
        log():find("ITNP_ERROR fault: line one line two", 1, true) ~= nil)
    fs.delete(FAULT)

    if fs.exists("/auth/itnpass_station_id") then
        fs.delete("/auth/itnpass_station_id")
    end
    local id = server.loadServerId()
    H.check("server.id_generated_len24",
        #id == 24 and id:match("^[A-Za-z0-9]+$") ~= nil, id)
    H.check("server.id_persisted",
        ((H.readFile("/auth/itnpass_station_id") or ""):gsub("%s+", "")) == id)
    H.check("server.id_stable", server.loadServerId() == id)
    H.writeFile("/auth/itnpass_station_id", "AAAAAAAAAAAAAAAAAAAAAAAA\n")
    H.check("server.id_reads_existing_file",
        server.loadServerId() == "AAAAAAAAAAAAAAAAAAAAAAAA")
    H.writeFile("/auth/itnpass_station_id", "short\n")
    local regenerated = server.loadServerId()
    H.check("server.id_bad_file_regenerated",
        #regenerated == 24 and regenerated ~= "short", regenerated)

    server.log("hello log")
    H.check("server.log_line_format",
        log():find("%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d  hello log") ~= nil,
        log())

    ------------------------------------------------------------------------
    -- modem selection
    ------------------------------------------------------------------------
    H.group("server.modem")
    local base = dofile(CONFIG)
    local side, err

    H.installPeripheral({ names = {} })
    side, err = server.pickModem(base)
    H.check("server.modem_none",
        side == nil and err == "no wired modem found - attach a wired modem and reboot",
        tostring(err))

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    side, err = server.pickModem(base)
    H.check("server.modem_single_wired", side == "left" and err == nil,
        tostring(side))

    H.installPeripheral({
        names = { "top" },
        types = { top = "modem" },
        wireless = { top = true },
    })
    side, err = server.pickModem(base)
    H.check("server.modem_wireless_only_ignored",
        side == nil and err == "no wired modem found - attach a wired modem and reboot",
        tostring(err))

    H.installPeripheral({
        names = { "back", "left" },
        types = { back = "modem", left = "modem", drive_0 = "drive" },
        remotes = { back = { "drive_0" }, left = {} },
    })
    side, err = server.pickModem(base)
    H.check("server.modem_picks_network_without_drive",
        side == "left" and err == nil, tostring(side) .. "/" .. tostring(err))

    H.installPeripheral({
        names = { "back", "left" },
        types = { back = "modem", left = "modem", d1 = "drive", d2 = "drive" },
        remotes = { back = { "d1" }, left = { "d2" } },
    })
    side, err = server.pickModem(base)
    H.check("server.modem_every_modem_has_drive",
        side == nil and err == "every wired modem carries a drive; the terminal"
            .. " network is not attached; set modem_side in /auth/itnpass_config.lua",
        tostring(err))

    H.installPeripheral({
        names = { "back", "left" },
        types = { back = "modem", left = "modem" },
        remotes = { left = {} },
        remotesError = { back = true },
    })
    side, err = server.pickModem(base)
    H.check("server.modem_unknown_remote_network",
        side == nil and err == "cannot tell which wired modem is the terminal"
            .. " network (2 wired modems, 1 could not report their network);"
            .. " set modem_side in /auth/itnpass_config.lua", tostring(err))

    H.installPeripheral({
        names = { "back", "left" },
        types = { back = "modem", left = "modem" },
        remotes = { back = {}, left = {} },
    })
    side, err = server.pickModem(base)
    H.check("server.modem_ambiguous",
        side == nil and err == "several wired modems could be the terminal network"
            .. " (back, left); set modem_side in /auth/itnpass_config.lua",
        tostring(err))

    H.installPeripheral({ names = { "top" }, types = { top = "modem" } })
    side, err = server.pickModem({ modem_side = "top", protocol = "itnpass_v1" })
    H.check("server.modem_configured", side == "top" and err == nil, tostring(side))

    H.installPeripheral({ names = { "top" }, types = { top = "drive" } })
    side, err = server.pickModem({ modem_side = "top", protocol = "itnpass_v1" })
    H.check("server.modem_configured_not_a_modem",
        side == nil and err == "modem_side 'top' is not a modem", tostring(err))

    H.installPeripheral({
        names = { "top" },
        types = { top = "modem" },
        wireless = { top = true },
    })
    side, err = server.pickModem({ modem_side = "top", protocol = "itnpass_v1" })
    H.check("server.modem_configured_wireless",
        side == nil and err == "modem_side 'top' is not a wired modem",
        tostring(err))
end

return run
