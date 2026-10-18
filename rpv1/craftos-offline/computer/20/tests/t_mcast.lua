--[[- tests/t_mcast.lua — group address test, membership parsing and domain decisions.]]
local T, M = ...

T.ok(M.mcast_test(M.ip2int("224.0.0.0")), "224.0.0.0 is multicast")
T.ok(M.mcast_test(M.ip2int("239.1.1.1")), "239.1.1.1 is multicast")
T.ok(M.mcast_test(M.ip2int("239.255.255.255")), "upper multicast bound")
T.ok(not M.mcast_test(M.ip2int("223.255.255.255")), "223.x is not multicast")
T.ok(not M.mcast_test(M.ip2int("240.0.0.0")), "240.x is not multicast")
T.ok(not M.mcast_test(M.ip2int("10.0.1.1")), "unicast is not multicast")

local lanA = { name = "LAN-A", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0") }
local lanB = { name = "LAN-B", ip = M.ip2int("10.0.2.1"), prefix = 24, net = M.ip2int("10.0.2.0") }
local node = T.node({
    mcast = "1", mcast_groups = "239.1.1.1, 239.9.9.9, 10.0.5.5",
    mcast_domains = "LAN-A>LAN-B", mcast_rate = 3,
    bcast_relay = "LAN-A>LAN-B", bcast_rate = 2,
}, { lanA, lanB })
node.mcast = M.mcast_new(node)

T.ok(node.mcast.groups[M.ip2int("239.1.1.1")], "group 239.1.1.1 joined")
T.ok(not node.mcast.groups[M.ip2int("10.0.5.5")], "unicast entries in mcast_groups are ignored")
T.ok(node.mcast.domains["LAN-A>LAN-B"], "domain pair parsed")
T.eq(node.mcast.domains["LAN-B>LAN-A"], nil, "reverse domain is not implied")

-- a joined group is delivered locally
local g = { src = M.ip2int("10.0.1.2"), dst = M.ip2int("239.1.1.1"), proto = M.IP_UDP, ttl = 1 }
T.eq(M.mcast_input_hook(node, lanA, g, "x"), "local", "joined group delivered locally")

-- a group nobody joined is forwarded across the allowed domain only
local g9 = { src = M.ip2int("10.0.1.2"), dst = M.ip2int("239.9.9.2"), proto = M.IP_UDP, ttl = 1 }
local action, egress = M.mcast_input_hook(node, lanA, g9, "x")
T.eq(action, "forward", "unjoined group is forwarded by a router")
T.eq(egress[1], "LAN-B", "egress follows the domain rule")

-- the reverse direction has no rule: denied
T.eq(M.mcast_input_hook(node, lanB, g9, "x"), "drop", "reverse direction denied")
T.ok(node.mcast.denied >= 1, "deny counted")

-- rate limit: 3/s -> the 4th frame in the same second is dropped
local rate = 0
for i = 1, 4 do
    local a = M.mcast_input_hook(node, lanA, g9, "x")
    if a == "drop" then rate = rate + 1 end
end
T.ok(rate >= 1, "per-group rate limit drops excess frames")
T.ok(node.mcast.rate_drops >= 1, "rate drop counted")

-- limited broadcast is only relayed when a domain rule allows it
node.mcast.buckets = {}
local bcast = { src = M.ip2int("10.0.1.2"), dst = M.IP_BCAST, proto = M.IP_UDP, ttl = 1 }
local ba, be = M.mcast_input_hook(node, lanA, bcast, "x")
T.eq(ba, "forward", "broadcast relayed on the allowed pair")
T.eq(be[1], "LAN-B", "broadcast egress follows bcast_relay")
T.eq(M.mcast_input_hook(node, lanB, bcast, "x"), nil, "no bcast_relay rule -> untouched (never forwarded)")

-- a host (not a router) never forwards group traffic
local host = T.node({ mcast = "1", mcast_groups = "239.1.1.1" }, { lanA })
host.role = "host"
host.mcast = M.mcast_new(host)
T.eq(M.mcast_input_hook(host, lanA, g9, "x"), "drop", "host does not forward unjoined groups")
