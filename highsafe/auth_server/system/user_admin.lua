-- user_admin.lua -- HighSafe root console: user and terminal key management.
-- Deploy path: /system/user_admin.lua
--
-- Started by /startup.lua next to the running service, so it only ever runs on
-- an auth server. A "root" account of /auth/users.db may operate it. Every
-- action reports "[OK] ..." or "[Error] ..." and then waits for Enter, because
-- the service owns the same screen and the operator cannot scroll back.

local USER_MANAGER_PATH = "/auth/user_manager.lua"
local TERMINAL_KEYS_PATH = "/auth/terminal_keys.lua"
local SHA_PATH = "/sha256.lua"
local USERS_DB_PATH = "/auth/users.db"
local SERVER_ID_PATH = "/auth/server_id"

local MAX_TERMINAL_ID_LENGTH = 64
local ACCESS_DENIED_DELAY = 1
local IDLE_DELAY = 30

local userManager = nil
local terminalKeys = nil
local sha = nil

local function loadLibrary(path)
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clearScreen()
    pcall(function()
        term.clear()
        term.setCursorPos(1, 1)
    end)
end

local function readLine()
    local text = read()
    if type(text) ~= "string" then return "" end
    return text
end

local function readSecret()
    local text = read("*")
    if type(text) ~= "string" then return "" end
    return text
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return text
end

local function readServerId()
    local text = readFile(SERVER_ID_PATH)
    if type(text) == "string" then
        text = text:gsub("%s+", "")
        if text ~= "" then return text end
    end
    return "not created yet"
end

local function loadUsersDb()
    local text = readFile(USERS_DB_PATH)
    if type(text) ~= "string" or text == "" then return {} end
    local ok, data = pcall(textutils.unserialize, text)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

-- Console login hashes locally against /auth/users.db: this console runs on the
-- machine that owns the file, and using the wire helper with empty nonces would
-- tie the console to the protocol's derivation for no benefit.
local function authenticate(name, password)
    if name == "" or password == "" or not sha then return nil end
    local user = loadUsersDb()[name]
    if type(user) ~= "table" then return nil end
    if type(user.salt) ~= "string" or user.salt == "" then return nil end
    if type(user.hash) ~= "string" then return nil end
    if sha.hash(password .. user.salt) ~= user.hash then return nil end
    return { name = name, role = user.role or "guest" }
end

local function loginScreen()
    local empty = next(loadUsersDb()) == nil
    while true do
        clearScreen()
        print("User Admin (server only)")
        print("Server ID: " .. readServerId())
        print("")
        if empty then
            print("No accounts in /auth/users.db.")
            print("Run setup_root.lua to create the first root account.")
            print("")
        end
        if not userManager then
            print("WARNING: /auth/user_manager.lua is not loadable")
            print("")
        end
        write("Username: ")
        local name = trim(readLine())
        if name == "" then return nil end
        write("Password: ")
        local password = readSecret()
        if password == "" then return nil end
        local user = authenticate(name, password)
        if user and user.role == "root" then
            return user
        end
        print("Access denied.")
        os.sleep(ACCESS_DENIED_DELAY)
    end
end

local function report(ok, message)
    if ok then
        print("[OK] " .. tostring(message or "done"))
    else
        print("[Error] " .. tostring(message or "failed"))
    end
end

local function pause()
    write("Press Enter to return...")
    readLine()
end

local function callManager(name, ...)
    if not userManager then
        return false, "/auth/user_manager.lua is not loadable"
    end
    local fn = userManager[name]
    if type(fn) ~= "function" then
        return false, "user manager has no " .. tostring(name)
    end
    local results = { pcall(fn, ...) }
    if results[1] ~= true then
        return false, tostring(results[2])
    end
    if results[2] == nil then
        return false, tostring(results[3] or "failed")
    end
    return results[2] == true, results[3]
end

local function validTerminalId(id)
    if type(id) ~= "string" or id == "" or #id > MAX_TERMINAL_ID_LENGTH then
        return false
    end
    if id:find("|", 1, true) then return false end
    if id:find("%c") then return false end
    return true
end

local function addUserFlow()
    clearScreen()
    print("=== Add User ===")
    write("Username: ")
    local name = trim(readLine())
    if name == "" then
        print("No user name given.")
        return pause()
    end
    write("Password: ")
    local password = readSecret()
    if password == "" then
        print("No password given.")
        return pause()
    end
    write("Role (admin/operator/guest): ")
    local role = trim(readLine())
    if role == "" then role = "guest" end
    local ok, message = callManager("addUser", name, password, role)
    report(ok, message)
    pause()
end

local function deleteUserFlow(actor)
    clearScreen()
    print("=== Delete User ===")
    write("Username: ")
    local name = trim(readLine())
    if name == "" then
        print("No user name given.")
        return pause()
    end
    write("Confirm delete '" .. name .. "'? (yes/no): ")
    if readLine() ~= "yes" then
        print("Cancelled.")
        return pause()
    end
    local ok, message = callManager("deleteUser", name, actor.name)
    report(ok, message)
    pause()
end

