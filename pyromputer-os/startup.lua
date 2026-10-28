-- Clear the ROM's boot banner ("CraftOS 1.9", "Press DEL to enter SETUP") before
-- anything of ours is drawn, so the operator's first sight of the machine is the
-- shell and not the firmware.
--
-- GUARDED ON PURPOSE. This is the first statement of the boot script: if `shell`
-- were not in scope here, a bare shell.run() would raise and the watchdog below
-- would never start, leaving the machine parked at a bare CraftOS prompt with no
-- way back short of editing the file. pcall costs nothing and cannot brick a box.
if type(shell) == "table" and type(shell.run) == "function" then
    pcall(shell.run, "clear")
end

-- startup.lua - watchdog + first boot hook
-- Relaunches psh whenever it exits, unless root requested escape.
-- Ignores Ctrl+T to prevent dropping to CraftOS shell.
-- On a machine that has not been set up yet firstboot is run until it succeeds.

-- ------------------------------------------------------------------
-- Module search paths: /lib/?.lua and /usr/?.lua so that
-- require("perm"), require("cwd"), ... resolve on CC:Tweaked.
-- ------------------------------------------------------------------
local EXTRA_PATHS = { "/lib/?.lua", "/usr/?.lua" }
for _, entry in ipairs(EXTRA_PATHS) do
    if not package.path:find(entry, 1, true) then
        package.path = entry .. ";" .. package.path
    end
end

-- ------------------------------------------------------------------
-- Modules that live on a mounted medium. On a machine built in two
-- parts (the shell here, its own modules on a medium marked .pkgsys)
-- the shell's modules are not under /lib at all: they are packages at
-- <medium>/usr/pkgs/<name>/lib. require() only searches package.path,
-- so those directories have to be put there, and this has to happen
-- BEFORE the first require of anything they carry.
--
-- The scan lives in lib/mounts.lua, which is always on the computer --
-- it cannot live in lib/pkg.lua, because on such a machine pkg.lua is
-- itself on the medium, and a shell that had to load the package
-- manager to find the medium's modules could never start.
--
-- pcall: a machine with no medium is the ordinary case, not an error.
-- ------------------------------------------------------------------
local mounts_ok, mounts = pcall(require, "mounts")
if mounts_ok and type(mounts) == "table" and mounts.refresh_module_paths then
    pcall(mounts.refresh_module_paths)
end

-- psh lives in /usr/, which is not on the CraftOS shell search path,
-- so the launcher targets its absolute path.
local marker = require("marker")

-- OS-LEVEL USERS: wrap fs's mutating calls so a program cannot do what the
-- shell refuses (lib/osguard.lua). Installed once, before the shell starts; a
-- machine where that fails keeps the shell-level checks and the boot guard.
--
-- The require is written HERE, at column 0, and not only inside the pcall below.
-- tools/deploy.py decides the two halves of a two-part install from the
-- column-0 requires of the entry points; a require that lives only inside an
-- anonymous function (even one the pcall runs at boot) is classified as lazy and
-- shipped on the system module medium. Measured: that put lib/osguard.lua on
-- part 2, and a machine with no medium inserted had no guard at all -- a program
-- could fs.open("/usr/psh.lua", "a") and the permission model was gone from the
-- program layer. The pcall keeps its job (a failed install must not stop the
-- boot); the require's placement is what keeps the module on the computer.
require("osguard")
pcall(function()
    local og = require("osguard")
    if type(og) == "table" and og.install then og.install() end
end)

local LAUNCH_TARGET = "/usr/psh.lua"
local RELAUNCH_DELAY = 0.2
local MAX_CRASHES_PER_MINUTE = 20
local crash_times = {}

local function record_crash()
    table.insert(crash_times, os.epoch("utc") / 1000)
    local cutoff = os.epoch("utc") / 1000 - 60
    while #crash_times > 0 and crash_times[1] < cutoff do
        table.remove(crash_times, 1)
    end
end

local function too_many_crashes()
    return #crash_times >= MAX_CRASHES_PER_MINUTE
end

-- ------------------------------------------------------------------
-- Scheduled tasks. While a session is running, psh drives the queue from its
-- own idle hook; the watchdog keeps the clock alive in the gaps (crash
-- restart, setup gate) so that due entries do not have to wait for the next
-- login. Commands are fired through a non-interactive psh run, so builtins,
-- pipes and redirections behave exactly as in a session.
-- ------------------------------------------------------------------
local SCHED_TICK = 0.25
local sched_ok, cron = pcall(require, "cron")
local last_sched_tick = 0

