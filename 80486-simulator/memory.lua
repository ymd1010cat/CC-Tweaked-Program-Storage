---------------------------------------------------------------------------
-- 80486-simulator/memory.lua
--
-- Sparse 16 MiB byte-addressable memory for CC:Tweaked / CraftOS.
--
-- Storage model:
--   * The address space is split into 4096-byte pages.
--   * A page is stored as one immutable Lua string of exactly 4096 bytes.
--   * An untouched page is nil and reads as zero.  This is important on a
--     CC computer: a full 16 MiB machine still starts out tiny.
--   * There is NO byte-indexed table backing the address space.
--   * Every allocated page carries an exact count of its non-zero bytes, so
--     writing zeros back over the last live bytes releases the page again
--     (the memory stays truly sparse instead of keeping all-zero pages).
--   * Block operations are capped at MAX_BLOCK bytes.  Reads/writes/fills/
--     copies above the cap raise instead of materialising huge strings.
--
-- All multi-byte values are little-endian, as required by the 80486.
-- No CPU cache / TLB behaviour is modelled here; this is functional memory.
--
-- Optional write protection: Memory.new(size, opts) accepts
-- opts.protect_start / opts.protect_end to mark a byte range (for example the
-- 0xF0000..0xFFFFF BIOS ROM window) that the write paths reject.  A write
-- that touches the protected range raises "Memory Write Protection Fault";
-- reads are never affected.  Memory.new(size) leaves protection disabled so
-- the module stays usable as a plain RAM object.
---------------------------------------------------------------------------

local PAGE_SIZE  = 4096
local PAGE_SHIFT = 12
local MAX_SIZE   = 16 * 1024 * 1024
local MAX_BLOCK  = 1024 * 1024
local PAGE_COUNT = MAX_SIZE / PAGE_SIZE
local ZERO_PAGE  = string.rep("\0", PAGE_SIZE)

local floor  = math.floor
local char   = string.char
local byte   = string.byte
local concat = table.concat

local Memory = {}
Memory.__index = Memory

---------------------------------------------------------------------------
-- Error helpers
---------------------------------------------------------------------------

local function fmt_number(v)
    if type(v) == "number" and v == v and v % 1 == 0
        and v >= 0 and v <= 4294967295 then
        return string.format("0x%X", v)
    end
    return tostring(v)
end

local function bounds_error(op, addr, len, size)
    -- No %d anywhere: string.format("%d", ...) is not safe on CraftOS for
    -- values outside the 32-bit integer range (and not at all for nil or
    -- non-integer lengths), which used to mask the real out-of-bounds
    -- diagnosis with a formatting error.  Addresses print in hex, lengths
    -- and sizes in decimal.
    error(string.format(
        "%s: out-of-bounds access addr=%s len=%s size=%s",
        op, fmt_number(addr), tostring(len), tostring(size)
    ), 0)
end

local function validate_length(op, len)
    if type(len) ~= "number" or len % 1 ~= 0 or len < 0 then
        error(string.format(
            "%s: length must be a non-negative integer (got %s)",
            op, tostring(len)
        ), 0)
    end
end

local function check_block(op, len)
    if len > MAX_BLOCK then
        error(string.format(
            "%s: block length %s exceeds MAX_BLOCK (%d bytes)",
            op, fmt_number(len), MAX_BLOCK
        ), 0)
    end
end

local function check_range(self, addr, len, op)
    -- addr % 1 also rejects NaN and infinities.
    if type(addr) ~= "number" or addr % 1 ~= 0 or addr < 0
        or addr + len > self._size then
        bounds_error(op, addr, len, self._size)
    end
end

local function check_value(op, value, max_value)
    if type(value) ~= "number" or value % 1 ~= 0
        or value < 0 or value > max_value then
        error(string.format(
            "%s: value must be an integer in 0..%s (got %s)",
            op, tostring(max_value), tostring(value)
        ), 0)
    end
end

-- Write protection.  Called by every write path after the range/value checks
-- and before any page is touched.  A zero-length write never faults.
local function check_write_protection(self, addr, len, op)
    local protect_start = self._protect_start
    if protect_start == nil or len <= 0 then
        return
    end
    local protect_end = self._protect_end
    if addr + len - 1 < protect_start or addr > protect_end then
        return
    end
    error(op .. ": Memory Write Protection Fault: addr="
        .. fmt_number(addr) .. " len=" .. tostring(len)
        .. " protected=" .. fmt_number(protect_start)
        .. ".." .. fmt_number(protect_end), 0)
end

---------------------------------------------------------------------------
-- Page primitives
---------------------------------------------------------------------------

-- 0..255.  addr must already be range-checked.
local function load8(self, addr)
    local page = self._pages[floor(addr / PAGE_SIZE) + 1]
    if page == nil then
        return 0
    end
    return byte(page, addr % PAGE_SIZE + 1)
