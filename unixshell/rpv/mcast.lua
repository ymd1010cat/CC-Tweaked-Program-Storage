--[[- rpv/mcast.lua ? multicast groups and broadcast/multicast domain control.

CC networks are small and flat, so "multicast" here is deliberately simple: a
multicast packet is an IP datagram to an address in 224.0.0.0/4 sent as an L2
broadcast on the local segment, and every receiver keeps only the groups it joined.
Routers decide, per group, which segments may exchange group traffic
(`mcast_domains=LAN-A>LAN-B,LAN-B>LAN-A`), with a per-group rate limit so one noisy
sender cannot flood a bridged domain.

Because limited broadcast (255.255.255.255) is *not* forwarded by the IP layer by
default, the same domain machinery can optionally relay it (`bcast_relay=LAN-A>LAN-B`)
and rate-limit it -- that is the "broadcast domain control" half.

Configuration (node keys):
    mcast=1                          enable the group/domain machinery on a router
    mcast_groups=239.1.1.1,...       groups this node joins (host side)
    mcast_domains=LAN-A>LAN-B,...    allowed ingress>egress pairs for group traffic
    mcast_rate=20                    max group packets per second per (group, ingress)
    bcast_relay=LAN-A>LAN-B,...      also relay limited broadcast across these pairs
    bcast_rate=10                    rate limit for relayed broadcasts

API: rpv.mcast_setup(node), rpv.mcast_join(node, group), rpv.mcast_leave(node, group),
     rpv.mcast_send(node, group, dport, data), rpv.mcast_joined(node, group),
     rpv.mcast_test(ip), rpv.mcast_input_hook(node, iface, h, payload)

Logs: MCAST_START, MCAST_JOIN, MCAST_SEND, MCAST_FORWARD, MCAST_LOCAL, MCAST_DENY,
MCAST_RATE_DROP, BCAST_FORWARD, BCAST_RATE_DROP, MCAST_STATE.
]]
local M = ...
local u8, u16, u32, r16, byte, sub = M.u8, M.u16, M.u32, M.r16, M.byte, M.sub

local function parse_pairs(spec)
    local out = {}
    for pair in tostring(spec or ""):gmatch("[^,]+") do
        local a, b = pair:match("^%s*([%w%-_]+)%s*>%s*([%w%-_]+)%s*$")
        if a then out[a .. ">" .. b] = true end
    end
    return out
end

function M.mcast_test(ip)
    return ip >= M.ip2int("224.0.0.0") and ip <= M.ip2int("239.255.255.255")
end

function M.mcast_new(node, opts)
    local groups = {}
    for g in tostring(node.cfg.mcast_groups or ""):gmatch("[^,]+") do
        local s = g:match("^%s*([%d%.]+)%s*$")
        if s and M.mcast_test(M.ip2int(s)) then groups[M.ip2int(s)] = true end
    end
    return {
        node = node,
        groups = groups,
        domains = parse_pairs(node.cfg.mcast_domains),
        bcast = parse_pairs(node.cfg.bcast_relay),
        rate = tonumber(node.cfg.mcast_rate) or 20,
        bcast_rate = tonumber(node.cfg.bcast_rate) or 10,
        buckets = {},                -- key -> {n, t0}
        sent = 0, local_deliver = 0, forwarded = 0, denied = 0, rate_drops = 0,
        bcast_forwarded = 0, bcast_drops = 0,
    }
end

function M.mcast_setup(node, opts)
    if node.cfg.mcast ~= "1" and not node.cfg.mcast_groups then return nil end
    local mc = M.mcast_new(node, opts)
    node.mcast = mc
    local ng, nd = 0, 0
    for _ in pairs(mc.groups) do ng = ng + 1 end
    for _ in pairs(mc.domains) do nd = nd + 1 end
    node:log("MCAST_START groups=%d domains=%d rate=%d/s bcast_relay=%d", ng, nd, mc.rate,
        (function() local c = 0 for _ in pairs(mc.bcast) do c = c + 1 end return c end)())
    node:add_task("mcast", function()
        while true do
            os.sleep(5)
            node:log("MCAST_STATE joined=%d sent=%d local=%d forwarded=%d denied=%d rate_drops=%d bcast_fwd=%d bcast_drops=%d",
                (function() local c = 0 for _ in pairs(mc.groups) do c = c + 1 end return c end)(),
                mc.sent, mc.local_deliver, mc.forwarded, mc.denied, mc.rate_drops, mc.bcast_forwarded, mc.bcast_drops)
        end
    end)
    return mc
end

function M.mcast_join(node, group)
    if not node.mcast then return false end
    local ip = type(group) == "number" and group or M.ip2int(group)
    if not M.mcast_test(ip) then return false end
    node.mcast.groups[ip] = true
    node:log("MCAST_JOIN group=%s", M.int2ip(ip))
    return true
