-- ITN-Pass terminal boot: lock the machine, prove the network, start the kernel.
-- Deploy path: /startup.lua (terminal).

local sandboxOk, sandbox = pcall(dofile, "/system/sandbox.lua")
if not sandboxOk or type(sandbox) ~= "table" then
    print("FATAL: cannot load sandbox")
    while true do
        os.pullEventRaw()
    end
end

sandbox.lockEvents()

local netcheck = dofile("/system/netcheck.lua")
local ok, ids, reason = netcheck.check(3)
if not ok then
    local flag = fs.open("/auth/itnpass_lock.flag", "w")
    if flag then
        flag.write(tostring(reason or "network check failed"))
        flag.close()
    end
    term.clear()
    term.setCursorPos(1, 1)
    print("NETWORK SECURITY CHECK FAILED")
    print("Reason: " .. tostring(reason or "unknown"))
    print("Fix the network and reboot.")
    while true do
        os.pullEventRaw()
    end
end

if fs.exists("/auth/itnpass_lock.flag") then
    fs.delete("/auth/itnpass_lock.flag")
end

os.run({}, "/system/kernel.lua")
