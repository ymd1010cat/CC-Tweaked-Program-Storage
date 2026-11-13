---------------------------------------------------------------------------
-- 80486-simulator/tests/test_config_integration.lua
--
-- Integration tests for the phase-2 configuration hand-off: runner.lua reads
-- 80486.cfg (or --config=PATH), validates the [memory] / [disk] / [bios] /
-- [vga] / [watchdog] sections and passes the values to the executor modules.
--
-- Runs standalone in CraftOS:
--     dofile("/tests/test_config_integration.lua")
---------------------------------------------------------------------------

local function load_runner()
    local candidates = {
        "80486-simulator/runner.lua",
        "../runner.lua",
        "runner.lua",
        "/80486-simulator/runner.lua",
        "/runner.lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            -- A table argument selects module mode: the machine does not
            -- run at load time.
            local ok, module = pcall(chunk, {})
            if ok and type(module) == "table"
                and type(module.new) == "function" then
                return module
            end
            last_error = module
        else
            last_error = err
        end
    end
    error("unable to load runner.lua: " .. tostring(last_error))
end

local function load_module(name, is_module)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" and is_module(mod) then
        return mod
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
            local ok2, mod2 = pcall(chunk)
            if ok2 and type(mod2) == "table" and is_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load " .. name .. ".lua: " .. tostring(last_error))
end

local Runner = load_runner()
local Memory = load_module("memory", function(mod)
    return type(mod.new) == "function" and mod.PAGE_SIZE == 4096
end)
local Cpu = load_module("cpu", function(mod)
    return type(mod.new) == "function" and mod.SLEEP_INTERVAL == 200
end)

local concat = table.concat

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

-- Replaces print() for one call and collects every line; the first return
-- value is the joined output, the second the function's own result.
local function capture(fn)
    local lines = {}
    local real_print = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    local ok, result = pcall(fn)
    _G.print = real_print
    if not ok then
        error(result, 0)
    end
    return table.concat(lines, "\n"), result
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
-- Test doubles
---------------------------------------------------------------------------

-- Minimal in-memory disk backend (same shape the runner and disk tests use).
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

-- program: mov ax,0xB800 / mov ds,ax / mov byte [0],'B' / attr / hlt
local BOOT_PROGRAM = string.char(
    0xB8, 0x00, 0xB8,
    0x8E, 0xD8,
    0xC6, 0x06, 0x00, 0x00, 0x42,
    0xC6, 0x06, 0x01, 0x00, 0x07,
    0xF4)

local function make_boot_sector(program)
    program = program or ""
    local sector = program .. string.rep("\0", 512 - #program)
    sector = sector:sub(1, 510) .. string.char(0x55, 0xAA)
    return sector
end

-- Builds a machine from a parsed config table (nil means "no config file",
-- which still applies the documented defaults) with a fake disk backend.
local function mount(config, opts)
    opts = opts or {}
    local backend = new_fake_backend()
    backend.add("/img_00.dat", opts.sector or make_boot_sector(BOOT_PROGRAM))
    local machine = Runner.new{
        config = config,
        disk_opts = {backend = backend, shards = {"/img_00.dat"}},
        term = false,
        sleep = opts.sleep or function() end,
        slice = opts.slice or 1000,
        max_steps = opts.max_steps,
    }
    return machine, backend
end

-- Boot program that issues INT 13h AH=02 (read sectors) with AL=count and
-- then halts.  Used to exercise the real interrupt path through the CPU.
--   * SP is first moved to 0x7000: the reset stack at SS:SP=0000:0000 grows
--     down from 0xFFFF, which would sit inside the 32 KiB DMA range.
--   * The destination is 0x8000: 64 sectors fill 0x8000..0xFFFF, inside the
--     64 KiB DMA window and clear of both the boot sector at 0x7C00 and the
--     relocated stack (0x6FFx).
local function int13_boot_program(count)
    return string.char(
        0xBC, 0x00, 0x70,  -- mov sp, 0x7000
        0xB4, 0x02,        -- mov ah, 0x02
        0xB0, count,       -- mov al, count
        0xB5, 0x00,        -- mov ch, 0
        0xB1, 0x01,        -- mov cl, 1
        0xB6, 0x00,        -- mov dh, 0
        0xB2, 0x00,        -- mov dl, 0
        0xBB, 0x00, 0x80,  -- mov bx, 0x8000
        0xCD, 0x13,        -- int 0x13
        0xF4)              -- hlt
end

-- 65-sector image (one boot sector plus 64 zero sectors) with a configured
-- multi-sector read cap of 64.
local function int13_machine(count)
    local sector = make_boot_sector(int13_boot_program(count))
    local backend = new_fake_backend()
    backend.add("/img_00.dat", sector .. string.rep("\0", 64 * 512))
    local machine = Runner.new{
        config = {disk = {max_sectors_per_read = 64}},
        disk_opts = {backend = backend, shards = {"/img_00.dat"}},
        term = false,
        sleep = function() end,
        max_steps = 100,
    }
    return machine, sector
end

local function warning_index(warnings, text)
    for i = 1, #warnings do
        if warnings[i] == text then
            return i
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- CraftOS filesystem helpers (the CLI reads real files)
---------------------------------------------------------------------------

local fsapi = rawget(_G, "fs")

local function has_fs()
    return type(fsapi) == "table" and type(fsapi.open) == "function"
end

local function fs_write(path, data)
    local handle, err = fsapi.open(path, "wb")
    if handle == nil then
        error("cannot write " .. path .. ": " .. tostring(err))
    end
    handle.write(data)
    handle.close()
end

local function fs_read(path)
    local handle, err = fsapi.open(path, "rb")
    if handle == nil then
        error("cannot read " .. path .. ": " .. tostring(err))
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function fs_remove(path)
    pcall(fsapi.delete, path)
end

-- Writes a bootable one-sector shard at an explicit path.  CLI tests pass
-- --shards= so they never touch the shared /disk directory that the runner
-- test already uses (and whose open shard handles can block deletion).
local function write_shard(path)
    fs_write(path, make_boot_sector(BOOT_PROGRAM))
end

---------------------------------------------------------------------------
-- Config hand-off to the modules
---------------------------------------------------------------------------

test("config sections reach every module", function()
    local machine = mount({
        memory = {protect_start = 0xE0000, protect_end = 0xEFFFF},
        disk = {read_only = true, max_sectors_per_read = 64},
        bios = {check_boot_signature = false},
        vga = {width = 40, height = 25},
        watchdog = {max_tick = 7},
    })

    local protect_start, protect_end = machine.memory:get_write_protection()
    eq(protect_start, 0xE0000, "memory protect_start")
    eq(protect_end, 0xEFFFF, "memory protect_end")
    eq(machine.disk:get_max_sectors_per_read(), 64, "disk read cap")
    eq(machine.disk:is_read_only(), true, "disk read_only")
    eq(machine.bios.check_boot_signature, false, "bios signature check")
    eq(machine.vga.width, 40, "vga width")
    eq(machine.vga.height, 25, "vga height")
    eq(machine.cpu.watchdog_max_tick, 7, "watchdog max_tick")
    eq(#machine.warnings, 0, "no warnings")

    local steps, reason = machine:run(1000)
    eq(reason, "halted", "machine still boots")
    eq(steps, 5, "boot program instruction count")
end)

test("default config protects the BIOS ROM window", function()
    local machine = mount(nil)

    local protect_start, protect_end = machine.memory:get_write_protection()
    eq(protect_start, 0xF0000, "default protect_start")
    eq(protect_end, 0xFFFFF, "default protect_end")
    eq(#machine.warnings, 0, "defaults are quiet")

    local err = expect_error(function()
        machine.memory:write8(0xF0000, 0x90)
    end, "Memory Write Protection Fault")
    contains(tostring(err), "0xF0000", "fault names the address")

    expect_error(function()
        machine.memory:write16(0xEFFFF, 0x9090)
    end, "Memory Write Protection Fault")
    expect_error(function()
        machine.memory:write32(0xFFFFC, 0)
    end, "Memory Write Protection Fault")
    expect_error(function()
        machine.memory:write(0xF0000, "AB")
    end, "Memory Write Protection Fault")
    expect_error(function()
        machine.memory:fill(0xF8000, 16, 0x90)
    end, "Memory Write Protection Fault")
    expect_error(function()
        machine.memory:copy(0xF0000, 0, 2)
    end, "Memory Write Protection Fault")

    -- Reads and neighbouring writes are unaffected.
    eq(machine.memory:read8(0xF0000), 0, "protected memory reads as zero")
    machine.memory:write8(0xEFFFF, 0x11)
    eq(machine.memory:read8(0xEFFFF), 0x11, "write below the window")
    machine.memory:write8(0x100000, 0x22)
    eq(machine.memory:read8(0x100000), 0x22, "write above the window")
end)

test("custom protection window blocks the BIOS boot write", function()
    local machine = mount({
        memory = {protect_start = 0x7C00, protect_end = 0x7DFF},
    })
    local err = expect_error(function()
        machine:boot()
    end, "Memory Write Protection Fault")
    contains(tostring(err), "0x7C00", "boot address is protected")
    eq(machine.booted, false, "machine did not boot")
end)

test("read_only=true rejects disk writes", function()
    local machine = mount({disk = {read_only = true}})
    local err = expect_error(function()
        machine.disk:write_sector(0, string.rep("\1", 512))
    end, "read-only")
    contains(tostring(err), "read_only=true", "config key is named")

    local default_machine = mount(nil)
    expect_error(function()
        default_machine.disk:write_sector(0, string.rep("\1", 512))
    end, "read-only")
end)

test("read_only=false warns and keeps the safe default", function()
    local machine = mount({disk = {read_only = false}})
    eq(machine.disk:is_read_only(), true, "writes stay rejected")
    eq(warning_index(machine.warnings,
        "WARN: Config [disk.read_only] is not implemented yet: "
        .. "write-back is not implemented"), 1, "read_only=false warning")
    eq(#machine.warnings, 1, "single warning")
    contains(machine.warnings[1], "write-back is not implemented",
        "warning uses the disk.lua wording")
    expect_error(function()
        machine.disk:write_sector(0, string.rep("\1", 512))
    end, "read-only")
end)

test("max_sectors_per_read reaches disk and BIOS", function()
    local backend = new_fake_backend()
    local image = make_boot_sector(BOOT_PROGRAM) .. string.rep("\0", 64 * 512)
    backend.add("/img_00.dat", image)
    local machine = Runner.new{
        config = {disk = {max_sectors_per_read = 64}},
        disk_opts = {backend = backend, shards = {"/img_00.dat"}},
        term = false,
        sleep = function() end,
    }

    eq(machine.disk:get_max_sectors_per_read(), 64, "disk cap")
    eq(machine.disk.MAX_SECTORS_PER_READ, 64, "BIOS-visible cap")
    eq(machine.bios.max_sectors_per_read, 64, "BIOS limit")

    local data, reason = machine.disk:try_read_sectors(0, 64)
    eq(type(data), "string", "64 sectors are accepted")
    eq(#data, 64 * 512, "64 sector payload")

    data, reason = machine.disk:try_read_sectors(0, 65)
    eq(data, nil, "65 sectors are rejected")
    contains(tostring(reason), "64", "configured cap is reported")

    local default_machine = mount(nil)
    eq(default_machine.disk:get_max_sectors_per_read(), 128, "default cap")
    eq(default_machine.disk.MAX_SECTORS_PER_READ, 128, "default BIOS cap")
end)

test("disk image config becomes the shard chain", function()
    local backend = new_fake_backend()
    backend.add("/images/dos212.img", make_boot_sector(BOOT_PROGRAM))
    local machine = Runner.new{
        config = {disk = {image = "/images/dos212.img"}},
        disk_opts = {backend = backend},
        term = false,
        sleep = function() end,
    }
    eq(machine.disk:get_shard(1).path, "/images/dos212.img",
        "image shard path")
    local steps, reason = machine:run(100)
    eq(reason, "halted", "image boots")
    eq(steps, 5, "boot program instructions")

    -- An explicit shard list still overrides the configured image.
    local other = new_fake_backend()
    other.add("/other/img_00.dat", make_boot_sector(BOOT_PROGRAM))
    local override = Runner.new{
        config = {disk = {image = "/images/dos212.img"}},
        disk_opts = {backend = other, shards = {"/other/img_00.dat"}},
        term = false,
        sleep = function() end,
    }
    eq(override.disk:get_shard(1).path, "/other/img_00.dat",
        "explicit shards win")
end)

test("bios check_boot_signature follows the config", function()
    local unsigned = string.rep("\0", 512)
    local machine = mount({bios = {check_boot_signature = true}},
        {sector = unsigned})
    local err = expect_error(function()
        machine:boot()
    end, "not bootable")
    contains(tostring(err), "0xAA55", "signature hint")

    local lenient = mount({bios = {check_boot_signature = false}},
        {sector = unsigned})
    eq(lenient:boot(), 0, "lenient CS")
    eq(lenient.cpu.ip, 0x7C00, "lenient IP")
end)

test("unimplemented options warn but do not stop the machine", function()
    local machine = mount({
        cpu = {enable_xms = true, target_mhz = 66},
        vga = {screen_mode = "monitor", width = 80, height = 25},
    })

    eq(#machine.warnings, 3, "three warnings")
    -- pairs() order is not defined, so only presence is checked here.
    eq(warning_index(machine.warnings,
        "WARN: Config [cpu.enable_xms] is not implemented yet") ~= nil, true,
        "enable_xms warning")
    eq(warning_index(machine.warnings,
        "WARN: Config [cpu.target_mhz] is not implemented yet") ~= nil, true,
        "target_mhz warning")
    eq(warning_index(machine.warnings,
        "WARN: Config [vga.screen_mode] is not implemented yet") ~= nil, true,
        "screen_mode warning")

    local steps, reason = machine:run(1000)
    eq(reason, "halted", "machine still boots")
    eq(steps, 5, "default logic still runs")
end)

test("default-valued unimplemented options are quiet", function()
    local machine = mount({
        cpu = {enable_xms = false, target_mhz = 33},
        vga = {screen_mode = "text"},
    })
    eq(#machine.warnings, 0, "documented defaults do not warn")

    -- Older config files may keep enable_xms in [memory]; the documented
    -- default must stay quiet there too, while a changed value still warns.
    local quiet = mount({memory = {enable_xms = false}})
    eq(#quiet.warnings, 0, "default in another section is quiet")
    local loud = mount({memory = {enable_xms = true}})
    eq(warning_index(loud.warnings,
        "WARN: Config [memory.enable_xms] is not implemented yet") ~= nil,
        true, "changed value in another section warns")
end)

---------------------------------------------------------------------------
-- Watchdog semantics
---------------------------------------------------------------------------

test("watchdog max_tick=-1 keeps the instruction-based yield", function()
    local sleeps = {}
    local cpu = Cpu.new{
        memory = Memory.new(0x10000),
        sleep = function(seconds) sleeps[#sleeps + 1] = seconds end,
        watchdog_max_tick = -1,
    }
    eq(cpu.watchdog_max_tick, -1, "watchdog disabled")
    -- EB FE = jmp $ at 0000:0000.
    cpu.memory:write(0, string.char(0xEB, 0xFE))

    local steps, reason = cpu:run(1000)
    eq(steps, 1000, "bounded instruction count")
    eq(reason, "limit", "stop reason")
    eq(#sleeps, 5, "sleep(0) every 200 instructions")
    for i = 1, #sleeps do
        eq(sleeps[i], 0, "sleep argument " .. i)
    end

    local machine = mount({watchdog = {max_tick = -1}})
    eq(machine.cpu.watchdog_max_tick, -1, "config disables the watchdog")
end)

test("watchdog max_tick>0 trips after a forced yield", function()
    local sleeps = {}
    local ticks = 0
    local cpu = Cpu.new{
        memory = Memory.new(0x10000),
        sleep = function(seconds) sleeps[#sleeps + 1] = seconds end,
        sleep_interval = 5,
        watchdog_max_tick = 1,
        clock = function()
            ticks = ticks + 0.1
            return ticks
        end,
    }
    cpu.memory:write(0, string.char(0xEB, 0xFE))

    local err = expect_error(function()
        cpu:run(10000)
    end, "watchdog")
    contains(tostring(err), "max_tick=1", "tick count in the message")
    contains(tostring(err), "0.05", "computed timeout in the message")

    if #sleeps < 2 then
        error("the watchdog must force a sleep(0) before raising", 2)
    end
    for i = 1, #sleeps do
        eq(sleeps[i], 0, "forced yield argument " .. i)
    end
end)

test("invalid watchdog values are rejected", function()
    local err = expect_error(function()
        Runner.new{config = {watchdog = {max_tick = 0}}}
    end, "max_tick")
    contains(tostring(err), "must be -1", "accepted values are reported")

    expect_error(function()
        Runner.new{config = {watchdog = {max_tick = -2}}}
    end, "max_tick")
end)

---------------------------------------------------------------------------
-- Validation of config values
---------------------------------------------------------------------------

test("invalid config values are rejected clearly", function()
    expect_error(function()
        Runner.new{config = {memory = {protect_start = "F0000"}}}
    end, "protect_start")

    expect_error(function()
        Runner.new{config = {
            memory = {protect_start = 0xFFFFF, protect_end = 0xF0000},
        }}
    end, "must be <=")

    expect_error(function()
        Runner.new{config = {disk = {max_sectors_per_read = 0}}}
    end, "max_sectors_per_read")

    expect_error(function()
        Runner.new{config = {disk = {read_only = "yes"}}}
    end, "read_only")

    expect_error(function()
        Runner.new{config = {bios = {check_boot_signature = 1}}}
    end, "check_boot_signature")

    expect_error(function()
        Runner.new{config = {disk = {image = 42}}}
    end, "image")
end)

---------------------------------------------------------------------------
-- Config file loading
---------------------------------------------------------------------------

test("missing config file reports a clear error", function()
    local empty_fs = {
        exists = function() return false end,
        open = function() return nil, "missing" end,
    }
    local cfg, err = Runner.load_config("/no_such_80486.cfg", empty_fs)
    eq(cfg, nil, "load_config failure")
    contains(tostring(err), "config file not found", "clear diagnostic")
    contains(tostring(err), "/no_such_80486.cfg", "path in the diagnostic")

    local out, result = capture(function()
        return Runner.run_cli({"--config=/no_such_80486.cfg", "--headless"})
    end)
    eq(result, false, "cli failure return value")
    contains(out, "config file", "cli prints a config error")
    if has_fs() then
        contains(out, "not found", "cli reports the missing file")
    end
end)

test("malformed config file reports the parser line number", function()
    local bad_text = "[memory\nprotect_start=0xF0000\n"
    local bad_fs = {
        exists = function() return true end,
        open = function()
            return {
                readAll = function() return bad_text end,
                close = function() end,
            }
        end,
    }
    local cfg, err = Runner.load_config("/bad.cfg", bad_fs)
    eq(cfg, nil, "load_config failure")
    contains(tostring(err), "invalid", "parse failure diagnostic")
    contains(tostring(err), "config_parser: line 1", "line number is kept")

    if has_fs() then
        fs_write("/tests_bad.cfg", bad_text)
        local out, result = capture(function()
            return Runner.run_cli({"--config=/tests_bad.cfg", "--headless"})
        end)
        fs_remove("/tests_bad.cfg")
        eq(result, false, "cli failure return value")
        contains(out, "config_parser: line 1", "cli keeps the line number")
    end
end)

test("runner reads the default 80486.cfg", function()
    eq(Runner.DEFAULT_CONFIG, "80486.cfg", "documented default name")
    if not has_fs() then
        return
    end

    local cfg, err = Runner.load_config(Runner.DEFAULT_CONFIG)
    eq(type(cfg), "table", "default config parses: " .. tostring(err))
    eq(type(cfg.memory), "table", "memory section")
    eq(cfg.memory.protect_start, 0xF0000, "protect_start")
    eq(cfg.memory.protect_end, 0xFFFFF, "protect_end")
    eq(type(cfg.watchdog), "table", "watchdog section")
    eq(cfg.watchdog.max_tick, -1, "watchdog disabled")

    local shard = "/tests_boot_default.dat"
    write_shard(shard)
    local out, result = capture(function()
        return Runner.run_cli({"--shards=" .. shard, "--headless",
            "--max-steps=1000"})
    end)
    fs_remove(shard)
    eq(result, "halted", "boots with the default config")
    contains(out, "runner: running", "startup message")
end)

test("cli prints unimplemented config warnings", function()
    if not has_fs() then
        return
    end
    local shard = "/tests_boot_warn.dat"
    write_shard(shard)
    fs_write("/tests_warn.cfg", concat({
        "[cpu]",
        "target_mhz=66",
        "enable_xms=true",
        "[bios]",
        "check_boot_signature=true",
    }, "\n") .. "\n")
    local out, result = capture(function()
        return Runner.run_cli({"--config=/tests_warn.cfg",
            "--shards=" .. shard, "--headless", "--max-steps=1000"})
    end)
    fs_remove("/tests_warn.cfg")
    fs_remove(shard)

    eq(result, "halted", "machine still boots")
    contains(out, "WARN: Config [cpu.target_mhz] is not implemented yet",
        "target_mhz warning on startup")
    contains(out, "WARN: Config [cpu.enable_xms] is not implemented yet",
        "enable_xms warning on startup")
end)

test("INT 13h honours max_sectors_per_read", function()
    -- AL=64: success, CF=0, AH=0 and 64 sectors DMA'd to 0x8000.
    local machine, sector = int13_machine(64)
    local steps, reason = machine:run(100)
    eq(reason, "halted", "halted after INT 13h")
    eq(steps, 10, "ten instructions executed")
    eq(machine.cpu:get_flag("CF"), false, "CF cleared on success")
    eq(machine.cpu:get_reg8(4), 0x00, "AH = 0 on success")
    eq(machine.cpu:get_reg8(0), 64, "AL = 64 sectors")
    eq(machine.memory:read(0x8000, 512), sector, "DMA payload is sector 0")
    eq(machine.bios.last_error, nil, "no disk error recorded")

    -- AL=65: rejected by the configured cap before the disk is touched.
    local failing = int13_machine(65)
    local fail_steps, fail_reason = failing:run(100)
    eq(fail_reason, "halted", "halted after the rejected transfer")
    eq(fail_steps, 10, "ten instructions executed")
    eq(failing.cpu:get_flag("CF"), true, "CF set on failure")
    eq(failing.cpu:get_reg8(4), 0x04, "AH = 0x04 sector not found")
    eq(failing.memory:read(0x8000, 512), string.rep("\0", 512),
        "destination untouched")
    contains(tostring(failing.bios.last_error), "64", "limit in the reason")
end)

test("block writes across the protection boundary are rejected", function()
    local machine = mount(nil)
    local memory = machine.memory

    expect_error(function()
        memory:write(0xEFFF0, string.rep("\1", 17))
    end, "Memory Write Protection Fault")
    expect_error(function()
        memory:fill(0xEFFF0, 17, 0x5A)
    end, "Memory Write Protection Fault")
    expect_error(function()
        memory:copy(0xEFFFD, 0, 4)
    end, "Memory Write Protection Fault")
    expect_error(function()
        memory:write32(0xFFFFD, 0x11223344)
    end, "Memory Write Protection Fault")

    -- The guard runs before the store, so nothing leaked into RAM.
    eq(memory:read8(0xEFFF0), 0, "first byte below the window untouched")
    eq(memory:read8(0xEFFFF), 0, "last unprotected byte untouched")
    eq(memory:read8(0xF0000), 0, "first protected byte untouched")
end)

test("missing default config is a fail-fast error", function()
    if not has_fs() then
        return
    end
    local paths = {"/80486.cfg", "/80486-simulator/80486.cfg"}
    local saved = {}
    for i = 1, #paths do
        saved[i] = fs_read(paths[i])
    end
    for i = 1, #paths do
        fs_remove(paths[i])
    end

    local out, result = capture(function()
        return Runner.run_cli({"--headless", "--max-steps=1"})
    end)

    -- Restore before asserting: a failed assertion must not leave the staged
    -- default config missing for any later test.
    for i = 1, #paths do
        fs_write(paths[i], saved[i])
    end

    eq(result, false, "run_cli fails without the default config")
    contains(out, "config file not found", "clear diagnostic")
    contains(out, "searched", "search list is reported")
    contains(out, "80486-simulator/80486.cfg", "search path is listed")
    contains(out, "/80486-simulator/80486.cfg", "absolute path is listed")
end)

test("cli warns about screen_mode=monitor", function()
    if not has_fs() then
        return
    end
    local shard = "/tests_boot_vga.dat"
    write_shard(shard)
    fs_write("/tests_vga.cfg", concat({
        "[vga]",
        "screen_mode=monitor",
        "width=80",
        "height=25",
        "[bios]",
        "check_boot_signature=true",
    }, "\n") .. "\n")
    local out, result = capture(function()
        return Runner.run_cli({"--config=/tests_vga.cfg",
            "--shards=" .. shard, "--headless", "--max-steps=1000"})
    end)
    fs_remove("/tests_vga.cfg")
    fs_remove(shard)

    eq(result, "halted", "machine still boots in text mode")
    contains(out, "WARN: Config [vga.screen_mode] is not implemented yet",
        "screen_mode warning printed")
end)

---------------------------------------------------------------------------

print(string.format(
    "config_integration_test: %d total, %d passed, 0 skipped, %d failed",
    total, passed, failed))

if failed > 0 then
    error(string.format("%d config integration test(s) failed", failed), 0)
end

return true
