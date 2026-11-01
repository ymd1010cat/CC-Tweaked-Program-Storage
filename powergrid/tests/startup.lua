-- startup.lua - boot script for the powergrid offline suite.
--
-- Staged to /startup.lua on a throwaway headless CraftOS-PC computer. All the
-- work happens in /tests/run.lua; a crash outside that file (a syntax error,
-- for example) still leaves a marker in /logs/suite.log and still shuts the
-- computer down, so the ps1 runner can never hang until its timeout.

local ok, err = pcall(dofile, "/tests/run.lua")
if not ok then
    if not fs.exists("/logs") then pcall(fs.makeDir, "/logs") end
    local f = fs.open("/logs/suite.log", "a")
    if f then
        f.writeLine("OFFLINE_CRASH run.lua: " .. tostring(err))
        f.writeLine("OFFLINE_FAIL 1")
        f.writeLine("TEST_DONE")
        f.close()
    end
    pcall(os.shutdown)
end
