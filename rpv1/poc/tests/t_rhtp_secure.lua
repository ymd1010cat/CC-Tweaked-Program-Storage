--[[- tests/t_rhtp_secure.lua - the standalone PSK-seal envelope (apps/rhtp_secure.lua)
used by the RHTP server to wrap responses, cross-checked against the exact key-derivation
and envelope rules the pyroet-os system/net/rhtp_secure.lua copy implements. Every assertion
here pins down a rule that both the pyroet-os and rpv1 copies must hold, so a silent drift in
either breaks the golden test.

The cross-test is a byte-identical contract: the same PSK + request nonce must seal the same
plaintext to the same envelope (deterministic HKDF/ChaCha20/HMAC), and that envelope must open
under this copy and under the pyroet-os-copy semantics. The 12-byte ChaCha20 nonce is
nonce_input = nonce_base[1..4] .. bin_nonce (8 bytes), a deliberate deviation from http_secure's
persistent counter: RHTP is stateless single-request/single-response, so per-message nonces are
negotiated on the wire instead of a shared monotonic counter.
]]
local T, M = ...

local S = M.rhtp_secure
local crypto = M
T.ok(S ~= nil and type(crypto.hkdf_sha256) == "function", "rhtp_secure and crypto modules loaded")
if not S then return end

local PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

local function make_secure()
    local ok, inst, err = pcall(S.new, { psk_hex = PSK, crypto = crypto })
    if not ok then return nil, inst end
    return inst, err
end

-- ===== constructor contract =================================================
local sconf = assert(make_secure(), "secure module new() succeeds with a 64-hex PSK")
T.eq(S.VERSION, "1.0", "VERSION is 1.0")
T.eq(S.NONCE_LEN, 8, "NONCE_LEN is 8 (the per-request nonce width)")
T.eq(S.TAG_LEN, 16, "TAG_LEN is 16 (HMAC-SHA256 truncated)")

local bad, berr = S.new({ psk_hex = "nothex", crypto = crypto })
T.ok(bad == nil, "bad psk is rejected")
T.eq(berr, "bad psk", "bad psk reason")
-- without an explicit crypto the module lazy-loads /system/rpv/crypto.lua
-- (crypto.lua here), so a 64-hex key alone succeeds with the default fallback
local autoc = S.new({ psk_hex = PSK })
T.ok(type(autoc) == "table", "crypto auto-loads when not passed")

-- explicit nonce_base must be honored (12 bytes); the default derives from the PSK
local shownce = assert(S.new({ psk_hex = PSK, crypto = crypto, nonce_base = "abcdefghijkl" }))
T.eq(shownce:nonce_of(string.rep("\1", 8)):sub(1, 4), "abcd", "nonce_base dictation keeps its first 4 bytes")
T.eq(shownce:nonce_of(string.rep("\1", 8)):sub(5), string.rep("\1", 8), "explicit nonce_base keeps the 8 request bytes")

-- ===== key derivation (must match the pyroet-os copy exactly) ===============
T.eq(crypto.hex(sconf.key), "575b16f28df6901307d22fc4546070da2cbb186488a7e2ea5641168b2cc89c57",
    "s2c key derivation (HKDF rhtp-s2c-key-v1) matches the golden value")
