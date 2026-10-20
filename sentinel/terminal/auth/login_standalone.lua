-- Sentinel standalone login: local /auth/users.db compare, no network, no audit.
-- Deploy: /auth/login_standalone.lua

local sha256 = dofile("/sha256.lua")

local M = {}

local USERS_PATH = "/auth/users.db"
local UNKNOWN_SALT = "ffffffffffffffff"

local function loadUsers()
    if not fs.exists(USERS_PATH) then return {} end
    local handle = fs.open(USERS_PATH, "r")
    if not handle then return {} end
    local raw = handle.readAll()
    handle.close()
    local ok, decoded = pcall(textutils.unserialize, raw)
    if ok and type(decoded) == "table" then return decoded end
    return {}
end

local function checkCredentials(username, password)
    local users = loadUsers()
    local record = users[username]
    if type(record) ~= "table" or type(record.salt) ~= "string"
        or type(record.hash) ~= "string" then
        -- Still burn one hash so unknown users cost the same as wrong ones.
        sha256.hash(password .. UNKNOWN_SALT)
        return nil
    end
    local candidate = sha256.hash(password .. record.salt)
    if candidate ~= record.hash then return nil end
    return { name = username, role = record.role or "guest" }
end

function M.login()
    term.clear()
    term.setCursorPos(1, 1)
    print("Secure Terminal")
    print("")
    write("Username: ")
    local username = read()
    if username == nil or username == "" then return nil end
    write("Password: ")
    local password = read("*")
    if password == nil or password == "" then return nil end

    print("Authenticating...")
    local user = checkCredentials(username, password)
    if not user then
        print("[Error] Invalid credentials")
        return nil
    end
    return user
end

function M.verifyPassword(username, password)
    if type(username) ~= "string" or username == "" then return false end
    if type(password) ~= "string" or password == "" then return false end
    return checkCredentials(username, password) ~= nil
end

return M
