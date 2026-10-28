-- gnome.apps.editor - a windowed text editor over the CraftOS filesystem.
--
-- WHY IT IS ITS OWN APPLICATION
-- Files is a browser: it lists, descends and opens a file. The editor is the thing
-- with a cursor, a buffer, a save, an undo and a find, and loading both into one
-- module would give the file browser a text buffer and the text buffer a directory
-- listing. They meet at one documented seam instead: `api.open("editor",
-- { path = <file> })`, which Files calls when Enter is pressed on a file.
--
-- THE BUFFER IS LINES, NOT A BYTE OFFSET
-- `lines` is the file split on "\n"; joining them with "\n" reproduces the file
-- exactly -- including a trailing newline, which split/join keeps as one final empty
-- line. The cursor lives in that space (row and column, column 1..len+1), and the
-- DISPLAY is a second, derived thing: `wrap_layout` turns the logical lines into
-- the display rows the window is wide enough to hold. Automatic wrapping is that
-- derivation and nothing else -- no character is inserted, so saving a wrapped
-- document writes exactly what was typed.
--
-- KEYS
-- Arrows (by DISPLAY row, so a long wrapped line moves like the eye expects),
-- Home/End, PageUp/PageDown, Enter, Backspace, Delete, Tab and printable `char`
-- input edit; Ctrl+S or F2 saves; Ctrl+Z or F4 undoes one edit (the undo stack is
-- snapshots of the line table, capped); Ctrl+F or F3 opens the find prompt, F3
-- again finds the next occurrence (wrapped), and F9 leaves the prompt (an empty
-- query with Enter closes it too). The modifier-free F2/F3/F4/F9 exist because a
-- build cannot always tell that Ctrl is held -- the same reason F2 saves.
--
-- ESCAPE IS NOT THE WAY OUT OF FIND. Minecraft keeps ESC for its own menu and
-- never delivers it to the computer, so keys.escape is nil on the platform and a
-- branch keyed to it is dead code (the lesson lib/bios.lua's menus learned). The
-- desktop's back-out key is F10 (68), which it consumes before an application
-- sees it, so this app uses F9 (67) -- a function key the machine does deliver.
local editor = {}

-- The ROM's LWJGL key codes, read off rom/apis/keys.lua on CraftOS-PC 2.8.3
-- (the row starting at 66 is f8=66, f9=67, f10=68). Spelled here so the editor
-- works in a Lua state with no keys table (the PC suite).
local KEYS = {
    f9 = 67, backspace = 14, tab = 15, enter = 28,
    f = 33, z = 44, s = 31,
    home = 199, up = 200, pageup = 201, left = 203, right = 205,
    finish = 207, down = 208, pagedown = 209, delete = 211,
    f2 = 113, f3 = 114, f4 = 115,
}
editor.KEYS = KEYS

local UNDO_CAP = 200

-- Room for the file, the same check every other writer of the project asks
-- (lib/space.lua). The load is pcall'd and may fail: a machine whose base half
-- is an older installation does not carry the module, and a save that works must
-- not become an error because the preflight is missing. No module or no API
-- means "write it", which is exactly what space.need answers for itself.
local function space_need(path, bytes)
    local ok, space = pcall(require, "space")
    if not ok or type(space) ~= "table" or type(space.need) ~= "function" then
        return true
    end
    local ok_need, room, why = pcall(space.need, path, bytes)
    if not ok_need then return true end
    return room and true or false, why
end

local function ctrl_down()
    return type(keys) == "table" and type(keys.isCtrlDown) == "function"
        and keys.isCtrlDown() == true
end

local function split_lines(text)
    local lines, pos = {}, 1
    while true do
        local nl = text:find("\n", pos, true)
        if not nl then
            lines[#lines + 1] = text:sub(pos)
            break
        end
        lines[#lines + 1] = text:sub(pos, nl - 1)
        pos = nl + 1
    end
    return lines
end

local function read_file(path)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then
        return nil, "this machine has no filesystem"
    end
    local ok, f = pcall(fs.open, path, "r")
    if not ok or not f then return nil, "cannot read " .. tostring(path) end
    local okr, text = pcall(f.readAll)
    pcall(f.close)
    if not okr or type(text) ~= "string" then return nil, "cannot read " .. tostring(path) end
    return text
end

-- The state of one window. It is created on the first call that has the opts, so a
-- window created without a path still gets its buffer; an existing state is never
-- re-initialised, which is what keeps two editor windows independent.
local function state(win, opts)
    win.state = win.state or {}
    local st = win.state
    if st.ready then return st end
    st.ready = true
    st.lines = { "" }
    st.row, st.col = 1, 1
    st.scroll = 0
    st.path = nil
    st.dirty = false
    st.message = nil
    st.bytes = 0
    st.undo = {}
    st.find = nil
    if type(opts) == "table" and opts.path then
        editor.load(st, opts.path)
    end
    return st
end

function editor.text(st)
    return table.concat(st.lines, "\n")
end

-- Read a file into the buffer. Answers true, or false plus the reason (which is put
-- in the status line rather than raised into the desktop's event loop).
function editor.load(st, path)
    local text, why = read_file(path)
    if text == nil then
        st.path = path
        st.message = tostring(why)
        return false
    end
    st.path = path
    st.lines = split_lines(text)
    if #st.lines == 0 then st.lines = { "" } end
    st.row, st.col = 1, 1
    st.scroll = 0
    st.dirty = false
    st.bytes = #text
    st.message = nil
    st.undo = {}
    st.find = nil
    return true
end

-- Write the buffer back. Answers true, or false plus the reason.
function editor.write_file(path, text)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then
        return false, "this machine has no filesystem"
    end
    -- Before the open: an open truncates the file, so a refusal after it would
    -- have destroyed the old contents the refusal is meant to protect.
    local room, why = space_need(path, #text)
    if not room then return false, why end
    local ok, err = pcall(function()
        local f = fs.open(path, "w")
        if not f then error("cannot write " .. tostring(path), 0) end
        f.write(text)
        f.close()
    end)
    if not ok then return false, tostring(err) end
    return true
end

function editor.save(st)
    if not st.path or st.path == "" then
        st.message = "no file name: open a file from Files first"
        return false
    end
    local text = table.concat(st.lines, "\n")
    local ok, why = editor.write_file(st.path, text)
    if not ok then
        st.message = tostring(why)
        return false
    end
    st.dirty = false
    st.bytes = #text
    st.message = "saved " .. st.path .. " (" .. tostring(#text) .. " bytes)"
    return true
end

-- ------------------------------------------------------------------- undo
-- One snapshot per edit, the cursor included. Snapshots share the strings (only
-- the array is copied), so a 200-deep stack of a small document is cheap; the cap
-- is what keeps an editor left on a big file from growing without bound.
local function snapshot(st)
    local lines = {}
    for i = 1, #st.lines do lines[i] = st.lines[i] end
    st.undo[#st.undo + 1] = { lines = lines, row = st.row, col = st.col }
    if #st.undo > UNDO_CAP then table.remove(st.undo, 1) end
end

function editor.undo(st)
    local entry = table.remove(st.undo)
    if not entry then
        st.message = "nothing to undo"
        return false
    end
    st.lines = entry.lines
    st.row, st.col = entry.row, entry.col
    st.dirty = true
    st.message = "undone"
    return true
end

-- ------------------------------------------------------------------ layout
-- The display rows for a window w wide: one chunk per w columns of every logical
-- line. A line of exactly w characters gets a trailing empty chunk, because the
-- cursor can sit after the last character and that position needs a cell. This is
-- pure derivation: `lines` is never touched.
local function wrap_layout(st, w)
    if w < 1 then w = 1 end
    local out = {}
    for r = 1, #st.lines do
        local line = st.lines[r]
        local start = 1
        repeat
            out[#out + 1] = { row = r, start = start, text = line:sub(start, start + w - 1) }
            start = start + w
        until start > #line + 1
    end
    return out
end

-- Where the cursor is in the layout: the display index and its column in that row.
local function display_index(layout, st, w)
    if w < 1 then w = 1 end
    for i = 1, #layout do
        local chunk = layout[i]
        if chunk.row == st.row then
            local next_start = chunk.start + w
            if st.col >= chunk.start and st.col < next_start then
                return i, st.col - chunk.start + 1
            end
        end
    end
    return 1, 1
end

-- Move by display rows, keeping the column within the row (the wrapped line case
-- is why arrows are display-relative: down from the end of a long wrapped line
-- lands one display row lower, not on the next logical line).
local function move_display(st, w, delta)
    local layout = wrap_layout(st, w)
    local di, dc = display_index(layout, st, w)
    local target = di + delta
    if target < 1 then target = 1 end
    if target > #layout then target = #layout end
    local chunk = layout[target]
    if not chunk then return end
    st.row = chunk.row
    local want = chunk.start + dc - 1
    local line = st.lines[st.row] or ""
    if want > #line + 1 then want = #line + 1 end
    st.col = want
end

local function clamp(st)
    if st.row < 1 then st.row = 1 end
    if st.row > #st.lines then st.row = #st.lines end
    local line = st.lines[st.row] or ""
    if st.col < 1 then st.col = 1 end
    if st.col > #line + 1 then st.col = #line + 1 end
end

local function insert_text(st, text)
    snapshot(st)
    local line = st.lines[st.row]
    st.lines[st.row] = line:sub(1, st.col - 1) .. text .. line:sub(st.col)
    st.col = st.col + #text
    st.dirty = true
    st.message = nil
end

local function newline(st)
    snapshot(st)
    local line = st.lines[st.row]
    local left = line:sub(1, st.col - 1)
    local right = line:sub(st.col)
    st.lines[st.row] = left
    table.insert(st.lines, st.row + 1, right)
    st.row = st.row + 1
    st.col = 1
    st.dirty = true
    st.message = nil
end

local function backspace(st)
    snapshot(st)
    if st.col > 1 then
        local line = st.lines[st.row]
        st.lines[st.row] = line:sub(1, st.col - 2) .. line:sub(st.col)
        st.col = st.col - 1
    elseif st.row > 1 then
        local prev = st.lines[st.row - 1]
        st.col = #prev + 1
        st.lines[st.row - 1] = prev .. st.lines[st.row]
        table.remove(st.lines, st.row)
        st.row = st.row - 1
    else
        -- nothing to delete: do not leave an empty undo step behind
        st.undo[#st.undo] = nil
        return
    end
    st.dirty = true
    st.message = nil
end

local function delete(st)
    local line = st.lines[st.row]
    if st.col <= #line then
        snapshot(st)
        st.lines[st.row] = line:sub(1, st.col - 1) .. line:sub(st.col + 1)
    elseif st.row < #st.lines then
        snapshot(st)
        st.lines[st.row] = line .. st.lines[st.row + 1]
        table.remove(st.lines, st.row + 1)
    end
    st.dirty = true
    st.message = nil
end

local function move_left(st)
    if st.col > 1 then
        st.col = st.col - 1
    elseif st.row > 1 then
        st.row = st.row - 1
        st.col = #st.lines[st.row] + 1
    end
end

local function move_right(st)
    local line = st.lines[st.row]
    if st.col <= #line then
        st.col = st.col + 1
    elseif st.row < #st.lines then
        st.row = st.row + 1
        st.col = 1
    end
end

-- -------------------------------------------------------------------- find
-- Search forward from a position, wrapping once. Plain find: the operator is
-- looking for a string, not a pattern, and a pattern would need escaping rules this
-- window has no room to explain.
local function next_match(st, query, from_row, from_col)
    if query == nil or query == "" then return nil end
    for r = from_row, #st.lines do
        local start = 1
        if r == from_row then start = math.max(1, from_col) end
        local at = st.lines[r]:find(query, start, true)
        if at then return r, at end
    end
    for r = 1, from_row do
        local at = st.lines[r]:find(query, 1, true)
        if at then return r, at end
    end
    return nil
end

-- Find the NEXT occurrence, starting just after the cursor and wrapping once. That
-- is the meaning of F3 after Enter, and it is also what Enter itself does when the
-- query was already committed.
local function find_after(st)
    local query = st.find and st.find.query or ""
    if query == "" then return false end
    local r, c = next_match(st, query, st.row, st.col + 1)
    if r then
        st.row, st.col = r, c
        st.message = "found " .. tostring(r) .. ":" .. tostring(c)
        return true
    end
    st.message = "not found: " .. query
    return false
end

-- What the cursor is on: the cell under it is drawn in the accent colour, so the
-- operator can always see where typing will land even on a line of spaces.
function editor.draw(api, win)
    local st = state(win, win.opts)
    local w, h = api.w, api.h
    if w < 4 or h < 2 then return end
    local head = st.path or "[no file]"
    local pos = tostring(st.row) .. ":" .. tostring(st.col) .. (st.dirty and "*" or "")
    api.write(1, 1, head, api.colours.white)
    if #head + #pos + 2 <= w then
        api.write(w - #pos + 1, 1, pos,
                  st.dirty and api.colours.orange or api.colours.lightGray)
    end
    local view = h - 2
    local layout = wrap_layout(st, w)
    local di, dc = display_index(layout, st, w)
    if view > 0 then
        local maxscroll = math.max(0, #layout - view)
        if di - 1 < st.scroll then st.scroll = di - 1 end
        if di - 1 >= st.scroll + view then st.scroll = di - 1 - view + 1 end
        if st.scroll > maxscroll then st.scroll = maxscroll end
        if st.scroll < 0 then st.scroll = 0 end
        for i = 1, view do
            local chunk = layout[st.scroll + i]
            if chunk == nil then break end
            api.write(1, 1 + i, chunk.text, api.colours.lightGray)
        end
        local cy = 1 + (di - st.scroll)
        if cy >= 2 and cy <= h - 1 then
            local ch = st.lines[st.row]:sub(st.col, st.col)
            if ch == "" then ch = " " end
            api.cell(math.min(dc, w), cy, ch, api.colours.black, api.colours.orange)
        end
    end
    local status
    if st.find and st.find.mode == "input" then
        status = "find: " .. tostring(st.find.query)
    elseif st.message then
        status = st.message
    else
        status = "ctrl+s/F2 save   ctrl+z/F4 undo   ctrl+f/F3 find"
    end
    api.write(1, h, status, api.colours.gray)
end

function editor.event(api, win, ev)
    local st = state(win, win.opts)
    local name = type(ev) == "table" and ev[1] or nil
    local w = math.max(1, api.w)
    if name == "char" then
        local ch = tostring(ev[2] or "")
        if #ch == 1 then
            local byte = ch:byte()
            if byte and byte >= 32 and byte < 127 then
                if st.find and st.find.mode == "input" then
                    st.find.query = st.find.query .. ch
                    return true
                end
                insert_text(st, ch)
                return true
            end
        end
        return false
    end
    if name ~= "key" then return false end
    local k = tonumber(ev[2])
    local ctrl = ctrl_down()

    -- The find prompt takes the keyboard while it is open: characters go to the
    -- query, not to the buffer, which is what makes the prompt a mode rather than
    -- a decoration.
    if st.find and st.find.mode == "input" then
        if k == KEYS.backspace then
            st.find.query = st.find.query:sub(1, -2)
            return true
        elseif k == KEYS.enter then
            if #st.find.query == 0 then
                st.find = nil
                return true
            end
            local r, c = next_match(st, st.find.query, st.row, st.col)
            if r then
                st.row, st.col = r, c
                st.find.mode = "active"
                st.message = "found " .. tostring(r) .. ":" .. tostring(c)
            else
                st.find.mode = "active"
                st.message = "not found: " .. st.find.query
            end
            return true
        elseif k == KEYS.f3 then
            st.find.mode = "active"
            return find_after(st)
        elseif k == KEYS.f9 then
            st.find = nil
            return true
        end
        return false
    end

    if ctrl and k == KEYS.s then editor.save(st) return true end
    if k == KEYS.f2 then editor.save(st) return true end
    if (ctrl and k == KEYS.z) or k == KEYS.f4 then editor.undo(st) return true end
    if (ctrl and k == KEYS.f) or k == KEYS.f3 then
        -- F3 is "find next" once a query is committed; Ctrl+F is the prompt.
        if k == KEYS.f3 and st.find and st.find.query ~= "" and
           st.find.mode == "active" then
            return find_after(st)
        end
        st.find = st.find or { query = "" }
        st.find.mode = "input"
        return true
    end

    if k == KEYS.enter then
        newline(st)
    elseif k == KEYS.backspace then
        backspace(st)
    elseif k == KEYS.delete then
        delete(st)
    elseif k == KEYS.tab then
        insert_text(st, "  ")
    elseif k == KEYS.left then
        move_left(st)
    elseif k == KEYS.right then
        move_right(st)
    elseif k == KEYS.up then
        move_display(st, w, -1)
    elseif k == KEYS.down then
        move_display(st, w, 1)
    elseif k == KEYS.home then
        st.col = 1
    elseif k == KEYS.finish then
        st.col = #st.lines[st.row] + 1
    elseif k == KEYS.pageup then
        move_display(st, w, -math.max(1, api.h - 2))
    elseif k == KEYS.pagedown then
        move_display(st, w, math.max(1, api.h - 2))
    elseif k == KEYS.f9 then
        st.find = nil
        return true
    else
        return false
    end
    clamp(st)
    return true
end

-- The state accessor is public for the suite: a test can assert the buffer, the
-- undo stack and the find prompt without reaching into the app's closures.
function editor.buffer(win, opts)
    return state(win, opts)
end

-- The layout is public for the same reason: the wrap is the interesting derived
-- thing, and asserting it directly is clearer than reading cells back.
function editor.layout(st, w)
    return wrap_layout(st, w)
end

function editor.cursor_display(st, w)
    return display_index(wrap_layout(st, w), st, w)
end

return editor
