--[[- rpv/icmp.lua — echo, time exceeded, destination unreachable.

The node owns the callbacks: node.on_echo_reply(src, seq, rtt_us, bytes) and
node.on_icmp_error(src, type, code). Apps (ping/traceroute) set them.
]]
local M = ...
local u8, u16, r16, cksum, sub, byte, int2ip = M.u8, M.u16, M.r16, M.cksum, M.sub, M.byte, M.int2ip

function M.icmp_send(node, dst, itype, code, rest, ttl)
    local body = u8(itype) .. u8(code) .. u16(0) .. rest
    body = sub(body, 1, 2) .. u16(cksum(body)) .. sub(body, 5)
    return node:send_ip(dst, M.IP_ICMP, body, ttl, nil, false)
end

-- echo request/reply share layout: type|code|cksum|id(2)|seq(2)|data
-- The send time is recorded here so callers get an rtt_us in on_echo_reply
-- without having to know about node.ping_sent (library users used to have to).
function M.icmp_echo(node, dst, seq, data, ttl, id)
    node.ping_sent[seq] = os.clock()
    return M.icmp_send(node, dst, 8, 0, u16(id or 0x1234) .. u16(seq) .. (data or ""), ttl)
end

function M.icmp_error(node, iface, h, payload, itype, code)
    local quote = M.ip_build(h.src, h.dst, h.proto, h.ttl, h.id, false, 0, sub(payload, 1, 8))
    return M.icmp_send(node, h.src, itype, code, u16(0) .. u16(0) .. quote, 64)
end

-- RFC 1191 "fragmentation needed": ICMP type 3 code 4, with the next-hop MTU in
-- the low half of the second word (bytes 7..8 of the ICMP message).
function M.icmp_frag_needed(node, iface, h, payload, mtu)
    local quote = M.ip_build(h.src, h.dst, h.proto, h.ttl, h.id, false, 0, sub(payload, 1, 8))
    return M.icmp_send(node, h.src, 3, 4, u16(0) .. u16(mtu) .. quote, 64)
end

function M.icmp_input(node, iface, h, payload)
    if #payload < 4 then return end
    local itype, code = byte(payload, 1), byte(payload, 2)
    if itype == 8 then
        if node.echo_icmp then
            node:log("ICMP_ECHO_REQ from=%s seq=%d bytes=%d", int2ip(h.src), r16(payload, 7), #payload)
            M.icmp_send(node, h.src, 0, 0, sub(payload, 5), 64)
        end
    elseif itype == 0 then
        local seq = r16(payload, 7)
        local t = node.ping_sent and node.ping_sent[seq]
        local rtt = t and (os.clock() - t) * 1e6 or nil
        node.stats.icmp_replies = node.stats.icmp_replies + 1
        node:log("ICMP_ECHO_REPLY from=%s seq=%d rtt_us=%s", int2ip(h.src),
            seq, rtt and string.format("%.0f", rtt) or "?")
        if node.on_echo_reply then node.on_echo_reply(h.src, seq, rtt, #payload) end
    elseif itype == 11 then
        node.stats.icmp_time_exceeded = node.stats.icmp_time_exceeded + 1
        local quoted = sub(payload, 9)
        local inner = #quoted >= 20 and M.ip_parse(quoted) or nil
        -- quoted IP header (20) + ICMP type/code/cksum/id (6) -> seq at byte 27
        local qseq = #quoted >= 28 and r16(quoted, 27) or nil
        node:log("ICMP_TIME_EXCEEDED from=%s quoted_dst=%s quoted_seq=%s", int2ip(h.src),
            inner and int2ip(inner.dst) or "?", tostring(qseq))
        if node.on_icmp_error then node.on_icmp_error(h.src, itype, code, inner, qseq) end
    elseif itype == 3 then
        node.stats.icmp_unreachable = node.stats.icmp_unreachable + 1
        local quoted = sub(payload, 9)
        local inner = #quoted >= 20 and M.ip_parse(quoted) or nil
        local qseq = #quoted >= 28 and r16(quoted, 27) or nil
        if code == 4 then
            -- fragmentation needed: learn the path MTU for the destination
            local mtu = #payload >= 8 and r16(payload, 7) or nil
            local dst = inner and inner.dst or h.src
            node.pmtu = node.pmtu or {}
            node.pmtu[dst] = { mtu = mtu, expires = os.clock() + 300, source = int2ip(h.src) }
            node.stats.pmtu_updates = (node.stats.pmtu_updates or 0) + 1
            node:log("PMTU_UPDATE dst=%s mtu=%s from=%s", int2ip(dst), tostring(mtu), int2ip(h.src))
        else
            node:log("ICMP_UNREACHABLE code=%d from=%s", code, int2ip(h.src))
        end
        if node.on_icmp_error then node.on_icmp_error(h.src, itype, code, inner, qseq, code == 4 and r16(payload, 7) or nil) end
    else
        node:log("ICMP_TYPE_%d from=%s", itype, int2ip(h.src))
    end
end

return M
