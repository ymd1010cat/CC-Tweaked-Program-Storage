--[[- mc-load — modem flood load generator / counter (real Minecraft).

One computer is the counter, the rest are senders on the same channel. Each
sender transmits `load_per_tick` frames per server tick (then os.sleep(0)), so the
offered load is (senders * per_tick) frames/tick. The counter records per-tick
arrival deltas, giving the achieved pps and any drop-off as CC's per-tick
computer budget saturates.

  role.txt (counter):  app=mc-load  load_role=counter  load_channel=6400  load_secs=12
  role.txt (senders):  app=mc-load  load_role=sender   load_channel=6400  load_secs=12  load_per_tick=4
]]
return function(M, node, args)
    local role = node.cfg.load_role or "sender"
    local mode = node.cfg.load_mode or "raw"          -- raw modem flood | rpv (UDP through the stack)
    local perTick = tonumber(node.cfg.load_per_tick) or 1
    local secs = tonumber(node.cfg.load_secs) or 12
    local ch = tonumber(node.cfg.load_channel) or 6400
    local port = tonumber(node.cfg.load_port) or 6500
    local dst = node.cfg.load_dst and M.ip2int(node.cfg.load_dst) or nil
    local iface = node.ifaces[1]
    local frame = node.cfg.load_frame_bytes and M.rep("x", tonumber(node.cfg.load_frame_bytes)) or M.rep("x", 140)
    local f = fs.open("mc-load-" .. role .. ".txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        f.flush()
    end

    peripheral.call(iface.side, "open", ch)
    w("LOAD_START id=%d role=%s mode=%s per_tick=%d secs=%d side=%s bytes=%d", node.id, role, mode, perTick, secs,
        iface.side, #frame)

    local function fire()
        if mode == "rpv" then
            M.udp_send(node, dst, port, port, frame, 64)
        else
            peripheral.call(iface.side, "transmit", ch, ch, frame)
        end
    end

    if role == "sender" and mode == "conn" then
        -- backpressure test: stream a fixed amount over a real connection
        local want = tonumber(node.cfg.load_conn_bytes) or 20000
        local chunk = M.rep("y", 256)
        local c = M.conn_connect(node, dst, port, { sport = port + 1 })
        c:on_open(function(conn)
            local t0 = os.clock()
            local sent = 0
            w("LOAD_CONN_OPEN mss=%d want=%d", conn.mss, want)
            while sent < want do
                local n = math.min(#chunk, want - sent)
                conn:send(n == #chunk and chunk or M.rep("y", n))
                sent = sent + n
            end
            conn:close()
            local span = os.clock() - t0
            w("LOAD_SENT total=%d ticks=%d span=%.3f fps=%.0f bytes_per_s=%.0f tx=%d retx=%d", sent, 0, span,
                sent / span, sent / span, conn.tx, conn.retx)
            w("LOAD_DONE")
        end)
        c:on_close(function(conn) conn:log_stats("loadconn-client") end)
        return
    elseif role == "sender" then
        if mode == "rpv" and not dst then
            w("LOAD_ERROR mode=rpv needs load_dst")
            return
        end
        node:add_task("load-send", function()
            os.sleep(2)                              -- let the counter start first
            local t0 = os.clock()
            local ticks, sent = 0, 0
            while os.clock() - t0 < secs do
                for _ = 1, perTick do fire() end
                sent, ticks = sent + perTick, ticks + 1
                os.sleep(0)
            end
            local span = os.clock() - t0
            w("LOAD_SENT total=%d ticks=%d span=%.3f fps=%.0f per_tick=%.1f", sent, ticks, span,
                sent / span, sent / ticks)
            w("LOAD_DONE")
        end)
    else
        local rx, ticks, last = 0, 0, 0
        local t0 = os.clock()
        local listener = nil
        if mode == "conn" then
            listener = M.conn_listen(node, port, function(conn)
                w("LOAD_CONN_ACCEPT peer=%s", M.int2ip(conn.peer_ip))
                conn:on_data(function(c, data) rx = rx + #data end)
                conn:on_close(function(c)
                    c:log_stats("loadconn-server")
                    w("LOAD_CONN_CLOSED bytes=%d", rx)
                end)
            end)
        elseif mode == "rpv" then
            local sk = node:bind(port, function(data, src, sport) rx = rx + 1 end) -- luacheck: ignore sk
        else
            node:add_task("load-rx", function()
                while true do
                    local ev, side, chan, reply, msg = os.pullEvent("modem_message")
                    if chan == ch then rx = rx + 1 end
                end
            end)
        end
        node:add_task("load-tick", function()
            while os.clock() - t0 < secs + 4 do
                os.sleep(0)
                ticks = ticks + 1
                local delta = rx - last
                last = rx
                if ticks % 20 == 0 then w("LOAD_TICK ticks=%d delta_20t=%d rx=%d", ticks, delta, rx) end
            end
        end)
        node:add_task("load-finish", function()
            os.sleep(secs + 5)
            local span = os.clock() - t0
            w("LOAD_RESULT received=%d ticks=%d span=%.3f fps=%.0f per_tick_avg=%.1f", rx, ticks, span,
                rx / span, ticks > 0 and rx / ticks or 0)
            w("LOAD_DONE")
            w("TEST_DONE")
        end)
    end
end
