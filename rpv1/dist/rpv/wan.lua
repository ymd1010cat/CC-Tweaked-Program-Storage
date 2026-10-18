--[[- rpv/wan.lua ? rednet as the WAN interface only.

Ported from the monolithic prototype. The WAN interface's link layer IS rednet:
frames are handed to rednet.send(<peer id>, frame, "rpv") and arrive as
rednet_message. Routers advertise their connected subnets ({"rpv-advert"}),
peers learn WAN routes from those, plain rednet devices are reached through
static map= entries with UDP<->table translation. Nothing here is used for LAN
traffic: rednet.open() is only ever called on the WAN modem.
]]
local M = ...
local u8, u16, u32, r16, r32, byte, sub, floor, int2ip = M.u8, M.u16, M.u32, M.r16, M.r32, M.byte, M.sub, M.floor, M.int2ip

function M.wan_new(side, mtu)
    return {
        side = side, channel = "wan", mtu = tonumber(mtu) or 512,
        is_wan = true, peers = {}, routes = {}, legacy = {},
        advert = 0, legacy_tx = 0, legacy_rx = 0, sent_frames = 0, recv_frames = 0,
        seq = 0, advert_seq = {},
        iface = { side = side, name = "WAN", channel = "wan", is_wan = true, ip = 0, prefix = 0, mtu = tonumber(mtu) or 512 },
    }
end

function M.wan_setup(node, w, cidr)
    w.iface.cidr = cidr
    -- the WAN interface gets a connected route for its own subnet, exactly like a LAN
    -- interface: directly attached WAN peers are then reachable without waiting for an
    -- advert (needed by the minimal "WAN only" topology and by WAN-only nodes)
    local ipstr, prefix = tostring(cidr):match("^([%d%.]+)/(%d+)$")
    if ipstr then
        w.iface.ip = M.ip2int(ipstr)
        w.iface.prefix = tonumber(prefix)
        w.iface.net = M.masked(w.iface.ip, w.iface.prefix)
        if M.route_connected then M.route_connected(node.routes, w.iface) end
    end
    if peripheral.getType(w.side) ~= "modem" then
        node:log("WAN_NO_MODEM side=%s", w.side)
        return false
    end
    rednet.open(w.side)
    node.by_channel["wan"] = w.iface
    -- static WAN neighbours (wan_peer=172.16.0.2:22[,more]): a directly attached peer can
    -- be pinned so the first packet does not have to wait for an advert or a hello to
    -- teach us its rednet id (the wired/wireless equivalent of a static ARP entry)
    for spec in tostring(node.cfg.wan_peer or ""):gmatch("[^,]+") do
        local pip, pid = spec:match("^%s*([%d%.]+)%s*:%s*(%d+)%s*$")
        if pip and pid then
            w.peers[pip] = tonumber(pid)
            node:log("WAN_PEER_STATIC ip=%s id=%s", pip, pid)
        end
    end
    -- both wired and wireless modems are accepted: rednet.open works on either, and
    -- nothing here assumes wireless (the router needs the peer on the same wired
    -- network, or within wireless range)
    local ptype = peripheral.getType(w.side)
    local pwireless = nil
    if ptype == "modem" then
        local okw, v = pcall(peripheral.call, w.side, "isWireless")
        pwireless = okw and v or nil
    end
    node:log("WAN_READY side=%s addr=%s mtu=%d advertise=%s peripheral=%s phys_wireless=%s",
        w.side, w.iface.cidr, w.mtu, tostring(node.cfg.advert == "1"), tostring(ptype), tostring(pwireless))
    if node.cfg.rpv_host then
        rednet.host("rpv", node.cfg.rpv_host)
        node:log("WAN_REDNET_HOST protocol=rpv name=%s", node.cfg.rpv_host)
    end
    if node.cfg.advert == "1" then node:after(1.0, function() M.wan_advert_loop(node, w) end) end
    -- WAN tunnel AEAD (wansec.lua): opt-in with wan_secure=1
    if node.cfg.wan_secure == "1" and M.wansec_setup then
        M.wansec_setup(node, w)
        node:after(1.5, function() M.wansec_hello_loop(node, w) end)
    end
    return true
end

function M.wan_frame_send(node, w, peer, pkt)
    local frame = u32(peer) .. u32(node.mac) .. u16(M.ET_IP) .. pkt
    if node.wansec and node.wansec.enabled then
        local env = M.wansec_wrap(node, w, peer, frame)
        if not env then
            w.sec_dropped = (w.sec_dropped or 0) + 1
            return false                      -- fail closed: no keys, no frame
        end
        rednet.send(peer, env, "rpv")
    else
        rednet.send(peer, frame, "rpv")
    end
    w.sent_frames = w.sent_frames + 1
    return true
end

