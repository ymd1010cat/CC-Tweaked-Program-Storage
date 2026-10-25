-- Sentinel login dispatcher: the auth server is the only credential authority.
-- Deploy: /auth/login.lua
--
-- The offline (standalone) store is retired: every login, password re-check and
-- vault request goes over the modem through /auth/login_client.lua.

local M = {}

local ok, loginClient = pcall(dofile, "/auth/login_client.lua")
if not ok or type(loginClient) ~= "table" then
    error("cannot load /auth/login_client.lua", 0)
end

function M.login()
    return loginClient.login()
end

function M.verifyPassword(username, password)
    return loginClient.verifyPassword(username, password)
end

-- Ask the auth server to grant vault access for an authenticated account.
-- Returns ok, reason, code, detail (see login_client.requestOpen).
function M.requestOpen(username)
    return loginClient.requestOpen(username)
end

return M
