-- desktop.lua - the GNOME-like desktop of the Pyromputer OS machine (package gnome).
--
-- USAGE
--   desktop
--   desktop --headless --events FILE [--dump FILE] [--clock HH:MM]
--   desktop --autostart on|off|status
--
-- WHAT --autostart DOES, AND WHAT IT DELIBERATELY DOES NOT DO
--   The default boot of this machine is psh. `desktop` inside psh is the way in,
--   and leaving the desktop returns to psh. --autostart on makes the NEXT boot
--   start the desktop instead: it writes one line to /etc/session.conf, and the
--   boot script runs that line through psh before the shell, so a package command
--   resolves exactly as it does in a session. --autostart off removes the line and
--   the next boot is psh again. It never touches /startup.lua: the boot script
--   stays the machine's, and this command only fills in one optional key, which is
--   why the base installation names no package and a machine that never runs this
--   still boots into the shell.
--   It is root only, because it decides what the machine starts, and a session an
--   ordinary account could switch is a machine whose owner has lost control of it.
--
-- WHY --headless IS PART OF THE COMMAND AND NOT A TEST HOOK
--   term.getLine does not exist on CraftOS-PC 2.8.3 (measured), so a drawn cell
--   cannot be read back off a terminal: a run that only renders to the screen can
--   show that nothing raised, never that the panel says what it should. A machine
--   acceptance therefore has to render into a buffer screen and look at the cells
--   -- the same path the PC suite takes. --headless is that path, spelled as a
--   documented mode of the command rather than a build only a test can reach: it
--   reads synthetic events from FILE, renders into a buffer, and writes the cells
--   (character, foreground and background per cell) plus the desktop's own state
--   to --dump.
--
-- WHY IT REFRESHES THE MODULE PATHS ITSELF
--   Installing a package registers its commands, but the package's lib/ directory
--   is put on package.path when the machine boots or a medium is mounted -- not by
--   the install. Without the refresh below, "desktop" would resolve, fail to load
--   gnome.desktop, and only work after a reboot. lib/mounts.lua is part of the base
--   installation and owns that scan, so this asks it.
--
-- EXIT STATUS  0 ran, 1 usage or a failure while loading, 130 interrupted.
local args, stage = ...

