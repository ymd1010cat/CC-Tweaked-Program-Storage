---------------------------------------------------------------------------
-- 80486-simulator/tests/test_cpu_matrix.lua
--
-- Data-driven opcode matrix tests for cpu.lua.  Each matrix walks every
-- ModR/M reg value and checks the IP advance, result, flags and exception
-- paths.  Expected values come from a small independent oracle below, not
-- from the emulator itself.
--
-- Runs standalone with Lua or inside CraftOS:
--     dofile("/tests/test_cpu_matrix.lua")
---------------------------------------------------------------------------

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
}, function(mod)
    return type(mod) == "table" and type(mod.new) == "function"
end, "cpu.lua")

local Memory = load_module("memory", {
    "80486-simulator/memory.lua",
    "../memory.lua",
    "memory.lua",
    "/80486-simulator/memory.lua",
    "/memory.lua",
}, function(mod)
    return type(mod) == "table" and type(mod.new) == "function"
end, "memory.lua")

local floor = math.floor

---------------------------------------------------------------------------
-- Harness
---------------------------------------------------------------------------

local total  = 0
local passed = 0
local failed = 0

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", tostring(want), tostring(got)), 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not text:find(needle, 1, true) then
        error(string.format("%s: %s does not contain %q",
            label or "text", tostring(text), needle), 2)
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
-- CPU / memory helpers
---------------------------------------------------------------------------

local CS = 0x1000
local DS = 0x2000
local SS = 0x4000
local SP = 0x8000

local P2 = {}
for i = 0, 17 do
    P2[i] = 2 ^ i
end

local function bit(value, n)
    return floor(value / P2[n]) % 2
end

local function parity(value)
    local ones = 0
    local v = value % 256
    for _ = 1, 8 do
        ones = ones + v % 2
        v = floor(v / 2)
    end
    return ones % 2 == 0
end

local function band(a, b)
    local r, p = 0, 1
    for _ = 1, 16 do
        if a % 2 == 1 and b % 2 == 1 then
            r = r + p
        end
        a = floor(a / 2)
        b = floor(b / 2)
        p = p * 2
    end
    return r
end

local function bor(a, b)
    local r, p = 0, 1
    for _ = 1, 16 do
        if a % 2 == 1 or b % 2 == 1 then
            r = r + p
        end
        a = floor(a / 2)
        b = floor(b / 2)
        p = p * 2
    end
    return r
end

local function bxor(a, b)
    local r, p = 0, 1
    for _ = 1, 16 do
        if (a % 2) ~= (b % 2) then
            r = r + p
        end
        a = floor(a / 2)
        b = floor(b / 2)
        p = p * 2
    end
    return r
end

local function new_cpu()
    local cpu = Cpu.new{
        memory = Memory.new(),
        sleep = function() end,
    }
    cpu.seg.cs = CS
    cpu.seg.ds = DS
    cpu.seg.es = 0x3000
    cpu.seg.ss = SS
    cpu.ip = 0x0100
    cpu:set_reg16(4, SP)
    return cpu
end

local function put(cpu, seg, offset, bytes)
    for i = 1, #bytes do
        cpu:write8(seg, offset + i - 1, bytes[i])
    end
end

local FLAG_NAMES = {"CF", "PF", "AF", "ZF", "SF", "OF"}

local function set_flags(cpu, flags)
    for i = 1, #FLAG_NAMES do
        local name = FLAG_NAMES[i]
        if flags[name] ~= nil then
            cpu:set_flag(name, flags[name])
        end
    end
end

local function snapshot_flags(cpu)
    local flags = {}
    for i = 1, #FLAG_NAMES do
        flags[FLAG_NAMES[i]] = cpu:get_flag(FLAG_NAMES[i])
    end
    return flags
end

local function assert_flags(cpu, expected, label)
    for i = 1, #FLAG_NAMES do
        local name = FLAG_NAMES[i]
        if expected[name] ~= nil then
            eq(cpu:get_flag(name), expected[name], label .. " " .. name)
        end
    end
end

local function assert_flags_unchanged(cpu, before, label)
    for i = 1, #FLAG_NAMES do
        local name = FLAG_NAMES[i]
        eq(cpu:get_flag(name), before[name], label .. " " .. name)
    end
end

local function s8(v)
    v = v % 256
    if v >= 0x80 then
        return v - 256
    end
    return v
end

local function s16(v)
    v = v % 65536
    if v >= 0x8000 then
        return v - 65536
    end
    return v
end

local function s32(v)
    v = v % 4294967296
    if v >= 2147483648 then
        return v - 4294967296
    end
    return v
end

-- Truncating division (rounds toward zero) and modulo, as x86 IDIV requires.
-- The remainder keeps the sign of the dividend.
local function trunc_div(a, b)
    local q = a / b
    if q < 0 then
        q = math.ceil(q)
    else
        q = math.floor(q)
    end
    return q, a - q * b
end

local function unsigned_div(a, b)
    local q = floor(a / b)
    return q, a - q * b
end

-- INC/DEC flags.  CF is deliberately not touched by INC/DEC, so it is not
-- part of the returned flag table; callers assert it stays unchanged.
local function inc_dec_oracle(value, bits, direction)
    local mask = (bits == 8) and 0xFF or 0xFFFF
    local sign = (bits == 8) and 0x80 or 0x8000
    local result
    local flags = {}
    if direction > 0 then
        result = (value + 1) % (mask + 1)
        flags.OF = (value == sign - 1)
        flags.AF = (value % 16 == 15)
    else
        result = (value - 1) % (mask + 1)
        flags.OF = (value == sign)
        flags.AF = (value % 16 == 0)
    end
    flags.SF = result >= sign
    flags.ZF = result == 0
    flags.PF = parity(result)
    return result, flags
end

---------------------------------------------------------------------------
-- Independent oracles
---------------------------------------------------------------------------

