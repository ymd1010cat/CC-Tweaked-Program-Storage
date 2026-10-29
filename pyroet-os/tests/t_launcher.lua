--[[- pyroet-os/tests/t_launcher.lua -- the desktop: manifest, scanning, sorting,
-- selection, launch, status block, and the 26x20 width rules.

The app is driven through a fake file system (no emulator disk is touched) so
every fixture -- two roots, a missing manifest, a duplicate name, a denied
capability -- is one table entry away. The launch path goes through the same
`api.sys.launch` entry point the runtime hands out, never through a coroutine of
the app's own.

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local M = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)
local manifest_raw = assert(loadfile("/system/system/launcher.app/manifest.lua"))()

local function stub_sys(opts)
    local o = opts or {}
    return {
        apps = function() return o.apps or {} end,
        status = function()
            if o.status_error then return nil, o.status_error end
            return {
                health = o.health or "ok",
                services = o.services or {
                    { name = "net", state = "running", healthy = o.net_health or "ok" },
                },
            }
        end,
        perms = function() return o.perms end,
        launch = o.launch,
    }
end

-- a machine made of two tables: files (path -> text) and dirs (path -> names)
local function fake_api(opts)
    local o = opts or {}
    local files = o.files or {}
    local dirs = o.dirs or {}
    local api = { logs = {}, calls = { list = 0, read = 0, write = 0, mkdir = 0 } }
    api.files = files
    api.dirs = dirs
    api.fs = {
        read = function(path)
            api.calls.read = api.calls.read + 1
            local text = files[path]
            if text == nil then return nil, "missing file: " .. tostring(path) end
            return text
        end,
        list = function(path)
            api.calls.list = api.calls.list + 1
            local names = dirs[path]
            if names == nil then return nil, "no directory: " .. tostring(path) end
            local copy = {}
            for i = 1, #names do copy[i] = names[i] end
            return copy
        end,
        exists = function(path)
            if files[path] ~= nil then return true end
            if dirs[path] ~= nil then return true end
            return false
        end,
        write = function(path, data)
            api.calls.write = api.calls.write + 1
            files[path] = data
            return true
        end,
        makeDir = function(path)
            api.calls.mkdir = api.calls.mkdir + 1
            if dirs[path] == nil then dirs[path] = {} end
            return true
        end,
    }
    api.sys = o.sys
    api.log = function(message) api.logs[#api.logs + 1] = tostring(message) end
    api.yield = function() end
    if o.free ~= nil then
        api.fs.getFreeSpace = function() return o.free end
    end
    return api
end

local function machine(opts)
    local o = opts or {}
    local apps = o.apps or {
        { name = "box", version = "0.1.0", capabilities = { "fs.read" } },
        { name = "launcher", version = "0.1.0", capabilities = { "fs.read", "fs.write" } },
        { name = "net", version = "0.2.0", capabilities = { "net.rpv" } },
    }
    return fake_api({
        files = o.files or {
            ["/boot.ok"] = "PYROET-BOOT-OK-2 version=2.0.0 manifest_sha="
                .. string.rep("ab", 32) .. " ts=1700000000000\n",
            ["/apps/box.app/manifest.lua"] = "return {}\n",
            ["/system/system/launcher.app/manifest.lua"] = "return {}\n",
            ["/system/system/net.app/manifest.lua"] = "return {}\n",
        },
        dirs = o.dirs or {
            ["/apps"] = { "box.app", "notes.txt" },
            ["/system/system"] = { "launcher.app", "net.app", "readme.txt" },
        },
        sys = o.sys or stub_sys({ apps = apps }),
        free = o.free == nil and 26214 or o.free,
    })
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("launcher.manifest")
    do
        local manifest, err = APPS.validate_manifest(manifest_raw, "/system/system/launcher.app")
        H.table("manifest", manifest)
        H.eq("manifest_error", err, nil)
        H.eq("manifest_name", manifest and manifest.name, "launcher")
        H.eq("manifest_version", manifest and manifest.version, "0.1.0")
        H.eq("manifest_entry", manifest and manifest.entry, "main.lua")
        H.eq("cap_count", manifest and #manifest.capabilities, 2)
        H.eq("cap_read", manifest and manifest.capabilities[1], "fs.read")
        H.eq("cap_write", manifest and manifest.capabilities[2], "fs.write")
        H.eq("entry_is_body",
            type(assert(loadfile("/system/system/launcher.app/main.lua"))()), "function")
        H.eq("view_cols", M.VIEW.cols, 26)
        H.eq("view_rows", M.VIEW.rows, 20)
        H.eq("min_cols", M.MIN_COLS, 16)
        H.eq("min_rows", M.MIN_ROWS, 6)
        H.eq("roots", table.concat(M.ROOTS, ","), "/apps,/system/system")
        H.ascii_check("main_ascii", H.read("/system/system/launcher.app/main.lua") or "")
        H.ascii_check("manifest_ascii", H.read("/system/system/launcher.app/manifest.lua") or "")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.boot")
    do
        -- one global marker: version plus the manifest hash of the running tree
        local info = M.read_boot(machine())
        H.eq("version", info.version, "2.0.0")
        H.eq("sha", info.sha256, string.rep("ab", 32))
        H.eq("source", info.source, "/boot.ok")
        H.eq("short_sha", M.short_sha(info.sha256), "abababab")
        H.eq("no_slot_field", info.slot, nil)

        -- a marker without a version or hash: both stay unknown, no marker file
        local nothing = M.read_boot(fake_api({}))
        H.eq("nothing_version", nothing.version, nil)
        H.eq("nothing_sha", nothing.sha256, nil)
        H.eq("nothing_source", nothing.source, nil)

        -- manifest_sha=none is a sentinel, not a hash, and never reaches the row
        local none = fake_api({ files = {
            ["/boot.ok"] = "PYROET-BOOT-OK-2 version=9.9.9 manifest_sha=none ts=1\n",
        } })
        local none_info = M.read_boot(none)
        H.eq("none_version", none_info.version, "9.9.9")
        H.eq("none_sha_dropped", none_info.sha256, nil)
        H.eq("none_source", none_info.source, "/boot.ok")
        H.eq("none_short", M.short_sha(none_info.sha256), nil)

        -- a v1 marker on the same path still carries a version and a sha256
        local legacy = fake_api({ files = {
            ["/boot.ok"] = "PYROET-BOOT-OK-1 slot=a version=1.0.0 sha256="
                .. string.rep("cd", 32) .. " ts=1\n",
        } })
        local legacy_info = M.read_boot(legacy)
        H.eq("legacy_version", legacy_info.version, "1.0.0")
        H.eq("legacy_sha", legacy_info.sha256, string.rep("cd", 32))
        H.eq("legacy_no_slot_field", legacy_info.slot, nil)

        -- junk: a marker with no version reads as no version, never a crash
        local junk = M.read_boot(fake_api({ files = { ["/boot.ok"] = "a b!\n" } }))
        H.eq("junk_version", junk.version, nil)
        H.eq("junk_short", M.short_sha(junk.sha256), nil)
        H.eq("junk_valid_hex", M.short_sha("not-hex-at-all"), nil)

        local denied = M.read_file({}, "/boot.ok")
        H.eq("read_denied", denied, nil)
        local _, reason = M.read_file({}, "/boot.ok")
        H.eq("read_reason", reason, "capability denied: fs.read")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.scan")
    do
        local api = machine()
        local entries, problems = M.scan(api)
        H.eq("entry_count", #entries, 3)
        H.eq("sorted_first", entries[1] and entries[1].name, "box")
        H.eq("sorted_second", entries[2] and entries[2].name, "launcher")
        H.eq("sorted_third", entries[3] and entries[3].name, "net")
        H.eq("first_dir", entries[1] and entries[1].dir, "/apps/box.app")
        H.eq("first_root", entries[1] and entries[1].root, "/apps")
        H.eq("third_root", entries[3] and entries[3].root, "/system/system")
        H.eq("version_from_runtime", entries[3] and entries[3].version, "0.2.0")
        H.eq("problems_empty", #problems, 0)
        -- a package the runtime did not load is still on the desktop
        H.eq("box_version", entries[1] and entries[1].version, "0.1.0")

        -- a directory without a manifest is reported, not listed
        local no_manifest = fake_api({
            dirs = { ["/apps"] = { "ghost.app" }, ["/system/system"] = {} },
        })
        local ghost_entries, ghost_problems = M.scan(no_manifest)
        H.eq("ghost_entries", #ghost_entries, 0)
        H.contains("ghost_problem", H.joined(ghost_problems), "no manifest ghost")

        -- the same app in both roots: first root wins, the duplicate is noted
        local duplicate = fake_api({
            files = {
                ["/apps/net.app/manifest.lua"] = "return {}\n",
                ["/system/system/net.app/manifest.lua"] = "return {}\n",
            },
            dirs = { ["/apps"] = { "net.app" }, ["/system/system"] = { "net.app" } },
        })
        local dup_entries, dup_problems = M.scan(duplicate)
        H.eq("duplicate_count", #dup_entries, 1)
        H.eq("duplicate_root", dup_entries[1] and dup_entries[1].root, "/apps")
        H.contains("duplicate_problem", H.joined(dup_problems), "duplicate net")

        -- a missing root and a missing capability are both just problems
        local missing = fake_api({ dirs = { ["/system/system"] = {} } })
        local missing_entries, missing_problems = M.scan(missing)
        H.eq("missing_entries", #missing_entries, 0)
        H.contains("missing_problem", H.joined(missing_problems), "no root /apps")

        local denied_entries, denied_problems = M.scan({})
        H.eq("denied_entries", #denied_entries, 0)
        H.contains("denied_problem", H.joined(denied_problems), "fs.read denied")

        local empty_entries, empty_problems = M.scan(fake_api({
            dirs = { ["/apps"] = {}, ["/system/system"] = {} },
        }))
        H.eq("empty_entries", #empty_entries, 0)
        H.eq("empty_problems", #empty_problems, 0)

        -- the version column is fed by api.sys.apps, and absent means "?"
        local no_sys = fake_api({
            files = { ["/apps/mystery.app/manifest.lua"] = "return {}\n" },
            dirs = { ["/apps"] = { "mystery.app" }, ["/system/system"] = {} },
        })
        local mystery = M.scan(no_sys)
        H.eq("mystery_version", mystery[1] and mystery[1].version, "?")
        H.eq("mystery_state", mystery[1] and mystery[1].state, "unknown")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.render")
    do
        local api = machine()
        local state = M.build(api)
        local lines = M.render(state, 26, 20)
        H.eq("rows", #lines, 20)
        for i = 1, #lines do H.eq("width_" .. tostring(i), #lines[i], 26) end
        H.contains("row1_version", lines[1], "ver 2.0.0")
        H.contains("row1_hash", lines[1], "sha abababab")
        H.absent("no_slot_text", H.joined(lines), "slot")
        H.contains("row2_net", lines[2], "net ok")
        H.contains("row2_free", lines[2], "free 25K")
        H.contains("list_first", lines[3], "box")
        H.contains("list_version", lines[3], "0.1.0")
        H.eq("list_marker_selected", lines[3]:sub(1, 1), ">")
        H.contains("hint", lines[19], "up/dn enter run")
        H.contains("status_row", lines[20], "3 apps sel 1/3")
        H.eq("status_width", #lines[20], 26)

        -- narrower than 26 columns: the version column is dropped
        local narrow = M.render(state, 20, 20)
        H.eq("narrow_rows", #narrow, 20)
        H.eq("narrow_width", #narrow[3], 20)
        H.eq("narrow_no_version", narrow[3]:find("0.1.0", 1, true), nil)
        H.contains("narrow_name", narrow[3], "box")

        -- every size stays inside its own box
        for _, cols in ipairs({ 10, 12, 16, 20, 25, 26, 40 }) do
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

        -- degenerate views: one status row, still informative
        local tiny = M.render(state, 10, 20)
        H.eq("tiny_rows", #tiny, 1)
        H.contains("tiny_text", tiny[1], "launcher 3")
        local short = M.render(state, 26, 4)
        H.eq("short_rows", #short, 1)

        -- no free space reading, no net service: the header degrades
        local no_free = fake_api({ dirs = { ["/apps"] = {}, ["/system/system"] = {} } })
        local no_free_state = M.build(no_free)
        local no_free_lines = M.render(no_free_state, 26, 20)
        H.contains("free_na", no_free_lines[2], "free n/a")
        H.contains("net_off", no_free_lines[2], "net off")
        H.contains("no_apps_hint", no_free_lines[19], "no apps installed")
        H.contains("no_apps_status", no_free_lines[20], "0 apps sel 0/0")

        -- a down service and a degraded one are distinct on screen
        local down = M.build(fake_api({
            dirs = { ["/apps"] = {}, ["/system/system"] = {} },
            sys = stub_sys({ services = { { name = "net", state = "failed" } } }),
        }))
        H.contains("net_down", M.render(down, 26, 20)[2], "net down")
        local degraded = M.build(fake_api({
            dirs = { ["/apps"] = {}, ["/system/system"] = {} },
            sys = stub_sys({ net_health = "degraded" }),
        }))
        H.contains("net_degraded", M.render(degraded, 26, 20)[2], "net degraded")
        local no_status = M.build(fake_api({
            dirs = { ["/apps"] = {}, ["/system/system"] = {} },
            sys = { apps = function() return {} end },
        }))
        H.contains("net_off_without_status",
            M.render(no_status, 26, 20)[2], "net off")

        -- the selection marker follows the index, and the window scrolls
        state.index = 3
        local scrolled = M.render(state, 26, 20)
        H.contains("scrolled_marker", H.joined(scrolled), "> net")
        H.eq("status_follows_index", scrolled[20]:find("sel 3/3", 1, true) ~= nil, true)

        -- messages replace the hint, and are clamped to the width
        state.message = "started net"
        H.contains("message_hint", M.render(state, 26, 20)[19], "started net")
        state.message = string.rep("x", 80)
        H.eq("message_clamped", #M.render(state, 26, 20)[19], 26)
        H.eq("fit_short", M.fit("ab", 4), "ab  ")
        H.eq("fit_long", M.fit("abcdef", 3), "abc")
        H.eq("fit_control", M.fit("a\tb", 3), "a?b")
        H.eq("bytes_small", M.bytes_text(900), "900B")
        H.eq("bytes_k", M.bytes_text(26214), "25K")
        H.eq("bytes_m", M.bytes_text(2097152), "2M")
        H.eq("bytes_bad", M.bytes_text(-1), "n/a")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.keys")
    do
        local launched = nil
        local api = machine({
            sys = stub_sys({
                apps = { { name = "box", version = "0.1.0" } },
                launch = function(name)
                    launched = name
                    return true
                end,
            }),
        })
        local state = M.build(api)
        H.eq("keys_entry_count", #state.entries, 3)
        H.eq("keys_index", state.index, 1)

        H.eq("down_action", M.handle_key(state, "down", api), "move")
        H.eq("down_index", state.index, 2)
        H.eq("digit_action", M.handle_key(state, "7", api), "select")
        H.eq("digit_clamped", state.index, 3)
        H.eq("zero_action", M.handle_key(state, "0", api), "none")
        H.eq("unknown_action", M.handle_key(state, "z", api), "none")
        H.eq("nil_key_action", M.handle_key(state, nil, api), "none")

        local list = M.build(api)
        H.eq("list_count", #list.entries, 3)
        M.handle_key(list, "down", api)
        H.eq("down_two", list.index, 2)
        M.handle_key(list, "down", api)
        M.handle_key(list, "down", api)
        H.eq("down_wrap", list.index, 1)
        M.handle_key(list, "up", api)
        H.eq("up_wrap", list.index, 3)
        M.handle_key(list, "left", api)
        H.eq("left_is_up", list.index, 2)
        M.handle_key(list, "right", api)
        H.eq("right_is_down", list.index, 3)
        H.eq("digit_two", M.handle_key(list, "2", api), "select")
        H.eq("digit_two_index", list.index, 2)

        -- Enter goes through the runtime entry point
        H.eq("enter_action", M.handle_key(list, "enter", api), "launch")
        H.eq("launched_name", launched, "launcher")
        H.eq("launch_message", list.message, "started launcher")
        H.eq("launch_recorded", api.files["/etc/launcher.recent"], "launcher\n")
        H.eq("recent_made_dir", api.dirs["/etc"] ~= nil, true)

        -- no launch entry point: denied, not a crash
        local plain = machine()
        local plain_state = M.build(plain)
        H.eq("denied_action", M.handle_key(plain_state, "enter", plain), "denied")
        H.eq("denied_message", plain_state.message, "launch denied")
        H.eq("denied_nothing_launched", plain_state.launched, nil)

        -- a runtime that refuses the start
        local refusing = machine({ sys = stub_sys({
            launch = function() return nil, "quota exceeded: starts" end,
        }) })
        local refused_state = M.build(refusing)
        H.eq("refused_action", M.handle_key(refused_state, "enter", refusing), "error")
        H.contains("refused_message", refused_state.message, "cannot start box")
        H.eq("refused_error", refused_state.launch_error, "quota exceeded: starts")

        -- a runtime that raises
        local raising = machine({ sys = stub_sys({
            launch = function() error("launch-boom") end,
        }) })
        local raise_state = M.build(raising)
        H.eq("raise_action", M.handle_key(raise_state, "enter", raising), "error")
        H.eq("raise_message", raise_state.message, "launch failed")

        -- Enter with nothing installed
        local empty = fake_api({ dirs = { ["/apps"] = {}, ["/system/system"] = {} } })
        local empty_state = M.build(empty)
        H.eq("empty_enter_action", M.handle_key(empty_state, "enter", empty), "none")
        H.eq("empty_enter_message", empty_state.message, "no app selected")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.run")
    do
        local launched = {}
        local api = machine({ sys = stub_sys({
            apps = {
                { name = "box", version = "0.1.0" },
                { name = "launcher", version = "0.1.0" },
                { name = "net", version = "0.2.0" },
            },
            launch = function(name)
                launched[#launched + 1] = name
                return true
            end,
        }) })
        local frames = 0
        local state = M.run(nil, api, {
            max_frames = 4,
            keys = { "down", "enter" },
            paint = false,
            each = function() frames = frames + 1 end,
        })
        H.eq("run_frames", frames, 4)
        H.eq("run_launches", #launched, 1)
        H.eq("run_launched_name", launched[1], "launcher")
        H.eq("run_state_launched", state.launched, "launcher")
        H.table("run_state", state)

        -- the scan is throttled: four frames, one scan of two roots
        H.eq("scan_once", api.calls.list, 2)
        local api2 = machine()
        M.run(nil, api2, { max_frames = 3, scan_interval = 1, paint = false })
        H.eq("scan_every_frame", api2.calls.list, 8)

        -- keys as an iterator work the same way
        local api3 = machine({ sys = stub_sys({ launch = function() return true end }) })
        local pulled = 0
        local keys = function()
            pulled = pulled + 1
            if pulled == 1 then return "down" end
            if pulled == 2 then return "enter" end
            return nil
        end
        local iter_state = M.run(nil, api3, { max_frames = 3, keys = keys, paint = false })
        H.eq("iterator_launched", iter_state.launched, "launcher")
    end

    -- -----------------------------------------------------------------
    H.group("launcher.selftest")
    do
        local ok, problems = M.layout_selftest()
        H.check("selftest", ok, table.concat(problems or {}, ","))
        H.eq("selftest_problems", #(problems or {}), 0)
        H.eq("selftest_alias", M.layout_selftest, M.selftest)
    end
end
