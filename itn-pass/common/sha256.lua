-- sha256.lua -- SHA-256 (FIPS 180-4), pure Lua for CraftOS.
--
-- Install as /sha256.lua on every machine that hashes: the Sentinel auth
-- server, the audit server, both terminal modes, and the ITN-Pass station.
-- The ITN-Pass terminal never loads this file.
--
--   local sha = dofile("/sha256.lua")
--   sha.hash("abc")    --> 64 lowercase hex chars
--   sha.digest("abc")  --> 32 raw bytes
--
-- Needs bit32 (present in CC:Tweaked and CraftOS-PC). No 5.3 syntax: runs on
-- the Lua 5.1/5.2 subset CraftOS ships.

local M = {}

local band = bit32.band
local bxor = bit32.bxor
local bnot = bit32.bnot
local rrotate = bit32.rrotate
local rshift = bit32.rshift

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local IV = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local TWO32 = 4294967296

-- Big-endian encoding of a 32-bit word.
local function be32(n)
    n = n % TWO32
    local b4 = n % 256; n = (n - b4) / 256
    local b3 = n % 256; n = (n - b3) / 256
    local b2 = n % 256; n = (n - b2) / 256
    return string.char(n, b2, b3, b4)
end

-- Appends 0x80, zero fill, then the 64-bit message length in bits.
local function pad(msg)
    local n = #msg
    local fill = 55 - (n % 64)
    if fill < 0 then fill = fill + 64 end
    return msg
        .. "\128"
        .. string.rep("\0", fill)
        .. be32(math.floor(n * 8 / TWO32))
        .. be32((n * 8) % TWO32)
end

-- Folds one 64-byte block (starting at off) into the state h[1..8].
local function block(h, data, off)
    local w = {}
    for i = 0, 15 do
        local p = off + i * 4
        w[i] = data:byte(p) * 0x1000000
             + data:byte(p + 1) * 0x10000
             + data:byte(p + 2) * 0x100
             + data:byte(p + 3)
    end
    for i = 16, 63 do
        local x, y = w[i - 15], w[i - 2]
        local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
        local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
        w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
    end

    local a, b, c, d = h[1], h[2], h[3], h[4]
    local e, f, g, k = h[5], h[6], h[7], h[8]

    for i = 0, 63 do
        local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = band(k + s1 + ch + K[i + 1] + w[i], 0xffffffff)
        local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = band(s0 + maj, 0xffffffff)
        k, g, f, e = g, f, e, band(d + t1, 0xffffffff)
        d, c, b, a = c, b, a, band(t1 + t2, 0xffffffff)
    end

    h[1] = band(h[1] + a, 0xffffffff)
    h[2] = band(h[2] + b, 0xffffffff)
    h[3] = band(h[3] + c, 0xffffffff)
    h[4] = band(h[4] + d, 0xffffffff)
    h[5] = band(h[5] + e, 0xffffffff)
    h[6] = band(h[6] + f, 0xffffffff)
    h[7] = band(h[7] + g, 0xffffffff)
    h[8] = band(h[8] + k, 0xffffffff)
end

-- 32 raw bytes.
function M.digest(msg)
    local data = pad(msg)
    local h = { IV[1], IV[2], IV[3], IV[4], IV[5], IV[6], IV[7], IV[8] }
    for off = 1, #data, 64 do
        block(h, data, off)
    end
    local parts = {}
    for i = 1, 8 do parts[i] = be32(h[i]) end
    return table.concat(parts)
end

local HEX = "0123456789abcdef"

-- 64 lowercase hex chars.
function M.hash(msg)
    local raw = M.digest(msg)
    local out = {}
    for i = 1, #raw do
        local b = raw:byte(i)
        local hi = math.floor(b / 16)
        out[i] = HEX:sub(hi + 1, hi + 1) .. HEX:sub(b % 16 + 1, b % 16 + 1)
    end
    return table.concat(out)
end

return M
