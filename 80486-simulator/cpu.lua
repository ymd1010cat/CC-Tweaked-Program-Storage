---------------------------------------------------------------------------
-- 80486-simulator/cpu.lua
--
-- A 16-bit real-mode interpreter for the Intel 80486.
--
-- This module executes real machine code.  Every byte fetched from CS:IP is
-- decoded and executed; an instruction that is not implemented, an I/O port
-- that has no handler, an interrupt vector that has neither a Lua handler nor
-- an IVT entry, and a divide error all raise a Lua error instead of being
-- silently skipped.  Nothing here fabricates a result.
--
-- Target runtime: CraftOS / CraftOS-PC (Lua 5.1).  There are no bitwise
-- operators, no goto and no integer division available, so every bit
-- operation in this file is arithmetic (floor division and modulo).
--
-- Storage model: memory is 16 MiB of sparse paged RAM supplied by memory.lua;
-- I/O is routed through caller supplied port tables; software interrupts are
-- routed through caller supplied handlers or the real IVT at physical 0.
--
-- Public surface used by bios.lua and the tests:
--   Cpu.new(opts)                 opts.memory (required), opts.sleep,
--                                 opts.sleep_interval, opts.clock,
--                                 opts.watchdog_max_tick
--   Cpu.Device                    instance metatable
--   Cpu.SLEEP_INTERVAL            200
--   Cpu.WATCHDOG_SECONDS_PER_TICK 0.05
--   cpu.watchdog_max_tick         -1 disables the watchdog; > 0 arms it
--   cpu.reg[0..7]                 AX CX DX BX SP BP SI DI (32-bit integers)
--   cpu.seg                       { cs =, ds =, es =, ss = }
--   cpu.ip                        instruction pointer (wraps at 0x10000)
--   cpu.flags                     booleans: CF PF AF ZF SF TF IF DF OF
--   cpu.halted, cpu.steps
--   cpu.interrupts                vector -> function(cpu)
--   cpu.ports                     { in = { [port] = fn }, out = { [port] = fn } }
--   cpu:get_reg8 / set_reg8 / get_reg16 / set_reg16
--   cpu:get_sreg / set_sreg / get_flag / set_flag
--   cpu:read8 / read16 / write8 / write16
--   cpu:push16 / pop16 / step / run
--   cpu:jump_far(segment, offset)
--                               far jump; inside a registered interrupt
--                               handler it also suppresses the implicit IRET
--                               so firmware handlers such as INT 19h can take
--                               over control instead of returning
---------------------------------------------------------------------------

local floor = math.floor
local ceil  = math.ceil

local M = {}

local CPU = {}
CPU.__index = CPU

M.Device         = CPU
M.SLEEP_INTERVAL = 200
-- One watchdog tick is 0.05 seconds of wall clock time; [watchdog] max_tick
-- multiplies this.  -1 (the default) disables the watchdog completely and
-- leaves only the instruction-count based sleep(0) yield in CPU:run.
M.WATCHDOG_SECONDS_PER_TICK = 0.05

local BASE8  = 256
local BASE16 = 65536
local BASE32 = 4294967296
local MASK8  = 0xFF
local MASK16 = 0xFFFF

-- Powers of two.  Index 0 .. 32; 2^32 is still exact in a double.
local P2 = {}
for i = 0, 32 do
    P2[i] = 2 ^ i
end

-- Parity of every byte: true when the byte has an even number of 1 bits.
local PARITY = {}
do
    for value = 0, 255 do
        local ones = 0
        local rest = value
        for _ = 1, 8 do
            ones = ones + rest % 2
            rest = floor(rest / 2)
        end
        PARITY[value] = (ones % 2 == 0)
    end
end

-- Nibble truth tables for AND / OR / XOR.  Index is (a * 16 + b), a and b are
-- nibbles.  This is how the file computes bitwise logic without operators.
local AND_NIB, OR_NIB, XOR_NIB = {}, {}, {}
do
    for a = 0, 15 do
        for b = 0, 15 do
            local av, bv = a, b
            local p = 1
            local rav, rov, rxv = 0, 0, 0
            for _ = 1, 4 do
                local x = av % 2
                local y = bv % 2
                if x == 1 and y == 1 then
                    rav = rav + p
                end
                if x == 1 or y == 1 then
                    rov = rov + p
                end
                if x ~= y then
                    rxv = rxv + p
                end
                av = floor(av / 2)
                bv = floor(bv / 2)
                p = p * 2
            end
            local key = a * 16 + b
            AND_NIB[key] = rav
            OR_NIB[key]  = rov
            XOR_NIB[key] = rxv
        end
    end
end

---------------------------------------------------------------------------
-- Small numeric helpers
---------------------------------------------------------------------------

-- Sign extend an 8-bit value.
local function s8(v)
    if v >= 0x80 then
        return v - 256
    end
    return v
end

-- Sign extend a 16-bit value.
local function s16(v)
    if v >= 0x8000 then
        return v - 65536
    end
    return v
end

-- Sign extend a 32-bit value.
local function s32(v)
    if v >= 0x80000000 then
        return v - BASE32
    end
    return v
end

-- Bit `n` (0 = least significant) of `value`, as 0 or 1.
local function bit(value, n)
    return floor(value / P2[n]) % 2
end

local function band(a, b, bits)
    local r, mul = 0, 1
    local nibble_count = (bits == 8) and 2 or 4
    for _ = 1, nibble_count do
        r = r + AND_NIB[(a % 16) * 16 + (b % 16)] * mul
        a = floor(a / 16)
        b = floor(b / 16)
        mul = mul * 16
    end
    return r
end

local function bor(a, b, bits)
    local r, mul = 0, 1
    local nibble_count = (bits == 8) and 2 or 4
    for _ = 1, nibble_count do
        r = r + OR_NIB[(a % 16) * 16 + (b % 16)] * mul
        a = floor(a / 16)
        b = floor(b / 16)
        mul = mul * 16
    end
    return r
end

local function bxor(a, b, bits)
    local r, mul = 0, 1
    local nibble_count = (bits == 8) and 2 or 4
    for _ = 1, nibble_count do
        r = r + XOR_NIB[(a % 16) * 16 + (b % 16)] * mul
        a = floor(a / 16)
        b = floor(b / 16)
        mul = mul * 16
    end
    return r
end

-- Truncating division (rounds toward zero), as required by IDIV.
local function trunc_div(a, b)
    local q = a / b
    if q < 0 then
        q = ceil(q)
    else
        q = floor(q)
    end
    return q, a - q * b
end

---------------------------------------------------------------------------
-- Errors.  CS:IP always refers to the start of the failing instruction.
---------------------------------------------------------------------------

local function raise_unimplemented(self, opcode)
    error(string.format(
        "cpu: unimplemented opcode 0x%02X at CS:IP=%04X:%04X",
        opcode, self._err_cs, self._err_ip), 0)
end

local function raise_divide(self)
    error(string.format(
        "cpu: divide error at CS:IP=%04X:%04X",
        self._err_cs, self._err_ip), 0)
end

local function raise_port(self, port)
    error(string.format(
        "cpu: unmapped I/O port 0x%04X at CS:IP=%04X:%04X",
        port, self._err_cs, self._err_ip), 0)
end

local function raise_interrupt(self, vector)
    error(string.format(
        "cpu: unimplemented interrupt 0x%02X at CS:IP=%04X:%04X",
        vector, self._err_cs, self._err_ip), 0)
end

local function raise_bad_argument(where, message)
    error("cpu: " .. where .. ": " .. message, 0)
end

---------------------------------------------------------------------------
-- Flags
---------------------------------------------------------------------------

local function update_szp(self, result, bits)
    local f = self.flags
    local sign = (bits == 8) and 0x80 or 0x8000
    f.ZF = (result == 0)
    f.SF = (result >= sign)
    f.PF = PARITY[result % 256]
end

local function pack_flags(self)
    local f = self.flags
    local v = 0
    if f.CF then v = v + 1 end
    if f.PF then v = v + 4 end
    if f.AF then v = v + 16 end
    if f.ZF then v = v + 64 end
    if f.SF then v = v + 128 end
    if f.TF then v = v + 256 end
    if f.IF then v = v + 512 end
    if f.DF then v = v + 1024 end
    if f.OF then v = v + 2048 end
    -- Bit 1 is always set in the value pushed by PUSHF.
    return v + 2
end

