--[[- qos-peer ? the receiving side of the QoS experiment.

Config: role=host, iface=...|10.0.1.2/24, app=qos-peer
  * echoes UDP 7 (the bulk flood target, i.e. its egress is the congested one)
  * listens on conn 4400 and counts the transferred bytes
  * listens on UDP 4401: "qos-on" makes it enable its own QoS scheduler mid-run
    (that is the point: its ACKs then outrank its own bulk echo replies)
Writes qos-peer-log.txt + QOS_PEER_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local log = fs.open("qos-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local res = { echoed = 0, conn_bytes = 0, conn_closed = false }

    node:bind(7, function(data, src, sport)
        res.echoed = res.echoed + 1
        M.udp_send(node, src, 7, sport, "e:" .. tostring(data))
    end)

    node:bind(4401, function(data, src, sport)
        if tostring(data) == "qos-on" then
            node.cfg.qos = "1"
            if M.qos_setup then M.qos_setup(node) end
            w("QOS_ENABLED on the receiver (ACKs now outrank bulk replies)")
        end
    end)

    M.conn_listen(node, 4400, function(conn)
        w("QOS_PEER_CONN peer=%s", M.int2ip(conn.peer_ip))
        conn:on_data(function(_, data) res.conn_bytes = res.conn_bytes + #data end)
        conn:on_close(function()
            res.conn_closed = true
            w("QOS_PEER_CONN_CLOSED bytes=%d", res.conn_bytes)
        end)
    end)

    node:add_task("qos-peer", function()
        local waited = 0
        while waited < 150 do
            os.sleep(5)
            waited = waited + 5
            local s = M.qos_stats and M.qos_stats(node) or {}
            -- periodic report: the harness reads the LAST one, i.e. after phase B
            w("QOS_PEER_STATE t=%.0f echoed=%d conn_bytes=%d high=%d mid=%d low=%d tx=%d dropped=%d",
                waited, res.echoed, res.conn_bytes, s.high or 0, s.mid or 0, s.low or 0, s.tx or 0, s.dropped or 0)
        end
        local st = M.qos_stats and M.qos_stats(node) or {}
        w("QOS_PEER_RESULT echoed=%d conn_bytes=%d conn_closed=%s high=%d mid=%d low=%d dropped=%d tx=%d",
            res.echoed, res.conn_bytes, tostring(res.conn_closed),
            st.high or 0, st.mid or 0, st.low or 0, st.dropped or 0, st.tx or 0)
        w("TEST_DONE")
    end)
end
