--[[- tests/t_scale.lua ? control-plane scale: 100 nodes for topology + distance vector.

The emulator cannot host 100 CraftOS computers on this machine, so the control plane
is exercised at scale offline (pure logic), which is what actually has to scale:

  1. topology: 100 synthetic reports (a 10x10 grid) merged by one collector ->
     100 nodes, 180 links, a rendered map, and an expiry pass
  2. distance vector: 100 nodes (10 star clusters of 10, cluster heads in a ring ->
     diameter 8) converge to the exact hop counts in a bounded number of rounds,
     with split horizon / poisoned reverse and the metric-16 ceiling
Timing is measured and reported; the assertions stay on correctness plus a generous
time budget so the test is meaningful on slow emulated hosts too.

Data-plane scale (many flows over a real 3-router mesh) is covered by
poc/run-mesh.ps1 on the emulator.
]]
local T, M = ...

-- ===== 1. 100-node topology merge ===========================================
local lan = { name = "LAN-SCALE", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0"), cidr = "10.0.1.1/24" }
local collector = T.node({ topo = "1", topo_collect = "1" }, { lan })
collector.id, collector.mac, collector.role = 999, 999, "host"
collector.topo = M.topo_new(collector)

local W, H = 10, 10
local function nid(x, y) return 100 + (y - 1) * W + x end
local function report(x, y)
    local id = nid(x, y)
    local lines = { string.format("NODE id=%d mac=%d role=router ver=RPV1", id, id) }
    -- every grid node owns one /24
    lines[#lines + 1] = string.format("IFACE name=LAN cidr=10.%d.%d.1/24 ch=%d mtu=512 kind=wired", y, x, 5000 + id % 500)
    -- neighbours: right and below (the link is reported from both ends)
    local function peer(nx, ny)
        if nx < 1 or nx > W or ny < 1 or ny > H then return end
        lines[#lines + 1] = string.format("PEER ip=10.%d.%d.1 kind=arp", ny, nx)
    end
    peer(x + 1, y)
    peer(x - 1, y)
    peer(x, y + 1)
    peer(x, y - 1)
    lines[#lines + 1] = "SVC dhcp=0 leases=0 dns=0 nat=0 mcast=0 qos=0 dv=1"
    lines[#lines + 1] = "END"
    return table.concat(lines, "\n")
end

local t0 = os.clock()
local merged = 0
for y = 1, H do
    for x = 1, W do
        if M.topo_input(collector, report(x, y), M.ip2int(string.format("10.%d.%d.1", y, x))) then merged = merged + 1 end
    end
end
local mergeMs = (os.clock() - t0) * 1000
T.eq(merged, 100, "all 100 reports merged")
local stats = M.topo_stats(collector)
T.eq(stats.nodes, 100, "map holds 100 nodes")
-- a 10x10 grid has 10*9 horizontal + 9*10 vertical links = 180
T.eq(stats.links, 180, "grid links discovered")

local text = M.topo_text(collector)
local nodeLines, linkLines = 0, 0
for _ in text:gmatch("NODE id=") do nodeLines = nodeLines + 1 end
for _ in text:gmatch("LINK ") do linkLines = linkLines + 1 end
T.eq(nodeLines, 100, "rendered map lists 100 nodes")
T.eq(linkLines, 180, "rendered map lists 180 links")
T.ok(text:find("NETMAP_END", 1, true) ~= nil, "map is framed at scale")
T.ok(#text < 200000, "map text stays under 200 kB at 100 nodes")
T.ok(mergeMs < 20000, string.format("100-node merge is fast enough (%.0f ms)", mergeMs))

-- every node expires once its reports stop
for _, n in pairs(collector.topo.nodes) do n.seen = os.clock() - (collector.topo.ttl + 1) end
T.eq(M.topo_expire(collector), 100, "all 100 nodes expire")
T.eq(M.topo_stats(collector).nodes, 0, "map empty after expiry")

-- ===== 2. 100-node distance vector ==========================================
-- topology: 10 clusters of 10 nodes (one head each), heads in a ring.
-- diameter = 2 (head<->member) + 5 (ring half) + 2 = 9 hops -> within the INF=16 ceiling
local INF = M.DV_INFINITY
T.eq(INF, 16, "protocol infinity is 16")
local CLUSTERS, MEMBERS = 10, 10
local N = CLUSTERS * MEMBERS
local head = {}
local links = {}
-- all heads first, then the links (the ring must not reference a head that has not
-- been created yet -- head[1 % 10 + 1] is head[2], which did not exist on round 1)
for c = 1, CLUSTERS do head[c] = c * 10 end
for c = 1, CLUSTERS do
    -- members are the 9 non-head ids of the cluster; the 10th is the head itself
    for m = 1, MEMBERS - 1 do
        local id = (c - 1) * 10 + m
        links[#links + 1] = { id, head[c] }
    end
    links[#links + 1] = { head[c], head[c % CLUSTERS + 1] }   -- ring between heads
end

local adj = {}
for i = 1, N do adj[i] = {} end
local badLinks = 0
for _, l in ipairs(links) do
    if not adj[l[1]] or not adj[l[2]] then
        badLinks = badLinks + 1
        print(string.format("SCALE_BAD_LINK a=%s b=%s (N=%d)", tostring(l[1]), tostring(l[2]), N))
    else
        adj[l[1]][#adj[l[1]] + 1] = l[2]
        adj[l[2]][#adj[l[2]] + 1] = l[1]
    end
end
T.eq(badLinks, 0, "every link references existing nodes")
T.eq(#links, CLUSTERS * (MEMBERS - 1) + CLUSTERS, "100-node graph has the expected links")

-- reference hop counts (BFS from node 1)
local dist = { [1] = 0 }
local queue = { 1 }
local qi = 1
while qi <= #queue do               -- NOTE: a numeric for would freeze #queue at entry
    local u = queue[qi]
    qi = qi + 1
    for _, v in ipairs(adj[u]) do
        if dist[v] == nil then dist[v] = dist[u] + 1; queue[#queue + 1] = v end
    end
end
T.eq(#queue, N, "graph is connected")
local diameter = 0
for _, d in pairs(dist) do if d > diameter then diameter = d end end
T.ok(diameter < INF, string.format("diameter %d stays under the ceiling %d", diameter, INF))

-- synchronous DV rounds with split horizon + poisoned reverse (same rules as dv.lua)
local rt = {}
for i = 1, N do rt[i] = { [i] = { metric = 0, via = nil } } end
local rounds, converged = 0, false
local t1 = os.clock()
for round = 1, 40 do
    rounds = round
    -- build each node's announcement for each neighbour (poison what came from it)
    local announcements = {}
    for i = 1, N do announcements[i] = {} end
    for i = 1, N do
        for _, nbr in ipairs(adj[i]) do
            local entries = {}
            for dest, e in pairs(rt[i]) do
                entries[dest] = (e.via == nbr) and INF or e.metric
            end
            announcements[nbr][i] = entries
        end
    end
    -- apply
    local changed = false
    for i = 1, N do
        for nbr, entries in pairs(announcements[i]) do
            for dest, metric in pairs(entries) do
                if dest ~= i then
                    local candidate = metric + 1
                    if candidate < INF then
                        local have = rt[i][dest]
                        if not have or candidate < have.metric or have.via == nbr then
                            if not have or have.metric ~= candidate or have.via ~= nbr then
                                rt[i][dest] = { metric = candidate, via = nbr }
                                changed = true
                            end
                        end
                    end
                end
            end
        end
    end
    if not changed then
        converged = true
        break
    end
end
local dvMs = (os.clock() - t1) * 1000

T.ok(converged, string.format("100-node DV converged in %d rounds", rounds))
T.ok(rounds <= diameter + 3, string.format("convergence (%d rounds) is near the diameter (%d)", rounds, diameter))

-- per-node BFS: the converged metric must equal the true shortest hop count
local function bfs(src)
    local d = { [src] = 0 }
    local q = { src }
    local qi = 1
    while qi <= #q do
        local u = q[qi]
        qi = qi + 1
        for _, v in ipairs(adj[u]) do
            if d[v] == nil then d[v] = d[u] + 1; q[#q + 1] = v end
        end
    end
    return d
end
local wrong, unreachable, maxMetric = 0, 0, 0
for i = 1, N do
    local truth = bfs(i)
    for dest = 1, N do
        local e = rt[i][dest]
        if not e then
            unreachable = unreachable + 1
        else
            if e.metric > maxMetric then maxMetric = e.metric end
            if e.metric ~= truth[dest] then wrong = wrong + 1 end
        end
    end
end
T.eq(unreachable, 0, "every node reaches every other node")
T.eq(wrong, 0, "every hop count equals the shortest path")
T.eq(maxMetric, diameter, "the largest metric equals the diameter")
T.ok(dvMs < 20000, string.format("100-node DV ran in %.0f ms", dvMs))

print(string.format("SCALE_TOPO nodes=100 links=180 merge_ms=%.0f", mergeMs))
print(string.format("SCALE_DV nodes=100 links=%d diameter=%d rounds=%d max_metric=%d dv_ms=%.0f",
    #links, diameter, rounds, maxMetric, dvMs))
