--[[- apps/udp-echo.lua — the UDP echo service the selftest expects on port 7.

Replies with u16(length) || u16(checksum) so the client can verify the payload
end to end.

  app=udp-echo:7
]]
return function(M, node, args)
    local port = tonumber(args) or 7
    local sk = node:bind(port, function(data, src, sport, sock)
        local reply = M.u16(#data) .. M.u16(M.rawsum(data))
        sock:sendto(src, sport, reply)
        node:log("UDPECHO_APP bytes=%d from=%s sport=%d", #data, M.int2ip(src), sport)
    end) -- luacheck: ignore sk
    node:log("UDP_ECHO bound port=%d", port)
end
