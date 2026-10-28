--[[- apps/rhtp_server.lua - RHTP/1.0 GET server for the rpv1 app layer.

RHTP is the tiny datagram HTTP-alike the InterTeamNet demos speak: one request
datagram in, one response datagram out, no keep-alive and no pipelining.

    local rhtp = ...                        -- loaded as apps/rhtp_server.lua
    local sk = rhtp.start_rhtp(node, 8080)  -- node:bind(8080, handler)

Routes (exact paths; a "?query" or "#fragment" suffix is stripped first):

    GET /                "Welcome to InterTeamNet"
    GET /api/dns_mirror  dns_db.txt with an X-DNS-Hash header (SHA-256 of the body)
    GET /api/directory   ip_directory.txt, or the built-in fallback directory
    anything else        404 Page Not Found

Replies leave through rpv.udp_send(node, src, port, sport, response): the source
port stays the listening port, the destination port is the requester's source
port. The routing runs inside pcall, so a malformed request or an internal error
answers "500 Server Error" for that one datagram and the socket keeps running.

The server holds no state, reads only the two mirror files (neither has to
exist) and is ASCII-only.
]]
local M = {}
M.VERSION = "1.0"
M.DEFAULT_PORT = 8080
M.DNS_DB = "dns_db.txt"
M.DIRECTORY = "ip_directory.txt"
M.FALLBACK_DIRECTORY = "root.server 172.16.1.2"

local NOT_FOUND = "RHTP/1.0 404 Not Found\r\n\r\nPage Not Found"
local DNS_NOT_FOUND = "RHTP/1.0 404 Not Found\r\n\r\nDNS DB Not Found"
local SERVER_ERROR = "RHTP/1.0 500 Internal Server Error\r\n\r\nServer Error"

-- tests/run.lua and node2/startup.lua load app files as chunk(rpv), so the
-- library table is usually available as the load-time vararg (start_rhtp also
-- takes it as an explicit third argument)
local ARGV = ...

-- ===== rpv library and sha256 ==============================================
local function usable(t)
    return type(t) == "table" and type(t.udp_send) == "function"
end

local RP = nil
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

-- rpv.sha256 comes from rpv/crypto.lua; when the library table is not reachable
-- the module is loaded directly (module files are `local M = ...`, so an empty
-- table is enough to own one instance)
local sha = nil
local function sha256(msg)
    if not sha then
        if type(RP) == "table" and type(RP.sha256) == "function" then sha = RP.sha256 end
        for _, path in ipairs({ "rpv/crypto.lua", "crypto.lua" }) do
            if not sha then
                local loaded, chunk = pcall(loadfile, path)
                if loaded and type(chunk) == "function" then
                    local ok, mod = pcall(chunk, {})
                    if ok and type(mod) == "table" and type(mod.sha256) == "function" then
                        sha = mod.sha256
                    end
                end
            end
        end
    end
    if not sha then error("rhtp_server: rpv.sha256 not available", 0) end
    return sha(msg)
end

-- ===== request parsing and routing =========================================
local function read_file(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local body = f.readAll()
    f.close()
    if body == nil then return nil end
    return tostring(body)
end

-- only the request line matters: "GET /path", CR/LF tolerant, lowercase
-- methods and junk before "GET" are not accepted
local function parse_request(data)
    local line = tostring(data or ""):match("^[^\r\n]*") or ""
    local method, target = line:match("^%s*(%u+)%s+(%S+)")
    if not method then return nil end
    return method, (target:gsub("[?#].*$", ""))
end

local function route(data)
    local method, path = parse_request(data)
    if method ~= "GET" or not path then return NOT_FOUND end
    if path == "/" then
        return "RHTP/1.0 200 OK\r\n\r\nWelcome to InterTeamNet"
    end
    if path == "/api/dns_mirror" then
        local body = read_file(M.DNS_DB)
        if not body then return DNS_NOT_FOUND end
        return "RHTP/1.0 200 OK\r\nX-DNS-Hash: " .. sha256(body) .. "\r\n\r\n" .. body
    end
    if path == "/api/directory" then
        local body = read_file(M.DIRECTORY)
        if not body then body = M.FALLBACK_DIRECTORY end
        return "RHTP/1.0 200 OK\r\n\r\n" .. body
    end
    return NOT_FOUND
end

-- one request datagram -> one response datagram; never throws, an error inside
-- the routing becomes the 500 response (log is the optional node:log wrapper)
function M.handle_request(data, log)
    local ok, response = pcall(route, data)
    if not ok then
        if type(log) == "function" then log("RHTP_ERROR %s", tostring(response)) end
        return SERVER_ERROR
    end
    if type(response) ~= "string" then return SERVER_ERROR end
    return response
end

-- ===== socket server ======================================================
-- start_rhtp(node, port[, rpv]) -> socket. Without the library table the reply
-- falls back to the socket's own sendto(), which calls rpv.udp_send internally.
function M.start_rhtp(node, port, rpv_lib)
    local bind_port = tonumber(port) or M.DEFAULT_PORT
    RP = RP or resolve_rpv(rpv_lib)

    local function log(fmt, ...)
        if type(node.log) == "function" then node:log(fmt, ...) end
    end

    local sock
    sock = node:bind(bind_port, function(data, src, sport)
        local response = M.handle_request(data, log)
        local ok, err
        if RP then
            ok, err = pcall(RP.udp_send, node, src, bind_port, sport, response)
        else
            ok, err = pcall(sock.sendto, sock, src, sport, response)
        end
        if not ok then log("RHTP_SEND_FAIL err=%s", tostring(err)) end
        log("RHTP_REQ sport=%s status=\"%s\" bytes=%d", tostring(sport),
            tostring(response:match("^[^\r\n]*")), #response)
    end)

    log("RHTP_START port=%d lib=%s", bind_port, tostring(RP ~= nil))
    return sock
end

-- app-loader form (node2/startup.lua): app=rhtp_server:8080
function M.new(o)
    local opts = o or {}
    local self = { rpv = opts.rpv, node = opts.node, port = tonumber(opts.args) or M.DEFAULT_PORT, sock = nil }
    self.start = function()
        self.sock = M.start_rhtp(self.node, self.port, self.rpv)
        return self.sock ~= nil
    end
    return self
end

return M
