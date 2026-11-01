--[[- tests/t_dad.lua ? duplicate address detection + optional header checksum.

dad.lua is a pure state machine, so almost everything here drives it with an
injected clock and a captured transmit path. The last two groups check the two
places where the library has to be wired: the ip_parse checksum switch and the
node hooks (static source assertions, because a full node needs modems).
]]
local T, M = ...
local int2ip = M.int2ip

-- ===== harness ==============================================================
local original_link_send = M.link_send
local tx = {}

local function capture_tx()
    tx = {}
    M.link_send = function(node, iface, dst, etype, body)
        tx[#tx + 1] = { dst = dst, etype = etype, body = body, iface = iface and iface.name }
        return #body
    end
end

local clock = { t = 0 }
local function now(node) return clock.t end

local function iface(name, cidr, extra)
    local ipstr, prefix = cidr:match("^([%d%.]+)/(%d+)$")
    local i = {
        name = name, side = name, cidr = cidr, channel = 1, mtu = 256,
        ip = M.ip2int(ipstr), prefix = tonumber(prefix),
    }
    i.net = M.masked(i.ip, i.prefix)
    if extra then
        for k, v in pairs(extra) do i[k] = v end
    end
    return i
end

local function new_node(opts)
    local o = opts or {}
    local n = {
        id = o.id or 21, mac = o.id or 21, role = o.role or "host",
        cfg = o.cfg or {}, ifaces = o.ifaces or {}, stats = {}, lines = {},
        dad = M.dad_new(o.dad), arp = M.arp_new(), dad_now = now,
    }
    function n:log(fmt, ...)
        local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        self.lines[#self.lines + 1] = line
        return line
    end
    function n:has(fragment)
        for _, line in ipairs(self.lines) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end
    function n:last()
        return self.lines[#self.lines] or ""
    end
    return n
end

local function claim_body(op, mac, sip, tip)
    return M.u16(op) .. M.u32(mac) .. M.u32(sip) .. M.u32(M.MAC_BCAST) .. M.u32(tip)
end

local ok, err = pcall(function()
    capture_tx()
    local lan = iface("lan", "10.0.1.2/24")

    -- ===== constructor =====================================================
    local d = M.dad_new()
    T.eq(d.enabled, true, "dad_new: enabled by default")
    T.eq(d.policy, "detect", "dad_new: detect by default")
    T.eq(d.probes, 3, "dad_new: 3 probes by default")
    T.eq(d.interval, 0.5, "dad_new: 0.5 s probe interval")
    T.eq(#d.queue, 0, "dad_new: empty queue")
    T.eq(d.conflicts, 0, "dad_new: no conflicts yet")
    T.eq(M.dad_new({ enabled = false }).enabled, false, "dad_new: enabled=false honoured")
    T.eq(M.dad_new({ policy = "yield" }).policy, "yield", "dad_new: policy=yield honoured")
    T.eq(M.dad_new({ policy = "bogus" }).policy, "detect", "dad_new: unknown policy falls back to detect")
    T.eq(M.dad_new({ probes = 0 }).probes, 1, "dad_new: probes clamp to >= 1")
    T.eq(M.dad_new({ probes = 99 }).probes, 10, "dad_new: probes clamp to <= 10")
    T.eq(M.dad_new({ interval = 0.01 }).interval, 0.1, "dad_new: interval floor is 0.1 s")

    -- ===== frame bodies ====================================================
    local n = new_node({ ifaces = { lan } })
    local probe = M.dad_probe_body(n, lan)
    T.eq(#probe, 18, "probe body is 18 bytes")
    T.eq(M.r16(probe, 1), 1, "probe is an ARP request")
    T.eq(M.r32(probe, 3), 21, "probe sender MAC is ours")
    T.eq(M.r32(probe, 7), 0, "probe sender address is 0.0.0.0 (RFC 5227)")
    T.eq(M.r32(probe, 15), lan.ip, "probe target address is the address under test")
    local ann = M.dad_announce_body(n, lan)
    T.eq(#ann, 18, "announce body is 18 bytes")
    T.eq(M.r16(ann, 1), 2, "announce is an ARP reply")
    T.eq(M.r32(ann, 7), lan.ip, "announce sender address is ours")
    T.eq(M.r32(ann, 15), lan.ip, "announce target address is ours (gratuitous)")
    T.eq(M.r32(ann, 11), M.MAC_BCAST, "announce target MAC is the broadcast")

    -- a probe must not poison the ARP cache with a 0.0.0.0 entry
    n.arp.cache = {}
    M.arp_input(n, lan, probe)
    T.eq(n.arp.cache[0], nil, "ARP probe does not create a 0.0.0.0 cache entry")
    local reply_body = claim_body(2, 77, M.ip2int("10.0.1.9"), n.mac)
    M.arp_input(n, lan, reply_body)
    T.ok(n.arp.cache[M.ip2int("10.0.1.9")] ~= nil, "a real ARP sender still fills the cache")

    -- ===== scheduling ======================================================
    clock.t = 100
    capture_tx()
    local wan = iface("wan", "10.200.0.1/24", { is_wan = true })
    local lan2 = iface("lan2", "10.0.2.2/24", { channel = 2 })
    local yielded = iface("lan3", "10.0.3.2/24", { channel = 3, conflicted = { ip = 1 } })
    n = new_node({ ifaces = { lan, wan, lan2, yielded }, dad = { probes = 3, interval = 0.5 } })
    T.eq(M.dad_start(n), 8, "dad_start queues 3 probes + 1 announce per real interface")
    T.ok(n:has("DAD_START queued=8 probes=3 interval=0.50 policy=detect"), "DAD_START is logged")
    T.eq(#M.dad_status(n).peers, 0, "dad_status starts with no peers")

    local sent = M.dad_tick(n)
    T.eq(sent, 2, "at t0 one probe goes out per interface (2 interfaces)")
    T.eq(#tx, 2, "two probe frames were transmitted")
    T.eq(M.r16(tx[1].body, 1), 1, "the first frame is a probe")
    T.eq(tx[1].dst, M.MAC_BCAST, "probes go to the broadcast MAC")
    T.eq(tx[1].etype, M.ET_ARP, "probes use the ARP ethertype")
    T.eq(M.dad_tick(n), 0, "nothing else is due at t0")
    clock.t = 100.4
    T.eq(M.dad_tick(n), 0, "no probe before the interval elapsed")
    clock.t = 100.5
    T.eq(M.dad_tick(n), 2, "second probe burst at t0+0.5")
    clock.t = 101.0
    T.eq(M.dad_tick(n), 2, "third probe burst at t0+1.0")
    clock.t = 101.5
    T.eq(M.dad_tick(n), 2, "one announce per interface at t0+1.5")
    T.eq(M.r16(tx[#tx].body, 1), 2, "the announce is an ARP reply")
    T.eq(M.dad_status(n).probes, 6, "six probes were sent in total")
    T.eq(M.dad_status(n).announced, 2, "two announces were sent in total")
    T.eq(M.dad_tick(n), 0, "the queue is empty afterwards")

    local off = new_node({ ifaces = { lan }, dad = { enabled = false } })
    T.eq(M.dad_start(off), 0, "dad_start is a no-op when disabled")
    T.eq(M.dad_tick(off), 0, "dad_tick is a no-op when disabled")

    -- ===== input filtering =================================================
    n = new_node({ ifaces = { lan }, id = 21 })
    local our_ip = lan.ip
    T.eq(M.dad_input(n, lan, M.dad_probe_body(n, lan)), nil, "our own probe claims nothing")
    T.eq(M.dad_input(n, lan, claim_body(2, 5, 0, our_ip)), nil, "a sender address of 0.0.0.0 is not a claim")
    T.eq(M.dad_input(n, lan, claim_body(2, 21, our_ip, our_ip)), nil, "our own MAC is not a foreign claim")
    T.eq(M.dad_input(n, lan, claim_body(2, 5, M.ip2int("10.0.9.9"), our_ip)), nil, "a foreign address is not our business")
    T.eq(M.dad_input(n, lan, claim_body(3, 5, our_ip, our_ip)), nil, "only ARP op 1/2 counts as a claim")
    T.eq(M.dad_input(n, lan, "short"), nil, "a runt ARP body is ignored")
    T.eq(n.stats.dad_conflicts, nil, "no conflict was counted")

    -- ===== conflict handling ===============================================
    local res = M.dad_input(n, lan, claim_body(2, 5, our_ip, our_ip))
    T.eq(res, "conflict", "a foreign claim on our address is a conflict")
    T.eq(n.stats.dad_conflicts, 1, "the conflict counter went up")
    T.eq(n.dad.conflicts, 1, "the dad counter went up")
    T.ok(n:has("DAD_CONFLICT addr=10.0.1.2 claimer=5 on=lan op=2 count=1 winner=them"),
        "DAD_CONFLICT names the address, the claimer and the winner")
    T.eq(n.dad.defended, 1, "the first claim triggers one defensive announce")
    T.ok(n:has("DAD_DEFEND addr=10.0.1.2 claimer=5"), "DAD_DEFEND is logged")
    T.ok(lan.conflicted == nil, "detect policy does not yield the address")
    local before = #tx
    M.dad_input(n, lan, claim_body(1, 5, our_ip, our_ip))
    T.eq(n.dad.conflicts, 2, "a repeated claim is counted again")
    T.ok(n:has("count=2 winner=them"), "the repeat is logged with a running count")
    T.eq(#tx, before, "a repeated claim does not announce again (no ping-pong)")

    local peer_wins = M.dad_claim_wins(21, 5)
    T.eq(peer_wins, false, "the lower computer id wins: 5 beats 21")
    T.eq(M.dad_claim_wins(5, 21), true, "the lower computer id wins: 5 keeps the address")
    T.eq(M.dad_claim_wins(21, 21), false, "identical ids cannot resolve to a win")
    local n2 = new_node({ ifaces = { iface("lan", "10.0.1.2/24") }, id = 5 })
    M.dad_input(n2, n2.ifaces[1], claim_body(2, 21, n2.ifaces[1].ip, n2.ifaces[1].ip))
    T.ok(n2:has("winner=us"), "the lower id logs winner=us")

    -- ===== yield policy ====================================================
    local loser = new_node({ ifaces = { iface("lan", "10.0.1.2/24") }, id = 21, dad = { policy = "yield" } })
    local lif = loser.ifaces[1]
    T.eq(M.dad_input(loser, lif, claim_body(2, 5, lif.ip, lif.ip)), "yield", "yield policy reports the yield")
    T.ok(lif.conflicted ~= nil, "the interface is marked conflicted")
    T.eq(lif.conflicted.peer, 5, "the winner is recorded on the interface")
    T.eq(loser.stats.dad_yielded, 1, "the yield counter went up")
    T.ok(loser:has("DAD_ADDRESS_YIELD addr=10.0.1.2 winner=5 loser=21 on=lan"), "DAD_ADDRESS_YIELD is logged")

    local winner = new_node({ ifaces = { iface("lan", "10.0.1.2/24") }, id = 5, dad = { policy = "yield" } })
    M.dad_input(winner, winner.ifaces[1], claim_body(2, 21, winner.ifaces[1].ip, winner.ifaces[1].ip))
    T.ok(winner.ifaces[1].conflicted == nil, "the winner under yield policy keeps the address")

    -- a yielded interface is not probed again and must not source traffic
    T.eq(M.dad_start(loser), 0, "a yielded interface is not probed again")

    -- ===== peer cap ========================================================
    -- id 1000 keeps every claim foreign (a claim from our own id is ignored)
    local storm = new_node({ ifaces = { lan }, id = 1000 })
    for mac = 1, 40 do
        M.dad_input(storm, lan, claim_body(2, mac, our_ip, our_ip))
    end
    T.eq(storm.dad.peer_count, 16, "the peer table is capped at MAX_PEERS")
    T.ok(storm.dad.ignored > 0, "claims beyond the cap are counted as ignored")
    T.eq(storm.dad.conflicts, 40, "every claim is still counted as a conflict")

    -- ===== status / report =================================================
    local s = M.dad_status(n)
    T.eq(s.enabled, true, "dad_status: enabled")
    T.eq(s.policy, "detect", "dad_status: policy")
    T.eq(#s.peers, 1, "dad_status: one peer recorded")
    T.eq(s.peers[1].mac, 5, "dad_status: peer MAC")
    T.eq(s.peers[1].ip, our_ip, "dad_status: peer address")
    T.eq(s.peers[1].count, 2, "dad_status: peer claim count")
    T.ok(M.dad_report(n):find("dad=on policy=detect", 1, true) ~= nil, "dad_report renders the counters")
    T.eq(M.dad_report(off), "dad=off", "dad_report says off when disabled")
    T.eq(M.dad_status({}).enabled, false, "dad_status on a node without dad says disabled")

    -- ===== ip header checksum switch =======================================
    local src, dst = M.ip2int("10.0.1.2"), M.ip2int("10.0.2.2")
    local pkt = M.ip_build(src, dst, M.IP_UDP, 63, 4321, false, 0, "body")
    local good = M.ip_parse(pkt)
    T.ok(good ~= nil, "a freshly built header parses")
    local bad = M.sub(pkt, 1, 10) .. M.u16((M.r16(pkt, 11) + 1) % 65536) .. M.sub(pkt, 13)
    local dropped, why = M.ip_parse(bad)
    T.eq(dropped, nil, "the default parse rejects a bad header checksum")
    T.eq(why, "hdr_cksum", "the rejection names the checksum")
    local lenient = M.ip_parse(bad, false)
    T.ok(lenient ~= nil, "ip_parse(..., false) skips the header checksum")
    T.eq(lenient.id, 4321, "the lenient parse still reads the header fields")
    local runt, why2 = M.ip_parse("short")
    T.eq(runt, nil, "a runt still fails")
    T.eq(why2, "structure", "a runt is a structural failure, not a checksum failure")

    -- ===== node wiring =====================================================
    local node = M.node_new({ role = "host" })
    local corrupt = M.sub(pkt, 1, 10) .. M.u16((M.r16(pkt, 11) + 1) % 65536) .. M.sub(pkt, 13)
    node.verify_cksum = true
    node:ip_input(nil, corrupt)
    T.eq(node.stats.ip_cksum_bad, 1, "node:ip_input counts a bad checksum separately")
    T.eq(node.stats.ip_bad, 0, "a bad checksum is not counted as an unparseable packet")
    node:ip_input(nil, "short")
    T.eq(node.stats.ip_bad, 1, "a runt is still counted as ip_bad")
    node.verify_cksum = false
    node:ip_input(nil, corrupt)
    T.eq(node.stats.ip_cksum_bad, 1, "with verification off the packet is not rejected")
    T.eq(node.stats.ip_rx, 1, "with verification off the packet reaches the receive path")
    T.ok(type(node:dad_report()) == "string", "a real node exposes dad_report()")

    -- the hooks have to exist in node.lua, not only in dad.lua
    local f = fs.open("rpv/node.lua", "r")
    local src_text = f.readAll()
    f.close()
    for _, hook in ipairs({ "M.dad_start(self)", "M.dad_tick(self)", "M.dad_input(self, iface, body)",
                            'self.cfg.ip_cksum ~= "0"', "ip_cksum_bad", "dad_send_blocked" }) do
        T.ok(src_text:find(hook, 1, true) ~= nil, "node.lua wires " .. hook)
    end
end)

M.link_send = original_link_send
if not ok then error(err) end
