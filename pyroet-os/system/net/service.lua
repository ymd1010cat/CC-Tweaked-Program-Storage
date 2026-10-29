--[[- pyroet-os/net/service.lua -- the Pyroet OS network service.

Registered in the kernel as `net` (deps = {}), it owns the rpv node the rest of
the system talks through and the static data that replaces the cut modules
(DECISIONS.md 3.2, 9):

    1. read /etc/network.conf            key=value lines, '#' comments
    2. rpv.node_new(spec) + node:setup()  one LAN interface, static address
    3. apply static neighbours            node.arp.cache[ip] = {mac=, expires=}
    4. apply static routes                rpv.route_add(..., "file")
    5. load /etc/hosts.conf               via net/hosts.lua, inject node.hosts
    6. bind the probe socket              UDP send-one/receive-one reachability

Failure policy: a missing or invalid config, a missing rpv table, a raising
setup and a refused probe socket all end in `health = "degraded"` plus a
`NET_*` log line, never in a panic. `start` still returns true, because the
kernel's readiness check accepts `degraded` (DECISIONS.md 2.7): a typo in one
config file must not roll back an otherwise bootable machine.

Config keys (all optional except `ip`):

    ip=10.0.0.5            required, strict dotted decimal (no leading zero)
    prefix=24              default 24, 1..32
    gateway=10.0.0.1       optional; omitted means local subnet only
    iface_side=back        modem side, default "back"
    iface_name=NET         default "NET"
    channel=4100           default 4100, 1..65532 (65533-65535 are rednet's)
    mtu=256                default 256, >= 68 (IPv4 minimum)
    linktype=wired         free-form label, default "wired"
    role=host              default "host"
    hosts_file=/etc/hosts.conf   default /etc/hosts.conf
    probe_port=47100       default 47100
    hosts_interval=5       default 5 s between mtime checks
    neighbor_ttl=3600      default 3600 s for static ARP entries
    static_neighbor=10.0.0.9,1001     repeatable
    static_route=10.9.0.0/16 via 10.0.0.9   repeatable

Unknown keys are logged as NET_CONFIG_UNKNOWN and do not degrade the service.
A bad value returns a message that includes the line number.

No non-ASCII bytes in this file.
]]

local S = {}

S.VERSION = "1.0"
S.NAME = "net"
S.DEFAULT_CONFIG_PATH = "/etc/network.conf"
S.DEFAULT_HOSTS_PATH = "/etc/hosts.conf"
S.DEFAULT_IFACE_SIDE = "back"
S.DEFAULT_IFACE_NAME = "NET"
S.DEFAULT_CHANNEL = 4100
S.DEFAULT_MTU = 256
S.DEFAULT_PROBE_PORT = 47100
S.DEFAULT_HOSTS_INTERVAL = 5
S.DEFAULT_NEIGHBOR_TTL = 3600
S.PROBE_PAYLOAD = "PYROET-NET-PROBE-1"
S.MAX_PROBES = 8
S.MAX_TIMEOUT = 10

local KNOWN_KEYS = {
    ip = true, prefix = true, gateway = true, iface_side = true,
    iface_name = true, channel = true, mtu = true, linktype = true,
    role = true, hosts_file = true, probe_port = true,
    hosts_interval = true, neighbor_ttl = true,
}

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

function S.parse_ip(text)
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

function S.int2ip(value)
    local n = math.floor(tonumber(value) or 0)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

local function masked(ip, prefix)
    if prefix <= 0 then return 0 end
    if prefix >= 32 then return ip end
    local size = 2 ^ (32 - prefix)
    return ip - (ip % size)
end

local function read_file(fsx, path)
    if not fsx or type(fsx.exists) ~= "function" then return nil, "no file system" end
    local ok, exists = pcall(fsx.exists, path)
    if not ok or not exists then return nil, "missing file: " .. tostring(path) end
    local handle = fsx.open(path, "r")
    if not handle then return nil, "cannot open " .. tostring(path) end
    local text
    if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
    handle.close()
    if text == nil then return nil, "cannot read " .. tostring(path) end
    return text
end

-- ---------------------------------------------------------------------------
-- config parsing (pure, testable without a file system)
-- ---------------------------------------------------------------------------

function S.parse_config(text)
    if type(text) ~= "string" then return nil, "network text must be a string" end
    local raw, neighbors, routes = {}, {}, {}
    local line_no = 0
    local body = text
    if body:sub(-1) ~= "\n" then body = body .. "\n" end
    for line in body:gmatch("([^\n]*)\n") do
        line_no = line_no + 1
        local clean = line:gsub("#.*$", ""):gsub("^[ \t]+", ""):gsub("[ \t\r]+$", "")
        if clean ~= "" then
            local key, value = clean:match("^([%w_]+)[ \t]*=[ \t]*(.*)$")
            if not key then
                return nil, "line " .. line_no .. ": expected key=value"
            end
            value = value:gsub("[ \t]+$", "")
            if key == "static_neighbor" then
                local ip_text, mac_text = value:match("^([^,]+),([^,]+)$")
                local ip = ip_text and S.parse_ip(ip_text)
                if not ip or not mac_text or mac_text:find("[^%d]") then
                    return nil, "line " .. line_no
                        .. ": bad static_neighbor '" .. value .. "' (want <ipv4>,<mac>)"
                end
                local mac = tonumber(mac_text)
                if not mac or mac % 1 ~= 0 or mac < 0 or mac > 4294967295 then
                    return nil, "line " .. line_no
                        .. ": bad static_neighbor '" .. value .. "' (want <ipv4>,<mac>)"
                end
                neighbors[#neighbors + 1] = {
                    ip = ip, ip_text = S.int2ip(ip), mac = mac,
                }
            elseif key == "static_route" then
                local net_text, prefix_text, gw_text =
                    value:match("^(%S+)/(%d+)[ \t]+via[ \t]+(%S+)$")
                local net = net_text and S.parse_ip(net_text)
                local prefix = tonumber(prefix_text)
                local gw = gw_text and S.parse_ip(gw_text)
                if not net or not prefix or prefix % 1 ~= 0
                    or prefix < 0 or prefix > 32 or not gw then
                    return nil, "line " .. line_no
                        .. ": bad static_route '" .. value .. "' (want <net>/<prefix> via <gw>)"
                end
                local net_masked = masked(net, prefix)
                routes[#routes + 1] = {
                    net = net_masked, net_text = S.int2ip(net_masked),
                    prefix = math.floor(prefix),
                    gw = gw, gw_text = S.int2ip(gw),
                }
            else
                raw[key] = value
            end
        end
    end

    local cfg = { neighbors = neighbors, routes = routes, unknown = {} }
    local ip_text = raw.ip
    if ip_text == nil or ip_text == "" then
        return nil, "missing required key 'ip'"
    end
    local ip = S.parse_ip(ip_text)
    if not ip then return nil, "bad ipv4 '" .. ip_text .. "'" end
    cfg.ip, cfg.ip_int = S.int2ip(ip), ip

    local prefix = tonumber(raw.prefix)
    if raw.prefix == nil then prefix = 24 end
    if not prefix or prefix % 1 ~= 0 or prefix < 1 or prefix > 32 then
        return nil, "bad prefix '" .. tostring(raw.prefix) .. "' (want 1..32)"
    end
    cfg.prefix = math.floor(prefix)

    if raw.gateway ~= nil and raw.gateway ~= "" then
        local gw = S.parse_ip(raw.gateway)
        if not gw then return nil, "bad gateway '" .. raw.gateway .. "'" end
        cfg.gateway, cfg.gateway_int = S.int2ip(gw), gw
    end

    cfg.iface_side = raw.iface_side or S.DEFAULT_IFACE_SIDE
    if not cfg.iface_side:match("^[%w_]+$") then
        return nil, "bad iface_side '" .. cfg.iface_side .. "'"
    end

    cfg.iface_name = raw.iface_name or S.DEFAULT_IFACE_NAME
    if not cfg.iface_name:match("^[%w%._%-]+$") then
        return nil, "bad iface_name '" .. cfg.iface_name .. "'"
    end

    local channel = tonumber(raw.channel)
    if raw.channel == nil then channel = S.DEFAULT_CHANNEL end
    if not channel or channel % 1 ~= 0 or channel < 1 or channel > 65532 then
        return nil, "bad channel '" .. tostring(raw.channel)
            .. "' (want 1..65532; 65533-65535 are rednet's)"
    end
    cfg.channel = math.floor(channel)

    local mtu = tonumber(raw.mtu)
    if raw.mtu == nil then mtu = S.DEFAULT_MTU end
    if not mtu or mtu % 1 ~= 0 or mtu < 68 or mtu > 65535 then
        return nil, "bad mtu '" .. tostring(raw.mtu) .. "' (want 68..65535)"
    end
    cfg.mtu = math.floor(mtu)

    cfg.linktype = raw.linktype or "wired"
    if not cfg.linktype:match("^[%w_%-]+$") then
        return nil, "bad linktype '" .. cfg.linktype .. "'"
    end

    cfg.role = raw.role or "host"
    if not cfg.role:match("^[%w_%-]+$") then
        return nil, "bad role '" .. cfg.role .. "'"
    end

    cfg.hosts_file = raw.hosts_file or S.DEFAULT_HOSTS_PATH
    cfg.hosts_file_explicit = raw.hosts_file ~= nil
    if type(cfg.hosts_file) ~= "string" or cfg.hosts_file == ""
        or cfg.hosts_file:sub(1, 1) ~= "/"
        or cfg.hosts_file:find("..", 1, true)
        or not cfg.hosts_file:match("^/[%w%._%-/]+$") then
        return nil, "bad hosts_file '" .. tostring(cfg.hosts_file) .. "'"
    end

    local probe_port = tonumber(raw.probe_port)
    if raw.probe_port == nil then probe_port = S.DEFAULT_PROBE_PORT end
    if not probe_port or probe_port % 1 ~= 0
        or probe_port < 1 or probe_port > 65534 then
        return nil, "bad probe_port '" .. tostring(raw.probe_port) .. "'"
    end
    cfg.probe_port = math.floor(probe_port)

    local interval = tonumber(raw.hosts_interval)
    if raw.hosts_interval == nil then interval = S.DEFAULT_HOSTS_INTERVAL end
    if not interval or interval <= 0 then
        return nil, "bad hosts_interval '" .. tostring(raw.hosts_interval) .. "'"
    end
    cfg.hosts_interval = interval

    local ttl = tonumber(raw.neighbor_ttl)
    if raw.neighbor_ttl == nil then ttl = S.DEFAULT_NEIGHBOR_TTL end
    if not ttl or ttl <= 0 then
        return nil, "bad neighbor_ttl '" .. tostring(raw.neighbor_ttl) .. "'"
    end
    cfg.neighbor_ttl = ttl

    local unknown = {}
    for key in pairs(raw) do
        if not KNOWN_KEYS[key] then unknown[#unknown + 1] = key end
    end
    table.sort(unknown)
    cfg.unknown = unknown
    return cfg
end

-- ---------------------------------------------------------------------------
-- service object
-- ---------------------------------------------------------------------------

function S.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = S })
    self.opts = o
    self.rpv = o.rpv
    self.fs = o.fs or rawget(_G, "fs")
    self.sink = o.log
    self.logs = {}
    self.clock = o.clock
    self.config_path = o.config_path or S.DEFAULT_CONFIG_PATH
    self.hosts_path = o.hosts_path or S.DEFAULT_HOSTS_PATH
    self.hosts_module = o.hosts_module
    self.hosts = nil
    self.cfg = nil
    self.node = nil
    self.state = "new"
    self.health_state = "degraded"
    self.reasons = {}
    self.counters = { sent = 0, received = 0, timeouts = 0 }
    self.probes = {}
    self.probe_seq = 0
    self.inflight = 0
    self.probe_socket = nil
    self.probe_port = nil
    self.reload_timer = nil
    self.stopped = false
    return self
