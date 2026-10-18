-- bios.lua - the setup screen shown for three seconds before the shell starts
--
-- WHAT IT IS FOR
-- A few settings decide how the machine behaves before anyone can log in: whether
-- the shell may be left, whether a boot file may be overwritten, and whether this
-- screen itself is locked. Those are properties of the MACHINE, so they have to be
-- changeable without a shell -- a machine whose shell will not start is exactly
-- when someone needs to change them.
--
-- The shape follows the firmware of a real PC: a short window at power on ("Press
-- DEL to enter SETUP"), then the boot carries on. Missing the window is not an
-- error; it is the normal case.
--
-- THE PASSWORD IS SEPARATE FROM THE LOGIN PASSWORD, ON PURPOSE
-- It is stored in /etc/bios.conf and checked here, not through lib/perm.lua. Two
-- reasons, and the second is the load bearing one:
--   * a forgotten login password and a forgotten BIOS password are different
--     problems, and reusing one for the other makes each one worse;
--   * this module runs BEFORE the shell and before /etc/passwd is necessarily
--     readable in a form the user database can parse, so depending on the login
--     database here would make the setup screen unavailable exactly when the
--     machine is broken.
--
-- THE THREE OPTIONS, AND WHY THEY ARE THESE
--   password     ask for the password before booting at all. Off by default: a
--                machine that will not boot without a password is a machine that
--                cannot be recovered by reinstalling the shell, which is a serious
--                thing to turn on by accident.
--   bootguard    mirrors "set -o bootguard" (see lib/protect.lua). It is here so
--                the rule can be changed when the shell cannot start.
--   noexit       mirrors "set -o noexit". Same reason.
--
-- Both mirrors write through lib/protect.lua, so there is one authority for each
-- rule and this screen cannot drift from what the shell reports.

local bios = {}

local CONF = "/etc/bios.conf"

-- The window is short on purpose. Three seconds is long enough to press a key and
-- short enough that a machine rebooted in a loop is not painful to watch.
bios.WINDOW = 3

-- ============================================================
-- boot order: which startup scripts the ROM is allowed to run
-- ============================================================
--
-- THE ROM HAS ITS OWN BOOT SETTINGS, AND ONE OF THEM IS A HIJACK
-- --------------------------------------------------------------
-- CraftOS reads /.settings when a computer starts (rom/apis/settings.lua), and
-- rom/startup.lua consults two of those keys BEFORE running anything of ours:
--
--   shell.allow_startup       run a startup script in the computer's own root
--   shell.allow_disk_startup  run a startup script found on an attached disk
--
-- Both default to TRUE. The second one is the dangerous one, and the ROM code is
-- explicit about it (rom/startup.lua):
--
--     if settings.get("shell.allow_disk_startup") then
--         for _, sName in pairs(peripheral.getNames()) do
--             if disk.isPresent(sName) and disk.hasData(sName) then
--                 local startups = findStartups(disk.getMountPath(sName))
--                 if startups then
--                     tUserStartups = startups   -- REPLACES what was found above
--                     break
--                 end
--             end
--         end
--     end
--
-- So a disk inserted at boot with a file called "startup" does not merely run
-- ALONGSIDE the machine's own startup -- it REPLACES it. The shell never starts,
-- and nothing in this repository ever gets to run, which is why lib/protect.lua
-- (which runs inside startup.lua) cannot defend against it. The defence has to be
-- the ROM's own switch, turned off before the next boot.
--
-- WHY THIS IS A BIOS SETTING AND NOT A SHELL ONE
-- It has to be in force before the shell exists, and it has to survive the shell
-- not starting -- which is exactly the state a hijack leaves the machine in. The
-- settings file is /.settings, and only the ROM reads it, so the BIOS writes it
-- directly.
--
-- WHY "ALLOW DISK STARTUP" IS OFF BY DEFAULT HERE
-- The ROM's default is on for a normal computer. This machine's is off, and the
-- reason is that a disk is something handed over: the whole point of protecting
-- boot files is that a medium can carry a file that lands on a boot path, and a
-- startup script on a disk is that hazard at its most direct. An operator who
-- wants the ROM's behaviour can turn it on here. The two defaults disagreeing is
-- deliberate, and it is stated in the menu.
--
-- THE FILE FORMAT IS NOT NEGOTIABLE, AND IT COST A WRONG FIRST ATTEMPT
-- /.settings must be EXACTLY a table literal. textutils.unserialize is what both
-- the host bios.lua and settings.load() use, and it does NOT accept a leading
-- "return" or any comment: fed `return { ... }` it returns nil, the load reports
-- failure, and every key silently keeps its ROM default. A file that "looks
-- right" and does nothing is the worst outcome here, because the machine appears
-- protected. So this module writes exactly what textutils.serialize produces --
-- the same shape the ROM's own settings.save() writes -- and the repository's
-- /.settings is a bare table literal with no comment in it. The explanation lives
-- here and in the README, never in the file itself.
--
-- Every write goes to the ABSOLUTE / path, never to the bare ".settings" the ROM's
-- save() defaults to: that default is relative to the current directory, so a
-- caller whose cwd is not / would write the settings somewhere the ROM never reads.
local SETTINGS_FILE = "/.settings"

-- ============================================================
-- the ROM's settings, and the trap of enforcing them
-- ============================================================
--
-- The ROM's "set" command reads and writes these keys (rom/programs/set.lua over
-- rom/apis/settings.lua), and this screen offers the ones that decide how the
-- machine behaves before the shell exists.
--
-- TWO DIFFERENT THINGS, AND CONFLATING THEM WAS A REAL BUG
-- -------------------------------------------------------
--   policy   what this MACHINE insists on. It is a property of the installation,
--            so it lives in this file, not in /.settings: a value that lives only
--            in /.settings can be edited by anyone who can write a file.
--   choice   what the OPERATOR picked on the setup screen. It is recorded in
--            /etc/bios.conf, which is the machine's own configuration.
--
-- The first version of this had one field, `want`, doing both jobs, and the
-- consequence was that a menu entry was a lie: turning "boot from a disk" ON
-- appeared to work, and the next boot's enforcement silently set it back to the
-- OFF policy. Enforcement must restore POLICY, and POLICY must be what the
-- operator chose -- otherwise the screen does not do what it says.
--
-- So `enforce` now writes, for each key, the value from /etc/bios.conf when the
-- operator has recorded one, and the shipped policy otherwise. A key the operator
-- never touched keeps the installation's default; a key they changed keeps their
-- change across reboots; and deleting /.settings is still repaired from the same
-- source of truth.
local ROM_KEYS = {
    { key = "shell.allow_disk_startup", label = "Boot from a disk's startup",
      -- The installation's policy: OFF. The ROM's own default is on, and this
      -- deliberately disagrees with it, because a disk is something handed over
      -- and a startup on one REPLACES the machine's own (see the note above).
      policy = false,
      why = "a disk's startup REPLACES the machine's own, so the shell never runs" },
    { key = "shell.allow_startup", label = "Run this machine's startup",
      policy = true,
      why = "the machine's own startup; without it nothing of ours runs at all" },
}

