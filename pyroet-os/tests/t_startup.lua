--[[- pyroet-os/tests/t_startup.lua -- the whole chain: boot decision -> kernel -> commit.

Uses the staged module paths a real image has (/system/boot.lua,
/system/startup.lua, /system/kernel/init.lua, /system/kernel/apps.lua) and a sandbox `root`
for the boot state, so the same code path as a real boot is exercised without
touching the emulator's own disk layout.

P6 changed two things that this file is here to pin down: there is no slot any
more (the plan carries a journal state), and /boot.ok records the manifest_sha
that the update journal described -- not a per-slot image descriptor that no
longer exists.

No non-ASCII bytes in this file.
]]

_G.PYROET_STARTUP_TEST = true
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

local BOOT = dofile("/system/boot.lua")

return function(H)
    local F = H.real_fs()

    local CR = {}
    assert(loadfile("/system/rpv/crypto.lua"))(CR)
    local function sha(text) return CR.hex(CR.sha256(text)) end

    local M1 = "1111111111111111111111111111111111111111111111111111111111111111"
    local M2 = "2222222222222222222222222222222222222222222222222222222222222222"

    -- every sandbox needs the tree the bootloader insists on
    local function system_tree(dir, files)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/kernel/ota.lua", "-- ota\n")
        local names = {}
        for relpath in pairs(files or {}) do names[#names + 1] = relpath end
        table.sort(names)
        for i = 1, #names do
            H.write(dir .. "/system/" .. names[i], files[names[i]])
        end
        return dir
    end

    local function commit_marker(dir, version, manifest)
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=" .. version
            .. " manifest_sha=" .. manifest .. " ts=1700000000000")
    end

    local function journal(dir, seq, state, files, opts)
        local o = opts or {}
        local out = {
            "PYROET-UPD-JOURNAL-1",
            "seq=" .. tostring(seq),
            "state=" .. state,
            "version=" .. (o.version or "2.0.0"),
            "manifest_sha=" .. (o.manifest_sha or M1),
        }
        for i = 1, #files do
            local f = files[i]
            out[#out + 1] = f.relpath .. " " .. (f.old_sha or "-") .. " "
                .. f.new_sha .. " " .. tostring(f.bytes or 0)
        end
        H.write(dir .. "/update.journal." .. tostring(seq), table.concat(out, "\n") .. "\n")
    end

    local function hello_package(root)
        return H.app_package(root .. "/hello.app", {
            manifest = 'return { name = "hello", version = "0.1.0",'
                .. ' capabilities = { "fs.read", "fs.write" } }',
            main = [[
return function(manifest, api)
    api.log("hello-body")
    api.yield()
    api.log("hello-body-2")
end
]],
        })
    end

    -- an applied, uncommitted update: the state a real OTA leaves on disk
    local function applied_update(dir)
        local old_sha = sha("-- ota v1\n")
        local new_text = "-- ota v2\n"
        H.write(dir .. "/system/kernel/ota.lua", new_text)
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- ota v1\n")
        journal(dir, 2, "applied", {
            { relpath = "kernel/ota.lua", old_sha = old_sha,
              new_sha = sha(new_text), bytes = #new_text },
        }, { version = "2.0.0", manifest_sha = M1 })
        return old_sha, sha(new_text)
    end

    -- -----------------------------------------------------------------
    H.group("startup.chain")
    do
        local dir = system_tree(H.case_dir("startup", "chain"))
        applied_update(dir)
        local apps_root = dir .. "/apps"
        hello_package(apps_root)

        local log, lines = H.logger()
        local frames, reboots = 0, 0
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = apps_root,
            reboot = function() reboots = reboots + 1 end,
            frame = function() frames = frames + 1; return true end,
        })

        H.eq("version", startup.VERSION, "0.2.0")
        H.eq("boot_path", startup.BOOT_PATH, "/system/boot.lua")
        H.table("result", result)
        H.check("ok", result and result.ok == true, "ok=" .. tostring(result and result.ok))
        H.check("committed", result and result.committed == true, "not committed")
        H.check("no_reboot", result and result.rebooted == false,
            "rebooted=" .. tostring(result and result.rebooted))
        H.eq("plan_action", result and result.plan.action, "trial")
        H.eq("plan_journal", result and result.plan.journal.state, "applied")
        H.eq("plan_tries", result and result.plan.tries, 1)
        H.eq("frames", frames, 1)
        H.eq("reboots", reboots, 0)
        H.eq("result_version", result and result.version, "0.2.0")

        H.has(lines, "STARTUP_PLAN action=trial journal=applied tries=1")
        H.has(lines, "STARTUP_UI_READY")
        H.has(lines, "STARTUP_KERNEL health=ok running=1")
        H.has(lines, "STARTUP_APPS_TICK advanced=1")
        H.has(lines, "HELLO_APP_STARTED")
        H.has(lines, "APP_START name=hello")
        H.has(lines, "APP_LOG app=hello msg=hello-body")
        H.has(lines, "STARTUP_COMMITTED version=2.0.0 manifest_sha=" .. M1)
        H.lacks("no_missing_manifest", lines, "STARTUP_NO_MANIFEST")

        local ready_at = H.index_of(lines, "STARTUP_UI_READY")
        local commit_at = H.index_of(lines, "BOOT_COMMIT version=2.0.0")
        H.check("ui_before_commit", ready_at ~= nil and commit_at ~= nil
            and ready_at < commit_at, "ready=" .. tostring(ready_at)
            .. " commit=" .. tostring(commit_at))

        -- the credential the bootloader wrote is the one the journal described
        local parsed = BOOT.read_marker({ fs = F, root = dir })
        H.table("marker", parsed)
        H.eq("marker_version", parsed and parsed.version, "2.0.0")
        H.eq("marker_manifest", parsed and parsed.manifest_sha, M1)
        H.check("marker_tag", parsed and parsed.tag == "PYROET-BOOT-OK-2",
            "tag=" .. tostring(parsed and parsed.tag))
        H.eq("journal_cleaned", BOOT.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("backup_cleaned", H.exists(dir .. "/update.backup"), false)
        H.eq("tries_reset", H.read(dir .. "/boot.tries"), "0")
        H.eq("kernel_health", result.status.health, "ok")
        H.table("kernel_names", result.kernel:names())
        H.eq("hello_service", result.kernel:get("hello").state, "running")
        H.check("app_runtime", result.apps ~= nil, "no app runtime in the result")
        H.eq("app_state", result.apps and result.apps:app("hello").state, "running")
        H.eq("info_manifest", result.info and result.info.manifest_sha, M1)
        H.eq("info_version", result.info and result.info.version, "2.0.0")
        H.ascii_check("logs_ascii", H.joined(lines))

        -- booting again from the committed marker takes the normal path
        local log2, lines2 = H.logger()
        local again = startup.run({
            fs = F,
            root = dir,
            log = log2,
            apps_root = apps_root,
            reboot = function() end,
            frame = function() return true end,
        })
        H.eq("second_action", again.plan.action, "normal")
        H.eq("second_journal", again.plan.journal, nil)
        H.check("second_ok", again.ok == true, "second boot failed")
        H.has(lines2, "STARTUP_PLAN action=normal journal=none tries=0")
        H.has(lines2, "BOOT_NORMAL version=2.0.0")
        -- the marker is rewritten with the same credential (only ts moves)
        local stable = H.read(dir .. "/boot.ok") or ""
        H.contains("marker_stable_version", stable,
            "PYROET-BOOT-OK-2 version=2.0.0 manifest_sha=" .. M1)
        H.match("marker_stable_ts", stable, " ts=%d+$")
    end

    -- -----------------------------------------------------------------
    H.group("startup.placeholder")
    do
        -- no app package at all: the hello service is the placeholder, and the
        -- manifest of the committed system is preserved, not invented
        local dir = system_tree(H.case_dir("startup", "placeholder"))
        commit_marker(dir, "1.0.0", M2)
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("ok", result.ok == true, "boot failed")
        H.eq("plan", result.plan.action, "normal")
        H.has(lines, "HELLO_PLACEHOLDER name=hello")
        H.lacks("no_app_start", lines, "APP_START name=hello")
        H.has(lines, "APP_SCAN_MISSING root=" .. dir .. "/apps")
        H.has(lines, "STARTUP_COMMITTED version=1.0.0 manifest_sha=" .. M2)
        H.contains("marker_kept", H.read(dir .. "/boot.ok"), "manifest_sha=" .. M2)
        H.eq("info_version", result.info.version, "1.0.0")
    end

    -- -----------------------------------------------------------------
    H.group("startup.no_manifest")
    do
        -- a system that has never been updated has no manifest to record
        local dir = system_tree(H.case_dir("startup", "no_manifest"))
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("ok", result.ok == true, "boot failed")
        H.eq("plan", result.plan.action, "trial")
        H.has(lines, "STARTUP_NO_MANIFEST source=none")
        H.has(lines, "STARTUP_COMMITTED version=0.2.0 manifest_sha=none")
        H.contains("marker_none", H.read(dir .. "/boot.ok"), "manifest_sha=none")
        H.eq("info_manifest", result.info.manifest_sha, nil)
    end

    -- -----------------------------------------------------------------
    H.group("startup.degraded")
    do
        local dir = system_tree(H.case_dir("startup", "degraded"))
        commit_marker(dir, "1.0.0", M1)
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
            services = {
                {
                    name = "net",
                    deps = {},
                    start = function() return nil, "down" end,
                },
            },
        })
        H.eq("health", result.status.health, "degraded")
        H.check("still_ok", result.ok == true, "a degraded service must not block boot")
        H.has(lines, "STARTUP_KERNEL health=degraded")
        H.has(lines, "KERNEL_SERVICE_FAIL name=net")
        H.check("marker_written", H.exists(dir .. "/boot.ok"), "no /boot.ok")
        H.eq("net_failed", result.kernel:get("net").state, "failed")
        H.eq("hello_running", result.kernel:get("hello").state, "running")
        H.eq("committed", result.committed, true)
    end

    -- -----------------------------------------------------------------
    H.group("startup.kernel_fatal")
    do
        local dir = system_tree(H.case_dir("startup", "kernel_fatal"))
        journal(dir, 4, "applied", {
            { relpath = "kernel/ota.lua", old_sha = "-", new_sha = sha("-- ota\n"), bytes = 8 },
        }, { version = "5.0.0", manifest_sha = M1 })
        local log, lines = H.logger()
        local reboots = 0
        local fake = {
            register = function() return true end,
            start_all = function()
                return {
                    health = "failed",
                    fatal = true,
                    counts = { running = 0, failed = 1, skipped = 0 },
                    services = {},
                }
            end,
        }
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            kernel = { new = function() return fake end },
            reboot = function() reboots = reboots + 1 end,
            frame = function() return true end,
        })
        H.eq("reboots", reboots, 1)
        H.check("result_rebooted", result.rebooted == true, "not reported as reboot")
        H.eq("reason", result.reason, "kernel_health")
        H.has(lines, "STARTUP_KERNEL health=failed")
        H.has(lines, "STARTUP_REBOOT reason=kernel_health")
        H.check("no_commit", not H.exists(dir .. "/boot.ok"),
            "a failed kernel must not commit")
        H.eq("tries_persisted", H.read(dir .. "/boot.tries"), "1")
        H.eq("journal_kept", H.exists(dir .. "/update.journal.4"), true)
    end

    -- -----------------------------------------------------------------
    H.group("startup.frame_fail")
    do
        local dir = system_tree(H.case_dir("startup", "frame_fail"))
        applied_update(dir)
        local log, lines = H.logger()
        local reboots = 0
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() reboots = reboots + 1 end,
            frame = function() return false end,
        })
        H.eq("reboots", reboots, 1)
        H.eq("reason", result.reason, "first_frame")
        H.has(lines, "STARTUP_FRAME_NOT_READY")
        H.has(lines, "STARTUP_REBOOT reason=first_frame")
        H.check("no_commit", not H.exists(dir .. "/boot.ok"),
            "the first frame never came up, yet /boot.ok was written")
        H.eq("tries_kept", H.read(dir .. "/boot.tries"), "1")
        H.eq("journal_kept", H.exists(dir .. "/update.journal.2"), true)

        -- a frame that raises is the same failure
        local dir2 = system_tree(H.case_dir("startup", "frame_throw"))
        commit_marker(dir2, "1.0.0", M1)
        local log2, lines2 = H.logger()
        local reboots2 = 0
        local result2 = startup.run({
            fs = F,
            root = dir2,
            log = log2,
            apps_root = dir2 .. "/apps",
            reboot = function() reboots2 = reboots2 + 1 end,
            frame = function() error("no screen") end,
        })
        H.eq("throw_reboots", reboots2, 1)
        H.eq("throw_reason", result2.reason, "first_frame")
        H.has(lines2, "STARTUP_FRAME_FAIL")
    end

    -- -----------------------------------------------------------------
    H.group("startup.fatal_plan")
    do
        -- nothing to boot: report and hand the console over, never reboot
        local dir = H.case_dir("startup", "fatal_plan")
        local log, lines = H.logger()
        local reboots = 0
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() reboots = reboots + 1 end,
            frame = function() return true end,
        })
        H.check("not_ok", result.ok == false, "ok=" .. tostring(result.ok))
        H.check("fatal", result.fatal == true, "fatal flag missing")
        H.eq("error", result.error, "no_system")
        H.eq("no_reboot", reboots, 0)
        H.has(lines, "STARTUP_PLAN action=fatal journal=none tries=0")
        H.has(lines, "STARTUP_FATAL reason=no_system")
        H.has(lines, "BOOT_FATAL reason=no_system")
        H.lacks("no_reboot_log", lines, "STARTUP_REBOOT")

        -- a rollback that cannot be proven is fatal in the same way
        local dir2 = system_tree(H.case_dir("startup", "fatal_rollback"))
        H.write(dir2 .. "/system/kernel/ota.lua", "-- half applied\n")
        H.write(dir2 .. "/update.journal.5", "PYROET-UPD-JOURNAL-1\nseq=5\nstate=applying\n"
            .. "version=2.0.0\nmanifest_sha=" .. M1 .. "\n"
            .. "kernel/ota.lua " .. sha("-- ota\n") .. " " .. sha("-- half applied\n") .. " 14\n")
        H.mkdirp(dir2 .. "/update.backup/kernel")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", "-- corrupt\n")
        local log2, lines2 = H.logger()
        local reboots2 = 0
        local result2 = startup.run({
            fs = F,
            root = dir2,
            log = log2,
            apps_root = dir2 .. "/apps",
            reboot = function() reboots2 = reboots2 + 1 end,
            frame = function() return true end,
        })
        H.eq("rollback_error", result2.error, "rollback_fail")
        H.eq("rollback_no_reboot", reboots2, 0)
        H.has(lines2, "STARTUP_FATAL reason=rollback_fail")
        H.has(lines2, "FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
        H.lacks("no_rollback_reboot", lines2, "STARTUP_REBOOT")
    end

    -- -----------------------------------------------------------------
    H.group("startup.commit_fail")
    do
        local dir = system_tree(H.case_dir("startup", "commit_fail"))
        applied_update(dir)
        local proxy = H.fs({
            overrides = {
                open = function(path, mode)
                    if type(path) == "string" and path:find("boot.ok", 1, true) then
                        return nil
                    end
                    return F.open(path, mode)
                end,
            },
        })
        local log, lines = H.logger()
        local reboots = 0
        local result = startup.run({
            fs = proxy,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() reboots = reboots + 1 end,
            frame = function() return true end,
        })
        H.eq("reboots", reboots, 1)
        H.eq("reason", result.reason, "commit")
        H.has(lines, "STARTUP_COMMIT_FAIL")
        H.has(lines, "STARTUP_REBOOT reason=commit")
        H.check("no_marker", not H.exists(dir .. "/boot.ok"),
            "the marker exists even though writing it failed")
        H.eq("tries_kept", H.read(dir .. "/boot.tries"), "1")
        -- the intent survives, so the next boot retries the same trial
        H.eq("journal_kept", BOOT.read_journal({ fs = F, root = dir }).state, "applied")
        H.eq("backup_kept", H.exists(dir .. "/update.backup/kernel/ota.lua"), true)
    end

    -- -----------------------------------------------------------------
    H.group("startup.register_fail")
    do
        local dir = system_tree(H.case_dir("startup", "register_fail"))
        applied_update(dir)
        local log, lines = H.logger()
        local reboots = 0
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() reboots = reboots + 1 end,
            frame = function() return true end,
            services = {
                { name = "hello", deps = {}, start = function() return true end },
            },
        })
        H.eq("reboots", reboots, 1)
        H.eq("reason", result.reason, "register")
        H.has(lines, "STARTUP_REGISTER_FAIL")
        H.has(lines, "STARTUP_REBOOT reason=register")
        H.check("no_commit", not H.exists(dir .. "/boot.ok"),
            "kernel init failed yet /boot.ok was written")
        H.eq("tries_still_1", H.read(dir .. "/boot.tries"), "1")
    end

    -- -----------------------------------------------------------------
    H.group("startup.modules")
    do
        local dir = system_tree(H.case_dir("startup", "modules"))
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            boot_path = "/nope/boot.lua",
            reboot = function() end,
        })
        H.check("boot_module_fails", result.ok == false, "ok=" .. tostring(result.ok))
        H.eq("boot_module_error", result.error, "boot module unavailable")
        H.has(lines, "STARTUP_BOOT_MODULE_FAIL")

        local log2, lines2 = H.logger()
        local result2 = startup.run({
            fs = F,
            root = dir,
            log = log2,
            kernel_path = "/nope/kernel.lua",
            reboot = function() end,
        })
        H.check("kernel_module_fails", result2.ok == false, "ok=" .. tostring(result2.ok))
        H.eq("kernel_module_error", result2.error, "kernel module unavailable")
        H.has(lines2, "STARTUP_KERNEL_MODULE_FAIL")

        -- the default boot path is the one P6 moved the bootloader to
        H.eq("default_boot_path", startup.BOOT_PATH, "/system/boot.lua")
        H.eq("default_kernel_path", startup.KERNEL_PATH, "/system/kernel/init.lua")
        H.eq("system_root", startup.SYSTEM_ROOT, "/system")
    end

    -- -----------------------------------------------------------------
    H.group("startup.hello_package")
    do
        local dir = system_tree(H.case_dir("startup", "hello_package"))
        commit_marker(dir, "1.0.0", M1)
        local apps_root = dir .. "/apps"
        -- a crashing hello app must degrade the hello service, not the kernel
        H.app_package(apps_root .. "/hello.app", {
            manifest = 'return { name = "hello", version = "0.1.0" }',
            main = 'return function(manifest, api) error("hello-boom") end',
        })
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = apps_root,
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("ok", result.ok == true, "a crashing app blocked the boot")
        H.has(lines, "APP_CRASH app=hello")
        H.eq("app_state", result.apps:app("hello").state, "crashed")
        H.eq("kernel_health", result.status.health, "ok")
        local hello = result.status.services[1]
        H.eq("hello_healthy_at_start", hello and hello.healthy, "ok")
        -- aggregate health is live: the crash happened after start_all
        local after = result.kernel:status()
        H.eq("hello_healthy_after_crash", after.services[1].healthy, "degraded")
        H.eq("aggregate_after_crash", after.health, "degraded")
        H.check("crash_not_fatal", after.fatal == false, "a crashed app became fatal")
        H.eq("committed", result.committed, true)
    end

    -- -----------------------------------------------------------------
    H.group("startup.loop")
    do
        local dir = system_tree(H.case_dir("startup", "loop"))
        commit_marker(dir, "1.0.0", M1)
        local log, lines = H.logger()
        local called = nil
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
            loop = function(kernel, rt, plan)
                called = { kernel = kernel, rt = rt, plan = plan }
                log("LOOP_HANDOVER")
            end,
        })
        H.check("loop_called", called ~= nil, "the loop hook never ran")
        H.eq("loop_kernel", called and called.kernel == result.kernel, true)
        H.eq("loop_action", called and called.plan.action, "normal")
        H.check("loop_after_commit",
            H.index_of(lines, "STARTUP_COMMITTED") ~= nil
            and H.index_of(lines, "LOOP_HANDOVER") ~= nil
            and H.index_of(lines, "STARTUP_COMMITTED") < H.index_of(lines, "LOOP_HANDOVER"),
            "the loop hook ran before the commit")

        -- a raising loop hook is reported, but the machine already committed
        local dir2 = system_tree(H.case_dir("startup", "loop_throw"))
        commit_marker(dir2, "1.0.0", M1)
        local log2, lines2 = H.logger()
        local result2 = startup.run({
            fs = F,
            root = dir2,
            log = log2,
            apps_root = dir2 .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
            loop = function() error("loop-boom") end,
        })
        H.check("loop_throw_ok", result2.ok == true, "a loop crash rolled back the boot")
        H.has(lines2, "STARTUP_LOOP_FAIL")
        H.contains("loop_throw_text", H.joined(lines2), "loop-boom")
    end

    -- -----------------------------------------------------------------
    H.group("startup.rolledback")
    do
        -- the bootloader rolled an update back: this boot must boot the old
        -- system and keep the old credential, not adopt the rolled-back version
        local dir = system_tree(H.case_dir("startup", "rolledback"))
        commit_marker(dir, "1.0.0", M2)
        journal(dir, 3, "rolledback", {
            { relpath = "kernel/ota.lua", old_sha = sha("-- ota\n"),
              new_sha = sha("-- ota v2\n"), bytes = 11 },
        }, { version = "2.0.0", manifest_sha = M1 })
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- ota\n")
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("ok", result.ok == true, "boot failed")
        H.eq("plan", result.plan.action, "normal")
        H.has(lines, "BOOT_JOURNAL_ROLLEDBACK seq=3")
        H.has(lines, "STARTUP_COMMITTED version=1.0.0 manifest_sha=" .. M2)
        H.contains("marker_kept", H.read(dir .. "/boot.ok") or "",
            "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha=" .. M2)
        H.eq("journal_cleaned", BOOT.journal_gens({ fs = F, root = dir })[1], nil)
    end

    -- -----------------------------------------------------------------
    H.group("startup.migration")
    do
        -- a machine that still has the slot layout migrates on this boot
        local dir = system_tree(H.case_dir("startup", "migration"))
        H.mkdirp(dir .. "/slots/a")
        H.write(dir .. "/slots/a/boot.ok", "PYROET-BOOT-OK-1 slot=a version=1.0.0 sha256="
            .. M1 .. " ts=1")
        H.write(dir .. "/boot.slot", "a")
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("ok", result.ok == true, "migration broke the boot")
        H.has(lines, "BOOT_MIGRATED from=slots")
        H.eq("slots_gone", H.exists(dir .. "/slots"), false)
        H.eq("boot_slot_gone", H.exists(dir .. "/boot.slot"), false)
        H.contains("marker_v2", H.read(dir .. "/boot.ok"), "PYROET-BOOT-OK-2")
        H.eq("committed", result.committed, true)
    end
end
