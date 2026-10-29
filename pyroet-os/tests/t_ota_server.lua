--[[- pyroet-os/tests/t_ota_server.lua -- PYROET-OTA/2 distribution side.

Drives `ota/server.lua` (the publishing / serving end) against the real client
`system/kernel/ota.lua` in one process: a stub rednet carries the bytes, the
server's own `request`/`handle`/`dispatch` code answers them, and the client
downloads, verifies and applies into a /t sandbox. Nothing is mocked except the
modem, so the client's parser and the server's formatter are tested against each
other rather than against a hand-written expectation.

Three kinds of assertion, in this order of importance:

  1. differential -- the same input through both implementations must produce
     the same result: `valid_path` (accept/reject AND reason) over every rule,
     `manifest_hash` in both directions, and the client's own parse of the
     server's META/FILE/DATA lines re-hashing to the server's manifest_sha.
     A ?? mismatch is a failure, not a hunch.
  2. end to end -- a full update from a directory-built manifest (small files
     plus one multi-chunk file), with the exact wire conversation asserted.
  3. faults -- manifest lie, tampered bytes, lost packet, lost request, empty
     file set, oversized file, path outside the whitelist, unknown request,
     out-of-range idx, retry() after a reject, and the serve()/stop() loop.

No non-ASCII bytes in this file.
]]

local OTA = dofile("/system/kernel/ota.lua")
local BOOT = dofile("/system/boot.lua")
local SRV = dofile("/ota/server.lua")