-- Removable media. The shell mounts disks from its own editor loop while a
-- session runs; the watchdog covers the gaps (crash restart, setup gate,
-- a non-interactive psh run) so a disk inserted then is still picked up.
local disk_ok, disk = pcall(require, "disk")
local services_ok, services = pcall(require, "services")

local function run_scheduled(command)
    shell.run(LAUNCH_TARGET, "-c", command)
end

-- ------------------------------------------------------------------
-- The SESSION COMMAND: an optional session that starts before psh.
--
-- /etc/session.conf is a key=value file, the same shape as the rest of /etc, and
-- the one key read here is `command`. What it names is run through psh -- not
-- through the ROM shell -- so a command that lives in an installed package is
-- found exactly as the operator would find it inside a session. It runs ONCE per
-- boot: when it returns, the ordinary psh session starts, which is what leaving
-- a graphical session means.
--
-- This file is deliberately generic and the base installation names no package
-- here: a machine that never sets the key boots into psh and nothing else, so
-- installing an extra package cannot quietly take the shell away. The reader is
-- defensive for the same reason the setup gate is: a boot file that cannot be
-- read must never keep the shell from starting.
-- ------------------------------------------------------------------
local SESSION_CONF = "/etc/session.conf"

local function session_command()
    if type(fs) ~= "table" or type(fs.open) ~= "function" then return nil end
    local f = fs.open(SESSION_CONF, "r")
    if not f then return nil end
    local ok, text = pcall(f.readAll)
    f.close()
    if not ok then return nil end
    for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "command" and value ~= "" then return value end
    end
    return nil
end

local DCNET_CONF = "/etc/dcnet.conf"

-- dcnet boot entry: /etc/dcnet.conf may ask for a resident master or worker.
-- The root/control paths are computed here (before the shell starts) so the
-- shell can write commands into the same queue the daemon reads.
local function dcnet_boot_config()
    _G.PSH_BOOT_JOBS = nil
    _G.PSH_FORWARD = nil
    _G.DCNET_CTL = nil
    _G.DCNET_BOOT_ROLE = nil
    _G.DCNET_MULTISHELL = nil
    _G.DCNET_BIN = nil
    local f = fs.open(DCNET_CONF, "r")
    if not f then return end
    local ok, text = pcall(f.readAll)
    f.close()
    if not ok then return end
    local conf = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local key, value = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then conf[key] = value end
    end
    local user = "root"
    local okp, perm = pcall(require, "perm")
    if okp and type(perm) == "table" and type(perm.get_current_user) == "function" then
        user = perm.get_current_user() or user
    end
    local root = conf.root
    if not root or root == "" then
        if user == "root" then
            root = "/var/lib/dcnet"
        else
            root = "/home/" .. tostring(user) .. "/.dcnet"
        end
    end
    _G.DCNET_ROOT = root
    _G.DCNET_CTL = root .. "/ctl"
    local boot = tostring(conf.boot or ""):lower()
    local role = nil
    if boot == "master" or boot == "worker" then role = boot end
    _G.DCNET_BOOT_ROLE = role
    if role then
        local okb, pkg = pcall(require, "pkg")
        if okb and type(pkg) == "table" and type(pkg.resolve_command) == "function" then
            _G.DCNET_BIN = pkg.resolve_command("dcnet")
        end
        -- Advanced computers get a real multishell: dcnet owns one tab and psh
        -- another, instead of the shell running dcnet as a background job.
        local ms = tostring(conf.multishell or "1"):lower()
        local has_multishell = fs.exists("/rom/programs/advanced/multishell.lua")
        if has_multishell and ms ~= "0" and ms ~= "false" and ms ~= "no" then
            _G.DCNET_MULTISHELL = true
        else
            _G.PSH_BOOT_JOBS = { "dcnet " .. role .. " --headless" }
        end
    end
    local fwd = tostring(conf.forward or ""):lower()
    _G.PSH_FORWARD = (fwd == "1" or fwd == "true" or fwd == "yes")
end

local function tick_disk(name, side)
    if not disk_ok or type(disk) ~= "table" then return end
    pcall(function()
        local lines = disk.on_event(name, side)
        for _, line in ipairs(lines or {}) do print(line) end
    end)
end

local function tick_scheduler()
    if not sched_ok or type(cron) ~= "table" then return end
    if not fs.exists("/etc/crontab") and not fs.exists("/var/spool/at") then return end

    local now = os.epoch("utc") / 1000
    if (now - last_sched_tick) < 1 then return end
    last_sched_tick = now

    pcall(cron.run_due, nil, run_scheduled)
