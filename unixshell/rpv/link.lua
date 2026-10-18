--[[- rpv/link.lua ? link layer: frames over modem channels.

An interface is one modem side + one channel. Frames are
  dstMAC(4) | srcMAC(4) | ethertype(2) | body
MACs are computer IDs. (The rednet WAN link and the cluster fabric plug in here
in M2 ? they only need to override link_send / the event source.)
]]
local M = ...
local u16, u32, r16, r32 = M.u16, M.u32, M.r16, M.r32

function M.link_open(iface)
    peripheral.call(iface.side, "open", iface.channel)
end

function M.link_send(node, iface, dstmac, etype, body)
    -- test hook: simulate a dead link / dead peer (nothing leaves the node).
    -- Like drop_every this exists so failure modes can be exercised deterministically.
    if node.cfg.block_egress == "1" then
        node.stats.blocked_tx = (node.stats.blocked_tx or 0) + 1
        if (node.stats.blocked_tx % 20) == 1 then
            node:log("LINK_BLOCKED dstmac=%d etype=0x%04X (block_egress=1)", dstmac, etype)
        end
        return 0
    end
    -- QoS scheduler hook (qos.lua): when enabled, frames are queued by priority and
    -- drained by a tick task instead of going straight out. The scheduler itself
    -- transmits through link_send with node.qos.bypass set, so this cannot recurse.
    if node.qos and not node.qos.bypass then
        local q = M.qos_enqueue
        if q and q(node, iface, dstmac, etype, body) then return 0 end
    end
    local frame = u32(dstmac) .. u32(node.mac) .. u16(etype) .. body
    peripheral.call(iface.side, "transmit", iface.channel, node.mac, frame)
    node.stats.frames_tx = node.stats.frames_tx + 1
    node.stats.bytes_tx = node.stats.bytes_tx + #frame
    if node.capture_on then node:cap_push("tx", iface, dstmac, etype, frame) end
    return #frame
end

function M.link_parse(frame)
    if type(frame) ~= "string" or #frame < 10 then return nil end
    return r32(frame, 1), r32(frame, 5), r16(frame, 9), M.sub(frame, 11)
end

return M
