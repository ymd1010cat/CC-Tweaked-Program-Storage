--[[- pyroet-os/kernel/ota.lua -- system OTA client: file-set updates.

Two sources, one apply path. The default is the ROM `rednet` API (no rpv, no
net/service.lua: the network stack is what may be broken); with `rhtp` the same
description is pulled from the real upgrade server over RHTP/1.0 instead:

    GET <base>/meta.txt        -> the META line, then one FILE line per file
    GET <base>/<relpath>       -> the file body

The base is `/etc/ota.servers`' first usable line when that file exists, else
O.DEFAULT_UPGRADE (`rhtp://pyroet.pyrotechnic.org/upgrade`). meta.txt is exactly
the rednet reply text without the packet framing, so one parser reads both and
the digest/size/journal logic below is shared by both sources.

SHA-256 from /system/rpv/crypto.lua is the whole trust model (DECISIONS.md 8.3):
an unverified file set is never applied, and a file body that does not match its
declared size and sha256 never reaches /system.

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
         a/b download <relpath>.part and prove the byte count AND sha256
         c/d move /system/<relpath> into /update.backup/<relpath> and prove the
             backup really is old_sha (a bad backup aborts the whole update)
         e/f move the part into /system/<relpath>, ask the file system for the
             byte count again, and prove sha256 == new_sha
    6. journal(state=applied). Only then is a reboot allowed to try the new
       version; boot.lua's decision table takes it from there.

Any failure from step 4 on is rolled back immediately with the material the
journal describes (boot.rollback), and reported as OTA_FAIL stage=.. err=..
Verification failures (steps 2/3) are OTA_REJECT and leave `retry()` available:
nothing on disk changed, so the only cost is the download.

The declared `<size>` is checked, never assumed (DECISIONS 13.3). Three places,
because a byte count is the one thing a digest cannot tell you about:
  * the DATA loop cannot stop early -- the last chunk has to be exactly `want`;
  * the assembled .part is measured with `fs.getSize` against `<size>`, and a
    mismatch is OTA_REJECT stage=verify reason=size file=.. got=.. want=.. while
    nothing has been applied yet (retryable), or a rollback once something has;
  * the file that landed in /system is measured again before its digest is
    trusted, so a write cut short by a full disk cannot hide behind bytes whose
    digest happens to match.

    local c = dofile("/system/kernel/ota.lua").new({ fs = fs, boot = boot,
        rednet = rednet, host = 12, log = print })
    c:update(); c:status()   -- idle/fetching/.../ready/rejected/failed + bytes

...or over the network upgrade channel:

    local c = dofile("/system/kernel/ota.lua").new({ fs = fs, rhtp = rhtp,
        base = nil, log = print, progress = function(rel, i, n) end })
    c:update()

new() options: fs, boot, boot_opts, rednet, host, protocol, timeout, max_tries,
max_data, backup_cap, log, clock, sha, crypto_path, loadfile, boot_path, rhtp,
base, progress. `rhtp` switches the source; `base` overrides /etc/ota.servers;
`progress(relpath, index, count)` is called once per file before it is fetched.
Failure lines: OTA_NET_FAIL stage=<meta|file|size> url=.. err=.. for the RHTP
transport (the client adds RHTP_GET / RHTP_TIMEOUT / RHTP_DNS_FAIL lines) and
OTA_RHTP_CHUNK path=.. off=.. len=.. for every slice of a file, plus OTA_FAIL /
OTA_REJECT for the update itself. A network failure clears /update.stage before
it returns, so a rejected download leaves no residue.
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
    -- The real upgrade channel (2026-11-01): the same PYROET-OTA/2 description,
    -- fetched over RHTP/1.0 instead of rednet. `GET <base>/meta.txt` returns the
    -- META line and one FILE line per file as plain text; every file is then one
    -- chunked `GET <base>/<relpath>`. The base is /etc/ota.servers' first line
    -- when that file exists, otherwise this constant. There is no http fallback:
    -- the handheld may not have a ROM http table at all.
    DEFAULT_UPGRADE = "rhtp://pyroet.pyrotechnic.org/upgrade",
    RHTP_CONF = "/etc/ota.servers",
    META_FILE = "meta.txt",
    MAX_URL = 160,
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
-- meta.txt over RHTP + the upgrade base (the network source, 2026-11-01)
-- ---------------------------------------------------------------------------

-- Parse a whole `meta.txt` body: the META line first, then one FILE line per
-- entry, blank lines ignored (a trailing newline is normal). Pure: no fs and no
-- network, so the kernel's RHTP source and an app that only wants the remote
-- version parse with the same code.
function O.parse_manifest(body)
    if type(body) ~= "string" or body == "" then return nil, "empty meta" end
    local meta, files
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        local clean = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if clean ~= "" then
            if meta == nil then
                local m, why = O.parse_meta(clean)
                if not m then return nil, "meta " .. tostring(why) end
                meta = m
            else
                local rec, why = O.parse_file(O.PREFIX .. " FILE " .. clean)
                if not rec then return nil, "file " .. tostring(why) end
                files = files or {}
                files[#files + 1] = rec
            end
        end
    end
    if meta == nil then return nil, "meta missing" end
    files = files or {}
    if #files ~= meta.files then
        return nil, "file count " .. tostring(#files) .. "/" .. tostring(meta.files)
    end
    return meta, files
end

-- RHTP base URL, normalized without the trailing slash; the reason strings are
-- short and stable so a status line can show them verbatim. `rhtp://<host>
-- [:port]/<path>` is the only accepted scheme; a bare `<host>[:port]/<path>` is
-- read as rhtp:// (the same rule the client's own parser applies), and any other
-- explicit scheme is refused instead of silently falling back to http.
function O.valid_base(url)
    local text = tostring(url == nil and "" or url)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "empty" end
    if #text > O.MAX_URL then return nil, "too long" end
    if text:find("%s") then return nil, "space" end
    local rest = text
    if text:sub(1, 7):lower() == "rhtp://" then
        rest = text:sub(8)
    elseif text:find("://", 1, true) then
        return nil, "scheme"
    end
    local host, path = rest:match("^([^/]*)(.*)$")
    if host == nil or host == "" then return nil, "host" end
    local name = host:match("^([^:]+)") or host
    if name == "" or not name:match("^[%w%._%-]+$") then return nil, "host" end
    local port_text = host:match("^[^:]+:(%d+)$")
    if port_text ~= nil then
        local number = tonumber(port_text)
        if not number or number < 1 or number > 65535 then return nil, "port" end
    end
    if path ~= "" and path:sub(1, 1) ~= "/" then return nil, "path" end
    local normalized = "rhtp://" .. host:lower() .. path
    return (normalized:gsub("/+$", ""))
end

-- Read a whole text file through either fs flavour: the kernel's real fs (open)
-- or an app's capability-gated api.fs (read). nil means "cannot tell".
function O.read_text(fsx, path)
    if type(fsx) ~= "table" then return nil end
    if type(fsx.exists) == "function" then
        local called, has = pcall(fsx.exists, path)
        if not called or has ~= true then return nil end
    end
    if type(fsx.read) == "function" then
        local called, text = pcall(fsx.read, path)
        if called and type(text) == "string" then return text end
        return nil
    end
    return read_all(fsx, path)
end

-- The upgrade base: an explicit override wins, then the first usable line of
-- /etc/ota.servers, then the built-in default. A missing config file is not an
-- error - that is exactly the machine a fresh image ships to.
function O.upgrade_base(fsx, override)
    local explicit, why = O.valid_base(override)
    if explicit then return explicit end
    if override ~= nil and tostring(override) ~= "" then return nil, why end
    local text = O.read_text(fsx, O.RHTP_CONF)
    if type(text) == "string" then
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            local clean = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if clean ~= "" and clean:sub(1, 1) ~= "#" then
                local base, berr = O.valid_base(clean)
                if base then return base end
                return nil, "bad " .. O.RHTP_CONF .. " " .. tostring(berr)
            end
        end
    end
    return O.DEFAULT_UPGRADE
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

    -- The network source: with `rhtp` the client fetches meta.txt and every file
    -- over RHTP/1.0 instead of asking a rednet peer, and the whole apply half of
    -- the client (journal, backup, staged .part, verify) is unchanged. `rhtp` is
    -- the net service's client ({ get =, fetch = }), never a host http table.
    self.rhtp = o.rhtp
    self.rhtp_mode = type(o.rhtp) == "table" and type(o.rhtp.get) == "function"
    self.progress = o.progress
    self.base, self.base_err, self.source_error = nil, nil, nil
    if o.rhtp ~= nil and not self.rhtp_mode then
        -- asked for the network source but the host has no client: a readable
        -- failure, never a quiet fall back to rednet or to http
        self.source_error = "no rhtp"
    end
    if self.rhtp_mode then
        local base, berr = O.upgrade_base(self.fs, o.base)
        self.base, self.base_err = base, berr
        if not base then self.source_error = "base " .. tostring(berr) end
    end
    self.rhtp_files = nil
    self.gets = 0
    self.rhtp_cache = nil

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
    self.rhtp_files, self.rhtp_cache, self.applied = nil, nil, 0
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
        source = self.rhtp_mode and "rhtp" or "rednet", base = self.base,
        gets = self.gets,
    }
end

-- a fatal, non-recoverable-by-retry failure of the update as a whole
function O:fail(stage, err)
    self.stage, self.err = stage, tostring(err)
    self:set_state("failed", stage)
    self:log("OTA_FAIL stage=" .. tostring(stage) .. " err=" .. short(self.err, 48))
    -- nothing was applied on this path, so a half-downloaded /update.stage is
    -- residue: clear it and the machine stays exactly as it was
    if self.rhtp_mode and (self.applied or 0) == 0 then self:drop_stage() end
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
    if self.rhtp_mode and (self.applied or 0) == 0 then self:drop_stage() end
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

-- The byte count the file system reports for a file: fs.getSize where it exists,
-- a full read otherwise. nil means "cannot tell", which every caller treats as a
-- failure -- never as "the declared size must have been right".
function O:file_size(path)
    if not self.fs.exists(path) then return nil end
    if type(self.fs.getSize) == "function" then
        local ok, size = pcall(self.fs.getSize, path)
        if ok and type(size) == "number" then return size end
    end
    local text = read_all(self.fs, path)
    if text == nil then return nil end
    return #text
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

-- ---------------------------------------------------------------------------
-- RHTP source: GET <base>/meta.txt and GET <base>/<relpath> (2026-11-01)
--
-- The service protocol is the project's own RHTP/1.0 (system/net/rhtp.lua), not
-- a host http table: a kernel image update must not depend on a ROM API the
-- handheld may not have. The client handed in through `rhtp` is the net
-- service's, so there is one rpv node and one resolver for the whole machine.
-- ---------------------------------------------------------------------------

-- one GET -> body, or nil, reason. A 4xx/5xx is a reason ("rhtp 404"), never a
-- body: only bytes that arrived as a 2xx answer are ever looked at.
function O:rhtp_get(url)
    local client = self.rhtp
    if type(client) ~= "table" or type(client.get) ~= "function" then
        return nil, "no rhtp"
    end
    self.gets = self.gets + 1
    local called, body, extra = pcall(client.get, url)
    if not called then return nil, "rhtp fail" end
    if body == nil then return nil, short(extra or "no reply", 32) end
    if type(body) ~= "string" then return nil, "bad response" end
    if body == "" then return nil, "empty" end
    return body
end

-- One whole file, pulled in RHTP chunks (the client sends off=/len= and expects
-- 206; a server that ignores the extension answers 200 with the whole body and
-- that is accepted). The byte count is proven here, the digest in download().
function O:rhtp_fetch(url, size)
    local client = self.rhtp
    if type(client) ~= "table" or type(client.fetch) ~= "function" then
        return nil, "no rhtp"
    end
    self.gets = self.gets + 1
    local called, body, extra = pcall(client.fetch, url, size)
    if not called then return nil, "rhtp fail" end
    if body == nil then return nil, short(extra or "no reply", 32) end
    if type(body) ~= "string" then return nil, "bad response" end
    if body == "" then return nil, "empty" end
    return body
end

function O:rhtp_meta()
    local url = tostring(self.base) .. "/" .. O.META_FILE
    local body, err = self:rhtp_get(url)
    if body == nil then
        self:log("OTA_NET_FAIL stage=meta url=" .. short(url, 60)
            .. " err=" .. short(err or "?", 32))
        return nil, tostring(err or "no body")
    end
    local called, meta, files = pcall(O.parse_manifest, body)
    if not called then return nil, "bad meta" end
    if not meta then
        self:log("OTA_NET_FAIL stage=meta url=" .. short(url, 60)
            .. " err=" .. short(files or "parse", 40))
        return nil, tostring(files or "parse")
    end
    self.rhtp_files = files
    self:log("OTA_NET_OK stage=meta url=" .. short(url, 60) .. " files="
        .. tostring(#(files or {})) .. " bytes=" .. tostring(#body))
    return meta
end

-- The whole body of one file, fetched once and kept only while this file is the
-- one being written: a file is at most F_MAX bytes, and a retry of the same file
-- re-reads the copy instead of the network.
function O:rhtp_chunk(f, offset, want)
    local cache = self.rhtp_cache
    if type(cache) ~= "table" or cache.relpath ~= f.relpath then
        local url = tostring(self.base) .. "/" .. tostring(f.relpath)
        local body, err = self:rhtp_fetch(url, f.size)
        if body == nil then
            self:log("OTA_NET_FAIL stage=file url=" .. short(url, 60)
                .. " err=" .. short(err or "?", 32))
            return nil, tostring(err or "no body")
        end
        -- the declared size is part of the description: a body of another length
        -- can never be the file the manifest_sha was computed over
        if #body ~= f.size then
            self:log("OTA_NET_FAIL stage=size url=" .. short(url, 60)
                .. " got=" .. tostring(#body) .. " want=" .. tostring(f.size))
            return nil, "size got=" .. tostring(#body) .. " want=" .. tostring(f.size)
        end
        cache = { relpath = f.relpath, body = body }
        self.rhtp_cache = cache
        self:log("OTA_NET_OK stage=file url=" .. short(url, 60)
            .. " bytes=" .. tostring(#body))
    end
    if offset >= #cache.body then return nil, "offset past end" end
    self:log("OTA_RHTP_CHUNK path=" .. f.relpath .. " off=" .. tostring(offset)
        .. " len=" .. tostring(want))
    return cache.body:sub(offset + 1, offset + want)
end

-- the transport seams: rednet asks for a descriptor packet, RHTP already has the
-- whole list from meta.txt, and a chunk comes from a DATA reply or from the
-- fetched body. Everything above this line (verify, cap, journal, backup) is
-- shared by the two sources.
function O:meta_record()
    if self.rhtp_mode then return self:rhtp_meta() end
    return self:request(function()
        return O.PREFIX .. " GET meta"
    end, O.parse_meta)
end

function O:file_record(idx)
    if self.rhtp_mode then
        local rec = (self.rhtp_files or {})[idx + 1]
        if not rec then return nil, "missing file " .. tostring(idx) end
        return rec
    end
    return self:request(function()
        return O.PREFIX .. " GET " .. tostring(idx)
    end, O.parse_file)
end

function O:chunk(f, offset, want)
    if self.rhtp_mode then return self:rhtp_chunk(f, offset, want) end
    return self:request(function()
        return O.PREFIX .. " GET " .. tostring(f.idx) .. " " .. tostring(offset)
    end, function(msg)
        local d, why = O.parse_data(msg, {
            relpath = f.relpath, offset = offset, size = f.size,
        })
        if not d then return nil, why end
        if #d.data ~= want then return nil, "chunk " .. #d.data .. "/" .. want end
        return d.data
    end)
end

-- Remove the staging tree without touching the journal or the backup tree: the
-- stage only holds a download in progress, so dropping it can never make the
-- machine unbootable (boot.cleanup, which also drops journal and backup, is a
-- different decision and not taken here).
function O:drop_stage()
    local paths = self:paths()
    if type(paths) ~= "table" or type(paths.stage) ~= "string" then return false end
    if not self.fs.exists(paths.stage) then return true end
    local function rm(path)
        local called, names = pcall(self.fs.list, path)
        if called and type(names) == "table" then
            for i = 1, #names do
                local child = path .. "/" .. tostring(names[i])
                local is_dir = false
                if type(self.fs.isDir) == "function" then
                    local dcalled, value = pcall(self.fs.isDir, child)
                    is_dir = (dcalled and value) == true
                end
                if is_dir then rm(child) else pcall(self.fs.delete, child) end
            end
        end
        pcall(self.fs.delete, path)
    end
    rm(paths.stage)
    self:log("OTA_STAGE_DROP path=" .. short(paths.stage, 40))
    return true
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
            local data, derr = self:chunk(f, offset, want)
            if not data then
                err = derr
                break
            end
            if not pcall(handle.write, data) then
                err = "write_failed"
                break
            end
            at = at + #data
        end
        pcall(handle.close)
        -- the byte count before the digest: a short or padded write has to be
        -- named as a size problem, not as a digest problem. `at` only counts what
        -- this loop handed to write(), so the file system is asked what really
        -- landed (DECISIONS 13.3).
        local got_size, kind = nil, nil
        if not err and at ~= f.size then
            got_size, kind = at, "size"
            err = "size got=" .. tostring(at) .. " want=" .. tostring(f.size)
        end
        if not err then
            got_size = self:file_size(part)
            if got_size ~= f.size then
                kind = "size"
                err = "size got=" .. tostring(got_size) .. " want=" .. tostring(f.size)
            end
        end
        if not err then
            local got = self:file_sha(part)
            if got == f.sha256 then return true end
            kind = "digest"
            err = "digest " .. short(got and got:sub(1, 12) or "?", 12)
        end
        self.retries = self.retries + 1
        self:log("OTA_RETRY attempt=" .. attempt .. " max=" .. self.max_tries
            .. " err=file " .. short(err, 32))
        if attempt == self.max_tries then
            -- the caller needs to know WHICH proof failed: a wrong byte count is
            -- a verification refusal, a wrong digest or a lost packet is not
            if kind == "size" then
                return nil, err, "size", "file=" .. f.relpath
                    .. " got=" .. tostring(got_size) .. " want=" .. tostring(f.size)
            end
            return nil, err, kind
        end
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
    local okd, derr, dkind, ddetail = self:download(f, part)
    if not okd then
        pcall(self.fs.delete, part)
        -- a byte count that is not the declared one is a verification refusal
        -- (the server described N bytes and something else arrived); everything
        -- else here is a transfer failure
        if dkind == "size" then return nil, "verify", ddetail end
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
    -- the .part was proven, but the file that landed is a different file: ask the
    -- file system for its size before trusting the digest, because a write that
    -- was cut short can still hash to the right value only by accident
    local landed = self:file_size(target)
    if landed ~= f.size then
        return nil, "install", "size got=" .. tostring(landed)
            .. " want=" .. tostring(f.size)
    end
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
    -- rollback deletes the stage itself; asking again is cheap and covers the
    -- rollback-failure branch, where an unverified half file must not linger
    if self.rhtp_mode then self:drop_stage() end
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
    if self.source_error then return self:fail("prepare", self.source_error) end
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
    if self.rhtp_mode then
        self:log("OTA_SOURCE kind=rhtp base=" .. short(self.base, 60))
    else
        self:log("OTA_SOURCE kind=rednet host=" .. tostring(self.host))
    end

    local meta, merr = self:meta_record()
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
        local rec, ferr = self:file_record(idx)
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

    local applied = 0
    for i = 1, #files do
        -- the one progress hook: the caller paints `fetching <rel> (i/n)` before
        -- the file is fetched, so a network download shows what it is doing
        if type(self.progress) == "function" then
            pcall(self.progress, files[i].relpath, i, #files)
        end
        local ok, stage, detail = self:apply_one(files[i])
        if not ok then
            self.applied = applied
            -- A size refusal before anything was applied leaves the disk exactly
            -- as it was, so it is the same retryable reject as a bad
            -- manifest_sha; once a file has landed the only honest answer is the
            -- rollback (DECISIONS 13.3).
            if stage == "verify" and applied == 0 then
                self:cleanup()
                return self:reject("verify", "size", detail)
            end
            return self:apply_failure(stage, detail)
        end
        applied = applied + 1
        self.applied = applied
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
