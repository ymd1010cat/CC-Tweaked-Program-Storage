--[[- tests/t_http_integration.lua - minimal server + client end to end (offline).]]
local T, M = ...

local C = M.http_common
local S = M.http_server
local CL = M.http_client
local HS = M.http_secure
local crypto = M
T.ok(C ~= nil and S ~= nil and CL ~= nil and HS ~= nil and type(crypto.hkdf_sha256) == "function",
    "all HTTP modules loaded")
if not C or not S or not CL or not HS then return end

-- ===== plaintext server + client =========================================
local seen_paths = {}
local srv = S.start(8080, {
    ["/hello"] = function(req)
        seen_paths[#seen_paths + 1] = req.path
        return "hello"
    end,
    ["/created"] = function() return { status = 201, body = "new" } end,
    ["/boom"] = function() error("integration boom") end,
}, { log = function() end })
T.ok(srv ~= nil, "plaintext server starts")
if not srv then return end

local function plain_transport(req) return srv:handle(req) end

local r = CL.get({ url = "http://box:8080/hello", transport = plain_transport, retries = 0 })
T.ok(r.ok, "plaintext GET succeeds")
T.eq(r.status, 200, "plaintext GET status")
T.eq(r.body, "hello", "plaintext GET body")
T.eq(seen_paths[1], "/hello", "server route received the path")

r = CL.get({ url = "http://box:8080/created", transport = plain_transport, retries = 0 })
T.eq(r.status, 201, "201 round trip")

r = CL.get({ url = "http://box:8080/nowhere", transport = plain_transport, retries = 0 })
T.eq(r.status, 404, "404 round trip")
T.ok(r.ok, "404 is still a successful HTTP transaction")

r = CL.get({ url = "http://box:8080/boom", transport = plain_transport, retries = 0 })
T.eq(r.status, 500, "handler crash round trip")

r = CL.request("HEAD", { url = "http://box:8080/hello", transport = plain_transport, retries = 0 })
T.eq(r.status, 405, "HEAD is rejected end to end")
T.eq(C.header(r.headers, "allow"), "GET", "HEAD 405 Allow")
T.eq(r.body, "", "HEAD rejection has no body on the client side")

r = CL.post({ url = "http://box:8080/hello", body = "x", transport = plain_transport, retries = 0 })
T.eq(r.status, 405, "POST is rejected end to end")
T.eq(C.header(r.headers, "allow"), "GET", "POST 405 Allow")

local parsed = C.parse_response(srv:handle("GET /../secret HTTP/1.1\r\nHost: box\r\n\r\n"))
T.eq(parsed.status, 403, "traversal round trip is 403")

-- retry through a flaky transport
local flaky_calls = 0
local flaky = function(req)
    flaky_calls = flaky_calls + 1
    if flaky_calls == 1 then return nil, "timeout" end
    return srv:handle(req)
end
r = CL.get({
    url = "http://box:8080/hello",
    transport = flaky,
    retries = 1,
    sleep = function() end,
})
T.ok(r.ok, "retry through the real server succeeds")
T.eq(flaky_calls, 2, "one retry was made")
T.eq(r.body, "hello", "retried body")

-- ===== PSK-secured server + client ========================================
local PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
local sec_client, ccerr = HS.new({ psk = PSK, crypto = crypto, salt = "integration", role = "client" })
local sec_server, cserr = HS.new({ psk = PSK, crypto = crypto, salt = "integration", role = "server" })
T.ok(sec_client ~= nil and sec_server ~= nil, "secure client/server created")
T.eq(ccerr, nil, "secure client constructor")
T.eq(cserr, nil, "secure server constructor")

local secure_srv = S.start(8081, {
    ["/secret"] = function(req) return "secret:" .. req.path end,
}, { secure = sec_server, strict = true, log = function() end })
T.ok(secure_srv ~= nil, "secure server starts")
if not secure_srv then return end

local wire_request, wire_response
local secure_transport = function(req)
    wire_request = req
    local response = secure_srv:handle(req)
    wire_response = response
    return response
end

r = CL.get({
    url = "http://box:8081/secret",
    transport = secure_transport,
    secure = sec_client,
    retries = 0,
})
T.ok(r.ok, "secure GET succeeds")
T.eq(r.status, 200, "secure GET status")
T.eq(r.body, "secret:/secret", "secure GET body")
T.eq(wire_request:sub(1, 1), "H", "request on the wire is an envelope")
T.eq(wire_response:sub(1, 1), "H", "response on the wire is an envelope")
T.ok(not wire_request:find("GET /secret", 1, true), "request plaintext is not on the wire")
T.ok(not wire_response:find("secret:", 1, true), "response plaintext is not on the wire")

r = CL.post({
    url = "http://box:8081/secret",
    body = "x",
    transport = secure_transport,
    secure = sec_client,
    retries = 0,
})
T.ok(r.ok, "secure 405 response is readable")
T.eq(r.status, 405, "secure POST is rejected")

-- a replayed request is refused and the 403 itself is sealed and readable
local env = sec_client:seal_request(C.build_request("GET", "/secret", { Host = "box" }))
local first = secure_srv:handle(env)
local opened = sec_client:open_response(first)
T.ok(opened ~= nil, "server seals the accepted replay-test response")
parsed = C.parse_response(opened)
T.eq(parsed.status, 200, "first envelope is accepted")

local second = secure_srv:handle(env)
local opened_second = sec_client:open_response(second)
T.ok(opened_second ~= nil, "server seals the rejection response")
parsed = C.parse_response(opened_second)
T.eq(parsed.status, 403, "replayed envelope is refused with 403")
T.ok(parsed.body:find("replayed", 1, true) ~= nil, "replay reason is reported")

-- plaintext against a strict secure server is refused, and the refusal is sealed
local plain = C.build_request("GET", "/secret", { Host = "box" })
local refusal = secure_srv:handle(plain)
T.eq(refusal:sub(1, 1), "H", "plaintext refusal is sealed")
local opened_refusal = sec_client:open_response(refusal)
T.ok(opened_refusal ~= nil, "secure client can read the refusal")
parsed = C.parse_response(opened_refusal)
T.eq(parsed.status, 403, "plaintext request to a strict server answers 403")
T.ok(parsed.body:find("envelope", 1, true) ~= nil, "strict mode asks for an envelope")

-- a tampered envelope is also refused
local tamper_env = sec_client:seal_request(C.build_request("GET", "/secret", { Host = "box" }))
local tampered = tamper_env:sub(1, #tamper_env - 1)
    .. string.char((tamper_env:byte(#tamper_env) + 1) % 256)
local tamper_resp = secure_srv:handle(tampered)
local opened_tamper = sec_client:open_response(tamper_resp)
T.ok(opened_tamper ~= nil, "tampered request gets a sealed refusal")
parsed = C.parse_response(opened_tamper)
T.eq(parsed.status, 403, "tampered envelope answers 403")

-- a client with the wrong PSK cannot read the refusal
local wrong_client = HS.new({ psk = string.rep("ab", 32), crypto = crypto, salt = "integration", role = "client" })
r = CL.get({
    url = "http://box:8081/secret",
    transport = secure_transport,
    secure = wrong_client,
    retries = 0,
})
T.ok(not r.ok, "wrong PSK client fails")
T.ok(tostring(r.err):find("secure", 1, true) ~= nil, "wrong PSK error explains the secure layer")

-- non-strict secure mode lets plaintext through (but still seals the response)
local loose_client = HS.new({ psk = PSK, crypto = crypto, salt = "loose", role = "client" })
local loose_server = HS.new({ psk = PSK, crypto = crypto, salt = "loose", role = "server", strict = false })
local loose_srv = S.start(8082, { ["/open"] = "open" }, { secure = loose_server, strict = false })
local loose_plain = C.build_request("GET", "/open", { Host = "box" })
local loose_resp = loose_srv:handle(loose_plain)
T.eq(loose_resp:sub(1, 1), "H", "non-strict response is still sealed")
local opened_loose = loose_client:open_response(loose_resp)
T.ok(opened_loose ~= nil, "non-strict client opens the response")
parsed = C.parse_response(opened_loose)
T.eq(parsed.status, 200, "plaintext passes through in non-strict mode")
T.eq(parsed.body, "open", "non-strict body")

srv:stop()
secure_srv:stop()
loose_srv:stop()
