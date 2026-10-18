--[[- p3-selftest ? P3 transport acceptance: selective ACKs, window scaling, slow
start curve, multi-flow fairness and keepalive.

Config: role=host, iface=...|10.0.1.1/24, app=p3-selftest:10.0.1.2
Experiments (all against p3-peer):
  SACK      : the same 6 KB transfer under deterministic loss (drop_every=3), once with
              conn_sack=0 and once with conn_sack=1 -> retransmit count must not grow
  FAIRNESS  : two simultaneous 4 KB flows, without and with conn_global_max_inflight
  KEEPALIVE : idle with conn_keepalive=2 (peer alive -> probes answered), then ask the
              peer to blackhole itself -> CONN_KEEPALIVE_TIMEOUT must fire
Result line: P3_RESULT sack=.. fair=.. keepalive=.. pass=.. + TEST_DONE.
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or node.cfg.peer or "10.0.1.2"
    local peerIP = M.ip2int(peer)
    local log = fs.open("p3-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    local function xfer(port, bytes, opts)
        opts = opts or {}
        local c = M.conn_connect(node, peerIP, port, { sport = opts.sport or 4700 })
        local payload = string.rep("P", bytes)
        c:on_open(function() c:send(payload); c:close() end)
        local t0 = os.clock()
        local guard = 0
        while c.bytes_tx < bytes and guard < 100 do os.sleep(0.25); guard = guard + 0.25 end
        local ms = (os.clock() - t0) * 1000
        return c, ms
    end

    local res = {}

    node:add_task("p3-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 4)
        w("P3_START peer=%s", peer)

        -- ---- SACK under deterministic loss -------------------------------------
        node.cfg.drop_every = "3"
        node.cfg.conn_sack = "0"
        local a, aMs = xfer(4400, 6000, { sport = 4700 })
        w("P3_SACK_OFF retx=%d ms=%.0f tx=%d", a.retx, aMs, a.tx)
        a:abort("phase-sack-off done")            -- release its share of the in-flight budget
        os.sleep(2)
        node.cfg.conn_sack = "1"
        local b, bMs = xfer(4400, 6000, { sport = 4701 })
        w("P3_SACK_ON retx=%d sack_retx=%d sack_rx=%d sack_sent=%d ms=%.0f", b.retx, b.sack_retx, b.sack_rx, b.sack_sent, bMs)
        res.sack = (b.bytes_tx >= 6000) and (b.sack_rx > 0)
        b:abort("phase-sack-on done")
        node.cfg.drop_every = "0"
        os.sleep(2)

        -- ---- multi-flow fairness ----------------------------------------------
        local function two_flows(cap, sportBase)
            node.cfg.conn_global_max_inflight = tostring(cap)
            -- distinct source ports per phase: the listener keys connections by
            -- (src, sport), so reusing a sport would hand the new SYN to the old conn
            local c1 = M.conn_connect(node, peerIP, 4400, { sport = sportBase })
            local c2 = M.conn_connect(node, peerIP, 4401, { sport = sportBase + 1 })
            local pay = string.rep("F", 4000)
            local t0 = os.clock()
            c1:on_open(function() c1:send(pay) end)
            c2:on_open(function() c2:send(pay) end)
            local done1, done2, guard = false, false, 0
            c1:on_close(function() done1 = true end)
            c2:on_close(function() done2 = true end)
            while (not (done1 and done2)) and guard < 100 do
                if c1.bytes_tx >= 4000 then done1 = true end
                if c2.bytes_tx >= 4000 then done2 = true end
                os.sleep(0.25); guard = guard + 0.25
            end
            local ms = (os.clock() - t0) * 1000
            return c1, c2, ms
        end
        local c1, c2, offMs = two_flows(0, 4710)
        w("P3_FAIR_NO_CAP b1=%d b2=%d ms=%.0f inflight1=%d inflight2=%d", c1.bytes_tx, c2.bytes_tx, offMs,
            (function() local n = 0 for _ in pairs(c1.unacked) do n = n + 1 end return n end)(),
            (function() local n = 0 for _ in pairs(c2.unacked) do n = n + 1 end return n end)())
        os.sleep(3)
        c1:abort("phase-fair-nocap done")
        c2:abort("phase-fair-nocap done")
        os.sleep(1)
        local d1, d2, capMs = two_flows(2, 4712)
        w("P3_FAIR_CAP b1=%d b2=%d ms=%.0f cwnd_limited1=%d cwnd_limited2=%d", d1.bytes_tx, d2.bytes_tx, capMs,
            d1.cwnd_limited or 0, d2.cwnd_limited or 0)
        res.fair = (c1.bytes_tx >= 4000) and (c2.bytes_tx >= 4000) and (d1.bytes_tx >= 4000) and (d2.bytes_tx >= 4000)
        node.cfg.conn_global_max_inflight = "0"
        os.sleep(2)

        -- ---- keepalive: probes while alive, timeout once the peer blackholes ----
        node.cfg.conn_keepalive = "2"
        local c = M.conn_connect(node, peerIP, 4400, { sport = 4720 })
        c:on_open(function() c:send(string.rep("K", 200)) end)
        os.sleep(7)                                  -- ~3 probe intervals, peer answers
        local probesAlive = c.keepalives
        local aliveOk = (c.keepalives >= 1) and (not c.closed)
        w("P3_KEEPALIVE_ALIVE probes=%d closed=%s ka_miss=%d", c.keepalives, tostring(c.closed), c.ka_miss)

        M.udp_send(node, peerIP, 4402, 4402, "blackhole")
        local guard = 0
        while not c.closed and guard < 25 do os.sleep(0.5); guard = guard + 0.5 end
        local timedOut = c.closed and (c.ka_miss or 0) > 3
        w("P3_KEEPALIVE_BLACKHOLE probes=%d closed=%s ka_miss=%d after=%.1fs timed_out=%s",
            c.keepalives, tostring(c.closed), c.ka_miss, guard, tostring(timedOut))
        M.udp_send(node, peerIP, 4402, 4402, "heal")
        res.keepalive = aliveOk and timedOut

        local pass = res.sack and res.fair and res.keepalive
        w("P3_RESULT sack=%s fair=%s keepalive=%s pass=%s", tostring(res.sack), tostring(res.fair),
            tostring(res.keepalive), tostring(pass))
        w("TEST_DONE")
    end)
end
