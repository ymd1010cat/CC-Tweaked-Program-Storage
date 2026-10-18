--[[- rpv-libtest.lua — library acceptance test, written as an EXTERNAL program.

Installed as `startup.lua` on a plain CC:Tweaked computer. It touches nothing
except the public library API (documented in rpv/API.md) and a config table; if
this passes, the library boundary is real and usable from outside the project.

Checks, in order:
    1. node_new(table) + setup() + interface came up
    2. ARP resolution of the peer (node:resolve + arp cache)
    3. ICMP echo round trip            (rpv.icmp_echo + node.on_echo_reply)
    4. UDP request/response round trip (rpv.udp_send + node:bind)
    5. a 4 KiB transfer over UDP (fragmentation + reassembly, exercised by the lib)
    6. stats/telemetry surfaces exist and moved (node:dump_stats)
Writes lib-log.txt and ends with LIBTEST_RESULT pass=true|false + TEST_DONE.
]]
-- works with either distribution form: the folder layout (rpv.lua + rpv/) or the
-- single-file build (rpv-bundle.lua)
local rpv = (function()
    local ok, mod = pcall(require, "rpv")
    if ok and type(mod) == "table" then return mod end
    for _, path in ipairs({ "rpv-bundle.lua", "/rpv-bundle.lua" }) do
        local ok2, b = pcall(dofile, path)
        if ok2 and type(b) == "table" then return b end
    end
    error("RPV1 not found: install rpv.lua + rpv/, or put rpv-bundle.lua next to this program")
end)()

-- ==== edit these to fit your network =======================================
local MY_CIDR    = "10.0.1.2/24"
local PEER_IP    = "10.0.1.3"
local MY_SIDE    = "left"
-- ==========================================================================
local CHANNEL    = 4400
local ECHO_PORT  = 4100
local MY_PORT    = 4101
local SPAWN_IDS  = ""                 -- emulator-only: extra computer ids to boot
                                      -- (poc/run-lib.ps1 patches this to "21")

local log = fs.open("lib-log.txt", "w")
local function w(fmt, ...)
    log.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
    log.flush()
end

local checks = {}
local function check(name, ok, detail)
    checks[#checks + 1] = { name = name, ok = ok and true or false }
    w("LIBTEST_%s ok=%s %s", name, tostring(ok and true or false), detail or "")
end

-- 1. build a node from a plain table (no role.txt anywhere) ------------------
local node = rpv.node_new({
    role = "host",
    ifaces = { { side = MY_SIDE, name = "LAN", cidr = MY_CIDR, channel = CHANNEL,
                 mtu = 256, linktype = "wireless" },
               { side = "top", name = "DUMMY", cidr = "10.99.0.1/24", channel = 4500,
                 mtu = 128 } },
    spawn = SPAWN_IDS,
})
node:setup()
check("NODE_UP", #node.ifaces == 2, string.format("ifaces=%d mac=%d", #node.ifaces, node.mac))

local peer = rpv.ip2int(PEER_IP)
local path = node:resolve(peer)
check("ROUTE", path ~= nil, path and ("via=" .. (path.iface and path.iface.name or "?")) or "no path")

-- state that the checks below fill in
local got_echo, echo_rtt = false, nil
local got_reply, reply_len = false, 0
local got_big, big_len = false, 0

node.on_echo_reply = function(src, seq, rtt)
    if seq == 1001 then
        got_echo = true
        echo_rtt = rtt
    end
    w("LIBTEST_ECHO_REPLY from=%s seq=%s rtt_us=%s", rpv.int2ip(src), tostring(seq),
        rtt and string.format("%.0f", rtt) or "?")
end

node:bind(MY_PORT, function(data, src, sport)
    -- the peer echoes back with an "echo:" prefix, so accept both forms
    if data:sub(1, 6) == "big:" or data:sub(1, 9) == "echo:big:" then
        got_big = true
        big_len = #data
    else
        got_reply = true
        reply_len = #data
    end
    w("LIBTEST_UDP_RX from=%s bytes=%d", rpv.int2ip(src), #data)
end)

node:add_task("libtest", function()
    os.sleep(3)                                    -- let the modem settle

    -- 2. ARP: resolve the peer, then look at the public ARP cache
    local resolved = false
    rpv.arp_resolve(node, node.ifaces[1], peer, function(ip, mac)
        resolved = true
        w("LIBTEST_ARP_RESOLVED ip=%s mac=%d", rpv.int2ip(ip), mac)
    end)
    local waited = 0
    while not resolved and waited < 5 do
        os.sleep(0.2)
        waited = waited + 0.2
    end
    check("ARP", resolved, string.format("after=%.1fs", waited))

    -- 3. ICMP echo through the library
    rpv.icmp_echo(node, peer, 1001, "libtest", 64)
    waited = 0
    while not got_echo and waited < 5 do
        os.sleep(0.2)
        waited = waited + 0.2
    end
    check("PING", got_echo, echo_rtt and string.format("rtt_us=%.0f", echo_rtt) or "timeout")

    -- 4. UDP request/response
    rpv.udp_send(node, peer, MY_PORT, ECHO_PORT, "hello-lib")
    waited = 0
    while not got_reply and waited < 5 do
        os.sleep(0.2)
        waited = waited + 0.2
    end
    check("UDP", got_reply, string.format("reply_bytes=%d", reply_len))

    -- 5. fragmentation + reassembly: 4 KiB through a 256-byte MTU path
    rpv.udp_send(node, peer, MY_PORT, ECHO_PORT, "big:" .. string.rep("B", 4000))
    waited = 0
    while not got_big and waited < 12 do
        os.sleep(0.2)
        waited = waited + 0.2
    end
    check("FRAG_REASM", got_big, string.format("bytes=%d after=%.1fs", big_len, waited))

    -- 6. telemetry surface
    node:dump_stats()
    local s = node.stats
    check("STATS", s.frames_rx > 0 and s.ip_rx > 0,
        string.format("frames_rx=%d ip_rx=%d", s.frames_rx, s.ip_rx))

    local failed = {}
    for _, c in ipairs(checks) do
        if not c.ok then failed[#failed + 1] = c.name end
    end
    w("LIBTEST_RESULT checks=%d failed=%d pass=%s", #checks, #failed,
        tostring(#failed == 0))
    w("TEST_DONE")
end)

node:run()