end

function M.mcast_leave(node, group)
    if not node.mcast then return false end
    node.mcast.groups[type(group) == "number" and group or M.ip2int(group)] = nil
    return true
end

function M.mcast_joined(node, group)
    if not node.mcast then return false end
    return node.mcast.groups[type(group) == "number" and group or M.ip2int(group)] == true
end

-- send to a group: L2 broadcast on the segment the iface is on
function M.mcast_send(node, group, dport, data, sport, iface)
    local ip = type(group) == "number" and group or M.ip2int(group)
    if not M.mcast_test(ip) then return false end
    sport = sport or dport
    if node.udp then node.udp.tx = node.udp.tx + 1 end
    local len = 8 + #data
    local src = (iface and iface.ip) or (node.ifaces[1] and node.ifaces[1].ip) or 0
    local pseudo = u32(src) .. u32(ip) .. u8(0) .. u8(M.IP_UDP) .. u16(len)
    local ck = M.cksum(pseudo .. u16(sport) .. u16(dport) .. u16(len) .. u16(0) .. data)
    if ck == 0 then ck = 0xFFFF end
    local pkt = u16(sport) .. u16(dport) .. u16(len) .. u16(ck) .. data
    if node.mcast then node.mcast.sent = node.mcast.sent + 1 end
    node:log("MCAST_SEND group=%s dport=%d bytes=%d", M.int2ip(ip), dport, #data)
    return node:send_ip(ip, M.IP_UDP, pkt, 1, src)
end

local function bucket_ok(mc, key, limit, now)
    local b = mc.buckets[key]
    if not b or now - b.t0 >= 1 then
        mc.buckets[key] = { n = 1, t0 = now }
        return true
    end
    b.n = b.n + 1
    return b.n <= limit
end

-- hook from ip_deliver: decides delivery/forwarding for group and (optionally)
-- limited-broadcast traffic. Returns "local" (deliver here), "forward" with an
-- egress iface list, or "drop".
function M.mcast_input_hook(node, iface, h, payload)
    local mc = node.mcast
    if not mc then return nil end
    local now = os.clock()

    if h.dst == M.IP_BCAST then
        -- broadcast domain control: relay only across allowed ingress>egress pairs
        local egress = {}
        for pair in pairs(mc.bcast) do
            local a, b = pair:match("^([^>]+)>(.+)$")
            if a == iface.name then egress[#egress + 1] = b end
        end
        if #egress == 0 then return nil end
        if not bucket_ok(mc, "bcast:" .. iface.name, mc.bcast_rate, now) then
            mc.bcast_drops = mc.bcast_drops + 1
            node:log("BCAST_RATE_DROP from=%s on=%s limit=%d/s", M.int2ip(h.src), iface.name, mc.bcast_rate)
            return "drop"
        end
        mc.bcast_forwarded = mc.bcast_forwarded + 1
        node:log("BCAST_FORWARD src=%s on=%s -> %s", M.int2ip(h.src), iface.name, table.concat(egress, ","))
        return "forward", egress
    end

    if not M.mcast_test(h.dst) then return nil end
    -- is this group ours? deliver locally (only joined sockets will accept it)
    if mc.groups[h.dst] then
        mc.local_deliver = mc.local_deliver + 1
        node:log("MCAST_LOCAL group=%s from=%s on=%s", M.int2ip(h.dst), M.int2ip(h.src), iface.name)
        return "local"
    end
    -- otherwise a router may forward it inside the allowed domain
    if node.role ~= "router" then
        node:log("MCAST_NOJOIN group=%s from=%s (host did not join)", M.int2ip(h.dst), M.int2ip(h.src))
        return "drop"
    end
    local egress = {}
    for pair in pairs(mc.domains) do
        local a, b = pair:match("^([^>]+)>(.+)$")
        if a == iface.name then egress[#egress + 1] = b end
    end
    if #egress == 0 then
        mc.denied = mc.denied + 1
        node:log("MCAST_DENY group=%s from=%s on=%s (no domain rule)", M.int2ip(h.dst), M.int2ip(h.src), iface.name)
        return "drop"
    end
    if not bucket_ok(mc, "mc:" .. h.dst .. ":" .. iface.name, mc.rate, now) then
        mc.rate_drops = mc.rate_drops + 1
        node:log("MCAST_RATE_DROP group=%s on=%s limit=%d/s", M.int2ip(h.dst), iface.name, mc.rate)
        return "drop"
    end
    mc.forwarded = mc.forwarded + 1
    node:log("MCAST_FORWARD group=%s from=%s on=%s -> %s", M.int2ip(h.dst), M.int2ip(h.src), iface.name, table.concat(egress, ","))
    return "forward", egress
end

return M
