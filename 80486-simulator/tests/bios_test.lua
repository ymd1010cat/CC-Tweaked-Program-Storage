---------------------------------------------------------------------------
-- 80486-simulator/tests/bios_test.lua
--
-- Standalone tests for bios.lua (INT 10h video, INT 13h disk).
--
-- From the repository root:
--     lua 80486-simulator/tests/bios_test.lua
-- or, inside CraftOS:
--     dofile("/tests/bios_test.lua")
--
-- The CPU is a minimal stub that implements exactly the public API described
-- by cpu.lua (registers, segment registers, flags and memory access).  When
-- a real cpu.lua is present on one of the search paths it is used instead,
-- provided it passes a small self-check; in that case the same interrupt
-- entry points are driven through the real register file.
--
-- The video side is checked through the same fake terminal used by
-- vga_test.lua, and the disk side through a fake block device, so nothing
-- here touches the real hardware or the real disk image.
---------------------------------------------------------------------------

local char   = string.char
local byte   = string.byte
local rep    = string.rep
local sub    = string.sub
local floor  = math.floor

---------------------------------------------------------------------------
-- Module loading
---------------------------------------------------------------------------

local function load_module(name, is_module)
    local ok, mod = pcall(require, name)
    if ok and is_module(mod) then
        return mod
    end

    local candidates = {
        "80486-simulator/" .. name .. ".lua",
        "../" .. name .. ".lua",
        name .. ".lua",
        "/80486-simulator/" .. name .. ".lua",
        "/" .. name .. ".lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and is_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load " .. name .. ".lua: " .. tostring(last_error))
end

local function is_memory_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.PAGE_SIZE == 4096
end

local function is_vga_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.BASE == 0xB8000
        and mod.WIDTH == 80
end

local function is_bios_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and type(mod.DEFAULT_GEOMETRY) == "table"
end

local Memory = load_module("memory", is_memory_module)
local Vga = load_module("vga", is_vga_module)
local Bios = load_module("bios", is_bios_module)

---------------------------------------------------------------------------
-- Test bookkeeping
---------------------------------------------------------------------------

local total   = 0
local passed  = 0
local skipped = 0
local failed  = 0

