-- CardKey terminal login screen: read one code and have the server verify it.
-- Deploy path: /auth/cardkey_login.lua

local client = dofile("/auth/cardkey_client.lua")

local M = {}

-- login() -> {name = "cardkey", code, uses_left} | nil
function M.login()
    term.clear()
    term.setCursorPos(1, 1)
    print("Secure Terminal")
    print("")
    print("Enter your card key.")
    print("")
    write("Card key: ")
    local code = read()
    print("Checking...")

    local ok, info = client.check(code)
    if not ok then
        print("")
        print("[Error] " .. tostring(info))
        sleep(2)
        return nil
    end

    print("")
    print("[OK] Card key accepted.")
    if info and info.uses_left ~= nil then
        print("Uses left on this key: " .. tostring(info.uses_left))
    end
    sleep(1)
    return {
        name = "cardkey",
        code = code,
        uses_left = info and info.uses_left or nil,
    }
end

return M
