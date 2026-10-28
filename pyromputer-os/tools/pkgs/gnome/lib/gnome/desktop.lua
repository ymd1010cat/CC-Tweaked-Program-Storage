-- gnome.desktop - an Ubuntu GNOME (Yaru) desktop for the Pyromputer OS machine: a
-- near black top panel, a permanent dock down the left edge, an activities
-- overview over the workspace, and windows with a title bar, an orange accent
-- cell, a close control on the right, click-to-focus, raise-on-click and
-- drag-by-title-bar. The accent colour is orange, which is what makes the
-- picture read as Ubuntu's GNOME rather than as a generic one.
--
-- THE SAME APPLICATION MAY BE OPEN MANY TIMES. open() never raises an existing
-- window: it makes a new one every time, and the windows of one application are
-- titled "Files", "Files 2", "Files 3" so a dump, a task manager row and an
-- operator can tell them apart. Everything a window owns lives on that window
-- (win.state, win.tasks, the ROM window a shell window built), so two copies share
-- no mutable state.
--
-- WHAT IT IS NOT. There is no ROM windowing API to build on: CraftOS-PC 2.8.3
-- has no `window` module, no paintutils.drawFilled and no paintutils.drawText
-- (all measured). Every border, title bar, highlight and card here is drawn by
-- this file, cell by cell, into a gnome.screen surface.
--
-- WHY THE EVENT LOOP IS SPLIT FROM os.pullEvent
-- term.getLine does not exist (measured), so nothing can read a drawn cell back
-- off a real screen. The only way any assertion -- the PC suite and the machine
-- acceptance alike -- can see what was drawn is to render into a buffer screen
-- and drive the desktop from a LIST of synthetic events. run() is that path and
-- returns the screen it drew into; run_interactive() is the same desktop with
-- os.pullEvent as the source. The interactive loop is a thin shell around the
-- same handle(), not a second implementation.
--
-- WHAT HAPPENS WHEN SOMETHING GOES WRONG (a desktop must not take the shell
-- down with it, and every one of these is asserted in tests/batch10_check.lua):
--   unknown event          counted in stats.unknown, ignored.
--   malformed event        counted in stats.malformed: a non-table, an event
--                          with no name, coordinates that are not numbers.
--   a raise in a handler   caught in handle(), counted in stats.errors; the
--                          desktop keeps its state and keeps drawing.
--   a raise inside an app  caught per call (stats.app_errors); the window shows
--                          "app error: ..." and every other window still draws.
--   a missing app module   the app is still listed, marked unavailable, and
--                          opening it opens a window that names the module.
--   a tiny screen          1x1 and up: the panel truncates, cards and the close
--                          control are dropped when there is no room, windows
--                          are clamped. Nothing raises.
local screenmod = require("gnome.screen")
local applist = require("gnome.apps")

local desktop = {}

-- The pump passes a call's arguments around as a table, and the runtimes this
-- project compiles under disagree about how: 5.1 has no table.pack, and 5.2+ has
-- no global unpack. One alias each is what keeps the package portable across all
-- six of them (and across the machine, which reports 5.2 with a 5.1 compat layer).
local unpack = table.unpack or unpack
local function pack(...)
    return { n = select("#", ...), ... }
end

-- Colour constants, spelled as the ROM's own values so this module has no load
-- time dependency on colors: read off CraftOS-PC 2.8.3 (colors.white == 1,
-- ... colors.black == 32768, and the bit position IS the blit letter's index).
local C = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
    pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024,
    blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768,
}
desktop.COLOURS = C

local THEME = {
    wallpaper_fg = C.white, wallpaper_bg = C.black,
    dim_fg = C.gray, dim_bg = C.black,
    panel_fg = C.white, panel_bg = C.black,
    -- The accent. Ubuntu's is orange, and it is used for exactly the three
    -- places the picture says "this one": the open activity, the selected card,
    -- and the accent cell and running dot of a window.
    accent_fg = C.black, accent_bg = C.orange,
    clock_fg = C.white, clock_bg = C.black,
    status_fg = C.lightGray, status_bg = C.black,
    overview_fg = C.white, overview_bg = C.blue,
    card_fg = C.white, card_bg = C.blue,
    card_sel_fg = C.black, card_sel_bg = C.orange,
    title_fg = C.white, title_bg = C.gray,
    title_off_fg = C.lightGray, title_off_bg = C.black,
    -- The one-cell mark at the left of a focused window's title bar.
    mark_fg = C.orange, mark_bg = C.orange,
    mark_off_fg = C.gray, mark_off_bg = C.black,
    border_fg = C.gray, border_bg = C.black,
    body_fg = C.white, body_bg = C.black,
    error_fg = C.white, error_bg = C.red,
    dock_fg = C.lightGray, dock_bg = C.black,
    dock_icon_on_fg = C.white,
    dock_sep_fg = C.gray, dock_sep_bg = C.black,
    dock_on_fg = C.orange, dock_off_fg = C.gray,
    overlay_fg = C.black, overlay_bg = C.lightGray,
    overlay_dim_fg = C.gray, overlay_dim_bg = C.black,
}
desktop.THEME = THEME

-- The fallback wallpaper: horizontal bands from purple at the top to orange at
-- the bottom, drawn with the sixteen colours the ROM has. It is what the desktop
-- falls back to on a build that cannot redefine the palette; the real sweep is
-- below.
desktop.WALLPAPER = { C.purple, C.magenta, C.red, C.orange }

-- The real wallpaper: six colour SLOTS redefined to six points of Ubuntu's own
-- purple to orange sweep. A terminal cell holds one background colour and the
-- sixteen ROM colours are far apart, so four flat bands is all the stock palette
-- can say; redefining six slots (term.setPaletteColour) gives six colours whose
-- neighbours differ by about 0.14 per channel, so three to four rows per stop
-- reads as a sweep rather than a step. There is deliberately no dithering: a
-- 4x2 cell checkerboard was tried in 1.7.5 and the owner could still see it,
-- because on a 51x19 screen one cell is a large block. The blend that was wanted
-- is in the RGB of the redefined slots, not in a pattern.
--
-- A palette belongs to a TERMINAL, not to a cell: while the desktop runs these six
-- slots look different everywhere they are used, on every window and in every
-- program the desktop pumps. The slots are chosen for what that costs:
--   * purple and magenta were the old wallpaper's own, and nothing else draws
--     with them once the wallpaper uses this table;
--   * green and pink are used by neither the package nor the shell;
--   * lightBlue is the user name in the shell's default prompt, so it becomes a
--     warm mid tone -- readable on black, and that prompt is not on the wallpaper;
--   * brown is only the calculator's hovered key.
-- Left alone: the shell's host colour (yellow), its path colour (lime), red (the
-- error colour), orange (the accent), blue (the overview's cards), cyan (Files
-- and Settings) and the five neutral slots.
--
-- The slots are put back when the desktop is done (Desktop:restore_palette), and
-- a screen that cannot redefine the palette gets WALLPAPER above instead: a
-- fallback that draws the old wallpaper, never a blank one.
desktop.WALLPAPER_STOPS = {
    { colour = C.purple,    rgb = { 0.294, 0.165, 0.388 } },  -- #4b2a63
    { colour = C.magenta,   rgb = { 0.400, 0.208, 0.478 } },  -- #66357a
    { colour = C.green,     rgb = { 0.541, 0.247, 0.525 } },  -- #8a3f86
    { colour = C.pink,      rgb = { 0.702, 0.302, 0.388 } },  -- #b34d63
    { colour = C.lightBlue, rgb = { 0.847, 0.400, 0.227 } },  -- #d8663a
    { colour = C.brown,     rgb = { 0.976, 0.502, 0.114 } },  -- #f9801d
}

-- The dithering matrix the wallpaper blends its bands with: sixteen levels in a
-- 4x2 ordered (Bayer) pattern, so a cell takes the next band when its own level
-- is below the row's blend fraction.
local BAYER = {
    { 0, 8, 2, 10 },
    { 12, 4, 14, 6 },
}

-- The keyboard codes the desktop recognises, as the ROM's LWJGL key codes (read
-- off rom/apis/keys.lua on CraftOS-PC 2.8.3, where the row that starts at 66 is
-- f8, f9, f10, numLock, scrollLock: F10 is 68; tab 15, enter 28, o 24). Spelled
-- here so the desktop works in a Lua state that has no keys table.
--
-- The back-out key is F10, not Escape. Escape never reaches the computer in
-- Minecraft -- the game keeps ESC for its own menu and never delivers it -- so
-- keys.escape is nil there and a branch keyed to it is dead code. This is the
-- same lesson lib/bios.lua's menus learned. F10 is delivered, is unbound in
-- vanilla Minecraft, and has no character, so typing it into a text field cannot
-- happen by accident.
local KEYS = { f10 = 68, tab = 15, enter = 28, backspace = 14, space = 57, o = 24 }
desktop.KEYS = KEYS

desktop.SHELL = "/usr/psh.lua"
desktop.CARD = { w = 12, h = 4 }
desktop.MIN_WIN = { w = 3, h = 3 }
desktop.PANEL_ROW = 1
-- The dock: three columns of icons down the left edge, which is Ubuntu's
-- default. It is chrome -- the dock is drawn in the desktop AND in the overview,
-- and no window may sit on top of it -- so its width is part of every geometry
-- function rather than a drawing detail.
desktop.DOCK_W = 3
-- The running indicator, one cell under its icon. ASCII, like everything else
-- this package draws: the terminal has no bullet that is not a character.
desktop.DOT = "*"

