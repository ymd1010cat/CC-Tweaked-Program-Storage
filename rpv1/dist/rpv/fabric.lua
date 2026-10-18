--[[- rpv/fabric.lua — cluster: several computers acting as one logical router.

Ported from the monolithic prototype into the module library. Members announce
their real interfaces over a shared fabric channel (unicast frames go to the
target member's own ID channel, so only its modem is woken), build remote routes
from those announcements, and hand packets over with FAB_FORWARD so the egress
member transmits them at that segment's MTU. TTL is decremented ONCE per
cluster, i.e. N members count as one router hop.

All offsets here are relative to the L2 body (link_parse has already stripped
the 10-byte frame header).
]]
local M = ...
local u8, u16, u32, r16, r32, byte, sub, int2ip = M.u8, M.u16, M.u32, M.r16, M.r32, M.byte, M.sub, M.int2ip

local ET_FABRIC = 0x88B5
local FAB_ANNOUNCE, FAB_FORWARD, FAB_FRAG = 1, 2, 3
M.ET_FABRIC = ET_FABRIC

function M.fabric_new(side, channel, mtu)
    return {
        side = side, channel = tonumber(channel), mtu = tonumber(mtu) or 1024,
        peers = {}, routes = {}, ucast = nil, iface = nil, announces = 0,
        seq = 0, peer_seq = {}, frags = {}, frag_bytes = 0, fragid = 0,
    }
end

function M.fabric_setup(node, f)
    f.ucast = node.id % 65500
    f.iface = {
        side = f.side, name = "FAB", channel = f.channel, mtu = f.mtu,
        is_fabric = true, ip = 0, prefix = 0, net = 0, cidr = "-",
    }
    if peripheral.getType(f.side) ~= "modem" then
        node:log("FABRIC_NO_MODEM side=%s", f.side)
        return false
    end
    peripheral.call(f.side, "open", f.channel)
    peripheral.call(f.side, "open", f.ucast)
    node.by_channel[f.channel] = f.iface
    node.by_channel[f.ucast] = f.iface
    node:log("FABRIC side=%s bcast_ch=%d ucast_ch=%d mtu=%d", f.side, f.channel, f.ucast, f.mtu)
    return true
end

function M.fabric_send_frame(node, f, dstmac, body)
    peripheral.call(f.side, "transmit", f.channel, node.mac,
        u32(dstmac) .. u32(node.mac) .. u16(ET_FABRIC) .. body)
    node.stats.fabric_frames = (node.stats.fabric_frames or 0) + 1
end

function M.fabric_announce(node, f)
    f.seq = f.seq + 1
    local body = u8(FAB_ANNOUNCE) .. u16(f.seq) .. u8(#node.ifaces)
    for _, i in ipairs(node.ifaces) do
        body = body .. u8(#i.cidr) .. i.cidr .. u8(#i.name) .. i.name
    end
    M.fabric_send_frame(node, f, M.MAC_BCAST, body)
    f.announces = f.announces + 1
    node:log("FABRIC_ANNOUNCE sent ifaces=%d seq=%d", #node.ifaces, f.seq)
end

-- FAB_FORWARD body: cmd(1) idx(1) ttl(1) proto(1) src(4) dst(4) payload
-- FAB_FRAG   body: ... + fragid(2) off8(2) mf(1) chunk
local FRAG_HEADER = 17

function M.fabric_forward(node, f, member, idx, src, dst, proto, ttl, payload)
    local maxpay = f.mtu - 10 - 12
    if #payload <= maxpay then
        local body = u8(FAB_FORWARD) .. u8(idx) .. u8(ttl) .. u8(proto) .. u32(src) .. u32(dst) .. payload
        M.fabric_send_frame(node, f, member, body)
        node.stats.fabric_fwd = (node.stats.fabric_fwd or 0) + 1
        node:log("FABRIC_FWD member=%d idx=%d ttl=%d proto=%d bytes=%d", member, idx, ttl, proto, #payload)
        return true
    end
    -- payload does not fit a single fabric frame: fragment it
    f.fragid = f.fragid % 65535 + 1
    local chunkmax = f.mtu - 10 - FRAG_HEADER
    chunkmax = chunkmax - (chunkmax % 8)
    if chunkmax <= 0 then
        node:log("FABRIC_MTU_TOO_SMALL mtu=%d", f.mtu)
        return false
    end
    local parts = 0
    for off = 0, #payload - 1, chunkmax do
        local chunk = sub(payload, off + 1, math.min(off + chunkmax, #payload))
        local mf = (off + #chunk) < #payload
        local body = u8(FAB_FRAG) .. u8(idx) .. u8(ttl) .. u8(proto) .. u32(src) .. u32(dst)
            .. u16(f.fragid) .. u16(off / 8) .. u8(mf and 1 or 0) .. chunk
        M.fabric_send_frame(node, f, member, body)
        parts = parts + 1
    end
    node.stats.fabric_frag_tx = (node.stats.fabric_frag_tx or 0) + parts
    node:log("FABRIC_FRAG_TX member=%d id=%d bytes=%d parts=%d mtu=%d", member, f.fragid, #payload, parts, f.mtu)
    return true
end

function M.fabric_announce_loop(node, f)
    M.fabric_announce(node, f)
    node:after(tonumber(node.cfg.fabric_interval) or 2, function() M.fabric_announce_loop(node, f) end)
end

function M.fabric_input(node, f, body, srcmac)
    local cmd = byte(body, 1)
    if cmd == FAB_ANNOUNCE then
        local seq, n, pos, list = r16(body, 2), byte(body, 4), 5, {}
        local last = f.peer_seq[srcmac]
        if last and seq <= last then
            node.stats.fabric_announce_stale = (node.stats.fabric_announce_stale or 0) + 1
            node:log("FABRIC_ANNOUNCE_STALE member=%d seq=%d <= %d (ignored)", srcmac, seq, last)
            return
        end
        f.peer_seq[srcmac] = seq
        for i = 1, n do
            local cl = byte(body, pos)
            local cidr = sub(body, pos + 1, pos + cl)
            pos = pos + 1 + cl
            local nl = byte(body, pos)
            local name = sub(body, pos + 1, pos + nl)
            pos = pos + 1 + nl
            list[i] = { cidr = cidr, name = name }
        end
        f.peers[srcmac] = { ifaces = list, expires = os.clock() + 6 }
        M.fabric_rebuild_routes(node, f)
        node:log("FABRIC_ANNOUNCE member=%d seq=%d ifaces=%s", srcmac, seq, list[1] and list[1].cidr or "?")
    elseif cmd == FAB_FORWARD then
        local idx, ttl, proto = byte(body, 2), byte(body, 3), byte(body, 4)
        local src, dst = r32(body, 5), r32(body, 9)
        local data = sub(body, 13)
        local iface = node.ifaces[idx]
        if not iface then
            node:log("FABRIC_BAD_IDX idx=%d from=%d", idx, srcmac)
            return
        end
        node.stats.fabric_recv = (node.stats.fabric_recv or 0) + 1
        node:log("FABRIC_RECV fromMember=%d out=%s ttl=%d proto=%d bytes=%d", srcmac, iface.name, ttl, proto, #data)
        -- verbatim hand-off: no second TTL decrement, no re-route; the egress
        -- member ARPs for the real destination on its own segment
        node:send_local(iface, dst, src, dst, proto, ttl, data)
    elseif cmd == FAB_FRAG then
        local idx, ttl, proto = byte(body, 2), byte(body, 3), byte(body, 4)
        local src, dst = r32(body, 5), r32(body, 9)
        local fragid, off8, mf = r16(body, 13), r16(body, 15), byte(body, 17) == 1
        local chunk = sub(body, 18)
        local key = srcmac .. ":" .. fragid
        local b = f.frags[key]
        if not b then
            local count = 0
            for _ in pairs(f.frags) do count = count + 1 end
            if count >= 8 then
                node.stats.fabric_frag_drops = (node.stats.fabric_frag_drops or 0) + 1
                node:log("FABRIC_FRAG_DROP table full (key=%s)", key)
                return
            end
            b = { parts = {}, expires = os.clock() + 5, idx = idx, ttl = ttl, proto = proto, src = src, dst = dst }
            f.frags[key] = b
        end
        b.parts[#b.parts + 1] = { off = off8 * 8, data = chunk }
        f.frag_bytes = f.frag_bytes + #chunk
        if not mf then b.total = off8 * 8 + #chunk end
        if not b.total then return end
        table.sort(b.parts, function(x, y) return x.off < y.off end)
        local pos, out = 0, {}
        for _, p in ipairs(b.parts) do
            if p.off ~= pos then return end
            out[#out + 1] = p.data
            pos = pos + #p.data
        end
        if pos ~= b.total then return end
        f.frags[key] = nil
        f.frag_bytes = f.frag_bytes - pos
        node.stats.fabric_frag_rx = (node.stats.fabric_frag_rx or 0) + 1
        node:log("FABRIC_FRAG_RX fromMember=%d id=%d bytes=%d parts=%d", srcmac, fragid, pos, #b.parts)
        local iface = node.ifaces[b.idx]
        if not iface then
            node:log("FABRIC_BAD_IDX idx=%d from=%d", b.idx, srcmac)
            return
        end
        node:send_local(iface, b.dst, b.src, b.dst, b.proto, b.ttl, M.concat(out))
    else
        node:log("FABRIC_UNKNOWN_CMD %d", cmd)
    end
end

function M.fabric_rebuild_routes(node, f)
    local out = {}
    for member, p in pairs(f.peers) do
        if p.expires > os.clock() then
            for i, meta in ipairs(p.ifaces) do
                local ipstr, prefix = meta.cidr:match("^([%d%.]+)/(%d+)$")
                if ipstr then
                    out[#out + 1] = {
                        prefix = tonumber(prefix), net = M.masked(M.ip2int(ipstr), tonumber(prefix)),
                        remote = member, idx = i, meta = meta,
                    }
                end
            end
        end
    end
    f.routes = out
end

function M.fabric_tick(node, f)
    local expired = false
    for member, p in pairs(f.peers) do
        if p.expires < os.clock() then
            f.peers[member] = nil
            expired = true
            node:log("FABRIC_PEER_EXPIRED member=%d", member)
        end
    end
    if expired then M.fabric_rebuild_routes(node, f) end
    local now = os.clock()
    for key, b in pairs(f.frags) do
        if b.expires < now then
            for _, p in ipairs(b.parts) do f.frag_bytes = f.frag_bytes - #p.data end
            f.frags[key] = nil
            node.stats.fabric_frag_drops = (node.stats.fabric_frag_drops or 0) + 1
            node:log("FABRIC_FRAG_TIMEOUT key=%s", key)
        end
    end
end

return M
