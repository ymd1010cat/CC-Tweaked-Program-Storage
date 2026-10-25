-- tests/startup.lua -- offline runner entry point.
--
-- Staged as /startup.lua on a headless CraftOS-PC computer that holds the
-- Sentinel deploy layout plus tests/. No real modems, redstone or second
-- computer are involved: tests/run.lua installs fakes and drives the modules.

local ok, err = pcall(dofile, "/tests/run.lua")
if not ok then
    print("OFFLINE_CRASH " .. tostring(err))
    print("OFFLINE_PASS 0")
    print("OFFLINE_FAIL 1")
    print("OFFLINE_GROUPS 0")
    print("TEST_DONE")
end
