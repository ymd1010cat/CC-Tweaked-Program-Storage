-- itnpass_profile.lua -- ITN-Pass payload profiles (what a disk write installs).
-- Deploy as /itnpass_profile.lua; the station service, the disk writer, the
-- admin side and the batch tool all read the catalog through this one file.
--
-- A payload profile names one deployment payload (one operating system tree)
-- and fixes three things the station cannot guess:
--   * media / transactions -- how many disks one installation takes;
--   * parts               -- the payload sub-directories, one per disk, empty
--                            for a single-disk profile (the payload root is
--                            written as-is);
--   * capacity            -- the byte budget of one disk for that profile;
--   * default_uses        -- card key uses a batch should mint by default.
--
-- The numbers come from DECISIONS.md section 1-2 (floppy 1,228,800 B, computer
-- disk 1,000,000 B, pyromputer-os = 781,380 + 614,005 B over two disks). They
-- are DEFAULTS, not policy: /auth/itnpass_config.lua can override the byte
-- budget per profile with "profile_capacity", which is the documented knob for
-- a trimmed payload or a different medium.
--
-- Resolution order for the profile a station serves, identical for every
-- reader:
--   1. /auth/itnpass_profile.txt, when it exists and holds a known name;
--   2. otherwise the "profile" field of /auth/itnpass_config.lua;
--   3. otherwise the built-in default "default".
-- A mistyped override keeps the configured value; a mistyped config value
-- fails safe to "default". Names are case sensitive and lower case.

local M = {}

M.DEFAULT = "default"
M.PROFILE_FILE = "/auth/itnpass_profile.txt"
M.CONFIG_PATH = "/auth/itnpass_config.lua"
M.LOG_PATH = "/auth/itnpass_profile.log"
M.MAX_NAME_LEN = 32

-- Medium budgets, measured in the repository (DECISIONS.md section 1.1).
M.CAPACITY_FLOPPY = 1228800
M.CAPACITY_COMPUTER = 1000000

-- The catalog. Every entry is read-only in spirit: nothing but tests and the
-- config override changes a number at run time.
M.CATALOG = {
    ["default"] = {
        name = "default",
        media = "any",
        transactions = 1,
        parts = {},
        capacity = nil,
        default_uses = nil,
        note = "any single tree; no profile specific byte budget",
    },
    ["pyroet-os"] = {
        name = "pyroet-os",
        media = "floppy",
        transactions = 1,
        parts = {},
        capacity = M.CAPACITY_FLOPPY,
        default_uses = 1,
        note = "trimmed single floppy; only valid while the tree fits one disk",
    },
    ["pyromputer-os"] = {
        name = "pyromputer-os",
        media = "floppy",
        transactions = 2,
        parts = {"part1", "part2"},
        capacity = M.CAPACITY_FLOPPY,
        default_uses = 2,
        note = "two floppies, one write transaction per part",
    },
}

-- Sorted list of catalog names, so messages and tests are deterministic.
local NAMES = {"default", "pyroet-os", "pyromputer-os"}

function M.names()
    local out = {}
    for i = 1, #NAMES do
        out[i] = NAMES[i]
    end
    return out
end

function M.names_line()
    return table.concat(NAMES, ", ")
end

function M.is_known(name)
    return type(name) == "string" and M.CATALOG[name] ~= nil
end

-- get("name") -> the catalog entry, or nil for an unknown / malformed name.
function M.get(name)
    if type(name) ~= "string" then
        return nil
    end
    return M.CATALOG[name]
end

