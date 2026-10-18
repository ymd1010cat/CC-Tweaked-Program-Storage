-- HighSafe one-time root account setup (standalone / auth server machine).
-- Deploy: /setup_root.lua
--
-- Refuses to run when any root account already exists. The account is created
-- with the same salt/hash rules as /auth/user_manager.lua.

local sha256 = dofile("/sha256.lua")

local USERS_PATH = "/auth/users.db"
local SALT_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
local SALT_LENGTH = 16
local MAX_NAME = 32
local MAX_PASSWORD = 128

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

local function hasRoot(users)
    for _, record in pairs(users) do
        if type(record) == "table" and record.role == "root" then
            return true
        end
    end
    return false
end

local function saveUsers(users)
    if not fs.exists("/auth") then
        pcall(fs.makeDir, "/auth")
    end
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

print("HighSafe Root Setup (one-time)")
print("")

local users = loadUsers()
if hasRoot(users) then
    print("A root account already exists.")
    print("Setup refused.")
    return
end

write("Username: ")
local name = read()
if name == nil or name == "" or #name > MAX_NAME then
    print("Invalid username.")
    return
end

write("Password: ")
local password = read("*")
if password == nil or password == "" or #password > MAX_PASSWORD then
    print("Invalid password.")
    return
end

local salt = makeSalt()
users[name] = {
    salt = salt,
    hash = sha256.hash(password .. salt),
    role = "root",
}

if not saveUsers(users) then
    print("Cannot write " .. USERS_PATH)
    return
end

print("[OK] Root account '" .. name .. "' created.")