return function(H)
    local F = H.real_fs()

    local CR = {}
    assert(loadfile("/system/rpv/crypto.lua"))(CR)
    local function sha(text) return CR.hex(CR.sha256(text)) end
    local function hex_of(text) return CR.hex(text) end
    local function sha_of(path)
        local text = H.read(path)
        if text == nil then return nil end
        return sha(text)
    end

    local PREFIX = OTA.PREFIX
    local SERVER_ID = 12

    -- -----------------------------------------------------------------
    -- fixtures
    -- -----------------------------------------------------------------

    -- a publishing directory: meta.txt next to the file tree
    local function publish(name, version, files, extra)
        local dir = H.case_dir("ota_server", name .. "_pub")
        local side = { "version=" .. version }
        for i = 1, #(extra or {}) do side[#side + 1] = extra[i] end
        H.write(dir .. "/meta.txt", table.concat(side, "\n") .. "\n")
        local names = {}
        for relpath in pairs(files or {}) do names[#names + 1] = relpath end
        table.sort(names)
        for i = 1, #names do H.write(dir .. "/" .. names[i], files[names[i]]) end
        return dir
    end

    -- the "machine" the client updates: <root>/system with the current bytes
    local function sandbox(name, files)
        local root = H.case_dir("ota_server", name .. "_root")
        H.mkdirp(root .. "/system")
        local names = {}
        for relpath in pairs(files or {}) do names[#names + 1] = relpath end
        table.sort(names)
        for i = 1, #names do H.write(root .. "/system/" .. names[i], files[names[i]]) end
        return root
    end

    local function server(opts)
        local o = opts or {}
        local log, lines = H.logger()
        local sha_fn = o.sha
        if sha_fn == nil then sha_fn = CR.sha256 end
        local s = SRV.new({
            fs = o.fs or F, manifest = o.manifest, dir = o.dir, sha = sha_fn,
            log = log, rednet = o.rednet, channel = o.channel,
            loadfile = o.loadfile,
        })
        return s, log, lines
    end

    local function build(dir, opts)
        local o = opts or {}
        local log, lines = H.logger()
        local m, why, path = SRV.build_manifest(dir, {
            fs = o.fs or F, sha = o.sha, log = log, loadfile = o.loadfile,
        })
        return m, why, path, lines
    end

    local function client(root, net, opts)
        local o = opts or {}
        local log, lines = H.logger()
        local c = OTA.new({
            fs = o.fs or F, boot = BOOT,
            boot_opts = { fs = F, root = root, log = log },
            rednet = net, host = o.host or SERVER_ID, sha = CR.sha256,
            log = log, timeout = 1, max_tries = o.max_tries or 2,
            backup_cap = o.backup_cap, clock = os.clock,
        })
        return c, log, lines
    end

    -- One process, two ends of a modem. The client's send() runs the server's
    -- real dispatch(); whatever the server sends back appears in the client's
    -- receive queue. drop_data / drop_request inject loss without a network.
    local function wire(srv, opts)
        local o = opts or {}
        local w = {
            queue = {}, sent = {}, dropped = 0,
            drop_data = o.drop_data or 0, drop_request = o.drop_request or 0,
        }
        w.rednet = {
            send = function(host, msg, protocol)
                if host ~= SERVER_ID then return true end
                w.sent[#w.sent + 1] = msg
                if w.drop_request > 0 then
                    w.drop_request = w.drop_request - 1
                    return true
                end
                local reply = srv:dispatch(SERVER_ID, msg, protocol)
                if reply and w.drop_data > 0
                    and msg:match("^%S+%s+GET%s+%S+%s+%S+$") then
                    w.drop_data = w.drop_data - 1
                    w.dropped = w.dropped + 1
                    if #w.queue > 0 then w.queue[#w.queue] = nil end
                end
                return true
            end,
            receive = function(protocol, timeout)
                local item = table.remove(w.queue, 1)
                if not item then return nil end
                return item[1], item[2]
            end,
        }
        w.server_rednet = {
            send = function(to, msg, protocol)
                w.queue[#w.queue + 1] = { to, msg, protocol }
                return true
            end,
            receive = function() return nil end,
        }
        srv.rednet = w.server_rednet
        return w
    end

    -- publish dir -> server -> wire -> client over a sandbox
    local function stack(name, version, files, opts)
        local o = opts or {}
        local pub = publish(name, version, files, o.pins)
        local srv, slog, slines = server({ dir = pub })
        local w = wire(srv, o)
        local root = sandbox(name, o.old)
        local c, clog, clines = client(root, w.rednet, o)
        return {
            srv = srv, w = w, c = c, root = root, pub = pub,
            slines = slines, clines = clines, clog = clog, slog = slog,
        }
    end

    -- first log line containing `marker`, then the value of `key=..` on it
    local function field_of(lines, marker, key)
        for i = 1, #lines do
            local line = tostring(lines[i])
            if line:find(marker, 1, true) then
                return line:match(key .. "=(%S+)")
            end
        end
        return nil
    end

    local function journal_of(root)
        return BOOT.read_journal({ fs = F, root = root })
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.constants")
    do
        -- every number the wire format depends on, checked against the client:
        -- a server that grew its own idea of MAX_DATA or F_MAX would silently
        -- truncate or overrun what the client accepts
        H.eq("prefix", SRV.PREFIX, OTA.PREFIX)
        H.eq("protocol", SRV.PROTOCOL, OTA.PROTOCOL)
        H.eq("max_data", SRV.MAX_DATA, OTA.MAX_DATA)
        H.eq("max_data_value", SRV.MAX_DATA, 8192)
        H.eq("f_max", SRV.F_MAX, OTA.F_MAX)
        H.eq("f_max_value", SRV.F_MAX, 65536)
        H.eq("max_files", SRV.MAX_FILES, OTA.MAX_FILES)
        H.eq("crypto", SRV.CRYPTO, OTA.CRYPTO)
        H.eq("max_path", SRV.MAX_PATH, 96)
        H.eq("sidecar", SRV.SIDECAR, "meta.txt")
        H.eq("timeout_number", type(SRV.TIMEOUT), "number")
        H.eq("version_string", type(SRV.VERSION), "string")

        local exts = { "lua", "txt", "conf", "cfg" }
        for i = 1, #exts do
            local ext = exts[i]
            H.eq("ext_" .. ext, (SRV.EXT[ext] == true) and (OTA.EXT[ext] == true), true)
        end
        local ext_count = 0
        for _ in pairs(SRV.EXT) do ext_count = ext_count + 1 end
        H.eq("ext_count", ext_count, 4)

        local reserved = { "update.journal", "update.backup", "boot.ok", "boot.tries", "startup.lua" }
        for i = 1, #reserved do
            local name = reserved[i]
            H.eq("reserved_" .. i, (SRV.RESERVED[name] == true) and (OTA.RESERVED[name] == true),
                true)
        end
        local reserved_count = 0
        for _ in pairs(SRV.RESERVED) do reserved_count = reserved_count + 1 end
        H.eq("reserved_count", reserved_count, 5)
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.valid_path")
    do
        -- the whitelist copied into the server, diffed against the client over
        -- every rule of P6-design 3.3: same accept/reject AND same reason
        local PATHS = {
            "kernel/ota.lua", "net/x.conf", "a.lua", "a.txt", "a.conf", "a.cfg",
            "kernel/deep/nested/app.lua", "kernel/a..b.lua",
            "", "/system/kernel/a.lua", "kernel/a.lua/", "kernel//a.lua",
            "..", "kernel/../a.lua", "kernel/./a.lua", "kernel/.image",
            ".kernel/a.lua", "kernel/a b.lua", "kernel/a+b.lua",
            string.rep("a", 93) .. ".lua", string.rep("a", 88) .. "abcd.lua",
            "kernel/a", "kernel/a.exe", "kernel/a.bin", "update.journal",
            "startup.lua", "system/boot.ok", "kernel/" .. string.char(127) .. "a.lua",
            "kernel/a.lua\0x",
        }
        H.eq("path_cases", #PATHS, 29)
        for i = 1, #PATHS do
            local path = PATHS[i]
            local clients_ok, clients_why = OTA.valid_path(path)
            local ours_ok, ours_why = SRV.valid_path(path)
            H.eq("verdict_" .. i, ours_ok and "ok" or "no", clients_ok and "ok" or "no")
            H.eq("reason_" .. i, tostring(ours_why), tostring(clients_why))
        end
        -- not a string at all: both must say bad_path rather than raise
        H.eq("nil_verdict", select(2, SRV.valid_path(nil)), select(2, OTA.valid_path(nil)))
        H.eq("table_verdict", select(2, SRV.valid_path({})), select(2, OTA.valid_path({})))
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.manifest_hash")
    do
        local a = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("a", 64) }
        local b = { relpath = "kernel/b.lua", size = 9, sha256 = string.rep("b", 64) }
        local ours = SRV.manifest_hash({ a, b }, CR.sha256)
        H.eq("same_as_client", ours, OTA.manifest_hash({ a, b }, CR.sha256))
        H.eq("order_independent", SRV.manifest_hash({ b, a }, CR.sha256), ours)
        H.eq("hex64", #ours, 64)
        H.eq("lowercase", ours, ours:lower())
        -- the single definition of P6-design 3.2, spelled out on the server side
        local manual = sha("kernel/a.lua\0" .. "8\0" .. string.rep("a", 64) .. "\n"
            .. "kernel/b.lua\0" .. "9\0" .. string.rep("b", 64) .. "\n")
        H.eq("exact_definition", ours, manual)
        -- the client accepts a digest under either key; so must the server
        local c = { relpath = "kernel/a.lua", size = 8, new_sha = string.rep("a", 64) }
        H.eq("new_sha_key", SRV.manifest_hash({ c, b }, CR.sha256),
            OTA.manifest_hash({ c, b }, CR.sha256))
        -- case normalisation and the empty set
        local upper = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("A", 64) }
        H.eq("sha_case", SRV.manifest_hash({ upper, b }, CR.sha256), ours)
        H.eq("empty", SRV.manifest_hash({}, CR.sha256), CR.hex(CR.sha256("")))
        H.eq("empty_same_as_client", SRV.manifest_hash({}, CR.sha256),
            OTA.manifest_hash({}, CR.sha256))
        -- size and digest both participate
        local bigger = { relpath = "kernel/a.lua", size = 9, sha256 = string.rep("a", 64) }
        H.check("size_matters", SRV.manifest_hash({ bigger, b }, CR.sha256) ~= ours, "size ignored")
        local other = { relpath = "kernel/a.lua", size = 8, sha256 = string.rep("c", 64) }
        H.check("sha_matters", SRV.manifest_hash({ other, b }, CR.sha256) ~= ours, "digest ignored")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.build_manifest")
    do
        local a, x, c = "-- a\n", "k=v\n", "c=1\n"
        local dir = publish("build", "0.7.0", {
            ["kernel/a.lua"] = a, ["net/x.conf"] = x, ["kernel/deep/c.cfg"] = c,
        })
        local m, why, path, lines = build(dir)
        H.eq("why", why, nil)
        H.eq("bad_path", path, nil)
        H.table("manifest", m)
        H.eq("version", m.version, "0.7.0")
        H.eq("count", #m.files, 3)
        H.eq("count_field", m.count, 3)
        H.eq("order", m.files[1].relpath .. "," .. m.files[2].relpath .. "," .. m.files[3].relpath,
            "kernel/a.lua,kernel/deep/c.cfg,net/x.conf")
        H.eq("idx0", m.files[1].idx, 0)
        H.eq("idx1", m.files[2].idx, 1)
        H.eq("idx2", m.files[3].idx, 2)
        H.eq("size", m.files[2].size, #c)
        H.eq("sha", m.files[2].sha256, sha(c))
        H.eq("sha_lower", m.files[2].sha256, m.files[2].sha256:lower())
        H.eq("bytes", m.bytes, #a + #x + #c)
        H.eq("data_kept", m.files[1].data, a)
        -- the aggregate the server computed is the client's definition
        H.eq("aggregate_is_client_hash", m.manifest_sha, OTA.manifest_hash(m.files, CR.sha256))
        H.eq("aggregate_lower", m.manifest_sha, m.manifest_sha:lower())
        -- the sidecar is not part of the update set
        local sidecar_served = false
        for i = 1, #m.files do
            if m.files[i].relpath == "meta.txt" then sidecar_served = true end
        end
        H.eq("sidecar_skipped", sidecar_served, false)
        H.eq("dir_field", m.dir, dir)
        H.has(lines, "OTA_SERVER_MANIFEST dir=")
        H.has(lines, "files=3")
        H.has(lines, "manifest_sha=" .. m.manifest_sha:sub(1, 12))

        -- serve those records and let the CLIENT parse them back
        local srv = server({ manifest = m })
        local parsed = {}
        for idx = 0, #m.files - 1 do
            local line = srv:handle(PREFIX .. " GET " .. idx, 7)
            parsed[#parsed + 1] = OTA.parse_file(line)
        end
        H.eq("parsed_count", #parsed, 3)
        for idx = 1, #parsed do
            H.eq("parsed_relpath_" .. idx, parsed[idx] and parsed[idx].relpath, m.files[idx].relpath)
            H.eq("parsed_sha_" .. idx, parsed[idx] and parsed[idx].sha256, m.files[idx].sha256)
        end
        -- the other direction of the same definition: records the client parsed
        -- out of the wire hash to the server's manifest_sha
        H.eq("client_parsed_hash", OTA.manifest_hash(parsed, CR.sha256), m.manifest_sha)

        -- optional pins in meta.txt: files= and manifest_sha= bind the mirror to
        -- the exact bytes that were tested
        local pinned = publish("build_pinned", "0.7.1",
            { ["kernel/a.lua"] = a, ["net/x.conf"] = x },
            { "files=2", "manifest_sha=" .. OTA.manifest_hash({
                { relpath = "kernel/a.lua", size = #a, sha256 = sha(a) },
                { relpath = "net/x.conf", size = #x, sha256 = sha(x) },
            }, CR.sha256) })
        local m2 = build(pinned)
        H.table("pinned_manifest", m2)
        H.eq("pinned_count", m2 and #m2.files, 2)

        -- an empty set is a legal manifest (the migration journal's definition)
        local empty = publish("build_empty", "0.0.1", {})
        local m3 = build(empty)
        H.table("empty_manifest", m3)
        H.eq("empty_count", m3 and #m3.files, 0)
        H.eq("empty_hash", m3 and m3.manifest_sha, CR.hex(CR.sha256("")))
        -- comments and blank lines in the sidecar are fine
        H.write(empty .. "/meta.txt", "# comment\n\nversion=0.0.2\n")
        local m4 = build(empty)
        H.eq("comment_version", m4 and m4.version, "0.0.2")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.build_manifest_errors")
    do
        local function refuse(name, files, why_want, extra)
            local dir = publish(name, "1.0.0", files, extra)
            local m, why, path = build(dir)
            H.eq("refuse_" .. name .. "_nil", m, nil)
            H.eq("refuse_" .. name .. "_why", why, why_want)
            return path
        end
        -- a path the client would refuse is not published at all
        local path = refuse("bad_ext", { ["kernel/evil.bin"] = "a" }, "bad_ext")
        H.eq("bad_ext_path", path, "kernel/evil.bin")
        H.eq("bad_ext_client", select(2, OTA.valid_path("kernel/evil.bin")), "bad_ext")
        refuse("reserved", { ["startup.lua"] = "-- x\n" }, "reserved")
        refuse("space_path", { ["kernel/a b.lua"] = "a" }, "bad_path")
        refuse("zero_size", { ["net/empty.txt"] = "" }, "bad_size")
        refuse("too_large", { ["kernel/huge.lua"] = string.rep("x", OTA.F_MAX + 1) }, "too_large")

        -- sidecar problems: missing, unversioned, unknown key, duplicate, junk
        local bare = H.case_dir("ota_server", "no_meta")
        H.write(bare .. "/kernel/a.lua", "a")
        local m, why = build(bare)
        H.eq("missing_meta_nil", m, nil)
        H.eq("missing_meta_why", why, "missing_meta")

        local noversion = H.case_dir("ota_server", "no_version")
        H.write(noversion .. "/meta.txt", "files=1\n")
        local m2, why2 = build(noversion)
        H.eq("no_version_why", why2, "bad_version")

        local unknown = publish("unknown_key", "1", {}, { "extra=1" })
        local m3, why3 = build(unknown)
        H.eq("unknown_key_why", why3, "unexpected_extra")

        local dup = publish("dup_key", "1", {}, { "version=2" })
        local m4, why4 = build(dup)
        H.eq("duplicate_key_why", why4, "duplicate_version")

        local junk = publish("junk_line", "1", {}, { "junk" })
        local m5, why5 = build(junk)
        H.eq("junk_line_why", why5, "bad_meta_line")

        local badver = publish("bad_version", "0/6", {})
        local m6, why6 = build(badver)
        H.eq("bad_version_why", why6, "bad_version")

        -- pins that do not match the tree are refused (a stale mirror)
        local files_wrong = publish("files_pin", "1", { ["kernel/a.lua"] = "a" }, { "files=2" })
        local m7, why7 = build(files_wrong)
        H.eq("files_pin_why", why7, "files_mismatch")

        local sha_wrong = publish("sha_pin", "1", { ["kernel/a.lua"] = "a" },
            { "manifest_sha=" .. string.rep("0", 64) })
        local m8, why8 = build(sha_wrong)
        H.eq("sha_pin_why", why8, "manifest_sha_mismatch")

        local sha_junk = publish("sha_junk", "1", { ["kernel/a.lua"] = "a" },
            { "manifest_sha=nothex" })
        local m9, why9 = build(sha_junk)
        H.eq("sha_junk_why", why9, "bad_manifest_sha")

        -- no SHA-256 implementation: refuse rather than publish unchecked bytes
        local ok_dir = publish("no_sha", "1", { ["kernel/a.lua"] = "a" })
        local m10, why10 = build(ok_dir, { sha = false, loadfile = function() return nil end })
        H.eq("no_sha_nil", m10, nil)
        H.eq("no_sha_why", why10, "no_sha256")

        -- not a directory, or no directory at all
        H.eq("no_dir_why", select(2, build(nil)), "no_dir")
        H.eq("missing_dir_why", select(2, build("/t/ota_server/definitely_absent")), "no_dir")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.new")
    do
        local a, x = "-- a v1\n", "k=v1\n"
        -- unsorted input, one digest upper case, sizes derived from the bytes
        local s, log, lines = server({ manifest = {
            version = "1.2.3",
            files = {
                { relpath = "net/x.conf", data = x },
                { relpath = "kernel/a.lua", data = a, sha256 = sha(a):upper() },
            },
        } })
        H.eq("error", s.error, nil)
        H.eq("count", #s.files, 2)
        H.eq("sorted", s.files[1].relpath .. "," .. s.files[2].relpath, "kernel/a.lua,net/x.conf")
        H.eq("size_derived", s.files[1].size, #a)
        H.eq("sha_lowered", s.files[1].sha256, sha(a))
        H.eq("bytes", s.manifest.bytes, #a + #x)
        H.eq("aggregate", s.manifest.manifest_sha, OTA.manifest_hash(s.files, CR.sha256))
        H.has(lines, "OTA_SERVER_READY version=1.2.3 files=2")

        -- every way a manifest can be inconsistent is refused here, with the
        -- reason the client would also use where one exists
        local function reject(manifest, why)
            local inst, _, inst_lines = server({ manifest = manifest })
            H.eq("reject_" .. tostring(why), inst.error, why)
            return inst, inst_lines
        end
        reject(nil, "no_manifest")
        reject({ files = {} }, "bad_version")
        reject({ version = "1", files = "x" }, "no_manifest")
        reject({ version = "0/6", files = {} }, "bad_version")
        reject({ version = "1", files = { { relpath = "../a.lua", data = "a" } } }, "bad_path")
        reject({ version = "1", files = { { relpath = "startup.lua", data = "a" } } }, "reserved")
        reject({ version = "1", files = { { relpath = "kernel/a.bin", data = "a" } } }, "bad_ext")
        reject({ version = "1", files = { { relpath = "kernel/a.lua", data = "" } } }, "bad_size")
        reject({ version = "1", files = { { relpath = "kernel/a.lua", size = 9, sha256 = "zz" } } },
            "bad_sha256")
        reject({ version = "1", files = { { relpath = "kernel/a.lua", data = "a", size = 2 } } },
            "size_mismatch")
        reject({ version = "1", files = { { relpath = "kernel/a.lua", data = "a",
            sha256 = H.HEX64 } } }, "sha_mismatch")
        reject({ version = "1", files = {
            { relpath = "kernel/a.lua", data = "a" },
            { relpath = "kernel/a.lua", data = "b" },
        } }, "duplicate")
        reject({ version = "1", files = { { relpath = "kernel/a.lua", data = "a" } },
            manifest_sha = string.rep("f", 64) }, "manifest_sha_mismatch")
        reject({ version = "1", files = {}, manifest_sha = "nothex" }, "bad_manifest_sha")
        reject({ version = "1", files = { { relpath = "kernel/big.lua",
            data = string.rep("x", OTA.F_MAX + 1) } } }, "bad_size")
        local many = {}
        for i = 1, OTA.MAX_FILES + 1 do
            many[i] = { relpath = "kernel/f" .. i .. ".lua", size = 1, sha256 = H.HEX64 }
        end
        reject({ version = "1", files = many }, "too_many_files")

        local inst, inst_lines = reject({ version = "1",
            files = { { relpath = "kernel/a.bin", data = "a" } } }, "bad_ext")
        H.eq("reject_logged", inst.error, "bad_ext")
        H.has(inst_lines, "OTA_SERVER_REJECT why=bad_ext")

        -- an empty set is legal at this layer (the client has its own 1..256
        -- rule and refuses it later, which the faults group proves)
        local empty = server({ manifest = { version = "0.0.1", files = {} } })
        H.eq("empty_error", empty.error, nil)
        H.eq("empty_count", #empty.files, 0)
        H.eq("empty_hash", empty.manifest.manifest_sha, CR.hex(CR.sha256("")))

        -- a manifest with digests but no bytes can describe files, not serve them
        local lazy = server({ manifest = { version = "1.0", files = {
            { relpath = "kernel/a.lua", size = #a, sha256 = sha(a) },
        } } })
        H.eq("lazy_error", lazy.error, nil)
        H.eq("lazy_file", lazy:handle(PREFIX .. " GET 0", 7),
            PREFIX .. " FILE kernel/a.lua " .. tostring(#a) .. " " .. sha(a))
        H.eq("lazy_data", lazy:handle(PREFIX .. " GET 0 0", 7),
            PREFIX .. " ERR reason=no_data")

        -- no SHA-256 -> no manifest
        local nosha = server({ manifest = { version = "1", files = {} }, sha = false,
            loadfile = function() return nil end })
        H.eq("no_sha_error", nosha.error, "no_sha256")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.handle")
    do
        local big = string.rep("w", OTA.MAX_DATA + 100)
        local a, x = "-- a v1\n", "k=v1\n"
        local manifest = {
            version = "9.9.9",
            files = {
                { relpath = "net/x.conf", data = x, size = #x },
                { relpath = "kernel/big.lua", data = big },
                { relpath = "kernel/a.lua", data = a, sha256 = sha(a) },
            },
        }
        local s, log, lines = server({ manifest = manifest })
        H.eq("error", s.error, nil)
        H.eq("order", s.files[1].relpath .. "," .. s.files[2].relpath .. "," .. s.files[3].relpath,
            "kernel/a.lua,kernel/big.lua,net/x.conf")
        H.eq("idx", s.files[3].idx, 2)
        H.eq("aggregate", s.manifest.manifest_sha, OTA.manifest_hash(s.files, CR.sha256))

        -- META: the exact line, then the client's parser on it
        local meta_reply = s:handle(PREFIX .. " GET meta", 7)
        H.eq("meta_reply", meta_reply, PREFIX .. " META version=9.9.9 files=3 manifest_sha="
            .. s.manifest.manifest_sha)
        local pm = OTA.parse_meta(meta_reply)
        H.eq("meta_version", pm and pm.version, "9.9.9")
        H.eq("meta_files", pm and pm.files, 3)
        H.eq("meta_hash", pm and pm.manifest_sha, s.manifest.manifest_sha)

        -- FILE for an index, parsed by the client
        local file_reply = s:handle(PREFIX .. " GET 1", 7)
        H.eq("file_reply", file_reply, PREFIX .. " FILE kernel/big.lua "
            .. tostring(#big) .. " " .. sha(big))
        local pf = OTA.parse_file(file_reply)
        H.eq("file_relpath", pf and pf.relpath, "kernel/big.lua")
        H.eq("file_size", pf and pf.size, #big)
        H.eq("file_sha", pf and pf.sha256, sha(big))

        -- DATA: the first full chunk and the short tail, both through the
        -- client's parser with the request pinned (that is how it is consumed)
        local d0 = s:handle(PREFIX .. " GET 1 0", 7)
        local pd0 = OTA.parse_data(d0, { relpath = "kernel/big.lua", offset = 0, size = #big })
        H.eq("d0_offset", pd0 and pd0.offset, 0)
        H.eq("d0_len", pd0 and #pd0.data, OTA.MAX_DATA)
        H.eq("d0_bytes", pd0 and pd0.data == big:sub(1, OTA.MAX_DATA), true)
        local payload0 = d0:match("(%x+)$")
        H.eq("d0_hex_len", payload0 and #payload0, OTA.MAX_DATA * 2)
        H.eq("d0_hex_lower", payload0, payload0 and payload0:lower())
        H.eq("d0_hex_bytes", payload0, hex_of(big:sub(1, OTA.MAX_DATA)))
        local tail = #big - OTA.MAX_DATA
        local d1 = s:handle(PREFIX .. " GET 1 " .. OTA.MAX_DATA, 7)
        local pd1 = OTA.parse_data(d1, { relpath = "kernel/big.lua", offset = OTA.MAX_DATA,
            size = #big })
        H.eq("d1_offset", pd1 and pd1.offset, OTA.MAX_DATA)
        H.eq("d1_len", pd1 and #pd1.data, tail)
        H.eq("d1_bytes", pd1 and pd1.data == big:sub(OTA.MAX_DATA + 1), true)
        H.eq("d1_echoes_offset", d1 and d1:find(" " .. OTA.MAX_DATA .. " ", 1, true) ~= nil, true)

        -- every malformed request gets an ERR with a stable reason
        local function err_of(msg)
            local reply = s:handle(msg, 7)
            if type(reply) ~= "string" then return nil end
            return reply:match("ERR reason=(%S+)")
        end
        H.eq("unaligned", err_of(PREFIX .. " GET 1 7"), "bad_offset")
        H.eq("at_end", err_of(PREFIX .. " GET 1 " .. #big), "bad_offset")
        H.eq("past_end_aligned", err_of(PREFIX .. " GET 1 " .. (#big + OTA.MAX_DATA)),
            "bad_offset")
        H.eq("offset_text", err_of(PREFIX .. " GET 0 8k"), "bad_offset")
        H.eq("idx_count", err_of(PREFIX .. " GET 3"), "bad_idx")
        H.eq("idx_big", err_of(PREFIX .. " GET 999"), "bad_idx")
        H.eq("idx_negative", err_of(PREFIX .. " GET -1"), "bad_idx")
        H.eq("idx_text", err_of(PREFIX .. " GET abc"), "bad_idx")
        H.eq("bad_verb", err_of(PREFIX .. " PUT meta"), "bad_verb")
        H.eq("no_args", err_of(PREFIX .. " GET"), "bad_request")
        H.eq("meta_extra", err_of(PREFIX .. " GET meta extra"), "bad_request")

        -- traffic that is not ours is ignored, never answered
        H.eq("foreign", s:handle("PYROET-FLASH/2 GET meta", 7), nil)
        H.eq("old_prefix", s:handle("PYROET-OTA/1 GET meta", 7), nil)
        H.eq("not_string", s:handle(nil, 7), nil)
        H.eq("ignored", s.ignored, 3)

        -- describe() prints exactly the replies, one line each
        local described = s:describe()
        H.eq("describe_count", #described, 4)
        H.eq("describe_meta", described[1], PREFIX .. " META version=9.9.9 files=3 manifest_sha="
            .. s.manifest.manifest_sha)
        H.eq("describe_file0", described[2], PREFIX .. " FILE kernel/a.lua "
            .. tostring(#a) .. " " .. sha(a))
        H.eq("describe_file2", described[4], PREFIX .. " FILE net/x.conf "
            .. tostring(#x) .. " " .. sha(x))

        -- counters: one packet per handle, served + errors + ignored == packets
        H.eq("packets_sum", s.packets, s.served + s.errors + s.ignored)
        H.eq("served_exact", s.served, 4)
        H.ge("errors_min", s.errors, 11)
        H.ge("bytes_min", s.bytes, OTA.MAX_DATA + tail)
        H.has(lines, "OTA_SERVER_SEND kind=META")
        H.has(lines, "OTA_SERVER_SEND kind=FILE")
        H.has(lines, "OTA_SERVER_SEND kind=DATA")
        H.has(lines, "OTA_SERVER_ERR reason=bad_offset")
        H.has(lines, "OTA_SERVER_IGNORE why=wrong_protocol")
        H.ascii_check("logs_ascii", H.joined(lines))

        -- an instance whose manifest failed validation answers ERR, not a crash
        local broken = server({})
        H.eq("broken_error", broken.error, "no_manifest")
        H.eq("broken_reply", broken:handle(PREFIX .. " GET meta", 7),
            PREFIX .. " ERR reason=no_manifest")
        H.eq("broken_stats_error", broken.errors, 1)
        -- dot-call form: no instance, so no manifest either
        H.eq("dot_call", SRV.handle(PREFIX .. " GET meta"), PREFIX .. " ERR reason=no_manifest")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.e2e")
    do
        local old_a = "-- a v1\n"
        local a, x = "-- a v2\n", "k=v2\n"
        local big = string.rep("q", OTA.MAX_DATA + 100)
        local total = #a + #big + #x
        local t = stack("e2e", "0.7.0", {
            ["kernel/a.lua"] = a,
            ["kernel/big.lua"] = big,
            ["net/x.conf"] = x,
        }, { old = { ["kernel/a.lua"] = old_a, ["kernel/keep.lua"] = "-- keep\n" } })

        -- the manifest the server built is the one the client verifies against
        H.eq("server_error", t.srv.error, nil)
        H.eq("server_hash", t.srv.manifest.manifest_sha,
            OTA.manifest_hash(t.srv.files, CR.sha256))

        local ok, status = t.c:update()
        H.check("update_ok", ok == true, "err=" .. tostring(status and status.error))
        local st = t.c:status()
        H.eq("state", st.state, "ready")
        H.eq("stage", st.stage, "applied")
        H.eq("count", st.count, 3)
        H.eq("version", st.version, "0.7.0")
        H.eq("manifest", st.manifest_sha, t.srv.manifest.manifest_sha)
        H.eq("bytes", st.bytes, total)
        H.eq("backup_bytes", st.backup, #old_a)

        -- the machine really changed, and only where the manifest said
        H.eq("applied_a", sha_of(t.root .. "/system/kernel/a.lua"), sha(a))
        H.eq("applied_big", H.read(t.root .. "/system/kernel/big.lua"), big)
        H.eq("applied_x", H.read(t.root .. "/system/net/x.conf"), x)
        H.eq("keep_untouched", sha_of(t.root .. "/system/kernel/keep.lua"), sha("-- keep\n"))
        H.eq("backup_a", sha_of(t.root .. "/update.backup/kernel/a.lua"), sha(old_a))
        H.eq("no_backup_for_new", H.exists(t.root .. "/update.backup/kernel/big.lua"), false)

        local rec = journal_of(t.root)
        H.eq("journal_state", rec and rec.state, "applied")
        H.eq("journal_seq", rec and rec.seq, 3)
        H.eq("journal_manifest", rec and rec.manifest_sha, t.srv.manifest.manifest_sha)

        -- the exact wire conversation: manifest first, then every FILE, then the
        -- chunks in apply order (kernel/a.lua, kernel/big.lua two chunks, net/x.conf)
        H.eq("sent_count", #t.w.sent, 8)
        H.eq("sent_1", t.w.sent[1], PREFIX .. " GET meta")
        H.eq("sent_2", t.w.sent[2], PREFIX .. " GET 0")
        H.eq("sent_3", t.w.sent[3], PREFIX .. " GET 1")
        H.eq("sent_4", t.w.sent[4], PREFIX .. " GET 2")
        H.eq("sent_5", t.w.sent[5], PREFIX .. " GET 0 0")
        H.eq("sent_6", t.w.sent[6], PREFIX .. " GET 1 0")
        H.eq("sent_7", t.w.sent[7], PREFIX .. " GET 1 " .. OTA.MAX_DATA)
        H.eq("sent_8", t.w.sent[8], PREFIX .. " GET 2 0")

        -- cross-check: the aggregate the CLIENT recomputed from what it received
        H.eq("client_aggregate", field_of(t.clines, "OTA_MANIFEST", "sha256"),
            t.srv.manifest.manifest_sha:sub(1, 12))
        H.eq("records_full_hash", OTA.manifest_hash(t.srv.files, CR.sha256),
            t.srv.manifest.manifest_sha)
        H.eq("client_meta_hash", field_of(t.clines, "OTA_META", "manifest_sha"),
            t.srv.manifest.manifest_sha:sub(1, 12))

        H.eq("server_packets", t.srv.packets, 8)
        H.eq("server_bytes", t.srv.bytes, total)
        H.eq("server_errors", t.srv.errors, 0)
        H.lacks("server_no_err", t.slines, "OTA_SERVER_ERR")
        H.has(t.slines, "OTA_SERVER_READY version=0.7.0 files=3")
        H.has(t.slines, "OTA_SERVER_SEND kind=META to=12")
        H.has(t.slines, "OTA_SERVER_SEND kind=DATA to=12")
        H.has(t.clines, "OTA_META version=0.7.0 files=3")
        H.has(t.clines, "OTA_READY version=0.7.0 files=3 bytes=" .. tostring(total)
            .. " manifest_sha=" .. t.srv.manifest.manifest_sha:sub(1, 12))
        H.ascii_check("server_logs_ascii", H.joined(t.slines))
        H.ascii_check("client_logs_ascii", H.joined(t.clines))
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.faults")
    do
        -- 1) a server whose META lies about manifest_sha: the client refuses at
        -- stage=verify and changes nothing (nothing was downloaded to /system)
        local old_a = "-- a v1\n"
        local t = stack("lie_manifest", "1.0.0", { ["kernel/a.lua"] = "-- a v2\n" },
            { old = { ["kernel/a.lua"] = old_a } })
        local good_hash = t.srv.manifest.manifest_sha
        t.srv.manifest.manifest_sha = string.rep("f", 64)
        local ok, err = t.c:update()
        H.check("lie_ok", ok == nil and type(err) == "string", "ok=" .. tostring(ok))
        H.eq("lie_err", err, "manifest_sha")
        H.eq("lie_state", t.c:status().state, "rejected")
        H.eq("lie_stage", t.c:status().stage, "verify")
        H.has(t.clines, "OTA_REJECT stage=verify reason=manifest_sha got="
            .. good_hash:sub(1, 12) .. " want=" .. string.rep("f", 12))
        H.eq("lie_system_untouched", sha_of(t.root .. "/system/kernel/a.lua"), sha(old_a))
        H.eq("lie_no_journal", journal_of(t.root), nil)
        H.eq("lie_no_backup", H.exists(t.root .. "/update.backup"), false)
        H.eq("lie_no_stage", H.exists(t.root .. "/update.stage"), false)
        H.lacks("lie_no_fail", t.clines, "OTA_FAIL")
        H.ge("lie_server_served", t.srv.served, 2)

        -- retry() after the publisher fixes the mirror: same client, same disk
        t.srv.manifest.manifest_sha = good_hash
        local ok2 = t.c:retry()
        H.check("retry_ok", ok2 == true, "retry failed")
        H.eq("retry_state", t.c:status().state, "ready")
        H.has(t.clines, "OTA_RETRY_FROM state=rejected")
        H.eq("retry_applied", sha_of(t.root .. "/system/kernel/a.lua"), sha("-- a v2\n"))

        -- 2) tampered bytes behind a correct digest: the manifest still verifies
        -- (FILE lines are honest), the download digest fails, the update rolls
        -- back and the machine is exactly where it started
        local t2 = stack("tamper_data", "1.0.1", { ["kernel/a.lua"] = "-- a v2\n" },
            { old = { ["kernel/a.lua"] = old_a } })
        t2.srv.files[1].data = "-- b v2\n"
        local ok3, err3 = t2.c:update()
        H.check("tamper_ok", ok3 == nil and type(err3) == "string", "ok=" .. tostring(ok3))
        H.eq("tamper_state", t2.c:status().state, "rolled_back")
        H.eq("tamper_stage", t2.c:status().stage, "chunk")
        H.has(t2.clines, "OTA_FAIL stage=chunk")
        H.has(t2.clines, "OTA_ROLLED_BACK stage=chunk")
        H.eq("tamper_system_old", sha_of(t2.root .. "/system/kernel/a.lua"), sha(old_a))
        H.eq("tamper_journal", journal_of(t2.root).state, "rolledback")
        H.eq("tamper_no_part", H.exists(t2.root .. "/update.stage"), false)

        -- 3) a lost DATA reply: one retransmission, the update still lands
        local big = string.rep("q", OTA.MAX_DATA + 100)
        local t3 = stack("drop_data", "1.0.2", { ["kernel/big.lua"] = big }, { drop_data = 1 })
        H.check("drop_ok", t3.c:update() == true, "one lost chunk broke the update")
        H.eq("drop_dropped", t3.w.dropped, 1)
        H.has(t3.clines, "OTA_RETRY attempt=1 max=2 err=timeout")
        H.eq("drop_applied", H.read(t3.root .. "/system/kernel/big.lua"), big)
        H.eq("drop_resent", t3.w.sent[3] .. "|" .. t3.w.sent[4],
            (PREFIX .. " GET 0 0") .. "|" .. (PREFIX .. " GET 0 0"))
        H.eq("drop_tail", t3.w.sent[5], PREFIX .. " GET 0 " .. OTA.MAX_DATA)
        H.eq("drop_requests", #t3.w.sent, 5)

        -- 4) a lost request (the client never reaches the server): retried
        local t4 = stack("drop_request", "1.0.3", { ["kernel/a.lua"] = "-- a v3\n" },
            { drop_request = 1 })
        H.check("drop_request_ok", t4.c:update() == true, "a lost request broke the update")
        H.has(t4.clines, "OTA_RETRY attempt=1 max=2 err=timeout")
        H.eq("drop_request_sent", t4.w.sent[1], PREFIX .. " GET meta")
        H.eq("drop_request_sent2", t4.w.sent[2], PREFIX .. " GET meta")
        H.eq("drop_request_packets", t4.srv.packets, 3)

        -- 5) files=0: legal for the server (the empty-set hash of 3.2), refused
        -- by the client, which requires 1..256
        local empty = server({ manifest = { version = "0.0.1", files = {} } })
        H.eq("empty_server_ok", empty.error, nil)
        H.eq("empty_meta", empty:handle(PREFIX .. " GET meta", 7),
            PREFIX .. " META version=0.0.1 files=0 manifest_sha=" .. CR.hex(CR.sha256("")))
        local empty_raw = empty:handle(PREFIX .. " GET meta", 7)
        H.eq("empty_meta_client", select(2, OTA.parse_meta(empty_raw)), "bad files")
        H.eq("empty_meta_hash_text", empty_raw:match("manifest_sha=(%x+)$"),
            OTA.manifest_hash({}, CR.sha256))
        local w5 = wire(empty)
        local root5 = sandbox("files_zero")
        local c5, _, clines5 = client(root5, w5.rednet)
        local ok5, err5 = c5:update()
        H.check("zero_ok", ok5 == nil, "ok=" .. tostring(ok5))
        H.eq("zero_err", err5, "bad files")
        H.eq("zero_state", c5:status().state, "failed")
        H.has(clines5, "OTA_FAIL stage=meta err=bad files")

        -- 6) oversized file: the server will not publish what the client cannot
        -- parse, and the client's own reason is the same class of refusal
        local huge = server({ manifest = { version = "1", files = {
            { relpath = "kernel/huge.lua", size = OTA.F_MAX + 1, sha256 = H.HEX64 },
        } } })
        H.eq("huge_nil", huge.files, nil)
        H.eq("huge_why", huge.error, "bad_size")
        H.eq("huge_client", select(2, OTA.parse_file(PREFIX .. " FILE kernel/huge.lua "
            .. tostring(OTA.F_MAX + 1) .. " " .. H.HEX64)), "bad size")

        -- 7) a path outside the whitelist never reaches the wire
        local pub = publish("evil_path", "1", {})
        H.write(pub .. "/kernel/evil.bin", "x")
        local m, why_path, path = build(pub)
        H.eq("evil_nil", m, nil)
        H.eq("evil_why", why_path, "bad_ext")
        H.eq("evil_path", path, "kernel/evil.bin")
        H.eq("evil_client", select(2, OTA.valid_path("kernel/evil.bin")), "bad_ext")
        local bad_path_srv = server({ manifest = { version = "1", files = {
            { relpath = "../etc/passwd.lua", size = 1, sha256 = H.HEX64 },
        } } })
        H.eq("bad_relpath_why", bad_path_srv.error, "bad_path")
        H.eq("bad_relpath_client", select(2, OTA.valid_path("../etc/passwd.lua")), "bad_path")
    end

    -- -----------------------------------------------------------------
    H.group("ota_server.serve")
    do
        local a = "-- a v1\n"
        local s, log, lines = server({ manifest = { version = "3.0.0", files = {
            { relpath = "kernel/a.lua", data = a },
        } } })
        H.eq("serve_error", s.error, nil)
        local inbox = {
            PREFIX .. " GET meta", PREFIX .. " GET 0", PREFIX .. " GET 0 0", "HELLO",
        }
        local outbox = {}
        s.rednet = {
            receive = function(protocol, timeout)
                if #inbox == 0 then
                    s:stop()
                    return nil
                end
                local item = table.remove(inbox, 1)
                return 7, item
            end,
            send = function(to, msg, protocol)
                outbox[#outbox + 1] = { to = to, msg = msg, protocol = protocol }
                return true
            end,
        }
        H.eq("serve_return", s:serve(), true)
        H.eq("stopped", s.running, false)
        H.eq("outbox_count", #outbox, 3)
        H.eq("outbox_to", outbox[1] and outbox[1].to, 7)
        H.eq("outbox_protocol", outbox[1] and outbox[1].protocol, OTA.PROTOCOL)
        H.eq("outbox_meta", outbox[1] and outbox[1].msg, PREFIX .. " META version=3.0.0 files=1"
            .. " manifest_sha=" .. s.manifest.manifest_sha)
        H.eq("outbox_file", outbox[2] and outbox[2].msg, PREFIX .. " FILE kernel/a.lua "
            .. tostring(#a) .. " " .. sha(a))
        H.eq("outbox_data", outbox[3] and outbox[3].msg, PREFIX .. " DATA kernel/a.lua 0 "
            .. hex_of(a))
        H.eq("serve_packets", s.packets, 4)
        H.eq("serve_served", s.served, 3)
        H.eq("serve_ignored", s.ignored, 1)
        H.eq("serve_bytes", s.bytes, #a)
        H.has(lines, "OTA_SERVER_START protocol=pyroet-ota version=3.0.0 files=1")
        H.has(lines, "OTA_SERVER_STOP packets=4 served=3")
        H.has(lines, "OTA_SERVER_IGNORE why=wrong_protocol to=7")

        -- no rednet: refuse to spin
        local bare, _, bare_lines = server({ manifest = { version = "1", files = {} } })
        bare.rednet = nil
        local ok, why = bare:serve()
        H.eq("no_rednet_ok", ok, nil)
        H.eq("no_rednet_why", why, "no_rednet")
        H.has(bare_lines, "OTA_SERVER_NO_REDNET")

        -- a broken manifest is refused before the loop starts
        local bad, _, bad_lines = server({})
        bad.rednet = { receive = function() return nil end, send = function() end }
        local ok2, why2 = bad:serve()
        H.eq("no_manifest_ok", ok2, nil)
        H.eq("no_manifest_why", why2, "no_manifest")
        H.has(bad_lines, "OTA_SERVER_NO_MANIFEST")

        -- receive() raising stops the loop instead of killing the task
        local crash, _, crash_lines = server({ manifest = { version = "1", files = {} } })
        crash.rednet = {
            receive = function() error("modem unplugged") end,
            send = function() end,
        }
        local ok3, why3 = crash:serve()
        H.eq("recv_fail_ok", ok3, nil)
        H.eq("recv_fail_why", why3, "receive_failed")
        H.eq("recv_fail_running", crash.running, false)
        H.has(crash_lines, "OTA_SERVER_RECV_FAIL")

        -- stop() before/after serve is idempotent and harmless
        H.eq("stop_return", s:stop(), true)
        H.eq("stop_again", s:stop(), true)
    end
end
