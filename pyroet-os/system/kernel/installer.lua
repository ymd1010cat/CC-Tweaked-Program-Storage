--[[- pyroet-os/kernel/installer.lua -- application installer (medium or memory).

Installs `<name>.app` into `/apps/<name>.app` (replacing an older copy) or removes
it. Package format is the runtime's (DECISIONS.md 5): `manifest.lua` + `main.lua`,
validated by kernel/apps.lua through `A:read_manifest(dir)` -- never parsed a
second time here. Sources: opts.dir, then packages[name] (in memory), then
<media_root>/<name>.app.

Stage in `/apps/.tmp-<name>/`, validate there (files present, manifest valid,
optional `SHA256SUMS` = `<64 hex>  <relpath>` verified file by file, optional
sizes), then replace
`/apps/<name>.app`: INSTALL_REPLACE, delete old, `fs.move` the temp in, and when
move is refused copy + verify + delete the temp (CraftOS `fs.move` never
overwrites; boot.lua uses the same fallback). Any failure deletes the temp and
keeps the installed version (INSTALL_FAIL name=... err=...).

A declared size is checked against the bytes that actually landed, in the two
places a package can declare one (DECISIONS.md 5.2):

  * per file, as a third column of `SHA256SUMS`:
    `<64 hex>  <size>  <relpath>` or `<64 hex>  <relpath>  <size>`;
  * once for the package, as the manifest's `size`: the byte total of everything
    except `manifest.lua` itself (a file cannot contain its own final length).

Neither is required: without them the package is verified by digest only, which
is what every package written before the field existed relies on.

uninstall deletes only `/apps/<name>.app`; `/system/system/<name>.app` is refused
(INSTALL_REMOVE_DENIED ... reason=system) because system apps move only through an
OTA image (DECISIONS.md 1.2(c)). list() reports both roots.

    local inst = dofile("/system/kernel/installer.lua").new({ fs = fs, log = print })
    inst:install("hello"); inst:uninstall("hello"); inst:list()

new() options: fs, log, apps, loadfile, sha, crypto_path, media_root, apps_root,
system_root, packages. No non-ASCII bytes in this file.
]]

local I = { VERSION = "1.0", NAME_MAX = 40 }
-- user apps live in /apps, the image's own apps in /system/system (P6-3), and
-- SHA-256 comes from the rpv module that ships with the image
local APP, SYS, SUMS, CRYPTO = "/apps", "/system/system", "SHA256SUMS",
    "/system/rpv/crypto.lua"

local function short(v, max)
    local s = tostring(v == nil and "nil" or v):gsub("[\r\n\t]+", " ")
        :gsub("[^%w%._%-:=/ ]", "_")
    max = max or 40
    if #s > max then s = s:sub(1, max) end
    return s == "" and "-" or s
end

local function join(dir, name)
    local head = tostring(dir):gsub("/+$", "")
    return (head == "" and "/" or head) .. "/" .. name
end

local function read_all(fsx, path)
    if not fsx.exists(path) then return nil end
    local handle = fsx.open(path, "r")
    if not handle then return nil end
    local text
    if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
    handle.close()
    return text or ""
end

local function mkdirp(fsx, path)
    if not path or path == "" or fsx.exists(path) then return true end
    local parent = fsx.getDir(path)
    if parent and parent ~= "" and parent ~= "/" then mkdirp(fsx, parent) end
    pcall(fsx.makeDir, path)
    return fsx.exists(path)
end

local function rm(fsx, path)
    if not fsx.exists(path) then return true end
    pcall(fsx.delete, path)
    return not fsx.exists(path)
end

