---------------------------------------------------------------------------
-- 80486-simulator/tests/disk_test.lua
--
-- Standalone tests for disk.lua.  No test framework is required.
--
-- From the repository root:
--     lua 80486-simulator/tests/disk_test.lua
-- or, inside CraftOS:
--     dofile("/tests/disk_test.lua")
--
-- The tests are split in two parts:
--   * a fake in-memory backend exercises discovery, the LBA mapping,
--     cross-shard sector assembly, the LRU cache and every error path;
--   * the real CraftOS fs backend (and the Lua io backend) are exercised
--     against actual shard files created under /disk and /disk2, which are
--     removed again before the test finishes.
---------------------------------------------------------------------------

local function is_disk_module(mod)
    return type(mod) == "table"
        and type(mod.new) == "function"
        and mod.SECTOR_SIZE == 512
        and type(mod.Device) == "table"
end

local function load_disk()
    local ok, mod = pcall(require, "disk")
    if ok and is_disk_module(mod) then
        return mod
    end

    -- Make the test runnable from the repo root, from 80486-simulator/,
    -- from 80486-simulator/tests/ or from inside CraftOS.
    local candidates = {
        "80486-simulator/disk.lua",
        "../disk.lua",
        "disk.lua",
        "/80486-simulator/disk.lua",
        "/disk.lua",
    }
    local last_error
    for i = 1, #candidates do
        local chunk, err = loadfile(candidates[i])
        if chunk then
            local ok2, mod2 = pcall(chunk)
            if ok2 and is_disk_module(mod2) then
                return mod2
            end
            last_error = mod2
        else
            last_error = err
        end
    end
    error("unable to load disk.lua: " .. tostring(last_error))
end

local Disk = load_disk()

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
    if type(v) == "number" and v == v and v % 1 == 0 then
        return string.format("%d", v)
    end
    return tostring(v)
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "value", show(want), show(got)), 2)
    end
end

local function eq_number(got, want, label)
    if type(got) ~= "number" or got ~= want then
        error(string.format("%s: expected %s, got %s",
            label or "number", show(want), show(got)), 2)
    end
end

local function contains(text, needle, label)
    if type(text) ~= "string" then
        error(string.format("%s: expected a string containing %q, got %s",
            label or "text", needle, show(text)), 2)
    end
    if not text:find(needle, 1, true) then
        error(string.format("%s: %q does not contain %q",
            label or "text", text, needle), 2)
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

-- A skipped check is reported separately and is never counted as a pass.
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
-- Deterministic byte pattern: byte i = (i * 37 + 11) mod 256.
---------------------------------------------------------------------------

