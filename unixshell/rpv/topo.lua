--[[- rpv/topo.lua ? topology discovery and network-map output.

Every node periodically reports what it knows about itself and its neighbours; a
collector merges the reports into a map and can dump it as text. Nothing new is put
on the wire for discovery: a report is built from state the node already has (ARP
cache, DV routes, fabric peers, WAN peers, DHCP/DNS leases, NAT rules, group
membership), so enabling it costs one small datagram per interval.

Report (one UDP datagram, text so it is greppable in a capture):
    NODE id=<n> mac=<n> role=<role> ver=RPV1
    IFACE name=<n> cidr=<ip/prefix> ch=<n> mtu=<n> kind=<wired|wireless|wan|fabric>
    PEER ip=<ip> kind=<arp|dv|fabric|wan> [id=<n>]
    SVC dhcp=<0|1> leases=<n> dns=<0|1> nat=<n> mcast=<n> qos=<0|1> dv=<0|1>
    END

Map (collector):
    NETMAP_BEGIN nodes=<n> links=<m> at=<seconds>
    NODE id=<n> role=<role> addrs=<a,b,c> peers=<n>
    LINK <a><-><b> via=<iface> kind=<...>
    NETMAP_END

Config keys:
    topo=1                     report periodically on this node
    topo_server=<ip>           send reports to this collector (else limited broadcast)
    topo_interval=5            report period
    topo_collect=1             this node is a collector (binds topo_port)
    topo_port=6900
    topo_dump=1                write netmap.txt + NETMAP_* lines every topo_dump_every
    topo_dump_every=10
    topo_ttl=20                a node disappears from the map after this long

API: rpv.topo_setup(node), rpv.topo_report(node), rpv.topo_input(node, text, src),
     rpv.topo_dump(node), rpv.topo_text(node), rpv.topo_map(node), rpv.topo_stats(node)
]]
local M = ...
local u8, u16, u32, r32, byte, sub = M.u8, M.u16, M.u32, M.r32, M.byte, M.sub

local PORT = 6900

