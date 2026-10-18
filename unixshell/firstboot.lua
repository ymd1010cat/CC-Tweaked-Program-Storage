-- firstboot.lua - initial system setup
-- Prompts for: root password, primary user, computer name, network,
-- timezone, packages. Ctrl+T (the terminate event) skips the question that
-- is waiting; the words 'skip' and 'later' do the same where offered.

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

local perm   = require("perm")
local audit  = require("audit")
local policy = require("policy")
local tz     = require("time")

local marker = require("marker")

local NET_CONF    = "/etc/network.conf"
local TZ_CONF     = "/etc/timezone.conf"

if marker.done() then return end

policy.ensure_defaults()
tz.ensure_defaults()

-- ============================================================
-- Safe input
-- ============================================================

-- Ctrl+T, the terminate event, is the skip key of the wizard: the prompts
-- read raw events, so a terminate arrives here as a plain event instead of
-- killing the program. Escape has no meaning while the wizard is asking.
local function read_line()
    local buf = {}
    while true do
        local ev = { os.pullEventRaw() }
        local e = ev[1]
        if e == "terminate" then
            term.write("\n")
            return nil
        elseif e == "key" then
            local k = ev[2]
            if k == keys.enter then
                term.write("\n")
                return table.concat(buf)
            elseif k == keys.backspace then
                if #buf > 0 then
                    table.remove(buf)
                    term.write("\b \b")
                end
            end
        elseif e == "char" then
            table.insert(buf, ev[2])
            term.write(ev[2])
        elseif e == "paste" then
            table.insert(buf, ev[2])
            term.write(ev[2])
        elseif e == "shutdown" then
            return nil
        end
    end
end

local function read_password()
    local buf = {}
    while true do
        local ev = { os.pullEventRaw() }
        local e = ev[1]
        if e == "terminate" then
            term.write("\n")
            return nil
        elseif e == "key" then
            local k = ev[2]
            if k == keys.enter then
                term.write("\n")
                return table.concat(buf)
            elseif k == keys.backspace then
                if #buf > 0 then table.remove(buf) end
            end
        elseif e == "char" then
            table.insert(buf, ev[2])
        elseif e == "shutdown" then
            return nil
        end
    end
end

-- ============================================================
-- Screen helpers
-- ============================================================

local function header(title)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.lightBlue)
    print("=================================")
    print("  " .. title)
    print("=================================")
    term.setTextColor(colors.white)
    print("")
end

local function hint(text)
    term.setTextColor(colors.lightGray)
    print(text)
    term.setTextColor(colors.white)
end

local function error_line(text)
    term.setTextColor(colors.red)
    print(text)
    term.setTextColor(colors.white)
end

-- ============================================================
-- Step 1: root password
-- ============================================================

local function prompt_root_password()
    header("First Boot: Root password")
    hint("Root must have a password.")
    hint("Policy: " .. (policy.get("min_length") or 0) .. "+ chars")
    hint("Press Ctrl+T to cancel.")
    print("")

    while true do
        io.write("Root password: ")
        local p1 = read_password()
        if not p1 then return nil end

        local ok, reason = policy.check_password(p1)
        if not ok then
            error_line("Rejected: " .. reason)
        else
            io.write("Retype password: ")
            local p2 = read_password()
            if not p2 then return nil end
            if p1 == p2 then return p1 end
            error_line("Passwords do not match. Try again.")
        end
        print("")
    end
end

-- ============================================================
-- Step 2: primary username
-- ============================================================

local function prompt_username()
    header("First Boot: Administrator account")
    hint("Blacklist: " .. (policy.get("blacklist") or ""))
    hint("Leave blank for default name 'admin'.")
    hint("Press Ctrl+T to cancel.")
    print("")

    while true do
        io.write("Username [admin]: ")
        local name = read_line()
        if not name then return nil end
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then name = "admin" end

        local ok, reason = policy.check_username(name)
        if not ok then
            error_line("Rejected: " .. reason)
        elseif perm.user_exists(name) and name ~= "admin" then
            error_line("User already exists. Choose another.")
        else
            return name
        end
    end