local function show(value)
    if type(value) == "string" then
        if #value <= 60 then
            return string.format("%q", value)
        end
        return string.format("<string len=%d>", #value)
    end
    if type(value) == "number" then
        return string.format("%d (0x%X)", value, value)
    end
    return tostring(value)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" or not text:find(needle, 1, true) then
        error(string.format("%s: %s does not contain %q",
            label or "text", show(text), needle), 2)
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

local function skip(reason)
    error({__skip = reason}, 0)
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        if type(err) == "table" and err.__skip ~= nil then
            skipped = skipped + 1
            print("skip " .. name .. " (" .. tostring(err.__skip) .. ")")
        else
            failed = failed + 1
            print("FAIL " .. name)
            print("     " .. tostring(err))
        end
    end
end

---------------------------------------------------------------------------
-- Fake CraftOS terminal (same contract as the one in vga_test.lua)
---------------------------------------------------------------------------

local function new_term(width, height)
    local term = {
        width  = width,
        height = height,
        cells  = {},
        fg     = {},
        bg     = {},
        blits  = 0,
        writes = 0,
        cursor_x = 1,
        cursor_y = 1,
    }
    for row = 1, height do
        term.cells[row] = {}
        term.fg[row] = {}
        term.bg[row] = {}
        for col = 1, width do
            term.cells[row][col] = "?"
            term.fg[row][col] = "?"
            term.bg[row][col] = "?"
        end
    end

    function term.getSize()
        return term.width, term.height
    end

    function term.setCursorPos(x, y)
        term.cursor_x = x
        term.cursor_y = y
    end

    function term.getCursorPos()
        return term.cursor_x, term.cursor_y
    end

    function term.blit(text, text_fg, text_bg)
        term.blits = term.blits + 1
        local row = term.cursor_y
        local col = term.cursor_x
        for i = 1, #text do
            local cell_col = col + i - 1
            if row >= 1 and row <= term.height
                and cell_col >= 1 and cell_col <= term.width
            then
                term.cells[row][cell_col] = sub(text, i, i)
                term.fg[row][cell_col] = sub(text_fg, i, i)
                term.bg[row][cell_col] = sub(text_bg, i, i)
            end
        end
        term.cursor_x = col + #text
    end

    function term.write(text)
        term.writes = term.writes + 1
        local row = term.cursor_y
        local col = term.cursor_x
        for i = 1, #text do
            local cell_col = col + i - 1
            if row >= 1 and row <= term.height
                and cell_col >= 1 and cell_col <= term.width
            then
                term.cells[row][cell_col] = sub(text, i, i)
            end
        end
        term.cursor_x = col + #text
    end

    return term
end

local function term_char(term, row, col)
    return term.cells[row][col]
end

local function term_fg(term, row, col)
    return term.fg[row][col]
end

local function term_bg(term, row, col)
    return term.bg[row][col]
end

---------------------------------------------------------------------------
-- Fake block device
---------------------------------------------------------------------------

local DEFAULT_SECTOR_COUNT = 100

local function new_disk()
    local disk = {
        sector_count = DEFAULT_SECTOR_COUNT,
        calls        = {},
        fail_lba     = nil,
        fail_reason  = "simulated read failure",
        bad_length   = nil,
    }
    function disk:try_read_sectors(lba, count)
        self.calls[#self.calls + 1] = {lba = lba, count = count}
        if self.fail_lba ~= nil and lba == self.fail_lba then
            return nil, self.fail_reason
        end
        if lba < 0 or count < 0 or lba + count > self.sector_count then
            return nil, string.format("LBA %d+%d out of range", lba, count)
        end
        if self.bad_length ~= nil then
            return rep("x", self.bad_length)
        end
        local parts = {}
        for i = 0, count - 1 do
            parts[#parts + 1] = rep(char((lba + i) % 256), 512)
        end
        return table.concat(parts)
    end
    return disk
end

---------------------------------------------------------------------------
-- Minimal CPU stub implementing the public cpu.lua API
---------------------------------------------------------------------------

local function new_cpu(memory)
    local cpu = {
        reg16      = {},
        seg        = {cs = 0, ds = 0, es = 0, ss = 0},
        flags      = {},
        ip         = 0,
        halted     = false,
        steps      = 0,
        interrupts = {},
        ports      = {["in"] = {}, out = {}},
        memory     = memory,
    }

    -- 16-bit registers: 0=AX 1=CX 2=DX 3=BX 4=SP 5=BP 6=SI 7=DI
    function cpu:get_reg16(index)
        return self.reg16[index] or 0
    end

    function cpu:set_reg16(index, value)
        if type(value) ~= "number" then
            error("cpu:set_reg16: value must be a number", 2)
        end
        self.reg16[index] = value % 65536
    end

    -- 8-bit registers: 0=AL 1=CL 2=DL 3=BL 4=AH 5=CH 6=DH 7=BH
    function cpu:get_reg8(index)
        local low = index < 4
        local base = low and index or index - 4
        local value = self.reg16[base] or 0
        if low then
            return value % 256
        end
        return floor(value / 256) % 256
    end

    function cpu:set_reg8(index, value)
        if type(value) ~= "number" then
            error("cpu:set_reg8: value must be a number", 2)
        end
        local low = index < 4
        local base = low and index or index - 4
        local value16 = self.reg16[base] or 0
        local low_byte = value16 % 256
        local high_byte = floor(value16 / 256) % 256
        if low then
            low_byte = value % 256
        else
            high_byte = value % 256
        end
        self.reg16[base] = high_byte * 256 + low_byte
    end

    function cpu:get_sreg(name)
        return self.seg[name] or 0
    end

    function cpu:set_sreg(name, value)
        if type(value) ~= "number" then
            error("cpu:set_sreg: value must be a number", 2)
        end
        self.seg[name] = value % 65536
    end

    function cpu:get_flag(name)
        return self.flags[name] == true
    end

    function cpu:set_flag(name, value)
        self.flags[name] = value and true or false
    end

    function cpu:read8(segment, offset)
        return self.memory:read8(segment * 16 + offset)
    end

    function cpu:read16(segment, offset)
        return self.memory:read16(segment * 16 + offset)
    end

    function cpu:write8(segment, offset, value)
        self.memory:write8(segment * 16 + offset, value)
    end

    function cpu:write16(segment, offset, value)
        self.memory:write16(segment * 16 + offset, value)
    end

    function cpu:push16(value)
        local sp = (self:get_reg16(4) - 2) % 65536
        self:set_reg16(4, sp)
        self:write16(self:get_sreg("ss"), sp, value % 65536)
    end

    function cpu:pop16()
        local sp = self:get_reg16(4)
        local value = self:read16(self:get_sreg("ss"), sp)
        self:set_reg16(4, (sp + 2) % 65536)
        return value
    end

    return cpu
end

---------------------------------------------------------------------------
-- Environment helpers
---------------------------------------------------------------------------

local function new_env(opts)
    opts = opts or {}
    local memory = opts.memory or Memory.new()
    local vga = opts.vga or Vga.new{memory = memory}
    local term = opts.term
    if term == nil then
        term = new_term(51, 19)
    end
    local bios = Bios.new{
        memory   = memory,
        vga      = vga,
        disk     = opts.disk,
        term     = term,
        geometry = opts.geometry,
        log      = opts.log,
    }
    local cpu = new_cpu(memory)
    bios:attach(cpu)
    return {
        bios   = bios,
        cpu    = cpu,
        memory = memory,
        vga    = vga,
        term   = term,
        disk   = opts.disk,
    }
end

local function ah(cpu)
    return cpu:get_reg8(4)
end

local function al(cpu)
    return cpu:get_reg8(0)
end

local function cf(cpu)
    local value = cpu:get_flag("CF")
    return value == true or value == 1
end

local function set_inputs(cpu, values)
    if values.ah ~= nil then cpu:set_reg8(4, values.ah) end
    if values.al ~= nil then cpu:set_reg8(0, values.al) end
    if values.ch ~= nil then cpu:set_reg8(5, values.ch) end
    if values.cl ~= nil then cpu:set_reg8(1, values.cl) end
    if values.dh ~= nil then cpu:set_reg8(6, values.dh) end
    if values.dl ~= nil then cpu:set_reg8(2, values.dl) end
    if values.bl ~= nil then cpu:set_reg8(3, values.bl) end
    if values.bh ~= nil then cpu:set_reg8(7, values.bh) end
    if values.cx ~= nil then cpu:set_reg16(1, values.cx) end
    if values.es ~= nil then cpu:set_sreg("es", values.es) end
    if values.bx ~= nil then cpu:set_reg16(3, values.bx) end
end

local function call_int10(env, values)
    set_inputs(env.cpu, values)
    return env.bios:int10(env.cpu)
end

local function call_int13(env, values)
    set_inputs(env.cpu, values)
    return env.bios:int13(env.cpu)
end

---------------------------------------------------------------------------
-- Construction and installation
---------------------------------------------------------------------------

test("module constants and defaults", function()
    eq(Bios.DEFAULT_GEOMETRY.sectors, 9, "default sectors")
    eq(Bios.DEFAULT_GEOMETRY.heads, 2, "default heads")
    eq(Bios.DEFAULT_GEOMETRY.cylinders, 40, "default cylinders")
    eq(Bios.INT_VIDEO, 0x10, "video interrupt")
    eq(Bios.INT_DISK, 0x13, "disk interrupt")
    eq(Bios.MAX_SECTORS_PER_READ, 128, "sector read limit")

    local env = new_env()
    eq(env.bios.mode, 3, "initial video mode")
    eq(env.bios.last_error, nil, "no error initially")
    eq(type(env.bios.interrupts[0x10]), "function", "INT 10h handler")
    eq(type(env.bios.interrupts[0x13]), "function", "INT 13h handler")
    eq(env.bios.geometry.sectors, 9, "geometry sectors")
    eq(env.bios.geometry.heads, 2, "geometry heads")
    eq(env.bios.geometry.cylinders, 40, "geometry cylinders")
end)

test("constructor validates its options", function()
    local memory = Memory.new()
    local vga = Vga.new{memory = memory}

    expect_error(function() Bios.new(nil) end, "options table")
    expect_error(function() Bios.new{vga = vga} end, "opts.memory")
    expect_error(function() Bios.new{memory = memory} end, "opts.vga")
    expect_error(function()
        Bios.new{memory = memory, vga = vga,
            disk = {try_read_sectors = "no"}}
    end, "try_read_sectors")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, log = "no"}
    end, "opts.log")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, term = 42}
    end, "opts.term")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, geometry = {sectors = 0}}
    end, "geometry.sectors")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, geometry = {sectors = 64}}
    end, "sectors")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, geometry = {heads = 0}}
    end, "geometry.heads")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, geometry = {cylinders = 1025}}
    end, "cylinders")
    expect_error(function()
        Bios.new{memory = memory, vga = vga, geometry = "no"}
    end, "opts.geometry")
