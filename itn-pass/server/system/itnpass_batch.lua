-- itnpass_batch.lua -- scripted batch generation, listing and revocation.
-- Deploy as /system/itnpass_batch.lua on the card key station.
--
-- Two ways to load this file:
--   * from the CraftOS shell (any argument):
--       itnpass_batch new 20 --uses 2 --prefix labA
--     main() runs, prints one ASCII summary line beyond the per-item lines and
--     raises an error when the command fails, so a wrapper script notices.
--   * as a table module (no arguments): loadfile(path)() returns M and does
--     nothing else; that is what the offline suite drives.
--
-- Boundary with the store: every database operation goes through
-- /auth/itnpass_store.lua (mint / commitBatch / export / list / revoke /
-- unrevoke / prune / log). This tool never opens /auth/itnpass_passes.db, never
-- derives a fingerprint and never keeps a plaintext key after export. That is
-- also why `unrevoke` needs the FULL key: the database only holds fingerprints,
-- so a 12-character id cannot be turned back into the code it came from.
--
-- Plaintext keys never go to stdout. `new` writes them to a staging file under
-- <export_dir>/.stage/ and prints ids only; `export --out PATH` is the single
-- command that writes a distribution file, and PATH must be given explicitly.

local M = {}

M.VERSION = "1.0"
-- First token of the note written into every record this tool creates. The
-- note field is the store's documented free-text slot, so batch metadata needs
-- no database schema change (expires/prefix/profile are recorded there).
M.NOTE_TAG = "itnp-batch/1"
M.STORE_PATH = "/auth/itnpass_store.lua"
M.CONFIG_PATH = "/auth/itnpass_config.lua"
M.PROFILE_PATH = "/itnpass_profile.lua"
M.LOG_PATH = "/auth/itnpass_server.log"
M.STAGE_DIR_NAME = ".stage"
M.MAX_USES = 1000
M.MAX_EXPIRES_DAYS = 3650
M.MAX_PROFILE_LEN = 32
M.MAX_PREFIX_LEN = 24
M.DEFAULT_PROFILE = "default"
M.DEFAULT_PREFIX = "batch"
M.DAY_MS = 86400000
M.STATUS = {
    ACTIVE = "active",
    USED = "used",
    EXPIRED = "expired",
    REVOKED = "revoked",
}

local STATUS_VALUES = {
    active = true,
    used = true,
    expired = true,
    revoked = true,
}

local COMMANDS = {
    new = true,
    list = true,
    export = true,
    revoke = true,
    unrevoke = true,
    prune = true,
}

----------------------------------------------------------------------------
-- small helpers (no state: everything below reads the disk when it is called)
----------------------------------------------------------------------------

local function nowMs()
    return os.epoch("utc")
end

local function say(text)
    print(text)
end

-- Appends one line to the service log. The batch tool and the service share
-- /auth/itnpass_server.log, so one grep finds admin actions and traffic
-- together; the writer is local because the tool must still log when the store
-- itself failed to load.
local function log(message)
    local stamp = ""
    local okDate, value = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if okDate and type(value) == "string" then
        stamp = value
    end
    local f = fs.open(M.LOG_PATH, "a")
    if not f then
        return false
    end
    f.write(stamp .. "  " .. tostring(message) .. "\n")
    f.close()
    return true
end

M.log = log

local function readFile(path)
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "rb")
    if not f then
        return nil
    end
    local text = f.readAll()
    f.close()
    return text
end

local function writeFile(path, text)
    local f = fs.open(path, "wb")
    if not f then
        return false, "cannot open " .. path
    end
    local ok, err = pcall(function()
        f.write(text)
    end)
    f.close()
    if not ok then
        return false, "write failed: " .. tostring(err)
    end
    if (fs.getSize(path) or -1) ~= #text then
        return false, "write failed: " .. path
    end
    return true
end

local function parentOf(path)
    local p = tostring(path):gsub("/+$", "")
    local cut = p:match("^.*()/")
    if not cut or cut == 1 then
        return "/"
    end
    return p:sub(1, cut - 1)