end

-- ============================================================
-- Step 3: user password
-- ============================================================

local function prompt_user_password(username)
    header("First Boot: Password for " .. username)
    hint("Leave blank for no password.")
    hint("Press Ctrl+T to cancel.")
    print("")

    while true do
        io.write("Password (blank = none): ")
        local p1 = read_password()
        if not p1 then return nil end
        if #p1 == 0 then return "" end

        local ok, reason = policy.check_password(p1)
        if not ok then
            error_line("Rejected: " .. reason)
            print("")
        else
            io.write("Retype password: ")
            local p2 = read_password()
            if not p2 then return nil end
            if p1 == p2 then return p1 end
            error_line("Passwords do not match. Try again.")
            print("")
        end
    end
end

-- ============================================================
-- Step 4: computer name (label)
-- ============================================================

-- Labels are kept short on purpose: CraftOS shows them in terminal titles
-- and stores them inside the computer data file. The 32 character limit is
-- a policy of this wizard, not a documented API limit, so it lives in a
-- single constant that is easy to change.
local LABEL_MAX = 32
local LABEL_SKIP_WORD = "skip"

-- Returns the current label ("" when none is set), or nil when the API is
-- missing/failing, in which case the step cannot verify anything.
local function current_label()
    if type(os.getComputerLabel) ~= "function" then return nil end
    local ok, value = pcall(os.getComputerLabel)
    if not ok then return nil end
    if value == nil then return "" end
    return tostring(value)
end

-- Writes the label through the native API first, then through the rom
-- "label set" program. Returns true, method on success and false, reason
-- otherwise; the read-back decides success on both paths.
local function write_label(name)
    if type(os.getComputerLabel) ~= "function" then
        return false, "os.getComputerLabel is unavailable, cannot verify the label"
    end

    if type(os.setComputerLabel) == "function" then
        pcall(os.setComputerLabel, name)
        if current_label() == name then
            return true, "os.setComputerLabel"
        end
    end

    if type(shell) == "table" and type(shell.run) == "function" then
        -- shell.run joins its arguments and tokenises them again, so the
        -- name is quoted to survive as a single argument.
        pcall(shell.run, "label set \"" .. name .. "\"")
        if current_label() == name then
            return true, "label set"
        end
    end

    return false, "the label could not be read back after writing"
end

-- Returns a human readable reason, or nil when the name is acceptable.
local function label_problem(name)
    if #name > LABEL_MAX then
        return "too long (max " .. LABEL_MAX .. " characters)"
    end
    if name:find("%c") then
        return "control characters are not allowed"
    end
    if name:find("[\128-\255]") then
        return "only printable ASCII characters are supported"
    end
    if name:find('"', 1, true) then
        return "double quotes are not allowed"
    end
    return nil
end

