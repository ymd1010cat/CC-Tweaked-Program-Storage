--[[- tests/t_ha_e2e.lua - the two HA switches in one process: apps/core_router.lua
(the primary, with its embedded RPV1-HA/1 responder) and apps/backup_router.lua
(the standby), wired together by a stubbed datagram transport instead of a modem.

Nothing here opens a socket or a modem: the two fixtures hand every payload to a
small in-process "wire" that delivers SYNC/CFG datagrams to the peer's bound
handler, broadcast first, exactly as rpv does on the shared VIP. The clock is
injected per runtime, never patched globally: M.options{ clock = ... } for the
backup switches and rt.clock for the primary's responder (the hook
core_router.lua:905 documents). The takeover at the 15 s mark and the 10/30 s
cooldown are therefore decided by the test, not by how fast the runner is, and
no fake clock can leak into another group.

Scenarios: A sync, B takeover, C failback, D debounce (cooldown in both
directions), E error paths (a stale nonce, a foreign `to`/`master`, a malformed
datagram, a DHCP port collision, and a taken-over primary that must stay mute),
F an idle standby (a duplicate recovery keeps the pool role.txt configured).
]]
local T, M = ...

local CR = M.core_router
local BR = M.backup_router
T.ok(CR ~= nil, "the core_router module is loaded")
T.ok(BR ~= nil, "the backup_router module is loaded")
if not CR or not BR then return end

-- ===== the injected clock ===================================================
-- one counter for the whole group, handed to the runtimes instead of patched
-- into the os table: every timestamp the apps take (takeover cooldown,
-- last_change, last_master_seen, synced_at, primary last_announce) comes from
-- here when the runtime carries the clock function
local real_clock = os.clock
local NOW = 1000
local function clock() return NOW end

local function tick(seconds)
    NOW = NOW + (seconds or 0)
    return NOW
end

-- ===== fixtures =============================================================
local function ip(text) return CR.parse_ipv4(text) end

local VIP = ip("10.200.0.1")        -- both switches share the ender public VIP
local BCAST = 4294967295
local HA_PORT = 6710
local PRIMARY_ID = 133
local BACKUP_ID = 42

-- what a takeover must inherit: the primary's *live* pool, not the defaults
local WANT = {
    pool_start = "10.200.0.60", pool_end = "10.200.0.160", lease_time = 1200,
    gateway = "10.200.0.1", dns = "10.200.0.2", prefix = 24, dhcp_port = 6700,
}

local function check_cfg(cfg, want, where)
    T.eq(cfg and cfg.pool_start, want.pool_start, where .. ": pool_start")
    T.eq(cfg and cfg.pool_end, want.pool_end, where .. ": pool_end")
    T.eq(cfg and cfg.lease_time, want.lease_time, where .. ": lease_time")
    T.eq(cfg and cfg.gateway, want.gateway, where .. ": gateway")
    T.eq(cfg and cfg.dns, want.dns, where .. ": dns")
    T.eq(cfg and cfg.prefix, want.prefix, where .. ": prefix")
    T.eq(cfg and cfg.dhcp_port, want.dhcp_port, where .. ": dhcp_port")
end

