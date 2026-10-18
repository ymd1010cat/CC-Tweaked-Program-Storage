-- boot.lua - boot identity for ush
--
-- CraftOS has no init process and no boot counter, so "this boot" is derived
-- from the wall clock instant the computer was switched on:
--
--     boot id = os.epoch("utc") - os.clock()
--
-- os.clock() counts seconds since the machine started, os.epoch("utc") is the
-- current absolute time, so the difference is stable for as long as the
-- computer keeps running and changes on the next boot.
--
-- One shot boot hooks (the /etc/rc.d runner, @reboot crontab entries) key
-- their "once per boot" logic on a marker file: the marker written by an
-- earlier boot holds a different instant, so the hook runs again, while a
-- marker written by the same boot is recognised even though os.clock() keeps
-- moving forward.
local boot = {}

local TOLERANCE = 60    -- seconds of drift tolerated inside one boot

local function now_epoch()
    local ok, e = pcall(os.epoch, "utc")
    if ok and type(e) == "number" then return e / 1000 end
    return os.time()
end

local function ensure_dir(path)
    if fs.exists(path) then return true end
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
    return fs.exists(path)
end

-- The instant this computer was switched on, in Unix seconds.
function boot.epoch()
    return math.floor(now_epoch() - (os.clock() or 0))
end

function boot.id()
    return tostring(boot.epoch())
end

-- Boot id stored in a marker file, or nil when the file is missing or does not
-- hold a plain number.
function boot.marker(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local line = f.readLine()
    f.close()
    if line == nil then return nil end
    return line:match("^%s*(%-?%d+)")
end

function boot.write_marker(path, id)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then ensure_dir(dir) end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(tostring(id) .. "\n")
    f.close()
    return true
end

-- True when this is the first call of the current boot for this marker, in
-- which case the marker is written so that later calls (including calls from
-- another process, for example the watchdog after the shell was restarted)
-- report false.
function boot.begin(path)
    local id = boot.epoch()
    local last = boot.marker(path)
    if last then
        local n = tonumber(last)
        if n and math.abs(n - id) <= TOLERANCE then return false, id end
    end
    boot.write_marker(path, id)
    return true, id
end

-- True when the marker belongs to the boot that is still running.
function boot.same_boot(path)
    local last = boot.marker(path)
    if not last then return false end
    local n = tonumber(last)
    if not n then return false end
    return math.abs(n - boot.epoch()) <= TOLERANCE
end

return boot
