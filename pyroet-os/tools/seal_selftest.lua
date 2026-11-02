--[[- pyroet-os/tools/seal_selftest.lua -- local proof that RHTP sealing works.

Run it on the machine you want to check (a pocket computer with the image, or
a demo disk copy):

    seal_selftest

It derives the PSK key tree, seals a sample response with a fresh 8-byte
nonce, opens it again, and confirms that a tampered ciphertext and an
unsealed response are both refused. Nothing leaves the machine: this is a
no-network check of system/net/rhtp_secure.lua against the real crypto
module, so it also works on a computer with no modem attached.

Output is machine readable: one SEAL_SELFTEST line per step and
"SEAL_SELFTEST RESULT ok" (or "fail") at the end. If the key tree or the
envelope module is missing, the failure line names the path that was tried.

Development tool: it lives in tools/ and is never listed in install.set.

As a module: local S = assert(loadfile("/seal_selftest.lua"))(M)
    then S.run{ crypto=..., seal=..., log=... } -> ok, lines

No non-ASCII bytes in this file. ]]

local M = {}

M.PSK_BYTES = 32
M.PSK_HEX_LEN = 64
M.SAMPLE_BODY = "seal selftest body"

local CRYPTO_PATHS = {
    "/system/rpv/crypto.lua",
    "rpv/crypto.lua",
    "/rpv/crypto.lua",
}

local SEAL_PATHS = {
    "/system/net/rhtp_secure.lua",
    "rhtp_secure.lua",
    "/rhtp_secure.lua",
}

local function first_module(paths, need)
    local tried = {}
    for i = 1, #paths do
        local f = loadfile(paths[i])
        if f then
            local ok, mod = pcall(f, {})
            if ok and type(mod) == "table" and type(mod[need]) == "function" then
                return mod
            end
        end
        tried[#tried + 1] = paths[i]
    end
    return nil, table.concat(tried, " ")
end

function M.run(o)
    local opts = o or {}
    local log = opts.log or print
    local lines = {}
    local all_ok = true

    local function emit(text)
        lines[#lines + 1] = text
        log(text)
    end

    local function check(name, ok, detail)
        if ok then
            emit("SEAL_SELFTEST ok " .. name)
        else
            all_ok = false
            emit("SEAL_SELFTEST FAIL " .. name .. ": " .. tostring(detail))
        end
    end

    local function finish()
        emit("SEAL_SELFTEST RESULT " .. (all_ok and "ok" or "fail"))
        return all_ok, lines
    end

    emit("SEAL_SELFTEST begin")

    local crypto = opts.crypto
    if not crypto then crypto = first_module(CRYPTO_PATHS, "random_bytes") end
    if type(crypto) ~= "table" or type(crypto.random_bytes) ~= "function"
        or type(crypto.hex) ~= "function" then
        check("crypto", false, "no crypto module (tried " .. table.concat(CRYPTO_PATHS, " ") .. ")")
        return finish()
    end
    check("crypto", true)

    local seal = opts.seal
    if not seal then seal = first_module(SEAL_PATHS, "new") end
    if type(seal) ~= "table" or type(seal.new) ~= "function" then
        check("module", false, "no rhtp_secure module (tried " .. table.concat(SEAL_PATHS, " ") .. ")")
        return finish()
    end
    check("module", true)

    local psk_hex = crypto.hex(crypto.random_bytes(M.PSK_BYTES))
    check("psk", #psk_hex == M.PSK_HEX_LEN, "len=" .. tostring(#psk_hex))
    emit("SEAL_SELFTEST psk_len=" .. #psk_hex)

    local sealer, why = seal.new({ psk_hex = psk_hex, crypto = crypto })
    if not sealer then
        check("new", false, why)
        return finish()
    end
    check("new", true)

    local nonce_len = seal.NONCE_LEN or 8
    local nonce = crypto.random_bytes(nonce_len)
    local text, serr = sealer:seal(200, "OK", M.SAMPLE_BODY, nonce)
    if type(text) ~= "string" then
        check("seal", false, serr)
        return finish()
    end
    check("seal", true)

    local code, body = sealer:open(text, nonce)
    check("roundtrip", code == 200 and body == M.SAMPLE_BODY,
        "code=" .. tostring(code) .. " body=" .. tostring(body))

    -- Tampering with the ciphertext must be caught by the tag.
    local head, ct = text:match("^(.-)\r\n\r\n(.*)$")
    if not head then
        check("tamper rejected", false, "could not split the envelope")
    else
        local flipped = (ct:sub(1, 1) == "A" and "B" or "A") .. ct:sub(2)
        local tcode, terr = sealer:open(head .. "\r\n\r\n" .. flipped, nonce)
        check("tamper rejected", tcode == nil and terr == "seal bad", tostring(terr))
    end

    -- An unsealed response to a sealed request is refused, not accepted.
    local ucode, uerr = sealer:open("RHTP/1.0 200 OK\r\n\r\nplain", nonce)
    check("plaintext rejected", ucode == nil and uerr == "plain", tostring(uerr))

    -- A different PSK must not open the same envelope (domain separation).
    local other_psk = crypto.hex(crypto.random_bytes(M.PSK_BYTES))
    local other = seal.new({ psk_hex = other_psk, crypto = crypto })
    if not other then
        check("wrong psk rejected", false, "second sealer could not be built")
    else
        local ocode, oerr = other:open(text, nonce)
        check("wrong psk rejected", ocode == nil and oerr == "seal bad", tostring(oerr))
    end

    return finish()
end

-- Executed directly (the shell passes a string arg or nothing): run and print.
-- Loaded with loadfile(path)(tbl): stay a plain module so tests can call run().
local host = ...
if type(host) ~= "table" then M.run({}) end
return M
