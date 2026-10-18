--[[- apps/socket-echo.lua — a third-party-style program using only the public
socket API (no access to the protocol internals).

  app=socket-echo:9000
]]
return function(M, node, args)
    local port = tonumber(args) or 9000
    local sk = node:bind(port, function(data, src, sport, sock)
        node:log("ECHO_APP recv bytes=%d from=%s sport=%d", #data, M.int2ip(src), sport)
        sock:sendto(src, sport, "echo:" .. data)
    end)
    node:log("SOCKET_ECHO bound port=%d", port)
end
