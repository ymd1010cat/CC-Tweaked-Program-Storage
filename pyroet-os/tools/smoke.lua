--[[- pyroet-os/tools/smoke.lua -- P1 smoke test for the vendored rpv subset.

Staged layout (created by tools/smoke-run.ps1):

    /system/rpv/*.lua  the ten vendored files (9 modules + loader.lua)
    /smoke.lua    this file
    /startup.lua  pcall(dofile, "smoke.lua")

No real hardware is used: `peripheral` is stubbed with one modem on every side and
records every transmit, `periphemu` is disabled so no modem blocks are created, and
`fs` is wrapped so the config files are always absent and the node log file is
observable. The test loads the library through its public entry point
(rpv/loader.lua), checks the exported surface, builds a minimal node, runs setup(),
pushes one UDP datagram through ARP -> link -> IPv4, exercises the loopback path,
and proves every RPV_SUBSET_* degradation (icmp, wan, fabric, and the six
config-gated opt-in subsystems) logs and drops instead of calling a nil field.

Output markers (parsed by tools/smoke-run.ps1):
    SMOKE_PASS <n>   n assertions passed, 0 failed
    SMOKE_FAIL <n>   n failures (one SMOKE_FAIL_AT line each)
    SMOKE_DONE       always the last line
]]

local pass, fail = 0, 0

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        local extra = detail and tostring(detail) or ""
        if #extra > 32 then extra = string.sub(extra, 1, 32) end
        print("SMOKE_FAIL_AT " .. name .. " " .. extra)
    end
end

local function group(name)
    print("SMOKE_GROUP " .. name)
end

-- ---- environment stubs ------------------------------------------------------
local real_peripheral, real_periphemu, real_fs = peripheral, periphemu, fs

local transmits = {}
local opens = {}
peripheral = {
    getType = function(side)
        if side == nil then return nil end
        return "modem"
    end,
    call = function(side, method, ...)
        if method == "transmit" then
            local args = { n = select("#", ...), ... }
            transmits[#transmits + 1] = { side = side, args = args }
        elseif method == "open" then
            opens[#opens + 1] = { side = side, channel = (select(1, ...)) }
        end
        return nil                         -- open / isWireless / close
    end,
}
periphemu = nil                            -- never attach real modems from a test

local opened = {}
local log_mirror = {}
fs = setmetatable({
    open = function(path, mode)
        opened[path] = (opened[path] or 0) + 1
        local f = real_fs.open(path, mode)
        -- every node opens the same "rpv-log.txt" with mode "w", so a later node
        -- truncates an earlier one's warnings: mirror the writes so the evidence for
        -- all RPV_SUBSET_* lines survives to the end of the run.
        if path == "rpv-log.txt" and f then
            local proxy = setmetatable({}, { __index = f })
            proxy.writeLine = function(line)
                log_mirror[#log_mirror + 1] = line
                return f.writeLine(line)
            end
            return proxy
        end
        return f
    end,
    exists = function(path)
        if path == "role.txt" or path == "routes.txt" or path == "hosts.txt" then return false end
        return real_fs.exists(path)
    end,
    attributes = function(path) return nil end,     -- no mtime churn during the test
}, { __index = real_fs })

-- ---- 1. load through the public entry point ---------------------------------
group("load")
local loaded, rpv = pcall(dofile, "/system/rpv/loader.lua")
check("loader_loads", loaded, rpv)
if type(rpv) ~= "table" then
    print("SMOKE_FAIL 1")
    print("SMOKE_DONE")
    return
end

local expected_modules = { "crypto", "util", "ip", "route", "arp", "link", "udp", "conn", "node" }
check("modules_is_table", type(rpv.modules) == "table")
check("modules_count_9", rpv.modules and #rpv.modules == 9, rpv.modules and #rpv.modules)
for i = 1, #expected_modules do
    check("module_" .. expected_modules[i], rpv.modules and rpv.modules[i] == expected_modules[i],
        rpv.modules and rpv.modules[i])
end
check("version_rpv1", rpv.version == "RPV1", rpv.version)
check("lib_flag", rpv.lib == true)

-- ---- 2. exported surface ----------------------------------------------------
group("api")
local needed = {
    "node_new", "new_node", "subset_missing",
    -- node/ip
    "ip_build", "ip_parse", "ip_max_payload", "ip2int", "int2ip", "masked",
    "reasm_new", "reasm_push", "reasm_expire",
    -- routing
    "route_new", "route_add", "route_connected", "route_default", "route_lookup",
    "route_path", "route_list",
    -- neighbour + link + udp
    "arp_new", "arp_send", "arp_input", "arp_resolve", "arp_tick",
    "link_open", "link_send", "link_parse",
    "udp_new", "udp_send", "udp_bind", "udp_input",
    -- conn + crypto
    "conn_new", "conn_connect", "conn_listen", "conn_parse",
    "sha256", "hmac_sha256", "chacha20_xor", "hex", "unhex", "random_bytes",
    -- codec helpers the modules capture at load time
    "u8", "u16", "u32", "r16", "r32", "cksum", "sub", "byte", "ET_ARP", "ET_IP",
    "IP_ICMP", "IP_UDP", "MAC_BCAST", "IP_BCAST",
}
for i = 1, #needed do
    check("api_" .. needed[i], rpv[needed[i]] ~= nil or needed[i] == "version")
end

-- the cut modules must be absent: if one leaks back in, the subset accounting and
-- the size gate are wrong
local cut = {
    "services_setup", "lookup", "dns_register", "hosts_load",
    "wan_new", "wan_setup", "wan_tick", "wan_input", "wan_send",
    "dv_setup", "nat_setup", "nat_input_hook", "mcast_setup", "mcast_input_hook",
    "qos_setup", "qos_enqueue", "topo_setup", "compat_setup",
    "fabric_new", "fabric_setup", "fabric_tick", "fabric_input", "fabric_forward",
    "fabric_announce_loop", "icmp_input", "icmp_error", "icmp_frag_needed",
}
for i = 1, #cut do
    check("cut_" .. cut[i], rpv[cut[i]] == nil)
end

check("sha256_kat",
    rpv.hex(rpv.sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

-- ---- 3. minimal node + setup() ----------------------------------------------
group("node")
local node = rpv.node_new({
    role = "host",
    ifaces = { { side = "back", name = "LAN", cidr = "10.0.1.2/24", channel = 4001, mtu = 256, linktype = "wired" } },
    gw = "10.0.1.1",
})
local nodes = { node }
check("node_new", type(node) == "table")
check("log_file_opened", opened["rpv-log.txt"] ~= nil)
local setup_ok, setup_err = pcall(function() node:setup() end)
check("node_setup", setup_ok, setup_err)
check("iface_count", node.ifaces and #node.ifaces == 1, node.ifaces and #node.ifaces)
check("iface_ip", node.ifaces and node.ifaces[1].ip == rpv.ip2int("10.0.1.2"))
check("iface_net", node.ifaces and node.ifaces[1].net == rpv.ip2int("10.0.1.0"))
check("iface_channel", node.ifaces and node.ifaces[1].channel == 4001)
check("loopback_iface", node.lo and node.lo.ip == rpv.ip2int("127.0.0.1"))
check("link_opened", #opens == 1 and opens[1].channel == 4001,
    opens[1] and opens[1].channel)
check("tick_scheduled", next(node.timers) ~= nil)

local r_subnet = rpv.route_lookup(node.routes, rpv.ip2int("10.0.1.99"))
check("route_subnet", r_subnet and r_subnet.kind == "connected", r_subnet and r_subnet.kind)
local r_default = rpv.route_lookup(node.routes, rpv.ip2int("8.8.8.8"))
check("route_default", r_default and r_default.gw == rpv.ip2int("10.0.1.1"), r_default and r_default.gw)
check("route_loopback", rpv.route_lookup(node.routes, rpv.ip2int("127.0.0.1")) ~= nil)
local path_default = rpv.route_path(node.routes, rpv.ip2int("8.8.8.8"))
check("path_default_gw", path_default and path_default.next_hop == rpv.ip2int("10.0.1.1"),
    path_default and path_default.next_hop)
check("path_default_iface", path_default and path_default.iface == node.ifaces[1])
check("dns_is_optional", node:lookup("example.invalid") == nil)

-- ---- 4. UDP -> ARP -> link -> IPv4 -----------------------------------------
group("datapath")
local nine = rpv.ip2int("10.0.1.9")
local tx0 = node.stats.frames_tx
local sent = rpv.udp_send(node, nine, 4100, 4100, "hello rpv subset")
check("udp_send_queued", sent == true, sent)
check("arp_request_on_wire", node.stats.frames_tx == tx0 + 1, node.stats.frames_tx - tx0)
check("arp_pending", node.arp.pending[nine] ~= nil)
local arp_body = rpv.u16(2) .. rpv.u32(9) .. rpv.u32(nine)
    .. rpv.u32(node.mac) .. rpv.u32(node.ifaces[1].ip)
local arp_frame = rpv.u32(node.mac) .. rpv.u32(9) .. rpv.u16(rpv.ET_ARP) .. arp_body
node:on_frame(node.ifaces[1], arp_frame)
check("arp_resolved", node.arp.cache[nine] ~= nil)
check("arp_pending_cleared", node.arp.pending[nine] == nil)
check("datagram_on_wire", node.stats.frames_tx == tx0 + 2, node.stats.frames_tx - tx0)

local last = transmits[#transmits]
local dmac, smac, etype, l3 = nil, nil, nil, nil
if last then dmac, smac, etype, l3 = rpv.link_parse(last.args[3]) end
check("l2_frame", dmac ~= nil)
check("l2_dst_is_peer", dmac == 9, dmac)
check("l2_src_is_self", smac == node.mac, smac)
check("l2_ethertype_ip", etype == rpv.ET_IP, etype)
local h = l3 and rpv.ip_parse(l3) or nil
check("l3_parses", h ~= nil)
check("l3_proto_udp", h and h.proto == rpv.IP_UDP, h and h.proto)
check("l3_src_self", h and h.src == node.ifaces[1].ip, h and h.src)
check("l3_dst_peer", h and h.dst == nine, h and h.dst)
check("udp_dport", h and l3 and rpv.r16(l3, h.ihl + 3) == 4100, h and l3 and rpv.r16(l3, h.ihl + 3))

-- loopback: send to our own 127.0.0.1 and receive on a bound socket
local got = nil
local sk = rpv.udp_bind(node, 9000, function(data, src, sport, s)
    got = { data = data, src = src, sport = sport, port = s.port }
end)
check("udp_bound", sk ~= nil and node.udp.ports[9000] == sk)
-- the loopback path delivers internally, so udp_send returns whatever udp_input
-- returned (nil) instead of a send status: assert the call itself does not error
local lo_ok, lo_err = pcall(function()
    return rpv.udp_send(node, rpv.ip2int("127.0.0.1"), 9000, 9000, "loop")
end)
check("loopback_send", lo_ok, lo_err)
check("loopback_delivered", got ~= nil and got.data == "loop", got and got.data)
check("loopback_src", got and got.src == rpv.ip2int("127.0.0.1"))
check("loopback_port", got and got.port == 9000)
if sk then sk:close() end
check("udp_closed", node.udp.ports[9000] == nil)

-- ---- 5. subset degradations -------------------------------------------------
group("subset")
-- inbound ICMP echo request: icmp.lua is not vendored, so this must log and drop
local icmp_pkt = rpv.ip_build(nine, node.ifaces[1].ip, rpv.IP_ICMP, 64, 7, false, 0,
    string.char(8, 0, 0, 0, 0, 1, 0, 1))
local icmp_ok, icmp_err = pcall(function() node:ip_input(node.ifaces[1], icmp_pkt) end)
check("icmp_no_crash", icmp_ok, icmp_err)
check("icmp_warned", rpv.subset_warned["RPV_SUBSET_NO_ICMP"] == true)
check("icmp_not_delivered", node.stats.icmp_replies == 0)

-- a rednet/WAN interface cannot be attached: refuse it and keep the node alive
local wan_node = rpv.node_new({
    role = "host",
    ifaces = { { side = "top", name = "WAN", cidr = "10.9.0.2/24", channel = "rednet", mtu = 256 } },
})
nodes[#nodes + 1] = wan_node
local wan_ok, wan_err = pcall(function() wan_node:setup() end)
check("wan_no_crash", wan_ok, wan_err)
check("wan_iface_refused", wan_node.ifaces and #wan_node.ifaces == 0, wan_node.ifaces and #wan_node.ifaces)
check("wan_warned", rpv.subset_warned["RPV_SUBSET_NO_WAN"] == true)
check("wan_absent", wan_node.wan == nil)

-- a fabric spec cannot be attached either
local fab_node = rpv.node_new({
    role = "host",
    fabric = { side = "right", channel = 7000 },
    ifaces = { { side = "back", name = "LAN", cidr = "10.0.2.2/24", channel = 4002, mtu = 256 } },
})
nodes[#nodes + 1] = fab_node
local fab_ok, fab_err = pcall(function() fab_node:setup() end)
check("fabric_no_crash", fab_ok, fab_err)
check("fabric_warned", rpv.subset_warned["RPV_SUBSET_NO_FABRIC"] == true)
check("fabric_absent", fab_node.fabric == nil)
check("fabric_iface_kept", fab_node.ifaces and #fab_node.ifaces == 1)

-- the opt-in subsystems (nat/mcast/qos/dv/topo/services) are not vendored either: a
-- config key that asks for one must be reported, not silently ignored
local opt_node = rpv.node_new({
    role = "host",
    ifaces = { { side = "back", name = "LAN", cidr = "10.0.3.2/24", channel = 4003, mtu = 256 } },
    nat = "1", mcast = "1", qos = "1", dv = "1", topo = "1", dhcp_pool = "10.0.3.100-10.0.3.150",
})
nodes[#nodes + 1] = opt_node
local opt_ok, opt_err = pcall(function() opt_node:setup() end)
check("optin_no_crash", opt_ok, opt_err)
local opt_tags = { "RPV_SUBSET_NO_NAT", "RPV_SUBSET_NO_MCAST", "RPV_SUBSET_NO_QOS",
    "RPV_SUBSET_NO_DV", "RPV_SUBSET_NO_TOPO", "RPV_SUBSET_NO_SERVICES" }
for i = 1, #opt_tags do
    check("optin_" .. opt_tags[i], rpv.subset_warned[opt_tags[i]] == true)
end

-- ---- 6. teardown ------------------------------------------------------------
group("teardown")
for i = 1, #nodes do
    local n = nodes[i]
    for t in pairs(n.timers or {}) do pcall(os.cancelTimer, t) end
    n.timers = {}
    if n.logfile then pcall(function() n.logfile.close() end) end
end
check("timers_canceled", next(nodes[1].timers or {}) == nil)

-- quote every ASCII warning the degradation paths actually wrote
local subset_lines = 0
for i = 1, #log_mirror do
    local start = string.find(log_mirror[i], "RPV_SUBSET_", 1, true)
    if start then
        subset_lines = subset_lines + 1
        print("SMOKE_LOG " .. string.sub(log_mirror[i], start, start + 56))
    end
end
check("subset_log_lines", subset_lines >= 9, subset_lines)
peripheral, periphemu, fs = real_peripheral, real_periphemu, real_fs

if fail == 0 then
    print("SMOKE_PASS " .. tostring(pass))
else
    print("SMOKE_FAIL " .. tostring(fail))
end
print("SMOKE_ASSERTS " .. tostring(pass + fail) .. " pass=" .. tostring(pass) .. " fail=" .. tostring(fail))
print("SMOKE_DONE")