end

-- Write one byte.  addr/value must already be validated.  The per-page
-- non-zero byte counter is updated so the page is released as soon as its
-- last non-zero byte is overwritten with zero.
local function store8(self, addr, value)
    local page_index = floor(addr / PAGE_SIZE) + 1
    local offset     = addr % PAGE_SIZE + 1
    local pages      = self._pages
    local counts     = self._nonzero
    local page       = pages[page_index]

    if page == nil then
        if value == 0 then
            -- Keep untouched pages sparse; zero is the implicit contents.
            return
        end
        pages[page_index] = ZERO_PAGE:sub(1, offset - 1)
            .. char(value)
            .. ZERO_PAGE:sub(offset + 1)
        counts[page_index] = 1
        return
    end

    if byte(page, offset) == value then
        return
    end

    local count = counts[page_index] or 0
    if value == 0 then
        count = count - 1
    else
        count = count + 1
    end

    if count <= 0 then
        -- The page became all zero: drop it so the memory stays sparse.
        pages[page_index] = nil
        counts[page_index] = nil
        return
    end

    pages[page_index] = page:sub(1, offset - 1)
        .. char(value)
        .. page:sub(offset + 1)
    counts[page_index] = count
end

-- Number of bytes in s that are not zero.  %z is Lua 5.1's pattern escape
-- for the NUL byte; gsub returns the substitution count as its second value.
local function count_nonzero(s)
    return select(2, s:gsub("[^%z]", ""))
end

-- Write a string of arbitrary length, rebuilding each touched page at most
-- once.  addr and #data must already be range-checked.  Per-page non-zero
-- counters are adjusted by comparing the replaced byte range, so writing
-- zeros over the last live bytes of a page frees that page.
local function store_bytes(self, addr, data)
    local len = #data
    if len == 0 then
        return
    end

    local pages  = self._pages
    local counts = self._nonzero
    local pos    = 1

    while pos <= len do
        local a          = addr + pos - 1
        local page_index = floor(a / PAGE_SIZE) + 1
        local offset     = a % PAGE_SIZE + 1
        local n          = PAGE_SIZE - offset + 1
        local left       = len - pos + 1
        if n > left then
            n = left
        end

        local chunk = data:sub(pos, pos + n - 1)
        local base  = pages[page_index]
        local old_count = 0
        if base ~= nil then
            old_count = count_nonzero(base:sub(offset, offset + n - 1))
        end
        local new_count = count_nonzero(chunk)
        local total = (counts[page_index] or 0) - old_count + new_count

        if offset == 1 and n == PAGE_SIZE then
            -- Whole page: strings are immutable, so share the new string.
            if total == 0 then
                pages[page_index] = nil
                counts[page_index] = nil
            else
                pages[page_index] = chunk
                counts[page_index] = total
            end
        elseif base == nil then
            if total > 0 then
                pages[page_index] = ZERO_PAGE:sub(1, offset - 1)
                    .. chunk
                    .. ZERO_PAGE:sub(offset + n)
                counts[page_index] = total
            end
        else
            local new_page = base:sub(1, offset - 1)
                .. chunk
                .. base:sub(offset + n)
            if total == 0 then
                pages[page_index] = nil
                counts[page_index] = nil
            else
                pages[page_index] = new_page
                counts[page_index] = total
            end
        end

        pos = pos + n
    end
end

---------------------------------------------------------------------------
-- Construction / introspection
---------------------------------------------------------------------------

function Memory.new(size, opts)
    if size == nil then
        size = MAX_SIZE
    end
    if type(size) ~= "number" or size % 1 ~= 0
        or size < 1 or size > MAX_SIZE then
        error(string.format(
            "memory.new: size must be an integer in 1..%d (got %s)",
            MAX_SIZE, tostring(size)
        ), 0)
    end

    local protect_start, protect_end
    if opts ~= nil then
        if type(opts) ~= "table" then
            error("memory.new: opts must be a table (got "
                .. type(opts) .. ")", 0)
        end
        protect_start = opts.protect_start
        protect_end = opts.protect_end
        if (protect_start == nil) ~= (protect_end == nil) then
            error("memory.new: protect_start and protect_end must be "
                .. "given together", 0)
        end
        if protect_start ~= nil then
            if type(protect_start) ~= "number" or protect_start % 1 ~= 0
                or type(protect_end) ~= "number" or protect_end % 1 ~= 0 then
                error("memory.new: protect_start and protect_end must be "
                    .. "integers", 0)
            end
            if protect_start < 0 or protect_end < protect_start
                or protect_end >= size then
                error("memory.new: write protection range "
                    .. fmt_number(protect_start) .. ".."
                    .. fmt_number(protect_end) .. " does not fit in "
                    .. tostring(size) .. " bytes of memory", 0)
            end
        end
    end

    return setmetatable({
        _size          = size,
        _page_count    = floor((size + PAGE_SIZE - 1) / PAGE_SIZE),
        _pages         = {},
        _nonzero       = {},
        _protect_start = protect_start,
        _protect_end   = protect_end,
    }, Memory)
