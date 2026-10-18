--[[- rpv security/wpa.lua — a WPA2-inspired link security layer for CC networks.

Structure mirrors WPA2-PSK / 802.11i, adapted to CC:

  WPA2                               here
  ----                               ----
  SSID + passphrase → PMK (PBKDF2)   network name + passphrase → PMK (PBKDF2-HMAC-SHA256)
  4-way handshake (ANonce/SNonce)    same: M1..M4 with HMAC-SHA256 MIC (KCK)
  PTK = PRF(PMK, MACs, nonces)       PTK = HKDF-SHA256(PMK, macs||nonces) → KCK|KEK|TK
  GTK wrapped with KEK               GTK encrypted with KEK-derived ChaCha20 key
  CCMP = AES-CCM (AEAD)              ChaCha20 + HMAC-SHA256 (encrypt-then-MAC)
  48-bit PN replay counter           same: 48-bit PN + 64-frame sliding window

Differences / caveats (documented, deliberate):
  * no AES/Poly1305: ChaCha20 + HMAC-SHA256 needs no extra primitive and is
    verified by KATs; Poly1305 is a drop-in optimisation later.
  * no Diffie-Hellman: like WPA2-PSK this gives no forward secrecy, and a
    captured handshake is offline-dictionary-attackable — use long random
    per-network keys, or per-node keys (see rpv-security.md).
  * PBKDF2 must be chunked (yield_every) so CC's "too long without yielding"
    watchdog does not kill the computer during the handshake.
]]

local crypto = ...
assert(crypto and crypto.sha256, "wpa.lua requires crypto.lua")

local wpa = {}

local concat, rep, sub, byte, char, floor = table.concat, string.rep, string.sub, string.byte, string.char, math.floor
local HMAC = crypto.hmac_sha256

local function u48be(n)
    local out = {}
    for i = 6, 1, -1 do
        out[i] = char(n % 256)
        n = floor(n / 256)
    end
    return concat(out)
end
local function r48be(s, i)
    local n = 0
    for k = 0, 5 do n = n * 256 + byte(s, i + k) end
    return n
end

-- ===== key derivation =====
-- PMK = PBKDF2-HMAC-SHA256(passphrase, network name, iterations, 32)
function wpa.derive_pmk(passphrase, network, iterations, yield_every)
    return crypto.pbkdf2_sha256(passphrase, network, iterations or 1024, 32, yield_every or 128)
end

-- PTK = HKDF-SHA256(PMK, salt = macs||nonces, info = "rpv pairwise", 64)
function wpa.derive_ptk(pmk, mac_a, mac_b, nonce_a, nonce_b)
    local lo_mac, hi_mac = mac_a, mac_b
    if mac_a > mac_b then lo_mac, hi_mac = mac_b, mac_a end
    local lo_nonce, hi_nonce = nonce_a, nonce_b
    if nonce_a > nonce_b then lo_nonce, hi_nonce = nonce_b, nonce_a end
    local salt = lo_mac .. hi_mac .. lo_nonce .. hi_nonce
    local ptk = crypto.hkdf_sha256(pmk, salt, "rpv pairwise key expansion", 64)
    return {
        ptk = ptk,
        kck = sub(ptk, 1, 16),          -- key confirmation key (MIC)
        kek = sub(ptk, 17, 32),         -- key encryption key (GTK wrap)
        tk = sub(ptk, 33, 64),          -- temporal key (data protection)
    }
end

-- data plane keys, one direction each
function wpa.data_keys(tk, direction)
    return {
        enc = crypto.hkdf_sha256(tk, "", "rpv data enc " .. direction, 32),
        mac = crypto.hkdf_sha256(tk, "", "rpv data mac " .. direction, 32),
    }
end

-- ===== MIC (WPA2 uses HMAC over KCK, truncated to 16 bytes) =====
local function mic(kck, parts)
    return sub(HMAC(kck, concat(parts)), 1, 16)
end

-- ===== 4-way handshake =====
-- message shapes (tables, exchanged as strings by the app layer):
--   M1: { t="M1", anonce=32B }
--   M2: { t="M2", snonce=32B, mic=16B }
--   M3: { t="M3", gtk_ct=<32B+16B tag>, mic=16B }
--   M4: { t="M4", mic=16B }
function wpa.new_handshake(role, pmk, ap_mac, sta_mac)
    return {
        role = role, pmk = pmk, ap_mac = ap_mac, sta_mac = sta_mac,
        state = "init", anonce = nil, snonce = nil, ptk = nil, gtk = nil, errors = 0,
    }
end

-- returns M1 (authenticator) or nil (supplicant waits for M1)
function wpa.hs_start(h)
    if h.role ~= "ap" then return nil end
    h.anonce = crypto.random_bytes(32)
    h.state = "m1_sent"
    return { t = "M1", anonce = h.anonce }
end

-- supplicant: consume M1, produce M2
function wpa.hs_rx_m1(h, m1)
    if h.role ~= "sta" then return nil, "not supplicant" end
    if m1.t ~= "M1" or #m1.anonce ~= 32 then return nil, "bad M1" end
    h.anonce = m1.anonce
    h.snonce = crypto.random_bytes(32)
    h.ptk = wpa.derive_ptk(h.pmk, h.ap_mac, h.sta_mac, h.anonce, h.snonce)
    local m = { t = "M2", snonce = h.snonce }
    m.mic = mic(h.ptk.kck, { "M2", h.anonce, h.snonce, h.ap_mac, h.sta_mac })
    h.state = "m2_sent"
    return m
