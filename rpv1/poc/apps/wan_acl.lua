--[[- apps/wan_acl.lua - fail-closed channel whitelist for the rpv WAN side.

The WAN is one modem channel: every computer on it can hear the traffic (rednet
peers, ender-modem bridges), so the WAN programs ask this object which channels
they are willing to use. The default policy allows the 200..299 band and denies
everything else; `allow` adds a channel (or a range) at runtime or from a file.

The object is deliberately dumb: `check(channel)` only answers true/false and
keeps counters. It never sees a packet, so a rejected packet's payload cannot
end up in a log; the optional logger is called with a single event word.

    local wan_acl = ...             -- loaded as apps/wan_acl.lua
    local acl = wan_acl.new()       -- default band 200..299
    acl:check(250)                  -- true
    acl:check(300)                  -- false
    acl:allow(4700)                 -- dynamic allow
    acl:check(4700)                 -- true

`new(opts)` keys (all optional):

    - band  = { 200, 299 }   default band; `false` disables it (empty whitelist)
    - allow = { 4700 }       extra allowed channels
    - deny  = { 250 }        explicit denies; they win over allow and band
    - path  = "wan_acl.txt"  load a whitelist file immediately (errors are kept
                             in `acl.config_error`, the policy stays fail-closed)
    - log   = function(event)  called with "WAN_ACL_DENY" only, never payloads

Whitelist file (ASCII, one entry per line, `#` comments):

    200-299      # a band
    4700         # a single channel

`acl:load(path)` is additive, not a replacement: it merges the file into the
current policy and never revokes anything (the default band and earlier allows
stay). Loading the same file twice keeps `check()` answering the same, but it
appends the file's bands to the internal range list again (MAX_RANGES = 128), so
load once at startup. To replace the policy, build a fresh acl
(`wan_acl.new`); to revoke one channel, call `acl:deny(ch)` (deny wins over
allow and band).

Invalid channels (nil, strings, non-integers, NaN, outside 0..65535) are always
denied, and an empty policy denies everything. Lua 5.1, no dependencies.
]]

local M = {}

M.MIN_CHANNEL = 0
M.MAX_CHANNEL = 65535
M.DEFAULT_BAND = { 200, 299 }
M.MAX_RANGES = 128
M.DEFAULT_PATH = "wan_acl.txt"

local function is_channel(ch)
    if type(ch) ~= "number" then return false end
    if ch ~= ch then return false end          -- NaN
    if ch ~= math.floor(ch) then return false end
    return ch >= M.MIN_CHANNEL and ch <= M.MAX_CHANNEL
end

M.is_channel = is_channel

local Acl = {}
Acl.__index = Acl

-- ===== policy mutation =====================================================
function Acl:allow(ch)
    if not is_channel(ch) then return nil, "invalid channel" end
    self.allow_set[ch] = true
    return true
end

