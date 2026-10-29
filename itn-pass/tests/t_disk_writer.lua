-- t_disk_writer.lua -- disk payload copy: failure texts and rollback.

local function run(H)
    H.group("disk_writer")
    local writer = dofile("/system/disk_writer.lua")

    local function payloadReset(files)
        H.rmTree("/payload")
        fs.makeDir("/payload")
        for _, f in ipairs(files) do
            local path = "/payload/" .. f.rel
            H.ensureDir(path:match("^(.*)/[^/]+$"))
            H.writeFile(path, f.data)
        end
    end

    local function mountReset()
        H.rmTree("/disk")
        fs.makeDir("/disk")
    end

    local function ready()
        H.installPeripheral({ names = { "left" }, types = { left = "drive" } })
        H.installDisk({
            present = function() return true end,
            mount = function() return "/disk" end,
        })
        mountReset()
    end

    local ok, reason, detail, info, st

    ------------------------------------------------------------------------
    -- payload preconditions
    ------------------------------------------------------------------------
    H.rmTree("/payload")
    ok, reason, detail = writer.write()
    H.check("disk_writer.no_payload", ok == false and reason == "no payload",
        tostring(reason))
    H.check("disk_writer.no_payload_detail",
        detail == "/payload is missing on the server", tostring(detail))

    fs.makeDir("/payload")
    ok, reason, detail = writer.write()
    H.check("disk_writer.empty_payload", reason == "empty payload", tostring(reason))
    H.check("disk_writer.empty_payload_detail",
        detail == "/payload contains nothing to write", tostring(detail))
    fs.delete("/payload")

    ------------------------------------------------------------------------
    -- drive / disk / mount selection
    ------------------------------------------------------------------------
    payloadReset({ { rel = "a.txt", data = "AAA" } })

    H.installPeripheral({ names = {} })
    ok, reason, detail = writer.write()
    H.check("disk_writer.no_drive", reason == "no drive", tostring(reason))
    H.check("disk_writer.no_drive_detail",
        detail == "no disk drive is visible; check the drive network", tostring(detail))
    st = writer.status()
    H.check("disk_writer.status_no_drive", st.state == "no drive" and #st.drives == 0,
        st.state)

    H.installPeripheral({
        names = { "left", "back" },
        types = { left = "drive", back = "drive" },
    })
    ok, reason, detail = writer.write()
    H.check("disk_writer.too_many_drives", reason == "too many drives", tostring(reason))
    H.check("disk_writer.too_many_detail",
        detail == "2 drives visible (back, left); exactly one is allowed",
        tostring(detail))
    st = writer.status()
    H.check("disk_writer.status_too_many",
        st.state == "too many drives" and #st.drives == 2, st.state)

    H.installPeripheral({ names = { "left" }, types = { left = "drive" } })
    H.installDisk({ present = function() return false end })
    ok, reason, detail = writer.write()
    H.check("disk_writer.no_disk", reason == "no disk" and detail == "insert a disk into left",
        tostring(detail))
    st = writer.status()
    H.check("disk_writer.status_no_disk",
        st.state == "no disk" and st.drive == "left" and st.mount == nil, st.state)

    H.installDisk({ presentError = true })
    ok, reason, detail = writer.write()
    H.check("disk_writer.present_error_is_no_disk", reason == "no disk",
        tostring(reason))

    H.installDisk({
        present = function() return true end,
        mount = function() return "" end,
    })
    ok, reason, detail = writer.write()
    H.check("disk_writer.no_mount_empty_path", reason == "no mount", tostring(reason))
    H.check("disk_writer.no_mount_empty_path_detail",
        detail == "disk in left has no readable filesystem", tostring(detail))

    H.installDisk({
        present = function() return true end,
        mount = function() return "/nodisk" end,
    })
    ok, reason, detail = writer.write()
    H.check("disk_writer.no_mount_missing_path", reason == "no mount",
        tostring(reason))
    H.check("disk_writer.no_mount_missing_path_detail",
        detail == "disk in left is not mounted at /nodisk", tostring(detail))
    st = writer.status()
    H.check("disk_writer.status_no_mount", st.state == "no mount", st.state)

    ------------------------------------------------------------------------
    -- free space
    ------------------------------------------------------------------------
    ready()
    payloadReset({ { rel = "a.txt", data = "AAAAA" } })
    H.setFreeSpace(4)
    ok, reason, detail = writer.write()
    H.check("disk_writer.disk_full", reason == "disk full", tostring(reason))
    H.check("disk_writer.disk_full_detail", detail == "need 5 bytes, 4 free",
        tostring(detail))
    H.check("disk_writer.disk_full_writes_nothing", not fs.exists("/disk/a.txt"))

    H.installDisk({
        present = function() return true end,
        mount = function() return "/disk" end,
        total = 1000,
        used = 400,
    })
    st = writer.status()
    H.check("disk_writer.status_space_shim",
        st.state == "ready" and st.free == 600 and st.total == 1000,
        tostring(st.free) .. "/" .. tostring(st.total))
    payloadReset({ { rel = "a.txt", data = string.rep("A", 700) } })
    ok, reason, detail = writer.write()
    H.check("disk_writer.disk_full_via_shim",
        reason == "disk full" and detail == "need 700 bytes, 600 free",
        tostring(detail))

    ------------------------------------------------------------------------
    -- successful copy
    ------------------------------------------------------------------------
    ready()
    H.setFreeSpace(1000000)
    H.writeFile("/disk/keep.txt", "KEEP")
    local big = string.rep("B", 9000)
    payloadReset({
        { rel = "a.txt", data = "AAA" },
        { rel = "sub/b.txt", data = big },
        { rel = "sub/inner/c.txt", data = "C\n" },
    })
    ok, reason, detail = writer.write()
    info = reason
    H.check("disk_writer.write_ok", ok == true, tostring(detail))
    H.check("disk_writer.write_info_fields",
        info ~= nil and info.drive == "left" and info.mount == "/disk"
        and info.files == 3 and info.dirs == 2 and info.bytes == 9005
        and info.free_after == 1000000, textutils.serialize(info or {}))
    H.check("disk_writer.write_small_file", H.readFile("/disk/a.txt") == "AAA")
    H.check("disk_writer.write_chunked_file", H.readFile("/disk/sub/b.txt") == big)
    H.check("disk_writer.write_size_matches_source",
        fs.getSize("/disk/sub/b.txt") == #big)
    H.check("disk_writer.write_nested_file",
        H.readFile("/disk/sub/inner/c.txt") == "C\n")
    H.check("disk_writer.write_keeps_unrelated_file",
        H.readFile("/disk/keep.txt") == "KEEP")

    H.setFreeSpace(4242)
    st = writer.status()
    H.check("disk_writer.status_ready",
        st.state == "ready" and st.drive == "left" and st.mount == "/disk", st.state)
    H.check("disk_writer.status_free",
        st.free == 4242 and st.total == nil, tostring(st.free))

    H.installPeripheral({
        names = { "left", "top" },
        types = { left = "drive", top = "modem" },
    })
    st = writer.status()
    H.check("disk_writer.ignores_non_drives",
        #st.drives == 1 and st.drives[1] == "left", #st.drives)

    ------------------------------------------------------------------------
    -- rollback and per-file size checks
    ------------------------------------------------------------------------
    H.group("disk_writer.rollback")
    local realOpen = fs.open
    local LOG = "/auth/itnpass_server.log"

    local function logText()
        return H.readFile(LOG) or ""
    end

    local function clearLog()
        if fs.exists(LOG) then
            fs.delete(LOG)
        end
    end

    ready()
    H.setFreeSpace(1000000)
    H.writeFile("/disk/keep.txt", "KEEP")
    payloadReset({
        { rel = "a.txt", data = "AAA" },
        { rel = "b.txt", data = "BB" },
        { rel = "sub/c.txt", data = "CCC" },
    })
    H.scenario("disk_writer.rollback_read", function()
        fs.open = function(path, mode)
            if path == "/payload/sub/c.txt" then
                return nil
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.rollback_read_reason",
        ok == false and reason == "write failed: /disk/sub/c.txt", tostring(reason))
    H.check("disk_writer.rollback_read_detail",
        detail == "cannot read /payload/sub/c.txt", tostring(detail))
    H.check("disk_writer.rollback_read_removes_new_files",
        not fs.exists("/disk/a.txt") and not fs.exists("/disk/b.txt"))
    H.check("disk_writer.rollback_read_removes_new_dirs",
        not fs.exists("/disk/sub"))
    H.check("disk_writer.rollback_read_keeps_unrelated",
        H.readFile("/disk/keep.txt") == "KEEP")

    ready()
    H.setFreeSpace(1000000)
    H.writeFile("/disk/a.txt", "ORIGINAL")
    payloadReset({ { rel = "a.txt", data = "NEWCONTENT" }, { rel = "b.txt", data = "BB" } })
    clearLog()
    H.scenario("disk_writer.rollback_restore", function()
        fs.open = function(path, mode)
            if path == "/payload/b.txt" then
                return nil
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.rollback_restores_previous_bytes",
        H.readFile("/disk/a.txt") == "ORIGINAL", tostring(H.readFile("/disk/a.txt")))
    -- A rollback that put every byte back is not a failure and stays quiet.
    H.check("disk_writer.rollback_restore_reports_no_failure",
        tostring(detail):find("rollback failed", 1, true) == nil, tostring(detail))
    H.check("disk_writer.rollback_restore_log_clean",
        logText():find("WRITER_ROLLBACK_SIZE", 1, true) == nil, logText():sub(1, 80))

    -- A rollback that lands short must be detected and reported, not swallowed.
    ready()
    H.setFreeSpace(1000000)
    H.writeFile("/disk/a.txt", "ORIGINAL")
    payloadReset({ { rel = "a.txt", data = "NEWCONTENT" }, { rel = "b.txt", data = "BB" } })
    clearLog()
    local aOpens = 0
    H.scenario("disk_writer.rollback_short_restore", function()
        fs.open = function(path, mode)
            if path == "/payload/b.txt" then
                return nil
            end
            if path == "/disk/a.txt" and mode == "wb" then
                aOpens = aOpens + 1
                if aOpens == 2 then
                    -- The rollback write: accept only part of the backup.
                    return {
                        write = function(chunk)
                            local f = realOpen(path, "wb")
                            f.write(tostring(chunk):sub(1, 3))
                            f.close()
                        end,
                        close = function() end,
                    }
                end
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.rollback_short_reason",
        ok == false and reason == "write failed: /disk/b.txt", tostring(reason))
    H.check("disk_writer.rollback_short_failure_reported",
        tostring(detail):find("rollback failed", 1, true) ~= nil, tostring(detail))
    H.check("disk_writer.rollback_short_failure_bytes",
        tostring(detail):find("has 3 of 8 bytes", 1, true) ~= nil, tostring(detail))
    H.check("disk_writer.rollback_short_logged",
        logText():find("WRITER_ROLLBACK_SIZE", 1, true) ~= nil, logText())
    H.check("disk_writer.rollback_short_log_values",
        logText():find("WRITER_ROLLBACK_SIZE dst=/disk/a.txt expected=8 got=3", 1, true)
        ~= nil, logText())
    H.check("disk_writer.rollback_short_leaves_short_file",
        fs.getSize("/disk/a.txt") == 3, tostring(fs.getSize("/disk/a.txt")))

    ready()
    payloadReset({ { rel = "a.txt", data = "AAA" } })
    H.scenario("disk_writer.rollback_open", function()
        fs.open = function(path, mode)
            if path == "/disk/a.txt" and mode == "wb" then
                return nil
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.open_destination_reason",
        reason == "write failed: /disk/a.txt", tostring(reason))
    H.check("disk_writer.open_destination_detail",
        detail == "cannot open destination", tostring(detail))
    H.check("disk_writer.open_destination_no_residue",
        not fs.exists("/disk/a.txt"))

    ready()
    H.writeFile("/disk/a.txt", "")
    payloadReset({ { rel = "a.txt", data = string.rep("X", 100) } })
    H.scenario("disk_writer.rollback_truncated", function()
        fs.open = function(path, mode)
            if path == "/disk/a.txt" and mode == "wb" then
                return { write = function() end, close = function() end }
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.truncated_reason", reason == "write truncated",
        tostring(reason))
    H.check("disk_writer.truncated_detail",
        detail == "/disk/a.txt: wrote 0 bytes, expected 100", tostring(detail))

    ready()
    payloadReset({ { rel = "a.txt", data = "AAA" } })
    H.scenario("disk_writer.rollback_chunk_error", function()
        fs.open = function(path, mode)
            if path == "/disk/a.txt" and mode == "wb" then
                return {
                    write = function() error("disk refused the data") end,
                    close = function() end,
                }
            end
            return realOpen(path, mode)
        end
        ok, reason, detail = writer.write()
    end)
    fs.open = realOpen
    H.check("disk_writer.chunk_error_reason",
        reason == "write failed: /disk/a.txt", tostring(reason))
    H.check("disk_writer.chunk_error_detail",
        tostring(detail):find("disk refused the data", 1, true) ~= nil,
        tostring(detail))

    ready()
    H.writeFile("/disk/sub", "I am a file")
    payloadReset({ { rel = "sub/c.txt", data = "C" } })
    ok, reason, detail = writer.write()
    H.check("disk_writer.dir_blocked_by_file",
        reason == "cannot create /disk/sub"
        and detail == "a file with that name is in the way", tostring(detail))

    ready()
    fs.makeDir("/disk/x")
    payloadReset({ { rel = "x", data = "X" } })
    ok, reason, detail = writer.write()
    H.check("disk_writer.file_blocked_by_dir",
        reason == "cannot create /disk/x"
        and detail == "a directory with that name is in the way", tostring(detail))
end

return run