end)

test("attach installs the interrupts and the CRTC ports", function()
    local env = new_env()
    local cpu = env.cpu
    eq(cpu.interrupts[0x10], env.bios.interrupts[0x10], "INT 10h installed")
    eq(cpu.interrupts[0x13], env.bios.interrupts[0x13], "INT 13h installed")
    eq(type(cpu.ports.out[0x3D4]), "function", "CRTC index port")
    eq(type(cpu.ports.out[0x3D5]), "function", "CRTC data out port")
    eq(type(cpu.ports["in"][0x3D5]), "function", "CRTC data in port")
    eq(cpu.ports.out[0x3D8], nil, "other video ports stay unmapped")
    eq(cpu.ports.out[0x3DA], nil, "status port stays unmapped")
    eq(cpu.ports["in"][0x3D4], nil, "index port has no read handler")
end)

test("attach rejects an unusable cpu", function()
    local env = new_env()
    expect_error(function() env.bios:attach(nil) end, "cpu object")

    local broken = new_cpu(Memory.new())
    broken.set_reg8 = nil
    expect_error(function() env.bios:attach(broken) end, "set_reg8")

    local no_ports = new_cpu(Memory.new())
    no_ports.ports = nil
    expect_error(function() env.bios:attach(no_ports) end, "cpu.ports")

    local no_interrupts = new_cpu(Memory.new())
    no_interrupts.interrupts = nil
    expect_error(function() env.bios:attach(no_interrupts) end,
        "cpu.interrupts")
end)

---------------------------------------------------------------------------
-- INT 10h: mode and cursor
---------------------------------------------------------------------------

test("INT 10h AH=00 sets a text mode and clears the screen", function()
    local env = new_env()
    env.vga:write_cell(3, 5, "X", 0x1F)
    env.vga:set_cursor(9, 9)

    call_int10(env, {ah = 0x00, al = 0x03})
    eq(env.bios.mode, 3, "reported mode")
    eq(env.vga:read_char(3, 5), " ", "screen cleared")
    eq(env.vga:read_attr(3, 5), 0x07, "clear attribute")
    local row, col = env.vga:get_cursor()
    eq(row, 0, "cursor row reset")
    eq(col, 0, "cursor column reset")
    eq(env.term.blits > 0, true, "screen refreshed after mode set")
    eq(term_char(env.term, 1, 1), " ", "terminal shows the cleared cell")

    for _, mode in ipairs({0, 1, 2, 3, 7}) do
        call_int10(env, {ah = 0x00, al = mode})
        eq(env.bios.mode, mode, "mode " .. mode .. " accepted")
    end
end)

test("INT 10h AH=00 rejects unimplemented video modes", function()
    local env = new_env()
    local err = expect_error(function()
        call_int10(env, {ah = 0x00, al = 0x13})
    end, "INT 10h")
    contains(tostring(err), "0x13", "error names the mode")
    eq(env.bios.mode, 3, "mode unchanged after a failed set")
end)

test("INT 10h AH=01 stores the cursor shape", function()
    local env = new_env()
    call_int10(env, {ah = 0x01, ch = 0x06, cl = 0x07})
    eq(env.bios.cursor_shape, 0x0607, "stored shape")

    -- Function 03 must hand the shape back in CX.
    call_int10(env, {ah = 0x03})
    eq(env.cpu:get_reg16(1), 0x0607, "CX shape")
end)

test("INT 10h AH=02 sets the cursor and refreshes", function()
    local env = new_env()
    call_int10(env, {ah = 0x02, dh = 5, dl = 10})
    local row, col = env.vga:get_cursor()
    eq(row, 5, "cursor row")
    eq(col, 10, "cursor column")
    eq(env.term.cursor_y, 6, "terminal cursor row")
    eq(env.term.cursor_x, 11, "terminal cursor column")

    -- Out-of-range positions are clamped by the VGA.
    call_int10(env, {ah = 0x02, dh = 200, dl = 200})
    row, col = env.vga:get_cursor()
    eq(row, 24, "clamped row")
    eq(col, 79, "clamped column")
end)

