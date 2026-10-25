-- role_policy.lua -- pure role ranking and authorisation helpers.
-- Deploy: /auth/role_policy.lua on the auth server, the audit server and the
-- client terminal.
--
-- Roles live per account in /auth/users.db; this module never touches the
-- store. It only answers "how strong is this role" and "does this role satisfy
-- a required role". "guest" is a legacy alias of "user" and normalises to it,
-- so a stored guest account has the same weight as a stored user account.

local M = {}

local WEIGHTS = {
    root = 4,
    admin = 3,
    operator = 2,
    user = 1,
}

local ALIASES = {
    guest = "user",
}

--- Canonical role name, or nil for anything that is not a known role.
function M.normalize(role)
    if type(role) ~= "string" then return nil end
    local text = (role:lower():gsub("%s+", ""))
    if text == "" then return nil end
    text = ALIASES[text] or text
    if not WEIGHTS[text] then return nil end
    return text
end

--- Numeric weight of a role; nil when the role is unknown.
function M.weight(role)
    local canonical = M.normalize(role)
    if not canonical then return nil end
    return WEIGHTS[canonical]
end

--- True only when userRole is at least as strong as required.
function M.allows(userRole, required)
    local have = M.weight(userRole)
    if not have then return false end
    local need = M.weight(required)
    if not need then return false end
    return have >= need
end

return M
