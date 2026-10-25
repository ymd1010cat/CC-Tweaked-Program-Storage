--[[- apps/http_server.lua - minimal GET router for the rpv1 HTTP layer.

    local server = http_server.start(8080, routes, opts)
    local response = server:handle(raw_request, src)   -- always returns a string
    server:stop()

routes is an exact path table:
  "/ping"   = "pong"                          -- static body
  "/hello"  = function(req, server) ... end   -- function route

Only GET is served. For a matched route, every other method (including HEAD)
answers 405 with "Allow: GET" and does not run the handler; an unknown path still
answers 404 first. This keeps the app layer to the static/function GET routes the
baseline asked for (no HEAD, POST body handling, directory serving or wildcard
prefixes). Responses default to "Connection: close" (a handler-provided
Connection header wins), and handle(raw, src) consumes exactly one request (one
datagram): there is no keep-alive, pipelining or concurrent connection handling.

A handler returns nil, a string (body), a number (status), or a table
{ status = 200, body = "text", headers = { ... }, content_type = "text/plain" }.

opts:
  transport    function(port, on_data) or { bind = function(self, port, on_data) }
               on_data(data, reply, src) -> reply(response). Without it the server
               is offline-only and only server:handle() is used. src is forwarded
               to http_secure's rate limiter.
  secure       http_secure instance in server role. Requests must be envelopes
               and responses are sealed.
  strict       default true with secure: plaintext or bad envelopes answer 403;
               false lets plaintext requests through (bad envelopes answer 400).
  log          function(level, message)
  server_name  response Server header (default rpv-http/1.0)
  max_path, max_request_line, max_header_bytes, max_body_bytes
               forwarded to http_common

Status codes: 200/201/204, 400, 403 (traversal, non-ASCII, secure required),
404, 405 (+ Allow: GET), 413, 414, 431, 500; 505 for an unsupported HTTP version.
Handler errors are caught with xpcall and become 500; handle() itself never throws.

Security knobs live in http_secure: rate_limit is fail-closed (missing src, bad
clock/label or a full max_sources table rejects the request), malformed src
labels can share a bucket, session_epoch is session separation and not
authentication, and seed_file defaults to <role_file dir>/seed.bin. See the
README "Application-layer HTTP (minimal GET) and security boundary" for the full boundary.
]]
local M = {}

local ALLOW = "GET"

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

local function trace(err)
    if debug and debug.traceback then
        local ok, tb = pcall(debug.traceback, tostring(err), 2)
        if ok and tb then return tb end
    end
    return tostring(err)
end

local Server = {}
Server.__index = Server

function Server:_log(level, fmt, ...)
    local log = self.opts.log
    if type(log) ~= "function" then return end
    local msg = fmt
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        if ok then msg = formatted end
    end
    pcall(log, level, tostring(msg))
end

function Server:_index_routes()
    self.exact = {}
    for key, value in pairs(self.routes) do
        if type(key) == "string" and key:sub(1, 1) == "/" then
            self.exact[key] = value
        end
    end
end

function Server:_match(path)
    return self.exact[path]
end

function Server:_invoke(handler, req)
    local ok, res = xpcall(function() return handler(req, self) end, trace)
    if not ok then
        self.stats.errors = self.stats.errors + 1
        self:_log("ERROR", "handler error: " .. tostring(res))
        return nil, res
    end
    return res
end

function Server:_normalize_result(res)
    if res == nil then return { status = 200, body = "" } end
    if type(res) == "string" then return { status = 200, body = res } end
    if type(res) == "number" then return { status = res, body = "" } end
    if type(res) == "table" then
        local status = tonumber(res.status) or 200
        if status < 100 or status > 599 then return nil, "invalid handler status" end
        if res.body ~= nil and type(res.body) ~= "string" then
            return nil, "handler body must be a string"
        end
        return {
            status = status,
            body = res.body or "",
            headers = res.headers,
            content_type = res.content_type,
        }
    end
    return nil, "handler returned " .. type(res)
end

function Server:_resolve(req)
    local route = self:_match(req.path)
    if route == nil then return nil, 404 end
    if req.method ~= "GET" then return nil, 405 end
    if type(route) == "string" then return { kind = "body", body = route } end
    if type(route) == "function" then return { kind = "handler", handler = route } end
    return nil, 500
end

function Server:_respond(req, status, body, headers, opts)
    local common = self.common
    local opts = opts or {}
    local h = {}
    for k, v in pairs(headers or {}) do h[k] = v end
    if opts.content_type and h["Content-Type"] == nil and h["content-type"] == nil then
        h["Content-Type"] = opts.content_type
    end
    if body ~= nil and type(body) ~= "string" then body = tostring(body) end
    local status = tonumber(status) or 500
    self.stats.by_status[status] = (self.stats.by_status[status] or 0) + 1
    return common.build_response(status, h, body, {
        server_name = self.opts.server_name,
    })
end

function Server:_dispatch(req)
    local resolved, status = self:_resolve(req)
    if not resolved then
        if status == 405 then
            return {
                status = 405,
                body = "Method Not Allowed",
                headers = { Allow = ALLOW },
                content_type = "text/plain; charset=us-ascii",
            }
        end
        return {
            status = status or 404,
            body = self.common.reason(status or 404),
            content_type = "text/plain; charset=us-ascii",
        }
    end

    if resolved.kind == "body" then
        return {
            status = 200,
            body = resolved.body,
            content_type = self.common.content_type(req.path),
        }
    end

    local res, err = self:_invoke(resolved.handler, req)
    if res == nil and err ~= nil then
        return {
            status = 500,
            body = "Internal Server Error",
            content_type = "text/plain; charset=us-ascii",
        }
    end

    local normalized, nerr = self:_normalize_result(res)
    if not normalized then
        self.stats.errors = self.stats.errors + 1
        self:_log("ERROR", tostring(nerr))
        return {
            status = 500,
            body = "Internal Server Error",
            content_type = "text/plain; charset=us-ascii",
        }
    end
    return normalized
