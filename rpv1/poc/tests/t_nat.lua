--[[- tests/t_nat.lua ? DNAT rules, masquerade rewrite and checksum validity.]]
local T, M = ...

local ext = { name = "LAN-B", ip = M.ip2int("10.0.2.1"), prefix = 24, net = M.ip2int("10.0.2.0") }
local int = { name = "LAN-A", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0") }
local node = T.node({ nat = "1", nat_out = "LAN-B", nat_forward = "7000>10.0.1.2:7000, 7001>10.0.1.3:9000" },
    { ext, int })
node.nat = M.nat_new(node)
T.eq(node.nat.out, ext, "external interface selected by nat_out")
T.eq(node.nat.rules[7000].ip, M.ip2int("10.0.1.2"), "rule 7000 target parsed")
T.eq(node.nat.rules[7000].port, 7000, "rule 7000 port parsed")
T.eq(node.nat.rules[7001].port, 9000, "rule 7001 with a different internal port")
T.eq(node.nat.rules[9999], nil, "no rule for an unlisted port")

-- the node must be able to resolve external destinations (stub the router logic)
node.resolve = function(self, dst)
    if M.masked(dst, ext.prefix) == ext.net then return { iface = ext, next_hop = dst } end
    return nil
end

local function udp(sport, dport, data, src, dst)
    local len = 8 + #data
    local pseudo = M.u32(src) .. M.u32(dst) .. M.u8(0) .. M.u8(M.IP_UDP) .. M.u16(len)
    local ck = M.cksum(pseudo .. M.u16(sport) .. M.u16(dport) .. M.u16(len) .. M.u16(0) .. data)
    if ck == 0 then ck = 0xFFFF end
    return M.u16(sport) .. M.u16(dport) .. M.u16(len) .. M.u16(ck) .. data
end
-- verify exactly like udp_input does: recompute with the checksum field zeroed and
-- compare against the field (M.cksum returns the ones-complement sum, not zero)
local function cksum_ok(payload, src, dst)
    local len = M.r16(payload, 5)
    local data = M.sub(payload, 9, len)
    local pseudo = M.u32(src) .. M.u32(dst) .. M.u8(0) .. M.u8(M.IP_UDP) .. M.u16(len)
    return M.r16(payload, 7) == M.cksum(pseudo .. M.sub(payload, 1, 6) .. M.u16(0) .. data)
end

-- outbound private -> external: source rewritten, checksum still valid
local inner, peer = M.ip2int("10.0.1.2"), M.ip2int("10.0.2.2")
local payload = udp(4300, 7, "hello", inner, peer)
local h = { src = inner, dst = peer, proto = M.IP_UDP, ttl = 63 }
local action, ns, nd, np = M.nat_input_hook(node, int, h, payload)
T.eq(action, "rewrite", "outbound packet is rewritten")
T.eq(ns, ext.ip, "source became the external address")
T.eq(nd, peer, "destination unchanged")
T.ok(M.r16(np, 1) >= 40000, "source port taken from the translation pool")
T.eq(M.sub(np, 9), "hello", "payload preserved")
T.ok(cksum_ok(np, ns, nd), "rewritten UDP checksum is valid")
T.eq(node.nat.xlate, 1, "masquerade counted")

local extPort = M.r16(np, 1)
local key = node.nat.by_ext["17:" .. extPort]
T.ok(key ~= nil, "flow recorded in the external port map")

-- the peer's reply must come back to the internal host, same port
local reply = udp(7, extPort, "world", peer, ext.ip)
local a2, s2, d2, p2 = M.nat_input_hook(node, ext, { src = peer, dst = ext.ip, proto = M.IP_UDP, ttl = 63 }, reply)
T.eq(a2, "forward", "reply is forwarded inward")
T.eq(s2, peer, "reply source is the external peer")
T.eq(d2, inner, "reply destination is the internal host")
T.eq(M.r16(p2, 3), 4300, "reply destination port restored to the internal port")
T.ok(cksum_ok(p2, s2, d2), "reply checksum is valid")

-- a static port forward: inbound to the external address is redirected
local knock = udp(7100, 7000, "knock", peer, ext.ip)
local a3, s3, d3, p3 = M.nat_input_hook(node, ext, { src = peer, dst = ext.ip, proto = M.IP_UDP, ttl = 63 }, knock)
T.eq(a3, "forward", "port forward reaches the internal host")
T.eq(d3, M.ip2int("10.0.1.2"), "forwarded to the rule target")
T.eq(M.r16(p3, 3), 7000, "rule's internal port applied")

-- unknown inbound port: dropped, and counted
local stray = udp(7101, 7002, "x", peer, ext.ip)
T.eq(M.nat_input_hook(node, ext, { src = peer, dst = ext.ip, proto = M.IP_UDP, ttl = 63 }, stray), "drop",
    "unknown inbound port is dropped")
T.eq(node.nat.drops, 1, "drop counted")

-- ICMP echo requests are translated by id
local echo = M.u8(8) .. M.u8(0) .. M.u16(0) .. M.u16(4660) .. M.u16(1) .. "ping"
local a4, s4, d4, p4 = M.nat_input_hook(node, int, { src = inner, dst = peer, proto = M.IP_ICMP, ttl = 63 }, echo)
T.eq(a4, "rewrite", "outbound echo is rewritten")
T.eq(s4, ext.ip, "echo source became the external address")
T.ok(M.r16(p4, 5) ~= 4660, "echo id was translated")
T.eq(M.r16(p4, 3), M.cksum(M.sub(p4, 1, 2) .. M.u16(0) .. M.sub(p4, 5)), "echo checksum is valid")
