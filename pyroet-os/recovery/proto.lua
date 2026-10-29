--[[- recovery/proto.lua -- shared file-set framing, hashing and apply for the
recovery tools (PYROET-FLASH/2, DECISIONS.md 12). ASCII only.

There is no slot and no /boot.slot any more: the image is one file set rooted at
`/system/`, so "which image is in charge" is not a pointer any more, it is a
fact. `P.target()` is the equivalent of the old `P.ptr()`: it reports the single
tree (and whether it is there at all, which a bricked machine needs to know).

A flash is a three phase transaction (`P.write_file_set`):

    1. describe  `META` lists every file as `<relpath> <size> <sha256>` plus a
                 version and the `manifest_sha` of exactly those lines
    2. stage     every file is downloaded into /update.stage/<relpath>.part and
                 proven (size + sha256) BEFORE the system is touched; a file
                 whose target already has the wanted sha256 is skipped, which is
                 what makes a second run of the same set a no-op
    3. apply     per file: the old bytes move to /update.backup/<relpath>, the
                 staged file moves into /system/<relpath>, and both moves are
                 proven by reading the bytes back. Any failure undoes the files
                 already applied (by hash, in reverse order) and stops, so the
                 old system survives.

Phase 2 is why a bad download or a bad digest can never leave a half system:
nothing under /system is touched until every byte of the set has been proven.
Phase 3 is the only phase that can, and it undoes itself.

After a successful apply the set is described to the bootloader as an `applied`
update journal (the same `update.journal.<seq>` generation kernel/ota.lua
writes). That is what lets `boot.lua` trial-boot the freshly flashed image and
roll it back from /update.backup when it never reaches its first frame. A journal
write failure is not a flash failure -- the files are on disk and verified -- so
it is reported and nothing is undone.

Wire format (one line per packet, `+` is a literal space):

    PYROET-FLASH/2 META version=<tok> manifest_sha=<64 hex> files=<n>
    <relpath> <size> <sha256>                            (one per file)
    PYROET-FLASH/2 GET meta
    PYROET-FLASH/2 GET <relpath> <chunk index>
    PYROET-FLASH/2 DATA <relpath> idx=<i> sha256=<64 hex> <hex payload>
    PYROET-FLASH/2 PUSH meta ...
    PYROET-FLASH/2 PUSH DATA <relpath> idx=<i> sha256=<64 hex> <hex payload>

`idx` is the chunk number (offset / MAX_DATA). MAX_DATA is 8,192 payload bytes
(16,384 hex characters), which keeps one packet well inside the rednet packet
limit -- the v1 MAX_CHUNK of 32,768 bytes became 65,536 hex characters and was
already at that limit. Provider signature used by flash and bootstrap:

    provider(relpath, offset, want) -> chunk | nil, reason

No non-ASCII bytes in this file.
]]

local P = {}

P.PREFIX = "PYROET-FLASH/2"
P.PROTOCOL = "pyroet-flash"
P.CRYPTO = "/system/rpv/crypto.lua"
P.JOURNAL_TAG = "PYROET-UPD-JOURNAL-1"
P.MAX_FILES = 256
P.MAX_FILE = 65536
P.MAX_DATA = 8192
P.MAX_TRIES = 3
P.TIMEOUT = 3
P.REL_MAX = 96

-- ---------------------------------------------------------------------------
-- paths and digests
-- ---------------------------------------------------------------------------

function P.join(root, rest)
    local head = tostring(root or ""):gsub("/+$", "")
    local tail = tostring(rest or ""):gsub("^/+", "")
    if head == "" then return "/" .. tail end
    if head:sub(1, 1) ~= "/" then head = "/" .. head end
    return head .. "/" .. tail
end

function P.dirname(path)
    return tostring(path):match("^(.*)/[^/]*$") or "/"
end

