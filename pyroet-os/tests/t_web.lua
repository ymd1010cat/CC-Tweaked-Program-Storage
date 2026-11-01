--[[- pyroet-os/tests/t_web.lua -- the built-in browser (system/system/web.app).

The default page is the built-in `about:home`, so the first frame needs no
network. `local:/path` reads a file on this computer; `http(s)://` goes through
the host's http table (faked here).

No non-ASCII bytes in this file.
]]

_G.PYROET_BROWSER_TEST = true
local WEB = assert(loadfile("/tests/web.app/main.lua"))()
_G.PYROET_BROWSER_TEST = nil

local KEYS = { up = 10, down = 11, enter = 14, q = 16, b = 18, r = 19 }

return function(H)
    local F = H.real_fs()
    local TEXT = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"

    local function api_with(http)
        local log, lines = H.logger()
        return {
            fs = {
                read = function(path)
                    if not F.exists(path) then return nil, "no such file" end
                    return H.read(path)
                end,
            },
            http = http,
            input = { keys = KEYS, pullEvent = function() return nil end },
            yield = function() end,
            log = log,
        }, lines
    end

    -- -----------------------------------------------------------------
    H.group("web.manifest")
    do
        local raw = assert(loadfile("/tests/web.app/manifest.lua"))()
        local caps = {}
        for i = 1, #(raw.capabilities or {}) do caps[raw.capabilities[i]] = true end
        H.eq("web_name", raw.name, "web")
        H.eq("web_version", raw.version, "0.1.0")
        H.eq("web_cap_http", caps.http, true)
        H.eq("web_cap_input", caps.input, true)
        H.eq("web_cap_terminal", caps.terminal, true)
        H.eq("web_cap_read", caps["fs.read"], true)
        H.eq("web_cap_write", caps["fs.write"], nil)
    end

    -- -----------------------------------------------------------------
    H.group("web.helpers")
    do
        H.eq("web_default_home", WEB.DEFAULT_HOME, "about:home")
        H.eq("web_scheme_about", WEB.scheme("about:home"), "about")
        H.eq("web_scheme_local", WEB.scheme("local:/etc/page.txt"), "local")
        H.eq("web_scheme_http", WEB.scheme("http://x/y"), "http")
        H.eq("web_scheme_https", WEB.scheme("HTTPS://x/y"), "http")
        H.eq("web_scheme_none", WEB.scheme("example.com/x"), "")
        H.eq("web_scheme_ftp", WEB.scheme("ftp://x/y"), "ftp")
        H.eq("web_scheme_added", WEB.now_url("example.com/x"), "http://example.com/x")
        H.eq("web_scheme_kept", WEB.now_url("local:/etc/x"), "local:/etc/x")
        local wrapped = WEB.wrap(TEXT, 20)
        for i = 1, #wrapped do H.eq("web_wrap_width_" .. i, #wrapped[i] <= 20, true) end
        H.contains("web_wrap_first", wrapped[1], "alpha beta gamma")
    end

    -- -----------------------------------------------------------------
    H.group("web.about")
    do
        local api, lines = api_with(nil)
        local state = WEB.new_state(api)
        H.eq("about_target", state.target, "about:home")
        WEB.open(state, api, state.target)
        local frame = WEB.render(state, 51, 19)
        H.contains("about_row1", frame[1] or "", "Browser 0.1.0")
        local text = table.concat(frame, "\n")
        H.contains("about_keys", text, "enter   open the address below")
        H.contains("about_scroll", table.concat(state.lines, "\n"), "up/down scroll the page")
        H.contains("about_back", text, "b       back (history)")
        H.contains("about_reload", text, "r       reload")
        H.contains("about_quit", table.concat(state.lines, "\n"), "q       quit to the desktop")
        H.contains("about_config", table.concat(state.lines, "\n"), "/etc/browser.home")
        H.contains("about_local", table.concat(state.lines, "\n"), "local:/etc/page.txt")
        H.contains("about_nonet", table.concat(state.lines, "\n"), "no network? use local:")
        H.contains("about_status", frame[18] or "", "about:home")
        H.eq("about_hint", (frame[19] or ""):sub(1, 30), "up/dn b back r reload a edit q")
        H.contains("about_log", H.joined(lines), "BROWSER_OPEN url=about:home")
        H.eq("about_no_http", state.error, nil)
    end

    -- -----------------------------------------------------------------
    H.group("web.local")
    do
        H.write("/tests/page.txt", "page line one\npage line two\n")
        local api, lines = api_with(nil)
        local state = WEB.new_state(api)
        local action = WEB.open(state, api, "local:/tests/page.txt")
        H.eq("local_action", action, "open")
        H.contains("local_status", state.status, "local ")
        H.contains("local_body", table.concat(state.lines, " "), "page line one")
        H.contains("local_log", H.joined(lines), "BROWSER_OPEN url=local:/tests/page.txt")

        local state2 = WEB.new_state(api)
        local action2 = WEB.open(state2, api, "local:/tests/nope.txt")
        H.eq("local_missing_action", action2, "error")
        H.eq("local_missing_status", state2.status,
            "local: no such file: /tests/nope.txt")
        H.contains("local_missing_log", H.joined(lines), "BROWSER_OPEN url=local:/tests/nope.txt")

        local state3 = WEB.new_state(api)
        local action3 = WEB.open(state3, api, "ftp://example.com/x")
        H.eq("scheme_bad_action", action3, "error")
        H.eq("scheme_bad_status", state3.status, "unsupported scheme: ftp")
        H.rmrf("/tests/page.txt")
    end

    -- -----------------------------------------------------------------
    H.group("web.http")
    do
        local requests = {}
        local api, lines = api_with({
            get = function(url)
                requests[#requests + 1] = url
                return { ok = true, status = 200, body = TEXT }
            end,
        })
        local state = WEB.new_state(api)
        H.eq("http_action", WEB.open(state, api, "example.com/text"), "open")
        H.eq("http_url_completed", requests[1], "http://example.com/text")
        H.contains("http_body", table.concat(state.lines, " "), "alpha beta gamma")
        H.contains("http_status", state.status, "200")

        local api2, lines2 = api_with({
            get = function() return { ok = true, status = 404, body = "not found" } end,
        })
        local state2 = WEB.new_state(api2)
        H.eq("http_404_action", WEB.open(state2, api2, "http://x/y"), "error")
        H.eq("http_404_status", state2.status, "http 404")
        H.contains("http_404_log", H.joined(lines2), "BROWSER_OPEN url=http://x/y")

        local api3, lines3 = api_with({
            get = function() return nil, "connection refused" end,
        })
        local state3 = WEB.new_state(api3)
        H.eq("http_fail_action", WEB.open(state3, api3, "http://x/y"), "error")
        H.eq("http_fail_status", state3.status, "failed: connection refused")

        -- no http host at all: the first frame says so and q still quits
        local saved = rawget(_G, "PYROET_APP_NOPAINT")
        rawset(_G, "PYROET_APP_NOPAINT", true)
        local buf = { clear = function() end, write = function() end,
            setCursorPos = function() end, getSize = function() return 51, 19 end }
        local api4 = {
            fs = { read = function() return nil end },
            input = { keys = KEYS, pullEvent = function() return "char", "q" end },
            terminal = buf,
            yield = function() end,
            log = function() end,
        }
        local result = WEB.body(nil, api4)
        rawset(_G, "PYROET_APP_NOPAINT", saved)
        H.eq("http_none_quit", result, "quit")
    end

    -- -----------------------------------------------------------------
    H.group("web.config")
    do
        H.mkdirp("/etc")
        H.write("/etc/browser.home", "example.com/start\n")
        local api = api_with(nil)
        H.eq("config_home", WEB.home(api), "http://example.com/start")
        H.write("/etc/browser.home", "local:/tests/page.txt\n")
        H.eq("config_local", WEB.home(api), "local:/tests/page.txt")
        H.write("/etc/browser.home", "\n")
        H.eq("config_empty", WEB.home(api), "about:home")
        H.rmrf("/etc/browser.home")
        H.eq("config_absent", WEB.home(api), "about:home")

        -- a bad URL is a readable status line, and the file can be edited after
        H.write("/etc/browser.home", "no-such-host.invalid/x\n")
        local state = WEB.new_state(api)
        local api2 = api_with({
            get = function() return nil, "dns failure" end,
        })
        H.eq("config_bad_action", WEB.open(state, api2, state.target), "error")
        H.eq("config_bad_status", state.status, "failed: dns failure")
        H.write("/etc/browser.home", "local:/tests/page.txt\n")
        H.eq("config_reread", WEB.home(api), "local:/tests/page.txt")
        H.rmrf("/etc/browser.home")
    end

    -- -----------------------------------------------------------------
    H.group("web.edit")
    -- T11: the address bar is editable. `a` (or `/`) enters edit mode prefilled
    -- with the current address; printable chars append, backspace deletes, enter
    -- opens and `c` cancels. `q` is a letter while editing, never a quit.
    do
        local requests = {}
        local api, lines = api_with({
            get = function(url)
                requests[#requests + 1] = url
                return { ok = true, status = 200, body = TEXT }
            end,
        })
        local state = WEB.new_state(api)
        WEB.open(state, api, "about:home", { source = "home" })

        -- a) `a` enters edit mode prefilled with the current address
        H.eq("edit_begin", WEB.dispatch_event(state, "key", "a", api), "repaint")
        H.eq("edit_on", state.edit, true)
        H.eq("edit_prefill", state.edit_text, "about:home")
        H.has(lines, "BROWSER_EDIT begin url=about:home")

        -- b) the editor row: prompt, text and a cursor; the hint changes too
        local frame = WEB.render(state, 51, 19)
        H.contains("edit_row", frame[18] or "", "edit> about:home_")
        H.contains("edit_hint", frame[19] or "", "enter open c cancel bs del")

        -- c) typing an IP, then enter: the normalisation adds http://
        WEB.dispatch_event(state, "key", "c", api)   -- cancel, back to reading
        H.eq("edit_off", state.edit, nil)
        H.has(lines, "BROWSER_EDIT end reason=cancel")
        H.eq("edit_again", WEB.dispatch_event(state, "char", "a", api), "repaint")
        H.eq("edit_prefill2", state.edit_text, "about:home")
        state.edit_text = ""
        for i = 1, #"192.168.1.10" do
            local ch = ("192.168.1.10"):sub(i, i)
            WEB.dispatch_event(state, "char", ch, api)
        end
        H.eq("edit_text", state.edit_text, "192.168.1.10")
        H.eq("edit_submit", WEB.dispatch_event(state, "key", "enter", api), "open")
        H.eq("edit_off2", state.edit, nil)
        H.eq("edit_url", requests[#requests], "http://192.168.1.10")
        H.has(lines, "BROWSER_OPEN url=" .. WEB.fit("http://192.168.1.10", 60)
            .. " ok=true source=typed")

        -- d) editing accepts a port/path and the `local:` / `about:` forms
        state.edit = true
        state.edit_text = "192.168.1.10:8080/path"
        H.eq("edit_port_submit", WEB.dispatch_event(state, "key", "enter", api), "open")
        H.eq("edit_port_url", requests[#requests], "http://192.168.1.10:8080/path")
        state.edit = true
        state.edit_text = "local:/tests/page.txt"
        H.write("/tests/page.txt", "page body\n")
        H.eq("edit_local_submit", WEB.dispatch_event(state, "key", "enter", api), "open")
        H.contains("edit_local_body", table.concat(state.lines, " "), "page body")
        state.edit = true
        state.edit_text = "about:home"
        H.eq("edit_about_submit", WEB.dispatch_event(state, "key", "enter", api), "open")
        H.contains("edit_about_row", (WEB.render(state, 51, 19)[1] or ""), "Browser 0.1.0")

        -- e) backspace deletes one character; an empty line says so and stays
        state.edit = true
        state.edit_text = "abc"
        H.eq("edit_back", WEB.dispatch_event(state, "key", "backspace", api), "move")
        H.eq("edit_back_text", state.edit_text, "ab")
        state.edit_text = ""
        H.eq("edit_empty", WEB.dispatch_event(state, "key", "enter", api), "denied")
        H.eq("edit_empty_status", state.status, "empty address")
        H.eq("edit_empty_still", state.edit, true)

        -- f) `q` types a letter while editing (no quit), and `c` cancels
        H.eq("edit_q", WEB.dispatch_event(state, "char", "q", api), "move")
        H.eq("edit_q_text", state.edit_text, "q")
        H.eq("edit_c", WEB.dispatch_event(state, "key", "c", api), "repaint")
        H.eq("edit_c_off", state.edit, nil)
        H.eq("edit_q_reading_quits", WEB.dispatch_event(state, "char", "q", api), "quit")

        -- g) illegal addresses are refused with a readable status
        state.edit = true
        state.edit_text = "two words"
        H.eq("edit_space", WEB.dispatch_event(state, "key", "enter", api), "denied")
        H.eq("edit_space_status", state.status, "address has a space")
        state.edit_text = string.rep("x", 161)
        H.eq("edit_long", WEB.dispatch_event(state, "key", "enter", api), "denied")
        H.eq("edit_long_status", state.status, "address too long")
        H.eq("edit_still_on", state.edit, true)
        H.rmrf("/tests/page.txt")
    end

    -- -----------------------------------------------------------------
    H.group("web.keys")
    do
        local api, lines = api_with(nil)
        local state = WEB.new_state(api)
        WEB.open(state, api, "about:home")
        local function key(name)
            return WEB.dispatch_event(state, "key", name, nil, api)
        end
        H.eq("keys_quit", key("q"), "quit")
        H.eq("keys_quit_detail", select(2, key("q")), "q")
        H.eq("keys_enter", key("enter"), "open")
        H.eq("keys_reload", key("r"), "open")
        H.eq("keys_back_none", key("b"), "none")
        state.lines = {}
        for i = 1, 80 do state.lines[i] = "line " .. i end
        state.rows = 19
        state.scroll = 0
        H.eq("keys_down", key("down"), "scroll")
        H.eq("keys_down_value", state.scroll, 1)
        H.eq("keys_up", key("up"), "scroll")
        H.eq("keys_up_value", state.scroll, 0)

        local api2, lines2 = api_with({
            get = function() return { ok = true, status = 200, body = TEXT } end,
        })
        local state2 = WEB.new_state(api2)
        WEB.open(state2, api2, "example.com/a")
        WEB.open(state2, api2, "example.com/b")
        H.eq("keys_history", #state2.history, 1)
        H.eq("keys_back", WEB.dispatch_event(state2, "key", "b", api2), "open")
        H.eq("keys_back_url", state2.url, "http://example.com/a")
        H.eq("keys_back_empty", #state2.history, 0)
    end
end
