--[[- pyroet-os/system/installer.app/main.lua -- the Installer (26x20 UI).

What it does, and nothing else:

  1. scan the source medium /disk/apps for `<name>.app` packages -- a machine
     with no drive simply has no medium, which is a normal state and not an
     error -- and the two installed roots: /apps (user packages) and
     /system/system (the image's own packages, which can never be removed);
  2. show one list of tagged rows: `d` package on the medium, `i` installed
     under /apps, `s` shipped with the image;
  3. Enter on a `d` row installs it, Enter on an `i` row removes it, Enter on an
     `s` row is refused on screen (system packages only move through a system
     OTA, DECISIONS.md 1.2(c));
  4. print the outcome on the hint row: `installed <name> <version>`,
     `removed <name>`, or one of the failure lines `hash check failed`,
     `size check failed`, `cancelled`, `system app locked` ... (DECISIONS.md 17).

How the transaction happens: this package never implements the installer and
never loadfile()s a kernel module. It calls the host-supplied installer bridge
through the granted surface, in this order:

    opts.installer                        tests, or a host that wires it
    api.sys.install / api.sys.uninstall   a bridge on the system surface
    api.installer                         an installer object handed to the package

Each bridge function takes the package name and answers `true, info` or
`nil, err` -- exactly kernel/installer.lua's contract with the object bound away,
because an app that can loadfile() an image path can reach every module in the
image. Since T4 the kernel always carries install/uninstall/list on api.sys
(kernel/apps.lua implements them against the installer startup.lua built), so
"the kernel did not expose an installer" is no longer a state this package can
observe: M.bridge answers nil only when no bridge object was supplied at all, and
that -- a missing bridge -- is the one trigger for `installer unavailable`,
after which the app keeps running: a missing capability is a normal result, not a
crash (DECISIONS.md 4.2). A bridge that is present but refuses (`nil, "installer
unavailable"` from a machine with no installer instance) is reported through the
same single mapping, M.error_text.

Input: the runtime has no input capability (DECISIONS.md 9.7), so keys are a pure
function of the state -- `M.handle_key(state, key, api, opts)` -- and `M.run`
pulls them from `opts.keys`. Up/down (or left/right) move, a digit jumps, enter
or return applies, escape or q or c cancels the line on screen.

Layout (DECISIONS.md 7.2): row 1 the app version, row 2 the medium and the
installed count, rows 3..n-2 the list, row n-1 the hint (or one message), row n
the counters. Every line is padded or truncated to the view width and never
wider. Under 16 columns or 6 rows the view collapses to a single status line --
`layout_selftest` proves both rules without a terminal.

Test hooks (real boots never set them): _G.PYROET_INSTALLER_TEST returns the
module instead of the entry body, _G.PYROET_APP_NOPAINT skips painting.

No non-ASCII bytes in this file.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 26, rows = 20 }
M.MIN_COLS = 16
M.MIN_ROWS = 6
M.MEDIUM = "/disk/apps"        -- packages on the source medium
M.APPS = "/apps"               -- installed user packages
M.SYSTEM = "/system/system"    -- packages that ship with the image
M.HINT = "up/dn enter apply"
M.SCAN_INTERVAL = 10
M.SOURCES = { "disk", "apps", "system" }

-- ---------------------------------------------------------------------------
-- small pure helpers
-- ---------------------------------------------------------------------------

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

-- one clean line out of anything the host or a log handed back
function M.plain(text, max)
    max = max or 40
    local s = tostring(text == nil and "" or text):gsub("[\r\n\t]+", " ")
        :gsub("[^\32-\126]", "?")
    if #s > max then s = s:sub(1, max) end
    return s
end

-- fs.read is a capability: a denial is a normal result, never a crash
function M.read_file(api, path)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.read) ~= "function" then
        return nil, "capability denied: fs.read"
    end
    local called, text, err = pcall(fsx.read, path)
    if not called then return nil, tostring(text) end
    if text == nil then return nil, tostring(err or "missing") end
    return tostring(text), nil
end

-- Peek at a package's declared version without running anything from the
-- medium: executing a package's manifest before the installer validated it is
-- exactly the thing a package manager must not do. A value this cannot read is
-- "?" and nothing else happens.
function M.manifest_version(api, dir)
    local text = M.read_file(api, dir .. "/manifest.lua")
    if type(text) ~= "string" then return "?" end
    local version = text:match('version%s*=%s*"([^"\r\n]+)"')
    if version == nil or version == "" or #version > 24 then return "?" end
    if version:find("[^\32-\126]") then return "?" end
    return version
end

function M.key_of(entry)
    if type(entry) ~= "table" then return nil end
    return tostring(entry.source) .. ":" .. tostring(entry.name)
end

function M.tag_of(entry)
    if type(entry) ~= "table" then return "?" end
    if entry.source == "disk" then return "d" end
    if entry.source == "system" then return "s" end
    return "i"
end

-- what Enter means on this row
function M.action_of(entry)
    if type(entry) ~= "table" then return "none" end
    if entry.source == "disk" then return "install" end
    if entry.source == "system" then return "locked" end
    return "remove"
end

-- ---------------------------------------------------------------------------
-- reading the machine
-- ---------------------------------------------------------------------------

-- versions and states of the packages the runtime already loaded; a package the
-- runtime refused still gets a row, with version "?"
function M.versions(api)
    local index = {}
    local sys = type(api) == "table" and api.sys or nil
    if type(sys) ~= "table" or type(sys.apps) ~= "function" then return index end
    local called, list = pcall(sys.apps)
    if not called or type(list) ~= "table" then return index end
    for i = 1, #list do
        local item = list[i]
        if type(item) == "table" and type(item.name) == "string" then
            index[item.name] = item
        end
    end
    return index
end

-- `dir`'s entries, sorted, or nil plus the reason when it cannot be read at all
local function listing(api, path)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.list) ~= "function" then
        return nil, "capability denied: fs.read"
    end
    local called, names, reason = pcall(fsx.list, path)
    if not called then return nil, tostring(names) end
    if type(names) ~= "table" then return nil, reason end
    local sorted = {}
    for i = 1, #names do sorted[#sorted + 1] = tostring(names[i]) end
    table.sort(sorted)
    return sorted
