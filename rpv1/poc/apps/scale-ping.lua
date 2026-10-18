--[[- scale-ping — host-side probe for the large-scale runs.

Config: role=host, iface=<side>|<name>|<cidr>|<ch>|512|wireless, gw=..., app=scale-ping,
        peers=<ip,ip,...>, rounds=<n>, interval=<sec>, start_delay=<sec>

Pings every peer round-robin, records which peers answered, and measures how late a 1 s
timer actually fires (that drift is the honest "is the emulator keeping up" number).
Result: SCALE_RESULT peers= ok= pct= rounds= pass= + SCALE_LAG avg_ms= max_ms= + TEST_DONE.
]]
return function(M, node, args)
    local list = {}
    for ip in tostring(node.cfg.peers or ""):gmatch("[^,]+") do
        ip = ip:match("^%s*(.-)%s*$")
        if ip ~= "" then list[#list + 1] = ip end
    end
    local rounds = tonumber(node.cfg.rounds) or 6
    local interval = tonumber(node.cfg.interval) or 3
    local log = fs.open("scale-log.txt", "w")
    local function w(fmt, ...)
        local line = string.format("%.3f " .. fmt, os.clock(), ...)
        log.writeLine(line)
        log.flush()
        if node.log then node:log("%s", line) end
    end

    local SEQ_BASE = 12000
    local got = {}
    node.on_echo_reply = function(src, seq)
        if seq and seq >= SEQ_BASE and #list > 0 then
            got[((seq - SEQ_BASE) % #list) + 1] = true
        end
    end

    node:add_task("scale-ping", function()
        os.sleep(tonumber(node.cfg.start_delay) or 20)
        w("SCALE_START peers=%d rounds=%d", #list, rounds)
        if #list == 0 then
            w("SCALE_RESULT peers=0 ok=0 pct=0 rounds=0 pass=false")
            w("TEST_DONE")
            return
        end

        local lagSum, lagMax, lagN = 0, 0, 0
        for r = 0, rounds - 1 do
            for i = 1, #list do
                M.icmp_echo(node, M.ip2int(list[i]), SEQ_BASE + i + r * #list)
                local before = os.clock()
                os.sleep(1)
                local drift = (os.clock() - before - 1) * 1000
                if drift < 0 then drift = 0 end
                lagSum, lagN = lagSum + drift, lagN + 1
                if drift > lagMax then lagMax = drift end
            end
        end
        os.sleep(interval)

        local ok = 0
        for i = 1, #list do if got[i] then ok = ok + 1 end end
        local pct = ok / #list * 100
        w("SCALE_LAG avg_ms=%.0f max_ms=%.0f samples=%d", lagN > 0 and lagSum / lagN or 0, lagMax, lagN)
        w("SCALE_RESULT peers=%d ok=%d pct=%.0f rounds=%d pass=%s",
            #list, ok, pct, rounds, tostring(ok >= math.ceil(#list * 0.5)))
        w("TEST_DONE")
    end)
end
