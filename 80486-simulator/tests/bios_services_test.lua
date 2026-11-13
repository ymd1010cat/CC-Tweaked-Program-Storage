---------------------------------------------------------------------------
-- 80486-simulator/tests/bios_services_test.lua
--
-- Tests for the DOS-required firmware services added on top of the video /
-- disk / bootstrap interrupts:
--
--     INT 16h keyboard (blocking AH=00, non-blocking AH=01, shift flags)
--     INT 12h conventional memory size
--     INT 15h AH=88h extended memory size
--     INT 1Ah tick counter / real-time clock reads
--     INT 08h system timer tick
--
-- The tests drive the real CPU and BIOS modules (no stubs), injecting the
-- keyboard / clock / date sources where determinism is needed.
--
-- Runs standalone in CraftOS:
--     dofile("/tests/bios_services_test.lua")
---------------------------------------------------------------------------

local function load_module(name)
    local ok, module = pcall(require, name)
    if ok and type(module) == "table" then
        return module
    end
    local candidates = {
        name .. ".lua",
        "80486-simulator/" .. name .. ".lua",
        "/" .. name .. ".lua",
        "/80486-simulator/" .. name .. ".lua",
        "../" .. name .. ".lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, module2 = pcall(chunk)
            if ok2 and type(module2) == "table" then
                return module2
            end
            last_error = module2
        else
            last_error = err
        end
    end
    error("unable to load " .. name .. ": " .. tostring(last_error))
end

local Memory = load_module("memory")
local Cpu    = load_module("cpu")
local Vga    = load_module("vga")
local Bios   = load_module("bios")

local floor = math.floor

---------------------------------------------------------------------------
-- Harness
---------------------------------------------------------------------------

local total   = 0
local passed  = 0
local skipped = 0
local failed  = 0

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

-- Builds a real machine (memory + VGA + BIOS + CPU).  The keyboard, clock
-- and date sources are injectable for deterministic tests.
local function new_machine(opts)
    opts = opts or {}
    local memory = Memory.new()
    local vga = Vga.new{
        memory = memory,
        width  = opts.vga_width,
        height = opts.vga_height,
    }
    local clock = opts.clock or function()
        return 0
    end
    local bios = Bios.new{
        memory = memory,
        vga = vga,
        disk = opts.disk,
        term = false,
        clock = clock,
        date = opts.date,
        keyboard_pull = opts.keyboard_pull,
        keyboard_poll = opts.keyboard_poll,
        keyboard_max = opts.keyboard_max,
        conventional_kb = opts.conventional_kb,
        extended_kb = opts.extended_kb,
        equipment_word = opts.equipment_word,
    }
    local cpu = Cpu.new{memory = memory, sleep = function() end}
    bios:attach(cpu)
    return bios, cpu, memory
end

local function ax(cpu)
    return cpu:get_reg8(0) + cpu:get_reg8(4) * 256
end

local function dx(cpu)
    return cpu:get_reg8(2) + cpu:get_reg8(6) * 256
end

local function cx(cpu)
    return cpu:get_reg8(1) + cpu:get_reg8(5) * 256
end

local function set_ax(cpu, value)
    cpu:set_reg8(0, value % 256)
    cpu:set_reg8(4, floor(value / 256) % 256)
end

local function set_cx(cpu, value)
    cpu:set_reg8(1, value % 256)
    cpu:set_reg8(5, floor(value / 256) % 256)
end

local function set_dx(cpu, value)
    cpu:set_reg8(2, value % 256)
    cpu:set_reg8(6, floor(value / 256) % 256)
end

-- Writes a program at 1000:0000 and runs it until HLT.
local function run_program(cpu, memory, bytes)
    memory:write(0x10000, bytes)
    cpu:set_sreg("cs", 0x1000)
    cpu.ip = 0
    return cpu:run(100)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

test("the DOS service vectors are registered and attached", function()
    eq(Bios.INT_TIMER, 0x08, "INT 08h")
    eq(Bios.INT_EQUIPMENT, 0x11, "INT 11h")
    eq(Bios.INT_MEMORY, 0x12, "INT 12h")
    eq(Bios.INT_SYSTEM, 0x15, "INT 15h")
    eq(Bios.INT_KEYBOARD, 0x16, "INT 16h")
    eq(Bios.INT_PRINTER, 0x17, "INT 17h")
    eq(Bios.INT_TIME, 0x1A, "INT 1Ah")

    local bios, cpu = new_machine()
    local vectors = {0x08, 0x11, 0x12, 0x15, 0x16, 0x17, 0x1A}
    for i = 1, #vectors do
        local vector = vectors[i]
        eq(type(bios.interrupts[vector]), "function",
            "BIOS handler for vector " .. vector)
        eq(type(cpu.interrupts[vector]), "function",
            "CPU handler for vector " .. vector)
    end
end)

---------------------------------------------------------------------------
-- INT 11h equipment check
---------------------------------------------------------------------------

test("INT 11h reports the derived equipment word", function()
    local fake_disk = {try_read_sectors = function()
        return nil, "no disk"
    end}
    local bios, cpu, memory = new_machine{disk = fake_disk}
    local steps, reason = run_program(cpu, memory, string.char(
        0xCD, 0x11, -- int 0x11
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    if steps < 2 then
        error("INT 11h was never executed")
    end
    eq(ax(cpu), 0x0021, "AX = one floppy + 80x25 colour")
end)

test("INT 11h derives the equipment word from the hardware", function()
    eq(Bios.DEFAULT_EQUIPMENT_WORD, 0x0021, "documented default")
    local fake_disk = {try_read_sectors = function()
        return nil, "no disk"
    end}

    local bios, cpu = new_machine{}
    bios:int11(cpu)
    eq(ax(cpu), 0x0020, "no disk: bit 0 clear, 80x25 colour")

    bios, cpu = new_machine{disk = fake_disk}
    bios:int11(cpu)
    eq(ax(cpu), 0x0021, "disk: bit 0 set, 80x25 colour")

    bios, cpu = new_machine{disk = fake_disk, vga_width = 40}
    bios:int11(cpu)
    eq(ax(cpu), 0x0011, "disk + 40x25 colour video")

    bios, cpu = new_machine{equipment_word = 0x1234}
    bios:int11(cpu)
    eq(ax(cpu), 0x1234, "opts.equipment_word overrides")

    expect_error(function()
        new_machine{equipment_word = -1}
    end, "equipment_word")
    expect_error(function()
        new_machine{equipment_word = 65536}
    end, "equipment_word")
    expect_error(function()
        new_machine{equipment_word = 1.5}
    end, "equipment_word")
end)

---------------------------------------------------------------------------
-- INT 17h printer services
---------------------------------------------------------------------------

test("INT 17h reports no printer attached", function()
    eq(Bios.PRINTER_STATUS, 0x0091, "printer status constant")
    local bios, cpu, memory = new_machine()
    local steps, reason = run_program(cpu, memory, string.char(
        0xB4, 0x00, -- mov ah, 0x00 (print character)
        0xB0, 0x41, -- mov al, 'A'
        0xCD, 0x17, -- int 0x17
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    if steps < 4 then
        error("INT 17h was never executed")
    end
    local status = cpu:get_reg8(4)
    eq(status, 0x0091, "AH = no-printer status")
    eq(floor(status / 128) % 2, 1, "bit 7 = not busy")
    eq(status % 2, 1, "bit 0 = time-out")
end)

test("INT 17h accepts initialize and read-status", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(4, 0x01)
    bios:int17(cpu)
    eq(cpu:get_reg8(4), 0x0091, "initialize status")
    eq(floor(cpu:get_reg8(4) / 128) % 2, 1, "initialize bit 7 = not busy")
    cpu:set_reg8(4, 0x02)
    bios:int17(cpu)
    eq(cpu:get_reg8(4), 0x0091, "read status")
    eq(floor(cpu:get_reg8(4) / 128) % 2, 1, "read-status bit 7 = not busy")
end)

---------------------------------------------------------------------------
-- INT 12h / INT 15h memory services
---------------------------------------------------------------------------

test("INT 12h reports 640 KiB of conventional memory", function()
    local bios, cpu, memory = new_machine()
    local steps, reason = run_program(cpu, memory, string.char(
        0xCD, 0x12, -- int 0x12
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    if steps < 2 then
        error("INT 12h was never executed")
    end
    eq(ax(cpu), 640, "AX = conventional KiB")
end)

test("INT 12h honours a configured conventional size", function()
    local bios, cpu, memory = new_machine{conventional_kb = 512}
    bios:int12(cpu)
    eq(ax(cpu), 512, "configured size")
end)

test("INT 15h AH=88h reports 15 MiB of extended memory", function()
    local bios, cpu, memory = new_machine()
    local _, reason = run_program(cpu, memory, string.char(
        0xB4, 0x88, -- mov ah, 0x88
        0xCD, 0x15, -- int 0x15
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    eq(ax(cpu), 15360, "AX = extended KiB")
    eq(cpu:get_flag("CF"), false, "CF clear")
end)

test("INT 15h honours a configured extended size", function()
    local bios, cpu = new_machine{extended_kb = 1024}
    cpu:set_reg8(4, 0x88)
    bios:int15(cpu)
    eq(ax(cpu), 1024, "configured extended KiB")
end)

test("INT 15h rejects unknown functions", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(4, 0x99)
    expect_error(function() bios:int15(cpu) end, "INT 15h")
end)

---------------------------------------------------------------------------
-- INT 16h keyboard
---------------------------------------------------------------------------

test("INT 16h AH=00 blocks on the injected keyboard source", function()
    local pulls = 0
    local bios, cpu, memory = new_machine{
        keyboard_pull = function()
            pulls = pulls + 1
            return {ascii = 0x41, scan = 0x1E}
        end,
    }
    local _, reason = run_program(cpu, memory, string.char(
        0xB4, 0x00, -- mov ah, 0x00
        0xCD, 0x16, -- int 0x16
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    eq(pulls, 1, "keyboard source called once")
    eq(cpu:get_reg8(0), 0x41, "AL = ASCII")
    eq(cpu:get_reg8(4), 0x1E, "AH = scan code")
end)

test("INT 16h AH=00 drains the internal buffer first", function()
    local bios, cpu = new_machine{
        keyboard_pull = function()
            error("blocking pull must not be used while keys are queued", 0)
        end,
    }
    bios:push_key(0x1E, 0x41)
    bios:push_key(0x30, 0x42)
    eq(bios:keyboard_count(), 2, "two keys queued")

    cpu:set_reg8(4, 0x00)
    bios:int16(cpu)
    eq(cpu:get_reg8(0), 0x41, "first ASCII")
    eq(cpu:get_reg8(4), 0x1E, "first scan")
    -- AH now holds the scan code, so restore the function number.
    cpu:set_reg8(4, 0x00)
    bios:int16(cpu)
    eq(cpu:get_reg8(0), 0x42, "second ASCII")
    eq(cpu:get_reg8(4), 0x30, "second scan")
    eq(bios:keyboard_count(), 0, "buffer drained")

    cpu:set_reg8(4, 0x00)
    local err = expect_error(function() bios:int16(cpu) end,
        "blocking pull must not be used")
    contains(tostring(err), "blocking pull", "queue-first behaviour")
end)

test("INT 16h AH=01 reports an empty buffer with ZF set", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(4, 0x01)
    cpu:set_flag("ZF", false)
    bios:int16(cpu)
    eq(cpu:get_flag("ZF"), true, "ZF set when no key is pending")
    eq(bios:keyboard_count(), 0, "buffer untouched")
end)

test("INT 16h AH=01 peeks without consuming the key", function()
    local bios, cpu = new_machine()
    bios:push_key(0x1E, 0x41)
    cpu:set_reg8(4, 0x01)
    bios:int16(cpu)
    eq(cpu:get_flag("ZF"), false, "ZF clear with a key pending")
    eq(cpu:get_reg8(0), 0x41, "AL = ASCII")
    eq(cpu:get_reg8(4), 0x1E, "AH = scan")
    eq(bios:keyboard_count(), 1, "key still queued")

    cpu:set_reg8(4, 0x00)
    bios:int16(cpu)
    eq(cpu:get_reg8(0), 0x41, "AH=00 consumes the same key")
    eq(bios:keyboard_count(), 0, "buffer empty")
end)

test("INT 16h AH=01 uses the non-blocking poll hook", function()
    local polls = 0
    local bios, cpu = new_machine{
        keyboard_poll = function()
            polls = polls + 1
            return {ascii = 0x7A, scan = 0x2C}
        end,
    }
    cpu:set_reg8(4, 0x01)
    bios:int16(cpu)
    eq(polls, 1, "poll hook called")
    eq(cpu:get_flag("ZF"), false, "ZF clear after refill")
    eq(cpu:get_reg8(0), 0x7A, "AL = polled ASCII")
    eq(cpu:get_reg8(4), 0x2C, "AH = polled scan")
    eq(bios:keyboard_count(), 1, "polled key was queued")
end)

local function keys_api()
    local api = rawget(_G, "keys")
    if type(api) == "table" then
        return api
    end
    local ok, mod = pcall(require, "keys")
    if ok and type(mod) == "table" then
        _G.keys = mod
        return mod
    end
    return nil
end

-- The CraftOS event queue is shared by every test in this file.  Drain it
-- around the pump tests so a leftover timer from one test cannot be counted
-- as a key/timer seen by the next one.
local function drain_event_queue()
    local timer = os.startTimer(0)
    while true do
        local event, p1 = os.pullEventRaw()
        if event == "timer" and p1 == timer then
            break
        end
    end
end

local function pack_args(...)
    return {n = select("#", ...), ...}
end

-- Pull events until a fresh zero-delay timer marker and return them.
local function drain_until_marker()
    local marker = os.startTimer(0)
    local seen = {}
    while true do
        local args = pack_args(os.pullEventRaw())
        if args[1] == "timer" and args[2] == marker then
            break
        end
        seen[#seen + 1] = args
    end
    return seen
end

local function event_seen(events, name, first)
    for i = 1, #events do
        if events[i][1] == name
            and (first == nil or events[i][2] == first) then
            return true
        end
    end
    return false
end

test("bios:pump_events maps an Enter key event to scan 0x1C", function()
    local keysapi = keys_api()
    if keysapi == nil then
        error("CraftOS keys API is required for this test", 2)
    end
    local bios, cpu = new_machine()
    drain_event_queue()

    os.queueEvent("key", keysapi.enter)
    eq(bios:pump_events(), 1, "enter event pumped")
    eq(bios:keyboard_count(), 1, "key buffered")
    cpu:set_reg8(4, 0x01)
    bios:int16(cpu)
    eq(cpu:get_flag("ZF"), false, "DOS polling sees the key")
    eq(cpu:get_reg8(0), 0x0D, "AL = CR")
    eq(cpu:get_reg8(4), 0x1C, "AH = enter scan code")
end)

test("bios:pump_events maps a char event to ASCII and scan code", function()
    local bios, cpu = new_machine()
    drain_event_queue()

    os.queueEvent("char", "d")
    eq(bios:pump_events(), 1, "char event pumped")
    eq(bios:keyboard_count(), 1, "key buffered")
    cpu:set_reg8(4, 0x01)
    bios:int16(cpu)
    eq(cpu:get_flag("ZF"), false, "DOS polling sees the key")
    eq(cpu:get_reg8(0), 100, "AL = 'd'")
    eq(cpu:get_reg8(4), 0x20, "AH = scan code for 'd'")
end)

test("bios:pump_events re-queues non-keyboard events", function()
    local bios = new_machine()
    drain_event_queue()

    os.queueEvent("timer", 12345)
    bios:pump_events()

    -- Pull events until the re-queued timer or a short timeout appears.
    local timeout = os.startTimer(0.2)
    local found = false
    while true do
        local event, p1 = os.pullEventRaw()
        if event == "timer" and p1 == 12345 then
            found = true
            break
        end
        if event == "timer" and p1 == timeout then
            break
        end
    end
    eq(found, true, "the timer event survived the pump")
    drain_event_queue()
end)

test("bios:pump_events consumes at most 16 events per call", function()
    local bios = new_machine()
    drain_event_queue()

    for i = 1, 20 do
        os.queueEvent("char", string.char(96 + i))
    end
    eq(bios:pump_events(), 16, "first pump is capped")
    eq(bios:keyboard_count(), 16, "16 keys buffered")
    eq(bios:pump_events(), 4, "second pump drains the rest")
    eq(bios:keyboard_count(), 20, "all 20 keys buffered")
    drain_event_queue()
end)

test("sleep(0) keeps buffered keys and later events still pump", function()
    local keysapi = keys_api()
    if keysapi == nil then
        error("CraftOS keys API is required for this test", 2)
    end
    local bios = new_machine()
    drain_event_queue()

    os.queueEvent("char", "a")
    eq(bios:pump_events(), 1, "first pump")
    os.sleep(0)
    eq(bios:keyboard_count(), 1, "sleep(0) kept the buffered key")

    os.queueEvent("key", keysapi.enter)
    eq(bios:pump_events(), 1, "second pump")
    eq(bios:keyboard_count(), 2, "later event was pumped")
    drain_event_queue()
end)

test("pump stays leak-free across 1000 rounds", function()
    local bios, cpu = new_machine()
    drain_event_queue()

    for round = 1, 1000 do
        -- Every 100 rounds a timer event must be re-queued, not swallowed.
        if round % 100 == 0 then
            os.queueEvent("timer", 1)
            bios:pump_events()
            local seen = drain_until_marker()
            eq(event_seen(seen, "timer", 1), true,
                "timer re-queued at round " .. round)
        end

        -- Every 50 rounds a peripheral event must be re-queued as well.
        if round % 50 == 0 then
            os.queueEvent("peripheral", "left", "keyboard")
            bios:pump_events()
            local seen = drain_until_marker()
            eq(event_seen(seen, "peripheral", "left"), true,
                "peripheral re-queued at round " .. round)
        end

        -- One key per round: it must be pumped immediately, survive the
        -- os.sleep(0) yield and be the only key visible to INT 16h.
        eq(bios:keyboard_count(), 0, "no stale key before round " .. round)
        os.queueEvent("char", "x")
        eq(bios:pump_events() >= 1, true, "x pumped at round " .. round)
        os.sleep(0)
        eq(bios:keyboard_count(), 1, "x survived sleep at round " .. round)

        cpu:set_reg8(4, 0x01)
        bios:int16(cpu)
        eq(cpu:get_reg8(0), 120, "AL = 'x' at round " .. round)
        cpu:set_reg8(4, 0x00)
        bios:int16(cpu)
        eq(bios:keyboard_count(), 0, "x consumed at round " .. round)
    end
end)

test("bios:pump_events leaves injected keyboard sources alone", function()
    local bios, cpu = new_machine{
        keyboard_pull = function()
            return {ascii = 0x41, scan = 0x1E}
        end,
    }
    os.queueEvent("char", "z")
    eq(bios:pump_events(), 0, "no pumping with an injected source")
    eq(bios:keyboard_count(), 0, "buffer untouched")

    -- Drain the queued event so later tests start from a clean queue.
    local timer = os.startTimer(0)
    while true do
        local event, p1 = os.pullEventRaw()
        if event == "timer" and p1 == timer then break end
    end
end)

test("INT 16h AH=02 reports no shift flags", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(0, 0xFF)
    cpu:set_reg8(4, 0x02)
    bios:int16(cpu)
    eq(cpu:get_reg8(0), 0, "AL = 0 (no shift state tracked)")
end)

test("INT 16h AH=10h returns extended keys with AL=0", function()
    local bios, cpu = new_machine{
        keyboard_pull = function()
            return {ascii = 0, scan = 0x48}
        end,
    }
    cpu:set_reg8(4, 0x10)
    bios:int16(cpu)
    eq(cpu:get_reg8(0), 0x00, "AL = 0 for an extended key")
    eq(cpu:get_reg8(4), 0x48, "AH = up-arrow scan code")
end)

test("keyboard buffer overflow drops the oldest key", function()
    local bios, cpu = new_machine{keyboard_max = 3}
    for ascii = 1, 5 do
        bios:push_key(ascii + 0x10, ascii)
    end
    eq(bios:keyboard_count(), 3, "buffer capped")
    eq(bios:keyboard_dropped(), 2, "two keystrokes dropped")

    cpu:set_reg8(4, 0x00)
    for expected = 3, 5 do
        cpu:set_reg8(4, 0x00)
        bios:int16(cpu)
        eq(cpu:get_reg8(0), expected, "kept ASCII " .. expected)
    end
    eq(bios:keyboard_count(), 0, "buffer empty")
end)

test("INT 16h rejects unknown functions", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(4, 0x99)
    expect_error(function() bios:int16(cpu) end, "INT 16h")
end)

---------------------------------------------------------------------------
-- INT 1Ah / INT 08h timer services
---------------------------------------------------------------------------

test("INT 1Ah AH=00 returns ticks derived from the clock", function()
    local now = 0
    local bios, cpu, memory = new_machine{
        clock = function()
            return now
        end,
    }
    now = 1.0
    local _, reason = run_program(cpu, memory, string.char(
        0xB4, 0x00, -- mov ah, 0x00
        0xCD, 0x1A, -- int 0x1a
        0xF4))      -- hlt
    eq(reason, "halted", "halted")
    eq(cx(cpu), 0, "CX = high word")
    eq(dx(cpu), 18, "DX = 18 ticks (1 s at 18.2065 Hz)")
    eq(cpu:get_reg8(0), 0, "AL = midnight flag")
end)

test("INT 1Ah AH=01 sets the tick counter", function()
    local now = 0
    local bios, cpu = new_machine{
        clock = function()
            return now
        end,
    }
    set_cx(cpu, 1)
    set_dx(cpu, 2)
    cpu:set_reg8(4, 0x01)
    bios:int1a(cpu)

    cpu:set_reg8(4, 0x00)
    bios:int1a(cpu)
    eq(cx(cpu), 1, "CX restored")
    eq(dx(cpu), 2, "DX restored")
end)

test("INT 1Ah AH=02 returns the RTC time", function()
    local bios, cpu = new_machine{
        date = function()
            return {hour = 13, min = 45, sec = 30,
                year = 2026, month = 11, day = 12}
        end,
    }
    cpu:set_reg8(4, 0x02)
    bios:int1a(cpu)
    eq(cpu:get_flag("CF"), false, "CF = 0 (binary format)")
    eq(cpu:get_reg8(5), 13, "CH = hour")
    eq(cpu:get_reg8(1), 45, "CL = minute")
    eq(cpu:get_reg8(6), 30, "DH = second")
    eq(cpu:get_reg8(2), 0, "DL = daylight saving")
end)

test("INT 1Ah AH=04 returns the RTC date", function()
    local bios, cpu = new_machine{
        date = function()
            return {year = 2026, month = 11, day = 12,
                hour = 0, min = 0, sec = 0}
        end,
    }
    cpu:set_reg8(4, 0x04)
    bios:int1a(cpu)
    eq(cpu:get_reg8(5), 20, "CH = century")
    eq(cpu:get_reg8(1), 26, "CL = year")
    eq(cpu:get_reg8(6), 11, "DH = month")
    eq(cpu:get_reg8(2), 12, "DL = day")
end)

test("INT 1Ah rejects setting the RTC", function()
    local bios, cpu = new_machine()
    cpu:set_reg8(4, 0x03)
    expect_error(function() bios:int1a(cpu) end, "INT 1Ah")
    cpu:set_reg8(4, 0x05)
    expect_error(function() bios:int1a(cpu) end, "setting the RTC")
end)

test("INT 08h advances the same tick counter", function()
    local now = 0
    local bios, cpu, memory = new_machine{
        clock = function()
            return now
        end,
    }
    local _, reason = run_program(cpu, memory, string.char(
        0xCD, 0x08, -- int 0x08 (BIOS timer tick)
        0xF4))      -- hlt
    eq(reason, "halted", "halted")

    cpu:set_reg8(4, 0x00)
    bios:int1a(cpu)
    eq(dx(cpu), 1, "one tick after INT 08h")

    now = 0.5
    bios:int1a(cpu)
    eq(dx(cpu), 1 + floor(0.5 * 18.2065),
        "ticks continue from the INT 08h base")
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format(
    "bios_services_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d BIOS service test(s) failed", failed), 0)
end

return true
