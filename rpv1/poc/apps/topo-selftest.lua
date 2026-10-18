--[[- topo-selftest — topology discovery acceptance (runs on the COLLECTOR).

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1,
        topo=1 topo_collect=1 topo_dump=1 topo_server=10.0.1.2, app=topo-selftest
Waits until every node has reported, then asserts the merged map and writes it out:
    TOPO_SELFTEST nodes=N links=M ids=... pass=...
    NETMAP_* lines (also written to netmap.txt)
    TEST_DONE
]]
return function(M, node, args)
    local expect = tonumber(node.cfg.expect_nodes) or 5
    local log = fs.open("topo-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    node:add_task("topo-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 10)
        w("TOPO_SELFTEST_START expect_nodes=%d", expect)

        local stats = M.topo_stats and M.topo_stats(node) or { nodes = 0, links = 0 }
        local waited = 0
        while (stats.nodes or 0) < expect and waited < 24 do
            os.sleep(1)
            waited = waited + 1
            stats = M.topo_stats(node) or stats
        end
        w("TOPO_WAIT_DONE nodes=%d links=%d after=%ds", stats.nodes or 0, stats.links or 0, waited)

        local text = M.topo_text(node)
        local ids, links = {}, 0
        for id in text:gmatch("NODE id=(%d+)") do ids[#ids + 1] = tonumber(id) end
        table.sort(ids)
        for _ in text:gmatch("LINK ") do links = links + 1 end

        local seen = {}
        for _, id in ipairs(ids) do seen[id] = true end
        local allThere = true
        for id = 21, 20 + expect do if not seen[id] then allThere = false end end

        local ok = (stats.nodes or 0) >= expect and links >= (expect - 1) and allThere
        w("TOPO_SELFTEST nodes=%d links=%d ids=%s all_present=%s pass=%s",
            stats.nodes or 0, links, table.concat(ids, ","), tostring(allThere), tostring(ok))
        M.topo_dump(node)                     -- final map -> netmap.txt + NETMAP_* lines
        w("TEST_DONE")
    end)
end
