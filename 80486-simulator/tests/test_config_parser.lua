---------------------------------------------------------------------------
-- 80486-simulator/tests/test_config_parser.lua
--
-- Standalone tests for config_parser.lua.  No test framework is required.
--
-- From the repository root:
--     lua 80486-simulator/tests/test_config_parser.lua
-- or, inside CraftOS:
--     dofile("80486-simulator/tests/test_config_parser.lua")
---------------------------------------------------------------------------

local function is_config_parser_module(mod)
    return type(mod) == "table"
        and type(mod.parse) == "function"
        and type(mod.MAX_CONTENT) == "number"
end

local function load_config_parser()
    local ok, mod = pcall(require, "config_parser")
    if ok and is_config_parser_module(mod) then
        return mod
    end

    -- Make the test runnable from the repo root, from 80486-simulator/, or
    -- from inside tests/ on CraftOS.
    local candidates = {
        "80486-simulator/config_parser.lua",
        "../config_parser.lua",
        "config_parser.lua",
        "/80486-simulator/config_parser.lua",
        "/config_parser.lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and is_config_parser_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load config_parser.lua: " .. tostring(last_error))
end

local Parser = load_config_parser()
local concat = table.concat
local nul = string.char(0)

local total   = 0
local passed  = 0
local failed  = 0

