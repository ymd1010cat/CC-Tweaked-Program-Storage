-- bignum.lua - arbitrary precision integers for CC:Tweaked
-- Representation: limbs[i] holds 16 bits, little-endian
-- I/O uses hexadecimal strings

local B = {}
B.__index = B

local BASE = 65536
local BASE_DIGITS = 4   -- hex digits per limb

-- ============================================================
-- Construction / conversion
-- ============================================================

function B.from_hex(hex)
    if type(hex) == "number" then
        hex = string.format("%x", hex)
    end
    hex = tostring(hex):gsub("^0x", ""):gsub("%s", "")
    hex = hex:gsub("^0+", "")
    if hex == "" then hex = "0" end
    while #hex % BASE_DIGITS ~= 0 do hex = "0" .. hex end
    local limbs = {}
    for i = #hex, 1, -BASE_DIGITS do
        table.insert(limbs, tonumber(hex:sub(i - BASE_DIGITS + 1, i), 16))
    end
    return setmetatable({ limbs = limbs }, B)
end

function B.to_hex(n)
    local limbs = n.limbs
    if #limbs == 0 then return "0" end
    local parts = { string.format("%x", limbs[#limbs]) }
    for i = #limbs - 1, 1, -1 do
        table.insert(parts, string.format("%04x", limbs[i]))
    end
    return table.concat(parts)
end

function B.zero()
    return setmetatable({ limbs = {} }, B)
end

function B.one()
    return setmetatable({ limbs = { 1 } }, B)
end

function B.trim(n)
    while #n.limbs > 0 and n.limbs[#n.limbs] == 0 do
        table.remove(n.limbs)
    end
end

function B.copy(n)
    local limbs = {}
    for i = 1, #n.limbs do limbs[i] = n.limbs[i] end
    return setmetatable({ limbs = limbs }, B)
end

-- ============================================================
-- Comparison
-- ============================================================

function B.compare(a, b)
    if #a.limbs ~= #b.limbs then
        return #a.limbs < #b.limbs and -1 or 1
    end
    for i = #a.limbs, 1, -1 do
        if a.limbs[i] ~= b.limbs[i] then
            return a.limbs[i] < b.limbs[i] and -1 or 1
        end
    end
    return 0
end

function B.is_zero(n) return #n.limbs == 0 end
function B.is_odd(n)  return #n.limbs > 0 and n.limbs[1] % 2 == 1 end

-- ============================================================
-- Arithmetic
-- ============================================================

function B.add(a, b)
    local result = {}
    local carry = 0
    local n = math.max(#a.limbs, #b.limbs)
    for i = 1, n do
        local s = (a.limbs[i] or 0) + (b.limbs[i] or 0) + carry
        result[i] = s % BASE
        carry = math.floor(s / BASE)
    end
    if carry > 0 then result[n + 1] = carry end
    return setmetatable({ limbs = result }, B)
end

function B.sub(a, b)
    -- assumes a >= b
    local result = {}
    local borrow = 0
    for i = 1, #a.limbs do
        local s = a.limbs[i] - (b.limbs[i] or 0) - borrow
        if s < 0 then
            s = s + BASE
            borrow = 1
        else
            borrow = 0
        end
        result[i] = s
    end
    local r = setmetatable({ limbs = result }, B)
    B.trim(r)
    return r
end

function B.mul(a, b)
    if B.is_zero(a) or B.is_zero(b) then return B.zero() end
    local n, m = #a.limbs, #b.limbs
    local result = {}
    for i = 1, n + m do result[i] = 0 end
    for i = 1, n do
        local ai = a.limbs[i]
        if ai ~= 0 then
            local carry = 0
            for j = 1, m do
                local p = result[i + j - 1] + ai * b.limbs[j] + carry
                result[i + j - 1] = p % BASE
                carry = math.floor(p / BASE)
            end
            local k = i + m
            while carry > 0 do
                local s = (result[k] or 0) + carry
                result[k] = s % BASE
                carry = math.floor(s / BASE)
                k = k + 1
            end
        end
    end
    local r = setmetatable({ limbs = result }, B)
    B.trim(r)
    return r
end

-- Divide a by b, return quotient, remainder
function B.divmod(a, b)
    if B.is_zero(b) then error("bignum: division by zero") end
    if B.compare(a, b) < 0 then
        return B.zero(), B.copy(a)
    end

    -- Fast path: single-limb divisor
    if #b.limbs == 1 then
        local d = b.limbs[1]
        local q = {}
        local rem = 0
        for i = #a.limbs, 1, -1 do
            local cur = rem * BASE + a.limbs[i]
            q[i] = math.floor(cur / d)
            rem = cur % d
        end
        local quotient = setmetatable({ limbs = q }, B)
        B.trim(quotient)
        local remainder = setmetatable({ limbs = { rem } }, B)
        B.trim(remainder)
        return quotient, remainder
    end

    -- General case: long division, one limb at a time
    local quotient = {}
    for i = 1, #a.limbs do quotient[i] = 0 end
    local remainder = B.zero()

    for i = #a.limbs, 1, -1 do
        -- remainder = remainder * BASE + a.limbs[i]
        table.insert(remainder.limbs, 1, a.limbs[i])
        B.trim(remainder)

        -- Find largest q such that b * q <= remainder
        local lo, hi = 0, BASE - 1
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local candidate = B.mul(b, B.from_hex(string.format("%x", mid)))
            if B.compare(candidate, remainder) <= 0 then
                lo = mid
            else
                hi = mid - 1
            end
        end
        quotient[i] = lo
        if lo > 0 then
            local product = B.mul(b, B.from_hex(string.format("%x", lo)))
            remainder = B.sub(remainder, product)
        end
    end

    local q = setmetatable({ limbs = quotient }, B)
    B.trim(q)
    return q, remainder
end

function B.mod(a, b)
    local _, r = B.divmod(a, b)
    return r
end

-- ============================================================
-- Small whole numbers
-- ============================================================

-- From a Lua number. Only whole values up to 2^53 are exact in a double, and
-- a negative number has no meaning without a sign convention, so both are
-- refused instead of being guessed.
function B.from_num(x)
    if type(x) ~= "number" or x ~= math.floor(x) or x < 0 or x > 2 ^ 53 then
        error("bignum: from_num needs a whole number in 0 .. 2^53", 2)
    end
    return B.from_hex(string.format("%x", x))
end

-- 2^k, built limb by limb so a large k stays exact.
function B.pow2(k)
    k = math.floor(k)
    if k < 0 then error("bignum: pow2 needs k >= 0", 2) end
    local limb = math.floor(k / 16) + 1
    local limbs = {}
    for i = 1, limb - 1 do limbs[i] = 0 end
    limbs[limb] = 2 ^ (k % 16)
    return setmetatable({ limbs = limbs }, B)
end

-- Number of significant bits (0 for zero).
function B.bitlen(n)
    if #n.limbs == 0 then return 0 end
    local top = n.limbs[#n.limbs]
    local bits = 0
    while top > 0 do
        bits = bits + 1
        top = math.floor(top / 2)
    end
    return (#n.limbs - 1) * 16 + bits
end

-- ============================================================
-- Decimal I/O
-- ============================================================

-- Ten to the ninth is the largest power of ten that a double holds exactly, so
-- the decimal routines work on nine digit chunks.
local DEC_BASE = "3b9aca00"
local DEC_CHUNK = 9
local DEC_CHUNK_VALUE = 1000000000

-- Value of a string of decimal digits (blanks are ignored, a sign is not
-- read: the caller decides what to do with one).
function B.from_dec(text)
    if type(text) == "number" then
        text = string.format("%d", text)
    end
    local digits = tostring(text):gsub("%s", "")
    if digits:match("^%d+$") == nil then
        error("bignum: from_dec needs decimal digits", 2)
    end
    digits = digits:gsub("^0+", "")
    if digits == "" then return B.zero() end

    local value = B.zero()
    local take = #digits % DEC_CHUNK
    if take == 0 then take = DEC_CHUNK end
    local i = 1
    while i <= #digits do
        local stop = i + take - 1
        local chunk = tonumber(digits:sub(i, stop))
        local scale = take == DEC_CHUNK and B.from_hex(DEC_BASE)
            or B.from_num(10 ^ take)
        value = B.add(B.mul(value, scale), B.from_num(chunk))
        i = stop + 1
        take = DEC_CHUNK
    end
    return value
end

-- Decimal string of an unsigned value, without padding or sign.
function B.to_dec(n)
    if B.is_zero(n) then return "0" end
    local chunks = {}
    local cur = B.copy(n)
    local den = B.from_hex(DEC_BASE)
    while not B.is_zero(cur) do
        local q, r = B.divmod(cur, den)
        chunks[#chunks + 1] = tonumber(B.to_hex(r), 16)
        cur = q
    end
    local parts = {}
    for i = #chunks, 1, -1 do
        if i == #chunks then
            parts[#parts + 1] = string.format("%d", chunks[i])
        else
            parts[#parts + 1] = string.format("%09d", chunks[i] % DEC_CHUNK_VALUE)
        end
    end
    return table.concat(parts)
end

-- ============================================================
-- Bit operations
-- ============================================================

-- The four bit functions of a nibble, filled in once at load time so the
-- per limb work stays a handful of table reads instead of a loop over 16
-- bits. This also keeps the library free of any bit library, which CraftOS
-- does not promise on every version.
local AND_NIB, OR_NIB, XOR_NIB = {}, {}, {}
for x = 0, 15 do
    AND_NIB[x], OR_NIB[x], XOR_NIB[x] = {}, {}, {}
end
for x = 0, 15 do
    for y = 0, 15 do
        local bx, by = x, y
        local bit, a, o, e = 1, 0, 0, 0
        for _ = 1, 4 do
            local xb, yb = bx % 2, by % 2
            if xb == 1 and yb == 1 then a = a + bit end
            if xb == 1 or yb == 1 then o = o + bit end
            if xb ~= yb then e = e + bit end
            bx, by, bit = math.floor(bx / 2), math.floor(by / 2), bit * 2
        end
        AND_NIB[x][y], OR_NIB[x][y], XOR_NIB[x][y] = a, o, e
    end
end

-- One 16 bit limb through the four nibble tables of a bit function.
local function nibble(table_of, x, y)
    local result, mul = 0, 1
    for _ = 1, 4 do
        result = result + table_of[x % 16][y % 16] * mul
        x, y, mul = math.floor(x / 16), math.floor(y / 16), mul * 16
    end
    return result
end

local function bitwise(a, b, table_of)
    local n = math.max(#a.limbs, #b.limbs)
    local limbs = {}
    for i = 1, n do
        limbs[i] = nibble(table_of, a.limbs[i] or 0, b.limbs[i] or 0)
    end
    local r = setmetatable({ limbs = limbs }, B)
    B.trim(r)
    return r
end

function B.band(a, b) return bitwise(a, b, AND_NIB) end
function B.bor(a, b)  return bitwise(a, b, OR_NIB) end
function B.bxor(a, b) return bitwise(a, b, XOR_NIB) end

-- a * 2^k, k a whole number of bits (k >= 0).
function B.shl(a, k)
    k = math.floor(k)
    if k <= 0 then return B.copy(a) end
    local whole, rest = math.floor(k / 16), k % 16
    local limbs = {}
    for i = 1, whole do limbs[i] = 0 end
    for i = 1, #a.limbs do limbs[whole + i] = a.limbs[i] end
    if rest > 0 then
        local mul, carry = 2 ^ rest, 0
        for i = 1, #limbs do
            local v = limbs[i] * mul + carry
            limbs[i] = v % BASE
            carry = math.floor(v / BASE)
        end
        while carry > 0 do
            limbs[#limbs + 1] = carry % BASE
            carry = math.floor(carry / BASE)
        end
    end
    local r = setmetatable({ limbs = limbs }, B)
    B.trim(r)
    return r
end

-- floor(a / 2^k), the unsigned shift right (k >= 0).
function B.shr(a, k)
    k = math.floor(k)
    if k <= 0 then return B.copy(a) end
    local whole = math.floor(k / 16)
    if whole >= #a.limbs then return B.zero() end
    local limbs = {}
    for i = whole + 1, #a.limbs do limbs[#limbs + 1] = a.limbs[i] end
    local rest = k % 16
    if rest > 0 then
        local div, carry = 2 ^ rest, 0
        for i = #limbs, 1, -1 do
            local v = carry * BASE + limbs[i]
            limbs[i] = math.floor(v / div)
            carry = v % div
        end
    end
    local r = setmetatable({ limbs = limbs }, B)
    B.trim(r)
    return r
end

-- Modular exponentiation: base^exp mod modulus
function B.modpow(base, exp, modulus)
    local result = B.one()
    base = B.mod(base, modulus)
    local e = B.copy(exp)
    while not B.is_zero(e) do
        if B.is_odd(e) then
            result = B.mod(B.mul(result, base), modulus)
        end
        -- e = e / 2
        e = (B.divmod(e, B.from_hex("2")))
        base = B.mod(B.mul(base, base), modulus)
    end
    return result
end

return B
