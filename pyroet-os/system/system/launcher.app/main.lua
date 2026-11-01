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
M.LEAVE_HINT = "Ctrl+T opens power menu"
-- the package name of this app: it must never appear in its own list. A second
-- copy under /apps is skipped by the same rule (the package name, not the path).
M.SELF = "launcher"
-- The power menu (round 8). Ctrl+T used to drop the machine to the CraftOS
-- shell, which the user does not want; the desktop now intercepts `terminate`
-- and shows this instead. It is drawn by the launcher itself: no new app, no
-- extra capability, exactly three entries.
M.POWER_ITEMS = {
    { id = "update", label = "Update" },
    { id = "shutdown", label = "Shutdown" },
    { id = "reboot", label = "Reboot" },
    { id = "cancel", label = "Cancel" },
}
-- the OTA screen (T5): the launcher only renders what the kernel reports; the
-- kernel owns the medium, the meta parser and the installer
M.OTA_TITLE = "Updates"
M.POWER_TITLE = "Power"
-- the permission dialog (permissions rule 6): one question, two buttons, and the
-- keyboard belongs to it until one of them is pressed (this machine's "tap").
M.PERM_TITLE = "Permission request"
M.PERM_ALLOW = "[Allow]"
M.PERM_DENY = "[Deny]"
M.PERM_HINT = "A=allow D=deny"
-- tests replace these instead of really shutting the machine down
M.POWER_HOOKS = {}
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
-- T15: the version of a package directory, read from its manifest (the runtime
-- only knows packages it scanned at boot). A read failure is logged once and
-- shown as `?` -- it is not an error the desktop should die on.
function M.read_version(api, dir)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.read) ~= "function" then return nil end
    local called, text = pcall(fsx.read, dir .. "/manifest.lua")
    if not called or type(text) ~= "string" then
        if type(api) == "table" and type(api.log) == "function" then
            pcall(api.log, "LAUNCHER_MANIFEST_MISS path=" .. tostring(dir))
        end
        return nil
    end
    local version = text:match('version%s*=%s*"([^"]*)"')
    if version == nil or version == "" then
        local ok, value = pcall(function()
            local chunk = (type(rawget(_G, "loadfile")) == "function")
                and loadfile(dir .. "/manifest.lua") or nil
            if chunk == nil then return nil end
            local raw = chunk()
            if type(raw) == "table" and raw.version ~= nil then
                return tostring(raw.version)
            end
            return nil
        end)
        version = ok and value or nil
    end
    if version == nil then
        if type(api) == "table" and type(api.log) == "function" then
            pcall(api.log, "LAUNCHER_MANIFEST_MISS path=" .. tostring(dir))
        end
        return nil
    end
    return tostring(version)
end

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
        local version = type(record) == "table" and record.version or nil
        if type(version) ~= "string" or version == "" then
            -- a package installed at run time has no runtime record yet: read its
            -- manifest instead of showing "?"
            version = M.read_version(api, dir)
        end
        entries[#entries + 1] = {
            name = app,
            dir = dir,
            root = root,
            version = version or "?",
            state = type(record) == "table" and record.state or "unknown",
            capabilities = type(record) == "table" and record.capabilities or nil,
        }
    end
    local skipped_self = 0
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
                    elseif app == M.SELF then
                        -- the desktop itself: not an app row (a second copy under
                        -- /apps is skipped by the same rule)
                        skipped_self = skipped_self + 1
                        if type(api) == "table" and type(api.log) == "function" then
                            pcall(api.log, "LAUNCHER_SKIP_SELF name=" .. app
                                .. " path=" .. dir)
                        end
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

-- the ROM function a power entry needs, or nil: never assume it exists
function M.power_fn(id)
    local hook = M.POWER_HOOKS[id]
    if type(hook) == "function" then return hook end
    local osx = rawget(_G, "os")
    local fn = type(osx) == "table" and osx[id] or nil
    if type(fn) == "function" then return fn end
    return nil
end

function M.power_available(id)
    -- the menu entries that do not call an `os` function
    if id == "cancel" or id == "update" then return true end
    return M.power_fn(id) ~= nil
end