-- parse(value) -> catalog name, or nil.
-- Parses a whole file body: blank lines are ignored, "#" starts a comment
-- (whole line or trailing), and every remaining value must be the same known
-- name. Two different names in one file are ambiguous and rejected, exactly
-- like the run mode file. Names are case sensitive.
function M.parse(value)
    if type(value) ~= "string" then
        return nil
    end
    local found = nil
    for line in (value .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("#", 1, true)
        if cut then
            line = line:sub(1, cut - 1)
        end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            if not M.is_known(line) then
                return nil
            end
            if found ~= nil and found ~= line then
                return nil
            end
            found = line
        end
    end
    return found
end

-- One short printable line for log messages: never trust a file's content to
-- be single-line or short.
function M.summarize(text)
    if type(text) ~= "string" then
        return ""
    end
    local flat = text:gsub("%s+", " ")
    flat = flat:gsub("^ ", ""):gsub(" $", "")
    if #flat > 40 then
        flat = flat:sub(1, 40)
    end
    return flat
end

-- Appends one line to /auth/itnpass_profile.log. Logging never breaks the
-- caller: a missing /auth directory just means no line is written.
function M.log(message)
    local stamp = ""
    local okDate, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if okDate and type(value) == "string" then
        stamp = value .. "  "
    end
    local f = fs.open(M.LOG_PATH, "a")
    if not f then
        return false
    end
    f.write(stamp .. tostring(message) .. "\n")
    f.close()
    return true
end

-- read_override(path) -> profile, raw
--   "name", file text   the file exists and holds a known name
--   nil, file text      the file exists but holds nothing usable
--   nil, nil            no file (or it cannot be opened)
function M.read_override(path)
    local target = path or M.PROFILE_FILE
    if not fs.exists(target) then
        return nil, nil
    end
    local f = fs.open(target, "rb")
    if not f then
        return nil, nil
    end
    local raw = f.readAll()
    f.close()
    raw = raw or ""
    return M.parse(raw), raw
end

-- resolve(conf) -> name, source, problem
--   source: "file" | "config" | "default" | "config_bad"
--   problem: nil | "config_bad" | "file_bad"
function M.resolve(conf)
    local configured = nil
    if type(conf) == "table" then
        configured = conf.profile
    end
    local name = M.DEFAULT
    local source = "default"
    local problem = nil
    if configured ~= nil then
        if M.is_known(configured) then
            name = configured
            source = "config"
        else
            source = "config_bad"
            problem = "config_bad"
            M.log("ITNP_CONFIG_BAD key=profile value=" .. M.summarize(tostring(configured))
                .. " fallback=" .. M.DEFAULT)
        end
    end
    local override, raw = M.read_override()
    if override ~= nil then
        name = override
        source = "file"
    elseif raw ~= nil then
        if problem == nil then
            problem = "file_bad"
        end
        M.log("ITNP_PROFILE_BAD path=" .. M.PROFILE_FILE .. " value=" .. M.summarize(raw)
            .. " keep=" .. name)
    end
    return name, source, problem
end

-- current() -> profile, source : the profile of the station as configured.
-- /auth/itnpass_config.lua already applies resolve() when it loads and marks
-- the result with "profile_source"; a table built by hand is resolved here so
-- the priority stays the same (profile file first, then the config value).
function M.current()
    local ok, conf = pcall(dofile, M.CONFIG_PATH)
    if ok and type(conf) == "table" then
        if conf.profile_source ~= nil and M.is_known(conf.profile) then
            return conf.profile, conf.profile_source
        end
        return M.resolve(conf)
    end
    return M.resolve(nil)
end

-- capacity(name, conf) -> bytes, or nil when the profile has no byte budget.
-- "profile_capacity" in the config wins over the catalog, so an operator can
-- declare a different medium without editing code.
function M.capacity(name, conf)
    local entry = M.get(name)
    if entry == nil then
        return nil
    end
    local override = nil
    if type(conf) == "table" and type(conf.profile_capacity) == "table" then
        override = tonumber(conf.profile_capacity[name])
    end
    if override ~= nil and override > 0 then
        return math.floor(override)
    end
    return entry.capacity
end

-- default_uses(name) -> the card key use count a batch should mint by default,
-- nil when the profile leaves that decision to the config ("default_uses").
function M.default_uses(name)
    local entry = M.get(name)
    if entry == nil then
        return nil
    end
    return entry.default_uses
end

-- parts(name) -> list of payload sub-directories (empty for a single tree).
function M.parts(name)
    local entry = M.get(name)
    if entry == nil then
        return {}
    end
    local out = {}
    for i = 1, #entry.parts do
        out[i] = entry.parts[i]
    end
    return out
end

return M
