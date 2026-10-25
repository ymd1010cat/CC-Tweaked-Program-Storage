--[[- apps/hosts.lua - local hostname -> IPv4 table for the rpv1 app layer.

The application layer (HTTP client/server, scripts) speaks in dotted quads; this
module gives it names. It is a standalone app module: rpv.lua does not load it,
it never reaches into private rpv state, and it talks over the network only
through the public node socket API that rpv/node.lua already exposes:

    node:bind(port, cb)                  -- rpv/node.lua:268 -> rpv.udp_bind
    sk:sendto(dst_int, dport, data, ttl) -- rpv/udp.lua
    sk:close()                           -- rpv/udp.lua

Name-resolution boundary (apps/hosts vs rpv/services):

  This module owns the application layer's own table. `M.entries` is
  hostname -> dotted quad, filled only by load/update/set, replaced whole by
  load/update, and it is never reloaded or touched by the rpv library. It is
  not the rpv built-in name service and it is not a cache of it.

  rpv/services.lua keeps a second table, `node.hosts` (hostname -> integer IP):
  services.hosts_load fills it at node:setup() from `hosts_file` (default
  "hosts.txt"), rpv/node.lua reloads it when "hosts.txt" changes on disk, and
  dns_register / a successful lookup add to it. node:lookup() answers from
  node.hosts first and only then queries the name server.

  Same file name and line format, but two parsers, two tables and no
  synchronisation: hosts.update() rewrites the file and never node.hosts;
  dns_register/lookup() update node.hosts and never this module. Neither table
  is authoritative for the other: apps resolve against hosts.resolve(), rpv
  code (DHCP/DNS server, dynamic registration) uses node:lookup().

Usage:

    local hosts = ...                 -- loaded as apps/hosts.lua
    hosts.load("hosts.txt")           -- { ok=true, n=2, path="hosts.txt" }
    hosts.resolve("router")           -- { ok=true, name="router", ip="10.0.1.1", int=... }
    hosts.save("hosts.txt")           -- .tmp + rename, never truncates in place
    hosts.update(node, "10.0.1.1")    -- pull a fresh table over UDP 6702

File format (ASCII, one entry per line, `#` comments, blank lines ignored):

    router 10.0.1.1
    printer 10.0.1.2

Update protocol (the hosts update server listens on UDP 6702):

    client -> server   "HOSTS1 GET\n"
    server -> client   "HOSTS1 <bytes>\n" followed by <bytes> of the file format

Safety rules (all fail-closed):

  * hostnames are DNS-ish labels: 1..63 ASCII bytes, alnum at both ends,
    letters/digits/'.'/'-'/'_' inside, no empty label, no non-ASCII bytes
  * IPv4 is a strict dotted quad (four 0..255 octets, no leading zeros)
  * paths with a `..` component or control bytes are rejected (traversal)
  * at most MAX_ENTRIES entries, MAX_FILE_BYTES per file/update body,
    MAX_REPLY_BYTES per update datagram
  * a load/update is committed only after the whole payload validated, and an
    update is written to disk before it replaces the in-memory table, so a
    failed load/update/save leaves the previous table and file untouched
  * update() rejects an empty payload unless opts.allow_empty = true, so a
    broken or hostile server cannot silently wipe the table; load() has no
    such guard (an empty file does clear the table)

The rpv UDP socket table has no ephemeral-port allocator, so update() binds UDP
port 0 (the single "ephemeral" slot) and the server replies to the source port;
opts.local_port overrides it when an app needs a fixed port.
]]

local M = {}

M.DEFAULT_PORT = 6702
M.MAX_ENTRIES = 1024
M.MAX_NAME = 63
M.MAX_FILE_BYTES = 65536
M.MAX_REPLY_BYTES = 60000
M.MAX_PATH = 255
M.REQUEST = "HOSTS1 GET\n"
M.WIRE = "HOSTS1"
M.TMP_SUFFIX = ".tmp"
M.BAK_SUFFIX = ".bak"

-- current table (name -> dotted quad), replaced atomically by load/update
M.entries = {}
M.source = nil
M.stats = { loads = 0, saves = 0, updates = 0, update_failures = 0, rejects = 0 }

-- ===== validation ==========================================================
local function ascii_string(s)
    if type(s) ~= "string" then return false end
    for i = 1, #s do
        local b = s:byte(i)
        if b > 126 or (b < 32 and b ~= 9 and b ~= 10 and b ~= 13) then return false end
    end
    return true
end

