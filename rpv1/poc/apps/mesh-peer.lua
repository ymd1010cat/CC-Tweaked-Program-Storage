--[[- mesh-peer ? far side of the mesh load test.

Config: role=host, iface=...|10.0.3.2/24, gw=10.0.3.1, app=mesh-peer
Listens on conn 4400..(4400+flows-1) and counts what each flow delivered; answers
ICMP echo automatically (the IP layer does that).
Result: MESH_PEER_RESULT flow0= flow1= ... + TEST_DONE.
]]
return function(M, node, args)
    local flows = tonumber(node.cfg.flows) or 4
    local basePort = tonumber(node.cfg.base_port) or 4400
    local log = fs.open("mesh-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local got = {}

    for i = 1, flows do
        local port = basePort + i - 1
        got[port] = 0
        M.conn_listen(node, port, function(conn)
            w("MESH_PEER_CONN port=%d peer=%s", port, M.int2ip(conn.peer_ip))
            conn:on_data(function(_, data) got[port] = got[port] + #data end)
        end)
    end

    node:add_task("mesh-peer", function()
        local waited = 0
        local expect = tonumber(node.cfg.expect_per_flow) or 1500
        local function complete()
            for i = 1, flows do
                if (got[basePort + i - 1] or 0) < expect then return false end
            end
            return true
        end
        -- report periodically as well: the harness may stop the emulator right after the
        -- sender says TEST_DONE, so a single final line is easy to miss under load
        while not complete() and waited < 120 do
            os.sleep(2)
            waited = waited + 2
            local parts0 = {}
            for i = 1, flows do parts0[#parts0 + 1] = string.format("flow%d=%d", i, got[basePort + i - 1] or 0) end
            w("MESH_PEER_RESULT %s complete=%s after=%.1fs", table.concat(parts0, " "), tostring(complete()), waited)
        end
        local parts = {}
        for i = 1, flows do parts[#parts + 1] = string.format("flow%d=%d", i, got[basePort + i - 1] or 0) end
        w("MESH_PEER_RESULT %s complete=%s after=%.1fs", table.concat(parts, " "), tostring(complete()), waited)
        w("TEST_DONE")
    end)
end
