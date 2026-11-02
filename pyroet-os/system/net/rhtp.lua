--[[- pyroet-os/net/rhtp.lua -- RHTP/1.0 client over the rpv UDP stack.

RHTP is the project's own datagram request/response protocol (rpv1
apps/rhtp_server.lua is the reference server): one request datagram in, one
response datagram out, no keep-alive, no pipelining:

    request   GET <path>
    response  RHTP/1.0 <code> <reason>\r\n<[headers>\r\n]\r\n<body>

Client API:

    local R = dofile("/system/net/rhtp.lua")
    local c = R.new{ node = node, log = print }
    local code, body = c:get("rhtp://store.pyrotechnic.org/index.txt")
    local ok, text   = c:fetch("rhtp://store.pyrotechnic.org/pkg/files.txt", size,
                               { progress = function(done, total) end })

* R.new{node=, log=, timeout=, port=, max_bytes=, host=, pump=, clock=,
  client_port=, debug=, rpv=, dns=, fs=, dns_server=, dns_gateway=,
  dns_cache=, dns_config_path=, dns_module=, secret=, secure=, rand=}. `node`
  is an rpv node (node.bind / node.lookup).
  `timeout` defaults to 3 s, `port` (the server port used for a bare "/path"
  target) to 8080, `max_bytes` to 4096 (the fetch chunk size), `debug=false`
  suppresses RHTP_RESOLVE only. `pump(seconds)` is the host's node pump; it
  defaults to `node:pump` when the node has one. `clock` defaults to os.clock.
  `dns` is a resolver object (an `R`-free table with query/resolve) or a
  module with `new`; `dns=false` turns the DNS stage off. Without one the
  module loads `/system/net/dns.lua` lazily, and the `dns_*` keys are handed
  to `dns.new` (the net service passes its already parsed `/etc/network.conf`
  values, so there is exactly one config parser per process).
  Sealing (DECISIONS.md 44): `secret` is a 64-hex PSK, `secure` is a prebuilt
  net/rhtp_secure.lua object (when both are given `secure` wins). With a
  working secure object every request starts with a fresh 8-byte random nonce
  (a `Rhtp-Seal: 1 <nonce>` marker is added to the request line) and the
  response must be a sealed envelope, else the call fails closed
  (`nil, "seal required"` / `nil, "seal bad"`). `rand(n)` overrides the nonce
  source (default: the secure object's own crypto.random_bytes). Without a
  secret/secure object the client behaves exactly as before (plaintext).
* R.parse_url(url) -> {scheme="rhtp", host=, port=, path=} | nil, reason.
  `rhtp://<host>[:<port>]/<path>`; a bare `<host>[:<port>]/<path>` is read as
  rhtp://. Any other explicit scheme is refused ("bad scheme") -- there is no
  silent http fallback anywhere in this module.
* c:get(url[, opts]) -> status, body | nil, reason. `status` is the numeric
  RHTP code and is only returned for a 2xx answer; 4xx/5xx is
  nil, "rhtp <code>". opts: {timeout=, offset=, length=, limit=}; offset and
  length add the chunk extension to the request, limit caps the body a single
  response may carry (default R.MAX_DATAGRAM). When sealing is enabled the
  response must be a sealed envelope: an unscaled answer to a sealed request
  is nil, "seal required", and a mismatched tag/nonce is nil, "seal bad".
* c:fetch(url, size[, opts]) -> true, body | nil, reason. With a numeric size
  the body is pulled in `max_bytes` chunks as `GET <path> off=<n> len=<n>`,
  expecting `206 Partial Content` with exactly that segment; a server that
  ignores the extension and answers 200 with the whole file is accepted as-is.
  opts.progress(done, total) is called after every chunk.
* c:resolve(host) -> ip (integer), dotted text | nil, "dns: unknown host".

Name resolution, in order: a dotted-decimal host is used directly; else
`node:lookup(host)` (nil in this image -- rpv/services.lua is not vendored);
else the static `node.hosts` table `net/hosts.lua` fills from
`/etc/hosts.conf`; else a real DNS QUERY through `net/dns.lua`, whose resolver
comes from `/etc/network.conf` (`dns=<ipv4>`, else `gateway`). A name none of
them can answer is nil, "dns: unknown host" plus RHTP_DNS_FAIL (with the dns
module's own reason, e.g. `err=dns: nxdomain`); RHTP_RESOLVE is the debug-only
success line and says which source answered (`source=hosts` / `source=dns`).

Paths: the URL path is never mapped onto the local file system, so there is no
dot-dot escape to defend against -- and the parser refuses one anyway. A
`?query` or `#fragment` suffix is stripped before the request is built (the
reference server ignores it too). Length <= 96 printable ASCII, no "//", no
"." or ".." segments, no backslash.

Transfer: the client binds a local UDP port (49152..65532 when the node exposes
its port table, else 0), sends one datagram and waits until `timeout` expires.
A reply is accepted from the resolved address only. Without a pump -- or on a
node whose pump cannot deliver -- the call still returns after the deadline
instead of spinning. Logs: RHTP_GET host= ip= path= code= bytes=, RHTP_TIMEOUT,
RHTP_BAD_RESPONSE, RHTP_CHUNK off= len=, RHTP_DNS_FAIL host=, RHTP_RESOLVE
host= ip=, RHTP_TOO_LARGE path= bytes= limit=, RHTP_SEND_FAIL.

Sealing: by default RHTP is plaintext -- no TLS and no signature; integrity
comes from the SHA-256 the caller checks (kernel/ota.lua for images, appstore's
SHA256.txt for packages), and DECISIONS.md section 44 records that boundary.
When the net service is configured with a `rhtp_secret` (64 hex), every request
carries a fresh random nonce and the response must be a PSK-sealed envelope
(ChaCha20 + HMAC16, net/rhtp_secure.lua); a sealed request facing an unscaled
answer fails closed. See R.new below for the `secret`/`secure`/`rand` keys.

No non-ASCII bytes in this file.
]]

local R = {}

-- net/dns.lua, loaded once per process on first use (nil = not available)
local DNS_MODULE

local function load_dns_module(fsx)
    if DNS_MODULE ~= nil then return DNS_MODULE end
    local candidates = { "/system/net/dns.lua", "system/net/dns.lua" }
    for i = 1, #candidates do
        local path = candidates[i]
        local exists = false
        if type(fsx) == "table" and type(fsx.exists) == "function" then
            local ok, found = pcall(fsx.exists, path)
            exists = ok and found == true
        end
        if exists then
            local ok, module = pcall(dofile, path)
            if ok and type(module) == "table" and type(module.new) == "function" then
                DNS_MODULE = module
                return module
            end
        end
    end
    return nil
end

R.VERSION = "1.0"
R.PREFIX = "RHTP/1.0"
R.DEFAULT_PORT = 8080
R.DEFAULT_TIMEOUT = 3
R.DEFAULT_CHUNK = 4096
R.MAX_URL = 160
R.MAX_PATH = 96
R.MAX_HOST = 64
R.MAX_DATAGRAM = 60000
R.MAX_PUMP_STEPS = 64
R.CLIENT_PORT_FIRST = 49152
R.CLIENT_PORT_LAST = 65532
R.CLIENT_PORT_SPAN = R.CLIENT_PORT_LAST - R.CLIENT_PORT_FIRST + 1
R.SEAL_MARKER = "Rhtp-Seal"
R.SEAL_REQUIRE = "seal required"

-- net/rhtp_secure.lua, loaded lazily on first secret use (nil = unavailable).
-- Same shape as net/dns.lua: a pure module cache, one module per process.
local SECURE_MODULE
local function load_rhtp_secure(fsx)
    if SECURE_MODULE ~= nil then return SECURE_MODULE end
    local candidates = { "/system/net/rhtp_secure.lua", "system/net/rhtp_secure.lua" }
    for i = 1, #candidates do
        local path = candidates[i]
        local exists = false
        if type(fsx) == "table" and type(fsx.exists) == "function" then
            local ok, found = pcall(fsx.exists, path)
            exists = ok and found == true
        end
        -- without a filesystem probe (headless / tests) still try to load the
        -- absolute path directly; it resolves in the same environment that
        -- loaded rhtp.lua itself
        if exists or fsx == nil then
            local ok, module = pcall(dofile, path)
            if ok and type(module) == "table" and type(module.new) == "function" then
                SECURE_MODULE = module
                return module
            end
        end
    end
    return nil
end

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 48
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

-- strict dotted decimal (no leading zeros, exactly four octets) -> integer
function R.parse_ip(text)
    if type(text) ~= "string" then return nil end
    local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    local parts = { a, b, c, d }
    local value = 0
    for i = 1, 4 do
        local part = parts[i]
        if #part > 3 then return nil end
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
        local octet = tonumber(part)
        if octet == nil or octet > 255 then return nil end
        value = value * 256 + octet
    end
    return value
end

function R.int2ip(value)
    local n = math.floor(tonumber(value) or 0)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

-- ---------------------------------------------------------------------------
-- URL parsing (pure)
-- ---------------------------------------------------------------------------

-- URL path -> normalized path, or nil, reason. The query string and fragment
-- are dropped: RHTP carries no query semantics and the reference server strips
-- them too, so there is exactly one spelling of a path on the wire.
function R.path_of(text)
    local path = tostring(text == nil and "" or text)
    if path == "" then return true, "/" end
    if path:sub(1, 1) ~= "/" then return nil, "bad path" end
    path = path:gsub("[?#].*$", "")
    if path == "" then path = "/" end
    if #path > R.MAX_PATH then return nil, "bad path" end
    for i = 1, #path do
        local byte = path:byte(i)
        if byte < 33 or byte > 126 then return nil, "bad path" end
    end
    if path:find("\\", 1, true) then return nil, "bad path" end
    if path:find("..", 1, true) then return nil, "bad path" end
    if path:find("//", 1, true) then return nil, "bad path" end
    for segment in (path .. "/"):gmatch("([^/]*)/") do
        if segment == "." or segment == ".." then return nil, "bad path" end
    end
    return true, path
end

function R.parse_url(url)
    if type(url) ~= "string" then return nil, "bad url" end
    local text = url:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "bad url" end
    if #text > R.MAX_URL then return nil, "bad url" end
    if text:find("%s") then return nil, "bad url" end
    local rest = text
    if text:sub(1, 7):lower() == "rhtp://" then
        rest = text:sub(8)
    elseif text:find("://", 1, true) then
        return nil, "bad scheme"
    end
    local hostpart, path = rest:match("^([^/]*)(.*)$")
    if hostpart == nil or hostpart == "" then return nil, "bad host" end
    local host, port_text = hostpart:match("^([^:]+):(%d+)$")
    if host == nil then host, port_text = hostpart, nil end
    if type(host) ~= "string" or host == "" or #host > R.MAX_HOST then
        return nil, "bad host"
    end
    if not host:match("^[%w%._%-]+$") then return nil, "bad host" end
    if host:sub(1, 1) == "." or host:sub(-1) == "." then return nil, "bad host" end
    local port = R.DEFAULT_PORT
    if port_text ~= nil then
        local number = tonumber(port_text)
        if not number or number ~= math.floor(number) or number < 1 or number > 65535 then
            return nil, "bad port"
        end
        port = number
    end
    local okpath, normalized = R.path_of(path)
    if not okpath then return nil, normalized end
    return { scheme = "rhtp", host = host:lower(), port = port, path = normalized }
end

-- ---------------------------------------------------------------------------
-- response parsing (pure)
-- ---------------------------------------------------------------------------

-- One response datagram -> code, body, headers | nil, reason. The status line
-- must be "RHTP/1.0 <3 digits>"; anything else is RHTP_BAD_RESPONSE upstream
-- (a 4xx/5xx with a valid status line is a readable "rhtp <code>", not this).
function R.parse_response(text)
    if type(text) ~= "string" or text == "" then return nil, "bad response" end
    local head, body = text:match("^(.-)\r?\n\r?\n(.*)$")
    if head == nil then return nil, "bad response" end
    local first = head:match("^([^\r\n]*)") or ""
    local version, code = first:match("^RHTP/(%d+%.%d+) (%d%d%d)")
    if not version then return nil, "bad response" end
    if version ~= "1.0" then return nil, "bad response" end
    local headers = {}
    for line in (head .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= first then
            local key, value = line:match("^([%w%-]+):[ \t]*(.*)$")
            if key then headers[key:lower()] = value end
        end
    end
    return tonumber(code), body, headers
end

-- ---------------------------------------------------------------------------
-- client
-- ---------------------------------------------------------------------------

function R.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = R })
    self.node = o.node
    self.sink = o.log
    self.logs = {}
    self.timeout = tonumber(o.timeout) or R.DEFAULT_TIMEOUT
    if self.timeout <= 0 then self.timeout = R.DEFAULT_TIMEOUT end
    self.port = tonumber(o.port) or R.DEFAULT_PORT
    self.max_bytes = tonumber(o.max_bytes) or R.DEFAULT_CHUNK
    if self.max_bytes < 1 then self.max_bytes = R.DEFAULT_CHUNK end
    self.host = o.host
    self.client_port = tonumber(o.client_port)
    self.debug = o.debug ~= false
    self.clock = o.clock or os.clock
    self.requests = 0
    self.bytes = 0
    self.failures = 0
    self.port_seq = 0
    self.pump = o.pump
    if self.pump == nil and type(self.node) == "table"
        and type(self.node.pump) == "function" then
        local node = self.node
        self.pump = function(seconds) return node:pump(seconds) end
    end
    -- name resolution stage 3: the DNS resolver. A caller may hand over a ready
    -- object, a module, or false (off); otherwise net/dns.lua is loaded lazily.
    self.dns = o.dns
    self.dns_disabled = (o.dns == false)
    self.dns_tried = false
    self.dns_module = o.dns_module
    if type(self.dns) == "table" and type(self.dns.query) ~= "function"
        and type(self.dns.resolve) ~= "function"
        and type(self.dns.new) == "function" then
        -- handed a module, not an object: build the object on first use
        self.dns_module = self.dns
        self.dns = nil
    end
    self.rpv = o.rpv
    self.fs = o.fs
    self.dns_server = o.dns_server
    self.dns_gateway = o.dns_gateway
    self.dns_cache = o.dns_cache
    self.dns_config_path = o.dns_config_path
    -- Sealing (DECISIONS.md 44): a prebuilt net/rhtp_secure.lua object, or a
    -- 64-hex PSK from which the net service builds one. `secure` wins over
    -- `secret`. rand(n) is the 8-byte per-request nonce source; it defaults to
    -- the secure object's crypto.random_bytes.
    self.secure = o.secure
    self.rand = o.rand
    if self.secure == nil and type(o.secret) == "string" then
        if #o.secret == 64 and o.secret:match("^[0-9a-fA-F]+$") ~= nil then
            local secure_lib = load_rhtp_secure(self.fs)
            if secure_lib then
                local ok, obj = pcall(secure_lib.new, { psk_hex = o.secret })
                if ok and type(obj) == "table" then self.secure = obj end
            end
        end
    end
    return self
