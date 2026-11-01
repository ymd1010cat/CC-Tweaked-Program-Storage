-- power.lua - the Power Grid Controller's power-mode primitive.
--
-- Shared by startup.lua (the manual menu) and watchdog_app.lua (the watchdog
-- switch/restore). The logic is extracted verbatim from the archived
-- startup.lua applyPower()/config-validation block, so the observable behaviour
-- stays the same:
--   * PowerGrid.ini holds a single line, the mode 0-3;
--   * the analog redstone output on "back" carries 1-3, mode 0 drives
--     setOutput(false)+setAnalogOutput(0);
--   * a speaker peripheral, when present, plays "create:confirm".
--
-- The archived error codes are preserved exactly:
--   FILE_NOT_FOUND / VALUE_LENGTH_IS_ZERO / VALUE_TYPE_NOT_CORRECT /
--   INI_VALUE_OUT_RANGE
-- and M.describe() returns the archived log line and bsod "extra" text for
-- them, so startup.lua can keep its messages byte for byte.
--
-- opts (all optional, for tests): path, side, redstone, peripheral.

local M = {}

M.VERSION = "1.0"

M.PATH = "PowerGrid.ini"
M.SIDE = "back"
M.SOUND = "create:confirm"
M.MIN = 0
M.MAX = 3

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

-- Read the current mode. Returns value, errorCode, rawLine; errorCode is nil on
-- success.
function M.read(opts)
    if type(opts) ~= "table" then opts = {} end
    local path = opts.path or M.PATH
    local file = io.open(path, "r")
    if not file then
        return nil, "FILE_NOT_FOUND", nil
    end
    local line = file:read("*line")
    file:close()
    return M.validate(line)
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
    end
    return "Unknown PowerGrid.ini error: " .. tostring(code),
        "Invalid power configuration."
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

    local written = false
    local file = io.open(path, "w")
    if file then
        file:write(tostring(value) .. "\n")
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
