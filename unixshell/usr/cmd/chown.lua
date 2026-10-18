-- chown.lua - change file owner and group (external command for ush)
--
-- Usage: chown [-R] OWNER[:GROUP] FILE...
--        chown [-R] :GROUP FILE...
--
-- Ownership is stored by lib/perm.lua in /var/lib/perm.dat, next to the mode
-- bits handled by chmod. Only root or the owner of a path may change its
-- ownership; a path without a permission record is treated as owned by the
-- current user. Names must exist in /etc/passwd (users) and /etc/group
-- (groups). An empty owner or group field means "leave unchanged".
-- Relative paths are resolved against the shared working directory
-- (lib/cwd.lua).

local args, stage = ...

local perm  = require("perm")
local audit = require("audit")
local cwd   = require("cwd")

local USAGE = "usage: chown [-R] OWNER[:GROUP] FILE..."

local function emit(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local recursive = false
local spec = nil
local targets = {}

for _, a in ipairs(args) do
    if a == "-R" or a == "-r" then
        recursive = true
    elseif a:sub(1, 1) == "-" and #a > 1 then
        emit("chown: invalid option: " .. a)
        emit(USAGE)
        return
    elseif not spec then
        spec = a
    else
        targets[#targets + 1] = a
    end
end

if not spec or #targets == 0 then
    emit(USAGE)
    return
end

-- OWNER, OWNER:GROUP, :GROUP, OWNER: (empty field = unchanged)
local owner, group = spec:match("^([^:]*):(.*)$")
if owner == nil then owner = spec end
if owner == "" then owner = nil end
if group == "" then group = nil end

if not owner and not group then
    emit("chown: invalid spec: " .. spec)
    emit(USAGE)
    return
end

if owner and not perm.user_exists(owner) then
    emit("chown: invalid user: '" .. owner .. "'")
    return
end

if group and not perm.group_exists(group) then
    emit("chown: invalid group: '" .. group .. "'")
    return
end

local actor = perm.get_current_user()
local is_root = actor == "root" or perm.user_level(actor) >= 2

local function child_name(parent, name)
    if parent:sub(-1) == "/" then
        return parent .. name
    end
    return parent .. "/" .. name
end

local function apply(path, shown)
    if not fs.exists(path) then
        emit("chown: " .. shown .. ": no such file or directory")
        return
    end

    local rec = perm.get_mode(path)
    if is_root or rec == nil or rec.owner == actor then
        local before_owner = rec and rec.owner or actor
        local before_group = rec and rec.group or before_owner
        local ok, err = perm.chown(path, owner, group)
        if ok then
            local new_owner = owner or before_owner
            local new_group = group or before_group
            audit.log({ actor = actor, action = "chown", target = path,
                        result = "granted",
                        note = "owner=" .. new_owner .. " group=" .. new_group })
        else
            emit("chown: " .. shown .. ": " .. tostring(err))
            audit.log({ actor = actor, action = "chown", target = path,
                        result = "failed", note = tostring(err) })
        end
    else
        emit("chown: " .. shown .. ": permission denied")
        audit.log({ actor = actor, action = "chown", target = path,
                    result = "denied", note = "not owner" })
    end

    if recursive and fs.isDir(path) then
        for _, name in ipairs(fs.list(path)) do
            apply(child_name(path, name), child_name(shown, name))
        end
    end
end

for _, t in ipairs(targets) do
    apply(cwd.resolve(t), t)
end
