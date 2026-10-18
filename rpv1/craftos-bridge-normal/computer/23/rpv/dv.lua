--[[- rpv/dv.lua ? distance-vector routing (RIP-lite) with loop suppression.

Lets a set of routers build their forwarding tables by themselves instead of
being hand-configured with routes.txt. Everything rides on rpv UDP, so it works
on wired, wireless and cross-dimension links.

How it works
  * every router periodically broadcasts an ANNOUNCE on each non-WAN interface:
    the list of (net, prefix, metric) it can reach -- its own connected subnets
    with metric 0, everything else with the metric it learned, +1 per hop
  * a node that hears an ANNOUNCE on interface I from neighbour N installs
    `net -> via N` on I with metric = announced + 1, and updates the real route
    table (kind "dv"; route.lua ranks it below connected/static routes)
  * metric 16 means unreachable ("infinity", RIP's 16)

Loop suppression
  * **split horizon with poisoned reverse**: to the neighbour a route was learned
    from, that route is announced back with metric = infinity, so two routers can
    never point at each other
  * **hop limit**: anything at 16 is not installed and removes the route that
    came in over that interface
  * **expiry (hold-down)**: a route not refreshed within `dv_timeout` seconds is
    removed (DV_EXPIRE) instead of lingering

Config keys (node):
    dv=1                 enable
    dv_port=6800         UDP port (all routers must match)
    dv_interval=3        announce period in seconds
    dv_jitter=0          randomise the period by +/- this fraction (0..1); use it on
                         large networks so announces do not arrive in lockstep
    dv_timeout=12        route lifetime without a refresh

Logs: DV_ANNOUNCE, DV_INSTALL, DV_UPDATE, DV_REMOVE, DV_EXPIRE, DV_ROUTE (one
line per installed route, emitted every interval for the harness), DV_STATE.
]]
local M = ...
local u8, u16, u32, r16, r32, byte, sub = M.u8, M.u16, M.u32, M.r16, M.r32, M.byte, M.sub

local PORT = 6800
local T_ANNOUNCE = 1
local INF = 16                 -- hop count meaning "unreachable"

local function dv_pack(entries)
    local out = { u8(T_ANNOUNCE), u16(#entries) }
    for _, e in ipairs(entries) do
        out[#out + 1] = u32(e.net) .. u8(e.prefix) .. u8(e.metric)
    end
    return table.concat(out)
end

local function dv_unpack(s)
    -- u8 type | u16 count | count * (u32 net | u8 prefix | u8 metric)
    if #s < 3 then return nil end
    local n = r16(s, 2)
    if #s < 3 + n * 6 then return nil end
    local out = {}
    for i = 0, n - 1 do
        local o = 4 + i * 6          -- entries start after type(1) + count(2)
        out[#out + 1] = { net = r32(s, o), prefix = byte(s, o + 4), metric = byte(s, o + 5) }
    end
    return out
end

function M.dv_new(node, opts)
    opts = opts or {}
    return {
        node = node,
        port = tonumber(node.cfg.dv_port) or PORT,
        interval = tonumber(node.cfg.dv_interval) or 3,
        timeout = tonumber(node.cfg.dv_timeout) or 12,
        routes = {},          -- net -> { prefix, metric, iface, gw, via, age, own }
        neighbors = {},       -- iface name -> last announce time
        installs = 0, updates = 0, removes = 0, expires = 0, poisoned = 0, announces = 0,
    }
end

-- our own subnets, metric 0, never expired
local function seed_own(dv)
    local node = dv.node
    for _, iface in ipairs(node.ifaces) do
        if not iface.is_wan then
            local key = iface.net .. "/" .. iface.prefix
            dv.routes[key] = { prefix = iface.prefix, net = iface.net, metric = 0,
                               iface = iface, via = nil, own = true, age = 0 }
        end
    end
end

function M.dv_setup(node, opts)
    local dv = M.dv_new(node, opts)
    node.dv = dv
    seed_own(dv)
    node:log("DV_START port=%d interval=%ds timeout=%ds own_subnets=%d",
        dv.port, dv.interval, dv.timeout, (function() local n = 0 for _ in pairs(dv.routes) do n = n + 1 end return n end)())

    dv.sk = node:bind(dv.port, function(data, src, sport)
        local entries = dv_unpack(data)
        if not entries then return end
        local iface = nil
        -- which of our interfaces is this neighbour on?
        for _, i in ipairs(node.ifaces) do
            if not i.is_wan and M.masked(src, i.prefix) == i.net then iface = i break end
        end
        if not iface then
            node:log("DV_IGNORE from=%s (not on a local subnet)", M.int2ip(src))
            return
        end
        dv.neighbors[iface.name] = os.clock()
        if node.cfg.dv_debug == "1" then
            node:log("DV_RX from=%s on=%s entries=%d", M.int2ip(src), iface.name, #entries)
        end
        for _, e in ipairs(entries) do
            if node.cfg.dv_debug == "1" then
                node:log("DV_RX_ENTRY net=%s/%d metric=%d", M.int2ip(e.net), e.prefix, e.metric)
            end
            local key = e.net .. "/" .. e.prefix
            local have = dv.routes[key]
            if e.metric >= INF then
                -- poisoned reverse: a neighbour says "do not come this way".
                -- Only the neighbour we actually route through may invalidate our route:
                -- on a shared segment (a grid LAN has several routers) another neighbour
                -- poisons the route it learned FROM us, and treating that as authoritative
                -- made 3+ hop routes flap install/remove forever.
                if have and not have.own and have.gw == src then
                    dv.routes[key] = nil
                    M.route_upsert(node.routes, have.prefix, have.net, have.iface, nil, "dv", true)
                    dv.removes = dv.removes + 1
                    node:log("DV_REMOVE net=%s/%d reason=poisoned via=%s gw=%s", M.int2ip(e.net), e.prefix, iface.name, M.int2ip(src))
                elseif have and not have.own and have.via == iface.name then
                    dv.poison_ignored = (dv.poison_ignored or 0) + 1
                    if node.cfg.dv_debug == "1" then
                        node:log("DV_POISON_IGNORED net=%s/%d from=%s (our gw is %s)",
                            M.int2ip(e.net), e.prefix, M.int2ip(src), M.int2ip(have.gw or 0))
                    end
                end
                dv.poisoned = dv.poisoned + 1
            else
                -- never take our own connected subnet from someone else
                local is_own = false
                for _, i in ipairs(node.ifaces) do
                    if not i.is_wan and i.net == e.net and i.prefix == e.prefix then is_own = true end
                end
                if not is_own then
                    local candidate = e.metric + 1
                    if candidate < INF and (not have or candidate < have.metric or have.gw == src) then
                        -- a hand-configured/connected route of the same prefix always
                        -- wins: don't shadow it (route_lookup keeps first-added order,
                        -- so the priority is enforced here at install time)
                        local best = M.route_lookup(node.routes, e.net)
                        local blocked = best and best.net == e.net and best.prefix == e.prefix
                            and (M.ROUTE_RANK[best.kind] or 2) > (M.ROUTE_RANK.dv or 2)
                        if blocked then
                            node:log("DV_SHADOWED net=%s/%d by=%s", M.int2ip(e.net), e.prefix, tostring(best.kind))
                        else
                            local isNew = (not have) or have.own
                            dv.routes[key] = { prefix = e.prefix, net = e.net, metric = candidate,
                                               iface = iface, gw = src, via = iface.name, age = 0 }
                            M.route_upsert(node.routes, e.prefix, e.net, iface, src, "dv")
                            if isNew then
                                dv.installs = dv.installs + 1
                                node:log("DV_INSTALL net=%s/%d metric=%d gw=%s via=%s", M.int2ip(e.net), e.prefix, candidate, M.int2ip(src), iface.name)
                            else
                                dv.updates = dv.updates + 1
                                node:log("DV_UPDATE net=%s/%d metric=%d gw=%s via=%s", M.int2ip(e.net), e.prefix, candidate, M.int2ip(src), iface.name)
                            end
                        end
                    end
                end
            end
        end
        dv.dirty = true
    end)

    node:add_task("dv", function()
        -- dv_jitter (0..1, default 0): randomise each period by +/- jitter so a large
        -- network does not announce in lockstep. With dozens of routers on shared media
        -- the synchronised bursts starve ARP and neighbour discovery (measured: a 6x6
        -- grid dropped to 10% delivery without it). Kept at 0 by default so the small
        -- deterministic test topologies stay reproducible.
        local jitter = tonumber(node.cfg.dv_jitter) or 0
        local function period()
            if jitter <= 0 then return dv.interval end
            local f = 1 + (math.random() * 2 - 1) * jitter
            if f < 0.25 then f = 0.25 end
            return dv.interval * f
        end
        os.sleep(1)                        -- let the interfaces settle
        while true do
            local now = os.clock()
            -- 1. announce on every non-WAN interface (split horizon + poisoned reverse)
            for _, iface in ipairs(node.ifaces) do
                if not iface.is_wan then
                    local entries = {}
                    for _, r in pairs(dv.routes) do
                        local metric = r.metric
                        if not r.own and r.via == iface.name then metric = INF end   -- poison reverse
                        entries[#entries + 1] = { net = r.net, prefix = r.prefix, metric = metric }
                    end
                    if node.cfg.dv_debug == "1" then
                        for _, e in ipairs(entries) do
                            node:log("DV_TX iface=%s net=%s/%d metric=%d", iface.name, M.int2ip(e.net), e.prefix, e.metric)
                        end
                    end
                    M.udp_send(node, M.IP_BCAST, dv.port, dv.port, dv_pack(entries), 1, iface.ip)
                    dv.announces = dv.announces + 1
                end
            end
            -- 2. age / expire learned routes
            for key, r in pairs(dv.routes) do
                if not r.own then
                    r.age = (r.age or 0) + dv.interval
                    if r.age > dv.timeout then
                        dv.routes[key] = nil
                        M.route_upsert(node.routes, r.prefix, r.net, r.iface, nil, "dv", true)
                        dv.expires = dv.expires + 1
                        node:log("DV_EXPIRE net=%s/%d via=%s after=%ds", M.int2ip(r.net), r.prefix, tostring(r.via), r.age)
                    end
                end
            end
            -- 3. report (the harness asserts on these lines)
            for _, r in pairs(dv.routes) do
                if not r.own then
                    node:log("DV_ROUTE net=%s/%d metric=%d gw=%s via=%s age=%d",
                        M.int2ip(r.net), r.prefix, r.metric, r.gw and M.int2ip(r.gw) or "-", tostring(r.via), r.age or 0)
                end
            end
            local nRoutes, nNb = 0, 0
            for _, r in pairs(dv.routes) do if not r.own then nRoutes = nRoutes + 1 end end
            for _, t in pairs(dv.neighbors) do if now - t <= dv.timeout then nNb = nNb + 1 end end
            node:log("DV_STATE learned=%d neighbors=%d installs=%d updates=%d removes=%d expires=%d poisoned=%d announces=%d",
                nRoutes, nNb, dv.installs, dv.updates, dv.removes, dv.expires, dv.poisoned, dv.announces)
            os.sleep(period())
        end
    end)
    return dv
end

M.DV_INFINITY = INF

return M
