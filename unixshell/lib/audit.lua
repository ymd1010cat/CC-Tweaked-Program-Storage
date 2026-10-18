-- audit.lua - audit log for privileged operations
--
-- /var/log/auth.log is an append-only list of "[time] key=value" records.
-- Rotation is delegated to lib/logrotate.lua: the log is cut when it reaches
-- MAX_LINES lines or MAX_BYTES bytes, up to MAX_ARCHIVES generations are kept
-- as auth.log.1 (newest) ... auth.log.N (oldest), and older generations are
-- dropped. lib/logrotate.lua also owns the "logrotate" command, so the limits
-- can be inspected and the log cut by hand.
local audit = {}

local LOG = "/var/log/auth.log"
local MAX_LINES = 5000
local MAX_BYTES = 512 * 1024
local MAX_ARCHIVES = 3

audit.log_file = LOG
audit.max_lines = MAX_LINES
audit.max_bytes = MAX_BYTES
audit.keep = MAX_ARCHIVES

local function timestamp()
    local ok, t = pcall(require, "time")
    if ok then return t.format("%Y-%m-%d %H:%M:%S") end
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function ensure()
    if not fs.exists("/var/log") then fs.makeDir("/var/log") end
end

audit.limits = { max_lines = MAX_LINES, max_size = MAX_BYTES, keep = MAX_ARCHIVES }

local function rotate()
    if not fs.exists(LOG) then return nil end
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.check then
        return lr.check(LOG, audit.limits)
    end
    -- Fallback for a setup without lib/logrotate.lua: single generation.
    local f = fs.open(LOG, "r")
    if not f then return nil end
    local n = 0
    while true do
        local _ = f.readLine()
        if _ == nil then break end
        n = n + 1
    end
    f.close()
    if n >= MAX_LINES then
        if fs.exists(LOG .. ".1") then fs.delete(LOG .. ".1") end
        fs.move(LOG, LOG .. ".1")
        return "lines"
    end
    return nil
end

-- Cut the log now, ignoring the limits ("logrotate force auth" also does this).
function audit.rotate_now()
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.rotate then
        return lr.rotate(LOG, audit.limits, true)
    end
    return rotate()
end

-- Existing generations, newest first: {{index, path, lines, size}, ...}.
function audit.archives()
    local ok, lr = pcall(require, "logrotate")
    if ok and lr and lr.archives then
        return lr.archives(LOG, audit.limits)
    end
    local out = {}
    if fs.exists(LOG .. ".1") then
        out[1] = { index = 1, path = LOG .. ".1", lines = nil }
    end
    return out
end


function audit.log(entry)
    ensure(); rotate()
    local parts = {
        "[" .. timestamp() .. "]",
        "actor=" .. (entry.actor or "?"),
        "action=" .. (entry.action or "?"),
        "target=" .. (entry.target or "?"),
        "result=" .. (entry.result or "?"),
    }
    if entry.command then
        parts[#parts + 1] = 'command="' .. entry.command .. '"'
    end
    if entry.note then
        parts[#parts + 1] = 'note="' .. entry.note .. '"'
    end
    local line = table.concat(parts, " ")
    local f = fs.open(LOG, "a")
    f.write(line .. "\n")
    f.close()
    return line
end

function audit.tail(n)
    n = n or 20
    if not fs.exists(LOG) then return {} end
    local buf = {}
    local f = fs.open(LOG, "r")
    while true do
        local line = f.readLine()
        if line == nil then break end
        table.insert(buf, line)
        if #buf > n then table.remove(buf, 1) end
    end
    f.close()
    return buf
end

return audit
