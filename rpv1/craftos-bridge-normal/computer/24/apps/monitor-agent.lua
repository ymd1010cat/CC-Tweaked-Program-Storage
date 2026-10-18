--[[- apps/monitor-agent.lua — telemetry agent (M3).

Periodically ships this node's counters to a collector.

  app=monitor-agent:10.0.1.1:4200
]]
return function(M, node, args)
    local ipstr, port = args:match("^([%d%.]+):(%d+)$")
    if not ipstr then
        node:log("MON_AGENT_BAD_ARGS args=%s", tostring(args))
        return
    end
    local dst = M.ip2int(ipstr)
    port = tonumber(port) or 4200
    local t0 = os.clock()
    local interval = tonumber(node.cfg.mon_interval) or 3

    node:add_task("monitor-agent", function()
        while true do
            local st, cache = node.stats, 0
            for _ in pairs(node.arp.cache) do cache = cache + 1 end
            local metrics = {
                uptime = math.floor(os.clock() - t0),
                ip_rx = st.ip_rx,
                fwd = st.fwd,
                ttl_drop = st.ttl_drop,
                udp_rx = node.udp.rx,
                udp_tx = node.udp.tx,
                arp_cache = cache,
                free_kb = math.floor(((fs.getFreeSpace and fs.getFreeSpace("/") or -1)) / 1024),
            }
            M.udp_send(node, dst, port, port,
                textutils.serialize({ node = node.id, role = node.role, metrics = metrics }), 64)
            node:log("MON_TX node=%d uptime=%ds fwd=%d ip_rx=%d udp_rx=%d arp=%d free_kb=%d",
                node.id, metrics.uptime, metrics.fwd, metrics.ip_rx, metrics.udp_rx, metrics.arp_cache, metrics.free_kb)
            os.sleep(interval)
        end
    end)
end
