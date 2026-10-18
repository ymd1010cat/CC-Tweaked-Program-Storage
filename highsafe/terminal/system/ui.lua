-- HighSafe terminal menu (loaded and called by the kernel).
-- Deploy: /system/ui.lua
-- Signature: ui(token, session, sandbox, auth)

local token, session, sandbox, auth = ...

local function loadUserManager()
    local ok, chunk = pcall(loadfile, "/auth/user_manager.lua")
    if not ok or type(chunk) ~= "function" then return nil end
    local okRun, module = pcall(chunk)
    if okRun and type(module) == "table" then return module end
    return nil
end

local function showHeader(user)
    term.clear()
    term.setCursorPos(1, 1)
    print("Secure System")
    print("User: " .. tostring(user.name) .. " (" .. tostring(user.role) .. ")")
    print("")
end

local function prompt(text)
    write(text)
    return read()
end

local function buildMenu(user)
    local items = { { id = "vault", label = "Open Vault" } }
    local manager = nil
    if user.role == "root" then
        manager = loadUserManager()
        if manager then
            items[#items + 1] = { id = "add", label = "Add User" }
            items[#items + 1] = { id = "delete", label = "Delete User" }
            items[#items + 1] = { id = "role", label = "Change Role" }
        end
        items[#items + 1] = { id = "exit", label = "Exit to CraftOS" }
    end
    items[#items + 1] = { id = "logout", label = "Logout" }
    return items, manager
end

local function renderMenu(user, items)
    showHeader(user)
    for index, item in ipairs(items) do
        print(index .. ". " .. item.label)
    end
    print("0. Logout (shortcut)")
    print("")
    write("Select an option: ")
end

-- One-second pulse on the left side, then the session ends.
local function openVault()
    print("Opening Vault...")
    redstone.setOutput("left", 1)
    sleep(1)
    redstone.setOutput("left", 0)
    return "break"
end

-- Two-stage exit: write the anti flag, drop the sandbox, reboot. The next boot
-- sees anti=1 and rewrites it as anti=2, falling through to the CraftOS shell.
local function exitToCraftOS(user)
    print("Security Check Required")
    write("Enter password: ")
    local password = read("*")

    local verified = false
    if type(password) == "string" and password ~= "" then
        verified = auth.verifyPassword(user.name, password) == true
    end
    if not verified then
        print("Incorrect password.")
        sleep(2)
        return nil
    end

    print("Password correct. Exiting to CraftOS...")
    local handle = fs.open("/anti.txt", "w")
    if handle then
        handle.write("anti=1")
        handle.close()
    end
    sleep(1)
    sandbox.restore()
    os.reboot()
    return "break"
end

local function promptRole()
    local role = prompt("Role (admin/operator/guest): ")
    if role == nil or role == "" then return "guest" end
    if role == "admin" or role == "operator" or role == "guest" then
        return role
    end
    print("[Error] Invalid role: " .. tostring(role))
    print("Allowed: admin, operator, guest")
    if role == "root" then
        print("Root accounts cannot be created through UI.")
    end
    return nil
end

local function doAddUser(manager)
    print("=== Add User ===")
    local name = prompt("Username: ")
    if name == nil or name == "" then
        print("[Error] Name cannot be empty.")
        return
    end
    write("Password: ")
    local password = read("*")
    if password == nil or password == "" then
        print("[Error] Password cannot be empty.")
        return
    end
    local role = promptRole()
    if not role then return end

    local ok, message = manager.addUser(name, password, role)
    if ok then
        print("[OK] " .. tostring(message))
    else
        print("[Error] " .. tostring(message))
    end
end

local function doDeleteUser(manager, requester)
    print("=== Delete User ===")
    local name = prompt("Username: ")
    if name == nil or name == "" then
        print("[Error] Name cannot be empty.")
        return
    end
    local answer = prompt("Confirm delete '" .. name .. "'? (yes/no): ")
    if answer ~= "yes" then return end

    local ok, message = manager.deleteUser(name, requester)
    if ok then
        print("[OK] " .. tostring(message))
    else
        print("[Error] " .. tostring(message))
    end
end

local function doChangeRole(manager, requester)
    print("=== Change Role ===")
    local name = prompt("Username: ")
    if name == nil or name == "" then
        print("[Error] Name cannot be empty.")
        return
    end
    local role = promptRole()
    if not role then return end

    local ok, message = manager.changeRole(name, role, requester)
    if ok then
        print("[OK] " .. tostring(message))
    else
        print("[Error] " .. tostring(message))
    end
end

local function runSubmenu(id, manager, user)
    if not manager then return end
    if id == "add" then
        doAddUser(manager)
    elseif id == "delete" then
        doDeleteUser(manager, user.name)
    elseif id == "role" then
        doChangeRole(manager, user.name)
    end
    print("Press Enter to return...")
    read()
end

while true do
    local user = session.validate(token)
    if not user then return end

    local items, manager = buildMenu(user)
    renderMenu(user, items)
    local choice = tonumber(read())

    if choice == 0 then
        return
    end

    local item = nil
    if choice then item = items[choice] end

    if item then
        local result = nil
        if item.id == "vault" then
            result = openVault()
        elseif item.id == "exit" then
            result = exitToCraftOS(user)
        elseif item.id == "logout" then
            return "break"
        else
            runSubmenu(item.id, manager, user)
        end
        if result == "break" then return "break" end
        sleep(0.5)
    end
end
