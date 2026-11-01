--[[- tests/t_rhtp_client.lua - apps/rhtp_client.lua: request building, response
parsing, the injected-transport request/retry path, and the two rpv transports
(asynchronous call() and the blocking harness transport). The asynchronous test
runs the real apps/rhtp_server.lua over a stub node + stub rpv pair, so one
datagram really travels client -> server -> client inside the process.
]]
local T, M = ...

local RC = M.rhtp_client
local RS = M.rhtp_server
T.ok(RC ~= nil, "rhtp_client module is loaded")
T.ok(RS ~= nil, "rhtp_server module is loaded (for the end-to-end cases)")
if not RC then return end

local WELCOME = "RHTP/1.0 200 OK\r\n\r\nWelcome to InterTeamNet"
local NOT_FOUND = "RHTP/1.0 404 Not Found\r\n\r\nPage Not Found"

local DNS_DB = "dns_db.txt"
local DIRECTORY = "ip_directory.txt"

local function clean(path)
    if fs.exists(path) then pcall(fs.delete, path) end
end

local function write(path, text)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

-- ===== module surface =======================================================
T.eq(RC.VERSION, "1.0", "the client version is 1.0")
T.eq(RC.PROTOCOL, "RHTP/1.0", "the wire protocol is RHTP/1.0")
T.eq(RC.DEFAULT_PORT, 8080, "the default port is 8080")
T.eq(RC.DEFAULT_TIMEOUT_MS, 3000, "the default timeout is 3000 ms")
T.eq(RC.DEFAULT_LOCAL_PORT, 40000, "ephemeral ports start at 40000")
T.ok(type(RC.build_request) == "function", "build_request is exported")
T.ok(type(RC.parse_response) == "function", "parse_response is exported")
T.ok(type(RC.call) == "function", "call is exported")
T.ok(type(RC.rpv_transport) == "function", "rpv_transport is exported")

-- ===== request building =====================================================
T.eq(RC.build_request("GET", "/"), "GET / RHTP/1.0\r\n\r\n",
    "a bare GET carries the request line and the blank line")
T.eq(RC.build_request(nil, "/x"), "GET /x RHTP/1.0\r\n\r\n", "the method defaults to GET")
T.eq(RC.build_request("GET", "/api/directory", { Accept = "*/*" }),
    "GET /api/directory RHTP/1.0\r\nAccept: */*\r\n\r\n",
    "headers follow the request line, sorted by name")
T.eq(RC.build_request("GET", "/", { b = "2", a = "1" }),
    "GET / RHTP/1.0\r\na: 1\r\nb: 2\r\n\r\n", "header order is deterministic")
T.eq(RC.build_request("GET", "/probe", nil, "body"), "GET /probe RHTP/1.0\r\n\r\nbody",
    "a body is appended after the blank line")

local bad, berr = RC.build_request("get", "/")
T.eq(bad, nil, "a lowercase method is rejected")
T.ok(berr ~= nil, "the lowercase-method error is reported")
T.eq((RC.build_request("GET", "x")), nil, "a relative path is rejected")
T.eq((RC.build_request("GET", "/a b")), nil, "a path with whitespace is rejected")
T.eq((RC.build_request("GET", "/x", { ["Bad Name"] = "1" })), nil, "a bad header name is rejected")
T.eq((RC.build_request("GET", "/x", { ["A"] = "v\r\nInjected: 1" })), nil,
    "a header value with CRLF is rejected")
T.eq((RC.build_request("GET", "/x", nil, 42)), nil, "a non-string body is rejected")

-- ===== response parsing =====================================================
local ok_res, perr = RC.parse_response(WELCOME)
T.ok(type(ok_res) == "table", "a well-formed 200 parses")
T.eq(perr, nil, "parsing a good response reports no error")
T.eq(ok_res.status, 200, "the status code is numeric")
T.eq(ok_res.reason, "OK", "the reason phrase is kept")
T.eq(ok_res.version, "RHTP/1.0", "the response version is kept")
T.eq(ok_res.body, "Welcome to InterTeamNet", "the body is everything after the blank line")
T.eq(ok_res.ok, true, "a parsed response is marked ok")

