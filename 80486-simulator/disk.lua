---------------------------------------------------------------------------
-- 80486-simulator/disk.lua
--
-- Sector-addressed block device for the 80486 simulator, backed by a chain
-- of local image shard files (img_00.dat, img_01.dat, ...).
--
-- Why shards?
--   A bootable MS-DOS 2.0 image is larger than a single CC floppy, and the
--   simulator must not download anything at runtime.  The image therefore
--   lives on the computer as a numbered chain of shard files, either in the
--   computer's own directory (on CraftOS "./disk" IS "/disk") or spread over
--   several mounted floppies ("/disk", "/disk2", ...).
--
-- Storage model:
--   * The image is the byte-wise concatenation of shards in index order:
--     img_00.dat first, then img_01.dat, and so on.  The shard sizes come
--     from the files themselves (about 128 KiB each is the usual slice
--     size); nothing about the layout is hard coded.
--   * A logical block address (LBA) is a 512-byte sector.  LBA n covers
--     image bytes [n*512, n*512+511].
--   * Shard boundaries are NOT required to be sector aligned.  A single
--     sector may therefore straddle two shard files (for example 200 bytes
--     at the end of img_00.dat and 312 bytes at the start of img_01.dat).
--     Such sectors are assembled by reading both shards.
--   * Reads go through a small in-memory LRU cache of whole sectors
--     (64 sectors = 32 KiB by default, per the design constraint).  Cached
--     sectors are served without touching the shard files.
--   * Shard file handles are cached too, but only a bounded number of them
--     (4 by default) using an LRU order, so a long chain of floppies cannot
--     leak open files.
--   * A single multi-sector request is capped at MAX_SECTORS_PER_READ (128)
--     sectors.  Reading more at once would materialise large parts of the
--     image in memory for no reason.
--   * Shard integrity is checked with CRC32.  Expected checksums may come
--     from an explicit `opts.checksums` table, from `<shard>.crc32` sidecar
--     files, or from an `image.crc32` manifest (lines `crc32hex name`,
--     sha256sum style; a `name crc32hex` order is accepted as well).  When
--     expectations exist they are verified at mount and on `verify()`; a
--     mismatch refuses to mount instead of silently serving corrupt data.
--   * Physical read failures (open/seek/read error, short read, seek that
--     does not land on the requested offset) are retried `opts.read_retries`
--     times (2 by default) with a fresh handle before the read fails.
--   * The image is read-only.  write_sector() raises instead of pretending
--     to write: the 80486 side must observe a real disk error and a future
--     module decides how to persist writes.  Nothing here fakes success.
--
-- Failure policy:
--   * A missing, duplicated, empty or gapped shard chain is an error at
--     open time: the disk refuses to mount a partial image.
--   * A sector that is out of range, or a shard that is shorter than its
--     recorded size (truncated file, floppy yanked), is an error at read
--     time.  Nothing is silently zero-filled and nothing is skipped.
--   * `try_read_sector` / `try_read_sectors` report such failures as
--     `nil, reason` so an INT 13h handler can report a drive error instead
--     of crashing the machine.  `read_sector` / `read_sectors` raise.
--
-- Typical use:
--     local Disk = require("disk")
--     local disk = Disk.new()                       -- auto-discover shards
--     local sector = disk:read_sector(0)            -- boot sector
--     local data   = disk:read_sectors(1, 4)
--
--   Explicit placement / custom shard names:
--     local disk = Disk.new{
--         dirs = {"/disk", "/disk5"},               -- search order
--         prefix = "img_", suffix = ".dat",         -- file naming
--         cache_sectors = 64,                       -- LRU capacity
--     }
--     local disk = Disk.new{ shards = {             -- bypass discovery
--         "/disk/img_00.dat", "/disk2/img_01.dat",
--     } }
--
--   Returns from map()/map_byte() are the precise (file, offset) mapping:
--     { index, position, path, offset, available, byte, lba, in_sector }
--
-- The CPU/BIOS layers only ever read 512-byte sectors through this module;
-- the INT 13h handler will sit directly on top of try_read_sectors().
---------------------------------------------------------------------------

local SECTOR_SIZE           = 512
local DEFAULT_SHARD_SIZE    = 128 * 1024
local DEFAULT_CACHE_SECTORS = 64
local DEFAULT_PREFIX        = "img_"
local DEFAULT_SUFFIX        = ".dat"
local MAX_SHARD_INDEX       = 100000
local MAX_SECTORS_PER_READ  = 128
local DEFAULT_MAX_OPEN_HANDLES = 4
local DEFAULT_READ_RETRIES  = 2
local CHECKSUM_SUFFIX       = ".crc32"
local MANIFEST_NAME         = "image.crc32"
local CHECKSUM_CHUNK        = 65536

-- Floppies mounted by CraftOS show up as /disk, /disk2, /disk3, ...  The
-- default search order covers a 1.5 MiB image when sliced in 128 KiB parts.
local DEFAULT_DIRS = {"/disk"}
for i = 2, 12 do
    DEFAULT_DIRS[i] = "/disk" .. i
end

local floor  = math.floor
local concat = table.concat

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function is_integer(v)
    -- v % 1 also rejects NaN and infinities.
    return type(v) == "number" and v % 1 == 0
end

local function err_text(v)
    if v == nil then
        return "unknown error"
    end
    return tostring(v)
end

local function fail(where, fmt, ...)
    local message = fmt
    if select("#", ...) > 0 then
        message = string.format(fmt, ...)
    end
    error(where .. ": " .. message, 0)
end

local function copy_array(source)
    local copy = {}
    for i = 1, #source do
        copy[i] = source[i]
    end
    return copy
end

-- Joins a directory and a file name without depending on the host's path
-- rules.  fs.combine() in CraftOS strips the leading slash, so it is not
-- used here: "/disk" + "img_00.dat" always becomes "/disk/img_00.dat".
local function join_path(dir, name)
    if dir == "" then
        return name
    end
    if dir:sub(-1) == "/" then
        return dir .. name
    end
    return dir .. "/" .. name
end

local function describe_sizes(shards)
    local parts = {}
    for i = 1, #shards do
        local shard = shards[i]
        parts[#parts + 1] = string.format("%s=%s", shard.path,
            tostring(shard.size))
    end
    return concat(parts, ", ")
