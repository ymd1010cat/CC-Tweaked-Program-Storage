--[[- svc-selftest ? DHCP-lite + lookup-lite acceptance (a pure client).

Config (role.txt):
    role=host
    iface=back|LAN-A|10.254.0.22/16|4001|256|wired   <- placeholder address
    dhcp=1                    <- ask the DHCP server for a real one
    name=client22             <- register this name with the name server
    dns_server=10.0.1.1
    app=svc-selftest:host23   <- resolve this name, then ping it
    start_delay=2

Flow: wait for the lease -> adopt address/gateway -> register our name ->
resolve the peer name -> ICMP echo it. Writes svc-log.txt and ends with
SVC_RESULT pass=true|false + TEST_DONE.
]]
return function(M, node, args)
    local peerName = (args ~= "" and args) or node.cfg.peer_name or "host23"
    local startDelay = tonumber(node.cfg.start_delay) or 2
    local log = fs.open("svc-log.txt", "w")
    local function w(fmt, ...)
        log.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
        log.flush()
    end
    local res = { bound = false, lookup = nil, ping = false, name_registered = false }

    node.on_echo_reply = function(src, seq, rtt)
        if seq and seq >= 7001 and seq <= 7004 then
            res.ping = true
            w("SVC_PING_REPLY from=%s rtt_us=%s", M.int2ip(src), rtt and string.format("%.0f", rtt) or "?")
        end
    end

    node:add_task("svc-selftest", function()
        os.sleep(startDelay)
        w("SVC_START peer_name=%s placeholder=%s gw=%s", peerName, node.ifaces[1].cidr, tostring(node.cfg.gw))

        -- 1. the DHCP client task (started by services_setup) must bind
        local waited = 0
        while waited < tonumber(node.cfg.dhcp_timeout or 20)
            and not (node.dhcp_client and node.dhcp_client.state == "BOUND") do
            os.sleep(0.5)
            waited = waited + 0.5
        end
        local cli = node.dhcp_client
        if cli and cli.state == "BOUND" then
            res.bound = true
            w("SVC_BOUND ip=%s/%d gw=%s dns=%s after=%.1fs", M.int2ip(cli.bound.ip), cli.bound.prefix,
                M.int2ip(cli.bound.gw), M.int2ip(cli.bound.dns), waited)
        else
            w("SVC_BOUND_FAILED state=%s after=%.1fs", cli and cli.state or "none", waited)
        end

        -- 2. register our name with the name server (after the address is real)
        if res.bound then
            res.name_registered = node:dns_register(node.cfg.name) and true or false
            os.sleep(1)
        end

        -- 3. resolve the peer name through lookup-lite (retry: the first exchange on an
        --    emulated LAN is occasionally lost, which is unrelated to the services)
        local ip = nil
        for attempt = 1, 4 do
            ip = node:lookup(peerName, 4)
            if ip then break end
            w("SVC_LOOKUP_RETRY try=%d", attempt)
            os.sleep(1)
        end
        if ip then
            res.lookup = ip
            w("SVC_LOOKUP name=%s ip=%s ok=true", peerName, M.int2ip(ip))
        else
            w("SVC_LOOKUP name=%s ok=false", peerName)
        end

        -- 4. prove the adopted address + gateway actually route (retry for the same reason)
        if ip then
            waited = 0
            for attempt = 1, 4 do
                M.icmp_echo(node, ip, 7000 + attempt, "svc", 64)
                local inner = 0
                while not res.ping and inner < 4 do
                    os.sleep(0.25)
                    inner = inner + 0.25
                end
                waited = waited + inner
                if res.ping then break end
                w("SVC_PING_RETRY try=%d", attempt)
            end
            w("SVC_PING ok=%s after=%.2fs", tostring(res.ping), waited)
        end

        local ok = res.bound and res.lookup ~= nil and res.ping
        w("SVC_RESULT bound=%s registered=%s lookup=%s ping=%s pass=%s", tostring(res.bound),
            tostring(res.name_registered), res.lookup and M.int2ip(res.lookup) or "none",
            tostring(res.ping), tostring(ok))
        -- keep the node alive for a while so the DHCP client reaches its T1 renewal
        -- (dhcp_t1=4 in this scenario): the lease lifecycle then shows up in the log
        local hold = tonumber(node.cfg.svc_hold) or 0
        if hold > 0 then
            w("SVC_HOLD seconds=%.0f (watching the DHCP renewal)", hold)
            os.sleep(hold)
            w("SVC_HOLD_DONE renews=%s", tostring(node.dhcp_client and node.dhcp_client.renews or 0))
        end
        w("TEST_DONE")
    end)
end
