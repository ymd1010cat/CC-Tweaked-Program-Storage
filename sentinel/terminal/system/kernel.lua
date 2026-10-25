-- Sentinel terminal kernel: login/menu cycle plus the audit queue.
-- Deploy: /system/kernel.lua

local sandbox = dofile("/system/sandbox.lua")
sandbox.init()

local auth = dofile("/auth/login.lua")
local session = dofile("/auth/session.lua")
local audit = dofile("/system/audit.lua")

local function mainLoop()
    while true do
        local ok, message = pcall(function()
            local user = auth.login()
            if user then
                local token = session.create(user)
                local okUi, uiError = pcall(function()
                    local ui = assert(loadfile("/system/ui.lua"))
                    ui(token, session, sandbox, auth)
                end)
                session.destroy(token)
                if not okUi then
                    error(uiError, 0)
                end
            end
        end)

        if not ok then
            print("System error, returning to login...")
            print(message)
            sleep(2)
        end
        sleep(0.5)
    end
end

-- The audit server is the only sink: a failed start (no modem, no PSK) is
-- retried on the same short interval.
local function auditLoop()
    while true do
        pcall(audit.start)
        sleep(5)
    end
end

parallel.waitForAny(mainLoop, auditLoop)
