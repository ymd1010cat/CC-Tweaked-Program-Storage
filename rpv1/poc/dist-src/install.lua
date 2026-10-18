--[[- install.lua — RPV1 library installer (runs ON a CC:Tweaked computer).

Three sources:

    install.lua                     -- files sitting next to this script (dir/floppy copy)
    install.lua /disk               -- a directory (disk drive, floppy, subfolder)
    install.lua https://host/base   -- an HTTP(S) base URL that serves rpv-<v>.zip contents

Options:

    --target <dir>     install into this directory (default "/")
    --log <file>       also write every line to this file (headless installs)
    --no-examples      skip examples/ and docs
    --quiet            only print the result lines

It copies the library tree, verifies every file against MANIFEST.txt (CRC32 + size,
computed in pure Lua), then loads the freshly installed library and builds a node
to prove the install works. Prints:

    INSTALL_OK files=<n> verified=<n> skipped=<n>
    INSTALL_VERIFY ok=true|false version=RPV1 modules=10
]]
local args = { ... }
local OPT = { target = "/", examples = true, quiet = false }
local source = nil
for _, a in ipairs(args) do
    if a == "--no-examples" then OPT.examples = false
    elseif a == "--quiet" then OPT.quiet = true
    elseif a == "--target" then OPT.want_target = true
    elseif a == "--log" then OPT.want_log = true
    elseif OPT.want_target then OPT.target = a; OPT.want_target = nil
    elseif OPT.want_log then OPT.log_path = a; OPT.want_log = nil
    elseif source == nil then source = a end
end
if OPT.target:sub(-1) ~= "/" then OPT.target = OPT.target .. "/" end

local logFile = OPT.log_path and fs.open(OPT.log_path, "w") or nil
local function emit(line)
    if logFile then logFile.writeLine(line); logFile.flush() end
    print(line)
end
local function say(fmt, ...)
    local line = string.format(fmt, ...)
    if logFile then logFile.writeLine(line); logFile.flush() end
    if not OPT.quiet then print(line) end
end
local function result(fmt, ...)
    local line = string.format(fmt, ...)
    if logFile then logFile.writeLine(line); logFile.flush() end
    print(line)
end

-- ---- pure-Lua CRC32 (integrity against truncation/corruption) --------------
-- CC:Tweaked ships Lua 5.2 (bit32). Lua 5.3+ dropped bit32 for real operators, so
-- compile those lazily (a literal `a ~ b` would not even parse on 5.2).
local BXOR, BAND, BNOT
if bit32 then
    BXOR, BAND, BNOT = bit32.bxor, bit32.band, bit32.bnot
else
    local ok, ops = pcall(function()
        return load("return function(a,b) return a ~ b end, function(a,b) return a & b end, function(a) return ~a end")()
    end)
    if ok and ops then
        local raw_xor, raw_and, raw_not = ops()
        local M32 = 0xFFFFFFFF
        BXOR = function(a, b) return raw_and(raw_xor(a, b), M32) end
        BAND = function(a, b) return raw_and(raw_and(a, b), M32) end
        BNOT = function(a) return raw_and(raw_not(a), M32) end
    else
        result("INSTALL_FAIL no bitwise support (need bit32 or Lua 5.3+)")
        return
    end
end