local function unpack_flags(self, v)
    local f = self.flags
    f.CF = (v % 2 == 1)
    f.PF = (floor(v / 4) % 2 == 1)
    f.AF = (floor(v / 16) % 2 == 1)
    f.ZF = (floor(v / 64) % 2 == 1)
    f.SF = (floor(v / 128) % 2 == 1)
    f.TF = (floor(v / 256) % 2 == 1)
    f.IF = (floor(v / 512) % 2 == 1)
    f.DF = (floor(v / 1024) % 2 == 1)
    f.OF = (floor(v / 2048) % 2 == 1)
end

---------------------------------------------------------------------------
-- Arithmetic / logic operations
--
--   op 0 = ADD, 1 = OR, 2 = ADC, 3 = SBB, 4 = AND, 5 = SUB, 6 = XOR, 7 = CMP
--
-- The result is returned masked to `bits`; CMP only sets flags, the caller
-- decides whether to write the result back.
---------------------------------------------------------------------------

local function alu_op(self, op, a, b, bits)
    local f = self.flags
    local mask, sign
    if bits == 8 then
        mask = MASK8
        sign = 0x80
    else
        mask = MASK16
        sign = 0x8000
    end
    local result

    if op == 0 or op == 2 then
        local carry_in = 0
        if op == 2 and f.CF then
            carry_in = 1
        end
        local total = a + b + carry_in
        result = total % (mask + 1)
        f.CF = (total > mask)
        f.AF = ((a % 16) + (b % 16) + carry_in) > 15
        local sign_a = (a >= sign)
        f.OF = (sign_a == (b >= sign)) and ((result >= sign) ~= sign_a)
        update_szp(self, result, bits)
    elseif op == 5 or op == 7 or op == 3 then
        local carry_in = 0
        if op == 3 and f.CF then
            carry_in = 1
        end
        local diff = a - b - carry_in
        result = diff % (mask + 1)
        f.CF = (diff < 0)
        f.AF = ((a % 16) < ((b % 16) + carry_in))
        local sign_a = (a >= sign)
        f.OF = (sign_a ~= (b >= sign)) and ((result >= sign) ~= sign_a)
        update_szp(self, result, bits)
    else
        if op == 1 then
            result = bor(a, b, bits)
        elseif op == 4 then
            result = band(a, b, bits)
        else
            result = bxor(a, b, bits)
        end
        f.CF = false
        f.OF = false
        update_szp(self, result, bits)
    end

    return result
end

-- INC / DEC.  CF is deliberately left untouched.
local function inc_dec(self, value, bits, direction)
    local mask = (bits == 8) and MASK8 or MASK16
    local sign = (bits == 8) and 0x80 or 0x8000
    local f = self.flags
    local result
    if direction > 0 then
        result = (value + 1) % (mask + 1)
        f.OF = (value == sign - 1)
        f.AF = (value % 16 == 15)
    else
        result = (value - 1) % (mask + 1)
        f.OF = (value == sign)
        f.AF = (value % 16 == 0)
    end
    update_szp(self, result, bits)
    return result
end

-- Rotate helpers.  `width` bits, count 1 .. width - 1.
local function rotate_left(v, n, width)
    local cut = P2[width - n]
    return (v % cut) * P2[n] + floor(v / cut)
end

local function rotate_right(v, n, width)
    return floor(v / P2[n]) + (v % P2[n]) * P2[width - n]
end

-- Shift / rotate.  op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SAL, 7 SAR.
-- A masked count of zero leaves the flags completely untouched.
local function shift_rotate(self, op, value, count, bits)
    local f = self.flags
    local cnt = count % 32
    if cnt == 0 then
        return value
    end

    local size = (bits == 8) and 256 or 65536
    local sign = (bits == 8) and 0x80 or 0x8000
    local n = cnt % bits

    if op == 0 then -- ROL
        if n == 0 then
            f.CF = (value >= sign)
            return value
        end
        local r = rotate_left(value, n, bits)
        f.CF = (r % 2 == 1)
        f.OF = ((r >= sign) ~= f.CF)
        return r
    elseif op == 1 then -- ROR
        if n == 0 then
            f.CF = (value % 2 == 1)
            return value
        end
        local r = rotate_right(value, n, bits)
        f.CF = (r >= sign)
        f.OF = ((r >= sign) ~= (bit(r, bits - 2) == 1))
        return r
    elseif op == 2 then -- RCL
        if n == 0 then
            return value
        end
        local tmp = value + (f.CF and size or 0)
        local r9 = rotate_left(tmp, n, bits + 1)
        f.CF = (r9 >= size)
        local r = r9 % size
        f.OF = ((r >= sign) ~= f.CF)
        return r
    elseif op == 3 then -- RCR
        if n == 0 then
            return value
        end
        local tmp = value + (f.CF and size or 0)
        local r9 = rotate_right(tmp, n, bits + 1)
        f.CF = (r9 >= size)
        local r = r9 % size
        f.OF = ((r >= sign) ~= (bit(r, bits - 2) == 1))
        return r
    elseif op == 4 or op == 6 then -- SHL / SAL
        local r = (value * P2[n]) % size
        f.CF = (bit(value, bits - n) == 1)
        f.OF = ((r >= sign) ~= f.CF)
        update_szp(self, r, bits)
        return r
    elseif op == 5 then -- SHR
        local r = floor(value / P2[n])
        f.CF = (bit(value, n - 1) == 1)
        f.OF = (value >= sign)
        update_szp(self, r, bits)
        return r
    else -- SAR
        local signed = (value >= sign) and (value - size) or value
        local r = floor(signed / P2[n]) % size
        f.CF = (bit(value, n - 1) == 1)
        f.OF = false
        update_szp(self, r, bits)
        return r
    end
end

---------------------------------------------------------------------------
-- Multiply / divide
---------------------------------------------------------------------------

local function do_mul(self, value, bits)
    local f = self.flags
    if bits == 8 then
        local product = self:get_reg8(0) * value
        self:set_reg16(0, product % BASE16)
        f.CF = (product > 255)
        f.OF = f.CF
    else
        local product = self:get_reg16(0) * value
        self:set_reg16(0, product % BASE16)
        self:set_reg16(2, floor(product / BASE16) % BASE16)
        f.CF = (product >= BASE16)
        f.OF = f.CF
    end
end

local function do_imul(self, value, bits)
    local f = self.flags
    if bits == 8 then
        local product = s8(self:get_reg8(0)) * s8(value)
        self:set_reg16(0, product % BASE16)
        f.CF = (product < -128 or product > 127)
        f.OF = f.CF
    else
        local product = s16(self:get_reg16(0)) * s16(value)
        self:set_reg16(0, product % BASE16)
        self:set_reg16(2, floor(product / BASE16) % BASE16)
        f.CF = (product < -32768 or product > 32767)
        f.OF = f.CF
    end
end

local function do_div(self, value, bits)
    if value == 0 then
        raise_divide(self)
    end
    if bits == 8 then
        local dividend = self:get_reg16(0)
        local q = floor(dividend / value)
        if q > 255 then
            raise_divide(self)
        end
        self:set_reg8(0, q)
        self:set_reg8(4, dividend % value)
    else
        local dividend = self:get_reg16(2) * BASE16 + self:get_reg16(0)
        local q = floor(dividend / value)
        if q > 65535 then
            raise_divide(self)
        end
        self:set_reg16(0, q)
        self:set_reg16(2, dividend % value)
    end
end

local function do_idiv(self, value, bits)
    if value == 0 then
        raise_divide(self)
    end
    if bits == 8 then
        local dividend = s16(self:get_reg16(0))
        local divisor = s8(value)
        if divisor == 0 then
            raise_divide(self)
        end
        local q, r = trunc_div(dividend, divisor)
        if q < -128 or q > 127 then
            raise_divide(self)
        end
        self:set_reg8(0, q % 256)
        self:set_reg8(4, r % 256)
    else
        local dividend = s32(self:get_reg16(2) * BASE16 + self:get_reg16(0))
        local divisor = s16(value)
        if divisor == 0 then
            raise_divide(self)
        end
        local q, r = trunc_div(dividend, divisor)
        if q < -32768 or q > 32767 then
            raise_divide(self)
        end
        self:set_reg16(0, q % BASE16)
        self:set_reg16(2, r % BASE16)
    end
end

---------------------------------------------------------------------------
-- Instruction stream access
---------------------------------------------------------------------------