local function split(s)
    local out = {}
    for line in tostring(s):gmatch("[^\r\n]+") do out[#out + 1] = line end
    return out
end

-- build our own report from existing state
function M.topo_report_text(node)
    local lines = {}
    lines[#lines + 1] = string.format("NODE id=%d mac=%d role=%s ver=%s",
        node.id or 0, node.mac or 0, tostring(node.role), tostring(M.RPV_VERSION or "RPV1"))
    for _, i in ipairs(node.ifaces or {}) do
        local kind = i.is_wan and "wan" or (i.is_fabric and "fabric") or (i.wireless and "wireless" or "wired")
        lines[#lines + 1] = string.format("IFACE name=%s cidr=%s ch=%s mtu=%s kind=%s",
            tostring(i.name), tostring(i.cidr), tostring(i.channel), tostring(i.mtu), kind)
    end
    local seen = {}
    local function peer(ip, kind, id)
        if not ip or ip == 0 or seen[ip] then return end
        seen[ip] = true
        lines[#lines + 1] = string.format("PEER ip=%s kind=%s%s", M.int2ip(ip), kind,
            id and (" id=" .. tostring(id)) or "")
    end
    if node.arp and node.arp.cache then
        for ip in pairs(node.arp.cache) do peer(ip, "arp") end
    end
    if node.dv then
        for _, r in pairs(node.dv.routes) do
            if not r.own then peer(r.gw, "dv") end
        end
    end
    if node.fabric and node.fabric.peers then
        for member in pairs(node.fabric.peers) do
            lines[#lines + 1] = string.format("PEER id=%d kind=fabric", member)
        end
    end
    if node.wan and node.wan.peers then
        for ip, id in pairs(node.wan.peers) do peer(ip, "wan", id) end
    end
    local leases = 0
    if node.dhcp and node.dhcp.by_ip then for _ in pairs(node.dhcp.by_ip) do leases = leases + 1 end end
    local groups = 0
    if node.mcast and node.mcast.groups then for _ in pairs(node.mcast.groups) do groups = groups + 1 end end
    local rules = 0
    if node.nat and node.nat.rules then for _ in pairs(node.nat.rules) do rules = rules + 1 end end
    lines[#lines + 1] = string.format("SVC dhcp=%d leases=%d dns=%d nat=%d mcast=%d qos=%d dv=%d",
        node.dhcp and 1 or 0, leases, node.dns and 1 or 0, rules, groups,
        node.qos and 1 or 0, node.dv and 1 or 0)
    lines[#lines + 1] = "END"
    return table.concat(lines, "\n")
end

function M.topo_send(node)
    local text = M.topo_report_text(node)
    local server = node.cfg.topo_server and M.ip2int(node.cfg.topo_server)
    local port = tonumber(node.cfg.topo_port) or PORT
    if server then
        M.udp_send(node, server, port, port, text)
    else
        M.udp_send(node, M.IP_BCAST, port, port, text, 1)
    end
    if node.topo then
        node.topo.reports_sent = (node.topo.reports_sent or 0) + 1
        -- low-rate evidence that this node is reporting (every 4th report)
        if node.topo.reports_sent % 4 == 1 then
            node:log("TOPO_SENT from=%s n=%d ifaces=%d bytes=%d",
                M.int2ip(node.ifaces[1] and node.ifaces[1].ip or 0), node.topo.reports_sent, #node.ifaces, #text)
        end
    end
    return true
end

function M.topo_new(node, opts)
    return {
        node = node, port = tonumber(node.cfg.topo_port) or PORT,
        interval = tonumber(node.cfg.topo_interval) or 5,
        ttl = tonumber(node.cfg.topo_ttl) or 20,
        collect = node.cfg.topo_collect == "1",
        nodes = {},            -- id -> { role, addrs = {..}, peers = {..}, seen = t }
        links = {},            -- "a|b" -> { a, b, via, kind }
        by_addr = {},          -- ip -> node id
        reports_rx = 0, reports_sent = 0, dumps = 0,
    }
end

-- merge one received report
function M.topo_input(node, text, src)
    local topo = node.topo
    if not topo or not topo.collect then return false end
    local cur = nil
    for _, line in ipairs(split(text)) do
        local head = line:match("^(%u+)")
        if head == "NODE" then
            local id = tonumber(line:match("id=(%d+)"))
            if not id then return false end
            cur = topo.nodes[id] or { id = id, addrs = {}, peers = {} }
            cur.role = line:match("role=(%S+)") or cur.role
            cur.seen = os.clock()
            topo.nodes[id] = cur
        elseif head == "IFACE" and cur then
            local cidr = line:match("cidr=(%S+)")
            local name = line:match("name=(%S+)")
            if cidr then
                cur.addrs[cidr] = true
                local ip = cidr:match("^([%d%.]+)")
                if ip then topo.by_addr[M.ip2int(ip)] = cur.id end
            end

        elseif head == "PEER" and cur then
            local ip = line:match("ip=(%S+)")
            local key = line:match("kind=(%S+)")
            if ip then
                cur.peers[ip] = key or "?"
            elseif line:match("id=(%d+)") and key == "fabric" then
                cur.peers["#" .. line:match("id=(%d+)")] = "fabric"
            end
        end
    end
    if not cur then return false end
    topo.reports_rx = topo.reports_rx + 1
    node:log("TOPO_REPORT_RX from=%s id=%s reports_rx=%d nodes=%d",
        M.int2ip(src or 0), tostring(cur.id), topo.reports_rx, (function()
            local n = 0
            for _ in pairs(topo.nodes) do n = n + 1 end
            return n
        end)())
    M.topo_rebuild(node)
    return true
end

-- turn the peer lists into links (peer ip -> the node that owns that address)
function M.topo_rebuild(node)
    local topo = node.topo
    if not topo then return 0 end
    topo.links = {}
    local function link(a, b, via, kind)
        if not a or not b or a == b then return end
        local key = a < b and (a .. "|" .. b) or (b .. "|" .. a)
        local l = topo.links[key]
        if not l then
            topo.links[key] = { a = math.min(a, b), b = math.max(a, b), via = via, kind = kind }
        elseif l.kind ~= kind then
            l.kind = l.kind .. "+" .. kind
        end
    end
    for id, n in pairs(topo.nodes) do
        if n.peers then
            for key, kind in pairs(n.peers) do
                local target = nil
                if key:sub(1, 1) == "#" then
                    target = tonumber(key:sub(2))
                else
                    local ip = M.ip2int(key)
                    target = topo.by_addr[ip]
                end
                link(id, target, n.role, kind)
            end
        end
    end
    local count = 0
    for _ in pairs(topo.links) do count = count + 1 end
    return count
end

function M.topo_expire(node)
    local topo = node.topo
    if not topo then return 0 end
    local now, dropped = os.clock(), 0
    for id, n in pairs(topo.nodes) do
        if n.seen and now - n.seen > topo.ttl then
            topo.nodes[id] = nil
            dropped = dropped + 1
        end
    end
    if dropped > 0 then M.topo_rebuild(node) end
    return dropped
end

function M.topo_map(node)
    local topo = node.topo
    if not topo then return nil end
    return topo
end

-- text rendering: short lines, one node / one link per line (grep friendly)
function M.topo_text(node)
    local topo = node.topo
    if not topo then return "NETMAP_BEGIN nodes=0 links=0\nNETMAP_END" end
    local ids = {}
    for id in pairs(topo.nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    local linkKeys = {}
    for k in pairs(topo.links) do linkKeys[#linkKeys + 1] = k end
    table.sort(linkKeys)
    local out = {}
    out[#out + 1] = string.format("NETMAP_BEGIN nodes=%d links=%d at=%.0f", #ids, #linkKeys, os.clock())
    for _, id in ipairs(ids) do
        local n = topo.nodes[id]
        local addrs = {}
        for a in pairs(n.addrs) do addrs[#addrs + 1] = a end
        table.sort(addrs)
        local peers = 0
        for _ in pairs(n.peers) do peers = peers + 1 end
        out[#out + 1] = string.format("NODE id=%d role=%s addrs=%s peers=%d", id, tostring(n.role),
            #addrs > 0 and table.concat(addrs, ",") or "-", peers)
    end
    for _, k in ipairs(linkKeys) do
        local l = topo.links[k]
        out[#out + 1] = string.format("LINK %d<->%d kind=%s", l.a, l.b, tostring(l.kind))
    end
    out[#out + 1] = "NETMAP_END"
    return table.concat(out, "\n")
end

function M.topo_dump(node, path)
    local text = M.topo_text(node)
    path = path or "netmap.txt"
    local f = fs.open(path, "w")
    if f then
        f.writeLine(text)
        f.close()
    end
    if node.topo then node.topo.dumps = node.topo.dumps + 1 end
    for _, line in ipairs(split(text)) do node:log("%s", line) end
    return text
end

function M.topo_stats(node)
    local topo = node.topo
    if not topo then return nil end
    local n, l = 0, 0
    for _ in pairs(topo.nodes) do n = n + 1 end
    for _ in pairs(topo.links) do l = l + 1 end
    return { nodes = n, links = l, reports_rx = topo.reports_rx, reports_sent = topo.reports_sent, dumps = topo.dumps }
end

function M.topo_setup(node, opts)
    if node.cfg.topo ~= "1" and node.cfg.topo_collect ~= "1" then return nil end
    local topo = M.topo_new(node, opts)
    node.topo = topo
    node:log("TOPO_START collect=%s port=%d interval=%ds ttl=%ds", tostring(topo.collect), topo.port, topo.interval, topo.ttl)
    if topo.collect then
        node:bind(topo.port, function(data, src, sport)
            M.topo_input(node, tostring(data), src)
        end)
    end
    node:add_task("topo", function()
        local nextDump = os.clock() + (tonumber(node.cfg.topo_dump_every) or 10)
        while true do
            os.sleep(topo.interval)
            if node.cfg.topo == "1" then M.topo_send(node) end
            M.topo_expire(node)
            if topo.collect and node.cfg.topo_dump == "1" and os.clock() >= nextDump then
                nextDump = os.clock() + (tonumber(node.cfg.topo_dump_every) or 10)
                M.topo_dump(node)
            end
            if topo.collect then
                local n, l = 0, 0
                for _ in pairs(topo.nodes) do n = n + 1 end
                for _ in pairs(topo.links) do l = l + 1 end
                node:log("TOPO_STATE nodes=%d links=%d reports_rx=%d reports_sent=%d dumps=%d",
                    n, l, topo.reports_rx, topo.reports_sent, topo.dumps)
            end
        end
    end)
    return topo
end

return M
