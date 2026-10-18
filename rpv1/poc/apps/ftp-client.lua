--[[- apps/ftp-client.lua — pulls a file with the windowed block protocol.

Buffers out-of-order blocks, acknowledges the highest contiguous block
(cumulative ACK, duplicate ACKs trigger fast retransmit on the server), and
verifies the whole file with SHA-256 before reporting.

  app=ftp-client:10.0.1.2:4300:payload.txt
]]
return function(M, node, args)
    local ipstr, rest = args:match("^([%d%.]+):(.*)$")
    local port, name = (rest or ""):match("^(%d+):(.+)$")
    if not ipstr or not port then
        node:log("FTP_CLIENT_BAD_ARGS args=%s", tostring(args))
        return
    end
    local crypto = dofile("crypto.lua")
    local dst, port, name = M.ip2int(ipstr), tonumber(port), name
    local meta, buf, expect, blocks_rx = nil, {}, 1, 0
    local finished = false
    local out = "received-" .. name
    local t0 = os.clock()

    -- ---- connection-oriented transport (rpv/conn.lua) ----
    if node.cfg.ftp_transport == "conn" then
        local stream, head = "", nil
        local c = M.conn_connect(node, dst, port, { sport = port + 1 })
        c:on_open(function(conn)
            node:log("FTPC_CONN_OPEN mss=%d cwnd=%d ssthresh=%d", conn.mss, conn.cwnd, conn.ssthresh)
            conn:send(name)
        end)
        c:on_data(function(conn, data)
            stream = stream .. data
            if not head then
                if #stream >= 2 then
                    local hlen = M.r16(stream, 1)
                    if #stream >= 2 + hlen then
                        local m = textutils.unserialize(stream:sub(3, 2 + hlen))
                        stream = stream:sub(3 + hlen)
                        if type(m) == "table" and m.size then
                            head = m
                            node:log("FTPC_META name=%s size=%d transport=conn mss=%s sha=%s", m.name, m.size,
                                tostring(m.mss), tostring(m.sha):sub(1, 16))
                        else
                            node:log("FTPC_ERR reason=%s", tostring(m))
                            head = { size = math.huge }
                        end
                    end
                end
            end
            if head and #stream >= head.size then
                local payload = stream:sub(1, head.size)
                local got = crypto.hex(crypto.sha256(payload))
                local f = fs.open(out, "wb")
                f.write(payload)
                f.close()
                node:log("FTPC_WROTE file=%s bytes=%d", out, #payload)
                node:log("FTPC_VERIFY size_ok=%s sha_ok=%s got=%s want=%s", tostring(#payload == head.size),
                    tostring(got == head.sha), got:sub(1, 16), tostring(head.sha):sub(1, 16))
                node:log("FTPC_RESULT blocks=%d bytes=%d window=conn ok=%s elapsed=%.3f",
                    math.ceil(#payload / (tonumber(head.mss) or 200)), #payload, tostring(got == head.sha), os.clock() - t0)
                conn:log_stats("client")
                node:log("TEST_DONE")
                conn:close()
            end
        end)
        node:add_task("ftp-conn-timeout", function()
            os.sleep(40)
            if not head then
                node:log("FTPC_CONN_TIMEOUT (no data)")
                node:log("TEST_DONE")
            end
        end)
        return
    end

    local function ack(i, tag)
        M.udp_send(node, dst, port, port, textutils.serialize({ t = "ack", i = i }), 64)
        if tag then node:log("FTPC_ACK i=%d (%s)", i, tag) end
    end

    local function finish()
        if finished then return true end
        if not meta or expect <= meta.blocks then return false end
        finished = true
        local parts = {}
        for i = 1, meta.blocks do parts[i] = buf[i] end
        local content = table.concat(parts)
        local f = fs.open(out, "wb")
        f.write(content)
        f.close()
        local got = crypto.hex(crypto.sha256(content))
        local ok_sha = got == meta.sha
        local ok_size = #content == meta.size
        node:log("FTPC_WROTE file=%s bytes=%d", out, #content)
        node:log("FTPC_VERIFY size_ok=%s sha_ok=%s got=%s want=%s", tostring(ok_size), tostring(ok_sha),
            got:sub(1, 16), tostring(meta.sha):sub(1, 16))
        M.udp_send(node, dst, port, port, textutils.serialize({ t = "done" }), 64)
        node:log("FTPC_RESULT blocks=%d bytes=%d window=%s ok=%s elapsed=%.3f", blocks_rx, #content,
            tostring(meta.window), tostring(ok_sha and ok_size), os.clock() - t0)
        node:log("TEST_DONE")
        return true
    end

    local sk = node:bind(port, function(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if not ok or type(msg) ~= "table" then
            node:log("FTPC_BAD_PACKET from=%s", M.int2ip(src))
            return
        end
        if msg.t == "meta" then
            meta = msg
            buf, expect, blocks_rx = {}, 1, 0
            t0 = os.clock()
            node:log("FTPC_META name=%s size=%d blocks=%d window=%s sha=%s", msg.name, msg.size, msg.blocks,
                tostring(msg.window), tostring(msg.sha):sub(1, 16))
        elseif msg.t == "blk" then
            local i = tonumber(msg.i) or 0
            if i == expect then
                buf[expect] = msg.data
                blocks_rx = blocks_rx + 1
                expect = expect + 1
                while buf[expect] do
                    blocks_rx = blocks_rx + 1
                    expect = expect + 1
                end
                ack(expect - 1, nil)
                node:log("FTPC_RX_BLOCK i=%d bytes=%d expect=%d", i, #msg.data, expect)
                if meta and expect > meta.blocks then finish() end
            elseif i > expect then
                if not buf[i] then
                    buf[i] = msg.data
                    node:log("FTPC_BUFFERED i=%d expect=%d", i, expect)
                end
                ack(expect - 1, "dupack")     -- duplicate ACK -> fast retransmit
            else
                node:log("FTPC_DUP_BLOCK i=%d expect=%d", i, expect)
                ack(expect - 1, nil)
            end
        elseif msg.t == "fin" then
            if not finish() then
                node:log("FTPC_FIN_WAIT expect=%d of %s", expect, tostring(meta and meta.blocks))
                ack(expect - 1, "fin-wait")
            end
        elseif msg.t == "err" then
            node:log("FTPC_ERR reason=%s", tostring(msg.reason))
        end
    end) -- luacheck: ignore sk

    node:log("FTP_CLIENT get=%s from=%s:%d", name, ipstr, port)
    M.udp_send(node, dst, port, port, textutils.serialize({ t = "get", name = name }), 64)

    -- safety net: if "fin" is lost, nudge the server once nothing arrives
    node:add_task("ftp-timeout", function()
        os.sleep(15)
        if meta and expect <= meta.blocks then
            node:log("FTPC_RETRY_GET expect=%d of %d", expect, meta.blocks)
            M.udp_send(node, dst, port, port, textutils.serialize({ t = "get", name = name }), 64)
        end
    end)
end
