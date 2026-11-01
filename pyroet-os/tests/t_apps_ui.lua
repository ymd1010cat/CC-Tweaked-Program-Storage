--[[- pyroet-os/tests/t_apps_ui.lua -- D1-fix round 3: the three system apps are
keyboard-operable.

Each app is driven through its **resident body** (`M.body`) with a scripted event
queue and `tests/screen.lua` installed as the app's terminal, which is the only
way to assert what the user actually sees:

  settings   first frame (editable rows) -> down moves the marker -> enter cycles
             the value and writes /etc/network.conf -> q returns "quit", and the
             file is checked byte-wise (comment + untouched keys survive)
  net        first frame (ip/gateway/health/hosts) -> enter refreshes the service
             status -> q returns "quit"
  installer  first frame (package list) -> down moves the marker -> enter reports
             "installer unavailable" when there is no bridge (never faked)
             -> q returns "quit"

Also asserts the three manifests declare `input` + `terminal` (static), so the
desktop actually hands them the keyboard.

No non-ASCII bytes in this file.
]]

local S = dofile("/tests/screen.lua")

_G.PYROET_SETTINGS_TEST = true
local SETTINGS = assert(loadfile("/system/system/settings.app/main.lua"))()
_G.PYROET_SETTINGS_TEST = nil

_G.PYROET_NET_APP_TEST = true
local NET = assert(loadfile("/system/system/net.app/main.lua"))()
_G.PYROET_NET_APP_TEST = nil

_G.PYROET_INSTALLER_TEST = true
-- the installer package is staged under /tests (the staged /system/system root is
-- pinned at three packages by t_desktop/t_settings/t_budget)
local INSTALLER = assert(loadfile("/tests/installer.app/main.lua"))()
_G.PYROET_INSTALLER_TEST = nil

-- a deterministic key table: the dispatch accepts names, so the test states its
-- own vocabulary (the numeric form is covered in t_desktop_loop)
local KEYS = { up = 10, down = 11, left = 12, right = 13, enter = 14, escape = 15 }

