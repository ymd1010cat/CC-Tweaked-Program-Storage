-- Sentinel terminal menu (loaded and called by the kernel).
-- Deploy: /system/ui.lua
-- Signature: ui(token, session, sandbox, auth)

local token, session, sandbox, auth = ...

local rolePolicy = dofile("/auth/role_policy.lua")

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

-- The terminal never manages accounts: users, roles and passwords live only in
-- the auth server's /auth/users.db and are changed from its root console. No
-- legacy branch keeps an Add/Delete/Change Role menu alive for old deployments.
local function buildMenu(user)
    local items = { { id = "vault", label = "Open Vault" } }
    if rolePolicy.allows(user.role, "root") then
        items[#items + 1] = { id = "exit", label = "Exit to CraftOS" }
    end
    items[#items + 1] = { id = "logout", label = "Logout" }
    return items
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

-- Modal alert: no separate window manager exists in CraftOS, so the alert is
-- drawn on the terminal and closed with Enter.
local function showAlert(heading, lines)
    term.clear()
    term.setCursorPos(1, 1)
    print("[!] " .. heading)
    for _, line in ipairs(lines) do
        print("")
        print(line)
    end
    print("")
    write("Press Enter to continue...")
    read()
end

-- The terminal has no door wiring: it asks the auth server, which owns the
-- actuator, and ends the session only when the server grants access.
--
-- A "denied" answer is not just a failed menu action: the server re-read the
-- account role and refused, so the local session may belong to a role that
-- has been revoked. The menu must not stay open with that stale identity, so
-- the token is destroyed and the kernel falls back to the login screen.
local function openVault(user, token)
    print("Requesting vault access from auth server...")
    local ok, reason, code = auth.requestOpen(user.name)
    if ok then
        print("[OK] Vault opened by auth server.")
        return "break"
    end
    if code == "denied" then
        showAlert("Permission denied", {
            "Your account no longer has vault access: the role is",
            "insufficient or an administrator revoked it.",
            "",
            "The local session will be closed and the login screen",
            "will be shown again.",
        })
        if type(session) == "table" and type(session.destroy) == "function" then
            pcall(session.destroy, token)
        end
        print("Session closed. Returning to login...")
        sleep(1)
        return "break"
    end
    if code == "network" then
        print("[Error] Auth server unreachable.")
    elseif code == "timeout" then
        print("[Error] Auth server did not answer.")
    else
        print("[Denied] " .. tostring(reason or "denied"))
    end
    print("")
    sleep(2)
    return nil
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

while true do
    local user = session.validate(token)
    if not user then return end

    local items = buildMenu(user)
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
            result = openVault(user, token)
        elseif item.id == "exit" then
            result = exitToCraftOS(user)
        elseif item.id == "logout" then
            return "break"
        end
        if result == "break" then return "break" end
        sleep(0.5)
    end
end
