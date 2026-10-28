--[[- rpv/nat.lua ? NAT-lite: port forwarding (DNAT) and masquerade (PAT).

Why this exists here: the roadmap's "do not do" note rejects *internet* NAT (CC has no
public network). What is useful in a CC world is the other half of the job: letting a
whole private subnet share ONE external identity, and letting a single well-known port
on the router reach one internal computer. That is exactly what this module does, with
no assumptions about a real internet.

Configuration (node keys):
    nat=1                                   enable
    nat_out=<iface name>                    the "external" interface (default: last iface)
    nat_forward=7000>10.0.1.2:7000,...      DNAT rules (udp by default, `tcp:` ignored)
    nat_port_base=40000                     start of the translated port pool
    nat_max_flows=64
    nat_timeout=60                          seconds an idle flow is kept

Behaviour
  * outbound (private host -> external): the source address/port is rewritten to the
    external address plus a port from the pool, and a flow entry records how to map the
    reply back. UDP gets its checksum recomputed; ICMP echo requests are translated by
    id so replies match.
  * inbound to a forwarded port: the destination is rewritten to the internal host and
    the flow is created so its replies come back out.
  * inbound to the external address with no rule and no matching flow: logged as
    NAT_DROP (and an ICMP port-unreachable is *not* generated, matching a dark NAT).
  * flows expire (NAT_EXPIRE) and the pool is bounded (NAT_POOL_EXHAUSTED).

Logs: NAT_START, NAT_XLATE, NAT_FWD, NAT_DROP, NAT_EXPIRE, NAT_STATE.
]]
local M = ...
local u8, u16, u32, r16, r32, byte, sub, cksum, int2ip = M.u8, M.u16, M.u32, M.r16, M.r32, M.byte, M.sub, M.cksum, M.int2ip

local T_OUT = 1
local T_IN = 2

local function proto_name(p) return (p == M.IP_UDP) and "udp" or (p == M.IP_ICMP) and "icmp" or tostring(p) end

-- rebuild a UDP datagram with a checksum valid for the new src/dst
local function udp_rechecksum(payload, src, dst)
    if #payload < 8 then return payload end
    local len = r16(payload, 5)
    local data = sub(payload, 9, len)
    local pseudo = u32(src) .. u32(dst) .. u8(0) .. u8(M.IP_UDP) .. u16(len)
    local ck = cksum(pseudo .. sub(payload, 1, 6) .. u16(0) .. data)
    if ck == 0 then ck = 0xFFFF end
    return sub(payload, 1, 6) .. u16(ck) .. data
end

-- ICMP echo request/reply: type(1) code(1) cksum(2) id(2) seq(2) data
local function icmp_rechecksum(payload)
    if #payload < 4 then return payload end
    local ck = cksum(sub(payload, 1, 2) .. u16(0) .. sub(payload, 5))
    return sub(payload, 1, 2) .. u16(ck) .. sub(payload, 5)
end

local function parse_rules(spec)
    local out = {}
    for rule in tostring(spec or ""):gmatch("[^,]+") do
        local port, host, hport = rule:match("^%s*(%d+)%s*>%s*([%d%.]+):(%d+)%s*$")
        if port then out[tonumber(port)] = { ip = M.ip2int(host), port = tonumber(hport) } end
    end
    return out
end

function M.nat_new(node, opts)
    opts = opts or {}
    local out_iface = nil
    local want = node.cfg.nat_out
    for _, i in ipairs(node.ifaces) do
        if want and i.name == want then out_iface = i end
    end
    if not out_iface then
        for _, i in ipairs(node.ifaces) do if not i.is_wan and not i.is_fabric then out_iface = i end end
    end
    return {
        node = node,
        out = out_iface,
        ext_ip = out_iface and out_iface.ip or 0,
        rules = parse_rules(node.cfg.nat_forward),
        port_base = tonumber(node.cfg.nat_port_base) or 40000,
        next_port = tonumber(node.cfg.nat_port_base) or 40000,
        max_flows = tonumber(node.cfg.nat_max_flows) or 64,
        timeout = tonumber(node.cfg.nat_timeout) or 60,
        flows = {},                 -- key -> flow
        by_ext = {},                -- "proto:port" -> key
        xlate = 0, fwd_hits = 0, drops = 0, expires = 0, exhausted = 0, icmp = 0,
    }