test("INT 10h AH=03 reports cursor position and shape", function()
    local env = new_env()
    call_int10(env, {ah = 0x01, ch = 0x06, cl = 0x07})
    call_int10(env, {ah = 0x02, dh = 2, dl = 3})
    call_int10(env, {ah = 0x03})
    eq(env.cpu:get_reg8(6), 2, "DH cursor row")
    eq(env.cpu:get_reg8(2), 3, "DL cursor column")
    eq(env.cpu:get_reg8(5), 0x06, "CH shape start")
    eq(env.cpu:get_reg8(1), 0x07, "CL shape end")
    eq(env.cpu:get_reg8(7), 0, "BH page")
end)

test("INT 10h AH=05 only supports page 0", function()
    local env = new_env()
    call_int10(env, {ah = 0x05, al = 0x00})
    expect_error(function()
        call_int10(env, {ah = 0x05, al = 0x01})
    end, "INT 10h")
end)

---------------------------------------------------------------------------
-- INT 10h: scrolling windows
---------------------------------------------------------------------------

local function fill_rows(vga, rows, columns)
    for row = 0, rows - 1 do
        for col = 0, columns - 1 do
            vga:write_cell(row, col, char(65 + row), 0x07)
        end
    end
end

test("INT 10h AH=06 scrolls a window up", function()
    local env = new_env()
    fill_rows(env.vga, 10, 10)

    call_int10(env, {ah = 0x06, al = 1, bh = 0x1F,
        ch = 5, cl = 2, dh = 8, dl = 6})

    eq(env.vga:read_char(5, 2), "G", "row 6 moved to row 5")
    eq(env.vga:read_char(7, 2), "I", "row 8 moved to row 7")
    eq(env.vga:read_char(8, 2), " ", "bottom row blank")
    eq(env.vga:read_attr(8, 2), 0x1F, "bottom row scroll attribute")
    eq(env.vga:read_char(4, 2), "E", "row above the window untouched")
    eq(env.vga:read_char(5, 0), "F", "column left of the window untouched")
    eq(env.vga:read_char(5, 7), char(65 + 5), "column right untouched")
    eq(env.term.blits > 0, true, "screen refreshed")

    -- AL=0 clears the whole window.
    call_int10(env, {ah = 0x06, al = 0, bh = 0x4E,
        ch = 5, cl = 2, dh = 8, dl = 6})
    eq(env.vga:read_char(6, 3), " ", "window cleared")
    eq(env.vga:read_attr(6, 3), 0x4E, "window clear attribute")
    eq(env.vga:read_char(4, 2), "E", "outside the window untouched")
end)

test("INT 10h AH=07 scrolls a window down", function()
    local env = new_env()
    fill_rows(env.vga, 10, 10)

    call_int10(env, {ah = 0x07, al = 2, bh = 0x4E,
        ch = 2, cl = 0, dh = 5, dl = 9})

    eq(env.vga:read_char(5, 0), "D", "row 3 moved to row 5")
    eq(env.vga:read_char(4, 0), "C", "row 2 moved to row 4")
    eq(env.vga:read_char(2, 0), " ", "top row blank")
    eq(env.vga:read_attr(2, 0), 0x4E, "top row scroll attribute")
    eq(env.vga:read_char(3, 0), " ", "second top row blank")
    eq(env.vga:read_char(1, 0), "B", "row above the window untouched")
end)

test("INT 10h scroll rejects an invalid window", function()
    local env = new_env()
    local err = expect_error(function()
        call_int10(env, {ah = 0x06, al = 1, bh = 0x07,
            ch = 5, cl = 0, dh = 4, dl = 9})
    end, "INT 10h")
    contains(tostring(err), "invalid scroll window", "error explains why")
end)

---------------------------------------------------------------------------
-- INT 10h: reading and writing characters
---------------------------------------------------------------------------

test("INT 10h AH=08 reads character and attribute at the cursor", function()
    local env = new_env()
    env.vga:write_cell(4, 6, "Q", 0x4E)
    call_int10(env, {ah = 0x02, dh = 4, dl = 6})
    call_int10(env, {ah = 0x08})
    eq(al(env.cpu), byte("Q"), "AL character code")
    eq(ah(env.cpu), 0x4E, "AH attribute")

    -- Extended codes are returned as their stored byte, not as the
    -- approximated glyph that read_char() would produce.
    env.vga:write_cell(4, 6, 0xDB, 0x07)
    call_int10(env, {ah = 0x02, dh = 4, dl = 6})
    call_int10(env, {ah = 0x08})
    eq(al(env.cpu), 0xDB, "raw extended character code")
end)

test("INT 10h AH=09 writes characters with an attribute", function()
    local env = new_env()
    call_int10(env, {ah = 0x02, dh = 1, dl = 1})
    call_int10(env, {ah = 0x09, al = byte("X"), bh = 0,
        bl = 0x4E, cx = 3})

    for col = 1, 3 do
        eq(env.vga:read_char(1, col), "X", "character at column " .. col)
        eq(env.vga:read_attr(1, col), 0x4E, "attribute at column " .. col)
    end
    local row, col = env.vga:get_cursor()
    eq(row, 1, "cursor row unchanged")
    eq(col, 1, "cursor column unchanged")
    eq(term_char(env.term, 2, 2), "X", "terminal refreshed")

    -- Writes wrap at the right edge (without moving the cursor).
    local wrapped = new_env()
    call_int10(wrapped, {ah = 0x02, dh = 0, dl = 78})
    call_int10(wrapped, {ah = 0x09, al = byte("W"), bl = 0x1F, cx = 4})
    eq(wrapped.vga:read_char(0, 78), "W", "column 78")
    eq(wrapped.vga:read_char(0, 79), "W", "column 79")
    eq(wrapped.vga:read_char(1, 0), "W", "wrapped to row 1")
    eq(wrapped.vga:read_char(1, 1), "W", "wrapped second cell")
    row, col = wrapped.vga:get_cursor()
    eq(row, 0, "wrapped cursor row unchanged")
    eq(col, 78, "wrapped cursor column unchanged")
end)