-- the reason line under an entry that cannot run on this ROM
function M.power_reason(id)
    if M.power_available(id) then return "" end
    return "os." .. tostring(id) .. " unavailable"
end

function M.power_open(state, api, source)
    state.power = true
    state.power_index = 1
    state.message = ""
    M.note(api, "power menu open source=" .. tostring(source or "key"))
    return "repaint"
end

function M.power_close(state, api)
    state.power = nil
    state.message = ""
    M.note(api, "power menu cancel")
    return "repaint"
end

function M.power_move(state, delta)
    local count = #M.POWER_ITEMS
    local index = (state.power_index or 1) + delta
    if index < 1 then index = 1 end
    if index > count then index = count end
    state.power_index = index
    return "move"
end

-- Run one entry. The log line is written BEFORE the action, and the action is
-- wrapped: a ROM without os.shutdown/os.reboot shows "unavailable" instead of
-- crashing, and a failing call is logged, not raised.
function M.power_run(state, api, index)
    local item = M.POWER_ITEMS[index or state.power_index or 1]
    if item == nil then return "none" end
    if item.id == "cancel" then return M.power_close(state, api) end
    if item.id == "update" then return M.ota_open(state, api) end
    local fn = M.power_fn(item.id)
    if fn == nil then
        M.note(api, "POWER " .. item.id .. " unavailable")
        state.message = M.power_reason(item.id)
        return "denied"
    end
    M.note(api, "POWER " .. item.id .. " requested")
    local ok, err = pcall(fn)
    if not ok then
        M.note(api, "POWER " .. item.id .. " failed err=" .. tostring(err))
        state.message = "power failed"
        return "error"
    end
    return "power"
end