-- Returns "set", "kept", "skipped" or "failed". The step never aborts the
-- wizard: a machine without a label can still finish the setup.
local function prompt_computer_label()
    header("First Boot: Computer name")
    hint("A label makes this computer easy to tell apart from others.")
    hint("Blank line keeps an existing label; if none is set the")
    hint("default name cc-<id> is used instead.")
    hint("Type 'skip' or press Ctrl+T to leave the label unchanged.")
    print("")

    while true do
        local before = current_label()
        if before == nil then
            error_line("Computer labels are not available on this system.")
            audit.log({
                actor = "firstboot",
                action = "label",
                target = "-",
                result = "failed",
                note = "os.getComputerLabel is unavailable",
            })
            print("")
            return "failed"
        end

        local prompt = "Computer name"
        if before ~= "" then prompt = prompt .. " [" .. before .. "]" end
        io.write(prompt .. ": ")

        local raw = read_line()
        if raw == nil then
            hint("Skipped: the label is unchanged.")
            print("")
            return "skipped"
        end

        local name = raw:gsub("^%s+", ""):gsub("%s+$", "")

        if name:lower() == LABEL_SKIP_WORD then
            hint("Skipped: the label is unchanged.")
            print("")
            return "skipped"
        end

        if name == "" then
            if before ~= "" then
                hint("Kept the current label: " .. before)
                audit.log({
                    actor = "firstboot",
                    action = "label",
                    target = before,
                    result = "skipped",
                    note = "kept the existing computer label",
                })
                print("")
                return "kept"
            end
            -- Same default as lib/sysinfo.lua and the ush "hostname" builtin,
            -- so an unnamed machine keeps reading the same name.
            name = "cc-" .. tostring(os.getComputerID())
        end

        local problem = label_problem(name)
        if problem then
            error_line("Rejected: " .. problem)
            print("")
        else
            local ok, how = write_label(name)
            if ok then
                print("Computer label set to \"" .. name .. "\" [" .. how .. "]")
                audit.log({
                    actor = "firstboot",
                    action = "label",
                    target = name,
                    result = "granted",
                    note = "computer label set via " .. how,
                })
                print("")
                return "set"
            end
            error_line("Could not set the label: " .. tostring(how))
            hint("Setup continues without a label.")
            audit.log({
                actor = "firstboot",
                action = "label",
                target = name,
                result = "failed",
                note = tostring(how),
            })
            print("")
            return "failed"
        end
    end
end

-- ============================================================
-- Step 5: network
-- ============================================================

local function detect_modems()
    local sides = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            table.insert(sides, name)
        end
    end
    return sides
end

-- Leave the update server out: write an offline configuration instead of
-- nothing, so first boot still finishes and the package manager takes its
-- "no server" path. An update server is optional, and the settings the user
-- already provided (or an earlier run left behind) are kept.
local function skip_network_config(message)
    print("")
    print(message or "Skipping the update server configuration.")
    print("Offline mode will be used: the shell works, no server is contacted.")
    print("Configure one later in " .. NET_CONF .. " or /etc/pkg.conf:")
    print("  server_id=<pc id> and offline=false, then run 'pkg update'")

    local modem_side, channel, key = "back", "pkg-repo", "mysecretpassword"
    local sides = detect_modems()
    if #sides > 0 then modem_side = sides[1] end
    if fs.exists(NET_CONF) then
        local prev = fs.open(NET_CONF, "r")
        if prev then
            while true do
                local line = prev.readLine()
                if line == nil then break end
                local k, v = line:match("^([%w_]+)%s*=%s*(%S+)%s*$")
                if k == "modem_side" then modem_side = v
                elseif k == "channel" then channel = v
                elseif k == "key" then key = v end
            end
            prev.close()
        end
    end

    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = fs.open(NET_CONF, "w")
    f.write("modem_side=" .. modem_side .. "\n")
    f.write("server_id=0\n")
    f.write("offline=true\n")
    f.write("channel=" .. channel .. "\n")
    f.write("key=" .. key .. "\n")
    f.close()

    local p = fs.open("/etc/pkg.conf", "w")
    p.write("modem_side=" .. modem_side .. "\n")
    p.write("server_id=0\n")
    p.write("offline=true\n")
    p.write("channel=" .. channel .. "\n")
    p.write("key=" .. key .. "\n")
    p.close()

    print("Saved " .. NET_CONF .. ": no update server, offline=true.")
    return true
end

