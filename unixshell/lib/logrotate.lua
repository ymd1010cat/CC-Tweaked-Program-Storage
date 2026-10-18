-- logrotate.lua - size / line based log rotation for ush
--
-- The log writers of the project (audit, sessionlog, cron, services, disk)
-- call logrotate.check() before they append, so a log that reached its limits
-- is cut before it can grow any further; logrotate.sweep() catches the files
-- that are written by a single shot process (the watchdog log, for example).
--
-- Archive naming follows the convention that auth.log and wtmp already used:
-- the live file stays where it is and the previous generation moves to
-- "<path>.1", the one before that to "<path>.2", and so on up to "keep"
-- generations; the oldest generation beyond "keep" is dropped. After a cut the
-- live file is recreated empty, so readers and writers always find a target.
--
-- /etc/logrotate.conf, one target per line, every field optional:
--
--   # path                     max_lines=5000 max_size=256k keep=3
--   /var/log/auth.log          max_lines=5000 max_size=256k keep=3
--   /var/log/wtmp              keep=2
--
-- Without a configuration file the files listed in logrotate.sweep_paths are
-- rotated with logrotate.defaults.
local logrotate = {}

local CONF = "/etc/logrotate.conf"

logrotate.conf_file = CONF
logrotate.defaults = { max_lines = 5000, max_size = 262144, keep = 3 }
logrotate.sweep_paths = {
    "/var/log/auth.log",
    "/var/log/wtmp",
    "/var/log/cron.log",
    "/var/log/service.log",
    "/var/log/disk.log",
    "/var/log/watchdog.log",
}

local last_sweep = 0
local SWEEP_INTERVAL = 3600     -- seconds between two background sweeps

local function now_seconds()
    local ok, e = pcall(os.epoch, "utc")
    if ok and type(e) == "number" then return math.floor(e / 1000) end
    return os.time()
end

local function ensure_dir(path)
    if fs.exists(path) then return true end
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
    return fs.exists(path)
end

-- ------------------------------------------------------------------
-- Limits and configuration
-- ------------------------------------------------------------------

-- "1024", "256k", "2M", "1g" -> bytes.
function logrotate.parse_size(text)
    if type(text) == "number" then return math.floor(text) end
    if type(text) ~= "string" then return nil end
    local num, unit = text:match("^%s*(%d+)%s*([kKmMgG]?)%s*$")
    if not num then return nil end
    local n = tonumber(num)
    unit = unit:lower()
    if unit == "k" then return n * 1024 end
    if unit == "m" then return n * 1024 * 1024 end
    if unit == "g" then return n * 1024 * 1024 * 1024 end
    return n
end

