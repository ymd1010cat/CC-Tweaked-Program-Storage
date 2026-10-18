-- CardKey terminal kernel: lock the machine, then loop login -> menu -> logout.
-- Deploy path: /system/kernel.lua
-- Script, not a module: /startup.lua runs this through os.run({}, ...).

local sandbox = dofile("/system/sandbox.lua")
local auth = dofile("/auth/cardkey_login.lua")
local session = dofile("/auth/session.lua")

sandbox.init()

local function runSession()
    local user = auth.login()
    if not user then
        return
    end
    local token = session.create(user)
    if not token then
        error("cannot create session", 0)
    end
    local ok, err = pcall(function()
        local screen, loadErr = loadfile("/system/ui.lua")
        if not screen then
            error(loadErr or "cannot load /system/ui.lua", 0)
        end
        screen(token, session, sandbox, user)
    end)
    session.destroy(token)
    if not ok then
        error(err, 0)
    end
end

while true do
    local ok, err = pcall(runSession)
    if not ok then
        print("System error, returning to card key prompt...")
        print(tostring(err))
        sleep(2)
    end
    sleep(0.5)
end
