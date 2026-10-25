-- Sentinel standalone login: retired.
-- Deploy: /auth/login_standalone.lua
--
-- Offline authentication is not supported any more: roles and password hashes
-- live on the auth server, so a local /auth/users.db is no longer an authority.
-- The module is kept only so an old deployment that still reaches for it fails
-- loudly instead of silently checking a stale local store.

local M = {}

local MESSAGE = "Offline mode is disabled. Connect to the auth server."

function M.login()
    error(MESSAGE, 0)
end

function M.verifyPassword(username, password)
    error(MESSAGE, 0)
end

return M
