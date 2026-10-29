--[[- pyroet-os/tests/t_settings.lua -- Settings: read only rendering of the
-- system, the app/capability table, /etc/network.conf (redacted) and storage.

Two properties matter and are tested directly: the screen is *read only* (the
manifest declares one capability, and an instrumented file system records zero
write/append/delete/makeDir calls), and a missing file degrades to a fixed line
instead of raising.

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")

rawset(_G, "PYROET_SETTINGS_TEST", true)
local M = assert(loadfile("/system/system/settings.app/main.lua"))()
rawset(_G, "PYROET_SETTINGS_TEST", nil)
local manifest_raw = assert(loadfile("/system/system/settings.app/manifest.lua"))()

local CONFIG = table.concat({
    "# node configuration",
    "ip=10.0.0.5",
    "prefix=24",
    "gateway=10.0.0.1",
    "channel=4100",
    "psk=deadbeefcafe",
    "role=host",
    "this line has no equals sign",
}, "\r\n") .. "\r\n"

local INSTALL_SET = table.concat({
    "# pyroet-os/install.set",
    "pyroet-os/startup.lua",
    "pyroet-os/system/kernel/apps.lua",
}, "\n") .. "\n"

local function stub_sys(opts)
    local o = opts or {}
    return {
        apps = function() return o.apps or {} end,
        status = function()
            return {
                health = o.health or "ok",
                services = o.services or {
                    { name = "net", state = "running", healthy = o.net_health or "ok" },
                },
            }
        end,
        perms = function(name)
            local map = o.perms or {}
            return map[name]
        end,
    }
end

local function fake_api(opts)
    local o = opts or {}
    local files = o.files or {}
    local api = { logs = {}, writes = 0, reads = 0 }
    api.files = files
    api.fs = {
        read = function(path)
            api.reads = api.reads + 1
            local text = files[path]
            if text == nil then return nil, "missing file: " .. tostring(path) end
            return text
        end,
        getFreeSpace = function()
            if o.free == nil then return nil end
            return o.free
        end,
        write = function() api.writes = api.writes + 1; return true end,
        append = function() api.writes = api.writes + 1; return true end,
        delete = function() api.writes = api.writes + 1; return true end,
        makeDir = function() api.writes = api.writes + 1; return true end,
    }
    api.sys = o.sys
    api.log = function(message) api.logs[#api.logs + 1] = tostring(message) end
    api.yield = function() end
    return api
end

local ALL_APPS = {
    { name = "launcher", version = "0.1.0", state = "running",
        capabilities = { "fs.read", "fs.write" } },
    { name = "net", version = "0.1.0", state = "loaded",
        capabilities = { "net.rpv", "fs.read" } },
    { name = "settings", version = "0.1.0", state = "running",
        capabilities = { "fs.read" } },
}

local function machine(opts)
    local o = opts or {}
    return fake_api({
        files = o.files or {
            ["/boot.ok"] = "PYROET-BOOT-OK-2 version=2.0.0 manifest_sha="
                .. string.rep("ef", 32) .. " ts=1700000000000\n",
            ["/etc/network.conf"] = CONFIG,
            ["/etc/install.set"] = INSTALL_SET,
        },
        sys = o.sys or stub_sys({
            apps = ALL_APPS,
            perms = {
                launcher = { ["fs.read"] = true, ["fs.write"] = false },
                net = { ["net.rpv"] = false, ["fs.read"] = true },
            },
        }),
        free = o.free == nil and 26214 or o.free,
    })
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("settings.manifest")
    do
        local manifest, err = APPS.validate_manifest(manifest_raw, "/system/system/settings.app")
        H.table("manifest", manifest)
        H.eq("manifest_error", err, nil)
        H.eq("manifest_name", manifest and manifest.name, "settings")
        H.eq("manifest_version", manifest and manifest.version, "0.1.0")
        H.eq("manifest_entry", manifest and manifest.entry, "main.lua")
        H.eq("cap_count", manifest and #manifest.capabilities, 1)
        H.eq("only_read", manifest and manifest.capabilities[1], "fs.read")
        local has_write = false
        for i = 1, #(manifest and manifest.capabilities or {}) do
            if manifest.capabilities[i] == "fs.write" then has_write = true end
        end
        H.eq("no_write_cap", has_write, false)
        H.eq("entry_is_body",
            type(assert(loadfile("/system/system/settings.app/main.lua"))()), "function")
        H.eq("view_cols", M.VIEW.cols, 26)
        H.eq("view_rows", M.VIEW.rows, 20)
        H.eq("budget", M.BUDGET, 629145)
        H.eq("stretch", M.STRETCH, 349525)
        H.eq("window", M.WINDOW, 900000)
        H.eq("backup_cap", M.BACKUP_CAP, 200000)
        H.eq("budget_under_window", M.BUDGET + M.BACKUP_CAP <= M.WINDOW, true)
        H.ascii_check("main_ascii", H.read("/system/system/settings.app/main.lua") or "")
        H.ascii_check("manifest_ascii", H.read("/system/system/settings.app/manifest.lua") or "")
    end

    -- -----------------------------------------------------------------
    H.group("settings.conf")
    do
        local entries, bad = M.parse_conf(CONFIG)
        H.eq("conf_entries", #entries, 6)
        H.eq("conf_bad", bad, 1)
        H.eq("conf_first_key", entries[1] and entries[1].key, "ip")
        H.eq("conf_first_value", entries[1] and entries[1].value, "10.0.0.5")
        H.eq("conf_last_key", entries[6] and entries[6].key, "role")

        H.eq("conf_empty", #(M.parse_conf("")), 0)
        local comments = M.parse_conf("# only a comment\n\n")
        H.eq("conf_comments", #comments, 0)

        -- secrets never reach the screen
        H.eq("redact_psk", M.redacted("psk", "deadbeef"), "***")
        H.eq("redact_psk_file", M.redacted("psk_file", "x"), "***")
        H.eq("redact_password", M.redacted("password", "hunter2"), "***")
        H.eq("redact_secret", M.redacted("session_secret", "x"), "***")
        H.eq("redact_token", M.redacted("api_token", "x"), "***")
        H.eq("redact_plain", M.redacted("ip", "10.0.0.5"), "10.0.0.5")
        H.eq("redact_case", M.redacted("PSK", "x"), "***")

        local conf, bads, error_text = M.read_conf(machine())
        H.eq("read_conf_count", #conf, 6)
        H.eq("read_conf_bad", bads, 1)
        H.eq("read_conf_error", error_text, nil)
        local psk = conf[5]
        H.eq("read_conf_psk_key", psk and psk.key, "psk")
        H.eq("read_conf_psk_redacted", psk and psk.value, "***")

        local missing_conf, _, missing_error = M.read_conf(fake_api({}))
        H.eq("missing_conf_count", #missing_conf, 0)
        H.contains("missing_conf_error", missing_error, "missing file")

        local install_entries = M.read_install_set(machine())
        H.eq("install_set_entries", install_entries, 2)
        H.eq("install_set_missing", M.read_install_set(fake_api({})), nil)
    end

    -- -----------------------------------------------------------------
    H.group("settings.apps")
    do
        local apps, apps_error = M.read_apps(machine())
        H.eq("apps_error", apps_error, nil)
        H.eq("apps_count", #apps, 3)
        H.eq("apps_sorted", apps[1] and apps[1].name, "launcher")
        H.eq("apps_second", apps[2] and apps[2].name, "net")
        H.eq("apps_third", apps[3] and apps[3].name, "settings")
        H.eq("apps_caps", #(apps[1] and apps[1].capabilities or {}), 2)
        H.eq("apps_granted", apps[1] and apps[1].grants["fs.read"], true)
        H.eq("apps_denied", apps[1] and apps[1].grants["fs.write"], false)
        H.eq("apps_no_decisions", apps[3] and apps[3].grants, nil)

        local none, none_error = M.read_apps(fake_api({}))
        H.eq("no_sys_apps", #none, 0)
        H.contains("no_sys_error", none_error, "system unavailable: apps")

        -- a runtime index that raises is a value, not a crash
        local broken, broken_error = M.read_apps({
            sys = { apps = function() error("index-boom") end },
        })
        H.eq("broken_apps", #broken, 0)
        H.contains("broken_error", broken_error, "index-boom")

        local sections = M.sections(M.build(machine()))
        local text = H.joined(sections)
        H.contains("section_system", text, "=== system ===")
        H.contains("section_apps", text, "=== apps ===")
        H.contains("section_conf", text, "=== conf ===")
        H.contains("section_storage", text, "=== storage ===")
        H.contains("app_line", text, "launcher 0.1.0")
        H.contains("cap_granted", text, "  fs.read granted")
        H.contains("cap_denied", text, "  fs.write denied")
        H.contains("cap_pending", text, "  fs.read pending")
        H.contains("net_cap_denied", text, "  net.rpv denied")
        H.contains("conf_ip", text, "ip 10.0.0.5")
        H.contains("conf_bad_line", text, "bad conf lines 1")
        H.contains("storage_budget", text, "gate 629145 B")
        H.contains("storage_target", text, "target 349525 B")
        H.contains("storage_window", text, "window 900000 B")
        H.contains("storage_backup_cap", text, "backup cap 200000 B")
        H.contains("storage_free", text, "free 26214 B")
        H.contains("storage_install", text, "install.set 2 entries")
        H.absent("no_secret_value", text, "deadbeef")
    end

    -- -----------------------------------------------------------------
    H.group("settings.render")
    do
        local api = machine()
        local state = M.build(api)
        local lines = M.render(state, 26, 20)
        H.eq("rows", #lines, 20)
        for i = 1, #lines do H.eq("width_" .. tostring(i), #lines[i], 26) end
        H.contains("title", lines[1], "Settings 0.1.0")
        H.contains("status_row", lines[20], "ro 3 apps 26x20")
        H.eq("status_width", #lines[20], 26)

        -- a tall view holds the whole body
        local tall = M.render(state, 26, 40)
        H.eq("tall_rows", #tall, 40)
        for i = 1, #tall do H.eq("tall_width_" .. tostring(i), #tall[i], 26) end
        local tall_text = H.joined(tall)
        H.contains("tall_system", tall_text, "os 0.1.0")
        H.contains("tall_image", tall_text, "image 2.0.0")
        H.contains("tall_sha", tall_text, "image 2.0.0 sha efefefef")
        H.absent("tall_no_slot", tall_text, "slot")
        H.eq("short_sha", M.short_sha(string.rep("ef", 32)), "efefefef")
        H.eq("short_sha_none", M.short_sha(nil), nil)
        H.eq("short_sha_bad", M.short_sha("not-hex"), nil)
        H.contains("tall_net", tall_text, "net ok")
        H.contains("tall_storage", tall_text, "install.set 2 entries")
        H.contains("tall_redacted", tall_text, "psk ***")
        H.absent("tall_no_secret", tall_text, "deadbeef")

        -- a 20 row view truncates the body with a +N more line
        local text20 = H.joined(lines)
        H.contains("truncated_marker", text20, "more")
        H.contains("truncated_start", text20, "=== system ===")

        -- narrower than 26: same body, padded to the narrower width
        local narrow = M.render(state, 20, 20)
        H.eq("narrow_rows", #narrow, 20)
        H.eq("narrow_width", #narrow[3], 20)
        H.contains("narrow_title", narrow[1], "Settings")

        -- degenerate views collapse to one status row
        local tiny = M.render(state, 10, 20)
        H.eq("tiny_rows", #tiny, 1)
        H.contains("tiny_text", tiny[1], "settings")
        H.eq("tiny_width", #tiny[1], 10)
        H.contains("narrow_status", M.render(state, 20, 20)[20], "ro 3 apps 20x20")
        local short = M.render(state, 26, 4)
        H.eq("short_rows", #short, 1)

        -- every size stays inside its own box
        for _, cols in ipairs({ 8, 12, 16, 20, 26, 40 }) do
            for _, rows in ipairs({ 3, 6, 8, 20, 40 }) do
                local size = tostring(cols) .. "x" .. tostring(rows)
                local fitted = M.render(state, cols, rows)
                local want_rows = (cols >= M.MIN_COLS and rows >= M.MIN_ROWS) and rows or 1
                H.eq("sweep_rows_" .. size, #fitted, want_rows)
                local widest = 0
                for i = 1, #fitted do
                    if #fitted[i] > widest then widest = #fitted[i] end
                end
                H.eq("sweep_width_" .. size, widest <= cols, true)
            end
        end

        -- missing everything: the fixed degrade lines, never an error
        local empty = M.build(fake_api({}))
        local empty_lines = M.render(empty, 26, 40)
        local empty_text = H.joined(empty_lines)
        H.contains("empty_system", empty_text, "os 0.1.0")
        H.contains("empty_image", empty_text, "image ?")
        H.absent("empty_no_slot", empty_text, "slot")
        H.contains("empty_apps", empty_text, "apps n/a")
        H.contains("empty_conf", empty_text, "conf n/a")
        H.contains("empty_free", empty_text, "free n/a")
        H.contains("empty_install", empty_text, "install.set n/a")
        H.contains("empty_net", empty_text, "net off")
        H.eq("empty_status", empty_lines[40], M.fit("ro 0 apps 26x40", 26))

        -- a runtime without app capabilities still renders the app table
        local nocaps = M.build(machine({
            sys = stub_sys({ apps = { { name = "bare", version = "9.9.9",
                capabilities = {} } } }),
        }))
        H.contains("no_caps_line", H.joined(M.sections(nocaps)), "no capabilities")
        H.contains("no_caps_app", H.joined(M.sections(nocaps)), "bare 9.9.9")

        H.eq("fit_short", M.fit("ab", 4), "ab  ")
        H.eq("fit_long", M.fit("abcdef", 3), "abc")
        H.eq("fit_control", M.fit("a\tb", 3), "a?b")
    end

    -- -----------------------------------------------------------------
    H.group("settings.readonly")
    do
        local api = machine()
        local state = M.build(api)
        M.render(state, 26, 20)
        M.render(state, 26, 40)
        M.render(state, 10, 3)
        M.run(nil, api, { max_frames = 2, paint = false })
        H.eq("no_writes", api.writes, 0)
        H.ge("did_read", api.reads, 4)

        -- instrumented real fs: the same claim against CraftOS itself
        local proxy, calls = H.fs()
        local fs_api = {
            read = function(path)
                if not proxy.exists(path) then return nil, "missing" end
                local handle = proxy.open(path, "r")
                if not handle then return nil, "unreadable" end
                local text = handle.readAll()
                handle.close()
                return text
            end,
            write = function(path, data)
                return proxy.open(path, "w") ~= nil
            end,
            append = function(path, data)
                return proxy.open(path, "a") ~= nil
            end,
            delete = function(path) return proxy.delete(path) end,
            makeDir = function(path) return proxy.makeDir(path) end,
        }
        local real_state = M.build({
            fs = fs_api,
            sys = stub_sys({ apps = {} }),
        }, { conf_path = "/system/system/settings.app/manifest.lua" })
        M.render(real_state, 26, 20)
        H.ge("real_read_calls", H.calls_to(calls, "open"), 1)
        H.ge("real_exists_calls", H.calls_to(calls, "exists"), 1)
        H.ge("real_conf_entries", #(real_state.conf or {}), 1)
        H.eq("real_no_delete_calls", H.calls_to(calls, "delete"), 0)
        H.eq("real_no_make_dir_calls", H.calls_to(calls, "makeDir"), 0)
        local write_opens = 0
        for i = 1, #calls do
            if calls[i].method == "open" and calls[i][2] ~= "r" then
                write_opens = write_opens + 1
            end
        end
        H.eq("no_write_mode_open", write_opens, 0)

        -- the runtime denies fs.write because the manifest never declares it
        local rt = APPS.new({ fs = H.real_fs(), log = H.logger(), apps_root = "/system/system" })
        H.eq("runtime_scan", rt:scan(), 3)
        H.check("start_settings", rt:start("settings") == true, "start refused")
        local api_table = rt:app("settings").api
        local called, value, reason = pcall(api_table.fs.write, "/t/nope.txt", "x")
        H.eq("write_call_ok", called, true)
        H.eq("write_denied", value, nil)
        H.eq("write_reason", reason, "capability denied: fs.write")
        local read_value = api_table.fs.read("/system/system/settings.app/manifest.lua")
        H.contains("read_allowed", tostring(read_value), "settings")
        rt:tick()
        H.eq("still_running", rt:app("settings").state, "running")
        rt:kill("settings")
    end
end