end

function M.nat_setup(node, opts)
    if not node.cfg.nat or node.cfg.nat ~= "1" then return nil end
    local nat = M.nat_new(node, opts)
    if not nat.out then
        node:log("NAT_NO_EXTERNAL_IFACE")
        return nil
    end
    node.nat = nat
    local n = 0
    for _ in pairs(nat.rules) do n = n + 1 end
    node:log("NAT_START external=%s addr=%s rules=%d port_base=%d max_flows=%d timeout=%ds",
        nat.out.name, int2ip(nat.ext_ip), n, nat.port_base, nat.max_flows, nat.timeout)

    -- flow expiry + periodic report for the harness
    node:add_task("nat", function()
        local nextReport = os.clock()
        while true do
            os.sleep(1)
            local now = os.clock()
            for k, f in pairs(nat.flows) do
                if f.expires <= now then
                    nat.flows[k] = nil
                    nat.by_ext[f.proto .. ":" .. f.ext_port] = nil
                    nat.expires = nat.expires + 1
                end
            end
            if now >= nextReport then
                nextReport = now + 5
                node:log("NAT_STATE flows=%d xlate=%d fwd=%d drops=%d expires=%d exhausted=%d icmp=%d",
                    (function() local c = 0 for _ in pairs(nat.flows) do c = c + 1 end return c end)(),
                    nat.xlate, nat.fwd_hits, nat.drops, nat.expires, nat.exhausted, nat.icmp)
            end
        end
    end)
    return nat
end

local function alloc_port(nat)
    for _ = 1, 4096 do
        local p = nat.next_port
        nat.next_port = nat.next_port + 1
        if nat.next_port > 60000 then nat.next_port = nat.port_base end
        if not nat.by_ext["17:" .. p] and not nat.by_ext["1:" .. p] then return p end
    end
    return nil
end

