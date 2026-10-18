--[[- mc-probe — real-machine measurements (runs inside Minecraft).

Measures what CraftOS-PC cannot tell us:
  * modem frame size limit: how big a payload actually arrives over a raw
    modem channel (bisect on payload size)
  * os.sleep(0) / os.sleep(1) resolution and os.clock() granularity in ticks
  * per-hop RTT over rpv itself (the node's own ICMP ping)

  role.txt:  app=mc-probe  probe_remote=<computer id>
]]
return function(M, node, args)
    local remote = tonumber(node.cfg.probe_remote)
    local iface = node.ifaces[1]
    local f = fs.open("mc-probe.txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        f.flush()
    end

    w("PROBE_START id=%d remote=%s side=%s ch=%d mtu=%d wireless=%s", node.id, tostring(remote),
        iface.side, iface.channel, iface.mtu, tostring(iface.wireless))
    local names = peripheral.getNames()
    w("PERIPHERALS n=%d list=%s", #names, textutils.serialize(names))

    -- clock / sleep resolution
    node:add_task("probe-sleep", function()
        for _, d in ipairs({ 0, 0.05, 0.2, 1 }) do
            local t0 = os.clock()
            local c0 = os.epoch and os.epoch("utc") or 0
            os.sleep(d)
            local dt = os.clock() - t0
            local c1 = os.epoch and os.epoch("utc") or 0
            w("SLEEP requested=%.2f measured=%.3f wall_ms=%d", d, dt, c1 - c0)
        end
        w("PROBE_SLEEP_DONE")
    end)

    -- raw modem frame limit: bisect the largest payload that arrives
    local probe_port, probe_chan = 4400, 6000
    local got = {}
    local sk = node:bind(probe_port, function(data, src, sport)
        local n = tonumber(data:match("^size:(%d+)$") or "")
        if n then got[n] = true end
    end) -- luacheck: ignore sk

    node:add_task("probe-frames", function()
        os.sleep(3)
        peripheral.call(iface.side, "open", probe_chan)
        for _, size in ipairs({ 128, 512, 1024, 4096, 8192, 16384, 32768, 65536, 131072 }) do
            local payload = string.rep("x", size)
            local ok, err = pcall(peripheral.call, iface.side, "transmit", probe_chan, probe_chan, payload)
            w("RAW_TX size=%d ok=%s err=%s", size, tostring(ok), tostring(err))
            os.sleep(1)
        end
        w("PROBE_FRAMES_SENT")
    end)

    -- who receives what (both sides run this app; whoever is not sending reads)
    node:add_task("probe-rx", function()
        while true do
            local ev, side, chan, reply, msg, dist = os.pullEvent("modem_message")
            if type(msg) == "string" then
                w("RAW_RX chan=%d bytes=%d distance=%s", chan, #msg, tostring(dist))
            end
        end
    end)

    -- rpv-level ping (ICMP echo) with ttl=1/2 to measure per-hop RTT
    node:add_task("probe-ping", function()
        os.sleep(8)
        for seq = 1, 5 do
            node.ping_sent[seq] = os.clock()
            M.icmp_echo(node, M.ip2int(node.cfg.probe_target or "10.0.1.2"), seq, M.rep("P", 32), 64)
            os.sleep(0.5)
        end
        w("PROBE_PING_SENT")
    end)
    node.on_echo_reply = function(src, seq, rtt)
        if seq >= 1 and seq <= 5 then w("PING_REPLY seq=%d rtt_us=%.0f", seq, rtt or -1) end
    end

    node:add_task("probe-finish", function()
        os.sleep(30)
        local sizes = {}
        for n in pairs(got) do sizes[#sizes + 1] = n end
        table.sort(sizes)
        local parts = {}
        for _, n in ipairs(sizes) do parts[#parts + 1] = tostring(n) end
        w("PROBE_FRAME_RESULT received=[%s]", table.concat(parts, ","))
        w("PROBE_DONE")
        w("TEST_DONE")
    end)
end
