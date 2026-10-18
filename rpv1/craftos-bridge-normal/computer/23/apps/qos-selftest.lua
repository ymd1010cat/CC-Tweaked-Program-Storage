--[[- qos-selftest ? QoS acceptance: the same conn transfer under the same bulk
flood, once WITHOUT QoS and once WITH QoS enabled on the RECEIVER.

The contention this exercises is on the receiver's egress: the flood makes it emit
hundreds of echo replies, and its conn ACKs have to get out through the same modem.
With qos=1 the ACKs (priority 0) jump ahead of the bulk replies (priority 2).

Config: role=host, iface=...|10.0.1.1/24, app=qos-selftest:10.0.1.2
Phases: A = qos off, B = after telling the peer to enable qos (UDP 4401 "qos-on").
Result: QOS_RESULT off_retx=.. off_ms=.. on_retx=.. on_ms=.. peer_high=.. pass=..
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or node.cfg.peer or "10.0.1.2"
    local peerIP = M.ip2int(peer)
    local log = fs.open("qos-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    local bytes = tonumber(node.cfg.conn_bytes) or 4000
    local floodN = tonumber(node.cfg.flood_packets) or 300
    local sport = 4500

    local function flood(tag)
        for i = 1, floodN do
            M.udp_send(node, peerIP, 7, 7, string.rep("x", 180))
            if i % 5 == 0 then os.sleep(0) end
        end
        w("QOS_FLOOD %s n=%d bytes=%d", tag, floodN, floodN * 180)
    end

    local function transfer(tag)
        local c = M.conn_connect(node, peerIP, 4400, { sport = sport })
        sport = sport + 1
        local done = false
        c:on_open(function()
            c:send(string.rep("Q", bytes))
            c:close()
        end)
        c:on_close(function() done = true end)
        local t0 = os.clock()
        local guard = 0
        -- completion = every payload byte handed to the link (waiting for the peer FIN
        -- would just measure the peer application, not the transfer)
        while c.bytes_tx < bytes and guard < 60 do os.sleep(0.25); guard = guard + 0.25 end
        local ms = (os.clock() - t0) * 1000
        c:log_stats(tag)
        return { ms = ms, retx = c.retx, done = (c.bytes_tx >= bytes), bytes_tx = c.bytes_tx, cwnd = c.cwnd, srtt = c.srtt }
    end

    -- receive the echoes ourselves: an unbound port would log one line per echo and
    -- that file I/O would dominate the measurement
    local echoes = 0
    node:bind(7, function(data, src, sport) echoes = echoes + 1 end)

    node:add_task("qos-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 4)
        w("QOS_START peer=%s conn_bytes=%d flood=%d mss=%s", peer, bytes, floodN, tostring(node.cfg.conn_mss))

        -- phase A: baseline, QoS off everywhere
        node:add_task("flood-a", function() os.sleep(0.5); flood("A") end)
        local a = transfer("A")
        w("QOS_PHASE_A retx=%d ms=%.0f cwnd=%d bytes_tx=%d done=%s", a.retx, a.ms, a.cwnd, a.bytes_tx, tostring(a.done))
        os.sleep(5)

        -- phase B: the receiver turns QoS on (its ACKs must beat its echo replies)
        M.udp_send(node, peerIP, 4401, 4401, "qos-on")
        os.sleep(1.5)
        node:add_task("flood-b", function() os.sleep(0.5); flood("B") end)
        local b = transfer("B")
        w("QOS_PHASE_B retx=%d ms=%.0f cwnd=%d bytes_tx=%d done=%s", b.retx, b.ms, b.cwnd, b.bytes_tx, tostring(b.done))
        os.sleep(5)

        -- the peer reports its own QoS counters in its result line; the sender only
        -- asserts the transfer itself got no worse
        local ok = a.done and b.done and b.retx <= a.retx and b.ms <= a.ms * 1.5
        w("QOS_RESULT off_retx=%d off_ms=%.0f on_retx=%d on_ms=%.0f pass=%s", a.retx, a.ms, b.retx, b.ms, tostring(ok))
        w("TEST_DONE")
    end)
end
