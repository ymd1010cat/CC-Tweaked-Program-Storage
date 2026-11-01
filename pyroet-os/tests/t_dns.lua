--[[- pyroet-os/tests/t_dns.lua -- net/dns.lua: a real DNS QUERY.

Three layers are pinned down separately, because they fail differently:

  1. `dns.format`: name encoding and the query bytes (labels, case folding, the
     forbidden shapes, QTYPE=1/QCLASS=1, the id).
  2. `dns.response`: the parser against hand-built response bytes -- a normal A
     answer, a compressed answer name (0xC0xx), NXDOMAIN, a wrong id, a
     truncated packet, a pointer loop, an empty answer section.
  3. `dns.query`: the transport -- resolver selection from /etc/network.conf
     (`dns=`, `gateway`, neither), the 1 s x 2 tries deadline, the positive
     answer cache (TTL capped at 60 s, never for NXDOMAIN), the rpv.udp_send
     path, and every DNS_* log line.

A last group pins the resolver ORDER the RHTP client uses: node:lookup first,
then node.hosts, then the DNS module -- plus one end-to-end GET whose name only
the DNS module can answer.

Time is a counter here (`clock`) and the pump advances it, so a timeout case
finishes in microseconds instead of sleeping for a second.

No non-ASCII bytes in this file.
]]

local D = assert(loadfile("/system/net/dns.lua"))()
local R = assert(loadfile("/system/net/rhtp.lua"))()