end

local function sleep_ignoring_terminate(seconds)
    local deadline = os.epoch("utc") / 1000 + seconds
    local timer = os.startTimer(SCHED_TICK)
    while true do
        local ev = { os.pullEventRaw() }
        if ev[1] == "timer" and ev[2] == timer then
            tick_scheduler()
            if os.epoch("utc") / 1000 >= deadline then
                return true
            end
            timer = os.startTimer(SCHED_TICK)
        elseif ev[1] == "disk" or ev[1] == "disk_eject" then
            tick_disk(ev[1], ev[2])
        elseif ev[1] == "terminate" then
            -- ignore Ctrl+T
        elseif ev[1] == "shutdown" or ev[1] == "reboot" then
            return false
        end
    end
end

-- There is no "drop to the CraftOS shell" path any more. The old one worked by
-- having the shell write /var/lib/.escape_allowed and this watchdog read it and
-- break out of its loop; the "craftos" built-in is replaced by "reboot", which
-- restarts the machine through this file instead of abandoning it. Removing the
-- flag file as well as the reader matters: a flag left behind by an older install
-- would otherwise look like a request nobody can now honour.
local function clear_stale_escape_flag()
    local stale = "/var/lib/.escape_allowed"
    if fs.exists(stale) then
        fs.delete(stale)
        print("[watchdog] removed a stale escape flag from an older install")
    end
end

local services_booted = false
-- Whether the optional session command has already had its turn this boot. It is
-- one shot on purpose: after it exits, psh runs, and a psh crash/relaunch must not
-- drop the operator back into the session they just left.
local session_done = false

-- The setup screen, shown once per boot. It runs FIRST, before the licence gate
-- and before firstboot, because it is firmware: the settings it changes are the
-- ones that decide whether the rest may run at all, and a machine whose shell
-- will not start must still be able to reach it.
--
-- A failure inside the screen must never stop the machine from booting, so the
-- whole thing is wrapped: if lib/bios.lua cannot be loaded (a damaged install)
-- the boot carries on as if the window had simply been missed.
local bios_done = false

clear_stale_escape_flag()

