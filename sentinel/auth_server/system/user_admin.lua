-- user_admin.lua -- Sentinel root console: user and terminal key management.
-- Deploy path: /system/user_admin.lua
--
-- Started by /startup.lua next to the running service, so it only ever runs on
-- an auth server. A "root" account of /auth/users.db may operate it. Every
-- action reports "[OK] ..." or "[Error] ..." and then waits for Enter, because
-- the service owns the same screen and the operator cannot scroll back.

local USER_MANAGER_PATH = "/auth/user_manager.lua"
local TERMINAL_KEYS_PATH = "/auth/terminal_keys.lua"
local ROLE_POLICY_PATH = "/auth/role_policy.lua"
local SHA_PATH = "/sha256.lua"
local USERS_DB_PATH = "/auth/users.db"
local SERVER_ID_PATH = "/auth/server_id"
local CONSOLE_LOG_PATH = "/auth/console.log"

-- Read by /startup.lua. The console runs inside os.run({}, ...), whose
-- environment keeps its own writes, so this must be assigned on _G explicitly.
local CONSOLE_EXIT_FLAG = "SENTINEL_CONSOLE_EXIT"

local MAX_TERMINAL_ID_LENGTH = 64
local ACCESS_DENIED_DELAY = 1
local IDLE_DELAY = 30
-- Mount path used when a drive peripheral does not answer getMountPath.
local DISK_MOUNT_FALLBACK = "/disk"

local userManager = nil
local terminalKeys = nil
local rolePolicy = nil
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
    return { name = name, role = user.role }
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
        if not rolePolicy then
            print("WARNING: /auth/role_policy.lua is not loadable")
            print("")
        end
        write("Username: ")
        local name = trim(readLine())
        if name == "" then return nil end
        write("Password: ")
        local password = readSecret()
        if password == "" then return nil end
        local user = authenticate(name, password)
        if user and rolePolicy and rolePolicy.allows(user.role, "root") then
            return user
        end
        print("Access denied.")
        os.sleep(ACCESS_DENIED_DELAY)
    end
end

-- Append one line to /auth/console.log. Best effort: a console that cannot log
-- still works, the record just stays missing.
local function timestamp()
    local ok, value = pcall(function()
        return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end)
    if ok and type(value) == "string" then return value end
    return "?"
end

local function appendLog(line)
    local handle = fs.open(CONSOLE_LOG_PATH, "a")
    if not handle then return end
    pcall(function()
        handle.writeLine(timestamp() .. " " .. tostring(line))
    end)
    handle.close()
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
    write("Role (admin/operator/user/guest): ")
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
    write("Role (admin/operator/user/guest): ")
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

-- Mount path of the first drive peripheral (names sorted, like the audit
-- server picks its drive). Returns nil plus a reason when there is no usable
-- drive, so the flow can say why instead of failing silently.
local function findDriveMount()
    if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
        return nil, "no peripheral API"
    end
    local okNames, names = pcall(peripheral.getNames)
    if not okNames or type(names) ~= "table" then
        return nil, "cannot list peripherals"
    end
    table.sort(names)
    for i = 1, #names do
        local name = names[i]
        local okType, kind = pcall(peripheral.getType, name)
        if okType and kind == "drive" then
            local okPresent, present = pcall(peripheral.call, name, "isDiskPresent")
            if okPresent and present == false then
                return nil, "no disk in " .. tostring(name)
            end
            local okPath, mount = pcall(peripheral.call, name, "getMountPath")
            if okPath and type(mount) == "string" and mount ~= "" then
                return mount
            end
            return DISK_MOUNT_FALLBACK
        end
    end
    return nil, "no disk drive"
end

