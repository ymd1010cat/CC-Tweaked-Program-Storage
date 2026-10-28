-- mounts.lua - logical mount table for psh
-- CraftOS has no kernel mount namespace: a disk drive simply shows up as a
-- directory (usually /disk). This module therefore implements a user space
-- mount table: every entry maps a logical path (the mount point, e.g. /mnt/a)
-- onto a real directory (the source, e.g. /disk). The table is persisted in
-- the audit.lua style (one "key=value" record per line, "#" comments) so that
-- it can be inspected with "cat /var/lib/mounts".
local mounts = {}

local MTAB = "/var/lib/mounts"
local MTAB_DIR = "/var/lib"

-- Directories that may hold a real filesystem on CC:Tweaked. "/rom" is the
-- read only ROM, "/disk" and "/diskN" are floppy drives.
local CANDIDATES = { "/disk", "/disk0", "/disk1", "/disk2", "/disk3", "/rom" }

local cache = nil

local function timestamp()
    local ok, t = pcall(require, "time")
    if ok then return t.format("%Y-%m-%d %H:%M:%S") end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function ensure_dir(path)
    if fs.exists(path) then return true end
    local parts = {}
    for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
    local acc = ""
    for _, seg in ipairs(parts) do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
    return fs.exists(path)
end

function mounts.ensure()
    if not fs.exists(MTAB_DIR) then fs.makeDir(MTAB_DIR) end
    return true
end

local function basename(p)
    local b = tostring(p):match("([^/]+)/*$")
    return b or "mnt"
end

-- Parse the option string ("rw", "ro", "ro,nodev") into a set.
local function opt_set(opts)
    local set = {}
    for part in tostring(opts or "rw"):gmatch("[^,]+") do
        set[part] = true
    end
    if not set.ro then set.rw = true end
    return set
end

function mounts.opt_set(opts) return opt_set(opts) end

