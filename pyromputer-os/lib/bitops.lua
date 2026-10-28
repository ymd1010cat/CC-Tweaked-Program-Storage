-- bitops.lua - the 32-bit operations the digest modules need, in ONE place
--
-- WHY THIS MODULE EXISTS
-- SHA-256 and MD5 both need band/bor/bxor/bnot/lshift/rshift on 32-bit values.
-- That was written out separately, three times, and all three copies had the same
-- defect: the functions were declared with two parameters while bit32's are
-- VARIADIC. The compression function calls bxor(a, b, c); a two-argument wrapper
-- silently drops the third, and the digest that comes out is stable, wrong, and
-- passes any test that only asks "is it stable".
--
-- The three copies were lib/crypto.lua's arithmetic fallback, lib/sha256.lua's
-- bit32 branch, and the bit32 shim in tests/net_harness.lua -- so the suite could
-- not have caught it: its own shim had the bug. One implementation with one
-- known-answer self test is the fix for the class of mistake, not just the
-- instance.
--
-- CALLERS MUST NOT WRAP THESE. A wrapper like
--     local function mybxor(a, b) return ops.bxor(a, b) end
-- reintroduces exactly the bug this file exists to prevent. Use the functions
-- directly, or write a vararg wrapper (`function(...)`) if you must wrap at all.
--
-- CraftOS is Lua 5.2 and has bit32 (measured: _VERSION is "Lua 5.2" and
-- bit32.bxor(5, 3) is 6). The PC side suites run on lupa's Lua 5.1, where bit32 is
-- absent, so an exact arithmetic fallback keeps both loadable. The self test runs
-- on whichever path is present.

local ops = {}

local MOD = 4294967296

-- ============================================================
-- the native path
-- ============================================================
local bit32_lib = rawget(_G, "bit32")

if bit32_lib then
    -- VARIADIC, like the original. `function(...)` is the whole point: writing
    -- `function(a, b)` here is the bug.
    ops.band   = function(...) return bit32_lib.band(...) end
    ops.bor    = function(...) return bit32_lib.bor(...) end
    ops.bxor   = function(...) return bit32_lib.bxor(...) end
    ops.bnot   = function(a) return bit32_lib.bnot(a) end
    ops.rshift = function(a, n) return bit32_lib.rshift(a, n) end
    ops.lshift = function(a, n) return bit32_lib.lshift(a, n) end
