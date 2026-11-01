--[[- tests/t_pathview.lua ? multi-hop path view (topo_flows / topo_hops).

The view is built from two halves: the local forwarding state (ARP cache, routes,
NAT flows, fabric members, WAN peers) and the collected network map. Both are
plain tables, so the whole thing is driven here without a modem: a four-node chain
A-B-C-D gives distances 0/1/2/3 that the assertions can pin down exactly.
]]
local T, M = ...
local int2ip, ip2int = M.int2ip, M.ip2int

local function iface(name, cidr)
    local ipstr, prefix = cidr:match("^([%d%.]+)/(%d+)$")
    local i = { name = name, cidr = cidr, ip = ip2int(ipstr), prefix = tonumber(prefix), mtu = 256 }
    i.net = M.masked(i.ip, i.prefix)
    return i
end

local function build_topo()
    local topo = { nodes = {}, links = {}, by_addr = {} }
    local function add_node(id, ...)
        local n = { id = id, addrs = {}, peers = {} }
        for _, cidr in ipairs({ ... }) do
            n.addrs[cidr] = true
            topo.by_addr[ip2int(cidr:match("^([%d%.]+)"))] = id
        end
        topo.nodes[id] = n
    end
    local function link(a, b)
        local key = a < b and (a .. "|" .. b) or (b .. "|" .. a)
        topo.links[key] = { a = math.min(a, b), b = math.max(a, b), kind = "wired" }
    end
    add_node(1, "10.0.1.2/24")
    add_node(2, "10.0.1.1/24", "10.0.2.1/24")
    add_node(3, "10.0.2.2/24", "10.0.3.1/24")
    add_node(4, "10.0.3.2/24")
    link(1, 2)
    link(2, 3)
    link(3, 4)
    return topo
end

local function build_node(topo)
    local lan = iface("LAN", "10.0.1.2/24")
    local node = {
        id = 1, mac = 1, role = "router", topo = topo,
        ifaces = { lan }, routes = M.route_new(), arp = M.arp_new(), stats = {},
    }
    function node:log() end
    M.route_connected(node.routes, lan)
    M.route_add(node.routes, 24, ip2int("10.0.2.0"), nil, ip2int("10.0.1.1"), "dv")
    M.route_add(node.routes, 16, ip2int("10.0.3.0"), nil, ip2int("10.0.1.1"), "dv")
    M.route_default(node.routes, ip2int("10.0.1.1"))
    node.arp.cache[ip2int("10.0.1.1")] = { mac = 2, expires = 1e9 }
    node.nat = { flows = {
        ["17:5000"] = { proto = M.IP_UDP, int_ip = ip2int("10.0.1.9"), int_port = 7000,
                        ext_port = 5000, peer = ip2int("10.0.3.2"), peer_port = 5000 },
    } }
    node.fabric = { peers = { [3] = { expires = 1e9, ifaces = {} } }, iface = lan }
    node.wan = { peers = { [ip2int("10.200.0.9")] = 77 }, iface = lan }
    return node
end

local topo = build_topo()
local node = build_node(topo)

-- ===== map distance (BFS) ===================================================
T.eq(M.topo_hops(topo, 1, 1), 0, "distance to ourselves is 0")
T.eq(M.topo_hops(topo, 1, 2), 1, "one hop to the neighbour")
T.eq(M.topo_hops(topo, 1, 3), 2, "two hops to the next router")
T.eq(M.topo_hops(topo, 1, 4), 3, "three hops to the far end of the chain")
T.eq(M.topo_hops(topo, 4, 1), 3, "BFS is symmetric")
T.eq(M.topo_hops(topo, 1, 99), nil, "an unknown node has no distance")
T.eq(M.topo_hops(nil, 1, 2), nil, "no map, no distance")
T.eq(M.topo_hops({ nodes = { [1] = {}, [2] = {} }, links = {} }, 1, 2), nil, "disconnected map has no distance")

T.eq(M.topo_hops_to_ip(node, ip2int("10.0.1.1")), 1, "distance to the owner of 10.0.1.1")
T.eq(M.topo_hops_to_ip(node, ip2int("10.0.3.2")), 3, "distance to the owner of 10.0.3.2")
T.eq(M.topo_hops_to_ip(node, ip2int("10.0.9.9")), nil, "an address no report mentions has no distance")
T.eq(M.topo_hops_to_ip({ id = 1 }, ip2int("10.0.1.1")), nil, "a node without a map has no distance")

