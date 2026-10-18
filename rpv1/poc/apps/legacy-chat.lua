--[[- apps/legacy-chat.lua — a program written against the STOCK rednet API.

It never mentions rpv: it calls rednet.open / host / lookup / send / receive /
broadcast exactly like a CC:Tweaked program would. Run it on a node whose
role.txt has `shim=1` and it works over the routed rpv network instead of
rednet's flood.

  app=legacy-chat:server:22     (hosts name "host-<own id>", replies once)
  app=legacy-chat:client:23     (looks up the peer name, sends by computer id,
                                 waits for the reply, then broadcasts)
]]
return function(M, node, args)
    local f = fs.open("legacy-log.txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f [%d] " .. fmt, os.clock(), os.getComputerID(), ...))
        f.flush()
    end

    local mode, peer = args:match("^([^:]*):?(%d*)$")
    mode = (mode ~= "" and mode) or "client"
    peer = tonumber(peer)
    w("LEGACY_START mode=%s peer=%s", tostring(mode), tostring(peer))

    rednet.open("back")   -- stock rednet call

    if mode == "server" then
        rednet.host("chat", "host-" .. os.getComputerID())
        w("LEGACY_SERVER_READY hostname=host-%d", os.getComputerID())
        local sender, message, protocol = rednet.receive("chat", 30)
        w("LEGACY_SERVER_GOT sender=%s protocol=%s message=%s", tostring(sender), tostring(protocol), tostring(message))
        if sender then rednet.send(sender, "pong from " .. os.getComputerID(), "chat") end
        w("LEGACY_SERVER_DONE")
    else
        os.sleep(3)
        local target = rednet.lookup("chat", "host-" .. tostring(peer))
        w("LEGACY_LOOKUP name=host-%s -> %s", tostring(peer), tostring(target))
        rednet.send(peer, "hello from " .. os.getComputerID(), "chat")
        w("LEGACY_SENT id=%s", tostring(peer))
        local sender, message, protocol = rednet.receive("chat", 20)
        w("LEGACY_REPLY sender=%s protocol=%s message=%s", tostring(sender), tostring(protocol), tostring(message))
        rednet.broadcast("legacy broadcast from " .. os.getComputerID(), "chat")
        w("LEGACY_BROADCAST_SENT")
        w("LEGACY_RESULT lookup_ok=%s reply_ok=%s", tostring(target ~= nil), tostring(message ~= nil))
        w("TEST_DONE")
    end
end
