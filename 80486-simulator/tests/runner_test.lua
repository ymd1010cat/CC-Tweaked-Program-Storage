---------------------------------------------------------------------------
-- 80486-simulator/tests/runner_test.lua
--
-- Tests for runner.lua (the machine entry point) and its INT 19h bootstrap
-- chain: shard loading from a specified path, sector 0 -> 0x0000:0x7C00,
-- CS:IP hand-over without an IRET, the render/sleep main loop and the
-- command line parser.
--
-- Runs standalone in CraftOS:
--     dofile("/tests/runner_test.lua")
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

local Runner = load_runner()

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

-- Minimal in-memory disk backend (same shape as the one used by the disk
-- tests), so the runner can mount an image without real shard files.
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

local function new_term(width, height)
    local term = {
        width  = width,
        height = height,
        cursor = {1, 1},
        blits  = 0,
        cells  = {},
        fg     = {},
        bg     = {},
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

    function term.setTextColor() end
    function term.setBackgroundColor() end

    return term
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

-- Builds a machine with one shard holding `sector`.
local function mount_sector(sector, opts)
    opts = opts or {}
    local backend = new_fake_backend()
    backend.add("/img_00.dat", sector)
    local machine = Runner.new{
        disk_opts = {backend = backend, shards = {"/img_00.dat"}},
        term = opts.term or false,
        sleep = opts.sleep or function() end,
        slice = opts.slice or 1000,
        max_steps = opts.max_steps,
        check_boot_signature = opts.check_boot_signature,
    }
    return machine, backend
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

test("runner wires memory, disk, VGA, BIOS and CPU together", function()
    local machine = mount_sector(make_boot_sector(BOOT_PROGRAM))
    eq(type(machine.memory), "table", "memory")
    eq(type(machine.disk), "table", "disk")
    eq(type(machine.vga), "table", "vga")
    eq(type(machine.bios), "table", "bios")
    eq(type(machine.cpu), "table", "cpu")
    eq(machine.booted, false, "not booted yet")

    eq(type(machine.bios.interrupts[0x10]), "function", "INT 10h handler")
    eq(type(machine.bios.interrupts[0x13]), "function", "INT 13h handler")
    eq(type(machine.bios.interrupts[0x19]), "function", "INT 19h handler")
    eq(type(machine.cpu.interrupts[0x10]), "function", "CPU INT 10h")
    eq(type(machine.cpu.interrupts[0x13]), "function", "CPU INT 13h")
    eq(type(machine.cpu.interrupts[0x19]), "function", "CPU INT 19h")
end)

test("INT 19h loads sector 0 to 0x0000:0x7C00", function()
    local sector = make_boot_sector(BOOT_PROGRAM)
    local machine = mount_sector(sector)

    local cs, ip = machine:boot()
    eq(cs, 0, "CS")
    eq(ip, 0x7C00, "IP")
    eq(machine.booted, true, "booted flag")
    eq(machine.bios.boot_count, 1, "boot count")
    eq(machine.cpu:get_reg8(2), 0, "DL = boot drive")
    eq(machine.memory:read(0x7C00, 512), sector, "boot sector in memory")
    eq(machine.memory:read8(0x7C00 + 510), 0x55, "signature byte 0")
    eq(machine.memory:read8(0x7C00 + 511), 0xAA, "signature byte 1")
end)

test("boot sector executes and reaches the VGA screen", function()
    local term = new_term(51, 19)
    local sleeps = {}
    local machine = mount_sector(make_boot_sector(BOOT_PROGRAM), {
        term = term,
        sleep = function(seconds)
            sleeps[#sleeps + 1] = seconds
        end,
    })

    local steps, reason = machine:run(1000)
    eq(reason, "halted", "stop reason")
    eq(steps, 5, "executed instructions")

    eq(machine.memory:read8(0xB8000), 0x42, "VGA character byte")
    eq(machine.memory:read8(0xB8001), 0x07, "VGA attribute byte")
    eq(machine.vga:read_char(0, 0), "B", "VGA character")
    eq(term.cells[1][1], "B", "screen character")

    if #sleeps < 1 then
        error("the main loop never called sleep(0)")
    end
    for i = 1, #sleeps do
        eq(sleeps[i], 0, "sleep argument " .. i)
    end
    if machine.renders < 1 then
        error("the main loop never rendered the screen")
    end
end)

test("INT 19h executed as an instruction skips the implicit IRET", function()
    local machine = mount_sector(make_boot_sector(BOOT_PROGRAM))

    -- Run "int 0x19" from a scratch program; the BIOS handler must hand
    -- control to 0x7C00 instead of returning to the next instruction.
    machine.memory:write(0x10000, string.char(0xCD, 0x19))
    machine.cpu:set_sreg("cs", 0x1000)
    machine.cpu.ip = 0

    local steps, reason = machine.cpu:run(100)
    eq(reason, "halted", "boot program halted")
    eq(machine.cpu.steps < 20, true, "did not fall through to garbage")
    eq(machine.cpu.seg.cs, 0, "CS after boot")
    eq(machine.memory:read8(0xB8000), 0x42, "boot program ran")
end)

test("a non-bootable sector is refused", function()
    local sector = string.rep("\0", 512) -- no 0xAA55 signature
    local machine = mount_sector(sector)
    local err = expect_error(function() machine:boot() end, "not bootable")
    contains(tostring(err), "0xAA55", "signature hint")
    eq(machine.booted, false, "still not booted")

    -- Explicitly disabled signature checking accepts the same sector.
    local lenient = mount_sector(sector, {check_boot_signature = false})
    eq(lenient:boot(), 0, "lenient CS")
    eq(lenient.cpu.ip, 0x7C00, "lenient IP")
end)

test("a missing boot sector reports the disk error", function()
    local machine = Runner.new{
        disk = {
            try_read_sectors = function()
                return nil, "injected disk failure"
            end,
        },
        term = false,
        sleep = function() end,
    }
    local err = expect_error(function() machine:boot() end,
        "cannot read the boot sector")
    contains(tostring(err), "injected disk failure", "root cause")
end)

test("headless mode never touches a terminal", function()
    local machine = mount_sector(make_boot_sector(BOOT_PROGRAM), {
        term = false,
    })
    eq(machine.term, nil, "no terminal")
    local steps, reason = machine:run(1000)
    eq(reason, "halted", "halted")
    eq(machine.renders, 0, "no renders")
    eq(machine.memory:read8(0xB8000), 0x42, "VGA memory still written")
end)

test("an endless boot sector obeys max_steps", function()
    -- EB FE = jmp $ (infinite loop) placed at 0x7C00.
    local machine = mount_sector(
        make_boot_sector(string.char(0xEB, 0xFE)))
    local steps, reason = machine:run(500)
    eq(reason, "limit", "stop reason")
    eq(steps, 500, "bounded instruction count")
end)

---------------------------------------------------------------------------
-- Image loading from a specified path
---------------------------------------------------------------------------

test("mounts shards from the directory given to the runner", function()
    local backend = new_fake_backend()
    backend.add("/dos/image/img_00.dat",
        make_boot_sector(BOOT_PROGRAM))
    local machine = Runner.new{
        disk_opts = {backend = backend, dirs = {"/dos/image"}},
        term = false,
        sleep = function() end,
    }
    eq(machine.disk:get_shard(1).path, "/dos/image/img_00.dat",
        "shard path")
    eq(machine:status().shards, 1, "status shard count")
    eq(machine:status().sectors, 1, "status sector count")
    local steps, reason = machine:run(100)
    eq(reason, "halted", "booted from the specified directory")
    eq(steps, 5, "boot program instructions")
end)

test("mounts an explicit shard list given to the runner", function()
    local backend = new_fake_backend()
    backend.add("/media/disk_a.dat", make_boot_sector(BOOT_PROGRAM))
    local machine = Runner.new{
        disk_opts = {
            backend = backend,
            shards = {"/media/disk_a.dat"},
        },
        term = false,
        sleep = function() end,
    }
    eq(machine.disk:get_shard(1).path, "/media/disk_a.dat",
        "explicit shard path")
    local steps, reason = machine:run(100)
    eq(reason, "halted", "booted from the explicit shard")
    eq(steps, 5, "boot program instructions")
end)

---------------------------------------------------------------------------
-- Command line parsing
---------------------------------------------------------------------------

test("parse_args understands the documented command line", function()
    local opts = Runner.parse_args({})
    eq(type(opts), "table", "empty arguments")
    eq(type(opts.disk_opts), "table", "disk options")

    opts = Runner.parse_args({"/disk"})
    eq(opts.disk_opts.dirs[1], "/disk", "positional directory")

    opts = Runner.parse_args({"/disk,/disk5"})
    eq(opts.disk_opts.dirs[1], "/disk", "comma list 1")
    eq(opts.disk_opts.dirs[2], "/disk5", "comma list 2")

    opts = Runner.parse_args({"--dirs=/a,/b"})
    eq(opts.disk_opts.dirs[1], "/a", "--dirs 1")
    eq(opts.disk_opts.dirs[2], "/b", "--dirs 2")

    opts = Runner.parse_args({"--shards=/a/0.dat,/b/1.dat"})
    eq(opts.disk_opts.shards[1], "/a/0.dat", "--shards 1")
    eq(opts.disk_opts.shards[2], "/b/1.dat", "--shards 2")

    opts = Runner.parse_args({"--cache=32", "--slice=10",
        "--max-steps=123", "--geometry=9,2,40"})
    eq(opts.disk_opts.cache_sectors, 32, "--cache")
    eq(opts.slice, 10, "--slice")
    eq(opts.max_steps, 123, "--max-steps")
    eq(opts.geometry.sectors, 9, "--geometry sectors")
    eq(opts.geometry.heads, 2, "--geometry heads")
    eq(opts.geometry.cylinders, 40, "--geometry cylinders")

    opts = Runner.parse_args({"--headless", "--no-signature-check",
        "--help"})
    eq(opts.headless, true, "--headless")
    eq(opts.check_boot_signature, false, "--no-signature-check")
    eq(opts.help, true, "--help")
end)

test("parse_args rejects malformed options", function()
    local opts, err = Runner.parse_args({"--bogus"})
    eq(opts, nil, "unknown option")
    contains(err, "unknown option", "unknown option reason")

    opts, err = Runner.parse_args({"--dirs="})
    eq(opts, nil, "empty value")
    contains(err, "needs a value", "empty value reason")

    opts, err = Runner.parse_args({"--cache=nope"})
    eq(opts, nil, "bad cache")
    contains(err, "--cache", "bad cache reason")

    opts, err = Runner.parse_args({"--geometry=1,2"})
    eq(opts, nil, "bad geometry")
    contains(err, "geometry", "bad geometry reason")
end)

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

test("status reports the machine state", function()
    local machine = mount_sector(make_boot_sector(BOOT_PROGRAM))
    eq(machine:status().booted, false, "before boot")
    machine:boot()
    eq(machine:status().booted, true, "after boot")
    eq(machine:status().cs, 0, "status CS")
    eq(machine:status().ip, 0x7C00, "status IP")
    eq(machine:status().image_bytes, 512, "image bytes")
end)

---------------------------------------------------------------------------
-- Command line entry point
---------------------------------------------------------------------------

local function cleanup_real_disk()
    local fsapi = rawget(_G, "fs")
    if type(fsapi) ~= "table" then
        return
    end
    pcall(fsapi.delete, "/disk/img_00.dat")
    pcall(fsapi.delete, "/disk/img_00.dat.crc32")
    if fsapi.exists("/disk") then
        pcall(fsapi.delete, "/disk")
    end
end

test("cli --help succeeds", function()
    eq(Runner.run_cli({"--help"}), true, "help return value")
end)

test("cli reports a missing image without throwing", function()
    eq(Runner.run_cli({"/no_such_shard_directory", "--headless"}), false,
        "mount failure return value")
end)

test("cli boots from real shard files under /disk", function()
    local fsapi = rawget(_G, "fs")
    if type(fsapi) ~= "table" or type(fsapi.open) ~= "function" then
        skip("no CraftOS fs API")
    end
    cleanup_real_disk()
    if fsapi.exists("/disk") then
        skip("/disk already exists")
    end
    fsapi.makeDir("/disk")
    local handle, err = fsapi.open("/disk/img_00.dat", "wb")
    if handle == nil then
        cleanup_real_disk()
        error("cannot write test shard: " .. tostring(err))
    end
    handle.write(make_boot_sector(BOOT_PROGRAM))
    handle.close()

    local ok, reason = pcall(Runner.run_cli,
        {"/disk", "--headless", "--max-steps=1000"})
    cleanup_real_disk()
    if not ok then
        error("runner cli raised: " .. tostring(reason))
    end
    eq(reason, "halted", "cli boot result")
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format("runner_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d runner test(s) failed", failed), 0)
end

return true