-- Copies one terminal's key to the floppy, so the operator never retypes the 32
-- random characters (a CC screen cannot drag-select). The terminal then only
-- needs "copy /disk/psk.txt /auth/psk.txt" before /startup.lua is installed.
local function writeKeyToDiskFlow()
    clearScreen()
    print("=== Write Key to Disk ===")
    if not terminalKeys then
        print("[Error] /auth/terminal_keys.lua is not loadable")
        return pause()
    end
    local mount, why = findDriveMount()
    if not mount then
        print("[Error] " .. tostring(why))
        print("Attach a drive with a floppy disk and try again.")
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
    local ok, key = pcall(terminalKeys.get, id)
    if not ok or type(key) ~= "string" or key == "" then
        print("[Error] terminal id not registered: " .. id)
        return pause()
    end
    local function writeDisk(name, text)
        local handle = fs.open(mount .. "/" .. name, "w")
        if not handle then return false end
        local wrote = pcall(function()
            handle.write(text)
        end)
        handle.close()
        return wrote
    end
    local wroteKey = writeDisk("psk.txt", key)
    local wroteId = writeDisk("terminal_id.txt", id)
    if not wroteKey or not wroteId then
        print("[Error] cannot write to " .. mount .. " (write protected?)")
        return pause()
    end
    print("")
    print("[OK] Wrote key for " .. id .. " to:")
    print("  " .. mount .. "/psk.txt")
    print("  " .. mount .. "/terminal_id.txt")
    print("")
    print("On that terminal, before /startup.lua is installed:")
    print("  copy " .. mount .. "/psk.txt /auth/psk.txt")
    print("  copy " .. mount .. "/terminal_id.txt /auth/terminal_id.txt")
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
        print("4. Write Key to Disk")
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
        elseif choice == "4" then
            writeKeyToDiskFlow()
        elseif choice == "0" then
            return
        end
    end
end

-- The one exit the anti-exit defence deliberately allows: a root operator may
-- hand this computer back to the CraftOS shell (maintenance, recovery). Because
-- that stops the service and exposes /auth, the account password is asked for
-- again as a second confirmation (same idea as the terminal's Exit to CraftOS).
-- The password is re-checked against /auth/users.db and the role is re-read from
-- the database, so a downgraded or deleted account cannot take this exit.
-- Returns true when the shell handover was requested; mainMenu then unwinds so
-- /startup.lua can see the flag and finish.
local function exitToShellFlow(actor)
    clearScreen()
    print("=== Exit to Shell ===")
    if not rolePolicy or not rolePolicy.allows(actor.role, "root") then
        print("[Error] only a root account may exit to the shell")
        appendLog("CONSOLE_SHELL_DENIED user=" .. tostring(actor.name)
            .. " role=" .. tostring(actor.role) .. " reason=not_root")
        pause()
        return false
    end
    print("This stops the auth service and leaves the CraftOS shell")
    print("running on this computer. Until it reboots, /auth (users,")
    print("terminal keys, PSK) is readable there.")
    print("")
    print("Security Check Required")
    write("Password: ")
    local confirmed = authenticate(actor.name, readSecret())
    if not confirmed then
        print("Incorrect password.")
        appendLog("CONSOLE_SHELL_DENIED user=" .. tostring(actor.name)
            .. " role=" .. tostring(actor.role) .. " reason=bad_password")
        os.sleep(ACCESS_DENIED_DELAY)
        return false
    end
    if not rolePolicy.allows(confirmed.role, "root") then
        print("Access denied.")
        appendLog("CONSOLE_SHELL_DENIED user=" .. tostring(actor.name)
            .. " role=" .. tostring(confirmed.role) .. " reason=not_root")
        os.sleep(ACCESS_DENIED_DELAY)
        return false
    end
    appendLog("CONSOLE_EXIT_TO_SHELL user=" .. tostring(confirmed.name)
        .. " role=" .. tostring(confirmed.role))
    _G[CONSOLE_EXIT_FLAG] = true
    print("")
    print("[OK] Dropping to the CraftOS shell. Auth service stopped.")
    return true
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
        print("6. Exit to Shell")
        print("0. Log Out")
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
        elseif choice == "6" then
            if exitToShellFlow(actor) then return end
        elseif choice == "0" then
            return
        end
    end
end

local function main()
    userManager = loadLibrary(USER_MANAGER_PATH)
    terminalKeys = loadLibrary(TERMINAL_KEYS_PATH)
    rolePolicy = loadLibrary(ROLE_POLICY_PATH)
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
