--[[- tests/t_dv_multipath.lua ? equal-cost alternatives in the distance-vector table.

A grid gives several next hops with the same metric; the DV table still installs a
single route, so this file pins down the three things the extras are for: keeping
the alternative (dv_alt_candidate / dv_add_alt), using it so a packet is not sent
back out of the interface it arrived on (dv_forward_alt), and promoting it when the
primary stops announcing (dv_expire_route).

Everything is driven directly: dv_new only reads node.cfg and node:log, so no
socket, no coroutine and no topology are needed.
]]
local T, M = ...
local int2ip, ip2int = M.int2ip, M.ip2int

local function iface(name, cidr)
    local ipstr, prefix = cidr:match("^([%d%.]+)/(%d+)$")
    local i = { name = name, cidr = cidr, ip = ip2int(ipstr), prefix = tonumber(prefix), mtu = 256 }
    i.net = M.masked(i.ip, i.prefix)
    return i
end

local function new_node()
    local n = { id = 1, mac = 1, role = "router", cfg = {}, ifaces = {}, routes = M.route_new(),
                stats = {}, lines = {} }
    function n:log(fmt, ...)
        local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        self.lines[#self.lines + 1] = line
        return line
    end
    function n:has(fragment)
        for _, line in ipairs(self.lines) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end
    return n
end

local lanA = iface("LAN-A", "10.0.1.1/24")
local lanB = iface("LAN-B", "10.0.2.1/24")
local gwA, gwB, gwC = ip2int("10.0.1.2"), ip2int("10.0.2.2"), ip2int("10.0.2.3")
local remote_net = ip2int("10.0.9.0")
local key = remote_net .. "/24"

local node = new_node()
node.ifaces = { lanA, lanB }
local dv = M.dv_new(node)
T.eq(dv.interval, 3, "dv_new: default interval")
T.eq(dv.timeout, 12, "dv_new: default timeout")

-- primary route learned from gwA on LAN-A with metric 2
local function install_primary()
    dv.lines_reset = nil
    dv.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = 0 }
    M.route_upsert(node.routes, 24, remote_net, lanA, gwA, "dv")
    return dv.routes[key]
end
local primary = install_primary()