-- ALU: op 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP.
-- For the logic ops AF is undefined by the ISA and is left out of the
-- result table; callers assert it stays unchanged.
local function alu_oracle(op, a, b, bits, carry_in)
    local mask = (bits == 8) and 0xFF or 0xFFFF
    local sign = (bits == 8) and 0x80 or 0x8000
    local result, flags
    if op == 0 or op == 2 then
        local c = (op == 2 and carry_in) and 1 or 0
        local total = a + b + c
        result = total % (mask + 1)
        flags = {
            CF = total > mask,
            PF = parity(result),
            AF = ((a % 16) + (b % 16) + c) > 15,
            ZF = result == 0,
            SF = result >= sign,
            OF = ((a >= sign) == (b >= sign))
                and ((result >= sign) ~= (a >= sign)),
        }
    elseif op == 3 or op == 5 or op == 7 then
        local c = (op == 3 and carry_in) and 1 or 0
        local diff = a - b - c
        result = diff % (mask + 1)
        flags = {
            CF = diff < 0,
            PF = parity(result),
            AF = (a % 16) < ((b % 16) + c),
            ZF = result == 0,
            SF = result >= sign,
            OF = ((a >= sign) ~= (b >= sign))
                and ((result >= sign) ~= (a >= sign)),
        }
    else
        if op == 1 then
            result = bor(a, b)
        elseif op == 4 then
            result = band(a, b)
        else
            result = bxor(a, b)
        end
        result = result % (mask + 1)
        flags = {
            CF = false,
            PF = parity(result),
            ZF = result == 0,
            SF = result >= sign,
            OF = false,
        }
    end
    return result, flags
end

local function rotate_left(v, n, width)
    local cut = P2[width - n]
    return (v % cut) * P2[n] + floor(v / cut)
end

local function rotate_right(v, n, width)
    return floor(v / P2[n]) + (v % P2[n]) * P2[width - n]
end

-- Shift/rotate: op 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SAL, 7 SAR.
-- The 80186 and later mask the count to five bits.  A masked count of zero
-- leaves value and flags untouched (nil flag table).  Counts that are a
-- nonzero multiple of the operand width shift every bit out: SHL/SHR result
-- in zero, SAR repeats the sign, and CF receives the original sign bit.
-- OF is architecturally undefined for those counts, so the oracle omits it.
local function shift_oracle(op, value, count, bits, carry_in)
    local size = (bits == 8) and 256 or 65536
    local sign = (bits == 8) and 0x80 or 0x8000
    local cnt = count % 32
    if cnt == 0 then
        -- A masked count of zero leaves every flag completely untouched.
        return value, nil
    end
    local n = cnt % bits
    if op == 0 then -- ROL
        if n == 0 then
            -- A full width multiple is the identity; CF is not updated.
            return value, nil
        end
        local r = rotate_left(value, n, bits)
        local cf = (r % 2 == 1)
        return r, {CF = cf, OF = ((r >= sign) ~= cf)}
    elseif op == 1 then -- ROR
        if n == 0 then
            return value, nil
        end
        local r = rotate_right(value, n, bits)
        return r, {
            CF = r >= sign,
            OF = ((r >= sign) ~= (bit(r, bits - 2) == 1)),
        }
    elseif op == 2 then -- RCL
        local rn = cnt % (bits + 1)
        if rn == 0 then
            return value, nil
        end
        local tmp = value + (carry_in and size or 0)
        local r9 = rotate_left(tmp, rn, bits + 1)
        local cf = r9 >= size
        local r = r9 % size
        return r, {CF = cf, OF = ((r >= sign) ~= cf)}
    elseif op == 3 then -- RCR
        local rn = cnt % (bits + 1)
        if rn == 0 then
            return value, nil
        end
        local tmp = value + (carry_in and size or 0)
        local r9 = rotate_right(tmp, rn, bits + 1)
        local cf = r9 >= size
        local r = r9 % size
        return r, {
            CF = cf,
            OF = ((r >= sign) ~= (bit(r, bits - 2) == 1)),
        }
    elseif op == 4 or op == 6 then -- SHL / SAL
        if n == 0 then
            return 0, {
                CF = bit(value, bits - 1) == 1,
                PF = parity(0),
                ZF = true,
                SF = false,
            }
        end
        local r = (value * P2[n]) % size
        local cf = (bit(value, bits - n) == 1)
        return r, {
            CF = cf,
            OF = ((r >= sign) ~= cf),
            PF = parity(r),
            ZF = r == 0,
            SF = r >= sign,
        }
    elseif op == 5 then -- SHR
        if n == 0 then
            return 0, {
                CF = bit(value, bits - 1) == 1,
                PF = parity(0),
                ZF = true,
                SF = false,
            }
        end
        local r = floor(value / P2[n])
        return r, {
            CF = (bit(value, n - 1) == 1),
            OF = value >= sign,
            PF = parity(r),
            ZF = r == 0,
            SF = false,
        }
    else -- SAR
        if n == 0 then
            local r = (value >= sign) and (size - 1) or 0
            return r, {
                CF = bit(value, bits - 1) == 1,
                PF = parity(r),
                ZF = r == 0,
                SF = r >= sign,
            }
        end
        local signed = (value >= sign) and (value - size) or value
        local r = floor(signed / P2[n]) % size
        return r, {
            CF = (bit(value, n - 1) == 1),
            OF = false,
            PF = parity(r),
            ZF = r == 0,
            SF = r >= sign,
        }
    end
end

local JCC_CONDITIONS = {
    function(f) return f.OF end,                       -- 0x70 JO
    function(f) return not f.OF end,                   -- 0x71 JNO
    function(f) return f.CF end,                       -- 0x72 JB
    function(f) return not f.CF end,                   -- 0x73 JAE
    function(f) return f.ZF end,                       -- 0x74 JE
    function(f) return not f.ZF end,                   -- 0x75 JNE
    function(f) return f.CF or f.ZF end,               -- 0x76 JBE
    function(f) return not f.CF and not f.ZF end,      -- 0x77 JA
    function(f) return f.SF end,                       -- 0x78 JS
    function(f) return not f.SF end,                   -- 0x79 JNS
    function(f) return f.PF end,                       -- 0x7A JP
    function(f) return not f.PF end,                   -- 0x7B JNP
    function(f) return f.SF ~= f.OF end,               -- 0x7C JL
    function(f) return f.SF == f.OF end,               -- 0x7D JGE
    function(f) return f.ZF or (f.SF ~= f.OF) end,     -- 0x7E JLE
    function(f) return not f.ZF and f.SF == f.OF end,  -- 0x7F JG
}

