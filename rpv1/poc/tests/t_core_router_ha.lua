--[[- tests/t_core_router_ha.lua - apps/core_router.lua: the embedded RPV1-HA/1
configuration sync responder on UDP 6710.

Driven offline: the responder only needs node:bind and rpv.udp_send, so the fake
node captures the bound handler and the fake rpv records every datagram. Every
message is cross-checked against apps/backup_router.lua -- a request built by the
backup must be accepted by the core router, and the core reply must come back out
of backup_router.parse_message/parse_config/on_sync_reply with the same values --
so the two copies of the protocol cannot drift apart.

Groups: module surface, the golden SYNC/CFG cross-check, config sources, bad
messages and the 512 byte cap, the per-source rate limit, taken-over silence, the
reply address, setup_router integration (including the redstone lock), the
primary-client log line and the counters.
]]
local T, M = ...

local CR = M.core_router
local BR = M.backup_router
T.ok(CR ~= nil, "core_router module is loaded")
T.ok(BR ~= nil, "backup_router module is loaded")
if not CR or not BR then return end

-- ===== fixtures =============================================================
local MASTER_ID = 133
local PEER_ID = 42
local NONCE = 987654321
local HA_PORT = 6710
local BCAST = 4294967295
local PUBLIC_IP = CR.parse_ipv4("10.200.0.1")
local PEER_IP = CR.parse_ipv4("10.200.0.7")
local OTHER_IP = CR.parse_ipv4("10.200.0.8")
local ORDER = "^RPV1%-HA/1 CFG master=%d+ to=%d+ nonce=%d+ pool_start=%S+ "
    .. "pool_end=%S+ lease_time=%d+ gateway=%S+ dns=%S+ prefix=%d+ "
    .. "dhcp_port=%d+ uptime=%d+$"

-- the reply must name every field in exactly the order build_reply() uses
local function order_ok(text)
    return type(text) == "string" and text:find(ORDER) ~= nil
end

