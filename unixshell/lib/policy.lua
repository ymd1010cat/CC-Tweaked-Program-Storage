-- policy.lua - password and username policy
local policy = {}

local FILE = "/etc/passwd.policy"

local defaults = {
    min_length     = 6,
    require_digit  = true,
    require_letter = true,
    require_upper  = false,
    require_symbol = false,
    blacklist      = "root,daemon,bin,sys,adm,operator,mail,ftp,http",
}

local cached = nil

local function to_bool(v)
    return v == "true" or v == "1" or v == "yes"
end

local function load()
    if cached then return cached end
    local cfg = {}
    for k, v in pairs(defaults) do cfg[k] = v end

    if fs.exists(FILE) then
        local f = fs.open(FILE, "r")
        while true do
            local line = f.readLine()
            if line == nil then break end
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1,1) ~= "#" then
                local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
                if k and defaults[k] ~= nil then
                    if type(defaults[k]) == "number" then
                        cfg[k] = tonumber(v) or defaults[k]
                    elseif type(defaults[k]) == "boolean" then
                        cfg[k] = to_bool(v)
                    else
                        cfg[k] = v
                    end
                end
            end
        end
        f.close()
    end

    cached = cfg
    return cfg
end

function policy.reload()
    cached = nil
end

function policy.get(key)
    return load()[key]
end

-- Returns true or false, reason
function policy.check_password(pwd)
    local cfg = load()

    if #pwd < cfg.min_length then
        return false, "password too short (min " .. cfg.min_length .. ")"
    end
    if cfg.require_digit and not pwd:match("%d") then
        return false, "password must contain a digit"
    end
    if cfg.require_letter and not pwd:match("%a") then
        return false, "password must contain a letter"
    end
    if cfg.require_upper and not pwd:match("%u") then
        return false, "password must contain an uppercase letter"
    end
    if cfg.require_symbol and not pwd:match("[^%w]") then
        return false, "password must contain a symbol"
    end
    return true
end

-- Returns true if username is allowed to be registered
function policy.check_username(name)
    local cfg = load()
    if not name or name == "" then
        return false, "username is empty"
    end
    if #name > 32 then
        return false, "username too long"
    end
    if not name:match("^[%a_]") then
        return false, "must start with a letter or underscore"
    end
    if not name:match("^[%w_]+$") then
        return false, "only letters, digits and underscore allowed"
    end

    -- Blacklist check
    for blocked in cfg.blacklist:gmatch("[^,]+") do
        blocked = blocked:gsub("^%s+", ""):gsub("%s+$", "")
        if blocked == name then
            return false, "'" .. name .. "' is a reserved name"
        end
    end
    return true
end

-- Utility: ensure the config file exists
function policy.ensure_defaults()
    if fs.exists(FILE) then return end
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = fs.open(FILE, "w")
    f.write("# Password policy for firstboot and passwd\n")
    f.write("min_length=" .. defaults.min_length .. "\n")
    f.write("require_digit=" .. tostring(defaults.require_digit) .. "\n")
    f.write("require_letter=" .. tostring(defaults.require_letter) .. "\n")
    f.write("require_upper=" .. tostring(defaults.require_upper) .. "\n")
    f.write("require_symbol=" .. tostring(defaults.require_symbol) .. "\n")
    f.write("blacklist=" .. defaults.blacklist .. "\n")
    f.close()
end

return policy
