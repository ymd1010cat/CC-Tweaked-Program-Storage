--[[- rpv/qos.lua ? multi-priority egress queues (control traffic wins).

Why: a CC router is single threaded and every transmit costs real time, so a bulk
transfer can sit in front of the one packet that matters -- a TCP-ish ACK from
conn.lua, an ICMP error, a routing announcement. With QoS enabled, `link_send`
queues frames instead of transmitting them, and a tick task drains the queues in
priority order with a per-tick budget.

Priorities (lower number = more urgent):
    0  control   : ICMP, ARP, conn pure ACKs (segment type 3, len 0), DV/announce
    1  interactive: UDP up to `qos_small` bytes (commands, telemetry, chat)
    2  bulk      : everything else (file transfers)

Config keys:
    qos=1                  enable
    qos_budget=16          frames drained per tick
    qos_budget_bytes=4096  byte budget per tick
    qos_max_queue=64       per-interface queue depth (drop lowest priority first)
    qos_small=96           "interactive" threshold in bytes
    qos_weights=4,2,1      drain weights for priorities 0,1,2 per tick round

API: rpv.qos_setup(node), rpv.qos_enqueue(node, iface, dstmac, etype, body),
     rpv.qos_classify(body, etype), rpv.qos_flush(node), rpv.qos_stats(node)

Logs: QOS_START, QOS_DROP, QOS_STATE tx= high= mid= low= dropped= queued= depth=.
]]
local M = ...
local u16, r16, byte, sub = M.u16, M.r16, M.byte, M.sub

-- 0 = control, 1 = interactive, 2 = bulk
function M.qos_classify(body, etype)
    if etype ~= M.ET_IP then return 0 end                    -- ARP and friends: control
    if #body < 20 then return 0 end
    local ihl = (byte(body, 1) % 16) * 4
    if ihl < 20 or #body < ihl then return 1 end
    local proto = byte(body, 10)
    if proto == M.IP_ICMP then return 0 end
    if proto == M.IP_UDP and #body >= ihl + 8 then
        local udp = sub(body, ihl + 1)
        -- conn.lua pure ACK: segment type 3 (DATA) with a zero length field
        if byte(udp, 9) == 3 and r16(udp, 20) == 0 then return 0 end
        if #udp - 8 <= (M.qos_small or 96) then return 1 end
        return 2
    end
    return 1
end

local function parse_weights(spec)
    local w = {}
    for n in tostring(spec or "4,2,1"):gmatch("%d+") do w[#w + 1] = tonumber(n) end
    if #w == 0 then w = { 4, 2, 1 } end
    return w
end

function M.qos_setup(node, opts)
    if node.cfg.qos ~= "1" then return nil end
    local q = {
        node = node,
        budget = tonumber(node.cfg.qos_budget) or 16,
        budget_bytes = tonumber(node.cfg.qos_budget_bytes) or 4096,
        max_queue = tonumber(node.cfg.qos_max_queue) or 64,
        small = tonumber(node.cfg.qos_small) or 96,
        weights = parse_weights(node.cfg.qos_weights),
        queues = {},              -- iface name -> { [prio] = {frames...} }
        tx = 0, high = 0, mid = 0, low = 0, dropped = 0, queued = 0, drained = 0,
    }
    M.qos_small = q.small
    node.qos = q
    node:log("QOS_START budget=%d frames/%d bytes per tick max_queue=%d small=%d weights=%s",
        q.budget, q.budget_bytes, q.max_queue, q.small, node.cfg.qos_weights or "4,2,1")

    node:add_task("qos", function()
        local nextReport = os.clock() + 5
        while true do
            M.qos_flush(node)
            os.sleep(0)
            local now = os.clock()
            if now >= nextReport then
                nextReport = now + 5
                local depth = 0
                for _, byPrio in pairs(q.queues) do
                    for _, list in pairs(byPrio) do depth = depth + #list end
                end
                node:log("QOS_STATE tx=%d high=%d mid=%d low=%d dropped=%d queued=%d depth=%d",
                    q.tx, q.high, q.mid, q.low, q.dropped, q.queued, depth)
            end
        end
    end)
    return q
end

local function depth_of(q, iface)
    local byPrio = q.queues[iface.name]
    if not byPrio then return 0 end
    local n = 0
    for _, list in pairs(byPrio) do n = n + #list end
    return n
end

function M.qos_enqueue(node, iface, dstmac, etype, body)
    local q = node.qos
    if not q then return false end
    local prio = M.qos_classify(body, etype)
    local byPrio = q.queues[iface.name]
    if not byPrio then byPrio = {}; q.queues[iface.name] = byPrio end
    local list = byPrio[prio]
    if not list then list = {}; byPrio[prio] = list end
    if depth_of(q, iface) >= q.max_queue then
        -- drop the least urgent frame we can find (never the urgent one we are adding
        -- unless the whole queue is priority 0)
        local victimPrio, victimList = nil, nil
        for p = 2, prio, -1 do
            local l = byPrio[p]
            if l and #l > 0 then victimPrio, victimList = p, l break end
        end
        if victimList then
            table.remove(victimList, 1)
            q.dropped = q.dropped + 1
            node:log("QOS_DROP prio=%d iface=%s depth=%d (queue full)", victimPrio, iface.name, depth_of(q, iface))
        else
            q.dropped = q.dropped + 1
            node:log("QOS_DROP prio=%d iface=%s depth=%d (only urgent traffic queued)", prio, iface.name, depth_of(q, iface))
            return true
        end
    end
    list[#list + 1] = { dstmac = dstmac, etype = etype, body = body, prio = prio }
    q.queued = q.queued + 1
    return true
end

-- drain the queues: all of priority 0 first (up to the budget), then weighted
-- rounds for 1 and 2 so bulk traffic cannot starve control traffic
function M.qos_flush(node)
    local q = node.qos
    if not q then return 0 end
    local sent, bytes = 0, 0
    q.bypass = true
    local function send_one(iface, item)
        return M.link_send(node, iface, item.dstmac, item.etype, item.body)
    end
    -- round robin across interfaces so one busy link cannot hold the others back
    for name, byPrio in pairs(q.queues) do
        local iface = node.by_iface and node.by_iface[name]
        if not iface then
            for _, i in ipairs(node.ifaces) do if i.name == name then iface = i end end
        end
        if iface then
            for prio = 0, 2 do
                local list = byPrio[prio]
                local weight = q.weights[prio + 1] or 1
                local allowance = (prio == 0) and q.budget or math.max(1, weight)
                local n = 0
                while list and #list > 0 and sent < q.budget and bytes < q.budget_bytes and n < allowance do
                    local item = table.remove(list, 1)
                    bytes = bytes + #item.body + 10
                    send_one(iface, item)
                    sent = sent + 1
                    n = n + 1
                    if prio == 0 then q.high = q.high + 1
                    elseif prio == 1 then q.mid = q.mid + 1
                    else q.low = q.low + 1 end
                end
                if sent >= q.budget or bytes >= q.budget_bytes then break end
            end
        end
    end
    q.bypass = false
    q.tx = q.tx + sent
    return sent
end

function M.qos_stats(node)
    local q = node.qos
    if not q then return nil end
    local depth = 0
    for _, byPrio in pairs(q.queues) do
        for _, list in pairs(byPrio) do depth = depth + #list end
    end
    return { tx = q.tx, high = q.high, mid = q.mid, low = q.low, dropped = q.dropped,
             queued = q.queued, depth = depth }
end

return M
