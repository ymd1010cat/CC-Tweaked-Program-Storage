--[[- apps/http_client.lua - one-shot HTTP/1.1 client for the rpv1 app layer.

    local r = http_client.get({ url = "http://10.0.1.2:8080/status" })
    -- r = { ok = true, status = 200, body = "...", err = nil }

The transport is injected, so this module stays pure Lua:
  opts.transport = function(request_string, meta) -> raw_response, err
  opts.transport = { request = function(self, request_string, meta) ... end }

meta carries host, port, path, url, method, attempt and timeout_ms. The transport
owns the actual deadline (a synchronous Lua call cannot abort itself); timeout_ms
is therefore a contract handed to it and to the caller's retry policy.

Retries: opts.retries (default 2) extra attempts, exponential backoff starting at
opts.backoff_ms (default 100 ms), capped by opts.backoff_max_ms (default 2000 ms).
opts.backoff may also be a function(attempt) -> milliseconds. opts.sleep(seconds)
overrides os.sleep (tests pass a fake).

ok is true whenever a well-formed HTTP response arrived, including 4xx/5xx: callers
inspect status. ok is false only for transport, framing or secure-envelope errors,
and then err explains why. opts.secure (an http_secure client instance) seals the
request (c2s) and opens the response (s2c).
]]
local M = {}

M.DEFAULT_TIMEOUT_MS = 5000
M.DEFAULT_RETRIES = 2
M.DEFAULT_BACKOFF_MS = 100
M.DEFAULT_BACKOFF_MAX_MS = 2000
M.MAX_RETRIES = 10

local cached_common
local function get_common()
    if cached_common then return cached_common end
    for _, path in ipairs({ "apps/http_common.lua", "http_common.lua" }) do
        local chunk = loadfile(path)
        if chunk then
            local mod = chunk()
            if type(mod) == "table" then
                cached_common = mod
                return mod
            end
        end
    end
    return nil
end

function M.parse_url(url, common)
    common = common or get_common()
    if not common then return nil, "http_common module not found" end
    if type(url) ~= "string" or url == "" then return nil, "url must be a string" end
    if not common.is_ascii(url) then return nil, "non-ASCII url" end

    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    if not scheme then return nil, "url needs a scheme" end
    if scheme:lower() ~= "http" then return nil, "unsupported scheme: " .. scheme end
    local hostport, target = rest:match("^([^/]*)(.*)$")
    if not hostport or hostport == "" then return nil, "empty host" end

    local host, port = hostport:match("^([^:]+):(%d+)$")
    if not host then
        host, port = hostport, common.DEFAULT_PORT
    end
    if not host:match("^[%w%.%-]+$") then return nil, "bad host" end
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then return nil, "bad port" end

    if target == "" then target = "/" end
    if target:sub(1, 1) == "?" then target = "/" .. target end
    if target:sub(1, 1) ~= "/" then return nil, "bad request target" end
    -- validate (traversal, escapes, non-ASCII) but send the original encoding
    local path, query, status = common.normalize_path(target)
    if not path then return nil, tostring(query) .. (status and (" (" .. status .. ")") or "") end

    return { host = host, port = port, path = target, url = url }
end

local function resolve_target(opts, common)
    if opts.url ~= nil then
        return M.parse_url(opts.url, common)
    end
    local host = opts.host
    if type(host) ~= "string" or host == "" then return nil, "no url or host" end
    if not host:match("^[%w%.%-]+$") then return nil, "bad host" end
    local port = tonumber(opts.port) or common.DEFAULT_PORT
    if port < 1 or port > 65535 then return nil, "bad port" end
    local target = opts.path or "/"
    if type(target) ~= "string" or target:sub(1, 1) ~= "/" then
        return nil, "bad request target"
    end
    local path, perr, pstatus = common.normalize_path(target)
    if not path then
        return nil, tostring(perr) .. (pstatus and (" (" .. pstatus .. ")") or "")
    end
    return { host = host, port = port, path = target, url = "http://" .. host .. ":" .. port .. target }
