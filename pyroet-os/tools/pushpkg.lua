--[[- pyroet-os/tools/pushpkg.lua -- push a package to a handheld over rednet.

This file is a DEVELOPMENT TOOL: it is not part of the image and it is not in
install.set. Copy it to the OTHER computer (CraftOS or Pyromputer OS), keep the
handheld on this side running appstore with its receiver armed (press `l`; the
status row shows `listening ch=<n> id=<computer id>`), then run:

    pushpkg <target-id|broadcast> [name]

    target-id   the rednet id appstore prints, or `broadcast` for every receiver
    name        one package from index.txt; omitted = every package in it

/etc/pushpkg.conf (optional, one key=value per line, '#' starts a comment):

    server=<http base>    default http://store.pyrotechnic.org/
    protocol=<name>       default PYROET-PKG/1 (appstore may override its side)
    channel=<n>           informational; rednet has no numeric channel here
    timeout=<seconds>     ack timeout, default 5

Server layout, the same one appstore reads:

    GET <base>/index.txt          "app <name> <version> <dir>" per line
                                  or "lua <name> <version> <file.lua>"
    GET <base>/<dir>/files.txt    one relative path per line        (app)
    GET <base>/<dir>/<relpath>    the file body                     (app)
    GET <base>/<file.lua>         one Lua file                      (lua)
    GET <base>/<dir>/SHA256.txt   optional "<sha256> <relpath>"     (app)

A `lua` package is wrapped before sending: manifest.lua (name, version and the
capabilities fs.read/input/terminal) + main.lua (the file). A package is one
stream -- begin, then every file in chunks of at most 8 KiB, then end with the
whole-package digest -- and every message waits for an ack, retried twice.
Logs: PUSHPKG_TARGET / PUSHPKG_INDEX / PUSHPKG_BEGIN / PUSHPKG_FILE /
PUSHPKG_RETRY / PUSHPKG_END / PUSHPKG_FAIL.

No non-ASCII bytes in this file. `_G.PYROET_PUSHPKG_TEST` returns the module.
]]

local M = {}

M.VERSION = "0.1.0"
M.PROTOCOL = "PYROET-PKG/1"
M.CONF = "/etc/pushpkg.conf"
M.SERVER = "http://store.pyrotechnic.org/"
M.TIMEOUT = 5
M.RETRIES = 2          -- two retries after the first attempt = three sends
M.CHUNK = 8192
M.MAX_BODY = 262144
M.MAX_FILES = 256
M.MAX_REL = 96

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function plain(text, max)
    local value = tostring(text == nil and "" or text)
    value = value:gsub("[\r\n\t]+", " ")
    if max ~= nil and #value > max then value = value:sub(1, max) end
    return value
end

local function join(base, rest)
    local text = tostring(base or "")
    if text:sub(-1) ~= "/" then text = text .. "/" end
    return text .. tostring(rest or "")
end

function M.log(env, line)
    local sink = env and env.log or rawget(_G, "print")
    if type(sink) == "function" then pcall(sink, tostring(line)) end
end

-- ---------------------------------------------------------------------------
-- sha256 (bit32 on Lua 5.2 / bit on LuaJIT); nil when the host has neither --
-- the stream then goes out without the end digest instead of lying
-- ---------------------------------------------------------------------------

local band, bxor, bnot, rshift, lshift, rorate = nil, nil, nil, nil, nil, nil

do
    local b = rawget(_G, "bit32")
    if type(b) == "table" then
        band, bxor, bnot = b.band, b.bxor, b.bnot
        rshift, lshift, rorate = b.rshift, b.lshift, b.rrotate
    else
        local b2 = rawget(_G, "bit")
        if type(b2) == "table" then
            band, bxor, bnot = b2.band, b2.bxor, b2.bnot
            rshift, lshift, rorate = b2.rshift, b2.lshift, b2.ror
        end
    end
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function u32(value)
    return band(value, 0xFFFFFFFF)
end

