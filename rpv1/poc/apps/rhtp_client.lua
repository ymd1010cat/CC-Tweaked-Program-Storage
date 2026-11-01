--[[- apps/rhtp_client.lua - RHTP/1.0 one-shot client for the rpv1 app layer.

RHTP is the datagram HTTP-alike rpv1 apps speak: one request datagram in, one
response datagram out, no keep-alive and no pipelining. apps/rhtp_server.lua is
the server half; this file is the client half.

Three layers, each usable on its own:

    local req = rhtp_client.build_request("GET", "/api/directory")
    local res = rhtp_client.parse_response(raw)
    local r   = rhtp_client.get{ path = "/", transport = my_transport }

get/request take an injected transport, exactly like apps/http_client.lua:

    transport(payload, meta) -> raw_response | nil, err
    or a table carrying a send(self, payload, meta) method

meta carries path, port, timeout_ms, attempt and (when known) addr. The transport
owns the deadline: a synchronous Lua call cannot abort itself.

For a live rpv node the transport is asynchronous, so rhtp_client.call() binds an
ephemeral local port, sends one datagram and fires the callback from the socket
handler (or from a node:after timeout). It never blocks, so it is safe inside any
rpv callback:

    rhtp_client.call(node, rpv, { addr = "172.16.1.2", path = "/" },
        function(res, err) ... end)

M.rpv_transport() is the blocking variant for pumped harnesses only: it calls
opts.pump (default node:tick) in a loop until the reply arrives or the deadline
passes. Never call it from inside a live event loop - the node's own pullEvent
loop is what delivers the datagram there.

Everything here is ASCII-only and pure Lua 5.1.
]]
local M = {}

M.VERSION = "1.0"
M.PROTOCOL = "RHTP/1.0"
M.DEFAULT_PORT = 8080
M.DEFAULT_TIMEOUT_MS = 3000
M.DEFAULT_RETRIES = 2
M.DEFAULT_BACKOFF_MS = 100
M.DEFAULT_BACKOFF_MAX_MS = 2000
M.MAX_RETRIES = 10
M.DEFAULT_LOCAL_PORT = 40000
M.LOCAL_PORT_TRIES = 64

-- ===== small helpers ========================================================
local function is_ascii(s)
    if type(s) ~= "string" then return false end
    for i = 1, #s do
        if s:byte(i) > 126 or s:byte(i) < 32 then return false end
    end
    return true
end

