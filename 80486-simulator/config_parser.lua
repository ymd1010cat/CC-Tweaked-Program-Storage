---------------------------------------------------------------------------
-- 80486-simulator/config_parser.lua
--
-- INI-style parser for 80486.cfg.
--
-- The parser is deliberately small and dependency free: it takes the whole
-- file as one in-memory string, returns a nested Lua table, and never touches
-- fs, term or any other CC peripheral.  It performs no dynamic execution at
-- all -- only pattern matching and tonumber() on ordinary configuration text.
--
-- Accepted syntax
-- ---------------
--     ; comment line            (leading ';' after optional whitespace)
--     # comment line            (leading '#' after optional whitespace)
--     [section]                 section header, name is trimmed
--     key=value                 one entry per line
--
-- Blank lines and comment lines are ignored.  There are no inline comments:
-- '#' and ';' only start a comment when they are the first non-blank
-- character of a line, so a value may contain either character.
--
-- Section names and keys are restricted to [A-Za-z0-9_.-]+; anything else is
-- a malformed line, not a silently accepted name.
--
-- Value typing (first match wins)
-- -------------------------------
--     true / false              -> boolean
--     0xHHHH                    -> number, base 16 ('0x' or '0X' prefix)
--     12345                     -> number, base 10 (digits only)
--     -1                        -> number, base 10 (leading '-' allowed)
--     []                        -> empty table
--     [A, B]                    -> {"A", "B"}  (elements trimmed, strings)
--     everything else           -> string (an empty value is "")
--
-- List elements are plain strings and may not contain '[' or ']'.  Lists
-- have no quoting or escaping, so a bracket inside an element means the
-- value is malformed and is rejected.
--
-- Return value
-- ------------
--     {
--         memory = { size = 16777216, base = 0xF0000 },
--         cpu    = { turbo = true },
--         vga    = { boot_drives = {"0x00", "0x80"} },
--     }
--
-- Limits (hard; a file over a limit is rejected, never truncated)
-- ---------------------------------------------------------------
--     whole file      64 KiB (after BOM strip and CRLF normalisation)
--     one line        256 bytes (normalised, before trimming)
--     key=value       4096 entries in total
--     numbers         unsigned 0..0xFFFFFFFF; signed -2147483648..-1
--
-- The 64 KiB whole-file cap is measured on the normalised content string:
-- after a single UTF-8 BOM has been stripped and after the CR of every
-- CRLF pair has been removed (a lone CR is not a line separator and stays
-- in the string, so it counts).  A CRLF file therefore measures one byte
-- per line less than its on-disk size, plus three bytes fewer when a BOM
-- was present.  The 256-byte line cap is measured on that same normalised
-- line, before it is trimmed.
--
-- Numeric limits are checked twice.  First the digit count is validated
-- (leading zeros are ignored), then the converted value is checked for NaN
-- and +/-inf.  This matters because Lua 5.2 (CraftOS-PC) turns a very long
-- digit run into inf, while CC's Lua 5.1 tonumber() goes through strtoul and
-- may saturate, so the conversion result cannot be trusted on its own.
-- Unsigned values are limited to 0..0xFFFFFFFF (the full 32-bit linear
-- address range of the emulated 80486); a leading '-' selects the signed
-- range -2147483648..-1, which non-address options such as
-- [watchdog] max_tick=-1 use.
--
-- Errors
-- ------
-- Every malformed line raises an error that names the offending line:
--
--     config_parser: line 7: expected 'key=value' or '[section]', got 'foo'
--
-- Control bytes found in an offending line (NUL, ESC, CR, ...) are escaped
-- as \xNN before the message is built, and the message is assembled with
-- plain concatenation instead of string.format("%s"): a %s format goes
-- through a C string on CraftOS and would silently truncate the diagnostic
-- at the first NUL byte.
--
-- escape_control() escapes only C0 control bytes (0x00-0x1F) and DEL
-- (0x7F).  Bytes >= 0x80 are echoed into the diagnostic unchanged: they are
-- neither escaped nor dropped, and escape_control() never rejects them.
-- (The name character-set check may of course still reject the line.)
--
-- Strictness rules (on purpose, so nothing is ever skipped silently):
--   * an entry before the first [section] is rejected; there is no implicit
--     global section, so a misplaced key is never silently hoisted.
--   * a duplicate key inside a section is rejected and the message names
--     both lines; silently overriding a value hides typos.
--   * repeated [section] headers are merged, so a file may grow a section in
--     several places.
--   * keys and section names are [A-Za-z0-9_.-]+; anything else is a
--     malformed line.
--   * '0x' values with invalid hex digits, unsigned numbers outside
--     0..0xFFFFFFFF, signed numbers outside -2147483648..-1, list values
--     with an empty element and unterminated list values are rejected
--     instead of degrading to strings.
--   * a line ending in CRLF is accepted; a lone CR is not a line separator.
---------------------------------------------------------------------------

