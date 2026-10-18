--[[- tests/t_qos.lua — priority classification (this is what makes ACKs jump the queue).]]
local T, M = ...

local src, dst = M.ip2int("10.0.1.2"), M.ip2int("10.0.1.3")
local function ip(proto, payload, extraHeader)
    return M.ip_build(src, dst, proto, 64, 1, false, 0, payload or "") .. (extraHeader or "")
end
local function udp(dport, data)
    return M.u16(4000) .. M.u16(dport) .. M.u16(8 + #data) .. M.u16(0) .. data
end

-- ARP and friends (non-IP frames) are control traffic
T.eq(M.qos_classify("whatever", M.ET_ARP or 0x0806), 0, "non-IP frame is control")
T.eq(M.qos_classify("short", M.ET_IP), 0, "truncated IP body is treated as control")

-- ICMP is control
T.eq(M.qos_classify(ip(M.IP_ICMP, M.u8(8) .. M.u8(0) .. M.u16(0) .. M.u16(1) .. M.u16(2)), M.ET_IP), 0,
    "ICMP is priority 0")

-- a conn pure ACK (DATA type 3, zero length) must be priority 0
local pureAck = M.u8(3) .. M.u32(100) .. M.u32(200) .. M.u16(4096) .. M.u16(0)
T.eq(M.qos_classify(ip(M.IP_UDP, udp(4300, pureAck)), M.ET_IP), 0, "conn pure ACK is control")

-- a conn data segment (type 3, non-zero length) counts as bulk when large
local dataSeg = M.u8(3) .. M.u32(100) .. M.u32(200) .. M.u16(4096) .. M.u16(180) .. string.rep("d", 180)
T.eq(M.qos_classify(ip(M.IP_UDP, udp(4300, dataSeg)), M.ET_IP), 2, "large conn data is bulk")

-- small UDP is interactive, big UDP is bulk
T.eq(M.qos_classify(ip(M.IP_UDP, udp(4300, string.rep("s", 40))), M.ET_IP), 1, "small UDP is interactive")
T.eq(M.qos_classify(ip(M.IP_UDP, udp(4300, string.rep("b", 600))), M.ET_IP), 2, "big UDP is bulk")

-- http://the threshold is configurable through the module table
local old = M.qos_small
M.qos_small = 700
T.eq(M.qos_classify(ip(M.IP_UDP, udp(4300, string.rep("m", 600))), M.ET_IP), 1, "conn_small threshold honoured")
M.qos_small = old
