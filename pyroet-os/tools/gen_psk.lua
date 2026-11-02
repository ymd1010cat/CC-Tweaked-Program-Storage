--[[- pyroet-os/tools/gen_psk.lua -- make a 64-hex RHTP pre-shared key.

Run it on any machine that has the rpv crypto module (a pocket computer with
the image installed, or a staged disk):

    gen_psk

It prints two ready-to-paste lines:

    rhtp_secret=<64 hex>        -> /etc/network.conf on the pocket computer
    opts.secret = "<64 hex>"    -> the deployed rhtp_server (rpv1/poc/apps)

Both ends must use the SAME value. A client with a secret and a server without
one fails closed ("seal required"); a server with a different secret fails
closed too ("seal bad"). Replacing the secret replaces the trust source.

Development tool: it lives in tools/ and is never listed in install.set.

As a module: local G = assert(loadfile("/gen_psk.lua"))(M)
    then G.gen{ crypto=... } -> 64-hex string, or nil, reason

No non-ASCII bytes in this file. ]]

local M = {}

M.BYTES = 32
M.HEX_LEN = 64

-- The crypto module is `local M = ...; return M`, and every loader in the
-- image passes a table; fall back across the paths a running machine may have.
local CRYPTO_PATHS = {
    "/system/rpv/crypto.lua",
    "rpv/crypto.lua",
    "/rpv/crypto.lua",
}

local function load_crypto()
    for i = 1, #CRYPTO_PATHS do
        local f = loadfile(CRYPTO_PATHS[i])
        if f then
            local ok, mod = pcall(f, {})
            if ok and type(mod) == "table" and type(mod.random_bytes) == "function" then
                return mod
            end
        end
    end
    return nil
end

-- 64 hex characters (32 bytes) from the real CSPRNG the envelope uses.
function M.gen(o)
    local opts = o or {}
    local crypto = opts.crypto or load_crypto()
    if type(crypto) ~= "table" or type(crypto.random_bytes) ~= "function" then
        return nil, "no crypto"
    end
    local ok, bytes = pcall(crypto.random_bytes, M.BYTES)
    if not ok or type(bytes) ~= "string" or #bytes ~= M.BYTES then
        return nil, "random_bytes failed"
    end
    local hex = crypto.hex(bytes)
    if type(hex) ~= "string" or #hex ~= M.HEX_LEN or not hex:match("^[0-9a-f]+$") then
        return nil, "bad hex"
    end
    return hex
end

function M.run(o)
    local opts = o or {}
    local log = opts.log or print
    local hex, why = M.gen(opts)
    if not hex then
        log("GEN_PSK FAIL " .. tostring(why))
        return false, nil
    end
    log("GEN_PSK ok len=" .. #hex)
    log("rhtp_secret=" .. hex)
    log("opts.secret = \"" .. hex .. "\"")
    return true, hex
end

-- Executed directly (the shell passes a string arg or nothing): run and print.
-- Loaded with loadfile(path)(tbl): stay a plain module so tests can call gen().
local host = ...
if type(host) ~= "table" then M.run({}) end
return M
