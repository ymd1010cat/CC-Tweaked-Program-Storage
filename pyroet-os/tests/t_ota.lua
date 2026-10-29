--[[- pyroet-os/tests/t_ota.lua -- PYROET-OTA/2 file-set updates, download and apply.

Covers pyroet-os/P6-design.md section 3 (the wire format and its boundaries),
5.1/5.2 (the order of a file's a-h steps and the three journal write points) and
7 (BACKUP_CAP). The peer is a fake rednet server built in this file: it speaks
the protocol from a list of (relpath, bytes) pairs and can drop, corrupt or lie
about any packet, which is how the retry and rejection paths are driven without
a network.

The three things every rejection case asserts are the same three that matter on
a real machine: /system is byte-identical, no journal exists, and the client is
left in a state that can be retried.

No non-ASCII bytes in this file.
]]

local OTA = dofile("/system/kernel/ota.lua")
local BOOT = dofile("/system/boot.lua")

return function(H)
    local F = H.real_fs()

    local CR = {}
    assert(loadfile("/system/rpv/crypto.lua"))(CR)
    local function sha(text) return CR.hex(CR.sha256(text)) end
    local function sha_of(path)
        local text = H.read(path)
        if text == nil then return nil end
        return sha(text)
    end
    local function hex_of(text) return CR.hex(text) end

    local PREFIX = OTA.PREFIX

    -- -----------------------------------------------------------------
    -- the fake distribution server
    -- -----------------------------------------------------------------
    local function peer(files, opts)
        local o = opts or {}
        local p = { sent = {}, host = o.host or 12 }
        local recs = {}
        for i = 1, #files do
            local f = files[i]
            recs[i] = {
                relpath = f.relpath,
                data = f.data,
                size = f.size or #f.data,
                sha256 = (f.sha or sha(f.data)):lower(),
            }
        end
        local manifest = (o.manifest or OTA.manifest_hash(recs, CR.sha256)):lower()
        local drop_meta = o.drop_meta or 0
        local drop_data = o.drop_data or 0
        local corrupt = o.corrupt_data or 0
        local wrong_relpath = o.wrong_relpath or 0
        local pending = nil

        local function build(msg)
            local body = msg:sub(#PREFIX + 2)
            local verb, a, b = body:match("^(%S+)%s*(%S*)%s*(%S*)$")
            if verb ~= "GET" then return nil end
            if a == "meta" then
                if drop_meta > 0 then
                    drop_meta = drop_meta - 1
                    return nil
                end
                local line = PREFIX .. " META version=" .. (o.version or "0.6.0")
                    .. " files=" .. tostring(#files)
                    .. " manifest_sha=" .. manifest
                if o.meta_extra then line = line .. " " .. o.meta_extra end
                return line
            end
            local idx = tonumber(a)
            if not idx or idx < 0 or idx >= #files then return nil end
            local rec = recs[idx + 1]
            if b == "" then
                local size = rec.size
                if o.file_size and o.file_size[idx] then size = o.file_size[idx] end
                local digest = rec.sha256
                if o.bad_file_sha and o.bad_file_sha[idx] then digest = o.bad_file_sha[idx] end
                local path = rec.relpath
                if o.bad_file_path and o.bad_file_path[idx] then path = o.bad_file_path[idx] end
                return PREFIX .. " FILE " .. path .. " " .. tostring(size) .. " " .. digest
            end
            local offset = tonumber(b)
            if not offset then return nil end
            if drop_data > 0 then
                drop_data = drop_data - 1
                return nil
            end
            local chunk = rec.data:sub(offset + 1, offset + (o.max_data or OTA.MAX_DATA))
            if corrupt > 0 then
                corrupt = corrupt - 1
                chunk = string.rep("Z", #chunk)
            end
            local path = rec.relpath
            if wrong_relpath > 0 then
                wrong_relpath = wrong_relpath - 1
                path = "kernel/bogus.lua"
            end
            return PREFIX .. " DATA " .. path .. " " .. tostring(offset) .. " " .. hex_of(chunk)
        end

        p.rednet = {
            send = function(host, msg, protocol)
                if host ~= p.host then return end
                p.sent[#p.sent + 1] = msg
                pending = build(msg)
                return true
            end,
            receive = function(protocol, timeout)
                local msg = pending
                pending = nil
                if msg == nil then return nil end
                return p.host, msg
            end,
        }
        p.files = recs
        p.manifest = manifest
        return p
    end

    -- a sandbox whose /system holds the "current" files
    local function sandbox(name, files)
        local dir = H.case_dir("ota", name)
        H.mkdirp(dir .. "/system")
        local olds = {}
        local names = {}
        for relpath in pairs(files or {}) do names[#names + 1] = relpath end
        table.sort(names)
        for i = 1, #names do
            local relpath = names[i]
            local text = files[relpath]
            H.write(dir .. "/system/" .. relpath, text)
            olds[relpath] = sha(text)
        end
        return dir, olds
    end

    local function client(dir, net, opts)
        local o = opts or {}
        local log, lines = H.logger()
        local c = OTA.new({
            fs = o.fs or F,
            boot = BOOT,
            boot_opts = { fs = F, root = dir, log = log },
            rednet = net,
            host = o.host or 12,
            sha = CR.sha256,
            log = log,
            timeout = 1,
            max_tries = o.max_tries or 2,
            backup_cap = o.backup_cap,
            clock = os.clock,
        })
        return c, log, lines
    end

    local function journal_of(dir)
        return (BOOT.read_journal({ fs = F, root = dir }))
    end

    -- -----------------------------------------------------------------
    H.group("ota.parse_meta")
    do
        local good = PREFIX .. " META version=0.6.0 files=3 manifest_sha=" .. H.HEX64
        local meta = OTA.parse_meta(good)
        H.table("meta", meta)
        H.eq("version", meta and meta.version, "0.6.0")
        H.eq("files", meta and meta.files, 3)
        H.eq("manifest", meta and meta.manifest_sha, H.HEX64)

        -- the prefix moved to /2 and nothing else is accepted
        H.eq("old_prefix", select(2, OTA.parse_meta(
            "PYROET-OTA/1 META version=1 files=1 manifest_sha=" .. H.HEX64)),
            "wrong protocol")
        H.eq("not_meta", select(2, OTA.parse_meta(
            PREFIX .. " FILE kernel/a.lua 1 " .. H.HEX64)), "not META")
        H.eq("not_string", select(2, OTA.parse_meta(nil)), "not a string")

        -- files: 1..256, decimal only
        H.eq("files_zero", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=0 manifest_sha=" .. H.HEX64)), "bad files")
        H.eq("files_257", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=257 manifest_sha=" .. H.HEX64)), "bad files")
        H.eq("files_text", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=abc manifest_sha=" .. H.HEX64)), "bad files")
        H.eq("files_fraction", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=2.5 manifest_sha=" .. H.HEX64)), "bad files")
        H.eq("files_256_ok", OTA.parse_meta(
            PREFIX .. " META version=1 files=256 manifest_sha=" .. H.HEX64) ~= nil, true)

        -- manifest_sha: exactly 64 hex, case insensitive, normalised to lower
        H.eq("sha_63", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 manifest_sha=" .. H.HEX64:sub(1, 63))),
            "bad manifest_sha")
        H.eq("sha_65", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 manifest_sha=" .. H.HEX64 .. "a")),
            "bad manifest_sha")
        H.eq("sha_nonhex", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 manifest_sha=" .. string.rep("z", 64))),
            "bad manifest_sha")
        local upper = OTA.parse_meta(PREFIX .. " META version=1 files=1 manifest_sha="
            .. H.HEX64:upper())
        H.eq("sha_lowered", upper and upper.manifest_sha, H.HEX64)

        -- version: [%w._-] and at most 32 characters
        H.eq("version_slash", select(2, OTA.parse_meta(
            PREFIX .. " META version=0/6 files=1 manifest_sha=" .. H.HEX64)), "bad version")
        H.eq("version_long", select(2, OTA.parse_meta(
            PREFIX .. " META version=" .. string.rep("9", 33) .. " files=1 manifest_sha="
            .. H.HEX64)), "bad version")
        H.eq("version_32_ok", OTA.parse_meta(
            PREFIX .. " META version=" .. string.rep("9", 32) .. " files=1 manifest_sha="
            .. H.HEX64) ~= nil, true)

        -- field hygiene: missing, extra and duplicated fields are not "ignored"
        H.eq("missing_files", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 manifest_sha=" .. H.HEX64)), "missing files")
        H.eq("extra_field", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 manifest_sha=" .. H.HEX64 .. " extra=1")),
            "unexpected extra")
        H.eq("duplicate_field", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 files=2 manifest_sha=" .. H.HEX64)),
            "duplicate files")
        H.eq("bad_token", select(2, OTA.parse_meta(
            PREFIX .. " META version=1 files=1 manifest_sha=" .. H.HEX64 .. " junk")),
            "bad token junk")
    end

    -- -----------------------------------------------------------------
    H.group("ota.parse_file")
    do
        local good = PREFIX .. " FILE kernel/ota.lua 12912 " .. H.HEX64
        local rec = OTA.parse_file(good)
        H.table("file", rec)
        H.eq("relpath", rec and rec.relpath, "kernel/ota.lua")
        H.eq("size", rec and rec.size, 12912)
        H.eq("sha", rec and rec.sha256, H.HEX64)

        -- size: 1..65536 (F_max)
        H.eq("size_zero", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua 0 " .. H.HEX64)), "bad size")
        H.eq("size_over", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua 65537 " .. H.HEX64)), "bad size")
        H.eq("size_text", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua abc " .. H.HEX64)), "bad size")
        H.eq("size_max_ok", OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua 65536 " .. H.HEX64) ~= nil, true)

        -- sha: 64 hex, upper case accepted and normalised
        H.eq("sha_short", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua 1 " .. H.HEX64:sub(1, 63))), "bad sha256")
        local up = OTA.parse_file(PREFIX .. " FILE kernel/a.lua 1 " .. H.HEX64:upper())
        H.eq("sha_lowered", up and up.sha256, H.HEX64)

        -- relpath: the whitelist of section 3.3 applies to FILE too
        H.eq("path_dotdot", select(2, OTA.parse_file(
            PREFIX .. " FILE ../system/kernel/a.lua 1 " .. H.HEX64)), "bad_path")
        H.eq("path_dot_segment", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/./a.lua 1 " .. H.HEX64)), "bad_path")
        H.eq("path_leading", select(2, OTA.parse_file(
            PREFIX .. " FILE /system/kernel/a.lua 1 " .. H.HEX64)), "bad_path")
        H.eq("path_double", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel//a.lua 1 " .. H.HEX64)), "bad_path")
        H.eq("path_hidden", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/.image 1 " .. H.HEX64)), "bad_path")
        H.eq("path_ext", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.bin 1 " .. H.HEX64)), "bad_ext")
        H.eq("path_reserved", select(2, OTA.parse_file(
            PREFIX .. " FILE startup.lua 1 " .. H.HEX64)), "reserved")
        H.eq("path_long", select(2, OTA.parse_file(
            PREFIX .. " FILE " .. string.rep("a", 93) .. ".lua 1 " .. H.HEX64)), "bad_path")

        -- FILE is positional: four tokens, no more and no fewer
        H.eq("not_file", select(2, OTA.parse_file(
            PREFIX .. " DATA kernel/a.lua 0 00")), "not FILE")
        H.eq("short_line", select(2, OTA.parse_file(
            PREFIX .. " FILE kernel/a.lua")), "not FILE")
    end

    -- -----------------------------------------------------------------
    H.group("ota.parse_data")
    do
        local payload = hex_of("abcdefgh")
        local good = PREFIX .. " DATA kernel/a.lua 0 " .. payload
        local d = OTA.parse_data(good, { relpath = "kernel/a.lua", offset = 0, size = 64 })
        H.table("data", d)
        H.eq("relpath", d and d.relpath, "kernel/a.lua")
        H.eq("offset", d and d.offset, 0)
        H.eq("payload", d and d.data, "abcdefgh")

        H.eq("offset_unaligned", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 7 " .. payload,
            { relpath = "kernel/a.lua", offset = 7, size = 64 })), "bad offset")
        H.eq("offset_past_end", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 8192 " .. payload,
            { relpath = "kernel/a.lua", offset = 8192, size = 64 })), "offset past end")
        H.eq("odd_hex", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 0 " .. payload .. "a", nil)), "odd hex")
        H.eq("bad_hex", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 0 00GG", nil)), "bad hex")
        H.eq("too_large", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 0 " .. string.rep("61", OTA.MAX_DATA + 1), nil)),
            "payload too large")
        -- a DATA line with no payload at all cannot even be tokenised
        H.eq("no_payload", select(2, OTA.parse_data(PREFIX .. " DATA kernel/a.lua 0", nil)),
            "not DATA")
        H.eq("wrong_relpath", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/b.lua 0 " .. payload,
            { relpath = "kernel/a.lua", offset = 0, size = 64 })), "wrong relpath")
        H.eq("wrong_offset", select(2, OTA.parse_data(
            PREFIX .. " DATA kernel/a.lua 8192 " .. payload,
            { relpath = "kernel/a.lua", offset = 0, size = 65536 })), "wrong offset")
        H.eq("not_data", select(2, OTA.parse_data(
            PREFIX .. " FILE kernel/a.lua 8 " .. H.HEX64, nil)), "not DATA")
    end

    -- -----------------------------------------------------------------
    H.group("ota.valid_path")
    do
        -- the seven rules of section 3.3, one assertion each
        H.eq("ok_simple", OTA.valid_path("kernel/ota.lua"), true)
        H.eq("ok_deep", OTA.valid_path("net/apps/x.conf"), true)
        H.eq("ok_exts", OTA.valid_path("a.lua") and OTA.valid_path("a.txt")
            and OTA.valid_path("a.conf") and OTA.valid_path("a.cfg"), true)
        H.eq("empty", select(2, OTA.valid_path("")), "bad_path")
        H.eq("nil_path", select(2, OTA.valid_path(nil)), "bad_path")
        H.eq("too_long", select(2, OTA.valid_path(string.rep("a", 93) .. ".lua")), "bad_path")
        H.eq("exactly_96", OTA.valid_path(string.rep("a", 88) .. "abcd.lua"), true)
        H.eq("non_ascii", select(2, OTA.valid_path("kernel/" .. string.char(127) .. "a.lua")),
            "bad_path")
        H.eq("space", select(2, OTA.valid_path("kernel/a b.lua")), "bad_path")
        H.eq("leading_slash", select(2, OTA.valid_path("/system/kernel/a.lua")), "bad_path")
        H.eq("trailing_slash", select(2, OTA.valid_path("kernel/a.lua/")), "bad_path")
        H.eq("double_slash", select(2, OTA.valid_path("kernel//a.lua")), "bad_path")
        H.eq("dotdot", select(2, OTA.valid_path("..")), "bad_path")
        H.eq("dotdot_segment", select(2, OTA.valid_path("kernel/../a.lua")), "bad_path")
        H.eq("dot_file", select(2, OTA.valid_path("kernel/.tries")), "bad_path")
        H.eq("dot_dir", select(2, OTA.valid_path(".kernel/a.lua")), "bad_path")
        H.eq("bad_char", select(2, OTA.valid_path("kernel/a+b.lua")), "bad_path")
        H.eq("no_ext", select(2, OTA.valid_path("kernel/a")), "bad_ext")
        H.eq("wrong_ext", select(2, OTA.valid_path("kernel/a.exe")), "bad_ext")
        H.eq("reserved_journal", select(2, OTA.valid_path("update.journal")), "reserved")
        H.eq("reserved_startup", select(2, OTA.valid_path("startup.lua")), "reserved")
        H.eq("reserved_nested", select(2, OTA.valid_path("system/boot.ok")), "reserved")
        -- "a..b.lua" is not a ".." segment: the rule is per segment, not per string
        H.eq("dots_inside_name", OTA.valid_path("kernel/a..b.lua"), true)
    end

    -- -----------------------------------------------------------------
    H.group("ota.manifest_hash")
    do
        local a = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("a", 64) }
        local b = { relpath = "kernel/b.lua", size = 9, sha256 = string.rep("b", 64) }
        local h1 = OTA.manifest_hash({ a, b }, CR.sha256)
        local h2 = OTA.manifest_hash({ b, a }, CR.sha256)
        H.eq("order_independent", h1, h2)
        H.eq("hex64", #h1, 64)
        H.eq("lower", h1, h1:lower())

        -- case normalisation of the per-file digest
        local a_up = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("A", 64) }
        H.eq("sha_case", OTA.manifest_hash({ a_up, b }, CR.sha256), h1)

        -- the single definition, spelled out (section 3.2)
        local manual = sha("kernel/a.lua\0" .. "8\0" .. string.rep("a", 64) .. "\n"
            .. "kernel/b.lua\0" .. "9\0" .. string.rep("b", 64) .. "\n")
        H.eq("exact_definition", h1, manual)

        -- empty file set hashes the empty string (used by the migration journal)
        H.eq("empty", OTA.manifest_hash({}, CR.sha256), sha(""))

        -- size and digest both participate
        local bigger = { relpath = "kernel/a.lua", size = 9, sha256 = string.rep("a", 64) }
        H.check("size_matters", OTA.manifest_hash({ bigger, b }, CR.sha256) ~= h1,
            "size was not part of the hash")
        local other = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("c", 64) }
        H.check("sha_matters", OTA.manifest_hash({ other, b }, CR.sha256) ~= h1,
            "digest was not part of the hash")
        -- the relpath cannot carry a NUL: the whitelist rejects control bytes
        H.eq("nul_path_rejected", select(2, OTA.valid_path("kernel/a.lua\0x")), "bad_path")
    end

    -- -----------------------------------------------------------------
    H.group("ota.idle")
    do
        local dir = sandbox("idle")
        local c = client(dir, peer({}).rednet)
        local status = c:status()
        H.eq("state", status.state, "idle")
        H.eq("count", status.count, 0)
        H.eq("bytes", status.bytes, 0)
        H.eq("retries", status.retries, 0)
        H.eq("cap", status.cap, OTA.BACKUP_CAP)
        H.eq("version", status.version, nil)
        H.table("files", status.files)
        H.eq("states", table.concat(status.states, ","), "idle")
        H.eq("no_journal", journal_of(dir), nil)

        -- no boot module and no way to load one: refuse before touching anything
        local log, lines = H.logger()
        local broken = OTA.new({
            fs = F, boot_path = "/nope/boot.lua", rednet = peer({}).rednet,
            boot_opts = { fs = F, root = dir }, sha = CR.sha256, log = log, timeout = 1,
        })
        local ok, err = broken:update()
        H.check("no_boot_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("no_boot_err", err, "boot module unavailable")
        H.has(lines, "OTA_FAIL stage=prepare err=boot module unavailable")
        H.eq("no_boot_state", broken:status().state, "failed")

        -- a client with no SHA-256 cannot verify anything at all
        local log2, lines2 = H.logger()
        local nosha = OTA.new({
            fs = F, boot = BOOT, boot_opts = { fs = F, root = dir },
            rednet = peer({}).rednet, sha = false, log = log2, timeout = 1,
            loadfile = function() return nil end,
        })
        local ok2, err2 = nosha:update()
        H.eq("no_sha_err", err2, "no_sha256")
        H.has(lines2, "OTA_FAIL stage=prepare err=no_sha256")
    end

    -- -----------------------------------------------------------------
    H.group("ota.happy")
    do
        local a1, a2 = "-- a v1\n", "-- a v2\n"
        local x1, x2 = "k=v1\n", "k=v2\n"
        local dir, olds = sandbox("happy", {
            ["kernel/a.lua"] = a1,
            ["net/x.conf"] = x1,
            ["kernel/keep.lua"] = "-- keep\n",
        })
        local keep_sha = sha_of(dir .. "/system/kernel/keep.lua")
        local files = {
            { relpath = "kernel/a.lua", data = a2 },
            { relpath = "net/x.conf", data = x2 },
        }
        local p = peer(files)
        local c, log, lines = client(dir, p.rednet)
        local ok, status = c:update()

        H.check("ok", ok == true, "err=" .. tostring(status and status.error))
        H.eq("state", c:status().state, "ready")
        H.eq("stage", c:status().stage, "applied")
        H.eq("count", c:status().count, 2)
        H.eq("version", c:status().version, "0.6.0")
        H.eq("manifest", c:status().manifest_sha, p.manifest)
        H.eq("bytes", c:status().bytes, #a2 + #x2)
        H.eq("backup_bytes", c:status().backup, #a1 + #x1)

        -- the system tree really changed, and nothing else did
        H.eq("new_a", sha_of(dir .. "/system/kernel/a.lua"), sha(a2))
        H.eq("new_x", sha_of(dir .. "/system/net/x.conf"), sha(x2))
        H.eq("keep_untouched", sha_of(dir .. "/system/kernel/keep.lua"), keep_sha)

        -- the old bytes are in the backup tree, verified before they were moved
        H.eq("backup_a", sha_of(dir .. "/update.backup/kernel/a.lua"), olds["kernel/a.lua"])
        H.eq("backup_x", sha_of(dir .. "/update.backup/net/x.conf"), olds["net/x.conf"])
        H.eq("backup_only_touched", H.exists(dir .. "/update.backup/kernel/keep.lua"), false)

        -- the journal ends in applied, with the local old_sha and the remote
        -- new_sha, and the manifest of the whole set
        local rec = journal_of(dir)
        H.table("journal", rec)
        H.eq("journal_state", rec and rec.state, "applied")
        H.eq("journal_files", rec and #rec.files, 2)
        H.eq("journal_manifest", rec and rec.manifest_sha, p.manifest)
        H.eq("journal_version", rec and rec.version, "0.6.0")
        H.eq("journal_old", rec and rec.files[1].old_sha, olds["kernel/a.lua"])
        H.eq("journal_new", rec and rec.files[1].new_sha, sha(a2))
        H.eq("journal_bytes", rec and rec.files[1].bytes, #a2)
        H.eq("journal_seq", rec and rec.seq, 3)

        -- the wire conversation: meta, every FILE line, then the chunks
        H.eq("sent_meta", p.sent[1], PREFIX .. " GET meta")
        H.eq("sent_file0", p.sent[2], PREFIX .. " GET 0")
        H.eq("sent_file1", p.sent[3], PREFIX .. " GET 1")
        H.eq("sent_data0", p.sent[4], PREFIX .. " GET 0 0")
        H.eq("sent_data1", p.sent[5], PREFIX .. " GET 1 0")
        H.eq("sent_count", #p.sent, 5)

        H.has(lines, "OTA_META version=0.6.0 files=2 manifest_sha=" .. p.manifest:sub(1, 12))
        H.has(lines, "OTA_FILE idx=0 path=kernel/a.lua size=" .. #a2
            .. " sha256=" .. sha(a2):sub(1, 12) .. " old=" .. olds["kernel/a.lua"]:sub(1, 12))
        H.has(lines, "OTA_MANIFEST files=2 bytes=" .. (#a2 + #x2)
            .. " backup=" .. (#a1 + #x1) .. " sha256=" .. p.manifest:sub(1, 12))
        H.has(lines, "OTA_JOURNAL seq=1 state=prepare")
        H.has(lines, "OTA_JOURNAL seq=2 state=applying")
        H.has(lines, "OTA_JOURNAL seq=3 state=applied")
        H.has(lines, "OTA_APPLIED path=kernel/a.lua new=" .. sha(a2):sub(1, 12))
        H.has(lines, "OTA_APPLIED path=net/x.conf new=" .. sha(x2):sub(1, 12))
        H.has(lines, "OTA_READY version=0.6.0 files=2 bytes=" .. (#a2 + #x2)
            .. " manifest_sha=" .. p.manifest:sub(1, 12))
        H.eq("states", table.concat(c:status().states, ","),
            "idle,fetching,listing,verifying,applying,applying,ready")
        H.ascii_check("logs_ascii", H.joined(lines))
        -- only two journal generations survive (2 and 3)
        H.eq("gens", table.concat(BOOT.journal_gens({ fs = F, root = dir }), ","), "3,2")
    end

    -- -----------------------------------------------------------------
    H.group("ota.new_file")
    do
        -- a file the update creates: no backup is needed for it, and rolling back
        -- means deleting it
        local dir, olds = sandbox("new_file", { ["kernel/a.lua"] = "-- a v1\n" })
        local added = "-- brand new\n"
        local p = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" },
                         { relpath = "kernel/added.txt", data = added } })
        local c, log, lines = client(dir, p.rednet)
        H.check("ok", c:update() == true, "update failed")
        H.eq("added", sha_of(dir .. "/system/kernel/added.txt"), sha(added))
        H.eq("no_backup_for_new", H.exists(dir .. "/update.backup/kernel/added.txt"), false)
        H.eq("backup_for_old", sha_of(dir .. "/update.backup/kernel/a.lua"),
            olds["kernel/a.lua"])
        H.eq("backup_bytes", c:status().backup, 8)
        local rec = journal_of(dir)
        H.eq("old_sha_dash", rec and rec.files[2].old_sha, "-")
        H.has(lines, "OTA_FILE idx=1 path=kernel/added.txt size=" .. #added
            .. " sha256=" .. sha(added):sub(1, 12) .. " old=-")
    end

    -- -----------------------------------------------------------------
    H.group("ota.verify_reject")
    do
        local a1 = "-- a v1\n"
        local dir, olds = sandbox("verify_reject", { ["kernel/a.lua"] = a1 })
        local lied = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } },
            { manifest = string.rep("f", 64) })
        local c, log, lines = client(dir, lied.rednet)
        local ok, err = c:update()
        H.check("reject_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("reject_err", err, "manifest_sha")
        H.eq("reject_state", c:status().state, "rejected")
        H.eq("reject_stage", c:status().stage, "verify")
        H.has(lines, "OTA_REJECT stage=verify reason=manifest_sha got="
            .. OTA.manifest_hash(lied.files, CR.sha256):sub(1, 12)
            .. " want=" .. string.rep("f", 12))

        -- not a byte of that was written: no system change, no intent, no backup
        H.eq("system_untouched", sha_of(dir .. "/system/kernel/a.lua"), olds["kernel/a.lua"])
        H.eq("no_journal", BOOT.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("no_backup", H.exists(dir .. "/update.backup"), false)
        H.eq("no_stage", H.exists(dir .. "/update.stage"), false)
        H.lacks("no_fail", lines, "OTA_FAIL")

        -- nothing changed, so pulling it again from the top is enough
        local good = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } })
        c.rednet = good.rednet
        local ok2 = c:retry()
        H.check("retry_ok", ok2 == true, "retry failed")
        H.eq("retry_state", c:status().state, "ready")
        H.has(lines, "OTA_RETRY_FROM state=rejected")
        H.eq("retry_applied", sha_of(dir .. "/system/kernel/a.lua"), sha("-- a v2\n"))

        -- retrying a client that is neither rejected nor rolled back is refused
        local c2 = client(dir, peer({}).rednet)
        local ok3, why = c2:retry()
        H.check("retry_refused", ok3 == nil and type(why) == "string",
            "ok=" .. tostring(ok3))
        H.contains("retry_refused_text", why, "nothing to retry")
    end

    -- -----------------------------------------------------------------
    H.group("ota.cap")
    do
        -- BACKUP_CAP is a policy limit on the bytes the update would copy away
        local big = string.rep("x", 32)
        local dir, olds = sandbox("cap", { ["kernel/a.lua"] = big })
        local p = peer({ { relpath = "kernel/a.lua", data = string.rep("y", 32) } })
        local c, log, lines = client(dir, p.rednet, { backup_cap = 16 })
        local ok, err = c:update()
        H.check("cap_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("cap_err", err, "too_big")
        H.eq("cap_stage", c:status().stage, "cap")
        H.eq("cap_state", c:status().state, "rejected")
        H.has(lines, "OTA_REJECT stage=cap reason=too_big need=32 cap=16")
        H.eq("system_untouched", sha_of(dir .. "/system/kernel/a.lua"), olds["kernel/a.lua"])
        H.eq("no_journal", BOOT.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("no_backup", H.exists(dir .. "/update.backup"), false)

        -- the cap does not count files the update creates (nothing to back up)
        local dir2 = sandbox("cap_new")
        local p2 = peer({ { relpath = "kernel/new.lua", data = big } })
        local c2 = client(dir2, p2.rednet, { backup_cap = 16 })
        H.check("cap_new_ok", c2:update() == true,
            "a created file must not count against the backup cap")

        -- and a cap raised later lets the same pull through
        local c3 = client(dir, peer({ { relpath = "kernel/a.lua", data = string.rep("y", 32) } }).rednet,
            { backup_cap = 64 })
        H.check("cap_raised_ok", c3:update() == true, "the raised cap was not honoured")
    end

    -- -----------------------------------------------------------------
    H.group("ota.bad_file")
    do
        -- a bad description is refused after the retries, before any download
        local dir = sandbox("bad_path", { ["kernel/a.lua"] = "-- a v1\n" })
        local p = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } },
            { bad_file_path = { [0] = "../etc/passwd.lua" } })
        local c, log, lines = client(dir, p.rednet)
        local ok, err = c:update()
        H.check("bad_path_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("bad_path_err", err, "bad_path")
        H.eq("bad_path_stage", c:status().stage, "file")
        H.has(lines, "OTA_FAIL stage=file err=bad_path")
        H.eq("nothing_written", H.exists(dir .. "/update.backup"), false)
        H.eq("system_untouched", sha_of(dir .. "/system/kernel/a.lua"), sha("-- a v1\n"))

        -- F_max is enforced by the parser, so an oversized file never gets a
        -- journal and never gets a byte
        local dir2 = sandbox("too_large")
        local p2 = peer({ { relpath = "kernel/a.lua", data = "x" } },
            { file_size = { [0] = OTA.F_MAX + 1 } })
        local c2, log2, lines2 = client(dir2, p2.rednet)
        local ok2, err2 = c2:update()
        H.eq("too_large_err", err2, "bad size")
        H.has(lines2, "OTA_FAIL stage=file err=bad size")
        H.eq("too_large_nothing", BOOT.journal_gens({ fs = F, root = dir2 })[1], nil)

        -- a duplicate relpath would make the journal lie about what it touched
        local dir3 = sandbox("duplicate")
        local p3 = peer({
            { relpath = "kernel/a.lua", data = "aa" },
            { relpath = "kernel/a.lua", data = "bb" },
        })
        local c3, log3, lines3 = client(dir3, p3.rednet)
        local ok3, err3 = c3:update()
        H.check("duplicate_ok", ok3 == nil, "duplicate accepted")
        H.contains("duplicate_err", err3, "duplicate")
        H.has(lines3, "OTA_FAIL stage=file err=duplicate kernel/a.lua")
    end

    -- -----------------------------------------------------------------
    H.group("ota.retransmit")
    do
        -- a lost packet costs one request; the update still lands
        local dir, olds = sandbox("retransmit", { ["kernel/a.lua"] = "-- a v1\n" })
        local p = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } }, { drop_data = 1 })
        local c, log, lines = client(dir, p.rednet)
        H.check("ok_after_drop", c:update() == true, "one lost packet broke the update")
        H.has(lines, "OTA_RETRY attempt=1 max=2 err=timeout")
        H.eq("applied", sha_of(dir .. "/system/kernel/a.lua"), sha("-- a v2\n"))
        H.check("retries_counted", c:status().retries >= 1,
            "retries=" .. tostring(c:status().retries))
        H.eq("old_was", olds["kernel/a.lua"] ~= sha("-- a v2\n"), true)

        -- a corrupted chunk fails the file digest, so the whole file is fetched
        -- again (no bitmap, no partial trust)
        local dir2 = sandbox("corrupt_chunk", { ["kernel/a.lua"] = "-- a v1\n" })
        local p2 = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } },
            { corrupt_data = 1 })
        local c2, log2, lines2 = client(dir2, p2.rednet, { max_tries = 2 })
        H.check("ok_after_corrupt", c2:update() == true, "corruption was not recovered")
        H.has(lines2, "OTA_RETRY attempt=1 max=2 err=file digest")
        H.eq("applied_after_corrupt", sha_of(dir2 .. "/system/kernel/a.lua"), sha("-- a v2\n"))

        -- a DATA packet that names another file is rejected, not trusted
        local dir3 = sandbox("wrong_relpath", { ["kernel/a.lua"] = "-- a v1\n" })
        local p3 = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } },
            { wrong_relpath = 1 })
        local c3, log3, lines3 = client(dir3, p3.rednet, { max_tries = 2 })
        H.check("ok_after_wrong_path", c3:update() == true, "wrong relpath was not retried")
        H.has(lines3, "OTA_RETRY attempt=1 max=2 err=wrong relpath")

        -- a meta reply that never comes is a hard failure before the download
        local dir4 = sandbox("timeout")
        local p4 = peer({ { relpath = "kernel/a.lua", data = "aa" } }, { drop_meta = 9 })
        local c4, log4, lines4 = client(dir4, p4.rednet)
        local ok4, err4 = c4:update()
        H.check("timeout_ok", ok4 == nil, "ok=" .. tostring(ok4))
        H.eq("timeout_err", err4, "timeout")
        H.eq("timeout_stage", c4:status().stage, "meta")
        H.has(lines4, "OTA_FAIL stage=meta err=timeout")

        -- a multi-chunk file is requested at MAX_DATA offsets
        local long = string.rep("q", OTA.MAX_DATA + 100)
        local dir5 = sandbox("multi_chunk")
        local p5 = peer({ { relpath = "net/big.txt", data = long } })
        local c5, log5, lines5 = client(dir5, p5.rednet)
        H.check("multi_ok", c5:update() == true, "multi-chunk failed")
        H.eq("multi_bytes", sha_of(dir5 .. "/system/net/big.txt"), sha(long))
        H.eq("multi_requests", p5.sent[4], PREFIX .. " GET 0 " .. OTA.MAX_DATA)
        H.eq("multi_applied", H.read(dir5 .. "/system/net/big.txt"), long)
    end

    -- -----------------------------------------------------------------
    H.group("ota.apply_failure")
    do
        -- an applying-phase failure rolls back the files that were already
        -- written, so the machine ends up exactly where it started
        local a1, a2 = "-- a v1\n", "-- a v2\n"
        local b1, b2 = "-- b v1\n", "-- b v2\n"
        local dir, olds = sandbox("apply_failure", {
            ["kernel/a.lua"] = a1,
            ["kernel/b.lua"] = b1,
        })
        local files = {
            { relpath = "kernel/a.lua", data = a2 },
            { relpath = "kernel/b.lua", data = b2 },
        }
        local p = peer(files)
        -- the install move of the .part file is refused, and so is its copy
        local proxy = H.fs({
            overrides = {
                move = function(src, dst)
                    if type(src) == "string" and src:find("%.part$") then
                        return nil, "refused"
                    end
                    return F.move(src, dst)
                end,
                copy = function(src, dst)
                    if type(src) == "string" and src:find("%.part$") then
                        return nil, "refused"
                    end
                    return F.copy(src, dst)
                end,
            },
        })
        local c, log, lines = client(dir, p.rednet, { fs = proxy })
        local ok, err = c:update()
        H.check("apply_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("apply_state", c:status().state, "rolled_back")
        H.has(lines, "OTA_FAIL stage=install")
        H.has(lines, "OTA_ROLLED_BACK stage=install")
        H.eq("a_back_to_old", sha_of(dir .. "/system/kernel/a.lua"), olds["kernel/a.lua"])
        H.eq("b_back_to_old", sha_of(dir .. "/system/kernel/b.lua"), olds["kernel/b.lua"])
        H.eq("rolledback_journal", journal_of(dir).state, "rolledback")
        H.eq("tombstone_seq", journal_of(dir).seq, 3)
        H.check("retryable", type(c.retry) == "function", "no retry entry point")
    end

    -- -----------------------------------------------------------------
    H.group("ota.discard")
    do
        -- the intent of a refused update is dropped, and only that
        local dir, olds = sandbox("discard", { ["kernel/a.lua"] = "-- a v1\n" })
        local p = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } },
            { manifest = string.rep("e", 64) })
        local c, log, lines = client(dir, p.rednet)
        c:update()
        H.eq("rejected", c:status().state, "rejected")
        H.check("discard_ok", c:discard() == true, "discard refused")
        H.has(lines, "OTA_DISCARD")
        H.eq("idle_again", c:status().state, "idle")
        H.eq("no_journal", BOOT.journal_gens({ fs = F, root = dir })[1], nil)
        H.eq("system_kept", sha_of(dir .. "/system/kernel/a.lua"), olds["kernel/a.lua"])
    end

    -- -----------------------------------------------------------------
    H.group("ota.rerun")
    do
        -- a second update on top of a committed one starts a new journal
        -- generation and leaves two generations at most
        local dir, olds = sandbox("rerun", { ["kernel/a.lua"] = "-- a v1\n" })
        local first = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } })
        local c = client(dir, first.rednet)
        H.check("first_ok", c:update() == true, "first update failed")
        H.eq("first_seq", journal_of(dir).seq, 3)

        -- the same content again: old_sha == new_sha, and that is still a real
        -- update that goes through the journal (it must not be special-cased)
        local second = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } })
        c.rednet = second.rednet
        H.check("second_ok", c:update() == true, "re-run failed")
        H.eq("second_seq", journal_of(dir).seq, 6)
        H.eq("gens", table.concat(BOOT.journal_gens({ fs = F, root = dir }), ","), "6,5")
        H.eq("same_bytes", sha_of(dir .. "/system/kernel/a.lua"), sha("-- a v2\n"))
        local rec = journal_of(dir)
        H.eq("same_old", rec.files[1].old_sha, sha("-- a v2\n"))
        H.eq("same_new", rec.files[1].new_sha, sha("-- a v2\n"))
        H.eq("first_old", olds["kernel/a.lua"] ~= sha("-- a v2\n"), true)
    end

    -- -----------------------------------------------------------------
    H.group("ota.no_system")
    do
        local dir = H.case_dir("ota", "no_system")
        local c, log, lines = client(dir, peer({}).rednet)
        local ok, err = c:update()
        H.check("no_system_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("no_system_err", err, "no_system")
        H.has(lines, "OTA_FAIL stage=prepare err=no_system")
        H.eq("no_system_state", c:status().state, "failed")
    end

    -- -----------------------------------------------------------------
    H.group("ota.small_data")
    do
        -- MAX_DATA is the packet payload size, not the file size: a file smaller
        -- than one chunk is one request, and the reply is correspondingly short
        local dir = sandbox("small")
        local text = "abc"
        local p = peer({ { relpath = "net/small.conf", data = text } })
        local c, log, lines = client(dir, p.rednet)
        H.check("ok", c:update() == true, "small file failed")
        H.eq("content", H.read(dir .. "/system/net/small.conf"), text)
        H.eq("one_data_request", #p.sent, 3)
        H.eq("max_data", OTA.MAX_DATA, 8192)
        H.eq("max_files", OTA.MAX_FILES, 256)
        H.eq("f_max", OTA.F_MAX, 65536)
        H.eq("backup_cap", OTA.BACKUP_CAP, 200000)
        H.eq("prefix", OTA.PREFIX, "PYROET-OTA/2")
    end

    -- -----------------------------------------------------------------
    H.group("ota.status_transitions")
    do
        -- the state list is the audit trail of the run, in order
        local dir, olds = sandbox("status", { ["kernel/a.lua"] = "-- a v1\n" })
        local p = peer({ { relpath = "kernel/a.lua", data = "-- a v2\n" } })
        local c = client(dir, p.rednet)
        c:update()
        local states = table.concat(c:status().states, ",")
        H.eq("states", states, "idle,fetching,listing,verifying,applying,applying,ready")
        H.eq("journal_seq_last", c:status().journal, 3)
        H.eq("no_fatal", c:status().fatal, nil)
        H.eq("err_clear", c:status().error, nil)
        H.eq("system_applied", sha_of(dir .. "/system/kernel/a.lua"), sha("-- a v2\n"))
        H.eq("old_was", olds["kernel/a.lua"] ~= sha("-- a v2\n"), true)
    end
end
