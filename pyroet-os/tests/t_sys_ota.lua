--[[- pyroet-os/tests/t_ota.lua -- T5: the desktop OTA surface.

The kernel owns the medium: `api.sys.ota_list()` reads `/disk/ota/meta.txt`
(an image update, parsed by kernel/ota.lua) and `/disk/apps/<name>.app`
(package updates), and `api.sys.ota_apply(name)` applies a package through the
*same* installer object as `api.sys.install`. The launcher only renders the
answer: `no updates` plus a reason when there is no source, never a crash.

No non-ASCII bytes in this file.
]]

local APPS = assert(loadfile("/system/kernel/apps.lua"))()
local INSTALLER = assert(loadfile("/system/kernel/installer.lua"))()

local HEX = string.rep("ab", 32)
local META_OK = "PYROET-OTA/2 META version=1.2.0 files=2 manifest_sha=" .. HEX

return function(H)
    local F = H.real_fs()

    local function installer_for(media)
        return INSTALLER.new({
            fs = F,
            log = H.logger(),
            apps = APPS,
            media_root = "/pkgs",
            apps_root = "/apps",
            system_root = "/system/system",
        })
    end

    local function runtime(opts)
        local o = opts or {}
        local log, lines = H.logger()
        local rt = APPS.new({
            fs = F,
            log = log,
            apps_root = o.apps_root or "/system/system",
            installer = o.installer,
            -- the host table must exist for the runtime-served bridges (install /
            -- uninstall / list / ota_*); the functions behind them are the
            -- runtime's own, not host callbacks
            sys = o.sys or {},
            ota_meta = o.ota_meta,
            ota_media = o.ota_media,
        })
        return rt, log, lines
    end

    local function launch(rt, name)
        H.check("start_" .. name, rt:start(name) == true, "start refused")
        return rt:app(name).api
    end

    -- -----------------------------------------------------------------
    H.group("ota.list")
    do
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
        local inst = installer_for()
        local rt, log, lines = runtime({ installer = inst })
        H.eq("scan", rt:scan(), 3)
        local api = launch(rt, "launcher")

        -- 1) no source medium at all
        local ok, info = api.sys.ota_list()
        H.eq("none_ok", ok, nil)
        H.eq("none_reason", info, "no source")
        H.has(lines, "APP_OTA_LIST ok=false reason=no_source checked=/pkgs,/disk")

        -- 2) a package on the source medium is an update
        H.app_package("/pkgs/demo.app", {
            manifest = 'return { name = "demo", version = "1.0.1", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local ok2, info2 = api.sys.ota_list()
        H.eq("pkg_ok", ok2, true)
        H.table("pkg_info", info2)
        H.eq("pkg_entries", info2 and #info2.entries, 1)
        H.eq("pkg_name", info2 and info2.entries[1].name, "demo")
        H.eq("pkg_version", info2 and info2.entries[1].version, "1.0.1")
        H.eq("pkg_kind", info2 and info2.entries[1].kind, "package")
        H.has(lines, "APP_OTA_LIST ok=true entries=1")

        -- 3) an image meta is listed too, parsed by kernel/ota.lua
        H.mkdirp("/disk/ota")
        H.write("/disk/ota/meta.txt", META_OK .. "\n")
        local ok3, info3 = api.sys.ota_list()
        H.eq("image_ok", ok3, true)
        H.eq("image_entries", info3 and #info3.entries, 2)
        H.eq("image_kind", info3 and info3.entries[1].kind, "image")
        H.eq("image_version", info3 and info3.entries[1].version, "1.2.0")

        -- 4) an unparsable meta is an error the caller can show, not a crash
        H.write("/disk/ota/meta.txt", "garbage\n")
        local ok4, info4 = api.sys.ota_list()
        H.eq("bad_ok", ok4, nil)
        H.eq("bad_reason", info4, "bad meta")
        H.has(lines, "APP_OTA_LIST ok=false reason=bad_meta")
        H.write("/disk/ota/meta.txt", META_OK .. "\n")

        -- 5) capability gates: the bridge asks the caller's own cap set
        H.rmrf("/apps")
        H.app_package("/apps/reader.app", {
            manifest = 'return { name = "reader", version = "1.0.0",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local rt2 = APPS.new({ fs = F, log = H.logger(), apps_root = "/apps",
            installer = inst, sys = {} })
        H.eq("scan2", rt2:scan(), 1)
        local rapi = launch(rt2, "reader")
        local rok, rerr = rapi.sys.ota_list()
        H.eq("reader_list_ok", rok, true)
        H.table("reader_list_info", rerr)
        H.ge("reader_entries", rerr and #rerr.entries or 0, 1)
        local aok, aerr = rapi.sys.ota_apply("demo")
        H.eq("reader_apply_ok", aok, nil)
        H.eq("reader_apply_reason", aerr, "capability denied: fs.write")
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("ota.apply")
    do
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
        H.app_package("/pkgs/demo.app", {
            manifest = 'return { name = "demo", version = "1.0.1", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local inst = installer_for()
        local rt, log, lines = runtime({ installer = inst })
        H.eq("scan", rt:scan(), 3)
        local api = launch(rt, "launcher")

        -- a package entry installs through the installer object
        local ok, info = api.sys.ota_apply("demo")
        H.eq("apply_ok", ok, true)
        H.table("apply_info", info)
        H.check("apply_installed", F.exists("/apps/demo.app/manifest.lua"),
            "not installed")
        H.has(lines, "APP_OTA_APPLY name=demo ok=true")

        -- an image update cannot be applied from the desktop (recovery owns it)
        H.mkdirp("/disk/ota")
        H.write("/disk/ota/meta.txt", META_OK .. "\n")
        local iok, ierr = api.sys.ota_apply("image")
        H.eq("image_apply_ok", iok, nil)
        H.eq("image_apply_reason", ierr, "image ota needs recovery")
        H.has(lines, "APP_OTA_APPLY name=image ok=false reason=recovery_only")

        -- a package that is not on the medium: the installer's own error text
        local mok, merr = api.sys.ota_apply("ghost")
        H.eq("missing_ok", mok, nil)
        H.contains("missing_reason", tostring(merr), "no_source")
        H.has(lines, "APP_OTA_APPLY name=ghost ok=false")

        -- uninstalling a package the OTA just installed is the normal path back
        H.eq("remove_ok", select(1, api.sys.uninstall("demo")), true)
        H.eq("remove_gone", F.exists("/apps/demo.app"), false)
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("ota.internal")
    -- T7: a pocket computer has no disk drive, so /pkgs (on this computer's own
    -- disk) is the primary source; /disk is only added when it is mounted.
    do
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
        H.app_package("/pkgs/demo.app", {
            manifest = 'return { name = "demo", version = "2.0.0", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local inst = installer_for()
        local rt, log, lines = runtime({ installer = inst })
        H.eq("scan", rt:scan(), 3)
        local api = launch(rt, "launcher")

        -- no /disk at all: the internal package is still listed, and the source
        -- summary says `internal` (never `disk none`)
        local ok, info = api.sys.ota_list()
        H.eq("internal_ok", ok, true)
        H.eq("internal_source", info and info.source, "internal")
        H.eq("internal_entries", info and #info.entries, 1)
        H.eq("internal_entry_source", info and info.entries[1].source, "internal")
        H.has(lines, "APP_OTA_LIST ok=true entries=1 source=internal")

        -- and it installs into /apps through the same installer object
        H.eq("internal_apply", select(1, api.sys.ota_apply("demo")), true)
        H.check("internal_installed", F.exists("/apps/demo.app/manifest.lua"),
            "not installed")
        H.eq("internal_remove", select(1, api.sys.uninstall("demo")), true)

        -- with a mounted disk both sources are merged into `internal+disk`
        H.app_package("/disk/apps/diskapp.app", {
            manifest = 'return { name = "diskapp", version = "1.0.0",'
                .. ' entry = "main.lua", capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local ok2, info2 = api.sys.ota_list()
        H.eq("merged_ok", ok2, true)
        H.eq("merged_source", info2 and info2.source, "internal+disk")
        H.eq("merged_entries", info2 and #info2.entries, 2)
        local sources = {}
        for i = 1, #(info2 and info2.entries or {}) do
            sources[info2.entries[i].source] = true
        end
        H.eq("merged_has_internal", sources.internal, true)
        H.eq("merged_has_disk", sources.disk, true)

        -- the installer app reads the same roots: /pkgs first, /disk optional
        _G.PYROET_INSTALLER_TEST = true
        local APP = assert(loadfile("/tests/installer.app/main.lua"))()
        _G.PYROET_INSTALLER_TEST = nil
        local fs_api = {
            list = function(path)
                if not F.exists(path) then return nil, "not found" end
                if not F.isDir(path) then return nil, "not a directory" end
                return F.list(path)
            end,
            exists = function(path) return F.exists(path) end,
            isDir = function(path) return F.isDir(path) end,
        }
        local entries, problems, ok3, text = APP.scan({
            fs = fs_api,
            sys = { apps = function() return {} end },
        })
        H.eq("app_source_text", text, "internal+disk")
        local found = {}
        for i = 1, #entries do
            found[entries[i].source .. ":" .. entries[i].name] = true
        end
        H.eq("app_pkgs", found["internal:demo"], true)
        H.eq("app_disk", found["disk:diskapp"], true)
        H.eq("app_tag", APP.tag_of({ source = "internal" }), "p")
        H.eq("app_action", APP.action_of({ source = "internal" }), "install")

        -- a machine with neither source: the hint names what was checked
        H.rmrf("/pkgs")
        H.rmrf("/disk")
        local no_disk_entries, no_disk_problems, ok4, text2 = APP.scan({
            fs = fs_api,
            sys = { apps = function() return {} end },
        })
        H.eq("app_none_text", text2, "none")
        local off_source = 0
        for i = 1, #no_disk_entries do
            local source = no_disk_entries[i].source
            if source == "internal" or source == "disk" then off_source = off_source + 1 end
        end
        H.eq("app_none_entries", off_source, 0)
        H.absent("app_none_no_disk_word", H.joined(no_disk_problems), "no disk")
        H.eq("app_none_problems", #no_disk_problems, 0)
        H.rmrf("/apps")
        H.rmrf("/disk")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("ota.e2e_install")
    -- T13 regression: pressing Enter in the *installer app* on a /pkgs row must
    -- really install it. The app is driven through its own dispatch, and the
    -- bridge it calls is the real kernel/installer.lua (same code the runtime
    -- uses), so `internal` rows are covered end to end.
    do
        H.rmrf("/apps")
        H.rmrf("/pkgs")
        H.app_package("/pkgs/xpkg.app", {
            manifest = 'return { name = "xpkg", version = "0.3.0", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        local log, lines = H.logger()
        -- the default constructor must find /pkgs on its own: the source roots
        -- are constants (I.INTERNAL / I.DISK), not something a caller passes
        H.eq("e2e_internal_const", INSTALLER.INTERNAL, "/pkgs")
        H.eq("e2e_disk_const", INSTALLER.DISK, "/disk/apps")
        local inst = INSTALLER.new({
            fs = F,
            log = log,
            apps = APPS,
            apps_root = "/apps",
            system_root = "/system/system",
        })
        H.eq("e2e_default_source", inst:source_for("xpkg"), "/pkgs/xpkg.app")
        -- the app talks to the runtime's own bridge (A:sys_install), which is
        -- what emits APP_INSTALL and what the real api.sys.install calls
        local rt = runtime({ installer = inst, sys = {}, apps_root = "/system/system" })
        rt.sink = log
        local record = { name = "installer", caps = { ["fs.write"] = true,
            ["fs.read"] = true } }
        local api = {
            fs = F,
            sys = {
                apps = function() return {} end,
                install = function(name) return rt:sys_install(record, name) end,
                uninstall = function(name) return rt:sys_uninstall(record, name) end,
            },
            input = { keys = {}, pullEvent = function() return nil end },
            terminal = nil,
            yield = function() end,
            log = log,
        }
        _G.PYROET_INSTALLER_TEST = true
        local APP = assert(loadfile("/tests/installer.app/main.lua"))()
        _G.PYROET_INSTALLER_TEST = nil
        local state = APP.build(api, {})
        H.ge("e2e_entries", #state.entries, 1)
        H.eq("e2e_first_source", state.entries[1].source, "internal")
        H.eq("e2e_first_name", state.entries[1].name, "xpkg")
        H.eq("e2e_action", APP.action_of(state.entries[1]), "install")
        local saved = rawget(_G, "PYROET_APP_NOPAINT")
        rawset(_G, "PYROET_APP_NOPAINT", true)
        local action, detail = APP.dispatch_event(state, "key", "enter", api, {})
        rawset(_G, "PYROET_APP_NOPAINT", saved)
        H.eq("e2e_dispatch_action", action, "install")
        H.eq("e2e_dispatch_detail", detail, "xpkg")
        H.check("e2e_installed", F.exists("/apps/xpkg.app/manifest.lua"),
            "package not installed (state message: " .. tostring(state.message) .. ")")
        H.has(lines, "APP_INSTALL name=xpkg ok=true")
        H.has(lines, "INSTALL_OK name=xpkg")
        -- and it is now an installed row: Enter again says nothing to do
        local state2 = APP.build(api, {})
        local installed_row = nil
        for i = 1, #state2.entries do
            if state2.entries[i].name == "xpkg" then installed_row = state2.entries[i] end
        end
        H.check("e2e_installed_row", installed_row ~= nil, "no xpkg row after install")
        H.eq("e2e_installed_source", installed_row and installed_row.source, "apps")
        H.eq("e2e_installed_action", installed_row and APP.action_of(installed_row), "remove")
        H.rmrf("/apps")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("ota.rescan")
    -- T15: a package installed at run time is launchable without a reboot --
    -- launch rescans once when the name is unknown, and rescan repairs the table.
    do
        H.rmrf("/apps")
        H.rmrf("/pkgs")
        local inst = installer_for()
        local rt, log, lines = runtime({ installer = inst, apps_root = "/system/system" })
        local record = { name = "launcher", caps = { ["fs.read"] = true,
            ["fs.write"] = true } }
        H.eq("rescan_scan", rt:scan(), 3)
        -- a package appears while the machine is running
        H.app_package("/apps/late.app", {
            manifest = 'return { name = "late", version = "1.4.2", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }',
            main = 'return function(manifest, api) return nil end\n',
        })
        H.eq("rescan_unknown", rt.index.late, nil)
        -- the launcher shows the real version even without a runtime record (T15)
        _G.PYROET_LAUNCHER_TEST = true
        local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
        _G.PYROET_LAUNCHER_TEST = nil
        H.eq("rescan_manifest_version",
            LAUNCHER.read_version({ fs = { read = function(path)
                return H.read(path)
            end } }, "/apps/late.app"), "1.4.2")
        local lstate = LAUNCHER.build({
            fs = {
                read = function(path)
                    return H.read(path)
                end,
                list = function(path)
                    if not F.exists(path) then return nil, "no root" end
                    return F.list(path)
                end,
                exists = function(path) return F.exists(path) end,
            },
        }, { roots = { "/apps" } })
        H.eq("rescan_launcher_version", lstate.entries[1] and lstate.entries[1].version,
            "1.4.2")
        -- launch rescans automatically and starts it
        local ok, info = rt:sys_launch(record, "late")
        H.eq("rescan_launch_ok", ok, true)
        H.table("rescan_info", info)
        H.has(lines, "APP_LAUNCH_RESCAN name=late reason=unknown")
        H.has(lines, "APP_RESCAN")
        H.has(lines, "APP_START name=late")
        H.eq("rescan_running", rt:app("late").state, "running")
        H.eq("rescan_version", rt:app("late").manifest.version, "1.4.2")

        -- the explicit API works too, and reports the count
        local rok, rinfo = rt:sys_rescan(record)
        H.eq("rescan_ok", rok, true)
        H.table("rescan_report", rinfo)
        H.ge("rescan_count", rinfo and rinfo.count or 0, 4)

        -- removing the directory drops the record on the next rescan, but a
        -- running instance is kept (its coroutine is alive)
        H.rmrf("/apps/late.app")
        local rok2, rinfo2 = rt:sys_rescan(record)
        H.eq("rescan_ok2", rok2, true)
        H.eq("rescan_removed_running", rinfo2 and rinfo2.removed, 0)
        H.check("rescan_running_kept", rt:app("late") ~= nil, "running record dropped")
        rt:kill("late")
        local rok3, rinfo3 = rt:sys_rescan(record)
        H.eq("rescan_ok3", rok3, true)
        H.eq("rescan_removed_after_kill", rinfo3 and rinfo3.removed, 1)
        H.eq("rescan_gone", rt:app("late"), nil)
        H.has(lines, "APP_RESCAN count=")

        -- an unknown name still fails, with the documented error
        local mok, merr = rt:sys_launch(record, "ghost")
        H.eq("rescan_miss_ok", mok, nil)
        H.eq("rescan_miss_err", merr, "no such app")
        H.has(lines, "APP_LAUNCH_MISS name=ghost")
        H.rmrf("/apps")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("ota.launcher")
    do
        -- the launcher only renders the kernel's answer; `api.sys` is faked here
        _G.PYROET_LAUNCHER_TEST = true
        local L = assert(loadfile("/system/system/launcher.app/main.lua"))()
        _G.PYROET_LAUNCHER_TEST = nil

        local function api_with(list, apply)
            local log, lines = H.logger()
            local sysx = {}
            if list then sysx.ota_list = list end
            if apply then sysx.ota_apply = apply end
            return { sys = sysx, log = log }, lines
        end

        local state = L.build(nil, {})

        -- the power menu always offers Update, and it opens this screen
        H.eq("menu_has_update", L.POWER_ITEMS[1].id, "update")
        H.eq("menu_count", #L.POWER_ITEMS, 4)
        local api = api_with(function()
            return true, { source = "/disk/ota/meta.txt", entries = {
                { name = "demo", version = "1.0.1", kind = "package" },
            } }
        end, function() return true, { version = "1.0.1" } end)
        state.power = true
        state.power_index = 1
        local action = L.power_run(state, api)
        H.eq("update_action", action, "repaint")
        H.eq("power_closed", state.power, nil)
        H.check("ota_open", type(state.ota) == "table", "no ota screen")
        H.eq("ota_index", state.ota.index, 1)
        H.eq("ota_entries", #state.ota.entries, 1)

        -- the screen: title, the entry with its marker, hint row
        local lines = L.render(state, 26, 19)
        H.contains("ota_title", lines[1] or "", "Updates 0.2.0")
        H.contains("ota_row2", lines[2] or "", "> demo 1.0.1 package")
        H.contains("ota_hint", lines[19] or "", "enter install q=back")

        -- keys: up/down move, enter applies, q closes (no Esc)
        H.eq("ota_down", L.dispatch_event(state, "key", "down", nil, api), "move")
        H.eq("ota_enter", L.dispatch_event(state, "key", "enter", nil, api), "power")
        H.eq("ota_closed_by_q", L.dispatch_event(state, "char", "q", nil, api),
            "repaint")
        H.eq("ota_gone", state.ota, nil)

        -- no source: `no updates` plus the kernel's reason, and enter does nothing
        local api2 = api_with(function() return nil, "no source" end, nil)
        state.power_index = 1
        state.power = true
        L.power_run(state, api2)
        H.check("ota_open2", type(state.ota) == "table", "no ota screen")
        H.eq("ota_reason", state.ota.reason, "no source")
        local empty = table.concat(L.render(state, 26, 19), "\n")
        H.contains("ota_no_updates", empty, "no updates")
        H.contains("ota_reason_row", empty, "no source")
        H.eq("ota_enter_empty", L.dispatch_event(state, "key", "enter", nil, api2),
            "none")
        H.eq("ota_cancel_q", L.dispatch_event(state, "key", "q", nil, api2),
            "repaint")
        H.eq("ota_closed", state.ota, nil)

        -- a failing apply is shown, not raised
        local api3 = api_with(function()
            return true, { source = "/disk/apps", entries = {
                { name = "demo", version = "1.0.1", kind = "package" },
            } }
        end, function() return nil, "hash check failed" end)
        state.power = true
        state.power_index = 1
        L.power_run(state, api3)
        H.eq("ota_apply_fail", L.dispatch_event(state, "key", "enter", nil, api3),
            "error")
        H.eq("ota_apply_reason", state.ota.reason, "hash check failed")

        -- a missing bridge (old kernel) says so instead of crashing
        local api4 = { log = H.logger() }
        state.power = true
        state.power_index = 1
        L.power_run(state, api4)
        H.eq("ota_no_bridge", state.ota and state.ota.reason, "no ota bridge")
        H.contains("ota_no_bridge_row", table.concat(L.render(state, 26, 19), "\n"),
            "no ota bridge")
        state.ota = nil
    end
end