local function show(v)
    if type(v) == "string" then
        if #v <= 40 then
            return string.format("%q", v)
        end
        return string.format("<string len=%d>", #v)
    end
    if type(v) == "table" then
        return "<table>"
    end
    return tostring(v)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function array_eq(got, want, label)
    label = label or "value"
    if type(got) ~= "table" then
        error(string.format("%s: expected a table, got %s", label, show(got)), 2)
    end
    eq(#got, #want, label .. " length")
    for i = 1, #want do
        eq(got[i], want[i], string.format("%s[%d]", label, i))
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" then
        error(string.format("%s: expected a string containing %q, got %s",
            label or "text", needle, show(text)), 2)
    end
    if not text:find(needle, 1, true) then
        error(string.format("%s: %q does not contain %q",
            label or "text", text, needle), 2)
    end
end

local function expect_error(fn, needle)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, but the call succeeded", 2)
    end
    if needle and not tostring(err):find(needle, 1, true) then
        error("error message does not contain " .. needle
            .. ": " .. tostring(err), 2)
    end
    return err
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok      " .. name)
    else
        failed = failed + 1
        print("FAIL    " .. name)
        print("        " .. tostring(err))
    end
end

---------------------------------------------------------------------------

test("sections and scalar entries", function()
    local cfg = Parser.parse(concat({
        "[memory]",
        "size=16777216",
        "base=0xF0000",
        "",
        "[cpu]",
        "mode=real",
        "",
        "[vga]",
        "text_base=0xB8000",
    }, "\n"))

    eq(type(cfg), "table", "root")
    eq(type(cfg.memory), "table", "memory section")
    eq(type(cfg.cpu), "table", "cpu section")
    eq(type(cfg.vga), "table", "vga section")
    eq(cfg.memory.size, 16777216, "memory.size")
    eq(cfg.memory.base, 0xF0000, "memory.base")
    eq(type(cfg.memory.base), "number", "memory.base type")
    eq(cfg.cpu.mode, "real", "cpu.mode")
    eq(cfg.vga.text_base, 0xB8000, "vga.text_base")
end)

test("comments and blank lines are ignored", function()
    local cfg = Parser.parse(concat({
        "; leading comment",
        "# another comment",
        "",
        "   ",
        "   ; indented comment",
        "\t# tab-indented comment",
        "[boot]",
        "; comment between entries",
        "drive=0x80",
        "",
        "# trailing comment",
    }, "\n"))

    local names = {}
    for name in pairs(cfg) do
        names[#names + 1] = name
    end
    eq(#names, 1, "only one section")
    eq(names[1], "boot", "section name")
    eq(cfg.boot.drive, 0x80, "boot.drive")
end)

test("boolean values", function()
    local cfg = Parser.parse("[cpu]\nturbo=true\ncache=false\n")

    eq(cfg.cpu.turbo, true, "turbo")
    eq(cfg.cpu.cache, false, "cache")
    eq(type(cfg.cpu.turbo), "boolean", "turbo type")
    eq(type(cfg.cpu.cache), "boolean", "cache type")
end)

test("decimal and hexadecimal numbers", function()
    local cfg = Parser.parse(concat({
        "[io]",
        "port=0x3F8",
        "irq=4",
        "zero=0",
        "upper=0XFFFF",
        "leading=007",
        "neg=-1",
        "big=0xF0000",
    }, "\n"))

    eq(cfg.io.port, 0x3F8, "hex port")
    eq(cfg.io.irq, 4, "decimal irq")
    eq(cfg.io.zero, 0, "zero")
    eq(cfg.io.upper, 0xFFFF, "uppercase 0X prefix")
    eq(cfg.io.leading, 7, "leading zeros")
    eq(cfg.io.neg, -1, "negative decimal is a number")
    eq(type(cfg.io.neg), "number", "negative decimal type")
    eq(cfg.io.big, 0xF0000, "large hex value")
    eq(type(cfg.io.irq), "number", "decimal type")
end)

test("number boundaries and overflow guards", function()
    local cfg = Parser.parse(concat({
        "[num]",
        "hex_max=0xFFFFFFFF",
        "dec_max=4294967295",
        "zero=0x0000000000000000",
        "padded=0x00000000FFFFFFFF",
    }, "\n"))
    eq(cfg.num.hex_max, 0xFFFFFFFF, "hex max")
    eq(cfg.num.dec_max, 4294967295, "decimal max")
    eq(cfg.num.zero, 0, "zero with leading zeros")
    eq(cfg.num.padded, 0xFFFFFFFF, "leading zeros do not overflow")

    local err = expect_error(function()
        Parser.parse("[num]\nhex=0x100000000\n")
    end, "line 2")
    contains(tostring(err), "too many digits", "hex over eight digits")

    err = expect_error(function()
        Parser.parse("[num]\ndec=4294967296\n")
    end, "line 2")
    contains(tostring(err), "out of range", "decimal just over max")
    contains(tostring(err), "0xFFFFFFFF", "allowed range is reported")

    err = expect_error(function()
        Parser.parse("[num]\ndec=9999999999\n")
    end, "line 2")
    contains(tostring(err), "out of range", "ten digit decimal over max")

    -- 250 digits fit on one line, so the digit-count guard has to fire.
    err = expect_error(function()
        Parser.parse("[num]\nhex=0x" .. string.rep("F", 250) .. "\n")
    end, "line 2")
    contains(tostring(err), "too many digits", "long hex digit run")

    err = expect_error(function()
        Parser.parse("[num]\ndec=" .. string.rep("9", 250) .. "\n")
    end, "line 2")
    contains(tostring(err), "too many digits", "long decimal digit run")

    -- 400 digits cross the per-line limit before the number is even parsed.
    err = expect_error(function()
        Parser.parse("[num]\nhex=0x" .. string.rep("F", 400) .. "\n")
    end, "line 2")
    contains(tostring(err), "too long", "400 hex digits")

    err = expect_error(function()
        Parser.parse("[num]\ndec=" .. string.rep("9", 400) .. "\n")
    end, "line 2")
    contains(tostring(err), "too long", "400 decimal digits")
end)

test("signed numbers for non-address options", function()
    -- [watchdog] max_tick=-1 must survive parsing as the number -1.
    local cfg = Parser.parse(concat({
        "[watchdog]",
        "max_tick=-1",
        "floor=-2147483648",
        "padded=-0000000001",
    }, "\n"))
    eq(cfg.watchdog.max_tick, -1, "negative one")
    eq(cfg.watchdog.floor, -2147483648, "signed minimum")
    eq(cfg.watchdog.padded, -1, "leading zeros after the sign")
    eq(Parser.MIN_NUMBER, -2147483648, "MIN_NUMBER")

    local err = expect_error(function()
        Parser.parse("[watchdog]\nv=-2147483649\n")
    end, "line 2")
    contains(tostring(err), "-2147483648..-1", "signed range is reported")

    expect_error(function()
        Parser.parse("[watchdog]\nv=-99999999999999999999\n")
    end, "line 2")
end)

test("empty and populated lists", function()
    local cfg = Parser.parse(concat({
        "[boot]",
        "empty=[]",
        "spaced_empty=[ ]",
        "single=[A]",
        "pair=[A,B]",
        "spaces=[ A , B , C ]",
        "numbers=[1,0x10]",
    }, "\n"))

    array_eq(cfg.boot.empty, {}, "empty")
    array_eq(cfg.boot.spaced_empty, {}, "spaced empty")
    array_eq(cfg.boot.single, {"A"}, "single")
    array_eq(cfg.boot.pair, {"A", "B"}, "pair")
    array_eq(cfg.boot.spaces, {"A", "B", "C"}, "spaces")
    array_eq(cfg.boot.numbers, {"1", "0x10"}, "list elements stay strings")
end)

test("brackets inside list elements are rejected", function()
    local bad = {
        "list=[A]]",
        "list=[A][B]",
        "list=[A],[B]",
        "list=[]]",
        "list=[[A]]",
    }
    for i = 1, #bad do
        local err = expect_error(function()
            Parser.parse("[s]\n" .. bad[i] .. "\n")
        end, "line 2")
        contains(tostring(err), "invalid '[' or ']' in list element",
            "case " .. i)
    end
end)

test("plain strings are preserved", function()
    local cfg = Parser.parse(concat({
        "[paths]",
        "empty=",
        "text=hello world",
        "equals=a=b",
        "punct=C:\\DOS #1",
        "semicolon=x;y",
        "hash=#tag",
    }, "\n"))

    eq(cfg.paths.empty, "", "empty value")
    eq(type(cfg.paths.empty), "string", "empty value type")
    eq(cfg.paths.text, "hello world", "inner spaces kept")
    eq(cfg.paths.equals, "a=b", "only the first '=' splits")
    eq(cfg.paths.punct, "C:\\DOS #1", "backslash and '#' kept")
    eq(cfg.paths.semicolon, "x;y", "inline ';' kept")
    eq(cfg.paths.hash, "#tag", "value may start with '#'")
end)

test("whitespace around sections, keys and values", function()
    local cfg = Parser.parse(concat({
        "   [ boot ]   ",
        "  drive = 0x80  ",
        "  vga.text-base = 0xB8000 ",
        "\t[ cpu ]\t",
        " speed = 33 ",
    }, "\n"))

    eq(cfg.boot.drive, 0x80, "trimmed key/value")
    eq(cfg.boot["vga.text-base"], 0xB8000, "dot and dash in key")
    eq(cfg.cpu.speed, 33, "tab trimmed")
end)

test("repeated sections merge and CRLF is accepted", function()
    local cfg = Parser.parse(concat({
        "[cpu]\r",
        "speed=33\r",
        "[bus]\r",
        "width=16\r",
        "[cpu]\r",
        "turbo=true\r",
    }, "\n"))

    eq(cfg.cpu.speed, 33, "first cpu entry")
    eq(cfg.cpu.turbo, true, "merged cpu entry")
    eq(cfg.bus.width, 16, "bus entry")
end)

test("empty input and comment-only input", function()
    local cfg = Parser.parse("")
    eq(type(cfg), "table", "empty root")
    eq(next(cfg), nil, "no sections in empty input")

    cfg = Parser.parse("\n\n; only comments\n# nothing else\n")
    eq(next(cfg), nil, "no sections in comment-only input")
end)

test("a single UTF-8 BOM is tolerated", function()
    local bom = "\239\187\191"
    local cfg = Parser.parse(bom .. "[cpu]\nspeed=33\n")
    eq(cfg.cpu.speed, 33, "section after BOM")

    local err = expect_error(function()
        Parser.parse(bom .. bom .. "[cpu]\nspeed=33\n")
    end, "line 1")
    contains(tostring(err), "expected 'key=value' or '[section]'",
        "double BOM is not stripped twice")
end)

test("parse calls are independent", function()
    local a = Parser.parse("[x]\nk=1\n")
    local b = Parser.parse("[x]\nk=2\n")
    eq(a.x.k, 1, "first parse")
    eq(b.x.k, 2, "second parse")
end)

test("realistic 80486.cfg sample", function()
    local text = concat({
        "; 80486.cfg -- machine configuration",
        "[machine]",
        "memory_bytes=16777216",
        "",
        "[cpu]",
        "reset_vector=0xFFFF0",
        "turbo=true",
        "",
        "[vga]",
        "text_base=0xB8000",
        "columns=80",
        "boot_drives=[0x00,0x80]",
        "",
        "[debug]",
        "trace=false",
    }, "\n")

    local cfg = Parser.parse(text)
    eq(cfg.machine.memory_bytes, 16777216, "machine.memory_bytes")
    eq(cfg.cpu.reset_vector, 0xFFFF0, "cpu.reset_vector")
    eq(cfg.cpu.turbo, true, "cpu.turbo")
    eq(cfg.vga.text_base, 0xB8000, "vga.text_base")
    eq(cfg.vga.columns, 80, "vga.columns")
    array_eq(cfg.vga.boot_drives, {"0x00", "0x80"}, "vga.boot_drives")
    eq(cfg.debug.trace, false, "debug.trace")
    eq(cfg.missing, nil, "unknown section is absent")
end)

test("hard limits are exposed", function()
    eq(Parser.MAX_CONTENT, 64 * 1024, "MAX_CONTENT")
    eq(Parser.MAX_LINE, 256, "MAX_LINE")
    eq(Parser.MAX_ENTRIES, 4096, "MAX_ENTRIES")
    eq(Parser.MAX_NUMBER, 0xFFFFFFFF, "MAX_NUMBER")
end)

test("malformed lines raise errors that name the line", function()
    local err = expect_error(function()
        Parser.parse("key=1\n[boot]\n")
    end, "line 1")
    contains(tostring(err), "before the first [section]",
        "entry before a section")

    err = expect_error(function()
        Parser.parse("[cpu]\nkey = 1\nbroken line\n")
    end, "line 3")
    contains(tostring(err), "config_parser:", "module prefix")

    err = expect_error(function()
        Parser.parse("[cpu]\nport=0xZZ\n")
    end, "line 2")
    contains(tostring(err), "invalid hexadecimal", "bad hex is rejected")

    err = expect_error(function()
        Parser.parse("[boot]\nlist=[A,B\n")
    end, "line 2")
    contains(tostring(err), "missing ']'", "unterminated list")

    err = expect_error(function()
        Parser.parse("[boot]\nlist=[A,,B]\n")
    end, "line 2")
    contains(tostring(err), "empty element", "empty list element")

    err = expect_error(function()
        Parser.parse("[boot]\nlist=[A,]\n")
    end, "line 2")
    contains(tostring(err), "empty element", "trailing comma")
end)

test("malformed sections raise errors that name the line", function()
    local err = expect_error(function()
        Parser.parse("[cpu\nspeed=33\n")
    end, "line 1")
    contains(tostring(err), "must end with ']'", "unterminated section")

    err = expect_error(function()
        Parser.parse("[cpu] trailing\nspeed=33\n")
    end, "line 1")
    contains(tostring(err), "must end with ']'", "trailing text after header")

    err = expect_error(function()
        Parser.parse("[]\nspeed=33\n")
    end, "line 1")
    contains(tostring(err), "empty section name", "empty section name")
end)

test("section names use the same character set as keys", function()
    local names = {
        "[a=b]",
        "[a b]",
        "[a" .. nul .. "b]",
    }
    for i = 1, #names do
        local err = expect_error(function()
            Parser.parse(names[i] .. "\nk=1\n")
        end, "line 1")
        contains(tostring(err), "invalid section name", "case " .. i)
    end

    local err = expect_error(function()
        Parser.parse("[a" .. nul .. "b]\nk=1\n")
    end, "line 1")
    contains(tostring(err), "\\x00", "NUL escaped in section name")
    contains(tostring(err), "(allowed: letters, digits, '_', '.', '-')",
        "section character set is reported")
end)

test("malformed entries raise errors that name the line", function()
    local err = expect_error(function()
        Parser.parse("[cpu]\n=33\n")
    end, "line 2")
    contains(tostring(err), "missing key name", "missing key")

    err = expect_error(function()
        Parser.parse("[cpu]\nbad key=33\n")
    end, "line 2")
    contains(tostring(err), "invalid key name", "invalid key")

    err = expect_error(function()
        Parser.parse("[cpu]\nspeed=33\nspeed=66\n")
    end, "line 3")
    contains(tostring(err), "duplicate key", "duplicate key")
    contains(tostring(err), "line 2", "duplicate names the first line")
end)

test("duplicate key across a reopened section is rejected", function()
    -- Lines: 1 [s], 2 k=1, 3 [t], 4 x=1, 5 [s], 6 k=2.
    local err = expect_error(function()
        Parser.parse("[s]\nk=1\n[t]\nx=1\n[s]\nk=2\n")
    end, "line 6")
    contains(tostring(err), "duplicate key", "duplicate after reopening")
    contains(tostring(err), "line 2", "names the first definition")
end)

test("NUL bytes never truncate the error message", function()
    local err = expect_error(function()
        Parser.parse("[s]\nk" .. nul .. "=1\n")
    end, "line 2")
    local text = tostring(err)
    contains(text, "(allowed: letters, digits, '_', '.', '-')",
        "full key-name diagnostic")
    contains(text, "\\x00", "NUL is escaped")
    eq(text:find(nul, 1, true), nil, "error text has no raw NUL")
end)

test("NUL in a value does not disturb line numbers", function()
    local cfg = Parser.parse("[s]\nv=a" .. nul .. "b\n")
    eq(type(cfg.s.v), "string", "value type")
    eq(#cfg.s.v, 3, "value length")
    eq(cfg.s.v:byte(1), 97, "first byte")
    eq(cfg.s.v:byte(2), 0, "NUL byte kept")
    eq(cfg.s.v:byte(3), 98, "last byte")

    local err = expect_error(function()
        Parser.parse("[s]\nv=a" .. nul .. "b\nbroken line\n")
    end, "line 3")
    contains(tostring(err), "expected 'key=value'", "error after NUL value")

    err = expect_error(function()
        Parser.parse("[s]\nport=0x" .. nul .. "\n")
    end, "line 2")
    contains(tostring(err), "invalid hexadecimal", "NUL inside hex")
    contains(tostring(err), "\\x00", "NUL escaped in hex diagnostic")
end)

test("a lone CR is not a line separator", function()
    local err = expect_error(function()
        Parser.parse("[s]\ra=1\r")
    end, "line 1")
    contains(tostring(err), "must end with ']'", "whole text is one line")
    contains(tostring(err), "\\x0D", "CR is escaped in the diagnostic")
end)

test("CRLF files keep correct error line numbers", function()
    local err = expect_error(function()
        Parser.parse("[s]\r\nok=1\r\nbroken\r\n")
    end, "line 3")
    contains(tostring(err), "expected 'key=value'", "line three is the bad one")
end)

test("bare 0x and 0X are invalid hexadecimal numbers", function()
    local err = expect_error(function()
        Parser.parse("[s]\na=0x\n")
    end, "line 2")
    contains(tostring(err), "invalid hexadecimal", "bare 0x")

    err = expect_error(function()
        Parser.parse("[s]\na=0X\n")
    end, "line 2")
    contains(tostring(err), "invalid hexadecimal", "bare 0X")
end)

test("file size limit is enforced", function()
    local text = string.rep("a=1\n", 20000)
    eq(#text, 80000, "test input size")
    local err = expect_error(function()
        Parser.parse(text)
    end, "line 16385")
    contains(tostring(err), "too large", "size diagnostic")
    contains(tostring(err), "limit", "limit is reported")
end)

test("line length limit is enforced", function()
    local key = string.rep("x", 254)      -- key .. "=1" is exactly 256 bytes
    local cfg = Parser.parse("[s]\n" .. key .. "=1\n")
    eq(cfg.s[key], 1, "line at the limit is accepted")

    local err = expect_error(function()
        Parser.parse("[s]\n" .. string.rep("x", 255) .. "=1\n")
    end, "line 2")
    contains(tostring(err), "line too long", "257 byte line")
end)

test("entry count limit is enforced", function()
    local parts = {"[s]"}
    for i = 1, 4097 do
        parts[#parts + 1] = "k" .. i .. "=1"
    end
    local err = expect_error(function()
        Parser.parse(concat(parts, "\n"))
    end, "line 4098")
    contains(tostring(err), "too many entries", "entry limit")
end)

test("non-string input is rejected", function()
    expect_error(function() Parser.parse(nil) end, "must be a string")
    expect_error(function() Parser.parse(42) end, "must be a string")
end)

test("content size boundary at 64 KiB", function()
    -- One section, one entry and comment padding; every line ends with '\n'.
    -- 3 + 3 + 16382 * 3 bytes of text plus 16384 newlines is exactly 65536.
    local parts = {"[s]", "k=1"}
    for _ = 1, 16382 do
        parts[#parts + 1] = ";;;"
    end
    local exact = concat(parts, "\n") .. "\n"
    eq(#exact, 65536, "byte length at the limit")
    local cfg = Parser.parse(exact)
    eq(cfg.s.k, 1, "entry at the size limit is parsed")

    -- One extra byte on the last comment line: 65537 bytes, still valid.
    parts[#parts] = ";;;;"
    local over = concat(parts, "\n") .. "\n"
    eq(#over, 65537, "byte length over the limit")
    -- A file of MAX_CONTENT + 1 bytes that ends with '\n' loses exactly that
    -- final newline from the size-check prefix, so the reported line is the
    -- total number of lines in the file.
    local err = expect_error(function()
        Parser.parse(over)
    end, "line " .. #parts)
    contains(tostring(err), "too large", "size diagnostic at the boundary")
end)

test("entry count boundary at 4096", function()
    local parts = {"[s]"}
    for i = 1, Parser.MAX_ENTRIES do
        parts[#parts + 1] = "k" .. i .. "=1"
    end
    local text = concat(parts, "\n") .. "\n"
    eq(#text < Parser.MAX_CONTENT, true, "boundary file fits in 64 KiB")
    local cfg = Parser.parse(text)
    local count = 0
    for _ in pairs(cfg.s) do
        count = count + 1
    end
    eq(count, 4096, "stored key count at the limit")
    eq(cfg.s.k1, 1, "first entry at the limit")
    eq(cfg.s.k4096, 1, "last entry at the limit")

    -- The 4097th entry is on line 4098 because line 1 is the [s] header.
    parts[#parts + 1] = "k4097=1"
    local err = expect_error(function()
        Parser.parse(concat(parts, "\n") .. "\n")
    end, "line 4098")
    contains(tostring(err), "too many entries", "entry limit diagnostic")
end)

test("bracket and section name boundaries", function()
    local bad = {
        "[A]B]",
        "[A] [B]",
        "[[A]",
    }
    for i = 1, #bad do
        local err = expect_error(function()
            Parser.parse("[s]\nv=" .. bad[i] .. "\n")
        end, "line 2")
        contains(tostring(err), "invalid '[' or ']' in list element",
            "case " .. i)
    end

    local cfg = Parser.parse("[a_b.c-d]\nk=1\n")
    eq(type(cfg["a_b.c-d"]), "table", "punctuated section name")
    eq(cfg["a_b.c-d"].k, 1, "key inside punctuated section")
end)

test("number text length boundaries", function()
    local err = expect_error(function()
        Parser.parse("[n]\nhex=0xFFFFFFFFF\n")
    end, "line 2")
    contains(tostring(err), "too many digits", "nine hex digits")

    local cfg = Parser.parse("[n]\ndec=00000000004294967295\n")
    eq(cfg.n.dec, 4294967295, "padded decimal max")
    eq(type(cfg.n.dec), "number", "padded decimal type")
end)

test("ESC and DEL are escaped in diagnostics", function()
    local esc = string.char(27)
    local del = string.char(127)
    local allowed = "(allowed: letters, digits, '_', '.', '-')"

    local err = expect_error(function()
        Parser.parse("[s]\nk" .. esc .. "=1\n")
    end, "line 2")
    local text = tostring(err)
    contains(text, "\\x1B", "ESC is escaped")
    contains(text, allowed, "key-name diagnostic for ESC")
    eq(text:find(esc, 1, true), nil, "error text has no raw ESC")

    err = expect_error(function()
        Parser.parse("[s]\nk" .. del .. "=1\n")
    end, "line 2")
    text = tostring(err)
    contains(text, "\\x7F", "DEL is escaped")
    contains(text, allowed, "key-name diagnostic for DEL")
    eq(text:find(del, 1, true), nil, "error text has no raw DEL")
end)

---------------------------------------------------------------------------

print(string.format(
    "config_parser_test: %d total, %d passed, 0 skipped, %d failed",
    total, passed, failed))

if failed > 0 then
    error(string.format("%d config parser test(s) failed", failed), 0)
end

return true
