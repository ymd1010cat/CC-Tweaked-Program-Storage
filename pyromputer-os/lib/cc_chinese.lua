-- cc_chinese.lua - draw CJK text on a CC:Tweaked screen from bitmap glyphs
--
-- HOW A CHARACTER BECOMES A CELL
-- A CraftOS terminal cell is 2x3 pixels, so a size 12 glyph is 6 cells wide and
-- 4 cells tall and is drawn with term.blit, whose "text" argument is not
-- characters but six bit flags packed into one byte per cell:
--
--     bit 0  left top        bit 3  right top
--     bit 1  left middle     bit 4  right middle
--     bit 2  left bottom     bit 5  right bottom
--
-- The ROM reads those bytes with string.char(128 + mask), which is why a real
-- glyph produces bytes above 128 and a blank cell is exactly 128. That is the
-- fact an acceptance probe can stand on when it wants to prove that pixels and
-- not merely absence-of-error came out of a render.
--
-- WHERE THE GLYPHS COME FROM, AND WHAT HAPPENS WHEN THEY ARE NOT THERE
-- The shipped glyph set is rasterised from Noto Sans SC, which is under the SIL
-- Open Font License 1.1 (the licence text and attribution are in
-- THIRD_PARTY_LICENSES at the repository root). The glyphs are on a medium of
-- its own (see lib/cc_fonts.lua for why: about
-- 1 MB of data will not fit beside the shell on a 1,000,000 B computer). So
-- every entry point here has to answer "and if the medium is out?" -- and the
-- answer is NOT a blank screen and NOT an error raised in the middle of a line
-- that has already been half drawn. draw() returns a report whose reason says
-- what happened, and a caller that ignores the report still gets a finished
-- screen. render() is the one function that raises, for a caller that wants a
-- font or wants to know, and it raises one message that names the medium and
-- the fix.
--
-- TWO MEDIA, AND THEREFORE TWO KINDS OF "NOT A GLYPH". The whole of GB2312 is
-- 146,463 B too big for one floppy, so the shipped set spans two media (see
-- lib/cc_fonts.lua). That adds a case the single-medium version did not have: a
-- character that IS in the set and whose glyph is on the medium that is not
-- inserted. It must not be drawn as the fallback box -- a box means "this font
-- has no such character", which is false -- and it must not be a blank with no
-- explanation. draw() counts those in report.absent, names the part in
-- report.reason, and lists the parts to insert in report.missing_parts.
local cc_chinese = {}

local shards = require("cc_font_shards")
local fonts = require("cc_fonts")

cc_chinese.config = {
    -- nil means "find the font medium by its marker"; a string pins the glyph
    -- set by name, which is what a program that ships its own font would do.
    base = nil,
    size = 12,
    text_color = colors.white,
    bg_color = colors.black,
    -- U+FFFD is in every generated set (tools/fontgen.py draws it as a hollow
    -- box) and is what a codepoint the set does not have is drawn as. A visible
    -- box beats a blank cell: a blank cell cannot be told apart from a space, so
    -- it hides the very problem the operator needs to see.
    fallback = 0xFFFD,
}

-- The base name a size uses. The name is how a medium that carries more than one
-- size says which is which (tools/fontgen.py --base), so it is a convention
-- shared by the generator and the runtime rather than a per-medium setting.
function cc_chinese.stem(size)
    return "shs" .. tostring(size)
end

-- The stem of a base path ("/disk2/fonts/shs12" -> "shs12").
local function stem_of(base)
    return tostring(base):match("([^/]+)$") or tostring(base)
end

