-- lib/osguard.lua - the permission model, enforced below the shell.
--
-- WHY THIS EXISTS. CraftOS has no users: `fs` is one global table that every
-- program can call directly. The shell's checks (guard_write, perm.can_write in
-- rm/touch/...) therefore only bound the SHELL -- measured: a program running as a
-- guest appended to /usr/psh.lua with fs.open, and nothing stopped it. This module
-- wraps the mutating entry points of the fs table IN PLACE, so every caller -- the
-- shell, a package, a user script, a language interpreter -- goes through the same
-- rule:
--
--   * writing or deleting a system directory (/usr /lib /etc /bin /sbin /opt /rom
--     /startup.lua /firstboot.lua) is refused for every account but root;
--   * /etc/shadow is not readable by anyone but root;
--   * everything else asks the permission database (perm.can_write), which the
--     machine may or may not have populated -- a missing record still means "no
--     rule", exactly as before.
--
-- WHAT IT CANNOT STOP is stated too: a program that saved `fs.open` before this
-- installed (a require-time capture) or that reaches the raw table another way is
-- not guarded. There is no kernel here; this is the deepest place the project can
-- put the check, and it is put there once, at boot, before the shell starts.
local guard = {}

-- The mark lives on the wrapped TABLE, not in this module. The ROM gives every
-- program its OWN package table (rom/programs/shell.lua, createShellEnv), so a
-- module-local flag belongs to one program while the fs table it wraps is the
-- machine's own: measured, a second program asked osguard.installed() on a
-- machine where the guard demonstrably was installed and got false, and its
-- install() wrapped a second layer over the first.
local MARK = "__osguard_installed"

-- THE UNGUARDED OPEN, kept for perm itself, lives on the same TABLE and for the
-- same measured reason as the mark above: a module-local value belongs to ONE
-- program while the fs table belongs to the machine. The ROM builds a fresh
-- package table for every program it runs (rom/programs/shell.lua:50
-- createShellEnv -> rom/modules/main/cc/require.lua:120 make_package), so the
-- instance that installed the guard at boot is not the instance another program
-- can require.
--
-- Measured on a real machine: startup.lua installed the guard -- the fs table got
-- the mark -- and usr/psh.lua, a different program, required lib/osguard.lua and
-- found raw_open = nil. lib/perm.lua therefore fell back to the GUARDED open,
-- /etc/shadow read as nil, every password failed, and su/sudo were unusable from
-- every account while the stored hashes were correct. install() answered false
-- there because the mark was already on the table; that was not a second
-- installer, it was the same guard seen from another program.
--
-- THE HONEST LIMIT is the same one the header states: a program that reads this
-- field, or that captured fs.open before the install, is not guarded. There is no
-- kernel here; the guard is a mistake-catcher, and perm is the platform's
-- setuid layer (it is the module that decides who the account is).
local RAW_OPEN = "__osguard_raw_open"
guard.RAW_OPEN = RAW_OPEN

local installed = false

local function wrap(fs, name, replacer)
    local real = fs[name]
    if type(real) ~= "function" then return false end
    fs[name] = replacer(real)
    return true
end

-- The path rules are perm's, so the two layers cannot disagree.
local function allowed(perm, path)
    return perm.can_write(path) == true
end

local function readable(perm, path, name)
    if name == "/etc/shadow" and perm.get_current_user() ~= "root" then
        return false
    end
    return perm.can_read(path) == true
end

-- install([fstable][, perm]) -- once per process. Answers true when the wrappers
-- were installed, false when they already were or when fs is absent.
function guard.install(fstable, perm)
    local fs = fstable or _G.fs
    if type(fs) ~= "table" then return false end
    -- Second call on the same table: the mark the first call left is the answer,
    -- whichever program is asking.
    if fs[MARK] then return false end
    perm = perm or require("perm")

    -- THE UNGUARDED OPEN, kept for perm itself.
    --
    -- The rule below makes /etc/shadow readable only by root, and perm is the
    -- module that decides whether someone IS root -- by reading that very file.
    -- Through the wrapper that is a deadlock: a non-root session gets nil, its
    -- shadow table comes out empty, and EVERY password is refused. Measured on a
    -- real machine: perm.check_password("root", "root") was false while the stored
    -- hash was exactly sha256("cc-salt:root"), so su and sudo were unusable from
    -- every account. In Unix terms perm is the setuid login program, so it is given
    -- the primitive rather than a way round it.
    guard.raw_open = fs["open"]
    -- Put it where another program can find it -- see RAW_OPEN above.
    if type(guard.raw_open) == "function" then fs[RAW_OPEN] = guard.raw_open end

    wrap(fs, "open", function(real)
        return function(path, mode)
            local m = tostring(mode or "r"):lower()
            if m:sub(1, 1) == "r" then
                if not readable(perm, path, path) then return nil end
            elseif not allowed(perm, path) then
                return nil
            end
            return real(path, mode)
        end
    end)

    wrap(fs, "delete", function(real)
        return function(path)
            if not allowed(perm, path) then return false end
            return real(path)
        end
    end)

    wrap(fs, "makeDir", function(real)
        return function(path)
            if not allowed(perm, path) then return false end
            return real(path)
        end
    end)

    wrap(fs, "move", function(real)
        return function(src, dst)
            if not allowed(perm, src) or not allowed(perm, dst) then return false end
            return real(src, dst)
        end
    end)

    wrap(fs, "copy", function(real)
        return function(src, dst)
            if not allowed(perm, dst) then return false end
            return real(src, dst)
        end
    end)

    installed = true
    fs[MARK] = true
    guard.fs = fs
    return true
end

-- installed([fstable]) -- is the guard on that table? Answers the mark the
-- install left there first, so a program that never ran install() itself still
-- gets the truth about the machine's fs table. The module flag stays as the
-- fallback for a caller that asks with no table (or with one it wrapped before
-- the mark existed).
function guard.installed(fstable)
    local fs = fstable or _G.fs
    if type(fs) == "table" and fs[MARK] then return true end
    return installed
end

return guard
