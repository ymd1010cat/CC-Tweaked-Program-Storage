--[[- wansec-selftest ? WAN tunnel AEAD acceptance, runs on the near-side host.

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, app=wansec-selftest:10.0.2.2
Sends (across the rednet WAN between two routers):
  * an ICMP echo
  * a UDP datagram carrying the marker RPVSECRET (the sniffer must not be able to read
    it once the tunnel is encrypted)
Writes wansec-log.txt + WANSEC_SELFTEST_RESULT + TEST_DONE.
]]
return function(M, node, args)
    local peer = (args ~= "" and args) or node.cfg.peer or "10.0.2.2"
    local peerIP = M.ip2int(peer)
    local marker = node.cfg.marker or "RPVSECRET"
    local log = fs.open("wansec-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local res = { ping = false, echo = false }

    node.on_echo_reply = function(src, seq, rtt)
        if seq and seq >= 9500 and seq <= 9502 then
            res.ping = true
            w("WANSEC_PING_REPLY from=%s rtt_us=%s", M.int2ip(src), rtt and string.format("%.0f", rtt) or "?")
        end
    end
    node:bind(4600, function(data, src, sport)
        if tostring(data):find(marker, 1, true) then
            res.echo = true
            w("WANSEC_MARKER_ECHO from=%s payload=%q", M.int2ip(src), tostring(data))
        end
    end)

    node:add_task("wansec-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 12)
        -- retry a few times: the first ARP on a wireless emulated LAN is occasionally
        -- lost, which is unrelated to the WAN modem under test
        local waited = 0
        for attempt = 1, 3 do
            M.icmp_echo(node, peerIP, 9500 + attempt - 1, "wansec", 64)
            local inner = 0
            while not res.ping and inner < 4 do os.sleep(0.25); inner = inner + 0.25 end
            waited = waited + inner
            if res.ping then break end
        end
        w("WANSEC_PING ok=%s after=%.2fs", tostring(res.ping), waited)

        waited = 0
        for attempt = 1, 3 do
            M.udp_send(node, peerIP, 4600, 7, marker .. "-payload")
            local inner = 0
            while not res.echo and inner < 4 do os.sleep(0.25); inner = inner + 0.25 end
            waited = waited + inner
            if res.echo then break end
        end
        w("WANSEC_MARKER ok=%s after=%.2fs", tostring(res.echo), waited)

        local ok = res.ping and res.echo
        w("WANSEC_SELFTEST_RESULT ping=%s marker=%s pass=%s", tostring(res.ping), tostring(res.echo), tostring(ok))
        w("TEST_DONE")
    end)
end
