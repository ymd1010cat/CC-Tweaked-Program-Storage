--[[- pyroet-os/examples/files.app/main.lua -- a small, read-only file manager.

An *optional* example package (not in the image, like net and web): copy
examples/files.app to /pkgs/files.app and install it. It browses the file
system read-only on purpose -- no write, no delete, so a mis-key cannot lose a
file.

Keys (Esc is never used: the ROM does not deliver it):
    up/down     move in the list (or scroll a viewed file)
    enter       open a directory / view a text file
    b, backspace  go up one directory (or close the viewer)
    r           re-read the current directory
    h           show hidden entries (dot files)
    q           quit

No non-ASCII bytes in this file. `_G.PYROET_FILES_TEST` returns the module.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 51, rows = 19 }
M.MIN_COLS = 14
M.MIN_ROWS = 6
M.MAX_BYTES = 65536
M.MAX_LINES = 4000
M.HINT = "up/dn enter b up r refresh h hidden q quit"

function M.fit(text, cols)
    local value = tostring(text == nil and "" or text)
    if #value > cols then value = value:sub(1, cols) end
    while #value < cols do value = value .. " " end
    return value
end

function M.note(api, text)
    if type(api) ~= "table" or type(api.log) ~= "function" then return false end
    return pcall(api.log, text)
end

function M.fs_of(api)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.list) ~= "function" then return nil end
    return fsx
end

