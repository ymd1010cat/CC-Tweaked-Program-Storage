--[[- tests/t_http_common.lua - framing, path normalisation and limits (offline).]]
local T, M = ...

local C = M.http_common
T.ok(C ~= nil, "http_common module loaded")
if not C then return end

T.eq(C.DEFAULT_PORT, 8080, "default HTTP port is 8080")

-- ===== ASCII / token checks ================================================
T.ok(C.is_ascii("GET /a HTTP/1.1"), "plain header block is ASCII")
T.ok(not C.is_ascii("GET /caf" .. string.char(233) .. " HTTP/1.1"), "non-ASCII byte is detected")
T.ok(C.is_ascii(""), "empty string is ASCII")
T.ok(C.is_token("Content-Length"), "header name is a token")
T.ok(not C.is_token("Bad Name"), "space is not allowed in a token")
T.ok(not C.is_token("Bad:Name"), "colon is not allowed in a token")
T.ok(not C.is_token(""), "empty token rejected")
T.ok(C.is_printable_ascii("/a/b.txt"), "printable path accepted")
T.ok(not C.is_printable_ascii("/a\tb"), "tab is not a printable path byte")

-- ===== path normalisation ==================================================
local p, q = C.normalize_path("/a/./b//c?x=1&y=2")
T.eq(p, "/a/b/c", "path is collapsed and dot segments dropped")
T.eq(q, "x=1&y=2", "query string is split from the path")

p, q = C.normalize_path("/")
T.eq(p, "/", "root stays root")
T.eq(q, "", "root has an empty query")

p, q = C.normalize_path("/a%20b")
T.eq(p, "/a b", "percent escapes are decoded")

local err, st
p, err, st = C.normalize_path("/a/../etc/passwd")
T.eq(p, nil, "traversal returns nil")
T.eq(st, 403, "traversal answers 403")
T.ok(err ~= nil, "traversal has an error message")

p, err, st = C.normalize_path("/caf" .. string.char(233))
T.eq(p, nil, "non-ASCII target rejected")
T.eq(st, 403, "non-ASCII target answers 403")

p, err, st = C.normalize_path("/a\\b")
T.eq(p, nil, "backslash target rejected")
T.eq(st, 403, "backslash target answers 403")

p, err, st = C.normalize_path("/" .. string.rep("a", C.MAX_PATH))
T.eq(p, nil, "over-long target rejected")
T.eq(st, 414, "over-long target answers 414")

p, err, st = C.normalize_path("relative/path")
T.eq(p, nil, "origin-form must start with a slash")
T.eq(st, 400, "relative target answers 400")

p, err, st = C.normalize_path("/a%2fb")
T.eq(p, nil, "encoded separator rejected")
T.eq(st, 403, "encoded separator answers 403")

local query = C.parse_query("x=1&y=2&flag")
T.eq(query.x, "1", "query field x")
T.eq(query.y, "2", "query field y")
T.eq(query.flag, "", "query field without a value is empty")
query = C.parse_query("n=a+b%20c")
T.eq(query.n, "a b c", "plus and percent escapes decode in query strings")

-- ===== request parsing =====================================================
local raw = "GET /hello?x=1 HTTP/1.1\r\nHost: box\r\n\r\n"
local req, perr = C.parse_request(raw)
T.ok(req ~= nil, "simple GET parses")
T.eq(req.method, "GET", "method")
T.eq(req.path, "/hello", "request path")
T.eq(req.query.x, "1", "request query")
T.eq(req.headers.host, "box", "headers are lower-cased")
T.eq(req.version, "HTTP/1.1", "version")
T.eq(req.body, "", "GET has an empty body")
T.eq(req.keep_alive, true, "HTTP/1.1 defaults to keep-alive")

local post = "POST /echo HTTP/1.1\r\nHost: box\r\nContent-Length: 5\r\n\r\nhello"
req = C.parse_request(post)
T.ok(req ~= nil, "POST with a body parses")
T.eq(req.body, "hello", "body matches content-length")
T.eq(req.content_length, 5, "content-length recorded")

req, perr, st = C.parse_request("BROKEN\r\n\r\n")
T.eq(req, nil, "malformed request line rejected")
T.eq(st, 400, "malformed request line answers 400")
T.ok(perr ~= nil, "malformed request has an error")

req, perr, st = C.parse_request("GET / HTTP/1.1\r\nContent-Length: nope\r\n\r\n")
T.eq(req, nil, "bad content-length rejected")
T.eq(st, 400, "bad content-length answers 400")

