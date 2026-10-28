-- time.lua - configurable timezone helper
local time = {}

local FILE = "/etc/timezone.conf"
local DEFAULT_OFFSET = 0
local DEFAULT_LABEL = "UTC"

local cached = nil

local function load()
    if cached then return cached end
    local cfg = { offset = DEFAULT_OFFSET, label = DEFAULT_LABEL }
    if fs.exists(FILE) then
        local f = fs.open(FILE, "r")
        while true do
            local line = f.readLine()
            if line == nil then break end
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1,1) ~= "#" then
                local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
                if k == "offset" then cfg.offset = tonumber(v) or 0 end
                if k == "label" then cfg.label = v end
            end
        end
        f.close()
    end
    cached = cfg
    return cfg
end

function time.reload() cached = nil end

function time.get_offset() return load().offset end
function time.get_label() return load().label end

-- Returns a Unix-like timestamp shifted into the configured zone
function time.now()
    local cfg = load()
    return os.time() + cfg.offset * 3600
end

-- Formats a string using the configured zone.
-- Accepts the same format characters as os.date.
function time.format(fmt)
    local shifted = time.now()
    return os.date(fmt, shifted) .. " " .. load().label
end

function time.ensure_defaults()
    if fs.exists(FILE) then return end
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local f = fs.open(FILE, "w")
    f.write("# Timezone configuration\n")
    f.write("offset=0\n")
    f.write("label=UTC\n")
    f.close()
end

return time
