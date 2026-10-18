-- sysinfo.lua - data sources for the system monitoring builtins
-- Everything here is derived from APIs that really exist on CC:Tweaked /
-- CraftOS-PC. Where a Unix notion has no counterpart on CraftOS the caller is
-- told what the data actually is, instead of inventing a number.
--
--   df     -> fs.getCapacity / fs.getFreeSpace per real filesystem
--   free   -> the same storage numbers plus the Lua heap size
--             (collectgarbage("count"), kB) and computer facts
--   ps     -> multishell tabs + ush internal jobs (see jobs.lua); CraftOS has
--             no kernel process table
--   uptime -> os.clock(), the seconds elapsed since the computer booted
--   top    -> repeated sampling of the above
local sysinfo = {}

-- Filesystem candidates, in the order they are shown by df.
local FS_CANDIDATES = { "/", "/rom", "/disk", "/disk0", "/disk1", "/disk2", "/disk3" }

local function safe_call(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
end

function sysinfo.capacity(path)
    return (safe_call(fs.getCapacity, path))
end

function sysinfo.free_space(path)
    return (safe_call(fs.getFreeSpace, path))
end

-- Every real filesystem, mapped onto the mount point the user knows about.
-- Mounts registered in the mount table are reported under their logical
-- target so that df agrees with the mount(8) output.
function sysinfo.filesystems()
    local mounts = require("mounts")
local rpvnet  = require("rpvnet")
    local out, seen = {}, {}

    local function add(mount, probe, kind, entry)
        if not fs.exists(probe) or not fs.isDir(probe) then return end
        if seen[probe] then return end
        local cap = sysinfo.capacity(probe)
        if not cap or cap <= 0 then return end
        seen[probe] = true
        local free = sysinfo.free_space(probe) or 0
        if free > cap then free = cap end
        out[#out + 1] = {
            mount = mount, probe = probe, kind = kind,
            capacity = cap, free = free, used = cap - free,
            readonly = entry ~= nil and mounts.opt_set(entry.opts).ro == true,
        }
    end

    for _, p in ipairs(FS_CANDIDATES) do
        local kind = "hdd"
        if p == "/rom" then kind = "rom"
        elseif p ~= "/" then kind = "floppy" end
        add(p, p, kind)
    end

    for _, e in ipairs(mounts.list()) do
        if not seen[e.source] then
            add(e.target, e.source, "mount", e)
        end
    end

    return out
end

-- Storage totals used by free(1).
function sysinfo.storage_total()
    local total, free = 0, 0
    for _, f in ipairs(sysinfo.filesystems()) do
        total = total + f.capacity
        free = free + f.free
    end
    return total, free, total - free
end

-- Lua heap usage in bytes. collectgarbage("count") is part of standard Lua and
-- is available on both Cobalt and LuaJIT, but it is wrapped defensively.
function sysinfo.heap_bytes()
    local kb = safe_call(collectgarbage, "count")
    if type(kb) ~= "number" then return nil end
    return math.floor(kb * 1024)
end

function sysinfo.uptime_seconds()
    local c = os.clock()
    if type(c) ~= "number" then return 0 end
    return c
end

-- Estimated boot time: os.clock() counts from boot, os.epoch("utc") gives the
-- real clock, so the difference is the moment the computer started.
function sysinfo.boot_epoch_ms()
    local epoch = safe_call(os.epoch, "utc")
    if type(epoch) ~= "number" then return nil end
    return epoch - sysinfo.uptime_seconds() * 1000
end

function sysinfo.computer()
    return {
        id = os.getComputerID(),
        label = os.getComputerLabel() or ("cc-" .. tostring(os.getComputerID())),
        version = select(1, safe_call(os.version)) or "CraftOS",
        host = type(_G._HOST) == "string" and _G._HOST or "CC:Tweaked",
    }
end

-- CraftOS task view. Data sources, in order of reliability:
--   1. multishell tabs, when the CraftOS shell runs with multiple tabs;
--   2. the os.pullEvent loop that is currently blocked;
--   3. ush internal jobs (jobs.lua) which are owned by the shell itself.
function sysinfo.tasks()
    local out = {}

    local count = select(1, safe_call(function()
        if multishell and multishell.getCount then return multishell.getCount() end
        return 0
    end))
    count = tonumber(count) or 0
    local focus = select(1, safe_call(function()
        if multishell and multishell.getFocus then return multishell.getFocus() end
        return nil
    end))

    for i = 1, count do
        local title = safe_call(function()
            return multishell.getTitle(i)
        end)
        out[#out + 1] = {
            pid = i,
            kind = "multishell",
            command = tostring(title or ("tab " .. i)),
            state = (focus == i) and "running" or "waiting",
        }
    end

    out[#out + 1] = {
        pid = 0,
        kind = "ush",
        command = "ush (interactive shell)",
        state = "running",
    }

    local ok, jobs = pcall(require, "jobs")
    if ok and jobs and jobs.list then
        for _, j in ipairs(jobs.list()) do
            out[#out + 1] = {
                pid = 1000 + j.id,
                kind = "job",
                command = j.command,
                state = j.state,
                started = j.started,
            }
        end
    end

    return out
end

-- Modems and rednet state, shared by netstat(1) and ping(1).
function sysinfo.network()
    local out = {}
    local names = safe_call(peripheral.getNames) or {}
    for _, name in ipairs(names) do
        local is_modem = safe_call(peripheral.hasType, name, "modem")
        if is_modem then
            local wireless = safe_call(peripheral.call, name, "isWireless")
            local open = false
            local ok, rednet = pcall(require, "rednet")
            if ok then
                open = rpvnet.isOpen(name) and true or false
            end
            out[#out + 1] = {
                side = name,
                wireless = wireless and true or false,
                open = open,
            }
        end
    end
    return out
end

-- Total number of entries of the whole filesystem, used by free(1) as a cheap
-- "inode" style figure.
function sysinfo.entry_count(root)
    local n = 0
    local function walk(p)
        local list = safe_call(fs.list, p) or {}
        for _, name in ipairs(list) do
            local full = (p == "/" and "/" or p .. "/") .. name
            n = n + 1
            if safe_call(fs.isDir, full) then walk(full) end
        end
    end
    walk(root or "/")
    return n
end

return sysinfo
