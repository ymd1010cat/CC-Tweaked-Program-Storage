-- t_power.lua - power.lua behaviour and parity with the archived startup.lua.
--
-- The archived power code lived inside startup.lua as a local function, so this
-- file keeps a verbatim reference copy of that code and drives both
-- implementations with the same inputs, comparing the resulting ini bytes, the
-- redstone call list and the speaker call list. The error codes and messages are
-- pinned against the literal strings the archived program produced.

local H = ...
local P = H.power

local function readText(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local function writeText(path, text)
    local f = fs.open(path, "w")
    f.write(text)
    f.close()
end

local function countIn(text, needle)
    local n = 0
    local pos = 1
    while true do
        local found = text:find(needle, pos, true)
        if not found then break end
        n = n + 1
        pos = found + #needle
    end
    return n
end

local function newRedstone()
    local rs = { calls = {} }
    function rs.setOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setOutput", side, value }
        return true
    end
    function rs.setAnalogOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setAnalogOutput", side, value }
        return true
    end
    return rs
end

local function newPeripheral(withSpeaker)
    local p = { sounds = {} }
    function p.find(kind)
        if kind == "speaker" and withSpeaker then
            return { playSound = function(name)
                p.sounds[#p.sounds + 1] = name
            end }
        end
        return nil
    end
    return p
end

-- Deterministic text form of a table/strings/numbers, used to compare the two
-- implementations call for call.
local function repr(value)
    if type(value) == "table" then
        local parts = {}
        for i = 1, #value do parts[i] = repr(value[i]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
end

-- Reference implementation: verbatim copy of the archived startup.lua code.
local function refApplyPower(value, path, redstone, peripheralApi)
    local f = io.open(path, "w")
    if f then
        f:write(tostring(value) .. "\n")
        f:close()
    end

    if value > 0 then
        redstone.setOutput("back", true)
        redstone.setAnalogOutput("back", value)
    else
        redstone.setOutput("back", false)
        redstone.setAnalogOutput("back", 0)
    end

    local speaker = peripheralApi.find("speaker")
    if speaker then
        speaker.playSound("create:confirm")
    end
end

-- Reference validation: the archived inline checks from startup.lua.
local function refValidate(line)
    if line == nil or #line == 0 then
        return nil, "VALUE_LENGTH_IS_ZERO", line
    end
    local power = tonumber(line)
    if power == nil then
        return nil, "VALUE_TYPE_NOT_CORRECT", line
    end
    if power < 0 or power > 3 then
        return power, "INI_VALUE_OUT_RANGE", line
    end
    return power, nil, line
end

-- Validation -----------------------------------------------------------------

H.group("power-validate")
local cases = { "0", "1", "2", "3", " 1", "2 ", "3.5", "", "abc", "1x", "-1", "4", "15" }
for _, raw in ipairs(cases) do
    local gotValue, gotCode, gotRaw = P.validate(raw)
    local refValue, refCode, refRaw = refValidate(raw)
    H.eq(gotCode, refCode, "same code for <" .. raw .. ">")
    H.eq(gotValue, refValue, "same value for <" .. raw .. ">")
    H.eq(gotRaw, refRaw, "same raw line for <" .. raw .. ">")
end
local nilValue, nilCode = P.validate(nil)
H.eq(nilValue, nil, "a nil line has no value")
H.eq(nilCode, "VALUE_LENGTH_IS_ZERO", "a nil line is the empty error")
H.eq(P.validate(""), nil, "an empty line has no value")
H.eq(select(2, P.validate("")), "VALUE_LENGTH_IS_ZERO", "empty line code")
H.eq(P.validate(" 1"), 1, "surrounding space is accepted")
H.eq(select(2, P.validate("abc")), "VALUE_TYPE_NOT_CORRECT", "text is a type error")
H.eq(P.validate("3.5"), 3.5, "fractional modes are accepted like before")
H.eq(select(1, P.validate("-1")), -1, "a negative mode still yields its value")
H.eq(select(2, P.validate("-1")), "INI_VALUE_OUT_RANGE", "negative mode code")
H.eq(select(1, P.validate("4")), 4, "mode 4 yields its value for the log line")
H.eq(select(2, P.validate("4")), "INI_VALUE_OUT_RANGE", "mode 4 code")
H.eq(select(1, P.validate("15")), 15, "mode 15 value")
H.eq(select(2, P.validate("15")), "INI_VALUE_OUT_RANGE", "mode 15 code")

-- Messages -------------------------------------------------------------------

H.group("power-describe")
local fixed = {
    { "FILE_NOT_FOUND", "Configuration file PowerGrid.ini not found",
        "Configuration file missing." },
    { "VALUE_LENGTH_IS_ZERO", "PowerGrid.ini is empty", "Power value is empty." },
}
for _, case in ipairs(fixed) do
    local message, extra = P.describe(case[1])
    H.eq(message, case[2], "message for " .. case[1])
    H.eq(extra, case[3], "extra for " .. case[1])
end
H.eq(P.describe("VALUE_TYPE_NOT_CORRECT", nil, "abc"),
    "Invalid power value format: abc", "type message carries the raw line")
H.eq(select(2, P.describe("VALUE_TYPE_NOT_CORRECT", nil, "abc")),
    "Invalid power value format.", "type extra text")
H.eq(P.describe("INI_VALUE_OUT_RANGE", 5, "5"),
    "Power value out of range: 5", "range message carries the value")
H.eq(P.describe("INI_VALUE_OUT_RANGE", -1, "-1"),
    "Power value out of range: -1", "negative range message")
H.eq(select(2, P.describe("INI_VALUE_OUT_RANGE", 5)),
    "Power value must be between 0 and 3.", "range extra text")
H.contains(select(1, P.describe("UNKNOWN_CODE")), "Unknown PowerGrid.ini error",
    "unknown codes are reported")

-- Reading --------------------------------------------------------------------

H.group("power-read")
local missing = "/tests/power_missing.ini"
H.eq(readText(missing), nil, "the missing fixture really is absent")
H.eq(select(1, P.read({ path = missing })), nil, "a missing file has no value")
H.eq(select(2, P.read({ path = missing })), "FILE_NOT_FOUND", "missing file code")
writeText("/tests/power_blank.ini", "\n")
H.eq(select(2, P.read({ path = "/tests/power_blank.ini" })),
    "VALUE_LENGTH_IS_ZERO", "a blank line is the empty error")
writeText("/tests/power_empty.ini", "")
H.eq(select(2, P.read({ path = "/tests/power_empty.ini" })),
    "VALUE_LENGTH_IS_ZERO", "a zero byte file is the empty error")
writeText("/tests/power_bad.ini", "abc\n")
H.eq(select(2, P.read({ path = "/tests/power_bad.ini" })),
    "VALUE_TYPE_NOT_CORRECT", "text is a type error")
H.eq(select(3, P.read({ path = "/tests/power_bad.ini" })), "abc",
    "the type error keeps the raw line")
writeText("/tests/power_range.ini", "7\n")
H.eq(select(1, P.read({ path = "/tests/power_range.ini" })), 7,
    "the range error still returns the value")
H.eq(select(2, P.read({ path = "/tests/power_range.ini" })),
    "INI_VALUE_OUT_RANGE", "range file code")
writeText("/tests/power_ok.ini", "2\n")
local okValue, okCode = P.read({ path = "/tests/power_ok.ini" })
H.eq(okValue, 2, "a valid file yields the mode")
H.eq(okCode, nil, "a valid file has no error code")
writeText("/tests/power_multi.ini", "3\n0\n")
H.eq(P.read({ path = "/tests/power_multi.ini" }), 3, "only the first line counts")
H.eq(select(2, P.read({ path = "/tests/power_multi.ini" })), nil,
    "first line valid means no error")

-- Applying -------------------------------------------------------------------

H.group("power-apply")
local rs = newRedstone()
local periph = newPeripheral(true)
H.eq(P.apply(2, { path = "/tests/power_apply.ini", redstone = rs,
    peripheral = periph }), true, "apply reports success")
H.eq(readText("/tests/power_apply.ini"), "2\n", "apply writes the mode line")
H.eq(#rs.calls, 2, "apply writes two redstone signals")
H.eq(rs.calls[1][1], "setOutput", "setOutput first")
H.eq(rs.calls[1][2], "back", "the archived side is back")
H.eq(rs.calls[1][3], true, "setOutput(true)")
H.eq(rs.calls[2][1], "setAnalogOutput", "setAnalogOutput second")
H.num(rs.calls[2][3], 2, "analog level equals the mode")
H.eq(periph.sounds[1], "create:confirm", "the speaker chirped")

local rs0 = newRedstone()
local periph0 = newPeripheral(false)
H.eq(P.apply(0, { path = "/tests/power_zero.ini", redstone = rs0,
    peripheral = periph0 }), true, "mode 0 applies")
H.eq(readText("/tests/power_zero.ini"), "0\n", "mode 0 written")
H.eq(#rs0.calls, 2, "mode 0 writes two signals")
H.eq(rs0.calls[1][3], false, "mode 0 drives setOutput false")
H.num(rs0.calls[2][3], 0, "mode 0 drives analog 0")
H.eq(#periph0.sounds, 0, "no speaker means no sound")

fs.makeDir("/tests/power_dir")
H.ok(fs.exists("/tests/power_dir"), "the unwritable fixture really is a directory")
local rsBad = newRedstone()
local okBad, whyBad = P.apply(1, {
    path = "/tests/power_dir",
    redstone = rsBad,
    peripheral = newPeripheral(false),
})
H.eq(okBad, nil, "an unwritable path reports failure")
H.eq(whyBad, "WRITE_FAILED", "unwritable path code")
H.eq(#rsBad.calls, 2, "the redstone output is still driven")
H.num(rsBad.calls[2][3], 1, "the requested mode is still driven")

local rsSide = newRedstone()
P.apply(1, { path = "/tests/power_side.ini", redstone = rsSide, side = "top" })
H.eq(rsSide.calls[1][2], "top", "the redstone side can be overridden")

-- Parity with the archived implementation ------------------------------------

H.group("power-parity")
for _, value in ipairs({ 0, 1, 2, 3 }) do
    local newRs, refRs = newRedstone(), newRedstone()
    local newP, refP = newPeripheral(true), newPeripheral(true)
    local newPath, refPath = "/tests/parity_new.ini", "/tests/parity_ref.ini"
    local okNew = P.apply(value, { path = newPath, redstone = newRs,
        peripheral = newP })
    refApplyPower(value, refPath, refRs, refP)
    H.eq(readText(newPath), readText(refPath),
        "same ini for mode " .. tostring(value))
    H.eq(repr(newRs.calls), repr(refRs.calls),
        "same redstone calls for mode " .. tostring(value))
    H.eq(repr(newP.sounds), repr(refP.sounds),
        "same speaker calls for mode " .. tostring(value))
    H.eq(okNew, true, "apply succeeded for mode " .. tostring(value))
    H.eq(#newRs.calls, 2, "two redstone calls for mode " .. tostring(value))
end
for _, speakerOn in ipairs({ true, false }) do
    local newRs, refRs = newRedstone(), newRedstone()
    local newP, refP = newPeripheral(speakerOn), newPeripheral(speakerOn)
    P.apply(3, { path = "/tests/parity_new.ini", redstone = newRs,
        peripheral = newP })
    refApplyPower(3, "/tests/parity_ref.ini", refRs, refP)
    H.eq(repr(newRs.calls), repr(refRs.calls),
        "same redstone calls, speaker=" .. tostring(speakerOn))
    H.eq(repr(newP.sounds), repr(refP.sounds),
        "same speaker calls, speaker=" .. tostring(speakerOn))
end

-- Source pinning -------------------------------------------------------------

H.group("power-source")
local src = H.readAll("/power.lua") or ""
H.contains(src, "Configuration file PowerGrid.ini not found",
    "archived missing-file message kept")
H.contains(src, "PowerGrid.ini is empty", "archived empty-file message kept")
H.contains(src, "Invalid power value format: ", "archived type message kept")
H.contains(src, "Power value out of range: ", "archived range message kept")
H.contains(src, "Configuration file missing.", "archived missing-file extra kept")
H.contains(src, "Power value is empty.", "archived empty extra kept")
H.contains(src, "Invalid power value format.", "archived type extra kept")
H.contains(src, "Power value must be between 0 and 3.",
    "archived range extra kept")
H.contains(src, "FILE_NOT_FOUND", "archived error code kept")
H.contains(src, "VALUE_LENGTH_IS_ZERO", "archived empty code kept")
H.contains(src, "VALUE_TYPE_NOT_CORRECT", "archived type code kept")
H.contains(src, "INI_VALUE_OUT_RANGE", "archived range code kept")
H.contains(src, 'M.PATH = "PowerGrid.ini"', "archived config path kept")
H.contains(src, 'M.SIDE = "back"', "archived redstone side kept")
H.contains(src, 'M.SOUND = "create:confirm"', "archived speaker sound kept")

local startupSrc = H.readAll("/tests/startup_source.lua") or ""
H.contains(startupSrc, 'local power_api = require("power")',
    "startup.lua uses power.lua")
H.contains(startupSrc, "power_api.read()", "startup reads through power.lua")
H.contains(startupSrc, "power_api.describe(configError, power, configLine)",
    "startup describes errors through power.lua")
H.lacks(startupSrc, "local function applyPower",
    "startup.lua no longer defines the helper")
H.lacks(startupSrc, 'io.open("PowerGrid.ini", "w")',
    "startup.lua no longer writes the ini itself")
H.eq(countIn(startupSrc, "power_api.apply(power)"), 5,
    "startup applies power from five places (boot + four menu entries)")
H.contains(startupSrc, 'shell.run("clear")', "the screen clear is kept")
H.contains(startupSrc, "local function wrapText", "printer wrapping is kept")
H.contains(startupSrc, "MAX_LINE_WIDTH = 40", "printer width is kept")
H.contains(startupSrc, "MAX_LINES_PER_PAGE = 60", "printer page size is kept")
H.contains(startupSrc, 'peripheral.find("printer")', "printer lookup is kept")
H.contains(startupSrc, "printer.getPaperLevel()", "printer paper check is kept")
H.contains(startupSrc, "printer.getInkLevel()", "printer ink check is kept")
H.contains(startupSrc, "printer.newPage()", "printer page creation is kept")
H.contains(startupSrc, "printer.endPage()", "printer page end is kept")
H.contains(startupSrc, "printer.write(seg)", "printer write is kept")
H.contains(startupSrc, "VERSION_INFO", "the version command is kept")
H.contains(startupSrc, 'title = "Power Grid Controller v2.1"',
    "the version title is kept")
H.contains(startupSrc, "FEEDBACK_DELAY = 1", "the feedback delay is kept")
H.contains(startupSrc, "Switch To Main Grid", "the menu text is kept")
H.contains(startupSrc, "Press ESC TO EXIT", "the menu footer is kept")
H.contains(startupSrc, "error = configError",
    "the blue screen still receives the archived code")
H.lacks(startupSrc, "watchdog",
    "the controller still has no watchdog hook of its own")