end

-- a capability refusal is worth naming on screen; a missing directory is not
local function describe(reason, fallback)
    local text = type(reason) == "string" and reason or ""
    if text:find("capability denied", 1, true) then return text end
    if text:find("capability unavailable", 1, true) then return text end
    return fallback
end

local function has_manifest(api, dir)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.exists) ~= "function" then return true end
    local called, found = pcall(fsx.exists, dir .. "/manifest.lua")
    return called and found == true
end

-- Every row the screen can show, in one pass. Returns entries, problems and
-- whether a medium was readable: a missing drive is `disk_ok=false`, a refused
-- fs.read is a problem line, and neither one raises.
function M.scan(api, opts)
    local o = opts or {}
    local medium = o.medium or M.MEDIUM
    local roots = {
        { root = o.apps or M.APPS, source = "apps" },
        { root = o.system or M.SYSTEM, source = "system" },
    }
    local entries, problems, seen = {}, {}, {}
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.list) ~= "function" then
        return entries, { "capability denied: fs.read" }, false
    end
    local index = M.versions(api)

    local names, medium_reason = listing(api, medium)
    local disk_ok = names ~= nil
    if not disk_ok then
        problems[#problems + 1] = describe(medium_reason, "no disk")
    else
        for i = 1, #names do
            local dir_name = names[i]
            if dir_name:sub(-4) == ".app" then
                local app = dir_name:sub(1, #dir_name - 4)
                local dir = medium .. "/" .. dir_name
                if not has_manifest(api, dir) then
                    problems[#problems + 1] = "no manifest " .. app
                elseif seen[app] then
                    problems[#problems + 1] = "duplicate " .. app
                else
                    seen[app] = true
                    entries[#entries + 1] = {
                        name = app, dir = dir, root = medium, source = "disk",
                        version = M.manifest_version(api, dir),
                    }
                end
            end
        end
    end

    for r = 1, #roots do
        local root, source = roots[r].root, roots[r].source
        local list, root_reason = listing(api, root)
        if list == nil then
            problems[#problems + 1] = describe(root_reason,
                "no root " .. tostring(root))
        else
            for i = 1, #list do
                local dir_name = list[i]
                if dir_name:sub(-4) == ".app" then
                    local app = dir_name:sub(1, #dir_name - 4)
                    local dir = root .. "/" .. dir_name
                    if not has_manifest(api, dir) then
                        problems[#problems + 1] = "no manifest " .. app
                    else
                        local record = index[app]
                        entries[#entries + 1] = {
                            name = app, dir = dir, root = root, source = source,
                            version = type(record) == "table"
                                and tostring(record.version or "?") or "?",
                            state = type(record) == "table" and record.state or nil,
                        }
                    end
                end
            end
        end
    end

    -- medium first, then the user root, then the image: the on-screen order is
    -- the order of the three questions a user actually asks
    local RANK = { disk = 1, apps = 2, system = 3 }
    table.sort(entries, function(a, b)
        local ra, rb = RANK[a.source] or 9, RANK[b.source] or 9
        if ra ~= rb then return ra < rb end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.dir) < tostring(b.dir)
    end)
    return entries, problems, disk_ok
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
        version = o.version or "?",
        medium = o.medium or M.MEDIUM,
        apps_root = o.apps or M.APPS,
        system_root = o.system or M.SYSTEM,
        scan_interval = o.scan_interval or M.SCAN_INTERVAL,
        disk_ok = false,
        disk_count = 0,
        apps_count = 0,
        sys_count = 0,
        scanned = 0,
        frames = 0,
    }
    return M.refresh(state, api, o)
end

function M.selected(state)
    return (state.entries or {})[state.index or 0]
end

function M.refresh(state, api, opts)
    local o = opts or {}
    state.frames = (state.frames or 0) + 1
    local interval = o.scan_interval or state.scan_interval or M.SCAN_INTERVAL
    local want = (state.scanned or 0) == 0 or o.force_scan == true
        or (interval > 0 and (state.frames % interval) == 0)
    if want then
        -- the selection follows the package, not the row number: installing an
        -- app inserts a row and must not move the cursor somewhere else
        local keep = state.selected_key
        if not keep then
            local current = M.selected(state)
            keep = current and M.key_of(current) or nil
        end
        local entries, problems, disk_ok = M.scan(api, o)
        state.entries = entries
        state.problems = problems or {}
        state.disk_ok = disk_ok == true
        state.scanned = (state.scanned or 0) + 1
        local index = nil
        if keep then
            for i = 1, #entries do
                if M.key_of(entries[i]) == keep then index = i break end
            end
        end
        local position = index or state.index or 1
        if position > #entries then position = math.max(1, #entries) end
        if position < 1 then position = 1 end
        state.index = position
        local selected = entries[position]
        state.selected_key = selected and M.key_of(selected) or nil
        state.disk_count, state.apps_count, state.sys_count = 0, 0, 0
        for i = 1, #entries do
            local source = entries[i].source
            if source == "disk" then
                state.disk_count = state.disk_count + 1
            elseif source == "system" then
                state.sys_count = state.sys_count + 1
            else
                state.apps_count = state.apps_count + 1
            end
        end
    end
    return state
end

-- ---------------------------------------------------------------------------
-- the installer bridge (see the header for the order and the contract)
-- ---------------------------------------------------------------------------

-- The surface functions this package accepts as a bridge. A T4 kernel exposes
-- all three on api.sys; a host that wires only uninstall is still a bridge (the
-- call site says which function it needs).
M.BRIDGE_FUNCTIONS = { "install", "uninstall", "list" }

-- returns bridge, nil -- or nil, "installer unavailable" when no object was
-- supplied at all. `nil` is the *only* trigger for that message: exposure by the
-- kernel is no longer something this package has to detect (T4).
function M.bridge(api, opts)
    local o = opts or {}
    if type(o.installer) == "table" then return o.installer, nil end
    local sys = type(api) == "table" and api.sys or nil
    if type(sys) == "table" then
        for i = 1, #M.BRIDGE_FUNCTIONS do
            if type(sys[M.BRIDGE_FUNCTIONS[i]]) == "function" then return sys, nil end
        end
    end
    local direct = type(api) == "table" and api.installer or nil
    if type(direct) == "table" then
        for i = 1, #M.BRIDGE_FUNCTIONS do
            if type(direct[M.BRIDGE_FUNCTIONS[i]]) == "function" then return direct, nil end
        end
    end
    return nil, "installer unavailable"
end

-- Map whatever the installer answered onto the one line the screen has room for.
-- The class is returned too so a test (and the key handler) can act on it
-- without re-parsing the message.
function M.error_text(err)
    local text = M.plain(err, 40)
    local low = text:lower()
    if low == "" then return "install failed", "error" end
    if low:find("cancel", 1, true) then return "cancelled", "cancel" end
    if low:find("no_source", 1, true) then return "cancelled: no source", "cancel" end
    if low:find("capability denied", 1, true) then
        return low:find("fs.write", 1, true) and "capability denied: fs.write"
            or "capability denied", "denied"
    end
    if low:find("digest", 1, true) or low:find("sums", 1, true)
        or low:find("sha256", 1, true) or low:find("hash", 1, true)
        or low:find("unlisted", 1, true) then
        return "hash check failed", "hash"
    end
    if low:find("size", 1, true) then return "size check failed", "size" end
    if low:find("unavailable", 1, true) then return "installer unavailable", "unavailable" end
    if low:find("system app", 1, true) or low == "system" then
        return "system app locked", "locked"
    end
    if low:find("not installed", 1, true) then return "not installed", "missing" end
    return "failed: " .. text, "error"
end

local ACTION = {
    cancel = "cancel", hash = "hash", size = "size", locked = "locked",
    denied = "denied", missing = "missing", unavailable = "unavailable",
    error = "error",
}

function M.install_selected(state, api, opts)
    local entry = M.selected(state)
    if not entry then
        state.message = "nothing selected"
        return "none"
    end
    if entry.source ~= "disk" then
        state.message = "already installed"
        return "none"
    end
    local bridge = M.bridge(api, opts)
    if not bridge or type(bridge.install) ~= "function" then
        state.message = "installer unavailable"
        return "unavailable"
    end
    local called, ok, detail = pcall(bridge.install, entry.name)
    state.last_error = nil
    if not called then
        state.message = "install failed"
        state.last_error = M.plain(ok, 60)
        return "error", state.last_error
    end
    if ok then
        local version = type(detail) == "table" and tostring(detail.version or "?")
            or tostring(entry.version or "?")
        state.message = "installed " .. entry.name .. " " .. version
        state.installed = entry.name
        M.refresh(state, api, { force_scan = true, medium = state.medium,
            apps = state.apps_root, system = state.system_root,
            scan_interval = state.scan_interval })
        return "install", entry.name
    end
    local text, class = M.error_text(detail)
    state.message = text
    state.last_error = M.plain(detail, 60)
    return ACTION[class] or "error", state.last_error
end

function M.remove_selected(state, api, opts)
    local entry = M.selected(state)
    if not entry then
        state.message = "nothing selected"
        return "none"
    end
    if entry.source == "system" then
        -- an image package leaves only through a system OTA (DECISIONS 1.2(c))
        state.message = "system app locked"
        return "locked"
    end
    if entry.source ~= "apps" then
        state.message = "not installed"
        return "missing"
    end
    local bridge = M.bridge(api, opts)
    if not bridge or type(bridge.uninstall) ~= "function" then
        state.message = "installer unavailable"
        return "unavailable"
    end
    local called, ok, detail = pcall(bridge.uninstall, entry.name)
    state.last_error = nil
    if not called then
        state.message = "remove failed"
        state.last_error = M.plain(ok, 60)
        return "error", state.last_error
    end
    if ok then
        state.message = "removed " .. entry.name
        state.removed = entry.name
        M.refresh(state, api, { force_scan = true, medium = state.medium,
            apps = state.apps_root, system = state.system_root,
            scan_interval = state.scan_interval })
        return "remove", entry.name
    end
    local text, class = M.error_text(detail)
    state.message = text
    state.last_error = M.plain(detail, 60)
    return ACTION[class] or "error", state.last_error
end

-- what Enter does on the selected row
function M.activate(state, api, opts)
    local entry = M.selected(state)
    if not entry then
        state.message = "nothing selected"
        return "none"
    end
    local action = M.action_of(entry)
    if action == "install" then return M.install_selected(state, api, opts) end
    if action == "locked" then
        state.message = "system app locked"
        return "locked"
    end
    if action == "remove" then return M.remove_selected(state, api, opts) end
    state.message = "nothing to do"
    return "none"
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

function M.header_lines(state)
    local installed = (state.apps_count or 0) + (state.sys_count or 0)
    return {
        "installer " .. tostring(state.version or "?"),
        "disk " .. (state.disk_ok and "ok" or "none") .. " "
            .. tostring(installed) .. " installed",
    }
end

-- full width keeps a version column; a narrow view drops it and stays a single
-- column list instead of truncating the names away
function M.row_text(state, entry, position, cols)
    local marker = (position == state.index) and ">" or " "
    local tag = M.tag_of(entry)
    if cols >= M.VIEW.cols then
        local version = tostring(entry.version or "?")
        local pad = cols - 4 - #entry.name - #version
        if pad >= 1 then
            return marker .. " " .. tag .. " " .. entry.name
                .. string.rep(" ", pad) .. version
        end
        return marker .. " " .. tag .. " " .. entry.name .. " " .. version
    end
    return marker .. " " .. tag .. " " .. entry.name
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
    local count = #(state.entries or {})
    if count == 0 then
        -- a refused capability is the one problem worth naming on screen
        local problems = state.problems or {}
        for i = 1, #problems do
            local text = tostring(problems[i]):lower()
            if text:find("denied", 1, true) or text:find("unavailable", 1, true) then
                return M.plain(problems[i], 26)
            end
        end
        if not state.disk_ok then return "no disk, no apps" end
        return "no apps to install"
    end
    local entry = M.selected(state)
    if not entry then return M.HINT end
    local action = M.action_of(entry)
    if action == "install" then return "enter install" end
    if action == "locked" then return "system app locked" end
    if action == "remove" then return "enter remove" end
    return M.HINT
end

function M.status_line(state, cols)
    local disk = state.disk_count or 0
    local apps = state.apps_count or 0
    local sys = state.sys_count or 0
    local total = disk + apps + sys
    local index = total == 0 and 0 or (state.index or 0)
    return M.fit("d" .. disk .. " i" .. apps .. " s" .. sys
        .. " sel " .. index .. "/" .. total, cols)
end

function M.compact_line(state, cols, rows)
    local count = #(state.entries or {})
    return M.fit("installer " .. tostring(count) .. " items "
        .. tostring(cols) .. "x" .. tostring(rows), cols)
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
-- input
-- ---------------------------------------------------------------------------

local UP = { up = true, left = true }
local DOWN = { down = true, right = true }
local CANCEL = { escape = true, q = true, c = true }

-- pure key handling: one key in, one action out. Returns
-- "move"|"select"|"install"|"remove"|"cancel"|"locked"|"hash"|"size"|
-- "unavailable"|"missing"|"error"|"none" and, when something was applied, the
-- package name (or the installer's own error string).
function M.handle_key(state, key, api, opts)
    local count = #(state.entries or {})
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
        state.selected_key = M.key_of(state.entries[state.index])
        state.message = ""
        return "move"
    end
    if key:match("^%d$") then
        local want = tonumber(key)
        if want and want >= 1 and count > 0 then
            if want > count then want = count end
            state.index = want
            state.selected_key = M.key_of(state.entries[want])
            state.message = ""
            return "select"
        end
        return "none"
    end
    if key == "enter" or key == "return" then
        return M.activate(state, api, opts)
    end
    if CANCEL[key] then
        state.message = "cancelled"
        return "cancel"
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
    if type(manifest) == "table" and manifest.version then
        state.version = tostring(manifest.version)
    else
        state.version = M.VERSION
    end
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
        if key then M.handle_key(state, key, api, o) end
        if api and type(api.yield) == "function" then api.yield() end
    end
    return state
end

-- ---------------------------------------------------------------------------
-- DECISIONS.md 7.2 self test: no terminal, no fs, pure layout rules
-- ---------------------------------------------------------------------------

function M.sample_state()
    return {
        cols = M.VIEW.cols,
        rows = M.VIEW.rows,
        entries = {
            { name = "box", source = "disk", version = "0.2.0" },
            { name = "launcher", source = "apps", version = "0.1.0" },
            { name = "settings", source = "system", version = "0.1.0" },
        },
        index = 1,
        message = "",
        problems = {},
        version = "0.1.0",
        disk_ok = true,
        disk_count = 1,
        apps_count = 1,
        sys_count = 1,
    }
end

function M.selftest()
    local problems = {}
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
    local state = M.sample_state()
    local full = M.render(state, M.VIEW.cols, M.VIEW.rows)
    in_bounds(full, M.VIEW.cols, M.VIEW.rows, "26x20")
    if not (full[1] or ""):find("installer 0.1.0", 1, true) then
        problems[#problems + 1] = "row 1 lost the version"
    end
    if not (full[2] or ""):find("disk ok 2 installed", 1, true) then
        problems[#problems + 1] = "row 2 lost the medium or the installed count"
    end
    if (full[3] or ""):sub(1, 4) ~= "> d " then
        problems[#problems + 1] = "row 3 is not the selected medium row"
    end
    if not (full[19] or ""):find("enter install", 1, true) then
        problems[#problems + 1] = "the hint row lost the install action"
    end
    if not (full[20] or ""):find("d1 i1 s1 sel 1/3", 1, true) then
        problems[#problems + 1] = "the counter row lost the selection"
    end
    -- the three tags are distinct, so the row kinds are readable without colour
    local tags = (full[3] or ""):sub(3, 3) .. (full[4] or ""):sub(3, 3)
        .. (full[5] or ""):sub(3, 3)
    if tags ~= "dis" then
        problems[#problems + 1] = "row tags are " .. tostring(tags)
    end
    -- narrow: the version column is dropped, not truncated mid-name
    local narrow = M.render(state, 20, 20)
    in_bounds(narrow, 20, 20, "20x20")
    if (narrow[3] or ""):find("0.2.0", 1, true) then
        problems[#problems + 1] = "20x20 kept the version column"
    end
    if not (narrow[3] or ""):find("box", 1, true) then
        problems[#problems + 1] = "20x20 dropped the package name"
    end
    -- degenerate views collapse to one status line
    for _, size in ipairs({ { 10, 20 }, { 26, 4 }, { 1, 1 }, { 15, 5 } }) do
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
    -- an empty machine still renders, and says which kind of empty it is
    local empty = {
        cols = M.VIEW.cols, rows = M.VIEW.rows, entries = {}, index = 1,
        problems = {}, message = "", version = "0.1.0", disk_ok = false,
        disk_count = 0, apps_count = 0, sys_count = 0,
    }
    local empty_lines = M.render(empty, M.VIEW.cols, M.VIEW.rows)
    in_bounds(empty_lines, M.VIEW.cols, M.VIEW.rows, "empty")
    if not (empty_lines[19] or ""):find("no disk, no apps", 1, true) then
        problems[#problems + 1] = "an empty machine did not say why it is empty"
    end
    if not (empty_lines[20] or ""):find("d0 i0 s0 sel 0/0", 1, true) then
        problems[#problems + 1] = "an empty machine did not report zero counters"
    end
    -- a machine with no runtime at all: the refusal is named, not a crash
    local denied = M.build(nil, { cols = M.VIEW.cols, rows = M.VIEW.rows })
    local denied_lines = M.render(denied, M.VIEW.cols, M.VIEW.rows)
    in_bounds(denied_lines, M.VIEW.cols, M.VIEW.rows, "denied")
    if not (denied_lines[19] or ""):find("capability denied", 1, true) then
        problems[#problems + 1] = "a refused fs.read was not named on screen"
    end
    -- a disk with nothing installable on it
    local bare = {
        cols = M.VIEW.cols, rows = M.VIEW.rows, entries = {}, index = 1,
        problems = {}, message = "", version = "0.1.0", disk_ok = true,
        disk_count = 0, apps_count = 0, sys_count = 0,
    }
    local bare_lines = M.render(bare, M.VIEW.cols, M.VIEW.rows)
    if not (bare_lines[19] or ""):find("no apps to install", 1, true) then
        problems[#problems + 1] = "an empty medium did not say there is nothing to install"
    end
    return #problems == 0, problems
end

M.layout_selftest = M.selftest

local function body(manifest, api)
    return M.run(manifest, api)
end

if rawget(_G, "PYROET_INSTALLER_TEST") then
    return M
end

return body
