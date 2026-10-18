--[[- tests/t_route.lua ? longest-prefix match, kind preference, upsert, path resolution.]]
local T, M = ...

local lanA = { name = "LAN-A", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0") }
local lanB = { name = "LAN-B", ip = M.ip2int("10.0.2.1"), prefix = 24, net = M.ip2int("10.0.2.0") }
local rt = M.route_new()
M.route_connected(rt, lanA)
M.route_connected(rt, lanB)
M.route_default(rt, M.ip2int("10.0.2.254"))

local best = M.route_lookup(rt, M.ip2int("10.0.1.55"))
T.ok(best ~= nil and best.prefix == 24 and best.kind == "connected", "longest prefix wins over default")
T.eq(best.iface, lanA, "resolved to the LAN-A interface")

M.route_add(rt, 16, M.ip2int("10.0.0.0"), lanB, nil, "file")
local b2 = M.route_lookup(rt, M.ip2int("10.0.1.55"))
T.eq(b2.prefix, 24, "more specific /24 still wins over /16")

-- equal prefix: route_lookup is deliberately first-added-wins, which is why connected
-- routes (installed at boot) win and why dv.lua refuses to shadow them at install time
-- (DV_SHADOWED, checked by the topology harness)
local rt2 = M.route_new()
local learned = { name = "LAN-B", ip = M.ip2int("10.0.2.1"), prefix = 24, net = M.ip2int("10.0.2.0") }
M.route_connected(rt2, lanA)
M.route_add(rt2, 24, M.ip2int("10.0.1.0"), learned, M.ip2int("10.0.9.9"), "dv")
local b3 = M.route_lookup(rt2, M.ip2int("10.0.1.5"))
T.eq(b3.kind, "connected", "connected route (added first) keeps the tie")
T.ok((M.ROUTE_RANK.connected or 0) > (M.ROUTE_RANK.dv or 0), "rank table: connected > dv")
T.ok((M.ROUTE_RANK.dv or 0) > (M.ROUTE_RANK.default or 0), "rank table: dv > default")

-- upsert replaces instead of duplicating
local rt3 = M.route_new()
M.route_upsert(rt3, 24, M.ip2int("10.0.3.0"), lanA, M.ip2int("10.0.3.1"), "dv")
M.route_upsert(rt3, 24, M.ip2int("10.0.3.0"), lanA, M.ip2int("10.0.3.2"), "dv")
local n = 0
for _, r in ipairs(rt3.entries) do if r.kind == "dv" then n = n + 1 end end
T.eq(n, 1, "route_upsert keeps a single dv entry")
local kept = M.route_lookup(rt3, M.ip2int("10.0.3.9"))
T.eq(kept.gw, M.ip2int("10.0.3.2"), "upsert refreshed the gateway")

M.route_upsert(rt3, 24, M.ip2int("10.0.3.0"), lanA, nil, "dv", true)
local n2 = 0
for _, r in ipairs(rt3.entries) do if r.kind == "dv" then n2 = n2 + 1 end end
T.eq(n2, 0, "route_upsert can drop an entry")

-- path resolution: a gateway route needs the gateway reachable via a connected route
local rt4 = M.route_new()
M.route_connected(rt4, lanA)
M.route_add(rt4, 24, M.ip2int("10.0.7.0"), nil, M.ip2int("10.0.1.9"), "file")
local path = M.route_path(rt4, M.ip2int("10.0.7.5"))
T.ok(path ~= nil, "gateway route resolves")
T.eq(path.next_hop, M.ip2int("10.0.1.9"), "next hop is the gateway")
T.eq(path.iface, lanA, "egress interface is the one that reaches the gateway")

local rt5 = M.route_new()
M.route_add(rt5, 24, M.ip2int("10.0.8.0"), nil, M.ip2int("10.0.1.9"), "file")
T.ok(M.route_path(rt5, M.ip2int("10.0.8.5")) == nil, "unreachable gateway -> no path")

local list = M.route_list(rt)
T.ok(#list >= 3, "route_list reports every entry")
T.eq(list[1].dest, "10.0.1.0/24", "route_list formatting")
