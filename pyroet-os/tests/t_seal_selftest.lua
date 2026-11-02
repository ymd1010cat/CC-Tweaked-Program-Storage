--[[- pyroet-os/tests/t_seal_selftest.lua -- the PSK generator and the
-- no-network seal proof (tools/gen_psk.lua, tools/seal_selftest.lua).
--
-- The point of these two tools is that the OWNER can verify sealing on a
-- machine that has no server attached, so the checks here must prove that the
-- tools really exercise the envelope: a fake envelope that accepts tampered
-- ciphertext has to make the selftest report FAIL, not ok.
--
-- No non-ASCII bytes in this file. ]]

local CRYPTO = assert(loadfile("/system/rpv/crypto.lua"))({})
local SC = assert(loadfile("/system/net/rhtp_secure.lua"))()
local GEN = assert(loadfile("/tests/gen_psk.lua"))({})
local SELFTEST = assert(loadfile("/tests/seal_selftest.lua"))({})

return function(H)
    local function sink()
        local lines = {}
        return function(text) lines[#lines + 1] = tostring(text) end, lines
    end

    -- -----------------------------------------------------------------
    H.group("seal_selftest.gen_psk")
    do
        local hex, why = GEN.gen({ crypto = CRYPTO })
        H.check("gen_ok", type(hex) == "string", "gen failed: " .. tostring(why))
        H.eq("gen_len", #(hex or ""), 64)
        H.match("gen_hex", hex or "", "^[0-9a-f]+$")
        local again = GEN.gen({ crypto = CRYPTO })
        H.check("gen_differs", hex ~= again, "two generators returned the same psk")
        local bad, berr = GEN.gen({ crypto = {} })
        H.check("gen_no_crypto", bad == nil and berr == "no crypto", tostring(berr))

        local log, lines = sink()
        local ok = GEN.run({ crypto = CRYPTO, log = log })
        H.check("run_ok", ok == true)
        H.eq("run_log", lines[1], "GEN_PSK ok len=64")
        H.match("run_conf_line", lines[2] or "", "^rhtp_secret=[0-9a-f]+$")
        H.match("run_server_line", lines[3] or "", "^opts%.secret = \"[0-9a-f]+\"$")
    end

    -- -----------------------------------------------------------------
    H.group("seal_selftest.run")
    do
        local log, lines = sink()
        local ok, out = SELFTEST.run({ crypto = CRYPTO, seal = SC, log = log })
        H.check("selftest_ok", ok == true, table.concat(lines, " | "))
        H.check("returns_lines", type(out) == "table" and #out > 0)
        H.has(lines, "SEAL_SELFTEST begin")
        H.has(lines, "SEAL_SELFTEST ok new")
        H.has(lines, "SEAL_SELFTEST ok seal")
        H.has(lines, "SEAL_SELFTEST ok roundtrip")
        H.has(lines, "SEAL_SELFTEST ok tamper rejected")
        H.has(lines, "SEAL_SELFTEST ok plaintext rejected")
        H.has(lines, "SEAL_SELFTEST ok wrong psk rejected")
        H.has(lines, "SEAL_SELFTEST RESULT ok")
        H.lacks("no_fail_line", lines, "SEAL_SELFTEST FAIL")
    end

    -- -----------------------------------------------------------------
    H.group("seal_selftest.detects_broken_envelope")
    do
        -- an envelope that never refuses anything: the selftest must fail
        local bogus = {
            NONCE_LEN = 8,
            new = function()
                return {
                    seal = function(_, code, reason, body)
                        return "RHTP/1.0 " .. code .. " " .. reason .. "\r\n\r\n" .. (body or "")
                    end,
                    open = function(_, text)
                        local _, body = text:match("^(.-)\r\n\r\n(.*)$")
                        return 200, body or ""
                    end,
                }
            end,
        }
        local log, lines = sink()
        local ok = SELFTEST.run({ crypto = CRYPTO, seal = bogus, log = log })
        H.check("bogus_fails", ok == false)
        H.has(lines, "SEAL_SELFTEST FAIL tamper rejected")
        H.has(lines, "SEAL_SELFTEST RESULT fail")
    end

    -- -----------------------------------------------------------------
    H.group("seal_selftest.missing_crypto")
    do
        local log, lines = sink()
        local ok = SELFTEST.run({ crypto = { hex = function() return "" end }, seal = SC, log = log })
        H.check("no_crypto_fails", ok == false)
        H.has(lines, "SEAL_SELFTEST FAIL crypto")
        H.has(lines, "SEAL_SELFTEST RESULT fail")
    end

    -- -----------------------------------------------------------------
    H.group("seal_selftest.real_disk_paths")
    do
        -- no injected modules: the tool must find /system/net + /system/rpv
        local log, lines = sink()
        local ok = SELFTEST.run({ log = log })
        H.check("disk_ok", ok == true, table.concat(lines, " | "))
        H.has(lines, "SEAL_SELFTEST RESULT ok")
    end
end