local function prompt_network()
    header("First Boot: Network")
    hint("Configure the modem side and package server.")
    hint("Leave fields blank to use the default in brackets.")
    hint("Type 'skip' or press Ctrl+T to run without an update server; it can")
    hint("be configured later.")
    print("")

    -- Modem side
    local sides = detect_modems()
    if #sides > 0 then
        hint("Detected modems: " .. table.concat(sides, ", "))
    else
        hint("No modem detected. You can still configure it now.")
    end

    local modem_side
    while true do
        io.write("Modem side [back, 'skip' = no server]: ")
        modem_side = read_line()
        if not modem_side then return skip_network_config() end
        modem_side = modem_side:gsub("^%s+", ""):gsub("%s+$", "")
        local word = modem_side:lower()
        if word == "skip" or word == "later" then
            return skip_network_config()
        end
        if modem_side == "" then modem_side = "back" end
        if peripheral.getType(modem_side) == "modem" then
            break
        end
        error_line("No modem on side '" .. modem_side .. "'. Try again.")
    end

    -- Server ID
    io.write("Package server ID [0 = no server, 'skip' = configure later]: ")
    local sid = read_line()
    if not sid then
        return skip_network_config("Skipping the update server configuration.")
    end
    sid = sid:gsub("^%s+", ""):gsub("%s+$", "")
    if sid == "" then sid = "0" end
    local sid_word = sid:lower()
    if sid_word == "skip" or sid_word == "later" then
        return skip_network_config("No update server: nothing was configured.")
    end

    local server_id = tonumber(sid) or 0

    -- Channel and key
    io.write("Channel [pkg-repo]: ")
    local channel = read_line()
    if not channel then
        return skip_network_config("Skipping the update server configuration.")
    end
    if channel == "" then channel = "pkg-repo" end

    io.write("Encryption key [mysecretpassword]: ")
    local key = read_line()
    if not key then
        return skip_network_config("Skipping the update server configuration.")
    end
    if key == "" then key = "mysecretpassword" end

    -- Offline mode: preserved from an earlier run, and switched on
    -- automatically when the user picks server_id 0 (no licence server).
    local offline_value = "false"
    if fs.exists(NET_CONF) then
        local prev = fs.open(NET_CONF, "r")
        if prev then
            while true do
                local line = prev.readLine()
                if line == nil then break end
                local value = line:match("^%s*offline%s*=%s*(%S+)%s*$")
                if value then offline_value = value end
            end
            prev.close()
        end
    end
    if server_id == 0 then
        offline_value = "true"
        print("No licence server: offline mode will be used.")
    elseif offline_value == "true" or offline_value == "1" then
        print("Note: offline=true is kept in " .. NET_CONF ..
              "; set it to false to use licence server " .. server_id .. ".")
    end

    -- Write /etc/network.conf
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = fs.open(NET_CONF, "w")
    f.write("modem_side=" .. modem_side .. "\n")
    f.write("server_id=" .. server_id .. "\n")
    f.write("offline=" .. offline_value .. "\n")
    f.write("channel=" .. channel .. "\n")
    f.write("key=" .. key .. "\n")
    f.close()

    -- Also write /etc/pkg.conf for backwards compatibility
    local p = fs.open("/etc/pkg.conf", "w")
    p.write("modem_side=" .. modem_side .. "\n")
    p.write("server_id=" .. server_id .. "\n")
    p.write("channel=" .. channel .. "\n")
    p.write("key=" .. key .. "\n")
    p.close()

    return true
end

-- ============================================================
-- Step 6: timezone
-- ============================================================

local function prompt_timezone()
    header("First Boot: Timezone")
    hint("Enter UTC offset in hours, e.g. 8 or -5 or 5.5.")
    hint("Press Ctrl+T to use UTC (offset 0).")
    print("")

    io.write("UTC offset [0]: ")
    local off = read_line()
    if off == nil then return end
    off = off:gsub("^%s+", ""):gsub("%s+$", "")
    if off == "" then off = "0" end

    local offset = tonumber(off)
    if not offset then offset = 0 end

    io.write("Label [UTC]: ")
    local label = read_line()
    if label == nil then return end
    if label == "" then label = "UTC" end

    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = fs.open(TZ_CONF, "w")
    f.write("# Timezone configuration\n")
    f.write("offset=" .. offset .. "\n")
    f.write("label=" .. label .. "\n")
    f.close()

    tz.reload()
