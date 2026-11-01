-- power.lua - PowerGrid.ini parsing/writing plus the power-mode primitive.
--
-- PowerGrid.ini is the single configuration file for the whole project:
--   * new format: one "key=value" per line; blank lines and lines whose first
--     non-space character is '#' are comments;
--   * old format: the whole file is a bare number 0-3, which is what the
--     archived controller wrote. It keeps working: it is read as mode=<number>
--     with every watchdog setting at its default, and M.apply() keeps writing
--     the bare number for such a file, so an old controller's file is never
--     silently upgraded.
--
-- M.read() still returns mode, errorCode, rawLine and still reports the archived
-- error codes (FILE_NOT_FOUND / VALUE_LENGTH_IS_ZERO / VALUE_TYPE_NOT_CORRECT /
-- INI_VALUE_OUT_RANGE). The only new code is MODE_MISSING, used when a
-- key=value file simply has no mode= line.
--
-- Writes are format preserving: in a key=value file M.apply() rewrites only the
-- mode line, in place; comments, unknown keys, blank lines and the line order
-- stay untouched. When there is no mode line yet it is appended at the end.
--
-- opts (all optional, for tests): path, side, redstone, peripheral.

local M = {}

M.VERSION = "1.1"

M.PATH = "PowerGrid.ini"
M.SIDE = "back"
M.SOUND = "create:confirm"
M.MIN = 0
M.MAX = 3
M.MODE_KEY = "mode"

-- field name -> ini key, for the watchdog section.
M.WATCHDOG_KEYS = {
    enabled = "watchdog.enabled",
    low = "watchdog.low",
    high = "watchdog.high",
    window = "watchdog.window",
    poll = "watchdog.poll",
    input_side = "watchdog.input_side",
    alarm_side = "watchdog.alarm_side",
    switch_to = "watchdog.switch_to",
    restore = "watchdog.restore",
}

local KNOWN = {}
for _, key in pairs(M.WATCHDOG_KEYS) do
    KNOWN[key] = true
end
KNOWN[M.MODE_KEY] = true

local function trim(text)
    if type(text) ~= "string" then return text end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

-- "key = value" -> key, value; anything else -> nil.
function M.parseLine(text)
    if type(text) ~= "string" then return nil end
    local key, value = text:match("^([%a_][%w_%.%-]*)%s*=%s*(.-)%s*$")
    if key == nil then return nil end
    return key, value
end

