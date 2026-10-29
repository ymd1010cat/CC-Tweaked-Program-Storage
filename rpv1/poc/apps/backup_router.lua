--[[- apps/backup_router.lua - RPV1 hot-standby (HA) switch for the ender public wire.

What this file is
  A single-file, pure Lua 5.1 backup switch for an RPV1 (CC:Tweaked) router. The
  primary and the backup share the public gateway address (10.200.0.1/24, the
  ender public side), so the pair is a hot standby: the backup owns the same VIP
  on the same wire but stays quiet -- no DHCP server, no ARP answers for the VIP
  -- until the primary stops answering.

  Four jobs, in this order:

  1. Startup lock. The BOTTOM redstone input must be powered. Nothing below the
     lock runs while it is off: no DHCP, no sync task, no hooks.
  2. Firewall. An RPV1 input hook in front of rpv.nat_input_hook drops every
     packet whose destination is inside 192.168.0.0/16 when it arrives from the
     public zone (the 10.200.0.0/24 wire) or carries a public source address.
     LAN ingress is untouched, so a local DHCP/DNS service keeps working.
  3. Configuration sync. A background node task sends one UDP request to the
     primary every 5 s (port 6710 by default) and stores the DHCP parameters the
     primary reports in synced_dhcp_config. Nothing is started from it while the
     primary is alive.
  4. Takeover and failback. Three misses (15 s) without a response and the backup
     starts the DHCP server from synced_dhcp_config (rpv.dhcp_server_start) and
     broadcasts a gratuitous ARP for the VIP. As soon as the primary answers
     again the local DHCP server is shut down and the box returns to standby, so
     the pair never serves leases at the same time.

Log tags worth watching (all lines are ASCII)
  HA_BOOT HA_REDSTONE_LOCK HA_REDSTONE_ON HA_FIREWALL_READY HA_FIREWALL_OFF
  STANDBY_DHCP_OFF HA_SYNC_TX HA_SYNC_MISS HA_SYNC_REPLY HA_SYNC_BAD
  SYNCED_DHCP_CONFIG TAKEOVER_ACTIVE TAKEOVER_ABORT HA_TAKEOVER_HOLD
  HA_ARP_ANNOUNCE HA_DHCP_STOP STANDBY_MODE FIREWALL_DROP HA_MODE

Wire format (ASCII, one UDP datagram per message)
  request : RPV1-HA/1 SYNC id=<computer id> nonce=<n>
  reply   : RPV1-HA/1 CFG master=<id> to=<requester id> nonce=<n> ...
            -- pool_start=10.200.0.50 pool_end=10.200.0.150 lease_time=600
            -- gateway=10.200.0.1 dns=10.200.0.1 prefix=24 dhcp_port=6700
            -- uptime=42

  A second copy of this file can act as the primary: opts.role = "primary"
  answers the requests from the running DHCP server (or from
  M.DEFAULT_DHCP_CONFIG) and never takes over anything.

Why the sync is sent to 255.255.255.255 when the VIP is shared
  rpv delivers a datagram addressed to an address the local node owns to itself
  (rpv/node.lua:556-568 in this repository), so on a backup whose interface IS
  10.200.0.1 a unicast to 10.200.0.1 would never reach the primary. When the
  configured primary address equals the local interface address, the request
  (and the reply) use the limited broadcast instead; every node on the wire sees
  it and the nonce/to fields make sure only the intended peer acts on it. A
  backup with a distinct address uses plain unicast, but takeover is only
  possible when the VIP is a local address (otherwise packets for the VIP are
  never delivered to this node).

Usage
  -- A) die-hard boot: lock, build the node, start the HA service, run
  local ha = dofile("apps/backup_router.lua")
  ha.boot({ rpv = rpv })                       -- never returns

  -- B) under node2/startup.lua: role.txt gets `app=backup_router`
  --    (the bootstrap already ran node:setup(); start() does the rest)
  local ha = dofile("apps/backup_router.lua")
  ha.start_router(node, rpv, { master_ip = "10.200.0.1", sync_port = 6710 })

  -- C) the same file as the primary (it answers the sync requests)
  local inst = ha.new{ rpv = rpv, node = node, role = "primary" }
  inst.start()

  -- optional console status
  print(ha.status_text(node.ha))

The file is ASCII only and uses nothing outside the CraftOS fs/rs APIs and the
rpv node object (modem, UDP, ARP, DHCP are all rpv services).
]]

local M = {}

M.VERSION = "1.0"
M.PROTO = "RPV1-HA/1"
M.TAG = "backup_router"

-- ===== knobs (all overridable through opts / the module table) ==============
M.CIDR = "10.200.0.1/24"        -- base interface of the switch (ender public)
M.MASTER_IP = "10.200.0.1"      -- the primary switch (the VIP in shared mode)
M.SYNC_PORT = 6710              -- UDP port of the HA protocol
M.SYNC_INTERVAL = 5             -- seconds between sync requests
M.FAIL_LIMIT = 3                -- consecutive misses before a takeover
M.TAKEOVER_AFTER = 15           -- seconds of silence before a takeover
M.ANNOUNCE_INTERVAL = 10        -- re-announce the VIP this often while active
M.ANNOUNCE_BURST = 3            -- gratuitous ARP frames sent at takeover
M.ANNOUNCE_GAP = 0.5            -- seconds between those frames
M.TAKEOVER_COOLDOWN = 10        -- minimum seconds between two takeovers
M.PRIMARY_ANNOUNCE_EVERY = 10   -- primary re-announces the VIP this often
M.REDSTONE_SIDE = "bottom"      -- startup lock side
M.REDSTONE_POLL = 0.5           -- os.sleep while the lock is closed
M.IFACE_SIDE = "left"           -- modem side used by boot()
M.IFACE_NAME = "PUBLIC"         -- interface name used on the public wire
M.IFACE_CHANNEL = 4001          -- modem channel of the public wire
M.DHCP_PROBE = "0"              -- no ICMP conflict probe on a takeover (fast)
M.MIN_LEASE = 30
M.MAX_LEASE = 2592000           -- 30 days
M.MAX_MSG_BYTES = 512
M.MAX_TOKENS = 32
M.NONCE_KEEP = 8
M.MAX_BLOCKED = 16

M.PUBLIC_NET = "10.200.0.0"
M.PUBLIC_PREFIX = 24
M.MULTICAST_LO = 3758096384     -- 224.0.0.0
M.MULTICAST_HI = 4026531839     -- 239.255.255.255
M.IP_BROADCAST = 4294967295