end

local function ensureDir(path)
    if path == nil or path == "" or path == "/" then
        return true
    end
    if fs.exists(path) then
        return fs.isDir(path)
    end
    if not ensureDir(parentOf(path)) then
        return false
    end
    local made = fs.makeDir(path)
    if made == nil then
        made = false
    end
    return made or (fs.exists(path) and fs.isDir(path))
end

local function loadStore()
    local ok, store = pcall(dofile, M.STORE_PATH)
    if not ok or type(store) ~= "table" then
        return nil, "cannot load " .. M.STORE_PATH
    end
    return store
end

-- The payload profile catalog. Batches are minted for a profile (the store
-- binds the new records to it), so an unknown name must be refused instead of
-- producing keys that no station can ever charge.
local function loadProfiles()
    local ok, mod = pcall(dofile, M.PROFILE_PATH)
    if not ok or type(mod) ~= "table" then
        return nil, "cannot load " .. M.PROFILE_PATH
    end
    return mod
end

M.loadProfiles = loadProfiles

local function config()
    local ok, value = pcall(dofile, M.CONFIG_PATH)
    if ok and type(value) == "table" then
        return value
    end
    return {}
end

-- One token of a batch label: letters, digits, dot, dash, underscore. Values
-- go into note fields, file names and JSON lines, so anything else is refused
-- instead of being silently rewritten.
local function safeLabel(text, limit)
    if type(text) ~= "string" then
        return nil
    end
    if text == "" or #text > limit then
        return nil
    end
    if not text:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") then
        return nil
    end
    return text
end

M.safeLabel = safeLabel

local function integerOf(value)
    if type(value) == "number" then
        if value ~= math.floor(value) then
            return nil
        end
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    if not value:match("^%d+$") then
        return nil
    end
    return tonumber(value)
end

M.integerOf = integerOf

local function jsonString(value)
    local text = tostring(value == nil and "" or value)
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("[%z\1-\31]", " ")
    return '"' .. text .. '"'
end

M.jsonString = jsonString

----------------------------------------------------------------------------
-- batch note: the only place batch metadata is stored
----------------------------------------------------------------------------

-- The note is a single ASCII line of key=value tokens, so an operator reading
-- the console output (or an older store build) still sees plain text. expires
-- is an absolute epoch-millisecond value; 0 means "no expiry recorded".
local function buildNote(fields)
    return table.concat({
        M.NOTE_TAG,
        "batch=" .. tostring(fields.batch),
        "profile=" .. tostring(fields.profile),
        "prefix=" .. tostring(fields.prefix),
        "uses=" .. tostring(fields.uses),
        "expires=" .. tostring(fields.expires or 0),
    }, " ")
end

M.buildNote = buildNote