-- sorted relative paths of every regular file under dir
local function tree(fsx, dir, prefix, out)
    out = out or {}
    local names = fsx.list(dir) or {}
    table.sort(names)
    for i = 1, #names do
        local path = join(dir, names[i])
        local rel = prefix and (prefix .. "/" .. names[i]) or names[i]
        if fsx.isDir(path) then tree(fsx, path, rel, out) else out[#out + 1] = rel end
    end
    return out
end

-- SHA-256 from the image's crypto module (DECISIONS.md 3.1); its rpv module
-- convention (`local M = ...`) means loadfile + table, not dofile
local function sha_of(opts, loadfn)
    if type(opts.sha) == "function" then return opts.sha end
    local lf = loadfn or rawget(_G, "loadfile")
    if type(lf) ~= "function" then return nil end
    local ok, chunk = pcall(lf, opts.crypto_path or CRYPTO)
    if not ok or type(chunk) ~= "function" then return nil end
    local mod = {}
    if not pcall(chunk, mod) or type(mod.sha256) ~= "function" then return nil end
    return mod.sha256
end

local function hex(data)
    return (tostring(data):gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- /system/rpv/crypto.lua's sha256 returns the 32 raw digest bytes, a test double may
-- return hex; SHA256SUMS is hex either way, so normalise here once
local function digest(fn, text)
    local out = tostring(fn(text))
    if #out == 32 then out = hex(out) end
    return out:lower()
end

-- the byte count a package file really has: fs.getSize where the file system
-- offers one, a full read otherwise. nil means "cannot tell", which is a
-- verification failure and never an excuse to accept the declared number.
local function size_of(fsx, path)
    if not fsx.exists(path) then return nil end
    if type(fsx.getSize) == "function" then
        local ok, size = pcall(fsx.getSize, path)
        if ok and type(size) == "number" then return size end
    end
    local text = read_all(fsx, path)
    if text == nil then return nil end
    return #text
end

-- one `SHA256SUMS` line: "<hex>  <rel>" with an optional size, in either the
-- middle or the last column. nil means the line is not a sums line at all.
local function parse_sums_line(line)
    local hex, one, two = line:match("^(%x+)%s+(%S+)%s+(%S+)%s*$")
    if hex then
        if two:match("^%d+$") then return hex, one, tonumber(two) end
        if one:match("^%d+$") then return hex, two, tonumber(one) end
        return nil
    end
    hex, one = line:match("^(%x+)%s+(%S+)%s*$")
    if hex then return hex, one, nil end
    return nil
end

function I.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = I })
    self.fs, self.sink, self.logs, self.rt = o.fs or rawget(_G, "fs"), o.log, {}, nil
    self.loadfile = o.loadfile or rawget(_G, "loadfile")
    self.apps = o.apps
    self.media_root, self.packages = o.media_root or "/disk/apps", o.packages or {}
    self.apps_root, self.system_root = o.apps_root or APP, o.system_root or SYS
    self.sha = sha_of(o, self.loadfile)
    return self
end

function I:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then pcall(self.sink, line) end
end

-- one throw-away runtime instance is enough to reuse `A:read_manifest(dir)`
function I:read_manifest(dir)
    if type(self.apps) ~= "table" then
        local ok, mod = pcall(dofile, "/system/kernel/apps.lua")
        if ok and type(mod) == "table" then self.apps = mod end
    end
    if type(self.apps) ~= "table" or type(self.apps.new) ~= "function" then
        return nil, "no manifest parser"
    end
    self.rt = self.rt or self.apps.new({ fs = self.fs, loadfile = self.loadfile })
    return self.rt:read_manifest(dir)
end

function I:valid_name(name)
    return type(name) == "string" and #name > 0 and #name <= I.NAME_MAX
        and name:match("^[%w_%.%-]+$") ~= nil and name:find("..", 1, true) == nil
end

-- `<64 hex>  <relpath>` per line (an optional size may be a third column: every
-- listed file must exist and match, and every file must be listed -- a manifest
-- that may skip a file proves nothing). A declared size has to be the real one.
function I:verify_sums(dir)
    local fsx, sha, want, count = self.fs, self.sha, {}, 0
    if type(sha) ~= "function" then
        self:log("INSTALL_HASH_UNAVAILABLE file=" .. SUMS)
        return nil, "no sha256"
    end
    for line in (read_all(fsx, join(dir, SUMS)) or ""):gmatch("[^\r\n]+") do
        count = count + 1
        local hex, rel, declared = parse_sums_line(line)
        if not hex or #hex ~= 64 or not rel or rel:find("..", 1, true)
            or rel:sub(1, 1) == "/" then
            self:log("INSTALL_HASH_BAD file=" .. SUMS .. " line=" .. count)
            return nil, "bad sums line"
        end
        if want[rel] then
            self:log("INSTALL_HASH_BAD file=" .. short(rel, 48) .. " reason=duplicate")
            return nil, "duplicate " .. rel
        end
        want[rel] = { sha = hex:lower(), size = declared }
    end
    if count == 0 then
        self:log("INSTALL_HASH_BAD file=" .. SUMS .. " reason=empty")
        return nil, "empty sums"
    end
    for rel, entry in pairs(want) do
        local path = join(dir, rel)
        local body = read_all(fsx, path)
        local got = body and digest(sha, body)
        if got ~= entry.sha then
            self:log("INSTALL_HASH_BAD file=" .. short(rel, 48)
                .. (got and (" want=" .. entry.sha:sub(1, 12) .. " got=" .. got:sub(1, 12))
                    or " reason=missing"))
            return nil, "digest " .. rel
        end
        if entry.size ~= nil then
            local actual = size_of(fsx, path)
            if actual ~= entry.size then
                self:log("INSTALL_SIZE_BAD file=" .. short(rel, 48)
                    .. " got=" .. tostring(actual) .. " want=" .. tostring(entry.size))
                return nil, "size " .. rel
            end
        end
    end
    local listed = tree(fsx, dir)
    for i = 1, #listed do
        if listed[i] ~= SUMS and not want[listed[i]] then
            self:log("INSTALL_HASH_BAD file=" .. short(listed[i], 48) .. " reason=unlisted")
            return nil, "unlisted " .. listed[i]
        end
    end
    return true
