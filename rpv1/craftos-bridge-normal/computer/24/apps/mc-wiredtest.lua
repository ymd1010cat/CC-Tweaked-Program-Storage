--[[- mc-wiredtest — minimal raw wired-modem diagnostic.

Reports the modem's network membership (getNamesRemote) and does a raw
send/receive on one channel, so we can tell "no network" from "no messages".

  role.txt:  app=mc-wiredtest
]]
return function(M, node, args)
    local iface = node.ifaces[1]
    local f = fs.open("mc-wired.txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        f.flush()
    end

    w("WIRED_TEST id=%d side=%s type=%s wireless=%s", node.id, iface.side,
        tostring(peripheral.getType(iface.side)), tostring(iface.wireless))
    local ok, names = pcall(peripheral.call, iface.side, "getNamesRemote")
    w("REMOTE ok=%s names=%s", tostring(ok), textutils.serialize(names))
    local ok2, isw = pcall(peripheral.call, iface.side, "isWireless")
    w("IS_WIRELESS ok=%s value=%s", tostring(ok2), tostring(isw))
    local ok3, modem = pcall(peripheral.wrap, iface.side)
    if ok3 and modem then
        local ok4, names2 = pcall(function() return modem.getNamesRemote() end)
        w("WRAP_REMOTE ok=%s names=%s", tostring(ok4), textutils.serialize(names2))
    end

    peripheral.call(iface.side, "open", 6200)
    w("CHANNEL_6200_OPEN")

    node:add_task("wtx", function()
        for i = 1, 10 do
            peripheral.call(iface.side, "transmit", 6200, 6200, "hello-" .. node.id .. "-" .. i)
            w("TX i=%d", i)
            os.sleep(1)
        end
    end)

    node:add_task("wrx", function()
        while true do
            local ev, side, chan, reply, msg, dist = os.pullEvent("modem_message")
            w("GOT side=%s chan=%s reply=%s bytes=%s msg=%s", tostring(side), tostring(chan),
                tostring(reply), tostring(type(msg) == "string" and #msg or "?"), tostring(msg))
        end
    end)

    node:add_task("wfinish", function()
        os.sleep(15)
        w("WIRED_DONE")
        w("TEST_DONE")
    end)
end