end

function Server:_finish(response)
    local secure = self.opts.secure
    if secure and secure.enabled ~= false then
        local ok, sealed = pcall(secure.seal_response, secure, response)
        if ok and sealed then return sealed end
        self:_log("SEC", "could not seal response: " .. tostring(sealed))
        local fallback = self.common.build_response(500, nil, "Internal Server Error", {
            server_name = self.opts.server_name,
        })
        local fok, fsealed = pcall(secure.seal_response, secure, fallback)
        if fok and fsealed then return fsealed end
        -- never fall back to plaintext while secure mode is enabled
        return ""
    end
    return response
end

function Server:_handle(raw, src)
    local raw = raw
    local common = self.common
    self.stats.requests = self.stats.requests + 1
    if type(raw) ~= "string" then
        return self:_finish(self:_respond(nil, 400, "Bad Request", nil, {
            content_type = "text/plain; charset=us-ascii",
        }))
    end

    local strict = self.opts.strict ~= false
    local secure = self.opts.secure
    if secure then
        if secure.enabled == false then
            if strict then
                self.stats.rejected = self.stats.rejected + 1
                return self:_finish(self:_respond(nil, 403, "Forbidden: secure transport required", nil, {
                    content_type = "text/plain; charset=us-ascii",
                }))
            end
        elseif raw:sub(1, 1) == "H" then
            local plain, serr = secure:open_request(raw, src)
            if not plain then
                self.stats.rejected = self.stats.rejected + 1
                self:_log("SEC", "request rejected: " .. tostring(serr))
                local code = strict and 403 or 400
                return self:_finish(self:_respond(nil, code, "Forbidden: " .. tostring(serr), nil, {
                    content_type = "text/plain; charset=us-ascii",
                }))
            end
            raw = plain
        elseif strict then
            self.stats.rejected = self.stats.rejected + 1
            return self:_finish(self:_respond(nil, 403, "Forbidden: secure envelope required", nil, {
                content_type = "text/plain; charset=us-ascii",
            }))
        end
    end

    local req, perr, pstatus = common.parse_request(raw, self.opts)
    if not req then
        self.stats.rejected = self.stats.rejected + 1
        return self:_finish(self:_respond(nil, pstatus or 400, tostring(perr), nil, {
            content_type = "text/plain; charset=us-ascii",
        }))
    end

    local res = self:_dispatch(req)
    return self:_finish(self:_respond(req, res.status, res.body, res.headers, {
        content_type = res.content_type,
    }))
end

function Server:handle(raw, src)
    local ok, res = xpcall(function() return self:_handle(raw, src) end, trace)
    if not ok then
        self.stats.errors = self.stats.errors + 1
        self:_log("ERROR", "unhandled: " .. tostring(res))
        local fallback = self.common.build_response(500, nil, "Internal Server Error", {
            server_name = self.opts.server_name,
        })
        local fok, sealed = pcall(self._finish, self, fallback)
        if fok and sealed then return sealed end
        return fallback
    end
    return res
end

function Server:stop()
    if self.stopped then return end
    self.stopped = true
    local listener = self.listener
    if listener then
        if type(listener) == "table" and listener.close then
            pcall(listener.close, listener)
        elseif type(listener) == "function" then
            pcall(listener)
        end
    end
    self.listener = nil
    local transport = self.opts.transport
    if type(transport) == "table" and transport.unbind then
        pcall(transport.unbind, transport)
    end
    if M.current == self then M.current = nil end
    self:_log("INFO", "server stopped port=" .. tostring(self.port))
end

function Server:get_stats()
    local by_status = {}
    for code, count in pairs(self.stats.by_status) do by_status[code] = count end
    return {
        requests = self.stats.requests,
        errors = self.stats.errors,
        rejected = self.stats.rejected,
        by_status = by_status,
    }
end

function M.new(port, routes, opts)
    local opts = opts or {}
    local common = opts.common or get_common()
    if not common then return nil, "http_common module not found" end
    local newport = tonumber(port or common.DEFAULT_PORT)
    if not newport or newport < 0 or newport > 65535 then return nil, "invalid port" end
    if type(routes) ~= "table" then return nil, "routes must be a table" end

    local self = setmetatable({
        port = newport,
        routes = routes,
        opts = opts,
        common = common,
        stats = { requests = 0, errors = 0, rejected = 0, by_status = {} },
        stopped = false,
    }, Server)
    self:_index_routes()

    local transport = self.opts.transport
    if transport then
        local on_data = function(data, reply, src)
            local response = self:handle(data, src)
            if type(reply) == "function" then
                pcall(reply, response)
            end
            return response
        end
        local listener
        if type(transport) == "function" then
            listener = transport(newport, on_data)
        elseif type(transport) == "table" then
            local bind = transport.bind or transport.listen
            if type(bind) ~= "function" then return nil, "transport has no bind" end
            listener = bind(transport, newport, on_data)
        else
            return nil, "bad transport"
        end
        if listener == nil then return nil, "transport bind failed" end
        self.listener = listener
    end

    self:_log("INFO", "server started port=" .. tostring(newport))
    return self
end

function M.start(port, routes, opts)
    local server, err = M.new(port, routes, opts)
    if not server then return nil, err end
    M.current = server
    return server
end

function M.stop()
    if M.current then M.current:stop() end
end

function M.handle(raw, src)
    if not M.current then
        local common = get_common()
        if common then
            return common.build_response(500, nil, "server not started", { server_name = false })
        end
        return nil
    end
    return M.current:handle(raw, src)
end

return M
