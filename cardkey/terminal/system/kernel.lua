-- CardKey terminal kernel: lock the machine, then loop login -> menu -> logout.
-- Deploy path: /system/kernel.lua
-- Script, not a module: /startup.lua runs this through os.run({}, ...).
--
-- Run mode comes from /cardkey_mode.lua (mode file first, then
-- /auth/cardkey_config.lua, then "pass"). In "free" mode there is no card key
-- prompt: the kernel hands the menu a synthetic guest user and logs
-- FREE_SESSION. A terminal without /cardkey_mode.lua boots as "pass", exactly
-- as it did before the free mode existed -- the resolver is optional here.
-- The network check still runs in /startup.lua, because the disk is written by
-- the server and the terminal must still reach it.

local sandbox = dofile("/system/sandbox.lua")
local auth = dofile("/auth/cardkey_login.lua")
local session = dofile("/auth/session.lua")

sandbox.init()

-- Optional resolver: a missing or broken /cardkey_mode.lua keeps the paid mode.
local okMode, modeModule = pcall(dofile, "/cardkey_mode.lua")
if not okMode or type(modeModule) ~= "table" then
    modeModule = nil
end
local MODE = "pass"
if modeModule ~= nil then
    local okCurrent, value = pcall(modeModule.current)
    if okCurrent and modeModule.is_valid(value) then
        MODE = value
    end
end
local FREE = MODE == "free"

-- Synthetic identity for the open mode: no card key, no use counter. The menu
-- checks "free" so it can word its result screen without a card key story.
local function guestUser()
    if modeModule ~= nil then
        modeModule.log("FREE_SESSION id=" .. tostring(os.getComputerID()))
    end
    return {
        name = "guest",
        code = "",
        uses_left = nil,
        free = true,
    }
end

local function runSession()
    local user
    if FREE then
        user = guestUser()
    else
        user = auth.login()
    end
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
        if FREE then
            print("System error, returning to the menu...")
        else
            print("System error, returning to card key prompt...")
        end
        print(tostring(err))
        sleep(2)
    end
    sleep(0.5)
end
