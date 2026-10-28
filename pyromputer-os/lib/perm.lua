-- perm.lua - simulated permission model for psh
local perm = {}

-- SHA-256, required at LOAD TIME and from the BASE half on purpose.
--
-- This used to be a lazy `pcall(require, "crypto")` inside hash_password, with an
-- arithmetic fold as the fallback. That made the STORED PASSWORD depend on which
-- modules were reachable: lib/crypto.lua sits in the modules half (the removable
-- medium) while this file sits in the base half (the computer), so the same
-- password hashed one way with the medium inserted and another way without it.
-- Measured: alice:0fbcae8a2053... with the medium, alice:1265856734 without, and
-- check_password returned false -- a password set with the medium in place could
-- not be verified without it. On a two-part install, where Part 2 is a handheld
-- you can take away, that locks the operator out of their own machine.
--
-- A require at column 0 is what tools/deploy.py's load-time closure looks for, so
-- this line is also what puts lib/sha256.lua in the base half, where the machine
-- can always reach it. The hash no longer depends on what is plugged in.
local sha256 = require("sha256")

local PASSWD  = "/etc/passwd"
local GROUPS  = "/etc/group"
local SHADOW  = "/etc/shadow"
local SUDOERS = "/etc/sudoers"
local CURRENT = "/etc/current_user"
local DB      = "/var/lib/perm.dat"

local db, users, groups_db, shadow, sudoers = nil, nil, nil, nil, nil

-- ============ hashing ============
-- The salt prefix is part of the stored format. Changing it invalidates every
-- password on every existing machine, so it is not a detail to tidy up.