local CRC_TABLE
local function crc32(s)
    if not CRC_TABLE then
        CRC_TABLE = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if c % 2 == 1 then c = BXOR(0xEDB88320, math.floor(c / 2)) else c = math.floor(c / 2) end
            end
            CRC_TABLE[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        local b = s:byte(i)
        crc = BXOR(CRC_TABLE[BAND(BXOR(crc, b), 0xFF)], math.floor(crc / 256))
    end
    return BAND(BNOT(crc), 0xFFFFFFFF)
end
local function crc_hex(n) return string.format("%08x", n) end

local function read(path)
    local f = fs.open(path, "rb")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function mtime_dir(path)
    local ok, isdir = pcall(fs.isDir, path)
    return ok and isdir
end

local function ensure_dir(path)
    if path == "/" or path == "" then return true end
    if mtime_dir(path) then return true end
    local parent = path:match("^(.*)/[^/]+$") or "/"
    ensure_dir(parent)
    fs.makeDir(path)
    return mtime_dir(path)
end

-- manifest line:  sha256  crc32  size  path
local function parse_manifest(text)
    local files = {}
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            local sha, crc, size, path = line:match("^(%x+)%s+(%x+)%s+(%d+)%s+(.+)$")
            if path then files[#files + 1] = { sha = sha, crc = crc, size = tonumber(size), path = path } end
        end
    end
    return files
end

local is_url = source and source:match("^https?://")

-- ---- gather the manifest ---------------------------------------------------
local manifest_text, base
if is_url then
    base = source:gsub("/$", "") .. "/"
    local ok, res = pcall(function() return http.get(base .. "MANIFEST.txt") end)
    if ok and res then manifest_text = res.readAll(); res.close() end
    if not manifest_text then
        result("INSTALL_FAIL manifest=<%s>", tostring(ok and "no response" or res))
        return
    end
else
    base = source or "."
    if base:sub(-1) ~= "/" then base = base .. "/" end
    manifest_text = read(base .. "MANIFEST.txt")
    if not manifest_text then
        result("INSTALL_FAIL no MANIFEST.txt in %s (run this next to the unpacked release)", base)
        return
    end
end
manifest_text = manifest_text:gsub("\r", "")

local files = parse_manifest(manifest_text)
if #files == 0 then result("INSTALL_FAIL manifest-empty"); return end
say("install: %d files from %s -> %s", #files, base, OPT.target)

-- ---- copy + verify ---------------------------------------------------------
local copied, verified, skipped, failed = 0, 0, 0, {}
for _, entry in ipairs(files) do
    local rel = entry.path
    if OPT.examples or (rel:sub(1, 9) ~= "examples/" and rel:sub(-3) ~= ".md") then
        local data
        if is_url then
            local ok, res = pcall(function() return http.get(base .. rel) end)
            if ok and res then data = res.readAll(); res.close() end
        else
            data = read(base .. rel)
        end
        if not data then
            failed[#failed + 1] = rel .. " (missing)"
        else
            local target = OPT.target .. rel
            ensure_dir(target:match("^(.*)/[^/]+$") or "/")
            local f = fs.open(target, "wb")
            if not f then
                failed[#failed + 1] = rel .. " (cannot write)"
            else
                f.write(data)
                f.close()
                copied = copied + 1
                if #data == entry.size and crc_hex(crc32(data)) == entry.crc then
                    verified = verified + 1
                else
                    failed[#failed + 1] = string.format("%s (crc %s != %s)", rel, crc_hex(crc32(data)), entry.crc)
                end
            end
        end
    else
        skipped = skipped + 1
    end
end

if #failed > 0 then
    for _, f in ipairs(failed) do say("install: FAILED %s", f) end
    result("INSTALL_FAIL files=%d verified=%d bad=%d", copied, verified, #failed)
    return
end
result("INSTALL_OK files=%d verified=%d skipped=%d", copied, verified, skipped)

-- ---- prove the installed copy loads and runs -------------------------------
local entry = OPT.target .. "rpv.lua"
local bundle = OPT.target .. "rpv-bundle.lua"
local loader = fs.exists(entry) and entry or (fs.exists(bundle) and bundle or nil)
if not loader then
    result("INSTALL_VERIFY ok=false version=? modules=0 (no rpv.lua installed)")
    return
end
local ok, rpv = pcall(function() return dofile(loader) end)
if not ok or type(rpv) ~= "table" then
    result("INSTALL_VERIFY ok=false version=? modules=0 err=%s", tostring(rpv))
    return
end
local node_ok, node = pcall(function()
    local n = rpv.node_new({ role = "host" })
    return n
end)
result("INSTALL_VERIFY ok=%s version=%s modules=%d node_new=%s", tostring(node_ok), tostring(rpv.version),
    rpv.modules and #rpv.modules or 0, tostring(node_ok))
say("installed to %s (examples=%s)", OPT.target, tostring(OPT.examples))
say("next: put rpv.lua + rpv/ on your computer, then `local rpv = require(\"rpv\")`")
