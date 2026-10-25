--[[- tests/t_http_client.lua - get(), retries, backoff and URL parsing (offline).]]
local T, M = ...

local CL = M.http_client
local C = M.http_common
T.ok(CL ~= nil and C ~= nil, "http_client and http_common modules loaded")
if not CL or not C then return end

local function response(status, body)
    return C.build_response(status, nil, body, { server_name = false })
end

-- ===== success and unified result shape ===================================
local calls, seen_request, seen_meta = 0, nil, nil
local r = CL.get({
    url = "http://10.0.0.1:8080/x?y=1",
    retries = 0,
    transport = function(req, meta)
        calls = calls + 1
        seen_request, seen_meta = req, meta
        return response(200, "ok")
    end,
})
T.ok(r.ok, "successful get has ok=true")
T.eq(r.status, 200, "successful get status")
T.eq(r.body, "ok", "successful get body")
T.eq(r.err, nil, "successful get has no error")
T.eq(calls, 1, "one attempt without retries")
T.ok(seen_request:find("GET /x?y=1 HTTP/1.1\r\n", 1, true) == 1, "request line uses the URL target")
T.ok(seen_request:find("Host: 10.0.0.1\r\n", 1, true) ~= nil, "Host header omits the default port")
T.eq(seen_meta.timeout_ms, CL.DEFAULT_TIMEOUT_MS, "default timeout is passed to the transport")
T.eq(seen_meta.host, "10.0.0.1", "meta host")
T.eq(seen_meta.port, 8080, "meta port")

local explicit_host
r = CL.get({ url = "http://box:9000/h", retries = 0,
    transport = function(req) explicit_host = req return response(200, "h") end })
T.ok(explicit_host:find("Host: box:9000\r\n", 1, true) ~= nil, "Host header includes a non-default port")

-- 4xx is still a well-formed HTTP transaction
r = CL.get({ url = "http://h:8080/missing", retries = 0,
    transport = function() return response(404, "missing") end })
T.ok(r.ok, "404 is ok=true (HTTP transaction succeeded)")
T.eq(r.status, 404, "404 status is reported")
T.eq(r.body, "missing", "404 body is reported")

-- ===== retries and exponential backoff ====================================
local attempts = 0
local sleeps, delays = {}, {}
r = CL.get({
    url = "http://h:8080/flaky",
    retries = 1,
    backoff_ms = 50,
    transport = function()
        attempts = attempts + 1
        if attempts == 1 then return nil, "timeout" end
        return response(200, "second")
    end,
    sleep = function(s) sleeps[#sleeps + 1] = s end,
    on_backoff = function(_, d) delays[#delays + 1] = d end,
})
T.ok(r.ok, "retry succeeds on the second attempt")
T.eq(r.status, 200, "retried response status")
T.eq(attempts, 2, "exactly two attempts")
T.eq(delays[1], 50, "first backoff uses the configured base")
T.near(sleeps[1], 0.05, 0.0001, "sleep receives seconds")

attempts, sleeps, delays = 0, {}, {}
r = CL.get({
    url = "http://h:8080/dead",
    retries = 3,
    backoff_ms = 100,
    backoff_max_ms = 1000,
    transport = function() attempts = attempts + 1 return nil, "timeout" end,
    sleep = function(s) sleeps[#sleeps + 1] = s end,
    on_backoff = function(_, d) delays[#delays + 1] = d end,
})
T.ok(not r.ok, "all attempts failing gives ok=false")
T.eq(r.status, nil, "failed get has no status")
T.eq(r.err, "timeout", "failed get keeps the transport error")
T.eq(attempts, 4, "retries+1 attempts are made")
T.eq(delays[1], 100, "backoff 1 is the base")
T.eq(delays[2], 200, "backoff 2 doubles")
T.eq(delays[3], 400, "backoff 3 doubles again")

delays = {}
r = CL.get({
    url = "http://h:8080/cap",
    retries = 3,
    backoff_ms = 100,
    backoff_max_ms = 150,
    transport = function() return nil, "err" end,
    on_backoff = function(_, d) delays[#delays + 1] = d end,
    sleep = function() end,
})
T.eq(delays[3], 150, "backoff is capped")

-- ===== timeout and transport metadata =====================================
local captured
r = CL.get({
    url = "http://h:8080/t",
    timeout_ms = 1234,
    retries = 0,
    transport = function(_, meta) captured = meta return response(200, "t") end,
})
T.eq(captured.timeout_ms, 1234, "timeout_ms is forwarded")
T.eq(captured.method, "GET", "meta method")
T.ok(r.ok, "timeout get succeeds")

-- ===== URL / target parsing ===============================================
local u, uerr = CL.parse_url("http://box")
T.ok(u ~= nil, "host-only URL parses")
T.eq(u.port, 8080, "host-only URL uses the default port")
T.eq(u.path, "/", "host-only URL defaults to /")
T.eq(uerr, nil, "host-only URL has no error")

u = CL.parse_url("http://box:9000/a/b?c=1")
T.eq(u.port, 9000, "explicit port parsed")
T.eq(u.path, "/a/b?c=1", "path and query preserved")

u, uerr = CL.parse_url("https://box/")
T.eq(u, nil, "https URL rejected")
T.ok(uerr ~= nil, "https URL has an error")

u, uerr = CL.parse_url("http://box/../etc")
T.eq(u, nil, "traversal URL rejected")

u, uerr = CL.parse_url("http://bo" .. string.char(233) .. "x/")
T.eq(u, nil, "non-ASCII URL rejected")

u, uerr = CL.parse_url("http://box:0/")
T.eq(u, nil, "zero port rejected")

u = CL.parse_url("http://box/a%20b")
T.eq(u.path, "/a%20b", "URL target is not re-encoded")

-- host/port/path form and encoded path preservation
local path_seen, method_seen, body_seen
r = CL.post({
    host = "box",
    port = 9000,
    path = "/a%20b?q=1",
    body = "hello",
    retries = 0,
    transport = function(req, meta)
        path_seen, method_seen = meta.path, meta.method
        body_seen = req
        return response(201, "made")
    end,
})
T.eq(r.status, 201, "POST status")
T.eq(method_seen, "POST", "POST method is forwarded")
T.eq(path_seen, "/a%20b?q=1", "encoded path is preserved")
T.ok(body_seen:find("Content-Length: 5\r\n", 1, true) ~= nil, "POST content-length")
T.ok(body_seen:sub(-5) == "hello", "POST body is sent")

-- ===== framing / secure / transport failures ==============================
attempts = 0
r = CL.get({
    url = "http://h:8080/bad",
    retries = 1,
    transport = function() attempts = attempts + 1 return "garbage" end,
    sleep = function() end,
})
T.ok(not r.ok, "malformed response gives ok=false")
T.ok(r.err:find("bad response", 1, true) ~= nil, "malformed response records the parse error")
T.eq(attempts, 2, "malformed responses are retried")

r = CL.get({ url = "http://h:8080/none", retries = 0 })
T.ok(not r.ok, "missing transport gives ok=false")
T.eq(r.err, "no transport", "missing transport error")

-- HEAD parses a content-length without requiring a body
local head_response = C.build_response(200, nil, "hello", { head = true, server_name = false })
r = CL.request("HEAD", { url = "http://h:8080/h", retries = 0,
    transport = function() return head_response end })
T.ok(r.ok, "HEAD succeeds")
T.eq(r.body, "", "HEAD has no body")
T.eq(r.headers["content-length"], "5", "HEAD keeps content-length")
