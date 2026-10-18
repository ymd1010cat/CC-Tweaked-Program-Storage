-- gnome.screen - the drawing surface the desktop renders into.
--
-- WHY THIS IS AN ABSTRACTION AND NOT A CALL TO term
-- -------------------------------------------------
-- term.getLine does NOT exist on CraftOS-PC 2.8.3 (measured: the field is nil),
-- so a drawn cell cannot be read back off a real screen. A drawing bug is then
-- invisible to anything that renders to a terminal: a run can prove that no call
-- raised, never that the panel says what it should. Every draw of this desktop
-- therefore goes through a screen object with one small set of primitives, and
-- there are two implementations of it:
--
--   screen.buffer(w, h)   keeps the character, the foreground and the
--                         background of every cell in a table. The PC suite and
--                         the machine acceptance render into this and assert on
--                         cells.
--   screen.term(t)        the real terminal. It keeps the same shadow table and
--                         flushes the rows that changed with term.blit, so a
--                         real screen and a buffer describe the same picture.
--
-- Both refuse to draw while RELEASED. release() is what Desktop:handover calls
-- before it hands the screen to a program: while a program owns the terminal, a
-- desktop that kept painting into it would overwrite that program's output.
-- acquire() takes the screen back. Since 1.6.0 no shipped application hands the
-- screen over -- the Terminal runs its shell in a window like the Console -- so
-- this pair belongs to the handover capability, and the suite exercises it through
-- a synthetic app.
--
-- The colour arguments are the ROM's own constants (colors.white .. colors.black),
-- which is what term.setTextColour takes. A dump renders them through
-- colors.toBlit, so what a reader compares is the same alphabet term.blit uses.
local screen = {}

local BLANK = " "
local WHITE = 1        -- colors.white
local BLACK = 32768    -- colors.black

local function whole(v, fallback)
    local n = tonumber(v)
    if not n then return fallback or 0 end
    return math.floor(n)
end

-- Clamp, and answer `lo` when the range is inverted: a window wider than the
-- screen has no legal x at all, and "1" is the only answer that still draws.
local function fit(v, lo, hi)
    if lo > hi then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
screen.fit = fit

local function one_char(ch)
    if type(ch) == "number" then return string.char(ch % 256) end
    if type(ch) ~= "string" or ch == "" then return BLANK end
    return ch:sub(1, 1)
end