local function make_node(id, addr)
    local node = {
        id = id, mac = id, role = "router", cfg = {}, stats = {},
        logs = {}, binds = {}, tasks = {},
        ifaces = { { side = "left", name = "PUBLIC", ip = addr, prefix = 24,
                     net = ip("10.200.0.0"), channel = 4001 } },
    }
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    function node:bind(port, handler)
        local sock = { port = port, handler = handler, closes = 0 }
        function sock.close(self)
            self.closes = self.closes + 1
            self.closed = true
        end
        node.binds[#node.binds + 1] = sock
        node.sock = sock
        return sock
    end
    function node:add_task(name, fn)
        node.tasks[#node.tasks + 1] = { name = name, fn = fn }
        return node.tasks[#node.tasks]
    end
    node.on_frame = function(self, iface, frame) return "frame" end
    return node
end

local function count_log(node, tag)
    local hits = 0
    for _, line in ipairs(node.logs or {}) do
        if tostring(line):find(tag, 1, true) then hits = hits + 1 end
    end
    return hits
end

local function logged(node, tag)
    return count_log(node, tag) > 0
end

-- ===== the wire =============================================================
-- endpoints register their bound socket handler; a broadcast reaches both
-- switches (the VIP is one address, so even a unicast to it lands on both),
-- and `wire.up.primary` is the primary machine going dark
local wire = { up = { primary = true }, sent = {}, off_port = 0,
               primary_in = 0, backup_in = 0 }
local endpoints = {}

local function add_endpoint(name, addr, handler)
    endpoints[#endpoints + 1] = { name = name, ip = addr, handler = handler }
end

local function wire_send(from, dst, dport, sport, payload)
    wire.sent[#wire.sent + 1] = { from = from, dst = dst, dport = dport,
        sport = sport, payload = payload }
    if dport ~= HA_PORT then
        wire.off_port = wire.off_port + 1
        return 0
    end
    local delivered = 0
    for index = 1, #endpoints do
        local ep = endpoints[index]
        local up = (ep.name ~= "primary") or wire.up.primary
        local match = (dst == BCAST) or (dst == ep.ip)
        if up and match and type(ep.handler) == "function" then
            if ep.name == "primary" then
                wire.primary_in = wire.primary_in + 1
            else
                wire.backup_in = wire.backup_in + 1
            end
            ep.handler(payload, VIP, sport)
            delivered = delivered + 1
        end
    end
    return delivered
end

-- the rpv surface both apps use. `quiet` keeps a fixture off the wire (a dead
-- primary, or a third box in the debounce scenario)
local function make_rpv(name, quiet)
    local rpv = {
        IP_BCAST = BCAST, MAC_BCAST = 281474976710655, ET_ARP = 2054,
        name = name, sent = {}, frames = {}, servers = {},
        dhcp_starts = 0, dhcp_closes = 0,
    }
    function rpv.udp_send(node, dst, dport, sport, body)
        rpv.sent[#rpv.sent + 1] = { node = node, dst = dst, dport = dport,
            sport = sport, body = body }
        if not quiet then wire_send(name, dst, dport, sport, body) end
        return true
    end
    function rpv.link_send(node, iface, dst, etype, body)
        rpv.frames[#rpv.frames + 1] = { iface = iface, dst = dst, etype = etype,
            body = body }
        return true
    end
    function rpv.u16(value)
        return string.char(math.floor(value / 256) % 256, value % 256)
    end
    function rpv.u32(value)
        return string.char(math.floor(value / 16777216) % 256,
            math.floor(value / 65536) % 256, math.floor(value / 256) % 256,
            value % 256)
    end
    function rpv.r16(text, at) return 0 end
    function rpv.r32(text, at) return 0 end
    function rpv.link_parse(frame) return nil end
    function rpv.nat_input_hook(node, iface, h, payload) return "nat" end
    -- stands in for rpv.dhcp_server_start: builds a server table from node.cfg,
    -- the user's keys, exactly like the library does
    function rpv.dhcp_server_start(node, srv_opts)
        rpv.dhcp_starts = rpv.dhcp_starts + 1
        local sk = { handler = function() return "served" end }
        function sk.close(self)
            self.closed = true
            self.closes = (self.closes or 0) + 1
            rpv.dhcp_closes = rpv.dhcp_closes + 1
        end
        local lo, hi = tostring(node.cfg.dhcp_pool or ""):match("^([%d%.]+)%-(%d%.+)$")
        local srv = {
            lo = ip(lo) or ip("10.200.0.50"), hi = ip(hi) or ip("10.200.0.150"),
            lease = tonumber(node.cfg.dhcp_lease) or 600,
            gw = ip(node.cfg.dhcp_gw) or VIP, dns = ip(node.cfg.dhcp_dns) or VIP,
            prefix = 24, port = tonumber(node.cfg.dhcp_port) or 6700,
            by_ip = {}, by_client = {}, sk = sk,
        }
        rpv.servers[#rpv.servers + 1] = srv
        return srv
    end
    return rpv
end

local function assert_exclusive(master_serving, backup_serving, where)
    T.ok(not (master_serving and backup_serving),
        "never two DHCP servers at once (" .. where .. ")")
end

-- ===== the two machines =====================================================
local pnode = make_node(PRIMARY_ID, VIP)
pnode.dhcp_server = {
    lo = ip("10.200.0.60"), hi = ip("10.200.0.160"), lease = 1200,
    gw = VIP, dns = ip("10.200.0.2"), prefix = 24, port = 6700,
    by_ip = {}, by_client = {},
}
local prpv = make_rpv("primary")
local prt = CR.start_ha(pnode, prpv)
T.ok(prt ~= nil, "the primary starts its RPV1-HA/1 responder")
if prt then prt.clock = clock end        -- the documented per-runtime clock hook
T.ok(prt ~= nil and prt.clock == clock, "the responder runs on the injected clock")
T.eq(#pnode.binds, 1, "the primary binds one socket")
T.eq((pnode.binds[1] or {}).port, HA_PORT, "the responder listens on 6710")
T.ok(logged(pnode, "CORE_ROUTER_HA_READY"), "the responder announces itself")

local bnode = make_node(BACKUP_ID, VIP)
local brpv = make_rpv("backup")
local brt = BR.start_router(bnode, brpv,
    { announce_gap = 0, redstone_side = "none", clock = clock })
T.ok(brt ~= nil, "the standby starts")
T.ok(brt and brt.started == true, "the standby runtime is marked started")
T.ok(brt ~= nil and brt.clock == clock, "the standby reads the injected clock")
T.eq(brt and brt.started_at, NOW, "the standby anchors started_at on the injected clock")
T.eq(#bnode.binds, 1, "the standby binds one socket")
T.eq((bnode.binds[1] or {}).port, HA_PORT, "the standby syncs on 6710")
T.eq(brt.mode, "STANDBY", "the standby begins in STANDBY")
T.eq(brt.shared, true, "the standby holds the same VIP as the primary")
T.eq(bnode.ha_dhcp_active, nil, "a standby has no DHCP flag set")
T.eq(brpv.dhcp_starts, 0, "a standby starts no DHCP server")
T.ok(logged(bnode, "STANDBY_DHCP_OFF"), "the standby logs that DHCP is off")
T.ok(logged(bnode, "HA_FIREWALL_READY"), "the firewall hook is installed")

local prt_handler = (pnode.binds[1] or {}).handler
local brt_handler = (bnode.binds[1] or {}).handler
add_endpoint("primary", VIP, prt_handler)
add_endpoint("backup", VIP, brt_handler)
T.ok(prt_handler ~= nil and brt_handler ~= nil, "both sockets have a handler")

-- ===== A. sync: SYNC out, CFG back, seven fields stored ======================
local round_a = BR.ha_tick(brt, NOW)
T.ok(round_a ~= nil, "the standby runs one 5 s sync cycle")
T.eq(round_a.mode, "STANDBY", "a healthy cycle stays on standby")
T.eq(round_a.sent, 1, "one sync request was sent")
T.eq(round_a.misses, 0, "an answered round is not a miss")
T.eq(#brpv.sent, 1, "the wire carried exactly one request")
T.eq(brpv.sent[1].dport, HA_PORT, "the request targets 6710")
T.eq(brpv.sent[1].dst, BCAST,
    "a shared-VIP request is a broadcast (a unicast would loop back)")

local request = BR.parse_message(brpv.sent[1].body)
T.ok(request ~= nil, "the request parses as RPV1-HA/1")
T.eq(request and request.kind, "SYNC", "the request kind is SYNC")
T.eq(request and request.fields.id, "42", "the request names the standby")
T.ok(tonumber(request and request.fields.nonce) ~= nil,
    "the request carries a nonce")

T.eq(#prpv.sent, 1, "the primary answered the request")
T.eq(prpv.sent[1].dport, HA_PORT, "the answer targets 6710")
T.eq(prpv.sent[1].dst, BCAST,
    "a shared-VIP answer is broadcast too, or it would never leave the box")

local answer = BR.parse_message(prpv.sent[1].body)
T.ok(answer ~= nil, "the answer parses as RPV1-HA/1")
T.eq(answer and answer.kind, "CFG", "the answer kind is CFG")
T.eq(answer and answer.fields.master, "133", "the answer names the primary")
T.eq(answer and answer.fields.to, "42", "the answer is addressed to the standby")
T.ok(CR.ha_parse(prpv.sent[1].body) ~= nil,
    "the primary's own parser accepts its own CFG")

T.ok(brt.synced_dhcp_config ~= nil, "the standby stored a synced config")
check_cfg(brt.synced_dhcp_config, WANT, "A synced")
T.eq(brt.last_master_id, PRIMARY_ID, "the standby records the master id")
T.eq(brt.stats.sync_rx, 1, "the sync counter moved")
T.eq(brt.misses, 0, "the miss counter stays clear")
T.eq(brt.pending_nonce, nil, "the answered nonce is no longer pending")
T.ok(logged(bnode, "SYNCED_DHCP_CONFIG"), "the sync is logged")
T.eq(bnode.synced_dhcp_config, brt.synced_dhcp_config,
    "the config is mirrored on the node")
T.eq(BR.synced_dhcp_config, brt.synced_dhcp_config,
    "and on the backup_router module table")
T.eq(BR.evaluate(brt, NOW), false, "a freshly synced standby is never due")
T.ok(brt.synced_dhcp_config.pool_start ~= BR.DEFAULT_DHCP_CONFIG.pool_start,
    "the synced pool is the primary's live pool, not the built-in default")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after the sync")

-- ===== B. takeover: three unanswered rounds and 15 s of silence ============
wire.up.primary = false          -- the primary machine goes dark
local seen_before = wire.primary_in

-- one full 5 s interval without a reply is one missed round, so three of them
-- are exactly the 15 s TAKEOVER_AFTER documents: the third silent cycle is the
-- takeover, not a fourth one
local round_b1 = BR.ha_tick(brt, tick(5))
T.eq(round_b1.misses, 1, "the first silent round is the first miss")
T.eq(round_b1.mode, "STANDBY", "one silent round does not move the mode")
T.eq(BR.evaluate(brt, NOW), false, "5 s of silence are not yet due")
T.eq(wire.primary_in, seen_before, "the dark primary receives nothing")
T.eq(bnode.ha_dhcp_active, nil, "no DHCP flag without a takeover")
T.eq(brpv.dhcp_starts, 0, "a late master never triggers a DHCP start")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after round 1")

local round_b2 = BR.ha_tick(brt, tick(5))
T.eq(round_b2.misses, 2, "the second silent round is two misses")
T.eq(BR.evaluate(brt, NOW), false, "two misses are below the fail limit")
T.eq(brt.mode, "STANDBY", "two misses do not move the mode")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after miss 2")

-- the documented rule: three misses AND the full 15 s window
local due = { mode = "STANDBY", opt = brt.opt, misses = 3,
              last_master_seen = brt.last_master_seen }
T.eq(BR.evaluate(due, brt.last_master_seen + 14), false,
    "14 s of silence are not yet due")
T.eq(BR.evaluate(due, brt.last_master_seen + 15), true,
    "three misses plus 15 s of silence are due")

local round_b3 = BR.ha_tick(brt, tick(5))
T.eq(round_b3.misses, 3, "the third silent round is three misses")
T.eq(round_b3.mode, "ACTIVE", "the third missed round takes over")
T.eq(NOW - brt.last_master_seen, 15,
    "the takeover lands exactly 15 s after the last answer")
T.eq(brt.stats.takeovers, 1, "the takeover counter moved")
T.eq(brpv.dhcp_starts, 1, "takeover calls rpv.dhcp_server_start exactly once")
T.eq(bnode.ha_dhcp_active, true, "the standby now serves DHCP")
T.eq(bnode.cfg.dhcp_pool, "10.200.0.60-10.200.0.160",
    "the served pool is the synced one, not the default")
T.eq(bnode.cfg.dhcp_probe, "0", "the ICMP probe stays off during a takeover")
T.eq(bnode.cfg.dhcp_gw, "10.200.0.1", "the served gateway is the synced one")
T.eq(bnode.cfg.dhcp_dns, "10.200.0.2", "the served dns is the synced one")
T.eq(bnode.cfg.dhcp_lease, "1200", "the served lease is the synced one")
T.eq(bnode.cfg.dhcp_port, "6700", "the served DHCP port is the synced one")
T.ok(bnode.cfg.dhcp_pool ~= (BR.DEFAULT_DHCP_CONFIG.pool_start .. "-"
    .. BR.DEFAULT_DHCP_CONFIG.pool_end), "the default pool was never used")
T.eq(#brpv.frames, 3, "three gratuitous ARPs announce the VIP")
T.ok(logged(bnode, "TAKEOVER_ACTIVE"), "TAKEOVER_ACTIVE is logged")
T.ok(brt.dhcp_server ~= nil, "the runtime holds the server it started")
T.ok(brt.synced_dhcp_config ~= nil, "the takeover keeps the synced config")
check_cfg(brt.synced_dhcp_config, WANT, "B kept")
T.eq(brt.last_change, NOW, "the state change is stamped on the injected clock")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after takeover")

-- a served lease is on the books, so the failback has something to release
local active_srv = brt.dhcp_server
active_srv.by_ip[1] = true
active_srv.by_client[1] = true
T.eq(active_srv.port, 6700, "the served server binds the synced port")

-- ===== C. failback: the primary answers again ==============================
wire.up.primary = true
local round_c = BR.ha_tick(brt, tick(5))
T.eq(round_c.mode, "STANDBY", "the recovered master is taken back at once")
T.eq(brt.stats.standbys, 1, "the failback counter moved")
T.eq(brt.dhcp_server, nil, "the runtime drops the served server")
T.eq(bnode.ha_dhcp_active, false, "the backup stops serving DHCP")
T.eq(bnode.cfg.dhcp_pool, nil, "the pool is cleared on failback")
T.eq(active_srv.stopped, true, "the stopped server is marked")
T.eq(active_srv.sk.closed, true, "stop_dhcp closed the DHCP socket")
T.eq(active_srv.sk.closes, 1, "the DHCP socket is closed exactly once")
T.eq(next(active_srv.by_ip), nil, "the lease table is emptied")
T.eq(next(active_srv.by_client), nil, "the client table is emptied")
T.ok(logged(bnode, "HA_DHCP_STOP"), "the stop is logged")
T.ok(logged(bnode, "STANDBY_MODE"), "STANDBY_MODE is logged")
T.eq(brt.last_master_seen, NOW, "the sighting is stamped on the injected clock")
T.eq(brt.last_master_id, PRIMARY_ID, "the recovered master is recorded")
T.eq(brt.misses, 0, "the failback clears the miss counter")
T.ok(brt.synced_dhcp_config ~= nil, "the synced config survives the failback")
check_cfg(brt.synced_dhcp_config, WANT, "C after failback")
T.eq(BR.evaluate(brt, NOW), false, "a synced standby is not due again")
T.ok(#brpv.frames == 3, "a failback sends no gratuitous ARP of its own")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after failback")

-- ===== D. debounce: cooldown in both directions ============================
-- a third box on its own quiet transport: same code, 30 s cooldown, no wire
local dnode = make_node(77, VIP)
local drpv = make_rpv("debounce", true)
local drt = BR.start_router(dnode, drpv,
    { cooldown = 30, announce_gap = 0, redstone_side = "none", clock = clock })
T.ok(drt ~= nil, "the debounce fixture starts")
T.eq(drt.opt.cooldown, 30, "the fixture uses a 30 s cooldown")

local dnonce = BR.send_sync_request(drt, NOW)
T.ok(dnonce ~= nil, "the fixture sends a request")
local dcfg_msg = BR.parse_message(
    CR.ha_build_reply(CR.ha_config_from_node(pnode), 77, dnonce, PRIMARY_ID))
T.ok(dcfg_msg ~= nil, "the primary's reply builds for the fixture")
BR.on_sync_reply(drt, dcfg_msg, VIP)
T.ok(drt.synced_dhcp_config ~= nil, "the fixture is synced")
check_cfg(drt.synced_dhcp_config, WANT, "D synced")
T.eq(drt.last_master_id, PRIMARY_ID, "the fixture records the master")

local d_first = BR.ha_tick(drt, tick(5))
T.eq(d_first.misses, 1, "the first fixture round without a reply is one miss")
T.eq(BR.ha_tick(drt, tick(5)).misses, 2, "the fixture misses twice")
local d_take = BR.ha_tick(drt, tick(5))
T.eq(d_take.misses, 3, "the fixture misses three times")
T.eq(d_take.mode, "ACTIVE", "the fixture takes over after 15 s of silence")
T.eq(drpv.dhcp_starts, 1, "the fixture starts DHCP once")
local d_change = drt.last_change
T.eq(d_change, NOW, "the fixture stamps the takeover on the injected clock")

-- the master answers again: a CFG means failback right now, no cooldown wait
local d_nonce2 = BR.send_sync_request(drt, NOW)
local dcfg2 = BR.parse_message(
    CR.ha_build_reply(CR.ha_config_from_node(pnode), 77, d_nonce2, PRIMARY_ID))
BR.on_sync_reply(drt, dcfg2, VIP)
T.eq(drt.mode, "STANDBY", "a CFG during a takeover fails back immediately")
T.eq(drpv.dhcp_closes, 1, "the immediate failback closes the DHCP socket")
T.eq(drt.last_change, NOW, "the failback stamps the same clock value")
T.eq(drt.stats.standbys, 1, "the fixture failback counter moved")

local d_clean = BR.ha_tick(drt, tick(5))
T.eq(d_clean.misses, 1,
    "the answered round counts no miss; the next silent one does")
local d_miss1 = BR.ha_tick(drt, tick(5))
T.eq(d_miss1.misses, 2, "the debounce window keeps missing")
local d_miss2 = BR.ha_tick(drt, tick(5))
T.eq(d_miss2.misses, 3, "the debounce window reaches three misses")
T.eq(BR.evaluate(drt, NOW), true, "the debounce window is due at 15 s")
T.eq(NOW - drt.last_change, 15,
    "the cooldown is measured on the injected clock, 15 s of 30 s used")
T.eq(d_miss2.mode, "STANDBY", "the 30 s cooldown holds the takeover")
T.eq(drpv.dhcp_starts, 1, "no second DHCP start inside the cooldown")
T.eq(drt.stats.takeovers, 1, "the takeover counter did not move")
T.eq(count_log(dnode, "HA_TAKEOVER_HOLD"), 1, "the hold is logged")
T.eq(drt.last_change, d_change, "a held takeover leaves the stamp alone")
local d_late = BR.ha_tick(drt, tick(15))
T.eq(d_late.mode, "ACTIVE", "the takeover fires once the cooldown expires")
T.eq(NOW - d_change, 30, "the second takeover waits exactly the cooldown")
T.eq(drpv.dhcp_starts, 2, "the second DHCP start happened exactly once")
T.eq(drt.stats.takeovers, 2, "the takeover counter moved again")
T.ok(drt.last_change > d_change, "the new takeover stamped a later clock")

-- ===== E. error paths ======================================================
-- the wire is dark again, so nothing but the injected datagrams is delivered
wire.up.primary = false
local stale_nonce = 999999999
local cfg_now = CR.ha_config_from_node(pnode)
local kept = brt.synced_dhcp_config
local rx_before = brt.stats.sync_rx
local stale_before = brt.stats.sync_stale

local wrong_nonce = CR.ha_build_reply(cfg_now, BACKUP_ID, stale_nonce, PRIMARY_ID)
brt_handler(wrong_nonce, VIP, HA_PORT)
T.eq(brt.stats.sync_stale, stale_before + 1, "an unknown nonce is dropped as stale")
T.eq(brt.synced_dhcp_config, kept, "a stale reply never replaces the config")
T.eq(brt.stats.sync_rx, rx_before, "a stale reply is not counted as a sync")

-- a reply addressed to somebody else: rejected before the nonce is even looked at
local pending = BR.send_sync_request(brt, NOW)
T.ok(pending ~= nil, "the standby has a pending nonce")
local stale_after_to = brt.stats.sync_stale
local foreign_to = CR.ha_build_reply(cfg_now, 777, pending, PRIMARY_ID)
brt_handler(foreign_to, VIP, HA_PORT)
T.eq(brt.stats.sync_stale, stale_after_to,
    "a foreign `to` returns before the nonce bookkeeping")
T.eq(brt.stats.sync_rx, rx_before, "a foreign `to` is never applied")
T.eq(brt.synced_dhcp_config, kept, "a foreign `to` keeps the synced config")

-- our own broadcast coming back: `master` is this node
local own_master = CR.ha_build_reply(cfg_now, BACKUP_ID, pending, BACKUP_ID)
brt_handler(own_master, VIP, HA_PORT)
T.eq(brt.stats.sync_stale, stale_after_to,
    "a reply whose master is ourselves is ignored before the nonce check")
T.eq(brt.synced_dhcp_config, kept, "our own reply never replaces the config")

-- a malformed datagram: logged, never applied
local bad_before = brt.stats.sync_bad
brt_handler("RPV1-HA/2 SYNC id=42 nonce=5", VIP, HA_PORT)
T.eq(brt.stats.sync_bad, bad_before + 1, "another protocol version is rejected")
T.ok(logged(bnode, "HA_SYNC_BAD"), "the bad datagram is logged")

-- a CFG whose DHCP port collides with the sync port must be refused
local collide_cfg = CR.ha_config_from_node(pnode)
collide_cfg.dhcp_port = HA_PORT
local collide = CR.ha_build_reply(collide_cfg, BACKUP_ID, pending, PRIMARY_ID)
brt_handler(collide, VIP, HA_PORT)
T.eq(brt.stats.sync_rx, rx_before, "a port-colliding CFG is never applied")
T.eq(brt.synced_dhcp_config, kept, "a port-colliding CFG keeps the old config")
T.ok(logged(bnode, "dhcp_port_collision"), "the collision is logged")

-- a primary that has been taken over must stay mute
tick(2)
local silent_before = #prpv.sent
pnode.ha_taken_over = true
local silent_action = CR.ha_handle(prt, BR.build_request(BACKUP_ID, 4242), VIP, HA_PORT)
T.eq(silent_action, "silent", "ha_taken_over silences the responder")
T.eq(#prpv.sent, silent_before, "a taken-over primary sends nothing")
T.ok(logged(pnode, "CORE_ROUTER_HA_SILENT"), "the silence is logged")

tick(2)
pnode.ha_taken_over = false
pnode.ha_dhcp_active = true
T.eq(CR.ha_handle(prt, BR.build_request(BACKUP_ID, 4243), VIP, HA_PORT), "silent",
    "ha_dhcp_active silences the responder as well")
T.eq(prt.stats.silent, 2, "the silence counter moved twice")

-- clearing both flags restores the pair end to end
tick(2)
pnode.ha_dhcp_active = false
wire.up.primary = true
local replies_before = #prpv.sent
T.eq(CR.ha_handle(prt, BR.build_request(BACKUP_ID, 4244), VIP, HA_PORT), "replied",
    "with both flags clear the primary answers again")
T.eq(#prpv.sent, replies_before + 1,
    "the restored responder puts an answer on the wire")
local round_e = BR.ha_tick(brt, NOW)
T.eq(round_e.mode, "STANDBY", "the pair ends up on the standby side")
T.eq(brt.stats.sync_rx, rx_before + 1, "the standby consumes a fresh reply")
check_cfg(brt.synced_dhcp_config, WANT, "E after recovery")
T.eq(brt.last_master_seen, NOW, "the recovery is stamped on the injected clock")
assert_exclusive(wire.up.primary, bnode.ha_dhcp_active == true, "after recovery")

-- ===== F. an idle standby keeps the pool role.txt configured ==============
-- A standby that is already idle has no DHCP server to stop. Running the
-- recovery path there must not touch node.cfg.dhcp_pool: role.txt is the only
-- local copy of the pool the box would serve after a takeover.
local fnode = make_node(88, VIP)
fnode.cfg = { dhcp_pool = "10.200.0.200-10.200.0.220" }
local frpv = make_rpv("idle", true)
local frt = BR.start_router(fnode, frpv,
    { announce_gap = 0, redstone_side = "none", clock = clock })
T.ok(frt ~= nil, "the idle standby starts")
T.eq(fnode.cfg.dhcp_pool, "10.200.0.200-10.200.0.220",
    "an idle boot leaves the configured pool alone")
T.eq(frpv.dhcp_starts, 0, "the idle standby serves no DHCP")

-- a recovery on an idle runtime: nothing to stop, but the state is logged
local idle = BR.standby(frt, "master_recovered", PRIMARY_ID)
T.eq(idle, false, "an idle recovery is not a service change")
T.eq(frt.mode, "STANDBY", "the idle runtime stays on standby")
T.eq(fnode.cfg.dhcp_pool, "10.200.0.200-10.200.0.220",
    "an idle standby keeps node.cfg.dhcp_pool")
T.eq(frpv.dhcp_closes, 0, "an idle standby closes no DHCP socket")
T.ok(logged(fnode, "STANDBY_MODE"), "the idle recovery still logs STANDBY_MODE")
T.eq(frt.last_change, NOW, "the idle recovery is stamped on the injected clock")

-- and the same box through the wire: a valid CFG resets the misses and still
-- leaves the pool where role.txt put it
T.eq(BR.ha_tick(frt, tick(5)).misses, 1, "a silent round on the idle box is one miss")
T.eq(BR.ha_tick(frt, tick(5)).misses, 2, "a second silent round is two misses")
local fnonce = BR.send_sync_request(frt, NOW)
local fcfg = CR.ha_build_reply(CR.ha_config_from_node(pnode), 88, fnonce, PRIMARY_ID)
local fhandler = (fnode.binds[1] or {}).handler
fhandler(fcfg, VIP, HA_PORT)
T.eq(frt.mode, "STANDBY", "a CFG on the idle box keeps it on standby")
T.eq(frt.misses, 0, "a reply puts the miss counter back to zero")
T.eq(frt.pending_nonce, nil, "the answered nonce is no longer pending")
T.eq(fnode.cfg.dhcp_pool, "10.200.0.200-10.200.0.220",
    "a CFG on an idle standby never clears the configured pool")
T.eq(frt.last_master_seen, NOW, "the sighting is stamped on the injected clock")
check_cfg(frt.synced_dhcp_config, WANT, "F synced")
T.eq(frt.stats.sync_rx, 1, "the idle box consumed the CFG")
assert_exclusive(wire.up.primary, fnode.ha_dhcp_active == true, "on the idle box")

-- ===== no global clock was ever patched ===================================
T.eq(os.clock, real_clock, "the global os.clock is untouched, nothing to restore")
T.eq(prt and prt.clock, clock, "the responder reads its injected clock")
T.eq(brt and brt.clock, clock, "the standby runtime carries its own clock")
