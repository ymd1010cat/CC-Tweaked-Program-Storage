-- gnome.apps.settings - the machine's settings panel.
--
-- WHAT THIS WINDOW IS: sections of key/value rows, because that is what a
-- settings panel looks like -- a title, then what the machine is, what its
-- storage is doing, and what this package is. The rows are built from live data
-- every frame (hostname, the session's user, the storage bar, the package count),
-- and the two actions at the bottom really do something: the panel colour is a
-- real change of the desktop's own palette, and log out leaves the desktop the
-- way pressing F10 with nothing left open does.
--
-- THE SHAPE IS DATA. Every field is an entry in one list; the layout packs the
-- list into rows. A body wide enough for a second column shows the two halves of
-- a section side by side; a narrower body stacks them and scrolls with the arrow
-- keys, so a 12 column body still reads and every field stays reachable. Drawing
-- and hit testing ask the same layout, so the row an operator clicks is the row
-- the operator read.
--
-- The storage numbers come from fs.getCapacity/getFreeSpace (pcall'd: a machine
-- without a filesystem gets "?" rather than a traceback) and go through
-- gnome.fmt.bytes, which is the one place in this package that knows the
-- kilobyte. So does the shell's version: this package's modules may require
-- nothing but the package's own modules, and the shell has no version module at
-- all -- its version is the banner line near the bottom of its own source, which
-- is read once per window and reported as "?" when it cannot be read.
local fmt = require("gnome.fmt")

local settings = {}

-- What this package is when the installed manifest cannot be asked (the host
-- suite runs from the source tree, where no package is installed). Kept in step
-- with tools/pkgs/gnome/manifest by the suite, which reads the manifest.
settings.VERSION = "1.8.5"

local INDENT = 2         -- key/value rows are indented under their section title
local LABEL_W = 9        -- the label field, so every value starts in one column
local COL2 = 18          -- the second column of a wide body
-- The second column needs its whole value field: 18 + 2 + 9 + 8 - 1 = 36 cells.
local WIDE_MIN = COL2 + INDENT + LABEL_W + 8 - 1
settings.WIDE_MIN = WIDE_MIN
settings.COL2 = COL2
settings.LABEL_W = LABEL_W

-- Per window state, filled in one field at a time: an empty state table arrives
-- with the window, and "win.state or {...}" alone would leave the scroll nil.
-- Nothing here is module level, so two settings windows scroll independently.
local function state(win)
    win.state = win.state or {}
    if win.state.scroll == nil then win.state.scroll = 0 end
    return win.state
end

settings.state = state

-- ---------------------------------------------------------------- the machine
local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

settings.PSH_BANNER = "psh%s+(%d+%.%d+)"

-- The tail of a text file. The shell's version is a string in a 300 KB source
-- file; reading the file to find one line would be the wrong shape for a window
-- that redraws, so the tail is asked for instead (CraftOS file handles seek).
local function read_tail(path, limit)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then return nil end
    local ok, handle = pcall(fs.open, path, "r")
    if not ok or type(handle) ~= "table" then return nil end
    if type(handle.seek) == "function" then
        local ok_end, size = pcall(handle.seek, "end")
        if ok_end and tonumber(size) then
            pcall(handle.seek, "set", math.max(0, math.floor(tonumber(size)) - limit))
        end
    end
    local ok_read, text = pcall(handle.read, limit)
    if type(handle.close) == "function" then pcall(handle.close) end
    if ok_read and type(text) == "string" then return text end
    return nil
end

function settings.psh_version()
    for _, path in ipairs({ "/usr/psh.lua", "/lib/psh.lua" }) do
        local text = read_tail(path, 8192)
        if text then
            local version = text:match(settings.PSH_BANNER)
            if version then return version end
        end
    end
    return "?"
end

local function hostname()
    if type(os) ~= "table" then return "?" end
    local label = safe(os.getComputerLabel)
    if label ~= nil and tostring(label) ~= "" then return tostring(label) end
    local id = safe(os.getComputerID)
    if id ~= nil then return "cc-" .. tostring(id) end
    return "?"
end

local function current_user()
    local ok, perm = pcall(require, "perm")
    if not ok or type(perm) ~= "table" then return "?" end
    local name = safe(perm.get_current_user)
    if name == nil then return "?" end
    return tostring(name)
end

local function storage(path)
    local capacity, free = nil, nil
    if type(fs) == "table" then
        capacity = safe(fs.getCapacity, path)
        free = safe(fs.getFreeSpace, path)
    end
    capacity, free = tonumber(capacity), tonumber(free)
    local used = nil
    if capacity and free then used = math.max(0, capacity - free) end
    return capacity, free, used
end

local function package_count()
    local ok, pkg = pcall(require, "pkg")
    if not ok or type(pkg) ~= "table" then return nil end
    local list = safe(pkg.list)
    if type(list) ~= "table" then return nil end
    return #list
end

-- This package's version: the INSTALLED manifest when the package manager can
-- read one (which is the same file pkgserver publishes), and the constant above
-- when it cannot. pkg.installed_version is not used because it answers "0" for a
-- package that is not installed, and "gnome 0" is not a version an operator would
-- read as "not installed".
local function package_version()
    local ok, pkg = pcall(require, "pkg")
    if ok and type(pkg) == "table" then
        local manifest = safe(pkg.read_manifest, "gnome")
        if type(manifest) == "table" and type(manifest.version) == "string" and
           manifest.version ~= "" then
            return manifest.version
        end
    end
    return settings.VERSION
end

-- Everything the panel shows, gathered once per frame (or once per assertion).
function settings.info(api, win)
    local d = api.desktop
    local info = {}
    info.hostname = hostname()
    info.user = current_user()
    info.screen = tostring(d.w) .. "x" .. tostring(d.h)
    info.clock = tostring(safe(d.clock_text, d) or "--:--")
    info.total, info.free, info.used = storage("/")
    info.packages = package_count()
    info.version = package_version()
    if win ~= nil then
        win.state = win.state or {}
        if win.state.psh_version == nil then win.state.psh_version = settings.psh_version() end
        info.psh = win.state.psh_version
    else
        info.psh = settings.psh_version()
    end
    return info
end

-- ------------------------------------------------------------------ the fields
-- One list, in reading order. The layout below decides where each one goes; on a
-- wide body two key/value entries share a row, on a narrow one every entry has a
-- row of its own and the panel scrolls.
function settings.entries(api, win)
    local info = settings.info(api, win)
    local d = api.desktop
    local packages = info.packages
    if packages == nil then packages = "no pkg module" else packages = tostring(packages) .. " installed" end
    return {
        { kind = "section", text = "System" },
        { kind = "kv", label = "hostname", value = info.hostname },
        { kind = "kv", label = "user", value = info.user },
        { kind = "kv", label = "screen", value = info.screen },
        { kind = "kv", label = "clock", value = info.clock },
        { kind = "section", text = "Storage" },
        { kind = "kv", label = "total", value = fmt.bytes(info.total) },
        { kind = "kv", label = "free", value = fmt.bytes(info.free) },
        { kind = "bar", used = info.used, total = info.total },
        { kind = "kv", label = "packages", value = packages },
        { kind = "section", text = "About" },
        { kind = "kv", label = "gnome", value = info.version },
        { kind = "kv", label = "psh", value = info.psh },
        { kind = "action", action = "panel",
          label = "panel: " .. ((d.panel_dark and "black") or "gray") },
        { kind = "action", action = "quit", label = "log out" },
    }
end

-- ------------------------------------------------------------------ the layout
-- rows, in body relative cells. A row holds one entry that spans it (a section
-- title, the storage bar) or up to two entries side by side. `scroll` is the
-- index of the first row shown; it is clamped here, so no caller can scroll past
-- the last page.
function settings.layout(w, h, entries, scroll)
    w = math.max(0, math.floor(tonumber(w) or 0))
    h = math.max(0, math.floor(tonumber(h) or 0))
    local wide = w >= WIDE_MIN
    local rows = {}
    local function new_row()
        local row = { parts = {} }
        rows[#rows + 1] = row
        return row
    end
    for _, entry in ipairs(entries or {}) do
        if wide and (entry.kind == "kv" or entry.kind == "action") then
            local row = rows[#rows]
            if not row or row.span or row.full then row = new_row() end
            row.parts[#row.parts + 1] = entry
            if #row.parts >= 2 then row.full = true end
        else
            local row = new_row()
            row.span = true
            row.parts[1] = entry
        end
    end
    local max_scroll = math.max(0, #rows - h)
    local start = math.floor(tonumber(scroll) or 0)
    if start < 0 then start = 0 end
    if start > max_scroll then start = max_scroll end
    local visible = {}
    for i = 1, math.min(h, #rows - start) do visible[i] = rows[start + i] end
    return { rows = rows, visible = visible, wide = wide, scroll = start,
             max_scroll = max_scroll, width = w, height = h }
end

-- ------------------------------------------------------------------- drawing
local function part_text(part)
    if part.kind == "section" then return part.text end
    if part.kind == "kv" then return (" "):rep(INDENT) .. fmt.pad(part.label, LABEL_W) .. part.value end
    if part.kind == "action" then return "> " .. part.label end
    return ""
end

-- The storage bar: "[" then as many "#" as the percentage the line shows, then
-- "-" to the end and the percentage itself, right aligned to the body. The
-- filled part is counted FROM the printed percentage, so the bar and the number
-- cannot disagree -- the suite reads both off the screen and checks that, and
-- asks this function what the ends of the scale look like.
function settings.bar_fill(inner, used, total)
    inner = math.floor(tonumber(inner) or 0)
    if inner <= 0 then return 0 end
    used, total = tonumber(used), tonumber(total)
    if not used or not total or total <= 0 then return 0 end
    if used < 0 then used = 0 end
    -- The percentage the line prints, not the exact ratio: rounding twice in two
    -- places is how a bar and its label end up one cell apart.
    local shown = tonumber((fmt.percent(used, total)):match("^(%d+%.?%d*)"))
    if not shown then return 0 end
    local filled = math.floor(inner * shown / 100 + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner then filled = inner end
    return filled
end

local function draw_bar(api, row, entry, colours)
    local percent = fmt.percent(entry.used, entry.total)
    local tail = " " .. percent
    local room = api.w - #tail
    if room < 3 then
        api.write(1, row, fmt.fit(percent, api.w), colours.white)
        return 0
    end
    local inner = room - 2
    local filled = settings.bar_fill(inner, entry.used, entry.total)
    api.write(1, row, "[", colours.gray)
    if filled > 0 then api.write(2, row, ("#"):rep(filled), colours.cyan) end
    if inner - filled > 0 then
        api.write(2 + filled, row, ("-"):rep(inner - filled), colours.gray)
    end
    api.write(room, row, "]", colours.gray)
    api.write(room + 2, row, percent, colours.white)
    return filled
end

local function draw_part(api, row, col, zone, part, colours)
    if part.kind == "kv" then
        if zone < INDENT + LABEL_W + 2 then
            -- Too narrow for a column of values: "label: value" on one line, cut
            -- to the zone. The label stays readable, which is the point.
            api.write(col, row, fmt.fit(part.label .. ": " .. part.value, zone), colours.white)
            return
        end
        local label = (" "):rep(INDENT) .. fmt.pad(part.label, LABEL_W)
        api.write(col, row, fmt.fit(label, zone), colours.gray)
        local value_col = col + INDENT + LABEL_W
        api.write(value_col, row, fmt.fit(part.value, zone - (INDENT + LABEL_W)), colours.white)
        return
    end
    if part.kind == "section" then
        api.write(col, row, fmt.fit(part.text, zone), colours.white)
        return
    end
    if part.kind == "action" then
        api.write(col, row, fmt.fit("> " .. part.label, zone), colours.cyan)
    end
end

function settings.draw(api, win)
    local st = state(win)
    local entries = settings.entries(api, win)
    local lay = settings.layout(api.w, api.h, entries, st.scroll)
    st.scroll = lay.scroll
    local colours = api.colours
    for i, row in ipairs(lay.visible) do
        local first = row.parts[1]
        if first.kind == "bar" then
            draw_bar(api, i, first, colours)
        elseif lay.wide and row.parts[2] then
            -- Two zones: the first column keeps COL2-1 cells, the second the
            -- rest. Each side is cut to its own zone, so neither can run into
            -- the other, and neither can run out of the window (app_api would
            -- clip it anyway -- the suite asserts nothing is clipped).
            draw_part(api, i, 1, COL2 - 1, first, colours)
            draw_part(api, i, COL2, api.w - COL2 + 1, row.parts[2], colours)
        else
            draw_part(api, i, 1, api.w, first, colours)
        end
    end
end

-- -------------------------------------------------------------------- actions
function settings.press(api, entry)
    if type(entry) ~= "table" or entry.kind ~= "action" then return false end
    local d = api.desktop
    if entry.action == "panel" then
        d.panel_dark = not d.panel_dark
        d.palette.panel_bg = d.panel_dark and api.colours.black or api.colours.gray
        return true
    end
    if entry.action == "quit" then
        d:quit("logout")
        return true
    end
    return false
end

-- ---------------------------------------------------------------- interaction
function settings.event(api, win, ev)
    local st = state(win)
    if ev[1] == "key" then
        local key = tonumber(ev[2])
        local page = math.max(1, api.h - 1)
        local step = nil
        if key == 200 then step = -1
        elseif key == 208 then step = 1
        elseif key == 201 then step = -page
        elseif key == 209 then step = page
        end
        if step == nil then return false end
        local entries = settings.entries(api, win)
        st.scroll = settings.layout(api.w, api.h, entries, st.scroll + step).scroll
        return true
    end
    if ev[1] ~= "mouse_click" then return false end
    if not ev[3] or not ev[4] then return false end
    local row = tonumber(ev[4]) - api.body.y + 1
    local col = tonumber(ev[3]) - api.body.x + 1
    if not row or not col or row < 1 or col < 1 or row > api.h or col > api.w then return false end
    local lay = settings.layout(api.w, api.h, settings.entries(api, win), st.scroll)
    local hit = lay.visible[row]
    if not hit then return false end
    local part = hit.parts[1]
    if lay.wide and hit.parts[2] and col >= COL2 then part = hit.parts[2] end
    return settings.press(api, part)
end

return settings