end

---------------------------------------------------------------------------
-- CRC32 integrity checks
--
-- CraftOS Lua 5.1 has no bitwise operators, so the checksum uses the host
-- bit32 library when available and a portable nibble-table xor otherwise.
-- CRC-32 (IEEE 802.3, polynomial 0xEDB88320) is cheap enough to run over a
-- whole DOS image, which makes it the right integrity check here.
---------------------------------------------------------------------------

local byte = string.byte
local HEX_DIGITS = "0123456789abcdef"

local bit32 = rawget(_G, "bit32")
if type(bit32) ~= "table" then
    local ok32, module32 = pcall(require, "bit32")
    if ok32 and type(module32) == "table" then
        bit32 = module32
    end
end

local XOR_NIBBLE = {}
do
    local a, b
    for a = 0, 15 do
        XOR_NIBBLE[a] = {}
        for b = 0, 15 do
            local value = 0
            local place = 1
            local x, y = a, b
            for _ = 1, 4 do
                if (x % 2) ~= (y % 2) then
                    value = value + place
                end
                x = floor(x / 2)
                y = floor(y / 2)
                place = place * 2
            end
            XOR_NIBBLE[a][b] = value
        end
    end
end

local function xor_byte(a, b)
    return XOR_NIBBLE[floor(a / 16)][floor(b / 16)] * 16
        + XOR_NIBBLE[a % 16][b % 16]
end

local function xor32_nibbles(a, b)
    local result = 0
    local place = 1
    for _ = 1, 4 do
        result = result + xor_byte(a % 256, b % 256) * place
        a = floor(a / 256)
        b = floor(b / 256)
        place = place * 256
    end
    return result
end

local xor32
if bit32 ~= nil and type(bit32.bxor) == "function" then
    xor32 = function(a, b)
        return bit32.bxor(a, b)
    end
else
    xor32 = xor32_nibbles
end

local CRC32_TABLE = {}
do
    local index
    for index = 0, 255 do
        local value = index
        for _ = 1, 8 do
            if value % 2 == 1 then
                value = xor32(floor(value / 2), 0xEDB88320)
            else
                value = floor(value / 2)
            end
        end
        CRC32_TABLE[index] = value
    end
end

local function hex8(value)
    local parts = {}
    for i = 8, 1, -1 do
        local digit = value % 16
        parts[i] = HEX_DIGITS:sub(digit + 1, digit + 1)
        value = floor(value / 16)
    end
    return concat(parts)
end

local function parse_hex8(text)
    if type(text) ~= "string" then
        return nil
    end
    local lowered = text:lower()
    if not lowered:match("^%x%x%x%x%x%x%x%x$") then
        return nil
    end
    return tonumber(lowered, 16)
end

local function crc32_update(crc, data)
    local table_ = CRC32_TABLE
    for i = 1, #data do
        local index = xor_byte(crc % 256, byte(data, i))
        crc = xor32(floor(crc / 256), table_[index])
    end
    return crc
end

-- CRC-32 of a string, as an unsigned 32-bit number.
local function crc32(data)
    if type(data) ~= "string" then
        error("disk.crc32: data must be a string (got "
            .. type(data) .. ")", 0)
    end
    -- The final xor with 0xFFFFFFFF is a 32-bit NOT, written without
    -- bitwise operators so it also works on plain Lua 5.1.
    return 4294967295 - crc32_update(0xFFFFFFFF, data)
end

local function crc32_hex(data)
    return hex8(crc32(data))
end

local function basename(path)
    local name = path:match("([^/]+)$")
    if name == nil or name == "" then
        return path
    end
    return name
end

---------------------------------------------------------------------------
-- Backends
--
-- A backend hides the difference between the CraftOS file API and the plain
-- Lua io library.  The required functions are:
--
--     backend.open(path)          -> handle | nil, reason
--     backend.seek(handle, off)   -> new position | nil, reason
--     backend.read(handle, n)     -> exactly n bytes | nil, reason
--     backend.close(handle)       -> nothing
--     backend.size(path)          -> byte size | nil, reason
--     backend.list(dir)           -> array of names | nil, reason
--     backend.is_dir(path)        -> boolean
--
-- CraftOS has no legacy fs.read/fs.seek/fs.close functions any more; file
-- handles are tables with bound methods.  The fs backend detects that shape
-- and refuses to run on an unsupported API instead of half-working.
---------------------------------------------------------------------------

