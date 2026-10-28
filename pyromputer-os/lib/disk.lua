-- disk.lua - removable media events (disk / disk_eject) for psh
--
-- CraftOS raises two events when a floppy is inserted into or removed from a
-- disk drive: "disk" (with the side as argument) and "disk_eject". psh reacts
-- from two places:
--
--   * the interactive line editor, which drains the queued events between two
--     keystrokes (safe_read -> disk.drain), so a user sitting at the prompt
--     sees the medium appear under /mnt without typing anything;
--   * startup.lua's watchdog, which calls disk.on_event() while no session is
--     running, so an insertion in the middle of the night is not lost.
--
-- The mount itself goes through lib/mounts.lua, so the mount table, the
-- "mount"/"umount" commands and the path mapping all see the same entries.
-- Names follow the existing convention: /disk -> /mnt/floppy, /disk2 ->
-- /mnt/floppy2, /disk0 -> /mnt/floppy0. A label file ".label" on the medium
-- wins over the drive name. A target that is already taken gets the next free
-- suffix (floppy2, floppy3, ...) and a source that is already mounted is left
-- alone, so a repeated "disk" event is harmless.
--
-- /etc/disk.conf (optional, every key optional):
--   automount=on|off
--   source=/disk
local disk = {}

local mounts = require("mounts")

local CONF = "/etc/disk.conf"
local LOG = "/var/log/disk.log"
local MOUNT_BASE = "/mnt"
local MAX_SUFFIX = 9

disk.conf_file = CONF
disk.log_file = LOG
disk.mount_base = MOUNT_BASE
disk.default_sources = { "/disk", "/disk0", "/disk1", "/disk2", "/disk3" }
disk.automount_default = true

local function logrotate()
    local ok, m = pcall(require, "logrotate")
    if ok and type(m) == "table" then return m end
    return nil
end

local function timestamp()
    local ok, t = pcall(require, "time")
    if ok and t and t.format then return t.format("%Y-%m-%d %H:%M:%S") end
    return os.date("%Y-%m-%d %H:%M:%S")
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

-- ------------------------------------------------------------------
-- Configuration
-- ------------------------------------------------------------------