-- Parse the configuration text into a list of targets
-- { path, max_lines, max_size, keep }. Unknown keys are reported in the second
-- return value so that the command can show them.
function logrotate.parse_config(text)
    local targets, bad = {}, {}
    if type(text) ~= "string" then return targets, bad end
    for raw in text:gmatch("[^\n]+") do
        local line = raw:gsub("\r", "")
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local words = {}
            for w in trimmed:gmatch("%S+") do words[#words + 1] = w end
            local target = {}
            for _, w in ipairs(words) do
                local key, value = w:match("^([%w_]+)=(.*)$")
                if key then
                    key = key:lower()
                    if key == "path" then
                        target.path = value
                    elseif key == "max_lines" then
                        target.max_lines = tonumber(value)
                    elseif key == "max_size" then
                        target.max_size = logrotate.parse_size(value)
                    elseif key == "keep" then
                        target.keep = tonumber(value)
                    else
                        bad[#bad + 1] = key
                    end
                elseif w:sub(1, 1) == "/" then
                    target.path = w
                else
                    bad[#bad + 1] = w
                end
            end
            if target.path then targets[#targets + 1] = target end
        end
    end
    return targets, bad
end

function logrotate.config()
    if not fs.exists(CONF) then return {} end
    local f = fs.open(CONF, "r")
    if not f then return {} end
    local text = f.readAll()
    f.close()
    local targets = logrotate.parse_config(text)
    return targets
end

-- Targets to sweep: the configuration when there is one, otherwise the well
-- known log files of the project with the default limits.
function logrotate.targets()
    local cfg = logrotate.config()
    if #cfg > 0 then return cfg end
    local out = {}
    for _, p in ipairs(logrotate.sweep_paths) do
        out[#out + 1] = {
            path = p,
            max_lines = logrotate.defaults.max_lines,
            max_size = logrotate.defaults.max_size,
            keep = logrotate.defaults.keep,
        }
    end
    return out
end

-- Effective limits for one path: caller options win over the configuration,
-- which wins over the defaults.
function logrotate.merged(path, opts)
    local conf = nil
    for _, t in ipairs(logrotate.config()) do
        if t.path == path then conf = t break end
    end
    local function pick(key)
        if opts and opts[key] ~= nil then return opts[key] end
        if conf and conf[key] ~= nil then return conf[key] end
        return logrotate.defaults[key]
    end
    return {
        max_lines = pick("max_lines"),
        max_size = pick("max_size"),
        keep = pick("keep"),
    }
end

-- ------------------------------------------------------------------
-- Inspection
-- ------------------------------------------------------------------

function logrotate.count_lines(path)
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

-- Line count and byte size of a file; a missing file reports exists = false.
function logrotate.stats(path)
    if not fs.exists(path) then return { exists = false, lines = 0, size = 0 } end
    local f = fs.open(path, "r")
    if not f then return { exists = false, lines = 0, size = 0 } end
    local text = f.readAll()
    f.close()
    text = text or ""
    local lines = 0
    for _ in text:gmatch("[^\n]*\n") do lines = lines + 1 end
    if #text > 0 and text:sub(-1) ~= "\n" then lines = lines + 1 end
    return { exists = true, lines = lines, size = #text }
end

-- Why the file should be cut: "lines", "size" or nil when it is still within
-- its limits.
function logrotate.reason(path, opts)
    local lim = logrotate.merged(path, opts)
    local st = logrotate.stats(path)
    if not st.exists then return nil end
    if lim.max_lines and st.lines >= lim.max_lines then return "lines" end
    if lim.max_size and st.size >= lim.max_size then return "size" end
    return nil
end

function logrotate.archive_name(path, index)
    return path .. "." .. tostring(index)
end

function logrotate.human(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1048576 then return string.format("%.1fM", bytes / 1048576) end
    if bytes >= 1024 then return string.format("%.1fK", bytes / 1024) end
    return tostring(bytes) .. "B"
end

-- ------------------------------------------------------------------
-- Rotation
-- ------------------------------------------------------------------

-- Cut the file now. With force the limits are not consulted, which is what the
-- "rotate" subcommand uses. Returns a record describing the cut.
function logrotate.rotate(path, opts, force)
    local lim = logrotate.merged(path, opts)
    local why = force and "forced" or logrotate.reason(path, opts)
    if not why then return nil, "nothing to rotate" end

    local st = logrotate.stats(path)
    local keep = lim.keep or logrotate.defaults.keep
    if keep < 1 then keep = 1 end

    local oldest = logrotate.archive_name(path, keep)
    if fs.exists(oldest) and not fs.delete(oldest) then
        return nil, "cannot delete " .. oldest
    end
    for i = keep - 1, 1, -1 do
        local from = logrotate.archive_name(path, i)
        if fs.exists(from) then
            local to = logrotate.archive_name(path, i + 1)
            if fs.exists(to) then fs.delete(to) end
            if not fs.move(from, to) then
                return nil, "cannot move " .. from .. " to " .. to
            end
        end
    end

    local first = logrotate.archive_name(path, 1)
    if fs.exists(first) then fs.delete(first) end
    if not fs.move(path, first) then
        return nil, "cannot move " .. path .. " to " .. first
    end

    -- Recreate the live file empty: a log that does not exist yet is harder to
    -- use than an empty one, and the root of the log directory stays writable.
    local dir = path:match("^(.*)/[^/]+$")
    if dir then ensure_dir(dir) end
    local h = fs.open(path, "w")
    if h then
        h.write("")
        h.close()
    end

    return {
        path = path,
        archive = first,
        reason = why,
        lines = st.lines,
        size = st.size,
        keep = keep,
    }
end

-- Called by the log writers before an append. Cheap when the file is small.
function logrotate.check(path, opts)
    local lim = logrotate.merged(path, opts)
    local st = logrotate.stats(path)
    if not st.exists then return false end
    local why
    if lim.max_lines and st.lines >= lim.max_lines then
        why = "lines"
    elseif lim.max_size and st.size >= lim.max_size then
        why = "size"
    end
    if not why then return false end
    local rec, err = logrotate.rotate(path, opts)
    if not rec then return false, err end
    return true, rec
end

-- Housekeeping over every configured target. Throttled, so it is safe to call
-- from the shell start path; force = true sweeps immediately.
function logrotate.sweep(force)
    local now = now_seconds()
    if not force and (now - last_sweep) < SWEEP_INTERVAL then
        return { skipped = true, rotated = {} }
    end
    last_sweep = now
    local out = { rotated = {}, errors = {} }
    for _, t in ipairs(logrotate.targets()) do
        local ok, rec = logrotate.check(t.path, t)
        if ok then
            out.rotated[#out.rotated + 1] = rec
        elseif rec then
            out.errors[#out.errors + 1] = t.path .. ": " .. tostring(rec)
        end
    end
    return out
end

-- ------------------------------------------------------------------
-- Reading and listing the archives
-- ------------------------------------------------------------------

-- The last n lines of a file; 0 or a negative n reads everything.
function logrotate.read_lines(path, n)
    n = n or 20
    local out = {}
    if not fs.exists(path) then return out end
    local f = fs.open(path, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        out[#out + 1] = line
        if n > 0 and #out > n then table.remove(out, 1) end
    end
    f.close()
    return out
end

-- Archives that exist right now, oldest last: {{ index, path, lines, size }}.
function logrotate.archives(path, opts)
    local lim = logrotate.merged(path, opts)
    local keep = lim.keep or logrotate.defaults.keep
    if keep < 1 then keep = 1 end
    local out = {}
    for i = 1, keep do
        local p = logrotate.archive_name(path, i)
        local st = logrotate.stats(p)
        if st.exists then
            out[#out + 1] = { index = i, path = p, lines = st.lines, size = st.size }
        end
    end
    return out
end

function logrotate.read_archive(path, index, n)
    index = tonumber(index) or 1
    return logrotate.read_lines(logrotate.archive_name(path, index), n)
end

-- One row per target: used by the "logrotate" command without arguments.
function logrotate.status()
    local rows = {}
    for _, t in ipairs(logrotate.targets()) do
        local st = logrotate.stats(t.path)
        local lim = logrotate.merged(t.path, t)
        rows[#rows + 1] = {
            path = t.path,
            exists = st.exists,
            lines = st.lines,
            size = st.size,
            max_lines = lim.max_lines,
            max_size = lim.max_size,
            keep = lim.keep,
            archives = #logrotate.archives(t.path, t),
        }
    end
    return rows
end

-- ------------------------------------------------------------------
-- logrotate(8) command
-- ------------------------------------------------------------------

local USAGE = {
    "usage: logrotate [status]              one line per configured target",
    "       logrotate list [PATH]           archives of a target",
    "       logrotate show [-a N] [-n N] [PATH]",
    "                                       last N lines of a log or of archive N",
    "       logrotate rotate [PATH]         cut the log now (limits ignored)",
}

function logrotate.main(args, stage)
    stage = stage or { write = function(s) print(s) end }
    local function emit(text) stage.write(text .. "\n") end
    args = args or {}

    local mode, path, index, count = "status", nil, 1, 20
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-s" or a == "show" then
            mode = "show"
            if args[i + 1] and args[i + 1]:sub(1, 1) ~= "-" then
                path = args[i + 1]
                i = i + 1
            end
        elseif a == "list" or a == "-l" then
            mode = "list"
            if args[i + 1] and args[i + 1]:sub(1, 1) ~= "-" then
                path = args[i + 1]
                i = i + 1
            end
        elseif a == "rotate" or a == "-f" then
            mode = "rotate"
            if args[i + 1] and args[i + 1]:sub(1, 1) ~= "-" then
                path = args[i + 1]
                i = i + 1
            end
        elseif a == "-a" then
            index = tonumber(args[i + 1]) or 1
            i = i + 1
        elseif a == "-n" then
            count = tonumber(args[i + 1]) or 20
            i = i + 1
        elseif a == "-h" or a == "--help" or a == "help" then
            mode = "help"
        elseif a:sub(1, 1) ~= "-" and not path then
            path = a
        else
            emit("logrotate: " .. a .. ": unknown option")
            return 1
        end
        i = i + 1
    end

    if mode == "help" then
        for _, line in ipairs(USAGE) do emit(line) end
        return 0
    end

    if mode == "status" then
        emit(string.format("%-28s %5s %6s %8s %8s %4s %4s",
            "LOG", "LINES", "LIMIT", "SIZE", "MAX", "KEEP", "ARCH"))
        for _, r in ipairs(logrotate.status()) do
            emit(string.format("%-28s %5d %6d %8s %8s %4d %4d",
                r.path, r.lines, r.max_lines or 0,
                logrotate.human(r.size), logrotate.human(r.max_size or 0),
                r.keep or 0, r.archives))
        end
        return 0
    end

    if mode == "list" then
        local paths = {}
        if path then
            paths[1] = path
        else
            for _, r in ipairs(logrotate.status()) do paths[#paths + 1] = r.path end
        end
        local missing = 0
        for _, p in ipairs(paths) do
            local found = logrotate.archives(p)
            if #found == 0 then
                missing = missing + 1
                emit("logrotate: " .. p .. ": no archives")
            else
                emit(p)
                for _, a in ipairs(found) do
                    emit(string.format("  %-30s %5d lines  %8s",
                        a.path, a.lines, logrotate.human(a.size)))
                end
            end
        end
        return missing > 0 and 1 or 0
    end

    if mode == "show" then
        if not path then
            emit("logrotate: show needs a log path")
            return 1
        end
        local target = logrotate.archive_name(path, index)
        local is_archive = index > 1 or not fs.exists(path)
        if is_archive and not fs.exists(target) then
            emit("logrotate: " .. target .. ": no such archive")
            return 1
        end
        if is_archive then
            target = logrotate.archive_name(path, index)
            local st = logrotate.stats(target)
            emit(target .. ": archive " .. tostring(index) ..
                 ", " .. tostring(st.lines) .. " lines (last " .. tostring(count) .. ")")
        else
            target = path
            local st = logrotate.stats(target)
            emit(target .. ": live log, " .. tostring(st.lines) ..
                 " lines (last " .. tostring(count) .. ")")
        end
        for _, line in ipairs(logrotate.read_lines(target, count)) do emit(line) end
        return 0
    end

    -- rotate
    local done, failed = 0, 0
    local paths = {}
    if path then
        paths[1] = { path = path }
    else
        paths = logrotate.targets()
    end
    for _, t in ipairs(paths) do
        local rec, err = logrotate.rotate(t.path, nil, true)
        if rec then
            done = done + 1
            emit(string.format("logrotate: %s -> %s (%d lines, %s, reason=%s)",
                rec.path, rec.archive, rec.lines,
                logrotate.human(rec.size), rec.reason))
        else
            failed = failed + 1
            emit("logrotate: " .. t.path .. ": " .. tostring(err))
        end
    end
    return failed > 0 and 1 or 0
end

return logrotate
