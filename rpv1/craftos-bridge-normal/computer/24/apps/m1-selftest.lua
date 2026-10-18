--[[- apps/m1-selftest.lua — M1 acceptance test, written as an ordinary app on
top of the public API only.

  app=m1-selftest:10.0.1.2:9000

Checks:
  1. traceroute with increasing TTL -> hop 1 should be the router, hop 2 the host
  2. three ICMP echoes get replies
  3. a UDP socket exchange with the peer's socket-echo app
]]
return function(M, node, args)
    local ipstr, port = args:match("^([%d%.]+):?(%d*)$")
    local target = ipstr or "10.0.1.2"
    port = tonumber(port) or 9000
    local dst = M.ip2int(target)
    local res = { hops = {}, pings = 0, socket_ok = false }
    local MAXHOP = 4

    node.on_echo_reply = function(src, seq, rtt)
        if seq > 99 and seq <= 99 + MAXHOP then
            local h = seq - 99
            res.hops[h] = M.int2ip(src)
            res.trace_done = true
            node:log("SELFTEST_TRACE_END hop=%d at=%s rtt_us=%s", h, M.int2ip(src), rtt and string.format("%.0f", rtt) or "?")
        elseif seq < 100 then
            res.pings = res.pings + 1
            node:log("SELFTEST_PING_REPLY seq=%d rtt_us=%s", seq, rtt and string.format("%.0f", rtt) or "?")
        end
    end

    node.on_icmp_error = function(src, itype, code, inner, seq)
        if itype == 11 and seq and seq > 99 and seq <= 99 + MAXHOP then
            local h = seq - 99
            res.hops[h] = M.int2ip(src)
            node:log("SELFTEST_TRACE_HOP %d = %s", h, M.int2ip(src))
        end
    end

    -- 1. traceroute: one probe per hop, 0.6 s apart
    for h = 1, MAXHOP do
        node:after(0.6 * h, function()
            if res.trace_done then return end
            local seq = 99 + h
            node.ping_sent[seq] = os.clock()
            M.icmp_echo(node, dst, seq, "hop" .. h, h)
            node:log("SELFTEST_TRACE_PROBE hop=%d ttl=%d", h, h)
        end)
    end

    -- 2. three pings
    node:after(3.5, function()
        for seq = 1, 3 do
            node.ping_sent[seq] = os.clock()
            M.icmp_echo(node, dst, seq, string.rep("P", 32), 64)
        end
        node:log("SELFTEST_PING_SENT n=3")
    end)

    -- 3. socket exchange
    local sk = node:bind(9100, function(data, src, sport)
        node:log("SELFTEST_SOCKET_REPLY from=%s sport=%d data=%s", M.int2ip(src), sport, data)
        if data:sub(1, 5) == "echo:" then res.socket_ok = true end
    end)
    node:after(4.5, function()
        sk:sendto(dst, port, "hello-socket")
        node:log("SELFTEST_SOCKET_SENT to=%s:%d from_port=%d", target, port, sk.port)
    end)

    -- summary: wait for the expectations (or give up)
    node:after(5.5, function()
        local deadline = os.clock() + 15
        local function check()
            local nhops = 0
            for _ in pairs(res.hops) do nhops = nhops + 1 end
            local complete = res.pings >= 3 and res.socket_ok and nhops >= 2
            if complete or os.clock() > deadline then
                node:log("SELFTEST_RESULT hops=%d hop1=%s hop2=%s pings=%d socket_ok=%s complete=%s",
                    nhops, tostring(res.hops[1]), tostring(res.hops[2]), res.pings, tostring(res.socket_ok), tostring(complete))
                node:log("TEST_DONE")
            else
                node:after(0.5, check)
            end
        end
        node:after(0.1, check)
    end)
end
