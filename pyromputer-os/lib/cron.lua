-- cron.lua - scheduled tasks for psh (crontab and at)
--
-- Storage, in the audit.lua style (one record per line, key=value fields):
--
--   /etc/crontab          "m h dom mon dow user command" lines, "#" comments
--   /var/spool/at/<...>   one file per one-shot job
--   /var/lib/cron.state   last fired minute per crontab entry
--   /var/log/cron.log     execution log
--
-- Time specs: the five classic fields, plus the special entries
--
--   @reboot     run once per boot (fired by the first tick after the boot)
--   @hourly @daily @midnight @weekly @monthly
--               expanded to "0 * * * *", "0 0 * * *", "0 0 * * 0", "0 0 1 * *"
--
-- A @reboot line has the form "@reboot <user> <command>"; the owning user is
-- the crontab it was installed for. The boot identity comes from lib/boot.lua,
-- and /var/lib/cron.reboot remembers the boot whose @reboot entries already
-- ran, so the watchdog cannot fire them a second time.
--
-- User level: /etc/crontab is a single table with a user column, and the
-- entries installed by "crontab -u USER" carry that user in the log
-- (user=... field). A user who is not root may only manage their own lines.
--
-- Triggering model (honest description): CraftOS has no scheduler daemon and
-- no threads, so due tasks are checked at shell idle points - the line editor
-- timer while the user types, and the startup.lua watchdog while psh is not
-- running. A task that becomes due while a long command runs is therefore
-- fired late, not concurrently.
local cron = {}

local SYS_CRONTAB = "/etc/crontab"
local SPOOL = "/var/spool/at"
local STATE = "/var/lib/cron.state"
local LOG = "/var/log/cron.log"
local REBOOT_MARKER = "/var/lib/cron.reboot"
local MAX_STATE = 500

-- Special time specs, expanded to the classic five field form.
local ALIASES = {
    ["@hourly"]   = "0 * * * *",
    ["@daily"]    = "0 0 * * *",
    ["@midnight"] = "0 0 * * *",
    ["@weekly"]   = "0 0 * * 0",
    ["@monthly"]  = "0 0 1 * *",
}

cron.log_file = LOG
cron.state_file = STATE
cron.reboot_marker = REBOOT_MARKER
cron.table_file = SYS_CRONTAB
cron.aliases = ALIASES


local function timestamp()
    local ok, t = pcall(require, "time")
    if ok then return t.format("%Y-%m-%d %H:%M:%S") end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function now_seconds()
    local ok, e = pcall(os.epoch, "utc")
    if ok and type(e) == "number" then return math.floor(e / 1000) end
    return os.time()
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

function cron.ensure()
    ensure_dir("/etc")
    ensure_dir("/var/spool")
    ensure_dir("/var/log")
    ensure_dir("/var/lib")
    if not fs.exists(SPOOL) then fs.makeDir(SPOOL) end
    return true
end

-- ------------------------------------------------------------------
-- Field matching: "*", "n", "a,b,c", "a-b", "*/n", "a-b/n"
-- ------------------------------------------------------------------

-- Kept as a thin alias so callers that only test a single value keep working.
function cron.match_field(field, value)
    return cron.field_match(field, value)
end

function cron.field_match(field, value)
    if field == nil then return false end
    local spec = tostring(field):gsub("%s", "")
    if spec == "" then return false end
    if spec == "*" then return true end

    for part in spec:gmatch("[^,]+") do
        local range, step = part, 1
        local slash = part:find("/", 1, true)
        if slash then
            range = part:sub(1, slash - 1)
            step = tonumber(part:sub(slash + 1)) or 1
        end

        local lo, hi
        if range == "*" then
            lo, hi = nil, nil
        else
            local dash = range:find("-", 2, true)
            if dash then
                lo = tonumber(range:sub(1, dash - 1))
                hi = tonumber(range:sub(dash + 1))
            else
                lo = tonumber(range)
                hi = lo
            end
        end

        if lo == nil then
            -- "*/n": every n-th value
            if value % step == 0 then return true end
        elseif hi == nil then
            if value == lo then return true end
        elseif value >= lo and value <= hi then
            if step <= 1 or (value - lo) % step == 0 then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------------
-- /etc/crontab
-- ------------------------------------------------------------------

