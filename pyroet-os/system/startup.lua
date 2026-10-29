--[[- pyroet-os/startup.lua -- Pyroet OS boot chain: bootloader -> kernel -> apps -> commit.

This is the only file CraftOS runs (via the tiny /startup.lua stub), so it stays
a thin sequence and pushes every real decision into the modules it loads:

    1. boot.begin()      decide from /system + update journal + /boot.ok
    2. kernel.new()      build the service manager
    3. apps.new()        build the app runtime, scan <apps_root> for *.app
    4. register          the system services (currently one: the hello app)
    5. start_all()       topological start, failure isolation
    6. apps tick         give the hello app its first time slice
    7. first frame       "UI is up" (DECISIONS.md 2.7 item 3)
    8. permissions       read /etc/perms/, then start the launcher (7b below)
    9. boot.commit()     write the global /boot.ok, drop journal + backup
   10. loop hook         hand over to whatever runs the machine

Since P6 there is one /system/ tree and no slot: an update is a file set applied
in place under a journal (pyroet-os/P6-design.md). The bootloader rolls a failed
or uncommitted update back before this file runs, so by the time the chain
starts, /system/ is either the old version, or the new one on trial.

Anything that makes the machine unbootable ends in `os.reboot()` and NOT in a
commit, so the bootloader's `/boot.tries` bookkeeping decides the rollback: a
system that cannot get to its first frame three times in a row is rolled back to
the bytes in /update.backup/. A boot plan of `fatal` (no system tree, or a
rollback that cannot be proven) does NOT reboot -- a reboot loop cannot repair a
broken byte -- it reports and returns, leaving the console to the ROM shell.

Readiness before commit is exactly: kernel not `failed`, every service that had
to start started (degraded is acceptable and logged), the app runtime made a
scheduling pass, and the frame callback returned non-false.

The desktop step (8) is deliberately after the first frame and before the
commit: the machine is provably up before anything interactive runs, a launcher
that is missing only costs a log line (the hello placeholder is the fallback),
and a launcher that raises is caught here so it can never turn a good boot into
a rollback loop. Declared capabilities are not grants, so the permission table
(kernel/permissions.lua) is attached before the kernel starts any app, and the
table is *read* at step 8 -- reading never prompts.

Usage (this is what the ROM stub runs):

    dofile("/system/startup.lua")

Usage under test (returns the module instead of booting):

    _G.PYROET_STARTUP_TEST = true
    local startup = dofile("/system/startup.lua")
    local result = startup.run({ fs = fake_fs, reboot = record_only })

Options accepted by run(opts): fs, root (boot state prefix), boot, kernel, apps,
boot_path, kernel_path, apps_path, apps_root, system_root, log, now, term,
frame, loop, reboot, version, services, rpv, rednet, redstone, peripheral, http,
write_limit, permissions, permissions_path, perms_root, ask, launcher.

No non-ASCII bytes in this file.
]]

local P = {}

