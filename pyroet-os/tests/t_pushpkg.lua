--[[- pyroet-os/tests/t_pushpkg.lua -- tools/pushpkg.lua, the OTHER computer.

pushpkg is a development tool, not image payload: run-tests.ps1 copies it to
/tests/pushpkg.lua. Everything around it is faked here -- http is a URL -> body
map, rednet is a scripted transport, the file system only answers
/etc/pushpkg.conf -- so the tool's own parsing, wrapping, chunking, ack/retry
and logging are what these groups assert.

No non-ASCII bytes in this file.
]]

rawset(_G, "PYROET_PUSHPKG_TEST", true)
local P = assert(loadfile("/tests/pushpkg.lua"))()
rawset(_G, "PYROET_PUSHPKG_TEST", nil)

return function(H)
    local function http_from(map)
        return { get = function(url)
            local item = map[url]
            if item == nil then return nil, "not found" end
            if type(item) == "table" then return item end
            return { ok = true, status = 200, body = item }
        end }
    end

    local function env_with(opts)
        local o = opts or {}
        local env = {
            http = o.http or http_from({}),
            rednet = o.rednet,
            peripheral = o.peripheral or { getNames = function() return {} end },
            clock = o.clock or function() return 0 end,
            logs = {},
        }
        env.fs = { read = function(path)
            if o.conf ~= nil and path == P.CONF then return o.conf end
            return nil, "not found"
        end }
        env.log = function(line)
            env.logs[#env.logs + 1] = tostring(line)
        end
        return env
    end

    local function fake_net(opts)
        local o = opts or {}
        local net = { sent = {}, broadcasts = {}, opened = {}, received = 0 }
        net.inbox = {}
        net.silent = o.silent or 0
        function net.push(sender, msg)
            net.inbox[#net.inbox + 1] = { sender = sender, msg = msg }
        end
        net.receive = function(protocol, timeout)
            net.received = net.received + 1
            net.last_timeout = timeout
            if net.silent > 0 then
                net.silent = net.silent - 1
                table.remove(net.inbox, 1)
                return nil
            end
            local item = table.remove(net.inbox, 1)
            if item == nil then return nil end
            return item.sender, item.msg
        end
        net.send = function(dest, msg, protocol)
            net.sent[#net.sent + 1] = { dest = dest, msg = msg,
                protocol = protocol }
            if o.ack ~= false then
                local ack = o.on_send and o.on_send(msg, dest)
                    or { kind = "ack", ok = true }
                net.push(dest, ack)
            end
            return true
        end
        net.broadcast = function(msg, protocol)
            net.broadcasts[#net.broadcasts + 1] = { msg = msg,
                protocol = protocol }
            if o.ack ~= false then
                local ack = o.on_send and o.on_send(msg, nil)
                    or { kind = "ack", ok = true }
                net.push(1, ack)
            end
            return true
        end
        net.open = function(name)
            net.opened[#net.opened + 1] = name
            return true
        end
        return net
    end

    local MANIFEST = 'return { name = "demo", version = "1.0.0" }\n'
    local MAIN = "return function(manifest, api) return nil end\n"
    local BASE = "http://example.com/pkg/"

    local function demo_pkg()
        return { name = "demo", version = "1.0.0", kind = "app",
            files = { { rel = "manifest.lua", body = MANIFEST },
                { rel = "main.lua", body = MAIN } } }
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.sha")
    do
        H.check("sha_ready", P.sha_ready() == true, "no bit32/bit on this host")
        H.eq("sha_abc", P.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        H.eq("sha_empty", P.sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        H.eq("sha_64", #(P.sha256("x") or ""), 64)
        -- the digest formula is order independent (rels are sorted)
        local one = P.digest_of({ { rel = "a", body = "1" },
            { rel = "b", body = "2" } })
        local two = P.digest_of({ { rel = "b", body = "2" },
            { rel = "a", body = "1" } })
        H.eq("digest_sorted", one, two)
        H.eq("digest_formula", one, P.sha256("a\n1b\n2"))
        H.eq("digest_empty", P.digest_of({}), nil)
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.conf")
    do
        local conf = P.parse_conf(nil)
        H.eq("conf_default_server", conf.server, P.SERVER)
        -- the host tool and appstore share the 2026-11-01 default: the project
        -- store, not a .invalid placeholder
        H.eq("conf_builtin_server", P.SERVER, "http://store.pyrotechnic.org/")
        H.check("conf_no_invalid", (P.SERVER or ""):find("invalid", 1, true) == nil,
            "pushpkg still defaults to a placeholder server")
        H.eq("conf_default_protocol", conf.protocol, "PYROET-PKG/1")
        H.eq("conf_default_timeout", conf.timeout, 5)
        H.eq("conf_path", P.CONF, "/etc/pushpkg.conf")
        local parsed = P.parse_conf(
            "# comment\nserver=http://host/pkg/\nprotocol=PYROET-PKG/2\n"
            .. "channel=4200\ntimeout=9\n")
        H.eq("conf_server", parsed.server, "http://host/pkg/")
        H.eq("conf_protocol", parsed.protocol, "PYROET-PKG/2")
        H.eq("conf_channel", parsed.channel, 4200)
        H.eq("conf_timeout", parsed.timeout, 9)
        local bad = P.parse_conf("server=ftp://x/\nchannel=0\ntimeout=-1\n"
            .. "protocol=two words\n")
        H.eq("conf_bad_server", bad.server, P.SERVER)
        H.eq("conf_bad_channel", bad.channel, nil)
        H.eq("conf_bad_timeout", bad.timeout, P.TIMEOUT)
        H.eq("conf_bad_protocol", bad.protocol, P.PROTOCOL)
        local env = env_with({ conf = "server=http://c/\nprotocol=P2\n" })
        local loaded, note = P.conf(env)
        H.eq("conf_loaded", loaded.server, "http://c/")
        H.eq("conf_loaded_protocol", loaded.protocol, "P2")
        H.eq("conf_loaded_note", note, nil)
        local missing, why = P.conf(env_with({}))
        H.eq("conf_missing_server", missing.server, P.SERVER)
        H.eq("conf_missing_note", why, "no conf")
        local none, fswhy = P.conf({})
        H.eq("conf_no_fs_reason", fswhy, "no fs")
        H.eq("conf_no_fs_server", none.server, P.SERVER)
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.index")
    do
        local entries, bad = P.parse_index(
            "app demo 1.0.0 demo\nlua hello 0.1.0 hello.lua\ngarbage\n"
            .. "zip x 1.0 d\napp bad/name 1.0 d\napp v 1.0 x..y\n", BASE)
        H.eq("index_entries", #entries, 2)
        H.eq("index_bad", bad, 4)
        H.eq("index_app_kind", entries[1].kind, "app")
        H.eq("index_app_dir", entries[1].dir, "demo")
        H.eq("index_app_base", entries[1].base, BASE)
        H.eq("index_lua_kind", entries[2].kind, "lua")
        H.eq("index_lua_dir", entries[2].dir, "hello.lua")
        H.eq("index_demo_version", entries[1].version, "1.0.0")
        -- trailing whitespace and CRLF are tolerated
        local clean = P.parse_index("app one 1.0 a\r\n\r\n", BASE)
        H.eq("index_clean", #clean, 1)
        H.eq("index_empty", #(P.parse_index("", BASE)), 0)
        -- long names and paths stay out
        local _, long_bad = P.parse_index("app " .. string.rep("a", 41)
            .. " 1.0 d\n", BASE)
        H.eq("index_long_name", long_bad, 1)
        local _2, path_bad = P.parse_index("app x 1.0 "
            .. string.rep("p", 200) .. "\n", BASE)
        H.eq("index_long_dir", path_bad, 1)
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.wrap")
    do
        local files = P.wrap_lua("hello", "0.1.0", "print('hi')\n")
        H.eq("wrap_files", #files, 2)
        H.eq("wrap_manifest_rel", files[1].rel, "manifest.lua")
        H.eq("wrap_main_rel", files[2].rel, "main.lua")
        H.eq("wrap_main_body", files[2].body, "print('hi')\n")
        H.contains("wrap_name", files[1].body, 'name = "hello"')
        H.contains("wrap_version", files[1].body, 'version = "0.1.0"')
        H.contains("wrap_entry", files[1].body, 'entry = "main.lua"')
        H.contains("wrap_read", files[1].body, '"fs.read"')
        H.contains("wrap_input", files[1].body, '"input"')
        H.contains("wrap_terminal", files[1].body, '"terminal"')
        -- a real index entry + http map loads and wraps the single file
        local index_body = "lua hello 0.1.0 hello.lua\n"
        local entries = P.parse_index(index_body, BASE)
        H.eq("wrap_index_entries", #entries, 1)
        local env = env_with({ http = http_from({
            [BASE .. "hello.lua"] = "print('hi')\n",
        }) })
        local pkg, err = P.load_package(env, { server = BASE }, entries[1])
        H.eq("wrap_load_err", err, nil)
        H.check("wrap_load_pkg", type(pkg) == "table", "no package")
        H.eq("wrap_load_kind", pkg and pkg.kind, "lua")
        H.eq("wrap_load_name", pkg and pkg.name, "hello")
        H.eq("wrap_load_files", pkg and #pkg.files, 2)
        H.eq("wrap_load_main", pkg and pkg.files[2].body, "print('hi')\n")
        -- a 404 on the lua file is a clean failure
        local env404 = env_with({ http = http_from({}) })
        local none, why = P.load_package(env404, { server = BASE }, entries[1])
        H.eq("wrap_load_none", none, nil)
        H.contains("wrap_load_why", tostring(why), "lua ")
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.app")
    do
        local index = P.parse_index("app demo 1.0.0 demo\n", BASE)
        local function server(extra)
            local map = {
                [BASE .. "demo/files.txt"] = "manifest.lua\nmain.lua\n",
                [BASE .. "demo/manifest.lua"] = MANIFEST,
                [BASE .. "demo/main.lua"] = MAIN,
            }
            for key, value in pairs(extra or {}) do map[key] = value end
            return map
        end
        -- every file arrives and is handed to the stream as {rel, body}
        local env = env_with({ http = http_from(server()) })
        local pkg, err = P.load_package(env, { server = BASE }, index[1])
        H.eq("app_load_err", err, nil)
        H.eq("app_load_kind", pkg and pkg.kind, "app")
        H.eq("app_load_files", pkg and #pkg.files, 2)
        H.eq("app_load_manifest", pkg and pkg.files[1].body, MANIFEST)
        H.eq("app_load_main", pkg and pkg.files[2].body, MAIN)
        -- the optional checksum list is verified before anything is sent
        local good = server({ [BASE .. "demo/SHA256.txt"] =
            P.sha256(MANIFEST) .. " manifest.lua\n"
            .. P.sha256(MAIN) .. " main.lua\n" })
        local checked = P.load_package(env_with({ http = http_from(good) }),
            { server = BASE }, index[1])
        H.check("app_sha_ok", checked ~= nil, "a verified package was refused")
        local bad = server({ [BASE .. "demo/SHA256.txt"] =
            string.rep("0", 64) .. " main.lua\n" })
        local refused, why = P.load_package(env_with({ http = http_from(bad) }),
            { server = BASE }, index[1])
        H.eq("app_sha_bad", refused, nil)
        H.eq("app_sha_bad_why", why, "sha256 main.lua")
        -- the package must ship a manifest (the receiver publishes an .app)
        local no_manifest = server({ [BASE .. "demo/files.txt"] = "main.lua\n" })
        local nm, nmwhy = P.load_package(env_with({ http = http_from(no_manifest) }),
            { server = BASE }, index[1])
        H.eq("app_no_manifest", nm, nil)
        H.eq("app_no_manifest_why", nmwhy, "no manifest.lua")
        -- files.txt itself is required, and a bad path in it is refused
        local no_files = server({})
        no_files[BASE .. "demo/files.txt"] = nil
        local nf, nfwhy = P.load_package(env_with({ http = http_from(no_files) }),
            { server = BASE }, index[1])
        H.eq("app_no_files", nf, nil)
        H.contains("app_no_files_why", tostring(nfwhy), "files ")
        local bad_path = server({ [BASE .. "demo/files.txt"] = "../etc/passwd\n" })
        local bp, bpwhy = P.load_package(env_with({ http = http_from(bad_path) }),
            { server = BASE }, index[1])
        H.eq("app_bad_path", bp, nil)
        H.contains("app_bad_path_why", tostring(bpwhy), "bad path")
        -- a missing file body is named, not silently skipped
        local missing = server({})
        missing[BASE .. "demo/main.lua"] = nil
        local mp, mpwhy = P.load_package(env_with({ http = http_from(missing) }),
            { server = BASE }, index[1])
        H.eq("app_missing_file", mp, nil)
        H.contains("app_missing_file_why", tostring(mpwhy), "fetch main.lua")
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.chunks")
    do
        local body = string.rep("x", 9000)
        local list = P.chunks(body)
        H.eq("chunks_count", #list, 2)
        H.eq("chunks_first", #list[1], P.CHUNK)
        H.eq("chunks_second", #list[2], 9000 - P.CHUNK)
        H.eq("chunks_join", #(list[1] .. list[2]), #body)
        H.eq("chunks_chunk_size", P.CHUNK, 8192)
        local empty = P.chunks("")
        H.eq("chunks_empty_count", #empty, 1)
        H.eq("chunks_empty_body", empty[1], "")
        local exact = P.chunks(string.rep("y", P.CHUNK))
        H.eq("chunks_exact_count", #exact, 1)
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.send")
    do
        local net = fake_net()
        local env = env_with({ rednet = net })
        local conf = P.parse_conf(nil)
        local pkg = demo_pkg()
        pkg.files[2].body = string.rep("z", 9000)      -- two chunks
        local report, err = P.send_package(env, net, 12, conf, pkg)
        H.eq("send_err", err, nil)
        H.check("send_report", type(report) == "table", "no report")
        H.eq("send_name", report and report.name, "demo")
        H.eq("send_files", report and report.files, 2)
        H.eq("send_bytes", report and report.bytes,
            #MANIFEST + 9000)
        H.eq("send_sha", report and report.sha, P.digest_of(pkg.files))
        -- begin, one file chunk for the manifest, two for main, end
        H.eq("send_messages", #net.sent, 5)
        H.eq("send_begin_kind", net.sent[1].msg.kind, "begin")
        H.eq("send_begin_name", net.sent[1].msg.name, "demo")
        H.eq("send_begin_version", net.sent[1].msg.version, "1.0.0")
        H.eq("send_begin_pkg", net.sent[1].msg.pkg, "app")
        H.eq("send_begin_files", net.sent[1].msg.files, 2)
        H.eq("send_begin_dest", net.sent[1].dest, 12)
        H.eq("send_begin_protocol", net.sent[1].protocol, "PYROET-PKG/1")
        H.eq("send_file_kind", net.sent[2].msg.kind, "file")
        H.eq("send_file_rel", net.sent[2].msg.rel, "manifest.lua")
        H.eq("send_file_chunk", net.sent[2].msg.chunk, 1)
        H.eq("send_file_chunks", net.sent[2].msg.chunks, 1)
        H.eq("send_chunked_rel", net.sent[3].msg.rel, "main.lua")
        H.eq("send_chunked_first", net.sent[3].msg.chunk, 1)
        H.eq("send_chunked_chunks", net.sent[3].msg.chunks, 2)
        H.eq("send_chunked_second", net.sent[4].msg.chunk, 2)
        H.eq("send_end_kind", net.sent[5].msg.kind, "end")
        H.eq("send_end_sha", net.sent[5].msg.sha, P.digest_of(pkg.files))
        H.eq("send_begin_has_no_data", net.sent[1].msg.data, nil)
        H.eq("send_end_has_no_data", net.sent[5].msg.data, nil)
        H.check("send_chunk_limit",
            #(net.sent[3].msg.data) <= P.CHUNK and #(net.sent[4].msg.data) <= P.CHUNK,
            "a chunk exceeded 8 KiB")
        -- logs are the documented ones
        H.has(env.logs, "PUSHPKG_BEGIN name=demo pkg=app files=2")
        H.has(env.logs, "PUSHPKG_FILE rel=manifest.lua bytes=")
        H.has(env.logs, "PUSHPKG_FILE rel=main.lua bytes=9000 chunks=2")
        H.has(env.logs, "PUSHPKG_END name=demo ok=true files=2 bytes=")
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.retry")
    do
        -- two lost acks cost two retries and the package still arrives
        local net = fake_net({ silent = 2 })
        local env = env_with({ rednet = net })
        local report, err = P.send_package(env, net, 7,
            P.parse_conf(nil), demo_pkg())
        H.eq("retry_err", err, nil)
        H.check("retry_report", type(report) == "table", "no report")
        H.eq("retry_lines", H.count(env.logs, "PUSHPKG_RETRY"), 2)
        H.has(env.logs, "PUSHPKG_RETRY attempt=1 max=2")
        H.has(env.logs, "PUSHPKG_RETRY attempt=2 max=2")
        H.eq("retry_all_ok", #net.sent, 6)
        -- an ack with ok=false is the receiver's answer: no retry, no stream
        local refused = fake_net({ on_send = function(msg)
            if msg.kind == "begin" then
                return { kind = "ack", ok = false, err = "busy" }
            end
            return { kind = "ack", ok = true }
        end })
        local env2 = env_with({ rednet = refused })
        local none, why = P.send_package(env2, refused, 7,
            P.parse_conf(nil), demo_pkg())
        H.eq("nack_send_none", none, nil)
        H.eq("nack_send_why", why, "busy")
        H.eq("nack_messages", #refused.sent, 1)
        H.eq("nack_no_retry", H.count(env2.logs, "PUSHPKG_RETRY"), 0)
        -- a file refused after the begin aborts the stream
        local half = fake_net({ on_send = function(msg)
            if msg.kind == "file" then
                return { kind = "ack", ok = false, err = "write check failed" }
            end
            return { kind = "ack", ok = true }
        end })
        local env3 = env_with({ rednet = half })
        local hnone, hwhy = P.send_package(env3, half, 7,
            P.parse_conf(nil), demo_pkg())
        H.eq("half_none", hnone, nil)
        H.eq("half_why", hwhy, "write check failed")
        H.eq("half_last_kind", half.sent[#half.sent].msg.kind, "abort")
        -- no ack at all: the ack timeout ends each attempt, and it gives up
        local ticking = 0
        local silent = fake_net({ ack = false })
        local env4 = env_with({ rednet = silent, clock = function()
            ticking = ticking + 1
            return ticking
        end })
        local tnone, twhy = P.send_package(env4, silent, 7,
            P.parse_conf("timeout=2\n"), demo_pkg())
        H.eq("timeout_none", tnone, nil)
        H.eq("timeout_why", twhy, "timeout")
        H.eq("timeout_retries", H.count(env4.logs, "PUSHPKG_RETRY"), 2)
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.run")
    do
        local function server()
            return {
                [BASE .. "index.txt"] = "app demo 1.0.0 demo\n"
                    .. "lua hello 0.1.0 hello.lua\n",
                [BASE .. "demo/files.txt"] = "manifest.lua\nmain.lua\n",
                [BASE .. "demo/manifest.lua"] = MANIFEST,
                [BASE .. "demo/main.lua"] = MAIN,
                [BASE .. "hello.lua"] = "print('hi')\n",
            }
        end
        local env = env_with({ http = http_from(server()),
            rednet = fake_net(), conf = "server=" .. BASE .. "\n" })
        local reports, err = P.run(env, { "12" })
        H.eq("run_err", err, nil)
        H.eq("run_reports", type(reports) == "table" and #reports, 2)
        H.eq("run_first", reports and reports[1].name, "demo")
        H.eq("run_second", reports and reports[2].name, "hello")
        H.eq("run_begins", H.count(env.logs, "PUSHPKG_BEGIN"), 2)
        H.eq("run_ends", H.count(env.logs, "PUSHPKG_END"), 2)
        H.has(env.logs, "PUSHPKG_TARGET target=12 protocol=PYROET-PKG/1")
        H.has(env.logs, "PUSHPKG_INDEX entries=2 bad=0")
        H.has(env.logs, "PUSHPKG_BEGIN name=hello pkg=lua files=2")
        -- a name selects exactly one package
        local one_env = env_with({ http = http_from(server()),
            rednet = fake_net(), conf = "server=" .. BASE .. "\n" })
        local one = P.run(one_env, { "12", "hello" })
        H.eq("run_one", type(one) == "table" and #one, 1)
        H.eq("run_one_name", one and one[1].name, "hello")
        H.eq("run_one_begins", H.count(one_env.logs, "PUSHPKG_BEGIN"), 1)
        -- broadcast uses rednet.broadcast for every message
        local cast = fake_net()
        local cast_env = env_with({ http = http_from(server()),
            rednet = cast, conf = "server=" .. BASE .. "\n" })
        local cast_reports = P.run(cast_env, { "broadcast", "hello" })
        H.eq("run_broadcast", type(cast_reports) == "table" and #cast_reports, 1)
        H.has(cast_env.logs, "PUSHPKG_TARGET target=broadcast")
        H.check("run_broadcast_used", #cast.broadcasts >= 4, "no broadcast calls")
        H.eq("run_broadcast_sends", #cast.sent, 0)
        -- a bad target, a missing index and an unknown name are clean failures
        local bad = P.run(env_with({ rednet = fake_net() }), { "nowhere" })
        H.eq("run_bad_target", bad, nil)
        local bad_env = env_with({ http = http_from({}), rednet = fake_net() })
        local no_index, index_why = P.run(bad_env, { "12" })
        H.eq("run_no_index", no_index, nil)
        H.eq("run_no_index_why", index_why, "index")
        H.has(bad_env.logs, "PUSHPKG_FAIL err=index")
        local ghost, ghost_why = P.run(env, { "12", "ghost" })
        H.eq("run_ghost", ghost, nil)
        H.eq("run_ghost_why", ghost_why, "no such package")
        local empty_env = env_with({ http = http_from({
            [BASE .. "index.txt"] = "" }), rednet = fake_net(),
            conf = "server=" .. BASE .. "\n" })
        local empty, empty_why = P.run(empty_env, { "12" })
        H.eq("run_empty", empty, nil)
        H.eq("run_empty_why", empty_why, "empty index")
        -- no rednet at all: named, and no http request is made
        local saved_net = rawget(_G, "rednet")
        rawset(_G, "rednet", nil)
        local naked = env_with({ http = http_from(server()) })
        local none, net_why = P.run(naked, { "12" })
        rawset(_G, "rednet", saved_net)
        H.eq("run_no_rednet", none, nil)
        H.eq("run_no_rednet_why", net_why, "no_rednet")
        H.has(naked.logs, "PUSHPKG_FAIL err=no_rednet")
        -- a package that fails to download does not stop the next one
        local partial = server()
        partial[BASE .. "demo/files.txt"] = nil
        local part_env = env_with({ http = http_from(partial),
            rednet = fake_net(), conf = "server=" .. BASE .. "\n" })
        local pulled = P.run(part_env, { "12" })
        H.eq("run_partial", type(pulled) == "table" and #pulled, 1)
        H.eq("run_partial_name", pulled and pulled[1].name, "hello")
        H.has(part_env.logs, "PUSHPKG_FAIL name=demo err=files ")
    end

    -- -----------------------------------------------------------------
    H.group("pushpkg.entry")
    do
        H.eq("entry_version", P.VERSION, "0.1.0")
        H.eq("entry_protocol", P.PROTOCOL, "PYROET-PKG/1")
        H.eq("entry_conf", P.CONF, "/etc/pushpkg.conf")
        H.eq("entry_retries", P.RETRIES, 2)
        H.eq("entry_chunk", P.CHUNK, 8192)
        H.ascii_check("pushpkg_ascii", H.read("/tests/pushpkg.lua") or "")
        local entry = assert(loadfile("/tests/pushpkg.lua"))()
        H.eq("entry_is_program", type(entry), "function")
    end
end