local function make_data(size)
    local chunks = {}
    for i = 0, size - 1 do
        chunks[#chunks + 1] = string.char((i * 37 + 11) % 256)
    end
    return table.concat(chunks)
end

-- A second, deliberately different pattern, used to prove that a reload
-- really re-reads the shard files instead of serving stale bytes.
local function make_data_alt(size)
    local chunks = {}
    for i = 0, size - 1 do
        chunks[#chunks + 1] = string.char((i * 91 + 3) % 256)
    end
    return table.concat(chunks)
end

---------------------------------------------------------------------------
-- Fake backend: shard files live in memory, so tests need no real disk and
-- can count every physical operation.
---------------------------------------------------------------------------

local function fake_backend()
    local backend = {
        name       = "fake",
        files      = {},
        dirs       = {},
        fail_open  = {},
        short_read = {},
        fail_reads = {},
        seek_bug   = false,
        opens      = 0,
        closes     = 0,
        reads      = 0,
        seeks      = 0,
    }

    local function split(path)
        local dir, name = path:match("^(.*)/([^/]+)$")
        return dir, name
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

    function backend.remove(path)
        local dir, name = split(path)
        backend.files[path] = nil
        if dir ~= nil and backend.dirs[dir] ~= nil then
            backend.dirs[dir][name] = nil
        end
        return backend
    end

    function backend.is_dir(path)
        return backend.dirs[path] ~= nil
    end

    function backend.list(path)
        local entries = backend.dirs[path]
        if entries == nil then
            return nil, "not a directory: " .. tostring(path)
        end
        local names = {}
        for name in pairs(entries) do
            names[#names + 1] = name
        end
        table.sort(names)
        return names
    end

    function backend.size(path)
        local data = backend.files[path]
        if data == nil then
            return nil, "file not found: " .. tostring(path)
        end
        return #data
    end

    function backend.open(path)
        backend.opens = backend.opens + 1
        if backend.fail_open[path] then
            return nil, "injected open failure"
        end
        if backend.files[path] == nil then
            return nil, "file not found: " .. tostring(path)
        end
        return {path = path, position = 0, closed = false}
    end

    function backend.seek(handle, offset)
        backend.seeks = backend.seeks + 1
        if handle.closed then
            return nil, "handle is closed"
        end
        if offset < 0 then
            return nil, "negative seek"
        end
        if backend.seek_bug then
            -- A drive that always reports position 0: the device must
            -- notice that its seek did not land on the requested offset.
            handle.position = 0
            return 0
        end
        handle.position = offset
        return offset
    end

    function backend.read(handle, count)
        backend.reads = backend.reads + 1
        if handle.closed then
            return nil, "handle is closed"
        end
        local remaining = backend.fail_reads[handle.path]
        if remaining ~= nil and remaining > 0 then
            backend.fail_reads[handle.path] = remaining - 1
            return nil, "injected read failure"
        end
        local data = backend.files[handle.path]
        if data == nil then
            return nil, "file vanished: " .. tostring(handle.path)
        end
        local chunk = data:sub(handle.position + 1,
            handle.position + count)
        if backend.short_read[handle.path] and #chunk > 0 then
            chunk = chunk:sub(1, #chunk - 1)
        end
        handle.position = handle.position + #chunk
        return chunk
    end

    function backend.close(handle)
        backend.closes = backend.closes + 1
        handle.closed = true
    end

    return backend
end

-- Builds a fake backend whose shards are one explicit chain.
-- sizes = {768, 1280} -> /shards/img_00.dat (768 B), /shards/img_01.dat.
local function build_explicit(sizes)
    local backend = fake_backend()
    local total_size = 0
    for i = 1, #sizes do
        total_size = total_size + sizes[i]
    end
    local data = make_data(total_size)
    local paths = {}
    local offset = 1
    for i = 1, #sizes do
        local path = string.format("/shards/img_%02d.dat", i - 1)
        backend.add(path, data:sub(offset, offset + sizes[i] - 1))
        paths[i] = path
        offset = offset + sizes[i]
    end
    return backend, paths, data
end

-- Builds a fake backend whose discovery directories hold one file per size.
-- dirs = {"/disk", "/disk2"}; sizes = {768, 1280}
local function build_discovered(dirs, sizes)
    local backend = fake_backend()
    local total_size = 0
    for i = 1, #sizes do
        total_size = total_size + sizes[i]
    end
    local data = make_data(total_size)
    local offset = 1
    for i = 1, #sizes do
        local dir = dirs[(i - 1) % #dirs + 1]
        local name = string.format("img_%02d.dat", i - 1)
        backend.add(dir .. "/" .. name,
            data:sub(offset, offset + sizes[i] - 1))
        offset = offset + sizes[i]
    end
    return backend, data
end

---------------------------------------------------------------------------
-- Real filesystem helpers (CraftOS fs API).  The io library can also write,
-- but the fs API is what disk.lua mounts by default, so use it here.
---------------------------------------------------------------------------

local function fs_available()
    local fsapi = rawget(_G, "fs")
    return type(fsapi) == "table"
        and type(fsapi.open) == "function"
        and type(fsapi.makeDir) == "function"
        and type(fsapi.delete) == "function"
        and type(fsapi.exists) == "function"
end

local REAL_FILES = {
    "/disk/img_00.dat",
    "/disk/img_01.dat",
    "/disk/img_02.dat",
    "/disk/img_00.dat.crc32",
    "/disk/image.crc32",
    "/disk2/img_00.dat",
    "/disk2/img_01.dat",
    "/disk2/img_02.dat",
    "/disk2/img_00.dat.crc32",
}

local function real_remove(path)
    local fsapi = rawget(_G, "fs")
    if type(fsapi) == "table" and fsapi.exists(path) then
        pcall(fsapi.delete, path)
    end
end

local function real_cleanup()
    for i = 1, #REAL_FILES do
        real_remove(REAL_FILES[i])
    end
    for _, dir in ipairs({"/disk", "/disk2"}) do
        if rawget(_G, "fs") and _G.fs.exists(dir) then
            pcall(_G.fs.delete, dir)
        end
    end
end

local function real_write(path, data)
    local handle, err = _G.fs.open(path, "wb")
    if handle == nil then
        error("cannot write " .. path .. ": " .. tostring(err), 0)
    end
    handle.write(data)
    handle.close()
end

-- Runs fn(data) with /disk/img_00.dat (768 B) and /disk2/img_01.dat
-- (1280 B) present, and always cleans the files up afterwards, even when
-- an assertion fails.
local function with_real_files(fn)
    if not fs_available() then
        skip("no CraftOS fs API")
    end
    real_cleanup()
    if _G.fs.exists("/disk") or _G.fs.exists("/disk2") then
        skip("/disk or /disk2 already exists")
    end
    _G.fs.makeDir("/disk")
    _G.fs.makeDir("/disk2")
    local data = make_data(2048)
    real_write("/disk/img_00.dat", data:sub(1, 768))
    real_write("/disk2/img_01.dat", data:sub(769, 2048))

    local ok, err = pcall(fn, data)
    real_cleanup()
    if not ok then
        error(err, 0)
    end
end

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

test("module constants", function()
    eq(Disk.SECTOR_SIZE, 512, "SECTOR_SIZE")
    eq(Disk.DEFAULT_SHARD_SIZE, 131072, "DEFAULT_SHARD_SIZE")
    eq(Disk.DEFAULT_CACHE_SECTORS, 64, "DEFAULT_CACHE_SECTORS")
    eq(Disk.DEFAULT_PREFIX, "img_", "DEFAULT_PREFIX")
    eq(Disk.DEFAULT_SUFFIX, ".dat", "DEFAULT_SUFFIX")
    eq(type(Disk.Device), "table", "Device table")
    eq(Disk.Device.__index, Disk.Device, "Device __index")
    eq(Disk.DEFAULT_DIRS[1], "/disk", "first default dir")
    eq(Disk.DEFAULT_DIRS[2], "/disk2", "second default dir")
    eq(Disk.DEFAULT_DIRS[12], "/disk12", "last default dir")
end)

---------------------------------------------------------------------------
-- Discovery and precise LBA -> (shard, offset) mapping
---------------------------------------------------------------------------

test("discovers shards across two directories", function()
    local backend, data = build_discovered({"/disk", "/disk2"}, {768, 1280})
    local disk = Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}

    eq(disk:get_size(), 2048, "image size")
    eq(disk:get_sector_count(), 4, "sector count")
    eq(disk:get_shard_count(), 2, "shard count")

    local first = disk:get_shard(1)
    eq(first.index, 0, "shard 1 index")
    eq(first.path, "/disk/img_00.dat", "shard 1 path")
    eq(first.size, 768, "shard 1 size")
    eq(first.start, 0, "shard 1 start")

    local second = disk:get_shard(2)
    eq(second.index, 1, "shard 2 index")
    eq(second.path, "/disk2/img_01.dat", "shard 2 path")
    eq(second.size, 1280, "shard 2 size")
    eq(second.start, 768, "shard 2 start")

    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq(disk:read_sector(1), data:sub(513, 1024), "sector 1 (crosses shards)")
    eq(disk:read_sector(2), data:sub(1025, 1536), "sector 2")
    eq(disk:read_sector(3), data:sub(1537, 2048), "sector 3")
end)

test("map reports the exact shard offset", function()
    local backend, _, data = build_explicit({768, 1280})
    local disk = Disk.new{backend = backend, shards = {
        "/shards/img_00.dat", "/shards/img_01.dat"}}
    eq(disk:get_size(), 2048, "image size")

    local m0 = disk:map(0)
    eq(m0.index, 0, "LBA 0 shard index")
    eq(m0.position, 1, "LBA 0 shard position")
    eq(m0.path, "/shards/img_00.dat", "LBA 0 path")
    eq(m0.offset, 0, "LBA 0 shard offset")
    eq(m0.available, 768, "LBA 0 available")
    eq(m0.byte, 0, "LBA 0 byte")
    eq(m0.lba, 0, "LBA 0 lba")
    eq(m0.in_sector, 0, "LBA 0 in_sector")

    local m1 = disk:map(1)
    eq(m1.index, 0, "LBA 1 stays in shard 0")
    eq(m1.offset, 512, "LBA 1 shard offset")
    eq(m1.available, 256, "LBA 1 available")

    local m2 = disk:map(2)
    eq(m2.index, 1, "LBA 2 is in shard 1")
    eq(m2.offset, 256, "LBA 2 shard offset")
    eq(m2.available, 1024, "LBA 2 available")

    local last = disk:map(3)
    eq(last.index, 1, "LBA 3 shard")
    eq(last.offset, 768, "LBA 3 offset")
    eq(last.byte, 1536, "LBA 3 byte")

    local wide = disk:map_byte(767)
    eq(wide.index, 0, "byte 767 shard")
    eq(wide.offset, 767, "byte 767 offset")
    eq(wide.available, 1, "byte 767 available")
    eq(wide.in_sector, 255, "byte 767 in_sector")

    local next_byte = disk:map_byte(768)
    eq(next_byte.index, 1, "byte 768 shard")
    eq(next_byte.offset, 0, "byte 768 offset")
    eq(next_byte.lba, 1, "byte 768 lba")
    eq(next_byte.in_sector, 256, "byte 768 in_sector")

    local very_last = disk:map_byte(2047)
    eq(very_last.index, 1, "last byte shard")
    eq(very_last.offset, 1279, "last byte offset")
end)

test("reads a sector that straddles two shards", function()
    local backend, _, data = build_explicit({768, 1280})
    local disk = Disk.new{backend = backend, shards = {
        "/shards/img_00.dat", "/shards/img_01.dat"}}

    local sector = disk:read_sector(1)
    eq(#sector, 512, "sector length")
    -- First 256 bytes come from the tail of shard 0, the rest from shard 1.
    eq(sector:sub(1, 256), data:sub(513, 768), "shard 0 part")
    eq(sector:sub(257), data:sub(769, 1024), "shard 1 part")

    local stats = disk:stats()
    eq_number(stats.misses, 1, "one cache miss")
    eq_number(stats.shard_reads, 2, "two shard reads")
    eq_number(stats.shard_bytes, 512, "512 shard bytes")
    eq_number(stats.fetches, 1, "one fetch")
end)

test("multi-sector reads open each shard only once", function()
    local backend, _, data = build_explicit({768, 1280})
    local disk = Disk.new{backend = backend, shards = {
        "/shards/img_00.dat", "/shards/img_01.dat"}}

    eq(disk:read_sectors(0, 4), data, "all four sectors")
    eq_number(backend.opens, 2, "both shards opened")
    eq_number(disk:stats().misses, 4, "four misses")
    eq_number(disk:stats().hits, 0, "no hits yet")

    eq(disk:read_sectors(0, 4), data, "cached read")
    eq_number(disk:stats().hits, 4, "four hits")
    eq_number(disk:stats().misses, 4, "still four misses")
end)

test("reads across a shard edge exactly on a sector boundary", function()
    local backend, _, data = build_explicit({512, 512, 512})
    local disk = Disk.new{backend = backend, shards = {
        "/shards/img_00.dat", "/shards/img_01.dat", "/shards/img_02.dat"}}
    eq(disk:get_shard_count(), 3, "three shards")
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq(disk:read_sector(1), data:sub(513, 1024), "sector 1")
    eq(disk:read_sector(2), data:sub(1025, 1536), "sector 2")
    eq(disk:map(1).index, 1, "sector 1 starts a shard")
    eq(disk:map(1).offset, 0, "sector 1 shard offset")
    eq_number(disk:stats().shard_reads, 3, "one shard read per sector")
end)

test("custom shard prefix and suffix", function()
    local backend = fake_backend()
    local data = make_data(1024)
    backend.add("/data/disk00.bin", data:sub(1, 512))
    backend.add("/data/disk01.bin", data:sub(513, 1024))
    -- Must be ignored: wrong prefix or wrong suffix.
    backend.add("/data/img_00.dat", string.rep("\1", 512))
    backend.add("/data/disk00.bin.bak", string.rep("\2", 512))

    local disk = Disk.new{backend = backend, dirs = {"/data"},
        prefix = "disk", suffix = ".bin"}
    eq(disk:get_shard_count(), 2, "two shards")
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq(disk:read_sector(1), data:sub(513, 1024), "sector 1")
end)

test("non shard files are ignored", function()
    local backend = fake_backend()
    local data = make_data(512)
    backend.add("/disk/img_00.dat", data)
    backend.add("/disk/img_00.dat.bak", string.rep("\7", 512))
    backend.add("/disk/notes.txt", "not a shard")
    backend.add("/disk/README", "still not a shard")

    local disk = Disk.new{backend = backend, dirs = {"/disk"}}
    eq(disk:get_shard_count(), 1, "only the real shard")
    eq(disk:read_sector(0), data, "sector 0")
end)

---------------------------------------------------------------------------
-- LRU cache
---------------------------------------------------------------------------

test("LRU evicts the least recently used sector", function()
    local backend, paths, data = build_explicit({512, 512, 512, 512})
    local disk = Disk.new{backend = backend, shards = paths,
        cache_sectors = 2}

    eq(disk:get_cache_capacity(), 2, "capacity")
    eq(disk:get_cache_count(), 0, "empty at start")

    -- 0..3 fit nowhere: capacity is 2.  Access pattern below forces exact
    -- evictions, so the counters are deterministic.
    local sequence = {0, 1, 0, 2, 1, 2, 0, 2, 0}
    for i = 1, #sequence do
        local lba = sequence[i]
        eq(disk:read_sector(lba), data:sub(lba * 512 + 1, (lba + 1) * 512),
            "sector " .. lba)
    end

    local stats = disk:stats()
    eq_number(stats.hits, 4, "hits")
    eq_number(stats.misses, 5, "misses")
    eq_number(stats.evictions, 3, "evictions")
    eq_number(stats.fetches, 5, "fetches")
    eq_number(stats.shard_reads, 5, "shard reads")
    eq_number(stats.cached, 2, "cached sectors")
    eq_number(disk:get_cache_count(), 2, "cache count")

    -- Sector 1 was evicted, so this is a miss again.
    eq(disk:read_sector(1), data:sub(513, 1024), "sector 1 again")
    eq_number(disk:stats().misses, 6, "sixth miss")
    eq_number(disk:stats().evictions, 4, "fourth eviction")
end)

test("cache hits do not touch the shard files", function()
    local backend, paths, data = build_explicit({512, 512, 512, 512})
    local disk = Disk.new{backend = backend, shards = paths}

    eq(disk:read_sector(2), data:sub(1025, 1536), "first read")
    local reads_after_first = backend.reads
    eq_number(reads_after_first, 1, "one physical read")

    for i = 1, 5 do
        eq(disk:read_sector(2), data:sub(1025, 1536), "repeat read " .. i)
    end
    eq_number(backend.reads, reads_after_first, "no extra physical reads")
    eq_number(disk:stats().hits, 5, "five cache hits")
end)

test("default cache holds exactly 64 sectors", function()
    local sizes = {}
    for i = 1, 80 do
        sizes[i] = 512
    end
    local backend, paths, data = build_explicit(sizes)
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:get_cache_capacity(), 64, "default capacity")
    eq(disk:get_sector_count(), 80, "80 sectors")

    for lba = 0, 79 do
        eq(disk:read_sector(lba), data:sub(lba * 512 + 1, (lba + 1) * 512),
            "sector " .. lba)
    end
    eq_number(disk:get_cache_count(), 64, "cache is full")
    eq_number(disk:stats().cached, 64, "stats report 64 cached")

    disk:reset_stats()
    -- The newest sector is still cached ...
    eq(disk:read_sector(79), data:sub(79 * 512 + 1, 80 * 512), "sector 79")
    eq_number(disk:stats().hits, 1, "newest sector was a hit")
    -- ... while the oldest one was evicted long ago.
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq_number(disk:stats().misses, 1, "oldest sector is a miss")
    eq_number(disk:stats().evictions, 1, "one eviction")
end)

test("cache capacity 1 keeps only the last sector", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths,
        cache_sectors = 1}
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq(disk:read_sector(1), data:sub(513, 1024), "sector 1")
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0 again")
    local stats = disk:stats()
    eq_number(stats.hits, 0, "no hits")
    eq_number(stats.misses, 3, "three misses")
    eq_number(stats.evictions, 2, "two evictions")
    eq_number(disk:get_cache_count(), 1, "one cached sector")
end)

test("invalidate_cache drops sectors but keeps counters", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    disk:read_sector(0)
    disk:read_sector(0)
    eq_number(disk:stats().hits, 1, "one hit before invalidate")
    eq(disk:invalidate_cache(), disk, "invalidate returns the device")
    eq_number(disk:get_cache_count(), 0, "cache emptied")
    eq_number(disk:stats().hits, 1, "hits survive")
    eq_number(disk:stats().misses, 1, "misses survive")
    local reads_before = backend.reads
    disk:read_sector(0)
    eq_number(backend.reads, reads_before + 1, "sector read again")
end)

---------------------------------------------------------------------------
-- Explicit shard lists
---------------------------------------------------------------------------

test("explicit shard list defines the order", function()
    local backend, _, data = build_explicit({512, 1024})
    local disk = Disk.new{backend = backend, shards = {
        "/shards/img_00.dat", "/shards/img_01.dat"}}
    eq(disk:get_size(), 1536, "image size")
    eq(disk:get_sector_count(), 3, "sector count")
    eq(disk:map(0).path, "/shards/img_00.dat", "sector 0 path")
    eq(disk:map(1).path, "/shards/img_01.dat", "sector 1 path")
    eq(disk:map(1).offset, 0, "sector 1 offset")
    eq(disk:map(2).offset, 512, "sector 2 offset")
    eq(disk:read_sectors(0, 3), data, "all sectors")
end)

test("explicit list rejects unusable entries", function()
    local backend = fake_backend()
    expect_error(function()
        Disk.new{backend = backend, shards = {}}
    end, "shards is empty")
    expect_error(function()
        Disk.new{backend = backend, shards = "img_00.dat"}
    end, "shards must be an array")
    expect_error(function()
        Disk.new{backend = backend, shards = {42}}
    end, "shards[1] must be a non-empty path")
    expect_error(function()
        Disk.new{backend = backend, shards = {""}}
    end, "shards[1] must be a non-empty path")
    expect_error(function()
        Disk.new{backend = backend, shards = {"/nope/img_00.dat"}}
    end, "cannot stat shard")
end)

test("reload follows changed shard sizes", function()
    local backend, paths, data = build_explicit({512, 1024})
    local disk = Disk.new{backend = backend, shards = paths,
        cache_sectors = 2}
    eq(disk:read_sector(1), data:sub(513, 1024), "original sector 1")
    eq(disk:get_shard_count(), 2, "two shards")
    eq(disk:map(1).index, 1, "sector 1 starts in shard 1")

    -- Move the split point: shard 0 grows to 1024 bytes and shard 1 shrinks
    -- to 512, so byte 512 now belongs to shard 0.
    local new_data = make_data_alt(1536)
    backend.add("/shards/img_00.dat", new_data:sub(1, 1024))
    backend.add("/shards/img_01.dat", new_data:sub(1025, 1536))
    disk:reset_stats()
    eq(disk:reload(), disk, "reload returns the device")
    eq_number(disk:stats().reloads, 1, "reload counted")
    eq_number(disk:get_shard_count(), 2, "still two shards")
    eq_number(disk:get_sector_count(), 3, "still three sectors")
    eq(disk:map(1).index, 0, "sector 1 now lives in shard 0")
    eq(disk:map(1).offset, 512, "sector 1 shard offset")
    eq(disk:map(2).index, 1, "sector 2 starts in shard 1")
    eq(disk:map(2).offset, 0, "sector 2 shard offset")
    eq(disk:read_sector(1), new_data:sub(513, 1024), "new sector 1")
    eq(disk:read_sector(2), new_data:sub(1025, 1536), "new sector 2")
end)

test("reload rescans the shard chain and clears the cache", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:read_sector(0), data:sub(1, 512), "first read")
    eq_number(disk:get_cache_count(), 1, "cached sector")

    local new_data = make_data_alt(1024)
    backend.add("/shards/img_00.dat", new_data:sub(1, 512))
    backend.add("/shards/img_01.dat", new_data:sub(513, 1024))
    disk:reset_stats()
    eq(disk:reload(), disk, "reload returns the device")
    eq_number(disk:stats().reloads, 1, "reload counted")
    eq_number(disk:get_cache_count(), 0, "cache cleared")
    eq(disk:read_sector(0), new_data:sub(1, 512), "new content")
    eq_number(disk:stats().misses, 1, "read after reload is a miss")
end)

test("failed reload leaves the device with no geometry", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:read_sector(0), data:sub(1, 512), "initial read")

    backend.remove("/shards/img_00.dat")
    expect_error(function() disk:reload() end, "cannot stat shard")
    eq_number(disk:get_size(), 0, "size cleared")
    eq_number(disk:get_sector_count(), 0, "sector count cleared")
    eq_number(disk:get_shard_count(), 0, "shard count cleared")
    expect_error(function() disk:read_sector(0) end, "out of range")

    -- Restoring the shard makes a second reload work again.
    backend.add("/shards/img_00.dat", data:sub(1, 512))
    eq(disk:reload(), disk, "second reload succeeds")
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0 after recovery")
end)

---------------------------------------------------------------------------
-- Discovery failures
---------------------------------------------------------------------------

test("discovery rejects a chain that does not start at zero", function()
    local backend = fake_backend()
    backend.add("/disk/img_01.dat", string.rep("\1", 512))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "must start at index 0")
end)

