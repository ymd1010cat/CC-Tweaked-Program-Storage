--[[- apps/http_common.lua - pure-Lua HTTP/1.x framing for the rpv1 app layer.

One parser/builder shared by http_server, http_client and http_secure. It is
deliberately strict: ASCII header sections, CRLF framing (bare LF is accepted on
input), no transfer-encoding/chunking, exact Content-Length, one message per
call. Every failure returns (nil, err, status) so callers can answer a 4xx
instead of crashing.

Limits (all overridable through opts):
  MAX_PATH         1024 bytes  -> 414
  MAX_REQUEST_LINE 2048 bytes  -> 414
  MAX_HEADER_BYTES 8192 bytes  -> 431
  MAX_BODY_BYTES  65536 bytes  -> 413

Path normalisation percent-decodes once, collapses //, drops '.', rejects '..',
non-ASCII and control bytes. Traversal or illegal bytes answer 403.
]]
local M = {}

M.DEFAULT_PORT = 8080
M.MAX_PATH = 1024
M.MAX_REQUEST_LINE = 2048
M.MAX_HEADER_BYTES = 8192
M.MAX_BODY_BYTES = 65536
M.PROTOCOL = "HTTP/1.1"

local REASON = {
    [100] = "Continue",
    [200] = "OK",
    [201] = "Created",
    [202] = "Accepted",
    [204] = "No Content",
    [206] = "Partial Content",
    [301] = "Moved Permanently",
    [302] = "Found",
    [304] = "Not Modified",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [408] = "Request Timeout",
    [413] = "Payload Too Large",
    [414] = "URI Too Long",
    [415] = "Unsupported Media Type",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
    [501] = "Not Implemented",
    [503] = "Service Unavailable",
    [505] = "HTTP Version Not Supported",
}

local CONTENT_TYPES = {
    html = "text/html; charset=us-ascii",
    htm = "text/html; charset=us-ascii",
    txt = "text/plain; charset=us-ascii",
    md = "text/markdown; charset=us-ascii",
    css = "text/css; charset=us-ascii",
    js = "application/javascript",
    json = "application/json",
    xml = "application/xml",
    lua = "text/plain; charset=us-ascii",
    csv = "text/csv; charset=us-ascii",
}

-- ===== small helpers =======================================================
function M.reason(status)
    local status = tonumber(status) or 0
    return REASON[status] or ("Status " .. tostring(status))
end

function M.is_ascii(s)
    if type(s) ~= "string" then return false end
    for i = 1, #s do
        if s:byte(i) > 127 then return false end
    end
    return true
end

-- true when every byte is a visible ASCII character (0x20..0x7e)
function M.is_printable_ascii(s)
    if type(s) ~= "string" or s == "" then return false end
    for i = 1, #s do
        local b = s:byte(i)
        if b < 32 or b > 126 then return false end
    end
    return true
end

-- RFC 7230 token: no separators, no controls, no non-ASCII
function M.is_token(s)
    if type(s) ~= "string" or s == "" then return false end
    for i = 1, #s do
        local b = s:byte(i)
        local ok = (b >= 48 and b <= 57)      -- 0-9
            or (b >= 65 and b <= 90)          -- A-Z
            or (b >= 97 and b <= 122)         -- a-z
            or b == 33 or b == 35 or b == 36 or b == 37 or b == 38 or b == 39
            or b == 42 or b == 43 or b == 45 or b == 46
            or b == 94 or b == 95 or b == 96 or b == 124 or b == 126
        if not ok then return false end
    end
    return true
end

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function has_control(s, allow_tab)
    for i = 1, #s do
        local b = s:byte(i)
        if b < 32 or b == 127 then
            if not (allow_tab and b == 9) then return true end
        end
    end
    return false
end