-- Returns a table for notes written by this tool, nil for any other note
-- (for example the free-text note typed into the station console).
local function parseNote(note)
    if type(note) ~= "string" then
        return nil
    end
    if note:sub(1, #M.NOTE_TAG) ~= M.NOTE_TAG then
        return nil
    end
    local meta = {
        batch = "",
        profile = "",
        prefix = "",
        uses = 0,
        expires = 0,
    }
    for key, value in note:gmatch("(%S+)=(%S+)") do
        if key == "batch" then
            meta.batch = value
        elseif key == "profile" then
            meta.profile = value
        elseif key == "prefix" then
            meta.prefix = value
        elseif key == "uses" then
            meta.uses = tonumber(value) or 0
        elseif key == "expires" then
            meta.expires = tonumber(value) or 0
        end
    end
    return meta
end

M.parseNote = parseNote

-- Status precedence: revoked > used > expired > active. A key that is both
-- used up and past its expiry reports "used"; revocation always wins because it
-- is the operator's explicit decision.
local function statusOf(item, now)
    if type(item) ~= "table" then
        return M.STATUS.ACTIVE
    end
    if item.revoked then
        return M.STATUS.REVOKED
    end
    if (item.uses_left or 0) <= 0 then
        return M.STATUS.USED
    end
    local meta = parseNote(item.note)
    if meta and meta.expires > 0 and meta.expires <= now then
        return M.STATUS.EXPIRED
    end
    return M.STATUS.ACTIVE
end

M.statusOf = statusOf

-- One machine readable line per key. Only ids and fingerprints prefixes are
-- printed: a full key exists in this process only while `new` runs, and after
-- that only inside the staging file.
local function keyLine(item, now)
    local meta = parseNote(item.note) or {batch = "", profile = "", expires = 0, uses = 0}
    local id = tostring(item.fp or "")
    return "{" ..
        "\"id\":" .. jsonString(id) ..
        ",\"fp6\":" .. jsonString(id:sub(1, 6)) ..
        ",\"uses_left\":" .. tostring(item.uses_left or 0) ..
        ",\"uses_total\":" .. tostring(item.uses_total or 0) ..
        ",\"status\":" .. jsonString(statusOf(item, now)) ..
        ",\"batch\":" .. jsonString(meta.batch) ..
        ",\"profile\":" .. jsonString(meta.profile) ..
        ",\"expires\":" .. tostring(meta.expires or 0) ..
        "}"
end

M.keyLine = keyLine

----------------------------------------------------------------------------
-- paths
----------------------------------------------------------------------------

local function exportDir()
    local dir = tostring(config().export_dir or "/cardkeys"):gsub("/+$", "")
    if dir == "" then
        dir = "/"
    end
    return dir
end

local function stageDir()
    local dir = exportDir()
    if dir == "/" then
        return "/" .. M.STAGE_DIR_NAME
    end
    return dir .. "/" .. M.STAGE_DIR_NAME
end

M.stageDir = stageDir

local function batchStamp()
    local stamp = os.date("%Y%m%d-%H%M%S")
    if type(stamp) ~= "string" or stamp == "" then
        stamp = tostring(math.floor(nowMs() / 1000))
    end
    return stamp
end

-- Same-second batches get -2, -3 ... exactly like the store's export names, so
-- a staging file is never overwritten.
local function uniqueBatchId(dir, prefix)
    local base = prefix .. "-" .. batchStamp()
    local id = base
    local suffix = 1
    while fs.exists(dir .. "/" .. id .. ".txt") do
        suffix = suffix + 1
        id = base .. "-" .. tostring(suffix)
    end
    return id
end

local function stagedBatches()
    local dir = stageDir()
    local names = {}
    if fs.exists(dir) and fs.isDir(dir) then
        for _, name in ipairs(fs.list(dir)) do
            if name:match("^.+%.txt$") then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names, dir
end

----------------------------------------------------------------------------
-- argument parsing
----------------------------------------------------------------------------

local VALUE_FLAGS = {
    ["--uses"] = "uses",
    ["--prefix"] = "prefix",
    ["--profile"] = "profile",
    ["--expires"] = "expires",
    ["--status"] = "status",
    ["--out"] = "out",
    ["--batch"] = "batch",
}

local SWITCH_FLAGS = {
    ["--yes"] = "yes",
    ["--keep"] = "keep",
}

-- Returns spec = {command, positional = {...}, uses, prefix, profile, expires,
-- status, out, yes, keep}, or nil plus a human readable reason.
function M.parse(argv)
    if type(argv) ~= "table" then
        return nil, "no arguments"
    end
    local command = argv[1]
    if type(command) ~= "string" or command == "" then
        return nil, "missing command"
    end
    local spec = {command = command, positional = {}}
    local index = 2
    while index <= #argv do
        local token = tostring(argv[index])
        local name = VALUE_FLAGS[token]
        if name then
            local value = argv[index + 1]
            if value == nil then
                return nil, "missing value for " .. token
            end
            spec[name] = tostring(value)
            index = index + 2
        elseif SWITCH_FLAGS[token] then
            spec[SWITCH_FLAGS[token]] = true
            index = index + 1
        elseif token:sub(1, 2) == "--" then
            return nil, "unknown option " .. token
        else
            spec.positional[#spec.positional + 1] = token
            index = index + 1
        end
    end
    return spec
end

function M.usage()
    local profiles = loadProfiles()
    local profileLine = "  profiles come from " .. M.PROFILE_PATH .. ": default"
    if profiles then
        profileLine = "  profiles come from " .. M.PROFILE_PATH .. ": " ..
            profiles.names_line()
    end
    return table.concat({
        "ITN-Pass batch tool " .. M.VERSION,
        "usage:",
        "  itnpass_batch new <count> [--uses N] [--prefix P] [--profile NAME] [--expires DAYS]",
        "  itnpass_batch list [--status active|used|expired|revoked]",
        "  itnpass_batch export --out PATH [--batch ID] [--keep]",
        "  itnpass_batch revoke <id-prefix|full key> --yes",
        "  itnpass_batch unrevoke <full key>",
        "  itnpass_batch prune",
        profileLine,
        "plaintext keys never go to the screen:",
        "  new stages them under " .. M.STAGE_DIR_NAME .. "/, export copies that file to an",
        "  explicit path and removes the staging copy unless --keep is given.",
    }, "\n")
end

----------------------------------------------------------------------------
-- new
----------------------------------------------------------------------------

local function commandNew(spec)
    local count = integerOf(spec.positional[1])
    if count == nil or count < 1 then
        return false, 0, "bad_count", "count must be a positive integer", nil, nil
    end
    if #spec.positional > 1 then
        return false, 0, "bad_args", "too many arguments for new", nil, nil
    end
    local conf = config()
    local maxBatch = tonumber(conf.max_batch) or 200
    if count > maxBatch then
        return false, 0, "count_too_large",
            "count above max_batch (" .. tostring(maxBatch) .. ")", nil, nil
    end
    local profiles, whyProfiles = loadProfiles()
    if not profiles then
        return false, 0, "profile_unavailable", whyProfiles, nil, nil
    end
    -- The profile is chosen before the use count: a profile carries its own
    -- card key budget (one disk per use), so `new --profile pyroet-os` without
    -- --uses must mint single-write keys, not the station-wide default.
    local profile = M.DEFAULT_PROFILE
    if spec.profile ~= nil then
        profile = safeLabel(spec.profile, M.MAX_PROFILE_LEN)
        if profile == nil then
            return false, 0, "bad_profile",
                "profile must be 1-" .. tostring(M.MAX_PROFILE_LEN) ..
                " characters of [A-Za-z0-9._-]", nil, nil
        end
    elseif type(conf.profile) == "string" and conf.profile ~= "" then
        -- Site default, resolved by /itnpass_profile.lua when the config loads.
        profile = conf.profile
    end
    if not profiles.is_known(profile) then
        return false, 0, "bad_profile",
            "unknown profile " .. tostring(profile) .. " (known: " ..
            profiles.names_line() .. ")", nil, nil
    end

    local uses = profiles.default_uses(profile)
    if uses == nil then
        uses = integerOf(conf.default_uses) or 2
    end
    if spec.uses ~= nil then
        uses = integerOf(spec.uses)
        if uses == nil then
            return false, 0, "bad_uses", "uses must be a positive integer", nil, nil
        end
    end
    if uses < 1 or uses > M.MAX_USES then
        return false, 0, "bad_uses",
            "uses must be between 1 and " .. tostring(M.MAX_USES), nil, nil
    end
    local days = 0
    if spec.expires ~= nil then
        days = integerOf(spec.expires)
        if days == nil or days < 1 or days > M.MAX_EXPIRES_DAYS then
            return false, 0, "bad_expires",
                "expires must be between 1 and " .. tostring(M.MAX_EXPIRES_DAYS) .. " days",
                nil, nil
        end
    end
    local prefix = M.DEFAULT_PREFIX
    if spec.prefix ~= nil then
        prefix = safeLabel(spec.prefix, M.MAX_PREFIX_LEN)
        if prefix == nil then
            return false, 0, "bad_prefix",
                "prefix must be 1-" .. tostring(M.MAX_PREFIX_LEN) ..
                " characters of [A-Za-z0-9._-]", nil, nil
        end
    end

    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end

    local recorded = nowMs()
    local expires = 0
    if days > 0 then
        expires = recorded + days * M.DAY_MS
    end
    local dir = stageDir()
    local id = uniqueBatchId(dir, prefix)
    local note = buildNote({
        batch = id,
        profile = profile,
        prefix = prefix,
        uses = uses,
        expires = expires,
    })

    local codes, pending = store.mint(count, uses, note, profile)
    if not codes then
        return false, 0, "mint_failed", tostring(pending), nil, nil
    end

    -- The plaintext file is written before the database is touched: a staging
    -- failure leaves the store untouched, so no unusable key can be charged.
    local path = dir .. "/" .. id .. ".txt"
    local wrote, whyWrite = store.export(codes, path, {uses = uses, note = note})
    if not wrote then
        return false, 0, "stage_failed", tostring(whyWrite), " staged=none", nil
    end
    local stored = store.commitBatch(pending)
    if stored ~= count then
        return false, stored, "commit_failed",
            "stored " .. tostring(stored) .. " of " .. tostring(count),
            " batch=" .. id .. " staged=" .. path, nil
    end

    local lines = {}
    for index = 1, #pending do
        local item = pending[index]
        lines[#lines + 1] = keyLine({
            fp = item.fp:sub(1, 12),
            uses_left = uses,
            uses_total = uses,
            revoked = false,
            note = note,
        }, recorded)
    end

    local extra = " batch=" .. id ..
        " uses=" .. tostring(uses) ..
        " profile=" .. profile ..
        " expires=" .. tostring(expires) ..
        " staged=" .. path
    return true, count, nil, nil, extra, lines
end

----------------------------------------------------------------------------
-- list
----------------------------------------------------------------------------

local function commandList(spec)
    local filter = nil
    if spec.status ~= nil then
        filter = tostring(spec.status):lower()
        if not STATUS_VALUES[filter] then
            return false, 0, "bad_status",
                "status must be one of active, used, expired, revoked", nil, nil
        end
    end
    if #spec.positional > 0 then
        return false, 0, "bad_args", "list takes no positional arguments", nil, nil
    end
    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end

    local items = store.list()
    local now = nowMs()
    local lines = {}
    for _, item in ipairs(items) do
        if filter == nil or statusOf(item, now) == filter then
            lines[#lines + 1] = keyLine(item, now)
        end
    end
    local extra = " total=" .. tostring(#items) .. " shown=" .. tostring(#lines)
    if filter then
        extra = extra .. " status=" .. filter
    end
    return true, #items, nil, nil, extra, lines
end

----------------------------------------------------------------------------
-- export
----------------------------------------------------------------------------

local function commandExport(spec)
    local out = spec.out
    if type(out) ~= "string" or out == "" then
        return false, 0, "no_out", "--out PATH is required", nil, nil
    end
    if #spec.positional > 0 then
        return false, 0, "bad_args", "export takes no positional arguments", nil, nil
    end
    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end
    local names, dir = stagedBatches()
    local id
    if spec.batch ~= nil then
        id = safeLabel(spec.batch, 64)
        if id == nil then
            return false, 0, "bad_batch", "batch id is not a valid file name", nil, nil
        end
    elseif #names == 0 then
        return false, 0, "no_staging",
            "nothing staged; run new first", " staged=none", nil
    elseif #names > 1 then
        -- Two staged batches are two plaintext files; picking one by name would
        -- be a guess. The operator (or a script) names the batch instead.
        return false, 0, "ambiguous_staging",
            tostring(#names) .. " staged batches; pass --batch <id>", nil, nil
    else
        id = names[1]:gsub("%.txt$", "")
    end
    local source = dir .. "/" .. id .. ".txt"
    if not fs.exists(source) then
        return false, 0, "no_staging",
            "no staged batch named " .. id, " batch=" .. id, nil
    end
    if out:gsub("/+$", "") == source then
        return false, 0, "same_path",
            "the export path is the staging file itself", " batch=" .. id, nil
    end
    local text = readFile(source)
    if text == nil then
        return false, 0, "stage_read", "cannot read " .. source, " batch=" .. id, nil
    end
    if fs.exists(out) and fs.isDir(out) then
        return false, 0, "out_is_dir", "not a file: " .. out, " batch=" .. id, nil
    end
    if not ensureDir(parentOf(out)) then
        return false, 0, "out_dir", "cannot create " .. parentOf(out), " batch=" .. id, nil
    end
    local wrote, whyWrite = writeFile(out, text)
    if not wrote then
        return false, 0, "out_write", tostring(whyWrite), " batch=" .. id, nil
    end
    if (readFile(out) or "") ~= text then
        pcall(fs.delete, out)
        return false, 0, "out_verify",
            "readback differs from the staged file", " batch=" .. id, nil
    end
    local keys = 0
    for line in text:gmatch("[^\n]+") do
        if store.normalize(line) ~= nil then
            keys = keys + 1
        end
    end
    if keys == 0 then
        pcall(fs.delete, out)
        return false, 0, "no_keys",
            "the staged batch holds no keys", " batch=" .. id, nil
    end
    local purged = false
    if not spec.keep then
        -- fs.delete can fail without raising, so the file's absence is the
        -- only trustworthy success signal.
        pcall(fs.delete, source)
        purged = not fs.exists(source)
    end
    local line = "{\"batch\":" .. jsonString(id) ..
        ",\"out\":" .. jsonString(out) ..
        ",\"keys\":" .. tostring(keys) ..
        ",\"bytes\":" .. tostring(#text) ..
        ",\"staging\":" .. jsonString(purged and "purged" or "kept") .. "}"
    local extra = " batch=" .. id ..
        " out=" .. out ..
        " bytes=" .. tostring(#text) ..
        " staging=" .. (purged and "purged" or "kept")
    return true, keys, nil, nil, extra, {line}
end

----------------------------------------------------------------------------
-- revoke / unrevoke
----------------------------------------------------------------------------

local function commandRevoke(spec)
    local target = spec.positional[1]
    if type(target) ~= "string" or target == "" then
        return false, 0, "no_target", "revoke needs an id prefix or a full key", nil, nil
    end
    if #spec.positional > 1 then
        return false, 0, "bad_args", "revoke takes one target", nil, nil
    end
    if not spec.yes then
        return false, 0, "confirmation_required",
            "refusing to revoke without --yes", nil, nil
    end
    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end
    local ok, message = store.revoke(target)
    if not ok then
        return false, 0, "revoke_failed", tostring(message), nil, nil
    end
    -- Never echo what was typed: it may be a full plaintext key. A key is
    -- reported by id, a fingerprint prefix is already safe to repeat.
    local shown = target
    local norm = store.normalize(target)
    if norm then
        shown = tostring(store.fingerprint(norm) or ""):sub(1, 12)
    end
    return true, 1, nil, nil, " target=" .. shown, nil
end

local function commandUnrevoke(spec)
    local target = spec.positional[1]
    if type(target) ~= "string" or target == "" then
        return false, 0, "no_target", "unrevoke needs the full key", nil, nil
    end
    if #spec.positional > 1 then
        return false, 0, "bad_args", "unrevoke takes one key", nil, nil
    end
    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end
    local norm = store.normalize(target)
    if norm == nil then
        -- Deliberate: the database stores sha256(pepper|key) only, so restoring
        -- by id would mean storing the key itself and losing that property.
        return false, 0, "needs_full_key",
            "unrevoke needs the full key (the database stores fingerprints only)",
            nil, nil
    end
    local ok, message = store.unrevoke(norm)
    if not ok then
        return false, 0, "unrevoke_failed", tostring(message), nil, nil
    end
    return true, 1, nil, nil, " id=" .. tostring(store.fingerprint(norm) or ""):sub(1, 12), nil
end

----------------------------------------------------------------------------
-- prune
----------------------------------------------------------------------------

-- Three independent cleanups, in this order:
--   1. expired reservations (delegated to store.prune);
--   2. keys whose recorded expiry passed are revoked through store.revoke, so
--      the station itself enforces the expiry (it only looks at `revoked`);
--   3. staging files of a batch whose keys are all dead are deleted, so
--      plaintext does not stay on the station disk forever. A staging file with
--      no matching database records is KEPT: after a database loss it may be
--      the only copy of the keys, and deleting it silently would be worse.
local function commandPrune(spec)
    if #spec.positional > 0 then
        return false, 0, "bad_args", "prune takes no arguments", nil, nil
    end
    local store, whyStore = loadStore()
    if not store then
        return false, 0, "store_unavailable", whyStore, nil, nil
    end
    local now = nowMs()
    local dropped = store.prune()
    local revoked = 0
    local live = {}
    for _, item in ipairs(store.list()) do
        local meta = parseNote(item.note)
        local status = statusOf(item, now)
        if status == M.STATUS.EXPIRED then
            local ok, _ = store.revoke(item.fp)
            if ok then
                revoked = revoked + 1
                status = M.STATUS.REVOKED
            end
        end
        if meta and meta.batch ~= "" then
            local entry = live[meta.batch]
            if entry == nil then
                entry = {alive = false}
                live[meta.batch] = entry
            end
            if status ~= M.STATUS.REVOKED and status ~= M.STATUS.EXPIRED then
                entry.alive = true
            end
        end
    end
    local removed = 0
    local dir = stageDir()
    if fs.exists(dir) and fs.isDir(dir) then
        for _, name in ipairs(fs.list(dir)) do
            local id = name:match("^(.+)%.txt$")
            if id then
                local entry = live[id]
                if entry ~= nil and not entry.alive then
                    local ok = pcall(fs.delete, dir .. "/" .. name)
                    if ok then
                        removed = removed + 1
                    end
                end
            end
        end
    end
    local count = dropped + revoked + removed
    local extra = " reservations=" .. tostring(dropped) ..
        " expired=" .. tostring(revoked) ..
        " staging=" .. tostring(removed)
    return true, count, nil, nil, extra, nil
end

----------------------------------------------------------------------------
-- dispatch
----------------------------------------------------------------------------

local HANDLERS = {
    new = commandNew,
    list = commandList,
    export = commandExport,
    revoke = commandRevoke,
    unrevoke = commandUnrevoke,
    prune = commandPrune,
}

-- Runs one command. Returns ok plus the error text on failure; every run leaves
-- exactly one ITNP_BATCH line in /auth/itnpass_server.log.
function M.main(argv)
    local spec, why = M.parse(argv)
    if not spec then
        say("ITNP_BATCH error ok=0 detail=" .. tostring(why))
        return false, why
    end
    if not COMMANDS[spec.command] then
        if spec.command == "help" then
            say(M.usage())
            return true
        end
        local message = "unknown command " .. tostring(spec.command) ..
            " (new, list, export, revoke, unrevoke, prune)"
        say("ITNP_BATCH error ok=0 detail=" .. message)
        return false, message
    end
    local handler = HANDLERS[spec.command]
    local ok, count, slug, message, extra, lines = handler(spec)
    count = count or 0
    extra = extra or ""
    if type(lines) == "table" then
        for _, line in ipairs(lines) do
            say(line)
        end
    end
    local summary
    if ok then
        summary = "ITNP_BATCH " .. spec.command .. " count=" .. tostring(count) ..
            " ok=1" .. extra
    else
        summary = "ITNP_BATCH " .. spec.command .. " count=" .. tostring(count) ..
            " ok=0 error=" .. tostring(slug) .. extra ..
            " detail=" .. tostring(message)
    end
    say(summary)
    log("ITNP_BATCH " .. spec.command .. " count=" .. tostring(count) ..
        " ok=" .. (ok and "1" or "0") .. extra ..
        (ok and "" or (" error=" .. tostring(slug))))
    return ok, message
end

----------------------------------------------------------------------------
-- standalone entry point
----------------------------------------------------------------------------

local argv = {...}
if select("#", ...) > 0 then
    local ok, message = M.main(argv)
    if not ok then
        error("itnpass_batch: " .. tostring(message), 0)
    end
end

return M
