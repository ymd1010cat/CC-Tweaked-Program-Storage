--[[- apps/panel.lua — metrics dashboard (M4).

Collects telemetry (same wire format as monitor-agent) and renders it on a
monitor peripheral if one is attached, otherwise on the computer terminal.
Every 3 s it redraws and logs PANEL_DRAW so the dashboard can be asserted
without reading pixels.

  app=panel:4200
]]
return function(M, node, args)
    local port = tonumber(args) or 4200
    local latest = {}
    local mon

    if periphemu and peripheral.getType("top") ~= "monitor" then
        -- headless CraftOS-PC refuses to create monitors; fall back to the term
        local ok, err = pcall(periphemu.create, "top", "monitor")
        if not ok then node:log("PANEL_ATTACH_FAIL %s", tostring(err)) end
    end
    if peripheral.getType("top") == "monitor" then
        mon = peripheral.wrap("top")
        node:log("PANEL_MONITOR attached")
    end
    local out = mon or term

    local function draw()
        local ids = {}
        for id, e in pairs(latest) do
            if e.at > os.clock() - 20 then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local okDraw, err = pcall(function()
            out.clear()
            out.setCursorPos(1, 1)
            out.write("rpv dashboard  nodes=" .. #ids)
            local y = 2
            for _, id in ipairs(ids) do
                local e = latest[id]
                out.setCursorPos(1, y)
                out.write(string.format("#%d %s up=%ss fwd=%s ip_rx=%s free=%sKB", id, tostring(e.role),
                    tostring(e.metrics.uptime), tostring(e.metrics.fwd), tostring(e.metrics.ip_rx), tostring(e.metrics.free_kb)))
                y = y + 1
                if y > 12 then break end
            end
            -- multi-hop path view: the destinations that are NOT one hop away are the
            -- ones an operator is actually looking for
            local summary = M.topo_flow_summary and M.topo_flow_summary(node) or nil
            if summary then
                out.setCursorPos(1, y)
                out.write(string.format("paths flows=%d multi=%d unknown=%d", summary.flows, summary.multi, summary.unknown))
                y = y + 1
                for _, f in ipairs(summary.list or {}) do
                    if f.hops and f.hops > 1 and y <= 18 then
                        out.setCursorPos(1, y)
                        out.write(string.format("%s via %s hops=%d", f.dst, tostring(f.via), f.hops))
                        y = y + 1
                    end
                end
                node.last_paths = { flows = summary.flows, multi = summary.multi, unknown = summary.unknown }
            end
        end)
        node:log("PANEL_DRAW nodes=%d target=%s ok=%s%s", #ids, mon and "monitor" or "term", tostring(okDraw),
            okDraw and "" or (" err=" .. tostring(err)))
        return #ids
    end

    local sk = node:bind(port, function(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if ok and type(msg) == "table" and type(msg.metrics) == "table" then
            latest[msg.node] = { role = msg.role, metrics = msg.metrics, at = os.clock() }
        end
    end) -- luacheck: ignore sk

    node:add_task("panel", function()
        local announced = false
        while true do
            os.sleep(3)
            local n = draw()
            if n >= 2 and not announced then
                announced = true
                node:log("PANEL_OK nodes=%d", n)
                node:log("TEST_DONE")
            end
        end
    end)

    node:log("PANEL bound port=%d", port)
end