test("INT 10h AH=0A writes characters and keeps the attribute", function()
    local env = new_env()
    env.vga:write_cell(2, 0, "A", 0x1F)
    env.vga:write_cell(2, 1, "B", 0x2A)
    env.vga:write_cell(2, 2, "C", 0x4E)
    call_int10(env, {ah = 0x02, dh = 2, dl = 0})
    call_int10(env, {ah = 0x0A, al = byte("Z"), bl = 0xFF, cx = 3})

    eq(env.vga:read_char(2, 0), "Z", "first character")
    eq(env.vga:read_char(2, 1), "Z", "second character")
    eq(env.vga:read_char(2, 2), "Z", "third character")
    eq(env.vga:read_attr(2, 0), 0x1F, "first attribute kept")
    eq(env.vga:read_attr(2, 1), 0x2A, "second attribute kept")
    eq(env.vga:read_attr(2, 2), 0x4E, "third attribute kept")
end)

---------------------------------------------------------------------------
-- INT 10h: teletype
---------------------------------------------------------------------------

test("INT 10h AH=0E teletype writes characters and wraps", function()
    local env = new_env()
    call_int10(env, {ah = 0x00, al = 0x03})
    for i = 1, #"HELLO" do
        call_int10(env, {ah = 0x0E, al = byte(sub("HELLO", i, i))})
    end
    eq(env.vga:read_line(0):sub(1, 5), "HELLO", "text written")
    eq(env.vga:read_attr(0, 0), 0x07, "teletype writes the default attribute")
    local row, col = env.vga:get_cursor()
    eq(row, 0, "cursor row")
    eq(col, 5, "cursor column advanced")
    eq(term_char(env.term, 1, 1), "H", "terminal shows the first character")

    -- Right-edge wrap: a character in the last column moves to the next row.
    call_int10(env, {ah = 0x02, dh = 0, dl = 79})
    call_int10(env, {ah = 0x0E, al = byte("R")})
    row, col = env.vga:get_cursor()
    eq(row, 1, "cursor wrapped to the next row")
    eq(col, 0, "cursor at column 0")
    eq(env.vga:read_char(0, 79), "R", "character in the last column")
end)

test("INT 10h AH=0E teletype handles CR, LF and BS", function()
    local env = new_env()
    call_int10(env, {ah = 0x00, al = 0x03})
    call_int10(env, {ah = 0x0E, al = byte("A")})
    call_int10(env, {ah = 0x0E, al = 13})
    local row, col = env.vga:get_cursor()
    eq(row, 0, "CR keeps the row")
    eq(col, 0, "CR returns to column 0")

    call_int10(env, {ah = 0x0E, al = 10})
    row, col = env.vga:get_cursor()
    eq(row, 1, "LF moves down")
    eq(col, 0, "LF keeps the column")

    call_int10(env, {ah = 0x0E, al = byte("B")})
    call_int10(env, {ah = 0x0E, al = 8})
    row, col = env.vga:get_cursor()
    eq(row, 1, "BS keeps the row")
    eq(col, 0, "BS steps back")

    -- BS at column 0 must not run off the screen.
    call_int10(env, {ah = 0x0E, al = 8})
    row, col = env.vga:get_cursor()
    eq(col, 0, "BS clamps at column 0")

    -- BEL is consumed without moving the cursor.
    call_int10(env, {ah = 0x0E, al = 7})
    row, col = env.vga:get_cursor()
    eq(row, 1, "BEL keeps the row")
    eq(col, 0, "BEL keeps the column")
end)

test("INT 10h AH=0E teletype scrolls at the bottom", function()
    local env = new_env()
    call_int10(env, {ah = 0x00, al = 0x03})

    -- Write at the bottom-right corner: that triggers a full-screen scroll.
    call_int10(env, {ah = 0x02, dh = 24, dl = 79})
    call_int10(env, {ah = 0x0E, al = byte("S")})
    local row, col = env.vga:get_cursor()
    eq(row, 24, "cursor stays on the last row")
    eq(col, 0, "cursor wrapped to column 0")
    eq(env.vga:read_char(23, 79), "S", "character scrolled up one row")
    eq(env.vga:read_char(24, 0), " ", "bottom row cleared by the scroll")

    -- A line feed on the last row scrolls too.
    local second = new_env()
    call_int10(second, {ah = 0x00, al = 0x03})
    call_int10(second, {ah = 0x02, dh = 23, dl = 0})
    call_int10(second, {ah = 0x0E, al = byte("X")})
    call_int10(second, {ah = 0x0E, al = 10})
    call_int10(second, {ah = 0x0E, al = byte("Y")})
    call_int10(second, {ah = 0x0E, al = 10})
    eq(second.vga:read_char(22, 0), "X", "X scrolled up")
    eq(second.vga:read_char(23, 1), "Y", "Y scrolled up")
end)

test("INT 10h AH=0F reports mode, columns and page", function()
    local env = new_env()
    call_int10(env, {ah = 0x00, al = 0x03})
    call_int10(env, {ah = 0x0F})
    eq(al(env.cpu), 3, "AL mode")
    eq(ah(env.cpu), 80, "AH columns")
    eq(env.cpu:get_reg8(7), 0, "BH page")
end)

test("INT 10h rejects unknown functions", function()
    local env = new_env()
    local err = expect_error(function()
        call_int10(env, {ah = 0x99, al = 0x00})
    end, "INT 10h")
    contains(tostring(err), "0x99", "error names the AH value")

    local err2 = expect_error(function()
        env.bios:int10(nil)
    end, "cpu")
    contains(tostring(err2), "INT 10h", "error names the interrupt")
end)

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

