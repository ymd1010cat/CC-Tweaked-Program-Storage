--[[- mesh-load ? data-plane load across a multi-router mesh (near host).

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1,
        app=mesh-load:10.0.3.2, flows=4, conn_bytes=1500
Opens `flows` concurrent conns to the far host (through a 3-router triangle with two
redundant paths), sends `conn_bytes` on each, and keeps pinging the far host while the
data flows, so the control plane is exercised under load.
Result: MESH_RESULT flows= bytes= ms= goodput_bps= retx= pings= fair= pass=.. + TEST_DONE.
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or node.cfg.peer or "10.0.3.2"
    local peerIP = M.ip2int(peer)
    local flows = tonumber(node.cfg.flows) or 4
    local perFlow = tonumber(node.cfg.conn_bytes) or 1500
    local basePort = tonumber(node.cfg.base_port) or 4400
    local log = fs.open("mesh-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    local pings, pongs = 0, 0
    node.on_echo_reply = function(src, seq)
        if seq and seq >= 8300 and seq < 8300 + 1000 then pongs = pongs + 1 end
    end

    node:add_task("mesh-load", function()
        os.sleep(tonumber(node.cfg.start_delay) or 14)
        w("MESH_START peer=%s flows=%d bytes_per_flow=%d", peer, flows, perFlow)

        local conns, done = {}, 0
        local payload = string.rep("M", perFlow)
        local t0 = os.clock()
        for i = 1, flows do
            local c = M.conn_connect(node, peerIP, basePort + i - 1, { sport = 4900 + i })
            conns[i] = c
            local finished = false
            c:on_open(function()
                c:send(payload)
            end)
            c.on_data = nil
            c:on_close(function() finished = true end)
            conns[i]._finished = false
        end

        -- ping the far host while the flows are in flight (control plane under load)
        local pingTask = node:add_task("mesh-ping", function()
            for i = 1, 20 do
                M.icmp_echo(node, peerIP, 8300 + i, "meshload", 64)
                pings = pings + 1
                os.sleep(0.5)
            end
        end)

        local guard = 0
        while guard < 60 do
            os.sleep(0.25)
            guard = guard + 0.25
            done = 0
            for i = 1, flows do
                if conns[i].bytes_tx >= perFlow then done = done + 1 end
            end
            if done == flows then break end
        end
        local ms = (os.clock() - t0) * 1000

        local bytes, retx, fastest, slowest = 0, 0, nil, nil
        for i = 1, flows do
            local c = conns[i]
            bytes = bytes + math.min(c.bytes_tx, perFlow)
            retx = retx + (c.retx or 0)
            local per = (c.srtt or 0)
            if per > 0 then
                fastest = (not fastest or per < fastest) and per or fastest
                slowest = (not slowest or per > slowest) and per or slowest
            end
            c:abort("mesh-load done")
        end
        local goodput = ms > 0 and (bytes / (ms / 1000)) or 0
        local fair = (done == flows)
        w("MESH_RESULT flows=%d done=%d bytes=%d ms=%.0f goodput_bps=%.0f retx=%d pings=%d pongs=%d fair=%s",
            flows, done, bytes, ms, goodput, retx, pings, pongs, tostring(fair))

        local ok = (done == flows) and bytes >= flows * perFlow and pongs >= 1
        w("MESH_VERDICT flows_complete=%s bytes_ok=%s pongs=%d pass=%s", tostring(done == flows),
            tostring(bytes >= flows * perFlow), pongs, tostring(ok))
        w("TEST_DONE")
    end)
end
