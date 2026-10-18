-- HighSafe terminal boot: sandbox, network presence check, anti-fallthrough flag.
-- Deploy: /startup.lua

local okSandbox, sandbox = pcall(dofile, "/system/sandbox.lua")
if not okSandbox or type(sandbox) ~= "table"
    or type(sandbox.lockEvents) ~= "function" then
    print("FATAL: cannot load sandbox")
    while true do sleep(100) end
end

sandbox.lockEvents()

local function halt()
    while true do sleep(100) end
end

local function writeFile(path, content)
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(content)
    handle.close()
    return true
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local content = handle.readAll()
    handle.close()
    return content
end

local function safeLoad(path)
    local ok, value = pcall(dofile, path)
    if ok and type(value) == "table" then return value end
    return nil
end

local modeConfig = safeLoad("/auth/mode.lua") or { mode = "client" }
local mode = modeConfig.mode or "client"

if mode == "client" then
    local netcheck = safeLoad("/system/netcheck.lua")
    if not netcheck or type(netcheck.check) ~= "function" then
        writeFile("/lock.flag", "cannot load netcheck")
        print("NETWORK SECURITY CHECK FAILED")
        print("Reason: cannot load netcheck")
        print("")
        print("Fix the network and reboot.")
        halt()
    end

    local called, passed, ids, reason = pcall(netcheck.check, 3)
    if not called then
        passed = false
        reason = "check interrupted"
    end
    if not passed then
        if type(reason) ~= "string" or reason == "" then
            reason = "check interrupted"
        end
        writeFile("/lock.flag", reason)
        print("NETWORK SECURITY CHECK FAILED")
        print("Reason: " .. reason)
        print("")
        print("Fix the network and reboot.")
        halt()
    end

    -- Only a passing check may clear a previous lock.
    if fs.exists("/lock.flag") then
        fs.delete("/lock.flag")
    end
end

local anti = readFile("/anti.txt")
local antiState = nil
if anti then
    if anti:find("anti=1", 1, true) then
        antiState = 1
    elseif anti:find("anti=2", 1, true) then
        antiState = 2
    end
end

if antiState == 1 then
    -- Second boot after an Exit to CraftOS: leave a marker and stop here so the
    -- machine lands on the CraftOS shell.
    writeFile("/anti.txt", "anti=2")
    return
elseif antiState == 2 then
    if fs.exists("/anti.txt") then
        fs.delete("/anti.txt")
    end
end

os.run({}, "/system/kernel.lua")
