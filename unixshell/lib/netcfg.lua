-- netcfg.lua - one reader for the rednet settings of the whole system
--
-- The package manager (/etc/pkg.conf) and the licence client
-- (/etc/network.conf) already describe the same network: one modem side, one
-- protocol name ("channel") and one shared key. The file transfer and remote
-- execution commands must speak exactly the same protocol and use the same
-- key, so they read the settings here instead of inventing their own.
--
-- Precedence: /etc/pkg.conf first, then /etc/network.conf; a key set in
-- pkg.conf wins. Keys may contain underscores ("server_id", "modem_side",
-- "chunk_size"), which is why the pattern below is not plain "%w+": the older
-- pkg loader used "%w+" and silently dropped "server_id", leaving the package
-- manager with no server to talk to.

local netcfg = {}

local FILES = { "/etc/pkg.conf", "/etc/network.conf" }

local cache = nil

-- The file the winning value of each key came from, filled while load()
-- builds the cache and cleared by reload(). netcfg.source() answers "which
-- file do I have to edit", so that a message can name it instead of guessing.
local sources = {}

local DEFAULTS = {
    channel     = "pkg-repo",
    modem_side  = "back",
    chunk_size  = 4096,
    timeout     = 5,
    retries     = 3,
    max_output  = 8192,
}

local function parse_file(path, into)
    if not fs.exists(path) then return end
    local f = fs.open(path, "r")
    if not f then return end
    while true do
        local line = f.readLine()
        if line == nil then break end
        local k, v = line:match("^([%w_%-]+)%s*=%s*(.-)%s*$")
        if k then
            into[k] = v
            sources[k] = path
        end
    end
    f.close()
end

-- Every setting as a string, defaults applied. The table is cached: call
-- netcfg.reload() after editing a configuration file.
function netcfg.load()
    if cache then return cache end
    local cfg = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    -- Both files are read in reverse priority order so that pkg.conf wins.
    for i = #FILES, 1, -1 do parse_file(FILES[i], cfg) end
    cache = cfg
    return cfg
end

function netcfg.reload()
    cache = nil
    sources = {}
    return netcfg.load()
end

-- The configuration file the value of "key" came from, or nil when no file
-- sets it. Building the cache is what fills the answer, so the load() call
-- below is part of the contract.
function netcfg.source(key)
    netcfg.load()
    return sources[key]
end

function netcfg.get(key, fallback)
    local value = netcfg.load()[key]
    if value == nil or value == "" then return fallback end
    return value
end

function netcfg.number(key, fallback)
    local value = tonumber(netcfg.load()[key])
    if value == nil then return fallback end
    return value
end

-- Protocol name used by rednet. The licence server uses its own channel, the
-- repository and the data channel share this one.
function netcfg.channel() return netcfg.get("channel", DEFAULTS.channel) end

-- Shared key of the channel. crypto.lua turns it into a keystream, so a peer
-- that does not know the key cannot produce a message that decrypts.
function netcfg.key()
    local key = netcfg.load().key
    if key == nil or key == "" then
        return nil, "no key configured in " .. netcfg.server_file() ..
                    " (key=<shared secret>)"
    end
    return key
end

function netcfg.modem() return netcfg.get("modem_side", DEFAULTS.modem_side) end

function netcfg.server_id()
    local id = tonumber(netcfg.load().server_id)
    if id == nil or id <= 0 then return nil end
    return id
end

-- Switch values may be written as 1, true, yes or on, in any case. Everything
-- else counts as "off", so a typo or a missing key never switches a feature on
-- by accident.
function netcfg.truthy(value)
    if value == nil then return false end
    local v = tostring(value):lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

-- True when /etc/pkg.conf or /etc/network.conf asks for offline operation
-- (offline=true). pkg.conf wins over network.conf, like every other key here.
function netcfg.offline()
    return netcfg.truthy(netcfg.load().offline)
end

-- The file that describes the update server, for a message that has to name
-- one: the file the winning server_id (or key, or channel) came from, and
-- /etc/pkg.conf when nothing is configured yet, which is the file to create.
function netcfg.server_file()
    return tostring(netcfg.source("server_id") or netcfg.source("key") or
                    netcfg.source("channel") or FILES[1])
end