test("discovery rejects a gap in the chain", function()
    local backend = fake_backend()
    backend.add("/disk/img_00.dat", string.rep("\1", 512))
    backend.add("/disk/img_02.dat", string.rep("\2", 512))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "missing shard")
end)

test("discovery rejects a duplicate shard index", function()
    local backend = fake_backend()
    backend.add("/disk/img_00.dat", string.rep("\1", 512))
    backend.add("/disk2/img_00.dat", string.rep("\2", 512))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}
    end, "duplicate shard index 0")
end)

test("discovery reports missing directories and shards", function()
    local backend = fake_backend()
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}
    end, "no image shards found")
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "none of these directories exist")

    backend.add("/disk/img_00.dat", string.rep("\1", 512))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk2"}}
    end, "no image shards found")
end)

test("discovery rejects empty and absurd shard files", function()
    local backend = fake_backend()
    backend.add("/disk/img_00.dat", "")
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "is empty")

    backend = fake_backend()
    backend.add("/disk/img_99999999.dat", string.rep("\1", 512))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "out-of-range index")
end)

test("discovery rejects a partial last sector", function()
    local backend = fake_backend()
    backend.add("/disk/img_00.dat", string.rep("\1", 512))
    backend.add("/disk/img_01.dat", string.rep("\2", 100))
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk"}}
    end, "not a multiple")
