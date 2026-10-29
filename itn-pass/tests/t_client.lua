-- t_client.lua -- itnpass_client: request shape and reply validation.
--
-- netcheck runs inside the client, so every exchange is fed the heartbeats a
-- terminal would hear first; replies are pushed from the fake modem's transmit
-- hook, exactly where a real answer would arrive.

local function run(H)
    H.group("client")
    local CLIENT = "/auth/itnpass_client.lua"
    local CODE = "23456789ABCDEFGH"
    local FORMATTED = "2345-6789-ABCD-EFGH"

    local function newClient()
        return dofile(CLIENT)
    end

    local function heartbeats(ids)
        for _, id in ipairs(ids) do
            H.pushEvent("modem_message", "left", 33, 33, {
                protocol = "itnpass_v1",
                type = "heartbeat",
                server_id = id,
            })
        end
    end

    local function wired(opts)
        opts = opts or {}
        return H.installPeripheral({
            names = { "left" },
            types = { left = "modem" },
            wireless = opts.wireless and { left = true } or {},
            transmitError = opts.transmitError,
            onTransmit = opts.onTransmit,
        })
    end

    local function answered(replyFor)
        return function(HH, name, channel, replyChannel, message)
            local reply = replyFor(message)
            if reply then
                HH.pushEvent("modem_message", name, replyChannel, 33, reply)
            end
        end
    end

    local function verifyReply(fields)
        return function(message)
            local reply = {
                protocol = "itnpass_v1",
                type = "verify_response",
                server_id = "SRV-A",
                nonce = message.nonce,
                success = true,
                message = "OK",
                uses_left = 2,
                uses_total = 3,
            }
            for k, v in pairs(fields or {}) do
                reply[k] = v
            end
            return reply
        end
    end

    local ok, reason, rec, c

    ------------------------------------------------------------------------
    -- input validation and modem selection
    ------------------------------------------------------------------------
    wired()
    c = newClient()
    ok, reason = c.check("   ")
    H.check("client.check_empty_code", ok == false and reason == "empty code",
        tostring(reason))
    ok, reason = c.check(nil)
    H.check("client.check_nil_code", ok == false and reason == "empty code",
        tostring(reason))
    ok, reason = c.check(42)
    H.check("client.check_non_string_code", ok == false and reason == "empty code",
        tostring(reason))

    H.installPeripheral({ names = {} })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.no_modem", ok == false and reason == "no modem",
        tostring(reason))

    wired({ wireless = true })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.wireless_modem_refused", reason == "wireless modem not allowed",
        tostring(reason))

    ------------------------------------------------------------------------
    -- network check gating
    ------------------------------------------------------------------------
    rec = wired()
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.network_no_server",
        ok == false and reason == "network check: no card key server detected",
        tostring(reason))
    H.check("client.network_no_server_no_transmit", #rec.sent == 0, #rec.sent)

    rec = wired()
    heartbeats({ "SRV-A", "SRV-B" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.network_multiple_servers",
        reason == "network check: multiple servers: 2", tostring(reason))

    ------------------------------------------------------------------------
    -- verify_request / verify_response
    ------------------------------------------------------------------------
    rec = wired({ onTransmit = answered(verifyReply()) })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(" " .. FORMATTED .. " ")
    H.check("client.verify_ok", ok == true, tostring(reason))
    H.check("client.verify_info",
        reason.uses_left == 2 and reason.uses_total == 3,
        textutils.serialize(reason or {}))

    local sent = rec.sent[1]
    local req = sent.message
    H.check("client.request_protocol", req.protocol == "itnpass_v1", req.protocol)
    H.check("client.request_type", req.type == "verify_request", req.type)
    -- The client only trims: normalising the code is the server's job.
    H.check("client.request_code_trimmed", req.code == FORMATTED, tostring(req.code))
    H.check("client.request_nonce",
        type(req.nonce) == "string" and #req.nonce > 0, tostring(req.nonce))
    H.check("client.request_terminal_id",
        req.terminal_id == tostring(os.getComputerID()), tostring(req.terminal_id))
    H.check("client.request_no_reservation", req.reservation_id == nil,
        tostring(req.reservation_id))
    H.check("client.request_channel", sent.channel == 33, sent.channel)
    H.check("client.request_reply_channel",
        sent.replyChannel >= 1000 and sent.replyChannel <= 9999, sent.replyChannel)
    H.check("client.request_channel_closed", rec.closes >= 1, rec.closes)

    ------------------------------------------------------------------------
    -- write_request / write_response
    ------------------------------------------------------------------------
    rec = wired({
        onTransmit = answered(function(message)
            if message.type ~= "write_request" then
                return nil
            end
            return {
                protocol = "itnpass_v1",
                type = "write_response",
                server_id = "SRV-A",
                nonce = message.nonce,
                success = true,
                message = "OK",
                charged = true,
                uses_left = 1,
                uses_total = 2,
                files = 3,
                dirs = 1,
                bytes = 9000,
            }
        end),
    })
    heartbeats({ "SRV-A" })
    c = newClient()
    local wok, winfo = c.write(FORMATTED)
    H.check("client.write_ok", wok == true, tostring(winfo))
    H.check("client.write_info",
        winfo.charged == true and winfo.files == 3 and winfo.dirs == 1
        and winfo.bytes == 9000 and winfo.uses_left == 1 and winfo.uses_total == 2,
        textutils.serialize(winfo or {}))
    req = rec.sent[1].message
    H.check("client.write_type", req.type == "write_request", req.type)
    H.check("client.write_reservation_id",
        req.reservation_id == req.terminal_id .. "-" .. req.nonce,
        tostring(req.reservation_id))

    rec = wired()
    c = newClient()
    local wok2, wreason = c.write("")
    H.check("client.write_empty_code", wok2 == false and wreason == "empty code",
        tostring(wreason))
    H.check("client.write_empty_code_no_transmit", #rec.sent == 0, #rec.sent)

    ------------------------------------------------------------------------
    -- reply validation
    ------------------------------------------------------------------------
    rec = wired({ onTransmit = answered(verifyReply({ server_id = "SRV-EVIL" })) })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.unknown_server_rejected",
        ok == false and reason == "answer from unknown server", tostring(reason))
    ok, reason = c.check(FORMATTED)
    H.check("client.network_invalidated_after_unknown_server",
        reason == "network check: no card key server detected", tostring(reason))

    rec = wired()
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.timeout", ok == false and reason == "server timeout",
        tostring(reason))

    rec = wired({ onTransmit = answered(verifyReply({ nonce = "bogus-nonce" })) })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.wrong_nonce_ignored",
        ok == false and reason == "server timeout", tostring(reason))

    rec = wired({
        onTransmit = answered(function(message)
            return {
                protocol = "itnpass_v1",
                type = "write_response",
                server_id = "SRV-A",
                nonce = message.nonce,
                success = true,
                message = "OK",
            }
        end),
    })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.wrong_type_ignored",
        ok == false and reason == "server timeout", tostring(reason))

    rec = wired({
        onTransmit = answered(function(message)
            return {
                protocol = "other_v1",
                type = "verify_response",
                server_id = "SRV-A",
                nonce = message.nonce,
                success = true,
                message = "OK",
            }
        end),
    })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.wrong_protocol_ignored",
        ok == false and reason == "server timeout", tostring(reason))

    ------------------------------------------------------------------------
    -- refused replies
    ------------------------------------------------------------------------
    rec = wired({ onTransmit = answered(verifyReply({ success = false,
        message = "unknown code" })) })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.refused_reason",
        ok == false and reason == "unknown code", tostring(reason))

    rec = wired({ onTransmit = answered(verifyReply({ success = false,
        message = "" })) })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.refused_empty_message", reason == "refused", tostring(reason))

    rec = wired({
        onTransmit = answered(function(message)
            return {
                protocol = "itnpass_v1",
                type = "write_response",
                server_id = "SRV-A",
                nonce = message.nonce,
                success = false,
                message = "disk write error",
                detail = "no drive: insert a disk",
            }
        end),
    })
    heartbeats({ "SRV-A" })
    c = newClient()
    local wok3, wreason3, wdetail = c.write(FORMATTED)
    H.check("client.write_refused_reason",
        wok3 == false and wreason3 == "disk write error", tostring(wreason3))
    H.check("client.write_refused_detail",
        wdetail == "no drive: insert a disk", tostring(wdetail))

    ------------------------------------------------------------------------
    -- transport failure and the cached server set
    ------------------------------------------------------------------------
    rec = wired({ transmitError = true })
    heartbeats({ "SRV-A" })
    c = newClient()
    ok, reason = c.check(FORMATTED)
    H.check("client.transmit_error", ok == false and reason == "no modem",
        tostring(reason))

    rec = wired({ onTransmit = answered(verifyReply()) })
    heartbeats({ "SRV-A" })
    c = newClient()
    local okFirst = c.check(FORMATTED)
    local okSecond, secondReason = c.check(FORMATTED)
    H.check("client.server_set_cached", okFirst == true and okSecond == true,
        tostring(secondReason))
    H.check("client.server_set_cached_sends_two_requests", #rec.sent == 2, #rec.sent)
    H.check("client.nonce_unique_per_request",
        rec.sent[1].message.nonce ~= rec.sent[2].message.nonce)
end

return run
