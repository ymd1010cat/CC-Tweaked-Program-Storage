--[[- pyroet-os/system/settings.app/main.lua -- Settings: a read only view (26x20 UI).

What it shows, all of it read from files or from the host's read-only system
surface (never written back):

    system   Pyroet OS version, image version and the first eight hex digits of
             the global /boot.ok manifest_sha (one system tree, no slot), net
             health
    apps     every app the runtime knows: name, version, and one line per
             declared capability with its decision -- granted / denied /
             pending (no decision file yet)
    conf     the key items of /etc/network.conf: one `key value` line per entry,
             with anything named like a secret (psk, pass, secret, key, token)
             replaced by *** before it ever reaches the screen
    storage  free space, the three size gates of DECISIONS.md 8.4 (hard gate
             629,145 B = 3/5 MiB, target line 349,525 B = 1/3 MiB, update
             window 900,000 B = image + backup cap), and how many entries
             /etc/install.set lists when the image ships that file

Strictly read only: the module has no write path at all, the manifest declares
only `fs.read`, and the offline suite drives it with an instrumented file system
that fails any write/append/delete/makeDir call. A missing file degrades to a
`n/a` line; it never raises, so a settings screen is always shown.

Layout (DECISIONS.md 7.2): row 1 title, rows 2..n-1 body with a `+N more` line
when the body does not fit, row n the status line (`ro <n> apps <cols>x<rows>`).
Every line is padded or truncated to the view width. Under 16 columns or 6 rows
the whole body collapses to one status line -- `layout_selftest` proves it.

Test hooks (real boots never set them): _G.PYROET_SETTINGS_TEST returns the
module instead of the entry body, _G.PYROET_APP_NOPAINT skips painting.

No non-ASCII bytes in this file.
]]

local M = {}

M.HINT = "up/dn enter q=back"
M.VERSION = "0.2.0"
M.VIEW = { cols = 26, rows = 20 }
M.MIN_COLS = 16
M.MIN_ROWS = 6
M.BOOT_OK = "/boot.ok"
M.CONF_PATH = "/etc/network.conf"
M.INSTALL_SET = "/etc/install.set"
M.CONF_LINES = 6
-- DECISIONS.md 8.4, three tiers: hard gate (3/5 MiB), target line (1/3 MiB),
-- and the update window (image + BACKUP_CAP 200,000). The gate tool
-- pyroet-os/tools/sizecheck.py is the only authority for the first two.
M.BUDGET = 629145
M.STRETCH = 349525
M.WINDOW = 900000
M.BACKUP_CAP = 200000
M.SECRET_KEYS = { "psk", "pass", "secret", "key", "token" }

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

-- ---------------------------------------------------------------------------
-- reading (fs.read only, every refusal is a value, never an error)
-- ---------------------------------------------------------------------------

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

-- the global commit marker the single-tree boot chain writes:
-- `PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..`; there is no slot pointer
-- and no per-slot descriptor to consult.
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

function M.read_net(api)
    local sys = api and api.sys
    if type(sys) ~= "table" or type(sys.status) ~= "function" then
        return "off", "system unavailable: status"
    end
    local called, status = pcall(sys.status)
    if not called or type(status) ~= "table" then return "off", tostring(status) end
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

