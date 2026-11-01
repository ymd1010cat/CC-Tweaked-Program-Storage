--[[- pyroet-os/tests/t_pkgget.lua -- the package downloader (system/system/pkgget.app).

The server is plain http + plain text: index.txt, <dir>/files.txt, the files
themselves and an optional SHA256.txt. http is faked here (a URL -> body map)
and the file system is the real one, so the staged package is inspected on disk.

No non-ASCII bytes in this file.
]]

_G.PYROET_PKGGET_TEST = true
local P = assert(loadfile("/system/system/pkgget.app/main.lua"))()
_G.PYROET_PKGGET_TEST = nil

local KEYS = { up = 10, down = 11, enter = 14, q = 16, a = 17, r = 19,
    backspace = 21 }

return function(H)
    local F = H.real_fs()

    local function http_from(map)
        local calls = {}
        return {
            get = function(url)
                calls[#calls + 1] = url
                local item = map[url]
                if item == nil then return nil, "not found" end
                if type(item) == "table" then return item end
                return { ok = true, status = 200, body = item }
            end,
        }, calls
    end

    local function api_with(http, sys)
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
            http = http,
            sys = sys,
            input = { keys = KEYS, pullEvent = function() return nil end },
            yield = function() end,
            log = log,
        }
        return api, lines
    end

    local BASE = "http://example.com/pkg/"
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
    H.group("pkgget.manifest")
    do
        local raw = assert(loadfile("/system/system/pkgget.app/manifest.lua"))()
        local caps = {}
        for i = 1, #(raw.capabilities or {}) do caps[raw.capabilities[i]] = true end
        H.eq("pkgget_name", raw.name, "pkgget")
        H.eq("pkgget_version", raw.version, "0.1.0")
        H.eq("pkgget_http", caps.http, true)
        H.eq("pkgget_write", caps["fs.write"], true)
        H.eq("pkgget_read", caps["fs.read"], true)
        H.eq("pkgget_input", caps.input, true)
        H.eq("pkgget_terminal", caps.terminal, true)
    end

    -- -----------------------------------------------------------------
    H.group("pkgget.index")
    do
        local http = http_from(server())
        local api = api_with(http)
        local state = P.new_state(api)
        H.eq("index_default_server", state.server, P.PLACEHOLDER)
        local entries, bad = P.parse_index("app a 1.0.0 da\nnonsense\napp b 2.0 d2\n", BASE)
        H.eq("index_entries", #entries, 2)
        H.eq("index_bad", bad, 1)
        H.eq("index_first_name", entries[1].name, "a")
        H.eq("index_first_dir", entries[1].dir, "da")

        -- a 404 is a readable status and no entries
        local api404 = api_with(http_from({})[1])
        local state404 = P.new_state(api404)
        state404.server_index = 1
        H.eq("index_404", P.load_index(state404, api404), "error")
        H.contains("index_404_status", state404.status, "index ")
        H.eq("index_404_entries", #state404.entries, 0)

        -- a 404 status is named verbatim
        local api404b = api_with({ get = function()
            return { ok = true, status = 404, body = "nope" }
        end })
        local state404b = P.new_state(api404b)
        state404b.servers = { BASE }
        H.eq("index_404b", P.load_index(state404b, api404b), "error")
        H.eq("index_404b_status", state404b.status, "index http 404")

        -- the real server listing: two apps and a bad-line count
        local state2 = P.new_state(api)
        state2.servers = { BASE }
        state2.server_index = 1
        H.eq("index_ok", P.load_index(state2, api), "open")
        H.eq("index_ok_entries", #state2.entries, 2)
        H.contains("index_ok_status", state2.status, "bad lines: 2")
        local frame = P.render(state2, 51, 19)
        H.contains("index_row1", frame[1] or "", "pkgget 0.1.0")
        H.contains("index_server_row", frame[2] or "", "server: " .. BASE)
        H.contains("index_app_row", table.concat(frame, "\n"), "demo 1.0.0")
        H.contains("index_hint", frame[19] or "", "up/dn enter r reload a server q quit")

        -- no http at all
        local state3 = P.new_state(api_with(nil)[1])
        H.eq("index_no_http", P.load_index(state3, api_with(nil)[1]), "error")
        H.eq("index_no_http_status", state3.status, "index no http")
    end

    -- -----------------------------------------------------------------
    H.group("pkgget.download")
    do
        H.rmrf("/pkgs")
        local calls
        local http
        http, calls = http_from(server())
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
        H.has(lines, "PKGGET_FETCH name=demo files=2")
        H.has(lines, "PKGGET_INSTALL name=demo ok=true")
        H.contains("download_status", state.status, "installed demo")

        -- a server without the optional SHA256.txt is honest about it
        H.hrmrf = H.rmrf
        H.rmrf("/pkgs")
        local http2, calls2 = http_from(server())
        local api2, lines2 = api_with(http2, nil)
        local state2 = P.new_state(api2)
        state2.servers = { BASE }
        state2.server_index = 1
        P.load_index(state2, api2)
        state2.index = 2
        H.eq("download_nobridge", P.enter(state2, api2), "install")
        H.contains("download_unverified", state2.status, "unverified")
        H.has(lines2, "PKGGET_INSTALL name=demo ok=false err=no_bridge")
        H.contains("download_staged", state2.status, "staged in /pkgs")
        H.rmrf("/pkgs")
    end

    -- -----------------------------------------------------------------
    H.group("pkgget.sha")
    do
        H.rmrf("/pkgs")
        -- a wrong hash fails and leaves nothing behind
        local map = server()
        map[BASE .. "demo/SHA256.txt"] = string.rep("00", 32) .. " manifest.lua\n"
            .. string.rep("00", 32) .. " main.lua\n"
        local api, lines = api_with(http_from(map), nil)
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
            local api2, lines2 = api_with(http_from(map2), nil)
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
    H.group("pkgget.edit")
    do
        H.rmrf("/pkgs")
        local http, calls = http_from(server())
        local api, lines = api_with(http, nil)
        local state = P.new_state(api)
        state.servers = { BASE }
        state.server_index = 1
        -- `a` edits the first server line, prefilled
        H.eq("edit_begin", P.dispatch_event(state, "key", "a", api), "repaint")
        H.eq("edit_on", state.editing, true)
        H.eq("edit_prefill", state.edit_text, BASE)
        H.has(lines, "PKGGET_EDIT begin url=" .. P.plain(BASE, 60))
        local frame = P.render(state, 51, 19)
        H.contains("edit_row", frame[2] or "", "server> " .. BASE .. "_")
        H.contains("edit_hint", frame[19] or "", "enter accept c cancel bs del")

        -- typing is appended; q is a letter while editing
        state.edit_text = "http://"
        P.dispatch_event(state, "char", "q", api)
        H.eq("edit_q_text", state.edit_text, "http://q")
        H.eq("edit_back", P.dispatch_event(state, "key", "backspace", api), "move")
        H.eq("edit_back_text", state.edit_text, "http://")
        H.eq("edit_off", P.dispatch_event(state, "key", "c", api), "repaint")
        H.eq("edit_cancelled", state.editing, nil)
        H.has(lines, "PKGGET_EDIT end reason=cancel")

        -- enter accepts: the new server replaces the first line and the index loads
        state.editing = true
        state.edit_text = BASE
        local action = P.dispatch_event(state, "key", "enter", api)
        H.eq("edit_submit", action, "open")
        H.eq("edit_new_server", P.server_of(state), BASE)
        H.has(lines, "PKGGET_SERVER url=" .. P.plain(BASE, 60))
        H.eq("edit_no_space", P.valid_url("two words"), false)
        H.eq("edit_no_empty", P.valid_url("   "), false)
        H.eq("edit_too_long", P.valid_url(string.rep("x", 200)), false)
    end

    -- -----------------------------------------------------------------
    H.group("pkgget.keys")
    do
        local api = api_with(http_from(server()), nil)
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
        state.servers = { BASE, "http://second.example/" }
        H.eq("keys_server_cycle", P.dispatch_event(state, "key", "s", api), "repaint")
        H.eq("keys_server_second", P.server_of(state), "http://second.example/")
        H.eq("keys_server_wrap", P.dispatch_event(state, "key", "s", api), "repaint")
        H.eq("keys_server_first", P.server_of(state), BASE)
        -- the list has no entries and enter does nothing
        state.entries = {}
        state.index = 5
        H.eq("keys_empty_enter", P.dispatch_event(state, "key", "enter", api), "none")
        H.eq("pkgget_hint", P.HINT, "up/dn enter r reload a server q quit")
    end
end
