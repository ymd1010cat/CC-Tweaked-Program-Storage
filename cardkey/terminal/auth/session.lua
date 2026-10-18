-- CardKey terminal session table: create/validate/destroy, fixed TTL.
-- Deploy path: /auth/session.lua
-- Sessions live in memory only; a reboot drops every one of them.

local M = {}

local TTL_MS = 600000
local sessions = {}
local serial = 0

local function nowMs()
    return os.epoch("utc")
end

local function newToken()
    serial = serial + 1
    return tostring(os.getComputerID()) .. "-" .. tostring(nowMs()) .. "-"
        .. tostring(serial) .. "-" .. tostring(math.random(1, 2147483647))
end

local function isExpired(record)
    return (nowMs() - record.created) > TTL_MS
end

-- create(user) -> token | (nil, reason)
function M.create(user)
    if type(user) ~= "table" then
        return nil, "invalid user"
    end
    local token = newToken()
    sessions[token] = {
        token = token,
        user = user,
        created = nowMs(),
        ttl = TTL_MS,
        last_seen = nowMs(),
    }
    return token
end

-- validate(token) -> record | (nil, reason)
function M.validate(token)
    if type(token) ~= "string" or sessions[token] == nil then
        return nil, "invalid session"
    end
    local record = sessions[token]
    if isExpired(record) then
        sessions[token] = nil
        return nil, "session expired"
    end
    record.last_seen = nowMs()
    return record, nil
end

-- destroy(token) -> true when a session was removed, false otherwise
function M.destroy(token)
    if type(token) ~= "string" or sessions[token] == nil then
        return false
    end
    sessions[token] = nil
    return true
end

return M
