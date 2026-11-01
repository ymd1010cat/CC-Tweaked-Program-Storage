--[[- pyroet-os/tests/t_web.lua -- the built-in browser (system/system/web.app).

A text HTTP browser: `api.http.get(url)` -> body, wrapped to the screen, with
scroll / history / reload / quit. The http table is faked here: a fixed page, a
404 and a transport failure are the three cases the UI must survive.

No non-ASCII bytes in this file.
]]

local S = dofile("/tests/screen.lua")

_G.PYROET_BROWSER_TEST = true
local WEB = assert(loadfile("/system/system/web.app/main.lua"))()
_G.PYROET_BROWSER_TEST = nil

local KEYS = { up = 10, down = 11, enter = 14, escape = 15, q = 16 }

return function(H)
    local F = H.real_fs()

    local function host(events)
        local queue, index = {}, 0
        for i = 1, #events do queue[i] = events[i] end
        local hx = { keys = KEYS }
        function hx.pullEvent()
            index = index + 1
            local event = queue[index]
            if event == nil then return nil end
            return event[1], event[2]
        end
        return hx
    end

    local TEXT = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        .. " nu xi omicron pi rho sigma tau"

    local function api_with(http, events, buf)
        local log, lines = H.logger()
        return {
            fs = {
                read = function(path)
                    local text = F.exists(path) and H.read(path)
                    if text == nil then return nil, "missing" end
                    return text
                end,
            },
            http = http,
            input = host(events),
            terminal = buf,
            yield = function() end,
            log = log,
        }, lines
    end

    local function run(api, buf)
        local saved = rawget(_G, "PYROET_APP_NOPAINT")
        rawset(_G, "PYROET_APP_NOPAINT", nil)
        local ok, called, value = pcall(function()
            local fine, ret = S.with_term(buf, function()
                return WEB.body(nil, api)
            end)
            return fine, ret
        end)
        rawset(_G, "PYROET_APP_NOPAINT", saved)
        H.check("web_ran", ok and called == true, tostring(value))
        if ok and called == true then return value end
        return nil
    end

    -- -----------------------------------------------------------------
    H.group("web.manifest")
    do
        local raw = assert(loadfile("/system/system/web.app/manifest.lua"))()
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
    H.group("web.render")
    do
        local state = WEB.new_state({ fs = { read = function() return nil end } })
        H.eq("web_default_home", state.target, WEB.DEFAULT_HOME)
        H.eq("web_scheme_added", WEB.now_url("pastebin.com/raw/1"),
            "http://pastebin.com/raw/1")
        H.eq("web_scheme_kept", WEB.now_url("https://example.com/x"),
            "https://example.com/x")
        H.eq("web_empty_url", WEB.now_url("  "), "")

        local wrapped = WEB.wrap(TEXT, 20)
        H.ge("web_wrap_lines", #wrapped, 3)
        for i = 1, #wrapped do H.eq("web_wrap_width_" .. i, #wrapped[i] <= 20, true) end
        H.contains("web_wrap_first", wrapped[1], "alpha beta gamma")

        local lines = WEB.render(state, 51, 19)
        H.eq("web_rows", #lines, 19)
        H.contains("web_title", lines[1], "Browser 0.1.0")
        H.contains("web_url_row", lines[2], "url (enter opens home)")
        H.contains("web_hint", lines[19], "up/dn b back r reload q quit")
    end

    -- -----------------------------------------------------------------
    H.group("web.open")
    do
        H.mkdirp("/etc")
        H.write("/etc/browser.home", "example.com/text\n")
        local buf = S.buffer(51, 19)
        local home = WEB.home({ fs = { read = function() return H.read("/etc/browser.home") end } })
        H.eq("web_home_file", home, "http://example.com/text")
        H.rmrf("/etc/browser.home")

        -- 1) a fixed page: enter opens it, the body wraps, rows are the page
        local requests = {}
        local api, lines = api_with({
            get = function(url)
                requests[#requests + 1] = url
                return { ok = true, status = 200, body = TEXT }
            end,
        }, { { "key", "enter" }, { "char", "q" } }, buf)
        local result = run(api, buf)
        H.eq("web_quit", result, "quit")
        H.eq("web_request_url", requests[1], WEB.DEFAULT_HOME)
        H.has(lines, "BROWSER_OPEN url=" .. WEB.fit(WEB.DEFAULT_HOME, 60) .. " ok=true")
        local frame = buf.row(3)
        H.contains("web_row3", frame or "", "alpha beta gamma")
        H.contains("web_status", buf.row(18) or "", "200")
    end

    -- -----------------------------------------------------------------
    H.group("web.errors")
    do
        -- 2) a 404 is a readable status line, not a crash
        local buf = S.buffer(51, 19)
        local api, lines = api_with({
            get = function() return { ok = true, status = 404, body = "not found" } end,
        }, { { "char", "q" } }, buf)
        local result = run(api, buf)
        H.eq("web_404_quit", result, "quit")
        H.contains("web_404_status", buf.row(18) or "", "http 404")
        H.has(lines, "BROWSER_OPEN url=" .. WEB.fit(WEB.DEFAULT_HOME, 60)
            .. " ok=false status=404")

        -- 3) a transport failure is a readable error too
        local buf2 = S.buffer(51, 19)
        local api2, lines2 = api_with({
            get = function() return nil, "connection refused" end,
        }, { { "char", "q" } }, buf2)
        local result2 = run(api2, buf2)
        H.eq("web_fail_quit", result2, "quit")
        H.contains("web_fail_status", buf2.row(18) or "", "failed: connection refused")

        -- 4) no http host at all: the app says so and still quits with q
        local buf3 = S.buffer(51, 19)
        local api3, lines3 = api_with(nil, { { "char", "q" } }, buf3)
        local result3 = run(api3, buf3)
        H.eq("web_unavailable_quit", result3, "quit")
        H.contains("web_unavailable_status", buf3.row(18) or "",
            "browser unavailable")
        H.has(lines3, "BROWSER_UNAVAILABLE reason=no_http")
    end

    -- -----------------------------------------------------------------
    H.group("web.keys")
    do
        -- down scrolls, b goes back to the previous page, r reloads, q quits
        local buf = S.buffer(51, 19)
        local calls = {}
        local api, lines = api_with({
            get = function(url)
                calls[#calls + 1] = url
                return { ok = true, status = 200, body = TEXT .. " " .. TEXT }
            end,
        }, {
            { "key", "enter" },   -- open home
            { "key", "enter" },   -- open it again (pushes history)
            { "char", "b" },      -- back
            { "key", "down" },    -- scroll
            { "char", "r" },      -- reload
            { "char", "q" },      -- quit
        }, buf)
        local result = run(api, buf)
        H.eq("web_keys_quit", result, "quit")
        H.eq("web_keys_calls", #calls, 5)
        H.has(lines, "BROWSER_QUIT key=q")
        -- the history stack held the previous url while `b` opened it
        H.eq("web_history_empty_after_back", #(WEB.new_state(api).history or {}), 0)

        local state = WEB.new_state(api)
        state.lines = { "one", "two", "three", "four" }
        state.rows = 19
        H.eq("web_scroll_down", WEB.scroll(state, 1), "none")
        H.eq("web_scroll_floor", state.scroll, 0)
        state.lines = {}
        for i = 1, 40 do state.lines[i] = "line " .. i end
        H.eq("web_scroll_move", WEB.scroll(state, 2), "scroll")
        H.eq("web_scroll_value", state.scroll, 2)
        H.eq("web_scroll_max", WEB.scroll(state, 999) == "scroll", true)
        H.eq("web_scroll_top", WEB.scroll(state, -999) == "scroll", true)
        H.eq("web_scroll_zero", state.scroll, 0)
    end
end
