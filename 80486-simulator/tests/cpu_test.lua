---------------------------------------------------------------------------
-- 80486-simulator/tests/cpu_test.lua
--
-- Standalone tests for cpu.lua.  No test framework is required.
--
-- From the repository root:
--     lua 80486-simulator/tests/cpu_test.lua
-- or, inside CraftOS:
--     dofile("/tests/cpu_test.lua")
--
-- A test that cannot run because the environment lacks a required API must
-- raise error({ __skip = "reason" }, 0); such a test is counted as skipped
-- and never as passed.
---------------------------------------------------------------------------

local floor = math.floor

local function is_cpu_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and type(mod.Device) == "table"
        and mod.SLEEP_INTERVAL == 200
end

local function is_memory_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.PAGE_SIZE == 4096
        and type(mod.Memory) == "table"
end

local function load_module(require_name, candidates, validator, label)
    local ok, mod = pcall(require, require_name)
    if ok and validator(mod) then
        return mod
    end

    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and validator(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load " .. label .. ": " .. tostring(last_error))
end

local Cpu = load_module("cpu", {
    "80486-simulator/cpu.lua",
    "../cpu.lua",
    "cpu.lua",
    "/80486-simulator/cpu.lua",
    "/cpu.lua",
}, is_cpu_module, "cpu.lua")

local Memory = load_module("memory", {
    "80486-simulator/memory.lua",
    "../memory.lua",
    "memory.lua",
    "/80486-simulator/memory.lua",
    "/memory.lua",
}, is_memory_module, "memory.lua")

---------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------

local total   = 0
local passed  = 0
local skipped = 0
local failed  = 0

local function show(v)
    if type(v) == "string" then
        if #v <= 40 then
            return string.format("%q", v)
        end
        return string.format("<string len=%d>", #v)
    end
    if type(v) == "number" and v == v and v % 1 == 0 and v >= 0 then
        return string.format("0x%X (%d)", v, v)
    end
    return tostring(v)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function contains(text, needle, label)
    local haystack = tostring(text)
    if not haystack:find(needle, 1, true) then
        error(string.format("%s: expected to contain %q, got %q",
            label or "value", needle, haystack), 2)
    end
end

local function expect_error(fn, ...)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, but the call succeeded", 2)
    end
    local text = tostring(err)
    local needles = select("#", ...)
    for i = 1, needles do
        local needle = select(i, ...)
        if needle and not text:find(needle, 1, true) then
            error(string.format("error message does not contain %q: %s",
                needle, text), 2)
        end
    end
    return text
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    elseif type(err) == "table" and err.__skip then
        skipped = skipped + 1
        print("skip " .. name .. ": " .. tostring(err.__skip))
    else
        failed = failed + 1
        print("FAIL " .. name)
        print("     " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- CPU helpers
---------------------------------------------------------------------------

local CS = 0x1000
local DS = 0x2000
local ES = 0x3000
local SS = 0x4000
local SP = 0x8000

-- Create a CPU with a 16 MiB memory, distinct segments and a no-op sleep
-- function, so a test never blocks on the real os.sleep.
local function new_cpu(extra)
    local opts = {
        memory = Memory.new(),
        sleep  = function() end,
    }
    if extra ~= nil then
        for key, value in pairs(extra) do
            opts[key] = value
        end
    end
    local cpu = Cpu.new(opts)
    cpu.seg.cs = CS
    cpu.seg.ds = DS
    cpu.seg.es = ES
    cpu.seg.ss = SS
    cpu.ip = 0x0100
    cpu:set_reg16(4, SP)
    return cpu
end

-- Write a list of bytes into a segment at a 16-bit offset.
local function put(cpu, seg, offset, bytes)
    for i = 1, #bytes do
        cpu:write8(seg, offset + i - 1, bytes[i])
    end
end

-- Execute `count` instructions.
local function steps(cpu, count)
    for _ = 1, count do
        cpu:step()
    end
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

test("module surface and register helpers", function()
    eq(Cpu.SLEEP_INTERVAL, 200, "SLEEP_INTERVAL")
    eq(type(Cpu.Device), "table", "Device metatable")

    local cpu = new_cpu()
    eq(getmetatable(cpu), Cpu.Device, "instances use Cpu.Device as metatable")
    eq(cpu.ip, 0x0100, "initial IP")
    eq(cpu.halted, false, "not halted")
    eq(cpu.steps, 0, "no steps yet")

    cpu:set_reg16(0, 0x1234)
    eq(cpu.reg[0], 0x1234, "AX is reg[0]")
    eq(cpu:get_reg16(0), 0x1234, "AX")
    eq(cpu:get_reg8(0), 0x34, "AL")
    eq(cpu:get_reg8(4), 0x12, "AH")

    cpu:set_reg8(0, 0xAB)
    eq(cpu:get_reg16(0), 0x12AB, "AX after writing AL")
    cpu:set_reg8(4, 0xCD)
    eq(cpu:get_reg16(0), 0xCDAB, "AX after writing AH")
    eq(cpu:get_reg8(4), 0xCD, "AH")

    cpu:set_reg16(2, 0x1FFFF)
    eq(cpu:get_reg16(2), 0xFFFF, "16-bit register view is masked")

    -- reg[0..7] is AX CX DX BX SP BP SI DI.
    cpu:set_reg16(7, 0x0F0F)
    eq(cpu.reg[7], 0x0F0F, "DI is reg[7]")

    cpu:set_sreg("es", 0x1234)
    eq(cpu:get_sreg("es"), 0x1234, "ES")
    eq(cpu:get_sreg("cs"), CS, "CS")
    eq(cpu:get_sreg("ss"), SS, "SS")

    cpu:set_flag("CF", 1)
    eq(cpu:get_flag("CF"), true, "CF from a truthy value")
    cpu:set_flag("ZF", true)
    eq(cpu:get_flag("ZF"), true, "ZF set")
    cpu:set_flag("ZF", false)
    eq(cpu:get_flag("ZF"), false, "ZF cleared")
end)

test("memory helpers and stack are little-endian", function()
    local cpu = new_cpu()

    cpu:write16(DS, 0x0040, 0x1234)
    eq(cpu:read8(DS, 0x0040), 0x34, "low byte")
    eq(cpu:read8(DS, 0x0041), 0x12, "high byte")
    eq(cpu:read16(DS, 0x0040), 0x1234, "read16")
    cpu:write8(DS, 0x0042, 0x7F)
    eq(cpu:read8(DS, 0x0042), 0x7F, "read8")

    cpu:push16(0xABCD)
    eq(cpu:get_reg16(4), SP - 2, "SP after push")
    eq(cpu:read16(SS, SP - 2), 0xABCD, "pushed value")
    eq(cpu:pop16(), 0xABCD, "pop16")
    eq(cpu:get_reg16(4), SP, "SP restored")

    cpu:set_reg16(4, 0x0000)
    cpu:push16(0x1111)
    eq(cpu:get_reg16(4), 0xFFFE, "SP wraps below zero")
end)

test("MOV addressing: absolute disp16 and BX+SI", function()
    local cpu = new_cpu()

    -- MOV AX, [0x2000] with the default DS segment (mod = 0, rm = 6).
    cpu:write16(DS, 0x2000, 0xCAFE)
    put(cpu, CS, 0x0100, { 0x8B, 0x06, 0x00, 0x20 })
    cpu:step()
    eq(cpu:get_reg16(0), 0xCAFE, "MOV AX, [0x2000]")
    eq(cpu.ip, 0x0104, "IP after four bytes")

    -- MOV AX, [BX+SI]
    cpu:set_reg16(3, 0x0100)
    cpu:set_reg16(6, 0x0020)
    cpu:write16(DS, 0x0120, 0x55AA)
    cpu.ip = 0x0200
    put(cpu, CS, 0x0200, { 0x8B, 0x00 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x55AA, "MOV AX, [BX+SI]")

    -- MOV [BX+SI], AX writes to the same effective address.
    cpu:set_reg16(0, 0x1122)
    cpu.ip = 0x0300
    put(cpu, CS, 0x0300, { 0x89, 0x00 })
    cpu:step()
    eq(cpu:read16(DS, 0x0120), 0x1122, "MOV [BX+SI], AX")
end)

test("MOV addressing: BP defaults to SS, prefixes override segments", function()
    local cpu = new_cpu()

    cpu:set_reg16(5, 0x0040) -- BP
    cpu:set_reg16(3, 0x0010) -- BX
    cpu:write16(SS, 0x0050, 0x1111) -- [BP+0x10] via SS
    cpu:write16(DS, 0x0010, 0x2222) -- DS:[BX]
    cpu:write16(CS, 0x0010, 0x3333) -- CS:[BX]
    cpu:write16(SS, 0x0010, 0x4444) -- SS:[BX]
    cpu:write16(ES, 0x0010, 0x5555) -- ES:[BX]

    -- MOV AX, [BP+disp8] uses SS by default.
    put(cpu, CS, 0x0100, { 0x8B, 0x46, 0x10 })
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_reg16(0), 0x1111, "BP memory default segment is SS")

    -- 0x26 ES: MOV AX, [BX]
    cpu.ip = 0x0200
    put(cpu, CS, 0x0200, { 0x26, 0x8B, 0x07 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x5555, "ES override")

    -- 0x2E CS: MOV AX, [BX]
    cpu.ip = 0x0300
    put(cpu, CS, 0x0300, { 0x2E, 0x8B, 0x07 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x3333, "CS override")

    -- 0x36 SS: MOV AX, [BX]
    cpu.ip = 0x0400
    put(cpu, CS, 0x0400, { 0x36, 0x8B, 0x07 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x4444, "SS override")

    -- 0x3E DS: MOV AX, [BX]
    cpu.ip = 0x0500
    put(cpu, CS, 0x0500, { 0x3E, 0x8B, 0x07 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x2222, "DS override")
end)

test("DAS second adjustment uses the adjusted AL (0x9F boundary)", function()
    -- 0x9A: low-nibble adjust -> 0x94, which is <= 0x9F, so no -0x60 step.
    local cpu = new_cpu()
    cpu:set_reg16(0, 0x009A)
    cpu:set_flag("AF", false)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0100
    put(cpu, CS, 0x0100, { 0x2F })
    cpu:step()
    eq(cpu:get_reg8(0), 0x94, "DAS 0x9A -> 0x94")
    eq(cpu:get_flag("CF"), false, "DAS 0x9A keeps CF clear")

    -- 0x9F: -> 0x99.
    cpu:set_reg16(0, 0x009F)
    cpu:set_flag("AF", false)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0101
    put(cpu, CS, 0x0101, { 0x2F })
    cpu:step()
    eq(cpu:get_reg8(0), 0x99, "DAS 0x9F -> 0x99")
    eq(cpu:get_flag("CF"), false, "DAS 0x9F keeps CF clear")

    -- 0xA0 with AF=1: subtract 6 first -> 0x9A (no second step).
    cpu:set_reg16(0, 0x00A0)
    cpu:set_flag("AF", true)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0102
    put(cpu, CS, 0x0102, { 0x2F })
    cpu:step()
    eq(cpu:get_reg8(0), 0x9A, "DAS 0xA0+AF -> 0x9A")
    eq(cpu:get_flag("AF"), true, "DAS 0xA0+AF sets AF")

    -- A borrow across the nibble must take the second step: 0x00 with AF=1
    -- becomes 0xFA, which is > 0x9F, so -0x60 -> 0x9A and CF=1.
    cpu:set_reg16(0, 0x0000)
    cpu:set_flag("AF", true)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0103
    put(cpu, CS, 0x0103, { 0x2F })
    cpu:step()
    eq(cpu:get_reg8(0), 0x9A, "DAS 0x00+AF -> 0x9A")
    eq(cpu:get_flag("CF"), true, "DAS borrow sets CF")
end)

test("LAHF and SAHF move the low flag byte", function()
    local cpu = new_cpu()

    -- LAHF (9F) stores SF:ZF:0:AF:0:PF:1:CF in AH.
    cpu:set_flag("CF", true)
    cpu:set_flag("PF", false)
    cpu:set_flag("AF", true)
    cpu:set_flag("ZF", true)
    cpu:set_flag("SF", false)
    cpu.ip = 0x0100
    put(cpu, CS, 0x0100, { 0x9F })
    cpu:step()
    eq(cpu:get_reg8(4), 0x53, "AH = packed flags")

    -- SAHF (9E) restores CF/PF/AF/ZF/SF from AH and leaves OF alone.
    cpu:set_flag("CF", false)
    cpu:set_flag("PF", true)
    cpu:set_flag("AF", false)
    cpu:set_flag("ZF", false)
    cpu:set_flag("SF", true)
    cpu:set_flag("OF", true)
    cpu.ip = 0x0101
    put(cpu, CS, 0x0101, { 0x9E })
    cpu:step()
    eq(cpu:get_flag("CF"), true, "CF restored")
    eq(cpu:get_flag("PF"), false, "PF restored")
    eq(cpu:get_flag("AF"), true, "AF restored")
    eq(cpu:get_flag("ZF"), true, "ZF restored")
    eq(cpu:get_flag("SF"), false, "SF restored")
    eq(cpu:get_flag("OF"), true, "OF untouched")
end)

test("LAHF/SAHF keep comparison flags across an arithmetic instruction", function()
    -- COMMAND.COM's internal command lookup does: REPE CMPSB; LAHF;
    -- ADD SI,CX (clobbers flags); SAHF; JNZ next-entry.  If LAHF and SAHF
    -- are swapped, the match's ZF is lost and every command falls through to
    -- the "external file" path (DOS: Bad command or file name).
    local cpu = new_cpu()
    cpu:set_flag("CF", true)
    cpu:set_flag("ZF", true)
    cpu:set_reg16(6, 0x0000) -- SI, ADD will clear ZF

    put(cpu, CS, 0x0100, { 0x9F, -- LAHF: save CF/ZF
        0x83, 0xC6, 0x01,      -- ADD SI, 1: clobbers ZF
        0x9E })                -- SAHF: restore CF/ZF
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(6), 1, "ADD SI, 1 executed")
    eq(cpu:get_flag("ZF"), false, "ADD clobbered ZF as expected")
    cpu:step()
    eq(cpu:get_flag("CF"), true, "SAHF restored CF")
    eq(cpu:get_flag("ZF"), true, "SAHF restored ZF")
end)

test("LEA loads effective addresses, not memory", function()
    local cpu = new_cpu()

    -- LEA AX, [0x1234] (mod=0, rm=6): the offset only, DS is not applied.
    cpu.ip = 0x0100
    put(cpu, CS, 0x0100, { 0x8D, 0x06, 0x34, 0x12 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x1234, "LEA AX, [0x1234]")
    eq(cpu.ip, 0x0104, "IP after four bytes")

    -- LEA DX, [BX+SI+0x10] computes BX+SI+disp8.
    cpu:set_reg16(3, 0x0100) -- BX
    cpu:set_reg16(6, 0x0020) -- SI
    cpu.ip = 0x0200
    put(cpu, CS, 0x0200, { 0x8D, 0x50, 0x10 })
    cpu:step()
    eq(cpu:get_reg16(2), 0x0130, "LEA DX, [BX+SI+0x10]")

    -- LEA DI, [BP+disp8] uses the segment offset, not the SS:BP address.
    cpu:set_reg16(5, 0xFF00) -- BP
    cpu.ip = 0x0300
    put(cpu, CS, 0x0300, { 0x8D, 0x7E, 0x40 })
    cpu:step()
    eq(cpu:get_reg16(7), 0xFF40, "LEA DI, [BP+0x40]")

    -- A high segment must not leak into the offset: DS=0xFFFF with a direct
    -- displacement still loads the plain 16-bit offset.
    cpu.seg.ds = 0xFFFF
    cpu.ip = 0x0400
    put(cpu, CS, 0x0400, { 0x8D, 0x1E, 0x00, 0x10 })
    cpu:step()
    eq(cpu:get_reg16(3), 0x1000, "DS does not leak into LEA")

    -- mod=3 is not a valid LEA encoding; the 80186+ executes it as MOV.
    cpu:set_reg16(3, 0x2468)
    cpu.ip = 0x0500
    put(cpu, CS, 0x0500, { 0x8D, 0xC3 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x2468, "LEA with mod=3 behaves as MOV")
end)

test("BCD and ASCII adjust instructions", function()
    local cpu = new_cpu()

    -- AAM (D4 0A): 0x2F -> AH=4, AL=7.
    cpu:set_reg16(0, 0x002F)
    cpu.ip = 0x0100
    put(cpu, CS, 0x0100, { 0xD4, 0x0A })
    cpu:step()
    eq(cpu:get_reg16(0), 0x0407, "AAM 0x2F")

    -- AAD (D5 0A): 0x0407 -> 0x002F, AH cleared.
    cpu.ip = 0x0102
    put(cpu, CS, 0x0102, { 0xD5, 0x0A })
    cpu:step()
    eq(cpu:get_reg16(0), 0x002F, "AAD 0x0407")
    eq(cpu:get_reg8(4), 0, "AAD clears AH")

    -- DAA: AL=0x0A -> 0x10, no carry.
    cpu:set_reg16(0, 0x000A)
    cpu:set_flag("AF", false)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0104
    put(cpu, CS, 0x0104, { 0x27 })
    cpu:step()
    eq(cpu:get_reg8(0), 0x10, "DAA 0x0A")
    eq(cpu:get_flag("CF"), false, "DAA CF")

    -- DAA with a decimal carry: AL=0x9A -> 0x00, CF=1.
    cpu:set_reg16(0, 0x009A)
    cpu:set_flag("AF", false)
    cpu:set_flag("CF", false)
    cpu.ip = 0x0105
    put(cpu, CS, 0x0105, { 0x27 })
    cpu:step()
    eq(cpu:get_reg8(0), 0x00, "DAA 0x9A")
    eq(cpu:get_flag("CF"), true, "DAA carry")

    -- AAA: AL=0x0A -> AL=0, AH + 1, CF=AF=1.
    cpu:set_reg16(0, 0x020A)
    cpu:set_flag("AF", false)
    cpu.ip = 0x0106
    put(cpu, CS, 0x0106, { 0x37 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x0300, "AAA 0x0A")
    eq(cpu:get_flag("CF"), true, "AAA CF")

    -- AAS: AL=0x0A -> AL=4, AH - 1, CF=AF=1.
    cpu:set_reg16(0, 0x030A)
    cpu:set_flag("AF", false)
    cpu.ip = 0x0108
    put(cpu, CS, 0x0108, { 0x3F })
    cpu:step()
    eq(cpu:get_reg16(0), 0x0204, "AAS 0x0A")
    eq(cpu:get_flag("CF"), true, "AAS CF")

    -- DAS: AL=0x0A -> 0x04, no carry.
    cpu:set_reg16(0, 0x000A)
    cpu:set_flag("AF", false)
    cpu:set_flag("CF", false)
    cpu.ip = 0x010A
    put(cpu, CS, 0x010A, { 0x2F })
    cpu:step()
    eq(cpu:get_reg8(0), 0x04, "DAS 0x0A")
    eq(cpu:get_flag("CF"), false, "DAS CF")

    -- AAM with a zero base is a divide error.
    cpu.ip = 0x010C
    put(cpu, CS, 0x010C, { 0xD4, 0x00 })
    expect_error(function() cpu:step() end, "divide error")

    -- AAD with a zero base is legal: AL = (0 * AH + AL) = AL, AH = 0 and
    -- no division is performed.
    cpu:set_reg16(0, 0x1234)
    cpu.ip = 0x010E
    put(cpu, CS, 0x010E, { 0xD5, 0x00 })
    cpu:step()
    eq(cpu:get_reg16(0), 0x0034, "AAD base 0 leaves AL")
end)

test("MOV immediates, moffs and segment registers", function()
    local cpu = new_cpu()

    put(cpu, CS, 0x0100, { 0xB8, 0x34, 0x12 }) -- MOV AX, 0x1234
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_reg16(0), 0x1234, "MOV AX, imm16")
    eq(cpu.ip, 0x0103, "IP after MOV imm16")

    put(cpu, CS, 0x0103, { 0xB5, 0x77 }) -- MOV CH, 0x77
    cpu:step()
    eq(cpu:get_reg8(5), 0x77, "MOV CH, imm8")

    -- MOV moffs16, AX (A3) then MOV AL, moffs8 (A0), both DS relative.
    cpu:set_reg16(0, 0xBEEF)
    cpu.ip = 0x0105
    put(cpu, CS, 0x0105, { 0xA3, 0x00, 0x20 })
    cpu:step()
    eq(cpu:read16(DS, 0x2000), 0xBEEF, "MOV [0x2000], AX")

    cpu:write8(DS, 0x2001, 0x5A)
    cpu.ip = 0x0108
    put(cpu, CS, 0x0108, { 0xA0, 0x01, 0x20 })
    cpu:step()
    eq(cpu:get_reg8(0), 0x5A, "MOV AL, [0x2001]")

    -- MOV r/m16, Sreg (8C) and MOV Sreg, r/m16 (8E).
    cpu:set_reg16(0, 0x0000)
    cpu.ip = 0x010B
    put(cpu, CS, 0x010B, { 0x8C, 0xC8 }) -- MOV AX, CS
    cpu:step()
    eq(cpu:get_reg16(0), CS, "MOV AX, CS")

    cpu:set_reg16(0, 0x2345)
    cpu.ip = 0x010D
    put(cpu, CS, 0x010D, { 0x8E, 0xD8 }) -- MOV DS, AX
    cpu:step()
    eq(cpu:get_sreg("ds"), 0x2345, "MOV DS, AX")

    -- MOV r/m8, imm8 with a register destination (C6 C3 5A = MOV BL, 0x5A).
    cpu.ip = 0x0110
    put(cpu, CS, 0x0110, { 0xC6, 0xC3, 0x5A })
    cpu:step()
    eq(cpu:get_reg8(3), 0x5A, "MOV BL, imm8")

    -- MOV r/m16, imm16 with a register destination.
    cpu.ip = 0x0113
    put(cpu, CS, 0x0113, { 0xC7, 0xC2, 0x78, 0x56 })
    cpu:step()
    eq(cpu:get_reg16(2), 0x5678, "MOV DX, imm16")
end)

test("ADD and ADC set carry, overflow, auxiliary and parity flags", function()
    local cpu = new_cpu()

    -- MOV AL, 0x7F ; ADD AL, 1 -> 0x80 with OF, SF, AF set.
    put(cpu, CS, 0x0100, { 0xB0, 0x7F, 0x04, 0x01 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x80, "ADD result")
    eq(cpu:get_flag("OF"), true, "OF on signed overflow")
    eq(cpu:get_flag("SF"), true, "SF")
    eq(cpu:get_flag("ZF"), false, "ZF")
    eq(cpu:get_flag("AF"), true, "AF carry out of bit 3")
    eq(cpu:get_flag("CF"), false, "CF not set")
    eq(cpu:get_flag("PF"), false, "PF odd parity for 0x80")

    -- ADC includes the carry input: 0xFF + 0 + CF(1) = 0x00 with CF set.
    put(cpu, CS, 0x0104, { 0xB0, 0xFF, 0xF9, 0x14, 0x00 })
    cpu.ip = 0x0104
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x00, "ADC result")
    eq(cpu:get_flag("CF"), true, "ADC carry out")
    eq(cpu:get_flag("ZF"), true, "ADC ZF")
    eq(cpu:get_flag("PF"), true, "ADC PF even parity")

    -- 16-bit ADD overflow: 0x8000 + 0x8000 = 0x0000, CF and OF set.
    put(cpu, CS, 0x0110, { 0xB8, 0x00, 0x80, 0x05, 0x00, 0x80 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0000, "16-bit ADD result")
    eq(cpu:get_flag("CF"), true, "16-bit CF")
    eq(cpu:get_flag("OF"), true, "16-bit OF")
    eq(cpu:get_flag("ZF"), true, "16-bit ZF")
end)

test("SUB and SBB set borrow, sign and auxiliary flags", function()
    local cpu = new_cpu()

    -- MOV AL, 0x10 ; SUB AL, 1 -> 0x0F with AF set.
    put(cpu, CS, 0x0100, { 0xB0, 0x10, 0x2C, 0x01 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x0F, "SUB result")
    eq(cpu:get_flag("CF"), false, "no borrow")
    eq(cpu:get_flag("AF"), true, "AF borrow from bit 4")
    eq(cpu:get_flag("PF"), true, "PF even parity for 0x0F")
    eq(cpu:get_flag("SF"), false, "SF")
    eq(cpu:get_flag("ZF"), false, "ZF")

    -- MOV AL, 0x00 ; STC ; SBB AL, 0 -> 0xFF with CF and SF set.
    put(cpu, CS, 0x0104, { 0xB0, 0x00, 0xF9, 0x1C, 0x00 })
    cpu.ip = 0x0104
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xFF, "SBB result")
    eq(cpu:get_flag("CF"), true, "SBB borrow")
    eq(cpu:get_flag("SF"), true, "SBB SF")
    eq(cpu:get_flag("OF"), false, "SBB no overflow")

    -- 16-bit SUB below zero: 0x0000 - 0x0001 = 0xFFFF, CF set.
    put(cpu, CS, 0x0110, { 0xB8, 0x00, 0x00, 0x2D, 0x01, 0x00 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0xFFFF, "16-bit SUB result")
    eq(cpu:get_flag("CF"), true, "16-bit borrow")
end)

test("AND OR XOR clear CF and OF and set ZF/SF/PF", function()
    local cpu = new_cpu()

    -- STC ; MOV AL, 0xF0 ; AND AL, 0x0F -> 0x00
    put(cpu, CS, 0x0100, { 0xF9, 0xB0, 0xF0, 0x24, 0x0F })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x00, "AND result")
    eq(cpu:get_flag("ZF"), true, "AND ZF")
    eq(cpu:get_flag("PF"), true, "AND PF")
    eq(cpu:get_flag("SF"), false, "AND SF")
    eq(cpu:get_flag("CF"), false, "AND clears CF")
    eq(cpu:get_flag("OF"), false, "AND clears OF")

    -- MOV AL, 0x0F ; OR AL, 0xF0 -> 0xFF
    put(cpu, CS, 0x0110, { 0xB0, 0x0F, 0x0C, 0xF0 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xFF, "OR result")
    eq(cpu:get_flag("SF"), true, "OR SF")
    eq(cpu:get_flag("ZF"), false, "OR ZF")
    eq(cpu:get_flag("PF"), true, "OR PF even parity")

    -- MOV AL, 0xFF ; XOR AL, 0xFF -> 0x00
    put(cpu, CS, 0x0120, { 0xB0, 0xFF, 0x34, 0xFF })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x00, "XOR result")
    eq(cpu:get_flag("ZF"), true, "XOR ZF")

    -- 16-bit AND: 0xF0F0 AND 0x0F0F = 0x0000.
    put(cpu, CS, 0x0130, { 0xB8, 0xF0, 0xF0, 0x25, 0x0F, 0x0F })
    cpu.ip = 0x0130
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0000, "16-bit AND result")
    eq(cpu:get_flag("ZF"), true, "16-bit AND ZF")
end)

test("CMP sets flags but never writes the destination", function()
    local cpu = new_cpu()

    put(cpu, CS, 0x0100, { 0xB0, 0x05, 0x3C, 0x03 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x05, "AL unchanged by CMP")
    eq(cpu:get_flag("ZF"), false, "CMP ZF")
    eq(cpu:get_flag("CF"), false, "CMP CF")
    eq(cpu:get_flag("SF"), false, "CMP SF")
    eq(cpu:get_flag("AF"), false, "CMP AF")
    eq(cpu:get_flag("PF"), false, "CMP PF odd parity for 2")

    -- 16-bit equal comparison sets ZF and leaves AX alone.
    put(cpu, CS, 0x0110, { 0xB8, 0x03, 0x00, 0x3D, 0x03, 0x00 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0003, "AX unchanged by CMP")
    eq(cpu:get_flag("ZF"), true, "16-bit CMP ZF")
end)

test("INC and DEC preserve the carry flag", function()
    local cpu = new_cpu()

    -- STC ; MOV AL, 0x7F ; INC AL -> 0x80, CF untouched.
    put(cpu, CS, 0x0100, { 0xF9, 0xB0, 0x7F, 0xFE, 0xC0 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x80, "INC result")
    eq(cpu:get_flag("CF"), true, "INC keeps CF")
    eq(cpu:get_flag("OF"), true, "INC OF at the signed boundary")
    eq(cpu:get_flag("SF"), true, "INC SF")
    eq(cpu:get_flag("AF"), true, "INC AF")

    -- STC ; MOV AL, 0x80 ; DEC AL -> 0x7F, CF untouched.
    put(cpu, CS, 0x0108, { 0xF9, 0xB0, 0x80, 0xFE, 0xC8 })
    cpu.ip = 0x0108
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x7F, "DEC result")
    eq(cpu:get_flag("CF"), true, "DEC keeps CF")
    eq(cpu:get_flag("OF"), true, "DEC OF at the signed boundary")
    eq(cpu:get_flag("AF"), true, "DEC AF")

    -- 16-bit INC 0xFFFF wraps to 0x0000 and leaves CF set.
    put(cpu, CS, 0x0110, { 0xF9, 0xB8, 0xFF, 0xFF, 0x40 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0000, "INC 16-bit wrap")
    eq(cpu:get_flag("CF"), true, "16-bit INC keeps CF")
    eq(cpu:get_flag("ZF"), true, "16-bit INC ZF")
end)

test("XCHG swaps register and memory operands", function()
    local cpu = new_cpu()

    put(cpu, CS, 0x0100, {
        0xB8, 0x34, 0x12, -- MOV AX, 0x1234
        0xBB, 0x78, 0x56, -- MOV BX, 0x5678
        0x93,             -- XCHG AX, BX
    })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x5678, "AX after XCHG")
    eq(cpu:get_reg16(3), 0x1234, "BX after XCHG")

    put(cpu, CS, 0x0110, {
        0xB0, 0x11,       -- MOV AL, 0x11
        0xB3, 0x22,       -- MOV BL, 0x22
        0x86, 0xD8,       -- XCHG AL, BL
    })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x22, "AL after 8-bit XCHG")
    eq(cpu:get_reg8(3), 0x11, "BL after 8-bit XCHG")
end)

test("TEST, NOT and NEG", function()
    local cpu = new_cpu()

    -- STC ; MOV AL, 0x0F ; TEST AL, 1 -> result 1, CF cleared.
    put(cpu, CS, 0x0100, { 0xF9, 0xB0, 0x0F, 0xA8, 0x01 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_flag("ZF"), false, "TEST ZF")
    eq(cpu:get_flag("CF"), false, "TEST clears CF")
    eq(cpu:get_flag("PF"), false, "TEST PF odd")

    -- MOV AL, 0xF0 ; TEST AL, 0x0F -> zero.
    put(cpu, CS, 0x0110, { 0xB0, 0xF0, 0xA8, 0x0F })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_flag("ZF"), true, "TEST zero result")

    -- STC ; MOV AL, 0x0F ; NOT AL -> 0xF0, flags unchanged.
    put(cpu, CS, 0x0120, { 0xF9, 0xB0, 0x0F, 0xF6, 0xD0 })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xF0, "NOT result")
    eq(cpu:get_flag("CF"), true, "NOT leaves flags alone")

    -- MOV AL, 1 ; NEG AL -> 0xFF with CF, SF and AF set.
    put(cpu, CS, 0x0130, { 0xB0, 0x01, 0xF6, 0xD8 })
    cpu.ip = 0x0130
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xFF, "NEG result")
    eq(cpu:get_flag("CF"), true, "NEG CF")
    eq(cpu:get_flag("SF"), true, "NEG SF")
    eq(cpu:get_flag("AF"), true, "NEG AF")
    eq(cpu:get_flag("OF"), false, "NEG OF")

    -- NEG of the most negative byte overflows.
    put(cpu, CS, 0x0140, { 0xB0, 0x80, 0xF6, 0xD8 })
    cpu.ip = 0x0140
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x80, "NEG 0x80 result")
    eq(cpu:get_flag("OF"), true, "NEG 0x80 OF")
    eq(cpu:get_flag("CF"), true, "NEG 0x80 CF")
end)

test("shift and rotate operations", function()
    local cpu = new_cpu()

    -- SHL AL, 1: 0x81 -> 0x02, CF = 1, OF = 1.
    put(cpu, CS, 0x0100, { 0xB0, 0x81, 0xD0, 0xE0 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x02, "SHL result")
    eq(cpu:get_flag("CF"), true, "SHL CF")
    eq(cpu:get_flag("OF"), true, "SHL OF")
    eq(cpu:get_flag("PF"), false, "SHL PF odd parity")

    -- SHR AL, 1: 0x81 -> 0x40, CF = 1.
    put(cpu, CS, 0x0108, { 0xB0, 0x81, 0xD0, 0xE8 })
    cpu.ip = 0x0108
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x40, "SHR result")
    eq(cpu:get_flag("CF"), true, "SHR CF")
    eq(cpu:get_flag("OF"), true, "SHR OF is the old MSB")

    -- SAR AL, 1: 0x81 -> 0xC0, CF = 1.
    put(cpu, CS, 0x0110, { 0xB0, 0x81, 0xD0, 0xF8 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xC0, "SAR result")
    eq(cpu:get_flag("CF"), true, "SAR CF")
    eq(cpu:get_flag("SF"), true, "SAR SF")
    eq(cpu:get_flag("PF"), true, "SAR PF even parity")

    -- ROL AL, 1: 0x81 -> 0x03, CF = 1, OF = 1.
    put(cpu, CS, 0x0118, { 0xB0, 0x81, 0xD0, 0xC0 })
    cpu.ip = 0x0118
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x03, "ROL result")
    eq(cpu:get_flag("CF"), true, "ROL CF")
    eq(cpu:get_flag("OF"), true, "ROL OF")

    -- ROR AL, 1: 0x81 -> 0xC0, CF = 1, OF = 0 (top two bits are equal).
    put(cpu, CS, 0x0120, { 0xB0, 0x81, 0xD0, 0xC8 })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xC0, "ROR result")
    eq(cpu:get_flag("CF"), true, "ROR CF")
    eq(cpu:get_flag("OF"), false, "ROR OF")

    -- RCL AL, 1: 0x80 through a clear carry -> 0x00, CF = 1.
    put(cpu, CS, 0x0128, { 0xF8, 0xB0, 0x80, 0xD0, 0xD0 })
    cpu.ip = 0x0128
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x00, "RCL result")
    eq(cpu:get_flag("CF"), true, "RCL CF")

    -- RCR AL, 1: 0x01 through a set carry -> 0x80, CF = 1.
    put(cpu, CS, 0x0130, { 0xF9, 0xB0, 0x01, 0xD0, 0xD8 })
    cpu.ip = 0x0130
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x80, "RCR result")
    eq(cpu:get_flag("CF"), true, "RCR CF")
end)

test("shift by zero leaves flags untouched, shifts by CL work", function()
    local cpu = new_cpu()

    -- STC ; MOV AL, 1 ; SHL AL, 0 -> CF must still be set.
    put(cpu, CS, 0x0100, { 0xF9, 0xB0, 0x01, 0xC0, 0xE0, 0x00 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0x01, "count zero keeps the value")
    eq(cpu:get_flag("CF"), true, "count zero keeps CF")

    -- MOV CL, 2 ; MOV AX, 3 ; SHL AX, CL -> 0x000C.
    put(cpu, CS, 0x0110, { 0xB1, 0x02, 0xB8, 0x03, 0x00, 0xD3, 0xE0 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x000C, "SHL AX, CL")
    eq(cpu:get_flag("CF"), false, "SHL AX, CL CF")

    -- 16-bit shift: 0x8000 SHL 1 = 0 with CF, OF and ZF set.
    put(cpu, CS, 0x0120, { 0xB8, 0x00, 0x80, 0xD1, 0xE0 })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0000, "16-bit SHL result")
    eq(cpu:get_flag("CF"), true, "16-bit SHL CF")
    eq(cpu:get_flag("OF"), true, "16-bit SHL OF")
    eq(cpu:get_flag("ZF"), true, "16-bit SHL ZF")
end)

test("MUL and IMUL", function()
    local cpu = new_cpu()

    -- 16-bit MUL: 0x1234 * 0x0010 = 0x12340 -> AX = 0x2340, DX = 0x0001.
    put(cpu, CS, 0x0100, {
        0xB8, 0x34, 0x12, -- MOV AX, 0x1234
        0xBB, 0x10, 0x00, -- MOV BX, 0x0010
        0xF7, 0xE3,       -- MUL BX
    })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x2340, "MUL AX")
    eq(cpu:get_reg16(2), 0x0001, "MUL DX")
    eq(cpu:get_flag("CF"), true, "MUL CF")
    eq(cpu:get_flag("OF"), true, "MUL OF")

    -- 8-bit MUL: 0x10 * 0x11 = 0x0110 -> AX = 0x0110.
    put(cpu, CS, 0x0110, { 0xB0, 0x10, 0xB3, 0x11, 0xF6, 0xE3 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0110, "8-bit MUL AX")
    eq(cpu:get_flag("CF"), true, "8-bit MUL CF")

    -- 8-bit MUL that fits: 2 * 3 = 6 -> CF clear.
    put(cpu, CS, 0x0120, { 0xB0, 0x02, 0xB3, 0x03, 0xF6, 0xE3 })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0006, "small 8-bit MUL")
    eq(cpu:get_flag("OF"), false, "small MUL OF")

    -- 16-bit IMUL: -2 * 3 = -6 -> AX = 0xFFFA, DX = 0xFFFF, no overflow.
    put(cpu, CS, 0x0130, {
        0xB8, 0xFE, 0xFF, -- MOV AX, 0xFFFE (-2)
        0xBB, 0x03, 0x00, -- MOV BX, 3
        0xF7, 0xEB,       -- IMUL BX
    })
    cpu.ip = 0x0130
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0xFFFA, "IMUL AX")
    eq(cpu:get_reg16(2), 0xFFFF, "IMUL DX")
    eq(cpu:get_flag("CF"), false, "IMUL CF when the product fits")

    -- 8-bit IMUL overflow: 64 * 4 = 256 does not fit in a byte.
    put(cpu, CS, 0x0140, { 0xB0, 0x40, 0xB3, 0x04, 0xF6, 0xEB })
    cpu.ip = 0x0140
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0x0100, "8-bit IMUL product")
    eq(cpu:get_flag("CF"), true, "8-bit IMUL CF")
    eq(cpu:get_flag("OF"), true, "8-bit IMUL OF")
end)

test("DIV and IDIV", function()
    local cpu = new_cpu()

    -- 16-bit DIV: DX:AX = 10, divisor 3 -> AX = 3, DX = 1.
    put(cpu, CS, 0x0100, {
        0xB8, 0x0A, 0x00, -- MOV AX, 10
        0xBA, 0x00, 0x00, -- MOV DX, 0
        0xBB, 0x03, 0x00, -- MOV BX, 3
        0xF7, 0xF3,       -- DIV BX
    })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 3, "DIV quotient")
    eq(cpu:get_reg16(2), 1, "DIV remainder")

    -- 8-bit DIV: AX = 20, divisor 3 -> AL = 6, AH = 2.
    put(cpu, CS, 0x0110, { 0xB8, 0x14, 0x00, 0xB3, 0x03, 0xF6, 0xF3 })
    cpu.ip = 0x0110
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 6, "8-bit DIV quotient")
    eq(cpu:get_reg8(4), 2, "8-bit DIV remainder")

    -- 16-bit IDIV: DX:AX = -7, divisor 2 -> AX = -3, DX = -1.
    put(cpu, CS, 0x0120, {
        0xB8, 0xF9, 0xFF, -- MOV AX, 0xFFF9 (-7)
        0xBA, 0xFF, 0xFF, -- MOV DX, 0xFFFF
        0xBB, 0x02, 0x00, -- MOV BX, 2
        0xF7, 0xFB,       -- IDIV BX
    })
    cpu.ip = 0x0120
    cpu:step()
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0xFFFD, "IDIV quotient")
    eq(cpu:get_reg16(2), 0xFFFF, "IDIV remainder")

    -- 8-bit IDIV: AX = -7, divisor 2 -> AL = -3 (0xFD), AH = -1 (0xFF).
    put(cpu, CS, 0x0130, { 0xB8, 0xF9, 0xFF, 0xB3, 0x02, 0xF6, 0xFB })
    cpu.ip = 0x0130
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu:get_reg8(0), 0xFD, "8-bit IDIV quotient")
    eq(cpu:get_reg8(4), 0xFF, "8-bit IDIV remainder")