return function(H)
    local IP_STORE = D.parse_ip("10.0.0.5")
    local IP_DNS = D.parse_ip("10.0.0.1")
    local IP_BOX = D.parse_ip("10.0.0.9")

    -- --- DNS bytes ------------------------------------------------------
    local function u16(n)
        n = math.floor(n) % 65536
        return string.char(math.floor(n / 256) % 256, n % 256)
    end
    local function u32(n)
        n = math.floor(n) % 4294967296
        return string.char(math.floor(n / 16777216) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    local function header(id, flags, qd, an)
        return u16(id) .. u16(flags) .. u16(qd) .. u16(an) .. u16(0) .. u16(0)
    end
    local function qname(name)
        local out = {}
        for label in (name:lower() .. "."):gmatch("([^.]*)%.") do
            out[#out + 1] = string.char(#label) .. label
        end
        out[#out + 1] = "\0"
        return table.concat(out)
    end
    local function question(name)
        return qname(name) .. u16(1) .. u16(1)
    end
    local function ip_bytes(ip_text)
        local ip = D.parse_ip(ip_text)
        return string.char(math.floor(ip / 16777216) % 256,
            math.floor(ip / 65536) % 256, math.floor(ip / 256) % 256, ip % 256)
    end
    local function a_record(name_bytes, ip_text, ttl)
        return name_bytes .. u16(1) .. u16(1) .. u32(ttl) .. u16(4)
            .. ip_bytes(ip_text)
    end
    -- a 0xC0xx pointer to the question name at offset 12 (1-based 13)
    local PTR_QUESTION = "\192\012"

    -- --- fake node / clock ----------------------------------------------
    -- opts.reply(request, dst, dport, n) -> response string|nil; a nil answer is
    -- the "silent server" timeout case
    local function fake_node(opts)
        local o = opts or {}
        local node = { ports = {}, sent = {}, lookups = {} }
        node.udp = { ports = node.ports }
        if o.lookup ~= nil then
            node.lookup = function(_, name)
                node.lookups[#node.lookups + 1] = name
                return o.lookup(name)
            end
        end
        node.hosts = o.hosts or {}
        node.bind = function(_, port, cb)
            local socket = { port = port, handler = cb, closed = false }
            function socket:sendto(dst, dport, data)
                node.sent[#node.sent + 1] = {
                    dst = dst, port = dport, data = tostring(data), from = self.port,
                }
                if o.reply then
                    local response = o.reply(tostring(data), dst, dport, #node.sent)
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

    local function fake_time()
        local env = { now = 0 }
        env.clock = function() return env.now end
        -- one pump pass consumes the whole remaining wait: the deadline is hit
        -- after one step per attempt, so a 1 s timeout costs no wall clock
        env.pump = function(seconds) env.now = env.now + (tonumber(seconds) or 0) end
        return env
    end

    local function resolver(node, extra)
        local log, lines = H.logger()
        local o = extra or {}
        o.node = node
        o.log = log
        local obj = D.new(o)
        return obj, lines
    end

    local function id_of(request)
        return request:byte(1) * 256 + request:byte(2)
    end

    -- one A answer for the question carried in `request`
    local function answer_for(request, ip_text, ttl, ptr)
        local id = id_of(request)
        local name = ptr and PTR_QUESTION or request:sub(13, 13 + #qname("store") - 1)
        return header(id, 0x8180, 1, 1) .. request:sub(13)
            .. a_record(name, ip_text, ttl)
    end

    -- -----------------------------------------------------------------
    H.group("dns.format")
    do
        H.eq("encode_simple", D.encode_name("a.b"), "\1a\1b\0")
        H.eq("encode_fold", D.encode_name("Store.PyroTechnic.ORG"),
            "\5store\11pyrotechnic\3org\0")
        H.eq("encode_hyphen", D.encode_name("a-b.c_1"), "\3a-b\3c_1\0")

        local bad = { "", "a..b", ".a", "a.", "bad name", "a!b", "a b",
            string.rep("a", 64), string.rep("a.", 127), string.rep("ab.", 90) }
        local rejected = 0
        for i = 1, #bad do
            local wire = D.encode_name(bad[i])
            if wire == nil then rejected = rejected + 1 end
        end
        H.eq("encode_rejections", rejected, #bad)

        local query = D.build_query("store", 0x1234)
        H.eq("query_type", type(query), "string")
        H.eq("query_len", #query, 12 + 7 + 4)
        H.eq("query_id", id_of(query), 0x1234)
        H.eq("query_flags_rd", query:byte(3) * 256 + query:byte(4), 0x0100)
        H.eq("query_qdcount", query:byte(5) * 256 + query:byte(6), 1)
        H.eq("query_ancount", query:byte(7) * 256 + query:byte(8), 0)
        H.contains("query_name", query, "\5store\0")
        H.eq("query_qtype", query:sub(-4, -3):byte(1) * 256 + query:sub(-4, -3):byte(2), 1)
        H.eq("query_qclass", query:sub(-2):byte(1) * 256 + query:sub(-2):byte(2), 1)
        H.eq("query_build_bad_name", (D.build_query("a..b", 1)), nil)

        H.eq("parse_ip", D.parse_ip("10.0.0.9"), IP_BOX)
        H.eq("parse_ip_leading_zero", D.parse_ip("10.0.0.09"), nil)
        H.eq("int2ip", D.int2ip(IP_STORE), "10.0.0.5")
        H.ascii_check("format_ascii", "encode store 5 bytes")
    end

    -- -----------------------------------------------------------------
    H.group("dns.response")
    do
        -- a normal A answer
        local ok = header(7, 0x8180, 1, 1) .. question("store")
            .. a_record(PTR_QUESTION, "10.0.0.5", 300)
        local ip, ttl, why = D.parse_response(ok, 7)
        H.eq("answer_ip", ip, IP_STORE)
        H.eq("answer_ttl", ttl, 300)
        H.eq("answer_no_reason", why, nil)
        -- an uncompressed answer name is read the same way
        local plain = header(7, 0x8180, 1, 1) .. question("store")
            .. a_record(qname("store"), "10.0.0.5", 30)
        H.eq("answer_plain_name", (D.parse_response(plain, 7)), IP_STORE)

        -- the id must match, QR must be set
        H.eq("answer_wrong_id", select(3, D.parse_response(ok, 8)), "bad id")
        local query_only = header(7, 0x0100, 1, 1) .. question("store")
        H.eq("answer_not_a_response", select(3, D.parse_response(query_only, 7)),
            "bad packet")

        -- NXDOMAIN
        local nx = header(7, 0x8183, 1, 0) .. question("ghost")
        H.eq("answer_nxdomain_reason", select(3, D.parse_response(nx, 7)), "nxdomain")

        -- truncation (TC=1) is its own failure, not a bad packet
        local tc = header(7, 0x8380, 1, 0) .. question("store")
        H.eq("answer_truncated", select(3, D.parse_response(tc, 7)), "truncated")

        -- a packet cut after the question but claiming one answer
        local cut = header(7, 0x8180, 1, 1) .. question("store")
        H.eq("answer_cut_reason", select(3, D.parse_response(cut, 7)), "bad packet")
        H.eq("answer_runt", select(3, D.parse_response("\1\2\3", 7)), "bad packet")
        H.eq("answer_no_answer", select(3, D.parse_response(
            header(7, 0x8180, 1, 0) .. question("store"), 7)), "no answer")

        -- a pointer loop: the answer name points at itself, so the jump budget
        -- has to stop it (offset of the answer name is 24, 1-based)
        local loop_head = header(7, 0x8180, 1, 1) .. question("store")
        H.eq("loop_name_offset", #loop_head + 1, 24)
        local loop = loop_head .. "\192\023" .. u16(1) .. u16(1) .. u32(30)
            .. u16(4) .. ip_bytes("10.0.0.5")
        H.eq("answer_pointer_loop", select(3, D.parse_response(loop, 7)), "bad packet")
        -- a pointer past the end of the packet
        local away = loop_head .. "\192\200" .. u16(1) .. u16(1) .. u32(30)
            .. u16(4) .. ip_bytes("10.0.0.5")
        H.eq("answer_pointer_oob", select(3, D.parse_response(away, 7)), "bad packet")
        H.eq("name_end_zero", D.name_end("\0", 1), 2)
        H.eq("name_end_bad_label", select(2, D.name_end("\64", 1)), "bad packet")
    end

    -- -----------------------------------------------------------------
    H.group("dns.query")
    do
        local cfg = "ip=10.0.0.5/24\ngateway=10.0.0.1\ndns=10.0.0.1\n"

        -- a positive answer: right server, right port, right id, one log pair
        local node = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 30)
        end })
        local dns, lines = resolver(node, { config = cfg })
        local ip, text = dns:query("store")
        H.eq("query_ip", ip, IP_STORE)
        H.eq("query_text", text, "10.0.0.5")
        H.eq("query_sent_count", #node.sent, 1)
        H.eq("query_sent_dst", node.sent[1].dst, IP_DNS)
        H.eq("query_sent_port", node.sent[1].port, 53)
        H.eq("query_sent_from_ephemeral",
            node.sent[1].from >= D.CLIENT_PORT_FIRST
            and node.sent[1].from <= D.CLIENT_PORT_LAST, true)
        H.eq("query_sent_id", id_of(node.sent[1].data) ~= 0, true)
        H.has(lines, "DNS_QUERY host=store server=10.0.0.1")
        H.has(lines, "DNS_ANSWER host=store ip=10.0.0.5 ttl=30")

        -- cache: a second lookup sends nothing, and the name is case-insensitive
        H.eq("cache_second", (dns:query("STORE")), IP_STORE)
        H.eq("cache_no_second_send", #node.sent, 1)
        H.eq("cache_hits", dns:stats().cache_hits, 1)
        H.eq("cache_entries", dns:stats().cached, 1)

        -- TTL is capped at 60 s: 61 s later the answer is gone
        local cached_at = dns:now()
        dns.clock = function() return cached_at + 61 end
        H.eq("cache_expired_refetch", (dns:query("store")), IP_STORE)
        H.eq("cache_expired_sent", #node.sent, 2)

        -- a long TTL is capped, a zero TTL is not cached at all
        local node_t = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 300)
        end })
        local env_t = fake_time()
        local dns_t, lines_t = resolver(node_t, { config = cfg, clock = env_t.clock,
            pump = env_t.pump })
        dns_t:query("store")
        H.has(lines_t, "DNS_ANSWER host=store ip=10.0.0.5 ttl=60")
        H.eq("ttl_capped_stats", dns_t:stats().cached, 1)
        local node_zero = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 0)
        end })
        local dns_zero = resolver(node_zero, { config = cfg })
        dns_zero:query("store")
        dns_zero:query("store")
        H.eq("ttl_zero_not_cached_sends", #node_zero.sent, 2)
        H.eq("ttl_zero_stats", dns_zero:stats().cached, 0)

        -- NXDOMAIN: readable reason, its own log, never cached
        local node_nx = fake_node({ reply = function(request)
            return header(id_of(request), 0x8183, 1, 0) .. request:sub(13)
        end })
        local dns_nx, lines_nx = resolver(node_nx, { config = cfg })
        local nx_ip, nx_err = dns_nx:query("ghost")
        H.eq("nxdomain_nil", nx_ip, nil)
        H.eq("nxdomain_reason", nx_err, "dns: nxdomain")
        H.has(lines_nx, "DNS_NXDOMAIN host=ghost server=10.0.0.1")
        H.eq("nxdomain_not_cached", dns_nx:stats().cached, 0)
        dns_nx:query("ghost")
        H.eq("nxdomain_asked_twice", #node_nx.sent, 2)

        -- a silent server: tries x timeout, one DNS_TIMEOUT line
        local node_dead = fake_node({ reply = nil })
        local env = fake_time()
        local dns_dead, lines_dead = resolver(node_dead, { config = cfg,
            clock = env.clock, pump = env.pump })
        local dead_ip, dead_err = dns_dead:query("store")
        H.eq("timeout_nil", dead_ip, nil)
        H.eq("timeout_reason", dead_err, "dns: timeout")
        H.eq("timeout_sends", #node_dead.sent, 2)
        H.eq("timeout_deadline", env.now >= 2, true)
        H.eq("timeout_log_count", H.count(lines_dead, "DNS_TIMEOUT"), 1)
        H.has(lines_dead, "DNS_TIMEOUT host=store server=10.0.0.1 tries=2")
        H.eq("timeout_stats", dns_dead:stats().timeouts, 1)

        -- a wrong id is a bad packet (and the query is retried once)
        local node_id = fake_node({ reply = function(request)
            local id = (id_of(request) + 1) % 65536
            return header(id, 0x8180, 1, 1) .. request:sub(13)
                .. a_record(PTR_QUESTION, "10.0.0.5", 30)
        end })
        local dns_id, lines_id = resolver(node_id, { config = cfg })
        H.eq("bad_id_reason", select(2, dns_id:query("store")), "dns: bad packet")
        H.eq("bad_id_sends", #node_id.sent, 2)
        H.has(lines_id, "DNS_BAD_PACKET host=store err=bad id")

        -- a truncated answer is a bad packet too
        local node_tc = fake_node({ reply = function(request)
            return header(id_of(request), 0x8380, 1, 0) .. request:sub(13)
        end })
        local dns_tc, lines_tc = resolver(node_tc, { config = cfg })
        H.eq("truncated_reason", select(2, dns_tc:query("store")), "dns: bad packet")
        H.has(lines_tc, "DNS_BAD_PACKET host=store err=truncated")

        -- no dns key and no gateway: no packet at all
        local node_none = fake_node()
        local dns_none, lines_none = resolver(node_none,
            { config = "ip=10.0.0.5/24\n" })
        H.eq("no_dns_reason", select(2, dns_none:query("store")), "dns: no dns")
        H.eq("no_dns_sends", #node_none.sent, 0)
        H.lacks("no_dns_no_query_line", lines_none, "DNS_QUERY")

        -- an omitted dns= falls back to the gateway
        local node_gw = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 30)
        end })
        local dns_gw = resolver(node_gw,
            { config = "ip=10.0.0.5/24\ngateway=10.0.0.1\n" })
        H.eq("gateway_fallback_ip", (dns_gw:query("store")), IP_STORE)
        H.eq("gateway_fallback_dst", node_gw.sent[1].dst, IP_DNS)

        -- dns=0: the cache is off, the gateway is still the server
        local node_off = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 60)
        end })
        local dns_off = resolver(node_off,
            { config = "ip=10.0.0.5/24\ngateway=10.0.0.1\ndns=0\n" })
        dns_off:query("store")
        dns_off:query("store")
        H.eq("dns_zero_sends", #node_off.sent, 2)
        H.eq("dns_zero_stats", dns_off:stats().cache_enabled, false)
        H.eq("dns_zero_server", dns_off:stats().server, "10.0.0.1")

        -- a malformed dns= is reported and the gateway is used
        local node_bad = fake_node({ reply = function(request)
            return answer_for(request, "10.0.0.5", 30)
        end })
        local dns_bad, lines_bad = resolver(node_bad,
            { config = "ip=10.0.0.5/24\ngateway=10.0.0.1\ndns=10.0.0\n" })
        H.eq("bad_dns_ip", (dns_bad:query("store")), IP_STORE)
        H.has(lines_bad, "DNS_CONFIG_BAD key=dns value=10.0.0")
        H.eq("bad_dns_fallback_dst", node_bad.sent[1].dst, IP_DNS)

        -- no socket at all: a readable failure, no crash
        local bare = D.new({ log = function() end, config = cfg })
        H.eq("no_network_reason", select(2, bare:query("store")), "dns: no network")
        H.eq("bad_name_reason", select(2, dns_none:query("a..b")), "dns: bad name")

        -- the rpv.udp_send path (the socket API would be the fallback)
        local sent_rpv = {}
        local node_rpv = fake_node()
        local dns_rpv, lines_rpv = resolver(node_rpv, { config = cfg,
            rpv = { udp_send = function(node, dst, sport, dport, data, ttl)
                sent_rpv[#sent_rpv + 1] = {
                    node = node, dst = dst, sport = sport, dport = dport,
                    data = data, ttl = ttl,
                }
                local socket = node.ports[sport]
                if socket and socket.handler then
                    socket.handler(header(id_of(data), 0x8180, 1, 1)
                        .. data:sub(13) .. a_record(PTR_QUESTION, "10.0.0.5", 30))
                end
                return true
            end } })
        H.eq("rpv_send_ip", (dns_rpv:query("store")), IP_STORE)
        H.eq("rpv_send_count", #sent_rpv, 1)
        H.eq("rpv_send_node", sent_rpv[1].node, node_rpv)
        H.eq("rpv_send_dst", sent_rpv[1].dst, IP_DNS)
        H.eq("rpv_send_dport", sent_rpv[1].dport, 53)
        H.eq("rpv_send_ttl", sent_rpv[1].ttl, 64)
        H.eq("rpv_send_ephemeral", sent_rpv[1].sport >= D.CLIENT_PORT_FIRST
            and sent_rpv[1].sport <= D.CLIENT_PORT_LAST, true)
        H.eq("rpv_no_socket_send", #node_rpv.sent, 0)
        H.has(lines_rpv, "DNS_ANSWER host=store ip=10.0.0.5 ttl=30")
        H.ascii_check("query_ascii", H.joined(lines) .. H.joined(lines_dead)
            .. H.joined(lines_nx))
    end

    -- -----------------------------------------------------------------
    H.group("dns.rhtp")
    do
        -- order 1: node:lookup answers, the DNS module is never touched
        local order = {}
        local node1 = fake_node({
            lookup = function(name)
                order[#order + 1] = "lookup"
                if name == "store" then return IP_STORE end
                return nil
            end,
            reply = function() return "RHTP/1.0 200 OK\r\n\r\nhi" end,
        })
        local asked1 = 0
        local log1, lines1 = H.logger()
        local c1 = R.new({ node = node1, log = log1, dns = {
            query = function() asked1 = asked1 + 1 return nil, "dns: nxdomain" end,
        } })
        H.check("lookup_first", c1:get("rhtp://store/x") == 200, "lookup did not answer")
        H.eq("lookup_order", table.concat(order, ","), "lookup")
        H.eq("lookup_no_dns", asked1, 0)
        H.has(lines1, "RHTP_RESOLVE host=store ip=10.0.0.5")

        -- order 2: node.hosts answers before the DNS module
        order = {}
        local node2 = fake_node({ hosts = { store = IP_STORE },
            reply = function() return "RHTP/1.0 200 OK\r\n\r\nhi" end })
        local asked2 = 0
        local log2, lines2 = H.logger()
        local c2 = R.new({ node = node2, log = log2, dns = {
            query = function() asked2 = asked2 + 1 return nil end,
        } })
        c2:get("rhtp://store/x", { timeout = 1 })
        H.eq("hosts_no_dns", asked2, 0)
        H.has(lines2, "RHTP_RESOLVE host=store ip=10.0.0.5 source=hosts")

        -- order 3: neither answers, the DNS query runs and its answer is used
        local node3 = fake_node({
            reply = function(request, dst, dport)
                if dport == 53 then return answer_for(request, "10.0.0.5", 30) end
                return "RHTP/1.0 200 OK\r\n\r\nworld"
            end,
        })
        local dns3 = D.new({ node = node3, config = "ip=10.0.0.5\ndns=10.0.0.1\n",
            log = function() end })
        local log3, lines3 = H.logger()
        local c3 = R.new({ node = node3, log = log3, dns = dns3 })
        local code3, body3 = c3:get("rhtp://store/x")
        H.eq("dns_code", code3, 200)
        H.eq("dns_body", body3, "world")
        H.has(lines3, "RHTP_RESOLVE host=store ip=10.0.0.5 source=dns")
        local dns_packets, http_packets = 0, 0
        for i = 1, #node3.sent do
            if node3.sent[i].port == 53 then dns_packets = dns_packets + 1
            elseif node3.sent[i].port == 8080 then http_packets = http_packets + 1 end
        end
        H.eq("dns_one_query", dns_packets, 1)
        H.eq("dns_then_http", http_packets, 1)

        -- all three fail: the readable failure keeps its RHTP contract
        local node4 = fake_node({ lookup = function() return nil end })
        local log4, lines4 = H.logger()
        local c4 = R.new({ node = node4, log = log4, dns = {
            query = function() return nil, "dns: nxdomain" end,
        } })
        H.eq("all_fail_nil", (c4:get("rhtp://ghost/x")), nil)
        H.has(lines4, "RHTP_DNS_FAIL host=ghost err=dns: nxdomain")
        H.eq("all_fail_no_packet", #node4.sent, 0)

        -- dns = false: no module is even loaded (the third source is off)
        local node5 = fake_node()
        local c5 = R.new({ node = node5, log = function() end, dns = false })
        H.eq("dns_off_reason", select(2, c5:resolve("ghost")), "dns: unknown host")
    end
end