end)

test("option validation", function()
    local backend, paths = build_explicit({512})
    expect_error(function() Disk.new(42) end, "opts must be a table")
    expect_error(function()
        Disk.new{backend = "nope", shards = paths}
    end, "backend must be")
    expect_error(function()
        Disk.new{backend = {}, shards = paths}
    end, "missing the 'open' function")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, cache_sectors = 0}
    end, "cache_sectors")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, cache_sectors = 1.5}
    end, "cache_sectors")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, cache_sectors = "64"}
    end, "cache_sectors")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, cache_sectors = 4097}
    end, "4096")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, cache_sectors = 1000000}
    end, "4096")
    -- The documented upper bound itself is allowed.
    local large = Disk.new{backend = backend, shards = paths,
        cache_sectors = Disk.MAX_CACHE_SECTORS}
    eq(large:get_cache_capacity(), 4096, "cache at the upper bound")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, prefix = 42}
    end, "prefix must be a string")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, suffix = 42}
    end, "suffix must be a string")
    expect_error(function()
        Disk.new{backend = backend, dirs = 42}
    end, "dirs must be a string or an array")
    expect_error(function()
        Disk.new{backend = backend, dirs = {}}
    end, "dirs is empty")
    expect_error(function()
        Disk.new{backend = backend, dirs = {42}}
    end, "dirs[1] must be a non-empty path")
    expect_error(function()
        Disk.new{backend = backend, dirs = ""}
    end, "dirs must not be empty")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, max_open_handles = 0}
    end, "max_open_handles")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, max_open_handles = 1.5}
    end, "max_open_handles")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, read_retries = -1}
    end, "read_retries")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, read_retries = 1.5}
    end, "read_retries")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, checksums = "x"}
    end, "checksums must be a table")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, manifest = 42}
    end, "manifest must be")
    expect_error(function()
        Disk.new{backend = backend, shards = paths, manifest = ""}
    end, "manifest must be")
