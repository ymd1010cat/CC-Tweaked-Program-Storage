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
        return nil, "CONFIG_FILE_EMPTY", line
    end
    local power = tonumber(line)
    if power == nil then
        return nil, "MODE_NOT_A_NUMBER", line
    end
    if power < 0 or power > 3 then
        return power, "MODE_OUT_OF_RANGE", line
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
H.eq(nilCode, "CONFIG_FILE_EMPTY", "a nil line is the empty error")
H.eq(P.validate(""), nil, "an empty line has no value")
H.eq(select(2, P.validate("")), "CONFIG_FILE_EMPTY", "empty line code")
H.eq(P.validate(" 1"), 1, "surrounding space is accepted")
H.eq(select(2, P.validate("abc")), "MODE_NOT_A_NUMBER", "text is a type error")
H.eq(P.validate("3.5"), 3.5, "fractional modes are accepted like before")
H.eq(select(1, P.validate("-1")), -1, "a negative mode still yields its value")
H.eq(select(2, P.validate("-1")), "MODE_OUT_OF_RANGE", "negative mode code")
H.eq(select(1, P.validate("4")), 4, "mode 4 yields its value for the log line")
H.eq(select(2, P.validate("4")), "MODE_OUT_OF_RANGE", "mode 4 code")
H.eq(select(1, P.validate("15")), 15, "mode 15 value")
H.eq(select(2, P.validate("15")), "MODE_OUT_OF_RANGE", "mode 15 code")

-- Messages -------------------------------------------------------------------

H.group("power-describe")
local fixed = {
    { "CONFIG_FILE_MISSING", "PowerGrid.ini not found or not readable",
        "Configuration file missing. Using mode=1 (Main Grid)." },
    { "CONFIG_FILE_EMPTY", "PowerGrid.ini is empty",
        "Power value is empty. Using mode=1 (Main Grid)." },
    { "CONFIG_WRITE_FAILED", "PowerGrid.ini could not be written",
        "PowerGrid.ini could not be saved (disk full or read-only). " ..
        "The redstone output was still driven; fix the disk and restart." },
}
for _, case in ipairs(fixed) do
    local message, extra = P.describe(case[1])
    H.eq(message, case[2], "message for " .. case[1])
    H.eq(extra, case[3], "extra for " .. case[1])
end
H.eq(P.describe("MODE_NOT_A_NUMBER", nil, "abc"),
    "PowerGrid.ini mode is not a number: abc", "type message carries the raw line")
H.eq(select(2, P.describe("MODE_NOT_A_NUMBER", nil, "abc")),
    "Invalid power value format. Using mode=1 (Main Grid).", "type extra text")
H.eq(P.describe("MODE_OUT_OF_RANGE", 5, "5"),
    "PowerGrid.ini mode is out of range: 5", "range message carries the value")
H.eq(P.describe("MODE_OUT_OF_RANGE", -1, "-1"),
    "PowerGrid.ini mode is out of range: -1", "negative range message")
H.eq(select(2, P.describe("MODE_OUT_OF_RANGE", 5)),
    "Power value must be between 0 and 3. Using mode=1 (Main Grid).",
    "range extra text")
H.contains(select(1, P.describe("UNKNOWN_CODE")), "Unknown PowerGrid.ini error",
    "unknown codes are reported")
-- Old codes keep working through describe()/normalizeCode().
H.eq(P.normalizeCode("FILE_NOT_FOUND"), "CONFIG_FILE_MISSING",
    "old missing code normalises")
H.eq(P.normalizeCode("CONFIG_FILE_MISSING"), "CONFIG_FILE_MISSING",
    "new codes normalise to themselves")
H.eq(P.describe("FILE_NOT_FOUND"), "PowerGrid.ini not found or not readable",
    "describe accepts an old code")
H.eq(P.legacyOf("MODE_OUT_OF_RANGE"), "INI_VALUE_OUT_RANGE",
    "new code maps back to the old one")
H.eq(P.legacyOf("CONFIG_WRITE_FAILED"), "WRITE_FAILED",
    "the write code maps back too")
H.eq(P.describe("MODE_KEY_MISSING"), "PowerGrid.ini has no mode= line",
    "the missing mode line has a message")
H.eq(select(2, P.describe("MODE_KEY_MISSING")),
    "Missing mode setting. Using mode=1 (Main Grid).",
    "the missing mode line explains the fallback")