end)

test("divide by zero raises a divide error with CS:IP", function()
    local cpu = new_cpu()
    put(cpu, CS, 0x0100, {
        0xB8, 0x0A, 0x00, -- MOV AX, 10
        0xB3, 0x00,       -- MOV BL, 0
        0xF6, 0xF3,       -- DIV BL
    })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    local text = expect_error(function() cpu:step() end,
        "cpu: divide error", "CS:IP", "1000:0105")
    contains(text, "divide error", "message")
end)

test("JMP short, near and far", function()
    local cpu = new_cpu()

    cpu.ip = 0x0100
    put(cpu, CS, 0x0100, { 0xEB, 0x02 })
    cpu:step()
    eq(cpu.ip, 0x0104, "JMP rel8")

    cpu.ip = 0x0200
    put(cpu, CS, 0x0200, { 0xE9, 0x03, 0x00 })
    cpu:step()
    eq(cpu.ip, 0x0206, "JMP rel16")

    cpu.ip = 0x0300
    put(cpu, CS, 0x0300, { 0xEA, 0x00, 0x20, 0x00, 0x30 })
    cpu:step()
    eq(cpu:get_sreg("cs"), 0x3000, "far JMP CS")
    eq(cpu.ip, 0x2000, "far JMP IP")
end)

