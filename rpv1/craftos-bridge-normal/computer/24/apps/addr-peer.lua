--[[- addr-peer ? the other host on the segment for addr-selftest.

Config: role=host, iface=...|10.0.1.3/24, gw=10.0.1.1, app=addr-peer
Listens on UDP 9998 (the directed-broadcast port) and answers the sender on 9997.
ICMP echo is answered by the IP layer itself, so nothing else is needed.
Result: ADDR_PEER_BCAST lines + a periodic ADDR_PEER_STATE.
]]
return function(M, node, args)
    local log = fs.open("addr-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local seen = 0

    node:add_task("addr-peer", function()
        node:bind(9998, function(data, src)
            seen = seen + 1
            w("ADDR_PEER_BCAST n=%d from=%s data=%s", seen, M.int2ip(src), tostring(data))
            if data == "who" then M.udp_send(node, src, 9998, 9997, "here") end
        end)
        w("ADDR_PEER_READY port=9998")
        while true do
            os.sleep(5)
            w("ADDR_PEER_STATE seen=%d", seen)
        end
    end)
end
