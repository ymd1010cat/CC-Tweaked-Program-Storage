-- protect.lua - which files a shell command may overwrite, and whether the shell
--               can be left
--
-- WHY THIS EXISTS
-- The machine boots by running files in fixed places: /startup.lua at the root,
-- /usr/ush.lua, /lib/*.lua, /firstboot.lua. If one of those is overwritten the
-- computer either stops booting or boots something else entirely, and the only
-- way back is to reinstall from outside. On a machine whose filesystem also
-- holds removable media (a package store, a disk someone handed over) the
-- dangerous case is ordinary: a file copied off a medium lands on a boot path.
--
-- So the shell refuses to overwrite a BOOT FILE unless the operator has turned
-- that off. The default is on (protection), and the switch is a machine rule in
-- /etc/boot.conf rather than a per-command flag, because the point is to survive
-- a careless command, not to be asked each time.
--
-- The same file holds the other rule of the same kind: whether the shell may be
-- left at all. "ush cannot be exited" is a property of the machine (a kiosk, a
-- console that has to stay up), not of one command, so it is recorded here and
-- read at start up rather than decided per keystroke.
--
-- WHAT IS PROTECTED, AND WHY THE LIST IS A LIST
-- Only paths that the boot sequence actually reads are protected. Protecting all
-- of /lib would also block a package upgrade, which is legitimate; protecting the
-- boot path does not, because a package installs into /usr/pkgs. The list is
-- explicit so that a reader can see exactly what is covered.
--
-- A file that does not exist is not a boot file yet: creating /startup.lua where
-- there was none is a write, not an overwrite, and it is refused too -- the
-- hazard is the same, since the next boot would run whatever landed there.
--
-- THE ESCAPE HATCH IS DELIBERATE AND NARROW
-- A root user who really means to replace a boot file can turn the guard off
-- ("set +o bootguard"), which is recorded in /etc/boot.conf and therefore
-- survives a reboot. That is the same shape as the store rules in
-- /etc/pkgstore.conf: a rule about the machine, kept on the machine, changed by a
-- privileged command. The same applies to "set +o noexit".

local protect = {}

local CONF = "/etc/boot.conf"

-- The paths the boot sequence reads. A trailing "/" means a whole directory:
-- every file under it is a boot file.
local BOOT_PATHS = {
    "/startup.lua",
    "/firstboot.lua",
    "/usr/ush.lua",
    "/lib/",
}

-- Declared before its users, the same discipline lib/pkg.lua needs: a local that
-- is used above its declaration is a nil, not a compile error.
local cached = nil

local function read_conf()
    local out = { guard = true, noexit = true }
    if not fs.exists(CONF) then return out end
    local f = fs.open(CONF, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
            if v ~= "" then
                local on = not (v == "0" or v == "off" or v == "no" or v == "false")
                if k == "boot_guard" then out.guard = on end
                if k == "no_exit" then out.noexit = on end
            end
        end
    end
    f.close()
    return out
end

-- Normalise a path for comparison: a single leading slash, no "./" or "//",
-- no trailing slash. A path that is not absolute is not a boot path (it cannot
-- be: the boot sequence reads fixed absolute names).
function protect.normalize(path)
    if type(path) ~= "string" or path == "" then return nil end
    local text = path:gsub("\\", "/")
    if text:sub(1, 1) ~= "/" then return nil end
    text = text:gsub("//+", "/")
    while text:find("/%./") do text = text:gsub("/%./", "/") end
    text = text:gsub("/%.$", "/")
    while #text > 1 and text:sub(-1) == "/" do text = text:sub(1, -2) end
    return text
end

-- True when this path is one the boot sequence reads.
function protect.is_boot_file(path)
    local text = protect.normalize(path)
    if not text then return false end
    for _, entry in ipairs(BOOT_PATHS) do
        if entry:sub(-1) == "/" then
            local prefix = entry:sub(1, -2)
            if text == prefix or text:sub(1, #prefix + 1) == prefix .. "/" then
                return true
            end
        elseif text == entry then
            return true
        end
    end
    return false
end

-- Forget the cached answer. Called after a switch changes.
function protect.reload()
    cached = nil
    return read_conf()
end

-- The two rules, as the shell wants them: the guard is on unless /etc/boot.conf
-- says otherwise. Read once and remembered: a command that writes many files
-- must not re-read the file per file.
function protect.enabled()
    if cached == nil then cached = read_conf() end
    return cached.guard
end

function protect.no_exit()
    if cached == nil then cached = read_conf() end
    return cached.noexit
end

-- Write one switch, keeping every other line as it was. The file is written with
-- the OFF value only when a rule is off, so "on" (the default) and "no file" are
-- the same on disk.
local function set_conf(key, on)
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local pattern = "^%s*" .. key .. "%s*="
    local lines = {}
    if fs.exists(CONF) then
        local f = fs.open(CONF, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                if not line:match(pattern) then lines[#lines + 1] = line end
            end
            f.close()
        end
    end
    if not on then table.insert(lines, 1, key .. "=0") end
    local f = fs.open(CONF, "w")
    if not f then return false, "cannot write " .. CONF end
    f.write(table.concat(lines, "\n"))
    if #lines > 0 then f.write("\n") end
    f.close()
    protect.reload()
    return true, on and "on" or "off"
end

-- Turn the boot guard on or off.
function protect.set_enabled(on)
    return set_conf("boot_guard", on)
end

-- Turn "the shell may be left" on or off.
function protect.set_no_exit(on)
    return set_conf("no_exit", on)
end

-- The check a writer calls before it opens a path for writing. Returns true when
-- the write may go ahead, or false plus the message to show.
--
-- "actor" is the user the command runs as. root is NOT exempt: the whole point is
-- that a careless root command cannot brick the machine, and a root user who means
-- it has set +o bootguard. Saying so in the message is what makes the guard usable
-- rather than merely obstructive.
function protect.check(path, actor)
    if not protect.enabled() then return true end
    if not protect.is_boot_file(path) then return true end
    return false, "ush: " .. tostring(path) .. ": boot file is protected " ..
                  "(set +o bootguard as root to allow it)"
end

-- The paths that are protected, for the man page and for "set -o" to report.
function protect.paths()
    return BOOT_PATHS
end

return protect
