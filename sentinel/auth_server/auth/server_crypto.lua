-- server_crypto.lua -- server-side signatures for the secure_auth_v5 protocol.
-- Deploy path: /auth/server_crypto.lua
--
-- A signature is sha256(terminal_key .. "|" .. data). The terminal key lives in
-- /auth/terminal_keys.db and never leaves the server, so sign() also answers
-- "may this terminal be talked to at all": an unknown id has no key and
-- therefore cannot be signed for or verified against.
--
-- Both helpers fail closed and never raise: sign() returns nil, verify()
-- returns false.

local M = {}

local KEYS_MODULE = "/auth/terminal_keys.lua"
local SHA_MODULE = "/sha256.lua"
local SIG_LENGTH = 64

local shaModule = nil
local shaLoaded = false
local keyStore = nil
local keyStoreLoaded = false

local function getSha()
    if shaLoaded then return shaModule end
    shaLoaded = true
    local ok, mod = pcall(dofile, SHA_MODULE)
    if ok and type(mod) == "table" and type(mod.hash) == "function" then
        shaModule = mod
    end
    return shaModule
end

local function getKeyStore()
    if keyStoreLoaded then return keyStore end
    keyStoreLoaded = true
    local ok, mod = pcall(dofile, KEYS_MODULE)
    if ok and type(mod) == "table" and type(mod.get) == "function" then
        keyStore = mod
    end
    return keyStore
end

local function keyFor(terminalId)
    if type(terminalId) ~= "string" or terminalId == "" then return nil end
    local store = getKeyStore()
    if not store then return nil end
    local ok, key = pcall(store.get, terminalId)
    if not ok then return nil end
    if type(key) ~= "string" or key == "" then return nil end
    return key
end

--- 64 lowercase hex characters, or nil when no key exists for the terminal.
function M.sign(terminalId, data)
    if type(data) ~= "string" then return nil end
    local key = keyFor(terminalId)
    if not key then return nil end
    local sha = getSha()
    if not sha then return nil end
    return sha.hash(key .. "|" .. data)
end

--- True only for the exact signature of a registered terminal.
function M.verify(terminalId, data, sig)
    if type(sig) ~= "string" then return false end
    sig = sig:lower()
    if #sig ~= SIG_LENGTH or sig:find("[^0-9a-f]") then return false end
    local expected = M.sign(terminalId, data)
    if not expected then return false end
    return expected == sig
end

return M
