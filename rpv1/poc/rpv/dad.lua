--[[- rpv/dad.lua ? duplicate address detection for the IPv4-like address space.

Two nodes that believe they own the same address are a silent failure mode: ARP
resolves to whichever node answered last, so half of the traffic goes to the wrong
host and nothing logs an error. This module adds a bounded subset of RFC 5227 that
is a pure function of (node, interface, time) and is therefore fully unit-testable
without a modem:

  * PROBE -- an ARP *request* whose sender protocol address is 0.0.0.0 (that is
    what the field is for) asking "who has <our address>". A probe never poisons a
    neighbour cache and never starts a fight by itself.
  * ANNOUNCE -- a gratuitous ARP reply (op=2, sender and target both our address)
    that publishes the address after the probe window. Every other owner of the
    same address on the same channel sees it as a foreign claim.
  * CONFLICT -- hearing a foreign claim for one of our addresses (op 1 or 2 with a
    sender address we own and a different sender MAC). The claim is counted and
    logged once per peer, then resolved deterministically: the lower computer id
    keeps the address. With policy="yield" the loser marks the interface as
    conflicted and stops claiming the address; policy="detect" (the default) only
    counts and logs, because a host that has gone silent is often worse than a
    host with a split ARP cache.

Why the tie-break is by computer id: both ends see the same two ids, so both end
up with the same answer and exactly one of them keeps the address. Nothing has to
be agreed out of band and no packet is needed to settle it.
]]
local M = ...
local u16, u32, r16, r32, int2ip = M.u16, M.u32, M.r16, M.r32, M.int2ip

local DEFAULT_PROBES = 3
local DEFAULT_INTERVAL = 0.5
local MAX_PEERS = 16      -- a claim storm from a whole subnet must stay bounded

-- Clock injection: tests pass node.dad_now, production uses os.clock like the rest
-- of the library. Wrapping it here keeps every scheduling decision testable.
local function now_of(node)
    local f = node and node.dad_now
    if type(f) == "function" then return f(node) end
    return os.clock()
end

function M.dad_new(opts)
    local o = opts or {}
    local probes = tonumber(o.probes) or DEFAULT_PROBES
    if probes < 1 then probes = 1 end
    if probes > 10 then probes = 10 end
    local interval = tonumber(o.interval) or DEFAULT_INTERVAL
    if interval < 0.1 then interval = 0.1 end
    return {
        enabled = o.enabled ~= false,
        policy = o.policy == "yield" and "yield" or "detect",
        probes = probes,
        interval = interval,
        queue = {},          -- pending { at, iface, kind } entries, drained by dad_tick
        peers = {},          -- sender MAC -> { ip, count, first, last, defended }
        peer_count = 0,
        probes_sent = 0,
        announced = 0,
        conflicts = 0,
        defended = 0,
        yielded = 0,
        ignored = 0,
    }
end

-- ARP body layout (L2 header already stripped):
--   op(2) | senderMAC(4) | senderIP(4) | targetMAC(4) | targetIP(4)
function M.dad_probe_body(node, iface)
    return u16(1) .. u32(node.mac) .. u32(0) .. u32(0) .. u32(iface.ip)
end

function M.dad_announce_body(node, iface)
    return u16(2) .. u32(node.mac) .. u32(iface.ip) .. u32(M.MAC_BCAST) .. u32(iface.ip)
end

function M.dad_send(node, iface, body, kind)
    local d = node.dad
    M.link_send(node, iface, M.MAC_BCAST, M.ET_ARP, body)
    if kind == "probe" then
        d.probes_sent = d.probes_sent + 1
        node:log("DAD_PROBE iface=%s addr=%s try=%d", iface.name, tostring(iface.cidr or int2ip(iface.ip)), d.probes_sent)
    else
        d.announced = d.announced + 1
        node:log("DAD_ANNOUNCE iface=%s addr=%s", iface.name, tostring(iface.cidr or int2ip(iface.ip)))
    end
end