end

function S:now()
    if type(self.clock) == "function" then return self.clock() end
    return os.clock()
end

function S:log(fmt, ...)
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

function S:degrade(reason, detail)
    self.health_state = "degraded"
    local known = false
    for i = 1, #self.reasons do
        if self.reasons[i] == reason then known = true end
    end
    if not known then self.reasons[#self.reasons + 1] = reason end
    if detail ~= nil then
        self:log("NET_DEGRADE_REASON reason=%s detail=%s",
            short(reason, 24), short(detail, 80))
    end
end

function S:health()
    if self.state ~= "running" then return "degraded" end
    return self.health_state
end

function S:load_config()
    local text, read_err = read_file(self.fs, self.config_path)
    if not text then return nil, read_err end
    local cfg, parse_err = S.parse_config(text)
    if not cfg then return nil, parse_err end
    return cfg
end

function S:load_hosts_module()
    local fsx = self.fs
    local candidates = { "/system/net/hosts.lua", "system/net/hosts.lua" }
    for i = 1, #candidates do
        local path = candidates[i]
        if fsx and type(fsx.exists) == "function" then
            local ok, exists = pcall(fsx.exists, path)
            if ok and exists then
                local loaded, module = pcall(dofile, path)
                if loaded and type(module) == "table" then return module end
                self:log("NET_HOSTS_MODULE_FAIL path=%s err=%s",
                    short(path, 40), short(module, 60))
            end
        end
    end
    return nil
end

function S:create_node()
    local rpv = self.rpv
    if type(rpv) ~= "table" or type(rpv.node_new) ~= "function" then
        self:degrade("rpv", "rpv library not supplied")
        self:log("NET_RPV_MISSING (pass rpv= to net.new)")
        return nil
    end
    local cfg = self.cfg
    local spec = {
        role = cfg.role,
        gw = cfg.gateway,
        ifaces = { {
            side = cfg.iface_side,
            name = cfg.iface_name,
            cidr = cfg.ip .. "/" .. tostring(cfg.prefix),
            channel = cfg.channel,
            mtu = cfg.mtu,
            linktype = cfg.linktype,
        } },
    }
    local ok, node = pcall(rpv.node_new, spec)
    if not ok or type(node) ~= "table" then
        self:degrade("node_new", tostring(node))
        self:log("NET_NODE_FAIL err=" .. short(node, 96))
        return nil
    end
    self.node = node
    local ok2, setup_err = pcall(node.setup, node)
    if not ok2 then
        self:degrade("setup", tostring(setup_err))
        self:log("NET_SETUP_FAIL err=" .. short(setup_err, 96))
    end
    return node
end

function S:apply_neighbors()
    local node, cfg = self.node, self.cfg
    if not node then return 0 end
    if type(node.arp) ~= "table" or type(node.arp.cache) ~= "table" then
        return 0
    end
    local now = self:now()
    local applied = 0
    for i = 1, #cfg.neighbors do
        local entry = cfg.neighbors[i]
        node.arp.cache[entry.ip] = {
            mac = entry.mac,
            expires = now + cfg.neighbor_ttl,
            static = true,
        }
        applied = applied + 1
        self:log("NET_NEIGHBOR ip=%s mac=%d ttl=%d",
            entry.ip_text, entry.mac, cfg.neighbor_ttl)
    end
    self.neighbor_count = applied
    return applied
end

function S:apply_routes()
    local node, cfg, rpv = self.node, self.cfg, self.rpv
    if not node or type(node.routes) ~= "table" then return 0 end
    if type(rpv) ~= "table" or type(rpv.route_add) ~= "function" then
        self:log("NET_ROUTE_SKIP (rpv.route_add unavailable)")
        return 0
    end
    local applied = 0
    for i = 1, #cfg.routes do
        local route = cfg.routes[i]
        local ok = pcall(rpv.route_add, node.routes, route.prefix, route.net,
            nil, route.gw, "file")
        if ok then
            applied = applied + 1
            self:log("NET_ROUTE dst=%s/%d via=%s kind=file",
                route.net_text, route.prefix, route.gw_text)
        else
            self:log("NET_ROUTE_FAIL dst=%s", short(route.net_text, 24))
        end
    end
    self.route_count = applied
    return applied
end

function S:setup_hosts()
    local mod = self.hosts_module
    if type(mod) ~= "table" or type(mod.new) ~= "function" then
        self:log("NET_HOSTS_MODULE_MISSING")
        return nil
    end
    self.hosts = mod.new({
        fs = self.fs,
        log = function(line) self:log("%s", tostring(line)) end,
        path = self.hosts_path,
        min_interval = self.cfg.hosts_interval,
        clock = self.clock,
    })
    local ok, info = self.hosts:load(self.hosts_path)
    if not ok then
        if self.cfg.hosts_file_explicit then
            self:degrade("hosts_file", info)
            self:log("NET_HOSTS_BAD path=%s err=%s",
                short(self.hosts_path, 48), short(info, 64))
        else
            self:log("NET_HOSTS_MISSING path=%s", short(self.hosts_path, 48))
        end
        return nil
    end
    local count = 0
    if type(mod.apply) == "function" and self.node then
        count = mod.apply(self.node, self.hosts:list()) or 0
    end
    self:log("NET_HOSTS path=%s entries=%d", short(self.hosts_path, 48), count)
    return count
end

function S:reload_hosts(now)
    if not self.hosts then return false, "no hosts" end
    local changed, info = self.hosts:reload_if_changed(now)
    if not changed then return false, info end
    local count = 0
    if self.hosts_module and type(self.hosts_module.apply) == "function"
        and self.node then
        count = self.hosts_module.apply(self.node, self.hosts:list()) or 0
    end
    self:log("NET_HOSTS_RELOAD entries=%d", count)
    return true, count
end

function S:schedule_reload()
    local node = self.node
    if not node or type(node.after) ~= "function" then return false end
    local interval = (self.cfg and self.cfg.hosts_interval)
        or S.DEFAULT_HOSTS_INTERVAL
    local service = self
    local function check()
        if service.stopped then return end
        service:reload_hosts()
        service:schedule_reload()
    end
    local ok, timer = pcall(node.after, node, interval, check)
    if ok then self.reload_timer = timer end
    return ok
end

function S:open_probe_socket()
    local node = self.node
    if not node or type(node.bind) ~= "function" then return nil end
    local port = self.cfg.probe_port
    local ok, socket = pcall(node.bind, node, port,
        function(data, src, sport)
            self:on_probe_reply(data, src, sport)
        end)
    if not ok or type(socket) ~= "table" then
        self:degrade("probe", tostring(socket))
        self:log("NET_PROBE_SOCKET_FAIL port=%d err=%s", port, short(socket, 64))
        return nil
    end
    self.probe_socket = socket
    self.probe_port = port
    self:log("NET_PROBE_SOCKET port=%d ip=%s", port, short(self.cfg.ip, 16))
    return socket
end

function S:start()
    if self.state == "running" then return true end
    self.state = "running"
    self.stopped = false
    self.health_state = "ok"
    self.reasons = {}
    local cfg, cfg_err = self:load_config()
    if not cfg then
        self:degrade("config", cfg_err)
        self:log("NET_CONFIG_BAD path=%s err=%s",
            short(self.config_path, 48), short(cfg_err, 96))
        self:log("NET_DEGRADED reasons=%s node=none",
            table.concat(self.reasons, ","))
        return true
    end
    self.cfg = cfg
    self.hosts_path = cfg.hosts_file
    for i = 1, #cfg.unknown do
        self:log("NET_CONFIG_UNKNOWN key=%s", short(cfg.unknown[i], 24))
    end
    if not self.hosts_module then
        self.hosts_module = self:load_hosts_module()
    end
    self:create_node()
    if self.node then
        self:apply_neighbors()
        self:apply_routes()
        self:setup_hosts()
        self:open_probe_socket()
        self:schedule_reload()
    end
    if self:health() == "ok" then
        self:log("NET_READY ip=%s/%d gw=%s iface=%s ch=%d hosts=%d",
            self.cfg.ip, self.cfg.prefix, short(self.cfg.gateway or "-", 16),
            short(self.cfg.iface_side, 12), self.cfg.channel,
            self.hosts and self.hosts:count() or 0)
    else
        self:log("NET_DEGRADED reasons=%s node=%s",
            (#self.reasons > 0 and table.concat(self.reasons, ",") or "-"),
            self.node and "up" or "none")
    end
    return true
end

function S:stop()
    if self.state == "stopped" then return true end
    self.stopped = true
    self.state = "stopped"
    local closed = 0
    if self.probe_socket and type(self.probe_socket.close) == "function" then
        pcall(self.probe_socket.close, self.probe_socket)
        closed = 1
    end
    for id, probe in pairs(self.probes) do
        probe.done = true
        probe.result = {
            ok = false, err = "stopped",
            ip = probe.ip, port = probe.port, rtt = 0,
        }
    end
    self.probes = {}
    self.inflight = 0
    self:log("NET_STOP socket_closed=%d", closed)
    return true
end

-- ---------------------------------------------------------------------------
-- probe: UDP send-one/receive-one reachability (no ICMP in the subset)
-- ---------------------------------------------------------------------------

function S:finish_probe(probe, result)
    if probe.done then return false end
    probe.done = true
    probe.result = result
    probe.result.ip = probe.ip
    probe.result.port = probe.port
    local rtt = self:now() - probe.sent
    if rtt < 0 then rtt = 0 end
    probe.result.rtt = rtt
    probe.result.rtt_text = string.format("%.2fs", rtt)
    self.probes[probe.id] = nil
    self.inflight = (self.inflight or 0) - 1
    if probe.result.ok then
        self.counters.received = self.counters.received + 1
        self:log("NET_PROBE_REPLY dst=%s port=%d rtt=%s",
            probe.ip, probe.port, probe.result.rtt_text)
    elseif probe.result.err == "timeout" then
        self.counters.timeouts = self.counters.timeouts + 1
        self:log("NET_PROBE_TIMEOUT dst=%s port=%d after=%s",
            probe.ip, probe.port, probe.result.rtt_text)
    else
        self:log("NET_PROBE_FAIL dst=%s port=%d err=%s",
            probe.ip, probe.port, short(probe.result.err, 48))
    end
    if type(probe.cb) == "function" then pcall(probe.cb, probe.result) end
    return true
end

function S:on_probe_reply(data, src, sport)
    local text = tostring(data == nil and "" or data)
    local match = nil
    for id, probe in pairs(self.probes) do
        if not probe.done and probe.dst == src and probe.port == sport then
            if text == probe.token
                or text:sub(1, #probe.token) == probe.token then
                match = probe
                break
            end
            if match == nil then match = probe end
        end
    end
    if not match then return nil, "no matching probe" end
    self:finish_probe(match, {
        ok = true, bytes = #text, reply = text,
    })
    return match
end

function S:probe(ip, port, payload, timeout, cb)
    if self.stopped then return nil, "service stopped" end
    local dst = S.parse_ip(tostring(ip == nil and "" or ip))
    if not dst then return nil, "bad ipv4: " .. tostring(ip) end
    local port_no = tonumber(port)
    if not port_no or port_no % 1 ~= 0 or port_no < 1 or port_no > 65535 then
        return nil, "bad port: " .. tostring(port)
    end
    local socket = self.probe_socket
    if not socket or type(socket.sendto) ~= "function" then
        return nil, "probe socket unavailable"
    end
    if (self.inflight or 0) >= S.MAX_PROBES then
        return nil, "too many probes"
    end
    local wait = tonumber(timeout) or 2
    if wait <= 0 then wait = 2 end
    if wait > S.MAX_TIMEOUT then wait = S.MAX_TIMEOUT end
    local body = tostring(payload == nil and S.PROBE_PAYLOAD or payload)
    self.probe_seq = self.probe_seq + 1
    local id = self.probe_seq
    local probe = {
        id = id,
        dst = dst,
        ip = S.int2ip(dst),
        port = math.floor(port_no),
        token = S.PROBE_PAYLOAD .. " " .. tostring(id) .. " " .. body,
        sent = self:now(),
        done = false,
        result = nil,
        cb = cb,
    }
    self.probes[id] = probe
    self.inflight = (self.inflight or 0) + 1
    self.counters.sent = self.counters.sent + 1
    local called, sent = pcall(socket.sendto, socket, dst, probe.port,
        probe.token, 64)
    if not called then
        self:finish_probe(probe, { ok = false, err = "unreachable: " .. tostring(sent) })
        return probe
    end
    if sent == false then
        self:finish_probe(probe, { ok = false, err = "unreachable" })
        return probe
    end
    local node = self.node
    if node and type(node.after) == "function" then
        local ok, timer_err = pcall(node.after, node, wait, function()
            if not probe.done then
                self:finish_probe(probe, { ok = false, err = "timeout" })
            end
        end)
        if not ok then
            self:finish_probe(probe, { ok = false, err = "no timer: " .. tostring(timer_err) })
            return probe
        end
    else
        self:finish_probe(probe, { ok = false, err = "no timer" })
    end
    self:log("NET_PROBE_SEND dst=%s port=%d timeout=%.2fs",
        probe.ip, probe.port, wait)
    return probe
end

function S:stats()
    return {
        sent = self.counters.sent,
        received = self.counters.received,
        timeouts = self.counters.timeouts,
        inflight = self.inflight or 0,
    }
end

function S:resolve(name)
    if not self.hosts then return nil, "no hosts table" end
    return self.hosts:resolve(name)
end

function S:list_hosts()
    if not self.hosts then return {} end
    return self.hosts:list()
end

function S:status()
    local cfg = self.cfg or {}
    local reasons = {}
    for i = 1, #self.reasons do reasons[i] = self.reasons[i] end
    return {
        started = self.state == "running",
        health = self:health(),
        ip = cfg.ip,
        prefix = cfg.prefix,
        gateway = cfg.gateway,
        iface = cfg.iface_side,
        channel = cfg.channel,
        hosts = self.hosts and self.hosts:count() or 0,
        probe_port = self.probe_port,
        reasons = reasons,
    }
end

-- ---------------------------------------------------------------------------
-- kernel registration
-- ---------------------------------------------------------------------------

-- A spec for kernel:register("net", spec) / startup.lua's ctx.services list.
function S.spec(opts)
    local service = S.new(opts)
    local spec = {
        name = S.NAME,
        deps = {},
        service = service,
        start = function() return service:start() end,
        stop = function() return service:stop() end,
        health = function() return service:health() end,
    }
    return spec
end

function S.register(kernel, opts)
    if type(kernel) ~= "table" or type(kernel.register) ~= "function" then
        return nil, "kernel table required"
    end
    local spec = S.spec(opts)
    local ok, err = kernel:register(S.NAME, spec)
    return ok, err, spec.service
end

return S