end

-- Replaces the protected window; pass nil to disable protection.
function Memory:set_write_protection(protect_start, protect_end)
    if protect_start == nil then
        self._protect_start = nil
        self._protect_end = nil
        return self
    end
    if type(protect_start) ~= "number" or protect_start % 1 ~= 0
        or type(protect_end) ~= "number" or protect_end % 1 ~= 0 then
        error("memory.set_write_protection: range bounds must be integers", 0)
    end
    if protect_start < 0 or protect_end < protect_start
        or protect_end >= self._size then
        error("memory.set_write_protection: range "
            .. fmt_number(protect_start) .. ".." .. fmt_number(protect_end)
            .. " does not fit in " .. tostring(self._size) .. " bytes", 0)
    end
    self._protect_start = protect_start
    self._protect_end = protect_end
    return self
end

-- Returns protect_start, protect_end (both nil when protection is off).
function Memory:get_write_protection()
    return self._protect_start, self._protect_end
end

function Memory:get_size()
    return self._size
end

function Memory:get_page_count()
    return self._page_count
end

-- Useful for tests / diagnostics, not part of the CPU hot path.
function Memory:allocated_pages()
    local n = 0
    for _ in pairs(self._pages) do
        n = n + 1
    end
    return n
end

-- Total number of non-zero bytes currently held by allocated pages.
-- Zero for a freshly created (or fully zeroed) memory.
function Memory:nonzero_bytes()
    local n = 0
    for _, count in pairs(self._nonzero) do
        n = n + count
    end
    return n
end

function Memory:clear()
    self._pages   = {}
    self._nonzero = {}
    return self
end

---------------------------------------------------------------------------
-- 8 / 16 / 32-bit reads
---------------------------------------------------------------------------

function Memory:read8(addr)
    check_range(self, addr, 1, "memory.read8")
    return load8(self, addr)
end

function Memory:read16(addr)
    check_range(self, addr, 2, "memory.read16")

    local offset = addr % PAGE_SIZE
    if offset <= PAGE_SIZE - 2 then
        local page = self._pages[floor(addr / PAGE_SIZE) + 1]
        if page == nil then
            return 0
        end
        local b1, b2 = byte(page, offset + 1, offset + 2)
        return b1 + b2 * 256
    end

    local b1 = load8(self, addr)
    local b2 = load8(self, addr + 1)
    return b1 + b2 * 256
end