-- Describe the update server without touching the network:
--
--   configured  true when there is an update server to talk to
--   server_id   the computer id to send to, or nil
--   offline     offline mode is on, so no request may be made at all
--   reason      why there is no server, for the user to read
--
-- A computer with no update server is a normal state, not an error: pkg.lua
-- and firstboot ask here before a request and report reason / setup_hint()
-- instead of raising or waiting for a reply that cannot come.
function netcfg.server_config()
    local st = {
        configured = false,
        server_id  = netcfg.server_id(),
        offline    = netcfg.offline(),
        reason     = nil,
    }
    if st.offline then
        -- Offline mode is an answer in itself: nothing is sent, nothing waits.
        -- The file named is the one that carries offline=true, so the message
        -- points at the line the user has to change.
        st.server_id = nil
        local file = netcfg.source("offline") or netcfg.server_file()
        st.reason = "no update server in use: offline mode is enabled in " ..
                    file .. " (offline=true)"
        return st
    end
    local raw = netcfg.load().server_id
    if raw == nil or tostring(raw) == "" then
        st.reason = "no update server configured: server_id is not set in " ..
                    netcfg.server_file()
        return st
    end
    if not st.server_id then
        st.reason = "no update server configured: server_id '" .. tostring(raw) ..
                    "' is not a positive computer id"
        return st
    end
    st.configured = true
    return st
end

function netcfg.chunk_size()
    local size = netcfg.number("chunk_size", DEFAULTS.chunk_size)
    if size < 64 then size = 64 end
    if size > 32768 then size = 32768 end
    return size
end

function netcfg.timeout()
    local t = netcfg.number("timeout", DEFAULTS.timeout)
    if t <= 0 then t = DEFAULTS.timeout end
    return t
end

function netcfg.retries()
    local r = netcfg.number("retries", DEFAULTS.retries)
    if r < 0 then r = 0 end
    return r
end

function netcfg.max_output()
    local m = netcfg.number("max_output", DEFAULTS.max_output)
    if m < 256 then m = 256 end
    return m
end

-- Open rednet on the configured side, falling back to the first side that
-- carries a modem. Returns true when rednet is open, or nil plus a reason.
function netcfg.open()
    -- lazy require: rpvnet itself requires netcfg, so it cannot be at the top
    local rpvnet = require("rpvnet")
    local ok = pcall(rpvnet.open, netcfg.modem())
    if ok then return true end

    local ok_sys, sysinfo = pcall(require, "sysinfo")
    if ok_sys and sysinfo.network then
        for _, entry in ipairs(sysinfo.network()) do
            if pcall(rpvnet.open, entry.side) then return true end
        end
    end
    return nil, "no modem could be opened (side " .. tostring(netcfg.modem()) .. ")"
end

-- Resolve the computer a command was pointed at. A plain id ("5") is the
-- normal case; a name is looked up in /etc/hosts, one entry per line:
--
--   <id> <name> [alias ...]        # comments may follow
--
-- Only the data channel commands read that file, so a network of a few
-- computers can use names without giving up the ids. Returns the id, or nil
-- plus a reason.
function netcfg.resolve_target(value)
    if type(value) == "number" then
        if value <= 0 then return nil, "invalid computer id: " .. tostring(value) end
        return value
    end
    local text = tostring(value or "")
    local id = tonumber(text)
    if id then
        if id <= 0 then return nil, "invalid computer id: " .. text end
        return id
    end
    if text == "" then return nil, "no computer given" end

    if fs.exists("/etc/hosts") then
        local f = fs.open("/etc/hosts", "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                local number, rest = line:match("^%s*(%d+)%s+(.+)$")
                if number then
                    rest = rest:gsub("#.*$", "")
                    for name in rest:gmatch("%S+") do
                        if name == text then
                            f.close()
                            return tonumber(number)
                        end
                    end
                end
            end
            f.close()
        end
    end
    return nil, "unknown computer: " .. text .. " (no entry in /etc/hosts)"
end

-- Wrap a message for the channel: serialized, then encrypted with the key.
function netcfg.pack(msg)
    local key, err = netcfg.key()
    if not key then return nil, err end
    return require("crypto").encrypt(key, textutils.serialize(msg))
end

-- Unwrap an incoming message. Returns the table, or nil plus a reason. A
-- message that does not decrypt is indistinguishable from noise on the
-- channel; the callers report it as a rejected peer.
function netcfg.unpack(blob)
    local key = netcfg.key()
    if not key then return nil, "no key configured" end
    if type(blob) ~= "string" then return nil, "not a string payload" end
    local plain = require("crypto").decrypt(key, blob)
    if not plain then return nil, "could not be decrypted" end
    local msg = textutils.unserialize(plain)
    if type(msg) ~= "table" then return nil, "not a message table" end
    return msg
end

return netcfg