local function listUsersFlow()
    clearScreen()
    print("=== Users ===")
    if not userManager or type(userManager.listUsers) ~= "function" then
        print("[Error] /auth/user_manager.lua is not loadable")
        return pause()
    end
    local ok, list = pcall(userManager.listUsers)
    if not ok or type(list) ~= "table" then
        print("[Error] cannot read /auth/users.db")
        return pause()
    end
    if #list == 0 then
        print("No users.")
        return pause()
    end
    for i = 1, #list do
        local entry = list[i]
        local name, role
        if type(entry) == "table" then
            name = entry[1] or entry.name
            role = entry[2] or entry.role
        end
        print(string.format("%d. %s (%s)", i, tostring(name or "?"), tostring(role or "?")))
    end
    pause()
end

local function changeRoleFlow(actor)
    clearScreen()
    print("=== Change Role ===")
    write("Username: ")
    local name = trim(readLine())
    if name == "" then
        print("No user name given.")
        return pause()
    end
    write("Role (admin/operator/guest): ")
    local role = trim(readLine())
    if role == "" then role = "guest" end
    local ok, message = callManager("changeRole", name, role, actor.name)
    report(ok, message)
    pause()
end

local function listTerminalKeys()
    clearScreen()
    print("=== Terminal Keys ===")
    if not terminalKeys then
        print("[Error] /auth/terminal_keys.lua is not loadable")
        return pause()
    end
    local ok, ids = pcall(terminalKeys.list)
    if not ok or type(ids) ~= "table" then
        print("[Error] cannot read /auth/terminal_keys.db")
        return pause()
    end
    if #ids == 0 then
        print("No terminal keys registered.")
        return pause()
    end
    for i = 1, #ids do
        print("- " .. tostring(ids[i]))
    end
    print("")
    print("Total: " .. tostring(#ids))
    pause()
end

local function addTerminalKey()
    clearScreen()
    print("=== Add / Show Key ===")
    if not terminalKeys then
        print("[Error] /auth/terminal_keys.lua is not loadable")
        return pause()
    end
    write("Terminal ID: ")
    local id = trim(readLine())
    if id == "" then
        print("No terminal id given.")
        return pause()
    end
    if not validTerminalId(id) then
        print("[Error] invalid terminal id")
        return pause()
    end
    local ok, key = pcall(terminalKeys.add, id)
    if not ok or type(key) ~= "string" or key == "" then
        print("[Error] cannot write /auth/terminal_keys.db")
        return pause()
    end
    print("")
    print("Terminal ID: " .. id)
    print("Key:         " .. key)
    print("")
    print("Write this key into /auth/psk.txt")
    print("Write the ID into /auth/terminal_id.txt")
    print("on that terminal.")
    pause()
end

local function removeTerminalKey()
    clearScreen()
    print("=== Remove Key ===")
    if not terminalKeys then
        print("[Error] /auth/terminal_keys.lua is not loadable")
        return pause()
    end
    write("Terminal ID: ")
    local id = trim(readLine())
    if id == "" then
        print("No terminal id given.")
        return pause()
    end
    write("Confirm remove '" .. id .. "'? (yes/no): ")
    if readLine() ~= "yes" then
        print("Cancelled.")
        return pause()
    end
    local ok, removed = pcall(terminalKeys.remove, id)
    if ok and removed then
        print("[OK] Terminal key removed.")
    else
        print("[Error] Terminal key not found.")
    end
    pause()
end

local function terminalKeysMenu()
    while true do
        clearScreen()
        print("=== Terminal Keys ===")
        print("")
        print("1. List")
        print("2. Add / Show Key")
        print("3. Remove")
        print("0. Back")
        print("")
        write("Select an option: ")
        local choice = readLine()
        if choice == "1" then
            listTerminalKeys()
        elseif choice == "2" then
            addTerminalKey()
        elseif choice == "3" then
            removeTerminalKey()
        elseif choice == "0" then
            return
        end
    end
end

local function mainMenu(actor)
    while true do
        clearScreen()
        print("User Admin (server only)")
        print("User: " .. actor.name .. " (" .. tostring(actor.role) .. ")")
        print("")
        print("1. Add User")
        print("2. Delete User")
        print("3. List Users")
        print("4. Change Role")
        print("5. Manage Terminal Keys")
        print("0. Exit")
        print("")
        write("Select an option: ")
        local choice = readLine()
        if choice == "1" then
            addUserFlow()
        elseif choice == "2" then
            deleteUserFlow(actor)
        elseif choice == "3" then
            listUsersFlow()
        elseif choice == "4" then
            changeRoleFlow(actor)
        elseif choice == "5" then
            terminalKeysMenu()
        elseif choice == "0" then
            return
        end
    end
end

local function main()
    userManager = loadLibrary(USER_MANAGER_PATH)
    terminalKeys = loadLibrary(TERMINAL_KEYS_PATH)
    sha = loadLibrary(SHA_PATH)

    if not sha then
        clearScreen()
        print("FATAL: cannot load /sha256.lua")
        print("Root login needs the shared SHA-256 module.")
        while true do
            os.sleep(IDLE_DELAY)
        end
    end

    local user = loginScreen()
    if not user then return end
    mainMenu(user)
end

main()
