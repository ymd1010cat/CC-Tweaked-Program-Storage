-- checksum.lua - integrity digests shared by the network and package layers
--
-- Two digests are used in this project:
--   * CRC32, for the per-chunk and whole-file checks of a rednet transfer.
--     It is cheap enough to run for every message and catches truncation and
--     corruption on the wire.
--   * SHA-256, for package digests. It comes from lib/crypto.lua, which uses
--     the CraftOS "cc.crypto" library when it exists.
--
-- bit32 exists on CC:Tweaked and on the Lua interpreters used for the PC side
-- checks. A pure arithmetic fallback keeps the module loadable on a runtime
-- that has no bit library at all, which is what the syntax-only check uses.

local checksum = {}

local bit32_lib = rawget(_G, "bit32")

local bxor, band, btest
if bit32_lib then
    bxor  = function(a, b) return bit32_lib.bxor(a, b) end
    band  = function(a, b) return bit32_lib.band(a, b) end
    btest = function(value, mask) return bit32_lib.band(value, mask) ~= 0 end
else
    -- Arithmetic fallback: only used when no bit library is present.
    local function clamp(x) return x % 4294967296 end
    bxor = function(a, b)
        local res, bit = 0, 1
        a, b = clamp(a), clamp(b)
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if abit ~= bbit then res = res + bit end
            a, b, bit = (a - abit) / 2, (b - bbit) / 2, bit * 2
        end
        return res
    end
    band = function(a, b)
        local res, bit = 0, 1
        a, b = clamp(a), clamp(b)
        for _ = 1, 32 do
            local abit, bbit = a % 2, b % 2
            if abit == 1 and bbit == 1 then res = res + bit end
            a, b, bit = (a - abit) / 2, (b - bbit) / 2, bit * 2
        end
        return res
    end
    btest = function(value, mask) return band(value, mask) ~= 0 end
end

local CRC32_POLY = 0xEDB88320

local crc_table = nil

local function build_table()
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if btest(c, 1) then
                c = bxor(math.floor(c / 2), CRC32_POLY)
            else
                c = math.floor(c / 2)
            end
        end
        t[i] = c
    end
    return t
end

-- CRC32 as used by zlib/PNG: reflected, polynomial 0xEDB88320, initial value
-- 0xFFFFFFFF, final complement. crc32("123456789") is 0xCBF43926.
function checksum.crc32(data)
    if crc_table == nil then crc_table = build_table() end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local byte = string.byte(data, i)
        local idx = bxor(band(crc, 0xFF), byte)
        -- Shift the register right by one byte before mixing the table entry
        -- in: band(crc, 0xFFFFFF00) alone would leave the 24 bits in place and
        -- produce a checksum no other implementation agrees with.
        crc = bxor(math.floor(crc / 256), crc_table[idx])
    end
    return bxor(crc, 0xFFFFFFFF)
end

function checksum.crc32_hex(data)
    return string.format("%08x", checksum.crc32(data))
end

-- SHA-256 of a string, as a lower case hex digest.
function checksum.sha256(data)
    return require("crypto").sha256(data)
end

-- Canonical digest of a "name -> content" file table, used for packages.
-- The order is fixed (sorted names) and the length is included before each
-- body, so neither a reordering nor a shifted boundary can produce the same
-- digest.
function checksum.files_digest(files)
    local names = {}
    for name in pairs(files or {}) do table.insert(names, tostring(name)) end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local body = tostring(files[name] or "")
        table.insert(parts, name .. ":" .. #body .. "\n" .. body .. "\n")
    end
    return checksum.sha256(table.concat(parts))
end

return checksum
