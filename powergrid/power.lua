-- power.lua - PowerGrid.ini parsing/writing plus the power-mode primitive.
--
-- This is the only configuration the project keeps: a single mode 0-3.
-- PowerGrid.ini is either
--   * new format: one "mode=<number>" line (blank lines and lines whose first
--     non-space character is '#' are comments; unknown keys are preserved by
--     writers and ignored by readers), or
--   * old format: the whole file is a bare number, which is what the archived
--     controller wrote. It keeps working and M.apply() keeps writing the bare
--     number for such a file, so an old controller's file is never silently
--     upgraded.
--
-- Error codes (one glance readable; M.LEGACY_CODES maps the old names):
--   CONFIG_FILE_MISSING   file does not exist / cannot be read
--   CONFIG_FILE_EMPTY     file has no mode value
--   MODE_NOT_A_NUMBER     the mode value is not a number
--   MODE_OUT_OF_RANGE     the mode value is outside 0-3
--   MODE_KEY_MISSING      key=value file without a mode= line
--   CONFIG_WRITE_FAILED   the file could not be rewritten (the only fatal one)
--
-- A bad config never stops the program: M.boot() always returns a usable mode
-- (M.DEFAULT_MODE = 1, Main Grid) plus the reason, so the caller logs one
-- CONFIG_ERROR line and keeps running. M.apply() can then recreate a missing
-- file (bare number, as before).
--
-- Writes are format preserving: in a key=value file M.apply() rewrites only the
-- mode line, in place; comments, unknown keys, blank lines and the line order
-- stay untouched. When there is no mode line yet it is appended at the end.
--
-- There is no software watchdog: a physical watchdog (redstone, timer, player)
-- is expected to call M.apply() when it wants to switch the grid. See switch.lua
-- for the tiny command line front end and README.md for the wiring notes.
--
-- opts (all optional, for tests): path, side, redstone, peripheral.

local M = {}

M.VERSION = "1.3"

M.PATH = "PowerGrid.ini"
M.SIDE = "back"
M.SOUND = "create:confirm"
M.MIN = 0
M.MAX = 3
M.MODE_KEY = "mode"
M.DEFAULT_MODE = 1

-- old error code -> new error code. Kept so old logs/tests can be compared.
M.LEGACY_CODES = {
    FILE_NOT_FOUND = "CONFIG_FILE_MISSING",
    VALUE_LENGTH_IS_ZERO = "CONFIG_FILE_EMPTY",
    VALUE_TYPE_NOT_CORRECT = "MODE_NOT_A_NUMBER",
    INI_VALUE_OUT_RANGE = "MODE_OUT_OF_RANGE",
    MODE_MISSING = "MODE_KEY_MISSING",
    WRITE_FAILED = "CONFIG_WRITE_FAILED",
}

local LEGACY_OF = {}
for oldCode, newCode in pairs(M.LEGACY_CODES) do
    LEGACY_OF[newCode] = oldCode
end
M.LEGACY_OF = LEGACY_OF

-- One-line, human readable meaning of each code.
M.DESCRIPTIONS = {
    CONFIG_FILE_MISSING = "PowerGrid.ini not found or not readable",
    CONFIG_FILE_EMPTY = "PowerGrid.ini has no mode value",
    MODE_NOT_A_NUMBER = "the mode value is not a number",
    MODE_OUT_OF_RANGE = "the mode value is outside 0-3",
    MODE_KEY_MISSING = "the file has no mode= line",
    CONFIG_WRITE_FAILED = "PowerGrid.ini could not be written",
}

-- Accept an old code and hand back the new one (anything else is returned as is).
function M.normalizeCode(code)
    if type(code) == "string" and M.LEGACY_CODES[code] ~= nil then
        return M.LEGACY_CODES[code]
    end
    return code
end

-- New code -> old code, for log consumers that still match the old names.
function M.legacyOf(code)
    return LEGACY_OF[M.normalizeCode(code)]
end

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

-- Validate the mode text. Returns value, errorCode, rawLine.
function M.validate(line)
    if line == nil or #line == 0 then
        return nil, "CONFIG_FILE_EMPTY", line
    end
    local value = tonumber(line)
    if value == nil then
        return nil, "MODE_NOT_A_NUMBER", line
    end
    if value < M.MIN or value > M.MAX then
        return value, "MODE_OUT_OF_RANGE", line
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
            return nil, "MODE_KEY_MISSING", nil
        end
        return M.validate(trim(value))
    end
    return M.validate(info.first_content)