local function fetch8(self, ip)
    local b = self.memory:read8(self.seg.cs * 16 + ip)
    return b, (ip + 1) % BASE16
end

local function fetch16(self, ip)
    local base = self.seg.cs * 16 + ip
    local low = self.memory:read8(base)
    local high = self.memory:read8(base + 1)
    return low + high * 256, (ip + 2) % BASE16
end

-- Decode a ModR/M byte (and its displacement).
--
-- Returns:
--   reg      the raw 3-bit reg field (0..7)
--   rm       the raw 3-bit r/m register when mod == 3, otherwise nil
--   addr     the linear address of the memory operand when mod ~= 3
--   new_ip   the instruction pointer after the ModR/M bytes
--   offset   the 16-bit effective address (segment offset) when mod ~= 3;
--            nil for register operands.  LEA needs this value because the
--            linear address alone cannot recover it once a high segment
--            (>= 0x10000 / 16) has been added.
--
-- `seg_override` is the segment register named by a prefix ("es", "cs",
-- "ss", "ds") or nil.
local function decode_modrm(self, ip, seg_override)
    local modrm
    modrm, ip = fetch8(self, ip)

    local mod = floor(modrm / 64)
    local reg = floor(modrm / 8) % 8
    local rm  = modrm % 8

    if mod == 3 then
        return reg, rm, nil, ip, nil
    end

    local offset
    local default_seg

    if rm == 0 then
        offset = self:get_reg16(3) + self:get_reg16(6) -- BX + SI
        default_seg = "ds"
    elseif rm == 1 then
        offset = self:get_reg16(3) + self:get_reg16(7) -- BX + DI
        default_seg = "ds"
    elseif rm == 2 then
        offset = self:get_reg16(5) + self:get_reg16(6) -- BP + SI
        default_seg = "ss"
    elseif rm == 3 then
        offset = self:get_reg16(5) + self:get_reg16(7) -- BP + DI
        default_seg = "ss"
    elseif rm == 4 then
        offset = self:get_reg16(6) -- SI
        default_seg = "ds"
    elseif rm == 5 then
        offset = self:get_reg16(7) -- DI
        default_seg = "ds"
    elseif rm == 6 then
        if mod == 0 then
            -- Direct 16-bit displacement, DS relative (or the override).
            local direct
            direct, ip = fetch16(self, ip)
            local base = self.seg[seg_override or "ds"] * 16
            return reg, nil, base + direct, ip, direct
        end
        offset = self:get_reg16(5) -- BP
        default_seg = "ss"
    else
        offset = self:get_reg16(3) -- BX
        default_seg = "ds"
    end

    if mod == 1 then
        local disp
        disp, ip = fetch8(self, ip)
        offset = offset + s8(disp)
    elseif mod == 2 then
        local disp
        disp, ip = fetch16(self, ip)
        offset = offset + disp
    end

    offset = offset % BASE16
    local base = self.seg[seg_override or default_seg] * 16
    return reg, nil, base + offset, ip, offset
end

---------------------------------------------------------------------------
-- Operand access
---------------------------------------------------------------------------

local function read_rm8(self, rm, addr)
    if addr ~= nil then
        return self.memory:read8(addr)
    end
    return self:get_reg8(rm)
end

local function read_rm16(self, rm, addr)
    if addr ~= nil then
        return self.memory:read16(addr)
    end
    return self:get_reg16(rm)
end

local function write_rm8(self, rm, addr, value)
    if addr ~= nil then
        self.memory:write8(addr, value % 256)
    else
        self:set_reg8(rm, value)
    end
end

local function write_rm16(self, rm, addr, value)
    if addr ~= nil then
        self.memory:write16(addr, value % BASE16)
    else
        self:set_reg16(rm, value)
    end
end

-- Read a byte / word from the code segment (displacement operands).
local function read_code8(self, ip)
    return self.memory:read8(self.seg.cs * 16 + ip)
end

local function read_code16(self, ip)
    local base = self.seg.cs * 16 + ip
    return self.memory:read16(base)
end

---------------------------------------------------------------------------
-- Ports
---------------------------------------------------------------------------

local function port_in(self, port, size)
    local fn = self.ports["in"][port]
    if type(fn) ~= "function" then
        raise_port(self, port)
    end
    local value = fn(self, size)
    if type(value) ~= "number" then
        raise_bad_argument("port handler", string.format(
            "IN port 0x%04X returned %s", port, tostring(value)))
    end
    return value
end

local function port_out(self, port, size, value)
    local fn = self.ports.out[port]
    if type(fn) ~= "function" then
        raise_port(self, port)
    end
    fn(self, size, value)
end

---------------------------------------------------------------------------
-- Software interrupts
---------------------------------------------------------------------------

-- Push FLAGS, CS and the return IP, disable IF/TF, then either call the
-- registered Lua handler (and perform the IRET the handler implies) or jump
-- through the real interrupt vector table.  On return `self.ip` holds the
-- next instruction to execute.
--
-- Real interrupt handlers hand their result back by editing the FLAGS image
-- (that is how a BIOS reports CF = 1, for example).  A Lua handler does the
-- same through cpu:set_flag, so the flags it touches are remembered and
-- re-applied after the implicit IRET has restored the untouched ones from
-- the stack.  The IVT dispatch path is unchanged.
--
-- A handler may also take over control completely by calling
-- cpu:jump_far(cs, ip) -- INT 19h does this after loading the boot sector.
-- In that case the implicit IRET is suppressed and the pushed frame is left
-- on the stack, which is what real firmware does (boot code installs its own
-- stack before it needs one).
local function do_interrupt(self, vector, return_ip)
    local f = self.flags
    self:push16(pack_flags(self))
    self:push16(self.seg.cs)
    self:push16(return_ip)
    f.IF = false
    f.TF = false

    local handler = self.interrupts[vector]
    if type(handler) == "function" then
        self._flag_overrides = {}
        self._handler_jumped = false
        self._in_handler = true
        local ok, handler_error = pcall(handler, self)
        self._in_handler = false
        if not ok then
            self._flag_overrides = {}
            self._handler_jumped = false
            error(handler_error, 0)
        end

        if self._handler_jumped then
            -- The handler chose a new CS:IP and never returns (INT 19h).
            self._handler_jumped = false
            return
        end

        local ip  = self:pop16()
        local cs  = self:pop16()
        local fl  = self:pop16()
        self.seg.cs = cs % BASE16
        self.ip     = ip % BASE16
        unpack_flags(self, fl)

        local overrides = self._flag_overrides
        self._flag_overrides = {}
        for name, value in pairs(overrides) do
            self.flags[name] = value
        end
        return
    end

    local offset = self:read16(0, vector * 4)
    local segment = self:read16(0, vector * 4 + 2)
    if offset == 0 and segment == 0 then
        raise_interrupt(self, vector)
    end
    self.seg.cs = segment % BASE16
    self.ip     = offset % BASE16
end

---------------------------------------------------------------------------
-- String instructions
--
-- A REP/REPNE prefixed string instruction executes exactly one iteration per
-- step().  CX is decremented after the iteration; if the repeat condition
-- still holds the IP is rewound to the start of the instruction (prefixes
-- included) so the next step() continues the repetition.
---------------------------------------------------------------------------

local function string_source_base(self)
    return self.seg[self._seg or "ds"] * 16
end

local function string_delta(self, bits)
    local delta = bits / 8
    if self.flags.DF then
        return -delta
    end
    return delta
end

local function string_movs(self, bits)
    local src = string_source_base(self)
    local dst = self.seg.es * 16
    local si  = self:get_reg16(6)
    local di  = self:get_reg16(7)
    if bits == 8 then
        self.memory:write8(dst + di, self.memory:read8(src + si))
    else
        self.memory:write16(dst + di, self.memory:read16(src + si))
    end
    local delta = string_delta(self, bits)
    self:set_reg16(6, (si + delta) % BASE16)
    self:set_reg16(7, (di + delta) % BASE16)
end

local function string_cmps(self, bits)
    local src = string_source_base(self)
    local dst = self.seg.es * 16
    local si  = self:get_reg16(6)
    local di  = self:get_reg16(7)
    local a, b
    if bits == 8 then
        a = self.memory:read8(src + si)
        b = self.memory:read8(dst + di)
    else
        a = self.memory:read16(src + si)
        b = self.memory:read16(dst + di)
    end
    alu_op(self, 5, a, b, bits)
    local delta = string_delta(self, bits)
    self:set_reg16(6, (si + delta) % BASE16)
    self:set_reg16(7, (di + delta) % BASE16)
