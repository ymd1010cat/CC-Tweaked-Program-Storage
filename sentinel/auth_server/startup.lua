-- startup.lua -- Sentinel auth server boot entry.
-- Deploy path: /startup.lua
--
-- The service and the root console share this computer and its screen:
-- runService never returns while the machine is healthy, runConsole is
-- restarted after it ends. waitForAny therefore only returns when the whole
-- startup should end.

local SERVICE = "/system/auth_server.lua"
local CONSOLE = "/system/user_admin.lua"
local CONSOLE_RESTART_DELAY = 1

local function runService()
    os.run({}, SERVICE)
end

local function runConsole()
    while true do
        os.run({}, CONSOLE)
        os.sleep(CONSOLE_RESTART_DELAY)
    end
end

parallel.waitForAny(runService, runConsole)
