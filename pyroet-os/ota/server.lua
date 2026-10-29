--[[- pyroet-os/ota/server.lua -- PYROET-OTA/2 distribution side (the "134" box).

This module is the other end of `system/kernel/ota.lua`: it answers the three
requests in P6-design.md section 3.1 over a bare `rednet` modem. It is a
distribution-side tool, NOT image content: it never ships in `install.set` and
never runs on a Pyroet OS pocket computer (DECISIONS.md 15). A plain CraftOS
computer with a modem, this one file and a publish directory is the whole
deployment.

Publish directory layout (the relpath is the path under the directory):

    <dir>/meta.txt          sidecar: "version=<tok>" (and optionally
                            "files=<n>" / "manifest_sha=<64 hex>" pins)
    <dir>/kernel/ota.lua    -> relpath "kernel/ota.lua"
    <dir>/net/x.conf        -> relpath "net/x.conf"

`meta.txt` is the only file at the root that is not part of the update set; a
mirror of `/system` copies it next to the tree without ever serving it.

Wire format -- byte for byte the client's, because the client is the only
authority on what a correct reply looks like:

    request  PYROET-OTA/2 GET meta
    reply    PYROET-OTA/2 META version=<t> files=<n> manifest_sha=<64 hex>
    request  PYROET-OTA/2 GET <idx>                 idx is 0-based
    reply    PYROET-OTA/2 FILE <relpath> <size> <sha256>
    request  PYROET-OTA/2 GET <idx> <offset>
    reply    PYROET-OTA/2 DATA <relpath> <offset> <hex>

The FILE descriptions are served one per `GET <idx>` (that is how the client
asks for them); `srv:describe()` prints META plus every FILE line, each line
identical to the reply to the corresponding request, for a human or a diff.

Everything that can diverge from the client is defined once here and pinned by
tests/t_ota_server.lua:

  * the aggregate hash of P6-design 3.2 (sorted relpath, NUL separated, one
    SHA-256 over the whole string; the empty set hashes the empty string);
  * lowercase hex for every digest and every DATA payload;
  * `MAX_DATA`-aligned offsets and the same chunk arithmetic
    (`min(MAX_DATA, size - offset)`), so the last chunk of a file is short;
  * the path whitelist of P6-design 3.3, copied from the client because the
    distribution centre is a plain computer that need not have
    `/system/kernel/ota.lua`. `tests/t_ota_server.lua` runs a differential over
    every rule in both directions, so a copy that drifts is a test failure, not
    a silent divergence between the two ends.

Fail-closed on the publishing side, on purpose: a manifest that is internally
inconsistent (a digest that does not match the bytes, a manifest_sha that does
not match the records, a file over `F_MAX`, a path outside the whitelist) is
refused by `M.new`/`M.build_manifest` instead of being served and rejected by
every client in the field one by one. Nothing is signed: SHA-256 plus framing
is the whole trust model (DECISIONS.md 15.3), and the "signature" of a publish
directory is the `manifest_sha` pin in its `meta.txt`.

    local S = dofile("/ota/server.lua")
    local srv = S.new({ fs = fs, rednet = rednet, dir = "/publish" })
    srv:serve()                    -- answers GET meta / GET idx / GET idx off
    -- srv:stop() from another task; srv:stats(); srv:describe()

No non-ASCII bytes in this file.
]]

local M = {
    VERSION = "1.0",
    PREFIX = "PYROET-OTA/2",
    PROTOCOL = "pyroet-ota",
    -- The client's constants, repeated so this file works on a machine that has
    -- no /system tree at all. tests/t_ota_server.lua asserts them equal.
    MAX_DATA = 8192,
    F_MAX = 65536,
    MAX_FILES = 256,
    MAX_PATH = 96,
    TIMEOUT = 3,
    CRYPTO = "/system/rpv/crypto.lua",
    SIDECAR = "meta.txt",
    EXT = { lua = true, txt = true, conf = true, cfg = true },
    RESERVED = {
        ["update.journal"] = true, ["update.backup"] = true, ["boot.ok"] = true,
        ["boot.tries"] = true, ["startup.lua"] = true,
    },
}

