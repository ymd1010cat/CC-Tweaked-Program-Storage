--[[- pyroet-os/system/boot.lua -- Pyroet OS bootloader: one /system tree + update journal.

Implements pyroet-os/P6-design.md sections 2, 4, 5 and 6, with no dependency
beyond the CraftOS `fs` API plus SHA-256 (loaded lazily from
/system/rpv/crypto.lua), so it runs before the kernel and before everything else.

There is no slot and no slot pointer any more. The machine has exactly one system
tree, `/system/`, and an update is a *file set* applied in place. What makes that
survivable is three files:

    update.journal.<seq>   the intent: prepare -> applying -> applied
                           (+ rolledback tombstone), one line per file:
                           <relpath> <old_sha> <new_sha> <bytes>
    update.backup/<rel>    the proven-good old bytes of every file the update
                           touches (verified BEFORE the file is moved away)
    boot.ok                the commit credential, one ASCII line:
                           PYROET-BOOT-OK-2 version=<t> manifest_sha=<64 hex|none> ts=<ms>

Boot decision table (P6-design section 6). The inputs are only: is /system there,
what does the newest parseable journal say, is boot.ok there (and does its
manifest_sha match), and how many trials are gone:

    no /system                     -> fatal(no_system), never reboot in a loop
    no journal + boot.ok           -> normal, tries untouched (steady state)
    no journal + no boot.ok        -> trial (tries +1 persisted BEFORE booting)
    journal prepare                -> the download never applied: clean up, normal/trial
    journal applying               -> roll back first, then normal/trial
    journal applied + sha match    -> committed: clean up, normal
    journal applied + sha differs  -> uncommitted: trial, and after MAX_TRIES: rollback
    journal applied + tries > 2    -> roll back, write the rolledback tombstone
    journal rolledback             -> clean up, normal/trial
    genuine rollback failure       -> fatal(rollback_fail) + FLASH_REQUIRED, no reboot

Rollback (section 4.2) is driven by content hashes, never by progress flags: for
each entry in reverse order, `sha256(/system/<rel>) == old_sha` means "already
rolled back, skip", `sha256(update.backup/<rel>) == old_sha` means "move it back
and read it back to prove it", and `old_sha == "-"` means "the update created
this file, delete it". A flag write is itself a power-cut window; a hash is a
function of the bytes and cannot lie.

`MAX_TRIES = 2` is unchanged: the third failed attempt (tries > 2) rolls back.

2.6 migration (P6-3, M.migrate_layout): the pre-P6-3 image kept /kernel, /rpv and
/net in the computer root and the system apps directly in /system. decide()
renames those entries into the single tree before it reads anything else; a
failure renames back what it already moved and ends in fatal(layout_migrate_fail),
never in a half-migrated boot. The move is a rename per top-level entry, so no
content is rewritten and nothing needs a journal.

Usage:

    local boot = dofile("/system/boot.lua")
    local plan = boot.begin({ fs = fs })
    if plan.action ~= "fatal" then
        -- ... run the kernel ...
        boot.commit({ version = "0.6.0", manifest_sha = plan.journal and plan.journal.manifest_sha }, { fs = fs })
    end

Every entry point takes one trailing options table:

    fs    file system table (default: the global `fs`)
    root  prefix for every path, "" = computer root. Tests and tools use it to
          keep several independent state machines side by side.
    log   function(line) receiving each ASCII status line (default: no-op)
    now   function() -> epoch milliseconds (default: os.epoch("utc"))
    sha   function(bytes) -> digest, for callers that already hold SHA-256
    crypto_path  where to load SHA-256 from (default /system/rpv/crypto.lua)

`boot.new(opts)` returns the same functions bound to one options table, for
colon-style calls (`local b = boot.new{root = "/t/x"}; b:begin()`).

No non-ASCII bytes in this file.
]]

local M = {}

M.VERSION = "2.0"
M.MARKER_TAG = "PYROET-BOOT-OK-2"
M.JOURNAL_TAG = "PYROET-UPD-JOURNAL-1"
M.MAX_TRIES = 2
M.JOURNAL_KEEP = 2
M.CRYPTO = "/system/rpv/crypto.lua"
M.STATES = { prepare = true, applying = true, applied = true, rolledback = true }

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/, ]", "_")
    max = max or 56
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function join(root, rest)
    if root == nil or root == "" or root == "/" then return "/" .. rest end
    local head = tostring(root):gsub("/+$", "")
    if head == "" then return "/" .. rest end
    if head:sub(1, 1) ~= "/" then head = "/" .. head end
    return head .. "/" .. rest
end

function M.now()
    if os and os.epoch then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return value end
    end
    if os and os.time then return math.floor(os.time() * 1000) end
    return 0
end

-- CraftOS-PC's string.format refuses %d for values beyond its integer range (an
-- epoch-millisecond timestamp is one), so integers are rendered with %.0f
-- instead of %d. The result is still plain decimal ASCII.
local function fmt_int(value)
    local n = tonumber(value) or 0
    if n ~= n then n = 0 end
    if n < 0 then n = 0 end
    if n > 1e15 then n = 1e15 end
    return string.format("%.0f", math.floor(n))
end

local function to_hex(data)
    return (tostring(data):gsub(".", function(ch)
        return string.format("%02x", ch:byte())
    end))
end

-- ---------------------------------------------------------------------------
-- context / paths
-- ---------------------------------------------------------------------------

local function ctx(opts)
    local o = opts or {}
    local fsx = o.fs or rawget(_G, "fs")
    if not fsx then
        error("pyroet boot: no file system (pass opts.fs)", 2)
    end
    local c = {
        fs = fsx,
        root = o.root or "",
        log = o.log or function() end,
        now = o.now or M.now,
        opts = o,
    }
    c.paths = M.paths(o)
    return c
