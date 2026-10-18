--[[- mc-bench — real-machine throughput / ping-pong benchmark.

Two computers, one raw modem channel each (6100) plus a request/reply channel
(6101). Measures what actually matters on a real server:

  * how many modem frames fit in one server tick (flood, no sleeps)
  * stop-and-wait ping-pong cost in ticks (this is what an ACKed protocol pays)
  * bytes/second sustained

  role.txt:  app=mc-bench  bench_role=sender|receiver  bench_frames=200
]]
return function(M, node, args)
    local role = node.cfg.bench_role or "sender"
    local n = tonumber(node.cfg.bench_frames) or 200
    local frame = string.rep("b", 140)
    local iface = node.ifaces[1]
    local CH_DATA, CH_PING = 6100, 6101
    local f = fs.open("mc-bench-" .. role .. ".txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        f.flush()
    end
    w("BENCH_START id=%d role=%s frames=%d side=%s wireless=%s", node.id, role, n, iface.side, tostring(iface.wireless))
    peripheral.call(iface.side, "open", CH_DATA)
    peripheral.call(iface.side, "open", CH_PING)

    local rx, ticks = 0, 0

    node:add_task("bench-rx", function()
        while true do
            local ev, side, chan, reply, msg = os.pullEvent("modem_message")
            if chan == CH_DATA and type(msg) == "string" then
                rx = rx + 1
                if rx % 50 == 0 then w("BENCH_RX_PROGRESS n=%d", rx) end
            elseif chan == CH_PING and type(msg) == "string" and msg:sub(1, 4) == "ping" then
                os.sleep(0)                       -- one real server tick
                peripheral.call(iface.side, "transmit", CH_PING, CH_PING, "pong")
            end
        end
    end)

    if role == "sender" then
        node:add_task("bench-run", function()
            os.sleep(3)
            -- 1) flood: as fast as possible, no yields
            local t0 = os.clock()
            for _ = 1, n do
                peripheral.call(iface.side, "transmit", CH_DATA, CH_DATA, frame)
            end
            local span = os.clock() - t0
            w("BENCH_FLOOD_SENT n=%d span=%.3f span_ticks=%d fps=%.0f", n, span, math.floor(span * 20),
                span > 0 and (n / span) or -1)
            os.sleep(5)
            -- 2) stop-and-wait ping-pong (receiver sleeps one tick before replying)
            local m = math.min(n, 20)
            local p0 = os.clock()
            for i = 1, m do
                peripheral.call(iface.side, "transmit", CH_PING, CH_PING, "ping" .. i)
                while true do
                    local ev, side, chan, reply, msg = os.pullEvent("modem_message")
                    if chan == CH_PING and msg == "pong" then break end
                end
            end
            local pspan = os.clock() - p0
            w("BENCH_PINGPONG n=%d span=%.3f ticks=%d ticks_per_rtt=%.1f", m, pspan,
                math.floor(pspan * 20), (pspan * 20) / m)
            os.sleep(3)
            w("BENCH_DONE")
            w("TEST_DONE")
        end)
    else
        node:add_task("bench-summary", function()
            os.sleep(30)
            w("BENCH_RX_TOTAL n=%d", rx)
            w("BENCH_DONE")
            w("TEST_DONE")
        end)
    end
end
