--[[- tests/t_addr.lua ? IPv4 special-use address semantics.

Pure classification/decision logic (the wiring into the data path is exercised by the
CraftOS-PC run-addr.ps1 scenario and by the existing end-to-end jobs).
]]
local T, M = ...

local function ip(s) return M.ip2int(s) end

-- ===== classification matrix ================================================
local cases = {
    { "0.0.0.1", "unspecified" }, { "0.255.255.255", "unspecified" },
    { "10.1.2.3", "private" }, { "10.255.255.254", "private" },
    { "100.64.0.1", "cgnat" }, { "100.127.255.255", "cgnat" }, { "100.128.0.1", "public" },
    { "127.0.0.1", "loopback" }, { "127.255.255.255", "loopback" },
    { "169.254.1.1", "linklocal" }, { "169.255.0.1", "public" },
    { "172.15.255.255", "public" }, { "172.16.0.1", "private" }, { "172.31.255.255", "private" },
    { "172.32.0.1", "public" },
    { "192.0.0.1", "protocol" }, { "192.0.2.5", "testnet" }, { "192.0.1.1", "public" },
    { "192.168.1.1", "private" }, { "192.168.255.254", "private" }, { "192.169.0.1", "public" },
    { "198.18.0.1", "benchmark" }, { "198.19.255.255", "benchmark" }, { "198.20.0.1", "public" },
    { "198.51.100.7", "testnet" }, { "203.0.113.9", "testnet" },
    { "224.0.0.1", "multicast" }, { "239.255.255.255", "multicast" },
    { "240.0.0.1", "reserved" }, { "255.255.255.254", "reserved" },
    { "255.255.255.255", "broadcast" },
    { "8.8.8.8", "public" }, { "1.1.1.1", "public" },
}
for _, c in ipairs(cases) do
    T.eq(M.ip_class(ip(c[1])), c[2], "class of " .. c[1])
end

-- ===== flags ================================================================
T.ok(M.ip_is_private(ip("10.0.0.1")), "10/8 is private (LAN)")
T.ok(M.ip_is_private(ip("172.16.0.1")), "172.16/12 is private (LAN)")
T.ok(M.ip_is_private(ip("192.168.5.5")), "192.168/16 is private (LAN)")
T.ok(not M.ip_is_private(ip("192.169.5.5")), "192.169/16 is NOT private")
T.ok(not M.ip_is_private(ip("8.8.8.8")), "8.8.8.8 is not private")
T.ok(M.ip_is_loopback(ip("127.0.0.1")), "127/8 is loopback")
T.ok(not M.ip_is_loopback(ip("128.0.0.1")), "128/8 is not loopback")
T.ok(M.ip_is_multicast(ip("224.0.0.1")), "224/4 is multicast")
T.ok(M.ip_is_multicast(ip("239.1.1.1")), "239/8 is multicast")
T.ok(M.ip_is_linklocal(ip("169.254.10.20")), "169.254/16 is link local")
T.ok(M.ip_is_unspecified(ip("0.0.0.0")), "0/8 is this-network")
T.ok(M.ip_is_broadcast(ip("255.255.255.255")), "255.255.255.255 is the limited broadcast")
T.ok(not M.ip_is_broadcast(ip("255.255.255.254")), "the address below is not the broadcast")