else
    -- ============================================================
    -- the arithmetic fallback (exact, slower)
    -- ============================================================
    local function clamp(x) return x % MOD end
    ops.u32 = clamp

    -- Fold one value into the accumulator, 32 bits at a time.
    --
    -- The varargs are packed into a TABLE first because Lua 5.1, which the PC side
    -- suites run on, forbids `...` inside a nested function ("cannot use '...'
    -- outside a vararg function"). select(i, ...) written inside a closure is a
    -- load error, not a wrong answer, so it fails loudly -- but it fails on the
    -- fallback path only, which is the path a machine without bit32 would take.
    local function fold_into(acc, y, keep)
        y = clamp(y)
        local res, bit = 0, 1
        local x = acc
        for _ = 1, 32 do
            local xb, yb = x % 2, y % 2
            if keep(xb, yb) then res = res + bit end
            x, y, bit = (x - xb) / 2, (y - yb) / 2, bit * 2
        end
        return res
    end

    local function variadic(keep)
        return function(first, ...)
            local acc = clamp(first)
            local rest = { ... }
            for i = 1, #rest do acc = fold_into(acc, rest[i], keep) end
            return acc
        end
    end

    -- VARIADIC: same contract as bit32.
    ops.band = variadic(function(x, y) return x == 1 and y == 1 end)
    ops.bor  = variadic(function(x, y) return x == 1 or y == 1 end)
    ops.bxor = variadic(function(x, y) return x ~= y end)
    ops.bnot = function(a) return MOD - 1 - clamp(a) end
    ops.rshift = function(a, n) return math.floor(clamp(a) / (2 ^ n)) end
    ops.lshift = function(a, n) return (clamp(a) * (2 ^ n)) % MOD end
end

-- ============================================================
-- helpers the digest modules share
-- ============================================================

-- Sum of the arguments, wrapped into 32 bits.
function ops.add32(...)
    local s = 0
    for i = 1, select("#", ...) do s = s + select(i, ...) end
    return ops.band(s, 0xFFFFFFFF)
end

-- Rotate right inside 32 bits.
function ops.rotr(x, n)
    return ops.band(ops.bor(ops.rshift(x, n), ops.lshift(x, 32 - n)), 0xFFFFFFFF)
end

-- Rotate left inside 32 bits.
function ops.rotl(x, n)
    return ops.band(ops.bor(ops.lshift(x, n), ops.rshift(x, 32 - n)), 0xFFFFFFFF)
end

-- A 32-bit value as four bytes, big or little endian.
function ops.u32be(v)
    v = math.floor(v)
    return string.char(math.floor(v / 0x1000000) % 256, math.floor(v / 0x10000) % 256,
                       math.floor(v / 0x100) % 256, v % 256)
end

function ops.u32le(v)
    v = math.floor(v)
    return string.char(v % 256, math.floor(v / 0x100) % 256,
                       math.floor(v / 0x10000) % 256, math.floor(v / 0x1000000) % 256)
end

-- A 32-bit value read from a string.
function ops.r32be(s, i)
    return string.byte(s, i) * 0x1000000 + string.byte(s, i + 1) * 0x10000 +
           string.byte(s, i + 2) * 0x100 + string.byte(s, i + 3)
end

function ops.r32le(s, i)
    return string.byte(s, i) + string.byte(s, i + 1) * 0x100 +
           string.byte(s, i + 2) * 0x10000 + string.byte(s, i + 3) * 0x1000000
end

-- Raw bytes as lower case hex, and back.
function ops.hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", string.byte(s, i)) end
    return table.concat(out)
end

-- True when this machine has a native bit library rather than the fallback.
function ops.has_native()
    return bit32_lib ~= nil
end

-- ============================================================
-- self test
-- ============================================================
-- The VARIADIC cases are the reason this exists. A two-argument band/bor/bxor
-- passes the two-argument cases above and fails these.
function ops.selftest()
    local cases = {
        { "band(0xF0F0F0F0, 0x0F0F0F0F)", ops.band(0xF0F0F0F0, 0x0F0F0F0F), 0 },
        { "band(0xFFFFFFFF, 0xFFFFFFFF)", ops.band(0xFFFFFFFF, 0xFFFFFFFF), 4294967295 },
        { "bor(0xF0F0F0F0, 0x0F0F0F0F)", ops.bor(0xF0F0F0F0, 0x0F0F0F0F), 4294967295 },
        { "bxor(0xF0F0F0F0, 0x0F0F0F0F)", ops.bxor(0xF0F0F0F0, 0x0F0F0F0F), 4294967295 },
        { "bnot(0)", ops.bnot(0), 4294967295 },
        { "bnot(0xFFFFFFFF)", ops.bnot(0xFFFFFFFF), 0 },
        { "lshift(1, 31)", ops.lshift(1, 31), 2147483648 },
        { "rshift(0x80000000, 31)", ops.rshift(0x80000000, 31), 1 },
        { "rotr(0x80000000, 1)", ops.rotr(0x80000000, 1), 1073741824 },
        { "rotr(1, 1)", ops.rotr(1, 1), 2147483648 },
        { "rotl(1, 1)", ops.rotl(1, 1), 2 },
        -- THREE arguments: a two-argument implementation drops the third and
        -- returns 1 or 2 here instead of 7.
        { "bxor(1, 2, 4)", ops.bxor(1, 2, 4), 7 },
        { "band(0xFF, 0xFF, 0xFF)", ops.band(0xFF, 0xFF, 0xFF), 255 },
        { "bor(1, 2, 4)", ops.bor(1, 2, 4), 7 },
        { "bxor(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)",
          ops.bxor(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF), 4294967295 },
        -- FOUR arguments, to catch a "handles exactly three" special case.
        { "bxor(0xF0, 0x0F, 0xFF, 0x00)", ops.bxor(0xF0, 0x0F, 0xFF, 0x00), 0 },
        { "add32(0xFFFFFFFF, 1)", ops.add32(0xFFFFFFFF, 1), 0 },
    }
    local out = {}
    for _, case in ipairs(cases) do
        out[#out + 1] = { name = case[1], ok = case[2] == case[3],
                          got = case[2], want = case[3] }
    end
    return out
end

return ops