-- The glyph sets under one medium, most preferred first: the size this module
-- renders at, then 12, then 8, then anything else the medium has. A medium may
-- carry several sets and picking between them at random is what this order
-- exists to prevent.
local function bases_on(medium)
    local dir = medium .. "/" .. fonts.DIR
    if not (fs.exists(dir) and fs.isDir(dir)) then return {} end
    local found = {}
    for _, name in ipairs(fs.list(dir) or {}) do
        local stem = name:match("^(.*)_index%.lua$")
        if stem then found[#found + 1] = dir .. "/" .. stem end
    end
    table.sort(found)
    -- THE SIZE ORDER IS A READABILITY DECISION, not an arbitrary default.
    -- A glyph of size N occupies ceil(N/2) x ceil(N/3) cells, so size 12 is a
    -- 6x4-cell block: on a 51-column screen a character is 6 cells wide and 4
    -- tall, and CJK text at that density is legible but cramped -- measured on the
    -- GUI, where the 12-point strokes merge into blobs at the size a 51x19 screen
    -- gives them. Size 16 is 8x6 and much clearer, at twice the bytes per glyph,
    -- which is why it ships as a SEPARATE, SMALLER set (the characters the
    -- interface actually uses) rather than as a bigger copy of the whole of
    -- GB2312: that would need three floppies. So 16 is preferred when a medium
    -- carries it, and 12 stays the fallback for a machine that only has the full
    -- set.
    local prefer = { cc_chinese.stem(cc_chinese.config.size), "shs16", "shs12", "shs8" }
    local out, taken = {}, {}
    for _, want in ipairs(prefer) do
        for _, base in ipairs(found) do
            if stem_of(base) == want and not taken[base] then
                taken[base] = true
                out[#out + 1] = base
            end
        end
    end
    for _, base in ipairs(found) do
        if not taken[base] then
            taken[base] = true
            out[#out + 1] = base
        end
    end
    return out
end

-- The pixel size a set was BUILT at, taken from the index's own declaration
-- (fontgen writes "matrix: N rows of N chars -> w x h cells" into every index).
--
-- WHY THIS EXISTS. A set's glyph matrices are size x size pixels, and the number
-- of character cells they pack into follows from that size (cells()). config.size
-- used to be the only source of both, so a machine that carried a size 16 set
-- while the config still said 12 packed 16 rows of pixels into 6x4 cells: the
-- glyph came out as a band of noise. Measured on the GUI, choosing the size 16
-- interface set drew garbage on screen while every "a glyph was drawn" assertion
-- still passed -- the drawing happened, at the wrong geometry.
--
-- So the size FOLLOWS the set that was chosen, and config.size becomes the
-- preference and the fallback rather than the truth. Nothing is guessed from the
-- set's NAME: the test fixture's set is called shs4 and holds 4x4-pixel matrices,
-- which is exactly the assumption a name-based rule would get wrong.
local function size_from_index(index)
    if type(index) ~= "table" then return nil end
    local rows = tonumber(index.__rows)
    if not rows or rows <= 0 then return nil end
    return rows
end
cc_chinese.size_from_index = size_from_index

-- Resolve the glyph set and load its index, once per base. Returns true, or
-- false plus a reason that names what is missing.
--
-- A BASE NAMES A SET AND NOT NECESSARILY A MEDIUM. The whole of GB2312 is
-- 146,463 B too big for one floppy, so a set may be built as two media, each
-- carrying part of the shards and an index naming only those (see
-- lib/cc_fonts.lua). shards.init() resolves the whole set from the base's stem,
-- so the two parts are unioned here without this module having to walk the media
-- itself -- and a set that fits one medium comes back as one layer, unchanged.
local function adopt(base, ok, ...)
    -- The chosen set decides the geometry, from its own declared matrix size.
    -- Only on success: a failed init has no set to take a size from, and the
    -- configured size stays as the preference.
    if ok then
        local size = size_from_index(shards.index and shards.index())
        if size then cc_chinese.config.size = size end
    end
    return ok, ...
end

local function ensure()
    if cc_chinese.config.base then
        local base, _medium, _index, why = fonts.resolve(cc_chinese.config.base)
        if not base then return false, why end
        return adopt(base, shards.init(base))
    end
    -- WHICH SET, WHEN THE MACHINE CARRIES SEVERAL.
    --
    -- fonts.find() answers with the first marked medium it walks and the first
    -- set on it, which is right for "is there a font at all" and wrong for "which
    -- of these should be used". A machine carrying a size 16 interface set on one
    -- medium and the full size 12 set on two others took whichever medium the
    -- drive order produced, and the geometry then disagreed with the pixels:
    -- measured on the GUI as noise on screen while every "something was drawn"
    -- assertion passed.
    --
    -- So the choice is made ACROSS media, with the same preference order bases_on
    -- uses within one. The size is adopted from the chosen set afterwards, which
    -- is what makes the geometry agree with the matrices.
    local all = {}
    for _, entry in ipairs(fonts.media()) do
        for _, base in ipairs(entry.bases or {}) do all[#all + 1] = base end
    end
    if #all == 0 then
        local _b, _m, _i, find_why = fonts.find()
        return false, find_why
    end
    -- THE ORDER IS BY READABILITY, NOT BY THE CURRENT CONFIG.
    --
    -- The first version of this loop put stem(config.size) first, so a machine
    -- that had both a size 16 interface set and the full size 12 set chose the 12
    -- one -- the config said 12 -- and the better set was never used. Measured:
    -- adopted size=12 source=/disk3/fonts/shs12 while /disk2/fonts/shs16 was
    -- mounted and readable.
    --
    -- THE ORDER IS 12 FIRST, AND THAT IS A MEASURED DECISION, NOT A DEFAULT.
    --
    -- Size N occupies ceil(N/2) x ceil(N/3) cells, so 12 is 6x4 and 16 is 8x6.
    -- On a 51x19 screen that means:
    --   size 12 -- 8 characters per line, 4 rows per line of text
    --   size 16 -- 6 characters per line, 6 rows per line of text
    -- and each character cell is 2x3 PIXELS either way. A bigger matrix therefore
    -- does NOT buy more detail per cell: it buys more cells, each still holding
    -- six sub-pixels. Measured on the GUI by drawing one glyph through both paths
    -- and comparing bytes: the size 16 glyph is correct and byte-identical to what
    -- its matrix says, and it still LOOKS like noise at 51 columns, because the
    -- strokes are spread over 8x6 coarse cells instead of packed into 6x4. Fewer,
    -- denser cells read better on this screen.
    --
    -- So 12 wins when a medium carries it, 8 is next (denser still, for a screen
    -- with even less room), 16 is the last resort before the configured size. A
    -- machine that only has the size 16 interface set still gets it.
    local chosen = nil
    for _, want in ipairs({ "shs12", "shs8", "shs16",
                            cc_chinese.stem(cc_chinese.config.size) }) do
        for _, base in ipairs(all) do
            if stem_of(base) == want then chosen = base break end
        end
        if chosen then break end
    end
    chosen = chosen or all[1]
    return adopt(chosen, shards.init(chosen))
end

-- The glyph source, or raise. For a caller that wants a font or wants to know;
-- draw() below is the one that degrades instead.
function cc_chinese.render()
    local ok, why = ensure()
    if not ok then
        error(fonts.why(why), 2)
    end
    return shards
end

-- Is a font available right now? Returns true, or false plus the reason.
function cc_chinese.available()
    return ensure()
end

-- The codepoints of a string, which is what the draw loop walks.
--
-- A byte of 0x80..0xBF arriving first is a stray continuation from a broken
-- string: it is drawn as a space rather than assembled into a large number,
-- because the alternative is a glyph lookup for a codepoint nobody meant. The
-- two, three and four byte forms are the standard ones; a truncated sequence
-- reads its missing bytes as zero, which lands outside any real set and becomes
-- the fallback box.
function cc_chinese.codepoints(text)
    local s = tostring(text)
    local i, n = 1, #s
    return function()
        if i > n then return nil end
        local b1 = string.byte(s, i)
        i = i + 1
        if b1 < 0x80 then return b1 end
        if b1 < 0xC0 then return 32 end
        local function next_byte()
            local b = string.byte(s, i)
            i = i + 1
            return b or 0x80
        end
        if b1 < 0xE0 then
            return (b1 - 0xC0) * 64 + (next_byte() - 0x80)
        elseif b1 < 0xF0 then
            local b2, b3 = next_byte(), next_byte()
            return (b1 - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
        elseif b1 < 0xF8 then
            local b2, b3, b4 = next_byte(), next_byte(), next_byte()
            return (b1 - 0xF0) * 262144 + (b2 - 0x80) * 4096
                 + (b3 - 0x80) * 64 + (b4 - 0x80)
        end
        return 32
    end
end

-- One terminal cell: the six sub-pixels of a 2x3 block of a glyph.
--
-- Exposed because this is the encoding the whole system is built on, and an
-- acceptance probe has to be able to compute the byte it expects rather than
-- just observe that some bytes appeared.
function cc_chinese.cell_byte(r0l, r1l, r2l, r0r, r1r, r2r)
    local m = 0
    if r0l == "1" then m = m + 1 end
    if r1l == "1" then m = m + 2 end
    if r2l == "1" then m = m + 4 end
    if r0r == "1" then m = m + 8 end
    if r1r == "1" then m = m + 16 end
    if r2r == "1" then m = m + 32 end
    return string.char(128 + m)
end

-- How many cells a glyph of this pixel size takes: the size of the matrix the
-- renderer is walking, derived the same way in one place so that a caller
-- measuring a line and the code drawing it cannot disagree.
function cc_chinese.cells(size)
    size = size or cc_chinese.config.size
    return math.ceil(size / 2), math.ceil(size / 3)
end

local function blank_row(width)
    return string.rep("0", width)
end

-- Draw one glyph matrix at (x, y). Returns the number of rows blitted.
--
-- The number of cell rows comes from the CONFIGURED SIZE and not from the
-- matrix: draw() advances the cursor by that number, and if the two disagreed
-- then a caller measuring with measure() would lay out text at a different
-- spacing from the renderer -- the failure would be a garbled line, not an
-- error. So a matrix shorter than the configured size is padded with blank rows
-- and one that is longer is drawn down to the edge, which is what a font built
-- for a different size than the machine was configured for deserves.
local function render_glyph(matrix, x, y)
    local w = #(matrix[1] or "")
    local cells_w, cells_h = cc_chinese.cells(cc_chinese.config.size)
    local fg = colors.toBlit(cc_chinese.config.text_color)
    local bg = colors.toBlit(cc_chinese.config.bg_color)
    local blank = blank_row(w)

    for cy = 0, cells_h - 1 do
        local r0 = matrix[cy * 3 + 1] or blank
        local r1 = matrix[cy * 3 + 2] or blank
        local r2 = matrix[cy * 3 + 3] or blank
        local text, fgs, bgs = {}, {}, {}
        for cx = 0, cells_w - 1 do
            local a = cx * 2 + 1
            local b = cx * 2 + 2
            text[#text + 1] = cc_chinese.cell_byte(
                r0:sub(a, a), r1:sub(a, a), r2:sub(a, a),
                r0:sub(b, b), r1:sub(b, b), r2:sub(b, b))
            fgs[#fgs + 1] = fg
            bgs[#bgs + 1] = bg
        end
        term.setCursorPos(x, y + cy)
        term.blit(table.concat(text), table.concat(fgs), table.concat(bgs))
    end
    return cells_h
end

-- Draw a string, one glyph at a time, wrapping at the right edge.
--
-- Returns a table rather than a single value because there are five outcomes a
-- caller can want to tell apart, and a boolean cannot: whether it drew at all
-- (ok), why not (reason), how many characters were drawn from the set (drawn),
-- how many were not (missing), and how many of those are in the set but on a
-- medium that is not inserted (absent, with missing_parts naming the parts). The
-- last ones are the ones a caller can act on -- "this menu has three characters
-- the font does not have" and "insert the second font medium" are different
-- sentences, and a user should not have to see three boxes to learn the second.
function cc_chinese.draw(text, x, y)
    local ok, why = ensure()
    if not ok then
        return { ok = false, reason = why, drawn = 0, missing = 0, absent = 0,
                 missing_parts = {}, cells = 0 }
    end

    local cx, cy = term.getCursorPos()
    if x then cx = x end
    if y then cy = y end
    local screen_w = select(1, term.getSize())
    local cells_w, cells_h = cc_chinese.cells(cc_chinese.config.size)

    local report = { ok = true, reason = nil, drawn = 0, missing = 0, absent = 0,
                     missing_parts = {}, cells = 0, error = nil }
    for code in cc_chinese.codepoints(text) do
        local matrix, err = shards.get(code)
        if matrix then
            render_glyph(matrix, cx, cy)
            report.drawn = report.drawn + 1
        else
            local gap = shards.absent(code)
            if gap then
                -- The character IS in this set; it is on a part that is not in
                -- the machine. The fallback box is deliberately NOT drawn: a box
                -- says "this font has no such character", which is false here,
                -- and the whole point of this path is that the machine must say
                -- which medium to insert instead of passing a box off as an
                -- answer. The cell is left as it was and the reason names the
                -- part.
                report.absent = report.absent + 1
                local known = false
                for _, part in ipairs(report.missing_parts) do
                    if part == gap.part then known = true end
                end
                if not known then report.missing_parts[#report.missing_parts + 1] = gap.part end
                if not report.reason then report.reason = gap.why end
                if not report.error then report.error = gap.why end
            else
                local fallback = shards.get(cc_chinese.config.fallback)
                if fallback then
                    render_glyph(fallback, cx, cy)
                else
                    -- The fallback box is itself a glyph of the set, and it can
                    -- be on the medium that is not in the machine. Then a
                    -- character the font does not have cannot be drawn as a box
                    -- either -- and that must be SAID, because a blank cell with
                    -- no reason is the one outcome this whole path exists to
                    -- prevent.
                    local box_gap = shards.absent(cc_chinese.config.fallback)
                    if box_gap then
                        if not report.reason then report.reason = box_gap.why end
                        if not report.error then report.error = box_gap.why end
                    end
                end
            end
            report.missing = report.missing + 1
            -- The first real failure (a shard that would not load, as opposed to
            -- a character this set simply does not have) is the one worth
            -- reporting: a line of text should not turn 40 diagnostics into 40
            -- problems when there is one cause.
            if err and err ~= "not in this set" and not report.error then
                report.error = err
            end
        end
        report.cells = report.cells + 1
        cx = cx + cells_w
        if cx + cells_w - 1 > screen_w then
            cx = 1
            cy = cy + cells_h
        end
    end
    term.setCursorPos(cx, cy)
    return report
end

-- Paint a rectangle in the background colour, ahead of drawing text into it.
-- Not called by draw(), because a caller may want to keep what is under the
-- text; it is the caller's rectangle, so it is the caller's decision.
function cc_chinese.clear(x, y, cols, rows)
    local bg = colors.toBlit(cc_chinese.config.bg_color)
    local row = string.rep(" ", cols)
    local row_bg = string.rep(bg, cols)
    for j = 0, rows - 1 do
        term.setCursorPos(x, y + j)
        term.blit(row, string.rep("0", cols), row_bg)
    end
end

-- The size of a line in character cells, for centring or for a border. The same
-- arithmetic as the draw loop, from the same function.
function cc_chinese.measure(text)
    local n = 0
    for _ in cc_chinese.codepoints(text) do n = n + 1 end
    local cells_w, cells_h = cc_chinese.cells(cc_chinese.config.size)
    return n * cells_w, cells_h
end

-- Release the cached shards, keeping the index.
function cc_chinese.clear_cache()
    shards.clear()
end

return cc_chinese