test("refresh paints the framebuffer and can be skipped", function()
    local env = new_env()
    env.vga:clear(0x07)
    env.vga:write_cell(0, 0, "R", 0x1F)
    local cols, rows = env.bios:refresh()
    eq(cols, 51, "painted columns")
    eq(rows, 19, "painted rows")
    eq(term_char(env.term, 1, 1), "R", "terminal painted")

    -- Without a terminal refresh reports that nothing was painted.
    local headless = new_env({term = false})
    eq(headless.bios.term, nil, "no terminal attached")
    local cols2, rows2 = headless.bios:refresh()
    eq(cols2, 0, "no painted columns")
    eq(rows2, 0, "no painted rows")
end)

---------------------------------------------------------------------------
-- INT 13h: reset, parameters, seek
---------------------------------------------------------------------------

test("INT 13h AH=00 resets the disk system", function()
    local env = new_env({disk = new_disk()})
    env.cpu:set_flag("CF", true)
    call_int13(env, {ah = 0x00})
    eq(cf(env.cpu), false, "CF cleared")
    eq(ah(env.cpu), 0x00, "AH success")
end)

test("INT 13h AH=08 reports the drive geometry", function()
    local env = new_env({disk = new_disk()})
    call_int13(env, {ah = 0x08})
    eq(cf(env.cpu), false, "CF cleared")
    eq(ah(env.cpu), 0x00, "AH success")
    eq(env.cpu:get_reg8(5), 39, "CH cylinders - 1")
    eq(env.cpu:get_reg8(1), 9, "CL sectors per track")
    eq(env.cpu:get_reg8(6), 1, "DH heads - 1")
    eq(env.cpu:get_reg8(2), 0, "DL = 0")
    eq(env.cpu:get_reg8(3), 0, "BL drive type")

    -- A geometry with more than 256 cylinders needs the high bits of CL.
    local big = new_env({disk = new_disk(),
        geometry = {sectors = 18, heads = 4, cylinders = 300}})
    call_int13(big, {ah = 0x08})
    eq(big.cpu:get_reg8(5), 299 % 256, "CH cylinders - 1 (low 8 bits)")
    eq(big.cpu:get_reg8(1), 18 + 64, "CL sectors | cylinder high bits")
    eq(big.cpu:get_reg8(6), 3, "DH heads - 1")
end)

test("INT 13h AH=0C seeks to a valid CHS", function()
    local env = new_env({disk = new_disk()})
    call_int13(env, {ah = 0x0C, ch = 2, cl = 3, dh = 1, dl = 0})
    eq(cf(env.cpu), false, "CF cleared")
    eq(ah(env.cpu), 0x00, "AH success")
    eq(env.bios.last_error, nil, "no error recorded")

    call_int13(env, {ah = 0x0C, ch = 40, cl = 1, dh = 0, dl = 0})
    eq(cf(env.cpu), true, "CF set for an invalid cylinder")
    eq(ah(env.cpu), 0x04, "AH sector-not-found")
    contains(env.bios.last_error, "cylinder", "why it failed")
end)

---------------------------------------------------------------------------
-- INT 13h: reading sectors
---------------------------------------------------------------------------

test("INT 13h AH=02 reads sectors to ES:BX", function()
    local disk = new_disk()
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 4, ch = 0, cl = 2, dh = 0, dl = 0,
        es = 0x1000, bx = 0x0000})

    eq(cf(env.cpu), false, "CF cleared")
    eq(ah(env.cpu), 0x00, "AH success")
    eq(al(env.cpu), 4, "AL sectors transferred")
    eq(#disk.calls, 1, "exactly one disk read")
    eq(disk.calls[1].lba, 1, "CL=2 means LBA 1")
    eq(disk.calls[1].count, 4, "sector count")

    eq(env.memory:read8(0x10000), 1, "sector 1 first byte")
    eq(env.memory:read8(0x10000 + 511), 1, "sector 1 last byte")
    eq(env.memory:read8(0x10000 + 512), 2, "sector 2 first byte")
    eq(env.memory:read8(0x10000 + 3 * 512), 4, "sector 4 first byte")
    eq(env.memory:read8(0x10000 + 4 * 512), 0, "nothing past the transfer")
    eq(env.bios.last_error, nil, "no error recorded")
end)

test("INT 13h AH=02 converts CHS to LBA", function()
    local disk = new_disk()
    local env = new_env({disk = disk})

    -- cylinder 0, head 0, sector 1 -> LBA 0
    call_int13(env, {ah = 0x02, al = 1, ch = 0, cl = 1, dh = 0, dl = 0,
        es = 0x0000, bx = 0x0500})
    eq(disk.calls[1].lba, 0, "first sector")

    -- cylinder 0, head 1, sector 1 -> LBA 9
    call_int13(env, {ah = 0x02, al = 1, ch = 0, cl = 1, dh = 1, dl = 0,
        es = 0x0000, bx = 0x0500})
    eq(disk.calls[2].lba, 9, "next head starts after 9 sectors")

    -- cylinder 2, head 1, sector 1 -> (2*2+1)*9 = LBA 45
    call_int13(env, {ah = 0x02, al = 1, ch = 2, cl = 1, dh = 1, dl = 0,
        es = 0x0000, bx = 0x0500})
    eq(disk.calls[3].lba, 45, "cylinder and head combine")

    -- The two high cylinder bits live in CL bits 6-7.  A 40-cylinder
    -- geometry can never address them, so use a bigger geometry here.
    local big_disk = new_disk()
    big_disk.sector_count = 100000
    local big = new_env({disk = big_disk,
        geometry = {sectors = 9, heads = 2, cylinders = 300}})
    call_int13(big, {ah = 0x02, al = 1, ch = 0, cl = 0x41, dh = 0, dl = 0,
        es = 0x0000, bx = 0x0500})
    eq(cf(big.cpu), false, "CF cleared for the high-bit cylinder")
    eq(big_disk.calls[1].lba, (256 * 2 + 0) * 9,
        "cylinder high bits decoded from CL")
end)

