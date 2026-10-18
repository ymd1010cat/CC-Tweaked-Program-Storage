-- disk_writer.lua -- copies the server payload to the one attached disk drive.
-- Deploy as /system/disk_writer.lua on the card key server.
--
-- M.write()   -> true, {drive, mount, files, dirs, bytes, free_after}
--             -> false, reason, detail
-- M.status()  -> {state, drives, drive?, mount?, free?}
--
-- The drive network must hold exactly one drive. Failure messages are the ones
-- the terminal and the admin console show, so they are spelled out verbatim.

local M = {}

local function cfg()
    local ok, t = pcall(dofile, "/auth/cardkey_config.lua")
    if ok and type(t) == "table" then
        return t
    end
    return {}
end

local function parentOf(path)
    local p = tostring(path):gsub("/+$", "")
    local cut = p:match("^.*()/")
    if not cut or cut == 1 then
        return "/"
    end
    return p:sub(1, cut - 1)
end

local function ensureDir(path)
    if path == nil or path == "" or path == "/" then
        return true
    end
    if fs.exists(path) then
        return fs.isDir(path)
    end
    if not ensureDir(parentOf(path)) then
        return false
    end
    local made = fs.makeDir(path)
    if made == nil then
        made = false
    end
    return made or (fs.exists(path) and fs.isDir(path))
end

local function readFile(path)
    local f = fs.open(path, "rb")
    if not f then
        return nil
    end
    local text = f.readAll()
    f.close()
    return text
end

local function joinPath(base, rel)
    local left = tostring(base)
    if left:sub(-1) ~= "/" then
        left = left .. "/"
    end
    return left .. tostring(rel)
end