end

local function string_stos(self, bits)
    local dst = self.seg.es * 16
    local di  = self:get_reg16(7)
    if bits == 8 then
        self.memory:write8(dst + di, self:get_reg8(0))
    else
        self.memory:write16(dst + di, self:get_reg16(0))
    end
    self:set_reg16(7, (di + string_delta(self, bits)) % BASE16)
end

local function string_lods(self, bits)
    local src = string_source_base(self)
    local si  = self:get_reg16(6)
    if bits == 8 then
        self:set_reg8(0, self.memory:read8(src + si))
    else
        self:set_reg16(0, self.memory:read16(src + si))
    end
    self:set_reg16(6, (si + string_delta(self, bits)) % BASE16)
end

local function string_scas(self, bits)
    local dst = self.seg.es * 16
    local di  = self:get_reg16(7)
    local a, b
    if bits == 8 then
        a = self:get_reg8(0)
        b = self.memory:read8(dst + di)
    else
        a = self:get_reg16(0)
        b = self.memory:read16(dst + di)
    end
    alu_op(self, 5, a, b, bits)
    self:set_reg16(7, (di + string_delta(self, bits)) % BASE16)
end

---------------------------------------------------------------------------
-- Decoder tables
---------------------------------------------------------------------------

local handlers = {}

local function def(opcode, fn)
    handlers[opcode] = fn
end

-- ALU family 0x00 .. 0x3D (the 16 segment push/pop opcodes in that range are
-- defined separately below and are not overwritten).
local ALU_OPS = {
    [0] = 0, -- ADD
    [1] = 1, -- OR
    [2] = 2, -- ADC
    [3] = 3, -- SBB
    [4] = 4, -- AND
    [5] = 5, -- SUB
    [6] = 6, -- XOR
    [7] = 7, -- CMP
}

for group = 0, 7 do
    local base  = group * 8
    local aluop = ALU_OPS[group]

    -- r/m8, r8
    def(base + 0, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local result = alu_op(self, aluop, read_rm8(self, rm, addr),
            self:get_reg8(reg), 8)
        if aluop ~= 7 then
            write_rm8(self, rm, addr, result)
        end
        return nip
    end)

    -- r/m16, r16
    def(base + 1, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local result = alu_op(self, aluop, read_rm16(self, rm, addr),
            self:get_reg16(reg), 16)
        if aluop ~= 7 then
            write_rm16(self, rm, addr, result)
        end
        return nip
    end)

    -- r8, r/m8
    def(base + 2, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local result = alu_op(self, aluop, self:get_reg8(reg),
            read_rm8(self, rm, addr), 8)
        if aluop ~= 7 then
            self:set_reg8(reg, result)
        end
        return nip
    end)

    -- r16, r/m16
    def(base + 3, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local result = alu_op(self, aluop, self:get_reg16(reg),
            read_rm16(self, rm, addr), 16)
        if aluop ~= 7 then
            self:set_reg16(reg, result)
        end
        return nip
    end)

    -- AL, imm8
    def(base + 4, function(self, ip)
        local imm, nip = fetch8(self, ip)
        local result = alu_op(self, aluop, self:get_reg8(0), imm, 8)
        if aluop ~= 7 then
            self:set_reg8(0, result)
        end
        return nip
    end)

    -- AX, imm16
    def(base + 5, function(self, ip)
        local imm, nip = fetch16(self, ip)
        local result = alu_op(self, aluop, self:get_reg16(0), imm, 16)
        if aluop ~= 7 then
            self:set_reg16(0, result)
        end
        return nip
    end)
end

---------------------------------------------------------------------------
-- MOV
---------------------------------------------------------------------------

def(0x88, function(self, ip, seg) -- MOV r/m8, r8
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    write_rm8(self, rm, addr, self:get_reg8(reg))
    return nip
end)

def(0x89, function(self, ip, seg) -- MOV r/m16, r16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    write_rm16(self, rm, addr, self:get_reg16(reg))
    return nip
end)

def(0x8A, function(self, ip, seg) -- MOV r8, r/m8
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    self:set_reg8(reg, read_rm8(self, rm, addr))
    return nip
end)

def(0x8B, function(self, ip, seg) -- MOV r16, r/m16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    self:set_reg16(reg, read_rm16(self, rm, addr))
    return nip
end)

def(0x8D, function(self, ip, seg) -- LEA r16, m
    local reg, rm, _, nip, offset = decode_modrm(self, ip, seg)
    if offset == nil then
        -- ModR/M form with mod=3 is not a valid LEA encoding.  The 80186+
        -- treats it as MOV r16, r/m16, so do the same instead of inventing
        -- an address; nothing is silently skipped.
        self:set_reg16(reg, self:get_reg16(rm))
        return nip
    end
    self:set_reg16(reg, offset % BASE16)
    return nip
end)

local SREG_NAMES = { "es", "cs", "ss", "ds" }

def(0x8C, function(self, ip, seg) -- MOV r/m16, Sreg
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local name = SREG_NAMES[reg + 1]
    if name == nil then
        raise_unimplemented(self, 0x8C)
    end
    write_rm16(self, rm, addr, self.seg[name])
    return nip
end)

def(0x8E, function(self, ip, seg) -- MOV Sreg, r/m16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local name = SREG_NAMES[reg + 1]
    if name == nil then
        raise_unimplemented(self, 0x8E)
    end
    self.seg[name] = read_rm16(self, rm, addr) % BASE16
    return nip
end)

def(0xA0, function(self, ip, seg) -- MOV AL, moffs8
    local offset, nip = fetch16(self, ip)
    self:set_reg8(0, self:read8(self.seg[seg or "ds"], offset))
    return nip
end)

def(0xA1, function(self, ip, seg) -- MOV AX, moffs16
    local offset, nip = fetch16(self, ip)
    self:set_reg16(0, self:read16(self.seg[seg or "ds"], offset))
    return nip
end)

def(0xA2, function(self, ip, seg) -- MOV moffs8, AL
    local offset, nip = fetch16(self, ip)
    self:write8(self.seg[seg or "ds"], offset, self:get_reg8(0))
    return nip
end)

def(0xA3, function(self, ip, seg) -- MOV moffs16, AX
    local offset, nip = fetch16(self, ip)
    self:write16(self.seg[seg or "ds"], offset, self:get_reg16(0))
    return nip
end)

for i = 0, 7 do
    def(0xB0 + i, function(self, ip) -- MOV r8, imm8
        local imm, nip = fetch8(self, ip)
        self:set_reg8(i, imm)
        return nip
    end)

    def(0xB8 + i, function(self, ip) -- MOV r16, imm16
        local imm, nip = fetch16(self, ip)
        self:set_reg16(i, imm)
        return nip
    end)
end

def(0xC6, function(self, ip, seg) -- MOV r/m8, imm8
    local _, rm, addr, nip = decode_modrm(self, ip, seg)
    local imm
    imm, nip = fetch8(self, nip)
    write_rm8(self, rm, addr, imm)
    return nip
end)

def(0xC7, function(self, ip, seg) -- MOV r/m16, imm16
    local _, rm, addr, nip = decode_modrm(self, ip, seg)
    local imm
    imm, nip = fetch16(self, nip)
    write_rm16(self, rm, addr, imm)
    return nip
end)

def(0x8F, function(self, ip, seg) -- POP r/m16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    if reg ~= 0 then
        raise_unimplemented(self, 0x8F)
    end
    write_rm16(self, rm, addr, self:pop16())
    return nip
end)

def(0xC4, function(self, ip, seg) -- LES r16, m16:16
    local reg, _, addr, nip = decode_modrm(self, ip, seg)
    if addr == nil then
        raise_unimplemented(self, 0xC4)
    end
    self:set_reg16(reg, self.memory:read16(addr))
    self.seg.es = self.memory:read16(addr + 2)
    return nip
end)

def(0xC5, function(self, ip, seg) -- LDS r16, m16:16
    local reg, _, addr, nip = decode_modrm(self, ip, seg)
    if addr == nil then
        raise_unimplemented(self, 0xC5)
    end
    self:set_reg16(reg, self.memory:read16(addr))
    self.seg.ds = self.memory:read16(addr + 2)
    return nip
end)