function P.read(fs, path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll and handle.readAll() or handle.read("*a")
    handle.close()
    return text or ""
end

function P.remove(fs, path)
    if not path or not fs.exists(path) then return true end
    pcall(fs.delete, path)
    return not fs.exists(path)
end

function P.ensure_dir(fs, path)
    if not path or path == "" or path == "/" then return true end
    if fs.exists(path) then
        if fs.isDir and not fs.isDir(path) then return nil, "not_a_dir" end
        return true
    end
    local parent = P.dirname(path)
    if parent ~= path and parent ~= "/" then
        local ok = P.ensure_dir(fs, parent)
        if not ok then return nil, "mkdir" end
    end
    pcall(fs.makeDir, path)
    if not fs.exists(path) then return nil, "mkdir" end
    return true
end

-- rename. CraftOS returns a value instead of raising when it refuses, so the
-- only proof that it worked is "target exists, source gone".
function P.move(fs, src, dst)
    if type(fs.move) ~= "function" then return nil, "no_move" end
    local ok = pcall(fs.move, src, dst)
    if ok and fs.exists(dst) and not fs.exists(src) then return true end
    return nil, "move"
end

-- write tmp -> delete target -> move tmp in; CraftOS fs.move cannot overwrite
function P.atomic(fs, path, text)
    local tmp = path .. ".tmp"
    P.remove(fs, tmp)
    local handle = fs.open(tmp, "w")
    if not handle then return nil, "open" end
    local ok = pcall(handle.write, text)
    handle.close()
    if not ok then return nil, "write" end
    if fs.exists(path) and not P.remove(fs, path) then return nil, "del" end
    if P.move(fs, tmp, path) then return true end
    return nil, "move"
end

function P.sha(opts)
    local o = opts or {}
    if type(o.sha) == "function" then return o.sha end
    local ok, chunk = pcall(loadfile, o.crypto_path or P.CRYPTO)
    if not ok or type(chunk) ~= "function" then return nil end
    local mod = {}
    if pcall(chunk, mod) and type(mod.sha256) == "function" then return mod.sha256 end
    return nil
end

local function hex(text)
    return (tostring(text):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function unhex(text)
    local s = tostring(text or "")
    if #s % 2 ~= 0 or s:find("[^0-9a-fA-F]") then return nil end
    return (s:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

-- hex digest of a text; the rpv sha256 returns 32 raw bytes and a test double
-- may return hex, so both are normalised to 64 lowercase characters
function P.dg(fn, text)
    local out = tostring(fn(text))
    if #out == 32 then out = hex(out) end
    return out:lower()
end

function P.check(sha, data, want)
    if type(sha) ~= "function" then return nil, "sha256" end
    if type(data) ~= "string" then return nil, "data" end
    if P.dg(sha, data) ~= tostring(want):lower() then return nil, "digest" end
    return true
end

local function file_sha(fs, sha, path)
    if not fs.exists(path) then return nil end
    local text = P.read(fs, path)
    if text == nil then return nil end
    return P.dg(sha, text)
end

local function is_sha64(value)
    return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- the one tree (P.ptr's replacement)
-- ---------------------------------------------------------------------------

-- There is no pointer and no slot: the target is always <root>/system. Returns
-- the directory when it is there, nil + "missing"/"not_a_dir" otherwise (a flash
-- is exactly the tool you reach for when it is missing, so this is information,
-- not a refusal).
function P.target(fs, root)
    local dir = P.join(root, "system")
    if not fs.exists(dir) then return nil, "missing", dir end
    if fs.isDir and not fs.isDir(dir) then return nil, "not_a_dir", dir end
    return dir, nil, dir
end

function P.stage_path(root)
    return P.join(root, "update.stage")
end

function P.backup_path(root)
    return P.join(root, "update.backup")
end

-- ---------------------------------------------------------------------------
-- relpath rules (same family as kernel/ota.lua, P6-design 3.3)
-- ---------------------------------------------------------------------------

function P.valid_relpath(relpath)
    local p = type(relpath) == "string" and relpath or ""
    if p == "" then return nil, "empty" end
    if #p > P.REL_MAX then return nil, "length" end
    if p:sub(1, 1) == "/" or p:sub(-1) == "/" then return nil, "slash" end
    if p:find("//", 1, true) then return nil, "slash" end
    if p:find("[^\32-\126]") then return nil, "ascii" end
    local count = 0
    for segment in p:gmatch("[^/]+") do
        count = count + 1
        if segment == ".." then return nil, "dotdot" end
        if segment:sub(1, 1) == "." then return nil, "dot" end
        if segment:find("[^%w_%-%.]") then return nil, "chars" end
    end
    if count == 0 then return nil, "empty" end
    return true
end

-- ---------------------------------------------------------------------------
-- META / DATA parsing
-- ---------------------------------------------------------------------------

-- canonical manifest text: one line per file, sorted by relpath, with NUL
-- separators so a space in a path cannot move a field boundary
function P.manifest(files)
    local sorted = {}
    for i = 1, #files do sorted[i] = files[i] end
    table.sort(sorted, function(a, b) return a.relpath < b.relpath end)
    local out = {}
    for i = 1, #sorted do
        local f = sorted[i]
        out[i] = f.relpath .. "\0" .. tostring(f.size) .. "\0" .. f.sha256 .. "\n"
    end
    return table.concat(out)
end

function P.manifest_sha(sha, files)
    if type(sha) ~= "function" then return nil end
    return P.dg(sha, P.manifest(files))
end

-- Parses a META packet, or the meta.txt body wrapped as one: the on-disk file is
-- the same text without the `PYROET-FLASH/2 META ` head prefix, which is why
-- flash.lua can hand both to the same parser.
function P.meta(msg, sha)
    if type(msg) ~= "string" then return nil, "pre" end
    local head = msg:match("^([^\n]*)") or ""
    local rest = msg:sub(#head + 2)
    if head:sub(1, #P.PREFIX + 1) ~= P.PREFIX .. " " then return nil, "pre" end
    local body = head:sub(#P.PREFIX + 2)
    local keyword, tail
    if body:sub(1, 9) == "PUSH meta" then
        keyword, tail = "PUSH meta", body:sub(10)
    elseif body:sub(1, 4) == "META" then
        keyword, tail = "META", body:sub(5)
    else
        return nil, "pkt"
    end
    local version = tail:match("version=(%S+)")
    local manifest_sha = tail:match("manifest_sha=(%x+)")
    local count = tonumber(tail:match("files=(%d+)"))
    if not version or #version > 32 or version:find("[^%w%._%-]") then
        return nil, "version"
    end
    if not is_sha64(manifest_sha) then return nil, "manifest_sha" end
    if not count or count < 1 or count > P.MAX_FILES then return nil, "files" end

    local files, seen = {}, {}
    for line in (rest .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            local relpath, size, digest = line:match("^(%S+) (%d+) (%x+)$")
            if not relpath then return nil, "file_line" end
            local ok, why = P.valid_relpath(relpath)
            if not ok then return nil, "path_" .. tostring(why) end
            if seen[relpath] then return nil, "duplicate" end
            seen[relpath] = true
            local n = tonumber(size)
            if n < 1 or n > P.MAX_FILE then return nil, "size" end
            if not is_sha64(digest:lower()) then return nil, "sha256" end
            files[#files + 1] = { relpath = relpath, size = n, sha256 = digest:lower() }
        end
    end
    if #files ~= count then return nil, "count" end
    if type(sha) == "function" then
        local got = P.manifest_sha(sha, files)
        if got ~= manifest_sha:lower() then return nil, "manifest_sha_mismatch" end
    end
    return {
        version = version,
        manifest_sha = manifest_sha:lower(),
        files = files,
        keyword = keyword,
    }
end

function P.data(msg)
    if type(msg) ~= "string" then return nil, "pre" end
    if msg:sub(1, #P.PREFIX + 1) ~= P.PREFIX .. " " then return nil, "pre" end
    local body = msg:sub(#P.PREFIX + 2)
    local tail
    if body:sub(1, 9) == "PUSH DATA" then
        tail = body:sub(10)
    elseif body:sub(1, 4) == "DATA" then
        tail = body:sub(5)
    else
        return nil, "pkt"
    end
    tail = tail:gsub("^%s+", "")
    local relpath, index, digest, payload =
        tail:match("^(%S+)%s+idx=(%d+)%s+sha256=(%x+)%s+(%x*)$")
    if not relpath then return nil, "fields" end
    local ok, why = P.valid_relpath(relpath)
    if not ok then return nil, "path_" .. tostring(why) end
    local idx = tonumber(index)
    if not idx or idx < 0 then return nil, "idx" end
    if not is_sha64(digest:lower()) then return nil, "sha256" end
    local data = unhex(payload)
    if data == nil then return nil, "hex" end
    if #data < 1 or #data > P.MAX_DATA then return nil, "size" end
    return { relpath = relpath, idx = idx, sha256 = digest:lower(), data = data }
end

-- ---------------------------------------------------------------------------
-- rednet helper
-- ---------------------------------------------------------------------------

function P.fetch(net, host, build, accept, opts)
    local o = opts or {}
    local protocol = o.protocol or P.PROTOCOL
    local timeout = o.timeout or P.TIMEOUT
    local max = o.max_tries or P.MAX_TRIES
    local err = "timeout"
    if type(net) ~= "table" or not net.send or not net.receive then
        return nil, "rednet"
    end
    for _ = 1, max do
        if not pcall(net.send, host, build(), protocol) then
            err = "send"
        else
            local ok, sender, msg = pcall(net.receive, protocol, timeout)
            if not ok then
                err = "recv"
            elseif sender == nil then
                err = "timeout"
            elseif sender == host and type(msg) == "string" then
                local parsed, perr = accept(msg)
                if parsed then return parsed end
                err = perr
            else
                err = "peer"
            end
        end
    end
    return nil, err
end

function P.fail(out, tag, stage, err)
    local text = tostring(err == nil and "?" or err):gsub("%s+", " "):sub(1, 48)
    out(tostring(tag) .. "_FAIL stage=" .. tostring(stage) .. " err=" .. text)
    return false
end

-- ---------------------------------------------------------------------------
-- apply: undo already-applied files in reverse order, by hash
-- ---------------------------------------------------------------------------

-- entries are in apply order; each one has target (the new bytes are there, or
-- the move failed), backup (old bytes, absent for an added file) and part.
-- Restoring means: remove whatever is at the target, move the backup back, and
-- prove the old digest came back. Returns restored, dropped, ok.
function P.undo(fs, sha, entries)
    local restored, dropped, bad = 0, 0, 0
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.part then P.remove(fs, e.part) end
        if e.backup and fs.exists(e.backup) then
            if fs.exists(e.target) then P.remove(fs, e.target) end
            local moved = P.move(fs, e.backup, e.target)
            local got = file_sha(fs, sha, e.target)
            if moved and got == e.old_sha then
                restored = restored + 1
            else
                bad = bad + 1
            end
        elseif e.old_sha == "-" then
            if fs.exists(e.target) then P.remove(fs, e.target) end
            dropped = dropped + 1
        else
            bad = bad + 1
        end
    end
    return restored, dropped, bad == 0
end

-- ---------------------------------------------------------------------------
-- the file set transaction
-- ---------------------------------------------------------------------------

-- Returns true, stats on success; nil, stage, err on failure. Stats fields:
-- files, written, skipped, bytes, version, manifest_sha, journal (seq or nil).
function P.write_file_set(fs, root, meta, provider, sha, opts)
    local o = opts or {}
    if type(fs) ~= "table" then return nil, "prepare", "fs" end
    if type(sha) ~= "function" then return nil, "prepare", "sha256" end
    if type(provider) ~= "function" then return nil, "prepare", "provider" end
    if type(meta) ~= "table" or type(meta.files) ~= "table" or #meta.files == 0 then
        return nil, "meta", "table"
    end
    -- the manifest digest is the anchor: it must describe exactly the file lines
    -- that are about to be written, and it is checked before anything is staged
    if not is_sha64(meta.manifest_sha) then return nil, "manifest", "sha256" end
    if P.manifest_sha(sha, meta.files) ~= meta.manifest_sha then
        return nil, "manifest", "sha256"
    end

    local base = tostring(root or "")
    local system = P.join(base, "system")
    local stage = P.join(base, "update.stage")
    local backup = P.join(base, "update.backup")

    -- what actually has to change. A file already at the wanted digest is a
    -- no-op, which is what makes a repeated flash (or a resumed one) safe.
    local plan, skipped = {}, 0
    for i = 1, #meta.files do
        local f = meta.files[i]
        f.target = system .. "/" .. f.relpath
        f.current = file_sha(fs, sha, f.target)
        if f.current == f.sha256 then
            skipped = skipped + 1
        else
            plan[#plan + 1] = f
        end
    end

    local stats = {
        files = #meta.files, written = 0, skipped = skipped, bytes = 0,
        version = meta.version, manifest_sha = meta.manifest_sha,
    }
    if #plan == 0 then
        -- nothing changed: the machine already runs exactly this set, so there
        -- is no update to describe to the bootloader (an empty `applied`
        -- journal would only cost trial boots)
        return true, stats
    end

    -- phase 2: stage and prove every byte before /system is touched
    P.remove(fs, stage)
    if not P.ensure_dir(fs, stage) then return nil, "stage", "mkdir" end
    for i = 1, #plan do
        local f = plan[i]
        local part = stage .. "/" .. f.relpath .. ".part"
        f.part = part
        if not P.ensure_dir(fs, P.dirname(part)) then
            P.remove(fs, stage)
            return nil, "stage", "mkdir"
        end
        local handle = fs.open(part, "w")
        if not handle then
            P.remove(fs, stage)
            return nil, "stage", "open"
        end
        local offset, why = 0, nil
        while offset < f.size do
            local want = math.min(P.MAX_DATA, f.size - offset)
            local chunk, cerr = provider(f.relpath, offset, want)
            if type(chunk) ~= "string" then
                why = cerr or "chunk"
                break
            end
            if #chunk ~= want then
                why = "size"
                break
            end
            if not pcall(handle.write, chunk) then
                why = "write"
                break
            end
            offset = offset + #chunk
        end
        handle.close()
        if why then
            P.remove(fs, stage)
            return nil, "stage", why
        end
        local text = P.read(fs, part)
        if #(text or "") ~= f.size then
            P.remove(fs, stage)
            return nil, "stage", "size"
        end
        if P.dg(sha, text) ~= f.sha256 then
            P.remove(fs, stage)
            return nil, "stage", "sha256"
        end
        stats.written = stats.written + 1
        stats.bytes = stats.bytes + f.size
    end

    -- phase 3: apply, remembering exactly what was replaced
    local applied = {}
    local function fail(stage_name, err)
        local restored, dropped = P.undo(fs, sha, applied)
        P.remove(fs, stage)
        return nil, stage_name,
            tostring(err) .. " rolled_back=" .. tostring(restored)
                .. " removed=" .. tostring(dropped)
    end
    for i = 1, #plan do
        local f = plan[i]
        local entry = {
            relpath = f.relpath, target = f.target, part = f.part,
            old_sha = f.current or "-", new_sha = f.sha256, bytes = f.size,
        }
        applied[#applied + 1] = entry
        if not P.ensure_dir(fs, P.dirname(f.target)) then
            return fail("apply", "mkdir")
        end
        if f.current then
            local bpath = backup .. "/" .. f.relpath
            entry.backup = bpath
            if not P.ensure_dir(fs, P.dirname(bpath)) then
                return fail("backup", "mkdir")
            end
            if fs.exists(bpath) then P.remove(fs, bpath) end
            if not P.move(fs, f.target, bpath) then
                return fail("backup", "move")
            end
            -- a backup that is not the old bytes must never be used to overwrite
            -- the system: put it back and stop here
            if file_sha(fs, sha, bpath) ~= f.current then
                P.move(fs, bpath, f.target)
                entry.backup = nil
                applied[#applied] = nil
                return fail("backup", "sha256")
            end
        end
        if not P.move(fs, f.part, f.target) then
            return fail("apply", "move")
        end
        if file_sha(fs, sha, f.target) ~= f.sha256 then
            return fail("apply", "sha256")
        end
        entry.part = nil
    end

    P.remove(fs, stage)
    stats.journal = P.write_journal(fs, base, meta, applied, sha)
    return true, stats
end

-- Describes the applied set to boot.lua as an `applied` generation, so a freshly
-- flashed image is trial-booted and can be rolled back from /update.backup. A
-- failure here leaves the verified files in place and returns nil (not fatal),
-- because the files themselves are already correct.
function P.write_journal(fs, root, meta, entries, sha)
    local base = tostring(root or "")
    local newest = 0
    local names = fs.list and fs.list(base == "" and "/" or base) or {}
    for i = 1, #names do
        local seq = tonumber(tostring(names[i]):match("^update%.journal%.(%d+)$"))
        if seq and seq > newest then newest = seq end
    end
    local files = {}
    for i = 1, #entries do
        local e = entries[i]
        files[#files + 1] = e.relpath .. " " .. tostring(e.old_sha) .. " "
            .. tostring(e.new_sha) .. " " .. string.format("%.0f", e.bytes)
    end
    local seq = string.format("%.0f", newest + 1)
    local text = table.concat({
        P.JOURNAL_TAG,
        "seq=" .. seq,
        "state=applied",
        "version=" .. tostring(meta.version or "none"),
        "manifest_sha=" .. tostring(meta.manifest_sha or "none"),
    }, "\n")
    if #files > 0 then text = text .. "\n" .. table.concat(files, "\n") end
    local path = P.join(base, "update.journal." .. seq)
    local ok = P.atomic(fs, path, text .. "\n")
    if not ok then return nil end
    return tonumber(seq)
end

return P
