-- cardkey_mode.lua -- CardKey run mode (pass = card key required, free = open).
-- Deploy as /cardkey_mode.lua, next to /sha256.lua. The server, the admin
-- console and every terminal read their mode through this one file.
--
-- Resolution order, identical for every reader:
--   1. /auth/cardkey_mode.txt, when it exists and holds a valid value;
--   2. otherwise the "mode" field of /auth/cardkey_config.lua;
--   3. otherwise the built-in default "pass".
--
-- Anything invalid fails safe to "pass": a mistyped override or a broken config
-- value can never turn a paid station into a free one by accident.
--
-- A MISSING RESOLVER IS NOT A FAULT. CardKey is a deployed project, so a
-- machine that never received /cardkey_mode.lua (an old installation, a
-- terminal nobody updated) must keep running exactly as before. Every reader
-- loads this file through pcall(dofile, ...) and treats a missing file as
-- "pass"; nothing in the deployment fails because of it. (This is the one
-- deliberate difference from itn-pass, where the resolver is mandatory.)
--
-- The free mode only decides whether a card key is needed -- disk validation,
-- rollback, free-space checks and the terminal network check keep running in
-- both modes. See README section 15.

local M = {}

M.PASS = "pass"
M.FREE = "free"
M.DEFAULT = "pass"
M.MODE_FILE = "/auth/cardkey_mode.txt"
M.CONFIG_PATH = "/auth/cardkey_config.lua"
M.LOG_PATH = "/auth/cardkey_mode.log"

function M.is_valid(value)
    return value == M.PASS or value == M.FREE
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

-- Parses the whole file body. Blank lines are ignored, "#" starts a comment
-- (whole line or trailing), and the remaining tokens must all be the same
-- valid mode. Returns "pass" / "free", or nil when nothing valid is left.
function M.parse(text)
    if type(text) ~= "string" then
        return nil
    end
    local found = nil
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("#", 1, true)
        if cut then
            line = line:sub(1, cut - 1)
        end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            if not M.is_valid(line) then
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

-- Appends one line to /auth/cardkey_mode.log. Logging never breaks the caller:
-- a missing /auth directory or a full disk just means no line is written.
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

-- read_override(path) -> mode, raw
--   "pass"/"free", file text   the file exists and holds a valid value
--   nil, file text             the file exists but holds nothing usable
--   nil, nil                   no file (or it cannot be opened)
function M.read_override(path)
    local target = path or M.MODE_FILE
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

-- resolve(conf) -> mode, source, problem
--   source: "file" | "config" | "default" | "config_bad"
--   problem: nil | "config_bad" | "file_bad"
-- The override file wins over the config value, exactly as documented.
function M.resolve(conf)
    local configMode = nil
    if type(conf) == "table" then
        configMode = conf.mode
    end
    local mode = M.DEFAULT
    local source = "default"
    local problem = nil
    if configMode ~= nil then
        if M.is_valid(configMode) then
            mode = configMode
            source = "config"
        else
            source = "config_bad"
            problem = "config_bad"
            M.log("MODE_CONFIG_BAD key=mode value=" .. M.summarize(tostring(configMode))
                .. " fallback=" .. M.DEFAULT)
        end
    end
    local override, raw = M.read_override()
    if override ~= nil then
        mode = override
        source = "file"
        -- A rejected config value stays reportable through "problem" even
        -- though the file won; the log line above already recorded it.
    elseif raw ~= nil then
        if problem == nil then
            problem = "file_bad"
        end
        M.log("MODE_FILE_BAD path=" .. M.MODE_FILE .. " value=" .. M.summarize(raw)
            .. " keep=" .. mode)
    end
    return mode, source, problem
end

-- current() -> mode, source : the mode in force for this boot.
-- /auth/cardkey_config.lua already applies resolve() when it loads and marks
-- the result with "mode_source", so such a table is final. A config table
-- built by hand (tests, a terminal without a config file) has no marker and is
-- resolved here, which keeps the same priority: mode file first, then the
-- config value.
function M.current()
    local ok, conf = pcall(dofile, M.CONFIG_PATH)
    if ok and type(conf) == "table" then
        if conf.mode_source ~= nil and M.is_valid(conf.mode) then
            return conf.mode, conf.mode_source
        end
        return M.resolve(conf)
    end
    return M.resolve(nil)
end

return M