---------------------------------------------------------------------------
-- Matrix 1: ALU group 0x80 / 0x81 / 0x82 / 0x83
---------------------------------------------------------------------------

test("ALU group 0x80-0x83 reg 0-7 x register/memory matrix", function()
    local configs = {
        {opcode = 0x80, bits = 8,  imm_bits = 8},
        {opcode = 0x81, bits = 16, imm_bits = 16},
        {opcode = 0x82, bits = 8,  imm_bits = 8},
        {opcode = 0x83, bits = 16, imm_bits = 8},
    }
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local mask = (bits == 8) and 0xFF or 0xFFFF
        for op = 0, 7 do
            for form = 1, 2 do -- 1 = register destination, 2 = memory
                local cpu = new_cpu()
                local a = (bits == 8) and 0xA5 or 0xA5A5
                local imm = (cfg.imm_bits == 8) and 0xF0 or 0x1234
                local b
                if bits == 8 then
                    b = imm % 256
                elseif cfg.imm_bits == 8 then
                    b = (imm >= 0x80) and (imm - 256) or imm
                    b = b % 65536
                else
                    b = imm % 65536
                end

                set_flags(cpu, {
                    CF = true, PF = false, AF = true,
                    ZF = false, SF = false, OF = false,
                })
                if form == 1 then
                    if bits == 8 then
                        cpu:set_reg8(0, a)
                    else
                        cpu:set_reg16(0, a)
                    end
                else
                    if bits == 8 then
                        cpu:write8(DS, 0x0300, a)
                    else
                        cpu:write16(DS, 0x0300, a)
                    end
                end

                local code
                if form == 1 then
                    code = {cfg.opcode, 0xC0 + op * 8}
                else
                    code = {cfg.opcode, op * 8 + 6, 0x00, 0x03}
                end
                if cfg.imm_bits == 8 then
                    code[#code + 1] = imm % 256
                else
                    code[#code + 1] = imm % 256
                    code[#code + 1] = floor(imm / 256) % 256
                end
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()

                eq(cpu.ip, 0x0100 + #code,
                    string.format("opcode %02X reg %d form %d IP",
                        cfg.opcode, op, form))
                local got
                if form == 1 then
                    got = (bits == 8) and cpu:get_reg8(0)
                        or cpu:get_reg16(0)
                else
                    got = (bits == 8) and cpu:read8(DS, 0x0300)
                        or cpu:read16(DS, 0x0300)
                end
                local result, flags = alu_oracle(op, a, b, bits, true)
                local want = (op == 7) and a or result
                eq(got % (mask + 1), want,
                    string.format("opcode %02X reg %d form %d result",
                        cfg.opcode, op, form))
                if op == 1 or op == 4 or op == 6 then
                    -- AF is undefined for logic operations and must be
                    -- left untouched by the handler.
                    flags.AF = true
                end
                assert_flags(cpu, flags,
                    string.format("opcode %02X reg %d form %d flags",
                        cfg.opcode, op, form))
                cases = cases + 1
            end
        end
    end
    eq(cases, 64, "ALU matrix case count")
end)

test("ALU boundary operands exercise all six flags", function()
    -- Each pair targets a documented corner: signed overflow, wrap-around,
    -- borrows and the signed minimum.  ADC/SBB run with CF=1 preset.
    local pairs_8 = {
        {0x7F, 0x01}, -- max positive + 1 -> OF
        {0x80, 0x80}, -- signed minimum + itself
        {0x00, 0x01}, -- 0 - 1 -> borrow CF
        {0x80, 0x00}, -- signed minimum with zero
        {0x80, 0xFF}, -- minimum + / - one
        {0xFF, 0x01}, -- -1 + 1 / -1 - 1
        {0x00, 0xFF}, -- 0 - 255 -> borrow CF
    }
    local pairs_16 = {
        {0x7FFF, 0x0001},
        {0x8000, 0x8000},
        {0x0000, 0x0001},
        {0x8000, 0x0000},
        {0x8000, 0xFFFF},
        {0xFFFF, 0x0001},
        {0x0000, 0xFFFF},
    }
    local cases = 0

    for pi = 1, #pairs_8 do
        local a = pairs_8[pi][1]
        local b = pairs_8[pi][2]
        for op = 0, 7 do
            local cpu = new_cpu()
            set_flags(cpu, {
                CF = true, PF = false, AF = true,
                ZF = false, SF = false, OF = false,
            })
            cpu:set_reg8(0, a)
            put(cpu, CS, 0x0100, {0x80, 0xC0 + op * 8, b})
            cpu.ip = 0x0100
            cpu:step()
            local label = string.format("ALU8 pair %d op %d", pi, op)
            eq(cpu.ip, 0x0103, label .. " IP")
            local result, flags = alu_oracle(op, a, b, 8, true)
            local want = (op == 7) and a or result
            eq(cpu:get_reg8(0), want, label .. " result")
            if op == 1 or op == 4 or op == 6 then
                flags.AF = true
            end
            assert_flags(cpu, flags, label .. " flags")
            cases = cases + 1
        end
    end

    for pi = 1, #pairs_16 do
        local a = pairs_16[pi][1]
        local b = pairs_16[pi][2]
        for op = 0, 7 do
            local cpu = new_cpu()
            set_flags(cpu, {
                CF = true, PF = false, AF = true,
                ZF = false, SF = false, OF = false,
            })
            cpu:set_reg16(0, a)
            put(cpu, CS, 0x0100, {0x81, 0xC0 + op * 8,
                b % 256, floor(b / 256) % 256})
            cpu.ip = 0x0100
            cpu:step()
            local label = string.format("ALU16 pair %d op %d", pi, op)
            eq(cpu.ip, 0x0104, label .. " IP")
            local result, flags = alu_oracle(op, a, b, 16, true)
            local want = (op == 7) and a or result
            eq(cpu:get_reg16(0), want, label .. " result")
            if op == 1 or op == 4 or op == 6 then
                flags.AF = true
            end
            assert_flags(cpu, flags, label .. " flags")
            cases = cases + 1
        end
    end
    eq(cases, (7 + 7) * 8, "ALU boundary case count")
end)

---------------------------------------------------------------------------
-- Matrix 2: shift/rotate group
---------------------------------------------------------------------------

test("shift group 0xC0/C1/D0/D1/D2/D3 reg 0-7 matrix", function()
    local configs = {
        {opcode = 0xC0, bits = 8,  mode = "imm8"},
        {opcode = 0xC1, bits = 16, mode = "imm8"},
        {opcode = 0xD0, bits = 8,  mode = "one"},
        {opcode = 0xD1, bits = 16, mode = "one"},
        {opcode = 0xD2, bits = 8,  mode = "cl"},
        {opcode = 0xD3, bits = 16, mode = "cl"},
    }
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local mask = (bits == 8) and 0xFF or 0xFFFF
        local value = (bits == 8) and 0x81 or 0x8001
        for reg = 0, 7 do
            local cpu = new_cpu()
            set_flags(cpu, {
                CF = true, PF = false, AF = false,
                ZF = false, SF = false, OF = false,
            })
            if bits == 8 then
                cpu:set_reg8(0, value)
            else
                cpu:set_reg16(0, value)
            end
            local code = {cfg.opcode, 0xC0 + reg * 8}
            if cfg.mode == "imm8" then
                code[#code + 1] = 1
            elseif cfg.mode == "cl" then
                cpu:set_reg8(1, 1)
            end
            put(cpu, CS, 0x0100, code)
            cpu.ip = 0x0100
            cpu:step()

            eq(cpu.ip, 0x0100 + #code,
                string.format("opcode %02X reg %d IP", cfg.opcode, reg))
            local got = (bits == 8) and cpu:get_reg8(0)
                or cpu:get_reg16(0)
            local want, flags = shift_oracle(reg, value, 1, bits, true)
            eq(got % (mask + 1), want,
                string.format("opcode %02X reg %d result",
                    cfg.opcode, reg))
            assert_flags(cpu, flags,
                string.format("opcode %02X reg %d flags", cfg.opcode, reg))
            cases = cases + 1
        end
    end
    eq(cases, 48, "shift matrix case count")
end)

test("shift count 0 leaves value and every flag unchanged", function()
    local configs = {
        {opcode = 0xC0, bits = 8,  mode = "imm8"},
        {opcode = 0xC1, bits = 16, mode = "imm8"},
        {opcode = 0xD2, bits = 8,  mode = "cl"},
        {opcode = 0xD3, bits = 16, mode = "cl"},
    }
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local value = (bits == 8) and 0x81 or 0x8001
        for reg = 0, 7 do
            local cpu = new_cpu()
            local before = {
                CF = true, PF = true, AF = true,
                ZF = true, SF = true, OF = true,
            }
            set_flags(cpu, before)
            if bits == 8 then
                cpu:set_reg8(0, value)
            else
                cpu:set_reg16(0, value)
            end
            local code = {cfg.opcode, 0xC0 + reg * 8}
            if cfg.mode == "imm8" then
                code[#code + 1] = 0
            else
                cpu:set_reg8(1, 0)
            end
            put(cpu, CS, 0x0100, code)
            cpu.ip = 0x0100
            cpu:step()
            local label = string.format("shift0 %02X reg %d",
                cfg.opcode, reg)
            eq(cpu.ip, 0x0100 + #code, label .. " IP")
            local got = (bits == 8) and cpu:get_reg8(0)
                or cpu:get_reg16(0)
            -- Cross-check against the oracle as well: both the snapshot and
            -- the oracle must agree that a zero count is a complete no-op.
            local want, flags = shift_oracle(reg, value, 0, bits, true)
            eq(want, value, label .. " oracle value unchanged")
            eq(flags, nil, label .. " oracle flags untouched")
            eq(got, want, label .. " value unchanged")
            assert_flags_unchanged(cpu, before, label .. " flags")
            cases = cases + 1
        end
    end
    eq(cases, 32, "shift count 0 case count")
end)

test("RCL/RCR count 1 carry-in boundary", function()
    local values_8 = {0x00, 0x80, 0xFF}
    local values_16 = {0x0000, 0x8000, 0xFFFF}
    local cases = 0
    local configs = {
        {opcode = 0xD0, bits = 8},
        {opcode = 0xD1, bits = 16},
    }
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local values = (bits == 8) and values_8 or values_16
        for vi = 1, #values do
            for _, op in ipairs({2, 3}) do -- RCL / RCR
                for _, cf in ipairs({false, true}) do
                    local cpu = new_cpu()
                    set_flags(cpu, {
                        CF = cf, PF = false, AF = false,
                        ZF = false, SF = false, OF = false,
                    })
                    local value = values[vi]
                    if bits == 8 then
                        cpu:set_reg8(0, value)
                    else
                        cpu:set_reg16(0, value)
                    end
                    put(cpu, CS, 0x0100, {cfg.opcode, 0xC0 + op * 8})
                    cpu.ip = 0x0100
                    cpu:step()
                    local label = string.format("RCL/RCR %02X op %d v %d cf %s",
                        cfg.opcode, op, value, tostring(cf))
                    local got = (bits == 8) and cpu:get_reg8(0)
                        or cpu:get_reg16(0)
                    local want, flags = shift_oracle(op, value, 1, bits, cf)
                    eq(cpu.ip, 0x0102, label .. " IP")
                    eq(got, want, label .. " result")
                    eq(cpu:get_flag("CF"), flags.CF, label .. " CF")
                    eq(cpu:get_flag("OF"), flags.OF, label .. " OF")
                    cases = cases + 1
                end
            end
        end
    end
    eq(cases, 24, "RCL/RCR boundary case count")
end)

test("shift full width counts shift every bit out", function()
    local configs = {
        {opcode = 0xC0, bits = 8,  mode = "imm8"},
        {opcode = 0xC1, bits = 16, mode = "imm8"},
        {opcode = 0xD2, bits = 8,  mode = "cl"},
        {opcode = 0xD3, bits = 16, mode = "cl"},
    }
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local mask = (bits == 8) and 0xFF or 0xFFFF
        -- 8-bit: every nonzero multiple of 8 below the 32 count mask, plus
        -- 32 itself (masked to zero).  16-bit: the single multiple 16, plus
        -- the masked-to-zero count 32.
        local counts = (bits == 8) and {8, 16, 24, 32} or {16, 32}
        local values = (bits == 8) and {0x81, 0x01} or {0x8001, 0x0001}
        for cni = 1, #counts do
            local count = counts[cni]
            for vi = 1, #values do
                local value = values[vi]
                for reg = 0, 7 do
                    local cpu = new_cpu()
                    local before = {
                        CF = true, PF = false, AF = true,
                        ZF = false, SF = false, OF = false,
                    }
                    set_flags(cpu, before)
                    if bits == 8 then
                        cpu:set_reg8(0, value)
                    else
                        cpu:set_reg16(0, value)
                    end
                    local code = {cfg.opcode, 0xC0 + reg * 8}
                    if cfg.mode == "imm8" then
                        code[#code + 1] = count
                    else
                        cpu:set_reg8(1, count)
                    end
                    put(cpu, CS, 0x0100, code)
                    cpu.ip = 0x0100
                    cpu:step()

                    local label = string.format(
                        "full %02X bits %d count %d value %04X reg %d",
                        cfg.opcode, bits, count, value, reg)
                    eq(cpu.ip, 0x0100 + #code, label .. " IP")
                    local got = (bits == 8) and cpu:get_reg8(0)
                        or cpu:get_reg16(0)
                    local want, flags = shift_oracle(reg, value, count, bits,
                        true)
                    eq(got % (mask + 1), want, label .. " result")
                    if flags then
                        -- OF is architecturally undefined for these counts
                        -- and the oracle omits it; CF/PF/ZF/SF are defined.
                        assert_flags(cpu, flags, label .. " flags")
                    else
                        -- ROL/ROR/RCL/RCR with an effective count of zero
                        -- leave the value and every flag untouched.
                        eq(got, value, label .. " value unchanged")
                        assert_flags_unchanged(cpu, before, label .. " flags")
                    end
                    cases = cases + 1
                end
            end
        end
    end
    eq(cases, (2 * 4 + 2 * 2) * 2 * 8, "shift full width case count")
end)

test("RCL/RCR effective count zero leaves flags untouched", function()
    -- The rotate-through-carry ring is bits + 1 wide, so counts that are a
    -- nonzero multiple of bits + 1 (9 for 8-bit, 17 for 16-bit) must behave
    -- like a zero count: value and every flag stay unchanged, CF included.
    local configs = {
        {opcode = 0xC0, bits = 8,  mode = "imm8", counts = {9, 18, 27}},
        {opcode = 0xC1, bits = 16, mode = "imm8", counts = {17}},
        {opcode = 0xD2, bits = 8,  mode = "cl",   counts = {9, 18, 27}},
        {opcode = 0xD3, bits = 16, mode = "cl",   counts = {17}},
    }
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        for cni = 1, #cfg.counts do
            local count = cfg.counts[cni]
            for _, cf in ipairs({false, true}) do
                for _, op in ipairs({2, 3}) do -- RCL / RCR
                    local cpu = new_cpu()
                    local before = {
                        CF = cf, PF = true, AF = true,
                        ZF = true, SF = true, OF = true,
                    }
                    set_flags(cpu, before)
                    local value = (bits == 8) and 0x81 or 0x8001
                    if bits == 8 then
                        cpu:set_reg8(0, value)
                    else
                        cpu:set_reg16(0, value)
                    end
                    local code = {cfg.opcode, 0xC0 + op * 8}
                    if cfg.mode == "imm8" then
                        code[#code + 1] = count
                    else
                        cpu:set_reg8(1, count)
                    end
                    put(cpu, CS, 0x0100, code)
                    cpu.ip = 0x0100
                    cpu:step()
                    local label = string.format(
                        "rcl0 %02X bits %d count %d op %d cf %s",
                        cfg.opcode, bits, count, op, tostring(cf))
                    local got = (bits == 8) and cpu:get_reg8(0)
                        or cpu:get_reg16(0)
                    eq(cpu.ip, 0x0100 + #code, label .. " IP")
                    eq(got, value, label .. " value unchanged")
                    assert_flags_unchanged(cpu, before, label .. " flags")
                    cases = cases + 1
                end
            end
        end
    end
    eq(cases, (3 + 1 + 3 + 1) * 2 * 2, "RCL/RCR effective zero case count")
end)

---------------------------------------------------------------------------
-- Matrix 3: group 3 (0xF6 / 0xF7)
---------------------------------------------------------------------------

test("group 3 0xF6/0xF7 reg 0-7 matrix", function()
    local configs = {{opcode = 0xF6, bits = 8}, {opcode = 0xF7, bits = 16}}
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        local bits = cfg.bits
        local mask = (bits == 8) and 0xFF or 0xFFFF
        for reg = 0, 7 do
            local cpu = new_cpu()
            local before = {
                CF = true, PF = false, AF = true,
                ZF = false, SF = true, OF = false,
            }
            set_flags(cpu, before)
            local code
            local label = string.format("opcode %02X reg %d", cfg.opcode, reg)

            if reg == 0 or reg == 1 then -- TEST r/m, imm
                local a = (bits == 8) and 0xA5 or 0xA5A5
                local imm = (bits == 8) and 0x0F or 0x00FF
                if bits == 8 then
                    cpu:set_reg8(0, a)
                else
                    cpu:set_reg16(0, a)
                end
                code = {cfg.opcode, 0xC0 + reg * 8}
                if bits == 8 then
                    code[#code + 1] = imm
                else
                    code[#code + 1] = imm % 256
                    code[#code + 1] = floor(imm / 256) % 256
                end
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local got = (bits == 8) and cpu:get_reg8(0)
                    or cpu:get_reg16(0)
                eq(got, a, label .. " accumulator unchanged")
                local _, flags = alu_oracle(4, a, imm, bits, false)
                flags.AF = true
                assert_flags(cpu, flags, label .. " flags")
            elseif reg == 2 then -- NOT r/m
                local a = (bits == 8) and 0x5A or 0x5A5A
                if bits == 8 then
                    cpu:set_reg8(0, a)
                else
                    cpu:set_reg16(0, a)
                end
                code = {cfg.opcode, 0xC0 + reg * 8}
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local got = (bits == 8) and cpu:get_reg8(0)
                    or cpu:get_reg16(0)
                eq(got, (mask - a) % (mask + 1), label .. " result")
                assert_flags_unchanged(cpu, before, label .. " flags")
            elseif reg == 3 then -- NEG r/m
                local a = (bits == 8) and 0x7F or 0x7FFF
                if bits == 8 then
                    cpu:set_reg8(0, a)
                else
                    cpu:set_reg16(0, a)
                end
                code = {cfg.opcode, 0xC0 + reg * 8}
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local got = (bits == 8) and cpu:get_reg8(0)
                    or cpu:get_reg16(0)
                local result, flags = alu_oracle(5, 0, a, bits, false)
                eq(got, result, label .. " result")
                assert_flags(cpu, flags, label .. " flags")
            elseif reg == 4 or reg == 5 then -- MUL / IMUL
                local source = (bits == 8) and 0x06 or 0x0006
                local acc = (reg == 5) and ((bits == 8) and 0xFE or 0xFFFE)
                    or ((bits == 8) and 0x07 or 0x0007)
                if bits == 8 then
                    cpu:set_reg8(0, acc)
                    cpu:set_reg8(1, source)
                else
                    cpu:set_reg16(0, acc)
                    cpu:set_reg16(1, source)
                end
                code = {cfg.opcode, 0xC0 + reg * 8 + 1}
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local a_num, b_num, product
                if bits == 8 then
                    a_num = (reg == 5) and s8(acc) or acc
                    b_num = (reg == 5) and s8(source) or source
                else
                    a_num = (reg == 5) and s16(acc) or acc
                    b_num = (reg == 5) and s16(source) or source
                end
                product = a_num * b_num
                local lo = product % (mask + 1)
                local hi = floor(product / (mask + 1)) % (mask + 1)
                if bits == 8 then
                    eq(cpu:get_reg16(0), product % 65536, label .. " AX")
                else
                    eq(cpu:get_reg16(0), lo, label .. " AX")
                    eq(cpu:get_reg16(2), hi, label .. " DX")
                end
                local overflow
                if reg == 4 then
                    overflow = (product < 0) or (product > mask)
                else
                    overflow = (bits == 8)
                        and (product < -128 or product > 127)
                        or (product < -32768 or product > 32767)
                end
                eq(cpu:get_flag("CF"), overflow, label .. " CF")
                eq(cpu:get_flag("OF"), overflow, label .. " OF")
                local after = snapshot_flags(cpu)
                eq(after.PF, before.PF, label .. " PF unchanged")
                eq(after.AF, before.AF, label .. " AF unchanged")
                eq(after.ZF, before.ZF, label .. " ZF unchanged")
                eq(after.SF, before.SF, label .. " SF unchanged")
            elseif reg == 6 or reg == 7 then -- DIV / IDIV
                local dividend, divisor, q, r
                if bits == 8 then
                    if reg == 6 then
                        dividend = 0x001E
                        divisor = 0x07
                        q, r = unsigned_div(dividend, divisor)
                    else
                        dividend = 0xFFF6 -- -10 as a signed word
                        divisor = 0x03
                        q, r = trunc_div(s16(dividend), s8(divisor))
                    end
                    cpu:set_reg16(0, dividend)
                    cpu:set_reg8(1, divisor)
                    code = {cfg.opcode, 0xC0 + reg * 8 + 1}
                    put(cpu, CS, 0x0100, code)
                    cpu.ip = 0x0100
                    cpu:step()
                    eq(cpu.ip, 0x0100 + #code, label .. " IP")
                    eq(cpu:get_reg8(0), q % 256, label .. " quotient AL")
                    eq(cpu:get_reg8(4), r % 256, label .. " remainder AH")
                else
                    if reg == 6 then
                        dividend = 0x00010002 -- DX=1 AX=2
                        divisor = 0x000A
                        q, r = unsigned_div(dividend, divisor)
                    else
                        dividend = 0xFFFFFFF6 -- -10 in DX:AX
                        divisor = 0x0003
                        q, r = trunc_div(s32(dividend), s16(divisor))
                    end
                    cpu:set_reg16(2, floor(dividend / 65536) % 65536)
                    cpu:set_reg16(0, dividend % 65536)
                    cpu:set_reg16(1, divisor)
                    code = {cfg.opcode, 0xC0 + reg * 8 + 1}
                    put(cpu, CS, 0x0100, code)
                    cpu.ip = 0x0100
                    cpu:step()
                    eq(cpu.ip, 0x0100 + #code, label .. " IP")
                    eq(cpu:get_reg16(0), q % 65536, label .. " quotient AX")
                    eq(cpu:get_reg16(2), r % 65536, label .. " remainder DX")
                end
                assert_flags_unchanged(cpu, before, label .. " flags")
            end
            cases = cases + 1
        end
    end
    eq(cases, 16, "group 3 matrix case count")
end)

test("group 3 DIV/IDIV divide error paths", function()
    local configs = {{opcode = 0xF6, bits = 8}, {opcode = 0xF7, bits = 16}}
    local cases = 0
    for ci = 1, #configs do
        local cfg = configs[ci]
        for _, reg in ipairs({6, 7}) do
            local cpu = new_cpu()
            local code = {cfg.opcode, 0xC0 + reg * 8 + 1}
            put(cpu, CS, 0x0100, code)
            if cfg.bits == 8 then
                cpu:set_reg8(1, 0)
            else
                cpu:set_reg16(1, 0)
            end
            cpu.ip = 0x0100
            expect_error(function()
                cpu:step()
            end, "divide error")
            cases = cases + 1
        end
    end

    -- DIV quotient overflow is also a divide error (AX=FFFF / 1 > 255).
    local cpu = new_cpu()
    cpu:set_reg16(0, 0xFFFF)
    cpu:set_reg8(1, 1)
    put(cpu, CS, 0x0100, {0xF6, 0xC0 + 6 * 8 + 1})
    cpu.ip = 0x0100
    local err = expect_error(function()
        cpu:step()
    end, "divide error")
    contains(tostring(err), "divide error", "overflow diagnostic")
    cases = cases + 1
    eq(cases, 5, "group 3 exception case count")
end)

test("DIV/IDIV signed oracle matrix", function()
    local cases = {
        -- bits, reg (6 DIV / 7 IDIV), unsigned dividend, divisor, #DE?
        {8,  6, 0x001E,     0x07, false}, -- +30 / +7
        {8,  7, 0x001E,     0x03, false}, -- +30 / +3
        {8,  7, 0xFFF6,     0x03, false}, -- -10 / +3
        {8,  7, 0x001E,     0xFD, false}, -- +30 / -3
        {8,  7, 0xFFF6,     0xFD, false}, -- -10 / -3
        {8,  7, 0xFF00,     0x01, true},  -- -256 / +1: quotient overflow
        {16, 6, 0x00010002, 0x000A, false},
        {16, 7, 0xFFFFFFF6, 0x0003, false},
        {16, 7, 0x0000001E, 0xFFF6, false},
        {16, 7, 0xFFFFFFF6, 0xFFF6, false},
        {16, 7, 0xFFFF8000, 0xFFFF, true}, -- -32768 / -1: overflow
        {16, 6, 0xFFFFFFFF, 0x0001, true}, -- quotient > 0xFFFF
    }
    for i = 1, #cases do
        local c = cases[i]
        local bits, reg, dividend, divisor = c[1], c[2], c[3], c[4]
        local expect_divide = c[5]
        local cpu = new_cpu()
        local before = {
            CF = true, PF = false, AF = true,
            ZF = false, SF = false, OF = false,
        }
        set_flags(cpu, before)
        if bits == 8 then
            cpu:set_reg16(0, dividend)
            cpu:set_reg8(1, divisor)
        else
            cpu:set_reg16(2, floor(dividend / 65536) % 65536)
            cpu:set_reg16(0, dividend % 65536)
            cpu:set_reg16(1, divisor)
        end
        local opcode = (bits == 8) and 0xF6 or 0xF7
        put(cpu, CS, 0x0100, {opcode, 0xC0 + reg * 8 + 1})
        cpu.ip = 0x0100

        if expect_divide then
            expect_error(function()
                cpu:step()
            end, "divide error")
        else
            cpu:step()
            local q, r
            if reg == 6 then
                q, r = unsigned_div(dividend, divisor)
            elseif bits == 8 then
                q, r = trunc_div(s16(dividend), s8(divisor))
            else
                q, r = trunc_div(s32(dividend), s16(divisor))
            end
            local label = string.format("DIV/IDIV case %d", i)
            if bits == 8 then
                eq(cpu:get_reg8(0), q % 256, label .. " quotient")
                eq(cpu:get_reg8(4), r % 256, label .. " remainder")
            else
                eq(cpu:get_reg16(0), q % 65536, label .. " quotient")
                eq(cpu:get_reg16(2), r % 65536, label .. " remainder")
            end
            assert_flags_unchanged(cpu, before, label .. " flags")
        end
    end
    eq(#cases, 12, "DIV/IDIV oracle case count")
end)

---------------------------------------------------------------------------
-- Matrix 4: group 4 / 5 (0xFE / 0xFF)
---------------------------------------------------------------------------

test("group 4 0xFE INC/DEC flags matrix and illegal regs", function()
    local cases = 0
    local groups = {
        {reg = 0, values = {0x7F, 0xFF, 0x00}},
        {reg = 1, values = {0x80, 0x01, 0xFF}},
    }
    for gi = 1, #groups do
        local reg = groups[gi].reg
        local list = groups[gi].values
        local direction = (reg == 0) and 1 or -1
        for form = 1, 2 do
            for vi = 1, #list do
                local value = list[vi]
                local cpu = new_cpu()
                local before = {
                    CF = true, PF = false, AF = false,
                    ZF = false, SF = false, OF = false,
                }
                set_flags(cpu, before)
                if form == 1 then
                    cpu:set_reg8(0, value)
                else
                    cpu:write8(DS, 0x0300, value)
                end
                local code = {0xFE, 0xC0 + reg * 8}
                if form == 2 then
                    code = {0xFE, reg * 8 + 6, 0x00, 0x03}
                end
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                local label = string.format("0xFE reg %d form %d value %02X",
                    reg, form, value)
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local got = (form == 1) and cpu:get_reg8(0)
                    or cpu:read8(DS, 0x0300)
                local want, flags = inc_dec_oracle(value, 8, direction)
                eq(got, want, label .. " result")
                eq(cpu:get_flag("CF"), true, label .. " CF unchanged")
                assert_flags(cpu, flags, label .. " flags")
                cases = cases + 1
            end
        end
    end

    for reg = 2, 7 do
        local cpu = new_cpu()
        put(cpu, CS, 0x0100, {0xFE, 0xC0 + reg * 8})
        cpu.ip = 0x0100
        expect_error(function()
            cpu:step()
        end, "unimplemented opcode")
        cases = cases + 1
    end
    eq(cases, 18, "0xFE case count")
end)

test("group 5 0xFF INC/DEC/CALL/JMP/PUSH matrix", function()
    local cases = 0

    -- INC/DEC register and memory forms with full flag checks.
    local groups = {
        {reg = 0, values = {0x7FFF, 0xFFFF, 0x0000}},
        {reg = 1, values = {0x8000, 0x0001, 0xFFFF}},
    }
    for gi = 1, #groups do
        local reg = groups[gi].reg
        local list = groups[gi].values
        local direction = (reg == 0) and 1 or -1
        for form = 1, 2 do
            for vi = 1, #list do
                local value = list[vi]
                local cpu = new_cpu()
                local before = {
                    CF = true, PF = false, AF = false,
                    ZF = false, SF = false, OF = false,
                }
                set_flags(cpu, before)
                if form == 1 then
                    cpu:set_reg16(0, value)
                else
                    cpu:write16(DS, 0x0300, value)
                end
                local code = {0xFF, 0xC0 + reg * 8}
                if form == 2 then
                    code = {0xFF, reg * 8 + 6, 0x00, 0x03}
                end
                put(cpu, CS, 0x0100, code)
                cpu.ip = 0x0100
                cpu:step()
                local label = string.format("0xFF reg %d form %d value %04X",
                    reg, form, value)
                eq(cpu.ip, 0x0100 + #code, label .. " IP")
                local got = (form == 1) and cpu:get_reg16(0)
                    or cpu:read16(DS, 0x0300)
                local want, flags = inc_dec_oracle(value, 16, direction)
                eq(got, want, label .. " result")
                eq(cpu:get_flag("CF"), true, label .. " CF unchanged")
                assert_flags(cpu, flags, label .. " flags")
                cases = cases + 1
            end
        end
    end

    -- CALL near r/m16: pushes the return address; flags unchanged.
    local cpu = new_cpu()
    local before = {CF = true, PF = true, AF = true,
        ZF = true, SF = true, OF = true}
    set_flags(cpu, before)
    cpu:set_reg16(0, 0x1234)
    put(cpu, CS, 0x0100, {0xFF, 0xC0 + 2 * 8})
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.ip, 0x1234, "CALL near target")
    eq(cpu:get_reg16(4), SP - 2, "CALL near SP")
    eq(cpu:read16(SS, SP - 2), 0x0102, "CALL near return address")
    assert_flags_unchanged(cpu, before, "CALL near")
    cases = cases + 1

    -- CALL far m16:16: pushes CS and the return address; flags unchanged.
    cpu = new_cpu()
    before = {CF = true, PF = true, AF = true,
        ZF = true, SF = true, OF = true}
    set_flags(cpu, before)
    cpu:write16(DS, 0x0300, 0x5678)
    cpu:write16(DS, 0x0302, 0x2345)
    put(cpu, CS, 0x0100, {0xFF, 3 * 8 + 6, 0x00, 0x03})
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.seg.cs, 0x2345, "CALL far CS")
    eq(cpu.ip, 0x5678, "CALL far IP")
    eq(cpu:get_reg16(4), SP - 4, "CALL far SP")
    eq(cpu:read16(SS, SP - 4), 0x0104, "CALL far return address")
    eq(cpu:read16(SS, SP - 2), CS, "CALL far saved CS")
    assert_flags_unchanged(cpu, before, "CALL far")
    cases = cases + 1

    -- JMP near r/m16: no stack effect; flags unchanged.
    cpu = new_cpu()
    before = {CF = true, PF = true, AF = true,
        ZF = true, SF = true, OF = true}
    set_flags(cpu, before)
    cpu:set_reg16(0, 0x2345)
    put(cpu, CS, 0x0100, {0xFF, 0xC0 + 4 * 8})
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.ip, 0x2345, "JMP near target")
    eq(cpu:get_reg16(4), SP, "JMP near leaves SP")
    assert_flags_unchanged(cpu, before, "JMP near")
    cases = cases + 1

    -- JMP far m16:16: no stack effect; flags unchanged.
    cpu = new_cpu()
    before = {CF = true, PF = true, AF = true,
        ZF = true, SF = true, OF = true}
    set_flags(cpu, before)
    cpu:write16(DS, 0x0300, 0x3456)
    cpu:write16(DS, 0x0302, 0x2000)
    put(cpu, CS, 0x0100, {0xFF, 5 * 8 + 6, 0x00, 0x03})
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.seg.cs, 0x2000, "JMP far CS")
    eq(cpu.ip, 0x3456, "JMP far IP")
    eq(cpu:get_reg16(4), SP, "JMP far leaves SP")
    assert_flags_unchanged(cpu, before, "JMP far")
    cases = cases + 1

    -- PUSH r/m16: flags unchanged.
    cpu = new_cpu()
    before = {CF = true, PF = true, AF = true,
        ZF = true, SF = true, OF = true}
    set_flags(cpu, before)
    cpu:set_reg16(0, 0x1234)
    put(cpu, CS, 0x0100, {0xFF, 0xC0 + 6 * 8})
    cpu.ip = 0x0100
    cpu:step()
    eq(cpu.ip, 0x0102, "PUSH IP")
    eq(cpu:get_reg16(4), SP - 2, "PUSH SP")
    eq(cpu:read16(SS, SP - 2), 0x1234, "PUSH stack value")
    assert_flags_unchanged(cpu, before, "PUSH")
    cases = cases + 1

    -- reg 7 is illegal; only the diagnostic is asserted.
    cpu = new_cpu()
    put(cpu, CS, 0x0100, {0xFF, 0xC0 + 7 * 8})
    cpu.ip = 0x0100
    expect_error(function()
        cpu:step()
    end, "unimplemented opcode")
    cases = cases + 1

    eq(cases, 18, "0xFF case count")
end)

---------------------------------------------------------------------------
-- Matrix 5: conditional jumps
---------------------------------------------------------------------------

test("Jcc 0x70-0x7F taken/not-taken matrix", function()
    local flag_sets = {
        {CF = false, PF = false, AF = false, ZF = false,
         SF = false, OF = false},
        {CF = true, PF = true, AF = true, ZF = true,
         SF = true, OF = true},
        {CF = false, PF = true, AF = false, ZF = true,
         SF = false, OF = true},
        {CF = true, PF = false, AF = true, ZF = false,
         SF = true, OF = false},
    }
    local cases = 0
    for cc = 0, 15 do
        for fi = 1, #flag_sets do
            local cpu = new_cpu()
            set_flags(cpu, flag_sets[fi])
            local before = snapshot_flags(cpu)
            put(cpu, CS, 0x0100, {0x70 + cc, 0x10})
            cpu.ip = 0x0100
            cpu:step()
            local taken = JCC_CONDITIONS[cc + 1](flag_sets[fi])
            local want = 0x0100 + 2 + (taken and 0x10 or 0)
            eq(cpu.ip, want,
                string.format("Jcc %02X flagset %d IP", 0x70 + cc, fi))
            assert_flags_unchanged(cpu, before,
                string.format("Jcc %02X flagset %d", 0x70 + cc, fi))
            cases = cases + 1
        end
    end
    eq(cases, 64, "Jcc matrix case count")
end)

---------------------------------------------------------------------------

print(string.format(
    "cpu_matrix_test: %d total, %d passed, 0 skipped, %d failed",
    total, passed, failed))

if failed > 0 then
    error(string.format("%d CPU matrix test(s) failed", failed), 0)
end

return true
