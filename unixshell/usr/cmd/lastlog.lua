-- lastlog.lua - report the last login of every user (external command for
-- ush)
--
-- Usage: lastlog [-u USER]
--
--   -u USER   report only USER
--
-- The most recent login event per user is read from /var/log/wtmp through
-- lib/sessionlog.lua; users without any login event are reported as
-- "**Never logged in**". The user list comes from lib/perm.lua (/etc/passwd).

local args, stage = ...

local sessionlog = require("sessionlog")
local perm = require("perm")

local USAGE = "usage: lastlog [-u USER]"

local function emit(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local user_filter = nil
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-u" or a == "--user" then
        user_filter = args[i + 1]
        if not user_filter then
            emit("lastlog: option requires an argument: " .. a)
            emit(USAGE)
            return
        end
        i = i + 2
    elseif a:sub(1, 1) == "-" and #a > 1 then
        emit("lastlog: invalid option: " .. a)
        emit(USAGE)
        return
    else
        if user_filter then
            emit("lastlog: extra operand: " .. a)
            emit(USAGE)
            return
        end
        user_filter = a
        i = i + 1
    end
end

if user_filter and not perm.user_exists(user_filter) then
    emit("lastlog: user '" .. user_filter .. "' does not exist")
    return
end

local latest = {}
for _, ev in ipairs(sessionlog.history(true)) do
    if ev.type == "login" then
        local current = latest[ev.user]
        if not current or (ev.since or 0) >= (current.since or 0) then
            latest[ev.user] = ev
        end
    end
end

local users = user_filter and { user_filter } or perm.list_users()

emit(string.format("%-16s %-8s %s", "Username", "Port", "Latest"))
for _, name in ipairs(users) do
    local ev = latest[name]
    if ev then
        emit(string.format("%-16s %-8s %s", name, ev.tty or "-", ev.time or "-"))
    else
        emit(string.format("%-16s %-8s %s", name, "", "**Never logged in**"))
    end
end
