-- cardkey_store.lua -- pepper-derived card key database and charge accounting.
-- Deploy as /auth/cardkey_store.lua on the card key server.
--
-- The database only ever holds sha256(code .. "|" .. pepper) fingerprints.
-- Plaintext codes exist while a batch is being generated and in the exported
-- text files; nothing else stores them.

local M = {}

local sha = dofile("/sha256.lua")

local ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
local CODE_LEN = 16
local PEPPER_PATH = "/auth/cardkey_pepper.txt"
local DB_PATH = "/auth/cardkeys.db"
local PEPPER_LEN = 48
local PEPPER_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

local data = {}
local resIndex = {}
local pepper = nil
local lastRaw = nil
local mintCounter = 0

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------

local function nowMs()
    return os.epoch("utc")
end

local function cfg()
    local ok, t = pcall(dofile, "/auth/cardkey_config.lua")
    if ok and type(t) == "table" then
        return t
    end
    return {}
end

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
    -- CraftOS-PC's file:write returns nothing, so success is checked by size.
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

-- Parent directory of an absolute path ("/" for top level entries).
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
    local okParent = ensureDir(parentOf(path))
    if not okParent then
        return false
    end
    local made = fs.makeDir(path)
    if made == nil then
        made = false
    end
    return made or (fs.exists(path) and fs.isDir(path))
end

local function parseDb(raw)
    if type(raw) ~= "string" or raw == "" then
        return {}
    end
    local ok, t = pcall(textutils.unserialize, raw)
    if ok and type(t) == "table" then
        return t
    end
    return nil
end

local function rebuildIndex()
    resIndex = {}
    for fp, rec in pairs(data) do
        if type(rec) == "table" and type(rec.reservations) == "table" then
            for resId in pairs(rec.reservations) do
                resIndex[resId] = fp
            end
        end
    end
end

local function save()
    local text = textutils.serialize(data)
    local ok = writeFile(DB_PATH, text)
    if not ok then
        return false
    end
    lastRaw = text
    return true
end

-- Other agents (admin console and service) hold their own copy of this module.
-- Re-read the file when somebody else saved it so neither copy loses keys.
local function refresh()
    local raw = readFile(DB_PATH)
    if raw == lastRaw then
        return
    end
    if raw == nil then
        data = {}
        lastRaw = nil
        rebuildIndex()
        return
    end
    local parsed = parseDb(raw)
    if parsed then
        data = parsed
        lastRaw = raw
        rebuildIndex()
    end
end

local function liveReservations(rec, now)
    local held = 0
    if type(rec.reservations) == "table" then
        for _, expiry in pairs(rec.reservations) do
            if type(expiry) == "number" and expiry > now then
                held = held + 1
            end
        end
    end
    return held
end

