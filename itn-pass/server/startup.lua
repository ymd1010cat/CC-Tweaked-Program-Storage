-- startup.lua -- ITN-Pass station boot: service coroutine plus admin console.
-- Deploy as /startup.lua on the station.
--
-- The service runs in its own coroutine and writes only to its log file. The
-- admin console owns the terminal; when it exits it is started again after a
-- short breath so the password prompt always comes back.

local function runServer()
    local ok, err = pcall(os.run, {}, "/system/itnpass_server.lua")
    -- The service only returns when it could not boot (bad modem wiring) or
    -- when it crashed. In both cases the console must stay alive so the player
    -- sees the fault flag; park instead of dropping to the CraftOS shell.
    if not ok or fs.exists("/auth/itnpass_fault.flag") then
        while true do
            os.pullEvent("terminate")
        end
    end
end

local function runAdmin()
    while true do
        local ok, err = pcall(os.run, {}, "/system/itnpass_admin.lua")
        if not ok then
            print("[ERROR] " .. tostring(err))
            os.sleep(2)
        end
        os.sleep(1)
    end
end

parallel.waitForAny(runServer, runAdmin)