local Parser = {}

local MAX_CONTENT = 64 * 1024
local MAX_LINE    = 256
local MAX_ENTRIES = 4096
local MAX_NUMBER  = 0xFFFFFFFF
local MIN_NUMBER  = -2147483648

---------------------------------------------------------------------------
-- Error helper
---------------------------------------------------------------------------

-- Two hex digits per control byte value, e.g. HEX_BYTE[0] == "00".
local HEX_BYTE = {}
for i = 0, 31 do
    HEX_BYTE[i] = string.format("%02X", i)
end
HEX_BYTE[127] = "7F"

-- Replace C0 control bytes and DEL with their \xNN spelling so a diagnostic
-- stays readable and never contains a raw NUL.
local function escape_control(text)
    local parts = {}
    for i = 1, #text do
        local byte = string.byte(text, i)
        local code = HEX_BYTE[byte]
        if code == nil then
            parts[#parts + 1] = string.char(byte)
        else
            parts[#parts + 1] = "\\x" .. code
        end
    end
    return table.concat(parts)
end

local function fail(lineno, message)
    -- No string.format("%s") anywhere in the error path: user text may hold
    -- NUL bytes, and the C string formatting path on CraftOS truncates there.
    error("config_parser: line " .. lineno .. ": "
        .. escape_control(message), 0)
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- Line parsing
---------------------------------------------------------------------------

-- Called with a trimmed line that starts with '['.
local function parse_section(line, lineno)
    if line:sub(-1) ~= "]" then
        fail(lineno, "section header must end with ']': '" .. line .. "'")
    end
    local name = trim(line:sub(2, -2))
    if name == "" then
        fail(lineno, "empty section name in '" .. line .. "'")
    end
    if not name:match("^[%w_%.%-]+$") then
        fail(lineno, "invalid section name '" .. name
            .. "' (allowed: letters, digits, '_', '.', '-')")
    end
    return name
end

-- Called with a trimmed line that does not start with '['.
local function parse_entry(line, lineno)
    local equals = line:find("=", 1, true)
    if equals == nil then
        fail(lineno, "expected 'key=value' or '[section]', got '"
            .. line .. "'")
    end
    local key = trim(line:sub(1, equals - 1))
    local value = trim(line:sub(equals + 1))
    if key == "" then
        fail(lineno, "missing key name before '=' in '" .. line .. "'")
    end
    if not key:match("^[%w_%.%-]+$") then
        fail(lineno, "invalid key name '" .. key
            .. "' (allowed: letters, digits, '_', '.', '-')")
    end
    return key, value
end

---------------------------------------------------------------------------
-- Value conversion
---------------------------------------------------------------------------

-- Reject NaN, infinities and values outside the 32-bit linear address range.
-- Called after every numeric conversion: the digit-count checks below should
-- already catch these, so this is the explicit second line of defence.
local function check_number(value, text, lineno)
    if value ~= value
        or value == math.huge
        or value == -math.huge
        or value < 0
        or value > MAX_NUMBER then
        fail(lineno, "number out of range: '" .. text
            .. "' (allowed 0..0xFFFFFFFF)")
    end
    return value
end

local function parse_hex(text, digits, lineno)
    -- Leading zeros never make a short value long: drop them first.
    local significant = digits:gsub("^0+", "")
    if #significant > 8 then
        fail(lineno, "hexadecimal number has too many digits: '" .. text
            .. "' (allowed 0..0xFFFFFFFF)")
    end
    return check_number(tonumber(digits, 16), text, lineno)
end

local function parse_decimal(text, digits, lineno)
    local significant = digits:gsub("^0+", "")
    if #significant > 10 then
        fail(lineno, "decimal number has too many digits: '" .. text
            .. "' (allowed 0..0xFFFFFFFF)")
    end
    if #significant == 10 and significant > "4294967295" then
        fail(lineno, "number out of range: '" .. text
            .. "' (allowed 0..0xFFFFFFFF)")
    end
    return check_number(tonumber(digits, 10), text, lineno)
end

-- Negative decimal for non-address options (for example max_tick=-1).  The
-- digit-count guard runs before tonumber() for the same reason as above.
local function parse_signed_decimal(text, digits, lineno)
    local significant = digits:gsub("^0+", "")
    if #significant > 10 then
        fail(lineno, "decimal number has too many digits: '" .. text
            .. "' (allowed -2147483648..-1)")
    end
    if #significant == 10 and significant > "2147483648" then
        fail(lineno, "number out of range: '" .. text
            .. "' (allowed -2147483648..-1)")
    end
    local value = -tonumber(digits, 10)
    if value ~= value
        or value == math.huge
        or value == -math.huge
        or value < MIN_NUMBER
        or value > -1 then
        fail(lineno, "number out of range: '" .. text
            .. "' (allowed -2147483648..-1)")
    end
    return value
end

-- Called with a trimmed value that starts with '[' and ends with ']'.
local function parse_list(value, lineno)
    local inner = trim(value:sub(2, -2))
    if inner == "" then
        return {}
    end
    -- No quoting or escaping exists in a list, so a remaining bracket can
    -- only be a malformed outer match such as [A]] or [[A]].
    if inner:find("[%[%]]") then
        fail(lineno, "invalid '[' or ']' in list element: '" .. value .. "'")
    end
    local items = {}
    local start = 1
    while true do
        local comma = inner:find(",", start, true)
        local part
        if comma then
            part = inner:sub(start, comma - 1)
        else
            part = inner:sub(start)
        end
        part = trim(part)
        if part == "" then
            fail(lineno, "empty element in list value '" .. value .. "'")
        end
        items[#items + 1] = part
        if not comma then
            break
        end
        start = comma + 1
    end
    return items
end

local function parse_value(text, lineno)
    if text == "true" then
        return true
    end
    if text == "false" then
        return false
    end

    local hex = text:match("^0[xX](%x+)$")
    if hex then
        return parse_hex(text, hex, lineno)
    end
    if text:match("^0[xX]") then
        fail(lineno, "invalid hexadecimal number '" .. text .. "'")
    end

    if text:match("^%d+$") then
        return parse_decimal(text, text, lineno)
    end

    if text:match("^%-%d+$") then
        return parse_signed_decimal(text, text:sub(2), lineno)
    end

    if text:sub(1, 1) == "[" then
        if text:sub(-1) ~= "]" then
            fail(lineno, "malformed list value '" .. text
                .. "': missing ']'")
        end
        return parse_list(text, lineno)
    end

    return text
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- parse(content) -> table
--
-- content is the full text of 80486.cfg (a string, with '\n' or CRLF line
-- endings).  The result maps section names to tables of converted values.
function Parser.parse(content)
    if type(content) ~= "string" then
        error("config_parser: content must be a string (got "
            .. type(content) .. ")", 0)
    end

    -- A UTF-8 BOM would otherwise turn the first section header into a
    -- non-ASCII name.  Generated config files are plain ASCII; tolerate the
    -- single BOM that some editors write anyway.  Two BOMs are not a valid
    -- file and are rejected by the normal line parsing below.
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end

    -- Normalise CRLF once, so the 64 KiB cap is measured on the same bytes
    -- the line scanner walks: after BOM stripping and after the CR of every
    -- CRLF pair has been removed.  A lone CR is left in place (it is not a
    -- line separator) and therefore still counts towards the size cap.
    content = content:gsub("\r\n", "\n")

    if #content > MAX_CONTENT then
        -- Report the line on which the cap is crossed, not just "line 1".
        local _, newlines = content:sub(1, MAX_CONTENT):gsub("\n", "\n")
        fail(newlines + 1, "config file is too large: " .. #content
            .. " bytes (limit " .. MAX_CONTENT .. " bytes)")
    end

    local root = {}
    local current = nil
    local current_name = nil
    local first_line = {}   -- section table -> key -> line number
    local entries = 0

    local length = #content
    local pos = 1
    local lineno = 0
    while pos <= length do
        lineno = lineno + 1
        local newline = content:find("\n", pos, true)
        local line
        if newline then
            line = content:sub(pos, newline - 1)
            pos = newline + 1
        else
            line = content:sub(pos)
            pos = length + 1
        end
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        if #line > MAX_LINE then
            fail(lineno, "line too long: " .. #line
                .. " bytes (limit " .. MAX_LINE .. " bytes)")
        end
        line = trim(line)

        if line ~= ""
            and line:sub(1, 1) ~= "#"
            and line:sub(1, 1) ~= ";" then
            if line:sub(1, 1) == "[" then
                local name = parse_section(line, lineno)
                current_name = name
                current = root[name]
                if current == nil then
                    current = {}
                    root[name] = current
                    first_line[current] = {}
                end
            else
                local key, raw = parse_entry(line, lineno)
                if current == nil then
                    fail(lineno, "key '" .. key
                        .. "' appears before the first [section]")
                end
                entries = entries + 1
                if entries > MAX_ENTRIES then
                    fail(lineno, "too many entries (limit "
                        .. MAX_ENTRIES .. ")")
                end
                local seen = first_line[current]
                if seen[key] ~= nil then
                    fail(lineno, "duplicate key '" .. key
                        .. "' in section [" .. current_name
                        .. "] (first defined on line " .. seen[key] .. ")")
                end
                current[key] = parse_value(raw, lineno)
                seen[key] = lineno
            end
        end
    end

    return root
end

-- Exposed so callers and tests can reason about the hard limits.
Parser.MAX_CONTENT = MAX_CONTENT
Parser.MAX_LINE = MAX_LINE
Parser.MAX_ENTRIES = MAX_ENTRIES
Parser.MAX_NUMBER = MAX_NUMBER
Parser.MIN_NUMBER = MIN_NUMBER

return Parser