function Memory:read32(addr)
    check_range(self, addr, 4, "memory.read32")

    local offset = addr % PAGE_SIZE
    if offset <= PAGE_SIZE - 4 then
        local page = self._pages[floor(addr / PAGE_SIZE) + 1]
        if page == nil then
            return 0
        end
        local b1, b2, b3, b4 = byte(page, offset + 1, offset + 4)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    local b1 = load8(self, addr)
    local b2 = load8(self, addr + 1)
    local b3 = load8(self, addr + 2)
    local b4 = load8(self, addr + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

---------------------------------------------------------------------------
-- 8 / 16 / 32-bit writes
---------------------------------------------------------------------------

function Memory:write8(addr, value)
    check_range(self, addr, 1, "memory.write8")
    check_value("memory.write8", value, 255)
    check_write_protection(self, addr, 1, "memory.write8")
    store8(self, addr, value)
    return self
end

function Memory:write16(addr, value)
    check_range(self, addr, 2, "memory.write16")
    check_value("memory.write16", value, 65535)
    check_write_protection(self, addr, 2, "memory.write16")

    local b1 = value % 256
    local b2 = (value - b1) / 256
    store_bytes(self, addr, char(b1, b2))
    return self
end

function Memory:write32(addr, value)
    check_range(self, addr, 4, "memory.write32")
    check_value("memory.write32", value, 4294967295)
    check_write_protection(self, addr, 4, "memory.write32")

    local b1 = value % 256
    local b2 = floor(value / 256) % 256
    local b3 = floor(value / 65536) % 256
    local b4 = floor(value / 16777216) % 256
    store_bytes(self, addr, char(b1, b2, b3, b4))
    return self
end

---------------------------------------------------------------------------
-- Block operations
---------------------------------------------------------------------------

function Memory:read(addr, len)
    validate_length("memory.read", len)
    check_block("memory.read", len)
    check_range(self, addr, len, "memory.read")
    if len == 0 then
        return ""
    end

    local parts = {}
    local pos   = 0

    while pos < len do
        local a          = addr + pos
        local page_index = floor(a / PAGE_SIZE) + 1
        local offset     = a % PAGE_SIZE + 1
        local n          = PAGE_SIZE - offset + 1
        local left       = len - pos
        if n > left then
            n = left
        end

        local page = self._pages[page_index]

        if page == nil then
            if offset == 1 and n == PAGE_SIZE then
                parts[#parts + 1] = ZERO_PAGE
            else
                parts[#parts + 1] = ZERO_PAGE:sub(1, n)
            end
        elseif offset == 1 and n == PAGE_SIZE then
            parts[#parts + 1] = page
        else
            parts[#parts + 1] = page:sub(offset, offset + n - 1)
        end

        pos = pos + n
    end

    return concat(parts)
end

function Memory:write(addr, data)
    if type(data) ~= "string" then
        error("memory.write: data must be a string (got "
            .. type(data) .. ")", 0)
    end
    check_block("memory.write", #data)
    check_range(self, addr, #data, "memory.write")
    check_write_protection(self, addr, #data, "memory.write")
    store_bytes(self, addr, data)
    return self
end

function Memory:fill(addr, len, value)
    validate_length("memory.fill", len)
    check_block("memory.fill", len)
    check_range(self, addr, len, "memory.fill")
    check_value("memory.fill", value, 255)
    check_write_protection(self, addr, len, "memory.fill")

    if len == 0 then
        return self
    end

    local ch        = char(value)
    local full_page = nil
    local pages     = self._pages
    local counts    = self._nonzero
    local pos       = 0

    while pos < len do
        local a          = addr + pos
        local page_index = floor(a / PAGE_SIZE) + 1
        local offset     = a % PAGE_SIZE + 1
        local n          = PAGE_SIZE - offset + 1
        local left       = len - pos
        if n > left then
            n = left
        end

        local base = pages[page_index]
        local old_count = 0
        if base ~= nil then
            old_count = count_nonzero(base:sub(offset, offset + n - 1))
        end
        local added = 0
        if value ~= 0 then
            added = n
        end
        local total = (counts[page_index] or 0) - old_count + added

        if offset == 1 and n == PAGE_SIZE then
            if value == 0 then
                pages[page_index] = nil
                counts[page_index] = nil
            else
                if full_page == nil then
                    full_page = string.rep(ch, PAGE_SIZE)
                end
                pages[page_index] = full_page
                counts[page_index] = total
            end
        elseif base == nil then
            if total > 0 then
                pages[page_index] = ZERO_PAGE:sub(1, offset - 1)
                    .. string.rep(ch, n)
                    .. ZERO_PAGE:sub(offset + n)
                counts[page_index] = total
            end
        else
            local new_page = base:sub(1, offset - 1)
                .. string.rep(ch, n)
                .. base:sub(offset + n)
            if total == 0 then
                pages[page_index] = nil
                counts[page_index] = nil
            else
                pages[page_index] = new_page
                counts[page_index] = total
            end
        end

        pos = pos + n
    end

    return self
end

-- memmove semantics.  Overlapping copies are safe.  The destination range is
-- write-protected exactly like write(): copying into it raises.
function Memory:copy(dst, src, len)
    validate_length("memory.copy", len)
    check_block("memory.copy", len)
    check_range(self, dst, len, "memory.copy(dst)")
    check_range(self, src, len, "memory.copy(src)")
    check_write_protection(self, dst, len, "memory.copy(dst)")

    if len == 0 or dst == src then
        return self
    end

    -- When dst is above src and the ranges overlap, copy backwards.
    local backwards = dst > src and dst < src + len

    if backwards then
        local remaining = len
        while remaining > 0 do
            local n   = remaining < PAGE_SIZE and remaining or PAGE_SIZE
            local off = remaining - n
            self:write(dst + off, self:read(src + off, n))
            remaining = off
        end
    else
        local pos = 0
        while pos < len do
            local n = len - pos
            if n > PAGE_SIZE then
                n = PAGE_SIZE
            end
            self:write(dst + pos, self:read(src + pos, n))
            pos = pos + n
        end
    end

    return self
end

-- Explicit alias for the CPU/BIOS layers; identical memmove semantics.
Memory.memmove = Memory.copy

---------------------------------------------------------------------------
-- Public module
---------------------------------------------------------------------------

return {
    PAGE_SIZE  = PAGE_SIZE,
    PAGE_SHIFT = PAGE_SHIFT,
    PAGE_COUNT = PAGE_COUNT,
    MAX_SIZE   = MAX_SIZE,
    MAX_BLOCK  = MAX_BLOCK,
    Memory     = Memory,
    new        = function(size, opts)
        return Memory.new(size, opts)
    end,
}