local function scanDrives()
    local drives = {}
    local names = peripheral.getNames()
    if type(names) ~= "table" then
        return drives
    end
    for _, name in ipairs(names) do
        local ok, isDrive = pcall(peripheral.hasType, name, "drive")
        if ok and isDrive then
            drives[#drives + 1] = tostring(name)
        end
    end
    table.sort(drives)
    return drives
end

-- Free bytes on the mounted disk. CraftOS has no disk.getDiskSpaceTotal, so a
-- shim that provides the pair is preferred when present and the filesystem
-- capacity is used otherwise.
local function diskSpace(driveName, mount)
    local getTotal = disk.getDiskSpaceTotal
    local getUsed = disk.getDiskSpaceUsed
    if type(getTotal) == "function" and type(getUsed) == "function" then
        local okT, total = pcall(getTotal, driveName)
        local okU, used = pcall(getUsed, driveName)
        if okT and okU and type(total) == "number" and type(used) == "number" then
            return total - used, total
        end
    end
    if type(fs.getFreeSpace) == "function" then
        local okF, free = pcall(fs.getFreeSpace, mount)
        if okF and type(free) == "number" then
            return free, nil
        end
    end
    return nil, nil
end

-- Returns a location table or nil, reason, detail.
local function locate()
    local drives = scanDrives()
    if #drives == 0 then
        return nil, "no drive", "no disk drive is visible; check the drive network"
    end
    if #drives > 1 then
        return nil, "too many drives",
            tostring(#drives) .. " drives visible (" .. table.concat(drives, ", ") ..
            "); exactly one is allowed"
    end
    local name = drives[1]
    local okPresent, present = pcall(disk.isPresent, name)
    if not okPresent or not present then
        return nil, "no disk", "insert a disk into " .. name
    end
    local okMount, mount = pcall(disk.getMountPath, name)
    if not okMount or type(mount) ~= "string" or mount == "" then
        return nil, "no mount", "disk in " .. name .. " has no readable filesystem"
    end
    if not (fs.exists(mount) and fs.isDir(mount)) then
        return nil, "no mount", "disk in " .. name .. " is not mounted at " .. mount
    end
    return {drive = name, mount = mount}
end

-- Recursively lists the payload, sorted, directories before their contents.
local function walk(root)
    local entries = {}
    local function visit(dir, rel)
        local names = fs.list(dir)
        if type(names) ~= "table" then
            return
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local src = joinPath(dir, name)
            local relPath = (rel == "") and name or (rel .. "/" .. name)
            if fs.isDir(src) then
                entries[#entries + 1] = {kind = "dir", rel = relPath, src = src}
                visit(src, relPath)
            else
                entries[#entries + 1] = {
                    kind = "file",
                    rel = relPath,
                    src = src,
                    size = fs.getSize(src) or 0,
                }
            end
        end
    end
    visit(root, "")
    return entries
end

function M.status()
    local drives = scanDrives()
    local st = {state = "", drives = drives}
    if #drives == 0 then
        st.state = "no drive"
        return st
    end
    if #drives > 1 then
        st.state = "too many drives"
        return st
    end
    local name = drives[1]
    st.drive = name
    local okPresent, present = pcall(disk.isPresent, name)
    if not okPresent or not present then
        st.state = "no disk"
        return st
    end
    local okMount, mount = pcall(disk.getMountPath, name)
    if not okMount or type(mount) ~= "string" or mount == "" then
        st.state = "no mount"
        return st
    end
    st.mount = mount
    if not (fs.exists(mount) and fs.isDir(mount)) then
        st.state = "no mount"
        return st
    end
    st.state = "ready"
    local free, total = diskSpace(name, mount)
    st.free = free
    st.total = total
    return st
end

function M.write()
    local conf = cfg()
    local root = tostring(conf.payload_dir or "/payload")
    if not fs.exists(root) or not fs.isDir(root) then
        return false, "no payload", root .. " is missing on the server"
    end
    local entries = walk(root)
    if #entries == 0 then
        return false, "empty payload", root .. " contains nothing to write"
    end
    local totalBytes = 0
    for _, entry in ipairs(entries) do
        if entry.kind == "file" then
            totalBytes = totalBytes + entry.size
        end
    end

    local loc, reason, detail = locate()
    if not loc then
        return false, reason, detail
    end

    local free = diskSpace(loc.drive, loc.mount)
    if free and totalBytes > free then
        return false, "disk full", "need " .. tostring(totalBytes) .. " bytes, " ..
            tostring(free) .. " free"
    end

    local written = {}
    local createdDirs = {}
    local files, dirs = 0, 0

    -- Undo everything this call did. Pre-existing files get their previous
    -- bytes back; files and directories created here are removed.
    local function rollback()
        for i = #written, 1, -1 do
            local item = written[i]
            if item.existed then
                local out = fs.open(item.dst, "wb")
                if out then
                    out.write(item.backup or "")
                    out.close()
                end
            else
                fs.delete(item.dst)
            end
        end
        for i = #createdDirs, 1, -1 do
            if createdDirs[i].created then
                fs.delete(createdDirs[i].path)
            end
        end
    end

    for _, entry in ipairs(entries) do
        local dst = joinPath(loc.mount, entry.rel)
        if entry.kind == "dir" then
            if not fs.exists(dst) then
                local okMake, makeErr = pcall(fs.makeDir, dst)
                if not okMake or not fs.exists(dst) then
                    rollback()
                    return false, "cannot create " .. dst, tostring(makeErr or "makeDir failed")
                end
                createdDirs[#createdDirs + 1] = {path = dst, created = true}
            elseif not fs.isDir(dst) then
                rollback()
                return false, "cannot create " .. dst, "a file with that name is in the way"
            end
            dirs = dirs + 1
        else
            local parent = parentOf(dst)
            if not fs.exists(parent) then
                if not ensureDir(parent) then
                    rollback()
                    return false, "cannot create " .. parent, "makeDir failed"
                end
                createdDirs[#createdDirs + 1] = {path = parent, created = true}
            end
            local existed = fs.exists(dst)
            local backup = nil
            if existed then
                if fs.isDir(dst) then
                    rollback()
                    return false, "cannot create " .. dst,
                        "a directory with that name is in the way"
                end
                backup = readFile(dst)
                if backup == nil then
                    rollback()
                    return false, "write failed: " .. dst, "cannot read the existing file"
                end
            end
            written[#written + 1] = {dst = dst, existed = existed, backup = backup}

            local src = fs.open(entry.src, "rb")
            if not src then
                rollback()
                return false, "write failed: " .. dst, "cannot read " .. entry.src
            end
            local out = fs.open(dst, "wb")
            if not out then
                src.close()
                rollback()
                return false, "write failed: " .. dst, "cannot open destination"
            end
            local okWrite = true
            local writeError = nil
            while true do
                local chunk = src.read(8192)
                if chunk == nil then
                    break
                end
                -- CraftOS-PC's file:write returns nothing; errors are what is
                -- detectable here, the byte count is verified after the close.
                local okChunk, chunkError = pcall(function()
                    out.write(chunk)
                end)
                if not okChunk then
                    okWrite = false
                    writeError = chunkError
                    break
                end
            end
            src.close()
            out.close()
            if not okWrite then
                rollback()
                return false, "write failed: " .. dst, tostring(writeError or "the disk refused the data")
            end
            if (fs.getSize(dst) or -1) ~= entry.size then
                local got = fs.getSize(dst)
                rollback()
                return false, "write truncated", dst .. ": wrote " .. tostring(got) ..
                    " bytes, expected " .. tostring(entry.size)
            end
            files = files + 1
        end
    end

    local freeAfter = diskSpace(loc.drive, loc.mount)
    return true, {
        drive = loc.drive,
        mount = loc.mount,
        files = files,
        dirs = dirs,
        bytes = totalBytes,
        free_after = freeAfter,
    }
end

return M
