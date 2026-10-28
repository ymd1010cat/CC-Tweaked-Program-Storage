-- history.lua - command history for psh
-- Entries are kept in memory (oldest first) and persisted one per line to the
-- user's history file. Supports "!!" (previous command) and "!n" (n-th command)
-- expansion; "!" inside single quotes is left alone.

local history = {}

local DEFAULT_MAX = 200

local entries = {}
local max_entries = DEFAULT_MAX
local file_path = nil
local last_save_error = nil

function history.init(path, max)
    file_path = path
    max_entries = max or DEFAULT_MAX
    entries = {}
    last_save_error = nil
    if not path then return true end
    local ok, exists = pcall(fs.exists, path)
    if not ok or not exists then return true end
    local handle = fs.open(path, "r")
    if not handle then return true end
    while true do
        local line = handle.readLine()
        if line == nil then break end
        line = line:gsub("\r$", "")
        if line ~= "" then entries[#entries + 1] = line end
    end
    handle.close()
    while #entries > max_entries do table.remove(entries, 1) end
    return true
end

function history.path() return file_path end
function history.count() return #entries end
function history.max() return max_entries end
function history.error() return last_save_error end

function history.all()
    local out = {}
    for i, e in ipairs(entries) do out[i] = e end
    return out
end

-- 1-based lookup, as printed by the "history" built-in.
function history.get(n)
    n = tonumber(n)
    if n == nil then return nil end
    n = math.floor(n)
    if n < 1 or n > #entries then return nil end
    return entries[n]
end

function history.last()
    return entries[#entries]
end

function history.save()
    if not file_path then return false end
    local dir = file_path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" and not fs.exists(dir) then
        pcall(fs.makeDir, dir)
    end
    local handle = fs.open(file_path, "w")
    if not handle then
        last_save_error = "cannot write " .. file_path
        return false
    end
    for _, e in ipairs(entries) do handle.writeLine(e) end
    handle.close()
    last_save_error = nil
    return true
end

-- Append one command; blanks and immediate repeats are dropped (like bash).
function history.add(line)
    if type(line) ~= "string" then return false end
    line = line:gsub("[\r\n]+", " ")
    if line == "" then return false end
    if entries[#entries] == line then return false end
    entries[#entries + 1] = line
    while #entries > max_entries do table.remove(entries, 1) end
    history.save()
    return true
end

function history.clear()
    entries = {}
    history.save()
    return true
end

-- Expand history references in a complete input line. Returns the expanded
-- line, or nil plus an error message when a reference cannot be resolved.
function history.expand(line)
    if type(line) ~= "string" or not line:find("!", 1, true) then return line end
    local out = {}
    local i = 1
    local quote = nil

    while i <= #line do
        local c = line:sub(i, i)
        if quote == "'" then
            out[#out + 1] = c
            if c == "'" then quote = nil end
            i = i + 1
        elseif c == "\\" and i < #line then
            out[#out + 1] = line:sub(i, i + 1)
            i = i + 2
        elseif quote == '"' then
            out[#out + 1] = c
            if c == '"' then quote = nil end
            i = i + 1
        elseif c == "'" or c == '"' then
            quote = c
            out[#out + 1] = c
            i = i + 1
        elseif c == "!" then
            local nxt = line:sub(i + 1, i + 1)
            if nxt == "!" then
                local cmd = history.last()
                if not cmd then return nil, "!!: event not found" end
                out[#out + 1] = cmd
                i = i + 2
            else
                local digits = line:sub(i + 1):match("^(%d+)")
                if digits then
                    local cmd = history.get(digits)
                    if not cmd then return nil, "!" .. digits .. ": event not found" end
                    out[#out + 1] = cmd
                    i = i + 1 + #digits
                else
                    out[#out + 1] = c
                    i = i + 1
                end
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out)
end

return history