-- Parse one crontab line into a structured entry, or return nil plus a
-- reason. Expected form: m h dom mon dow user command...
-- A "@reboot user command" line is also accepted; its alias is stored in the
-- "alias" field with special = true, and minute/hour/dom/month/dow stay nil.
function cron.parse_line(line)
    if line == nil then return nil, "empty" end
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil, "empty" end
    if trimmed:sub(1, 1) == "#" then return nil, "comment" end

    local words = {}
    for w in trimmed:gmatch("%S+") do
        words[#words + 1] = w
    end

    local head = (words[1] or ""):lower()
    if head == "@reboot" then
        if #words < 3 then
            return nil, "@reboot needs a user and a command"
        end
        local command = trimmed:match("^%s*%S+%s+%S+%s+(.*)$")
        if not command or command == "" then
            return nil, "@reboot needs a command"
        end
        local entry = {
            alias = "@reboot", special = true, user = words[2],
            command = command, line = trimmed, spec = "@reboot",
        }
        entry.minute, entry.hour = nil, nil
        entry.dom, entry.month, entry.dow = nil, nil, nil
        return entry
    end

    if ALIASES[head] then
        local command = trimmed:match("^%s*%S+%s+%S+%s+(.*)$")
        if not command or command == "" then
            return nil, head .. " needs a command"
        end
        local spec = ALIASES[head]
        return {
            alias = head, spec = spec, user = words[2], command = command,
            line = trimmed,
            minute = spec:match("^(%S+)"), hour = spec:match("^%S+%s+(%S+)"),
            dom = spec:match("^%S+%s+%S+%s+(%S+)"),
            month = spec:match("^%S+%s+%S+%s+%S+%s+(%S+)"),
            dow = spec:match("^%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"),
        }
    end

    if #words < 6 then
        return nil, "expected 'minute hour dom month dow user command'"
    end

    local command = trimmed:match("^%s*%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.*)$")
    if not command or command == "" then
        return nil, "missing command"
    end

    return {
        minute = words[1], hour = words[2], dom = words[3],
        month = words[4], dow = words[5], user = words[6],
        command = command,
        line = trimmed,
    }
end

function cron.load_lines()
    local lines = {}
    if not fs.exists(SYS_CRONTAB) then return lines end
    local f = fs.open(SYS_CRONTAB, "r")
    if not f then return lines end
    while true do
        local line = f.readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    f.close()
    return lines
end

function cron.save_lines(lines)
    ensure_dir("/etc")
    local f = fs.open(SYS_CRONTAB, "w")
    if not f then return false, "cannot write " .. SYS_CRONTAB end
    f.write("# psh crontab - maintained by crontab(1)\n")
    f.write("# m h dom mon dow user command\n")
    for _, line in ipairs(lines) do
        f.write(line .. "\n")
    end
    f.close()
    return true
end

-- All entries of the table, parsed. Invalid lines are reported through the
-- second return value.
function cron.entries()
    local entries, bad = {}, {}
    for _, line in ipairs(cron.load_lines()) do
        local e, why = cron.parse_line(line)
        if e then
            entries[#entries + 1] = e
        elseif why and why ~= "empty" and why ~= "comment" then
            bad[#bad + 1] = { line = line, reason = why }
        end
    end
    return entries, bad
end

function cron.entries_for(user)
    local out = {}
    for _, e in ipairs(cron.entries()) do
        if e.user == user then out[#out + 1] = e end
    end
    return out
end

-- Replace every line of one user by the given entries, keeping other users and
-- the comment block untouched.
function cron.install_for(user, lines)
    local kept = {}
    for _, line in ipairs(cron.load_lines()) do
        local e = cron.parse_line(line)
        if not (e and e.user == user) then kept[#kept + 1] = line end
    end
    for _, line in ipairs(lines) do
        if line:match("%S") then kept[#kept + 1] = line end
    end
    return cron.save_lines(kept)
end

function cron.remove_for(user)
    return cron.install_for(user, {})
end

function cron.add_entry(user, command, spec)
    spec = spec or "*/5 * * * *"
    local line = spec .. " " .. user .. " " .. command
    local kept = cron.load_lines()
    kept[#kept + 1] = line
    return cron.save_lines(kept)
end

-- ------------------------------------------------------------------
-- at queue
-- ------------------------------------------------------------------

local function at_seq()
    if not fs.exists(SPOOL) then return 0 end
    local n = 0
    for _, f in ipairs(fs.list(SPOOL)) do n = n + 1 end
    return n
end

function cron.at_add(when_epoch, command, user)
    cron.ensure()
    when_epoch = math.floor(tonumber(when_epoch) or now_seconds())
    local name = string.format("%d-%03d.job", when_epoch, at_seq() + 1)
    local path = SPOOL .. "/" .. name
    local f = fs.open(path, "w")
    if not f then return nil, "cannot write " .. path end
    f.write("when=" .. when_epoch .. "\n")
    f.write("user=" .. (user or "root") .. "\n")
    f.write("created=" .. now_seconds() .. "\n")
    f.write("command=" .. command .. "\n")
    f.close()
    return path
end

function cron.at_list()
    local out = {}
    if not fs.exists(SPOOL) then return out end
    for _, name in ipairs(fs.list(SPOOL)) do
        local path = SPOOL .. "/" .. name
        local f = fs.open(path, "r")
        if f then
            local job = { path = path, name = name }
            while true do
                local line = f.readLine()
                if line == nil then break end
                local k, v = line:match("^([%w_]+)=(.*)$")
                if k then job[k] = v end
            end
            f.close()
            job.when_epoch = tonumber(job.when) or 0
            out[#out + 1] = job
        end
    end
    table.sort(out, function(a, b) return a.when_epoch < b.when_epoch end)
    return out
end

function cron.at_remove(path)
    if fs.exists(path) then return fs.delete(path) end
    return false
end

-- Parse "at" style time expressions:
--   "+N"     -> N seconds from now
--   "HH:MM"  -> today at HH:MM, tomorrow when already past
--   an epoch -> absolute unix time
function cron.parse_at_time(spec, now)
    now = now or now_seconds()
    if spec == nil or spec == "" then return nil, "missing time" end

    local rel = spec:match("^%+(%d+)$")
    if rel then return now + tonumber(rel), "relative" end

    local h, m = spec:match("^(%d%d?):(%d%d)$")
    if h and m then
        h, m = tonumber(h), tonumber(m)
        if h > 23 or m > 59 then return nil, "invalid time" end
        local t = os.date("*t", now)
        t.hour, t.min, t.sec = h, m, 0
        local target = os.time(t)
        if target <= now then target = target + 86400 end
        return target, "clock"
    end

    local abs = tonumber(spec)
    if abs then return abs, "absolute" end

    return nil, "unrecognised time (use +N, HH:MM or an epoch)"
end

-- ------------------------------------------------------------------
-- State and firing
-- ------------------------------------------------------------------

-- djb2, used as a stable key for a crontab entry.
function cron.hash(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

function cron.state_load()
    local state = {}
    if not fs.exists(STATE) then return state end
    local f = fs.open(STATE, "r")
    if not f then return state end
    while true do
        local line = f.readLine()
        if line == nil then break end
        local key = line:match("key=(%x+)")
        local when = line:match("when=(%d+)")
        if key then state[key] = tonumber(when) or 0 end
    end
    f.close()
    return state
end

function cron.state_save(state)
    cron.ensure()
    local f = fs.open(STATE, "w")
    if not f then return false, "cannot write " .. STATE end
    f.write("# psh cron state - last fired minute per entry\n")
    local n = 0
    for key, when in pairs(state) do
        n = n + 1
        if n > MAX_STATE then break end
        f.write("key=" .. key .. " when=" .. tostring(when) .. "\n")
    end
    f.close()
    return true
end

-- One line per execution:
--   [time] user=U level=L command="..." result=ok|error [exit=N] [note="..."]
-- level is the table the entry came from: "crontab", "at" or "reboot".
-- Exit status is recorded when the runner reports one.
function cron.log(entry, result, note, extra)
    cron.ensure()
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.check then
        pcall(lr.check, LOG, { max_lines = 2000, keep = 2 })
    end
    local f = fs.open(LOG, "a")
    if not f then return false end
    local parts = {
        "[" .. timestamp() .. "]",
        "user=" .. (entry.user or "?"),
        "level=" .. ((extra and extra.level) or entry.level or "crontab"),
        "command=\"" .. (entry.command or "") .. "\"",
        "result=" .. (result or "?"),
    }
    if extra and extra.exit ~= nil then
        parts[#parts + 1] = "exit=" .. tostring(extra.exit)
    end
    if note then parts[#parts + 1] = 'note="' .. note .. '"' end
    f.write(table.concat(parts, " ") .. "\n")
    f.close()
    return true
end

-- The last n log lines, optionally only those containing `filter` (a plain
-- substring, so "user=alice" or a command fragment both work).
function cron.logs(n, filter)
    n = n or 20
    local out = {}
    if not fs.exists(LOG) then return out end
    local f = fs.open(LOG, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        if not filter or line:find(filter, 1, true) then
            out[#out + 1] = line
            if #out > n then table.remove(out, 1) end
        end
    end
    f.close()
    return out
end

function cron.tail(n)
    n = n or 20
    if not fs.exists(LOG) then return {} end
    local buf = {}
    local f = fs.open(LOG, "r")
    while true do
        local line = f.readLine()
        if line == nil then break end
        buf[#buf + 1] = line
        if #buf > n then table.remove(buf, 1) end
    end
    f.close()
    return buf
end

-- Does this entry fire during the minute described by t (os.date "*t" table)?
function cron.fires(entry, t)
    return cron.field_match(entry.minute, t.min) and
           cron.field_match(entry.hour, t.hour) and
           cron.field_match(entry.dom, t.day) and
           cron.field_match(entry.month, t.month) and
           cron.field_match(entry.dow, (t.wday - 1) % 7)
end

-- Next fire time for an entry, searched minute by minute for at most `days`.
function cron.next_time(entry, from, days)
    from = from or now_seconds()
    days = days or 7
    local limit = from + days * 86400
    local t = from + 60
    while t <= limit do
        if cron.fires(entry, os.date("*t", t)) then return t end
        t = t + 60
    end
    return nil
end

-- Fire everything that is due. `runner(command, user)` performs the actual
-- execution and is supplied by the shell; it may return false plus a message
-- for a command that failed, and a second value with the exit status. Returns
-- a summary table.
function cron.run_due(now, runner)
    now = now or now_seconds()
    local summary = { at = {}, cron = {}, reboot = {}, errors = {} }

    -- Execute one entry and write the log line. The runner is called through
    -- pcall, so a broken command can never escape the idle hook.
    local function fire(entry, note, level, list)
        if not runner then return false end
        local pcall_ok, run_ok, code = pcall(runner, entry.command, entry.user)
        local ok = pcall_ok and (run_ok ~= false)
        local info = { level = level }
        if type(code) == "number" then info.exit = code end
        local why
        if not pcall_ok then
            why = tostring(run_ok)
        elseif run_ok == false then
            why = "runner reported failure"
            if type(code) == "string" and code ~= "" then why = code end
        end
        cron.log(entry, ok and "success" or "error", ok and note or why, info)
        if not ok then summary.errors[#summary.errors + 1] = tostring(why) end
        if list then list[#list + 1] = entry end
        return ok
    end

    -- @reboot entries: once per boot, keyed on the boot identity.
    local specials = {}
    for _, e in ipairs(cron.entries()) do
        if e.special then specials[#specials + 1] = e end
    end
    if #specials > 0 then
        local ok, b = pcall(require, "boot")
        local first = ok and b and b.begin and b.begin(REBOOT_MARKER)
        if first then
            for _, e in ipairs(specials) do
                fire(e, "@reboot", "reboot", summary.reboot)
            end
        end
    end

    -- One-shot jobs next: they are always run once, even when late.
    for _, job in ipairs(cron.at_list()) do
        if job.when_epoch <= now then
            local cmd = job.command or ""
            cron.at_remove(job.path)
            if runner then
                fire({ user = job.user, command = cmd, level = "at",
                       when = job.when_epoch },
                     "at " .. job.name, "at", summary.at)
            end
        end
    end

    -- Repeating entries: at most once per minute, tracked in the state file.
    local state = cron.state_load()
    local minute = math.floor(now / 60) * 60
    local t = os.date("*t", now)
    local dirty = false

    for _, e in ipairs(cron.entries()) do
        if not e.special and cron.fires(e, t) then
            local key = cron.hash(e.line)
            if (state[key] or 0) < minute then
                state[key] = minute
                dirty = true
                if runner then
                    fire(e, "crontab", e.level or "crontab", summary.cron)
                end
            end
        end
    end

    if dirty then cron.state_save(state) end
    return summary
end

return cron
