-- /lib/cwd.lua
-- Shared current working directory manager for ush.
-- All paths are stored as absolute, normalized POSIX-like paths.

local cwd = {}

local state = {
    current = "/",
}

local function split(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function normalize(path)
    if type(path) ~= "string" or path == "" then
        return "/"
    end

    if path:sub(1, 1) ~= "/" then
        path = state.current .. "/" .. path
    end

    local parts = split(path)
    local out = {}

    for i = 1, #parts do
        local part = parts[i]
        if part == "." then
            -- skip
        elseif part == ".." then
            if #out > 0 then
                out[#out] = nil
            end
        else
            out[#out + 1] = part
        end
    end

    return "/" .. table.concat(out, "/")
end

function cwd.get()
    return state.current
end

function cwd.set(path)
    local abs = normalize(path)

    if fs.exists(abs) and not fs.isDir(abs) then
        return nil, "not a directory: " .. abs
    end

    state.current = abs
    return abs
end

function cwd.resolve(path)
    return normalize(path)
end

function cwd.join(...)
    local parts = { ... }
    local path = table.concat(parts, "/")
    return normalize(path)
end

function cwd.is_absolute(path)
    return type(path) == "string" and path:sub(1, 1) == "/"
end

return cwd