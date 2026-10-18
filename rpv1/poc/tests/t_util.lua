--[[- tests/t_util.lua — integer/varint helpers, addresses, checksums.]]
local T, M = ...

T.eq(M.u8(0), "\0", "u8 zero")
T.eq(M.u8(255), string.char(255), "u8 max")
T.eq(#M.u16(0x1234), 2, "u16 width")
T.eq(M.r16(M.u16(0xBEEF), 1), 0xBEEF, "u16 round trip")
T.eq(M.r32(M.u32(0xDEADBEEF), 1), 0xDEADBEEF, "u32 round trip")
T.eq(M.r32(M.u32(4000000000), 1), 4000000000, "u32 large value")

T.eq(M.ip2int("10.0.1.2"), (10 * 2 ^ 24) + (0 * 2 ^ 16) + (1 * 2 ^ 8) + 2, "ip2int")
T.eq(M.int2ip((10 * 2 ^ 24) + (0 * 2 ^ 16) + (1 * 2 ^ 8) + 2), "10.0.1.2", "int2ip")
T.eq(M.int2ip(M.ip2int("255.255.255.255")), "255.255.255.255", "ip round trip max")
T.eq(M.int2ip(M.ip2int("0.0.0.0")), "0.0.0.0", "ip round trip zero")

T.eq(M.masked(M.ip2int("10.0.1.77"), 24), M.ip2int("10.0.1.0"), "masked /24")
T.eq(M.masked(M.ip2int("10.0.1.77"), 16), M.ip2int("10.0.0.0"), "masked /16")
T.eq(M.masked(M.ip2int("10.0.1.77"), 0), 0, "masked /0")

T.eq(M.hex("A"), "41", "hex A")
T.eq(M.unhex("41"), "A", "unhex 41")
T.eq(M.hex(M.unhex("00112233445566778899aabbccddeeff")), "00112233445566778899aabbccddeeff", "hex round trip")
T.ok(M.equals("abc", "abc"), "equals same")
T.ok(not M.equals("abc", "abd"), "equals different")
T.ok(not M.equals("abc", "abcd"), "equals different length")