P.VERSION = "0.2.0"
P.BOOT_PATH = "/system/boot.lua"
P.KERNEL_PATH = "/system/kernel/init.lua"
P.APPS_PATH = "/system/kernel/apps.lua"
P.PERMISSIONS_PATH = "/system/kernel/permissions.lua"
P.APPS_ROOT = "/apps"
-- the whole image lives here: /system/{startup,boot}.lua, kernel/, rpv/, net/,
-- and the system apps under /system/system/*.app. /apps and /etc stay at the
-- root because they are user data, not image content (DECISIONS.md 13.11).
P.SYSTEM_ROOT = "/system"
P.SYSTEM_APPS_ROOT = "/system/system"
P.LOG_PATH = "/kernel.log"
P.LAUNCHER = "launcher"
P.FALLBACK_APP = "hello"

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function load_module(path)
    local ok, module, err = pcall(dofile, path)
    if not ok then return nil, tostring(module) end
    if type(module) ~= "table" then
        return nil, "module " .. tostring(path) .. " did not return a table: " .. tostring(err)
    end
    return module
end

-- default logger: stdout plus an append-only /kernel.log (best effort)
function P.default_log(fsx, path)
    local file = path or P.LOG_PATH
    return function(line)
        print(line)
        if not fsx then return end
        local ok, handle = pcall(fsx.open, file, "a")
        if ok and handle then
            pcall(handle.write, line .. "\n")
            pcall(handle.close)
        end
    end
end

function P.default_frame(opts)
    local o = opts or {}
    return function(plan, status)
        local term = o.term or rawget(_G, "term")
        if not term then return true end
        local ok = pcall(function()
            term.clear()
            term.setCursorPos(1, 1)
            term.write("Pyroet OS " .. P.VERSION)
            term.setCursorPos(1, 2)
            term.write("kernel " .. tostring(status and status.health or "unknown"))
            term.setCursorPos(1, 3)
            term.write(tostring(plan and plan.action or "?")
                .. " journal " .. tostring(plan and plan.journal and plan.journal.state or "none"))
        end)
        return ok
    end
end

-- ---------------------------------------------------------------------------
-- commit metadata
-- ---------------------------------------------------------------------------

-- The marker carries version + manifest_sha + timestamp, and both come from the
-- update journal: after P6 the journal *is* the manifest description (the
-- per-slot /slots/<x>/.image died with /slots/), and boot.commit deletes it
-- right after the marker is written.
--
-- Three cases, in this order:
--   * journal state=applied -> the version and manifest_sha that was just tried
--     (the normal path after an OTA);
--   * no such journal but a marker on disk -> keep that marker's manifest_sha,
--     which is what a boot that just rolled an update back must not destroy;
--   * neither -> a system that was never updated, recorded as manifest_sha=none.
-- boot.lua prints its own BOOT_SHA_INVALID when a digest is malformed; a
-- missing description is only worth a log line here.
function P.commit_info(ctx)
    local info = { version = ctx.version or P.VERSION, manifest_sha = nil }
    local journal
    if type(ctx.boot.read_journal) == "function" then
        journal = ctx.boot.read_journal(ctx.boot_opts)
    end
    local marker
    if type(ctx.boot.read_marker) == "function" then
        marker = ctx.boot.read_marker(ctx.boot_opts)
    end
    if type(journal) == "table" and journal.state == "applied" then
        info.version = journal.version or info.version
        info.manifest_sha = journal.manifest_sha
    elseif type(marker) == "table" then
        info.version = marker.version or info.version
        info.manifest_sha = marker.manifest_sha
    end
    if not info.manifest_sha or info.manifest_sha == "none" then
        ctx.log("STARTUP_NO_MANIFEST source="
            .. tostring(type(journal) == "table" and journal.path or "none"))
    end
    return info
end

-- ---------------------------------------------------------------------------
-- system services
-- ---------------------------------------------------------------------------

local function register_hello(k, ctx)
    local ok, err = k:register("hello", {
        deps = {},
        start = function()
            local rt = ctx.rt
            if rt and rt:app("hello") then
                local started, why = rt:start("hello")
                if not started then return nil, why end
                ctx.log("HELLO_APP_STARTED")
                return true
            end
            -- no package shipped yet: the service is the placeholder the
            -- launcher will take over from, not a failure
            ctx.log("HELLO_PLACEHOLDER name=hello")
            return true
        end,
        health = function()
            local rt = ctx.rt
            if not rt then return true end
            local record = rt:app("hello")
            if record and record.state == "crashed" then return "degraded" end
            return true
        end,
        stop = function()
            local rt = ctx.rt
            if rt and rt:app("hello") then rt:kill("hello") end
            return true
        end,
    })
    return ok, err
end

function P.register_system(k, ctx)
    local ok, err = register_hello(k, ctx)
    if not ok then return nil, err end
    local extra = ctx.services
    if extra then
        for i = 1, #extra do
            local spec = extra[i]
            local ok2, err2 = k:register(spec.name, spec)
            if not ok2 then return nil, err2 end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- permissions and the desktop
-- ---------------------------------------------------------------------------

-- Boot has no keyboard: the P2 app runtime ships seven fixed capabilities and
-- none of them is input (DECISIONS.md 9.7). So the answer to "does this app get
-- this capability" is a policy rather than a question: a package that arrived
-- with the system image is granted exactly what its manifest declares, and
-- anything else is denied until an input service can actually ask. Whichever way
-- it goes, the permission table logs the prompt and every decision.
function P.default_ask(log)
    return function(app, cap, info)
        local dir = type(info) == "table" and tostring(info.dir or "") or ""
        if dir:sub(1, #P.SYSTEM_ROOT + 1) == P.SYSTEM_ROOT .. "/" then
            log("PERMS_PREGRANT app=" .. tostring(app) .. " cap=" .. tostring(cap))
            return true
        end
        return false
    end
end

-- Step 3c, before anything starts: declared is not granted, so the table has to
-- be attached while every start still has a chance to be gated.
function P.attach_permissions(ctx, o, log)
    local perms_mod = o.permissions
    if perms_mod == nil and ctx.rt then
        perms_mod = load_module(o.permissions_path or P.PERMISSIONS_PATH)
    end
    if ctx.rt and type(perms_mod) == "table" and type(perms_mod.new) == "function" then
        ctx.perms = perms_mod.new({
            fs = ctx.fs,
            log = log,
            root = o.perms_root,
            ask = o.ask or P.default_ask(log),
        })
        ctx.rt:set_permissions(ctx.perms)
        log("STARTUP_PERMS_READY root=" .. short(ctx.perms.root, 40))
        return true
    end
    if ctx.rt then log("STARTUP_PERMS_MISSING") end
    return false
end

-- Step 7b, after the first frame and before the commit: read the permission
-- table (reading never prompts), start the launcher through the runtime, and
-- fall back to the hello placeholder when there is no launcher package.
function P.start_desktop(ctx, o, log)
    if not ctx.rt then return false end
    local okp, stats = pcall(function()
        if not ctx.perms or type(ctx.rt.entries) ~= "function" then return nil end
        return ctx.perms:prefetch(ctx.rt:entries())
    end)
    if okp and type(stats) == "table" then
        log("STARTUP_PERMS_TABLE apps=" .. tostring(stats.apps)
            .. " loaded=" .. tostring(stats.loaded)
            .. " pending=" .. tostring(stats.pending)
            .. " bad=" .. tostring(stats.bad))
    elseif not okp then
        log("STARTUP_PERMS_TABLE_FAIL err=" .. short(stats))
    end

    local launcher = o.launcher or P.LAUNCHER
    local started_name = nil
    if ctx.rt:app(launcher) then
        local ok, why = ctx.rt:start(launcher)
        if ok then
            started_name = launcher
            ctx.launcher = launcher
            log("STARTUP_LAUNCHER_STARTED name=" .. launcher)
        else
            log("STARTUP_LAUNCHER_FAIL name=" .. launcher .. " err=" .. short(why))
        end
    else
        log("STARTUP_LAUNCHER_MISSING name=" .. launcher)
    end

    if not started_name and ctx.rt:app(P.FALLBACK_APP) then
        local fallback = ctx.rt:app(P.FALLBACK_APP)
        if fallback.state == "running" then
            ctx.launcher = P.FALLBACK_APP
            log("STARTUP_FALLBACK name=" .. P.FALLBACK_APP .. " state=running")
        else
            local ok, why = ctx.rt:start(P.FALLBACK_APP)
            if ok then
                started_name = P.FALLBACK_APP
                ctx.launcher = P.FALLBACK_APP
                log("STARTUP_FALLBACK name=" .. P.FALLBACK_APP .. " state=started")
            else
                log("STARTUP_FALLBACK_FAIL name=" .. P.FALLBACK_APP .. " err=" .. short(why))
            end
        end
    end

    -- one scheduling step, for the desktop only: the rest of the runtime keeps
    -- the time slice the boot chain already gave it (step 6)
    if started_name and type(ctx.rt.step) == "function" then
        local ok, advanced = pcall(ctx.rt.step, ctx.rt, started_name)
        if ok then
            log("STARTUP_DESKTOP_TICK advanced=" .. tostring(advanced))
        else
            log("STARTUP_DESKTOP_TICK_FAIL err=" .. short(advanced))
        end
    end
    return ctx.launcher ~= nil
end

-- ---------------------------------------------------------------------------
-- the chain
-- ---------------------------------------------------------------------------

local function reboot(ctx, reason)
    ctx.log("STARTUP_REBOOT reason=" .. short(reason))
    local ok, err = pcall(ctx.reboot)
    if not ok then
        ctx.log("STARTUP_REBOOT_FAIL err=" .. short(err))
    end
    return { ok = false, rebooted = true, reason = tostring(reason) }
end

function P.run(opts)
    local o = opts or {}
    local fsx = o.fs or rawget(_G, "fs")
    local log = o.log or P.default_log(fsx, o.log_path)

    local boot, boot_err = o.boot, nil
    if not boot then boot, boot_err = load_module(o.boot_path or P.BOOT_PATH) end
    if type(boot) ~= "table" or type(boot.begin) ~= "function" then
        log("STARTUP_BOOT_MODULE_FAIL err=" .. short(boot_err or "not a module"))
        return { ok = false, error = "boot module unavailable" }
    end

    local kernel_mod = o.kernel or load_module(o.kernel_path or P.KERNEL_PATH)
    if type(kernel_mod) ~= "table" or type(kernel_mod.new) ~= "function" then
        log("STARTUP_KERNEL_MODULE_FAIL")
        return { ok = false, error = "kernel module unavailable" }
    end

    local ctx = {
        fs = fsx,
        boot = boot,
        log = log,
        version = o.version,
        services = o.services,
        rt = nil,
        perms = nil,
        launcher = nil,
        boot_opts = { fs = fsx, root = o.root or "", log = log, now = o.now },
        reboot = o.reboot or function()
            if os and os.reboot then os.reboot() end
        end,
    }

    -- 1. boot decision ----------------------------------------------------
    local plan = boot.begin(ctx.boot_opts)
    log("STARTUP_PLAN action=" .. tostring(plan.action)
        .. " journal=" .. tostring(type(plan.journal) == "table" and plan.journal.state or "none")
        .. " tries=" .. tostring(plan.tries or 0))
    if plan.action == "fatal" then
        log("STARTUP_FATAL reason=" .. short(plan.error))
        return { ok = false, fatal = true, plan = plan, error = tostring(plan.error) }
    end

    -- 2/3. kernel and app runtime -----------------------------------------
    local k = kernel_mod.new({ log = log })

    -- The read-only system surface (DECISIONS.md 8.6): kernel health, the app
    -- index and one app's permission decisions, plus the runtime's own start
    -- entry so the launcher never pulls a coroutine by hand. Handed only to the
    -- packages under the system root; everything else gets the stubs.
    local sys_host = {
        status = function()
            if type(k.status) ~= "function" then return nil, "kernel status unavailable" end
            return k:status()
        end,
        apps = function()
            if not ctx.rt then return nil, "no app runtime" end
            return ctx.rt:status().apps
        end,
        perms = function(name)
            if not ctx.perms then return nil, "no permission table" end
            return ctx.perms:decisions_for(name)
        end,
        launch = function(name)
            if not ctx.rt then return nil, "no app runtime" end
            if not ctx.rt:app(name) then return nil, "no such app: " .. tostring(name) end
            return ctx.rt:start(name)
        end,
    }
    local function sys_for(record)
        local dir = type(record) == "table" and tostring(record.dir or "") or ""
        if dir:sub(1, #P.SYSTEM_ROOT + 1) ~= P.SYSTEM_ROOT .. "/" then return nil end
        return sys_host
    end

    local apps_mod = o.apps or load_module(o.apps_path or P.APPS_PATH)
    if type(apps_mod) == "table" and type(apps_mod.new) == "function" then
        ctx.rt = apps_mod.new({
            fs = fsx,
            log = log,
            apps_root = o.apps_root or P.APPS_ROOT,
            max_starts = o.max_starts,
            write_limit = o.write_limit,
            rpv = o.rpv,
            rednet = o.rednet,
            redstone = o.redstone,
            peripheral = o.peripheral,
            http = o.http,
            sys = sys_for,
        })
        ctx.rt:scan()
        -- the system apps ship with the image under /system/system, next to the
        -- boot chain and not under the user app root /apps
        local system_root = o.system_root
        if system_root == nil then system_root = P.SYSTEM_APPS_ROOT end
        if system_root ~= false and system_root ~= "" then
            ctx.rt:scan(system_root)
        end
    else
        log("STARTUP_APPS_MODULE_MISSING")
    end

    -- 3c. declared capabilities are only declared --------------------------
    pcall(P.attach_permissions, ctx, o, log)

    -- 4. services ----------------------------------------------------------
    local ok, err = P.register_system(k, ctx)
    if not ok then
        log("STARTUP_REGISTER_FAIL err=" .. short(err))
        return reboot(ctx, "register")
    end

    -- 5. start -------------------------------------------------------------
    local status = k:start_all()
    log("STARTUP_KERNEL health=" .. tostring(status.health)
        .. " running=" .. tostring(status.counts.running)
        .. " failed=" .. tostring(status.counts.failed)
        .. " skipped=" .. tostring(status.counts.skipped))
    if status.fatal then
        return reboot(ctx, "kernel_health")
    end

    -- 6. one scheduling pass so on_start bodies are running before the frame
    if ctx.rt then
        local advanced = ctx.rt:tick()
        log("STARTUP_APPS_TICK advanced=" .. tostring(advanced))
    end

    -- 7. first frame -------------------------------------------------------
    local frame = o.frame or P.default_frame(o)
    local okf, fret = pcall(frame, plan, status, ctx.rt)
    if not okf then
        log("STARTUP_FRAME_FAIL err=" .. short(fret))
        return reboot(ctx, "first_frame")
    end
    if fret == false then
        log("STARTUP_FRAME_NOT_READY")
        return reboot(ctx, "first_frame")
    end
    log("STARTUP_UI_READY")

    -- 7b. the desktop: permission table first, then the launcher -----------
    local okd, derr = pcall(P.start_desktop, ctx, o, log)
    if not okd then log("STARTUP_DESKTOP_FAIL err=" .. short(derr)) end

    -- 8. commit (writes the global /boot.ok, then drops journal and backup) --
    local info = P.commit_info(ctx)
    local okc, cerr = boot.commit(info, ctx.boot_opts)
    if not okc then
        log("STARTUP_COMMIT_FAIL err=" .. short(cerr))
        return reboot(ctx, "commit")
    end
    log("STARTUP_COMMITTED version=" .. tostring(info.version)
        .. " manifest_sha=" .. tostring(info.manifest_sha or "none"))

    -- 9. hand over ---------------------------------------------------------
    if o.loop then
        local okl, lerr = pcall(o.loop, k, ctx.rt, plan)
        if not okl then log("STARTUP_LOOP_FAIL err=" .. short(lerr)) end
    end

    return {
        ok = true,
        committed = true,
        rebooted = false,
        plan = plan,
        status = status,
        kernel = k,
        apps = ctx.rt,
        perms = ctx.perms,
        launcher = ctx.launcher,
        info = info,
        version = P.VERSION,
    }
end

P.register = P.register_system

-- A harness sets _G.PYROET_STARTUP_TEST before dofile to receive this module
-- instead of booting the machine right here. Real boots never set it.
if rawget(_G, "PYROET_STARTUP_TEST") then
    return P
end

return P.run()
