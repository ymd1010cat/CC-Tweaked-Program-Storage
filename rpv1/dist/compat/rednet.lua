--[[- compat/rednet.lua — drop-in `rednet` API on top of rpv.

Legacy CC programs keep calling rednet.send / receive / broadcast / host /
lookup unchanged; they just get addressed over rpv instead of rednet's flood.

Envelope (UDP to SHIM_PORT, serialised tables):
  reg        { t="reg", id=<computer id>, ip=<rpv ip> }          node -> directory, every 3 s
  lookup     { t="lookup", id=<target id>, from=<id> }           node -> directory
  reply      { t="reply", id=<id>, ip=<ip> }                     directory -> node
  data       { t="data", from=<id>, protocol=, message= }        node <-> node
  bcast      { t="bcast", from=<id>, protocol=, message= }       node -> directory (relayed to all)
  host       { t="host", from=<id>, protocol=, hostname= }       node -> directory
  unhost     { t="unhost", from=, protocol=, hostname= }
  name_query { t="name_query", req=<nonce>, protocol=, hostname= }
  name_reply { t="name_reply", req=<nonce>, id=<id|nil> }

Rules kept from rednet: receive returns (sender, message, protocol); broadcast
reaches every node; host/lookup give name resolution. Differences: no CHANNEL_*
(no channels at all), and messages travel as UDP datagrams so they can be routed.
]]
local M = ...
local SHIM_PORT = 4100