req, perr, st = C.parse_request("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n")
T.eq(req, nil, "oversized declared body rejected")
T.eq(st, 413, "oversized body answers 413")

req, perr, st = C.parse_request("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
T.eq(req, nil, "transfer-encoding rejected")
T.eq(st, 400, "transfer-encoding answers 400")

req, perr, st = C.parse_request("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhi")
T.eq(req, nil, "truncated body rejected")
T.eq(st, 400, "truncated body answers 400")

req, perr, st = C.parse_request("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nhello")
T.eq(req, nil, "trailing bytes rejected")
T.eq(st, 400, "trailing bytes answer 400")

local big_head = "GET / HTTP/1.1\r\nX-Pad: " .. string.rep("a", C.MAX_HEADER_BYTES) .. "\r\n\r\n"
req, perr, st = C.parse_request(big_head)
T.eq(req, nil, "oversized header block rejected")
T.eq(st, 431, "oversized header block answers 431")

local long_target = "GET /" .. string.rep("a", C.MAX_PATH + 8) .. " HTTP/1.1\r\n\r\n"
req, perr, st = C.parse_request(long_target)
T.eq(req, nil, "over-long target rejected")
T.eq(st, 414, "over-long target answers 414")

req, perr, st = C.parse_request("GET /../secret HTTP/1.1\r\n\r\n")
T.eq(req, nil, "traversal request rejected")
T.eq(st, 403, "traversal request answers 403")

req, perr, st = C.parse_request("GET / HTTP/1.1\r\nHost: box\r\n X-Fold: yes\r\n\r\n")
T.eq(req, nil, "folded header rejected")
T.eq(st, 400, "folded header answers 400")

req, perr, st = C.parse_request("GET / HTTP/2.0\r\n\r\n")
T.eq(req, nil, "unsupported version rejected")
T.eq(st, 505, "unsupported version answers 505")

-- bare LF framing is accepted on input
req = C.parse_request("GET /lf HTTP/1.0\nHost: box\n\n")
T.ok(req ~= nil, "bare LF request parses")
T.eq(req.path, "/lf", "bare LF path")
T.eq(req.keep_alive, false, "HTTP/1.0 defaults to close")

-- ===== response building / parsing ========================================
local resp = C.build_response(200, { ["Content-Type"] = "text/plain" }, "hello", { server_name = false })
T.ok(resp:find("HTTP/1.1 200 OK\r\n", 1, true) == 1, "status line is built")
T.ok(resp:find("Content-Length: 5\r\n", 1, true) ~= nil, "content-length is added")
T.ok(resp:find("Connection: close\r\n", 1, true) ~= nil, "connection close is added")
T.ok(resp:find("\r\n\r\nhello", 1, true) ~= nil, "body follows the header terminator")

local parsed = C.parse_response(resp)
T.ok(parsed ~= nil, "built response parses")
T.eq(parsed.status, 200, "response status")
T.eq(parsed.body, "hello", "response body")
T.eq(parsed.headers["content-type"], "text/plain", "response header")

local not_found = C.build_response(404, nil, "missing", { server_name = false })
parsed = C.parse_response(not_found)
T.eq(parsed.status, 404, "404 status")
T.eq(parsed.reason, "Not Found", "404 reason")

local head = C.build_response(200, nil, "hello", { head = true, server_name = false })
parsed = C.parse_response(head, { head = true })
T.eq(parsed.body, "", "HEAD response has no body")
T.eq(parsed.headers["content-length"], "5", "HEAD keeps the entity length")

local injected = C.build_response(200, { ["X-Evil"] = "a\r\nInjected: yes" }, "x", { server_name = false })
T.ok(not injected:find("Injected:", 1, true), "response header injection is dropped")

parsed, perr, st = C.parse_response("garbage\r\n\r\n")
T.eq(parsed, nil, "malformed response rejected")
T.eq(st, 400, "malformed response answers 400")

local reqraw = C.build_request("GET", "/x?y=1", { Host = "box", ["User-Agent"] = "t" })
T.ok(reqraw:find("GET /x?y=1 HTTP/1.1\r\n", 1, true) == 1, "request line is built")
T.ok(reqraw:find("Host: box\r\n", 1, true) ~= nil, "host header is built")
T.ok(reqraw:find("\r\n\r\n", 1, true) ~= nil, "request terminator is built")

local postraw = C.build_request("POST", "/echo", { Host = "box" }, "hello")
T.ok(postraw:find("Content-Length: 5\r\n", 1, true) ~= nil, "request content-length is added")
T.ok(postraw:sub(-5) == "hello", "request body is appended")