-- The keys this screen can change, by name, for the lookup below.
local ROM_BY_KEY = {}
for _, item in ipairs(ROM_KEYS) do ROM_BY_KEY[item.key] = item end

-- Read /.settings. It is a serialised Lua table written by the ROM's settings
-- API, so textutils.unserialize is the right reader -- and a file that will not
-- parse is treated as absent rather than as an error, because a damaged settings
-- file must not make the setup screen unusable.
local function read_settings()
    if not fs.exists(SETTINGS_FILE) then return {} end
    local f = fs.open(SETTINGS_FILE, "r")
    if not f then return {} end
    local text = f.readAll()
    f.close()
    local ok, data = pcall(textutils.unserialize, text)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

local function write_settings(data)
    local f = fs.open(SETTINGS_FILE, "w")
    if not f then return false, "cannot write " .. SETTINGS_FILE end
    f.write(textutils.serialize(data))
    f.close()
    return true
end

-- What the ROM would actually do, which is not the same as what is in the file:
-- an absent key falls back to the ROM's own default, and for
-- shell.allow_disk_startup that default is TRUE on an ordinary computer. Reporting
-- the file's contents would show "not set" for a machine that is in fact open.
--
-- The ROM's definition is `default = commands == nil` (CraftOS-PC's bios.lua), so
-- a Command Computer defaults it OFF. The global `commands` table is what tells
-- them apart, and it is checked here for the same reason the ROM checks it: the
-- answer depends on the machine.
function bios.rom_default(key)
    if key == "shell.allow_startup" then return true end
    if key == "shell.allow_disk_startup" then
        return commands == nil
    end
    return nil
end

function bios.rom_setting(key)
    local data = read_settings()
    if data[key] ~= nil then return data[key] end
    return bios.rom_default(key)
end

-- Forward declaration, and it is load bearing: read_conf is defined below with the
-- rest of /etc/bios.conf, but the ROM-key helpers above it need to read the
-- operator's recorded choice. A local used before its declaration is nil, not a
-- compile error -- lib/pkg.lua carries the same note for the same reason.
local read_conf

-- The operator's recorded choice for a key, or nil when they never made one.
local function recorded_choice(key)
    local conf = read_conf()
    return conf.rom and conf.rom[key] or nil
end

-- What this machine insists a key be. The operator's choice wins when there is
-- one; otherwise the installation's policy. This is the single source of truth
-- that both enforce_rom_settings() and the menu report.
function bios.wanted_rom_setting(key)
    local chosen = recorded_choice(key)
    if chosen ~= nil then return chosen end
    local item = ROM_BY_KEY[key]
    if item then return item.policy end
    return bios.rom_default(key)