---------------------------------------------------------------------------
-- Group 1 (0x80 / 0x81 / 0x82 / 0x83): ALU r/m, immediate
---------------------------------------------------------------------------

local function def_group1(opcode, bits, immediate_bits)
    def(opcode, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local immediate
        if immediate_bits == 8 then
            immediate, nip = fetch8(self, nip)
        else
            immediate, nip = fetch16(self, nip)
        end
        if bits == 16 and immediate_bits == 8 then
            immediate = s8(immediate) % BASE16
        end
        local value
        if bits == 8 then
            value = read_rm8(self, rm, addr)
        else
            value = read_rm16(self, rm, addr)
        end
        local result = alu_op(self, reg, value, immediate, bits)
        if reg ~= 7 then
            if bits == 8 then
                write_rm8(self, rm, addr, result)
            else
                write_rm16(self, rm, addr, result)
            end
        end
        return nip
    end)
end

def_group1(0x80, 8, 8)
def_group1(0x81, 16, 16)
def_group1(0x82, 8, 8)
def_group1(0x83, 16, 8)

---------------------------------------------------------------------------
-- TEST
---------------------------------------------------------------------------

def(0x84, function(self, ip, seg) -- TEST r/m8, r8
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    alu_op(self, 4, read_rm8(self, rm, addr), self:get_reg8(reg), 8)
    return nip
end)

def(0x85, function(self, ip, seg) -- TEST r/m16, r16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    alu_op(self, 4, read_rm16(self, rm, addr), self:get_reg16(reg), 16)
    return nip
end)

def(0xA8, function(self, ip) -- TEST AL, imm8
    local imm, nip = fetch8(self, ip)
    alu_op(self, 4, self:get_reg8(0), imm, 8)
    return nip
end)

def(0xA9, function(self, ip) -- TEST AX, imm16
    local imm, nip = fetch16(self, ip)
    alu_op(self, 4, self:get_reg16(0), imm, 16)
    return nip
end)

---------------------------------------------------------------------------
-- XCHG
---------------------------------------------------------------------------

def(0x86, function(self, ip, seg) -- XCHG r/m8, r8
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local other = read_rm8(self, rm, addr)
    local value = self:get_reg8(reg)
    write_rm8(self, rm, addr, value)
    self:set_reg8(reg, other)
    return nip
end)

def(0x87, function(self, ip, seg) -- XCHG r/m16, r16
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local other = read_rm16(self, rm, addr)
    local value = self:get_reg16(reg)
    write_rm16(self, rm, addr, value)
    self:set_reg16(reg, other)
    return nip
end)

---------------------------------------------------------------------------
-- PUSH / POP
---------------------------------------------------------------------------

for i = 0, 7 do
    def(0x50 + i, function(self, ip) -- PUSH r16
        self:push16(self:get_reg16(i))
        return ip
    end)

    def(0x58 + i, function(self, ip) -- POP r16
        self:set_reg16(i, self:pop16())
        return ip
    end)

    def(0x40 + i, function(self, ip) -- INC r16
        self:set_reg16(i, inc_dec(self, self:get_reg16(i), 16, 1))
        return ip
    end)

    def(0x48 + i, function(self, ip) -- DEC r16
        self:set_reg16(i, inc_dec(self, self:get_reg16(i), 16, -1))
        return ip
    end)
end

def(0x06, function(self, ip) -- PUSH ES
    self:push16(self.seg.es)
    return ip
end)

def(0x07, function(self, ip) -- POP ES
    self.seg.es = self:pop16()
    return ip
end)

def(0x0E, function(self, ip) -- PUSH CS
    self:push16(self.seg.cs)
    return ip
end)

def(0x16, function(self, ip) -- PUSH SS
    self:push16(self.seg.ss)
    return ip
end)

def(0x17, function(self, ip) -- POP SS
    self.seg.ss = self:pop16()
    return ip
end)

def(0x1E, function(self, ip) -- PUSH DS
    self:push16(self.seg.ds)
    return ip
end)

def(0x1F, function(self, ip) -- POP DS
    self.seg.ds = self:pop16()
    return ip
end)

def(0x60, function(self, ip) -- PUSHA
    local sp = self:get_reg16(4)
    self:push16(self:get_reg16(0))
    self:push16(self:get_reg16(1))
    self:push16(self:get_reg16(2))
    self:push16(self:get_reg16(3))
    self:push16(sp)
    self:push16(self:get_reg16(5))
    self:push16(self:get_reg16(6))
    self:push16(self:get_reg16(7))
    return ip
end)

def(0x61, function(self, ip) -- POPA (the saved SP is discarded)
    self:set_reg16(7, self:pop16())
    self:set_reg16(6, self:pop16())
    self:set_reg16(5, self:pop16())
    self:pop16()
    self:set_reg16(3, self:pop16())
    self:set_reg16(2, self:pop16())
    self:set_reg16(1, self:pop16())
    self:set_reg16(0, self:pop16())
    return ip
end)

def(0x68, function(self, ip) -- PUSH imm16
    local imm, nip = fetch16(self, ip)
    self:push16(imm)
    return nip
end)

def(0x6A, function(self, ip) -- PUSH imm8 (sign extended)
    local imm, nip = fetch8(self, ip)
    self:push16(s8(imm) % BASE16)
    return nip
end)

def(0x9C, function(self, ip) -- PUSHF
    self:push16(pack_flags(self))
    return ip
end)

def(0x9D, function(self, ip) -- POPF
    unpack_flags(self, self:pop16())
    return ip
end)

---------------------------------------------------------------------------
-- Jcc (all sixteen condition codes)
---------------------------------------------------------------------------

local CONDITIONS = {
    function(f) return f.OF end,                        -- 0x70 JO
    function(f) return not f.OF end,                    -- 0x71 JNO
    function(f) return f.CF end,                        -- 0x72 JB
    function(f) return not f.CF end,                    -- 0x73 JAE
    function(f) return f.ZF end,                        -- 0x74 JE
    function(f) return not f.ZF end,                    -- 0x75 JNE
    function(f) return f.CF or f.ZF end,                -- 0x76 JBE
    function(f) return not f.CF and not f.ZF end,       -- 0x77 JA
    function(f) return f.SF end,                        -- 0x78 JS
    function(f) return not f.SF end,                    -- 0x79 JNS
    function(f) return f.PF end,                        -- 0x7A JP
    function(f) return not f.PF end,                    -- 0x7B JNP
    function(f) return f.SF ~= f.OF end,                -- 0x7C JL
    function(f) return f.SF == f.OF end,                -- 0x7D JGE
    function(f) return f.ZF or (f.SF ~= f.OF) end,      -- 0x7E JLE
    function(f) return not f.ZF and f.SF == f.OF end,   -- 0x7F JG
}

for cc = 0, 15 do
    local condition = CONDITIONS[cc + 1]
    def(0x70 + cc, function(self, ip)
        local disp, nip = fetch8(self, ip)
        if condition(self.flags) then
            nip = (nip + s8(disp)) % BASE16
        end
        return nip
    end)
end

---------------------------------------------------------------------------
-- LOOP / LOOPE / LOOPNE / JCXZ
---------------------------------------------------------------------------

def(0xE0, function(self, ip) -- LOOPNE
    local disp, nip = fetch8(self, ip)
    local cx = (self:get_reg16(1) - 1) % BASE16
    self:set_reg16(1, cx)
    if cx ~= 0 and not self.flags.ZF then
        nip = (nip + s8(disp)) % BASE16
    end
    return nip
end)

def(0xE1, function(self, ip) -- LOOPE
    local disp, nip = fetch8(self, ip)
    local cx = (self:get_reg16(1) - 1) % BASE16
    self:set_reg16(1, cx)
    if cx ~= 0 and self.flags.ZF then
        nip = (nip + s8(disp)) % BASE16
    end
    return nip
end)

def(0xE2, function(self, ip) -- LOOP
    local disp, nip = fetch8(self, ip)
    local cx = (self:get_reg16(1) - 1) % BASE16
    self:set_reg16(1, cx)
    if cx ~= 0 then
        nip = (nip + s8(disp)) % BASE16
    end
    return nip
end)

def(0xE3, function(self, ip) -- JCXZ
    local disp, nip = fetch8(self, ip)
    if self:get_reg16(1) == 0 then
        nip = (nip + s8(disp)) % BASE16
    end
    return nip
end)