function M.rednet_shim_new(node, opts)
    opts = opts or {}
    local me = node.id
    local my_ip = opts.ip or (node.ifaces[1] and node.ifaces[1].ip)
    local dir_ip = opts.dir_ip
    local port = opts.port or SHIM_PORT
    local cache = { [me] = my_ip }        -- computer id -> rpv ip
    local queue = {}                      -- received messages not consumed yet
    local pending = {}                    -- sends waiting for an id lookup
    local names = {}                      -- protocol -> hostname (hosted locally)
    local open = false
    local st = { tx = 0, rx = 0, lookups = 0, resolved = 0, bcasts = 0, unresolved = 0, drops = 0 }

    local function enc(t) return textutils.serialize(t) end
    local function send_to(ip, tbl) return M.udp_send(node, ip, port, port, enc(tbl), 64) end

    local function deliver(sender, message, protocol)
        st.rx = st.rx + 1
        node:log("SHIM_RECV from=%s protocol=%s", tostring(sender), tostring(protocol))
        if node:has_waiter("rpv_rednet") then
            node:emit_event("rpv_rednet", sender, message, protocol)
        else
            queue[#queue + 1] = { sender, message, protocol }
        end
    end

    local function flush_pending(id, ip)
        for i = #pending, 1, -1 do
            local p = pending[i]
            if p.id == id then
                send_to(ip, { t = "data", from = me, protocol = p.protocol, message = p.message })
                st.tx = st.tx + 1
                table.remove(pending, i)
            end
        end
    end

    local function on_datagram(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if not ok or type(msg) ~= "table" then
            st.drops = st.drops + 1
            node:log("SHIM_BAD_PACKET bytes=%d", #data)
            return
        end
        if msg.t == "data" then
            deliver(msg.from, msg.message, msg.protocol)
        elseif msg.t == "reply" then
            cache[msg.id] = msg.ip
            st.resolved = st.resolved + 1
            node:log("SHIM_RESOLVED id=%s ip=%s", tostring(msg.id), M.int2ip(msg.ip))
            flush_pending(msg.id, msg.ip)
        elseif msg.t == "reg" then
            cache[msg.id] = msg.ip
            node:log("SHIM_PEER_REG id=%s ip=%s", tostring(msg.id), M.int2ip(msg.ip))
        elseif msg.t == "name_reply" then
            node:emit_event("rpv_rednet_name", msg.req, msg.id)
        else
            node:log("SHIM_UNKNOWN_TYPE t=%s", tostring(msg.t))
        end
    end

    local sk = node:bind(port, on_datagram)   -- luacheck: ignore sk

    -- ---- rednet API ----
    local rednet = {
        CHANNEL_BROADCAST = 65535,
        CHANNEL_REPEAT = 65533,
        MAX_ID_CHANNELS = 65500,
    }

    local function announce()
        local msg = { t = "reg", id = me, ip = my_ip }
        if dir_ip then send_to(dir_ip, msg) end
        M.udp_send(node, M.IP_BCAST, port, port, enc(msg), 64)   -- same-subnet peers
    end

    function rednet.open(side)
        if open then return false end
        open = true
        node:log("SHIM_OPEN id=%d ip=%s dir=%s port=%d side=%s", me, M.int2ip(my_ip),
            dir_ip and M.int2ip(dir_ip) or "none", port, tostring(side))
        node:add_task("rednet-announce", function()
            while true do
                announce()
                os.sleep(3)
            end
        end)
        return true
    end

    function rednet.close(side) open = false end
    function rednet.isOpen(side) return open end

    function rednet.send(recipient, message, protocol)
        recipient = tonumber(recipient)
        if recipient == me then
            deliver(me, message, protocol)
            return true
        end
        local ip = cache[recipient]
        if ip then
            send_to(ip, { t = "data", from = me, protocol = protocol, message = message })
            st.tx = st.tx + 1
            return true
        end
        st.unresolved = st.unresolved + 1
        pending[#pending + 1] = { id = recipient, message = message, protocol = protocol, expires = os.clock() + 5 }
        if dir_ip then
            send_to(dir_ip, { t = "lookup", id = recipient, from = me })
            st.lookups = st.lookups + 1
        end
        node:log("SHIM_SEND_QUEUED id=%s (awaiting directory reply)", tostring(recipient))
        return true
    end

    function rednet.broadcast(message, protocol)
        st.bcasts = st.bcasts + 1
        if dir_ip then
            send_to(dir_ip, { t = "bcast", from = me, protocol = protocol, message = message })
        else
            M.udp_send(node, M.IP_BCAST, port, port, enc({ t = "data", from = me, protocol = protocol, message = message }), 64)
        end
        return true
    end

    function rednet.receive(protocol_filter, timeout)
        -- drain anything already queued
        for i = 1, #queue do
            local q = queue[i]
            if protocol_filter == nil or q[3] == protocol_filter then
                table.remove(queue, i)
                return q[1], q[2], q[3]
            end
        end
        local timer = timeout and os.startTimer(timeout) or nil
        while true do
            local ev, p1, p2, p3 = os.pullEvent(timer and nil or "rpv_rednet")
            if ev == "rpv_rednet" then
                if protocol_filter == nil or p3 == protocol_filter then
                    if timer then os.cancelTimer(timer) end
                    return p1, p2, p3
                end
            elseif ev == "timer" and p1 == timer then
                return nil
            end
        end
    end

    function rednet.host(protocol, hostname)
        if hostname == "localhost" then error("Reserved hostname", 2) end
        names[protocol] = hostname
        if dir_ip then send_to(dir_ip, { t = "host", id = me, from = me, protocol = protocol, hostname = hostname }) end
        node:log("SHIM_HOST protocol=%s name=%s", tostring(protocol), tostring(hostname))
    end

    function rednet.unhost(protocol)
        local h = names[protocol]
        names[protocol] = nil
        if dir_ip then send_to(dir_ip, { t = "unhost", from = me, protocol = protocol, hostname = h }) end
    end

    function rednet.lookup(protocol, hostname)
        if names[protocol] and (hostname == nil or hostname == names[protocol]) then return me end
        if not dir_ip then return nil end
        local req = tostring(os.clock()) .. "-" .. tostring(me)
        send_to(dir_ip, { t = "name_query", req = req, protocol = protocol, hostname = hostname, from = me })
        local timer = os.startTimer(3)
        while true do
            local ev, p1, p2 = os.pullEvent()
            if ev == "rpv_rednet_name" and p1 == req then
                os.cancelTimer(timer)
                return p2
            elseif ev == "timer" and p1 == timer then
                return nil
            end
        end
    end

    function rednet.stats()
        return st, { queued = #queue, pending = #pending, cached = (function()
            local n = 0 for _ in pairs(cache) do n = n + 1 end return n end)() }
    end

    -- resolve expires so a silent peer does not stay cached forever
    node:add_task("rednet-pending-expiry", function()
        while true do
            os.sleep(1)
            for i = #pending, 1, -1 do
                if pending[i].expires < os.clock() then
                    node:log("SHIM_PENDING_EXPIRED id=%s", tostring(pending[i].id))
                    table.remove(pending, i)
                end
            end
        end
    end)

    return rednet
end

return M