local function randomString(alphabet, count)
    local out = {}
    for i = 1, count do
        local idx = math.random(1, #alphabet)
        out[i] = alphabet:sub(idx, idx)
    end
    return table.concat(out)
end

local function seedPrng()
    local seed = nowMs() % 2147483647
    seed = bit32.bxor(seed, math.floor(os.clock() * 1000000) % 2147483647)
    seed = bit32.bxor(seed, os.getComputerID() * 7919)
    math.randomseed(seed % 2147483647)
end

local function loadPepper()
    local raw = readFile(PEPPER_PATH)
    if raw then
        raw = raw:gsub("%s+", "")
    end
    if raw and raw ~= "" then
        pepper = raw
        return
    end
    local fresh = randomString(PEPPER_ALPHABET, PEPPER_LEN)
    writeFile(PEPPER_PATH, fresh .. "\n")
    -- Re-read what is actually on disk: two instances starting at once must
    -- never end up using different peppers.
    local check = readFile(PEPPER_PATH)
    if check then
        check = check:gsub("%s+", "")
    end
    if check and check ~= "" then
        pepper = check
    else
        pepper = fresh
    end
end

local function deriveCode(label)
    local digest = sha.hash((pepper or "") .. "|cardkey|" .. label)
    local out = {}
    for i = 1, CODE_LEN do
        local byte = tonumber(digest:sub(i * 2 - 1, i * 2), 16) or 0
        local idx = (byte % 32) + 1
        out[i] = ALPHABET:sub(idx, idx)
    end
    return table.concat(out)
end

local function newLabel()
    mintCounter = mintCounter + 1
    return tostring(nowMs()) .. ":" .. tostring(mintCounter) .. ":" ..
        tostring(math.random(1, 2147483647)) .. ":" .. tostring(os.getComputerID())
end

---------------------------------------------------------------------------
-- boot: seed the PRNG, load the database, load (or create) the pepper
---------------------------------------------------------------------------

seedPrng()

do
    local raw = readFile(DB_PATH)
    local parsed = parseDb(raw)
    if parsed then
        data = parsed
    else
        data = {}
    end
    lastRaw = raw
    rebuildIndex()
end

loadPepper()

---------------------------------------------------------------------------
-- code format helpers
---------------------------------------------------------------------------

function M.normalize(code)
    if type(code) ~= "string" then
        return nil
    end
    local s = code:upper():gsub("[^A-Z0-9]", "")
    if #s ~= CODE_LEN then
        return nil
    end
    for i = 1, #s do
        if not ALPHABET:find(s:sub(i, i), 1, true) then
            return nil
        end
    end
    return s
end

function M.fingerprint(code)
    local norm = M.normalize(code)
    if not norm then
        return nil
    end
    return sha.hash(norm .. "|" .. (pepper or ""))
end

function M.format(code)
    local norm = M.normalize(code)
    if not norm then
        return nil
    end
    return norm:sub(1, 4) .. "-" .. norm:sub(5, 8) .. "-" ..
        norm:sub(9, 12) .. "-" .. norm:sub(13, 16)
end

---------------------------------------------------------------------------
-- lookup / reservations / charging
---------------------------------------------------------------------------

function M.lookup(code)
    refresh()
    local norm = M.normalize(code)
    if not norm then
        return nil, "invalid code format"
    end
    local fp = M.fingerprint(norm)
    local rec = data[fp]
    if type(rec) ~= "table" then
        return nil, "unknown code"
    end
    if rec.revoked then
        return nil, "revoked"
    end
    local left = rec.uses_left or 0
    if left <= 0 then
        return nil, "used up"
    end
    local held = liveReservations(rec, nowMs())
    if left - held <= 0 then
        return nil, "in use on another terminal"
    end
    return rec, nil, fp
end

function M.reserve(code, resId)
    refresh()
    if type(resId) ~= "string" or resId == "" then
        return nil, "missing reservation id"
    end
    local norm = M.normalize(code)
    if not norm then
        return nil, "invalid code format"
    end
    local fp = M.fingerprint(norm)
    local rec = data[fp]
    if type(rec) ~= "table" then
        return nil, "unknown code"
    end
    if rec.revoked then
        return nil, "revoked"
    end
    if type(rec.reservations) ~= "table" then
        rec.reservations = {}
    end
    local now = nowMs()
    local ttl = tonumber(cfg().reservation_ttl_ms) or 300000
    local live = 0
    for id, expiry in pairs(rec.reservations) do
        if type(expiry) ~= "number" or expiry <= now then
            rec.reservations[id] = nil
            resIndex[id] = nil
        else
            live = live + 1
        end
    end
    local left = rec.uses_left or 0
    if left <= 0 then
        return nil, "used up"
    end
    if rec.reservations[resId] then
        return nil, "duplicate request"
    end
    if left - live <= 0 then
        return nil, "in use on another terminal"
    end
    local expiry = now + ttl
    rec.reservations[resId] = expiry
    resIndex[resId] = fp
    save()
    return {
        fp = fp,
        resId = resId,
        uses_total = rec.uses_total,
        uses_left = rec.uses_left,
        held = live + 1,
        expires = expiry,
    }
end

function M.commit(resId)
    refresh()
    local fp = resIndex[resId]
    if not fp then
        return nil, "no such reservation"
    end
    local rec = data[fp]
    local now = nowMs()
    local expiry = nil
    if type(rec) == "table" and type(rec.reservations) == "table" then
        expiry = rec.reservations[resId]
    end
    if type(expiry) ~= "number" or expiry <= now then
        if type(rec) == "table" and type(rec.reservations) == "table" then
            rec.reservations[resId] = nil
        end
        resIndex[resId] = nil
        return nil, "no such reservation"
    end
    rec.reservations[resId] = nil
    resIndex[resId] = nil
    local charged = (rec.uses_left or 0) > 0
    if charged then
        rec.uses_left = rec.uses_left - 1
    end
    rec.last_used = now
    save()
    return rec, charged
end

function M.release(resId)
    refresh()
    local fp = resIndex[resId]
    if not fp then
        return nil, "no such reservation"
    end
    local rec = data[fp]
    if type(rec) ~= "table" or type(rec.reservations) ~= "table" or
        rec.reservations[resId] == nil then
        resIndex[resId] = nil
        return nil, "no such reservation"
    end
    rec.reservations[resId] = nil
    resIndex[resId] = nil
    save()
    return true
end

-- Drops expired holds. Saves when something was actually removed so the
-- cleanup survives a restart.
function M.prune()
    refresh()
    local now = nowMs()
    local dropped = 0
    for _, rec in pairs(data) do
        if type(rec) == "table" and type(rec.reservations) == "table" then
            for id, expiry in pairs(rec.reservations) do
                if type(expiry) ~= "number" or expiry <= now then
                    rec.reservations[id] = nil
                    resIndex[id] = nil
                    dropped = dropped + 1
                end
            end
        end
    end
    if dropped > 0 then
        save()
    end
    return dropped
end

---------------------------------------------------------------------------
-- generation and export
---------------------------------------------------------------------------

function M.mint(count, uses, note)
    refresh()
    if type(count) ~= "number" or count < 1 then
        return nil, "count must be >= 1"
    end
    if type(uses) ~= "number" or uses < 1 then
        return nil, "uses must be >= 1"
    end
    count = math.floor(count)
    uses = math.floor(uses)
    if count < 1 then
        return nil, "count must be >= 1"
    end
    if uses < 1 then
        return nil, "uses must be >= 1"
    end
    note = type(note) == "string" and note or ""
    local codes, pending = {}, {}
    local taken = {}
    local attempts = count * 50 + 200
    local created = nowMs()
    while #codes < count do
        if attempts <= 0 then
            return nil, "could not find enough unique codes"
        end
        attempts = attempts - 1
        local code = deriveCode(newLabel())
        local fp = sha.hash(code .. "|" .. (pepper or ""))
        if not data[fp] and not taken[fp] then
            taken[fp] = true
            codes[#codes + 1] = code
            pending[#pending + 1] = {
                fp = fp,
                code = code,
                rec = {
                    uses_total = uses,
                    uses_left = uses,
                    created = created,
                    note = note,
                    revoked = false,
                    reservations = {},
                },
            }
        end
    end
    return codes, pending
end

function M.commitBatch(pending)
    refresh()
    if type(pending) ~= "table" then
        return 0
    end
    local stored = 0
    for _, item in ipairs(pending) do
        if type(item) == "table" and type(item.fp) == "string" and
            type(item.rec) == "table" then
            data[item.fp] = item.rec
            stored = stored + 1
        end
    end
    save()
    return stored
end

function M.export(codes, path, meta)
    if type(codes) ~= "table" or #codes == 0 then
        return false, "nothing to export"
    end
    local dir = parentOf(path)
    if not ensureDir(dir) then
        return false, "cannot create " .. dir
    end
    local uses = (meta and meta.uses) or 1
    local note = (meta and meta.note) or ""
    local lines = {
        "# CardKey batch",
        "# generated: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "# count: " .. tostring(#codes),
        "# uses each: " .. tostring(uses),
        "# note: " .. tostring(note),
        "#",
        "# One key per line. Each key can be used " .. tostring(uses) .. " time(s).",
        "# Keep this file secret: anyone who reads it can use the keys.",
        "# Copy the keys off the server, then delete this file.",
        "",
    }
    for _, code in ipairs(codes) do
        lines[#lines + 1] = M.format(code) or code
    end
    local text = table.concat(lines, "\n") .. "\n"
    local wrote, why = writeFile(path, text)
    if not wrote then
        return false, why
    end
    if (fs.getSize(path) or -1) ~= #text then
        fs.delete(path)
        return false, "write truncated: " .. path
    end
    local check = readFile(path) or ""
    for _, code in ipairs(codes) do
        local formatted = M.format(code) or code
        if not check:find(formatted, 1, true) then
            fs.delete(path)
            return false, "verification failed: " .. path
        end
    end
    return true, path, #codes
end

function M.generate(count, uses, note)
    local codes, pending = M.mint(count, uses, note)
    if not codes then
        return nil, pending
    end
    local dir = tostring(cfg().export_dir or "/cardkeys")
    local stamp = os.date("%Y%m%d-%H%M%S")
    local path = dir .. "/cardkeys_" .. stamp .. ".txt"
    local suffix = 1
    while fs.exists(path) do
        suffix = suffix + 1
        path = dir .. "/cardkeys_" .. stamp .. "-" .. tostring(suffix) .. ".txt"
    end
    local latest = dir .. "/latest.txt"
    local meta = {uses = math.floor(uses), note = note}
    local ok, why = M.export(codes, path, meta)
    if not ok then
        return nil, why
    end
    ok, why = M.export(codes, latest, meta)
    if not ok then
        return nil, why
    end
    M.commitBatch(pending)
    return codes, path, latest
end

---------------------------------------------------------------------------
-- reporting and revocation
---------------------------------------------------------------------------

function M.list()
    refresh()
    local now = nowMs()
    local items = {}
    for fp, rec in pairs(data) do
        if type(rec) == "table" then
            items[#items + 1] = {
                fp = fp:sub(1, 12),
                uses_left = rec.uses_left or 0,
                uses_total = rec.uses_total or 0,
                held = liveReservations(rec, now),
                created = rec.created or 0,
                last_used = rec.last_used,
                note = rec.note or "",
                revoked = rec.revoked and true or false,
            }
        end
    end
    table.sort(items, function(a, b)
        if a.created ~= b.created then
            return a.created < b.created
        end
        return a.fp < b.fp
    end)
    return items
end

function M.stats()
    refresh()
    local now = nowMs()
    local st = {total = 0, alive = 0, exhausted = 0, revoked = 0, remaining = 0, held = 0}
    for _, rec in pairs(data) do
        if type(rec) == "table" then
            st.total = st.total + 1
            local left = rec.uses_left or 0
            st.remaining = st.remaining + left
            st.held = st.held + liveReservations(rec, now)
            if rec.revoked then
                st.revoked = st.revoked + 1
            end
            if left <= 0 then
                st.exhausted = st.exhausted + 1
            elseif not rec.revoked then
                st.alive = st.alive + 1
            end
        end
    end
    return st
end

function M.revoke(input)
    refresh()
    if type(input) ~= "string" then
        return false, "no match"
    end
    local norm = M.normalize(input)
    if norm then
        local fp = M.fingerprint(norm)
        local rec = data[fp]
        if type(rec) == "table" then
            rec.revoked = true
            save()
            return true, "revoked"
        end
    end
    local prefix = input:lower():gsub("%s+", "")
    if #prefix < 4 then
        return false, "prefix too short (min 4 chars)"
    end
    if not prefix:match("^[0-9a-f]+$") then
        return false, "no match"
    end
    local matches = {}
    for fp in pairs(data) do
        if fp:sub(1, #prefix) == prefix then
            matches[#matches + 1] = fp
        end
    end
    if #matches == 0 then
        return false, "no match"
    end
    if #matches > 1 then
        return false, "ambiguous prefix, " .. tostring(#matches) .. " matches"
    end
    if data[matches[1]] then
        data[matches[1]].revoked = true
        save()
        return true, "revoked"
    end
    return false, "no match"
end

function M.unrevoke(code)
    refresh()
    local norm = M.normalize(code)
    if not norm then
        return false, "invalid code format"
    end
    local fp = M.fingerprint(norm)
    local rec = data[fp]
    if type(rec) ~= "table" then
        return false, "no match (unrevoke needs the full code)"
    end
    rec.revoked = false
    save()
    return true, "restored"
end

return M
