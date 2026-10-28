-- chmod.lua - change file mode bits (external command for psh)
--
-- Usage: chmod [-R] MODE FILE...
--
-- MODE accepts an octal form (755, 644, 0644) or a symbolic nine-character
-- form (rwxr-xr-x). Modes are stored in /var/lib/perm.dat through lib/perm.lua.
-- Only the owner of a path or root may change its mode; paths without a
-- permission record are treated as owned by the current user. Relative paths
-- are resolved against the shared working directory (lib/cwd.lua).

local args, stage = ...

local perm  = require("perm")
local audit = require("audit")
local cwd   = require("cwd")

local USAGE = "usage: chmod [-R] MODE FILE..."

local function emit(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local OCTAL = {
    ["0"] = "---", ["1"] = "--x", ["2"] = "-w-", ["3"] = "-wx",
    ["4"] = "r--", ["5"] = "r-x", ["6"] = "rw-", ["7"] = "rwx",
}

-- Convert an octal or symbolic mode into the nine-character rwx form.
local function parse_mode(text)
    local digits = text:match("^([0-7][0-7][0-7])$") or
                   text:match("^0([0-7][0-7][0-7])$")
    if digits then
        local parts = {}
        for i = 1, 3 do
            parts[i] = OCTAL[digits:sub(i, i)]
        end
        return table.concat(parts)
    end
    if text:match("^[r-][w-][x-][r-][w-][x-][r-][w-][x-]$") then
        return text
    end
    return nil
end

local recursive = false
local mode_text = nil
local targets = {}

for _, a in ipairs(args) do
    if a == "-R" or a == "-r" then
        recursive = true
    elseif a:sub(1, 1) == "-" and #a > 1 then
        emit("chmod: invalid option: " .. a)
        emit(USAGE)
        return
    elseif not mode_text then
        mode_text = a
    else
        targets[#targets + 1] = a
    end
end

if not mode_text or #targets == 0 then
    emit(USAGE)
    return
end

local new_mode = parse_mode(mode_text)
if not new_mode then
    emit("chmod: invalid mode: " .. mode_text)
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
        emit("chmod: " .. shown .. ": no such file or directory")
        return
    end

    local rec = perm.get_mode(path)
    if is_root or rec == nil or rec.owner == actor then
        local owner = rec and rec.owner or actor
        local group = rec and rec.group or owner
        perm.set_mode(path, new_mode, owner, group)
        audit.log({ actor = actor, action = "chmod", target = path,
                    result = "granted", note = "mode=" .. new_mode })
    else
        emit("chmod: " .. shown .. ": permission denied")
        audit.log({ actor = actor, action = "chmod", target = path,
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
