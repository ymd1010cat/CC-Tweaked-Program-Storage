--[[- rpv/arp.lua — neighbour discovery with a request queue.

Unlike the first prototype (which blocked inside a nested event loop and dropped
packets while waiting), an unresolved next hop queues the packet and the node
flushes the queue when the reply arrives. Requests are rate limited and retried.
]]
local M = ...
local r16, r32, u16, u32, int2ip = M.r16, M.r32, M.u16, M.u32, M.int2ip

local RETRY_AFTER = 0.5
local MAX_TRIES = 4
local GIVE_UP = 4
local CACHE_TTL = 120

function M.arp_new()
    return { cache = {}, pending = {}, requests = 0, hits = 0, timeouts = 0, replies = 0 }
end

function M.arp_send(node, iface, op, tmac, tip)
    local body = u16(op) .. u32(node.mac) .. u32(iface.ip) .. u32(tmac) .. u32(tip)
    M.link_send(node, iface, op == 1 and M.MAC_BCAST or tmac, M.ET_ARP, body)
end

-- body layout (L2 header already stripped):
--   op(2) | senderMAC(4) | senderIP(4) | targetMAC(4) | targetIP(4)  = 18 bytes
function M.arp_input(node, iface, frame)
    if #frame < 18 then return end
    local op = r16(frame, 1)
    local smac, sip = r32(frame, 3), r32(frame, 7)
    local tip = r32(frame, 15)
    node.arp.cache[sip] = { mac = smac, expires = os.clock() + CACHE_TTL }
    if op == 1 and tip == iface.ip then
        node.arp.replies = node.arp.replies + 1
        M.arp_send(node, iface, 2, smac, sip)
        node:log("ARP_REPLY to %s mac=%d", int2ip(sip), smac)
    end
    local p = node.arp.pending[sip]
    if p then
        node.arp.pending[sip] = nil
        node:log("ARP_RESOLVED who=%s mac=%d queued=%d", int2ip(sip), smac, #p.cbs)
        for _, cb in ipairs(p.cbs) do cb(smac) end
    end
    return true
end

-- cb(mac) on success, cb(nil, reason) on failure
function M.arp_resolve(node, iface, ip, cb)
    local e = node.arp.cache[ip]
    if e and e.expires > os.clock() then
        node.arp.hits = node.arp.hits + 1
        return cb(e.mac)
    end
    local p = node.arp.pending[ip]
    if not p then
        -- last is back-dated so the very first request goes out immediately,
        -- even if the computer only booted a moment ago
        p = { cbs = {}, iface = iface, first = os.clock(), last = os.clock() - RETRY_AFTER, tries = 0 }
        node.arp.pending[ip] = p
        node:log("ARP_QUEUE who=%s via=%s", int2ip(ip), iface.name)
    end
    p.cbs[#p.cbs + 1] = cb
    local now = os.clock()
    if now - p.last >= RETRY_AFTER and p.tries < MAX_TRIES then
        p.last, p.tries = now, p.tries + 1
        node.arp.requests = node.arp.requests + 1
        node:log("ARP_REQUEST who=%s via=%s try=%d", int2ip(ip), iface.name, p.tries)
        M.arp_send(node, p.iface, 1, 0, ip)
    end
end

function M.arp_tick(node)
    local now = os.clock()
    for ip, e in pairs(node.arp.cache) do
        if e.expires < now then node.arp.cache[ip] = nil end
    end
    for ip, p in pairs(node.arp.pending) do
        if now - p.first > GIVE_UP then
            node.arp.pending[ip] = nil
            node.arp.timeouts = node.arp.timeouts + 1
            node:log("ARP_TIMEOUT who=%s dropped=%d", int2ip(ip), #p.cbs)
            for _, cb in ipairs(p.cbs) do cb(nil, "timeout") end
        elseif now - p.last >= RETRY_AFTER and p.tries < MAX_TRIES then
            p.last, p.tries = now, p.tries + 1
            node.arp.requests = node.arp.requests + 1
            node:log("ARP_RETRY who=%s try=%d", int2ip(ip), p.tries)
            M.arp_send(node, p.iface, 1, 0, ip)
        end
    end
end

return M
