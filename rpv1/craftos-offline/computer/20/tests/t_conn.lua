--[[- tests/t_conn.lua — segment codec and the P3 configuration surface.]]
local T, M = ...

T.eq(M.CONN_TYPES.SYN, 1, "type SYN")
T.eq(M.CONN_TYPES.SYNACK, 2, "type SYNACK")
T.eq(M.CONN_TYPES.DATA, 3, "type DATA")
T.eq(M.CONN_TYPES.FIN, 4, "type FIN")
T.eq(M.CONN_TYPES.SACK, 5, "type SACK")

-- hand-build a segment exactly as conn.lua writes it
local function seg(t, seq, ack, win, payload)
    return M.u8(t) .. M.u32(seq) .. M.u32(ack) .. M.u16(win) .. M.u16(#payload) .. payload
end
local s = M.conn_parse(seg(3, 1000, 2000, 4096, "hello"))
T.ok(s ~= nil, "conn_parse accepts a well formed segment")
T.eq(s.t, 3, "parsed type")
T.eq(s.seq, 1000, "parsed seq")
T.eq(s.ack, 2000, "parsed ack")
T.eq(s.win, 4096, "parsed window")
T.eq(s.len, 5, "parsed length")
T.eq(s.payload, "hello", "parsed payload")
T.ok(M.conn_parse("tiny") == nil, "conn_parse rejects a runt")
T.ok(M.conn_parse(seg(3, 1, 1, 1, "abc"):sub(1, 15)) == nil, "conn_parse rejects a truncated payload")

-- config surface: defaults and the P3 knobs
local node = T.node({}, { { name = "LAN-A", ip = M.ip2int("10.0.1.1"), prefix = 24, net = M.ip2int("10.0.1.0") } })
local c = M.conn_new(node, { port = 4300, peer_ip = M.ip2int("10.0.1.2"), peer_port = 4300, state = "SYN_SENT" })
T.eq(c.sack, true, "SACK on by default")
T.eq(c.iw, 2, "default initial window")
T.eq(c.cwnd, 2, "cwnd starts at the initial window")
T.eq(c.wscale, 0, "window scaling off by default")
T.eq(c.mss, 200, "default MSS")

node.cfg.conn_sack = "0"
node.cfg.conn_iw = "4"
node.cfg.conn_wscale = "4"
node.cfg.conn_keepalive = "5"
node.cfg.conn_global_max_inflight = "3"
local c2 = M.conn_new(node, { port = 4300, peer_ip = M.ip2int("10.0.1.2"), peer_port = 4300 })
T.eq(c2.sack, false, "conn_sack=0 disables SACK")
T.eq(c2.iw, 4, "conn_iw honoured")
T.eq(c2.wscale, 4, "conn_wscale honoured")
T.eq(c2.keepalive, 5, "conn_keepalive honoured")
T.eq(c2.gmax, 3, "conn_global_max_inflight honoured")

-- PSK derivation: deterministic, and different keys for different secrets
local n1 = T.node({ conn_psk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" })
local n2 = T.node({ conn_psk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff" })
local n3 = T.node({ conn_psk = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100" })
local k1, k2, k3 = M.conn_psk_derive(n1), M.conn_psk_derive(n2), M.conn_psk_derive(n3)
T.eq(#k1, 32, "derived PSK is 32 bytes")
T.eq(k1, k2, "same PSK -> same key")
T.ok(k1 ~= k3, "different PSK -> different key")
T.eq(M.conn_psk_derive(T.node({})), nil, "no conn_psk -> no key (fail closed)")
