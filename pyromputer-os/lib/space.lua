-- space.lua - is there room for this write?
--
-- Every writer in this project that can put a large amount of data on a disk
-- asks this module before it truncates or creates anything: shell redirects,
-- cp, ln, sed -i, tee, tar, the package unpacker, the transfer receiver and
-- the editor's save. The point is not a statistic: a full disk used to leave a
-- file truncated to zero bytes (fs.open "w" succeeds, then the write fails), or
-- a half written download, with the previous contents gone. A refusal that says
-- what is missing is the smaller harm.
--
-- THE CRITERION: a write is refused when the bytes it puts on the disk are
-- GREATER than the free space reported for the target filesystem. Equal is
-- allowed -- a file that exactly fills the disk is a file that fits.
--
-- NO API, NO REFUSAL. fs.getFreeSpace is not in every CraftOS build and can be
-- taken away from the table by a program, and a machine that cannot answer the
-- question must not be turned read-only: a false refusal breaks writes that
-- would have worked, which is worse than the truncation this check exists to
-- avoid. free() therefore answers nil and need() answers true, and the caller
-- carries on exactly as before this module existed.
--
-- THE NUMBERS ARE BYTES, AND THE ARGUMENT IS A PATH. Measured on CraftOS-PC
-- 2.8.3 (2026-10-17, probe script run with --headless --script): fs.getFreeSpace
-- exists, takes a
-- directory, a file, a path that does not exist, or "", and answers the free
-- space of the volume that path lives on, in bytes -- 224410443776 for the
-- emulator's host disk, 0 for /rom. It is not KiB and it is not per directory.
-- On a real CraftOS computer it answers for the computer's own disk, which is
-- the number a two-part install has to live inside.
--
-- WHAT THIS CANNOT DO: it is a preflight, not a reservation. Between the answer
-- and the write another program can take the space (CraftOS has no way to hold
-- it), so a write may still fail after a positive answer. It narrows the window;
-- it does not close it. It also cannot know the size of a write it is not told
-- about: a redirect is opened before its command has produced a byte, so the
-- only honest test there is "the filesystem is not already full" (1 byte).
local space = {}

-- Bytes free on the filesystem that holds "path", or nil when this platform
-- cannot answer. An unreadable or impossible answer is nil, never 0: 0 means a
-- full disk and would refuse every write on a machine that simply has no API.
function space.free(path)
    if type(path) ~= "string" or path == "" then path = "/" end
    if type(fs) ~= "table" or type(fs.getFreeSpace) ~= "function" then return nil end

    local function ask(probe)
        local ok, value = pcall(fs.getFreeSpace, probe)
        if not ok or type(value) ~= "number" then return nil end
        if value ~= value or value < 0 then return nil end     -- NaN or nonsense
        return math.floor(value)
    end

    local value = ask(path)
    if value ~= nil then return value end

    -- A filesystem may answer nil for a path that does not exist yet (the test
    -- stub does; the emulator answers for the volume anyway). A file about to be
    -- created lives on the volume of its nearest existing parent, so asking that
    -- is the same question -- and skipping it would silently allow the write on
    -- exactly the implementations that are strict about the argument.
    local probe = path
    for _ = 1, 64 do
        local parent = probe:match("^(.*)/[^/]*$")
        if parent == nil then break end
        if parent == "" then parent = "/" end
        if parent == probe then break end
        probe = parent
        local exists = nil
        if type(fs.exists) == "function" then
            local ok_e, yes = pcall(fs.exists, probe)
            if not ok_e then break end
            exists = yes
        end
        if exists then
            value = ask(probe)
            if value ~= nil then return value end
        end
    end
    return nil
end

-- The one sentence a refusal prints. Short, one line, ASCII: it travels through
-- the shell's own emit(), a peer's result message and an editor status line.
-- A byte count as text, for the one sentence a refusal prints. NOT %d: on the
-- real machine (CraftOS-PC 2.8.3) string.format("%d", 224476971009) RAISES
-- "bad argument #2 (not a number in proper range)", because %d is the C integer
-- conversion and a free space measured in bytes does not fit it. The PC suite
-- never saw it -- every number there is small -- and the probe crashed on the
-- first big one. "%.0f" takes the double Lua actually stores, is exact for every
-- byte count a disk can hold (below 2^53), and never raises.
local function count(n)
    if type(n) ~= "number" then return tostring(n) end
    return string.format("%.0f", n)
end
space.count = count

function space.reason(need, free)
    return "not enough space: need " .. count(need) .. " bytes, " .. count(free) .. " free"
end

-- ok, reason. "bytes" is what the caller is about to write; a size it does not
-- know (nil) or nothing at all (0) is allowed, because there is nothing to
-- measure and guessing a refusal would break writes that would have worked.
function space.need(path, bytes)
    local want = tonumber(bytes)
    if not want or want <= 0 then return true end
    want = math.ceil(want)
    local free = space.free(path)
    if free == nil then return true end
    if want > free then return false, space.reason(want, free) end
    return true
end

-- The check for a copy that writes MANY files under one destination: "bytes" is
-- the total the caller accumulated with size(). The question is the same one and
-- so is the answer -- the name exists to say that the number is a whole tree's,
-- because a per-file check alone lets a tree of files that each fit fill the disk
-- and leave the last ones truncated.
--
-- A copy that overwrites existing files is counted at its FULL size. That is
-- conservative: it can refuse a copy that would have fitted because the old
-- bytes were about to be freed. Refusing is recoverable, half a tree is not, and
-- the alternative -- knowing which destination files will be replaced -- is a
-- model of the copy this module does not have.
function space.need_tree(dest, bytes)
    return space.need(dest, bytes)
end

-- Total bytes of a file, or of every file below a directory, for the callers
-- that accumulate a tree before asking. nil when the size cannot be measured
-- (no filesystem API, a listing that fails, a path too deep to trust): the
-- caller then skips the check rather than refusing on a guess.
local MAX_DEPTH = 32

function space.size(path, depth)
    depth = depth or 0
    if type(path) ~= "string" or path == "" then return nil end
    if depth > MAX_DEPTH then return nil end
    if type(fs) ~= "table" then return nil end

    local ok_dir, is_dir = pcall(fs.isDir, path)
    if not ok_dir then return nil end
    if is_dir then
        local ok_list, names = pcall(fs.list, path)
        if not ok_list or type(names) ~= "table" then return nil end
        local total = 0
        for _, name in ipairs(names) do
            local part = space.size(path .. "/" .. name, depth + 1)
            if part == nil then return nil end
            total = total + part
        end
        return total
    end

    local ok_size, size = pcall(fs.getSize, path)
    if not ok_size or type(size) ~= "number" or size < 0 then return nil end
    return size
end

return space