---------------------------------------------------------------------------
-- JMP / CALL / RET
---------------------------------------------------------------------------

def(0xEB, function(self, ip) -- JMP rel8
    local disp, nip = fetch8(self, ip)
    return (nip + s8(disp)) % BASE16
end)

def(0xE9, function(self, ip) -- JMP rel16
    local disp, nip = fetch16(self, ip)
    return (nip + s16(disp)) % BASE16
end)

def(0xEA, function(self, ip) -- JMP ptr16:16
    local offset, nip = fetch16(self, ip)
    local segment
    segment, nip = fetch16(self, nip)
    self.seg.cs = segment % BASE16
    return offset % BASE16
end)

def(0xE8, function(self, ip) -- CALL rel16
    local disp, nip = fetch16(self, ip)
    self:push16(nip)
    return (nip + s16(disp)) % BASE16
end)

def(0x9A, function(self, ip) -- CALL ptr16:16
    local offset, nip = fetch16(self, ip)
    local segment
    segment, nip = fetch16(self, nip)
    self:push16(self.seg.cs)
    self:push16(nip)
    self.seg.cs = segment % BASE16
    return offset % BASE16
end)

def(0xC3, function(self, ip) -- RET
    return self:pop16()
end)

def(0xC2, function(self, ip) -- RET imm16
    local imm
    imm, ip = fetch16(self, ip)
    local target = self:pop16()
    self:set_reg16(4, (self:get_reg16(4) + imm) % BASE16)
    return target
end)

def(0xCB, function(self, ip) -- RETF
    local target = self:pop16()
    self.seg.cs = self:pop16()
    return target
end)

def(0xCA, function(self, ip) -- RETF imm16
    local imm
    imm, ip = fetch16(self, ip)
    local target = self:pop16()
    self.seg.cs = self:pop16()
    self:set_reg16(4, (self:get_reg16(4) + imm) % BASE16)
    return target
end)

---------------------------------------------------------------------------
-- Group 4 / 5 (0xFE / 0xFF)
---------------------------------------------------------------------------

def(0xFE, function(self, ip, seg)
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local value = read_rm8(self, rm, addr)
    if reg == 0 then
        write_rm8(self, rm, addr, inc_dec(self, value, 8, 1))
    elseif reg == 1 then
        write_rm8(self, rm, addr, inc_dec(self, value, 8, -1))
    else
        raise_unimplemented(self, 0xFE)
    end
    return nip
end)

def(0xFF, function(self, ip, seg)
    local reg, rm, addr, nip = decode_modrm(self, ip, seg)
    local value = read_rm16(self, rm, addr)
    if reg == 0 then
        write_rm16(self, rm, addr, inc_dec(self, value, 16, 1))
    elseif reg == 1 then
        write_rm16(self, rm, addr, inc_dec(self, value, 16, -1))
    elseif reg == 2 then -- CALL near r/m16
        self:push16(nip)
        return value % BASE16
    elseif reg == 3 then -- CALL far m16:16
        if addr == nil then
            raise_unimplemented(self, 0xFF)
        end
        local offset = self.memory:read16(addr)
        local segment = self.memory:read16(addr + 2)
        self:push16(self.seg.cs)
        self:push16(nip)
        self.seg.cs = segment % BASE16
        return offset % BASE16
    elseif reg == 4 then -- JMP near r/m16
        return value % BASE16
    elseif reg == 5 then -- JMP far m16:16
        if addr == nil then
            raise_unimplemented(self, 0xFF)
        end
        local offset = self.memory:read16(addr)
        local segment = self.memory:read16(addr + 2)
        self.seg.cs = segment % BASE16
        return offset % BASE16
    elseif reg == 6 then -- PUSH r/m16
        self:push16(value)
        return nip
    else
        raise_unimplemented(self, 0xFF)
    end
end)

---------------------------------------------------------------------------
-- Shift / rotate group (0xC0 / 0xC1 / 0xD0 / 0xD1 / 0xD2 / 0xD3)
---------------------------------------------------------------------------

local function def_shift(opcode, bits, count_mode)
    def(opcode, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local count
        if count_mode == "imm8" then
            count, nip = fetch8(self, nip)
        elseif count_mode == "cl" then
            count = self:get_reg8(1)
        else
            count = 1
        end
        local value
        if bits == 8 then
            value = read_rm8(self, rm, addr)
        else
            value = read_rm16(self, rm, addr)
        end
        local result = shift_rotate(self, reg, value, count, bits)
        if bits == 8 then
            write_rm8(self, rm, addr, result)
        else
            write_rm16(self, rm, addr, result)
        end
        return nip
    end)
end

def_shift(0xC0, 8, "imm8")
def_shift(0xC1, 16, "imm8")
def_shift(0xD0, 8, "one")
def_shift(0xD1, 16, "one")
def_shift(0xD2, 8, "cl")
def_shift(0xD3, 16, "cl")

---------------------------------------------------------------------------
-- Group 3 (0xF6 / 0xF7): TEST NOT NEG MUL IMUL DIV IDIV
---------------------------------------------------------------------------

local function def_group3(opcode, bits)
    def(opcode, function(self, ip, seg)
        local reg, rm, addr, nip = decode_modrm(self, ip, seg)
        local value
        if bits == 8 then
            value = read_rm8(self, rm, addr)
        else
            value = read_rm16(self, rm, addr)
        end

        if reg == 0 or reg == 1 then -- TEST
            local immediate
            if bits == 8 then
                immediate, nip = fetch8(self, nip)
            else
                immediate, nip = fetch16(self, nip)
            end
            alu_op(self, 4, value, immediate, bits)
        elseif reg == 2 then -- NOT
            local mask = (bits == 8) and MASK8 or MASK16
            if bits == 8 then
                write_rm8(self, rm, addr, mask - value)
            else
                write_rm16(self, rm, addr, mask - value)
            end
        elseif reg == 3 then -- NEG
            local result = alu_op(self, 5, 0, value, bits)
            if bits == 8 then
                write_rm8(self, rm, addr, result)
            else
                write_rm16(self, rm, addr, result)
            end
        elseif reg == 4 then
            do_mul(self, value, bits)
        elseif reg == 5 then
            do_imul(self, value, bits)
        elseif reg == 6 then
            do_div(self, value, bits)
        else
            do_idiv(self, value, bits)
        end
        return nip
    end)
end

def_group3(0xF6, 8)
def_group3(0xF7, 16)

---------------------------------------------------------------------------
-- String instructions
---------------------------------------------------------------------------

local function def_string(opcode, fn, conditional)
    def(opcode, function(self, ip, seg)
        self._seg = seg
        local rep = self._rep
        if rep == nil then
            fn(self)
            return ip
        end
        local cx = self:get_reg16(1)
        if cx == 0 then
            return ip
        end
        fn(self)
        cx = (cx - 1) % BASE16
        self:set_reg16(1, cx)
        local more
        if conditional then
            if rep == "rep" then
                more = (cx ~= 0) and self.flags.ZF
            else
                more = (cx ~= 0) and not self.flags.ZF
            end
        else
            more = (cx ~= 0)
        end
        if more then
            return self._err_ip
        end
        return ip
    end)
end

def_string(0xA4, function(self) string_movs(self, 8) end, false)
def_string(0xA5, function(self) string_movs(self, 16) end, false)
def_string(0xA6, function(self) string_cmps(self, 8) end, true)
def_string(0xA7, function(self) string_cmps(self, 16) end, true)
def_string(0xAA, function(self) string_stos(self, 8) end, false)
def_string(0xAB, function(self) string_stos(self, 16) end, false)
def_string(0xAC, function(self) string_lods(self, 8) end, false)
def_string(0xAD, function(self) string_lods(self, 16) end, false)
def_string(0xAE, function(self) string_scas(self, 8) end, true)
def_string(0xAF, function(self) string_scas(self, 16) end, true)

---------------------------------------------------------------------------
-- Misc single byte instructions
---------------------------------------------------------------------------

def(0x90, function(self, ip) -- NOP
    return ip
end)

for i = 1, 7 do
    def(0x90 + i, function(self, ip) -- XCHG AX, r16
        local ax = self:get_reg16(0)
        self:set_reg16(0, self:get_reg16(i))
        self:set_reg16(i, ax)
        return ip
    end)
end

def(0x98, function(self, ip) -- CBW
    self:set_reg16(0, s8(self:get_reg8(0)) % BASE16)
    return ip
end)

