-- startup.lua -- Sentinel audit server boot entry.
-- Deploy as /startup.lua on the audit server computer.
--
-- The audit server is one module: /system/audit_server.lua returns a table and
-- is started here. A load failure is fatal, exactly like a missing modem.

local ok, server = pcall(dofile, "/system/audit_server.lua")
if not ok or type(server) ~= "table" or type(server.main) ~= "function" then
    print("FATAL: cannot load /system/audit_server.lua")
    if not ok then
        print(tostring(server))
    end
    while true do
        os.sleep(100)
    end
end

server.main()
