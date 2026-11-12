---------------------------------------------------------------------------
-- 80486-simulator/tests/test_integration.lua
--
-- End-to-end integration test for the 80486 simulator stack:
--
--     CPU (cpu.lua) -> memory.lua @ 0xB8000 -> VGA (vga.lua) -> BIOS
--     (bios.lua) -> CraftOS term screen
--
-- The central proof is the first case: a real program executed by the
-- emulated CPU
--
--     mov ax, 0xB800
--     mov ds, ax
--     mov byte [0x0000], 'H'        ; == mov byte [0xB8000], 'H'
--     mov byte [0x0001], 0x07       ; light grey on black
--     hlt
--
-- must leave 'H' in the 0xB8000 text buffer AND on the CC screen after the
-- BIOS renders the VGA text buffer.
--
-- The other cases drive INT 10h (teletype / write char) and INT 13h (CHS
-- sector read through disk.lua) from real machine code, so the interrupt
-- path is exercised, not simulated from the Lua side.
--
-- Runs standalone in CraftOS:
--     dofile("/tests/test_integration.lua")
-- or from the repository root with any Lua 5.1 interpreter that can find
-- memory.lua/cpu.lua/vga.lua/bios.lua/disk.lua.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Module loading
---------------------------------------------------------------------------

local function load_module(name, candidates)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then
        return mod
    end
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and type(mod2) == "table" then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load " .. name .. ": " .. tostring(last_error))
end

local Memory = load_module("memory", {
    "80486-simulator/memory.lua",
    "../memory.lua",
    "memory.lua",
    "/80486-simulator/memory.lua",
    "/memory.lua",
})
local Cpu = load_module("cpu", {
    "80486-simulator/cpu.lua",
    "../cpu.lua",
    "cpu.lua",
    "/80486-simulator/cpu.lua",
    "/cpu.lua",
})
local Vga = load_module("vga", {
    "80486-simulator/vga.lua",
    "../vga.lua",
    "vga.lua",
    "/80486-simulator/vga.lua",
    "/vga.lua",
})
local Bios = load_module("bios", {
    "80486-simulator/bios.lua",
    "../bios.lua",
    "bios.lua",
    "/80486-simulator/bios.lua",
    "/bios.lua",
})
local Disk = load_module("disk", {
    "80486-simulator/disk.lua",
    "../disk.lua",
    "disk.lua",
    "/80486-simulator/disk.lua",
    "/disk.lua",
})

---------------------------------------------------------------------------
-- Test harness
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
    return tostring(v)
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
            label or "text", tostring(text), needle), 2)
    end
end

local function skip(reason)
    error({__skip = tostring(reason)}, 0)
