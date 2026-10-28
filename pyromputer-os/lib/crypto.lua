-- crypto.lua - XOR + SHA-256 keystream for rednet payloads
local crypto = {}

-- SHA-256, from lib/sha256.lua.
--
-- This used to ask the ROM for "cc.crypto" and fall back to a 64-bit arithmetic
-- fold when that library was absent. The fallback was NOT a hash, and cc.crypto
-- is absent on CraftOS-PC 2.8.3, so on that machine every digest this project
-- computed -- the login password hash, the BIOS password hash, the package
-- signature check -- was a non-cryptographic fold while still being treated as a
-- digest. Measured: crypto.sha256("abc") returned 16 characters where the real
-- digest is 64.
--
-- lib/sha256.lua is the real thing, verified against the FIPS/RFC test vectors,
-- and it is in the base half of the installation so it is always on the machine.
-- cc.crypto is still preferred when it exists (it is a native implementation and
-- much faster on a real CC:Tweaked machine), but it is now an optimisation rather
-- than the only correct path.
local function sha256(s)
    local ok, c = pcall(require, "cc.crypto")
    if ok and type(c) == "table" and type(c.sha256) == "function" then
        return c.sha256(s)
    end
    return require("sha256").hex(s)
end

crypto.sha256 = sha256

local function keystream(password, nonce, length)
    local stream = {}
    local total = 0
    local counter = 0
    while total < length do
        counter = counter + 1
        local block = sha256(password .. ":" .. nonce .. ":" .. counter)
        table.insert(stream, block)
        total = total + #block
    end
    return table.concat(stream):sub(1, length)
end

local function xor(a, b)
    local out = {}
    for i = 1, #a do
        out[i] = string.char(bit32.bxor(
            string.byte(a, i), string.byte(b, i)))
    end
    return table.concat(out)
end

function crypto.encrypt(password, plaintext)
    local nonce = tostring(math.random(1, 1e9)) .. tostring(os.epoch("utc"))
    local ks = keystream(password, nonce, #plaintext)
    local ciphertext = xor(plaintext, ks)
    local b64 = textutils.base64encode and textutils.base64encode(ciphertext)
        or ciphertext
    return nonce .. "\0" .. textutils.serialize({ data = b64 })
end

function crypto.decrypt(password, blob)
    local sep = blob:find("\0", 1, true)
    if not sep then return nil end
    local nonce = blob:sub(1, sep - 1)
    local payload = textutils.unserialize(blob:sub(sep + 1))
    if not payload then return nil end
    local ciphertext = payload.data
    if textutils.base64decode then
        ciphertext = textutils.base64decode(ciphertext)
    end
    local ks = keystream(password, nonce, #ciphertext)
    return xor(ciphertext, ks)
end

return crypto