-- queue the probe burst (+ one announce) for every local address on a real channel.
-- Loopback and WAN interfaces are skipped: there is no shared medium to collide on.
function M.dad_start(node)
    local d = node.dad
    if not d or not d.enabled then return 0 end
    local now, n = now_of(node), 0
    for _, iface in ipairs(node.ifaces or {}) do
        if iface.ip and not iface.is_wan and not iface.loopback and not iface.conflicted then
            for k = 1, d.probes do
                d.queue[#d.queue + 1] = { at = now + (k - 1) * d.interval, iface = iface, kind = "probe" }
                n = n + 1
            end
            d.queue[#d.queue + 1] = { at = now + d.probes * d.interval, iface = iface, kind = "announce" }
            n = n + 1
        end
    end
    node:log("DAD_START queued=%d probes=%d interval=%.2f policy=%s", n, d.probes, d.interval, d.policy)
    return n
end

-- drain everything that is due; returns how many frames were sent
function M.dad_tick(node)
    local d = node.dad
    if not d or not d.enabled or #d.queue == 0 then return 0 end
    local now, sent, i = now_of(node), 0, 1
    while i <= #d.queue do
        local e = d.queue[i]
        if e.at <= now then
            table.remove(d.queue, i)
            local body
            if e.kind == "probe" then body = M.dad_probe_body(node, e.iface) else body = M.dad_announce_body(node, e.iface) end
            M.dad_send(node, e.iface, body, e.kind)
            sent = sent + 1
        else
            i = i + 1
        end
    end
    return sent
end

function M.dad_owner(node, ip)
    for _, iface in ipairs(node.ifaces or {}) do
        if iface.ip == ip then return iface end
    end
    return nil
end

-- Deterministic tie-break: the lower computer id keeps the address. Both nodes
-- compute the same answer from the same two ids, so exactly one of them wins.
function M.dad_claim_wins(mine, theirs)
    return mine < theirs
end

function M.dad_yield(node, iface, ip, peer)
    if iface.conflicted then return false end
    iface.conflicted = { ip = ip, peer = peer, at = now_of(node) }
    node.dad.yielded = node.dad.yielded + 1
    node.stats.dad_yielded = (node.stats.dad_yielded or 0) + 1
    node:log("DAD_ADDRESS_YIELD addr=%s winner=%d loser=%d on=%s (address no longer claimed)",
        int2ip(ip), peer, node.mac, tostring(iface.name))
    return true
end

function M.dad_conflict(node, iface, ours, smac, sip, op)
    local d = node.dad
    local now = now_of(node)
    local p = d.peers[smac]
    if not p and d.peer_count >= MAX_PEERS then
        -- the peer table is a diagnostic aid, not an accounting system: past the cap
        -- the claim still counts as a conflict, it just stops creating new entries
        d.ignored = d.ignored + 1
        d.conflicts = d.conflicts + 1
        node.stats.dad_conflicts = (node.stats.dad_conflicts or 0) + 1
        return "ignored"
    end
    if not p then
        p = { ip = sip, count = 0, first = now, last = now, defended = false }
        d.peers[smac] = p
        d.peer_count = d.peer_count + 1
    end
    p.count = p.count + 1
    p.last = now
    d.conflicts = d.conflicts + 1
    node.stats.dad_conflicts = (node.stats.dad_conflicts or 0) + 1
    local wins = M.dad_claim_wins(node.mac, smac)
    node:log("DAD_CONFLICT addr=%s claimer=%d on=%s op=%d count=%d winner=%s",
        int2ip(sip), smac, tostring(iface and iface.name or ours.name), op, p.count,
        wins and "us" or "them")
    -- one defensive announce per peer: enough to re-assert the address without
    -- turning two duplicated hosts into an announcement ping-pong
    if not p.defended then
        p.defended = true
        d.defended = d.defended + 1
        M.dad_send(node, ours, M.dad_announce_body(node, ours), "announce")
        node:log("DAD_DEFEND addr=%s claimer=%d", int2ip(sip), smac)
    end
    if d.policy == "yield" and not wins then
        M.dad_yield(node, ours, sip, smac)
        return "yield"
    end
    return "conflict"
end

-- returns "conflict" / "yield" / "ignored" / nil when the frame claims nothing of ours
function M.dad_input(node, iface, body)
    local d = node.dad
    if not d or not d.enabled then return nil end
    if #body < 18 then return nil end
    local op = r16(body, 1)
    if op ~= 1 and op ~= 2 then return nil end
    local smac, sip = r32(body, 3), r32(body, 7)
    -- a probe (sender 0.0.0.0) claims nothing, and our own frames are not claims
    if sip == 0 or smac == node.mac then return nil end
    local ours = M.dad_owner(node, sip)
    if not ours then return nil end
    return M.dad_conflict(node, iface, ours, smac, sip, op)
end

function M.dad_status(node)
    local d = node.dad
    if not d then return { enabled = false } end
    local peers = {}
    for mac, p in pairs(d.peers) do
        peers[#peers + 1] = { mac = mac, ip = p.ip, count = p.count, defended = p.defended }
    end
    table.sort(peers, function(a, b) return a.mac < b.mac end)
    return {
        enabled = d.enabled, policy = d.policy,
        probes = d.probes_sent, announced = d.announced, conflicts = d.conflicts,
        defended = d.defended, yielded = d.yielded, ignored = d.ignored,
        queued = #d.queue, peers = peers,
    }
end

function M.dad_report(node)
    local s = M.dad_status(node)
    if not s.enabled then return "dad=off" end
    return string.format("dad=on policy=%s probes=%d announced=%d conflicts=%d defended=%d yielded=%d queued=%d peers=%d",
        s.policy, s.probes, s.announced, s.conflicts, s.defended, s.yielded, s.queued, #s.peers)
end

return M