-- ===========================================================================
-- the buffer implementation: the record of what was drawn
-- ===========================================================================
function screen.buffer(w, h, fg, bg)
    local cells, fgs, bgs = {}, {}, {}
    local b = {
        kind = "buffer",
        released = false,
        clipped = 0,        -- cell writes that fell outside the screen
        lost = 0,           -- draws refused because the screen was released
        presents = 0,
        w = 0, h = 0,
    }

    b.reset = function(nw, nh, rfg, rbg)
        nw = math.max(0, whole(nw))
        nh = math.max(0, whole(nh))
        b.w, b.h = nw, nh
        b.default_fg = rfg or b.default_fg or fg or WHITE
        b.default_bg = rbg or b.default_bg or bg or BLACK
        cells, fgs, bgs = {}, {}, {}
        for y = 1, nh do
            cells[y], fgs[y], bgs[y] = {}, {}, {}
            for x = 1, nw do
                cells[y][x] = BLANK
                fgs[y][x] = b.default_fg
                bgs[y][x] = b.default_bg
            end
        end
    end

    local function inside(x, y)
        x, y = tonumber(x), tonumber(y)
        if not x or not y then return nil end
        x, y = math.floor(x), math.floor(y)
        if x < 1 or y < 1 or x > b.w or y > b.h then return nil end
        return x, y
    end

    b.reset(w, h, fg, bg)

    b.size = function() return b.w, b.h end

    b.cell = function(x, y, ch, cfg, cbg)
        if b.released then b.lost = b.lost + 1 return false end
        local ix, iy = inside(x, y)
        if not ix then b.clipped = b.clipped + 1 return false end
        cells[iy][ix] = one_char(ch)
        fgs[iy][ix] = cfg or b.default_fg
        bgs[iy][ix] = cbg or b.default_bg
        return true
    end

    -- Write a run of text. Answers the number of cells written; the characters
    -- that did not fit count as clipped, so a caller (or a test) can see that a
    -- line ran off the edge instead of assuming it was short.
    b.text = function(x, y, text, cfg, cbg)
        if b.released then b.lost = b.lost + 1 return 0 end
        text = tostring(text or "")
        local written = 0
        for i = 1, #text do
            local ix, iy = inside(x + i - 1, y)
            if ix then
                cells[iy][ix] = text:sub(i, i)
                fgs[iy][ix] = cfg or b.default_fg
                bgs[iy][ix] = cbg or b.default_bg
                written = written + 1
            else
                b.clipped = b.clipped + 1
            end
        end
        return written
    end

    b.fill = function(x1, y1, x2, y2, ch, cfg, cbg)
        if b.released then b.lost = b.lost + 1 return 0 end
        x1, y1, x2, y2 = tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)
        if not x1 or not y1 or not x2 or not y2 then b.clipped = b.clipped + 1 return 0 end
        if x1 > x2 then x1, x2 = x2, x1 end
        if y1 > y2 then y1, y2 = y2, y1 end
        local written, cellch = 0, one_char(ch)
        for y = math.floor(y1), math.floor(y2) do
            for x = math.floor(x1), math.floor(x2) do
                local ix, iy = inside(x, y)
                if ix then
                    cells[iy][ix] = cellch
                    fgs[iy][ix] = cfg or b.default_fg
                    bgs[iy][ix] = cbg or b.default_bg
                    written = written + 1
                else
                    b.clipped = b.clipped + 1
                end
            end
        end
        return written
    end

    b.hline = function(x1, x2, y, ch, cfg, cbg)
        return b.fill(x1, y, x2, y, ch, cfg, cbg)
    end

    b.vline = function(x, y1, y2, ch, cfg, cbg)
        return b.fill(x, y1, x, y2, ch, cfg, cbg)
    end

    b.clear = function(cfg, cbg)
        return b.fill(1, 1, b.w, b.h, BLANK, cfg or b.default_fg, cbg or b.default_bg)
    end

    b.present = function()
        b.presents = b.presents + 1
        return 0
    end

    b.release = function()
        -- Clear BEFORE marking the screen released: clear() goes through fill(),
        -- and fill() refuses to write once the screen is released. Doing it the
        -- other way round left the last frame on the screen for the shell to
        -- start inside of.
        b.clear()
        b.released = true
        return true
    end

    b.acquire = function()
        b.released = false
        b.clear()
        return true
    end

    -- What is on the screen, read back. This is the whole point of the buffer:
    -- a test asks these questions because term.getLine cannot be asked them.
    b.char = function(x, y)
        local ix, iy = inside(x, y)
        if not ix then return nil end
        return cells[iy][ix]
    end

    b.fg = function(x, y)
        local ix, iy = inside(x, y)
        if not ix then return nil end
        return fgs[iy][ix]
    end

    b.bg = function(x, y)
        local ix, iy = inside(x, y)
        if not ix then return nil end
        return bgs[iy][ix]
    end

    b.row = function(y)
        y = whole(y)
        if y < 1 or y > b.h or not cells[y] then return "" end
        return table.concat(cells[y])
    end

    b.fg_row = function(y)
        y = whole(y)
        if y < 1 or y > b.h or not fgs[y] then return {} end
        local out = {}
        for x = 1, b.w do out[x] = fgs[y][x] end
        return out
    end

    b.bg_row = function(y)
        y = whole(y)
        if y < 1 or y > b.h or not bgs[y] then return {} end
        local out = {}
        for x = 1, b.w do out[x] = bgs[y][x] end
        return out
    end

    -- Column of `text` in row y, or nil. Plain find: the caller is looking for a
    -- label, not a pattern.
    b.find = function(y, text)
        local at = b.row(y):find(tostring(text), 1, true)
        return at
    end

    b.rows = function()
        local out = {}
        for y = 1, b.h do out[y] = b.row(y) end
        return out
    end

    -- ---------------------------------------------------------------- palette
    -- A palette belongs to a terminal, not to a cell: redefining a colour slot
    -- changes every cell that uses it, which is why the desktop only does this
    -- for its own wallpaper and puts the slots back when it is done (see
    -- gnome.desktop's WALLPAPER_STOPS and restore_palette). The buffer records
    -- what was asked for, so the PC suite can assert it and the headless dump
    -- shows the slots the real machine would use; the term implementation also
    -- forwards it to the terminal it wraps.
    b.palette_set = {}
    b.palette_was = {}

    -- What a slot looked like before we touched it. This has to come from
    -- nativePaletteColour, NOT getPaletteColour: measured on CraftOS-PC 2.8.3, a
    -- slot nobody has set answers getPaletteColour with #191919 (0.098), while the
    -- machine's own colour is what nativePaletteColour knows (lightBlue is
    -- 0.6/0.698/0.949, purple 0.698/0.4/0.898). Restoring from getPaletteColour
    -- therefore paints the shell's prompt slots dark grey -- a wrong colour that
    -- looks like a broken palette rather than a restored one.
    local function original_rgb(t, colour)
        local fn = type(t) == "table" and t.nativePaletteColour or nil
        if type(fn) ~= "function" and type(term) == "table" and
           type(term.nativePaletteColour) == "function" then
            fn = term.nativePaletteColour
        end
        if type(fn) == "function" then
            local ok, red, green, blue = pcall(fn, colour)
            if ok and red then return { red, green, blue } end
        end
        -- Last resort for a terminal with no native palette API at all.
        if type(t) == "table" and type(t.getPaletteColour) == "function" then
            local ok, red, green, blue = pcall(t.getPaletteColour, colour)
            if ok and red then return { red, green, blue } end
        end
        return false
    end

    b.set_palette = function(colour, red, green, blue)
        if b.released then return false end
        if b.palette_was[colour] == nil then
            b.palette_was[colour] = false
            if b.kind == "term" then
                b.palette_was[colour] = original_rgb(b.terminal, colour)
            end
        end
        if b.kind == "term" then
            if not (b.terminal and type(b.terminal.setPaletteColour) == "function") then
                return false
            end
            if not pcall(b.terminal.setPaletteColour, colour, red, green, blue) then
                return false
            end
        end
        b.palette_set[colour] = { red, green, blue }
        return true
    end

    -- Put the slots back and answer how many were restored. A slot whose original
    -- RGB could not be read is forgotten rather than guessed at: a wrong colour on
    -- the shell's prompt is worse than the machine's own default.
    b.restore_palette = function()
        local count = 0
        for colour, was in pairs(b.palette_was) do
            if was and b.kind == "term" and b.terminal and
               type(b.terminal.setPaletteColour) == "function" then
                if pcall(b.terminal.setPaletteColour, colour, was[1], was[2], was[3]) then
                    count = count + 1
                end
            end
        end
        b.palette_was, b.palette_set = {}, {}
        return count
    end

    return b