-- perm's OWN files are read and written through the UNGUARDED open.
--
-- Two measured reasons, both about the same fact: lib/osguard.lua wraps the
-- machine's fs table, and perm is the module that both decides who the account is
-- and keeps the files that answer says so.
--
-- 1. /etc/shadow is readable only by root (that rule is osguard's), and this
--    module is what decides whether someone IS root -- by reading that file.
--    Going through the wrapper deadlocks: a non-root session gets nil, the shadow
--    table comes out empty, and every password check fails, so nobody can ever
--    authenticate and no one can become root. Measured on a real machine before
--    this: su and sudo were unusable from every account while the stored hashes
--    were correct.
--
-- 2. The guard is installed by the program that boots (startup.lua), and the ROM
--    gives EVERY PROGRAM ITS OWN package.loaded (rom/programs/shell.lua:50
--    createShellEnv -> rom/modules/main/cc/require.lua:120 make_package). The
--    osguard module a later program can require is therefore a different instance,
--    whose module-local raw_open is nil. The primitive is kept on the fs table
--    next to the guard's mark (osguard.RAW_OPEN), because that table is the
--    machine's own and crosses program boundaries. Measured: reading only the
--    module copy left raw_open nil inside usr/psh.lua, so the deadlock above came
--    back on the real machine even though the code looked fixed.
--
-- 3. perm also WRITES its own files: /etc/shadow, /etc/passwd, /etc/group,
--    /etc/sudoers, /var/lib/perm.dat and /etc/current_user. Those writes are the
--    login program's business -- "su" moves /etc/current_user on behalf of an
--    account the guard would refuse to write /etc for. In Unix terms perm is the
--    setuid login program, so it holds the primitive rather than a way round it.
--
-- Asked for lazily because osguard requires this module: a load-time require here
-- would be a cycle. By the time a password is checked, both are loaded.
--
-- Only the TABLE is consulted, never `guard.raw_open`. That module field belongs
-- to whichever table the instance that installed it happened to guard: a fresh
-- instance has it nil (the measured bug), and an instance that guarded some other
-- table -- which the offline suites do on purpose -- would hand its open to us and
-- the file would come back with no readLine. The field on THIS fs table is the
-- only one that is about this machine.
local function unguarded_open(path, mode)
    local ok, guard = pcall(require, "osguard")
    if ok and type(guard) == "table" then
        local key = guard.RAW_OPEN
        if type(key) == "string" and type(fs) == "table" then
            local raw = rawget(fs, key)
            if type(raw) == "function" then return raw(path, mode) end
        end
    end
    return fs.open(path, mode)
end

local function hash_password(pwd)
    return sha256.hex("cc-salt:" .. tostring(pwd))
end

-- ============ loaders ============
local function load_users()
    if users then return users end
    users = {}
    if fs.exists(PASSWD) then
        local f = unguarded_open(PASSWD, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                local name, level, groups = line:match("^([^:]+):(%d+):(.*)$")
                if not name then
                    name, level = line:match("^([^:]+):(%d+)$")
                end
                if name then
                    users[name] = {
                        level = tonumber(level) or 0,
                        groups = groups or name,
                    }
                end
            end
            f.close()
        end
    end
    if not users.root then users.root = { level = 2, groups = "root" } end
    return users
end

local function load_groups()
    if groups_db then return groups_db end
    groups_db = {}
    if fs.exists(GROUPS) then
        local f = unguarded_open(GROUPS, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                local name, members = line:match("^([^:]+):(.*)$")
                if name then
                    local list = {}
                    for m in (members or ""):gmatch("[^,]+") do
                        table.insert(list, m)
                    end
                    groups_db[name] = list
                end
            end
            f.close()
        end
    end
    return groups_db
end

-- A FAILED READ IS NOT AN ANSWER, so it is not cached.
--
-- This used to assign the empty table first and then fill it, which meant a load
-- that could not open the file cached "nobody has a password" for the rest of the
-- process: every later check failed even after the file became readable. That is
-- exactly what kept su and sudo unusable on a real machine (the first read happens
-- while lib/osguard.lua is still deciding what it may open). Now the table is only
-- kept when it was actually read, or when there is no file to read.
local function load_shadow()
    if shadow then return shadow end
    local result = {}
    local cacheable = not fs.exists(SHADOW)
    local f = unguarded_open(SHADOW, "r")
    if f then
        cacheable = true
        while true do
            local line = f.readLine()
            if line == nil then break end
            local name, h = line:match("^([^:]+):(.*)$")
            if name then result[name] = h end
        end
        f.close()
    end
    if cacheable then shadow = result end
    return result
end

local function load_sudoers()
    if sudoers then return sudoers end
    sudoers = {}
    if fs.exists(SUDOERS) then
        local f = unguarded_open(SUDOERS, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line ~= "" and line:sub(1,1) ~= "#" then
                    sudoers[line] = true
                end
            end
            f.close()
        end
    end
    return sudoers
end

-- A line may name a user exactly, a group as "%group", or use '*' as a
-- wildcard: "py*" covers every account whose name starts with "py". The
-- wildcard is the same one lib/sudorules.lua uses for commands, so both files
-- of the sudo policy are written the same way.
local function name_pattern(entry)
    local escaped = entry:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
    escaped = escaped:gsub("%*", ".*")
    return "^" .. escaped .. "$"
end

perm.name_pattern = name_pattern

function perm.is_sudoer(name)
    load_sudoers()
    load_users()
    load_groups()
    if sudoers[name] == true then return true end
    for entry in pairs(sudoers) do
        if entry:sub(1, 1) == "%" then
            -- group entry: the user has to be a member of that group
            local group = entry:sub(2)
            local members = groups_db[group]
            if members then
                for _, member in ipairs(members) do
                    if member == name then return true end
                end
            end
            local u = users[name]
            if u then
                for g in tostring(u.groups or ""):gmatch("[^,]+") do
                    if g == group then return true end
                end
            end
        elseif entry:find("*", 1, true) then
            if name:match(name_pattern(entry)) ~= nil then return true end
        end
    end
    return false
end

local function load_db()
    if db then return db end
    db = {}
    if fs.exists(DB) then
        local f = unguarded_open(DB, "r")
        if f then
            db = textutils.unserialize(f.readAll()) or {}
            f.close()
        end
    end
    return db
end

-- ============ savers ============
local function save_passwd()
    local f = unguarded_open(PASSWD, "w")
    for name, u in pairs(users) do
        f.write(name .. ":" .. u.level .. ":" .. (u.groups or name) .. "\n")
    end
    f.close()
end

local function save_groups()
    local f = unguarded_open(GROUPS, "w")
    for gname, members in pairs(groups_db) do
        f.write(gname .. ":" .. table.concat(members, ",") .. "\n")
    end
    f.close()
end

local function save_shadow()
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = unguarded_open(SHADOW, "w")
    for name, h in pairs(shadow) do
        f.write(name .. ":" .. h .. "\n")
    end
    f.close()
end

local function save_sudoers()
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = unguarded_open(SUDOERS, "w")
    for u in pairs(sudoers) do f.write(u .. "\n") end
    f.close()
end

local function save_db()
    if not fs.exists("/var/lib") then fs.makeDir("/var/lib") end
    local f = unguarded_open(DB, "w")
    f.write(textutils.serialize(db))
    f.close()
end

-- ============ public API ============

-- WHO MAY CHANGE THE LOGIN DATABASE.
--
-- perm opens /etc/passwd, /etc/group, /etc/shadow, /etc/sudoers and
-- /etc/current_user through the unguarded open (see above), so the guard no longer
-- refuses those writes on perm's behalf. The rule has to be here instead: changing
-- accounts and their passwords is root's business, exactly as the shell's own
-- commands treat it. Without it, "useradd -u 2 name" from an ordinary account would
-- succeed now -- on the guarded filesystem it used to die on a nil handle, which
-- was a refusal by accident rather than by rule.
--
-- It is a check, not a kernel: a program that reaches the primitive on the fs table
-- can still write those files directly (lib/osguard.lua says so at RAW_OPEN).
local function only_root()
    return perm.get_current_user() == "root"
end

-- THE ACCOUNT IS READ FROM /etc/current_user EVERY TIME, never remembered.
--
-- This used to cache the name in a module variable. That is wrong in exactly the
-- case the guard cares about: lib/osguard.lua keeps the perm INSTANCE of the
-- program that installed it (startup.lua, the boot program), while the session
-- changes the account from another program (usr/psh.lua wires "su" and "sudo" to
-- set_current_user). The cached name in the guard's instance would still be the
-- account the console belonged to at boot, so after "su root" every write to /etc
-- would still be refused -- measured on a real machine as a second wall after the
-- shadow read was fixed. It is also the only honest answer: /etc/current_user is
-- the record of who owns the console, and another program may have moved it.
function perm.get_current_user()
    if fs.exists(CURRENT) then
        local f = unguarded_open(CURRENT, "r")
        if f then
            local name = f.readLine()
            f.close()
            if name and name ~= "" then return name end
        end
    end
    return "root"
end

function perm.set_current_user(name)
    load_users()
    if not users[name] then return false, "no such user: " .. name end
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = unguarded_open(CURRENT, "w")
    if not f then return false, "cannot write " .. CURRENT end
    f.write(name)
    f.close()
    return true
end

function perm.user_level(name)
    load_users()
    local u = users[name or perm.get_current_user()]
    return u and u.level or 0
end

function perm.user_exists(name)
    load_users()
    return users[name] ~= nil
end

-- Sorted list of every known user name (/etc/passwd).
function perm.list_users()
    load_users()
    local names = {}
    for name in pairs(users) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function perm.get_groups(name)
    load_users()
    local u = users[name]
    if not u then return {} end
    local result = {}
    for g in (u.groups or ""):gmatch("[^,]+") do
        table.insert(result, g)
    end
    return result
end

function perm.group_members(gname)
    load_groups()
    return groups_db[gname] or {}
end

function perm.group_exists(gname)
    load_groups()
    return groups_db[gname] ~= nil
end

function perm.set_password(name, pwd, proof)
    -- An account may set its OWN password and prove it with the old one -- that is
    -- exactly what the shell's "passwd" asks for -- and nothing else.
    if not only_root() then
        if name ~= perm.get_current_user()
           or proof == nil or not perm.check_password(name, proof) then
            return false, "permission denied: not your account"
        end
    end
    local db = load_shadow()
    db[name] = hash_password(pwd)
    shadow = db                 -- save_shadow() writes the module table
    save_shadow()
    return true
end

function perm.check_password(name, pwd)
    -- Use the RETURNED table, not the module one: load_shadow() deliberately does
    -- not keep a table it could not read, so `shadow` may still be nil here and
    -- indexing it would be an error rather than a refusal.
    local db = load_shadow()
    local stored = db[name]
    if not stored then return false end
    return stored == hash_password(pwd)
end

function perm.add_sudoer(name)
    if not only_root() then return false, "permission denied: only root may change sudoers" end
    load_sudoers()
    sudoers[name] = true
    save_sudoers()
end

function perm.remove_sudoer(name)
    if not only_root() then return false, "permission denied: only root may change sudoers" end
    load_sudoers()
    sudoers[name] = nil
    save_sudoers()
end

-- ============ file permissions ============

function perm.set_mode(path, mode, owner, group)
    load_db()
    db[path] = {
        owner = owner or perm.get_current_user(),
        group = group or owner or perm.get_current_user(),
        mode = mode or "rw-r--r--",
    }
    save_db()
end

function perm.get_mode(path)
    load_db()
    return db[path]
end

-- Change the owner and/or the group of a path. nil means "leave unchanged".
-- The record is created when the path has none yet (mode defaults to
-- rw-r--r--, owner to the current user), so chown/chgrp also work on files
-- that were never touched by chmod.
function perm.chown(path, owner, group)
    if owner ~= nil then
        load_users()
        if not users[owner] then
            return false, "no such user: " .. tostring(owner)
        end
    end
    if group ~= nil then
        load_groups()
        if not groups_db[group] then
            return false, "no such group: " .. tostring(group)
        end
    end

    load_db()
    local rec = db[path]
    local new_owner = owner or (rec and rec.owner) or perm.get_current_user()
    local new_group = group or (rec and rec.group) or new_owner
    db[path] = {
        owner = new_owner,
        group = new_group,
        mode  = (rec and rec.mode) or "rw-r--r--",
    }
    save_db()
    return true
end

function perm.set_owner(path, owner)
    return perm.chown(path, owner, nil)
end

function perm.set_group(path, group)
    return perm.chown(path, nil, group)
end

function perm.get_owner(path)
    load_db()
    local rec = db[path]
    return rec and rec.owner or nil
end

function perm.get_group(path)
    load_db()
    local rec = db[path]
    return rec and rec.group or nil
end

function perm.remove(path)
    load_db()
    for k in pairs(db) do
        if k == path or k:sub(1, #path + 1) == path .. "/" then
            db[k] = nil
        end
    end
    save_db()
end

local function parse_mode(mode)
    local owner = { r = mode:sub(1,1) == "r", w = mode:sub(2,2) == "w", x = mode:sub(3,3) == "x" }
    local group = { r = mode:sub(4,4) == "r", w = mode:sub(5,5) == "w", x = mode:sub(6,6) == "x" }
    local other = { r = mode:sub(7,7) == "r", w = mode:sub(8,8) == "w", x = mode:sub(9,9) == "x" }
    return owner, group, other
end

-- THE MACHINE ITSELF IS READ-ONLY FOR EVERYONE BUT ROOT. This is a rule about
-- the machine, not about a file record: a fresh machine has no /etc/perm.db, and
-- a missing record must not mean "writable" for the directories the system lives
-- in (that was measured: without the rule, can_write answered true for
-- /usr/psh.lua and /etc/passwd for every account). Reading stays allowed -- these
-- are the files the operator must be able to read (manuals, config).
perm.SYSTEM_READONLY = {
    "/usr", "/lib", "/etc", "/bin", "/sbin", "/opt",
    "/startup.lua", "/firstboot.lua", "/rom",
}

function perm.is_system_path(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    for _, root in ipairs(perm.SYSTEM_READONLY) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
    end
    return false
end
function perm.check(path, action)
    load_db()
    -- The system directories are read-only for every account but root, whatever
    -- the record says (see SYSTEM_READONLY above).
    if action == "w" and perm.is_system_path(path) and perm.get_current_user() ~= "root" then
        return false
    end
    local record = db[path]
    if not record then return true end

    local user = perm.get_current_user()
    local bits
    if record.owner == user then
        bits = select(1, parse_mode(record.mode))
    else
        local in_group = false
        for _, g in ipairs(perm.get_groups(user)) do
            if g == record.group then in_group = true break end
        end
        if in_group then
            bits = select(2, parse_mode(record.mode))
        else
            bits = select(3, parse_mode(record.mode))
        end
    end

    if action == "r" then return bits.r, "permission denied (read)"
    elseif action == "w" then return bits.w, "permission denied (write)"
    elseif action == "x" then return bits.x, "permission denied (execute)"
    end
    return false, "unknown action"
end

function perm.can_read(path)  return perm.check(path, "r") end
function perm.can_write(path) return perm.check(path, "w") end
function perm.can_exec(path)  return perm.check(path, "x") end

-- ============ user management ============

local function reload_all()
    users, groups_db, shadow, sudoers = nil, nil, nil, nil
    load_users(); load_groups(); load_shadow(); load_sudoers()
end

function perm.add_user(name, opts)
    if not only_root() then return false, "permission denied: only root may add accounts" end
    opts = opts or {}
    load_users()
    if users[name] then return false, "user already exists" end
    users[name] = { level = opts.level or 0, groups = opts.groups or name }
    save_passwd()

    load_groups()
    local primary = (opts.groups or name):match("^([^,]+)") or name
    if not groups_db[primary] then groups_db[primary] = {} end
    local present = false
    for _, m in ipairs(groups_db[primary]) do
        if m == name then present = true break end
    end
    if not present then table.insert(groups_db[primary], name) end
    save_groups()

    load_shadow()
    shadow[name] = hash_password(opts.password or "")
    save_shadow()
    return true
end

function perm.del_user(name, remove_home)
    if not only_root() then return false, "permission denied: only root may remove accounts" end
    load_users()
    if not users[name] then return false, "no such user" end
    users[name] = nil
    save_passwd()

    load_groups()
    for _, members in pairs(groups_db) do
        for i = #members, 1, -1 do
            if members[i] == name then table.remove(members, i) end
        end
    end
    save_groups()

    load_shadow(); shadow[name] = nil; save_shadow()
    load_sudoers(); sudoers[name] = nil; save_sudoers()

    if remove_home then
        local home = "/home/" .. name
        if fs.exists(home) then
            local function rm(p)
                if fs.isDir(p) then
                    for _, f in ipairs(fs.list(p)) do rm(p .. "/" .. f) end
                end
                fs.delete(p)
            end
            rm(home)
        end
    end
    return true
end

function perm.mod_user(name, opts)
    if not only_root() then return false, "permission denied: only root may change accounts" end
    opts = opts or {}
    load_users()
    local u = users[name]
    if not u then return false, "no such user" end

    if opts.groups then u.groups = opts.groups end
    if opts.level then u.level = opts.level end

    if opts.name and opts.name ~= name then
        if users[opts.name] then return false, "target name already exists" end
        users[opts.name] = u
        users[name] = nil

        load_shadow(); shadow[opts.name] = shadow[name]; shadow[name] = nil; save_shadow()
        load_sudoers()
        if sudoers[name] then
            sudoers[name] = nil
            sudoers[opts.name] = true
            save_sudoers()
        end
    end
    save_passwd()
    return true
end

function perm.add_group(name)
    if not only_root() then return false, "permission denied: only root may add groups" end
    load_groups()
    if groups_db[name] then return false, "group already exists" end
    groups_db[name] = {}
    save_groups()
    return true
end

function perm.del_group(name)
    if not only_root() then return false, "permission denied: only root may remove groups" end
    load_groups()
    if not groups_db[name] then return false, "no such group" end
    groups_db[name] = nil
    save_groups()
    return true
end

function perm.add_to_group(user, group)
    if not only_root() then return false, "permission denied: only root may change groups" end
    load_users(); load_groups()
    if not users[user] then return false, "no such user" end
    if not groups_db[group] then groups_db[group] = {} end
    for _, m in ipairs(groups_db[group]) do
        if m == user then return true end
    end
    table.insert(groups_db[group], user)
    local list = {}
    for g in users[user].groups:gmatch("[^,]+") do
        if g ~= group then table.insert(list, g) end
    end
    table.insert(list, group)
    users[user].groups = table.concat(list, ",")
    save_groups(); save_passwd()
    return true
end

function perm.remove_from_group(user, group)
    if not only_root() then return false, "permission denied: only root may change groups" end
    load_users(); load_groups()
    local members = groups_db[group]
    if members then
        for i = #members, 1, -1 do
            if members[i] == user then table.remove(members, i) end
        end
        save_groups()
    end
    if users[user] then
        local list = {}
        for g in users[user].groups:gmatch("[^,]+") do
            if g ~= group then table.insert(list, g) end
        end
        users[user].groups = table.concat(list, ",")
        save_passwd()
    end
    return true
end

function perm.reload() reload_all() end

-- ============ defaults ============
local function ensure_defaults()
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    if not fs.exists(PASSWD) then
        local f = unguarded_open(PASSWD, "w")
        f.write("root:2:root\nadmin:1:admin,sudo\nguest:0:guest\n")
        f.close()
    end
    if not fs.exists(GROUPS) then
        local f = unguarded_open(GROUPS, "w")
        f.write("root:root\nadmin:admin\nsudo:admin\nguest:guest\n")
        f.close()
    end
    if not fs.exists(SHADOW) then
        local f = unguarded_open(SHADOW, "w")
        f.write("root:"  .. hash_password("root")  .. "\n")
        f.write("admin:" .. hash_password("admin") .. "\n")
        f.write("guest:" .. hash_password("")      .. "\n")
        f.close()
    end
    if not fs.exists(SUDOERS) then
        local f = unguarded_open(SUDOERS, "w")
        f.write("root\nadmin\n")
        f.close()
    end
end

ensure_defaults()
return perm