end

-- DECISIONS.md 5.2: a package may declare `size`, the byte total of everything it
-- ships. `manifest.lua` is excluded because a file cannot contain its own final
-- length, so counting it would make the field impossible to fill in. An
-- undeclared size is not an error: a package written before the field existed
-- installs on its digests alone.
function I:verify_total(dir, declared)
    local want = tonumber(declared)
    if not want or want < 0 or want ~= math.floor(want) then
        self:log("INSTALL_SIZE_BAD scope=package reason=declared value="
            .. short(declared, 16))
        return nil, "bad size"
    end
    local total = 0
    local listed = tree(self.fs, dir)
    for i = 1, #listed do
        if listed[i] ~= "manifest.lua" then
            total = total + (size_of(self.fs, join(dir, listed[i])) or 0)
        end
    end
    if total ~= want then
        self:log("INSTALL_SIZE_BAD scope=package got=" .. tostring(total)
            .. " want=" .. tostring(want))
        return nil, "size " .. tostring(total) .. "/" .. tostring(want)
    end
    return true, total
end

function I:fail(name, tmp, err, extra)
    if tmp then rm(self.fs, tmp) end
    if extra then rm(self.fs, extra) end
    self:log("INSTALL_FAIL name=" .. tostring(name) .. " err=" .. short(err))
    return nil, tostring(err)
end

