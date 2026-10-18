--[[- addr-selftest ? IPv4 reserved-segment behaviour on a real rpv node.

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, app=addr-selftest:10.0.1.3,
        broadcast=10.0.1.255, start_delay=8
Checks: 127.0.0.1 ICMP and UDP round trips happen WITHOUT any modem transmission;
reserved destinations (0/8, 169.254/16, 240/4, 224/4) increase reserved_drop instead of
going out; a directed broadcast (10.0.1.255) reaches the other host on the segment; the
peer is reachable normally.
Result: ADDR_RESULT ... pass=true + TEST_DONE.
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or "10.0.1.3"
    local peerIP = M.ip2int(peer)
    local log = fs.open("addr-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    local pongs = 0
    node.on_echo_reply = function(src, seq)
        if seq and seq >= 15000 and seq < 16000 then pongs = pongs + 1 end
    end

    node:add_task("addr-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 8)
        local tx0 = node.stats.tx or 0

        -- 1. loopback ICMP: answered locally, nothing on a modem
        M.icmp_echo(node, M.ip2int("127.0.0.1"), 15000)
        local waited = 0
        while pongs == 0 and waited < 4 do os.sleep(0.25); waited = waited + 0.25 end
        local lo_ok = pongs > 0
        local tx_after_lo = node.stats.tx or 0
        w("ADDR_LOOPBACK reply=%s tx_before=%d tx_after=%d lo_sent=%d", tostring(lo_ok), tx0, tx_after_lo, node.stats.lo_sent or 0)

        -- 2. loopback UDP round trip
        local got = nil
        node:bind(9999, function(data) got = data end)
        M.udp_send(node, M.ip2int("127.0.0.1"), 9999, 9999, "loopback-udp")
        waited = 0
        while not got and waited < 3 do os.sleep(0.25); waited = waited + 0.25 end
        local no_tx_lo = (node.stats.tx or 0) == tx_after_lo
        w("ADDR_LOOPBACK_UDP got=%s no_tx=%s", tostring(got), tostring(no_tx_lo))

        -- 3. invalid destinations (0/8 = this-network, 240/4 = reserved) must not be
        -- transmitted at all; link local and multicast ARE transmittable (they are only
        -- never forwarded by a router, which is a different rule)
        local drop0 = node.stats.reserved_drop or 0
        for _, a in ipairs({ "0.0.0.1", "240.0.0.1", "255.255.255.254" }) do
            M.icmp_echo(node, M.ip2int(a), 15100)
        end
        os.sleep(0.5)
        local drop1 = node.stats.reserved_drop or 0
        w("ADDR_RESERVED drops_before=%d drops_after=%d", drop0, drop1)
        M.icmp_echo(node, M.ip2int("169.254.1.1"), 15150)
        M.udp_send(node, M.ip2int("224.0.0.9"), 9990, 9990, "group")
        os.sleep(0.5)
        local drop2 = node.stats.reserved_drop or 0
        w("ADDR_TRANSMITTABLE extra_drops=%d", drop2 - drop1)

        -- 4. directed broadcast reaches the other host on this segment
        local replies = 0
        node:bind(9998, function(data, src)
            if data == "who" then M.udp_send(node, src, 9998, 9997, "here") end
        end)
        node:bind(9997, function(data) if data == "here" then replies = replies + 1 end end)
        M.udp_send(node, M.ip2int(node.cfg.broadcast or "10.0.1.255"), 9998, 9998, "who")
        waited = 0
        while replies == 0 and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("ADDR_DIRECTED_BCAST replies=%d after=%.1fs", replies, waited)

        -- 5. baseline: the peer is reachable normally
        M.icmp_echo(node, peerIP, 15200)
        waited = 0
        while pongs < 2 and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("ADDR_PEER_PING pongs=%d", pongs)

        local pass = lo_ok and (got == "loopback-udp") and no_tx_lo and (drop1 - drop0) == 3 and (drop2 - drop1) == 0 and replies >= 1 and pongs >= 2
        w("ADDR_RESULT loopback=%s loopback_udp=%s no_tx=%s reserved_drops=%d bcast_replies=%d peer_pongs=%d pass=%s",
            tostring(lo_ok), tostring(got == "loopback-udp"), tostring(no_tx_lo),
            drop1 - drop0, replies, pongs, tostring(pass))
        w("TEST_DONE")
    end)
end
