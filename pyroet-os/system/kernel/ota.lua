--[[- pyroet-os/kernel/ota.lua -- system OTA client: file-set updates over rednet.

Uses only the ROM `rednet` API (no rpv, no net/service.lua: the network stack is
what may be broken) plus SHA-256 from /rpv/crypto.lua. An unverified file set is
never applied; SHA-256 plus framing is the whole trust model (DECISIONS.md 8.3).

Protocol PYROET-OTA/2 (P6-design section 3), still one bare-rednet request per
packet:

    request  PYROET-OTA/2 GET meta
    reply    PYROET-OTA/2 META version=<t> files=<n> manifest_sha=<64 hex>
    request  PYROET-OTA/2 GET <idx>                 idx is 0-based
    reply    PYROET-OTA/2 FILE <relpath> <size> <sha256>
    request  PYROET-OTA/2 GET <idx> <offset>
    reply    PYROET-OTA/2 DATA <relpath> <offset> <hex>

`MAX_DATA = 8192` payload bytes per DATA packet (v1 packed 32 KiB into 64 KiB of
hex, right at the rednet packet limit; the smaller chunk leaves room for the
relpath and the offset). A lost packet costs one request, never correctness.

Order (P6-design sections 3 and 5, and this is the safety argument):

    1. META, then every FILE line. No byte is downloaded yet.
    2. aggregate manifest hash over (relpath, size, sha256) == META.manifest_sha.
       A mismatch is OTA_REJECT stage=verify: /system was never touched, so
       dropping the intent is all the recovery that is needed.
    3. BACKUP_CAP check over the bytes that will be backed up (files that exist):
       over the cap is OTA_REJECT stage=cap, again before anything is written.
    4. journal(state=prepare) -- the intent, with old_sha computed LOCALLY.
    5. journal(state=applying), then for every file, in order:
         a/b download <relpath>.part and prove size + sha256
         c/d move /system/<relpath> into /update.backup/<relpath> and prove the
             backup really is old_sha (a bad backup aborts the whole update)
         e/f move the part into /system/<relpath> and prove sha256 == new_sha
    6. journal(state=applied). Only then is a reboot allowed to try the new
       version; boot.lua's decision table takes it from there.

Any failure from step 4 on is rolled back immediately with the material the
journal describes (boot.rollback), and reported as OTA_FAIL stage=.. err=..
Verification failures (steps 2/3) are OTA_REJECT and leave `retry()` available:
nothing on disk changed, so the only cost is the download.

    local c = dofile("/system/kernel/ota.lua").new({ fs = fs, boot = boot,
        rednet = rednet, host = 12, log = print })
    c:update(); c:status()   -- idle/fetching/.../ready/rejected/failed + bytes

new() options: fs, boot, boot_opts, rednet, host, protocol, timeout, max_tries,
max_data, backup_cap, log, clock, sha, crypto_path, loadfile, boot_path.
No non-ASCII bytes in this file.
]]

local O = {
    VERSION = "2.0",
    PREFIX = "PYROET-OTA/2",
    PROTOCOL = "pyroet-ota",
    MAX_TRIES = 3,
    TIMEOUT = 3,
    MAX_DATA = 8192,
    F_MAX = 65536,
    MAX_FILES = 256,
    BACKUP_CAP = 200000,
    CRYPTO = "/system/rpv/crypto.lua",
    BOOT_PATH = "/system/boot.lua",
    EXT = { lua = true, txt = true, conf = true, cfg = true },
    RESERVED = {
        ["update.journal"] = true, ["update.backup"] = true, ["boot.ok"] = true,
        ["boot.tries"] = true, ["startup.lua"] = true,
    },
}

local function short(value, max)
    local s = tostring(value == nil and "nil" or value):gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 40
    if #s > max then s = s:sub(1, max) end
    return s == "" and "-" or s
end

local function path_join(base, rest)
    local head = tostring(base or "")
    if head == "" or head == "/" then return "/" .. tostring(rest) end
    head = head:gsub("/+$", "")
    if head == "" then return "/" .. tostring(rest) end
    return head .. "/" .. tostring(rest)
