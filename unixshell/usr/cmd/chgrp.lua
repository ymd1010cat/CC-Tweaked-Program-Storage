-- chgrp.lua - change the group of files and directories (external command
-- for ush)
--
-- Usage: chgrp [-R] GROUP FILE...
--
-- The group is stored by lib/perm.lua in /var/lib/perm.dat, next to the owner
-- and the mode bits. Only root or the owner of a path may change its group; a
-- path without a permission record is treated as owned by the current user.
-- The group must exist in /etc/group. Relative paths are resolved against the
-- shared working directory (lib/cwd.lua).

local args, stage = ...

local perm  = require("perm")
local audit = require("audit")
local cwd   = require("cwd")

local USAGE = "usage: chgrp [-R] GROUP FILE..."

local function emit(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local recursive = false
local group = nil
local targets = {}

for _, a in ipairs(args) do
    if a == "-R" or a == "-r" then
        recursive = true
    elseif a:sub(1, 1) == "-" and #a > 1 then
        emit("chgrp: invalid option: " .. a)
        emit(USAGE)
        return
    elseif not group then
        group = a
    else
        targets[#targets + 1] = a
    end
end

if not group or #targets == 0 then
    emit(USAGE)
    return
end

if not perm.group_exists(group) then
    emit("chgrp: invalid group: '" .. group .. "'")
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
        emit("chgrp: " .. shown .. ": no such file or directory")
        return
    end

    local rec = perm.get_mode(path)
    if is_root or rec == nil or rec.owner == actor then
        local ok, err = perm.chown(path, nil, group)
        if ok then
            audit.log({ actor = actor, action = "chgrp", target = path,
                        result = "granted", note = "group=" .. group })
        else
            emit("chgrp: " .. shown .. ": " .. tostring(err))
            audit.log({ actor = actor, action = "chgrp", target = path,
                        result = "failed", note = tostring(err) })
        end
    else
        emit("chgrp: " .. shown .. ": permission denied")
        audit.log({ actor = actor, action = "chgrp", target = path,
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
