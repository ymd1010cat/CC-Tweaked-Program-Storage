-- t_profile.lua -- payload profiles end to end:
--   * the catalog (/itnpass_profile.lua) and its resolution order;
--   * the store quota binding (per-profile charging, unbound legacy records);
--   * the disk writer part selection and byte budget;
--   * the station service accepting profile / part on verify and write;
--   * the batch tool minting keys for one profile.

local function run(H)
    local PROFILE = "/itnpass_profile.lua"
    local OVERRIDE = "/auth/itnpass_profile.txt"
    local PLOG = "/auth/itnpass_profile.log"
    local CONFIG = "/auth/itnpass_config.lua"
    local DB = "/auth/itnpass_passes.db"
    local PEPPER_PATH = "/auth/itnpass_pepper.txt"
    local LOG = "/auth/itnpass_server.log"
    local STORE = "/auth/itnpass_store.lua"
    local BATCH = "/system/itnpass_batch.lua"
    local PEPPER = string.rep("Ab7", 16)

    local function readFile(path)
        return H.readFile(path) or ""
    end

    local function clearFile(path)
        if fs.exists(path) then
            fs.delete(path)
        end
    end

    ------------------------------------------------------------------------
    -- catalog
    ------------------------------------------------------------------------
    H.group("profile.catalog")
    local profiles = dofile(PROFILE)
    H.check("profile.default_name", profiles.DEFAULT == "default", profiles.DEFAULT)
    H.check("profile.floppy_capacity", profiles.CAPACITY_FLOPPY == 1228800,
        profiles.CAPACITY_FLOPPY)
    H.check("profile.computer_capacity", profiles.CAPACITY_COMPUTER == 1000000,
        profiles.CAPACITY_COMPUTER)
    local names = profiles.names()
    H.check("profile.names_count", #names == 3, #names)
    H.check("profile.names_sorted",
        names[1] == "default" and names[2] == "pyroet-os"
        and names[3] == "pyromputer-os", table.concat(names, ","))
    H.check("profile.names_line", profiles.names_line() ==
        "default, pyroet-os, pyromputer-os", profiles.names_line())
    H.check("profile.is_known_default", profiles.is_known("default") == true)
    H.check("profile.is_known_pyroet", profiles.is_known("pyroet-os") == true)
    H.check("profile.is_known_pyromputer", profiles.is_known("pyromputer-os") == true)
    H.check("profile.is_known_unknown", profiles.is_known("nope") == false)
    H.check("profile.is_known_nil", profiles.is_known(nil) == false)

    local pyroet = profiles.get("pyroet-os")
    H.check("profile.pyroet_media", pyroet ~= nil and pyroet.media == "floppy",
        pyroet and pyroet.media)
    H.check("profile.pyroet_transactions", pyroet.transactions == 1,
        pyroet.transactions)
    H.check("profile.pyroet_capacity", pyroet.capacity == 1228800, pyroet.capacity)
    H.check("profile.pyroet_uses", pyroet.default_uses == 1, pyroet.default_uses)
    H.check("profile.pyroet_single_tree", #profiles.parts("pyroet-os") == 0,
        #profiles.parts("pyroet-os"))

    local pyromputer = profiles.get("pyromputer-os")
    H.check("profile.pyromputer_transactions", pyromputer.transactions == 2,
        pyromputer.transactions)
    H.check("profile.pyromputer_uses", pyromputer.default_uses == 2,
        pyromputer.default_uses)
    local parts = profiles.parts("pyromputer-os")
    H.check("profile.pyromputer_parts",
        #parts == 2 and parts[1] == "part1" and parts[2] == "part2",
        table.concat(parts, ","))
    H.check("profile.pyromputer_part_capacity", pyromputer.capacity == 1228800,
        pyromputer.capacity)
    -- The 781,380 + 614,005 B layout from DECISIONS section 1.2 only works as
    -- two disks: the profile says two transactions and each part fits a floppy.
    H.check("profile.pyromputer_total_exceeds_floppy",
        781380 + 614005 > profiles.CAPACITY_FLOPPY)
    H.check("profile.pyromputer_part1_fits", 781380 <= profiles.CAPACITY_FLOPPY)
    H.check("profile.pyromputer_part2_fits", 614005 <= profiles.CAPACITY_FLOPPY)

    local fallback = profiles.get("default")
    H.check("profile.default_no_capacity", fallback.capacity == nil,
        tostring(fallback.capacity))
    H.check("profile.default_no_uses", fallback.default_uses == nil,
        tostring(fallback.default_uses))
    H.check("profile.unknown_entry", profiles.get("nope") == nil)
    H.check("profile.nil_entry", profiles.get(nil) == nil)

    H.check("profile.parse_ok", profiles.parse("pyroet-os") == "pyroet-os")
    H.check("profile.parse_trims", profiles.parse("  pyroet-os \n") == "pyroet-os")
    H.check("profile.parse_comment", profiles.parse("# the disk\npyroet-os\n") ==
        "pyroet-os")
    H.check("profile.parse_case_sensitive", profiles.parse("PYROET-OS") == nil)
    H.check("profile.parse_unknown", profiles.parse("nope") == nil)
    H.check("profile.parse_empty", profiles.parse("") == nil)
    H.check("profile.parse_blank_lines", profiles.parse("\n\n   \n") == nil)
    H.check("profile.parse_nil", profiles.parse(nil) == nil)
    H.check("profile.parse_number", profiles.parse(7) == nil)
    H.check("profile.parse_conflict",
        profiles.parse("pyroet-os\npyromputer-os\n") == nil)

    H.check("profile.capacity_catalog",
        profiles.capacity("pyroet-os", {}) == 1228800)
    H.check("profile.capacity_override",
        profiles.capacity("pyroet-os", {profile_capacity = {["pyroet-os"] = 99}}) == 99)
    H.check("profile.capacity_override_zero_ignored",
        profiles.capacity("pyroet-os", {profile_capacity = {["pyroet-os"] = 0}}) ==
        1228800)
    H.check("profile.capacity_default", profiles.capacity("default", {}) == nil)
    H.check("profile.capacity_unknown", profiles.capacity("nope", {}) == nil)
    H.check("profile.uses_pyroet", profiles.default_uses("pyroet-os") == 1)
    H.check("profile.uses_default", profiles.default_uses("default") == nil)

    -- The catalog is shared state: a caller mutating the copies it gets must
    -- not change what the next call returns.
    names[1] = "tampered"
    parts[1] = "tampered"
    H.check("profile.names_copy", profiles.names()[1] == "default")
    H.check("profile.parts_copy", profiles.parts("pyromputer-os")[1] == "part1")

    H.check("profile.summarize_short", profiles.summarize("  a\nb  ") == "a b")
    H.check("profile.summarize_truncated", #profiles.summarize(string.rep("x", 90)) == 40)

    ------------------------------------------------------------------------
    -- resolution order: profile file > config field > default
    ------------------------------------------------------------------------
    H.group("profile.resolve")
    clearFile(OVERRIDE)
    clearFile(PLOG)
    local name, source, problem = profiles.resolve({})
    H.check("profile.resolve_default", name == "default" and source == "default",
        tostring(name) .. "/" .. tostring(source))
    H.check("profile.resolve_default_no_problem", problem == nil)

    name, source = profiles.resolve({profile = "pyroet-os"})
    H.check("profile.resolve_config", name == "pyroet-os" and source == "config",
        tostring(name) .. "/" .. tostring(source))

    name, source, problem = profiles.resolve({profile = "PYROET-OS"})
    H.check("profile.resolve_config_bad_falls_back",
        name == "default" and source == "config_bad" and problem == "config_bad",
        tostring(name) .. "/" .. tostring(source))
    H.check("profile.resolve_config_bad_logged",
        readFile(PLOG):find("ITNP_CONFIG_BAD key=profile", 1, true) ~= nil,
        readFile(PLOG))

    clearFile(PLOG)
    H.writeFile(OVERRIDE, "# station profile\npyromputer-os\n")
    name, source = profiles.resolve({profile = "pyroet-os"})
    H.check("profile.resolve_file_wins",
        name == "pyromputer-os" and source == "file",
        tostring(name) .. "/" .. tostring(source))

    H.writeFile(OVERRIDE, "bogus-profile\n")
    name, source, problem = profiles.resolve({profile = "pyroet-os"})
    H.check("profile.resolve_file_bad_keeps_config",
        name == "pyroet-os" and source == "config" and problem == "file_bad",
        tostring(name) .. "/" .. tostring(source) .. "/" .. tostring(problem))
    H.check("profile.resolve_file_bad_logged",
        readFile(PLOG):find("ITNP_PROFILE_BAD path=" .. OVERRIDE, 1, true) ~= nil,
        readFile(PLOG))
    H.check("profile.resolve_file_bad_keep_value",
        readFile(PLOG):find("keep=pyroet-os", 1, true) ~= nil, readFile(PLOG))

    H.writeFile(OVERRIDE, "pyroet-os\n")
    name, source, problem = profiles.resolve({profile = "bogus"})
    H.check("profile.resolve_file_beats_config_bad",
        name == "pyroet-os" and source == "file" and problem == "config_bad",
        tostring(name) .. "/" .. tostring(source) .. "/" .. tostring(problem))

    -- current() reads the deployed config file; a hand-built table without the
    -- marker is resolved with the same priority.
    local configText = H.readFile(CONFIG) or ""
    clearFile(OVERRIDE)
    name, source = profiles.current()
    H.check("profile.current_default", name == "default" and source == "config",
        tostring(name) .. "/" .. tostring(source))
    H.writeFile(CONFIG, "return {profile = \"pyroet-os\"}\n")
    name, source = profiles.current()
    H.check("profile.current_from_config",
        name == "pyroet-os" and source == "config",
        tostring(name) .. "/" .. tostring(source))
    H.writeFile(CONFIG, "return {profile = \"pyroet-os\", profile_source = \"file\"}\n")
    name, source = profiles.current()
    H.check("profile.current_marker", name == "pyroet-os" and source == "file",
        tostring(name) .. "/" .. tostring(source))
    H.writeFile(CONFIG, configText)
    clearFile(OVERRIDE)
    clearFile(PLOG)

    -- The staged config carries the resolved profile and keeps the legacy
    -- shape by default.
    local conf = dofile(CONFIG)
    H.check("profile.config_default", conf.profile == "default", tostring(conf.profile))
    H.check("profile.config_source", conf.profile_source == "config",
        tostring(conf.profile_source))
    H.check("profile.config_capacity_empty",
        type(conf.profile_capacity) == "table" and next(conf.profile_capacity) == nil)

    ------------------------------------------------------------------------
    -- store: quota is charged per profile
    ------------------------------------------------------------------------
    H.group("profile.store")
    local function freshStore()
        clearFile(DB)
        clearFile(LOG)
        H.writeFile(PEPPER_PATH, PEPPER .. "\n")
        return dofile(STORE)
    end

    local store = freshStore()
    local codes, pending = store.mint(1, 2, "note", "pyroet-os")
    H.check("profile.store_mint_ok", codes ~= nil and #codes == 1)
    H.check("profile.store_commit_batch", store.commitBatch(pending) == 1)
    local code = codes[1]

    local st = store.stats()
    H.check("profile.store_stats_profiles",
        st.profiles ~= nil and st.profiles["pyroet-os"] ~= nil
        and st.profiles["pyroet-os"].total == 1, textutils.serialize(st.profiles or {}))
    H.check("profile.store_stats_profile_remaining",
        st.profiles["pyroet-os"].remaining == 2)
    H.check("profile.store_stats_unbound", st.unbound == 0, st.unbound)

    H.check("profile.store_lookup_bound_ok", store.lookup(code, "pyroet-os") ~= nil)
    local rec, why = store.lookup(code, "pyromputer-os")
    H.check("profile.store_lookup_other_profile", rec == nil and why == "profile mismatch",
        tostring(why))
    rec, why = store.lookup(code)
    H.check("profile.store_lookup_no_profile_is_default",
        rec == nil and why == "profile mismatch", tostring(why))

    local grant, whyReserve = store.reserve(code, "res-wrong", "pyromputer-os")
    H.check("profile.store_reserve_other_profile",
        grant == nil and whyReserve == "profile mismatch", tostring(whyReserve))
    H.check("profile.store_mismatch_charges_nothing",
        select(1, store.lookup(code, "pyroet-os")).uses_left == 2)
    H.check("profile.store_mismatch_leaves_no_hold",
        store.stats().held == 0, store.stats().held)

    -- A hold created for the right profile cannot be committed under another.
    grant = store.reserve(code, "res-right", "pyroet-os")
    H.check("profile.store_reserve_right_profile", grant ~= nil)
    rec, why = store.commit("res-right")
    H.check("profile.store_commit_other_profile",
        rec == nil and why == "profile mismatch", tostring(why))
    H.check("profile.store_commit_mismatch_keeps_uses",
        select(1, store.lookup(code, "pyroet-os")).uses_left == 2)
    local charged
    rec, charged = store.commit("res-right", "pyroet-os")
    H.check("profile.store_commit_right_profile", rec ~= nil and charged == true,
        tostring(charged))
    H.check("profile.store_charged_once",
        select(1, store.lookup(code, "pyroet-os")).uses_left == 1)

    -- A key minted without a profile keeps the old behaviour: it pays for any
    -- profile, which is how an old database and the console stay usable.
    local legacyCodes, legacyPending = store.mint(1, 1, "console")
    store.commitBatch(legacyPending)
    H.check("profile.store_legacy_lookup_any_profile",
        store.lookup(legacyCodes[1], "pyromputer-os") ~= nil)
    H.check("profile.store_legacy_unbound_count", store.stats().unbound == 1,
        store.stats().unbound)
    grant = store.reserve(legacyCodes[1], "res-legacy", "pyromputer-os")
    H.check("profile.store_legacy_reserve", grant ~= nil)
    H.check("profile.store_legacy_commit",
        select(1, store.commit("res-legacy", "pyromputer-os")) ~= nil)

    -- Cross profile: spending a pyromputer-os use leaves the pyroet-os quota
    -- untouched.
    local crossCodes, crossPending = store.mint(1, 1, "cross", "pyromputer-os")
    store.commitBatch(crossPending)
    local before = store.stats().profiles["pyroet-os"].remaining
    store.reserve(crossCodes[1], "res-cross", "pyromputer-os")
    store.commit("res-cross", "pyromputer-os")
    st = store.stats()
    H.check("profile.store_cross_untouched",
        st.profiles["pyroet-os"].remaining == before, tostring(before))
    H.check("profile.store_cross_spent", st.profiles["pyromputer-os"].remaining == 0,
        st.profiles["pyromputer-os"].remaining)

    -- An existing database written before profiles existed has no "profile"
    -- field: those records must stay readable and usable for every profile.
    local crafted = string.rep("2", 16)
    local probe = dofile(STORE)
    local craftedFp = probe.fingerprint(crafted)
    H.check("profile.store_legacy_fingerprint", craftedFp ~= nil)
    H.writeFile(DB, textutils.serialize({
        [craftedFp] = {
            uses_total = 2,
            uses_left = 2,
            created = 1600000000000,
            note = "",
            revoked = false,
            reservations = {},
        },
    }))
    local old = dofile(STORE)
    H.check("profile.store_old_db_lookup_default", old.lookup(crafted) ~= nil)
    H.check("profile.store_old_db_lookup_pyroet",
        old.lookup(crafted, "pyroet-os") ~= nil)
    H.check("profile.store_old_db_lookup_pyromputer",
        old.lookup(crafted, "pyromputer-os") ~= nil)
    local oldStats = old.stats()
    H.check("profile.store_old_db_unbound", oldStats.unbound == 1, oldStats.unbound)
    H.check("profile.store_old_db_no_profiles", next(oldStats.profiles) == nil)
    H.check("profile.store_old_db_reserve",
        old.reserve(crafted, "res-old", "pyroet-os") ~= nil)
    H.check("profile.store_old_db_commit",
        select(1, old.commit("res-old", "pyroet-os")) ~= nil)
    H.check("profile.store_old_db_charged",
        select(1, old.lookup(crafted, "pyromputer-os")).uses_left == 1)

    ------------------------------------------------------------------------
    -- disk writer: part selection and byte budget
    ------------------------------------------------------------------------
    H.group("profile.writer")
    clearFile(DB)
    clearFile(LOG)
    H.writeFile(PEPPER_PATH, PEPPER .. "\n")
    local writer = dofile("/system/disk_writer.lua")
    local configText = H.readFile(CONFIG) or ""
    local function setCapacity(text)
        H.writeFile(CONFIG, (H.readFile(CONFIG) or ""):gsub(
            "profile_capacity = {},", "profile_capacity = {" .. (text or "") .. "},"))
    end
    local function restoreConfig()
        H.writeFile(CONFIG, configText)
    end

    local function payloadReset(files)
        H.rmTree("/payload")
        fs.makeDir("/payload")
        for _, f in ipairs(files) do
            local path = "/payload/" .. f.rel
            local parent = path:match("^(.*)/[^/]+$")
            if parent ~= nil and parent ~= "" then
                H.ensureDir(parent)
            end
            H.writeFile(path, f.data)
        end
    end

    local function mountReset()
        H.rmTree("/disk")
        fs.makeDir("/disk")
    end

    local function ready()
        H.installPeripheral({ names = { "left" }, types = { left = "drive" } })
        H.installDisk({
            present = function() return true end,
            mount = function() return "/disk" end,
        })
        mountReset()
    end

    H.rmTree("/payload")
    local plan, why, detail = writer.plan()
    H.check("profile.writer_plan_no_payload",
        plan == nil and why == "no payload", tostring(why))
    H.check("profile.writer_plan_no_payload_detail",
        detail == "/payload is missing on the server", tostring(detail))

    fs.makeDir("/payload")
    plan, why = writer.plan()
    H.check("profile.writer_plan_empty_payload",
        plan == nil and why == "empty payload", tostring(why))
    fs.delete("/payload")

    payloadReset({ { rel = "a.txt", data = string.rep("A", 20) } })
    plan, why, detail = writer.plan("nope")
    H.check("profile.writer_plan_unknown_profile",
        plan == nil and why == "unknown profile", tostring(why))
    H.check("profile.writer_plan_unknown_profile_detail",
        tostring(detail):find("not one of:", 1, true) ~= nil, tostring(detail))

    plan = writer.plan("pyroet-os")
    H.check("profile.writer_plan_pyroet", plan ~= nil, tostring(plan))
    H.check("profile.writer_plan_pyroet_fields",
        plan and plan.profile == "pyroet-os" and plan.part == nil
        and plan.bytes == 20 and plan.capacity == 1228800
        and plan.source == "/payload", textutils.serialize(plan or {}))

    plan = writer.plan("pyroet-os", 1)
    H.check("profile.writer_plan_part_one_ok", plan ~= nil and plan.part == 1,
        plan and plan.part)
    plan, why = writer.plan("pyroet-os", 2)
    H.check("profile.writer_plan_single_tree_part_two",
        plan == nil and why == "bad part", tostring(why))
    plan, why = writer.plan("pyroet-os", "abc")
    H.check("profile.writer_plan_bad_part_word",
        plan == nil and why == "bad part", tostring(why))
    plan, why = writer.plan("pyroet-os", 0)
    H.check("profile.writer_plan_bad_part_zero",
        plan == nil and why == "bad part", tostring(why))
    plan, why = writer.plan("pyroet-os", 1.5)
    H.check("profile.writer_plan_bad_part_float",
        plan == nil and why == "bad part", tostring(why))

    -- Byte budget: the profile (or the config override on top of it) refuses an
    -- over-large payload before any disk is touched.
    setCapacity('["pyroet-os"] = 16')
    plan, why, detail = writer.plan("pyroet-os")
    H.check("profile.writer_plan_too_large",
        plan == nil and why == "payload too large", tostring(why))
    H.check("profile.writer_plan_too_large_detail",
        detail == "need 20 bytes, profile pyroet-os allows 16", tostring(detail))
    ready()
    local ok, reason, writeDetail = writer.write("pyroet-os")
    H.check("profile.writer_write_too_large",
        ok == false and reason == "payload too large", tostring(reason))
    H.check("profile.writer_write_too_large_detail",
        writeDetail == "need 20 bytes, profile pyroet-os allows 16",
        tostring(writeDetail))
    H.check("profile.writer_write_too_large_touches_nothing",
        #fs.list("/disk") == 0, textutils.serialize(fs.list("/disk")))
    restoreConfig()

    H.check("profile.writer_plan_restored_budget",
        writer.plan("pyroet-os") ~= nil)
    H.check("profile.writer_plan_default_has_no_budget",
        writer.plan("default") ~= nil and writer.plan("default").capacity == nil)

    -- Multi-part profile: the parts are the payload sub-directories.
    payloadReset({
        { rel = "part1/base.txt", data = "AAAA" },
        { rel = "part2/mods.txt", data = "BB" },
    })
    plan, why, detail = writer.plan("pyromputer-os")
    H.check("profile.writer_parts_ambiguous",
        plan == nil and why == "part required", tostring(why))
    H.check("profile.writer_parts_ambiguous_detail",
        tostring(detail):find("part1, part2", 1, true) ~= nil, tostring(detail))
    plan = writer.plan("pyromputer-os", 1)
    H.check("profile.writer_part1_source",
        plan ~= nil and plan.part == 1 and plan.source == "/payload/part1"
        and plan.bytes == 4, textutils.serialize(plan or {}))
    plan = writer.plan("pyromputer-os", 2)
    H.check("profile.writer_part2_source",
        plan ~= nil and plan.part == 2 and plan.source == "/payload/part2"
        and plan.bytes == 2, textutils.serialize(plan or {}))
    plan, why, detail = writer.plan("pyromputer-os", 3)
    H.check("profile.writer_part_out_of_range",
        plan == nil and why == "bad part", tostring(why))
    H.check("profile.writer_part_out_of_range_detail",
        detail == "profile pyromputer-os has 2 part(s), got 3", tostring(detail))
    setCapacity('["pyromputer-os"] = 3')
    plan, why, detail = writer.plan("pyromputer-os", 1)
    H.check("profile.writer_part_budget",
        plan == nil and why == "payload too large", tostring(why))
    H.check("profile.writer_part_budget_detail",
        detail == "need 4 bytes, profile pyromputer-os allows 3", tostring(detail))
    restoreConfig()

    -- With only one part on the payload disk the part is detected, which is how
    -- an operator writes disk 1, swaps the payload, then writes disk 2.
    H.rmTree("/payload/part1")
    plan = writer.plan("pyromputer-os")
    H.check("profile.writer_part_detected",
        plan ~= nil and plan.part == 2 and plan.source == "/payload/part2",
        textutils.serialize(plan or {}))

    ready()
    H.setFreeSpace(1000000)
    local wrote, info = writer.write("pyromputer-os", 2)
    H.check("profile.writer_write_part2_ok", wrote == true, tostring(info))
    H.check("profile.writer_write_part2_info",
        info ~= nil and info.profile == "pyromputer-os" and info.part == 2
        and info.bytes == 2 and info.files == 1
        and info.source == "/payload/part2", textutils.serialize(info or {}))
    H.check("profile.writer_write_part2_content",
        H.readFile("/disk/mods.txt") == "BB", H.readFile("/disk/mods.txt"))

    -- The pre-profile call shape still writes the payload root and reports no
    -- profile, so an old caller (and an old terminal) keeps working.
    payloadReset({ { rel = "flat.txt", data = "FLAT" } })
    ready()
    H.setFreeSpace(1000000)
    wrote, info = writer.write()
    H.check("profile.writer_legacy_ok", wrote == true, tostring(info))
    H.check("profile.writer_legacy_info",
        info ~= nil and info.profile == nil and info.part == nil
        and info.files == 1 and info.bytes == 4, textutils.serialize(info or {}))
    H.check("profile.writer_legacy_content", H.readFile("/disk/flat.txt") == "FLAT")

    ------------------------------------------------------------------------
    -- station service: profile and part on the wire
    ------------------------------------------------------------------------
    H.group("profile.server")
    local server = H.load("/system/itnpass_server.lua", "test")
    local function stationConf(overrides)
        local base = dofile(CONFIG)
        local out = {}
        for k, v in pairs(base) do out[k] = v end
        for k, v in pairs(overrides or {}) do out[k] = v end
        return out
    end

    local function fakeWriter()
        local w = { calls = 0, planCalls = 0, args = nil, planFail = nil }
        w.plan = function(profileName, part)
            w.planCalls = w.planCalls + 1
            if w.planFail ~= nil then
                return nil, w.planFail, "plan detail"
            end
            return {profile = profileName, part = part or 1, bytes = 9000}
        end
        w.write = function(profileName, part)
            w.calls = w.calls + 1
            w.args = {profileName, part}
            if w.writeFail ~= nil then
                return false, w.writeFail, "write detail"
            end
            return true, {files = 2, dirs = 1, bytes = 9000, part = part or 1}
        end
        return w
    end

    local seq = 0
    local function nonce(tag)
        seq = seq + 1
        return tostring(tag) .. "-" .. tostring(seq)
    end
    local function request(ctx, kind, fields)
        local msg = {protocol = "itnpass_v1", type = kind, terminal_id = "T-9"}
        for k, v in pairs(fields or {}) do msg[k] = v end
        return server.handleMessage(ctx, msg)
    end

    local sstore = freshStore()
    local scodes, spend = sstore.mint(1, 2, "srv", "pyroet-os")
    sstore.commitBatch(spend)
    local scode = scodes[1]
    local unboundCodes, unboundPending = sstore.mint(1, 1, "srv-free")
    sstore.commitBatch(unboundPending)

    local function ctxFor(w, overrides)
        return server.newContext(stationConf(overrides), sstore, w, "TEST-SRV")
    end

    clearFile(LOG)
    local ctx = ctxFor(fakeWriter())
    local reply = request(ctx, "verify_request", {nonce = nonce("v"), code = scode})
    H.check("profile.server_verify_station_default_mismatch",
        reply ~= nil and reply.success == false
        and reply.message == "profile mismatch",
        tostring(reply and reply.message))
    H.check("profile.server_verify_mismatch_logged",
        readFile(LOG):find("ITNP_DENY terminal=T-9 reason=profile mismatch", 1, true)
        ~= nil, readFile(LOG))

    reply = request(ctx, "verify_request",
        {nonce = nonce("v"), code = scode, profile = "nope"})
    H.check("profile.server_verify_unknown_profile",
        reply ~= nil and reply.success == false and reply.message == "unknown profile",
        tostring(reply and reply.message))
    H.check("profile.server_verify_unknown_profile_logged",
        readFile(LOG):find("reason=unknown profile", 1, true) ~= nil, readFile(LOG))

    reply = request(ctx, "verify_request",
        {nonce = nonce("v"), code = scode, profile = "pyroet-os"})
    H.check("profile.server_verify_request_profile",
        reply ~= nil and reply.success == true and reply.profile == "pyroet-os"
        and reply.uses_left == 2, textutils.serialize(reply or {}))
    H.check("profile.server_verify_request_profile_logged",
        readFile(LOG):find("ITNP_CHECK terminal=T-9 success=1 uses_left=2 profile=pyroet-os",
            1, true) ~= nil, readFile(LOG))

    local stationCtx = ctxFor(fakeWriter(), {profile = "pyroet-os"})
    reply = request(stationCtx, "verify_request", {nonce = nonce("v"), code = scode})
    H.check("profile.server_verify_station_profile",
        reply ~= nil and reply.success == true and reply.profile == "pyroet-os",
        textutils.serialize(reply or {}))
    reply = request(stationCtx, "verify_request",
        {nonce = nonce("v"), code = unboundCodes[1]})
    H.check("profile.server_verify_unbound_any_profile",
        reply ~= nil and reply.success == true, tostring(reply and reply.message))

    -- write: an unknown profile or an over-large payload must refuse without a
    -- reservation, without a disk write and without charging a use.
    clearFile(LOG)
    local w = fakeWriter()
    ctx = ctxFor(w)
    local usesBefore = select(1, sstore.lookup(scode, "pyroet-os")).uses_left
    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = scode, reservation_id = "p-1",
        profile = "nope",
    })
    H.check("profile.server_write_unknown_profile",
        reply ~= nil and reply.success == false and reply.message == "unknown profile",
        tostring(reply and reply.message))
    H.check("profile.server_write_unknown_profile_no_disk", w.calls == 0, w.calls)
    H.check("profile.server_write_unknown_profile_no_charge",
        select(1, sstore.lookup(scode, "pyroet-os")).uses_left == usesBefore)

    w = fakeWriter()
    w.planFail = "payload too large"
    ctx = ctxFor(w)
    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = scode, reservation_id = "p-2",
        profile = "pyroet-os",
    })
    H.check("profile.server_write_plan_refused",
        reply ~= nil and reply.success == false
        and reply.message == "payload too large", tostring(reply and reply.message))
    H.check("profile.server_write_plan_refused_detail",
        reply ~= nil and reply.detail == "plan detail", tostring(reply and reply.detail))
    H.check("profile.server_write_plan_refused_no_write", w.calls == 0, w.calls)
    H.check("profile.server_write_plan_refused_no_charge",
        select(1, sstore.lookup(scode, "pyroet-os")).uses_left == usesBefore)
    H.check("profile.server_write_plan_refused_logged",
        readFile(LOG):find("ITNP_DENY terminal=T-9 reason=payload too large", 1, true)
        ~= nil, readFile(LOG))

    w = fakeWriter()
    ctx = ctxFor(w)
    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = scode, reservation_id = "p-3",
        profile = "pyromputer-os",
    })
    H.check("profile.server_write_profile_mismatch",
        reply ~= nil and reply.success == false
        and reply.message == "profile mismatch", tostring(reply and reply.message))
    H.check("profile.server_write_mismatch_no_disk", w.calls == 0, w.calls)

    w = fakeWriter()
    ctx = ctxFor(w)
    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = scode, reservation_id = "p-4",
        profile = "pyroet-os",
    })
    H.check("profile.server_write_ok",
        reply ~= nil and reply.success == true and reply.charged == true,
        tostring(reply and reply.message))
    H.check("profile.server_write_reply_profile",
        reply ~= nil and reply.profile == "pyroet-os" and reply.part == 1,
        textutils.serialize(reply or {}))
    H.check("profile.server_write_writer_args",
        w.args ~= nil and w.args[1] == "pyroet-os" and w.args[2] == 1,
        textutils.serialize(w.args or {}))
    H.check("profile.server_write_charged",
        select(1, sstore.lookup(scode, "pyroet-os")).uses_left == usesBefore - 1)

    -- part is passed through and the auto-detected part from the plan wins.
    w = fakeWriter()
    ctx = ctxFor(w, {profile = "pyromputer-os"})
    local partCodes, partPending = sstore.mint(1, 2, "srv-part", "pyromputer-os")
    sstore.commitBatch(partPending)
    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = partCodes[1], reservation_id = "p-5", part = 2,
    })
    H.check("profile.server_write_part_reply",
        reply ~= nil and reply.success == true and reply.part == 2,
        textutils.serialize(reply or {}))
    H.check("profile.server_write_part_args",
        w.args ~= nil and w.args[1] == "pyromputer-os" and w.args[2] == 2,
        textutils.serialize(w.args or {}))
    H.check("profile.server_write_part_logged",
        readFile(LOG):find("ITNP_WRITE reservation=p-5", 1, true) ~= nil
        and readFile(LOG):find("part=2", 1, true) ~= nil, readFile(LOG))

    reply = request(ctx, "write_request", {
        nonce = nonce("w"), code = partCodes[1], reservation_id = "p-6", part = 9,
    })
    H.check("profile.server_write_bad_part_passes_through",
        reply ~= nil and w.args ~= nil and w.args[2] == 9,
        textutils.serialize(w.args or {}))

    -- free mode keeps the disk transaction but charges nothing; the profile
    -- still has to be valid because it selects the payload.
    H.group("profile.server_free")
    local freeStore = freshStore()
    local fw = fakeWriter()
    local fctx = server.newContext(stationConf({mode = "free"}), freeStore, fw,
        "TEST-SRV")
    reply = request(fctx, "write_request", {
        nonce = nonce("f"), code = "", reservation_id = "f-1", profile = "nope",
    })
    H.check("profile.server_free_unknown_profile",
        reply ~= nil and reply.success == false and reply.message == "unknown profile",
        tostring(reply and reply.message))
    H.check("profile.server_free_unknown_profile_no_write", fw.calls == 0, fw.calls)

    clearFile(LOG)
    reply = request(fctx, "write_request", {
        nonce = nonce("f"), code = "", reservation_id = "f-2", profile = "pyroet-os",
    })
    H.check("profile.server_free_write_ok",
        reply ~= nil and reply.success == true and reply.charged == false
        and reply.free == true, textutils.serialize(reply or {}))
    H.check("profile.server_free_write_profile",
        reply ~= nil and reply.profile == "pyroet-os", tostring(reply and reply.profile))
    H.check("profile.server_free_write_args",
        fw.args ~= nil and fw.args[1] == "pyroet-os", textutils.serialize(fw.args or {}))
    H.check("profile.server_free_write_logged",
        readFile(LOG):find("ITNP_FREE_WRITE ok=1 files=2 dirs=1 bytes=9000", 1, true)
        ~= nil and readFile(LOG):find("profile=pyroet-os", 1, true) ~= nil,
        readFile(LOG))

    ------------------------------------------------------------------------
    -- batch tool: minting for a profile
    ------------------------------------------------------------------------
    H.group("profile.batch")
    local tool = H.load(BATCH)
    local function resetBatch()
        clearFile(DB)
        clearFile(LOG)
        H.rmTree("/cardkeys")
        H.writeFile(PEPPER_PATH, PEPPER .. "\n")
        return dofile(STORE)
    end

    local function runCommand(...)
        H.beginCapture()
        local ok, err = tool.main({...})
        local text = H.endCapture()
        return text, ok, err
    end

    local bench = resetBatch()

    local function stagedCode(out)
        local path = out:match("staged=(%S+)")
        if path == nil then
            return nil
        end
        local text = H.readFile(path) or ""
        for line in text:gmatch("[^\n]+") do
            local code = bench.normalize(line)
            if code ~= nil then
                return code
            end
        end
        return nil
    end

    H.stamp = "20260301-000000"
    local out, ok = runCommand("new", "2", "--profile", "pyroet-os")
    H.check("profile.batch_new_ok", ok == true, out)
    H.check("profile.batch_new_profile_uses",
        out:find("uses=1", 1, true) ~= nil, out)
    H.check("profile.batch_new_profile_summary",
        out:find("profile=pyroet-os", 1, true) ~= nil, out)
    local st = bench.stats()
    H.check("profile.batch_new_bound_records",
        st.profiles["pyroet-os"] ~= nil and st.profiles["pyroet-os"].total == 2,
        textutils.serialize(st.profiles or {}))
    H.check("profile.batch_new_remaining",
        st.profiles["pyroet-os"].remaining == 2, st.profiles["pyroet-os"].remaining)
    local code = stagedCode(out)
    H.check("profile.batch_staged_code", code ~= nil, out)
    H.check("profile.batch_bound_lookup",
        code ~= nil and bench.lookup(code, "pyroet-os") ~= nil)
    H.check("profile.batch_bound_other_profile",
        code ~= nil and bench.lookup(code, "pyromputer-os") == nil)

    -- Without --profile the site default ("default") is used and the records are
    -- bound to it; the use count is the station's default_uses (2).
    bench = resetBatch()
    out, ok = runCommand("new", "1")
    H.check("profile.batch_default_ok", ok == true, out)
    H.check("profile.batch_default_profile",
        out:find("profile=default", 1, true) ~= nil, out)
    H.check("profile.batch_default_uses", out:find("uses=2", 1, true) ~= nil, out)
    st = bench.stats()
    H.check("profile.batch_default_bound",
        st.profiles["default"] ~= nil and st.profiles["default"].total == 1,
        textutils.serialize(st.profiles or {}))
    code = stagedCode(out)
    H.check("profile.batch_default_bound_lookup",
        code ~= nil and bench.lookup(code, "default") ~= nil)
    H.check("profile.batch_default_other_profile",
        code ~= nil and bench.lookup(code, "pyroet-os") == nil)

    -- The two-part profile mints two uses by default (one per disk).
    bench = resetBatch()
    out, ok = runCommand("new", "1", "--profile", "pyromputer-os")
    H.check("profile.batch_pyromputer_ok", ok == true, out)
    H.check("profile.batch_pyromputer_uses", out:find("uses=2", 1, true) ~= nil, out)
    H.check("profile.batch_pyromputer_stored",
        bench.stats().profiles["pyromputer-os"].remaining == 2)

    out, ok = runCommand("new", "1", "--profile", "nope-1")
    H.check("profile.batch_unknown_profile", ok == false
        and out:find("error=bad_profile", 1, true) ~= nil, out)
    H.check("profile.batch_unknown_profile_detail",
        out:find("unknown profile nope-1", 1, true) ~= nil, out)
    H.check("profile.batch_unknown_profile_known_list",
        out:find("known: default, pyroet-os, pyromputer-os", 1, true) ~= nil, out)
    H.check("profile.batch_unknown_profile_stores_nothing",
        bench.stats().total == 1, bench.stats().total)

    out, ok = runCommand("new", "1", "--profile", "bad profile")
    H.check("profile.batch_label_still_refused", ok == false
        and out:find("error=bad_profile", 1, true) ~= nil, out)

    out, ok = runCommand("new", "1", "--profile", "pyroet-os", "--uses", "5")
    H.check("profile.batch_uses_flag_wins", ok == true
        and out:find("uses=5", 1, true) ~= nil, out)

    H.check("profile.batch_usage_lists_profiles",
        tool.usage():find("profiles come from " .. tool.PROFILE_PATH, 1, true) ~= nil,
        tool.usage())
    H.check("profile.batch_usage_names",
        tool.usage():find("pyromputer-os", 1, true) ~= nil)
    H.stamp = nil
end

return run