local function out(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local function usage()
    out("usage: desktop [--headless --events FILE [--dump FILE] [--clock HH:MM]]")
    out("       desktop --autostart on|off|status")
    out("  run the GNOME-like desktop on this machine, or render it headless.")
    out("  --headless    no terminal: render into a buffer screen and dump the cells")
    out("  --events F    the synthetic events to drive it with, one per line")
    out("  --dump F      write the screen dump to F (default: print it)")
    out("  --clock T     the clock text to draw instead of the time of day")
    out("  --autostart   on: the next boot starts this desktop instead of psh")
    out("                off: the next boot starts psh (the default)")
    out("                status: say what the next boot will start (root only to set)")
end

-- ---------------------------------------------------------------------------
-- the optional session (/etc/session.conf), which the boot script reads
-- ---------------------------------------------------------------------------
-- One key, `command`, holding the command line the boot runs through psh before
-- the shell. The file is key=value, like the rest of /etc, and other keys a future
-- boot script might add are preserved: this command owns one key, not the file.
local SESSION_CONF = "/etc/session.conf"

local function session_lines()
    local out_lines = {}
    if type(fs) ~= "table" or type(fs.open) ~= "function" then return out_lines end
    local f = fs.open(SESSION_CONF, "r")
    if not f then return out_lines end
    local ok, text = pcall(f.readAll)
    f.close()
    if not ok then return out_lines end
    for line in (tostring(text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if line:match("%S") then out_lines[#out_lines + 1] = line end
    end
    return out_lines
end

local function session_current()
    for _, line in ipairs(session_lines()) do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "command" then return value end
    end
    return nil
end

-- Write the key, or drop it. Answers true, or false plus the reason.
local function session_write(command)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then
        return false, "this machine has no filesystem"
    end
    local keep = {}
    for _, line in ipairs(session_lines()) do
        local key = line:match("^%s*([%w_]+)%s*=")
        if key ~= "command" then keep[#keep + 1] = line end
    end
    if command then keep[#keep + 1] = "command=" .. command end
    if #keep == 0 then
        if fs.exists(SESSION_CONF) then
            pcall(fs.delete, SESSION_CONF)
            -- "removed" is checked rather than assumed: a machine whose /etc cannot
            -- be written must say so instead of silently booting the same session.
            if fs.exists(SESSION_CONF) then
                return false, "cannot remove " .. SESSION_CONF
            end
        end
        return true
    end
    local f = fs.open(SESSION_CONF, "w")
    if not f then return false, "cannot write " .. SESSION_CONF .. " (is this machine's /etc writable?)" end
    f.write(table.concat(keep, "\n") .. "\n")
    f.close()
    return true
end

-- The console account is not root, and this decides what the machine starts: it is
-- refused rather than silently done, the way `pkg install` is. A machine with no
-- user database is a single user machine, so it is treated as root.
local function machine_is_root()
    local okp, p = pcall(require, "perm")
    if okp and type(p) == "table" and type(p.get_current_user) == "function" then
        local ok, user = pcall(p.get_current_user)
        if ok and user ~= nil then return tostring(user) == "root" end
    end
    return true
end

local opts = { headless = false }
local i = 1
while args and args[i] do
    local a = args[i]
    if a == "--headless" then
        opts.headless = true
    elseif a == "--autostart" then
        i = i + 1
        opts.autostart = args[i] or "status"
    elseif a == "--events" or a == "--dump" or a == "--clock" then
        i = i + 1
        if args[i] == nil then
            usage()
            out("desktop: " .. a .. " needs a value")
            return 1
        end
        opts[a:sub(3)] = args[i]
    elseif a == "--help" or a == "-h" then
        usage()
        return 0
    else
        usage()
        out("desktop: unknown option: " .. tostring(a))
        return 1
    end
    i = i + 1
end

-- The session switch is answered here, before anything is loaded: it has to work
-- on a machine whose package modules are on package.path only after a reboot, and
-- it must not start a desktop as a side effect of asking what the next boot does.
if opts.autostart then
    local mode = tostring(opts.autostart)
    if mode == "status" then
        out("autostart: " .. tostring(session_current() or "psh (the default)"))
        return 0
    end
    if mode ~= "on" and mode ~= "off" then
        usage()
        out("desktop: --autostart takes on, off or status")
        return 1
    end
    if not machine_is_root() then
        out("desktop: --autostart needs root: it decides what this machine starts")
        out("desktop: try: sudo desktop --autostart " .. mode)
        return 1
    end
    -- The command line written out is this command's own name: the boot runs it
    -- through psh, so "desktop" resolves exactly as it does in a session.
    local wanted = (mode == "on") and "desktop" or nil
    local wrote, why = session_write(wanted)
    if not wrote then
        out("desktop: " .. tostring(why))
        return 1
    end
    if mode == "on" then
        out("desktop: the next boot starts the desktop instead of psh")
        out("desktop: leaving the desktop still gives you psh; 'desktop --autostart off' undoes this")
    else
        out("desktop: the next boot starts psh")
    end
    return 0
end

if opts.headless and not opts.events then
    usage()
    out("desktop: --headless needs --events FILE")
    return 1
end

-- Put this package's lib/ directory on package.path (see the header).
local okm, mounts = pcall(require, "mounts")
if okm and type(mounts) == "table" and type(mounts.refresh_module_paths) == "function" then
    pcall(mounts.refresh_module_paths)
end

-- A module that is there but raises is a different failure from a module that is
-- not on package.path at all, and the message has to say which: the traceback is
-- appended when the machine has the debug library, because "attempt to call a nil
-- value" with no file and no line is not something an operator can act on.
local function trace(err)
    if type(debug) == "table" and type(debug.traceback) == "function" then
        return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
end

local ok, desktop = xpcall(function() return require("gnome.desktop") end, trace)
if not ok then
    out("desktop: cannot load gnome.desktop: " .. tostring(desktop))
    out("desktop: the gnome package's lib/ directory has to be on package.path " ..
        "-- is the package installed on this machine?")
    return 1
end
local screenmod = require("gnome.screen")

local function read_events(path)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then
        return nil, "this machine has no filesystem to read " .. tostring(path) .. " from"
    end
    local f = fs.open(path, "r")
    if not f then return nil, "cannot read " .. tostring(path) end
    local text = f.readAll()
    f.close()
    return desktop.parse_events(text)
end

if opts.headless then
    local events, why = read_events(opts.events)
    if not events then
        out("desktop: " .. tostring(why))
        return 1
    end
    local w, h = 51, 19
    if type(term) == "table" and type(term.getSize) == "function" then
        local tw, th = term.getSize()
        if tonumber(tw) and tonumber(th) then w, h = math.floor(tw), math.floor(th) end
    end
    local screen = screenmod.buffer(math.max(1, w), math.max(1, h))
    local _, d = desktop.run({ screen = screen, events = events, clock = opts.clock })
    local text = desktop.dump(screen, d)
    if opts.dump then
        local f = fs.open(opts.dump, "w")
        if not f then
            out("desktop: cannot write " .. tostring(opts.dump))
            return 1
        end
        f.write(text)
        f.close()
        out(string.format("desktop: %d event(s) -> %s (%dx%d)", #events, opts.dump, w, h))
    else
        out(text)
    end
    return 0
end

-- WHERE THE OPERATOR IS LEFT. "the desktop is gone" must not mean "the machine
-- is outside its own system": started from a psh session, returning to the
-- caller is the prompt; started from a boot script that runs this module
-- directly, or from the CraftOS prompt, it is not, and the operator would be
-- looking at a bare ROM prompt with the machine's shell gone. psh marks the
-- commands it runs (__psh_command), so the two cases are told apart by a fact
-- rather than by guessing about the caller (gnome.desktop's landing says why).
local PSH_PATH = "/usr/psh.lua"
local function land()
    return desktop.landing({
        in_shell = __psh_command == true,
        run_shell = function()
            if type(shell) ~= "table" or type(shell.run) ~= "function" then
                return false
            end
            return shell.run(PSH_PATH) and true or false
        end,
    })
end

-- A DESKTOP INSIDE A WINDOW IS REFUSED. The Terminal and the Console run the
-- project's shell in a window of the desktop; `desktop` typed at that prompt would
-- start a second desktop inside that window, where its frame would be drawn into
-- an invisible window of the outer one, two pumps would compete for one event
-- stream, and the operator could not get back to anything. The machine's own
-- screen is the only terminal a desktop runs on, so a terminal that reports a
-- window's getLine (see gnome.desktop's needs_whole_screen) is refused with the
-- reason and status 1.
-- The decision itself is gnome.desktop's needs_whole_screen, so the suite can test
-- it without running the command.
if type(term) == "table" and type(term.current) == "function" then
    local okc, target = pcall(term.current)
    if okc and desktop.needs_whole_screen(target) then
        out("desktop: cannot start inside a window of another desktop")
        out("desktop: it needs the machine's own screen")
        out("desktop: run it from that screen instead")
        return 1
    end
end

local d, err = desktop.run_interactive({ clock = opts.clock })
if not d then
    -- Ctrl+T on a CraftOS console arrives as a terminate event, which
    -- os.pullEvent turns into the error "Terminated". That is a normal way to
    -- leave a full screen program, not a fault, so it gets the status of an
    -- interrupted command. The landing still applies: an interrupted desktop
    -- started outside the shell would otherwise drop the operator out of the
    -- system too.
    if tostring(err):find("Terminated", 1, true) then
        out("desktop: interrupted")
        if land() == "shell-failed" then
            out("desktop: cannot start " .. PSH_PATH .. "; the shell is not running")
        end
        return 130
    end
    out("desktop: " .. tostring(err))
    return 1
end
out("desktop: left the desktop (" .. tostring(d.exit_reason) .. ")")
-- "log out" means the psh SESSION ends, not that the machine does: the shell
-- honours /var/lib/.logout at the session boundary and the boot script starts
-- a fresh psh. The request is written only when a shell started this desktop;
-- started anywhere else there is no session to end, and the landing below
-- puts the operator at psh instead.
if tostring(d.exit_reason) == "logout" and __psh_command == true then
    pcall(function()
        if not fs.exists("/var/lib") then fs.makeDir("/var/lib") end
        local f = fs.open("/var/lib/.logout", "w")
        if f then f.write("logout" .. string.char(10)); f.close() end
    end)
end
local where = land()
if where == "shell-failed" then
    out("desktop: cannot start " .. PSH_PATH .. "; the shell is not running")
    return 1
end
return 0
