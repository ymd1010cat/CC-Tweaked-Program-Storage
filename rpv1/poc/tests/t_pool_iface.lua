--[[- tests/t_pool_iface.lua - apps/core_router.lua: the optional pool interface.

A DHCP pool that does not live on the public wire (10.100.0.0/16 is the plan this
suite pins down) needs its own address, channel and connected route. The tests
drive M.enable_pool_iface offline: the node stub carries ifaces/by_side/
by_channel/routes, the rpv stub only supplies route_upsert (or nothing, to take
the local installer path).

Groups: cidr and subnet helpers, a normal pool interface, explicit pools,
idempotency, every failure code, the HA configuration source that reads
cfg.pool_iface, setup_router integration and the backup-side rule that refuses a
cross-subnet pool without a pool interface.
]]
local T, M = ...

local CR = M.core_router
local BR = M.backup_router
T.ok(CR ~= nil, "core_router module is loaded")
T.ok(BR ~= nil, "backup_router module is loaded")
if not CR or not BR then return end

-- ===== fixtures =============================================================
local function ip(text) return CR.parse_ipv4(text) end

local PUBLIC_IP = ip("10.200.0.1")
local POOL_IP = ip("10.100.0.1")

local function public_iface(addr)
    return {
        side = "left", name = "PUBLIC", ip = addr or PUBLIC_IP, prefix = 24,
        net = ip("10.200.0.0"), cidr = "10.200.0.1/24", mtu = 256,
        channel = 4001, linktype = "wired",
    }
end

local function make_node(opts)
    local o = opts or {}
    local node = {
        id = o.id or 133, mac = o.id or 133, role = "router",
        cfg = o.cfg or {}, stats = {}, logs = {}, tasks = {}, binds = {},
        arp = { cache = {} },
        ifaces = o.ifaces or { public_iface() },
        by_side = {}, by_channel = {},
        routes = M.route_new(),
    }
    for _, iface in ipairs(node.ifaces) do
        node.by_side[iface.side] = iface
        node.by_channel[iface.channel] = iface
        M.route_connected(node.routes, iface)
    end
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

