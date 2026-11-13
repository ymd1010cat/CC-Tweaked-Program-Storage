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
--   1. The machine configuration (80486.cfg by default) is read and parsed
--      by config_parser.lua.  A missing or malformed file is a fatal error:
--      the runner never falls back to silent defaults.  Options that are not
--      implemented yet print a WARN line and are ignored.
--   2. Disk.new() mounts the sharded image.  The shard files are either
--      discovered in the search directories (/disk, /disk2, ...) or given
--      explicitly; checksums are verified when expected values exist.
--   3. Vga.new() maps the 0xB8000 text plane of the same memory object.
--   4. Memory.new() applies the configured write-protection window (default
--      0xF0000..0xFFFFF, the BIOS ROM area); writes there raise
--      "Memory Write Protection Fault".
--   5. Bios.new() + Bios:attach(cpu) install INT 10h, INT 13h and INT 19h.
--   6. INT 19h reads sector 0 into memory at 0x0000:0x7C00, verifies the
--      0xAA55 signature and hands control to CS:IP = 0000:7C00.
--   7. The main loop runs fixed-size instruction slices, renders the VGA
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
--     runner --config=/path/80486.cfg -- explicit config file
--     runner --cache=64               -- sector cache size
--     runner --max-steps=2000000      -- stop after N instructions
--     runner --slice=2000             -- instructions between render/sleep
--     runner --geometry=9,2,40        -- floppy geometry used by INT 13h
--     runner --headless               -- do not render to the terminal
--     runner --no-signature-check     -- accept boot sectors without 0xAA55
--     runner --help
--
-- Configuration (80486.cfg)
-- -------------------------
-- A minimal INI file parsed by config_parser.lua; see that module for the
-- exact value syntax.  Recognised keys:
--
--     [memory]
--     protect_start=0xF0000      write-protected window start
--     protect_end=0xFFFFF        write-protected window end
--
--     [disk]
--     read_only=true             reject every disk write (default true)
--     max_sectors_per_read=128   multi-sector read cap (default 128)
--     image=/path/to/dos.img     single-file shard (optional; an explicit
--                                --shards= or --dirs= still wins)
--
--     [bios]
--     check_boot_signature=true  require 0xAA55 in the boot sector
--
--     [vga]
--     width=80                   text plane width in cells
--     height=25                  text plane height in cells
--     base=0xB8000               text plane physical base address
--     attr=7                     default attribute byte
--
--     [watchdog]
--     max_tick=-1                -1 disables the timeout watchdog;
--                                N > 0 grants N * 0.05 seconds of run time
--
-- Unimplemented options ([cpu] enable_xms, [cpu] target_mhz,
-- [vga] screen_mode, ...) print "WARN: Config [section.key] is not
-- implemented yet" when set away from their documented default, and are then
-- ignored: an old config file never crashes the machine.
--
-- As a module (tests, other programs)
-- -----------------------------------
--     local Runner = loadfile("runner.lua")({})
--     local machine = Runner.new{
--         config = parsed_config, -- optional; parsed 80486.cfg table
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
local Config = load_module("config_parser")

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
Runner.DEFAULT_CONFIG    = "80486.cfg"
Runner.DEFAULT_PROTECT_START = 0xF0000
Runner.DEFAULT_PROTECT_END   = 0xFFFFF
Runner.DEFAULT_MAX_SECTORS_PER_READ = Disk.MAX_SECTORS_PER_READ or 128
Runner.DEFAULT_WATCHDOG_MAX_TICK    = -1

local function is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

---------------------------------------------------------------------------
-- Configuration handling
---------------------------------------------------------------------------

-- Sections and keys the runner implements today.  Every other key is an
-- unimplemented option: it is reported as a WARN when it carries a
-- non-default value and then ignored, so old config files keep working.
local IMPLEMENTED_KEYS = {
    memory   = {protect_start = true, protect_end = true},
    disk     = {read_only = true, max_sectors_per_read = true, image = true},
    bios     = {check_boot_signature = true},
    vga      = {width = true, height = true, base = true, attr = true},
    watchdog = {max_tick = true},
}

-- Documented defaults of the options that are not implemented yet.  A config
-- that explicitly spells out one of these defaults must not warn.  The by-key
-- table is a fallback for older configs that put a known option in another
-- section (for example [memory] enable_xms instead of [cpu] enable_xms).
local UNIMPLEMENTED_DEFAULTS = {
    ["cpu.enable_xms"]   = false,
    ["cpu.target_mhz"]   = 33,
    ["vga.screen_mode"]  = "text",
}
local UNIMPLEMENTED_DEFAULTS_BY_KEY = {
    enable_xms  = false,
    target_mhz  = 33,
    screen_mode = "text",
}

local function config_error(section, key, message)
    error("config [" .. section .. "] " .. key .. ": " .. message, 0)
end

local function config_section(config, name)
    local section = config[name]
    if section == nil then
        return nil
    end
    if type(section) ~= "table" then
        error("config section [" .. name .. "] must be a table (got "
            .. type(section) .. ")", 0)
    end
    return section
end

local function config_bool(config, name, key, default)
    local section = config_section(config, name)
    if section == nil or section[key] == nil then
        return default
    end
    local value = section[key]
    if type(value) ~= "boolean" then
        config_error(name, key, "must be true or false (got "
            .. type(value) .. ")")
    end
    return value
end

local function config_integer(config, name, key, default, minimum, maximum)
    local section = config_section(config, name)
    if section == nil or section[key] == nil then
        return default
    end
    local value = section[key]
    if not is_integer(value) or value < minimum or value > maximum then
        config_error(name, key, "must be an integer " .. tostring(minimum)
            .. ".." .. tostring(maximum) .. " (got "
            .. tostring(value) .. ")")
    end
    return value
end

local function config_optional_integer(config, name, key, minimum, maximum)
    local section = config_section(config, name)
    if section == nil or section[key] == nil then
        return nil
    end
    local value = section[key]
    if not is_integer(value) or value < minimum or value > maximum then
        config_error(name, key, "must be an integer " .. tostring(minimum)
            .. ".." .. tostring(maximum) .. " (got "
            .. tostring(value) .. ")")
    end
    return value
end

-- Validates the parsed config and turns it into the option table the module
-- constructors need.  Unknown keys become WARN strings in the result; they
-- never stop a boot.
local function resolve_config(config)
    if config == nil then
        config = {}
    end
    if type(config) ~= "table" then
        error("runner.new: opts.config must be a parsed configuration table "
            .. "(got " .. type(config) .. ")", 0)
    end

    local warnings = {}
    local warned = {}
    local function warn_unimplemented(section, key)
        local id = section .. "." .. key
        if warned[id] then
            return
        end
        warned[id] = true
        warnings[#warnings + 1] = "WARN: Config [" .. id
            .. "] is not implemented yet"
    end

    local protect_start = config_integer(config, "memory", "protect_start",
        Runner.DEFAULT_PROTECT_START, 0, Memory.MAX_SIZE - 1)
    local protect_end = config_integer(config, "memory", "protect_end",
        Runner.DEFAULT_PROTECT_END, 0, Memory.MAX_SIZE - 1)
    if protect_start > protect_end then
        config_error("memory", "protect_start",
            "must be <= protect_end")
    end

    local read_only = config_bool(config, "disk", "read_only", true)
    if not read_only then
        -- Write-back is not implemented (same wording as disk.lua); keep the
        -- default safety behaviour and warn instead of crashing.
        warned["disk.read_only"] = true
        warnings[#warnings + 1] = "WARN: Config [disk.read_only] is not "
            .. "implemented yet: write-back is not implemented"
        read_only = true
    end
    local max_read = config_integer(config, "disk", "max_sectors_per_read",
        Runner.DEFAULT_MAX_SECTORS_PER_READ, 1,
        Disk.MAX_CACHE_SECTORS or 4096)

    -- Single-file image path; disk.lua treats it as a one-shard chain.
    local disk_image = nil
    local disk_section = config_section(config, "disk")
    if disk_section ~= nil and disk_section.image ~= nil then
        disk_image = disk_section.image
        if type(disk_image) ~= "string" or disk_image == "" then
            config_error("disk", "image", "must be a non-empty path string")
        end
    end

    local check_signature = config_bool(config, "bios",
        "check_boot_signature", true)

    local watchdog_max_tick = Runner.DEFAULT_WATCHDOG_MAX_TICK
    local watchdog_section = config_section(config, "watchdog")
    if watchdog_section ~= nil and watchdog_section.max_tick ~= nil then
        watchdog_max_tick = watchdog_section.max_tick
        if not is_integer(watchdog_max_tick)
            or (watchdog_max_tick ~= -1 and watchdog_max_tick < 1) then
            config_error("watchdog", "max_tick",
                "must be -1 (disabled) or a positive integer (got "
                .. tostring(watchdog_max_tick) .. ")")
        end
    end

    local vga_width = config_optional_integer(config, "vga", "width", 1, 1000)
    local vga_height = config_optional_integer(config, "vga", "height", 1, 1000)
    local vga_base = config_optional_integer(config, "vga", "base", 0,
        Memory.MAX_SIZE - 1)
    local vga_attr = config_optional_integer(config, "vga", "attr", 0, 255)

    -- Anything left over is an unimplemented option (or an unknown section).
    for section_name, section in pairs(config) do
        if type(section) ~= "table" then
            error("config section [" .. tostring(section_name)
                .. "] must be a table (got " .. type(section) .. ")", 0)
        end
        local implemented = IMPLEMENTED_KEYS[section_name] or {}
        for key, value in pairs(section) do
            if not implemented[key] then
                local default = UNIMPLEMENTED_DEFAULTS[section_name
                    .. "." .. key]
                if default == nil then
                    default = UNIMPLEMENTED_DEFAULTS_BY_KEY[key]
                end
                if default == nil or value ~= default then
                    warn_unimplemented(tostring(section_name), tostring(key))
                end
            end
        end
    end

    return {
        memory_protect_start = protect_start,
        memory_protect_end = protect_end,
        disk_read_only = read_only,
        disk_max_sectors_per_read = max_read,
        disk_image = disk_image,
        bios_check_boot_signature = check_signature,
        vga_width = vga_width,
        vga_height = vga_height,
        vga_base = vga_base,
        vga_attr = vga_attr,
        watchdog_max_tick = watchdog_max_tick,
        warnings = warnings,
    }
end

local function read_all(handle)
    if type(handle.readAll) == "function" then
        return handle.readAll()
    end
    local parts = {}
    while true do
        local chunk = handle.read(4096)
        if chunk == nil or chunk == "" then
            break
        end
        parts[#parts + 1] = chunk
    end
    return table.concat(parts)
end

-- load_config(path, fsapi) -> parsed table, or nil, error message.
-- fsapi is optional so tests can inject a fake filesystem.
function Runner.load_config(path, fsapi)
    if type(path) ~= "string" or path == "" then
        return nil, "config path must be a non-empty string"
    end
    if fsapi == nil then
        fsapi = rawget(_G, "fs")
    end
    if type(fsapi) ~= "table" or type(fsapi.open) ~= "function" then
        return nil, "config file '" .. path
            .. "' cannot be read: no filesystem available"
    end
    if type(fsapi.exists) == "function" and not fsapi.exists(path) then
        return nil, "config file not found: " .. path
    end
    local handle, open_error = fsapi.open(path, "rb")
    if handle == nil then
        return nil, "config file '" .. path .. "' cannot be opened: "
            .. tostring(open_error)
    end
    local ok, content = pcall(function()
        return read_all(handle)
    end)
    pcall(handle.close, handle)
    if not ok then
        return nil, "config file '" .. path .. "' cannot be read: "
            .. tostring(content)
    end
    if type(content) ~= "string" then
        return nil, "config file '" .. path .. "' did not return text"
    end
    local parsed_ok, parsed = pcall(Config.parse, content)
    if not parsed_ok then
        return nil, "config file '" .. path .. "' is invalid: "
            .. tostring(parsed)
    end
    return parsed
end

-- load_default_config(path, fsapi) -> parsed table, or nil, error message.
-- With no explicit path the documented default file names are searched.
function Runner.load_default_config(path, fsapi)
    if path ~= nil then
        return Runner.load_config(path, fsapi)
    end
    local candidates = {
        Runner.DEFAULT_CONFIG,
        "80486-simulator/" .. Runner.DEFAULT_CONFIG,
        "/" .. Runner.DEFAULT_CONFIG,
        "/80486-simulator/" .. Runner.DEFAULT_CONFIG,
    }
    for i = 1, #candidates do
        local parsed, error_text = Runner.load_config(candidates[i], fsapi)
        if parsed ~= nil then
            return parsed, candidates[i]
        end
        if type(error_text) ~= "string"
            or not error_text:find("not found", 1, true) then
            return nil, error_text
        end
    end
    return nil, "config file not found: " .. Runner.DEFAULT_CONFIG
        .. " (searched " .. table.concat(candidates, ", ") .. ")"
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
    "  --config=PATH           machine config (default: 80486.cfg)",
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
        elseif argument:sub(1, 9) == "--config=" then
            local raw, err = take_value("--config=")
            if raw == nil then return nil, err end
            opts.config_path = raw
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

local function build_disk(opts, base)
    local disk_opts = {}
    -- Config-derived defaults first; explicit disk_opts / CLI aliases win.
    if base ~= nil then
        for key, value in pairs(base) do
            disk_opts[key] = value
        end
    end
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

    -- Resolve the parsed config early: a bad value is a hard error before
    -- any disk file is opened, and unimplemented options become warnings.
    local config = resolve_config(opts.config)

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
        memory = Memory.new(nil, {
            protect_start = config.memory_protect_start,
            protect_end   = config.memory_protect_end,
        })
    end

    local disk = opts.disk
    if disk == nil then
        local disk_base = {
            read_only            = config.disk_read_only,
            max_sectors_per_read = config.disk_max_sectors_per_read,
        }
        -- The config image is only a default: an explicit shard list or
        -- search directory from the command line (or an embedding caller)
        -- takes precedence.
        local explicit = opts.dirs ~= nil or opts.shards ~= nil
        if type(opts.disk_opts) == "table"
            and (opts.disk_opts.dirs ~= nil
                or opts.disk_opts.shards ~= nil) then
            explicit = true
        end
        if config.disk_image ~= nil and not explicit then
            disk_base.shards = {config.disk_image}
        end
        disk = build_disk(opts, disk_base)
    end

    local vga = opts.vga
    if vga == nil then
        vga = Vga.new{
            memory = memory,
            width  = config.vga_width,
            height = config.vga_height,
            base   = config.vga_base,
            attr   = config.vga_attr,
        }
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
        -- An explicit option (for example --no-signature-check) overrides the
        -- config file, because it is the more specific request.
        local bios_check = config.bios_check_boot_signature
        if opts.check_boot_signature ~= nil then
            bios_check = opts.check_boot_signature
        end
        bios = Bios.new{
            memory = memory,
            vga = vga,
            disk = disk,
            term = bios_term,
            geometry = opts.geometry,
            log = opts.log,
            boot_drive = opts.boot_drive,
            check_boot_signature = bios_check,
        }
    end

    -- Every yield must first move already-queued CraftOS key/char events into
    -- the BIOS keyboard buffer: os.sleep(0) discards non-timer events, so a
    -- key typed between yields would otherwise be lost forever.  The required
    -- sleep call itself is kept unchanged underneath.
    local base_sleep = sleep
    local function sleep_with_events(seconds)
        if bios ~= nil and type(bios.pump_events) == "function" then
            bios:pump_events()
        end
        base_sleep(seconds)
    end

    local cpu = opts.cpu
    if cpu == nil then
        cpu = Cpu.new{
            memory = memory,
            sleep = sleep_with_events,
            watchdog_max_tick = config.watchdog_max_tick,
        }
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
        sleep     = sleep_with_events,
        slice     = slice,
        max_steps = opts.max_steps,
        booted    = false,
        renders   = 0,
        slices    = 0,
        config    = config,
        warnings  = config.warnings,
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

    -- Load the machine config before touching any disk.  A missing or
    -- malformed file is a fatal startup error: never run on silent defaults.
    local parsed_config, config_error = Runner.load_default_config(
        opts.config_path)
    if parsed_config == nil then
        print("runner: " .. tostring(config_error))
        return false
    end
    opts.config = parsed_config

    local ok, machine_or_error = pcall(Runner.new, opts)
    if not ok then
        print("runner: cannot initialise the machine: "
            .. tostring(machine_or_error))
        return false
    end
    local machine = machine_or_error
    for i = 1, #machine.warnings do
        print(machine.warnings[i])
    end
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
    -- A watchdog trip (or any other execution error) must give a clear
    -- diagnostic and a clean exit instead of a raw CraftOS stack trace.
    local run_ok, steps, reason = pcall(machine.run, machine, opts.max_steps)
    if not run_ok then
        print("runner: run failed: " .. tostring(steps))
        return false
    end
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