test("conditional jumps taken and not taken", function()
    local cpu = new_cpu()

    -- MOV AL, 1 ; CMP AL, 1 ; JE +2 -> taken to 0x0108.
    put(cpu, CS, 0x0100, { 0xB0, 0x01, 0x3C, 0x01, 0x74, 0x02, 0x90, 0x90 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu.ip, 0x0108, "JE taken")

    -- Same flags, JNE +2 -> not taken, falls through to 0x0106.
    put(cpu, CS, 0x0200, { 0xB0, 0x01, 0x3C, 0x01, 0x75, 0x02, 0x90, 0x90 })
    cpu.ip = 0x0200
    cpu:step()
    cpu:step()
    cpu:step()
    eq(cpu.ip, 0x0206, "JNE not taken")

    -- JB after a clear carry is not taken; JC after STC is taken.
    put(cpu, CS, 0x0300, { 0xF8, 0x72, 0x02 })
    cpu.ip = 0x0300
    cpu:step()
    cpu:step()
    eq(cpu.ip, 0x0303, "JB not taken")

    put(cpu, CS, 0x0400, { 0xF9, 0x72, 0x02 })
    cpu.ip = 0x0400
    cpu:step()
    cpu:step()
    eq(cpu.ip, 0x0405, "JC taken")
end)

test("LOOP and JCXZ", function()
    local cpu = new_cpu()

    -- MOV CX, 3 ; NOP ; LOOP -3 -> three iterations, then CX = 0.
    put(cpu, CS, 0x0100, { 0xB9, 0x03, 0x00, 0x90, 0xE2, 0xFD })
    cpu.ip = 0x0100
    cpu:step()
    for _ = 1, 3 do
        cpu:step() -- NOP
        cpu:step() -- LOOP
    end
    eq(cpu:get_reg16(1), 0, "CX after LOOP")
    eq(cpu.ip, 0x0106, "IP after LOOP")

    -- JCXZ with CX = 0 jumps.
    cpu:set_reg16(1, 0)
    cpu.ip = 0x0200
    put(cpu, CS, 0x0200, { 0xE3, 0x02 })
    cpu:step()
    eq(cpu.ip, 0x0204, "JCXZ taken")

    -- JCXZ with a non-zero CX falls through.
    cpu:set_reg16(1, 1)
    cpu.ip = 0x0210
    put(cpu, CS, 0x0210, { 0xE3, 0x02 })
    cpu:step()
    eq(cpu.ip, 0x0212, "JCXZ not taken")

    -- LOOPE with ZF set jumps while CX is still non-zero.
    cpu:set_reg16(1, 2)
    cpu:set_flag("ZF", true)
    cpu.ip = 0x0300
    put(cpu, CS, 0x0300, { 0xE1, 0x02 })
    cpu:step()
    eq(cpu.ip, 0x0304, "LOOPE taken")
    eq(cpu:get_reg16(1), 1, "LOOPE decrements CX")
end)

test("CALL and RET near, including RET imm16", function()
    local cpu = new_cpu()

    -- 0x0100: CALL +3 -> target 0x0106, return to 0x0103
    -- 0x0103: MOV AL, 1
    -- 0x0105: NOP
    -- 0x0106: MOV BL, 2
    -- 0x0108: RET
    put(cpu, CS, 0x0100, { 0xE8, 0x03, 0x00, 0xB0, 0x01, 0x90,
        0xB3, 0x02, 0xC3 })
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.ip, 0x0106, "CALL target")
    eq(cpu:get_reg16(4), SP - 2, "CALL pushes the return address")
    eq(cpu:read16(SS, SP - 2), 0x0103, "return address value")

    cpu:step()
    eq(cpu:get_reg8(3), 2, "callee body ran")
    cpu:step()
    eq(cpu.ip, 0x0103, "RET returns")
    eq(cpu:get_reg16(4), SP, "RET restores SP")
    cpu:step()
    eq(cpu:get_reg8(0), 1, "caller continues")

    -- RET imm16 additionally pops the immediate from the stack.
    put(cpu, CS, 0x0200, { 0xB8, 0x34, 0x12, 0x50, 0x50,
        0xC2, 0x02, 0x00 })
    cpu.ip = 0x0200
    cpu:set_reg16(4, SP)
    cpu:step() -- MOV AX, 0x1234
    cpu:step() -- PUSH AX
    cpu:step() -- PUSH AX
    eq(cpu:get_reg16(4), SP - 4, "two pushes")
    cpu:step() -- RET 2
    eq(cpu.ip, 0x1234, "RET imm16 target")
    eq(cpu:get_reg16(4), SP, "RET imm16 pops the address and the immediate")
end)

