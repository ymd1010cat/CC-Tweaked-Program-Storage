--[[- apps/routectl.lua — show interfaces / routes / arp / sockets / stats / paths / capture.

  app=routectl            (everything)
  app=routectl:routes
  app=routectl:paths      (one line per destination: next hop, egress, hop count)
  app=routectl:capture
]]
return function(M, node, args)
    node:after(1, function()
        local what = (args ~= "" and args) or "all"
        local function sec(fmt, ...) node:log("ROUTECTL " .. string.format(fmt, ...)) end

        if what == "all" or what == "ifaces" then
            for _, i in ipairs(node.ifaces) do
                sec("iface %s addr=%s ch=%d mtu=%d link=%s wireless=%s", i.name, i.cidr, i.channel, i.mtu, i.linktype, tostring(i.wireless))
            end
        end
        if what == "all" or what == "routes" then
            for _, r in ipairs(M.route_list(node.routes)) do
                sec("route %s via %s (%s)", r.dest, r.via, r.kind)
            end
        end
        if what == "all" or what == "paths" then
            -- join the forwarding state with the collected map: dst is the destination
            -- name, via the next hop, out the egress interface, hops the map distance
            local summary = M.topo_flow_summary and M.topo_flow_summary(node) or { flows = 0, multi = 0, unknown = 0, list = {} }
            for _, f in ipairs(summary.list or {}) do
                sec("path dst=%s via=%s out=%s kind=%s hops=%s", f.dst, tostring(f.via), tostring(f.out),
                    tostring(f.kind), f.hops and tostring(f.hops) or "?")
            end
            sec("paths flows=%d multi=%d unknown=%d", summary.flows, summary.multi, summary.unknown)
        end
        if what == "all" or what == "arp" then
            for ip, e in pairs(node.arp.cache) do sec("arp %s -> mac %d", M.int2ip(ip), e.mac) end
            for ip, p in pairs(node.arp.pending) do sec("arp-pending %s tries=%d queued=%d", M.int2ip(ip), p.tries, #p.cbs) end
        end
        if what == "all" or what == "sockets" then
            for port, sk in pairs(node.udp.ports) do sec("socket port=%d rx=%d tx=%d", port, sk.rx, sk.tx) end
        end
        if what == "all" or what == "stats" then node:dump_stats() end
        if what == "capture" then
            for _, c in ipairs(node:capture(10)) do
                sec("cap %s iface=%s len=%d dst=%s etype=%s", c.dir, c.iface, c.len, tostring(c.dst), c.etype)
            end
        end
        node:log("ROUTECTL_DONE")
    end)
end
