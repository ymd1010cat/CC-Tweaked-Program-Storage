if ccemux and ccemux.openEmu then
    for _, id in ipairs({21, 22, 23, 24}) do
        ccemux.openEmu(id)
        os.sleep(0.8)
    end
end
os.sleep(1.5)
local fn = loadfile("ender-bridge.lua")
if fn then return fn() end
print("bridge program missing")
