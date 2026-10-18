--[[- rpv/services.lua ? DHCP-lite (address autoconfiguration) and lookup-lite (name?IP).

Both are ordinary rpv UDP services, so they work across routers and the rednet WAN
like any other traffic.

DHCP-LITE (UDP 6700 by default)
  A client starts with a *placeholder* address on the segment the server lives on
  (convention: `dhcp=1` with a cidr in 10.254.0.0/16), broadcasts DISCOVER, and
  adopts the address the server offers:

      DISCOVER (broadcast)  -> OFFER  (unicast, offered ip/mask/gw/dns/lease)
      REQUEST  (unicast)    -> ACK    (unicast; the lease is committed)
                             -> NAK    (no pool space / bad request)

  On ACK the client re-addresses its interface, installs the default route and (when
  a name is configured) registers that name with the name server.

  server keys: dhcp_pool=10.0.1.100-10.0.1.150  dhcp_gw=10.0.1.1  dhcp_dns=10.0.1.1
               dhcp_lease=600  dhcp_port=6700  dhcp_server_name=dhcp
  client keys: dhcp=1  [dhcp_server=<ip>]  name=<hostname>  dns_server=<ip>

LOOKUP-LITE (UDP 6701 by default)
      REGISTER name -> ip      (client announces itself to the name server)
      QUERY    name -> ANSWER ip / NACK
  Clients also read a static `hosts.txt` (`<name> <ip>` per line) at setup, so the
  common case needs no query at all.

  server keys: dns=1  dns_port=6701
  client keys: name=<hostname>  dns_server=<ip>  (defaults to the default gateway)

Wire format (kept tiny on purpose):
  DHCP:  u8 type | u32 xid | u32 ip | u8 prefix | u32 gw | u32 dns | u32 lease | u8 nameLen | name
  DNS:   u8 type | u8 nameLen | name | u32 ip
]]
local M = ...
local u8, u16, u32, r32, byte, sub = M.u8, M.u16, M.u32, M.r32, M.byte, M.sub

local DHCP_PORT, DNS_PORT = 6700, 6701
local T_DISCOVER, T_OFFER, T_REQUEST, T_ACK, T_NAK = 1, 2, 3, 4, 5
local T_RELEASE, T_DECLINE = 6, 7
local D_REGISTER, D_QUERY, D_ANSWER, D_NACK = 1, 2, 3, 4

M.SERVICES_TYPES = {
    dhcp = { DISCOVER = T_DISCOVER, OFFER = T_OFFER, REQUEST = T_REQUEST, ACK = T_ACK, NAK = T_NAK },
    dns = { REGISTER = D_REGISTER, QUERY = D_QUERY, ANSWER = D_ANSWER, NACK = D_NACK },
}