-- every app the runtime loaded, plus its decisions; a runtime that supplies no
-- system surface is reported as "apps n/a" instead of being indexed
function M.read_apps(api)
    local sys = api and api.sys
    if type(sys) ~= "table" or type(sys.apps) ~= "function" then
        return {}, "system unavailable: apps"
    end
    local called, list = pcall(sys.apps)
    if not called or type(list) ~= "table" then
        return {}, tostring(list)
    end
    local copy = {}
    for i = 1, #list do
        if type(list[i]) == "table" then copy[#copy + 1] = list[i] end
    end
    table.sort(copy, function(a, b)
        return tostring(a.name) < tostring(b.name)
    end)
    local apps = {}
    for i = 1, #copy do
        local item = copy[i]
        local app = {
            name = tostring(item.name or "?"),
            version = tostring(item.version or "?"),
            state = tostring(item.state or "?"),
            capabilities = item.capabilities or {},
            grants = nil,
        }
        if type(sys.perms) == "function" then
            local pcalled, decisions = pcall(sys.perms, app.name)
            if pcalled and type(decisions) == "table" then app.grants = decisions end
        end
        apps[#apps + 1] = app
    end
    return apps, nil
end

-- `key=value` lines; `#` comments and blank lines are dropped, a malformed line
-- is counted (shown as "bad conf lines N") rather than pretending it parsed
function M.parse_conf(text)
    local entries, bad = {}, 0
    local number, pos = 0, 1
    local body = type(text) == "string" and text or ""
    while pos <= #body do
        local stop = body:find("[\r\n]", pos)
        local line
        if stop then
            line = body:sub(pos, stop - 1)
            pos = stop + 1
            if body:sub(pos, pos) == "\n" and body:sub(stop, stop) == "\r" then
                pos = pos + 1
            end
        else
            line = body:sub(pos)
            pos = #body + 1
        end
        number = number + 1
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local key, value = trimmed:match("^([%w%._%-]+)%s*=%s*(.-)%s*$")
            if key then
                entries[#entries + 1] = { key = key, value = value, line = number }
            else
                bad = bad + 1
            end
        end
    end
    return entries, bad
end

-- a secret never reaches the screen: the key name decides, not the caller
function M.redacted(key, value)
    local lowered = tostring(key):lower()
    for i = 1, #M.SECRET_KEYS do
        if lowered:find(M.SECRET_KEYS[i], 1, true) then return "***" end
    end
    return tostring(value)
end

function M.read_conf(api, path)
    local text, err = M.read_file(api, path or M.CONF_PATH)
    if text == nil then return {}, 0, tostring(err) end
    local entries, bad = M.parse_conf(text)
    local out = {}
    for i = 1, #entries do
        out[#out + 1] = {
            key = entries[i].key,
            value = M.redacted(entries[i].key, entries[i].value),
            line = entries[i].line,
        }
    end
    return out, bad, nil
end

-- how many entries /etc/install.set lists; the size gate itself lives in
-- tools/sizecheck.py, this is only a sanity number for the screen
function M.read_install_set(api)
    local text = M.read_file(api, M.INSTALL_SET)
    if type(text) ~= "string" then return nil end
    local count = 0
    for raw in tostring(text):gmatch("[^\r\n]+") do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then count = count + 1 end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

function M.build(api, opts)
    local o = opts or {}
    local state = {
        cols = o.cols or M.VIEW.cols,
        rows = o.rows or M.VIEW.rows,
        version = "?",
        sha256 = nil,
        boot_source = nil,
        net = "?",
        net_reason = nil,
        free = nil,
        apps = {},
        apps_error = nil,
        conf = {},
        bad_conf = 0,
        conf_error = nil,
        install_entries = nil,
        conf_path = o.conf_path or M.CONF_PATH,
        item = 1,
        message = "",
        frames = 0,
    }
    return M.refresh(state, api, o)
end

function M.refresh(state, api, opts)
    local o = opts or {}
    state.frames = (state.frames or 0) + 1
    local boot = M.read_boot(api)
    state.version = boot.version or "?"
    state.sha256 = boot.sha256
    state.boot_source = boot.source
    local net, reason = M.read_net(api)
    state.net = net
    state.net_reason = reason
    state.free = M.read_free(api)
    local apps, apps_error = M.read_apps(api)
    state.apps = apps
    state.apps_error = apps_error
    local conf, bad, conf_error = M.read_conf(api, state.conf_path or o.conf_path)
    state.conf = conf
    state.conf_missing = (#conf == 0)
    state.bad_conf = bad or 0
    state.conf_error = conf_error
    state.install_entries = M.read_install_set(api)
    return state
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- the full body, untruncated: render() is what fits it to the screen, tests can
-- read every line here without guessing at an offset
function M.sections(state)
    local out = {}
    local function add(text) out[#out + 1] = tostring(text) end
    add("=== system ===")
    add("os " .. M.VERSION)
    local image = "image " .. tostring(state.version or "?")
    local short = M.short_sha(state.sha256)
    if short then image = image .. " sha " .. short end
    add(image)
    add("net " .. tostring(state.net or "?"))
    add("=== apps ===")
    local apps = state.apps or {}
    if #apps == 0 then
        -- fixed wording on purpose: a screen that cannot read the app index has
        -- to say something stable, the raw reason stays in state.apps_error
        add("apps n/a")
    else
        for i = 1, #apps do
            local app = apps[i]
            add(app.name .. " " .. app.version)
            local caps = app.capabilities or {}
            if #caps == 0 then
                add("  no capabilities")
            else
                for j = 1, #caps do
                    local cap = caps[j]
                    local granted = app.grants and app.grants[cap]
                    local text = "pending"
                    if granted == true then text = "granted" end
                    if granted == false then text = "denied" end
                    add("  " .. tostring(cap) .. " " .. text)
                end
            end
        end
    end
    add("=== conf ===")
    local conf = state.conf or {}
    if #conf == 0 then
        add("conf n/a")
    else
        local shown = 0
        for i = 1, #conf do
            if shown >= M.CONF_LINES then
                add("+" .. tostring(#conf - shown) .. " more")
                break
            end
            add(conf[i].key .. " " .. conf[i].value)
            shown = shown + 1
        end
        if #conf <= M.CONF_LINES and (state.bad_conf or 0) > 0 then
            add("bad conf lines " .. tostring(state.bad_conf))
        end
    end
    add("=== storage ===")
    add("free " .. (state.free and (tostring(state.free) .. " B") or "n/a"))
    add("gate " .. tostring(M.BUDGET) .. " B")
    add("target " .. tostring(M.STRETCH) .. " B")
    add("window " .. tostring(M.WINDOW) .. " B")
    add("backup cap " .. tostring(M.BACKUP_CAP) .. " B")
    if state.install_entries then
        add("install.set " .. tostring(state.install_entries) .. " entries")
    else
        add("install.set n/a")
    end
    return out
end

function M.status_line(state, cols, rows)
    local text = "ro " .. tostring(#(state.apps or {})) .. " apps "
        .. tostring(cols) .. "x" .. tostring(rows) .. " q=back"
    return M.fit(text, cols)
end

function M.compact_line(state, cols, rows)
    return M.fit("settings ro " .. tostring(#(state.apps or {})) .. " apps "
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
    if state.perms then return M.perms_lines(state, cols, rows) end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("Settings " .. M.VERSION)
    -- the editable rows (D1-fix round 3): one line per config key, `>` on the
    -- selected one, and the hint row right under them
    -- T17: the whole page is a scrolling window, never a "+N more" cut. The
    -- selected item is always kept inside the window; `^`/`v` say which way
    -- there is more, and the hint row carries `items i/N`.
    local items = M.items(state)
    local lines = {}
    if #items == 0 then
        lines[#lines + 1] = "no editable settings"
        lines[#lines + 1] = "need " .. M.conf_path(state)
    else
        for i = 1, #items do
            local item = items[i]
            local marker = (i == (state.item or 1)) and ">" or " "
            lines[#lines + 1] = marker .. " " .. item.label .. " " .. item.value
        end
    end
    local body = M.sections(state)
    for i = 1, #body do lines[#lines + 1] = body[i] end
    if state.message and state.message ~= "" then lines[#lines + 1] = state.message end
    local visible = math.max(1, rows - 3) -- title + hint + status
    local count = #lines
    local max_first = math.max(1, count - visible + 1)
    local selected = math.min(#items, math.max(1, state.item or 1))
    local first = math.min(math.max(1, state.scroll or 1), max_first)
    if selected >= 1 and selected <= #items then
        if selected < first then first = selected end
        if selected > first + visible - 1 then first = selected - visible + 1 end
        if first > max_first then first = max_first end
        if first < 1 then first = 1 end
    end
    state.scroll = first
    for i = first, first + visible - 1 do
        add(lines[i] or "")
    end
    -- the scroll indicators: `^` above and `v` below when the window is inside
    if first > 1 then
        out[2] = M.fit("^", cols)
    end
    if first + visible - 1 < count then
        out[#out] = M.fit("v", cols)
    end
    add(M.HINT)
    add(M.status_line(state, cols, rows))
    return out
end

-- ---------------------------------------------------------------------------
-- Permissions (permissions rule 6): the Android app-permissions screen
-- ---------------------------------------------------------------------------
--
-- Level 1 lists every scanned package; level 2 its capabilities with the state on
-- disk -- `granted`, `denied`, or `ask` (no line yet). Enter toggles
-- granted/denied through api.sys.perms_set (an `ask` becomes granted: the same act
-- as answering A); `q` goes back one level and leaves Settings at level 1.
M.PERMS_TITLE = "Permissions"
M.PERMS_OPEN_HINT = "enter=open q=back"
M.PERMS_CAP_HINT = "enter=toggle q=back"

-- level 1: read the package list (api.sys.perms_list) and keep it in the state
function M.perms_refresh(state, api)
    local p = state.perms
    local sysax = type(api) == "table" and api.sys or nil
    local list = type(sysax) == "table" and sysax.perms_list or nil
    if type(list) ~= "function" then
        p.message = "no permission bridge"
        return nil
    end
    local called, ok, apps = pcall(list)
    if not called or ok ~= true then
        p.message = "permissions unavailable"
        M.note(api, "perms list failed err=" .. M.fit(tostring(called and apps or ok), 40))
        return nil
    end
    p.apps = {}
    for i = 1, #(apps or {}) do p.apps[#p.apps + 1] = apps[i] end
    return p.apps
end

function M.perms_open(state, api)
    state.perms = { level = 1, index = 1, apps = {}, caps = {}, message = "" }
    M.perms_refresh(state, api)
    M.note(api, "perms open apps=" .. tostring(#(state.perms.apps or {})))
    return "repaint"
end

function M.perms_close(state, api)
    state.perms = nil
    state.message = ""
    M.note(api, "perms close")
    return "repaint"
end

-- the row the arrow keys act on, for the current level
function M.perms_count(state)
    local p = state.perms
    if type(p) ~= "table" then return 0 end
    if p.level == 1 then return #(p.apps or {}) end
    return #(p.caps or {})
end

function M.perms_move(state, delta)
    local count = M.perms_count(state)
    if count == 0 then return "none" end
    local index = (state.perms.index or 1) + delta
    if index < 1 then index = count end
    if index > count then index = 1 end
    state.perms.index = index
    state.perms.message = ""
    return "move"
end

function M.perms_enter(state, api)
    local p = state.perms
    if type(p) ~= "table" then return "none" end
    if p.level == 1 then
        local app = (p.apps or {})[p.index or 1]
        if app == nil then return "none" end
        p.app = app
        p.caps = {}
        for i = 1, #(app.caps or {}) do
            local cap = app.caps[i]
            p.caps[i] = { cap = cap, state = (app.states or {})[cap] or "ask" }
        end
        p.level, p.index, p.message = 2, 1, ""
        M.note(api, "perms app=" .. tostring(app.name) .. " caps=" .. tostring(#p.caps))
        return "repaint"
    end
    local cap = (p.caps or {})[p.index or 1]
    if cap == nil then return "none" end
    local sysax = type(api) == "table" and api.sys or nil
    local set = type(sysax) == "table" and sysax.perms_set or nil
    if type(set) ~= "function" then
        p.message = "no permission bridge"
        return "denied"
    end
    local want = (cap.state == "granted") and "denied" or "granted"
    local called, ok, err = pcall(set, p.app.name, cap.cap, want)
    if not called or ok ~= true then
        p.message = "save failed"
        M.note(api, "perms set failed app=" .. tostring(p.app.name) .. " cap="
            .. tostring(cap.cap) .. " err=" .. M.fit(tostring(called and err or ok), 40))
        return "denied"
    end
    cap.state = want
    p.message = tostring(cap.cap) .. " " .. want
    M.note(api, "perms set app=" .. tostring(p.app.name) .. " cap=" .. tostring(cap.cap)
        .. " state=" .. want)
    return "change"
end

function M.perms_back(state, api)
    local p = state.perms
    if type(p) ~= "table" then return "none" end
    if p.level == 2 then
        local name = p.app and p.app.name or nil
        p.level, p.caps, p.app = 1, {}, nil
        -- re-read the file so level 1 shows what was written, not what we hoped
        M.perms_refresh(state, api)
        for i = 1, #(p.apps or {}) do
            if p.apps[i].name == name then p.index = i break end
        end
        return "repaint"
    end
    return M.perms_close(state, api)
end

function M.perms_lines(state, cols, rows)
    local p = state.perms or {}
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add(M.PERMS_TITLE)
    if p.level == 1 then
        local apps = p.apps or {}
        if #apps == 0 then add("no apps") end
        for i = 1, #apps do
            local app = apps[i]
            local marker = (i == (p.index or 1)) and ">" or " "
            add(marker .. " " .. tostring(app.name) .. " " .. tostring(app.version or "?"))
        end
    else
        add(tostring(p.app and p.app.name or "?"))
        local caps = p.caps or {}
        if #caps == 0 then add("no capabilities") end
        for i = 1, #caps do
            local cap = caps[i]
            local marker = (i == (p.index or 1)) and ">" or " "
            add(marker .. " " .. tostring(cap.cap) .. " " .. tostring(cap.state))
        end
    end
    if p.message and p.message ~= "" then
        add("")
        add(p.message)
    end
    while #out < rows - 1 do add("") end
    add(M.fit(p.level == 2 and M.PERMS_CAP_HINT or M.PERMS_OPEN_HINT, cols))
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
-- editable settings (D1-fix round 3: the app has a keyboard now)
-- ---------------------------------------------------------------------------
--
-- The file pyroet-os already treats as *the* user settings is `/etc/network.conf`
-- (the net service reads it at boot; `settings` only used to print it). Editing
-- therefore means: pick a whitelisted key, cycle its value, write that one line
-- back. Everything else in the file -- comments, order, unknown keys -- is kept
-- byte for byte, because rewriting a config the user hand-edited is how a
-- "settings screen" turns into a broken network.

M.ITEMS = {
    { key = "prefix", label = "prefix", choices = { "24", "16", "8" } },
    { key = "iface_side", label = "iface", choices = { "auto" } },
}

function M.conf_path(state, opts)
    local o = opts or {}
    return (state and state.conf_path) or o.conf_path or M.CONF_PATH
end

-- the editable rows: a key is offered only when the config file actually has it,
-- so a machine without /etc/network.conf says so instead of inventing defaults.
-- The permission screen is one more row at the bottom (Android keeps it here too).
function M.items(state)
    local out = {}
    local conf = (state and state.conf) or {}
    local have = {}
    for i = 1, #conf do have[conf[i].key] = conf[i].value end
    for i = 1, #M.ITEMS do
        local item = M.ITEMS[i]
        local value = have[item.key]
        local default = false
        if value == nil then
            -- no line yet: offer the first choice. A fresh machine has no
            -- /etc/network.conf at all, and a settings screen that can show
            -- nothing is not a settings screen.
            value = item.choices[1]
            default = true
        end
        out[#out + 1] = {
            key = item.key,
            label = item.label,
            value = value,
            default = default,
            choices = item.choices,
        }
    end
    out[#out + 1] = {
        key = "permissions",
        label = "permissions",
        value = tostring(#((state and state.apps) or {})) .. " apps",
        choices = {},
        perms = true,
    }
    return out
end

function M.item_count(state)
    return #M.items(state)
end

-- index of the first choice equal to `value`, else 1
function M.choice_at(choices, value)
    local list = choices or {}
    for i = 1, #list do
        if tostring(list[i]) == tostring(value) then return i end
    end
    return 1
end

-- next choice in `step` direction (wraps both ways)
function M.cycle(choices, value, step)
    local list = choices or {}
    if #list == 0 then return value end
    local at = M.choice_at(list, value)
    at = at + (step or 1)
    while at < 1 do at = at + #list end
    while at > #list do at = at - #list end
    return tostring(list[at])
end

-- rewrite exactly one `key=value` line, keeping every other byte of the file.
-- Returns true on success, or nil + reason (a refused fs.write is a normal
-- result: the capability stub answers, the screen shows it, nothing is lost).
function M.save_item(api, path, key, value)
    local fsx = api and api.fs
    if type(fsx) ~= "table" then return nil, "capability denied: fs.write" end
    local called, text, err = pcall(fsx.read, path)
    if not called then text, err = nil, text end
    if type(text) ~= "string" then
        -- a fresh machine has no config yet: the first change creates it
        text = ""
    end
    local parent = tostring(path):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and type(fsx.exists) == "function"
        and type(fsx.makeDir) == "function" then
        local ok, here = pcall(fsx.exists, parent)
        if not (ok and here) then pcall(fsx.makeDir, parent) end
    end
    local wanted = tostring(key) .. "=" .. tostring(value)
    local out, done = {}, false
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line_key = raw:gsub("^%s+", ""):match("^([%w_%-%.]+)%s*=")
        if line_key ~= nil and line_key == tostring(key) then
            out[#out + 1] = wanted
            done = true
        else
            out[#out + 1] = raw
        end
    end
    if not done then out[#out] = wanted end
    local wrote, werr = pcall(fsx.write, path, table.concat(out, "\n") .. "\n")
    if not wrote then return nil, tostring(werr) end
    return true
end

-- one key in, one action out: "move"|"change"|"repaint"|"denied"|"none".
-- `left`/`right` and `enter` all change the selected value (enter confirms the
-- next choice). The permission screen has its own two levels and its own keys.
function M.handle_key(state, key, api)
    if type(key) ~= "string" then return "none" end
    if state.perms then
        if key == "up" or key == "left" then return M.perms_move(state, -1) end
        if key == "down" or key == "right" then return M.perms_move(state, 1) end
        if key == "enter" or key == "return" then return M.perms_enter(state, api) end
        return "none"
    end
    local items = M.items(state)
    local count = #items
    if key == "up" or key == "left" then
        if count == 0 then return "none" end
        if key == "up" then
            state.item = (state.item or 1) - 1
            if state.item < 1 then state.item = count end
            state.message = ""
            return "move"
        end
        return M.change_item(state, api, -1)
    end
    if key == "down" or key == "right" then
        if count == 0 then return "none" end
        if key == "down" then
            state.item = (state.item or 1) + 1
            if state.item > count then state.item = 1 end
            state.message = ""
            return "move"
        end
        return M.change_item(state, api, 1)
    end
    if key == "enter" or key == "return" then
        local item = items[state.item or 1]
        if item ~= nil and item.perms then return M.perms_open(state, api) end
        return M.change_item(state, api, 1)
    end
    return "none"
end

function M.change_item(state, api, step)
    local items = M.items(state)
    local item = items[state.item or 1]
    if item == nil then
        state.message = "nothing to edit"
        return "none"
    end
    if item.perms then return "none" end
    local value = M.cycle(item.choices, item.value, step)
    local ok, err = M.save_item(api, M.conf_path(state), item.key, value)
    if not ok then
        state.message = "save failed: " .. tostring(err)
        M.note(api, "save failed key=" .. item.key .. " err=" .. tostring(err))
        return "denied", tostring(err)
    end
    state.message = "saved " .. item.key .. "=" .. value
    M.note(api, "saved " .. item.key .. "=" .. value)
    -- refresh from disk so the row shows what was actually written, not what we
    -- hoped was written
    M.refresh(state, api, {})
    return "change", value
end

-- ---------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------

function M.run(manifest, api, opts)
    local o = opts or {}
    local state = M.build(api, o)
    state.manifest = manifest
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
        if api and type(api.yield) == "function" then api.yield() end
    end
    return state
end

-- ---------------------------------------------------------------------------
-- the resident body (D1-fix round 3): keyboard + screen, no busy loop
-- ---------------------------------------------------------------------------

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

function M.note(api, text)
    if type(api) ~= "table" or type(api.log) ~= "function" then return false end
    return pcall(api.log, text)
end

function M.clear(term)
    local t = term or rawget(_G, "term")
    if type(t) ~= "table" or type(t.clear) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(t.clear))
end

-- refresh + render + paint in one call: only called on a frame that changed
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

-- D1-fix round 5: one quit vocabulary, for keys and for the event loop.
-- The real machine delivers `char` for a typed letter but `key` (a raw code) for
-- the same press, and `keys.escape` does not exist in the CraftOS-PC ROM, so:
--   * a key *name* ("q", "Q", "escape") quits,
--   * a raw keycode is resolved through the ROM keys table first (CraftOS-PC
--     sends q=16, CC:Tweaked sends 81 -- both resolve to the same name),
--   * 256 is accepted as escape even when the ROM has no keys.escape entry.
M.ESCAPE_CODE = 256
-- the two codes a quit can arrive as when the ROM's keys table has no name for
-- them: CraftOS-PC sends q=16, CC:Tweaked sends the GLFW code 81, and 256 is
-- escape on both (the ROM has no keys.escape entry at all)
M.QUIT_CODES = { [16] = true, [81] = true, [256] = true }

function M.quit_key(key, api)
    if type(key) == "number" then
        if M.QUIT_CODES[key] then return true end
        local name = M.code_name(key, api)
        if name ~= nil then
            key = name
        elseif key == M.ESCAPE_CODE then
            key = "escape"
        else
            return false
        end
    end
    if type(key) ~= "string" then return false end
    key = key:lower()
    return key == "q" or key == "escape" or key == "quit"
end

-- one delivered event -> one action. Returns "quit" when the app has to end,
-- otherwise "move" | "change" | "denied" | "none" | "repaint".
function M.dispatch_event(state, event, p1, api)
    -- the permission screen owns `q`: it goes back one level, it never leaves the
    -- app from inside a list the user is in the middle of
    if state.perms and event == "key" then
        if M.quit_key(p1, api) then return M.perms_back(state, api) end
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        local action, detail = M.handle_key(state, tostring(key == nil and "" or key), api)
        M.note(api, "perms key=" .. tostring(key) .. " action=" .. tostring(action)
            .. (detail ~= nil and (" detail=" .. tostring(detail)) or ""))
        return action, detail
    end
    if state.perms and event == "char" then
        local ch = tostring(p1 == nil and "" or p1)
        if ch == "q" or ch == "Q" then return M.perms_back(state, api) end
        return "none"
    end
    if event == "key" then
        -- the raw value is checked for quit FIRST: a keycode with no name in
        -- this ROM (escape is 256 and has no keys.escape entry) must still leave
        if M.quit_key(p1, api) then return "quit", tostring(p1) end
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        key = tostring(key == nil and "" or key)
        if M.quit_key(key, api) then return "quit", tostring(key) end
        local action, detail = M.handle_key(state, key, api)
        M.note(api, "key=" .. key .. " action=" .. tostring(action)
            .. " item=" .. tostring(state.item or 1)
            .. (detail ~= nil and (" detail=" .. tostring(detail)) or ""))
        return action, detail
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1)
        if ch == "q" or ch == "Q" then return "quit", "q" end
        return "none"
    end
    if event == "desk_focus" then return "repaint" end
    if event == "term_resize" then return "repaint" end
    if event == "terminate" or event == "shutdown" then return "quit", event end
    return "none"
end

-- no keyboard (capability refused or no host): keep the frame, never spin
function M.idle(api)
    while true do
        if type(api) == "table" and type(api.yield) == "function" then
            api.yield()
        else
            return "idle"
        end
    end
end

function M.body(manifest, api)
    local state = M.build(api, {})
    state.manifest = manifest
    local term = type(api) == "table" and api.terminal or nil
    local input = type(api) == "table" and api.input or nil
    local pull = type(input) == "table" and input.pullEvent or nil
    M.paint_once(state, api, term)
    M.note(api, "ready item=" .. tostring(state.item or 1)
        .. " items=" .. tostring(#M.items(state)))
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
            local action, detail = M.dispatch_event(state, event, p1, api)
            if action == "quit" then
                M.note(api, "quit key=" .. tostring(detail))
                return "quit"
            end
            if action ~= "none" then M.paint_once(state, api, term) end
            api.yield()
        end
    end
end

-- The DECISIONS 7.2 self test this app used to carry (sample_state/selftest, ~95
-- lines) is gone: nothing in the image or the suite called it, and t_settings
-- renders 26x20, 26x40, 8-row, 20-col and 1x1 frames with cell assertions, which
-- is the same rule checked harder. It was the first thing cut for the size cap.
local function body(manifest, api)
    return M.body(manifest, api)
end

if rawget(_G, "PYROET_SETTINGS_TEST") then
    return M
end

return body
