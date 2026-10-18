--[[- hotreload-selftest — config hot reload acceptance (runs on the near host).

Config: role=host, iface=...|10.0.1.2/24, gw=10.0.1.1, app=hotreload-selftest:10.0.3.2
The harness rewrites the ROUTER's routes.txt / role.txt / hosts.txt while everything is
running. This app checks the two halves:

  t=5s   ping the far destination  -> must FAIL (no route yet)
  t=10s  lookup "printer"          -> must FAIL (no hosts.txt entry yet)
  t=16s  ping again                -> must SUCCEED (route reloaded)
         lookup again              -> must SUCCEED (hosts.txt reloaded)

Result: HR_RESULT before_blocked=.. after_ok=.. lookup_after=.. pass=.. + TEST_DONE.
]]
return function(M, node, args)
    local far = M.ip2int((args ~= "" and args) or node.cfg.far or "10.0.3.2")
    local log = fs.open("hr-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end
    local res = { ping1 = false, ping2 = false, look1 = nil, look2 = nil }
    local seqSeen = {}

    node.on_echo_reply = function(src, seq)
        if seq == 8101 then res.ping1 = true end
        if seq == 8102 then res.ping2 = true end
    end

    local function ping(seq, tag)
        M.icmp_echo(node, far, seq, "hr", 64)
        local waited = 0
        local ok = false
        while waited < 4 do
            os.sleep(0.25)
            waited = waited + 0.25
            ok = (seq == 8101 and res.ping1) or (seq == 8102 and res.ping2)
            if ok then break end
        end
        w("HR_PING %s seq=%d ok=%s after=%.2fs", tag, seq, tostring(ok), waited)
        return ok
    end

    node:add_task("hotreload-selftest", function()
        os.sleep(tonumber(node.cfg.start_delay) or 5)
        w("HR_START far=%s", M.int2ip(far))

        local p1 = ping(8101, "before")
        w("HR_BEFORE ping_ok=%s (route must not exist yet)", tostring(p1))

        -- this must run BEFORE the harness rewrites the files (it does, right here), and
        -- lookup reads node.hosts once at entry, so a reload mid-query does not help it
        res.look1 = node:lookup("printer", 2)
        w("HR_LOOKUP_BEFORE ok=%s", tostring(res.look1 ~= nil))

        os.sleep(8)                                  -- the harness rewrites the config here
        w("HR_WAIT_DONE (config should have been reloaded by now)")

        local p2 = ping(8102, "after")
        w("HR_AFTER ping_ok=%s", tostring(p2))
        res.look2 = node:lookup("printer", 3)
        w("HR_LOOKUP_AFTER ok=%s ip=%s", tostring(res.look2 ~= nil),
            res.look2 and M.int2ip(res.look2) or "none")

        local ok = (not p1) and p2 and (res.look1 == nil) and (res.look2 ~= nil)
        w("HR_RESULT before_blocked=%s after_ok=%s lookup_after=%s pass=%s",
            tostring(not p1), tostring(p2), tostring(res.look2 ~= nil), tostring(ok))
        w("TEST_DONE")
    end)
end
