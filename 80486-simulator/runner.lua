---------------------------------------------------------------------------
-- 80486-simulator/runner.lua
--
-- Machine entry point for the 80486 simulator: it wires the memory, disk,
-- VGA, BIOS and CPU modules together, boots from sector 0 of the sharded
-- local DOS image through INT 19h and then runs the machine while keeping
-- the CraftOS terminal and the VGA text buffer in sync.
--
-- What happens on boot
-- --------------------
--   1. Disk.new() mounts the sharded image.  The shard files are either
--      discovered in the search directories (/disk, /disk2, ...) or given
--      explicitly; checksums are verified when expected values exist.
--   2. Vga.new() maps the 0xB8000 text plane of the same memory object.
--   3. Bios.new() + Bios:attach(cpu) install INT 10h, INT 13h and INT 19h.
--   4. INT 19h reads sector 0 into memory at 0x0000:0x7C00, verifies the
--      0xAA55 signature and hands control to CS:IP = 0000:7C00.
--   5. The main loop runs fixed-size instruction slices, renders the VGA
--      text plane to the terminal after every slice and calls sleep(0) so
--      CraftOS can service events (the CPU also yields every 200
--      instructions itself).
--
-- Usage from the CraftOS shell
-- ----------------------------
--     runner                          -- auto-discover shards (see disk.lua)
--     runner /disk                    -- use /disk, or /disk,/disk5
--     runner --dirs=/disk,/disk2      -- explicit search directories
--     runner --shards=/disk/img_00.dat,/disk2/img_01.dat
--     runner --cache=64               -- sector cache size
--     runner --max-steps=2000000      -- stop after N instructions
--     runner --slice=2000             -- instructions between render/sleep
--     runner --geometry=9,2,40        -- floppy geometry used by INT 13h
--     runner --headless               -- do not render to the terminal
--     runner --no-signature-check     -- accept boot sectors without 0xAA55
--     runner --help
--
-- As a module (tests, other programs)
-- -----------------------------------
--     local Runner = loadfile("runner.lua")({})
--     local machine = Runner.new{
--         disk = disk,            -- optional; otherwise built from disk_opts
--         disk_opts = {dirs = {"/disk"}},
--         term = term,            -- optional; false/nil disables rendering
--         sleep = function(s) end,
--         slice = 2000,
--     }
--     machine:boot()              -- INT 19h
--     local steps, reason = machine:run(max_steps)
--
-- The runner is a program, not a library to require(): loading it with a
-- table argument returns the module table without executing the machine.
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
    error("runner: unable to load module " .. name .. ": "
        .. tostring(last_error), 0)
end

local Memory = load_module("memory")
local Disk   = load_module("disk")
local Vga    = load_module("vga")
local Bios   = load_module("bios")
local Cpu    = load_module("cpu")

---------------------------------------------------------------------------
-- Module table and constants
---------------------------------------------------------------------------

local Runner = {}
Runner.__index = Runner

Runner.SECTOR_SIZE       = 512
Runner.BOOT_ADDRESS      = Bios.BOOT_ADDRESS or 0x7C00
Runner.BOOT_SIGNATURE    = Bios.BOOT_SIGNATURE or 0xAA55
Runner.DEFAULT_SLICE     = 2000
Runner.MAX_SLICE         = 1000000

local function is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

