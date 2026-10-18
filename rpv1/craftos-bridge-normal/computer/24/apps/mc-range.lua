--[[- apps/mc-range.lua — wireless modem range probe (real Minecraft).

Both computers open one raw channel; each sends a frame every second and logs
what it hears, including the distance reported by modem_message. The harness
runs this at several distances to find the real range boundary.

  role.txt:  app=mc-range
]]
return function(M, node, args)
    local iface = node.ifaces[1]
    local CH = 6300
    local f = fs.open("mc-range.txt", "w")
    local function w(fmt, ...)
        f.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        f.flush()
    end

    w("RANGE_TEST id=%d side=%s wireless=%s", node.id, iface.side, tostring(iface.wireless))
    peripheral.call(iface.side, "open", CH)
    local rx, maxdist = 0, nil

    node:add_task("range-rx", function()
        while true do
            local ev, side, chan, reply, msg, dist = os.pullEvent("modem_message")
            if chan == CH and type(msg) == "string" then
                rx = rx + 1
                if dist and (not maxdist or dist > maxdist) then maxdist = dist end
                w("RANGE_RX from=%d bytes=%d distance=%s", msg:match("id=(%d+)") or -1, #msg, tostring(dist))
            end
        end
    end)

    node:add_task("range-tx", function()
        for i = 1, 12 do
            peripheral.call(iface.side, "transmit", CH, CH, "hello id=" .. node.id .. " n=" .. i)
            os.sleep(1)
        end
        w("RANGE_TX_DONE")
    end)

    node:add_task("range-finish", function()
        os.sleep(14)
        w("RANGE_RESULT id=%d frames=%d max_distance=%s", node.id, rx, tostring(maxdist))
        w("RANGE_DONE")
        w("TEST_DONE")
    end)
end