local function be32(value)
    local n = value % 4294967296
    return string.char(math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function word_at(text, index)
    local a, b, c, d = text:byte(index, index + 3)
    return u32(lshift(a, 24) + lshift(b, 16) + lshift(c, 8) + d)
end

function M.sha_ready()
    return band ~= nil
end

function M.sha256(text)
    if band == nil then return nil end
    local msg = tostring(text or "")
    local bits = #msg * 8
    local pad = 64 - ((#msg + 9) % 64)
    if pad == 64 then pad = 0 end
    msg = msg .. "\128" .. string.rep("\0", pad)
        .. be32(math.floor(bits / 4294967296)) .. be32(bits)

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = {}

    for offset = 1, #msg, 64 do
        for i = 0, 15 do w[i] = word_at(msg, offset + i * 4) end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(rorate(x, 7), rorate(x, 18), rshift(x, 3))
            local s1 = bxor(rorate(y, 17), rorate(y, 19), rshift(y, 10))
            w[i] = u32(w[i - 16] + s0 + w[i - 7] + s1)
        end
        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for i = 0, 63 do
            local s1 = bxor(rorate(e, 6), rorate(e, 11), rorate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = u32(h + s1 + ch + K[i + 1] + w[i])
            local s0 = bxor(rorate(a, 2), rorate(a, 13), rorate(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = u32(s0 + maj)
            h, g, f, e = g, f, e, u32(d + t1)
            d, c, b, a = c, b, a, u32(t1 + t2)
        end
        h0, h1, h2, h3 = u32(h0 + a), u32(h1 + b), u32(h2 + c), u32(h3 + d)
        h4, h5, h6, h7 = u32(h4 + e), u32(h5 + f), u32(h6 + g), u32(h7 + h)
    end
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7)
end

-- the same formula the receiver uses: "<rel>\n<body>" over the sorted rels
function M.digest_of(files)
    local copy = {}
    for i = 1, #(files or {}) do copy[i] = files[i] end
    if #copy == 0 then return nil end
    table.sort(copy, function(a, b) return a.rel < b.rel end)
    local buf = {}
    for i = 1, #copy do
        buf[#buf + 1] = copy[i].rel .. "\n"
        buf[#buf + 1] = copy[i].body
    end
    return M.sha256(table.concat(buf))
end

-- ---------------------------------------------------------------------------
-- configuration + http
-- ---------------------------------------------------------------------------

function M.parse_conf(text)
    local out = { server = M.SERVER, protocol = M.PROTOCOL, timeout = M.TIMEOUT }
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local clean = trim((line:gsub("\r", "")))
        if clean ~= "" and clean:sub(1, 1) ~= "#" then
            local key, value = clean:match("^([%w_]+)%s*=%s*(%S+)$")
            if key == "server" then
                if value:match("^https?://") then out.server = value end
            elseif key == "protocol" then
                if #value <= 32 and not value:find("[^\32-\126]") then
                    out.protocol = value
                end
            elseif key == "channel" then
                local number = tonumber(value)
                if number and number >= 1 and number <= 65532
                    and number == math.floor(number) then
                    out.channel = number
                end
            elseif key == "timeout" then
                local number = tonumber(value)
                if number and number > 0 and number <= 120 then
                    out.timeout = number
                end
            end
        end
    end
    return out
end

function M.conf(env)
    local fsx = env and env.fs or nil
    if type(fsx) ~= "table" or type(fsx.read) ~= "function" then
        return M.parse_conf(nil), "no fs"
    end
    local called, text = pcall(fsx.read, M.CONF)
    if not called or type(text) ~= "string" then
        return M.parse_conf(nil), "no conf"
    end
    return M.parse_conf(text)
end

function M.http_of(env)
    local http = env and env.http or rawget(_G, "http")
    if type(http) ~= "table" or type(http.get) ~= "function" then return nil end
    return http
end

-- one GET -> body, status, err (a 4xx/5xx answer is not a transport failure)
function M.get(env, url)
    local http = M.http_of(env)
    if http == nil then return nil, nil, "no http" end
    local called, res, extra = pcall(http.get, url)
    if not called then return nil, nil, tostring(res) end
    if res == nil then return nil, nil, tostring(extra or "failed") end
    if type(res) == "string" then return res, 200 end
    if type(res) ~= "table" then return nil, nil, "bad response" end
    local status = tonumber(res.status) or (res.ok == false and 0 or 200)
    local body = type(res.body) == "string" and res.body or ""
    if body == "" and type(res.readAll) == "function" then
        local ok, text = pcall(res.readAll)
        if ok and type(text) == "string" then body = text end
    end
    if status < 200 or status > 299 then return nil, status, "http " .. status end
    return body, status
end

-- ---------------------------------------------------------------------------
-- index / files.txt / SHA256.txt
-- ---------------------------------------------------------------------------

function M.parse_index(text, base)
    local entries, bad = {}, 0
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local clean = trim((line:gsub("\r", "")))
        if clean ~= "" then
            local tag, name, version, where = clean:match(
                "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
            local ok = tag == "app" or tag == "lua"
            if ok and (name == nil or #name == 0 or #name > 40
                or name:find("[/\\]") or name:find("..", 1, true)
                or not name:match("^[%w_%-]+$")) then
                ok = false
            end
            if ok and (version == nil or #version == 0 or #version > 32
                or not version:match("^[%w%._%-]+$")) then
                ok = false
            end
            if ok and (where == nil or where == "" or #where > M.MAX_REL
                or where:sub(1, 1) == "/" or where:find("..", 1, true)
                or where:find("\\") or where:find("[%s%c]")) then
                ok = false
            end
            if not ok then
                bad = bad + 1
            else
                entries[#entries + 1] = { name = name, version = version,
                    kind = tag, dir = where, base = base }
            end
        end
    end
    return entries, bad
end

function M.parse_files(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local rel = trim((line:gsub("\r", "")))
        if rel ~= "" then
            if #rel > M.MAX_REL or rel:sub(1, 1) == "/"
                or rel:find("..", 1, true) or rel:find("\\")
                or rel:find("[%s%c]") then
                return nil, "bad path " .. plain(rel, 32)
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
        local clean = trim((line:gsub("\r", "")))
        local sha, rel = clean:match("^(%x+)%s+(%S+)$")
        if sha ~= nil and #sha == 64 then out[rel] = sha:lower() end
    end
    return out
end

-- a `lua` package is one file wrapped into the .app shape the receiver wants
function M.wrap_lua(name, version, body)
    local manifest = 'return { name = "' .. tostring(name)
        .. '", version = "' .. tostring(version)
        .. '", entry = "main.lua", capabilities = { "fs.read", "input",'
        .. ' "terminal" } }\n'
    return {
        { rel = "manifest.lua", body = manifest },
        { rel = "main.lua", body = body },
    }
end

function M.load_package(env, conf, entry)
    local base = join(entry.base or conf.server, entry.dir)
    if entry.kind == "lua" then
        local body, status, err = M.get(env, base)
        if body == nil then return nil, "lua " .. tostring(err or status) end
        if #body > M.MAX_BODY then return nil, "file too large" end
        return { name = entry.name, version = entry.version, kind = "lua",
            files = M.wrap_lua(entry.name, entry.version, body) }
    end
    local list_body, _, lerr = M.get(env, join(base, "files.txt"))
    if list_body == nil then return nil, "files " .. tostring(lerr) end
    local list, why = M.parse_files(list_body)
    if list == nil then return nil, why end
    local sha_body = M.get(env, join(base, "SHA256.txt"))
    local shas = type(sha_body) == "string" and M.parse_sha(sha_body) or nil
    local files, total, manifest = {}, 0, false
    for i = 1, #list do
        local rel = list[i]
        local body, status, err = M.get(env, join(base, rel))
        if body == nil then
            return nil, "fetch " .. rel .. ": " .. tostring(err or status)
        end
        total = total + #body
        if total > M.MAX_BODY then return nil, "package too large" end
        local want = shas and shas[rel]
        if want ~= nil then
            local have = M.sha256(body)
            if have == nil then return nil, "sha unavailable" end
            if have ~= want then return nil, "sha256 " .. rel end
        end
        if rel == "manifest.lua" then manifest = true end
        files[#files + 1] = { rel = rel, body = body }
    end
    if #files == 0 then return nil, "no files" end
    if not manifest then return nil, "no manifest.lua" end
    return { name = entry.name, version = entry.version, kind = "app",
        files = files }
end

-- ---------------------------------------------------------------------------
-- rednet transport
-- ---------------------------------------------------------------------------

function M.chunks(body, size)
    local step = size or M.CHUNK
    local text = tostring(body or "")
    local out = {}
    if #text == 0 then
        out[1] = ""
        return out
    end
    for i = 1, #text, step do out[#out + 1] = text:sub(i, i + step - 1) end
    return out
end

function M.target_of(arg)
    if arg == nil or tostring(arg) == "" then return nil, "usage" end
    if tostring(arg) == "broadcast" then return "broadcast" end
    local id = tonumber(arg)
    if id == nil or id ~= math.floor(id) or id < 0 then
        return nil, "bad target"
    end
    return id
end

function M.net_of(env)
    local net = env and env.rednet or nil
    if type(net) ~= "table" then net = rawget(_G, "rednet") end
    if type(net) ~= "table" or type(net.send) ~= "function"
        or type(net.receive) ~= "function" then
        return nil
    end
    return net
end

function M.open_modems(env, net)
    if type(net.open) ~= "function" then return 0 end
    local per = env and env.peripheral or rawget(_G, "peripheral")
    local names = type(per) == "table" and type(per.getNames) == "function"
        and per.getNames() or nil
    if type(names) ~= "table" then return 0 end
    local opened = 0
    for i = 1, #names do
        if pcall(net.open, names[i]) then opened = opened + 1 end
    end
    return opened
end

-- send one message and wait for its ack; a missing ack costs one retry, an ack
-- with ok=false is the receiver's answer and is returned as-is
function M.request(env, net, target, protocol, msg, timeout, retries)
    local clock = env.clock or os.clock
    local why = "timeout"
    for attempt = 0, retries do
        if attempt > 0 then
            M.log(env, "PUSHPKG_RETRY attempt=" .. tostring(attempt)
                .. " max=" .. tostring(retries))
        end
        local sent = false
        if target == "broadcast" and type(net.broadcast) == "function" then
            local called, ok = pcall(net.broadcast, msg, protocol)
            sent = called and ok ~= false
        else
            local dest = target == "broadcast" and 65535 or target
            local called, ok = pcall(net.send, dest, msg, protocol)
            sent = called and ok ~= false
        end
        if not sent then
            why = "send failed"
        else
            local deadline = clock() + timeout
            while true do
                local left = deadline - clock()
                if left <= 0 then
                    why = "timeout"
                    break
                end
                local called, sender, ack = pcall(net.receive, protocol, left)
                if not called then
                    why = plain(sender, 40)
                    break
                end
                if sender == nil then
                    why = "timeout"
                    break
                end
                if type(ack) == "table" and ack.kind == "ack"
                    and (target == "broadcast" or sender == target) then
                    return ack, nil
                end
                why = "stray message"
            end
        end
    end
    return nil, why
end

function M.abort(env, net, target, protocol, name)
    local msg = { kind = "abort", name = tostring(name or "?") }
    if target == "broadcast" and type(net.broadcast) == "function" then
        pcall(net.broadcast, msg, protocol)
    else
        pcall(net.send, target == "broadcast" and 65535 or target, msg, protocol)
    end
end

function M.send_package(env, net, target, conf, pkg)
    local protocol, timeout = conf.protocol, conf.timeout or M.TIMEOUT
    local retries = conf.retries or M.RETRIES
    local ack, why = M.request(env, net, target, protocol, {
        kind = "begin", name = pkg.name, version = pkg.version,
        pkg = pkg.kind, files = #pkg.files,
    }, timeout, retries)
    if not ack or ack.ok ~= true then
        return nil, (ack and ack.err) or why or "begin refused"
    end
    M.log(env, "PUSHPKG_BEGIN name=" .. pkg.name .. " pkg=" .. pkg.kind
        .. " files=" .. tostring(#pkg.files))
    local bytes = 0
    for i = 1, #pkg.files do
        local file = pkg.files[i]
        local list = M.chunks(file.body)
        for chunk = 1, #list do
            local fack, fwhy = M.request(env, net, target, protocol, {
                kind = "file", rel = file.rel, data = list[chunk],
                chunk = chunk, chunks = #list,
            }, timeout, retries)
            if not fack or fack.ok ~= true then
                M.abort(env, net, target, protocol, pkg.name)
                return nil, (fack and fack.err) or fwhy or "file refused"
            end
        end
        bytes = bytes + #file.body
        M.log(env, "PUSHPKG_FILE rel=" .. file.rel .. " bytes="
            .. tostring(#file.body) .. " chunks=" .. tostring(#list))
    end
    local sha = M.digest_of(pkg.files)
    local eack, ewhy = M.request(env, net, target, protocol, {
        kind = "end", sha = sha,
    }, timeout, retries)
    if not eack or eack.ok ~= true then
        M.abort(env, net, target, protocol, pkg.name)
        return nil, (eack and eack.err) or ewhy or "end refused"
    end
    M.log(env, "PUSHPKG_END name=" .. pkg.name .. " ok=true files="
        .. tostring(#pkg.files) .. " bytes=" .. tostring(bytes)
        .. " sha=" .. tostring(sha and sha:sub(1, 12) or "none"))
    return { name = pkg.name, files = #pkg.files, bytes = bytes, sha = sha }
end

-- ---------------------------------------------------------------------------
-- entry point
-- ---------------------------------------------------------------------------

function M.run(env, args)
    local list = args or {}
    local conf, note = M.conf(env)
    if note ~= nil then M.log(env, "PUSHPKG_CONF reason=" .. tostring(note)) end
    local target, terr = M.target_of(list[1])
    if terr ~= nil then
        M.log(env, "PUSHPKG_FAIL err=" .. tostring(terr))
        M.log(env, "PUSHPKG_USAGE pushpkg <target-id|broadcast> [name]")
        return nil, terr
    end
    local net = M.net_of(env)
    if net == nil then
        M.log(env, "PUSHPKG_FAIL err=no_rednet")
        return nil, "no_rednet"
    end
    local opened = M.open_modems(env, net)
    M.log(env, "PUSHPKG_TARGET target=" .. tostring(target) .. " protocol="
        .. conf.protocol .. " modems=" .. tostring(opened))
    local index_body, status, ierr = M.get(env, join(conf.server, "index.txt"))
    if index_body == nil then
        M.log(env, "PUSHPKG_FAIL err=index " .. tostring(ierr or status))
        return nil, "index"
    end
    local entries, bad = M.parse_index(index_body, conf.server)
    M.log(env, "PUSHPKG_INDEX entries=" .. tostring(#entries)
        .. " bad=" .. tostring(bad))
    local picked = {}
    if list[2] ~= nil then
        for i = 1, #entries do
            if entries[i].name == list[2] then picked[#picked + 1] = entries[i] end
        end
        if #picked == 0 then
            M.log(env, "PUSHPKG_FAIL err=no such package: " .. tostring(list[2]))
            return nil, "no such package"
        end
    else
        picked = entries
    end
    if #picked == 0 then
        M.log(env, "PUSHPKG_FAIL err=empty index")
        return nil, "empty index"
    end
    local reports = {}
    for i = 1, #picked do
        local entry = picked[i]
        local pkg, perr = M.load_package(env, conf, entry)
        if pkg == nil then
            M.log(env, "PUSHPKG_FAIL name=" .. tostring(entry.name)
                .. " err=" .. tostring(perr))
        else
            local report, serr = M.send_package(env, net, target, conf, pkg)
            if report then
                reports[#reports + 1] = report
            else
                M.log(env, "PUSHPKG_FAIL name=" .. tostring(entry.name)
                    .. " err=" .. tostring(serr))
            end
        end
    end
    if #reports == 0 then return nil, "nothing sent" end
    return reports
end

if rawget(_G, "PYROET_PUSHPKG_TEST") then return M end

-- a shell program: the arguments arrive as varargs
return function(...)
    local env = {
        fs = rawget(_G, "fs"),
        http = rawget(_G, "http"),
        rednet = rawget(_G, "rednet"),
        peripheral = rawget(_G, "peripheral"),
        log = function(line) print(line) end,
    }
    local reports = M.run(env, { ... })
    if reports == nil then return 1 end
    print("PUSHPKG_SENT packages=" .. tostring(#reports))
    return 0
end
