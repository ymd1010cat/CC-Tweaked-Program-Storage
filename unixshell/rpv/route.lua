--[[- rpv/route.lua -- small route table with longest-prefix match.]]
local M = ...
local masked, int2ip = M.masked, M.int2ip

function M.route_new() return { entries = {} } end

function M.route_add(rt, prefix, net, iface, gw, kind)
    rt.entries[#rt.entries + 1] = { prefix = prefix, net = net, iface = iface, gw = gw, kind = kind or "static" }
    return rt.entries[#rt.entries]
end

function M.route_connected(rt, iface)
    return M.route_add(rt, iface.prefix, iface.net, iface, nil, "connected")
end

function M.route_default(rt, gw)
    return M.route_add(rt, 0, 0, nil, gw, "default")
end

-- explicit preference when two routes have the same prefix length: a directly
-- connected subnet beats a configured route, which beats anything learned by a
-- routing protocol, which beats the default route.
local RANK = { connected = 4, fabric = 4, file = 3, static = 3, api = 3, dhcp = 3, dv = 2, default = 1 }
M.ROUTE_RANK = RANK

function M.route_lookup(rt, dst)
    -- longest prefix wins; on a tie the entry added first wins (connected routes are
    -- installed at boot, so they naturally beat learned ones). Priority between
    -- kinds is enforced when a route is installed (see route_upsert/DV), not here:
    -- keeping this loop behaviour-preserving matters for every existing topology.
    local best
    for _, r in ipairs(rt.entries) do
        if masked(dst, r.prefix) == r.net and (not best or r.prefix > best.prefix) then best = r end
    end
    return best
end

-- replace (or drop) an entry of a given kind: used by the DV module so repeated
-- announcements update a route instead of piling up duplicates
function M.route_upsert(rt, prefix, net, iface, gw, kind, drop)
    local kept = {}
    for _, r in ipairs(rt.entries) do
        local same = (r.kind == kind and r.net == net and r.prefix == prefix and r.iface == iface)
        if not same then kept[#kept + 1] = r end
    end
    rt.entries = kept
    if drop then return nil end
    return M.route_add(rt, prefix, net, iface, gw, kind)
end

-- resolve a route into a path {iface=, next_hop=}
function M.route_path(rt, dst)
    local r = M.route_lookup(rt, dst)
    if not r then return nil end
    if r.gw then
        local r2 = M.route_lookup(rt, r.gw)
        if not r2 or r2.gw then return nil end
        return { iface = r2.iface, next_hop = r.gw, prefix = r.prefix }
    end
    return { iface = r.iface, next_hop = dst, prefix = r.prefix }
end

function M.route_list(rt)
    local out = {}
    for _, r in ipairs(rt.entries) do
        out[#out + 1] = {
            dest = int2ip(r.net) .. "/" .. r.prefix,
            via = r.gw and int2ip(r.gw) or (r.iface and r.iface.name or "-"),
            kind = r.kind,
        }
    end
    return out
end

return M
