--[[- pyroet-os/system/system/appstore.app/main.lua -- download a package over http.

The server is chosen by the user: `a` edits the address line (the first line of
/etc/appstore.servers is the default). Any static file server works -- the layout is
plain text, there is no zip and no JSON:

    GET <base>/index.txt              -> one "app <name> <version> <dir>" per line
    GET <base>/<dir>/files.txt        -> one relative path per line
    GET <base>/<dir>/<relpath>        -> the file body
    GET <base>/<dir>/SHA256.txt       -> optional "<sha256> <relpath>" lines

A download goes to /pkgs/<name>.app/ (files land as .part and are renamed when
complete; a failure removes everything downloaded so far), then the kernel
bridge (api.sys.install) puts it into /apps when it is available.

A pocket computer has no drive, so it only ever writes its own /pkgs. A block
computer with the handheld in a disk drive does have /disk, so the start-up
probe (fs.exists + fs.isDir) makes the target selectable: `t` switches between
self (/pkgs) and disk (/disk/pkgs). The status row always shows the choice as
`target self` or `target disk`. A disk download is writing only -- there is no
api.sys.install call, because the block computer cannot install onto the
handheld -- and it ends with `written to disk`; take the handheld out and let
its own installer install the package. Without /disk the target stays self and
`t` only says `no disk drive`.

Keys (Esc is never used): up/down move, enter open/edit, r reload the index,
a edit the server, t switch target, q quit. In the editor: printable chars
append, backspace deletes, enter accepts, c cancels (q is a letter there).
`l` arms the receiver described below.

Receiver mode (the other computer runs tools/pushpkg.lua): press `l` to listen
on rednet channel 4101 under protocol PYROET-PKG/1; /etc/appstore.recv may override
`channel=` and `protocol=`. While armed the status row shows `listening ch=4101`
plus this computer's id, and `q` stops listening. One package is one stream:

    {kind="begin", name=, version=, pkg="app"|"lua", files=}
    {kind="file", rel=, data=, chunk=, chunks=}      one per chunk (<= 8 KiB)
    {kind="end", sha=}                               sha is optional

and every message is answered with {kind="ack", ok=bool, err=..}. Files land
under /pkgs/<name>.app.part and the tree is renamed to /pkgs/<name>.app only
after every file read back and the end digest (if sent) matched; any failure
deletes the .part tree, so a half package never becomes visible. A published
package is installed through the kernel bridge when the host has one.

No non-ASCII bytes in this file. `_G.PYROET_APPSTORE_TEST` returns the module.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 51, rows = 19 }
M.MIN_COLS = 18
M.MIN_ROWS = 8
M.CONF = "/etc/appstore.servers"
M.PLACEHOLDER = "http://example.invalid/"
M.PKGS = "/pkgs"
M.DISK = "/disk"
M.DISK_PKGS = "/disk/pkgs"
M.INDEX = "index.txt"
M.FILES = "files.txt"
M.SHA = "SHA256.txt"
M.MAX_URL = 160
M.MAX_FILES = 256
M.MAX_BODY = 262144
M.HINT = "up/dn enter r reload a url q quit l recv t target"
M.RECV_PROTOCOL = "PYROET-PKG/1"
M.RECV_CHANNEL = 4101
M.RECV_CONF = "/etc/appstore.recv"
M.RECV_TIMEOUT = 0.1
M.RECV_IDLE = 120
M.MAX_CHUNK = 8192
M.MAX_CHUNKS = 256
M.MAX_REL = 96
M.MAX_RECV = 262144

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

-- one line, spaces kept: protocol strings (an ack err, a role) stay readable
function M.oneline(text, max)
    local value = tostring(text == nil and "" or text):gsub("[\r\n\t]+", " ")
    if max ~= nil and #value > max then value = value:sub(1, max) end
    return value
end

function M.join(base, rest)
    local text = tostring(base or "")
    if text:sub(-1) ~= "/" then text = text .. "/" end
    return text .. tostring(rest or "")
end

-- ---------------------------------------------------------------------------
-- configuration: /etc/appstore.servers, one URL per line (the first is the default)
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

-- a block computer with the handheld in a drive has /disk; a pocket computer has
-- no drive, so there is nothing to select and the target stays self
function M.probe_disk(api)
    local fsx = type(api) == "table" and api.fs or nil
    if type(fsx) ~= "table" or type(fsx.exists) ~= "function"
        or type(fsx.isDir) ~= "function" then
        return false
    end
    local called, has = pcall(fsx.exists, M.DISK)
    if not called or has ~= true then return false end
    local dcalled, is_dir = pcall(fsx.isDir, M.DISK)
    return dcalled and is_dir == true
end

function M.target_of(state)
    if type(state) == "table" and state.target == "disk" then return "disk" end
    return "self"
end

-- "" for this machine's own /pkgs, "/disk" for the drive in the block computer
function M.target_root(state)
    if M.target_of(state) == "disk" then return M.DISK end
    return ""
end

function M.pkgs_root(state)
    return M.target_root(state) .. M.PKGS
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
        target = "self",
        disk = M.probe_disk(api),
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
        return { M.fit("appstore " .. tostring(#(state.entries or {})) .. " apps", cols) }
    end
    local out = {}
    local function add(text)
        if #out >= rows then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("appstore " .. M.VERSION)
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
    add("target " .. M.target_of(state) .. "  " .. (status ~= "" and status or "ready"))
    if state.editing then
        add("enter accept c cancel bs del")
    elseif type(state.recv) == "table" then
        add("q stop listening")
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
        M.note(api, "APPSTORE_INDEX ok=false server=" .. M.plain(base, 60)
            .. " err=" .. tostring(err or status))
        return "error"
    end
    local entries, bad = M.parse_index(body, base)
    state.entries = entries
    if state.index > #entries + 1 then state.index = 1 end
    state.status = #entries .. " apps"
    if bad > 0 then state.status = state.status .. " bad lines: " .. tostring(bad) end
    M.note(api, "APPSTORE_INDEX ok=true entries=" .. tostring(#entries)
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

-- `t`: self <-> disk. The drive can appear or go away between presses, so this
-- re-probes; a machine without the drive only says so and keeps writing /pkgs.
function M.cycle_target(state, api)
    if M.probe_disk(api) ~= true then
        state.disk = false
        state.target = "self"
        state.status = "no disk drive"
        M.note(api, "APPSTORE_TARGET ok=false err=no_disk")
        return "repaint"
    end
    state.disk = true
    state.target = (M.target_of(state) == "disk") and "self" or "disk"
    state.status = ""
    M.note(api, "APPSTORE_TARGET ok=true target=" .. state.target
        .. " root=" .. M.pkgs_root(state))
    return "repaint"
end

function M.edit_begin(state, api)
    state.editing = true
    state.edit_text = M.server_of(state)
    M.note(api, "APPSTORE_EDIT begin url=" .. M.plain(state.edit_text, 60))
    return "repaint"
end

function M.edit_end(state, api, why)
    state.editing = nil
    M.note(api, "APPSTORE_EDIT end reason=" .. tostring(why or "cancel"))
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
    M.note(api, "APPSTORE_EDIT end reason=accept url=" .. M.plain(value, 60))
    M.note(api, "APPSTORE_SERVER url=" .. M.plain(value, 60))
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
    local pkgs = M.pkgs_root(state)
    local root = pkgs .. "/" .. entry.name .. ".app"
    local partial = root .. ".part"
    M.rm_tree(fsx, partial)
    if type(fsx.makeDir) == "function" then
        pcall(fsx.makeDir, partial)
        pcall(fsx.makeDir, pkgs)
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
            M.note(api, "APPSTORE_FETCH name=" .. entry.name .. " ok=false file="
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
                    M.note(api, "APPSTORE_FETCH name=" .. entry.name
                        .. " ok=false file=" .. M.plain(rel, 40) .. " err=sha_missing")
                    return nil, state.status
                end
                if have ~= want then
                    state.progress = nil
                    state.status = "hash check failed: " .. rel
                    M.rm_tree(fsx, partial)
                    M.note(api, "APPSTORE_FETCH name=" .. entry.name
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
            M.note(api, "APPSTORE_FETCH name=" .. entry.name .. " ok=false file="
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
    local target = M.target_of(state)
    local install_ok = nil
    if target == "disk" then
        -- write only: the block computer cannot install onto the handheld
        state.status = "written to disk " .. root .. " (" .. tostring(bytes)
            .. " B" .. vtext .. ")"
        M.note(api, "APPSTORE_WRITE ok=true target=disk name=" .. entry.name
            .. " files=" .. tostring(#files) .. " bytes=" .. tostring(bytes))
    else
        state.status = "staged " .. root .. " (" .. tostring(bytes) .. " B" .. vtext .. ")"
        local sysax = type(api) == "table" and api.sys or nil
        if type(sysax) == "table" and type(sysax.install) == "function" then
            local called, ok2, detail = pcall(sysax.install, entry.name)
            install_ok = called and ok2 == true
            M.note(api, "APPSTORE_INSTALL name=" .. entry.name .. " ok="
                .. tostring(install_ok) .. (install_ok and "" or (" err="
                    .. M.plain(detail, 40))))
            if install_ok then
                state.status = "installed " .. entry.name .. vtext
            else
                state.status = "staged in /pkgs (" .. M.plain(detail, 32) .. ")"
            end
        else
            state.status = "staged in /pkgs" .. vtext
            M.note(api, "APPSTORE_INSTALL name=" .. entry.name
                .. " ok=false err=no_bridge")
        end
    end
    M.note(api, "APPSTORE_FETCH name=" .. entry.name .. " files=" .. tostring(#files)
        .. " bytes=" .. tostring(bytes) .. " ok=true")
    return true, { files = #files, bytes = bytes, verified = verified,
        install = install_ok, target = target, root = root }
end

-- ---------------------------------------------------------------------------
-- receiver: a package streamed over rednet by pushpkg on another computer
-- ---------------------------------------------------------------------------

-- /etc/appstore.recv (optional): `channel=<1..65532>` and `protocol=<name>` lines.
-- A missing or unreadable file is the normal case and means the defaults.
function M.recv_conf(api)
    local out = { channel = M.RECV_CHANNEL, protocol = M.RECV_PROTOCOL,
        path = M.RECV_CONF }
    local fsx = M.pkgs_of(api)
    if type(fsx) ~= "table" or type(fsx.read) ~= "function" then return out end
    local called, text = pcall(fsx.read, M.RECV_CONF)
    if not called or type(text) ~= "string" then return out end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local clean = M.trim((line:gsub("\r", "")))
        local key, value = clean:match("^([%w_]+)%s*=%s*(%S+)$")
        if key == "channel" then
            local number = tonumber(value)
            if number and number >= 1 and number <= 65532
                and number == math.floor(number) then
                out.channel = number
            end
        elseif key == "protocol" and #value <= 32
            and not value:find("[^\32-\126]") then
            out.protocol = value
        end
    end
    return out
end

-- the rednet table this package may use: the runtime grants net.rednet, and a
-- direct run inside the ROM shell falls back to the global
function M.rednet_of(api)
    local net = type(api) == "table" and type(api.net) == "table"
        and api.net.rednet or nil
    if type(net) == "table" and type(net.receive) == "function" then return net end
    local glob = rawget(_G, "rednet")
    if type(glob) == "table" and type(glob.receive) == "function" then return glob end
    return nil
end

-- a zero-timeout receive tells a real rednet table from the capability stub: the
-- stub answers `nil, "capability denied: net.rednet"` instead of a timeout
function M.rednet_probe(net, protocol)
    if type(net) ~= "table" or type(net.receive) ~= "function" then
        return nil, "no_rednet"
    end
    local ok, sender, message = pcall(net.receive, protocol, 0)
    if not ok then return nil, "no_rednet" end
    if sender == nil and type(message) == "string"
        and message:find("capability", 1, true) then
        return nil, "no_rednet"
    end
    if sender ~= nil then return net, nil, sender, message end
    return net, nil
end

-- open every attached modem, so rednet receives the broadcast channel
function M.open_modems(net)
    if type(net) ~= "table" or type(net.open) ~= "function" then return 0 end
    local per = rawget(_G, "peripheral")
    local names = type(per) == "table" and type(per.getNames) == "function"
        and per.getNames() or nil
    if type(names) ~= "table" then return 0 end
    local opened = 0
    for i = 1, #names do
        if pcall(net.open, names[i]) then opened = opened + 1 end
    end
    return opened
end

function M.computer_id()
    local osx = rawget(_G, "os")
    if type(osx) == "table" and type(osx.getComputerID) == "function" then
        local ok, id = pcall(osx.getComputerID)
        if ok and id ~= nil then return id end
    end
    return "?"
end

function M.recv_arm(state, api)
    if type(state.recv) == "table" then
        state.status = "listening ch=" .. tostring(state.recv.channel)
        return "repaint"
    end
    local conf = M.recv_conf(api)
    local net, why, sender, message = M.rednet_probe(M.rednet_of(api),
        conf.protocol)
    if net == nil then
        state.status = "no rednet"
        M.note(api, "APPSTORE_RECV_ARM ok=false err=" .. tostring(why))
        return "denied", why
    end
    local opened = M.open_modems(net)
    state.recv = { channel = conf.channel, protocol = conf.protocol,
        path = conf.path, net = net, clock = state.recv_clock or os.clock }
    state.status = "listening ch=" .. tostring(conf.channel)
        .. " id=" .. tostring(M.computer_id())
    M.note(api, "APPSTORE_RECV_ARM ch=" .. tostring(conf.channel)
        .. " protocol=" .. M.plain(conf.protocol, 32)
        .. " modems=" .. tostring(opened))
    if sender ~= nil then M.recv_message(state, api, sender, message) end
    return "repaint"
end

function M.recv_stop(state, api)
    local recv = state.recv
    if type(recv) ~= "table" then return "none" end
    if recv.pkg then M.recv_cleanup(api, recv) end
    state.recv = nil
    state.status = "receiver stopped"
    M.note(api, "APPSTORE_RECV_STOP")
    return "repaint"
end

function M.recv_cleanup(api, recv)
    local fsx = M.pkgs_of(api)
    if type(fsx) == "table" and type(recv) == "table" and recv.pkg then
        M.rm_tree(fsx, recv.pkg.part)
    end
    if type(recv) == "table" then recv.pkg = nil end
end

function M.ensure_dir(fsx, path)
    if type(fsx) ~= "table" or type(fsx.makeDir) ~= "function" then return false end
    local current = ""
    for part in tostring(path):gmatch("[^/]+") do
        current = current .. "/" .. part
        if type(fsx.exists) ~= "function" or not fsx.exists(current) then
            pcall(fsx.makeDir, current)
        end
    end
    return type(fsx.exists) ~= "function" or fsx.exists(path) == true
end

-- write one file and read it back: a disk that misreports a write never gets to
-- say a package was received
function M.recv_write(fsx, path, body)
    if type(fsx) ~= "table" or type(fsx.write) ~= "function" then
        return nil, "no fs"
    end
    M.ensure_dir(fsx, M.parent_dir(path))
    local called, wrote = pcall(fsx.write, path, body)
    if not called or wrote == false then return nil, "write failed" end
    if type(fsx.read) == "function" then
        local rcalled, back = pcall(fsx.read, path)
        if not rcalled or back ~= body then return nil, "write check failed" end
    end
    return true
end

-- `parts` is a list of {rel, body}: the digest covers "<rel>\n<body>" sorted by
-- rel, the same formula pushpkg uses
function M.digest_of(parts)
    if type(parts) ~= "table" or #parts == 0 then return nil end
    local copy = {}
    for i = 1, #parts do copy[i] = parts[i] end
    table.sort(copy, function(a, b) return a.rel < b.rel end)
    local buf = {}
    for i = 1, #copy do
        buf[#buf + 1] = copy[i].rel .. "\n"
        buf[#buf + 1] = copy[i].body
    end
    return M.sha_of(table.concat(buf))
end

function M.recv_ack(recv, sender, ok, err, extra)
    if type(recv) ~= "table" or type(recv.net) ~= "table" then return false end
    if type(sender) ~= "number" then return false end
    local msg = { kind = "ack", ok = ok == true }
    if err ~= nil then msg.err = M.oneline(err, 48) end
    if type(extra) == "table" then
        if extra.name ~= nil then msg.name = tostring(extra.name) end
        if extra.rel ~= nil then msg.rel = tostring(extra.rel) end
        if extra.chunk ~= nil then msg.chunk = tonumber(extra.chunk) end
    end
    local called, sent = pcall(recv.net.send, sender, msg, recv.protocol)
    return called and sent ~= false
end

function M.recv_fail(state, api, recv, sender, err, extra)
    local pkg = recv.pkg
    local name = pkg and pkg.name or "?"
    local files = pkg and pkg.files or 0
    local bytes = pkg and pkg.bytes or 0
    M.recv_cleanup(api, recv)
    M.note(api, "APPSTORE_RECV name=" .. tostring(name) .. " files="
        .. tostring(files) .. " bytes=" .. tostring(bytes) .. " ok=false err="
        .. M.plain(err, 40))
    M.recv_ack(recv, sender, false, err, extra)
    state.status = "recv failed: " .. M.plain(err, 20)
    return "error"
end

function M.recv_begin(state, api, recv, sender, msg)
    if recv.pkg then
        M.recv_ack(recv, sender, false, "busy", msg)
        state.status = "recv busy"
        return "none"
    end
    local name, version = msg.name, msg.version
    local kind = tostring(msg.pkg == nil and "app" or msg.pkg)
    local files = tonumber(msg.files)
    if type(name) ~= "string" or #name == 0 or #name > 40
        or not name:match("^[%w_%-]+$") then
        return M.recv_fail(state, api, recv, sender, "bad name", msg)
    end
    if kind ~= "app" and kind ~= "lua" then
        return M.recv_fail(state, api, recv, sender, "bad pkg", msg)
    end
    if type(version) ~= "string" or #version == 0 or #version > 32
        or version:find("[^\32-\126]") then
        return M.recv_fail(state, api, recv, sender, "bad version", msg)
    end
    if type(files) ~= "number" or files ~= math.floor(files) or files < 1
        or files > M.MAX_FILES then
        return M.recv_fail(state, api, recv, sender, "bad files", msg)
    end
    local fsx = M.pkgs_of(api)
    if type(fsx) ~= "table" or type(fsx.write) ~= "function" then
        return M.recv_fail(state, api, recv, sender, "no fs", msg)
    end
    local root = M.PKGS .. "/" .. name .. ".app"
    local part = root .. ".part"
    M.rm_tree(fsx, part)
    if not M.ensure_dir(fsx, part) then
        return M.recv_fail(state, api, recv, sender, "no directory", msg)
    end
    recv.pkg = {
        name = name, version = version, kind = kind, files = files,
        root = root, part = part, written = 0, bytes = 0,
        chunks = {}, parts = {}, at = recv.clock(),
    }
    M.recv_ack(recv, sender, true, nil, { name = name })
    state.status = "recv " .. name .. " 0/" .. tostring(files) .. " 0 B"
    return "move"
end

function M.recv_file(state, api, recv, sender, msg)
    local pkg = recv.pkg
    if type(pkg) ~= "table" then
        M.recv_ack(recv, sender, false, "no begin", msg)
        return "none"
    end
    local rel = msg.rel
    if type(rel) ~= "string" or #rel == 0 or #rel > M.MAX_REL
        or rel:sub(1, 1) == "/" or rel:find("..", 1, true)
        or rel:find("\\") or rel:find("[%s%c]") then
        return M.recv_fail(state, api, recv, sender, "bad rel", msg)
    end
    local data = msg.data
    if type(data) ~= "string" or #data > M.MAX_CHUNK then
        return M.recv_fail(state, api, recv, sender, "bad data", msg)
    end
    local chunk, chunks = tonumber(msg.chunk) or 1, tonumber(msg.chunks) or 1
    if chunk ~= math.floor(chunk) or chunks ~= math.floor(chunks)
        or chunk < 1 or chunks < chunk or chunks > M.MAX_CHUNKS then
        return M.recv_fail(state, api, recv, sender, "bad chunk", msg)
    end
    local slot = pkg.chunks[rel]
    if slot == nil then
        slot = { next = 1, parts = {}, bytes = 0 }
        pkg.chunks[rel] = slot
    end
    if chunk ~= slot.next then
        return M.recv_fail(state, api, recv, sender, "chunk order", msg)
    end
    slot.parts[#slot.parts + 1] = data
    slot.bytes = slot.bytes + #data
    slot.next = chunk + 1
    if pkg.bytes + slot.bytes > M.MAX_RECV then
        return M.recv_fail(state, api, recv, sender, "too large", msg)
    end
    pkg.at = recv.clock()
    local request = { name = pkg.name, rel = rel, chunk = chunk }
    if chunk < chunks then
        M.recv_ack(recv, sender, true, nil, request)
        state.status = "recv " .. pkg.name .. " " .. tostring(pkg.written) .. "/"
            .. tostring(pkg.files) .. " " .. tostring(pkg.bytes + slot.bytes) .. " B"
        return "move"
    end
    local body = table.concat(slot.parts)
    pkg.chunks[rel] = nil
    local ok, why = M.recv_write(M.pkgs_of(api), pkg.part .. "/" .. rel, body)
    if not ok then
        return M.recv_fail(state, api, recv, sender, why, request)
    end
    pkg.parts[#pkg.parts + 1] = { rel = rel, body = body }
    pkg.written = pkg.written + 1
    pkg.bytes = pkg.bytes + #body
    M.recv_ack(recv, sender, true, nil, request)
    state.status = "recv " .. pkg.name .. " " .. tostring(pkg.written) .. "/"
        .. tostring(pkg.files) .. " " .. tostring(pkg.bytes) .. " B"
    return "move"
end

function M.recv_end(state, api, recv, sender, msg)
    local pkg = recv.pkg
    if type(pkg) ~= "table" then
        M.recv_ack(recv, sender, false, "no begin", msg)
        return "none"
    end
    if pkg.written ~= pkg.files or next(pkg.chunks) ~= nil then
        return M.recv_fail(state, api, recv, sender, "incomplete", msg)
    end
    local want = msg.sha
    if want ~= nil and want ~= "" then
        if type(want) ~= "string" or #want ~= 64 or not want:match("^%x+$") then
            return M.recv_fail(state, api, recv, sender, "bad sha", msg)
        end
        local have = M.digest_of(pkg.parts)
        if have == nil then
            return M.recv_fail(state, api, recv, sender, "sha unavailable", msg)
        end
        if have ~= want:lower() then
            return M.recv_fail(state, api, recv, sender, "hash check failed", msg)
        end
    end
    local fsx = M.pkgs_of(api)
    M.rm_tree(fsx, pkg.root)
    pcall(fsx.move, pkg.part, pkg.root)
    if type(fsx.exists) == "function" and fsx.exists(pkg.root) ~= true then
        return M.recv_fail(state, api, recv, sender, "cannot rename", msg)
    end
    local install_ok = false
    local sysx = type(api) == "table" and api.sys or nil
    if type(sysx) == "table" and type(sysx.install) == "function" then
        local called, ok, why = pcall(sysx.install, pkg.name)
        install_ok = called and ok == true
        if not install_ok then state.install_error = M.plain(why, 40) end
    end
    M.recv_ack(recv, sender, true, nil, { name = pkg.name })
    M.note(api, "APPSTORE_RECV name=" .. pkg.name .. " files=" .. tostring(pkg.files)
        .. " bytes=" .. tostring(pkg.bytes) .. " ok=true"
        .. (install_ok and "" or " install=false"))
    state.recv_pkg = { name = pkg.name, files = pkg.files, bytes = pkg.bytes,
        root = pkg.root, install = install_ok }
    state.status = install_ok and ("installed " .. pkg.name)
        or ("staged " .. pkg.root)
    recv.pkg = nil
    return "install"
end

function M.recv_abort(state, api, recv, sender, msg)
    local name = recv.pkg and recv.pkg.name or "?"
    M.recv_cleanup(api, recv)
    M.recv_ack(recv, sender, true, nil, { name = name })
    M.note(api, "APPSTORE_RECV_ABORT name=" .. tostring(name))
    state.status = "aborted " .. tostring(name)
    return "repaint"
end

function M.recv_message(state, api, sender, msg)
    local recv = state.recv
    if type(recv) ~= "table" then return "none" end
    if type(msg) ~= "table" or type(msg.kind) ~= "string" then
        M.recv_ack(recv, sender, false, "bad message")
        return "none"
    end
    if msg.kind == "begin" then return M.recv_begin(state, api, recv, sender, msg) end
    if msg.kind == "file" then return M.recv_file(state, api, recv, sender, msg) end
    if msg.kind == "end" then return M.recv_end(state, api, recv, sender, msg) end
    if msg.kind == "abort" then return M.recv_abort(state, api, recv, sender, msg) end
    if msg.kind == "ack" then return "none" end
    M.recv_ack(recv, sender, false, "bad kind", msg)
    return "none"
end

function M.recv_poll(state, api)
    local recv = state.recv
    if type(recv) ~= "table" or type(recv.net) ~= "table" then return "none" end
    local clock = recv.clock or os.clock
    if recv.pkg and (clock() - (recv.pkg.at or clock())) > M.RECV_IDLE then
        local name = recv.pkg.name
        M.recv_fail(state, api, recv, nil, "timeout", { name = name })
        M.note(api, "APPSTORE_RECV_TIMEOUT name=" .. tostring(name))
        return "error"
    end
    local ok, sender, msg = pcall(recv.net.receive, recv.protocol, M.RECV_TIMEOUT)
    if not ok then
        M.note(api, "APPSTORE_RECV_ERR err=" .. M.plain(sender, 40))
        return "none"
    end
    if type(sender) ~= "number" then return "none" end
    return M.recv_message(state, api, sender, msg)
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
    -- while the receiver is armed every key belongs to it: `q` stops listening
    -- and nothing else reaches the list
    if type(state.recv) == "table" then
        if event == "key" then
            local key = p1
            if type(key) == "number" then
                key = M.code_name(key, api)
                if key == nil then return "none" end
            end
            key = tostring(key == nil and "" or key):lower()
            if key == "q" then return M.recv_stop(state, api) end
            return "none"
        end
        if event == "char" then
            if tostring(p1 == nil and "" or p1):lower() == "q" then
                return M.recv_stop(state, api)
            end
            return "none"
        end
        if event == "desk_focus" or event == "term_resize" then return "repaint" end
        if event == "terminate" or event == "shutdown" then return "quit", event end
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
        if key == "l" then return M.recv_arm(state, api) end
        if key == "up" then return M.move(state, -1) end
        if key == "down" then return M.move(state, 1) end
        if key == "enter" then return M.enter(state, api) end
        if key == "r" then return M.load_index(state, api) end
        if key == "a" then return M.edit_begin(state, api) end
        if key == "s" then return M.cycle_server(state) end
        if key == "t" then return M.cycle_target(state, api) end
        return "none"
    end
    if event == "char" then
        local ch = tostring(p1 == nil and "" or p1):lower()
        if ch == "q" then return "quit", "q" end
        if ch == "r" then return M.load_index(state, api) end
        if ch == "a" then return M.edit_begin(state, api) end
        if ch == "l" then return M.recv_arm(state, api) end
        if ch == "s" then return M.cycle_server(state) end
        if ch == "t" then return M.cycle_target(state, api) end
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
        state.status = "appstore unavailable: no http"
        M.paint_once(state, api, term)
        M.note(api, "APPSTORE_UNAVAILABLE reason=no_http")
        if type(pull) ~= "function" then return M.idle(api) end
        while true do
            local event, p1 = pull()
            if event == nil then
                if p1 ~= nil then return M.idle(api) end
                if type(state.recv) == "table" then
                    local action = M.recv_poll(state, api)
                    if action ~= "none" then M.paint_once(state, api, term) end
                end
                api.yield()
            else
                local action, detail = M.dispatch_event(state, event, p1, api)
                if action == "quit" then return "quit" end
                if state.editing == nil and action ~= "none" then
                    M.paint_once(state, api, term)
                end
            end
        end
    end
    M.note(api, "APPSTORE_SERVER url=" .. M.plain(M.server_of(state), 60))
    M.load_index(state, api)
    M.paint_once(state, api, term)
    if type(pull) ~= "function" then return M.idle(api) end
    while true do
        local event, p1 = pull()
        if event == nil then
            if p1 ~= nil then return M.idle(api) end
            if type(state.recv) == "table" then
                local action = M.recv_poll(state, api)
                if action ~= "none" then M.paint_once(state, api, term) end
            end
            api.yield()
        else
            local action, detail = M.dispatch_event(state, event, p1, api)
            if action == "quit" then
                M.note(api, "APPSTORE_QUIT key=" .. tostring(detail))
                return "quit"
            end
            if action ~= "none" then M.paint_once(state, api, term) end
            api.yield()
        end
    end
end

if rawget(_G, "PYROET_APPSTORE_TEST") then return M end

return function(manifest, api)
    return M.body(manifest, api)
end
