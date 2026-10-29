--[[- tests/t_backup_router.lua - apps/backup_router.lua: the RPV1-HA/1 codec,
the CFG validation, the takeover rule, the options table, the DHCP start/stop
bookkeeping, the public-side firewall hook and the role="primary" responder.
Offline: stub node/rpv tables, no socket, no redstone hardware, no modem.
]]
local T, M = ...

local BR = M.backup_router
T.ok(BR ~= nil, "backup_router module is loaded")
if not BR then return end

local function ip(text)
    return BR.parse_ipv4(text)
end

local PUBLIC_IP = ip("10.200.0.1")
local PEER_IP = ip("10.200.0.7")
local OTHER_IP = ip("10.200.0.8")
local BLOCKED = ip("192.168.1.9")

local function logged(node, tag)
    for _, line in ipairs(node.logs or {}) do
        if tostring(line):find(tag, 1, true) then return true end
    end
    return false
end

local function make_node(opts)
    local o = opts or {}
    local node = {
        id = o.id or 133, mac = (o.id or 133), cfg = o.cfg or {},
        logs = {}, binds = {}, tasks = {},
    }
    if o.ifaces then node.ifaces = o.ifaces end
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    function node:bind(port, handler)
        local sock = { port = port, handler = handler }
        function sock.close(self) self.closed = true end
        node.binds[#node.binds + 1] = sock
        node.sock = sock
        return sock
    end
    function node:add_task(name, fn)
        node.tasks[#node.tasks + 1] = { name = name, fn = fn }
        return node.tasks[#node.tasks]
    end
    node.on_frame = function(self, iface, frame)
        self.frames = (self.frames or 0) + 1
        return "frame"
    end
    return node
end

-- a full rpv stub for start_router/announce: every helper the module requires
local function make_rpv(opts)
    local o = opts or {}
    local rpv = {
        IP_BCAST = 4294967295, MAC_BCAST = 281474976710655, ET_ARP = 2054,
        sent = {}, frames = {},
    }
    function rpv.udp_send(node, dst, dport, sport, body)
        rpv.sent[#rpv.sent + 1] = {
            node = node, dst = dst, dport = dport, sport = sport, body = body,
        }
        return true
    end
    function rpv.link_send(node, iface, dst, etype, body)
        rpv.frames[#rpv.frames + 1] = {
            iface = iface, dst = dst, etype = etype, body = body,
        }
        return true
    end
    function rpv.u16(value)
        return string.char(math.floor(value / 256) % 256, value % 256)
    end
    function rpv.u32(value)
        return string.char(
            math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
            math.floor(value / 256) % 256, value % 256)
    end
    function rpv.r16(text, at) return 0 end
    function rpv.r32(text, at) return 0 end
    function rpv.link_parse(frame) return nil end
    function rpv.nat_input_hook(node, iface, h, payload) return "nat" end
    if o.dhcp then
        function rpv.dhcp_server_start(node, srv_opts)
            rpv.dhcp_starts = (rpv.dhcp_starts or 0) + 1
            rpv.servers = rpv.servers or {}
            local sk = { handler = function() return "served" end }
            function sk.close(self)
                self.closed = true
                rpv.dhcp_closes = (rpv.dhcp_closes or 0) + 1
            end
            local srv = {
                lo = ip("10.200.0.50"), hi = ip("10.200.0.150"), lease = 600,
                gw = PUBLIC_IP, dns = PUBLIC_IP, prefix = 24, port = 6700,
                by_ip = {}, by_client = {}, sk = sk,
            }
            rpv.servers[#rpv.servers + 1] = srv
            return srv
        end
    end
    return rpv
end

local function public_iface(addr)
    return {
        name = "PUBLIC", ip = addr or PUBLIC_IP, prefix = 24,
        net = ip("10.200.0.0"),
    }
end

-- ===== addresses and constants =============================================
T.eq(BR.VERSION, "1.0", "the version is 1.0")
T.eq(BR.PROTO, "RPV1-HA/1", "the wire token is RPV1-HA/1")
T.eq(BR.SYNC_PORT, 6710, "the default sync port is 6710")
T.eq(BR.FAIL_LIMIT, 3, "three misses are needed")
T.eq(BR.TAKEOVER_AFTER, 15, "the silent window is 15 s")
T.eq(BR.MIN_LEASE, 30, "the minimum lease is 30 s")
T.eq(BR.MAX_LEASE, 2592000, "the maximum lease is 30 days")
T.eq(BR.MAX_MSG_BYTES, 512, "one datagram is capped at 512 bytes")
T.eq(BR.BLOCK_NET, "192.168.0.0", "the blocked net is 192.168.0.0")
T.eq(BR.BLOCK_PREFIX, 16, "the blocked prefix is /16")
T.eq(BR.IP_BROADCAST, 4294967295, "the limited broadcast address")
T.eq(ip("10.200.0.1"), 10 * 16777216 + 200 * 65536 + 1, "a dotted quad is big-endian")
T.eq(BR.int2ip(ip("10.200.0.1")), "10.200.0.1", "int2ip round-trips")
T.eq(ip("010.200.0.1"), nil, "leading zeros are rejected")
T.eq(ip("10.200.0"), nil, "a short quad is rejected")
T.eq(ip("10.200.0.256"), nil, "an octet above 255 is rejected")
T.eq(ip(nil), nil, "a non-string is rejected")
T.eq(ip(" 10.200.0.1 "), ip("10.200.0.1"), "surrounding space is trimmed")
T.eq(BR.in_subnet(PEER_IP, ip("10.200.0.0"), 24), true, "10.200.0.7 is in /24")
T.eq(BR.in_subnet(ip("10.200.1.7"), ip("10.200.0.0"), 24), false, "a /24 boundary is respected")
T.eq(BR.in_subnet(PEER_IP, ip("10.200.0.0"), 33), false, "a prefix above 32 is invalid")
T.eq(BR.is_public(PUBLIC_IP), true, "the VIP is public")
T.eq(BR.is_public(ip("192.168.1.1")), false, "a LAN address is not public")
T.eq(BR.is_public(nil), false, "nil is not public")

-- ===== request codec ========================================================
local REQ = BR.build_request(42, 987654321)
T.eq(REQ, "RPV1-HA/1 SYNC id=42 nonce=987654321", "the request text is the golden one")
T.eq(BR.build_request(42.9, 7.8), "RPV1-HA/1 SYNC id=42 nonce=7", "ids are floored")
T.eq(BR.build_request(nil, nil), "RPV1-HA/1 SYNC id=0 nonce=0", "nil becomes zero")
local req_msg = BR.parse_message(REQ)
T.ok(req_msg ~= nil, "the request parses")
T.eq(req_msg and req_msg.kind, "SYNC", "the request kind is SYNC")
T.eq(req_msg and req_msg.fields.id, "42", "the id survives")
T.eq(req_msg and req_msg.fields.nonce, "987654321", "the nonce survives")

-- ===== reply codec ==========================================================
local CFG = BR.copy_config(BR.DEFAULT_DHCP_CONFIG)
local REPLY = BR.build_reply(CFG, 42, 5, 133)
local ORDER = "^RPV1%-HA/1 CFG master=133 to=42 nonce=5 pool_start=10%.200%.0%.50 "
    .. "pool_end=10%.200%.0%.150 lease_time=600 gateway=10%.200%.0%.1 "
    .. "dns=10%.200%.0%.1 prefix=24 dhcp_port=6700 uptime=%d+$"
T.ok(REPLY:match(ORDER) ~= nil, "the reply keeps the field set and order")
local reply_msg = BR.parse_message(REPLY)
local rf = (reply_msg and reply_msg.fields) or {}
T.ok(reply_msg ~= nil, "the reply parses")
T.eq(reply_msg and reply_msg.kind, "CFG", "the reply kind is CFG")
T.eq(rf.master, "133", "master is the answering node")
T.eq(rf.to, "42", "to is the requester")
T.eq(rf.nonce, "5", "the nonce is echoed")
T.eq(rf.pool_start, "10.200.0.50", "reply pool_start")
T.eq(rf.pool_end, "10.200.0.150", "reply pool_end")
T.eq(tonumber(rf.lease_time), 600, "reply lease_time")
T.eq(rf.gateway, "10.200.0.1", "reply gateway")
T.eq(rf.dns, "10.200.0.1", "reply dns")
T.eq(tonumber(rf.prefix), 24, "reply prefix")
T.eq(tonumber(rf.dhcp_port), 6700, "reply dhcp_port")
T.ok(tonumber(rf.uptime) ~= nil, "uptime is numeric")
local minimal = BR.parse_message(BR.build_reply(
    { pool_start = "10.200.0.50", pool_end = "10.200.0.150" }, 1, 2, nil))
T.ok(minimal ~= nil, "a minimal config still builds")
T.eq(minimal and minimal.fields.master, "0", "a missing master id is zero")
T.eq(minimal and minimal.fields.lease_time, "600", "the default lease is 600")
T.eq(minimal and minimal.fields.prefix, "24", "the default prefix is 24")
T.eq(minimal and minimal.fields.dhcp_port, "6700", "the default DHCP port is 6700")

-- ===== parse_message rejects bad datagrams =================================
local function msg_error(text)
    local _, err = BR.parse_message(text)
    return err
end
T.eq(msg_error(nil), "empty datagram", "nil is an empty datagram")
T.eq(msg_error(""), "empty datagram", "an empty string is an empty datagram")
T.eq(msg_error("RPV1-HA/1 SYNC " .. string.rep("x", BR.MAX_MSG_BYTES)), "datagram too large",
    "a datagram above 512 bytes is rejected")
T.eq(msg_error("RPV2-HA/1 SYNC id=1"), "protocol mismatch", "another protocol is rejected")
T.eq(msg_error("RPV1-HA/1 PING id=1"), "unknown message kind PING", "an unknown kind is rejected")
T.eq(msg_error("RPV1-HA/1 sync id=1"), "unknown message kind sync", "the kind is case sensitive")
local many = {}
for i = 1, BR.MAX_TOKENS + 1 do many[i] = "f" .. i .. "=1" end
T.eq(msg_error("RPV1-HA/1 SYNC " .. table.concat(many, " ")), "too many fields",
    "more than 32 fields are rejected")
T.eq(msg_error("RPV1-HA/1 SYNC id=1 garbage"), "malformed field garbage",
    "a token without '=' is rejected")
T.eq(msg_error("RPV1-HA/1 SYNC id=1 id=2"), "duplicate field id", "a duplicate field is rejected")
local fwd = BR.parse_message("RPV1-HA/1 SYNC id=1 nonce=2 future=9")
T.eq(fwd and fwd.fields.future, "9", "an unknown extra field is kept")
local spaced = BR.parse_message("  RPV1-HA/1\tSYNC  id=1\nnonce=2  ")
T.ok(spaced ~= nil and spaced.fields.nonce == "2", "any whitespace separates fields")

-- ===== parse_config validation =============================================
local parsed = BR.parse_config(rf)
T.ok(parsed ~= nil, "a valid CFG parses into a config table")
T.eq(parsed and parsed.pool_start, "10.200.0.50", "parse_config pool_start")
T.eq(parsed and parsed.pool_end, "10.200.0.150", "parse_config pool_end")
T.eq(parsed and parsed.pool_start_int, ip("10.200.0.50"), "parse_config keeps the pool ints")
T.eq(parsed and parsed.lease_time, 600, "parse_config lease_time")
T.eq(parsed and parsed.gateway, "10.200.0.1", "parse_config gateway")
T.eq(parsed and parsed.dns, "10.200.0.1", "parse_config dns")
T.eq(parsed and parsed.prefix, 24, "parse_config prefix")
T.eq(parsed and parsed.dhcp_port, 6700, "parse_config dhcp_port")

local function cfg_error(fields)
    local _, err = BR.parse_config(fields)
    return err
end
T.eq(cfg_error(nil), "no fields", "nil fields are rejected")
T.eq(cfg_error({ pool_end = "10.0.0.2", lease_time = 600 }), "pool_start is missing",
    "pool_start is required")
T.eq(cfg_error({ pool_start = "10.0.0.1", lease_time = 600 }), "pool_end is missing",
    "pool_end is required")
T.eq(cfg_error({ pool_start = "010.0.0.1", pool_end = "10.0.0.2", lease_time = 600 }),
    "pool_start is not an IPv4 address", "a leading zero is not an IPv4 address")
T.eq(cfg_error({ pool_start = "10.0.0.9", pool_end = "10.0.0.2", lease_time = 600 }),
    "pool_start is above pool_end", "an inverted pool is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 29 }),
    "lease_time is out of range (30..2592000)", "a short lease is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 2592001 }),
    "lease_time is out of range (30..2592000)", "a long lease is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = "x" }),
    "lease_time is out of range (30..2592000)", "a non-numeric lease is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600, prefix = 7 }),
    "prefix is out of range", "a prefix below 8 is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600, prefix = 31 }),
    "prefix is out of range", "a prefix above 30 is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600, dhcp_port = 0 }),
    "dhcp_port is out of range", "port 0 is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600, dhcp_port = 70000 }),
    "dhcp_port is out of range", "a port above 65535 is rejected")
T.eq(cfg_error({ pool_start = "0.0.0.0", pool_end = "10.0.0.2", lease_time = 600 }),
    "pool_start is not a usable host address", "0.0.0.0 is not a host")
T.eq(cfg_error({ pool_start = "224.0.0.1", pool_end = "10.0.0.2", lease_time = 600 }),
    "pool_start is not a usable host address", "a multicast address is not a host")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600,
    gateway = "bad" }), "gateway is not an IPv4 address", "a bad gateway is rejected")
T.eq(cfg_error({ pool_start = "10.0.0.1", pool_end = "10.0.0.2", lease_time = 600,
    dns = "bad" }), "dns is not an IPv4 address", "a bad dns is rejected")
local least = BR.parse_config({ pool_start = "10.0.0.1", pool_end = "10.0.0.2",
    lease_time = BR.MIN_LEASE })
T.eq(least and least.lease_time, BR.MIN_LEASE, "the minimum lease is accepted")
local most = BR.parse_config({ pool_start = "10.0.0.1", pool_end = "10.0.0.2",
    lease_time = BR.MAX_LEASE })
T.eq(most and most.lease_time, BR.MAX_LEASE, "the maximum lease is accepted")
local optional = BR.parse_config({ pool_start = "10.0.0.1", pool_end = "10.0.0.2",
    lease_time = 600 })
T.eq(optional and optional.gateway, nil, "a missing gateway stays nil")
T.eq(optional and optional.prefix, nil, "a missing prefix stays nil")
T.eq(optional and optional.dhcp_port, nil, "a missing port stays nil")

T.eq(BR.config_text(CFG),
    "pool=10.200.0.50-10.200.0.150 lease=600s gw=10.200.0.1 dns=10.200.0.1 prefix=24 port=6700",
    "config_text keeps the operator-readable shape")
T.eq(BR.config_text({}), "pool=nil-nil lease=0s gw=nil dns=nil prefix=0 port=0",
    "config_text tolerates an empty table")

-- ===== options =============================================================
local d = BR.options()
T.eq(d.role, "standby", "the default role is standby")
T.eq(d.master_ip, "10.200.0.1", "the default master is the VIP")
T.eq(d.local_cidr, "10.200.0.1/24", "the default CIDR is the public wire")
T.eq(d.iface_name, "PUBLIC", "the default interface name")
T.eq(d.side, "left", "the default modem side")
T.eq(d.channel, 4001, "the default modem channel")
T.eq(d.sync_port, 6710, "the default sync port")
T.eq(d.interval, 5, "the default sync interval")
T.eq(d.fail_limit, 3, "the default fail limit")
T.eq(d.takeover_after, 15, "the default silent window")
T.eq(d.announce_interval, 10, "the default announce interval")
T.eq(d.announce_burst, 3, "the default announce burst")
T.eq(d.announce_gap, 0.5, "the default announce gap")
T.eq(d.cooldown, 10, "the default takeover cooldown")
T.eq(d.firewall, true, "the firewall is on by default")
T.eq(d.redstone_side, "bottom", "the lock side is bottom")
T.eq(d.responder, false, "a standby is not a responder")
local o = BR.options({
    role = "primary", master_ip = "10.9.9.9", sync_port = "6800", interval = "7",
    fail_limit = 2.9, takeover_after = 20, redstone_side = false, firewall = false,
    responder = false, announce_gap = 0,
})
T.eq(o.role, "primary", "the role is overridden")
T.eq(o.master_ip, "10.9.9.9", "master_ip is overridden")
T.eq(o.sync_port, 6800, "a string sync_port is converted")
T.eq(o.interval, 7, "a string interval is converted")
T.eq(o.fail_limit, 2, "fail_limit is floored")
T.eq(o.takeover_after, 20, "takeover_after is overridden")
T.eq(o.redstone_side, "none", "false disables the redstone lock")
T.eq(o.firewall, false, "the firewall can be disabled")
T.eq(o.responder, false, "an explicit responder wins")
T.eq(o.announce_gap, 0, "the announce gap is overridden")
T.eq(BR.options({ role = "primary" }).responder, true, "a primary responds by default")
T.eq(BR.options({ sync_port = 0 }).sync_port, 6710, "port 0 falls back to 6710")
T.eq(BR.options({ sync_port = 70000 }).sync_port, 6710, "port 70000 falls back")
T.eq(BR.options({ interval = 0 }).interval, 5, "interval 0 falls back to 5")
T.eq(BR.options({ interval = "x" }).interval, 5, "a non-numeric interval falls back")
T.eq(BR.options({ fail_limit = -2 }).fail_limit, 3, "a negative fail_limit falls back")
T.eq(BR.options({ channel = 0 }).channel, 4001, "channel 0 falls back")
T.eq(BR.options({ redstone_side = "left" }).redstone_side, "left", "a side name is kept")

-- ===== the takeover rule ====================================================
local function rt_eval(extra)
    local rt = {
        mode = "STANDBY", misses = 3, last_master_seen = 100,
        opt = { fail_limit = 3, takeover_after = 15 },
    }
    for key, value in pairs(extra or {}) do rt[key] = value end
    return rt
end
T.eq(BR.evaluate(rt_eval(), 115), true, "3 misses and 15 s of silence take over")
T.eq(BR.evaluate(rt_eval(), 114.9), false, "just under 15 s is not enough")
T.eq(BR.evaluate(rt_eval({ misses = 2 }), 115), false, "two misses are not enough")
T.eq(BR.evaluate(rt_eval({ mode = "ACTIVE" }), 115), false, "an ACTIVE node never takes over")
local started = rt_eval()
started.last_master_seen = nil
started.started_at = 50
T.eq(BR.evaluate(started, 65), true, "started_at anchors the silent window")
local zero = rt_eval()
zero.last_master_seen = nil
zero.started_at = nil
T.eq(BR.evaluate(zero, 15), true, "no anchor means time zero")
T.eq(BR.evaluate(nil, 15), false, "nil runtime never takes over")
T.eq(BR.evaluate({ mode = "STANDBY", misses = 3 }, 15), false, "a runtime without opt is refused")
T.eq(BR.evaluate(rt_eval({ opt = { fail_limit = 4, takeover_after = 15 } }), 200), false,
    "opt.fail_limit is honoured")
T.eq(BR.evaluate(rt_eval({ opt = { fail_limit = 3, takeover_after = 30 } }), 115), false,
    "opt.takeover_after is honoured")

-- ===== redstone lock =======================================================
local saved_rs = rawget(_G, "rs")
local saved_redstone = rawget(_G, "redstone")
_G.rs = nil
_G.redstone = nil
local rs_on, rs_err = BR.redstone_input("bottom")
T.eq(rs_on, false, "no redstone API means the lock is closed")
T.eq(rs_err, "redstone API is unavailable", "the missing API is named")
_G.redstone = saved_redstone
local saw_side = nil
_G.rs = { getInput = function(side) saw_side = side; return true end }
local wn = make_node()
BR.redstone_ready = false
T.eq(BR.wait_for_redstone(wn, "bottom"), true, "the lock opens when the face is powered")
T.eq(saw_side, "bottom", "the configured side is read")
T.ok(logged(wn, "HA_REDSTONE_ON"), "HA_REDSTONE_ON is logged")
T.eq(BR.redstone_ready, true, "the module remembers the open lock")
_G.rs = { getInput = function() return false end }
T.eq(BR.redstone_input("bottom"), false, "an unpowered face is false")
_G.rs = { getInput = function() error("t_backup rs boom") end }
local rs_bad, rs_bad_err = BR.redstone_input("bottom")
T.eq(rs_bad, false, "a failing getInput is caught")
T.ok(rs_bad_err ~= nil and rs_bad_err:find("t_backup rs boom", 1, true) ~= nil,
    "the getInput error is reported")
BR.redstone_ready = false
T.eq(BR.wait_for_redstone(wn, "none"), true, "side none skips the lock")
T.ok(logged(wn, "HA_REDSTONE_SKIP"), "the skipped lock is logged")
T.eq(BR.redstone_ready, true, "the skipped lock is remembered")
_G.rs = saved_rs

-- ===== public-side firewall ================================================
BR.clear_blocked()
T.eq(#BR.blocked, 0, "the block list can be reset")
T.eq(BR.add_blocked("192.168.0.0", 16), true, "the 192.168/16 range is added")
T.eq(#BR.blocked, 1, "one range is stored")
T.eq(BR.is_blocked(ip("192.168.5.5")), true, "a 192.168 destination is blocked")
T.eq(BR.is_blocked(ip("10.200.5.5")), false, "a public destination is not blocked")
T.eq(BR.blocked_text(), "192.168.0.0/16", "blocked_text lists the range")
T.eq(BR.add_blocked("192.168.0.0", 16), true, "re-adding the same range is a no-op")
T.eq(#BR.blocked, 1, "the duplicate is not stored twice")
local bad_add, bad_add_err = BR.add_blocked("nope", 16)
T.eq(bad_add, nil, "a bad net is refused")
T.eq(bad_add_err, "bad range", "the bad net error is named")
local bad_bits, bad_bits_err = BR.add_blocked("192.168.0.0", 33)
T.eq(bad_bits, nil, "a bad prefix is refused")
T.eq(bad_bits_err, "bad range", "the bad prefix error is named")

local fnode = make_node()
local frpv = make_rpv()
local chained = { n = 0 }
frpv.nat_input_hook = function(node, iface, h, payload)
    chained.n = chained.n + 1
    return "forwarded"
end
T.eq(BR.install_firewall(fnode, frpv), "rpv", "the firewall links onto rpv.nat_input_hook")
T.eq(frpv.nat_input_hook, BR.nat_input_hook, "rpv.nat_input_hook now chains through the module")
T.ok(BR.saved_nat_hook ~= nil, "the previous hook is saved")
T.eq(BR.firewall_enabled, true, "the firewall reports enabled")
T.ok(logged(fnode, "HA_FIREWALL_READY"), "HA_FIREWALL_READY is logged")
local pub = public_iface()
local lan = { name = "LAN", ip = ip("192.168.1.1"), prefix = 24, net = ip("192.168.1.0") }
local drops0 = BR.stats.firewall_drops
T.eq(frpv.nat_input_hook(fnode, pub, { src = PEER_IP, dst = BLOCKED, proto = 6 }, ""),
    "drop", "a public-to-LAN packet is dropped")
T.eq(BR.stats.firewall_drops, drops0 + 1, "the drop counter moves")
T.ok(logged(fnode, "FIREWALL_DROP"), "FIREWALL_DROP is logged")
T.eq(chained.n, 0, "a dropped packet never reaches the old hook")
T.eq(frpv.nat_input_hook(fnode, lan, { src = ip("192.168.1.5"), dst = BLOCKED, proto = 6 }, ""),
    "forwarded", "a LAN-to-LAN packet passes")
T.eq(chained.n, 1, "the old hook runs for a passed packet")
T.eq(frpv.nat_input_hook(fnode, lan, { src = ip("192.168.1.5"), dst = PEER_IP, proto = 6 }, ""),
    "forwarded", "a LAN-to-public packet passes")
T.eq(frpv.nat_input_hook(fnode, pub, { src = ip("192.168.1.5"), dst = BLOCKED }, ""),
    "drop", "a 192.168 source from the public side is dropped")
T.eq(frpv.nat_input_hook(fnode, lan, { src = OTHER_IP, dst = BLOCKED }, ""),
    "drop", "a public source is dropped on any ingress")
T.eq(frpv.nat_input_hook(fnode, pub, { src = PEER_IP, dst = ip("10.200.0.9") }, ""),
    "forwarded", "a public-to-public packet passes")
T.eq(frpv.nat_input_hook(fnode, pub, {}, ""), "forwarded", "a header without dst is not dropped")
BR.firewall_enabled = false
T.eq(frpv.nat_input_hook(fnode, pub, { src = PEER_IP, dst = BLOCKED }, ""),
    "forwarded", "a disabled firewall passes everything")
T.eq(BR.install_firewall(fnode, frpv, { firewall = false }), "off", "firewall = false turns it off")
T.eq(BR.firewall_enabled, false, "the disabled state is recorded")
T.ok(logged(fnode, "HA_FIREWALL_OFF"), "HA_FIREWALL_OFF is logged")

local gnode = make_node()
local delivered = { n = 0 }
function gnode:ip_deliver(iface, h, payload)
    delivered.n = delivered.n + 1
    return "delivered"
end
T.eq(BR.install_firewall(gnode, nil, {}), "node", "without rpv the node.ip_deliver fallback is used")
T.eq(gnode.ha_ip_guard, true, "the fallback marks the node")
T.eq(gnode.ip_deliver(gnode, pub, { src = PEER_IP, dst = BLOCKED }, ""), nil,
    "the node guard drops the packet")
T.eq(delivered.n, 0, "the dropped packet is not delivered")
T.eq(gnode.ip_deliver(gnode, pub, { src = PEER_IP, dst = ip("10.200.0.9") }, ""), "delivered",
    "the node guard forwards the packet")
T.eq(delivered.n, 1, "the forwarded packet is delivered")
BR.clear_blocked()
BR.add_blocked(BR.BLOCK_NET, BR.BLOCK_PREFIX)
BR.firewall_enabled = false
BR.saved_nat_hook = nil

-- ===== DHCP start / stop ===================================================
local calls = { closed = 0, base = 0, starts = 0 }
local function make_server()
    local sk = { handler = function()
        calls.base = calls.base + 1
        return "base"
    end }
    function sk.close(self)
        calls.closed = calls.closed + 1
        sk.closed = true
    end
    return {
        lo = ip("10.200.0.50"), hi = ip("10.200.0.150"), lease = 600,
        gw = PUBLIC_IP, dns = PUBLIC_IP, prefix = 24, port = 6700,
        by_ip = { [1] = true }, by_client = { [1] = true }, sk = sk,
    }
end
local old_srv = make_server()
local dhcp_node = make_node({ cfg = {} })
dhcp_node.dhcp_server = old_srv
dhcp_node.ha_dhcp_srv = old_srv
local dhcp_rpv = make_rpv()
function dhcp_rpv.dhcp_server_start(node, srv_opts)
    calls.starts = calls.starts + 1
    calls.last = make_server()
    return calls.last
end
local dry = { node = dhcp_node, rpv = dhcp_rpv }
local srv = BR.start_dhcp(dry, BR.copy_config(BR.DEFAULT_DHCP_CONFIG))
T.ok(srv ~= nil, "start_dhcp returns the new server")
T.eq(calls.starts, 1, "rpv.dhcp_server_start is called once")
T.eq(calls.closed, 1, "the previous socket is closed before the new bind")
T.eq(old_srv.sk.closed, true, "the old socket is really closed")
T.eq(srv == old_srv, false, "a new server instance is used")
T.eq(dhcp_node.ha_dhcp_srv, srv, "the new server is attached to the node")
T.eq(dhcp_node.dhcp_server, nil, "the stale node.dhcp_server reference is cleared")
T.eq(dhcp_node.cfg.dhcp_pool, "10.200.0.50-10.200.0.150", "the pool is written to node.cfg")
T.eq(dhcp_node.cfg.dhcp_gw, "10.200.0.1", "dhcp_gw is written")
T.eq(dhcp_node.cfg.dhcp_dns, "10.200.0.1", "dhcp_dns is written")
T.eq(dhcp_node.cfg.dhcp_lease, "600", "dhcp_lease is written")
T.eq(dhcp_node.cfg.dhcp_port, "6700", "dhcp_port is written")
T.eq(dhcp_node.cfg.dhcp_probe, "0", "the ICMP probe is disabled")
T.eq(dhcp_node.ha_dhcp_active, true, "DHCP is marked active")
T.eq(next(old_srv.by_ip), nil, "the old leases are released")
T.eq(old_srv.stopped, true, "the old server is marked stopped")
T.eq(srv.sk.handler("data", 1, 2), "base", "the guarded handler forwards while active")
T.eq(calls.base, 1, "the base handler ran once")
T.eq(BR.stop_dhcp(dhcp_node), true, "stop_dhcp tears the server down")
T.eq(calls.closed, 2, "stop_dhcp closes the socket")
T.eq(dhcp_node.ha_dhcp_active, false, "DHCP is marked inactive")
T.eq(dhcp_node.ha_dhcp_srv, nil, "the server reference is cleared")
T.eq(dhcp_node.dhcp_server, nil, "node.dhcp_server stays clear")
T.eq(dhcp_node.cfg.dhcp_pool, nil, "the pool is cleared on stop")
T.eq(next(srv.by_ip), nil, "the leases are cleared on stop")
T.eq(next(srv.by_client), nil, "the client table is cleared on stop")
T.eq(srv.sk.handler("data", 1, 2), nil, "the stopped handler is guarded")
T.eq(calls.base, 1, "a stopped server never serves")
T.eq(srv.stopped, true, "the stopped server is marked")
T.eq(BR.stop_dhcp(dhcp_node), false, "stopping an empty node is a no-op")
local srv2 = BR.start_dhcp(dry, BR.copy_config(BR.DEFAULT_DHCP_CONFIG))
T.ok(srv2 ~= nil, "a restart returns a new server")
T.eq(calls.starts, 2, "the restart calls rpv again")
T.eq(calls.closed, 2, "a clean restart closes nothing stale")
T.eq(dhcp_node.ha_dhcp_srv, srv2, "the restart replaces the node reference")
T.eq(calls.last, srv2, "the last start is the one attached")

local bad_rpv = make_rpv()
function bad_rpv.dhcp_server_start() error("t_backup dhcp boom") end
local bad_rt = { node = make_node({ cfg = {} }), rpv = bad_rpv }
local failed, failed_err = BR.start_dhcp(bad_rt, BR.copy_config(BR.DEFAULT_DHCP_CONFIG))
T.eq(failed, nil, "a failing DHCP start returns nil")
T.ok(failed_err ~= nil and failed_err:find("t_backup dhcp boom", 1, true) ~= nil,
    "the start error is reported")
T.eq(bad_rt.node.cfg.dhcp_pool, nil, "a failed start leaves no pool behind")
T.eq(bad_rt.node.ha_dhcp_active, false, "a failed start never marks DHCP active")
local round_rpv = make_rpv()
function round_rpv.dhcp_server_start() return "not a table" end
local round_rt = { node = make_node({ cfg = {} }), rpv = round_rpv }
local rounded, round_err = BR.start_dhcp(round_rt, BR.copy_config(BR.DEFAULT_DHCP_CONFIG))
T.eq(rounded, nil, "a non-table server is refused")
T.eq(round_err, "dhcp_server_start returned no server", "the refusal is named")
T.eq(round_rt.node.cfg.dhcp_pool, nil, "the refused start clears the pool")

-- ===== stop_dhcp with node.cfg == nil (F4) =================================
-- a node built without a cfg table still has to be torn down cleanly: the old
-- code indexed node.cfg.dhcp_pool unconditionally and raised
local nilcfg_srv = make_server()
local nilcfg_node = make_node()
nilcfg_node.cfg = nil
nilcfg_node.dhcp_server = nilcfg_srv
local closes_before = calls.closed
local ok_nil = pcall(BR.stop_dhcp, nilcfg_node)
T.ok(ok_nil == true, "stop_dhcp does not raise when node.cfg is nil")
T.eq(nilcfg_node.dhcp_server, nil, "stop_dhcp still clears node.dhcp_server")
T.eq(nilcfg_node.ha_dhcp_srv, nil, "stop_dhcp still clears node.ha_dhcp_srv")
T.eq(nilcfg_node.ha_dhcp_active, false, "stop_dhcp still clears the active flag")
T.eq(nilcfg_srv.stopped, true, "stop_dhcp still marks the server stopped")
T.eq(nilcfg_srv.sk.closed, true, "stop_dhcp still closes the socket")
T.eq(next(nilcfg_srv.by_ip), nil, "stop_dhcp still releases the leases")
T.eq(calls.closed, closes_before + 1, "stop_dhcp closes exactly one socket")
T.eq(nilcfg_node.cfg, nil, "a nil node.cfg stays nil")
T.eq(pcall(BR.stop_dhcp, nilcfg_node), true, "a second stop on a nil cfg is a no-op")

-- ===== the gateway a primary reports (F3) ===================================
-- rpv lists the LAN interface first on a real box: ifaces[1] must not become the
-- gateway a backup inherits, or a takeover hands LAN addresses to the clients
local LAN_FIRST = {
    { name = "LAN", ip = ip("192.168.1.1"), prefix = 24, net = ip("192.168.0.0") },
    public_iface(),
}
local gnode = make_node()
gnode.ifaces = LAN_FIRST
gnode.cfg = {}
local gcfg = BR.dhcp_config_from_node(gnode)
T.eq(gcfg.gateway, "10.200.0.1", "the public interface wins over ifaces[1]")
T.eq(gcfg.dns, "10.200.0.1", "the default dns follows the public gateway")
T.eq(gcfg.pool_start, "10.200.0.50", "the built-in pool is still reported")
T.eq(gcfg.prefix, 24, "the public prefix is reported")

local pool_node = make_node()
pool_node.ifaces = LAN_FIRST
pool_node.cfg = { dhcp_pool = "10.200.0.50-10.200.0.150", dhcp_lease = "900" }
local pcfg = BR.dhcp_config_from_node(pool_node)
T.eq(pcfg.gateway, "10.200.0.1", "a cfg pool still uses the public gateway")
T.eq(pcfg.pool_start, "10.200.0.50", "the cfg pool start survives")
T.eq(pcfg.pool_end, "10.200.0.150", "the cfg pool end survives")
T.eq(pcfg.lease_time, 900, "the cfg lease survives")

-- the documented escape hatch: an explicit cfg.public_iface (name or address)
local explicit_node = make_node()
explicit_node.ifaces = {
    { name = "LAN", ip = ip("192.168.1.1"), prefix = 24, net = ip("192.168.0.0") },
    { name = "WAN", ip = ip("10.200.0.5"), prefix = 24, net = ip("10.200.0.0") },
}
explicit_node.cfg = { public_iface = "WAN" }
T.eq(BR.dhcp_config_from_node(explicit_node).gateway, "10.200.0.5",
    "an explicit cfg.public_iface name selects the gateway")
explicit_node.cfg = { public_iface = "10.200.0.5" }
T.eq(BR.dhcp_config_from_node(explicit_node).gateway, "10.200.0.5",
    "an explicit cfg.public_iface address selects the gateway")

-- any address on the public wire counts, not only the named interface
local named_node = make_node()
named_node.ifaces = {
    { name = "LAN", ip = ip("192.168.1.1"), prefix = 24, net = ip("192.168.0.0") },
    { name = "WAN", ip = ip("10.200.0.9"), prefix = 24, net = ip("10.200.0.0") },
}
named_node.cfg = {}
T.eq(BR.dhcp_config_from_node(named_node).gateway, "10.200.0.9",
    "any 10.200.0.0/24 interface is public, not only the named one")

-- no public interface at all: the first-interface fallback stays, explicitly
local lan_only = make_node()
lan_only.ifaces = { { name = "LAN", ip = ip("192.168.1.1"), prefix = 24, net = ip("192.168.0.0") } }
lan_only.cfg = {}
T.eq(BR.dhcp_config_from_node(lan_only).gateway, "192.168.1.1",
    "without a public interface the first interface is the documented fallback")
T.eq(BR.gateway_iface(lan_only, lan_only.cfg).name, "LAN",
    "gateway_iface names the fallback interface")
T.eq(BR.gateway_iface(gnode, gnode.cfg).name, "PUBLIC",
    "gateway_iface names the public interface")

-- ===== start_router on a non-shared standby ================================
local snode = make_node()
snode.ifaces = { public_iface(PEER_IP) }
snode.cfg = {}
local srpv = make_rpv({ dhcp = true })
local srt = BR.start_router(snode, srpv, { master_ip = "10.200.0.1", announce_gap = 0 })
T.ok(srt ~= nil, "a standby starts")
T.eq(srt.role, "standby", "the role is standby")
T.eq(srt.mode, "STANDBY", "the mode is STANDBY")
T.eq(srt.shared, false, "a distinct address is not the shared VIP")
T.eq(srt.vip, PEER_IP, "the vip is the local address")
T.eq(srt.master, PUBLIC_IP, "the master is the configured primary")
T.eq(srt.started, true, "the runtime is marked started")
T.eq(snode.ha, srt, "node.ha points at the runtime")
T.eq(#snode.binds, 1, "the sync socket is bound")
T.eq(snode.binds[1].port, 6710, "the sync socket uses 6710")
T.eq(#snode.tasks, 1, "the sync task is scheduled")
T.ok(logged(snode, "HA_BOOT"), "HA_BOOT is logged")
T.ok(logged(snode, "TAKEOVER_DISABLED"), "a non-shared VIP disables takeover")
T.ok(logged(snode, "STANDBY_DHCP_OFF"), "a standby keeps DHCP off")
T.ok(snode.ha_arp_guard ~= nil, "the ARP guard wraps node.on_frame")
T.eq(BR.start_router(snode, srpv, {}), srt, "start_router is idempotent")
T.eq(BR.takeover(srt, "test"), false, "a non-shared standby never takes over")
T.ok(logged(snode, "vip_not_local"), "the takeover abort names the reason")

-- ===== takeover and failback ===============================================
local function make_rt(extra)
    local node = make_node({ id = 42 })
    node.ifaces = { public_iface() }
    node.cfg = {}
    local rt = {
        node = node, rpv = make_rpv({ dhcp = true }), role = "standby",
        mode = "STANDBY", shared = true, vip = PUBLIC_IP, master = PUBLIC_IP,
        public_iface = node.ifaces[1], opt = BR.options({ announce_gap = 0 }),
        stats = { takeovers = 0 }, misses = 3, started_at = 0, last_master_seen = 0,
        synced_dhcp_config = BR.copy_config(BR.DEFAULT_DHCP_CONFIG),
    }
    for key, value in pairs(extra or {}) do rt[key] = value end
    return rt
end
local rt = make_rt()
T.eq(BR.evaluate(rt, 100), true, "the dropped standby is due")
T.eq(BR.takeover(rt, "master_timeout"), true, "the standby takes over")
T.eq(rt.mode, "ACTIVE", "the mode becomes ACTIVE")
T.eq(rt.stats.takeovers, 1, "the takeover counter moved")
T.eq(rt.node.ha_active, true, "the node is marked active")
T.eq(rt.node.ha_dhcp_active, true, "DHCP is active after the takeover")
T.eq(rt.rpv.dhcp_starts, 1, "the takeover starts DHCP once")
T.eq(#rt.rpv.frames, 3, "the default announce burst is three frames")
T.eq(rt.stats.arp_announce, 3, "the announce counter counts the burst")
T.ok(logged(rt.node, "TAKEOVER_ACTIVE"), "TAKEOVER_ACTIVE is logged")
T.eq(rt.dhcp_server ~= nil, true, "the runtime holds the DHCP server")
T.eq(BR.evaluate(rt, 1000), false, "an ACTIVE node is never due")
T.eq(BR.standby(rt, "master_recovered", 133), true, "failback stops DHCP")
T.eq(rt.mode, "STANDBY", "the mode returns to STANDBY")
T.eq(rt.node.ha_active, false, "the node is marked inactive")
T.eq(rt.node.ha_dhcp_active, false, "DHCP is stopped on failback")
T.eq(rt.stats.standbys, 1, "the standby counter moved")
T.ok(logged(rt.node, "STANDBY_MODE"), "STANDBY_MODE is logged")
T.eq(BR.standby(rt, "master_recovered", 133), false, "a second failback is a no-op")

local no_cfg = make_rt()
no_cfg.synced_dhcp_config = nil
T.eq(BR.takeover(no_cfg, "x"), false, "nothing synced means no takeover")
T.ok(logged(no_cfg.node, "no_synced_config"), "the missing config is logged")
local collide = make_rt()
collide.synced_dhcp_config.dhcp_port = collide.opt.sync_port
T.eq(BR.takeover(collide, "x"), false, "a DHCP port collision aborts the takeover")
T.ok(logged(collide.node, "dhcp_port_collision"), "the collision is logged")
local cooling = make_rt()
cooling.last_change = os.clock()
T.eq(BR.takeover(cooling, "x"), false, "the cooldown holds the takeover")
T.ok(logged(cooling.node, "HA_TAKEOVER_HOLD"), "the cooldown is logged")
local broken = make_rt()
function broken.rpv.dhcp_server_start() error("t_backup dhcp boom") end
T.eq(BR.takeover(broken, "x"), false, "a failing DHCP start aborts the takeover")
T.ok(logged(broken.node, "reason=dhcp_start"), "the DHCP start failure is logged")
T.eq(broken.mode, "STANDBY", "a failed takeover stays on standby")
T.eq(BR.takeover(make_rt({ role = "primary" }), "x"), false, "a primary never takes over")
T.eq(BR.takeover(make_rt({ mode = "ACTIVE" }), "x"), false, "an ACTIVE runtime never takes over")

-- ===== role="primary" responder ============================================
local pnode = make_node({ id = 133 })
pnode.ifaces = { public_iface() }
pnode.cfg = {}
local prpv = make_rpv({ dhcp = true })
local prt = BR.start_router(pnode, prpv, { role = "primary", announce_gap = 0 })
T.ok(prt ~= nil, "a primary starts")
T.eq(prt.mode, "PRIMARY", "the primary mode is PRIMARY")
T.eq(prt.role, "primary", "the primary role is recorded")
T.eq(prt.shared, true, "the primary owns the VIP")
T.eq(prt.started, true, "the primary runtime is started")
T.eq(prt.opt.responder, true, "the primary is a responder")
T.eq(pnode.ha_active, true, "the primary node is marked active")
T.eq(#pnode.binds, 1, "the primary binds the sync port")
T.eq(pnode.binds[1].port, 6710, "the responder listens on 6710")
T.eq(#pnode.tasks, 0, "a primary runs no sync task")
T.ok(logged(pnode, "HA_BOOT"), "the primary boot line is logged")
T.ok(logged(pnode, "HA_MODE"), "the mode line is logged")
local handler = pnode.binds[1].handler
T.eq(type(handler), "function", "the socket has a handler")

handler(BR.build_request(42, 555), PEER_IP, 4444)
T.eq(#prpv.sent, 1, "one SYNC gets one reply")
local sent = prpv.sent[1]
T.eq(sent.node, pnode, "the reply is sent on this node")
T.eq(sent.dst, PEER_IP, "a distinct requester gets a unicast reply")
T.eq(sent.dport, 6710, "the reply targets the sync port")
T.eq(sent.sport, 4444, "the requester source port is reused")
local answer = BR.parse_message(sent.body)
T.ok(answer ~= nil, "the primary reply parses")
local af = (answer and answer.fields) or {}
T.eq(answer and answer.kind, "CFG", "the primary answers with CFG")
T.eq(af.master, "133", "the reply names the primary")
T.eq(af.to, "42", "the reply names the requester")
T.eq(af.nonce, "555", "the nonce is echoed")
T.eq(af.pool_start, "10.200.0.50", "the default pool_start is reported")
T.eq(af.pool_end, "10.200.0.150", "the default pool_end is reported")
T.eq(tonumber(af.dhcp_port), 6700, "the default DHCP port is reported")
T.eq(prt.stats.sync_replies, 1, "the reply counter moved")
T.ok(logged(pnode, "HA_SYNC_REPLY to=42"), "the reply is logged")
T.eq(#prpv.frames, 1, "the first reply announces the VIP")
T.ok(logged(pnode, "HA_ARP_ANNOUNCE"), "the announcement is logged")

handler(BR.build_request(7, 556), OTHER_IP, 4445)
T.eq(#prpv.sent, 2, "a second requester is answered")
T.eq(#prpv.frames, 1, "the primary announcement is rate limited")

handler(BR.build_request(42, 557), PUBLIC_IP, 4446)
T.eq(prpv.sent[3].dst, prpv.IP_BCAST, "a shared-VIP requester is answered on broadcast")

handler(BR.build_request(133, 558), PEER_IP, 4447)
T.eq(#prpv.sent, 3, "a request naming this node is ignored")
handler("RPV1-HA/1 SYNC nonce=1", PEER_IP, 4448)
T.eq(#prpv.sent, 3, "a request without an id is ignored")
handler(BR.build_request(42, 560):gsub("nonce=560", "nonce=abc"), PEER_IP, 4449)
T.eq(#prpv.sent, 4, "a non-numeric nonce is still answered")
T.eq(BR.parse_message(prpv.sent[4].body).fields.nonce, "0", "the non-numeric nonce becomes 0")
handler(BR.build_reply(BR.DEFAULT_DHCP_CONFIG, 42, 561, 999), PEER_IP, 4450)
T.eq(#prpv.sent, 4, "a CFG datagram is never answered by a primary")

local tick = BR.ha_tick(prt)
T.ok(tick ~= nil, "ha_tick runs on a primary")
T.eq(prt.mode, "PRIMARY", "a primary never changes mode")
T.eq(prt.stats.sync_tx, 0, "a primary sends no sync requests")

local rpv3 = make_rpv({ dhcp = true })
local n3 = make_node({ id = 9 })
n3.ifaces = { public_iface(PEER_IP) }
n3.cfg = {}
local rt3 = {
    node = n3, rpv = rpv3, role = "primary", mode = "PRIMARY", shared = false,
    vip = PEER_IP, master = PUBLIC_IP, public_iface = n3.ifaces[1],
    opt = BR.options({ role = "primary", announce_gap = 0 }), stats = {},
}
BR.on_sync_request(rt3, { fields = { id = "42", nonce = "7" } }, PEER_IP, 1200)
T.eq(#rpv3.sent, 1, "a direct primary request is answered")
T.eq(rpv3.sent[1].sport, 1200, "the direct requester source port is reused")
T.eq(rpv3.sent[1].dst, PEER_IP, "a non-shared primary replies by unicast")
T.eq(rt3.stats.sync_replies, 1, "the direct reply counter moved")

-- ===== status ==============================================================
local st = BR.status(prt)
T.ok(st ~= nil, "status returns a table")
T.eq(st and st.mode, "PRIMARY", "status reports the mode")
T.eq(st and st.role, "primary", "status reports the role")
T.eq(st and st.vip, "10.200.0.1", "status reports the VIP")
T.eq(BR.status(nil), nil, "status of nil is nil")
T.ok(BR.status_text(prt):find("mode=PRIMARY", 1, true) ~= nil,
    "status_text reports the mode")
T.eq(BR.status_text(nil), "HA status: not started", "status_text of nil is a fixed line")
