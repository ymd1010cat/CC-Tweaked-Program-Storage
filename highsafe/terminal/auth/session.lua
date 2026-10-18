-- HighSafe session tokens, kept in memory only.
-- Deploy: /auth/session.lua

local M = {}

local TTL_MS = 3600000
local active = {}

local function now()
    return os.epoch("utc")
end

local function makeToken()
    local token = nil
    repeat
        token = tostring(now()) .. "-" .. tostring(math.random(1, 2147483647))
    until active[token] == nil
    return token
end

function M.create(user)
    if type(user) ~= "table" then return nil end
    local token = makeToken()
    active[token] = { user = user, created = now() }
    return token
end

function M.validate(token)
    local slot = active[token]
    if not slot then return false end
    if now() - slot.created > TTL_MS then
        active[token] = nil
        return false
    end
    return slot.user
end

function M.destroy(token)
    active[token] = nil
end

return M
