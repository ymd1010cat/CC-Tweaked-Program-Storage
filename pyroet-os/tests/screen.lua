--[[- pyroet-os/tests/screen.lua -- a character-cell screen buffer for the PC side.

CraftOS-PC 2.8.3 has no `term.getLine`, so a cell that has been drawn cannot be
read back off the emulator's real screen.  A boot screen assertion therefore
needs a terminal that keeps what it was told to draw.  This file is that
terminal: a buffer implementing the subset of the CraftOS `term` API the boot
chain uses, plus `install()` which puts it in the global `term` slot so the ROM's
own `print` and `write` render into it.

The buffer models the emulator, not an ideal terminal.  The rules below were
measured on CraftOS-PC 2.8.3 with a pass-through recorder, and each one is the
reason a naive "it drew something" buffer would agree with a wrong boot screen:

  * write() does NOT wrap and does NOT clamp the cursor: 60 characters written
    at column 1 of a 51 wide screen leave the cursor at (61, 1) and only the
    cells inside the screen change.  `print` is what wraps, by splitting the
    line into chunks of `getSize()` and calling setCursorPos() between them, so
    a buffer that wrapped inside write() would draw a long log line once per
    chunk.
  * clear() does NOT move the cursor (measured: (1,19) before and after).  The
    startup frame positions itself explicitly for exactly that reason.
  * blit() DOES advance the cursor by the text length, like write().
  * scroll(n) moves the rows up and leaves the bottom rows blank in the current
    background colour; the cursor stays where it was.  `print` at the last row
    ends with setCursorPos(1, h) followed by scroll(1), so after the newline the
    line it just wrote sits one row higher and the bottom row is blank -- the
    buffer needs that exact order to reproduce the real console.
  * setCursorPos() clamps to the screen; write() does not.

What the buffer deliberately does not implement: monitors, colours beyond the
sixteen CraftOS palette numbers, `term.getLine` (it does not exist), windows,
and anything the boot chain never calls.  A missing method raises a Lua error,
which is what a real terminal would do, so a test that needs a new method has to
add it here rather than get a silent nil.

No non-ASCII bytes in this file.
]]

local S = {}

S.DEFAULT_W = 51
S.DEFAULT_H = 19

-- CraftOS colour numbers are bit masks: white is bit 0, black bit 15.
S.WHITE = 2 ^ 0
S.BLACK = 2 ^ 15

-- the colour letter used by term.blit ("0".."f") back to the CraftOS number
function S.hex_colour(letter)
    local n = tonumber(tostring(letter or ""), 16)
    if n == nil then return nil end
    return 2 ^ n
end

local function blank_row(w, fg, bg)
    local row = {}
    for x = 1, w do row[x] = { " ", fg, bg } end
    return row
end

local function blank_grid(w, h, fg, bg)
    local grid = {}
    for y = 1, h do grid[y] = blank_row(w, fg, bg) end
    return grid
end

-- ---------------------------------------------------------------------------
-- the buffer
-- ---------------------------------------------------------------------------

