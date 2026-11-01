--[[- pyroet-os/tests/t_appstore.lua -- the package downloader (system/system/appstore.app).

The server is plain RHTP + plain text: index.txt, <dir>/files.txt, the files
themselves and an optional SHA256.txt. The RHTP client is faked here (a URL ->
body map behind api.net.rhtp_get) and the file system is the real one, so the
staged package is inspected on disk.

No non-ASCII bytes in this file.
]]

_G.PYROET_APPSTORE_TEST = true
local P = assert(loadfile("/system/system/appstore.app/main.lua"))()
_G.PYROET_APPSTORE_TEST = nil

local KEYS = { up = 10, down = 11, enter = 14, q = 16, a = 17, r = 19,
    backspace = 21 }

return function(H)
    local F = H.real_fs()

    -- one RHTP GET over a URL -> body map: the net service answers (body) or
    -- (nil, "rhtp 404"), exactly like the real client
    local function rhtp_from(map)
        local calls = {}
        local fake = {}
        fake.get = function(url)
            calls[#calls + 1] = url
            local item = map[url]
            if item == nil then return nil, "rhtp 404" end
            if type(item) == "table" then return item.body, item.err end
            return item, nil
        end
        fake.fetch = fake.get
        return fake, calls
    end

    -- the appstore no longer touches api.http at all: only api.net.rhtp_get
    local function api_with(rhtp, sys)
        local log, lines = H.logger()
        local api = {
            fs = {
                read = function(path)
                    if not F.exists(path) then return nil, "not found" end
                    return H.read(path)
                end,
                list = function(path)
                    if not F.exists(path) then return nil, "not found" end
                    return F.list(path)
                end,
                exists = function(path) return F.exists(path) end,
                isDir = function(path) return F.isDir(path) end,
                makeDir = function(path)
                    pcall(F.makeDir, path)
                    return true
                end,
                write = function(path, body)
                    local ok = pcall(H.write, path, body)
                    return ok
                end,
                delete = function(path) return pcall(F.delete, path) end,
                move = function(a, b) return pcall(F.move, a, b) end,
            },
            net = {
                rhtp_get = rhtp and rhtp.get or nil,
                rhtp_fetch = rhtp and rhtp.fetch or nil,
            },
            sys = sys,
            input = { keys = KEYS, pullEvent = function() return nil end },
            yield = function() end,
            log = log,
        }
        return api, lines
    end

    local BASE = "rhtp://example.com/pkg/"
    local function server()
        return {
            [BASE .. "index.txt"] = "app demo 1.0.0 demo\napp other 2.0.0 other\n"
                .. "garbage line\napp bad/name 1.0 x\n",
            [BASE .. "demo/files.txt"] = "manifest.lua\nmain.lua\n",
            [BASE .. "demo/manifest.lua"] =
                'return { name = "demo", version = "1.0.0", entry = "main.lua",'
                .. ' capabilities = { "fs.read" } }\n',
            [BASE .. "demo/main.lua"] = 'return function(manifest, api) return nil end\n',
            [BASE .. "other/files.txt"] = "manifest.lua\n",
            [BASE .. "other/manifest.lua"] = 'return { name = "other", version = "2.0.0" }\n',
        }
    end

    -- -----------------------------------------------------------------
    H.group("appstore.manifest")
    do
        local raw = assert(loadfile("/system/system/appstore.app/manifest.lua"))()
        local caps = {}
        for i = 1, #(raw.capabilities or {}) do caps[raw.capabilities[i]] = true end
        H.eq("appstore_name", raw.name, "appstore")
        H.eq("appstore_version", raw.version, "0.1.0")
        H.eq("appstore_rhtp", caps["net.rhtp"], true)
        H.eq("appstore_no_http", caps.http, nil)
        H.eq("appstore_write", caps["fs.write"], true)
        H.eq("appstore_read", caps["fs.read"], true)
        H.eq("appstore_input", caps.input, true)
        H.eq("appstore_terminal", caps.terminal, true)
        H.eq("appstore_rednet", caps["net.rednet"], true)
    end

    -- -----------------------------------------------------------------
    H.group("appstore.index")
    do
        local http = rhtp_from(server())
        local api = api_with(http)
        local state = P.new_state(api)
        -- 2026-11-01: the built-in default is the project store, not a .invalid
        -- placeholder, so a fresh machine needs no `a` press before it can install
        H.eq("index_default_server", state.server, "rhtp://store.pyrotechnic.org/")
        H.eq("index_default_constant", P.DEFAULT_SERVER, "rhtp://store.pyrotechnic.org/")
        H.check("index_no_invalid", (P.DEFAULT_SERVER or ""):find("invalid", 1, true) == nil,
            "the default server is still a placeholder")
        local entries, bad = P.parse_index("app a 1.0.0 da\nnonsense\napp b 2.0 d2\n", BASE)
        H.eq("index_entries", #entries, 2)
        H.eq("index_bad", bad, 1)
        H.eq("index_first_name", entries[1].name, "a")
        H.eq("index_first_dir", entries[1].dir, "da")

        -- a 404 is a readable status and no entries
        local api404 = api_with(rhtp_from({})[1])
        local state404 = P.new_state(api404)
        state404.server_index = 1
        H.eq("index_404", P.load_index(state404, api404), "error")
        H.contains("index_404_status", state404.status, "store: ")
        H.eq("index_404_entries", #state404.entries, 0)

        -- a 404 status is named verbatim
        local api404b = api_with({ get = function()
            return nil, "rhtp 404"
        end })
        local state404b = P.new_state(api404b)
        state404b.servers = { BASE }
        H.eq("index_404b", P.load_index(state404b, api404b), "error")
        H.eq("index_404b_status", state404b.status, "store: rhtp 404")

        -- the real server listing: two apps and a bad-line count
        local state2 = P.new_state(api)
        state2.servers = { BASE }
        state2.server_index = 1
        H.eq("index_ok", P.load_index(state2, api), "open")
        H.eq("index_ok_entries", #state2.entries, 2)
        H.contains("index_ok_status", state2.status, "bad lines: 2")
        local frame = P.render(state2, 51, 19)
        H.contains("index_row1", frame[1] or "", "appstore 0.1.0")
        H.contains("index_server_row", frame[2] or "", "server: " .. BASE)
        H.contains("index_app_row", table.concat(frame, "\n"), "demo 1.0.0")
        H.contains("index_hint", frame[19] or "", "up/dn enter r reload a url q quit")

        -- no net.rhtp grant/host at all: a readable line, no request
        local state3 = P.new_state(api_with(nil)[1])
        H.eq("index_no_rhtp", P.load_index(state3, api_with(nil)[1]), "error")
        H.eq("index_no_rhtp_status", state3.status, "store: no rhtp")

        -- the two other named failures keep their exact words on the status line
        local dns_api = api_with({ get = function() return nil, "dns: unknown host" end })
        local state_dns = P.new_state(dns_api)
        H.eq("index_dns_action", P.load_index(state_dns, dns_api), "error")
        H.eq("index_dns_status", state_dns.status, "store: dns unknown host")
        local to_api = api_with({ get = function() return nil, "timeout" end })
        local state_to = P.new_state(to_api)
        H.eq("index_timeout_action", P.load_index(state_to, to_api), "error")
        H.eq("index_timeout_status", state_to.status, "store: timeout")
    end

    -- -----------------------------------------------------------------
    H.group("appstore.download")
    do
        H.rmrf("/pkgs")
        local calls
        local http
        http, calls = rhtp_from(server())
        local installed = {}
        local sysx = {
            install = function(name)
                installed[#installed + 1] = name
                return true, { version = "1.0.0" }
            end,
        }
        local api, lines = api_with(http, sysx)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        P.load_index(state, api)
        state.index = 2 -- row 1 is the server line, row 2 is "demo"
        local action = P.enter(state, api)
        H.eq("download_action", action, "install")
        H.check("download_manifest", F.exists("/pkgs/demo.app/manifest.lua"),
            "manifest.lua not staged")
        H.check("download_main", F.exists("/pkgs/demo.app/main.lua"),
            "main.lua not staged")
        H.contains("download_content", H.read("/pkgs/demo.app/main.lua") or "",
            "return function(manifest, api)")
        H.eq("download_no_part", F.exists("/pkgs/demo.app.part"), false)
        H.eq("download_installed", installed[1], "demo")
        H.has(lines, "APPSTORE_FETCH name=demo files=2")
        H.has(lines, "APPSTORE_INSTALL name=demo ok=true")
        H.contains("download_status", state.status, "installed demo")

        -- a server without the optional SHA256.txt is honest about it
        H.hrmrf = H.rmrf
        H.rmrf("/pkgs")
        local http2, calls2 = rhtp_from(server())
        local api2, lines2 = api_with(http2, nil)
        local state2 = P.new_state(api2)
        state2.servers = { BASE }
        state2.server_index = 1
        P.load_index(state2, api2)
        state2.index = 2
        H.eq("download_nobridge", P.enter(state2, api2), "install")
        H.contains("download_unverified", state2.status, "unverified")
        H.has(lines2, "APPSTORE_INSTALL name=demo ok=false err=no_bridge")
        H.contains("download_staged", state2.status, "staged in /pkgs")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("appstore.sha")
    do
        H.rmrf("/pkgs")
        -- a wrong hash fails and leaves nothing behind
        local map = server()
        map[BASE .. "demo/SHA256.txt"] = string.rep("00", 32) .. " manifest.lua\n"
            .. string.rep("00", 32) .. " main.lua\n"
        local api, lines = api_with(rhtp_from(map), nil)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        P.load_index(state, api)
        state.index = 2
        H.eq("sha_bad", P.enter(state, api), "error")
        H.contains("sha_bad_status", state.status, "hash check failed")
        H.eq("sha_bad_clean", F.exists("/pkgs/demo.app"), false)
        H.eq("sha_bad_clean_part", F.exists("/pkgs/demo.app.part"), false)

        -- with the correct hash the package is verified (the digest comes from
        -- /system/rpv/crypto.lua when this image can load it)
        local manifest = map[BASE .. "demo/manifest.lua"]
        local main = map[BASE .. "demo/main.lua"]
        local sha_ok = P.sha_of(manifest)
        if sha_ok ~= nil then
            local map2 = server()
            map2[BASE .. "demo/SHA256.txt"] = P.sha_of(manifest) .. " manifest.lua\n"
                .. P.sha_of(main) .. " main.lua\n"
            local api2, lines2 = api_with(rhtp_from(map2), nil)
            local state2 = P.new_state(api2)
            state2.servers = { BASE }
            state2.server_index = 1
            P.load_index(state2, api2)
            state2.index = 2
            H.eq("sha_good", P.enter(state2, api2), "install")
            H.contains("sha_good_status", state2.status, ", verified")
            H.absent("sha_good_no_unverified", state2.status, "unverified")
            H.check("sha_good_file", F.exists("/pkgs/demo.app/main.lua"), "not staged")
        else
            H.check("sha_crypto_absent", true, "")
        end
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("appstore.edit")
    do
        H.rmrf("/pkgs")
        local http, calls = rhtp_from(server())
        local api, lines = api_with(http, nil)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        -- `a` edits the first server line, prefilled
        H.eq("edit_begin", P.dispatch_event(state, "key", "a", api), "repaint")
        H.eq("edit_on", state.editing, true)
        H.eq("edit_prefill", state.edit_text, BASE)
        H.has(lines, "APPSTORE_EDIT begin url=" .. P.plain(BASE, 60))
        local frame = P.render(state, 51, 19)
        H.contains("edit_row", frame[2] or "", "server> " .. BASE .. "_")
        H.contains("edit_hint", frame[19] or "", "enter accept c cancel bs del")

        -- typing is appended; q is a letter while editing
        state.edit_text = "rhtp://"
        P.dispatch_event(state, "char", "q", api)
        H.eq("edit_q_text", state.edit_text, "rhtp://q")
        H.eq("edit_back", P.dispatch_event(state, "key", "backspace", api), "move")
        H.eq("edit_back_text", state.edit_text, "rhtp://")
        H.eq("edit_off", P.dispatch_event(state, "key", "c", api), "repaint")
        H.eq("edit_cancelled", state.editing, nil)
        H.has(lines, "APPSTORE_EDIT end reason=cancel")

        -- enter accepts: the new server replaces the first line and the index loads
        state.editing = true
        state.edit_text = BASE
        local action = P.dispatch_event(state, "key", "enter", api)
        H.eq("edit_submit", action, "open")
        H.eq("edit_new_server", P.server_of(state), BASE)
        H.has(lines, "APPSTORE_SERVER url=" .. P.plain(BASE, 60))
        H.eq("edit_no_space", P.valid_url("two words"), false)
        H.eq("edit_no_empty", P.valid_url("   "), false)
        H.eq("edit_too_long", P.valid_url(string.rep("x", 200)), false)
        -- a bare host[:port]/path is accepted and normalized to rhtp://
        H.eq("edit_bare", P.normalize_server("box:8081/pkg/"),
            "rhtp://box:8081/pkg/")
        H.eq("edit_bare_default_port", P.normalize_server("box/pkg"),
            "rhtp://box/pkg")
        -- the host http scheme is refused instead of being stored as reachable
        H.eq("edit_http_refused", P.valid_url("http://store.pyrotechnic.org/"),
            false)
        H.eq("edit_http_reason", select(2, P.valid_url("http://x/")),
            "only rhtp:// addresses")
        H.eq("edit_bad_port", P.valid_url("rhtp://box:0/x"), false)
    end

    -- -----------------------------------------------------------------
    -- -----------------------------------------------------------------
    -- receiver: the other computer runs tools/pushpkg.lua; the rednet side is
    -- scripted here and the file system is real, so a received package is
    -- inspected on disk
    -- -----------------------------------------------------------------
    local function fake_rednet(opts)
        local o = opts or {}
        local net = { sent = {}, opened = {}, polls = 0, script = {} }
        function net.push(sender, msg)
            net.script[#net.script + 1] = { sender = sender, msg = msg }
        end
        net.receive = function(protocol, timeout)
            net.polls = net.polls + 1
            net.last_protocol = protocol
            net.last_timeout = timeout
            if o.denied then return nil, "capability denied: net.rednet" end
            local item = table.remove(net.script, 1)
            if item == nil then return nil end
            return item.sender, item.msg
        end
        net.send = function(target, msg, protocol)
            net.sent[#net.sent + 1] = { target = target, msg = msg,
                protocol = protocol }
            return true
        end
        net.open = function(name)
            net.opened[#net.opened + 1] = name
            return true
        end
        return net
    end

    local function recv_api(net, sysx)
        local api, lines = api_with(nil, sysx)
        api.net = { rednet = net }
        return api, lines
    end

    local function begin_msg(name, files)
        return { kind = "begin", name = name, version = "1.0.0", pkg = "app",
            files = files }
    end

    local function poll(state, api, net, sender, msg)
        net.push(sender, msg)
        return P.recv_poll(state, api)
    end

    local MANIFEST = 'return { name = "demo", version = "1.0.0" }\n'
    local MAIN = "return function(manifest, api) return nil end\n"

    H.group("appstore.recv.arm")
    do
        H.rmrf("/pkgs")
        H.rmrf("/etc/appstore.recv")
        local net = fake_rednet()
        local api, lines = recv_api(net)
        local state = P.new_state(api)
        -- `l` arms; the config file is optional, so the defaults apply
        H.eq("arm_via_key", P.dispatch_event(state, "key", "l", api), "repaint")
        H.check("arm_state", type(state.recv) == "table", "receiver not armed")
        H.eq("arm_channel", state.recv and state.recv.channel, 4101)
        H.eq("arm_protocol", state.recv and state.recv.protocol, "PYROET-PKG/1")
        H.contains("arm_status", state.status, "listening ch=4101")
        H.eq("arm_default_protocol", P.RECV_PROTOCOL, "PYROET-PKG/1")
        H.eq("arm_conf_path", P.RECV_CONF, "/etc/appstore.recv")
        H.has(lines, "APPSTORE_RECV_ARM ch=4101 protocol=PYROET-PKG/1")
        -- the hint row switches to the receiver vocabulary
        local frame = P.render(state, 51, 19)
        H.eq("arm_rows", #frame, 19)
        H.contains("arm_hint", frame[19] or "", "q stop listening")
        H.absent("arm_hint_old", frame[19] or "", "up/dn enter")
        -- arming twice is idempotent, and `q` only stops the receiver
        H.eq("arm_twice", P.recv_arm(state, api), "repaint")
        H.eq("stop_action", P.dispatch_event(state, "key", "q", api), "repaint")
        H.eq("stop_state", state.recv, nil)
        H.eq("stop_status", state.status, "receiver stopped")
        H.has(lines, "APPSTORE_RECV_STOP")
        H.eq("arm_again", P.recv_arm(state, api), "repaint")
        P.recv_stop(state, api)
        -- a char event arms too
        local api2 = recv_api(fake_rednet())
        local state2 = P.new_state(api2)
        H.eq("arm_char", P.dispatch_event(state2, "char", "l", api2), "repaint")
        H.check("arm_char_state", type(state2.recv) == "table", "not armed")
        P.recv_stop(state2, api2)
        -- every attached modem is opened, so rednet hears the broadcast channel
        local opened = fake_rednet()
        local saved_per = rawget(_G, "peripheral")
        rawset(_G, "peripheral",
            { getNames = function() return { "top", "left" } end })
        local count = P.open_modems(opened)
        rawset(_G, "peripheral", saved_per)
        H.eq("open_modems_count", count, 2)
        H.eq("open_modems_names", table.concat(opened.opened, ","), "top,left")
        -- no rednet capability: named on screen, no crash
        local denied = fake_rednet({ denied = true })
        local api3, lines3 = recv_api(denied)
        local state3 = P.new_state(api3)
        H.eq("no_rednet_action", P.recv_arm(state3, api3), "denied")
        H.eq("no_rednet_status", state3.status, "no rednet")
        H.eq("no_rednet_state", state3.recv, nil)
        H.has(lines3, "APPSTORE_RECV_ARM ok=false err=no_rednet")
        -- a host with no rednet table at all
        local saved_net = rawget(_G, "rednet")
        rawset(_G, "rednet", nil)
        local api4, lines4 = recv_api(nil)
        local state4 = P.new_state(api4)
        H.eq("no_net_table", P.recv_arm(state4, api4), "denied")
        H.eq("no_rednet_table_state", state4.recv, nil)
        H.has(lines4, "APPSTORE_RECV_ARM ok=false err=no_rednet")
        rawset(_G, "rednet", saved_net)
    end

    H.group("appstore.recv.conf")
    do
        H.rmrf("/pkgs")
        H.mkdirp("/etc")
        H.write("/etc/appstore.recv",
            "# receiver settings\nchannel=4200\nprotocol=PYROET-PKG/9\n")
        local api, lines = recv_api(fake_rednet())
        local state = P.new_state(api)
        H.eq("conf_arm", P.recv_arm(state, api), "repaint")
        H.eq("conf_channel", state.recv and state.recv.channel, 4200)
        H.eq("conf_protocol", state.recv and state.recv.protocol, "PYROET-PKG/9")
        H.contains("conf_status", state.status, "listening ch=4200")
        H.has(lines, "APPSTORE_RECV_ARM ch=4200 protocol=PYROET-PKG/9")
        P.recv_stop(state, api)
        -- bad values are ignored: the defaults stay
        H.write("/etc/appstore.recv", "channel=0\nchannel=abc\nprotocol=two words\n")
        local api2 = recv_api(fake_rednet())
        local state2 = P.new_state(api2)
        H.eq("conf_bad_arm", P.recv_arm(state2, api2), "repaint")
        H.eq("conf_bad_channel", state2.recv and state2.recv.channel, 4101)
        H.eq("conf_bad_protocol", state2.recv and state2.recv.protocol,
            "PYROET-PKG/1")
        P.recv_stop(state2, api2)
        F.delete("/etc/appstore.recv")
        H.eq("conf_removed", F.exists("/etc/appstore.recv"), false)
    end

    H.group("appstore.recv.package")
    do
        H.rmrf("/pkgs")
        local net = fake_rednet()
        local installed = {}
        local sysx = { install = function(name)
            installed[#installed + 1] = name
            return true, { version = "1.0.0" }
        end }
        local api, lines = recv_api(net, sysx)
        local state = P.new_state(api)
        H.eq("pkg_arm", P.recv_arm(state, api), "repaint")
        H.eq("begin_action", poll(state, api, net, 12, begin_msg("demo", 2)),
            "move")
        H.eq("begin_ack_target", net.sent[1].target, 12)
        H.eq("begin_ack_kind", net.sent[1].msg.kind, "ack")
        H.eq("begin_ack_ok", net.sent[1].msg.ok, true)
        H.eq("begin_ack_name", net.sent[1].msg.name, "demo")
        H.eq("begin_ack_protocol", net.sent[1].protocol, "PYROET-PKG/1")
        H.check("begin_part_dir", F.exists("/pkgs/demo.app.part"), "no .part dir")
        H.eq("begin_app_absent", F.exists("/pkgs/demo.app"), false)
        H.eq("file1_action", poll(state, api, net, 12, { kind = "file",
            rel = "manifest.lua", data = MANIFEST, chunk = 1, chunks = 1 }), "move")
        H.check("file1_written", F.exists("/pkgs/demo.app.part/manifest.lua"),
            "manifest not staged")
        H.eq("file1_ack_rel", net.sent[#net.sent].msg.rel, "manifest.lua")
        H.eq("file2_action", poll(state, api, net, 12, { kind = "file",
            rel = "main.lua", data = MAIN, chunk = 1, chunks = 1 }), "move")
        H.contains("progress_status", state.status, "recv demo 2/2")
        local sha = P.digest_of({ { rel = "manifest.lua", body = MANIFEST },
            { rel = "main.lua", body = MAIN } })
        H.check("digest_available", sha ~= nil, "no sha256 in this image")
        H.eq("end_action", poll(state, api, net, 12, { kind = "end", sha = sha }),
            "install")
        H.eq("end_ack_ok", net.sent[#net.sent].msg.ok, true)
        H.check("published_manifest", F.exists("/pkgs/demo.app/manifest.lua"),
            "package not published")
        H.check("published_main", F.exists("/pkgs/demo.app/main.lua"),
            "package not published")
        H.eq("published_content", H.read("/pkgs/demo.app/main.lua"), MAIN)
        H.eq("part_cleaned", F.exists("/pkgs/demo.app.part"), false)
        H.eq("installed_once", installed[1], "demo")
        H.eq("installed_count", #installed, 1)
        H.has(lines, "APPSTORE_RECV name=demo files=2 bytes=")
        H.eq("recv_report_name", state.recv_pkg and state.recv_pkg.name, "demo")
        H.eq("recv_report_files", state.recv_pkg and state.recv_pkg.files, 2)
        H.eq("recv_report_install", state.recv_pkg and state.recv_pkg.install, true)
        H.contains("recv_status", state.status, "installed demo")
        -- still listening for the next package
        H.check("still_armed", type(state.recv) == "table", "receiver disarmed")
        H.eq("next_poll", P.recv_poll(state, api), "none")
        P.recv_stop(state, api)

        -- no bridge: the package stays staged in /pkgs, which is a normal state
        H.rmrf("/pkgs")
        local net2 = fake_rednet()
        local api2, lines2 = recv_api(net2)
        local state2 = P.new_state(api2)
        P.recv_arm(state2, api2)
        H.eq("solo_begin", poll(state2, api2, net2, 7, begin_msg("solo", 1)), "move")
        H.eq("solo_file", poll(state2, api2, net2, 7, { kind = "file",
            rel = "main.lua", data = MAIN, chunk = 1, chunks = 1 }), "move")
        H.eq("solo_end", poll(state2, api2, net2, 7, { kind = "end" }), "install")
        H.check("solo_published", F.exists("/pkgs/solo.app/main.lua"),
            "not published")
        H.eq("solo_install", state2.recv_pkg and state2.recv_pkg.install, false)
        H.contains("solo_status", state2.status, "staged /pkgs/solo.app")
        H.has(lines2, "APPSTORE_RECV name=solo files=1 bytes=")
        H.has(lines2, "install=false")
        P.recv_stop(state2, api2)
        H.rmrf("/pkgs")
    end

    H.group("appstore.recv.chunks")
    do
        H.rmrf("/pkgs")
        local net = fake_rednet()
        local api, lines = recv_api(net)
        local state = P.new_state(api)
        P.recv_arm(state, api)
        local body = string.rep("abc", 3000)          -- 9000 bytes, 2 chunks
        H.eq("chunk_begin", poll(state, api, net, 3, begin_msg("chunked", 1)),
            "move")
        H.eq("chunk_first", poll(state, api, net, 3, { kind = "file",
            rel = "main.lua", data = body:sub(1, P.MAX_CHUNK), chunk = 1,
            chunks = 2 }), "move")
        H.eq("chunk_first_ack", net.sent[#net.sent].msg.chunk, 1)
        H.eq("chunk_first_not_written",
            F.exists("/pkgs/chunked.app.part/main.lua"), false)
        H.eq("chunk_second", poll(state, api, net, 3, { kind = "file",
            rel = "main.lua", data = body:sub(P.MAX_CHUNK + 1), chunk = 2,
            chunks = 2 }), "move")
        H.eq("chunk_second_ack", net.sent[#net.sent].msg.chunk, 2)
        H.eq("chunk_written_bytes",
            #(H.read("/pkgs/chunked.app.part/main.lua") or ""), #body)
        H.eq("chunk_end", poll(state, api, net, 3, { kind = "end" }),
            "install")
        -- an out-of-order chunk is refused and the .part tree goes away
        H.eq("order_begin", poll(state, api, net, 3, begin_msg("badchunk", 1)),
            "move")
        H.eq("order_action", poll(state, api, net, 3, { kind = "file",
            rel = "main.lua", data = "x", chunk = 2, chunks = 2 }), "error")
        H.eq("order_ack_ok", net.sent[#net.sent].msg.ok, false)
        H.contains("order_ack_err", net.sent[#net.sent].msg.err, "chunk order")
        H.eq("order_part_cleaned", F.exists("/pkgs/badchunk.app.part"), false)
        P.recv_stop(state, api)
        H.rmrf("/pkgs")
    end

    H.group("appstore.recv.abort")
    do
        H.rmrf("/pkgs")
        local net = fake_rednet()
        local api, lines = recv_api(net)
        local state = P.new_state(api)
        P.recv_arm(state, api)
        H.eq("abort_begin", poll(state, api, net, 5, begin_msg("gone", 2)), "move")
        H.eq("abort_file", poll(state, api, net, 5, { kind = "file",
            rel = "main.lua", data = "x", chunk = 1, chunks = 1 }), "move")
        H.check("abort_part_exists", F.exists("/pkgs/gone.app.part"), "no part")
        H.eq("abort_action", poll(state, api, net, 5, { kind = "abort" }), "repaint")
        H.eq("abort_ack_ok", net.sent[#net.sent].msg.ok, true)
        H.eq("abort_part_cleaned", F.exists("/pkgs/gone.app.part"), false)
        H.eq("abort_published", F.exists("/pkgs/gone.app"), false)
        H.eq("abort_status", state.status, "aborted gone")
        H.check("abort_still_armed", type(state.recv) == "table", "disarmed")
        H.has(lines, "APPSTORE_RECV_ABORT name=gone")
        P.recv_stop(state, api)
        H.rmrf("/pkgs")
    end

    H.group("appstore.recv.failures")
    do
        local function ready(name)
            H.rmrf("/pkgs")
            local net = fake_rednet()
            local api, lines = recv_api(net)
            local state = P.new_state(api)
            P.recv_arm(state, api)
            return state, api, net, lines
        end
        -- a wrong end digest refuses the package and leaves nothing behind
        local state, api, net, lines = ready()
        poll(state, api, net, 9, begin_msg("demo", 1))
        poll(state, api, net, 9, { kind = "file", rel = "main.lua",
            data = MAIN, chunk = 1, chunks = 1 })
        H.eq("sha_bad_action", poll(state, api, net, 9, { kind = "end",
            sha = string.rep("0", 64) }), "error")
        H.eq("sha_bad_ack", net.sent[#net.sent].msg.ok, false)
        H.contains("sha_bad_err", net.sent[#net.sent].msg.err, "hash check failed")
        H.eq("sha_bad_part", F.exists("/pkgs/demo.app.part"), false)
        H.eq("sha_bad_published", F.exists("/pkgs/demo.app"), false)
        H.has(lines, "APPSTORE_RECV name=demo files=1 bytes=")
        H.has(lines, "ok=false")
        H.check("sha_bad_armed", type(state.recv) == "table", "disarmed")
        -- a malformed digest is refused before anything is compared
        poll(state, api, net, 9, begin_msg("sha", 1))
        poll(state, api, net, 9, { kind = "file", rel = "main.lua",
            data = MAIN, chunk = 1, chunks = 1 })
        H.eq("sha_short_action", poll(state, api, net, 9, { kind = "end",
            sha = "abc" }), "error")
        H.contains("sha_short_err", net.sent[#net.sent].msg.err, "bad sha")
        -- an incomplete stream is refused
        poll(state, api, net, 9, begin_msg("half", 2))
        poll(state, api, net, 9, { kind = "file", rel = "main.lua",
            data = "x", chunk = 1, chunks = 1 })
        H.eq("incomplete_action", poll(state, api, net, 9, { kind = "end" }),
            "error")
        H.contains("incomplete_err", net.sent[#net.sent].msg.err, "incomplete")
        H.eq("incomplete_part", F.exists("/pkgs/half.app.part"), false)
        -- bad names, versions, kinds and paths are all clean refusals
        H.eq("bad_name_action", poll(state, api, net, 9, { kind = "begin",
            name = "../etc", version = "1", files = 1 }), "error")
        H.contains("bad_name_err", net.sent[#net.sent].msg.err, "bad name")
        H.eq("bad_kind_action", poll(state, api, net, 9, { kind = "begin",
            name = "k", version = "1", pkg = "zip", files = 1 }), "error")
        H.contains("bad_kind_err", net.sent[#net.sent].msg.err, "bad pkg")
        H.eq("bad_version_action", poll(state, api, net, 9, { kind = "begin",
            name = "v", version = "", files = 1 }), "error")
        H.contains("bad_version_err", net.sent[#net.sent].msg.err, "bad version")
        H.eq("bad_files_action", poll(state, api, net, 9, { kind = "begin",
            name = "f", version = "1", files = 0 }), "error")
        H.contains("bad_files_err", net.sent[#net.sent].msg.err, "bad files")
        poll(state, api, net, 9, begin_msg("paths", 1))
        H.eq("bad_rel_action", poll(state, api, net, 9, { kind = "file",
            rel = "../etc/passwd", data = "x", chunk = 1, chunks = 1 }), "error")
        H.contains("bad_rel_err", net.sent[#net.sent].msg.err, "bad rel")
        H.eq("bad_rel_part", F.exists("/pkgs/paths.app.part"), false)
        poll(state, api, net, 9, begin_msg("data", 1))
        H.eq("bad_data_action", poll(state, api, net, 9, { kind = "file",
            rel = "main.lua", data = 7, chunk = 1, chunks = 1 }), "error")
        H.contains("bad_data_err", net.sent[#net.sent].msg.err, "bad data")
        H.eq("no_begin_action", poll(state, api, net, 9, { kind = "file",
            rel = "main.lua", data = "x", chunk = 1, chunks = 1 }), "none")
        H.contains("no_begin_err", net.sent[#net.sent].msg.err, "no begin")
        H.eq("end_no_begin", poll(state, api, net, 9, { kind = "end" }), "none")
        H.contains("end_no_begin_err", net.sent[#net.sent].msg.err, "no begin")
        H.eq("bad_kind_message", poll(state, api, net, 9, { kind = "nope" }),
            "none")
        H.contains("bad_kind_message_err", net.sent[#net.sent].msg.err, "bad kind")
        -- a disk that does not keep the bytes is caught by the read-back check
        poll(state, api, net, 9, begin_msg("lying", 1))
        api.fs.read = function() return "mangled" end
        H.eq("write_check_action", poll(state, api, net, 9, { kind = "file",
            rel = "main.lua", data = "x", chunk = 1, chunks = 1 }), "error")
        H.contains("write_check_err", net.sent[#net.sent].msg.err,
            "write check failed")
        H.eq("write_check_part", F.exists("/pkgs/lying.app.part"), false)
        P.recv_stop(state, api)
        H.rmrf("/pkgs")
    end

    H.group("appstore.recv.timeout")
    do
        H.rmrf("/pkgs")
        local now = 0
        local net = fake_rednet()
        local api, lines = recv_api(net)
        local state = P.new_state(api)
        state.recv_clock = function() return now end
        P.recv_arm(state, api)
        H.eq("timeout_begin", poll(state, api, net, 4, begin_msg("slow", 1)),
            "move")
        now = 200
        H.eq("timeout_action", P.recv_poll(state, api), "error")
        H.eq("timeout_part", F.exists("/pkgs/slow.app.part"), false)
        H.has(lines, "APPSTORE_RECV_TIMEOUT name=slow")
        H.eq("timeout_acks", #net.sent, 1)   -- only the begin ack from before
        H.check("timeout_armed", type(state.recv) == "table", "disarmed")
        -- a plain receive timeout is not an error and does not drop the stream
        now = 0
        H.eq("timeout_second_begin", poll(state, api, net, 4,
            begin_msg("slow2", 1)), "move")
        H.eq("timeout_empty_poll", P.recv_poll(state, api), "none")
        H.check("timeout_empty_armed", type(state.recv) == "table", "disarmed")
        P.recv_stop(state, api)
        H.rmrf("/pkgs")
    end

    H.group("appstore.keys")
    do
        local api = api_with(rhtp_from(server()), nil)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        P.load_index(state, api)
        H.eq("keys_quit", P.dispatch_event(state, "key", "q", api), "quit")
        H.eq("keys_quit_char", P.dispatch_event(state, "char", "q", api), "quit")
        H.eq("keys_reload", P.dispatch_event(state, "key", "r", api), "open")
        state.index = 1
        H.eq("keys_down", P.dispatch_event(state, "key", "down", api), "move")
        H.eq("keys_down_index", state.index, 2)
        H.eq("keys_up", P.dispatch_event(state, "key", "up", api), "move")
        H.eq("keys_up_index", state.index, 1)
        -- several servers: `s` cycles, the first line is what `a` edits
        state.servers = { BASE, "rhtp://second.example/" }
        H.eq("keys_server_cycle", P.dispatch_event(state, "key", "s", api), "repaint")
        H.eq("keys_server_second", P.server_of(state), "rhtp://second.example/")
        H.eq("keys_server_wrap", P.dispatch_event(state, "key", "s", api), "repaint")
        H.eq("keys_server_first", P.server_of(state), BASE)
        -- the list has no entries and enter does nothing
        state.entries = {}
        state.index = 5
        H.eq("keys_empty_enter", P.dispatch_event(state, "key", "enter", api), "none")
        H.eq("appstore_hint", P.HINT,
            "up/dn enter r reload a url q quit l recv t target")
    end

    -- -----------------------------------------------------------------
    -- disk target: the handheld sits in a drive of a block computer. A pocket
    -- computer has no /disk, so only the drive case can be selected; the file
    -- system is real, so a disk write is inspected on /disk/pkgs.
    -- -----------------------------------------------------------------
    H.group("appstore.target")
    do
        -- no drive: `t` only says so and the target stays self
        H.rmrf("/pkgs")
        H.rmrf("/disk")
        local installed = {}
        local api, lines = api_with(rhtp_from(server()), { install = function(name)
            installed[#installed + 1] = name
            return true, { version = "1.0.0" }
        end })
        local state = P.new_state(api)
        H.eq("target_probe_none", state.disk, false)
        H.eq("target_default", P.target_of(state), "self")
        H.eq("target_self_root", P.target_root(state), "")
        H.eq("target_self_pkgs", P.pkgs_root(state), "/pkgs")
        H.eq("target_none_key", P.dispatch_event(state, "key", "t", api), "repaint")
        H.eq("target_none_still_self", P.target_of(state), "self")
        H.eq("target_none_status", state.status, "no disk drive")
        local frame = P.render(state, 51, 19)
        H.contains("target_none_row", frame[18] or "", "target self  no disk drive")
        H.has(lines, "APPSTORE_TARGET ok=false err=no_disk")
        H.lacks("target_none_no_write", lines, "APPSTORE_WRITE")
        -- a self download still goes through the bridge
        state.servers = { BASE }
        state.server_index = 1
        P.load_index(state, api)
        state.index = 2
        H.eq("target_self_action", P.enter(state, api), "install")
        H.eq("target_self_installed", installed[1], "demo")
        H.check("target_self_file", F.exists("/pkgs/demo.app/main.lua"), "not staged")
        H.has(lines, "APPSTORE_INSTALL name=demo ok=true")

        -- a drive: `t` selects disk, the package is written and never installed
        H.rmrf("/pkgs")
        H.mkdirp("/disk")
        H.check("target_disk_created", F.isDir("/disk"), "/disk is not a directory")
        local installed2 = {}
        local api2, lines2 = api_with(rhtp_from(server()), { install = function(name)
            installed2[#installed2 + 1] = name
            return true, { version = "2.0.0" }
        end })
        local state2 = P.new_state(api2)
        H.eq("target_probe_disk", state2.disk, true)
        H.eq("target_disk_default", P.target_of(state2), "self")
        H.eq("target_disk_key", P.dispatch_event(state2, "key", "t", api2), "repaint")
        H.eq("target_disk_on", P.target_of(state2), "disk")
        H.eq("target_disk_root", P.target_root(state2), "/disk")
        H.eq("target_disk_pkgs", P.pkgs_root(state2), "/disk/pkgs")
        local frame2 = P.render(state2, 51, 19)
        H.contains("target_disk_row", frame2[18] or "", "target disk")
        H.has(lines2, "APPSTORE_TARGET ok=true target=disk root=/disk/pkgs")
        state2.servers = { BASE }
        state2.server_index = 1
        P.load_index(state2, api2)
        state2.index = 2
        H.eq("target_disk_action", P.enter(state2, api2), "install")
        H.eq("target_disk_no_bridge", #installed2, 0)
        H.lacks("target_disk_no_install_log", lines2, "APPSTORE_INSTALL")
        H.has(lines2, "APPSTORE_WRITE ok=true target=disk name=demo files=2 bytes=")
        H.has(lines2, "APPSTORE_FETCH name=demo files=2")
        H.contains("target_disk_status", state2.status, "written to disk")
        local map = server()
        H.eq("target_disk_manifest", H.read("/disk/pkgs/demo.app/manifest.lua"),
            map[BASE .. "demo/manifest.lua"])
        H.eq("target_disk_main", H.read("/disk/pkgs/demo.app/main.lua"),
            map[BASE .. "demo/main.lua"])
        H.eq("target_disk_no_part", F.exists("/disk/pkgs/demo.app.part"), false)
        H.eq("target_disk_internal_clean", F.exists("/pkgs/demo.app"), false)
        H.contains("target_disk_row_after", (P.render(state2, 51, 19))[18] or "",
            "written to disk")
        -- the `t` char event goes back to self and the bridge works again
        H.eq("target_back_char", P.dispatch_event(state2, "char", "t", api2), "repaint")
        H.eq("target_back_self", P.target_of(state2), "self")
        H.contains("target_back_row", (P.render(state2, 51, 19))[18] or "", "target self")
        state2.index = 3 -- row 3 is "other"
        H.eq("target_back_action", P.enter(state2, api2), "install")
        H.eq("target_back_installed", installed2[1], "other")
        H.check("target_back_file", F.exists("/pkgs/other.app/manifest.lua"), "not staged")
        H.eq("target_back_disk_clean", F.exists("/disk/pkgs/other.app"), false)
        -- the drive goes away again: `t` reports it and falls back to self
        H.rmrf("/disk")
        H.eq("target_gone_key", P.dispatch_event(state2, "key", "t", api2), "repaint")
        H.eq("target_gone_self", P.target_of(state2), "self")
        H.eq("target_gone_status", state2.status, "no disk drive")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("appstore.update")
    -- 2026-11-01: the row under the package list is the system update entry. The
    -- app reads meta.txt and paints; the kernel bridge (api.sys.ota_apply
    -- "image") is stubbed here, its real behaviour is t_sys_ota.ota.image.
    do
        local CR = {}
        assert(loadfile("/system/rpv/crypto.lua"))(CR)
        local OTA = assert(loadfile("/system/kernel/ota.lua"))()
        local function sha(text) return CR.hex(CR.sha256(text)) end
        local UP = "rhtp://up.example/upgrade"
        local body = "-- kernel v2\n"
        local rec = { relpath = "kernel/a.lua", size = #body, sha256 = sha(body) }
        local manifest = OTA.manifest_hash({ rec }, CR.sha256)
        local meta = "PYROET-OTA/2 META version=0.4.0 files=1 manifest_sha=" .. manifest
            .. "\nkernel/a.lua " .. tostring(#body) .. " " .. sha(body) .. "\n"
        local INDEX = BASE .. "index.txt"

        -- the OTA base is /etc/ota.servers' first line (not the package server)
        H.mkdirp("/etc")
        H.write("/etc/ota.servers", "# upgrade\n" .. UP .. "\nrhtp://other/\n")

        -- the row is the last item, and it shows the remote version after a load
        local http = rhtp_from({
            [INDEX] = "app demo 1.0.0 demo\n",
            [UP .. "/meta.txt"] = meta,
        })
        local api = api_with(http)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        H.eq("update_load", P.load_index(state, api), "open")
        H.eq("update_index", P.ota_index(state), #state.entries + 2)
        H.eq("update_version", state.ota_version, "0.4.0")
        H.eq("update_files", state.ota_files, 1)
        local text = table.concat(P.render(state, 51, 19), "\n")
        H.contains("update_row", text, "System update 0.4.0")
        H.contains("update_row_hint", text, "up/dn enter r reload a url q quit")

        -- no remote meta: the row is still there, just without a version
        local http_plain = rhtp_from({ [INDEX] = "app demo 1.0.0 demo\n" })
        local api_plain = api_with(http_plain)
        local plain = P.new_state(api_plain)
        plain.servers = { BASE }
        P.load_index(plain, api_plain)
        H.eq("update_no_version", plain.ota_version, nil)
        H.contains("update_plain_row", table.concat(P.render(plain, 51, 19), "\n"),
            "System update")

        -- the RHTP reasons reach the OTA row unchanged: a name that does not
        -- resolve and a request that timed out each say so
        local function meta_reason(err)
            local fake = rhtp_from({ [INDEX] = "app demo 1.0.0 demo\n" })
            local get = function(url)
                if url == UP .. "/meta.txt" then return nil, err end
                return fake.get(url)
            end
            local api_r = api_with({ get = get })
            local st_r = P.new_state(api_r)
            st_r.servers = { BASE }
            P.load_index(st_r, api_r)
            st_r.index = P.ota_index(st_r)
            return st_r, api_r
        end
        local st_dns, api_dns = meta_reason("dns: unknown host")
        H.eq("update_dns_action", P.ota_enter(st_dns, api_dns), "error")
        H.eq("update_dns_status", st_dns.status, "update: dns unknown host")
        local st_to, api_to = meta_reason("timeout")
        H.eq("update_timeout_action", P.ota_enter(st_to, api_to), "error")
        H.eq("update_timeout_status", st_to.status, "update: timeout")

        -- Enter on the row: the bridge is called with the base and a progress
        -- callback, the callback line is painted, and the status says reboot
        local progress = {}
        local st
        local sysx = {
            ota_apply = function(name, opts)
                H.eq("update_bridge_name", name, "image")
                H.eq("update_bridge_base", opts and opts.base, UP)
                if type(opts) == "table" and type(opts.progress) == "function" then
                    opts.progress("kernel/a.lua", 1, 2)
                    progress[#progress + 1] = (st and st.progress) or ""
                end
                return true, { state = "ready", version = "0.4.1" }
            end,
        }
        local api2 = api_with(http, sysx)
        st = P.new_state(api2)
        st.servers = { BASE }
        P.load_index(st, api2)
        st.index = P.ota_index(st)
        H.eq("update_enter", P.enter(st, api2), "repaint")
        H.eq("update_progress_line", progress[1], "fetching kernel/a.lua (1/2)")
        H.eq("update_progress_cleared", st.progress, nil)
        H.eq("update_status", st.status, "reboot to apply")
        H.eq("update_version_after", st.ota_version, "0.4.1")

        -- a failing bridge: one readable status line, no version change
        local sys_bad = { ota_apply = function() return nil, "digest 0123" end }
        local api3 = api_with(http, sys_bad)
        local st3 = P.new_state(api3)
        st3.servers = { BASE }
        P.load_index(st3, api3)
        st3.index = P.ota_index(st3)
        H.eq("update_fail_action", P.enter(st3, api3), "error")
        H.eq("update_fail_status", st3.status, "update failed: digest 0123")

        -- no net.rhtp at all: a readable line and no bridge call
        local api4 = api_with(nil)
        local st4 = P.new_state(api4)
        H.eq("update_norhtp_action", P.ota_enter(st4, api4), "error")
        H.eq("update_norhtp_status", st4.status, "update: no rhtp")

        -- a transport failure (no reply) and a 404 are both readable lines
        local api5 = api_with(rhtp_from({}))
        local st5 = P.new_state(api5)
        H.eq("update_404_action", P.ota_enter(st5, api5), "error")
        H.eq("update_transport_status", st5.status, "update: rhtp 404")
        local api5b = api_with({ get = function()
            return nil, "rhtp 404"
        end })
        local st5b = P.new_state(api5b)
        H.eq("update_404b_action", P.ota_enter(st5b, api5b), "error")
        H.eq("update_404b_status", st5b.status, "update: rhtp 404")

        -- a bad meta body is a readable line too
        local api5c = api_with({ get = function()
            return "garbage\n", nil
        end })
        local st5c = P.new_state(api5c)
        H.eq("update_badmeta_action", P.ota_enter(st5c, api5c), "error")
        H.contains("update_badmeta_status", st5c.status, "update: meta")

        -- the row moves like any item and cannot be walked past
        local st6 = P.new_state(api2)
        st6.entries = { { name = "demo", version = "1.0.0" } }
        st6.index = 1
        P.move(st6, 1)
        P.move(st6, 1)
        P.move(st6, 1)
        H.eq("update_move_max", st6.index, 3)

        -- with no config file the built-in default is the project store
        H.rmrf("/etc/ota.servers")
        H.eq("update_default_base", P.OTA_DEFAULT, "rhtp://pyroet.pyrotechnic.org/upgrade")
        H.eq("update_default_used", P.ota_base(api), P.OTA_DEFAULT)
    end
end