end

-- ===========================================================================
-- the terminal implementation: the same shadow, flushed to the real screen
-- ===========================================================================
function screen.term(t, opts)
    opts = opts or {}
    t = t or term

    local function size_now()
        local w, h
        if t and t.getSize then w, h = t.getSize() end
        w, h = math.max(1, whole(w, 1)), math.max(1, whole(h, 1))
        return w, h
    end

    local base = screen.buffer(size_now())
    base.kind = "term"
    base.terminal = t
    base.blits = 0
    base.rows_written = 0
    -- The rows the shadow has no stamp for are written, which is why the FIRST
    -- frame of a fresh screen covers the whole screen: what the terminal had on it
    -- before this object existed is unknown, and a diff needs a known "before".
    -- Emptying the table is what asks for a full paint again (a resize, a release,
    -- an acquire all do it), so there is no second flag meaning the same thing.
    base.over = {}          -- the last stamp written per row (text + colours)

    local function toblit(colour)
        if opts.toblit then return opts.toblit(colour) end
        if colors and colors.toBlit then return colors.toBlit(colour) end
        return string.format("%x", math.floor(tonumber(colour) or 0) % 16)
    end

    local inner_present = base.present
    base.present = function()
        local nw, nh = size_now()
        if nw ~= base.w or nh ~= base.h then
            -- The terminal was resized behind our back: the shadow describes a
            -- screen that no longer exists, so start a new one and repaint every
            -- row of it.
            base.reset(nw, nh)
            base.over = {}
        end
        inner_present()
        if base.released then return 0 end
        local written = 0
        for y = 1, base.h do
            local row = base.row(y)
            local fgchars, bgchars = {}, {}
            local fgrow, bgrow = base.fg_row(y), base.bg_row(y)
            for x = 1, base.w do
                fgchars[x] = toblit(fgrow[x])
                bgchars[x] = toblit(bgrow[x])
            end
            local fgtext, bgtext = table.concat(fgchars), table.concat(bgchars)
            -- The stamp carries the colours as well as the text: a row whose
            -- characters are unchanged but recoloured still has to be written.
            local stamp = row .. "\1" .. fgtext .. "\1" .. bgtext
            if base.over[y] ~= stamp then
                if t.setCursorPos then t.setCursorPos(1, y) end
                if t.blit then
                    t.blit(row, fgtext, bgtext)
                elseif t.write then
                    t.write(row)
                end
                base.blits = base.blits + 1
                base.over[y] = stamp
                written = written + 1
            end
        end
        base.rows_written = base.rows_written + written
        return written
    end

    local inner_release = base.release
    base.release = function()
        inner_release()
        base.over = {}
        if t.setCursorBlink then t.setCursorBlink(true) end
        if t.setBackgroundColour then t.setBackgroundColour(opts.bg or base.default_bg) end
        if t.setTextColour then t.setTextColour(opts.fg or base.default_fg) end
        if t.clear then t.clear() end
        if t.setCursorPos then t.setCursorPos(1, 1) end
        return true
    end

    local inner_acquire = base.acquire
    base.acquire = function()
        inner_acquire()
        base.over = {}
        if t.clear then t.clear() end
        if t.setCursorBlink then t.setCursorBlink(false) end
        return true
    end

    if t.setCursorBlink then t.setCursorBlink(false) end

    return base
end

-- A screen of the requested kind, for callers that take a name rather than an
-- object: "term" (the machine) or "buffer" (a table, used by tests).
function screen.new(kind, arg)
    if kind == "term" then return screen.term(arg) end
    if kind == "buffer" then
        if type(arg) == "table" then return screen.buffer(arg.w, arg.h) end
        return screen.buffer(51, 19)
    end
    error("gnome.screen: unknown screen kind: " .. tostring(kind), 0)
end

return screen