test("far CALL and RETF", function()
    local cpu = new_cpu()

    -- 0x0100: CALL 0x2000:0x0100 (5 bytes), returns to 0x0105.
    put(cpu, CS, 0x0100, { 0x9A, 0x00, 0x01, 0x00, 0x20 })
    -- The callee is RETF at 0x2000:0x0100.
    put(cpu, 0x2000, 0x0100, { 0xCB })

    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_sreg("cs"), 0x2000, "far CALL CS")
    eq(cpu.ip, 0x0100, "far CALL IP")
    eq(cpu:get_reg16(4), SP - 4, "far CALL pushes CS and IP")
    eq(cpu:read16(SS, SP - 2), CS, "far CALL pushes CS first")
    eq(cpu:read16(SS, SP - 4), 0x0105, "far CALL return IP on top")

    cpu:step()
    eq(cpu:get_sreg("cs"), CS, "RETF restores CS")
    eq(cpu.ip, 0x0105, "RETF restores IP")
    eq(cpu:get_reg16(4), SP, "RETF restores SP")
end)

test("PUSH, POP, PUSHF and POPF", function()
    local cpu = new_cpu()

    put(cpu, CS, 0x0100, {
        0xB8, 0xEF, 0xBE, -- MOV AX, 0xBEEF
        0x50,             -- PUSH AX
        0x5B,             -- POP BX
    })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(4), SP - 2, "PUSH decrements SP")
    cpu:step()
    eq(cpu:get_reg16(3), 0xBEEF, "POP value")
    eq(cpu:get_reg16(4), SP, "POP restores SP")

    -- PUSH imm16 and PUSH imm8 (sign extended).
    put(cpu, CS, 0x0110, { 0x68, 0x34, 0x12, 0x6A, 0xF0 })
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:read16(SS, SP - 2), 0x1234, "PUSH imm16")
    cpu:step()
    eq(cpu:read16(SS, SP - 4), 0xFFF0, "PUSH imm8 is sign extended")

    -- PUSHF pushes the packed flags, bit 1 always set.
    cpu:set_reg16(4, SP)
    cpu:set_flag("CF", true)
    cpu:set_flag("IF", true)
    cpu:set_flag("ZF", true)
    put(cpu, CS, 0x0120, { 0x9C })
    cpu.ip = 0x0120
    cpu:step()
    local packed = cpu:read16(SS, SP - 2)
    eq(packed % 2, 1, "PUSHF CF bit")
    eq(floor(packed / 2) % 2, 1, "PUSHF bit 1 is always one")
    eq(floor(packed / 64) % 2, 1, "PUSHF ZF bit")
    eq(floor(packed / 512) % 2, 1, "PUSHF IF bit")

    -- POPF loads flags from the stack.
    cpu:set_reg16(4, SP)
    put(cpu, CS, 0x0130, { 0xB8, 0x01, 0x00, 0x50, 0x9D })
    cpu.ip = 0x0130
    cpu:step() -- MOV AX, 1
    cpu:step() -- PUSH AX
    cpu:step() -- POPF
    eq(cpu:get_flag("CF"), true, "POPF sets CF")
    eq(cpu:get_flag("ZF"), false, "POPF clears ZF")
    eq(cpu:get_flag("IF"), false, "POPF clears IF")

    -- Segment register push/pop: PUSH ES / POP DS.
    cpu.ip = 0x0140
    cpu:set_reg16(4, SP)
    put(cpu, CS, 0x0140, { 0x06, 0x1F })
    cpu:step()
    cpu:step()
    eq(cpu:get_sreg("ds"), ES, "POP DS after PUSH ES")
    eq(cpu:get_reg16(4), SP, "segment push/pop is balanced")