test("INT 13h AH=02 rejects invalid CHS parameters", function()
    local disk = new_disk()
    local env = new_env({disk = disk})

    local cases = {
        {name = "sector count 0", values = {al = 0, cl = 1}},
        {name = "sector 0", values = {al = 1, cl = 0}},
        {name = "sector 10", values = {al = 1, cl = 10}},
        {name = "head 2", values = {al = 1, cl = 1, dh = 2}},
        {name = "cylinder 40", values = {al = 1, cl = 1, ch = 40}},
        {name = "cylinder from CL high bits",
            values = {al = 1, cl = 0x81, ch = 8}},
    }
    for i = 1, #cases do
        local case = cases[i]
        local values = case.values
        values.ah = 0x02
        values.dh = values.dh or 0
        values.dl = 0
        values.es = 0
        values.bx = 0
        call_int13(env, values)
        eq(cf(env.cpu), true, case.name .. ": CF set")
        eq(ah(env.cpu), 0x04, case.name .. ": AH sector not found")
        eq(env.bios.last_error ~= nil, true, case.name .. ": error recorded")
    end
    eq(#disk.calls, 0, "no disk access was attempted")
end)

test("INT 13h AH=02 rejects more than 128 sectors", function()
    local disk = new_disk()
    disk.sector_count = 1000
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 129, cl = 1, es = 0, bx = 0})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x04, "AH sector not found")
    contains(env.bios.last_error, "128", "error mentions the limit")
    eq(#disk.calls, 0, "no disk access was attempted")

    -- Exactly 128 sectors (a full 64 KiB) is legal.
    local boundary = new_env({disk = disk})
    call_int13(boundary, {ah = 0x02, al = 128, cl = 1, es = 0, bx = 0})
    eq(cf(boundary.cpu), false, "CF cleared for 128 sectors")
    eq(ah(boundary.cpu), 0x00, "AH success")
    eq(al(boundary.cpu), 128, "AL sectors transferred")
    eq(disk.calls[#disk.calls].count, 128, "one 128-sector read")
end)

test("INT 13h AH=02 honours the disk sector limit", function()
    -- A disk object that advertises its own multi-sector cap (the disk
    -- module exports MAX_SECTORS_PER_READ) shrinks the interrupt limit.
    local disk = new_disk()
    disk.sector_count = 1000
    disk.MAX_SECTORS_PER_READ = 64
    local env = new_env({disk = disk})
    eq(env.bios.max_sectors_per_read, 64, "limit taken from the disk")

    call_int13(env, {ah = 0x02, al = 65, cl = 1, es = 0, bx = 0})
    eq(cf(env.cpu), true, "CF set above the disk limit")
    eq(ah(env.cpu), 0x04, "AH sector not found")
    contains(env.bios.last_error, "64", "error names the disk limit")
    eq(#disk.calls, 0, "no disk access was attempted")

    call_int13(env, {ah = 0x02, al = 64, cl = 1, es = 0, bx = 0})
    eq(cf(env.cpu), false, "CF cleared at the disk limit")
    eq(al(env.cpu), 64, "AL sectors transferred")
    eq(disk.calls[1].count, 64, "one 64-sector read")

    -- Without such a field the BIOS limit applies.
    local plain = new_env({disk = new_disk()})
    eq(plain.bios.max_sectors_per_read, 128, "BIOS default limit")
end)

test("INT 13h AH=02 fails without a disk", function()
    local env = new_env()
    call_int13(env, {ah = 0x02, al = 1, cl = 1, es = 0, bx = 0})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x80, "AH no disk")
    contains(env.bios.last_error, "no disk", "reason recorded")
end)

test("INT 13h AH=02 reports a disk read error", function()
    local disk = new_disk()
    disk.fail_lba = 1
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 2, cl = 2, es = 0, bx = 0x0500})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x04, "AH sector not found")
    eq(al(env.cpu), 0, "AL no sectors transferred")
    contains(env.bios.last_error, "simulated read failure", "reason recorded")
    contains(env.bios.last_error, "LBA 1", "LBA in the reason")
    eq(env.memory:read8(0x0500), 0, "destination untouched")
end)

test("INT 13h AH=02 rejects a short disk response", function()
    local disk = new_disk()
    disk.bad_length = 100
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 1, cl = 1, es = 0, bx = 0x0500})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x04, "AH sector not found")
    contains(env.bios.last_error, "expected 512", "reason recorded")
end)

test("INT 13h AH=02 enforces the 64 KiB DMA boundary", function()
    local disk = new_disk()
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 1, cl = 1, es = 0x0000, bx = 0xFFF8})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x09, "AH DMA boundary crossed")
    contains(env.bios.last_error, "64 KiB", "reason recorded")
    eq(#disk.calls, 0, "no disk access was attempted")

    -- The last legal transfer that still fits below the boundary works.
    local ok_env = new_env({disk = new_disk()})
    call_int13(ok_env, {ah = 0x02, al = 1, cl = 1, es = 0x0000,
        bx = 0xF000})
    eq(cf(ok_env.cpu), false, "CF cleared below the boundary")
    eq(ah(ok_env.cpu), 0x00, "AH success")
end)

test("INT 13h AH=02 writes to the ES:BX linear address", function()
    local disk = new_disk()
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x02, al = 2, cl = 1, es = 0x2000, bx = 0x0100})
    eq(cf(env.cpu), false, "CF cleared")
    eq(env.memory:read8(0x20100), 0, "first byte at ES:BX")
    eq(env.memory:read8(0x20100 + 512), 1, "second sector at ES:BX + 512")
    eq(env.memory:read8(0x200FF), 0, "byte before ES:BX untouched")
end)

---------------------------------------------------------------------------
-- INT 13h: write protection
---------------------------------------------------------------------------