-- One tick is the scheduler's unit of time, and the period the interactive loop
-- arms its timer with: a task that sleeps a second is resumed after twenty ticks
-- in either driver, so a headless run can assert a schedule without waiting.
desktop.TICK = 0.05

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function centre(w, text)
    local x = math.floor((w - #text) / 2) + 1
    if x < 1 then x = 1 end
    return x
end
desktop.centre = centre

local function in_rect(rect, x, y)
    if not rect or not x or not y then return false end
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end
desktop.in_rect = in_rect

-- ===========================================================================
-- geometry: pure functions of the screen, so a click and the drawing agree
-- ===========================================================================
--
-- The layout functions are the single description of where things are. The
-- drawing code asks them, the hit testing asks them, and the tests assert on
-- them, which is why a panel that moves cannot leave its click target behind.

function desktop.panel(w, h, text)
    text = text or {}
    local activities = tostring(text.activities or "Activities")
    local clock = tostring(text.clock or "")
    local status = tostring(text.status or "")
    if #activities > w then activities = activities:sub(1, math.max(0, w)) end
    local clock_x = math.floor((w - #clock) / 2) + 1
    clock_x = screenmod.fit(clock_x, 1, math.max(1, w))
    local status_x = screenmod.fit(w - #status + 1, 1, math.max(1, w))
    return {
        row = desktop.PANEL_ROW,
        activities = { x = 1, y = desktop.PANEL_ROW, w = #activities, h = 1, text = activities },
        clock = { x = clock_x, y = desktop.PANEL_ROW, w = #clock, h = 1, text = clock },
        status = { x = status_x, y = desktop.PANEL_ROW, w = #status, h = 1, text = status },
    }
end

-- The workspace: what the desktop owns that is not chrome. A window lives here
-- and nowhere else -- right of the dock, under the panel -- and every function
-- that places one asks this, so a click, a drag and a drawing cannot disagree
-- about which part of the screen a window may use. A screen too small to hold
-- the chrome still answers a workspace of at least one cell, so nothing raises.
function desktop.WORK(w, h, dock_w)
    w = math.floor(tonumber(w) or 1)
    h = math.floor(tonumber(h) or 1)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    local dw = math.floor(tonumber(dock_w) or desktop.DOCK_W)
    if dw < 1 then dw = 1 end
    if dw > w then dw = w end
    local x = dw + 2                        -- the dock, then its separator cell
    if x > w then x = w end
    local y = desktop.PANEL_ROW + 1         -- straight under the panel
    if y > h then y = h end
    return { x = x, y = y, w = math.max(1, w - x + 1), h = math.max(1, h - y + 1) }
end

-- Where a row sits in a sweep of n stops, as a fractional index in 1..n: row 1
-- is exactly the first stop, the last row exactly the last one, and every row in
-- between lands between two of them. Keeping the fractional part is what lets
-- draw_wallpaper mix the two neighbours instead of stepping from one to the next.
local function sweep_at(n, h, y)
    local rows = math.floor(tonumber(h) or 1)
    if rows < 1 then rows = 1 end
    y = math.floor(tonumber(y) or 1)
    if y < 1 then y = 1 elseif y > rows then y = rows end
    if rows == 1 or n == 1 then return 1 end
    return 1 + ((y - 1) * (n - 1)) / (rows - 1)
end

function desktop.wallpaper_band_at(h, y)
    return sweep_at(#desktop.WALLPAPER, h, y)
end

-- The same question for the real sweep: where the row sits among the redefined
-- slots. The tests ask this what colour a row is, so it is public.
function desktop.wallpaper_stop_at(h, y)
    return sweep_at(#desktop.WALLPAPER_STOPS, h, y)
end

-- The stop a row is nearest to: what the wallpaper's own words sit on, and the
-- colour the fallback path calls the row's band.
function desktop.wallpaper_stop(h, y)
    local n = #desktop.WALLPAPER_STOPS
    local t = desktop.wallpaper_stop_at(h, y)
    local i = math.floor(t + 0.5)
    if i < 1 then i = 1 end
    if i > n then i = n end
    return desktop.WALLPAPER_STOPS[i].colour, i
end

function desktop.wallpaper_band(h, y)
    local n = #desktop.WALLPAPER
    local t = desktop.wallpaper_band_at(h, y)
    local i = math.floor(t + 0.5)
    if i < 1 then i = 1 end
    if i > n then i = n end
    return desktop.WALLPAPER[i], i
end

function desktop.overview(w, h, count, dock_w)
    local work = desktop.WORK(w, h, dock_w)
    local title = "Applications"
    if #title > work.w then title = title:sub(1, math.max(0, work.w)) end
    local out = {
        title = { x = work.x, y = work.y, w = #title, h = 1, text = title },
        cells = {}, card_w = 0, card_h = 0, columns = 0, work = work,
    }
    local top = work.y + 2
    local bottom = work.y + work.h - 1      -- the workspace's own last row
    local card_w = math.min(desktop.CARD.w, work.w)
    local card_h = math.min(desktop.CARD.h, bottom - top + 1)
    if card_w < 3 or card_h < 1 or bottom < top then return out end
    local columns = math.max(1, math.floor(work.w / card_w))
    out.card_w, out.card_h, out.columns = card_w, card_h, columns
    for i = 1, count do
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        local x = work.x + col * card_w
        local y = top + row * card_h
        if y + card_h - 1 > bottom then break end
        out.cells[#out.cells + 1] = { x = x, y = y, w = card_w, h = card_h, index = i }
    end
    return out
end

-- The dock: the favourites down the left edge, each with its running indicator
-- one row under it. Every other row is a spacer, which is what keeps the hit
-- target of one icon away from its neighbour's.
function desktop.dock(w, h, items, dock_w)
    w = math.floor(tonumber(w) or 1)
    h = math.floor(tonumber(h) or 1)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    local dw = math.floor(tonumber(dock_w) or desktop.DOCK_W)
    if dw < 1 then dw = 1 end
    if dw > w then dw = w end
    local y = desktop.PANEL_ROW + 1
    if y > h then y = h end
    local out = {
        x = 1, y = y, w = dw, h = math.max(0, h - y + 1),
        sep_x = dw + 1, dot = desktop.DOT, items = {},
    }
    local row = y
    for i, item in ipairs(items or {}) do
        local label = tostring(item.icon or item.label or item.id or "?")
        if #label > dw then label = label:sub(1, dw) end
        local dot_y = row + 1
        if dot_y > h then break end
        out.items[#out.items + 1] = {
            x = centre(dw, label), y = row, w = #label, h = 1,
            index = #out.items + 1, id = item.id, text = label,
            dot = { x = centre(dw, desktop.DOT), y = dot_y, w = 1, h = 1, text = desktop.DOT },
        }
        row = row + 2
    end
    return out
end

function desktop.close_rect(win)
    -- " [x]" needs five cells: the title bar has room for a close control only
    -- when it is at least six wide. A narrower window simply has none, and then
    -- nothing is drawn and nothing is returned.
    if not win or win.w < 6 then return nil end
    return { x = win.x + win.w - 3, y = win.y, w = 3, h = 1 }
end

function desktop.title_rect(win)
    return { x = win.x, y = win.y, w = win.w, h = 1 }
end

function desktop.window_rect(win)
    return { x = win.x, y = win.y, w = win.w, h = win.h }
end

-- The interior the app draws into: inside the title bar, the side borders and
-- the bottom border.
function desktop.body_rect(win)
    return { x = win.x + 1, y = win.y + 1,
             w = math.max(0, win.w - 2), h = math.max(0, win.h - 2) }
end

-- Where a new window goes. It is measured against the WORKSPACE, not the
-- screen, so a window never starts under the panel or over the dock, and each
-- further window is stepped down and right so the one behind stays visible.
function desktop.default_geometry(w, h, index, dock_w)
    local work = desktop.WORK(w, h, dock_w)
    local win_w = math.min(40, math.max(desktop.MIN_WIN.w, work.w - 4))
    local win_h = math.min(12, math.max(desktop.MIN_WIN.h, work.h - 4))
    local step = math.floor(tonumber(index) or 0) % 4
    local x = screenmod.fit(work.x + step * 2, work.x, work.x + work.w - win_w)
    local y = screenmod.fit(work.y + 1 + step, work.y, work.y + work.h - win_h)
    return x, y, win_w, win_h
end

-- ===========================================================================
-- the desktop itself
-- ===========================================================================
local Desktop = {}
Desktop.__index = Desktop

function desktop.new(opts)
    opts = opts or {}
    local d = setmetatable({}, Desktop)
    d.palette = copy(opts.palette or THEME)
    d.shell_path = tostring(opts.shell or desktop.SHELL)
    d.run_shell = opts.run_shell
    d.clock = opts.clock
    d.status_text = tostring(opts.status or "[psh]")
    d.panel_dark = true
    -- The dock's width is an option, because the workspace it leaves is what
    -- every window geometry is measured against.
    d.dock_w = math.floor(tonumber(opts.dock_w) or desktop.DOCK_W)
    if d.dock_w < 1 then d.dock_w = 1 end
    d.windows = {}
    d.window_count = 0
    d.focus = nil
    d.overview = false
    d.select = 1
    d.drag = nil
    d.exit = false
    d.exit_reason = nil
    d.last_error = nil
    d.last_unknown = nil
    d.last_handover = nil
    -- The clock, the tasks and the overlays. self.now only ever moves on a tick,
    -- which is what makes a schedule assertable (see the task section below).
    d.now = tonumber(opts.now) or 0
    -- Named step, not tick: the desktop has a tick() method, and an instance
    -- field would shadow it (a lookup finds the number first, and the call
    -- becomes "attempt to call a number value").
    d.step = tonumber(opts.step) or tonumber(opts.tick) or desktop.TICK
    if not (d.step > 0) then d.step = desktop.TICK end
    d.tasks = {}
    d.overlays = {}
    d.overlay_count = 0
    d.running_task = nil
    d.timer = nil
    -- What the terminal was before anything of ours ran. A program run from a
    -- window may redirect it (that is how a windowed program is fed at all), so
    -- the desktop remembers its own target in order to take it back.
    d.term_target = opts.term
    if d.term_target == nil and type(term) == "table" and type(term.current) == "function" then
        local okc, current = pcall(term.current)
        if okc then d.term_target = current end
    end
    -- THE SCREEN IS BOUND TO THE TERMINAL OBJECT, NOT TO THE GLOBAL term API.
    -- Since 1.6.0 a pumped program redirects the global term to its own window
    -- (that is how a shell inside a window is fed at all), and the term API's
    -- blit FOLLOWS that redirect. A desktop that painted through the API therefore
    -- painted its own frame INTO the shell's invisible window: on the machine the
    -- Terminal showed a copy of the desktop (measured: the window's lines were
    -- screen rows 1..10, "Activities", the dock, the title bar) and the shell's
    -- prompt was overwritten, so typing looked like it did nothing. The headless
    -- suite could not see it: it draws into a buffer and never touches term.
    -- Binding the object makes the desktop's drawing independent of whoever
    -- redirected the API; that is all the pump needs, and the pump keeps owning the
    -- redirect for the programs it feeds.
    if opts.screen then
        d.screen = opts.screen
    elseif type(d.term_target) == "table" then
        d.screen = screenmod.term(d.term_target)
    else
        d.screen = screenmod.term()
    end
    -- THE PUMP REGISTRY: every running pumped program, in registration order.
    -- It is a list rather than one slot because a shell window -- the Terminal or
    -- the Console, one mechanism with two names since 1.6.0 -- may be open more
    -- than once, and each copy runs its own shell (see the pump section below).
    -- An empty list means no program is being pumped.
    d.pumps = {}
    d.stats = {
        events = 0, clicks = 0, keys = 0, drags = 0, scrolls = 0,
        unknown = 0, malformed = 0, bad_coords = 0, other_buttons = 0,
        opened = 0, closed = 0, app_errors = 0, errors = 0,
        handovers = 0, handover_ok = 0, presents = 0,
        ticks = 0, tasks_started = 0, tasks_finished = 0, task_errors = 0, resumes = 0,
        overlays_opened = 0, overlays_closed = 0, overlay_errors = 0,
        overlay_events = 0, overlay_draws = 0,
        pumps = 0, pumped_events = 0, pump_errors = 0, reclaims = 0,
        pump_wraps = 0, pumps_peak = 0, term_asserts = 0,
        -- Cells an app asked for that fell outside its own window and were
        -- dropped instead of painted on the desktop (see app_api).
        clipped = 0,
        -- Pointer moves handed to the focused window's application. Counted
        -- because a hover that never reaches an app is invisible in the cells.
        moves = 0,
        -- Wallpaper palette: how many times the six slots were redefined and how
        -- many times they were put back. A machine that cannot redefine them
        -- (or a build without setPaletteColour) stays at zero and draws the
        -- sixteen colour fallback instead, which the counters make visible.
        palette_sets = 0, palette_restores = 0,
    }
    d.entries = opts.entries or applist.load(opts.specs)
    -- A host may hand over entries that never went through the registry -- a spec
    -- with draw/event straight on it. Those are normalised here, so the two ways of
    -- registering an application cannot differ in what the desktop does with it:
    -- without this, such an app resolved to NO app at all and its window came up
    -- blank, with nothing to explain why. (Found by the machine acceptance probe.)
    for i, entry in ipairs(d.entries) do
        local is_app = applist.is_app_spec and applist.is_app_spec(entry)
        if type(entry.app) ~= "table" and (is_app or entry.module) then
            d.entries[i] = applist.load({ entry })[1]
        end
    end
    d.by_id = {}
    for _, entry in ipairs(d.entries) do d.by_id[entry.id] = entry end
    d.favourites = opts.favourites or { "terminal", "files", "settings", "calc" }
    d.w, d.h = 1, 1
    d:resize()
    return d
end

function Desktop:register_app(spec)
    local entry = applist.load({ spec })[1]
    self.entries[#self.entries + 1] = entry
    self.by_id[entry.id] = entry
    return entry
end

function Desktop:resize()
    local w, h = self.screen.size()
    w = math.floor(tonumber(w) or 0)
    h = math.floor(tonumber(h) or 0)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    self.w, self.h = w, h
    for _, win in ipairs(self.windows) do
        self:move_window(win, win.x, win.y)
    end
    return w, h
end

function Desktop:clock_text()
    local c = self.clock
    if type(c) == "function" then
        local ok, value = pcall(c)
        if ok and value ~= nil then return tostring(value) end
        return "--:--"
    end
    if type(c) == "string" and c ~= "" then return c end
    if c == nil then
        local ok, value = pcall(os.date, "%H:%M")
        if ok and type(value) == "string" then return value end
    end
    return "--:--"
end

function Desktop:panel_layout()
    return desktop.panel(self.w, self.h, {
        activities = "Activities",
        clock = self:clock_text(),
        status = self.status_text,
    })
end

function Desktop:overview_layout()
    return desktop.overview(self.w, self.h, #self.entries, self.dock_w)
end

-- The dock's entries are the favourites, in the order the operator gave them.
-- The icon is what is drawn; the label a favourite carries is only for a host
-- that wants one (the dashboard that used to live at the bottom of the screen).
function Desktop:dock_layout()
    local items = {}
    for _, id in ipairs(self.favourites or {}) do
        local entry = self.by_id[id]
        if entry then
            items[#items + 1] = { id = entry.id, icon = entry.icon, label = entry.name }
        end
    end
    return desktop.dock(self.w, self.h, items, self.dock_w)
end

function Desktop:work_rect()
    return desktop.WORK(self.w, self.h, self.dock_w)
end

-- Is any window of this application open? This is what the dock's running
-- indicator means: one window or five, the dot is on.
function Desktop:app_running(id)
    for _, win in ipairs(self.windows) do
        if win.id == id then return true end
    end
    return false
end

-- Title the windows of ONE application: "Files", "Files 2", "Files 3". The
-- numbering follows creation order (win.serial, not the z order and not the
-- position in the window list) and is redone whenever a window of that
-- application opens or closes, so "one window is called Files" stays true after
-- a close instead of leaving a lone "Files 2" behind.
function Desktop:retitle_app(id)
    local list = {}
    for _, win in ipairs(self.windows) do
        if win.id == id then list[#list + 1] = win end
    end
    table.sort(list, function(a, b) return (a.serial or 0) < (b.serial or 0) end)
    local entry = self.by_id[id]
    local name = entry and entry.name or tostring(id)
    for i, win in ipairs(list) do
        win.number = i
        win.title = (i == 1) and name or (name .. " " .. tostring(i))
    end
    return #list
end

-- ------------------------------------------------------------------ windows
--
-- EVERY CALL MAKES A NEW WINDOW. This used to raise the existing copy of an
-- application instead, which made the desktop a task switcher rather than a
-- window manager: clicking Files twice gave one window, and two file browsers
-- could never be open at once. The same application may now be open as many
-- times as the operator asks for, and the only thing the copies share is the
-- application module -- every piece of per-window state lives on the window.
-- Open an application. opts (optional) is handed to the app's open hook through the
-- window, which is how one application opens another on a particular thing: Files
-- opens the editor on a file with `api.open("editor", { path = ... })`. It is kept
-- on the window (win.opts) so a redraw or a second open call can see it too.
function Desktop:open(id, opts)
    local entry = self.by_id[id]
    if not entry then return nil end
    self.window_count = self.window_count + 1
    -- The geometry is stepped by the number of windows already open, of ANY
    -- application: two copies of one application would otherwise land exactly on
    -- top of each other and the operator could not see that both exist.
    local x, y, w, h = desktop.default_geometry(self.w, self.h, #self.windows, self.dock_w)
    local win = {
        -- The title and the number are settled by retitle_app just below, because
        -- they depend on how many copies of this application are open.
        id = entry.id, title = entry.name, number = 1,
        x = x, y = y, w = w, h = h, state = {}, opts = opts,
        -- The creation order, which is what the titles are numbered by.
        serial = self.window_count,
    }
    self.windows[#self.windows + 1] = win
    self.focus = win
    self.stats.opened = self.stats.opened + 1
    self:retitle_app(entry.id)
    self:app_call(win, "open", opts)
    -- An app that defines main/task becomes a scheduled task. It gets its first
    -- slice here, before the frame that shows it, so a window whose picture comes
    -- only from its task is not blank for the first frame.
    local task = self:start_app_task(win)
    if task then self:resume_task(task) end
    -- A state change repaints. handle() draws after every event as well, and the
    -- second paint is a no-op for the terminal screen (its row diff is empty),
    -- so a caller may change the desktop directly and still see it.
    self:draw()
    return win
end

function Desktop:focus_window(win)
    for i, other in ipairs(self.windows) do
        if other == win then table.remove(self.windows, i) break end
    end
    self.windows[#self.windows + 1] = win          -- the last one is topmost
    self.focus = win
    self:draw()
    return win
end

function Desktop:close_window(win)
    for i, other in ipairs(self.windows) do
        if other == win then table.remove(self.windows, i) break end
    end
    -- A task whose window is gone must not be resumed into a window that is not
    -- there, and a modal must not outlive its application: both are dropped here
    -- rather than left for the next frame to trip over.
    local stopped = 0
    for _, t in ipairs(self.tasks) do
        if t.window == win and t.status ~= "dead" then
            t.status = "dead"
            t.stopped = "window closed"
            stopped = stopped + 1
        end
    end
    if stopped > 0 then
        self.stats.tasks_finished = self.stats.tasks_finished + stopped
    end
    -- A pump whose window is gone has nobody to feed. It is dropped from the
    -- registry here -- only its own entry, and only if it was still there -- so a
    -- closed shell window cannot leave a wrapper installed (or a terminal handed
    -- to a window that no longer exists) for the rest of the session.
    for i = #self.pumps, 1, -1 do
        local st = self.pumps[i]
        if st.window == win then self:pump_forget(st) end
    end
    self:clear_overlays(win)
    if self.drag and self.drag.win == win then self.drag = nil end
    if self.focus == win then self.focus = self.windows[#self.windows] end
    self.stats.closed = self.stats.closed + 1
    -- The remaining copies of this application are renumbered, so a lone window
    -- is called "Files" again rather than staying "Files 2" forever.
    self:retitle_app(win.id)
    self:draw()
    return true
end

-- A window is clamped to the WORKSPACE, not to the screen: the panel and the
-- dock are chrome, and a window that slid under them would be unreachable.
function Desktop:move_window(win, x, y)
    local work = self:work_rect()
    local maxx = math.max(work.x, work.x + work.w - win.w)
    local maxy = math.max(work.y, work.y + work.h - win.h)
    win.x = screenmod.fit(math.floor(tonumber(x) or win.x), work.x, maxx)
    win.y = screenmod.fit(math.floor(tonumber(y) or win.y), work.y, maxy)
    return win
end

function Desktop:top_window()
    return self.windows[#self.windows]
end

-- ------------------------------------------------------------------ the apps
--
-- THE WINDOW EDGE IS ENFORCED HERE, NOT IN EACH APPLICATION
-- screen.text/cell/fill clip at the SCREEN, and the screen is the whole display,
-- so an app that wrote one cell past its window painted over the window's border,
-- the window behind it, the dock -- the desktop. The Console happened to be safe
-- because it sliced every line to its own width before placing a cell; every other
-- app was one long string away from the same bug, and it was reported on the
-- machine as "the text ran out of the window". The clip therefore lives in the one
-- function every app draws through, so a new app cannot forget it:
--   write  keeps the characters inside the body's columns and drops the rest,
--   cell   drops a cell outside the body,
--   fill   intersects the rectangle with the body,
-- and every dropped cell is counted in stats.clipped. The counter is what lets a
-- test say "nothing was thrown away here" and, separately, "this overflow was",
-- instead of assuming a draw was short enough.
function Desktop:app_api(win)
    local body = desktop.body_rect(win)
    local d = self
    local left, right = body.x, body.x + body.w - 1
    local top, bottom = body.y, body.y + body.h - 1
    local function drop(n)
        n = math.floor(tonumber(n) or 0)
        if n > 0 then d.stats.clipped = d.stats.clipped + n end
    end
    return {
        desktop = d, screen = d.screen, win = win, body = body,
        w = body.w, h = body.h,
        colours = C, keys = KEYS, shell = d.shell_path,
        write = function(col, row, text, fg, bg)
            if text == nil then text = "" end
            text = tostring(text)
            if text == "" then return 0 end
            local x = body.x + math.floor(tonumber(col) or 1) - 1
            local y = body.y + math.floor(tonumber(row) or 1) - 1
            -- The whole run is off the body in y: not one character has a cell.
            if body.w <= 0 or body.h <= 0 or y < top or y > bottom then
                drop(#text)
                return 0
            end
            -- The body columns are [left, right]; the run covers [x, x+#text-1].
            local first = 1
            if x < left then first = left - x + 1 end
            local last = #text
            if x + last - 1 > right then last = right - x + 1 end
            if last < first then
                drop(#text)
                return 0
            end
            drop(#text - (last - first + 1))
            d.screen.text(x + first - 1, y, text:sub(first, last), fg, bg)
            return last - first + 1
        end,
        cell = function(col, row, ch, fg, bg)
            local x = body.x + math.floor(tonumber(col) or 1) - 1
            local y = body.y + math.floor(tonumber(row) or 1) - 1
            if body.w <= 0 or body.h <= 0 or x < left or x > right or
               y < top or y > bottom then
                drop(1)
                return false
            end
            d.screen.cell(x, y, ch, fg, bg)
            return true
        end,
        fill = function(col, row, cw, chh, ch, fg, bg)
            local x1 = body.x + math.floor(tonumber(col) or 1) - 1
            local y1 = body.y + math.floor(tonumber(row) or 1) - 1
            local x2 = x1 + math.floor(tonumber(cw) or 0) - 1
            local y2 = y1 + math.floor(tonumber(chh) or 0) - 1
            -- Same normalisation screen.fill does, so a caller that measured its
            -- rectangle backwards is clipped rather than silently lost.
            if x1 > x2 then x1, x2 = x2, x1 end
            if y1 > y2 then y1, y2 = y2, y1 end
            local total = (x2 - x1 + 1) * (y2 - y1 + 1)
            if body.w <= 0 or body.h <= 0 then
                drop(total)
                return 0
            end
            local cx1, cx2 = math.max(x1, left), math.min(x2, right)
            local cy1, cy2 = math.max(y1, top), math.min(y2, bottom)
            if cx1 > cx2 or cy1 > cy2 then
                drop(total)
                return 0
            end
            drop(total - (cx2 - cx1 + 1) * (cy2 - cy1 + 1))
            d.screen.fill(cx1, cy1, cx2, cy2, ch, fg, bg)
            return (cx2 - cx1 + 1) * (cy2 - cy1 + 1)
        end,
        open = function(id, app_opts) return d:open(id, app_opts) end,
        close = function() return d:close_window(win) end,
        handover = function() return d:handover(win) end,
        task = d:task_api(),
        overlay = function(spec) return d:push_overlay(spec, win) end,
    }
end

-- Call one app callback. A raise inside an app is the app's problem, not the
-- desktop's: it is recorded on the window and counted, and the loop goes on.
function Desktop:app_call(win, what, ...)
    local entry = self.by_id[win.id]
    local app = entry and entry.app
    if type(app) ~= "table" or type(app[what]) ~= "function" then return false end
    local ok, result = pcall(app[what], self:app_api(win), win, ...)
    if not ok then
        win.error = tostring(result)
        self.stats.app_errors = self.stats.app_errors + 1
        return false
    end
    return result
end

-- An application that defines `main` (or `task`) runs as a task rather than as a
-- pair of callbacks: it is started when its window opens and resumed by the
-- scheduler from then on. `open` and `draw` still run, so an app may use both --
-- a task for the work that waits, the callbacks for the picture.
function Desktop:start_app_task(win)
    local entry = self.by_id[win.id]
    local app = entry and entry.app
    local main = app and (app.main or app.task)
    if type(main) ~= "function" then return nil end
    local d = self
    return self:start_task(win, function() return main(d:app_api(win), win) end, win.title)
end

-- ------------------------------------------------------------------ the tasks
--
-- WHY A TASK IS A COROUTINE AND NOT A PROCESS
-- CraftOS is single threaded, and its own parallel API is a coroutine scheduler
-- (waitForAny around coroutine.resume), so "another process" on this machine can
-- only mean another coroutine. The desktop therefore schedules its own: a window
-- may run one or more tasks, a task yields through the api it was handed
-- (api.task), and the desktop resumes whatever is due. Two applications making
-- progress in one run is what multitasking means here. Nothing is preempted:
-- that is a property of the machine, not of this desktop.
--
-- TIME IS INJECTABLE BECAUSE THE SCREEN IS
-- A sleep that can only be observed by waiting is not testable, so the desktop
-- owns a clock (self.now) that only a tick moves. The interactive loop arms
-- os.startTimer(self.tick) for its ticks; a headless run is handed {"tick"}
-- events. A task that slept 0.1 s is therefore resumed on the second tick in
-- either driver, and an assertion can say so without sleeping at all.

function Desktop:start_task(win, fn, name)
    if type(fn) ~= "function" then return nil end
    local t = {
        co = coroutine.create(fn),
        name = tostring(name or (win and win.title) or "task"),
        window = win, status = "ready", waiting = "tick", wake_at = nil,
        resumes = 0, error = nil, started = self.now,
    }
    self.tasks[#self.tasks + 1] = t
    if win then
        win.tasks = win.tasks or {}
        win.tasks[#win.tasks + 1] = t
    end
    self.stats.tasks_started = self.stats.tasks_started + 1
    return t
end

-- Resume one task once. A raise inside a task is the task's problem, not the
-- desktop's: coroutine.resume answers it rather than propagating it, so it is
-- recorded on the task and on the window it belongs to and the remaining tasks
-- keep running -- the rule an app callback already follows.
function Desktop:resume_task(t)
    if not t or t.status == "dead" then return false end
    t.resumes = t.resumes + 1
    t.waiting = nil
    t.wake_at = nil
    self.stats.resumes = self.stats.resumes + 1
    local previous = self.running_task
    self.running_task = t
    local ok, err = coroutine.resume(t.co)
    self.running_task = previous
    if not ok then
        t.status = "dead"
        t.error = tostring(err)
        self.stats.task_errors = self.stats.task_errors + 1
        self.stats.tasks_finished = self.stats.tasks_finished + 1
        if t.window then t.window.task_error = t.error end
        return false
    end
    if coroutine.status(t.co) == "dead" then
        t.status = "dead"
        self.stats.tasks_finished = self.stats.tasks_finished + 1
    else
        t.status = "suspended"
    end
    return true
end

-- Everything that is due now: a task that has never run or is waiting on a tick,
-- and a task whose sleep has expired. A task waiting on an event is deliberately
-- NOT resumed here -- poke_tasks is what an event does -- so a task cannot be
-- woken by the clock it did not ask for.
function Desktop:run_tasks()
    for _, t in ipairs(self.tasks) do
        if t.status ~= "dead" and t.waiting ~= "event" and t.waiting ~= "pump" and
           (t.wake_at == nil or t.wake_at <= self.now) then
            self:resume_task(t)
        end
    end
    return #self.tasks
end

function Desktop:poke_tasks()
    for _, t in ipairs(self.tasks) do
        if t.status ~= "dead" and t.waiting == "event" then
            self:resume_task(t)
        end
    end
    return #self.tasks
end

-- One tick: time moves, everything due runs. The caller draws.
function Desktop:advance(dt)
    local step = tonumber(dt)
    if not step or step <= 0 then step = self.step end
    self.now = self.now + step
    self.stats.ticks = self.stats.ticks + 1
    self:run_tasks()
    return self.now
end

-- The api a task yields through. It acts on the task that is running now, which
-- is why it is built per call rather than cached on the window.
function Desktop:task_api()
    local d = self
    local function current() return d.running_task end
    return {
        spawn = function(fn, name)
            local owner = current() and current().window or nil
            return d:start_task(owner, fn, name)
        end,
        sleep = function(seconds)
            local t = current()
            if not t then return false end
            t.waiting = "sleep"
            t.wake_at = d.now + math.max(0, tonumber(seconds) or 0)
            return coroutine.yield("sleep")
        end,
        wait_event = function()
            local t = current()
            if not t then return false end
            t.waiting = "event"
            return coroutine.yield("event")
        end,
        yield = function()
            local t = current()
            if not t then return false end
            t.waiting = "tick"
            return coroutine.yield("tick")
        end,
        now = function() return d.now end,
        current = current,
        pump = function(fn, opts) return d:pump(fn, opts) end,
    }
end

-- ------------------------------------------------------------------- the pump
--
-- A BLOCKING PROGRAM CANNOT RUN IN THE FRAME LOOP
-- os.pullEvent and os.pullEventRaw are this machine's only event read, and both
-- block until an event arrives. A program written as "read, react, read again" --
-- a shell at its prompt is the one that matters here -- would therefore freeze the
-- desktop: no repaint, no clock, no second window. The pump turns such a program
-- into one of the desktop's tasks: the program runs in a coroutine of its own, its
-- read is answered by the desktop, and control returns to the frame loop between
-- events. Coroutines are the only concurrency this machine has (there are no
-- threads, and nothing can preempt a running function), which is why the waiting
-- happens at the task's level and the program never really reads the machine.
--
-- ONE READ, MANY PROGRAMS
-- os.pullEvent is one global function, so "which program is the reader" cannot be
-- asked of the machine. The wrapper is installed ONCE, when the first program
-- starts pumping in this Lua state, and removed when the last one ends. While it is
-- installed the wrapper answers a call by the pump the CALLER belongs to
-- (coroutine.running() is the key), and a puller that belongs to no pump reaches
-- the machine exactly as before. Consequences worth knowing:
--   * self.pumps is a registry in registration order, oldest first;
--   * #self.pumps is how many programs are being pumped right now;
--   * stats.pump_wraps counts installations of the wrapper, so it stays at one
--     while any number of programs are pumped.
--
-- WHO IS OFFERED AN EVENT, AND WHO WINS
-- One event goes to one pump: delivering it twice would wake one program twice.
-- The order is:
--   1. the focused window's pump, when the program's own filter accepts the
--      event. The keyboard belongs to the window the operator is looking at, and
--      a program in a background window is offered no key or char at all -- that
--      is what makes "typing goes to the focused console" true;
--   2. otherwise the other pumps in REGISTRATION order (oldest first). A
--      background shell still receives its timers and rednet messages while a
--      different window has the focus: the pump is its event source, and a delay
--      it asked for must not depend on where the operator clicked.
-- A pump bound to a window is offered no mouse event unless it asked for them
-- (opts.mouse), and a click belongs to the focused window like the keyboard. With
-- the overview up the keyboard belongs to the desktop, so nothing is pumped there:
-- one window cannot hold the desktop hostage. Every filter the program passes is
-- honoured, with one deliberate widening: a program waiting for "char" is also
-- offered "key", which is what the ROM does and what an interrupt wrapper on top
-- of this needs in order to see a Ctrl combination at all.
--
-- THE TERMINAL IS ONE GLOBAL TARGET TOO
-- term.redirect sets one target for the whole machine, so two pumped programs with
-- two windows would otherwise write into whichever window redirected last. A pump
-- is given the terminal its program owns (opts.term) and re-asserts that target
-- before every slice of the program; that is what makes two shells two windows
-- instead of two views of one. A program that redirects term and then ends -- or
-- simply forgets to put it back -- must not leave the desktop drawing into a window
-- that is gone, so a pump that ends hands the terminal on: to the most recently
-- registered pump that still has a target, and back to the desktop's own target
-- (reclaim_terminal) when none is left.
--
-- THE READABLE SURFACE IS THE ONE WE CREATED
-- Measured on CraftOS-PC 2.8.3: term.native() has no getLine, term.getLine does not
-- exist at all, and term.current() is a different table from term.native() even on
-- the machine's own screen -- while every window.create window has getLine(y),
-- answering text, foreground and background. A shell in a window is therefore built
-- on a ROM window created below the desktop's own terminal, and the desktop keeps
-- that terminal handle (d.term_target) instead of asking term.current() later:
-- after a program redirected the API, term.current() is that program's window.

-- The events that belong to the keyboard, and therefore to the focused window.
-- Nothing else is in this table: a timer or a rednet message is not a key.
local KEY_EVENTS = { key = true, char = true, key_up = true, paste = true }

-- Process wide, because os.pullEvent is: holders is how many programs are being
-- pumped, owner maps a program's coroutine to its pump entry, and machine_pull /
-- machine_raw are what was underneath the wrapper (put back when holders reaches
-- zero).
local pull_hook = { holders = 0, owner = {}, machine_pull = nil, machine_raw = nil }

-- The wrapper. One closure per flavour, so os.pullEvent and os.pullEventRaw keep
-- answering with their own function.
local function hooked_read(raw)
    return function(...)
        local entry = pull_hook.owner[coroutine.running()]
        local machine = raw and pull_hook.machine_raw or pull_hook.machine_pull
        if entry == nil then
            -- Not a pumped program: this read belongs to the machine.
            if type(machine) ~= "function" then
                error("this machine has no os.pullEvent", 0)
            end
            return machine(...)
        end
        entry.request = pack(...)
        local ev = coroutine.yield("pull")
        entry.request = nil
        if ev == nil then
            -- The pump was torn down under the call (its window closed, or the
            -- desktop ended): reach the machine rather than return nothing to a
            -- program that expects an event.
            local fallback = raw and pull_hook.machine_raw or pull_hook.machine_pull
            if type(fallback) == "function" then return fallback() end
            return nil
        end
        return unpack(ev, 1, ev.n or #ev)
    end
end

-- Hold the wrapper: the 0 -> 1 transition swaps the globals, every later call only
-- counts. Returns true only for the call that did the swap, which is what lets a
-- stats counter say "installed once" rather than "installed per program".
local function hold_hook()
    pull_hook.holders = pull_hook.holders + 1
    if pull_hook.holders > 1 then return false end
    pull_hook.machine_pull = os.pullEvent
    pull_hook.machine_raw = os.pullEventRaw
    os.pullEvent = hooked_read(false)
    os.pullEventRaw = hooked_read(true)
    return true
end

-- And release it on the 1 -> 0 transition: the machine's own functions come back
-- exactly as they were found, even when the program raised.
local function release_hook()
    pull_hook.holders = pull_hook.holders - 1
    if pull_hook.holders > 0 then return false end
    pull_hook.holders = 0
    os.pullEvent = pull_hook.machine_pull
    os.pullEventRaw = pull_hook.machine_raw
    return true
end

function Desktop:pump_active()
    for _, entry in ipairs(self.pumps) do
        if entry.waiting then return true end
    end
    return false
end

-- Does THIS pump's program want this event? The program's own filter (entry.
-- request) decides, plus the two rules that are not its to decide: the overview
-- takes the keyboard back, and a pump that did not ask for the mouse never sees a
-- click.
function Desktop:pump_matches(ev, entry)
    if not entry or not entry.waiting then return false end
    if self.overview then return false end
    local name = type(ev) == "table" and ev[1] or nil
    if type(name) ~= "string" then return false end
    if not entry.mouse and name:find("^mouse_") then return false end
    local req = entry.request
    if req == nil or req.n == 0 then return true end
    for i = 1, req.n do
        local want = req[i]
        if want == nil or want == name then return true end
        if want == "char" and name == "key" then return true end
    end
    return false
end

-- WHICH pump gets this event, if any. The rule is stated in the section comment:
-- the focused window's pump first, then registration order, one event to one pump.
function Desktop:pump_offer(ev)
    local name = type(ev) == "table" and ev[1] or nil
    if type(name) ~= "string" then return nil end
    local keyboard = KEY_EVENTS[name] == true
    local pointer = name:find("^mouse_") ~= nil
    local focused = nil
    if self.focus ~= nil then
        for _, entry in ipairs(self.pumps) do
            if entry.window == self.focus then focused = entry break end
        end
    end
    if focused ~= nil and self:pump_matches(ev, focused) then return focused end
    -- A key is the focused window's or the desktop's, never a background shell's:
    -- otherwise typing would land in a window the operator is not looking at.
    if keyboard then return nil end
    for _, entry in ipairs(self.pumps) do
        if entry ~= focused and self:pump_matches(ev, entry) then
            -- A click belongs to the window under the pointer; a background pump
            -- is not offered one it cannot see.
            if not (pointer and entry.window ~= nil and entry.window ~= self.focus) then
                return entry
            end
        end
    end
    return nil
end

-- Hand one event to a pumping program. Its task is in waiting == "pump", which
-- neither the clock nor poke_tasks resumes, so this is the only thing that can wake
-- it -- and that is what keeps one event from waking it twice. The entry is passed
-- in by pump_offer, so the event cannot be delivered to a different program than
-- the one that was chosen.
function Desktop:pump_deliver(ev, entry)
    entry = entry or self:pump_offer(ev)
    if not entry or not entry.waiting then return false end
    entry.answer = ev
    entry.events = entry.events + 1
    self.stats.pumped_events = self.stats.pumped_events + 1
    if entry.task then self:resume_task(entry.task) end
    return true
end

-- Take the terminal back from whatever ran last. term.redirect is one global
-- target, so a program that redirected it and then died -- or simply forgot to
-- restore -- would leave the desktop writing into a window that no longer exists.
-- Called when the last pump ends, after a whole-screen handover, and at the top of
-- every interactive loop iteration, so no single program can keep the machine's
-- terminal for the rest of the session.
function Desktop:reclaim_terminal()
    if type(term) ~= "table" or type(term.redirect) ~= "function" then return false end
    local target = self.term_target
    if target == nil then
        if type(term.current) ~= "function" then return false end
        local okc, current = pcall(term.current)
        if not okc or current == nil then return false end
        self.term_target = current
        target = current
    end
    local ok = pcall(term.redirect, target)
    if ok then self.stats.reclaims = self.stats.reclaims + 1 end
    return ok
end

-- Re-assert one terminal target. Used before every slice of a pumped program, so
-- the program always writes into the surface it was given even when another pumped
-- program redirected term after it did (see "THE TERMINAL IS ONE GLOBAL TARGET
-- TOO" above).
function Desktop:pump_terminal(target)
    if type(term) ~= "table" or type(term.redirect) ~= "function" then return false end
    if target == nil then return false end
    local ok = pcall(term.redirect, target)
    if ok then self.stats.term_asserts = self.stats.term_asserts + 1 end
    return ok
end

-- Hand the terminal on when one pump ends. A pump that redirected term and then
-- ended must not leave the desktop writing into a window that is gone -- but with
-- another pumped program still running, the right target is THAT program's, not
-- the desktop's: it is the one that will write next. Only when no pumped program
-- with a target is left does the desktop take its own terminal back.
function Desktop:pump_restore_terminal(entry)
    local target = nil
    for _, other in ipairs(self.pumps) do
        if other ~= entry and other.term ~= nil then target = other.term end
    end
    if target ~= nil then return self:pump_terminal(target) end
    return self:reclaim_terminal()
end

-- Drop ONE pump: the one that ended, and only that one. The terminal is handed on
-- after the entry is gone, so "who is left" is answered by the registry itself.
function Desktop:pump_forget(entry)
    if not entry or not entry.registered then return false end
    entry.registered = false
    for i = #self.pumps, 1, -1 do
        if self.pumps[i] == entry then table.remove(self.pumps, i) end
    end
    pull_hook.owner[entry.co] = nil
    release_hook()
    self:pump_restore_terminal(entry)
    return true
end

-- Run a blocking function as a task of the one that is running now. Any number of
-- programs may be pumped at the same time (a shell per window); opts.term is the
-- terminal surface this program writes through, re-asserted before every slice.
function Desktop:pump(fn, opts)
    opts = opts or {}
    if type(fn) ~= "function" then return false, "the pump needs a function" end
    local me = coroutine.running()
    local task = self.running_task
    if me == nil or task == nil then
        return false, "the pump has to run inside a task"
    end
    -- THE PROGRAM GOES IN A COROUTINE OF ITS OWN, and this loop is what drives it.
    -- Not a detail: on 5.1/LuaJIT a yield inside a pcall is "attempt to yield
    -- across C-call boundary", so a program wrapped in pcall could not wait for
    -- anything at all. Here the waiting is done by THIS loop, at the task's level,
    -- and the program's raises come back from coroutine.resume -- which also means
    -- the task's own resume_task contains them, as it does for any other task.
    local program = coroutine.create(fn)
    local entry = {
        co = program, task = task, window = opts.window or task.window,
        term = opts.term, mouse = opts.mouse == true, request = nil, answer = nil,
        waiting = false, events = 0, registered = true, number = #self.pumps + 1,
    }
    self.pumps[#self.pumps + 1] = entry
    if #self.pumps > self.stats.pumps_peak then self.stats.pumps_peak = #self.pumps end
    pull_hook.owner[program] = entry
    if hold_hook() then self.stats.pump_wraps = self.stats.pump_wraps + 1 end
    self.stats.pumps = self.stats.pumps + 1

    if entry.term ~= nil then self:pump_terminal(entry.term) end
    local ok, err = coroutine.resume(program)
    while ok and coroutine.status(program) == "suspended" do
        entry.waiting = true
        task.waiting = "pump"
        while entry.answer == nil and entry.registered do
            coroutine.yield("event")
        end
        entry.waiting = false
        if not entry.registered or entry.answer == nil then break end
        local ev = entry.answer
        entry.answer = nil
        -- The terminal is one global target: re-assert this program's before the
        -- slice that is about to write through it.
        if entry.term ~= nil then self:pump_terminal(entry.term) end
        ok, err = coroutine.resume(program, ev)
    end
    -- Only this pump's own entry is cleaned up here; every other one keeps running.
    self:pump_forget(entry)
    task.waiting = nil
    if not ok then
        self.stats.pump_errors = self.stats.pump_errors + 1
        return false, tostring(err)
    end
    return true
end

-- ------------------------------------------------------------------ the overlays
--
-- WHAT AN OVERLAY IS FOR, AND WHY AN APPLICATION CANNOT DO IT
-- A menu, a modal question, a tooltip, a notification: something drawn over the
-- windows AND over the panel, that may also have to swallow the event which would
-- otherwise reach the desktop. An app cannot do either from its own hooks: the
-- frame paints the dock and the panel after every window, so whatever an app draws
-- is painted over, and an event offered to a window has already been routed. An
-- overlay is a per-frame draw hook with its own event hook: drawn after the panel,
-- offered every event before the desktop's own dispatch.
--
-- THE RULES THAT MAKE IT A LAYER
-- An overlay consumes an event only by answering truthy: a tooltip that answers
-- nothing lets the click through; a modal answers true and the click never reaches
-- the window underneath. Overlays are offered events topmost first, because the
-- operator acts on what they can see. A raise inside an overlay is contained and
-- counted (stats.overlay_errors), exactly as an app's raise is. An overlay belongs
-- to the window that asked for it, so closing that window drops it: a modal cannot
-- outlive the application that opened it and go on eating events for a window that
-- is gone.

function Desktop:push_overlay(spec, win)
    if type(spec) == "function" then spec = { draw = spec } end
    if type(spec) ~= "table" then return nil end
    self.overlay_count = self.overlay_count + 1
    local ov = {
        name = tostring(spec.name or ("overlay " .. tostring(self.overlay_count))),
        number = self.overlay_count,
        draw = spec.draw, event = spec.event, window = win,
    }
    self.overlays[#self.overlays + 1] = ov
    self.stats.overlays_opened = self.stats.overlays_opened + 1
    return ov
end

function Desktop:pop_overlay(ov)
    if ov == nil then ov = self.overlays[#self.overlays] end
    for i, other in ipairs(self.overlays) do
        if other == ov then
            table.remove(self.overlays, i)
            self.stats.overlays_closed = self.stats.overlays_closed + 1
            return true
        end
    end
    return false
end

-- Drop every overlay a window owns. Called when the window closes, so a modal
-- cannot outlive the application that opened it and leave the desktop offering
-- events to a hook whose window is gone.
function Desktop:clear_overlays(win)
    local removed = 0
    for i = #self.overlays, 1, -1 do
        if self.overlays[i].window == win then
            table.remove(self.overlays, i)
            self.stats.overlays_closed = self.stats.overlays_closed + 1
            removed = removed + 1
        end
    end
    return removed
end

function Desktop:overlay_depth() return #self.overlays end

-- A window's api is relative to the window's interior; an overlay is not in a
-- window, so its coordinates are the screen's own.
function Desktop:overlay_api(ov)
    local d = self
    return {
        desktop = d, screen = d.screen, name = ov.name, number = ov.number,
        win = ov.window, w = d.w, h = d.h,
        now = function() return d.now end,
        write = function(x, y, text, fg, bg) d.screen.text(x, y, text, fg, bg) end,
        cell = function(x, y, ch, fg, bg) d.screen.cell(x, y, ch, fg, bg) end,
        fill = function(x1, y1, x2, y2, ch, fg, bg)
            d.screen.fill(x1, y1, x2, y2, ch, fg, bg)
        end,
        close = function() return d:pop_overlay(ov) end,
    }
end

function Desktop:overlay_event(ev)
    for i = #self.overlays, 1, -1 do
        local ov = self.overlays[i]
        if type(ov.event) == "function" then
            local ok, handled = pcall(ov.event, self:overlay_api(ov), ev, ov)
            if not ok then
                self.stats.overlay_errors = self.stats.overlay_errors + 1
                self.last_error = tostring(handled)
            elseif handled then
                self.stats.overlay_events = self.stats.overlay_events + 1
                return true
            end
        end
    end
    return false
end

function Desktop:draw_overlays()
    for _, ov in ipairs(self.overlays) do
        if type(ov.draw) == "function" then
            self.stats.overlay_draws = self.stats.overlay_draws + 1
            local ok, err = pcall(ov.draw, self:overlay_api(ov), ov)
            if not ok then
                self.stats.overlay_errors = self.stats.overlay_errors + 1
                self.last_error = tostring(err)
            end
        end
    end
end

-- ------------------------------------------------------- the terminal handover
--
-- A DESKTOP CAPABILITY, NOT WHAT THE TERMINAL DOES (1.6.0)
-- Giving the whole screen to a program is a shape an application may still ask
-- for: the screen is released, the program owns the terminal for as long as it
-- runs, and the desktop takes the screen back and repaints after it returns. The
-- Terminal used to be the app that did this; since 1.6.0 it runs its shell inside
-- its own window (gnome.apps.shellwin) like the Console, so the shipped desktop has
-- no full screen app left. The capability is kept because it is the honest other
-- shape -- a program that needs the whole terminal, not a rectangle -- and the
-- suite exercises it through a synthetic app rather than through a shipped one.
function Desktop:handover(win)
    local s = self.screen
    self.stats.handovers = self.stats.handovers + 1
    local runner = self.run_shell
    if type(runner) ~= "function" then
        runner = function(path)
            if type(shell) == "table" and type(shell.run) == "function" then
                return shell.run(path)
            end
            error("this machine has no shell.run: cannot start " .. tostring(path), 0)
        end
    end
    -- The screen is not the desktop's while the shell runs. release() clears it
    -- and refuses every later draw, so nothing here can paint over the session;
    -- acquire() takes it back and the full repaint below restores the desktop.
    -- The palette is the terminal's, so it is handed back as well: a full screen
    -- program must see the ROM's colours, and the repaint redefines them.
    self:restore_palette()
    s.release()
    local ok, result = pcall(runner, self.shell_path)
    s.acquire()
    -- The shell, or anything it ran, may have left the terminal redirected: the
    -- desktop's own screen object survives that, but the next thing to use the
    -- global term must not inherit it.
    self:reclaim_terminal()
    if ok then
        self.stats.handover_ok = self.stats.handover_ok + 1
    else
        self.stats.errors = self.stats.errors + 1
    end
    self.last_handover = {
        ok = ok, path = self.shell_path, result = result,
        error = (not ok) and tostring(result) or nil,
    }
    if win then
        win.last_result = ok and tostring(result) or ("error: " .. tostring(result))
    end
    self:draw()
    return self.last_handover
end

-- --------------------------------------------------------------- interaction
function Desktop:toggle_overview()
    self.overview = not self.overview
    if #self.entries > 0 then
        self.select = screenmod.fit(self.select, 1, #self.entries)
    else
        self.select = 1
    end
    return self.overview
end

function Desktop:select_next(step)
    if #self.entries == 0 then return nil end
    step = step or 1
    self.select = ((self.select - 1 + step) % #self.entries) + 1
    return self.entries[self.select]
end

function Desktop:quit(reason)
    -- The wallpaper's colour slots belong to the terminal: they are put back
    -- before the operator is handed anything else (the shell, usually).
    self:restore_palette()
    self.exit = true
    self.exit_reason = tostring(reason or "quit")
    return true
end

function Desktop:dock_hit(x, y)
    local lay = self:dock_layout()
    for _, item in ipairs(lay.items) do
        -- The icon and its running dot are one target of two rows: an operator
        -- clicking under an icon means the application above it.
        if in_rect({ x = lay.x, y = item.y, w = lay.w, h = 2 }, x, y) then
            return item
        end
    end
    return nil
end

-- The dock is chrome and is drawn over everything, so it takes the click before
-- any window does. A click on the black between two icons does nothing at all --
-- and in particular does not drop the focus, which a click on the wallpaper does.
function Desktop:dock_click(x, y)
    local lay = self:dock_layout()
    if not (x >= lay.x and x <= lay.sep_x and y >= lay.y and y <= lay.y + lay.h - 1) then
        return false
    end
    local item = self:dock_hit(x, y)
    if item then
        if self.overview then self.overview = false end
        self:open(item.id)
    end
    return true
end

function Desktop:on_click(button, x, y)
    self.stats.clicks = self.stats.clicks + 1
    if not tonumber(x) or not tonumber(y) then
        self.stats.bad_coords = self.stats.bad_coords + 1
        return
    end
    x, y = math.floor(tonumber(x)), math.floor(tonumber(y))
    if button ~= 1 then
        self.stats.other_buttons = self.stats.other_buttons + 1
        return
    end
    -- The panel is drawn last and is therefore always on top.
    local panel = self:panel_layout()
    if in_rect(panel.activities, x, y) then self:toggle_overview() return end
    if in_rect(panel.status, x, y) then self:open("settings") return end
    -- Then the dock, in both modes: it is drawn over the overview as well.
    if self:dock_click(x, y) then return end
    if self.overview then
        local lay = self:overview_layout()
        for i, cell in ipairs(lay.cells) do
            if in_rect(cell, x, y) then
                self.select = i
                local entry = self.entries[cell.index]
                if entry then
                    self.overview = false
                    self:open(entry.id)
                end
                return
            end
        end
        return
    end
    -- Topmost window first: what is drawn on top is what gets the click.
    for i = #self.windows, 1, -1 do
        local win = self.windows[i]
        if in_rect(desktop.close_rect(win), x, y) then
            self:close_window(win)
            return
        end
        if in_rect(desktop.title_rect(win), x, y) then
            self:focus_window(win)
            self.drag = { win = win, last_x = x, last_y = y }
            return
        end
        if in_rect(desktop.window_rect(win), x, y) then
            self:focus_window(win)
            self:app_call(win, "event", { "mouse_click", button, x, y })
            return
        end
    end
    self.focus = nil            -- a click on the wallpaper takes the focus away
end

function Desktop:on_drag(button, x, y)
    self.stats.drags = self.stats.drags + 1
    if not self.drag then return end
    if not tonumber(x) or not tonumber(y) then
        self.stats.bad_coords = self.stats.bad_coords + 1
        return
    end
    if button ~= 1 then return end
    x, y = math.floor(tonumber(x)), math.floor(tonumber(y))
    local win = self.drag.win
    local dx, dy = x - self.drag.last_x, y - self.drag.last_y
    self.drag.last_x, self.drag.last_y = x, y
    self:move_window(win, win.x + dx, win.y + dy)
end

function Desktop:on_key(key)
    self.stats.keys = self.stats.keys + 1
    key = tonumber(key)
    if not key then
        self.stats.malformed = self.stats.malformed + 1
        return
    end
    if key == KEYS.o then
        self:toggle_overview()
        return
    end
    if key == KEYS.f10 then
        -- One "back out" key, three depths: leave the overview, then close the
        -- focused window, then leave the desktop. F10 is letterless and the
        -- machine really delivers it; Escape cannot be this key on Minecraft,
        -- which keeps it for its own menu and never sends it to the computer
        -- (lib/bios.lua's menus learned the same lesson), so a desktop keyed to
        -- Escape could not be left at all.
        if self.overview then
            self.overview = false
        elseif self.focus then
            self:close_window(self.focus)
        else
            self:quit("f10")
        end
        return
    end
    if key == KEYS.tab then
        if self.overview then
            self:select_next(1)
        elseif #self.windows > 1 then
            self:focus_window(self.windows[1])
        end
        return
    end
    if key == KEYS.enter and self.overview then
        local entry = self.entries[self.select]
        self.overview = false
        if entry then self:open(entry.id) end
        return
    end
    if self.focus then
        self:app_call(self.focus, "event", { "key", key })
    end
end

function Desktop:on_char(ch)
    if self.focus then
        self:app_call(self.focus, "event", { "char", ch })
    end
end

local function dispatch(d, ev)
    local name = type(ev) == "table" and ev[1] or nil
    if type(name) ~= "string" then
        d.stats.malformed = d.stats.malformed + 1
        return
    end
    if name == "mouse_click" then
        d:on_click(ev[2], ev[3], ev[4])
    elseif name == "mouse_up" then
        d.drag = nil
    elseif name == "mouse_move" then
        -- A move is offered to the focused window's application, because where
        -- the pointer is is the application's business: the calculator lights the
        -- key under it, everything else ignores the event. It is not a drag -- the
        -- drag path only runs while a button is held -- and it does not move the
        -- focus the way a click does.
        d.stats.moves = d.stats.moves + 1
        if d.focus then
            d:app_call(d.focus, "event", { "mouse_move", ev[2], ev[3], ev[4] })
        end
    elseif name == "mouse_drag" then
        d:on_drag(ev[2], ev[3], ev[4])
    elseif name == "mouse_scroll" then
        -- Deliberately ignored: nothing in a text grid scrolls yet, and a wheel
        -- event must not move the focus or the active window.
        d.stats.scrolls = d.stats.scrolls + 1
    elseif name == "key" then
        d:on_key(ev[2])
    elseif name == "char" then
        d:on_char(ev[2])
    elseif name == "term_resize" then
        d:resize()
    else
        d.stats.unknown = d.stats.unknown + 1
        d.last_unknown = name
    end
end

-- One event in, one frame out. Nothing here may raise: a raise would end the
-- interactive loop and hand the operator a traceback instead of a desktop.
--
-- The order is the point of the layer: an overlay is offered the event first
-- (topmost first, because that is what the operator can see), the desktop sees it
-- only if no overlay consumed it, and afterwards whatever task was waiting for an
-- event is resumed. A tick is not an event -- it moves the clock and runs the
-- tasks, and it is the desktop's before any overlay's, so a modal cannot starve
-- the scheduler by swallowing time.
function Desktop:tick(dt)
    self:advance(dt)
    self:draw()
    return self
end

function Desktop:handle(ev)
    local name = type(ev) == "table" and ev[1] or nil
    if name == "tick" then return self:tick(ev[2]) end
    self.stats.events = self.stats.events + 1
    -- A pumped program comes first: it is a window's own reader, and the event it
    -- is waiting for is not the desktop's. pump_offer picks exactly ONE program
    -- (the focused window's first, then registration order -- see the pump
    -- section); what it did not ask for -- a click, or a key while another window
    -- has the focus -- falls through to the desktop exactly as before.
    local pumped = self:pump_offer(ev)
    local ok, err = pcall(function()
        if pumped and self:pump_deliver(ev, pumped) then return end
        if not self:overlay_event(ev) then dispatch(self, ev) end
    end)
    if not ok then
        self.stats.errors = self.stats.errors + 1
        self.last_error = tostring(err)
    end
    self:poke_tasks()
    self:draw()
    return self
end

-- --------------------------------------------------------------------- draw
--
-- The wallpaper is Ubuntu's purple to orange sweep. On a terminal that can
-- redefine colour slots it is one of the six real RGB stops of WALLPAPER_STOPS per
-- row; otherwise it is the sixteen colour bands of WALLPAPER, still mixed two at a
-- time (the fallback cannot do better). It is painted in every mode, because it is
-- the desktop itself and not a decoration of the empty state; the words on it are
-- for the empty state only, and only the workspace is theirs to write in.

-- Redefine the six slots, once per run. Answers true when the sweep that gets
-- drawn is the real one. A screen with no palette -- a build without
-- setPaletteColour, or a terminal that refuses the call -- leaves this false and
-- the sixteen colour fallback is drawn instead of nothing.
function Desktop:install_palette()
    if self.palette_ready then return self.wallpaper_palette == true end
    self.palette_ready = true
    local s = self.screen
    local ok = type(s) == "table" and type(s.set_palette) == "function"
    if ok then
        for _, stop in ipairs(desktop.WALLPAPER_STOPS) do
            local rgb = stop.rgb
            if not s.set_palette(stop.colour, rgb[1], rgb[2], rgb[3]) then
                ok = false
                break
            end
        end
    end
    self.wallpaper_palette = ok
    if ok then self.stats.palette_sets = self.stats.palette_sets + 1 end
    return ok
end

-- Put the slots back. Called when the desktop is left, and around a handover:
-- the palette belongs to the terminal, so leaving it changed would recolour the
-- shell (and anything else) that runs after us.
function Desktop:restore_palette()
    if not self.palette_ready then return false end
    self.palette_ready = false
    local was = self.wallpaper_palette
    self.wallpaper_palette = false
    if was and type(self.screen) == "table" and
       type(self.screen.restore_palette) == "function" then
        self.screen.restore_palette()
        self.stats.palette_restores = self.stats.palette_restores + 1
    end
    return was == true
end

-- The colour of one wallpaper row: the stop it is nearest to. The wallpaper's own
-- words are drawn on this, so they sit on the row's colour and not on a
-- neighbour's.
function Desktop:wallpaper_row_colour(y)
    if self.wallpaper_palette then
        return (desktop.wallpaper_stop(self.h, y))
    end
    return (desktop.wallpaper_band(self.h, y))
end

function Desktop:draw_wallpaper()
    local s = self.screen
    if self.wallpaper_palette then
        -- One redefined slot per row, and no dithering. Six RGB points over
        -- nineteen rows is three to four rows per stop, and neighbours differ by
        -- about 0.14 per channel instead of the 0.4 of two ROM colours, so the
        -- step is a sweep. Mixing the neighbours cell by cell was tried (1.7.5)
        -- and the owner could still see the 4x2 checkerboard: on a 51x19 screen a
        -- cell is a big block, so any per-cell alternation is a pattern, not
        -- grain. Straight rows are the honest shape.
        for y = 1, self.h do
            s.fill(1, y, self.w, y, " ", self.palette.wallpaper_fg,
                   self:wallpaper_row_colour(y))
        end
        return
    end
    local n = #desktop.WALLPAPER
    for y = 1, self.h do
        local t = desktop.wallpaper_band_at(self.h, y)
        local i = math.floor(t)
        if i < 1 then i = 1 end
        if i > n - 1 then i = n - 1 end
        local a = desktop.WALLPAPER[i]
        local b = desktop.WALLPAPER[i + 1] or a
        local f = t - i                       -- 0..1, how far toward b
        -- The fallback: the same one-cell 4x2 Bayer mix, between ROM colours that
        -- are far apart. It is a banded gradient, which is all sixteen colours can
        -- honestly say, and it is why the redefined slots above exist.
        local bayer = BAYER[(y % 2) + 1]
        local lit = math.floor(f * 16)
        for x = 1, self.w do
            local col = (bayer[((x - 1) % 4) + 1] < lit) and b or a
            s.cell(x, y, " ", self.palette.wallpaper_fg, col)
        end
    end
end

function Desktop:draw_wallpaper_text()
    local p = self.palette
    local work = self:work_rect()
    -- The background says what the machine DOES (the one shortcut that opens the
    -- overview); it does not say what the software is called. The product name
    -- was never part of the desktop's job, and the owner asked for it to be gone.
    local hint = "press o for the overview"
    local y = math.max(work.y + 1, math.floor(self.h / 2) - 1)
    if y <= work.y + work.h - 1 then
        local hint_x = work.x + centre(work.w, hint) - 1
        if hint_x < work.x then hint_x = work.x end
        -- The hint is read on a coloured band, and gray on purple is hard to see:
        -- it uses the wallpaper's own foreground (white), the one colour the
        -- desktop already knows is legible on every band.
        self.screen.text(hint_x, y, hint, p.wallpaper_fg, self:wallpaper_row_colour(y))
    end
end

-- Paint a failure over the interior. Used both when the window already carries an
-- error before the frame and when the app raises WHILE drawing this frame: the
-- second case used to leave a half drawn window and only show the message on the
-- next event, which on a desktop that may then sit idle is not good enough. The
-- message is split on its line breaks, because a Lua require error is multi-line
-- and a newline written into a cell is not a line break.
--
-- Every cell it writes is inside body_rect: body.w and body.h are clamped at 0, a
-- zero-height interior draws nothing, and each line is cut to body.w. That is the
-- point -- an app that raises must not be the one that paints outside its window.
function Desktop:paint_error(body, text)
    local p = self.palette
    if body.w <= 0 or body.h <= 0 then return end
    self.screen.fill(body.x, body.y, body.x + body.w - 1, body.y + body.h - 1,
                     " ", p.error_fg, p.error_bg)
    local row = 0
    for line in (tostring(text) .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        row = row + 1
        if row > body.h then break end
        self.screen.text(body.x, body.y + row - 1, line:sub(1, body.w),
                         p.error_fg, p.error_bg)
    end
end

-- The chrome is drawn BEFORE the app body, and every cell of it is inside the
-- window's own rectangle: the title bar is a fill from x to x+w-1, the title text
-- is cut to the room the close control leaves, "[x]" is only placed when
-- close_rect found room for it (w >= 6), and the bottom border is cut to win.w so
-- a window narrower than three cells cannot draw its right end over the next cell
-- of the desktop. A window with no cells at all draws nothing.
function Desktop:draw_window(win)
    local s, p = self.screen, self.palette
    if not win or win.w < 1 or win.h < 1 then return end
    local focused = (self.focus == win)
    local title_fg = focused and p.title_fg or p.title_off_fg
    local title_bg = focused and p.title_bg or p.title_off_bg
    local right = win.x + win.w - 1
    local bottom = win.y + win.h - 1
    s.fill(win.x, win.y, right, win.y, " ", title_fg, title_bg)
    -- The accent cell: one orange cell at the left of the focused window's title
    -- bar. An unfocused window gets the plain title colour there, so the mark is
    -- a state and not a decoration. Everything at the left of the title starts
    -- one cell further in because of it.
    if focused then
        s.cell(win.x, win.y, " ", p.mark_fg, p.mark_bg)
    else
        s.cell(win.x, win.y, " ", p.mark_off_fg, p.mark_off_bg)
    end
    local close = desktop.close_rect(win)
    local text_x = win.x + 2
    local limit = close and (close.x - 2) or right
    local room = limit - text_x + 1
    if room > 0 then
        s.text(text_x, win.y, win.title:sub(1, room), title_fg, title_bg)
    end
    if close then s.text(close.x, close.y, "[x]", title_fg, title_bg) end
    if win.h >= 3 then
        for y = win.y + 1, bottom - 1 do
            s.cell(win.x, y, "|", p.border_fg, p.body_bg)
            s.cell(right, y, "|", p.border_fg, p.body_bg)
        end
        local body = desktop.body_rect(win)
        if body.w > 0 and body.h > 0 then
            s.fill(body.x, body.y, body.x + body.w - 1, body.y + body.h - 1,
                   " ", p.body_fg, p.body_bg)
        end
        s.text(win.x, bottom, ("+" .. ("-"):rep(math.max(0, win.w - 2)) .. "+")
                     :sub(1, math.max(0, win.w)),
               p.border_fg, p.body_bg)
        local entry = self.by_id[win.id]
        if win.error then
            self:paint_error(body, "app error: " .. tostring(win.error))
        elseif entry and entry.error then
            -- The app's module never loaded (a missing file, a half finished
            -- install): name the module, because that is what has to be fixed.
            self:paint_error(body, "this app is not available\n" ..
                             tostring(entry.module) .. ": " .. tostring(entry.error))
        else
            self:app_call(win, "draw")
            if win.error then
                self:paint_error(body, "app error: " .. tostring(win.error))
            end
        end
    end
end

function Desktop:draw_overview()
    local s, p = self.screen, self.palette
    local lay = self:overview_layout()
    local work = lay.work or self:work_rect()
    -- The overview covers the workspace and nothing else: Ubuntu's overview
    -- keeps its dock and its panel, and so does this one.
    s.fill(work.x, work.y, work.x + work.w - 1, work.y + work.h - 1, " ",
           p.overview_fg, p.overview_bg)
    s.text(lay.title.x, lay.title.y, lay.title.text, p.overview_fg, p.overview_bg)
    for i, cell in ipairs(lay.cells) do
        local entry = self.entries[cell.index]
        if entry then
            local selected = (i == self.select)
            -- The selected card is the accent: an orange background with the
            -- text in black. That is the whole of "this is the one you would
            -- open", and it is one colour a dump can assert.
            local fg = selected and p.card_sel_fg or p.card_fg
            local bg = selected and p.card_sel_bg or p.card_bg
            s.fill(cell.x, cell.y, cell.x + cell.w - 1, cell.y + cell.h - 1, " ", fg, bg)
            local icon = entry.icon or "???"
            local iy = cell.y + math.max(0, math.floor((cell.h - 2) / 2))
            -- centre() answers a 1-based column inside the card, so the card's own
            -- first column is added and then one taken back.
            s.text(cell.x + centre(cell.w, icon) - 1, iy, icon:sub(1, cell.w), fg, bg)
            local name = entry.name or entry.id
            if entry.error then name = name .. "!" end
            local ny = iy + 1
            if ny <= cell.y + cell.h - 1 then
                s.text(cell.x + centre(cell.w, name) - 1, ny, name:sub(1, cell.w), fg, bg)
            end
        end
    end
end

-- The dock: a near black column of favourite icons down the left edge, one gray
-- cell of separator to its right, and a running indicator under each icon. It is
-- drawn in the desktop AND in the overview (Ubuntu's is permanent), and after
-- every window, so no window can be drawn over it.
function Desktop:draw_dock()
    local s, p = self.screen, self.palette
    local lay = self:dock_layout()
    if lay.h <= 0 then return end
    local bottom = lay.y + lay.h - 1
    s.fill(lay.x, lay.y, lay.x + lay.w - 1, bottom, " ", p.dock_fg, p.dock_bg)
    for y = lay.y, bottom do
        s.cell(lay.sep_x, y, "|", p.dock_sep_fg, p.dock_sep_bg)
    end
    for _, item in ipairs(lay.items) do
        local running = self:app_running(item.id)
        s.text(item.x, item.y, item.text,
               running and p.dock_icon_on_fg or p.dock_fg, p.dock_bg)
        -- The indicator: the accent dot for an application with at least one
        -- window, a blank cell otherwise. One window or five, the dot is on.
        if running then
            s.cell(item.dot.x, item.dot.y, item.dot.text, p.dock_on_fg, p.dock_bg)
        else
            s.cell(item.dot.x, item.dot.y, " ", p.dock_off_fg, p.dock_bg)
        end
    end
end

function Desktop:draw_panel()
    local s, p = self.screen, self.palette
    local lay = self:panel_layout()
    s.fill(1, 1, self.w, 1, " ", p.panel_fg, p.panel_bg)
    local afg, abg = p.panel_fg, p.panel_bg
    if self.overview then afg, abg = p.accent_fg, p.accent_bg end
    s.text(lay.activities.x, lay.activities.y, lay.activities.text, afg, abg)
    s.text(lay.clock.x, lay.clock.y, lay.clock.text, p.clock_fg, p.clock_bg)
    s.text(lay.status.x, lay.status.y, lay.status.text, p.status_fg, p.status_bg)
end

-- One frame: wallpaper, the overview or the windows, then the dock, then the
-- panel. The order is the z order, and it is why the panel and the dock can never
-- be covered.
--
-- draw() never raises: a screen that lies about its size or refuses a write ends
-- up as a counter and a message, never as an error out of an event loop. The
-- re-entrancy guard is what an app calling api.open() from inside its own draw
-- would otherwise trip over.
function Desktop:draw()
    if self.drawing then return self end
    self.drawing = true
    local ok, err = pcall(Desktop.paint, self)
    self.drawing = nil
    if not ok then
        self.stats.errors = self.stats.errors + 1
        self.last_error = tostring(err)
    end
    return self
end

function Desktop:paint()
    -- The palette is set before the first cell is drawn, because the wallpaper's
    -- colour slots have to mean the new RGB by the time the frame is flushed.
    self:install_palette()
    local s = self.screen
    s.clear(self.palette.wallpaper_fg, self.palette.wallpaper_bg)
    -- The wallpaper is painted in every mode: it is the desktop, and the words on
    -- it are the empty state's. An empty desktop that showed no wallpaper while a
    -- window was up would flicker between two backgrounds.
    self:draw_wallpaper()
    if self.overview then
        self:draw_overview()
    else
        if #self.windows == 0 then self:draw_wallpaper_text() end
        for _, win in ipairs(self.windows) do self:draw_window(win) end
    end
    self:draw_dock()
    self:draw_panel()
    -- Last, so a modal can cover the panel too. Every window is painted before
    -- the panel, so an app could never have put anything above it on its own.
    self:draw_overlays()
    s.present()
    self.stats.presents = self.stats.presents + 1
end

-- ===========================================================================
-- drivers
-- ===========================================================================

-- Headless: a screen and a list of events, no terminal, no os.pullEvent. Returns
-- the screen it drew into and the desktop, in that order -- the screen is what
-- the caller came for (it is the only record of what was drawn).
function desktop.run(opts)
    opts = opts or {}
    local d = desktop.new(opts)
    d:resize()
    d:draw()
    local events = opts.events or {}
    local handled = 0
    for i = 1, #events do
        if d.exit then break end
        d:handle(events[i])
        handled = handled + 1
    end
    return d.screen, d
end

-- Interactive: the same desktop, fed by the machine's event queue. The terminal
-- is restored whatever happens, because the program that started this one -- the
-- shell -- has to get a usable screen back even if the desktop raised.
function desktop.run_interactive(opts)
    opts = opts or {}
    local d = desktop.new(opts)
    d:resize()
    d:draw()
    local ok, err = pcall(function()
        if type(term) == "table" then
            if term.setCursorBlink then term.setCursorBlink(false) end
            if term.setCursorPos then term.setCursorPos(1, 1) end
        end
        -- The desktop owns the clock, so it arms its own timer: a task that
        -- sleeps, or a window that redraws itself, makes progress while the
        -- operator does nothing. The desktop is the only thing reading the queue
        -- here, so a timer that is not ours is a tick as well.
        while not d.exit do
            d:reclaim_terminal()
            local ev = { os.pullEvent() }
            if ev[1] == "timer" then ev = { "tick" } end
            d:handle(ev)
            if not d.exit and type(os.startTimer) == "function" then
                local armed, id = pcall(os.startTimer, d.step)
                if armed then d.timer = id end
            end
        end
    end)
    -- Whatever ended the loop -- a quit, an interrupt that raised "Terminated", a
    -- screen that failed -- the wallpaper's colour slots must not outlive the
    -- desktop: the next program on this terminal is usually the shell.
    d:restore_palette()
    if type(term) == "table" then
        if term.setBackgroundColour then term.setBackgroundColour(C.black) end
        if term.setTextColour then term.setTextColour(C.white) end
        if term.clear then term.clear() end
        if term.setCursorBlink then term.setCursorBlink(true) end
        if term.setCursorPos then term.setCursorPos(1, 1) end
    end
    if not ok then return nil, tostring(err) end
    return d
end

-- ===========================================================================
-- landing: where the operator is left when the desktop is gone
-- ===========================================================================
--
-- "Leaving the desktop" must not leave the machine outside its own system. The
-- desktop can be started three ways, and only two of them end at a shell prompt
-- by themselves:
--
--   * from a psh session (`desktop` at the prompt, or as the session command,
--     which psh runs) -- returning to the caller IS the psh prompt, so starting
--     another shell here would nest a shell inside a shell;
--   * from a boot script that runs this module directly, or from the CraftOS
--     shell -- returning to the caller is a bare CraftOS prompt, or the end of
--     the boot script, and the operator is outside the machine's system.
--
-- psh marks every command chunk it runs with __psh_command (usr/psh.lua), and
-- that mark is how the two cases are told apart without guessing about the
-- caller. A caller that is not the shell gets the shell started for it.
--
-- opts.in_shell    true when this desktop IS a command of the running shell
-- opts.run_shell   function that starts the shell and answers true when it ran
-- Returns one of:
--   "caller"        returned to the caller, which is the shell -- nothing done
--   "shell"         the shell was started, so the operator is back at psh
--   "shell-failed"  the shell could not be started; the caller should say so
-- Is this terminal something other than the machine's own screen? The command
-- asks before it starts: since 1.6.0 the Terminal and the Console run the project's
-- shell INSIDE a window, and `desktop` typed at that prompt would start a second
-- desktop inside that window -- its windows would be drawn into an invisible window
-- of the outer desktop, two pumps would fight over one event stream, and there is
-- no way back the operator can see. So the desktop runs on the machine's own screen
-- or not at all; a terminal object that is not `term.native()` (a window, a monitor)
-- is refused, with the reason, by the command.
--
-- HOW IT TELLS THEM APART. Not by identity: measured on CraftOS-PC 2.8.3,
-- term.current() is NOT term.native() even on the machine's own screen (they are
-- different tables), so comparing them refused the desktop everywhere -- the boot
-- path caught it immediately. The fact that does hold is getLine: the machine's own
-- terminal has no getLine (nil on both term.native() and term.current() when that
-- is the screen -- measured), while every window created by window.create has one.
-- A terminal that can answer getLine is a window, and the desktop does not start
-- there. A machine where nothing answers getLine is allowed: a wrong refusal would
-- make the desktop unreachable.
function desktop.needs_whole_screen(t)
    if type(t) ~= "table" then return false end
    return type(t.getLine) == "function"
end

function desktop.landing(opts)
    opts = opts or {}
    if opts.in_shell then return "caller" end
    if type(opts.run_shell) ~= "function" then return "shell-failed" end
    local ok, ran = pcall(opts.run_shell)
    if ok and ran then return "shell" end
    return "shell-failed"
end

-- ===========================================================================
-- the headless script format and the screen dump
-- ===========================================================================
--
-- One event per line, as the event's own name followed by its arguments:
--
--   mouse_click 1 12 3        key 28        term_resize        nonsense 4
--
-- The parser is deliberately dumb, and deliberately here: a malformed line is
-- part of what has to be survivable, so "nonsense 4" becomes the unknown event
-- {"nonsense", 4} rather than an error, exactly what an unknown ROM event is.
function desktop.parse_events(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local body = line:gsub("#.*$", "")
        body = body:gsub("^%s+", ""):gsub("%s+$", "")
        if body ~= "" then
            local ev = {}
            for token in body:gmatch("%S+") do
                ev[#ev + 1] = tonumber(token) or token
            end
            out[#out + 1] = ev
        end
    end
    return out
end

local function colour_letter(c)
    if c == nil then return "." end
    if colors and colors.toBlit then return colors.toBlit(c) end
    return string.format("%x", math.floor(tonumber(c) or 0) % 16)
end

-- Everything an assertion could want to know about a finished run, as text: every
-- row of characters, every row of foreground and background letters (the same
-- alphabet term.blit uses), the windows and their geometry, and the counters.
function desktop.dump(screenobj, d)
    local out = {}
    local w, h = screenobj.size()
    out[#out + 1] = string.format("SIZE %d %d", w, h)
    for y = 1, h do out[#out + 1] = string.format("ROW %d %s", y, screenobj.row(y)) end
    for y = 1, h do
        local fg, bg = {}, {}
        for x = 1, w do
            fg[x] = colour_letter(screenobj.fg(x, y))
            bg[x] = colour_letter(screenobj.bg(x, y))
        end
        out[#out + 1] = string.format("FG %d %s", y, table.concat(fg))
        out[#out + 1] = string.format("BG %d %s", y, table.concat(bg))
    end
    if d then
        local dock_ids = {}
        for _, item in ipairs(d:dock_layout().items) do dock_ids[#dock_ids + 1] = tostring(item.id) end
        local win_ids = {}
        for _, win in ipairs(d.windows) do win_ids[#win_ids + 1] = tostring(win.id) end
        local work = d:work_rect()
        out[#out + 1] = string.format("MODE %s", d.overview and "overview" or "desktop")
        out[#out + 1] = string.format("DOCK %s", table.concat(dock_ids, ","))
        out[#out + 1] = string.format("DOCKW %d", d.dock_w)
        out[#out + 1] = string.format("WORK x=%d y=%d w=%d h=%d", work.x, work.y, work.w, work.h)
        out[#out + 1] = string.format("WINDOWS %d", #d.windows)
        for i, win in ipairs(d.windows) do
            out[#out + 1] = string.format(
                "WINDOW %d id=%s title=%s x=%d y=%d w=%d h=%d focus=%s error=%s",
                i, tostring(win.id), tostring(win.title), win.x, win.y, win.w, win.h,
                tostring(d.focus == win), tostring(win.error))
            if win.last_result ~= nil then
                out[#out + 1] = string.format("SESSION %d result=%s", i, tostring(win.last_result))
            end
        end
        out[#out + 1] = string.format("FOCUS %s", d.focus and tostring(d.focus.id) or "none")
        out[#out + 1] = string.format("ORDER %s", table.concat(win_ids, ","))
        out[#out + 1] = string.format("EXIT %s reason=%s", tostring(d.exit), tostring(d.exit_reason))
        -- The scheduler and the overlays, in the dump because both are state a
        -- reader cannot see in the cells: which tasks are running, how often each
        -- was resumed, what is on top, and whether an overlay ate an event.
        out[#out + 1] = string.format("CLOCK now=%.3f step=%.3f ticks=%d", d.now, d.step,
                                      d.stats.ticks)
        out[#out + 1] = string.format("TASKS %d started=%d finished=%d errors=%d resumes=%d",
                                      #d.tasks, d.stats.tasks_started, d.stats.tasks_finished,
                                      d.stats.task_errors, d.stats.resumes)
        for i, t in ipairs(d.tasks) do
            out[#out + 1] = string.format(
                "TASK %d name=%s status=%s resumes=%d win=%s error=%s", i, t.name, t.status,
                t.resumes, t.window and tostring(t.window.id) or "none", tostring(t.error))
        end
        out[#out + 1] = string.format(
            "OVERLAYS %d opened=%d closed=%d eaten=%d errors=%d draws=%d",
            #d.overlays, d.stats.overlays_opened, d.stats.overlays_closed,
            d.stats.overlay_events, d.stats.overlay_errors, d.stats.overlay_draws)
        for i, ov in ipairs(d.overlays) do
            out[#out + 1] = string.format("OVERLAY %d name=%s win=%s", i, ov.name,
                                          ov.window and tostring(ov.window.id) or "none")
        end
        -- The pump registry: how many programs are being pumped right now, in
        -- registration order, and for each its task, window, terminal and event
        -- count. A reader can therefore tell two consoles apart in a dump.
        local waiting = 0
        for _, ps in ipairs(d.pumps) do
            if ps.waiting then waiting = waiting + 1 end
        end
        out[#out + 1] = string.format("PUMPS %d active=%d wraps=%d peak=%d",
                                      #d.pumps, waiting, d.stats.pump_wraps,
                                      d.stats.pumps_peak)
        for i, ps in ipairs(d.pumps) do
            out[#out + 1] = string.format(
                "PUMP %d active=%s task=%s window=%s events=%d term=%s",
                i, tostring(ps.waiting == true),
                tostring(ps.task and ps.task.name or "none"),
                tostring(ps.window and ps.window.id or "none"), ps.events,
                tostring(ps.term ~= nil))
        end
        out[#out + 1] = string.format(
            "STATS events=%d clicks=%d keys=%d drags=%d scrolls=%d unknown=%d malformed=%d " ..
            "bad_coords=%d other_buttons=%d opened=%d closed=%d app_errors=%d errors=%d " ..
            "handovers=%d handover_ok=%d presents=%d ticks=%d tasks_started=%d " ..
            "tasks_finished=%d task_errors=%d resumes=%d overlays_opened=%d " ..
            "overlays_closed=%d overlay_events=%d overlay_errors=%d overlay_draws=%d " ..
            "pumps=%d pumped_events=%d pump_errors=%d reclaims=%d " ..
            "pump_wraps=%d pumps_peak=%d term_asserts=%d clipped=%d moves=%d " ..
            "palette_sets=%d palette_restores=%d",
            d.stats.events, d.stats.clicks, d.stats.keys, d.stats.drags, d.stats.scrolls,
            d.stats.unknown, d.stats.malformed, d.stats.bad_coords, d.stats.other_buttons,
            d.stats.opened, d.stats.closed, d.stats.app_errors, d.stats.errors,
            d.stats.handovers, d.stats.handover_ok, d.stats.presents,
            d.stats.ticks, d.stats.tasks_started, d.stats.tasks_finished, d.stats.task_errors,
            d.stats.resumes, d.stats.overlays_opened, d.stats.overlays_closed,
            d.stats.overlay_events, d.stats.overlay_errors, d.stats.overlay_draws,
            d.stats.pumps, d.stats.pumped_events, d.stats.pump_errors, d.stats.reclaims,
            d.stats.pump_wraps, d.stats.pumps_peak, d.stats.term_asserts,
            d.stats.clipped, d.stats.moves,
            d.stats.palette_sets, d.stats.palette_restores)
        out[#out + 1] = string.format("LAST_ERROR %s", tostring(d.last_error))
        out[#out + 1] = string.format("LAST_UNKNOWN %s", tostring(d.last_unknown))
        if d.last_handover then
            out[#out + 1] = string.format("HANDOVER ok=%s path=%s result=%s error=%s",
                tostring(d.last_handover.ok), tostring(d.last_handover.path),
                tostring(d.last_handover.result), tostring(d.last_handover.error))
        end
    end
    return table.concat(out, "\n")
end

return desktop
