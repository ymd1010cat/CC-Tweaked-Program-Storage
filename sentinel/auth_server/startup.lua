-- startup.lua -- Sentinel auth server boot entry.
-- Deploy path: /startup.lua
--
-- The service and the root console share this computer and its screen:
-- runService never returns while the machine is healthy, runConsole is
-- restarted after it ends. waitForAny therefore only returns when the whole
-- startup should end.

-- Keep the real os.pullEvent: a root operator may hand this computer back to the
-- CraftOS shell, and there Ctrl+T must work again.
local nativePullEvent = os.pullEvent

-- Ignore Ctrl+T process-wide before anything else runs. os.sleep, os.run and
-- every os.pullEvent call look up the current value of os.pullEvent, so
-- swapping it for the raw variant here makes a server "terminate" input an
-- ordinary, discarded event everywhere on this machine. A stray Ctrl+T can
-- never kill the service, the console, the parallel framework or os.run.
os.pullEvent = os.pullEventRaw

local SERVICE = "/system/auth_server.lua"
local CONSOLE = "/system/user_admin.lua"
local CONSOLE_RESTART_DELAY = 1

-- Set by /system/user_admin.lua, and only by a root operator. The console runs
-- inside os.run({}, ...), whose environment keeps its own writes, so it assigns
-- _G.SENTINEL_CONSOLE_EXIT explicitly.
local CONSOLE_EXIT_FLAG = "SENTINEL_CONSOLE_EXIT"

-- Last-resort lock. Reached only when the service itself has ended; keeps the
-- machine out of the CraftOS shell forever. os.pullEventRaw drains Ctrl+T so
-- nothing can ever exit this loop. Declared before the users below so they bind
-- this local instead of a nil global.
local function runConsoleLock()
    while true do
        os.pullEventRaw()
    end
end

local function runService()
    os.run({}, SERVICE)
    -- The service is expected to run forever. If it ever returns (it errored,
    -- say), lock the machine to a black screen instead of falling back to a
    -- CraftOS shell, where the whole server key store would be readable. A root
    -- operator asking for a shell is handled in runConsole instead.
    runConsoleLock()
end

local function runConsole()
    while true do
        os.run({}, CONSOLE)
        if _G[CONSOLE_EXIT_FLAG] then
            _G[CONSOLE_EXIT_FLAG] = nil
            -- Returning here ends parallel.waitForAny, so this startup file
            -- finishes and the CraftOS shell takes over. Give the shell its
            -- Ctrl+T back first: the swap above only exists to keep the auth
            -- service alive and must not follow us to a prompt.
            os.pullEvent = nativePullEvent
            return
        end
        os.sleep(CONSOLE_RESTART_DELAY)
    end
end

parallel.waitForAny(runService, runConsole)
