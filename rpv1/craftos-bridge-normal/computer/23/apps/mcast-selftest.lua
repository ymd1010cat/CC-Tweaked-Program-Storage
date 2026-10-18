--[[- mcast-selftest — multicast group + broadcast domain acceptance (LAN-A side).

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, mcast=1,
        mcast_groups=239.1.1.1, app=mcast-selftest
Sends: a burst to the joined group (the router must forward it and rate-limit the
burst), one packet to a group nobody joined, and a limited broadcast (relayed only
because bcast_relay allows LAN-A>LAN-B).
Writes mcast-log.txt + MCAST_SELFTEST_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local log = fs.open("mcast-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local group = M.ip2int(node.cfg.group or "239.1.1.1")
    local burst = tonumber(node.cfg.burst) or 30
    local res = { sent = 0, bcast_sent = 0 }

    node:bind(7200, function(data, src, sport)
        w("MCAST_OWN_ECHO from=%s payload=%q", M.int2ip(src), tostring(data))
    end)

    node:add_task("mcast-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 2)
        w("MCAST_START group=%s burst=%d", M.int2ip(group), burst)

        -- burst on the joined group (router: forward + rate limit)
        for i = 1, burst do
            M.mcast_send(node, group, 7300, "g1-" .. i, 7300)
            res.sent = res.sent + 1
            if i % 5 == 0 then os.sleep(0.05) end
        end
        w("MCAST_BURST_SENT n=%d", res.sent)
        os.sleep(1.0)

        -- a group nobody joined: the router must not learn anything, the host drops it
        for i = 1, 3 do M.mcast_send(node, "239.9.9.9", 7301, "g9-" .. i, 7301) end
        w("MCAST_OTHER_GROUP_SENT n=3 group=239.9.9.9")

        -- limited broadcast: only relayed when the domain rules allow it
        M.udp_send(node, M.IP_BCAST, 7200, 7200, "bcast-hello")
        res.bcast_sent = 1
        w("BCAST_SENT dst=255.255.255.255 port=7200")
        os.sleep(2.0)

        w("MCAST_SELFTEST_RESULT sent=%d bcast_sent=%d", res.sent, res.bcast_sent)
        w("TEST_DONE")
    end)
end
