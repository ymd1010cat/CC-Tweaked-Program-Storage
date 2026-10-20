-- Sentinel PSK access: read the shared key, sign and verify data.
-- Deploy: /auth/psk.lua
--
-- Signing primitive: sha256(key .. "|" .. data), key = the 32 character PSK.

local sha256 = dofile("/sha256.lua")

local M = {}

local PSK_PATH = "/auth/psk.txt"
local cached = nil

local function readKey()
    if cached then return cached end
    if not fs.exists(PSK_PATH) then
        error("PSK file not found: " .. PSK_PATH, 0)
    end
    local handle = fs.open(PSK_PATH, "r")
    if not handle then
        error("PSK file not found: " .. PSK_PATH, 0)
    end
    local raw = handle.readAll()
    handle.close()
    local key = raw:gsub("%s+", "")
    if key == "" then
        error("PSK is empty.", 0)
    end
    cached = key
    return key
end

function M.get()
    return readKey()
end

function M.sign(data)
    return sha256.hash(readKey() .. "|" .. tostring(data))
end

function M.verify(data, sig)
    if type(sig) ~= "string" then return false end
    return M.sign(data) == sig
end

return M
