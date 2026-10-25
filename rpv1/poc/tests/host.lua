--[[- tests/host.lua — minimal `fs` shim so the offline suite can run under desktop Lua.

CraftOS-PC is not required for the unit tests: the library modules and the test
suite only touch fs/os/string/table/bit32. On a machine with plain Lua 5.1:

    lua -e 'dofile("tests/host.lua")' tests/run.lua

Linux/macOS: sh = "sh" ; Windows: sh = "cmd" (io.popen is used for directory lists).
The paths are relative to the poc/ directory, exactly like the emulator staging.
]]
if fs and fs.open then return end   -- a real CC host already provides fs

local sep = package.config:sub(1, 1)
local sh = (sep == "\\") and "cmd /c dir /b " or "ls "

local H = {}

function H.open(path, mode)
    local f = io.open(path, mode == "r" and "rb" or "wb")
    if not f then return nil end
    return {
        readLine = function(self) local l = f:read("*l"); return l end,
        readAll = function(self) local s = f:read("*a"); return s or "" end,
        writeLine = function(self, s) f:write(s, "\n") end,
        write = function(self, s) f:write(s) end,
        close = function(self) f:close() end,
        flush = function(self) f:flush() end,
    }
end

function H.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function H.isDir(path)
    local f = io.open(path, "rb")
    if f then f:close() return false end
    return H.exists(path)
end

-- rename/delete are needed by apps/hosts.lua's atomic save. Windows os.rename
-- refuses to overwrite, exactly like the CC fs.move, so the module's move-aside
-- fallback exercises the same code path here.
function H.move(from, to)
    local ok, err = os.rename(from, to)
    if ok then return true end
    return false, err
end

function H.delete(path)
    local ok, err = os.remove(path)
    if ok then return true end
    return false, err
end

function H.list(path)
    local out = {}
    local cmd = sh .. path .. (sep == "\\" and "" or " 2>/dev/null")
    local p = io.popen(cmd)
    if not p then return out end
    for line in p:lines() do
        if line ~= "" and line ~= "." and line ~= ".." then out[#out + 1] = line end
    end
    p:close()
    return out
end

function H.attributes(path)
    local f = io.open(path, "rb")
    if not f then error("No file") end
    local size = f:seek("end")
    f:close()
    return { size = size, modification = os.time() }
end

fs = H
print("HOST_SHIM active (desktop Lua)")

-- CraftOS prints return values from the chunk, so emulate that bit of run.lua's entry
if not os.getComputerID then os.getComputerID = function() return 20 end end
if not os.epoch then os.epoch = function() return math.floor(os.time() * 1000) end end
if not os.version then os.version = function() return "desktop-lua" end end
if not bit32 and bit then bit32 = bit end
