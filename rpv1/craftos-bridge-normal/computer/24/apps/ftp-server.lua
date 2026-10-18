--[[- apps/ftp-server.lua — block-based file server with a sliding window.

v2: windowed send (default ftp_window=4) instead of strict stop-and-wait, because
real Minecraft quantises everything to server ticks (50 ms), where stop-and-wait
costs one tick per block. Still verifies the whole file with SHA-256.

  app=ftp-server:4300
  role.txt: ftp_block=256  ftp_window=4
]]
return function(M, node, args)
    local port = tonumber(args) or 4300
    local crypto = dofile("crypto.lua")
    local BLOCK = tonumber(node.cfg.ftp_block) or 256
    local WINDOW = tonumber(node.cfg.ftp_window) or 4
    local RETX = tonumber(node.cfg.ftp_retx) or 0.4
    local st = nil

    -- ---- connection-oriented transport (rpv/conn.lua: handshake + AIMD) ----
    if node.cfg.ftp_transport == "conn" then
        M.conn_listen(node, port, function(conn)
            node:log("FTP_CONN_ACCEPT peer=%s mss=%d", M.int2ip(conn.peer_ip), conn.mss)
            local asked = false
            conn:on_data(function(c, data)
                if asked then return end
                asked = true
                local name = tostring(data)
                if not fs.exists(name) then
                    c:send(M.u16(0) .. "ERR: no such file: " .. name)
                    c:close()
                    return
                end
                local f = fs.open(name, "rb")
                local content = f.readAll()
                f.close()
                local meta = textutils.serialize({
                    name = name, size = #content, sha = crypto.hex(crypto.sha256(content)), mss = c.mss,
                })
                node:log("FTP_SERVING name=%s size=%d transport=conn mss=%d sha=%s", name, #content, c.mss,
                    crypto.hex(crypto.sha256(content)):sub(1, 16))
                c:send(M.u16(#meta) .. meta .. content)
                node:log("FTP_SENT_ALL blocks=%d transport=conn", math.ceil(#content / c.mss))
                c:close()
            end)
            conn:on_close(function(c) c:log_stats("server") end)
        end)
        node:log("FTP_SERVER bound port=%d transport=conn mss=%s ssthresh=%s", port,
            tostring(node.cfg.conn_mss or 200), tostring(node.cfg.conn_ssthresh or 16))
        return
    end

    local function send_block(s, i)
        local data = s.content:sub((i - 1) * BLOCK + 1, i * BLOCK)
        s.sent[i] = true
        M.udp_send(node, s.peer, port, port, textutils.serialize({ t = "blk", i = i, data = data }), 64)
        node:log("FTP_TX_BLOCK i=%d/%d bytes=%d", i, s.blocks, #data)
    end

    -- fill the window: send everything from s.next up to base+WINDOW-1
    local function pump(s)
        while s.next <= s.blocks and s.next < s.base + WINDOW do
            send_block(s, s.next)
            s.next = s.next + 1
        end
        if s.next > s.blocks then
            M.udp_send(node, s.peer, port, port, textutils.serialize({ t = "fin" }), 64)
            node:log("FTP_SENT_ALL blocks=%d window=%d", s.blocks, WINDOW)
        end
    end

    local function retx_timer(s)
        node:after(RETX, function()
            if st ~= s or s.done then return end
            if s.base <= s.blocks and s.sent[s.base] then
                s.tries = s.tries + 1
                node:log("FTP_RETX base=%d window=[%d,%d] try=%d", s.base, s.base,
                    math.min(s.base + WINDOW - 1, s.blocks), s.tries)
                local upto = math.min(s.base + WINDOW - 1, s.blocks)
                for i = s.base, upto do send_block(s, i) end
                if s.tries > 20 then
                    node:log("FTP_GIVE_UP base=%d", s.base)
                    s.done = true
                end
            end
            retx_timer(s)
        end)
    end

    local sk = node:bind(port, function(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if not ok or type(msg) ~= "table" then
            node:log("FTP_BAD_PACKET from=%s", M.int2ip(src))
            return
        end
        if msg.t == "get" then
            local name = tostring(msg.name)
            if not fs.exists(name) then
                M.udp_send(node, src, port, port, textutils.serialize({ t = "err", reason = "no such file: " .. name }), 64)
                node:log("FTP_ERR no such file name=%s", name)
                return
            end
            local f = fs.open(name, "rb")
            local content = f.readAll()
            f.close()
            local blocks = math.ceil(#content / BLOCK)
            st = {
                content = content, name = name, peer = src, blocks = blocks,
                base = 1, next = 1, sent = {}, tries = 0, dup = 0, done = false,
                t0 = os.clock(),
            }
            M.udp_send(node, src, port, port, textutils.serialize({
                t = "meta", name = name, size = #content,
                sha = crypto.hex(crypto.sha256(content)), block = BLOCK, blocks = blocks, window = WINDOW,
            }), 64)
            node:log("FTP_SERVING name=%s size=%d blocks=%d window=%d sha=%s", name, #content, blocks, WINDOW,
                crypto.hex(crypto.sha256(content)):sub(1, 16))
            pump(st)
            retx_timer(st)
        elseif msg.t == "ack" and st and not st.done then
            local i = tonumber(msg.i) or 0
            if i >= st.base then
                for k = st.base, i do st.sent[k] = nil end
                st.base = i + 1
                st.tries, st.dup = 0, 0
                node:log("FTP_ACK i=%d base=%d", i, st.base)
                if st.base > st.blocks then
                    st.done = true
                    node:log("FTP_ALL_ACKED blocks=%d elapsed=%.3f", st.blocks, os.clock() - st.t0)
                else
                    pump(st)
                end
            else
                -- duplicate ack: fast retransmit after three of them
                st.dup = st.dup + 1
                node:log("FTP_DUP_ACK i=%d base=%d dup=%d", i, st.base, st.dup)
                if st.dup >= 3 then
                    st.dup = 0
                    node:log("FTP_FAST_RETX base=%d", st.base)
                    send_block(st, st.base)
                end
            end
        elseif msg.t == "done" then
            if st then st.done = true end
            node:log("FTP_DONE peer=%s", M.int2ip(src))
        else
            node:log("FTP_UNKNOWN t=%s", tostring(msg.t))
        end
    end) -- luacheck: ignore sk

    node:log("FTP_SERVER bound port=%d block=%d window=%d", port, BLOCK, WINDOW)
end