end)

---------------------------------------------------------------------------
-- Read failures
---------------------------------------------------------------------------

test("reads outside the image fail loudly", function()
    local backend, paths = build_explicit({768, 1280})
    local disk = Disk.new{backend = backend, shards = paths}

    expect_error(function() disk:read_sector(4) end, "out of range")
    expect_error(function() disk:read_sector(-1) end, "non-negative integer")
    expect_error(function() disk:read_sector(1.5) end, "non-negative integer")
    expect_error(function() disk:read_sector("0") end,
        "non-negative integer")
    expect_error(function() disk:read_sectors(3, 2) end, "out of range")
    expect_error(function() disk:read_sectors(0, -1) end,
        "non-negative integer")
    expect_error(function() disk:read_sectors(0, 1.5) end,
        "non-negative integer")

    local value, reason = disk:try_read_sector(4)
    eq(value, nil, "try_read_sector 4")
    contains(reason, "out of range", "try_read_sector 4 reason")
    -- `try_*` must not cache the failure.
    eq_number(disk:get_cache_count(), 0, "nothing cached")
end)

test("multi-sector reads return an empty string for zero sectors", function()
    local backend, paths = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:read_sectors(0, 0), "", "zero sectors")
    eq_number(disk:stats().misses, 0, "cache untouched")
    eq_number(backend.reads, 0, "no physical read")
