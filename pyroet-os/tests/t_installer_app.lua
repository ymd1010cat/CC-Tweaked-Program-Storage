--[[- pyroet-os/tests/t_installer_app.lua -- the Installer UI: manifest, scanning
-- (medium + both installed roots), the 26x20 layout, the install/uninstall
-- bridge and its failure lines, and the layout self test.

Two layers are driven here:

  * a fake file system (`files` path -> text, `dirs` path -> names), so a missing
    drive, a package without a manifest, a refused capability and a five item
    machine are each one table entry away;
  * a bridge recorder, so every install/uninstall call is an assertion and the
    app is never allowed to reach into /system/kernel/* by itself.

The app is staged as a fixture under /tests/installer.app (run-tests.ps1 explains
why it is not under /system/system for this suite); the last group proves the
package really belongs at /system/system/installer.app by asserting it against
/install.set and by scanning a case dir that mirrors the image layout.

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")

rawset(_G, "PYROET_INSTALLER_TEST", true)
local M = assert(loadfile("/tests/installer.app/main.lua"))()
rawset(_G, "PYROET_INSTALLER_TEST", nil)
local manifest_raw = assert(loadfile("/tests/installer.app/manifest.lua"))()

local BASE_FILES = {
    ["/disk/apps/box.app/manifest.lua"] = 'return { name = "box", version = "0.2.0",'
        .. ' capabilities = { "fs.read" } }\n',
    ["/disk/apps/box.app/main.lua"] = "return function(manifest, api) end\n",
    ["/disk/apps/zeta.app/manifest.lua"] = 'return { name = "zeta", version = "1.0.0" }\n',
    ["/disk/apps/zeta.app/main.lua"] = "return function(manifest, api) end\n",
    ["/apps/notes.app/manifest.lua"] = 'return { name = "notes", version = "0.3.0" }\n',
    ["/apps/notes.app/main.lua"] = "return function(manifest, api) end\n",
    ["/system/system/launcher.app/manifest.lua"] = 'return { name = "launcher",'
        .. ' version = "0.1.0" }\n',
    ["/system/system/launcher.app/main.lua"] = "return function(manifest, api) end\n",
    ["/system/system/settings.app/manifest.lua"] = 'return { name = "settings",'
        .. ' version = "0.1.0" }\n',
    ["/system/system/settings.app/main.lua"] = "return function(manifest, api) end\n",
}

local BASE_DIRS = {
    ["/disk"] = { "apps" },
    ["/disk/apps"] = { "box.app", "zeta.app", "readme.txt" },
    ["/apps"] = { "notes.app" },
    ["/system/system"] = { "launcher.app", "settings.app" },
}

local function copy_map(source)
    local out = {}
    for key, value in pairs(source or {}) do out[key] = value end
    return out
end

local function fake_api(opts)
    local o = opts or {}
    local files, dirs = o.files or {}, o.dirs or {}
    local api = { logs = {}, calls = { list = 0, read = 0, write = 0 } }
    api.files, api.dirs = files, dirs
    api.fs = {
        read = function(path)
            api.calls.read = api.calls.read + 1
            local text = files[path]
            if text == nil then return nil, "missing file: " .. tostring(path) end
            return text
        end,
        list = function(path)
            api.calls.list = api.calls.list + 1
            if o.list_denied then return nil, "capability denied: fs.read" end
            local names = dirs[path]
            if names == nil then return nil, "no directory: " .. tostring(path) end
            local copy = {}
            for i = 1, #names do copy[i] = names[i] end
            return copy
        end,
        exists = function(path)
            if files[path] ~= nil or dirs[path] ~= nil then return true end
            return false
        end,
        write = function(path, data)
            api.calls.write = api.calls.write + 1
            files[path] = data
            return true
        end,
        delete = function(path)
            if dirs[path] ~= nil then
                dirs[path] = nil
                return true
            end
            if files[path] ~= nil then
                files[path] = nil
                return true
            end
            return false
        end,
        makeDir = function(path)
            if dirs[path] == nil then dirs[path] = {} end
            return true
        end,
    }
    api.sys = o.sys
    api.installer = o.installer
    api.log = function(message) api.logs[#api.logs + 1] = tostring(message) end
    api.yield = function() end
    return api
end

local INSTALLED = {
    { name = "launcher", version = "0.1.0", state = "running" },
    { name = "notes", version = "0.3.0", state = "loaded" },
    { name = "settings", version = "0.1.0", state = "loaded" },
}

local function stub_sys(opts)
    local o = opts or {}
    return {
        apps = function()
            if o.apps_error then error("apps-boom") end
            return o.apps ~= nil and o.apps or INSTALLED
        end,
        install = o.install,
        uninstall = o.uninstall,
    }
end

-- a machine: two packages on the medium, one installed, two in the image
local function machine(opts)
    local o = opts or {}
    local files = o.files or copy_map(BASE_FILES)
    local dirs = o.dirs or copy_map(BASE_DIRS)
    return fake_api({
        files = files,
        dirs = dirs,
        sys = o.sys or stub_sys(o),
        installer = o.installer,
        list_denied = o.list_denied,
    })
end

-- a bridge that records every call, so "did the app call the installer" is a
-- table length instead of a guess
local function recorder(opts)
    local o = opts or {}
    local rec = { installs = {}, removes = {} }
    rec.install = function(name)
        rec.installs[#rec.installs + 1] = name
        if o.install_error then error(o.install_error) end
        return o.install_ok, o.install_detail
    end
    rec.uninstall = function(name)
        rec.removes[#rec.removes + 1] = name
        if o.remove_error then error(o.remove_error) end
        return o.remove_ok, o.remove_detail
    end
    return rec
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("installer.manifest")
    do
        local manifest, err = APPS.validate_manifest(manifest_raw, "installer.app")
        H.table("manifest", manifest)
        H.eq("manifest_error", err, nil)
        H.eq("manifest_name", manifest and manifest.name, "installer")
        H.eq("manifest_version", manifest and manifest.version, "0.2.0")
        H.eq("manifest_entry", manifest and manifest.entry, "main.lua")
        H.eq("cap_count", manifest and #manifest.capabilities, 4)
        H.eq("cap_input", manifest and manifest.capabilities[3], "input")
        H.eq("cap_terminal", manifest and manifest.capabilities[4], "terminal")
        H.eq("cap_read", manifest and manifest.capabilities[1], "fs.read")
        H.eq("cap_write", manifest and manifest.capabilities[2], "fs.write")
        H.eq("entry_is_body",
            type(assert(loadfile("/tests/installer.app/main.lua"))()), "function")
        H.check("layout_selftest_present", type(M.layout_selftest) == "function",
            "no layout_selftest")
        H.eq("view_cols", M.VIEW.cols, 26)
        H.eq("view_rows", M.VIEW.rows, 20)
        H.eq("min_cols", M.MIN_COLS, 16)
        H.eq("min_rows", M.MIN_ROWS, 6)
        H.eq("medium", M.MEDIUM, "/disk/apps")
        H.eq("apps_root", M.APPS, "/apps")
        H.eq("system_root", M.SYSTEM, "/system/system")
        H.eq("sources", table.concat(M.SOURCES, ","), "disk,apps,system")
        local src = H.read("/tests/installer.app/main.lua") or ""
        H.check("source_present", #src > 4000, "source too short: " .. tostring(#src))
        -- the app must never reach a kernel module by itself: the bridge is the
        -- only way in, and the bridge is supplied by the host or by a test
        H.absent("no_kernel_path", src, "/system/kernel")
        H.ascii_check("main_ascii", src)
        H.ascii_check("manifest_ascii",
            H.read("/tests/installer.app/manifest.lua") or "")
    end

    -- -----------------------------------------------------------------
    H.group("installer.scan")
    do
        local api = machine()
        local entries, problems, disk_ok = M.scan(api)
        H.eq("disk_ok", disk_ok, true)
        H.eq("entry_count", #entries, 5)
        H.eq("problem_count", #problems, 0)
        H.eq("order", table.concat({
            entries[1].name, entries[2].name, entries[3].name,
            entries[4].name, entries[5].name }, ","), "box,zeta,notes,launcher,settings")
        H.eq("first_source", entries[1].source, "disk")
        H.eq("first_dir", entries[1].dir, "/disk/apps/box.app")
        H.eq("first_root", entries[1].root, "/disk/apps")
        H.eq("first_version", entries[1].version, "0.2.0")
        H.eq("second_version", entries[2].version, "1.0.0")
        H.eq("third_source", entries[3].source, "apps")
        H.eq("third_version", entries[3].version, "0.3.0")
        H.eq("fourth_source", entries[4].source, "system")
        H.eq("fourth_version", entries[4].version, "0.1.0")
        local tags = M.tag_of(entries[1]) .. M.tag_of(entries[2])
            .. M.tag_of(entries[3]) .. M.tag_of(entries[4])
            .. M.tag_of(entries[5])
        H.eq("tags", tags, "ddiss")
        H.eq("actions", M.action_of(entries[1]) .. "," .. M.action_of(entries[3])
            .. "," .. M.action_of(entries[5]), "install,remove,locked")
        H.eq("readme_ignored", M.manifest_version(api, "/disk/apps/readme.txt"), "?")

        -- a package directory without a manifest is reported, not listed
        local ghost_dirs = copy_map(BASE_DIRS)
        ghost_dirs["/disk/apps"] = { "box.app", "ghost.app" }
        local ghost = machine({ dirs = ghost_dirs })
        local ghost_entries, ghost_problems = M.scan(ghost)
        H.eq("ghost_entries", #ghost_entries, 4)
        local ghost_names = {}
        for i = 1, #ghost_entries do ghost_names[ghost_entries[i].name] = true end
        H.eq("ghost_not_listed", ghost_names.ghost, nil)
        H.contains("ghost_problem", H.joined(ghost_problems), "no manifest ghost")

        -- no drive at all: one problem line, no crash, no medium
        local no_disk_dirs = copy_map(BASE_DIRS)
        no_disk_dirs["/disk"] = nil
        no_disk_dirs["/disk/apps"] = nil
        local no_disk = machine({ dirs = no_disk_dirs })
        local disk_entries, disk_problems, has_disk = M.scan(no_disk)
        H.eq("no_disk_ok", has_disk, false)
        H.eq("no_disk_entries", #disk_entries, 3)
        H.absent("no_disk_problem", H.joined(disk_problems), "no disk")

        -- a refused fs.read is named as such, not as a missing directory
        local denied = fake_api({ list_denied = true })
        local denied_entries, denied_problems, denied_disk = M.scan(denied)
        H.eq("denied_entries", #denied_entries, 0)
        H.eq("denied_disk", denied_disk, false)
        H.contains("denied_problem", H.joined(denied_problems),
            "capability denied: fs.read")

        -- no runtime at all
        local nothing_entries, nothing_problems = M.scan(nil)
        H.eq("nothing_entries", #nothing_entries, 0)
        H.contains("nothing_problem", H.joined(nothing_problems),
            "capability denied")

        -- a missing installed root is a problem, the other root still scans
        local missing_dirs = copy_map(BASE_DIRS)
        missing_dirs["/apps"] = nil
        local missing = machine({ dirs = missing_dirs })
        local missing_entries, missing_problems = M.scan(missing)
        H.eq("missing_entries", #missing_entries, 4)
        H.contains("missing_problem", H.joined(missing_problems), "no root /apps")

        -- an empty machine: no problems, nothing to install
        local empty = fake_api({ dirs = { ["/disk/apps"] = {}, ["/apps"] = {},
            ["/system/system"] = {} } })
        local empty_entries, empty_problems, empty_disk = M.scan(empty)
        H.eq("empty_entries", #empty_entries, 0)
        H.eq("empty_problem_count", #empty_problems, 0)
        H.eq("empty_disk_ok", empty_disk, true)

        -- runtime index wins for installed versions; an unknown package is "?"
        local unknown = machine({
            sys = stub_sys({ apps = { { name = "launcher", version = "9.9.9",
                state = "loaded" } } }),
        })
        local unknown_entries = M.scan(unknown)
        local by_name = {}
        for i = 1, #unknown_entries do by_name[unknown_entries[i].name] = unknown_entries[i] end
        H.eq("runtime_version", by_name.launcher and by_name.launcher.version, "9.9.9")
        H.eq("runtime_state", by_name.launcher and by_name.launcher.state, "loaded")
        H.eq("unknown_version", by_name.settings and by_name.settings.version, "?")
        H.eq("unknown_state", by_name.settings and by_name.settings.state, nil)
    end

    -- -----------------------------------------------------------------
    H.group("installer.render")
    do
        local api = machine()
        local state = M.build(api, { version = "0.1.0" })
        local lines = M.render(state, 26, 20)
        H.eq("rows", #lines, 20)
        for i = 1, #lines do H.eq("width_" .. tostring(i), #lines[i], 26) end
        H.contains("row1_version", lines[1], "installer 0.1.0")
        H.contains("row2_disk", lines[2], "source disk")
        H.contains("row2_installed", lines[2], "3 installed")
        H.contains("row3_marker", lines[3], "> d box")
        H.contains("row3_version", lines[3], "0.2.0")
        H.contains("row4_medium", lines[4], "d zeta")
        H.contains("row5_apps", lines[5], "i notes")
        H.contains("row6_system", lines[6], "s launcher")
        H.contains("hint_install", lines[19], "enter install")
        H.contains("status_row", lines[20], "d2 i1 s2 sel 1/5")
        H.eq("status_width", #lines[20], 26)

        -- narrow: the version column is dropped, names survive
        local narrow = M.render(state, 20, 20)
        H.eq("narrow_rows", #narrow, 20)
        H.eq("narrow_width", #narrow[3], 20)
        H.eq("narrow_no_version", narrow[3]:find("0.2.0", 1, true), nil)
        H.contains("narrow_name", narrow[3], "box")

        -- every size stays inside its own box
        for _, cols in ipairs({ 10, 15, 16, 20, 25, 26, 40 }) do
            for _, rows in ipairs({ 4, 6, 8, 20 }) do
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

        -- the hint follows the selected row kind
        state.index = 3
        H.contains("hint_remove", M.render(state, 26, 20)[19], "enter remove")
        state.index = 4
        H.contains("hint_locked", M.render(state, 26, 20)[19], "system app locked")
        H.eq("action_locked", M.action_of(M.selected(state)), "locked")
        state.index = 1
        H.contains("hint_back_to_install", M.render(state, 26, 20)[19], "enter install")

        -- a message replaces the hint and is clamped to the row
        state.message = "installed box 0.2.0"
        H.contains("message_hint", M.render(state, 26, 20)[19], "installed box 0.2.0")
        state.message = string.rep("x", 80)
        H.eq("message_clamped", #M.render(state, 26, 20)[19], 26)
        state.message = ""

        -- the list scrolls, and the window keeps the selection visible
        local big_dirs = copy_map(BASE_DIRS)
        local many = {}
        for i = 1, 20 do many[i] = string.format("app%02d.app", i) end
        big_dirs["/disk/apps"] = many
        local big_files = copy_map(BASE_FILES)
        for i = 1, 20 do
            big_files[string.format("/disk/apps/app%02d.app/manifest.lua", i)] =
                string.format('return { name = "app%02d", version = "0.1.0" }\n', i)
            big_files[string.format("/disk/apps/app%02d.app/main.lua", i)] =
                "return function(manifest, api) end\n"
        end
        local big = machine({ files = big_files, dirs = big_dirs })
        local big_state = M.build(big, { version = "0.1.0" })
        H.eq("big_count", #big_state.entries, 23)
        H.eq("window_first", M.window(big_state, 16), 1)
        big_state.index = 23
        H.eq("window_last", M.window(big_state, 16), 8)
        local scrolled = M.render(big_state, 26, 20)
        H.contains("scrolled_marker", H.joined(scrolled), "> s settings")
        H.eq("scrolled_status", scrolled[20]:find("sel 23/23", 1, true) ~= nil, true)

        -- degenerate views: one status row, still informative
        local tiny = M.render(state, 12, 20)
        H.eq("tiny_rows", #tiny, 1)
        H.contains("tiny_text", tiny[1], "installer 5")
        H.eq("tiny_width", #tiny[1], 12)
        H.eq("short_rows", #M.render(state, 26, 4), 1)
        H.eq("one_rows", #M.render(state, 1, 1), 1)

        -- the three "nothing here" lines are distinct ASCII prompts
        local empty_state = M.build(fake_api({ dirs = { ["/disk/apps"] = {},
            ["/apps"] = {}, ["/system/system"] = {} } }), { version = "0.1.0" })
        H.contains("empty_hint", M.render(empty_state, 26, 20)[19], "no apps to install")
        H.contains("empty_status", M.render(empty_state, 26, 20)[20], "d0 i0 s0 sel 0/0")
        H.contains("empty_disk_text", M.render(empty_state, 26, 20)[2], "source ")
        local no_disk_dirs = copy_map(BASE_DIRS)
        no_disk_dirs["/disk/apps"] = nil
        no_disk_dirs["/apps"] = {}
        no_disk_dirs["/system/system"] = {}
        local no_disk_state = M.build(machine({ dirs = no_disk_dirs }),
            { version = "0.1.0" })
        H.contains("no_disk_hint", M.render(no_disk_state, 26, 20)[19],
            "no source: checked ")
        H.contains("no_disk_header", M.render(no_disk_state, 26, 20)[2], "source none")
        local denied_state = M.build(fake_api({ list_denied = true }),
            { version = "0.1.0" })
        H.contains("denied_hint", M.render(denied_state, 26, 20)[19],
            "capability denied: fs.read")
        H.eq("denied_no_crash", #M.render(denied_state, 26, 20), 20)

        -- helpers
        H.eq("fit_short", M.fit("ab", 4), "ab  ")
        H.eq("fit_long", M.fit("abcdef", 3), "abc")
        H.eq("fit_control", M.fit("a\tb", 3), "a?b")
        H.eq("plain_newline", M.plain("a\nb"), "a b")
        H.eq("key_of", M.key_of(state.entries[1]), "disk:box")
        H.eq("key_of_nil", M.key_of(nil), nil)
    end

    -- -----------------------------------------------------------------
    H.group("installer.install")
    do
        local rec = recorder({ install_ok = true, install_detail = { version = "0.2.0" } })
        local api = machine({ sys = stub_sys({ install = rec.install }) })
        local state = M.build(api, { version = "0.1.0" })
        H.eq("selection", M.selected(state).name, "box")
        local action, detail = M.activate(state, api)
        H.eq("install_action", action, "install")
        H.eq("install_detail", detail, "box")
        H.eq("install_calls", #rec.installs, 1)
        H.eq("install_called_with", rec.installs[1], "box")
        H.eq("install_message", state.message, "installed box 0.2.0")
        H.eq("install_recorded", state.installed, "box")
        H.eq("install_no_error", state.last_error, nil)
        H.eq("install_removes_untouched", #rec.removes, 0)
        H.check("install_rescanned", (state.scanned or 0) >= 2,
            "scanned=" .. tostring(state.scanned))
        H.eq("install_sys_surface_used", api.calls.list > 0, true)

        -- the version in the message falls back to the row when the host says
        -- nothing, and an installed row cannot be installed again
        local quiet = recorder({ install_ok = true })
        local api2 = machine({ sys = stub_sys({ install = quiet.install }) })
        local state2 = M.build(api2, { version = "0.1.0" })
        M.activate(state2, api2)
        H.eq("fallback_version_message", state2.message, "installed box 0.2.0")
        state2.index = 3
        H.eq("reinstall_refused", M.install_selected(state2, api2), "none")
        H.eq("reinstall_message", state2.message, "already installed")
        H.eq("reinstall_calls", #quiet.installs, 1)

        -- opts.installer beats the system surface (tests and explicit wiring)
        local from_opts = recorder({ install_ok = true, install_detail = { version = "7.0.0" } })
        local api3 = machine({ sys = stub_sys({ install = rec.install }) })
        local state3 = M.build(api3, { version = "0.1.0" })
        H.eq("opts_bridge_action", M.activate(state3, api3, { installer = from_opts }),
            "install")
        H.eq("opts_bridge_called", #from_opts.installs, 1)
        H.eq("opts_bridge_message", state3.message, "installed box 7.0.0")
        H.eq("sys_bridge_not_used", #rec.installs, 1)

        -- api.installer is the last resort, and works the same way
        local direct = recorder({ install_ok = true })
        local api4 = machine({ sys = stub_sys({}), installer = direct })
        local state4 = M.build(api4, { version = "0.1.0" })
        H.eq("api_bridge_action", M.activate(state4, api4), "install")
        H.eq("api_bridge_called", #direct.installs, 1)

        -- no bridge at all: reported, not crashed
        local bare = machine({ sys = stub_sys({}) })
        local bare_state = M.build(bare, { version = "0.1.0" })
        H.eq("no_bridge_action", M.activate(bare_state, bare), "unavailable")
        H.eq("no_bridge_message", bare_state.message, "installer unavailable")
        local nil_state = M.build(nil)
        H.eq("no_bridge_nil_api", M.install_selected(nil_state, nil), "none")
        H.eq("no_bridge_nil_api_message", nil_state.message, "nothing selected")

        -- a bridge with only uninstall is not an installer
        local half = { uninstall = function() return true end }
        local half_state = M.build(machine({ sys = half }), { version = "0.1.0" })
        H.eq("half_bridge_action", M.activate(half_state, machine({ sys = half })),
            "unavailable")

        -- the bridge raising is contained, and the error is kept for the log
        local raising = recorder({ install_error = "bridge-boom" })
        local raising_api = machine({ sys = stub_sys({ install = raising.install }) })
        local raising_state = M.build(raising_api, { version = "0.1.0" })
        H.eq("raising_action", M.activate(raising_state, raising_api), "error")
        H.eq("raising_message", raising_state.message, "install failed")
        H.contains("raising_error", raising_state.last_error or "", "bridge-boom")

        -- nothing selected
        local empty_state = M.build(fake_api({ dirs = { ["/disk/apps"] = {},
            ["/apps"] = {}, ["/system/system"] = {} } }), { version = "0.1.0" })
        H.eq("nothing_selected_action", M.activate(empty_state, nil), "none")
        H.eq("nothing_selected_message", empty_state.message, "nothing selected")
    end

    -- -----------------------------------------------------------------
    H.group("installer.failures")
    do
        local cases = {
            { name = "hash_digest", detail = "digest main.lua", action = "hash",
                message = "hash check failed" },
            { name = "hash_sums", detail = "bad sums line", action = "hash",
                message = "hash check failed" },
            { name = "hash_no_sha", detail = "no sha256", action = "hash",
                message = "hash check failed" },
            { name = "hash_unlisted", detail = "unlisted extra.txt", action = "hash",
                message = "hash check failed" },
            { name = "size_file", detail = "size main.lua", action = "size",
                message = "size check failed" },
            { name = "size_total", detail = "size 120/200", action = "size",
                message = "size check failed" },
            { name = "size_declared", detail = "bad size", action = "size",
                message = "size check failed" },
            { name = "cancelled", detail = "cancelled", action = "cancel",
                message = "cancelled" },
            { name = "no_source", detail = "no_source", action = "cancel",
                message = "cancelled: no source" },
            { name = "system_app", detail = "system app", action = "locked",
                message = "system app locked" },
            { name = "not_installed", detail = "not installed", action = "missing",
                message = "not installed" },
            { name = "denied", detail = "capability denied: fs.write", action = "denied",
                message = "capability denied: fs.write" },
            { name = "unavailable", detail = "installer unavailable",
                action = "unavailable", message = "installer unavailable" },
            { name = "unknown", detail = "copy failed /disk/apps", action = "error",
                message = "failed: copy failed /disk/apps" },
        }
        for i = 1, #cases do
            local case = cases[i]
            local rec = recorder({ install_ok = false, install_detail = case.detail })
            local api = machine({ sys = stub_sys({ install = rec.install }) })
            local state = M.build(api, { version = "0.1.0" })
            local action = M.activate(state, api)
            H.eq(case.name .. "_action", action, case.action)
            H.eq(case.name .. "_message", state.message, case.message)
            H.eq(case.name .. "_error_kept", state.last_error, case.detail)
            H.eq(case.name .. "_called", #rec.installs, 1)
            H.eq(case.name .. "_not_installed", state.installed, nil)
        end
        -- error_text is the single mapping point, and it never returns nothing
        local text, class = M.error_text(nil)
        H.eq("error_nil_text", text, "install failed")
        H.eq("error_nil_class", class, "error")
        local text2, class2 = M.error_text("digest x")
        H.eq("error_digest_text", text2, "hash check failed")
        H.eq("error_digest_class", class2, "hash")
        local text3 = M.error_text(string.rep("z", 90))
        H.eq("error_truncated", #text3 <= 40 + 8, true)
        H.contains("error_truncated_text", text3, "failed: z")
        -- the hash class wins over the size class, because "digest" is checked first
        H.eq("error_order", select(2, M.error_text("digest size")), "hash")
    end

    -- -----------------------------------------------------------------
    H.group("installer.remove")
    do
        local rec = recorder({ remove_ok = true })
        local api = machine({ sys = stub_sys({ uninstall = rec.uninstall }) })
        local state = M.build(api, { version = "0.1.0" })
        state.index = 3
        local action, detail = M.activate(state, api)
        H.eq("remove_action", action, "remove")
        H.eq("remove_detail", detail, "notes")
        H.eq("remove_calls", #rec.removes, 1)
        H.eq("remove_called_with", rec.removes[1], "notes")
        H.eq("remove_message", state.message, "removed notes")
        H.eq("remove_recorded", state.removed, "notes")
        H.eq("remove_installs_untouched", #rec.installs, 0)

        -- /system is untouchable: refused on screen and never sent to the host
        local sys_rec = recorder({ remove_ok = true })
        local sys_api = machine({ sys = stub_sys({ uninstall = sys_rec.uninstall }) })
        local sys_state = M.build(sys_api, { version = "0.1.0" })
        sys_state.index = 4
        H.eq("system_remove_action", M.activate(sys_state, sys_api), "locked")
        H.eq("system_remove_message", sys_state.message, "system app locked")
        H.eq("system_remove_calls", #sys_rec.removes, 0)
        H.eq("system_remove_direct", M.remove_selected(sys_state, sys_api), "locked")
        H.eq("system_remove_after", #sys_rec.removes, 0)

        -- the installer itself may refuse: that is the same answer
        local refusing = recorder({ remove_ok = false, remove_detail = "system app" })
        local refuse_api = machine({ sys = stub_sys({ uninstall = refusing.uninstall }) })
        local refuse_state = M.build(refuse_api, { version = "0.1.0" })
        refuse_state.index = 3
        H.eq("host_refuse_action", M.activate(refuse_state, refuse_api), "locked")
        H.eq("host_refuse_message", refuse_state.message, "system app locked")
        H.eq("host_refuse_calls", #refusing.removes, 1)

        local missing = recorder({ remove_ok = false, remove_detail = "not installed" })
        local missing_api = machine({ sys = stub_sys({ uninstall = missing.uninstall }) })
        local missing_state = M.build(missing_api, { version = "0.1.0" })
        missing_state.index = 3
        H.eq("missing_action", M.activate(missing_state, missing_api), "missing")
        H.eq("missing_message", missing_state.message, "not installed")

        local raising = recorder({ remove_error = "remove-boom" })
        local raising_api = machine({ sys = stub_sys({ uninstall = raising.uninstall }) })
        local raising_state = M.build(raising_api, { version = "0.1.0" })
        raising_state.index = 3
        H.eq("remove_raise_action", M.activate(raising_state, raising_api), "error")
        H.eq("remove_raise_message", raising_state.message, "remove failed")
        H.contains("remove_raise_error", raising_state.last_error or "", "remove-boom")

        -- a medium row is not installed, so there is nothing to remove
        local disk_state = M.build(machine(), { version = "0.1.0" })
        H.eq("disk_remove_action", M.remove_selected(disk_state, machine()),
            "missing")
        H.eq("disk_remove_message", disk_state.message, "not installed")

        -- no bridge
        local bare_state = M.build(machine({ sys = stub_sys({}) }), { version = "0.1.0" })
        bare_state.index = 3
        H.eq("remove_no_bridge", M.activate(bare_state, machine({ sys = stub_sys({}) })),
            "unavailable")
        H.eq("remove_no_bridge_message", bare_state.message, "installer unavailable")

        -- nothing selected
        local empty_state = M.build(fake_api({ dirs = { ["/disk/apps"] = {},
            ["/apps"] = {}, ["/system/system"] = {} } }), { version = "0.1.0" })
        H.eq("remove_nothing", M.remove_selected(empty_state, nil), "none")
        H.eq("remove_nothing_message", empty_state.message, "nothing selected")
    end

    -- -----------------------------------------------------------------
    H.group("installer.keys")
    do
        local rec = recorder({ install_ok = true, install_detail = { version = "0.2.0" } })
        local api = machine({ sys = stub_sys({ install = rec.install,
            uninstall = recorder({ remove_ok = true }).uninstall }) })
        local state = M.build(api, { version = "0.1.0" })
        H.eq("keys_entry_count", #state.entries, 5)
        H.eq("keys_index", state.index, 1)
        H.eq("down_action", M.handle_key(state, "down", api), "move")
        H.eq("down_index", state.index, 2)
        H.eq("selected_key_after_down", state.selected_key, "disk:zeta")
        H.eq("up_action", M.handle_key(state, "up", api), "move")
        H.eq("up_index", state.index, 1)
        H.eq("up_wrap", M.handle_key(state, "up", api), "move")
        H.eq("up_wrap_index", state.index, 5)
        H.eq("down_wrap", M.handle_key(state, "down", api), "move")
        H.eq("down_wrap_index", state.index, 1)
        H.eq("left_is_up", M.handle_key(state, "left", api), "move")
        H.eq("left_index", state.index, 5)
        H.eq("right_is_down", M.handle_key(state, "right", api), "move")
        H.eq("right_index", state.index, 1)
        H.eq("digit_action", M.handle_key(state, "3", api), "select")
        H.eq("digit_index", state.index, 3)
        H.eq("digit_clamped", M.handle_key(state, "9", api), "select")
        H.eq("digit_clamped_index", state.index, 5)
        H.eq("zero_action", M.handle_key(state, "0", api), "none")
        H.eq("unknown_action", M.handle_key(state, "z", api), "none")
        H.eq("nil_key_action", M.handle_key(state, nil, api), "none")

        -- cancel clears the line; the selection stays put
        state.message = "installed box 0.2.0"
        H.eq("escape_action", M.handle_key(state, "escape", api), "cancel")
        H.eq("escape_message", state.message, "cancelled")
        H.eq("q_action", M.handle_key(state, "q", api), "cancel")
        H.eq("c_action", M.handle_key(state, "c", api), "cancel")
        H.eq("cancel_keeps_selection", state.index, 5)
        H.eq("move_clears_cancel", M.handle_key(state, "up", api), "move")
        H.eq("cleared_message", state.message, "")

        -- enter installs the selected medium row through the bridge
        state.index = 1
        H.eq("enter_action", M.handle_key(state, "enter", api), "install")
        H.eq("enter_called", rec.installs[1], "box")
        H.eq("enter_message", state.message, "installed box 0.2.0")
        -- and "return" is the same key
        local ret_rec = recorder({ install_ok = true })
        local ret_api = machine({ sys = stub_sys({ install = ret_rec.install }) })
        local ret_state = M.build(ret_api, { version = "0.1.0" })
        H.eq("return_action", M.handle_key(ret_state, "return", ret_api), "install")

        -- enter on /system is refused without a bridge call
        local lock_rec = recorder({})
        local lock_api = machine({ sys = stub_sys({ install = lock_rec.install,
            uninstall = lock_rec.uninstall }) })
        local lock_state = M.build(lock_api, { version = "0.1.0" })
        lock_state.index = 5
        H.eq("enter_locked_action", M.handle_key(lock_state, "enter", lock_api), "locked")
        H.eq("enter_locked_message", lock_state.message, "system app locked")
        H.eq("enter_locked_calls", #lock_rec.installs + #lock_rec.removes, 0)

        -- an empty machine: no movement, no action, no crash
        local empty_state = M.build(fake_api({ dirs = { ["/disk/apps"] = {},
            ["/apps"] = {}, ["/system/system"] = {} } }), { version = "0.1.0" })
        H.eq("empty_down", M.handle_key(empty_state, "down", nil), "none")
        H.eq("empty_enter", M.handle_key(empty_state, "enter", nil), "none")
        H.eq("empty_enter_message", empty_state.message, "nothing selected")
    end

    -- -----------------------------------------------------------------
    H.group("installer.run")
    do
        local rec = recorder({ install_ok = true, install_detail = { version = "1.0.0" } })
        local api = machine({ sys = stub_sys({ install = rec.install }) })
        local frames = 0
        local seen = nil
        local state = M.run(nil, api, {
            max_frames = 4,
            keys = { "down", "enter" },
            paint = false,
            term = { getSize = function() return 26, 20 end },
            each = function(s, lines)
                frames = frames + 1
                seen = lines
            end,
        })
        H.eq("run_frames", frames, 4)
        H.eq("run_installs", #rec.installs, 1)
        H.eq("run_installed_name", rec.installs[1], "zeta")
        H.eq("run_state_installed", state.installed, "zeta")
        H.eq("run_message", state.message, "installed zeta 1.0.0")
        H.eq("run_lines_rows", #seen, 20)
        H.eq("run_version_from_module", state.version, M.VERSION)
        H.table("run_state", state)

        -- the body is what the runtime file returns
        H.eq("entry_returns_body", type(assert(loadfile("/tests/installer.app/main.lua"))()),
            "function")

        -- scanning is throttled: the first frame of build() scans once, and the
        -- default interval keeps the next four frames from scanning again
        local throttled = machine()
        M.run(nil, throttled, { max_frames = 4, paint = false })
        H.eq("scan_once", throttled.calls.list, 4)
        -- interval 1 rescans on every frame: build + three loop frames
        local eager = machine()
        M.run(nil, eager, { max_frames = 3, scan_interval = 1, paint = false })
        H.eq("scan_every_frame", eager.calls.list, 16)

        -- keys as an iterator work the same way
        local iter_rec = recorder({ install_ok = true })
        local iter_api = machine({ sys = stub_sys({ install = iter_rec.install }) })
        local pulled = 0
        local keys = function()
            pulled = pulled + 1
            if pulled == 1 then return "down" end
            if pulled == 2 then return "enter" end
            return nil
        end
        M.run(nil, iter_api, { max_frames = 3, keys = keys, paint = false })
        H.eq("iterator_installed", iter_rec.installs[1], "zeta")

        -- the view is clamped to 26x20 whatever the terminal says
        local wide = { getSize = function() return 40, 30 end }
        local wc, wr = M.view_size(wide)
        H.eq("view_wide_cols", wc, 26)
        H.eq("view_wide_rows", wr, 20)
        local small = { getSize = function() return 20, 10 end }
        local sc, sr = M.view_size(small)
        H.eq("view_small_cols", sc, 20)
        H.eq("view_small_rows", sr, 10)
        local broken = { getSize = function() error("no terminal") end }
        local bc, br = M.view_size(broken)
        H.eq("view_broken_cols", bc, 26)
        H.eq("view_broken_rows", br, 20)
        H.eq("paint_without_terminal", M.paint({ "x" }, {}), false)
        H.eq("paint_nopaint_hook", M.paint({ "x" }, {
            setCursorPos = function() end, write = function() end }), false)
    end

    -- -----------------------------------------------------------------
    H.group("installer.selftest")
    do
        local ok, problems = M.layout_selftest()
        H.check("selftest", ok, table.concat(problems or {}, ","))
        H.eq("selftest_problems", #(problems or {}), 0)
        H.eq("selftest_alias", M.layout_selftest, M.selftest)
        H.eq("selftest_sample_rows", #M.render(M.sample_state(), 26, 20), 20)
        H.eq("selftest_sample_status", M.render(M.sample_state(), 26, 20)[20]:find(
            "d1 i1 s1 sel 1/3", 1, true) ~= nil, true)
    end

    -- -----------------------------------------------------------------
    H.group("installer.package")
    do
        -- the image manifest is the authority for the shipped path, and the
        -- package really is a system package: copy the two files into a case
        -- dir that mirrors /system/system and let the runtime validate it
        local install_set = H.read("/install.set") or ""
        H.contains("install_set_main", install_set,
            "pyroet-os/system/system/installer.app/main.lua")
        H.contains("install_set_manifest", install_set,
            "pyroet-os/system/system/installer.app/manifest.lua")
        local dir = H.case_dir("installer", "pkg")
        local main_src = assert(H.read("/tests/installer.app/main.lua"))
        local man_src = assert(H.read("/tests/installer.app/manifest.lua"))
        H.write(dir .. "/system/system/installer.app/main.lua", main_src)
        H.write(dir .. "/system/system/installer.app/manifest.lua", man_src)
        local log, lines = H.logger()
        local rt = APPS.new({ fs = H.real_fs(), log = log,
            apps_root = dir .. "/system/system" })
        H.eq("package_scan", rt:scan(), 1)
        H.has(lines, "APP_LOAD name=installer version=0.2.0 caps=fs.read,fs.write,input,terminal")
        local record = rt:app("installer")
        H.table("package_record", record)
        H.eq("package_name", record and record.name, "installer")
        H.eq("package_entry", record and record.entry_path,
            dir .. "/system/system/installer.app/main.lua")
        H.eq("package_caps", record and table.concat(record.manifest.capabilities, ","),
            "fs.read,fs.write,input,terminal")
        -- both capabilities really are granted to the package
        H.check("package_start", rt:start("installer") == true, "start refused")
        local api = rt:app("installer").api
        local called, listed = pcall(api.fs.list, "/")
        H.eq("package_list_callable", called, true)
        H.table("package_list", listed)
        local wrote, werr = pcall(api.fs.write, dir .. "/probe.txt", "x")
        H.eq("package_write_callable", wrote, true)
        H.eq("package_write_ok", werr, true)
        rt:kill("installer")
        H.eq("package_killed", rt:app("installer").state, "killed")
    end
end
