-- sessionlog.lua - login/logout accounting for psh
--
-- Two data sets are maintained:
--
--   * /var/log/wtmp          append-only event log, written in the same
--                            "[timestamp] key=value" style as lib/audit.lua.
--                            Rotated through lib/logrotate.lua after MAX_LINES
--                            lines or 512K, keeping MAX_GENS generations:
--                            wtmp.1 is the newest, wtmp.3 the oldest.
--   * /var/lib/sessions/*.dat live session record per console, so that "who"
--                            can list the users that are online right now.
--
-- Event line format (every value is a single token, no spaces):
--   [2026-09-16 10:00:00 UTC] type=login user=admin tty=tty5 cid=5 since=1758000000 note=console
--   [2026-09-16 10:30:00 UTC] type=logout user=admin tty=tty5 cid=5 since=1758000000 end=1758001800 note=exit
--
-- "since" is the login time in Unix seconds and is used to pair a logout
-- event with its login event; "end" is only present on logout events.
-- Readers for the history are "last" and "lastlog", "who"/"w" read the live
-- session records.

local sessionlog = {}

local LOG       = "/var/log/wtmp"
local ROTATED   = "/var/log/wtmp.1"
local SESS_DIR  = "/var/lib/sessions"
local MAX_LINES = 5000
local MAX_GENS  = 3
local TIME_FMT  = "%Y-%m-%d %H:%M:%S"

local function timestamp()
    local ok, tz = pcall(require, "time")
    if ok and tz and tz.format then return tz.format(TIME_FMT) end
    return os.date(TIME_FMT)
end

local function now_epoch()
    return math.floor(os.epoch("utc") / 1000)
end

local function ensure_dirs()
    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
    if not fs.exists("/var/lib") then fs.makeDir("/var/lib") end
    if not fs.exists(SESS_DIR) then fs.makeDir(SESS_DIR) end
end

-- Current time formatted like the audit log does it.
function sessionlog.timestamp()
    return timestamp()
end

-- Console tty name of this computer.
function sessionlog.tty()
    return "tty" .. tostring(os.getComputerID())
end

function sessionlog.session_file(tty)
    return SESS_DIR .. "/" .. tostring(tty or sessionlog.tty()) .. ".dat"
end

-- ============================================================
-- Event log
-- ============================================================

local function count_lines(path)
    if not fs.exists(path) then return 0 end
    local f = fs.open(path, "r")
    if not f then return 0 end
    local n = 0
    while true do
        local line = f.readLine()
        if line == nil then break end
        n = n + 1
    end
    f.close()
    return n
end

local function rotate()
    if not fs.exists(LOG) then return nil end
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.check then
        return lr.check(LOG, { max_lines = MAX_LINES, max_size = 512 * 1024,
                               keep = MAX_GENS })
    end
    -- Fallback for a setup without lib/logrotate.lua: single generation.
    if count_lines(LOG) < MAX_LINES then return nil end
    if fs.exists(ROTATED) then fs.delete(ROTATED) end
    fs.move(LOG, ROTATED)
    return "lines"
end

-- Generations kept for /var/log/wtmp, newest first.
function sessionlog.archives()
    local out = {}
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.archives then
        return lr.archives(LOG, { keep = MAX_GENS })
    end
    for i = 1, MAX_GENS do
        local path = LOG .. "." .. tostring(i)
        if fs.exists(path) then
            out[#out + 1] = { index = i, path = path }
        end
    end
    return out
end

-- Append one event. "rec" carries user/tty/cid/since.
function sessionlog.append(kind, rec, note)
    if type(rec) ~= "table" then return false end
    ensure_dirs()
    rotate()

    local line = string.format("[%s] type=%s user=%s tty=%s cid=%s since=%s",
        timestamp(), tostring(kind), tostring(rec.user), tostring(rec.tty),
        tostring(rec.cid), tostring(rec.since))
    if kind == "logout" then
        line = line .. " end=" .. tostring(now_epoch())
    end
    line = line .. " note=" .. tostring(note or "-")

    local f = fs.open(LOG, "a")
    if not f then return false end
    f.write(line .. "\n")
    f.close()
    return true
end

-- ============================================================
-- Live sessions
-- ============================================================

function sessionlog.read_session(tty)
    local path = sessionlog.session_file(tty)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local data = textutils.unserialize(f.readAll())
    f.close()
    if type(data) ~= "table" or not data.user then return nil end
    return data
end

local function write_session(rec)
    ensure_dirs()
    local f = fs.open(sessionlog.session_file(rec.tty), "w")
    if not f then return false end
    f.write(textutils.serialize(rec))
    f.close()
    return true
end

-- Record a login. A session record left behind by a previous shell (after a
-- crash, for example) is closed first and logged with note=crash.
function sessionlog.login(user, note)
    ensure_dirs()
    local tty = sessionlog.tty()

    local prev = sessionlog.read_session(tty)
    if prev then
        sessionlog.append("logout", prev, "crash")
    end

    local rec = {
        user  = tostring(user or "?"),
        tty   = tty,
        cid   = tostring(os.getComputerID()),
        since = now_epoch(),
        note  = tostring(note or "console"),
    }
    write_session(rec)
    sessionlog.append("login", rec, rec.note)
    return rec
end

-- Close the session of this console.
function sessionlog.logout(note)
    local tty = sessionlog.tty()
    local rec = sessionlog.read_session(tty)
    if not rec then return nil end

    sessionlog.append("logout", rec, note or "exit")
    local path = sessionlog.session_file(tty)
    if fs.exists(path) then fs.delete(path) end
    return rec
end

-- The console changes hands (su without -c): close the old login and open a
-- new one, so "who" reports the user that is actually using the shell.
function sessionlog.switch_user(user, note)
    local tty = sessionlog.tty()
    local rec = sessionlog.read_session(tty)
    if not rec then return sessionlog.login(user, note or "su") end

    sessionlog.append("logout", rec, note or "su")
    rec.user  = tostring(user)
    rec.since = now_epoch()
    rec.note  = tostring(note or "su")
    write_session(rec)
    sessionlog.append("login", rec, rec.note)
    return rec
end

-- Session record of this console, or nil.
function sessionlog.current()
    return sessionlog.read_session(sessionlog.tty())
end

-- Every live session known to this file system, oldest first.
function sessionlog.online()
    ensure_dirs()
    local list = {}
    for _, name in ipairs(fs.list(SESS_DIR)) do
        local tty = name:match("^(.+)%.dat$")
        if tty then
            local rec = sessionlog.read_session(tty)
            if rec then table.insert(list, rec) end
        end
    end
    table.sort(list, function(a, b) return (a.since or 0) < (b.since or 0) end)
    return list
end

-- ============================================================
-- History readers
-- ============================================================

local function parse_file(path, out)
    if not fs.exists(path) then return end
    local f = fs.open(path, "r")
    if not f then return end
    while true do
        local line = f.readLine()
        if line == nil then break end
        local ev = { line = line }
        ev.time  = line:match("^%[([^%]]+)%]")
        ev.type  = line:match(" type=(%S+)")
        ev.user  = line:match(" user=(%S+)")
        ev.tty   = line:match(" tty=(%S+)")
        ev.cid   = line:match(" cid=(%S+)")
        ev.since = tonumber(line:match(" since=(%S+)"))
        ev.finish = tonumber(line:match(" end=(%S+)"))
        ev.note  = line:match(" note=(%S+)")
        if ev.type and ev.user then table.insert(out, ev) end
    end
    f.close()
end

-- All parsed events, oldest first. Pass true to include the rotated logs, from
-- the oldest generation up to the live file.
function sessionlog.history(include_rotated)
    local events = {}
    if include_rotated then
        local gens = sessionlog.archives()
        for i = #gens, 1, -1 do parse_file(gens[i].path, events) end
    end
    parse_file(LOG, events)
    return events
end

return sessionlog