-- The OTA screen. `api.sys.ota_list()` is the kernel's answer: `true, {source,
-- entries}` when the medium offers something, `nil, reason` when it does not.
-- Nothing here reads a file or reaches a network.
function M.ota_open(state, api)
    state.power = nil
    state.ota = { index = 1, entries = {}, source = nil, reason = nil }
    local sysax = type(api) == "table" and api.sys or nil
    local list = type(sysax) == "table" and sysax.ota_list or nil
    if type(list) ~= "function" then
        state.ota.reason = "no ota bridge"
        M.note(api, "ota unavailable")
        return "repaint"
    end
    local called, ok, info = pcall(list)
    if not called then
        state.ota.reason = "ota failed"
        M.note(api, "ota list failed err=" .. M.fit(tostring(ok), 40))
        return "repaint"
    end
    if ok ~= true or type(info) ~= "table" then
        state.ota.reason = tostring(info or "no source")
        M.note(api, "ota list source=none reason=" .. state.ota.reason)
        return "repaint"
    end
    state.ota.source = tostring(info.source or "?")
    local entries = info.entries or {}
    for i = 1, #entries do state.ota.entries[#state.ota.entries + 1] = entries[i] end
    if #state.ota.entries == 0 then
        state.ota.reason = "up to date"
        M.note(api, "ota list source=" .. state.ota.source .. " entries=0")
        return "repaint"
    end
    M.note(api, "ota list source=" .. M.fit(state.ota.source, 32)
        .. " entries=" .. tostring(#state.ota.entries))
    return "repaint"
end

function M.ota_close(state, api)
    state.ota = nil
    state.message = ""
    M.note(api, "ota cancel")
    return "repaint"
end

function M.ota_selected(state)
    local ota = state.ota
    if type(ota) ~= "table" then return nil end
    return ota.entries[ota.index or 1]
end

function M.ota_move(state, delta)
    local ota = state.ota
    if type(ota) ~= "table" then return "none" end
    local count = #ota.entries
    local index = (ota.index or 1) + delta
    if index < 1 then index = 1 end
    if count > 0 and index > count then index = count end
    ota.index = index
    return "move"
end

-- Applying an entry: a package is installed through the kernel bridge; an image
-- update is listed but reflashed by recovery (the kernel says so, verbatim).
function M.ota_apply(state, api)
    local ota = state.ota
    local entry = M.ota_selected(state)
    if type(entry) ~= "table" then
        ota.reason = "no updates"
        return "none"
    end
    local sysax = type(api) == "table" and api.sys or nil
    local apply = type(sysax) == "table" and sysax.ota_apply or nil
    if type(apply) ~= "function" then
        ota.reason = "no ota bridge"
        return "denied"
    end
    M.note(api, "ota apply name=" .. tostring(entry.name))
    local called, ok, info = pcall(apply, entry.name)
    if not called then
        ota.reason = "apply failed"
        M.note(api, "ota apply failed err=" .. M.fit(tostring(ok), 40))
        return "error"
    end
    if ok ~= true then
        ota.reason = tostring(info or "failed")
        M.note(api, "ota apply name=" .. tostring(entry.name)
            .. " ok=false reason=" .. ota.reason)
        return "error"
    end
    state.message = "updated " .. tostring(entry.name)
    M.note(api, "ota apply name=" .. tostring(entry.name) .. " ok=true")
    return "power"
end

function M.ota_lines(state, cols, rows)
    local ota = state.ota or {}
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add(M.OTA_TITLE .. " " .. M.VERSION)
    local entries = ota.entries or {}
    if #entries == 0 then
        add("no updates")
        if ota.reason then add(tostring(ota.reason)) end
    else
        local index = ota.index or 1
        local area = rows - 4
        for i = 1, math.min(#entries, area) do
            local entry = entries[i]
            local marker = (i == index) and ">" or " "
            add(marker .. " " .. tostring(entry.name) .. " "
                .. tostring(entry.version or "?") .. " " .. tostring(entry.kind or ""))
        end
        if ota.reason then add(tostring(ota.reason)) end
    end
    while #out < rows - 1 do add("") end
    add(M.fit("enter install q=back", cols))
    return out
end

-- render the menu inside the same 26x19 frame (title, three entries, marker,
-- the reason line for an unavailable entry, and the hint row)
function M.power_lines(state, cols, rows)
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add(M.POWER_TITLE .. " " .. M.VERSION)
    add("")
    local index = state.power_index or 1
    for i = 1, #M.POWER_ITEMS do
        local item = M.POWER_ITEMS[i]
        local marker = (i == index) and ">" or " "
        local label = item.label
        if not M.power_available(item.id) then label = label .. " unavailable" end
        add(marker .. " " .. label)
    end
    add("")
    local current = M.POWER_ITEMS[index]
    if current ~= nil then
        local reason = M.power_reason(current.id)
        if reason ~= "" then add(reason) end
    end
    if state.message and state.message ~= "" then add(state.message) end
    while #out < rows - 1 do add("") end
    add(M.fit("enter runs q=cancel", cols))
    return out
end

-- The permission dialog: the runtime deferred an app's start because one declared
-- capability has no decision yet (permissions rule 6); this is the one screen that
-- can turn it into one. The first three rows are the question, as Android asks it.
function M.perm_open(state, api, app, cap)
    state.power, state.ota = nil, nil
    state.perm = {
        app = tostring(app == nil and "?" or app),
        cap = tostring(cap == nil and "?" or cap),
    }
    state.message = ""
    M.note(api, "perm open app=" .. state.perm.app .. " cap=" .. state.perm.cap)
    return "repaint"
end

-- A = allowed, D = denied. The kernel does the write (and only that write makes
-- the app startable), then the deferred start is retried: an allow starts the app
-- with the capability, a deny starts it with the capability refused -- exactly
-- what a package denied once already gets.
function M.perm_answer(state, api, verdict)
    local perm = state.perm
    if type(perm) ~= "table" then return "none" end
    local sysax = type(api) == "table" and api.sys or nil
    local answer = type(sysax) == "table" and sysax.perms_answer or nil
    if type(answer) ~= "function" then
        state.message = "no permission bridge"
        return "denied"
    end
    local called, ok, err = pcall(answer, perm.app, perm.cap, verdict)
    if not called or ok ~= true then
        state.message = "answer refused"
        M.note(api, "perm answer app=" .. perm.app .. " cap=" .. perm.cap
            .. " err=" .. M.fit(tostring(called and err or ok), 40))
        return "error"
    end
    M.note(api, "perm answer app=" .. perm.app .. " cap=" .. perm.cap
        .. " verdict=" .. tostring(verdict))
    state.message = tostring(verdict) .. " " .. perm.cap
    state.perm = nil
    local launch = type(sysax) == "table" and sysax.launch or nil
    if type(launch) == "function" then
        local again, started, rerr = pcall(launch, perm.app)
        if again and started then
            state.launched = perm.app
            state.message = "started " .. perm.app
            M.note(api, "perm retry app=" .. perm.app .. " started=true")
        else
            M.note(api, "perm retry app=" .. perm.app .. " started=false err="
                .. M.fit(tostring(started or rerr), 40))
        end
    end
    return "repaint"
end

function M.perm_lines(state, cols, rows)
    local perm = state.perm or {}
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add(M.PERM_TITLE)
    add(tostring(perm.app or "?") .. " wants " .. tostring(perm.cap or "?"))
    add(M.PERM_ALLOW .. "  " .. M.PERM_DENY)
    if state.message and state.message ~= "" then
        add("")
        add(state.message)
    end
    while #out < rows - 1 do add("") end
    add(M.fit(M.PERM_HINT, cols))
    return out
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
    if state.perm then return M.perm_lines(state, cols, rows) end
    if state.ota then return M.ota_lines(state, cols, rows) end
    if state.power then return M.power_lines(state, cols, rows) end
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
    -- the permission dialog owns the keyboard while it is open: A allows, D
    -- denies, everything else is ignored (a question has no "dismiss")
    if state.perm then
        local ch = nil
        if event == "char" then
            ch = p1
        elseif event == "key" then
            local key = p1
            if type(key) == "number" then key = M.code_name(key, api) end
            ch = key
        end
        ch = tostring(ch == nil and "" or ch):lower()
        if ch == "a" then return M.perm_answer(state, api, "allowed") end
        if ch == "d" then return M.perm_answer(state, api, "denied") end
        return "none"
    end
    -- the runtime deferred a start for an undecided capability: the desktop
    -- delivered it here, and it is a system-modal question (it closes a menu)
    if event == "perm_request" then return M.perm_open(state, api, p1, p2) end
    -- the OTA screen: up/down move, enter applies, q cancels (no Esc: the ROM
    -- does not deliver it, see DECISIONS.md)
    if state.ota then
        if event == "key" then
            local key = p1
            if type(key) == "number" then
                key = M.code_name(key, api)
                if key == nil then return "none" end
            end
            key = tostring(key == nil and "" or key):lower()
            if key == "up" then return M.ota_move(state, -1) end
            if key == "down" then return M.ota_move(state, 1) end
            if key == "enter" then return M.ota_apply(state, api) end
            if key == "q" then return M.ota_close(state, api) end
            return "none"
        end
        if event == "char" then
            local ch = tostring(p1 == nil and "" or p1):lower()
            if ch == "q" then return M.ota_close(state, api) end
            return "none"
        end
        return "none"
    end
    -- the power menu owns the keyboard while it is open: up/down move, enter
    -- runs, q/Esc cancels (nothing else may act on the desktop meanwhile)
    if state.power then
        if event == "key" then
            local key = p1
            if type(key) == "number" then
                key = M.code_name(key, api)
                if key == nil then
                    if p1 == M.ESCAPE_CODE then key = "escape" else return "none" end
                end
            end
            key = tostring(key == nil and "" or key):lower()
            if key == "up" then return M.power_move(state, -1) end
            if key == "down" then return M.power_move(state, 1) end
            if key == "enter" then return M.power_run(state, api) end
            if key == "escape" or key == "q" then return M.power_close(state, api) end
            return "none"
        end
        if event == "char" then
            local ch = tostring(p1 == nil and "" or p1):lower()
            if ch == "q" then return M.power_close(state, api) end
            return "none"
        end
        if event == "power_menu" then return "repaint" end
        return "none"
    end
    -- Ctrl+T: the desktop intercepts it and shows the power menu. This never
    -- returns "quit", so there is no path back to the CraftOS shell.
    if event == "power_menu" or event == "terminate" or event == "shutdown" then
        return M.power_open(state, api, event)
    end
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
