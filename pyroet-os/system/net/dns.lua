--[[- pyroet-os/net/dns.lua -- the resolver the RHTP client actually uses.

The rpv subset vendored in this image has no `services.lua`, so `node:lookup()`
answers nil and the only name source used to be the static table `net/hosts.lua`
fills from `/etc/hosts.conf`. This module closes that gap: it builds a real DNS
QUERY and sends it over the same node, so `store.pyrotechnic.org` resolves
without a hosts file.

Wire format (RFC 1035, the subset a resolver needs):

    header    id(u16) flags(u16) qd(u16) an(u16) ns(u16) ar(u16)
    question  <labels> 0  QTYPE(u16=1)  QCLASS(u16=1)
    answer    <name> TYPE(u16) CLASS(u16) TTL(u32) RDLEN(u16) RDATA

The query is sent with RD=1 (recursion desired), one question, no additional
records. The response must echo the id and set QR=1; `RCODE=3` is NXDOMAIN.
Only the ANSWER section is read, and only the first A record (type 1, class 1,
RDLEN 4) is returned. Compression pointers (the two high bits set, offset in the
low 14 bits) are followed with a hard jump budget, so a pointer loop is a bad
packet instead of an infinite loop.

Transport: the node's UDP socket API. A local ephemeral port is bound for the
exchange (`node:bind(port)`), the datagram is sent with `rpv.udp_send` when the
rpv table was supplied (else the socket's own `sendto`, which is the same call),
and the wait drives `node:pump` when the node has one, exactly like the RHTP
client does. Without a pump the wait ends at the deadline instead of spinning.

Resolver address, in order:
  1. `/etc/network.conf` key `dns=<ipv4>` (validated; `dns=0` means "no cache",
     and the resolver then falls back to the gateway);
  2. the same file's `gateway=<ipv4>`;
  3. nothing -- `nil, "dns: no dns"`, no packet is sent.

Retry: `tries` (default 2) attempts, `timeout` (default 1 s) each. A positive
answer is cached for `min(ttl, 60)` seconds (`cache = false` or `dns=0` turns
the cache off); NXDOMAIN and every other failure is never cached.

Logs: DNS_QUERY host=.. server=.., DNS_ANSWER host=.. ip=.. ttl=..,
DNS_TIMEOUT host=.. server=.. tries=.., DNS_NXDOMAIN host=.. server=..,
DNS_BAD_PACKET host=.. err=.., DNS_CONFIG_BAD key=dns value=..

Usage:

    local dns = dofile("/system/net/dns.lua")
    local r = dns.new({ node = node, log = print })
    local ip, ip_text = r:query("store.pyrotechnic.org")   -- nil, "dns: nxdomain"

No non-ASCII bytes in this file.
]]

local D = {}

D.VERSION = "1.0"
D.PORT = 53
D.DEFAULT_CONFIG = "/etc/network.conf"
D.DEFAULT_TIMEOUT = 1
D.DEFAULT_TRIES = 2
D.MAX_TTL = 60
D.MAX_NAME = 253
D.MAX_LABEL = 63
D.MAX_JUMPS = 8
D.MAX_PACKET = 512
D.MAX_PUMP_STEPS = 32
D.CLIENT_PORT_FIRST = 49152
D.CLIENT_PORT_LAST = 65532
D.CLIENT_PORT_SPAN = D.CLIENT_PORT_LAST - D.CLIENT_PORT_FIRST + 1

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 40
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function u16(n)
    n = math.floor(tonumber(n) or 0) % 65536
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function u32(n)
    n = math.floor(tonumber(n) or 0) % 4294967296
    return string.char(math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function r16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    if a == nil or b == nil then return nil end
    return a * 256 + b
end

local function r32(s, pos)
    local a, b, c, d = s:byte(pos, pos + 3)
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- strict dotted decimal (no leading zeros, exactly four octets) -> integer
function D.parse_ip(text)
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

function D.int2ip(value)
    local n = math.floor(tonumber(value) or 0)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

-- ---------------------------------------------------------------------------
-- name encoding / packet building (pure)
-- ---------------------------------------------------------------------------

-- "Store.PyroTechnic.ORG" -> "\5Store\12PyroTechnic\3ORG\0" (lower-cased labels).
-- Rejects empty labels ("..", a leading or trailing dot), labels over 63 bytes,
-- names over 253 bytes and anything outside [a-z0-9-_].
function D.encode_name(name)
    if type(name) ~= "string" then return nil, "bad name" end
    if name == "" or #name > D.MAX_NAME then return nil, "bad name" end
    if name:sub(1, 1) == "." or name:sub(-1) == "." then return nil, "bad name" end
    if name:find("..", 1, true) then return nil, "bad name" end
    local labels, wire, total = {}, {}, 0
    local lower = name:lower()
    for label in (lower .. "."):gmatch("([^.]*)%.") do
        if label == "" or #label > D.MAX_LABEL then return nil, "bad name" end
        if not label:match("^[%w_%-]+$") then return nil, "bad name" end
        labels[#labels + 1] = label
        wire[#wire + 1] = string.char(#label) .. label
        total = total + #label + 1
    end
    if #labels == 0 then return nil, "bad name" end
    -- the wire name is the sum of the labels plus the root label; DNS allows 255
    if total + 1 > 255 then return nil, "bad name" end
    wire[#wire + 1] = "\0"
    return table.concat(wire)
end

-- RD=1, one question, QTYPE=A, QCLASS=IN
function D.build_query(name, id)
    local wire, err = D.encode_name(name)
    if not wire then return nil, err end
    return u16(id) .. u16(0x0100) .. u16(1) .. u16(0) .. u16(0) .. u16(0)
        .. wire .. u16(1) .. u16(1)
end

-- read past a (possibly compressed) name; returns the offset just past the name
-- or nil, reason. A pointer is followed, but never more than MAX_JUMPS times:
-- a pointer loop is a bad packet, not a hang.
function D.name_end(packet, pos)
    local jumps, cursor, result = 0, tonumber(pos), nil
    local steps = 0
    while true do
        steps = steps + 1
        if steps > 256 then return nil, "bad packet" end
        local b = packet:byte(cursor)
        if b == nil then return nil, "bad packet" end
        if b == 0 then
            if result ~= nil then return result end
            return cursor + 1
        elseif b >= 192 then
            local b2 = packet:byte(cursor + 1)
            if b2 == nil then return nil, "bad packet" end
            jumps = jumps + 1
            if jumps > D.MAX_JUMPS then return nil, "bad packet" end
            if result == nil then result = cursor + 2 end
            local target = (b - 192) * 256 + b2 + 1
            if target < 13 or target > #packet then return nil, "bad packet" end
            cursor = target
        elseif b > 63 then
            return nil, "bad packet"
        else
            cursor = cursor + b + 1
            if cursor > #packet + 1 then return nil, "bad packet" end
        end
    end
end

-- response -> ip, ttl, nil | nil, nil, reason. Reasons: "bad id", "truncated",
-- "bad packet", "rcode <n>", "no answer", "nxdomain" (RCODE 3).
function D.parse_response(packet, id)
    if type(packet) ~= "string" or #packet < 12 then return nil, nil, "bad packet" end
    local got = r16(packet, 1)
    if id ~= nil and got ~= id then return nil, nil, "bad id" end
    local flags = r16(packet, 3)
    if flags == nil then return nil, nil, "bad packet" end
    local qr = math.floor(flags / 32768) % 2
    local opcode = math.floor(flags / 2048) % 16
    local truncated = math.floor(flags / 512) % 2
    local rcode = flags % 16
    if qr ~= 1 then return nil, nil, "bad packet" end
    if opcode ~= 0 then return nil, nil, "bad packet" end
    if truncated == 1 then return nil, nil, "truncated" end
    if rcode == 3 then return nil, nil, "nxdomain" end
    if rcode ~= 0 then return nil, nil, "rcode " .. tostring(rcode) end
    local qd = r16(packet, 5) or 0
    local an = r16(packet, 7) or 0
    local pos = 13
    for _ = 1, qd do
        local next_pos, err = D.name_end(packet, pos)
        if not next_pos then return nil, nil, err end
        pos = next_pos + 4
        if pos > #packet + 1 then return nil, nil, "bad packet" end
    end
    for _ = 1, an do
        local next_pos, err = D.name_end(packet, pos)
        if not next_pos then return nil, nil, err end
        pos = next_pos
        if pos + 9 > #packet then return nil, nil, "bad packet" end
        local rtype = r16(packet, pos)
        local rclass = r16(packet, pos + 2)
        local ttl = r32(packet, pos + 4)
        local rdlen = r16(packet, pos + 8)
        pos = pos + 10
        if rtype == nil or rclass == nil or ttl == nil or rdlen == nil then
            return nil, nil, "bad packet"
        end
        if pos + rdlen - 1 > #packet then return nil, nil, "bad packet" end
        if rtype == 1 and rclass == 1 then
            if rdlen ~= 4 then return nil, nil, "bad packet" end
            local a, b, c, d = packet:byte(pos, pos + 3)
            return ((a * 256 + b) * 256 + c) * 256 + d, ttl, nil
        end
        pos = pos + rdlen
    end
    return nil, nil, "no answer"
end

-- `dns=` / `gateway=` out of a network.conf text (lenient: only those two keys
-- matter here, unknown lines are the net service's business)
function D.config_values(text)
    local cfg = {}
    if type(text) ~= "string" then return cfg end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local clean = line:gsub("#.*$", ""):gsub("^[ \t]+", ""):gsub("[ \t\r]+$", "")
        if clean ~= "" then
            local key, value = clean:match("^([%w_]+)[ \t]*=[ \t]*(.*)$")
            if key == "dns" or key == "gateway" then cfg[key] = value end
        end
    end
    return cfg
end

-- ---------------------------------------------------------------------------
-- resolver object
-- ---------------------------------------------------------------------------

function D.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = D })
    self.node = o.node
    self.rpv = o.rpv
    self.sink = o.log
    self.logs = {}
    self.clock = o.clock
    self.fs = o.fs or rawget(_G, "fs")
    self.config_path = o.config_path or D.DEFAULT_CONFIG
    self.config_text = o.config
    self.cfg = nil
    self.resolved = false
    self.server = nil
    self.server_text = nil
    if o.server ~= nil then
        self.server = tonumber(o.server) or D.parse_ip(o.server)
        if self.server then
            self.server = math.floor(self.server)
            self.server_text = D.int2ip(self.server)
        else
            self:log("DNS_CONFIG_BAD key=dns value=%s", short(o.server, 24))
        end
    end
    if o.gateway ~= nil then
        self.gateway = tonumber(o.gateway) or D.parse_ip(o.gateway)
    end
    self.cache_enabled = o.cache ~= false
    self.timeout = tonumber(o.timeout) or D.DEFAULT_TIMEOUT
    if self.timeout <= 0 then self.timeout = D.DEFAULT_TIMEOUT end
    self.tries = math.floor(tonumber(o.tries) or D.DEFAULT_TRIES)
    if self.tries < 1 then self.tries = 1 end
    if self.tries > 4 then self.tries = 4 end
    self.max_ttl = math.floor(tonumber(o.max_ttl) or D.MAX_TTL)
    if self.max_ttl < 1 then self.max_ttl = 1 end
    self.pump = o.pump
    if self.pump == nil and type(self.node) == "table"
        and type(self.node.pump) == "function" then
        local node = self.node
        self.pump = function(seconds) return node:pump(seconds) end
    end
    self.bind_port = tonumber(o.client_port)
    self.port_seq = tonumber(o.port_seq) or 0
    self.id = math.floor(tonumber(o.id_start) or 0) % 65536
    self.cache = {}
    self.queries = 0
    self.answers = 0
    self.timeouts = 0
    self.nxdomain = 0
    self.bad = 0
    self.cache_hits = 0
    return self
end

function D:now()
    if type(self.clock) == "function" then return self.clock() end
    return os.clock()
end

function D:log(fmt, ...)
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

function D:read_config()
    if self.cfg ~= nil then return self.cfg end
    local text = self.config_text
    if text == nil then
        local fsx = self.fs
        if type(fsx) ~= "table" or type(fsx.exists) ~= "function" then return nil end
        local ok, exists = pcall(fsx.exists, self.config_path)
        if not ok or not exists then return nil end
        local opened, handle = pcall(fsx.open, self.config_path, "r")
        if not opened or type(handle) ~= "table" then return nil end
        if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
        pcall(handle.close, handle)
    end
    if type(text) ~= "string" then return nil end
    self.cfg = D.config_values(text)
    return self.cfg
end

-- the resolver address, or nil, "no dns". `dns=0` only turns the cache off.
function D:resolver()
    if self.server then return self.server, self.server_text end
    if self.resolved then return nil, "no dns" end
    self.resolved = true
    local cfg = self:read_config()
    if cfg then
        local text = cfg.dns
        if text ~= nil and text ~= "" then
            if text == "0" then
                self.cache_enabled = false
            else
                local ip = D.parse_ip(text)
                if ip then
                    self.server = ip
                    self.server_text = D.int2ip(ip)
                    return self.server, self.server_text
                end
                self:log("DNS_CONFIG_BAD key=dns value=%s", short(text, 24))
            end
        end
    end
    local gw = self.gateway
    if gw == nil and cfg and cfg.gateway ~= nil and cfg.gateway ~= "" then
        gw = D.parse_ip(cfg.gateway)
    end
    if gw then
        self.server = math.floor(gw)
        self.server_text = D.int2ip(self.server)
        return self.server, self.server_text
    end
    return nil, "no dns"
end

function D:cache_get(name)
    if not self.cache_enabled then return nil end
    local hit = self.cache[name]
    if hit == nil then return nil end
    if hit.expires > self:now() then return hit end
    self.cache[name] = nil
    return nil
end

function D:cache_put(name, ip, ttl)
    local capped = math.floor(tonumber(ttl) or 0)
    if capped < 0 then capped = 0 end
    if capped > self.max_ttl then capped = self.max_ttl end
    if not self.cache_enabled or capped <= 0 then return capped end
    self.cache[name] = { ip = ip, ttl = capped, expires = self:now() + capped }
    return capped
end

function D:cache_size()
    local n = 0
    for _ in pairs(self.cache) do n = n + 1 end
    return n
end

function D:stats()
    return {
        queries = self.queries, answers = self.answers, timeouts = self.timeouts,
        nxdomain = self.nxdomain, bad = self.bad, cache_hits = self.cache_hits,
        cached = self:cache_size(), server = self.server_text,
        cache_enabled = self.cache_enabled,
    }
end

-- one ephemeral local port (a node without a port table gets port 0)
function D:bind(handler)
    local node = self.node
    if type(node) ~= "table" or type(node.bind) ~= "function" then
        return nil, nil, "no network"
    end
    local ports = nil
    if type(node.udp) == "table" and type(node.udp.ports) == "table" then
        ports = node.udp.ports
    end
    self.port_seq = self.port_seq + 1
    local tries = ports and 32 or 1
    for step = 0, tries - 1 do
        local port = 0
        if ports then
            local offset = (self.port_seq * 11 + step) % D.CLIENT_PORT_SPAN
            port = D.CLIENT_PORT_FIRST + offset
            if self.bind_port then port = self.bind_port + step end
            if ports[port] ~= nil then port = nil end
        end
        if port ~= nil then
            local ok, socket = pcall(node.bind, node, port, handler)
            if ok and type(socket) == "table" then return socket, port end
        end
    end
    return nil, nil, "bind failed"
end

function D:send(socket, port, server, packet)
    local rpv = self.rpv
    if type(rpv) == "table" and type(rpv.udp_send) == "function" then
        local ok, sent = pcall(rpv.udp_send, self.node, server, port, D.PORT,
            packet, 64)
        return ok and sent ~= false
    end
    if type(socket) ~= "table" or type(socket.sendto) ~= "function" then
        return false
    end
    local ok, sent = pcall(socket.sendto, socket, server, D.PORT, packet, 64)
    return ok and sent ~= false
end

-- one datagram out, one datagram back (or nil, reason). The deadline is
-- observed even on a node without a pump.
function D:exchange(server, packet)
    local reply = nil
    local handler = function(data)
        if reply == nil then reply = tostring(data == nil and "" or data) end
    end
    local socket, port, err = self:bind(handler)
    if not socket then return nil, err or "no network" end
    if not self:send(socket, port, server, packet) then
        pcall(socket.close, socket)
        return nil, "send failed"
    end
    local deadline = self:now() + self.timeout
    local steps = 0
    while reply == nil do
        local left = deadline - self:now()
        if left <= 0 then break end
        if self.pump == nil then break end
        steps = steps + 1
        if steps > D.MAX_PUMP_STEPS then break end
        if not pcall(self.pump, left) then break end
    end
    pcall(socket.close, socket)
    if reply == nil then return nil, "timeout" end
    return reply
end

-- host -> ip (integer), dotted text | nil, "dns: <reason>"
function D:query(host)
    local name = tostring(host == nil and "" or host)
    local key = name:lower()
    local wire, name_err = D.encode_name(name)
    if not wire then return nil, "dns: " .. tostring(name_err) end
    local hit = self:cache_get(key)
    if hit then
        self.cache_hits = self.cache_hits + 1
        return hit.ip, D.int2ip(hit.ip)
    end
    local server, why = self:resolver()
    if not server then return nil, "dns: " .. tostring(why) end
    local node = self.node
    if type(node) ~= "table" or type(node.bind) ~= "function" then
        return nil, "dns: no network"
    end
    self.queries = self.queries + 1
    self:log("DNS_QUERY host=%s server=%s", short(name, 40), self.server_text)
    local last = "timeout"
    for _ = 1, self.tries do
        self.id = (self.id + 1) % 65536
        local id = self.id
        local packet = D.build_query(name, id)
        local reply, send_err = self:exchange(server, packet)
        if reply == nil then
            if send_err ~= nil and send_err ~= "timeout" then
                return nil, "dns: " .. tostring(send_err)
            end
            last = "timeout"
        else
            local ip, ttl, reason = D.parse_response(reply, id)
            if ip then
                local capped = self:cache_put(key, ip, ttl)
                self.answers = self.answers + 1
                self:log("DNS_ANSWER host=%s ip=%s ttl=%d", short(name, 40),
                    D.int2ip(ip), capped)
                return ip, D.int2ip(ip)
            end
            if reason == "nxdomain" then
                self.nxdomain = self.nxdomain + 1
                self:log("DNS_NXDOMAIN host=%s server=%s", short(name, 40),
                    self.server_text)
                return nil, "dns: nxdomain"
            end
            self.bad = self.bad + 1
            self:log("DNS_BAD_PACKET host=%s err=%s", short(name, 40),
                short(reason, 24))
            last = "bad packet"
        end
    end
    if last == "timeout" then
        self.timeouts = self.timeouts + 1
        self:log("DNS_TIMEOUT host=%s server=%s tries=%d", short(name, 40),
            self.server_text, self.tries)
    end
    return nil, "dns: " .. last
end

-- the RHTP client's spelling of the same thing
function D:resolve(host)
    return self:query(host)
end

return D
