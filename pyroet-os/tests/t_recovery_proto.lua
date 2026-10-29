--[[- pyroet-os/tests/t_recovery_proto.lua -- recovery/proto.lua: PYROET-FLASH/2
framing, the canonical manifest digest, the single-tree target, the atomic
writer and the file-set transaction (stage -> prove -> apply -> journal).

No slot is involved anywhere any more. No non-ASCII bytes in this file.
]]

local P = dofile("/recovery/proto.lua")

return function(H)
    local F = H.real_fs()
    local SHA = P.sha({})
    local BODY = "0123456789"
    local DIGEST = P.dg(SHA, BODY)

    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end

    -- files: { { relpath, body }, ... } -> a parsed META plus its canonical sha
    local function file_list(files)
        local out = {}
        for i = 1, #files do
            out[i] = { relpath = files[i][1], size = #files[i][2], sha256 = P.dg(SHA, files[i][2]) }
        end
        return out
    end

    local function meta_msg(files, version)
        local list = file_list(files)
        local text = P.PREFIX .. " META version=" .. tostring(version or "1.0.0")
            .. " manifest_sha=" .. P.manifest_sha(SHA, list)
            .. " files=" .. tostring(#list)
        for i = 1, #list do
            text = text .. "\n" .. list[i].relpath .. " " .. tostring(list[i].size)
                .. " " .. list[i].sha256
        end
        return text, list
    end

    local function provider_for(bodies)
        return function(relpath, offset, want)
            local body = bodies[relpath]
            if body == nil then return nil, "missing" end
            return body:sub(offset + 1, offset + want)
        end
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.hash")
    do
        H.check("sha_loaded", type(SHA) == "function", "no SHA-256 from /system/rpv/crypto.lua")
        H.eq("digest_len", #DIGEST, 64)
        H.ascii_check("digest_ascii", DIGEST)
        H.eq("digest_hex_lower", P.dg(function() return "AABBCCDD" end, "x"), "aabbccdd")
        H.eq("digest_raw_to_hex", P.dg(function() return string.rep("A", 32) end, "x"),
            string.rep("41", 32))
        H.eq("check_ok", P.check(SHA, BODY, DIGEST), true)
        H.eq("check_bad", P.check(SHA, BODY .. "!", DIGEST), nil)
        H.eq("check_no_sha", P.check(nil, BODY, DIGEST), nil)
        H.eq("check_upper_accepted", P.check(SHA, BODY, DIGEST:upper()), true)
        H.eq("check_not_string", P.check(SHA, 42, DIGEST), nil)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.manifest")
    do
        local a = { relpath = "kernel/a.lua", size = 3, sha256 = string.rep("aa", 32) }
        local b = { relpath = "boot.lua", size = 5, sha256 = string.rep("bb", 32) }
        local text_ab = P.manifest({ a, b })
        local text_ba = P.manifest({ b, a })
        H.eq("manifest_sorted", text_ab, text_ba)
        H.contains("manifest_line_a", text_ab, "kernel/a.lua\0003\000" .. string.rep("aa", 32) .. "\n")
        H.eq("manifest_starts_smallest", text_ab:sub(1, 8), "boot.lua")
        H.eq("manifest_sha_order", P.manifest_sha(SHA, { a, b }), P.manifest_sha(SHA, { b, a }))
        H.eq("manifest_sha_empty", P.manifest({}), "")
        H.eq("manifest_sha_empty_digest", P.manifest_sha(SHA, {}), P.dg(SHA, ""))
        H.eq("manifest_sha_no_sha", P.manifest_sha(nil, { a }), nil)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.relpath")
    do
        H.eq("rel_plain", P.valid_relpath("kernel/ota.lua"), true)
        H.eq("rel_dotted", P.valid_relpath("system/net.app/main.lua"), true)
        H.eq("rel_empty", select(1, P.valid_relpath("")), nil)
        H.eq("rel_empty_why", select(2, P.valid_relpath("")), "empty")
        H.eq("rel_leading_slash", select(1, P.valid_relpath("/system/boot.lua")), nil)
        H.eq("rel_trailing_slash", select(1, P.valid_relpath("kernel/")), nil)
        H.eq("rel_double_slash", select(1, P.valid_relpath("a//b.lua")), nil)
        H.eq("rel_dotdot", select(2, P.valid_relpath("a/../b.lua")), "dotdot")
        H.eq("rel_hidden_segment", select(2, P.valid_relpath("a/.hidden")), "dot")
        H.eq("rel_space", select(2, P.valid_relpath("a b.lua")), "chars")
        H.eq("rel_non_ascii", select(2, P.valid_relpath("a\200b.lua")), "ascii")
        H.eq("rel_too_long", select(2, P.valid_relpath(string.rep("a", 97))), "length")
        H.eq("rel_96_ok", P.valid_relpath(string.rep("a", 96)), true)
        H.eq("rel_not_string", P.valid_relpath(42), nil)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.target")
    do
        local dir = H.case_dir("recovery-proto", "target")
        local missing, why, path = P.target(F, dir)
        H.eq("target_missing", missing, nil)
        H.eq("target_missing_why", why, "missing")
        H.eq("target_missing_path", path, dir .. "/system")
        H.mkdirp(dir .. "/system")
        local found = P.target(F, dir)
        H.eq("target_found", found, dir .. "/system")
        H.eq("target_root_default", P.target(F, ""), "/system")
        local file_dir = H.case_dir("recovery-proto", "target-file")
        H.write(file_dir .. "/system", "not a tree\n")
        local bad, bwhy = P.target(F, file_dir)
        H.eq("target_not_a_dir", bad, nil)
        H.eq("target_not_a_dir_why", bwhy, "not_a_dir")
        H.eq("stage_path", P.stage_path("/t/x"), "/t/x/update.stage")
        H.eq("backup_path", P.backup_path("/t/x"), "/t/x/update.backup")
        H.eq("stage_path_root", P.stage_path(""), "/update.stage")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.fs")
    do
        local dir = H.case_dir("recovery-proto", "fs")
        local file = dir .. "/a.txt"
        H.eq("read_missing", P.read(F, file), nil)
        H.write(file, "hello")
        H.eq("read_text", P.read(F, file), "hello")
        H.eq("atomic_new", P.atomic(F, dir .. "/b.txt", "one"), true)
        H.eq("atomic_new_body", H.read(dir .. "/b.txt"), "one")
        H.eq("atomic_replace", P.atomic(F, dir .. "/b.txt", "two"), true)
        H.eq("atomic_replace_body", H.read(dir .. "/b.txt"), "two")
        H.eq("atomic_tmp_gone", H.exists(dir .. "/b.txt.tmp"), false)
        H.eq("ensure_new", P.ensure_dir(F, dir .. "/deep/er/dir"), true)
        H.eq("ensure_exists", P.ensure_dir(F, dir), true)
        H.eq("ensure_root", P.ensure_dir(F, "/"), true)
        local proxy = H.fs({ overrides = { move = function() return false end } })
        H.write(dir .. "/c.txt", "old")
        local ok, err = P.atomic(proxy, dir .. "/c.txt", "new")
        H.eq("atomic_move_refused", ok, nil)
        H.eq("atomic_move_err", err, "move")
        H.eq("atomic_old_deleted", H.exists(dir .. "/c.txt"), false)
        local nop = H.fs({ overrides = { open = function() return nil end } })
        H.eq("atomic_open_fail", P.atomic(nop, dir .. "/d.txt", "x"), nil)
        H.eq("read_open_fail", P.read(nop, file), nil)
        H.write(dir .. "/e.txt", "x")
        H.eq("remove_existing", P.remove(F, dir .. "/e.txt"), true)
        H.eq("remove_gone", P.remove(F, dir .. "/e.txt"), true)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.parse_meta")
    do
        local msg = meta_msg({ { "kernel/a.lua", "aaa" }, { "boot.lua", "bbbbb" } }, "1.2.3")
        local m, err = P.meta(msg, SHA)
        H.table("meta", m)
        H.eq("meta_error", err, nil)
        H.eq("meta_version", m.version, "1.2.3")
        H.eq("meta_files", #m.files, 2)
        H.eq("meta_first_relpath", m.files[1].relpath, "kernel/a.lua")
        H.eq("meta_first_size", m.files[1].size, 3)
        H.eq("meta_first_sha", m.files[1].sha256, P.dg(SHA, "aaa"))
        H.eq("meta_manifest_sha", m.manifest_sha, P.manifest_sha(SHA, file_list({
            { "kernel/a.lua", "aaa" }, { "boot.lua", "bbbbb" } })))
        H.eq("meta_push", P.meta(P.PREFIX .. " PUSH meta version=2.0.0 manifest_sha="
            .. m.manifest_sha .. " files=0"), nil)
        H.eq("meta_nil", P.meta(nil), nil)
        H.eq("meta_not_string", P.meta(42), nil)
        H.eq("meta_prefix", P.meta("PYROET-FLASH/1 META version=1 files=1 manifest_sha="
            .. m.manifest_sha), nil)
        H.eq("meta_kind", P.meta(P.PREFIX .. " DATA kernel/a.lua idx=0 sha256="
            .. P.dg(SHA, "a") .. " 61"), nil)
        H.eq("meta_files_zero", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("files=1", "files=0"), SHA)), "files")
        H.eq("meta_files_bad", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("files=1", "files=x"), SHA)), "files")
        H.eq("meta_version_slash", select(2, P.meta(meta_msg({ { "a.lua", "a" } }, "1/2"), SHA)),
            "version")
        H.eq("meta_version_long", select(2, P.meta(meta_msg({ { "a.lua", "a" } },
            string.rep("v", 33)), SHA)), "version")
        H.eq("meta_sha_short", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("manifest_sha=%x+", "manifest_sha=abc"), SHA)), "manifest_sha")
        H.eq("meta_sha_mismatch", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("manifest_sha=%x+", "manifest_sha=" .. string.rep("0", 64)), SHA)),
            "manifest_sha_mismatch")
        H.eq("meta_count_mismatch", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("files=1(%s-)\n", "files=2\n"), SHA)), "count")
        H.eq("meta_bad_path", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("a%.lua %d+", "../a.lua 1"), SHA)), "path_dotdot")
        H.eq("meta_duplicate", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            .. "\na.lua 1 " .. P.dg(SHA, "a"), SHA)), "duplicate")
        H.eq("meta_zero_size", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("a%.lua 1", "a.lua 0"), SHA)), "size")
        H.eq("meta_huge_size", select(2, P.meta(meta_msg({ { "a.lua", "a" } })
            :gsub("a%.lua 1", "a.lua 65537"), SHA)), "size")
        H.eq("meta_no_sha_arg_skips_check", type(P.meta(meta_msg({ { "a.lua", "a" } }))), "table")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.parse_data")
    do
        local msg = P.PREFIX .. " DATA kernel/a.lua idx=2 sha256=" .. P.dg(SHA, "abcd")
            .. " " .. hex("abcd")
        local d, err = P.data(msg)
        H.table("data", d)
        H.eq("data_error", err, nil)
        H.eq("data_relpath", d.relpath, "kernel/a.lua")
        H.eq("data_idx", d.idx, 2)
        H.eq("data_body", d.data, "abcd")
        H.eq("data_sha", d.sha256, P.dg(SHA, "abcd"))
        H.eq("data_push", P.data(P.PREFIX .. " PUSH DATA boot.lua idx=0 sha256="
            .. P.dg(SHA, "x") .. " " .. hex("x")).data, "x")
        H.eq("data_nil", P.data(nil), nil)
        H.eq("data_kind", select(2, P.data(meta_msg({ { "a.lua", "a" } }))), "pkt")
        H.eq("data_no_idx", select(2, P.data(P.PREFIX .. " DATA a.lua sha256="
            .. P.dg(SHA, "a") .. " 61")), "fields")
        H.eq("data_short_sha", select(2, P.data(P.PREFIX .. " DATA a.lua idx=0 sha256=abc 61")),
            "sha256")
        H.eq("data_bad_hex", select(2, P.data(P.PREFIX .. " DATA a.lua idx=0 sha256="
            .. P.dg(SHA, "a") .. " zz")), "fields")
        H.eq("data_odd_hex", select(2, P.data(P.PREFIX .. " DATA a.lua idx=0 sha256="
            .. P.dg(SHA, "a") .. " 616")), "hex")
        H.eq("data_empty_payload", select(2, P.data(P.PREFIX .. " DATA a.lua idx=0 sha256="
            .. P.dg(SHA, "a") .. " ")), "size")
        H.eq("data_bad_path", select(2, P.data(P.PREFIX .. " DATA ../a.lua idx=0 sha256="
            .. P.dg(SHA, "a") .. " 61")), "path_dotdot")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.write_set")
    do
        local files = { { "kernel/a.lua", "old a\n" }, { "kernel/b.lua", "old b\n" } }
        local msg, list = meta_msg(files, "3.0.0")
        local parsed = assert(P.meta(msg, SHA))

        local dir = H.case_dir("recovery-proto", "write-ok")
        H.mkdirp(dir .. "/system/kernel")
        H.write(dir .. "/system/kernel/a.lua", "old a\n")
        H.write(dir .. "/system/kernel/b.lua", "old b\n")
        local new_bodies = { ["kernel/a.lua"] = "new a!\n", ["kernel/b.lua"] = "new b!\n" }
        local meta = assert(P.meta(meta_msg({
            { "kernel/a.lua", new_bodies["kernel/a.lua"] },
            { "kernel/b.lua", new_bodies["kernel/b.lua"] },
        }, "3.0.0"), SHA))
        local ok, stats = P.write_file_set(F, dir, meta, provider_for(new_bodies), SHA)
        H.eq("write_ok", ok, true)
        H.eq("write_files", stats.files, 2)
        H.eq("write_written", stats.written, 2)
        H.eq("write_skipped", stats.skipped, 0)
        H.eq("write_bytes", stats.bytes, #"new a!\n" + #"new b!\n")
        H.eq("write_version", stats.version, "3.0.0")
        H.eq("write_manifest", stats.manifest_sha, meta.manifest_sha)
        H.eq("write_first_body", H.read(dir .. "/system/kernel/a.lua"), "new a!\n")
        H.eq("write_second_body", H.read(dir .. "/system/kernel/b.lua"), "new b!\n")
        H.eq("write_old_backed_up_a", H.read(dir .. "/update.backup/kernel/a.lua"), "old a\n")
        H.eq("write_old_backed_up_b", H.read(dir .. "/update.backup/kernel/b.lua"), "old b\n")
        H.eq("write_stage_gone", H.exists(dir .. "/update.stage"), false)
        H.eq("write_journal_seq", stats.journal, 1)
        local journal = H.read(dir .. "/update.journal.1") or ""
        H.contains("journal_tag", journal, "PYROET-UPD-JOURNAL-1")
        H.contains("journal_state", journal, "state=applied")
        H.contains("journal_version", journal, "version=3.0.0")
        H.contains("journal_manifest", journal, "manifest_sha=" .. meta.manifest_sha)
        H.contains("journal_file_line", journal, "kernel/a.lua " .. P.dg(SHA, "old a\n")
            .. " " .. P.dg(SHA, "new a!\n") .. " " .. tostring(#new_bodies["kernel/a.lua"]))

        -- a second run is a no-op: every file already has the wanted digest
        local ok2, stats2 = P.write_file_set(F, dir, meta, provider_for(new_bodies), SHA)
        H.eq("write2_ok", ok2, true)
        H.eq("write2_written", stats2.written, 0)
        H.eq("write2_skipped", stats2.skipped, 2)
        H.eq("write2_backup_still_old", H.read(dir .. "/update.backup/kernel/a.lua"), "old a\n")
        H.eq("write2_journal_none", stats2.journal, nil)
        H.eq("write2_no_second_journal", H.exists(dir .. "/update.journal.2"), false)

        -- an added file has no backup, and the journal says old_sha = -
        local dir_add = H.case_dir("recovery-proto", "write-add")
        local add_bodies = { ["etc/new.conf"] = "x=1\n" }
        local add_meta = assert(P.meta(meta_msg({ { "etc/new.conf", "x=1\n" } }, "1.0.0"), SHA))
        local ok3, stats3 = P.write_file_set(F, dir_add, add_meta, provider_for(add_bodies), SHA)
        H.eq("write_add_ok", ok3, true)
        H.eq("write_add_body", H.read(dir_add .. "/system/etc/new.conf"), "x=1\n")
        H.eq("write_add_no_backup", H.exists(dir_add .. "/update.backup/etc/new.conf"), false)
        H.contains("write_add_journal", H.read(dir_add .. "/update.journal.1") or "",
            "etc/new.conf - " .. P.dg(SHA, "x=1\n") .. " 4")

        -- a chunk failure stops before /system is touched
        local dir_chunk = H.case_dir("recovery-proto", "write-chunk")
        H.mkdirp(dir_chunk .. "/system/kernel")
        H.write(dir_chunk .. "/system/kernel/a.lua", "old a\n")
        local meta_chunk = assert(P.meta(meta_msg({
            { "kernel/a.lua", "new a!\n" } }, "3.0.0"), SHA))
        local okc, stagec, errc = P.write_file_set(F, dir_chunk, meta_chunk,
            function() return nil, "boom" end, SHA)
        H.eq("write_chunk_fail", okc, nil)
        H.eq("write_chunk_stage", stagec, "stage")
        H.contains("write_chunk_err", errc, "boom")
        H.eq("write_chunk_system_kept", H.read(dir_chunk .. "/system/kernel/a.lua"), "old a\n")
        H.eq("write_chunk_stage_gone", H.exists(dir_chunk .. "/update.stage"), false)
        H.eq("write_chunk_no_journal", H.exists(dir_chunk .. "/update.journal.1"), false)

        -- a wrong digest stops at the same place
        local dir_digest = H.case_dir("recovery-proto", "write-digest")
        H.mkdirp(dir_digest .. "/system/kernel")
        H.write(dir_digest .. "/system/kernel/a.lua", "old a\n")
        local okd, staged, errd = P.write_file_set(F, dir_digest, meta_chunk,
            function() return string.rep("X", 7) end, SHA)
        H.eq("write_digest_fail", okd, nil)
        H.eq("write_digest_stage", staged, "stage")
        H.eq("write_digest_err", errd, "sha256")
        H.eq("write_digest_system_kept", H.read(dir_digest .. "/system/kernel/a.lua"), "old a\n")

        -- a manifest digest that does not describe the file lines is refused
        local bad_manifest = assert(P.meta(meta_msg({ { "kernel/a.lua", "new a!\n" } }, "3.0.0"), SHA))
        bad_manifest.manifest_sha = string.rep("0", 64)
        local okm, stagem, errm = P.write_file_set(F, dir_digest, bad_manifest,
            provider_for({ ["kernel/a.lua"] = "new a!\n" }), SHA)
        H.eq("write_manifest_fail", okm, nil)
        H.eq("write_manifest_stage", stagem, "manifest")
        H.eq("write_manifest_err", errm, "sha256")
        H.eq("write_manifest_system_kept", H.read(dir_digest .. "/system/kernel/a.lua"), "old a\n")

        -- an apply failure rolls the already applied files back by hash
        local dir_apply = H.case_dir("recovery-proto", "write-apply")
        H.mkdirp(dir_apply .. "/system/kernel")
        H.write(dir_apply .. "/system/kernel/a.lua", "old a\n")
        H.write(dir_apply .. "/system/kernel/b.lua", "old b\n")
        local meta_apply = assert(P.meta(meta_msg({
            { "kernel/a.lua", "new a!\n" },
            { "kernel/b.lua", "new b!\n" },
        }, "3.0.0"), SHA))
        local real = H.real_fs()
        local moves = 0
        local flaky = H.fs({ overrides = { move = function(a, b)
            if b:find("system/kernel/b.lua", 1, true) then
                moves = moves + 1
                if moves == 1 then return false end
            end
            return real.move(a, b)
        end } })
        local oka, stagea, erra = P.write_file_set(flaky, dir_apply, meta_apply,
            provider_for({ ["kernel/a.lua"] = "new a!\n", ["kernel/b.lua"] = "new b!\n" }), SHA)
        H.eq("write_apply_fail", oka, nil)
        H.eq("write_apply_stage", stagea, "apply")
        H.contains("write_apply_err", erra, "rolled_back")
        H.eq("write_apply_a_restored", H.read(dir_apply .. "/system/kernel/a.lua"), "old a\n")
        H.eq("write_apply_b_kept", H.read(dir_apply .. "/system/kernel/b.lua"), "old b\n")
        H.eq("write_apply_no_new_a", P.dg(SHA, H.read(dir_apply .. "/system/kernel/a.lua")),
            P.dg(SHA, "old a\n"))
        H.eq("write_apply_stage_gone", H.exists(dir_apply .. "/update.stage"), false)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.proto.fetch")
    do
        local function scripted(items, sent)
            local i = 0
            return {
                send = function(host, msg) sent[#sent + 1] = msg; return true end,
                receive = function()
                    i = i + 1
                    local item = items[i]
                    if item == "raise" then error("modem gone") end
                    if item == nil then return nil end
                    return item[1], item[2]
                end,
            }
        end
        local GOOD = meta_msg({ { "kernel/a.lua", "aaa" } })
        local sent = {}
        local net = scripted({ { 12, GOOD } }, sent)
        local meta = P.fetch(net, 12, function() return P.PREFIX .. " GET meta" end,
            function(msg) return P.meta(msg, SHA) end, { max_tries = 3 })
        H.eq("fetch_ok", meta and meta.version, "1.0.0")
        H.eq("fetch_sent", #sent, 1)
        H.eq("fetch_request", sent[1], P.PREFIX .. " GET meta")

        sent = {}
        net = scripted({ { 12, P.PREFIX .. " META nonsense" }, { 12, GOOD } }, sent)
        meta = P.fetch(net, 12, function() return "q" end,
            function(msg) return P.meta(msg, SHA) end, { max_tries = 3 })
        H.eq("fetch_retry", meta and meta.version, "1.0.0")
        H.eq("fetch_retry_sends", #sent, 2)

        sent = {}
        net = scripted({}, sent)
        local m2, err = P.fetch(net, 12, function() return "q" end, P.meta, { max_tries = 2 })
        H.eq("fetch_timeout", m2, nil)
        H.eq("fetch_timeout_err", err, "timeout")
        H.eq("fetch_timeout_sends", #sent, 2)

        sent = {}
        net = scripted({ "raise", "raise", "raise" }, sent)
        local m3, err3 = P.fetch(net, 12, function() return "q" end, P.meta, { max_tries = 3 })
        H.eq("fetch_dead_modem", m3, nil)
        H.eq("fetch_dead_err", err3, "recv")

        sent = {}
        net = scripted({ { 99, GOOD }, { 12, GOOD } }, sent)
        meta = P.fetch(net, 12, function() return "q" end,
            function(msg) return P.meta(msg, SHA) end, { max_tries = 3 })
        H.eq("fetch_peer_filtered", meta and meta.version, "1.0.0")
        H.eq("fetch_peer_sends", #sent, 2)

        local badSend = { send = function() error("nope") end, receive = function() return nil end }
        local m4, err4 = P.fetch(badSend, 1, function() return "q" end, P.meta, { max_tries = 1 })
        H.eq("fetch_send_fail", m4, nil)
        H.eq("fetch_send_err", err4, "send")
        H.eq("fetch_no_rednet", P.fetch(nil, 1, function() return "q" end, P.meta), nil)
    end
end
