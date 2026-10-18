-- batch10_check.lua - PC side assertions for the GNOME-like desktop PACKAGE
-- (tools/pkgs/gnome, installed on a machine with "pkg install gnome").
--
-- WHAT THIS SUITE IS UP AGAINST
-- term.getLine does not exist on CraftOS-PC 2.8.3 (measured), so a drawn cell
-- cannot be read back off a real screen. Every assertion below therefore renders
-- into a gnome.screen buffer -- which keeps the character, the foreground and the
-- background of every cell -- and asserts on CELLS. "It did not raise" is not an
-- assertion in this file; "row 1 column 24 says 12:34" is.
--
-- The parts that fail on their own, and are checked separately:
--   1. the screen abstraction, including the terminal implementation, because a
--      buffer that is wrong about a colour makes every colour assertion agree
--      with a wrong desktop;
--   2. the geometry, as known answers at 51x19 and at sizes down to 1x1: a layout
--      that merely avoids raising on a small screen is not usable;
--   3. the interaction: click-to-focus, raise ordering, the close control, the
--      drag (including the clamp on screen), the keyboard back-out ladder, and
--      a click that really reaches an application (the calculator's display is
--      the known answer, not "the window is still there");
--   4. survival: unknown and malformed events, an app that raises, an app whose
--      module is missing, a shell runner that raises, a screen that raises, a
--      screen of one cell -- the desktop has to still be there afterwards;
--   5. the REAL package, read out of the repository with _G.read_host_file,
--      because the manifest pkg and pkgserver read is a host file and no
--      emulated filesystem can see it.
--
-- Everything here is a PC side simulation result. It is NOT a CraftOS-PC result:
-- the real installation, the real boot and the real shell handover are
-- tools/rpv-verify/_ush-desktop.sh.

local PROJ = _G.PROJ
-- The package's own modules first, then the project's lib/, which on a machine is
-- always on package.path (/lib/?.lua, installed by ush.lua). A settings panel
-- that asks perm who the session's user is and pkg how many packages are
-- installed has to be able to reach them here too -- otherwise the suite would
-- only ever see "?" and could not tell a working panel from a broken one.
package.path = PROJ .. "/tools/pkgs/gnome/lib/?.lua;" ..
               PROJ .. "/lib/?.lua;" .. package.path

local say = _G.__realprint