-- S.buffer([w[, h]]) -> terminal-like table
--
-- The returned table answers the term API below.  The assertion helpers
-- (char/fg/bg/row/trim/text/find/find_row/snapshot) are extra and are what the
-- suites read; they are not part of the terminal surface.
function S.buffer(w, h)
    local self = {}
    self.w = math.max(1, math.floor(tonumber(w) or S.DEFAULT_W))
    self.h = math.max(1, math.floor(tonumber(h) or S.DEFAULT_H))
    self.text_colour = S.WHITE
    self.background_colour = S.BLACK
    self.x = 1
    self.y = 1
    self.blink = true
    self.grid = blank_grid(self.w, self.h, self.text_colour, self.background_colour)
    self.calls = {}
    self.stats = { writes = 0, blits = 0, clears = 0, scrolls = 0,
                   clipped = 0, setpos = 0, clear_lines = 0 }

    local function record(name, a, b, c)
        self.calls[#self.calls + 1] = { name = name, a = a, b = b, c = c }
        return self.calls[#self.calls]
    end

    local function clamp(value, lo, hi)
        value = math.floor(tonumber(value) or lo)
        if value < lo then return lo end
        if value > hi then return hi end
        return value
    end

    local function put(x, y, ch, fg, bg)
        if x < 1 or x > self.w or y < 1 or y > self.h then return false end
        self.grid[y][x] = { ch, fg, bg }
        return true
    end

    -- --- the term API ------------------------------------------------------

    function self.size() return self.w, self.h end
    function self.getSize() return self.w, self.h end
    function self.getCursorPos() return self.x, self.y end
    function self.getCursorBlink() return self.blink end
    function self.isColor() return true end
    function self.getTextColor() return self.text_colour end
    function self.getTextColour() return self.text_colour end
    function self.getBackgroundColor() return self.background_colour end
    function self.getBackgroundColour() return self.background_colour end

    function self.setCursorPos(x, y)
        record("setCursorPos", x, y)
        self.stats.setpos = self.stats.setpos + 1
        self.x = clamp(x, 1, self.w)
        self.y = clamp(y, 1, self.h)
        return true
    end

    function self.setCursorBlink(on)
        record("setCursorBlink", on)
        self.blink = on and true or false
        return true
    end

    function self.setTextColor(colour)
        record("setTextColor", colour)
        self.text_colour = tonumber(colour) or self.text_colour
        return true
    end
    self.setTextColour = self.setTextColor

    function self.setBackgroundColor(colour)
        record("setBackgroundColor", colour)
        self.background_colour = tonumber(colour) or self.background_colour
        return true
    end
    self.setBackgroundColour = self.setBackgroundColor

    -- clipped at the right edge, cursor left out of bounds, exactly as measured
    function self.write(text)
        text = tostring(text)
        record("write", text, self.x, self.y)
        self.stats.writes = self.stats.writes + 1
        for i = 1, #text do
            if self.y >= 1 and self.y <= self.h and self.x >= 1 and self.x <= self.w then
                self.grid[self.y][self.x] = { text:sub(i, i), self.text_colour, self.background_colour }
            else
                self.stats.clipped = self.stats.clipped + 1
            end
            self.x = self.x + 1
        end
        return true
    end

    -- blit() carries per-character colours and, like write(), moves the cursor
    function self.blit(text, fgs, bgs)
        text = tostring(text)
        fgs = tostring(fgs or "")
        bgs = tostring(bgs or "")
        record("blit", text, fgs, bgs)
        self.stats.blits = self.stats.blits + 1
        for i = 1, #text do
            local fg = S.hex_colour(fgs:sub(i, i)) or self.text_colour
            local bg = S.hex_colour(bgs:sub(i, i)) or self.background_colour
            if self.y >= 1 and self.y <= self.h and self.x >= 1 and self.x <= self.w then
                self.grid[self.y][self.x] = { text:sub(i, i), fg, bg }
            else
                self.stats.clipped = self.stats.clipped + 1
            end
            self.x = self.x + 1
        end
        return true
    end

    -- clears with the current colours and leaves the cursor alone (measured)
    function self.clear()
        record("clear")
        self.stats.clears = self.stats.clears + 1
        self.grid = blank_grid(self.w, self.h, self.text_colour, self.background_colour)
        return true
    end

    function self.clearLine()
        record("clearLine")
        self.stats.clear_lines = self.stats.clear_lines + 1
        if self.y >= 1 and self.y <= self.h then
            self.grid[self.y] = blank_row(self.w, self.text_colour, self.background_colour)
        end
        return true
    end

    function self.scroll(n)
        n = math.floor(tonumber(n) or 1)
        if n < 1 then n = 1 end
        if n > self.h then n = self.h end
        record("scroll", n)
        self.stats.scrolls = self.stats.scrolls + 1
        for y = 1, self.h - n do
            self.grid[y] = self.grid[y + n]
        end
        for y = self.h - n + 1, self.h do
            self.grid[y] = blank_row(self.w, self.text_colour, self.background_colour)
        end
        return true
    end

    -- --- what a suite reads ------------------------------------------------

    -- character at (x, y); nil outside the screen, so a clipped draw is visible
    function self.char(x, y)
        x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
        if x < 1 or x > self.w or y < 1 or y > self.h then return nil end
        return self.grid[y][x][1]
    end

    function self.fg(x, y)
        x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
        if x < 1 or x > self.w or y < 1 or y > self.h then return nil end
        return self.grid[y][x][2]
    end

    function self.bg(x, y)
        x, y = math.floor(tonumber(x) or 0), math.floor(tonumber(y) or 0)
        if x < 1 or x > self.w or y < 1 or y > self.h then return nil end
        return self.grid[y][x][3]
    end

    -- the whole row, padded to the screen width; "" outside the screen
    function self.row(y)
        y = math.floor(tonumber(y) or 0)
        if y < 1 or y > self.h then return "" end
        local out = {}
        for x = 1, self.w do out[x] = self.grid[y][x][1] end
        return table.concat(out)
    end

    -- the row without its trailing blanks, for readable failure details
    function self.trim(y)
        return (self.row(y):gsub("%s+$", ""))
    end

    function self.text()
        local out = {}
        for y = 1, self.h do out[y] = self.row(y) end
        return table.concat(out, "\n")
    end

    -- first column of `needle` in row y, or nil (plain find, no patterns)
    function self.find(y, needle)
        needle = tostring(needle)
        return (self.row(y):find(needle, 1, true))
    end

    -- first row containing `needle`; also returns the column
    function self.find_row(needle)
        for y = 1, self.h do
            local at = self.find(y, needle)
            if at then return y, at end
        end
        return nil
    end

    -- a copy of the screen at this moment, so a suite can assert what the frame
    -- drew before the boot chain logs anything else over it
    function self.snapshot()
        local rows = {}
        for y = 1, self.h do rows[y] = self.row(y) end
        return {
            w = self.w, h = self.h, rows = rows,
            x = self.x, y = self.y,
            clears = self.stats.clears, scrolls = self.stats.scrolls,
            writes = self.stats.writes,
        }
    end

    -- index of the n-th call to `name`, or nil
    function self.call_index(name, n)
        n = n or 1
        local seen = 0
        for i = 1, #self.calls do
            if self.calls[i].name == name then
                seen = seen + 1
                if seen == n then return i end
            end
        end
        return nil
    end

    function self.count_calls(name)
        local n = 0
        for i = 1, #self.calls do
            if self.calls[i].name == name then n = n + 1 end
        end
        return n
    end

    -- every write() payload up to (not including) call `stop`, joined with "\n"
    function self.wrote_before(stop)
        local out = {}
        for i = 1, math.min(#self.calls, (stop or #self.calls + 1) - 1) do
            if self.calls[i].name == "write" then
                out[#out + 1] = tostring(self.calls[i].a)
            end
        end
        return table.concat(out, "\n")
    end

    return self
end

-- ---------------------------------------------------------------------------
-- installing the buffer as the emulator's terminal
-- ---------------------------------------------------------------------------

-- S.install(buffer) -> restore function
--
-- The ROM's print/write look the `term` global up when they are called, so
-- swapping the table is enough to make real `print("...")` render into the
-- buffer (measured on CraftOS-PC 2.8.3: two prints produced two write() calls).
-- Always call the returned function before printing anything else: the test
-- runner's own OFFLINE_* markers go through the same print, and with the buffer
-- still installed they would disappear into it instead of the console.
function S.install(buffer)
    local old = rawget(_G, "term")
    rawset(_G, "term", buffer)
    return function()
        rawset(_G, "term", old)
    end
end

-- run fn with `buffer` installed, restore in every case, and hand back the
-- failure instead of leaving the global swapped when fn raises
function S.with_term(buffer, fn)
    local restore = S.install(buffer)
    local ok, err = pcall(fn)
    restore()
    return ok, err
end

return S