H.group("power-codes")
H.eq(P.DEFAULT_MODE, 1, "the default mode is the main grid")
H.eq(P.LEGACY_CODES.FILE_NOT_FOUND, "CONFIG_FILE_MISSING", "legacy map: missing")
H.eq(P.LEGACY_CODES.VALUE_LENGTH_IS_ZERO, "CONFIG_FILE_EMPTY", "legacy map: empty")
H.eq(P.LEGACY_CODES.VALUE_TYPE_NOT_CORRECT, "MODE_NOT_A_NUMBER", "legacy map: type")
H.eq(P.LEGACY_CODES.INI_VALUE_OUT_RANGE, "MODE_OUT_OF_RANGE", "legacy map: range")
H.eq(P.LEGACY_CODES.MODE_MISSING, "MODE_KEY_MISSING", "legacy map: key")
H.eq(P.LEGACY_CODES.WRITE_FAILED, "CONFIG_WRITE_FAILED", "legacy map: write")
local codeCount = 0
for _ in pairs(P.LEGACY_CODES) do codeCount = codeCount + 1 end
H.eq(codeCount, 6, "six legacy codes are mapped")
H.contains(P.DESCRIPTIONS.CONFIG_FILE_MISSING, "not found",
    "the missing code has a description")
H.contains(P.DESCRIPTIONS.MODE_OUT_OF_RANGE, "0-3",
    "the range code has a description")
H.isType(P.DESCRIPTIONS.CONFIG_WRITE_FAILED, "string",
    "the write code has a description")

-- Reading --------------------------------------------------------------------

H.group("power-read")
local missing = "/tests/power_missing.ini"
H.eq(readText(missing), nil, "the missing fixture really is absent")
H.eq(select(1, P.read({ path = missing })), nil, "a missing file has no value")
H.eq(select(2, P.read({ path = missing })), "CONFIG_FILE_MISSING", "missing file code")
writeText("/tests/power_blank.ini", "\n")
H.eq(select(2, P.read({ path = "/tests/power_blank.ini" })),
    "CONFIG_FILE_EMPTY", "a blank line is the empty error")
writeText("/tests/power_empty.ini", "")
H.eq(select(2, P.read({ path = "/tests/power_empty.ini" })),
    "CONFIG_FILE_EMPTY", "a zero byte file is the empty error")
writeText("/tests/power_bad.ini", "abc\n")
H.eq(select(2, P.read({ path = "/tests/power_bad.ini" })),
    "MODE_NOT_A_NUMBER", "text is a type error")
H.eq(select(3, P.read({ path = "/tests/power_bad.ini" })), "abc",
    "the type error keeps the raw line")
writeText("/tests/power_range.ini", "7\n")
H.eq(select(1, P.read({ path = "/tests/power_range.ini" })), 7,
    "the range error still returns the value")
H.eq(select(2, P.read({ path = "/tests/power_range.ini" })),
    "MODE_OUT_OF_RANGE", "range file code")
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
H.eq(whyBad, "CONFIG_WRITE_FAILED", "unwritable path code")
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
H.contains(src, "PowerGrid.ini not found or not readable",
    "the missing-file message is the readable one")
H.contains(src, "PowerGrid.ini is empty", "the empty-file message is kept")
H.contains(src, "PowerGrid.ini mode is not a number: ", "the type message is readable")
H.contains(src, "PowerGrid.ini mode is out of range: ", "the range message is readable")
H.contains(src, "Configuration file missing.", "the missing-file consequence is kept")
H.contains(src, "Power value is empty.", "the empty-file consequence is kept")
H.contains(src, "Invalid power value format.", "the type consequence is kept")
H.contains(src, "Power value must be between 0 and 3.",
    "the range consequence is kept")
H.contains(src, "CONFIG_FILE_MISSING", "the missing code is present")
H.contains(src, "CONFIG_FILE_EMPTY", "the empty code is present")
H.contains(src, "MODE_NOT_A_NUMBER", "the type code is present")
H.contains(src, "MODE_OUT_OF_RANGE", "the range code is present")
H.contains(src, "MODE_KEY_MISSING", "the missing-mode code is present")
H.contains(src, "CONFIG_WRITE_FAILED", "the write code is present")
H.contains(src, "M.LEGACY_CODES", "the legacy code table is present")
H.contains(src, "M.DEFAULT_MODE = 1", "the default mode is documented in code")
H.contains(src, 'M.PATH = "PowerGrid.ini"', "the config path is kept")
H.contains(src, 'M.SIDE = "back"', "the redstone side is kept")
H.contains(src, 'M.SOUND = "create:confirm"', "the speaker sound is kept")

