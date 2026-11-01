--[[- pyroet-os/system/launcher.app/main.lua -- the Pyroet OS desktop (26x20 UI).

Responsibilities, and nothing else:

  1. scan /apps and /system/system for `<name>.app` directories that hold a
     manifest.lua, and show name + version (the version comes from the app
     runtime through `api.sys.apps()`; a package the runtime refused to load
     still gets a row, marked `?`);
  2. show a two line status block on top: image version and the first eight
     hex digits of /boot.ok's manifest_sha (the global commit marker -- there
     is one system tree and no slot pointer), net service health, free space;
  3. move a selection with the arrow keys or a digit key, and start the
     selected app on Enter *through the runtime* (`api.sys.launch`), never by
     pulling a coroutine of its own;
  4. after a successful start, append the name to /etc/launcher.recent.
     fs.write is declared for that one line only, and a refusal is ignored.

Input (D1): the desktop is resident now. The kernel's event loop
(kernel/desktop.lua) owns the one blocking `os.pullEvent`, normalizes what it
gets and pushes it into the machine's input queue, one event per scheduler step;
this app declares `input` and pulls that queue with `api.input.pullEvent()`,
which answers `nil` when nothing was delivered (it yields then -- a loop must
never spin on the keyboard). Keys are still a *pure* function of the state
(`M.handle_key(state, key)`), so the whole mapping stays testable without a
terminal, and `M.run` keeps the old keys-driven harness path.

Exit (D1): Esc, or `q` as a character, returns `"quit"` from the body. The app
runtime records that word and the desktop loop unwinds the boot chain back to
the console shell. Nothing else leaves the desktop.

Layout (DECISIONS.md 7.2): row 1 version + short hash, row 2 net + free, rows 3..n-2
the list, row n-1 the hint (or one message), row n the selection counter. Every
line is padded or truncated to the view width and never wider. Nothing fits
under 16 columns or 6 rows, so the view collapses to a single status line --
`layout_selftest` proves both rules without a terminal.

Test hooks (real boots never set them): _G.PYROET_LAUNCHER_TEST returns the
module instead of the entry body, _G.PYROET_APP_NOPAINT skips painting.

No non-ASCII bytes in this file.
]]

local M = {}

M.VERSION = "0.2.0"
M.VIEW = { cols = 26, rows = 20 }
M.MIN_COLS = 16
M.MIN_ROWS = 6
M.ROOTS = { "/apps", "/system/system" }
M.BOOT_OK = "/boot.ok"
M.RECENT_PATH = "/etc/launcher.recent"
M.HINT = "up/dn enter run"
-- leaving Pyroet OS is Ctrl+T (the ROM `terminate` event), never a letter:
-- q used to drop the whole machine to the CraftOS shell, which is not what
-- "back" means on this desktop.
M.LEAVE_HINT = "Ctrl+T leaves Pyroet OS"
M.SCAN_INTERVAL = 10