-- write the declared files of an in-memory package into the staging directory
function I:stage_memory(name, tmp)
    local fsx, map, names = self.fs, self.packages[name], {}
    for rel in pairs(map) do names[#names + 1] = rel end
    table.sort(names)
    for i = 1, #names do
        local rel, path = names[i], join(tmp, names[i])
        if rel:find("..", 1, true) or rel:sub(1, 1) == "/" then
            return nil, "bad path " .. short(rel, 24)
        end
        local handle = mkdirp(fsx, fsx.getDir(path)) and fsx.open(path, "w") or nil
        if not handle then return nil, "cannot write " .. short(rel, 24) end
        pcall(handle.write, tostring(map[rel]))
        handle.close()
    end
    return true
end

function I:install(name, opts)
    local o, fsx = opts or {}, self.fs
    if not self:valid_name(name) then
        self:log("INSTALL_FAIL name=" .. short(name) .. " err=bad_name")
        return nil, "bad name"
    end
    local final = join(self.apps_root, name .. ".app")
    local tmp = join(self.apps_root, ".tmp-" .. name)
    if not mkdirp(fsx, self.apps_root) then return self:fail(name, nil, "no app root") end
    rm(fsx, tmp)
    if not mkdirp(fsx, tmp) then return self:fail(name, nil, "no temp dir") end

    local src = o.dir
    if src == nil then
        local medium = join(self.media_root, name .. ".app")
        if fsx.exists(medium) and fsx.isDir(medium) then src = medium end
    end
    if src then
        pcall(fsx.copy, src, tmp)
        if not fsx.exists(join(tmp, "manifest.lua")) then
            return self:fail(name, tmp, "copy failed " .. short(src, 32))
        end
    elseif self.packages[name] then
        local okm, errm = self:stage_memory(name, tmp)
        if not okm then return self:fail(name, tmp, errm) end
    else
        return self:fail(name, tmp, "no_source")
    end

    -- validate the staged copy: what passed here is what moves into /apps
    local manifest, verr
    if not fsx.exists(join(tmp, "manifest.lua")) then verr = "missing manifest.lua" end
    if not fsx.exists(join(tmp, "main.lua")) then verr = "missing main.lua" end
    if not verr then manifest, verr = self:read_manifest(tmp) end
    if manifest and fsx.exists(join(tmp, SUMS)) then
        local oks, serr = self:verify_sums(tmp)
        if not oks then manifest, verr = nil, serr end
    end
    if manifest then
        -- the runtime validates a manifest and keeps the caller's table in
        -- `manifest.raw`, so a declared size is read from whichever of the two
        -- carries it
        local declared = manifest.size
        if declared == nil and type(manifest.raw) == "table" then
            declared = manifest.raw.size
        end
        if declared ~= nil then
            local okt, terr = self:verify_total(tmp, declared)
            if not okt then manifest, verr = nil, terr end
        end
    end
    if not manifest then return self:fail(name, tmp, verr or "invalid package") end
    if manifest.name ~= name then
        return self:fail(name, tmp, "manifest_name:" .. tostring(manifest.name))
    end

    local replaced = fsx.exists(final)
    if replaced then
        self:log("INSTALL_REPLACE name=" .. name)
        if not rm(fsx, final) then return self:fail(name, tmp, "cannot remove old") end
    end

    pcall(fsx.move, tmp, final)
    local method = "move"
    if not (fsx.exists(final) and not fsx.exists(tmp)) then
        method = "copy"
        self:log("INSTALL_MOVE_FALLBACK path=" .. short(final, 32) .. " reason=refused")
        pcall(fsx.copy, tmp, final)
        if not fsx.exists(final) then return self:fail(name, tmp, "copy failed") end
        local la, lb = tree(fsx, tmp), tree(fsx, final)
        if #la ~= #lb then return self:fail(name, tmp, "count " .. #la .. "/" .. #lb, final) end
        for i = 1, #la do
            if la[i] ~= lb[i] or read_all(fsx, join(tmp, la[i]))
                ~= read_all(fsx, join(final, la[i])) then
                return self:fail(name, tmp, "verify " .. short(la[i], 24), final)
            end
        end
        rm(fsx, tmp)   -- installed already: a leftover temp is only wasted space
    end
    self:log("INSTALL_OK name=" .. name .. " version=" .. short(manifest.version, 24)
        .. " method=" .. method)
    return true, { name = name, version = manifest.version, replaced = replaced, method = method }
end

function I:uninstall(name)
    local fsx = self.fs
    if not self:valid_name(name) then
        self:log("INSTALL_REMOVE_DENIED name=" .. short(name) .. " reason=bad_name")
        return nil, "bad name"
    end
    local path = join(self.apps_root, name .. ".app")
    if not fsx.exists(path) then
        if fsx.exists(join(self.system_root, name .. ".app")) then
            self:log("INSTALL_REMOVE_DENIED name=" .. name .. " reason=system")
            return nil, "system app"
        end
        self:log("INSTALL_REMOVE_MISSING name=" .. name)
        return nil, "not installed"
    end
    if not rm(fsx, path) then
        self:log("INSTALL_FAIL name=" .. name .. " err=cannot_remove")
        return nil, "cannot remove"
    end
    self:log("INSTALL_REMOVE name=" .. name)
    return true
end

function I:scan(root, source, entries)
    local fsx = self.fs
    local names = (fsx.exists(root) and fsx.isDir(root) and fsx.list(root)) or {}
    table.sort(names)
    for i = 1, #names do
        local dir = join(root, names[i])
        if names[i]:sub(-4) == ".app" and fsx.isDir(dir) then
            local manifest, err = self:read_manifest(dir)
            entries[#entries + 1] = {
                name = names[i]:sub(1, #names[i] - 4), dir = dir, root = root,
                source = source, version = manifest and manifest.version or "?",
                ok = manifest ~= nil, error = manifest and nil or err,
            }
        end
    end
end

function I:list()
    local entries = {}
    self:scan(self.apps_root, "apps", entries)
    self:scan(self.system_root, "system", entries)
    table.sort(entries, function(a, b)
        if a.name == b.name then return a.root < b.root end
        return a.name < b.name
    end)
    local apps = 0
    for i = 1, #entries do
        if entries[i].source == "apps" then apps = apps + 1 end
    end
    self:log("INSTALL_LIST count=" .. #entries .. " apps=" .. apps)
    return entries
end

return I