local function split_lines(s)
    local out = {}
    local i = 1
    while true do
        local j = s:find("\n", i, true)
        if not j then
            if i <= #s then out[#out + 1] = s:sub(i) end
            break
        end
        out[#out + 1] = s:sub(i, j - 1)
        i = j + 1
    end
    return out
end

local function split_head_body(raw)
    local i = raw:find("\r\n\r\n", 1, true)
    if i then return raw:sub(1, i - 1), raw:sub(i + 4) end
    i = raw:find("\n\n", 1, true)
    if i then return raw:sub(1, i - 1), raw:sub(i + 2) end
    return nil, nil
end

function M.header(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    return headers[name:lower()]
end

function M.content_type(path)
    local ext = tostring(path or ""):match("%.([%w]+)$")
    return CONTENT_TYPES[(ext or ""):lower()] or "application/octet-stream"
end

-- ===== percent decoding / path normalisation ===============================
function M.percent_decode(s, plus_as_space)
    if type(s) ~= "string" then return nil, "not a string" end
    local out = {}
    local i = 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "%" then
            local hex = s:sub(i + 1, i + 2)
            if #hex ~= 2 or hex:find("[^0-9a-fA-F]") then
                return nil, "bad percent escape"
            end
            local b = tonumber(hex, 16)
            if b == 0 then return nil, "nul byte" end
            out[#out + 1] = string.char(b)
            i = i + 3
        elseif plus_as_space and c == "+" then
            out[#out + 1] = " "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

function M.parse_query(query)
    local out = {}
    if type(query) ~= "string" or query == "" then return out end
    for pair in query:gmatch("[^&]+") do
        local raw_key, raw_val = pair:match("^([^=]*)=(.*)$")
        if not raw_key then raw_key, raw_val = pair, "" end
        local k = M.percent_decode(raw_key, true)
        local v = M.percent_decode(raw_val, true)
        if not k or not v or not M.is_ascii(k) or not M.is_ascii(v) then
            return nil, "bad query string"
        end
        if out[k] == nil then
            out[k] = v
        elseif type(out[k]) == "string" then
            out[k] = { out[k], v }
        else
            out[k][#out[k] + 1] = v
        end
    end
    return out
end

-- target is origin-form: "/path?query". Returns path, query or nil, err, status.
function M.normalize_path(target, opts)
    local opts = opts or {}
    local max_path = opts.max_path or M.MAX_PATH
    if type(target) ~= "string" or target == "" then
        return nil, "empty request target", 400
    end
    if #target > max_path then
        return nil, "uri too long", 414
    end
    if not M.is_ascii(target) then
        return nil, "non-ASCII request target", 403
    end
    if target:find("\\", 1, true) or target:find(" ", 1, true) then
        return nil, "illegal character in request target", 403
    end
    if has_control(target, false) then
        return nil, "control byte in request target", 403
    end
    if target:sub(1, 1) ~= "/" then
        return nil, "request target must start with /", 400
    end
    if target:find("#", 1, true) then
        return nil, "fragment not allowed in request target", 400
    end

    local path, query = target:match("^([^?]*)(.*)$")
    if query and query ~= "" then query = query:sub(2) end

    local parts = {}
    for seg in (path .. "/"):gmatch("([^/]*)/") do
        if seg ~= "" and seg ~= "." then
            local dec, derr = M.percent_decode(seg, false)
            if not dec then return nil, derr, 400 end
            if dec == ".." then
                return nil, "path traversal rejected", 403
            end
            if not M.is_printable_ascii(dec) then
                return nil, "illegal byte in path segment", 403
            end
            -- a decoded separator would change the segment structure on a
            -- second normalisation, so keep it out of the canonical path
            if dec:find("[/\\?#]", 1) then
                return nil, "encoded path separator rejected", 403
            end
            if dec ~= "." then parts[#parts + 1] = dec end
        end
    end

    local normal = "/" .. table.concat(parts, "/")
    if #normal > max_path then
        return nil, "uri too long", 414
    end
    return normal, query or ""
end

-- ===== header parsing ======================================================
local function parse_header_lines(lines, first)
    local headers = {}
    for i = first, #lines do
        local line = lines[i]
        if line == "" then
            -- an empty line in the middle is a framing error; a trailing one is
            -- impossible here because split_head_body consumed the terminator
            if i < #lines then return nil, "empty line inside header block", 400 end
        elseif line:sub(1, 1) == " " or line:sub(1, 1) == "\t" then
            return nil, "folded header lines are not supported", 400
        else
            local name, value = line:match("^([^:]+):(.*)$")
            if not name then return nil, "malformed header line", 400 end
            name = name:lower()
            if not M.is_token(name) then return nil, "bad header name", 400 end
            value = M.trim(value)
            if has_control(value, true) then
                return nil, "control byte in header value", 400
            end
            if not M.is_ascii(value) then
                return nil, "non-ASCII header value", 400
            end
            local had = headers[name]
            if had ~= nil then
                if name == "content-length" and had ~= value then
                    return nil, "conflicting content-length", 400
                end
                if name ~= "content-length" then
                    headers[name] = had .. ", " .. value
                end
            else
                headers[name] = value
            end
        end
    end
    return headers
end

local function prepare_head(raw, opts, limit)
    local opts = opts or {}
    local head, body = split_head_body(raw)
    if not head then return nil, nil, "missing header terminator", 400 end
    local max_head = opts.max_header_bytes or limit or M.MAX_HEADER_BYTES
    if #head > max_head then return nil, nil, "header block too large", 431 end
    head = head:gsub("\r\n", "\n")
    if head:find("\r", 1, true) then
        return nil, nil, "bare carriage return in header block", 400
    end
    return head, body
end

-- ===== requests ============================================================
function M.parse_request(raw, opts)
    local opts = opts or {}
    if type(raw) ~= "string" then
        return nil, "request must be a string", 400
    end
    local head, body, herr, hstatus = prepare_head(raw, opts, opts.max_header_bytes)
    if not head then return nil, herr, hstatus end

    local lines = split_lines(head)
    if #lines == 0 or lines[1] == "" then
        return nil, "empty request line", 400
    end
    if #lines[1] > (opts.max_request_line or M.MAX_REQUEST_LINE) then
        return nil, "request line too long", 414
    end

    local method, target, major, minor = lines[1]:match("^([^ ]+) ([^ ]+) HTTP/(%d)%.(%d)$")
    if not method then return nil, "malformed request line", 400 end
    if not M.is_token(method) then return nil, "bad method token", 400 end
    if major ~= "1" or (minor ~= "0" and minor ~= "1") then
        return nil, "unsupported HTTP version", 505
    end

    -- normalize_path returns (path, query) or (nil, err, status)
    local path, second, third = M.normalize_path(target, opts)
    if not path then return nil, second, third end
    local query = second

    local headers, xerr, xstatus = parse_header_lines(lines, 2)
    if not headers then return nil, xerr, xstatus end

    if headers["transfer-encoding"] then
        return nil, "transfer-encoding is not supported", 400
    end

    local content_length = 0
    local cl = headers["content-length"]
    if cl ~= nil then
        if not cl:match("^%d+$") then
            return nil, "bad content-length", 400
        end
        content_length = tonumber(cl) or 0
        if content_length > (opts.max_body_bytes or M.MAX_BODY_BYTES) then
            return nil, "body too large", 413
        end
    end

    if content_length > 0 then
        if #body < content_length then return nil, "incomplete body", 400 end
        if #body > content_length then return nil, "trailing bytes after body", 400 end
        body = body:sub(1, content_length)
    else
        if #body > 0 then return nil, "body without content-length", 400 end
        body = ""
    end

    local connection = (headers.connection or ""):lower()
    local keep_alive
    if major == "1" and minor == "1" then
        keep_alive = connection:find("close", 1, true) == nil
    else
        keep_alive = connection:find("keep-alive", 1, true) ~= nil
    end

    local qtable, qerr = M.parse_query(query)
    if not qtable then return nil, qerr, 400 end

    return {
        method = method,
        target = target,
        path = path,
        query_string = query,
        query = qtable,
        version = "HTTP/" .. major .. "." .. minor,
        headers = headers,
        body = body,
        content_length = content_length,
        keep_alive = keep_alive,
    }
end

function M.build_request(method, target, headers, body)
    local method = tostring(method or "GET")
    target = tostring(target or "/")
    if not M.is_token(method) then return nil, "bad method" end
    if target == "" or not M.is_ascii(target) or has_control(target, false) then
        return nil, "bad request target"
    end
    if target:find(" ", 1, true) then return nil, "space in request target" end

    local h = {}
    for k, v in pairs(headers or {}) do
        if type(k) == "string" and M.is_token(k) and v ~= nil then
            local sv = tostring(v)
            if M.is_ascii(sv) and not has_control(sv, true) then
                h[#h + 1] = { k, sv }
            end
        end
    end
    body = body or ""
    local has_length = false
    for _, kv in ipairs(h) do
        if kv[1]:lower() == "content-length" then has_length = true end
    end
    if not has_length and #body > 0 then
        h[#h + 1] = { "Content-Length", tostring(#body) }
    end
    table.sort(h, function(a, b) return a[1]:lower() < b[1]:lower() end)

    local out = { method .. " " .. target .. " HTTP/1.1\r\n" }
    for _, kv in ipairs(h) do
        out[#out + 1] = kv[1] .. ": " .. kv[2] .. "\r\n"
    end
    out[#out + 1] = "\r\n"
    out[#out + 1] = body
    return table.concat(out)
end

-- ===== responses ===========================================================
function M.build_response(status, headers, body, opts)
    local opts = opts or {}
    local status = tonumber(status) or 500
    local reason = tostring(opts.reason or M.reason(status))
    if not M.is_ascii(reason) or has_control(reason, false) then
        reason = M.reason(status)
    end

    local h = {}
    local has_length, has_connection, has_server = false, false, false
    for k, v in pairs(headers or {}) do
        if type(k) == "string" and M.is_token(k) and v ~= nil then
            local sv = tostring(v)
            if M.is_ascii(sv) and not has_control(sv, true) then
                h[#h + 1] = { k, sv }
                local lk = k:lower()
                if lk == "content-length" then has_length = true end
                if lk == "connection" then has_connection = true end
                if lk == "server" then has_server = true end
            end
        end
    end

    local omit_body = opts.head or status == 204 or status == 304
    if body ~= nil and not has_length and status ~= 204 and status ~= 304 then
        h[#h + 1] = { "Content-Length", tostring(#body) }
    end
    if not has_connection and not opts.keep_alive then
        h[#h + 1] = { "Connection", "close" }
    end
    if not has_server and opts.server_name ~= false then
        h[#h + 1] = { "Server", tostring(opts.server_name or "rpv-http/1.0") }
    end
    table.sort(h, function(a, b) return a[1]:lower() < b[1]:lower() end)

    local out = { "HTTP/1.1 " .. status .. " " .. reason .. "\r\n" }
    for _, kv in ipairs(h) do
        out[#out + 1] = kv[1] .. ": " .. kv[2] .. "\r\n"
    end
    out[#out + 1] = "\r\n"
    if not omit_body and body ~= nil then out[#out + 1] = body end
    return table.concat(out)
end

function M.parse_response(raw, opts)
    local opts = opts or {}
    if type(raw) ~= "string" then return nil, "response must be a string", 400 end
    local head, body, herr, hstatus = prepare_head(raw, opts, opts.max_header_bytes)
    if not head then return nil, herr, hstatus end
    if not M.is_ascii(head) then return nil, "non-ASCII header block", 400 end

    local lines = split_lines(head)
    if #lines == 0 or lines[1] == "" then
        return nil, "empty status line", 400
    end
    local major, minor, code, reason = lines[1]:match("^HTTP/(%d)%.(%d) (%d%d%d) ?(.*)$")
    if not code then return nil, "malformed status line", 400 end
    if major ~= "1" then return nil, "unsupported HTTP version", 505 end
    code = tonumber(code)

    local headers, xerr, xstatus = parse_header_lines(lines, 2)
    if not headers then return nil, xerr, xstatus end

    local resp = {
        version = "HTTP/" .. major .. "." .. minor,
        status = code,
        reason = M.trim(reason),
        headers = headers,
        body = "",
    }
    if code == 204 or code == 304 or (code >= 100 and code < 200) then
        return resp
    end

    local cl = headers["content-length"]
    if cl ~= nil then
        if not cl:match("^%d+$") then return nil, "bad content-length", 400 end
        local n = tonumber(cl) or 0
        if opts.head then return resp end
        if #body < n then return nil, "incomplete response body", 400 end
        resp.body = body:sub(1, n)
    else
        resp.body = opts.head and "" or body
    end
    return resp
end

return M
