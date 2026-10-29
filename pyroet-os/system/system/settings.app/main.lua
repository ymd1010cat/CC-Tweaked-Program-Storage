--[[- pyroet-os/system/settings.app/main.lua -- Settings: a read only view (26x20 UI).

What it shows, all of it read from files or from the host's read-only system
surface (never written back):

    system   Pyroet OS version, boot slot (/boot.slot), image version
             (/slots/<slot>/boot.ok, then .image, then /boot.ok), net health
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

M.VERSION = "0.1.0"
M.VIEW = { cols = 26, rows = 20 }
M.MIN_COLS = 16
M.MIN_ROWS = 6
M.SLOT_PATH = "/boot.slot"
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

function M.read_boot(api)
    local info = { slot = nil, version = nil, sha256 = nil, source = nil }
    local slot_text = M.read_file(api, M.SLOT_PATH)
    if type(slot_text) == "string" then
        local slot = slot_text:gsub("%s+", "")
        if slot:match("^[%w_%-]+$") then info.slot = slot end
    end
    local bases = {}
    if info.slot then bases[#bases + 1] = "/slots/" .. info.slot end
    bases[#bases + 1] = ""
    for i = 1, #bases do
        local base = bases[i]
        local text = M.read_file(api, base .. "/boot.ok")
        if type(text) == "string" then
            local version = marker_value(text, "version")
            if version then info.version = version end
            local sha = marker_value(text, "sha256")
            if sha and sha ~= "none" then info.sha256 = sha end
            info.source = base .. "/boot.ok"
            break
        end
    end
    if not info.version then
        for i = 1, #bases do
            local text = M.read_file(api, bases[i] .. "/.image")
            if type(text) == "string" then
                local version = marker_value(text, "version")
                if version then
                    info.version = version
                    info.source = bases[i] .. "/.image"
                    break
                end
            end
        end
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
        slot = "?",
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
        frames = 0,
    }
    return M.refresh(state, api, o)
end

function M.refresh(state, api, opts)
    local o = opts or {}
    state.frames = (state.frames or 0) + 1
    local boot = M.read_boot(api)
    state.slot = boot.slot or "?"
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
    add("os " .. M.VERSION .. " slot " .. tostring(state.slot or "?"))
    add("image " .. tostring(state.version or "?"))
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
        .. tostring(cols) .. "x" .. tostring(rows)
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
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("Settings " .. M.VERSION)
    local body = M.sections(state)
    local capacity = rows - 2
    if #body > capacity then
        local keep = capacity - 1
        for i = 1, keep do add(body[i]) end
        add("+" .. tostring(#body - keep) .. " more")
    else
        for i = 1, #body do add(body[i]) end
        while #out < rows - 1 do add("") end
    end
    add(M.status_line(state, cols, rows))
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
-- DECISIONS.md 7.2 self test: no terminal, no fs, pure layout rules
-- ---------------------------------------------------------------------------

function M.sample_state()
    return {
        cols = M.VIEW.cols,
        rows = M.VIEW.rows,
        slot = "a",
        version = "1.0.0",
        net = "ok",
        free = 26214,
        apps = {
            {
                name = "net", version = "0.1.0",
                capabilities = { "net.rpv", "fs.read" },
                grants = { ["net.rpv"] = true, ["fs.read"] = false },
            },
        },
        conf = {
            { key = "ip", value = "10.0.0.5" },
            { key = "psk", value = "***" },
        },
        bad_conf = 0,
        install_entries = 19,
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
    if not (full[1] or ""):find("Settings 0.1.0", 1, true) then
        problems[#problems + 1] = "title row lost"
    end
    local joined = table.concat(full, "\n")
    if not joined:find("=== apps ===", 1, true) then
        problems[#problems + 1] = "apps block lost"
    end
    if not (full[#full] or ""):find("ro 1 apps 26x20", 1, true) then
        problems[#problems + 1] = "status row lost"
    end
    -- a tall view shows the whole body, and the +N more line appears when not
    local tall = M.render(state, M.VIEW.cols, 40)
    in_bounds(tall, M.VIEW.cols, 40, "26x40")
    if not table.concat(tall, "\n"):find("install.set 19 entries", 1, true) then
        problems[#problems + 1] = "storage block missing"
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
    -- nothing readable at all: still a screen, never an error
    local empty = M.build(nil, { cols = M.VIEW.cols, rows = M.VIEW.rows })
    local empty_lines = M.render(empty, M.VIEW.cols, M.VIEW.rows)
    in_bounds(empty_lines, M.VIEW.cols, M.VIEW.rows, "empty")
    local empty_text = table.concat(empty_lines, "\n")
    if not empty_text:find("conf n/a", 1, true) then
        problems[#problems + 1] = "empty machine did not degrade to conf n/a"
    end
    if not empty_text:find("apps n/a", 1, true) then
        problems[#problems + 1] = "empty machine did not degrade to apps n/a"
    end
    if not empty_text:find("install.set n/a", 1, true) then
        problems[#problems + 1] = "empty machine did not degrade to install.set n/a"
    end
    return #problems == 0, problems
end

M.layout_selftest = M.selftest

local function body(manifest, api)
    return M.run(manifest, api)
end

if rawget(_G, "PYROET_SETTINGS_TEST") then
    return M
end

return body
