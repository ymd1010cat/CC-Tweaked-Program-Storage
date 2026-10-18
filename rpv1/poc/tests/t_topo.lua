--[[- tests/t_topo.lua — report parsing, link building and map rendering (offline).]]
local T, M = ...

local lanA = { name = "LAN-A", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0"), cidr = "10.0.1.1/24", channel = 4901, mtu = 512 }
local node = T.node({ topo = "1", topo_collect = "1", topo_port = "6900" }, { lanA })
node.id, node.mac, node.role = 23, 23, "host"
node.topo = M.topo_new(node)
T.ok(node.topo.collect, "collector mode parsed")
T.eq(node.topo.port, 6900, "port parsed")
T.eq(node.topo.interval, 5, "default interval")
T.eq(node.topo.ttl, 20, "default ttl")

-- our own report text must be parseable and framed
node.arp = { cache = { [M.ip2int("10.0.1.1")] = { mac = 21, expires = os.clock() + 30 } } }
local text = M.topo_report_text(node)
T.ok(text:find("NODE id=23", 1, true) ~= nil, "report has the NODE line")
T.ok(text:find("IFACE name=LAN-A cidr=10.0.1.1/24", 1, true) ~= nil, "report has the IFACE line")
T.ok(text:find("PEER ip=10.0.1.1 kind=arp", 1, true) ~= nil, "report lists the ARP neighbour")
T.ok(text:find("SVC dhcp=0", 1, true) ~= nil, "report has the SVC line")
T.ok(text:sub(-3) == "END", "report ends with END")

-- feed two synthetic reports: 21 (router, two LANs) and 22 (router, one LAN)
local r21 = table.concat({
    "NODE id=21 mac=21 role=router ver=RPV1",
    "IFACE name=LAN-A cidr=10.0.1.1/24 ch=4901 mtu=512 kind=wired",
    "IFACE name=LAN-B cidr=10.0.2.1/24 ch=4902 mtu=512 kind=wired",
    "PEER ip=10.0.2.2 kind=arp",
    "SVC dhcp=1 leases=2 dns=1 nat=0 mcast=0 qos=0 dv=1",
    "END",
}, "\n")
local r22 = table.concat({
    "NODE id=22 mac=22 role=router ver=RPV1",
    "IFACE name=LAN-B cidr=10.0.2.2/24 ch=4902 mtu=512 kind=wired",
    "PEER ip=10.0.1.1 kind=arp",
    "END",
}, "\n")

T.ok(M.topo_input(node, r21, M.ip2int("10.0.1.1")), "report 21 merged")
T.ok(M.topo_input(node, r22, M.ip2int("10.0.2.2")), "report 22 merged")
T.eq(node.topo.reports_rx, 2, "reports counted")

local stats = M.topo_stats(node)
T.eq(stats.nodes, 2, "two nodes in the map")
T.eq(stats.links, 1, "the two routers are linked to each other")
T.eq(node.topo.links["21|22"].kind, "arp", "link kind recorded")

-- address index lets a peer IP resolve to its owning node
T.eq(node.topo.by_addr[M.ip2int("10.0.2.2")], 22, "peer address maps to node 22")

-- rendering
local map = M.topo_text(node)
T.ok(map:find("NETMAP_BEGIN nodes=2 links=1", 1, true) ~= nil, "map header counts nodes and links")
T.ok(map:find("NODE id=21 role=router", 1, true) ~= nil, "map lists node 21")
T.ok(map:find("LINK 21<->22 kind=arp", 1, true) ~= nil, "map lists the link")
T.ok(map:find("NETMAP_END", 1, true) ~= nil, "map is framed")
T.ok(map:find("addrs=10.0.1.1/24,10.0.2.1/24", 1, true) ~= nil, "both addresses listed in order")

-- a node that stops reporting disappears after the ttl
node.topo.nodes[21].seen = os.clock() - (node.topo.ttl + 5)
T.eq(M.topo_expire(node), 1, "stale node expired")
T.eq(M.topo_stats(node).nodes, 1, "expiry removed it from the map")