local function make_node(opts)
    local o = opts or {}
    local node = {
        id = o.id or MASTER_ID, mac = o.id or MASTER_ID, role = "router",
        cfg = o.cfg or {}, stats = {}, tasks = {}, logs = {}, binds = {},
        arp = { cache = {} },
        ifaces = { {
            name = "PUBLIC", ip = PUBLIC_IP, prefix = 24,
            net = CR.parse_ipv4("10.200.0.0"),
        } },
    }
    if o.dhcp_server then node.dhcp_server = o.dhcp_server end
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    function node:add_task(name, fn)
        local task = { name = name, fn = fn }
        node.tasks[#node.tasks + 1] = task
        return task
    end
    function node:bind(port, handler)
        local entry = { port = port, handler = handler }
        node.binds[#node.binds + 1] = entry
        return { port = port, handler = handler, close = function() end }
    end
    return node
end

local function make_rpv()
    local rpv = { IP_BCAST = BCAST, sent = {} }
    function rpv.udp_send(node, dst, dport, sport, payload)
        rpv.sent[#rpv.sent + 1] = {
            dst = dst, dport = dport, sport = sport, payload = payload,
        }
        return true
    end
    function rpv.nat_input_hook() return nil end
    return rpv
end

local function count_log(node, tag)
    local n = 0
    for _, line in ipairs(node.logs or {}) do
        if tostring(line):find(tag, 1, true) then n = n + 1 end
    end
    return n
end

local function has_log(node, tag)
    return count_log(node, tag) > 0
end

local function sent_count(rpv)
    return #rpv.sent
end

local function last_sent(rpv)
    return rpv.sent[#rpv.sent] or {}
end

local function deliver(rt, node, data, src, sport)
    local bind = node.binds[#node.binds] or {}
    if type(bind.handler) ~= "function" then return "no_socket" end
    return bind.handler(data, src or PEER_IP, sport or HA_PORT)
end

-- ===== module surface =======================================================
T.eq(CR.HA_PROTO, "RPV1-HA/1", "the protocol token matches backup_router")
T.eq(CR.HA_PORT, 6710, "the default HA port is 6710")
T.eq(CR.HA_MAX_BYTES, 512, "one datagram is capped at 512 bytes")
T.eq(CR.HA_RATE_LIMIT, 5, "five requests per source are accepted")
T.eq(CR.HA_RATE_WINDOW, 1, "the rate window is one second")
T.eq(CR.DEFAULT_DHCP_CONFIG.pool_start, "10.200.0.50", "default pool start")
T.eq(CR.DEFAULT_DHCP_CONFIG.pool_end, "10.200.0.150", "default pool end")
T.eq(CR.DEFAULT_DHCP_CONFIG.dhcp_port, 6700, "default dhcp port")

-- ===== golden SYNC -> CFG cross-check with backup_router ====================
local gnode, grpv = make_node(), make_rpv()
local grt = CR.start_ha(gnode, grpv)
T.ok(grt ~= nil, "start_ha returns a runtime")
T.eq(#gnode.binds, 1, "start_ha binds exactly one socket")
T.eq((gnode.binds[1] or {}).port, HA_PORT, "the socket is on UDP 6710")
T.ok(has_log(gnode, "CORE_ROUTER_HA_READY"), "CORE_ROUTER_HA_READY is logged")
if not grt then return end

local golden_request = BR.build_request(PEER_ID, NONCE)
T.eq(golden_request, "RPV1-HA/1 SYNC id=42 nonce=987654321",
    "the backup request text is the golden one")

local parsed_request = CR.ha_parse(golden_request)
local rf = (parsed_request and parsed_request.fields) or {}
T.ok(parsed_request ~= nil, "core_router parses the backup request")
T.eq(parsed_request and parsed_request.kind, "SYNC", "the request kind is SYNC")
T.eq(rf.id, "42", "the requester id survives parsing")
T.eq(rf.nonce, "987654321", "the nonce survives parsing")

local before_clock = math.floor(os.clock())
local action = CR.ha_handle(grt, golden_request, PEER_IP, HA_PORT)
local after_clock = math.floor(os.clock())
T.eq(action, "replied", "a valid SYNC is answered")
T.eq(sent_count(grpv), 1, "exactly one reply datagram is sent")

local golden = last_sent(grpv)
T.eq(golden.dst, PEER_IP, "the reply goes back to the requester")
T.eq(golden.dport, HA_PORT, "the reply targets the HA port")
T.eq(golden.sport, HA_PORT, "the reply leaves from the HA port")
local golden_reply = tostring(golden.payload)
T.ok(order_ok(golden_reply), "the reply has the backup field set and order")

local back = BR.parse_message(golden_reply)
local bf = (back and back.fields) or {}
T.ok(back ~= nil, "backup_router.parse_message accepts the reply")
T.eq(back and back.kind, "CFG", "the reply kind is CFG")
T.eq(bf.master, "133", "master is this node")
T.eq(bf.to, "42", "to is the requesting id")
T.eq(bf.nonce, "987654321", "the nonce is echoed")
T.eq(bf.pool_start, "10.200.0.50", "reply pool_start")
T.eq(bf.pool_end, "10.200.0.150", "reply pool_end")
T.eq(tonumber(bf.lease_time), 600, "reply lease_time")
T.eq(bf.gateway, "10.200.0.1", "reply gateway")
T.eq(bf.dns, "10.200.0.1", "reply dns")
T.eq(tonumber(bf.prefix), 24, "reply prefix")
T.eq(tonumber(bf.dhcp_port), 6700, "reply dhcp_port")
local uptime = tonumber(bf.uptime)
T.ok(uptime ~= nil and uptime >= before_clock and uptime <= after_clock,
    "uptime is this node's clock")

local bcfg = (back and BR.parse_config(bf)) or {}
T.ok(back ~= nil and BR.parse_config(bf) ~= nil,
    "backup_router.parse_config accepts the reply fields")
T.eq(bcfg.pool_start, "10.200.0.50", "parse_config pool_start")
T.eq(bcfg.pool_end, "10.200.0.150", "parse_config pool_end")
T.eq(bcfg.lease_time, 600, "parse_config lease_time")
T.eq(bcfg.gateway, "10.200.0.1", "parse_config gateway")
T.eq(bcfg.dns, "10.200.0.1", "parse_config dns")
T.eq(bcfg.prefix, 24, "parse_config prefix")
T.eq(bcfg.dhcp_port, 6700, "parse_config dhcp_port")

-- the other direction: core_router understands a CFG the backup builds
local backup_cfg = BR.build_reply(CR.DEFAULT_DHCP_CONFIG, MASTER_ID, 7, PEER_ID)
local seen = CR.ha_parse(backup_cfg)
T.ok(seen ~= nil, "core_router parses a backup CFG reply")
T.eq(seen and seen.kind, "CFG", "a backup CFG is recognised as CFG")

-- and the whole backup receive path accepts the core reply unchanged
local bnode = make_node({ id = PEER_ID })
bnode.ifaces[1].ip = PEER_IP
local brt = {
    node = bnode, opt = { sync_port = HA_PORT }, mode = "STANDBY",
    nonces = { [NONCE] = true }, pending_nonce = NONCE, config_text = "",
    stats = { sync_rx = 0, sync_stale = 0, sync_bad = 0 },
}
local consumed = pcall(BR.on_sync_reply, brt, back, PUBLIC_IP)
T.ok(consumed, "backup on_sync_reply consumes the core reply without error")
local synced = brt.synced_dhcp_config or {}
T.ok(brt.synced_dhcp_config ~= nil, "the backup stores the synced config")
T.eq(synced.pool_start, "10.200.0.50", "synced pool_start")
T.eq(synced.pool_end, "10.200.0.150", "synced pool_end")
T.eq(synced.lease_time, 600, "synced lease_time")
T.eq(synced.gateway, "10.200.0.1", "synced gateway")
T.eq(synced.prefix, 24, "synced prefix")
T.eq(synced.dhcp_port, 6700, "synced dhcp_port")
T.eq(brt.last_master_id, MASTER_ID, "the backup records this master id")

-- ===== configuration sources ================================================
local defaults = CR.ha_config_from_node(make_node())
T.eq(defaults.pool_start, CR.DEFAULT_DHCP_CONFIG.pool_start, "no server: pool_start")
T.eq(defaults.pool_end, CR.DEFAULT_DHCP_CONFIG.pool_end, "no server: pool_end")
T.eq(defaults.lease_time, CR.DEFAULT_DHCP_CONFIG.lease_time, "no server: lease_time")
T.eq(defaults.gateway, CR.DEFAULT_DHCP_CONFIG.gateway, "no server: gateway")
T.eq(defaults.dns, CR.DEFAULT_DHCP_CONFIG.dns, "no server: dns")
T.eq(defaults.prefix, CR.DEFAULT_DHCP_CONFIG.prefix, "no server: prefix")
T.eq(defaults.dhcp_port, CR.DEFAULT_DHCP_CONFIG.dhcp_port, "no server: dhcp_port")

-- a running DHCP server is the source of truth
local server = {
    lo = CR.parse_ipv4("10.200.0.60"), hi = CR.parse_ipv4("10.200.0.160"),
    lease = 1200, gw = CR.parse_ipv4("10.200.0.1"), dns = CR.parse_ipv4("10.200.0.2"),
    prefix = 24, port = 6701,
}
local lnode, lrpv = make_node({ dhcp_server = server }), make_rpv()
local lrt = CR.start_ha(lnode, lrpv)
CR.ha_handle(lrt, golden_request, PEER_IP, HA_PORT)
local live = CR.ha_parse(tostring(last_sent(lrpv).payload))
local lf = (live and live.fields) or {}
T.ok(live ~= nil, "the live-server reply parses")
T.eq(lf.pool_start, "10.200.0.60", "live server pool_start")
T.eq(lf.pool_end, "10.200.0.160", "live server pool_end")
T.eq(tonumber(lf.lease_time), 1200, "live server lease_time")
T.eq(lf.gateway, "10.200.0.1", "live server gateway")
T.eq(lf.dns, "10.200.0.2", "live server dns")
T.eq(tonumber(lf.prefix), 24, "live server prefix")
T.eq(tonumber(lf.dhcp_port), 6701, "live server dhcp_port")

-- role.txt pool keys are used when the server has not been started yet
local cnode = make_node({ cfg = {
    dhcp_pool = "10.200.0.100-10.200.0.120", dhcp_gw = "10.200.0.9",
    dhcp_lease = "900", dhcp_dns = "10.200.0.10", dhcp_port = "6702",
} })
local from_cfg = CR.ha_config_from_node(cnode)
T.eq(from_cfg.pool_start, "10.200.0.100", "cfg pool_start")
T.eq(from_cfg.pool_end, "10.200.0.120", "cfg pool_end")
T.eq(from_cfg.lease_time, 900, "cfg lease_time")
T.eq(from_cfg.gateway, "10.200.0.9", "cfg gateway")
T.eq(from_cfg.dns, "10.200.0.10", "cfg dns")
T.eq(from_cfg.dhcp_port, 6702, "cfg dhcp_port")

local broken_cfg = CR.ha_config_from_node(make_node({ cfg = { dhcp_pool = "not a pool" } }))
T.eq(broken_cfg.pool_start, CR.DEFAULT_DHCP_CONFIG.pool_start,
    "a broken pool spec falls back to the defaults")

-- ===== bad messages: log only, never a reply ================================
local qnode, qrpv = make_node(), make_rpv()
local qrt = CR.start_ha(qnode, qrpv)
local clock_now = 500
qrt.clock = function() return clock_now end
local function step()
    clock_now = clock_now + 2
end

local function probe(text, src)
    step()
    return CR.ha_handle(qrt, text, src or PEER_IP, HA_PORT)
end

T.eq(probe(""), "bad", "an empty datagram is rejected")
T.eq(sent_count(qrpv), 0, "an empty datagram gets no reply")
T.eq(probe("RPV1-HA/1 SYNC id=42"), "bad", "a request without a nonce is rejected")
T.eq(has_log(qnode, "reason=nonce_is_missing"), true, "the missing nonce is logged")
T.eq(probe("RPV1-HA/1 SYNC nonce=5"), "bad", "a request without an id is rejected")
T.eq(probe("RPV1-HA/1 HELLO id=42 nonce=5"), "bad", "an unknown method is rejected")
T.eq(probe("RPV1-HA/2 SYNC id=42 nonce=5"), "bad", "another protocol version is rejected")
T.eq(probe("RPV1-HA/1 SYNC id=42 nonce=5 garbage"), "bad", "a malformed field is rejected")
T.eq(probe("RPV1-HA/1 SYNC id=42 id=43 nonce=5"), "bad", "a duplicate field is rejected")
T.eq(probe("RPV1-HA/1 SYNC id=42 nonce=abc"), "bad", "a non-numeric nonce is rejected")
T.eq(sent_count(qrpv), 0, "no malformed datagram was answered")
T.eq(has_log(qnode, "CORE_ROUTER_HA_BAD"), true, "CORE_ROUTER_HA_BAD is logged")

local big = "RPV1-HA/1 SYNC id=42 nonce=5 " .. string.rep("x", CR.HA_MAX_BYTES)
T.eq(probe(big), "bad", "a datagram above 512 bytes is rejected")
T.eq(sent_count(qrpv), 0, "an oversized datagram gets no reply")
T.eq(has_log(qnode, "reason=datagram_too_large"), true, "the size rejection is logged")

local exact = "RPV1-HA/1 SYNC id=42 nonce=77"
local padded = exact .. string.rep(" ", CR.HA_MAX_BYTES - #exact)
T.eq(#padded, CR.HA_MAX_BYTES, "the boundary datagram is exactly 512 bytes")
T.eq(probe(padded), "replied", "a 512 byte datagram is still answered")
T.eq(sent_count(qrpv), 1, "the boundary datagram is answered once")
local over = exact .. string.rep(" ", CR.HA_MAX_BYTES - #exact + 1)
T.eq(probe(over), "bad", "513 bytes are rejected")
T.eq(sent_count(qrpv), 1, "513 bytes are not answered")

T.eq(probe("RPV1-HA/1 SYNC id=42 nonce=5 future=1"), "replied",
    "an unknown extra field stays forward compatible")
T.eq(sent_count(qrpv), 2, "the forward-compatible request is answered")
T.eq(probe("RPV1-HA/1 SYNC id=133 nonce=5"), "ignored", "a request naming this node is ignored")
T.eq(probe(BR.build_reply(CR.DEFAULT_DHCP_CONFIG, MASTER_ID, 9, PEER_ID)), "ignored",
    "a CFG reply is not mistaken for a request")
T.eq(sent_count(qrpv), 2, "ignored datagrams get no reply")
T.ok(qrt.stats.bad >= 8, "the bad-message counter moved")

-- ===== per-source rate limit ================================================
local rnode, rrpv = make_node(), make_rpv()
local rrt = CR.start_ha(rnode, rrpv)
local rate_now = 1000
rrt.clock = function() return rate_now end
local rate_request = BR.build_request(PEER_ID, 111)
for n = 1, CR.HA_RATE_LIMIT do
    local decision = CR.ha_handle(rrt, rate_request, PEER_IP, HA_PORT)
    T.eq(decision, "replied", "request " .. n .. " inside the limit is answered")
    T.eq(sent_count(rrpv), n, "reply " .. n .. " was sent")
end
T.eq(CR.ha_handle(rrt, rate_request, PEER_IP, HA_PORT), "rate",
    "the sixth request in one second is dropped")
T.eq(sent_count(rrpv), 5, "the sixth request gets no reply")
T.eq(has_log(rnode, "CORE_ROUTER_HA_RATE"), true, "CORE_ROUTER_HA_RATE is logged")
T.eq(rrt.stats.rate_limited, 1, "the rate counter moved")
T.eq(CR.ha_handle(rrt, rate_request, OTHER_IP, HA_PORT), "replied",
    "another source has its own bucket")
T.eq(sent_count(rrpv), 6, "the other source is answered")
rate_now = rate_now + 1.5
T.eq(CR.ha_handle(rrt, rate_request, PEER_IP, HA_PORT), "replied",
    "a new window admits the source again")
T.eq(sent_count(rrpv), 7, "the post-window request is answered")
T.eq(rrt.stats.requests, 8, "every datagram is counted")

-- ===== taken-over silence ===================================================
local snode, srpv = make_node(), make_rpv()
local srt = CR.start_ha(snode, srpv)
local silence_request = BR.build_request(PEER_ID, 222)
snode.ha_taken_over = true
T.eq(CR.ha_handle(srt, silence_request, PEER_IP, HA_PORT), "silent",
    "ha_taken_over silences the responder")
T.eq(sent_count(srpv), 0, "a taken-over node sends nothing")
T.eq(has_log(snode, "CORE_ROUTER_HA_SILENT"), true, "CORE_ROUTER_HA_SILENT is logged")
snode.ha_taken_over = false
T.eq(CR.ha_handle(srt, silence_request, OTHER_IP, HA_PORT), "replied",
    "clearing ha_taken_over restores the responder")
snode.ha_dhcp_active = true
T.eq(CR.ha_handle(srt, silence_request, PEER_IP, HA_PORT), "silent",
    "ha_dhcp_active also silences the responder")
T.eq(sent_count(srpv), 1, "the second silent request sends nothing")
T.eq(srt.stats.silent, 2, "the silence counter moved")
snode.ha_dhcp_active = false
T.eq(CR.ha_handle(srt, silence_request, PEER_IP, HA_PORT), "replied",
    "with both flags clear the responder answers again")
T.eq(sent_count(srpv), 2, "the answer is sent")

-- ===== reply address ========================================================
local anode, arpv = make_node(), make_rpv()
local art = CR.start_ha(anode, arpv)
CR.ha_handle(art, golden_request, PEER_IP, 1234)
T.eq(last_sent(arpv).dst, PEER_IP, "a distinct peer gets a unicast reply")
T.eq(last_sent(arpv).sport, 1234, "the requester source port is reused")
T.eq(last_sent(arpv).dport, HA_PORT, "the reply is addressed to the HA port")
CR.ha_handle(art, golden_request, PUBLIC_IP, HA_PORT)
T.eq(last_sent(arpv).dst, BCAST,
    "a peer that shares the VIP is answered on the broadcast address")
T.eq(CR.ha_reply_dst(art, PEER_IP), PEER_IP, "unicast helper keeps a distinct peer")
T.eq(CR.ha_reply_dst(art, PUBLIC_IP), BCAST, "unicast helper broadcasts the shared VIP")

-- ===== start_ha options =====================================================
local pnode, prpv = make_node(), make_rpv()
local prt = CR.start_ha(pnode, prpv, { ha_port = 6711 })
T.eq((pnode.binds[1] or {}).port, 6711, "ha_port overrides the bind port")
T.eq(prt and prt.port, 6711, "the runtime reports the overridden port")
CR.ha_handle(prt, golden_request, PEER_IP, 6711)
T.eq(last_sent(prpv).dport, 6711, "the reply uses the overridden port")
local again = CR.start_ha(pnode, prpv)
T.eq(again, prt, "a second start_ha returns the same runtime")
T.eq(#pnode.binds, 1, "a second start_ha does not bind twice")
local bad_port, bad_err = CR.start_ha(make_node(), make_rpv(), { ha_port = 0 })
T.ok(bad_port == nil, "ha_port 0 is refused")
T.eq(bad_err, "bad ha_port 0", "the bad port is named in the error")

local saved_global_rpv = rawget(_G, "rpv")
local saved_loaded_rpv = package and package.loaded and package.loaded.rpv
_G.rpv = nil
if package and package.loaded then package.loaded.rpv = nil end
local no_rpv, no_rpv_err = CR.start_ha(make_node(), {})
T.ok(no_rpv == nil, "start_ha refuses to bind without rpv.udp_send")
T.eq(no_rpv_err, "rpv.udp_send is required to answer", "the missing transport is named")
_G.rpv = saved_global_rpv
if package and package.loaded then package.loaded.rpv = saved_loaded_rpv end

-- ===== setup_router integration and the redstone lock =======================
local saved_rs = rawget(_G, "rs")
local saved_sleep = os.sleep
local rs_on = true
_G.rs = { getInput = function() return rs_on end }

local inode, irpv = make_node(), make_rpv()
local runtime = CR.setup_router(inode, irpv)
T.ok(runtime ~= nil, "setup_router returns a runtime")
T.eq(#inode.binds, 1, "setup_router binds the HA socket")
T.eq((inode.binds[1] or {}).port, HA_PORT, "setup_router binds 6710 by default")
T.ok(runtime and runtime.ha ~= nil, "the runtime exposes the HA state")
T.eq(runtime and runtime.ha_port, HA_PORT, "the runtime reports the HA port")
T.ok(has_log(inode, "CORE_ROUTER_HA_READY"), "setup logs the HA readiness")

local setup_nonce = 424242
deliver(runtime and runtime.ha, inode, BR.build_request(PEER_ID, setup_nonce), PEER_IP, HA_PORT)
T.eq(sent_count(irpv), 1, "the socket setup_router bound answers a SYNC")
local setup_reply = BR.parse_message(tostring(last_sent(irpv).payload))
local srf = (setup_reply and setup_reply.fields) or {}
T.eq(srf.master, "133", "the setup-bound reply names this node")
T.eq(srf.to, "42", "the setup-bound reply names the requester")
T.eq(srf.nonce, "424242", "the setup-bound reply echoes the nonce")

local dnode, drpv = make_node(), make_rpv()
local disabled = CR.setup_router(dnode, drpv, { ha_sync = false })
T.ok(disabled ~= nil, "setup_router still works with ha_sync = false")
T.eq(#dnode.binds, 0, "ha_sync = false leaves the port unbound")
T.eq(disabled and disabled.ha, nil, "ha_sync = false has no HA runtime")
T.ok(has_log(dnode, "CORE_ROUTER_HA_OFF"), "ha_sync = false is logged")

local onode, orpv = make_node(), make_rpv()
local overridden = CR.setup_router(onode, orpv, { ha_port = 6720 })
T.eq((onode.binds[1] or {}).port, 6720, "opts.ha_port reaches setup_router")
T.eq(overridden and overridden.ha_port, 6720, "the runtime keeps the override")

rs_on = false
os.sleep = function() error("redstone lock held") end
local lnode2, lrpv2 = make_node(), make_rpv()
local locked_ok = pcall(CR.setup_router, lnode2, lrpv2)
T.ok(not locked_ok, "setup_router blocks while the bottom face is unpowered")
T.eq(#lnode2.binds, 0, "nothing is bound while the lock is closed")
T.eq(lnode2.core_router_ha, nil, "no responder exists while the lock is closed")
T.ok(has_log(lnode2, "CORE_ROUTER_REDSTONE_WAIT"), "the closed lock is logged")
os.sleep = saved_sleep
rs_on = true
_G.rs = saved_rs

-- ===== primary-client log ===================================================
local clnode, clrpv = make_node(), make_rpv()
local clrt = CR.start_ha(clnode, clrpv, { ha_primary_client = true })
local cl_now = 2000
clrt.clock = function() return cl_now end
CR.ha_handle(clrt, golden_request, PEER_IP, HA_PORT)
cl_now = cl_now + 2
CR.ha_handle(clrt, golden_request, OTHER_IP, HA_PORT)
T.eq(sent_count(clrpv), 2, "the primary-client fixture answered twice")
T.eq(count_log(clnode, "CORE_ROUTER_HA_REPLY"), 2,
    "ha_primary_client logs every reply")
T.ok(has_log(clnode, "CORE_ROUTER_HA_REPLY to=42"), "the reply log names the requester")

local qlnode, qlrpv = make_node(), make_rpv()
local qlrt = CR.start_ha(qlnode, qlrpv)
local ql_now = 3000
qlrt.clock = function() return ql_now end
CR.ha_handle(qlrt, golden_request, PEER_IP, HA_PORT)
ql_now = ql_now + 2
CR.ha_handle(qlrt, golden_request, OTHER_IP, HA_PORT)
T.eq(count_log(qlnode, "CORE_ROUTER_HA_REPLY"), 1,
    "without the flag only the first reply is logged")

-- ===== counters and status text =============================================
T.eq(clrt.stats.requests, 2, "the request counter counts datagrams")
T.eq(clrt.stats.replies, 2, "the reply counter counts answers")
T.eq(clrt.stats.silent, 0, "nothing was silenced")
T.eq(grt.stats.replies, 1, "the golden fixture answered once")
T.eq(CR.ha_config_text(CR.DEFAULT_DHCP_CONFIG),
    "pool=10.200.0.50-10.200.0.150 lease=600s gw=10.200.0.1 dns=10.200.0.1 prefix=24 port=6700",
    "the config text keeps the operator-readable shape")
