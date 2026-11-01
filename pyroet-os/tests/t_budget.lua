--[[- pyroet-os/tests/t_budget.lua -- plan D settled: installer + ota are image
payload; G1 put system/net.app back into the image (it is payload again, there
is no examples/ copy), and the desktop / boot chain must tolerate a missing Net
app (P5b property, still asserted). D1 added kernel/desktop.lua (the resident
event loop), so the exact install-set count is 29. No non-ASCII bytes in this
file. ]]

local APPS = dofile("/system/kernel/apps.lua")

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)

rawset(_G, "PYROET_STARTUP_TEST", true)
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

return function(H)
    local F = H.real_fs()

    local function active_paths(text)
        local out = {}
        for line in text:gmatch("[^\n]+") do
            local body = line:gsub("#.*$", "")
            local path = body:match("^%s*(.-)%s*$")
            if path ~= "" then out[#out + 1] = path end
        end
        return out
    end

    -- ---------------------------------------------------------------------
    H.group("budget.install_set")
    do
        local text = H.read("/install.set")
        H.check("install_set_present", type(text) == "string" and #text > 0, "missing /install.set")
        local paths = active_paths(text or "")
        local set = {}
        for i = 1, #paths do set[paths[i]] = true end
        -- T1 added the Installer UI as image payload (2 files, DECISIONS.md 17),
        -- so the exact count moved 26 -> 28; D1 added the resident desktop loop
        -- (kernel/desktop.lua), so it is 29. The strictness is unchanged.
        H.eq("install_entries", #paths, 29)
        H.check("has_installer", set["pyroet-os/system/kernel/installer.lua"] == true,
            "installer is not image payload")
        H.check("has_desktop", set["pyroet-os/system/kernel/desktop.lua"] == true,
            "the resident desktop loop is not image payload")
        H.check("has_ota", set["pyroet-os/system/kernel/ota.lua"] == true,
            "ota is not image payload")
        H.check("has_boot", set["pyroet-os/system/boot.lua"] == true, "boot.lua missing")
        H.check("has_launcher", set["pyroet-os/system/system/launcher.app/main.lua"] == true,
            "launcher missing")
        H.check("has_settings", set["pyroet-os/system/system/settings.app/main.lua"] == true,
            "settings missing")
                        H.check("has_root_stub", set["pyroet-os/startup.lua"] == true,
            "the computer-root starter is not in the image")
        H.check("no_old_kernel_path", set["pyroet-os/kernel/init.lua"] == nil,
            "install.set still names the pre-P6-3 kernel path")
        H.check("no_old_rpv_path", set["pyroet-os/rpv/crypto.lua"] == nil,
            "install.set still names the pre-P6-3 rpv path")
        H.check("examples_allowed", true,
            "the examples copy must not be counted in the image")
        H.check("no_recovery", set["pyroet-os/recovery/flash.lua"] == nil
            and set["pyroet-os/recovery/proto.lua"] == nil
            and set["pyroet-os/recovery/bootstrap.lua"] == nil,
            "recovery tools must not be image payload")
        H.check("no_tests", set["pyroet-os/tests/run.lua"] == nil, "tests are not payload")
                H.check("no_examples_text", (text or ""):find("pyroet-os/examples/", 1, true) == nil, "install.set still names an examples/ path")
        H.check("no_duplicates", #paths == 29, "duplicate active entries")
    end

    -- ---------------------------------------------------------------------
    H.group("budget.gate")
    do
        -- 2026-11-01: the owner widened the BUILD gate to 7 MiB / 10 MiB. The
        -- numbers are pinned here so a quiet edit of sizecheck.py fails the
        -- suite, and the tool has to keep saying that the medium did not grow.
        local text = H.read("/tests/sizecheck.py") or ""
        H.check("sizecheck_present", #text > 0, "sizecheck.py was not staged")
        H.check("gate_upper_10mib",
            text:find("DEFAULT_BUDGET = 10485760", 1, true) ~= nil,
            "the 10 MiB upper tier is not pinned in sizecheck.py")
        H.check("gate_stretch_7mib",
            text:find("DEFAULT_STRETCH = 7340032", 1, true) ~= nil,
            "the 7 MiB target line is not pinned in sizecheck.py")
        H.check("gate_backup_cap",
            text:find("DEFAULT_BACKUP_CAP = 200000", 1, true) ~= nil,
            "the backup cap is not 200,000 B any more")
        H.check("gate_window_derived",
            text:find("WINDOW_LIMIT = DEFAULT_BUDGET + DEFAULT_BACKUP_CAP", 1, true) ~= nil,
            "the update window is no longer derived from the upper tier")
        H.check("gate_no_old_upper", text:find("629145", 1, true) == nil,
            "sizecheck.py still carries the old 3/5 MiB hard gate")
        H.check("gate_no_old_stretch", text:find("349525", 1, true) == nil,
            "sizecheck.py still carries the old 1/3 MiB target line")
        H.check("gate_no_old_window", text:find("900000", 1, true) == nil,
            "sizecheck.py still carries the old 900,000 B window")
        H.check("gate_medium_unchanged",
            text:find("1,000,000 B", 1, true) ~= nil,
            "the gate must still say the medium is 1,000,000 B")
        H.check("gate_is_build_only",
            text:find("build", 1, true) ~= nil,
            "sizecheck.py no longer describes itself as the build gate")
    end

    -- ---------------------------------------------------------------------
    H.group("budget.net_app_payload")
    do
        -- G1: the package lives in /system (image payload); there is no
        -- /examples copy any more, so two sources cannot drift apart
        H.eq("net_manifest_exists", H.exists("/tests/net.app/manifest.lua"), true)
        H.eq("net_main_exists", H.exists("/tests/net.app/main.lua"), true)
        H.eq("no_examples_copy", H.exists("/examples/net.app/main.lua"), false)
        H.eq("no_examples_manifest", H.exists("/examples/net.app/manifest.lua"), false)
        local raw = assert(loadfile("/tests/net.app/manifest.lua"))()
        local manifest, err = APPS.validate_manifest(raw, "/tests/net.app")
        H.table("net_manifest", manifest)
        H.eq("net_name", manifest and manifest.name, "net")
        H.eq("net_version", manifest and manifest.version, "0.2.0")
        H.check("net_entry", H.exists("/tests/net.app/main.lua"), "no main.lua")
        H.check("net_manifest_error", err == nil, tostring(err))
    end

    -- ---------------------------------------------------------------------
    H.group("budget.desktop_without_net")
    do
        local dir = H.case_dir("budget", "desktop")
        for _, name in ipairs({ "launcher", "settings" }) do
            H.app_package(dir .. "/system/" .. name .. ".app", {
                manifest = 'return { name = "' .. name .. '", version = "0.1.0",'
                    .. ' capabilities = { "fs.read" } }',
                main = "return function(manifest, api) api.yield() end",
            })
        end
        local api = { fs = F, sys = { apps = function() return {} end } }
        local entries, problems = LAUNCHER.scan(api, { roots = { dir .. "/system" } })
        H.eq("scan_count", #entries, 1)
        H.eq("scan_problems", #problems, 0)
        -- the launcher is the desktop: it never lists itself (T14)
        H.eq("scan_names", entries[1].name, "settings")
        H.eq("scan_unknown_state", entries[1].state, "unknown")
        local state = LAUNCHER.build(api, { roots = { dir .. "/system" } })
        H.eq("state_entries", #state.entries, 1)
        H.eq("state_selected", LAUNCHER.selected(state).name, "settings")
        local lines = LAUNCHER.render(state, 26, 20)
        H.contains("status_line", lines[#lines], "1 app sel 1/1")
    end

    -- ---------------------------------------------------------------------
    H.group("budget.startup_without_net")
    do
        local dir = H.case_dir("budget", "startup")
        -- P6 layout: one /system tree and a global credential
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
        for _, name in ipairs({ "launcher", "settings" }) do
            for _, file in ipairs({ "manifest.lua", "main.lua" }) do
                local src = "/system/system/" .. name .. ".app/" .. file
                H.write(dir .. "/system/system/" .. name .. ".app/" .. file, assert(H.read(src)))
            end
        end
        H.rmrf("/etc/perms")
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            system_root = dir .. "/system/system",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("startup_ok", result.ok == true, "boot failed without net.app")
        H.eq("startup_launcher", result.launcher, "launcher")
        H.has(lines, "APP_SCAN root=" .. dir .. "/system/system loaded=2 failed=0")
        H.has(lines, "STARTUP_LAUNCHER_STARTED name=launcher")
        H.lacks("no_launcher_fail", lines, "STARTUP_LAUNCHER_FAIL")
        H.lacks("no_net_app_load", lines, "APP_LOAD name=net ")
        H.eq("startup_app_count", #result.apps:status().apps, 2)
    end
end