-- the firewall blocks these destinations on the public side
M.BLOCK_NET = "192.168.0.0"
M.BLOCK_PREFIX = 16

-- what a primary reports when it has no DHCP server of its own
M.DEFAULT_DHCP_CONFIG = {
    pool_start = "10.200.0.50",
    pool_end = "10.200.0.150",
    lease_time = 600,
    gateway = "10.200.0.1",
    dns = "10.200.0.1",
    prefix = 24,
    dhcp_port = 6700,
}

-- last configuration received from the primary (the variable named in the spec)
M.synced_dhcp_config = nil

M.stats = { firewall_drops = 0 }
M.blocked = {}                  -- { net = <int>, prefix = <n>, text = "a.b.c.d/n" }
M.saved_nat_hook = nil
M.firewall_enabled = false
M.redstone_ready = false

-- ===== helpers ==============================================================
local floor = math.floor

local function log(node, fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    if type(node) == "table" and type(node.log) == "function" then
        pcall(node.log, node, "%s", line)
    else
        print("[" .. M.TAG .. "] " .. line)
    end
end

local function pick(t, key, fallback)
    local value = t[key]
    if value == nil then return fallback end
    return value
end

local function positive(value, fallback)
    local n = tonumber(value)
    if not n or n <= 0 then return fallback end
    return n
end

-- every HA timestamp goes through the runtime clock. opts.clock (or rt.clock,
-- the same hook core_router.lua:845 uses for its responder) lets a test or a
-- host inject one; without it the OS clock is read exactly as before.
local function now_of(rt)
    if type(rt) == "table" and type(rt.clock) == "function" then
        return rt.clock()
    end
    return os.clock()
end

-- ===== addresses ============================================================
-- strict dotted quad: no leading zeros, so "010.0.0.1" cannot mean two
-- different addresses in two different parsers
function M.parse_ipv4(text)
    if type(text) ~= "string" then return nil end
    local s = text:gsub("^%s+", ""):gsub("%s+$", "")
    local a, b, c, d = s:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
    if not a then return nil end
    local parts = { a, b, c, d }
    local values = {}
    for i = 1, 4 do
        local part = parts[i]
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
        local v = tonumber(part)
        if not v or v > 255 then return nil end
        values[i] = v
    end
    return values[1] * 16777216 + values[2] * 65536 + values[3] * 256 + values[4]
end

function M.int2ip(n)
    n = floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    if n > M.IP_BROADCAST then n = M.IP_BROADCAST end
    return string.format("%d.%d.%d.%d",
        floor(n / 16777216) % 256, floor(n / 65536) % 256,
        floor(n / 256) % 256, n % 256)
end

function M.in_subnet(ip, net, prefix)
    if type(ip) ~= "number" or type(net) ~= "number" then return false end
    local bits = tonumber(prefix)
    if not bits or bits < 0 or bits > 32 then return false end
    if bits == 0 then return true end
    local size = 2 ^ (32 - bits)
    return (ip - (ip % size)) == (net - (net % size))
end

M.PUBLIC_NET_INT = M.parse_ipv4(M.PUBLIC_NET)

function M.is_public(ip)
    return type(ip) == "number" and M.in_subnet(ip, M.PUBLIC_NET_INT, M.PUBLIC_PREFIX)
end

local function usable_host(ip)
    if type(ip) ~= "number" then return false end
    if ip <= 0 or ip >= M.IP_BROADCAST then return false end
    if ip >= M.MULTICAST_LO and ip <= M.MULTICAST_HI then return false end
    return true
end

-- ===== wire protocol ========================================================
function M.build_request(id, nonce)
    return string.format("%s SYNC id=%d nonce=%d", M.PROTO, floor(id or 0), floor(nonce or 0))
end

function M.build_reply(cfg, to_id, nonce, master_id)
    return table.concat({
        M.PROTO,
        "CFG",
        "master=" .. tostring(floor(master_id or 0)),
        "to=" .. tostring(floor(to_id or 0)),
        "nonce=" .. tostring(floor(nonce or 0)),
        "pool_start=" .. tostring(cfg.pool_start),
        "pool_end=" .. tostring(cfg.pool_end),
        "lease_time=" .. tostring(floor(cfg.lease_time or 600)),
        "gateway=" .. tostring(cfg.gateway),
        "dns=" .. tostring(cfg.dns),
        "prefix=" .. tostring(floor(cfg.prefix or 24)),
        "dhcp_port=" .. tostring(floor(cfg.dhcp_port or 6700)),
        "uptime=" .. tostring(floor(os.clock())),
    }, " ")
end

function M.parse_message(text)
    if type(text) ~= "string" or text == "" then return nil, "empty datagram" end
    if #text > M.MAX_MSG_BYTES then return nil, "datagram too large" end
    local tokens = {}
    for token in text:gmatch("%S+") do
        tokens[#tokens + 1] = token
        if #tokens > M.MAX_TOKENS then return nil, "too many fields" end
    end
    if tokens[1] ~= M.PROTO then return nil, "protocol mismatch" end
    if tokens[2] ~= "SYNC" and tokens[2] ~= "CFG" then
        return nil, "unknown message kind " .. tostring(tokens[2])
    end
    local msg = { kind = tokens[2], fields = {} }
    for i = 3, #tokens do
        local key, value = tokens[i]:match("^([%w_]+)=(.+)$")
        if not key then return nil, "malformed field " .. tostring(tokens[i]) end
        if msg.fields[key] then return nil, "duplicate field " .. key end
        msg.fields[key] = value
    end
    return msg
end

function M.config_text(cfg)
    return string.format("pool=%s-%s lease=%ds gw=%s dns=%s prefix=%d port=%d",
        tostring(cfg.pool_start), tostring(cfg.pool_end), floor(cfg.lease_time or 0),
        tostring(cfg.gateway), tostring(cfg.dns), floor(cfg.prefix or 0),
        floor(cfg.dhcp_port or 0))
end

-- validate the CFG fields into a configuration table. Missing optional fields
-- are filled by the caller (on_sync_reply) because it knows the local interface.
function M.parse_config(fields)
    if type(fields) ~= "table" then return nil, "no fields" end

    local function address(name, required)
        local text = fields[name]
        if text == nil then
            if required then return nil, name .. " is missing" end
            return nil
        end
        local ip = M.parse_ipv4(text)
        if not ip then return nil, name .. " is not an IPv4 address" end
        if not usable_host(ip) then return nil, name .. " is not a usable host address" end
        return ip
    end

    local start_ip, err = address("pool_start", true)
    if not start_ip then return nil, err end
    local end_ip
    end_ip, err = address("pool_end", true)
    if not end_ip then return nil, err end
    if start_ip > end_ip then return nil, "pool_start is above pool_end" end

    local lease = tonumber(fields.lease_time)
    if not lease or lease < M.MIN_LEASE or lease > M.MAX_LEASE then
        return nil, "lease_time is out of range (" .. M.MIN_LEASE .. ".." .. M.MAX_LEASE .. ")"
    end

    local prefix = nil
    if fields.prefix ~= nil then
        prefix = tonumber(fields.prefix)
        if not prefix or prefix < 8 or prefix > 30 then return nil, "prefix is out of range" end
    end

    local port = nil
    if fields.dhcp_port ~= nil then
        port = tonumber(fields.dhcp_port)
        if not port or port < 1 or port > 65535 then return nil, "dhcp_port is out of range" end
    end

    local gateway
    gateway, err = address("gateway", false)
    if err then return nil, err end
    local dns
    dns, err = address("dns", false)
    if err then return nil, err end

    return {
        pool_start = M.int2ip(start_ip),
        pool_end = M.int2ip(end_ip),
        pool_start_int = start_ip,
        pool_end_int = end_ip,
        lease_time = floor(lease),
        gateway = gateway and M.int2ip(gateway) or nil,
        dns = dns and M.int2ip(dns) or nil,
        prefix = prefix,
        dhcp_port = port,
    }
end

-- ===== firewall (192.168.0.0/16 on the public side) =========================
local function rebuild_blocked_text()
    local parts = {}
    for i, entry in ipairs(M.blocked) do parts[i] = entry.text end
    return table.concat(parts, ",")
end

function M.add_blocked(net, prefix)
    local n = M.parse_ipv4(net)
    local bits = tonumber(prefix) or 32
    if not n or bits < 0 or bits > 32 then return nil, "bad range" end
    if #M.blocked >= M.MAX_BLOCKED then return nil, "too many blocked ranges" end
    for _, entry in ipairs(M.blocked) do
        if entry.net == n and entry.prefix == bits then return true end
    end
    M.blocked[#M.blocked + 1] = {
        net = n, prefix = bits, text = M.int2ip(n) .. "/" .. bits,
    }
    return true
end

function M.clear_blocked()
    M.blocked = {}
end

function M.is_blocked(ip)
    for _, entry in ipairs(M.blocked) do
        if M.in_subnet(ip, entry.net, entry.prefix) then return true end
    end
    return false
end

function M.blocked_text()
    return rebuild_blocked_text()
end

-- the predicate shared by the rpv hook and the node.ip_deliver fallback
function M.firewall_drop(node, iface, h)
    if not M.firewall_enabled then return false end
    if type(h) ~= "table" or type(h.dst) ~= "number" then return false end
    if not M.is_blocked(h.dst) then return false end
    local from_public = (type(iface) == "table" and M.is_public(iface.ip)) or M.is_public(h.src)
    if not from_public then return false end
    M.stats.firewall_drops = M.stats.firewall_drops + 1
    log(node, "FIREWALL_DROP src=%s dst=%s proto=%s iface=%s blocked=%s",
        M.int2ip(h.src), M.int2ip(h.dst), tostring(h.proto),
        tostring(type(iface) == "table" and iface.name or iface), M.blocked_text())
    return true
end

function M.nat_input_hook(node, iface, h, payload)
    if M.firewall_drop(node, iface, h) then return "drop" end
    if type(M.saved_nat_hook) == "function" then
        return M.saved_nat_hook(node, iface, h, payload)
    end
    return nil
end

function M.install_firewall(node, rpv, opts)
    if opts and opts.firewall == false then
        M.firewall_enabled = false
        log(node, "HA_FIREWALL_OFF")
        return "off"
    end
    if type(M.blocked) ~= "table" or #M.blocked == 0 then
        M.add_blocked(M.BLOCK_NET, M.BLOCK_PREFIX)
    end
    M.firewall_enabled = true

    if type(rpv) == "table" and rpv.nat_input_hook ~= M.nat_input_hook then
        if rpv.nat_input_hook == nil or type(rpv.nat_input_hook) == "function" then
            M.saved_nat_hook = rpv.nat_input_hook
            rpv.nat_input_hook = M.nat_input_hook
            log(node, "HA_FIREWALL_READY mode=rpv blocked=%s", M.blocked_text())
            return "rpv"
        end
    end

    if type(node.ip_deliver) == "function" and not node.ha_ip_guard then
        local base = node.ip_deliver
        node.ip_deliver = function(self, iface, h, payload)
            if M.firewall_drop(self, iface, h) then return end
            return base(self, iface, h, payload)
        end
        node.ha_ip_guard = true
        log(node, "HA_FIREWALL_READY mode=node blocked=%s", M.blocked_text())
        return "node"
    end

    log(node, "HA_FIREWALL_FAIL reason=no hook available")
    return nil
end

-- ===== DHCP state (standby keeps it off, takeover starts it) ================
-- rpv services read these keys from node.cfg, so a takeover is: write the
-- synced values into the cfg and call rpv.dhcp_server_start().
function M.stop_dhcp(node)
    local srv = node.ha_dhcp_srv or node.dhcp_server
    node.ha_dhcp_active = false
    if type(srv) ~= "table" then return false end
    srv.stopped = true
    if type(srv.sk) == "table" and type(srv.sk.close) == "function" then
        pcall(srv.sk.close, srv.sk)
    end
    -- the expiry sweeper of rpv keeps running on this table; emptying it makes
    -- the sweeper a no-op without touching the library
    srv.by_ip = {}
    srv.by_client = {}
    node.dhcp_server = nil
    node.dhcp = nil
    node.ha_dhcp_srv = nil
    if type(node.cfg) == "table" then node.cfg.dhcp_pool = nil end
    return true
end

function M.start_dhcp(rt, cfg)
    local node, rpv = rt.node, rt.rpv
    M.stop_dhcp(node)

    node.cfg.dhcp_pool = cfg.pool_start .. "-" .. cfg.pool_end
    node.cfg.dhcp_gw = cfg.gateway
    node.cfg.dhcp_dns = cfg.dns
    node.cfg.dhcp_lease = tostring(cfg.lease_time)
    node.cfg.dhcp_port = tostring(cfg.dhcp_port)
    node.cfg.dhcp_probe = M.DHCP_PROBE

    local ok, srv = pcall(rpv.dhcp_server_start, node, {})
    if not ok then
        node.cfg.dhcp_pool = nil
        return nil, tostring(srv)
    end
    if type(srv) ~= "table" then
        node.cfg.dhcp_pool = nil
        return nil, "dhcp_server_start returned no server"
    end

    -- guard the bound handler: a stopped instance can never answer, even if a
    -- stale socket reference survives somewhere in the node
    node.ha_dhcp_active = true
    local sk = srv.sk
    if type(sk) == "table" and type(sk.handler) == "function" then
        local base = sk.handler
        sk.handler = function(data, src, sport)
            if not node.ha_dhcp_active then return end
            return base(data, src, sport)
        end
    end
    node.ha_dhcp_srv = srv
    return srv
end

-- The interface whose address a primary reports as the client gateway. It has
-- to be the public side: rpv lists the LAN interface first on a real box, so
-- node.ifaces[1] alone would sync 192.168.1.1 (the LAN gateway) to the backup
-- and hand LAN addresses to every DHCP client on the public wire.
--   1. explicit configuration: cfg.public_iface may be an interface name, an
--      address string or an address number
--   2. the public wire itself (10.200.0.0/24, M.IFACE_NAME first)
--   3. nothing public on this node: the historical first-interface fallback
function M.gateway_iface(node, cfg)
    local list = type(node) == "table" and node.ifaces or nil
    if type(list) ~= "table" then list = {} end

    local want = type(cfg) == "table" and cfg.public_iface or nil
    if type(want) == "table" then return want end
    if type(want) == "string" and want ~= "" then
        local addr = M.parse_ipv4(want)
        for _, iface in ipairs(list) do
            if type(iface) == "table" and addr and iface.ip == addr then return iface end
        end
        for _, iface in ipairs(list) do
            if type(iface) == "table" and iface.name == want then return iface end
        end
    elseif type(want) == "number" then
        for _, iface in ipairs(list) do
            if type(iface) == "table" and iface.ip == want then return iface end
        end
    end

    local pub = M.find_public_iface(node)
    if type(pub) == "table" and type(pub.ip) == "number" and M.is_public(pub.ip) then
        return pub
    end
    return list[1]
end

-- what a primary reports to a backup: the live server first, then role.txt keys,
-- then the built-in defaults
function M.dhcp_config_from_node(node)
    if type(node) ~= "table" then return M.copy_config(M.DEFAULT_DHCP_CONFIG) end
    local srv = node.dhcp_server
    if type(srv) == "table" and type(srv.lo) == "number" then
        return {
            pool_start = M.int2ip(srv.lo),
            pool_end = M.int2ip(srv.hi),
            lease_time = tonumber(srv.lease) or 600,
            gateway = M.int2ip(srv.gw),
            dns = M.int2ip(srv.dns),
            prefix = tonumber(srv.prefix) or 24,
            dhcp_port = tonumber(srv.port) or 6700,
        }
    end

    local cfg = node.cfg or {}
    local pool = tostring(cfg.dhcp_pool or "")
    local lo, hi = pool:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)%s*$")
    local iface = M.gateway_iface(node, cfg)
    local local_ip = type(iface) == "table" and type(iface.ip) == "number"
        and M.int2ip(iface.ip) or M.MASTER_IP
    if lo and M.parse_ipv4(lo) and M.parse_ipv4(hi) then
        local gw = cfg.dhcp_gw or local_ip
        return {
            pool_start = lo,
            pool_end = hi,
            lease_time = tonumber(cfg.dhcp_lease) or 600,
            gateway = gw,
            dns = cfg.dhcp_dns or gw,
            prefix = type(iface) == "table" and (tonumber(iface.prefix) or 24) or 24,
            dhcp_port = tonumber(cfg.dhcp_port) or 6700,
        }
    end

    local d = M.DEFAULT_DHCP_CONFIG
    return {
        pool_start = d.pool_start, pool_end = d.pool_end, lease_time = d.lease_time,
        gateway = local_ip, dns = local_ip, prefix = d.prefix, dhcp_port = d.dhcp_port,
    }
end

function M.copy_config(cfg)
    return {
        pool_start = cfg.pool_start, pool_end = cfg.pool_end,
        lease_time = cfg.lease_time, gateway = cfg.gateway, dns = cfg.dns,
        prefix = cfg.prefix, dhcp_port = cfg.dhcp_port,
    }
end

-- ===== ARP for the VIP ======================================================
-- Gratuitous ARP: op 2 (reply), sender is us, sender/target IP is the VIP, and
-- the frame goes to the broadcast MAC, so every neighbour replaces its cache
-- entry for the gateway. Built by hand because rpv.arp_send() uses iface.ip as
-- the sender address and the VIP is the address that must be announced.
function M.announce(rt, count, why)
    local node, rpv = rt.node, rt.rpv
    local total = tonumber(count) or 0
    if total <= 0 then return 0 end
    local sent = 0
    for n = 1, total do
        for _, iface in ipairs(node.ifaces or {}) do
            if iface == rt.public_iface or iface.ip == rt.vip then
                local body = rpv.u16(2)
                    .. rpv.u32(node.mac)
                    .. rpv.u32(rt.vip)
                    .. rpv.u32(rpv.MAC_BCAST)
                    .. rpv.u32(rt.vip)
                rpv.link_send(node, iface, rpv.MAC_BCAST, rpv.ET_ARP, body)
                sent = sent + 1
                log(node, "HA_ARP_ANNOUNCE n=%d/%d iface=%s ip=%s mac=%08X reason=%s",
                    n, total, tostring(iface.name), M.int2ip(rt.vip), node.mac, tostring(why))
            end
        end
        if n < total and (rt.opt.announce_gap or 0) > 0 then
            os.sleep(rt.opt.announce_gap)
        end
    end
    rt.stats.arp_announce = (rt.stats.arp_announce or 0) + sent
    return sent
end

-- While the box is on standby it must not answer ARP for the VIP, otherwise
-- clients can send gateway traffic to a machine that is not serving. The guard
-- only inspects incoming ARP *requests* for the VIP and drops them silently.
function M.install_arp_guard(node, rpv)
    if node.ha_arp_guard then return true end
    if type(node.on_frame) ~= "function" then return false, "node.on_frame is missing" end
    local base = node.on_frame
    local guard = function(self, iface, frame)
        local rt = self.ha
        if type(rt) == "table" and rt.mode == "STANDBY" and type(frame) == "string" then
            local dstmac, srcmac, etype, body = rpv.link_parse(frame)
            if dstmac and etype == rpv.ET_ARP and type(body) == "string" and #body >= 18
                and rpv.r16(body, 1) == 1 and rpv.r32(body, 15) == rt.vip then
                rt.stats.arp_suppressed = (rt.stats.arp_suppressed or 0) + 1
                return
            end
        end
        return base(self, iface, frame)
    end
    node.on_frame = guard
    node.ha_arp_guard = guard
    return true
end

-- ===== options ==============================================================
function M.options(opts)
    local base = opts or {}
    local o = {
        role = tostring(pick(base, "role", "standby")),
        master_ip = tostring(pick(base, "master_ip", M.MASTER_IP)),
        local_cidr = tostring(pick(base, "local_cidr", M.CIDR)),
        iface_name = tostring(pick(base, "iface_name", M.IFACE_NAME)),
        side = tostring(pick(base, "side", M.IFACE_SIDE)),
        channel = tonumber(pick(base, "channel", M.IFACE_CHANNEL)),
        sync_port = tonumber(pick(base, "sync_port", M.SYNC_PORT)),
        interval = positive(pick(base, "interval", M.SYNC_INTERVAL), M.SYNC_INTERVAL),
        fail_limit = positive(pick(base, "fail_limit", M.FAIL_LIMIT), M.FAIL_LIMIT),
        takeover_after = positive(pick(base, "takeover_after", M.TAKEOVER_AFTER), M.TAKEOVER_AFTER),
        announce_interval = positive(pick(base, "announce_interval", M.ANNOUNCE_INTERVAL), M.ANNOUNCE_INTERVAL),
        announce_burst = tonumber(pick(base, "announce_burst", M.ANNOUNCE_BURST)) or 0,
        announce_gap = tonumber(pick(base, "announce_gap", M.ANNOUNCE_GAP)) or 0,
        cooldown = tonumber(pick(base, "cooldown", M.TAKEOVER_COOLDOWN)) or 0,
        redstone_side = pick(base, "redstone_side", M.REDSTONE_SIDE),
        firewall = pick(base, "firewall", true),
        responder = pick(base, "responder", nil),
        clock = pick(base, "clock", nil),
    }
    o.fail_limit = floor(o.fail_limit)
    if not o.sync_port or o.sync_port < 1 or o.sync_port > 65535 then o.sync_port = M.SYNC_PORT end
    if not o.channel or o.channel < 1 then o.channel = M.IFACE_CHANNEL end
    if o.redstone_side == false then o.redstone_side = "none" end
    if o.responder == nil then o.responder = (o.role == "primary") end
    if type(o.clock) ~= "function" then o.clock = nil end
    return o
end

-- ===== redstone lock ========================================================
function M.redstone_input(side)
    local api = rawget(_G, "rs")
    if type(api) ~= "table" then api = rawget(_G, "redstone") end
    if type(api) ~= "table" or type(api.getInput) ~= "function" then
        return false, "redstone API is unavailable"
    end
    local ok, value = pcall(api.getInput, side or M.REDSTONE_SIDE)
    if not ok then return false, tostring(value) end
    return value and true or false
end

-- blocks until the BOTTOM face is powered; there is no timeout and no override.
-- M.redstone_ready makes the second call (boot -> start_router) a no-op so the
-- opening is logged exactly once.
function M.wait_for_redstone(node, side)
    local lock_side = side or M.REDSTONE_SIDE
    if M.redstone_ready then return true end
    if lock_side == "none" or lock_side == false then
        M.redstone_ready = true
        log(node, "HA_REDSTONE_SKIP side=none")
        return true
    end
    local started = os.clock()
    local announced = false
    while true do
        local on, err = M.redstone_input(lock_side)
        if on then
            M.redstone_ready = true
            log(node, "HA_REDSTONE_ON side=%s waited=%.1fs", lock_side, os.clock() - started)
            return true
        end
        if not announced then
            announced = true
            if err then
                log(node, "HA_REDSTONE_LOCK side=%s waiting (%s)", lock_side, tostring(err))
            else
                log(node, "HA_REDSTONE_LOCK side=%s waiting for power", lock_side)
            end
        end
        os.sleep(M.REDSTONE_POLL)
    end
end

-- ===== module lookup ========================================================
local function looks_like_rpv(t)
    return type(t) == "table"
        and (type(t.udp_send) == "function" or type(t.dhcp_server_start) == "function")
end

function M.find_rpv(node)
    if type(node) == "table" and looks_like_rpv(node.rpv) then return node.rpv end
    if looks_like_rpv(rawget(_G, "rpv")) then return rawget(_G, "rpv") end
    local package_table = rawget(_G, "package")
    if type(package_table) == "table" and type(package_table.loaded) == "table" then
        if looks_like_rpv(package_table.loaded.rpv) then return package_table.loaded.rpv end
    end
    return nil
end

function M.find_public_iface(node, opt)
    local list = node.ifaces or {}
    local wanted = opt and opt.iface_name or M.IFACE_NAME
    for _, iface in ipairs(list) do
        if type(iface.ip) == "number" and M.is_public(iface.ip) and iface.name == wanted then
            return iface
        end
    end
    for _, iface in ipairs(list) do
        if type(iface.ip) == "number" and M.is_public(iface.ip) then return iface end
    end
    for _, iface in ipairs(list) do
        if iface.name == wanted then return iface end
    end
    return list[1]
end

-- ===== HA runtime ===========================================================
local function track_nonce(rt, nonce)
    rt.nonces[nonce] = true
    rt.nonce_order[#rt.nonce_order + 1] = nonce
    while #rt.nonce_order > M.NONCE_KEEP do
        local old = table.remove(rt.nonce_order, 1)
        rt.nonces[old] = nil
    end
end

local function store_synced(rt, cfg)
    M.synced_dhcp_config = cfg
    rt.synced_dhcp_config = cfg
    rt.node.synced_dhcp_config = cfg
    if type(_G) == "table" then _G.synced_dhcp_config = cfg end
end

-- one sync request. In shared-VIP mode the address is the limited broadcast:
-- see the header for why a unicast would be delivered to ourselves.
function M.send_sync_request(rt, now)
    local at = now or now_of(rt)
    rt.seq = rt.seq + 1
    local nonce = (rt.node.id % 100000) * 1000000 + (rt.seq % 1000000)
    local dst = rt.master
    if rt.shared then dst = rt.rpv.IP_BCAST end
    local message = M.build_request(rt.node.id, nonce)
    rt.stats.sync_tx = rt.stats.sync_tx + 1
    rt.pending_nonce = nonce
    rt.pending_sent = at
    track_nonce(rt, nonce)

    local ok, err = pcall(rt.rpv.udp_send, rt.node, dst, rt.opt.sync_port, rt.opt.sync_port, message)
    if not ok then
        rt.stats.sync_tx_fail = (rt.stats.sync_tx_fail or 0) + 1
        log(rt.node, "HA_SYNC_BAD reason=send err=%s", tostring(err))
        return nil
    end
    if rt.stats.sync_tx == 1 or rt.stats.sync_tx % 12 == 0 then
        log(rt.node, "HA_SYNC_TX n=%d master=%s dst=%s nonce=%d port=%d misses=%d",
            rt.stats.sync_tx, M.int2ip(rt.master), M.int2ip(dst), nonce, rt.opt.sync_port, rt.misses)
    end
    return nonce
end

-- is a takeover due? three misses AND the full silent window, exactly the rule
-- in the spec (3 x 5 s = 15 s). Pure function so it can be tested offline.
function M.evaluate(rt, now)
    if type(rt) ~= "table" or type(rt.opt) ~= "table" then return false end
    if rt.mode ~= "STANDBY" then return false end
    if (rt.misses or 0) < rt.opt.fail_limit then return false end
    local anchor = rt.last_master_seen or rt.started_at or 0
    return ((now or now_of(rt)) - anchor) >= rt.opt.takeover_after
end

function M.takeover(rt, why)
    if type(rt) ~= "table" or rt.role ~= "standby" or rt.mode == "ACTIVE" then return false end
    local node = rt.node
    if not rt.shared then
        log(node, "TAKEOVER_ABORT reason=vip_not_local local=%s master=%s",
            M.int2ip(rt.vip), M.int2ip(rt.master))
        return false
    end
    local cfg = rt.synced_dhcp_config
    if type(cfg) ~= "table" then
        rt.stats.takeover_aborts = (rt.stats.takeover_aborts or 0) + 1
        if rt.stats.takeover_aborts == 1 or rt.stats.takeover_aborts % 6 == 0 then
            log(node, "TAKEOVER_ABORT reason=no_synced_config (nothing has been synced yet)")
        end
        return false
    end
    local now = now_of(rt)
    if rt.last_change and (now - rt.last_change) < rt.opt.cooldown then
        log(node, "HA_TAKEOVER_HOLD cooldown=%.1fs left=%.1fs",
            rt.opt.cooldown, rt.opt.cooldown - (now - rt.last_change))
        return false
    end
    if cfg.dhcp_port == rt.opt.sync_port then
        log(node, "TAKEOVER_ABORT reason=dhcp_port_collision port=%d", cfg.dhcp_port)
        return false
    end
    if rt.public_iface.net and rt.public_iface.prefix
        and not M.in_subnet(cfg.pool_start_int or M.parse_ipv4(cfg.pool_start),
            rt.public_iface.net, rt.public_iface.prefix) then
        log(node, "HA_DHCP_POOL_OFF_SUBNET pool=%s-%s subnet=%s/%d",
            cfg.pool_start, cfg.pool_end, M.int2ip(rt.public_iface.net), rt.public_iface.prefix)
    end
    if rt.public_iface.prefix and cfg.prefix and cfg.prefix ~= rt.public_iface.prefix then
        log(node, "HA_DHCP_PREFIX_SYNCED synced=%d iface=%d (rpv serves the interface prefix)",
            cfg.prefix, rt.public_iface.prefix)
    end

    local srv, err = M.start_dhcp(rt, cfg)
    if not srv then
        log(node, "TAKEOVER_ABORT reason=dhcp_start err=%s", tostring(err))
        return false
    end

    rt.mode = "ACTIVE"
    rt.dhcp_server = srv
    rt.last_change = now
    rt.next_announce = now + rt.opt.announce_interval
    rt.stats.takeovers = rt.stats.takeovers + 1
    node.ha_active = true

    log(node, "TAKEOVER_ACTIVE reason=%s misses=%d silent=%.1fs %s",
        tostring(why), rt.misses, now - (rt.last_master_seen or rt.started_at),
        M.config_text(cfg))
    M.announce(rt, rt.opt.announce_burst, "takeover")
    return true
end

function M.standby(rt, why, master_id)
    if type(rt) ~= "table" or rt.role == "primary" then return false end
    local node = rt.node
    local was_active = (rt.mode == "ACTIVE")
    local srv = rt.dhcp_server
    if type(srv) ~= "table" and type(node) == "table" then
        srv = node.ha_dhcp_srv or node.dhcp_server
    end
    local serving = (type(srv) == "table")
    local served = serving and (tonumber(srv.leases) or 0) or 0

    rt.mode = "STANDBY"
    rt.last_change = now_of(rt)
    node.ha_active = false

    -- an idle standby has no DHCP service to stop, and stop_dhcp() also clears
    -- node.cfg.dhcp_pool (the pool role.txt configured locally) whenever a
    -- server table is still around. Only a box that was actually serving
    -- loses its DHCP state and its pool.
    if not (was_active or serving) then
        log(node, "STANDBY_MODE reason=%s master=%s (already idle, nothing to stop)",
            tostring(why), tostring(master_id))
        return false
    end

    M.stop_dhcp(node)
    rt.dhcp_server = nil
    rt.stats.standbys = (rt.stats.standbys or 0) + 1
    log(node, "HA_DHCP_STOP leases_served=%d", served)
    log(node, "STANDBY_MODE reason=%s master=%s (local DHCP stopped, VIP ARP answers suppressed)",
        tostring(why), tostring(master_id))
    return true
end

function M.on_sync_reply(rt, msg, src)
    local node = rt.node
    local f = msg.fields
    if tonumber(f.master) == node.id then return end       -- our own broadcast
    if f.to and tonumber(f.to) ~= node.id then return end  -- addressed to a peer
    local nonce = tonumber(f.nonce)
    if not nonce then
        log(node, "HA_SYNC_BAD src=%s reason=no_nonce", M.int2ip(src))
        return
    end
    if not (rt.nonces[nonce] or rt.pending_nonce == nonce) then
        rt.stats.sync_stale = (rt.stats.sync_stale or 0) + 1
        return
    end

    local cfg, err = M.parse_config(f)
    if not cfg then
        rt.stats.sync_bad = (rt.stats.sync_bad or 0) + 1
        log(node, "HA_SYNC_BAD src=%s reason=%s", M.int2ip(src), tostring(err))
        return
    end

    -- fill the fields the primary may omit with local knowledge
    cfg.gateway = cfg.gateway or M.int2ip(rt.vip)
    cfg.dns = cfg.dns or cfg.gateway
    cfg.prefix = cfg.prefix or rt.public_iface.prefix or M.PUBLIC_PREFIX
    cfg.dhcp_port = cfg.dhcp_port or M.DEFAULT_DHCP_CONFIG.dhcp_port
    if cfg.dhcp_port == rt.opt.sync_port then
        log(node, "HA_SYNC_BAD src=%s reason=dhcp_port_collision port=%d",
            M.int2ip(src), cfg.dhcp_port)
        return
    end
    local at = now_of(rt)
    cfg.master_id = tonumber(f.master)
    cfg.master_uptime = tonumber(f.uptime)
    cfg.synced_at = at

    local changed = (rt.config_text ~= M.config_text(cfg))
    rt.config_text = M.config_text(cfg)
    store_synced(rt, cfg)

    rt.stats.sync_rx = rt.stats.sync_rx + 1
    rt.misses = 0
    rt.last_master_seen = at
    rt.last_master_id = cfg.master_id
    if rt.pending_nonce == nonce then rt.pending_nonce = nil end

    if changed or rt.stats.sync_rx == 1 or rt.stats.sync_rx % 12 == 0 then
        log(node, "SYNCED_DHCP_CONFIG %s master=%s uptime=%s",
            M.config_text(cfg), tostring(cfg.master_id), tostring(cfg.master_uptime))
    end
    -- a valid CFG means the primary is alive: this box must not be serving.
    -- An already idle standby has nothing to normalise, so it is not called
    -- there (that would only repeat STANDBY_MODE on every 5 s sync).
    local serving = type(rt.dhcp_server) == "table"
    if not serving and type(node) == "table" then
        serving = type(node.ha_dhcp_srv) == "table" or type(node.dhcp_server) == "table"
    end
    if rt.mode ~= "STANDBY" or serving then
        M.standby(rt, "master_recovered", cfg.master_id)
    end
end

function M.on_sync_request(rt, msg, src, sport)
    local node = rt.node
    local want = tonumber(msg.fields.id)
    if not want or want == node.id then return end
    local nonce = tonumber(msg.fields.nonce) or 0
    local cfg = M.dhcp_config_from_node(node)
    local reply = M.build_reply(cfg, want, nonce, node.id)
    local dst = src
    if rt.shared and type(src) == "number" and src == rt.vip then
        dst = rt.rpv.IP_BCAST
    end
    local ok, err = pcall(rt.rpv.udp_send, node, dst, rt.opt.sync_port, sport or rt.opt.sync_port, reply)
    if not ok then
        log(node, "HA_SYNC_REPLY_FAIL to=%d err=%s", want, tostring(err))
        return
    end
    rt.stats.sync_replies = (rt.stats.sync_replies or 0) + 1
    if rt.stats.sync_replies == 1 or rt.stats.sync_replies % 12 == 0 then
        log(node, "HA_SYNC_REPLY to=%d nonce=%d %s", want, nonce, M.config_text(cfg))
    end
    if rt.role == "primary" then
        local now = now_of(rt)
        if now - (rt.last_announce or -1e9) >= M.PRIMARY_ANNOUNCE_EVERY then
            rt.last_announce = now
            M.announce(rt, 1, "primary_online")
        end
    end
end

function M.on_datagram(rt, data, src, sport)
    local msg, err = M.parse_message(data)
    if not msg then
        rt.stats.sync_bad = (rt.stats.sync_bad or 0) + 1
        log(rt.node, "HA_SYNC_BAD src=%s reason=%s", M.int2ip(src), tostring(err))
        return
    end
    if msg.kind == "CFG" then
        M.on_sync_reply(rt, msg, src)
    elseif msg.kind == "SYNC" and rt.opt.responder then
        M.on_sync_request(rt, msg, src, sport)
    end
end

-- one 5 s cycle of the background coroutine: judge the outstanding request,
-- send the next one, take over when the silent window is over, re-announce the
-- VIP while active
function M.ha_tick(rt, now)
    if type(rt) ~= "table" or not rt.started then return nil, "runtime is not started" end
    local at = now or now_of(rt)
    local node = rt.node

    if rt.role ~= "primary" then
        M.send_sync_request(rt, at)
        -- one full silent interval is one missed round, so three 5 s rounds are
        -- the 15 s TAKEOVER_AFTER documents. The count is taken after the send:
        -- a reply that arrived on this tick has already reset the anchor (an
        -- answered round is never a miss), and the fail limit can only be
        -- reached once the whole silent window has really passed.
        local anchor = rt.last_master_seen or rt.started_at or at
        local silent = at - anchor
        if silent >= rt.opt.interval then
            local missed = floor(silent / rt.opt.interval)
            if missed > rt.opt.fail_limit then missed = rt.opt.fail_limit end
            if missed > rt.misses then
                rt.misses = missed
                log(node, "HA_SYNC_MISS n=%d/%d silent=%.1fs",
                    rt.misses, rt.opt.fail_limit, silent)
            end
        end
        if rt.mode ~= "ACTIVE" and M.evaluate(rt, at) then
            M.takeover(rt, "master_timeout")
        end
    end

    if rt.mode == "ACTIVE" and at >= (rt.next_announce or 0) then
        M.announce(rt, 1, "renew")
        rt.next_announce = at + rt.opt.announce_interval
    end
    return { sent = rt.stats.sync_tx, misses = rt.misses, mode = rt.mode }
end

-- ===== entry point ==========================================================
function M.start_router(node, rpv, opts)
    if type(node) ~= "table" then return nil, "node table is required" end
    if type(node.ha) == "table" and node.ha.started then return node.ha end

    rpv = rpv or M.find_rpv(node)
    if type(rpv) ~= "table" then
        return nil, "rpv module table is required (pass it as the second argument)"
    end
    if type(rpv.udp_send) ~= "function" or type(rpv.link_send) ~= "function" then
        return nil, "rpv is missing udp_send/link_send"
    end
    local missing = {}
    for _, name in ipairs({ "u16", "u32", "r16", "r32", "link_parse", "link_send" }) do
        if type(rpv[name]) ~= "function" then missing[#missing + 1] = name end
    end
    for _, name in ipairs({ "IP_BCAST", "MAC_BCAST", "ET_ARP" }) do
        if type(rpv[name]) ~= "number" then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        return nil, "rpv is missing " .. table.concat(missing, ",")
    end

    local opt = M.options(opts or {})
    local standby = (opt.role ~= "primary")
    if standby and type(rpv.dhcp_server_start) ~= "function" then
        return nil, "rpv.dhcp_server_start is required"
    end

    -- 1. startup lock: nothing below runs while the bottom face is unpowered
    M.wait_for_redstone(node, opt.redstone_side)

    local pub = M.find_public_iface(node, opt)
    if type(pub) ~= "table" or type(pub.ip) ~= "number" then
        return nil, "no usable interface (expected cidr " .. opt.local_cidr .. ")"
    end
    local master = M.parse_ipv4(opt.master_ip)
    if not master then return nil, "bad master_ip '" .. tostring(opt.master_ip) .. "'" end

    local rt = {
        node = node, rpv = rpv, opt = opt,
        role = opt.role, mode = (opt.role == "primary") and "PRIMARY" or "STANDBY",
        public_iface = pub, vip = pub.ip, master = master,
        shared = (master == pub.ip),
        clock = opt.clock,
        started_at = 0, last_change = nil,
        misses = 0, seq = 0, nonces = {}, nonce_order = {},
        pending_nonce = nil, pending_sent = nil,
        synced_dhcp_config = nil, config_text = "",
        dhcp_server = nil, socket = nil, started = false,
        stats = {
            sync_tx = 0, sync_rx = 0, sync_replies = 0, sync_bad = 0,
            sync_stale = 0, sync_tx_fail = 0, takeovers = 0, takeover_aborts = 0,
            standbys = 0, arp_announce = 0, arp_suppressed = 0,
        },
    }
    rt.started_at = now_of(rt)
    node.ha = rt
    node.synced_dhcp_config = nil
    node.ha_active = (rt.mode == "ACTIVE") or (rt.mode == "PRIMARY")

    -- 2. a standby never serves DHCP, even if role.txt asked for it
    if standby then
        local old = node.dhcp_server
        if type(old) == "table" then
            local lo, hi = M.int2ip(old.lo), M.int2ip(old.hi)
            M.stop_dhcp(node)
            log(node, "STANDBY_DHCP_OFF pool=%s-%s (standby keeps DHCP off)", lo, hi)
        else
            log(node, "STANDBY_DHCP_OFF (no DHCP server running)")
        end
    end

    -- 3. RPV1 firewall in front of the forwarding path
    M.install_firewall(node, rpv, opt)

    -- 4. do not answer ARP for the VIP while on standby
    local guarded, guard_err = M.install_arp_guard(node, rpv)
    if not guarded then
        log(node, "HA_ARP_GUARD_FAIL reason=%s", tostring(guard_err))
    end

    -- 5. sync socket and the background coroutine
    if node.udp and node.udp.ports and node.udp.ports[opt.sync_port] then
        log(node, "HA_PORT_TAKEN port=%d (rebinding)", opt.sync_port)
    end
    rt.socket = node:bind(opt.sync_port, function(data, src, sport)
        M.on_datagram(rt, data, src, sport)
    end)
    if type(rt.socket) ~= "table" then
        return nil, "cannot bind sync port " .. tostring(opt.sync_port)
    end

    if not rt.shared then
        log(node, "TAKEOVER_DISABLED reason=vip_not_local local=%s master=%s (unicast sync only)",
            M.int2ip(rt.vip), M.int2ip(rt.master))
    end

    log(node, "HA_BOOT mode=%s local=%s master=%s sync_port=%d interval=%ds fail_limit=%d takeover_after=%ds transport=%s",
        opt.role, M.int2ip(pub.ip), M.int2ip(master), opt.sync_port, opt.interval,
        opt.fail_limit, opt.takeover_after, rt.shared and "broadcast" or "unicast")

    rt.started = true
    if standby then
        node:add_task("ha-sync", function()
            while true do
                local ok, err = pcall(M.ha_tick, rt)
                if not ok then log(node, "HA_TICK_ERROR err=%s", tostring(err)) end
                os.sleep(rt.opt.interval)
            end
        end)
    end
    log(node, "HA_MODE mode=%s responder=%s firewall=%s",
        rt.mode, tostring(opt.responder), tostring(M.firewall_enabled))
    return rt
end

function M.status(rt)
    if type(rt) ~= "table" then return nil end
    return {
        mode = rt.mode,
        role = rt.role,
        master = rt.last_master_id,
        vip = M.int2ip(rt.vip),
        synced = rt.synced_dhcp_config ~= nil,
        dhcp = rt.dhcp_server ~= nil,
        misses = rt.misses,
        age = now_of(rt) - (rt.last_master_seen or rt.started_at),
        stats = rt.stats,
    }
end

function M.status_text(rt)
    local s = M.status(rt)
    if not s then return "HA status: not started" end
    return string.format(
        "HA mode=%s role=%s vip=%s master=%s synced=%s dhcp=%s misses=%d silent=%.1fs sync_tx=%d sync_rx=%d takeovers=%d firewalled=%d",
        s.mode, s.role, s.vip, tostring(s.master), tostring(s.synced), tostring(s.dhcp),
        s.misses, s.age, s.stats.sync_tx, s.stats.sync_rx, s.stats.takeovers,
        M.stats.firewall_drops)
end

-- ===== loader forms =========================================================
-- node2/startup.lua app form: `app=backup_router` in role.txt
function M.new(opts)
    local base = opts or {}
    local app = { rpv = base.rpv, node = base.node, opt = base }
    function app:start()
        local rt, err = M.start_router(self.node, self.rpv, self.opt)
        if not rt then
            log(self.node, "HA_START_FAIL err=%s", tostring(err))
            return false, err
        end
        self.runtime = rt
        return true
    end
    function app:run() return true end
    return app
end

-- standalone boot: the lock runs before the node exists, DHCP can never be
-- started by the bootstrap, then the HA service takes over and node:run() runs
function M.boot(opts)
    local base = opts or {}
    local rpv = base.rpv or M.find_rpv(nil)
    if type(rpv) ~= "table" then
        print("[" .. M.TAG .. "] rpv module not found (pass opts.rpv)")
        return nil, "rpv module table is required"
    end
    local opt = M.options(base)
    M.wait_for_redstone(nil, opt.redstone_side)

    local node = rpv.node_new({
        role = "router",
        ifaces = { {
            side = opt.side, name = opt.iface_name, cidr = opt.local_cidr,
            channel = opt.channel, mtu = 256,
        } },
    })
    node.cfg.dhcp_pool = nil
    node.cfg.dhcp = nil
    node:setup()

    local rt, err = M.start_router(node, rpv, base)
    if not rt then
        node:log("HA_START_FAIL err=%s", tostring(err))
        return nil, err
    end
    node:run()
end

M.add_blocked(M.BLOCK_NET, M.BLOCK_PREFIX)

if type(_G) == "table" then
    _G.backup_router = M
end

return M