-- Read the table from disk. Entries keep the order they were written in.
function mounts.reload()
    local list = {}
    if fs.exists(MTAB) then
        local f = fs.open(MTAB, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                if line:sub(1, 1) ~= "#" then
                    local source = line:match("source=(%S+)")
                    local target = line:match("target=(%S+)")
                    if source and target then
                        list[#list + 1] = {
                            source = source,
                            target = target,
                            fstype = line:match("fstype=(%S+)") or "dir",
                            opts = line:match("opts=(%S+)") or "rw",
                            user = line:match("user=(%S+)") or "?",
                        }
                    end
                end
            end
            f.close()
        end
    end
    cache = list
    return list
end

function mounts.list()
    if cache == nil then mounts.reload() end
    return cache
end

function mounts.save()
    mounts.ensure()
    local f = fs.open(MTAB, "w")
    if not f then return false, "cannot write " .. MTAB end
    f.write("# psh mount table - maintained by mount(8) / umount(8)\n")
    f.write("# format: [time] source=<dir> target=<dir> fstype=<type> opts=<opts> user=<user>\n")
    for _, e in ipairs(cache or {}) do
        f.write("[" .. timestamp() .. "] source=" .. e.source ..
                " target=" .. e.target .. " fstype=" .. e.fstype ..
                " opts=" .. e.opts .. " user=" .. e.user .. "\n")
    end
    f.close()
    return true
end

-- Build a mount table string the way mount(8) prints it.
function mounts.format(entry)
    local set = opt_set(entry.opts)
    local mode = set.ro and "ro" or "rw"
    return string.format("%s on %s type %s (%s)", entry.source, entry.target,
                         entry.fstype, mode)
end

function mounts.find(spec)
    for _, e in ipairs(mounts.list()) do
        if e.target == spec or e.source == spec then return e end
    end
    return nil
end

function mounts.by_target(target)
    for _, e in ipairs(mounts.list()) do
        if e.target == target then return e end
    end
    return nil
end

-- ------------------------------------------------------------------
-- Path mapping
-- ------------------------------------------------------------------

-- Longest matching mount point wins, so nested mounts behave predictably.
function mounts.map(path)
    if type(path) ~= "string" or path == "" then return path end
    local best, best_len = nil, -1
    for _, e in ipairs(mounts.list()) do
        local t = e.target
        local plen = #t
        if path == t or (path:sub(1, plen) == t and path:sub(plen + 1, plen + 1) == "/") then
            if plen > best_len then best, best_len = e, plen end
        end
    end
    if not best then return path end
    local rest = path:sub(#best.target + 1)
    return best.source .. rest
end

-- Reverse mapping: turn a physical path back into the logical one, used by
-- "pwd" so that a user inside /disk/a sees /mnt/a again.
function mounts.unmap(path)
    if type(path) ~= "string" or path == "" then return path end
    local best, best_len = nil, -1
    for _, e in ipairs(mounts.list()) do
        local s = e.source
        local plen = #s
        if path == s or (path:sub(1, plen) == s and path:sub(plen + 1, plen + 1) == "/") then
            if plen > best_len then best, best_len = e, plen end
        end
    end
    if not best then return path end
    local rest = path:sub(#best.source + 1)
    return best.target .. rest
end

-- True when the path (logical or physical) lives on a read only mount.
function mounts.is_readonly(path)
    if type(path) ~= "string" or path == "" then return false end
    local logical = mounts.unmap(path)
    local best, best_len = nil, -1
    for _, e in ipairs(mounts.list()) do
        local t = e.target
        local plen = #t
        if logical == t or (logical:sub(1, plen) == t and
                            logical:sub(plen + 1, plen + 1) == "/") then
            if plen > best_len then best, best_len = e, plen end
        end
    end
    if not best then return false end
    return opt_set(best.opts).ro == true
end

-- Extra command directories contributed by the mount table (/usr/bin inside a
-- mounted package disk, for instance). Consumed by path.lua.
function mounts.bin_dirs()
    local out, seen = {}, {}
    for _, e in ipairs(mounts.list()) do
        local d = e.source .. "/bin"
        if fs.exists(d) and fs.isDir(d) and not seen[d] then
            seen[d] = true
            out[#out + 1] = d
        end
    end
    return out
end

-- ------------------------------------------------------------------
-- module directories (the same idea, for require())
-- ------------------------------------------------------------------
--
-- Commands and modules are two different lookups. A command is a FILE the shell
-- runs by path, so path.lua only has to know where to look. A module goes through
-- require(), which searches package.path and nothing else -- a module on a mounted
-- medium is simply invisible until its directory is on that path.
--
-- This matters for a machine built in two parts: the shell's own modules (the
-- manual pages, the file transfer, the services) live on a medium marked .pkgsys,
-- and the shell has to be able to require them. Packages publish modules at
--
--     <root>/<package>/lib/<module>.lua
--
-- and Lua's package.path has no recursive wildcard, so there is one entry per
-- package directory.
--
-- WHY THIS LIVES HERE AND NOT IN pkg.lua: on a two-part machine pkg.lua is ON THE
-- MEDIUM. A shell that had to load the package manager in order to find the
-- medium's modules could never start -- the code that would put the medium on the
-- path would itself be on the medium. mounts.lua is part of the load-time closure
-- and is always on the computer, so it owns the scan.
--
-- The rule matches bin_dirs(): every mounted medium's /usr/pkgs, plus the
-- computer's own /usr/pkgs. A medium with no packages contributes nothing, and a
-- medium that is not inserted is not in the mount table at all.
local MODULE_DIR = "/usr/pkgs"

function mounts.module_dirs()
    local out, seen = {}, {}
    local function add_root(root)
        local pkgs = root .. MODULE_DIR
        if not (fs.exists(pkgs) and fs.isDir(pkgs)) then return end
        for _, name in ipairs(fs.list(pkgs)) do
            local dir = pkgs .. "/" .. name .. "/lib"
            if fs.exists(dir) and fs.isDir(dir) and not seen[dir] then
                seen[dir] = true
                out[#out + 1] = dir
            end
        end
    end
    add_root("")                     -- the computer's own /usr/pkgs
    for _, e in ipairs(mounts.list()) do add_root(e.source) end
    table.sort(out)
    return out
end

-- Put every module directory on package.path, and take off the entries whose
-- directory is gone (the medium was ejected). Idempotent: an entry already present
-- is not added again, so refreshing on every disk event does not grow the string
-- without bound.
--
-- Returns the number of entries added and the full list in use, so a caller can
-- report what it did.
function mounts.refresh_module_paths()
    local wanted = {}
    local list = {}
    for _, dir in ipairs(mounts.module_dirs()) do
        wanted[dir .. "/?.lua"] = true
        list[#list + 1] = dir .. "/?.lua"
    end
    -- Only entries this function owns are reconsidered: one that names a package
    -- lib directory under a /usr/pkgs. Everything else on package.path (the
    -- shell's own /lib and /usr, the ROM's, a caller's) is left exactly as it was.
    local kept = {}
    for entry in package.path:gmatch("[^;]+") do
        local mine = entry:match("^.-/usr/pkgs/[^/]+/lib/%?%.lua$")
        if not mine or wanted[entry] then
            kept[#kept + 1] = entry
        end
    end
    local added = 0
    for _, entry in ipairs(list) do
        local present = false
        for _, k in ipairs(kept) do
            if k == entry then present = true break end
        end
        if not present then
            table.insert(kept, 1, entry)
            added = added + 1
        end
    end
    package.path = table.concat(kept, ";")
    return added, list
end

-- ------------------------------------------------------------------
-- mount / umount
-- ------------------------------------------------------------------

function mounts.mount(source, target, opts, user)
    if not source or source == "" then return false, "missing source" end
    if not fs.exists(source) or not fs.isDir(source) then
        return false, "source " .. source .. ": no such directory"
    end

    target = target or ("/mnt/" .. basename(source))
    if not target:match("^/") then return false, "target must be absolute" end
    if target == "/" then return false, "refusing to mount on /" end
    if target == source then return false, "source and target are the same directory" end

    -- A target inside another source would create a loop when mapping paths.
    if source:sub(1, #target + 1) == target .. "/" then
        return false, "cannot mount " .. source .. " on " .. target .. ": nested source"
    end

    local exists = mounts.by_target(target)
    if exists and exists.source ~= source then
        return false, "target " .. target .. " is already mounted"
    end

    if not ensure_dir(target) then
        return false, "cannot create mount point " .. target
    end

    local opts_str = opts or "rw"
    local fstype = fs.exists(source .. "/.disk") and "disk" or "dir"
    if not fs.getCapacity(source) then fstype = "dir" end

    if exists then
        exists.source = source
        exists.opts = opts_str
        exists.fstype = fstype
        exists.user = user or exists.user
    else
        table.insert(mounts.list(), {
            source = source, target = target, fstype = fstype,
            opts = opts_str, user = user or "?",
        })
    end
    local ok, err = mounts.save()
    if not ok then return false, err end
    -- A new medium may carry modules: put them on package.path now, so a require
    -- after this mount finds them. Doing it here rather than at each call site
    -- means every route to a mount (the shell, disk.lua's automount, a user
    -- running `mount`) refreshes the path, and none of them can forget.
    pcall(mounts.refresh_module_paths)
    return true, mounts.by_target(target)
end

-- occupy is the current working directory of the caller: unmounting a target
-- that still holds the cwd is refused, like a busy mount on a real system.
function mounts.umount(spec, occupy)
    local entry = mounts.find(spec)
    if not entry then return false, spec .. ": not mounted" end

    if occupy then
        local t = entry.target
        if occupy == t or occupy:sub(1, #t + 1) == t .. "/" then
            return false, entry.target .. ": target is busy (current directory)"
        end
    end

    local list = mounts.list()
    local kept = {}
    for _, e in ipairs(list) do
        if e ~= entry then kept[#kept + 1] = e end
    end
    cache = kept
    local ok, err = mounts.save()
    if not ok then return false, err end
    -- The medium's modules are gone: drop their entries, so a later require fails
    -- naming a file that does not exist rather than one on a medium that is not
    -- there. (refresh_module_paths keeps only the directories that are present.)
    pcall(mounts.refresh_module_paths)
    -- The mount point directory itself is kept: unmounting never deletes data.
    return true, entry
end

-- Candidate mount sources: real filesystems reported by fs.getCapacity.
-- Returns entries with the capacity/free space already sampled.
function mounts.probe()
    local out = {}
    for _, p in ipairs(CANDIDATES) do
        if fs.exists(p) and fs.isDir(p) then
            local cap = fs.getCapacity(p)
            if cap then
                out[#out + 1] = p
            end
        end
    end
    return out
end

function mounts.clear_cache() cache = nil end

return mounts