-- ---------------------------------------------------------------------------
-- small helpers (same shapes as the client's, so the log/digest handling is
-- identical on both sides)
-- ---------------------------------------------------------------------------

-- a reason string that can travel inside one `key=value` token
local function safe(value, max)
    local s = tostring(value == nil and "-" or value):gsub("%s+", " ")
    s = s:gsub("[^%w_%-%.]", "_")
    max = max or 32
    if #s > max then s = s:sub(1, max) end
    return s == "" and "-" or s
end

local function hex(data)
    return (tostring(data):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
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

-- the rpv crypto module is `local M = ...`, so it is loaded as a chunk fed an
-- empty table, exactly like kernel/ota.lua does it
local function load_sha(opts)
    if type(opts.sha) == "function" then return opts.sha end
    local lf = opts.loadfile or rawget(_G, "loadfile")
    if type(lf) ~= "function" then return nil end
    local ok, chunk = pcall(lf, opts.crypto_path or M.CRYPTO)
    if not ok or type(chunk) ~= "function" then return nil end
    local mod = {}
    if not pcall(chunk, mod) or type(mod.sha256) ~= "function" then return nil end
    return mod.sha256
end

-- a test double may return the 32 raw digest bytes; everything on the wire is
-- lowercase hex (the client normalises the same way)
local function digest(fn, text)
    local out = tostring(fn(text))
    if #out == 32 then out = hex(out) end
    return out:lower()
end

local function is_sha64(value)
    return type(value) == "string" and #value == 64 and value:match("^[%x]+$") ~= nil
end

local function valid_version(value)
    if type(value) ~= "string" then return nil end
    if #value < 1 or #value > 32 then return nil end
    if value:find("[^%w%._%-]") then return nil end
    return value
end

function M:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then pcall(self.sink, line) end
end

-- ---------------------------------------------------------------------------
-- path whitelist / traversal guard (P6-design 3.3)
-- ---------------------------------------------------------------------------

-- Copied rule for rule from the client's `O.valid_path`
-- (system/kernel/ota.lua:235-260): the distribution centre must not need the
-- client file to publish, and tests/t_ota_server.lua differentially compares
-- the two tables (accept/reject AND reason) so this copy cannot drift silently.
function M.valid_path(relpath)
    if type(relpath) ~= "string" or relpath == "" then return nil, "bad_path" end
    if #relpath > M.MAX_PATH then return nil, "bad_path" end
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
        if M.RESERVED[segment] then return nil, "reserved" end
    end
    local last = segments[#segments]
    local ext = last:match("%.([%w]+)$")
    if not ext or not M.EXT[ext:lower()] then return nil, "bad_ext" end
    return true
end

-- ---------------------------------------------------------------------------
-- the aggregate hash (P6-design 3.2, single definition)
-- ---------------------------------------------------------------------------

-- One "<relpath>\0<size>\0<lowercase sha>\n" line per file, sorted by relpath
-- byte order, one SHA-256 over the concatenation. Sorted HERE, so the index the
-- client asks for and the order the hash is built in are the same order.
function M.manifest_hash(files, sha)
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
-- building a manifest from a publish directory
-- ---------------------------------------------------------------------------

-- Walk `<base>` and collect (relpath, size, sha256, data) for every file except
-- the root `meta.txt` sidecar. Anything the client would refuse is refused here
-- instead: a path outside the whitelist, a zero-length file, a file over F_MAX,
-- more than MAX_FILES files. `state.bad` short-circuits the walk.
local function walk(fsx, base, rel, out, state)
    if state.bad then return end
    local dir = rel == "" and base or (base .. "/" .. rel)
    local names = fsx.list(dir)
    if type(names) ~= "table" then
        state.bad = { relpath = rel, why = "list_failed" }
        return
    end
    table.sort(names)
    for i = 1, #names do
        if state.bad then return end
        local name = names[i]
        local path = dir .. "/" .. name
        local sub = rel == "" and name or (rel .. "/" .. name)
        if fsx.isDir(path) then
            walk(fsx, base, sub, out, state)
        elseif not (rel == "" and name == M.SIDECAR) then
            local ok, why = M.valid_path(sub)
            if not ok then
                state.bad = { relpath = sub, why = why }
                return
            end
            local data = read_all(fsx, path)
            if data == nil then
                state.bad = { relpath = sub, why = "read_failed" }
                return
            end
            if #data < 1 then
                state.bad = { relpath = sub, why = "bad_size" }
                return
            end
            if #data > M.F_MAX then
                state.bad = { relpath = sub, why = "too_large" }
                return
            end
            if #out >= M.MAX_FILES then
                state.bad = { relpath = sub, why = "too_many_files" }
                return
            end
            out[#out + 1] = { relpath = sub, size = #data, sha256 = digest(state.sha, data),
                data = data }
        end
    end
end

-- Strict key=value sidecar: blank lines and '#' comments are ignored, unknown
-- keys, duplicates and unparsable tokens are errors. `files=` and
-- `manifest_sha=` are OPTIONAL pins, so a mirror can prove it is serving the
-- bytes that were tested rather than whatever a later edit left behind.
local function read_sidecar(fsx, path)
    local text = read_all(fsx, path)
    if text == nil then return nil, "missing_meta" end
    local out = {}
    local known = { version = true, files = true, manifest_sha = true }
    for line in tostring(text):gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([%a_]+)=(%S+)$")
            if not key then return nil, "bad_meta_line" end
            if not known[key] then return nil, "unexpected_" .. key end
            if out[key] ~= nil then return nil, "duplicate_" .. key end
            out[key] = value
        end
    end
    return out
end

-- M.build_manifest(dir[, opts]) -> manifest | nil, why, offending relpath
-- opts: fs, sha, crypto_path, loadfile, log. The manifest carries the ordered
-- records (each with idx 0-based and its bytes) plus version/bytes/count/hash.
function M.build_manifest(dir, opts)
    local o = opts or {}
    local fsx = o.fs or rawget(_G, "fs")
    local sink = o.log or function() end
    if type(fsx) ~= "table" then return nil, "no_fs" end
    if type(dir) ~= "string" or dir == "" then return nil, "no_dir" end
    if not fsx.exists(dir) or not fsx.isDir(dir) then return nil, "no_dir" end

    local sha = load_sha(o)
    if type(sha) ~= "function" then
        sink("OTA_SERVER_BUILD_FAIL why=no_sha256 dir=" .. safe(dir))
        return nil, "no_sha256"
    end

    local meta, merr = read_sidecar(fsx, dir .. "/" .. M.SIDECAR)
    if not meta then
        sink("OTA_SERVER_BUILD_FAIL why=" .. merr .. " dir=" .. safe(dir))
        return nil, merr
    end
    local version = valid_version(meta.version)
    if not version then
        sink("OTA_SERVER_BUILD_FAIL why=bad_version dir=" .. safe(dir))
        return nil, "bad_version"
    end

    local recs = {}
    local state = { sha = sha, bad = nil }
    walk(fsx, dir, "", recs, state)
    if state.bad then
        sink("OTA_SERVER_BAD_FILE path=" .. safe(state.bad.relpath, 96)
            .. " why=" .. safe(state.bad.why))
        return nil, state.bad.why, state.bad.relpath
    end
    if #recs > M.MAX_FILES then
        sink("OTA_SERVER_BUILD_FAIL why=too_many_files dir=" .. safe(dir))
        return nil, "too_many_files"
    end

    table.sort(recs, function(a, b) return a.relpath < b.relpath end)
    local bytes = 0
    for i = 1, #recs do
        recs[i].idx = i - 1
        bytes = bytes + recs[i].size
    end
    local hash = M.manifest_hash(recs, sha)

    -- optional pins written by whoever prepared the mirror
    if meta.files ~= nil and tostring(meta.files) ~= tostring(#recs) then
        sink("OTA_SERVER_BUILD_FAIL why=files_mismatch got=" .. tostring(#recs)
            .. " want=" .. tostring(meta.files))
        return nil, "files_mismatch"
    end
    if meta.manifest_sha ~= nil then
        if not is_sha64(meta.manifest_sha) then
            sink("OTA_SERVER_BUILD_FAIL why=bad_manifest_sha")
            return nil, "bad_manifest_sha"
        end
        if meta.manifest_sha:lower() ~= hash then
            sink("OTA_SERVER_BUILD_FAIL why=manifest_sha_mismatch got=" .. hash:sub(1, 12)
                .. " want=" .. meta.manifest_sha:lower():sub(1, 12))
            return nil, "manifest_sha_mismatch"
        end
    end

    sink("OTA_SERVER_MANIFEST dir=" .. safe(dir, 64) .. " version=" .. version
        .. " files=" .. tostring(#recs) .. " bytes=" .. tostring(bytes)
        .. " manifest_sha=" .. hash:sub(1, 12))
    return {
        version = version, files = recs, count = #recs, bytes = bytes,
        manifest_sha = hash, dir = dir,
    }
end

-- ---------------------------------------------------------------------------
-- the server instance
-- ---------------------------------------------------------------------------

function M:err(reason)
    return M.PREFIX .. " ERR reason=" .. safe(reason)
end

function M:stats()
    return {
        packets = self.packets, served = self.served, errors = self.errors,
        ignored = self.ignored, bytes = self.bytes, running = self.running,
        files = self.files and #self.files or 0,
        version = self.manifest and self.manifest.version or nil,
        manifest_sha = self.manifest and self.manifest.manifest_sha or nil,
        error = self.error,
    }
end

-- Validate and order an in-memory manifest. Every check is fail-closed: a record
-- that the client could not parse, a digest that does not match the bytes, a
-- manifest_sha that does not match the records -- all of them are refused here
-- with `self.error` set, because handing them to a client can only waste a
-- download. Returns true or nil, why.
function M:load_manifest(manifest)
    if type(manifest) ~= "table" then return nil, "no_manifest" end
    if type(manifest.files) ~= "table" then return nil, "no_manifest" end
    local version = valid_version(manifest.version)
    if not version then return nil, "bad_version" end
    if type(self.sha) ~= "function" then return nil, "no_sha256" end
    if #manifest.files > M.MAX_FILES then return nil, "too_many_files" end

    local recs, seen, bytes = {}, {}, 0
    for i = 1, #manifest.files do
        local f = manifest.files[i]
        if type(f) ~= "table" then return nil, "bad_record" end
        local ok, why = M.valid_path(f.relpath)
        if not ok then return nil, why end
        if seen[f.relpath] then return nil, "duplicate" end
        seen[f.relpath] = true

        local data = f.data
        local size = f.size
        if data ~= nil then
            if type(data) ~= "string" then return nil, "bad_data" end
            if size ~= nil and tonumber(size) ~= #data then return nil, "size_mismatch" end
            size = #data
        end
        size = tonumber(size)
        if not size or size ~= math.floor(size) or size < 1 or size > M.F_MAX then
            return nil, "bad_size"
        end

        local want = f.sha256
        local got
        if data ~= nil then
            got = digest(self.sha, data)
            if want ~= nil and tostring(want):lower() ~= got then return nil, "sha_mismatch" end
            want = got
        else
            if not is_sha64(want) then return nil, "bad_sha256" end
            want = tostring(want):lower()
        end

        bytes = bytes + size
        recs[#recs + 1] = { relpath = f.relpath, size = size, sha256 = want, data = data }
    end

    table.sort(recs, function(a, b) return a.relpath < b.relpath end)
    for i = 1, #recs do recs[i].idx = i - 1 end
    local hash = M.manifest_hash(recs, self.sha)

    if manifest.manifest_sha ~= nil then
        if not is_sha64(manifest.manifest_sha) then return nil, "bad_manifest_sha" end
        if tostring(manifest.manifest_sha):lower() ~= hash then
            return nil, "manifest_sha_mismatch"
        end
    end

    self.files = recs
    self.manifest = {
        version = version, files = recs, count = #recs, bytes = bytes,
        manifest_sha = hash,
    }
    self.error = nil
    return true
end

-- opts: fs, log, rednet, channel (the rednet protocol string; "channel" is the
-- task's name for it -- bare rednet has no numeric channels), manifest, dir,
-- sha, crypto_path, loadfile, timeout.
function M.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = M })
    self.sink = o.log
    self.logs = {}
    self.fs = o.fs or rawget(_G, "fs")
    self.rednet = o.rednet or rawget(_G, "rednet")
    self.protocol = o.channel or o.protocol or M.PROTOCOL
    self.timeout = o.timeout or M.TIMEOUT
    self.loader = o.loadfile or rawget(_G, "loadfile")
    self.sha = load_sha(o)
    self.running = false
    self.packets, self.served, self.errors, self.ignored, self.bytes = 0, 0, 0, 0, 0

    local manifest = o.manifest
    if manifest == nil and o.dir ~= nil then
        local built, why, path = M.build_manifest(o.dir, {
            fs = self.fs, sha = self.sha, loadfile = self.loader,
            crypto_path = o.crypto_path, log = function(line) self:log(line) end,
        })
        if not built then
            self.error = why
            self:log("OTA_SERVER_REJECT why=" .. safe(why) .. " path=" .. safe(path, 96))
            return self
        end
        manifest = built
    end

    local ok, why = self:load_manifest(manifest)
    if not ok then
        self.error = why
        self:log("OTA_SERVER_REJECT why=" .. safe(why))
        return self
    end
    self:log("OTA_SERVER_READY version=" .. self.manifest.version
        .. " files=" .. tostring(#self.files) .. " bytes=" .. tostring(self.manifest.bytes)
        .. " manifest_sha=" .. self.manifest.manifest_sha:sub(1, 12))
    return self
end

-- ---------------------------------------------------------------------------
-- the protocol
-- ---------------------------------------------------------------------------

-- Pure request -> reply. Returns the reply line, or nil, why. A nil, "wrong
-- protocol" / "not a string" means "not ours, stay quiet"; every other failure
-- is answered with ERR so an operator can see what the server thinks.
function M:request(msg)
    if type(msg) ~= "string" then return nil, "not a string" end
    if msg:sub(1, #M.PREFIX + 1) ~= M.PREFIX .. " " then return nil, "wrong protocol" end
    if not self.files or not self.manifest then return nil, "no_manifest" end

    local body = msg:sub(#M.PREFIX + 2)
    local verb, rest = body:match("^(%S+)%s*(.*)$")
    if verb ~= "GET" then return nil, "bad_verb" end
    local a, b = rest:match("^(%S+)%s*(%S*)$")
    if not a then return nil, "bad_request" end

    if a == "meta" then
        if b ~= "" then return nil, "bad_request" end
        return M.PREFIX .. " META version=" .. self.manifest.version
            .. " files=" .. tostring(#self.files)
            .. " manifest_sha=" .. self.manifest.manifest_sha
    end

    -- idx is decimal and 0-based; anything else is a bad request, not index 1
    if not a:match("^%d+$") then return nil, "bad_idx" end
    local idx = tonumber(a)
    if not idx or idx < 0 or idx >= #self.files then return nil, "bad_idx" end
    local f = self.files[idx + 1]

    if b == "" then
        return M.PREFIX .. " FILE " .. f.relpath .. " " .. tostring(f.size)
            .. " " .. f.sha256
    end

    if not b:match("^%d+$") then return nil, "bad_offset" end
    local offset = tonumber(b)
    if not offset or offset % M.MAX_DATA ~= 0 then return nil, "bad_offset" end
    if offset >= f.size then return nil, "bad_offset" end
    if f.data == nil then return nil, "no_data" end
    local chunk = f.data:sub(offset + 1, offset + M.MAX_DATA)
    if #chunk == 0 then return nil, "bad_offset" end
    self.bytes = self.bytes + #chunk
    return M.PREFIX .. " DATA " .. f.relpath .. " " .. tostring(offset) .. " " .. hex(chunk)
end

-- handle(msg, sender) -> reply | nil. Accepts both `srv:handle(msg, sender)` and
-- the task's `M.handle(msg, sender)` dot-call; the dot-call has no manifest, so
-- it refuses every request instead of raising.
function M:handle(msg, sender)
    if type(self) ~= "table" then
        -- called as M.handle(msg[, sender]): there is no instance and therefore
        -- no manifest to serve from
        return M:err("no_manifest")
    end
    self.packets = (self.packets or 0) + 1
    if type(self.files) ~= "table" or not self.manifest then
        local why = self.error or "no_manifest"
        self.errors = (self.errors or 0) + 1
        self:log("OTA_SERVER_ERR reason=" .. safe(why) .. " to=" .. safe(sender))
        return self:err(why)
    end
    local reply, why = self:request(msg)
    if reply then
        self.served = self.served + 1
        self:log("OTA_SERVER_SEND kind=" .. (reply:match("^%S+%s+(%S+)") or "?")
            .. " to=" .. safe(sender))
        return reply
    end
    if why == "wrong protocol" or why == "not a string" then
        self.ignored = self.ignored + 1
        self:log("OTA_SERVER_IGNORE why=" .. safe(why) .. " to=" .. safe(sender))
        return nil
    end
    self.errors = self.errors + 1
    self:log("OTA_SERVER_ERR reason=" .. safe(why) .. " to=" .. safe(sender))
    return self:err(why)
end

-- one packet end to end: classify, answer, send the answer back on the same
-- protocol. Returns the reply (for tests and for a caller that wants it).
function M:dispatch(sender, msg, protocol)
    local reply = self:handle(msg, sender)
    if reply and self.rednet and type(self.rednet.send) == "function" then
        local ok = pcall(self.rednet.send, sender, reply, protocol or self.protocol)
        if not ok then
            self:log("OTA_SERVER_SEND_FAIL to=" .. safe(sender))
            return nil
        end
    end
    return reply
end

-- META plus one FILE line per record, each line byte-identical to the reply the
-- corresponding request gets. For operators, diffs and the tests; not a packet.
function M:describe()
    local out = {}
    if not self.files or not self.manifest then return out end
    out[1] = M.PREFIX .. " META version=" .. self.manifest.version
        .. " files=" .. tostring(#self.files)
        .. " manifest_sha=" .. self.manifest.manifest_sha
    for i = 1, #self.files do
        local f = self.files[i]
        out[#out + 1] = M.PREFIX .. " FILE " .. f.relpath .. " " .. tostring(f.size)
            .. " " .. f.sha256
    end
    return out
end

-- Serve until stop(). One packet at a time, one reply per request: the client
-- drives, so there is no session state to leak and a lost packet costs one
-- request (DECISIONS.md 15.5).
function M:serve()
    local net = self.rednet
    if type(net) ~= "table" or type(net.receive) ~= "function" then
        self:log("OTA_SERVER_NO_REDNET")
        return nil, "no_rednet"
    end
    if not self.files or not self.manifest then
        self:log("OTA_SERVER_NO_MANIFEST why=" .. safe(self.error))
        return nil, "no_manifest"
    end
    self.running = true
    self:log("OTA_SERVER_START protocol=" .. safe(self.protocol, 24)
        .. " version=" .. self.manifest.version .. " files=" .. tostring(#self.files)
        .. " manifest_sha=" .. self.manifest.manifest_sha:sub(1, 12))
    while self.running do
        local ok, sender, msg = pcall(net.receive, self.protocol, self.timeout)
        if not ok then
            self.running = false
            self:log("OTA_SERVER_RECV_FAIL")
            return nil, "receive_failed"
        end
        if sender ~= nil then self:dispatch(sender, msg, self.protocol) end
    end
    self:log("OTA_SERVER_STOP packets=" .. tostring(self.packets)
        .. " served=" .. tostring(self.served) .. " errors=" .. tostring(self.errors)
        .. " ignored=" .. tostring(self.ignored) .. " bytes=" .. tostring(self.bytes))
    return true
end

function M:stop()
    self.running = false
    return true
end

return M