-- returns: action, new_src, new_dst, new_payload
--   "forward" = send the (translated) packet onward, "drop" = discard, nil = untouched
function M.nat_input_hook(node, iface, h, payload)
    local nat = node.nat
    if not nat then return nil end
    local now = os.clock()

    -- 1. traffic arriving on the external interface towards our external address
    if iface == nat.out and h.dst == nat.ext_ip then
        if h.proto == M.IP_UDP and #payload >= 8 then
            local dport = r16(payload, 3)
            local sport = r16(payload, 1)
            -- reply for an existing flow?
            local key = nat.by_ext["17:" .. dport]
            local f = key and nat.flows[key]
            if f and f.proto == M.IP_UDP then
                f.expires = now + nat.timeout
                -- reply: keep the peer's source port, retarget the destination to the
                -- internal host and its original port
                local np = u16(sport) .. u16(f.int_port) .. sub(payload, 5)
                np = udp_rechecksum(np, h.src, f.int_ip)
                return "forward", h.src, f.int_ip, np
            end
            -- static port forward?
            local r = nat.rules[dport]
            if r then
                nat.fwd_hits = nat.fwd_hits + 1
                -- remember the mapping so the reply leaves with the SAME external port
                local fkey = "fwd:" .. dport .. ":" .. h.src .. ":" .. sport
                nat.flows[fkey] = { proto = M.IP_UDP, int_ip = r.ip, int_port = r.port, ext_port = dport,
                                    peer = h.src, peer_port = sport, expires = now + nat.timeout, key = fkey }
                nat.by_ext["17:" .. dport] = fkey
                local np = udp_rechecksum(u16(sport) .. u16(r.port) .. sub(payload, 5), h.src, r.ip)
                node:log("NAT_FWD proto=udp ext_port=%d -> %s:%d from=%s sport=%d", dport, int2ip(r.ip), r.port, int2ip(h.src), sport)
                return "forward", h.src, r.ip, np
            end
            nat.drops = nat.drops + 1
            node:log("NAT_DROP proto=udp dst=%s port=%d from=%s (no rule, no flow)", int2ip(h.dst), dport, int2ip(h.src))
            return "drop"
        elseif h.proto == M.IP_ICMP and #payload >= 8 and byte(payload, 1) == 0 then
            -- echo reply for a masqueraded request: match on the translated id
            local id = r16(payload, 5)
            local ikey = nat.by_ext["1:" .. id]
            local f = ikey and nat.flows[ikey]
            if f then
                f.expires = now + nat.timeout
                local np = sub(payload, 1, 4) .. u16(f.int_id) .. sub(payload, 7)
                np = icmp_rechecksum(np)
                nat.icmp = nat.icmp + 1
                return "forward", h.src, f.int_ip, np
            end
            nat.drops = nat.drops + 1
            node:log("NAT_DROP proto=icmp dst=%s id=%d from=%s (no flow)", int2ip(h.dst), id, int2ip(h.src))
            return "drop"
        end
        return nil
    end

    -- 2. outbound: a private host sending through us (arrives on another interface)
    if iface ~= nat.out and not iface.is_wan and not iface.is_fabric then
        local isExternalDst = false
        local p = node:resolve(h.dst)
        if p and p.iface == nat.out then isExternalDst = true end
        if not isExternalDst then return nil end

        if h.proto == M.IP_UDP and #payload >= 8 then
            local sport, dport = r16(payload, 1), r16(payload, 3)
            local key = "udp:" .. h.src .. ":" .. sport .. ":" .. h.dst .. ":" .. dport
            local f = nat.flows[key]
            if not f then
                local n = 0
                for _ in pairs(nat.flows) do n = n + 1 end
                if n >= nat.max_flows then
                    nat.exhausted = nat.exhausted + 1
                    node:log("NAT_POOL_EXHAUSTED flows=%d (dropping %s:%d)", n, int2ip(h.src), sport)
                    return "drop"
                end
                local ext_port = alloc_port(nat)
                if not ext_port then
                    nat.exhausted = nat.exhausted + 1
                    return "drop"
                end
                f = { proto = M.IP_UDP, int_ip = h.src, int_port = sport, ext_port = ext_port,
                      peer = h.dst, peer_port = dport, expires = now + nat.timeout, key = key }
                nat.flows[key] = f
                nat.by_ext["17:" .. ext_port] = key
            else
                f.expires = now + nat.timeout
            end
            nat.xlate = nat.xlate + 1
            local np = udp_rechecksum(u16(f.ext_port) .. sub(payload, 3), nat.ext_ip, h.dst)
            node:log("NAT_XLATE proto=udp %s:%d -> %s:%d dst=%s:%d flows=%d",
                int2ip(h.src), sport, int2ip(nat.ext_ip), f.ext_port, int2ip(h.dst), dport, (function() local c = 0 for _ in pairs(nat.flows) do c = c + 1 end return c end)())
            return "rewrite", nat.ext_ip, h.dst, np
        elseif h.proto == M.IP_ICMP and #payload >= 8 and byte(payload, 1) == 8 then
            local id = r16(payload, 5)
            local key = "icmp:" .. h.src .. ":" .. id
            if not nat.flows[key] then
                local ext_id = alloc_port(nat) or id
                nat.flows[key] = { proto = M.IP_ICMP, int_ip = h.src, int_id = id, ext_id = ext_id,
                                   peer = h.dst, expires = now + nat.timeout, key = key }
                nat.by_ext["1:" .. ext_id] = key     -- reverse lookup for the echo reply
            end
            local f = nat.flows[key]
            f.expires = now + nat.timeout
            nat.xlate = nat.xlate + 1
            local np = sub(payload, 1, 4) .. u16(f.ext_id) .. sub(payload, 7)
            np = icmp_rechecksum(np)
            node:log("NAT_XLATE proto=icmp %s id=%d -> %s id=%d dst=%s", int2ip(h.src), id, int2ip(nat.ext_ip), f.ext_id, int2ip(h.dst))
            return "rewrite", nat.ext_ip, h.dst, np
        end
        return nil
    end
    return nil
end

return M