-- ===== forwardability (a router must never route these) =====================
T.ok(M.ip_forwardable(ip("10.0.0.1")), "private addresses are forwardable")
T.ok(M.ip_forwardable(ip("8.8.8.8")), "public addresses are forwardable")
T.ok(M.ip_forwardable(ip("100.64.0.1")), "CGNAT space is forwardable")
for _, a in ipairs({ "127.0.0.1", "169.254.1.1", "0.0.0.1", "240.0.0.1", "224.0.0.1",
                     "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "192.0.0.1" }) do
    T.ok(not M.ip_forwardable(ip(a)), "never forwarded: " .. a)
end

-- ===== directed broadcast ===================================================
T.eq(M.ip_directed_broadcast(ip("10.0.1.0"), 24), ip("10.0.1.255"), "/24 directed broadcast")
T.eq(M.ip_directed_broadcast(ip("192.168.0.0"), 16), ip("192.168.255.255"), "/16 directed broadcast")
T.eq(M.ip_directed_broadcast(ip("10.0.0.0"), 8), ip("10.255.255.255"), "/8 directed broadcast")
T.eq(M.ip_directed_broadcast(ip("10.0.0.0"), 31), nil, "no directed broadcast on /31")
T.eq(M.ip_directed_broadcast(ip("10.0.0.0"), 32), nil, "no directed broadcast on /32")

local iface = { ip = ip("10.0.1.2"), prefix = 24, net = ip("10.0.1.0") }
T.ok(M.ip_is_directed_broadcast(ip("10.0.1.255"), iface), "10.0.1.255 is this subnet broadcast")
T.ok(not M.ip_is_directed_broadcast(ip("10.0.2.255"), iface), "another subnet broadcast is not ours")
T.ok(not M.ip_is_directed_broadcast(ip("10.0.1.254"), iface), "an ordinary host address is not a broadcast")
T.ok(not M.ip_is_directed_broadcast(ip("10.0.1.255"), nil), "no interface means no directed broadcast")

-- ===== configuration warnings ==============================================
local function codes(f)
    local out = {}
    for _, w in ipairs(M.ip_iface_warnings(f)) do out[#out + 1] = w.code end
    return table.concat(out, ",")
end
T.eq(codes({ ip = ip("10.0.1.2"), prefix = 24, net = ip("10.0.1.0") }), "",
    "a private host address is clean")
T.eq(codes({ ip = ip("192.168.7.9"), prefix = 24, net = ip("192.168.7.0") }), "",
    "192.168/16 is accepted as a LAN address")
T.ok(codes({ ip = ip("8.8.8.8"), prefix = 24, net = ip("8.8.8.0") }):find("ADDR_NOT_PRIVATE", 1, true),
    "a public LAN address warns ADDR_NOT_PRIVATE")
T.ok(codes({ ip = ip("127.0.0.1"), prefix = 8, net = ip("127.0.0.0") }):find("ADDR_NOT_UNICAST", 1, true),
    "a loopback interface address warns ADDR_NOT_UNICAST")
T.ok(codes({ ip = ip("224.0.0.5"), prefix = 4, net = ip("224.0.0.0") }):find("ADDR_NOT_UNICAST", 1, true),
    "a multicast interface address warns ADDR_NOT_UNICAST")
T.ok(codes({ ip = ip("240.0.0.7"), prefix = 4, net = ip("240.0.0.0") }):find("ADDR_NOT_UNICAST", 1, true),
    "a reserved interface address warns ADDR_NOT_UNICAST")
T.ok(codes({ ip = ip("10.0.1.0"), prefix = 24, net = ip("10.0.1.0") }):find("ADDR_IS_NETWORK", 1, true),
    "the subnet address warns ADDR_IS_NETWORK")
T.ok(codes({ ip = ip("10.0.1.255"), prefix = 24, net = ip("10.0.1.0") }):find("ADDR_IS_BROADCAST", 1, true),
    "the directed broadcast address warns ADDR_IS_BROADCAST")
T.eq(codes({ ip = ip("169.254.1.1"), prefix = 16, net = ip("169.254.0.0") }), "",
    "a link local address is allowed without a warning")
T.eq(codes({ ip = ip("10.0.0.1"), prefix = 31, net = ip("10.0.0.0") }), "",
    "a /31 point-to-point pair is clean")
-- ===== transmittable vs forwardable ========================================
-- a host may put link local / multicast / doc-benchmark destinations on the wire; they
-- are only never FORWARDED by a router. 0/8, 240/4 and loopback are invalid everywhere.
T.ok(M.ip_transmittable(ip("169.254.1.1")), "link local is transmittable (just not forwarded)")
T.ok(M.ip_transmittable(ip("224.0.0.9")), "multicast is transmittable (just not forwarded)")
T.ok(M.ip_transmittable(ip("192.0.2.5")), "a TEST-NET address is transmittable")
T.ok(M.ip_transmittable(ip("198.18.0.1")), "a benchmark address is transmittable")
T.ok(M.ip_transmittable(ip("10.0.0.1")), "private is transmittable")
T.ok(M.ip_transmittable(ip("8.8.8.8")), "public is transmittable")
T.ok(not M.ip_transmittable(ip("0.0.0.1")), "0/8 is not transmittable")
T.ok(not M.ip_transmittable(ip("240.0.0.1")), "240/4 is not transmittable")
T.ok(not M.ip_transmittable(ip("255.255.255.255")), "the limited broadcast is not a send_ip target")
T.ok(not M.ip_transmittable(ip("127.0.0.1")), "loopback is not transmittable (it is delivered locally)")
T.ok(not M.ip_forwardable(ip("169.254.1.1")) and M.ip_transmittable(ip("169.254.1.1")),
    "link local: transmittable but not forwardable")
