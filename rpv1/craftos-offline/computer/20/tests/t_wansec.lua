--[[- tests/t_wansec.lua — the WAN AEAD state machine, offline (rednet is stubbed).

Two nodes with the same PSK exchange hellos and must end up with matching session
keys; a wrapped frame must round trip, a replayed envelope must be rejected and a
tampered tag must fail authentication.
]]
local T, M = ...

-- stub the rednet surface wansec uses (it only broadcasts/sends)
local sent = {}
_G.rednet = {
    broadcast = function(msg, proto) sent[#sent + 1] = { msg = msg, proto = proto } end,
    send = function(id, msg, proto) sent[#sent + 1] = { id = id, msg = msg, proto = proto } end,
    open = function() end,
    host = function() end,
}

local PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
local function mknode(id, psk)
    local n = {
        id = id, mac = id, role = "router", cfg = { wan_secure = "1", wan_psk = psk or PSK },
        ifaces = {}, stats = {}, logged = {},
    }
    function n:log(fmt, ...)
        local line = string.format(fmt, ...)
        self.logged[#self.logged + 1] = line
    end
    return n
end
local function has_log(n, needle)
    for _, l in ipairs(n.logged) do if l:find(needle, 1, true) then return true end end
    return false
end

local A, B = mknode(21), mknode(22)
local sa = M.wansec_setup(A, nil)
local sb = M.wansec_setup(B, nil)
T.ok(sa ~= nil and sb ~= nil, "wansec_setup returns state")
T.ok(sa.enabled, "secure WAN enabled with a PSK")
T.eq(sa.mac, 16, "default tag length 16")
T.eq(sa.window, 64, "default replay window 64")
T.ok(has_log(A, "WANSEC_START"), "WANSEC_START logged")

-- A's hello must be accepted by B and vice versa, giving both sides keys
local helloA = { sType = "rpv-sec-hello", ver = 1, mac = 21, nonce = sa.nonce,
                 tag = M.hmac_sha256(sa.k_ctrl, "HELLO|21|" .. sa.nonce):sub(1, sa.mac) }
T.ok(M.wansec_hello_input(B, nil, 21, helloA) == true, "valid hello consumed")
T.ok(B.wansec.peers[21] ~= nil, "B derived keys for A")
T.ok(has_log(B, "WANSEC_KEYS"), "WANSEC_KEYS logged")

local helloB = { sType = "rpv-sec-hello", ver = 1, mac = 22, nonce = sb.nonce,
                 tag = M.hmac_sha256(sb.k_ctrl, "HELLO|22|" .. sb.nonce):sub(1, sb.mac) }
M.wansec_hello_input(A, nil, 22, helloB)
T.ok(A.wansec.peers[22] ~= nil, "A derived keys for B")

-- both sides must have computed the same pair of keys (A->B send == B receive)
T.eq(A.wansec.peers[22].k_tx, B.wansec.peers[21].k_rx, "A->B key matches B's receive key")
T.eq(B.wansec.peers[21].k_tx, A.wansec.peers[22].k_rx, "B->A key matches A's receive key")

-- frame wrap/unwrap round trip
local frame = M.u32(22) .. M.u32(21) .. M.u16(M.ET_IP) .. "SECRET-PAYLOAD"
local env = M.wansec_wrap(A, nil, 22, frame)
T.ok(type(env) == "string" and env:sub(1, 1) == "S", "wrapped frame has the S marker")
T.ok(not env:find("SECRET-PAYLOAD", 1, true), "payload is not visible in the envelope")
local plain = M.wansec_unwrap(B, nil, 21, env)
T.eq(plain, frame, "unwrapped frame matches the original")
T.eq(B.wansec.rx, 1, "RX counter incremented")

-- the same envelope again is a replay
T.eq(M.wansec_unwrap(B, nil, 21, env), nil, "replayed envelope rejected")
T.eq(B.wansec.replay, 1, "replay counted")

-- a tampered tag must fail authentication
local env2 = M.wansec_wrap(A, nil, 22, "another-frame")
local tampered = env2:sub(1, #env2 - 1) .. string.char((env2:byte(#env2) + 1) % 256)
T.eq(M.wansec_unwrap(B, nil, 21, tampered), nil, "tampered tag rejected")
T.eq(B.wansec.auth_fail, 1, "auth failure counted")

-- an unsigned control table must be refused once the tunnel is secure
T.eq(M.wansec_verify_table(B, nil, 21, { sType = "rpv-advert", seq = 1 }), false, "unsigned advert rejected")
local advert = M.wansec_sign_table(A, { sType = "rpv-advert", seq = 1 })
T.eq(M.wansec_verify_table(B, nil, 21, advert), true, "signed advert accepted")
advert.seq = 2
T.eq(M.wansec_verify_table(B, nil, 21, advert), false, "tampered advert rejected")

-- fail closed without a PSK
local C = mknode(23, "")
local sc = M.wansec_setup(C, nil)
T.ok(sc and not sc.enabled, "no PSK -> not enabled")
T.eq(M.wansec_wrap(C, nil, 21, "x"), nil, "no keys -> nothing is wrapped")
T.ok(has_log(C, "WANSEC_FAIL_CLOSED"), "fail-closed is logged")

-- repeated hellos with the SAME nonce must not reset the replay window
local before = B.wansec.peers[21].rx_top
M.wansec_hello_input(B, nil, 21, helloA)
T.eq(B.wansec.peers[21].rx_top, before, "same-nonce hello keeps the replay window")

_G.rednet = nil