end)

test("map rejects out-of-range addresses", function()
    local backend, paths = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    local value, reason = disk:map(2)
    eq(value, nil, "map(2)")
    contains(reason, "out of range", "map(2) reason")
    value, reason = disk:map(-1)
    eq(value, nil, "map(-1)")
    contains(reason, "non-negative integer", "map(-1) reason")
    value, reason = disk:map(0.5)
    eq(value, nil, "map(0.5)")
    contains(reason, "non-negative integer", "map(0.5) reason")
    value, reason = disk:map_byte(1024)
    eq(value, nil, "map_byte(1024)")
    contains(reason, "out of range", "map_byte(1024) reason")
    value, reason = disk:map_byte(-1)
    eq(value, nil, "map_byte(-1)")
    contains(reason, "non-negative integer", "map_byte(-1) reason")
end)

test("a short shard read is an error, not zero padding", function()
    local backend, paths, data = build_explicit({768, 1280})
    local disk = Disk.new{backend = backend, shards = paths}
    -- The size was captured at mount time; now the file is shorter.  Sector
    -- 1 needs 256 bytes at offset 512 of shard 0, which no longer exist.
    backend.add("/shards/img_00.dat", data:sub(1, 700))
    expect_error(function() disk:read_sector(1) end, "short read")
    eq_number(disk:get_cache_count(), 0, "failed read not cached")
end)

test("a missing shard file fails at read time", function()
    local backend, paths = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    backend.remove("/shards/img_00.dat")
    expect_error(function() disk:read_sector(0) end, "cannot open shard")
    local value, reason = disk:try_read_sector(0)
    eq(value, nil, "try_read_sector value")
    contains(reason, "cannot open shard", "try_read_sector reason")
end)

test("a backend open failure is reported", function()
    local backend, paths = build_explicit({512})
    backend.fail_open["/shards/img_00.dat"] = true
    local disk = Disk.new{backend = backend, shards = paths}
    expect_error(function() disk:read_sector(0) end, "injected open failure")
end)

test("write_sector refuses to pretend", function()
    local backend, paths = build_explicit({512})
    local disk = Disk.new{backend = backend, shards = paths}
    expect_error(function()
        disk:write_sector(0, string.rep("\1", 512))
    end, "read-only")
end)

---------------------------------------------------------------------------
-- Lifecycle: close / reopen / copies
---------------------------------------------------------------------------

test("close releases handles and reopening works", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
    eq_number(backend.opens, 1, "one shard opened")
    eq(disk:close(), disk, "close returns the device")
    eq_number(backend.closes, 1, "handle closed")
    eq_number(disk:get_cache_count(), 0, "cache cleared on close")

    eq(disk:read_sector(1), data:sub(513, 1024), "read after close")
    eq_number(backend.opens, 2, "shard opened again")
end)

test("introspection returns copies", function()
    local backend, paths = build_explicit({512, 512})
    local disk = Disk.new{backend = backend, shards = paths}
    eq(disk:read_sector(0), disk:read_sector(0), "same sector twice")
    local reads_before = backend.reads
    eq_number(reads_before, 1, "one physical read")

    local shard = disk:get_shard(1)
    shard.path = "mutated"
    shard.size = 999
    eq(disk:get_shard(1).path, "/shards/img_00.dat", "shard copy is safe")
    eq(disk:get_shard(1).size, 512, "shard size copy is safe")

    local info = disk:info()
    eq(info.shard_count, 2, "info shard count")
    eq(info.sector_count, 2, "info sector count")
    eq(info.cache_capacity, 64, "info cache capacity")
    eq(info.shards[1].path, "/shards/img_00.dat", "info shard path")
    info.shards[1].path = "mutated"
    eq(disk:info().shards[1].path, "/shards/img_00.dat",
        "info copy is safe")

    local stats = disk:stats()
    stats.hits = 999
    eq_number(disk:stats().hits, 1, "stats copy is safe")

    local value, reason = disk:get_shard(99)
    eq(value, nil, "missing shard")
    contains(reason, "no shard at position", "missing shard reason")
end)

---------------------------------------------------------------------------
-- Real filesystem: CraftOS fs backend and Lua io backend
---------------------------------------------------------------------------

