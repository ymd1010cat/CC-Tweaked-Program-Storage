--[[- pyroet-os/tests/t_layout.lua -- P6-3: the single /system tree.

Three things are asserted here:

  1. the computer root keeps one tiny starter (pyroet-os/startup.lua) that only
     loads /system/startup.lua and falls back to the ROM shell with an ASCII
     message, so a broken image cannot turn into a reboot loop;
  2. boot.migrate_layout() renames the pre-P6-3 layout (root /kernel, /rpv, /net
     and /system/<name>.app) into the single tree, is reentrant, skips an entry
     whose target already exists, and rolls back everything it moved when one
     entry cannot be moved;
  3. every hardcoded path in the image points into /system.

No non-ASCII bytes in this file.
]]

local BOOT = dofile("/system/boot.lua")

rawset(_G, "PYROET_STARTUP_TEST", true)
local STARTUP = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)

rawset(_G, "PYROET_SETTINGS_TEST", true)
local SETTINGS = assert(loadfile("/system/system/settings.app/main.lua"))()
rawset(_G, "PYROET_SETTINGS_TEST", nil)

local P = dofile("/recovery/proto.lua")

local STARTER = "/tests/root-startup.lua"

return function(H)
    local F = H.real_fs()

    -- ---------------------------------------------------------------------
    H.group("layout.starter")
    do
        local source = H.read(STARTER)
        H.check("starter_present", type(source) == "string" and #source > 0, "missing starter")
        H.ascii_check("starter_ascii", source or "")
        H.ge("starter_small", 1536 - #(source or ""), 0)
        H.contains("starter_system_path", source or "", '"/system/startup.lua"')
        H.contains("starter_recovery_hint", source or "", "recovery/flash.lua")
        H.absent("starter_no_boot_chain", source or "", "P.BOOT_PATH")
        H.absent("starter_no_kernel", source or "", "SYSTEM_APPS_ROOT")
        H.eq("starter_get_size", F.getSize(STARTER), #(source or ""))

        -- drive the starter with a stubbed loadfile/print
        local function drive(loader)
            local saved_loadfile, saved_print = _G.loadfile, _G.print
            local out, calls = {}, 0
            _G.print = function(line) out[#out + 1] = tostring(line) end
            _G.loadfile = function(path)
                calls = calls + 1
                return loader(path)
            end
            local real_loadfile = saved_loadfile
            local ok, err = pcall(assert(real_loadfile(STARTER)))
            _G.loadfile, _G.print = saved_loadfile, saved_print
            return ok, err, out, calls
        end

        local ran = 0
        local ok, _, out, calls = drive(function(path)
            H.eq("starter_load_path", path, "/system/startup.lua")
            return function() ran = ran + 1 end
        end)
        H.eq("starter_success_ran", ran, 1)
        H.eq("starter_success_calls", calls, 1)
        H.eq("starter_success_ok", ok, true)
        H.eq("starter_success_silent", #out, 0)

        ok, _, out, calls = drive(function() return nil, "no such file" end)
        H.eq("starter_missing_ok", ok, true)
        H.contains("starter_missing_line", out[1] or "", "Pyroet OS: cannot load /system/startup.lua")
        H.contains("starter_missing_err", out[2] or "", "no such file")
        H.contains("starter_missing_hint", out[3] or "", "Run recovery/flash.lua")
        H.contains("starter_missing_shell", out[3] or "", "shell only")

        ok, _, out = drive(function() error("bad chunk") end)
        H.eq("starter_load_raises_ok", ok, true)
        H.contains("starter_load_raises_line", out[1] or "", "cannot load /system/startup.lua")
        H.contains("starter_load_raises_err", out[2] or "", "bad chunk")

        ok, _, out = drive(function()
            return function() error("kaboom", 0) end
        end)
        H.eq("starter_runtime_raises_ok", ok, true)
        H.contains("starter_runtime_line", out[1] or "", "Pyroet OS: startup failed")
        H.contains("starter_runtime_err", out[2] or "", "kaboom")
        H.contains("starter_runtime_hint", out[3] or "", "Run recovery/flash.lua")
    end

    -- ---------------------------------------------------------------------
    H.group("layout.paths")
    do
        H.eq("startup_boot_path", STARTUP.BOOT_PATH, "/system/boot.lua")
        H.eq("startup_kernel_path", STARTUP.KERNEL_PATH, "/system/kernel/init.lua")
        H.eq("startup_apps_path", STARTUP.APPS_PATH, "/system/kernel/apps.lua")
        H.eq("startup_perms_path", STARTUP.PERMISSIONS_PATH, "/system/kernel/permissions.lua")
        H.eq("startup_system_root", STARTUP.SYSTEM_ROOT, "/system")
        H.eq("startup_system_apps_root", STARTUP.SYSTEM_APPS_ROOT, "/system/system")
        H.eq("startup_apps_root", STARTUP.APPS_ROOT, "/apps")
        H.eq("startup_log_path", STARTUP.LOG_PATH, "/kernel.log")

        H.eq("boot_crypto", BOOT.CRYPTO, "/system/rpv/crypto.lua")
        H.eq("boot_paths_system", BOOT.paths({}).system, "/system")
        H.eq("boot_paths_system_apps", BOOT.paths({}).system_apps, "/system/system")
        H.eq("boot_system_path", BOOT.system_path("kernel/ota.lua", {}),
            "/system/kernel/ota.lua")
        H.eq("boot_system_path_root", BOOT.system_path("kernel/ota.lua", { root = "/t/x" }),
            "/t/x/system/kernel/ota.lua")

        H.eq("launcher_roots", table.concat(LAUNCHER.ROOTS, ","), "/apps,/system/system")
        H.eq("settings_gate", SETTINGS.BUDGET, 629145)
        H.eq("settings_stretch", SETTINGS.STRETCH, 349525)
        H.eq("settings_window", SETTINGS.WINDOW, 900000)
        H.eq("settings_backup_cap", SETTINGS.BACKUP_CAP, 200000)
        H.eq("recovery_crypto", P.CRYPTO, "/system/rpv/crypto.lua")

        -- the staged image really has this shape, and the old root is gone
        H.eq("staged_startup", H.exists("/system/startup.lua"), true)
        H.eq("staged_boot", H.exists("/system/boot.lua"), true)
        H.eq("staged_kernel", H.exists("/system/kernel/init.lua"), true)
        H.eq("staged_rpv", H.exists("/system/rpv/crypto.lua"), true)
        H.eq("staged_net", H.exists("/system/net/service.lua"), true)
        H.eq("staged_launcher", H.exists("/system/system/launcher.app/main.lua"), true)
        H.eq("staged_settings", H.exists("/system/system/settings.app/main.lua"), true)
        H.eq("staged_net_app", H.exists("/system/system/net.app/main.lua"), true)
        H.eq("no_root_kernel", H.exists("/kernel"), false)
        H.eq("no_root_rpv", H.exists("/rpv"), false)
        H.eq("no_root_net", H.exists("/net"), false)
        H.eq("etc_not_image", H.exists("/system/etc"), false)
        H.eq("recovery_not_image", H.exists("/system/recovery"), false)

        -- every module loads from the path the image actually ships
        H.truthy("load_kernel", loadfile("/system/kernel/init.lua"))
        H.truthy("load_apps", loadfile("/system/kernel/apps.lua"))
        H.truthy("load_installer", loadfile("/system/kernel/installer.lua"))
        H.truthy("load_ota", loadfile("/system/kernel/ota.lua"))
        H.truthy("load_service", loadfile("/system/net/service.lua"))
        H.truthy("load_hosts", loadfile("/system/net/hosts.lua"))
    end

    -- ---------------------------------------------------------------------
    H.group("layout.migrate")
    do
        local function old_layout(name)
            local dir = H.case_dir("layout", name)
            H.write(dir .. "/kernel/init.lua", "return 'kernel'\n")
            H.write(dir .. "/rpv/crypto.lua", "return 'crypto'\n")
            H.write(dir .. "/net/service.lua", "return 'service'\n")
            H.write(dir .. "/system/startup.lua", "return 'startup'\n")
            H.write(dir .. "/system/launcher.app/main.lua", "return 'launcher'\n")
            return dir
        end

        local dir = old_layout("full")
        local log, lines = H.logger()
        local plan = BOOT.legacy_layout({ fs = F, root = dir, log = log })
        H.eq("legacy_dir_count", #plan, 3)
        H.eq("legacy_dir_first", plan[1].name, "kernel")
        H.eq("legacy_dir_src", plan[1].src, dir .. "/kernel")
        H.eq("legacy_dir_dst", plan[1].dst, dir .. "/system/kernel")
        H.eq("legacy_dir_not_skipped", plan[1].skip, false)
        local apps = BOOT.legacy_apps({ fs = F, root = dir, log = log })
        H.eq("legacy_app_count", #apps, 1)
        H.eq("legacy_app_name", apps[1].name, "launcher.app")
        H.eq("legacy_app_dst", apps[1].dst, dir .. "/system/system/launcher.app")

        local moved, kind = BOOT.migrate_layout({ fs = F, root = dir, log = log })
        H.eq("migrate_moved", moved, true)
        H.eq("migrate_kind", kind, nil)
        H.has(lines, "BOOT_MIGRATE_LAYOUT name=kernel to=" .. dir
            .. "/system/kernel via=move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT name=rpv to=" .. dir .. "/system/rpv via=move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT name=net to=" .. dir .. "/system/net via=move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT name=launcher.app to=" .. dir
            .. "/system/system/launcher.app via=move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT_DONE dirs=3 apps=1")
        H.eq("migrate_kernel_body", H.read(dir .. "/system/kernel/init.lua"), "return 'kernel'\n")
        H.eq("migrate_rpv_body", H.read(dir .. "/system/rpv/crypto.lua"), "return 'crypto'\n")
        H.eq("migrate_net_body", H.read(dir .. "/system/net/service.lua"), "return 'service'\n")
        H.eq("migrate_app_body", H.read(dir .. "/system/system/launcher.app/main.lua"),
            "return 'launcher'\n")
        H.eq("migrate_root_kernel_gone", H.exists(dir .. "/kernel"), false)
        H.eq("migrate_root_rpv_gone", H.exists(dir .. "/rpv"), false)
        H.eq("migrate_root_net_gone", H.exists(dir .. "/net"), false)
        H.eq("migrate_old_app_gone", H.exists(dir .. "/system/launcher.app"), false)

        -- reentrant: a second call finds nothing to do
        local log2, lines2 = H.logger()
        local again = BOOT.migrate_layout({ fs = F, root = dir, log = log2 })
        H.eq("migrate_again", again, false)
        H.lacks("migrate_again_quiet", lines2, "BOOT_MIGRATE_LAYOUT name=")

        -- a machine with no /system at all: the migration creates it
        local bare = H.case_dir("layout", "bare")
        H.write(bare .. "/kernel/init.lua", "return 'k'\n")
        H.write(bare .. "/rpv/crypto.lua", "return 'c'\n")
        local bare_moved = BOOT.migrate_layout({ fs = F, root = bare, log = H.logger() })
        H.eq("migrate_bare", bare_moved, true)
        H.eq("migrate_bare_system_made", F.isDir(bare .. "/system"), true)
        H.eq("migrate_bare_kernel", H.read(bare .. "/system/kernel/init.lua"), "return 'k'\n")
        H.eq("migrate_bare_no_net", H.exists(bare .. "/system/net"), false)

        -- target already exists: the entry is skipped (never deleted), the rest
        -- still moves
        local skip = H.case_dir("layout", "skip")
        H.write(skip .. "/kernel/init.lua", "return 'old'\n")
        H.write(skip .. "/system/kernel/init.lua", "return 'new'\n")
        H.write(skip .. "/rpv/crypto.lua", "return 'c'\n")
        local log3, lines3 = H.logger()
        local skip_plan = BOOT.legacy_layout({ fs = F, root = skip, log = log3 })
        H.eq("skip_plan_count", #skip_plan, 2)
        H.eq("skip_plan_kernel_skipped", skip_plan[1].skip, true)
        H.eq("skip_plan_rpv_moved", skip_plan[2].skip, false)
        local skip_moved = BOOT.migrate_layout({ fs = F, root = skip, log = log3 })
        H.eq("skip_moved", skip_moved, true)
        H.has(lines3, "BOOT_MIGRATE_LAYOUT_SKIP name=kernel why=target_exists")
        H.eq("skip_old_kernel_kept", H.read(skip .. "/kernel/init.lua"), "return 'old'\n")
        H.eq("skip_new_kernel_kept", H.read(skip .. "/system/kernel/init.lua"), "return 'new'\n")
        H.eq("skip_rpv_moved", H.read(skip .. "/system/rpv/crypto.lua"), "return 'c'\n")
    end

    -- ---------------------------------------------------------------------
    H.group("layout.migrate_fail")
    do
        -- the third rename is refused: the two already moved are renamed back
        local dir = H.case_dir("layout", "rollback")
        H.write(dir .. "/kernel/init.lua", "return 'kernel'\n")
        H.write(dir .. "/rpv/crypto.lua", "return 'crypto'\n")
        H.write(dir .. "/net/service.lua", "return 'service'\n")
        local real = H.real_fs()
        local flaky = H.fs({ overrides = { move = function(a, b)
            if b:find("/system/net", 1, true) then return false end
            return real.move(a, b)
        end } })
        local log, lines = H.logger()
        local moved, kind = BOOT.migrate_layout({ fs = flaky, root = dir, log = log })
        H.eq("rollback_moved", moved, nil)
        H.eq("rollback_kind", kind, "move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT_FAIL name=net step=move")
        H.has(lines, "BOOT_MIGRATE_LAYOUT_ROLLED_BACK stage=move restored=2 of=2")
        H.eq("rollback_kernel_back", H.read(dir .. "/kernel/init.lua"), "return 'kernel'\n")
        H.eq("rollback_rpv_back", H.read(dir .. "/rpv/crypto.lua"), "return 'crypto'\n")
        H.eq("rollback_net_untouched", H.read(dir .. "/net/service.lua"), "return 'service'\n")
        H.eq("rollback_no_system_kernel", H.exists(dir .. "/system/kernel"), false)
        H.eq("rollback_no_system_rpv", H.exists(dir .. "/system/rpv"), false)

        -- boot must refuse to boot half migrated
        local plan = BOOT.begin({ fs = flaky, root = dir, log = log })
        H.eq("rollback_begin_action", plan.action, "fatal")
        H.eq("rollback_begin_error", plan.error, "layout_migrate_fail")
        H.has(lines, "BOOT_MIGRATE_LAYOUT_ABORT stage=move")
        H.has(lines, "BOOT_FATAL reason=layout_migrate_fail")
        H.eq("rollback_still_old", H.read(dir .. "/kernel/init.lua"), "return 'kernel'\n")

        -- an undo that also fails keeps the evidence and stays fatal
        local dir2 = H.case_dir("layout", "rollback-fail")
        H.write(dir2 .. "/kernel/init.lua", "return 'kernel'\n")
        H.write(dir2 .. "/rpv/crypto.lua", "return 'crypto'\n")
        H.write(dir2 .. "/net/service.lua", "return 'service'\n")
        local broken = H.fs({ overrides = { move = function(a, b)
            if b:find("/system/net", 1, true) then return false end
            if a:find("/system/rpv", 1, true) then return false end
            return real.move(a, b)
        end } })
        local log2, lines2 = H.logger()
        local moved2, kind2 = BOOT.migrate_layout({ fs = broken, root = dir2, log = log2 })
        H.eq("rollback_fail_moved", moved2, nil)
        H.eq("rollback_fail_kind", kind2, "rollback_fail")
        H.has(lines2, "BOOT_MIGRATE_LAYOUT_ROLLBACK_FAIL name=rpv")
        H.has(lines2, "BOOT_MIGRATE_LAYOUT_ROLLED_BACK stage=move restored=1 of=2")
        local plan2 = BOOT.begin({ fs = broken, root = dir2, log = log2 })
        H.eq("rollback_fail_action", plan2.action, "fatal")
        H.contains("rollback_fail_abort", H.joined(lines2), "BOOT_MIGRATE_LAYOUT_ABORT stage=")
    end

    -- ---------------------------------------------------------------------
    H.group("layout.boot_after_migrate")
    do
        -- an image from the old layout plus a commit marker boots normally once
        -- the migration has renamed it into place
        local dir = H.case_dir("layout", "boot")
        H.write(dir .. "/kernel/init.lua", "return 'kernel'\n")
        H.write(dir .. "/rpv/crypto.lua", "return 'crypto'\n")
        H.write(dir .. "/system/startup.lua", "return 'startup'\n")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000\n")
        local log, lines = H.logger()
        local plan = BOOT.begin({ fs = F, root = dir, log = log })
        H.eq("boot_action", plan.action, "normal")
        H.has(lines, "BOOT_MIGRATE_LAYOUT_DONE dirs=2 apps=0")
        H.has(lines, "BOOT_SYSTEM path=" .. dir .. "/system")
        H.eq("boot_kernel_moved", H.read(dir .. "/system/kernel/init.lua"), "return 'kernel'\n")
        H.eq("boot_no_root_kernel", H.exists(dir .. "/kernel"), false)

        -- an old image with no /system and no credential: the migration makes
        -- the tree, then the bootloader hands out a trial boot
        local bare = H.case_dir("layout", "boot-bare")
        H.write(bare .. "/kernel/init.lua", "return 'kernel'\n")
        H.write(bare .. "/system/startup.lua", "return 'startup'\n")
        local log2, lines2 = H.logger()
        local plan2 = BOOT.begin({ fs = F, root = bare, log = log2 })
        H.eq("boot_bare_action", plan2.action, "trial")
        H.eq("boot_bare_tries", plan2.tries, 1)
        H.has(lines2, "BOOT_MIGRATE_LAYOUT name=kernel to=" .. bare
            .. "/system/kernel via=move")
        H.has(lines2, "BOOT_TRIAL tries=1 max=2")

        -- the crypto path the bootloader uses is the migrated one
        local sha = P.sha({})
        H.check("boot_crypto_usable", type(sha) == "function", "no sha256")
        H.eq("boot_crypto_digest", P.dg(sha, "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end
end
