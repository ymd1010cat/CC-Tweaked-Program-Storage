--[[- apps/rednet-dir.lua — directory for the rednet compatibility shim.

Runs on a router. Keeps computer-id -> rpv-ip registrations and protocol
hostnames (so legacy rednet.lookup works), and relays broadcasts to every
registered node (that is how rednet's flood is emulated across subnets).

  app=rednet-dir:4100
]]
return function(M, node, args)
    local port = tonumber(args) or 4100
    local ids, names = {}, {}
    local st = { reg = 0, lookups = 0, hits = 0, bcasts = 0, relays = 0, names = 0 }

    local function send(ip, tbl) M.udp_send(node, ip, port, port, textutils.serialize(tbl), 64) end

    local sk = node:bind(port, function(data, src, sport)
        local ok, msg = pcall(textutils.unserialize, data)
        if not ok or type(msg) ~= "table" then
            node:log("DIR_BAD_PACKET from=%s bytes=%d", M.int2ip(src), #data)
            return
        end
        if msg.t == "reg" then
            local is_new = ids[msg.id] == nil
            ids[msg.id] = { ip = msg.ip, expires = os.clock() + 15 }
            st.reg = st.reg + 1
            if is_new then node:log("DIR_REG id=%s ip=%s", tostring(msg.id), M.int2ip(msg.ip)) end
        elseif msg.t == "lookup" then
            st.lookups = st.lookups + 1
            local e = ids[msg.id]
            if e and e.expires > os.clock() then
                st.hits = st.hits + 1
                send(src, { t = "reply", id = msg.id, ip = e.ip })
                node:log("DIR_LOOKUP id=%s -> %s", tostring(msg.id), M.int2ip(e.ip))
            else
                node:log("DIR_LOOKUP id=%s MISS", tostring(msg.id))
            end
        elseif msg.t == "bcast" then
            st.bcasts = st.bcasts + 1
            local n = 0
            for id, e in pairs(ids) do
                if id ~= msg.from and e.expires > os.clock() then
                    send(e.ip, { t = "data", from = msg.from, protocol = msg.protocol, message = msg.message })
                    n = n + 1
                end
            end
            st.relays = st.relays + n
            node:log("DIR_BCAST from=%s protocol=%s relayed=%d", tostring(msg.from), tostring(msg.protocol), n)
        elseif msg.t == "host" then
            local id = msg.id or msg.from
            names[msg.protocol] = names[msg.protocol] or {}
            names[msg.protocol][msg.hostname] = id
            st.names = st.names + 1
            node:log("DIR_HOST protocol=%s name=%s id=%s", tostring(msg.protocol), tostring(msg.hostname), tostring(id))
        elseif msg.t == "unhost" then
            if names[msg.protocol] then names[msg.protocol][msg.hostname] = nil end
        elseif msg.t == "name_query" then
            local tab = names[msg.protocol]
            local id = nil
            if tab then id = msg.hostname and tab[msg.hostname] or next(tab) end
            send(src, { t = "name_reply", req = msg.req, id = id })
            node:log("DIR_NAME_QUERY protocol=%s hostname=%s -> %s", tostring(msg.protocol), tostring(msg.hostname), tostring(id))
        else
            node:log("DIR_UNKNOWN t=%s", tostring(msg.t))
        end
    end) -- luacheck: ignore sk

    node:add_task("dir-expiry", function()
        while true do
            os.sleep(5)
            for id, e in pairs(ids) do
                if e.expires < os.clock() then ids[id] = nil end
            end
        end
    end)

    node:log("REDNET_DIR bound port=%d", port)
end
