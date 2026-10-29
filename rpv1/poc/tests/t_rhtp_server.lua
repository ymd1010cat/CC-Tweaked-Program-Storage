--[[- tests/t_rhtp_server.lua - apps/rhtp_server.lua: the RHTP/1.0 GET routes,
the mirror files and their fallbacks, the 500 path and the rpv.udp_send reply
contract. Everything is offline: a node stub captures node:bind, so no socket
and no modem are ever opened.
]]
local T, M = ...

local RH = M.rhtp_server
T.ok(RH ~= nil, "rhtp_server module is loaded")
if not RH then return end

local DNS_DB = RH.DNS_DB
local DIRECTORY = RH.DIRECTORY
local WELCOME = "RHTP/1.0 200 OK\r\n\r\nWelcome to InterTeamNet"
local NOT_FOUND = "RHTP/1.0 404 Not Found\r\n\r\nPage Not Found"
local DNS_NOT_FOUND = "RHTP/1.0 404 Not Found\r\n\r\nDNS DB Not Found"
local SERVER_ERROR = "RHTP/1.0 500 Internal Server Error\r\n\r\nServer Error"

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

-- a node stub: node:bind only records the handler, there is no transport
local function make_node()
    local node = { binds = {}, logs = {} }
    function node:bind(port, handler)
        local sock = { port = port, handler = handler, sent = {} }
        function sock.sendto(self, src, sport, body)
            self.sent[#self.sent + 1] = { src = src, sport = sport, body = body }
            return true
        end
        node.binds[#node.binds + 1] = sock
        node.sock = sock
        return sock
    end
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    return node
end

local function logged(node, tag)
    for _, line in ipairs(node.logs) do
        if tostring(line):find(tag, 1, true) then return true end
    end
    return false
end

local function make_rpv()
    local rpv = { sent = {} }
    function rpv.udp_send(node, src, dport, sport, body)
        rpv.sent[#rpv.sent + 1] = {
            node = node, src = src, dport = dport, sport = sport, body = body,
        }
        return true
    end
    rpv.sha256 = M.sha256
    return rpv
end

-- a private module instance. The transport is resolved per start_rhtp call and
-- kept in that instance, so a fresh chunk keeps the explicit-library and the
-- fallback cases independent (and one chunk can now hold two transports, which
-- the "two servers, two transports" case exercises).
local function fresh()
    local chunk = assert(loadfile("apps/rhtp_server.lua"))
    return chunk(false)
end

-- ===== module surface =======================================================
T.eq(RH.VERSION, "1.0", "the version is 1.0")
T.eq(RH.DEFAULT_PORT, 8080, "the default port is 8080")
T.eq(RH.DNS_DB, "dns_db.txt", "the DNS mirror file has a fixed name")
T.eq(RH.DIRECTORY, "ip_directory.txt", "the directory file has a fixed name")
T.eq(RH.FALLBACK_DIRECTORY, "root.server 172.16.1.2", "the fallback directory is built in")

local sha = M.sha256
T.ok(sha ~= nil, "rpv.sha256 is available to the harness")
if not sha then return end

-- ===== routing ==============================================================
clean(DNS_DB)
clean(DIRECTORY)

T.eq(RH.handle_request("GET /"), WELCOME, "GET / serves the welcome page")
T.eq(RH.handle_request("GET /?probe=1"), WELCOME, "the query string is stripped")
T.eq(RH.handle_request("GET /#top"), WELCOME, "the fragment is stripped")
T.eq(RH.handle_request("GET /\r\nHost: x\r\n"), WELCOME, "only the request line matters")
T.eq(RH.handle_request("  GET /  "), WELCOME, "surrounding whitespace is tolerated")
T.eq(RH.handle_request("GET /nope"), NOT_FOUND, "an unknown path is a 404")
T.eq(RH.handle_request(""), NOT_FOUND, "an empty datagram is a 404")
T.eq(RH.handle_request(nil), NOT_FOUND, "a nil datagram is a 404")
T.eq(RH.handle_request("POST / HTTP/1.0"), NOT_FOUND, "a non-GET method is a 404")
T.eq(RH.handle_request("post /"), NOT_FOUND, "lowercase methods are not accepted")
T.eq(RH.handle_request("PING"), NOT_FOUND, "a request without a path is a 404")
T.eq(RH.handle_request("GET /api/directory/"), NOT_FOUND, "routes are exact")

-- ===== the two mirror files =================================================
T.eq(RH.handle_request("GET /api/dns_mirror"), DNS_NOT_FOUND,
    "the missing DNS mirror is a 404")
T.eq(RH.handle_request("GET /api/directory"),
    "RHTP/1.0 200 OK\r\n\r\nroot.server 172.16.1.2",
    "the missing directory falls back to root.server")

local DNS_TEXT = "alpha.example 10.200.0.10\nbeta.example 10.200.0.11\n"
T.ok(write(DNS_DB, DNS_TEXT), "the DNS mirror fixture is written")
local PREFIX = "RHTP/1.0 200 OK\r\nX-DNS-Hash: "
local HEX_LEN = 64
local function header_block(text)
    local at = text:find("\r\n\r\n", 1, true)
    if not at then return text end
    return text:sub(1, at - 1)
end
local function bare_crlf(text)
    return (text:gsub("\r\n", "")):find("[\r\n]")
end
local resp = RH.handle_request("GET /api/dns_mirror")
-- the header value is what sits between the status line and the blank line: a
-- raw digest byte cannot be parsed on that line, a hex value can
local function header_value(text)
    return text:match("\r\nX%-DNS%-Hash: ([^\r\n]*)\r\n")
end
local function hex_digest(text)
    if type(text) ~= "string" then return nil end
    local ok, out = pcall(M.unhex, text)
    if ok then return out end
    return nil
end
T.eq(resp:sub(1, #PREFIX), PREFIX, "the DNS mirror carries an X-DNS-Hash header")
T.eq(#sha(DNS_TEXT), 32, "the SHA-256 digest is 32 raw bytes")
local value = header_value(resp)
T.ok(value ~= nil, "the X-DNS-Hash value sits on a single CRLF-terminated line")
T.eq(value and #value, HEX_LEN, "the header value is 64 characters, not the 32 raw bytes")
T.ok(value ~= nil and value:match("^[0-9a-f]+$") ~= nil, "the header value is lowercase hex")
T.eq(value, M.hex(sha(DNS_TEXT)), "the header value is the digest as lowercase hex")
T.eq(hex_digest(value), sha(DNS_TEXT), "the hex header decodes to the raw digest")
T.eq(resp:sub(#PREFIX + HEX_LEN + 1), "\r\n\r\n" .. DNS_TEXT, "the file body follows the header")
T.eq(bare_crlf(header_block(resp)), nil, "the header block has no bare CR or LF")

-- a body whose digest really contains a CR or LF byte. The search is
-- deterministic ("hostile-body-N" has a fixed digest), so the fixture is stable;
-- before the hex encoding the value was the raw digest and cut the header block
-- in two at that byte.
local hostile = nil
for i = 1, 1000 do
    local candidate = "hostile-body-" .. i .. "\n"
    if sha(candidate):find("[\r\n]") then
        hostile = candidate
        break
    end
end
T.ok(hostile ~= nil, "a SHA-256 digest with a CR or LF byte is reproducible")
T.ok(write(DNS_DB, hostile or DNS_TEXT), "the hostile mirror fixture is written")
local hresp = RH.handle_request("GET /api/dns_mirror")
local hvalue = header_value(hresp)
T.ok(hvalue ~= nil, "a digest with CR/LF still leaves one well formed hash line")
T.eq(hvalue and #hvalue, HEX_LEN, "a digest with CR/LF still yields 64 hex characters")
T.eq(hvalue, M.hex(sha(hostile or DNS_TEXT)), "the hostile header is still the hex digest")
T.eq(hex_digest(hvalue), sha(hostile or DNS_TEXT), "the hostile hex header decodes to the digest")
T.eq(bare_crlf(header_block(hresp)), nil,
    "a digest with CR/LF never leaks a bare CR or LF into the header block")
T.eq((header_block(hresp):gsub("\r\n", "")),
    "RHTP/1.0 200 OKX-DNS-Hash: " .. tostring(hvalue),
    "the hostile reply is exactly the status line plus the hash line")
T.eq(hresp:sub(#PREFIX + HEX_LEN + 1), "\r\n\r\n" .. (hostile or DNS_TEXT),
    "the hostile body still follows the header")
T.ok(write(DNS_DB, DNS_TEXT), "the plain mirror fixture is restored")

local queried = RH.handle_request("GET /api/dns_mirror?raw=1")
T.eq(queried:sub(1, #PREFIX + HEX_LEN), resp:sub(1, #PREFIX + HEX_LEN),
    "a query string does not change the mirror reply")

local DIR_TEXT = "root.server 10.9.9.9\n"
T.ok(write(DIRECTORY, DIR_TEXT), "the directory fixture is written")
T.eq(RH.handle_request("GET /api/directory"),
    "RHTP/1.0 200 OK\r\n\r\n" .. DIR_TEXT, "the directory file is served")
T.eq(RH.handle_request("GET /api/directory?fresh=1"),
    "RHTP/1.0 200 OK\r\n\r\n" .. DIR_TEXT, "the directory query is stripped")

-- ===== an internal error becomes a 500 ======================================
local function with_broken_exists(fn)
    local saved = fs.exists
    fs.exists = function() error("t_rhtp boom") end
    local ok, ret = pcall(fn)
    fs.exists = saved
    return ok, ret
end

local logged_error = nil
local ok500, resp500 = with_broken_exists(function()
    return RH.handle_request("GET /api/dns_mirror", function(fmt, ...)
        logged_error = string.format(fmt, ...)
    end)
end)
T.ok(ok500, "an internal error does not escape handle_request")
T.eq(resp500, SERVER_ERROR, "an internal error answers 500")
T.ok(logged_error ~= nil and logged_error:find("RHTP_ERROR", 1, true) ~= nil,
    "the 500 is logged through the log callback")
T.eq(fs.exists(DNS_DB), true, "the fs API is restored")

-- ===== the rpv.udp_send reply path =========================================
local S = fresh()
local node = make_node()
local rpv = make_rpv()
local sk = S.start_rhtp(node, 8080, rpv)
T.ok(sk ~= nil, "start_rhtp returns the socket")
T.eq(sk, node.sock, "the returned socket is the one node:bind created")
T.eq(node.sock.port, 8080, "the socket listens on 8080")
T.ok(logged(node, "RHTP_START port=8080 lib=true"), "the start line reports the library")
T.eq(#rpv.sent, 0, "nothing is sent at start")

node.sock.handler("GET /", 1001, 2002)
T.eq(#rpv.sent, 1, "one request gets one reply")
local first = rpv.sent[1]
T.eq(first.node, node, "udp_send arg 1 is the node")
T.eq(first.src, 1001, "udp_send arg 2 is the requester address")
T.eq(first.dport, 8080, "udp_send arg 3 is the listening port")
T.eq(first.sport, 2002, "udp_send arg 4 is the requester source port")
T.eq(first.body, WELCOME, "udp_send arg 5 is the response")
T.ok(logged(node, "RHTP_REQ sport=2002"), "the request line is logged")

node.sock.handler("GET /missing", 1003, 2004)
T.eq(#rpv.sent, 2, "a 404 is still sent back")
T.eq(rpv.sent[2].body, NOT_FOUND, "the 404 body reaches the wire")

local S2 = fresh()
local node2 = make_node()
local rpv2 = make_rpv()
S2.start_rhtp(node2, "9100", rpv2)
T.eq(node2.sock.port, 9100, "a string port is converted")
node2.sock.handler("GET /", 5, 6)
T.eq(rpv2.sent[1].dport, 9100, "the reply leaves from the custom port")

local S3 = fresh()
local node3 = make_node()
local rpv3 = { sent = {} }
rpv3.sha256 = sha
function rpv3.udp_send() error("t_rhtp send boom") end
S3.start_rhtp(node3, 8080, rpv3)
node3.sock.handler("GET /", 1, 2)
T.ok(logged(node3, "RHTP_SEND_FAIL"), "a failing udp_send is logged")
T.ok(logged(node3, "RHTP_REQ sport=2"), "the handler keeps running after a send failure")

-- ===== two servers, two transports (F2) ====================================
-- the rpv table is an argument of start_rhtp and belongs to that instance: a
-- second server started from the same module table must not inherit the first
-- one's transport (a file-level cache would route both replies through rpvA)
local TWO = fresh()
local nodeA, nodeB = make_node(), make_node()
local rpvA, rpvB = make_rpv(), make_rpv()
local skA = TWO.start_rhtp(nodeA, 8080, rpvA)
local skB = TWO.start_rhtp(nodeB, 8090, rpvB)
T.ok(skA ~= nil and skB ~= nil, "two servers start from one module table")
T.eq(nodeA.sock.port, 8080, "the first server listens on 8080")
T.eq(nodeB.sock.port, 8090, "the second server listens on 8090")
nodeA.sock.handler("GET /", 71, 72)
nodeB.sock.handler("GET /", 81, 82)
T.eq(#rpvA.sent, 1, "the first server answers through its own transport")
T.eq(#rpvB.sent, 1, "the second server answers through its own transport")
T.eq(rpvA.sent[1].dport, 8080, "the first reply leaves from 8080")
T.eq(rpvB.sent[1].dport, 8090, "the second reply leaves from 8090")
T.eq(rpvB.sent[1].src, 81, "the second reply goes to its requester")
T.eq(rpvB.sent[1].sport, 82, "the second reply reuses the requester source port")
T.ok(logged(nodeB, "RHTP_START port=8090 lib=true"), "the second start line reports its library")
-- the instance hash is used too (rpvB has sha256 but no hex: inline encoder)
nodeB.sock.handler("GET /api/dns_mirror", 83, 84)
T.eq(#rpvB.sent, 2, "the mirror reply also leaves through the second transport")
local mvalue = header_value(rpvB.sent[2].body)
T.eq(mvalue and #mvalue, HEX_LEN, "the per-instance hash yields 64 hex characters")
T.eq(mvalue, M.hex(sha(DNS_TEXT)), "the per-instance hash matches the body digest")

-- ===== the socket sendto fallback ===========================================
local saved_global = rawget(_G, "rpv")
local saved_loaded = package and package.loaded and package.loaded.rpv
_G.rpv = nil
if package and package.loaded then package.loaded.rpv = nil end
local S4 = fresh()
local node4 = make_node()
local sk4 = S4.start_rhtp(node4, 8081)
T.ok(sk4 ~= nil, "start_rhtp works without an rpv table")
T.ok(logged(node4, "RHTP_START port=8081 lib=false"), "the start line reports the fallback")
node4.sock.handler("GET /", 11, 12)
T.eq(#node4.sock.sent, 1, "the socket sendto fallback is used")
T.eq(node4.sock.sent[1].src, 11, "sendto gets the requester address")
T.eq(node4.sock.sent[1].sport, 12, "sendto gets the requester source port")
T.eq(node4.sock.sent[1].body, WELCOME, "sendto gets the response")
_G.rpv = saved_global
if package and package.loaded then package.loaded.rpv = saved_loaded end

-- ===== the node2 app form ===================================================
local S5 = fresh()
local app = S5.new{ node = make_node(), rpv = make_rpv(), args = "9200" }
T.ok(app ~= nil, "new() returns an app table")
T.eq(app.port, 9200, "args sets the port")
T.eq(app.sock, nil, "nothing is bound before start()")
T.eq(app.start(), true, "start() reports success")
T.eq(app.sock.port, 9200, "start() binds the requested port")
local app2 = S5.new{ node = make_node(), rpv = make_rpv() }
T.eq(app2.port, 8080, "the default port is used without args")

clean(DNS_DB)
clean(DIRECTORY)