-- Split into lines, keeping each line's own terminator so a rewrite preserves
-- the original newline style.
local function splitLines(text)
    local lines = {}
    local pos = 1
    while true do
        local nl = text:find("\n", pos, true)
        if nl == nil then
            lines[#lines + 1] = { body = text:sub(pos), eol = "" }
            break
        end
        local body = text:sub(pos, nl - 1)
        local eol = "\n"
        if body:sub(-1) == "\r" then
            body = body:sub(1, #body - 1)
            eol = "\r\n"
        end
        lines[#lines + 1] = { body = body, eol = eol }
        pos = nl + 1
    end
    return lines
end
M.splitLines = splitLines

-- Parse the whole file text into a report:
--   format        "keyvalue" | "legacy" | "comments" | "empty" | "missing"
--   first_content first non-comment non-blank line (the legacy mode line)
--   raw           key -> value (last duplicate wins)
--   bad_lines     non-comment lines that are not key=value
--   key_count / content_count / comment_count
function M.parse(text)
    local info = {
        format = "missing",
        first_content = nil,
        raw = {},
        bad_lines = {},
        key_count = 0,
        content_count = 0,
        comment_count = 0,
    }
    if type(text) ~= "string" then
        return info
    end
    local lines = splitLines(text)
    for i = 1, #lines do
        local body = trim(lines[i].body)
        if body == "" then
            -- blank line: preserved by writers, ignored here
        elseif body:sub(1, 1) == "#" then
            info.comment_count = info.comment_count + 1
        else
            info.content_count = info.content_count + 1
            if info.first_content == nil then info.first_content = body end
            local key, value = M.parseLine(body)
            if key ~= nil then
                info.key_count = info.key_count + 1
                info.raw[key] = value
            else
                info.bad_lines[#info.bad_lines + 1] = body
            end
        end
    end
    if info.key_count > 0 then
        info.format = "keyvalue"
    elseif info.content_count > 0 then
        info.format = "legacy"
    elseif info.comment_count > 0 then
        info.format = "comments"
    else
        info.format = "empty"
    end
    return info
end

-- Validate the first line of the config. Returns value, errorCode, rawLine.
-- The error codes and their precedence match the archived startup.lua.
function M.validate(line)
    if line == nil or #line == 0 then
        return nil, "VALUE_LENGTH_IS_ZERO", line
    end
    local value = tonumber(line)
    if value == nil then
        return nil, "VALUE_TYPE_NOT_CORRECT", line
    end
    if value < M.MIN or value > M.MAX then
        return value, "INI_VALUE_OUT_RANGE", line
    end
    return value, nil, line
end

-- Extract the mode from a parse report. Returns value, errorCode, rawLine.
function M.modeFrom(info)
    if type(info) ~= "table" then
        return M.validate(nil)
    end
    if info.format == "keyvalue" then
        local value = info.raw[M.MODE_KEY]
        if value == nil then
            return nil, "MODE_MISSING", nil
        end
        return M.validate(trim(value))
    end
    return M.validate(info.first_content)
end

-- Read a file as text. Returns text, or nil, "FILE_NOT_FOUND".
function M.readText(path)
    local okOpen, file = pcall(io.open, path, "r")
    if not okOpen or file == nil then
        return nil, "FILE_NOT_FOUND"
    end
    local okRead, text = pcall(file.read, file, "*a")
    file:close()
    if not okRead or type(text) ~= "string" then
        return nil, "FILE_NOT_FOUND"
    end
    return text
end

-- Read the current mode. Returns value, errorCode, rawLine; errorCode is nil on
-- success.
function M.read(opts)
    if type(opts) ~= "table" then opts = {} end
    local path = opts.path or M.PATH
    local text = M.readText(path)
    if text == nil then
        return nil, "FILE_NOT_FOUND", nil
    end
    return M.modeFrom(M.parse(text))
end

-- Rewrite only the mode line of a key=value (or comment-only) file. Every other
-- byte is preserved: comments, unknown keys, blank lines and the line order.
function M.setModeInText(text, value)
    if type(text) ~= "string" then text = "" end
    local lines = splitLines(text)
    local newLine = M.MODE_KEY .. "=" .. tostring(value)
    local replaced = false
    for i = 1, #lines do
        local body = trim(lines[i].body)
        if not replaced and body ~= "" and body:sub(1, 1) ~= "#" then
            local key = M.parseLine(body)
            if key == M.MODE_KEY then
                lines[i].body = newLine
                replaced = true
            end
        end
    end
    if not replaced then
        local last = lines[#lines]
        if last ~= nil and last.body == "" and last.eol == "" then
            -- the phantom line produced by a trailing newline
            last.body = newLine
            last.eol = "\n"
        else
            if last ~= nil and last.eol == "" then last.eol = "\n" end
            lines[#lines + 1] = { body = newLine, eol = "\n" }
        end
    end
    local out = {}
    for i = 1, #lines do
        out[i] = lines[i].body .. lines[i].eol
    end
    return table.concat(out)
end

-- Archived log line + bsod "extra" text for an error code.
function M.describe(code, value, raw)
    if code == "FILE_NOT_FOUND" then
        return "Configuration file PowerGrid.ini not found",
            "Configuration file missing."
    elseif code == "VALUE_LENGTH_IS_ZERO" then
        return "PowerGrid.ini is empty", "Power value is empty."
    elseif code == "VALUE_TYPE_NOT_CORRECT" then
        return "Invalid power value format: " .. tostring(raw),
            "Invalid power value format."
    elseif code == "INI_VALUE_OUT_RANGE" then
        return "Power value out of range: " .. tostring(value),
            "Power value must be between 0 and 3."
    elseif code == "MODE_MISSING" then
        return "PowerGrid.ini has no mode= line", "Missing mode setting."
    end
    return "Unknown PowerGrid.ini error: " .. tostring(code),
        "Invalid power configuration."
end

-- Read the watchdog section. Returns the raw option table (field -> raw string,
-- only the keys that are present) plus a parse report:
--   path, format, mode, mode_error, bad_lines, unknown (sorted), entries.
-- Value validation is left to watchdog.lua's sanitize, which owns the defaults;
-- the report is what lets the driver log WATCHDOG_CONFIG_BAD lines.
function M.config(opts)
    if type(opts) ~= "table" then opts = {} end
    local path = opts.path or M.PATH
    local text = M.readText(path)
    if text == nil then
        return {}, {
            path = path,
            format = "missing",
            mode = nil,
            mode_error = "FILE_NOT_FOUND",
            bad_lines = {},
            unknown = {},
            entries = {},
        }
    end

    local parsed = M.parse(text)
    local mode, modeError = M.modeFrom(parsed)

    local raw = {}
    for field, iniKey in pairs(M.WATCHDOG_KEYS) do
        local value = parsed.raw[iniKey]
        if value ~= nil then raw[field] = trim(value) end
    end

    local unknown = {}
    for key, value in pairs(parsed.raw) do
        if not KNOWN[key] then
            unknown[#unknown + 1] = { key = key, value = trim(value) }
        end
    end
    table.sort(unknown, function(a, b) return a.key < b.key end)

    return raw, {
        path = path,
        format = parsed.format,
        mode = mode,
        mode_error = modeError,
        bad_lines = parsed.bad_lines,
        unknown = unknown,
        entries = parsed.raw,
    }
end

-- Apply a mode: rewrite the config file, drive the analog output, chirp the
-- speaker. Returns true when the file was rewritten, or nil, "WRITE_FAILED"
-- when the file could not be opened (the redstone output is still driven, as
-- the archived startup.lua did).
function M.apply(value, opts)
    if type(opts) ~= "table" then opts = {} end
    local path = opts.path or M.PATH
    local side = opts.side or M.SIDE
    local redstone = opts.redstone
    if redstone == nil then redstone = _G.redstone end
    local peripheralApi = opts.peripheral
    if peripheralApi == nil then peripheralApi = _G.peripheral end

    local text = M.readText(path)
    local parsed = M.parse(text)
    local body
    if parsed.format == "keyvalue" or parsed.format == "comments" then
        body = M.setModeInText(text, value)
    else
        -- legacy / empty / missing: keep the old single bare number
        body = tostring(value) .. "\n"
    end

    local written = false
    local file = io.open(path, "w")
    if file then
        file:write(body)
        file:close()
        written = true
    end

    if type(redstone) == "table" and type(redstone.setOutput) == "function" then
        if value > 0 then
            redstone.setOutput(side, true)
            redstone.setAnalogOutput(side, value)
        else
            redstone.setOutput(side, false)
            redstone.setAnalogOutput(side, 0)
        end
    end

    if type(peripheralApi) == "table" and type(peripheralApi.find) == "function" then
        local speaker = peripheralApi.find("speaker")
        if speaker ~= nil and type(speaker.playSound) == "function" then
            speaker.playSound(M.SOUND)
        end
    end

    if written then return true end
    return nil, "WRITE_FAILED"
end

return M
