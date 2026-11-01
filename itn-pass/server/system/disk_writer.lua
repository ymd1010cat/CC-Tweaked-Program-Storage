-- disk_writer.lua -- copies the server payload to the one attached disk drive.
-- Deploy as /system/disk_writer.lua on the card key server.
--
-- M.plan([profile[, part]]) -> plan              (no drive touched: the same
--                                payload / byte budget checks write() runs, so a
--                                caller can refuse a write before charging a key)
--                            -> nil, reason, detail
-- M.write([profile[, part]])
--                            -> true, {drive, mount, files, dirs, bytes,
--                                      free_after, profile, part, source}
--                            -> false, reason, detail
-- M.status()                 -> {state, drives, drive?, mount?, free?}
--
-- A payload profile (see /itnpass_profile.lua) selects which payload tree this
-- transaction installs: a profile with parts keeps one sub-directory per disk
-- ("part1" / "part2") and one write transaction per part; a profile without
-- parts -- and every call that passes no profile at all -- writes the payload
-- root, which is the pre-profile behaviour. The profile also carries the byte
-- budget of one disk, so an over-large payload is refused before the disk is
-- touched instead of being reported as "disk full".
--
-- The drive network must hold exactly one drive. Failure messages are the ones
-- the terminal and the admin console show, so they are spelled out verbatim.

local M = {}

local LOG_PATH = "/auth/itnpass_server.log"

-- Same module instance contract as the store: the catalog is loaded once, so a
-- missing deployment file is reported as an unknown profile rather than being
-- silently ignored.
local profiles = nil
do
    local ok, mod = pcall(dofile, "/itnpass_profile.lua")
    if ok and type(mod) == "table" then
        profiles = mod
    end
end

-- Same line format as the service log. This module runs inside the server or
-- the admin console, neither of which can print while a copy is in progress.
local function log(message)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(message) .. "\n"
    local f = fs.open(LOG_PATH, "a")
    if f then
        f.write(line)
        f.close()
    end
end

local function cfg()
    local ok, t = pcall(dofile, "/auth/itnpass_config.lua")
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

-- Part number as an integer, or nil when it is malformed.
local function partNumber(part)
    if part == nil then
        return nil
    end
    local value = tonumber(part)
    if value == nil or value ~= math.floor(value) or value < 1 then
        return nil, "bad part"
    end
    return value
end

