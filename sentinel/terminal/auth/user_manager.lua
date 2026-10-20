-- Sentinel shared user store (standalone terminal and auth server).
-- Deploy: /auth/user_manager.lua
--
-- Users live in /auth/users.db as textutils.serialize of
--   { [name] = { salt = <16 alnum>, hash = <64 hex>, role = <role> } }
-- where hash = sha256(password .. salt) and the login derivation is
--   derived = sha256(hash .. "|" .. nonce_c .. "|" .. nonce_s).
--
-- Rules: no root creation through this API, names <= 32, passwords <= 128,
-- roles in {admin, operator, guest}, no self deletion, the last root cannot be
-- deleted, and root accounts cannot be modified.

local sha256 = dofile("/sha256.lua")

local M = {}

local USERS_PATH = "/auth/users.db"
local SALT_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
local SALT_LENGTH = 16
local MAX_NAME = 32
local MAX_PASSWORD = 128
local ROLES = { admin = true, operator = true, guest = true }

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

local function saveUsers(users)
    local handle = fs.open(USERS_PATH, "w")
    if not handle then return false end
    handle.write(textutils.serialize(users))
    handle.close()
    return true
end

local function makeSalt()
    local parts = {}
    for index = 1, SALT_LENGTH do
        local pick = math.random(1, #SALT_ALPHABET)
        parts[index] = SALT_ALPHABET:sub(pick, pick)
    end
    return table.concat(parts)
end

local function countRoots(users)
    local count = 0
    for _, record in pairs(users) do
        if type(record) == "table" and record.role == "root" then
            count = count + 1
        end
    end
    return count
end

local function checkNewUser(name, password, role)
    if type(name) ~= "string" or name == "" then
        return false, "Name cannot be empty."
    end
    if #name > MAX_NAME then
        return false, "Name too long (max " .. MAX_NAME .. ")."
    end
    if type(password) ~= "string" or password == "" then
        return false, "Password cannot be empty."
    end
    if #password > MAX_PASSWORD then
        return false, "Password too long (max " .. MAX_PASSWORD .. ")."
    end
    if role == "root" then
        return false, "Root accounts cannot be created through UI."
    end
    if not ROLES[role] then
        return false, "Invalid role: " .. tostring(role)
    end
    return true
end

function M.addUser(name, password, role)
    local ok, message = checkNewUser(name, password, role)
    if not ok then return false, message end

    local users = loadUsers()
    if type(users[name]) == "table" then
        return false, "User already exists."
    end

    local salt = makeSalt()
    users[name] = {
        salt = salt,
        hash = sha256.hash(password .. salt),
        role = role,
    }
    if not saveUsers(users) then
        return false, "Cannot write users.db."
    end
    return true, "User '" .. name .. "' added."
end

function M.deleteUser(name, requester)
    if type(name) ~= "string" or name == "" then
        return false, "Name cannot be empty."
    end

    local users = loadUsers()
    local record = users[name]
    if type(record) ~= "table" then
        return false, "User not found."
    end
    if name == requester then
        return false, "Cannot delete yourself."
    end
    if record.role == "root" and countRoots(users) <= 1 then
        return false, "Cannot delete the last root account."
    end

    users[name] = nil
    if not saveUsers(users) then
        return false, "Cannot write users.db."
    end
    return true, "User '" .. name .. "' deleted."
end

function M.changeRole(name, role, requester)
    if type(name) ~= "string" or name == "" then
        return false, "Name cannot be empty."
    end

    local users = loadUsers()
    local record = users[name]
    if type(record) ~= "table" then
        return false, "User not found."
    end
    if record.role == "root" then
        return false, "Root accounts cannot be modified."
    end
    if role == "root" then
        return false, "Root accounts cannot be created through UI."
    end
    if not ROLES[role] then
        return false, "Invalid role: " .. tostring(role)
    end

    record.role = role
    if not saveUsers(users) then
        return false, "Cannot write users.db."
    end
    return true, "User '" .. name .. "' is now " .. role .. "."
end

function M.listUsers()
    local users = loadUsers()
    local names = {}
    for name in pairs(users) do
        names[#names + 1] = name
    end
    table.sort(names)

    local result = {}
    for _, name in ipairs(names) do
        result[#result + 1] = { name = name, role = users[name].role }
    end
    return result
end

function M.getSalt(name)
    local users = loadUsers()
    local record = users[name]
    if type(record) ~= "table" or type(record.salt) ~= "string" then
        return nil
    end
    return record.salt
end

function M.verifyDerived(name, derived, nonceC, nonceS)
    if type(name) ~= "string" or type(derived) ~= "string" then
        return false, nil
    end
    if type(nonceC) ~= "string" or type(nonceS) ~= "string" then
        return false, nil
    end

    local users = loadUsers()
    local record = users[name]
    if type(record) ~= "table" or type(record.hash) ~= "string" then
        return false, nil
    end

    local expected = sha256.hash(record.hash .. "|" .. nonceC .. "|" .. nonceS)
    if expected ~= derived then
        return false, nil
    end
    return true, record.role
end

return M