def(0x99, function(self, ip) -- CWD
    if self:get_reg16(0) >= 0x8000 then
        self:set_reg16(2, MASK16)
    else
        self:set_reg16(2, 0)
    end
    return ip
end)

def(0x9E, function(self, ip) -- LAHF
    local f = self.flags
    local v = 2
    if f.CF then v = v + 1 end
    if f.PF then v = v + 4 end
    if f.AF then v = v + 16 end
    if f.ZF then v = v + 64 end
    if f.SF then v = v + 128 end
    self:set_reg8(4, v)
    return ip
end)

def(0x9F, function(self, ip) -- SAHF
    local f = self.flags
    local v = self:get_reg8(4)
    f.CF = (v % 2 == 1)
    f.PF = (floor(v / 4) % 2 == 1)
    f.AF = (floor(v / 16) % 2 == 1)
    f.ZF = (floor(v / 64) % 2 == 1)
    f.SF = (floor(v / 128) % 2 == 1)
    return ip
end)

def(0xF4, function(self, ip) -- HLT
    self.halted = true
    return ip
end)

def(0xF5, function(self, ip) -- CMC
    self.flags.CF = not self.flags.CF
    return ip
end)

def(0xF8, function(self, ip) -- CLC
    self.flags.CF = false
    return ip
end)

def(0xF9, function(self, ip) -- STC
    self.flags.CF = true
    return ip
end)

def(0xFA, function(self, ip) -- CLI
    self.flags.IF = false
    return ip
end)

def(0xFB, function(self, ip) -- STI
    self.flags.IF = true
    return ip
end)

def(0xFC, function(self, ip) -- CLD
    self.flags.DF = false
    return ip
end)

def(0xFD, function(self, ip) -- STD
    self.flags.DF = true
    return ip
end)

---------------------------------------------------------------------------
-- IN / OUT
---------------------------------------------------------------------------

def(0xE4, function(self, ip) -- IN AL, imm8
    local port, nip = fetch8(self, ip)
    self:set_reg8(0, port_in(self, port, 8))
    return nip
end)

def(0xE5, function(self, ip) -- IN AX, imm8
    local port, nip = fetch8(self, ip)
    self:set_reg16(0, port_in(self, port, 16))
    return nip
end)

def(0xE6, function(self, ip) -- OUT imm8, AL
    local port, nip = fetch8(self, ip)
    port_out(self, port, 8, self:get_reg8(0))
    return nip
end)

def(0xE7, function(self, ip) -- OUT imm8, AX
    local port, nip = fetch8(self, ip)
    port_out(self, port, 16, self:get_reg16(0))
    return nip
end)

def(0xEC, function(self, ip) -- IN AL, DX
    self:set_reg8(0, port_in(self, self:get_reg16(2), 8))
    return ip
end)

def(0xED, function(self, ip) -- IN AX, DX
    self:set_reg16(0, port_in(self, self:get_reg16(2), 16))
    return ip
end)

def(0xEE, function(self, ip) -- OUT DX, AL
    port_out(self, self:get_reg16(2), 8, self:get_reg8(0))
    return ip
end)

def(0xEF, function(self, ip) -- OUT DX, AX
    port_out(self, self:get_reg16(2), 16, self:get_reg16(0))
    return ip
end)

---------------------------------------------------------------------------
-- INT / IRET
---------------------------------------------------------------------------

def(0xCC, function(self, ip) -- INT 3
    do_interrupt(self, 3, ip)
    return nil
end)

def(0xCD, function(self, ip) -- INT imm8
    local vector, nip = fetch8(self, ip)
    do_interrupt(self, vector, nip)
    return nil
end)

def(0xCF, function(self, ip) -- IRET
    local return_ip = self:pop16()
    local cs = self:pop16()
    local flags = self:pop16()
    self.seg.cs = cs % BASE16
    self.ip = return_ip % BASE16
    unpack_flags(self, flags)
    return nil
end)

---------------------------------------------------------------------------
-- BCD / ASCII adjust instructions
---------------------------------------------------------------------------

-- DAA: decimal adjust AL after addition.
def(0x27, function(self) -- DAA
    local al = self:get_reg8(0)
    local old_al = al
    local old_cf = self.flags.CF
    local f = self.flags
    if al % 16 > 9 or f.AF then
        al = al + 6
        f.AF = true
    else
        f.AF = false
    end
    if old_al > 0x99 or old_cf then
        al = al + 0x60
        f.CF = true
    else
        f.CF = false
    end
    al = al % 256
    self:set_reg8(0, al)
    update_szp(self, al, 8)
    return nil
end)

-- DAS: decimal adjust AL after subtraction.
def(0x2F, function(self) -- DAS
    local al = self:get_reg8(0)
    local old_al = al
    local old_cf = self.flags.CF
    local f = self.flags
    if al % 16 > 9 or f.AF then
        al = al - 6
        f.AF = true
    else
        f.AF = false
    end
    if old_al > 0x99 or old_cf then
        al = al - 0x60
        f.CF = true
    else
        f.CF = false
    end
    al = al % 256
    self:set_reg8(0, al)
    update_szp(self, al, 8)
    return nil
end)

-- AAA: ASCII adjust AL after addition (works on the low nibble; AH carries
-- the decimal carry, SF/ZF/PF are undefined on the 8086 and left alone).
def(0x37, function(self) -- AAA
    local al = self:get_reg8(0)
    local f = self.flags
    if al % 16 > 9 or f.AF then
        al = (al + 6) % 256
        self:set_reg8(4, (self:get_reg8(4) + 1) % 256)
        f.AF = true
        f.CF = true
    else
        f.AF = false
        f.CF = false
    end
    self:set_reg8(0, al % 16)
    return nil
end)

-- AAS: ASCII adjust AL after subtraction.
def(0x3F, function(self) -- AAS
    local al = self:get_reg8(0)
    local f = self.flags
    if al % 16 > 9 or f.AF then
        al = (al - 6) % 256
        self:set_reg8(4, (self:get_reg8(4) - 1) % 256)
        f.AF = true
        f.CF = true
    else
        f.AF = false
        f.CF = false
    end
    self:set_reg8(0, al % 16)
    return nil
end)

-- AAM: ASCII adjust AX after multiply.  AH = AL / base, AL = AL % base;
-- SF/ZF/PF reflect the new AL.  A zero base raises a divide error, exactly
-- like the hardware exception (the immediate form is undocumented on the
-- 8086 but is what real CPUs execute).
def(0xD4, function(self, ip) -- AAM
    local base, nip = fetch8(self, ip)
    if base == 0 then
        raise_divide(self)
    end
    local al = self:get_reg8(0)
    local remainder = al % base
    self:set_reg8(4, floor(al / base))
    self:set_reg8(0, remainder)
    update_szp(self, remainder, 8)
    return nip
end)

-- AAD: ASCII adjust AX before divide.  AL = (AH * base + AL) % 256, AH = 0;
-- SF/ZF/PF reflect the new AL.
def(0xD5, function(self, ip) -- AAD
    local base, nip = fetch8(self, ip)
    local al = self:get_reg8(0)
    local ah = self:get_reg8(4)
    local value = (ah * base + al) % 256
    self:set_reg8(4, 0)
    self:set_reg8(0, value)
    update_szp(self, value, 8)
    return nip
end)

---------------------------------------------------------------------------
-- CPU methods
---------------------------------------------------------------------------

function CPU:get_reg8(i)
    if i < 4 then
        return self.reg[i] % 256
    end
    return floor(self.reg[i - 4] / 256) % 256
end

function CPU:set_reg8(i, value)
    local v = value % 256
    if i < 4 then
        local current = self.reg[i]
        self.reg[i] = current - (current % 256) + v
    else
        local index = i - 4
        local current = self.reg[index]
        local low = current % 256
        local high = current - (current % BASE16)
        self.reg[index] = high + v * 256 + low
    end
end

function CPU:get_reg16(i)
    return self.reg[i] % BASE16
end

function CPU:set_reg16(i, value)
    self.reg[i] = value % BASE16
end

function CPU:get_sreg(name)
    local value = self.seg[name]
    if value == nil then
        raise_bad_argument("get_sreg", "unknown segment register "
            .. tostring(name))
    end
    return value
end

function CPU:set_sreg(name, value)
    if self.seg[name] == nil then
        raise_bad_argument("set_sreg", "unknown segment register "
            .. tostring(name))
    end
    self.seg[name] = value % BASE16
