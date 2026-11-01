--[[- pyroet-os/system/system/pkgget.app/main.lua -- download a package over http.

The server is chosen by the user: `a` edits the address line (the first line of
/etc/pkg.servers is the default). Any static file server works -- the layout is
plain text, there is no zip and no JSON:

    GET <base>/index.txt              -> one "app <name> <version> <dir>" per line
    GET <base>/<dir>/files.txt        -> one relative path per line
    GET <base>/<dir>/<relpath>        -> the file body
    GET <base>/<dir>/SHA256.txt       -> optional "<sha256> <relpath>" lines

A download goes to /pkgs/<name>.app/ (files land as .part and are renamed when
complete; a failure removes everything downloaded so far), then the kernel
bridge (api.sys.install) puts it into /apps when it is available.

Keys (Esc is never used): up/down move, enter open/edit, r reload the index,
a edit the server, q quit. In the editor: printable chars append, backspace
deletes, enter accepts, c cancels (q is a letter there).

No non-ASCII bytes in this file. `_G.PYROET_PKGGET_TEST` returns the module.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 51, rows = 19 }
M.MIN_COLS = 18
M.MIN_ROWS = 8
M.CONF = "/etc/pkg.servers"
M.PLACEHOLDER = "http://example.invalid/"
M.PKGS = "/pkgs"
M.INDEX = "index.txt"
M.FILES = "files.txt"
M.SHA = "SHA256.txt"
M.MAX_URL = 160
M.MAX_FILES = 256
M.MAX_BODY = 262144
M.HINT = "up/dn enter r reload a server q quit"

function M.fit(text, cols)
    local value = tostring(text == nil and "" or text)
    if #value > cols then value = value:sub(1, cols) end
    while #value < cols do value = value .. " " end
    return value
end

function M.note(api, text)
    if type(api) ~= "table" or type(api.log) ~= "function" then return false end
    return pcall(api.log, text)
end

function M.plain(text, max)
    local value = tostring(text == nil and "" or text)
    value = value:gsub("[\r\n\t]+", " "):gsub("[^%w%._%-:=/%~%+]", "_")
    if max ~= nil and #value > max then value = value:sub(1, max) end
    return value
end

function M.trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.join(base, rest)
    local text = tostring(base or "")
    if text:sub(-1) ~= "/" then text = text .. "/" end
    return text .. tostring(rest or "")
end

-- ---------------------------------------------------------------------------
-- configuration: /etc/pkg.servers, one URL per line (the first is the default)
-- ---------------------------------------------------------------------------

function M.servers(api)
    local fsx = type(api) == "table" and api.fs or nil
    local out = {}
    if type(fsx) == "table" and type(fsx.read) == "function" then
        local called, text = pcall(fsx.read, M.CONF)
        if called and type(text) == "string" then
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local url = M.trim((line:gsub("\r", "")))
                if url ~= "" and url:sub(1, 1) ~= "#" and #url <= M.MAX_URL then
                    out[#out + 1] = url
                end
            end
        end
    end
    if #out == 0 then out[1] = M.PLACEHOLDER end
    return out
end

function M.new_state(api)
    local state = {
        servers = M.servers(api),
        server_index = 1,
        entries = {},
        index = 1,
        status = "",
        message = "",
        progress = nil,
        cols = M.VIEW.cols,
        rows = M.VIEW.rows,
    }
    state.server = state.servers[1]
    return state
end

function M.server_of(state)
    local list = state.servers or {}
    return list[state.server_index or 1] or list[1] or M.PLACEHOLDER
end

-- ---------------------------------------------------------------------------
-- http helpers
-- ---------------------------------------------------------------------------

function M.http_of(api)
    local http = type(api) == "table" and api.http or nil
    if type(http) ~= "table" or type(http.get) ~= "function" then return nil end
    return http
end

-- one GET -> body, status (nil, err when the transport failed)
function M.get(api, url)
    local http = M.http_of(api)
    if http == nil then return nil, nil, "no http" end
    local called, res, extra = pcall(http.get, url)
    if not called then return nil, nil, tostring(res) end
    if res == nil then return nil, nil, tostring(extra or "failed") end
    if type(res) == "string" then return res, 200 end
    if type(res) ~= "table" then return nil, nil, "bad response" end
    local status = tonumber(res.status) or (res.ok == false and 0 or 200)
    local body = type(res.body) == "string" and res.body or ""
    if status < 200 or status > 299 then return nil, status, "http " .. tostring(status) end
    return body, status
end

-- ---------------------------------------------------------------------------
-- index / files.txt / SHA256.txt parsing
-- ---------------------------------------------------------------------------

function M.parse_index(text, base)
    local entries, bad = {}, 0
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local clean = M.trim((line:gsub("\r", "")))
        if clean ~= "" then
            local tag, name, version, dir = clean:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
            if tag ~= "app" or name == nil or name:find("[/\\]") or name:find("..", 1, true)
                or #name > 40 then
                bad = bad + 1
            else
                entries[#entries + 1] = {
                    name = name,
                    version = version,
                    dir = dir,
                    base = base,
                }
            end
        end
    end
    return entries, bad
end

function M.parse_files(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local rel = M.trim((line:gsub("\r", "")))
        if rel ~= "" then
            -- a relative path only: no absolute paths, no "..", no backslashes
            if rel:sub(1, 1) == "/" or rel:find("..", 1, true) or rel:find("\\") then
                return nil, "bad path " .. M.plain(rel, 32)
            end
            out[#out + 1] = rel
            if #out > M.MAX_FILES then return nil, "too many files" end
        end
    end
    if #out == 0 then return nil, "no files" end
    return out
end

function M.parse_sha(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local clean = M.trim((line:gsub("\r", "")))
        local sha, rel = clean:match("^(%x+)%s+(%S+)$")
        if sha ~= nil and #sha == 64 then out[rel] = sha:lower() end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- rendering helpers
-- ---------------------------------------------------------------------------

function M.rows_for_list(state)
    return math.max(1, (state.rows or M.VIEW.rows) - 5)
end

function M.render(state, cols, rows)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    rows = math.floor(tonumber(rows) or M.VIEW.rows)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    if cols < M.MIN_COLS or rows < M.MIN_ROWS then
        return { M.fit("pkgget " .. tostring(#(state.entries or {})) .. " apps", cols) }
    end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("pkgget " .. M.VERSION)
    if state.editing then
        add("server> " .. tostring(state.edit_text or "") .. "_")
    else
        add("server: " .. M.server_of(state))
    end
    local area = rows - 4
    local entries = state.entries or {}
    local count = #entries + 1 -- row 1 is the server line
    local first = 1
    if count > area then
        first = math.max(1, (state.index or 1) - area + 1)
        if first + area - 1 > count then first = math.max(1, count - area + 1) end
    end
    for i = 0, area - 1 do
        local position = first + i
        if position == 1 then
            local marker = (state.index or 1) == 1 and ">" or " "
            add(marker .. " [server] " .. M.server_of(state))
        elseif position - 1 <= #entries then
            local entry = entries[position - 1]
            local marker = (state.index or 1) == position and ">" or " "
            add(marker .. " " .. tostring(entry.name) .. " " .. tostring(entry.version))
        else
            add("")
        end
    end
    local status = state.status ~= "" and state.status or state.message
    if state.progress ~= nil then status = state.progress end
    add(status ~= "" and status or "ready")
    if state.editing then
        add("enter accept c cancel bs del")
    else
        add(M.HINT)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

function M.load_index(state, api)
    local base = M.server_of(state)
    state.status = "loading index"
    state.editing = nil
    local body, status, err = M.get(api, M.join(base, M.INDEX))
    if body == nil then
        state.entries = {}
        state.index = 1
        state.status = "index " .. tostring(err or status)
        M.note(api, "PKGGET_INDEX ok=false server=" .. M.plain(base, 60)
            .. " err=" .. tostring(err or status))
        return "error"
    end
    local entries, bad = M.parse_index(body, base)
    state.entries = entries
    if state.index > #entries + 1 then state.index = 1 end
    state.status = #entries .. " apps"
    if bad > 0 then state.status = state.status .. " bad lines: " .. tostring(bad) end
    M.note(api, "PKGGET_INDEX ok=true entries=" .. tostring(#entries)
        .. " bad=" .. tostring(bad))
    return #entries > 0 and "open" or "none"
end

function M.selected_entry(state)
    local index = state.index or 1
    if index <= 1 then return nil end
    return (state.entries or {})[index - 1]
end

function M.move(state, delta)
    local count = #(state.entries or {}) + 1
    local index = (state.index or 1) + delta
    if index < 1 then index = 1 end
    if index > count then index = count end
    if index == state.index then return "none" end
    state.index = index
    return "move"
end

function M.cycle_server(state)
    local list = state.servers or {}
    if #list <= 1 then return "none" end
    state.server_index = (state.server_index or 1) + 1
    if state.server_index > #list then state.server_index = 1 end
    state.server = M.server_of(state)
    return "repaint"
end

function M.edit_begin(state, api)
    state.editing = true
    state.edit_text = M.server_of(state)
    M.note(api, "PKGGET_EDIT begin url=" .. M.plain(state.edit_text, 60))
    return "repaint"
end

function M.edit_end(state, api, why)
    state.editing = nil
    M.note(api, "PKGGET_EDIT end reason=" .. tostring(why or "cancel"))
    return "repaint"
end

function M.valid_url(text)
    local value = M.trim(text or "")
    if value == "" then return false, "empty address" end
    if #value > M.MAX_URL then return false, "address too long" end
    if value:find("%s") then return false, "address has a space" end
    return true
end

function M.edit_submit(state, api)
    local ok, why = M.valid_url(state.edit_text)
    if not ok then
        state.status = why
        return "denied", why
    end
    local value = M.trim(state.edit_text)
    state.servers = state.servers or {}
    table.insert(state.servers, 1, value)
    state.server_index = 1
    state.server = value
    state.editing = nil
    M.note(api, "PKGGET_EDIT end reason=accept url=" .. M.plain(value, 60))
    M.note(api, "PKGGET_SERVER url=" .. M.plain(value, 60))
    return M.load_index(state, api)
end

function M.edit_update(state, ch)
    local text = tostring(state.edit_text or "")
    if #text >= M.MAX_URL then
        state.status = "address too long"
        return "none"
    end
    state.edit_text = text .. tostring(ch)
    return "move"
end

function M.edit_delete(state)
    local text = tostring(state.edit_text or "")
    if text == "" then return "none" end
    state.edit_text = text:sub(1, -2)
    return "move"
end

-- ---------------------------------------------------------------------------
-- download
-- ---------------------------------------------------------------------------

function M.pkgs_of(api)
    return type(api) == "table" and api.fs or nil
end

function M.rm_tree(fsx, dir)
    if type(fsx) ~= "table" or type(fsx.list) ~= "function" then return end
    local called, names = pcall(fsx.list, dir)
    if not called or type(names) ~= "table" then return end
    for i = 1, #names do
        local path = dir .. "/" .. tostring(names[i])
        local is_dir = false
        if type(fsx.isDir) == "function" then
            local dcalled, value = pcall(fsx.isDir, path)
            is_dir = (dcalled and value) == true
        end
        if is_dir then
            M.rm_tree(fsx, path)
        elseif type(fsx.delete) == "function" then
            pcall(fsx.delete, path)
        end
    end
    if type(fsx.delete) == "function" then pcall(fsx.delete, dir) end
end

function M.parent_dir(path)
    return tostring(path):match("^(.*)/[^/]+$") or "/"
end

function M.make_parent(fsx, path)
    local dir = M.parent_dir(path)
    if dir == "/" or dir == "" then return true end
    if type(fsx.exists) == "function" and fsx.exists(dir) then return true end
    if type(fsx.makeDir) ~= "function" then return false end
    local called = pcall(fsx.makeDir, dir)
    return called
end

-- one file: GET -> .part -> rename; removes the part on any failure
function M.fetch_file(api, url, dest)
    local fsx = M.pkgs_of(api)
    if type(fsx) ~= "table" or type(fsx.write) ~= "function" then
        return nil, "no fs"
    end
    local body, status, err = M.get(api, url)
    if body == nil then return nil, tostring(err or status) end
    if #body > M.MAX_BODY then return nil, "file too large" end
    if not M.make_parent(fsx, dest) then return nil, "no directory" end
    local part = dest .. ".part"
    local called, ok = pcall(fsx.write, part, body)
    if not called or ok == false then
        pcall(fsx.delete, part)
        return nil, "write failed"
    end
    local check = true
    if type(fsx.read) == "function" then
        local rcalled, value = pcall(fsx.read, part)
        check = rcalled and value == body
    end
    if not check then
        pcall(fsx.delete, part)
        return nil, "write check failed"
    end
    if type(fsx.exists) == "function" and fsx.exists(dest)
        and type(fsx.delete) == "function" then
        pcall(fsx.delete, dest)
    end
    if type(fsx.move) == "function" then
        local mcalled = pcall(fsx.move, part, dest)
        if mcalled and (type(fsx.exists) ~= "function" or fsx.exists(dest)) then
            return true, #body
        end
    end
    pcall(fsx.write, dest, body)
    pcall(fsx.delete, part)
    return true, #body
end

function M.sha_of(body)
    local chunk = loadfile("/system/rpv/crypto.lua")
    if type(chunk) ~= "function" then return nil end
    local mod = {}
    local ok, ret = pcall(chunk, mod)
    local crypto = ok and (type(ret) == "table" and ret or mod) or nil
    if type(crypto) ~= "table" or type(crypto.sha256) ~= "function" then return nil end
    local called, digest = pcall(crypto.sha256, body)
    if not called or type(digest) ~= "string" then return nil end
    if type(crypto.hex) == "function" then
        local hcalled, hex = pcall(crypto.hex, digest)
        if hcalled and type(hex) == "string" then return hex:lower() end
    end
    return nil
end

-- download one entry into /pkgs/<name>.app; returns ok, info|err
function M.download(state, api, entry)
    local fsx = M.pkgs_of(api)
    if fsx == nil then
        state.status = "no fs"
        return nil, "no fs"
    end
    local base = M.join(entry.base or M.server_of(state), entry.dir)
    local files_body, _, ferr = M.get(api, M.join(base, M.FILES))
    if files_body == nil then
        state.status = "files " .. tostring(ferr)
        return nil, tostring(ferr)
    end
    local files, fwhy = M.parse_files(files_body)
    if files == nil then
        state.status = fwhy
        return nil, fwhy
    end
    -- the optional checksum list: present -> verify, absent -> say unverified
    local sha_body = M.get(api, M.join(base, M.SHA))
    local sha = type(sha_body) == "string" and M.parse_sha(sha_body) or nil
    local verified = sha ~= nil and next(sha) ~= nil
    local root = M.PKGS .. "/" .. entry.name .. ".app"
    local partial = root .. ".part"
    M.rm_tree(fsx, partial)
    if type(fsx.makeDir) == "function" then
        pcall(fsx.makeDir, partial)
        pcall(fsx.makeDir, M.PKGS)
    end
    local bytes = 0
    for i = 1, #files do
        local rel = files[i]
        state.progress = "fetching " .. rel .. " (" .. i .. "/" .. #files .. ")"
        local body, status, err = M.get(api, M.join(base, rel))
        if body == nil then
            state.progress = nil
            state.status = "failed " .. rel .. ": " .. tostring(err or status)
            M.rm_tree(fsx, partial)
            M.note(api, "PKGGET_FETCH name=" .. entry.name .. " ok=false file="
                .. M.plain(rel, 40) .. " err=" .. tostring(err or status))
            return nil, state.status
        end
        if verified then
            local want = sha[rel]
            if want ~= nil then
                local have = M.sha_of(body)
                if have == nil then
                    state.progress = nil
                    state.status = "sha unavailable for " .. rel
                    M.rm_tree(fsx, partial)
                    M.note(api, "PKGGET_FETCH name=" .. entry.name
                        .. " ok=false file=" .. M.plain(rel, 40) .. " err=sha_missing")
                    return nil, state.status
                end
                if have ~= want then
                    state.progress = nil
                    state.status = "hash check failed: " .. rel
                    M.rm_tree(fsx, partial)
                    M.note(api, "PKGGET_FETCH name=" .. entry.name
                        .. " ok=false file=" .. M.plain(rel, 40) .. " err=hash")
                    return nil, state.status
                end
            end
        end
        local ok, info = M.fetch_file(api, M.join(base, rel), partial .. "/" .. rel)
        if not ok then
            state.progress = nil
            state.status = "failed " .. rel .. ": " .. tostring(info)
            M.rm_tree(fsx, partial)
            M.note(api, "PKGGET_FETCH name=" .. entry.name .. " ok=false file="
                .. M.plain(rel, 40) .. " err=" .. tostring(info))
            return nil, state.status
        end
        bytes = bytes + (tonumber(info) or #body)
    end
    -- everything arrived: publish the directory
    M.rm_tree(fsx, root)
    if type(fsx.move) == "function" then
        pcall(fsx.move, partial, root)
    end
    local published = true
    if type(fsx.exists) == "function" then published = fsx.exists(root) == true end
    if not published then
        state.progress = nil
        state.status = "write failed: cannot rename"
        M.rm_tree(fsx, partial)
        return nil, state.status
    end
    state.progress = nil
    local vtext = verified and ", verified" or ", unverified"
    state.status = "staged " .. root .. " (" .. tostring(bytes) .. " B" .. vtext .. ")"
    local install_ok = nil
    local sysax = type(api) == "table" and api.sys or nil
    if type(sysax) == "table" and type(sysax.install) == "function" then
        local called, ok2, detail = pcall(sysax.install, entry.name)
        install_ok = called and ok2 == true
        M.note(api, "PKGGET_INSTALL name=" .. entry.name .. " ok="
            .. tostring(install_ok) .. (install_ok and "" or (" err="
                .. M.plain(detail, 40))))
        if install_ok then
            state.status = "installed " .. entry.name .. vtext
        else
            state.status = "staged in /pkgs (" .. M.plain(detail, 32) .. ")"
        end
    else
        state.status = "staged in /pkgs" .. vtext
        M.note(api, "PKGGET_INSTALL name=" .. entry.name .. " ok=false err=no_bridge")
    end
    M.note(api, "PKGGET_FETCH name=" .. entry.name .. " files=" .. tostring(#files)
        .. " bytes=" .. tostring(bytes) .. " ok=true")
    return true, { files = #files, bytes = bytes, verified = verified,
        install = install_ok, root = root }
end

function M.enter(state, api)
    if (state.index or 1) == 1 then return M.edit_begin(state, api) end
    local entry = M.selected_entry(state)
    if entry == nil then
        state.status = "nothing selected"
        return "none"
    end
    local ok, info = M.download(state, api, entry)
    if ok then return "install" end
    return "error"
end

-- ---------------------------------------------------------------------------
-- keys / loop
-- ---------------------------------------------------------------------------

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

function M.dispatch_event(state, event, p1, api)
    if state.editing then
        if event == "char" then
            local ch = tostring(p1 == nil and "" or p1)
            if ch == "" or ch == "\8" then return M.edit_delete(state) end
            local code = ch:byte(1)
            if code ~= nil and code >= 32 and code <= 126 then
                return M.edit_update(state, ch)
            end
            return "none"
        end
        if event == "key" then
            local key = p1
            if type(key) == "number" then
                key = M.code_name(key, api)
                if key == nil then return "none" end
            end
            key = tostring(key == nil and "" or key):lower()
            if key == "enter" then return M.edit_submit(state, api) end
            if key == "backspace" then return M.edit_delete(state) end
            if key == "c" then return M.edit_end(state, api, "cancel") end
            if key == "a" then return M.edit_update(state, "a") end
            return "none"
        end
        if event == "desk_focus" or event == "term_resize" then return "repaint" end
        return "none"
    end
    if event == "key" then
        local key = p1
        if type(key) == "number" then
            key = M.code_name(key, api)
            if key == nil then return "none" end
        end
        key = tostring(key == nil and "" or key):lower()
        if key == "q" then return "quit", "q" end
        if key == "up" then return M.move(state, -1) end
        if key == "down" then return M.move(state, 1) end
        if key == "enter" then return M.enter(state, api) end
        if key == "r" then return M.load_index(state, api) end
        if key == "a" then return M.edit_begin(state, api) end
        if key == "s" then return M.cycle_server(state) end
        return "none"
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1):lower()
        if ch == "q" then return "quit", "q" end
        if ch == "r" then return M.load_index(state, api) end
        if ch == "a" then return M.edit_begin(state, api) end
        if ch == "s" then return M.cycle_server(state) end
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
    if M.http_of(api) == nil then
        state.status = "pkgget unavailable: no http"
        M.paint_once(state, api, term)
        M.note(api, "PKGGET_UNAVAILABLE reason=no_http")
        if type(pull) ~= "function" then return M.idle(api) end
        while true do
            local event, p1 = pull()
            if event == nil then return M.idle(api) end
            local action, detail = M.dispatch_event(state, event, p1, api)
            if action == "quit" then return "quit" end
            if state.editing == nil and action ~= "none" then
                M.paint_once(state, api, term)
            end
        end
    end
    M.note(api, "PKGGET_SERVER url=" .. M.plain(M.server_of(state), 60))
    M.load_index(state, api)
    M.paint_once(state, api, term)
    if type(pull) ~= "function" then return M.idle(api) end
    while true do
        local event, p1 = pull()
        if event == nil then return M.idle(api) end
        local action, detail = M.dispatch_event(state, event, p1, api)
        if action == "quit" then
            M.note(api, "PKGGET_QUIT key=" .. tostring(detail))
            return "quit"
        end
        if action ~= "none" then M.paint_once(state, api, term) end
        api.yield()
    end
end

if rawget(_G, "PYROET_PKGGET_TEST") then return M end

return function(manifest, api)
    return M.body(manifest, api)
end
