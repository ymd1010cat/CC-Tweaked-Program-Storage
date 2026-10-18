--[[- apps/monitor-host.lua — telemetry collector (M3).

  app=monitor-host:4200

Keeps the latest sample per node and prints a summary every 5 s; logs
MON_RESULT + TEST_DONE once two nodes have reported.
]]
return function(M, node, args)
    local port = tonumber(args) or 4200
    local latest = {}

    local sk = node:bind(port, function(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if not ok or type(msg) ~= "table" or type(msg.metrics) ~= "table" then
            node:log("MON_BAD_PACKET from=%s", M.int2ip(src))
            return
        end
        latest[msg.node] = { role = msg.role, metrics = msg.metrics, at = os.clock(), ip = M.int2ip(src) }
        node:log("MON_RECV node=%s role=%s from=%s uptime=%s fwd=%s", tostring(msg.node), tostring(msg.role),
            M.int2ip(src), tostring(msg.metrics.uptime), tostring(msg.metrics.fwd))
    end) -- luacheck: ignore sk

    node:add_task("monitor-summary", function()
        local round, announced = 0, false
        while true do
            os.sleep(5)
            round = round + 1
            local ids, n = {}, 0
            for id, e in pairs(latest) do
                if e.at > os.clock() - 15 then
                    n = n + 1
                    ids[#ids + 1] = tostring(id)
                end
            end
            table.sort(ids)
            node:log("MON_SUMMARY round=%d nodes=%d ids=%s", round, n, table.concat(ids, ","))
            if n >= 2 and not announced then
                announced = true
                node:log("MON_RESULT nodes=%d ok=true", n)
                node:log("TEST_DONE")
            end
        end
    end)

    node:log("MONITOR_HOST bound port=%d", port)
end
