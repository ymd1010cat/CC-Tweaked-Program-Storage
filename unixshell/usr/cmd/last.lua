-- last.lua - show the login history (external command for ush)
--
-- Usage: last [-n N] [user]
--
--   -n N    print only the N most recent records (default 10)
--   user    restrict the report to one user
--
-- The events are read from /var/log/wtmp (and /var/log/wtmp.1 once the log
-- has been rotated) through lib/sessionlog.lua. A login event without a
-- matching logout event is reported as "still logged in".

local args, stage = ...

local sessionlog = require("sessionlog")
local who = require("who")

local USAGE = "usage: last [-n N] [user]"

local function emit(text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

local function fmt_duration(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then sec = 0 end
    local days = math.floor(sec / 86400)
    local hours = math.floor((sec % 86400) / 3600)
    local mins = math.floor((sec % 3600) / 60)
    if days > 0 then return string.format("%d+%02d:%02d", days, hours, mins) end
    return string.format("%02d:%02d", hours, mins)
end

local count = 10
local user_filter = nil
local i = 1
while i <= #args do
    local a = args[i]
    if a == "-n" then
        count = tonumber(args[i + 1])
        if not count then
            emit("last: option requires an argument: -n")
            emit(USAGE)
            return
        end
        i = i + 2
    elseif a:match("^%-n%d+$") then
        count = tonumber(a:sub(3))
        i = i + 1
    elseif a:sub(1, 1) == "-" and #a > 1 then
        emit("last: invalid option: " .. a)
        emit(USAGE)
        return
    else
        if user_filter then
            emit("last: extra operand: " .. a)
            emit(USAGE)
            return
        end
        user_filter = a
        i = i + 1
    end
end

local events = sessionlog.history(true)
if #events == 0 then
    emit("last: no login records in /var/log/wtmp")
    return
end

-- Pair every login with its logout (same tty and same login time).
local rows, by_key = {}, {}
for _, ev in ipairs(events) do
    local key = tostring(ev.tty) .. "@" .. tostring(ev.since)
    if ev.type == "login" then
        local row = {
            user  = ev.user,
            tty   = ev.tty,
            start = ev.time,
            since = ev.since or 0,
        }
        table.insert(rows, row)
        by_key[key] = row
    elseif ev.type == "logout" then
        local row = by_key[key]
        if row then
            row.finish = ev.time
            row.duration = math.max((ev.finish or os.time()) - (ev.since or 0), 0)
        end
    end
end

table.sort(rows, function(a, b) return (a.since or 0) > (b.since or 0) end)

local shown = 0
for _, row in ipairs(rows) do
    if (not user_filter or row.user == user_filter) and shown < count then
        shown = shown + 1
        local suffix
        if row.finish then
            suffix = " - " .. row.finish .. "  (" .. fmt_duration(row.duration) .. ")"
        else
            suffix = "  still logged in"
        end
        emit(string.format("%-8s %-7s %-24s %s",
            row.user, row.tty, row.start or "-", suffix))
    end
end

if shown == 0 then
    emit("last: no records" .. (user_filter and (" for " .. user_filter) or ""))
end

emit("")
emit("wtmp begins " .. tostring(events[1].time))