test("real fs backend reads shards spread over two mount points",
        function()
    with_real_files(function(data)
        -- Disk.new{} uses the default backend (fs on CraftOS) and the
        -- default search path (/disk, /disk2, ...).
        local disk = Disk.new{}
        eq(disk:get_size(), 2048, "image size")
        eq(disk:get_sector_count(), 4, "sector count")
        eq(disk:get_shard_count(), 2, "shard count")
        eq(disk:get_shard(1).path, "/disk/img_00.dat", "shard 0 path")
        eq(disk:get_shard(2).path, "/disk2/img_01.dat", "shard 1 path")

        eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
        eq(disk:read_sector(1), data:sub(513, 1024),
            "sector 1 (crosses floppies)")
        eq(disk:read_sector(2), data:sub(1025, 1536), "sector 2")
        eq(disk:read_sector(3), data:sub(1537, 2048), "sector 3")

        -- Cache: a second pass must not read the shard files again.
        local before = disk:stats().shard_reads
        eq(disk:read_sectors(0, 4), data, "all sectors from cache")
        eq_number(disk:stats().shard_reads, before, "no extra shard reads")
        eq_number(disk:get_cache_count(), 4, "four cached sectors")
        eq(disk:close(), disk, "close")
    end)
end)

test("real fs backend reports a truncated shard", function()
    with_real_files(function(data)
        local disk = Disk.new{}
        eq(disk:read_sector(0), data:sub(1, 512), "first read")
        disk:close()
        -- Shrink the first shard behind the device's back.  Sector 1 needs
        -- 256 bytes at offset 512, which a 700-byte shard cannot provide.
        real_write("/disk/img_00.dat", data:sub(1, 700))
        expect_error(function() disk:read_sector(1) end, "short read")
        eq_number(disk:get_cache_count(), 0, "failed read not cached")
        disk:close()
    end)
end)

test("real fs backend rejects an emptied mount", function()
    with_real_files(function(data)
        real_remove("/disk/img_00.dat")
        expect_error(function() Disk.new{} end, "must start at index 0")
    end)
end)

test("io backend reads an explicit shard list", function()
    local ioapi = rawget(_G, "io")
    if type(ioapi) ~= "table" or type(ioapi.open) ~= "function" then
        skip("no io library")
    end
    with_real_files(function(data)
        local disk = Disk.new{
            backend = "io",
            shards = {"/disk/img_00.dat", "/disk2/img_01.dat"},
        }
        eq(disk:get_size(), 2048, "image size")
        eq(disk:get_sector_count(), 4, "sector count")
        eq(disk:read_sector(0), data:sub(1, 512), "sector 0")
        eq(disk:read_sector(1), data:sub(513, 1024),
            "sector 1 (crosses files)")
        eq(disk:read_sector(3), data:sub(1537, 2048), "sector 3")
        eq(disk:close(), disk, "close")
    end)
end)

test("io backend cannot discover shards", function()
    local ioapi = rawget(_G, "io")
    if type(ioapi) ~= "table" or type(ioapi.open) ~= "function" then
        skip("no io library")
    end
    expect_error(function()
        Disk.new{backend = "io"}
    end, "no image shards found")
end)

---------------------------------------------------------------------------
-- Read caps, handle LRU, integrity and retries
---------------------------------------------------------------------------

test("multi-sector reads are capped by MAX_SECTORS_PER_READ", function()
    eq(Disk.MAX_SECTORS_PER_READ, 128, "MAX_SECTORS_PER_READ")
    local sizes = {}
    for i = 1, 130 do
        sizes[i] = 512
    end
    local backend, paths, data = build_explicit(sizes)
    local disk = Disk.new{backend = backend, shards = paths}

    local value, reason = disk:try_read_sectors(0, 129)
    eq(value, nil, "129 sectors rejected")
    contains(reason, "MAX_SECTORS_PER_READ", "cap reason")
    expect_error(function() disk:read_sectors(0, 129) end,
        "MAX_SECTORS_PER_READ")

    eq(disk:read_sectors(0, 128), data:sub(1, 128 * 512), "128 sectors")
    eq_number(disk:get_cache_count(), 64, "sector cache still bounded")
    eq(disk:read_sectors(128, 2), data:sub(128 * 512 + 1, 130 * 512),
        "tail can be read in a second call")
end)

test("shard handles are bounded by an LRU cache", function()
    local sizes = {}
    for i = 1, 6 do
        sizes[i] = 512
    end
    local backend, paths, data = build_explicit(sizes)
    local disk = Disk.new{backend = backend, shards = paths,
        max_open_handles = 2}
    eq(disk:get_max_open_handles(), 2, "configured maximum")

    for lba = 0, 5 do
        eq(disk:read_sector(lba), data:sub(lba * 512 + 1, (lba + 1) * 512),
            "sector " .. lba)
        eq_number(disk:get_open_handle_count(), lba < 2 and lba + 1 or 2,
            "open handles after sector " .. lba)
    end

    local stats = disk:stats()
    eq_number(stats.opens, 6, "one open per shard")
    eq_number(stats.handle_evictions, 4, "four LRU evictions")
    eq_number(disk:get_open_handle_count(), 2, "handles bounded")
    eq(disk:read_sector(0), data:sub(1, 512), "old sector reads again")
end)

test("a seek that lands elsewhere is rejected", function()
    -- Shard 0 is 1024 bytes, so sector 1 needs bytes 512..1023 from it: a
    -- seek to a non-zero offset inside a shard, where a buggy seek can be
    -- detected.
    local backend, paths = build_explicit({1024, 512})
    backend.seek_bug = true
    local disk = Disk.new{backend = backend, shards = paths,
        read_retries = 0}
    local ok, err = pcall(function() return disk:read_sector(1) end)
    eq(ok, false, "read fails")
    contains(tostring(err), "landed on 0 instead of 512", "seek diagnostic")
    eq_number(disk:stats().read_retries, 0, "no retry configured")
end)

test("physical read failures are retried with a fresh handle", function()
    local backend, paths, data = build_explicit({512, 512})
    backend.fail_reads["/shards/img_00.dat"] = 2
    local disk = Disk.new{backend = backend, shards = paths,
        read_retries = 2}
    eq(disk:read_sector(0), data:sub(1, 512), "read succeeds eventually")
    local stats = disk:stats()
    eq_number(stats.read_retries, 2, "two retries used")
    eq_number(stats.shard_reads, 1, "one successful shard read")
    eq_number(stats.opens, 3, "handle reopened for each attempt")
end)

