--[[- apps/rpv-selftest.lua — the acceptance client used by the LAN / cluster /
WAN harnesses (public API only). Mirrors the old monolithic test:

  * 3 ICMP echoes                       -> expect_pings (default 4 incl. ttl=2)
  * ttl=2 probe (seq 98)                -> survives only if the path is ONE hop
  * ttl=1 probe (seq 99)                -> must be dropped with ICMP time-exceeded
  * large UDP datagram to port 7        -> echoed back with length+checksum
  * optional legacy_remote (WAN device) -> "legacy-echo:..." reply

  app=rpv-selftest:10.0.2.2
Config: start_delay, large_bytes, expect_pings, expect_ttl2, expect_ttl_exceeded,
        legacy_remote
]]
return function(M, node, args)
    local target = (args ~= "" and args) or (node.cfg.remote or "10.0.2.2")
    local remote = M.ip2int(target)
    local start = tonumber(node.cfg.start_delay) or 3
    local large_bytes = tonumber(node.cfg.large_bytes) or 900
    local expect_pings = tonumber(node.cfg.expect_pings) or 4
    local expect_ttl2 = (tonumber(node.cfg.expect_ttl2) or 1) == 1
    local expect_ttl_ex = tonumber(node.cfg.expect_ttl_exceeded) or 1

    local res = { pings = 0, ttl_exceeded = 0, ttl2_ok = false, large_ok = nil, legacy_ok = nil }

    node.on_echo_reply = function(src, seq, rtt)
        if seq == 97 then
            res.ttl_custom_ok = true
            res.pings = res.pings + 1
            node:log("SELFTEST_TTL_CUSTOM_REPLY ttl=%s rtt_us=%s", tostring(node.cfg.probe_ttl), rtt and string.format("%.0f", rtt) or "?")
        elseif seq == 98 then
            res.ttl2_ok = true
            res.pings = res.pings + 1
            node:log("SELFTEST_TTL2_REPLY rtt_us=%s", rtt and string.format("%.0f", rtt) or "?")
        elseif seq >= 1 and seq <= 3 then
            res.pings = res.pings + 1
            node:log("SELFTEST_PING_REPLY seq=%d rtt_us=%s", seq, rtt and string.format("%.0f", rtt) or "?")
        end
    end
    node.on_icmp_error = function(src, itype, code, inner, qseq, mtu)
        if itype == 11 then
            res.ttl_exceeded = res.ttl_exceeded + 1
            node:log("SELFTEST_TTL_EXCEEDED from=%s", M.int2ip(src))
        elseif itype == 3 and code == 4 then
            res.pmtu_mtu = mtu
            node:log("SELFTEST_FRAG_NEEDED from=%s mtu=%s", M.int2ip(src), tostring(mtu))
            if not res.pmtu_retry then
                res.pmtu_retry = true
                local bytes = tonumber(node.cfg.pmtu_retry_bytes) or 100
                node:after(0.3, function()
                    node:log("SELFTEST_PMTU_RETRY bytes=%d df=1", bytes)
                    M.udp_send(node, remote, 40002, 7, M.rep("R", bytes), 64, nil, true)
                end)
            end
        end
    end

    -- large-datagram echo reply (port 7 service) and legacy-device reply
    local sk = node:bind(40000, function(data, src, sport)
        if #data >= 4 then
            local got_len, got_sum = M.r16(data, 1), M.r16(data, 3)
            res.large_ok = (got_len == node.large_len and got_sum == node.large_sum)
            node:log("SELFTEST_LARGE_REPLY from=%s sport=%d bytes=%d ok=%s", M.int2ip(src), sport, got_len, tostring(res.large_ok))
        else
            res.large_ok = false
            node:log("SELFTEST_LARGE_REPLY_SHORT from=%s bytes=%d", M.int2ip(src), #data)
        end
    end) -- luacheck: ignore sk

    local sk2 = node:bind(40001, function(data, src, sport)
        res.legacy_ok = data:sub(1, 12) == "legacy-echo:"
        node:log("SELFTEST_LEGACY_REPLY from=%s sport=%d data=%s", M.int2ip(src), sport, data)
    end) -- luacheck: ignore sk2

    -- reply to the post-frag-needed retry (DF=1, small enough for the path MTU)
    local sk3 = node:bind(40002, function(data, src, sport)
        local want = tonumber(node.cfg.pmtu_retry_bytes) or 100
        if #data >= 4 and M.r16(data, 1) == want then res.pmtu_ok = true end
        node:log("SELFTEST_PMTU_REPLY from=%s bytes=%d ok=%s", M.int2ip(src), #data, tostring(res.pmtu_ok))
    end) -- luacheck: ignore sk3

    node:after(start, function()
        node:log("SELFTEST_START remote=%s", M.int2ip(remote))
        for seq = 1, 3 do
            node.ping_sent[seq] = os.clock()
            M.icmp_echo(node, remote, seq, M.rep("P", 32), 64)
        end
        node:log("SELFTEST_PINGS_SENT n=3")
    end)

    node:after(start + 1.0, function()
        local app = M.rep("D", large_bytes)
        node.large_len, node.large_sum = #app, M.rawsum(app)
        node:log("SELFTEST_LARGE_SEND bytes=%d sum=%d", node.large_len, node.large_sum)
        M.udp_send(node, remote, 40000, 7, app, 64)
    end)

    node:after(start + 2.0, function()
        node.ping_sent[98] = os.clock()
        M.icmp_echo(node, remote, 98, M.rep("T", 8), 2)
        node:log("SELFTEST_TTL2_SENT ttl=2")
    end)

    node:after(start + 2.5, function()
        node.ping_sent[99] = os.clock()
        M.icmp_echo(node, remote, 99, M.rep("T", 8), 1)
        node:log("SELFTEST_TTL1_SENT ttl=1")
    end)

    -- optional extra probe with a caller-chosen TTL (multi-router paths)
    if node.cfg.probe_ttl then
        node:after(start + 3.2, function()
            node.ping_sent[97] = os.clock()
            M.icmp_echo(node, remote, 97, M.rep("T", 8), tonumber(node.cfg.probe_ttl))
            node:log("SELFTEST_TTL_CUSTOM_SENT ttl=%s", tostring(node.cfg.probe_ttl))
        end)
    end

    if node.cfg.legacy_remote then
        node:after(start + 3.0, function()
            node:log("SELFTEST_LEGACY_SEND to=%s dport=7 (WAN translation)", node.cfg.legacy_remote)
            M.udp_send(node, M.ip2int(node.cfg.legacy_remote), 40001, 7, "hello-legacy-peer", 64)
        end)
    end

    -- PMTU probe: a big datagram with DF=1 must come back as ICMP frag-needed
    if node.cfg.df_probe == "1" then
        local probe = tonumber(node.cfg.df_probe_bytes) or large_bytes
        node:after(start + 1.5, function()
            node:log("SELFTEST_DF_PROBE bytes=%d df=1", probe)
            M.udp_send(node, remote, 40003, 7, M.rep("Q", probe), 64, nil, true)
        end)
    end

    node:after(start + 4.0, function()
        local deadline = os.clock() + 20
        local function check()
            local legacy_ok = (not node.cfg.legacy_remote) or (res.legacy_ok == true)
            local pmtu_ok = (node.cfg.df_probe ~= "1") or (res.pmtu_ok == true)
            local ttl_custom_ok = (not node.cfg.probe_ttl) or (res.ttl_custom_ok == true)
            local complete = res.pings >= expect_pings
                and (not expect_ttl2 or res.ttl2_ok)
                and res.ttl_exceeded >= expect_ttl_ex
                and res.large_ok ~= nil
                and legacy_ok and pmtu_ok and ttl_custom_ok
            if complete or os.clock() > deadline then
                node:log("RESULTS pings_replied=%d ttl2_ok=%s ttl_custom_ok=%s large_reply_bytes=%s large_reply_ok=%s ttl_exceeded=%d legacy_reply_ok=%s pmtu_mtu=%s pmtu_ok=%s complete=%s",
                    res.pings, tostring(res.ttl2_ok), tostring(res.ttl_custom_ok), tostring(node.large_len), tostring(res.large_ok),
                    res.ttl_exceeded, tostring(res.legacy_ok), tostring(res.pmtu_mtu), tostring(res.pmtu_ok), tostring(complete))
                node:log("TEST_DONE")
            else
                node:after(0.5, check)
            end
        end
        node:after(0.1, check)
    end)
end