-- Picks the payload tree for one part of a multi-part profile. An explicit part
-- wins. Without one: exactly one part directory present means "this is the disk
-- being written"; none present means the operator swapped a half into the
-- payload root, so part 1 with the root is used; several present is ambiguous
-- and refused, because guessing would write the wrong half to a disk.
local function selectPart(base, spec, part)
    local present = {}
    for index = 1, #spec.parts do
        local path = joinPath(base, spec.parts[index])
        if fs.exists(path) and fs.isDir(path) then
            present[#present + 1] = index
        end
    end
    local want = nil
    if part ~= nil then
        want = part
    elseif #present == 1 then
        want = present[1]
    elseif #present == 0 then
        want = 1
    else
        local names = {}
        for _, index in ipairs(present) do
            names[#names + 1] = spec.parts[index]
        end
        return nil, "part required", "payload holds " .. tostring(#present) ..
            " parts (" .. table.concat(names, ", ") .. "); say which disk this is"
    end
    if want < 1 or want > #spec.parts then
        return nil, "bad part", "profile " .. tostring(spec.name) .. " has " ..
            tostring(#spec.parts) .. " part(s), got " .. tostring(want)
    end
    local root = joinPath(base, spec.parts[want])
    if not (fs.exists(root) and fs.isDir(root)) then
        -- Flat layout: the part was swapped into the payload root itself.
        root = base
    end
    return {index = want, root = root}
end

-- Shared by plan() and write(): everything that can refuse a write without
-- touching the disk (unknown profile, wrong part, missing payload, byte budget)
-- happens here, so the two paths cannot disagree about it.
-- Returns (plan, entries) or (nil, reason, detail).
local function buildPlan(profileName, part)
    local conf = cfg()
    local base = tostring(conf.payload_dir or "/payload")
    local name = nil
    local spec = nil
    if profileName ~= nil and profileName ~= "" then
        if profiles == nil then
            return nil, "unknown profile", "cannot load /itnpass_profile.lua"
        end
        name = profiles.parse(profileName)
        if name == nil then
            return nil, "unknown profile", "profile '" .. tostring(profileName) ..
                "' is not one of: " .. profiles.names_line()
        end
        spec = profiles.get(name)
    end

    local requested, partError = partNumber(part)
    if part ~= nil and requested == nil then
        return nil, tostring(partError or "bad part"), "a part must be an integer >= 1"
    end

    local root = base
    local index = nil
    if spec ~= nil and #spec.parts > 0 then
        local chosen, why, detail = selectPart(base, spec, requested)
        if not chosen then
            return nil, why, detail
        end
        root = chosen.root
        index = chosen.index
    elseif requested ~= nil and requested ~= 1 then
        return nil, "bad part", "a single-tree write cannot use part " ..
            tostring(requested)
    elseif requested ~= nil then
        index = 1
    end

    if not fs.exists(root) or not fs.isDir(root) then
        return nil, "no payload", root .. " is missing on the server"
    end

    local entries = walk(root)
    if #entries == 0 then
        return nil, "empty payload", root .. " contains nothing to write"
    end
    local totalBytes = 0
    local fileCount = 0
    local dirCount = 0
    for _, item in ipairs(entries) do
        if item.kind == "file" then
            totalBytes = totalBytes + item.size
            fileCount = fileCount + 1
        else
            dirCount = dirCount + 1
        end
    end

    local capacity = nil
    if name ~= nil and profiles ~= nil then
        capacity = profiles.capacity(name, conf)
    end
    if capacity ~= nil and capacity > 0 and totalBytes > capacity then
        return nil, "payload too large", "need " .. tostring(totalBytes) ..
            " bytes, profile " .. name .. " allows " .. tostring(capacity)
    end

    return {
        profile = name,
        part = index,
        source = root,
        files = fileCount,
        dirs = dirCount,
        bytes = totalBytes,
        capacity = capacity,
    }, entries
end

function M.plan(profileName, part)
    local plan, extra, detail = buildPlan(profileName, part)
    if not plan then
        return nil, extra, detail
    end
    return plan
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

function M.write(profileName, part)
    local plan, entries, planDetail = buildPlan(profileName, part)
    if not plan then
        return false, entries, planDetail
    end
    local totalBytes = plan.bytes

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
    -- bytes back; files and directories created here are removed. A restore
    -- that does not land every byte back is returned, never dropped.
    local function rollback()
        local failure = nil
        for i = #written, 1, -1 do
            local item = written[i]
            if item.existed then
                local want = #(item.backup or "")
                local out = fs.open(item.dst, "wb")
                if out then
                    out.write(item.backup or "")
                    out.close()
                end
                local got = fs.getSize(item.dst) or -1
                if got ~= want then
                    log("WRITER_ROLLBACK_SIZE dst=" .. item.dst .. " expected=" ..
                        tostring(want) .. " got=" .. tostring(got))
                    if failure == nil then
                        failure = {dst = item.dst, expected = want, got = got}
                    end
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
        return failure
    end

    -- Fails the copy after undoing it. A rollback that could not put the old
    -- bytes back belongs in the failure text: the caller forwards it and the
    -- operator has to know the disk is not in the state it was before.
    local function refuse(reason, detail)
        local failure = rollback()
        if failure then
            detail = tostring(detail or "") .. " (rollback failed: " .. failure.dst ..
                " has " .. tostring(failure.got) .. " of " ..
                tostring(failure.expected) .. " bytes)"
        end
        return false, reason, detail
    end

    for _, entry in ipairs(entries) do
        local dst = joinPath(loc.mount, entry.rel)
        if entry.kind == "dir" then
            if not fs.exists(dst) then
                local okMake, makeErr = pcall(fs.makeDir, dst)
                if not okMake or not fs.exists(dst) then
                    return refuse("cannot create " .. dst,
                        tostring(makeErr or "makeDir failed"))
                end
                createdDirs[#createdDirs + 1] = {path = dst, created = true}
            elseif not fs.isDir(dst) then
                return refuse("cannot create " .. dst,
                    "a file with that name is in the way")
            end
            dirs = dirs + 1
        else
            local parent = parentOf(dst)
            if not fs.exists(parent) then
                if not ensureDir(parent) then
                    return refuse("cannot create " .. parent, "makeDir failed")
                end
                createdDirs[#createdDirs + 1] = {path = parent, created = true}
            end
            local existed = fs.exists(dst)
            local backup = nil
            if existed then
                if fs.isDir(dst) then
                    return refuse("cannot create " .. dst,
                        "a directory with that name is in the way")
                end
                backup = readFile(dst)
                if backup == nil then
                    return refuse("write failed: " .. dst,
                        "cannot read the existing file")
                end
            end
            written[#written + 1] = {dst = dst, existed = existed, backup = backup}

            local src = fs.open(entry.src, "rb")
            if not src then
                return refuse("write failed: " .. dst, "cannot read " .. entry.src)
            end
            local out = fs.open(dst, "wb")
            if not out then
                src.close()
                return refuse("write failed: " .. dst, "cannot open destination")
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
                return refuse("write failed: " .. dst,
                    tostring(writeError or "the disk refused the data"))
            end
            if (fs.getSize(dst) or -1) ~= entry.size then
                local got = fs.getSize(dst)
                return refuse("write truncated", dst .. ": wrote " .. tostring(got) ..
                    " bytes, expected " .. tostring(entry.size))
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
        -- Empty on the pre-profile call shape, so an old caller sees the same
        -- info table it always did.
        profile = plan.profile,
        part = plan.part,
        source = plan.source,
        capacity = plan.capacity,
    }
end

return M
