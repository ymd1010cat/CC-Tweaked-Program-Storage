---------------------------------------------------------------------------
-- 80486-simulator/tests/memory_test.lua
--
-- Standalone tests for memory.lua.  No test framework is required.
--
-- From the repository root:
--     lua 80486-simulator/tests/memory_test.lua
-- or, inside CraftOS:
--     dofile("80486-simulator/tests/memory_test.lua")
---------------------------------------------------------------------------

local function is_memory_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.PAGE_SIZE == 4096
        and type(mod.Memory) == "table"
end

local function load_memory()
    local ok, mod = pcall(require, "memory")
    if ok and is_memory_module(mod) then
        return mod
    end

    -- Make the test runnable from the repo root, from 80486-simulator/, or
    -- from inside tests/ on CraftOS.
    local candidates = {
        "80486-simulator/memory.lua",
        "../memory.lua",
        "memory.lua",
        "/80486-simulator/memory.lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and is_memory_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load memory.lua: " .. tostring(last_error))
end

local Memory = load_memory()
local char   = string.char
local concat = table.concat

local total   = 0
local passed  = 0
local skipped = 0
local failed  = 0

local function show(v)
    if type(v) == "string" then
        if #v <= 40 then
            return string.format("%q", v)
        end
        return string.format("<string len=%d>", #v)
    end
    if type(v) == "number" and v == v and v % 1 == 0 and v >= 0 then
        return string.format("0x%X (%d)", v, v)
    end
    return tostring(v)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" then
        error(string.format("%s: expected a string containing %q, got %s",
            label or "text", needle, show(text)), 2)
    end
    if not text:find(needle, 1, true) then
        error(string.format("%s: %q does not contain %q",
            label or "text", text, needle), 2)
    end
end

local function expect_error(fn, needle)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, but the call succeeded", 2)
    end
    if needle and not tostring(err):find(needle, 1, true) then
        error("error message does not contain " .. needle
            .. ": " .. tostring(err), 2)
    end
    return err
end

-- A skipped check is reported separately and is never counted as a pass.
local function skip(reason)
    error({__skip = tostring(reason)}, 0)
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok      " .. name)
    elseif type(err) == "table" and err.__skip ~= nil then
        skipped = skipped + 1
        print("SKIP    " .. name .. " (" .. tostring(err.__skip) .. ")")
    else
        failed = failed + 1
        print("FAIL    " .. name)
        print("        " .. tostring(err))
    end
end

---------------------------------------------------------------------------

test("constants and default 16 MiB", function()
    eq(Memory.PAGE_SIZE, 4096, "PAGE_SIZE")
    eq(Memory.PAGE_SHIFT, 12, "PAGE_SHIFT")
    eq(Memory.PAGE_COUNT, 4096, "PAGE_COUNT")
    eq(Memory.MAX_SIZE, 16777216, "MAX_SIZE")

    local m = Memory.new()
    eq(m:get_size(), 16777216, "size")
    eq(m:get_page_count(), 4096, "page count")
    eq(m:allocated_pages(), 0, "allocated pages")
end)

test("unallocated memory reads as zero", function()
    local m = Memory.new(0x3000)
    eq(m:read8(0), 0, "read8(0)")
    eq(m:read16(0x1FFE), 0, "read16 last bytes")
    eq(m:read32(0x2000), 0, "read32 page start")
    eq(m:read(0x1000, 33), string.rep("\0", 33), "read block")
    eq(m:allocated_pages(), 0, "still sparse")
end)

test("zero writes stay sparse", function()
    local m = Memory.new(0x4000)
    m:write8(0, 0)
    m:write16(0x1000, 0)
    m:write32(0x2000, 0)
    m:write(0x100, string.rep("\0", 64))
    m:fill(0x200, 128, 0)
    eq(m:allocated_pages(), 0, "no page allocated for zeros")
end)

test("byte accesses at page edges", function()
    local m = Memory.new(0x3000)
    m:write8(0, 0xAA)
    m:write8(0xFFF, 0xBB)
    m:write8(0x1000, 0xCC)
    m:write8(0x2FFF, 0xDD)

    eq(m:read8(0), 0xAA, "first byte")
    eq(m:read8(0xFFF), 0xBB, "page 0 last byte")
    eq(m:read8(0x1000), 0xCC, "page 1 first byte")
    eq(m:read8(0x2FFF), 0xDD, "last byte")
    eq(m:allocated_pages(), 3, "three pages")
end)

test("16-bit little-endian accesses", function()
    local m = Memory.new(0x3000)
    m:write16(0, 0x1234)
    eq(m:read8(0), 0x34, "low byte")
    eq(m:read8(1), 0x12, "high byte")
    eq(m:read16(0), 0x1234, "read16")

    -- Straddles 0x0FFF / 0x1000.
    m:write16(0xFFF, 0xABCD)
    eq(m:read8(0xFFF), 0xCD, "low byte at boundary")
    eq(m:read8(0x1000), 0xAB, "high byte at boundary")
    eq(m:read16(0xFFF), 0xABCD, "read16 across page")

    -- Unaligned.
    m:write16(1, 0xBEEF)
    eq(m:read16(1), 0xBEEF, "unaligned read16")
end)

test("32-bit little-endian accesses", function()
    local m = Memory.new(0x3000)
    m:write32(0, 0x12345678)
    eq(m:read8(0), 0x78, "byte 0")
    eq(m:read8(1), 0x56, "byte 1")
    eq(m:read8(2), 0x34, "byte 2")
    eq(m:read8(3), 0x12, "byte 3")
    eq(m:read32(0), 0x12345678, "read32")

    -- Straddles 0x0FFF / 0x1000.
    m:write32(0xFFE, 0xDEADBEEF)
    eq(m:read8(0xFFE), 0xEF, "byte 0 at boundary")
    eq(m:read8(0xFFF), 0xBE, "byte 1 at boundary")
    eq(m:read8(0x1000), 0xAD, "byte 2 at boundary")
    eq(m:read8(0x1001), 0xDE, "byte 3 at boundary")
    eq(m:read32(0xFFE), 0xDEADBEEF, "read32 across page")

    m:write32(3, 0x89ABCDEF)
    eq(m:read32(3), 0x89ABCDEF, "unaligned read32")

    m:write32(0x10, 0xFFFFFFFF)
    eq(m:read32(0x10), 0xFFFFFFFF, "maximum 32-bit value")
end)

test("block write/read across pages", function()
    local m = Memory.new(0x4000)
    local data = "hello\0world" .. string.rep("!", 5000)

    m:write(0xF00, data)
    eq(m:read(0xF00, #data), data, "round trip")
    eq(m:read8(0xF00 + 5), 0, "embedded NUL")
    eq(m:read8(0xEFF), 0, "byte before block")
    eq(m:read8(0xF00 + #data), 0, "byte after block")

    local whole = string.rep("A", 4096)
    m:write(0x1000, whole)
    eq(m:read(0x1000, 4096), whole, "whole-page round trip")
end)

test("whole-page writes share and free zero pages", function()
    local m = Memory.new(0x1000)
    m:write(0, string.rep("\0", 4096))
    eq(m:allocated_pages(), 0, "zero page not allocated")

    local page = string.rep("A", 4096)
    m:write(0, page)
    eq(m:allocated_pages(), 1, "page allocated")
    eq(m:read(0, 4096), page, "page contents")

    m:write(0, string.rep("\0", 4096))
    eq(m:allocated_pages(), 0, "zero page released")
end)

test("fill across page boundaries", function()
    local m = Memory.new(0x3000)
    m:fill(0xFF0, 32, 0x5A)
    eq(m:read(0xFF0, 32), string.rep("Z", 32), "filled block")
    eq(m:read8(0xFEF), 0, "untouched before")
    eq(m:read8(0x1010), 0, "untouched after")

    local n = Memory.new(0x2000)
    n:fill(0, 0x1000, 0x11)
    eq(n:read(0, 4096), string.rep(char(0x11), 4096), "full page fill")
    eq(n:allocated_pages(), 1, "one page allocated")

    n:fill(0, 0x1000, 0)
    eq(n:allocated_pages(), 0, "zero fill releases page")
end)

test("copy / memmove semantics", function()
    local m = Memory.new(0x4000)
    local s = "abcdefghij"
    m:write(0x100, s)
    m:copy(0x200, 0x100, #s)
    eq(m:read(0x200, #s), s, "non-overlapping copy")

    -- dst > src, overlapping: backwards copy required.
    m:write(0, "abcdef")
    m:copy(1, 0, 6)
    eq(m:read(0, 7), "aabcdef", "overlap dst > src")

    -- dst < src, overlapping: forwards copy required.
    local n = Memory.new(0x1000)
    n:write(0, "abcdef")
    n:copy(0, 1, 5)
    eq(n:read(0, 6), "bcdeff", "overlap dst < src")

    -- Same address is a no-op.
    n:copy(0, 0, 6)
    eq(n:read(0, 6), "bcdeff", "self copy")

    -- Large overlapping copy spanning multiple pages.
    local p = Memory.new(0x3000)
    local big = string.rep("0123456789", 500)
    p:write(0x800, big)
    p:copy(0x900, 0x800, #big)
    eq(p:read(0x900, #big), big, "large overlapping copy")
end)

test("memmove alias", function()
    local m = Memory.new(0x1000)
    m:write(0, "abcdef")
    m:memmove(1, 0, 6)
    eq(m:read(0, 7), "aabcdef", "memmove is copy")
end)

test("non-page-aligned memory size", function()
    local m = Memory.new(0x2005) -- ceil(8197 / 4096) == 3 pages
    eq(m:get_page_count(), 3, "page count")
    m:write8(0x2004, 0x7E)
    eq(m:read8(0x2004), 0x7E, "last valid byte")

    m:write(0x1FFE, "AB")
    eq(m:read(0x1FFE, 2), "AB", "write ending at boundary")

    expect_error(function() m:read8(0x2005) end, "out-of-bounds")
    expect_error(function() m:write(0x2004, "AB") end, "out-of-bounds")
end)

test("top of the 16 MiB address space", function()
    local m = Memory.new()
    local top = Memory.MAX_SIZE - 1

    m:write8(0, 0x11)
    m:write8(top, 0x22)
    eq(m:read8(0), 0x11, "address 0")
    eq(m:read8(top), 0x22, "last address")

    m:write16(top - 1, 0x3344)
    eq(m:read8(top - 1), 0x44, "last 16-bit low")
    eq(m:read8(top), 0x33, "last 16-bit high")

    m:write32(top - 3, 0xAABBCCDD)
    eq(m:read32(top - 3), 0xAABBCCDD, "last 32-bit value")

    expect_error(function() m:read32(top - 2) end, "out-of-bounds")
    expect_error(function() m:write8(Memory.MAX_SIZE, 0) end,
        "out-of-bounds")
end)

test("bounds checks for every multi-byte access", function()
    local m = Memory.new(0x2000)
    local function bad(fn)
        expect_error(fn, "out-of-bounds")
    end

    bad(function() m:read8(-1) end)
    bad(function() m:read8(0x2000) end)
    bad(function() m:read16(0x1FFF) end)
    bad(function() m:read32(0x1FFE) end)
    bad(function() m:read(0x1FFF, 2) end)
    bad(function() m:write8(0x2000, 1) end)
    bad(function() m:write16(0x1FFF, 1) end)
    bad(function() m:write32(0x1FFE, 1) end)
    bad(function() m:write(0x1FFF, "ab") end)
    bad(function() m:fill(0x1FFF, 2, 1) end)
    bad(function() m:copy(0x1FFF, 0, 2) end)
    bad(function() m:copy(0, 0x1FFF, 2) end)
    bad(function() m:read(0x2001, 0) end)

    -- Zero-length accesses exactly at the end are legal.
    eq(m:read(0x2000, 0), "", "empty read at end")
    m:write(0x2000, "")
end)

test("invalid values, lengths and sizes", function()
    local m = Memory.new(0x1000)

    expect_error(function() m:write8(0, 256) end, "0..255")
    expect_error(function() m:write8(0, -1) end, "0..255")
    expect_error(function() m:write8(0, 1.5) end, "0..255")
    expect_error(function() m:write16(0, 65536) end, "0..65535")
    expect_error(function() m:write32(0, 4294967296) end, "0..4294967295")
    expect_error(function() m:fill(0, 1, 256) end, "0..255")

    expect_error(function() m:read(0, -1) end, "non-negative")
    expect_error(function() m:read(0, 1.5) end, "non-negative")
    expect_error(function() m:read(0, nil) end, "non-negative")
    expect_error(function() m:write(0, 42) end, "must be a string")

    expect_error(function() Memory.new(0) end, "size must be")
    expect_error(function() Memory.new(1.5) end, "size must be")
    expect_error(function() Memory.new(Memory.MAX_SIZE + 1) end,
        "size must be")
end)

test("every byte value round-trips", function()
    local bytes = {}
    for i = 0, 255 do
        bytes[#bytes + 1] = char(i)
    end
    local data = concat(bytes)

    local m = Memory.new(0x1000)
    m:write(0, data)
    eq(m:read(0, #data), data, "block round trip")
    for i = 0, 255 do
        eq(m:read8(i), i, "byte " .. i)
    end
end)

test("clear resets pages but keeps geometry", function()
    local m = Memory.new(0x2000)
    m:write(0, string.rep("Q", 4096))
    m:write(0x1000, string.rep("Z", 4096))
    eq(m:allocated_pages(), 2, "pages allocated")
    eq(m:nonzero_bytes(), 8192, "non-zero bytes tracked")

    m:clear()
    eq(m:allocated_pages(), 0, "pages cleared")
    eq(m:nonzero_bytes(), 0, "non-zero counters cleared")
    eq(m:get_size(), 0x2000, "size preserved")
    eq(m:get_page_count(), 2, "page count preserved")
    eq(m:read(0, 4096), string.rep("\0", 4096), "reads zero again")
end)

test("re-writing the same byte does not allocate", function()
    local m = Memory.new(0x1000)
    m:write8(10, 0)
    eq(m:allocated_pages(), 0, "zero write sparse")

    m:write8(10, 7)
    eq(m:allocated_pages(), 1, "nonzero write allocates")
    m:write8(10, 7)
    eq(m:allocated_pages(), 1, "same value does not reallocate")
    eq(m:read8(10), 7, "value intact")
    eq(m:nonzero_bytes(), 1, "same value does not double count")
end)

test("zeroing the last non-zero byte releases the page", function()
    local m = Memory.new(0x2000)
    eq(m:nonzero_bytes(), 0, "fresh memory has no non-zero bytes")

    m:write8(0x123, 0xAA)
    eq(m:allocated_pages(), 1, "page allocated")
    eq(m:nonzero_bytes(), 1, "one non-zero byte")

    m:write8(0x123, 0)
    eq(m:allocated_pages(), 0, "page released")
    eq(m:nonzero_bytes(), 0, "counter back to zero")
    eq(m:read8(0x123), 0, "reads zero again")

    -- A partially zeroed page stays allocated (it still holds live bytes).
    m:write8(0x200, 1)
    m:write8(0x201, 2)
    m:write8(0x200, 0)
    eq(m:allocated_pages(), 1, "page kept while it has live bytes")
    eq(m:nonzero_bytes(), 1, "one live byte left")
    m:write8(0x201, 0)
    eq(m:allocated_pages(), 0, "page released after the last byte")
end)

test("block writes that zero a page release it", function()
    local m = Memory.new(0x3000)
    m:write(0x010, string.rep("\2", 100))
    eq(m:allocated_pages(), 1, "page allocated")
    eq(m:nonzero_bytes(), 100, "100 non-zero bytes")

    m:write(0x010, string.rep("\0", 100))
    eq(m:allocated_pages(), 0, "page released by the zero block")
    eq(m:nonzero_bytes(), 0, "counter cleared")

    -- A zero block over untouched memory must stay sparse.
    m:write(0x1000, string.rep("\0", 512))
    eq(m:allocated_pages(), 0, "zero block does not allocate")

    -- A block spanning two pages with embedded zeros.
    local mixed = string.rep("\0", 8) .. string.rep("\3", 4)
        .. string.rep("\0", 20)
    m:write(0xFF8, mixed)
    eq(m:allocated_pages(), 1, "only the page with live bytes is kept")
    eq(m:nonzero_bytes(), 4, "four non-zero bytes")
    m:write(0x1000, string.rep("\0", 4))
    eq(m:allocated_pages(), 0, "page released again")
    eq(m:nonzero_bytes(), 0, "no live bytes")
end)

test("fill with zero releases pages", function()
    local m = Memory.new(0x3000)
    m:fill(0x1000, 4096, 0x7F)
    eq(m:allocated_pages(), 1, "page allocated by fill")
    eq(m:nonzero_bytes(), 4096, "whole page non-zero")

    m:fill(0x1000, 4096, 0)
    eq(m:allocated_pages(), 0, "filled-zero page released")
    eq(m:nonzero_bytes(), 0, "counter cleared")

    m:fill(0x1000, 100, 0x11)
    m:fill(0x1000, 40, 0)
    eq(m:nonzero_bytes(), 60, "partial zero keeps the live bytes")
    eq(m:allocated_pages(), 1, "page still allocated")
    m:fill(0x1000, 100, 0)
    eq(m:allocated_pages(), 0, "page released after full zero")
end)

test("non-zero accounting across page boundaries", function()
    local m = Memory.new(0x3000)
    m:write16(0xFFF, 0x0102)
    eq(m:allocated_pages(), 2, "both pages allocated")
    eq(m:nonzero_bytes(), 2, "two non-zero bytes")

    m:write16(0xFFF, 0)
    eq(m:allocated_pages(), 0, "both pages released")
    eq(m:nonzero_bytes(), 0, "no non-zero bytes")

    m:write32(0x0FFE, 0x04030201)
    eq(m:allocated_pages(), 2, "32-bit write crosses pages")
    eq(m:nonzero_bytes(), 4, "four non-zero bytes")
    m:write32(0x0FFE, 0)
    eq(m:allocated_pages(), 0, "released again")
end)

test("block operations are capped by MAX_BLOCK", function()
    eq(Memory.MAX_BLOCK, 1048576, "MAX_BLOCK")

    local m = Memory.new(16 * 1024 * 1024)
    expect_error(function() m:read(0, Memory.MAX_BLOCK + 1) end,
        "MAX_BLOCK")
    expect_error(function()
        m:write(0, string.rep("\1", Memory.MAX_BLOCK + 1))
    end, "MAX_BLOCK")
    expect_error(function() m:fill(0, Memory.MAX_BLOCK + 1, 0) end,
        "MAX_BLOCK")
    expect_error(function() m:copy(0, 0, Memory.MAX_BLOCK + 1) end,
        "MAX_BLOCK")

    -- Exactly the cap is still allowed.
    eq(#m:read(0, Memory.MAX_BLOCK), Memory.MAX_BLOCK, "read at the cap")
end)

test("bounds errors report awkward numbers without failing", function()
    local m = Memory.new(100)
    local err = expect_error(function() m:read(99, 2) end,
        "out-of-bounds")
    contains(tostring(err), "len=2", "length is reported")
    contains(tostring(err), "size=100", "size is reported")

    -- A 32-bit-sized address must be formatted, not crash on %d.
    err = expect_error(function() m:read(4294967295, 1) end,
        "out-of-bounds")
    contains(tostring(err), "0xFFFFFFFF", "address formatted in hex")

    -- Non-integer lengths are rejected before any formatting happens.
    err = expect_error(function() m:read(0, 1 / 0) end,
        "non-negative integer")
    contains(tostring(err), "inf", "infinity is visible in the message")
end)

---------------------------------------------------------------------------

print(string.format("memory_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d memory test(s) failed", failed), 0)
end

return true