local startupSrc = H.readAll("/tests/startup_source.lua") or ""
H.contains(startupSrc, 'loadLibrary("power")',
    "startup.lua loads power.lua through the diagnostic loader")
H.contains(startupSrc, 'loadLibrary("logger")',
    "startup.lua loads logger.lua through the diagnostic loader")
H.contains(startupSrc, 'loadLibrary("bsod")',
    "startup.lua loads bsod.lua through the diagnostic loader")
H.contains(startupSrc, "MISSING_LIBRARY",
    "startup.lua reports missing libraries with one token")
H.contains(startupSrc, "power_api.boot()", "startup boots through power.lua")
H.contains(startupSrc, "CONFIG_ERROR", "startup logs CONFIG_ERROR lines")
H.contains(startupSrc, "power_api.errorLine(boot.code",
    "startup uses the shared diagnostic line")
H.contains(startupSrc, "local function applyPower",
    "startup keeps a thin applyPower wrapper")
H.contains(startupSrc, "power_api.apply(value)",
    "the wrapper delegates the write to power.lua")
H.lacks(startupSrc, 'io.open("PowerGrid.ini", "w")',
    "startup.lua never writes the ini itself")
H.eq(countIn(startupSrc, "applyPower(power)"), 5,
    "startup applies power from five places (boot + four menu entries)")
H.contains(startupSrc, "CONFIG_WRITE_FAILED",
    "only a write failure reaches the blue screen")
H.eq(countIn(startupSrc, "bsod.show({"), 2,
    "two blue-screen paths (missing library, write failure)")
H.contains(startupSrc, "MISSING_LIBRARY",
    "missing libraries get their own blue-screen token")
H.lacks(startupSrc, "configError", "no config error path hands over to the blue screen")
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
H.contains(startupSrc, "CONFIG_ERROR", "the controller logs CONFIG_ERROR")
H.contains(startupSrc, "boot.code", "the controller logs the boot error code")
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
    "custom.extra=3\n" ..
    "custom.flag = false\n" ..
    "custom.thing=hello=world\n"
writeText("/tests/parse_kv.ini", keyvalueText)
parsed = P.parse(keyvalueText)
H.eq(parsed.format, "keyvalue", "key=value files are detected")
H.eq(parsed.raw["mode"], "1", "spaces around the key and value are trimmed")
H.eq(parsed.raw["custom.extra"], "3", "a plain value is kept")
H.eq(parsed.raw["custom.flag"], "false", "spaces around the value are trimmed")
H.eq(parsed.raw["custom.thing"], "hello=world", "values may contain '='")
H.eq(P.read({ path = "/tests/parse_kv.ini" }), 1, "the mode= key is read")

writeText("/tests/parse_dup.ini", "mode=1\nmode=2\n")
H.eq(P.read({ path = "/tests/parse_dup.ini" }), 2, "the last duplicate wins")

writeText("/tests/parse_no_mode.ini", "custom.extra=3\n")
local noModeValue, noModeCode = P.read({ path = "/tests/parse_no_mode.ini" })
H.eq(noModeValue, nil, "a key=value file without mode has no value")
H.eq(noModeCode, "MODE_KEY_MISSING", "a key=value file without mode is flagged")
H.eq(P.describe("MODE_KEY_MISSING"), "PowerGrid.ini has no mode= line",
    "MODE_KEY_MISSING has a log line")
H.eq(select(2, P.describe("MODE_KEY_MISSING")),
    "Missing mode setting. Using mode=1 (Main Grid).",
    "MODE_KEY_MISSING has a consequence text")

writeText("/tests/parse_mode_text.ini", "mode=abc\n")
H.eq(select(2, P.read({ path = "/tests/parse_mode_text.ini" })),
    "MODE_NOT_A_NUMBER", "a text mode keeps the archived type code")
H.eq(select(3, P.read({ path = "/tests/parse_mode_text.ini" })), "abc",
    "a text mode reports the raw value")
writeText("/tests/parse_mode_empty.ini", "mode=\n")
H.eq(select(2, P.read({ path = "/tests/parse_mode_empty.ini" })),
    "CONFIG_FILE_EMPTY", "an empty mode keeps the archived empty code")
writeText("/tests/parse_mode_range.ini", "mode=5\n")
H.eq(select(1, P.read({ path = "/tests/parse_mode_range.ini" })), 5,
    "an out of range mode reports its value")
H.eq(select(2, P.read({ path = "/tests/parse_mode_range.ini" })),
    "MODE_OUT_OF_RANGE", "an out of range mode keeps the archived code")