T.ok(#sconf.nonce_base == 12, "derived nonce_base is 12 bytes")

-- ===== seal/open round trip =================================================
local body = "Hello, world!\r\nwith a CR and a LF inside"
local bn = "\1\2\3\4\5\6\7\8"
local code = 200
local reason = "OK"
local sealed = assert(sconf:seal(code, reason, body, bn))

-- envelope shape: status line + Rhtp-Seal header + body
local head, ct = sealed:match("^(.-)\r\n\r\n(.*)$")
T.ok(head ~= nil, "sealed response has a header/body split")
T.ok(head:find("^RHTP/1.0 200 OK\r\nRhtp%-Seal: ", 1) ~= nil,
    "header starts with the status line then the Rhtp-Seal header")
T.eq(sealed:match("^RHTP/1.0 (%d+)"), "200", "status code is preserved")
-- the Rhtp-Seal line echoes the request nonce (16 hex) and the tag length (16)
local nonce_echo, tag_echo = sealed:match("Rhtp%-Seal: v1 (%x+) (%d+) (%x+)")
T.eq(nonce_echo, "0102030405060708", "header echoes the request nonce hex")
T.eq(tag_echo, "16", "header tag length is 16 bytes")
T.ok(not ct:find("world", 1, true), "plaintext body is not visible in the ciphertext")

-- deterministic: same nonce + plaintext -> same envelope
T.eq(sconf:seal(code, reason, body, bn), sealed, "sealing is deterministic per nonce")

-- open round trip (same instance, different nonce would use same keys)
local ok, plain = sconf:open(sealed, bn)
T.ok(ok == 200, "sealed response opens")
T.eq(plain, body, "opened plaintext matches")
local ok2, plain2 = sconf:open(sealed, "\1\2\3\4\5\6\7\9")
T.ok(ok2 == nil, "a wrong nonce fails to open (the echoed nonce is bound)")
T.eq(plain2, "seal bad", "wrong-nonce open reason")

-- open of a plaintext (unsealed) response fails closed
local ofail, oerr = sconf:open("RHTP/1.0 200 OK\r\n\r\nhi", bn)
T.ok(ofail == nil, "unsealed response is rejected")
T.eq(oerr, "plain", "unsealed-open reason is plain")

-- ===== tamper detection =====================================================
-- flip one hex char in the 32-hex tag token (the last token on the Rhtp-Seal
-- line): the MAC must reject and report "seal bad"
local tnonce, tlen, tag = sealed:match("Rhtp%-Seal: v1 (%x+) (%d+) (%x+)\r?\n")
T.ok(tag ~= nil and #tag == 32, "sealed response carries a 32-hex tag")
local badtag
if tag then
    local c = tag:sub(1, 1)
    local newc = (c == "a" and "b" or "a")
    badtag = sealed:gsub(tag, newc .. tag:sub(2), 1)
    local t1, t2 = sconf:open(badtag, bn)
    T.ok(t1 == nil, "a flipped tag hex char fails the MAC")
    T.ok(t2 == "seal bad", "tampered-open reason is seal bad")
end

-- flip one byte inside the ciphertext (body is opaque, so we tamper the byte
-- right after the header/body split and rebuild the envelope with the old tag)
local hlen = sealed:find("\r\n\r\n", 1, true) + 3
local ct1 = sealed:sub(hlen + 1)
local first = ct1:sub(1, 1)
local flipped = (first ~= "a" and "a" or "b")
local em = sealed:sub(1, hlen) .. flipped .. ct1:sub(2)
local u1 = sconf:open(em, bn)
T.ok(u1 == nil, "a modified ciphertext fails the MAC")

-- ===== full server integration (start_rhtp with opts.secret) ================
local RH = M.rhtp_server
T.ok(RH ~= nil, "rhtp_server module loaded")
if RH and crypto then
    -- node stub: captures the handler like t_rhtp_server does, but the server
    -- seals when the request carries the marker
    local function make_server_node(secret)
        local node = { logs = {} }
        function node:bind(port, handler)
            local sock = { port = port, handler = handler, sent = {} }
            function sock.sendto(self, src, sport, resp)
                self.sent[#self.sent + 1] = resp
                return true
            end
            node.sock = sock
            return sock
        end
        function node:log(fmt, ...)
            local ok, txt = pcall(string.format, fmt, ...)
            node.logs[#node.logs + 1] = ok and txt or tostring(fmt)
        end
        local rpv = { sha256 = M.sha256, hex = M.hex }
        function rpv.udp_send(n, src, dport, sport, resp)
            n.sock.sent[#n.sock.sent + 1] = resp
            return true
        end
        return node, rpv
    end

    local secret = PSK
    local node, rpv = make_server_node(secret)
    local sock = RH.start_rhtp(node, 8080, rpv, { secret = secret })
    T.ok(sock ~= nil, "start_rhtp with opts.secret binds a socket")
    local req = "GET / Rhtp-Seal: 1 0102030405060708"
    node.sock.handler(req, "10.0.0.9", 4000)
    local reply = node.sock.sent[#node.sock.sent]
    -- the reply to a marked request is wrapped
    local rcode, rbody = sconf:open(reply, "\1\2\3\4\5\6\7\8")
    T.ok(rcode == 200, "server-sealed reply opens with the request nonce")
    T.ok((rbody or ""):find("Welcome to InterTeamNet", 1, true) ~= nil,
        "sealed reply carries the routed body")

    -- a plain request gets the plaintext reply untouched
    local plnode, plrpv = make_server_node(secret)
    local pld = RH.start_rhtp(plnode, 8080, plrpv, { secret = secret })
    plnode.sock.handler("GET /", "10.0.0.9", 4001)
    local plreply = plnode.sock.sent[#plnode.sock.sent]
    T.ok(tostring(plreply):find("Welcome to InterTeamNet", 1, true) ~= nil,
        "an unmarked request is answered in plaintext")

    -- without opts.secret the server never seals even for a marked request
    local nonode, norpv = make_server_node(nil)
    local nsock = RH.start_rhtp(nonode, 8080, norpv)
    T.ok(nsock ~= nil, "start_rhtp without secret still binds")
    nonode.sock.handler("GET / Rhtp-Seal: 1 0102030405060708", "10.0.0.9", 4002)
    local nreply = nonode.sock.sent[#nonode.sock.sent]
    T.ok(tostring(nreply):find("Welcome to InterTeamNet", 1, true) ~= nil,
        "a server with no PSK never seals (plaintext by default)")
end