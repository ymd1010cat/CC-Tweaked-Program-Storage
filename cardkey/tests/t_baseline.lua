-- t_baseline.lua -- pass-mode baseline of the modules the free mode does not
-- touch, plus the real disk transaction endpoint.
--
-- The point of this file is regression: sha256, the card key database, the disk
-- writer failure texts, the network check, the session table and the client's
-- transport errors must keep behaving exactly as they did before the run mode
-- existed. Everything here runs in the paid mode (no mode file, no mode log).

local function run(H)
    local SHA = "/sha256.lua"
    local STORE = "/auth/cardkey_store.lua"
    local WRITER = "/system/disk_writer.lua"
    local NETCHECK = "/system/netcheck.lua"
    local SESSION = "/auth/session.lua"
    local CLIENT = "/auth/cardkey_client.lua"

    local realDofile = dofile

    local function readFile(path)
        return H.readFile(path)
    end

    ------------------------------------------------------------------------
    -- sha256: the known answer the whole database rests on
    ------------------------------------------------------------------------
    H.group("baseline.sha256")
    local sha = realDofile(SHA)
    H.check("baseline.sha256.abc",
        sha.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        tostring(sha.hash("abc")))
    H.check("baseline.sha256.empty",
        sha.hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        tostring(sha.hash("")))
    H.check("baseline.sha256.hex_len", #sha.hash("cardkey") == 64, #sha.hash("cardkey"))

    ------------------------------------------------------------------------
    -- store: normalisation, fingerprint, charge accounting, revoke
    ------------------------------------------------------------------------
    H.group("baseline.store")
    H.rmTree("/cardkeys")
    fs.delete("/auth/cardkeys.db")

    local store = realDofile(STORE)
    H.check("baseline.store.normalize_16", store.normalize(string.rep("2", 16)) ~= nil)
    H.check("baseline.store.normalize_15_rejected",
        store.normalize(string.rep("2", 15)) == nil)
    H.check("baseline.store.normalize_confusables_rejected",
        store.normalize("0O1I" .. string.rep("2", 12)) == nil)

    local stats0 = store.stats()
    H.check("baseline.store.empty_db_zero",
        stats0.total == 0 and stats0.alive == 0, tostring(stats0.total))

    local codes = store.generate(2, 2, "baseline")
    H.check("baseline.store.generate_count", type(codes) == "table" and #codes == 2,
        type(codes) == "table" and #codes or tostring(codes))
    local code = codes and codes[1]
    H.check("baseline.store.generate_plaintext_len",
        type(code) == "string" and #code == 16, type(code) == "string" and #code or "?")

    local fp = store.fingerprint(code)
    H.check("baseline.store.fingerprint_stable", fp == store.fingerprint(code))
    H.check("baseline.store.fingerprint_distinct", fp ~= store.fingerprint(codes[2]))

    local rec, reason = store.lookup(code)
    H.check("baseline.store.lookup_ok", rec ~= nil, tostring(reason))
    H.check("baseline.store.lookup_uses", rec ~= nil and rec.uses_left == 2,
        rec and rec.uses_left)
    H.check("baseline.store.lookup_unknown",
        select(2, store.lookup(string.rep("3", 16))) == "unknown code")

    local grant = store.reserve(code, "res-1")
    H.check("baseline.store.reserve_ok", grant ~= nil)
    H.check("baseline.store.reserve_reports_fp", grant ~= nil and grant.fp == fp,
        grant and tostring(grant.fp))
    H.check("baseline.store.reserve_twice_refused",
        select(2, store.reserve(code, "res-1")) == "duplicate request")
    local committed, charged = store.commit("res-1")
    H.check("baseline.store.commit_charges", committed ~= nil and charged == true)
    H.check("baseline.store.commit_decrements",
        committed ~= nil and committed.uses_left == 1, committed and committed.uses_left)
    H.check("baseline.store.commit_unknown",
        select(2, store.commit("no-such")) == "no such reservation")

    store.reserve(code, "res-2")
    H.check("baseline.store.release_ok", store.release("res-2") == true)
    H.check("baseline.store.release_frees",
        select(2, store.lookup(code)) == nil, tostring(select(2, store.lookup(code))))

    H.check("baseline.store.revoke_ok", store.revoke(fp) == true)
    H.check("baseline.store.revoked_refused",
        select(2, store.lookup(code)) == "revoked")
    H.check("baseline.store.unrevoke_ok", store.unrevoke(code) == true)
    H.check("baseline.store.unrevoked_lookup", store.lookup(code) ~= nil)

    local stats1 = store.stats()
    H.check("baseline.store.stats_total", stats1.total == 2, stats1.total)
    H.check("baseline.store.stats_remaining", stats1.remaining == 3, stats1.remaining)

    ------------------------------------------------------------------------
    -- disk writer: failure texts before any hardware is attached
    ------------------------------------------------------------------------
    H.group("baseline.writer")
    local writer = realDofile(WRITER)
    H.rmTree("/payload")

    local status = writer.status()
    H.check("baseline.writer.status_text", type(status.state) == "string" and
        #status.state > 0, tostring(status.state))
    local okWrite, reason = writer.write()
    H.check("baseline.writer.no_payload", okWrite == false and reason == "no payload",
        tostring(reason))

    H.ensureDir("/payload")
    H.writeFile("/payload/demo.txt", "cardkey payload\n")
    okWrite, reason = writer.write()
    H.check("baseline.writer.no_drive", okWrite == false and reason == "no drive",
        tostring(reason))
    local _, _, detail = writer.write()
    H.check("baseline.writer.no_drive_detail",
        detail == "no disk drive is visible; check the drive network", tostring(detail))

    ------------------------------------------------------------------------
    -- disk writer: the real copy transaction (paid and free use the same one)
    ------------------------------------------------------------------------
    H.group("baseline.writer.copy")
    H.ensureDir("/disk")
    H.installPeripheral({ names = { "drive_0" }, types = { drive_0 = "drive" } })
    H.installDisk({ presentDefault = true, mountPath = "/disk", total = 1000000,
        used = 0 })

    local wrote, info = writer.write()
    H.check("baseline.writer.copy_ok", wrote == true, tostring(info))
    H.check("baseline.writer.copy_files", wrote == true and info.files == 1,
        wrote == true and info.files or "?")
    H.check("baseline.writer.copy_bytes",
        wrote == true and info.bytes == #"cardkey payload\n",
        wrote == true and info.bytes or "?")
    H.check("baseline.writer.copy_mount", wrote == true and info.mount == "/disk",
        wrote == true and tostring(info.mount))
    H.check("baseline.writer.copy_content",
        readFile("/disk/demo.txt") == "cardkey payload\n",
        tostring(readFile("/disk/demo.txt")))

    -- A second run overwrites the same file and still reports one file.
    H.writeFile("/payload/demo.txt", "second\n")
    local wrote2, info2 = writer.write()
    H.check("baseline.writer.copy_overwrites",
        wrote2 == true and info2.files == 1 and readFile("/disk/demo.txt") == "second\n")

    -- Disk full is refused before anything is written.
    H.writeFile("/payload/demo.txt", string.rep("x", 64))
    H.installPeripheral({ names = { "drive_0" }, types = { drive_0 = "drive" } })
    H.installDisk({ presentDefault = true, mountPath = "/disk", total = 10, used = 0 })
    local fullOk, fullReason, fullDetail = writer.write()
    H.check("baseline.writer.disk_full_ok", fullOk == false and fullReason == "disk full",
        tostring(fullReason))
    H.check("baseline.writer.disk_full_detail",
        type(fullDetail) == "string" and fullDetail:find("free", 1, true) ~= nil,
        tostring(fullDetail))
    H.check("baseline.writer.disk_full_no_write",
        readFile("/disk/demo.txt") == "second\n", tostring(readFile("/disk/demo.txt")))

    H.rmTree("/disk")
    H.rmTree("/payload")

    ------------------------------------------------------------------------
    -- netcheck: the window still counts distinct servers
    ------------------------------------------------------------------------
    H.group("baseline.netcheck")
    local netcheck = realDofile(NETCHECK)

    H.resetStubs()
    local netOk, ids, netReason = netcheck.check(3)
    H.check("baseline.netcheck.no_modem", netOk == false and netReason == "no modem",
        tostring(netReason))

    H.installPeripheral({ names = { "back" }, types = { back = "modem" },
        wireless = { back = true } })
    netOk, ids, netReason = netcheck.check(3)
    H.check("baseline.netcheck.wireless_refused",
        netOk == false and netReason == "wireless modem", tostring(netReason))

    local function heartbeat(rec, id)
        rec.onTransmit = nil
        H.pushEvent("modem_message", "left", 3, 3, {
            protocol = "cardkey_v1",
            type = "heartbeat",
            server_id = id,
        })
    end

    H.resetStubs()
    local rec = H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeat(rec, "SRV-A")
    heartbeat(rec, "SRV-A")
    netOk, ids, netReason = netcheck.check(3)
    H.check("baseline.netcheck.one_server", netOk == true and netReason == nil,
        tostring(netReason))
    H.check("baseline.netcheck.one_server_id", ids["SRV-A"] == true)

    H.resetStubs()
    rec = H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeat(rec, "SRV-A")
    heartbeat(rec, "SRV-B")
    netOk, ids, netReason = netcheck.check(3)
    H.check("baseline.netcheck.two_servers",
        netOk == false and netReason == "multiple servers: 2", tostring(netReason))

    H.resetStubs()
    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    netOk, ids, netReason = netcheck.check(3)
    H.check("baseline.netcheck.no_server",
        netOk == false and netReason == "no card key server detected", tostring(netReason))

    H.resetStubs()

    ------------------------------------------------------------------------
    -- session table: create/validate/destroy and the 10 minute TTL
    ------------------------------------------------------------------------
    H.group("baseline.session")
    local session = realDofile(SESSION)
    local user = { name = "cardkey", code = "23456789ABCDEFGH" }
    local token = session.create(user)
    H.check("baseline.session.create", type(token) == "string" and #token > 0,
        type(token))
    H.check("baseline.session.invalid_user", select(2, session.create("nope")) ==
        "invalid user")
    local record = session.validate(token)
    H.check("baseline.session.validate", record ~= nil and record.user == user)
    H.check("baseline.session.validate_unknown",
        select(2, session.validate("nope")) == "invalid session")

    H.setNow(H.now + 600001)
    H.check("baseline.session.expires",
        select(2, session.validate(token)) == "session expired")
    H.check("baseline.session.destroy_missing", session.destroy(token) == false)

    ------------------------------------------------------------------------
    -- client: transport errors are unchanged in the paid mode
    ------------------------------------------------------------------------
    H.group("baseline.client")
    H.resetStubs()
    local client = realDofile(CLIENT)
    H.check("baseline.client.pass_mode", client.mode() == "pass", tostring(client.mode()))
    local ok, clientReason = client.check("23456789ABCDEFGH")
    H.check("baseline.client.no_modem", ok == false and clientReason == "no modem",
        tostring(clientReason))

    H.installPeripheral({ names = { "left" }, types = { left = "modem" },
        wireless = { left = true } })
    ok, clientReason = client.check("23456789ABCDEFGH")
    H.check("baseline.client.wireless_refused",
        ok == false and clientReason == "wireless modem not allowed",
        tostring(clientReason))

    -- Nobody answers: the reply loop times out on its own timer.
    H.resetStubs()
    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    client = realDofile(CLIENT)
    H.pushEvent("modem_message", "left", 3, 3, {
        protocol = "cardkey_v1",
        type = "heartbeat",
        server_id = "SRV-A",
    })
    ok, clientReason = client.check("23456789ABCDEFGH")
    H.check("baseline.client.timeout", ok == false and clientReason == "server timeout",
        tostring(clientReason))

    -- An answer from a server netcheck never saw is refused, not accepted.
    H.resetStubs()
    local answerRec = H.installPeripheral({ names = { "left" }, types = { left = "modem" },
        onTransmit = function(HH, name, channel, replyChannel, message)
            if message.type == "verify_request" then
                HH.pushEvent("modem_message", name, replyChannel, 3, {
                    protocol = "cardkey_v1",
                    type = "verify_response",
                    server_id = "SRV-EVIL",
                    nonce = message.nonce,
                    success = true,
                    message = "OK",
                    uses_left = 9,
                })
            end
        end })
    client = realDofile(CLIENT)
    H.pushEvent("modem_message", "left", 3, 3, {
        protocol = "cardkey_v1",
        type = "heartbeat",
        server_id = "SRV-A",
    })
    ok, clientReason = client.check("23456789ABCDEFGH")
    H.check("baseline.client.unknown_server",
        ok == false and clientReason == "answer from unknown server",
        tostring(clientReason))
    H.check("baseline.client.sent_once", #answerRec.sent == 1, #answerRec.sent)
    H.check("baseline.client.sent_code", #answerRec.sent == 1 and
        answerRec.sent[1].message.code == "23456789ABCDEFGH",
        #answerRec.sent > 0 and tostring(answerRec.sent[1].message.code) or "none")

    H.resetStubs()
end

return run
