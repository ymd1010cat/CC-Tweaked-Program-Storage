-- gnome.apps.files - a file browser over the CraftOS filesystem.
--
-- The listing order IS the drawing order: directories first (a click can descend
-- into one), then files, each group sorted by name. Because one function
-- produces the rows that are both drawn and hit tested, the row a click lands on
-- is the row the operator read -- there is no second index to keep in step.
--
-- A file's size goes through gnome.fmt.bytes, the package's one kilobyte ladder:
-- "320239B" is a number only its author reads, and a browser that printed raw
-- bytes would disagree with the settings panel about what a megabyte looks like.
local fmt = require("gnome.fmt")

local files = {}

local function state(win)
    win.state = win.state or {}
    if not win.state.path then win.state.path = "/" end
    if not win.state.select then win.state.select = 1 end
    if not win.state.scroll then win.state.scroll = 0 end
    return win.state
end

local function join(path, name)
    if path == "/" then return "/" .. name end
    return path .. "/" .. name
end

local function parent(path)
    if path == "/" or path == "" then return "/" end
    local up = path:match("^(.*)/[^/]*$")
    if not up or up == "" then return "/" end
    return up
end
files.parent = parent

-- The entries of one directory, or nil plus a reason. Every filesystem call is
-- pcall'd: a directory that cannot be read is reported in the window, not raised
-- into the desktop's event loop.
function files.list(path)
    if type(fs) ~= "table" or type(fs.list) ~= "function" then
        return nil, "no filesystem on this machine"
    end
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then
        return nil, "cannot list " .. tostring(path)
    end
    local dirs, plain = {}, {}
    for _, name in ipairs(names) do
        local full = join(path, name)
        local isdir = false
        if type(fs.isDir) == "function" then isdir = fs.isDir(full) and true or false end
        local size = 0
        if not isdir and type(fs.getSize) == "function" then
            local oks, s = pcall(fs.getSize, full)
            if oks then size = tonumber(s) or 0 end
        end
        local entry = { name = name, dir = isdir, size = size, path = full }
        if isdir then dirs[#dirs + 1] = entry else plain[#plain + 1] = entry end
    end
    local function by_name(a, b) return a.name < b.name end
    table.sort(dirs, by_name)
    table.sort(plain, by_name)
    local out = {}
    for _, e in ipairs(dirs) do out[#out + 1] = e end
    for _, e in ipairs(plain) do out[#out + 1] = e end
    return out
end

-- The clickable rows: row 1 is "<..>" unless we are at the root, then the
-- listing. Each row carries the rect (inside the body) it occupies.
function files.rows(win)
    local st = state(win)
    local out = {}
    if st.path ~= "/" then out[#out + 1] = { up = true, text = "<..>" } end
    local entries, why = files.list(st.path)
    if not entries then
        out[#out + 1] = { error = why, text = tostring(why) }
        return out
    end
    for _, entry in ipairs(entries) do
        local label = entry.name
        if entry.dir then label = label .. "/" else label = label .. "  " .. fmt.bytes(entry.size) end
        out[#out + 1] = { entry = entry, text = label }
    end
    return out
end

-- The selected row index in files.rows(), clamped to what the listing has now. A
-- directory change can leave the old index past the end; clamping here means the
-- drawing, the keyboard and the operator always agree on one row.
function files.selection(win)
    local st = state(win)
    local rows = files.rows(win)
    local n = #rows
    if n < 1 then st.select = 0 return 0 end
    st.select = math.floor(tonumber(st.select) or 1)
    if st.select < 1 then st.select = 1 end
    if st.select > n then st.select = n end
    return st.select
end

-- The rows the window can show and the first of them. Row 1 is the path line and
-- the last row is the hint when everything fits, so the listing gets h-1 rows; a
-- listing that needs a scroll gives that row to the entries instead (the hint is
-- dropped, not drawn over an entry). Keeping the window's selection on screen is
-- this function's job, so the keyboard cannot scroll the selection out of view.
function files.visible(win, h)
    local st = state(win)
    local rows = files.rows(win)
    local view = math.max(0, (tonumber(h) or 0) - 1)
    local sel = files.selection(win)
    if view < 1 then return rows, 0, 0 end
    local maxscroll = math.max(0, #rows - view)
    if sel - 1 < st.scroll then st.scroll = sel - 1 end
    if sel - 1 >= st.scroll + view then st.scroll = sel - 1 - view + 1 end
    if st.scroll > maxscroll then st.scroll = maxscroll end
    if st.scroll < 0 then st.scroll = 0 end
    return rows, view, st.scroll
end

function files.draw(api, win)
    local st = state(win)
    local rows, view, scroll = files.visible(win, api.h)
    local sel = files.selection(win)
    api.write(1, 1, st.path)
    -- When there is more than a windowful, the path line also says where the
    -- selection is: "sel/total" at the right edge, the numbers the listing shows,
    -- so a scrolled browser is not a mystery.
    if #rows > view and view >= 1 then
        local tag = tostring(sel) .. "/" .. tostring(#rows)
        if #st.path + #tag + 2 <= api.w then
            api.write(api.w - #tag + 1, 1, tag, api.colours.gray)
        end
    end
    for i = 1, view do
        local row = rows[scroll + i]
        if not row then break end
        local y = i + 1
        local colour = row.entry and (row.entry.dir and api.colours.cyan or api.colours.lightGray)
            or api.colours.white
        local selected = (scroll + i == sel)
        if selected then
            -- A selection band, not a block: gray behind white keeps the names
            -- readable (black on orange was the version the owner could not read).
            -- The directory/file colours are dropped on this one row -- the band
            -- itself says "this one". The background is passed to the text write
            -- too: api.write with no bg paints the DEFAULT background, which would
            -- punch black holes in the band behind every character.
            api.fill(1, y, api.w, 1, " ", api.colours.white, api.colours.gray)
            colour = api.colours.white
        end
        if selected then
            api.write(1, y, row.text, colour, api.colours.gray)
        else
            api.write(1, y, row.text, colour)
        end
    end
    if #rows <= view and api.h > 2 then
        api.write(1, api.h, "enter opens   arrows move", api.colours.gray)
    end
end

function files.activate(api, win)
    local st = state(win)
    local picked = files.rows(win)[files.selection(win)]
    if not picked then return false end
    if picked.up then
        st.path = parent(st.path)
        st.select = 1
        return true
    end
    if picked.entry and picked.entry.dir then
        st.path = picked.entry.path
        st.select = 1
        return true
    end
    if picked.entry then
        -- The seam between the two applications: Files does not edit, and the
        -- editor does not list. One documented call, and any other app can open a
        -- file in the editor the same way.
        return api.open("editor", { path = picked.entry.path }) and true or false
    end
    return false
end

function files.event(api, win, ev)
    local st = state(win)
    if ev[1] == "key" then
        st.click_index = nil
        local key = tonumber(ev[2])
        local rows, view = files.visible(win, api.h)
        local sel = files.selection(win)
        local page = math.max(1, view)
        if key == 200 then                    -- up
            st.select = math.max(1, sel - 1)
        elseif key == 208 then                -- down
            st.select = math.min(#rows, sel + 1)
        elseif key == 201 then                -- page up
            st.select = math.max(1, sel - page)
        elseif key == 209 then                -- page down
            st.select = math.min(#rows, sel + page)
        elseif key == 199 then                -- home
            st.select = 1
        elseif key == 207 then                -- end
            st.select = #rows > 0 and #rows or 1
        elseif key == 28 then                 -- enter
            return files.activate(api, win)
        else
            return false
        end
        -- Scroll the selection into view in the same event, so the frame drawn
        -- after this call already shows the row the key moved to.
        files.visible(win, api.h)
        return true
    end
    if ev[1] ~= "mouse_click" then return false end
    if not ev[3] or not ev[4] then return false end
    local row = tonumber(ev[4]) - api.body.y + 1
    local col = tonumber(ev[3]) - api.body.x + 1
    if not row or not col or row < 1 or col < 1 or col > api.w then return false end
    if row == 1 then return true end              -- the path line: nothing to do
    local rows, view, scroll = files.visible(win, api.h)
    local index = scroll + (row - 1)
    local picked = rows[index]
    if not picked then return true end
    st.select = index
    -- ONE CLICK SELECTS, TWO CLICKS OPEN -- and no clock is consulted. The pair
    -- is "the same row twice with nothing else in between": any click on another
    -- row, any key, and entering/leaving a directory all reset it. A timer window
    -- was tried twice (0.5s, then 2s of the desktop clock) and the second click
    -- kept falling outside it on a real machine -- the desktop clock is advanced
    -- per tick, and how many ticks pass between two human clicks is not something
    -- this app can know. Consecutive clicks need no such knowledge, and the rule
    -- is what the operator already feels: click once to select, click again on
    -- the same row to open. Two separate clicks on different rows cannot pair, so
    -- navigation cannot open something by accident.
    local double = st.click_index == index
    st.click_index = index
    if double then
        -- The next click starts a new pair rather than opening again.
        st.click_index = nil
        return files.activate(api, win)
    end
    -- A single click on a file only selects it: opening is the double click or
    -- Enter, so a navigation click never leaves the browser by accident.
    return true
end
return files
