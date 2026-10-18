--[[- nat-selftest ? NAT-lite acceptance, runs on the INTERNAL host.

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, app=nat-selftest:10.0.2.2
Flow: listen on UDP 7000 (reachable only through the router's port forward) ->
send through the masquerade to the external peer -> ping it through NAT ->
probe a non-forwarded port (must be silently dropped).
Writes nat-log.txt and ends with NAT_SELFTEST_RESULT pass=... + TEST_DONE.
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or node.cfg.peer
    local peerIP = M.ip2int(peer)
    local log = fs.open("nat-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end   -- also into rpv-log for the harness
    end
    local res = { inbound = false, xlate = false, icmp = false, drop_probe = false }
    local tokens = {}

    node.on_echo_reply = function(src, seq, rtt)
        if seq == 9001 then
            res.icmp = true
            w("NAT_PING_REPLY from=%s rtt_us=%s", M.int2ip(src), rtt and string.format("%.0f", rtt) or "?")
        end
    end

    -- the forwarded port lives here: only a DNAT'd packet can reach it
    node:bind(7000, function(data, src, sport)
        res.inbound = true
        w("NAT_INBOUND_REACHED from=%s sport=%d payload=%q", M.int2ip(src), sport, tostring(data))
        M.udp_send(node, src, 7000, sport, "pong-from-inside")
    end)

    node:add_task("nat-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 3)

        -- 1. masquerade: send to the external peer, check the reply comes back
        M.udp_send(node, peerIP, 7001, 7, "hello-outside")
        local waited = 0
        local sk = node:bind(7001, function(data, src, sport)
            tokens[#tokens + 1] = { data = data, src = src }
            if data:match("echo") then res.xlate = true end
        end)
        while not res.xlate and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("NAT_XLATE_CHECK ok=%s after=%.2fs", tostring(res.xlate), waited)

        -- 2. ICMP through NAT (the echo id is translated by the router)
        M.icmp_echo(node, peerIP, 9001, "nat", 64)
        waited = 0
        while not res.icmp and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("NAT_ICMP_CHECK ok=%s after=%.2fs", tostring(res.icmp), waited)

        -- 3. a port with no forward rule must be dropped silently by the router
        M.udp_send(node, M.ip2int("10.0.2.1"), 7002, 7002, "should-not-arrive")
        os.sleep(1.5)
        w("NAT_DROP_PROBE sent_to=10.0.2.1:7002 (router must log NAT_DROP)")

        -- 4. wait for the external host's inbound test (PEER_INBOUND)
        waited = 0
        while not res.inbound and waited < 8 do os.sleep(0.5); waited = waited + 0.5 end
        w("NAT_INBOUND_CHECK ok=%s after=%.2fs", tostring(res.inbound), waited)

        local ok = res.xlate and res.icmp and res.inbound
        w("NAT_SELFTEST_RESULT xlate=%s icmp=%s inbound=%s pass=%s", tostring(res.xlate),
            tostring(res.icmp), tostring(res.inbound), tostring(ok))
        w("TEST_DONE")
    end)
end
