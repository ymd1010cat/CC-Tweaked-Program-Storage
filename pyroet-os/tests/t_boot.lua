--[[- pyroet-os/tests/t_boot.lua -- single-tree bootloader: journal, rollback, commit.

Covers pyroet-os/P6-design.md sections 2, 4, 5 and 6 as behaviour, not as a
description: the 17-row decision table (plus the cross cases of section 9.1), the
two-generation journal, rollback driven by content hashes instead of progress
flags, the five rollback-failure paths of section 9.3 (each of which must leave
every file on disk for the operator), the 2.5 migration off the slot layout, and
the crash windows of section 5.1.

Fault injection is done with the instrumented fs from harness.lua, which
delegates to the real CraftOS fs unless a method is overridden.

No non-ASCII bytes in this file.
]]

local boot = dofile("/system/boot.lua")

return function(H)
    local F = H.real_fs()

    -- the real SHA-256, so nothing here depends on a test-only digest
    local CR = {}
    assert(loadfile("/system/rpv/crypto.lua"))(CR)
    local function sha(text) return CR.hex(CR.sha256(text)) end
    local function sha_of(path)
        local text = H.read(path)
        if text == nil then return nil end
        return sha(text)
    end

    local MANIFEST = "1111111111111111111111111111111111111111111111111111111111111111"
    local OTHER = "2222222222222222222222222222222222222222222222222222222222222222"

    local function case_root(name) return H.case_dir("boot", name) end

    -- a sandbox with one system tree
    local function system_dir(name)
        local dir = case_root(name)
        H.mkdirp(dir .. "/system")
        return dir
    end

    local function tree_file(dir, relpath, text)
        H.write(dir .. "/system/" .. relpath, text)
        return sha(text)
    end

    local function marker_line(version, manifest)
        return "PYROET-BOOT-OK-2 version=" .. version
            .. " manifest_sha=" .. manifest .. " ts=1700000000000"
    end

    local function committed(dir, version, manifest)
        H.write(dir .. "/boot.ok", marker_line(version or "1.0.0", manifest or MANIFEST))
    end

    local function journal(dir, seq, state, files, opts)
        local o = opts or {}
        local out = {
            "PYROET-UPD-JOURNAL-1",
            "seq=" .. tostring(seq),
            "state=" .. state,
            "version=" .. (o.version or "2.0.0"),
            "manifest_sha=" .. (o.manifest_sha or MANIFEST),
        }
        for i = 1, #files do
            local f = files[i]
            out[#out + 1] = f.relpath .. " " .. (f.old_sha or "-") .. " "
                .. f.new_sha .. " " .. tostring(f.bytes or 0)
        end
        local path = dir .. "/update.journal." .. tostring(seq)
        H.write(path, table.concat(out, "\n") .. "\n")
        return path
    end

    local function entry(relpath, old_sha, new_sha, bytes)
        return { relpath = relpath, old_sha = old_sha, new_sha = new_sha,
            bytes = bytes or 0 }
    end

    -- -----------------------------------------------------------------
    H.group("boot.no_system")
    do
        -- row 1: the one thing that is always fatal and never a reboot loop
        local dir = case_root("no_system")
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        local plan = b:begin()

        H.eq("action", plan.action, "fatal")
        H.eq("error", plan.error, "no_system")
        H.check("ok_false", plan.ok == false, "ok=" .. tostring(plan.ok))
        H.has(lines, "BOOT_NO_SYSTEM path=" .. dir .. "/system why=missing")
        H.has(lines, "BOOT_FATAL reason=no_system")
        H.has(lines, "BOOT_ACTION action=fatal")
        H.lacks("no_trial", lines, "BOOT_TRIAL")
        H.eq("no_marker", H.exists(dir .. "/boot.ok"), false)
        H.eq("no_tries", H.exists(dir .. "/boot.tries"), false)
        H.eq("describe", boot.describe(plan), "boot: fatal (no_system)")

        -- /system present but a file: still fatal, with its own reason
        local dir2 = case_root("system_is_file")
        H.write(dir2 .. "/system", "not a tree\n")
        local log2, lines2 = H.logger()
        local b2 = boot.new({ fs = F, root = dir2, log = log2 })
        local plan2 = b2:begin()
        H.eq("file_action", plan2.action, "fatal")
        H.eq("file_error", plan2.error, "no_system")
        H.has(lines2, "BOOT_NO_SYSTEM path=" .. dir2 .. "/system why=not_a_dir")
    end

    -- -----------------------------------------------------------------
    H.group("boot.normal")
    do
        -- row 3: steady state, tries are not touched at all
        local dir = system_dir("normal")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        committed(dir, "1.0.0", MANIFEST)
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        local plan = b:begin()

        H.eq("action", plan.action, "normal")
        H.eq("tries", plan.tries, 0)
        H.eq("marker_version", plan.marker and plan.marker.version, "1.0.0")
        H.eq("marker_manifest", plan.marker and plan.marker.manifest_sha, MANIFEST)
        H.has(lines, "BOOT_SYSTEM path=" .. dir .. "/system")
        H.has(lines, "BOOT_JOURNAL none")
        H.has(lines, "BOOT_MARKER version=1.0.0 manifest_sha=" .. MANIFEST:sub(1, 12))
        H.has(lines, "BOOT_NORMAL version=1.0.0")
        H.has(lines, "BOOT_ACTION action=normal tries=0")
        H.lacks("no_trial", lines, "BOOT_TRIAL")
        H.lacks("no_tries_write", lines, "BOOT_TRIES_PERSIST")
        H.eq("tries_untouched", H.read(dir .. "/boot.tries"), nil)
        H.eq("system_intact", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)
        H.eq("describe", boot.describe(plan), "boot: normal tries=0 version=1.0.0")
        H.eq("paths_system", b:paths().system, dir .. "/system")
        H.eq("system_path", b:system_path("kernel/ota.lua"), dir .. "/system/kernel/ota.lua")
        H.eq("journal_path", b:journal_path(7), dir .. "/update.journal.7")
    end

    -- -----------------------------------------------------------------
    H.group("boot.tries_stale")
    do
        -- row 6: a committed marker with a spent counter is a stale counter
        local dir = system_dir("tries_stale")
        tree_file(dir, "kernel/init.lua", "-- v1\n")
        committed(dir)
        H.write(dir .. "/boot.tries", "5")
        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()

        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_TRIES_STALE tries=5 max=2")
        H.has(lines, "BOOT_TRIES_RESET tries=0")
        H.eq("tries_reset_on_disk", H.read(dir .. "/boot.tries"), "0")
        H.eq("tries_reported", plan.tries, 0)
    end

    -- -----------------------------------------------------------------
    H.group("boot.trial")
    do
        -- row 5: a system with no credential gets exactly MAX_TRIES attempts,
        -- each one counted on disk BEFORE the system is entered
        local dir = system_dir("trial")
        local payload_sha = tree_file(dir, "kernel/init.lua", "-- first install\n")
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })

        local first = b:begin()
        H.eq("first_action", first.action, "trial")
        H.eq("first_tries", first.tries, 1)
        H.has(lines, "BOOT_TRIES_PERSIST tries=1")
        H.has(lines, "BOOT_TRIAL tries=1 max=2")
        H.has(lines, "BOOT_ACTION action=trial tries=1")
        H.eq("tries_on_disk_1", H.read(dir .. "/boot.tries"), "1")
        H.eq("tries_via_reader", boot.read_tries({ fs = F, root = dir }), 1)
        H.eq("no_marker_yet", H.read(dir .. "/boot.ok"), nil)
        H.eq("payload_untouched", sha_of(dir .. "/system/kernel/init.lua"), payload_sha)

        local second = b:begin()
        H.eq("second_action", second.action, "trial")
        H.eq("second_tries", second.tries, 2)
        H.eq("tries_on_disk_2", H.read(dir .. "/boot.tries"), "2")

        -- third attempt: the budget is gone and there is no journal, so there is
        -- nothing to roll back -- fatal, and the tree is left alone
        local third = b:begin()
        H.eq("third_action", third.action, "fatal")
        H.eq("third_error", third.error, "rollback_fail")
        H.has(lines, "BOOT_TRIES_EXCEEDED tries=3 max=2")
        H.has(lines, "BOOT_ROLLBACK_IMPOSSIBLE reason=no_journal")
        H.has(lines, "BOOT_ROLLBACK_FAIL seq=0 relpath=- want=- got=-")
        H.has(lines, "BOOT_FATAL reason=rollback_fail")
        H.has(lines, "FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
        H.eq("tries_on_disk_3", H.read(dir .. "/boot.tries"), "3")
        H.eq("payload_kept", sha_of(dir .. "/system/kernel/init.lua"), payload_sha)
        H.eq("describe_fatal", boot.describe(third), "boot: fatal (rollback_fail)")
    end

    -- -----------------------------------------------------------------
    H.group("boot.prepare")
    do
        -- row 4: the intent never reached the disk, the system was never touched
        local dir = system_dir("prepare_committed")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        committed(dir, "1.0.0", MANIFEST)
        local jpath = journal(dir, 1, "prepare", {
            entry("kernel/ota.lua", old_sha, OTHER, 7),
        })
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- old\n")

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_JOURNAL seq=1 state=prepare files=1")
        H.has(lines, "BOOT_JOURNAL_PREPARE_CLEAN seq=1")
        H.has(lines, "BOOT_CLEAN journal=1 backup=1")
        H.eq("journal_gone", H.exists(jpath), false)
        H.eq("backup_gone", H.exists(dir .. "/update.backup"), false)
        H.eq("system_kept", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)
        H.eq("marker_kept", H.read(dir .. "/boot.ok"), marker_line("1.0.0", MANIFEST))

        -- same journal, no credential: clean up, then trial the system
        local dir2 = system_dir("prepare_trial")
        tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        journal(dir2, 3, "prepare", {})
        local log2, lines2 = H.logger()
        local plan2 = boot.new({ fs = F, root = dir2, log = log2 }):begin()
        H.eq("trial_action", plan2.action, "trial")
        H.eq("trial_tries", plan2.tries, 1)
        H.has(lines2, "BOOT_JOURNAL_PREPARE_CLEAN seq=3")
        H.eq("trial_tries_disk", H.read(dir2 .. "/boot.tries"), "1")
        -- an empty file set is a valid journal (section 3.2 defines its hash)
        H.eq("empty_journal_gone", H.exists(dir2 .. "/update.journal.3"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.applying")
    do
        -- rows 7/8: half-applied by definition -- roll back before booting
        local dir = system_dir("applying_committed")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        H.write(dir .. "/system/kernel/ota.lua", "-- v2 new\n")
        local new_sha = sha_of(dir .. "/system/kernel/ota.lua")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        committed(dir, "1.0.0", MANIFEST)
        journal(dir, 4, "applying", { entry("kernel/ota.lua", old_sha, new_sha, 10) })

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_JOURNAL seq=4 state=applying files=1")
        H.has(lines, "BOOT_ROLLBACK seq=4 state=applying files=1 restored=1 deleted=0")
        H.has(lines, "BOOT_JOURNAL_ROLLEDBACK seq=5")
        H.has(lines, "BOOT_JOURNAL_WRITE seq=5 state=rolledback files=1")
        H.has(lines, "BOOT_CLEAN journal=2 backup=0")
        H.eq("old_bytes_restored", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)
        H.eq("backup_consumed", H.exists(dir .. "/update.backup"), false)
        H.eq("journal_gone", boot.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("marker_untouched", H.read(dir .. "/boot.ok"), marker_line("1.0.0", MANIFEST))

        -- same state, no credential: roll back, then trial the old version
        local dir2 = system_dir("applying_trial")
        local old2 = tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        H.write(dir2 .. "/system/kernel/ota.lua", "-- v2\n")
        local new2 = sha_of(dir2 .. "/system/kernel/ota.lua")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir2, 1, "applying", { entry("kernel/ota.lua", old2, new2, 6) })
        local log2, lines2 = H.logger()
        local plan2 = boot.new({ fs = F, root = dir2, log = log2 }):begin()
        H.eq("trial_action", plan2.action, "trial")
        H.eq("trial_tries", plan2.tries, 1)
        H.has(lines2, "BOOT_ROLLBACK seq=1 state=applying files=1 restored=1 deleted=0")
        H.eq("restored", sha_of(dir2 .. "/system/kernel/ota.lua"), old2)
        H.eq("tries_after", H.read(dir2 .. "/boot.tries"), "1")
    end

    -- -----------------------------------------------------------------
    H.group("boot.rollback_new_file")
    do
        -- old_sha = "-" (the update created the file): rolling back deletes it
        local dir = system_dir("new_file")
        tree_file(dir, "kernel/keep.lua", "-- keep\n")
        local add_sha = tree_file(dir, "kernel/added.lua", "-- added by the update\n")
        committed(dir)
        journal(dir, 2, "applying", { entry("kernel/added.lua", "-", add_sha, 23) })

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_ROLLBACK seq=2 state=applying files=1 restored=0 deleted=1")
        H.eq("added_gone", H.exists(dir .. "/system/kernel/added.lua"), false)
        H.eq("keep_kept", sha_of(dir .. "/system/kernel/keep.lua") ~= nil, true)
        H.eq("journal_gone", H.exists(dir .. "/update.journal.2"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.applying_multi")
    do
        -- two entries, one already back at old_sha: the hash is the progress
        -- marker, so only the second one is counted as restored
        local dir = system_dir("applying_multi")
        local a_old = tree_file(dir, "kernel/a.lua", "-- a1\n")
        tree_file(dir, "kernel/a.lua", "-- a1\n")
        local b_old = tree_file(dir, "kernel/b.lua", "-- b1\n")
        H.write(dir .. "/system/kernel/b.lua", "-- b2\n")
        local b_new = sha_of(dir .. "/system/kernel/b.lua")
        H.write(dir .. "/update.backup/kernel/b.lua", "-- b1\n")
        committed(dir)
        journal(dir, 8, "applying", {
            entry("kernel/a.lua", a_old, OTHER, 6),
            entry("kernel/b.lua", b_old, b_new, 6),
        })

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_ROLLBACK seq=8 state=applying files=2 restored=1 deleted=0")
        H.eq("a_is_old", sha_of(dir .. "/system/kernel/a.lua"), a_old)
        H.eq("b_is_old", sha_of(dir .. "/system/kernel/b.lua"), b_old)
        H.eq("no_journal", boot.journal_gens({ fs = F, root = dir })[1], nil)
    end

    -- -----------------------------------------------------------------
    H.group("boot.applied_committed")
    do
        -- row 10: the marker already proves this exact manifest, clean and boot
        local dir = system_dir("applied_committed")
        tree_file(dir, "kernel/ota.lua", "-- v1\n")
        local new_sha = tree_file(dir, "kernel/ota.lua", "-- v2\n")
        committed(dir, "2.0.0", MANIFEST)
        journal(dir, 6, "applied", { entry("kernel/ota.lua", OTHER, new_sha, 6) })
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        H.mkdirp(dir .. "/update.stage/kernel")
        H.write(dir .. "/update.stage/kernel/ota.lua.part", "half\n")

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_UPDATE_COMMITTED version=2.0.0 manifest_sha=" .. MANIFEST:sub(1, 12))
        H.has(lines, "BOOT_CLEAN journal=1 backup=1")
        H.lacks("no_rollback", lines, "BOOT_ROLLBACK ")
        H.eq("new_bytes_kept", sha_of(dir .. "/system/kernel/ota.lua"), new_sha)
        H.eq("backup_gone", H.exists(dir .. "/update.backup"), false)
        H.eq("stage_gone", H.exists(dir .. "/update.stage"), false)
        H.eq("journal_gone", H.exists(dir .. "/update.journal.6"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.version_mismatch")
    do
        -- row 17: version and manifest_sha disagree -- the hash wins
        local dir = system_dir("version_mismatch")
        local new_sha = tree_file(dir, "kernel/ota.lua", "-- v2\n")
        committed(dir, "1.9.9", MANIFEST)
        journal(dir, 9, "applied", { entry("kernel/ota.lua", OTHER, new_sha, 6) },
            { version = "2.0.0" })

        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_VERSION_MISMATCH marker=1.9.9 journal=2.0.0")
        H.has(lines, "BOOT_UPDATE_COMMITTED version=2.0.0")
        H.eq("bytes_kept", sha_of(dir .. "/system/kernel/ota.lua"), new_sha)
        H.eq("marker_not_rewritten", H.read(dir .. "/boot.ok"), marker_line("1.9.9", MANIFEST))
        H.eq("journal_gone", H.exists(dir .. "/update.journal.9"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.applied_uncommitted")
    do
        -- rows 11/12: applied but the marker is missing or different -> trial
        local dir = system_dir("applied_trial")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        H.write(dir .. "/system/kernel/ota.lua", "-- v2\n")
        local new_sha = sha_of(dir .. "/system/kernel/ota.lua")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        committed(dir, "1.0.0", OTHER)
        journal(dir, 2, "applied", { entry("kernel/ota.lua", old_sha, new_sha, 6) })
        local log, lines = H.logger()
        local first = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("trial_action", first.action, "trial")
        H.eq("trial_tries", first.tries, 1)
        H.has(lines, "BOOT_JOURNAL seq=2 state=applied files=1")
        H.has(lines, "BOOT_TRIAL tries=1 max=2")
        H.lacks("no_cleanup", lines, "BOOT_CLEAN")
        H.eq("journal_kept", H.exists(dir .. "/update.journal.2"), true)
        H.eq("new_bytes_on_trial", sha_of(dir .. "/system/kernel/ota.lua"), new_sha)
        H.eq("marker_kept", H.read(dir .. "/boot.ok"), marker_line("1.0.0", OTHER))

        -- no marker at all behaves the same (row 12)
        local dir2 = system_dir("applied_nomarker")
        local old2 = tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        H.write(dir2 .. "/system/kernel/ota.lua", "-- v2\n")
        local new2 = sha_of(dir2 .. "/system/kernel/ota.lua")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir2, 3, "applied", { entry("kernel/ota.lua", old2, new2, 6) })
        local plan2 = boot.new({ fs = F, root = dir2 }):begin()
        H.eq("nomarker_action", plan2.action, "trial")
        H.eq("nomarker_tries", plan2.tries, 1)

        -- third failed trial of the new image: roll back to the old bytes
        local dir3 = system_dir("applied_rollback")
        local old3 = tree_file(dir3, "kernel/ota.lua", "-- v1\n")
        H.write(dir3 .. "/system/kernel/ota.lua", "-- v2\n")
        local new3 = sha_of(dir3 .. "/system/kernel/ota.lua")
        H.write(dir3 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        committed(dir3, "1.0.0", OTHER)
        H.write(dir3 .. "/boot.tries", "2")
        journal(dir3, 7, "applied", { entry("kernel/ota.lua", old3, new3, 6) })
        local log3, lines3 = H.logger()
        local plan3 = boot.new({ fs = F, root = dir3, log = log3 }):begin()
        H.eq("rollback_action", plan3.action, "normal")
        H.has(lines3, "BOOT_TRIES_EXCEEDED tries=3 max=2")
        H.has(lines3, "BOOT_ROLLBACK seq=7 state=applied files=1 restored=1 deleted=0")
        H.eq("old_bytes_back", sha_of(dir3 .. "/system/kernel/ota.lua"), old3)
        H.eq("marker_still_old", H.read(dir3 .. "/boot.ok"), marker_line("1.0.0", OTHER))
        -- the rollback leaves the counter spent, so the stale-counter row runs
        H.has(lines3, "BOOT_TRIES_STALE tries=3 max=2")
        H.eq("tries_reset", H.read(dir3 .. "/boot.tries"), "0")
        H.eq("journal_gone", boot.journal_gens({ fs = F, root = dir3 })[1], nil)
    end

    -- -----------------------------------------------------------------
    H.group("boot.rolledback")
    do
        -- rows 15/16: the tombstone did its job -- drop it and boot what is there
        local dir = system_dir("rolledback_marker")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        committed(dir)
        journal(dir, 3, "rolledback", { entry("kernel/ota.lua", old_sha, OTHER, 6) })
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_JOURNAL_ROLLEDBACK seq=3")
        H.has(lines, "BOOT_CLEAN journal=1 backup=1")
        H.lacks("no_second_rollback", lines, "BOOT_ROLLBACK seq=")
        H.eq("journal_gone", H.exists(dir .. "/update.journal.3"), false)

        local dir2 = system_dir("rolledback_trial")
        tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        journal(dir2, 1, "rolledback", {})
        local plan2 = boot.new({ fs = F, root = dir2 }):begin()
        H.eq("trial_action", plan2.action, "trial")
        H.eq("trial_tries", plan2.tries, 1)
    end

    -- -----------------------------------------------------------------
    H.group("boot.journal_bad")
    do
        -- row 2: both generations unreadable and no rollback material -> treat
        -- the disk as "never updated"
        local dir = system_dir("journal_bad_none")
        tree_file(dir, "kernel/ota.lua", "-- v1\n")
        committed(dir)
        H.write(dir .. "/update.journal.2", "PYROET-UPD-JOURNAL-1\nseq=x\n")
        H.write(dir .. "/update.journal.1", "garbage\n")
        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_JOURNAL_UNREADABLE seq=2 why=bad_seq")
        H.has(lines, "BOOT_JOURNAL_UNREADABLE seq=1 why=bad_tag")
        H.has(lines, "BOOT_JOURNAL_BAD rollback=none")
        H.eq("journal_files_kept", H.exists(dir .. "/update.journal.2"), true)

        -- unreadable journal but backup material on disk: an update is there and
        -- cannot be described, which is a rollback failure (4.3 / section 9.3)
        local dir2 = system_dir("journal_bad_backup")
        tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        committed(dir2)
        H.write(dir2 .. "/update.journal.2", "not a journal\n")
        H.mkdirp(dir2 .. "/update.backup/kernel")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        local log2, lines2 = H.logger()
        local plan2 = boot.new({ fs = F, root = dir2, log = log2 }):begin()
        H.eq("bad_backup_action", plan2.action, "fatal")
        H.eq("bad_backup_error", plan2.error, "rollback_fail")
        H.has(lines2, "BOOT_JOURNAL_BAD rollback=required")
        H.has(lines2, "BOOT_ROLLBACK_FAIL seq=0 relpath=- want=- got=-")
        H.has(lines2, "FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
        H.eq("evidence_kept", H.exists(dir2 .. "/update.journal.2"), true)
        H.eq("backup_kept", H.exists(dir2 .. "/update.backup/kernel/ota.lua"), true)

        -- the newest generation is junk, the older one parses: 2.2 says use it
        local dir3 = system_dir("journal_fallback")
        tree_file(dir3, "kernel/ota.lua", "-- v1\n")
        committed(dir3)
        journal(dir3, 1, "prepare", {})
        H.write(dir3 .. "/update.journal.2", "PYROET-UPD-JOURNAL-1\nseq=2\nstate=nonsense\n")
        local log3, lines3 = H.logger()
        local plan3 = boot.new({ fs = F, root = dir3, log = log3 }):begin()
        H.eq("fallback_action", plan3.action, "normal")
        H.has(lines3, "BOOT_JOURNAL_UNREADABLE seq=2 why=bad_state")
        H.has(lines3, "BOOT_JOURNAL_PREPARE_CLEAN seq=1")
        H.eq("both_gens_cleaned", boot.journal_gens({ fs = F, root = dir3 })[1], nil)
    end

    -- -----------------------------------------------------------------
    H.group("boot.rollback_fail")
    do
        -- section 9.3: five ways a rollback cannot be proven. Each one has to be
        -- fatal, print the three grep-able lines, and keep every file on disk.
        local function fixture(name)
            local dir = system_dir(name)
            local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
            H.write(dir .. "/system/kernel/ota.lua", "-- v2\n")
            local new_sha = sha_of(dir .. "/system/kernel/ota.lua")
            journal(dir, 5, "applying", { entry("kernel/ota.lua", old_sha, new_sha, 6) },
                { manifest_sha = MANIFEST })
            return dir, old_sha, new_sha
        end

        local function expect_fail(lines, plan, name)
            H.eq(name .. "_action", plan.action, "fatal")
            H.eq(name .. "_error", plan.error, "rollback_fail")
            H.has(lines, "BOOT_ROLLBACK_FAIL seq=5 relpath=kernel/ota.lua")
            H.has(lines, "BOOT_FATAL reason=rollback_fail")
            H.has(lines, "FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
        end

        -- 1. the backup is not the old bytes
        local dir, old_sha, new_sha = fixture("fail_corrupt_backup")
        H.write(dir .. "/update.backup/kernel/ota.lua", "tampered\n")
        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        expect_fail(lines, plan, "corrupt")
        H.has(lines, "BOOT_ROLLBACK_FAIL seq=5 relpath=kernel/ota.lua want="
            .. old_sha:sub(1, 12) .. " got=" .. sha("tampered\n"):sub(1, 12))
        H.eq("corrupt_system_kept", sha_of(dir .. "/system/kernel/ota.lua"), new_sha)
        H.eq("corrupt_backup_kept", sha_of(dir .. "/update.backup/kernel/ota.lua"),
            sha("tampered\n"))
        H.eq("corrupt_journal_kept", H.exists(dir .. "/update.journal.5"), true)

        -- 2. no backup and the system file matches neither hash
        local dir2 = system_dir("fail_no_backup")
        tree_file(dir2, "kernel/ota.lua", "-- third party wrote this\n")
        journal(dir2, 5, "applying", {
            entry("kernel/ota.lua", sha("-- v1\n"), sha("-- v2\n"), 6),
        })
        local log2, lines2 = H.logger()
        local plan2 = boot.new({ fs = F, root = dir2, log = log2 }):begin()
        expect_fail(lines2, plan2, "missing")
        H.has(lines2, "BOOT_ROLLBACK_FAIL seq=5 relpath=kernel/ota.lua want="
            .. sha("-- v1\n"):sub(1, 12) .. " got=-")
        H.eq("missing_system_kept", sha_of(dir2 .. "/system/kernel/ota.lua"),
            sha("-- third party wrote this\n"))
        H.eq("missing_journal_kept", H.exists(dir2 .. "/update.journal.5"), true)

        -- 3. the backup exists but its content is a third thing
        local dir3 = system_dir("fail_backup_third")
        tree_file(dir3, "kernel/ota.lua", "-- v2\n")
        H.write(dir3 .. "/update.backup/kernel/ota.lua", "-- v3\n")
        journal(dir3, 5, "applying", {
            entry("kernel/ota.lua", sha("-- v1\n"), sha("-- v2\n"), 6),
        })
        local log3, lines3 = H.logger()
        local plan3 = boot.new({ fs = F, root = dir3, log = log3 }):begin()
        expect_fail(lines3, plan3, "third")
        H.has(lines3, "got=" .. sha("-- v3\n"):sub(1, 12))

        -- 4. the write back "works" but the bytes do not land: CC has no fsync,
        -- so a read-back mismatch is the only proof there is
        local dir4 = system_dir("fail_readback")
        tree_file(dir4, "kernel/ota.lua", "-- v2\n")
        H.write(dir4 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir4, 5, "applying", {
            entry("kernel/ota.lua", sha("-- v1\n"), sha("-- v2\n"), 6),
        })
        local proxy, calls = H.fs({
            overrides = {
                move = function(src, dst)
                    local handle = F.open(dst, "w")
                    handle.write("truncated")
                    handle.close()
                    pcall(F.delete, src)
                    return true
                end,
            },
        })
        local log4, lines4 = H.logger()
        local plan4 = boot.new({ fs = proxy, root = dir4, log = log4 }):begin()
        expect_fail(lines4, plan4, "readback")
        H.has(lines4, "BOOT_ROLLBACK_FAIL seq=5 relpath=kernel/ota.lua want="
            .. sha("-- v1\n"):sub(1, 12) .. " got=" .. sha("truncated"):sub(1, 12))
        H.check("move_used", H.calls_to(calls, "move") >= 1, "fs.move was never called")
        H.eq("readback_file_kept", H.read(dir4 .. "/system/kernel/ota.lua"), "truncated")
        H.eq("readback_journal_kept", H.exists(dir4 .. "/update.journal.5"), true)

        -- 5. move refuses and copy refuses: the restore itself cannot happen
        local dir5 = system_dir("fail_restore")
        tree_file(dir5, "kernel/ota.lua", "-- v2\n")
        H.write(dir5 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir5, 5, "applying", {
            entry("kernel/ota.lua", sha("-- v1\n"), sha("-- v2\n"), 6),
        })
        local proxy5 = H.fs({
            overrides = {
                move = function() return nil, "refused" end,
                copy = function() return nil, "refused" end,
            },
        })
        local log5, lines5 = H.logger()
        local plan5 = boot.new({ fs = proxy5, root = dir5, log = log5 }):begin()
        expect_fail(lines5, plan5, "restore")
        H.has(lines5, "BOOT_ROLLBACK_MOVE_FAIL path=kernel/ota.lua")
        H.has(lines5, "got=-")
    end

    -- -----------------------------------------------------------------
    H.group("boot.commit")
    do
        local dir = system_dir("commit")
        local payload = tree_file(dir, "kernel/ota.lua", "-- v2\n")
        committed(dir, "1.0.0", OTHER)
        H.write(dir .. "/boot.tries", "2")
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir, 2, "applied", { entry("kernel/ota.lua", OTHER, payload, 6) })
        journal(dir, 3, "applied", { entry("kernel/ota.lua", OTHER, payload, 6) })

        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        local ok, err = b:commit({ version = "2.0.0", manifest_sha = MANIFEST })
        H.check("commit_ok", ok == true, "err=" .. tostring(err))
        local marker = H.read(dir .. "/boot.ok")
        H.check("marker_exists", marker ~= nil, "no /boot.ok")
        H.ascii_check("marker_ascii", marker or "")
        H.check("marker_single_line", not (marker or ""):find("\n", 1, true),
            "marker has a newline")
        H.contains("marker_tag", marker, "PYROET-BOOT-OK-2")
        H.contains("marker_version", marker, "version=2.0.0")
        H.contains("marker_manifest", marker, "manifest_sha=" .. MANIFEST)
        H.match("marker_ts", marker, " ts=%d+$")
        H.has(lines, "BOOT_COMMIT version=2.0.0 manifest_sha=" .. MANIFEST:sub(1, 12))
        H.has(lines, "BOOT_TRIES_RESET tries=0")
        H.has(lines, "BOOT_CLEAN journal=2 backup=1")
        H.eq("tries_reset", H.read(dir .. "/boot.tries"), "0")
        H.eq("journal_gone", boot.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("backup_gone", H.exists(dir .. "/update.backup"), false)

        local parsed = boot.read_marker({ fs = F, root = dir })
        H.table("parsed", parsed)
        H.eq("parsed_version", parsed and parsed.version, "2.0.0")
        H.eq("parsed_manifest", parsed and parsed.manifest_sha, MANIFEST)
        H.check("parsed_ts_number", type(parsed and parsed.ts) == "number",
            "ts=" .. tostring(parsed and parsed.ts))
        H.eq("after_commit_normal", b:begin().action, "normal")

        -- a bad digest is recorded as none, never as evidence it is not
        H.check("bad_sha_ok", b:commit({ version = "2.0.1", manifest_sha = "xyz" }) == true)
        H.contains("bad_sha_none", H.read(dir .. "/boot.ok"), "manifest_sha=none")
        H.has(lines, "BOOT_SHA_INVALID value=xyz")

        -- no manifest at all is also "none"
        b:commit({ version = "2.0.2" })
        H.contains("missing_manifest_none", H.read(dir .. "/boot.ok"), "manifest_sha=none")

        -- a version with a newline must not split the marker line
        b:commit({ version = "2.0\nEVIL", manifest_sha = MANIFEST })
        local squashed = H.read(dir .. "/boot.ok") or ""
        H.check("version_sanitized", not squashed:find("\n", 1, true),
            "newline leaked into the marker")
        H.contains("version_sanitized_value", squashed, "version=2.0_EVIL")

        -- committing without a system tree fails loudly
        local empty = case_root("commit_no_system")
        local b2 = boot.new({ fs = F, root = empty })
        local ok2, err2 = b2:commit({ version = "9.9.9" })
        H.check("commit_missing_system", ok2 == nil and type(err2) == "string",
            "ok=" .. tostring(ok2))
        H.eq("commit_missing_error", err2, "system tree missing: " .. empty .. "/system")
        local log3, lines3 = H.logger()
        boot.commit({ version = "9.9.9" }, { fs = F, root = empty, log = log3 })
        H.has(lines3, "BOOT_COMMIT_FAIL reason=missing_system")
    end

    -- -----------------------------------------------------------------
    H.group("boot.marker_format")
    do
        -- a v1 marker is stale, not evidence: the system has to be trialled
        local dir = system_dir("marker_v1")
        tree_file(dir, "kernel/ota.lua", "-- v1\n")
        H.write(dir .. "/boot.ok",
            "PYROET-BOOT-OK-1 slot=a version=1.0.0 sha256=" .. MANIFEST .. " ts=1")
        local log, lines = H.logger()
        local plan = boot.new({ fs = F, root = dir, log = log }):begin()
        H.eq("action", plan.action, "trial")
        H.eq("tries", plan.tries, 1)
        H.has(lines, "BOOT_MARKER_STALE why=stale tag PYROET-BOOT-OK-1")

        local marker, why = boot.read_marker({ fs = F, root = dir })
        H.eq("read_v1", marker, nil)
        H.eq("read_v1_why", why, "stale tag PYROET-BOOT-OK-1")

        -- a v2 marker without manifest_sha is not a credential either
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 ts=1")
        H.eq("read_no_manifest", select(2, boot.read_marker({ fs = F, root = dir })),
            "missing manifest_sha")
        H.eq("read_missing", select(2, boot.read_marker({ fs = F, root = case_root("no_marker") })),
            "missing")

        -- trailing whitespace / extra fields are tolerated on the timestamp only
        H.write(dir .. "/boot.ok", marker_line("1.0.0", MANIFEST) .. "\r\n")
        local ok = boot.read_marker({ fs = F, root = dir })
        H.table("crlf_marker", ok)
        H.eq("crlf_manifest", ok and ok.manifest_sha, MANIFEST)
    end

    -- -----------------------------------------------------------------
    H.group("boot.journal_io")
    do
        -- every state change is a NEW generation: there is no in-place rewrite
        local dir = system_dir("journal_io")
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        local seq1 = b:write_journal({ state = "prepare", version = "2.0.0", files = {} })
        H.eq("first_seq", seq1, 1)
        H.eq("first_file", H.exists(dir .. "/update.journal.1"), true)
        local seq2 = b:write_journal({ seq = seq1 + 1, state = "applying", version = "2.0.0" })
        H.eq("second_seq", seq2, 2)
        H.eq("gens_count", table.concat(b:journal_gens(), ","), "2,1")

        -- two generations are kept, older ones are pruned
        b:write_journal({ seq = 3, state = "applied", version = "2.0.0" })
        H.eq("pruned_to_two", table.concat(b:journal_gens(), ","), "3,2")
        H.has(lines, "BOOT_JOURNAL_PRUNE seq=3 removed=1")
        H.eq("oldest_gone", H.exists(dir .. "/update.journal.1"), false)

        -- the newest generation is the one that counts
        local rec = b:read_journal()
        H.table("newest", rec)
        H.eq("newest_seq", rec and rec.seq, 3)
        H.eq("newest_state", rec and rec.state, "applied")

        -- a half-written journal can never be read: it is written to .tmp first
        -- and the .tmp name does not look like a journal
        local dir2 = system_dir("journal_tmp")
        H.write(dir2 .. "/update.journal.4.tmp", "PYROET-UPD-JOURNAL-1\nseq=4\n")
        local b2 = boot.new({ fs = F, root = dir2 })
        H.eq("tmp_not_counted", b2:journal_gens()[1], nil)
        H.eq("tmp_reason", select(2, b2:read_journal()), "none")

        -- writing the journal can fail; the caller has to see it
        local proxy = H.fs({
            overrides = {
                open = function(path, mode)
                    if type(path) == "string" and path:find("update.journal", 1, true) then
                        return nil
                    end
                    return F.open(path, mode)
                end,
            },
        })
        local log3, lines3 = H.logger()
        local b3 = boot.new({ fs = proxy, root = dir2, log = log3 })
        local bad, berr = b3:write_journal({ state = "prepare", version = "2.0.0" })
        H.check("write_fail", bad == nil and type(berr) == "string", "seq=" .. tostring(bad))
        H.has(lines3, "BOOT_WRITE_FAIL")
        H.has(lines3, "BOOT_JOURNAL_WRITE_FAIL")
        H.eq("no_partial_journal", b3:journal_gens()[1], nil)

        -- parse boundaries: every one of these is a bad generation, not a guess
        local dir3 = system_dir("journal_parse")
        local log4, lines4 = H.logger()
        local b4 = boot.new({ fs = F, root = dir3, log = log4 })
        local cases = {
            { "bad_tag", "not a journal\n" },
            { "unknown foo", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\nmanifest_sha=none\nfoo=bar\n" },
            { "duplicate seq", "PYROET-UPD-JOURNAL-1\nseq=1\nseq=2\nstate=prepare\nversion=1.0\nmanifest_sha=none\n" },
            { "bad_state", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=dancing\nversion=1.0\nmanifest_sha=none\n" },
            { "bad_version", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1/0\nmanifest_sha=none\n" },
            { "no_manifest_sha", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\n" },
            { "bad_manifest_sha", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\nmanifest_sha=zz\n" },
            { "bad_file_line", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\nmanifest_sha=none\nonly-one-token\n" },
            { "bad_old_sha", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\nmanifest_sha=none\na.lua xyz " .. MANIFEST .. " 3\n" },
            { "bad_new_sha", "PYROET-UPD-JOURNAL-1\nseq=1\nstate=prepare\nversion=1.0\nmanifest_sha=none\na.lua - zzz 3\n" },
        }
        for i = 1, #cases do
            H.write(dir3 .. "/update.journal." .. tostring(i), cases[i][2])
        end
        local why = select(2, b4:read_journal())
        H.eq("parse_all_bad", why, "bad")
        for i = 1, #cases do
            H.has(lines4, "BOOT_JOURNAL_UNREADABLE seq=" .. tostring(i)
                .. " why=" .. cases[i][1])
        end
        H.eq("no_gen_counted", b4:journal_gens()[1], #cases)
    end

    -- -----------------------------------------------------------------
    H.group("boot.migration")
    do
        -- 2.5: /boot.ok first, then the empty prepare journal, then the delete
        local dir = system_dir("migration")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        H.mkdirp(dir .. "/slots/a")
        H.write(dir .. "/slots/a/boot.ok",
            "PYROET-BOOT-OK-1 slot=a version=1.0.0 sha256=" .. MANIFEST .. " ts=1")
        H.write(dir .. "/slots/a/.image", "version=1.0.0\nsha256=" .. MANIFEST .. "\n")
        H.write(dir .. "/boot.slot", "a")
        H.write(dir .. "/boot.slot.tmp", "a")
        H.write(dir .. "/system.tmp", "residue\n")

        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        H.eq("legacy_before", table.concat(b:legacy(), ","),
            "boot.slot,boot.slot.tmp,slots,system.tmp")

        local plan = b:begin()
        H.eq("action", plan.action, "normal")
        H.has(lines, "BOOT_MIGRATED from=slots old=boot.slot,boot.slot.tmp,slots,system.tmp")
        H.has(lines, "BOOT_MIGRATE_DELETE name=boot.slot")
        H.has(lines, "BOOT_MIGRATE_DELETE name=slots")
        H.has(lines, "BOOT_MIGRATE_DONE")
        -- the same boot then cleans the empty prepare journal it just wrote
        H.has(lines, "BOOT_JOURNAL_PREPARE_CLEAN seq=1")
        H.eq("slots_gone", H.exists(dir .. "/slots"), false)
        H.eq("boot_slot_gone", H.exists(dir .. "/boot.slot"), false)
        H.eq("boot_slot_tmp_gone", H.exists(dir .. "/boot.slot.tmp"), false)
        H.eq("system_tmp_gone", H.exists(dir .. "/system.tmp"), false)
        H.eq("legacy_after", #b:legacy(), 0)
        H.eq("system_untouched", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)
        local marker = H.read(dir .. "/boot.ok")
        H.contains("marker_written", marker or "", "PYROET-BOOT-OK-2")
        H.contains("marker_none", marker or "", "manifest_sha=none")
        H.eq("no_journal_left", b:journal_gens()[1], nil)

        -- order: the credential and the intent are on disk before the delete
        local marker_at = H.index_of(lines, "BOOT_MARKER_WRITE")
        local journal_at = H.index_of(lines, "BOOT_JOURNAL_WRITE seq=1 state=prepare")
        local delete_at = H.index_of(lines, "BOOT_MIGRATE_DELETE name=boot.slot")
        H.check("credential_first", marker_at ~= nil and delete_at ~= nil
            and marker_at < delete_at, "marker=" .. tostring(marker_at)
            .. " delete=" .. tostring(delete_at))
        H.check("journal_before_delete", journal_at ~= nil and delete_at ~= nil
            and journal_at < delete_at, "journal=" .. tostring(journal_at)
            .. " delete=" .. tostring(delete_at))

        -- nothing to migrate: no marker is invented, no journal is written
        local dir2 = system_dir("no_migration")
        tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        local log2, lines2 = H.logger()
        boot.new({ fs = F, root = dir2, log = log2 }):begin()
        H.lacks("no_migrate_log", lines2, "BOOT_MIGRATED")
        H.eq("no_marker_invented", H.exists(dir2 .. "/boot.ok"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.crash_windows")
    do
        -- section 5.1: every one of these is a power cut at a different step of
        -- an update. The bootloader has to reach the old bytes, whatever is
        -- half-done, and the check is per-file SHA-256, not "it looks bootable".
        local old_text = "-- old payload\n"
        local old_sha = sha(old_text)

        -- a. journal(prepare) is on disk, no byte was touched
        local dir = system_dir("crash_prepare")
        tree_file(dir, "kernel/ota.lua", old_text)
        committed(dir, "1.0.0", MANIFEST)
        journal(dir, 1, "prepare", { entry("kernel/ota.lua", old_sha, OTHER, #old_text) })
        local plan = boot.new({ fs = F, root = dir }):begin()
        H.eq("prepare_action", plan.action, "normal")
        H.eq("prepare_bytes", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)

        -- b. crash between the backup move and the install: the system file is
        -- missing, the backup holds the old bytes
        local dir2 = system_dir("crash_mid_move")
        H.mkdirp(dir2 .. "/system/kernel")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", old_text)
        committed(dir2, "1.0.0", MANIFEST)
        journal(dir2, 2, "applying", { entry("kernel/ota.lua", old_sha, OTHER, #old_text) })
        local plan2 = boot.new({ fs = F, root = dir2 }):begin()
        H.eq("mid_move_action", plan2.action, "normal")
        H.eq("mid_move_bytes", sha_of(dir2 .. "/system/kernel/ota.lua"), old_sha)

        -- c. crash after the install, before the journal reached applied
        local dir3 = system_dir("crash_after_install")
        tree_file(dir3, "kernel/ota.lua", "-- new payload\n")
        H.write(dir3 .. "/update.backup/kernel/ota.lua", old_text)
        committed(dir3, "1.0.0", MANIFEST)
        journal(dir3, 3, "applying",
            { entry("kernel/ota.lua", old_sha, sha("-- new payload\n"), 15) })
        local plan3 = boot.new({ fs = F, root = dir3 }):begin()
        H.eq("after_install_action", plan3.action, "normal")
        H.eq("after_install_bytes", sha_of(dir3 .. "/system/kernel/ota.lua"), old_sha)

        -- d. crash after applied, before the kernel ever ran the new version
        local dir4 = system_dir("crash_after_applied")
        tree_file(dir4, "kernel/ota.lua", "-- new payload\n")
        H.write(dir4 .. "/update.backup/kernel/ota.lua", old_text)
        committed(dir4, "1.0.0", MANIFEST)
        journal(dir4, 4, "applied",
            { entry("kernel/ota.lua", old_sha, sha("-- new payload\n"), 15) },
            { manifest_sha = OTHER })
        local log4, lines4 = H.logger()
        local plan4 = boot.new({ fs = F, root = dir4, log = log4 }):begin()
        H.eq("after_applied_action", plan4.action, "trial")
        H.eq("after_applied_tries", plan4.tries, 1)
        H.has(lines4, "BOOT_TRIES_PERSIST tries=1")
        H.eq("new_bytes_on_trial", sha_of(dir4 .. "/system/kernel/ota.lua"),
            sha("-- new payload\n"))

        -- e. crash during the rewrite window: the newest generation is a .tmp
        local dir5 = system_dir("crash_journal_tmp")
        tree_file(dir5, "kernel/ota.lua", old_text)
        committed(dir5, "1.0.0", MANIFEST)
        journal(dir5, 1, "prepare", { entry("kernel/ota.lua", old_sha, OTHER, #old_text) })
        H.write(dir5 .. "/update.journal.2.tmp", "PYROET-UPD-JOURNAL-1\nseq=2\nstate=appl")
        local plan5 = boot.new({ fs = F, root = dir5 }):begin()
        H.eq("tmp_window_action", plan5.action, "normal")
        H.eq("tmp_window_bytes", sha_of(dir5 .. "/system/kernel/ota.lua"), old_sha)
        H.eq("tmp_cleaned", H.exists(dir5 .. "/update.journal.2.tmp"), false)
    end

    -- -----------------------------------------------------------------
    H.group("boot.rollback_api")
    do
        -- the rollback entry point on its own (ota calls it after a failed apply)
        local dir = system_dir("rollback_api")
        local old_sha = tree_file(dir, "kernel/ota.lua", "-- v1\n")
        H.write(dir .. "/system/kernel/ota.lua", "-- v2\n")
        local new_sha = sha_of(dir .. "/system/kernel/ota.lua")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        journal(dir, 2, "applying", { entry("kernel/ota.lua", old_sha, new_sha, 6) })
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        H.check("rollback_ok", b:rollback() == true, "rollback refused")
        H.eq("restored", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)
        H.has(lines, "BOOT_ROLLBACK seq=2 state=applying files=1 restored=1 deleted=0")
        H.eq("tombstone_state", b:read_journal().state, "rolledback")
        -- idempotent: a second call must not replay anything
        H.check("rollback_again", b:rollback() == true, "second rollback refused")
        H.has(lines, "BOOT_ROLLBACK_ALREADY")
        H.eq("still_old", sha_of(dir .. "/system/kernel/ota.lua"), old_sha)

        -- no journal at all: there is nothing to roll back and it must say so
        local dir2 = system_dir("rollback_none")
        tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        local log2, lines2 = H.logger()
        local ok2 = boot.new({ fs = F, root = dir2, log = log2 }):rollback()
        H.check("rollback_none_fails", ok2 == nil, "rollback without a journal succeeded")
        H.has(lines2, "BOOT_ROLLBACK_FAIL seq=0 relpath=- want=- got=-")
        H.has(lines2, "FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run")
    end

    -- -----------------------------------------------------------------
    H.group("boot.cleanup_api")
    do
        local dir = system_dir("cleanup")
        local log, lines = H.logger()
        local b = boot.new({ fs = F, root = dir, log = log })
        b:write_journal({ state = "prepare", version = "1.0.0" })
        H.mkdirp(dir .. "/update.backup/kernel")
        H.write(dir .. "/update.backup/kernel/ota.lua", "-- v1\n")
        H.mkdirp(dir .. "/update.stage/kernel")
        H.write(dir .. "/update.stage/kernel/ota.lua.part", "half\n")
        local journalled, backups = b:cleanup()
        H.eq("journal_removed", journalled, 1)
        H.eq("backup_counted", backups, 1)
        H.has(lines, "BOOT_CLEAN journal=1 backup=1")
        H.eq("journal_gone", H.exists(dir .. "/update.journal.1"), false)
        H.eq("backup_gone", H.exists(dir .. "/update.backup"), false)
        H.eq("stage_gone", H.exists(dir .. "/update.stage"), false)
        -- idempotent
        local again = b:cleanup()
        H.eq("clean_again", again, 0)
    end

    -- -----------------------------------------------------------------
    H.group("boot.tries_api")
    do
        local dir = case_root("tries_api")
        H.mkdirp(dir)
        local b = boot.new({ fs = F, root = dir })
        H.eq("default_zero", b:read_tries(), 0)
        H.eq("write_ok", b:write_tries(4), true)
        H.eq("written", H.read(dir .. "/boot.tries"), "4")
        H.eq("read_back", b:read_tries(), 4)
        H.write(dir .. "/boot.tries", "garbage\n")
        H.eq("garbage_zero", b:read_tries(), 0)
        H.write(dir .. "/boot.tries", "-4")
        H.eq("negative_zero", b:read_tries(), 0)
        H.write(dir .. "/boot.tries", "  7  ")
        H.eq("spaces_ok", b:read_tries(), 7)
        H.eq("write_negative_clamped", b:write_tries(-3), true)
        H.eq("clamped", H.read(dir .. "/boot.tries"), "0")
    end

    -- -----------------------------------------------------------------
    H.group("boot.guards")
    do
        local dir = system_dir("guards")
        local b = boot.new({ fs = F, root = dir })
        H.check("driver_begin", type(b.begin) == "function", "no begin")
        H.check("driver_commit", type(b.commit) == "function", "no commit")
        H.check("driver_journal", type(b.read_journal) == "function", "no read_journal")
        H.eq("journal_path_int", b:journal_path(9), dir .. "/update.journal.9")
        H.eq("system_path_nested", b:system_path("kernel/ota.lua"),
            dir .. "/system/kernel/ota.lua")
        H.check("describe_plan", boot.describe({ action = "trial", tries = 2 }),
            boot.describe({ action = "trial", tries = 2 }) == "boot: trial tries=2")
        H.eq("describe_nothing", boot.describe(nil), "boot: no plan")
        -- write_journal refuses an unknown state instead of writing it
        local ok, err = b:write_journal({ state = "dancing", version = "1.0" })
        H.check("bad_state", ok == nil and type(err) == "string", "state accepted")
        H.eq("bad_state_error", err, "bad state dancing")

        -- every log line the bootloader emits in a whole cycle must be ASCII
        local log, lines = H.logger()
        local dir2 = system_dir("ascii")
        local old_sha = tree_file(dir2, "kernel/ota.lua", "-- v1\n")
        H.write(dir2 .. "/system/kernel/ota.lua", "-- v2\n")
        H.write(dir2 .. "/update.backup/kernel/ota.lua", "-- v1\n")
        committed(dir2)
        journal(dir2, 1, "applying", { entry("kernel/ota.lua", old_sha, OTHER, 6) })
        local ascii = boot.new({ fs = F, root = dir2, log = log })
        ascii:begin()
        ascii:commit({ version = "2.0.0", manifest_sha = MANIFEST })
        H.ascii_check("log_ascii", H.joined(lines))
    end
end
