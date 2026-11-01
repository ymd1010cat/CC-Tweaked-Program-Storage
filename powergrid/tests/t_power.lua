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

-- Ini parsing ----------------------------------------------------------------

local function countKeysLua(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

H.group("power-parse")
writeText("/tests/parse_legacy.ini", "1\n")
local parsed = P.parse(readText("/tests/parse_legacy.ini"))
H.eq(parsed.format, "legacy", "a bare number is the legacy format")
H.eq(parsed.first_content, "1", "the legacy mode line is kept")
H.eq(P.read({ path = "/tests/parse_legacy.ini" }), 1, "the legacy mode is read")

writeText("/tests/parse_legacy_comments.ini", "# leading comment\n\n2\n")
parsed = P.parse(readText("/tests/parse_legacy_comments.ini"))
H.eq(parsed.format, "legacy", "comments before a bare number stay legacy")
H.eq(P.read({ path = "/tests/parse_legacy_comments.ini" }), 2,
    "comments and blank lines before the number are skipped")

writeText("/tests/parse_legacy_multi.ini", "3\nnonsense\n")
parsed = P.parse(readText("/tests/parse_legacy_multi.ini"))
H.eq(parsed.format, "legacy", "extra lines keep the legacy format")
H.eq(P.read({ path = "/tests/parse_legacy_multi.ini" }), 3,
    "only the first content line is the legacy mode")

local keyvalueText = "# config\n" ..
    "\n" ..
    "mode = 1\n" ..
    "watchdog.low=3\n" ..
    "watchdog.enabled = false\n" ..
    "custom.thing=hello=world\n"
writeText("/tests/parse_kv.ini", keyvalueText)
parsed = P.parse(keyvalueText)
H.eq(parsed.format, "keyvalue", "key=value files are detected")
H.eq(parsed.raw["mode"], "1", "spaces around the key and value are trimmed")
H.eq(parsed.raw["watchdog.low"], "3", "a plain value is kept")
H.eq(parsed.raw["watchdog.enabled"], "false", "spaces around the value are trimmed")
H.eq(parsed.raw["custom.thing"], "hello=world", "values may contain '='")
H.eq(P.read({ path = "/tests/parse_kv.ini" }), 1, "the mode= key is read")

writeText("/tests/parse_dup.ini", "mode=1\nmode=2\n")
H.eq(P.read({ path = "/tests/parse_dup.ini" }), 2, "the last duplicate wins")

writeText("/tests/parse_no_mode.ini", "watchdog.low=3\n")
local noModeValue, noModeCode = P.read({ path = "/tests/parse_no_mode.ini" })
H.eq(noModeValue, nil, "a key=value file without mode has no value")
H.eq(noModeCode, "MODE_MISSING", "a key=value file without mode is flagged")
H.eq(P.describe("MODE_MISSING"), "PowerGrid.ini has no mode= line",
    "MODE_MISSING has a log line")
H.eq(select(2, P.describe("MODE_MISSING")), "Missing mode setting.",
    "MODE_MISSING has a blue-screen text")

writeText("/tests/parse_mode_text.ini", "mode=abc\n")
H.eq(select(2, P.read({ path = "/tests/parse_mode_text.ini" })),
    "VALUE_TYPE_NOT_CORRECT", "a text mode keeps the archived type code")
H.eq(select(3, P.read({ path = "/tests/parse_mode_text.ini" })), "abc",
    "a text mode reports the raw value")
writeText("/tests/parse_mode_empty.ini", "mode=\n")
H.eq(select(2, P.read({ path = "/tests/parse_mode_empty.ini" })),
    "VALUE_LENGTH_IS_ZERO", "an empty mode keeps the archived empty code")
writeText("/tests/parse_mode_range.ini", "mode=5\n")
H.eq(select(1, P.read({ path = "/tests/parse_mode_range.ini" })), 5,
    "an out of range mode reports its value")
H.eq(select(2, P.read({ path = "/tests/parse_mode_range.ini" })),
    "INI_VALUE_OUT_RANGE", "an out of range mode keeps the archived code")

writeText("/tests/parse_bad_line.ini", "mode=1\nstray line\n")
parsed = P.parse(readText("/tests/parse_bad_line.ini"))
H.eq(#parsed.bad_lines, 1, "a non key=value line is recorded")
H.eq(parsed.bad_lines[1], "stray line", "the bad line text is kept")
H.eq(P.read({ path = "/tests/parse_bad_line.ini" }), 1, "the mode still parses")

writeText("/tests/parse_comments.ini", "# only comments\n\n")
parsed = P.parse(readText("/tests/parse_comments.ini"))
H.eq(parsed.format, "comments", "a comment-only file is its own format")
H.eq(select(2, P.read({ path = "/tests/parse_comments.ini" })),
    "VALUE_LENGTH_IS_ZERO", "a comment-only file has no mode")
writeText("/tests/parse_empty.ini", "")
H.eq(P.parse("").format, "empty", "an empty text is the empty format")
H.eq(P.parse(nil).format, "missing", "nil text is the missing format")

-- Ini writing ----------------------------------------------------------------

H.group("power-write")
local fidelityText = "# keep me\n" ..
    "\n" ..
    "watchdog.low=3\n" ..
    "mode=1\n" ..
    "custom.thing=hello\n" ..
    "watchdog.restore=false\n"
writeText("/tests/write_kv.ini", fidelityText)
H.eq(P.apply(3, { path = "/tests/write_kv.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) }), true, "apply succeeds on key=value")
local expectedFidelity = "# keep me\n" ..
    "\n" ..
    "watchdog.low=3\n" ..
    "mode=3\n" ..
    "custom.thing=hello\n" ..
    "watchdog.restore=false\n"
H.eq(readText("/tests/write_kv.ini"), expectedFidelity,
    "only the mode line changes, comments/unknown/order kept")
H.eq(P.read({ path = "/tests/write_kv.ini" }), 3, "the new mode reads back")

writeText("/tests/write_no_mode.ini", "# template\nwatchdog.low=4\n")
P.apply(2, { path = "/tests/write_no_mode.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_no_mode.ini"), "# template\nwatchdog.low=4\nmode=2\n",
    "a missing mode line is appended after the other lines")

writeText("/tests/write_spaces.ini", "  mode = 1  \nwatchdog.low=2\n")
P.apply(0, { path = "/tests/write_spaces.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_spaces.ini"), "mode=0\nwatchdog.low=2\n",
    "a spaced mode line is normalised, other lines untouched")

writeText("/tests/write_comments.ini", "# only comments\n")
P.apply(2, { path = "/tests/write_comments.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_comments.ini"), "# only comments\nmode=2\n",
    "a comment-only file keeps its comments and gains a mode line")

writeText("/tests/write_crlf.ini", "mode=1\r\nwatchdog.low=3\r\n")
P.apply(2, { path = "/tests/write_crlf.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_crlf.ini"), "mode=2\r\nwatchdog.low=3\r\n",
    "CRLF line endings are preserved")

writeText("/tests/write_legacy.ini", "1\n")
P.apply(2, { path = "/tests/write_legacy.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_legacy.ini"), "2\n",
    "a legacy file keeps the bare number format")

writeText("/tests/write_empty.ini", "")
P.apply(1, { path = "/tests/write_empty.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_empty.ini"), "1\n", "an empty file gets a bare number")

P.apply(0, { path = "/tests/write_missing.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_missing.ini"), "0\n", "a missing file gets a bare number")

fs.makeDir("/tests/write_dir")
H.eq(P.apply(2, { path = "/tests/write_dir", redstone = newRedstone(),
    peripheral = newPeripheral(false) }), nil, "a directory path cannot be written")
H.eq(select(2, P.apply(2, { path = "/tests/write_dir", redstone = newRedstone(),
    peripheral = newPeripheral(false) })), "WRITE_FAILED", "the write failure code")

-- Ini watchdog section -------------------------------------------------------

H.group("power-config")
local configText = "# monitoring\n" ..
    "mode=1\n" ..
    "watchdog.enabled=true\n" ..
    "watchdog.low=3\n" ..
    "watchdog.high=12\n" ..
    "watchdog.window=120\n" ..
    "watchdog.poll=5\n" ..
    "watchdog.input_side= top \n" ..
    "watchdog.alarm_side=right\n" ..
    "watchdog.switch_to=3\n" ..
    "watchdog.restore=false\n" ..
    "custom.thing=hello\n" ..
    "stray line\n"
writeText("/tests/config_full.ini", configText)
local raw, info = P.config({ path = "/tests/config_full.ini" })
H.eq(raw.enabled, "true", "config reads enabled")
H.eq(raw.low, "3", "config reads low")
H.eq(raw.high, "12", "config reads high")
H.eq(raw.window, "120", "config reads window")
H.eq(raw.poll, "5", "config reads poll")
H.eq(raw.input_side, "top", "config trims the input side")
H.eq(raw.alarm_side, "right", "config reads the alarm side")
H.eq(raw.switch_to, "3", "config reads switch_to")
H.eq(raw.restore, "false", "config reads restore")
H.eq(info.format, "keyvalue", "config reports the format")
H.num(info.mode, 1, "config reports the mode")
H.eq(info.mode_error, nil, "a valid config has no mode error")
H.eq(info.path, "/tests/config_full.ini", "config reports the path")
H.eq(#info.unknown, 1, "one unknown key is reported")
H.eq(info.unknown[1].key, "custom.thing", "the unknown key is named")
H.eq(info.unknown[1].value, "hello", "the unknown value is kept")
H.eq(#info.bad_lines, 1, "the malformed line is reported")

local rawMissing, infoMissing = P.config({ path = "/tests/config_missing.ini" })
H.eq(countKeysLua(rawMissing), 0, "a missing ini has no raw options")
H.eq(infoMissing.format, "missing", "a missing ini is reported as missing")
H.eq(infoMissing.mode_error, "FILE_NOT_FOUND", "a missing ini keeps the archived code")

local rawLegacy, infoLegacy = P.config({ path = "/tests/parse_legacy.ini" })
H.eq(countKeysLua(rawLegacy), 0, "a legacy ini has no watchdog options")
H.eq(infoLegacy.format, "legacy", "a legacy ini is reported as legacy")
H.num(infoLegacy.mode, 1, "a legacy ini still reports the mode")

local rawBad, infoBad = P.config({ path = "/tests/parse_no_mode.ini" })
H.eq(rawBad.low, "3", "config returns values even without a mode")
H.eq(infoBad.mode_error, "MODE_MISSING", "a mode-less key=value file is flagged")

writeText("/tests/config_invalid.ini", "mode=1\nwatchdog.low=abc\n")
local rawInvalid = select(1, P.config({ path = "/tests/config_invalid.ini" }))
H.eq(rawInvalid.low, "abc", "config hands raw strings to the validator")

H.eq(countKeysLua(P.WATCHDOG_KEYS), 9, "the driver mapping has nine keys")
H.eq(P.WATCHDOG_KEYS.low, "watchdog.low", "the low key name")
H.eq(P.WATCHDOG_KEYS.restore, "watchdog.restore", "the restore key name")
H.eq(P.MODE_KEY, "mode", "the mode key name")
