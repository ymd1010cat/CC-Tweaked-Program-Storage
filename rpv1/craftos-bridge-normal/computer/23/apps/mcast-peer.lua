--[[- mcast-peer — multicast group + broadcast domain acceptance (LAN-B side).

Config: role=host, iface=...|10.0.2.2/24, gw=10.0.2.1, mcast=1,
        mcast_groups=239.1.1.1, app=mcast-peer
Receives the relayed group traffic and the relayed broadcast, then tries to send to
the group itself: with the domain rule only allowing LAN-A>LAN-B, the router must
refuse (MCAST_DENY) -- that is the domain-isolation evidence.
Writes mcast-peer-log.txt + MCAST_PEER_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local log = fs.open("mcast-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local group = M.ip2int(node.cfg.group or "239.1.1.1")
    local res = { recv = 0, bcast = 0, other = 0 }

    node:bind(7300, function(data, src, sport)
        res.recv = res.recv + 1
        if res.recv <= 3 then w("MCAST_RECV group=%s from=%s payload=%q", M.int2ip(group), M.int2ip(src), tostring(data)) end
    end)
    node:bind(7301, function(data, src, sport)
        res.other = res.other + 1
        w("MCAST_RECV_UNJOINED group=239.9.9.9 from=%s payload=%q", M.int2ip(src), tostring(data))
    end)
    node:bind(7200, function(data, src, sport)
        res.bcast = res.bcast + 1
        w("BCAST_RECV from=%s payload=%q", M.int2ip(src), tostring(data))
    end)

    node:add_task("mcast-peer", function()
        os.sleep(tonumber(node.cfg.start_delay) or 8)
        local waited = 0
        while res.recv < 5 and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("MCAST_RECV_TOTAL n=%d after=%.2fs", res.recv, waited)

        -- try to push group traffic the other way: no LAN-B>LAN-A rule exists
        for i = 1, 3 do M.mcast_send(node, group, 7300, "from-B-" .. i, 7300) end
        w("MCAST_REVERSE_SENT n=3 (router must log MCAST_DENY)")
        os.sleep(1.5)

        local ok = res.recv >= 5 and res.bcast >= 1
        w("MCAST_PEER_RESULT recv=%d bcast=%d unjoined=%d pass=%s", res.recv, res.bcast, res.other, tostring(ok))
        w("TEST_DONE")
    end)
end