local pass, fail = 0, 0
local fails = {}
local sections = {}
local skipped = {}
local current = { name = "(before the first section)", pass = 0, fail = 0 }
sections[1] = current

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
        current.pass = current.pass + 1
    else
        fail = fail + 1
        current.fail = current.fail + 1
        fails[#fails + 1] = name ..
            (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
    end
end

local function skip(name, why)
    skipped[#skipped + 1] = name .. " (" .. tostring(why) .. ")"
end

local function section(title)
    current = { name = title, pass = 0, fail = 0 }
    sections[#sections + 1] = current
end

local ok_screen, screen = pcall(require, "gnome.screen")
local ok_desktop, desktop = pcall(require, "gnome.desktop")
local ok_apps, apps = pcall(require, "gnome.apps")
check("the package's screen module loads from tools/pkgs/gnome/lib",
      ok_screen and type(screen) == "table", tostring(screen))
check("the package's desktop module loads from tools/pkgs/gnome/lib",
      ok_desktop and type(desktop) == "table", tostring(desktop))
check("the package's app registry loads from tools/pkgs/gnome/lib",
      ok_apps and type(apps) == "table", tostring(apps))
if not (ok_screen and ok_desktop and ok_apps) then
    _G.__RESULT = { pass = pass, fail = fail + 1,
                    fails = { "the package modules do not load" }, sections = sections }
    say("cannot continue without the package modules")
    return
end
local filesapp = require("gnome.apps.files")
local calcapp = require("gnome.apps.calc")
local settingsapp = require("gnome.apps.settings")
local editorapp = require("gnome.apps.editor")
local fmt = require("gnome.fmt")

local C = desktop.COLOURS
local L = { red = "e", blue = "b", cyan = "9" }

-- helpers ---------------------------------------------------------------
local function newdesk(opts)
    opts = opts or {}
    opts.screen = opts.screen or screen.buffer(51, 19)
    if opts.clock == nil then opts.clock = "12:34" end
    return desktop.new(opts), opts.screen
end

local function click(d, x, y, button)
    d:handle({ "mouse_click", button or 1, x, y })
end

-- ===========================================================================
section("screen: the cell record")
-- ===========================================================================
do
    local b = screen.buffer(4, 2)
    check("a buffer of 4x2 reports its size", b.size() == 4 and select(2, b.size()) == 2,
          tostring(b.w) .. "x" .. tostring(b.h))
    check("an untouched cell is a blank with the default colours",
          b.char(1, 1) == " " and b.fg(1, 1) == C.white and b.bg(1, 1) == C.black,
          tostring(b.char(1, 1)) .. "/" .. tostring(b.fg(1, 1)) .. "/" .. tostring(b.bg(1, 1)))
    check("a row reads back as its characters", b.row(1) == "    ", "[" .. b.row(1) .. "]")
    check("a row out of range reads back as nothing", b.row(9) == "", "[" .. b.row(9) .. "]")

    check("one cell remembers character AND colours",
          b.cell(2, 2, "Z", C.red, C.blue) == true and b.char(2, 2) == "Z" and
          b.fg(2, 2) == C.red and b.bg(2, 2) == C.blue,
          tostring(b.char(2, 2)) .. "/" .. tostring(b.fg(2, 2)) .. "/" .. tostring(b.bg(2, 2)))

    local before = b.clipped
    b.cell(0, 1, "x", C.white, C.black)
    b.cell(1, 9, "x", C.white, C.black)
    check("a write outside the screen is refused and counted",
          b.clipped == before + 2 and b.char(0, 1) == nil,
          "clipped +" .. tostring(b.clipped - before))
    check("a cell that cannot exist answers nil rather than a character",
          b.char(5, 1) == nil and b.fg(5, 1) == nil and b.bg(5, 1) == nil)

    b.text(4, 1, "abcd", C.cyan, C.black)
    check("text is truncated at the right edge and the lost cells are counted",
          b.char(4, 1) == "a" and b.clipped >= 4, "clipped " .. tostring(b.clipped))

    local b2 = screen.buffer(6, 2)
    check("a run of text writes every character", b2.text(1, 1, "hello", C.white, C.black) == 5,
          b2.row(1))
    check("and the row says what was written", b2.row(1) == "hello ", "[" .. b2.row(1) .. "]")
    check("find reports the column of a label", b2.find(1, "ello") == 2, tostring(b2.find(1, "ello")))
    check("find reports nothing for a label that is not there", b2.find(1, "zzz") == nil)

    b2.fill(1, 2, 3, 2, "#", C.lime, C.black)
    check("fill writes the whole rectangle", b2.row(2) == "###   ", "[" .. b2.row(2) .. "]")
    b2.fill(5, 1, 3, 1, "=", C.white, C.black)
    check("an inverted rectangle is normalised", b2.row(1) == "he=== ", "[" .. b2.row(1) .. "]")

    b2.clear(C.gray, C.blue)
    check("clear resets the characters and the colours",
          b2.row(1) == "      " and b2.fg(1, 1) == C.gray and b2.bg(1, 1) == C.blue,
          "[" .. b2.row(1) .. "] " .. tostring(b2.fg(1, 1)) .. "/" .. tostring(b2.bg(1, 1)))

    local b3 = screen.buffer(3, 1)
    b3.cell(1, 1, "a", C.white, C.black)
    b3.release()
    check("release says the screen is not ours", b3.released == true)
    check("release clears what was there", b3.char(1, 1) == " " and b3.row(1) == "   ",
          "[" .. b3.row(1) .. "]")
    local lost = b3.lost
    check("a draw while released is refused", b3.cell(1, 1, "b", C.white, C.black) == false and
          b3.lost == lost + 1, "lost +" .. tostring(b3.lost - lost))
    check("and it did not reach the screen", b3.char(1, 1) == " ")
    b3.acquire()
    check("acquire takes the screen back and draws land again",
          b3.released == false and b3.cell(1, 1, "c", C.white, C.black) == true and
          b3.char(1, 1) == "c")
end

-- ===========================================================================
section("screen: the terminal implementation")
-- ===========================================================================
do
    -- A stand-in terminal that records exactly what a real one would receive.
    local function faketerm(w, h)
        local t = { w = w, h = h, blits = {}, cleared = 0 }
        t.getSize = function() return t.w, t.h end
        t.setCursorPos = function(x, y) t.pos = { x, y } end
        t.blit = function(text, fg, bg) t.blits[#t.blits + 1] = { text, fg, bg } end
        t.write = function(text) t.blits[#t.blits + 1] = { text, "", "" } end
        t.clear = function() t.cleared = t.cleared + 1 end
        t.setCursorBlink = function(on) t.blink = on end
        t.setTextColour = function(c) t.text_colour = c end
        t.setBackgroundColour = function(c) t.bg_colour = c end
        return t
    end

    local t = faketerm(20, 3)
    local s = screen.term(t)
    check("the term screen takes its size from the terminal",
          s.size() == 20 and select(2, s.size()) == 3, s.w .. "x" .. s.h)

    s.cell(1, 1, "A", C.white, C.black)
    s.cell(2, 2, "B", C.red, C.blue)
    local rows = s.present()
    check("the first frame writes every row, because what the terminal held before is unknown",
          rows == 3, tostring(rows))
    check("and blits them through the terminal", #t.blits == 3, tostring(#t.blits))
    check("the payload carries the row's characters",
          t.blits[1] and t.blits[1][1] == "A" .. (" "):rep(19),
          "[" .. tostring(t.blits[1] and t.blits[1][1]) .. "]")
    check("the payload carries the foreground letters of the row",
          t.blits[2] ~= nil and t.blits[2][2]:sub(2, 2) == L.red,
          "[" .. tostring(t.blits[2] and t.blits[2][2]) .. "]")
    check("the payload carries the background letters of the row",
          t.blits[2] ~= nil and t.blits[2][3]:sub(2, 2) == L.blue,
          "[" .. tostring(t.blits[2] and t.blits[2][3]) .. "]")

    local again = s.present()
    check("a second frame with no change writes nothing", again == 0, tostring(again))
    check("and makes no further blit call", #t.blits == 3, tostring(#t.blits))

    -- The colour is part of what a row IS: the same characters in another colour
    -- have to be written, or a redraw that only recolours is lost.
    s.cell(1, 1, "A", C.cyan, C.black)
    local recoloured = s.present()
    check("a row whose characters are unchanged but recoloured is rewritten",
          recoloured == 1, tostring(recoloured))
    check("and the new colour is what went to the terminal",
          t.blits[4] ~= nil and t.blits[4][2]:sub(1, 1) == L.cyan,
          "[" .. tostring(t.blits[4] and t.blits[4][2]) .. "]")

    s.release()
    check("release clears the real terminal too", t.cleared >= 1, tostring(t.cleared))
    check("and turns the cursor back on for the shell", t.blink == true, tostring(t.blink))
    local blits_before = #t.blits
    s.text(1, 1, "hello", C.white, C.black)
    s.present()
    check("nothing is written to the terminal while released",
          #t.blits == blits_before, "+" .. tostring(#t.blits - blits_before))
    s.acquire()
    s.text(1, 1, "hello", C.white, C.black)
    local full = s.present()
    check("acquire forces a full repaint of the real screen", full == 3, tostring(full))

    t.w, t.h = 10, 2
    s.cell(1, 1, "X", C.white, C.black)
    s.present()
    check("a resized terminal is noticed and the shadow follows it",
          s.w == 10 and s.h == 2, s.w .. "x" .. s.h)

    local plain = faketerm(4, 1)
    plain.blit = nil
    local ps = screen.term(plain)
    ps.text(1, 1, "abcd", C.white, C.black)
    ps.present()
    check("a terminal without term.blit is written with term.write instead",
          plain.blits[1] and plain.blits[1][1] == "abcd",
          "[" .. tostring(plain.blits[1] and plain.blits[1][1]) .. "]")
end

-- ===========================================================================
section("geometry: the panel, at 51x19 and at tiny sizes")
-- ===========================================================================
do
    local p = desktop.panel(51, 19, { activities = "Activities", clock = "12:34", status = "[ush]" })
    check("the panel is one row, at the top", p.row == 1 and p.activities.y == 1)
    check("the activities affordance starts at the left edge",
          p.activities.x == 1 and p.activities.w == 10, p.activities.x .. "+" .. p.activities.w)
    check("the clock is centred: 12:34 sits at column 24 of 51",
          p.clock.x == 24 and p.clock.w == 5, "x=" .. tostring(p.clock.x))
    check("the status area is flush with the right edge",
          p.status.x == 47 and p.status.x + p.status.w - 1 == 51, "x=" .. tostring(p.status.x))

    local small = desktop.panel(20, 5, { activities = "Activities", clock = "12:34", status = "[ush]" })
    check("at 20 wide the clock is centred again (column 8)",
          small.clock.x == 8, "x=" .. tostring(small.clock.x))
    check("and the status area still ends at the right edge", small.status.x == 16,
          "x=" .. tostring(small.status.x))

    local tiny = desktop.panel(8, 3, { activities = "Activities", clock = "12:34", status = "[ush]" })
    check("a panel narrower than the label truncates it",
          tiny.activities.text == "Activiti" and tiny.activities.w == 8,
          "[" .. tiny.activities.text .. "]")
    local one = desktop.panel(1, 1, { activities = "Activities", clock = "12:34", status = "[ush]" })
    check("a one cell panel keeps the label inside the screen",
          one.activities.w == 1 and one.clock.x == 1 and one.status.x == 1,
          one.activities.w .. "/" .. one.clock.x .. "/" .. one.status.x)
end

-- ===========================================================================
section("geometry: the overview grid")
-- ===========================================================================
do
    local o = desktop.overview(51, 19, 4, 3)
    check("the overview title is inside the workspace, under the panel",
          o.title.y == 2 and o.title.x == 5 and o.title.text == "Applications",
          o.title.x .. "," .. o.title.y .. " [" .. o.title.text .. "]")
    check("four cards fit in the workspace's 47 columns of 12 wide cards",
          #o.cells == 4 and o.card_w == 12 and o.card_h == 4 and o.columns == 3,
          #o.cells .. " cards, " .. o.card_w .. "x" .. o.card_h .. " cols=" .. o.columns)
    check("card 1 is at the workspace's first grid cell",
          o.cells[1].x == 5 and o.cells[1].y == 4 and o.cells[1].w == 12 and o.cells[1].h == 4,
          o.cells[1].x .. "," .. o.cells[1].y .. " " .. o.cells[1].w .. "x" .. o.cells[1].h)
    check("card 2 is one card to the right (17)", o.cells[2].x == 17, tostring(o.cells[2].x))
    check("card 3 is at 29 and card 4 wraps to 5 on a second row",
          o.cells[3].x == 29 and o.cells[4].x == 5 and o.cells[4].y == 8,
          tostring(o.cells[3].x) .. "/" .. tostring(o.cells[4].x) .. "," .. tostring(o.cells[4].y))
    check("every card stays inside the workspace and right of the dock",
          o.cells[4].y + o.cells[4].h - 1 == 11 and o.cells[1].x == 5,
          tostring(o.cells[4].y + o.cells[4].h - 1))

    local short = desktop.overview(20, 5, 4, 3)
    check("a five row screen has room for one two-row card",
          #short.cells == 1 and short.card_h == 2 and short.cells[1].y == 4,
          #short.cells .. " cards of " .. tostring(short.card_h))
    local narrow = desktop.overview(3, 3, 4, 3)
    check("a three row screen has room for no card at all and does not raise",
          #narrow.cells == 0 and narrow.title.text == "A", "[" .. narrow.title.text .. "]")
    local one = desktop.overview(1, 1, 4, 3)
    check("a one cell screen has no card and no title longer than a cell",
          #one.cells == 0 and #one.title.text == 1, "[" .. one.title.text .. "]")
    local many = desktop.overview(51, 19, 40, 3)
    check("the grid stops at the workspace's last row instead of running past it",
          #many.cells == 12 and #many.cells > 4 and #many.cells < 40 and
          many.cells[#many.cells].y + many.cells[#many.cells].h - 1 <= 19,
          #many.cells .. " cards")
end

-- ===========================================================================
section("geometry: the dock")
-- ===========================================================================
do
    local items = { { id = "terminal", icon = ">_" }, { id = "files", icon = "[=]" },
                    { id = "settings", icon = "(*)" }, { id = "calc", icon = "123" } }
    local d = desktop.dock(51, 19, items, 3)
    check("the dock runs down the left edge, under the panel",
          d.x == 1 and d.y == 2 and d.w == 3 and d.h == 18,
          d.x .. "," .. d.y .. " " .. d.w .. "x" .. d.h)
    check("a separator cell runs down its right side", d.sep_x == 4, tostring(d.sep_x))
    check("each favourite is an icon with its running dot on the row under it",
          d.items[1].text == ">_" and d.items[1].y == 2 and d.items[1].dot.y == 3 and
          d.items[2].y == 4 and d.items[3].y == 6 and d.items[4].y == 8,
          d.items[1].y .. "/" .. d.items[2].y .. "/" .. d.items[3].y .. "/" .. d.items[4].y)
    check("the icons are put in the dock's three columns",
          d.items[1].x == 1 and d.items[1].w == 2 and d.items[2].x == 1 and d.items[2].w == 3,
          d.items[1].x .. "+" .. d.items[1].w)
    check("the running dot is one cell in the middle column",
          d.items[1].dot.x == 2 and d.items[1].dot.w == 1, tostring(d.items[1].dot.x))
    check("the running dot is the ASCII dot", d.dot == "*" and desktop.DOT == "*",
          tostring(d.dot))
    local small = desktop.dock(20, 5, items, 3)
    check("a five row dock has room for two favourites and stops there",
          #small.items == 2 and small.h == 4, #small.items .. " items, h=" .. small.h)
    local none = desktop.dock(10, 3, {}, 3)
    check("an empty dock is empty and does not raise", #none.items == 0 and none.sep_x == 4)
    local narrow = desktop.dock(2, 3, items, 3)
    check("a dock wider than the screen is clamped to the screen's width",
          narrow.w == 2 and narrow.sep_x == 3, narrow.w .. "/" .. narrow.sep_x)
end

-- ===========================================================================
section("geometry: the workspace")
-- ===========================================================================
do
    local work = desktop.WORK(51, 19, 3)
    check("the workspace starts right of the dock's separator and under the panel",
          work.x == 5 and work.y == 2, work.x .. "," .. work.y)
    check("and it reaches the screen's last column and last row",
          work.w == 47 and work.h == 18 and work.x + work.w - 1 == 51 and
          work.y + work.h - 1 == 19,
          work.w .. "x" .. work.h)
    local two = desktop.WORK(51, 19, 2)
    check("a two column dock moves the workspace one column left",
          two.x == 4 and two.w == 48, two.x .. "+" .. two.w)
    -- The dock's width is an option, and the workspace follows it: the point of
    -- making it a field is that nothing else has to know the number.
    local dw = newdesk({ dock_w = 2 })
    dw:draw()
    check("opts.dock_w moves the dock's separator and the workspace with it",
          dw.dock_w == 2 and dw:work_rect().x == 4 and dw.screen.char(3, 2) == "|" and
          dw.screen.find(2, ">_") == 1,
          tostring(dw.dock_w) .. " sep=" .. tostring(dw.screen.char(3, 2)))
    local tiny = desktop.WORK(1, 1, 3)
    check("a one cell screen still answers a one cell workspace rather than raising",
          tiny.x == 1 and tiny.y == 1 and tiny.w == 1 and tiny.h == 1,
          tiny.x .. "," .. tiny.y .. " " .. tiny.w .. "x" .. tiny.h)
end

-- ===========================================================================
section("geometry: window chrome")
-- ===========================================================================
do
    local win = { x = 1, y = 3, w = 40, h = 12 }
    local close = desktop.close_rect(win)
    check("the close control sits at the right end of the title bar",
          close.x == 38 and close.y == 3 and close.w == 3 and close.h == 1,
          close.x .. "," .. close.y .. " " .. close.w)
    check("the title bar is the window's top row and spans its width",
          desktop.title_rect(win).x == 1 and desktop.title_rect(win).w == 40)
    local body = desktop.body_rect(win)
    check("the body is inside the title bar and the two side borders",
          body.x == 2 and body.y == 4 and body.w == 38 and body.h == 10,
          body.x .. "," .. body.y .. " " .. body.w .. "x" .. body.h)
    check("a narrow window has no close control (the label needs five cells)",
          desktop.close_rect({ x = 1, y = 1, w = 5, h = 3 }) == nil)
    check("and exactly six cells is the smallest that has one",
          desktop.close_rect({ x = 1, y = 1, w = 6, h = 3 }).x == 4)
    check("window_rect is the whole frame",
          desktop.window_rect(win).w == 40 and desktop.window_rect(win).h == 12)

    local x, y, w, h = desktop.default_geometry(51, 19, 0, 3)
    check("the first window on a 51x19 screen is 40x12 at 5,3, inside the workspace",
          x == 5 and y == 3 and w == 40 and h == 12, x .. "," .. y .. " " .. w .. "x" .. h)
    local x2, y2 = desktop.default_geometry(51, 19, 1, 3)
    check("the second is stepped down and right so the first stays visible",
          x2 == 7 and y2 == 4, x2 .. "," .. y2)
    local x3, y3 = desktop.default_geometry(51, 19, 2, 3)
    check("a third is stepped again, and never leaves the workspace",
          x3 == 9 and y3 == 5 and x3 + 40 - 1 <= 51 and y3 + 12 - 1 <= 19,
          x3 .. "," .. y3)
    local sx, sy, sw, sh = desktop.default_geometry(20, 5, 0, 3)
    check("a new window never exceeds the workspace it is opened on",
          sx == 5 and sy == 3 and sw == 12 and sh == 3, sx .. "," .. sy .. " " .. sw .. "x" .. sh)
    local _, _, tw, th = desktop.default_geometry(4, 3, 0, 3)
    check("and it never shrinks below the smallest drawable frame",
          tw == 3 and th == 3, tw .. "x" .. th)
    check("centring a title answers the column it starts at",
          desktop.centre(51, "the overview") == 20 and desktop.centre(10, "abcd") == 4,
          tostring(desktop.centre(51, "the overview")))
end

-- ===========================================================================
section("drawing: the panel, the wallpaper and the dock")
-- ===========================================================================
do
    local d, s = newdesk()
    d:draw()
    check("row 1 says Activities at the left edge", s.find(1, "Activities") == 1,
          "[" .. s.row(1) .. "]")
    check("row 1 carries the clock exactly where the layout puts it",
          s.find(1, "12:34") == 24, tostring(s.find(1, "12:34")))
    check("row 1 carries the status area at the right edge", s.find(1, "[ush]") == 47,
          tostring(s.find(1, "[ush]")))
    check("the clock is drawn in its own colour", s.fg(24, 1) == C.white, tostring(s.fg(24, 1)))
    check("the status area is drawn in its own colour",
          s.fg(47, 1) == C.lightGray, tostring(s.fg(47, 1)))
    check("the wallpaper carries no product name",
          s.find(8, "gnome") == nil and s.find(9, "gnome") == nil,
          "[" .. s.row(8) .. "]")
    check("but it still names the shortcut that opens the overview",
          s.find(8, "press o") == 16, tostring(s.find(8, "press o")))
    check("and the hint is drawn in the wallpaper's own readable colour",
          s.fg(16, 8) == C.white, tostring(s.fg(16, 8)))
    -- The palette half of the wallpaper: six ROM slots redefined to six RGB
    -- points of the purple to orange sweep. A buffer screen records the request,
    -- which is how a suite with no real terminal can see that it happened.
    check("the wallpaper redefines six colour slots with real RGB",
          s.palette_set[C.purple] ~= nil and s.palette_set[C.magenta] ~= nil and
          s.palette_set[C.green] ~= nil and s.palette_set[C.pink] ~= nil and
          s.palette_set[C.lightBlue] ~= nil and s.palette_set[C.brown] ~= nil and
          #s.palette_set[C.brown] == 3,
          tostring(s.palette_set[C.brown] and s.palette_set[C.brown][1]))
    check("the install is counted once, not once per frame",
          d.stats.palette_sets == 1, tostring(d.stats.palette_sets))
    d:draw()
    check("a second frame does not redefine the slots again",
          d.stats.palette_sets == 1, tostring(d.stats.palette_sets))
    check("the sweep starts on the deep purple slot",
          desktop.wallpaper_stop(19, 1) == C.purple,
          tostring(desktop.wallpaper_stop(19, 1)))
    check("and ends on the warm orange slot",
          desktop.wallpaper_stop(19, 19) == C.brown,
          tostring(desktop.wallpaper_stop(19, 19)))
    -- Solid rows, one redefined slot each. A 4x2 cell dither was tried (1.7.5)
    -- and can still be seen as a pattern on a 51x19 screen, so the wallpaper must
    -- NOT mix two colours across a row any more: a row is one background colour.
    local function row_colours(y)
        local cols, n = {}, 0
        for x = 5, 45 do
            if not cols[s.bg(x, y)] then cols[s.bg(x, y)] = true; n = n + 1 end
        end
        return n
    end
    check("a wallpaper row is one colour, not a cell pattern",
          row_colours(3) == 1 and row_colours(10) == 1 and row_colours(18) == 1,
          row_colours(3) .. "/" .. row_colours(10) .. "/" .. row_colours(18))
    check("and neighbouring rows really are different slots (a sweep)",
          s.bg(40, 3) ~= s.bg(40, 18) and s.bg(40, 10) ~= s.bg(40, 18),
          tostring(s.bg(40, 3)) .. "/" .. tostring(s.bg(40, 10)) .. "/" ..
          tostring(s.bg(40, 18)))
    local hint_cols = {}
    for x = 5, 45 do hint_cols[s.bg(x, 8)] = true end
    check("the wallpaper's own words sit on a colour that row carries",
          hint_cols[s.bg(16, 8)] == true, tostring(s.bg(16, 8)))
    check("the dock lists every favourite at its own row",
          s.find(2, ">_") == 1 and s.find(4, "[=]") == 1 and
          s.find(6, "(*)") == 1 and s.find(8, "123") == 1,
          tostring(s.find(2, ">_")) .. "/" .. tostring(s.find(8, "123")))
    check("the dock is a near black column with a gray separator on its right",
          s.bg(1, 2) == C.black and s.char(4, 2) == "|" and s.fg(4, 2) == C.gray,
          tostring(s.bg(1, 2)) .. " " .. tostring(s.char(4, 2)) .. "/" .. tostring(s.fg(4, 2)))
    check("the dock reaches the bottom row, where the old dash used to be",
          s.bg(2, 19) == C.black and s.char(4, 19) == "|", tostring(s.bg(2, 19)))
    check("nothing is running, so every indicator is blank",
          s.char(2, 3) == " " and s.char(2, 9) == " " and s.char(2, 9) ~= desktop.DOT,
          "[" .. tostring(s.char(2, 3)) .. "]")
end

-- A machine whose terminal cannot redefine the palette (or a build without
-- setPaletteColour) must still get a wallpaper: the sixteen colour sweep, not a
-- blank desktop. The fallback path is exercised by taking the one method away.
do
    local s = screen.buffer(51, 19)
    s.set_palette = nil
    local d = desktop.new({ screen = s, clock = "12:34" })
    d:draw()
    check("a screen without palette support says so instead of pretending",
          d.wallpaper_palette == false and d.stats.palette_sets == 0,
          tostring(d.wallpaper_palette) .. "/" .. tostring(d.stats.palette_sets))
    check("and the fallback still paints the sixteen colour sweep",
          s.bg(40, 19) == C.orange, tostring(s.bg(40, 19)))
    check("the fallback's first wallpaper row is the old purple",
          (function()
              local cols = {}
              for x = 5, 45 do cols[s.bg(x, 2)] = true end
              return cols[C.purple] == true
          end)(), tostring(s.bg(40, 2)))
end

-- Leaving the desktop gives the terminal its colours back: the shell runs on it
-- next, and a shell whose prompt colours were left as wallpaper stops would be a
-- machine that looks broken in a way nothing explains.
do
    local d, s = newdesk()
    d:draw()
    check("the slots are set while the desktop is up", next(s.palette_set) ~= nil)
    d:quit("test")
    check("quitting restores the colour slots it redefined",
          d.stats.palette_restores == 1, tostring(d.stats.palette_restores))
    check("and the terminal is left with no slots recorded",
          next(s.palette_set) == nil and next(s.palette_was) == nil)
    check("the restore is counted once even if quit is called twice",
          (function() d:quit("again") return d.stats.palette_restores == 1 end)(),
          tostring(d.stats.palette_restores))
end

-- A restore must put back the MACHINE's colour, not what getPaletteColour
-- answers for a slot nobody set. Measured on CraftOS-PC 2.8.3: an unset slot
-- answers getPaletteColour with #191919 (0.098) while nativePaletteColour knows
-- the real colour. Restoring from the former greys the shell's prompt slots --
-- a machine that looks broken after leaving the desktop, which is what the first
-- version of this restore did.
do
    local calls = {}
    local t = {
        getSize = function() return 51, 19 end,
        setPaletteColour = function(c, r, g, b) calls[c] = { r, g, b } end,
        getPaletteColour = function() return 0.098, 0.098, 0.098 end,
        nativePaletteColour = function() return 0.5, 0.25, 0.75 end,
        blit = function() end,
        clear = function() end,
        setCursorPos = function() end,
        setCursorBlink = function() end,
        setBackgroundColour = function() end,
        setTextColour = function() end,
    }
    local s = screen.term(t)
    local d = desktop.new({ screen = s, clock = "12:34" })
    d:draw()
    d:quit("test")
    local was = calls[desktop.COLOURS.purple]
    check("a restore puts the native colour back, not getPaletteColour's placeholder",
          was ~= nil and was[1] == 0.5 and was[2] == 0.25 and was[3] == 0.75,
          tostring(was and was[1]) .. "/" .. tostring(was and was[2]))
end

-- A pumped shell redirects the GLOBAL term to its own window while it runs, and
-- the term API's functions follow that redirect. The desktop must still paint its
-- OWN terminal: painting through the API put the desktop's frame into the shell's
-- invisible window (measured on the machine: the Terminal's lines were screen rows
-- 1..10 -- "Activities", the dock, the title bar -- and the shell's prompt was
-- overwritten, so typing looked like it did nothing).
do
    local blits = 0
    local native = {
        getSize = function() return 51, 19 end,
        blit = function() blits = blits + 1 end,
        clear = function() end,
        setCursorPos = function() end,
        setCursorBlink = function() end,
        setBackgroundColour = function() end,
        setTextColour = function() end,
    }
    local d = desktop.new({ term = native, clock = "12:34" })
    local saved = { blit = term.blit, setCursorPos = term.setCursorPos, clear = term.clear }
    local redirected = 0
    local function elsewhere()
        redirected = redirected + 1
        error("the desktop used the redirected term API", 0)
    end
    term.blit, term.setCursorPos, term.clear = elsewhere, elsewhere, elsewhere
    local ok = pcall(function() d:draw() end)
    term.blit, term.setCursorPos, term.clear =
        saved.blit, saved.setCursorPos, saved.clear
    check("the desktop paints its own terminal, not one a pump redirected",
          ok and blits > 0 and redirected == 0 and d.last_error == nil,
          tostring(blits) .. " native blit(s), " .. tostring(redirected) ..
          " redirected, last_error=" .. tostring(d.last_error))
end

-- ===========================================================================
section("the activities overview by mouse and by key")
-- ===========================================================================
do
    local d, s = newdesk()
    d:draw()
    click(d, 5, 1)
    check("clicking Activities opens the overview", d.overview == true)
    check("and the affordance is highlighted in the accent colour while it is open",
          s.bg(1, 1) == C.orange and s.fg(1, 1) == C.black,
          tostring(s.bg(1, 1)) .. "/" .. tostring(s.fg(1, 1)))
    check("the overview paints its own background behind the cards",
          s.bg(51, 10) == C.blue, tostring(s.bg(51, 10)))
    check("the overview is titled inside the workspace", s.find(2, "Applications") == 5,
          "[" .. s.row(2) .. "]")
    check("every application is listed by name on its own card",
          s.find(6, "Terminal") == 7 and s.find(6, "Files") == 20 and
          s.find(6, "Settings") == 31 and s.find(10, "Calculator") == 6,
          tostring(s.find(6, "Terminal")) .. "/" .. tostring(s.find(6, "Files")) ..
          "/" .. tostring(s.find(6, "Settings")) .. "/" .. tostring(s.find(10, "Calculator")))
    check("and by its icon on the line above",
          s.find(5, ">_") == 10 and s.find(5, "[=]") == 21,
          tostring(s.find(5, ">_")) .. "/" .. tostring(s.find(5, "[=]")))
    check("the first card is the selected one and says so in the accent colour",
          s.bg(5, 4) == C.orange and s.bg(17, 4) == C.blue,
          tostring(s.bg(5, 4)) .. "/" .. tostring(s.bg(17, 4)))
    check("the dock is still drawn while the overview is up",
          s.char(4, 5) == "|" and s.find(1, "Activities") == 1 and s.char(1, 2) == ">",
          "[" .. tostring(s.char(4, 5)) .. "]")
    check("and the dock is still a click target there",
          (function()
              local d0 = newdesk()
              d0:draw()
              click(d0, 5, 1)
              click(d0, 2, 8)
              return d0.overview == false and #d0.windows == 1 and d0.windows[1].id == "calc"
          end)())

    d:handle({ "key", desktop.KEYS.tab })
    check("tab moves the selection to the next card",
          d.select == 2 and s.bg(17, 4) == C.orange and s.bg(5, 4) == C.blue,
          "select=" .. tostring(d.select) .. " bg17=" .. tostring(s.bg(17, 4)))
    d:handle({ "key", desktop.KEYS.enter })
    check("enter opens the selected application and leaves the overview",
          d.overview == false and #d.windows == 1 and d.windows[1].id == "files",
          tostring(#d.windows) .. " " .. tostring(d.windows[1] and d.windows[1].id))
    check("and its window is drawn with the title of that application",
          s.find(3, "Files") == 7, "[" .. s.row(3) .. "]")

    -- A card is a click target: the window it opens is the whole point, and the
    -- click lands on the card the label was drawn in.
    local d2 = newdesk()
    d2:draw()
    click(d2, 5, 1)
    click(d2, 30, 6)
    check("clicking a card opens that card's application",
          d2.overview == false and #d2.windows == 1 and d2.windows[1].id == "settings",
          tostring(d2.windows[1] and d2.windows[1].id))

    local d3 = newdesk()
    d3:draw()
    d3:handle({ "key", desktop.KEYS.o })
    check("the o key opens the overview too", d3.overview == true)
    d3:handle({ "key", desktop.KEYS.o })
    check("and closes it again", d3.overview == false)
    d3:handle({ "key", desktop.KEYS.o })
    d3:handle({ "key", desktop.KEYS.f10 })
    check("F10 is the way back out of the overview",
          d3.overview == false and d3.exit == false)

    -- The overview covers the windows (as GNOME's does); leaving it brings them
    -- back, so a window is never hidden while it is the focus.
    local d4, s4 = newdesk()
    d4:draw()
    d4:open("files")
    check("a window is drawn before the overview is opened", s4.find(3, "Files") == 7,
          tostring(s4.find(3, "Files")))
    click(d4, 5, 1)
    check("the overview hides it", s4.find(3, "Files") == nil, "[" .. s4.row(3) .. "]")
    d4:handle({ "key", desktop.KEYS.f10 })
    check("and it is back when the overview is left",
          s4.find(3, "Files") == 7 and #d4.windows == 1, tostring(s4.find(3, "Files")))
end

-- ===========================================================================
section("windows: chrome, focus, raise and the close control")
-- ===========================================================================
do
    local d, s = newdesk()
    local win = d:open("terminal")
    check("a window opens at the geometry the layout gives it",
          win.x == 5 and win.y == 3 and win.w == 40 and win.h == 12,
          win.x .. "," .. win.y .. " " .. win.w .. "x" .. win.h)
    check("opening a window repaints the screen without an event",
          s.find(3, "Terminal") == 7, "[" .. s.row(3) .. "]")
    check("the title bar carries the application's name",
          s.find(3, "Terminal") == 7, "[" .. s.row(3) .. "]")
    check("the title bar carries a close control at its right end",
          s.find(3, "[x]") == 42, tostring(s.find(3, "[x]")))
    check("the focused window's title bar is the focused colour",
          s.bg(7, 3) == C.gray, tostring(s.bg(7, 3)))
    check("and its first cell is the orange accent mark of the focused window",
          s.bg(5, 3) == C.orange, tostring(s.bg(5, 3)))
    check("the sides of the window are drawn",
          s.char(5, 5) == "|" and s.char(44, 5) == "|",
          tostring(s.char(5, 5)) .. "/" .. tostring(s.char(44, 5)))
    check("the bottom border is drawn",
          s.char(5, 14) == "+" and s.char(44, 14) == "+" and s.char(6, 14) == "-",
          tostring(s.char(5, 14)) .. tostring(s.char(6, 14)) .. tostring(s.char(44, 14)))
    check("the app drew inside the body", s.find(4, "this machine has no window API") == 6,
          "[" .. s.row(4) .. "]")
    -- 1.6.0: the Terminal runs the shell in its own window, so on this machine --
    -- which has no window API (see the Console section) -- the body says why, then
    -- names the window and the shell. What it does NOT say any more is "press ENTER
    -- to start a session": there is nothing to hand over.
    check("the terminal window names itself below the reason",
          s.find(5, "unixshell terminal") == 6, "[" .. s.row(5) .. "]")
    check("and names the shell it runs", s.find(6, "the shell is /usr/ush.lua") == 6,
          "[" .. s.row(6) .. "]")
    check("the Terminal no longer asks for ENTER to start a session",
          (function()
              for y = 1, 19 do
                  if s.row(y):find("press ENTER", 1, true) then return false end
              end
              return true
          end)(), "press ENTER is still in the window")

    -- Focus and raise. Two windows overlap, so the order they are drawn in is
    -- visible in the cells they share.
    local second = d:open("files")
    check("the second window is stepped to 7,4", second.x == 7 and second.y == 4,
          second.x .. "," .. second.y)
    check("the newest window is the focus", d.focus == second and d:top_window() == second)
    check("the first window's title bar lost the focused colour",
          s.bg(2, 3) == C.black, tostring(s.bg(2, 3)))
    check("the topmost window's own content wins the cells they share",
          s.char(8, 5) == "/", "[" .. tostring(s.char(8, 5)) .. "]")

    click(d, 6, 3)
    check("clicking the first window's title bar focuses it",
          d.focus.id == "terminal", tostring(d.focus and d.focus.id))
    check("and raises it: the order ends with it",
          d.windows[#d.windows].id == "terminal", tostring(d.windows[#d.windows].id))
    check("the raise is visible: the raised window's banner now owns that cell",
          s.char(8, 5) == "i" and s.char(6, 5) == "u",
          "[" .. tostring(s.char(6, 5)) .. tostring(s.char(8, 5)) .. "]")
    check("and its title bar is focused again", s.bg(7, 3) == C.gray,
          tostring(s.bg(7, 3)))
    check("while the window below lost the orange accent mark",
          s.bg(5, 3) == C.orange and s.bg(7, 4) == C.black,
          tostring(s.bg(5, 3)) .. "/" .. tostring(s.bg(7, 4)))

    -- A cell only the second window covers: the terminal is 40 wide and ends at
    -- column 44, the file browser is at 7 and ends at 46.
    click(d, 45, 8)
    check("clicking a body the other window does not cover focuses it",
          d.focus.id == "files", tostring(d.focus and d.focus.id))

    local before = #d.windows
    click(d, 43, 3)
    check("the close control removes the window it belongs to",
          #d.windows == before - 1 and d.stats.closed == 1,
          #d.windows .. " windows, closed=" .. tostring(d.stats.closed))
    check("it is the window the control was drawn on",
          d.windows[1].id == "files", d.windows[1].id)
    check("the focus falls back to the remaining window",
          d.focus and d.focus.id == "files", tostring(d.focus and d.focus.id))
    check("its chrome is gone from the screen", s.find(3, "Terminal") == nil,
          "[" .. s.row(3) .. "]")
    check("the remaining window is still drawn", s.find(4, "Files") == 9,
          tostring(s.find(4, "Files")))

    local win2 = d.windows[1]
    click(d, win2.x + win2.w - 2, win2.y)
    check("closing the last window leaves an empty desktop",
          #d.windows == 0 and d.stats.closed == 2, #d.windows .. " windows")
    check("the wallpaper comes back", s.find(8, "press o") == 16,
          tostring(s.find(8, "press o")))
    check("and no title bar is left anywhere",
          s.find(3, "Files") == nil and s.find(3, "Terminal") == nil)

    -- A window too narrow for a close control has none, and a click where one
    -- would be is a click on the title bar, never a close.
    local d5 = newdesk({ screen = screen.buffer(4, 3) })
    local w5 = d5:open("files")
    check("a window on a four cell screen is three cells wide", w5.w == 3, tostring(w5.w))
    check("and therefore has no close control", desktop.close_rect(w5) == nil)
    click(d5, 4, 1)
    check("so a click in that corner does not close it", #d5.windows == 1, #d5.windows)
end

-- ===========================================================================
section("windows: dragging by the title bar, and the clamp")
-- ===========================================================================
do
    local d, s = newdesk()
    d:draw()
    local win = d:open("files")
    check("the window starts at the geometry the layout gave it",
          win.x == 5 and win.y == 3, win.x .. "," .. win.y)

    click(d, 5, 3)
    check("a press on the title bar starts a drag", d.drag ~= nil and d.drag.win == win)
    d:handle({ "mouse_drag", 1, 30, 12 })
    check("the drag moves the window by the pointer's delta",
          win.x == 12 and win.y == 8, win.x .. "," .. win.y)
    check("and the drawing follows the window",
          s.find(8, "Files") == 14, tostring(s.find(8, "Files")))

    -- Beyond the bottom right corner: the whole frame stays in the workspace, so
    -- the biggest legal x is 5 + 47 - 40 = 12 and the biggest legal y is 8.
    d:handle({ "mouse_drag", 1, 999, 999 })
    check("dragging past the right edge clamps x to the workspace's last column", win.x == 12,
          tostring(win.x))
    check("and past the bottom edge clamps y", win.y == 8, tostring(win.y))
    d:handle({ "mouse_drag", 1, -500, -500 })
    check("dragging past the top left clamps to the workspace's own corner (5,2)",
          win.x == 5 and win.y == 2, win.x .. "," .. win.y)
    check("a window is never dragged out of the workspace",
          win.x >= 5 and win.y >= 2 and win.x + win.w - 1 <= 51 and win.y + win.h - 1 <= 19,
          win.x .. "," .. win.y)

    -- The clamp is a property of the desktop, not of the drag: a direct move is
    -- clamped the same way, so no host can park a window over the dock.
    local d2 = newdesk()
    d2:draw()
    local w2 = d2:open("files")
    w2.x, w2.y = 5, 3
    d2:move_window(w2, 0, 0)
    check("a window moved to 0,0 lands at the workspace's corner, not the screen's",
          w2.x == 5 and w2.y == 2, w2.x .. "," .. w2.y)
    check("so the cell over the dock's column is still the dock",
          d2.screen.char(1, 2) == ">", "[" .. tostring(d2.screen.char(1, 2)) .. "]")
    d2:move_window(w2, 999, 999)
    check("and a window moved past the far corner stops at the workspace's edge",
          w2.x == 12 and w2.y == 8 and w2.x + w2.w - 1 == 51 and w2.y + w2.h - 1 == 19,
          w2.x .. "," .. w2.y)

    d:handle({ "mouse_up", 1, 1, 1 })
    check("mouse_up ends the drag", d.drag == nil)
    local was = win.x
    d:handle({ "mouse_drag", 1, 40, 10 })
    check("a drag with no button held moves nothing", win.x == was, tostring(win.x))

    local d4 = newdesk()
    local w4 = d4:open("files")
    local x4, y4 = w4.x, w4.y
    d4:handle({ "mouse_drag", 1, 20, 9 })
    check("a drag event with no press before it is ignored",
          w4.x == x4 and w4.y == y4, w4.x .. "," .. w4.y)

    local d3 = newdesk({ screen = screen.buffer(20, 5) })
    local w3 = d3:open("files")
    check("a window on a narrow screen fills most of the workspace but stays inside",
          w3.w == 12 and w3.x == 5 and w3.y == 3, w3.w .. " wide at " .. w3.x .. "," .. w3.y)
    click(d3, w3.x + 1, w3.y)
    d3:handle({ "mouse_drag", 1, 19, 4 })
    check("dragging it to the right edge clamps the frame to the screen",
          w3.x == 9 and w3.x + w3.w - 1 == 20, w3.x .. ".." .. (w3.x + w3.w - 1))
end

-- ===========================================================================
section("window resize and tiny screens")
-- ===========================================================================
do
    -- A screen whose size changes under the desktop, which is what term_resize
    -- means: the buffer is the record, the size is the screen's business.
    local function resizable(w, h)
        local inner = screen.buffer(w, h)
        local self = { inner = inner, w = w, h = h }
        self.size = function() return self.w, self.h end
        for _, name in ipairs({ "cell", "text", "fill", "hline", "vline", "clear",
                                "present", "release", "acquire", "row", "fg", "bg",
                                "char", "find", "fg_row", "bg_row" }) do
            self[name] = function(...) return inner[name](...) end
        end
        self.set = function(nw, nh)
            self.w, self.h = nw, nh
            inner.reset(nw, nh)
        end
        return self
    end

    local s = resizable(51, 19)
    local d = desktop.new({ screen = s, clock = "12:34" })
    d:draw()
    local w = d:open("files")
    s.set(20, 5)
    d:handle({ "term_resize" })
    check("term_resize adopts the new size", d.w == 20 and d.h == 5, d.w .. "x" .. d.h)
    check("the panel is redrawn for the new size",
          s.char(1, 1) == "A" and #s.row(1) == 20, #s.row(1) .. " [" .. s.row(1) .. "]")
    check("the clock moved with the new width", s.find(1, "12:34") == 8,
          tostring(s.find(1, "12:34")))
    check("a window larger than the new workspace is clamped into it",
          w.x == 5 and w.y == 2, w.x .. "," .. w.y)
    check("drawing a window bigger than the screen does not raise",
          d.stats.errors == 0, tostring(d.stats.errors))

    local tiny = newdesk({ screen = screen.buffer(1, 1) })
    tiny:draw()
    click(tiny, 1, 1)
    click(tiny, 1, 1)
    tiny:open("terminal")
    tiny:open("calc")
    check("a one cell screen draws and clicks without an error",
          tiny.stats.errors == 0 and tiny.exit == false, tostring(tiny.stats.errors))
    check("and it still recorded what it did", tiny.stats.clicks == 2,
          tostring(tiny.stats.clicks))

    local two = newdesk({ screen = screen.buffer(2, 2) })
    two:draw()
    click(two, 1, 1)
    click(two, 2, 2)
    check("a two cell screen survives opening the overview and clicking a card",
          two.stats.errors == 0, tostring(two.stats.errors))

    local zero = desktop.new({ screen = screen.buffer(0, 0), clock = "12:34" })
    zero:draw()
    check("a screen that reports no size at all is treated as one cell",
          zero.w == 1 and zero.h == 1 and zero.stats.errors == 0,
          zero.w .. "x" .. zero.h .. " errors=" .. tostring(zero.stats.errors))
end

-- ===========================================================================
section("survival: unknown, malformed and hostile events")
-- ===========================================================================
do
    local d = newdesk()
    d:draw()

    d:handle({ "nonsense", 4 })
    check("an unknown event is counted, not raised",
          d.stats.unknown == 1 and d.last_unknown == "nonsense" and d.stats.errors == 0,
          tostring(d.stats.unknown) .. "/" .. tostring(d.last_unknown) .. "/" ..
          tostring(d.stats.errors))
    check("and the loop is still alive afterwards", d.exit == false and d.stats.events == 1)

    local before = d.stats.malformed
    d:handle("a bare string")
    d:handle({})
    d:handle({ true })
    d:handle(nil)
    d:handle(42)
    check("a malformed event is counted in its own counter",
          d.stats.malformed == before + 5, "+" .. tostring(d.stats.malformed - before))
    check("and none of them raised", d.stats.errors == 0 and d.exit == false,
          tostring(d.stats.errors))

    local bad = d.stats.bad_coords
    d:handle({ "mouse_click", 1, "x", 2 })
    d:handle({ "mouse_click", 1, 3, "y" })
    check("coordinates that are not numbers are counted and ignored",
          d.stats.bad_coords == bad + 2, "+" .. tostring(d.stats.bad_coords - bad))

    local others = d.stats.other_buttons
    d:handle({ "mouse_click", 2, 5, 1 })
    check("a click with another button does not open the overview",
          d.stats.other_buttons == others + 1 and d.overview == false,
          tostring(d.stats.other_buttons))

    local scrolls, mode = d.stats.scrolls, d.overview
    d:handle({ "mouse_scroll", -1, 10, 10 })
    check("a wheel event is counted and changes nothing",
          d.stats.scrolls == scrolls + 1 and d.overview == mode, tostring(d.stats.scrolls))

    local malformed = d.stats.malformed
    d:handle({ "key", "not a key" })
    check("a key event without a key code is malformed, not a crash",
          d.stats.malformed == malformed + 1 and d.stats.errors == 0,
          "+" .. tostring(d.stats.malformed - malformed))

    click(d, 5, 1)
    check("a real click still works after the hostile events", d.overview == true)
    d:handle({ "key", desktop.KEYS.f10 })
    click(d, 2, 8)
    check("and the dock still opens an application",
          #d.windows == 1 and d.windows[1].id == "calc",
          tostring(d.windows[1] and d.windows[1].id))
    check("nothing in all of this raised inside a handler",
          d.stats.errors == 0, tostring(d.stats.errors))
end

-- ===========================================================================
section("survival: an app that raises")
-- ===========================================================================
do
    local d, s = newdesk()
    d:register_app({ id = "bomb", name = "Bomb", icon = "***",
                     draw = function() error("boom in draw") end,
                     event = function() error("boom in event") end })
    d:draw()
    d:open("files")
    local bomb = d:open("bomb")
    check("the window still opened", bomb ~= nil and #d.windows == 2, #d.windows)
    check("the raise inside the app was counted", d.stats.app_errors == 1,
          tostring(d.stats.app_errors))
    check("and recorded on the window",
          bomb.error and bomb.error:find("boom in draw", 1, true) ~= nil, tostring(bomb.error))
    check("the window says what happened instead of drawing the app",
          s.find(5, "app error") == 8, "[" .. s.row(5) .. "] error=" .. tostring(bomb.error))
    check("the error is painted in the error colour", s.bg(8, 5) == C.red,
          tostring(s.bg(8, 5)))
    check("the desktop is still running", d.exit == false and d.stats.errors == 0,
          tostring(d.exit) .. "/" .. tostring(d.stats.errors))
    check("and the other window is untouched", s.char(6, 4) == "/",
          "[" .. tostring(s.char(6, 4)) .. "]")

    click(d, bomb.x + 2, bomb.y + 2)
    check("a click into the broken app is counted, not raised",
          d.stats.app_errors == 2 and d.stats.errors == 0,
          tostring(d.stats.app_errors) .. "/" .. tostring(d.stats.errors))
    click(d, 5, 1)
    check("the desktop still handles events after it", d.overview == true)
end

-- ===========================================================================
section("survival: an app whose module is missing")
-- ===========================================================================
do
    local loaded = apps.load({ { id = "ghost", name = "Ghost",
                                 module = "gnome.apps.does_not_exist" } })
    check("the registry keeps the app and records why it is not there",
          #loaded == 1 and loaded[1].error ~= nil and loaded[1].app.unavailable == true,
          tostring(loaded[1].error))
    check("the reason names the module that could not be loaded",
          loaded[1].error:find("gnome.apps.does_not_exist", 1, true) ~= nil,
          tostring(loaded[1].error))

    local s = screen.buffer(51, 19)
    local d = desktop.new({ screen = s, clock = "12:34", entries = loaded,
                            favourites = { "ghost" } })
    d:draw()
    click(d, 5, 1)
    check("the overview lists the unavailable app, marked",
          s.find(6, "Ghost!") == 8, "[" .. s.row(6) .. "]")
    d:handle({ "key", desktop.KEYS.f10 })
    d:open("ghost")
    check("opening it opens a window rather than raising",
          #d.windows == 1 and d.stats.app_errors == 0,
          #d.windows .. " windows, " .. tostring(d.stats.app_errors))
    check("the window says the app is not available",
          s.find(4, "this app is not available") == 6, "[" .. s.row(4) .. "]")
    check("and names the module the operator has to fix",
          s.find(5, "gnome.apps.does_not_exist") == 6, "[" .. s.row(5) .. "]")
    check("the title bar still shows the app it belongs to",
          s.find(3, "Ghost") == 7, "[" .. s.row(3) .. "]")

    local real = apps.load()
    local broken = {}
    for _, entry in ipairs(real) do
        if entry.error then broken[#broken + 1] = entry.id .. ": " .. entry.error end
    end
    check("the shipped registry names seven applications", #real == 7, tostring(#real))
    check("every shipped app module loads from the package",
          #broken == 0, table.concat(broken, "; "))
    local names = {}
    for _, entry in ipairs(real) do names[entry.id] = entry.name end
    check("and they are a terminal, a file browser, settings, a calculator, the " ..
          "task manager, a console and a text editor",
          names.terminal == "Terminal" and names.files == "Files" and
          names.settings == "Settings" and names.calc == "Calculator" and
          names.taskman == "Tasks" and names.console == "Console" and
          names.editor == "Text Editor",
          tostring(names.terminal) .. "/" .. tostring(names.files) .. "/" ..
          tostring(names.settings) .. "/" .. tostring(names.calc) .. "/" ..
          tostring(names.taskman) .. "/" .. tostring(names.console) .. "/" ..
          tostring(names.editor))
end

-- ===========================================================================
section("the apps inside their windows")
-- ===========================================================================
do
    -- The file browser: navigating by clicking the rows it drew.
    _G.FS["/demo"] = { dir = true }
    _G.FS["/demo/alpha"] = { dir = true }
    _G.FS["/demo/note.txt"] = { content = "hello" }
    local d, s = newdesk()
    d:draw()
    local win = d:open("files")
    local body = desktop.body_rect(win)
    check("the file browser opens at the root", s.find(4, "/") == 6, "[" .. s.row(4) .. "]")
    local rows = filesapp.rows(win)
    local at = nil
    for i, row in ipairs(rows) do
        if row.entry and row.entry.name == "demo" then at = i end
    end
    check("the root listing contains the directory that was seeded", at ~= nil,
          tostring(at))
    click(d, body.x, body.y + (at or 1))
    check("one click on a directory only selects it", win.state.path == "/",
          tostring(win.state.path))
    click(d, body.x, body.y + (at or 1))
    check("two quick clicks descend into it", win.state.path == "/demo",
          tostring(win.state.path))
    check("and the path line says where it is",
          s.find(4, "/demo") == 6, "[" .. s.row(4) .. "]")
    check("the listing of the new directory puts the directory first",
          s.find(6, "alpha/") == 6, "[" .. s.row(6) .. "]")
    check("and shows the file with its size",
          s.find(7, "note.txt") == 6, "[" .. s.row(7) .. "]")
    check("the row above them is the way back up", s.find(5, "<..>") == 6,
          "[" .. s.row(5) .. "]")
    click(d, body.x, body.y + 1)
    check("one click on the up row only selects it", win.state.path == "/demo",
          tostring(win.state.path))
    click(d, body.x, body.y + 1)
    check("two clicks on the up row go back to the parent", win.state.path == "/",
          tostring(win.state.path))

    -- The calculator: four clicks with a known answer.
    local d2, s2 = newdesk()
    d2:draw()
    local cwin = d2:open("calc")
    local cbody = desktop.body_rect(cwin)
    -- The geometry is a function of the body (it was a constant grid through
    -- 1.6.0), so the suite asks for the layout of THIS window's interior.
    local lay = calcapp.layout(cbody.w, cbody.h)
    local function button(key)
        for _, b in ipairs(lay.buttons) do
            -- Body relative cell 1 is the body's FIRST cell, so the absolute
            -- coordinate is body + relative - 1: the app measures a click from
            -- the same corner.
            if b.key == key then return cbody.x + b.col - 1, cbody.y + b.row - 1 end
        end
    end
    check("the calculator draws its display line inside the body",
          #lay.buttons == 18, tostring(#lay.buttons))
    for _, key in ipairs({ "7", "+", "3", "=" }) do
        local bx, by = button(key)
        click(d2, bx, by)
    end
    -- The display is right aligned, so "10" ends at the body's last column
    -- (6 + 38 - 1 = 43) and starts at 42.
    check("7 + 3 = reads back as 10 on the display the operator sees",
          s2.find(4, "10") == 42, "[" .. s2.row(4) .. "] error=" .. tostring(cwin.error))
    check("and the keypad is drawn where a click can reach it",
          s2.find(6, "7") == 6 and s2.find(12, "+") == 33,
          tostring(s2.find(6, "7")) .. "/" .. tostring(s2.find(12, "+")))
    local bx, by = button("AC")
    click(d2, bx, by)
    check("AC clears the display", s2.find(4, "0") == 43, "[" .. s2.row(4) .. "]")

    -- Settings: a row that really changes the desktop's own state.
    local d3, s3 = newdesk()
    d3:draw()
    local swin = d3:open("settings")
    local sbody = desktop.body_rect(swin)
    check("the settings window reports the machine",
          s3.find(4, "System") == 6, "[" .. s3.row(4) .. "]")
    check("including the screen the desktop is drawn on",
          s3.find(6, "screen") == 8 and s3.find(6, "51x19") == 17, "[" .. s3.row(6) .. "]")
    check("the panel starts black", s3.bg(20, 1) == C.black, tostring(s3.bg(20, 1)))
    -- The action row is the last row of the interior in 1.7.0 (the panel is
    -- sections now, so "panel colour" and "log out" share that row, side by side).
    local action_row = sbody.y + 9
    click(d3, sbody.x, action_row)
    check("clicking the panel colour row changes the panel's colour",
          s3.bg(20, 1) == C.gray and d3.palette.panel_bg == C.gray,
          tostring(s3.bg(20, 1)))
    check("and the row says which colour it is now",
          s3.find(13, "> panel: gray") == 6, "[" .. s3.row(13) .. "]")
    click(d3, sbody.x, action_row)
    check("clicking it again goes back", s3.bg(20, 1) == C.black, tostring(s3.bg(20, 1)))
    click(d3, sbody.x + settingsapp.COL2 - 1, action_row)
    check("the log out row leaves the desktop",
          d3.exit == true and d3.exit_reason == "logout", tostring(d3.exit_reason))
end

-- ===========================================================================
section("an app's drawing is clipped to its own window")
-- ===========================================================================
do
    -- THE BUG THIS SECTION EXISTS FOR: app_api used to hand write/cell/fill
    -- straight to the screen, and the screen clips at the DISPLAY, not at the
    -- window. One string longer than the interior therefore painted over the
    -- window's border, the window behind it, the dock and the wallpaper -- "the
    -- text ran out of the window". The clip is now in app_api, so every app gets it
    -- without doing anything, and stats.clipped records what it dropped.
    --
    -- The window the default geometry gives the first one is (5,3) 40x12, so its
    -- body is (6,4) 38x10: columns 6..43 and rows 4..13, with the border at column
    -- 44 and the bottom border at row 14.
    local s = screen.buffer(51, 19)
    local d = desktop.new({ screen = s, clock = "12:34" })
    d:register_app({ id = "long", name = "Long", icon = "L!",
        draw = function(api, win)
            api.write(1, 1, string.rep("Z", 60))      -- 60 cells into 38
            api.cell(40, 2, "C")                      -- one past the right edge
            api.write(0, 3, "LEFT")                   -- one cell left of the body
            api.fill(30, 4, 15, 1, "#")               -- 15 cells from column 30
            api.write(api.w, 5, "R")                  -- the body's last column
            api.write(1, 11, "BELOW")                 -- the row below the body
            api.fill(1, 12, 20, 4, "`")               -- four rows below the body
        end })
    d:draw()
    local w = d:open("long")
    local body = desktop.body_rect(w)
    check("the window under test has the body the coordinates below assume",
          body.x == 6 and body.y == 4 and body.w == 38 and body.h == 10,
          body.x .. "," .. body.y .. " " .. body.w .. "x" .. body.h)
    check("a line wider than the body stops at the body's last column",
          s.char(43, 4) == "Z" and s.char(44, 4) == "|",
          tostring(s.char(43, 4)) .. "/" .. tostring(s.char(44, 4)))
    check("and the cells right of the window are not painted at all",
          s.char(45, 4) == " " and s.char(51, 4) == " ",
          "[" .. tostring(s.char(45, 4)) .. tostring(s.char(51, 4)) .. "]")
    check("a cell one past the body's right edge is dropped",
          s.char(44, 5) == "|" and s.char(45, 5) == " ",
          tostring(s.char(44, 5)) .. "/" .. tostring(s.char(45, 5)))
    check("a write that starts left of the body loses only the part outside",
          s.char(5, 6) == "|" and s.find(6, "EFT") == 6,
          "[" .. s.row(6) .. "]")
    check("a fill that runs past the right edge stops at the edge",
          s.char(43, 7) == "#" and s.char(44, 7) == "|" and s.char(45, 7) == " ",
          tostring(s.char(43, 7)) .. "/" .. tostring(s.char(44, 7)))
    check("a write below the body does not reach the window's bottom border",
          s.char(5, 14) == "+" and s.char(6, 14) == "-" and
          s.find(14, "BELOW") == nil, "[" .. s.row(14) .. "]")
    check("a fill that starts below the body does not paint on the desktop",
          s.char(6, 15) == " " and s.char(25, 18) == " ",
          "[" .. tostring(s.char(6, 15)) .. tostring(s.char(25, 18)) .. "]")
    check("the body's own last column is still written",
          s.char(43, 8) == "R", tostring(s.char(43, 8)))
    check("the cells it dropped are counted in stats.clipped",
          d.stats.clipped >= 22, tostring(d.stats.clipped))
    local dump = desktop.dump(s, d)
    check("and the dump reports the counter",
          dump:find(" clipped=", 1, true) ~= nil,
          "[" .. tostring(dump:match("STATS [^\n]")):sub(-40) .. "]")

    -- THE OTHER HALF OF THE CLAIM: the counter does not move for an app that
    -- draws exactly to its edges. Without this, "clipped > 0" would pass for an app
    -- that is simply clipped by the display and mean nothing.
    local s2 = screen.buffer(51, 19)
    local d2 = desktop.new({ screen = s2, clock = "12:34" })
    d2:register_app({ id = "neat", name = "Neat", icon = "N!",
        draw = function(api, win)
            api.write(1, 1, string.rep("q", api.w))
            api.fill(1, api.h, api.w, 1, "q")
            api.cell(api.w, api.h - 1, "q")
            api.write(api.w, 2, "q")
        end })
    d2:draw()
    d2:open("neat")
    d2:draw()
    check("an app that draws exactly to its edges counts no clipped cells",
          d2.stats.clipped == 0, tostring(d2.stats.clipped))
    check("and its last row and last column really are painted",
          s2.find(4, string.rep("q", 38)) == 6 and s2.char(43, 12) == "q",
          "[" .. s2.row(4) .. "]")

    -- AND THE SAME AT THE SCREEN'S BOTTOM RIGHT CORNER: the default geometry puts a
    -- window at (12,8) there, where the window's right edge IS the display's last
    -- column and its bottom edge IS the last row. An unclipped x draw would cover
    -- the border (and the display would hide the rest), and an unclipped y draw
    -- would land on the bottom border.
    local s3 = screen.buffer(51, 19)
    local d3 = desktop.new({ screen = s3, clock = "12:34" })
    d3:register_app({ id = "edge", name = "Edge", icon = "E!",
        draw = function(api, win)
            api.write(1, api.h + 1, "UNDER")
            api.write(1, 1, string.rep("X", 80))
            api.fill(api.w + 1, 1, 20, 3, "!")
            api.fill(1, api.h + 1, 5, 2, "V")
        end })
    local w3 = d3:open("edge")
    d3:move_window(w3, 1000, 1000)
    d3:draw()
    check("the window sits in the bottom right corner of the workspace",
          w3.x == 12 and w3.y == 8 and w3.x + w3.w - 1 == 51 and w3.y + w3.h - 1 == 19,
          w3.x .. "," .. w3.y)
    check("its right border survives a draw 80 cells wide",
          s3.char(51, 9) == "|" and s3.char(50, 9) == "X",
          tostring(s3.char(50, 9)) .. "/" .. tostring(s3.char(51, 9)))
    check("and a draw on its bottom border row does not land on the border",
          s3.char(12, 19) == "+" and s3.char(17, 19) == "-" and
          s3.find(19, "UNDER") == nil and s3.find(19, "VVVVV") == nil,
          "[" .. s3.row(19) .. "]")
    check("its dropped cells are counted too", d3.stats.clipped >= 70,
          tostring(d3.stats.clipped))
end

-- ===========================================================================
section("the handover is a desktop capability, and the Terminal is not it")
-- ===========================================================================
do
    -- 1.6.0: Desktop:handover stays -- a program that needs the whole terminal
    -- still has a shape to ask for -- but no shipped application uses it any more:
    -- the Terminal runs its shell in its own window (the section after this one).
    -- The API is therefore exercised through a SYNTHETIC app, which is honest
    -- about what is under test, and the last block proves the Terminal does not
    -- hand the screen over.
    local calls, released_at_call = {}, nil
    local s = screen.buffer(51, 19)
    local d = desktop.new({ screen = s, clock = "12:34",
        run_shell = function(path)
            calls[#calls + 1] = path
            released_at_call = s.released
            return "session over"
        end })
    d:register_app({ id = "giver", name = "Giver", icon = "G!",
        draw = function(api, win)
            api.write(1, 1, "the handover probe")
            if win.last_result == nil then
                api.write(1, 4, "press ENTER to give the screen away")
            else
                api.write(1, 4, "session ended: " .. tostring(win.last_result))
            end
        end,
        event = function(api, win, ev)
            if ev[1] == "key" and ev[2] == api.keys.enter then
                api.handover()
                return true
            end
            return false
        end })
    d:draw()
    d:open("giver")
    d:handle({ "key", desktop.KEYS.enter })

    check("the app that asks for a handover calls the runner with the shell's path",
          #calls == 1 and calls[1] == "/usr/ush.lua", table.concat(calls, ","))
    check("the screen is released while the shell owns it, so nothing paints over it",
          released_at_call == true, tostring(released_at_call))
    check("the screen is taken back when the shell returns", s.released == false)
    check("the handover is counted as a success",
          d.stats.handovers == 1 and d.stats.handover_ok == 1,
          tostring(d.stats.handovers) .. "/" .. tostring(d.stats.handover_ok))
    check("the runner's answer is remembered",
          d.last_handover and d.last_handover.ok == true and
          tostring(d.last_handover.result) == "session over",
          tostring(d.last_handover and d.last_handover.result))
    check("the desktop is redrawn after the shell exits",
          s.find(1, "Activities") == 1, "[" .. s.row(1) .. "]")
    check("the window reports the session that ended",
          s.find(7, "session ended: session over") == 6, "[" .. s.row(7) .. "]")

    -- A click no longer starts a session: it only focuses the window. Clicking
    -- around the desktop used to throw the operator into a shell they did not ask
    -- for. ENTER is what the window's body says, and ENTER is what starts one.
    calls = {}
    click(d, 8, 6)
    check("a click in the app's body no longer starts a session", #calls == 0,
          tostring(#calls))
    check("it only focuses the window", d.focus ~= nil, tostring(d.focus))
    d:handle({ "key", 28 })
    check("ENTER is still what starts one", #calls == 1, tostring(#calls))

    local s2 = screen.buffer(51, 19)
    local d2 = desktop.new({ screen = s2, clock = "12:34",
        run_shell = function() error("no shell on this machine", 0) end })
    d2:register_app({ id = "giver", name = "Giver", icon = "G!",
        event = function(api, win, ev)
            if ev[1] == "key" and ev[2] == api.keys.enter then api.handover() return true end
            return false
        end })
    d2:draw()
    d2:open("giver")
    d2:handle({ "key", desktop.KEYS.enter })
    check("a shell runner that raises is reported, not propagated",
          d2.last_handover and d2.last_handover.ok == false and
          tostring(d2.last_handover.error):find("no shell on this machine", 1, true) ~= nil,
          tostring(d2.last_handover and d2.last_handover.error))
    check("the screen is taken back even then", s2.released == false)
    check("and the desktop is still running",
          d2.exit == false and d2.stats.errors == 1, tostring(d2.stats.errors))

    -- With no runner given, the desktop uses the machine's own shell.run, which
    -- is the path the machine acceptance exercises for real.
    local real_run = _G.shell.run
    local seen = {}
    _G.shell.run = function(...) seen[#seen + 1] = select(1, ...) return "ran" end
    local s3 = screen.buffer(51, 19)
    local d3 = desktop.new({ screen = s3, clock = "12:34" })
    d3:register_app({ id = "giver", name = "Giver", icon = "G!",
        event = function(api, win, ev)
            if ev[1] == "key" and ev[2] == api.keys.enter then api.handover() return true end
            return false
        end })
    d3:draw()
    d3:open("giver")
    d3:handle({ "key", desktop.KEYS.enter })
    _G.shell.run = real_run
    check("with no runner injected the desktop calls the machine's shell.run",
          #seen == 1 and seen[1] == "/usr/ush.lua", table.concat(seen, ","))
    check("and takes its answer as the session result",
          d3.last_handover and d3.last_handover.ok == true and
          tostring(d3.last_handover.result) == "ran",
          tostring(d3.last_handover and d3.last_handover.result))

    -- THE TERMINAL IS NOT A HANDOVER ANY MORE. This is the block a revert to the
    -- 1.5.0 Terminal trips over: opening it and pressing ENTER must not run a full
    -- screen shell, must not release the screen and must not count a handover --
    -- what it starts is a windowed shell (next section) or, on a machine with no
    -- window API, a window that says why.
    local s4 = screen.buffer(51, 19)
    local ran4 = 0
    local d4 = desktop.new({ screen = s4, clock = "12:34",
        run_shell = function() ran4 = ran4 + 1 return "not this way" end })
    d4:draw()
    local t4 = d4:open("terminal")
    d4:handle({ "key", desktop.KEYS.enter })
    d4:handle({ "key", desktop.KEYS.enter })
    check("the Terminal does not hand the screen over when ENTER is pressed",
          d4.stats.handovers == 0 and d4.last_handover == nil and s4.released == false,
          tostring(d4.stats.handovers) .. "/" .. tostring(d4.last_handover))
    check("and it never runs a full screen shell any more", ran4 == 0, tostring(ran4))
    check("the Terminal stays a window on the desktop instead of leaving it",
          d4.exit == false and #d4.windows == 1 and d4.focus == t4,
          tostring(d4.exit) .. "/" .. tostring(#d4.windows))
end

-- ===========================================================================
section("the keyboard: the back-out ladder and focus cycling")
-- ===========================================================================
do
    local d = newdesk()
    d:draw()
    check("the back-out key is F10, the ROM's code 68, and Escape is not a key here",
          desktop.KEYS.f10 == 68 and desktop.KEYS.escape == nil,
          tostring(desktop.KEYS.f10) .. "/" .. tostring(desktop.KEYS.escape))
    d:handle({ "key", desktop.KEYS.f10 })
    check("F10 with nothing open leaves the desktop",
          d.exit == true and d.exit_reason == "f10", tostring(d.exit_reason))

    local d2 = newdesk()
    d2:draw()
    d2:open("files")
    d2:open("calc")
    check("the second window is the focus", d2.focus.id == "calc", d2.focus.id)
    d2:handle({ "key", desktop.KEYS.tab })
    check("tab cycles the focus to the other window", d2.focus.id == "files", d2.focus.id)
    check("and raises the window it focuses",
          d2.windows[#d2.windows].id == "files", d2.windows[#d2.windows].id)
    d2:handle({ "key", desktop.KEYS.tab })
    check("tab wraps around again", d2.focus.id == "calc", d2.focus.id)

    d2:handle({ "key", desktop.KEYS.f10 })
    check("F10 closes the focused window before it leaves the desktop",
          #d2.windows == 1 and d2.exit == false, #d2.windows)
    d2:handle({ "key", desktop.KEYS.f10 })
    check("a second F10 closes the last window, still not leaving",
          #d2.windows == 0 and d2.exit == false, #d2.windows)
    d2:handle({ "key", desktop.KEYS.f10 })
    check("and only with nothing left does it leave the desktop, reason f10",
          d2.exit == true and d2.exit_reason == "f10", tostring(d2.exit_reason))

    local seen = {}
    local d3 = newdesk()
    d3:register_app({ id = "keysink", name = "Keys", icon = "k",
                      draw = function() end,
                      event = function(api, win, ev) seen[#seen + 1] = ev[1] end })
    d3:draw()
    d3:open("keysink")
    d3:handle({ "key", 32 })
    d3:handle({ "char", "x" })
    check("the focused window's app receives keys and characters",
          #seen == 2 and seen[1] == "key" and seen[2] == "char", table.concat(seen, ","))
    -- The desktop owns this key: matching it has to come before the app call, or
    -- a focused application would see the back-out key too.
    local forwarded = #seen
    d3:handle({ "key", desktop.KEYS.f10 })
    check("the desktop consumes its back-out key instead of forwarding it",
          #seen == forwarded and #d3.windows == 0 and d3.exit == false,
          tostring(#seen) .. " events, " .. tostring(#d3.windows) .. " windows")
    d3:handle({ "key", desktop.KEYS.f10 })
    check("and with no window left the same key is the way out",
          d3.exit == true and d3.exit_reason == "f10", tostring(d3.exit_reason))
end

-- ===========================================================================
section("the dock: favourites, running dots and multiple windows")
-- ===========================================================================
do
    local d, s = newdesk()
    d:draw()
    click(d, 2, 8)
    check("clicking a dock icon opens that application",
          #d.windows == 1 and d.windows[1].id == "calc",
          tostring(d.windows[1] and d.windows[1].id))
    check("a running application gets the orange running dot",
          s.char(2, 9) == desktop.DOT and s.fg(2, 9) == C.orange,
          "[" .. tostring(s.char(2, 9)) .. "] " .. tostring(s.fg(2, 9)))
    check("and one that is not running has a blank cell where the dot would be",
          s.char(2, 3) == " " and s.char(2, 3) ~= desktop.DOT,
          "[" .. tostring(s.char(2, 3)) .. "]")
    check("the icon of a running application is brighter than an idle one",
          s.fg(1, 8) == C.white and s.fg(1, 2) == C.lightGray,
          tostring(s.fg(1, 8)) .. "/" .. tostring(s.fg(1, 2)))

    -- THE POINT OF THIS SECTION: a second click is a second window. This used to
    -- raise the first, and then "two file browsers" was impossible.
    local first = d.windows[1]
    click(d, 2, 8)
    check("clicking the same dock icon again opens a SECOND window",
          #d.windows == 2 and d.windows[1] == first and d.stats.opened == 2,
          #d.windows .. " windows, opened=" .. tostring(d.stats.opened))
    check("the second copy is titled Calculator 2 and the first keeps its name",
          d.windows[1].title == "Calculator" and d.windows[2].title == "Calculator 2",
          tostring(d.windows[1].title) .. "/" .. tostring(d.windows[2].title))
    check("the two copies are separate windows with separate state",
          rawequal(d.windows[1], d.windows[2]) == false and
          rawequal(d.windows[1].state, d.windows[2].state) == false,
          "the state table is shared")
    check("the dot stays on with two windows open",
          s.char(2, 9) == desktop.DOT and s.fg(2, 9) == C.orange, tostring(s.fg(2, 9)))
    check("the run indicator is per application, not per window",
          s.char(2, 3) == " ", "[" .. tostring(s.char(2, 3)) .. "]")
    check("a click on the running dot opens a window too",
          (function()
              local before = #d.windows
              click(d, 2, 9)
              return #d.windows == before + 1 and d.windows[#d.windows].title == "Calculator 3"
          end)())
    check("the third copy is titled Calculator 3",
          d.windows[#d.windows].title == "Calculator 3", d.windows[#d.windows].title)
    check("clicking the black of the dock between two icons opens nothing",
          (function()
              local before = #d.windows
              click(d, 2, 12)
              return #d.windows == before
          end)())
end

-- ===========================================================================
section("many windows: one application, independent copies")
-- ===========================================================================
do
    -- The same application twice: both open, both drawn, both with their own
    -- state, closing one leaves the other. "It opened" is not enough here -- the
    -- file browser's directory is the known answer.
    local d, s = newdesk()
    d:draw()
    local one = d:open("files")
    local two = d:open("files")
    check("two opens of one application are two different windows",
          one ~= two and #d.windows == 2, tostring(#d.windows))
    check("both are in the window list, in the order they were made",
          d.windows[1] == one and d.windows[2] == two)
    check("the titles are Files and Files 2",
          d.windows[1].title == "Files" and d.windows[2].title == "Files 2",
          tostring(d.windows[1].title) .. "/" .. tostring(d.windows[2].title))
    check("they are drawn at different places, so both can be seen",
          one.x ~= two.x or one.y ~= two.y, one.x .. "," .. one.y .. " / " .. two.x .. "," .. two.y)

    -- The directory one copy is in must not move the other: win.state is the
    -- whole of an app's per-window memory. The second copy is moved out of the
    -- way first, so both path lines are read off the screen at once.
    d:move_window(two, 12, 8)
    one.state.path = "/demo"
    d:draw()
    check("one copy moves without the other moving",
          one.state.path == "/demo" and two.state.path == "/",
          tostring(one.state.path) .. "/" .. tostring(two.state.path))
    check("and the screen shows the two different directories",
          s.find(4, "/demo") == 6 and s.find(9, "/") == 13,
          tostring(s.find(4, "/demo")) .. "/" .. tostring(s.find(9, "/")))

    -- The dock's dot is on with both, and closing one leaves the other.
    check("the dock dot is on while both copies are open",
          s.char(2, 5) == desktop.DOT and s.fg(2, 5) == C.orange,
          "[" .. tostring(s.char(2, 5)) .. "]")
    d:close_window(one)
    check("closing one copy leaves the other open",
          #d.windows == 1 and d.windows[1] == two, tostring(#d.windows))
    check("and the survivor is retitled Files, because it is the only one",
          d.windows[1].title == "Files", d.windows[1].title)
    check("the dock dot is still on for the survivor",
          s.char(2, 5) == desktop.DOT, "[" .. tostring(s.char(2, 5)) .. "]")
    d:close_window(two)
    check("closing the last one turns the dot off",
          #d.windows == 0 and s.char(2, 5) == " " and s.char(2, 5) ~= desktop.DOT,
          "[" .. tostring(s.char(2, 5)) .. "]")

    -- Three windows of one application, then close the middle one: the numbers
    -- are renumbered so there is no "Files 3" without a "Files 2".
    local w1 = d:open("files")
    local w2 = d:open("files")
    local w3 = d:open("files")
    check("a third copy is titled Files 3",
          w3.title == "Files 3" and w2.title == "Files 2" and w1.title == "Files",
          tostring(w3.title))
    check("all three are listed by the task manager's window list",
          #d.windows == 3, tostring(#d.windows))
    d:close_window(w2)
    check("closing the middle one renumbers the rest without a gap",
          w1.title == "Files" and w3.title == "Files 2" and #d.windows == 2,
          w1.title .. "/" .. w3.title)
    local dump = desktop.dump(s, d)
    check("the dump tells the two same-application windows apart by title",
          dump:find("WINDOW 1 id=files title=Files ", 1, true) ~= nil and
          dump:find("WINDOW 2 id=files title=Files 2 ", 1, true) ~= nil,
          "[" .. tostring(dump:match("WINDOW 2 [^\n]*")) .. "]")
    -- The Console is the case where a window owns hardware: each copy asks for its
    -- own ROM window (window.create under its own interior) and its own pump. The
    -- PC stub has no window API, so what is asserted here is the part that can be
    -- asserted without one: the two copies are separate windows with separate
    -- state, and each names the missing API for itself.
    local dc = newdesk()
    dc:draw()
    local c1 = dc:open("console")
    local c2 = dc:open("console")
    check("two Console windows are two windows with their own state",
          c1 ~= c2 and rawequal(c1.state, c2.state) == false and
          c1.state.problem ~= nil, tostring(c1.state.problem))
    check("each Console names the missing window API for itself",
          c2.state.problem ~= nil and
          c2.state.problem:find("no window API", 1, true) ~= nil,
          tostring(c2.state.problem))
end

-- ===========================================================================
section("the headless run path")
-- ===========================================================================
do
    local events = desktop.parse_events([[
# the overview, then a card
mouse_click 1 5 1
mouse_click 1 6 6
]])
    check("the script parser reads one event per line",
          #events == 2 and events[1][1] == "mouse_click" and events[1][4] == 1 and
          events[2][3] == 6, #events .. " events")
    check("a comment line and a blank line are not events",
          (function()
              local more = desktop.parse_events("# nothing\n\n   \nkey 28\n")
              return #more == 1 and more[1][1] == "key" and more[1][2] == 28
          end)())
    check("an unknown event name parses into an event all the same",
          (function()
              local more = desktop.parse_events("nonsense 4\n")
              return #more == 1 and more[1][1] == "nonsense" and more[1][2] == 4
          end)())
    check("the parser is not confused by CRLF or a missing final newline",
          (function()
              local more = desktop.parse_events("key 28\r\nmouse_click 1 2 3")
              return #more == 2 and more[1][2] == 28 and more[2][2] == 1
          end)())

    local scr, d = desktop.run({ screen = screen.buffer(51, 19), clock = "12:34",
                                 events = events })
    check("run returns the screen it drew into", scr ~= nil and scr.kind == "buffer")
    check("and the desktop that drew it",
          d ~= nil and d.stats.events == 2 and d.stats.clicks == 2,
          tostring(d and d.stats.events))
    check("the last frame shows the window the second click opened",
          scr.find(3, "Terminal") == 7, "[" .. scr.row(3) .. "]")

    check("run stops when the desktop exits, and counts the events it took",
          (function()
              local _, dd = desktop.run({ screen = screen.buffer(51, 19), clock = "12:34",
                  events = desktop.parse_events("key 68\nmouse_click 1 5 1\n") })
              return dd.exit == true and dd.overview == false and dd.stats.events == 1
          end)())

    local text = desktop.dump(scr, d)
    check("the dump names the size of the screen", text:find("SIZE 51 19", 1, true) ~= nil)
    check("the dump has a line per row of characters",
          text:find("ROW 1 Activities", 1, true) ~= nil and
          text:find("ROW 19", 1, true) ~= nil and
          text:find("ROW 2 >_ |", 1, true) ~= nil)
    check("the dump carries the foreground letters per row",
          text:find("FG 1 000", 1, true) ~= nil)
    check("the dump carries the background letters per row",
          -- The dock and its separator are black (f); the wallpaper's last row is
          -- the last redefined slot, which is brown, whose blit letter is c.
          text:find("BG 19 ffffc", 1, true) ~= nil,
          (text:match("BG 19 %S+") or "no BG 19 line"))
    check("the dump reports the window list",
          text:find("WINDOWS 1", 1, true) ~= nil and
          text:find("WINDOW 1 id=terminal title=Terminal x=5 y=3 w=40 h=12", 1, true) ~= nil)
    check("the dump reports the dock and the workspace a window may use",
          text:find("DOCK terminal,files,settings,calc", 1, true) ~= nil and
          text:find("DOCKW 3", 1, true) ~= nil and
          text:find("WORK x=5 y=2 w=47 h=18", 1, true) ~= nil)
    check("the dump reports the mode and the counters",
          text:find("MODE desktop", 1, true) ~= nil and
          text:find("STATS events=2 clicks=2", 1, true) ~= nil and
          text:find("EXIT false", 1, true) ~= nil)
end

-- ===========================================================================
section("a screen that raises cannot take the desktop down")
-- ===========================================================================
do
    local broken = { size = function() return 10, 3 end,
                     clear = function() error("no screen", 0) end }
    for _, name in ipairs({ "cell", "text", "fill", "present", "release", "acquire",
                            "row", "fg", "bg", "char", "find", "fg_row", "bg_row",
                            "hline", "vline" }) do
        broken[name] = function() return 0 end
    end
    local d = desktop.new({ screen = broken, clock = "12:34" })
    local ok = pcall(function()
        d:handle({ "mouse_click", 1, 5, 1 })
        d:handle({ "key", desktop.KEYS.o })
    end)
    check("a screen whose clear() raises does not raise out of handle", ok == true,
          tostring(ok))
    check("the failure is counted as an error", d.stats.errors >= 1, tostring(d.stats.errors))
    check("the last error names what happened",
          d.last_error and d.last_error:find("no screen", 1, true) ~= nil,
          tostring(d.last_error))
    check("the desktop is still processing events",
          d.stats.events == 2 and d.exit == false, tostring(d.stats.events))
end

-- ===========================================================================
section("the package a repository serves")
-- ===========================================================================
--
-- The manifest is a host file, and the rules that read it live in lib/pkg.lua
-- (key=value lines, comma separated bin and depends) and in pkgserver.lua (the
-- version line, and the directory name as the package name). The emulated
-- filesystem cannot see the repository, so these are the only checks that can
-- look at the real package at all.
do
    local HOST = _G.read_host_file
    local PKGDIR = PROJ .. "/tools/pkgs/gnome"
    local probe
    do
        local okh, value = pcall(function() return HOST(PKGDIR .. "/manifest") end)
        probe = okh and value or nil
    end
    if type(probe) ~= "string" or #probe == 0 then
        skip("the package manifest", "read_host_file cannot read the project tree")
    else
        local keys, values, stray = {}, {}, {}
        for line in (probe .. "\n"):gmatch("([^\r\n]*)\r?\n") do
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local k, v = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
                if k then
                    keys[#keys + 1] = k
                    values[k] = v
                else
                    stray[#stray + 1] = line
                end
            end
        end
        check("every manifest line is a key=value line the package manager can read",
              #stray == 0, table.concat(stray, " | "))
        check("the manifest declares a version, which pkgserver reports from it",
              values.version == "1.8.5", tostring(values.version))
        check("the version is of the shape semver compares",
              tostring(values.version):match("^%d+%.%d+%.%d+$") ~= nil, tostring(values.version))
        check("the manifest says the shells run in windows of their own",
              values.desc ~= nil and
              values.desc:find("inside its own window", 1, true) ~= nil,
              tostring(values.desc))
        check("the manifest publishes the command desktop",
              values.bin == "desktop", tostring(values.bin))
        check("it declares no package dependencies",
              values.depends == nil or values.depends == "", tostring(values.depends))
        local forced = {}
        for _, k in ipairs(keys) do
            if k:match("^requires") then forced[#forced + 1] = k end
        end
        check("it forces no medium or feature on the machine that installs it",
              #forced == 0, table.concat(forced, ","))
        check("the package directory name is the whole package name, as pkgserver requires",
              PKGDIR:match("([^/\\]+)$") == "gnome", PKGDIR)

        local bin = HOST(PKGDIR .. "/bin/desktop.lua")
        check("the command the manifest publishes is a file in the package",
              type(bin) == "string" and #bin > 0)
        check("the command has the headless path the machine acceptance uses",
              type(bin) == "string" and bin:find("--headless", 1, true) ~= nil)
        check("the command reports a package whose modules are unreachable instead of tracing back",
              type(bin) == "string" and
              bin:find('xpcall(function() return require("gnome.desktop") end', 1, true) ~= nil and
              bin:find("cannot load gnome.desktop", 1, true) ~= nil,
              "a traceback at the operator's prompt is the failure this avoids")
        check("the command returns a status rather than calling os.exit",
              type(bin) == "string" and bin:find("os.exit", 1, true) == nil)
        -- THE OPTIONAL BOOT SESSION. ush is the default, `desktop` is the way in,
        -- and --autostart makes the NEXT boot start the desktop instead. What is
        -- pinned here is that the command writes the SESSION KEY (a generic one,
        -- which the base boot script reads) and refuses the switch without root.
        check("the command can make the desktop the session the machine boots into",
              type(bin) == "string" and bin:find("--autostart", 1, true) ~= nil and
              bin:find("/etc/session.conf", 1, true) ~= nil and
              bin:find("command=", 1, true) ~= nil,
              "no session switch in the command")
        check("and it refuses that switch without root, naming the command to use",
              type(bin) == "string" and
              bin:find("--autostart needs root", 1, true) ~= nil and
              bin:find("sudo desktop --autostart", 1, true) ~= nil)
        check("the boot script waits for an explicit session key instead of one package",
              type(bin) == "string" and
              bin:find('keep[#keep + 1] = "command=" .. command', 1, true) ~= nil and
              bin:find('local wanted = (mode == "on") and "desktop" or nil', 1, true) ~= nil,
              "the command has to write the same key the boot script reads")
        local mod = HOST(PKGDIR .. "/lib/gnome/desktop.lua")
        check("the desktop module is in the package's lib/ directory",
              type(mod) == "string" and #mod > 0)
        check("and it is the module the command loads",
              type(mod) == "string" and mod:find("function desktop.run", 1, true) ~= nil)

        -- ESCAPE IS NOT A KEY THIS MACHINE RECEIVES. The desktop and the editor
        -- used to compare against the ROM's escape code (1); Minecraft keeps ESC
        -- for its own menu, so keys.escape is nil and those branches were dead.
        -- The back-out key is now F10 (68) and the editor's find key F9 (67).
        -- The scan looks for the identifier and the constant, not for the word
        -- "Escape": the comments have to be able to say why it is gone.
        local code = { "lib/gnome/desktop.lua", "lib/gnome/apps/editor.lua",
                       "lib/gnome/apps/shellwin.lua", "lib/gnome/apps/settings.lua",
                       "lib/gnome/apps/calc.lua", "bin/desktop.lua" }
        local stale, missing = {}, {}
        for _, rel in ipairs(code) do
            local text = HOST(PKGDIR .. "/" .. rel)
            if type(text) ~= "string" then
                missing[#missing + 1] = rel
            elseif text:find("KEYS%.escape", 1) or
                   text:find("escape%s*=%s*1[%s,}]", 1) then
                stale[#stale + 1] = rel
            end
        end
        check("every source that could use the ROM's escape code is present to scan",
              #missing == 0, table.concat(missing, ","))
        check("no package source still uses the ROM's escape key code or KEYS.escape",
              #stale == 0, table.concat(stale, ","))
        check("the desktop's back-out key is F10 (68) and its exit reason names it",
              type(mod) == "string" and mod:find("f10%s*=%s*68", 1) ~= nil and
              mod:find('quit%("f10"%)', 1) ~= nil)
        local edsrc = HOST(PKGDIR .. "/lib/gnome/apps/editor.lua")
        check("the editor leaves find with F9 (67), a key the machine delivers",
              type(edsrc) == "string" and edsrc:find("f9%s*=%s*67", 1) ~= nil)
        local swsrc = HOST(PKGDIR .. "/lib/gnome/apps/shellwin.lua")
        check("the window tells the operator the key that actually closes it",
              type(swsrc) == "string" and
              swsrc:find("press F10 to close", 1, true) ~= nil)

        -- A package that required the base installation's modules would not be
        -- optional; requiring only its own is what makes it an extra package.
        local files = { "lib/gnome/screen.lua", "lib/gnome/desktop.lua", "lib/gnome/apps.lua",
                        "lib/gnome/fmt.lua",
                        "lib/gnome/apps/terminal.lua", "lib/gnome/apps/files.lua",
                        "lib/gnome/apps/settings.lua", "lib/gnome/apps/calc.lua" }
        local foreign = {}
        for _, rel in ipairs(files) do
            local text = HOST(PKGDIR .. "/" .. rel)
            if type(text) ~= "string" then
                foreign[#foreign + 1] = rel .. " (missing)"
            else
                for name in text:gmatch('require%s*%(%s*"([^"]+)"') do
                    if not name:match("^gnome%.") then foreign[#foreign + 1] = rel .. " -> " .. name end
                end
                for name in text:gmatch("require%s*%(%s*'([^']+)'") do
                    if not name:match("^gnome%.") then foreign[#foreign + 1] = rel .. " -> " .. name end
                end
            end
        end
        check("the package's modules require nothing but the package's own modules",
              #foreign == 0, table.concat(foreign, "; "))
        for _, rel in ipairs(files) do
            check("the package carries " .. rel, type(HOST(PKGDIR .. "/" .. rel)) == "string")
        end

        -- tools/ is where a HOST side package source belongs: it is in
        -- tools/deploy.py's SKIP_DIRS, so no deploy can put it on a machine.
        -- Checked here against the source of the rule itself.
        local depl = HOST(PROJ .. "/tools/deploy.py")
        if type(depl) ~= "string" then
            skip("tools/ is out of the deployed tree", "tools/deploy.py cannot be read")
        else
            local at = depl:find("SKIP_DIRS%s*=%s*{")
            local close = at and depl:find("}", at)
            local header = (at and close) and depl:sub(at, close) or ""
            check("the package source lives under tools/, which deploy.py skips",
                  header:find('"tools"', 1, true) ~= nil, "[" .. header:sub(1, 80) .. "]")
            check("and tests/ is skipped by the same rule",
                  header:find('"tests"', 1, true) ~= nil)
            check("the deploy tool does not know the desktop package by name",
                  depl:find("gnome", 1, true) == nil,
                  "a deploy that mentioned it would be a machine copy, not a package")
        end

        -- THE COMMAND ENVIRONMENT, which is what the machine acceptance found and
        -- this suite could not: the ROM keeps require, package and shell in the
        -- environment it hands a program (rom/programs/shell.lua, createShellEnv)
        -- and NOT in _G, while loadfile() gives a chunk the default environment. So
        -- on a real machine a command file saw require as nil -- measured:
        -- usr/cmd/w.lua:12: attempt to call global 'require' (a nil value) -- and
        -- every external command of this project that loads a module was broken,
        -- while this suite stayed green because the stub has a global require. The
        -- two lines of usr/ush.lua that fix it are pinned here so they cannot be
        -- dropped again.
        local ushsrc = (_G.SH_SRC or {}).ush
        if type(ushsrc) ~= "string" then
            skip("the command environment", "usr/ush.lua is not in SH_SRC")
        else
            local at = ushsrc:find("local chunk, err = loadfile(full)", 1, true)
            -- The same file is where the OPTIONAL SESSION is read (see the
            -- startup section below): pinned as text because a boot script cannot
            -- be run by a suite. It is generic -- one key, no package name -- so
            -- the assertion further down that no base file names the package still
            -- holds, and a machine that never sets the key boots into ush.
            local startl = (_G.SH_SRC or {}).startup
            check("the boot script reads an optional session command from /etc/session.conf",
                  type(startl) == "string" and
                  startl:find('local SESSION_CONF = "/etc/session.conf"', 1, true) ~= nil and
                  startl:find('key == "command"', 1, true) ~= nil,
                  "the base boot path has no session key")
            check("and runs it through ush before the shell, at most once per boot",
                  type(startl) == "string" and
                  startl:find('if not session_done then', 1, true) ~= nil and
                  startl:find("shell.run(LAUNCH_TARGET, \"-c\", session_cmd)", 1, true) ~= nil and
                  select(2, startl:gsub("session_done", "")) >= 3,
                  "the one-shot guard or the ush launch is missing")
            check("the shell loads an external command file with loadfile", at ~= nil)
            local window = at and ushsrc:sub(at, at + 2600) or ""
            check("and runs it in an environment whose __index is the shell's, " ..
                  "so require/package/shell are the ones the ROM gave the shell",
                  window:find("setfenv", 1, true) ~= nil and
                  window:find("__index = getfenv(1)", 1, true) ~= nil,
                  window:sub(1, 100))
            -- The command's own table also says THAT the shell started it. A
            -- program that takes the whole screen and gives it back (the desktop
            -- does) needs the fact: returning to a shell command IS the prompt,
            -- returning to a boot script or the CraftOS prompt is not.
            check("and the command's environment says a shell started it " ..
                  "(__ush_command), which is what a full screen program lands by",
                  window:find("penv.__ush_command = true", 1, true) ~= nil,
                  window:sub(1, 100))
        end

        -- Nothing in the base installation may reference the package: it is
        -- installed with pkg, so the machine that never installs it must not
        -- look for it anywhere.
        local base = { { "startup.lua", (_G.SH_SRC or {}).startup },
                       { "usr/ush.lua", (_G.SH_SRC or {}).ush },
                       { "lib/pkg.lua", HOST(PROJ .. "/lib/pkg.lua") } }
        local mentioning = {}
        for _, pair in ipairs(base) do
            if type(pair[2]) == "string" and pair[2]:find("gnome", 1, true) then
                mentioning[#mentioning + 1] = pair[1]
            end
        end
        check("no base file names the desktop package", #mentioning == 0,
              table.concat(mentioning, ", "))
    end
end

-- ===========================================================================
section("multitasking: the tasks the desktop schedules")
-- ===========================================================================
do
    -- Two applications whose main() is a loop. The claim of this section is that
    -- both make progress in ONE run, and the counters are the evidence: "it did
    -- not raise" would be satisfied by a task that never ran at all.
    local log = {}
    local d, s = newdesk()
    d:register_app({ id = "a", name = "A", icon = "A", main = function(api)
        while true do
            log[#log + 1] = "a"
            api.task.sleep(0.1)
        end
    end })
    d:register_app({ id = "b", name = "B", icon = "B", main = function(api)
        while true do
            log[#log + 1] = "b"
            api.task.yield()
        end
    end })
    local wa = d:open("a")
    local wb = d:open("b")
    check("opening an app that defines main starts a task for it",
          #d.tasks == 2 and d.stats.tasks_started == 2, tostring(#d.tasks))
    check("the app gets its first slice before the frame that shows it",
          table.concat(log) == "ab", table.concat(log))
    check("a sleeping task is suspended in a sleep, not spun",
          d.tasks[1].status == "suspended" and d.tasks[1].waiting == "sleep",
          tostring(d.tasks[1].status) .. "/" .. tostring(d.tasks[1].waiting))

    -- A tick is time. Both directions are asserted, because "the task ran" alone
    -- would also pass with the sleep ignored.
    d:handle({ "tick" })
    check("one tick does not wake a task that asked for 0.1 s",
          table.concat(log) == "abb", table.concat(log))
    check("and the clock moved by exactly one step",
          math.abs(d.now - 0.05) < 1e-9, tostring(d.now))
    d:handle({ "tick" })
    check("the second tick does wake it (0.1 s is two steps)",
          table.concat(log) == "abbab", table.concat(log))
    check("both tasks made progress in the same run",
          select(2, table.concat(log):gsub("a", "")) == 2 and
          select(2, table.concat(log):gsub("b", "")) == 3, table.concat(log))
    check("a tick is not counted as an event", d.stats.events == 0,
          tostring(d.stats.events))
    check("but it is counted as a tick", d.stats.ticks == 2, tostring(d.stats.ticks))

    -- A task waiting for an event is woken by an event and NOT by the clock.
    local hits = 0
    d:register_app({ id = "c", name = "C", icon = "C", main = function(api)
        while true do
            api.task.wait_event()
            hits = hits + 1
        end
    end })
    d:open("c")
    check("a task that waits for an event has not run yet", hits == 0, tostring(hits))
    d:handle({ "tick" })
    check("and a tick does not wake it", hits == 0, tostring(hits))
    d:handle({ "key", 99 })
    check("an event does wake it", hits == 1, tostring(hits))

    -- A raise inside a task belongs to the task. The desktop keeps its other
    -- tasks running, which is the property that makes a scheduler usable.
    d:register_app({ id = "bomb2", name = "Boom", icon = "!", main = function()
        error("task exploded")
    end })
    local wbomb = d:open("bomb2")
    check("a task that raises is counted and not propagated",
          d.stats.task_errors == 1 and d.stats.errors == 0,
          tostring(d.stats.task_errors) .. "/" .. tostring(d.stats.errors))
    check("and the window it belonged to carries the reason",
          wbomb and wbomb.task_error and
          wbomb.task_error:find("task exploded", 1, true) ~= nil,
          tostring(wbomb and wbomb.task_error))
    local before_b = select(2, table.concat(log):gsub("b", ""))
    d:handle({ "tick" })
    check("the tasks of the other windows keep running after it",
          select(2, table.concat(log):gsub("b", "")) > before_b, table.concat(log))

    -- A task can spawn another one, and the spawn is scheduled rather than run
    -- where it was asked for: a task that could run another to completion would
    -- not be cooperative at all.
    local spawned = 0
    d:register_app({ id = "spawner", name = "Spawn", icon = "S", main = function(api)
        api.task.spawn(function() spawned = spawned + 1 end, "worker")
        while true do api.task.sleep(1) end
    end })
    local wsp = d:open("spawner")
    check("a task can spawn a second task for its window",
          #wsp.tasks == 2 and d.stats.tasks_started == #d.tasks,
          tostring(#wsp.tasks))
    check("and the spawned task has not run in place", spawned == 0, tostring(spawned))
    d:handle({ "tick" })
    check("it runs on the next tick", spawned == 1, tostring(spawned))

    -- Closing a window stops its tasks: a resumed task would otherwise draw into
    -- a window that is no longer there.
    local before_close = select(2, table.concat(log):gsub("b", ""))
    d:close_window(wb)
    check("closing a window stops the task that belonged to it",
          wb.tasks and wb.tasks[1].status == "dead" and
          wb.tasks[1].stopped == "window closed",
          tostring(wb.tasks and wb.tasks[1].status))
    d:handle({ "tick" })
    check("and a stopped task is never resumed again",
          select(2, table.concat(log):gsub("b", "")) == before_close,
          table.concat(log))
    check("the desktop counted the finished task",
          d.stats.tasks_finished >= 1, tostring(d.stats.tasks_finished))

    local text = desktop.dump(s, d)
    check("the dump reports the clock", text:find("CLOCK now=", 1, true) ~= nil)
    check("the dump counts the scheduler",
          text:find("TASKS ", 1, true) ~= nil and text:find("TASK 1 name=A", 1, true) ~= nil,
          "[" .. tostring(text:match("TASKS [^\n]*")) .. "]")

    -- The application that ships with the package is itself a task, and its count
    -- of ticks is what a reader can see without any assertion hook.
    local d2, s2 = newdesk()
    d2:draw()
    local wt = d2:open("taskman")
    check("the shipped task manager opens", wt ~= nil and #d2.tasks == 1,
          tostring(wt and #d2.tasks))
    check("it draws its own picture", s2.find(4, "windows: 1") == 6,
          "[" .. s2.row(4) .. "]")
    check("and its task starts at zero ticks", s2.find(5, "ticks: 0") ~= 0,
          "[" .. s2.row(5) .. "]")
    d2:handle({ "tick" })
    d2:handle({ "tick" })
    check("its task counts the ticks it was resumed for", s2.find(5, "ticks: 2") ~= 0,
          "[" .. s2.row(5) .. "]")
    check("and the clock it prints is the desktop's own", s2.find(6, "now: 0.10") ~= 0,
          "[" .. s2.row(6) .. "]")
end

-- ===========================================================================
section("overlays: drawn last, offered events first")
-- ===========================================================================
do
    -- An app that records the clicks it is given, so "the overlay ate it" is a
    -- fact about the application and not about the desktop's counters.
    local got = {}
    local d, s = newdesk()
    d:register_app({ id = "sink", name = "Sink", icon = "S",
        draw = function(api) api.write(1, 1, "sink body") end,
        event = function(api, win, ev)
            if ev[1] == "mouse_click" then got[#got + 1] = ev[3] .. "," .. ev[4] end
        end })
    d:draw()
    local win = d:open("sink")
    check("the app is open and focused", win ~= nil and #d.windows == 1)
    click(d, win.x + 1, win.y + 1)
    check("a click reaches the app when nothing is on top", #got == 1,
          table.concat(got, " "))

    -- The overlay is drawn after the panel, so it can cover row 1 -- something no
    -- application can do, because every window is painted before the panel.
    local eaten = 0
    local ov = d:push_overlay({
        name = "modal",
        draw = function(api)
            api.write(1, 1, "MODAL", C.black, C.lightGray)
            api.write(win.x + 1, win.y + 1, "COVER", C.black, C.lightGray)
        end,
        event = function(api, ev)
            if ev[1] == "mouse_click" then eaten = eaten + 1 return true end
        end,
    })
    check("the overlay was pushed and carries its name",
          ov ~= nil and d:overlay_depth() == 1 and ov.name == "modal",
          tostring(ov and ov.name))
    d:draw()
    check("an overlay is drawn over the panel row", s.row(1):sub(1, 5) == "MODAL",
          "[" .. s.row(1) .. "]")
    check("and over a window's interior, which no app can reach",
          s.char(win.x + 1, win.y + 1) == "C",
          "[" .. tostring(s.char(win.x + 1, win.y + 1)) .. "]")
    click(d, win.x + 1, win.y + 1)
    check("the overlay is offered the event before the app", eaten == 1, tostring(eaten))
    check("so the click never reaches the window underneath", #got == 1,
          table.concat(got, " "))
    check("and the desktop counted it as eaten", d.stats.overlay_events == 1,
          tostring(d.stats.overlay_events))

    -- Topmost first: the operator acts on what they can see.
    local first, second = 0, 0
    d:push_overlay({ name = "one", event = function() first = first + 1 return true end })
    d:push_overlay({ name = "two", event = function() second = second + 1 return true end })
    click(d, 5, 5)
    check("the topmost overlay is offered the event first",
          second == 1 and first == 0, tostring(first) .. "/" .. tostring(second))
    check("popping hands the next event to the one below",
          d:pop_overlay() == true and d:overlay_depth() == 2, tostring(d:overlay_depth()))
    click(d, 5, 5)
    check("which is now the one that gets it", first == 1 and second == 1,
          tostring(first) .. "/" .. tostring(second))
    d:pop_overlay()
    check("with the modal on top again the app is still shielded", d:overlay_depth() == 1)
    click(d, win.x + 1, win.y + 1)
    check("the modal is the one that ate it", eaten == 2 and #got == 1,
          tostring(eaten) .. "/" .. tostring(#got))
    d:pop_overlay()
    click(d, win.x + 1, win.y + 1)
    check("and with nothing on top the app receives the click again", #got == 2,
          table.concat(got, " "))

    -- A raise inside an overlay is contained, like an app's: the frame still
    -- paints and the desktop still handles events.
    d:push_overlay({ name = "bad",
        draw = function() error("overlay draw exploded") end,
        event = function() error("overlay event exploded") end })
    d:draw()
    check("an overlay that raises while drawing is counted",
          d.stats.overlay_errors >= 1, tostring(d.stats.overlay_errors))
    check("and the desktop is unharmed", d.exit == false and d.stats.errors == 0,
          tostring(d.exit) .. "/" .. tostring(d.stats.errors))
    click(d, win.x + 1, win.y + 1)
    check("one that raises while handling an event is counted too",
          d.stats.overlay_errors >= 2, tostring(d.stats.overlay_errors))
    check("and the event still reaches the window below", #got == 3,
          table.concat(got, " "))
    d:pop_overlay()

    -- An overlay belongs to the window that asked for it, and dies with it.
    d:register_app({ id = "modalapp", name = "Modal", icon = "M",
        open = function(api) api.overlay({ name = "app modal", draw = function() end }) end })
    local depth = d:overlay_depth()
    local wm = d:open("modalapp")
    check("an app can push an overlay through its own api",
          d:overlay_depth() == depth + 1, tostring(d:overlay_depth()))
    check("and the overlay is owned by that window",
          d.overlays[#d.overlays] ~= nil and d.overlays[#d.overlays].window == wm)
    d:close_window(wm)
    check("closing the window drops the overlay with it",
          d:overlay_depth() == depth, tostring(d:overlay_depth()))

    local text = desktop.dump(s, d)
    check("the dump reports the overlays",
          text:find("OVERLAYS ", 1, true) ~= nil, "[" .. s.row(1) .. "]")

    -- The event format has to carry a tick, or a headless machine cannot run a
    -- schedule at all.
    local ev = desktop.parse_events("tick\ntick 0.5\nmouse_click 1 3 3\n")
    check("the headless format parses a tick with and without a step",
          #ev == 3 and ev[1][1] == "tick" and ev[1][2] == nil and ev[2][2] == 0.5,
          tostring(#ev))
    local s3, d3 = desktop.run({ screen = screen.buffer(51, 19), clock = "12:34",
                                 events = ev })
    check("a headless run advances its clock from the tick events",
          math.abs(d3.now - 0.55) < 1e-9, tostring(d3.now))
    check("counts two ticks and one event",
          d3.stats.ticks == 2 and d3.stats.events == 1,
          tostring(d3.stats.ticks) .. "/" .. tostring(d3.stats.events))
    check("and does not mistake the tick for an unknown event",
          d3.stats.unknown == 0, tostring(d3.stats.unknown))
    check("the dump of that run carries the clock",
          desktop.dump(s3, d3):find("CLOCK now=0.550", 1, true) ~= nil)
end

-- ===========================================================================
section("the pump: a blocking program and the desktop at once")
-- ===========================================================================
do
    -- A program that reads a key by blocking cannot be run from a frame loop. The
    -- pump is what turns one into a task: os.pullEventRaw is answered from the
    -- desktop's own event stream, and everything else keeps being scheduled. The
    -- claim here is that the reader really got the events AND that the desktop
    -- still acted -- "it did not raise" would be satisfied by a program that never
    -- ran.
    local got = {}
    local d, s = newdesk()
    local real_raw = os.pullEventRaw
    d:register_app({ id = "reader", name = "Reader", icon = "R",
        draw = function(api) api.write(1, 1, "read " .. tostring(#got)) end,
        main = function(api, win)
            api.task.pump(function()
                for _ = 1, 3 do
                    local ev = { os.pullEventRaw() }
                    got[#got + 1] = tostring(ev[1]) .. ":" .. tostring(ev[2] or "")
                end
            end, { window = win })
        end })
    local w = d:open("reader")
    check("the app's task runs the blocking program inside the pump",
          d.stats.pumps == 1 and d:pump_active(), tostring(d.stats.pumps))
    check("and the task waits in the pump state, which no clock resumes",
          w.tasks[1].waiting == "pump", tostring(w.tasks[1].waiting))
    check("nothing was read before an event arrived", #got == 0, tostring(#got))

    local resumes_before = d.stats.resumes
    d:handle({ "tick" })
    check("a tick does not satisfy a read", #got == 0, tostring(#got))
    check("and does not even resume the task that is reading",
          d.stats.resumes == resumes_before,
          tostring(d.stats.resumes) .. "/" .. tostring(resumes_before))
    d:handle({ "key", 30 })
    check("a key reaches the blocking reader", got[1] == "key:30", tostring(got[1]))
    check("and the desktop's own key handling never saw it", d.stats.keys == 0,
          tostring(d.stats.keys))
    check("the reader is waiting again", d:pump_active(), "not pumping")
    d:handle({ "char", "a" })
    check("a char follows it", got[2] == "char:a", tostring(got[2]))

    -- A click belongs to the desktop: the operator has to be able to reach another
    -- window while a shell sits at a prompt.
    local before = #got
    click(d, 5, 1)
    check("a click is not eaten by a pumped reader", #got == before,
          table.concat(got, " "))
    check("so the desktop acted on it", d.overview == true, tostring(d.overview))
    d:handle({ "key", desktop.KEYS.f10 })
    check("and while the overview is up the desktop takes the keyboard back",
          d.overview == false and #got == before,
          tostring(d.overview) .. "/" .. tostring(#got))
    d:handle({ "key", 30 })
    check("the reader is fed again afterwards", got[3] == "key:30", tostring(got[3]))

    check("the program finished and the pump is gone", d:pump_active() == false,
          "still pumping")
    check("with no error counted", d.stats.pump_errors == 0, tostring(d.stats.pump_errors))
    check("and the real os.pullEventRaw is back", os.pullEventRaw == real_raw,
          tostring(os.pullEventRaw))
    check("the task that ran it is finished",
          w.tasks[1].status == "dead", tostring(w.tasks[1].status))

    local text = desktop.dump(s, d)
    check("the dump reports the pump registry and the wrapper it installed",
          text:find("PUMPS 0 active=0 wraps=1 peak=1", 1, true) ~= nil,
          "[" .. tostring(text:match("PUMPS [^\n]*")) .. "]")
    check("and counts what it handed over",
          text:find("pumped_events=3", 1, true) ~= nil,
          "[" .. tostring(text:match("PUMP [^\n]*")) .. "]")

    -- The console app runs the shell in a window through exactly this pump. The
    -- suite has no ROM window, which is the degradation the app has to report
    -- rather than pretend about: a blank window would hide the reason.
    local d3, s3 = newdesk()
    local wc = d3:open("console")
    check("the console app opens", wc ~= nil and #d3.windows == 1)
    check("and on a machine with no window API it says what is missing",
          s3.find(4, "this machine has no window API") == 6, "[" .. s3.row(4) .. "]")
    check("it did not start a shell it cannot show", d3.stats.pumps == 0,
          tostring(d3.stats.pumps))
end

-- ===========================================================================
section("the pump feeds the focused window, and the terminal comes back")
-- ===========================================================================
do
    local got, keys_b = {}, {}
    local real_pull = os.pullEvent
    local d, s = newdesk()
    d:register_app({ id = "ra", name = "RA", icon = "A", draw = function() end,
        main = function(api, win)
            api.task.pump(function()
                for _ = 1, 2 do
                    local ev = { os.pullEventRaw() }
                    got[#got + 1] = tostring(ev[2])
                end
            end, { window = win })
        end })
    d:register_app({ id = "rb", name = "RB", icon = "B", draw = function() end,
        event = function(api, win, ev)
            if ev[1] == "key" then keys_b[#keys_b + 1] = ev[2] end
        end })
    local wa = d:open("ra")
    d:open("rb")
    check("a pumped reader is not fed while another window has the focus",
          #got == 0, tostring(#got))
    d:handle({ "key", 44 })
    check("the focused window gets the key instead", keys_b[1] == 44, tostring(keys_b[1]))
    d:focus_window(wa)
    d:handle({ "key", 46 })
    check("and the reader is fed again once its own window is focused", got[1] == "46",
          tostring(got[1]))

    -- A SECOND PUMP IS NORMAL NOW, and it is what makes a console per window
    -- possible: the machine still has one read, and the wrapper installed by the
    -- first pump answers the second program's pulls as well (it finds its own
    -- state by the coroutine that is running). What used to be "refused rather than
    -- stacked" is therefore replaced by "accepted, and registered alongside the
    -- other one" -- an expectation the old single-slot design could not express.
    local seen_inside = "not asked"
    d:register_app({ id = "rc", name = "RC", icon = "C", draw = function() end,
        main = function(api, win)
            api.task.pump(function()
                seen_inside = #d.pumps .. "/" .. tostring(win ~= nil)
            end, { window = win })
        end })
    d:open("rc")
    check("a second program may pump at the same time as the first",
          seen_inside == "2/true", tostring(seen_inside))
    check("and its own entry is gone again when its program returned",
          #d.pumps == 1, tostring(#d.pumps))

    -- Finish the reader's program, so this section does not walk away from a
    -- running pump: the wrapper count is process wide, and a section that left one
    -- installed would make the next section's "installed once" assertions describe
    -- the wrong state.
    d:focus_window(wa)
    d:handle({ "key", 47 })
    check("the reader's program finished once it had both of its events",
          got[2] == "47", tostring(got[2]))
    check("and the section leaves no pump behind",
          #d.pumps == 0 and os.pullEvent == real_pull, tostring(#d.pumps))

    -- The terminal is a global, and a program that leaves it redirected would take
    -- the desktop's own screen with it. term.redirect is one target for the whole
    -- machine, so the desktop re-asserts its own at the top of every iteration of
    -- its session loop; the stub has no term.redirect, so the check installs one and
    -- puts it back.
    local real_term = term
    local marker = { name = "the desktop's terminal" }
    local other = { name = "somewhere else" }
    local seen = {}
    term = { current = function() return marker end,
             redirect = function(t) seen[#seen + 1] = t end }
    local ok_exp = pcall(function()
        local d2 = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34" })
        check("the desktop remembers the terminal it started on",
              d2.term_target == marker, tostring(d2.term_target and d2.term_target.name))
        check("taking it back redirects to that target",
              d2:reclaim_terminal() == true and seen[#seen] == marker,
              tostring(seen[#seen] and seen[#seen].name))
        local count = #seen
        check("and taking it back twice is harmless",
              d2:reclaim_terminal() == true and #seen == count + 1, tostring(#seen))

        d2:register_app({ id = "poison", name = "Poison", icon = "P", draw = function() end,
            main = function(api, win)
                api.task.pump(function() term.redirect(other) end, { window = win })
            end })
        d2:open("poison")
        check("a program that leaves the terminal redirected does not keep it",
              seen[#seen] == marker, tostring(seen[#seen] and seen[#seen].name))

        term.redirect = function() error("this terminal is broken") end
        check("a terminal whose redirect raises is reported, not raised",
              d2:reclaim_terminal() == false, "it answered true")
    end)
    term = real_term
    check("the experiment put the global term back", term == real_term)
    check("and it did not raise", ok_exp, "the terminal checks raised")
end

-- ===========================================================================
section("many pumped programs: a Console per window, one event to one pump")
-- ===========================================================================
do
    -- THE ROM WINDOW API, INSTALLED FOR THIS SECTION ONLY. The Console refuses to
    -- run a shell it cannot show, so "two consoles, two shells" can only be checked
    -- with a window API present; the fake below is the smallest thing the app uses
    -- (create under a parent, getSize, getLine). term is faked for the same reason:
    -- the pump re-asserts a terminal target before every slice, and what has to be
    -- asserted is WHICH target, and that one console's target is not the other's.
    local real_window, real_term = window, term
    local ROOT = { name = "the desktop's terminal" }
    local made, term_seen = {}, {}
    -- term.current() answers the surface term.redirect last selected, as the
    -- machine's does: that is what made "the second console is built inside the
    -- first" possible, so the fake has to model it or the assertion is empty.
    local term_now = ROOT
    window = { create = function(parent, x, y, w, h, visible)
        local wobj = { name = "rom-window-" .. (#made + 1), parent = parent,
                       x = x, y = y, w = w, h = h, visible = visible }
        function wobj.getSize() return w, h end
        function wobj.getLine(row)
            return string.rep(" ", w), string.rep("0", w), string.rep("f", w)
        end
        made[#made + 1] = wobj
        return wobj
    end }
    term = { current = function() return term_now end,
             redirect = function(t)
                 term_seen[#term_seen + 1] = t
                 term_now = t
             end }

    -- One runner per console, in creation order: the console opened first gets the
    -- first plan, and logs[1] are the events console 1's shell was fed. A shell
    -- that finishes its plan RETURNS, which is how "one pump ends, the other keeps
    -- running" is driven without a clock.
    local logs, runs = {}, 0
    local plan = { 2, 3, 9, 9, 9 }
    local function runner(path)
        runs = runs + 1
        local got = {}
        logs[runs] = got
        for _ = 1, (plan[runs] or 1) do
            local ev = { os.pullEventRaw() }
            got[#got + 1] = tostring(ev[1]) .. ":" .. tostring(ev[2])
        end
        return "the shell left"
    end

    local real_pull, real_raw = os.pullEvent, os.pullEventRaw
    local ok_exp = pcall(function()
        local d = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34",
                                run_shell = runner })
        local c1 = d:open("console")
        local c2 = d:open("console")
        check("two Console windows are being pumped at the same time",
              #d.pumps == 2 and d.pumps[1].window == c1 and d.pumps[2].window == c2,
              tostring(#d.pumps))
        check("and the registry keeps them in registration order",
              d.pumps[1].number == 1 and d.pumps[2].number == 2,
              tostring(d.pumps[1].number) .. "/" .. tostring(d.pumps[2].number))
        check("each console asked for a ROM window of its own",
              type(c1.state) == "table" and type(c2.state) == "table" and
              c1.state.win ~= nil and c2.state.win ~= nil and
              c1.state.win ~= c2.state.win, "the same ROM window twice")
        check("both are built under the desktop's terminal, not inside each other",
              made[1] ~= nil and made[2] ~= nil and made[1].parent == ROOT and
              made[2].parent == ROOT,
              "second parent=" .. tostring(made[2] and made[2].parent and made[2].parent.name))
        check("so the second console is not nested inside the first",
              made[2] ~= nil and made[2].parent ~= made[1], "it is nested")
        check("the copies are titled Console and Console 2",
              c1.title == "Console" and c2.title == "Console 2",
              tostring(c1.title) .. "/" .. tostring(c2.title))
        check("the wrapper was installed once for both pumps",
              d.stats.pump_wraps == 1 and d.stats.pumps == 2,
              tostring(d.stats.pump_wraps) .. "/" .. tostring(d.stats.pumps))
        check("and the stats saw two pumps at once", d.stats.pumps_peak == 2,
              tostring(d.stats.pumps_peak))
        check("both programs are waiting for an event",
              d:pump_active() == true and d.pumps[1].waiting == true and
              d.pumps[2].waiting == true, "not all waiting")
        check("os.pullEvent is the pump wrapper while they run",
              os.pullEvent ~= real_pull, "the wrapper is not installed")

        -- RULE 1: the keyboard belongs to the focused window, and only to it.
        d:focus_window(c1)
        d:handle({ "key", 30 })
        check("a key goes to the focused console", logs[1] and logs[1][1] == "key:30",
              tostring(logs[1] and logs[1][1]))
        check("and its own window was re-asserted before the shell saw the key",
              term_seen[#term_seen] == c1.state.win,
              tostring(term_seen[#term_seen] and term_seen[#term_seen].name))
        check("and not to the console behind it",
              logs[2] ~= nil and #logs[2] == 0, tostring(logs[2] and #logs[2]))
        d:focus_window(c2)
        d:handle({ "key", 31 })
        check("the other console gets the key once it has the focus",
              logs[2] and logs[2][1] == "key:31", tostring(logs[2] and logs[2][1]))
        check("and the first one was not fed again", logs[1] and #logs[1] == 1,
              tostring(logs[1] and #logs[1]))

        -- RULE 2: when the focused window has no pump, a NON-keyboard event goes to
        -- the oldest pump still waiting. c1's shell is waiting for its second event
        -- and gets it -- which finishes that program, and is also the check that
        -- one pump ending leaves the other alone.
        local files = d:open("files")
        check("a window with no pump can take the focus", d.focus == files,
              tostring(d.focus and d.focus.id))
        -- With the focus on a window that has no pump, a key goes to NOBODY: the
        -- keyboard is the focused window's, not the oldest pump's. This is the
        -- assertion a "background shell gets the keys" regression trips over.
        d:handle({ "key", 33 })
        check("a key is not given to a background pump",
              #logs[1] == 1 and #logs[2] == 1,
              tostring(#logs[1]) .. "/" .. tostring(#logs[2]))
        d:handle({ "timer", 7 })
        check("a non-key event reaches the oldest pump when the focus has none",
              logs[1] and logs[1][2] == "timer:7", tostring(logs[1] and logs[1][2]))
        check("the console that is not first did not see it", #logs[2] == 1,
              tostring(#logs[2]))
        check("the program that finished left the registry",
              #d.pumps == 1 and d.pumps[1].window == c2, tostring(#d.pumps))
        check("and the terminal was handed to the program still running",
              term_seen[#term_seen] == c2.state.win,
              tostring(term_seen[#term_seen] and term_seen[#term_seen].name))
        check("the wrapper stays installed for the surviving pump",
              os.pullEvent ~= real_pull, "it was restored too early")
        check("and the surviving pump is still fed",
              (function()
                  d:focus_window(c2)
                  d:handle({ "key", 32 })
                  return logs[2] ~= nil and logs[2][2] == "key:32"
              end)(), tostring(logs[2] and logs[2][2]))

        d:handle({ "timer", 8 })
        check("the last program ended and the registry is empty", #d.pumps == 0,
              tostring(#d.pumps))
        check("the machine's own os.pullEvent and os.pullEventRaw came back",
              os.pullEvent == real_pull and os.pullEventRaw == real_raw,
              "the wrapper is still installed")
        check("and the wrapper was never installed a second time",
              d.stats.pump_wraps == 1, tostring(d.stats.pump_wraps))
        check("the desktop took its own terminal back",
              term_seen[#term_seen] == ROOT,
              tostring(term_seen[#term_seen] and term_seen[#term_seen].name))
        check("all five events were handed to exactly one program each",
              d.stats.pumped_events == 5, tostring(d.stats.pumped_events))

        -- THREE consoles: the titles are numbered by creation and the registry is a
        -- list, so closing the middle one drops only that pump and renumbers the
        -- survivors.
        local d3 = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34",
            run_shell = function()
                while true do
                    local ev = { os.pullEventRaw() }
                end
            end })
        local t1 = d3:open("console")
        local t2 = d3:open("console")
        local t3 = d3:open("console")
        check("three consoles are three pumps",
              #d3.pumps == 3 and d3.stats.pumps_peak == 3, tostring(#d3.pumps))
        check("and they are numbered Console, Console 2, Console 3",
              t1.title == "Console" and t2.title == "Console 2" and
              t3.title == "Console 3",
              tostring(t1.title) .. "/" .. tostring(t2.title) .. "/" .. tostring(t3.title))
        check("each of the three has its own ROM window",
              t1.state.win ~= t2.state.win and t2.state.win ~= t3.state.win and
              t1.state.win ~= t3.state.win, "a window was shared")
        d3:close_window(t2)
        check("closing the middle console drops only its pump",
              #d3.pumps == 2 and d3.pumps[1].window == t1 and d3.pumps[2].window == t3,
              tostring(#d3.pumps))
        check("and the survivors are renumbered",
              t1.title == "Console" and t3.title == "Console 2",
              tostring(t1.title) .. "/" .. tostring(t3.title))
        d3:close_window(t1)
        d3:close_window(t3)
        check("closing every console leaves no pump and the machine's own read",
              #d3.pumps == 0 and os.pullEvent == real_pull and
              os.pullEventRaw == real_raw, tostring(#d3.pumps))
    end)
    window = real_window
    term = real_term
    check("the experiment put the window API and the terminal back",
          window == real_window and term == real_term)
    check("and it did not raise", ok_exp, "the multi-pump checks raised")
end

-- ===========================================================================
section("the Terminal runs the shell in its window, next to the Console")
-- ===========================================================================
do
    -- THE ROM WINDOW API AGAIN, INSTALLED FOR THIS SECTION ONLY: since 1.6.0 the
    -- Terminal is the same windowed shell as the Console, so it too refuses to run
    -- a shell it cannot show, and "the Terminal starts a shell in its window" can
    -- only be checked with a window API present. The fake is the smallest thing the
    -- shared implementation uses (create under a parent, getSize, getLine). term is
    -- faked for the same reason as in the two-console section: the pump re-asserts a
    -- terminal target before every slice, and what has to be asserted is WHICH one.
    local real_window, real_term = window, term
    local ROOT = { name = "the desktop's terminal" }
    local made, term_seen = {}, {}
    local term_now = ROOT
    window = { create = function(parent, x, y, w, h, visible)
        local wobj = { name = "rom-window-" .. (#made + 1), parent = parent,
                       x = x, y = y, w = w, h = h, visible = visible }
        function wobj.getSize() return w, h end
        function wobj.getLine(row)
            return string.rep(" ", w), string.rep("0", w), string.rep("f", w)
        end
        made[#made + 1] = wobj
        return wobj
    end }
    term = { current = function() return term_now end,
             redirect = function(t) term_seen[#term_seen + 1] = t term_now = t end }

    -- One runner call per shell instance. Each reads until it is given ENTER and
    -- then returns, which is how "the shell left" is driven and is also what the
    -- real ush does when it is allowed to leave; logs[i] is what shell i was fed.
    local logs, runs = {}, 0
    local function runner(path)
        runs = runs + 1
        local got = {}
        logs[runs] = got
        while true do
            local ev = { os.pullEventRaw() }
            got[#got + 1] = tostring(ev[1]) .. ":" .. tostring(ev[2])
            if ev[1] == "key" and ev[2] == 28 then break end
        end
        return "the shell left"
    end

    local real_pull, real_raw = os.pullEvent, os.pullEventRaw
    local ok_exp = pcall(function()
        local s = screen.buffer(51, 19)
        local d = desktop.new({ screen = s, clock = "12:34", run_shell = runner })
        local tentry = apps.by_id(d.entries, "terminal")
        local t = d:open("terminal")
        check("opening the Terminal starts a shell pumped inside its own window",
              #d.pumps == 1 and d.pumps[1].window == t, tostring(#d.pumps))
        check("the Terminal asked for a ROM window of its own",
              type(t.state) == "table" and t.state.win ~= nil,
              tostring(t.state and t.state.win))
        check("and it was built under the desktop's terminal, not under term.current()",
              made[1] ~= nil and made[1].parent == ROOT,
              tostring(made[1] and made[1].parent and made[1].parent.name))
        check("the pump was told that window is the shell's terminal",
              d.pumps[1].term == t.state.win, "the pump has no terminal target")
        check("the Terminal kept the name and the icon the overview shows",
              t.title == "Terminal" and tentry ~= nil and tentry.icon == ">_",
              tostring(t.title) .. "/" .. tostring(tentry and tentry.icon))

        -- TWO SHELLS, TWO WINDOWS: the Console opens next to it and is pumped too.
        local c = d:open("console")
        check("a Console opens next to the Terminal as a second pumped shell",
              #d.pumps == 2 and d.pumps[2].window == c and
              c.state.win ~= t.state.win, tostring(#d.pumps))
        d:focus_window(t)
        d:handle({ "char", "e" })
        check("a character typed into the focused Terminal goes to its own shell",
              logs[1] ~= nil and logs[1][#logs[1]] == "char:e",
              tostring(logs[1] and logs[1][#logs[1]]))
        check("and the Console's shell never sees it",
              logs[2] ~= nil and #logs[2] == 0, tostring(logs[2] and #logs[2]))
        d:focus_window(c)
        d:handle({ "char", "s" })
        check("typing into the Console goes to the Console's own shell",
              logs[2] ~= nil and logs[2][1] == "char:s",
              tostring(logs[2] and logs[2][1]))
        check("and not back into the Terminal",
              logs[1] ~= nil and #logs[1] == 1, tostring(logs[1] and #logs[1]))
        -- The shell's editing keys belong to the shell. A backspace has to reach
        -- the windowed program as a key event and must not be taken by the
        -- desktop's own keyboard handling: an editor that never saw it would make
        -- the window a display rather than a terminal.
        d:focus_window(t)
        d:handle({ "key", 14 })
        check("a backspace reaches the focused shell and is not kept by the desktop",
              logs[1] ~= nil and logs[1][#logs[1]] == "key:14" and d.stats.keys == 0,
              tostring(logs[1] and logs[1][#logs[1]]) .. "/keys=" .. tostring(d.stats.keys))

        -- ENTER ends the Terminal's shell: the window has to SAY the shell left
        -- (there is no desktop handover left to come back from).
        d:focus_window(t)
        d:handle({ "key", 28 })
        check("ENTER in the Terminal's shell makes that shell leave",
              t.state.exited == true, tostring(t.state and t.state.exited))
        check("and the window says so on its last row",
              s.find(13, "the shell left") == 6, "[" .. s.row(13) .. "]")
        check("the Console's shell is still being pumped",
              #d.pumps == 1 and d.pumps[1].window == c, tostring(#d.pumps))
        check("and no screen handover happened anywhere in this",
              d.stats.handovers == 0, tostring(d.stats.handovers))
        d:focus_window(c)
        d:handle({ "key", 28 })
        check("the last shell leaves too, and the machine's own read comes back",
              #d.pumps == 0 and os.pullEvent == real_pull, tostring(#d.pumps))

        -- THE TWO NAMES ARE ONE IMPLEMENTATION: whichever module the wrapper is,
        -- the thing that differs between the Terminal and the Console is the name
        -- and the banner it hands to the shared shell, so those are what this
        -- pins. (That both call one module is a fact of the files -- one shared
        -- implementation, two thin wrappers -- and not something a behavioural
        -- assertion can see.)
        local termmod = require("gnome.apps.terminal")
        local conmod = require("gnome.apps.console")
        local shared = require("gnome.apps.shellwin")
        check("the two wrappers differ only in the title and banner they pass",
              type(termmod.OPTS) == "table" and type(conmod.OPTS) == "table" and
              termmod.OPTS.title == "Terminal" and conmod.OPTS.title == "Console" and
              termmod.OPTS.banner ~= conmod.OPTS.banner and
              type(shared.main) == "function" and type(shared.draw) == "function",
              tostring(termmod.OPTS and termmod.OPTS.banner) .. "/" ..
              tostring(conmod.OPTS and conmod.OPTS.banner))
    end)
    window = real_window
    term = real_term
    check("the experiment put the window API and the terminal back",
          window == real_window and term == real_term)
    check("and it did not raise", ok_exp, "the windowed-shell checks raised")
end

-- ===========================================================================
section("fmt: the package's one kilobyte ladder")
-- ===========================================================================
do
    -- KNOWN ANSWERS, not "it returned a string": the boundaries are where a unit
    -- ladder is right or wrong, and every one of these numbers is a value an
    -- operator can check by hand. Base 1024, no decimal on a byte, one decimal on
    -- every larger unit.
    check("zero bytes is zero bytes", fmt.bytes(0) == "0 B", fmt.bytes(0))
    check("one byte is a whole byte", fmt.bytes(1) == "1 B", fmt.bytes(1))
    check("1023 bytes is still bytes", fmt.bytes(1023) == "1023 B", fmt.bytes(1023))
    check("1024 bytes is one kilobyte", fmt.bytes(1024) == "1.0 KB", fmt.bytes(1024))
    check("1025 bytes still reads as one kilobyte", fmt.bytes(1025) == "1.0 KB",
          fmt.bytes(1025))
    check("one byte under a megabyte is promoted, not printed as 1024.0 KB",
          fmt.bytes(1024 * 1024 - 1) == "1.0 MB", fmt.bytes(1024 * 1024 - 1))
    check("a megabyte is one megabyte", fmt.bytes(1024 * 1024) == "1.0 MB",
          fmt.bytes(1024 * 1024))
    check("five megabytes is five of them", fmt.bytes(5 * 1024 * 1024) == "5.0 MB",
          fmt.bytes(5 * 1024 * 1024))
    check("a gigabyte is the top of the ladder",
          fmt.bytes(1024 * 1024 * 1024) == "1.0 GB", fmt.bytes(1024 * 1024 * 1024))
    check("a missing or impossible count is a question mark, not a zero",
          fmt.bytes(nil) == "?" and fmt.bytes("nope") == "?" and fmt.bytes(-1) == "?",
          fmt.bytes(nil) .. "/" .. fmt.bytes("nope") .. "/" .. fmt.bytes(-1))

    -- "A byte carries no decimal" said as its own claim: every value under a
    -- kilobyte is checked, so a change of the B form to "%.1f B" cannot pass on
    -- one lucky number.
    local dotted = {}
    for _, n in ipairs({ 0, 1, 7, 512, 999, 1023 }) do
        if fmt.bytes(n):find(".", 1, true) then dotted[#dotted + 1] = n end
    end
    check("no byte count under a kilobyte carries a decimal point", #dotted == 0,
          table.concat(dotted, ","))
    check("and every larger unit carries exactly one",
          fmt.bytes(1024):find("^%d+%.%d KB$") ~= nil and
          fmt.bytes(2048) == "2.0 KB" and fmt.bytes(3 * 1024 * 1024) == "3.0 MB",
          fmt.bytes(1024) .. "/" .. fmt.bytes(2048) .. "/" .. fmt.bytes(3 * 1024 * 1024))

    -- Percentages: one decimal and the sign, clamped, and honest about nothing.
    check("a percentage is one decimal with its sign", fmt.percent(1, 4) == "25.0%",
          fmt.percent(1, 4))
    check("half of the stub machine's disk is 50.0%",
          fmt.percent(2 * 1024 * 1024, 4 * 1024 * 1024) == "50.0%",
          fmt.percent(2 * 1024 * 1024, 4 * 1024 * 1024))
    check("more used than there is is clamped to 100.0%",
          fmt.percent(5, 4) == "100.0%", fmt.percent(5, 4))
    check("nothing to divide by is a question mark",
          fmt.percent(1, 0) == "?" and fmt.percent(nil, 4) == "?",
          fmt.percent(1, 0) .. "/" .. fmt.percent(nil, 4))

    -- The two truncation helpers, which are what keeps a value inside its column.
    check("a value that fits is returned untouched",
          fmt.fit("abc", 4) == "abc" and fmt.fit_left("abc", 4) == "abc",
          fmt.fit("abc", 4) .. "/" .. fmt.fit_left("abc", 4))
    check("an overlong tail is cut and the cut is marked at the end",
          fmt.fit("abcdef", 4) == "abc>", fmt.fit("abcdef", 4))
    check("an overlong head is cut and the cut is marked at the front",
          fmt.fit_left("abcdef", 4) == ">def", fmt.fit_left("abcdef", 4))
    check("padding widens a value and never cuts it",
          fmt.pad("ab", 4) == "ab  " and fmt.pad("abcdef", 4) == "abcdef",
          "[" .. fmt.pad("ab", 4) .. "]/" .. fmt.pad("abcdef", 4))

    -- THE FILE BROWSER USES IT TOO: a 1024 byte file is "1.0 KB" on the screen,
    -- not "1024B", and the same ladder is what the settings panel shows.
    _G.FS["/kilo.bin"] = { content = ("x"):rep(1024) }
    local dfs, sfs = newdesk()
    dfs:draw()
    local fwin = dfs:open("files")
    local fbody = desktop.body_rect(fwin)
    local at = nil
    for i, row in ipairs(filesapp.rows(fwin)) do
        if row.entry and row.entry.name == "kilo.bin" then at = i end
    end
    check("the file browser lists the seeded kilobyte file", at ~= nil, tostring(at))
    local line = at and sfs.row(fbody.y + at) or ""
    check("its size column says 1.0 KB", line:find("kilo.bin  1.0 KB", 1, true) ~= nil,
          "[" .. line .. "]")
    check("and not the raw byte count", line:find("1024", 1, true) == nil,
          "[" .. line .. "]")
    _G.FS["/kilo.bin"] = nil
end

-- ===========================================================================
section("a desktop cannot start inside a window of another desktop")
-- ===========================================================================
do
    -- Since 1.6.0 the Terminal and the Console run the shell in a window, so
    -- `desktop` typed there would start a desktop inside a window of the outer one.
    -- The decision is gnome.desktop's, so it is asserted here without running the
    -- command. The fact it asks is getLine, measured on CraftOS-PC 2.8.3: the
    -- machine's own terminal has none (term.getLine is nil, and so is the field on
    -- term.native() and on term.current() when that is the screen), while every
    -- window.create window has it. Identity would have been wrong: measured too,
    -- term.current() is NOT term.native() even on the machine's own screen, which
    -- is why the first version of this guard refused the desktop everywhere.
    local wint = { getLine = function() return "", "", "" end }
    local native = { blit = function() end }
    check("a terminal that answers getLine is a window, and is refused",
          desktop.needs_whole_screen(wint) == true)
    check("the machine's own screen (no getLine) is not refused",
          desktop.needs_whole_screen(native) == false)
    check("a machine that cannot answer is allowed rather than guessed at",
          desktop.needs_whole_screen(nil) == false and
          desktop.needs_whole_screen(native) == false)

    local HOST = _G.read_host_file
    local bin = HOST and HOST(PROJ .. "/tools/pkgs/gnome/bin/desktop.lua")
    if type(bin) ~= "string" then
        skip("the windowed refusal", "read_host_file cannot read the package tree")
    else
        check("the command asks whether its terminal is a window",
              bin:find("desktop.needs_whole_screen(", 1, true) ~= nil,
              "the command never asks")
        check("and refuses with the reason and status 1",
              bin:find("cannot start inside a window", 1, true) ~= nil and
              bin:find("return 1", 1, true) ~= nil,
              "no refusal in the command")
        check("the refusal comes before the desktop is run",
              (function()
                  local guard = bin:find("desktop.needs_whole_screen(", 1, true)
                  local run = bin:find("desktop.run_interactive(", 1, true)
                  return guard ~= nil and run ~= nil and guard < run
              end)(), "the guard is after the run, so it guards nothing")
    end
end
-- ===========================================================================
section("the text editor: a buffer that edits, saves, and Files opens it")
-- ===========================================================================
do
    _G.FS["/note.txt"] = { content = "hello\nworld\n" }
    local d, s = newdesk()
    d:draw()
    local win = d:open("editor", { path = "/note.txt" })
    local body = desktop.body_rect(win)
    local st = editorapp.buffer(win)
    check("the editor window carries the file it was opened on",
          win.state.path == "/note.txt", tostring(win.state.path))
    check("and names it in its header row",
          s.find(body.y, "/note.txt") == body.x, "[" .. s.row(body.y) .. "]")
    check("the file's lines are drawn from the body's first row",
          (s.row(body.y + 1) or ""):find("hello", 1, true) ~= nil and
          (s.row(body.y + 2) or ""):find("world", 1, true) ~= nil)
    -- Typing at 1,1 inserts BEFORE the first character.
    d:handle({ "char", "X" })
    check("a char inserts at the cursor",
          editorapp.text(st) == "Xhello\nworld\n" and s.row(body.y + 1):find("Xhello", 1, true) ~= nil,
          "[" .. s.row(body.y + 1) .. "]")
    d:handle({ "key", 28 })                     -- enter splits after X
    check("enter splits the line and the buffer grows",
          editorapp.text(st) == "X\nhello\nworld\n", "[" .. editorapp.text(st):gsub("\n", "|") .. "]")
    d:handle({ "key", 14 })                     -- backspace joins again
    check("backspace joins the line back",
          editorapp.text(st) == "Xhello\nworld\n", "[" .. editorapp.text(st):gsub("\n", "|") .. "]")
    d:handle({ "key", 208 })                    -- down
    check("down moves to the next line", st.row == 2, tostring(st.row))
    d:handle({ "key", 207 })                    -- end
    check("end puts the cursor after the last character", st.col == 6, tostring(st.col))
    d:handle({ "char", "!" })
    check("typing marks the buffer dirty and the header says so",
          st.dirty == true and (s.row(body.y) or ""):find("*", 1, true) ~= nil,
          "[" .. s.row(body.y) .. "]")
    -- Ctrl+S: the stub has no keys API, so a Ctrl that is held is simulated.
    local saved_keys = _G.keys
    _G.keys = { isCtrlDown = function() return true end }
    d:handle({ "key", 31 })                     -- ctrl+s
    _G.keys = saved_keys
    check("ctrl+s writes the buffer back to the file",
          _G.FS["/note.txt"].content == "Xhello\nworld!\n",
          "[" .. tostring(_G.FS["/note.txt"].content):gsub("\n", "|") .. "]")
    check("and the buffer is no longer dirty", st.dirty == false)
    check("the status line says what was saved",
          (s.row(body.y + body.h - 1) or ""):find("saved /note.txt", 1, true) ~= nil,
          "[" .. s.row(body.y + body.h - 1) .. "]")

    -- THE SEAM WITH FILES: Enter on a listed file opens the editor on that path.
    local fd, fs_ = newdesk()
    fd:draw()
    local fwin = fd:open("files")
    local at = nil
    for i, row in ipairs(filesapp.rows(fwin)) do
        if row.entry and row.entry.name == "note.txt" then at = i end
    end
    check("Files lists the file the editor saved", at ~= nil, tostring(at))
    fwin.state.select = at
    fd:handle({ "key", 28 })                    -- enter
    local opened = nil
    for _, w in ipairs(fd.windows) do
        if w.id == "editor" then opened = w end
    end
    check("enter on a file opens the editor on that path",
          opened ~= nil and opened.state.path == "/note.txt",
          tostring(opened and opened.state.path))
    check("and the editor shows the file's own text",
          opened ~= nil and (fs_.row(desktop.body_rect(opened).y + 1) or ""):find("Xhello", 1, true) ~= nil,
          opened and "[" .. fs_.row(desktop.body_rect(opened).y + 1) .. "]" or "no window")

    -- A window opened without a path is honest: it edits, and it says there is
    -- nothing to save to instead of inventing a name.
    local bare = d:open("editor")
    d:handle({ "key", 113 })                    -- F2 with no path
    check("saving a window with no file says so instead of guessing",
          (editorapp.buffer(bare).message or ""):find("no file name", 1, true) ~= nil,
          tostring(editorapp.buffer(bare).message))
    _G.FS["/note.txt"] = nil
end

-- ===========================================================================
section("the text editor: a save that cannot fit is refused, not truncated")
-- ===========================================================================
-- The save goes through the same preflight as every other writer (lib/space.lua).
-- The failure this pins is the one an open performs on its own: fs.open(path, "w")
-- succeeds and truncates BEFORE a byte is written, so a check after it would have
-- destroyed the old file in the act of refusing the new one.
do
    local original = "keep these bytes\n"
    _G.FS["/space_note.txt"] = { content = original }
    local d, s = newdesk()
    d:draw()
    local win = d:open("editor", { path = "/space_note.txt" })
    local st = editorapp.buffer(win)
    local body = desktop.body_rect(win)
    check("the editor reads the file it was opened on",
          editorapp.text(st) == original, "[" .. editorapp.text(st):gsub("\n", "|") .. "]")
    -- One keystroke, so there is an edit that a refused save must not lose.
    d:handle({ "char", "X" })
    local edited = "X" .. original

    -- The free space is injected; 4 bytes cannot hold the 18 the buffer needs.
    local real_free = _G.fs.getFreeSpace
    _G.fs.getFreeSpace = function() return 4 end
    local ok = editorapp.save(st)
    _G.fs.getFreeSpace = real_free

    check("the save reports failure", ok == false, tostring(ok))
    check("the status line says the disk is too small",
          (st.message or ""):find("not enough space", 1, true) ~= nil,
          tostring(st.message))
    check("and names the bytes needed and free",
          (st.message or ""):find("need 18 bytes, 4 free", 1, true) ~= nil,
          tostring(st.message))
    check("the file was NOT truncated by the refused save",
          _G.FS["/space_note.txt"].content == original,
          "[" .. tostring(_G.FS["/space_note.txt"].content):gsub("\n", "|") .. "]")
    check("the buffer is still dirty, so the edit is not lost",
          st.dirty == true, tostring(st.dirty))
    -- The window draws the refusal, so the operator sees it and not a silent no-op.
    d:draw()
    check("the window's status row shows the refusal",
          (s.row(body.y + body.h - 1) or ""):find("not enough space", 1, true) ~= nil,
          "[" .. (s.row(body.y + body.h - 1) or "") .. "]")

    -- The control: with room, the same save writes the file and clears dirty.
    local ok2 = editorapp.save(st)
    check("the same save succeeds when there is room", ok2 == true, tostring(ok2))
    check("and the bytes reached the file",
          _G.FS["/space_note.txt"].content == edited,
          "[" .. tostring(_G.FS["/space_note.txt"].content):gsub("\n", "|") .. "]")
    check("and the buffer is no longer dirty", st.dirty == false, tostring(st.dirty))
    _G.FS["/space_note.txt"] = nil
end

-- ===========================================================================
section("the text editor: soft wrap, undo and find")
-- ===========================================================================
do
    -- SOFT WRAP IS DERIVED, NOT INSERTED: a 100 character line in the default
    -- 38-column body is three display rows, and the buffer still has no newline.
    local long = string.rep("x", 100)
    _G.FS["/wrap.txt"] = { content = long .. "\n" }
    local d, s = newdesk()
    d:draw()
    local win = d:open("editor", { path = "/wrap.txt" })
    local st = editorapp.buffer(win)
    local body = desktop.body_rect(win)
    local layout = editorapp.layout(st, body.w)
    -- Three chunks for the line plus one for the empty line the trailing newline
    -- leaves behind: the layout is per logical line and the empty one still needs a
    -- display row (that is where the cursor goes when it is past the end).
    check("a 100 character line wraps into three display rows",
          #layout == 4 and layout[3].row == 1 and layout[4].row == 2,
          tostring(#layout))
    check("the wrapped rows are one logical line, offset by the width",
          layout[2].row == 1 and layout[3].row == 1 and
          layout[2].start == body.w + 1 and layout[3].start == 2 * body.w + 1,
          layout[2].start .. "/" .. layout[3].start)
    check("the second wrap is drawn on the next body row",
          (s.row(body.y + 2) or ""):sub(body.x, body.x + 2) == "xxx",
          "[" .. tostring(s.row(body.y + 2)) .. "]")
    d:handle({ "key", 207 })                    -- end of the logical line
    local di, dc = editorapp.cursor_display(st, body.w)
    check("the cursor at the end of the long line is on the last display row",
          di == 3 and dc == 100 - 2 * body.w + 1,
          tostring(di) .. "/" .. tostring(dc))
    d:handle({ "key", 208 })                    -- down one DISPLAY row
    check("down after a wrapped row goes to the next display row",
          st.row == 2 and st.col == 1, tostring(st.row) .. ":" .. tostring(st.col))

    -- UNDO: one step per edit, and F4 and Ctrl+Z are the same action.
    _G.FS["/undo.txt"] = { content = "abc\n" }
    local d2 = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34" })
    d2:draw()
    local w2 = d2:open("editor", { path = "/undo.txt" })
    local st2 = editorapp.buffer(w2)
    d2:handle({ "char", "X" })
    d2:handle({ "char", "Y" })
    check("typing changed the buffer", editorapp.text(st2) == "XYabc\n",
          "[" .. editorapp.text(st2):gsub("\n", "|") .. "]")
    d2:handle({ "key", 115 })                   -- F4
    check("F4 undoes the last edit", editorapp.text(st2) == "Xabc\n",
          "[" .. editorapp.text(st2):gsub("\n", "|") .. "]")
    d2:handle({ "key", 115 })
    check("and again", editorapp.text(st2) == "abc\n",
          "[" .. editorapp.text(st2):gsub("\n", "|") .. "]")
    d2:handle({ "key", 115 })
    check("undo with an empty stack says so and changes nothing",
          editorapp.text(st2) == "abc\n" and
          tostring(st2.message):find("nothing to undo", 1, true) ~= nil,
          tostring(st2.message))
    local savedk = _G.keys
    _G.keys = { isCtrlDown = function() return true end }
    d2:handle({ "char", "Q" })
    d2:handle({ "key", 44 })                    -- ctrl+z
    check("ctrl+z is the same undo", editorapp.text(st2) == "abc\n",
          "[" .. editorapp.text(st2):gsub("\n", "|") .. "]")

    -- FIND: Ctrl+F opens a prompt that does not touch the buffer; Enter finds the
    -- first occurrence, F3 the next, and the search wraps at the end.
    _G.FS["/find.txt"] = { content = "alpha beta\ngamma beta\n" }
    local d3 = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34" })
    d3:draw()
    local w3 = d3:open("editor", { path = "/find.txt" })
    local st3 = editorapp.buffer(w3)
    d3:handle({ "key", 33 })                    -- ctrl+f
    for _, ch in ipairs({ "b", "e", "t", "a" }) do d3:handle({ "char", ch }) end
    check("the find prompt takes the characters instead of the buffer",
          st3.find ~= nil and st3.find.mode == "input" and
          editorapp.text(st3) == "alpha beta\ngamma beta\n" and
          st3.find.query == "beta", tostring(st3.find and st3.find.query))
    d3:handle({ "key", 28 })                    -- enter
    check("enter finds the first occurrence and moves the cursor there",
          st3.row == 1 and st3.col == 7,
          tostring(st3.row) .. ":" .. tostring(st3.col))
    d3:handle({ "key", 114 })                   -- F3
    check("F3 finds the next occurrence", st3.row == 2 and st3.col == 7,
          tostring(st3.row) .. ":" .. tostring(st3.col))
    d3:handle({ "key", 114 })                   -- F3 wraps
    check("and wraps around at the end", st3.row == 1 and st3.col == 7,
          tostring(st3.row) .. ":" .. tostring(st3.col))
    -- F9 leaves the prompt. Escape used to be the way out, but it never reaches a
    -- computer in Minecraft, so the desktop cannot use it either and this app must
    -- not depend on it. An empty query with Enter still closes the prompt too.
    d3:handle({ "key", 67 })                    -- F9 closes an active find
    check("F9 leaves the find prompt", st3.find == nil,
          tostring(st3.find and st3.find.query))
    d3:handle({ "key", 114 })                   -- F3 reopens the prompt
    for _, ch in ipairs({ "g", "a", "m" }) do d3:handle({ "char", ch }) end
    d3:handle({ "key", 67 })
    check("F9 closes the input prompt without touching the buffer",
          st3.find == nil and editorapp.text(st3) == "alpha beta\ngamma beta\n",
          tostring(st3.find and st3.find.query))
    d3:handle({ "key", 114 })                   -- F3 opens an empty prompt
    d3:handle({ "key", 28 })                    -- enter on an empty query
    check("an empty query with Enter still closes the prompt",
          st3.find == nil, tostring(st3.find and st3.find.query))
    check("the editor's find key is F9 (67) and it has no Escape binding",
          editorapp.KEYS.f9 == 67 and editorapp.KEYS.escape == nil,
          tostring(editorapp.KEYS.f9) .. "/" .. tostring(editorapp.KEYS.escape))
    _G.keys = savedk
    _G.FS["/wrap.txt"] = nil
    _G.FS["/undo.txt"] = nil
    _G.FS["/find.txt"] = nil
end

-- ===========================================================================
section("Files: a listing longer than the window scrolls")
-- ===========================================================================
do
    for i = 1, 30 do
        _G.FS[string.format("/f%02d.txt", i)] = { content = "x" }
    end
    local d, s = newdesk()
    d:draw()
    local win = d:open("files")
    local body = desktop.body_rect(win)
    local rows = filesapp.rows(win)
    local total = #rows
    local view = body.h - 1
    check("the directory has more entries than the window shows",
          total > view, tostring(total) .. " entries, " .. tostring(view) .. " rows")
    for _ = 1, view + 2 do d:handle({ "key", 208 }) end
    local sel = filesapp.selection(win)
    local _, _, scroll = filesapp.visible(win, body.h)
    check("moving down past the window scrolls, and the selection stays on screen",
          sel == view + 3 and scroll > 0,
          tostring(sel) .. " selected, scroll=" .. tostring(scroll))
    local tag = tostring(sel) .. "/" .. tostring(total)
    check("the path line says where the selection is",
          s.find(body.y, tag) == body.x + body.w - #tag,
          "[" .. s.row(body.y) .. "]")
    local first_text = rows[scroll + 1].text:match("^(%S+)")
    check("the row drawn at the top of the listing is the scrolled one",
          (s.row(body.y + 1) or ""):find(first_text, 1, true) ~= nil,
          "[" .. s.row(body.y + 1) .. "]")
    d:handle({ "key", 207 })                    -- end
    local bottom = select(3, filesapp.visible(win, body.h))
    check("end selects the last entry and scrolls to the bottom",
          filesapp.selection(win) == total and bottom == total - view,
          tostring(filesapp.selection(win)) .. "/" .. tostring(bottom))
    d:handle({ "mouse_click", 1, body.x, body.y + 1 })
    check("a click on a scrolled row selects the entry drawn there",
          filesapp.selection(win) == bottom + 1,
          tostring(filesapp.selection(win)) .. " vs " .. tostring(bottom + 1))
    d:handle({ "key", 199 })                    -- home
    check("home goes back to the top and scrolls the listing back",
          filesapp.selection(win) == 1 and
          select(3, filesapp.visible(win, body.h)) == 0)
    for i = 1, 30 do _G.FS[string.format("/f%02d.txt", i)] = nil end
end

-- ===========================================================================
section("Files: one click selects, two clicks open")
-- ===========================================================================
do
    _G.FS["/dc-dir"] = { dir = true }
    _G.FS["/dc-dir/inside.txt"] = { content = "hello\n" }
    local d, s = newdesk()
    d:draw()
    local win = d:open("files")
    local body = desktop.body_rect(win)
    local rows = filesapp.rows(win)
    local at = nil
    for i, row in ipairs(rows) do
        if row.entry and row.entry.name == "dc-dir" then at = i end
    end
    check("the directory is listed", at ~= nil, tostring(at))
    d:handle({ "mouse_click", 1, body.x, body.y + at })
    check("one click selects the row without entering it",
          win.state.path == "/" and filesapp.selection(win) == at,
          tostring(win.state.path) .. " " .. tostring(filesapp.selection(win)))
    check("the selection is a readable band, not a block that hides the name",
          s.bg(body.x, body.y + at) == C.gray and
          s.fg(body.x, body.y + at) == C.white and
          (s.row(body.y + at) or ""):find("dc-dir", 1, true) ~= nil,
          tostring(s.bg(body.x, body.y + at)) .. "/" ..
          tostring(s.fg(body.x, body.y + at)) .. " [" .. s.row(body.y + at) .. "]")
    -- A different row in between resets the pair: the rule is CONSECUTIVE clicks
    -- on one row, not two clicks anywhere, so no timer window is involved.
    local other = (at % #rows) + 1
    if other == at then other = (other % #rows) + 1 end
    d:handle({ "mouse_click", 1, body.x, body.y + other })
    d:handle({ "mouse_click", 1, body.x, body.y + at })
    check("a click on another row in between starts the pair over",
          win.state.path == "/", tostring(win.state.path))
    -- Two consecutive clicks on the same row: open, with no clock involved.
    d:handle({ "mouse_click", 1, body.x, body.y + at })
    check("two consecutive clicks on a folder enter it",
          win.state.path == "/dc-dir" and filesapp.selection(win) == 1,
          tostring(win.state.path) .. " " .. tostring(filesapp.selection(win)))
    -- A slow double click (a second of desktop clock) is still one, which is what
    -- a slow machine produces; the window is 2s for that reason.
    local dslow = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34" })
    dslow:draw()
    local wslow = dslow:open("files")
    local body_slow = desktop.body_rect(wslow)
    local rows_slow = filesapp.rows(wslow)
    local at_slow = nil
    for i, row in ipairs(rows_slow) do
        if row.entry and row.entry.name == "dc-dir" then at_slow = i end
    end
    dslow:handle({ "mouse_click", 1, body_slow.x, body_slow.y + at_slow })
    dslow.now = dslow.now + 1
    dslow:handle({ "mouse_click", 1, body_slow.x, body_slow.y + at_slow })
    check("a slow second click still enters the folder (no clock is consulted)",
          wslow.state.path == "/dc-dir", tostring(wslow.state.path))

    -- Inside it, the rows are "<..>" then inside.txt: two clicks on the file open
    -- it in the editor (one click would only select, which is what the row being
    -- a selection block in the screenshot means).
    d.now = d.now + 2
    d:handle({ "mouse_click", 1, body.x, body.y + 2 })
    check("one click on a file selects it and does not open anything",
          win.state.path == "/dc-dir" and #d.windows == 1,
          tostring(#d.windows) .. " window(s)")
    d.now = d.now + 0.1
    d:handle({ "mouse_click", 1, body.x, body.y + 2 })
    local opened = nil
    for _, w in ipairs(d.windows) do
        if w.id == "editor" then opened = w end
    end
    check("two quick clicks on a file open the editor on it",
          opened ~= nil and opened.state.path == "/dc-dir/inside.txt",
          tostring(opened and opened.state.path))
    -- And the parent row opens too when double clicked.
    local d2 = desktop.new({ screen = screen.buffer(51, 19), clock = "12:34" })
    d2:draw()
    local w2 = d2:open("files")
    w2.state.path = "/dc-dir"
    d2:draw()
    d2:handle({ "mouse_click", 1, body.x, body.y + 1 })
    d2.now = d2.now + 0.1
    d2:handle({ "mouse_click", 1, body.x, body.y + 1 })
    check("two clicks on <..> go back to the parent directory",
          w2.state.path == "/", tostring(w2.state.path))
    _G.FS["/dc-dir/inside.txt"] = nil
    _G.FS["/dc-dir"] = nil
end

-- ===========================================================================
section("the settings panel: sections, a storage bar and the machine")
-- ===========================================================================
do
    -- The stub machine, stated once: host cc-5, user root, a 4 MB disk with 2 MB
    -- free, no packages installed, the clock at 12:34. The panel is asserted
    -- against those numbers cell by cell -- "a settings window opened" would be
    -- true of the old abstract list of strings as well.
    local d, s = newdesk()
    d:draw()
    local win = d:open("settings")
    local body = desktop.body_rect(win)
    check("the panel's interior is the default window's 38x10",
          body.w == 38 and body.h == 10, body.w .. "x" .. body.h)
    check("it has three section titles, each at the body's first column",
          s.find(4, "System") == 6 and s.find(7, "Storage") == 6 and
          s.find(11, "About") == 6,
          tostring(s.find(4, "System")) .. "/" .. tostring(s.find(7, "Storage")) ..
          "/" .. tostring(s.find(11, "About")))
    check("a key/value row puts the label in one column and the value in another",
          s.find(5, "hostname") == 8 and s.find(5, "cc-5") == 17, "[" .. s.row(5) .. "]")
    check("the session's user is the one the machine reports",
          s.find(5, "user") == 25 and s.find(5, "root") == 34, "[" .. s.row(5) .. "]")
    check("the screen size is the desktop's own", s.find(6, "screen") == 8 and
          s.find(6, "51x19") == 17, "[" .. s.row(6) .. "]")
    check("and the clock is the desktop's clock", s.find(6, "clock") == 25 and
          s.find(6, "12:34") == 34, "[" .. s.row(6) .. "]")

    -- THE STORAGE NUMBERS ARE THE CONVERTED UNITS. fs.getFreeSpace("/") in the
    -- stub is 2097152 and the capacity is 4194304; a panel that printed either
    -- number would be the old one.
    check("the disk's capacity is printed as megabytes",
          s.find(8, "total") == 8 and s.find(8, "4.0 MB") == 17, "[" .. s.row(8) .. "]")
    check("the free space is the unit fmt.bytes chose, not a byte count",
          s.find(8, "free") == 25 and s.find(8, "2.0 MB") == 34, "[" .. s.row(8) .. "]")
    check("and the raw byte counts appear nowhere in that row",
          s.find(8, "2097152") == nil and s.find(8, "4194304") == nil,
          "[" .. s.row(8) .. "]")
    check("the panel and fmt.bytes agree about this machine's disk",
          s.find(8, fmt.bytes(4194304)) == 17 and s.find(8, fmt.bytes(2097152)) == 34,
          fmt.bytes(4194304) .. "/" .. fmt.bytes(2097152))

    -- THE BAR. Its length is asserted FROM the printed percentage, which is the
    -- claim "the bar and the number agree" and not two independent guesses.
    local bar = s.row(9)
    local filled, empty, hash_at = 0, 0, nil
    for i = 1, #bar do
        local ch = bar:sub(i, i)
        if ch == "#" then
            filled = filled + 1
            if not hash_at then hash_at = i end
        elseif ch == "-" then empty = empty + 1 end
    end
    local percent = fmt.percent(2097152, 4194304)
    check("the storage bar starts at the body's first column", s.char(6, 9) == "[",
          tostring(s.char(6, 9)))
    check("and its percentage is right aligned to the body's last column",
          s.find(9, percent) == 39 and s.find(9, percent) + #percent - 1 == 43,
          tostring(s.find(9, percent)) .. " [" .. s.row(9) .. "]")
    local inner = 38 - (#percent + 1) - 2
    check("the bar's length is the percentage printed next to it",
          filled == math.floor(inner * 50.0 / 100 + 0.5),
          filled .. " of " .. inner .. " for " .. percent)
    check("and the rest of the bar is empty cells", filled + empty == inner,
          filled .. "+" .. empty .. "/" .. inner)
    check("the filled part is the bar's own colour, so the accent stays the desktop's",
          hash_at ~= nil and s.fg(hash_at, 9) == C.cyan and s.bg(5, 3) == C.orange,
          tostring(hash_at and s.fg(hash_at, 9)))
    check("an empty disk fills no cell of the bar", settingsapp.bar_fill(10, 0, 100) == 0,
          tostring(settingsapp.bar_fill(10, 0, 100)))
    check("a full disk fills every cell of the bar",
          settingsapp.bar_fill(10, 100, 100) == 10,
          tostring(settingsapp.bar_fill(10, 100, 100)))

    -- The package count and the version are the package manager's, not constants.
    check("the package count comes from the package manager",
          s.find(10, "packages") == 8 and s.find(10, "0 installed") == 17,
          "[" .. s.row(10) .. "]")
    _G.FS["/usr/pkgs"] = { dir = true }
    _G.FS["/usr/pkgs/demo"] = { dir = true }
    d:draw()
    check("and it follows what is installed",
          s.find(10, "1 installed") == 17, "[" .. s.row(10) .. "]")

    local host = _G.read_host_file
    local okh, manifest = pcall(function() return host(PROJ .. "/tools/pkgs/gnome/manifest") end)
    if not okh then manifest = nil end
    local version = (type(manifest) == "string" and manifest:match("version=(%S+)")) or "?"
    check("the About section prints the version the manifest carries",
          s.find(12, "gnome") == 8 and s.find(12, version) == 17,
          "[" .. s.row(12) .. "] version=" .. version)
    _G.FS["/usr/pkgs/gnome"] = { dir = true }
    _G.FS["/usr/pkgs/gnome/manifest"] = { content = "name=gnome\nversion=9.9.9\n" }
    d:draw()
    check("an installed manifest wins over the version in the source tree",
          s.find(12, "9.9.9") == 17, "[" .. s.row(12) .. "]")
    _G.FS["/usr/pkgs/gnome"] = nil
    _G.FS["/usr/pkgs/gnome/manifest"] = nil
    _G.FS["/usr/pkgs/demo"] = nil
    _G.FS["/usr/pkgs"] = nil
    d:draw()
    check("and with nothing installed it falls back to the source tree's version",
          s.find(12, version) == 17, "[" .. s.row(12) .. "]")

    -- The shell has no version module: its version is the banner line in its own
    -- source, read from the tail. Both answers are asserted, because "?" that
    -- never becomes a version is as wrong as a version that is invented.
    check("the shell's version is ? when its source is not on the machine",
          s.find(12, "?") == 34, "[" .. s.row(12) .. "]")
    _G.FS["/usr/ush.lua"] = { content = ("-- filler\n"):rep(40) ..
        'print("ush 1.0 - type \'help\' for commands")\n' }
    local du, su = newdesk()
    du:draw()
    local uwin = du:open("settings")
    local ubody = desktop.body_rect(uwin)
    check("and it is read off the shell's banner when the file is there",
          su.find(ubody.y + 8, "1.0") == 34, "[" .. su.row(ubody.y + 8) .. "]")
    _G.FS["/usr/ush.lua"] = nil

    -- The two actions are a row of their own, side by side, and both reach the
    -- desktop: the panel colour through the palette, log out through quit.
    check("the actions sit on the panel's last row, one in each column",
          s.find(13, "> panel: black") == 6 and s.find(13, "> log out") == 23,
          "[" .. s.row(13) .. "]")
    click(d, body.x, body.y + 9)
    check("the panel action turns the panel gray",
          d.panel_dark == false and s.find(13, "> panel: gray") == 6,
          "[" .. s.row(13) .. "]")
    click(d, body.x, body.y + 9)
    check("and again back to black", d.panel_dark == true and
          s.find(13, "> panel: black") == 6, "[" .. s.row(13) .. "]")

    -- A 12 column interior: one field per row, scrolled with the arrow keys, and
    -- not one cell dropped on the floor (app_api's clip is the safety net, not
    -- the plan -- the suite asserts the net caught nothing).
    local dn, sn = newdesk({ screen = screen.buffer(22, 16) })
    dn:draw()
    local nwin = dn:open("settings")
    local nb = desktop.body_rect(nwin)
    check("on a narrow screen the interior is 12 cells wide",
          nb.w == 12 and nb.h == 9, nb.w .. "x" .. nb.h)
    local function narrow(row) return sn.row(nb.y + row - 1):sub(nb.x, nb.x + nb.w - 1) end
    local before_clip = dn.stats.clipped
    dn:draw()
    check("a 12 column panel draws without one clipped cell",
          dn.stats.clipped == before_clip, tostring(dn.stats.clipped - before_clip))
    check("and it still shows its sections and its values",
          narrow(1) == "System      " and narrow(2) == "hostname: c>" and
          narrow(4) == "screen: 22x>" and narrow(5) == "clock: 12:34",
          "[" .. narrow(1) .. "]/[" .. narrow(2) .. "]/[" .. narrow(5) .. "]")
    check("the storage numbers are converted here too",
          narrow(7) == "total: 4.0 >" and narrow(8) == "free: 2.0 MB",
          "[" .. narrow(7) .. "]/[" .. narrow(8) .. "]")
    dn:handle({ "key", 208 })
    check("the down arrow scrolls the narrow panel by one field",
          narrow(1) == "hostname: c>", "[" .. narrow(1) .. "]")
    dn:handle({ "key", 209 })
    check("the page down key stops at the last page instead of scrolling past it",
          narrow(9) == "> log out   ", "[" .. narrow(9) .. "]")
    click(dn, nb.x, nb.y + 8)
    check("and the log out action can be reached and clicked after scrolling",
          dn.exit == true and dn.exit_reason == "logout", tostring(dn.exit_reason))

    -- Two settings windows do not share a scroll position: nothing of this app
    -- is module level.
    local dn2, sn2 = newdesk({ screen = screen.buffer(22, 16) })
    dn2:draw()
    local first = dn2:open("settings")
    dn2:handle({ "key", 208 })
    local second = dn2:open("settings")
    local nb2 = desktop.body_rect(second)
    check("a second settings window starts at the top, not where the first was scrolled to",
          first.state.scroll == 1 and second.state.scroll == 0 and
          sn2.row(nb2.y):sub(nb2.x, nb2.x + nb2.w - 1):find("System", 1, true) == 1,
          tostring(first.state.scroll) .. "/" .. tostring(second.state.scroll))
end

-- ===========================================================================
section("the calculator: a keypad that is drawn, clicked and typed on")
-- ===========================================================================
do
    local d, s = newdesk()
    d:draw()
    local win = d:open("calc")
    local body = desktop.body_rect(win)
    local lay = calcapp.layout(body.w, body.h)
    local function at(key)
        for _, b in ipairs(lay.buttons) do
            if b.key == key then return b end
        end
    end
    local function cells(key)
        local b = at(key)
        if not b then return nil end
        return body.x + b.col - 1, body.y + b.row - 1
    end
    check("the keypad is the 4x4 grid plus AC and a backspace",
          #lay.buttons == 18 and #calcapp.GRID == 4 and #calcapp.GRID[1] == 4 and
          #calcapp.GRID[4] == 4, tostring(#lay.buttons))
    check("the grid's first key is an 8x2 block at the body's first column",
          at("7").col == 1 and at("7").row == 3 and at("7").w == 8 and at("7").h == 2,
          tostring(at("7").col) .. "," .. tostring(at("7").row))
    check("the grid's last key still ends inside the body",
          at("+").col == 28 and at("+").col + at("+").w - 1 == 35,
          tostring(at("+").col))
    check("the four columns are one key apart",
          at("8").col - at("7").col == 9 and at("9").col - at("8").col == 9 and
          at("/").col - at("9").col == 9, tostring(at("8").col))
    check("AC and the backspace are on the row above the grid",
          at("AC").row == 2 and at("<").row == 2 and at("AC").h == 1,
          tostring(at("AC").row))

    -- KEYBOARD, with a known answer, and the one semantic choice this calculator
    -- makes: left to right. 2 + 3 * 4 is 20 here.
    for _, ch in ipairs({ "2", "+", "3", "*", "4" }) do d:handle({ "char", ch }) end
    d:handle({ "key", 28 })
    check("typed 2 + 3 * 4 = gives 20: the machine runs left to right",
          s.find(4, "20") == 42, "[" .. s.row(4) .. "]")
    check("and not 14, which is what operator precedence would give",
          s.find(4, "14") == nil, "[" .. s.row(4) .. "]")
    -- "=" after a PENDING OPERATOR has to leave a fresh start as well: a digit
    -- typed then is a new number, not a digit glued onto the answer.
    d:handle({ "char", "9" })
    check("a digit after an operator's = starts a new number too",
          s.find(4, "9") == 43 and s.find(4, "209") == nil, "[" .. s.row(4) .. "]")
    -- The expression line above the keys says what is pending.
    d:handle({ "char", "c" })
    for _, ch in ipairs({ "2", "0" }) do d:handle({ "char", ch }) end
    d:handle({ "char", "+" })
    check("a pending operator is shown above the keypad, right aligned",
          s.find(5, "20 +") == 40, "[" .. s.row(5) .. "]")
    d:handle({ "char", "c" })
    check("c is the keyboard's AC", s.find(4, "0") == 43 and s.find(5, "+") == nil,
          "[" .. s.row(4) .. "]")

    -- "=" then a digit starts a NEW number.
    for _, ch in ipairs({ "1", "2", "=", "9" }) do d:handle({ "char", ch }) end
    check("a digit after = starts a new number instead of appending to the answer",
          s.find(4, "9") == 43 and s.find(4, "129") == nil, "[" .. s.row(4) .. "]")

    -- Backspace edits the number being typed.
    d:handle({ "char", "c" })
    for _, ch in ipairs({ "1", "2", "3" }) do d:handle({ "char", ch }) end
    check("the digits typed are shown right aligned as typed",
          s.find(4, "123") == 41, "[" .. s.row(4) .. "]")
    d:handle({ "key", 14 })
    check("backspace takes one digit off the end",
          s.find(4, "12") == 42 and s.find(4, "123") == nil, "[" .. s.row(4) .. "]")

    -- Divide by zero: the text, the colour, and that it is recoverable.
    d:handle({ "char", "c" })
    for _, ch in ipairs({ "5", "/", "0" }) do d:handle({ "char", ch }) end
    d:handle({ "key", 28 })
    check("dividing by zero says so on the display",
          s.find(4, "error: divide by zero") == 23, "[" .. s.row(4) .. "]")
    check("and it is the error colour, not the answer colour", s.fg(43, 4) == C.red,
          tostring(s.fg(43, 4)))
    d:handle({ "char", "7" })
    check("a digit after the error starts a new number, so the calculator keeps going",
          s.find(4, "7") == 43 and s.find(4, "error") == nil, "[" .. s.row(4) .. "]")
    check("the calculator does not eat the keys that are not its own",
          calcapp.event(d:app_api(win), win, { "key", 30 }) == false and
          calcapp.event(d:app_api(win), win, { "key", 200 }) == false)

    -- THE MOUSE: a click executes the key it lands on, and the highlight is
    -- asserted in colours -- a hover that is drawn nowhere is not a hover.
    local x7, y7 = cells("7")
    local x8, y8 = cells("8")
    -- The keyboard lit "7" a moment ago; the clock is what clears that highlight,
    -- so a tick is what a machine would have done between the two presses.
    d:handle({ "char", "c" })
    d:tick(1.0)
    check("an idle key is an inverse block of the body's colours",
          s.bg(x7, y7) == C.lightGray and s.fg(x7, y7) == C.black,
          tostring(s.bg(x7, y7)))
    d:handle({ "mouse_move", 1, x8, y8 })
    check("the key under the pointer is lit, and the one left behind is not",
          s.bg(x8, y8) == C.brown and s.bg(x7, y7) == C.lightGray,
          tostring(s.bg(x8, y8)) .. "/" .. tostring(s.bg(x7, y7)))
    d:handle({ "mouse_click", 1, x7, y7 })
    check("a key that was just pressed wears the accent orange",
          s.bg(x7, y7) == C.orange, tostring(s.bg(x7, y7)))
    check("and the click reached the machine", s.find(4, "7") == 43,
          "[" .. s.row(4) .. "]")
    d:tick(0.5)
    check("the pressed highlight goes away on its own", s.bg(x7, y7) == C.lightGray,
          tostring(s.bg(x7, y7)))
    check("the pointer moves are counted in the dump", d.stats.moves >= 1,
          tostring(d.stats.moves))

    -- A 12 column body: the keys shrink and the keypad stays inside the window.
    local dn, sn = newdesk({ screen = screen.buffer(22, 16) })
    dn:draw()
    local nwin = dn:open("calc")
    local nb = desktop.body_rect(nwin)
    local nlay = calcapp.layout(nb.w, nb.h)
    check("a 12 column body shrinks the keys instead of pushing them out",
          nlay.key_w == 2 and nlay.pitch == 3 and nlay.key_w * 4 + 3 <= nb.w,
          nlay.key_w .. "/" .. nlay.pitch)
    check("every key of the narrow keypad is inside the body",
          nlay.buttons[#nlay.buttons].col + nlay.key_w - 1 <= nb.w,
          tostring(nlay.buttons[#nlay.buttons].col))
    local nbefore = dn.stats.clipped
    dn:draw()
    check("and the narrow keypad draws without one clipped cell",
          dn.stats.clipped == nbefore, tostring(dn.stats.clipped - nbefore))
    local function nat(key)
        for _, b in ipairs(nlay.buttons) do
            if b.key == key then return nb.x + b.col - 1, nb.y + b.row - 1 end
        end
    end
    for _, key in ipairs({ "7", "+", "3", "=" }) do
        local x, y = nat(key)
        click(dn, x, y)
    end
    check("a click in the narrow keypad still reaches the key",
          sn.find(nb.y, "10") == 16, "[" .. sn.row(nb.y) .. "]")
    -- The display is ONE row and right aligned: an entry longer than the body is
    -- cut from the LEFT with a marker, because the digits typed last are the ones
    -- the operator is watching, and it must not push the keypad down a row.
    dn:handle({ "char", "c" })
    for _, ch in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "1", "2", "3" }) do
        dn:handle({ "char", ch })
    end
    check("an overlong entry keeps its newest digits and marks the cut",
          sn.char(nb.x, nb.y) == ">" and sn.char(nb.x + nb.w - 1, nb.y) == "3" and
          sn.find(nb.y, "1234567890123") == nil, "[" .. sn.row(nb.y) .. "]")
    check("and the keypad still starts on the row it always did",
          sn.find(nb.y + 1, "AC") == nb.x, "[" .. sn.row(nb.y + 1) .. "]")
end

-- ===========================================================================
section("landing: leaving the desktop must not leave the machine outside its system")
-- ===========================================================================
-- The desktop can be started three ways, and only one of them ends at a shell
-- prompt by itself: from a ush session (the normal way, and what the session
-- command is run through), or from a boot script that runs the module directly,
-- or from the CraftOS prompt. desktop.landing is the one place that decides, and
-- the shell marks its command chunks with __ush_command so the decision is made
-- on a fact rather than on a guess about the caller.
do
    local called = 0
    local function runner(answer)
        return function() called = called + 1; return answer end
    end

    called = 0
    check("a desktop that IS a shell command returns to that prompt",
          desktop.landing({ in_shell = true, run_shell = runner(true) }) == "caller")
    check("and no second shell is started inside the one that is already there",
          called == 0, tostring(called))

    called = 0
    check("a desktop started outside the shell starts the shell",
          desktop.landing({ in_shell = false, run_shell = runner(true) }) == "shell")
    check("exactly once", called == 1, tostring(called))

    check("a shell that answers false is a failure, not a landing",
          desktop.landing({ run_shell = runner(false) }) == "shell-failed")

    local raised = false
    local verdict = desktop.landing({ run_shell = function()
        raised = true
        error("the shell would not start")
    end })
    check("a shell that raises is contained and reported, not passed on",
          verdict == "shell-failed" and raised == true, tostring(verdict))

    check("a landing cannot be claimed with nothing to start",
          desktop.landing({}) == "shell-failed" and desktop.landing() == "shell-failed")

    -- THE WIRING, read where it lives: the package's own command file. The
    -- landing is only worth anything if the command asks it, and asks it with the
    -- shell's mark -- and the mark is only worth anything if ush sets it (the
    -- source pin for that is in the command environment section above).
    local HOST = _G.read_host_file
    local binc = HOST and HOST(PROJ .. "/tools/pkgs/gnome/bin/desktop.lua")
    if type(binc) ~= "string" then
        skip("the landing wiring", "read_host_file cannot read the package tree")
    else
        check("the desktop command asks the landing where the operator goes",
              binc:find("desktop.landing(", 1, true) ~= nil,
              "the command never asks")
        check("and tells it whether a shell started it (__ush_command)",
              binc:find("in_shell = __ush_command == true", 1, true) ~= nil,
              "the fact the decision rests on is not passed")
        check("and it starts the project's shell, not something else",
              binc:find('local USH_PATH = "/usr/ush.lua"', 1, true) ~= nil and
              binc:find("shell.run(USH_PATH)", 1, true) ~= nil,
              "the shell path or the call is missing")
        local first_land = binc:find("land()", 1, true)
        local second_land = first_land and binc:find("land()", first_land + 1, true)
        check("the same landing runs after an interrupted desktop as well",
              first_land ~= nil and second_land ~= nil,
              "an interrupted desktop would drop the operator out too")
        -- "LOG OUT" ENDS THE SESSION, NOT THE MACHINE. The settings action quits
        -- the desktop with reason "logout"; the command writes the request the
        -- shell honours at its session boundary, and only when a shell started
        -- the desktop (anywhere else there is no session to end).
        check("the log out action asks the session to end, not the machine",
              binc:find('tostring(d.exit_reason) == "logout"', 1, true) ~= nil and
              binc:find('"/var/lib/.logout"', 1, true) ~= nil,
              "the logout request is not wired")
        check("and only when a shell started the desktop",
              binc:find("__ush_command == true", 1, true) ~= nil,
              "the guard is missing")
        local ushsrc = (_G.SH_SRC or {}).ush
        check("the shell honours the request at its session boundary",
              type(ushsrc) == "string" and
              ushsrc:find('if fs.exists("/var/lib/.logout") then', 1, true) ~= nil and
              ushsrc:find('fs.delete("/var/lib/.logout")', 1, true) ~= nil,
              "ush never looks for the request")
    end

    -- AND NO WAY OUT OF THE MACHINE FROM THE GUI. The log out action leaves the
    -- DESKTOP (Desktop:quit, pinned by the settings section), and nothing in the
    -- package may shut the machine down or reboot it: those are the shell's and
    -- the operator's decisions, not a window's.
    local files = { "bin/desktop.lua", "lib/gnome/desktop.lua",
                    "lib/gnome/apps/settings.lua", "lib/gnome/apps/calc.lua" }
    local offenders = {}
    for _, rel in ipairs(files) do
        local text = HOST and HOST(PROJ .. "/tools/pkgs/gnome/" .. rel)
        if type(text) == "string" then
            for _, call in ipairs({ "os.shutdown", "os.reboot", "os.exit" }) do
                if text:find(call, 1, true) then
                    offenders[#offenders + 1] = rel .. " calls " .. call
                end
            end
        end
    end
    check("no window can shut the machine down or reboot it", #offenders == 0,
          table.concat(offenders, ", "))
end

-- ===========================================================================
_G.__RESULT = { pass = pass, fail = fail, fails = fails, sections = sections }
say("")
for _, s in ipairs(sections) do
    say(string.format("SECTION %-58s pass=%d fail=%d", s.name, s.pass, s.fail))
end
for _, s in ipairs(skipped) do say("  SKIP: " .. s) end
say(string.format("assertions: %d passed, %d failed", pass, fail))
for _, f in ipairs(fails) do
    say("  FAIL: " .. f)
end
