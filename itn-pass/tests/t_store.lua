-- t_store.lua -- itnpass_store: pepper, fingerprints, reservation accounting.
--
-- Fixtures are real files under /auth, so every assertion goes through the same
-- read/write path the deployed server uses. A fake wall clock drives the
-- 300000 ms reservation TTL.

local DB = "/auth/itnpass_passes.db"
local PEPPER_PATH = "/auth/itnpass_pepper.txt"
local STORE = "/auth/itnpass_store.lua"
local CONFIG = "/auth/itnpass_config.lua"
local KEYS_DIR = "/cardkeys"

-- 48 characters, so loadPepper() keeps it verbatim.
local PEPPER = string.rep("Ab3", 16)
local sha = dofile("/sha256.lua")
local CODE = "23456789ABCDEFGH"

local function run(H)
    local function resetDb()
        if fs.exists(DB) then fs.delete(DB) end
        if fs.exists(PEPPER_PATH) then fs.delete(PEPPER_PATH) end
    end

    local function freshStore(pepper)
        if pepper then
            H.writeFile(PEPPER_PATH, pepper .. "\n")
        end
        return dofile(STORE)
    end

    local function record(fields)
        local rec = {
            uses_total = 2,
            uses_left = 2,
            created = 1000,
            note = "",
            revoked = false,
            reservations = {},
        }
        for k, v in pairs(fields or {}) do
            rec[k] = v
        end
        return rec
    end

    -- Writes a database keyed by explicit fingerprints (so the fixture is
    -- deterministic, independent of the code minting RNG).
    local function writeDb(entries)
        local t = {}
        for _, e in ipairs(entries) do
            t[e.fp] = e.rec
        end
        H.writeFile(DB, textutils.serialize(t))
    end

    local function fpOf(code)
        return sha.hash(code .. "|" .. PEPPER)
    end

    local function dbForCode(code, rec)
        writeDb({ { fp = fpOf(code), rec = rec } })
    end

    ------------------------------------------------------------------------
    -- normalize / format / fingerprint
    ------------------------------------------------------------------------
    H.group("store")
    resetDb()
    local store = freshStore(PEPPER)

    H.check("store.normalize_upper", store.normalize("23456789ABCDEFGH") == CODE,
        store.normalize("23456789ABCDEFGH"))
    H.check("store.normalize_lower", store.normalize("23456789abcdefgh") == CODE)
    H.check("store.normalize_hyphens",
        store.normalize("2345-6789-abcd-efgh") == CODE)
    H.check("store.normalize_spaces",
        store.normalize("  2345 6789 abcd efgh ") == CODE)
    H.check("store.normalize_short", store.normalize("23456789ABCDEFG") == nil)
    H.check("store.normalize_long", store.normalize("23456789ABCDEFGH2") == nil)
    H.check("store.normalize_bad_digit", store.normalize("23456789ABCDEFG0") == nil)
    H.check("store.normalize_bad_letter", store.normalize("23456789ABCDEFGI") == nil)
    H.check("store.normalize_empty", store.normalize("") == nil)
    H.check("store.normalize_nil", store.normalize(nil) == nil)
    H.check("store.normalize_table", store.normalize({}) == nil)
    H.check("store.format_groups_of_four",
        store.format(CODE) == "2345-6789-ABCD-EFGH", store.format(CODE))
    H.check("store.format_lowercase_input",
        store.format("2345-6789-abcd-efgh") == "2345-6789-ABCD-EFGH")
    H.check("store.format_invalid", store.format("bad") == nil)

    local fp = store.fingerprint(CODE)
    H.check("store.fingerprint_formula", fp == sha.hash(CODE .. "|" .. PEPPER))
    H.check("store.fingerprint_hex64",
        type(fp) == "string" and #fp == 64 and fp:match("^[0-9a-f]+$") ~= nil)
    H.check("store.fingerprint_normalizes",
        store.fingerprint("2345-6789-abcd-efgh") == fp)
    H.check("store.fingerprint_invalid", store.fingerprint("nope") == nil)
    H.check("store.fingerprint_uses_pepper",
        store.fingerprint(CODE) ~= sha.hash(CODE .. "|"))

    ------------------------------------------------------------------------
    -- pepper lifecycle
    ------------------------------------------------------------------------
    H.group("store.pepper")
    resetDb()
    local first = dofile(STORE)
    local raw = H.readFile(PEPPER_PATH)
    local bare = (raw or ""):gsub("%s+", "")
    H.check("store.pepper_file_created", raw ~= nil)
    H.check("store.pepper_len_48", #bare == 48, #bare)
    H.check("store.pepper_alnum", bare:match("^[A-Za-z0-9]+$") ~= nil, bare)
    H.check("store.pepper_ends_with_newline", (raw or ""):sub(-1) == "\n")

    local second = dofile(STORE)
    H.check("store.pepper_reused_across_boots",
        second.fingerprint(CODE) == first.fingerprint(CODE))
    H.check("store.pepper_file_untouched_by_second_boot",
        H.readFile(PEPPER_PATH) == raw)

    -- A hand written pepper is taken verbatim (only whitespace is stripped).
    resetDb()
    H.writeFile(PEPPER_PATH, PEPPER .. "\n")
    local known = dofile(STORE)
    H.check("store.pepper_from_file", known.fingerprint(CODE) == fpOf(CODE))

    ------------------------------------------------------------------------
    -- database boot, lookup, list, stats
    ------------------------------------------------------------------------
    H.group("store.db")
    resetDb()
    store = freshStore(PEPPER)
    H.check("store.empty_db_stats_total", store.stats().total == 0)
    H.check("store.empty_db_list", #store.list() == 0)
    H.check("store.empty_db_lookup", select(2, store.lookup(CODE)) == "unknown code")
    H.check("store.empty_db_prune_zero", store.prune() == 0)

    local codes, pending = store.mint(3, 2, "batch one")
    H.check("store.mint_count", codes ~= nil and #codes == 3)
    H.check("store.mint_pending_count", pending ~= nil and #pending == 3)
    H.check("store.mint_codes_unique",
        codes[1] ~= codes[2] and codes[2] ~= codes[3] and codes[1] ~= codes[3])
    H.check("store.mint_codes_are_valid",
        store.normalize(codes[1]) == codes[1] and store.normalize(codes[2]) == codes[2])
    H.check("store.mint_rec_defaults",
        pending[1].rec.uses_total == 2 and pending[1].rec.uses_left == 2
        and pending[1].rec.revoked == false
        and type(pending[1].rec.reservations) == "table")
    H.check("store.mint_rec_note", pending[1].rec.note == "batch one")
    H.check("store.mint_fp_matches", pending[1].fp == store.fingerprint(pending[1].code))
    H.check("store.mint_not_saved_before_commit",
        select(2, dofile(STORE).lookup(codes[1])) == "unknown code")

    local okCount, countReason = store.mint(0, 1)
    H.check("store.mint_count_zero_rejected", okCount == nil
        and countReason == "count must be >= 1", countReason)
    local okUses, usesReason = store.mint(1, 0)
    H.check("store.mint_uses_zero_rejected", okUses == nil
        and usesReason == "uses must be >= 1", usesReason)
    H.check("store.commit_batch_nil", store.commitBatch(nil) == 0)
    H.check("store.commit_batch_stores", store.commitBatch(pending) == 3)

    local stats = store.stats()
    H.check("store.stats_after_batch",
        stats.total == 3 and stats.alive == 3 and stats.remaining == 6
        and stats.exhausted == 0 and stats.revoked == 0 and stats.held == 0,
        textutils.serialize(stats))
    H.check("store.list_after_batch", #store.list() == 3)
    H.check("store.db_file_written", H.readFile(DB) ~= nil)

    local rec = store.lookup(codes[1])
    H.check("store.lookup_hit", rec ~= nil)
    H.check("store.lookup_reports_uses", rec.uses_left == 2 and rec.uses_total == 2)
    H.check("store.lookup_does_not_consume", select(2, store.lookup(codes[1])) == nil)
    H.check("store.lookup_formatted_code",
        select(1, store.lookup(store.format(codes[1]))) ~= nil)
    H.check("store.lookup_unknown_code", select(2, store.lookup(CODE)) == "unknown code")
    H.check("store.lookup_invalid_format", select(2, store.lookup("bad")) == "invalid code format")
    H.check("store.lookup_nil", select(2, store.lookup(nil)) == "invalid code format")
    H.check("store.lookup_returns_fp", select(3, store.lookup(codes[1])) == fpOf(codes[1]))

    -- Deterministic single-record fixtures: used up, revoked, held, stale hold.
    dbForCode(CODE, record({ uses_left = 0 }))
    H.check("store.lookup_used_up",
        select(2, freshStore(PEPPER).lookup(CODE)) == "used up")

    dbForCode(CODE, record({ revoked = true }))
    H.check("store.lookup_revoked",
        select(2, freshStore(PEPPER).lookup(CODE)) == "revoked")

    dbForCode(CODE, record({
        uses_left = 1,
        reservations = { other = H.now + 1000 },
    }))
    H.check("store.lookup_held_elsewhere",
        select(2, freshStore(PEPPER).lookup(CODE)) == "in use on another terminal")

    dbForCode(CODE, record({
        uses_left = 1,
        reservations = { stale = H.now - 1 },
    }))
    H.check("store.lookup_stale_hold_ignored",
        select(2, freshStore(PEPPER).lookup(CODE)) == nil)

    -- Records that are not tables are skipped rather than crashing.
    writeDb({ { fp = string.rep("f", 64), rec = "junk" } })
    local junkStore = freshStore(PEPPER)
    H.check("store.junk_record_stats", junkStore.stats().total == 0)
    H.check("store.junk_record_lookup_unknown",
        select(2, junkStore.lookup(CODE)) == "unknown code")

    ------------------------------------------------------------------------
    -- reserve / commit / release
    ------------------------------------------------------------------------
    H.group("store.reserve")
    resetDb()
    store = freshStore(PEPPER)
    codes, pending = store.mint(2, 2, "")
    store.commitBatch(pending)
    local code = codes[1]

    local grant = store.reserve(code, "res-A")
    H.check("store.reserve_granted", grant ~= nil)
    H.check("store.reserve_fields",
        grant.fp == fpOf(code) and grant.resId == "res-A"
        and grant.uses_total == 2 and grant.uses_left == 2
        and grant.held == 1 and grant.expires == H.now + 300000,
        textutils.serialize(grant or {}))
    H.check("store.reserve_missing_id",
        select(2, store.reserve(code, "")) == "missing reservation id")
    H.check("store.reserve_nil_id",
        select(2, store.reserve(code, nil)) == "missing reservation id")
    H.check("store.reserve_duplicate",
        select(2, store.reserve(code, "res-A")) == "duplicate request")
    H.check("store.reserve_unknown_code",
        select(2, store.reserve(CODE, "res-X")) == "unknown code")
    H.check("store.reserve_invalid_code",
        select(2, store.reserve("bad", "res-X")) == "invalid code format")

    -- Another copy of the module (the admin console runs its own) must see the
    -- reservation, which is how the two agents share the database.
    local other = dofile(STORE)
    local committed, charged = other.commit("res-A")
    H.check("store.commit_cross_instance_ok", committed ~= nil and charged == true)
    H.check("store.commit_charges_one_use", committed.uses_left == 1)
    H.check("store.commit_sets_last_used", committed.last_used == H.now)
    H.check("store.commit_clears_reservation",
        next(committed.reservations) == nil)
    H.check("store.commit_twice_rejected",
        select(2, other.commit("res-A")) == "no such reservation")
    H.check("store.commit_unknown_id",
        select(2, other.commit("no-such-res")) == "no such reservation")
    H.check("store.commit_persisted",
        select(1, dofile(STORE).lookup(code)).uses_left == 1)

    grant = store.reserve(codes[2], "res-B")
    H.check("store.reserve_second_key", grant ~= nil)
    H.check("store.release_ok", store.release("res-B") == true)
    H.check("store.release_unknown",
        select(2, store.release("res-B")) == "no such reservation")
    H.check("store.release_does_not_charge",
        select(1, store.lookup(codes[2])).uses_left == 2)
    H.check("store.release_allows_new_reservation",
        store.reserve(codes[2], "res-C") ~= nil)
    H.check("store.commit_after_release",
        select(2, store.commit("res-C")) == true)
    H.check("store.commit_after_release_charges_one",
        select(1, store.lookup(codes[2])).uses_left == 1)

    ------------------------------------------------------------------------
    -- reservation TTL
    ------------------------------------------------------------------------
    H.group("store.ttl")
    resetDb()
    store = freshStore(PEPPER)
    codes, pending = store.mint(1, 1, "")
    store.commitBatch(pending)

    local t0 = H.now
    grant = store.reserve(codes[1], "ttl-1")
    H.check("store.ttl_expiry_is_300000", grant.expires == t0 + 300000,
        grant.expires - t0)
    H.check("store.ttl_blocks_single_use_key",
        select(2, store.lookup(codes[1])) == "in use on another terminal")
    H.advance(299999)
    H.check("store.ttl_still_held_before_expiry",
        select(2, store.lookup(codes[1])) == "in use on another terminal")
    H.advance(2)
    H.check("store.ttl_released_after_expiry",
        select(2, store.lookup(codes[1])) == nil)
    H.check("store.ttl_commit_after_expiry",
        select(2, store.commit("ttl-1")) == "no such reservation")

    H.advance(0)
    H.check("store.ttl_reserve_again_after_expiry",
        store.reserve(codes[1], "ttl-2") ~= nil)
    H.advance(300001)
    -- release() honours the same expiry rule as commit(): the hold is already
    -- gone, so there is nothing left to release.
    local relOk, relWhy = store.release("ttl-2")
    H.check("store.ttl_release_expired_hold_returns_false",
        relOk == nil and relWhy == "no such reservation",
        tostring(relOk) .. "/" .. tostring(relWhy))
    H.check("store.ttl_release_expired_does_not_charge",
        select(1, store.lookup(codes[1])).uses_left == 1)

    -- The TTL is read from the config file, not hardcoded in the store.
    local confText = H.readFile(CONFIG) or ""
    H.writeFile(CONFIG, (confText:gsub("reservation_ttl_ms = 300000",
        "reservation_ttl_ms = 1234")))
    grant = store.reserve(codes[1], "ttl-3")
    H.check("store.ttl_from_config", grant ~= nil and grant.expires == H.now + 1234,
        grant and (grant.expires - H.now))
    -- A hold that has not expired is still released normally.
    H.check("store.ttl_release_live_hold_returns_true",
        store.release("ttl-3") == true)
    H.writeFile(CONFIG, confText)

    ------------------------------------------------------------------------
    -- prune
    ------------------------------------------------------------------------
    H.group("store.prune")
    resetDb()
    store = freshStore(PEPPER)
    codes, pending = store.mint(2, 2, "")
    store.commitBatch(pending)
    H.check("store.prune_reserve_one", store.reserve(codes[1], "p-1") ~= nil)
    H.check("store.prune_reserve_two", store.reserve(codes[2], "p-2") ~= nil)
    H.check("store.prune_keeps_live_holds", store.prune() == 0)
    H.advance(300001)
    H.check("store.prune_drops_expired_holds", store.prune() == 2)
    H.check("store.prune_second_pass_drops_nothing", store.prune() == 0)
    H.check("store.prune_removes_from_db",
        (H.readFile(DB) or ""):find("p-1", 1, true) == nil)
    H.check("store.prune_commit_after_prune",
        select(2, store.commit("p-1")) == "no such reservation")
    H.check("store.prune_frees_lookup", select(2, store.lookup(codes[1])) == nil)

    ------------------------------------------------------------------------
    -- revoke / unrevoke
    ------------------------------------------------------------------------
    H.group("store.revoke")
    resetDb()
    store = freshStore(PEPPER)
    codes, pending = store.mint(3, 2, "")
    store.commitBatch(pending)

    local okRevoke, revokeReason = store.revoke(codes[1])
    H.check("store.revoke_full_code", okRevoke == true and revokeReason == "revoked",
        revokeReason)
    H.check("store.revoke_blocks_lookup",
        select(2, store.lookup(codes[1])) == "revoked")
    H.check("store.revoke_formatted_code_accepted",
        select(1, store.revoke(store.format(codes[2]))) == true)
    H.check("store.revoke_by_fp_prefix",
        select(1, store.revoke(store.fingerprint(codes[3]):sub(1, 12))) == true)
    H.check("store.revoke_lookup_prefix_order",
        select(2, store.lookup(codes[3])) == "revoked")
    H.check("store.revoke_prefix_too_short",
        select(2, store.revoke("abc")) == "prefix too short (min 4 chars)")
    H.check("store.revoke_prefix_non_hex",
        select(2, store.revoke("zzzz")) == "no match")
    H.check("store.revoke_prefix_no_match",
        select(2, store.revoke("deadbeef")) == "no match")
    H.check("store.revoke_non_string",
        select(2, store.revoke(nil)) == "no match")

    H.check("store.unrevoke_full_code",
        select(1, store.unrevoke(codes[1])) == true)
    H.check("store.unrevoke_restores_lookup",
        select(2, store.lookup(codes[1])) == nil)
    H.check("store.unrevoke_reason",
        select(2, store.unrevoke(codes[1])) == "restored")
    H.check("store.unrevoke_invalid_code",
        select(2, store.unrevoke("bad")) == "invalid code format")
    H.check("store.unrevoke_needs_full_code",
        (select(2, store.unrevoke(CODE)) or ""):find("no match", 1, true) ~= nil)

    -- Two fingerprints sharing a prefix must be reported as ambiguous.
    writeDb({
        { fp = "abcd" .. string.rep("1", 60), rec = record({}) },
        { fp = "abcd" .. string.rep("2", 60), rec = record({}) },
    })
    local amb = freshStore(PEPPER)
    H.check("store.revoke_ambiguous_prefix",
        select(2, amb.revoke("abcd")) == "ambiguous prefix, 2 matches")
    H.check("store.revoke_ambiguous_nothing_changed",
        (#amb.list() == 2) and amb.list()[1].revoked == false)

    -- stats/list on a hand built mix: alive, exhausted, revoked.
    writeDb({
        { fp = "aaaa" .. string.rep("0", 60), rec = record({ uses_left = 2, created = 10 }) },
        { fp = "bbbb" .. string.rep("0", 60), rec = record({ uses_left = 0, created = 20 }) },
        { fp = "cccc" .. string.rep("0", 60), rec = record({ uses_left = 1, revoked = true, created = 30 }) },
    })
    local mixed = freshStore(PEPPER)
    local mixedStats = mixed.stats()
    H.check("store.stats_mixed_total", mixedStats.total == 3, mixedStats.total)
    H.check("store.stats_mixed_alive", mixedStats.alive == 1, mixedStats.alive)
    H.check("store.stats_mixed_exhausted", mixedStats.exhausted == 1,
        mixedStats.exhausted)
    H.check("store.stats_mixed_revoked", mixedStats.revoked == 1, mixedStats.revoked)
    H.check("store.stats_mixed_remaining", mixedStats.remaining == 3,
        mixedStats.remaining)
    local items = mixed.list()
    H.check("store.list_mixed_count", #items == 3)
    H.check("store.list_sorted_by_created",
        items[1].fp == "aaaa00000000" and items[2].fp == "bbbb00000000"
        and items[3].fp == "cccc00000000",
        items[1].fp .. "/" .. items[2].fp .. "/" .. items[3].fp)
    H.check("store.list_fp_prefix_len", #items[1].fp == 12)

    ------------------------------------------------------------------------
    -- export / generate
    ------------------------------------------------------------------------
    H.group("store.generate")
    resetDb()
    H.rmTree(KEYS_DIR)
    store = freshStore(PEPPER)

    H.check("store.export_empty_table",
        select(2, store.export({}, KEYS_DIR .. "/x.txt")) == "nothing to export")
    H.check("store.export_nil",
        select(2, store.export(nil, KEYS_DIR .. "/x.txt")) == "nothing to export")

    codes, pending = store.mint(2, 3, "note text")
    local wrote, path, exported = store.export(codes, KEYS_DIR .. "/batch.txt",
        { uses = 3, note = "note text" })
    H.check("store.export_ok", wrote == true and path == KEYS_DIR .. "/batch.txt"
        and exported == 2, tostring(path))
    local text = H.readFile(KEYS_DIR .. "/batch.txt") or ""
    H.check("store.export_header", text:find("# ITN-Pass batch", 1, true) ~= nil)
    H.check("store.export_count_line", text:find("# count: 2", 1, true) ~= nil)
    H.check("store.export_uses_line", text:find("# uses each: 3", 1, true) ~= nil)
    H.check("store.export_note_line", text:find("# note: note text", 1, true) ~= nil)
    H.check("store.export_lists_formatted_codes",
        text:find("\n" .. store.format(codes[1]) .. "\n", 1, true) ~= nil
        and text:find("\n" .. store.format(codes[2]) .. "\n", 1, true) ~= nil)
    local keyLines = 0
    for line in text:gmatch("[^\n]+") do
        if store.normalize(line) ~= nil then
            keyLines = keyLines + 1
        end
    end
    H.check("store.export_one_key_per_line", keyLines == 2, keyLines)

    H.stamp = "20260101-000000"
    local genCodes, genPath, genLatest = store.generate(2, 2, "gen note")
    H.check("store.generate_codes", genCodes ~= nil and #genCodes == 2)
    H.check("store.generate_path",
        genPath == KEYS_DIR .. "/cardkeys_20260101-000000.txt", tostring(genPath))
    H.check("store.generate_latest", genLatest == KEYS_DIR .. "/latest.txt")
    H.check("store.generate_files_exist",
        fs.exists(genPath) and fs.exists(genLatest))
    H.check("store.generate_stored",
        select(1, store.lookup(genCodes[1])) ~= nil)
    H.check("store.generate_uses",
        select(1, store.lookup(genCodes[1])).uses_left == 2)
    local genText = H.readFile(genLatest) or ""
    -- Export writes "4-4-4-4"; a key line must round-trip through normalize.
    local formatted = 0
    for line in genText:gmatch("[^\n]+") do
        local norm = store.normalize(line)
        if norm and store.format(norm) == line then
            formatted = formatted + 1
        end
    end
    H.check("store.generate_latest_has_formatted_keys", formatted == 2, formatted)

    local _, genPath2 = store.generate(1, 1, "")
    H.check("store.generate_same_second_suffix",
        genPath2 == KEYS_DIR .. "/cardkeys_20260101-000000-2.txt",
        tostring(genPath2))
    H.stamp = nil

    -- An export directory blocked by a regular file reports the reason.
    H.writeFile("/blocked", "not a directory")
    H.writeFile(CONFIG, ((H.readFile(CONFIG) or ""):gsub(
        'export_dir = "/cardkeys"', 'export_dir = "/blocked"')))
    local blockedCodes, blockedWhy
    blockedCodes, blockedWhy = store.generate(1, 1, "")
    H.check("store.generate_export_dir_blocked", blockedCodes == nil
        and blockedWhy == "cannot create /blocked", tostring(blockedWhy))
    H.writeFile(CONFIG, (H.readFile(CONFIG) or ""):gsub(
        'export_dir = "/blocked"', 'export_dir = "/cardkeys"'))
    fs.delete("/blocked")

    ------------------------------------------------------------------------
    -- corrupt / empty database tolerance
    ------------------------------------------------------------------------
    H.group("store.corrupt")
    resetDb()
    H.writeFile(DB, "this is not a serialized table")
    local broken = freshStore(PEPPER)
    H.check("store.corrupt_boot_survives", type(broken) == "table")
    H.check("store.corrupt_stats_empty", broken.stats().total == 0)
    H.check("store.corrupt_lookup_unknown",
        select(2, broken.lookup(CODE)) == "unknown code")
    H.check("store.corrupt_list_empty", #broken.list() == 0)
    H.check("store.corrupt_prune_zero", broken.prune() == 0)
    local repairedCodes, repairedPending = broken.mint(1, 1, "")
    H.check("store.corrupt_mint_still_works", repairedCodes ~= nil)
    H.check("store.corrupt_commit_rewrites_db",
        broken.commitBatch(repairedPending) == 1)
    H.check("store.corrupt_db_usable_after_save",
        select(1, dofile(STORE).lookup(repairedCodes[1])) ~= nil)

    resetDb()
    H.writeFile(DB, "")
    H.check("store.empty_file_stats", freshStore(PEPPER).stats().total == 0)

    resetDb()
    H.writeFile(DB, "return 5")
    H.check("store.scalar_db_ignored", freshStore(PEPPER).stats().total == 0)

    ------------------------------------------------------------------------
    -- unreadable database is preserved, not overwritten by the next save
    ------------------------------------------------------------------------
    H.group("store.corrupt_keep")
    local LOG = "/auth/itnpass_server.log"
    local CORRUPT_PREFIX = DB .. ".corrupt-"

    local function corruptBackups()
        local out = {}
        for _, name in ipairs(fs.list("/auth")) do
            if name:find("itnpass_passes.db.corrupt-", 1, true) == 1 then
                out[#out + 1] = "/auth/" .. name
            end
        end
        table.sort(out)
        return out
    end

    local function clearCorruptBackups()
        for _, path in ipairs(corruptBackups()) do
            fs.delete(path)
        end
    end

    resetDb()
    clearCorruptBackups()
    if fs.exists(LOG) then fs.delete(LOG) end
    local corruptText = "this is not a serialized table"
    local stamp = tostring(math.floor(H.now / 1000))
    H.writeFile(DB, corruptText)
    local recovered = freshStore(PEPPER)
    local backups = corruptBackups()
    H.check("store.corrupt_original_kept", #backups == 1, tostring(#backups))
    H.check("store.corrupt_original_name", backups[1] == CORRUPT_PREFIX .. stamp,
        tostring(backups[1]))
    H.check("store.corrupt_original_bytes",
        backups[1] ~= nil and H.readFile(backups[1]) == corruptText,
        tostring(backups[1] and (H.readFile(backups[1]) or ""):sub(1, 40)))
    H.check("store.corrupt_starts_empty", recovered.stats().total == 0)
    H.check("store.corrupt_log_line",
        (H.readFile(LOG) or ""):find("STORE_DB_CORRUPT", 1, true) ~= nil,
        (H.readFile(LOG) or ""):sub(1, 80))
    H.check("store.corrupt_fault_flagged",
        type(recovered.faults) == "function" and #recovered.faults() >= 1
        and recovered.faults()[1].code == "STORE_DB_CORRUPT")

    -- The next save must leave the preserved bytes alone.
    local rescueCodes, rescuePending = recovered.mint(1, 1, "")
    H.check("store.corrupt_save_still_works",
        rescueCodes ~= nil and recovered.commitBatch(rescuePending) == 1)
    H.check("store.corrupt_backup_survives_save",
        #corruptBackups() == 1 and H.readFile(backups[1]) == corruptText,
        tostring(#corruptBackups()))
    H.check("store.corrupt_new_db_readable",
        select(1, dofile(STORE).lookup(rescueCodes[1])) ~= nil)

    -- A second failure in the same second gets its own name.
    H.writeFile(DB, "garbage again")
    local twice = freshStore(PEPPER)
    local all = corruptBackups()
    H.check("store.corrupt_second_backup_saved", #all == 2, tostring(#all))
    H.check("store.corrupt_second_backup_suffix",
        all[2] == CORRUPT_PREFIX .. stamp .. "-1", tostring(all[2]))
    H.check("store.corrupt_second_backup_bytes",
        all[2] ~= nil and H.readFile(all[2]) == "garbage again")
    H.check("store.corrupt_first_backup_untouched",
        all[1] ~= nil and H.readFile(all[1]) == corruptText)
    H.check("store.corrupt_same_second_starts_empty", twice.stats().total == 0)
    clearCorruptBackups()

    ------------------------------------------------------------------------
    -- pepper rotation orphans fingerprints
    ------------------------------------------------------------------------
    H.group("store.rotation")
    resetDb()
    store = freshStore(PEPPER)
    codes, pending = store.mint(1, 2, "")
    store.commitBatch(pending)
    H.check("store.rotation_lookup_before_rotation",
        select(1, store.lookup(codes[1])) ~= nil)
    H.writeFile(PEPPER_PATH, string.rep("Zz9", 16) .. "\n")
    local rotated = dofile(STORE)
    H.check("store.rotation_orphans_fingerprint",
        select(2, rotated.lookup(codes[1])) == "unknown code")
    H.check("store.rotation_keeps_records", rotated.stats().total == 1)
    H.check("store.rotation_changes_fingerprint",
        rotated.fingerprint(codes[1]) ~= store.fingerprint(codes[1]))
end

return run
