--[[- pyroet-os/net/hosts.lua -- static host table for Pyroet OS.

rpv/services.lua (DNS + DHCP) is not vendored (DECISIONS.md 3.2), so
`node:lookup()` returns nil and a name only resolves from a local file:

    /etc/hosts.conf            one '<hostname> <ipv4>' per line
    # comment                  blank lines ignored
    gw          10.0.0.1
    box-1       10.0.0.9   # trailing comment

Rules (strict, and all-or-nothing):
  - hostname matches [%w%.%-_]+ (ASCII letters/digits, '.', '-', '_');
  - an IPv4 address is four dot-separated decimal octets, each 0..255, no
    leading zero ('010' is rejected, '0' is fine), no signs, no whitespace;
  - one bad line rejects the WHOLE file: the previous table survives and
    HOSTS_BAD_FILE is logged. A half-applied hosts file is worse than a stale
    one, and a writer who can edit the file can also delete it.

Two entry points, one parser (so the two views cannot disagree):
  - H.new{fs=,log=,path=,min_interval=,clock=} is the table the net service
    and the Net app use: resolve / list / reload_if_changed;
  - H.hosts_load(node, path[, opts]) is the rpv-compatible hook. rpv/node.lua
    calls M.hosts_load(self, path) from n:tick() when the file's mtime moves
    and expects it to fill node.hosts (hostname -> integer IPv4).

Reload uses fs.attributes().modification with a minimum interval
(H.DEFAULT_MIN_INTERVAL = 5 s, DECISIONS.md 9.2). CC file times have one-second
resolution, so two writes inside the same second count as one change.

No non-ASCII bytes in this file.
]]

local H = {}

H.VERSION = "1.0"
H.DEFAULT_PATH = "/etc/hosts.conf"
H.DEFAULT_MIN_INTERVAL = 5

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

-- strict dotted-decimal IPv4 -> integer, or nil
function H.parse_ip(text)
    if type(text) ~= "string" then return nil end
    local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    local parts = { a, b, c, d }
    local value = 0
    for i = 1, 4 do
        local part = parts[i]
        if #part > 3 then return nil end
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
        local octet = tonumber(part)
        if octet == nil or octet > 255 then return nil end
        value = value * 256 + octet
    end
    return value
end

function H.int2ip(value)
    local n = math.floor(tonumber(value) or 0)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

function H.valid_hostname(name)
    if type(name) ~= "string" or name == "" then return false end
    return name:match("^[%w%.%-_]+$") ~= nil
end

function H.valid_ip(text)
    return H.parse_ip(text) ~= nil
end

-- one logical line -> entry, or nil for blank/comment, or nil, error (no lineno)
local function parse_line(line)
    local body = tostring(line):gsub("#.*$", "")
    body = body:gsub("[\r\n\t]+", " ")
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    if body == "" then return nil end
    local name, ip_text, extra = body:match("^(%S+)%s+(%S+)%s*(.*)$")
    if not name then return nil, "expected '<hostname> <ipv4>'" end
    if extra ~= "" then return nil, "extra token '" .. extra .. "'" end
    if not H.valid_hostname(name) then
        return nil, "bad hostname '" .. name .. "' (allowed: letters, digits, '.', '-', '_')"
    end
    local ip = H.parse_ip(ip_text)
    if ip == nil then
        return nil, "bad ipv4 '" .. ip_text .. "' (four octets 0..255, no leading zero)"
    end
    return { name = name, ip = ip, text = H.int2ip(ip) }
end

-- whole text -> { entries = [...], count = n } or nil, error ('line N: ...')
-- entries are unique by name, insertion order; a later duplicate wins.
function H.parse(text)
    if type(text) ~= "string" then return nil, "hosts text must be a string" end
    local order, by_name = {}, {}
    local line_no = 0
    local body = text
    if body:sub(-1) ~= "\n" then body = body .. "\n" end
    for line in body:gmatch("([^\n]*)\n") do
        line_no = line_no + 1
        local entry, err = parse_line(line)
        if err then return nil, "line " .. line_no .. ": " .. err end
        if entry then
            if by_name[entry.name] == nil then
                order[#order + 1] = entry.name
            end
            by_name[entry.name] = entry
        end
    end
    local entries = {}
    for i = 1, #order do entries[i] = by_name[order[i]] end
    return { entries = entries, count = #entries }
end

local function read_file(fsx, path)
    if not fsx or type(fsx.exists) ~= "function" then return nil, "no file system" end
    local ok, exists = pcall(fsx.exists, path)
    if not ok or not exists then return nil, "missing file: " .. tostring(path) end
    local handle = fsx.open(path, "r")
    if not handle then return nil, "cannot open " .. tostring(path) end
    local text
    if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
    handle.close()
    if text == nil then return nil, "cannot read " .. tostring(path) end
    return text
end

-- ---------------------------------------------------------------------------
-- table object
-- ---------------------------------------------------------------------------

function H.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = H })
    self.fs = o.fs or rawget(_G, "fs")
    self.sink = o.log
    self.logs = {}
    self.path = o.path or H.DEFAULT_PATH
    self.min_interval = tonumber(o.min_interval) or H.DEFAULT_MIN_INTERVAL
    if self.min_interval < 0 then self.min_interval = 0 end
    self.clock = o.clock
    self.entries = {}
    self.index = {}
    self.total = 0
    self.mtime = nil
    self.last_check = nil
    self.loads = 0
    self.bad = 0
    self.misses = 0
    self.reloads = 0
    return self