function disk.config()
    local out = { automount = disk.automount_default, sources = {} }
    if not fs.exists(CONF) then
        for _, s in ipairs(disk.default_sources) do out.sources[#out.sources + 1] = s end
        return out
    end
    local f = fs.open(CONF, "r")
    if not f then return out end
    while true do
        local line = f.readLine()
        if line == nil then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([%w_]+)%s*=%s*(%S+)")
            if key == "automount" then
                value = value:lower()
                out.automount = (value == "on" or value == "yes" or value == "true" or value == "1")
            elseif key == "source" and value then
                out.sources[#out.sources + 1] = value
            elseif line:sub(1, 1) == "/" then
                out.sources[#out.sources + 1] = line
            end
        end
    end
    f.close()
    if #out.sources == 0 then
        for _, s in ipairs(disk.default_sources) do out.sources[#out.sources + 1] = s end
    end
    return out
end

function disk.sources()
    return disk.config().sources
end

function disk.set_automount(on)
    ensure_dir("/etc")
    local lines = {}
    if fs.exists(CONF) then
        local f = fs.open(CONF, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                if not line:match("^%s*automount%s*=") then lines[#lines + 1] = line end
            end
            f.close()
        end
    end
    table.insert(lines, 1, "automount=" .. (on and "on" or "off"))
    local f = fs.open(CONF, "w")
    if not f then return false, "cannot write " .. CONF end
    f.write(table.concat(lines, "\n") .. "\n")
    f.close()
    return true
end

-- ------------------------------------------------------------------
-- Media and names
-- ------------------------------------------------------------------

-- Is this path one of the removable sources we watch?
function disk.removable(path)
    if type(path) ~= "string" or path == "" then return false end
    if path == "/rom" then return false end
    for _, s in ipairs(disk.sources()) do
        if s == path then return true end
    end
    return false
end

-- Is a medium present at this source? A directory that reports a capacity is a
-- mounted filesystem, a missing one means the floppy was taken out.
function disk.present(path)
    if type(path) ~= "string" or path == "" then return false end
    if not fs.exists(path) or not fs.isDir(path) then return false end
    local ok, cap = pcall(fs.getCapacity, path)
    if not ok then return false end
    return cap ~= nil
end

-- Optional volume label: a ".label" file in the root of the medium.
function disk.label(path)
    local file = path .. "/.label"
    if not fs.exists(file) then return nil end
    local f = fs.open(file, "r")
    if not f then return nil end
    local line = f.readLine()
    f.close()
    if not line then return nil end
    line = line:gsub("%s+$", "")
    if line == "" or not line:match("^[%w_%-]+$") then return nil end
    if #line > 16 then line = line:sub(1, 16) end
    return line:lower()
end

-- Base name of the mount point for a source: the label when the medium has
-- one, otherwise the drive name mapped onto the "floppy" convention.
function disk.base_name(path)
    local label = disk.label(path)
    if label then return label end
    local base = path:match("([^/]+)$") or ""
    local suffix = base:match("^disk(%d*)$")
    if not suffix then return "floppy" end
    if suffix == "" then return "floppy" end
    return "floppy" .. suffix
end

-- The mount point to use: the base name, or the next free suffixed one when
-- that target is already taken by another medium.
function disk.pick_target(source)
    local base = disk.base_name(source)
    for i = 1, MAX_SUFFIX do
        local name = (i == 1) and base or (base .. tostring(i))
        local target = MOUNT_BASE .. "/" .. name
        if not mounts.by_target(target) then return target end
    end
    return nil
end

-- The mount table entry that currently has this source, if any.
function disk.mounted(source)
    for _, e in ipairs(mounts.list()) do
        if e.source == source then return e end
    end
    return nil
end

-- Removable mounts whose medium disappeared.
function disk.lost()
    local out = {}
    for _, e in ipairs(mounts.list()) do
        if disk.removable(e.source) and not disk.present(e.source) then
            out[#out + 1] = e
        end
    end
    return out
end

-- ------------------------------------------------------------------
-- Actions
-- ------------------------------------------------------------------

function disk.log(action, source, target, result, note)
    local lr = logrotate()
    if lr then pcall(lr.check, LOG, { max_lines = 2000, keep = 2 }) end
    ensure_dir("/var/log")
    local f = fs.open(LOG, "a")
    if not f then return false end
    local parts = {
        "[" .. timestamp() .. "]",
        "action=" .. tostring(action),
        "source=" .. tostring(source),
        "target=" .. tostring(target or "-"),
        "result=" .. tostring(result),
    }
    if note then parts[#parts + 1] = 'note="' .. tostring(note) .. '"' end
    f.write(table.concat(parts, " ") .. "\n")
    f.close()
    return true
end

-- Mount a medium that just appeared. Returns true plus the mount entry, or
-- false plus the reason; nothing is mounted twice.
function disk.auto_mount(source, opts)
    opts = opts or {}
    if not disk.removable(source) then
        return false, source .. ": not a removable source"
    end
    if not disk.present(source) then
        return false, source .. ": no medium"
    end
    local existing = disk.mounted(source)
    if existing then
        return false, "already mounted on " .. existing.target
    end
    local target = opts.target or disk.pick_target(source)
    if not target then
        return false, source .. ": no free mount point under " .. MOUNT_BASE
    end
    local ok, rec = mounts.mount(source, target, "rw", "automount")
    if not ok then
        disk.log("mount", source, target, "error", tostring(rec))
        return false, tostring(rec)
    end
    disk.log("mount", source, target, "ok", "disk event")
    return true, rec
end

-- Unmount a medium whose removal was reported. The mount point directory is
-- kept (unmounting never deletes data), and the current directory of the shell
-- is not consulted: the medium is already gone, so the entry would be stale.
function disk.auto_umount(source)
    local entry = disk.mounted(source)
    if not entry then
        return false, source .. ": not mounted"
    end
    local ok, rec = mounts.umount(source, nil)
    if not ok then
        disk.log("umount", source, entry.target, "error", tostring(rec))
        return false, tostring(rec)
    end
    disk.log("umount", source, entry.target, "ok", "disk_eject event")
    return true, rec
end

-- Mount every watched source that has a medium and is not mounted yet.
function disk.scan()
    local done, failed = {}, {}
    for _, source in ipairs(disk.sources()) do
        if disk.present(source) then
            local ok, rec = disk.auto_mount(source)
            if ok then
                done[#done + 1] = rec
            elseif type(rec) == "string" and not rec:find("already mounted", 1, true) then
                failed[#failed + 1] = source .. ": " .. rec
            end
        end
    end
    return done, failed
end

-- Mount table rows for the watched sources.
function disk.status()
    local rows = {}
    for _, source in ipairs(disk.sources()) do
        local entry = disk.mounted(source)
        rows[#rows + 1] = {
            source = source,
            present = disk.present(source),
            target = entry and entry.target or "-",
            state = entry and (entry.opts:find("ro") and "mounted (ro)" or "mounted (rw)") or "not mounted",
            label = disk.label(source) or "-",
        }
    end
    return rows
end

-- Handle one event by name ("disk" / "disk_eject"). Returns a list of report
-- lines for the caller to print; the caller decides where they go.
function disk.on_event(name, side)
    local report = {}
    local function add(text) report[#report + 1] = text end

    if name == "disk" then
        if not disk.config().automount then return report end
        for _, source in ipairs(disk.sources()) do
            if disk.present(source) then
                local ok, rec = disk.auto_mount(source)
                if ok then
                    add("disk: " .. rec.source .. " mounted on " .. rec.target)
                elseif type(rec) == "string" and not rec:find("already mounted", 1, true) then
                    add("disk: " .. rec)
                end
            end
        end
        if side and #report > 0 then
            report[#report] = report[#report] .. " (side " .. tostring(side) .. ")"
        end
    elseif name == "disk_eject" then
        for _, entry in ipairs(disk.lost()) do
            local ok, rec = disk.auto_umount(entry.source)
            if ok then
                add("disk: " .. entry.source .. " unmounted from " .. entry.target)
            else
                add("disk: " .. tostring(rec))
            end
        end
    end
    return report
end

-- Wait up to `timeout` seconds for disk events and act on them. Events that
-- are not ours (keys, timers, term signals) are put back on the queue in order,
-- so a caller that is also reading the terminal loses nothing. Returns the
-- report lines.
--
-- The interactive shell does not use this: it sees the events directly in its
-- editor loop (usr/psh.lua). Scripts and the startup watchdog, which may block,
-- call it to collect what is pending.
local function requeue(ev)
    local unpack_fn = table.unpack or unpack
    os.queueEvent(unpack_fn(ev))
end

function disk.drain(limit, timeout)
    limit = limit or 8
    timeout = timeout or 0.1
    local report = {}
    local n = 0
    local timer = os.startTimer(timeout)

    while n < limit do
        local ev = { os.pullEventRaw() }
        if ev[1] == "timer" and ev[2] == timer then break end
        if ev[1] == "disk" or ev[1] == "disk_eject" then
            n = n + 1
            for _, line in ipairs(disk.on_event(ev[1], ev[2])) do
                report[#report + 1] = line
            end
        else
            requeue(ev)
        end
    end
    return report
end

-- ------------------------------------------------------------------
-- disk(8) command
-- ------------------------------------------------------------------

local USAGE = {
    "usage: disk                      state of the watched sources",
    "       disk scan                 mount every medium that is present",
    "       disk umount [SOURCE]      unmount removable media",
    "       disk on | off             switch automount",
}

function disk.main(args, stage)
    stage = stage or { write = function(s) print(s) end }
    local function emit(text) stage.write(text .. "\n") end
    args = args or {}

    local cmd = "status"
    local rest = {}
    for _, a in ipairs(args) do
        if a:sub(1, 1) == "-" and a ~= "-" then
            if a == "-h" or a == "--help" then
                cmd = "help"
            else
                emit("disk: " .. a .. ": unknown option")
                return 1
            end
        elseif cmd == "status" and rest[1] == nil and
               (a == "scan" or a == "umount" or a == "on" or a == "off" or a == "status" or a == "help") then
            cmd = a == "help" and "help" or a
        else
            rest[#rest + 1] = a
        end
    end

    if cmd == "help" then
        for _, line in ipairs(USAGE) do emit(line) end
        return 0
    end

    if cmd == "status" then
        local conf = disk.config()
        emit("automount: " .. (conf.automount and "on" or "off"))
        emit(string.format("%-10s %-8s %-14s %-14s %s",
            "SOURCE", "MEDIUM", "MOUNTED ON", "STATE", "LABEL"))
        for _, r in ipairs(disk.status()) do
            emit(string.format("%-10s %-8s %-14s %-14s %s",
                r.source, r.present and "yes" or "no", r.target, r.state, r.label))
        end
        return 0
    end

    if cmd == "scan" then
        local done, failed = disk.scan()
        for _, rec in ipairs(done) do
            emit("disk: " .. rec.source .. " mounted on " .. rec.target)
        end
        for _, text in ipairs(failed) do emit("disk: " .. text) end
        if #done == 0 and #failed == 0 then emit("disk: no medium found") end
        return #failed > 0 and 1 or 0
    end

    if cmd == "umount" then
        local sources = {}
        if rest[1] then
            sources[1] = rest[1]
        else
            for _, entry in ipairs(mounts.list()) do
                if disk.removable(entry.source) then
                    sources[#sources + 1] = entry.source
                end
            end
        end
        if #sources == 0 then
            emit("disk: nothing mounted from a removable source")
            return 0
        end
        local failed = 0
        for _, source in ipairs(sources) do
            local ok, rec = disk.auto_umount(source)
            if ok then
                emit("disk: " .. source .. " unmounted (was " .. rec.target .. ")")
            else
                failed = failed + 1
                emit("disk: " .. tostring(rec))
            end
        end
        return failed > 0 and 1 or 0
    end

    if cmd == "on" or cmd == "off" then
        local on = (cmd == "on")
        local ok, err = disk.set_automount(on)
        if not ok then
            emit("disk: " .. tostring(err))
            return 1
        end
        emit("disk: automount " .. (on and "on" or "off"))
        return 0
    end

    emit("disk: " .. tostring(cmd) .. ": unknown subcommand")
    return 1
end

return disk
