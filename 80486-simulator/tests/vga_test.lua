---------------------------------------------------------------------------
-- 80486-simulator/tests/vga_test.lua
--
-- Standalone tests for vga.lua.  No test framework is required.
--
-- From the repository root:
--     lua 80486-simulator/tests/vga_test.lua
-- or, inside CraftOS:
--     dofile("/tests/vga_test.lua")
--
-- The renderer is exercised against a fake CraftOS terminal: it records the
-- character, foreground colour and background colour of every cell, plus
-- every blit() call, so the tests can prove what was drawn where.
---------------------------------------------------------------------------

local char   = string.char
local byte   = string.byte
local rep    = string.rep
local sub    = string.sub

---------------------------------------------------------------------------
-- Module loading
---------------------------------------------------------------------------

local function load_module(name, is_module)
    local ok, mod = pcall(require, name)
    if ok and is_module(mod) then
        return mod
    end

    -- Make the test runnable from the repo root, from 80486-simulator/,
    -- from 80486-simulator/tests/ or from inside CraftOS.
    local candidates = {
        "80486-simulator/" .. name .. ".lua",
        "../" .. name .. ".lua",
        name .. ".lua",
        "/80486-simulator/" .. name .. ".lua",
        "/" .. name .. ".lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and is_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load " .. name .. ".lua: " .. tostring(last_error))
end

local function is_memory_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.PAGE_SIZE == 4096
end

local function is_vga_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.BASE == 0xB8000
        and mod.WIDTH == 80
        and mod.HEIGHT == 25
        and mod.CELL_SIZE == 2
end

local Memory = load_module("memory", is_memory_module)
local Vga = load_module("vga", is_vga_module)

---------------------------------------------------------------------------
-- Test bookkeeping
---------------------------------------------------------------------------

local total   = 0
local passed  = 0
local skipped = 0
local failed  = 0

