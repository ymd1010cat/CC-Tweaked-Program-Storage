-- path.lua - PATH resolution for ush
local path = {}

local CONFIG = "/etc/path.conf"
local DEFAULT_PATHS = { "/usr/cmd", "/usr/local/bin", "/bin" }

local function expand(entry)
    if not entry:find("*", 1, true) then return { entry } end
    local parts = {}
    for seg in entry:gmatch("[^/]+") do table.insert(parts, seg) end
    local results = { "/" }

    for _, seg in ipairs(parts) do
        local next_results = {}
        if seg == "*" then
            for _, base in ipairs(results) do
                local listpath = base == "/" and "/" or base
                if fs.exists(listpath) and fs.isDir(listpath) then
                    for _, name in ipairs(fs.list(listpath)) do
                        local full = (base == "/" and "/" or base .. "/") .. name
                        if fs.isDir(full) then table.insert(next_results, full) end
                    end
                end
            end
        else
            for _, base in ipairs(results) do
                local full = (base == "/" and "/" or base .. "/") .. seg
                table.insert(next_results, full)
            end
        end
        results = next_results
    end
    return results
end

function path.load()
    local entries = {}
    if fs.exists(CONFIG) then
        local f = fs.open(CONFIG, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line ~= "" and line:sub(1,1) ~= "#" then
                    table.insert(entries, line)
                end
            end
            f.close()
        end
    else
        entries = DEFAULT_PATHS
    end
    return entries
end

function path.dirs()
    local dirs = {}
    for _, entry in ipairs(path.load()) do
        for _, d in ipairs(expand(entry)) do
            table.insert(dirs, d)
        end
    end
    return dirs
end

function path.find(cmd)
    for _, dir in ipairs(path.dirs()) do
        local candidate = dir .. "/" .. cmd .. ".lua"
        if fs.exists(candidate) and not fs.isDir(candidate) then
            return candidate
        end
    end
    return nil
end

-- ------------------------------------------------------------
-- Script lookup: "ush hello" has to find hello.sh / hello.ush the same way it
-- finds hello.lua, so a script dropped into /usr/local/bin is callable by name.
-- ------------------------------------------------------------

local SCRIPT_SUFFIXES = { ".sh", ".ush" }

function path.script_suffixes()
    return SCRIPT_SUFFIXES
end

local function has_suffix(cmd, suffix)
    return #cmd >= #suffix and cmd:sub(-#suffix) == suffix
end

-- True when the name is meant to be read as a shell script by extension.
function path.is_script(cmd)
    if type(cmd) ~= "string" then return false end
    for _, suffix in ipairs(SCRIPT_SUFFIXES) do
        if has_suffix(cmd, suffix) then return true end
    end
    return false
end

-- Resolve a command name to a file on PATH: an explicit name (with a known
-- suffix) is looked up as is, a bare name is tried with every script suffix.
-- Names containing a slash are the caller's business, not ours.
function path.find_script(cmd)
    if type(cmd) ~= "string" or cmd == "" then return nil end
    if cmd:find("/", 1, true) then return nil end

    local dirs = path.dirs()
    local function try(name)
        for _, dir in ipairs(dirs) do
            local candidate = dir .. "/" .. name
            if fs.exists(candidate) and not fs.isDir(candidate) then
                return candidate
            end
        end
        return nil
    end

    if has_suffix(cmd, ".sh") or has_suffix(cmd, ".ush") or has_suffix(cmd, ".lua") then
        return try(cmd)
    end
    for _, suffix in ipairs(SCRIPT_SUFFIXES) do
        local found = try(cmd .. suffix)
        if found then return found end
    end
    return nil
end

return path