local function hex_encode(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", string.byte(s, i)) end
    return table.concat(out)
end
M.hex = hex_encode

-- the library table resolves exactly like the server side: explicit argument ->
-- load-time vararg -> _G.rpv -> require("rpv")
local function usable(t)
    return type(t) == "table" and type(t.udp_send) == "function"
end

local ARGV = ...

local function resolve_rpv(explicit)
    if usable(explicit) then return explicit end
    if usable(ARGV) then return ARGV end
    if type(_G) == "table" and usable(_G.rpv) then return _G.rpv end
    if type(require) == "function" then
        local ok, mod = pcall(require, "rpv")
        if ok and usable(mod) then return mod end
    end
    return nil
end

-- ===== request side =========================================================
-- Deterministic header order (sorted by name) so a test can compare bytes.
local function sorted_keys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return keys
end

-- build_request(method, path[, headers[, body]]) -> request_datagram | nil, err
function M.build_request(method, path, headers, body)
    local m = method
    if m == nil then m = "GET" end
    if type(m) ~= "string" or m == "" or not m:match("^[A-Z]+$") then
        return nil, "method must be uppercase letters"
    end
    if type(path) ~= "string" or path == "" then return nil, "path must be a string" end
    if path:sub(1, 1) ~= "/" then return nil, "path must start with /" end
    if not is_ascii(path) then return nil, "non-ASCII path" end
    if path:find("%s") then return nil, "path must not contain whitespace" end

    local out = m .. " " .. path .. " " .. M.PROTOCOL .. "\r\n"
    if headers ~= nil then
        if type(headers) ~= "table" then return nil, "headers must be a table" end
        for _, name in ipairs(sorted_keys(headers)) do
            local value = headers[name]
            if not name:match("^[%w%-_]+$") then return nil, "bad header name: " .. name end
            if not is_ascii(tostring(value)) then return nil, "bad header value: " .. name end
            out = out .. name .. ": " .. tostring(value) .. "\r\n"
        end
    end
    out = out .. "\r\n"
    if body ~= nil then
        if type(body) ~= "string" then return nil, "body must be a string" end
        out = out .. body
    end
    return out
end

-- ===== response side ========================================================
-- parse_response(raw) -> { version, status, reason, headers, raw_headers, body }
-- headers are lowercased for lookup, raw_headers keeps the wire spelling.
function M.parse_response(raw)
    if type(raw) ~= "string" or raw == "" then return nil, "empty response" end
    local at = raw:find("\r\n\r\n", 1, true)
    if not at then return nil, "no header terminator" end
    local head = raw:sub(1, at - 1)
    local body = raw:sub(at + 4)

    local lines = {}
    local start = 1
    while true do
        local hit = head:find("\r\n", start, true)
        if not hit then
            lines[#lines + 1] = head:sub(start)
            break
        end
        lines[#lines + 1] = head:sub(start, hit - 1)
        start = hit + 2
    end

    local version, code, reason = (lines[1] or ""):match("^(RHTP/%d+%.%d+)%s+(%d%d%d)%s*(.*)$")
    if not version then return nil, "bad status line" end

    local headers = {}
    local raw_headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([%w%-_]+):%s*(.*)$")
        if not name then return nil, "bad header line" end
        headers[name:lower()] = value
        raw_headers[#raw_headers + 1] = { name = name, value = value }
    end

    return {
        ok = true,
        version = version,
        status = tonumber(code),
        reason = reason,
        headers = headers,
        raw_headers = raw_headers,
        body = body,
    }
end

-- case-insensitive header lookup
function M.header(res, name)
    if type(res) ~= "table" or type(res.headers) ~= "table" then return nil end
    if type(name) ~= "string" then return nil end
    return res.headers[name:lower()]
end

-- verify_dns_hash(res[, sha256[, hex]]) -> true | false, why
-- The X-DNS-Hash header is the SHA-256 of the *body*, 64 lowercase hex chars.
function M.verify_dns_hash(res, sha256, hex)
    if type(res) ~= "table" or type(res.body) ~= "string" then return false, "no body" end
    local want = M.header(res, "X-DNS-Hash")
    if not want then return false, "no X-DNS-Hash header" end
    if type(sha256) ~= "function" then return false, "no sha256 function" end
    local digest = sha256(res.body)
    local got
    if type(hex) == "function" then got = hex(digest) else got = hex_encode(digest) end
    if got ~= want then return false, "hash mismatch" end
    return true
end

-- ===== transport plumbing ===================================================
local function call_transport(transport, payload, meta)
    if type(transport) == "function" then return transport(payload, meta) end
    if type(transport) == "table" then
        if type(transport.send) == "function" then return transport.send(transport, payload, meta) end
        if type(transport.request) == "function" then
            return transport.request(transport, payload, meta)
        end
    end
    return nil, "no transport"
end

local function backoff_delay(opts, attempt)
    local b = opts.backoff
    if type(b) == "function" then
        local ok, value = pcall(b, attempt)
        if ok then return math.max(0, tonumber(value) or 0) end
        return 0
    end
    local base = tonumber(b) or tonumber(opts.backoff_ms) or M.DEFAULT_BACKOFF_MS
    local cap = tonumber(opts.backoff_max_ms) or M.DEFAULT_BACKOFF_MAX_MS
    if base < 0 then base = 0 end
    local delay = base * (2 ^ (attempt - 1))
    if delay > cap then delay = cap end
    return delay
end

local function sleep_seconds(opts, seconds)
    local sleep = opts.sleep
    if type(sleep) == "function" then pcall(sleep, seconds) return end
    if os and os.sleep then pcall(os.sleep, seconds) end
end

local function normalize_retries(opts)
    local retries = tonumber(opts.retries)
    if retries == nil then retries = M.DEFAULT_RETRIES end
    if retries < 0 then retries = 0 end
    if retries > M.MAX_RETRIES then retries = M.MAX_RETRIES end
    return retries
end

-- ===== request/response over an injected transport ==========================
-- request(method[, opts]) -> { ok=true, status, reason, headers, body, attempts }
--                        | { ok=false, err, attempts }
function M.request(method, opts)
    local o = opts
    if type(o) == "string" then o = { path = opts } end
    if type(o) ~= "table" then return { ok = false, err = "opts must be a table" } end
    if o.transport == nil then return { ok = false, err = "no transport" } end

    local m = method or o.method or "GET"
    local path = o.path or "/"
    local request, berr = M.build_request(m, path, o.headers, o.body)
    if not request then return { ok = false, err = tostring(berr) } end

    local timeout_ms = tonumber(o.timeout_ms) or M.DEFAULT_TIMEOUT_MS
    if timeout_ms <= 0 then timeout_ms = M.DEFAULT_TIMEOUT_MS end
    local retries = normalize_retries(o)
    local attempts = retries + 1

    local meta = {
        path = path,
        port = tonumber(o.port) or M.DEFAULT_PORT,
        addr = o.addr,
        timeout_ms = timeout_ms,
        method = m,
    }

    local last_err = "no attempt made"
    for attempt = 1, attempts do
        meta.attempt = attempt
        local raw, terr = call_transport(o.transport, request, meta)
        if raw == nil then
            last_err = tostring(terr or "transport error")
        else
            local res, perr = M.parse_response(raw)
            if res then
                res.attempts = attempt
                return res
            end
            last_err = "bad response: " .. tostring(perr)
        end
        if type(o.on_attempt) == "function" then pcall(o.on_attempt, attempt, last_err) end
        if attempt < attempts then
            local delay = backoff_delay(o, attempt)
            if type(o.on_backoff) == "function" then pcall(o.on_backoff, attempt, delay) end
            sleep_seconds(o, delay / 1000)
        end
    end
    return { ok = false, err = last_err, attempts = attempts }
end

function M.get(opts)
    return M.request("GET", opts)
end

-- ===== ephemeral local ports ===============================================
local function port_free(node, port)
    if type(node) ~= "table" then return true end
    if type(node.udp) ~= "table" or type(node.udp.ports) ~= "table" then return true end
    return node.udp.ports[port] == nil
end

-- bind the first free port in [base, base + tries); the handler receives
-- (data, src, sport) like any rpv socket handler
local function bind_ephemeral(node, base, tries, handler)
    for i = 0, tries - 1 do
        local candidate = base + i
        if candidate <= 65535 and port_free(node, candidate) then
            local ok, sk = pcall(node.bind, node, candidate, handler)
            if ok and type(sk) == "table" then return sk, candidate end
        end
    end
    return nil, nil
end

-- ===== asynchronous one-shot call (live event loop) =========================
-- call(node, rpv, opts, on_done) -> socket | nil, err
-- opts: addr (integer) or host (string, resolved through rpv.ip2int),
--       port, path, method, timeout_ms, local_port, local_port_tries, rpv
function M.call(node, rpv, opts, on_done)
    local o = opts or {}
    local cb = on_done or o.on_done
    if type(cb) ~= "function" then return nil, "no callback" end
    if type(node) ~= "table" or type(node.bind) ~= "function" then return nil, "no node" end

    local RP = resolve_rpv(rpv or o.rpv)
    local dst = o.addr
    if dst == nil and type(o.host) == "string" and RP and type(RP.ip2int) == "function" then
        local ok, value = pcall(RP.ip2int, o.host)
        if ok then dst = value end
    end
    if type(dst) ~= "number" then return nil, "no destination address" end

    local port = tonumber(o.port) or M.DEFAULT_PORT
    local request, berr = M.build_request(o.method or "GET", o.path or "/", o.headers, o.body)
    if not request then return nil, tostring(berr) end

    local timeout_ms = tonumber(o.timeout_ms) or M.DEFAULT_TIMEOUT_MS
    if timeout_ms <= 0 then timeout_ms = M.DEFAULT_TIMEOUT_MS end
    local base = tonumber(o.local_port) or M.DEFAULT_LOCAL_PORT
    local tries = tonumber(o.local_port_tries) or M.LOCAL_PORT_TRIES

    local state = { done = false, sk = nil }

    local function finish(res, err)
        if state.done then return end
        state.done = true
        if state.sk and state.sk.close then pcall(state.sk.close, state.sk) end
        pcall(cb, res, err)
    end

    local function on_receive(data, src, sport)
        if state.done then return end
        local res, perr = M.parse_response(data)
        if not res then
            finish(nil, "bad response: " .. tostring(perr))
            return
        end
        res.from = src
        res.from_port = sport
        finish(res, nil)
    end

    local sk, lport = bind_ephemeral(node, base, tries, on_receive)
    if not sk then return nil, "no free local port" end
    state.sk = sk

    local sent, send_err
    if RP and type(RP.udp_send) == "function" then
        sent, send_err = pcall(RP.udp_send, node, dst, lport, port, request)
    else
        sent, send_err = pcall(sk.sendto, sk, dst, port, request)
    end
    if not sent then
        finish(nil, "send failed: " .. tostring(send_err))
        return sk
    end

    if type(node.after) == "function" then
        pcall(node.after, node, timeout_ms / 1000, function() finish(nil, "timeout") end)
    end
    return sk
end

-- ===== blocking transport for pumped harnesses ==============================
-- rpv_transport(node, rpv[, opts]) -> transport(payload, meta) -> raw | nil, err
-- opts: clock (default os.clock), pump (default node:tick), timeout_ms,
--       local_port, local_port_tries, addr (fallback when meta.addr is nil)
function M.rpv_transport(node, rpv, opts)
    local o = opts or {}
    local RP = resolve_rpv(rpv or o.rpv)
    local clock = o.clock
    if type(clock) ~= "function" then clock = os.clock end
    local pump = o.pump
    if type(pump) ~= "function" then pump = function() node:tick() end end

    return function(payload, meta)
        local m = meta or {}
        local dst = m.addr or o.addr
        if type(dst) ~= "number" then return nil, "no destination address" end
        local port = tonumber(m.port) or M.DEFAULT_PORT
        local timeout_ms = tonumber(m.timeout_ms) or tonumber(o.timeout_ms) or M.DEFAULT_TIMEOUT_MS
        local base = tonumber(o.local_port) or M.DEFAULT_LOCAL_PORT
        local tries = tonumber(o.local_port_tries) or M.LOCAL_PORT_TRIES

        local state = { reply = nil }
        local sk, lport = bind_ephemeral(node, base, tries, function(data)
            state.reply = data
        end)
        if not sk then return nil, "no free local port" end

        local sent, send_err
        if RP and type(RP.udp_send) == "function" then
            sent, send_err = pcall(RP.udp_send, node, dst, lport, port, payload)
        else
            sent, send_err = pcall(sk.sendto, sk, dst, port, payload)
        end
        if not sent then
            if sk.close then pcall(sk.close, sk) end
            return nil, "send failed: " .. tostring(send_err)
        end

        local deadline = clock() + timeout_ms / 1000
        while state.reply == nil and clock() < deadline do
            pcall(pump)
        end
        if sk.close then pcall(sk.close, sk) end
        if state.reply == nil then return nil, "timeout" end
        return state.reply
    end
end

return M