end

function CPU:get_flag(name)
    local value = self.flags[name]
    if value == nil then
        raise_bad_argument("get_flag", "unknown flag " .. tostring(name))
    end
    return value
end

function CPU:set_flag(name, value)
    if self.flags[name] == nil then
        raise_bad_argument("set_flag", "unknown flag " .. tostring(name))
    end
    local v = (value == true) or (value == 1)
    self.flags[name] = v
    -- While a registered interrupt handler runs, remember the flags it edits
    -- so the implicit IRET can re-apply them over the restored image.
    if self._in_handler and self._flag_overrides ~= nil then
        self._flag_overrides[name] = v
    end
end

function CPU:read8(seg, offset)
    return self.memory:read8(seg * 16 + offset)
end

function CPU:read16(seg, offset)
    return self.memory:read16(seg * 16 + offset)
end

function CPU:write8(seg, offset, value)
    self.memory:write8(seg * 16 + offset, value)
end

function CPU:write16(seg, offset, value)
    self.memory:write16(seg * 16 + offset, value)
end

function CPU:push16(value)
    local sp = (self:get_reg16(4) - 2) % BASE16
    self:set_reg16(4, sp)
    self.memory:write16(self.seg.ss * 16 + sp, value % BASE16)
end

function CPU:pop16()
    local sp = self:get_reg16(4)
    local value = self.memory:read16(self.seg.ss * 16 + sp)
    self:set_reg16(4, (sp + 2) % BASE16)
    return value
end

-- Far jump to segment:offset.  When called from inside a registered
-- interrupt handler it suppresses the implicit IRET, which is how the BIOS
-- INT 19h handler hands control to the boot sector without returning.
function CPU:jump_far(segment, offset)
    if type(segment) ~= "number" or segment % 1 ~= 0
        or segment < 0 or segment > BASE16 - 1 then
        error("cpu.jump_far: segment must be an integer 0..65535 (got "
            .. tostring(segment) .. ")", 0)
    end
    if type(offset) ~= "number" or offset % 1 ~= 0
        or offset < 0 or offset > BASE16 - 1 then
        error("cpu.jump_far: offset must be an integer 0..65535 (got "
            .. tostring(offset) .. ")", 0)
    end
    self.seg.cs = segment % BASE16
    self.ip = offset % BASE16
    if self._in_handler then
        self._handler_jumped = true
    end
    return self
end

-- Execute exactly one instruction.  Anything not implemented raises.
function CPU:step()
    self.steps = self.steps + 1

    local cs = self.seg.cs
    local start_ip = self.ip % BASE16
    self._err_cs = cs
    self._err_ip = start_ip

    local ip = start_ip
    local seg = nil
    local rep = nil
    local opcode

    while true do
        opcode, ip = fetch8(self, ip)
        if opcode == 0x26 then
            seg = "es"
        elseif opcode == 0x2E then
            seg = "cs"
        elseif opcode == 0x36 then
            seg = "ss"
        elseif opcode == 0x3E then
            seg = "ds"
        elseif opcode == 0xF0 then
            -- LOCK: accepted and ignored, there is no shared bus here.
        elseif opcode == 0xF2 then
            rep = "ne"
        elseif opcode == 0xF3 then
            rep = "rep"
        elseif opcode == 0x66 or opcode == 0x67 then
            -- Operand / address size prefixes are not implemented.
            error(string.format(
                "cpu: unimplemented opcode 0x%02X at CS:IP=%04X:%04X",
                opcode, cs, start_ip), 0)
        else
            break
        end
    end

    local handler = handlers[opcode]
    if handler == nil then
        error(string.format(
            "cpu: unimplemented opcode 0x%02X at CS:IP=%04X:%04X",
            opcode, cs, start_ip), 0)
    end

    self._op  = opcode
    self._seg = seg
    self._rep = rep

    local new_ip = handler(self, ip, seg)
    if new_ip ~= nil then
        self.ip = new_ip % BASE16
    end
end

-- Run until HLT or until max_steps instructions have executed.  Every
-- sleep_interval instructions the injected sleep function is called with 0
-- so the caller can yield to CraftOS.  This instruction-count yield is always
-- active and must never be removed.
--
-- Optional watchdog: when watchdog_max_tick > 0 the run gets a wall-clock
-- budget of watchdog_max_tick * WATCHDOG_SECONDS_PER_TICK seconds, armed on
-- the first run call and never reset.  At each yield point the CPU checks the
-- deadline; when it has passed it forces one more sleep(0) yield and then
-- raises a clear error, so a runaway guest cannot monopolise the computer.
-- The clock is injectable (opts.clock) so the behaviour is testable.
function CPU:run(max_steps)
    if max_steps == nil then
        max_steps = 1000000
    end
    local executed = 0
    local interval = self._sleep_interval
    local watchdog = self._watchdog_seconds

    local deadline = nil
    if watchdog ~= nil then
        if self._watchdog_deadline == nil then
            self._watchdog_deadline = self._clock() + watchdog
        end
        deadline = self._watchdog_deadline
    end

    while executed < max_steps do
        if self.halted then
            return executed, "halted"
        end
        self:step()
        executed = executed + 1
        if executed % interval == 0 then
            self._sleep(0)
            if deadline ~= nil and self._clock() >= deadline then
                -- Force a final yield, then stop with a diagnostic instead
                -- of letting the guest keep the computer busy forever.
                self._sleep(0)
                error("cpu.run: watchdog timeout: max_tick="
                    .. self.watchdog_max_tick .. " ("
                    .. tostring(watchdog) .. " s) exceeded at CS:IP="
                    .. string.format("%04X:%04X", self.seg.cs, self.ip), 0)
            end
        end
    end

    if self.halted then
        return executed, "halted"
    end
    return executed, "limit"
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function M.new(opts)
    if type(opts) ~= "table" then
        error("cpu.new: an options table is required", 0)
    end

    local memory = opts.memory
    if type(memory) ~= "table" or type(memory.read8) ~= "function" then
        error("cpu.new: opts.memory must be a memory object", 0)
    end

    local sleep = opts.sleep
    if sleep == nil then
        sleep = os.sleep
    end
    if type(sleep) ~= "function" then
        error("cpu.new: opts.sleep must be a function", 0)
    end

    local interval = opts.sleep_interval
    if interval == nil then
        interval = M.SLEEP_INTERVAL
    end
    if type(interval) ~= "number" or interval % 1 ~= 0 or interval < 1 then
        error("cpu.new: opts.sleep_interval must be a positive integer", 0)
    end

    local watchdog_tick = opts.watchdog_max_tick
    if watchdog_tick == nil then
        watchdog_tick = -1
    end
    if type(watchdog_tick) ~= "number" or watchdog_tick % 1 ~= 0
        or (watchdog_tick ~= -1 and watchdog_tick < 1) then
        error("cpu.new: opts.watchdog_max_tick must be -1 (disabled) or a "
            .. "positive integer", 0)
    end

    local clock = opts.clock
    if clock == nil then
        clock = rawget(_G, "os") and os.clock or function() return 0 end
    end
    if type(clock) ~= "function" then
        error("cpu.new: opts.clock must be a function", 0)
    end

    local watchdog_seconds = nil
    if watchdog_tick > 0 then
        watchdog_seconds = watchdog_tick * M.WATCHDOG_SECONDS_PER_TICK
    end

    local reg = {}
    for i = 0, 7 do
        reg[i] = 0
    end

    return setmetatable({
        memory = memory,
        reg     = reg,
        seg     = { cs = 0, ds = 0, es = 0, ss = 0 },
        ip      = 0,
        flags   = {
            CF = false,
            PF = false,
            AF = false,
            ZF = false,
            SF = false,
            TF = false,
            IF = false,
            DF = false,
            OF = false,
        },
        halted     = false,
        steps      = 0,
        interrupts = {},
        ports      = { ["in"] = {}, out = {} },
        _sleep          = sleep,
        _sleep_interval = interval,
        watchdog_max_tick  = watchdog_tick,
        _watchdog_seconds  = watchdog_seconds,
        _watchdog_deadline = nil,
        _clock             = clock,
        _err_cs         = 0,
        _err_ip         = 0,
        _op             = 0,
        _seg            = nil,
        _rep            = nil,
        _in_handler     = false,
        _handler_jumped = false,
        _flag_overrides = nil,
    }, CPU)
end

return M