end)

test("PUSHA and POPA", function()
    local cpu = new_cpu()
    cpu:set_reg16(0, 0x1111)
    cpu:set_reg16(1, 0x2222)
    cpu:set_reg16(2, 0x3333)
    cpu:set_reg16(3, 0x4444)
    cpu:set_reg16(5, 0x5555)
    cpu:set_reg16(6, 0x6666)
    cpu:set_reg16(7, 0x7777)

    put(cpu, CS, 0x0100, { 0x60 })
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_reg16(4), SP - 16, "PUSHA pushes eight words")
    eq(cpu:read16(SS, SP - 16), 0x7777, "DI at the lowest address")
    eq(cpu:read16(SS, SP - 14), 0x6666, "SI")
    eq(cpu:read16(SS, SP - 12), 0x5555, "BP")
    eq(cpu:read16(SS, SP - 10), SP, "saved SP")
    eq(cpu:read16(SS, SP - 8), 0x4444, "BX")
    eq(cpu:read16(SS, SP - 6), 0x3333, "DX")
    eq(cpu:read16(SS, SP - 4), 0x2222, "CX")
    eq(cpu:read16(SS, SP - 2), 0x1111, "AX")

    -- Clear the general registers but keep SP, which POPA needs.
    for i = 0, 7 do
        if i ~= 4 then
            cpu:set_reg16(i, 0)
        end
    end
    put(cpu, CS, 0x0110, { 0x61 })
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:get_reg16(0), 0x1111, "POPA AX")
    eq(cpu:get_reg16(1), 0x2222, "POPA CX")
    eq(cpu:get_reg16(2), 0x3333, "POPA DX")
    eq(cpu:get_reg16(3), 0x4444, "POPA BX")
    eq(cpu:get_reg16(5), 0x5555, "POPA BP")
    eq(cpu:get_reg16(6), 0x6666, "POPA SI")
    eq(cpu:get_reg16(7), 0x7777, "POPA DI")
    eq(cpu:get_reg16(4), SP, "POPA leaves SP alone")
