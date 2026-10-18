-- cksum.lua - the POSIX checksum printed by cksum(1)
--
-- WHY THIS IS NOT lib/checksum.lua
-- The two are different algorithms that share a name, and neither is derivable
-- from the other. lib/checksum.lua holds the zlib/PNG CRC-32: the polynomial is
-- used REFLECTED (0xEDB88320), the register starts at 0xFFFFFFFF and the value is
-- complemented at the end, which is what a zip stream or a transferred chunk
-- wants. cksum(1) is the older POSIX one: the polynomial is used as written
-- (0x04C11DB7, most significant bit first), the register starts at zero, then the
-- LENGTH of the input is fed through the same loop, and only then is the value
-- complemented. For "123456789" the two disagree -- cksum prints 930766865 where
-- the zlib value is 3421780262 -- so a "sum" built on checksum.crc32 would be
-- confidently wrong for every input and still perfectly stable, which is the one
-- kind of wrong a stability test cannot see.
--
-- The length is what separates two inputs of the same length from a short one:
-- a message and the same message with trailing zero bytes are different files and
-- have to print different numbers.

local ops = require("bitops")

local cksum = {}

-- The 256 entry byte table. It is built on first use rather than at load time
-- because a script that never calls cksum should not pay for it, and it is kept
-- because the table is the same for every call.
local TABLE

local function table_for()
    if TABLE then return TABLE end
    local built = {}
    for byte = 0, 255 do
        local crc = ops.lshift(byte, 24)
        for _ = 1, 8 do
            -- The generator is 0x04C11DB7 with the top bit revealed by the shift;
            -- a set top bit means the polynomial is subtracted, which for this
            -- form is an exclusive or after the shift.
            if ops.band(crc, 0x80000000) ~= 0 then
                crc = ops.bxor(ops.lshift(crc, 1), 0x04C11DB7)
            else
                crc = ops.lshift(crc, 1)
            end
        end
        built[byte] = crc
    end
    TABLE = built
    return TABLE
end

-- Feed DATA through the register and return the new value. CRC is the running
-- value, TABLE the byte table above.
local function feed(crc, data, byte_table)
    for i = 1, #data do
        local index = ops.band(ops.bxor(ops.rshift(crc, 24), data:byte(i)), 0xFF)
        crc = ops.bxor(ops.lshift(crc, 8), byte_table[index])
    end
    return crc
end

-- The number cksum(1) prints for DATA, and the length it prints beside it.
--
-- The length goes through the same loop, least significant byte first, in as few
-- bytes as it needs -- but never in none: the repeat runs once even for an empty
-- input, which is why "cksum </dev/null" prints 4294967295 0 and not 0 0.
function cksum.of(data)
    local byte_table = table_for()
    local crc = feed(0, data, byte_table)
    local rest = #data
    repeat
        crc = feed(crc, string.char(rest % 256), byte_table)
        rest = math.floor(rest / 256)
    until rest == 0
    return ops.bnot(crc), #data
end

-- Known answers, taken from cksum(1) itself. The empty input and the 256 byte
-- input are the two that pin the length encoding: one byte of zero for the first,
-- a zero byte followed by one for the second, and a "skip the length when it is
-- zero" implementation fails the first while a "one byte is always enough"
-- implementation fails the second.
function cksum.selftest()
    local cases = {
        { "123456789", "123456789", 930766865, 9 },
        { "abc", "abc", 1219131554, 3 },
        { "hello world", "hello world", 1135714720, 11 },
        { "foobar", "foobar", 2606601686, 6 },
        { "empty", "", 4294967295, 0 },
        { "a NUL byte", "a\0b", 3560722768, 3 },
        { "300 bytes", string.rep("x", 300), 3786917833, 300 },
        { "256 bytes", string.rep("a", 256), 3916537103, 256 },
    }
    local out = {}
    for _, case in ipairs(cases) do
        local crc, length = cksum.of(case[2])
        out[#out + 1] = {
            name = case[1],
            ok = (crc == case[3] and length == case[4]),
            got = tostring(crc) .. " " .. tostring(length),
            want = tostring(case[3]) .. " " .. tostring(case[4]),
        }
    end
    return out
end

return cksum