while true do
    if not bios_done then
        bios_done = true
        local ok_bios, bios = pcall(require, "bios")
        if ok_bios and type(bios) == "table" and bios.gate then
            -- "reboot bios" leaves a one shot request for this screen. It is read
            -- here, before the DEL window, so the operator does not have to win a
            -- race against a three second timer after asking for the screen.
            local armed = false
            pcall(function() armed = bios.setup_requested() end)
            if armed then
                print("[bios] opening setup as requested by 'reboot bios'")
                pcall(function() bios.disarm_setup() end)
            end

            -- The ROM's boot switches are re-enforced BEFORE the screen is shown,
            -- and before anything else of ours runs. This is the one defence that
            -- has to happen first: rom/startup.lua consults
            -- shell.allow_disk_startup BEFORE it runs this file at all, so a disk
            -- carrying a "startup" replaces the machine's own startup and nothing
            -- here executes. Re-enforcing now means the NEXT boot is safe even if
            -- this one was taken over -- and /.settings ships with the install, so
            -- the first boot is safe too.
            local changed = nil
            pcall(function() changed = bios.enforce_rom_settings() end)
            if type(changed) == "table" and #changed > 0 then
                print("[bios] restored boot settings: " .. table.concat(changed, ", "))
            end

            local proceed = true
            pcall(function() proceed = bios.gate({ force_window = armed }) end)
            -- The gate draws its own "Press DEL to enter SETUP" prompt, and it does
            -- so AFTER the clear at the top of this file -- so clearing only there
            -- leaves that one firmware line sitting above the shell banner
            -- (measured on the GUI: "Press DEL to enter SETUP" survived). Clear
            -- again once the window has closed. Measured after this: the screen
            -- goes straight to "psh 1.0 - type 'help' for commands".
            if proceed and type(shell) == "table" and type(shell.run) == "function" then
                pcall(shell.run, "clear")
            end
            if not proceed then
                -- A BIOS password is required and was not given. The machine stays
                -- at the setup screen rather than handing over a shell: that is
                -- what a firmware password means. Ctrl+T is ignored so the
                -- prompt cannot be escaped, and the loop only ends on a power
                -- cycle -- there is no other way back in, by design.
                print("")
                print("[bios] the shell was not started: the BIOS password is required")
                while true do
                    sleep_ignoring_terminate(3600)
                end
            end
        end
    end

    -- SETUP GATE. firstboot writes the setup marker (lib/marker.lua) when it
    -- finishes; a machine without one runs setup before the shell. There is no
    -- licence server any more (2026-10-17): the gate answers "has this machine
    -- been set up", not "is this machine allowed", and the marker is bound to
    -- this computer, so a copy taken to another machine does not count.
    if not marker.done() then
        pcall(function() shell.run("firstboot") end)
        if not marker.done() then
            -- Setup was cancelled or failed; delay and retry on the next pass
            sleep_ignoring_terminate(1)
        end
    end

    -- Only launch the shell after setup is complete
    if marker.done() then
        -- Bring the /etc/rc.d units up once per boot. A unit that fails is
        -- logged and skipped, so it can never keep the shell from starting;
        -- psh skips the units that are already up when it takes over.
        if services_ok and type(services) == "table" and not services_booted then
            services_booted = true
            pcall(function()
                local res = services.boot()
                for _, n in ipairs(res.started or {}) do
                    print("[service] " .. n .. " started")
                end
                for _, item in ipairs(res.failed or {}) do
                    print("[service] " .. item.name .. " failed: " .. item.reason)
                end
            end)
        end

        -- The shell is run under xpcall, not pcall, so a crash is contained AND
        -- explained. A pcall reports only the error message; the traceback says
        -- which line of which module raised it, and on a machine with no console
        -- output to scroll back through, that is the difference between a bug
        -- that can be found and one that can only be reproduced.
        --
        -- The handler is written to be incapable of failing: it runs while the
        -- stack is unwinding, so an error inside it would replace the real error
        -- with a confusing one. debug.traceback is optional in the ROM, hence the
        -- pcall around it (the same guard lib/rpvnet.lua uses).
        local function crash_report(err)
            local trace = ""
            if debug and debug.traceback then
                local okt, tb = pcall(debug.traceback, "", 2)
                if okt and tb then trace = "\n" .. tostring(tb) end
            end
            return tostring(err) .. trace
        end

        -- THE OPTIONAL SESSION FIRST (see session_command above): one command line,
        -- at most once per boot, run through psh and before the shell. Its failure
        -- is a note and never a reason to withhold the shell: a session command
        -- whose package was removed must land the operator on psh, not on a
        -- machine that boots to a blank screen.
        if not session_done then
            session_done = true
            local read_ok, session_cmd = pcall(session_command)
            if read_ok and session_cmd then
                print("[watchdog] starting the session command: " .. tostring(session_cmd))
                local sok, sres = xpcall(function()
                    return shell.run(LAUNCH_TARGET, "-c", session_cmd)
                end, crash_report)
                if not sok then
                    print("[watchdog] the session command raised: " .. tostring(sres))
                elseif sres == false then
                    print("[watchdog] the session command could not run: " ..
                          tostring(session_cmd))
                end
                print("[watchdog] the session ended; starting psh")
            end
        end

        pcall(dcnet_boot_config)
        local ok, err = xpcall(function()
            if rawget(_G, "DCNET_MULTISHELL") and rawget(_G, "DCNET_BOOT_ROLE") then
                -- Multishell takes a shell in tab 1. Queue the tab launcher as
                -- typed input so the machine ends with dcnet in tab 1 and psh
                -- in tab 2, without copying or patching the ROM.
                local typed = "/usr/dcnet-tabs.lua"
                for ch in typed:gmatch(".") do os.queueEvent("char", ch) end
                os.queueEvent("key", (keys and keys.enter) or 28)
                return shell.run("/rom/programs/advanced/multishell.lua")
            end
            return shell.run(LAUNCH_TARGET)
        end, crash_report)

        if not ok then
            record_crash()
            if not fs.exists("/var/log") then fs.makeDir("/var/log") end
            local f = fs.open("/var/log/watchdog.log", "a")
            if f then
                f.write(string.format("[%s] psh crashed: %s\n",
                    os.date("%Y-%m-%d %H:%M:%S"), tostring(err)))
                f.close()
            end
        end

        local wait_time = too_many_crashes() and 5 or RELAUNCH_DELAY
        if not sleep_ignoring_terminate(wait_time) then
            -- The computer is going down: take the units down in reverse order
            -- while the VM is still alive.
            if services_ok and type(services) == "table" then
                pcall(services.shutdown)
            end
            break
        end
    end
end