end)

test("LES and LDS load far pointers", function()
    local cpu = new_cpu()

    -- DS:[0x2000] = { offset = 0x5678, segment = 0x5000 }
    cpu:write16(DS, 0x2000, 0x5678)
    cpu:write16(DS, 0x2002, 0x5000)
    -- DS:[0x2010] = { offset = 0x1234, segment = 0x6000 }
    cpu:write16(DS, 0x2010, 0x1234)
    cpu:write16(DS, 0x2012, 0x6000)

    put(cpu, CS, 0x0100, { 0xC4, 0x1E, 0x00, 0x20 }) -- LES BX, [0x2000]
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_reg16(3), 0x5678, "LES offset")
    eq(cpu:get_sreg("es"), 0x5000, "LES segment into ES")

    put(cpu, CS, 0x0110, { 0xC5, 0x1E, 0x10, 0x20 }) -- LDS BX, [0x2010]
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:get_reg16(3), 0x1234, "LDS offset")
    eq(cpu:get_sreg("ds"), 0x6000, "LDS segment into DS")
end)

test("REP MOVSB forwards and rewinds IP between iterations", function()
    local cpu = new_cpu()
    cpu.seg.ds = DS
    cpu.seg.es = ES
    cpu:set_reg16(6, 0x0100)
    cpu:set_reg16(7, 0x0200)
    cpu:set_reg16(1, 5)
    put(cpu, DS, 0x0100, { 0x11, 0x22, 0x33, 0x44, 0x55 })
    put(cpu, CS, 0x0100, { 0xF3, 0xA4 }) -- REP MOVSB
    cpu.ip = 0x0100

    cpu:step()
    eq(cpu:get_reg16(1), 4, "CX decremented")
    eq(cpu.ip, 0x0100, "IP rewound while the repetition continues")
    eq(cpu:get_reg16(6), 0x0101, "SI advanced")
    eq(cpu:get_reg16(7), 0x0201, "DI advanced")

    steps(cpu, 4)
    eq(cpu:get_reg16(1), 0, "CX exhausted")
    eq(cpu.ip, 0x0102, "IP advanced after the last iteration")
    eq(cpu:read8(ES, 0x0200), 0x11, "byte 1")
    eq(cpu:read8(ES, 0x0201), 0x22, "byte 2")
    eq(cpu:read8(ES, 0x0202), 0x33, "byte 3")
    eq(cpu:read8(ES, 0x0203), 0x44, "byte 4")
    eq(cpu:read8(ES, 0x0204), 0x55, "byte 5")

    -- REP with CX = 0 executes no iteration.
    cpu:set_reg16(1, 0)
    cpu:set_reg16(6, 0x0100)
    cpu:set_reg16(7, 0x0300)
    put(cpu, CS, 0x0200, { 0xF3, 0xA4 })
    cpu.ip = 0x0200
    cpu:step()
    eq(cpu.ip, 0x0202, "REP with CX = 0 falls through")
    eq(cpu:get_reg16(7), 0x0300, "DI untouched with CX = 0")
end)

test("REP STOSW honours the direction flag", function()
    local cpu = new_cpu()
    cpu.seg.es = ES
    cpu:set_reg16(1, 3)
    cpu:set_reg16(7, 0x0300)
    cpu:set_reg16(0, 0xABCD)
    -- STD then REP STOSW
    put(cpu, CS, 0x0100, { 0xFD, 0xF3, 0xAB })
    cpu.ip = 0x0100

    cpu:step()
    eq(cpu:get_flag("DF"), true, "STD sets DF")
    eq(cpu.ip, 0x0101, "IP after STD")

    steps(cpu, 3)
    eq(cpu:get_reg16(1), 0, "CX exhausted")
    eq(cpu:get_reg16(7), 0x02FA, "DI walks backwards")
    eq(cpu.ip, 0x0103, "IP after the repeated STOSW")
    eq(cpu:read16(ES, 0x0300), 0xABCD, "word at 0x0300")
    eq(cpu:read16(ES, 0x02FE), 0xABCD, "word at 0x02FE")
    eq(cpu:read16(ES, 0x02FC), 0xABCD, "word at 0x02FC")

    -- With DF clear, REP STOSW walks forwards.
    cpu:set_reg16(1, 2)
    cpu:set_reg16(7, 0x0400)
    put(cpu, CS, 0x0200, { 0xFC, 0xF3, 0xAB })
    cpu.ip = 0x0200
    cpu:step() -- CLD
    steps(cpu, 2)
    eq(cpu:get_flag("DF"), false, "CLD clears DF")
    eq(cpu:get_reg16(7), 0x0404, "DI walks forwards with DF clear")
    eq(cpu:read16(ES, 0x0400), 0xABCD, "word at 0x0400")
end)

