--[[- p3-peer ? receiver side of the P3 transport experiments.

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, app=p3-peer
  * conn listeners on 4400 and 4401 (count bytes per flow, for the fairness test)
  * UDP 4402 control: "blackhole" makes THIS node drop all of its own transmits
    (a simulated dead peer, so the sender's keepalive must time out), "heal" undoes it
Writes p3-peer-log.txt + P3_PEER_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local log = fs.open("p3-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local res = { bytes = { [4400] = 0, [4401] = 0 }, conns = 0 }

    for _, port in ipairs({ 4400, 4401 }) do
        M.conn_listen(node, port, function(conn)
            res.conns = res.conns + 1
            w("P3_PEER_CONN port=%d peer=%s n=%d", port, M.int2ip(conn.peer_ip), res.conns)
            conn:on_data(function(_, data) res.bytes[port] = res.bytes[port] + #data end)
        end)
    end

    node:bind(4402, function(data, src, sport)
        local cmd = tostring(data)
        if cmd == "blackhole" then
            -- nothing may leave this node: a genuinely dead peer (drop_every only
            -- affects data retransmits, ACKs would still flow)
            node.cfg.block_egress = "1"
            w("P3_PEER_BLACKHOLE (all egress blocked from now on)")
        elseif cmd == "heal" then
            node.cfg.block_egress = "0"
            w("P3_PEER_HEALED")
        elseif cmd == "report" then
            w("P3_PEER_STATE c4400=%d c4401=%d conns=%d", res.bytes[4400], res.bytes[4401], res.conns)
        end
    end)

    node:add_task("p3-peer", function()
        local waited = 0
        while waited < 150 do
            os.sleep(5)
            waited = waited + 5
            w("P3_PEER_STATE t=%.0f c4400=%d c4401=%d conns=%d", waited, res.bytes[4400], res.bytes[4401], res.conns)
        end
        w("P3_PEER_RESULT c4400=%d c4401=%d conns=%d", res.bytes[4400], res.bytes[4401], res.conns)
        w("TEST_DONE")
    end)
end
