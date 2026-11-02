--[[- pyroet-os/tests/t_rhtp_secure.lua -- PSK-sealed RHTP envelope
-- (system/net/rhtp_secure.lua).
--
-- All of this uses the real rpv crypto primitives from /system/rpv/crypto.lua
-- and the real envelope module; nothing is stubbed. The golden cross-check to
-- the rpv1 reference lives on the rpv1 side (t_rhtp_secure.lua asserts the two
-- implementations coalesce on identical bytes for the same psk + nonce +
-- body); here the round-trip, tamper, fail-closed and ChaCha20-vector paths are
-- covered end to end.
--
-- No non-ASCII bytes in this file. ]]

local SC = assert(loadfile("/system/net/rhtp_secure.lua"))()
local CRYPTO = assert(loadfile("/system/rpv/crypto.lua"))({})

local function fresh(...)
    return SC.new(...)
end

return function(H)
    -- a fixed, valid 64-hex PSK shared by every group
    local PSK = string.rep("ab", 32) -- 64 chars
    H.eq("psk_len", #PSK, 64)
    H.match("psk_hex", PSK, "^[0-9a-fA-F]+$")

    -- -----------------------------------------------------------------
    H.group("seal.roundtrip")
    do
        local s, err = fresh({ psk_hex = PSK, crypto = CRYPTO })
        H.check("construct", s ~= nil and type(s) == "table", "new() failed: " .. tostring(err))
        if s then
            local bin_nonce = CRYPTO.random_bytes(8)
            local text = s:seal(200, "OK", "hello world", bin_nonce)
            H.check("seal_string", type(text) == "string", "seal returned " .. tostring(text))
            H.match("seal_status", text or "",
                "^RHTP/1%.0 200 OK\r\n[R]htp%-Seal: v1 %x+ 16 %x+\r\n\r\n")
            local code, body = s:open(text, bin_nonce)
            H.eq("open_code", code, 200)
            H.eq("open_body", body, "hello world")
        end
    end

    -- -----------------------------------------------------------------
    H.group("seal.empty_body")
    do
        local s = fresh({ psk_hex = PSK, crypto = CRYPTO })
        local bin_nonce = CRYPTO.random_bytes(8)
        local text = s:seal(204, "No Content", "", bin_nonce)
        H.check("seal_ok", type(text) == "string", "empty body seal failed")
        local code, body = s:open(text, bin_nonce)
        H.eq("empty_code", code, 204)
        H.eq("empty_body", body, "")
    end

    -- -----------------------------------------------------------------
    H.group("seal.psk_validation")
    do
        local bad1 = fresh({ psk_hex = "abcd", crypto = CRYPTO }) -- too short
        H.eq("short_psk", bad1, nil)
        H.eq("short_psk_reason", select(2, fresh({ psk_hex = "abcd", crypto = CRYPTO })), "bad psk")
        local bad2 = fresh({ psk_hex = string.rep("z", 64), crypto = CRYPTO })
        H.eq("nonhex_psk", bad2, nil)
        local no_psk = fresh({ crypto = CRYPTO })
        H.eq("no_psk", no_psk, nil)
        -- a crypto table without the rpv subset is refused (not lazily loaded)
        local no_crypto, no_crypto_err = fresh({ psk_hex = PSK, crypto = {} })
        H.eq("no_crypto", no_crypto, nil)
        H.eq("no_crypto_reason", no_crypto_err, "no crypto")
    end

    -- -----------------------------------------------------------------
    H.group("seal.tamper_fail_closed")
    do
        local s = fresh({ psk_hex = PSK, crypto = CRYPTO })
        local bin_nonce = CRYPTO.random_bytes(8)
        local text = s:seal(200, "OK", "sensitive payload", bin_nonce)

        -- tamper the ciphertext body: same header, different ct
        local head, ct = text:match("^(.*\r\n\r\n)(.*)$")
        local flipped = ct:sub(1, #ct - 1) .. (ct:sub(-1) == "x" and "y" or "x")
        local code, why = s:open(head .. flipped, bin_nonce)
        H.eq("ct_tamper_code", code, nil)
        H.eq("ct_tamper_reason", why, "seal bad")

        -- tamper the status line: 200 -> 404 must fail the MAC
        local alt = text:gsub("^RHTP/1%.0 200", "RHTP/1.0 404")
        local c2, w2 = s:open(alt, bin_nonce)
        H.eq("status_tamper_code", c2, nil)
        H.eq("status_tamper_reason", w2, "seal bad")

        -- wrong nonce echoes fail closed even with a valid-looking envelope
        local other = CRYPTO.random_bytes(8)
        local c3, w3 = s:open(text, other)
        H.eq("wrong_nonce_code", c3, nil)
        H.eq("wrong_nonce_reason", w3, "seal bad")

        -- a plain, non-sealed response is not a sealed one
        local c4, w4 = s:open("RHTP/1.0 200 OK\r\n\r\nplain", bin_nonce)
        H.eq("plain_code", c4, nil)
        H.eq("plain_reason", w4, "plain")

        -- a truncated/garbage envelope is not a plain response either
        local c5, w5 = s:open("garbage", bin_nonce)
        H.eq("garbage_code", c5, nil)
        H.eq("garbage_reason", w5, "bad response")
    end

    -- -----------------------------------------------------------------
    H.group("seal.nonce_determinism")
    do
        -- same psk + nonce + body must produce byte-identical text (the property
        -- the rpv1 golden cross-check relies on)
        local s = fresh({ psk_hex = PSK, crypto = CRYPTO })
        local bin_nonce = CRYPTO.random_bytes(8)
        local body = "deterministic body"
        local a = s:seal(200, "OK", body, bin_nonce)
        local b = s:seal(200, "OK", body, bin_nonce)
        H.eq("seal_identical", a, b)

        -- a different nonce is a different envelope (never a fixed keystream)
        local c = s:seal(200, "OK", body, CRYPTO.random_bytes(8))
        H.check("nonce_varies", a ~= c, "two nonces produced identical text")
    end

    -- -----------------------------------------------------------------
    H.group("seal.chacha_vector")
    do
        -- verify the envelope's ChaCha20 path against the primitive directly:
        -- seal with a hand-pinned nonce_base, then decrypt ct by hand
        local s = fresh({
            psk_hex = PSK,
            crypto = CRYPTO,
            nonce_base = string.rep("\0", 12),
        })
        local bin_nonce = string.rep("\171", 8)
        local body = "manual decrypt target"
        local text = s:seal(200, "OK", body, bin_nonce)
        local _, ct = text:match("^(.*\r\n\r\n)(.*)$")
        local nonce_input = string.rep("\0", 4) .. bin_nonce
        local plain = CRYPTO.chacha20_xor(s.key, nonce_input, 1, ct)
        H.eq("manual_decrypt", plain, body)
        H.eq("seal_uses_s2c_key", #s.key, 32)
        H.eq("seal_mac_len", #s.mac, 32)
        H.eq("nonce_base_len", #s.nonce_base, 12)
    end

    -- -----------------------------------------------------------------
    H.group("seal.psks_distinct_keys")
    do
        local s1 = fresh({ psk_hex = PSK, crypto = CRYPTO })
        local s2 = fresh({ psk_hex = string.rep("00ff", 32):sub(1, 64), crypto = CRYPTO })
        H.check("keys_differ", s1.key ~= s2.key, "two PSKs derived the same key")
        H.check("macs_differ", s1.mac ~= s2.mac, "two PSKs derived the same mac")
        -- a body sealed under PSK1 must not open under PSK2
        local bin_nonce = CRYPTO.random_bytes(8)
        local text = s1:seal(200, "OK", "cross psk", bin_nonce)
        local code, why = s2:open(text, bin_nonce)
        H.eq("cross_psk_code", code, nil)
        H.eq("cross_psk_reason", why, "seal bad")
    end
end