local hres = RC.parse_response("RHTP/1.0 200 OK\r\nX-DNS-Hash: abc\r\nContent: x\r\n\r\nbody\r\n")
T.eq(hres.body, "body\r\n", "the body may itself contain CRLF")
T.eq(RC.header(hres, "x-dns-hash"), "abc", "header lookup is case-insensitive")
T.eq(RC.header(hres, "X-DNS-HASH"), "abc", "header lookup ignores the caller's case")
T.eq(RC.header(hres, "missing"), nil, "an absent header is nil")
T.eq(RC.header(hres, "Content"), "x", "the second header is parsed")
T.eq(#hres.raw_headers, 2, "raw_headers keeps every header line")

T.eq(RC.parse_response(""), nil, "an empty datagram does not parse")
T.eq(RC.parse_response(nil), nil, "a nil datagram does not parse")
T.eq(RC.parse_response("RHTP/1.0 200 OK\r\nbody-without-separator"), nil,
    "a response without the header terminator does not parse")
T.eq(RC.parse_response("nonsense\r\n\r\nbody"), nil, "a bad status line does not parse")
local _, herr = RC.parse_response("RHTP/1.0 200 OK\r\nnot-a-header\r\n\r\nbody")
T.ok(herr ~= nil, "a malformed header line is reported")

local r404 = RC.parse_response(NOT_FOUND)
T.eq(r404.status, 404, "a 404 parses")
T.eq(r404.body, "Page Not Found", "the 404 body is kept")
T.eq(RC.parse_response("RHTP/1.0 500 Internal Server Error\r\n\r\nServer Error").status, 500,
    "a 500 parses")

-- ===== X-DNS-Hash verification ==============================================
local sha, hex = M.sha256, M.hex
T.ok(type(sha) == "function" and type(hex) == "function", "the harness exposes sha256/hex")
local BODY = "alpha.example 10.200.0.10\n"
local good = RC.parse_response("RHTP/1.0 200 OK\r\nX-DNS-Hash: " .. hex(sha(BODY)) .. "\r\n\r\n" .. BODY)
T.eq((RC.verify_dns_hash(good, sha, hex)), true, "a matching X-DNS-Hash verifies")
local badhash = RC.parse_response("RHTP/1.0 200 OK\r\nX-DNS-Hash: " .. string.rep("0", 64) .. "\r\n\r\n" .. BODY)
local okv, why = RC.verify_dns_hash(badhash, sha, hex)
T.eq(okv, false, "a wrong X-DNS-Hash is rejected")
T.eq(why, "hash mismatch", "the mismatch reason is reported")
T.eq((RC.verify_dns_hash(RC.parse_response(WELCOME), sha, hex)), false,
    "a response without the header is rejected")
-- the header alone is not enough: the digest covers the body
local swapped = RC.parse_response("RHTP/1.0 200 OK\r\nX-DNS-Hash: " .. hex(sha(BODY)) .. "\r\n\r\nother\n")
T.eq((RC.verify_dns_hash(swapped, sha, hex)), false, "a body swapped after signing is rejected")

-- ===== request/get over an injected transport ===============================
clean(DNS_DB)
clean(DIRECTORY)

local function via_server(payload)
    return RS.handle_request(payload)
end

local r1 = RC.get{ path = "/", transport = via_server }
T.eq(r1.ok, true, "get() over the real router succeeds")
T.eq(r1.status, 200, "the welcome route answers 200")
T.eq(r1.body, "Welcome to InterTeamNet", "the welcome body arrives")
T.eq(r1.attempts, 1, "a first-try success reports one attempt")

local r404b = RC.get{ path = "/nope", transport = via_server }
T.eq(r404b.status, 404, "a 404 is a parsed response, not an error")
T.eq(r404b.body, "Page Not Found", "the 404 body arrives")

local rdir = RC.get{ path = "/api/directory", transport = via_server }
T.eq(rdir.body, RS.FALLBACK_DIRECTORY, "the directory fallback arrives")
T.eq(RC.header(rdir, "X-DNS-Hash"), nil, "the plain directory has no hash header")

T.ok(write(DNS_DB, BODY), "the DNS mirror fixture is written")
local rm = RC.get{ path = "/api/dns_mirror", transport = via_server }
T.eq(rm.status, 200, "the mirror answers 200")
T.eq(rm.body, BODY, "the mirror body arrives")
T.eq((RC.verify_dns_hash(rm, sha, hex)), true, "the mirror reply verifies against its header")

local rq = RC.get{ path = "/?probe=1", transport = via_server }
T.eq(rq.status, 200, "a query string is still routed by the server")

-- ===== retries =============================================================
local calls = 0
local flaky = function(payload)
    calls = calls + 1
    if calls < 3 then return nil, "simulated loss" end
    return via_server(payload)
end
local r2 = RC.get{ path = "/", transport = flaky, retries = 3, sleep = function() end }
T.eq(calls, 3, "a lossy transport is retried until it answers")
T.eq(r2.ok, true, "a retried request finally succeeds")
T.eq(r2.attempts, 3, "the successful attempt number is reported")

local always = function() return nil, "down" end
local r3 = RC.get{ path = "/", transport = always, retries = 1, sleep = function() end }
T.eq(r3.ok, false, "an exhausted retry budget fails")
T.eq(r3.err, "down", "the transport error is surfaced")
T.eq(r3.attempts, 2, "one retry means two attempts")

local noT = RC.get{ path = "/" }
T.eq(noT.ok, false, "a missing transport fails")
T.eq(noT.err, "no transport", "the missing-transport reason is reported")

-- ===== asynchronous call() over a stub node + stub rpv ======================
local CLIENT_IP, SERVER_IP = 0x0A00000A, 0x0A000002

local function make_node()
    local node = { udp = { ports = {} }, timers = {}, logs = {} }
    function node:bind(port, cb)
        if self.udp.ports[port] then error("port in use: " .. tostring(port)) end
        local sk = { port = port, node = self, handler = cb }
        function sk:on_receive(fn) self.handler = fn end
        function sk:sendto(dst, dport, data) return true end
        function sk:close() self.node.udp.ports[self.port] = nil end
        self.udp.ports[port] = sk
        return sk
    end
    function node:after(sec, fn)
        self.timers[#self.timers + 1] = { sec = sec, fn = fn }
        return #self.timers
    end
    function node:log(fmt, ...) self.logs[#self.logs + 1] = tostring(fmt) end
    function node:tick() end
    return node
end

-- one shared wire: a datagram addressed to a bound port is delivered there with
-- the peer address as its source (the client leg and the server leg are told
-- apart by the destination port)
local function make_rpv()
    local rpv = { sent = {} }
    function rpv.udp_send(n, dst, sport, dport, data)
        rpv.sent[#rpv.sent + 1] = { dst = dst, sport = sport, dport = dport, data = data }
        local sk = n.udp.ports[dport]
        if not sk or not sk.handler then return false end
        local from = SERVER_IP
        if dport == RS.DEFAULT_PORT then from = CLIENT_IP end
        sk.handler(data, from, sport)
        return true
    end
    rpv.ip2int = M.ip2int
    rpv.sha256 = sha
    rpv.hex = hex
    return rpv
end

local node = make_node()
local rpv = make_rpv()
local server_sock = RS.start_rhtp(node, RS.DEFAULT_PORT, rpv)
T.ok(server_sock ~= nil, "the server binds its port on the stub node")

local got, gerr = nil, nil
local sk = RC.call(node, rpv, { addr = SERVER_IP, path = "/" }, function(res, err)
    got, gerr = res, err
end)
T.ok(sk ~= nil, "call() returns the local socket")
T.eq(gerr, nil, "the end-to-end call reports no transport error")
T.ok(type(got) == "table", "the end-to-end call delivered a response")
T.eq(got and got.status, 200, "the welcome route answers 200 over the wire")
T.eq(got and got.body, "Welcome to InterTeamNet", "the welcome body crosses the wire")
T.eq(got and got.from, SERVER_IP, "the response records the server address")
T.eq(got and got.from_port, RS.DEFAULT_PORT, "the response records the server port")
T.eq(node.udp.ports[40000], nil, "the ephemeral client port is released after the reply")
T.eq(#rpv.sent >= 2, true, "both legs of the exchange went through rpv.udp_send")

-- a second call must get a fresh ephemeral port (40000 was released)
local got2 = nil
RC.call(node, rpv, { addr = SERVER_IP, path = "/missing" }, function(res) got2 = res end)
T.eq(got2 and got2.status, 404, "a second call reaches the server and gets a 404")

-- the DNS mirror over the real wire, verified end to end
local got3 = nil
RC.call(node, rpv, { addr = SERVER_IP, path = "/api/dns_mirror" }, function(res) got3 = res end)
T.eq(got3 and got3.body, BODY, "the mirror body crosses the wire")
T.eq((got3 and RC.verify_dns_hash(got3, sha, hex)), true, "the wire mirror verifies")

-- a hostname destination is resolved through rpv.ip2int
local got4 = nil
RC.call(node, rpv, { host = "10.0.0.2", path = "/" }, function(res) got4 = res end)
T.eq(got4 and got4.status, 200, "a hostname destination is resolved through rpv.ip2int")

-- no listener: the send is accepted but no reply arrives; the node timer fires
local got5, err5 = nil, nil
RC.call(node, rpv, { addr = SERVER_IP, port = 9999, path = "/", timeout_ms = 250 },
    function(res, err) got5, err5 = res, err end)
T.eq(got5, nil, "an unanswered call delivers no response")
T.eq(err5, nil, "the callback has not fired before the timer runs")
local timer = node.timers[#node.timers]
T.ok(timer ~= nil, "call() scheduled a timeout timer")
T.eq(timer and timer.sec, 0.25, "the timeout timer uses timeout_ms")
if timer then timer.fn() end
T.eq(got5, nil, "the timeout still has no response")
T.eq(err5, "timeout", "the timeout fires the callback with reason timeout")
T.eq(node.udp.ports[40000], nil, "the ephemeral port is released on timeout")

-- a busy local port is skipped
local blocker = node:bind(RC.DEFAULT_LOCAL_PORT)
local got6 = nil
RC.call(node, rpv, { addr = SERVER_IP, path = "/" }, function(res) got6 = res end)
T.eq(got6 and got6.status, 200, "a busy first ephemeral port falls through to the next")
blocker:close()

local noaddr = RC.call(node, rpv, { path = "/" }, function() end)
T.eq(noaddr, nil, "call() without a destination fails")
local nocb = RC.call(node, rpv, { addr = SERVER_IP, path = "/" })
T.eq(nocb, nil, "call() without a callback fails")

-- ===== blocking harness transport ==========================================
local node2 = make_node()
local rpv2 = make_rpv()
RS.start_rhtp(node2, RS.DEFAULT_PORT, rpv2)
local clock_now = 0
local transport = RC.rpv_transport(node2, rpv2, {
    clock = function() return clock_now end,
    pump = function() clock_now = clock_now + 1 end,
})
local raw = transport("GET / RHTP/1.0\r\n\r\n", { addr = SERVER_IP, port = RS.DEFAULT_PORT })
T.ok(type(raw) == "string", "the blocking transport returns a raw datagram")
T.eq(RC.parse_response(raw).status, 200, "the blocking transport round trip answers 200")
T.eq(node2.udp.ports[40000], nil, "the blocking transport releases its port")

local dead_transport = RC.rpv_transport(node2, rpv2, {
    clock = function() return clock_now end,
    pump = function() clock_now = clock_now + 1000 end,
    timeout_ms = 100,
})
local raw2, terr2 = dead_transport("GET / RHTP/1.0\r\n\r\n", { addr = SERVER_IP, port = 9999 })
T.eq(raw2, nil, "an unanswered blocking request returns nil")
T.eq(terr2, "timeout", "an unanswered blocking request reports a timeout")

clean(DNS_DB)
clean(DIRECTORY)