-- printable ASCII only, truncated or padded to exactly `cols` columns
function M.fit(text, cols)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    if cols < 1 then cols = 1 end
    local s = tostring(text == nil and "" or text):gsub("[^\32-\126]", "?")
    if #s > cols then
        s = s:sub(1, cols)
    elseif #s < cols then
        s = s .. string.rep(" ", cols - #s)
    end
    return s
end

-- 2500 -> "2500B", 26214 -> "25K"; deliberately short, it shares a 26 column row
function M.bytes_text(value)
    local n = tonumber(value)
    if n == nil or n < 0 then return "n/a" end
    n = math.floor(n)
    if n < 1024 then return tostring(n) .. "B" end
    if n < 1048576 then return tostring(math.floor(n / 1024)) .. "K" end
    return tostring(math.floor(n / 1048576)) .. "M"
end

-- ---------------------------------------------------------------------------
-- reading the machine
-- ---------------------------------------------------------------------------

-- fs.read is a capability: a denial is a normal result, never a crash
function M.read_file(api, path)
    local fsx = api and api.fs
    if type(fsx) ~= "table" or type(fsx.read) ~= "function" then
        return nil, "capability denied: fs.read"
    end
    local called, text, err = pcall(fsx.read, path)
    if not called then return nil, tostring(text) end
    if text == nil then return nil, tostring(err or "missing") end
    return text, nil
end

local function marker_value(text, key)
    return tostring(text):match(key .. "=([^%s]+)")
end

-- the first eight hex digits of a hash, or nil when the value is not a full hex
-- string (P6 markers write `manifest_sha=none` when no update journal exists)
function M.short_sha(value)
    local text = tostring(value == nil and "" or value)
    if not text:match("^%x+$") then return nil end
    return text:sub(1, 8)
end

-- the one global commit marker the single-tree boot chain writes:
-- `PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..`. There is no slot
-- pointer to consult and no per-slot descriptor to fall back to.
function M.read_boot(api)
    local info = { version = nil, sha256 = nil, source = nil }
    local text = M.read_file(api, M.BOOT_OK)
    if type(text) == "string" then
        local version = marker_value(text, "version")
        if version then info.version = version end
        -- manifest_sha is the P6 key; sha256 is the same field on a marker the
        -- v1 boot chain left behind (same file, same meaning, not a slot read)
        local sha = marker_value(text, "manifest_sha") or marker_value(text, "sha256")
        if sha and sha ~= "none" then info.sha256 = sha end
        info.source = M.BOOT_OK
    end
    return info
end

-- net health through the host's read-only system surface: "ok", "degraded",
-- "down" (service not running), "off" (no net service at all)
function M.read_net(api)
    local sys = api and api.sys
    if type(sys) ~= "table" or type(sys.status) ~= "function" then
        return "off", "system unavailable: status"
    end
    local called, status = pcall(sys.status)
    if not called or type(status) ~= "table" then
        return "off", tostring(status)
    end
    local services = status.services or {}
    for i = 1, #services do
        local entry = services[i]
        if type(entry) == "table" and entry.name == "net" then
            if entry.state ~= "running" then return "down", tostring(entry.state) end
            if entry.healthy == "degraded" then return "degraded", nil end
            return "ok", nil
        end
    end
    return "off", nil
end

function M.read_free(api)
    local fsx = api and api.fs
    if type(fsx) ~= "table" or type(fsx.getFreeSpace) ~= "function" then return nil end
    local called, value = pcall(fsx.getFreeSpace, "/")
    if not called or type(value) ~= "number" then return nil end
    return math.floor(value)
end

-- ---------------------------------------------------------------------------
-- scanning
-- ---------------------------------------------------------------------------

-- A package is a directory `<name>.app` holding manifest.lua. The runtime owns
-- the loaded manifest (it validated it), so the version comes from
-- `api.sys.apps()`; a directory the runtime does not know is still listed, with
-- version "?" -- the desktop shows what is on the medium, not just what runs.
function M.scan(api, opts)
    local o = opts or {}
    local roots = o.roots or M.ROOTS
    local fsx = api and api.fs
    local entries, problems = {}, {}
    if type(fsx) ~= "table" or type(fsx.list) ~= "function" then
        problems[#problems + 1] = "fs.read denied"
        return entries, problems
    end
    local index = {}
    local sys = api and api.sys
    if type(sys) == "table" and type(sys.apps) == "function" then
        local called, list = pcall(sys.apps)
        if called and type(list) == "table" then
            for i = 1, #list do
                local item = list[i]
                if type(item) == "table" and type(item.name) == "string" then
                    index[item.name] = item
                end
            end
        end
    end
    local seen = {}
    local function add_entry(app, dir, root)
        local record = index[app]
        entries[#entries + 1] = {
            name = app,
            dir = dir,
            root = root,
            version = type(record) == "table" and record.version or "?",
            state = type(record) == "table" and record.state or "unknown",
            capabilities = type(record) == "table" and record.capabilities or nil,
        }
    end
    for r = 1, #roots do
        local root = tostring(roots[r])
        local called, names = pcall(fsx.list, root)
        if not called or type(names) ~= "table" then
            problems[#problems + 1] = "no root " .. root
        else
            local sorted = {}
            for i = 1, #names do sorted[#sorted + 1] = tostring(names[i]) end
            table.sort(sorted)
            for i = 1, #sorted do
                local name = sorted[i]
                if name:sub(-4) == ".app" then
                    local dir = root .. "/" .. name
                    local app = name:sub(1, #name - 4)
                    local manifest = false
                    if type(fsx.exists) == "function" then
                        local ecalled, found = pcall(fsx.exists, dir .. "/manifest.lua")
                        manifest = ecalled and found == true
                    end
                    if not manifest then
                        problems[#problems + 1] = "no manifest " .. app
                    elseif seen[app] then
                        problems[#problems + 1] = "duplicate " .. app
                    else
                        seen[app] = true
                        add_entry(app, dir, root)
                    end
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.name == b.name then return a.root < b.root end
        return a.name < b.name
    end)
    return entries, problems
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

function M.build(api, opts)
    local o = opts or {}
    local state = {
        cols = o.cols or M.VIEW.cols,
        rows = o.rows or M.VIEW.rows,
        entries = {},
        index = 1,
        problems = {},
        message = "",
        version = "?",
        sha256 = nil,
        boot_source = nil,
        net = "?",
        net_reason = nil,
        free = nil,
        launched = nil,
        frames = 0,
        scanned = 0,
        roots = o.roots or M.ROOTS,
        scan_interval = o.scan_interval or M.SCAN_INTERVAL,
    }
    return M.refresh(state, api, o)
end

function M.refresh(state, api, opts)
    local o = opts or {}
    state.frames = (state.frames or 0) + 1
    local interval = o.scan_interval or state.scan_interval or M.SCAN_INTERVAL
    local want = (state.scanned or 0) == 0 or o.force_scan == true
        or (interval > 0 and (state.frames % interval) == 0)
    if want then
        local keep = state.selected_name
        if not keep then
            local current = state.entries[state.index]
            keep = current and current.name or nil
        end
        local entries, problems = M.scan(api, { roots = state.roots })
        state.entries = entries
        state.problems = problems
        state.scanned = (state.scanned or 0) + 1
        local index = nil
        if keep then
            for i = 1, #entries do
                if entries[i].name == keep then index = i break end
            end
        end
        state.index = index or state.index or 1
        if state.index > #entries then state.index = math.max(1, #entries) end
        if state.index < 1 then state.index = 1 end
        local selected = entries[state.index]
        state.selected_name = selected and selected.name or nil
    end
    local boot = M.read_boot(api)
    state.version = boot.version or "?"
    state.sha256 = boot.sha256
    state.boot_source = boot.source
    local net, reason = M.read_net(api)
    state.net = net
    state.net_reason = reason
    state.free = M.read_free(api)
    return state
end

function M.selected(state)
    return (state.entries or {})[state.index or 0]
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

function M.header_lines(state)
    local first = "ver " .. tostring(state.version or "?")
    local short = M.short_sha(state.sha256)
    if short then first = first .. " sha " .. short end
    return {
        first,
        "net " .. tostring(state.net or "?") .. " free "
            .. (state.free and M.bytes_text(state.free) or "n/a"),
    }
end

-- full width keeps a version column; a narrow view drops it and stays a single
-- column list instead of truncating the names away
function M.row_text(state, entry, position, cols)
    local marker = (position == state.index) and ">" or " "
    if cols >= M.VIEW.cols then
        local version = tostring(entry.version or "?")
        local pad = cols - 2 - #entry.name - #version
        if pad >= 1 then
            return marker .. " " .. entry.name .. string.rep(" ", pad) .. version
        end
        return marker .. " " .. entry.name .. " " .. version
    end
    return marker .. " " .. entry.name
end

function M.window(state, area)
    local count = #(state.entries or {})
    if count <= area then return 1 end
    local first = math.max(1, (state.index or 1) - area + 1)
    if first + area - 1 > count then first = math.max(1, count - area + 1) end
    return first
end

function M.hint_line(state)
    if state.message and state.message ~= "" then return state.message end
    if #(state.entries or {}) == 0 then return "no apps installed" end
    return M.HINT
end

function M.status_line(state, cols)
    local count = #(state.entries or {})
    local index = state.index or 0
    if count == 0 then index = 0 end
    local text = tostring(count) .. " app" .. (count == 1 and "" or "s")
        .. " sel " .. tostring(index) .. "/" .. tostring(count)
    return M.fit(text, cols)
end

function M.compact_line(state, cols, rows)
    local count = #(state.entries or {})
    return M.fit("launcher " .. tostring(count) .. " apps " .. tostring(cols)
        .. "x" .. tostring(rows), cols)
end

function M.render(state, cols, rows)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    rows = math.floor(tonumber(rows) or M.VIEW.rows)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    if cols < M.MIN_COLS or rows < M.MIN_ROWS then
        return { M.compact_line(state, cols, rows) }
    end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    local header = M.header_lines(state)
    add(header[1])
    add(header[2])
    local area = rows - 4
    local first = M.window(state, area)
    local entries = state.entries or {}
    for i = 0, area - 1 do
        local position = first + i
        local entry = entries[position]
        if entry then
            add(M.row_text(state, entry, position, cols))
        else
            add("")
        end
    end
    add(M.hint_line(state))
    add(M.status_line(state, cols))
    return out
end

function M.paint(lines, term_api)
    local t = term_api or rawget(_G, "term")
    if type(t) ~= "table" or type(t.setCursorPos) ~= "function"
        or type(t.write) ~= "function" then
        return false
    end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    local ok = pcall(function()
        for i = 1, #lines do
            t.setCursorPos(1, i)
            t.write(lines[i])
        end
    end)
    return ok
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

-- ---------------------------------------------------------------------------
-- input and launch
-- ---------------------------------------------------------------------------

function M.note_recent(api, name)
    local fsx = api and api.fs
    if type(fsx) ~= "table" or type(fsx.write) ~= "function" then return false end
    local parent = M.RECENT_PATH:match("^(.*)/[^/]+$")
    if type(fsx.exists) == "function" and type(fsx.makeDir) == "function"
        and parent and parent ~= "" then
        local called, exists = pcall(fsx.exists, parent)
        if not (called and exists) then pcall(fsx.makeDir, parent) end
    end
    return (pcall(fsx.write, M.RECENT_PATH, tostring(name) .. "\n"))
end

-- Start through the runtime's entry point (api.sys.launch), never by pulling a
-- coroutine: the scheduler owns app lifecycles.
function M.launch_selected(state, api)
    local entry = M.selected(state)
    if not entry then
        state.message = "no app selected"
        return "none"
    end
    local sys = api and api.sys
    if type(sys) ~= "table" or type(sys.launch) ~= "function" then
        state.message = "launch denied"
        return "denied"
    end
    local called, started, err = pcall(sys.launch, entry.name)
    if not called then
        state.message = "launch failed"
        state.launch_error = tostring(started)
        return "error", tostring(started)
    end
    if started then
        state.launched = entry.name
        state.message = "started " .. entry.name
        M.note_recent(api, entry.name)
        return "launch", entry.name
    end
    state.message = "cannot start " .. entry.name
    state.launch_error = tostring(err)
    return "error", tostring(err)
end

local UP = { up = true, left = true }
local DOWN = { down = true, right = true }

-- ---------------------------------------------------------------------------
-- key names (D1-fix: both shapes are accepted)
-- ---------------------------------------------------------------------------
--
-- The desktop dispatcher delivers `key` events with a *name* ("up"/"down"), but
-- a raw keycode can still reach the launcher (a `key_up` event, a different
-- host, or a test). The code -> name map is built from the ROM's own keys table
-- through `api.input.keys`, so it is right on every ROM instead of being a
-- hardcoded list of numbers: CraftOS-PC sends up=200/down=208, Minecraft's
-- CC:Tweaked sends 265/264, and both resolve to the same names.

M.KEY_NAMES = { "up", "down", "left", "right", "enter", "escape", "backspace",
    "tab", "delete", "space" }

function M.key_map(keysx)
    local out = {}
    if type(keysx) ~= "table" then return out end
    for i = 1, #M.KEY_NAMES do
        local name = M.KEY_NAMES[i]
        local code = keysx[name]
        if type(code) == "number" and out[code] == nil then out[code] = name end
    end
    for name, code in pairs(keysx) do
        if type(name) == "string" and type(code) == "number" and out[code] == nil then
            out[code] = name
        end
    end
    return out
end

-- the keys table this app can see: the granted `input` host first, the ROM
-- global as the fallback (a denied capability still answers with an empty table)
function M.keys_table(api)
    local input = type(api) == "table" and api.input or nil
    local keysx = type(input) == "table" and input.keys or nil
    if type(keysx) == "table" and next(keysx) ~= nil then return keysx end
    return rawget(_G, "keys")
end

-- numeric keycode -> name, cached per keys table (the table never changes)
function M.code_name(code, api)
    local keysx = M.keys_table(api)
    if M.map_source ~= keysx then
        M.map_source = keysx
        M.map = M.key_map(keysx)
    end
    return (M.map or {})[code]
end

-- pure key handling: one key in, one action out. Returns the action
-- ("move"|"select"|"launch"|"error"|"denied"|"none") and the app name when the
-- action started something. A number is normalized through the ROM's keys table
-- first, so a raw keycode works exactly like the name the dispatcher sends.
function M.handle_key(state, key, api)
    local count = #(state.entries or {})
    if type(key) == "number" then
        local name = M.code_name(key, api)
        if name == nil then return "none" end
        key = name
    end
    if type(key) ~= "string" then return "none" end
    if UP[key] or DOWN[key] then
        if count == 0 then
            state.index = 1
            return "none"
        end
        if UP[key] then
            state.index = state.index - 1
            if state.index < 1 then state.index = count end
        else
            state.index = state.index + 1
            if state.index > count then state.index = 1 end
        end
        state.selected_name = state.entries[state.index].name
        state.message = ""
        return "move"
    end
    if key:match("^%d$") then
        local want = tonumber(key)
        if want and want >= 1 and count > 0 then
            if want > count then want = count end
            state.index = want
            state.selected_name = state.entries[want].name
            state.message = ""
            return "select"
        end
        return "none"
    end
    if key == "enter" or key == "return" then
        return M.launch_selected(state, api)
    end
    return "none"
end

-- ---------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------

function M.run(manifest, api, opts)
    local o = opts or {}
    local state = M.build(api, o)
    state.manifest = manifest
    local keys = o.keys
    local key_index = 0
    local frames = 0
    while true do
        local cols, rows = M.view_size(o.term)
        state.cols, state.rows = cols, rows
        M.refresh(state, api, o)
        local lines = M.render(state, cols, rows)
        if o.paint ~= false then M.paint(lines, o.term) end
        if type(o.each) == "function" then pcall(o.each, state, lines) end
        frames = frames + 1
        if o.max_frames and frames >= o.max_frames then break end
        local key = nil
        if type(keys) == "function" then
            key = keys()
        elseif type(keys) == "table" then
            key_index = key_index + 1
            key = keys[key_index]
        end
        if key then M.handle_key(state, key, api) end
        if api and type(api.yield) == "function" then api.yield() end
    end
    return state
end

-- ---------------------------------------------------------------------------
-- the resident desktop (D1): one delivered event at a time
-- ---------------------------------------------------------------------------

-- one line to the runtime's log, best effort: the harness api has no log
function M.note(api, text)
    if type(api) ~= "table" then return false end
    local log = api.log
    if type(log) ~= "function" then return false end
    return pcall(log, text)
end

-- The desktop owns the whole screen, so the first resident frame erases the
-- boot log behind it (the 26x20 view would otherwise sit on top of
-- STARTUP_COMMITTED and friends). A denied terminal answers with its stub.
function M.clear(term)
    local t = term or rawget(_G, "term")
    if type(t) ~= "table" or type(t.clear) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(t.clear))
end

-- refresh + render + paint in one call. The desktop paints only when something
-- it shows changed (one event, one frame), never in a timer loop: a 26x20
-- repaint per tick is exactly the storm the resident loop exists to avoid.
function M.paint_once(state, api, term)
    local cols, rows = M.view_size(term)
    state.cols, state.rows = cols, rows
    M.refresh(state, api, {})
    local lines = M.render(state, cols, rows)
    M.clear(term)
    M.paint(lines, term)
    state.painted = (state.painted or 0) + 1
    return lines
end

-- the keys that mean "back" -- and, on this desktop, "how do I leave".
M.ESCAPE_CODE = 256
M.QUIT_CODES = { [16] = true, [81] = true, [256] = true }

function M.quit_key(key, api)
    if type(key) == "number" then
        if M.QUIT_CODES[key] then return true end
        local name = M.code_name(key, api)
        if name ~= nil then key = name
        elseif key == M.ESCAPE_CODE then key = "escape"
        else return false end
    end
    if type(key) ~= "string" then return false end
    key = key:lower()
    return key == "q" or key == "escape" or key == "quit"
end

-- one normalized event in, one action out. The dispatcher delivers `key`
-- events with a key *name* ("up", "enter", "escape"), everything else raw; a
-- raw keycode is accepted as well and normalized through the ROM's keys table.
-- Returns "quit" when the desktop has to end, otherwise the handle_key action
-- ("move" | "select" | "launch" | "error" | "denied" | "repaint" | "none").
function M.dispatch_event(state, event, p1, p2, api)
    if event == "key" then
        if M.quit_key(p1, api) then
            -- back is not "leave the machine": say how to leave and stay here
            state.message = M.LEAVE_HINT
            M.note(api, "leave hint key=" .. tostring(p1) .. " scope=desktop")
            return "repaint"
        end
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        key = tostring(key == nil and "" or key)
        local action, detail = M.handle_key(state, key, api)
        M.note_key(api, state, key, action, detail)
        return action, detail
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1)
        if ch == "q" or ch == "Q" then
            state.message = M.LEAVE_HINT
            M.note(api, "leave hint char=" .. ch .. " scope=desktop")
            return "repaint"
        end
        if ch:match("^%d$") then
            local action, detail = M.handle_key(state, ch, api)
            M.note_key(api, state, ch, action, detail)
            return action, detail
        end
        return "none"
    end
    if event == "term_resize" then return "repaint" end
    -- the desktop hands the screen back (a screen loan just ended): show why and
    -- repaint now, because a loaned app that could not take the keyboard gives
    -- the launcher no other event to wake up on
    if event == "desk_focus" then
        state.message = tostring(p1 == nil and "desktop" or p1)
        M.note(api, "focus msg=" .. tostring(state.message))
        return "repaint"
    end
    return "none"
end

function M.note_key(api, state, key, action, detail)
    local entry = M.selected(state)
    local text = "key=" .. tostring(key) .. " action=" .. tostring(action)
        .. " index=" .. tostring(state.index) .. " sel="
        .. tostring(entry and entry.name or "-")
    if detail ~= nil then text = text .. " detail=" .. tostring(detail) end
    M.note(api, text)
end

-- no keyboard for this app (the capability was denied, or no host was supplied):
-- keep the painted frame current and stay resident without ever spinning. On a
-- real machine Ctrl+T still works, because the dispatcher handles `terminate`
-- itself and never asks an app about it.
function M.idle(api)
    while true do
        if type(api) == "table" and type(api.yield) == "function" then
            api.yield()
        else
            return "idle"
        end
    end
end

-- The resident entry body. It paints the desktop once, then consumes exactly
-- one delivered event per scheduler step; a scheduler step with nothing queued
-- costs one yield and no paint (`api.input.pullEvent()` answers nil).
function M.body(manifest, api)
    local state = M.build(api)
    state.manifest = manifest
    state.painted = 0
    local term = type(api) == "table" and api.terminal or nil
    local input = type(api) == "table" and api.input or nil
    local pull = type(input) == "table" and input.pullEvent or nil
    M.paint_once(state, api, term)
    M.note(api, "ready index=" .. tostring(state.index)
        .. " of=" .. tostring(#(state.entries or {})))
    if type(pull) ~= "function" then
        M.note(api, "no_input reason=no_host")
        return M.idle(api)
    end
    while true do
        local event, p1, p2 = pull()
        if event == nil then
            if p1 ~= nil then
                M.note(api, "no_input reason=" .. tostring(p1))
                return M.idle(api)
            end
            api.yield()
        else
            local action, detail = M.dispatch_event(state, event, p1, p2, api)
            if action == "quit" then
                M.note(api, "quit key=" .. tostring(detail))
                return "quit"
            end
            if action ~= "none" then M.paint_once(state, api, term) end
            api.yield()
        end
    end
end

-- ---------------------------------------------------------------------------
-- DECISIONS.md 7.2 self test: no terminal, no fs, pure layout rules
-- ---------------------------------------------------------------------------

function M.sample_state()
    return {
        cols = M.VIEW.cols,
        rows = M.VIEW.rows,
        entries = {
            { name = "launcher", version = "0.1.0" },
            { name = "net", version = "0.2.0" },
            { name = "settings", version = "0.1.0" },
        },
        index = 2,
        message = "",
        version = "1.0.0",
        sha256 = string.rep("ab", 32),
        net = "ok",
        free = 26214,
    }
end

function M.selftest()
    local problems = {}
    local state = M.sample_state()
    local function in_bounds(lines, cols, rows, where)
        if #lines ~= rows then
            problems[#problems + 1] = where .. " rows=" .. tostring(#lines)
        end
        for i = 1, #lines do
            if #lines[i] > cols then
                problems[#problems + 1] = where .. " row " .. tostring(i)
                    .. " width " .. tostring(#lines[i])
            end
        end
    end
    local full = M.render(state, M.VIEW.cols, M.VIEW.rows)
    in_bounds(full, M.VIEW.cols, M.VIEW.rows, "26x20")
    if not (full[1] or ""):find("ver 1.0.0 sha abababab", 1, true) then
        problems[#problems + 1] = "row 1 lost the version and the short hash"
    end
    if not (full[2] or ""):find("free 25K", 1, true) then
        problems[#problems + 1] = "row 2 lost the free space"
    end
    -- the slot era is gone: no row may carry the word again
    for i = 1, #full do
        if full[i]:find("slot", 1, true) then
            problems[#problems + 1] = "row " .. tostring(i) .. " still mentions a slot"
        end
    end
    if not (full[#full] or ""):find("3 apps sel 2/3", 1, true) then
        problems[#problems + 1] = "status row lost the selection"
    end
    -- narrow: the version column is dropped, not truncated mid-name
    local narrow = M.render(state, 20, 20)
    in_bounds(narrow, 20, 20, "20x20")
    if (narrow[3] or ""):find("0.1.0", 1, true) then
        problems[#problems + 1] = "20x20 kept the version column"
    end
    -- degenerate views collapse to one status line
    for _, size in ipairs({ { 10, 20 }, { 26, 4 }, { 1, 1 } }) do
        local cols, rows = size[1], size[2]
        local lines = M.render(state, cols, rows)
        if #lines ~= 1 then
            problems[#problems + 1] = tostring(cols) .. "x" .. tostring(rows)
                .. " expected a single status row, got " .. tostring(#lines)
        end
        if #(lines[1] or "") > cols then
            problems[#problems + 1] = tostring(cols) .. "x" .. tostring(rows)
                .. " status row too wide"
        end
    end
    -- an empty machine still renders
    local empty = M.build(nil, { cols = M.VIEW.cols, rows = M.VIEW.rows })
    local empty_lines = M.render(empty, M.VIEW.cols, M.VIEW.rows)
    in_bounds(empty_lines, M.VIEW.cols, M.VIEW.rows, "empty")
    if not (empty_lines[#empty_lines] or ""):find("0 apps sel 0/0", 1, true) then
        problems[#problems + 1] = "empty machine did not report 0 apps"
    end
    return #problems == 0, problems
end

M.layout_selftest = M.selftest

local function body(manifest, api)
    return M.body(manifest, api)
end

if rawget(_G, "PYROET_LAUNCHER_TEST") then
    return M
end

return body