test("REPE CMPSB stops at the first mismatch, REPNE at the first match", function()
    local cpu = new_cpu()
    cpu.seg.ds = DS
    cpu.seg.es = ES

    -- "ABC.." vs "ABX..": REPE stops after comparing the third byte.
    cpu:set_reg16(6, 0x0100)
    cpu:set_reg16(7, 0x0200)
    cpu:set_reg16(1, 5)
    put(cpu, DS, 0x0100, { 0x41, 0x42, 0x43, 0x44, 0x45 })
    put(cpu, ES, 0x0200, { 0x41, 0x42, 0x58, 0x44, 0x45 })
    put(cpu, CS, 0x0100, { 0xF3, 0xA6 }) -- REPE CMPSB
    cpu.ip = 0x0100
    steps(cpu, 3)
    eq(cpu:get_reg16(1), 2, "REPE CX after the mismatch")
    eq(cpu:get_flag("ZF"), false, "REPE ZF after the mismatch")
    eq(cpu:get_reg16(6), 0x0103, "REPE SI")
    eq(cpu:get_reg16(7), 0x0203, "REPE DI")
    eq(cpu.ip, 0x0102, "REPE IP after the mismatch")

    -- First two bytes differ, third matches: REPNE stops at the match.
    cpu:set_reg16(6, 0x0300)
    cpu:set_reg16(7, 0x0400)
    cpu:set_reg16(1, 5)
    put(cpu, DS, 0x0300, { 0x41, 0x42, 0x43, 0x44, 0x45 })
    put(cpu, ES, 0x0400, { 0x58, 0x59, 0x43, 0x44, 0x45 })
    put(cpu, CS, 0x0200, { 0xF2, 0xA6 }) -- REPNE CMPSB
    cpu.ip = 0x0200
    steps(cpu, 3)
    eq(cpu:get_reg16(1), 2, "REPNE CX at the first match")
    eq(cpu:get_flag("ZF"), true, "REPNE ZF at the first match")
    eq(cpu.ip, 0x0202, "REPNE IP after the match")
end)

test("INT with a registered Lua handler is followed by an implicit IRET", function()
    local cpu = new_cpu()
    cpu:set_flag("IF", true)
    cpu:set_flag("CF", true)
    local calls = 0

    cpu.interrupts[0x60] = function(inner)
        calls = calls + 1
        eq(calls, 1, "handler call count")
        eq(inner:get_flag("IF"), false, "IF cleared inside the handler")
        eq(inner:get_flag("TF"), false, "TF cleared inside the handler")
        eq(inner:get_reg16(4), SP - 6, "three words pushed")
        -- Push order: FLAGS, CS, return IP (IP ends up on top).
        eq(inner:read16(SS, SP - 2) % 4, 3, "FLAGS on the bottom")
        eq(inner:read16(SS, SP - 4), CS, "CS pushed")
        eq(inner:read16(SS, SP - 6), 0x0102, "return IP on top")
        inner:set_reg8(4, 0x42) -- AH = 0x42
        inner:set_reg16(3, 0x9999) -- BX
    end

    put(cpu, CS, 0x0100, { 0xCD, 0x60 }) -- INT 0x60
    cpu.ip = 0x0100
    cpu:step()
    eq(calls, 1, "handler ran once")
    eq(cpu.ip, 0x0102, "return IP after the implicit IRET")
    eq(cpu:get_sreg("cs"), CS, "CS restored")
    eq(cpu:get_reg16(4), SP, "stack balanced after the implicit IRET")
    eq(cpu:get_reg8(4), 0x42, "handler register change survives")
    eq(cpu:get_reg16(3), 0x9999, "handler register change survives (BX)")
    eq(cpu:get_flag("IF"), true, "IF restored from the pushed FLAGS")
    eq(cpu:get_flag("CF"), true, "CF restored from the pushed FLAGS")
end)

test("flags set by a registered interrupt handler survive the implicit IRET", function()
    local cpu = new_cpu()
    cpu:set_flag("IF", true)
    cpu:set_flag("DF", true)
    cpu:set_flag("CF", false)
    cpu:set_flag("ZF", false)

    local calls = 0
    cpu.interrupts[0x61] = function(inner)
        calls = calls + 1
        inner:set_flag("CF", true)
        inner:set_flag("ZF", true)
        -- IF and DF are deliberately left alone: they must come back from
        -- the FLAGS image pushed by INT.
    end

    put(cpu, CS, 0x0100, { 0xCD, 0x61 }) -- INT 0x61
    cpu.ip = 0x0100
    cpu:step()

    eq(calls, 1, "handler ran once")
    eq(cpu.ip, 0x0102, "IP after the implicit IRET")
    eq(cpu:get_sreg("cs"), CS, "CS restored")
    eq(cpu:get_reg16(4), SP, "stack balanced")
    eq(cpu:get_flag("CF"), true, "CF set by the handler survives")
    eq(cpu:get_flag("ZF"), true, "ZF set by the handler survives")
    eq(cpu:get_flag("IF"), true, "untouched IF restored from the stack")
    eq(cpu:get_flag("DF"), true, "untouched DF restored from the stack")

    -- A second interrupt whose handler touches no flags must bring CF and ZF
    -- back from the pushed image, not keep the previous handler's result.
    cpu:set_flag("CF", false)
    cpu:set_flag("ZF", false)
    cpu.interrupts[0x62] = function(inner)
        calls = calls + 1
        eq(inner:get_flag("CF"), false, "handler sees the live CF")
        inner:set_reg16(0, inner:get_reg16(0))
    end
    put(cpu, CS, 0x0200, { 0xCD, 0x62 }) -- INT 0x62
    cpu.ip = 0x0200
    cpu:step()
    eq(calls, 2, "second handler ran")
    eq(cpu:get_flag("CF"), false, "CF restored from the stack")
    eq(cpu:get_flag("ZF"), false, "ZF restored from the stack")
    eq(cpu.ip, 0x0202, "IP after the second implicit IRET")
    eq(cpu:get_reg16(4), SP, "stack balanced after the second INT")
end)

test("INT without a handler dispatches through the IVT, IRET returns", function()
    local cpu = new_cpu()
    cpu:set_flag("IF", true)

    -- Vector 0x21 is at physical 0x21 * 4 = 0x84.
    cpu:write16(0, 0x0084, 0x0100)
    cpu:write16(0, 0x0086, 0x3000)
    put(cpu, 0x3000, 0x0100, { 0xCF }) -- IRET

    put(cpu, CS, 0x0100, { 0xCD, 0x21 }) -- INT 0x21
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_sreg("cs"), 0x3000, "IVT segment")
    eq(cpu.ip, 0x0100, "IVT offset")
    eq(cpu:get_flag("IF"), false, "IF cleared by INT")
    eq(cpu:get_reg16(4), SP - 6, "three words pushed")
    -- Push order: FLAGS (SP-2), CS (SP-4), return IP (SP-6).
    local packed = cpu:read16(SS, SP - 2)
    eq(packed % 2, 0, "CF was clear in the pushed flags")
    eq(floor(packed / 2) % 2, 1, "pushed bit 1 set")
    eq(floor(packed / 512) % 2, 1, "IF was set in the pushed flags")
    eq(cpu:read16(SS, SP - 4), CS, "CS pushed")
    eq(cpu:read16(SS, SP - 6), 0x0102, "return IP pushed")

    cpu:step() -- IRET
    eq(cpu:get_sreg("cs"), CS, "IRET restores CS")
    eq(cpu.ip, 0x0102, "IRET restores IP")
    eq(cpu:get_flag("IF"), true, "IRET restores IF")
    eq(cpu:get_reg16(4), SP, "IRET restores SP")
end)

test("unimplemented interrupt raises with the vector and CS:IP", function()
    local cpu = new_cpu()
    put(cpu, CS, 0x0100, { 0xCD, 0x21 })
    cpu.ip = 0x0100
    local text = expect_error(function() cpu:step() end,
        "cpu: unimplemented interrupt 0x21", "CS:IP=1000:0100")
    contains(text, "0x21", "vector in the message")
end)

test("unknown opcodes raise with CS:IP and the opcode value", function()
    local cpu = new_cpu()
    put(cpu, CS, 0x0100, { 0x0F, 0x0B })
    cpu.ip = 0x0100
    local text = expect_error(function() cpu:step() end,
        "cpu: unimplemented opcode 0x0F", "CS:IP=1000:0100")
    contains(text, "1000:0100", "CS:IP text")

    -- The 0x66 operand size prefix is not implemented either.
    put(cpu, CS, 0x0200, { 0x66, 0x90 })
    cpu.ip = 0x0200
    local text66 = expect_error(function() cpu:step() end,
        "unimplemented opcode 0x66", "CS:IP=1000:0200")
    contains(text66, "0x66", "prefix opcode")

    -- A single unknown opcode byte.
    put(cpu, CS, 0x0300, { 0xD6 })
    cpu.ip = 0x0300
    expect_error(function() cpu:step() end,
        "unimplemented opcode 0xD6", "CS:IP=1000:0300")
end)

test("IN and OUT use the registered port handlers", function()
    local cpu = new_cpu()

    -- Unmapped port raises.
    put(cpu, CS, 0x0100, { 0xE4, 0x60 }) -- IN AL, 0x60
    cpu.ip = 0x0100
    local text = expect_error(function() cpu:step() end,
        "cpu: unmapped I/O port 0x0060", "CS:IP=1000:0100")
    contains(text, "unmapped I/O port", "message")

    local last_in_size
    cpu.ports["in"][0x0060] = function(inner, size)
        eq(inner, cpu, "handler receives the cpu")
        last_in_size = size
        if size == 8 then
            return 0xAB
        end
        return 0x1234
    end
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_reg8(0), 0xAB, "IN AL, 0x60")
    eq(last_in_size, 8, "8-bit IN size")

    put(cpu, CS, 0x0102, { 0xE5, 0x60 }) -- IN AX, 0x60
    cpu.ip = 0x0102
    cpu:step()
    eq(cpu:get_reg16(0), 0x1234, "IN AX, 0x60")
    eq(last_in_size, 16, "16-bit IN size")

    local out_size, out_value, out_port
    cpu.ports.out[0x0061] = function(_, size, value)
        out_size = size
        out_value = value
        out_port = 0x0061
    end
    cpu:set_reg8(0, 0x5A)
    put(cpu, CS, 0x0200, { 0xE6, 0x61 }) -- OUT 0x61, AL
    cpu.ip = 0x0200
    cpu:step()
    eq(out_port, 0x0061, "OUT port")
    eq(out_size, 8, "OUT size")
    eq(out_value, 0x5A, "OUT value")

    -- DX forms: IN AL, DX and OUT DX, AX.
    cpu.ports["in"][0x03F8] = cpu.ports["in"][0x0060]
    cpu.ports.out[0x03F8] = cpu.ports.out[0x0061]
    cpu:set_reg16(2, 0x03F8)
    put(cpu, CS, 0x0300, { 0xEC }) -- IN AL, DX
    cpu.ip = 0x0300
    cpu:step()
    eq(cpu:get_reg8(0), 0xAB, "IN AL, DX")

    cpu:set_reg16(0, 0x5A5A)
    put(cpu, CS, 0x0302, { 0xEF }) -- OUT DX, AX
    cpu.ip = 0x0302
    cpu:step()
    eq(out_size, 16, "OUT DX, AX size")
    eq(out_value, 0x5A5A, "OUT DX, AX value")