-- path = { peer = rednet id, peer_ip = rpv ip, legacy = bool }
function M.wan_send(node, w, path, src, dst, proto, ttl, payload)
    if not path.peer then
        node.stats.wan_no_peer = (node.stats.wan_no_peer or 0) + 1
        node:log("WAN_NO_PEER dst=%s (no rednet id known yet)", int2ip(dst))
        return false
    end
    if path.legacy then
        if proto ~= M.IP_UDP then
            node:log("WAN_LEGACY_UNSUPPORTED proto=%d dst=%s", proto, int2ip(dst))
            return false
        end
        local sport, dport, data = r16(payload, 1), r16(payload, 3), sub(payload, 9)
        if #data + 8 > w.mtu then
            node:log("WAN_LEGACY_TOO_BIG bytes=%d mtu=%d", #data, w.mtu)
            return false
        end
        w.legacy_tx = w.legacy_tx + 1
        node:log("WAN_LEGACY_TX peer=%d to=%s sport=%d dport=%d bytes=%d", path.peer, int2ip(dst), sport, dport, #data)
        rednet.send(path.peer, {
            sType = "udp", from = int2ip(src), to = int2ip(dst),
            sport = sport, dport = dport, data = data,
        }, "rpv")
        return true
    end
    local id = node:next_ipid()
    local maxpay = w.mtu - 20
    maxpay = maxpay - (maxpay % 8)
    local frames = 0
    if #payload <= maxpay then
        M.wan_frame_send(node, w, path.peer, M.ip_build(src, dst, proto, ttl, id, false, 0, payload))
        frames = 1
    else
        for off = 0, #payload - 1, maxpay do
            local chunk = sub(payload, off + 1, math.min(off + maxpay, #payload))
            local mf = (off + #chunk) < #payload
            M.wan_frame_send(node, w, path.peer, M.ip_build(src, dst, proto, ttl, id, mf, off / 8, chunk))
            frames = frames + 1
        end
        node:log("WAN_FRAGMENTED id=%d bytes=%d frames=%d mtu=%d", id, #payload, frames, w.mtu)
    end
    node.stats.wan_sent = (node.stats.wan_sent or 0) + frames
    node:log("WAN_SENT peer=%d dst=%s proto=%d ttl=%d bytes=%d frames=%d", path.peer, int2ip(dst), proto, ttl, #payload, frames)
    return true
end

function M.wan_input(node, w, sender, message, protocol)
    if protocol ~= "rpv" then return end
    -- WAN AEAD: unwrap encrypted frames, verify signed control tables
    if node.wansec then
        if type(message) == "table" and message.sType == "rpv-sec-hello" then
            return M.wansec_hello_input(node, w, sender, message)
        end
        if type(message) == "string" then
            if sub(message, 1, 1) == "S" then
                local plain = M.wansec_unwrap(node, w, sender, message)
                if not plain then return end
                message = plain
            elseif node.wansec.enabled then
                node.wansec.plaintext = node.wansec.plaintext + 1
                node:log("WANSEC_PLAINTEXT data frame from=%s bytes=%d (dropped, fail closed)", tostring(sender), #message)
                return
            end
        elseif type(message) == "table" then
            if not M.wansec_verify_table(node, w, sender, message) then return end
        end
    end
    if type(message) == "string" and #message >= 10 then
        local srcmac = r32(message, 5)
        if srcmac ~= sender then node:log("WAN_SPOOF frame_srcmac=%d rednet_sender=%s", srcmac, tostring(sender)) end
        node.stats.wan_recv = (node.stats.wan_recv or 0) + 1
        w.recv_frames = w.recv_frames + 1
        local h = M.ip_parse(sub(message, 11))
        if h then
            w.peers[h.src] = sender
            w.peer_seen = w.peer_seen or {}
            w.peer_seen[h.src] = os.clock() + 9
        end
        node:log("WAN_RECV from=%s bytes=%d", tostring(sender), #message)
        return node:on_frame(w.iface, message)
    end
    if type(message) ~= "table" then return end
    if message.sType == "rpv-advert" then return M.wan_advert_input(node, w, sender, message) end
    if message.sType == "rpv-is-at" then
        local ip = type(message.ip) == "string" and M.ip2int(message.ip) or nil
        if ip then
            w.peers[ip] = tonumber(message.id) or sender
            w.peer_seen = w.peer_seen or {}
            w.peer_seen[ip] = os.clock() + 9
        end
        node:log("WAN_IS_AT ip=%s id=%s", tostring(message.ip), tostring(message.id))
        return
    end
    if message.sType == "rpv-who-has" then return M.wan_who_has(node, w, sender, message) end
    if message.sType == "udp" then return M.wan_legacy_rx(node, w, sender, message) end
    node:log("WAN_CTRL_UNKNOWN type=%s", tostring(message.sType))
end

function M.wan_advert(node, w)
    local nets = {}
    for _, i in ipairs(node.ifaces) do
        -- advertise LANs only: the WAN subnet itself is not a remote network
        if not i.is_wan then nets[#nets + 1] = i.cidr end
    end
    w.seq = w.seq + 1
    local advert = {
        sType = "rpv-advert", ver = 1, seq = w.seq, hops = 1,
        gw = node.mac, ip = int2ip(w.iface.ip), nets = nets,
        default = node.cfg.advert_default == "1" and 1 or nil,
    }
    if M.wansec_sign_table then M.wansec_sign_table(node, advert) end
    rednet.broadcast(advert, "rpv")
    w.advert = w.advert + 1
    node:log("WAN_ADVERT_SENT ip=%s nets=%d seq=%d default=%s", int2ip(w.iface.ip), #nets, w.seq,
        tostring(node.cfg.advert_default == "1"))
end

function M.wan_advert_loop(node, w)
    M.wan_advert(node, w)
    node:after(tonumber(node.cfg.advert_interval) or 3, function() M.wan_advert_loop(node, w) end)
end

function M.wan_advert_input(node, w, sender, message)
    local gid = tonumber(message.gw) or sender
    local gwip = type(message.ip) == "string" and M.ip2int(message.ip) or nil
    -- loop protection: an advert that travelled too far is ignored
    local hops = tonumber(message.hops) or 1
    local max_hops = tonumber(node.cfg.max_advert_hops) or 4
    if hops > max_hops then
        node:log("WAN_ADVERT_LOOP gw=%d hops=%d > max %d (ignored)", gid, hops, max_hops)
        return
    end
    -- sequence check: reordered/duplicated adverts are ignored
    local seq = tonumber(message.seq)
    if seq then
        local last = w.advert_seq[gid]
        if last and seq <= last then
            node.stats.wan_advert_stale = (node.stats.wan_advert_stale or 0) + 1
            node:log("WAN_ADVERT_STALE gw=%d seq=%d <= %d (ignored)", gid, seq, last)
            return
        end
        w.advert_seq[gid] = seq
    end
    if gwip then
        w.peers[gwip] = gid
        w.peer_seen = w.peer_seen or {}
        w.peer_seen[gwip] = os.clock() + 9
    end
    local added, nets = 0, message.nets or {}
    for _, netstr in ipairs(nets) do
        local ip, prefix = tostring(netstr):match("^([%d%.]+)/(%d+)$")
        if ip then
            local pn = tonumber(prefix)
            local net = M.masked(M.ip2int(ip), pn)
            local mine = false
            for _, i in ipairs(node.ifaces) do
                if i.net == net and i.prefix == pn then mine = true end
            end
            if not mine and gid ~= node.mac then
                w.routes[string.format("%s/%d", int2ip(net), pn)] =
                    { prefix = pn, net = net, wan = true, gw_id = gid, gw_ip = gwip, expires = os.clock() + 9 }
                added = added + 1
            end
        end
    end
    -- optional default route: only installed when this site has no static gateway
    if message.default == 1 and gwip and not node.cfg.gw and gid ~= node.mac then
        w.routes["0.0.0.0/0"] = { prefix = 0, net = 0, wan = true, gw_id = gid, gw_ip = gwip, expires = os.clock() + 9 }
        node:log("WAN_DEFAULT_ROUTE gw=%d via=%s", gid, int2ip(gwip))
    end
    node:log("WAN_ADVERT_RECV gw=%d ip=%s seq=%s nets=%d added=%d", gid, tostring(message.ip), tostring(seq), #nets, added)
end

function M.wan_who_has(node, w, sender, message)
    local ip = type(message.ip) == "string" and M.ip2int(message.ip) or nil
    if not ip then return end
    local mine = false
    for _, i in ipairs(node.ifaces) do
        if i.ip == ip then mine = true end
    end
    node:log("WAN_WHO_HAS from=%s ip=%s answer=%s", tostring(sender), int2ip(ip), tostring(mine))
    if mine then
        local reply = { sType = "rpv-is-at", ip = int2ip(ip), id = node.mac }
        if M.wansec_sign_table then M.wansec_sign_table(node, reply) end
        rednet.send(sender, reply, "rpv")
    end
end

function M.wan_legacy_rx(node, w, sender, message)
    local dst = type(message.to) == "number" and message.to or M.ip2int(message.to)
    local sport = tonumber(message.sport) or 0
    local dport = tonumber(message.dport) or 0
    local data = tostring(message.data or "")
    w.legacy_rx = w.legacy_rx + 1
    node:log("WAN_LEGACY_RX from_rednet=%s to=%s sport=%d dport=%d bytes=%d", tostring(sender), int2ip(dst), sport, dport, #data)
    M.udp_send(node, dst, sport, dport, data, 64)
end

function M.wan_tick(node, w)
    local now = os.clock()
    for key, r in pairs(w.routes) do
        if r.expires < now then
            w.routes[key] = nil
            node:log("WAN_ROUTE_EXPIRED net=%s", key)
        end
    end
    if w.peer_seen then
        for ip, exp in pairs(w.peer_seen) do
            if exp < now and not w.legacy[ip] then
                w.peers[ip] = nil
                w.peer_seen[ip] = nil
            end
        end
    end
end

return M
