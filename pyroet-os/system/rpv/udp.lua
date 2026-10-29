--[[- rpv/udp.lua -- UDP datagrams + the socket API apps use.

A socket is a small object; because the node owns the event loop, apps are
callback driven:

    local sk = node:bind(9000)
    sk:on_receive(function(data, src, sport)
        sk:sendto(src, sport, "echo:" .. data)
    end)

There is deliberately no blocking recvfrom: inside one CC computer the node's
event loop is the only thing allowed to call os.pullEvent, so apps must either
use callbacks or node:after() timers. That is the same model as rednet.receive
vs os.pullEvent in vanilla CC.
]]
local M = ...
local u8, u16, u32, r16, cksum, sub, int2ip = M.u8, M.u16, M.u32, M.r16, M.cksum, M.sub, M.int2ip

function M.udp_new()
    return { ports = {}, tx = 0, rx = 0, dropped = 0, bad_cksum = 0 }
end

function M.udp_send(node, dst, sport, dport, data, ttl, src, df)
    src = src or node:pick_src(dst)
    local len = 8 + #data
    local pseudo = u32(src) .. u32(dst) .. u8(0) .. u8(M.IP_UDP) .. u16(len)
    local ck = cksum(pseudo .. u16(sport) .. u16(dport) .. u16(len) .. u16(0) .. data)
    if ck == 0 then ck = 0xFFFF end
    local hdr = u16(sport) .. u16(dport) .. u16(len) .. u16(ck)
    node.udp.tx = node.udp.tx + 1
    return node:send_ip(dst, M.IP_UDP, hdr .. data, ttl or 64, src, df)
end

function M.udp_bind(node, port, cb)
    local sk = { port = port, node = node, tx = 0, rx = 0, closed = false, handler = cb }
    function sk:on_receive(fn) self.handler = fn end
    function sk:sendto(dst, dport, data, ttl)
        if self.closed then return false end
        self.tx = self.tx + 1
        return M.udp_send(self.node, dst, self.port, dport, data, ttl)
    end
    function sk:reply(data, src, sport) return self:sendto(src, sport, data) end
    function sk:close()
        self.closed = true
        self.node.udp.ports[self.port] = nil
    end
    function sk:stats() return { port = self.port, rx = self.rx, tx = self.tx, closed = self.closed } end
    node.udp.ports[port] = sk
    return sk
end

function M.udp_input(node, iface, h, payload)
    if #payload < 8 then return end
    local sport, dport, len = r16(payload, 1), r16(payload, 3), r16(payload, 5)
    local data = sub(payload, 9)
    local pseudo = u32(h.src) .. u32(h.dst) .. u8(0) .. u8(M.IP_UDP) .. u16(len)
    local ck = r16(payload, 7)
    local expected = cksum(pseudo .. sub(payload, 1, 6) .. u16(0) .. data)
    if ck ~= 0 and ck ~= expected then
        node.udp.bad_cksum = node.udp.bad_cksum + 1
        node:log("UDP_BAD_CKSUM from=%s dport=%d", int2ip(h.src), dport)
        return
    end
    node.udp.rx = node.udp.rx + 1
    local sk = node.udp.ports[dport]
    if not sk or sk.closed then
        node.udp.dropped = node.udp.dropped + 1
        node:log("UDP_NO_PORT dport=%d from=%s sport=%d bytes=%d", dport, int2ip(h.src), sport, #data)
        -- Pyroet OS subset: icmp.lua is not vendored, so the port-unreachable option
        -- has no ICMP sender to call. Warn once (ASCII) and keep dropping: the
        -- UDP_NO_PORT line above and node.udp.dropped already record the packet.
        if node.icmp_port_unreachable and M.icmp_error then
            M.icmp_error(node, iface, h, payload, 3, 3)
        elseif node.icmp_port_unreachable then
            M.subset_missing(node, "RPV_SUBSET_NO_ICMP", "icmp_port_unreachable=1")
        end
        return
    end
    sk.rx = sk.rx + 1
    node:log("UDP_RECV dport=%d from=%s sport=%d bytes=%d", dport, int2ip(h.src), sport, #data)
    if sk.handler then sk.handler(data, h.src, sport, sk) end
end

return M