end

-- Turn a ROM setting on or off. This records the CHOICE (so the next boot keeps
-- it) and writes /.settings (so the ROM sees it now).
function bios.set_rom_setting(key, on)
    local want = on and true or false
    local okc, err = bios.set_rom_choice(key, want)
    if not okc then return false, err end
    local data = read_settings()
    data[key] = want
    return write_settings(data)
end

-- Put every ROM key this screen owns into the state the machine wants. Called at
-- boot, before the shell: a machine whose settings were changed elsewhere (or
-- that has none yet) is brought back to the wanted state, so "boot from a disk"
-- cannot be re-enabled by editing the file or by deleting it -- while a choice
-- the operator made on the setup screen is honoured rather than overwritten.
--
-- Returns the list of keys it changed, so the boot can say what it did.
function bios.enforce_rom_settings()
    local changed = {}
    local data = read_settings()
    local dirty = false
    for _, item in ipairs(ROM_KEYS) do
        local want = bios.wanted_rom_setting(item.key)
        if want ~= nil and data[item.key] ~= want then
            data[item.key] = want
            changed[#changed + 1] = item.key
            dirty = true
        end
    end
    if dirty then write_settings(data) end
    return changed
end

-- The hash is the same shape lib/perm.lua uses, so the two are recognisably the
-- same idea.
--
-- It used to pcall-require lib/crypto.lua with an arithmetic fallback, which had
-- the same defect perm.lua had: crypto lives in the modules half (the removable
-- medium) and this file lives in the base half (the computer), so the BIOS
-- password hash changed when the medium was removed and a password set with the
-- medium in place stopped verifying without it. lib/sha256.lua is in the base
-- half, so requiring it here makes the hash depend on the password and nothing
-- else. It is already loaded by perm.lua, so this costs nothing.
local bios_sha256 = require("sha256")

local function hash_password(pwd)
    return bios_sha256.hex("cc-bios:" .. tostring(pwd))
end

-- The recorded choice for a ROM key is a line "rom.<key>=<0|1>", e.g.
-- "rom.shell.allow_disk_startup=1". The prefix keeps the machine's own settings
-- apart from the ROM's keys, which contain dots of their own.
local ROM_CHOICE_PREFIX = "rom."

read_conf = function()
    local out = { password = nil, ask = false, rom = {} }
    if not fs.exists(CONF) then return out end
    local f = fs.open(CONF, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_%.]+)%s*=%s*(.-)%s*$")
            if k == "password" and v ~= "" then out.password = v end
            if k == "ask_password" and v ~= "" then
                out.ask = not (v == "0" or v == "off" or v == "no" or v == "false")
            end
            if k and k:sub(1, #ROM_CHOICE_PREFIX) == ROM_CHOICE_PREFIX and v ~= "" then
                out.rom[k:sub(#ROM_CHOICE_PREFIX + 1)] =
                    not (v == "0" or v == "off" or v == "no" or v == "false")
            end
        end
    end
    f.close()
    return out
end

local function write_conf(conf)
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local lines = {
        "# /etc/bios.conf - the setup screen of this machine",
        "#",
        "# Written by the BIOS setup screen (press DEL for three seconds at power",
        "# on) and by \"bios\" inside the shell. The password here is SEPARATE from",
        "# a login password on purpose: it is checked before the shell starts, so",
        "# it cannot depend on the user database the shell reads.",
        "#",
        "# ask_password=1 asks for the password before booting at all. Off unless",
        "# it is set: a machine that will not boot without a password is one that",
        "# cannot be recovered by reinstalling the shell.",
        "#",
        "# rom.<key>=0|1 records the CHOICE made for one of the ROM's own settings",
        "# (the ones CraftOS's \"set\" command writes to /.settings). The choice is",
        "# kept here, not in /.settings, because /.settings is rewritten at every",
        "# boot from this file: a value that lived only there could be edited away",
        "# by anyone who can write a file. A key with no line here keeps the value",
        "# the installation ships.",
    }
    if conf.password then
        lines[#lines + 1] = "password=" .. conf.password
    end
    if conf.ask then lines[#lines + 1] = "ask_password=1" end
    -- Sorted so the file is stable between two writes of the same state.
    local keys = {}
    for key in pairs(conf.rom or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        lines[#lines + 1] = ROM_CHOICE_PREFIX .. key .. "=" ..
            (conf.rom[key] and "1" or "0")
    end
    local f = fs.open(CONF, "w")
    if not f then return false, "cannot write " .. CONF end
    f.write(table.concat(lines, "\n") .. "\n")
    f.close()
    return true
end

function bios.has_password()
    return read_conf().password ~= nil
end

function bios.ask_at_boot()
    return read_conf().ask
end

function bios.check_password(pwd)
    local conf = read_conf()
    if not conf.password then return true end
    return conf.password == hash_password(pwd)
end

function bios.set_password(pwd)
    local conf = read_conf()
    if pwd == nil or pwd == "" then
        conf.password = nil
    else
        conf.password = hash_password(pwd)
    end
    return write_conf(conf)
end

function bios.set_ask(on)
    local conf = read_conf()
    conf.ask = on and true or false
    return write_conf(conf)
end

-- Record the operator's choice for a ROM key, so the next boot's enforcement
-- keeps it instead of restoring the installation's policy. Passing nil clears the
-- choice, which puts the key back on the policy.
function bios.set_rom_choice(key, on)
    local conf = read_conf()
    conf.rom = conf.rom or {}
    if on == nil then
        conf.rom[key] = nil
    else
        conf.rom[key] = on and true or false
    end
    return write_conf(conf)
end

-- The choice recorded for a key, or nil when the operator never made one. Exposed
-- so the menu can say whether a value is the installation's or the operator's.
function bios.rom_choice(key)
    return recorded_choice(key)
end

-- ============================================================
-- every CraftOS setting, not only the boot ones
-- ============================================================
--
-- The screen above owns the two keys that decide how the machine starts. The rest
-- of the ROM's settings (autocomplete, the editor's default extension, the
-- motd, ...) belong to CraftOS's own "set" command, and this project must not
-- pretend otherwise: they are not machine policy and nothing here enforces them.
--
-- What the BIOS screen CAN usefully add is a way to reach them when the shell is
-- not available -- a machine whose shell will not start is exactly when someone
-- needs to turn autocomplete off, or check what motd.path says. So the editor
-- below lists and changes ANY setting the ROM knows, through the same
-- settings API the "set" command uses, and writes /.settings the same way.
--
-- A setting changed here is NOT recorded in /etc/bios.conf and is NOT enforced:
-- it is the ROM's setting, and the ROM's own command is its editor. Only the keys
-- in ROM_KEYS are policy, and the difference is stated in the screen.

-- Every setting the ROM knows, sorted, as { name, value, type, default, is_policy }.
function bios.list_rom_settings()
    local out = {}
    local names = {}
    if type(settings) == "table" and settings.getNames then
        local ok, list = pcall(settings.getNames)
        if ok and type(list) == "table" then names = list end
    end
    if #names == 0 then
        -- No settings API (a stripped ROM, or the test stub without it): fall
        -- back to the keys this module already knows, so the screen still works.
        for _, item in ipairs(ROM_KEYS) do names[#names + 1] = item.key end
        table.sort(names)
    end
    for _, name in ipairs(names) do
        local value, stype, sdefault = nil, nil, nil
        if type(settings) == "table" then
            if settings.get then
                local ok, v = pcall(settings.get, name)
                if ok then value = v end
            end
            if settings.getDetails then
                local ok, d = pcall(settings.getDetails, name)
                if ok and type(d) == "table" then
                    stype = d.type
                    sdefault = d.default
                end
            end
        end
        out[#out + 1] = {
            name = name,
            value = value,
            type = stype,
            default = sdefault,
            -- Whether this key is one the machine enforces at boot.
            policy = ROM_BY_KEY[name] ~= nil,
        }
    end
    return out
end

-- Change any setting the ROM knows, the way the "set" command does: the value is
-- coerced by the declared type, and an empty entry unsets the key (so the ROM's
-- own default applies again).
--
-- Returns true, or false plus the reason.
function bios.set_any_rom_setting(name, value, stype)
    if type(settings) ~= "table" or not settings.set then
        return false, "no settings API on this machine"
    end
    -- A policy key goes through the choice/policy path, so the next boot keeps it
    -- rather than restoring the installation's value.
    if ROM_BY_KEY[name] then
        local on
        if value == nil or value == "" then
            on = nil
        else
            on = (value == true or value == "true" or value == 1)
        end
        local okc, err = bios.set_rom_choice(name, on)
        if not okc then return false, err end
        if on == nil then
            settings.unset(name)
        else
            settings.set(name, on)
        end
        settings.save(SETTINGS_FILE)
        return true
    end

    if value == nil or value == "" then
        settings.unset(name)
        settings.save(SETTINGS_FILE)
        return true
    end
    -- Coerce by the declared type, exactly as rom/programs/set.lua does: a
    -- boolean setting given "false" must become the boolean, not the string.
    local coerced = value
    if stype == "boolean" then
        if value == true or value == "true" then coerced = true
        elseif value == false or value == "false" then coerced = false
        else return false, "not a boolean: " .. tostring(value) end
    elseif stype == "number" then
        local n = tonumber(value)
        if n == nil then return false, "not a number: " .. tostring(value) end
        coerced = n
    elseif stype == "string" then
        coerced = tostring(value)
    end
    settings.set(name, coerced)
    settings.save(SETTINGS_FILE)
    return true
end

-- Put a key back to the value the ROM itself declares, by unsetting it.
function bios.reset_rom_setting(name)
    if type(settings) ~= "table" then return false, "no settings API" end
    if ROM_BY_KEY[name] then
        bios.set_rom_choice(name, nil)
    end
    if settings.unset then settings.unset(name) end
    if settings.save then settings.save(SETTINGS_FILE) end
    return true
end

-- ------------------------------------------------------------------ the screen
--
-- The rendering is deliberately plain: term writes with colours, no window API,
-- because this runs before anything else is loaded and must not depend on a
-- module that might be the thing that is broken.

local function colors_ok()
    return type(colors) == "table"
end

local function paint(colour)
    if colors_ok() and term.setTextColor then term.setTextColor(colour) end
end

local function clear()
    term.clear()
    term.setCursorPos(1, 1)
end

local function banner(title)
    clear()
    paint(colors_ok() and colors.lightBlue or nil)
    print("=========================================")
    print("  " .. title)
    print("=========================================")
    paint(colors_ok() and colors.white or nil)
    print("")
end

-- Read one key with no timeout: used by the password prompt, where waiting
-- forever is the right behaviour.
local function read_key()
    local ev = { os.pullEventRaw() }
    return ev[1], ev[2]
end

-- Read a line with the characters echoed as '*'. Ctrl+C is ignored rather than
-- treated as a cancel: this runs before the shell, and a half typed password
-- should not need a reboot to clear.
local function read_password(prompt)
    paint(colors_ok() and colors.lightGray or nil)
    write(prompt)
    paint(colors_ok() and colors.white or nil)
    -- A visible cursor: the same reason the shell asks for one (a prompt with no
    -- cursor reads as a screen that has stopped taking keys).
    if term.setCursorBlink then term.setCursorBlink(true) end
    local buf = {}
    while true do
        local kind, a = read_key()
        if kind == "char" then
            buf[#buf + 1] = a
            write("*")
        elseif kind == "key" then
            if a == keys.enter then
                print("")
                if term.setCursorBlink then term.setCursorBlink(false) end
                return table.concat(buf)
            elseif a == keys.backspace then
                if #buf > 0 then
                    table.remove(buf)
                    write("\b \b")
                end
            end
        elseif kind == "terminate" then
            -- ignore Ctrl+T
        end
    end
end

-- The three second window. Returns true when DEL was pressed.
--
-- It uses os.startTimer and os.pullEventRaw: the timer gives the deadline and any
-- other event is looked at and ignored. This is the one place a bare event loop
-- is correct -- there is no shell yet, so there is nothing to yield to.
function bios.prompt_del()
    paint(colors_ok() and colors.lightGray or nil)
    write("Press DEL to enter SETUP")
    paint(colors_ok() and colors.white or nil)
    local timer = os.startTimer(bios.WINDOW)
    while true do
        local ev = { os.pullEventRaw() }
        local kind, a = ev[1], ev[2]
        if kind == "timer" and a == timer then
            print("")
            return false
        elseif kind == "key" then
            -- keys.delete is DEL (211 on a PC keyboard). The backspace key is
            -- accepted as well: on the CraftOS console it is what a user without a
            -- full keyboard reaches for, and refusing it would make the screen
            -- unreachable on exactly the hardware that needs it most.
            if a == keys.delete or a == keys.backspace then
                print("")
                return true
            end
        elseif kind == "terminate" then
            -- ignore Ctrl+T
        elseif kind == "shutdown" or kind == "reboot" then
            return false
        end
    end
end

-- LEAVING A SCREEN USES "q", NOT ESCAPE.
--
-- Escape is not a key this machine can receive. Minecraft takes it for its own
-- menu and never delivers it to the computer -- and the ROM's own key table has no
-- escape entry at all (rom/apis/keys.lua ends at "delete"), so the old comparisons
-- against an "escape" key compared a number with nil and could never be true.
-- CraftOS-PC does forward the key as code 1, which is why this looked
-- fine on the emulator: the BIOS screens were leaveable there and unreachable
-- here. Firstboot already moved its skip key to Ctrl+T for the same reason; these
-- screens leave on a plain letter instead.
--
-- Matched on the CHARACTER event rather than on key code 16, because the character
-- is consumed by the match: the key event that came with it was already passed
-- over by the loop, so leaving this way cannot leave a stray "q" to fall through
-- into the shell prompt the boot is about to draw.
local function is_leave(kind, a)
    return kind == "char" and tostring(a):lower() == "q"
end

-- One menu entry: a line of text plus the action that runs when it is chosen.
-- Kept as data so the loop below has no per-entry branch.
local function menu(entries)
    local selected = 1
    while true do
        banner("BIOS SETUP")
        for i, e in ipairs(entries) do
            if i == selected then
                paint(colors_ok() and colors.black or nil)
                if colors_ok() and term.setBackgroundColor then
                    term.setBackgroundColor(colors.white)
                end
                print("  > " .. e.label)
                paint(colors_ok() and colors.white or nil)
                if colors_ok() and term.setBackgroundColor then
                    term.setBackgroundColor(colors.black)
                end
            else
                print("    " .. e.label)
            end
        end
        print("")
        paint(colors_ok() and colors.lightGray or nil)
        print("  Up/Down move, Enter selects, Q leaves")
        paint(colors_ok() and colors.white or nil)

        local kind, a = read_key()
        if kind == "key" then
            if a == keys.up then
                selected = selected - 1
                if selected < 1 then selected = #entries end
            elseif a == keys.down then
                selected = selected + 1
                if selected > #entries then selected = 1 end
            elseif a == keys.enter then
                local done = entries[selected].run()
                if done == "leave" then return end
            end
        elseif is_leave(kind, a) then
            return
        end
    end
end

local function yes_no(question, current)
    paint(colors_ok() and colors.lightGray or nil)
    write(question .. " [" .. (current and "Y/n" or "y/N") .. "] ")
    paint(colors_ok() and colors.white or nil)
    while true do
        local kind, a = read_key()
        if kind == "key" then
            if a == keys.enter then print("") return current end
        elseif kind == "char" then
            local c = tostring(a):lower()
            if c == "y" then print("") return true end
            if c == "n" then print("") return false end
            -- "q" keeps the value as it is, the same answer as a bare Enter: the
            -- operator asked to get out of the question, not to answer it.
            if c == "q" then print("") return current end
        end
    end
end

-- Read a line with the characters echoed, for a setting's value. Enter accepts,
-- Ctrl+T cancels (the setup wizard's cancel key, and the only cancel that is not
-- also a character this field may need), and an empty line means "unset" (the
-- ROM's own default again).
-- Returns (text, cancelled).
local function read_text(prompt, initial)
    paint(colors_ok() and colors.lightGray or nil)
    write(prompt)
    paint(colors_ok() and colors.white or nil)
    -- The visible cursor, for the same reason the shell asks for one.
    if term.setCursorBlink then term.setCursorBlink(true) end
    local buf = {}
    for i = 1, #tostring(initial or "") do buf[i] = tostring(initial):sub(i, i) end
    if #buf > 0 then write(table.concat(buf)) end
    while true do
        local kind, a = read_key()
        if kind == "key" then
            if a == keys.enter then
                print("")
                if term.setCursorBlink then term.setCursorBlink(false) end
                return table.concat(buf), false
            elseif a == keys.backspace then
                if #buf > 0 then
                    table.remove(buf)
                    write("\b \b")
                end
            end
        elseif kind == "char" then
            buf[#buf + 1] = a
            write(a)
        elseif kind == "terminate" then
            print("")
            if term.setCursorBlink then term.setCursorBlink(false) end
            return nil, true
        end
    end
end

-- Render a setting's value so a reader can tell "false" from "not set".
local function show_value(v)
    if v == nil then return "<unset>" end
    return textutils.serialize(v)
end

-- The browser over every setting the ROM knows. This is the part of the screen
-- that stands in for CraftOS's own "set" command when the shell is not available.
--
-- Only the keys in ROM_KEYS are policy (enforced at every boot, recorded in
-- /etc/bios.conf). The rest are the ROM's settings, changed here through the same
-- settings API the "set" command uses and not enforced by anything: the screen
-- says which is which, because a reader who cannot tell them apart would expect a
-- setting to survive a boot that will not touch it.
local function all_settings_menu()
    local index = 1
    while true do
        local items = bios.list_rom_settings()
        if #items == 0 then
            banner("CRAFTOS SETTINGS")
            print("  This machine's ROM exposes no settings.")
            os.sleep(1.5)
            return
        end
        if index > #items then index = #items end
        if index < 1 then index = 1 end

        -- Only a window of the list is drawn: the CraftOS screen is 19 rows and a
        -- machine may have many settings, so the list scrolls with the cursor.
        local PAGE = 12
        local first = index - math.floor(PAGE / 2)
        if first < 1 then first = 1 end
        if first + PAGE - 1 > #items then first = #items - PAGE + 1 end
        if first < 1 then first = 1 end

        banner("CRAFTOS SETTINGS")
        if first > 1 then print("   ... " .. (first - 1) .. " above") else print("") end
        for i = first, math.min(first + PAGE - 1, #items) do
            local item = items[i]
            local mark = item.policy and "*" or " "
            local line = string.format("%s %-34s %s", mark, item.name,
                                       show_value(item.value))
            if i == index then
                paint(colors_ok() and colors.black or nil)
                if colors_ok() and term.setBackgroundColor then
                    term.setBackgroundColor(colors.white)
                end
                print("> " .. line)
                paint(colors_ok() and colors.white or nil)
                if colors_ok() and term.setBackgroundColor then
                    term.setBackgroundColor(colors.black)
                end
            else
                print("  " .. line)
            end
        end
        print("")
        paint(colors_ok() and colors.lightGray or nil)
        print("  * = enforced at every boot (recorded in /etc/bios.conf)")
        print("  Enter changes, R resets to the ROM default, Q leaves")
        paint(colors_ok() and colors.white or nil)

        local kind, a = read_key()
        if kind == "key" then
            if a == keys.up then index = index - 1
            elseif a == keys.down then index = index + 1
            elseif a == keys.r then
                local item = items[index]
                bios.reset_rom_setting(item.name)
            elseif a == keys.enter then
                local item = items[index]
                banner(item.name)
                print("  " .. tostring(item.description or "(no description)"))
                print("")
                print("  type:    " .. tostring(item.type or "?"))
                print("  default: " .. show_value(item.default))
                print("  now:     " .. show_value(item.value))
                if item.policy then
                    print("")
                    paint(colors_ok() and colors.yellow or nil)
                    print("  This key is ENFORCED at every boot from")
                    print("  /etc/bios.conf, so a change here is kept.")
                    paint(colors_ok() and colors.white or nil)
                end
                print("")
                print("  Enter accepts the value, Ctrl+T cancels the edit.")
                local text, cancelled = read_text("  new value (empty = unset): ",
                                                  item.value)
                if not cancelled then
                    local ok, err = bios.set_any_rom_setting(item.name, text, item.type)
                    if not ok then
                        print("")
                        paint(colors_ok() and colors.red or nil)
                        print("  " .. tostring(err))
                        paint(colors_ok() and colors.white or nil)
                        os.sleep(1.5)
                    end
                end
            end
        elseif is_leave(kind, a) then
            return
        end
    end
end

-- Ask for a password twice and store it. An empty entry clears it, which is how
-- a machine stops asking.
local function change_password()
    banner("BIOS PASSWORD")
    print("  The BIOS password is separate from a login password.")
    print("  It is checked before the shell starts, so it cannot depend")
    print("  on the user database the shell reads.")
    print("")
    print("  Leave it empty to remove the password.")
    print("")
    local first = read_password("New password:     ")
    if first == "" then
        local ok, err = bios.set_password(nil)
        print("")
        print(ok and "  Password removed." or ("  " .. tostring(err)))
        os.sleep(1)
        return
    end
    local again = read_password("Repeat password:  ")
    print("")
    if first ~= again then
        print("  The two entries differ; nothing was changed.")
        os.sleep(1.5)
        return
    end
    local ok, err = bios.set_password(first)
    print(ok and "  Password set." or ("  " .. tostring(err)))
    os.sleep(1)
end

-- Everything the setup screen can change. "set -o" reports the same rules from
-- inside the shell; both write through lib/protect.lua, so the two views cannot
-- disagree.
local function settings_menu()
    local protect = require("protect")
    menu({
        { label = "Boot from a disk's startup",
          run = function()
              -- The effective value: the operator's recorded choice when there is
              -- one, the installation's policy otherwise. Reporting the raw file
              -- would show the ROM's default on a machine that is in fact
              -- protected, and would show a value the next boot is about to
              -- replace -- which is what made this entry a lie the first time.
              local now = bios.wanted_rom_setting("shell.allow_disk_startup")
              local chosen = bios.rom_choice("shell.allow_disk_startup")
              local on = yes_no("Let an attached disk's startup REPLACE this " ..
                                "machine's own?", now)
              bios.set_rom_setting("shell.allow_disk_startup", on)
              print("")
              if on then
                  print("  WARNING: a disk inserted at boot will now run its own")
                  print("  startup INSTEAD of this machine's, so the shell will")
                  print("  not start. Turn this off to get the machine back.")
              else
                  print("  Saved. This choice is kept across reboots (it is")
                  print("  recorded in /etc/bios.conf, not in /.settings, which")
                  print("  is rewritten from it at every boot).")
              end
              if chosen == nil then
                  print("  (the installation's policy; change it again to make")
                  print("   the choice explicit)")
              end
              os.sleep(2)
          end },
        { label = "Run this machine's startup",
          run = function()
              local now = bios.wanted_rom_setting("shell.allow_startup")
              local on = yes_no("Run this machine's own startup?", now)
              bios.set_rom_setting("shell.allow_startup", on)
              print("")
              print("  Saved. WARNING: with this off, nothing of this installation")
              print("  runs at boot at all.")
              os.sleep(2)
          end },
        { label = "BIOS password",
          run = function() change_password() end },
        { label = "Ask password before boot",
          run = function()
              local on = yes_no("Ask for the password before booting?", bios.ask_at_boot())
              bios.set_ask(on)
          end },
        { label = "Protect boot files",
          run = function()
              local on = yes_no("Refuse to overwrite a boot file?", protect.enabled())
              protect.set_enabled(on)
          end },
        { label = "Allow leaving the shell",
          run = function()
              local on = yes_no("May the shell be left (exit)?", not protect.no_exit())
              protect.set_no_exit(not on)
          end },
        { label = "All CraftOS settings",
          run = function() all_settings_menu() end },
        { label = "Save and leave",
          run = function() return "leave" end },
    })
end

-- The whole screen: the window, the optional boot password, then the menu.
-- Returns true when the boot should carry on, false when the user asked for the
-- machine to stop here (the caller decides what that means).
--
-- opts.opts is unused for now but kept in the signature: the tests pass a table
-- so they can drive the screen without the three second wait.
function bios.run(opts)
    opts = opts or {}
    if not opts.skip_window then
        if not bios.prompt_del() then return true end
    end

    -- Entering setup is itself protected when a password is set: the settings are
    -- what an attacker would want, and the screen is reachable by anyone standing
    -- at the machine.
    if bios.has_password() then
        banner("BIOS PASSWORD REQUIRED")
        print("  Enter the BIOS password to open setup.")
        print("")
        local given = read_password("Password: ")
        if not bios.check_password(given) then
            print("")
            paint(colors_ok() and colors.red or nil)
            print("  Incorrect password.")
            paint(colors_ok() and colors.white or nil)
            os.sleep(1.5)
            return true
        end
    end

    settings_menu()
    return true
end

-- The gate the boot sequence calls before anything else. Returns true to carry
-- on. It is deliberately total: a failure inside the screen must not stop the
-- machine from booting, so the caller wraps it, and this function itself only
-- returns true when there is nothing to ask.
function bios.gate(opts)
    opts = opts or {}

    -- "reboot bios" asked for this screen. force_window skips the DEL prompt --
    -- the operator already said what they wanted, and making them beat a three
    -- second timer to get it would be a poor answer to a deliberate request.
    if opts.force_window then
        if bios.has_password() then
            return bios.run({ skip_window = true })
        end
        settings_menu()
        return true
    end

    if opts.skip_window then return true end

    -- The normal boot: a short window, and missing it is the common case.
    if not bios.ask_at_boot() then
        if not bios.prompt_del() then return true end
        if not bios.has_password() then
            settings_menu()
            return true
        end
        return bios.run({ skip_window = true })
    end

    -- ask_password is on: the password is required before the shell starts.
    banner("BIOS PASSWORD")
    print("  This machine asks for its BIOS password before booting.")
    print("")
    local given = read_password("Password: ")
    if bios.check_password(given) then return true end
    print("")
    paint(colors_ok() and colors.red or nil)
    print("  Incorrect password.")
    paint(colors_ok() and colors.white or nil)
    print("  Press DEL to try again, or any other key to carry on without")
    print("  the shell (the machine stays at this screen).")
    -- A wrong password does not hand the machine over. The loop re-asks, which is
    -- what a real firmware password does: the only ways on are the right password
    -- or a power cycle.
    while true do
        local kind, a = read_key()
        if kind == "key" and (a == keys.delete or a == keys.backspace) then
            return bios.gate({ skip_window = true })
        elseif kind == "key" or kind == "char" then
            return false
        end
    end
end

-- ============================================================
-- the one shot request written by "reboot bios"
-- ============================================================
--
-- The file is deliberately a MARKER, not state: its existence means "open setup on
-- the next boot", and startup.lua removes it before showing the screen. That makes
-- the request impossible to honour twice -- a machine left unattended does not come
-- up in setup after an unrelated reboot -- and it cannot be confused with the
-- password or the ROM choices, which are configuration rather than a command.
--
-- It lives in /var/lib, not /etc: it is a one shot instruction from a running
-- shell, not a rule about the machine. A machine that is powered off while the
-- request is pending simply boots normally next time, which is the safe reading.
local SETUP_REQUEST = "/var/lib/.bios_setup_requested"

-- Arm the request. Called by the reboot built-in before os.reboot().
function bios.arm_setup()
    if not fs.exists("/var/lib") then fs.makeDir("/var/lib") end
    local f = fs.open(SETUP_REQUEST, "w")
    if not f then return false, "cannot write " .. SETUP_REQUEST end
    f.write(tostring(os.epoch("utc")) .. "\n")
    f.write(tostring(os.getComputerID()) .. "\n")
    f.close()
    return true
end

-- Is the screen requested for this boot? The computer id is checked for the same
-- reason startup.lua checks it for its own flags: a data directory copied to
-- another machine must not make that machine open its setup screen.
function bios.setup_requested()
    if not fs.exists(SETUP_REQUEST) then return false end
    local f = fs.open(SETUP_REQUEST, "r")
    if not f then return false end
    local _ts = f.readLine()
    local cid = f.readLine()
    f.close()
    if cid and cid ~= "" and cid ~= tostring(os.getComputerID()) then
        return false
    end
    return true
end

-- Consume the request. startup.lua calls this before showing the screen, so the
-- request is honoured exactly once.
function bios.disarm_setup()
    if fs.exists(SETUP_REQUEST) then return fs.delete(SETUP_REQUEST) end
    return false
end

return bios