end)

test("HLT stops the run loop with reason halted", function()
    local cpu = new_cpu()
    eq(cpu.halted, false, "not halted initially")
    put(cpu, CS, 0x0100, { 0x90, 0x90, 0xF4 })
    cpu.ip = 0x0100
    local executed, reason = cpu:run()
    eq(executed, 3, "executed instructions")
    eq(reason, "halted", "reason")
    eq(cpu.halted, true, "halted flag")
    eq(cpu.steps, 3, "step counter")
end)

test("run returns limit when max_steps is reached", function()
    local cpu = new_cpu()
    for i = 0, 9 do
        cpu:write8(CS, 0x0100 + i, 0x90)
    end
    cpu.ip = 0x0100
    local executed, reason = cpu:run(4)
    eq(executed, 4, "executed instructions")
    eq(reason, "limit", "reason")
    eq(cpu.ip, 0x0104, "IP after four NOPs")
    eq(cpu.halted, false, "not halted")
end)

test("run calls the injected sleep every sleep_interval instructions", function()
    local calls = {}
    local cpu = new_cpu({
        sleep = function(seconds)
            calls[#calls + 1] = seconds
        end,
        sleep_interval = 200,
    })

    for i = 0, 399 do
        cpu:write8(CS, 0x0100 + i, 0x90)
    end
    cpu:write8(CS, 0x0100 + 400, 0xF4)
    cpu.ip = 0x0100

    local executed, reason = cpu:run()
    eq(executed, 401, "executed instructions")
    eq(reason, "halted", "reason")
    eq(#calls, 2, "sleep call count")
    eq(calls[1], 0, "first sleep argument")
    eq(calls[2], 0, "second sleep argument")
end)

test("group 5 INC/DEC memory operands advance the IP", function()
    local cpu = new_cpu()
    cpu:write16(DS, 0x0100, 0x1234)

    put(cpu, CS, 0x0100, { 0xFF, 0x06, 0x00, 0x01 }) -- INC word [0x0100]
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.ip, 0x0104, "INC word [mem] advances IP")
    eq(cpu:read16(DS, 0x0100), 0x1235, "INC word [mem] increments")

    put(cpu, CS, 0x0110, { 0xFF, 0x0E, 0x00, 0x01 }) -- DEC word [0x0100]
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu.ip, 0x0114, "DEC word [mem] advances IP")
    eq(cpu:read16(DS, 0x0100), 0x1234, "DEC word [mem] decrements")

    -- The CS: override form is the one COMMAND.COM's busy-wait loop uses.
    cpu:write16(CS, 0x1200, 0x0001)
    put(cpu, CS, 0x0120, { 0x2E, 0xFF, 0x06, 0x00, 0x12 })
    cpu.ip = 0x0120
    cpu:step()
    eq(cpu.ip, 0x0125, "CS: INC word [mem] advances IP")
    eq(cpu:read16(CS, 0x1200), 0x0002, "CS: INC word [mem] increments")
end)

test("BCD adjust instructions advance the IP", function()
    local cpu = new_cpu()
    local cases = {
        {0x27, 1}, -- DAA
        {0x2F, 1}, -- DAS
        {0x37, 1}, -- AAA
        {0x3F, 1}, -- AAS
        {0xD4, 2}, -- AAM
        {0xD5, 2}, -- AAD
    }
    for i = 1, #cases do
        local op, len = cases[i][1], cases[i][2]
        cpu.ip = 0x0200
        if len == 1 then
            put(cpu, CS, 0x0200, { op })
        else
            put(cpu, CS, 0x0200, { op, 0x0A })
        end
        cpu:step()
        eq(cpu.ip, 0x0200 + len,
            "opcode " .. string.format("%02X", op) .. " advances IP")
    end
end)

test("step rejects a handler that does not advance the IP", function()
    local cpu = new_cpu()
    local original = Cpu.handlers[0x91] -- XCHG AX, CX
    Cpu.handlers[0x91] = function()
        return nil
    end
    local ok, err = pcall(function()
        cpu.ip = 0x0100
        put(cpu, CS, 0x0100, { 0x91 })
        cpu:step()
    end)
    Cpu.handlers[0x91] = original
    if ok then
        error("step accepted a handler that left IP unchanged", 2)
    end
    local text = tostring(err)
    if not text:find("did not advance IP", 1, true) then
        error("unexpected diagnostic: " .. text, 2)
    end
    if not text:find("0x91", 1, true) then
        error("diagnostic does not name the opcode: " .. text, 2)
    end
end)

test("LAHF and SAHF", function()
    local cpu = new_cpu()
    cpu:set_flag("CF", true)
    cpu:set_flag("PF", true)
    cpu:set_flag("AF", true)
    cpu:set_flag("ZF", true)
    cpu:set_flag("SF", true)

    put(cpu, CS, 0x0100, { 0x9F }) -- LAHF (0x9F according to the Intel ISA)
    cpu.ip = 0x0100
    cpu:step()
    -- SF ZF 0 AF 0 PF 1 CF = 0xD7
    eq(cpu:get_reg8(4), 0xD7, "LAHF packed AH")

    -- SAHF (0x9E) loads CF, PF, AF, ZF and SF from AH (0x53 = 0101 0011).
    cpu:set_reg8(4, 0x53)
    cpu:set_flag("OF", true)
    put(cpu, CS, 0x0110, { 0x9E })
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:get_flag("CF"), true, "SAHF CF")
    eq(cpu:get_flag("PF"), false, "SAHF PF")
    eq(cpu:get_flag("AF"), true, "SAHF AF")
    eq(cpu:get_flag("ZF"), true, "SAHF ZF")
    eq(cpu:get_flag("SF"), false, "SAHF SF")
    eq(cpu:get_flag("OF"), true, "SAHF leaves OF alone")
end)

test("flag control instructions", function()
    local cpu = new_cpu()
    cpu:set_flag("CF", false)
    put(cpu, CS, 0x0100, { 0xF9, 0xF8, 0xF5, 0xF5 }) -- STC CLC CMC CMC
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu:get_flag("CF"), true, "STC")
    cpu:step()
    eq(cpu:get_flag("CF"), false, "CLC")
    cpu:step()
    eq(cpu:get_flag("CF"), true, "CMC toggles on")
    cpu:step()
    eq(cpu:get_flag("CF"), false, "CMC toggles off")

    cpu:set_flag("IF", true)
    cpu:set_flag("DF", false)
    put(cpu, CS, 0x0110, { 0xFA, 0xFB, 0xFD, 0xFC }) -- CLI STI STD CLD
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:get_flag("IF"), false, "CLI")
    cpu:step()
    eq(cpu:get_flag("IF"), true, "STI")
    cpu:step()
    eq(cpu:get_flag("DF"), true, "STD")
    cpu:step()
    eq(cpu:get_flag("DF"), false, "CLD")
end)

test("group 1 sign-extends the imm8 form and writes memory", function()
    local cpu = new_cpu()

    -- MOV AX, 0 ; ADD AX, -128 (0x83 /0 with imm8 0x80) -> 0xFF80.
    put(cpu, CS, 0x0100, { 0xB8, 0x00, 0x00, 0x83, 0xC0, 0x80 })
    cpu.ip = 0x0100
    cpu:step()
    cpu:step()
    eq(cpu:get_reg16(0), 0xFF80, "ADD AX, sign-extended imm8")

    -- SUB AX, 1 -> 0xFF7F, no borrow out of 16 bits.
    put(cpu, CS, 0x0110, { 0x83, 0xE8, 0x01 })
    cpu.ip = 0x0110
    cpu:step()
    eq(cpu:get_reg16(0), 0xFF7F, "SUB AX, imm8")

    -- ADD [BX], AL writes through the ModR/M memory operand.
    cpu.seg.ds = DS
    cpu:set_reg16(3, 0x0100)
    cpu:set_reg8(0, 0x01)
    cpu:write8(DS, 0x0100, 0x10)
    put(cpu, CS, 0x0200, { 0x00, 0x07 }) -- ADD [BX], AL
    cpu.ip = 0x0200
    cpu:step()
    eq(cpu:read8(DS, 0x0100), 0x11, "ADD [BX], AL")

    -- SBB AX, [BX] reads the memory operand.
    cpu:set_reg16(0, 0x0100)
    cpu:write16(DS, 0x0100, 0x0001)
    cpu:set_flag("CF", false)
    put(cpu, CS, 0x0300, { 0x1B, 0x07 }) -- SBB AX, [BX]
    cpu.ip = 0x0300
    cpu:step()
    eq(cpu:get_reg16(0), 0x00FF, "SBB AX, [BX]")
end)

---------------------------------------------------------------------------

print(string.format("cpu_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d cpu test(s) failed", failed), 0)
end

return true
