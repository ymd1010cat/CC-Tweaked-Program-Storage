--[[- pyroet-os/system/system/web.app/main.lua -- a text HTTP browser.

Minimal, event driven, no graphics: open a URL, show the body as wrapped plain
text, scroll, go back, reload, quit. Nothing here parses HTML -- a page is a
string and the screen is a window over it.

Keys (never Esc: the ROM does not deliver it):
    enter   open the address (a missing http:// is added)
    up/down scroll
    b       back (history)
    r       reload
    q       quit

No non-ASCII bytes in this file. `_G.PYROET_BROWSER_TEST` returns the module.

No non-ASCII bytes in this file.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 51, rows = 19 }
M.MIN_COLS = 12
M.MIN_ROWS = 6
M.HOME_PATH = "/etc/browser.home"
M.DEFAULT_HOME = "about:home"
M.HISTORY_MAX = 8
M.MAX_BODY = 65536
M.HINT = "up/dn b back r reload q quit"

-- the built-in start page: always available, never a `failed:` first frame
function M.help_lines()
    return {
        "Browser " .. M.VERSION,
        "a text browser for Pyroet OS",
        "",
        "keys:",
        "  enter   open the address below",
        "  up/down scroll the page",
        "  b       back (history)",
        "  r       reload",
        "  q       quit to the desktop",
        "",
        "addresses:",
        "  http://host/path   http (api.http)",
        "  https://host/path  https (api.http)",
        "  local:/etc/page.txt  a file on this computer",
        "  about:home         this page",
        "",
        "home page: put one URL on the first line of",
        "  /etc/browser.home",
        "",
        "no network? use local: -- the file system",
        "always works, and the page is plain text.",
    }
end

-- "about:home" / "local:/path" / "http(s)://..." / no scheme at all
function M.scheme(url)
    local text = tostring(url == nil and "" or url):lower()
    if text == "about:home" then return "about" end
    local name = text:match("^([%a][%w+.-]*):")
    if name == nil then return "" end
    if name == "http" or name == "https" then return "http" end
    if name == "local" then return "local" end
    if name == "about" then return "about" end
    return name
end

function M.fit(text, cols)
    local value = tostring(text == nil and "" or text)
    if #value > cols then value = value:sub(1, cols) end
    while #value < cols do value = value .. " " end
    return value
end

function M.now_url(url)
    local text = tostring(url == nil and "" or url)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "" end
    if M.scheme(text) ~= "" then return text end
    return "http://" .. text
end

-- wrap a body into the view width; tabs and control bytes become spaces so a
-- pastebin page cannot move the cursor itself
function M.wrap(body, cols, max_lines)
    local out = {}
    local text = tostring(body == nil and "" or body)
    text = text:gsub("[\r\n\t]+", " "):gsub("%c", " ")
    local width = math.max(1, math.floor(cols or M.VIEW.cols))
    local limit = max_lines or 4000
    local i = 1
    while i <= #text and #out < limit do
        out[#out + 1] = text:sub(i, i + width - 1)
        i = i + width
    end
    if #out == 0 then out[1] = "" end
    return out
end

function M.home(api)
    local fsx = type(api) == "table" and api.fs or nil
    local called, text = false, nil
    if type(fsx) == "table" and type(fsx.read) == "function" then
        called, text = pcall(fsx.read, M.HOME_PATH)
    end
    if called and type(text) == "string" then
        local line = text:match("^%s*([^\r\n]+)")
        if line ~= nil then
            line = line:gsub("%s+$", "")
            if line ~= "" then
                -- a URL in the config is used as written; only a scheme-less
                -- address gets http:// (that is what "bad url" then reports)
                if M.scheme(line) == "" then line = M.now_url(line) end
                return line
            end
        end
    end
    return M.DEFAULT_HOME
end

function M.new_state(api)
    return {
        url = "",
        target = M.home(api),
        lines = {},
        status = "",
        error = nil,
        history = {},
        scroll = 0,
        http_ok = type(type(api) == "table" and api.http or nil) == "table",
    }
end

function M.note(api, text)
    if type(api) ~= "table" or type(api.log) ~= "function" then return false end
    return pcall(api.log, text)
end

-- one fetch: a 2xx body is the page, anything else is a readable status line
function M.open(state, api, url, opts)
    local o = opts or {}
    local raw = tostring(url == nil and "" or url):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        state.status = "empty address"
        return "none"
    end
    local kind = M.scheme(raw)
    -- 1) the built-in page: no fs, no network
    if kind == "about" then
        if raw:lower() ~= "about:home" then
            state.error = "unsupported scheme: " .. tostring(kind)
            state.status = state.error
            return "error"
        end
        state.url = "about:home"
        state.target = "about:home"
        local help = {}
        local source = M.help_lines()
        for i = 1, #source do
            local line = tostring(source[i])
            if #line <= M.VIEW.cols then
                help[#help + 1] = line
            else
                local parts = M.wrap(line, M.VIEW.cols)
                for j = 1, #parts do help[#help + 1] = parts[j] end
            end
        end
        state.lines = help
        state.error = nil
        state.status = "about:home " .. tostring(#state.lines) .. " lines"
        state.scroll = 0
        M.note(api, "BROWSER_OPEN url=about:home ok=true")
        return "open"
    end
    -- 2) a local file: plain text from this computer's own file system
    if kind == "local" then
        local path = raw:match("^[Ll][Oo][Cc][Aa][Ll]:(.*)$") or ""
        path = path:gsub("^%s+", ""):gsub("%s+$", "")
        local body, err = nil, nil
        local fsx = type(api) == "table" and api.fs or nil
        if path == "" then
            err = "no path"
        elseif type(fsx) ~= "table" or type(fsx.read) ~= "function" then
            err = "no fs host"
        else
            local called, value = pcall(fsx.read, path)
            if not called then body, err = nil, tostring(value)
            elseif type(value) ~= "string" then body, err = nil, "no such file: " .. path
            else body = value end
        end
        if body == nil then
            state.url = raw
            state.target = raw
            state.error = "local: " .. tostring(err)
            state.status = "local: " .. tostring(err)
            M.note(api, "BROWSER_OPEN url=" .. M.fit(raw, 60) .. " ok=false err="
                .. tostring(err))
            return "error"
        end
        if o.push ~= false then
            if state.url ~= "" then
                state.history[#state.history + 1] = state.url
                while #state.history > M.HISTORY_MAX do table.remove(state.history, 1) end
            end
        end
        state.url = raw
        state.target = raw
        state.lines = M.wrap(body, M.VIEW.cols)
        state.error = nil
        state.status = "local " .. tostring(#body) .. " bytes "
            .. tostring(#state.lines) .. " lines"
        state.scroll = 0
        M.note(api, "BROWSER_OPEN url=" .. M.fit(raw, 60) .. " ok=true lines="
            .. tostring(#state.lines))
        return "open"
    end
    -- 3) anything else with an explicit scheme is not ours
    if kind ~= "" and kind ~= "http" then
        state.error = "unsupported scheme: " .. tostring(kind)
        state.status = state.error
        M.note(api, "BROWSER_OPEN url=" .. M.fit(raw, 60) .. " ok=false unsupported="
            .. tostring(kind))
        return "error"
    end
    local target = M.now_url(raw)
    if target == "" then
        state.status = "empty address"
        return "none"
    end
    local function http_get(u)
        local http = type(api) == "table" and api.http or nil
        if type(http) ~= "table" or type(http.get) ~= "function" then
            return nil, "no http host"
        end
        local called, res, extra = pcall(http.get, u)
        if not called then return nil, tostring(res) end
        if res == nil then return nil, extra end
        return res
    end
    local called, res, err = pcall(http_get, target)
    if not called then res, err = nil, tostring(res) end
    if type(res) == "string" then res = { ok = true, status = 200, body = res } end
    if type(res) ~= "table" then
        state.error = tostring(err or "failed")
        state.status = "failed: " .. state.error
        M.note(api, "BROWSER_OPEN url=" .. M.fit(target, 60) .. " ok=false err=" .. state.status)
        return "error"
    end
    local status = tonumber(res.status) or (res.ok == false and 0 or 200)
    local body = res.body
    if type(body) ~= "string" then body = "" end
    if #body > M.MAX_BODY then body = body:sub(1, M.MAX_BODY) end
    if status < 200 or status > 299 then
        state.error = "http " .. tostring(status)
        state.status = "http " .. tostring(status)
        state.lines = M.wrap(body, M.VIEW.cols)
        state.scroll = 0
        M.note(api, "BROWSER_OPEN url=" .. M.fit(target, 60) .. " ok=false status="
            .. tostring(status))
        return "error"
    end
    if o.push ~= false then
        if state.url ~= "" then
            state.history[#state.history + 1] = state.url
            while #state.history > M.HISTORY_MAX do table.remove(state.history, 1) end
        end
    end
    state.url = target
    state.target = target
    state.lines = M.wrap(body, M.VIEW.cols)
    state.error = nil
    state.status = tostring(status) .. " " .. tostring(#body) .. " bytes "
        .. tostring(#state.lines) .. " lines"
    state.scroll = 0
    M.note(api, "BROWSER_OPEN url=" .. M.fit(target, 60) .. " ok=true status="
        .. tostring(status) .. " lines=" .. tostring(#state.lines))
    return "open"
end

function M.max_scroll(state)
    local rows = state.rows or M.VIEW.rows
    local page = math.max(1, rows - 5)
    return math.max(0, #(state.lines or {}) - page)
end

function M.scroll(state, delta)
    local limit = M.max_scroll(state)
    local value = (state.scroll or 0) + delta
    if value < 0 then value = 0 end
    if value > limit then value = limit end
    if value == state.scroll then return "none" end
    state.scroll = value
    return "scroll"
end

function M.back(state, api)
    local previous = state.history[#state.history]
    if previous == nil then
        state.status = "no history"
        return "none"
    end
    state.history[#state.history] = nil
    local action = M.open(state, api, previous, { push = false })
    if action == "open" then state.status = "back " .. tostring(state.status) end
    return action
end

function M.render(state, cols, rows)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    rows = math.floor(tonumber(rows) or M.VIEW.rows)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    if cols < M.MIN_COLS or rows < M.MIN_ROWS then
        return { M.fit("browser " .. tostring(#(state.lines or {})) .. " lines", cols) }
    end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("Browser " .. M.VERSION)
    add("url " .. (state.url ~= "" and state.url or "(enter opens home)"))
    local page = rows - 4
    local first = (state.scroll or 0) + 1
    local lines = state.lines or {}
    for i = 0, page - 1 do
        local line = lines[first + i]
        add(line == nil and "" or line)
    end
    add(state.status ~= "" and state.status or M.HINT)
    add(M.HINT)
    return out
end

function M.key_map(keysx)
    local out = {}
    if type(keysx) ~= "table" then return out end
    for name, code in pairs(keysx) do
        if type(name) == "string" and type(code) == "number" and out[code] == nil then
            out[code] = name
        end
    end
    return out
end

function M.keys_table(api)
    local input = type(api) == "table" and api.input or nil
    local keysx = type(input) == "table" and input.keys or nil
    if type(keysx) == "table" and next(keysx) ~= nil then return keysx end
    return rawget(_G, "keys")
end

function M.code_name(code, api)
    local keysx = M.keys_table(api)
    if M.map_source ~= keysx then
        M.map_source = keysx
        M.map = M.key_map(keysx)
    end
    return (M.map or {})[code]
end

function M.quit_key(key, api)
    if type(key) == "number" then
        if key == M.ESCAPE_CODE then return false end
        local name = M.code_name(key, api)
        if name == nil then return false end
        key = name
    end
    if type(key) ~= "string" then return false end
    return key:lower() == "q"
end

M.ESCAPE_CODE = 256

-- one delivered event -> one action; "quit" ends the app
function M.dispatch_event(state, event, p1, api)
    if event == "key" then
        if M.quit_key(p1, api) then return "quit", "q" end
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        key = tostring(key == nil and "" or key):lower()
        if key == "enter" then return M.open(state, api, state.target or state.url) end
        if key == "up" then return M.scroll(state, -1) end
        if key == "down" then return M.scroll(state, 1) end
        if key == "b" then return M.back(state, api) end
        if key == "r" then return M.open(state, api, state.url) end
        return "none"
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1):lower()
        if ch == "q" then return "quit", "q" end
        if ch == "b" then return M.back(state, api) end
        if ch == "r" then return M.open(state, api, state.url) end
        return "none"
    end
    if event == "desk_focus" or event == "term_resize" then return "repaint" end
    if event == "terminate" or event == "shutdown" then return "quit", event end
    return "none"
end

function M.clear(term)
    local t = term or rawget(_G, "term")
    if type(t) ~= "table" or type(t.clear) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(t.clear))
end

function M.paint(lines, term_api)
    local t = term_api or rawget(_G, "term")
    if type(t) ~= "table" or type(t.write) ~= "function" then return false end
    if rawget(_G, "PYROET_APP_NOPAINT") then return false end
    return (pcall(function()
        for i = 1, #lines do
            t.setCursorPos(1, i)
            t.write(lines[i])
        end
    end))
end

function M.view_size(term_api)
    local cols, rows = M.VIEW.cols, M.VIEW.rows
    local t = term_api or rawget(_G, "term")
    if type(t) == "table" and type(t.getSize) == "function" then
        local ok, w, h = pcall(t.getSize)
        if ok and type(w) == "number" and type(h) == "number" then
            cols = math.min(cols, math.max(1, math.floor(w)))
            rows = math.min(rows, math.max(1, math.floor(h)))
        end
    end
    return cols, rows
end

function M.paint_once(state, api, term)
    local cols, rows = M.view_size(term)
    state.cols, state.rows = cols, rows
    local lines = M.render(state, cols, rows)
    M.clear(term)
    M.paint(lines, term)
    state.painted = (state.painted or 0) + 1
    return lines
end

function M.idle(api)
    if type(api) == "table" and type(api.yield) == "function" then api.yield() end
    return "idle"
end

function M.body(manifest, api)
    local state = M.new_state(api)
    state.manifest = manifest
    local term = type(api) == "table" and api.terminal or nil
    local input = type(api) == "table" and api.input or nil
    local pull = type(input) == "table" and input.pullEvent or nil
    if type(api) == "table" and type(api.http) ~= "table" then
        state.status = "browser unavailable: no http host"
        M.paint_once(state, api, term)
        M.note(api, "BROWSER_UNAVAILABLE reason=no_http")
        if type(pull) ~= "function" then return M.idle(api) end
        while true do
            local event, p1 = pull()
            if event == nil then return M.idle(api) end
            local action, detail = M.dispatch_event(state, event, p1, api)
            if action == "quit" then
                M.note(api, "BROWSER_QUIT key=" .. tostring(detail))
                return "quit"
            end
            if action ~= "none" then M.paint_once(state, api, term) end
            api.yield()
        end
    end
    M.open(state, api, state.target)
    M.paint_once(state, api, term)
    M.note(api, "BROWSER_READY url=" .. M.fit(state.url, 60)
        .. " lines=" .. tostring(#(state.lines or {})))
    if type(pull) ~= "function" then
        M.note(api, "BROWSER_NO_INPUT")
        return M.idle(api)
    end
    while true do
        local event, p1 = pull()
        if event == nil then
            M.note(api, "BROWSER_NO_INPUT")
            return M.idle(api)
        end
        local action, detail = M.dispatch_event(state, event, p1, api)
        if action == "quit" then
            M.note(api, "BROWSER_QUIT key=" .. tostring(detail))
            return "quit"
        end
        if action ~= "none" then M.paint_once(state, api, term) end
        api.yield()
    end
end

if rawget(_G, "PYROET_BROWSER_TEST") then return M end

return function(manifest, api)
    return M.body(manifest, api)
end