end

-- the resolver object for this client, built at most once
function R:dns_client()
    if self.dns_disabled then return nil end
    if self.dns ~= nil then return self.dns end
    if self.dns_tried then return nil end
    self.dns_tried = true
    local mod = self.dns_module
    if mod == nil then mod = load_dns_module(self.fs) end
    if type(mod) ~= "table" then return nil end
    local client = self
    local ok, obj = pcall(mod.new, {
        node = self.node,
        rpv = self.rpv,
        fs = self.fs,
        clock = self.clock,
        pump = self.pump,
        config_path = self.dns_config_path,
        server = self.dns_server,
        gateway = self.dns_gateway,
        cache = self.dns_cache,
        log = function(line) client:log("%s", tostring(line)) end,
    })
    if not ok or type(obj) ~= "table" then return nil end
    self.dns = obj
    return obj
end

function R:now()
    if type(self.clock) == "function" then return self.clock() end
    return os.clock()
end

function R:log(fmt, ...)
    local line
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        line = ok and formatted or tostring(fmt)
    else
        line = tostring(fmt)
    end
    self.logs[#self.logs + 1] = line
    if type(self.sink) == "function" then
        local ok = pcall(self.sink, line)
        if not ok then self.sink = nil end
    end
    return line
end

-- dotted decimal first, node:lookup() second; nil, "dns: unknown host" when the
-- name cannot be turned into an address at all
function R:resolve(host)
    local name = tostring(host == nil and "" or host)
    local direct = R.parse_ip(name)
    if direct then
        if self.debug then
            self:log("RHTP_RESOLVE host=%s ip=%s direct=1", short(name, 40), name)
        end
        return direct, name
    end
    local node = self.node
    if type(node) ~= "table" then
        self:log("RHTP_DNS_FAIL host=%s err=no_node", short(name, 40))
        return nil, "dns: unknown host"
    end
    local address = nil
    if type(node.lookup) == "function" then
        local called, value = pcall(node.lookup, node, name)
        if called then
            if type(value) == "number" then
                address = math.floor(value)
            elseif type(value) == "string" then
                address = R.parse_ip(value)
            end
        end
    end
    -- rpv/services.lua is not vendored in this image, so node:lookup() answers
    -- nil; the static table net/hosts.lua fills from /etc/hosts.conf is consulted
    -- second (upstream lookup checks it first) so a configured name still
    -- resolves without the services module
    if address == nil and type(node.hosts) == "table" then
        local local_ip = node.hosts[name]
        if type(local_ip) == "number" then
            address = math.floor(local_ip)
        elseif type(local_ip) == "string" then
            address = R.parse_ip(local_ip)
        end
        if address then
            if self.debug then
                self:log("RHTP_RESOLVE host=%s ip=%s source=hosts",
                    short(name, 40), R.int2ip(address))
            end
            return address, R.int2ip(address)
        end
    end
    local dns_why = nil
    if address == nil then
        -- third source: a real DNS QUERY. rpv/services.lua is not vendored in
        -- this image, so node:lookup() above answers nil; net/dns.lua sends the
        -- query itself (resolver from /etc/network.conf: dns=, else gateway)
        local resolver = self:dns_client()
        if resolver ~= nil then
            local query = resolver.query or resolver.resolve
            if type(query) == "function" then
                local called, value, why = pcall(query, resolver, name)
                if called then
                    if type(value) == "number" then
                        address = math.floor(value)
                    elseif type(value) == "string" then
                        address = R.parse_ip(value)
                    end
                end
                if address then
                    if self.debug then
                        self:log("RHTP_RESOLVE host=%s ip=%s source=dns",
                            short(name, 40), R.int2ip(address))
                    end
                    return address, R.int2ip(address)
                end
                dns_why = why
            end
        end
    end
    if address == nil then
        self:log("RHTP_DNS_FAIL host=%s err=%s", short(name, 40),
            short(type(dns_why) == "string" and dns_why or "lookup", 32))
        return nil, "dns: unknown host"
    end
    if self.debug then
        self:log("RHTP_RESOLVE host=%s ip=%s", short(name, 40), R.int2ip(address))
    end
    return address, R.int2ip(address)
end

-- bind a local socket for one request; a real node exposes node.udp.ports, so
-- the ephemeral range is scanned for a free port (a stub node without it gets
-- port 0, which its own fake transport defines)
function R:bind(handler)
    local node = self.node
    if type(node) ~= "table" or type(node.bind) ~= "function" then
        return nil, nil, "no network"
    end
    local ports = nil
    if type(node.udp) == "table" and type(node.udp.ports) == "table" then
        ports = node.udp.ports
    end
    self.port_seq = (self.port_seq or 0) + 1
    local tries = ports and 32 or 1
    for step = 0, tries - 1 do
        local port = 0
        if ports then
            local offset = (self.port_seq * 7 + step) % R.CLIENT_PORT_SPAN
            port = R.CLIENT_PORT_FIRST + offset
            if self.client_port then port = self.client_port + step end
            if ports[port] ~= nil then port = nil end
        end
        if port ~= nil then
            local called, socket = pcall(node.bind, node, port, handler)
            if called and type(socket) == "table" then return socket, port end
        end
    end
    return nil, nil, "bind failed"
end

-- one request datagram -> raw response text; the deadline is observed even when
-- the host has no pump, and a stray/unparsable packet is the caller's problem
function R:exchange(ip, port, request, timeout)
    local reply = nil
    local handler = function(data)
        if reply == nil then reply = tostring(data == nil and "" or data) end
    end
    local sock, bound, err = self:bind(handler)
    if not sock then return nil, err or "bind failed" end
    self.requests = self.requests + 1
    local called, sent = pcall(sock.sendto, sock, ip, port, request, 64)
    if not called or sent == false then
        pcall(sock.close, sock)
        self.failures = self.failures + 1
        self:log("RHTP_SEND_FAIL ip=%s port=%d bytes=%d",
            R.int2ip(ip), math.floor(port), #request)
        return nil, "send failed"
    end
    local wait = tonumber(timeout) or self.timeout
    if wait <= 0 then wait = self.timeout end
    local deadline = self:now() + wait
    local steps = 0
    while reply == nil do
        local left = deadline - self:now()
        if left <= 0 then break end
        if self.pump == nil then break end
        steps = steps + 1
        if steps > R.MAX_PUMP_STEPS then break end
        if not pcall(self.pump, left) then break end
    end
    pcall(sock.close, sock)
    if reply == nil then
        self.failures = self.failures + 1
        self:log("RHTP_TIMEOUT ip=%s port=%d local=%s after=%.2fs",
            R.int2ip(ip), math.floor(port), tostring(bound), wait)
        return nil, "timeout"
    end
    self.bytes = self.bytes + #reply
    return reply
end

function R:url_of(target)
    if type(target) == "table" and type(target.host) == "string" then return target end
    if type(target) ~= "string" then return nil end
    if target:sub(1, 1) == "/" then
        local okpath, path = R.path_of(target)
        if not okpath then return nil end
        if type(self.host) ~= "string" or self.host == "" then return nil end
        return { scheme = "rhtp", host = self.host:lower(), port = self.port,
            path = path }
    end
    return R.parse_url(target)
end

-- One fresh 8-byte random nonce for a sealed request (DECISIONS.md 44). Uses
-- `rand(8)` when injected, else the secure object's crypto.random_bytes. The
-- source must return exactly 8 bytes to bound the ChaCha20 nonce.
function R:nonce()
    if not self.secure then return nil end
    if type(self.rand) == "function" then
        local n = self.rand(8)
        if type(n) == "string" and #n == 8 then return n end
    end
    if type(self.secure.crypto) == "table"
        and type(self.secure.crypto.random_bytes) == "function" then
        return self.secure.crypto.random_bytes(8)
    end
    return nil
end

-- Seal handling for one response text. Given the request nonce, opens the
-- envelope: a matching seal -> code, body; an unscaled answer to a sealed
-- request -> nil, R.SEAL_REQUIRE (fail closed, DECISIONS.md 44); a mismatch ->
-- nil, "seal bad". Honors a pre-negotiated `soft` mode that returns a nil code
-- with the plain response body so the caller can log the failure.
function R:open_response(text, bin_nonce)
    if not self.secure then
        return R.parse_response(text)
    end
    local code, body = self.secure:open(text, bin_nonce)
    if code ~= nil then return code, body end
    if body == "plain" then return nil, R.SEAL_REQUIRE end
    return nil, body
end

-- GET one path. Returns status, body for a 2xx answer; nil, reason otherwise.
function R:get(target, opts)
    local o = opts or {}
    local url = self:url_of(target)
    if not url then
        self.failures = self.failures + 1
        return nil, "bad url"
    end
    local ip, ip_text = self:resolve(url.host)
    if not ip then return nil, "dns: unknown host" end
    local request = "GET " .. url.path
    if o.offset ~= nil or o.length ~= nil then
        local offset = math.floor(tonumber(o.offset) or -1)
        local length = math.floor(tonumber(o.length) or -1)
        if offset < 0 or length < 1 then
            self.failures = self.failures + 1
            return nil, "bad range"
        end
        request = request .. " off=" .. tostring(offset) .. " len=" .. tostring(length)
    end
    -- Sealing (DECISIONS.md 44): one fresh nonce per request, echoed in the
    -- response envelope. The marker keeps `GET <path>` as the first two tokens
    -- (the reference server's parse_request reads only those) and carries the
    -- 16-hex nonce as an extra token the server binds into the tag.
    local bin_nonce = nil
    if self.secure then
        bin_nonce = self:nonce()
        if not bin_nonce then
            self.failures = self.failures + 1
            self:log("RHTP_SEAL_FRAMING path=%s err=no nonce source", short(url.path, 40))
            return nil, "bad nonce"
        end
        request = request .. " " .. R.SEAL_MARKER .. ": 1 " .. self.secure.crypto.hex(bin_nonce)
    end
    local text, err = self:exchange(ip, url.port, request, o.timeout)
    if not text then return nil, err end
    local code, body = self:open_response(text, bin_nonce)
    if not code then
        self.failures = self.failures + 1
        if body == R.SEAL_REQUIRE then
            self:log("RHTP_SEAL_REQUIRED host=%s path=%s bytes=%d",
                short(url.host, 40), short(url.path, 40), #text)
        elseif body == "seal bad" then
            self:log("RHTP_SEAL_BAD host=%s path=%s bytes=%d",
                short(url.host, 40), short(url.path, 40), #text)
        else
            self:log("RHTP_BAD_RESPONSE host=%s path=%s bytes=%d",
                short(url.host, 40), short(url.path, 40), #text)
        end
        return nil, body
    end
    local sealed = self.secure ~= nil
    self:log("RHTP_GET host=%s ip=%s path=%s code=%d bytes=%d sealed=%s",
        short(url.host, 40), short(ip_text, 16), short(url.path, 64),
        code, #body, sealed and "1" or "0")
    if code < 200 or code > 299 then
        self.failures = self.failures + 1
        self:log("RHTP_STATUS host=%s path=%s code=%d",
            short(url.host, 40), short(url.path, 40), code)
        return nil, "rhtp " .. tostring(code)
    end
    local limit = tonumber(o.limit) or R.MAX_DATAGRAM
    if #body > limit then
        self.failures = self.failures + 1
        self:log("RHTP_TOO_LARGE path=%s bytes=%d limit=%d",
            short(url.path, 40), #body, math.floor(limit))
        return nil, "too large"
    end
    return code, body
end

-- Fetch a whole body. With a numeric size the chunk extension is used; a 200
-- answer to a ranged request means the server ignores `off/len`, and its full
-- body is the answer (the caller still verifies size and digest).
function R:fetch(target, size, opts)
    local o = opts or {}
    local url = self:url_of(target)
    if not url then
        self.failures = self.failures + 1
        return nil, "bad url"
    end
    local total = tonumber(size)
    if total ~= nil then total = math.floor(total) end
    local progress = o.progress
    if total == nil or total <= 0 then
        local code, body = self:get(url, o)
        if not code then return nil, body end
        if type(progress) == "function" then pcall(progress, #body, #body) end
        return true, body
    end
    local chunk = math.floor(tonumber(o.max_bytes) or self.max_bytes)
    if chunk < 1 then chunk = self.max_bytes end
    local parts, done = {}, 0
    while done < total do
        local want = math.min(chunk, total - done)
        -- the per-response cap stays at the default here: a server that
        -- ignores off/len answers 200 with the WHOLE body, which is longer than
        -- the chunk that was asked for
        local code, body = self:get(url, {
            offset = done, length = want, timeout = o.timeout, limit = o.limit,
        })
        if not code then return nil, body end
        self:log("RHTP_CHUNK off=%d len=%d code=%d bytes=%d",
            done, want, code, #body)
        if code == 200 then
            -- full body: no point asking for more, and a size mismatch is a
            -- failure the caller must not have to discover by hashing
            if #body ~= total then
                return nil, "size " .. tostring(#body) .. "/" .. tostring(total)
            end
            parts = { body }
            done = #body
        else
            if #body ~= want then
                return nil, "bad chunk " .. tostring(#body) .. "/" .. tostring(want)
            end
            parts[#parts + 1] = body
            done = done + #body
        end
        if type(progress) == "function" then pcall(progress, done, total) end
    end
    local body = table.concat(parts)
    if #body ~= total then
        return nil, "size " .. tostring(#body) .. "/" .. tostring(total)
    end
    return true, body
end

function R:status()
    return {
        requests = self.requests, bytes = self.bytes, failures = self.failures,
        timeout = self.timeout, port = self.port, max_bytes = self.max_bytes,
    }
end

return R