end

function H:now()
    if type(self.clock) == "function" then return self.clock() end
    return os.clock()
end

function H:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if type(self.sink) == "function" then
        local ok = pcall(self.sink, line)
        if not ok then self.sink = nil end
    end
    return line
end

function H:mtime_of(path)
    local fsx = self.fs
    if not fsx or type(fsx.attributes) ~= "function"
        or type(fsx.exists) ~= "function" then
        return nil
    end
    path = path or self.path
    local ok, exists = pcall(fsx.exists, path)
    if not ok or not exists then return nil end
    local ok2, attr = pcall(fsx.attributes, path)
    if not ok2 or type(attr) ~= "table" then return nil end
    return attr.modification
end

function H:resolve(name)
    if type(name) ~= "string" then return nil, "hostname must be a string" end
    local entry = self.index[name]
    if not entry then return nil, "unknown host: " .. name end
    return entry.ip, entry.text
end

function H:list()
    local out = {}
    for i = 1, #self.entries do
        local entry = self.entries[i]
        out[i] = { name = entry.name, ip = entry.ip, text = entry.text }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function H:lookup(name)
    local entry = self.index[name]
    return entry
end

function H:size()
    return self.total
end

-- H:count() is the method; the numeric field is `total` so the two cannot
-- shadow each other (a field named count would win over the method).
function H:count()
    return self.total
end

-- all-or-nothing: only a fully valid file replaces the live table
function H:load(path)
    path = path or self.path
    local text, read_err = read_file(self.fs, path)
    if not text then
        self.misses = self.misses + 1
        self:log("HOSTS_MISSING path=" .. short(path, 48) .. " err=" .. short(read_err, 48))
        return nil, read_err
    end
    local parsed, parse_err = H.parse(text)
    if not parsed then
        self.bad = self.bad + 1
        self:log("HOSTS_BAD_FILE path=" .. short(path, 48) .. " err=" .. short(parse_err, 96))
        return nil, parse_err
    end
    local index = {}
    for i = 1, #parsed.entries do index[parsed.entries[i].name] = parsed.entries[i] end
    self.entries, self.index, self.total = parsed.entries, index, parsed.count
    self.path = path
    self.mtime = self:mtime_of(path)
    self.loads = self.loads + 1
    self:log("HOSTS_LOAD path=" .. short(path, 48) .. " entries=" .. tostring(self.total))
    return true, self.total
end

-- mtime driven, interval gated; returns true, n on reload else false, reason
function H:reload_if_changed(now)
    now = tonumber(now) or self:now()
    if self.last_check ~= nil and (now - self.last_check) < self.min_interval then
        return false, "too soon"
    end
    self.last_check = now
    if not (self.fs and type(self.fs.attributes) == "function") then
        return false, "no attributes"
    end
    local mtime = self:mtime_of(self.path)
    if mtime == nil then return false, "missing" end
    if self.mtime ~= nil and mtime == self.mtime then return false, "unchanged" end
    local ok, count = self:load(self.path)
    if not ok then return false, "bad file" end
    self.reloads = self.reloads + 1
    self:log("HOSTS_RELOAD path=" .. short(self.path, 48)
        .. " entries=" .. tostring(count))
    return true, count
end

-- ---------------------------------------------------------------------------
-- rpv-compatible injection
-- ---------------------------------------------------------------------------

-- Write hostname -> integer IPv4 into node.hosts. This is the table rpv reads
-- (services.lua is absent in the subset, so nothing else fills it).
function H.apply(node, list)
    if type(node) ~= "table" then return nil, "node table required" end
    if type(list) ~= "table" then return nil, "entry list required" end
    local map = {}
    local count = 0
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == "table" and type(entry.name) == "string"
            and type(entry.ip) == "number" then
            map[entry.name] = entry.ip
            count = count + 1
        end
    end
    node.hosts = map
    return count
end

-- rpv/node.lua:tick calls this as M.hosts_load(node, path); a bad file leaves
-- node.hosts exactly as it was and logs HOSTS_BAD_FILE through the node log.
function H.hosts_load(node, path, opts)
    if type(node) ~= "table" then return nil, "node table required" end
    local o = opts or {}
    local fsx = o.fs or rawget(_G, "fs")
    path = path or o.path or H.DEFAULT_PATH
    local text, read_err = read_file(fsx, path)
    if not text then
        if type(node.log) == "function" then
            node:log("HOSTS_MISSING path=%s err=%s", short(path, 48), short(read_err, 48))
        end
        return nil, read_err
    end
    local parsed, parse_err = H.parse(text)
    if not parsed then
        if type(node.log) == "function" then
            node:log("HOSTS_BAD_FILE path=%s err=%s", short(path, 48), short(parse_err, 96))
        end
        return nil, parse_err
    end
    local count = H.apply(node, parsed.entries)
    if type(node.log) == "function" then
        node:log("HOSTS_LOAD path=%s entries=%d source=rpv", short(path, 48), count)
    end
    return count
end

return H