local function show(value)
    if type(value) == "string" then
        if #value <= 60 then
            return string.format("%q", value)
        end
        return string.format("<string len=%d>", #value)
    end
    if type(value) == "number" then
        return string.format("%d (0x%X)", value, value)
    end
    return tostring(value)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not text:find(needle, 1, true) then
        error(string.format("%s: %s does not contain %q",
            label or "text", show(text), needle), 2)
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

local function skip(reason)
    error({__skip = reason}, 0)
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        if type(err) == "table" and err.__skip ~= nil then
            skipped = skipped + 1
            print("skip " .. name .. " (" .. tostring(err.__skip) .. ")")
        else
            failed = failed + 1
            print("FAIL " .. name)
            print("     " .. tostring(err))
        end
    end
end

---------------------------------------------------------------------------
-- Fake CraftOS terminal
--
-- Cells start out as "?" so a test can tell what the renderer actually
-- painted from what it left alone.  The functions are plain functions
-- without a self argument, exactly like the real CraftOS term API.
---------------------------------------------------------------------------

local function new_term(width, height)
    local term = {
        width       = width,
        height      = height,
        cells       = {},
        fg          = {},
        bg          = {},
        blits       = 0,
        writes      = 0,
        blit_sizes  = {},
        set_fg      = {},
        set_bg      = {},
        cursor_x    = 1,
        cursor_y    = 1,
        cursor_sets = 0,
    }
    for row = 1, height do
        term.cells[row] = {}
        term.fg[row] = {}
        term.bg[row] = {}
        for col = 1, width do
            term.cells[row][col] = "?"
            term.fg[row][col] = "?"
            term.bg[row][col] = "?"
        end
    end

    function term.getSize()
        return term.width, term.height
    end

    function term.setCursorPos(x, y)
        term.cursor_sets = term.cursor_sets + 1
        term.cursor_x = x
        term.cursor_y = y
    end

    function term.getCursorPos()
        return term.cursor_x, term.cursor_y
    end

    function term.blit(text, text_fg, text_bg)
        term.blits = term.blits + 1
        term.blit_sizes[#term.blit_sizes + 1] = #text
        local row = term.cursor_y
        local col = term.cursor_x
        for i = 1, #text do
            local cell_col = col + i - 1
            if row >= 1 and row <= term.height
                and cell_col >= 1 and cell_col <= term.width
            then
                term.cells[row][cell_col] = sub(text, i, i)
                term.fg[row][cell_col] = sub(text_fg, i, i)
                term.bg[row][cell_col] = sub(text_bg, i, i)
            end
        end
        term.cursor_x = col + #text
    end

    function term.write(text)
        term.writes = term.writes + 1
        local row = term.cursor_y
        local col = term.cursor_x
        for i = 1, #text do
            local cell_col = col + i - 1
            if row >= 1 and row <= term.height
                and cell_col >= 1 and cell_col <= term.width
            then
                term.cells[row][cell_col] = sub(text, i, i)
            end
        end
        term.cursor_x = col + #text
    end

    return term
end

-- A terminal that has no blit(); the renderer must fall back to
-- setTextColor / setBackgroundColor / write.
local function new_plain_term(width, height)
    local term = {
        width            = width,
        height           = height,
        cells            = {},
        fg               = {},
        bg               = {},
        writes           = 0,
        set_fg_calls     = 0,
        set_bg_calls     = 0,
        last_fg          = nil,
        last_bg          = nil,
        cursor_x         = 1,
        cursor_y         = 1,
    }
    for row = 1, height do
        term.cells[row] = {}
        term.fg[row] = {}
        term.bg[row] = {}
        for col = 1, width do
            term.cells[row][col] = "?"
            term.fg[row][col] = "?"
            term.bg[row][col] = "?"
        end
    end

    function term.getSize()
        return term.width, term.height
    end

    function term.setCursorPos(x, y)
        term.cursor_x = x
        term.cursor_y = y
    end

    function term.setTextColor(colour)
        term.set_fg_calls = term.set_fg_calls + 1
        term.current_fg = colour
    end

    function term.setBackgroundColor(colour)
        term.set_bg_calls = term.set_bg_calls + 1
        term.current_bg = colour
    end

    function term.write(text)
        term.writes = term.writes + 1
        local row = term.cursor_y
        local col = term.cursor_x
        for i = 1, #text do
            local cell_col = col + i - 1
            if row >= 1 and row <= term.height
                and cell_col >= 1 and cell_col <= term.width
            then
                term.cells[row][cell_col] = sub(text, i, i)
                term.fg[row][cell_col] = term.current_fg
                term.bg[row][cell_col] = term.current_bg
                term.last_fg = term.current_fg
                term.last_bg = term.current_bg
            end
        end
        term.cursor_x = col + #text
    end

    return term
end

local function new_screen()
    local memory = Memory.new()
    local vga = Vga.new{memory = memory}
    return vga, memory
end

local function cell_char(term, row, col)
    return term.cells[row][col]
end

local function cell_fg(term, row, col)
    return term.fg[row][col]
end

local function cell_bg(term, row, col)
    return term.bg[row][col]
end

---------------------------------------------------------------------------
-- Constants and construction
---------------------------------------------------------------------------

test("module constants", function()
    eq(Vga.BASE, 0xB8000, "Vga.BASE")
    eq(Vga.WIDTH, 80, "Vga.WIDTH")
    eq(Vga.HEIGHT, 25, "Vga.HEIGHT")
    eq(Vga.CELL_SIZE, 2, "Vga.CELL_SIZE")
end)

test("constructor defaults", function()
    local vga = new_screen()
    eq(vga:get_width(), 80, "width")
    eq(vga:get_height(), 25, "height")
    eq(vga:get_base(), 0xB8000, "base")
    eq(vga.attr, 0x07, "default attribute")
    local row, col = vga:get_cursor()
    eq(row, 0, "cursor row")
    eq(col, 0, "cursor column")
end)

test("constructor validates its options", function()
    expect_error(function() Vga.new(nil) end, "options table")
    expect_error(function() Vga.new({}) end, "opts.memory")
    expect_error(function() Vga.new{memory = {}} end, "read8")

    local memory = Memory.new()
    expect_error(function() Vga.new{memory = memory, width = 0} end,
        "width")
    expect_error(function() Vga.new{memory = memory, height = 1.5} end,
        "height")
    expect_error(function() Vga.new{memory = memory, base = -2} end,
        "base")
    expect_error(function() Vga.new{memory = memory, attr = 256} end,
        "attribute")

    -- The framebuffer must fit in the given memory object.
    local small = Memory.new(0x1000)
    expect_error(function() Vga.new{memory = small} end, "does not fit")
end)

---------------------------------------------------------------------------
-- Cell addressing
---------------------------------------------------------------------------

test("cell_offset maps row/column to 0xB8000", function()
    local vga = new_screen()
    eq(vga:cell_offset(0, 0), 0xB8000, "first cell")
    eq(vga:cell_offset(0, 1), 0xB8002, "second cell")
    eq(vga:cell_offset(1, 0), 0xB80A0, "start of row 1")
    eq(vga:cell_offset(0, 79), 0xB809E, "last cell of row 0")
    eq(vga:cell_offset(24, 0), 0xB8F00, "start of last row")
    eq(vga:cell_offset(24, 79), 0xB8F9E, "last cell")
end)

test("cell_offset rejects out-of-range cells", function()
    local vga = new_screen()
    expect_error(function() vga:cell_offset(25, 0) end, "row 25")
    expect_error(function() vga:cell_offset(0, 80) end, "column 80")
    expect_error(function() vga:cell_offset(-1, 0) end, "row -1")
    expect_error(function() vga:cell_offset(0, -1) end, "column -1")
    expect_error(function() vga:cell_offset(1.5, 0) end, "row")
end)

test("read/write go through memory at 0xB8000", function()
    local vga, memory = new_screen()
    vga:write_cell(0, 0, "H", 0x1F)
    eq(vga:read_char(0, 0), "H", "read_char")
    eq(vga:read_attr(0, 0), 0x1F, "read_attr")

    -- The bytes must really be at 0xB8000 / 0xB8001.
    eq(memory:read8(0xB8000), byte("H"), "character byte in memory")
    eq(memory:read8(0xB8001), 0x1F, "attribute byte in memory")

    -- A numeric character code is accepted too.
    vga:write_cell(2, 3, 0x41, 0x4E)
    eq(vga:read_char(2, 3), "A", "numeric code")
    eq(vga:read_attr(2, 3), 0x4E, "numeric code attribute")
    eq(memory:read8(vga:cell_offset(2, 3)), 0x41, "numeric code in memory")

    -- Omitting the attribute uses the screen default.
    vga:write_cell(1, 1, "Z")
    eq(vga:read_attr(1, 1), 0x07, "default attribute used")
end)

test("write_cell validates character and attribute", function()
    local vga = new_screen()
    expect_error(function() vga:write_cell(0, 0, "AB", 7) end, "one byte")
    expect_error(function() vga:write_cell(0, 0, 256, 7) end, "0..255")
    expect_error(function() vga:write_cell(0, 0, -1, 7) end, "0..255")
    expect_error(function() vga:write_cell(0, 0, 1.5, 7) end, "0..255")
    expect_error(function() vga:write_cell(0, 0, true, 7) end,
        "string or a byte")
    expect_error(function() vga:write_cell(0, 0, "A", 256) end, "0..255")
    expect_error(function() vga:write_cell(0, 0, "A", "7") end, "0..255")
end)

---------------------------------------------------------------------------
-- Whole-screen operations
---------------------------------------------------------------------------

test("clear fills the text plane and keeps the cursor", function()
    local vga = new_screen()
    vga:write_cell(3, 7, "Q", 0x1F)
    vga:set_cursor(5, 6)
    vga:clear(0x07)

    eq(vga:read_char(3, 7), " ", "cleared character")
    eq(vga:read_attr(3, 7), 0x07, "cleared attribute")
    for row = 0, 24 do
        eq(vga:read_attr(row, 0), 0x07, "row " .. row .. " first attr")
        eq(vga:read_attr(row, 79), 0x07, "row " .. row .. " last attr")
        eq(vga:read_char(row, 40), " ", "row " .. row .. " middle char")
    end
    local row, col = vga:get_cursor()
    eq(row, 5, "cursor row unchanged")
    eq(col, 6, "cursor column unchanged")

    -- clear() with an explicit attribute.
    vga:clear(0x4E)
    eq(vga:read_attr(0, 0), 0x4E, "explicit clear attribute")
end)

test("read_line returns the visible text of one row", function()
    local vga = new_screen()
    vga:clear(0x07)
    local text = "HELLO, VGA!"
    for i = 1, #text do
        vga:write_cell(2, i - 1, sub(text, i, i), 0x07)
    end
    eq(vga:read_line(2), text .. rep(" ", 80 - #text), "line text")
    eq(#vga:read_line(2), 80, "line length")
    eq(vga:read_line(0), rep(" ", 80), "empty line")
end)

test("snapshot reports characters and attributes", function()
    local vga = new_screen()
    vga:clear(0x1F)
    vga:write_cell(0, 0, "A", 0x4E)
    local snapshot = vga:snapshot()
    eq(snapshot.width, 80, "snapshot width")
    eq(snapshot.height, 25, "snapshot height")
    eq(#snapshot.rows, 25, "snapshot row count")
    eq(#snapshot.attrs, 25, "snapshot attr row count")
    eq(snapshot.rows[1], "A" .. rep(" ", 79), "snapshot row 1")
    eq(#snapshot.attrs[1], 80, "snapshot attr row length")
    eq(byte(snapshot.attrs[1], 1), 0x4E, "snapshot first attribute")
    eq(byte(snapshot.attrs[1], 2), 0x1F, "snapshot second attribute")
    eq(snapshot.rows[25], rep(" ", 80), "snapshot last row")
end)

---------------------------------------------------------------------------
-- Cursor
---------------------------------------------------------------------------

test("set_cursor clamps out-of-range positions", function()
    local vga = new_screen()
    vga:set_cursor(5, 10)
    local row, col = vga:get_cursor()
    eq(row, 5, "row")
    eq(col, 10, "column")

    vga:set_cursor(-3, 200)
    row, col = vga:get_cursor()
    eq(row, 0, "clamped row low")
    eq(col, 79, "clamped column high")

    vga:set_cursor(99, -1)
    row, col = vga:get_cursor()
    eq(row, 24, "clamped row high")
    eq(col, 0, "clamped column low")

    expect_error(function() vga:set_cursor("1", 0) end, "row")
    expect_error(function() vga:set_cursor(0, 1.5) end, "column")
end)

---------------------------------------------------------------------------
-- Scrolling
---------------------------------------------------------------------------

test("scroll_up moves the whole screen up", function()
    local vga = new_screen()
    vga:clear(0x07)
    for i = 1, #"TOP" do
        vga:write_cell(0, i - 1, sub("TOP", i, i), 0x1F)
    end
    for i = 1, #"SECOND" do
        vga:write_cell(1, i - 1, sub("SECOND", i, i), 0x2A)
    end

    vga:scroll_up(1)
    eq(sub(vga:read_line(0), 1, 6), "SECOND", "row 1 moved to row 0")
    eq(vga:read_attr(0, 0), 0x2A, "attribute moved with the row")
    eq(vga:read_line(24), rep(" ", 80), "bottom row blank")
    eq(vga:read_attr(24, 0), 0x07, "bottom row default attribute")
end)

test("scroll_up honours the attribute and clipping", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:write_cell(0, 0, "X", 0x1F)
    vga:write_cell(1, 0, "Y", 0x1F)

    vga:scroll_up(1, 0x4E)
    eq(vga:read_char(24, 0), " ", "new bottom row blank")
    eq(vga:read_attr(24, 0), 0x4E, "explicit scroll attribute")

    vga:scroll_up(3, 0x5F)
    eq(vga:read_attr(22, 0), 0x5F, "second new row attribute")
    eq(vga:read_attr(24, 79), 0x5F, "last new row attribute")

    -- Scrolling by zero is a no-op.
    vga:write_cell(0, 0, "K", 0x07)
    vga:scroll_up(0)
    eq(vga:read_char(0, 0), "K", "scroll_up(0) is a no-op")

    -- Scrolling the whole screen clears it.
    vga:scroll_up(999, 0x07)
    eq(vga:read_char(0, 0), " ", "full scroll clears")
    eq(vga:read_attr(4, 5), 0x07, "full scroll attribute")

    expect_error(function() vga:scroll_up(-1) end, "non-negative")
    expect_error(function() vga:scroll_up(1.5) end, "non-negative")
end)

---------------------------------------------------------------------------
-- Character mapping
---------------------------------------------------------------------------

test("printable ASCII passes through unchanged", function()
    local vga = new_screen()
    for code = 32, 126 do
        vga:write_cell(0, 0, code, 0x07)
        eq(vga:read_char(0, 0), char(code), "code " .. code)
    end
end)

test("control codes render as a dot", function()
    local vga = new_screen()
    vga:write_cell(0, 0, 0, 0x07)
    eq(vga:read_char(0, 0), ".", "NUL")
    vga:write_cell(0, 0, 7, 0x07)
    eq(vga:read_char(0, 0), ".", "BEL")
    vga:write_cell(0, 0, 31, 0x07)
    eq(vga:read_char(0, 0), ".", "US")
    vga:write_cell(0, 0, 127, 0x07)
    eq(vga:read_char(0, 0), ".", "DEL")
end)

test("extended codes map to readable ASCII approximations", function()
    local vga = new_screen()
    eq(Vga.glyph(0xDB), "#", "solid block")
    eq(Vga.glyph(0xB2), "#", "dark shading")
    eq(Vga.glyph(0xC4), "-", "horizontal line")
    eq(Vga.glyph(0xB3), "|", "vertical line")
    eq(Vga.glyph(0xC9), "+", "box corner")
    eq(Vga.glyph(0xCD), "=", "double horizontal line")
    eq(Vga.glyph(0x80), "C", "accented capital C")
    eq(Vga.glyph(0xE0), "a", "greek alpha")
    eq(Vga.glyph(0xFF), " ", "non-breaking space")

    -- Every extended code must come out as exactly one printable ASCII
    -- byte; nothing may be dropped or turned into a multi-byte value.
    for code = 128, 255 do
        local glyph = Vga.glyph(code)
        eq(type(glyph), "string", "glyph type for " .. code)
        eq(#glyph, 1, "glyph length for " .. code)
        local value = byte(glyph)
        if value < 32 or value > 126 then
            error(string.format("glyph for 0x%02X is not printable (%d)",
                code, value), 2)
        end
    end

    -- read_char() approximates but never rewrites the stored code.
    local vga2, memory2 = new_screen()
    vga2:write_cell(0, 0, 0xDB, 0x07)
    eq(vga2:read_char(0, 0), "#", "block read back as #")
    eq(memory2:read8(0xB8000), 0xDB, "stored code is untouched")
end)

---------------------------------------------------------------------------
-- Colour mapping
---------------------------------------------------------------------------

test("attribute bytes map to CC colour letters", function()
    eq(Vga.fg_color(0x07), "7", "0x07 foreground")
    eq(Vga.bg_color(0x07), "f", "0x07 background")
    eq(Vga.fg_color(0x1F), "0", "0x1F foreground")
    eq(Vga.bg_color(0x1F), "b", "0x1F background")
    eq(Vga.fg_color(0x00), "f", "black foreground")
    eq(Vga.fg_color(0x0F), "0", "white foreground")
    eq(Vga.fg_color(0x70), "f", "0x70 foreground is black")
    eq(Vga.bg_color(0x70), "7", "0x70 background is grey")
    eq(Vga.fg_color(0x25), "a", "magenta foreground")
    eq(Vga.bg_color(0x25), "d", "green background")

    local valid = "0123456789abcdef"
    for attr = 0, 255 do
        local fg = Vga.fg_color(attr)
        local bg = Vga.bg_color(attr)
        eq(#fg, 1, "fg length for " .. attr)
        eq(#bg, 1, "bg length for " .. attr)
        contains(valid, fg, "fg colour letter for " .. attr)
        contains(valid, bg, "bg colour letter for " .. attr)
    end

    expect_error(function() Vga.fg_color(256) end, "0..255")
    expect_error(function() Vga.bg_color(-1) end, "0..255")
end)

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

test("render paints the visible area with blit", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:write_cell(0, 0, "A", 0x1F)
    vga:write_cell(2, 5, "B", 0x4E)

    local term = new_term(51, 19)
    local cols, rows = vga:render(term)
    eq(cols, 51, "painted columns")
    eq(rows, 19, "painted rows")
    eq(term.blits, 19, "one blit per row")
    eq(#term.blit_sizes, 19, "blit size count")
    eq(term.blit_sizes[1], 51, "first blit width")
    eq(term.cursor_sets >= 19, true, "cursor positioned for every row")

    eq(cell_char(term, 1, 1), "A", "character at 1,1")
    eq(cell_fg(term, 1, 1), "0", "foreground at 1,1")
    eq(cell_bg(term, 1, 1), "b", "background at 1,1")
    eq(cell_char(term, 3, 6), "B", "character at 3,6")
    eq(cell_fg(term, 3, 6), "4", "foreground at 3,6")
    eq(cell_bg(term, 3, 6), "e", "background at 3,6")
    eq(cell_char(term, 19, 51), " ", "last visible cell")
end)

test("render clips to a small terminal", function()
    local vga = new_screen()
    vga:clear(0x07)
    for col = 0, 79 do
        vga:write_cell(0, col, char(65 + col % 26), 0x07)
    end
    vga:write_cell(9, 0, "Z", 0x1F)

    local term = new_term(10, 5)
    local cols, rows = vga:render(term)
    eq(cols, 10, "painted columns")
    eq(rows, 5, "painted rows")
    eq(term.blits, 5, "one blit per visible row")
    eq(term.blit_sizes[1], 10, "blit width clipped to 10")
    eq(cell_char(term, 1, 1), "A", "first cell")
    eq(cell_char(term, 1, 10), "J", "tenth cell of row 0")
    eq(cell_char(term, 5, 1), " ", "row 5 exists")
    eq(cell_char(term, 5, 10), " ", "row 5 last cell")
end)

test("render leaves terminal cells outside the framebuffer alone", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:write_cell(24, 79, "Q", 0x1F)

    local term = new_term(100, 30)
    local cols, rows = vga:render(term)
    eq(cols, 80, "painted columns")
    eq(rows, 25, "painted rows")
    eq(term.blits, 25, "one blit per framebuffer row")
    eq(term.blit_sizes[1], 80, "full width blit")
    eq(cell_char(term, 25, 80), "Q", "last framebuffer cell")
    eq(cell_char(term, 26, 1), "?", "terminal row 26 untouched")
    eq(cell_char(term, 1, 81), "?", "terminal column 81 untouched")
end)

test("render moves the terminal cursor to the VGA cursor", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:set_cursor(3, 4)
    local term = new_term(51, 19)
    vga:render(term)
    eq(term.cursor_y, 4, "terminal cursor row (1-based)")
    eq(term.cursor_x, 5, "terminal cursor column (1-based)")

    -- A cursor outside the visible rectangle is clamped to it.
    vga:set_cursor(24, 79)
    vga:render(term)
    eq(term.cursor_y, 19, "clamped terminal cursor row")
    eq(term.cursor_x, 51, "clamped terminal cursor column")
end)

test("render uses opts.term and _G.term", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:write_cell(0, 0, "O", 0x07)

    local via_opts = new_term(20, 6)
    local cols, rows = vga:render(nil, {term = via_opts})
    eq(cols, 20, "opts.term columns")
    eq(rows, 6, "opts.term rows")
    eq(cell_char(via_opts, 1, 1), "O", "opts.term painted")
    eq(via_opts.blits, 6, "opts.term blits")

    local saved = _G.term
    local via_global = new_term(20, 6)
    _G.term = via_global
    local ok, cols2, rows2 = pcall(function() return vga:render() end)
    _G.term = saved
    eq(ok, true, "render with _G.term succeeded")
    eq(cols2, 20, "_G.term columns")
    eq(rows2, 6, "_G.term rows")
    eq(cell_char(via_global, 1, 1), "O", "_G.term painted")
end)

test("render without any terminal paints nothing", function()
    local vga = new_screen()
    local saved = _G.term
    _G.term = nil
    local ok, cols, rows = pcall(function() return vga:render() end)
    _G.term = saved
    eq(ok, true, "render without a terminal does not crash")
    eq(cols, 0, "painted columns")
    eq(rows, 0, "painted rows")
end)

test("render falls back to write when blit is missing", function()
    local vga = new_screen()
    vga:clear(0x07)
    vga:write_cell(0, 0, "W", 0x1F)
    vga:write_cell(0, 1, "V", 0x4E)

    local term = new_plain_term(10, 3)
    local cols, rows = vga:render(term)
    eq(cols, 10, "painted columns")
    eq(rows, 3, "painted rows")
    eq(term.writes, 30, "write() called once per visible cell")
    eq(term.blits, nil, "no blit on this terminal")
    eq(cell_char(term, 1, 1), "W", "fallback character")
    eq(cell_char(term, 1, 2), "V", "second fallback character")
    eq(term.set_fg_calls > 0, true, "setTextColor was used")
    eq(term.set_bg_calls > 0, true, "setBackgroundColor was used")
    eq(term.fg[1][1], 0, "0x1F foreground is colour 0 (white)")
    eq(term.bg[1][1], 11, "0x1F background is colour b (blue)")
    eq(term.fg[1][2], 4, "0x4E foreground is colour 4 (yellow)")
    eq(term.bg[1][2], 14, "0x4E background is colour e (red)")
end)

test("render rejects unusable terminals", function()
    local vga = new_screen()
    expect_error(function() vga:render({}) end, "getSize")
    expect_error(function()
        vga:render({getSize = function() return 10, 5 end})
    end, "setCursorPos")
    expect_error(function()
        vga:render({
            getSize = function() return 10, 5 end,
            setCursorPos = function() end,
        })
    end, "neither")
    expect_error(function() vga:render(42) end, "terminal")
end)

test("render shows what the CPU wrote to the framebuffer", function()
    -- Proof that the screen comes from 0xB8000 and not from a Lua-side copy:
    -- poke the bytes directly through the memory object, then render.
    local vga, memory = new_screen()
    vga:clear(0x07)
    memory:write8(0xB8000, byte("R"))
    memory:write8(0xB8001, 0x1F)
    memory:write8(0xB8002, byte("A"))
    memory:write8(0xB8003, 0x1F)
    memory:write8(0xB8004, byte("M"))
    memory:write8(0xB8005, 0x1F)

    local term = new_term(51, 19)
    vga:render(term)
    eq(sub(cell_char(term, 1, 1) .. cell_char(term, 1, 2)
        .. cell_char(term, 1, 3), 1, 3), "RAM", "first three characters")
    eq(cell_fg(term, 1, 1), "0", "foreground from memory")
    eq(cell_bg(term, 1, 1), "b", "background from memory")
    eq(vga:read_line(0):sub(1, 3), "RAM", "read_line agrees")
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format("vga_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d vga test(s) failed", failed), 0)
end

return true