end

-- ============================================================
-- Step 7: import packages
-- ============================================================

local function prompt_packages()
    header("First Boot: Package import")
    hint("Optionally install packages now.")
    hint("Enter package names separated by spaces.")
    hint("Press Ctrl+T or blank line to skip.")
    print("")

    io.write("Packages: ")
    local line = read_line()
    if line == nil then return end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return end

    local ok, pkg = pcall(require, "pkg")
    if not ok then
        error_line("pkg module unavailable. Skipping.")
        return
    end

    print("")
    local ready, why = pkg.server_ready()
    if not ready then
        -- No update server is not a failure here: say so, say how to add one
        -- later, and leave the rest of the setup alone.
        error_line("No update server: " .. tostring(why))
        hint(pkg.setup_hint())
        hint("Skipping the package import. Nothing else is affected.")
        return
    end
    print("Updating package index...")
    local uok, umsg = pkg.update()
    if not uok then
        error_line("Failed to update: " .. tostring(umsg))
        hint("You can retry later with 'pkg update'.")
        return
    end
    print("Index: " .. umsg)
    print("")

    for name in line:gmatch("%S+") do
        io.write("Installing " .. name .. "... ")
        local iok, imsg = pkg.install(name)
        if iok then
            print("ok")
        else
            print("FAILED: " .. tostring(imsg))
        end
    end
end

-- ============================================================
-- Apply
-- ============================================================

local function apply(username, root_pwd, user_pwd)
    -- Clean up stock accounts
    if perm.user_exists("guest") then perm.del_user("guest") end
    if username ~= "admin" and perm.user_exists("admin") then
        perm.del_user("admin")
    end

    perm.set_password("root", root_pwd)

    if perm.user_exists(username) then
        perm.set_password(username, user_pwd)
    else
        local ok, err = perm.add_user(username, {
            level = 1,
            groups = username,
            password = user_pwd,
        })
        if not ok then return false, err end
    end
    perm.add_sudoer(username)
    perm.set_current_user(username)

    -- THE SETUP MARKER. Writing it is what tells startup (and the next boot)
    -- that this machine has been set up. There is no licence server any more
    -- (2026-10-17): the marker says which computer was set up, nothing more.
    marker.write({ computerId = tostring(os.getComputerID()) })
    print("")
    print("Setup complete: this machine is marked as set up.")

    audit.log({
        actor = "firstboot",
        action = "setup",
        target = username,
        result = "granted",
        note = "initial configuration complete",
    })
    return true
end

-- ============================================================
-- Main
-- ============================================================

local root_pwd = prompt_root_password()
if not root_pwd then return end

local username = prompt_username()
if not username then return end

local user_pwd = prompt_user_password(username)
if user_pwd == nil then return end

-- Computer name is optional; 'skip' or Ctrl+T keeps the current label, and
-- a failure here never aborts the setup
prompt_computer_label()

-- Network is optional; Ctrl+T skips without aborting the whole setup
prompt_network()

-- Timezone is also optional
prompt_timezone()

-- Apply user/root configuration first
header("Applying configuration")
print("Please wait...")

local ok, err = apply(username, root_pwd, user_pwd)
if not ok then
    error_line("Setup failed: " .. tostring(err))
    print("Press any key to retry...")
    os.pullEventRaw()
    return
end

print("")
term.setTextColor(colors.lime)
print("User configuration complete!")
term.setTextColor(colors.white)
print("")

-- Now try to import packages (network already configured)
prompt_packages()

header("Setup finished")
print("You can log in as:")
print("  - " .. username .. " (administrator, sudo enabled)")
print("  - root")
print("")
if #user_pwd == 0 then
    hint("Note: " .. username .. " has no password.")
end
print("Press any key to continue...")
os.pullEventRaw()