end

-- authenticator: verify M2, produce M3 (with wrapped GTK)
function wpa.hs_rx_m2(h, m2)
    if h.role ~= "ap" then return nil, "not authenticator" end
    if m2.t ~= "M2" or #m2.snonce ~= 32 then return nil, "bad M2" end
    h.snonce = m2.snonce
    h.ptk = wpa.derive_ptk(h.pmk, h.ap_mac, h.sta_mac, h.anonce, h.snonce)
    local want = mic(h.ptk.kck, { "M2", h.anonce, h.snonce, h.ap_mac, h.sta_mac })
    if not crypto.equals(want, m2.mic or "") then
        h.errors = h.errors + 1
        h.state = "failed"
        return nil, "MIC mismatch (wrong passphrase?)"
    end
    h.gtk = crypto.random_bytes(32)
    local kek_key = crypto.hkdf_sha256(h.ptk.kek, "", "rpv gtk wrap", 32)
    local ct = crypto.chacha20_xor(kek_key, rep("\0", 12), 0, h.gtk)
    local wrap_tag = sub(HMAC(kek_key, "gtk" .. ct), 1, 16)
    local m = { t = "M3", gtk_ct = ct .. wrap_tag }
    m.mic = mic(h.ptk.kck, { "M3", h.anonce, h.snonce, ct })
    h.state = "m3_sent"
    return m
end

-- supplicant: verify M3, unwrap GTK, produce M4
function wpa.hs_rx_m3(h, m3)
    if h.role ~= "sta" then return nil, "not supplicant" end
    if m3.t ~= "M3" or #m3.gtk_ct ~= 48 then return nil, "bad M3" end
    local ct, tag = sub(m3.gtk_ct, 1, 32), sub(m3.gtk_ct, 33, 48)
    local want = mic(h.ptk.kck, { "M3", h.anonce, h.snonce, ct })
    if not crypto.equals(want, m3.mic or "") then
        h.errors = h.errors + 1
        h.state = "failed"
        return nil, "M3 MIC mismatch"
    end
    local kek_key = crypto.hkdf_sha256(h.ptk.kek, "", "rpv gtk wrap", 32)
    if not crypto.equals(sub(HMAC(kek_key, "gtk" .. ct), 1, 16), tag) then
        h.errors = h.errors + 1
        h.state = "failed"
        return nil, "GTK wrap tag mismatch"
    end
    h.gtk = crypto.chacha20_xor(kek_key, rep("\0", 12), 0, ct)
    local m = { t = "M4" }
    m.mic = mic(h.ptk.kck, { "M4", h.anonce, h.snonce })
    h.state = "established"
    return m
end

-- authenticator: verify M4
function wpa.hs_rx_m4(h, m4)
    if h.role ~= "ap" then return nil, "not authenticator" end
    local want = mic(h.ptk.kck, { "M4", h.anonce, h.snonce })
    if not crypto.equals(want, m4.mic or "") then
        h.errors = h.errors + 1
        h.state = "failed"
        return nil, "M4 MIC mismatch"
    end
    h.state = "established"
    return true
end

-- ===== data plane: ChaCha20 + HMAC-SHA256 (encrypt-then-MAC), 48-bit PN =====
-- frame = PN(6) || ciphertext || tag(16); nonce = 6 zero bytes || PN (12 bytes)
function wpa.seal(keys, pn, plaintext)
    local nonce = rep("\0", 6) .. u48be(pn)
    local ct = crypto.chacha20_xor(keys.enc, nonce, 1, plaintext)
    local tag = sub(HMAC(keys.mac, u48be(pn) .. ct), 1, 16)
    return u48be(pn) .. ct .. tag
end

function wpa.open(keys, frame)
    if #frame < 6 + 16 then return nil, "short frame" end
    local pn = r48be(frame, 1)
    local ct = sub(frame, 7, #frame - 16)
    local tag = sub(frame, #frame - 15)
    local want = sub(HMAC(keys.mac, u48be(pn) .. ct), 1, 16)
    if not crypto.equals(want, tag) then return nil, "tag mismatch", pn end
    local nonce = rep("\0", 6) .. u48be(pn)
    return crypto.chacha20_xor(keys.enc, nonce, 1, ct), nil, pn
end

-- replay window: accept PN > last, or within WINDOW and unseen (WPA2-style)
local WINDOW = 64
function wpa.new_rx()
    return { last = nil, seen = {} }
end

function wpa.replay_check(rx, pn)
    if rx.last == nil then
        rx.last = pn
        rx.seen[pn % WINDOW] = true
        return true
    end
    if pn > rx.last then
        -- advance, clearing bits that fall out of the window
        for i = rx.last + 1, pn do rx.seen[i % WINDOW] = false end
        rx.seen[pn % WINDOW] = true
        rx.last = pn
        return true
    end
    if rx.last - pn >= WINDOW then return false end
    local slot = pn % WINDOW
    if rx.seen[slot] then return false end
    rx.seen[slot] = true
    return true
end

return wpa