function M.validate_name(name)
    if type(name) ~= "string" then return nil, "hostname must be a string" end
    if #name < 1 or #name > M.MAX_NAME then
        return nil, "hostname must be 1.." .. M.MAX_NAME .. " bytes"
    end
    if not ascii_string(name) then return nil, "hostname must be ASCII" end
    local tail = #name > 1 and "[A-Za-z0-9]" or ""
    if not name:match("^[A-Za-z0-9][A-Za-z0-9%._%-]*" .. tail .. "$") then
        return nil, "hostname must be a DNS-ish label"
    end
    if name:find("..", 1, true) then return nil, "hostname has an empty label" end
    return true
end

function M.validate_ip(ip)
    if type(ip) ~= "string" then return nil, "ip must be a string" end
    local a, b, c, d = ip:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
    if not a then return nil, "ip must be a dotted quad" end
    for _, octet in ipairs({ a, b, c, d }) do
        if #octet > 1 and octet:sub(1, 1) == "0" then return nil, "ip has a leading zero" end
        if tonumber(octet) > 255 then return nil, "ip octet is out of range" end
    end
    return true
end

function M.ip_to_int(ip)
    if not M.validate_ip(ip) then return nil end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    return tonumber(a) * 16777216 + tonumber(b) * 65536 + tonumber(c) * 256 + tonumber(d)
end

local function check_path(path, what)
    local what = what or "path"
    if type(path) ~= "string" then return nil, what .. " must be a string" end
    if path == "" then return nil, what .. " must not be empty" end
    if #path > M.MAX_PATH then return nil, what .. " is too long" end
    for i = 1, #path do
        local b = path:byte(i)
        if b < 32 or b > 126 then return nil, what .. " has control or non-ASCII bytes" end
    end
    for segment in path:gmatch("[^/\\]+") do
        if segment == ".." then return nil, "path traversal is not allowed" end
    end
    if path:match("[/\\]$") then return nil, what .. " must name a file" end
    return true
end

function M.check_path(path) return check_path(path, "hosts path") end

local function count(entries)
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    return n
end

function M.count() return count(M.entries) end

function M.snapshot()
    local out = {}
    for name, ip in pairs(M.entries) do out[name] = ip end
    return out
end

-- ===== parsing / serialisation =============================================
-- pure: returns a fresh name -> ip table, or nil, err. Nothing is committed.
function M.parse(text, origin)
    if type(text) ~= "string" then return nil, "hosts payload must be a string" end
    if #text > M.MAX_FILE_BYTES then return nil, "hosts payload is too large" end
    if not ascii_string(text) then return nil, "hosts payload must be ASCII" end
    local out, n = {}, 0
    local lineno = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lineno = lineno + 1
        local line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local name, ip = line:match("^([^%s]+)%s+([^%s]+)$")
            if not name then
                return nil, string.format("%s:%d: expected `<hostname> <ip>`", tostring(origin or "hosts"), lineno)
            end
            local ok, err = M.validate_name(name)
            if not ok then return nil, string.format("%s:%d: %s", tostring(origin or "hosts"), lineno, err) end
            ok, err = M.validate_ip(ip)
            if not ok then return nil, string.format("%s:%d: %s", tostring(origin or "hosts"), lineno, err) end
            if out[name] then
                return nil, string.format("%s:%d: duplicate hostname %s", tostring(origin or "hosts"), lineno, name)
            end
            n = n + 1
            if n > M.MAX_ENTRIES then return nil, "too many hosts entries" end
            out[name] = ip
        end
    end
    return out
end