test("read failure after all retries reports the attempt count", function()
    local backend, paths = build_explicit({512})
    backend.fail_reads["/shards/img_00.dat"] = 10
    local disk = Disk.new{backend = backend, shards = paths,
        read_retries = 2}
    local ok, err = pcall(function() return disk:read_sector(0) end)
    eq(ok, false, "read fails")
    contains(tostring(err), "injected read failure", "root cause reported")
    contains(tostring(err), "after 3 attempt(s)", "attempt count reported")
    eq_number(disk:stats().read_retries, 2, "retries counted")
end)

test("CRC32 matches the reference vectors", function()
    eq(Disk.crc32(""), 0, "empty string")
    eq(Disk.crc32("123456789"), 0xCBF43926, "check vector")
    eq(Disk.crc32("abc"), 0x352441C2, "abc vector")
    eq(Disk.crc32_hex("123456789"), "cbf43926", "hex form")
    eq(Disk.hex8(0xDEADBEEF), "deadbeef", "hex8 formatter")
end)

test("mount verifies shard checksums from sidecar files", function()
    local backend, paths, data = build_explicit({512, 1024})
    backend.add("/shards/img_00.dat.crc32",
        Disk.hex8(Disk.crc32(data:sub(1, 512))) .. "\n")
    backend.add("/shards/img_01.dat.crc32",
        Disk.hex8(Disk.crc32(data:sub(513, 1536))) .. "\n")

    local disk = Disk.new{backend = backend, shards = paths}
    eq_number(disk:info().integrity.checked, 2, "two shards verified")
    eq_number(disk:get_shard(1).crc32, Disk.crc32(data:sub(1, 512)),
        "shard crc recorded")

    -- Corrupt one shard and mounting must be refused.
    backend.add("/shards/img_01.dat", string.rep("\255", 1024))
    expect_error(function()
        Disk.new{backend = backend, shards = paths}
    end, "checksum mismatch")
end)

test("mount verifies an image.crc32 manifest", function()
    local backend, data = build_discovered({"/disk", "/disk2"}, {768, 1280})
    backend.add("/disk/image.crc32",
        Disk.crc32_hex(data:sub(1, 768)) .. "  img_00.dat\n"
        .. Disk.crc32_hex(data:sub(769, 2048)) .. "  img_01.dat\n")

    local disk = Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}
    eq_number(disk:info().integrity.checked, 2, "manifest entries verified")
    eq(disk:info().integrity.manifest, "/disk/image.crc32", "manifest path")

    -- The "name then hex" order is accepted too.
    backend.add("/disk/image.crc32",
        "img_00.dat " .. Disk.crc32_hex(data:sub(1, 768)) .. "\n"
        .. "img_01.dat " .. Disk.crc32_hex(data:sub(769, 2048)) .. "\n")
    local disk2 = Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}
    eq_number(disk2:info().integrity.checked, 2, "reversed order parsed")

    -- A bad checksum refuses to mount.
    backend.add("/disk/image.crc32",
        "00000000  img_00.dat\n"
        .. Disk.crc32_hex(data:sub(769, 2048)) .. "  img_01.dat\n")
    expect_error(function()
        Disk.new{backend = backend, dirs = {"/disk", "/disk2"}}
    end, "checksum mismatch")
end)

test("explicit opts.checksums is verified", function()
    local backend, paths, data = build_explicit({512, 512})
    local disk = Disk.new{
        backend = backend,
        shards  = paths,
        checksums = {
            [1] = Disk.hex8(Disk.crc32(data:sub(1, 512))),
            ["img_01.dat"] = Disk.hex8(Disk.crc32(data:sub(513, 1024))),
        },
    }
    eq_number(disk:info().integrity.checked, 2, "both shards verified")

    expect_error(function()
        Disk.new{backend = backend, shards = paths,
            checksums = {[1] = "00000000"}}
    end, "checksum mismatch")
    expect_error(function()
        Disk.new{backend = backend, shards = paths,
            checksums = {[1] = "nothex"}}
    end, "8-digit hex CRC32")
    expect_error(function()
        Disk.new{backend = backend, shards = paths,
            checksums = {["nope.dat"] = "00000000"}}
    end, "does not match any shard")
end)

test("verify re-checks the shards on demand", function()
    local backend, paths, data = build_explicit({512, 512})
    backend.add("/shards/img_00.dat.crc32",
        Disk.hex8(Disk.crc32(data:sub(1, 512))))
    local disk = Disk.new{backend = backend, shards = paths}
    eq_number(disk:info().integrity.checked, 1, "one expected checksum")

    local report = disk:verify()
    eq(report.ok, true, "verify ok")
    eq_number(report.checked, 1, "one comparison")
    eq(report.shards[1].verified, true, "first shard verified")
    eq(report.shards[2].verified, false, "second shard has no expectation")

    backend.add("/shards/img_00.dat", string.rep("\9", 512))
    report = disk:verify()
    eq(report.ok, false, "corruption detected")
    eq(report.shards[1].ok, false, "first shard failed")
    eq_number(report.shards[1].expected, Disk.crc32(data:sub(1, 512)),
        "expected value in the report")
    eq_number(disk:get_shard_count(), 2, "device still mounted")
end)

test("real fs mount verifies a sidecar checksum", function()
    with_real_files(function(data)
        real_write("/disk/img_00.dat.crc32",
            Disk.hex8(Disk.crc32(data:sub(1, 768))) .. "\n")
        local disk = Disk.new{}
        eq_number(disk:info().integrity.checked, 1, "one shard verified")
        eq_number(disk:get_shard(1).crc32, Disk.crc32(data:sub(1, 768)),
            "crc recorded")
        disk:close()

        real_write("/disk/img_00.dat", string.rep("\1", 768))
        expect_error(function() Disk.new{} end, "checksum mismatch")
    end)
end)

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

print(string.format("disk_test: %d passed, %d skipped, %d failed",
    passed, skipped, failed))

if failed > 0 then
    error(string.format("%d disk test(s) failed", failed), 0)
end

return true
