--[[- rpv/wansec.lua ? AEAD for the rednet WAN tunnel (control plane, P1b).

Same idea as the secure conn mode, applied to the WAN link: the tunnel is
authenticated and encrypted with a pre-shared key, so a computer that can hear the
rednet traffic (any modem on the WAN channel is enough) cannot read or forge it.

  * handshake: every node broadcasts `rpv-sec-hello` = mac + nonce + HMAC(k_ctrl).
    On a valid hello both sides derive per-peer session keys from the ordered
    (mac, nonce) pair, so both compute the same keys without another round trip.
  * data frames: `"S" | counter(4) | ChaCha20(frame) | tag(16)`, tag over
    `counter|ciphertext`. Retransmissions reuse the counter and produce the same
    ciphertext (same keystream), which is exactly what we want.
  * replay protection: per-peer monotonic counter + 64 frame sliding window.
  * control tables (rpv-advert / rpv-who-has / rpv-is-at) are signed over a
    canonical field list with k_ctrl.
  * fail-closed: with `wan_secure=1` a plaintext string frame, an unsigned table or
    a hello without a valid tag is dropped and counted; a peer we have no keys for
    cannot get anything through.

Config: wan_secure=1, wan_psk=<hex|passphrase>, wan_psk_iter=256,
        wan_sec_mac_len=16, wan_replay_window=64, wan_hello_interval=4

Logs: WANSEC_START, WANSEC_HELLO, WANSEC_KEYS, WANSEC_TX, WANSEC_RX, WANSEC_AUTH_FAIL,
      WANSEC_REPLAY, WANSEC_NO_KEYS, WANSEC_PLAINTEXT, WANSEC_STATE.
]]
local M = ...
local u8, u16, u32, r32, byte, sub = M.u8, M.u16, M.u32, M.r32, M.byte, M.sub

local HELLO = "rpv-sec-hello"

local function sec_is_hex(s)
    return #s >= 32 and #s % 2 == 0 and not s:find("[^0-9a-fA-F]")
end

function M.wansec_psk(node)
    local spec = node.cfg.wan_psk
    if not spec or spec == "" then return nil end
    local raw
    if sec_is_hex(spec) then
        raw = M.unhex(spec)
    else
        local iters = tonumber(node.cfg.wan_psk_iter) or 256
        raw = (iters > 0) and M.pbkdf2_sha256(spec, "rpv-wan", iters, 32, 32) or spec
    end
    return M.hkdf_sha256(raw, "", "rpv-wan-psk-v1", 32)
end

