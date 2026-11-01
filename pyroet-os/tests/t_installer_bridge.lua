--[[- pyroet-os/tests/t_installer_bridge.lua -- T4: api.sys.install / uninstall / list.

The installer UI (T1) can only reach kernel/installer.lua through a host bridge,
and until T4 the kernel did not carry one: `A.SYS_FUNCTIONS` was
status/apps/perms/launch, so a real machine answered `installer unavailable` on
Enter. This suite drives the half that was missing:

  * the three functions exist on api.sys and are the runtime's own (they read the
    *calling* record's capabilities, which is why they cannot live in the host
    table);
  * authorization: install/uninstall need fs.write, list needs fs.read, and the
    refusal is `nil, "capability denied: <cap>"` + APP_CAP_DENIED, never a raise;
  * parameter validation: a name is one package name ([%w_%-]+, 40 bytes), so
    "..", "a/b", "/abs", "" and a non-string are refused before anything is
    joined onto a root;
  * the /system protection: uninstall refuses an image package with
    `nil, "system app"` + APP_SYS_PROTECT, and never calls the installer;
  * end to end with the real kernel/installer.lua on the real file system: install
    a .app from a medium -> it lands under <apps_root>, list() contains it,
    uninstall deletes it, list() no longer does;
  * the UI itself: Enter on a medium row installs through api.sys (and Enter on
    the installed row removes), with a recording bridge proving the call chain;
  * startup.lua's injection: build_installer builds the real module, tolerates a
    missing/broken one with STARTUP_INSTALLER_UNAVAILABLE and does not stop a
    boot.

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")
local INSTALLER = dofile("/system/kernel/installer.lua")

rawset(_G, "PYROET_STARTUP_TEST", true)
local STARTUP = assert(loadfile("/system/startup.lua"))()
rawset(_G, "PYROET_STARTUP_TEST", nil)

-- the installer UI is the caller this bridge was built for; load it the way the
-- package is really loaded (its test hook returns the module)
rawset(_G, "PYROET_INSTALLER_TEST", true)
local UI = assert(loadfile("/tests/installer.app/main.lua"))()
rawset(_G, "PYROET_INSTALLER_TEST", nil)

local REAL = function() return rawget(_G, "fs") end

-- the suite's assertion kit, bound by the entry point below so the helpers here
-- can use the fixtures without threading it through every call
local H = nil

local function logger()
    local lines = {}
    return function(line) lines[#lines + 1] = tostring(line) end, lines
end

-- a runtime with exactly one loaded record, plus that record's api table. The
-- real file system is used on purpose: the capability gates, the manifest parse
-- and loadfile are then the ones a machine runs.
local function probe(dir, caps, opts)
    local o = opts or {}
    local fsx = REAL()
    H.rmrf(dir)
    H.mkdirp(dir)
    local list = {}
    for i = 1, #caps do list[i] = '"' .. caps[i] .. '"' end
    H.write(dir .. "/manifest.lua", 'return { name = "probe", version = "0.0.1",'
        .. ' capabilities = { ' .. table.concat(list, ", ") .. ' } }')
    H.write(dir .. "/main.lua", "return function(manifest, api) end")
    local log, lines = o.log, o.lines
    if type(log) ~= "function" then log, lines = logger() end
    -- the installer bridge rides on the same entitlement as the rest of api.sys:
    -- a record the host gave a system surface gets it, a user package does not
    -- (opts.no_sys provokes the second case)
    local host = o.sys
    if o.no_sys then host = nil elseif host == nil then host = {} end
    local rt = APPS.new({ fs = fsx, log = log, installer = o.installer, sys = host })
    local record = rt:load(dir)
    local api = rt:build_api(record)
    return api, record, rt, lines
end

-- a stand-in kernel/installer.lua instance: same shape (colon methods), every
-- call recorded, every answer scripted
local function fake(opts)
    local o = opts or {}
    local rec = { installs = {}, removes = {}, lists = 0 }
    rec.install = function(self, name)
        rec.installs[#rec.installs + 1] = name
        if o.install_raise then error(o.install_raise) end
        return o.install_ok, o.install_detail
    end
    rec.uninstall = function(self, name)
        rec.removes[#rec.removes + 1] = name
        if o.remove_raise then error(o.remove_raise) end
        return o.remove_ok, o.remove_detail
    end
    rec.list = function(self)
        rec.lists = rec.lists + 1
        if o.list_raise then error(o.list_raise) end
        return o.entries or {}
    end
    rec.fs = o.fs
    rec.system_root = o.system_root
    return rec
end

local function has(lines, fragment)
    for i = 1, #lines do
        if lines[i]:find(fragment, 1, true) then return true end
    end
    return false
end

local function has_not(lines, fragment)
    return not has(lines, fragment)
end

local function test_device(name)
    local base = H.case_dir("installer_bridge", name)
    local dirs = { "disk", "disk/apps", "apps", "system", "tools" }
    for i = 1, #dirs do H.mkdirp(base .. "/" .. dirs[i]) end
    local medium = base .. "/disk/apps"
    H.app_package(medium .. "/box.app",
        { manifest = 'return { name = "box", version = "0.2.0" }' })
    return base, medium
end

local function new_installer(base, medium, log)
    return INSTALLER.new({
        fs = REAL(),
        log = log,
        apps = APPS,
        media_root = medium,
        apps_root = base .. "/apps",
        system_root = base .. "/system",
    })
end

local function row_index(state, source, name)
    local entries = state.entries or {}
    for i = 1, #entries do
        if entries[i].source == source and entries[i].name == name then return i end
    end
    return nil
end

local BAD_NAMES = {
    { label = "dotdot", value = ".." },
    { label = "dotdot_path", value = "../../etc/passwd" },
    { label = "absolute", value = "/system" },
    { label = "separator", value = "a/b" },
    { label = "backslash", value = "a\\b" },
    { label = "dotted", value = "net.app" },
    { label = "empty", value = "" },
    { label = "nil", value = nil },
    { label = "number", value = 7 },
    { label = "boolean", value = true },
    { label = "too_long", value = string.rep("a", APPS.APP_NAME_MAX + 1) },
}

return function(kit)
    H = kit
    -- -----------------------------------------------------------------
    H.group("installer_bridge.surface")
    do
        H.eq("sys_function_count", #APPS.SYS_FUNCTIONS, 10)
        H.eq("sys_functions", table.concat(APPS.SYS_FUNCTIONS, ","),
            "status,apps,perms,launch,install,uninstall,list,ota_list,ota_apply,rescan")
        H.eq("install_cap", APPS.SYS_INSTALLER.install.cap, "fs.write")
        H.eq("install_method", APPS.SYS_INSTALLER.install.method, "sys_install")
        H.eq("uninstall_cap", APPS.SYS_INSTALLER.uninstall.cap, "fs.write")
        H.eq("list_cap", APPS.SYS_INSTALLER.list.cap, "fs.read")
        H.eq("name_max", APPS.APP_NAME_MAX, 40)
        local dir = H.case_dir("installer_bridge", "surface") .. "/probe.app"
        local api = probe(dir, { "fs.read", "fs.write" })
        H.table("api_sys", api.sys)
        local names = { "status", "apps", "perms", "launch", "install", "uninstall", "list" }
        for i = 1, #names do
            H.check("sys_is_function_" .. names[i],
                type(api.sys[names[i]]) == "function", "missing " .. names[i])
        end
        -- a name test is pure: the same answer with no bridge and no file system
        H.eq("name_ok_box", APPS.app_name_ok("box"), true)
        H.eq("name_ok_box_dash", APPS.app_name_ok("my_box-2"), true)
        H.eq("name_ok_dot", APPS.app_name_ok("box.app"), false)
        H.eq("name_ok_dotdot", APPS.app_name_ok(".."), false)
        H.eq("name_ok_slash", APPS.app_name_ok("/box"), false)
        H.eq("name_ok_empty", APPS.app_name_ok(""), false)
        H.eq("name_ok_nonstring", APPS.app_name_ok(7), false)
        H.eq("name_ok_long", APPS.app_name_ok(string.rep("a", 41)), false)
        H.eq("name_ok_exact_max", APPS.app_name_ok(string.rep("a", 40)), true)
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.authorization")
    do
        local dir = H.case_dir("installer_bridge", "auth") .. "/probe.app"
        local rec = fake({ install_ok = true, remove_ok = true, entries = {} })
        local api, record, rt, lines = probe(dir, {}, { installer = rec })
        H.eq("no_caps", #record.manifest.capabilities, 0)
        local ok, err = api.sys.install("box")
        H.eq("install_denied_ok", ok, nil)
        H.eq("install_denied_err", err, "capability denied: fs.write")
        local ok2, err2 = api.sys.uninstall("box")
        H.eq("uninstall_denied_ok", ok2, nil)
        H.eq("uninstall_denied_err", err2, "capability denied: fs.write")
        local ok3, err3 = api.sys.list()
        H.eq("list_denied_ok", ok3, nil)
        H.eq("list_denied_err", err3, "capability denied: fs.read")
        H.eq("denied_counter", record.denied, 3)
        H.has(lines, "APP_CAP_DENIED app=probe cap=fs.write")
        H.has(lines, "APP_CAP_DENIED app=probe cap=fs.read")
        -- a refusal is not an attempt: nothing reached the installer and no
        -- APP_INSTALL/APP_UNINSTALL/APP_LIST line was written
        H.eq("denied_install_calls", #rec.installs, 0)
        H.eq("denied_remove_calls", #rec.removes, 0)
        H.eq("denied_list_calls", rec.lists, 0)
        H.check("denied_no_install_log", has_not(lines, "APP_INSTALL"), "install log written")
        H.check("denied_no_list_log", has_not(lines, "APP_LIST"), "list log written")
        -- fs.write alone does not buy fs.read, and vice versa
        local wdir = H.case_dir("installer_bridge", "auth_write") .. "/probe.app"
        local wapi, _, _, wlines = probe(wdir, { "fs.write" }, { installer = rec })
        local okl, errl = wapi.sys.list()
        H.eq("write_only_list_ok", okl, nil)
        H.eq("write_only_list_err", errl, "capability denied: fs.read")
        H.has(wlines, "APP_CAP_DENIED app=probe cap=fs.read")
        local rdir = H.case_dir("installer_bridge", "auth_read") .. "/probe.app"
        local rapi, _, _, rlines = probe(rdir, { "fs.read" }, { installer = rec })
        local okr, errr = rapi.sys.install("box")
        H.eq("read_only_install_ok", okr, nil)
        H.eq("read_only_install_err", errr, "capability denied: fs.write")
        H.has(rlines, "APP_CAP_DENIED app=probe cap=fs.write")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.unavailable")
    do
        local dir = H.case_dir("installer_bridge", "none") .. "/probe.app"
        local api, _, _, lines = probe(dir, { "fs.read", "fs.write" })
        local ok, err = api.sys.install("box")
        H.eq("no_installer_install_ok", ok, nil)
        H.eq("no_installer_install_err", err, "installer unavailable")
        H.has(lines, "APP_INSTALL name=box ok=false")
        local ok2, err2 = api.sys.uninstall("box")
        H.eq("no_installer_uninstall_ok", ok2, nil)
        H.eq("no_installer_uninstall_err", err2, "installer unavailable")
        H.has(lines, "APP_UNINSTALL name=box ok=false")
        local ok3, err3 = api.sys.list()
        H.eq("no_installer_list_ok", ok3, nil)
        H.eq("no_installer_list_err", err3, "installer unavailable")
        H.has(lines, "APP_LIST n=0")
        -- a table that is not an installer is the same answer as no table
        local dir2 = H.case_dir("installer_bridge", "none2") .. "/probe.app"
        local api2, _, _, lines2 = probe(dir2, { "fs.read", "fs.write" },
            { installer = { apps_root = "/apps" } })
        local ok4, err4 = api2.sys.install("box")
        H.eq("half_installer_ok", ok4, nil)
        H.eq("half_installer_err", err4, "installer unavailable")
        H.has(lines2, "APP_INSTALL name=box ok=false")
        -- a package the host gave no system surface (a user package) gets the
        -- stub even with the installer present and fs.write granted
        local dir3 = H.case_dir("installer_bridge", "none3") .. "/probe.app"
        local api3, _, _, lines3 = probe(dir3, { "fs.read", "fs.write" },
            { installer = fake({ install_ok = true }), no_sys = true })
        local ok5, err5 = api3.sys.install("box")
        H.eq("user_app_install_ok", ok5, nil)
        H.eq("user_app_install_err", err5, "system unavailable: install")
        H.has(lines3, "APP_SYS_UNAVAILABLE app=probe fn=install")
        H.check("user_app_no_install_log", has_not(lines3, "APP_INSTALL"),
            "install log written for a user package")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.names")
    do
        local rec = fake({ install_ok = true, install_detail = { version = "9.9.9" },
            remove_ok = true })
        local dir = H.case_dir("installer_bridge", "names") .. "/probe.app"
        local api, _, _, lines = probe(dir, { "fs.read", "fs.write" },
            { installer = rec })
        for i = 1, #BAD_NAMES do
            local case = BAD_NAMES[i]
            local ok, err = api.sys.install(case.value)
            H.eq("install_bad_ok_" .. case.label, ok, nil)
            H.eq("install_bad_err_" .. case.label, err, "bad name")
            local ok2, err2 = api.sys.uninstall(case.value)
            H.eq("uninstall_bad_ok_" .. case.label, ok2, nil)
            H.eq("uninstall_bad_err_" .. case.label, err2, "bad name")
        end
        H.eq("bad_names_never_reached_install", #rec.installs, 0)
        H.eq("bad_names_never_reached_remove", #rec.removes, 0)
        H.has(lines, "APP_INSTALL name=../../etc/passwd ok=false")
        -- an invalid name is still one log line, and the count is the attempts
        H.has(lines, "APP_INSTALL name=a/b ok=false")
        local ok, info = api.sys.install("my_box-2")
        H.eq("good_install_ok", ok, true)
        H.eq("good_install_version", info and info.version, "9.9.9")
        H.eq("good_install_calls", #rec.installs, 1)
        H.eq("good_install_name", rec.installs[1], "my_box-2")
        H.has(lines, "APP_INSTALL name=my_box-2 ok=true")
        local ok2 = api.sys.uninstall("my_box-2")
        H.eq("good_uninstall_ok", ok2, true)
        H.eq("good_uninstall_name", rec.removes[1], "my_box-2")
        H.has(lines, "APP_UNINSTALL name=my_box-2 ok=true")
        -- the installer's own refusal is passed through, and logged as a miss
        local rdir = H.case_dir("installer_bridge", "names_refuse") .. "/probe.app"
        local refuse = fake({ install_ok = nil, install_detail = "digest main.lua" })
        local rapi, _, _, rlines = probe(rdir, { "fs.read", "fs.write" },
            { installer = refuse })
        local rok, rerr = rapi.sys.install("box")
        H.eq("refuse_ok", rok, nil)
        H.eq("refuse_err", rerr, "digest main.lua")
        H.has(rlines, "APP_INSTALL name=box ok=false")
        -- a raising installer is an answer, not a crash
        local edir = H.case_dir("installer_bridge", "names_raise") .. "/probe.app"
        local boom = fake({ install_raise = "installer-boom" })
        local eapi, _, _, _ = probe(edir, { "fs.read", "fs.write" }, { installer = boom })
        local eok, eerr = eapi.sys.install("box")
        H.eq("raise_ok", eok, nil)
        H.contains("raise_err", tostring(eerr), "installer-boom")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.system")
    do
        local base = H.case_dir("installer_bridge", "system")
        H.mkdirp(base .. "/system")
        H.mkdirp(base .. "/apps")
        H.app_package(base .. "/system/sysapp.app",
            { manifest = 'return { name = "sysapp", version = "0.1.0" }' })
        -- the same name installed under /apps as well: still not uninstallable
        H.app_package(base .. "/apps/sysapp.app",
            { manifest = 'return { name = "sysapp", version = "0.1.0" }' })
        local rec = fake({ remove_ok = true, fs = REAL(),
            system_root = base .. "/system" })
        local dir = base .. "/probe.app"
        local api, _, _, lines = probe(dir, { "fs.read", "fs.write" },
            { installer = rec })
        local ok, err = api.sys.uninstall("sysapp")
        H.eq("system_ok", ok, nil)
        H.eq("system_err", err, "system app")
        H.eq("system_never_reached", #rec.removes, 0)
        H.has(lines, "APP_SYS_PROTECT name=sysapp")
        H.has(lines, "APP_UNINSTALL name=sysapp ok=false")
        H.truthy("system_left_alone", H.exists(base .. "/system/sysapp.app/manifest.lua"))
        H.truthy("user_copy_left_alone", H.exists(base .. "/apps/sysapp.app/manifest.lua"))
        -- a plain user package is delegated
        local ok2 = api.sys.uninstall("notes")
        H.eq("user_ok", ok2, true)
        H.eq("user_reached", rec.removes[1], "notes")
        H.has(lines, "APP_UNINSTALL name=notes ok=true")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.e2e")
    do
        local base, medium = test_device("e2e")
        local log, lines = logger()
        local inst = new_installer(base, medium, log)
        H.eq("apps_root", inst.apps_root, base .. "/apps")
        H.eq("system_root", inst.system_root, base .. "/system")
        local api, _, _, rtlines = probe(base .. "/tools/probe.app",
            { "fs.read", "fs.write" }, { installer = inst, log = log, lines = lines })
        -- install: medium -> staging -> validated -> <apps_root>/box.app
        local ok, report = api.sys.install("box")
        H.eq("e2e_install_ok", ok, true)
        H.table("e2e_report", report)
        H.eq("e2e_report_name", report and report.name, "box")
        H.eq("e2e_report_version", report and report.version, "0.2.0")
        H.truthy("e2e_installed_manifest", H.exists(base .. "/apps/box.app/manifest.lua"))
        H.truthy("e2e_installed_main", H.exists(base .. "/apps/box.app/main.lua"))
        H.check("e2e_no_temp", not H.exists(base .. "/apps/.tmp-box"), "temp survived")
        H.has(lines, "APP_INSTALL name=box ok=true")
        H.has(lines, "INSTALL_OK name=box")
        -- list: the installed package only (kernel/installer.lua reports the two
        -- *installed* roots, /apps and /system/system; the medium is a source,
        -- not an installation)
        local entries = api.sys.list()
        H.table("e2e_list", entries)
        H.has(lines, "APP_LIST n=" .. #entries)
        H.eq("e2e_list_count", #entries, 1)
        local seen, tags = {}, {}
        for i = 1, #entries do
            local entry = entries[i]
            tags[#tags + 1] = tostring(entry.source) .. ":" .. tostring(entry.name)
            if entry.name == "box" and entry.source == "apps" then seen.apps = entry end
            if entry.name == "box" and entry.source == "disk" then seen.disk = entry end
        end
        H.truthy("e2e_list_has_apps_box", seen.apps ~= nil)
        H.eq("e2e_list_sources", table.concat(tags, ","), "apps:box")
        H.eq("e2e_apps_version", seen.apps and seen.apps.version, "0.2.0")
        H.eq("e2e_apps_dir", seen.apps and seen.apps.dir, base .. "/apps/box.app")
        H.eq("e2e_apps_ok", seen.apps and seen.apps.ok, true)
        -- a second install replaces the first, still through one call
        local ok2 = api.sys.install("box")
        H.eq("e2e_reinstall_ok", ok2, true)
        H.has(lines, "INSTALL_REPLACE name=box")
        -- removing it deletes the copy under <apps_root> and nothing else
        local ok3 = api.sys.uninstall("box")
        H.eq("e2e_uninstall_ok", ok3, true)
        H.check("e2e_removed", not H.exists(base .. "/apps/box.app"), "still installed")
        H.truthy("e2e_medium_kept", H.exists(medium .. "/box.app/manifest.lua"))
        H.has(lines, "APP_UNINSTALL name=box ok=true")
        H.has(lines, "INSTALL_REMOVE name=box")
        local after = api.sys.list()
        H.eq("e2e_list_after_empty", #after, 0)
        H.has(lines, "APP_LIST n=0")
        -- uninstall of something absent is the installer's own answer
        local ok4, err4 = api.sys.uninstall("ghost")
        H.eq("e2e_ghost_ok", ok4, nil)
        H.eq("e2e_ghost_err", err4, "not installed")
        H.has(lines, "APP_UNINSTALL name=ghost ok=false")
        -- a package that is not on the medium and not in memory
        local ok5, err5 = api.sys.install("nosuch")
        H.eq("e2e_nosource_ok", ok5, nil)
        H.eq("e2e_nosource_err", err5, "no_source")
        H.has(lines, "INSTALL_FAIL name=nosuch")
        H.ascii_check("e2e_logs_ascii", table.concat(lines, "\n"))
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.ui")
    do
        local base, medium = test_device("ui")
        local log, lines = logger()
        local inst = new_installer(base, medium, log)
        local api = probe(base .. "/tools/probe.app", { "fs.read", "fs.write" },
            { installer = inst, log = log, lines = lines })
        -- the UI sees the runtime's gated fs and the T4 system surface, nothing
        -- else: no opts.installer, no api.installer
        local ui_api = { fs = api.fs, sys = api.sys }
        local state = UI.build(ui_api, { version = "0.1.0", medium = medium,
            apps = base .. "/apps", system = base .. "/system" })
        H.eq("ui_rows", #state.entries, 1)
        H.eq("ui_disk_count", state.disk_count, 1)
        H.eq("ui_selected_source", UI.selected(state).source, "disk")
        H.eq("ui_hint", UI.hint_line(state), "enter install")
        -- Enter on the medium row really installs, through api.sys
        local action = UI.handle_key(state, "enter", ui_api, {})
        H.eq("ui_action", action, "install")
        H.eq("ui_message", state.message, "installed box 0.2.0")
        H.truthy("ui_installed", H.exists(base .. "/apps/box.app/manifest.lua"))
        H.has(lines, "APP_INSTALL name=box ok=true")
        H.has(lines, "INSTALL_OK name=box")
        -- the list re-scanned: the installed row is now an "i" row
        H.eq("ui_rows_after", #state.entries, 2)
        H.eq("ui_apps_count", state.apps_count, 1)
        local apps_row = row_index(state, "apps", "box")
        H.truthy("ui_has_apps_row", apps_row ~= nil)
        H.eq("ui_row_tag", UI.tag_of(state.entries[apps_row]), "i")
        -- Enter on the installed row removes it again
        state.index = apps_row
        state.selected_key = UI.key_of(state.entries[apps_row])
        local action2 = UI.handle_key(state, "enter", ui_api, {})
        H.eq("ui_remove_action", action2, "remove")
        H.eq("ui_remove_message", state.message, "removed box")
        H.check("ui_removed", not H.exists(base .. "/apps/box.app"), "still installed")
        H.has(lines, "APP_UNINSTALL name=box ok=true")
        H.eq("ui_rows_after_remove", #state.entries, 1)

        -- the same Enter with a caller that lacks fs.write: refused on screen,
        -- and the installer is never called
        local base2, medium2 = test_device("ui_denied")
        local inst2 = new_installer(base2, medium2, log)
        local api2 = probe(base2 .. "/tools/probe.app", { "fs.read" },
            { installer = inst2, log = log, lines = lines })
        local ui2 = { fs = api2.fs, sys = api2.sys }
        local state2 = UI.build(ui2, { version = "0.1.0", medium = medium2,
            apps = base2 .. "/apps", system = base2 .. "/system" })
        local action3 = UI.handle_key(state2, "enter", ui2, {})
        H.eq("ui_denied_action", action3, "denied")
        H.eq("ui_denied_message", state2.message, "capability denied: fs.write")
        H.check("ui_denied_not_installed",
            not H.exists(base2 .. "/apps/box.app"), "installed without fs.write")
        H.has(lines, "APP_CAP_DENIED app=probe cap=fs.write")

        -- no bridge at all: the T1 line, and the app keeps running
        local bare = { fs = REAL() }
        local state3 = UI.build(bare, { version = "0.1.0", medium = medium,
            apps = base .. "/apps", system = base .. "/system" })
        local action4 = UI.handle_key(state3, "enter", bare, {})
        H.eq("ui_no_bridge_action", action4, "unavailable")
        H.eq("ui_no_bridge_message", state3.message, "installer unavailable")
        -- a T4 kernel without an installer instance answers through the bridge,
        -- and the screen shows the same line (the mapping is the one place)
        local stub = { install = function() return nil, "installer unavailable" end }
        local stub_api = { fs = REAL(), sys = stub }
        local state4 = UI.build(stub_api, { version = "0.1.0", medium = medium,
            apps = base .. "/apps", system = base .. "/system" })
        local action5 = UI.handle_key(state4, "enter", stub_api, {})
        H.eq("ui_kernel_off_action", action5, "unavailable")
        H.eq("ui_kernel_off_message", state4.message, "installer unavailable")
        -- and a bridge exposing only list is a bridge, not "the kernel hid it"
        local list_only = { list = function() return {} end }
        local list_api = { fs = REAL(), sys = list_only }
        local state5 = UI.build(list_api, { version = "0.1.0", medium = medium,
            apps = base .. "/apps", system = base .. "/system" })
        H.eq("ui_list_only_action", UI.handle_key(state5, "enter", list_api, {}),
            "unavailable")
        H.eq("ui_list_only_message", state5.message, "installer unavailable")
        H.eq("ui_bridge_functions", table.concat(UI.BRIDGE_FUNCTIONS, ","),
            "install,uninstall,list")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.startup")
    do
        local log, lines = logger()
        local ctx = { fs = REAL(), log = log }
        -- the real module, built the way a boot builds it
        local inst = STARTUP.build_installer(ctx, {}, APPS)
        H.table("startup_installer", inst)
        H.eq("startup_apps_root", inst and inst.apps_root, "/apps")
        H.eq("startup_system_root", inst and inst.system_root, "/system/system")
        H.check("startup_sha", type(inst and inst.sha) == "function", "no sha256")
        H.has(lines, "STARTUP_INSTALLER_READY mode=new apps=/apps")
        -- the media root and the packages table are passed through
        local log2, lines2 = logger()
        local built = STARTUP.build_installer({ fs = REAL(), log = log2 },
            { media_root = "/disk/apps", packages = { box = {} },
              apps_root = "/t/apps", system_root = "/t/system" }, APPS)
        H.eq("startup_media_root", built and built.media_root, "/disk/apps")
        H.eq("startup_apps_root_opt", built and built.apps_root, "/t/apps")
        H.eq("startup_system_root_opt", built and built.system_root, "/t/system")
        H.eq("startup_packages", built and type(built.packages.box), "table")
        -- a module whose new() raises must not stop the boot
        local log3, lines3 = logger()
        local broken = { new = function() error("installer-boom") end }
        local none = STARTUP.build_installer({ fs = REAL(), log = log3 },
            { installer = broken }, APPS)
        H.eq("startup_broken", none, nil)
        H.has(lines3, "STARTUP_INSTALLER_UNAVAILABLE")
        -- no module at all (a path that does not exist)
        local log4, lines4 = logger()
        local missing = STARTUP.build_installer({ fs = REAL(), log = log4 },
            { installer_path = "/system/kernel/no-such-installer.lua" }, APPS)
        H.eq("startup_missing", missing, nil)
        H.has(lines4, "STARTUP_INSTALLER_UNAVAILABLE")
        -- explicit opt-out
        local log5, lines5 = logger()
        local off = STARTUP.build_installer({ fs = REAL(), log = log5 },
            { installer = false }, APPS)
        H.eq("startup_off", off, nil)
        H.has(lines5, "STARTUP_INSTALLER_UNAVAILABLE")
        -- an injected instance is used as-is
        local log6, lines6 = logger()
        local given = { apps_root = "/x/apps", system_root = "/x/system" }
        local same = STARTUP.build_installer({ fs = REAL(), log = log6 },
            { installer = given }, APPS)
        H.check("startup_injected_same", same == given, "not the injected table")
        H.has(lines6, "STARTUP_INSTALLER_READY mode=injected")
        -- and the runtime really keeps it: build_api's api.sys talks to it
        local log7, lines7 = logger()
        local rt = APPS.new({ fs = REAL(), log = log7, installer = given })
        H.check("startup_rt_installer", rt.installer == given, "runtime lost the installer")
    end

    -- -----------------------------------------------------------------
    H.group("installer_bridge.shape")
    do
        local dir = H.case_dir("installer_bridge", "shape") .. "/probe.app"
        local rec = fake({ install_ok = true, remove_ok = true, entries = { {} } })
        local api = probe(dir, { "fs.read", "fs.write" }, { installer = rec })
        -- a flat call: the closure takes the package name and nothing else, so
        -- the app-side `bridge.install(entry.name)` is the whole protocol
        local ok0, err0 = api.sys.install()
        H.eq("install_no_arg_ok", ok0, nil)
        H.eq("install_no_arg_err", err0, "bad name")
        local entries = api.sys.list()
        H.eq("list_count", #entries, 1)
        H.eq("list_calls", rec.lists, 1)
        -- a list returning a non-table is a clean refusal, not a crash
        local bdir = H.case_dir("installer_bridge", "shape_bad_list") .. "/probe.app"
        local nolist = fake({})
        nolist.list = function() return nil end
        local bapi, _, _, blines = probe(bdir, { "fs.read" }, { installer = nolist })
        local okb, errb = bapi.sys.list()
        H.eq("bad_list_ok", okb, nil)
        H.eq("bad_list_err", errb, "list failed")
        H.has(blines, "APP_LIST n=0")
        -- a raising list is contained too
        local cdir = H.case_dir("installer_bridge", "shape_raise_list") .. "/probe.app"
        local boom = fake({ list_raise = "list-boom" })
        local capi, _, _, clines = probe(cdir, { "fs.read" }, { installer = boom })
        local okc, errc = capi.sys.list()
        H.eq("raise_list_ok", okc, nil)
        H.contains("raise_list_err", tostring(errc), "list-boom")
        H.has(clines, "APP_LIST n=0")
        -- the kernel surface does not leak host-only names onto api.sys
        local known = {}
        for i = 1, #APPS.SYS_FUNCTIONS do known[APPS.SYS_FUNCTIONS[i]] = true end
        local extra = {}
        for key in pairs(api.sys) do
            if not known[key] then extra[#extra + 1] = tostring(key) end
        end
        H.eq("sys_no_extra_keys", table.concat(extra, ","), "")
        -- api.sys is not a capability tree: it is present with no caps at all,
        -- and the host functions answer their own refusal
        local ndir = H.case_dir("installer_bridge", "shape_nocap") .. "/probe.app"
        local bare = probe(ndir, {})
        H.eq("sys_present_without_caps", type(bare.sys.install), "function")
        H.eq("sys_stub_status", select(2, bare.sys.status()), "system unavailable: status")
    end
end