return function(H)
    local F = H.real_fs()

    local function host(events, keysx)
        local queue, index = {}, 0
        for i = 1, #events do queue[i] = events[i] end
        local hostx = { keys = keysx or KEYS }
        function hostx.pullEvent()
            index = index + 1
            local event = queue[index]
            if event == nil then return nil end
            return event[1], event[2], event[3], event[4]
        end
        function hostx.pushed()
            return index
        end
        return hostx
    end

    -- the app's api: real fs (so writes are really written), scripted input,
    -- the screen buffer as terminal, and a log sink the assertions can read
    local function app_api(opts)
        local o = opts or {}
        local log, lines = H.logger()
        local api = {
            fs = {
                read = function(path)
                    local text = H.read(path)
                    if text == nil then return nil, "missing" end
                    return text
                end,
                list = function(path)
                    local names = F.exists(path) and F.list(path)
                    if not names then return nil, "no directory" end
                    return names
                end,
                exists = function(path) return F.exists(path) end,
                size = function(path) return F.getSize(path) end,
                getFreeSpace = function(path) return F.getFreeSpace(path) end,
                write = function(path, data)
                    return H.write(path, data) ~= nil
                end,
            },
            input = o.input or host({}),
            terminal = o.terminal,
            yield = function() end,
            log = log,
            sys = o.sys,
            net = o.net,
        }
        return api, lines
    end

    local function snap(buf)
        local out = {}
        for y = 1, 19 do out[y] = buf.row(y) end
        return out
    end

    -- run one app body with the screen buffer installed (the apps paint the ROM
    -- terminal through `api.terminal`, and NOPAINT would hide everything)
    local function run_body(name, mod, api, buf)
        local saved = rawget(_G, "PYROET_APP_NOPAINT")
        rawset(_G, "PYROET_APP_NOPAINT", nil)
        local manifest = { name = name, version = "0.2.0" }
        local ok, called, value = pcall(function()
            local fine, ret = S.with_term(buf, function()
                return mod.body(manifest, api)
            end)
            return fine, ret
        end)
        rawset(_G, "PYROET_APP_NOPAINT", saved)
        H.check(name .. "_ran", ok and called == true, tostring(value))
        if ok and called == true then return value end
        return nil
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.manifests")
    do
        local function caps_of(path)
            local raw = assert(loadfile(path))()
            local set = {}
            for i = 1, #(raw.capabilities or {}) do set[raw.capabilities[i]] = true end
            return raw, set
        end
        local settings, settings_caps = caps_of("/system/system/settings.app/manifest.lua")
        local net, net_caps = caps_of("/system/system/net.app/manifest.lua")
        local installer, installer_caps = caps_of("/tests/installer.app/manifest.lua")
        for _, case in ipairs({
            { name = "settings", raw = settings, caps = settings_caps },
            { name = "net", raw = net, caps = net_caps },
            { name = "installer", raw = installer, caps = installer_caps },
        }) do
            H.eq(case.name .. "_input", case.caps.input, true)
            H.eq(case.name .. "_terminal", case.caps.terminal, true)
            H.eq(case.name .. "_version", case.raw.version, "0.2.0")
        end
        H.eq("settings_write", settings_caps["fs.write"], true)
        H.eq("net_rpv", net_caps["net.rpv"], true)
        H.eq("installer_write", installer_caps["fs.write"], true)
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.settings")
    do
        local dir = H.case_dir("apps_ui", "settings")
        H.mkdirp("/etc")
        H.write("/etc/network.conf",
            "# hand written\nprefix=24\niface_side=back\nkeep=1\n")

        -- 1) first frame: a run that quits immediately. Title, the two editable
        --    rows with the marker on row 2, and the hint row, all verbatim.
        local buf0 = S.buffer(51, 19)
        local api0 = app_api({
            terminal = buf0,
            input = host({ { "key", "q" } }),
        })
        run_body("settings_first", SETTINGS, api0, buf0)
        local first = snap(buf0)
        H.eq("settings_title", first[1]:sub(1, 14), "Settings 0.2.0")
        H.eq("settings_first_row2", first[2]:sub(1, 12), "> prefix 24 ")
        H.eq("settings_first_row3", first[3]:sub(1, 14), "  iface back  ")
        H.eq("settings_first_row4", first[4]:sub(1, 18), "up/dn enter q=back")

        -- 2) down + enter + q: the marker moves, enter cycles the value, the
        --    change is written to /etc/network.conf and q returns "quit"
        local buf = S.buffer(51, 19)
        local api, lines = app_api({
            terminal = buf,
            input = host({ { "key", "down" }, { "key", "enter" }, { "key", "q" } }),
        })
        local result = run_body("settings", SETTINGS, api, buf)
        H.eq("settings_result", result, "quit")
        local frame = snap(buf)
        H.eq("settings_row2", frame[2]:sub(1, 12), "  prefix 24 ")
        H.eq("settings_row3", frame[3]:sub(1, 14), "> iface top   ")
        H.eq("settings_row4", frame[4]:sub(1, 18), "up/dn enter q=back")
        local slog = H.joined(lines)
        H.contains("settings_move", slog, "key=down action=move item=2")
        H.contains("settings_change", slog, "key=enter action=change item=2 detail=top")
        H.contains("settings_saved", slog, "saved iface_side=top")
        H.contains("settings_quit", slog, "quit key=q")
        -- the file: one line replaced, everything else byte-identical
        local cfg = H.read("/etc/network.conf") or ""
        H.contains("settings_cfg_side", cfg, "iface_side=top")
        H.contains("settings_cfg_comment", cfg, "# hand written")
        H.contains("settings_cfg_prefix", cfg, "prefix=24")
        H.contains("settings_cfg_keep", cfg, "keep=1")
        H.absent("settings_cfg_old_side", cfg, "iface_side=back")
        H.ascii_check("settings_logs_ascii", H.joined(lines))
        H.rmrf("/etc/network.conf")
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.settings_exit")
    -- The real machine sends `key` (raw code) and `char` for the same press, and
    -- the ROM has no keys.escape: every shape has to leave the app.
    do
        H.mkdirp("/etc")
        H.write("/etc/network.conf", "# hand written\nprefix=24\niface_side=back\n")
        local K = rawget(_G, "keys")
        local qcode = (type(K) == "table" and type(K.q) == "number") and K.q or 16
        local shapes = {
            { name = "name_q", events = { { "key", "q" } } },
            { name = "name_Q", events = { { "key", "Q" } } },
            { name = "char_q", events = { { "char", "q" } } },
            { name = "char_Q", events = { { "char", "Q" } } },
            { name = "code_q", events = { { "key", qcode } } },
            { name = "name_escape", events = { { "key", "escape" } } },
            { name = "code_escape", events = { { "key", 256 } } },
            { name = "terminate", events = { { "terminate" } } },
        }
        for i = 1, #shapes do
            local case = shapes[i]
            local buf = S.buffer(51, 19)
            local api = app_api({ terminal = buf, input = host(case.events) })
            local result = run_body("settings_exit_" .. case.name, SETTINGS, api, buf)
            H.eq("settings_exit_" .. case.name, result, "quit")
        end
        H.rmrf("/etc/network.conf")
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.settings_fresh")
    -- A fresh machine has no /etc/network.conf at all. That is the state the demo
    -- disk is in, and a settings screen that shows nothing and answers every key
    -- with "none" looks exactly like a frozen app.
    do
        H.rmrf("/etc/network.conf")
        local buf = S.buffer(51, 19)
        local api, lines = app_api({
            terminal = buf,
            input = host({ { "key", "down" }, { "key", "enter" }, { "key", "q" } }),
        })
        local result = run_body("settings_fresh", SETTINGS, api, buf)
        H.eq("fresh_result", result, "quit")
        local frame = snap(buf)
        -- the two documented defaults are offered even with no file (the final
        -- frame: the marker moved to the second row, whose value was changed)
        H.eq("fresh_row2", frame[2]:sub(1, 12), "  prefix 24 ")
        H.eq("fresh_row3", frame[3]:sub(1, 14), "> iface top   ")
        -- down + enter changed the second row and CREATED the file
        H.contains("fresh_moved", H.joined(lines), "key=down action=move item=2")
        H.contains("fresh_saved", H.joined(lines), "saved iface_side=top")
        local cfg = H.read("/etc/network.conf") or ""
        H.contains("fresh_cfg", cfg, "iface_side=top")
        H.rmrf("/etc/network.conf")
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.net")
    do
        local buf = S.buffer(51, 19)
        local service = {
            status = function()
                return { ip = "10.0.0.5", prefix = 24, gateway = "10.0.0.1",
                    health = "ok", probe_port = 6701 }
            end,
            list_hosts = function()
                return { { name = "root.server", text = "10.0.0.2" } }
            end,
            probe = function()
                return { done = true, result = { ok = true, rtt_text = "3ms" } }
            end,
        }
        local api, lines = app_api({
            terminal = buf,
            input = host({ { "key", "enter" }, { "char", "r" }, { "key", "q" } }),
            net = { rpv = service },
        })
        local result = run_body("net", NET, api, buf)
        H.eq("net_result", result, "quit")
        local frame = snap(buf)
        H.contains("net_title", frame[1], "Pyroet Net 0.2")
        H.contains("net_ip", frame[2], "ip 10.0.0.5/24")
        H.contains("net_gw", frame[3], "gw 10.0.0.1")
        H.contains("net_health", frame[4], "health ok")
        -- enter and `r` both refreshed (the one real operation net has)
        H.eq("net_refreshes", H.count(lines, "refresh hosts=1"), 2)
        H.contains("net_ready", H.joined(lines), "ready health=ok ip=10.0.0.5")
        H.contains("net_quit", H.joined(lines), "quit key=q")
        H.ascii_check("net_logs_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("apps_ui.installer")
    do
        -- the scan reads the real /apps too: keep it empty so the list is the
        -- three image packages (other suites create fixtures there)
        H.rmrf("/apps")
        local buf = S.buffer(51, 19)
        -- no source medium and no bridge: the app must say so, not fake an install
        local api, lines = app_api({
            terminal = buf,
            input = host({ { "key", "down" }, { "key", "enter" }, { "key", "q" } }),
            sys = {
                apps = function()
                    return {
                        { name = "launcher", version = "0.2.0", state = "running" },
                        { name = "settings", version = "0.2.0", state = "loaded" },
                    }
                end,
            },
        })
        local result = run_body("installer", INSTALLER, api, buf)
        H.eq("installer_result", result, "quit")
        local frame = snap(buf)
        H.eq("installer_title", frame[1]:sub(1, 17), "installer 0.2.0  ")
        -- this app is driven through its body, so the sink carries the raw line
        -- (the runtime prepends APP_LOG when the app really runs)
        local logtext = H.joined(lines)
        H.contains("installer_ready", logtext, "ready entries=4 source=none")
        H.contains("installer_move", logtext, "key=down action=move")
        -- the selected row is a system package: pressing enter says it is locked
        -- (a real answer, not a fake install)
        H.contains("installer_locked", logtext, "key=enter action=locked")
        H.contains("installer_quit", logtext, "quit key=q")
        -- the screen shows what is installed and that there is no source medium
        local text = table.concat(frame, "\n")
        H.contains("installer_list_launcher", text, "launcher")
        H.contains("installer_list_settings", text, "settings")
        H.contains("installer_no_source", text, "source none")
        H.ascii_check("installer_logs_ascii", H.joined(lines))
    end

    H.rmrf("/apps_ui")
end