local function canon(msg)
    local keys = { "sType", "ver", "seq", "hops", "gw", "ip", "default", "mac", "nonce", "nets" }
    local parts = {}
    for _, k in ipairs(keys) do
        local v = msg[k]
        if type(v) == "table" then
            local t = {}
            for _, x in ipairs(v) do t[#t + 1] = tostring(x) end
            v = "[" .. table.concat(t, ",") .. "]"
        end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(parts, "|")
end

function M.wansec_setup(node, w)
    if node.cfg.wan_secure ~= "1" then return nil end
    local psk = M.wansec_psk(node)
    local sec = {
        node = node, w = w, mac = tonumber(node.cfg.wan_sec_mac_len) or 16,
        window = tonumber(node.cfg.wan_replay_window) or 64,
        peers = {}, tx = 0, rx = 0, auth_fail = 0, replay = 0, plaintext = 0, no_keys = 0,
        hellos = 0, enabled = psk ~= nil,
    }
    node.wansec = sec
    if not psk then
        node:log("WANSEC_FAIL_CLOSED no wan_psk (WAN tunnel will accept nothing)")
        return sec
    end
    sec.psk = psk
    sec.k_ctrl = M.hkdf_sha256(psk, "", "rpv-wan-ctrl-v1", 32)
    sec.nonce = M.random_bytes(8)
    sec.hello_tx = "HELLO|" .. tostring(node.mac) .. "|" .. sec.nonce
    node:log("WANSEC_START mac=%d hello_interval=%ss window=%d tag=%dB fail_closed=yes",
        node.mac, tostring(node.cfg.wan_hello_interval or 4), sec.window, sec.mac)
    return sec
end

function M.wansec_hello(node, w)
    local sec = node.wansec
    if not sec or not sec.enabled then return false end
    local tag = M.hmac_sha256(sec.k_ctrl, sec.hello_tx):sub(1, sec.mac)
    rednet.broadcast({ sType = HELLO, ver = 1, mac = node.mac, nonce = sec.nonce, tag = tag }, "rpv")
    sec.hellos = sec.hellos + 1
    node:log("WANSEC_HELLO sent nonce=%s tag=%s", M.hex(sec.nonce), M.hex(tag))
    return true
end

function M.wansec_hello_loop(node, w)
    M.wansec_hello(node, w)
    local st = M.wansec_stats(node)
    if st then
        node:log("WANSEC_STATE peers=%d tx=%d rx=%d auth_fail=%d replay=%d plaintext=%d no_keys=%d hellos=%d",
            st.peers, st.tx, st.rx, st.auth_fail, st.replay, st.plaintext, st.no_keys, st.hellos)
    end
    node:after(tonumber(node.cfg.wan_hello_interval) or 4, function() M.wansec_hello_loop(node, w) end)
end

-- derive per-peer keys; both sides use the ordered (mac, nonce) pair
local function derive_pair(sec, peer_mac, peer_nonce, my_nonce)
    local lo_mac, lo_nonce, hi_mac, hi_nonce
    if sec.node.mac < peer_mac then
        lo_mac, lo_nonce, hi_mac, hi_nonce = sec.node.mac, my_nonce, peer_mac, peer_nonce
    else
        lo_mac, lo_nonce, hi_mac, hi_nonce = peer_mac, peer_nonce, sec.node.mac, my_nonce
    end
    local salt = u32(lo_mac) .. lo_nonce .. u32(hi_mac) .. hi_nonce
    local k12 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-lo2hi", 32)
    local m12 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-lo2hi-mac", 32)
    local n12 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-lo2hi-nonce", 12)
    local k21 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-hi2lo", 32)
    local m21 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-hi2lo-mac", 32)
    local n21 = M.hkdf_sha256(sec.psk, salt, "rpv-wan-hi2lo-nonce", 12)
    local p = { mac = peer_mac, tx = 0, rx_top = 0, seen = {}, nonce = peer_nonce, since = os.clock() }
    if sec.node.mac < peer_mac then
        p.k_tx, p.m_tx, p.nonce_tx = k12, m12, n12
        p.k_rx, p.m_rx, p.nonce_rx = k21, m21, n21
    else
        p.k_tx, p.m_tx, p.nonce_tx = k21, m21, n21
        p.k_rx, p.m_rx, p.nonce_rx = k12, m12, n12
    end
    return p
end

function M.wansec_hello_input(node, w, sender, msg)
    local sec = node.wansec
    if not sec then return false end
    if not sec.enabled then
        sec.auth_fail = sec.auth_fail + 1
        node:log("WANSEC_PLAINTEXT hello from=%s but we have no usable PSK", tostring(sender))
        return true                       -- consumed (fail closed)
    end
    local pmac = tonumber(msg.mac) or sender
    local pnonce = tostring(msg.nonce or "")
    local expect = M.hmac_sha256(sec.k_ctrl, "HELLO|" .. tostring(pmac) .. "|" .. pnonce):sub(1, sec.mac)
    if not M.equals(expect, tostring(msg.tag or "")) then
        sec.auth_fail = sec.auth_fail + 1
        node:log("WANSEC_AUTH_FAIL hello from=%s (bad tag)", tostring(sender))
        return true
    end
    if #pnonce ~= 8 then
        sec.auth_fail = sec.auth_fail + 1
        return true
    end
    local had = sec.peers[pmac]
    if had and had.nonce == pnonce then
        -- same session: keep the counters and the replay window. Re-deriving on every
        -- hello would reset them, letting a captured frame be replayed successfully.
        had.since = os.clock()
        return true
    end
    sec.peers[pmac] = derive_pair(sec, pmac, pnonce, sec.nonce)
    sec.peers[pmac].id = tonumber(sender) or pmac
    if not had then
        node:log("WANSEC_KEYS peer=%d rednet_id=%s fp=%s", pmac, tostring(sender),
            M.hex(M.sha256(sec.peers[pmac].k_tx)):sub(1, 8))
    else
        node:log("WANSEC_REKEY peer=%d (peer restarted with a new nonce)", pmac)
    end
    -- answer so the peer can derive the same keys even if it booted after us
    M.wansec_hello(node, w)
    return true
end

-- control tables: sign a canonical view of the message
function M.wansec_sign_table(node, msg)
    local sec = node.wansec
    if not sec or not sec.enabled then return msg end
    msg.mac = node.mac
    msg.tag = M.hmac_sha256(sec.k_ctrl, canon(msg)):sub(1, sec.mac)
    return msg
end

function M.wansec_verify_table(node, w, sender, msg)
    local sec = node.wansec
    if not sec then return true end
    if not sec.enabled then
        sec.auth_fail = sec.auth_fail + 1
        node:log("WANSEC_PLAINTEXT %s from=%s (no usable PSK)", tostring(msg.sType), tostring(sender))
        return false
    end
    local tag = tostring(msg.tag or "")
    local copy = {}
    for k, v in pairs(msg) do if k ~= "tag" then copy[k] = v end end
    local expect = M.hmac_sha256(sec.k_ctrl, canon(copy)):sub(1, sec.mac)
    if not M.equals(expect, tag) then
        sec.auth_fail = sec.auth_fail + 1
        node:log("WANSEC_AUTH_FAIL %s from=%s (bad table tag)", tostring(msg.sType), tostring(sender))
        return false
    end
    return true
end

-- data frames: "S" | counter(4) | ciphertext | tag(16)
function M.wansec_wrap(node, w, peer, frame)
    local sec = node.wansec
    if not sec or not sec.enabled then return nil end
    local p = sec.peers[peer]
    if not p then
        sec.no_keys = sec.no_keys + 1
        node:log("WANSEC_NO_KEYS peer=%d (handshake pending, frame dropped)", peer)
        return nil
    end
    p.tx = p.tx + 1
    local ct = M.chacha20_xor(p.k_tx, p.nonce_tx, p.tx, frame)
    local tag = M.hmac_sha256(p.m_tx, u32(p.tx) .. ct):sub(1, sec.mac)
    sec.tx = sec.tx + 1
    node:log("WANSEC_TX peer=%d counter=%d bytes=%d", peer, p.tx, #frame)
    return "S" .. u32(p.tx) .. ct .. tag
end

function M.wansec_unwrap(node, w, sender, env)
    local sec = node.wansec
    if not sec or not sec.enabled then return nil end
    local p = sec.peers[tonumber(sender)]
    if not p then
        sec.no_keys = sec.no_keys + 1
        node:log("WANSEC_NO_KEYS from=%s (no session keys)", tostring(sender))
        return nil
    end
    if #env < 5 + sec.mac then return nil end
    local counter = r32(env, 2)
    local ct = sub(env, 6, #env - sec.mac)
    local tag = sub(env, #env - sec.mac + 1)
    if not M.equals(M.hmac_sha256(p.m_rx, u32(counter) .. ct):sub(1, sec.mac), tag) then
        sec.auth_fail = sec.auth_fail + 1
        node:log("WANSEC_AUTH_FAIL data from=%s counter=%d (bad tag)", tostring(sender), counter)
        return nil
    end
    if counter <= p.rx_top - sec.window or p.seen[counter] then
        sec.replay = sec.replay + 1
        node:log("WANSEC_REPLAY from=%s counter=%d top=%d (dropped)", tostring(sender), counter, p.rx_top)
        return nil
    end
    p.seen[counter] = true
    if counter > p.rx_top then p.rx_top = counter end
    for c in pairs(p.seen) do if c <= p.rx_top - sec.window then p.seen[c] = nil end end
    sec.rx = sec.rx + 1
    node:log("WANSEC_RX from=%s counter=%d bytes=%d", tostring(sender), counter, #env - 5 - sec.mac)
    return M.chacha20_xor(p.k_rx, p.nonce_rx, counter, ct)
end

function M.wansec_stats(node)
    local sec = node.wansec
    if not sec then return nil end
    local n = 0
    for _ in pairs(sec.peers) do n = n + 1 end
    return { peers = n, tx = sec.tx, rx = sec.rx, auth_fail = sec.auth_fail, replay = sec.replay,
             plaintext = sec.plaintext, no_keys = sec.no_keys, hellos = sec.hellos }
end

return M