end

function M.paths(opts)
    local o = opts or {}
    local root = o.root or ""
    return {
        root = root,
        system = join(root, "system"),
        system_apps = join(root, "system/system"),
        marker = join(root, "boot.ok"),
        tries = join(root, "boot.tries"),
        backup = join(root, "update.backup"),
        stage = join(root, "update.stage"),
        journal_prefix = join(root, "update.journal."),
        legacy_slot = join(root, "boot.slot"),
        legacy_slots = join(root, "slots"),
    }
end

function M.journal_path(seq, opts)
    return M.paths(opts).journal_prefix .. tostring(math.floor(tonumber(seq) or 0))
end

function M.system_path(relpath, opts)
    return M.paths(opts).system .. "/" .. tostring(relpath)
end

local function root_dir(c)
    local r = c.paths.root
    if r == nil or r == "" or r == "/" then return "/" end
    return r
end

-- ---------------------------------------------------------------------------
-- file primitives (CraftOS fs: open/move/copy/delete/makeDir/getDir/list)
-- ---------------------------------------------------------------------------

local function read_all(c, path)
    if not c.fs.exists(path) then return nil end
    local handle = c.fs.open(path, "r")
    if not handle then return nil end
    local text
    if handle.readAll then
        text = handle.readAll()
    else
        text = handle.read("*a")
    end
    handle.close()
    return text or ""
end

local function write_all(c, path, text)
    local handle = c.fs.open(path, "w")
    if not handle then return nil, "cannot open " .. path .. " for write" end
    local ok, err = pcall(handle.write, text)
    handle.close()
    if not ok then return nil, "write failed: " .. tostring(err) end
    return true
end

local function ensure_dir(c, path)
    if path == nil or path == "" or path == "/" then return true end
    if c.fs.exists(path) then
        if c.fs.isDir and not c.fs.isDir(path) then
            return nil, "not a directory: " .. path
        end
        return true
    end
    local parent = c.fs.getDir(path)
    if parent and parent ~= "" and parent ~= "/" and not c.fs.exists(parent) then
        local ok, err = ensure_dir(c, parent)
        if not ok then return nil, err end
    end
    pcall(c.fs.makeDir, path)
    if not c.fs.exists(path) then return nil, "cannot create " .. path end
    return true
end

local function remove_path(c, path)
    if not c.fs.exists(path) then return true end
    pcall(c.fs.delete, path)
    if c.fs.exists(path) then return false end
    return true
end

-- copy + read-back compare + delete source. Only reached when fs.move refused,
-- because CraftOS cannot move onto an existing target.
local function copy_then_delete(c, src, dst)
    if not c.fs.copy then return false end
    local ok = pcall(c.fs.copy, src, dst)
    if not ok or not c.fs.exists(dst) then
        c.log("BOOT_COPY_FAIL from=" .. short(src, 48) .. " to=" .. short(dst, 48))
        return false
    end
    local before, after = read_all(c, src), read_all(c, dst)
    if before == nil or before ~= after then
        c.log("BOOT_COPY_MISMATCH path=" .. short(dst, 48))
        return false
    end
    pcall(c.fs.delete, src)
    return true
end

-- Returns true, method ("move" or "copy") or nil, error.
local function move_file(c, src, dst)
    if c.fs.move then
        local ok = pcall(c.fs.move, src, dst)
        if ok and c.fs.exists(dst) and not c.fs.exists(src) then return true, "move" end
        c.log("BOOT_MOVE_FALLBACK from=" .. short(src, 48) .. " reason=refused")
    else
        c.log("BOOT_MOVE_FALLBACK from=" .. short(src, 48) .. " reason=no_fs_move")
    end
    if copy_then_delete(c, src, dst) then return true, "copy" end
    return nil, "cannot move " .. src .. " to " .. dst
end

-- Atomic-ish replace: write tmp, delete the target, move the tmp in (CraftOS
-- fs.move refuses to overwrite), and if the move is refused anyway fall back to
-- copy + read back + delete the source.
function M.atomic_write(path, text, opts)
    local c = ctx(opts)
    local tmp = path .. ".tmp"
    if c.fs.exists(tmp) then pcall(c.fs.delete, tmp) end
    local okw, errw = write_all(c, tmp, text)
    if not okw then
        c.log("BOOT_WRITE_FAIL path=" .. short(path, 48) .. " err=" .. short(errw))
        return nil, errw
    end
    if c.fs.exists(path) and not remove_path(c, path) then
        c.log("BOOT_DELETE_FAIL path=" .. short(path, 48))
    end
    local moved, method = move_file(c, tmp, path)
    if not moved then return nil, method end
    c.log("BOOT_ATOMIC_WRITE path=" .. short(path, 48) .. " method=" .. tostring(method))
    return true, method
end

-- ---------------------------------------------------------------------------
-- SHA-256 (lazy: only rollback / verification need it)
-- ---------------------------------------------------------------------------

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

local function sha_fn(c)
    if c.sha == nil then
        c.sha = load_sha(c.opts) or false
    end
    if c.sha == false then return nil end
    return c.sha
end

local function digest_of(c, text)
    local fn = sha_fn(c)
    if not fn then return nil, "no_sha256" end
    local out = tostring(fn(text))
    if #out == 32 then out = to_hex(out) end
    return out:lower()
end