-- ===== DHCP-lite ============================================================
-- wire format: 1 type | 4 xid | 4 ip | 1 prefix | 4 gw | 4 dns | 4 lease |
--               4 server-id | 4 client-id (mac) | 1 nameLen | name
--
-- The client id (its mac) is what leases are keyed on: keying on the source address
-- collides when two clients still hold the same placeholder address. server-id lets a
-- client address its REQUEST/RELEASE at the server that offered the lease.
local D_MIN = 31
local function dhcp_pack(t, xid, ip, prefix, gw, dns, lease, server, client, name)
    name = name or ""
    return u8(t) .. u32(xid or 0) .. u32(ip or 0) .. u8(prefix or 0) .. u32(gw or 0)
        .. u32(dns or 0) .. u32(lease or 0) .. u32(server or 0) .. u32(client or 0)
        .. u8(#name) .. name
end

local function dhcp_unpack(s)
    if #s < D_MIN then return nil end
    local nl = byte(s, 31)
    if #s < D_MIN + nl then return nil end
    return {
        t = byte(s, 1), xid = r32(s, 2), ip = r32(s, 6), prefix = byte(s, 10),
        gw = r32(s, 11), dns = r32(s, 15), lease = r32(s, 19),
        server = r32(s, 23), client = r32(s, 27), name = sub(s, 32, 31 + nl),
    }
end
M.dhcp_pack, M.dhcp_unpack = dhcp_pack, dhcp_unpack

-- A client that has no address yet may not be routable at all, so a reply is
-- unicast when a route exists and broadcast otherwise (real DHCP does the same).
local function dhcp_reply(node, src, sport, port, payload)
    if node:resolve(src) then
        M.udp_send(node, src, port, sport, payload)
    else
        M.udp_send(node, M.IP_BCAST, port, sport, payload)
    end
end

local function parse_pool(spec)
    local a, b = tostring(spec or ""):match("^([%d%.]+)%s*%-%s*([%d%.]+)$")
    if not a then return nil end
    return M.ip2int(a), M.ip2int(b)
end

-- server: bind the DHCP port, allocate from the pool, commit leases
-- server-side helpers (exported so the offline tests can drive them directly)
function M.dhcp_expire(node, srv, now)
    -- recycle bound leases past their deadline and stale offers; called by the sweeper
    -- task and directly by tests
    now = now or os.clock()
    local n = 0
    for ip, le in pairs(srv.by_ip) do
        local deadline = le.expires or 0
        if deadline > 0 and now >= deadline then
            local held = now - (le.granted_at or now)
            srv.by_ip[ip] = nil
            if le.client and srv.by_client[le.client] == ip then srv.by_client[le.client] = nil end
            srv.expired = (srv.expired or 0) + 1
            n = n + 1
            node:log("DHCP_EXPIRE ip=%s client=%s state=%s held=%.1fs", M.int2ip(ip), tostring(le.client), le.state, held)
        end
    end
    return n
end

local function release_lease(node, srv, ip, why)
    local le = ip and srv.by_ip[ip]
    if not le then return false end
    srv.by_ip[ip] = nil
    if le.client and srv.by_client[le.client] == ip then srv.by_client[le.client] = nil end
    srv.freed = (srv.freed or 0) + 1
    node:log("DHCP_%s ip=%s client=%s state=%s", why, M.int2ip(ip), tostring(le.client), le.state)
    return true
end

-- conflict probe: is somebody already using this address? The hook (srv.probe_fn) makes
-- it deterministic for the offline tests; otherwise it sends an ICMP echo and waits for
-- a reply (no reply within the timeout means the address looks free).
local function probe_address(node, srv, ip, cb)
    if srv.probe_fn then
        cb(srv.probe_fn(ip) and true or false)
        return
    end
    if node.cfg.dhcp_probe == "0" then cb(false) return end
    local seq = srv.probe_seq
    srv.probe_seq = srv.probe_seq + 1
    srv.probe = { ip = ip, seq = seq, in_use = false }
    M.icmp_echo(node, ip, seq)
    local timeout = tonumber(node.cfg.dhcp_probe_timeout) or 1.5
    node:after(timeout, function()
        local p = srv.probe
        srv.probe = nil
        if p and p.seq == seq then cb(p.in_use) end
    end)
end

-- ring allocation: scan the whole pool from the last position (wrap around) so address
-- addresses recycled by the expiry sweeper come back into use
local function find_free(srv)
    local total = srv.hi - srv.lo + 1
    for k = 0, total - 1 do
        local ip = srv.lo + ((srv.next - srv.lo + k) % total)
        if not srv.by_ip[ip] and not srv.bad[ip] then
            srv.next = ip + 1
            if srv.next > srv.hi then srv.next = srv.lo end
            return ip
        end
    end
    return nil
end

-- ring allocation: scan the whole pool from the last position (wrapping around) so
-- addresses recycled by the expiry sweeper come back into use
local function find_free(srv)
    local total = srv.hi - srv.lo + 1
    for k = 0, total - 1 do
        local ip = srv.lo + ((srv.next - srv.lo + k) % total)
        if not srv.by_ip[ip] and not srv.bad[ip] then
            srv.next = ip + 1
            if srv.next > srv.hi then srv.next = srv.lo end
            return ip
        end
    end
    return nil
end

function M.dhcp_server_start(node, opts)
    opts = opts or {}
    local port = tonumber(node.cfg.dhcp_port) or DHCP_PORT
    local lo, hi = parse_pool(node.cfg.dhcp_pool)
    if not lo then
        node:log("DHCP_SERVER_NO_POOL (set dhcp_pool=start-end)")
        return nil
    end
    local gw = M.ip2int(node.cfg.dhcp_gw or (node.ifaces[1] and node.ifaces[1].cidr:match("^([%d%.]+)") or "0.0.0.0"))
    local dns = M.ip2int(node.cfg.dhcp_dns or M.int2ip(gw))
    local lease = tonumber(node.cfg.dhcp_lease) or 600
    local prefix = tonumber((node.ifaces[1] and node.ifaces[1].prefix) or 24)
    local offer_ttl = tonumber(node.cfg.dhcp_offer_ttl) or 30
    local srv = { port = port, lo = lo, hi = hi, gw = gw, dns = dns, lease = lease,
                  prefix = prefix, by_client = {}, by_ip = {}, bad = {}, next = lo,
                  leases = 0, offers = 0, naks = 0, renewals = 0, expired = 0, freed = 0,
                  offer_ttl = offer_ttl, probe_seq = 40000, probe_fn = opts.probe_fn }
    node:log("DHCP_SERVER_START pool=%s-%s gw=%s dns=%s lease=%ds port=%d probe=%s",
        M.int2ip(lo), M.int2ip(hi), M.int2ip(gw), M.int2ip(dns), lease, port,
        (srv.probe_fn and "hook") or (node.cfg.dhcp_probe == "0" and "off") or "icmp")

    -- one DISCOVER/REQUEST/RELEASE/DECLINE handler, exported for the offline tests
    local function handle(data, src, sport)
        local m = dhcp_unpack(data)
        if not m then srv.bad_packets = (srv.bad_packets or 0) + 1 return end
        -- lease identity: the client id (mac) when present, else the source address
        local key = (m.client ~= 0) and m.client or src
        if m.t == T_DISCOVER then
            local ip = srv.by_client[key]
            if ip and not srv.by_ip[ip] then ip = nil end
            local function try_ip(tries)
                if not ip then
                    ip = find_free(srv)
                    if not ip then
                        srv.naks = srv.naks + 1
                        node:log("DHCP_NAK from=%s client=%s (pool exhausted)", M.int2ip(src), tostring(key))
                        dhcp_reply(node, src, sport, port, dhcp_pack(T_NAK, m.xid, 0, 0, srv.gw, srv.dns, 0, gw, key, "pool exhausted"))
                        return
                    end
                end
                probe_address(node, srv, ip, function(in_use)
                    if in_use then
                        srv.bad[ip] = true
                        node:log("DHCP_PROBE_INUSE ip=%s (skipping)", M.int2ip(ip))
                        ip = nil
                        if tries < (srv.hi - srv.lo + 1) then return try_ip(tries + 1) end
                        srv.naks = srv.naks + 1
                        node:log("DHCP_NAK client=%s (no free address after probing)", tostring(key))
                        dhcp_reply(node, src, sport, port, dhcp_pack(T_NAK, m.xid, 0, 0, srv.gw, srv.dns, 0, gw, key, "no free address"))
                        return
                    end
                    srv.by_client[key] = ip
                    srv.by_ip[ip] = { client = key, name = (m.name ~= "" and m.name) or nil,
                                      state = "offered", granted_at = os.clock(),
                                      expires = os.clock() + srv.offer_ttl }
                    srv.offers = srv.offers + 1
                    node:log("DHCP_OFFER to=%s client=%s ip=%s name=%s", M.int2ip(src), tostring(key), M.int2ip(ip), m.name)
                    dhcp_reply(node, src, sport, port, dhcp_pack(T_OFFER, m.xid, ip, srv.prefix, srv.gw, srv.dns, srv.lease, gw, key, m.name))
                end)
            end
            try_ip(0)
        elseif m.t == T_REQUEST then
            local ip = srv.by_client[key]
            if not ip or ip ~= m.ip then
                srv.naks = srv.naks + 1
                node:log("DHCP_NAK from=%s client=%s (requested %s, ours %s)", M.int2ip(src), tostring(key),
                    M.int2ip(m.ip), ip and M.int2ip(ip) or "none")
                dhcp_reply(node, src, sport, port, dhcp_pack(T_NAK, m.xid, 0, 0, srv.gw, srv.dns, 0, gw, key, "bad request"))
                return
            end
            local le = srv.by_ip[ip]
            local renew = (le.state == "bound")
            le.state = "bound"
            le.granted_at = os.clock()
            le.expires = os.clock() + srv.lease
            if m.name ~= "" then le.name = m.name end
            srv.leases = srv.leases + 1
            if renew then srv.renewals = srv.renewals + 1 end
            node:log("DHCP_LEASE ip=%s client=%s name=%s state=bound renew=%s n=%d",
                M.int2ip(ip), tostring(key), tostring(le.name), tostring(renew), srv.leases)
            dhcp_reply(node, src, sport, port, dhcp_pack(T_ACK, m.xid, ip, srv.prefix, srv.gw, srv.dns, srv.lease, gw, key, le.name or ""))
        elseif m.t == T_RELEASE then
            release_lease(node, srv, srv.by_client[key], "RELEASE")
        elseif m.t == T_DECLINE then
            local ip = srv.by_client[key] or m.ip
            if ip and srv.by_ip[ip] then
                srv.bad[ip] = true
                release_lease(node, srv, ip, "DECLINE")
            end
        end
    end
    srv.handle = handle
    srv.sk = node:bind(port, handle)
    node.dhcp_server = srv
    node.dhcp = srv
    -- recycle expired leases (and stale offers) without waiting for new traffic
    if node.add_task then
        node:add_task("dhcp-expire", function()
            local every = tonumber(node.cfg.dhcp_sweep) or 5
            while true do
                os.sleep(every)
                M.dhcp_expire(node, srv)
            end
        end)
    end
    -- a probe reply marks the probed address as in use
    local prev_echo = node.on_echo_reply
    node.on_echo_reply = function(src, seq, rtt)
        local p = srv.probe
        if p and seq == p.seq then p.in_use = true end
        if prev_echo then prev_echo(src, seq, rtt) end
    end
    return srv
end

-- client: acquire an address, then re-address the interface and install the route.
-- Once bound it renews at T1 (lease/2 by default, dhcp_t1 overrides) so the lease does
-- not silently expire, and it can hand the lease back (dhcp_release) or report an
-- address somebody else is using (dhcp_decline).
function M.dhcp_client_start(node, iface, opts)
    opts = opts or {}
    local port = tonumber(node.cfg.dhcp_port) or DHCP_PORT
    local iface = iface or node.ifaces[1]
    if not iface then node:log("DHCP_CLIENT_NO_IFACE") return nil end
    -- os.epoch in CC only accepts "ingame"/"utc"/"local"; "utc" is milliseconds
    local xid = (os.getComputerID() * 7919 + (os.epoch and os.epoch("utc") or 0)) % 2 ^ 31
    local name = node.cfg.name or ("host" .. tostring(node.id))
    local cli = { port = port, iface = iface, xid = xid, state = "INIT", tries = 0, name = name,
                  client = node.mac or 0, server = 0, acks = 0 }
    node.dhcp_client = cli
    node:log("DHCP_CLIENT_START iface=%s placeholder=%s name=%s client=%s", iface.name, iface.cidr, name, tostring(cli.client))

    local function send(kind, ip)
        -- a client without a usable address must broadcast: no ARP and no route needed
        local m = dhcp_pack(kind, xid, ip or 0, iface.prefix, 0, 0, 0, cli.server, cli.client, name)
        M.udp_send(node, M.IP_BCAST, port, port, m, 64, iface.ip)
    end

    -- exported so the offline tests can drive the client state machine
    local function handle(data, src, sport)
        local m = dhcp_unpack(data)
        if not m or m.xid ~= xid then return end
        if m.t == T_OFFER then
            cli.offer = m
            cli.server = m.server
            node:log("DHCP_OFFER_GOT ip=%s gw=%s dns=%s from=%s", M.int2ip(m.ip), M.int2ip(m.gw), M.int2ip(m.dns), M.int2ip(src))
            send(T_REQUEST, m.ip)
        elseif m.t == T_ACK then
            cli.state = "BOUND"
            cli.bound = m
            cli.acks = cli.acks + 1
            cli.lease = m.lease
            cli.t1 = tonumber(node.cfg.dhcp_t1) or math.max(2, math.floor((m.lease or 600) * (tonumber(node.cfg.dhcp_t1_scale) or 0.5)))
            node:log("DHCP_BOUND ip=%s/%d gw=%s dns=%s lease=%ds t1=%ds client=%s",
                M.int2ip(m.ip), m.prefix, M.int2ip(m.gw), M.int2ip(m.dns), m.lease, cli.t1, tostring(cli.client))
            M.dhcp_apply(node, iface, m)
        elseif m.t == T_NAK then
            node:log("DHCP_NAK reason=%s", tostring(m.name))
            cli.state = "NAK"
        end
    end
    cli.handle = handle
    cli.sk = node:bind(port, handle)
    send(T_DISCOVER, iface.ip)          -- start() initiates immediately
    node:log("DHCP_DISCOVER from=%s", M.int2ip(iface.ip))

    node:add_task("dhcp-client", function()
        while cli.state ~= "BOUND" and cli.tries < 8 do
            os.sleep(2)
            cli.tries = cli.tries + 1
            if cli.state == "NAK" then cli.state = "INIT" end
            if cli.state ~= "BOUND" then
                node:log("DHCP_RETRY try=%d", cli.tries)
                send(T_DISCOVER, iface.ip)
            end
        end
        if cli.state ~= "BOUND" then
            node:log("DHCP_FAILED tries=%d", cli.tries)
            return
        end
        while cli.state == "BOUND" do
            os.sleep(cli.t1 or 300)
            if cli.state ~= "BOUND" then break end
            cli.renews = (cli.renews or 0) + 1
            local acks = cli.acks
            node:log("DHCP_RENEW try=%d ip=%s", cli.renews, M.int2ip(cli.bound and cli.bound.ip or 0))
            send(T_REQUEST, cli.bound and cli.bound.ip or 0)
            local waited = 0
            while cli.state == "BOUND" and cli.acks == acks and waited < 5 do
                os.sleep(0.5)
                waited = waited + 0.5
            end
            if cli.state == "BOUND" and cli.acks == acks then
                node:log("DHCP_RENEW_FAIL try=%d (no answer, rediscovering)", cli.renews)
                cli.state = "INIT"
                cli.tries = 0
                send(T_DISCOVER, iface.ip)
            end
        end
    end)
    return cli
end

-- hand the lease back to the server (apps and tests)
function M.dhcp_release(node)
    local cli = node.dhcp_client
    if not cli or cli.state ~= "BOUND" then return false end
    local ip = cli.bound and cli.bound.ip or 0
    M.udp_send(node, M.IP_BCAST, cli.port, cli.port,
        dhcp_pack(T_RELEASE, cli.xid, ip, cli.iface.prefix, 0, 0, 0, cli.server, cli.client, cli.name), 64, cli.iface.ip)
    cli.state = "RELEASED"
    node:log("DHCP_RELEASED ip=%s", M.int2ip(ip))
    return true
end

-- report an address we found in use by somebody else (server blacklists it)
function M.dhcp_decline(node, ip)
    local cli = node.dhcp_client
    if not cli then return false end
    local addr = ip or (cli.bound and cli.bound.ip) or 0
    M.udp_send(node, M.IP_BCAST, cli.port, cli.port,
        dhcp_pack(T_DECLINE, cli.xid, addr, cli.iface.prefix, 0, 0, 0, cli.server, cli.client, cli.name), 64, cli.iface.ip)
    cli.state = "DECLINED"
    node:log("DHCP_DECLINED ip=%s", M.int2ip(addr))
    return true
end

-- adopt a lease: re-address the interface, replace its connected route, set the gw
function M.dhcp_apply(node, iface, m)
    local old_net = iface.net
    iface.ip, iface.prefix = m.ip, m.prefix
    iface.cidr = M.int2ip(m.ip) .. "/" .. m.prefix
    iface.net = M.masked(iface.ip, iface.prefix)
    local keep = {}
    for _, r in ipairs(node.routes.entries) do
        local is_connected_here = (r.kind == "connected" and r.iface == iface and r.net == old_net)
        if not is_connected_here then keep[#keep + 1] = r end
    end
    node.routes.entries = keep
    M.route_connected(node.routes, iface)
    if m.gw and m.gw ~= 0 then M.route_default(node.routes, m.gw) end
    node:log("DHCP_APPLIED iface=%s addr=%s net=%s gw=%s", iface.name, iface.cidr, M.int2ip(iface.net), M.int2ip(m.gw or 0))
    if node.dns_register then node:dns_register(node.cfg.name or m.name) end
    return true
end

-- ===== lookup-lite ==========================================================
local function dns_pack(t, name, ip)
    name = name or ""
    return u8(t) .. u8(#name) .. name .. u32(ip or 0)
end

local function dns_unpack(s)
    if #s < 2 then return nil end
    local nl = byte(s, 2)
    if #s < 2 + nl + 4 then return nil end
    return { t = byte(s, 1), name = sub(s, 3, 2 + nl), ip = r32(s, 3 + nl) }
end

function M.dns_server_start(node, opts)
    opts = opts or {}
    local port = tonumber(node.cfg.dns_port) or DNS_PORT
    local srv = { port = port, names = {}, queries = 0, registrations = 0 }
    -- leases published by our own DHCP server are resolvable too
    node:log("DNS_SERVER_START port=%d", port)
    srv.sk = node:bind(port, function(data, src, sport)
        local m = dns_unpack(data)
        if not m or m.name == "" then return end
        if m.t == D_REGISTER then
            srv.names[m.name] = m.ip
            srv.registrations = srv.registrations + 1
            node:log("DNS_REG name=%s ip=%s from=%s", m.name, M.int2ip(m.ip), M.int2ip(src))
        elseif m.t == D_QUERY then
            srv.queries = srv.queries + 1
            local ip = srv.names[m.name]
            -- fall back to the DHCP lease table (name -> address)
            if not ip and node.dhcp then
                for leaseIp, le in pairs(node.dhcp.by_ip) do
                    if le.name == m.name then ip = leaseIp break end
                end
            end
            node:log("DNS_QUERY name=%s answer=%s from=%s", m.name, ip and M.int2ip(ip) or "none", M.int2ip(src))
            M.udp_send(node, src, port, sport, dns_pack(ip and D_ANSWER or D_NACK, m.name, ip or 0))
        end
    end)
    node.dns = srv
    return srv
end

function M.hosts_load(node, path)
    path = path or "hosts.txt"
    local t = {}
    if fs.exists(path) then
        local f = fs.open(path, "r")
        for line in f.readLine do
            line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            local name, ip = line:match("^([%w%-_.]+)%s+([%d%.]+)$")
            if name then t[name] = M.ip2int(ip) end
        end
        f.close()
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        if n > 0 then node:log("HOSTS_LOADED n=%d path=%s", n, path) end
    end
    node.hosts = t
    return t
end

-- advertise our name/address to the name server
function M.dns_register(node, name)
    name = name or node.cfg.name
    if not name or name == "" then return false end
    local srv = node.cfg.dns_server and M.ip2int(node.cfg.dns_server)
        or (node.cfg.gw and M.ip2int(node.cfg.gw))
    if not srv then node:log("DNS_REGISTER_NO_SERVER"); return false end
    local ip = node:pick_src(srv)
    if not ip or ip == 0 then ip = node.ifaces[1] and node.ifaces[1].ip or 0 end
    local port = tonumber(node.cfg.dns_port) or DNS_PORT
    M.udp_send(node, srv, port, port, dns_pack(D_REGISTER, name, ip))
    node:log("DNS_REGISTER_SENT name=%s ip=%s to=%s", name, M.int2ip(ip), M.int2ip(srv))
    if node.hosts then node.hosts[name] = ip end
    return true
end

-- name -> ip. Blocking-style: call inside a task (uses os.sleep), or pass a
-- callback for the non-blocking form.
function M.lookup(node, name, timeout, cb)
    local t = node.hosts or {}
    if t[name] then
        if cb then cb(t[name]) end
        return t[name]
    end
    local srv = node.cfg.dns_server and M.ip2int(node.cfg.dns_server)
        or (node.cfg.gw and M.ip2int(node.cfg.gw))
    if not srv then
        node:log("LOOKUP_NO_SERVER name=%s", name)
        if cb then cb(nil) end
        return nil
    end
    local port = tonumber(node.cfg.dns_port) or DNS_PORT
    node:log("LOOKUP_QUERY name=%s via=%s", name, M.int2ip(srv))
    local result = nil
    local sk = node:bind(port, function(data, src, sport)
        local m = dns_unpack(data)
        if not m or m.name ~= name then return end
        if m.t == D_ANSWER and m.ip ~= 0 then
            result = m.ip
            node.hosts[name] = m.ip
        else
            result = false
        end
    end)
    M.udp_send(node, srv, port, port, dns_pack(D_QUERY, name))
    local waited = 0
    while result == nil and waited < (timeout or 3) do
        os.sleep(0.25)
        waited = waited + 0.25
    end
    if sk and sk.close then pcall(function() sk:close() end) end
    if result then
        node:log("LOOKUP_ANSWER name=%s ip=%s after=%.2fs", name, M.int2ip(result), waited)
        if cb then cb(result) end
        return result
    end
    node:log("LOOKUP_TIMEOUT name=%s after=%.2fs", name, waited)
    if cb then cb(nil) end
    return nil
end

-- ===== setup hook ===========================================================
-- Called from node:setup(); wired entirely from configuration keys.
function M.services_setup(node)
    M.hosts_load(node, node.cfg.hosts_file or "hosts.txt")
    if node.cfg.dhcp == "1" then
        local iface = node.ifaces[1]
        for _, i in ipairs(node.ifaces) do
            if not i.is_wan then iface = i break end
        end
        M.dhcp_client_start(node, iface)
    end
    if node.cfg.dhcp_pool then M.dhcp_server_start(node) end
    if node.cfg.dns == "1" then M.dns_server_start(node) end
    if node.cfg.name and node.cfg.name ~= "" and node.cfg.dhcp ~= "1" then
        node:after(1.0, function() M.dns_register(node) end)
    end
end

return M