-- ===== keeping an alternative ==============================================
T.eq(M.dv_add_alt(dv, key, lanB, gwB, 2), true, "the first equal-cost neighbour is kept")
T.eq(#primary.alts, 1, "one alternative recorded")
T.eq(M.dv_add_alt(dv, key, lanB, gwB, 2), false, "the same neighbour is not recorded twice")
T.eq(#primary.alts, 1, "still one alternative")
T.eq(M.dv_add_alt(dv, key, lanB, gwC, 2), true, "a second distinct neighbour is kept")
T.eq(#primary.alts, 2, "two alternatives recorded")
for extra = 1, 5 do
    M.dv_add_alt(dv, key, lanB, ip2int("10.0.2." .. (20 + extra)), 2)
end
T.eq(#primary.alts, 4, "the alternative list is capped at four")
T.eq(M.dv_add_alt(dv, "missing/24", lanB, gwB, 2), false, "an unknown destination is ignored")

-- dv_alt_candidate decides from a received announce entry
local n2 = new_node()
n2.ifaces = { lanA, lanB }
local dv2 = M.dv_new(n2)
dv2.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = 0 }
local entry = { net = remote_net, prefix = 24, metric = 1 }        -- candidate = 2
T.eq(M.dv_alt_candidate(n2, dv2, lanB, gwB, key, entry), true, "equal metric from another neighbour becomes an alternative")
T.ok(n2:has("DV_ALT net=10.0.9.0/24 metric=2 gw=10.0.2.2 via=LAN-B alts=1"), "DV_ALT names the alternative")
T.eq(dv2.routes[key].gw, gwA, "the installed route still points at the primary")
T.eq(M.dv_alt_candidate(n2, dv2, lanB, gwA, key, entry), false, "the primary's own announce is not an alternative")
T.eq(M.dv_alt_candidate(n2, dv2, lanB, gwB, key, { net = remote_net, prefix = 24, metric = 2 }), false, "a worse metric is not an alternative")
T.eq(M.dv_alt_candidate(n2, dv2, lanB, gwB, key, { net = remote_net, prefix = 24, metric = 30 }), false, "metric 16+ is unreachable, not an alternative")
dv2.routes[key] = { prefix = 24, net = remote_net, metric = 0, iface = lanA, via = nil, own = true, age = 0 }
T.eq(M.dv_alt_candidate(n2, dv2, lanB, gwB, key, entry), false, "our own connected subnet takes no alternatives")

-- ===== forwarding away from the ingress ====================================
local alt = M.dv_forward_alt(dv, ip2int("10.0.9.7"), 24, "LAN-A")
T.ok(alt ~= nil, "an alternative exists when the packet arrived on the primary's interface")
T.eq(alt and alt.gw, gwB, "the alternative next hop is the other neighbour")
T.eq(alt and alt.via, "LAN-B", "the alternative leaves through the other interface")
T.eq(M.dv_forward_alt(dv, ip2int("10.0.9.7"), 24, "LAN-B"), nil, "arriving on the alternative's interface leaves no alternative")
T.eq(M.dv_forward_alt(dv, ip2int("10.0.8.7"), 24, "LAN-A"), nil, "an unknown destination has no alternative")
T.eq(M.dv_forward_alt(nil, ip2int("10.0.9.7"), 24, "LAN-A"), nil, "no dv table, no alternative")
dv2.routes[key] = { prefix = 24, net = remote_net, metric = 0, iface = lanA, via = nil, own = true, age = 0,
                    alts = { { gw = gwB, iface = lanB, via = "LAN-B", metric = 1 } } }
T.eq(M.dv_forward_alt(dv2, remote_net, 24, "LAN-A"), nil, "a connected route never uses an alternative")

-- the alternative's own announce keeps it alive
local refreshed = M.dv_add_alt(dv, key, lanB, gwB, 2)
T.eq(refreshed, false, "refreshing an existing alternative reports no new entry")

-- ===== expiry: promote instead of dropping =================================
local n3 = new_node()
n3.ifaces = { lanA, lanB }
local dv3 = M.dv_new(n3)
dv3.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = 0,
                    alts = { { gw = gwB, iface = lanB, via = "LAN-B", metric = 3, age = 0 } } }
M.route_upsert(n3.routes, 24, remote_net, lanA, gwA, "dv")
T.eq(M.dv_expire_route(n3, dv3, key, dv3.routes[key]), nil, "a young route is not touched")
T.eq(dv3.routes[key].age, 3, "expiry ages the route by one interval")
T.eq(dv3.routes[key].alts[1].age, 3, "expiry ages the alternative too")

local old = dv3.routes[key]
old.age = dv3.timeout                                          -- next evaluation crosses the limit
T.eq(M.dv_expire_route(n3, dv3, key, old), "failover", "an expired primary fails over to the alternative")
T.eq(dv3.routes[key].gw, gwB, "the promoted alternative is now the primary")
T.eq(dv3.routes[key].metric, 3, "the promoted route keeps the alternative's metric")
T.eq(dv3.routes[key].age, 0, "the promoted route starts a fresh hold-down")
T.eq(#dv3.routes[key].alts, 0, "the promoted entry left the alternative list")
T.eq(dv3.failovers, 1, "the failover counter went up")
T.ok(n3:has("DV_FAILOVER net=10.0.9.0/24 metric=3 gw=10.0.2.2 via=LAN-B"), "DV_FAILOVER is logged")
local routed = M.route_lookup(n3.routes, remote_net)
T.eq(routed and routed.gw, gwB, "the real route table points at the new primary")

-- without alternatives the destination is dropped as before
local n4 = new_node()
n4.ifaces = { lanA }
local dv4 = M.dv_new(n4)
dv4.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = dv4.timeout }
M.route_upsert(n4.routes, 24, remote_net, lanA, gwA, "dv")
T.eq(M.dv_expire_route(n4, dv4, key, dv4.routes[key]), "expire", "an expired route without alternatives is removed")
T.eq(dv4.routes[key], nil, "the dv entry is gone")
T.eq(dv4.expires, 1, "the expire counter went up")
T.ok(n4:has("DV_EXPIRE net=10.0.9.0/24"), "DV_EXPIRE is logged")
T.eq(M.route_lookup(n4.routes, remote_net), nil, "the real route table no longer has the destination")
T.eq(M.dv_expire_route(n4, dv4, key, dv4.routes[key]), nil, "expiring a missing entry is a no-op")

-- alternatives that go silent die on their own
local n5 = new_node()
n5.ifaces = { lanA, lanB }
local dv5 = M.dv_new(n5)
dv5.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = 0,
                    alts = { { gw = gwB, iface = lanB, via = "LAN-B", metric = 3, age = dv5.timeout } } }
T.eq(M.dv_expire_route(n5, dv5, key, dv5.routes[key]), nil, "a stale alternative does not expire the route")
T.eq(#dv5.routes[key].alts, 0, "the stale alternative is dropped")
T.ok(n5:has("DV_ALT_EXPIRE net=10.0.9.0/24 alts=0"), "DV_ALT_EXPIRE is logged")

-- a poisoned announce removes just that alternative
local n6 = new_node()
n6.ifaces = { lanA, lanB }
local dv6 = M.dv_new(n6)
dv6.routes[key] = { prefix = 24, net = remote_net, metric = 2, iface = lanA, gw = gwA, via = "LAN-A", age = 0 }
M.dv_add_alt(dv6, key, lanB, gwB, 2)
T.eq(M.dv_drop_alt(dv6, key, gwB), true, "a poisoned alternative is dropped")
T.eq(#dv6.routes[key].alts, 0, "no alternatives left")
T.eq(M.dv_drop_alt(dv6, key, gwB), false, "dropping a missing alternative reports false")

-- ===== node wiring =========================================================
local f = fs.open("rpv/node.lua", "r")
local src = f.readAll()
f.close()
for _, hook in ipairs({ "M.dv_forward_alt(self.dv, h.dst, path.prefix or 0, iface.name)",
                        "FWD_ALT dst=%s gw=%s out=%s avoid=%s", "stats.fwd_alt" }) do
    T.ok(src:find(hook, 1, true) ~= nil, "node.lua wires " .. hook)
end