end

local function call_transport(transport, payload, meta)
    if type(transport) == "function" then
        return transport(payload, meta)
    end
    if type(transport) == "table" then
        if type(transport.request) == "function" then
            return transport.request(transport, payload, meta)
        end
        if type(transport.send) == "function" then
            return transport.send(transport, payload, meta)
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

function M.request(method, opts)
    if type(opts) == "string" then opts = { url = opts } end
    if type(opts) ~= "table" then return { ok = false, err = "opts must be a table" } end
    if opts.transport == nil then return { ok = false, err = "no transport" } end
    if opts.body ~= nil and type(opts.body) ~= "string" then
        return { ok = false, err = "body must be a string" }
    end
    local common = opts.common or get_common()
    if not common then return { ok = false, err = "http_common module not found" } end

    local method = tostring(method or "GET")
    local target, terr = resolve_target(opts, common)
    if not target then return { ok = false, err = terr } end

    local timeout_ms = tonumber(opts.timeout_ms) or M.DEFAULT_TIMEOUT_MS
    if timeout_ms <= 0 then timeout_ms = M.DEFAULT_TIMEOUT_MS end
    local retries = tonumber(opts.retries)
    if retries == nil then retries = M.DEFAULT_RETRIES end
    if retries < 0 then retries = 0 end
    if retries > M.MAX_RETRIES then retries = M.MAX_RETRIES end
    local attempts = retries + 1

    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if headers.Host == nil and headers.host == nil then
        if target.port == common.DEFAULT_PORT then
            headers.Host = target.host
        else
            headers.Host = target.host .. ":" .. tostring(target.port)
        end
    end
    if headers["User-Agent"] == nil then headers["User-Agent"] = "rpv-http/1.0" end
    if headers.Accept == nil then headers.Accept = "*/*" end
    if headers.Connection == nil then headers.Connection = "close" end

    local request_string, berr = common.build_request(method, target.path, headers, opts.body)
    if not request_string then return { ok = false, err = tostring(berr) } end

    local secure = opts.secure
    local last_err = "no attempt made"
    local meta = {
        host = target.host,
        port = target.port,
        path = target.path,
        url = target.url,
        method = method,
        timeout_ms = timeout_ms,
        headers = headers,
    }

    for attempt = 1, attempts do
        meta.attempt = attempt

        local payload = request_string
        if secure then
            if secure.enabled == false then
                return { ok = false, err = "secure transport disabled" }
            end
            local sealed, serr = secure:seal_request(request_string)
            if not sealed then
                return { ok = false, err = "secure seal: " .. tostring(serr) }
            end
            payload = sealed
        end

        local raw_response, tperr = call_transport(opts.transport, payload, meta)
        if raw_response == nil then
            last_err = tostring(tperr or "transport error")
        else
            local text = raw_response
            if secure then
                local plain, oerr = secure:open_response(raw_response, meta.host)
                if not plain then
                    last_err = "secure open: " .. tostring(oerr)
                    text = nil
                else
                    text = plain
                end
            end
            if text ~= nil then
                local parsed, perr = common.parse_response(text, { head = method == "HEAD" })
                if parsed then
                    return {
                        ok = true,
                        status = parsed.status,
                        body = parsed.body,
                        err = nil,
                        headers = parsed.headers,
                        attempts = attempt,
                    }
                end
                last_err = "bad response: " .. tostring(perr)
            end
        end

        if type(opts.on_attempt) == "function" then
            pcall(opts.on_attempt, attempt, last_err)
        end
        if attempt < attempts then
            local delay = backoff_delay(opts, attempt)
            if type(opts.on_backoff) == "function" then
                pcall(opts.on_backoff, attempt, delay)
            end
            sleep_seconds(opts, delay / 1000)
        end
    end

    return { ok = false, err = last_err, attempts = attempts }
end

function M.get(opts)
    return M.request("GET", opts)
end

function M.post(opts)
    return M.request("POST", opts)
end

return M