end

-- Read a file as text. Returns text, or nil, "CONFIG_FILE_MISSING".
function M.readText(path)
    local okOpen, file = pcall(io.open, path, "r")
    if not okOpen or file == nil then
        return nil, "CONFIG_FILE_MISSING"
    end
    local okRead, text = pcall(file.read, file, "*a")
    file:close()
    if not okRead or type(text) ~= "string" then
        return nil, "CONFIG_FILE_MISSING"
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
        return nil, "CONFIG_FILE_MISSING", nil
    end
    return M.modeFrom(M.parse(text))
end

-- Resolve the mode to run with, without ever failing:
--   ok=true  -> mode is the configured mode
--   ok=false -> mode is M.DEFAULT_MODE and code says why (message/extra are
--               human readable, ready for the log and the blue screen)
-- Also carries the parsed value (useful for MODE_OUT_OF_RANGE) and the raw line.
function M.boot(opts)
    local mode, code, raw = M.read(opts)
    if code == nil then
        return {
            ok = true,
            mode = mode,
            code = nil,
            value = mode,
            raw = raw,
            message = nil,
            extra = nil,
        }
    end
    local message, extra = M.describe(code, mode, raw)
    return {
        ok = false,
        mode = M.DEFAULT_MODE,
        code = code,
        value = mode,
        raw = raw,
        message = message,
        extra = extra,
    }
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

-- Human readable message + consequence text for an error code (old codes are
-- accepted and normalised).
function M.describe(code, value, raw)
    local newCode = M.normalizeCode(code)
    local fallback = M.DEFAULT_MODE
    if newCode == "CONFIG_FILE_MISSING" then
        return "PowerGrid.ini not found or not readable",
            "Configuration file missing. Using mode=" .. fallback ..
            " (Main Grid)."
    elseif newCode == "CONFIG_FILE_EMPTY" then
        return "PowerGrid.ini is empty",
            "Power value is empty. Using mode=" .. fallback .. " (Main Grid)."
    elseif newCode == "MODE_NOT_A_NUMBER" then
        return "PowerGrid.ini mode is not a number: " .. tostring(raw),
            "Invalid power value format. Using mode=" .. fallback ..
            " (Main Grid)."
    elseif newCode == "MODE_OUT_OF_RANGE" then
        return "PowerGrid.ini mode is out of range: " .. tostring(value),
            "Power value must be between 0 and 3. Using mode=" .. fallback ..
            " (Main Grid)."
    elseif newCode == "MODE_KEY_MISSING" then
        return "PowerGrid.ini has no mode= line",
            "Missing mode setting. Using mode=" .. fallback .. " (Main Grid)."
    elseif newCode == "CONFIG_WRITE_FAILED" then
        return "PowerGrid.ini could not be written",
            "PowerGrid.ini could not be saved (disk full or read-only). " ..
            "The redstone output was still driven; fix the disk and restart."
    end
    return "Unknown PowerGrid.ini error: " .. tostring(code),
        "Invalid power configuration."
end

-- One grep-able diagnostic line, e.g.
--   CONFIG_ERROR code=CONFIG_FILE_MISSING file=PowerGrid.ini fallback=mode=1 detail=...
function M.errorLine(code, opts)
    if type(opts) ~= "table" then opts = {} end
    local file = opts.file or M.PATH
    local fallback = opts.fallback
    if fallback == nil then fallback = "mode=" .. tostring(M.DEFAULT_MODE) end
    local message = opts.message
    if message == nil then
        message = (M.describe(code))
    end
    return "CONFIG_ERROR code=" .. tostring(M.normalizeCode(code)) ..
        " file=" .. tostring(file) ..
        " fallback=" .. tostring(fallback) ..
        " detail=" .. tostring(message)
end

-- Apply a mode: rewrite the config file, drive the analog output, chirp the
-- speaker. Returns true when the file was rewritten, or nil,
-- "CONFIG_WRITE_FAILED" when the file could not be opened (the redstone output
-- is still driven, as the archived startup.lua did). This is the only fatal
-- error in the project.
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
    return nil, "CONFIG_WRITE_FAILED"
end

return M