test("INT 13h AH=03 reports write protection", function()
    local disk = new_disk()
    local env = new_env({disk = disk})
    call_int13(env, {ah = 0x03, al = 1, cl = 1, es = 0, bx = 0x0600})
    eq(cf(env.cpu), true, "CF set")
    eq(ah(env.cpu), 0x03, "AH write protected")
    contains(env.bios.last_error, "read-only", "reason recorded")
    eq(#disk.calls, 0, "no disk access was attempted")
    eq(env.memory:read8(0x0600), 0, "memory untouched")
end)

test("INT 13h rejects unknown functions", function()
    local env = new_env({disk = new_disk()})
    local err = expect_error(function()
        call_int13(env, {ah = 0x55})
    end, "INT 13h")
    contains(tostring(err), "0x55", "error names the AH value")
end)

---------------------------------------------------------------------------
-- CRTC ports (0x3D4 / 0x3D5)
---------------------------------------------------------------------------

test("CRTC ports map the cursor location registers", function()
    local env = new_env()
    local cpu = env.cpu
    local write_index = cpu.ports.out[0x3D4]
    local write_data = cpu.ports.out[0x3D5]
    local read_data = cpu.ports["in"][0x3D5]

    -- Cursor location 80 == row 1, column 0.  The CPU calls an output
    -- handler as fn(cpu, size, value) and an input handler as fn(cpu, size).
    write_index(cpu, 1, 0x0E)
    write_data(cpu, 1, 0x00)
    write_index(cpu, 1, 0x0F)
    write_data(cpu, 1, 80)
    local row, col = env.vga:get_cursor()
    eq(row, 1, "cursor row from CRTC")
    eq(col, 0, "cursor column from CRTC")
    eq(env.term.cursor_y, 2, "terminal cursor follows the CRTC write")

    write_index(cpu, 1, 0x0E)
    eq(read_data(cpu, 1), 0x00, "CRTC high byte")
    write_index(cpu, 1, 0x0F)
    eq(read_data(cpu, 1), 80, "CRTC low byte")

    -- Only the cursor registers are implemented.
    expect_error(function() write_index(cpu, 1, 0x0A) end, "not implemented")
    expect_error(function() write_index(cpu, 1, 300) end, "0..255")
    expect_error(function() write_data(cpu, 1, -1) end, "0..255")
end)

---------------------------------------------------------------------------
-- Real CPU, when cpu.lua is available
--
-- cpu.lua is owned by a different module of this project; when it is on the
-- search path and passes a self-check, the interrupt handlers are driven
-- through the real register file instead of the stub above.
---------------------------------------------------------------------------

local function load_real_cpu()
    local candidates = {
        "80486-simulator/cpu.lua",
        "../cpu.lua",
        "cpu.lua",
        "/80486-simulator/cpu.lua",
        "/cpu.lua",
    }
    for i = 1, #candidates do
        local chunk = loadfile(candidates[i])
        if chunk then
            local ok, mod = pcall(chunk)
            if ok and type(mod) == "table" and type(mod.new) == "function" then
                return mod
            end
        end
    end
    return nil
end

local real_cpu = nil
local real_cpu_memory = nil
do
    local Cpu = load_real_cpu()
    if Cpu ~= nil then
        local memory = Memory.new()
        local ok, cpu = pcall(Cpu.new, {memory = memory})
        if ok and type(cpu) == "table"
            and type(cpu.get_reg8) == "function"
            and type(cpu.set_reg8) == "function"
            and type(cpu.get_sreg) == "function"
            and type(cpu.set_sreg) == "function"
            and type(cpu.get_flag) == "function"
            and type(cpu.set_flag) == "function"
            and type(cpu.set_reg16) == "function"
            and type(cpu.get_reg16) == "function"
            and type(cpu.step) == "function"
            and type(cpu.run) == "function"
        then
            -- Self-check: the register file must actually round-trip.
            local ok2 = pcall(function()
                cpu:set_reg8(4, 0x0E)
                cpu:set_reg8(0, byte("X"))
                if cpu:get_reg8(4) ~= 0x0E or cpu:get_reg8(0) ~= byte("X") then
                    error("register round trip failed")
                end
            end)
            if ok2 then
                real_cpu = cpu
                real_cpu_memory = memory
            end
        end
    end
end

if real_cpu ~= nil then
    test("real cpu runs mov/int 0x10/hlt end to end", function()
        local memory = real_cpu_memory
        local vga = Vga.new{memory = memory}
        local term = new_term(51, 19)
        local bios = Bios.new{memory = memory, vga = vga, term = term}
        bios:attach(real_cpu)

        -- Program at 0000:0500, exactly what the task asks for:
        --   B4 0E    mov ah, 0x0E   (teletype)
        --   B0 58    mov al, 'X'
        --   CD 10    int 0x10
        --   F4       hlt
        memory:write16(0x0500, 0x0EB4)
        memory:write16(0x0502, 0x58B0)
        memory:write16(0x0504, 0x10CD)
        memory:write8(0x0506, 0xF4)

        real_cpu:set_sreg("cs", 0x0000)
        real_cpu.ip = 0x0500
        real_cpu.halted = false

        local executed, reason = real_cpu:run(16)
        eq(reason, "halted", "cpu halted")
        eq(executed, 4, "four instructions executed")
        eq(real_cpu.halted, true, "halted flag set")
        eq(vga:read_char(0, 0), "X", "teletype reached the framebuffer")
        eq(vga:read_attr(0, 0), 0x07, "teletype attribute")
        eq(term_char(term, 1, 1), "X", "terminal shows the character")
        local row, col = vga:get_cursor()
        eq(row, 0, "cursor row")
        eq(col, 1, "cursor column")
    end)
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format("bios_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d bios test(s) failed", failed), 0)
end

return true