-- nil when the file is absent (that is a fact, not an error); "?", why when it
-- exists but cannot be hashed.
local function file_sha(c, path)
    if not c.fs.exists(path) then return nil end
    local text = read_all(c, path)
    if text == nil then return "?", "unreadable" end
    local hex, why = digest_of(c, text)
    if not hex then return "?", why end
    return hex
end

-- ---------------------------------------------------------------------------
-- journal: update.journal.<seq>, one file per generation
-- ---------------------------------------------------------------------------

local function is_sha_token(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function is_sha_or_new(value)
    if value == "-" then return true end
    return is_sha_token(value)
end

local function journal_text(rec)
    local out = {
        M.JOURNAL_TAG,
        "seq=" .. tostring(rec.seq),
        "state=" .. tostring(rec.state),
        "version=" .. tostring(rec.version),
        "manifest_sha=" .. tostring(rec.manifest_sha or "none"),
    }
    for i = 1, #rec.files do
        local f = rec.files[i]
        out[#out + 1] = tostring(f.relpath) .. " " .. tostring(f.old_sha or "-") .. " "
            .. tostring(f.new_sha) .. " " .. fmt_int(f.bytes)
    end
    return table.concat(out, "\n") .. "\n"
end

local function parse_journal(text)
    if type(text) ~= "string" then return nil, "unreadable" end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    if #lines < 1 or lines[1] ~= M.JOURNAL_TAG then return nil, "bad_tag" end

    local rec = { files = {}, raw = text }
    local seen = {}
    local at = 2
    while at <= #lines do
        local key, value = tostring(lines[at]):match("^([%a_]+)=(%S*)$")
        if not key then break end
        if seen[key] then return nil, "duplicate " .. key end
        seen[key] = true
        if key == "seq" then
            rec.seq = tonumber(value)
        elseif key == "state" then
            rec.state = value
        elseif key == "version" then
            rec.version = value
        elseif key == "manifest_sha" then
            rec.manifest_sha = value
        else
            return nil, "unknown " .. short(key, 16)
        end
        at = at + 1
    end
    if not rec.seq or rec.seq < 1 then return nil, "bad_seq" end
    if not rec.state or not M.STATES[rec.state] then return nil, "bad_state" end
    if not rec.version or #rec.version > 32 or rec.version:find("[^%w%._%-]") then
        return nil, "bad_version"
    end
    if not rec.manifest_sha then return nil, "no_manifest_sha" end
    if rec.manifest_sha ~= "none" and not is_sha_token(rec.manifest_sha) then
        return nil, "bad_manifest_sha"
    end
    for i = at, #lines do
        local relpath, old_sha, new_sha, bytes = tostring(lines[i])
            :match("^(%S+) (%S+) (%S+) (%d+)$")
        if not relpath then return nil, "bad_file_line" end
        if not is_sha_or_new(old_sha) then return nil, "bad_old_sha" end
        if not is_sha_token(new_sha) then return nil, "bad_new_sha" end
        rec.files[#rec.files + 1] = {
            relpath = relpath,
            old_sha = old_sha,
            new_sha = new_sha,
            bytes = tonumber(bytes),
        }
    end
    return rec
end

-- seq numbers present in the root, newest first (the file names, not the parsed
-- state: a corrupt generation still occupies its number and must not be reused)
local function journal_gens(c)
    local out, temps = {}, {}
    local names = c.fs.list(root_dir(c)) or {}
    for i = 1, #names do
        local name = tostring(names[i])
        local seq = tonumber(name:match("^update%.journal%.(%d+)$"))
        if seq then
            out[#out + 1] = seq
        elseif name:match("^update%.journal%.%d+%.tmp$") then
            temps[#temps + 1] = name
        end
    end
    table.sort(out, function(a, b) return a > b end)
    return out, temps
end

function M.journal_gens(opts)
    local c = ctx(opts)
    return (journal_gens(c))
end

-- The newest generation that parses. A bad newer generation is skipped (that is
-- the whole point of keeping two), and a bad *older* one is only counted.
function M.read_journal(opts)
    local c = ctx(opts)
    local gens = journal_gens(c)
    local bad = 0
    for i = 1, #gens do
        local path = c.paths.journal_prefix .. gens[i]
        local rec, why = parse_journal(read_all(c, path))
        if rec then
            rec.path = path
            return rec, bad
        end
        bad = bad + 1
        c.log("BOOT_JOURNAL_UNREADABLE seq=" .. gens[i] .. " why=" .. short(why, 24))
    end
    if #gens == 0 then return nil, "none" end
    return nil, "bad"
end

function M.next_seq(opts)
    local c = ctx(opts)
    local gens = journal_gens(c)
    return (gens[1] or 0) + 1
end

-- Keeps the generation `seq` and the one before it (P6-design 2.2): the replace
-- window of CraftOS (delete, then move) can lose the newest file, and then the
-- previous generation is the only record of the update.
function M.prune_journals(seq, opts)
    local c = ctx(opts)
    local gens = journal_gens(c)
    local keep_from = (tonumber(seq) or 0) - (M.JOURNAL_KEEP - 1)
    local removed = 0
    for i = 1, #gens do
        if gens[i] < keep_from then
            pcall(c.fs.delete, c.paths.journal_prefix .. gens[i])
            removed = removed + 1
        end
    end
    if removed > 0 then
        c.log("BOOT_JOURNAL_PRUNE seq=" .. tostring(seq) .. " removed=" .. removed)
    end
    return removed
end

-- Writes a NEW generation (never overwrites the live one), so a power cut can
-- only lose the write in progress, never the journal that described the disk.
function M.write_journal(rec, opts)
    local c = ctx(opts)
    local r = rec or {}
    local seq = math.floor(tonumber(r.seq) or 0)
    if seq < 1 then seq = M.next_seq(opts) end
    local entry = {
        seq = seq,
        state = tostring(r.state or "prepare"),
        version = tostring(r.version or "none"):gsub("[^%w%._%-]", "_"),
        manifest_sha = r.manifest_sha or "none",
        files = r.files or {},
    }
    if not M.STATES[entry.state] then
        return nil, "bad state " .. tostring(entry.state)
    end
    if #entry.version > 32 then entry.version = entry.version:sub(1, 32) end
    if entry.manifest_sha ~= "none" then
        entry.manifest_sha = tostring(entry.manifest_sha):lower()
        if not is_sha_token(entry.manifest_sha) then
            c.log("BOOT_JOURNAL_SHA_INVALID value=" .. short(entry.manifest_sha, 24))
            entry.manifest_sha = "none"
        end
    end
    local path = M.journal_path(seq, opts)
    local ok, err = M.atomic_write(path, journal_text(entry), opts)
    if not ok then
        c.log("BOOT_JOURNAL_WRITE_FAIL seq=" .. seq .. " err=" .. short(err))
        return nil, err
    end
    M.prune_journals(seq, opts)
    c.log("BOOT_JOURNAL_WRITE seq=" .. seq .. " state=" .. entry.state
        .. " files=" .. tostring(#entry.files))
    if type(rec) == "table" then rec.seq = seq end
    return seq, entry
end

-- ---------------------------------------------------------------------------
-- tries: /boot.tries (one global counter now)
-- ---------------------------------------------------------------------------

function M.read_tries(opts)
    local c = ctx(opts)
    local text = read_all(c, c.paths.tries)
    if text == nil then return 0 end
    local n = tonumber(text:match("^%s*(%-?%d+)%s*$"))
    if not n or n < 0 then return 0 end
    return n
end

function M.write_tries(n, opts)
    local c = ctx(opts)
    local value = math.floor(tonumber(n) or 0)
    if value < 0 then value = 0 end
    return write_all(c, c.paths.tries, fmt_int(value))
end

-- ---------------------------------------------------------------------------
-- /boot.ok: the global commit credential
-- ---------------------------------------------------------------------------

local function sanitize_token(value, max)
    local s = tostring(value == nil and "" or value)
    s = s:gsub("[^%w%._%-]", "_")
    if #s > (max or 32) then s = s:sub(1, max or 32) end
    if s == "" then s = "none" end
    return s
end

local function manifest_token(value, c)
    if value == nil then return "none" end
    local s = tostring(value):lower()
    if s == "none" then return "none" end
    if is_sha_token(s) then return s end
    c.log("BOOT_SHA_INVALID value=" .. short(s, 24))
    return "none"
end

function M.write_marker(info, opts)
    local c = ctx(opts)
    local i = info or {}
    local line = string.format("%s version=%s manifest_sha=%s ts=%s",
        M.MARKER_TAG,
        sanitize_token(i.version, 32),
        manifest_token(i.manifest_sha, c),
        fmt_int(i.ts or c.now()))
    local ok, err = M.atomic_write(c.paths.marker, line, opts)
    if not ok then
        c.log("BOOT_MARKER_WRITE_FAIL err=" .. short(err))
        return nil, err
    end
    c.log("BOOT_MARKER_WRITE version=" .. sanitize_token(i.version, 32)
        .. " manifest_sha=" .. manifest_token(i.manifest_sha, c))
    return true
end

function M.read_marker(opts)
    local c = ctx(opts)
    local text = read_all(c, c.paths.marker)
    if text == nil then return nil, "missing" end
    local line = text:match("^([^\r\n]*)") or ""
    local tag = line:match("^(%S+)")
    if tag ~= M.MARKER_TAG then return nil, "stale tag " .. short(tag, 24) end
    local marker = {
        tag = tag,
        raw = line,
        version = line:match(" version=(%S+)"),
        manifest_sha = line:match(" manifest_sha=(%S+)"),
        ts = tonumber(line:match(" ts=(%S+)")),
    }
    if not marker.version then return nil, "missing version" end
    if not marker.manifest_sha then return nil, "missing manifest_sha" end
    marker.manifest_sha = tostring(marker.manifest_sha):lower()
    return marker
end

function M.has_marker(opts)
    local c = ctx(opts)
    return c.fs.exists(c.paths.marker)
end

-- ---------------------------------------------------------------------------
-- cleanup: journal + backup + stage residue
-- ---------------------------------------------------------------------------

local function count_files(c, path)
    if not c.fs.exists(path) then return 0 end
    if c.fs.isDir and not c.fs.isDir(path) then return 1 end
    local n = 0
    local names = c.fs.list(path) or {}
    for i = 1, #names do
        n = n + count_files(c, join(path, tostring(names[i])))
    end
    return n
end

local function count_all(c, path)
    if not c.fs.exists(path) then return 0 end
    return count_files(c, path)
end

function M.cleanup(opts)
    local c = ctx(opts)
    local gens, temps = journal_gens(c)
    local removed = 0
    for i = 1, #gens do
        local path = c.paths.journal_prefix .. gens[i]
        if remove_path(c, path) then
            removed = removed + 1
        else
            c.log("BOOT_JOURNAL_DELETE_FAIL seq=" .. gens[i])
        end
    end
    for i = 1, #temps do
        remove_path(c, c.paths.journal_prefix .. temps[i]:match("^update%.journal%.(.+)$"))
    end
    local backups = count_all(c, c.paths.backup)
    if c.fs.exists(c.paths.backup) and not remove_path(c, c.paths.backup) then
        c.log("BOOT_BACKUP_DELETE_FAIL path=" .. short(c.paths.backup, 48))
    end
    if c.fs.exists(c.paths.stage) and not remove_path(c, c.paths.stage) then
        c.log("BOOT_STAGE_DELETE_FAIL path=" .. short(c.paths.stage, 48))
    end
    c.log("BOOT_CLEAN journal=" .. removed .. " backup=" .. backups)
    return removed, backups
end

-- ---------------------------------------------------------------------------
-- rollback (P6-design 4.2 / 4.3)
-- ---------------------------------------------------------------------------

local function rollback_fail(c, seq, relpath, want, got)
    c.log("BOOT_ROLLBACK_FAIL seq=" .. tostring(seq or 0)
        .. " relpath=" .. short(relpath or "-", 48)
        .. " want=" .. short(want or "-", 12)
        .. " got=" .. short(got or "-", 12))
    c.log("BOOT_FATAL reason=rollback_fail")
    c.log("FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
    return nil, "rollback_fail"
end

-- Restores every file the journal lists, newest entry first. Returns true or
-- nil, "rollback_fail". Evidence is never deleted on failure (P6-design 4.3).
function M.rollback(opts)
    local c = ctx(opts)
    local rec = M.read_journal(opts)
    if not rec then
        return rollback_fail(c, 0, nil, "-", "-")
    end
    if rec.state == "rolledback" then
        c.log("BOOT_ROLLBACK_ALREADY seq=" .. rec.seq)
        return true
    end
    local fn = sha_fn(c)
    if not fn then
        c.log("BOOT_ROLLBACK_NO_SHA")
        return rollback_fail(c, rec.seq, nil, "-", "-")
    end

    local restored, deleted = 0, 0
    for i = #rec.files, 1, -1 do
        local f = rec.files[i]
        local target = M.system_path(f.relpath, opts)
        local cur = file_sha(c, target)
        if f.old_sha == "-" then
            -- this file is new in the update: rolling back means removing it
            if cur ~= nil then
                if not remove_path(c, target) then
                    return rollback_fail(c, rec.seq, f.relpath, "-", cur)
                end
                deleted = deleted + 1
            end
        elseif cur == f.old_sha then
            -- already back: the hash is the progress marker, not a flag
        else
            local backup = join(c.paths.backup, f.relpath)
            local bsha = file_sha(c, backup)
            if bsha == nil then
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, "-")
            end
            if bsha ~= f.old_sha then
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, bsha)
            end
            if cur ~= nil and not remove_path(c, target) then
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, cur)
            end
            local parent = c.fs.getDir(target)
            local okd, derr = ensure_dir(c, parent)
            if not okd then
                c.log("BOOT_ROLLBACK_MKDIR_FAIL path=" .. short(parent, 48) .. " err=" .. short(derr, 24))
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, "-")
            end
            local moved, merr = move_file(c, backup, target)
            if not moved then
                c.log("BOOT_ROLLBACK_MOVE_FAIL path=" .. short(f.relpath, 48) .. " err=" .. short(merr, 24))
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, "-")
            end
            local got = file_sha(c, target)
            if got ~= f.old_sha then
                return rollback_fail(c, rec.seq, f.relpath, f.old_sha, got)
            end
            restored = restored + 1
        end
    end

    -- the tombstone: "this update was rolled back" must survive a reboot,
    -- otherwise the next boot replays the rollback (or guesses)
    local seq = M.write_journal({
        seq = rec.seq + 1,
        state = "rolledback",
        version = rec.version,
        manifest_sha = rec.manifest_sha,
        files = rec.files,
    }, opts)
    if not seq then
        c.log("BOOT_ROLLBACK_TOMBSTONE_FAIL seq=" .. rec.seq)
        return rollback_fail(c, rec.seq, nil, "-", "-")
    end
    if c.fs.exists(c.paths.stage) then pcall(c.fs.delete, c.paths.stage) end
    c.log("BOOT_ROLLBACK seq=" .. rec.seq .. " state=" .. rec.state
        .. " files=" .. tostring(#rec.files)
        .. " restored=" .. restored .. " deleted=" .. deleted)
    return true
end

-- ---------------------------------------------------------------------------
-- migration into the single tree (P6-3): /kernel, /rpv, /net -> /system/<name>
-- ---------------------------------------------------------------------------

-- Before P6-3 the image was split: the boot chain was already under /system but
-- the kernel, rpv and net modules were still directories in the computer root,
-- and the system apps sat directly in /system. The single tree keeps everything
-- image-shaped under /system, with the system apps one level deeper in
-- /system/system so they cannot be confused with kernel modules.
--
-- The move is a rename per top-level entry, never a copy: a rename either
-- happens or it does not, so there is no "half a tree" state to clean up, and a
-- failure is undone by renaming the entries back. Files inside a moved tree are
-- not re-hashed: nothing was rewritten.
M.LAYOUT_DIRS = { "kernel", "rpv", "net" }

-- One step per root entry. `skip` means the target already exists (an update
-- can have installed /system/kernel while the old /kernel was still there);
-- removing the old copy is not this function's decision, so it is only logged.
function M.legacy_layout(opts)
    local c = ctx(opts)
    local plan = {}
    for i = 1, #M.LAYOUT_DIRS do
        local name = M.LAYOUT_DIRS[i]
        local src = join(c.paths.root, name)
        if c.fs.exists(src) then
            local dst = join(c.paths.system, name)
            plan[#plan + 1] = {
                kind = "dir", name = name, src = src, dst = dst,
                skip = c.fs.exists(dst),
            }
        end
    end
    return plan
end

-- /system/<name>.app -> /system/system/<name>.app, sorted for a deterministic
-- log and a deterministic rollback order.
function M.legacy_apps(opts)
    local c = ctx(opts)
    local plan = {}
    if not c.fs.exists(c.paths.system) or type(c.fs.list) ~= "function" then
        return plan
    end
    if c.fs.isDir and not c.fs.isDir(c.paths.system) then return plan end
    local names = {}
    local listed = c.fs.list(c.paths.system) or {}
    for i = 1, #listed do names[#names + 1] = tostring(listed[i]) end
    table.sort(names)
    for i = 1, #names do
        local name = names[i]
        if name:sub(-4) == ".app" then
            local dst = join(c.paths.system_apps, name)
            plan[#plan + 1] = {
                kind = "app", name = name,
                src = join(c.paths.system, name), dst = dst,
                skip = c.fs.exists(dst),
            }
        end
    end
    return plan
end

-- rename only: fs.move refuses to overwrite, and a refused move is a failure,
-- not something to paper over with a copy (a copy cannot be undone cheaply).
local function move_tree(c, src, dst)
    if not c.fs.move then return nil, "no_fs_move" end
    local ok = pcall(c.fs.move, src, dst)
    if ok and c.fs.exists(dst) and not c.fs.exists(src) then return true, "move" end
    return nil, "move"
end

-- rename every step already applied back, newest first. Returns nil plus the
-- stage, or nil plus "rollback_fail" when the old layout could not be restored.
local function layout_rollback(c, moved, stage)
    local restored = 0
    for i = #moved, 1, -1 do
        local step = moved[i]
        local okm = move_tree(c, step.dst, step.src)
        if okm then
            restored = restored + 1
        else
            c.log("BOOT_MIGRATE_LAYOUT_ROLLBACK_FAIL name=" .. short(step.name, 24))
        end
    end
    c.log("BOOT_MIGRATE_LAYOUT_ROLLED_BACK stage=" .. tostring(stage)
        .. " restored=" .. tostring(restored) .. " of=" .. tostring(#moved))
    if restored ~= #moved then return nil, "rollback_fail" end
    return nil, tostring(stage)
end

-- Reentrant: every entry is checked on its own, so a boot after a successful
-- migration finds nothing to do (the root entries are gone) and a boot after a
-- rolled back one finds the old layout intact. Returns true when something
-- moved, false when there was nothing to do, nil + stage on failure (the caller
-- turns that into a fatal plan; the system must not boot half migrated).
function M.migrate_layout(opts)
    local c = ctx(opts)
    local todo, skipped = {}, 0
    local groups = { M.legacy_layout(opts), M.legacy_apps(opts) }
    for g = 1, #groups do
        local plan = groups[g]
        for i = 1, #plan do
            local step = plan[i]
            if step.skip then
                skipped = skipped + 1
                c.log("BOOT_MIGRATE_LAYOUT_SKIP name=" .. short(step.name, 24)
                    .. " why=target_exists")
            else
                todo[#todo + 1] = step
            end
        end
    end
    if #todo == 0 then
        if skipped > 0 then
            c.log("BOOT_MIGRATE_LAYOUT_SKIP_TOTAL names=" .. tostring(skipped))
        end
        return false
    end

    local moved = {}
    for i = 1, #todo do
        local step = todo[i]
        local parent = c.fs.getDir(step.dst)
        local okd, derr = ensure_dir(c, parent)
        if not okd then
            c.log("BOOT_MIGRATE_LAYOUT_FAIL name=" .. short(step.name, 24)
                .. " step=mkdir err=" .. short(derr, 24))
            return layout_rollback(c, moved, "mkdir")
        end
        local okm, method = move_tree(c, step.src, step.dst)
        if not okm then
            c.log("BOOT_MIGRATE_LAYOUT_FAIL name=" .. short(step.name, 24)
                .. " step=" .. tostring(method))
            return layout_rollback(c, moved, "move")
        end
        moved[#moved + 1] = step
        c.log("BOOT_MIGRATE_LAYOUT name=" .. short(step.name, 24)
            .. " to=" .. short(step.dst, 48) .. " via=" .. tostring(method))
    end
    local dirs, apps = 0, 0
    for i = 1, #moved do
        if moved[i].kind == "app" then apps = apps + 1 else dirs = dirs + 1 end
    end
    c.log("BOOT_MIGRATE_LAYOUT_DONE dirs=" .. tostring(dirs) .. " apps=" .. tostring(apps))
    return true
end

-- ---------------------------------------------------------------------------
-- migration off the slot layout (P6-design 2.5, order is load-bearing)
-- ---------------------------------------------------------------------------

-- What is left of the slot layout, as file/dir names.
function M.legacy(opts)
    local c = ctx(opts)
    local found = {}
    if c.fs.exists(c.paths.legacy_slot) then found[#found + 1] = "boot.slot" end
    if c.fs.exists(c.paths.legacy_slot .. ".tmp") then found[#found + 1] = "boot.slot.tmp" end
    if c.fs.exists(c.paths.legacy_slots) then found[#found + 1] = "slots" end
    local names = c.fs.list(root_dir(c)) or {}
    for i = 1, #names do
        local name = tostring(names[i])
        if name:match("^system%.tmp") then found[#found + 1] = name end
    end
    return found
end

-- /boot.ok first, then an empty prepare journal, and only then the delete: the
-- reverse order would let a power cut leave neither a system nor a credential.
function M.migrate(opts)
    local c = ctx(opts)
    local found = M.legacy(opts)
    if #found == 0 then return false end
    local version = c.opts.version or M.VERSION
    if not c.fs.exists(c.paths.marker) then
        local ok = M.write_marker({ version = version, manifest_sha = nil }, opts)
        if not ok then
            c.log("BOOT_MIGRATE_FAIL stage=marker")
            return false
        end
    end
    M.write_journal({ state = "prepare", version = version, files = {} }, opts)
    for i = 1, #found do
        local name = found[i]
        local path = join(c.paths.root, name)
        if not remove_path(c, path) then
            c.log("BOOT_MIGRATE_DELETE_FAIL name=" .. short(name, 32))
        else
            c.log("BOOT_MIGRATE_DELETE name=" .. short(name, 32))
        end
    end
    c.log("BOOT_MIGRATED from=slots old=" .. short(table.concat(found, ","), 48))
    return true
end

-- ---------------------------------------------------------------------------
-- the decision table (P6-design section 6)
-- ---------------------------------------------------------------------------

local function fatal(c, reason, extra)
    c.log("BOOT_FATAL reason=" .. short(reason, 32))
    local plan = { ok = false, action = "fatal", error = reason }
    if extra then
        for k, v in pairs(extra) do plan[k] = v end
    end
    return plan
end

-- the rollback helpers log BOOT_FATAL themselves (P6-design 4.3 fixes those
-- three lines), so this variant must not print a second one
local function fatal_quiet(reason)
    return { ok = false, action = "fatal", error = reason }
end

local function normal(c, opts, marker)
    c.log("BOOT_MARKER version=" .. short(marker.version, 16)
        .. " manifest_sha=" .. short(marker.manifest_sha, 12))
    c.log("BOOT_NORMAL version=" .. short(marker.version, 16))
    return { ok = true, action = "normal", tries = M.read_tries(opts), marker = marker }
end

-- trial boot: the counter is persisted BEFORE the system is entered, so a power
-- cut between the increment and the kernel start cannot hand out a free attempt
local function trial_step(c, opts)
    local tries = M.read_tries(opts) + 1
    local ok, err = M.write_tries(tries, opts)
    if not ok then
        c.log("BOOT_TRIES_FAIL err=" .. short(err, 32))
        return fatal(c, "tries_unwritable")
    end
    c.log("BOOT_TRIES_PERSIST tries=" .. tostring(tries))
    if tries > M.MAX_TRIES then return nil, tries end
    c.log("BOOT_TRIAL tries=" .. tostring(tries) .. " max=" .. tostring(M.MAX_TRIES))
    return { ok = true, action = "trial", tries = tries }
end

local function decide(c, opts)
    -- 2.6 layout migration runs before row 1: it may be the step that creates
    -- /system (an image from the pre-P6-3 layout only has the root directories)
    local migrated, mkind = M.migrate_layout(opts)
    if migrated == nil then
        c.log("BOOT_MIGRATE_LAYOUT_ABORT stage=" .. short(mkind, 24))
        return fatal(c, "layout_migrate_fail")
    end

    -- row 1: no system tree is a distinct, fatal condition
    local system = c.paths.system
    if not c.fs.exists(system) then
        c.log("BOOT_NO_SYSTEM path=" .. short(system, 48) .. " why=missing")
        return fatal(c, "no_system")
    end
    if c.fs.isDir and not c.fs.isDir(system) then
        c.log("BOOT_NO_SYSTEM path=" .. short(system, 48) .. " why=not_a_dir")
        return fatal(c, "no_system")
    end
    c.log("BOOT_SYSTEM path=" .. short(system, 48))

    -- 2.5 migration, before the journal is read (it writes a prepare journal)
    if M.migrate(opts) then
        c.log("BOOT_MIGRATE_DONE")
    end

    local rec, jwhy = M.read_journal(opts)
    local marker, mwhy = M.read_marker(opts)
    if marker == nil and mwhy ~= "missing" then
        c.log("BOOT_MARKER_STALE why=" .. short(mwhy, 32))
    end

    if rec == nil and jwhy == "bad" then
        -- both generations unreadable: normally that degrades to "never
        -- updated" (row 2), but leftover backup material means an update is on
        -- disk and cannot be described, which is a rollback failure (4.3)
        if count_all(c, c.paths.backup) > 0 then
            c.log("BOOT_JOURNAL_BAD rollback=required")
            M.rollback(opts)
            return fatal_quiet("rollback_fail")
        end
        c.log("BOOT_JOURNAL_BAD rollback=none")
    end

    if rec then
        c.log("BOOT_JOURNAL seq=" .. rec.seq .. " state=" .. rec.state
            .. " files=" .. tostring(#rec.files))
    else
        c.log("BOOT_JOURNAL none")
    end

    if rec and rec.state == "prepare" then
        -- row 4: the download never applied, the system was never touched
        c.log("BOOT_JOURNAL_PREPARE_CLEAN seq=" .. rec.seq)
        M.cleanup(opts)
        rec = nil
    elseif rec and rec.state == "applying" then
        -- rows 7/8/9: half-applied by definition, roll back before booting
        local okr = M.rollback(opts)
        if not okr then return fatal_quiet("rollback_fail") end
        rec = M.read_journal(opts)
    elseif rec and rec.state == "applied" then
        local committed = marker ~= nil and marker.manifest_sha ~= "none"
            and marker.manifest_sha == rec.manifest_sha
        if committed then
            -- row 10: the new version already proved itself
            if marker.version ~= rec.version then
                c.log("BOOT_VERSION_MISMATCH marker=" .. short(marker.version, 16)
                    .. " journal=" .. short(rec.version, 16))
            end
            c.log("BOOT_UPDATE_COMMITTED version=" .. short(rec.version, 16)
                .. " manifest_sha=" .. short(rec.manifest_sha, 12))
            M.cleanup(opts)
            rec = nil
        elseif M.read_tries(opts) > M.MAX_TRIES then
            -- row 13/14: the trial budget for the new version is gone
            c.log("BOOT_TRIES_EXCEEDED tries=" .. tostring(M.read_tries(opts))
                .. " max=" .. tostring(M.MAX_TRIES))
            local okr = M.rollback(opts)
            if not okr then return fatal_quiet("rollback_fail") end
            rec = M.read_journal(opts)
        end
    end

    if rec and rec.state == "rolledback" then
        -- rows 15/16: the tombstone did its job, drop it and boot what is there
        c.log("BOOT_JOURNAL_ROLLEDBACK seq=" .. rec.seq)
        M.cleanup(opts)
        rec = nil
    end

    if rec then
        -- rows 11/12: applied but not committed, and the budget is not spent
        local plan = trial_step(c, opts)
        if plan then
            plan.journal = rec
            return plan
        end
        c.log("BOOT_TRIES_EXCEEDED tries=" .. tostring(M.read_tries(opts))
            .. " max=" .. tostring(M.MAX_TRIES))
        local okr = M.rollback(opts)
        if not okr then return fatal_quiet("rollback_fail") end
        M.cleanup(opts)
    end

    -- rows 3 / 5 / 6: the steady state, or a system that has never committed
    if marker then
        local tries = M.read_tries(opts)
        if tries > M.MAX_TRIES then
            c.log("BOOT_TRIES_STALE tries=" .. tostring(tries)
                .. " max=" .. tostring(M.MAX_TRIES))
            M.write_tries(0, opts)
            c.log("BOOT_TRIES_RESET tries=0")
        end
        return normal(c, opts, marker)
    end

    local plan, ntries = trial_step(c, opts)
    if plan then return plan end

    -- no credential, no journal, nothing on disk to restore: the machine cannot
    -- boot and there is no rollback material, so say so instead of looping
    c.log("BOOT_TRIES_EXCEEDED tries=" .. tostring(ntries)
        .. " max=" .. tostring(M.MAX_TRIES))
    c.log("BOOT_ROLLBACK_IMPOSSIBLE reason=no_journal")
    M.rollback(opts)
    return fatal_quiet("rollback_fail")
end

function M.begin(opts)
    local c = ctx(opts)
    local plan = decide(c, opts)
    if plan.action ~= "fatal" then
        c.log("BOOT_ACTION action=" .. plan.action
            .. " tries=" .. tostring(plan.tries or M.read_tries(opts)))
    else
        c.log("BOOT_ACTION action=fatal")
    end
    return plan
end

-- ---------------------------------------------------------------------------
-- commit (P6-design 2.4 / 5.2: write /boot.ok, reset tries, drop journal+backup)
-- ---------------------------------------------------------------------------

function M.commit(info, opts)
    local c = ctx(opts)
    if not c.fs.exists(c.paths.system) then
        c.log("BOOT_COMMIT_FAIL reason=missing_system")
        return nil, "system tree missing: " .. c.paths.system
    end
    local i = info or {}
    local ok, err = M.write_marker(i, opts)
    if not ok then
        c.log("BOOT_COMMIT_FAIL reason=marker")
        return nil, err
    end
    local marker = M.read_marker(opts)
    c.log("BOOT_COMMIT version=" .. short(marker and marker.version or "?", 16)
        .. " manifest_sha=" .. short(marker and marker.manifest_sha or "none", 12))
    local wrote = M.write_tries(0, opts)
    if not wrote then c.log("BOOT_TRIES_FAIL err=reset") end
    c.log("BOOT_TRIES_RESET tries=0")
    M.cleanup(opts)
    return true
end

-- ---------------------------------------------------------------------------
-- formatting / bound driver
-- ---------------------------------------------------------------------------

function M.describe(plan)
    if type(plan) ~= "table" then return "boot: no plan" end
    if plan.action == "fatal" then
        return "boot: fatal (" .. tostring(plan.error) .. ")"
    end
    local text = "boot: " .. tostring(plan.action)
    if plan.tries then text = text .. " tries=" .. tostring(plan.tries) end
    if plan.marker then text = text .. " version=" .. tostring(plan.marker.version) end
    if plan.journal then text = text .. " journal=" .. tostring(plan.journal.state) end
    return text
end

local BOUND = {
    "begin", "commit", "rollback", "cleanup", "migrate", "migrate_layout",
    "legacy", "legacy_layout", "legacy_apps",
    "read_journal", "write_journal", "prune_journals", "next_seq", "journal_gens",
    "read_marker", "write_marker", "has_marker", "read_tries", "write_tries",
    "atomic_write", "paths", "journal_path", "system_path", "describe",
}

-- Returns every function bound to one options table, for colon-style calls:
--     local b = boot.new({ root = "/t/case1" })
--     local plan = b:begin()
function M.new(opts)
    local driver = { opts = opts or {} }
    local unpack_args = table.unpack or unpack
    for i = 1, #BOUND do
        local name = BOUND[i]
        driver[name] = function(self, ...)
            -- `M[name](..., self.opts)` would be wrong: a vararg that is not the
            -- last argument is truncated to one value, so every call would pass
            -- (nil, opts) instead of (args..., opts)
            local args = { n = select("#", ...), ... }
            args[args.n + 1] = self.opts
            return M[name](unpack_args(args, 1, args.n + 1))
        end
    end
    return driver
end

return M