end

local function dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or ""
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
    if not path or path == "" or path == "/" or fsx.exists(path) then return true end
    local parent = fsx.getDir(path)
    if parent and parent ~= "" and parent ~= "/" then mkdirp(fsx, parent) end
    pcall(fsx.makeDir, path)
    return fsx.exists(path) and true or nil, "cannot create " .. tostring(path)
end

local function unhex(text)
    text = tostring(text or "")
    if #text % 2 ~= 0 or text:find("[^0-9a-fA-F]") then return nil end
    return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function hex(data)
    return (tostring(data):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
end

-- SHA-256 from the image's crypto module; its rpv module convention
-- (`local M = ...`) means loadfile + table, not dofile
local function load_sha(opts, loadfn)
    if type(opts.sha) == "function" then return opts.sha end
    local lf = loadfn or opts.loadfile or rawget(_G, "loadfile")
    if type(lf) ~= "function" then return nil end
    local ok, chunk = pcall(lf, opts.crypto_path or O.CRYPTO)
    if not ok or type(chunk) ~= "function" then return nil end
    local mod = {}
    if not pcall(chunk, mod) or type(mod.sha256) ~= "function" then return nil end
    return mod.sha256
end

-- a test double may return the 32 raw digest bytes; packets carry hex
local function digest(fn, text)
    local out = tostring(fn(text))
    if #out == 32 then out = hex(out) end
    return out:lower()
end

-- ---------------------------------------------------------------------------
-- parsing (pure functions, exported for the tests)
-- ---------------------------------------------------------------------------

-- "PREFIX VERB rest..." -> rest, or nil, reason. Anything else is not ours.
function O.split(msg)
    if type(msg) ~= "string" then return nil, "not a string" end
    if msg:sub(1, #O.PREFIX + 1) ~= O.PREFIX .. " " then return nil, "wrong protocol" end
    return msg:sub(#O.PREFIX + 2)
end

-- Strict key=value list: unknown keys, duplicates and missing keys are all
-- errors, so a malformed META can never be read as "whatever was recognised"
local function fields(text, required)
    local out = {}
    for token in tostring(text):gmatch("%S+") do
        local key, value = token:match("^([%a_]+)=(%S+)$")
        if not key then return nil, "bad token " .. short(token, 24) end
        if out[key] ~= nil then return nil, "duplicate " .. key end
        out[key] = value
    end
    for i = 1, #required do
        if out[required[i]] == nil then return nil, "missing " .. required[i] end
    end
    for key in pairs(out) do
        local known = false
        for i = 1, #required do
            if required[i] == key then known = true end
        end
        if not known then return nil, "unexpected " .. short(key, 24) end
    end
    return out
end

function O.parse_meta(msg)
    local body, why = O.split(msg)
    if not body then return nil, why end
    local verb, rest = body:match("^(%S+)%s*(.*)$")
    if verb ~= "META" then return nil, "not META" end
    local f, ferr = fields(rest, { "version", "files", "manifest_sha" })
    if not f then return nil, ferr end
    local version = f.version
    if #version < 1 or #version > 32 then return nil, "bad version" end
    if version:find("[^%w%._%-]") then return nil, "bad version" end
    local files = tonumber(f.files)
    if not files or files ~= math.floor(files) or files < 1 or files > O.MAX_FILES then
        return nil, "bad files"
    end
    if #f.manifest_sha ~= 64 or not f.manifest_sha:match("^[%x]+$") then
        return nil, "bad manifest_sha"
    end
    return { version = version, files = files, manifest_sha = f.manifest_sha:lower() }
end

-- PYROET-OTA/2 FILE <relpath> <size> <sha256>
function O.parse_file(msg)
    local body, why = O.split(msg)
    if not body then return nil, why end
    local verb, relpath, size, sha = body:match("^(%S+) (%S+) (%S+) (%S+)$")
    if verb ~= "FILE" then return nil, "not FILE" end
    local ok, perr = O.valid_path(relpath)
    if not ok then return nil, perr end
    local n = tonumber(size)
    if not n or n ~= math.floor(n) or n < 1 or n > O.F_MAX then return nil, "bad size" end
    if #sha ~= 64 or not sha:match("^[%x]+$") then return nil, "bad sha256" end
    return { relpath = relpath, size = n, sha256 = sha:lower() }
end

-- PYROET-OTA/2 DATA <relpath> <offset> <hex>; `want` pins the request/reply pair
function O.parse_data(msg, want)
    local body, why = O.split(msg)
    if not body then return nil, why end
    local verb, relpath, offset, payload = body:match("^(%S+) (%S+) (%S+) (%S+)$")
    if verb ~= "DATA" then return nil, "not DATA" end
    local ok, perr = O.valid_path(relpath)
    if not ok then return nil, perr end
    local off = tonumber(offset)
    if not off or off ~= math.floor(off) or off < 0 then return nil, "bad offset" end
    if off % O.MAX_DATA ~= 0 then return nil, "bad offset" end
    if want then
        if want.relpath and relpath ~= want.relpath then return nil, "wrong relpath" end
        if want.offset and off ~= want.offset then return nil, "wrong offset" end
        if want.size and off >= want.size then return nil, "offset past end" end
    end
    if #payload % 2 ~= 0 then return nil, "odd hex" end
    if #payload > O.MAX_DATA * 2 then return nil, "payload too large" end
    local data = unhex(payload)
    if not data then return nil, "bad hex" end
    if #data == 0 then return nil, "empty payload" end
    return { relpath = relpath, offset = off, data = data }
end

-- Path whitelist / traversal guard (P6-design 3.3). Every rule has to hold; the
-- reason strings are stable enough to assert on.
function O.valid_path(relpath)
    if type(relpath) ~= "string" or relpath == "" then return nil, "bad_path" end
    if #relpath > 96 then return nil, "bad_path" end
    for i = 1, #relpath do
        local byte = relpath:byte(i)
        if byte < 33 or byte > 126 then return nil, "bad_path" end
    end
    if relpath:sub(1, 1) == "/" then return nil, "bad_path" end
    if relpath:sub(-1) == "/" then return nil, "bad_path" end
    if relpath:find("//", 1, true) then return nil, "bad_path" end
    local segments = {}
    for segment in (relpath .. "/"):gmatch("([^/]*)/") do
        segments[#segments + 1] = segment
    end
    for i = 1, #segments do
        local segment = segments[i]
        if segment == "" or segment == "." or segment == ".." then return nil, "bad_path" end
        if segment:sub(1, 1) == "." then return nil, "bad_path" end
        if not segment:match("^[%w_%-%.]+$") then return nil, "bad_path" end
        if O.RESERVED[segment] then return nil, "reserved" end
    end
    local last = segments[#segments]
    local ext = last:match("%.([%w]+)$")
    if not ext or not O.EXT[ext:lower()] then return nil, "bad_ext" end
    return true
end

-- The one definition of the aggregate hash (P6-design 3.2): sorted by relpath,
-- one "<relpath>\0<size>\0<lowercase sha>\n" line per file, one SHA-256 over the
-- whole string. An empty list hashes the empty string.
function O.manifest_hash(files, sha)
    local sorted = {}
    for i = 1, #files do sorted[i] = files[i] end
    table.sort(sorted, function(a, b) return tostring(a.relpath) < tostring(b.relpath) end)
    local parts = {}
    for i = 1, #sorted do
        local f = sorted[i]
        parts[#parts + 1] = tostring(f.relpath) .. "\0" .. tostring(f.size) .. "\0"
            .. tostring(f.sha256 or f.new_sha):lower() .. "\n"
    end
    return digest(sha, table.concat(parts))
end

-- ---------------------------------------------------------------------------
-- client
-- ---------------------------------------------------------------------------

function O.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = O })
    self.fs = o.fs or rawget(_G, "fs")
    self.boot = o.boot
    self.sink = o.log
    self.logs = {}
    self.rednet = o.rednet or rawget(_G, "rednet")
    self.host = o.host
    self.protocol = o.protocol or O.PROTOCOL
    self.timeout = o.timeout or O.TIMEOUT
    self.max_tries = o.max_tries or O.MAX_TRIES
    self.max_data = o.max_data or O.MAX_DATA
    self.cap = o.backup_cap or O.BACKUP_CAP
    self.clock = o.clock or os.clock
    self.loader = o.loadfile or rawget(_G, "loadfile")
    self.boot_path = o.boot_path or O.BOOT_PATH
    self.sha = load_sha(o, self.loader)

    -- own copy: the caller's table must not be mutated, but the bootloader needs
    -- the same fs / sha / root / log as this client
    local bo = {}
    for key, value in pairs(o.boot_opts or {}) do bo[key] = value end
    if bo.fs == nil then bo.fs = self.fs end
    if bo.log == nil then bo.log = self.sink end
    if bo.sha == nil then bo.sha = self.sha end
    if bo.loadfile == nil then bo.loadfile = self.loader end
    self.boot_opts = bo

    self:reset()
    return self
end

function O:reset()
    self.state, self.stage, self.err = "idle", nil, nil
    self.states = { "idle" }
    self.files = {}
    self.bytes, self.retries, self.backup_bytes = 0, 0, 0
    self.version, self.manifest, self.journal_seq, self.fatal = nil, nil, nil, nil
end

function O:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then pcall(self.sink, line) end
end

function O:set_state(name, stage)
    self.state = name
    if stage then self.stage = stage end
    self.states[#self.states + 1] = name
end

function O:status()
    local names = {}
    for i = 1, #self.files do names[i] = self.files[i].relpath end
    local states = {}
    for i = 1, #self.states do states[i] = self.states[i] end
    return {
        state = self.state, stage = self.stage, version = self.version,
        manifest_sha = self.manifest, files = names, count = #self.files,
        bytes = self.bytes, backup = self.backup_bytes, cap = self.cap,
        retries = self.retries, error = self.err, fatal = self.fatal,
        journal = self.journal_seq, states = states,
    }
end

-- a fatal, non-recoverable-by-retry failure of the update as a whole
function O:fail(stage, err)
    self.stage, self.err = stage, tostring(err)
    self:set_state("failed", stage)
    self:log("OTA_FAIL stage=" .. tostring(stage) .. " err=" .. short(self.err, 48))
    return nil, self.err
end

-- verification refused the update BEFORE anything was written: /system is
-- untouched, so the client stays retryable
function O:reject(stage, reason, detail)
    self.stage, self.err = stage, tostring(reason)
    self:set_state("rejected", stage)
    local line = "OTA_REJECT stage=" .. tostring(stage) .. " reason=" .. tostring(reason)
    if detail then line = line .. " " .. tostring(detail) end
    self:log(line)
    return nil, self.err
end

function O:boot_module()
    if type(self.boot) ~= "table" then
        local ok, mod = pcall(dofile, self.boot_path)
        if ok and type(mod) == "table" then self.boot = mod end
    end
    return self.boot
end

function O:digest(text)
    return digest(self.sha, text)
end

function O:file_sha(path)
    local text = read_all(self.fs, path)
    if text == nil then return nil end
    return self:digest(text)
end

function O:paths()
    local boot = self:boot_module()
    if type(boot) == "table" and type(boot.paths) == "function" then
        return boot.paths(self.boot_opts)
    end
    return nil
end

function O:system_path(relpath)
    return path_join(self:paths().system, relpath)
end

-- move with the copy + read-back + delete fallback CraftOS forces on us
function O:move(src, dst)
    if self.fs.move then
        local ok = pcall(self.fs.move, src, dst)
        if ok and self.fs.exists(dst) and not self.fs.exists(src) then return true, "move" end
    end
    if not self.fs.copy then return nil, "no copy fallback" end
    local ok = pcall(self.fs.copy, src, dst)
    if not ok or not self.fs.exists(dst) then return nil, "copy failed" end
    local before, after = read_all(self.fs, src), read_all(self.fs, dst)
    if before == nil or before ~= after then return nil, "copy mismatch" end
    pcall(self.fs.delete, src)
    return true, "copy"
end

-- one request, one peer-filtered reply; a stray packet is ignored and the clock
-- keeps running, so it cannot spin forever
function O:exchange(request)
    local net = self.rednet
    if type(net) ~= "table" or not net.send or not net.receive then
        return nil, "no_rednet"
    end
    if not pcall(net.send, self.host, request, self.protocol) then
        return nil, "send_failed"
    end
    local deadline = self.clock() + self.timeout
    while true do
        local left = deadline - self.clock()
        if left <= 0 then return nil, "timeout" end
        local ok, sender, msg = pcall(net.receive, self.protocol, left)
        if not ok then return nil, "receive_failed" end
        if sender == nil then return nil, "timeout" end
        if sender == self.host and type(msg) == "string"
            and msg:sub(1, #O.PREFIX + 1) == O.PREFIX .. " " then
            return msg
        end
    end
end

-- a missing reply and a packet that fails `accept` both cost one attempt, which
-- turns a corrupted packet into a retransmission instead of a failure
function O:request(build, accept)
    local err = "timeout"
    for attempt = 1, self.max_tries do
        local msg, xerr = self:exchange(build())
        local parsed, perr
        if msg then parsed, perr = accept(msg) end
        if parsed then return parsed end
        err = perr or xerr or "timeout"
        self.retries = self.retries + 1
        self:log("OTA_RETRY attempt=" .. attempt .. " max=" .. self.max_tries
            .. " err=" .. short(err, 32))
    end
    return nil, err
end

-- step a/b for one file: fetch every chunk of <relpath> into <path>.part and
-- prove the assembled bytes; a mismatch retries the whole file (no bitmap)
function O:download(f, part)
    for attempt = 1, self.max_tries do
        if self.fs.exists(part) then pcall(self.fs.delete, part) end
        local handle = self.fs.open(part, "w")
        if not handle then return nil, "cannot open " .. part end
        local at, err = 0, nil
        while at < f.size do
            local offset = at
            local want = math.min(self.max_data, f.size - at)
            local data, derr = self:request(function()
                return O.PREFIX .. " GET " .. tostring(f.idx) .. " " .. tostring(offset)
            end, function(msg)
                local d, why = O.parse_data(msg, {
                    relpath = f.relpath, offset = offset, size = f.size,
                })
                if not d then return nil, why end
                if #d.data ~= want then return nil, "chunk " .. #d.data .. "/" .. want end
                return d
            end)
            if not data then
                err = derr
                break
            end
            if not pcall(handle.write, data.data) then
                err = "write_failed"
                break
            end
            at = at + #data.data
        end
        pcall(handle.close)
        if not err and at == f.size then
            local got = self:file_sha(part)
            if got == f.sha256 then return true end
            err = "digest " .. short(got and got:sub(1, 12) or "?", 12)
        elseif not err then
            err = "size " .. tostring(at) .. "/" .. tostring(f.size)
        end
        self.retries = self.retries + 1
        self:log("OTA_RETRY attempt=" .. attempt .. " max=" .. self.max_tries
            .. " err=file " .. short(err, 32))
        if attempt == self.max_tries then return nil, err end
    end
    return nil, "unreachable"
end

-- steps a-f for one file (P6-design 5.1). Returns true, or nil, stage, detail.
function O:apply_one(f)
    local paths = self:paths()
    local part = path_join(paths.stage, f.relpath .. ".part")
    if not mkdirp(self.fs, dirname(part)) then
        return nil, "stage", "cannot create " .. short(dirname(part), 40)
    end
    local okd, derr = self:download(f, part)
    if not okd then
        pcall(self.fs.delete, part)
        return nil, "chunk", derr
    end

    -- c/d: the old bytes move to the backup tree and are proven before the
    -- system file disappears for good
    local target = self:system_path(f.relpath)
    if f.old_sha ~= "-" then
        local backup = path_join(paths.backup, f.relpath)
        if not mkdirp(self.fs, dirname(backup)) then
            return nil, "backup", "cannot create " .. short(dirname(backup), 40)
        end
        if self.fs.exists(backup) then pcall(self.fs.delete, backup) end
        local moved, merr = self:move(target, backup)
        if not moved then return nil, "backup", merr end
        local back = self:file_sha(backup)
        if back ~= f.old_sha then
            -- the backup is not what the journal says the old file was: put it
            -- back and abandon the update instead of overwriting with garbage
            self:move(backup, target)
            return nil, "backup", "verify " .. short(back and back:sub(1, 12) or "?", 12)
        end
    end

    -- e/f: install and read back (the only proof of a write CC can give)
    local installed, ierr = self:move(part, target)
    if not installed then return nil, "install", ierr end
    local got = self:file_sha(target)
    if got ~= f.sha256 then
        return nil, "install", "verify " .. short(got and got:sub(1, 12) or "?", 12)
    end
    self:log("OTA_APPLIED path=" .. f.relpath .. " new=" .. f.sha256:sub(1, 12))
    return true
end

function O:cleanup()
    local boot = self:boot_module()
    if type(boot) == "table" and type(boot.cleanup) == "function" then
        boot.cleanup(self.boot_opts)
    end
end

-- an applying-phase failure: restore the old bytes NOW (the journal is the only
-- description of what was touched) and report
function O:apply_failure(stage, err)
    self.stage, self.err = stage, tostring(err)
    self:log("OTA_FAIL stage=" .. tostring(stage) .. " err=" .. short(self.err, 48))
    local boot = self:boot_module()
    local ok = false
    if type(boot) == "table" and type(boot.rollback) == "function" then
        ok = boot.rollback(self.boot_opts) and true or false
    end
    if ok then
        self:set_state("rolled_back", stage)
        self:log("OTA_ROLLED_BACK stage=" .. tostring(stage))
        return nil, self.err
    end
    self.fatal = "rollback_fail"
    self:set_state("failed", stage)
    self:log("OTA_ROLLBACK_FAIL stage=" .. tostring(stage))
    self:log("FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
    return nil, self.err
end

local function journal_files(files)
    local out = {}
    for i = 1, #files do
        local f = files[i]
        out[i] = {
            relpath = f.relpath, old_sha = f.old_sha,
            new_sha = f.sha256, bytes = f.size,
        }
    end
    return out
end

function O:update()
    self:reset()
    self:set_state("fetching", "meta")
    if type(self.sha) ~= "function" then return self:fail("prepare", "no_sha256") end
    local boot = self:boot_module()
    if type(boot) ~= "table" or type(boot.write_journal) ~= "function"
        or type(boot.paths) ~= "function" then
        return self:fail("prepare", "boot module unavailable")
    end
    local paths = boot.paths(self.boot_opts)
    if not self.fs.exists(paths.system) then
        return self:fail("prepare", "no_system")
    end

    local meta, merr = self:request(function()
        return O.PREFIX .. " GET meta"
    end, O.parse_meta)
    if not meta then return self:fail("meta", merr) end
    self.version, self.manifest = meta.version, meta.manifest_sha
    self:log("OTA_META version=" .. meta.version .. " files=" .. tostring(meta.files)
        .. " manifest_sha=" .. meta.manifest_sha:sub(1, 12))

    -- the whole description first: no byte is downloaded before it is known what
    -- the update will touch, and old_sha is computed locally (never trusted from
    -- the server)
    self:set_state("listing", "files")
    local files, backup, seen = {}, 0, {}
    for idx = 0, meta.files - 1 do
        local rec, ferr = self:request(function()
            return O.PREFIX .. " GET " .. tostring(idx)
        end, O.parse_file)
        if not rec then return self:fail("file", ferr) end
        if seen[rec.relpath] then return self:fail("file", "duplicate " .. rec.relpath) end
        seen[rec.relpath] = true
        rec.idx = idx
        rec.old_sha = self:file_sha(path_join(paths.system, rec.relpath)) or "-"
        if rec.old_sha ~= "-" then backup = backup + rec.size end
        files[#files + 1] = rec
        self.files = files
        self.bytes = self.bytes + rec.size
        self:log("OTA_FILE idx=" .. tostring(idx) .. " path=" .. rec.relpath
            .. " size=" .. tostring(rec.size) .. " sha256=" .. rec.sha256:sub(1, 12)
            .. " old=" .. short(rec.old_sha, 12))
    end

    self:set_state("verifying", "manifest")
    local aggregate = O.manifest_hash(files, self.sha)
    self.manifest_hash = aggregate
    self:log("OTA_MANIFEST files=" .. tostring(#files) .. " bytes=" .. tostring(self.bytes)
        .. " backup=" .. tostring(backup) .. " sha256=" .. aggregate:sub(1, 12))
    if aggregate ~= meta.manifest_sha then
        return self:reject("verify", "manifest_sha",
            "got=" .. aggregate:sub(1, 12) .. " want=" .. meta.manifest_sha:sub(1, 12))
    end
    self.backup_bytes = backup
    if backup > self.cap then
        return self:reject("cap", "too_big",
            "need=" .. tostring(backup) .. " cap=" .. tostring(self.cap))
    end

    -- from here on the disk is mutated, so the intent has to be on disk first
    local entries = journal_files(files)
    self:set_state("applying", "prepare")
    local seq, jerr = boot.write_journal({
        state = "prepare", version = meta.version,
        manifest_sha = meta.manifest_sha, files = entries,
    }, self.boot_opts)
    if not seq then
        self:cleanup()
        return self:fail("journal", jerr)
    end
    self.journal_seq = seq
    self:log("OTA_JOURNAL seq=" .. tostring(seq) .. " state=prepare")

    local seq2, jerr2 = boot.write_journal({
        seq = seq + 1, state = "applying", version = meta.version,
        manifest_sha = meta.manifest_sha, files = entries,
    }, self.boot_opts)
    if not seq2 then
        -- nothing was replaced yet: the prepare journal plus the old system is
        -- already a consistent picture, and cleanup restores it exactly
        self:cleanup()
        return self:fail("journal", jerr2)
    end
    self.journal_seq = seq2
    self:set_state("applying", "apply")
    self:log("OTA_JOURNAL seq=" .. tostring(seq2) .. " state=applying")

    for i = 1, #files do
        local ok, stage, detail = self:apply_one(files[i])
        if not ok then return self:apply_failure(stage, detail) end
    end

    local seq3, jerr3 = boot.write_journal({
        seq = seq2 + 1, state = "applied", version = meta.version,
        manifest_sha = meta.manifest_sha, files = entries,
    }, self.boot_opts)
    if not seq3 then return self:apply_failure("journal", jerr3) end
    self.journal_seq = seq3
    self:log("OTA_JOURNAL seq=" .. tostring(seq3) .. " state=applied")

    self:set_state("ready", "applied")
    self:log("OTA_READY version=" .. meta.version .. " files=" .. tostring(#files)
        .. " bytes=" .. tostring(self.bytes)
        .. " manifest_sha=" .. meta.manifest_sha:sub(1, 12))
    return true, self:status()
end

-- A rejected update changed nothing, so pulling it again from the top is enough.
function O:retry()
    if self.fatal then return nil, "rollback failed; flash required" end
    if self.state ~= "rejected" and self.state ~= "rolled_back" then
        return nil, "nothing to retry (state=" .. tostring(self.state) .. ")"
    end
    self:log("OTA_RETRY_FROM state=" .. tostring(self.state))
    return self:update()
end

-- Throw away an intent that was never applied: journal + stage + backup.
function O:discard()
    self:cleanup()
    self:log("OTA_DISCARD")
    self:reset()
    return true
end

return O