-- ===== flow enumeration =====================================================
local flows = M.topo_flows(node)
local by_dst = {}
for _, f in ipairs(flows) do by_dst[f.dst] = f end
T.eq(#flows, 7, "seven destinations: default, neighbour, 2 dynamic routes, NAT flow, fabric, WAN")
T.ok(by_dst["10.0.1.0/24"] == nil, "locally connected subnets are not listed as paths")

local neighbour = by_dst["10.0.1.1"]
T.ok(neighbour ~= nil, "the resolved neighbour is listed")
T.eq(neighbour and neighbour.kind, "arp", "the neighbour kind is arp")
T.eq(neighbour and neighbour.hops, 1, "a resolved neighbour is one hop away")
T.eq(neighbour and neighbour.out, "LAN", "the neighbour is reached on the LAN interface")

local dyn = by_dst["10.0.2.0/24"]
T.ok(dyn ~= nil, "the dynamic route is listed")
T.eq(dyn and dyn.kind, "dv", "the route keeps its kind")
T.eq(dyn and dyn.via, "10.0.1.1", "the next hop is the gateway")
T.eq(dyn and dyn.hops, 2, "a destination behind the neighbour is two hops away")
T.eq(dyn and dyn.out, "LAN", "the route leaves through the gateway's interface")

local def = by_dst["0.0.0.0/0"]
T.ok(def ~= nil, "the default route is listed")
T.eq(def and def.via, "10.0.1.1", "the default route names the gateway")
T.eq(def and def.hops, 2, "the default route's distance is the gateway's distance plus one")

local nat = by_dst["10.0.3.2:5000"]
T.ok(nat ~= nil, "the translated flow is listed by peer address and port")
T.eq(nat and nat.kind, "nat-flow", "the translated flow is marked nat-flow")
T.eq(nat and nat.via, "10.0.1.9:7000", "the next hop is the internal host")
T.eq(nat and nat.hops, 3, "the translated peer is three hops away")

local fab = by_dst["fabric:3"]
T.ok(fab ~= nil, "the fabric member is listed")
T.eq(fab and fab.kind, "fabric", "the member is marked fabric")
T.eq(fab and fab.hops, 2, "a cluster member counts as reached in map hops")
T.eq(fab and fab.out, "LAN", "the member leaves through the fabric interface")

local wan = by_dst["wan:10.200.0.9"]
T.ok(wan ~= nil, "the WAN peer is listed")
T.eq(wan and wan.kind, "wan", "the peer is marked wan")
T.eq(wan and wan.hops, nil, "the map does not measure rednet distance")

-- ordering is stable (sorted by destination name)
local previous = ""
local sorted = true
for _, f in ipairs(flows) do
    if f.dst < previous then sorted = false end
    previous = f.dst
end
T.ok(sorted, "the flow list is sorted by destination")

-- a node with no map and no routes still renders (everything unknown)
local bare = { id = 7, mac = 7, role = "host", ifaces = {}, routes = M.route_new(),
               arp = M.arp_new(), stats = {} }
function bare:log() end
bare.arp.cache[ip2int("10.0.1.9")] = { mac = 9, expires = 1e9 }
local bare_flows = M.topo_flows(bare)
T.eq(#bare_flows, 1, "a bare node still lists its resolved neighbour")
T.eq(bare_flows[1].hops, nil, "without a map the distance is unknown")
T.eq(bare_flows[1].out, "-", "without a route the egress is unknown")

-- ===== rendering ============================================================
local lines = M.topo_flows_text(node)
T.eq(#lines, #flows, "one line per destination")
T.ok(lines[1]:find("PATH dst=", 1, true) == 1, "each line starts with PATH dst=")
T.ok(lines[1]:find(" hops=", 1, true) ~= nil, "each line carries the hop count")
local wan_line
for _, line in ipairs(lines) do
    if line:find("dst=wan:", 1, true) then wan_line = line end
end
T.ok(wan_line ~= nil and wan_line:find("hops=?", 1, true) ~= nil, "an unmeasurable hop count renders as hops=?")

local summary = M.topo_flow_summary(node)
T.eq(summary.flows, 7, "summary: seven flows")
T.eq(summary.multi, 5, "summary: five of them are more than one hop away")
T.eq(summary.unknown, 1, "summary: one destination cannot be placed on the map")
T.eq(#summary.list, 7, "summary carries the list as well")

-- ===== app wiring ===========================================================
-- staged under node2/ by run-offline.ps1 (apps/ is linted and their usage blocks
-- would trip the global? heuristic); the paths are the same files as in the repo
for _, spec in ipairs({ { "node2/routectl.lua", "topo_flow_summary" }, { "node2/routectl.lua", "path dst=%s via=%s out=%s" },
                        { "node2/panel.lua", "topo_flow_summary" }, { "node2/panel.lua", "paths flows=%d multi=%d unknown=%d" } }) do
    local f = fs.open(spec[1], "r")
    local text = f.readAll()
    f.close()
    T.ok(text:find(spec[2], 1, true) ~= nil, spec[1] .. " uses " .. spec[2])
end
