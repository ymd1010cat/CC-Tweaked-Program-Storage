--[[- apps/routectl.lua — show interfaces / routes / arp / sockets / stats / capture.

  app=routectl            (everything)
  app=routectl:routes
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
