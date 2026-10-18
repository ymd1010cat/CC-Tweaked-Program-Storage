--[[- wansec-peer — far-side host for the WAN AEAD acceptance.

Config: role=host, iface=...|10.0.2.2/24, gw=10.0.2.1, app=wansec-peer
Echoes UDP 7 and logs the marker it received (proof that the tunnel still carries
real traffic when the AEAD is on).
Writes wansec-peer-log.txt + WANSEC_PEER_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local marker = node.cfg.marker or "RPVSECRET"
    local log = fs.open("wansec-peer-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local res = { markers = 0 }

    node:bind(7, function(data, src, sport)
        local text = tostring(data)
        if text:find(marker, 1, true) then
            res.markers = res.markers + 1
            w("WANSEC_MARKER_RECV from=%s payload=%q", M.int2ip(src), text)
        end
        M.udp_send(node, src, 7, sport, "echo:" .. text)
    end)

    node:add_task("wansec-peer", function()
        local waited = 0
        while res.markers == 0 and waited < 60 do os.sleep(0.5); waited = waited + 0.5 end
        w("WANSEC_PEER_RESULT markers=%d after=%.1fs", res.markers, waited)
        w("TEST_DONE")
    end)
end