end

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("ok      " .. name)
    elseif type(err) == "table" and err.__skip ~= nil then
        skipped = skipped + 1
        print("SKIP    " .. name .. " (" .. tostring(err.__skip) .. ")")
    else
        failed = failed + 1
        print("FAIL    " .. name)
        print("        " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Deterministic 512-byte sector content for the INT 13h case.
local function sector_data()
    local chunks = {}
    for i = 0, 511 do
        chunks[#chunks + 1] = string.char((i * 29 + 7) % 256)
    end
    return table.concat(chunks)
end

-- A CraftOS terminal stand-in.  It records cells and colours exactly where
-- term.blit() draws, which is what VGA rendering uses.
local function new_term(width, height)
    local term = {
        width   = width,
        height  = height,
        cursor  = {1, 1},
        blits   = 0,
        cells   = {},
        fg      = {},
        bg      = {},
    }
    for y = 1, height do
        term.cells[y] = {}
        term.fg[y] = {}
        term.bg[y] = {}
        for x = 1, width do
            term.cells[y][x] = " "
            term.fg[y][x] = "0"
            term.bg[y][x] = "f"
        end
    end

    function term.getSize()
        return width, height
    end

    function term.setCursorPos(x, y)
        term.cursor = {x, y}
    end

    function term.getCursorPos()
        return term.cursor[1], term.cursor[2]
    end

    function term.blit(text, fg, bg)
        term.blits = term.blits + 1
        local x, y = term.cursor[1], term.cursor[2]
        for i = 1, #text do
            local px = x + i - 1
            if px >= 1 and px <= width and y >= 1 and y <= height then
                term.cells[y][px] = text:sub(i, i)
                term.fg[y][px] = fg:sub(i, i)
                term.bg[y][px] = bg:sub(i, i)
            end
        end
        term.cursor = {x + #text, y}
    end

    function term.clear()
        for y = 1, height do
            for x = 1, width do
                term.cells[y][x] = " "
                term.fg[y][x] = "0"
                term.bg[y][x] = "f"
            end
        end
        term.cursor = {1, 1}
    end

    function term.write(text)
        for i = 1, #text do
            local x, y = term.cursor[1], term.cursor[2]
            if x >= 1 and x <= width and y >= 1 and y <= height then
                term.cells[y][x] = text:sub(i, i)
            end
            term.cursor = {x + 1, y}
        end
    end

    function term.setTextColor() end
    function term.setBackgroundColor() end

    return term
end

local function term_row(term, y)
    return table.concat(term.cells[y], "")
end

-- Minimal in-memory disk backend, so INT 13h can run without real files.
local function new_fake_backend()
    local backend = {
        files = {},
        dirs  = {},
    }

    local function split(path)
        return path:match("^(.*)/([^/]+)$")
    end

    function backend.add(path, data)
        local dir, name = split(path)
        backend.files[path] = data
        if dir ~= nil then
            if backend.dirs[dir] == nil then
                backend.dirs[dir] = {}
            end
            backend.dirs[dir][name] = true
        end
        return backend
    end

    function backend.size(path)
        local data = backend.files[path]
        if data == nil then
            return nil, "missing"
        end
        return #data
    end

    function backend.is_dir(path)
        return backend.dirs[path] ~= nil
    end

    function backend.list(path)
        local names = {}
        for name in pairs(backend.dirs[path] or {}) do
            names[#names + 1] = name
        end
        table.sort(names)
        return names
    end

    function backend.open(path)
        if backend.files[path] == nil then
            return nil, "missing"
        end
        return {path = path, position = 0, closed = false}
    end

    function backend.seek(handle, offset)
        if handle.closed then
            return nil, "closed"
        end
        handle.position = offset
        return offset
    end

    function backend.read(handle, count)
        if handle.closed then
            return nil, "closed"
        end
        local data = backend.files[handle.path]
        if data == nil then
            return nil, "missing"
        end
        local chunk = data:sub(handle.position + 1,
            handle.position + count)
        handle.position = handle.position + #chunk
        return chunk
    end

    function backend.close(handle)
        handle.closed = true
    end

    return backend
end

-- Writes a program at segment:0 and points the CPU at it.
local function load_program(memory, cpu, segment, bytes)
    memory:write(segment * 16, bytes)
    cpu:set_sreg("cs", segment)
    cpu.ip = 0
end

local function new_cpu(memory, bios, sleep)
    local cpu = Cpu.new{
        memory = memory,
        sleep  = sleep or function() end,
    }
    bios:attach(cpu)
    return cpu
end

---------------------------------------------------------------------------
-- 1. The required proof: MOV byte [0xB8000], 'H'
---------------------------------------------------------------------------

test("MOV byte [0xB8000], 'H' reaches VGA memory and the screen", function()
    local memory = Memory.new()
    local vga    = Vga.new{memory = memory}
    local term   = new_term(51, 19)
    local bios   = Bios.new{memory = memory, vga = vga, term = term}
    local cpu    = new_cpu(memory, bios)

    local program = string.char(
        0xB8, 0x00, 0xB8,               -- mov ax, 0xB800
        0x8E, 0xD8,                     -- mov ds, ax
        0xC6, 0x06, 0x00, 0x00, 0x48,   -- mov byte [0x0000], 'H'
        0xC6, 0x06, 0x01, 0x00, 0x07,   -- mov byte [0x0001], 0x07
        0xF4)                           -- hlt
    load_program(memory, cpu, 0x1000, program)

    local steps, reason = cpu:run(1000)
    eq(reason, "halted", "CPU halted")
    if type(steps) ~= "number" or steps < 5 then
        error("expected at least 5 executed instructions, got "
            .. tostring(steps))
    end

    -- The raw text buffer at 0xB8000.
    eq(memory:read8(0xB8000), 0x48, "VGA char byte")
    eq(memory:read8(0xB8001), 0x07, "VGA attribute byte")

    -- The VGA abstraction over the same buffer.
    eq(vga:read_char(0, 0), "H", "VGA char")
    eq(vga:read_attr(0, 0), 0x07, "VGA attr")

    -- Rendering into the (fake) CraftOS screen.
    bios:refresh()
    if term.blits < 1 then
        error("VGA rendering never called term.blit")
    end
    eq(term.cells[1][1], "H", "screen character")
    eq(term.fg[1][1], "7", "screen foreground (light grey)")
    eq(term.bg[1][1], "f", "screen background (black)")
    eq(term_row(term, 1):sub(1, 1), "H", "first row text")
end)

---------------------------------------------------------------------------
-- 2. INT 10h teletype through a real machine-code call
---------------------------------------------------------------------------

test("INT 10h teletype renders through BIOS and VGA", function()
    local memory = Memory.new()
    local vga    = Vga.new{memory = memory}
    local term   = new_term(51, 19)
    local bios   = Bios.new{memory = memory, vga = vga, term = term}
    local cpu    = new_cpu(memory, bios)

    local program = string.char(
        0xB4, 0x0E,       -- mov ah, 0x0E  (teletype)
        0xB0, 0x69,       -- mov al, 'i'
        0xCD, 0x10,       -- int 0x10
        0xF4)             -- hlt
    load_program(memory, cpu, 0x1000, program)

    local _, reason = cpu:run(100)
    eq(reason, "halted", "CPU halted")

    eq(memory:read8(0xB8000), 0x69, "teletype wrote the text buffer")
    eq(vga:read_char(0, 0), "i", "teletype wrote the VGA char")
    eq(term.cells[1][1], "i", "teletype reached the screen")

    local row, col = vga:get_cursor()
    eq(row, 0, "cursor row after teletype")
    eq(col, 1, "cursor column after teletype")
end)

---------------------------------------------------------------------------
-- 3. INT 10h write-char with an explicit attribute (colour mapping)
---------------------------------------------------------------------------

test("INT 10h write-char maps VGA colours to CraftOS colours", function()
    local memory = Memory.new()
    local vga    = Vga.new{memory = memory}
    local term   = new_term(51, 19)
    local bios   = Bios.new{memory = memory, vga = vga, term = term}
    local cpu    = new_cpu(memory, bios)

    local program = string.char(
        0xB4, 0x09,       -- mov ah, 0x09  (write char + attr)
        0xB0, 0x41,       -- mov al, 'A'
        0xB3, 0x1F,       -- mov bl, 0x1F  (white on blue)
        0xB9, 0x01, 0x00, -- mov cx, 1
        0xCD, 0x10,       -- int 0x10
        0xF4)             -- hlt
    load_program(memory, cpu, 0x1000, program)

    local _, reason = cpu:run(100)
    eq(reason, "halted", "CPU halted")

    eq(memory:read8(0xB8000), 0x41, "text buffer character")
    eq(memory:read8(0xB8001), 0x1F, "text buffer attribute")
    eq(term.cells[1][1], "A", "screen character")
    eq(term.fg[1][1], "0", "white foreground")
    eq(term.bg[1][1], "b", "blue background")
end)

---------------------------------------------------------------------------
-- 4. INT 13h reads a real sector through disk.lua
---------------------------------------------------------------------------

test("INT 13h reads a sector through disk.lua into ES:BX", function()
    local sector = sector_data()
    local backend = new_fake_backend()
    backend.add("/img_00.dat", sector)
    local disk = Disk.new{
        backend = backend,
        shards  = {"/img_00.dat"},
    }

    local memory = Memory.new()
    local vga    = Vga.new{memory = memory}
    local term   = new_term(51, 19)
    local bios   = Bios.new{
        memory = memory,
        vga    = vga,
        term   = term,
        disk   = disk,
    }
    local cpu = new_cpu(memory, bios)

    local program = string.char(
        0xB8, 0x00, 0x00,  -- mov ax, 0x0000
        0x8E, 0xC0,        -- mov es, ax
        0xBB, 0x00, 0x05,  -- mov bx, 0x0500
        0xB4, 0x02,        -- mov ah, 0x02  (read sectors)
        0xB0, 0x01,        -- mov al, 0x01  (one sector)
        0xB5, 0x00,        -- mov ch, 0x00  (cylinder 0)
        0xB1, 0x01,        -- mov cl, 0x01  (sector 1)
        0xB6, 0x00,        -- mov dh, 0x00  (head 0)
        0xB2, 0x00,        -- mov dl, 0x00  (drive 0)
        0xCD, 0x13,        -- int 0x13
        0xF4)              -- hlt
    load_program(memory, cpu, 0x1000, program)

    local _, reason = cpu:run(100)
    eq(reason, "halted", "CPU halted")

    eq(cpu:get_flag("CF"), false, "carry flag clear on success")
    eq(cpu:get_reg8(4), 0, "AH = 0 on success")
    eq(memory:read(0x0500, 512), sector, "sector landed at ES:BX")
end)

---------------------------------------------------------------------------
-- 5. INT 13h reports a real disk failure through CF/AH
---------------------------------------------------------------------------

test("INT 13h reports a disk read failure via CF and AH", function()
    local backend = new_fake_backend()
    backend.add("/img_00.dat", sector_data())
    local disk = Disk.new{
        backend = backend,
        shards  = {"/img_00.dat"},
    }

    local memory = Memory.new()
    local vga    = Vga.new{memory = memory}
    local term   = new_term(51, 19)
    local bios   = Bios.new{
        memory = memory,
        vga    = vga,
        term   = term,
        disk   = disk,
    }
    local cpu = new_cpu(memory, bios)

    -- Cylinder 5 / head 1 / sector 9 does not exist in a 40/2/9 floppy.
    local program = string.char(
        0xB4, 0x02,        -- mov ah, 0x02
        0xB0, 0x01,        -- mov al, 0x01
        0xB5, 0x05,        -- mov ch, 0x05
        0xB1, 0x09,        -- mov cl, 0x09
        0xB6, 0x01,        -- mov dh, 0x01
        0xB2, 0x00,        -- mov dl, 0x00
        0xCD, 0x13,        -- int 0x13
        0xF4)              -- hlt
    load_program(memory, cpu, 0x1000, program)

    local _, reason = cpu:run(100)
    eq(reason, "halted", "CPU halted")

    eq(cpu:get_flag("CF"), true, "carry flag set on failure")
    eq(cpu:get_reg8(4), 0x04, "AH = sector not found")
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format(
    "integration_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d integration test(s) failed", failed), 0)
end

return true