function Acl:allow_range(lo, hi)
    if not is_channel(lo) or not is_channel(hi) then return nil, "invalid channel range" end
    if lo > hi then return nil, "channel range is inverted" end
    if #self.ranges >= M.MAX_RANGES then return nil, "too many channel ranges" end
    self.ranges[#self.ranges + 1] = { lo, hi }
    return true
end

function Acl:deny(ch)
    if not is_channel(ch) then return nil, "invalid channel" end
    self.deny_set[ch] = true
    self.allow_set[ch] = nil
    return true
end

-- ===== policy check ========================================================
function Acl:_denied()
    self.denied = self.denied + 1
    if self.log_fn then pcall(self.log_fn, "WAN_ACL_DENY") end
    return false
end

function Acl:check(ch)
    self.checked = self.checked + 1
    if not is_channel(ch) then return self:_denied() end
    if self.deny_set[ch] then return self:_denied() end
    if self.allow_set[ch] then
        self.allowed = self.allowed + 1
        return true
    end
    for i = 1, #self.ranges do
        local r = self.ranges[i]
        if ch >= r[1] and ch <= r[2] then
            self.allowed = self.allowed + 1
            return true
        end
    end
    return self:_denied()
end

function Acl:stats()
    return {
        checked = self.checked,
        allowed = self.allowed,
        denied = self.denied,
        channels = self:_count_channels(),
        ranges = #self.ranges,
        config_error = self.config_error,
    }
end

function Acl:_count_channels()
    local n = 0
    for _ in pairs(self.allow_set) do n = n + 1 end
    return n
end

-- ===== whitelist file ======================================================
-- Adds to the current policy (it does not revoke channels). The file is parsed
-- completely before anything is applied, so a malformed file changes nothing;
-- the capacity pre-check runs before the same boundary, so a file that does not
-- fit (current ranges + file ranges > MAX_RANGES) is refused without applying a
-- single entry either.
function Acl:load(path)
    local path = path or M.DEFAULT_PATH
    local ok, err = M.check_path(path)
    if not ok then return nil, err end
    if type(fs) ~= "table" or type(fs.open) ~= "function" then return nil, "fs API is not available" end
    local exists, yes = pcall(fs.exists, path)
    if not exists then return nil, tostring(yes) end
    if not yes then return nil, "no such whitelist: " .. path end
    local fok, handle = pcall(fs.open, path, "r")
    if not fok or not handle then return nil, tostring(handle) end
    local rok, data = pcall(handle.readAll, handle)
    pcall(handle.close, handle)
    if not rok or type(data) ~= "string" then return nil, "whitelist is not readable" end

    local singles, ranges = {}, {}
    local lineno = 0
    for line in (data .. "\n"):gmatch("(.-)\n") do
        lineno = lineno + 1
        local line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local lo, hi = line:match("^(%d+)%s*%-%s*(%d+)$")
            local one = line:match("^(%d+)$")
            if lo then
                lo, hi = tonumber(lo), tonumber(hi)
                if not is_channel(lo) or not is_channel(hi) then
                    return nil, string.format("%s:%d: channel band is out of range", path, lineno)
                end
                if lo > hi then return nil, string.format("%s:%d: channel band is inverted", path, lineno) end
                ranges[#ranges + 1] = { lo, hi }
            elseif one then
                one = tonumber(one)
                if not is_channel(one) then
                    return nil, string.format("%s:%d: channel is out of range", path, lineno)
                end
                singles[#singles + 1] = one
            else
                return nil, string.format("%s:%d: expected `<channel>` or `<lo>-<hi>`", path, lineno)
            end
        end
    end
    -- capacity pre-check against the *current* policy: everything below mutates
    -- ranges, so a file that does not fit must be refused before the first apply
    -- (a failed load leaves the policy untouched, fail-closed). Singles cannot
    -- fail: allow_set is unbounded, only MAX_RANGES limits the range list.
    if #self.ranges + #ranges > M.MAX_RANGES then return nil, "too many channel ranges" end
    for _, r in ipairs(ranges) do
        local aok, aerr = self:allow_range(r[1], r[2])
        if not aok then return nil, aerr end
    end
    for _, ch in ipairs(singles) do
        self.allow_set[ch] = true
    end
    self.source = path
    self.config_error = nil
    return { ok = true, ranges = #ranges, channels = #singles, path = path }
end

-- ===== construction ========================================================
function M.new(opts)
    local opts = opts or {}
    if type(opts) ~= "table" then return nil, "opts must be a table" end
    local self = setmetatable({
        ranges = {}, allow_set = {}, deny_set = {},
        checked = 0, allowed = 0, denied = 0,
        log_fn = type(opts.log) == "function" and opts.log or nil,
        config_error = nil, source = nil,
    }, Acl)

    local band = opts.band
    if band == nil then band = M.DEFAULT_BAND end
    if band ~= false then
        if type(band) ~= "table" then return nil, "band must be { lo, hi } or false" end
        local bok, berr = self:allow_range(band[1], band[2])
        if not bok then return nil, "bad band: " .. tostring(berr) end
    end

    if opts.allow ~= nil then
        if type(opts.allow) ~= "table" then return nil, "allow must be a list of channels" end
        for _, ch in ipairs(opts.allow) do
            local aok, aerr = self:allow(ch)
            if not aok then return nil, "bad allow entry: " .. tostring(aerr) end
        end
    end
    if opts.deny ~= nil then
        if type(opts.deny) ~= "table" then return nil, "deny must be a list of channels" end
        for _, ch in ipairs(opts.deny) do
            local dok, derr = self:deny(ch)
            if not dok then return nil, "bad deny entry: " .. tostring(derr) end
        end
    end
    if opts.path ~= nil then
        local lok, lerr = self:load(opts.path)
        if not lok then self.config_error = tostring(lerr) end
    end
    return self
end

-- path validation shared with apps/hosts.lua (kept local: no cross-module coupling)
function M.check_path(path)
    if type(path) ~= "string" then return nil, "path must be a string" end
    if path == "" or #path > 255 then return nil, "path must be 1..255 bytes" end
    for i = 1, #path do
        local b = path:byte(i)
        if b < 32 or b > 126 then return nil, "path has control or non-ASCII bytes" end
    end
    for segment in path:gmatch("[^/\\]+") do
        if segment == ".." then return nil, "path traversal is not allowed" end
    end
    if path:match("[/\\]$") then return nil, "path must name a file" end
    return true
end

return M
