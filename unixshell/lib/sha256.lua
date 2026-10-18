-- sha256.lua - a real SHA-256, in the base half of the installation
--
-- WHY THIS MODULE EXISTS AT ALL
-- lib/crypto.lua used to get its digest from the CraftOS "cc.crypto" library and
-- fall back to a 64-bit arithmetic fold when that library was missing:
--
--     local ok, c = pcall(require, "cc.crypto")
--     if ok and c and c.sha256 then return c.sha256(s) end
--     ... h1 = (h1 * 31 + byte) % 4294967291 ...   -- NOT a hash
--
-- cc.crypto is NOT present on CraftOS-PC 2.8.3 (measured: `require "cc.crypto"`
-- fails, and crypto.sha256("abc") returned a 16 character "0001786200021546"
-- where the real digest is 64 characters). So on that machine every digest this
-- project computed was a non-cryptographic fold, and the things built on it --
-- the login password hash, the BIOS password hash, the package signature check --
-- were all weaker than they claimed. Nothing failed loudly, which is why it went
-- unnoticed: the tests only asserted that the digest was stable and changed with
-- its input, and a fold satisfies both.
--
-- The implementation below is the one from rpv/crypto.lua, which was already
-- verified against the RFC test vectors. It is copied rather than required
-- because rpv/ lives on the removable medium (it is in the modules half of a
-- two-part install): a module in the base half may not depend on a module the
-- machine cannot load without the medium inserted. The two copies are kept in
-- step by the known-answer tests in tests/batch3_check.lua, which check this one
-- against the standard vectors rather than against itself.
--
-- BIT LIBRARY: CraftOS is Lua 5.2 and provides bit32 (measured on CraftOS-PC:
-- _VERSION is "Lua 5.2" and bit32.bxor(5, 3) is 6). The PC side suites run on
-- lupa's Lua 5.1, where bit32 is absent, so a pure arithmetic fallback keeps the
-- module loadable and testable there. The fallback is slow but exact, and the
-- known-answer tests run on BOTH paths, so a mistake in either is caught.

local sha256 = {}

-- ============================================================
-- 32-bit operations: from lib/bitops.lua, NOT written again here
-- ============================================================
-- These are DIRECT REFERENCES, never wrappers. A wrapper such as
--     local function bxor(a, b) return ops.bxor(a, b) end
-- is exactly the bug that made this file's first version produce a digest that
-- was stable and wrong: SHA-256 calls bxor(a, b, c), and a two-argument wrapper
-- drops the third argument. The same defect was written three times (here, in
-- lib/crypto.lua's fallback, and in the bit32 shim in tests/net_harness.lua),
-- which is why the suite could not catch it -- its own shim had it. One module
-- with one variadic self test is the fix.
local ops = require("bitops")

local band, bor, bxor, bnot, rshift, lshift =
    ops.band, ops.bor, ops.bxor, ops.bnot, ops.rshift, ops.lshift

local rotr  = ops.rotr
local add32 = ops.add32
local u32be = ops.u32be

-- Only the string and math functions the compression loop actually uses. `bor`
-- and `char` are no longer needed here: the rotation and the big-endian packing
-- moved into lib/bitops.lua with the rest of the 32-bit work.
local floor, byte, sub, rep, format, concat =
    math.floor, string.byte, string.sub, string.rep,
    string.format, table.concat

-- ============================================================
-- SHA-256 (FIPS 180-4)
-- ============================================================
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

local H0 = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local function compress(h, block)
    local w = {}
    for i = 0, 15 do
        local o = i * 4
        w[i] = byte(block, o + 1) * 0x1000000 + byte(block, o + 2) * 0x10000 +
               byte(block, o + 3) * 0x100 + byte(block, o + 4)
    end
    for i = 16, 63 do
        local x, y = w[i - 15], w[i - 2]
        local s0 = bxor(rotr(x, 7), rotr(x, 18), rshift(x, 3))
        local s1 = bxor(rotr(y, 17), rotr(y, 19), rshift(y, 10))
        w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 0, 63 do
        local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = add32(hh, S1, ch, K[i + 1], w[i])
        local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = add32(S0, maj)
        hh, g, f, e, d, c, b, a = g, f, e, add32(d, t1), c, b, a, add32(t1, t2)
    end
    h[1], h[2], h[3], h[4] = add32(h[1], a), add32(h[2], b), add32(h[3], c), add32(h[4], d)
    h[5], h[6], h[7], h[8] = add32(h[5], e), add32(h[6], f), add32(h[7], g), add32(h[8], hh)
end

-- The digest as 32 raw bytes.
function sha256.digest(msg)
    msg = tostring(msg)
    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local len = #msg
    local bits = len * 8
    local padded = msg .. "\128" .. rep("\0", (55 - len) % 64) ..
        u32be(floor(bits / 4294967296)) .. u32be(bits % 4294967296)
    for i = 1, #padded, 64 do compress(h, sub(padded, i, i + 63)) end
    local out = {}
    for i = 1, 8 do out[i] = u32be(h[i]) end
    return concat(out)
end

-- The digest as lower case hex, which is what every caller wants.
function sha256.hex(msg)
    local raw = sha256.digest(msg)
    local out = {}
    for i = 1, #raw do out[i] = format("%02x", byte(raw, i)) end
    return concat(out)
end

-- True when this machine has a real bit library. The PC side suites run on
-- Lua 5.1 without bit32 and use the arithmetic fallback, so a test can say which
-- path it exercised.
function sha256.has_bit_library()
    return bit32_lib ~= nil
end

-- The standard known-answer tests, so a caller (or a test) can prove the
-- implementation rather than assume it. Returns a list of
-- { name, ok, got, want }.
function sha256.selftest()
    local cases = {
        { "sha256('')", "",
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
        { "sha256('abc')", "abc",
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
        { "sha256(56-byte)",
          "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
        -- 112 bytes: exercises the two-block padding path, where the length does
        -- not fit in the final block and a whole extra block is added.
        { "sha256(112-byte)",
          "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno" ..
          "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
          "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1" },
    }
    local out = {}
    for _, case in ipairs(cases) do
        local got = sha256.hex(case[2])
        out[#out + 1] = { name = case[1], ok = got == case[3],
                          got = got, want = case[3] }
    end
    return out
end

return sha256
