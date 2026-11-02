--[[- pyroet-os/tests/t_rhtp.lua -- the RHTP/1.0 client (system/net/rhtp.lua).

Everything network-side is faked: a stub node implements lookup / bind and a
stub socket hands the response straight back to the handler, so the URL parser,
the resolver, the request builder, the status-line parser and the chunk loop are
driven without an emulator, a modem or a real DNS server.

No non-ASCII bytes in this file.
]]

local R = assert(loadfile("/system/net/rhtp.lua"))()
local S = assert(loadfile("/system/net/rhtp_secure.lua"))()
local CRYPTO = assert(loadfile("/system/rpv/crypto.lua"))({})
local PSK = string.rep("ab", 32) -- 64 hex chars

return function(H)
    local IP_BOX = R.parse_ip("10.0.0.9")
    local IP_STORE = R.parse_ip("10.0.0.5")

    -- a tiny RHTP server: path -> body, honours "off=/len=" with 206
    local function server(routes)
        return function(request)
            local text = tostring(request)
            local path, off, len = text:match("^GET (%S+) off=(%d+) len=(%d+)$")
            if path == nil then path = text:match("^GET (%S+)$") end
            if path == nil then
                return "RHTP/1.0 400 Bad Request\r\n\r\nbad request"
            end
            local body = routes[path]
            if body == nil then
                return "RHTP/1.0 404 Not Found\r\n\r\nPage Not Found"
            end
            if off ~= nil then
                local start, count = tonumber(off), tonumber(len)
                return "RHTP/1.0 206 Partial Content\r\n\r\n"
                    .. body:sub(start + 1, start + count)
            end
            return "RHTP/1.0 200 OK\r\n\r\n" .. body
        end
    end

    -- opts: reply(request) -> response string|nil, hosts, lookup(host), silent,
    -- honor_ext (default true: a ranged request gets a 206)
    local function make_node(opts)
        local o = opts or {}
        local node = { ports = {}, sent = {}, lookups = {} }
        node.hosts = o.hosts or {}
        node.udp = { ports = node.ports }
        if o.lookup ~= nil then
            node.lookup = function(_, name)
                node.lookups[#node.lookups + 1] = name
                return o.lookup(name)
            end
        else
            node.lookup = function(_, name)
                node.lookups[#node.lookups + 1] = name
                return node.hosts[name]
            end
        end
        node.bind = function(_, port, cb)
            local socket = { port = port, handler = cb, closed = false, node = node }
            function socket:sendto(dst, dport, data)
                node.sent[#node.sent + 1] = {
                    dst = dst, port = dport, data = tostring(data), from = self.port,
                }
                if not o.silent and o.reply then
                    local response = o.reply(tostring(data), dst, dport)
                    if response ~= nil and self.handler then
                        self.handler(response, dst, dport, self)
                    end
                end
                return true
            end
            function socket:close()
                self.closed = true
                node.ports[self.port] = nil
            end
            node.ports[port] = socket
            return socket
        end
        return node
    end

    local function new_client(node, extra)
        local log, lines = H.logger()
        local opts = extra or {}
        opts.node = node
        opts.log = log
        local c = R.new(opts)
        return c, lines
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.url")
    do
        local url = R.parse_url("rhtp://store.pyrotechnic.org/index.txt")
        H.table("parse_table", url)
        H.eq("parse_scheme", url.scheme, "rhtp")
        H.eq("parse_host", url.host, "store.pyrotechnic.org")
        H.eq("parse_port_default", url.port, 8080)
        H.eq("parse_path", url.path, "/index.txt")

        local bare = R.parse_url("store.pyrotechnic.org:9000/pkg/a.txt")
        H.eq("bare_host", bare.host, "store.pyrotechnic.org")
        H.eq("bare_port", bare.port, 9000)
        H.eq("bare_path", bare.path, "/pkg/a.txt")

        H.eq("root_path", R.parse_url("rhtp://10.0.0.5/").path, "/")
        H.eq("empty_path_default", R.parse_url("rhtp://host").path, "/")

        -- the query string and fragment are stripped (documented), so one path
        -- has exactly one spelling on the wire
        H.eq("query_stripped",
            R.parse_url("rhtp://host/a.txt?x=1&y=2").path, "/a.txt")
        H.eq("fragment_stripped", R.parse_url("rhtp://host/a#z").path, "/a")
        H.eq("query_only", R.parse_url("rhtp://host/p?q").path, "/p")

        H.eq("upper_scheme", R.parse_url("RHTP://Host/X").host, "host")

        local bad, why = R.parse_url("http://store.pyrotechnic.org/")
        H.eq("http_refused", bad, nil)
        H.eq("http_refused_reason", why, "bad scheme")
        H.eq("https_refused", (R.parse_url("https://x/y")), nil)

        H.eq("bad_port_reason", select(2, R.parse_url("rhtp://host:0/x")), "bad port")
        H.eq("bad_port_high", select(2, R.parse_url("rhtp://host:70000/x")), "bad port")
        H.eq("no_host_reason", select(2, R.parse_url("rhtp:///x")), "bad host")
        H.eq("empty_url", select(2, R.parse_url("")), "bad url")
        H.eq("space_url", select(2, R.parse_url("rhtp://a b/x")), "bad url")

        -- path traversal is refused before any request is built
        H.eq("dotdot_refused", select(2, R.parse_url("rhtp://host/../etc/passwd")),
            "bad path")
        H.eq("dotdot_mid_refused", select(2, R.parse_url("rhtp://host/a/../b")),
            "bad path")
        H.eq("dot_refused", select(2, R.parse_url("rhtp://host/a/./b")), "bad path")
        H.eq("double_slash_refused", select(2, R.parse_url("rhtp://host/a//b")),
            "bad path")
        H.eq("backslash_refused", select(2, R.parse_url("rhtp://host/a\\b")), "bad path")
        H.eq("long_path_refused",
            select(2, R.parse_url("rhtp://host/" .. string.rep("a", 120))), "bad path")
        H.eq("relative_path_refused", select(2, R.parse_url("rhtp://host/a/../")),
            "bad path")
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.response")
    do
        local code, body = R.parse_response("RHTP/1.0 200 OK\r\n\r\nhello")
        H.eq("resp_code", code, 200)
        H.eq("resp_body", body, "hello")

        local code2, body2 = R.parse_response(
            "RHTP/1.0 206 Partial Content\r\n\r\nabc")
        H.eq("resp_206", code2, 206)
        H.eq("resp_206_body", body2, "abc")

        local code3, body3, headers = R.parse_response(
            "RHTP/1.0 200 OK\r\nX-DNS-Hash: deadbeef\r\n\r\npayload")
        H.eq("resp_header_code", code3, 200)
        H.eq("resp_header_body", body3, "payload")
        H.eq("resp_header_value", headers["x-dns-hash"], "deadbeef")

        H.eq("resp_empty_body",
            select(2, R.parse_response("RHTP/1.0 200 OK\r\n\r\n")), "")

        H.eq("resp_bad_version", select(2, R.parse_response(
            "HTTP/1.1 200 OK\r\n\r\nx")), "bad response")
        H.eq("resp_truncated", select(2, R.parse_response("RHTP/1.0 20 OK\r\n\r\nx")),
            "bad response")
        H.eq("resp_no_blank_line", select(2, R.parse_response("RHTP/1.0 200 OK")),
            "bad response")
        H.eq("resp_empty", select(2, R.parse_response("")), "bad response")
        H.eq("resp_not_string", select(2, R.parse_response(nil)), "bad response")
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.dns")
    do
        -- a static hosts table answers when the resolver (services.lua) does not
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/hello"] = "world" }),
        })
        local c, lines = new_client(node)
        local code, body = c:get("rhtp://box/hello")
        H.eq("hosts_code", code, 200)
        H.eq("hosts_body", body, "world")
        H.has(lines, "RHTP_RESOLVE host=box ip=10.0.0.9 source=hosts")
        H.has(lines, "RHTP_GET host=box ip=10.0.0.9 path=/hello code=200 bytes=5")

        -- a resolver answer (integer) is used directly
        local node2 = make_node({
            lookup = function(name)
                if name == "store" then return IP_STORE end
                return nil
            end,
            reply = server({ ["/index.txt"] = "app demo 1.0.0 demo" }),
        })
        local c2, lines2 = new_client(node2)
        local code2, body2 = c2:get("rhtp://store/index.txt")
        H.eq("lookup_code", code2, 200)
        H.eq("lookup_body", body2, "app demo 1.0.0 demo")
        H.eq("lookup_called", node2.lookups[1], "store")
        H.has(lines2, "RHTP_RESOLVE host=store ip=10.0.0.5")

        -- dotted decimal: no lookup at all
        local node3 = make_node({ reply = server({ ["/x"] = "y" }) })
        local c3 = new_client(node3)
        H.eq("direct_code", select(1, c3:get("rhtp://10.0.0.9/x")), 200)
        H.eq("direct_no_lookup", #node3.lookups, 0)

        -- unknown name: readable failure, no request sent, one log line
        local node4 = make_node({ lookup = function() return nil end })
        local c4, lines4 = new_client(node4)
        local code4, err4 = c4:get("rhtp://ghost/x")
        H.eq("dns_code", code4, nil)
        H.eq("dns_err", err4, "dns: unknown host")
        H.has(lines4, "RHTP_DNS_FAIL host=ghost")
        H.eq("dns_no_request", #node4.sent, 0)

        -- node.hosts without a lookup function still resolves (the image has no
        -- services.lua, so that table is the only resolver a real node has)
        local node5 = make_node({ hosts = { box = "10.0.0.9" },
            reply = server({ ["/x"] = "y" }) })
        node5.lookup = nil
        local c5 = new_client(node5)
        H.eq("hosts_table_code", select(1, c5:get("rhtp://box/x")), 200)

        -- debug=false silences only the success line
        local node6 = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/x"] = "y" }),
        })
        local c6, lines6 = new_client(node6, { debug = false })
        c6:get("rhtp://box/x")
        H.lacks("debug_off_no_resolve", lines6, "RHTP_RESOLVE")
        H.has(lines6, "RHTP_GET")
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.get")
    do
        local node = make_node({
            hosts = { box = IP_BOX, big = IP_BOX, bad = IP_BOX, junk = IP_BOX },
            lookup = function() return nil end,
            reply = server({
                ["/hello"] = "world",
                ["/big"] = "0123456789",
            }),
        })
        local c, lines = new_client(node)
        local code, body = c:get("rhtp://box/hello")
        H.eq("get_code", code, 200)
        H.eq("get_body", body, "world")
        H.eq("get_one_request", #node.sent, 1)
        H.eq("get_request_text", node.sent[1].data, "GET /hello")
        H.eq("get_dst", node.sent[1].dst, IP_BOX)
        H.eq("get_dport", node.sent[1].port, 8080)
        H.ge("get_local_port", node.sent[1].from, 49152)
        H.eq("get_counters", c:status().requests, 1)
        H.eq("get_bytes", c:status().bytes, #"RHTP/1.0 200 OK\r\n\r\nworld")

        -- bare "/path" targets use the client's configured host/port
        local c2, _ = new_client(node, { host = "box", port = 8181 })
        H.eq("bare_path_code", select(1, c2:get("/hello")), 200)
        H.eq("bare_path_request", node.sent[#node.sent].data, "GET /hello")
        H.eq("bare_path_port", node.sent[#node.sent].port, 8181)

        -- non-2xx: the status line parses, the body is never handed back
        local code404, err404 = c:get("rhtp://box/missing")
        H.eq("notfound_code", code404, nil)
        H.eq("notfound_err", err404, "rhtp 404")
        H.has(lines, "path=/missing code=404")

        -- a body over the per-request cap is refused, not truncated
        local codeBig, errBig = c:get("rhtp://box/big", { limit = 4 })
        H.eq("limit_code", codeBig, nil)
        H.eq("limit_err", errBig, "too large")
        H.has(lines, "RHTP_TOO_LARGE path=/big bytes=10 limit=4")

        -- a URL the parser refuses never reaches the network
        local before = #node.sent
        H.eq("bad_url_code", (c:get("http://box/hello")), nil)
        H.eq("bad_url_unchanged", #node.sent, before)
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.fetch")
    do
        -- 206 chunks: four bytes at a time over a ten byte body
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/file"] = "0123456789" }),
        })
        local c, lines = new_client(node, { max_bytes = 4 })
        local progress = {}
        local ok, body = c:fetch("rhtp://box/file", 10, {
            progress = function(done, total) progress[#progress + 1] = done .. "/" .. total end,
        })
        H.eq("fetch_ok", ok, true)
        H.eq("fetch_body", body, "0123456789")
        H.eq("fetch_requests", #node.sent, 3)
        H.eq("fetch_req1", node.sent[1].data, "GET /file off=0 len=4")
        H.eq("fetch_req2", node.sent[2].data, "GET /file off=4 len=4")
        H.eq("fetch_req3", node.sent[3].data, "GET /file off=8 len=2")
        H.eq("fetch_progress", table.concat(progress, ","), "4/10,8/10,10/10")
        H.eq("fetch_chunk_logs", H.count(lines, "RHTP_CHUNK"), 3)
        H.has(lines, "RHTP_CHUNK off=8 len=2 code=206 bytes=2")

        -- the server ignores off/len and answers 200 with the whole body
        local plain = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = function(request)
                local path = tostring(request):match("^GET (%S+)")
                if path == "/file" then return "RHTP/1.0 200 OK\r\n\r\n0123456789" end
                return "RHTP/1.0 404 Not Found\r\n\r\nnope"
            end,
        })
        local c2, lines2 = new_client(plain, { max_bytes = 4 })
        local ok2, body2 = c2:fetch("rhtp://box/file", 10)
        H.eq("fetch_plain_ok", ok2, true)
        H.eq("fetch_plain_body", body2, "0123456789")
        H.eq("fetch_plain_requests", #plain.sent, 1)
        H.has(lines2, "RHTP_CHUNK off=0 len=4 code=200 bytes=10")

        -- a short 206 segment is a failure, not silently accepted bytes
        local short = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = function() return "RHTP/1.0 206 Partial Content\r\n\r\nabc" end,
        })
        local c3 = new_client(short, { max_bytes = 4 })
        local ok3, why3 = c3:fetch("rhtp://box/file", 10)
        H.eq("fetch_short_ok", ok3, nil)
        H.eq("fetch_short_err", why3, "bad chunk 3/4")

        -- a 200 body of another length is refused before the caller hashes it
        local wrong = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = function() return "RHTP/1.0 200 OK\r\n\r\nabc" end,
        })
        local c4 = new_client(wrong, { max_bytes = 4 })
        local ok4, why4 = c4:fetch("rhtp://box/file", 10)
        H.eq("fetch_wrong_ok", ok4, nil)
        H.eq("fetch_wrong_err", why4, "size 3/10")

        -- unknown size: one plain GET
        local single = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/file"] = "abc" }),
        })
        local c5 = new_client(single)
        local ok5, body5 = c5:fetch("rhtp://box/file")
        H.eq("fetch_nosize_ok", ok5, true)
        H.eq("fetch_nosize_body", body5, "abc")
        H.eq("fetch_nosize_requests", #single.sent, 1)
    end

    -- -----------------------------------------------------------------
    H.group("rhtp.failures")
    do
        -- silent server: the deadline is reached and reported, one pump per wait
        local silent = make_node({ hosts = { box = IP_BOX }, lookup = function() end,
            silent = true })
        local clock = 0
        local pumps = 0
        local c, lines = new_client(silent, {
            timeout = 1,
            clock = function() return clock end,
            pump = function(seconds) pumps = pumps + 1; clock = clock + seconds end,
        })
        local code, err = c:get("rhtp://box/hello")
        H.eq("timeout_code", code, nil)
        H.eq("timeout_err", err, "timeout")
        H.eq("timeout_pumps", pumps, 1)
        H.has(lines, "RHTP_TIMEOUT ip=10.0.0.9 port=8080")
        H.eq("timeout_counter", c:status().failures, 1)

        -- no pump at all: still returns after the deadline (never spins)
        local silent2 = make_node({ hosts = { box = IP_BOX }, lookup = function() end,
            silent = true })
        local c2 = new_client(silent2, { timeout = 1 })
        local code2, err2 = c2:get("rhtp://box/hello")
        H.eq("nopump_code", code2, nil)
        H.eq("nopump_err", err2, "timeout")

        -- a response that is not RHTP at all
        local junk = make_node({
            hosts = { box = IP_BOX },
            lookup = function() end,
            reply = function() return "200 OK\r\n\r\nbody" end,
        })
        local c3, lines3 = new_client(junk)
        local code3, err3 = c3:get("rhtp://box/x")
        H.eq("junk_code", code3, nil)
        H.eq("junk_err", err3, "bad response")
        H.has(lines3, "RHTP_BAD_RESPONSE host=box path=/x")

        -- 500 is a readable reason, not a bad response
        local broken = make_node({
            hosts = { box = IP_BOX },
            lookup = function() end,
            reply = function() return "RHTP/1.0 500 Internal Server Error\r\n\r\nServer Error" end,
        })
        local c4 = new_client(broken)
        H.eq("server_err", select(2, c4:get("rhtp://box/x")), "rhtp 500")

        -- a socket that refuses to send is named, not ignored
        local dead = make_node({ hosts = { box = IP_BOX }, lookup = function() end })
        dead.bind = function(_, port)
            local socket = { port = port }
            function socket:sendto() return false end
            function socket:close() end
            return socket
        end
        local c5, lines5 = new_client(dead)
        H.eq("send_fail", select(2, c5:get("rhtp://box/x")), "send failed")
        H.has(lines5, "RHTP_SEND_FAIL ip=10.0.0.9 port=8080")

        -- no node at all: no network, no raise (a direct address skips the
        -- resolver, so this reaches the transport and stops there)
        local c6 = R.new({ log = function() end })
        H.eq("no_node_err", select(2, c6:get("rhtp://10.0.0.9/x")), "no network")
        H.eq("no_node_dns", select(2, c6:get("rhtp://box/x")), "dns: unknown host")

        -- two requests in a row reuse nothing stale: each binds and closes
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() end,
            reply = server({ ["/a"] = "a", ["/b"] = "b" }),
        })
        local c7 = new_client(node)
        H.eq("twice_1", select(2, c7:get("rhtp://box/a")), "a")
        H.eq("twice_2", select(2, c7:get("rhtp://box/b")), "b")
        H.eq("twice_ports", #node.ports, 0)
    end

    -- -----------------------------------------------------------------
    -- Sealing (DECISIONS.md 44). A sealed server seals every answer when the
    -- request line carries `Rhtp-Seal: 1 <nonce16>` and echoes that nonce.
    local secure = assert(S.new{ psk_hex = PSK, crypto = CRYPTO })
    local RAND_NONCE = "\169\170\171\172\173\174\175\176" -- 8 bytes

    -- opts: fail(return_type), bad_tag, bad_nonce, no_header
    local function sealed_server(routes, o)
        local so = o or {}
        return function(request)
            local text = tostring(request)
            local path = text:match("^GET (%S+)")
            local nonce16 = text:match("Rhtp%-Seal: 1 (%x+)$")
            local body = (routes or {})[path]
            if body == nil then
                return "RHTP/1.0 404 Not Found\r\n\r\nnope"
            end
            if so.no_header then
                return "RHTP/1.0 200 OK\r\n\r\n" .. body
            end
            local bn = nonce16 and CRYPTO.unhex(nonce16:lower()) or RAND_NONCE
            if so.bad_nonce then bn = bn:sub(1, 7) .. string.char(bn:byte(8) + 1) end
            local sealed = assert(secure:seal(200, "OK", body, bn))
            if so.bad_tag then
                -- flip one hex char in the tag field (the 32-hex token that
                -- ends the Rhtp-Seal line), leaving status/ciphertext intact
                local _, tag = sealed:match("(%x+)%s+(%x+)\r?\n\r?\n")
                sealed, _ = sealed:gsub("%x+\r?\n\r?\n",
                    (tag:sub(1, 1) == "a" and "b" or "a") .. tag:sub(2)
                        .. "\r\n\r\n", 1)
            end
            return sealed
        end
    end

    H.group("rhtp.sealed_header")
    do
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/hello"] = "world" }),
        })
        local c = new_client(node, {
            secure = secure,
            rand = function(n) return RAND_NONCE end,
        })
        local code, body = c:get("rhtp://box/hello")
        H.eq("seal_code", code, 200)
        H.eq("seal_body", body, "world")
        H.eq("seal_request", node.sent[1].data,
            "GET /hello Rhtp-Seal: 1 "
            .. CRYPTO.hex(RAND_NONCE))
    end

    H.group("rhtp.sealed_nosecret")
    do
        -- no secret/secure -> the old plaintext path, marker absent
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/hello"] = "world" }),
        })
        local c = new_client(node)
        local code, body = c:get("rhtp://box/hello")
        H.eq("nosecret_code", code, 200)
        H.eq("nosecret_body", body, "world")
        H.eq("nosecret_request", node.sent[1].data, "GET /hello")
    end

    H.group("rhtp.sealed_required")
    do
        -- a sealed request answered with a plain (unsealed) response fails
        -- closed with "seal required"
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/hello"] = "world" }, { no_header = true }),
        })
        local c, lines = new_client(node, {
            secure = secure,
            rand = function() return RAND_NONCE end,
        })
        local code, err = c:get("rhtp://box/hello")
        H.eq("required_code", code, nil)
        H.eq("required_err", err, "seal required")
        H.has(lines, "RHTP_SEAL_REQUIRED host=box path=/hello")
        H.eq("required_failures", c:status().failures, 1)
    end

    H.group("rhtp.seal_bad_tag")
    do
        -- a tampered tag fails the MAC -> "seal bad"
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/hello"] = "world" }, { bad_tag = true }),
        })
        local c, lines = new_client(node, {
            secure = secure,
            rand = function() return RAND_NONCE end,
        })
        local code, err = c:get("rhtp://box/hello")
        H.eq("badtag_code", code, nil)
        H.eq("badtag_err", err, "seal bad")
        H.has(lines, "RHTP_SEAL_BAD host=box path=/hello")
    end

    H.group("rhtp.seal_bad_nonce")
    do
        -- a response echoing a different nonce must fail the MAC too
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/hello"] = "world" }, { bad_nonce = true }),
        })
        local c, lines = new_client(node, {
            secure = secure,
            rand = function() return RAND_NONCE end,
        })
        local code, err = c:get("rhtp://box/hello")
        H.eq("badnonce_code", code, nil)
        H.eq("badnonce_err", err, "seal bad")
    end

    H.group("rhtp.sealed_chunk")
    do
        -- chunked fetch: each chunk carries its own fresh nonce
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = function(request)
                local text = tostring(request)
                local path = text:match("^GET (%S+)")
                local nonce16 = text:match("Rhtp%-Seal: 1 (%x+)$")
                local bn = nonce16 and CRYPTO.unhex(nonce16:lower()) or RAND_NONCE
                local body = "0123456789"
                if path == "/file" then
                    local off = tonumber(text:match("off=(%d+)"))
                    local len = tonumber(text:match("len=(%d+)"))
                    local seg = off and len and body:sub(off + 1, off + len) or body
                    return assert(secure:seal(206, "Partial Content", seg, bn))
                end
                return "RHTP/1.0 404 Not Found\r\n\r\nnope"
            end,
        })
        local c, lines = new_client(node, {
            max_bytes = 4,
            secure = secure,
            rand = function() return RAND_NONCE end,
        })
        local ok, body = c:fetch("rhtp://box/file", 10)
        H.eq("chunk_ok", ok, true)
        H.eq("chunk_body", body, "0123456789")
        H.eq("chunk_requests", #node.sent, 3)
        -- each request carries the seal marker (per-chunk nonce re-used for
        -- determinism here; the marker must be present on every chunk)
        for i = 1, #node.sent do
            H.has({ node.sent[i].data }, "Rhtp-Seal: 1")
        end
    end

    H.group("rhtp.sealed_mixed")
    do
        -- left insecure + right secure behave independently on one client set
        local plain = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/a"] = "A" }),
        })
        local c1 = new_client(plain)
        H.eq("mixed_plain", select(2, c1:get("rhtp://box/a")), "A")

        local secured = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/b"] = "B" }),
        })
        local c2 = new_client(secured, {
            secure = secure,
            rand = function() return RAND_NONCE end,
        })
        H.eq("mixed_sealed", select(2, c2:get("rhtp://box/b")), "B")
    end

    H.group("rhtp.secret_hex")
    do
        -- a 64-hex `secret` builds the secure object; a bad one stays plaintext
        local node = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = sealed_server({ ["/x"] = "y" }),
        })
        local c = new_client(node, {
            secret = PSK,
            rand = function() return RAND_NONCE end,
        })
        H.eq("secret_hex_code", select(1, c:get("rhtp://box/x")), 200)
        H.has({ node.sent[#node.sent].data }, "Rhtp-Seal")

        local nodeBad = make_node({
            hosts = { box = IP_BOX },
            lookup = function() return nil end,
            reply = server({ ["/x"] = "y" }),
        })
        local cBad = new_client(nodeBad, { secret = "nothex" })
        H.eq("secret_bad_code", select(1, cBad:get("rhtp://box/x")), 200)
        H.eq("secret_bad_request", nodeBad.sent[#nodeBad.sent].data, "GET /x")
    end
end
