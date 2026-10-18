--[[- tests/startup.lua — offline runner entry point.

Staged as startup.lua on a computer that has ONLY rpv/, tests/ and tools/ (no apps,
no role.txt, no modems): running the offline suite needs no network and no second
computer, and takes a couple of seconds.
]]
local ok, err = pcall(dofile, "tests/run.lua")
if not ok then
    print("OFFLINE_CRASH " .. tostring(err))
    print("OFFLINE_RESULT pass=0 fail=1 groups=0")
    print("TEST_DONE")
end
