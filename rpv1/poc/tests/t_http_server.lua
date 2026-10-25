--[[- tests/t_http_server.lua - minimal GET routing and status codes (offline).]]
local T, M = ...

local S = M.http_server
local C = M.http_common
T.ok(S ~= nil and C ~= nil, "http_server and http_common modules loaded")
if not S or not C then return end

local function request(method, path, body, extra)
    local headers = { Host = "test" }
    for k, v in pairs(extra or {}) do headers[k] = v end
    return C.build_request(method, path, headers, body)
end

local function call(server, method, path, body, extra)
    local response = server:handle(request(method, path, body, extra))
    local parsed = C.parse_response(response)
    T.ok(parsed ~= nil, "response parses for " .. method .. " " .. path)
    return parsed, response
end

local hits = 0
local routes = {
    ["/static"] = "hello static",
    ["/fn"] = function(req)
        hits = hits + 1
        return { status = 200, body = "fn " .. req.method, headers = { ["X-Test"] = "1" } }
    end,
    ["/crash"] = function() error("boom") end,
    ["/bad"] = function() return { status = 999, body = "x" } end,
    ["/forbidden"] = function() return { status = 403, body = "no" } end,
    ["/created"] = function() return { status = 201, body = "new" } end,
}

local srv = S.start(8080, routes, { log = function() end })
T.ok(srv ~= nil, "server starts")
if not srv then return end

local resp = call(srv, "GET", "/static")
T.eq(resp.status, 200, "static route answers 200")
T.eq(resp.body, "hello static", "static route body")

resp = call(srv, "GET", "/fn")
T.eq(resp.status, 200, "function route answers 200")
T.eq(resp.body, "fn GET", "function route sees the method")
T.eq(resp.headers["x-test"], "1", "handler headers are forwarded")

resp = call(srv, "HEAD", "/static")
T.eq(resp.status, 405, "HEAD is not served")
T.eq(C.header(resp.headers, "allow"), "GET", "HEAD 405 Allow is GET")
T.eq(resp.body, "Method Not Allowed", "HEAD 405 body")

resp = call(srv, "HEAD", "/fn")
T.eq(resp.status, 405, "HEAD function route is not served")
T.eq(hits, 1, "rejected HEAD does not invoke the handler")

resp = call(srv, "POST", "/fn")
T.eq(resp.status, 405, "POST is not served")
T.eq(C.header(resp.headers, "allow"), "GET", "405 Allow is GET")
T.eq(hits, 1, "a rejected method does not invoke the handler")

resp = call(srv, "PUT", "/static")
T.eq(resp.status, 405, "PUT static is not served")
T.eq(C.header(resp.headers, "allow"), "GET", "static 405 Allow")

resp = call(srv, "POST", "/missing")
T.eq(resp.status, 404, "unknown path wins over method handling")

resp = call(srv, "GET", "/missing")
T.eq(resp.status, 404, "unknown path answers 404")
T.eq(resp.body, "Not Found", "404 body")

resp = call(srv, "GET", "/crash")
T.eq(resp.status, 500, "throwing handler answers 500")
resp = call(srv, "GET", "/static")
T.eq(resp.status, 200, "server still works after a handler crash")

resp = call(srv, "GET", "/bad")
T.eq(resp.status, 500, "invalid handler status answers 500")

resp = call(srv, "GET", "/forbidden")
T.eq(resp.status, 403, "handler can answer 403 explicitly")

resp = call(srv, "GET", "/created")
T.eq(resp.status, 201, "handler-defined 201 is preserved")

-- ===== parser limits become HTTP status codes =============================
resp = call(srv, "GET", "/../etc/passwd")
T.eq(resp.status, 403, "traversal answers 403")

local non_ascii = "GET /caf" .. string.char(233) .. " HTTP/1.1\r\nHost: test\r\n\r\n"
local parsed = C.parse_response(srv:handle(non_ascii))
T.eq(parsed.status, 403, "non-ASCII target answers 403")

resp = call(srv, "GET", "/" .. string.rep("a", C.MAX_PATH + 8))
T.eq(resp.status, 414, "over-long target answers 414")

local big_header = "GET /static HTTP/1.1\r\nHost: test\r\nX-Pad: "
    .. string.rep("a", C.MAX_HEADER_BYTES) .. "\r\n\r\n"
parsed = C.parse_response(srv:handle(big_header))
T.eq(parsed.status, 431, "oversized header block answers 431")

local big_body = "POST /fn HTTP/1.1\r\nHost: test\r\nContent-Length: "
    .. tostring(C.MAX_BODY_BYTES + 1) .. "\r\n\r\n"
parsed = C.parse_response(srv:handle(big_body))
T.eq(parsed.status, 413, "oversized body answers 413")

parsed = C.parse_response(srv:handle("not a request\r\n\r\n"))
T.eq(parsed.status, 400, "malformed request answers 400")

parsed = C.parse_response(srv:handle(12345))
T.eq(parsed.status, 400, "non-string request answers 400")

-- ===== stats ==============================================================
local stats = srv:get_stats()
T.ok(stats.requests > 10, "request counter increments")
T.ok(stats.errors >= 2, "handler errors are counted")
T.ok((stats.by_status[500] or 0) >= 2, "500 responses are counted")
T.ok((stats.by_status[405] or 0) >= 2, "405 responses are counted")

-- ===== transport adapter / stop ==========================================
local bound_port, on_data, closed
local srv2 = S.start(9090, { ["/t"] = "ok" }, {
    transport = function(port, cb)
        bound_port, on_data = port, cb
        return { close = function() closed = true end }
    end,
})
T.ok(srv2 ~= nil, "transport-backed server starts")
T.eq(bound_port, 9090, "transport receives the port")
local reply
local returned = on_data(request("GET", "/t"), function(r) reply = r end, "src-1")
T.ok(type(returned) == "string", "transport callback returns the response")
T.ok(type(reply) == "string" and reply:find("HTTP/1.1 200 OK", 1, true) == 1, "transport reply is a response")
srv2:stop()
T.ok(closed == true, "stop closes the transport listener")

-- a secure instance that cannot seal must not leak plaintext
local broken_secure = {
    enabled = true,
    open_request = function() return nil, "no" end,
    seal_response = function() return nil, "seal failed" end,
}
local srv3 = S.start(9091, { ["/x"] = "x" }, { secure = broken_secure, strict = false })
local broken_response = srv3:handle(request("GET", "/x"))
T.eq(broken_response, "", "secure seal failure fails closed")
srv3:stop()

srv:stop()
T.ok(srv.stopped == true, "server is marked stopped")

parsed = C.parse_response(S.handle(request("GET", "/static")))
T.eq(parsed.status, 500, "module handle without a server answers 500")