local function serialise(entries)
    local names = {}
    for name in pairs(entries) do names[#names + 1] = name end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do out[#out + 1] = name .. " " .. entries[name] .. "\n" end
    return table.concat(out)
end

local function same_table(a, b)
    if count(a) ~= count(b) then return false end
    for name, ip in pairs(a) do
        if b[name] ~= ip then return false end
    end
    return true
end

-- ===== disk I/O =============================================================
local function read_file(path)
    if type(fs) ~= "table" or type(fs.open) ~= "function" then return nil, "fs API is not available" end
    if type(fs.exists) ~= "function" then return nil, "fs.exists is not available" end
    local exists, yes = pcall(fs.exists, path)
    if not exists then return nil, tostring(yes) end
    if not yes then return nil, "no such hosts file: " .. path end
    local ok, handle = pcall(fs.open, path, "r")
    if not ok or not handle then return nil, tostring(handle) end
    local rok, data = pcall(handle.readAll, handle)
    pcall(handle.close, handle)
    if not rok then return nil, tostring(data) end
    if type(data) ~= "string" then return nil, "hosts file is not readable" end
    if #data > M.MAX_FILE_BYTES then return nil, "hosts file is too large" end
    return data
end

local function delete_file(path)
    if type(fs.delete) == "function" then pcall(fs.delete, path) end
end

local function write_file(path, text)
    local ok, handle = pcall(fs.open, path, "w")
    if not ok or not handle then return nil, tostring(handle) end
    local wok, werr = pcall(function()
        handle.write(text)
        handle.flush()
    end)
    local cok, cerr = pcall(handle.close, handle)
    if not wok then return nil, tostring(werr) end
    if not cok then return nil, tostring(cerr) end
    return true
end

-- Install `tmp` as `dst`. A true rename is preferred; the CC fs.move refuses to
-- overwrite, so an existing dst is moved aside to `<dst>.bak` first and put back
-- if the final move fails. `dst` is never opened for writing, so a crash cannot
-- leave a half-written hosts file behind.
local function replace_file(tmp, dst, rename)
    if rename then
        local ok, err = rename(tmp, dst)
        if not ok then return nil, err or "rename failed" end
        return true
    end
    if type(fs.move) ~= "function" then return nil, "fs.move is not available" end
    if not fs.exists(dst) then
        local pok, moved, merr = pcall(fs.move, tmp, dst)
        if pok and moved ~= false then return true end
        return nil, tostring(merr or moved)
    end
    local bak = dst .. M.BAK_SUFFIX
    delete_file(bak)
    local bok, moved, merr = pcall(fs.move, dst, bak)
    if not bok or moved == false then
        if type(fs.delete) ~= "function" then return nil, tostring(merr or moved) end
        local dok, derr = pcall(fs.delete, dst)
        if not dok then return nil, tostring(derr) end
    end
    local iok, imoved, ierr = pcall(fs.move, tmp, dst)
    if iok and imoved ~= false then
        delete_file(bak)
        return true
    end
    if fs.exists(bak) and not fs.exists(dst) then pcall(fs.move, bak, dst) end
    return nil, tostring(ierr or imoved)
end

local function save_entries(entries, path, opts)
    local opts = opts or {}
    if type(fs) ~= "table" or type(fs.open) ~= "function" then
        return nil, "fs API is not available"
    end
    local ok, err = check_path(path, "hosts path")
    if not ok then return nil, err end
    local text = serialise(entries)
    local tmp = path .. M.TMP_SUFFIX
    local wok, werr = write_file(tmp, text)
    if not wok then
        delete_file(tmp)
        return nil, werr
    end
    local rok, rerr = replace_file(tmp, path, opts.rename)
    if not rok then
        delete_file(tmp)
        return nil, rerr
    end
    return { ok = true, n = count(entries), path = path, bytes = #text }
end

-- ===== public API ==========================================================
function M.load(path)
    local ok, err = check_path(path, "hosts path")
    if not ok then
        M.stats.rejects = M.stats.rejects + 1
        return nil, err
    end
    local text
    text, err = read_file(path)
    if not text then
        M.stats.rejects = M.stats.rejects + 1
        return nil, err
    end
    local entries
    entries, err = M.parse(text, path)
    if not entries then
        M.stats.rejects = M.stats.rejects + 1
        return nil, err
    end
    M.entries = entries
    M.source = path
    M.stats.loads = M.stats.loads + 1
    return { ok = true, n = count(entries), path = path }
end

function M.set(name, ip)
    local ok, err = M.validate_name(name)
    if not ok then return nil, err end
    ok, err = M.validate_ip(ip)
    if not ok then return nil, err end
    if not M.entries[name] and count(M.entries) >= M.MAX_ENTRIES then
        return nil, "hosts table is full"
    end
    M.entries[name] = ip
    return { ok = true, n = count(M.entries) }
end

function M.resolve(name)
    local ok, err = M.validate_name(name)
    if not ok then return nil, err end
    local ip = M.entries[name]
    if not ip then return nil, "host not found: " .. name end
    return { ok = true, name = name, ip = ip, int = M.ip_to_int(ip) }
end

-- non-throwing convenience form: the dotted quad, or nil
function M.get(name)
    local r = M.resolve(name)
    return r and r.ip or nil
end

function M.save(path, opts)
    local r, err = save_entries(M.entries, path, opts)
    if not r then
        M.stats.rejects = M.stats.rejects + 1
        return nil, err
    end
    M.source = path
    M.stats.saves = M.stats.saves + 1
    return r
end

local function reply_body(data)
    if type(data) ~= "string" then return nil, "update reply is not a string" end
    if #data > M.MAX_REPLY_BYTES then return nil, "update reply is too large" end
    local nstr, pos = data:match("^" .. M.WIRE .. " (%d+)\n()")
    if not nstr then return nil, "update reply has no HOSTS1 header" end
    local n = tonumber(nstr)
    local body = data:sub(pos)
    if n ~= #body then return nil, "update reply is truncated" end
    return body
end

-- Pull a fresh table from the hosts update server. Tries 1 + opts.retries times,
-- each with opts.timeout seconds (opts.wait(sec) replaces os.sleep in tests).
-- The reply must come from `server_ip`, carry a valid header and a fully valid
-- body; the table is saved to opts.path (or the last loaded source, default
-- "hosts.txt") before it replaces the in-memory table.
function M.update(node, server_ip, opts)
    local opts = opts or {}
    if type(node) ~= "table" or type(node.bind) ~= "function" then
        return nil, "hosts.update needs a node with node:bind (rpv)"
    end
    local ipint
    if type(server_ip) == "number" then
        if server_ip ~= server_ip or server_ip ~= math.floor(server_ip)
            or server_ip < 1 or server_ip > 0xFFFFFFFE then
            return nil, "server ip is out of range"
        end
        ipint = server_ip
    else
        local ok, err = M.validate_ip(server_ip)
        if not ok then return nil, err end
        ipint = M.ip_to_int(server_ip)
    end
    local function port_of(value)
        if value == nil then return nil end
        if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > 65535 then
            return false
        end
        return value
    end
    local port = port_of(opts.port)
    if port == false then return nil, "port must be 0..65535" end
    port = port or M.DEFAULT_PORT
    local local_port = port_of(opts.local_port)
    if local_port == false then return nil, "local_port must be 0..65535" end
    local_port = local_port or 0
    local path = opts.path or M.source or "hosts.txt"
    local okp, perr = check_path(path, "hosts path")
    if not okp then return nil, perr end
    local timeout = tonumber(opts.timeout) or 2
    if timeout ~= timeout or timeout <= 0 then timeout = 2 end
    local retries = tonumber(opts.retries) or 2
    if retries ~= retries or retries < 0 then retries = 0 end
    if retries > 10 then retries = 10 end
    local slice = tonumber(opts.slice) or 0.1
    if slice ~= slice or slice <= 0 or slice > timeout then slice = timeout end
    local wait = type(opts.wait) == "function" and opts.wait or os.sleep
    local log = type(opts.log) == "function" and opts.log or nil

    local reply
    local handler = function(data, src)
        if src ~= ipint then return end
        if reply == nil then reply = data end
    end
    local bok, sk, berr = pcall(node.bind, node, local_port, handler)
    if not bok then return nil, "node:bind failed: " .. tostring(sk) end
    if not sk then return nil, "node:bind failed: " .. tostring(berr) end

    local attempts = 0
    local last = "timeout"
    for attempt = 1, retries + 1 do
        attempts = attempt
        reply = nil
        local sok, sent, serr = pcall(sk.sendto, sk, ipint, port, M.REQUEST)
        -- node:send_ip returns true/false when it hits the wire, but a local or
        -- loopback delivery returns whatever ip_deliver returns (possibly nil):
        -- only an explicit false or an exception counts as a send failure.
        if not sok or sent == false then
            last = "send failed"
            if type(sent) == "string" then last = last .. ": " .. sent end
            if type(serr) == "string" then last = last .. ": " .. serr end
        else
            local waited = 0
            while reply == nil and waited < timeout do
                pcall(wait, slice)
                waited = waited + slice
            end
            if reply ~= nil then
                local body, berr2 = reply_body(reply)
                local newtab, perr2
                if body then newtab, perr2 = M.parse(body, "update") else perr2 = berr2 end
                if not newtab then
                    last = perr2
                elseif count(newtab) == 0 and not opts.allow_empty then
                    last = "empty update rejected"
                else
                    if not same_table(newtab, M.entries) then
                        local saved, serr2 = save_entries(newtab, path, opts)
                        if not saved then
                            last = "save failed: " .. tostring(serr2)
                        else
                            M.entries = newtab
                            M.source = path
                            M.stats.updates = M.stats.updates + 1
                            pcall(sk.close, sk)
                            return { ok = true, n = count(newtab), attempts = attempt,
                                bytes = #body, changed = true, path = path }
                        end
                    else
                        M.stats.updates = M.stats.updates + 1
                        pcall(sk.close, sk)
                        return { ok = true, n = count(newtab), attempts = attempt,
                            bytes = #body, changed = false, path = path }
                    end
                end
            else
                last = "timeout"
            end
        end
        if log then
            pcall(log, string.format("HOSTS_UPDATE_RETRY attempt=%d", attempt))
        end
    end
    pcall(sk.close, sk)
    M.stats.update_failures = M.stats.update_failures + 1
    if log then pcall(log, "HOSTS_UPDATE_FAILED attempts=" .. tostring(attempts)) end
    return nil, last
end

return M