writeText("/tests/parse_bad_line.ini", "mode=1\nstray line\n")
parsed = P.parse(readText("/tests/parse_bad_line.ini"))
H.eq(#parsed.bad_lines, 1, "a non key=value line is recorded")
H.eq(parsed.bad_lines[1], "stray line", "the bad line text is kept")
H.eq(P.read({ path = "/tests/parse_bad_line.ini" }), 1, "the mode still parses")

writeText("/tests/parse_comments.ini", "# only comments\n\n")
parsed = P.parse(readText("/tests/parse_comments.ini"))
H.eq(parsed.format, "comments", "a comment-only file is its own format")
H.eq(select(2, P.read({ path = "/tests/parse_comments.ini" })),
    "CONFIG_FILE_EMPTY", "a comment-only file has no mode")
writeText("/tests/parse_empty.ini", "")
H.eq(P.parse("").format, "empty", "an empty text is the empty format")
H.eq(P.parse(nil).format, "missing", "nil text is the missing format")

-- Ini writing ----------------------------------------------------------------

H.group("power-write")
local fidelityText = "# keep me\n" ..
    "\n" ..
    "custom.extra=3\n" ..
    "mode=1\n" ..
    "custom.thing=hello\n" ..
    "custom.flag=false\n"
writeText("/tests/write_kv.ini", fidelityText)
H.eq(P.apply(3, { path = "/tests/write_kv.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) }), true, "apply succeeds on key=value")
local expectedFidelity = "# keep me\n" ..
    "\n" ..
    "custom.extra=3\n" ..
    "mode=3\n" ..
    "custom.thing=hello\n" ..
    "custom.flag=false\n"
H.eq(readText("/tests/write_kv.ini"), expectedFidelity,
    "only the mode line changes, comments/unknown/order kept")
H.eq(P.read({ path = "/tests/write_kv.ini" }), 3, "the new mode reads back")

writeText("/tests/write_no_mode.ini", "# template\ncustom.extra=4\n")
P.apply(2, { path = "/tests/write_no_mode.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_no_mode.ini"), "# template\ncustom.extra=4\nmode=2\n",
    "a missing mode line is appended after the other lines")

writeText("/tests/write_spaces.ini", "  mode = 1  \ncustom.extra=2\n")
P.apply(0, { path = "/tests/write_spaces.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_spaces.ini"), "mode=0\ncustom.extra=2\n",
    "a spaced mode line is normalised, other lines untouched")

writeText("/tests/write_comments.ini", "# only comments\n")
P.apply(2, { path = "/tests/write_comments.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_comments.ini"), "# only comments\nmode=2\n",
    "a comment-only file keeps its comments and gains a mode line")

writeText("/tests/write_crlf.ini", "mode=1\r\ncustom.extra=3\r\n")
P.apply(2, { path = "/tests/write_crlf.ini", redstone = newRedstone(),
    peripheral = newPeripheral(false) })
H.eq(readText("/tests/write_crlf.ini"), "mode=2\r\ncustom.extra=3\r\n",
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
    peripheral = newPeripheral(false) })), "CONFIG_WRITE_FAILED", "the write failure code")

H.group("power-boot")
local missingBoot = P.boot({ path = "/tests/boot_missing.ini" })
H.eq(missingBoot.ok, false, "a missing ini is not ok")
H.eq(missingBoot.code, "CONFIG_FILE_MISSING", "a missing ini reports the missing code")
H.num(missingBoot.mode, 1, "a missing ini boots with the default mode")
H.contains(missingBoot.message, "not found", "the boot message is human readable")
H.contains(missingBoot.extra, "Using mode=1 (Main Grid)",
    "the consequence names the default mode")

writeText("/tests/boot_empty.ini", "")
local emptyBoot = P.boot({ path = "/tests/boot_empty.ini" })
H.eq(emptyBoot.ok, false, "an empty ini is not ok")
H.eq(emptyBoot.code, "CONFIG_FILE_EMPTY", "an empty ini reports the empty code")
H.num(emptyBoot.mode, 1, "an empty ini boots with the default mode")

writeText("/tests/boot_comment.ini", "# nothing here\n")
H.eq(P.boot({ path = "/tests/boot_comment.ini" }).code, "CONFIG_FILE_EMPTY",
    "a comment-only ini counts as empty for the mode")

writeText("/tests/boot_text.ini", "mode=abc\n")
local textBoot = P.boot({ path = "/tests/boot_text.ini" })
H.eq(textBoot.code, "MODE_NOT_A_NUMBER", "a text mode is reported")
H.num(textBoot.mode, 1, "a text mode boots with the default mode")
H.contains(textBoot.message, "abc", "the message keeps the bad value")

writeText("/tests/boot_range.ini", "mode=9\n")
local rangeBoot = P.boot({ path = "/tests/boot_range.ini" })
H.eq(rangeBoot.code, "MODE_OUT_OF_RANGE", "an out of range mode is reported")
H.num(rangeBoot.mode, 1, "an out of range mode boots with the default mode")
H.num(rangeBoot.value, 9, "the parsed value is kept for the log")

writeText("/tests/boot_nokey.ini", "custom.extra=3\n")
local keyBoot = P.boot({ path = "/tests/boot_nokey.ini" })
H.eq(keyBoot.code, "MODE_KEY_MISSING", "a key=value file without mode is reported")
H.num(keyBoot.mode, 1, "a mode-less file boots with the default mode")

writeText("/tests/boot_ok.ini", "mode=2\n")
local okBoot = P.boot({ path = "/tests/boot_ok.ini" })
H.eq(okBoot.ok, true, "a good ini boots ok")
H.num(okBoot.mode, 2, "a good ini keeps its own mode")
H.eq(okBoot.code, nil, "a good ini has no error code")

H.eq(P.errorLine("CONFIG_FILE_MISSING", { message = missingBoot.message }),
    "CONFIG_ERROR code=CONFIG_FILE_MISSING file=PowerGrid.ini fallback=mode=1 " ..
    "detail=PowerGrid.ini not found or not readable",
    "the CONFIG_ERROR line is exact")
H.contains(P.errorLine("CONFIG_WRITE_FAILED", { fallback = "none" }),
    "fallback=none", "a write failure has no mode fallback")
H.eq(P.errorLine("FILE_NOT_FOUND"),
    "CONFIG_ERROR code=CONFIG_FILE_MISSING file=PowerGrid.ini " ..
    "fallback=mode=1 detail=PowerGrid.ini not found or not readable",
    "an old code is normalised in the log line")

-- After booting from a missing file, apply recreates it (legacy bare number).
local recreatePath = "/tests/boot_recreate.ini"
H.eq(P.read({ path = recreatePath }), nil, "the recreate fixture starts absent")
H.eq(P.boot({ path = recreatePath }).code, "CONFIG_FILE_MISSING",
    "the recreate fixture boots with the missing code")
H.eq(P.apply(1, { path = recreatePath, redstone = newRedstone(),
    peripheral = newPeripheral(false) }), true, "apply recreates the file")
H.eq(readText(recreatePath), "1\n", "the recreated file is the bare default mode")
H.eq(P.read({ path = recreatePath }), 1, "the recreated file reads back as mode 1")
H.eq(P.boot({ path = recreatePath }).ok, true, "the recreated file boots clean")

writeText("/tests/boot_recreate_empty.ini", "")
P.apply(P.boot({ path = "/tests/boot_recreate_empty.ini" }).mode, {
    path = "/tests/boot_recreate_empty.ini",
    redstone = newRedstone(),
    peripheral = newPeripheral(false),
})
H.eq(readText("/tests/boot_recreate_empty.ini"), "1\n",
    "an empty file is rebuilt as a bare number")

writeText("/tests/boot_recreate_kv.ini", "mode=9\ncustom.extra=4\n")
local kvBoot = P.boot({ path = "/tests/boot_recreate_kv.ini" })
H.eq(kvBoot.code, "MODE_OUT_OF_RANGE", "the key=value fixture is out of range")
H.num(kvBoot.mode, 1, "the key=value fixture boots the default mode")
P.apply(kvBoot.mode, { path = "/tests/boot_recreate_kv.ini",
    redstone = newRedstone(), peripheral = newPeripheral(false) })
H.eq(readText("/tests/boot_recreate_kv.ini"), "mode=1\ncustom.extra=4\n",
    "the recovery write only fixes the mode line")
H.eq(P.read({ path = "/tests/boot_recreate_kv.ini" }), 1,
    "the rebuilt key=value file reads back as mode 1")

-- A good config is never rewritten by a boot: read only.
writeText("/tests/boot_untouched.ini", "# keep\nmode=3\n")
P.boot({ path = "/tests/boot_untouched.ini" })
H.eq(readText("/tests/boot_untouched.ini"), "# keep\nmode=3\n",
    "booting never rewrites a good file")