local function make_fs_backend(fsapi)
    if type(fsapi) ~= "table" then
        error("disk.fs_backend: the CraftOS fs API is not available", 0)
    end
    local required = {"open", "getSize", "isDir", "list"}
    for i = 1, #required do
        local name = required[i]
        if type(fsapi[name]) ~= "function" then
            error("disk.fs_backend: fs." .. name .. " is missing", 0)
        end
    end

    local backend = {name = "fs"}

    function backend.open(path)
        local ok, handle, err = pcall(fsapi.open, path, "rb")
        if not ok then
            return nil, err_text(handle)
        end
        if handle == nil then
            return nil, err_text(err)
        end
        if type(handle) ~= "table"
            or type(handle.read) ~= "function"
            or type(handle.seek) ~= "function"
            or type(handle.close) ~= "function" then
            if type(fsapi.close) == "function" then
                pcall(fsapi.close, handle)
            end
            return nil, "unsupported fs handle API "
                .. "(need read/seek/close methods on the handle)"
        end
        return handle
    end

    function backend.seek(handle, offset)
        -- Bound handle method: handle.seek(whence, offset).
        local ok, position, err = pcall(handle.seek, "set", offset)
        if not ok then
            return nil, err_text(position)
        end
        if type(position) ~= "number" then
            return nil, err_text(err)
        end
        return position
    end

    function backend.read(handle, count)
        local ok, data, err = pcall(handle.read, count)
        if not ok then
            return nil, err_text(data)
        end
        if type(data) ~= "string" then
            return nil, err_text(err)
        end
        return data
    end

    function backend.close(handle)
        pcall(handle.close)
    end

    function backend.size(path)
        local ok, size, err = pcall(fsapi.getSize, path)
        if not ok then
            return nil, err_text(size)
        end
        if type(size) ~= "number" then
            return nil, err_text(err)
        end
        return size
    end

    function backend.list(dir)
        local ok, items, err = pcall(fsapi.list, dir)
        if not ok then
            return nil, err_text(items)
        end
        if type(items) ~= "table" then
            return nil, err_text(err)
        end
        local names = {}
        for i = 1, #items do
            if type(items[i]) == "string" then
                names[#names + 1] = items[i]
            end
        end
        return names
    end

    function backend.is_dir(path)
        local ok, result = pcall(fsapi.isDir, path)
        return ok and result == true
    end

    return backend
end

local function make_io_backend(ioapi)
    if ioapi == nil then
        ioapi = rawget(_G, "io")
    end
    if type(ioapi) ~= "table" or type(ioapi.open) ~= "function" then
        error("disk.io_backend: the Lua io library is not available", 0)
    end

    local backend = {name = "io", can_list = false}

    function backend.open(path)
        local ok, file, err = pcall(ioapi.open, path, "rb")
        if not ok then
            return nil, err_text(file)
        end
        if file == nil then
            return nil, err_text(err)
        end
        return file
    end

    function backend.seek(handle, offset)
        local ok, position, err = pcall(function()
            return handle:seek("set", offset)
        end)
        if not ok then
            return nil, err_text(position)
        end
        if type(position) ~= "number" then
            return nil, err_text(err)
        end
        return position
    end

    function backend.read(handle, count)
        local ok, data, err = pcall(function()
            return handle:read(count)
        end)
        if not ok then
            return nil, err_text(data)
        end
        if type(data) ~= "string" then
            return nil, err_text(err)
        end
        return data
    end

    function backend.close(handle)
        pcall(function()
            handle:close()
        end)
    end

    function backend.size(path)
        local handle, err = backend.open(path)
        if handle == nil then
            return nil, err
        end
        local ok, position = pcall(function()
            return handle:seek("end")
        end)
        backend.close(handle)
        if not ok or type(position) ~= "number" then
            return nil, "cannot determine the size of " .. tostring(path)
        end
        return position
    end

    function backend.list(dir)
        return nil, "the io backend cannot list directories "
            .. "(pass opts.shards explicitly)"
    end

    function backend.is_dir(path)
        -- The plain Lua io library has no portable directory test; the io
        -- backend is therefore only usable with an explicit shard list.
        return false
    end

    return backend
end

local function auto_backend()
    local fsapi = rawget(_G, "fs")
    if type(fsapi) == "table" and type(fsapi.open) == "function" then
        return make_fs_backend(fsapi)
    end
    local ioapi = rawget(_G, "io")
    if type(ioapi) == "table" and type(ioapi.open) == "function" then
        return make_io_backend(ioapi)
    end
    error("disk: no file backend available "
        .. "(need the CraftOS fs API or the Lua io library)", 0)
end

local BACKEND_FUNCTIONS = {
    "open", "read", "seek", "close", "size", "list", "is_dir",
}

local function resolve_backend(spec)
    if spec == nil or spec == "auto" then
        return auto_backend()
    end
    if spec == "fs" then
        return make_fs_backend(rawget(_G, "fs"))
    end
    if spec == "io" then
        return make_io_backend(rawget(_G, "io"))
    end
    if type(spec) == "table" then
        for i = 1, #BACKEND_FUNCTIONS do
            local name = BACKEND_FUNCTIONS[i]
            if type(spec[name]) ~= "function" then
                error("disk: custom backend is missing the '"
                    .. name .. "' function", 0)
            end
        end
        return spec
    end
    error("disk: backend must be 'auto', 'fs', 'io' or a backend table "
        .. "(got " .. type(spec) .. ")", 0)
end

---------------------------------------------------------------------------
-- Shard discovery and layout
---------------------------------------------------------------------------

local function shard_index_from_name(name, prefix, suffix)
    if type(name) ~= "string" then
        return nil
    end
    if #name <= #prefix + #suffix then
        return nil
    end
    if prefix ~= "" and name:sub(1, #prefix) ~= prefix then
        return nil
    end
    local digits_end = #name - #suffix
    if suffix ~= "" and name:sub(digits_end + 1) ~= suffix then
        return nil
    end
    local digits = name:sub(#prefix + 1, digits_end)
    if not digits:match("^%d+$") then
        return nil
    end
    return tonumber(digits)
end

-- Reads the size of one shard and rejects unusable values.
local function stat_shard(backend, path, where)
    local size, err = backend.size(path)
    if type(size) ~= "number" then
        fail(where, "cannot stat shard %s: %s", path, err_text(err))
    end
    if not is_integer(size) or size < 0 then
        fail(where, "shard %s has an invalid size (%s)", path, tostring(size))
    end
    if size == 0 then
        fail(where, "shard %s is empty", path)
    end
    return size
end

local function explicit_shards(device, where)
    local paths = device._explicit
    if type(paths) ~= "table" then
        fail(where, "shards must be an array of paths (got %s)",
            type(paths))
    end
    if #paths == 0 then
        fail(where, "shards is empty")
    end
    local shards = {}
    for i = 1, #paths do
        local path = paths[i]
        if type(path) ~= "string" or path == "" then
            fail(where, "shards[%d] must be a non-empty path string", i)
        end
        shards[i] = {
            index = i - 1,
            path  = path,
            size  = stat_shard(device._backend, path, where),
        }
    end
    return shards
end

local function discovered_shards(device, where)
    local backend = device._backend
    local prefix  = device._prefix
    local suffix  = device._suffix
    local dirs    = device._dirs
    local found   = {}
    local searched = {}
    local listed = false

    for i = 1, #dirs do
        local dir = dirs[i]
        searched[#searched + 1] = dir
        if backend.is_dir(dir) then
            local names, err = backend.list(dir)
            if names == nil then
                fail(where, "cannot list shard directory %s: %s",
                    dir, err_text(err))
            end
            listed = true
            for j = 1, #names do
                local name = names[j]
                local index = shard_index_from_name(name, prefix, suffix)
                if index ~= nil then
                    if not is_integer(index) or index < 0
                        or index > MAX_SHARD_INDEX then
                        fail(where, "shard file %s in %s has an "
                            .. "out-of-range index", name, dir)
                    end
                    local path = join_path(dir, name)
                    local previous = found[index]
                    if previous ~= nil then
                        fail(where, "duplicate shard index %d: %s and %s",
                            index, previous, path)
                    end
                    found[index] = path
                end
            end
        end
    end

    local indices = {}
    for index in pairs(found) do
        indices[#indices + 1] = index
    end
    table.sort(indices)

    if #indices == 0 then
        local searched_text = concat(searched, ", ")
        if not listed then
            searched_text = searched_text .. " (none of these directories exist)"
        end
        fail(where, "no image shards found; searched %s; expected %s00%s, "
            .. "%s01%s, ...", searched_text, prefix, suffix, prefix, suffix)
    end

    local first = indices[1]
    if first ~= 0 then
        fail(where, "shard sequence must start at index 0 "
            .. "(first shard found is %s)", found[first])
    end

    local shards = {}
    for position = 1, #indices do
        local index = indices[position]
        if index ~= position - 1 then
            fail(where, "missing shard %s%02d%s between %s%d%s and %s%d%s",
                prefix, position - 1, suffix,
                prefix, position - 2, suffix,
                prefix, index, suffix)
        end
        local path = found[index]
        shards[position] = {
            index = index,
            path  = path,
            size  = stat_shard(backend, path, where),
        }
    end
    return shards
end

-- Builds the shard chain and its cumulative geometry.  Raises on anything
-- that would mount a hole or a partial image.
local function load_layout(device, where)
    local shards
    if device._explicit ~= nil then
        shards = explicit_shards(device, where)
    else
        shards = discovered_shards(device, where)
    end

    local total = 0
    for i = 1, #shards do
        local shard = shards[i]
        shard.start = total
        total = total + shard.size
    end

    if total == 0 then
        fail(where, "the image is empty")
    end
    if total % SECTOR_SIZE ~= 0 then
        fail(where, "image size %d bytes is not a multiple of %d bytes "
            .. "(shards: %s)", total, SECTOR_SIZE, describe_sizes(shards))
    end

    return shards, total
end

local function install_layout(device, shards, total)
    device._shards       = shards
    device._size         = total
    device._sector_count = floor(total / SECTOR_SIZE)
end

---------------------------------------------------------------------------
-- Checksum collection and verification
--
-- Checksums are never invented: every expected value has to come from the
-- caller (opts.checksums), a `<shard>.crc32` sidecar file, or an
-- `image.crc32` manifest.  If expectations exist they are verified at mount,
-- and a mismatch refuses to mount the image.
---------------------------------------------------------------------------

local function read_small_file(device, path)
    local backend = device._backend
    local size, size_err = backend.size(path)
    if type(size) ~= "number" then
        return nil, err_text(size_err)
    end
    if size > 4096 then
        return nil, "checksum file is unexpectedly large"
    end
    local handle, open_err = backend.open(path)
    if handle == nil then
        return nil, err_text(open_err)
    end
    local text = ""
    if size > 0 then
        local seeked, seek_err = backend.seek(handle, 0)
        if seeked ~= 0 then
            backend.close(handle)
            return nil, "cannot seek checksum file: " .. err_text(seek_err)
        end
        local data, read_err = backend.read(handle, size)
        if type(data) ~= "string" or #data ~= size then
            backend.close(handle)
            return nil, "cannot read checksum file: " .. err_text(read_err)
        end
        text = data
    end
    backend.close(handle)
    return text
end

local function crc32_of_file(device, path, size)
    local backend = device._backend
    local handle, open_err = backend.open(path)
    if handle == nil then
        return nil, "cannot open " .. path .. ": " .. err_text(open_err)
    end
    local crc = 0xFFFFFFFF
    local position = 0
    local problem = nil
    while position < size do
        local count = size - position
        if count > CHECKSUM_CHUNK then
            count = CHECKSUM_CHUNK
        end
        local seeked, seek_err = backend.seek(handle, position)
        if seeked ~= position then
            problem = string.format("seek failed at %s: %s",
                tostring(position), err_text(seek_err))
            break
        end
        local data, read_err = backend.read(handle, count)
        if type(data) ~= "string" or #data ~= count then
            problem = string.format("short read at %s: %s",
                tostring(position), err_text(read_err))
            break
        end
        crc = crc32_update(crc, data)
        position = position + count
    end
    backend.close(handle)
    if problem ~= nil then
        return nil, string.format("%s: %s", path, problem)
    end
    return 4294967295 - crc
end

local function shard_position_for_key(device, key)
    if type(key) == "number" then
        if is_integer(key) and key >= 1 and key <= #device._shards then
            return key
        end
        return nil
    end
    if type(key) == "string" then
        for position = 1, #device._shards do
            local shard = device._shards[position]
            if shard.path == key or basename(shard.path) == key then
                return position
            end
        end
    end
    return nil
end

local function expected_set(device, expected, where, position, value, source)
    local shard = device._shards[position]
    local existing = expected[position]
    local hex = hex8(value)
    if existing ~= nil and existing.value ~= value then
        fail(where, "conflicting checksums for shard %s: %s says %s, "
            .. "%s says %s", shard.path, existing.source, existing.hex,
            source, hex)
    end
    expected[position] = {
        value  = value,
        hex    = hex,
        source = source,
        path   = shard.path,
    }
end

local function collect_expected(device, where)
    local expected = {}
    local manifest_path = nil

    -- 1) Explicit checksum table from the caller.
    local provided = device._opt_checksums
    if provided ~= nil then
        for key, value in pairs(provided) do
            local position = shard_position_for_key(device, key)
            if position == nil then
                fail(where, "checksums entry %s does not match any shard",
                    tostring(key))
            end
            local parsed = parse_hex8(tostring(value))
            if parsed == nil then
                fail(where, "checksums entry %s is not an 8-digit hex CRC32 "
                    .. "(got %s)", tostring(key), tostring(value))
            end
            expected_set(device, expected, where, position, parsed,
                "checksums")
        end
    end

    -- 2) Per-shard "<shard>.crc32" sidecar files.
    for position = 1, #device._shards do
        local shard = device._shards[position]
        local sidecar = shard.path .. CHECKSUM_SUFFIX
        local size = device._backend.size(sidecar)
        if type(size) == "number" then
            local text, err = read_small_file(device, sidecar)
            if text == nil then
                fail(where, "cannot read checksum file %s: %s",
                    sidecar, err_text(err))
            end
            local parsed = parse_hex8(text:match("(%x%x%x%x%x%x%x%x)"))
            if parsed == nil then
                fail(where, "checksum file %s does not contain an "
                    .. "8-digit hex CRC32", sidecar)
            end
            expected_set(device, expected, where, position, parsed,
                "sidecar " .. sidecar)
        end
    end

    -- 3) Manifest: explicit opts.manifest, or image.crc32 in a shard dir.
    if device._manifest ~= nil then
        manifest_path = device._manifest
    elseif device._explicit == nil then
        for i = 1, #device._dirs do
            local candidate = join_path(device._dirs[i], MANIFEST_NAME)
            if type(device._backend.size(candidate)) == "number" then
                if manifest_path ~= nil then
                    fail(where, "ambiguous checksum manifests: %s and %s",
                        manifest_path, candidate)
                end
                manifest_path = candidate
            end
        end
    end

    if manifest_path ~= nil then
        local text, err = read_small_file(device, manifest_path)
        if text == nil then
            fail(where, "cannot read checksum manifest %s: %s",
                manifest_path, err_text(err))
        end
        local matched = 0
        for line in text:gmatch("[^\n]+") do
            local clean = line:gsub("\r$", "")
            if not clean:match("^%s*#") and not clean:match("^%s*$") then
                local first, second = clean:match("^%s*(%S+)%s+(%S+)")
                if first ~= nil and second ~= nil then
                    local value = parse_hex8(first)
                    local name = second
                    if value == nil then
                        value = parse_hex8(second)
                        name = first
                    end
                    if value ~= nil then
                        local position = nil
                        for i = 1, #device._shards do
                            local shard = device._shards[i]
                            if shard.path == name
                                or basename(shard.path) == basename(name) then
                                position = i
                                break
                            end
                        end
                        if position ~= nil then
                            matched = matched + 1
                            expected_set(device, expected, where, position,
                                value, "manifest " .. manifest_path)
                        end
                    end
                end
            end
        end
        if matched == 0 then
            fail(where, "checksum manifest %s contains no checksums for the "
                .. "mounted shards", manifest_path)
        end
    end

    return expected, manifest_path
end

local function setup_checksums(device, where)
    local expected, manifest_path = collect_expected(device, where)
    device._expected = expected
    device._integrity = {
        checked  = 0,
        total    = #device._shards,
        manifest = manifest_path,
    }
    for position = 1, #device._shards do
        local shard = device._shards[position]
        local wanted = expected[position]
        if wanted ~= nil then
            local actual, err = crc32_of_file(device, shard.path, shard.size)
            if actual == nil then
                fail(where, "cannot checksum shard %s: %s",
                    shard.path, err_text(err))
            end
            if actual ~= wanted.value then
                fail(where, "checksum mismatch for shard %s: expected %s, "
                    .. "got %s (%s)", shard.path, wanted.hex,
                    hex8(actual), wanted.source)
            end
            shard.crc32 = actual
            shard.expected_crc32 = wanted.value
            device._integrity.checked = device._integrity.checked + 1
        end
    end
end

---------------------------------------------------------------------------
-- LRU sector cache
--
-- Intrusive doubly linked list: _cache_head is the most recently used
-- sector, _cache_tail the least recently used one.  _cache_map[lba] points
-- at the node.  The list never grows past _cache_capacity entries.
---------------------------------------------------------------------------

local function new_stats()
    return {
        hits             = 0,
        misses           = 0,
        evictions        = 0,
        fetches          = 0,
        shard_reads      = 0,
        shard_bytes      = 0,
        opens            = 0,
        closes           = 0,
        reloads          = 0,
        read_retries     = 0,
        handle_evictions = 0,
    }
end

local function cache_clear(device)
    local map = device._cache_map
    for lba, node in pairs(map) do
        map[lba] = nil
        node.data = nil
    end
    device._cache_map   = map
    device._cache_head  = nil
    device._cache_tail  = nil
    device._cache_count = 0
end

local function cache_touch(device, node)
    local head = device._cache_head
    if head == node then
        return
    end

    local previous = node.prev
    local following = node.next

    if previous ~= nil then
        previous.next = following
    end
    if following ~= nil then
        following.prev = previous
    end
    if device._cache_tail == node then
        device._cache_tail = previous
    end

    node.prev = nil
    node.next = head
    if head ~= nil then
        head.prev = node
    end
    device._cache_head = node
    if device._cache_tail == nil then
        device._cache_tail = node
    end
end

local function cache_put(device, lba, data)
    local node = device._cache_map[lba]
    if node ~= nil then
        node.data = data
        cache_touch(device, node)
        return
    end

    node = {lba = lba, data = data}
    device._cache_map[lba] = node
    local head = device._cache_head
    node.next = head
    if head ~= nil then
        head.prev = node
    end
    device._cache_head = node
    if device._cache_tail == nil then
        device._cache_tail = node
    end
    device._cache_count = device._cache_count + 1

    while device._cache_count > device._cache_capacity do
        local tail = device._cache_tail
        device._cache_tail = tail.prev
        if device._cache_tail ~= nil then
            device._cache_tail.next = nil
        end
        device._cache_map[tail.lba] = nil
        device._cache_count = device._cache_count - 1
        device._stats.evictions = device._stats.evictions + 1
        tail.prev = nil
        tail.next = nil
        tail.data = nil
        if device._cache_head == tail then
            device._cache_head = nil
        end
    end
end

---------------------------------------------------------------------------
-- Device
---------------------------------------------------------------------------

local Device = {}
Device.__index = Device

-- Maps the 1-based position in the shard chain to the shard and the byte
-- offset inside it, using a binary search over the cumulative starts.
function Device:_locate(offset)
    local shards = self._shards
    local low, high = 1, #shards
    while low <= high do
        local middle = floor((low + high) / 2)
        local shard = shards[middle]
        if offset < shard.start then
            high = middle - 1
        elseif offset >= shard.start + shard.size then
            low = middle + 1
        else
            return middle, offset - shard.start
        end
    end
    return nil, nil
end

-- Handle LRU.  _handle_order[1] is the least recently used shard position,
-- _handle_order[#] the most recently used one.  At most _max_open_handles
-- files stay open, so a long floppy chain cannot leak file handles.
function Device:_handle_touch(position)
    local order = self._handle_order
    local last = #order
    if last > 0 and order[last] == position then
        return
    end
    for i = 1, last do
        if order[i] == position then
            table.remove(order, i)
            break
        end
    end
    order[#order + 1] = position
end

function Device:_drop_handle(position)
    local handle = self._handles[position]
    if handle ~= nil then
        self._backend.close(handle)
        self._handles[position] = nil
        self._handle_count = self._handle_count - 1
        self._stats.closes = self._stats.closes + 1
    end
    local order = self._handle_order
    for i = #order, 1, -1 do
        if order[i] == position then
            table.remove(order, i)
        end
    end
end

function Device:_open_shard(position)
    local handle = self._handles[position]
    if handle ~= nil then
        self:_handle_touch(position)
        return handle
    end
    local shard = self._shards[position]
    while self._handle_count >= self._max_open_handles do
        local victim = self._handle_order[1]
        if victim == nil then
            break
        end
        self:_drop_handle(victim)
        self._stats.handle_evictions = self._stats.handle_evictions + 1
    end
    local opened, err = self._backend.open(shard.path)
    if opened == nil then
        return nil, string.format("cannot open shard %s: %s",
            shard.path, err_text(err))
    end
    self._handles[position] = opened
    self._handle_order[#self._handle_order + 1] = position
    self._handle_count = self._handle_count + 1
    self._stats.opens = self._stats.opens + 1
    return opened
end

function Device:_close_handles()
    while self._handle_count > 0 do
        local position = self._handle_order[1]
        if position == nil then
            break
        end
        self:_drop_handle(position)
    end
    -- Defensive: close anything that somehow escaped the LRU list.
    for position, handle in pairs(self._handles) do
        if handle ~= nil then
            self._backend.close(handle)
            self._handles[position] = nil
            self._stats.closes = self._stats.closes + 1
        end
    end
    self._handle_order = {}
    self._handle_count = 0
end

-- Reads an exact byte range from one shard.  A failed open, a seek that
-- does not land on the requested offset, a read error and a short read are
-- all hard failures (never zero filled).  The entire attempt is retried
-- with a fresh handle up to _read_retries times.
function Device:_read_shard(position, offset, count)
    local shard = self._shards[position]
    local backend = self._backend
    local attempts = self._read_retries + 1
    local last_error = "read failed"

    for attempt = 1, attempts do
        local failure = nil
        local handle, open_err = self:_open_shard(position)
        if handle == nil then
            failure = open_err
        else
            local seeked, seek_err = backend.seek(handle, offset)
            if seeked == nil then
                failure = string.format("seek failed in shard %s at "
                    .. "offset %d: %s", shard.path, offset,
                    err_text(seek_err))
            elseif seeked ~= offset then
                failure = string.format("seek in shard %s landed on %s "
                    .. "instead of %d", shard.path, tostring(seeked), offset)
            else
                local data, read_err = backend.read(handle, count)
                if data == nil then
                    failure = string.format("read failed in shard %s at "
                        .. "offset %d (%d bytes): %s", shard.path, offset,
                        count, err_text(read_err))
                elseif #data ~= count then
                    failure = string.format("short read in shard %s at "
                        .. "offset %d: wanted %d bytes, got %d",
                        shard.path, offset, count, #data)
                else
                    self._stats.shard_reads = self._stats.shard_reads + 1
                    self._stats.shard_bytes = self._stats.shard_bytes + #data
                    return data
                end
            end
        end

        last_error = failure
        -- Force the next attempt to reopen the file rather than reuse a
        -- handle whose position or state may be what failed.
        self:_drop_handle(position)
        if attempt < attempts then
            self._stats.read_retries = self._stats.read_retries + 1
        end
    end

    return nil, string.format("%s (after %d attempt(s))",
        last_error, attempts)
end

-- Reads one sector straight from the shard files, assembling it from as
-- many shards as the sector straddles.
function Device:_read_raw_sector(lba)
    local position = lba * SECTOR_SIZE
    local parts = {}
    local part_count = 0
    local remaining = SECTOR_SIZE

    while remaining > 0 do
        local shard_position, inside = self:_locate(position)
        if shard_position == nil then
            return nil, string.format("image is truncated at byte %d "
                .. "while reading LBA %s", position, tostring(lba))
        end
        local shard = self._shards[shard_position]
        local available = shard.size - inside
        local take = remaining
        if available < take then
            take = available
        end
        local data, err = self:_read_shard(shard_position, inside, take)
        if data == nil then
            return nil, string.format("LBA %s: %s", tostring(lba), err)
        end
        part_count = part_count + 1
        parts[part_count] = data
        position = position + take
        remaining = remaining - take
    end

    local sector = parts[1]
    if part_count > 1 then
        sector = concat(parts)
    end
    if #sector ~= SECTOR_SIZE then
        return nil, string.format("LBA %s assembled %d bytes instead of %d",
            tostring(lba), #sector, SECTOR_SIZE)
    end
    return sector
end

-- Cache-aware fetch.  Returns sector data or nil, reason.
function Device:_fetch(lba)
    local node = self._cache_map[lba]
    if node ~= nil then
        cache_touch(self, node)
        self._stats.hits = self._stats.hits + 1
        return node.data
    end

    self._stats.misses = self._stats.misses + 1
    local sector, err = self:_read_raw_sector(lba)
    if sector == nil then
        return nil, err
    end
    self._stats.fetches = self._stats.fetches + 1
    cache_put(self, lba, sector)
    return sector
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function validate_dirs(opts)
    local dirs = opts.dirs
    if dirs == nil then
        return copy_array(DEFAULT_DIRS)
    end
    if type(dirs) == "string" then
        if dirs == "" then
            fail("disk.new", "dirs must not be empty")
        end
        return {dirs}
    end
    if type(dirs) ~= "table" then
        fail("disk.new", "dirs must be a string or an array of strings "
            .. "(got %s)", type(dirs))
    end
    local copy = {}
    for i = 1, #dirs do
        local dir = dirs[i]
        if type(dir) ~= "string" or dir == "" then
            fail("disk.new", "dirs[%d] must be a non-empty path string", i)
        end
        copy[i] = dir
    end
    if #copy == 0 then
        fail("disk.new", "dirs is empty")
    end
    return copy
end

local function validate_options(opts)
    if type(opts) ~= "table" then
        fail("disk.new", "opts must be a table (got %s)", type(opts))
    end

    local cache_sectors = opts.cache_sectors
    if cache_sectors == nil then
        cache_sectors = DEFAULT_CACHE_SECTORS
    end
    if not is_integer(cache_sectors) or cache_sectors < 1 then
        fail("disk.new", "cache_sectors must be a positive integer (got %s)",
            tostring(cache_sectors))
    end

    local prefix = opts.prefix
    if prefix == nil then
        prefix = DEFAULT_PREFIX
    end
    if type(prefix) ~= "string" then
        fail("disk.new", "prefix must be a string (got %s)", type(prefix))
    end

    local suffix = opts.suffix
    if suffix == nil then
        suffix = DEFAULT_SUFFIX
    end
    if type(suffix) ~= "string" then
        fail("disk.new", "suffix must be a string (got %s)", type(suffix))
    end

    local max_open = opts.max_open_handles
    if max_open == nil then
        max_open = DEFAULT_MAX_OPEN_HANDLES
    end
    if not is_integer(max_open) or max_open < 1 then
        fail("disk.new", "max_open_handles must be a positive integer "
            .. "(got %s)", tostring(max_open))
    end

    local retries = opts.read_retries
    if retries == nil then
        retries = DEFAULT_READ_RETRIES
    end
    if not is_integer(retries) or retries < 0 then
        fail("disk.new", "read_retries must be a non-negative integer "
            .. "(got %s)", tostring(retries))
    end

    local checksums = opts.checksums
    if checksums ~= nil and type(checksums) ~= "table" then
        fail("disk.new", "checksums must be a table (got %s)",
            type(checksums))
    end

    local manifest = opts.manifest
    if manifest ~= nil
        and (type(manifest) ~= "string" or manifest == "") then
        fail("disk.new", "manifest must be a non-empty path string")
    end

    local explicit = opts.shards
    if explicit ~= nil and type(explicit) ~= "table" then
        fail("disk.new", "shards must be an array of paths (got %s)",
            type(explicit))
    end

    return {
        backend          = resolve_backend(opts.backend),
        cache_sectors    = cache_sectors,
        prefix           = prefix,
        suffix           = suffix,
        dirs             = validate_dirs(opts),
        explicit         = explicit,
        max_open_handles = max_open,
        read_retries     = retries,
        checksums        = checksums,
        manifest         = manifest,
    }
end

local Disk = {}

function Disk.new(opts)
    if opts == nil then
        opts = {}
    end
    local options = validate_options(opts)

    local device = setmetatable({
        _backend          = options.backend,
        _prefix           = options.prefix,
        _suffix           = options.suffix,
        _dirs             = options.dirs,
        _explicit         = options.explicit,
        _cache_capacity   = options.cache_sectors,
        _cache_map        = {},
        _cache_head       = nil,
        _cache_tail       = nil,
        _cache_count      = 0,
        _handles          = {},
        _handle_order     = {},
        _handle_count     = 0,
        _max_open_handles = options.max_open_handles,
        _read_retries     = options.read_retries,
        _opt_checksums    = options.checksums,
        _manifest         = options.manifest,
        _expected         = {},
        _integrity        = {checked = 0, total = 0, manifest = nil},
        _shards           = {},
        _size             = 0,
        _sector_count     = 0,
        _stats            = new_stats(),
    }, Device)

    local shards, total = load_layout(device, "disk.new")
    install_layout(device, shards, total)
    setup_checksums(device, "disk.new")
    return device
end

---------------------------------------------------------------------------
-- Public reads
---------------------------------------------------------------------------

function Device:try_read_sector(lba)
    if not is_integer(lba) or lba < 0 then
        return nil, "LBA must be a non-negative integer (got "
            .. tostring(lba) .. ")"
    end
    if lba >= self._sector_count then
        return nil, string.format("LBA %s out of range (sector_count=%d)",
            tostring(lba), self._sector_count)
    end
    return self:_fetch(lba)
end

function Device:read_sector(lba)
    local sector, err = self:try_read_sector(lba)
    if sector == nil then
        fail("disk.read_sector", "%s", err_text(err))
    end
    return sector
end

function Device:try_read_sectors(lba, count)
    if not is_integer(count) or count < 0 then
        return nil, "count must be a non-negative integer (got "
            .. tostring(count) .. ")"
    end
    if count > MAX_SECTORS_PER_READ then
        return nil, string.format("count %s exceeds MAX_SECTORS_PER_READ "
            .. "(%d)", tostring(count), MAX_SECTORS_PER_READ)
    end
    if not is_integer(lba) or lba < 0 then
        return nil, "LBA must be a non-negative integer (got "
            .. tostring(lba) .. ")"
    end
    if lba + count > self._sector_count then
        return nil, string.format("LBA range %s+%d out of range "
            .. "(sector_count=%d)", tostring(lba), count, self._sector_count)
    end
    if count == 0 then
        return ""
    end
    if count == 1 then
        return self:_fetch(lba)
    end

    local parts = {}
    for i = 0, count - 1 do
        local sector, err = self:_fetch(lba + i)
        if sector == nil then
            return nil, err
        end
        parts[i + 1] = sector
    end
    return concat(parts)
end

function Device:read_sectors(lba, count)
    local data, err = self:try_read_sectors(lba, count)
    if data == nil then
        fail("disk.read_sectors", "%s", err_text(err))
    end
    return data
end

---------------------------------------------------------------------------
-- LBA -> (shard, offset) mapping
---------------------------------------------------------------------------

function Device:map_byte(offset)
    if not is_integer(offset) or offset < 0 then
        return nil, "byte offset must be a non-negative integer (got "
            .. tostring(offset) .. ")"
    end
    local position, inside = self:_locate(offset)
    if position == nil then
        return nil, string.format("byte offset %s out of range "
            .. "(image size=%d)", tostring(offset), self._size)
    end
    local shard = self._shards[position]
    return {
        byte       = offset,
        index      = shard.index,
        position   = position,
        path       = shard.path,
        offset     = inside,
        available  = shard.size - inside,
        lba        = floor(offset / SECTOR_SIZE),
        in_sector  = offset % SECTOR_SIZE,
    }
end

function Device:map(lba)
    if not is_integer(lba) or lba < 0 then
        return nil, "LBA must be a non-negative integer (got "
            .. tostring(lba) .. ")"
    end
    if lba >= self._sector_count then
        return nil, string.format("LBA %s out of range (sector_count=%d)",
            tostring(lba), self._sector_count)
    end
    return self:map_byte(lba * SECTOR_SIZE)
end

---------------------------------------------------------------------------
-- Geometry / introspection
---------------------------------------------------------------------------

function Device:get_size()
    return self._size
end

function Device:get_sector_count()
    return self._sector_count
end

function Device:get_shard_count()
    return #self._shards
end

function Device:get_cache_capacity()
    return self._cache_capacity
end

function Device:get_cache_count()
    return self._cache_count
end

function Device:get_shard(position)
    local shard = self._shards[position]
    if shard == nil then
        return nil, "no shard at position " .. tostring(position)
    end
    return {
        index          = shard.index,
        path           = shard.path,
        size           = shard.size,
        start          = shard.start,
        crc32          = shard.crc32,
        expected_crc32 = shard.expected_crc32,
    }
end

-- Recomputes the CRC32 of every shard and compares it with the expected
-- checksums collected at mount time.  Returns a report instead of raising so
-- callers can decide how loud to be; each entry carries ok/reason.
function Device:verify()
    local report = {
        checked = 0,
        ok      = true,
        shards  = {},
    }
    for position = 1, #self._shards do
        local shard = self._shards[position]
        local expected = self._expected[position]
        local actual, err = crc32_of_file(self, shard.path, shard.size)
        local entry = {
            index    = shard.index,
            path     = shard.path,
            size     = shard.size,
            crc32    = actual,
            expected = expected and expected.value or nil,
            verified = expected ~= nil,
        }
        if actual == nil then
            entry.ok = false
            entry.reason = err
            report.ok = false
        elseif expected ~= nil then
            report.checked = report.checked + 1
            if actual ~= expected.value then
                entry.ok = false
                report.ok = false
            else
                entry.ok = true
            end
        else
            entry.ok = true
        end
        report.shards[position] = entry
    end
    return report
end

function Device:info()
    local shards = {}
    for i = 1, #self._shards do
        local shard = self._shards[i]
        shards[i] = {
            index          = shard.index,
            path           = shard.path,
            size           = shard.size,
            start          = shard.start,
            crc32          = shard.crc32,
            expected_crc32 = shard.expected_crc32,
        }
    end
    return {
        size             = self._size,
        sector_count     = self._sector_count,
        shard_count      = #shards,
        cache_capacity   = self._cache_capacity,
        cache_count      = self._cache_count,
        open_handles     = self._handle_count,
        max_open_handles = self._max_open_handles,
        read_retries     = self._read_retries,
        integrity        = {
            checked  = self._integrity.checked,
            total    = self._integrity.total,
            manifest = self._integrity.manifest,
            verified = self._integrity.checked > 0,
        },
        shards           = shards,
    }
end

function Device:get_open_handle_count()
    return self._handle_count
end

function Device:get_max_open_handles()
    return self._max_open_handles
end

function Device:get_read_retries()
    return self._read_retries
end

function Device:stats()
    local stats = self._stats
    return {
        hits             = stats.hits,
        misses           = stats.misses,
        evictions        = stats.evictions,
        fetches          = stats.fetches,
        shard_reads      = stats.shard_reads,
        shard_bytes      = stats.shard_bytes,
        opens            = stats.opens,
        closes           = stats.closes,
        reloads          = stats.reloads,
        read_retries     = stats.read_retries,
        handle_evictions = stats.handle_evictions,
        cached           = self._cache_count,
        capacity         = self._cache_capacity,
        open_handles     = self._handle_count,
    }
end

function Device:reset_stats()
    self._stats = new_stats()
    return self
end

---------------------------------------------------------------------------
-- Cache / handle lifecycle
---------------------------------------------------------------------------

function Device:invalidate_cache()
    cache_clear(self)
    return self
end

function Device:close()
    self:_close_handles()
    cache_clear(self)
    return self
end

-- Rescans the shard files (for example after swapping a floppy) and drops
-- every cached sector.  If the new chain is invalid the device is left with
-- no geometry at all, so it cannot keep serving sectors from a stale image
-- after a failed reload.
function Device:reload()
    self:_close_handles()
    cache_clear(self)
    self._shards       = {}
    self._size         = 0
    self._sector_count = 0
    self._expected     = {}
    self._integrity    = {checked = 0, total = 0, manifest = nil}
    local shards, total = load_layout(self, "disk.reload")
    install_layout(self, shards, total)
    setup_checksums(self, "disk.reload")
    self._stats.reloads = self._stats.reloads + 1
    return self
end

---------------------------------------------------------------------------
-- Writes
---------------------------------------------------------------------------

-- Deliberately unimplemented: the DOS image is mounted read-only for now.
-- The INT 13h layer must see a real failure rather than a fake success.
function Device:write_sector(lba, data)
    error("disk.write_sector: the shard image is read-only "
        .. "(write-back is not implemented)", 0)
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

Disk.SECTOR_SIZE           = SECTOR_SIZE
Disk.DEFAULT_SHARD_SIZE    = DEFAULT_SHARD_SIZE
Disk.DEFAULT_CACHE_SECTORS = DEFAULT_CACHE_SECTORS
Disk.DEFAULT_PREFIX        = DEFAULT_PREFIX
Disk.DEFAULT_SUFFIX        = DEFAULT_SUFFIX
Disk.DEFAULT_DIRS          = DEFAULT_DIRS
Disk.MAX_SECTORS_PER_READ  = MAX_SECTORS_PER_READ
Disk.DEFAULT_MAX_OPEN_HANDLES = DEFAULT_MAX_OPEN_HANDLES
Disk.DEFAULT_READ_RETRIES  = DEFAULT_READ_RETRIES
Disk.CHECKSUM_SUFFIX       = CHECKSUM_SUFFIX
Disk.MANIFEST_NAME         = MANIFEST_NAME
Disk.Device                = Device
Disk.crc32                 = crc32
Disk.crc32_hex             = crc32_hex
Disk.hex8                  = hex8

function Disk.fs_backend()
    return make_fs_backend(rawget(_G, "fs"))
end

function Disk.io_backend()
    return make_io_backend(rawget(_G, "io"))
end

return Disk
