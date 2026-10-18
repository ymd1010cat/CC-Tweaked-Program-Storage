--[[- tests/t_ip.lua ? IPv4 header build/parse and checksum validity.]]
local T, M = ...

local src, dst = M.ip2int("10.0.1.2"), M.ip2int("10.0.2.2")
local pkt = M.ip_build(src, dst, M.IP_UDP, 63, 1234, false, 0, "payload-bytes")
local h = M.ip_parse(pkt)
T.ok(h ~= nil, "ip_parse returns a header")
T.eq(h.src, src, "parsed src")
T.eq(h.dst, dst, "parsed dst")
T.eq(h.proto, M.IP_UDP, "parsed proto")
T.eq(h.ttl, 63, "parsed ttl")
T.eq(h.id, 1234, "parsed id")
T.eq(h.mf, false, "parsed mf=false")
T.eq(h.offset8, 0, "parsed offset=0")
T.eq(M.sub(pkt, h.ihl + 1, h.total), "payload-bytes", "payload extracted")

-- a valid IPv4 header re-checksummed must come out as zero
local full = M.sub(pkt, 1, h.ihl)
T.eq(M.cksum(full), 0, "header checksum verifies to 0")
-- authoritative form (same as ip_input): the field must equal the recomputed value
local zeroed = M.sub(pkt, 1, 10) .. M.u16(0) .. M.sub(pkt, 13, h.ihl)
T.eq(M.r16(pkt, 11), M.cksum(zeroed), "header checksum field matches the recomputation")

-- fragmentation flags survive the round trip
local frag = M.ip_build(src, dst, M.IP_ICMP, 64, 7, true, 3, "chunk", true)
local fh = M.ip_parse(frag)
T.eq(fh.mf, true, "frag: mf set")
T.eq(fh.offset8, 3, "frag: offset preserved")
T.eq(fh.df, true, "frag: df preserved")
T.ok(M.ip_parse("short") == nil, "ip_parse rejects a runt")

T.eq(M.IP_BCAST, M.ip2int("255.255.255.255"), "limited broadcast constant")
