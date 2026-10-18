--[[- nat-peer ? the EXTERNAL side of the NAT acceptance test.

Config: role=host, iface=...|10.0.2.2/24, gw=10.0.2.1, app=nat-peer
  1. echoes UDP 7 (records the source address it sees -> must be the NAT address)
  2. after a delay, knocks on the router's forwarded port (10.0.2.1:7000) and waits
     for a reply, proving the port forward reaches the internal host
Writes peer-log.txt and ends with PEER_RESULT pass=... + TEST_DONE.
]]
return function(M, node, args)
    local natIP = M.ip2int(node.cfg.nat_addr or "10.0.2.1")
    local fwdPort = tonumber(node.cfg.nat_port) or 7000
    local log = fs.open("peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end   -- also into rpv-log for the harness
    end
    local res = { echo_seen = false, source_is_nat = false, inbound_reply = false }

    node:bind(7, function(data, src, sport)
        res.echo_seen = true
        if src == natIP then res.source_is_nat = true end
        w("PEER_ECHO from=%s sport=%d source_is_nat=%s payload=%q", M.int2ip(src), sport, tostring(src == natIP), tostring(data))
        M.udp_send(node, src, 7, sport, "echo:" .. tostring(data))
    end)

    node:add_task("nat-peer", function()
        os.sleep(tonumber(node.cfg.start_delay) or 6)
        w("PEER_KNOCK dst=%s port=%d (router port forward -> internal host)", M.int2ip(natIP), fwdPort)
        local sk = node:bind(7100, function(data, src, sport)
            if data:match("pong") then
                res.inbound_reply = true
                w("PEER_INBOUND_REPLY from=%s sport=%d payload=%q", M.int2ip(src), sport, tostring(data))
            end
        end)
        M.udp_send(node, natIP, 7100, fwdPort, "knock-from-outside")
        local waited = 0
        while not res.inbound_reply and waited < 6 do os.sleep(0.25); waited = waited + 0.25 end
        w("PEER_INBOUND_CHECK ok=%s after=%.2fs", tostring(res.inbound_reply), waited)

        -- a port with no forward rule: the router must drop it (NAT_DROP) and nothing
        -- may come back
        local sk2 = node:bind(7101, function(data, src, sport)
            w("PEER_UNEXPECTED_REPLY from=%s payload=%q", M.int2ip(src), tostring(data))
            res.drop_probe_reply = true
        end)
        M.udp_send(node, natIP, 7101, 7002, "no-rule-here")
        w("PEER_DROP_PROBE dst=%s port=7002", M.int2ip(natIP))
        os.sleep(1.0)
        local ok = res.echo_seen and res.source_is_nat and res.inbound_reply
        w("PEER_RESULT echo=%s source_is_nat=%s inbound_reply=%s pass=%s", tostring(res.echo_seen),
            tostring(res.source_is_nat), tostring(res.inbound_reply), tostring(ok))
        w("TEST_DONE")
    end)
end
