-- tests/startup.lua -- offline runner entry point.
--
-- Staged as /startup.lua on a headless CraftOS-PC computer that holds the
-- itn-pass deploy layout plus tests/. No real modems, drive peripherals or
-- second computer are involved: tests/run.lua installs the fakes.
--
-- Output goes through term.write rather than print: the suite replaces the
-- global write() to capture module output, and BIOS print() calls write().
-- Everything is mirrored into /logs/suite.log because CraftOS-PC buffers
-- redirected stdout and the runner reads the log file for its verdict.

local function emit(text)
    local line = tostring(text)
    term.write(line .. "\n")
    local log = fs.open("/logs/suite.log", "a")
    if log then
        log.write(line .. "\n")
        log.close()
    end
end

local ok, err = pcall(dofile, "/tests/run.lua")
if not ok then
    emit("OFFLINE_CRASH " .. tostring(err))
    emit("OFFLINE_PASS 0")
    emit("OFFLINE_FAIL 1")
    emit("OFFLINE_GROUPS 0")
    emit("TEST_DONE")
    -- Let CraftOS-PC exit so the runner does not wait for its timeout.
    pcall(function()
        os.shutdown()
    end)
end
