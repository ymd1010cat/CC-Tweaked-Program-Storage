-- startup.lua - boot script for the pylib offline suite.
--
-- Staged to /startup.lua on a throwaway headless CraftOS-PC computer. All the
-- work happens in /tests/run.lua; this keeps a crash outside that file (for
-- example a syntax error) from leaving the runner hanging: the marker still
-- reaches /logs/suite.log and the computer still shuts down.

local ok, err = pcall(dofile, "/tests/run.lua")
if not ok then
    if not fs.exists("/logs") then pcall(fs.makeDir, "/logs") end
    local f = fs.open("/logs/suite.log", "a")
    if f then
        f.writeLine("PYLIB_CRASH run.lua: " .. tostring(err))
        f.writeLine("PYLIB_FAIL 1")
        f.writeLine("PYLIB_DONE")
        f.close()
    end
    pcall(os.shutdown)
end
