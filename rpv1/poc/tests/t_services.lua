--[[- tests/t_services.lua — DHCP-lite: leases keyed by client id, conflict probe,
expiry, renewal, RELEASE/DECLINE, and the client state machine.

Driven offline: the module talks through rpv.udp_send / rpv.icmp_echo and node:bind, so
the test replaces udp_send with a capture list and calls the exported handlers directly.
]]
local T, M = ...

local function stub_node(cfg, ifaces)
    local n = T.node(cfg, ifaces)
    n.sockets = {}
    function n:bind(port, h) local s = { port = port, handler = h } n.sockets[port] = s return s end
    n.tasks = {}
    function n:add_task(name, fn) n.tasks[name] = fn return fn end
    n.afters = {}
    function n:after(sec, fn) n.afters[#n.afters + 1] = fn return fn end
    function n:resolve(dst) return nil end
    return n
end

-- capture everything the DHCP code emits
local sent, probes = {}, {}
local real_udp, real_icmp = M.udp_send, M.icmp_echo
M.udp_send = function(node, dst, dport, sport, payload, ttl, src)
    sent[#sent + 1] = { dst = dst, dport = dport, sport = sport, payload = payload, src = src }
    return true
end
M.icmp_echo = function(node, dst, seq, payload, size)
    probes[#probes + 1] = { dst = dst, seq = seq }
    return true
end
local function last()
    return sent[#sent]
end
local function clear() sent, probes = {}, {} end
local function msg_of(rec) return M.dhcp_unpack(rec.payload) end

local LAN = { name = "LAN", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0"),
              cidr = "10.0.1.1/24" }
local MAC_A, MAC_B, MAC_C, MAC_D = 0xAA, 0xBB, 0xCC, 0xDD
local IP100, IP101, IP102 = M.ip2int("10.0.1.100"), M.ip2int("10.0.1.101"), M.ip2int("10.0.1.102")
local CLI = M.ip2int("10.0.1.50")

-- ===== wire format ==========================================================
local packed = M.dhcp_pack(3, 0x11223344, IP100, 24, M.ip2int("10.0.1.1"), M.ip2int("10.0.1.1"), 600, 42, 7, "node7")
local parsed = M.dhcp_unpack(packed)
T.eq(parsed.t, 3, "type survives the round trip")
T.eq(parsed.xid, 0x11223344, "xid survives the round trip")
T.eq(parsed.ip, IP100, "offered address survives")
T.eq(parsed.server, 42, "server id survives")
T.eq(parsed.client, 7, "client id (mac) survives")
T.eq(parsed.name, "node7", "hostname survives")
T.eq(M.dhcp_unpack(string.rep("\0", 30)), nil, "short packet rejected")
T.eq(M.dhcp_unpack(string.rep("\0", 31)).name, "", "name may be empty")

-- ===== server: pool, client-id keying, idempotence, exhaustion ==============
local srvNode = stub_node({ dhcp_pool = "10.0.1.100-10.0.1.102", dhcp_gw = "10.0.1.1",
                            dhcp_dns = "10.0.1.1", dhcp_lease = 60, dhcp_offer_ttl = 10,
                            dhcp_sweep = 3600 }, { LAN })
local srv = M.dhcp_server_start(srvNode, { probe_fn = function() return false end })
T.ok(srv ~= nil, "server starts from a pool spec")
T.eq(srv.lo, IP100, "pool start parsed")
T.eq(srv.hi, IP102, "pool end parsed")

local function discover(mac, name)
    clear()
    srv.handle(M.dhcp_pack(1, 111, 0, 24, 0, 0, 0, 0, mac, name or ""), CLI, 68)
    return last() and msg_of(last())
end
local function request(mac, ip)
    clear()
    srv.handle(M.dhcp_pack(3, 222, ip, 24, 0, 0, 0, 0, mac, ""), CLI, 68)
    return last() and msg_of(last())
end

local offerA = discover(MAC_A, "a")
T.eq(offerA.t, 2, "DISCOVER is answered with an OFFER")
T.eq(offerA.ip, IP100, "first client gets the first pool address")
T.eq(offerA.gw, M.ip2int("10.0.1.1"), "OFFER carries the gateway")
T.eq(offerA.client, MAC_A, "OFFER echoes the client id")
local offerA2 = discover(MAC_A, "a")
T.eq(offerA2.ip, IP100, "the same client is offered the same address (idempotent)")

local offerB = discover(MAC_B, "b")
T.eq(offerB.ip, IP101, "a second client gets a different address (keyed by mac, not by source ip)")
local offerC = discover(MAC_C, "c")
T.eq(offerC.ip, IP102, "a third client gets the last pool address")
local offerD = discover(MAC_D, "d")
T.eq(offerD.t, 5, "a fourth client gets a NAK")
T.eq(srv.naks, 1, "the NAK is counted")

-- ===== REQUEST: bind, wrong address, renewal ===============================
local ack = request(MAC_A, IP100)
T.eq(ack.t, 4, "a matching REQUEST is ACKed")
T.eq(srv.by_ip[IP100].state, "bound", "the lease is bound")
T.ok((srv.by_ip[IP100].expires or 0) > os.clock(), "the lease has a deadline")
T.eq(request(MAC_A, IP101).t, 5, "requesting somebody else's address is NAKed")
T.eq(request(MAC_D, IP100).t, 5, "an unknown client claiming a bound address is NAKed")
local before = srv.by_ip[IP100].expires
srv.by_ip[IP100].expires = before - 30
T.eq(request(MAC_A, IP100).t, 4, "renewal is ACKed")
T.eq(srv.renewals, 1, "the renewal is counted")
T.ok(srv.by_ip[IP100].expires > before - 30, "renewal pushes the deadline out")

-- ===== expiry: the sweeper recycles leases and stale offers =================
local expired = M.dhcp_expire(srvNode, srv, os.clock() + 10 + 3600)
T.ok(srv.by_ip[IP100] == nil, "an expired bound lease is recycled")
T.ok(srv.by_ip[IP101] == nil, "an expired offer is recycled too")
T.eq(srv.by_client[MAC_A], nil, "the client mapping is cleared on expiry")
T.ok(srv.expired >= 2, "expiries are counted")
local offerA3 = discover(MAC_A, "a")
T.eq(offerA3.ip, IP100, "the recycled address can be handed out again")

-- ===== RELEASE and DECLINE =================================================
T.ok(request(MAC_A, IP100).t == 4, "re-bind before releasing")
local rel = M.dhcp_unpack(M.dhcp_pack(6, 333, IP100, 24, 0, 0, 0, 0, MAC_A, ""))
clear()
srv.handle(M.dhcp_pack(6, 333, IP100, 24, 0, 0, 0, 0, MAC_A, ""), CLI, 68)
T.ok(srv.by_ip[IP100] == nil, "RELEASE frees the lease")
T.eq(srv.by_client[MAC_A], nil, "RELEASE clears the client mapping")
T.ok(srv.freed >= 1, "releases are counted")
T.ok(rel ~= nil, "RELEASE packet packs/unpacks")
local offerB2 = discover(MAC_B, "b")
srv.handle(M.dhcp_pack(7, 444, offerB2.ip, 24, 0, 0, 0, 0, MAC_B, ""), CLI, 68)
T.ok(srv.bad[offerB2.ip] == true, "DECLINE blacklists the address")
T.ok(srv.by_ip[offerB2.ip] == nil, "DECLINE frees the lease")

-- ===== conflict probe: skip an address that answers =========================
local probeNode = stub_node({ dhcp_pool = "10.0.1.100-10.0.1.102", dhcp_gw = "10.0.1.1",
                              dhcp_lease = 60, dhcp_sweep = 3600 }, { LAN })
local inuse = IP100
local srv2 = M.dhcp_server_start(probeNode, { probe_fn = function(ip) return ip == inuse end })
clear()
srv2.handle(M.dhcp_pack(1, 555, 0, 24, 0, 0, 0, 0, MAC_A, "a"), CLI, 68)
local probed = msg_of(last())
T.eq(probed.ip, IP101, "an address that answers the probe is skipped")
T.ok(srv2.bad[IP100] == true, "the in-use address is blacklisted")

-- the ICMP path: a probe is sent and a reply marks the address in use
local icmpNode = stub_node({ dhcp_pool = "10.0.1.100-10.0.1.102", dhcp_gw = "10.0.1.1",
                             dhcp_lease = 60, dhcp_sweep = 3600 }, { LAN })
local srv3 = M.dhcp_server_start(icmpNode, {})
clear()
srv3.handle(M.dhcp_pack(1, 666, 0, 24, 0, 0, 0, 0, MAC_A, "a"), CLI, 68)
T.eq(#probes, 1, "the server probes the candidate address over ICMP")
T.eq(#sent, 0, "no OFFER is sent before the probe finishes")
icmpNode.on_echo_reply(M.int2ip(IP100), probes[1].seq, 1)
icmpNode.afters[1]()
T.eq(#probes, 2, "an in-use address makes the server probe the next candidate")
T.eq(#sent, 0, "still no OFFER while the second probe is in flight")
icmpNode.afters[2]()
local after_probe = msg_of(last())
T.eq(after_probe.ip, IP101, "a probe reply makes the server pick the next address")

-- ===== client state machine ================================================
local hostIface = { name = "LAN", ip = M.ip2int("10.0.1.99"), prefix = 24,
                    net = M.ip2int("10.0.1.0"), cidr = "10.0.1.99/24" }
local hostNode = stub_node({ dhcp = "1", name = "hostA", dhcp_lease = 60, dhcp_t1 = 2 }, { hostIface })
hostNode.mac = MAC_A
clear()
local cli = M.dhcp_client_start(hostNode, hostIface)
T.ok(cli ~= nil, "client starts")
T.eq(cli.client, MAC_A, "the client puts its mac in the packet")
T.eq(cli.state, "INIT", "client starts in INIT")
T.eq(#sent, 1, "the client broadcasts a DISCOVER")
T.eq(msg_of(sent[1]).t, 1, "the first packet is a DISCOVER")

clear()
cli.handle(M.dhcp_pack(2, cli.xid, IP100, 24, M.ip2int("10.0.1.1"), M.ip2int("10.0.1.1"), 60, 21, MAC_A, "hostA"), 21, 6700)
T.eq(#sent, 1, "an OFFER triggers a REQUEST")
T.eq(msg_of(sent[1]).t, 3, "the follow-up packet is a REQUEST")
T.eq(msg_of(sent[1]).ip, IP100, "the REQUEST asks for the offered address")

clear()
cli.handle(M.dhcp_pack(4, cli.xid, IP100, 24, M.ip2int("10.0.1.1"), M.ip2int("10.0.1.1"), 60, 21, MAC_A, "hostA"), 21, 6700)
T.eq(cli.state, "BOUND", "an ACK binds the client")
T.eq(hostIface.ip, IP100, "the interface is re-addressed")
T.eq(hostIface.cidr, "10.0.1.100/24", "the cidr is updated")
T.ok(hostNode.routes and M.route_lookup(hostNode.routes, M.ip2int("10.0.1.0")) ~= nil, "a connected route exists after binding")
T.eq(cli.t1, 2, "dhcp_t1 overrides the renewal timer")
T.ok(type(hostNode.tasks["dhcp-client"]) == "function", "the client scheduled its task")

clear()
T.ok(M.dhcp_release(hostNode), "dhcp_release hands the lease back")
T.eq(cli.state, "RELEASED", "the client records the release")
T.eq(msg_of(sent[1]).t, 6, "a RELEASE packet is sent")
clear()
T.ok(M.dhcp_decline(hostNode, IP100), "dhcp_decline reports a bad address")
T.eq(msg_of(sent[1]).t, 7, "a DECLINE packet is sent")

-- ===== NAK handling: the client goes back to discovering ===================
local cli2 = (function()
    clear()
    return M.dhcp_client_start(stub_node({ dhcp = "1", name = "hostB" }, { { name = "LAN", ip = M.ip2int("10.0.1.98"), prefix = 24, net = M.ip2int("10.0.1.0"), cidr = "10.0.1.98/24" } }))
end)()
cli2.handle(M.dhcp_pack(5, cli2.xid, 0, 24, 0, 0, 0, 0, 0, "no free address"), 21, 6700)
T.eq(cli2.state, "NAK", "a NAK moves the client to NAK")

M.udp_send, M.icmp_echo = real_udp, real_icmp