local function split_list(text)
    local items = {}
    for item in tostring(text):gmatch("[^,]+") do
        local trimmed = item:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            items[#items + 1] = trimmed
        end
    end
    return items
end

---------------------------------------------------------------------------
-- Command line parsing
---------------------------------------------------------------------------

local USAGE = table.concat({
    "usage: runner [DIR[,DIR...]] [options]",
    "",
    "Boots the sharded local DOS image from sector 0 (INT 19h).",
    "",
    "options:",
    "  --dirs=a,b              shard search directories",
    "  --shards=p1,p2          explicit shard file list",
    "  --manifest=path         CRC32 manifest (default: image.crc32 in a shard dir)",
    "  --cache=N               sector cache size (default 64, max 4096)",
    "  --slice=N               instructions per render/sleep cycle",
    "  --max-steps=N           stop after N instructions",
    "  --geometry=S,H,C        floppy geometry for INT 13h (default 9,2,40)",
    "  --headless              do not render to the CraftOS terminal",
    "  --no-signature-check    accept a boot sector without 0xAA55",
    "  --help                  show this text",
}, "\n")

-- Parses shell arguments into runner options.  Returns opts, or nil, error.
function Runner.parse_args(args)
    if type(args) ~= "table" then
        return nil, "arguments must be a table"
    end
    local opts = {disk_opts = {}}
    local dirs = {}
    local shards = nil
    local index = 1

    local function take_value(prefix)
        local raw = args[index]:sub(#prefix + 1)
        if raw == "" then
            return nil, "option " .. prefix .. " needs a value"
        end
        return raw, nil
    end

    while index <= #args do
        local argument = tostring(args[index])
        if argument == "--help" or argument == "-h" then
            opts.help = true
        elseif argument == "--headless" or argument == "--no-render" then
            opts.headless = true
        elseif argument == "--no-signature-check" then
            opts.check_boot_signature = false
        elseif argument:sub(1, 7) == "--dirs=" then
            local raw, err = take_value("--dirs=")
            if raw == nil then return nil, err end
            dirs = split_list(raw)
        elseif argument:sub(1, 9) == "--shards=" then
            local raw, err = take_value("--shards=")
            if raw == nil then return nil, err end
            shards = split_list(raw)
        elseif argument:sub(1, 11) == "--manifest=" then
            local raw, err = take_value("--manifest=")
            if raw == nil then return nil, err end
            opts.manifest = raw
        elseif argument:sub(1, 8) == "--cache=" then
            local raw = argument:match("^%-%-cache=(%d+)$")
            if raw == nil then
                return nil, "--cache needs a positive integer"
            end
            opts.disk_opts.cache_sectors = tonumber(raw)
        elseif argument:sub(1, 8) == "--slice=" then
            local raw = argument:match("^%-%-slice=(%d+)$")
            if raw == nil then
                return nil, "--slice needs a positive integer"
            end
            opts.slice = tonumber(raw)
        elseif argument:sub(1, 12) == "--max-steps=" then
            local raw = argument:match("^%-%-max%-steps=(%d+)$")
            if raw == nil then
                return nil, "--max-steps needs a positive integer"
            end
            opts.max_steps = tonumber(raw)
        elseif argument:sub(1, 11) == "--geometry=" then
            local raw, err = take_value("--geometry=")
            if raw == nil then return nil, err end
            local sectors, heads, cylinders = raw:match(
                "^(%d+),(%d+),(%d+)$")
            if sectors == nil then
                return nil, "--geometry needs SECTORS,HEADS,CYLINDERS"
            end
            opts.geometry = {
                sectors   = tonumber(sectors),
                heads     = tonumber(heads),
                cylinders = tonumber(cylinders),
            }
        elseif argument == "--" then
            index = index + 1
            while index <= #args do
                local extra = split_list(tostring(args[index]))
                for i = 1, #extra do
                    dirs[#dirs + 1] = extra[i]
                end
                index = index + 1
            end
            break
        elseif argument:sub(1, 1) == "-" then
            return nil, "unknown option: " .. argument
        else
            local list = split_list(argument)
            for i = 1, #list do
                dirs[#dirs + 1] = list[i]
            end
        end
        index = index + 1
    end

    if #dirs > 0 then
        opts.disk_opts.dirs = dirs
    end
    if shards ~= nil then
        opts.disk_opts.shards = shards
    end
    return opts
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function build_disk(opts)
    local disk_opts = {}
    local source = opts.disk_opts
    if source ~= nil then
        if type(source) ~= "table" then
            error("runner.new: opts.disk_opts must be a table", 0)
        end
        for key, value in pairs(source) do
            disk_opts[key] = value
        end
    end
    -- Convenience aliases at the top level.
    if opts.dirs ~= nil and disk_opts.dirs == nil then
        disk_opts.dirs = opts.dirs
    end
    if opts.shards ~= nil and disk_opts.shards == nil then
        disk_opts.shards = opts.shards
    end
    if opts.cache_sectors ~= nil and disk_opts.cache_sectors == nil then
        disk_opts.cache_sectors = opts.cache_sectors
    end
    if opts.prefix ~= nil and disk_opts.prefix == nil then
        disk_opts.prefix = opts.prefix
    end
    if opts.suffix ~= nil and disk_opts.suffix == nil then
        disk_opts.suffix = opts.suffix
    end
    if opts.checksums ~= nil and disk_opts.checksums == nil then
        disk_opts.checksums = opts.checksums
    end
    if opts.manifest ~= nil and disk_opts.manifest == nil then
        disk_opts.manifest = opts.manifest
    end
    return Disk.new(disk_opts)
end

function Runner.new(opts)
    if opts == nil then
        opts = {}
    end
    if type(opts) ~= "table" then
        error("runner.new: opts must be a table (got " .. type(opts)
            .. ")", 0)
    end

    local term = opts.term
    if term == nil and opts.headless ~= true then
        term = rawget(_G, "term")
    end
    if term == false then
        term = nil
    end
    if term ~= nil and type(term) ~= "table" then
        error("runner.new: opts.term must be a terminal table or false", 0)
    end

    local sleep = opts.sleep
    if sleep == nil then
        sleep = rawget(_G, "os") and os.sleep or function() end
    end
    if type(sleep) ~= "function" then
        error("runner.new: opts.sleep must be a function", 0)
    end

    local slice = opts.slice
    if slice == nil then
        slice = Runner.DEFAULT_SLICE
    end
    if not is_integer(slice) or slice < 1 or slice > Runner.MAX_SLICE then
        error("runner.new: opts.slice must be an integer 1.."
            .. Runner.MAX_SLICE .. " (got " .. tostring(slice) .. ")", 0)
    end

    if opts.max_steps ~= nil
        and (not is_integer(opts.max_steps) or opts.max_steps < 1) then
        error("runner.new: opts.max_steps must be a positive integer", 0)
    end

    local memory = opts.memory
    if memory == nil then
        memory = Memory.new()
    end

    local disk = opts.disk
    if disk == nil then
        disk = build_disk(opts)
    end

    local vga = opts.vga
    if vga == nil then
        vga = Vga.new{memory = memory}
    end

    local bios = opts.bios
    if bios == nil then
        -- Bios.new() falls back to _G.term when term is nil; pass false for
        -- an explicitly headless machine so the BIOS never paints the real
        -- terminal behind the runner's back.
        local bios_term = term
        if bios_term == nil then
            bios_term = false
        end
        bios = Bios.new{
            memory = memory,
            vga = vga,
            disk = disk,
            term = bios_term,
            geometry = opts.geometry,
            log = opts.log,
            boot_drive = opts.boot_drive,
            check_boot_signature = opts.check_boot_signature,
        }
    end

    local cpu = opts.cpu
    if cpu == nil then
        cpu = Cpu.new{memory = memory, sleep = sleep}
    end

    if type(bios.attach) == "function" then
        bios:attach(cpu)
    end

    return setmetatable({
        memory    = memory,
        disk      = disk,
        vga       = vga,
        bios      = bios,
        cpu       = cpu,
        term      = term,
        sleep     = sleep,
        slice     = slice,
        max_steps = opts.max_steps,
        booted    = false,
        renders   = 0,
        slices    = 0,
    }, Runner)
end

---------------------------------------------------------------------------
-- Boot and execution
---------------------------------------------------------------------------

-- INT 19h: load sector 0 to 0x0000:0x7C00 and jump to it.  Raises when the
-- image cannot be read or the boot signature is missing.
function Runner:boot()
    if self.booted then
        return self.cpu.seg.cs, self.cpu.ip
    end
    self.bios:int19(self.cpu)
    self.booted = true
    return self.cpu.seg.cs, self.cpu.ip
end

-- Render the VGA text plane to the terminal (no-op in headless mode).
function Runner:render()
    if self.term == nil then
        return 0, 0
    end
    self.renders = self.renders + 1
    return self.vga:render(self.term)
end

-- Runs the machine.  Each slice executes up to self.slice instructions, then
-- the screen is refreshed and sleep(0) yields to CraftOS.  max_steps == nil
-- means "until HLT or an error"; pass a number to bound a run.
function Runner:run(max_steps)
    if max_steps == nil then
        max_steps = self.max_steps
    end
    if max_steps ~= nil
        and (not is_integer(max_steps) or max_steps < 1) then
        error("runner.run: max_steps must be a positive integer or nil", 0)
    end

    if not self.booted then
        self:boot()
    end

    local executed = 0
    self:render()

    while max_steps == nil or executed < max_steps do
        if self.cpu.halted then
            self:render()
            return executed, "halted"
        end

        local budget = self.slice
        if max_steps ~= nil and max_steps - executed < budget then
            budget = max_steps - executed
        end

        local steps, reason = self.cpu:run(budget)
        executed = executed + steps
        self.slices = self.slices + 1
        self:render()
        self.sleep(0)

        if reason == "halted" then
            return executed, "halted"
        end
        if steps == 0 then
            -- No instruction could be executed: report it instead of
            -- spinning forever inside the main loop.
            return executed, "stalled"
        end
    end

    self:render()
    return executed, "limit"
end

function Runner:status()
    local status = {
        booted  = self.booted,
        halted  = self.cpu.halted,
        steps   = self.cpu.steps,
        cs      = self.cpu.seg.cs,
        ip      = self.cpu.ip,
        slices  = self.slices,
        renders = self.renders,
    }
    if type(self.disk.get_size) == "function" then
        status.image_bytes = self.disk:get_size()
        status.sectors = self.disk:get_sector_count()
        status.shards = self.disk:get_shard_count()
    end
    return status
end

---------------------------------------------------------------------------
-- Program entry point
---------------------------------------------------------------------------

local function format_count(value)
    if type(value) ~= "number" then
        return tostring(value)
    end
    return tostring(value)
end

local function program_main(args)
    local opts, err = Runner.parse_args(args)
    if opts == nil then
        print("runner: " .. tostring(err))
        print(USAGE)
        return false
    end
    if opts.help then
        print(USAGE)
        return true
    end

    local ok, machine_or_error = pcall(Runner.new, opts)
    if not ok then
        print("runner: cannot initialise the machine: "
            .. tostring(machine_or_error))
        return false
    end
    local machine = machine_or_error
    local disk = machine.disk

    if type(disk.get_size) == "function" then
        print(string.format(
            "runner: image %s bytes, %s sector(s), %s shard(s)",
            format_count(disk:get_size()), format_count(disk:get_sector_count()),
            format_count(disk:get_shard_count())))
        if type(disk.info) == "function" then
            local info = disk:info()
            if info.integrity and info.integrity.verified then
                print(string.format(
                    "runner: CRC32 verified for %d/%d shard(s)",
                    info.integrity.checked, info.integrity.total))
            else
                print("runner: warning: no shard checksums configured "
                    .. "(integrity not verified)")
            end
        end
    end

    local boot_ok, boot_error = pcall(machine.boot, machine)
    if not boot_ok then
        print("runner: boot failed: " .. tostring(boot_error))
        return false
    end
    print(string.format(
        "runner: INT 19h loaded sector 0 at 0x%05X, CS:IP=%04X:%04X",
        Runner.BOOT_ADDRESS, machine.cpu.seg.cs, machine.cpu.ip))

    print("runner: running (Ctrl+T to stop)")
    local steps, reason = machine:run(opts.max_steps)
    print(string.format(
        "runner: stopped after %s instruction(s) (%s), CS:IP=%04X:%04X",
        format_count(steps), tostring(reason),
        machine.cpu.seg.cs, machine.cpu.ip))
    return reason
end

-- Exposed for tests and for embedding: runs the command line entry point
-- with an argument table (same strings the shell would pass).
Runner.run_cli = program_main

---------------------------------------------------------------------------
-- Execution when loaded as a program
---------------------------------------------------------------------------

local ENV = ...

if type(ENV) ~= "table" then
    local args = {}
    local arg_count = select("#", ...)
    for i = 1, arg_count do
        local value = select(i, ...)
        if value ~= nil then
            args[#args + 1] = tostring(value)
        end
    end
    if #args == 0 and type(arg) == "table" and arg[1] ~= nil then
        for i = 1, #arg do
            args[#args + 1] = tostring(arg[i])
        end
    end
    return program_main(args)
end

return Runner
