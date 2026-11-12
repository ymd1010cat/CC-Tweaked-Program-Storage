---------------------------------------------------------------------------
-- 80486-simulator/vga.lua
--
-- Text-mode VGA framebuffer for the 80486 simulator.
--
-- The VGA text plane of a PC lives in main memory at 0xB8000: 80 columns by
-- 25 rows, two bytes per cell (character code, then attribute).  This module
-- owns exactly that mapping.  It does not emulate any VGA register, any
-- graphics mode or any hardware detail beyond the text plane; the attribute
-- byte is interpreted as the usual palette (low nibble = foreground, high
-- nibble = background).
--
-- The framebuffer lives in the memory object that is passed in:
--
--     local vga = Vga.new{ memory = memory }
--     vga:write_cell(0, 0, "H", 0x1F)
--     assert(vga:read_char(0, 0) == "H")
--     assert(vga:read_attr(0, 0) == 0x1F)
--
-- Nothing is cached on the Lua side: every read and write goes to the memory
-- object, so the CPU sees exactly the same bytes and a test can prove that
-- the screen really comes from 0xB8000.
--
-- Rendering onto a CraftOS terminal
-- ---------------------------------
--     vga:render(term)          -- term is optional, _G.term is the default
--
-- Only the top-left rectangle that fits the terminal is painted:
-- min(vga width, term width) by min(vga height, term height).  Each row is
-- drawn with term.setCursorPos(1, row) followed by term.blit(text, fg, bg),
-- which is the fast path on CC:Tweaked.  When a terminal has no blit() (a
-- fake terminal in a test, for example) the renderer falls back to
-- setTextColor/setBackgroundColor/write.  A terminal that supports neither
-- is a hard error: the renderer never pretends to have drawn something.
--
-- Colour mapping
-- --------------
-- VGA colour indices are translated to the CC:Tweaked colour letters
-- (0-9/a-f).  0x07 (light grey on black) therefore renders as fg "7" /
-- bg "f", and 0x1F (white on blue) as fg "0" / bg "b".  See Vga.COLOR.
--
-- Character mapping
-- -----------------
-- Codes 32..126 are used as-is.  Control codes (0..31 and 127) render as
-- ".".  Codes 128..255 render as readable ASCII approximations (a CP437
-- style table, for example 0xDB -> "#", 0xC4 -> "-", 0xB3 -> "|"), because a
-- CraftOS terminal cannot show the original glyphs.  The character code in
-- memory is never rewritten by read_char(); only the returned display glyph
-- is approximated.
--
-- Conventions: CraftOS Lua 5.1 (no bitwise operators, no goto, no //),
-- pure ASCII source, four-space indent, everything local.
---------------------------------------------------------------------------

local floor  = math.floor
local char   = string.char
local byte   = string.byte
local sub    = string.sub
local rep    = string.rep
local concat = table.concat

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local BASE      = 0xB8000
local WIDTH     = 80
local HEIGHT    = 25
local CELL_SIZE = 2

---------------------------------------------------------------------------
-- VGA colour index -> CC:Tweaked colour letter.
--
-- The low half is the standard IBM palette.  The bright half is mapped onto
-- the closest CC colour, since CC has no separate bright variants; note that
-- 0x07 (light grey) must stay "7" so that the default attribute 0x07 comes
-- out as grey-on-black on a CC screen.
---------------------------------------------------------------------------

local COLOR = {
    [0] = "f", -- black
    "b",       -- blue
    "d",       -- green
    "9",       -- cyan
    "e",       -- red
    "a",       -- magenta (closest CC colour is "purple")
    "c",       -- brown
    "7",       -- light grey -> CC grey
    "8",       -- dark grey -> CC light grey
    "3",       -- bright blue -> CC light blue
    "5",       -- bright green -> CC lime
    "9",       -- bright cyan -> CC cyan
    "e",       -- bright red -> CC red
    "2",       -- bright magenta -> CC magenta
    "4",       -- yellow
    "0",       -- white
}

---------------------------------------------------------------------------
-- CP437 (codes 128..255) -> readable single-byte ASCII approximations.
-- Anything the terminal cannot draw degrades to a glyph with a similar
-- shape instead of disappearing.
---------------------------------------------------------------------------

local HIGH_GLYPHS = {}

local function fill_glyphs(first, glyphs)
    for i = 1, #glyphs do
        HIGH_GLYPHS[first + i - 1] = sub(glyphs, i, i)
    end
end

-- 0x80..0x9F: accented letters and a few symbols.
fill_glyphs(0x80, "CueaaaaceeeiiiAAEeEooouuyOUcLYPf")
-- 0xA0..0xAF: more accents, inverted question/exclamation, fractions.
fill_glyphs(0xA0, "aionuNao?--24!<>")
-- 0xB0..0xDF: shading and box drawing.  Shading becomes "#", horizontal
-- lines become "-", vertical lines become "|" and every junction becomes
-- "+", so boxes are still recognisable in a terminal.
fill_glyphs(0xB0, "###|++++" .. "++|+++++" .. "++++-+++" .. "+++++=++"
    .. "++++++++" .. "+++#####")
-- 0xE0..0xFF: Greek letters, mathematical symbols and the solid block.
fill_glyphs(0xE0, "abGpSsut" .. "PTOdopen" .. "=+><++/~" .. "o..vn2#"
    .. " ")

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function glyph(code)
    if code < 32 or code == 127 then
        -- Control codes have no visible glyph in a text plane.
        return "."
    end
    if code < 127 then
        return char(code)
    end
    return HIGH_GLYPHS[code] or "?"
end

local function is_integer(value)
    return type(value) == "number" and value == value and value % 1 == 0
end

local function check_integer(where, name, value)
    if not is_integer(value) then
        error(string.format("%s: %s must be an integer (got %s)",
            where, name, tostring(value)), 0)
    end
end

local function check_attr(where, attr)
    if not is_integer(attr) or attr < 0 or attr > 255 then
        error(string.format("%s: attribute must be an integer 0..255 (got %s)",
            where, tostring(attr)), 0)
    end
end

local function check_cell(self, row, col, where)
    if not is_integer(row) or row < 0 or row >= self.height then
        error(string.format("%s: row %s out of range 0..%d",
            where, tostring(row), self.height - 1), 0)
    end
    if not is_integer(col) or col < 0 or col >= self.width then
        error(string.format("%s: column %s out of range 0..%d",
            where, tostring(col), self.width - 1), 0)
    end
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

local Vga = {}
Vga.__index = Vga

Vga.BASE      = BASE
Vga.WIDTH     = WIDTH
Vga.HEIGHT    = HEIGHT
Vga.CELL_SIZE = CELL_SIZE
Vga.COLOR     = COLOR
Vga.glyph     = glyph

function Vga.fg_color(attr)
    check_attr("Vga.fg_color", attr)
    return COLOR[attr % 16]
end

function Vga.bg_color(attr)
    check_attr("Vga.bg_color", attr)
    return COLOR[floor(attr / 16) % 16]
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Vga.new(opts)
    if type(opts) ~= "table" then
        error("VGA.new: an options table is required", 0)
    end
    local memory = opts.memory
    if type(memory) ~= "table" then
        error("VGA.new: opts.memory is required", 0)
    end
    if type(memory.read8) ~= "function" or type(memory.write8) ~= "function"
        or type(memory.read) ~= "function" or type(memory.write) ~= "function"
    then
        error("VGA.new: opts.memory must provide read8/write8/read/write", 0)
    end

    local width  = opts.width
    local height = opts.height
    local base   = opts.base
    local attr   = opts.attr
    if width == nil then width = WIDTH end
    if height == nil then height = HEIGHT end
    if base == nil then base = BASE end
    if attr == nil then attr = 0x07 end

    check_integer("VGA.new", "width", width)
    check_integer("VGA.new", "height", height)
    check_integer("VGA.new", "base", base)
    check_attr("VGA.new", attr)
    if width < 1 or height < 1 then
        error(string.format("VGA.new: width and height must be positive "
            .. "(got %dx%d)", width, height), 0)
    end
    if base < 0 then
        error(string.format("VGA.new: base must be non-negative (got %d)",
            base), 0)
    end

    local size = width * height * CELL_SIZE
    if type(memory.get_size) == "function" then
        local mem_size = memory:get_size()
        if base + size > mem_size then
            error(string.format("VGA.new: framebuffer 0x%X..0x%X does not "
                .. "fit in %d bytes of memory", base, base + size - 1,
                mem_size), 0)
        end
    end

    return setmetatable({
        memory     = memory,
        width      = width,
        height     = height,
        base       = base,
        attr       = attr,
        cursor_row = 0,
        cursor_col = 0,
    }, Vga)
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

function Vga:get_width()
    return self.width
end

function Vga:get_height()
    return self.height
end

function Vga:get_base()
    return self.base
end

function Vga:cell_offset(row, col)
    check_cell(self, row, col, "VGA.cell_offset")
    return self.base + (row * self.width + col) * CELL_SIZE
end

---------------------------------------------------------------------------
-- Cell access
---------------------------------------------------------------------------

function Vga:read_char(row, col)
    return glyph(self.memory:read8(self:cell_offset(row, col)))
end

function Vga:read_attr(row, col)
    return self.memory:read8(self:cell_offset(row, col) + 1)
end

function Vga:write_cell(row, col, ch, attr)
    local offset = self:cell_offset(row, col)
    local code
    local kind = type(ch)
    if kind == "number" then
        if not is_integer(ch) or ch < 0 or ch > 255 then
            error(string.format("VGA.write_cell: character code must be an "
                .. "integer 0..255 (got %s)", tostring(ch)), 0)
        end
        code = ch
    elseif kind == "string" then
        if #ch ~= 1 then
            error(string.format("VGA.write_cell: character string must be "
                .. "exactly one byte (got %d bytes)", #ch), 0)
        end
        code = byte(ch)
    else
        error(string.format("VGA.write_cell: character must be a string or "
            .. "a byte (got %s)", kind), 0)
    end

    local value = attr
    if value == nil then value = self.attr end
    check_attr("VGA.write_cell", value)

    self.memory:write8(offset, code)
    self.memory:write8(offset + 1, value)
end

function Vga:clear(attr)
    local value = attr
    if value == nil then value = self.attr end
    check_attr("VGA.clear", value)

    local row_data = rep(char(32, value), self.width)
    local row_bytes = self.width * CELL_SIZE
    for row = 0, self.height - 1 do
        self.memory:write(self.base + row * row_bytes, row_data)
    end
end

function Vga:read_line(row)
    check_cell(self, row, 0, "VGA.read_line")
    local parts = {}
    for col = 0, self.width - 1 do
        parts[col + 1] = self:read_char(row, col)
    end
    return concat(parts)
end

function Vga:snapshot()
    local rows = {}
    local attrs = {}
    local row_bytes = self.width * CELL_SIZE
    for row = 0, self.height - 1 do
        local data = self.memory:read(self.base + row * row_bytes, row_bytes)
        local chars = {}
        local cell_attrs = {}
        for col = 0, self.width - 1 do
            local offset = col * CELL_SIZE + 1
            chars[col + 1] = glyph(byte(data, offset))
            cell_attrs[col + 1] = sub(data, offset + 1, offset + 1)
        end
        rows[row + 1] = concat(chars)
        attrs[row + 1] = concat(cell_attrs)
    end
    return {width = self.width, height = self.height, rows = rows, attrs = attrs}
end

---------------------------------------------------------------------------
-- Cursor
---------------------------------------------------------------------------

function Vga:set_cursor(row, col)
    check_integer("VGA.set_cursor", "row", row)
    check_integer("VGA.set_cursor", "column", col)
    if row < 0 then row = 0 end
    if col < 0 then col = 0 end
    if row > self.height - 1 then row = self.height - 1 end
    if col > self.width - 1 then col = self.width - 1 end
    self.cursor_row = row
    self.cursor_col = col
end

function Vga:get_cursor()
    return self.cursor_row, self.cursor_col
end

---------------------------------------------------------------------------
-- Scrolling
---------------------------------------------------------------------------

function Vga:scroll_up(lines, attr)
    local count = lines
    if count == nil then count = 1 end
    if not is_integer(count) or count < 0 then
        error(string.format("VGA.scroll_up: line count must be a "
            .. "non-negative integer (got %s)", tostring(count)), 0)
    end
    local value = attr
    if value == nil then value = self.attr end
    check_attr("VGA.scroll_up", value)

    if count == 0 then
        return
    end
    if count >= self.height then
        self:clear(value)
        return
    end

    local row_bytes = self.width * CELL_SIZE
    local kept = self.height - count
    local data = self.memory:read(self.base + count * row_bytes,
        kept * row_bytes)
    self.memory:write(self.base, data)

    local blank_row = rep(char(32, value), self.width)
    self.memory:write(self.base + kept * row_bytes,
        rep(blank_row, count))
end

---------------------------------------------------------------------------
-- Rendering onto a CC:Tweaked terminal
---------------------------------------------------------------------------

local function term_get_size(target)
    if type(target.getSize) ~= "function" then
        error("VGA.render: terminal has no getSize() method", 0)
    end
    local width, height = target.getSize()
    if not is_integer(width) or not is_integer(height)
        or width < 1 or height < 1
    then
        error(string.format("VGA.render: terminal size %s x %s is invalid",
            tostring(width), tostring(height)), 0)
    end
    return width, height
end

function Vga:render(term, opts)
    local target = term
    if target == nil and type(opts) == "table" then
        target = opts.term
    end
    if target == nil then
        target = _G.term
    end
    if target == nil then
        -- Nothing to draw on; explicitly report that nothing was painted.
        return 0, 0
    end
    if type(target) ~= "table" then
        error(string.format("VGA.render: terminal must be a table (got %s)",
            type(target)), 0)
    end

    local term_width, term_height = term_get_size(target)
    if type(target.setCursorPos) ~= "function" then
        error("VGA.render: terminal has no setCursorPos() method", 0)
    end
    local cols = math.min(self.width, term_width)
    local rows = math.min(self.height, term_height)
    if cols < 1 or rows < 1 then
        return 0, 0
    end

    local use_blit = type(target.blit) == "function"
    local set_fg = target.setTextColor or target.setTextColour
    local set_bg = target.setBackgroundColor or target.setBackgroundColour
    if not use_blit then
        if type(set_fg) ~= "function" or type(set_bg) ~= "function"
            or type(target.write) ~= "function"
        then
            error("VGA.render: terminal supports neither blit() nor "
                .. "setTextColor()/setBackgroundColor()/write()", 0)
        end
    end

    local row_bytes = self.width * CELL_SIZE
    local set_cursor_pos = target.setCursorPos
    for row = 0, rows - 1 do
        local data = self.memory:read(self.base + row * row_bytes, row_bytes)
        local chars = {}
        local fgs = {}
        local bgs = {}
        for col = 0, cols - 1 do
            local offset = col * CELL_SIZE + 1
            local attr = byte(data, offset + 1)
            chars[col + 1] = glyph(byte(data, offset))
            fgs[col + 1] = COLOR[attr % 16]
            bgs[col + 1] = COLOR[floor(attr / 16) % 16]
        end

        set_cursor_pos(1, row + 1)
        if use_blit then
            target.blit(concat(chars), concat(fgs), concat(bgs))
        else
            local current_fg = nil
            local current_bg = nil
            for col = 1, cols do
                if fgs[col] ~= current_fg then
                    current_fg = fgs[col]
                    set_fg(tonumber(current_fg, 16))
                end
                if bgs[col] ~= current_bg then
                    current_bg = bgs[col]
                    set_bg(tonumber(current_bg, 16))
                end
                target.write(chars[col])
            end
        end
    end

    -- Put the terminal cursor where the VGA cursor is, clamped to the part
    -- of the framebuffer that is actually visible on this terminal.
    local cursor_row, cursor_col = self:get_cursor()
    if cursor_row > rows - 1 then cursor_row = rows - 1 end
    if cursor_col > cols - 1 then cursor_col = cols - 1 end
    if cursor_row < 0 then cursor_row = 0 end
    if cursor_col < 0 then cursor_col = 0 end
    set_cursor_pos(cursor_col + 1, cursor_row + 1)

    return cols, rows
end

return Vga