-- only the routing entry point is used by enable_pool_iface; link_open is stubbed
-- so a missing modem in the emulator is not part of what these tests measure
local function make_rpv(opts)
    local o = opts or {}
    local rpv = { IP_BCAST = 4294967295, MAC_BCAST = 4294967295, ET_ARP = 2054, sent = {} }
    if o.route_upsert ~= false then
        function rpv.route_upsert(routes, prefix, net, iface, gw, kind)
            return M.route_upsert(routes, prefix, net, iface, gw, kind)
        end
    end
    -- core_router.find_rpv() recognises a transport by one of these two, and this
    -- hook is the one a real node would chain in front of the NAT hook
    function rpv.nat_input_hook(node, iface, h) return nil end
    function rpv.link_open(iface) rpv.opened = (rpv.opened or 0) + 1 return true end
    function rpv.udp_send(node, dst, dport, sport, payload)
        rpv.sent[#rpv.sent + 1] = { dst = dst, dport = dport, payload = payload }
        return true
    end
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

local SPEC = { side = "back", channel = 4200, cidr = "10.100.0.1/16", mtu = 256 }

local function copy_spec(extra)
    local spec = {
        side = SPEC.side, channel = SPEC.channel, cidr = SPEC.cidr, mtu = SPEC.mtu,
    }
    for key, value in pairs(extra or {}) do spec[key] = value end
    return spec
end

local function route_count(node)
    return #node.routes.entries
end

-- ===== cidr and subnet helpers =============================================
local c_ip, c_prefix = CR.parse_cidr("10.100.0.1/16")
T.eq(c_ip, POOL_IP, "the cidr address parses")
T.eq(c_prefix, 16, "the cidr prefix parses")
T.eq(CR.parse_cidr(" 10.100.0.1/16 "), POOL_IP, "surrounding space is trimmed")
T.eq(CR.parse_cidr("10.100.0.1"), nil, "a cidr without a prefix is refused")
T.eq(CR.parse_cidr("10.100.0.1/7"), nil, "a prefix below the minimum is refused")
T.eq(CR.parse_cidr("10.100.0.1/31"), nil, "a prefix above the maximum is refused")
T.eq(CR.parse_cidr("10.100.0.1/16/2"), nil, "two slashes are refused")
T.eq(CR.parse_cidr("300.1.1.1/16"), nil, "an octet above 255 is refused")
T.eq(CR.parse_cidr(nil), nil, "a non-string cidr is refused")
local _, _, cidr_reason = CR.parse_cidr("10.100.0.1")
T.eq(cidr_reason, "expected a.b.c.d/prefix", "the cidr failure names its shape")

T.eq(CR.masked_ip(POOL_IP, 16), ip("10.100.0.0"), "masking keeps the network address")
T.eq(CR.masked_ip(POOL_IP, 24), ip("10.100.0.0"), "a /24 mask zeroes the fourth octet")
T.eq(CR.masked_ip(ip("10.100.7.9"), 16), ip("10.100.0.0"), "a /16 mask zeroes the last two")
T.eq(CR.masked_ip(POOL_IP, 32), POOL_IP, "a /32 mask keeps the host")
T.eq(CR.masked_ip(nil, 16), nil, "masking nil is nil")
T.eq(CR.masked_ip(POOL_IP, 33), nil, "a prefix above 32 is refused")

local u_lo, u_hi = CR.subnet_usable(ip("10.100.0.0"), 16)
T.eq(u_lo, ip("10.100.0.1"), "the first usable host of a /16")
T.eq(u_hi, ip("10.100.255.254"), "the last usable host of a /16")
local n_lo, n_hi = CR.subnet_usable(ip("10.100.0.0"), 30)
T.eq(n_lo, ip("10.100.0.1"), "the first usable host of a /30")
T.eq(n_hi, ip("10.100.0.2"), "the last usable host of a /30")
T.eq(CR.subnet_usable(ip("10.100.0.0"), 31), nil, "a /31 has no usable host range")

-- ===== a normal pool interface =============================================
local node = make_node()
local rpv = make_rpv()
local before_routes = route_count(node)
local rt = CR.enable_pool_iface(node, rpv, copy_spec())
T.ok(rt ~= nil, "the pool interface is created")
T.eq(rt and rt.cidr, "10.100.0.1/16", "the runtime reports the cidr")
T.eq(rt and rt.prefix, 16, "the runtime reports the prefix")
T.eq(rt and rt.net, ip("10.100.0.0"), "the runtime reports the network")
T.eq(rt and rt.side, "back", "the runtime reports the side")
T.eq(rt and rt.channel, 4200, "the runtime reports the channel")
T.eq(rt and rt.mtu, 256, "the runtime reports the mtu")
T.eq(rt and rt.name, "POOL", "the default interface name is POOL")
T.eq(#node.ifaces, 2, "the node now has two interfaces")
T.eq(node.by_side["back"], rt and rt.iface, "the side index points at the new interface")
T.eq(node.by_channel[4200], rt and rt.iface, "the channel index points at the new interface")
T.eq(node.core_router_pool_iface, rt, "the runtime is kept on the node")
T.eq(rt and rt.iface.ip, POOL_IP, "the interface owns the pool address")
T.eq(rt and rt.iface.net, ip("10.100.0.0"), "the interface knows its network")
T.eq(rt and rt.iface.mtu, 256, "the interface keeps the mtu")
T.eq(rt and rt.iface.linktype, "wired", "the interface is a wired link")
T.eq(rt and rt.iface.pool_iface, true, "the interface is marked as the pool interface")

T.eq(route_count(node), before_routes + 1, "one connected route was installed")
local entry = M.route_lookup(node.routes, ip("10.100.5.5"))
T.ok(entry ~= nil, "the pool subnet resolves")
T.eq(entry and entry.prefix, 16, "the route is a /16")
T.eq(entry and entry.net, ip("10.100.0.0"), "the route points at 10.100.0.0")
T.eq(entry and entry.kind, "connected", "the route is connected")
T.eq(entry and entry.iface, rt and rt.iface, "the route leaves through the pool interface")
T.eq(rt and rt.route, "upsert", "rpv.route_upsert installed the route")
local path = M.route_path(node.routes, ip("10.100.5.5"))
T.eq(path and path.iface, rt and rt.iface, "the path uses the pool interface")
T.eq(path and path.next_hop, ip("10.100.5.5"), "the next hop is the destination itself")

T.eq(rt and rt.pool_start_str, "10.100.0.2", "the default pool skips the interface address")
T.eq(rt and rt.pool_end_str, "10.100.255.254", "the default pool ends at the broadcast")
T.eq(node.cfg.dhcp_pool, "10.100.0.2-10.100.255.254", "the pool is written for rpv")
T.eq(node.cfg.dhcp_gw, "10.100.0.1", "the gateway is the pool interface")
T.eq(node.cfg.dhcp_dns, "10.100.0.1", "the DNS server defaults to the gateway")
T.ok(has_log(node, "CORE_ROUTER_POOL_IFACE_READY"), "the ready line is logged")
T.ok(has_log(node, "pool=10.100.0.2-10.100.255.254"), "the ready line names the pool")
T.eq(rpv.opened, 1, "the link is opened once")

-- ===== idempotency =========================================================
local same_routes = route_count(node)
local again = CR.enable_pool_iface(node, rpv, copy_spec())
T.eq(again, rt, "the same spec returns the same runtime")
T.eq(#node.ifaces, 2, "the same spec adds no interface")
T.eq(route_count(node), same_routes, "the same spec adds no route")
T.ok(has_log(node, "CORE_ROUTER_POOL_IFACE_REUSE"), "the reuse is logged")

-- the connected route is idempotent on its own too (the local installer path)
local local_node = make_node()
local local_rpv = make_rpv({ route_upsert = false })
local local_rt = CR.enable_pool_iface(local_node, local_rpv, copy_spec())
T.ok(local_rt ~= nil, "a transport without route_upsert still works")
T.eq(local_rt and local_rt.route, "added", "the local installer reports the new route")
local routes_after_first = route_count(local_node)
local second_entry, how = CR.install_connected_route(local_node.routes, 16,
    ip("10.100.0.0"), local_rt and local_rt.iface)
T.ok(second_entry ~= nil, "the connected installer finds the existing route")
T.eq(how, "existing", "the connected installer reports the reuse")
T.eq(route_count(local_node), routes_after_first, "the connected installer adds no duplicate")
T.eq(#local_node.ifaces, 2, "the local-path node has one pool interface")

-- ===== explicit pools ======================================================
local ex_node = make_node()
local ex_rt = CR.enable_pool_iface(ex_node, make_rpv(), copy_spec({ pool = "10.100.0.10-10.100.1.250" }))
T.eq(ex_rt and ex_rt.pool_start_str, "10.100.0.10", "an explicit pool keeps its start")
T.eq(ex_rt and ex_rt.pool_end_str, "10.100.1.250", "an explicit pool keeps its end")
T.eq(ex_node.cfg.dhcp_pool, "10.100.0.10-10.100.1.250", "the explicit pool is written")

local se_node = make_node()
local se_rt = CR.enable_pool_iface(se_node, make_rpv(),
    copy_spec({ pool_start = "10.100.9.1", pool_end = "10.100.9.99" }))
T.eq(se_rt and se_rt.pool_start_str, "10.100.9.1", "pool_start is honoured")
T.eq(se_rt and se_rt.pool_end_str, "10.100.9.99", "pool_end is honoured")

local cf_node = make_node({ cfg = { dhcp_pool = "10.100.20.1-10.100.20.50" } })
local cf_rt = CR.enable_pool_iface(cf_node, make_rpv(), copy_spec())
T.eq(cf_rt and cf_rt.pool_start_str, "10.100.20.1", "a configured pool inside the subnet is kept")
T.eq(cf_node.cfg.dhcp_pool, "10.100.20.1-10.100.20.50", "the configured pool is unchanged")

local gw_node = make_node({ cfg = { dhcp_gw = "10.100.0.254", dhcp_dns = "10.100.0.53" } })
CR.enable_pool_iface(gw_node, make_rpv(), copy_spec())
T.eq(gw_node.cfg.dhcp_gw, "10.100.0.254", "an explicit gateway survives")
T.eq(gw_node.cfg.dhcp_dns, "10.100.0.53", "an explicit DNS server survives")

local off_node = make_node()
CR.enable_pool_iface(off_node, make_rpv(), copy_spec({ set_pool = false, set_gateway = false }))
T.eq(off_node.cfg.dhcp_pool, nil, "set_pool = false leaves the pool key alone")
T.eq(off_node.cfg.dhcp_gw, nil, "set_gateway = false leaves the gateway alone")

-- ===== failure codes =======================================================
local function failure(spec, opts)
    local node = (opts and opts.node) or make_node(opts and opts.cfg and { cfg = opts.cfg } or nil)
    local result, reason = CR.enable_pool_iface(node, (opts and opts.rpv) or make_rpv(), spec)
    return result, reason, node
end

local bad_cidr, bad_cidr_reason = failure(copy_spec({ cidr = "10.100.0.1" }))
T.eq(bad_cidr, nil, "a bad cidr is refused")
T.eq(bad_cidr_reason, "bad_cidr", "the bad cidr names its reason")
T.ok(has_log((select(3, failure(copy_spec({ cidr = "10.100.0.1" })))), "CORE_ROUTER_POOL_IFACE_FAIL"),
    "the bad cidr is logged as a pool failure")

local bad_side, bad_side_reason = failure(copy_spec({ side = "" }))
T.eq(bad_side, nil, "an empty side is refused")
T.eq(bad_side_reason, "bad_side", "the empty side names its reason")
local nil_side_spec = copy_spec()
nil_side_spec.side = nil
T.eq((select(2, failure(nil_side_spec))), "bad_side", "a nil side is refused")

local bad_channel, bad_channel_reason = failure(copy_spec({ channel = 0 }))
T.eq(bad_channel, nil, "channel 0 is refused")
T.eq(bad_channel_reason, "bad_channel", "channel 0 names its reason")
T.eq((select(2, failure(copy_spec({ channel = 70000 })))), "bad_channel",
    "a channel above 65535 is refused")
T.eq((select(2, failure(copy_spec({ channel = "x" })))), "bad_channel",
    "a non-numeric channel is refused")

local bad_mtu, bad_mtu_reason = failure(copy_spec({ mtu = 40 }))
T.eq(bad_mtu, nil, "an mtu below 68 is refused")
T.eq(bad_mtu_reason, "bad_mtu", "the small mtu names its reason")
T.eq((select(2, failure(copy_spec({ mtu = 70000 })))), "bad_mtu", "a huge mtu is refused")

local nil_spec, nil_spec_reason = CR.enable_pool_iface(make_node(), make_rpv(), nil)
T.eq(nil_spec, nil, "a missing spec is refused")
T.eq(nil_spec_reason, "no_spec", "the missing spec names its reason")
local nil_node, nil_node_reason = CR.enable_pool_iface(nil, make_rpv(), copy_spec())
T.eq(nil_node, nil, "a missing node is refused")
T.eq(nil_node_reason, "no_node", "the missing node names its reason")

local no_ifaces_node = make_node()
no_ifaces_node.ifaces = nil
T.eq((select(2, CR.enable_pool_iface(no_ifaces_node, make_rpv(), copy_spec()))), "no_ifaces",
    "a node without an interface list is refused")
local no_routes_node = make_node()
no_routes_node.routes = nil
T.eq((select(2, CR.enable_pool_iface(no_routes_node, make_rpv(), copy_spec()))), "no_route_table",
    "a node without a route table is refused")

local side_node = make_node()
side_node.by_side["back"] = side_node.ifaces[1]
local side_res, side_reason = CR.enable_pool_iface(side_node, make_rpv(), copy_spec())
T.eq(side_res, nil, "a used side is refused")
T.eq(side_reason, "iface_in_use", "the used side names its reason")
T.eq(#side_node.ifaces, 1, "the refused side added no interface")

local ch_node = make_node()
local taken = { side = "back2", name = "OTHER", ip = ip("10.55.0.1"), prefix = 24,
    net = ip("10.55.0.0"), cidr = "10.55.0.1/24", mtu = 256, channel = 4200 }
ch_node.ifaces[#ch_node.ifaces + 1] = taken
ch_node.by_channel[4200] = taken
ch_node.by_side["back2"] = taken
local ch_res, ch_reason = CR.enable_pool_iface(ch_node, make_rpv(), copy_spec())
T.eq(ch_res, nil, "a used channel is refused")
T.eq(ch_reason, "iface_in_use", "the used channel names its reason")

local ov_node = make_node()
local wide = { side = "back2", name = "WIDE", ip = ip("10.100.0.1"), prefix = 16,
    net = ip("10.100.0.0"), cidr = "10.100.0.1/16", mtu = 256, channel = 4201 }
ov_node.ifaces[#ov_node.ifaces + 1] = wide
ov_node.by_channel[4201] = wide
ov_node.by_side["back2"] = wide
local ov_res, ov_reason = CR.enable_pool_iface(ov_node, make_rpv(),
    copy_spec({ cidr = "10.100.5.1/24", channel = 4202, side = "back" }))
T.eq(ov_res, nil, "an overlapping subnet is refused")
T.eq(ov_reason, "iface_overlap", "the overlap names its reason")

local offp_node = make_node()
local offp_res, offp_reason = CR.enable_pool_iface(offp_node, make_rpv(),
    copy_spec({ pool = "10.200.0.50-10.200.0.150" }))
T.eq(offp_res, nil, "a pool outside the pool subnet is refused")
T.eq(offp_reason, "pool_off_subnet", "the off-subnet pool names the required reason")
T.ok(has_log(offp_node, "CORE_ROUTER_POOL_IFACE_FAIL reason=pool_off_subnet"),
    "the off-subnet pool is logged as a failure")
T.ok(has_log(offp_node, "pool=10.200.0.50-10.200.0.150"), "the log names the rejected pool")
T.eq(#offp_node.ifaces, 1, "a refused pool adds no interface")
T.eq(route_count(offp_node), 1, "a refused pool adds no route")
T.eq(offp_node.cfg.dhcp_pool, nil, "a refused pool writes no cfg key")

local half_node = make_node()
local half_res, half_reason = CR.enable_pool_iface(half_node, make_rpv(),
    copy_spec({ pool_start = "10.100.0.10", pool_end = "10.101.0.10" }))
T.eq(half_res, nil, "a pool that straddles the boundary is refused")
T.eq(half_reason, "pool_off_subnet", "the straddling pool names the required reason")

local bad_pool, bad_pool_reason = CR.enable_pool_iface(make_node(), make_rpv(),
    copy_spec({ pool = "10.100.0.9-10.100.0.2" }))
T.eq(bad_pool, nil, "an inverted pool is refused")
T.eq(bad_pool_reason, "bad_pool", "the inverted pool names its reason")
T.eq((select(2, CR.enable_pool_iface(make_node(), make_rpv(), copy_spec({ pool = "nonsense" })))),
    "bad_pool", "an unparsable pool is refused")

local edge_node = make_node()
local edge_res, edge_reason = CR.enable_pool_iface(edge_node, make_rpv(),
    copy_spec({ pool = "10.100.0.0-10.100.0.50" }))
T.eq(edge_res, nil, "a pool that starts at the network address is refused")
T.eq(edge_reason, "pool_off_subnet", "the network address names the subnet rule")

-- ===== the HA configuration source =========================================
local ha_node = make_node()
local pool_rt = CR.enable_pool_iface(ha_node, make_rpv(), copy_spec())
local derived = CR.ha_config_from_node(ha_node)
T.eq(derived.pool_start, "10.100.0.2", "the HA pool starts at the interface range")
T.eq(derived.pool_end, "10.100.255.254", "the HA pool ends at the broadcast")
T.eq(derived.gateway, "10.100.0.1", "the HA gateway is the pool interface")
T.eq(derived.dns, "10.100.0.1", "the HA DNS server defaults to that gateway")
T.eq(derived.prefix, 16, "the HA prefix is the pool interface prefix")
T.eq(derived.lease_time, CR.DEFAULT_DHCP_CONFIG.lease_time, "the lease default is kept")
T.eq(derived.dhcp_port, CR.DEFAULT_DHCP_CONFIG.dhcp_port, "the port default is kept")

local cfg_iface_node = make_node()
CR.enable_pool_iface(cfg_iface_node, make_rpv(), copy_spec())
cfg_iface_node.cfg.pool_iface = "back"
local by_name = CR.ha_config_from_node(cfg_iface_node)
T.eq(by_name.pool_start, "10.100.0.2", "cfg.pool_iface may name the side")
local cfg_iface_cidr = make_node()
CR.enable_pool_iface(cfg_iface_cidr, make_rpv(), copy_spec())
cfg_iface_cidr.cfg.pool_iface = "10.100.0.1/16"
local by_cidr = CR.ha_config_from_node(cfg_iface_cidr)
T.eq(by_cidr.pool_start, "10.100.0.2", "cfg.pool_iface may be the cidr")
T.eq(by_cidr.gateway, "10.100.0.1", "the cidr form keeps the gateway")

local explicit_node = make_node()
CR.enable_pool_iface(explicit_node, make_rpv(), copy_spec())
explicit_node.cfg.dhcp_pool = "10.100.7.1-10.100.7.20"
local explicit = CR.ha_config_from_node(explicit_node)
T.eq(explicit.pool_start, "10.100.7.1", "an explicit cfg.dhcp_pool wins over the interface range")
T.eq(explicit.pool_end, "10.100.7.20", "the explicit end is kept")
T.eq(explicit.gateway, "10.100.0.1", "the pool interface supplies the gateway")

explicit_node.cfg.dhcp_gw = "10.100.0.254"
T.eq(CR.ha_config_from_node(explicit_node).gateway, "10.100.0.254",
    "an explicit cfg.dhcp_gw still wins")

local srv_node = make_node()
CR.enable_pool_iface(srv_node, make_rpv(), copy_spec())
srv_node.dhcp_server = {
    lo = ip("10.100.30.10"), hi = ip("10.100.30.20"), lease = 300,
    gw = ip("10.100.0.1"), dns = ip("10.100.0.1"), prefix = 16, port = 6700,
}
local live = CR.ha_config_from_node(srv_node)
T.eq(live.pool_start, "10.100.30.10", "the live DHCP server still wins over everything")
T.eq(live.lease_time, 300, "the live lease is reported")

local no_pool_node = make_node({ cfg = { pool_iface = "does-not-exist" } })
local fallback = CR.ha_config_from_node(no_pool_node)
T.eq(fallback.pool_start, CR.DEFAULT_DHCP_CONFIG.pool_start,
    "an unknown pool_iface falls back to the defaults")
T.eq(fallback.gateway, CR.DEFAULT_DHCP_CONFIG.gateway,
    "the default gateway rule is unchanged")

-- the reply a standby parses must carry the cross-subnet pool unchanged
local reply_text = CR.ha_build_reply(derived, 42, 7, 133)
local parsed_reply = BR.parse_message(reply_text)
local pcfg = BR.parse_config((parsed_reply and parsed_reply.fields) or {})
T.ok(pcfg ~= nil, "the cross-subnet reply is a valid CFG")
T.eq(pcfg and pcfg.pool_start, "10.100.0.2", "the reply carries the cross-subnet pool start")
T.eq(pcfg and pcfg.pool_end, "10.100.255.254", "the reply carries the cross-subnet pool end")
T.eq(pcfg and pcfg.gateway, "10.100.0.1", "the reply carries the pool gateway")
T.eq(pcfg and pcfg.prefix, 16, "the reply carries the /16 prefix")

-- ===== setup_router integration ============================================
local saved_rs = rawget(_G, "rs")
_G.rs = { getInput = function() return true end }

local setup_node = make_node({ cfg = {} })
setup_node.routes = M.route_new()
for _, iface in ipairs(setup_node.ifaces) do M.route_connected(setup_node.routes, iface) end
local setup_rpv = make_rpv()
local runtime = CR.setup_router(setup_node, setup_rpv, { pool_iface = copy_spec() })
T.ok(runtime ~= nil, "setup_router returns a runtime")
T.ok(runtime and runtime.pool_iface ~= nil, "the runtime carries the pool interface")
T.eq(runtime and runtime.pool, "10.100.0.2-10.100.255.254", "the runtime reports the pool")
T.eq(#setup_node.ifaces, 2, "setup_router created the pool interface")
T.ok(has_log(setup_node, "CORE_ROUTER_POOL_IFACE_READY"), "the pool interface is logged")
T.ok(has_log(setup_node, "pool_iface=10.100.0.1/16"),
    "the ready line names the pool interface")
T.ok(has_log(setup_node, "CORE_ROUTER_HA_READY"), "the HA responder still starts")

local cfg_node = make_node({ cfg = { pool_iface = copy_spec() } })
cfg_node.routes = M.route_new()
local cfg_runtime = CR.setup_router(cfg_node, make_rpv(), { ha_sync = false })
T.ok(cfg_runtime and cfg_runtime.pool_iface ~= nil, "cfg.pool_iface reaches setup_router")
T.eq(#cfg_node.ifaces, 2, "cfg.pool_iface created the interface")

local off_setup_node = make_node({ cfg = {} })
off_setup_node.routes = M.route_new()
local off_runtime = CR.setup_router(off_setup_node, make_rpv(), {
    ha_sync = false, pool_iface = copy_spec({ pool = "10.200.0.50-10.200.0.150" }),
})
T.ok(off_runtime ~= nil, "a refused pool interface does not stop the boot")
T.eq(off_runtime and off_runtime.pool_iface, nil, "the refused pool interface is not in the runtime")
T.eq(#off_setup_node.ifaces, 1, "the refused pool interface was not created")
T.ok(has_log(off_setup_node, "CORE_ROUTER_POOL_IFACE_SKIP"), "the refusal is logged at boot")

local plain_node = make_node({ cfg = {} })
plain_node.routes = M.route_new()
local plain_runtime = CR.setup_router(plain_node, make_rpv(), { ha_sync = false })
T.eq(plain_runtime and plain_runtime.pool_iface, nil, "without a spec no pool interface is made")
T.eq(#plain_node.ifaces, 1, "the interface list is untouched without a spec")

_G.rs = saved_rs

-- ===== the standby side: an off-subnet pool is refused =====================
local function backup_node(opts)
    local o = opts or {}
    local node = {
        id = 42, mac = 42, role = "router", cfg = o.cfg or {}, logs = {},
        ifaces = o.ifaces or { public_iface(PUBLIC_IP) },
        by_side = {}, by_channel = {}, routes = M.route_new(),
        stats = {},
    }
    for _, iface in ipairs(node.ifaces) do
        node.by_side[iface.side] = iface
        node.by_channel[iface.channel] = iface
        M.route_connected(node.routes, iface)
    end
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    return node
end

local function backup_rt(node, cfg)
    local rt = {
        node = node, rpv = { IP_BCAST = 4294967295, MAC_BCAST = 4294967295, ET_ARP = 2054 },
        role = "standby", mode = "STANDBY", shared = true, vip = PUBLIC_IP,
        master = PUBLIC_IP, public_iface = node.ifaces[1],
        opt = BR.options({ announce_gap = 0 }),
        stats = { takeovers = 0 }, misses = 3, started_at = 0, last_master_seen = 0,
        synced_dhcp_config = cfg,
    }
    return rt
end

local off_cfg = {
    pool_start = "10.100.0.2", pool_end = "10.100.255.254",
    pool_start_int = ip("10.100.0.2"), pool_end_int = ip("10.100.255.254"),
    lease_time = 600, gateway = "10.100.0.1", dns = "10.100.0.1",
    prefix = 16, dhcp_port = 6700,
}
local refuse_node = backup_node()
local refuse_rt = backup_rt(refuse_node, off_cfg)
T.eq(BR.pool_iface_for(refuse_node, off_cfg, refuse_node.ifaces[1]), nil,
    "a node without a pool interface owns no pool subnet")
T.eq(BR.takeover(refuse_rt, "test"), false, "a cross-subnet pool without a pool interface is refused")
T.eq(refuse_rt.mode, "STANDBY", "the refused takeover stays on standby")
T.eq(refuse_rt.pool_off_subnet, true, "the runtime records the off-subnet condition")
T.eq(refuse_rt.node.ha_dhcp_active, nil, "no DHCP server was started")
T.eq(refuse_rt.stats.takeovers, 0, "the takeover counter did not move")
T.ok(count_log(refuse_node, "HA_DHCP_POOL_OFF_SUBNET") >= 1,
    "HA_DHCP_POOL_OFF_SUBNET is logged")
T.ok(has_log(refuse_node, "hint=needs_pool_iface"), "the log asks for a pool interface")
T.ok(has_log(refuse_node, "TAKEOVER_ABORT reason=pool_off_subnet"),
    "the abort names the pool subnet")

-- the same node with a pool interface (what core_router.enable_pool_iface makes)
local pool_node = backup_node()
local pool_iface_rt = CR.enable_pool_iface(pool_node, make_rpv(), copy_spec())
T.ok(pool_iface_rt ~= nil, "the backup side gets its own pool interface")
T.eq(BR.pool_iface_for(pool_node, off_cfg, pool_node.ifaces[1]), pool_iface_rt and pool_iface_rt.iface,
    "the pool interface owns the pool subnet")
local pool_rt_backup = backup_rt(pool_node, off_cfg)
function pool_rt_backup.rpv.dhcp_server_start() return nil end
T.eq(BR.takeover(pool_rt_backup, "test"), false,
    "the takeover gets past the pool gate and fails at DHCP instead")
T.ok(has_log(pool_node, "HA_DHCP_POOL_OFF_SUBNET") == false,
    "with a pool interface the off-subnet line is not logged")
T.ok(has_log(pool_node, "TAKEOVER_ABORT reason=dhcp_start"),
    "the failure moved past the pool check")

-- a pool inside the VIP subnet is still served without any pool interface
local same_cfg = BR.copy_config(BR.DEFAULT_DHCP_CONFIG)
same_cfg.pool_start_int = ip("10.200.0.50")
same_cfg.pool_end_int = ip("10.200.0.150")
local same_node = backup_node()
local same_rt = backup_rt(same_node, same_cfg)
function same_rt.rpv.dhcp_server_start() return nil end
T.eq(BR.takeover(same_rt, "test"), false, "the same-subnet takeover also needs DHCP")
T.ok(count_log(same_node, "HA_DHCP_POOL_OFF_SUBNET") == 0,
    "a same-subnet pool never logs the off-subnet line")