function M.join(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end

function M.parent(path)
    local text = tostring(path or "/")
    if text == "/" or text == "" then return "/" end
    local parent = text:match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then return "/" end
    return parent
end

function M.hidden(name)
    return tostring(name):sub(1, 1) == "."
end

-- one directory read: name, is directory, size (0 when unknown)
function M.read_dir(api, path, opts)
    local o = opts or {}
    local fsx = M.fs_of(api)
    if fsx == nil then
        M.note(api, "FILES_DENIED path=" .. tostring(path) .. " reason=no_fs")
        return nil, "no fs"
    end
    local called, names = pcall(fsx.list, path)
    if not called then
        M.note(api, "FILES_DENIED path=" .. tostring(path) .. " reason=" .. tostring(names))
        return nil, "cannot list"
    end
    if type(names) ~= "table" then
        M.note(api, "FILES_DENIED path=" .. tostring(path) .. " reason=not_found")
        return nil, "no such directory"
    end
    local out = {}
    for i = 1, #names do
        local name = tostring(names[i])
        if o.show_hidden or not M.hidden(name) then
            local full = M.join(path, name)
            local is_dir = false
            if type(fsx.isDir) == "function" then
                local dcalled, value = pcall(fsx.isDir, full)
                is_dir = (dcalled and value) == true
            end
            local size = 0
            if not is_dir and type(fsx.getSize) == "function" then
                local scalled, value = pcall(fsx.getSize, full)
                if scalled and type(value) == "number" then size = value end
            end
            out[#out + 1] = { name = name, path = full, dir = is_dir, size = size }
        end
    end
    table.sort(out, function(a, b)
        if a.dir ~= b.dir then return a.dir end
        return a.name < b.name
    end)
    return out
end

function M.new_state(api, opts)
    local o = opts or {}
    local state = {
        cwd = o.cwd or "/",
        entries = {},
        index = 1,
        scroll = 0,
        message = "",
        show_hidden = o.show_hidden == true,
        view = nil,
        cols = M.VIEW.cols,
        rows = M.VIEW.rows,
    }
    M.refresh(state, api)
    return state
end

function M.refresh(state, api)
    local entries, err = M.read_dir(api, state.cwd, { show_hidden = state.show_hidden })
    if entries == nil then
        state.entries = {}
        state.message = "denied: " .. tostring(err)
        return false
    end
    state.entries = entries
    if state.index > #entries then state.index = math.max(1, #entries) end
    state.scroll = 0
    state.message = #entries .. " entries"
    return true
end

function M.selected(state)
    return state.entries[state.index or 1]
end

function M.move(state, delta)
    local count = #state.entries
    if count == 0 then return "none" end
    local index = (state.index or 1) + delta
    if index < 1 then index = 1 end
    if index > count then index = count end
    if index == state.index then return "none" end
    state.index = index
    return "move"
end

function M.enter(state, api)
    local entry = M.selected(state)
    if entry == nil then
        state.message = "empty"
        return "none"
    end
    if entry.dir then
        state.cwd = entry.path
        state.index = 1
        M.refresh(state, api)
        M.note(api, "FILES_OPEN path=" .. entry.path)
        return "open"
    end
    return M.view_file(state, api, entry.path)
end

function M.view_file(state, api, path)
    local fsx = M.fs_of(api)
    if fsx == nil or type(fsx.read) ~= "function" then
        M.note(api, "FILES_DENIED path=" .. tostring(path) .. " reason=no_fs")
        state.message = "denied: no fs"
        return "error"
    end
    local called, body = pcall(fsx.read, path)
    if not called or type(body) ~= "string" then
        local reason = called and "not found" or tostring(body)
        M.note(api, "FILES_DENIED path=" .. tostring(path) .. " reason=" .. reason)
        state.message = "denied: " .. tostring(reason)
        return "error"
    end
    local truncated = false
    if #body > M.MAX_BYTES then
        body = body:sub(1, M.MAX_BYTES)
        truncated = true
    end
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r", ""))
        if #lines >= M.MAX_LINES then break end
    end
    if #lines == 0 then lines[1] = "" end
    if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
    state.view = { path = path, lines = lines, scroll = 0 }
    state.message = truncated and "truncated at 64 KB" or (#lines .. " lines")
    M.note(api, "FILES_VIEW path=" .. tostring(path) .. " lines=" .. tostring(#lines)
        .. (truncated and " truncated=true" or ""))
    return "open"
end

function M.view_scroll(state, delta)
    local view = state.view
    if type(view) ~= "table" then return "none" end
    local page = (state.rows or M.VIEW.rows) - 4
    local max_scroll = math.max(0, #(view.lines or {}) - page)
    local value = (view.scroll or 0) + delta
    if value < 0 then value = 0 end
    if value > max_scroll then value = max_scroll end
    if value == view.scroll then return "none" end
    view.scroll = value
    return "scroll"
end

function M.up(state, api)
    if state.view ~= nil then
        state.view = nil
        return "open"
    end
    if state.cwd == "/" then
        state.message = "root"
        return "none"
    end
    state.cwd = M.parent(state.cwd)
    state.index = 1
    M.refresh(state, api)
    M.note(api, "FILES_OPEN path=" .. tostring(state.cwd))
    return "open"
end

function M.render(state, cols, rows)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    rows = math.floor(tonumber(rows) or M.VIEW.rows)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    if cols < M.MIN_COLS or rows < M.MIN_ROWS then
        return { M.fit("files " .. tostring(#(state.entries or {})) .. " entries", cols) }
    end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("Files " .. M.VERSION)
    if state.view ~= nil then
        add("view " .. tostring(state.view.path))
        local page = rows - 4
        local first = (state.view.scroll or 0) + 1
        for i = 0, page - 1 do
            add(state.view.lines[first + i] or "")
        end
        add(state.message ~= "" and state.message or "view")
        add("up/dn scroll b back q quit")
        return out
    end
    add(state.cwd .. (state.show_hidden and "  (hidden on)" or ""))
    local page = rows - 4
    local count = #(state.entries or {})
    local first = 1
    if count > page then
        first = math.max(1, (state.index or 1) - page + 1)
        if first + page - 1 > count then first = math.max(1, count - page + 1) end
    end
    for i = 0, page - 1 do
        local position = first + i
        local entry = state.entries[position]
        if entry == nil then
            add("")
        else
            local marker = (position == (state.index or 1)) and ">" or " "
            local label = entry.dir and ("/" .. entry.name .. "/") or entry.name
            local tail = entry.dir and "dir" or tostring(entry.size) .. " B"
            add(marker .. " " .. label .. "  " .. tail)
        end
    end
    add(state.message ~= "" and state.message or M.HINT)
    add(M.HINT)
    return out
end

function M.key_map(keysx)
    local out = {}
    if type(keysx) ~= "table" then return out end
    for name, code in pairs(keysx) do
        if type(name) == "string" and type(code) == "number" and out[code] == nil then
            out[code] = name
        end
    end
    return out
end

function M.keys_table(api)
    local input = type(api) == "table" and api.input or nil
    local keysx = type(input) == "table" and input.keys or nil
    if type(keysx) == "table" and next(keysx) ~= nil then return keysx end
    return rawget(_G, "keys")
end

function M.code_name(code, api)
    local keysx = M.keys_table(api)
    if M.map_source ~= keysx then
        M.map_source = keysx
        M.map = M.key_map(keysx)
    end
    return (M.map or {})[code]
end

function M.dispatch_event(state, event, p1, api)
    if event == "key" then
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        key = tostring(key == nil and "" or key):lower()
        if key == "q" then return "quit", "q" end
        if state.view ~= nil then
            if key == "up" then return M.view_scroll(state, -1) end
            if key == "down" then return M.view_scroll(state, 1) end
            if key == "b" or key == "backspace" then return M.up(state, api) end
            return "none"
        end
        if key == "up" then return M.move(state, -1) end
        if key == "down" then return M.move(state, 1) end
        if key == "enter" then return M.enter(state, api) end
        if key == "b" or key == "backspace" then return M.up(state, api) end
        if key == "r" then M.refresh(state, api) return "repaint" end
        if key == "h" then
            state.show_hidden = not state.show_hidden
            M.refresh(state, api)
            state.message = "hidden " .. (state.show_hidden and "on" or "off")
            return "repaint"
        end
        return "none"
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1):lower()
        if ch == "q" then return "quit", "q" end
        if ch == "b" then return M.up(state, api) end
        if ch == "r" then M.refresh(state, api) return "repaint" end
        if ch == "h" then
            state.show_hidden = not state.show_hidden
            M.refresh(state, api)
            return "repaint"
        end
        return "none"
    end
    if event == "desk_focus" or event == "term_resize" then return "repaint" end
    if event == "terminate" or event == "shutdown" then return "quit", event end
    return "none"
end

function M.clear(term)
    local t = term or rawget(_G, "term")
    if type(t) ~= "table" or type(t.clear) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(t.clear))
end

function M.paint(lines, term_api)
    local t = term_api or rawget(_G, "term")
    if type(t) ~= "table" or type(t.write) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(function()
        for i = 1, #lines do
            t.setCursorPos(1, i)
            t.write(lines[i])
        end
    end))
end

function M.view_size(term_api)
    local cols, rows = M.VIEW.cols, M.VIEW.rows
    local t = term_api or rawget(_G, "term")
    if type(t) == "table" and type(t.getSize) == "function" then
        local ok, w, h = pcall(t.getSize)
        if ok and type(w) == "number" and type(h) == "number" then
            cols = math.min(cols, math.max(1, math.floor(w)))
            rows = math.min(rows, math.max(1, math.floor(h)))
        end
    end
    return cols, rows
end

function M.paint_once(state, api, term)
    local cols, rows = M.view_size(term)
    state.cols, state.rows = cols, rows
    local lines = M.render(state, cols, rows)
    M.clear(term)
    M.paint(lines, term)
    state.painted = (state.painted or 0) + 1
    return lines
end

function M.idle(api)
    if type(api) == "table" and type(api.yield) == "function" then api.yield() end
    return "idle"
end

function M.body(manifest, api)
    local state = M.new_state(api)
    state.manifest = manifest
    local term = type(api) == "table" and api.terminal or nil
    local input = type(api) == "table" and api.input or nil
    local pull = type(input) == "table" and input.pullEvent or nil
    M.paint_once(state, api, term)
    M.note(api, "FILES_OPEN path=" .. tostring(state.cwd))
    if type(pull) ~= "function" then return M.idle(api) end
    while true do
        local event, p1 = pull()
        if event == nil then return M.idle(api) end
        local action, detail = M.dispatch_event(state, event, p1, api)
        if action == "quit" then
            M.note(api, "FILES_QUIT key=" .. tostring(detail))
            return "quit"
        end
        if action ~= "none" then M.paint_once(state, api, term) end
        api.yield()
    end
end

if rawget(_G, "PYROET_FILES_TEST") then return M end

return function(manifest, api)
    return M.body(manifest, api)
end
