-- sudocache.lua - short-lived cache for sudo authentication
local cache = {}

local CACHE_FILE  = "/var/lib/sudo_cache.dat"
local CONFIG_FILE = "/etc/sudo.conf"

local config = nil

local function load_config()
    if config then return config end
    config = { timeout = 300 }
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line ~= "" and line:sub(1,1) ~= "#" then
                    local k, v = line:match("^(%w+)=(.*)$")
                    if k == "timeout" then config.timeout = tonumber(v) or 300 end
                end
            end
            f.close()
        end
    end
    return config
end

function cache.get_timeout() return load_config().timeout end

local function load()
    if not fs.exists(CACHE_FILE) then return {} end
    local f = fs.open(CACHE_FILE, "r")
    if not f then return {} end
    local data = textutils.unserialize(f.readAll()) or {}
    f.close()
    return data
end

local function save(data)
    if not fs.exists("/var/lib") then fs.makeDir("/var/lib") end
    local f = fs.open(CACHE_FILE, "w")
    f.write(textutils.serialize(data))
    f.close()
end

function cache.is_valid(user)
    local data = load()
    local ts = data[user]
    if not ts then return false end
    local now = os.epoch("utc") / 1000
    return (now - ts) < cache.get_timeout()
end

function cache.touch(user)
    local data = load()
    data[user] = os.epoch("utc") / 1000
    save(data)
end

function cache.clear(user)
    local data = load()
    if user then data[user] = nil else data = {} end
    save(data)
end

return cache
