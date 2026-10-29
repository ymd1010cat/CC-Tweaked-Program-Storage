--[[- pyroet-os/tests/t_recovery_flash.lua -- recovery/flash.lua: the floppy and
rednet sources of a PYROET-FLASH/2 file set, the stage-before-apply rule, the
idempotent second run and the "a failed flash keeps the old system" guarantee.

No slot is involved any more: the target is always <root>/system.
No non-ASCII bytes in this file.
]]

local P = dofile("/recovery/proto.lua")
local FLASH = assert(loadfile("/recovery/flash.lua"))()

return function(H)
    local F = H.real_fs()
    local SHA = P.sha({})

    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end

    local function described(files, version)
        local list = {}
        for i = 1, #files do
            list[i] = { relpath = files[i][1], size = #files[i][2],
                sha256 = P.dg(SHA, files[i][2]) }
        end
        local text = "version=" .. tostring(version or "9.9.9")
            .. " manifest_sha=" .. P.manifest_sha(SHA, list)
            .. " files=" .. tostring(#list)
        for i = 1, #list do
            text = text .. "\n" .. list[i].relpath .. " " .. tostring(list[i].size)
                .. " " .. list[i].sha256
        end
        return text, list
    end

    -- a floppy image: firmware/meta.txt plus the files under their relpaths
    local function release(dir, files, version)
        H.write(dir .. "/firmware/meta.txt", (described(files, version)) .. "\n")
        for i = 1, #files do
            H.write(dir .. "/firmware/" .. files[i][1], files[i][2])
        end
        return dir .. "/firmware"
    end

    local function run(argv, opts)
        local log, lines = H.logger()
        local base = { fs = F, print = log, sha = SHA }
        for k, v in pairs(opts or {}) do base[k] = v end
        local ok = FLASH.main(argv or {}, base)
        return ok, log, lines
    end

    local function scripted(items, sent)
        local i = 0
        return {
            send = function(host, msg) sent[#sent + 1] = msg; return true end,
            receive = function()
                i = i + 1
                local item = items[i]
                if item == nil then return nil end
                return item[1], item[2]
            end,
        }
    end

    local FILES = { { "boot.lua", "boot v2\n" }, { "kernel/a.lua", "a v2\n" } }

    -- ---------------------------------------------------------------------
    H.group("recovery.flash.args")
    do
        local a = FLASH.args({ "--disk", "/disk/fw", "--host", "7" })
        H.eq("args_disk", a.disk, "/disk/fw")
        H.eq("args_host", a.host, "7")
        local b = FLASH.args({ "--disk=/disk/x" })
        H.eq("args_inline", b.disk, "/disk/x")
        local c = FLASH.args({ "noise", "--host=12" })
        H.eq("args_skip", c.host, "12")
        H.eq("args_empty", #FLASH.args({}), 0)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.flash.disk")
    do
        local dir = H.case_dir("recovery-flash", "ok")
        H.mkdirp(dir .. "/system/kernel")
        H.write(dir .. "/system/boot.lua", "boot v1\n")
        H.write(dir .. "/system/kernel/a.lua", "a v1\n")
        local disk = release(dir, FILES)
        local ok, _, lines = run({}, { root = dir, disk = disk })
        H.check("disk_ok", ok == true, "flash failed")
        H.has(lines, "FLASH_TARGET path=" .. dir .. "/system state=present")
        H.has(lines, "FLASH_SOURCE kind=disk path=" .. disk)
        H.has(lines, "FLASH_META version=9.9.9 files=2 manifest_sha=")
        H.has(lines, "FLASH_OK files=2 written=2 skipped=0 bytes=13")
        H.eq("disk_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
        H.eq("disk_kernel", H.read(dir .. "/system/kernel/a.lua"), "a v2\n")
        H.eq("disk_backup_boot", H.read(dir .. "/update.backup/boot.lua"), "boot v1\n")
        H.eq("disk_backup_kernel", H.read(dir .. "/update.backup/kernel/a.lua"), "a v1\n")
        H.eq("disk_stage_gone", H.exists(dir .. "/update.stage"), false)
        H.eq("disk_journal", H.exists(dir .. "/update.journal.1"), true)
        H.contains("disk_journal_state", H.read(dir .. "/update.journal.1") or "",
            "state=applied")
        H.contains("disk_journal_line", H.read(dir .. "/update.journal.1") or "",
            "boot.lua " .. P.dg(SHA, "boot v1\n") .. " " .. P.dg(SHA, "boot v2\n") .. " 8")

        -- a bricked machine has no /system at all; the flash creates it
        local blank = H.case_dir("recovery-flash", "blank")
        local blank_disk = release(blank, FILES)
        local ok2, _, lines2 = run({}, { root = blank, disk = blank_disk })
        H.check("blank_ok", ok2 == true, "flash failed on a blank machine")
        H.has(lines2, "FLASH_TARGET path=" .. blank .. "/system state=missing")
        H.eq("blank_boot", H.read(blank .. "/system/boot.lua"), "boot v2\n")
        H.eq("blank_no_backup", H.exists(blank .. "/update.backup"), false)
        H.eq("blank_journal", H.exists(blank .. "/update.journal.1"), true)

        -- the same set again is a no-op: nothing is written, no backup churn
        local ok3, _, lines3 = run({}, { root = dir, disk = disk })
        H.check("again_ok", ok3 == true, "second flash failed")
        H.has(lines3, "FLASH_OK files=2 written=0 skipped=2 bytes=0")
        H.eq("again_backup_kept", H.read(dir .. "/update.backup/boot.lua"), "boot v1\n")
        H.eq("again_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.flash.meta")
    do
        local dir = H.case_dir("recovery-flash", "no-meta")
        H.mkdirp(dir .. "/firmware")
        local ok, _, lines = run({}, { root = dir, rednet = scripted({}, {}), host = 12 })
        H.check("no_source_fail", ok == false, "flashed without any source")
        H.has(lines, "FLASH_FAIL stage=meta err=timeout")

        local no_host = H.case_dir("recovery-flash", "no-host")
        local okh, _, linesh = run({}, { root = no_host })
        H.check("no_host_fail", okh == false, "accepted a missing host")
        H.has(linesh, "FLASH_FAIL stage=source err=host")

        dir = H.case_dir("recovery-flash", "bad-version")
        local disk = release(dir, FILES)
        H.write(disk .. "/meta.txt", (described(FILES, "9/9")) .. "\n")
        ok, _, lines = run({}, { root = dir, disk = disk })
        H.check("bad_version_fail", ok == false, "accepted a bad version")
        H.has(lines, "FLASH_FAIL stage=meta err=version")

        dir = H.case_dir("recovery-flash", "bad-manifest")
        disk = release(dir, FILES)
        local text = described(FILES)
        H.write(disk .. "/meta.txt", (text:gsub("manifest_sha=%x+", "manifest_sha="
            .. string.rep("0", 64))) .. "\n")
        ok, _, lines = run({}, { root = dir, disk = disk })
        H.check("bad_manifest_fail", ok == false, "accepted a wrong manifest digest")
        H.has(lines, "FLASH_FAIL stage=meta err=manifest_sha_mismatch")

        dir = H.case_dir("recovery-flash", "missing-file")
        disk = release(dir, FILES)
        H.rmrf(disk .. "/kernel/a.lua")
        ok, _, lines = run({}, { root = dir, disk = disk })
        H.check("missing_file_fail", ok == false, "flashed a missing file")
        H.has(lines, "FLASH_FAIL stage=stage err=missing")
        H.eq("missing_file_no_journal", H.exists(dir .. "/update.journal.1"), false)

        dir = H.case_dir("recovery-flash", "bad-body")
        disk = release(dir, FILES)
        H.write(disk .. "/kernel/a.lua", "a v3\n")
        ok, _, lines = run({}, { root = dir, disk = disk })
        H.check("bad_body_fail", ok == false, "flashed a body that does not match")
        H.has(lines, "FLASH_FAIL stage=stage err=sha256")
        H.eq("bad_body_no_system", H.exists(dir .. "/system"), false)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.flash.keep_old")
    do
        local dir = H.case_dir("recovery-flash", "keep")
        H.mkdirp(dir .. "/system/kernel")
        H.write(dir .. "/system/boot.lua", "boot v1\n")
        H.write(dir .. "/system/kernel/a.lua", "a v1\n")
        local disk = release(dir, FILES)
        local real = H.real_fs()
        -- refuse the second file's staged move: the first file was already
        -- applied, so the rollback has to undo it by hash
        local fails = 1
        local flaky = H.fs({ overrides = { move = function(a, b)
            if fails > 0 and b:find("/system/kernel/a.lua", 1, true) then
                fails = fails - 1
                return false
            end
            return real.move(a, b)
        end } })
        local ok, _, lines = run({}, { root = dir, disk = disk, fs = flaky })
        H.check("keep_fail", ok == false, "accepted a refusing fs")
        H.has(lines, "FLASH_FAIL stage=apply err=move")
        H.eq("keep_boot_old", H.read(dir .. "/system/boot.lua"), "boot v1\n")
        H.eq("keep_kernel_old", H.read(dir .. "/system/kernel/a.lua"), "a v1\n")
        H.eq("keep_backup_consumed", H.exists(dir .. "/update.backup/boot.lua"), false)
        H.eq("keep_no_journal", H.exists(dir .. "/update.journal.1"), false)
        H.eq("keep_stage_gone", H.exists(dir .. "/update.stage"), false)
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.flash.rednet")
    do
        local dir = H.case_dir("recovery-flash", "net")
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/boot.lua", "boot v1\n")
        local msg, list = described(FILES, "7.0.0")
        msg = P.PREFIX .. " META " .. msg
        local sent = {}
        local items = { { 12, msg } }
        for i = 1, #list do
            local f = FILES[i]
            local want = #f[2]
            for offset = 0, want - 1, P.MAX_DATA do
                local chunk = f[2]:sub(offset + 1, offset + P.MAX_DATA)
                items[#items + 1] = { 12, P.PREFIX .. " DATA " .. f[1] .. " idx="
                    .. tostring(math.floor(offset / P.MAX_DATA)) .. " sha256="
                    .. P.dg(SHA, chunk) .. " " .. hex(chunk) }
            end
        end
        local ok, _, lines = run({}, { root = dir, rednet = scripted(items, sent), host = 12 })
        H.check("net_ok", ok == true, "rednet flash failed")
        H.has(lines, "FLASH_SOURCE kind=rednet host=12")
        H.has(lines, "FLASH_OK files=2 written=2 skipped=0 bytes=13")
        H.eq("net_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
        H.eq("net_kernel", H.read(dir .. "/system/kernel/a.lua"), "a v2\n")
        H.eq("net_request_count", #sent, 3)
        H.eq("net_first_request", sent[1], P.PREFIX .. " GET meta")
        H.eq("net_chunk_request", sent[2], P.PREFIX .. " GET boot.lua 0")
        H.eq("net_second_chunk_request", sent[3], P.PREFIX .. " GET kernel/a.lua 0")

        -- a corrupt first reply is retried; the good one is uses
        local dir2 = H.case_dir("recovery-flash", "net-retry")
        local sent2 = {}
        local items2 = { { 12, msg },
            { 12, P.PREFIX .. " DATA boot.lua idx=0 sha256=" .. P.dg(SHA, "bad")
                .. " " .. hex("bad") } }
        for i = 1, #FILES do
            items2[#items2 + 1] = { 12, P.PREFIX .. " DATA " .. FILES[i][1] .. " idx=0 sha256="
                .. P.dg(SHA, FILES[i][2]) .. " " .. hex(FILES[i][2]) }
        end
        local ok2, _, lines2 = run({}, { root = dir2, rednet = scripted(items2, sent2), host = 12 })
        H.check("net_retry_ok", ok2 == true, "a corrupt reply was not retried")
        H.has(lines2, "FLASH_OK files=2 written=2 skipped=0 bytes=13")
        H.eq("net_retry_requests", #sent2, 4)

        -- every reply corrupt: the flash stops before touching /system
        local dir3 = H.case_dir("recovery-flash", "net-bad")
        H.mkdirp(dir3 .. "/system")
        H.write(dir3 .. "/system/boot.lua", "boot v1\n")
        local bad = { { 12, msg } }
        for _ = 1, 4 do
            bad[#bad + 1] = { 12, P.PREFIX .. " DATA boot.lua idx=0 sha256="
                .. P.dg(SHA, "bad") .. " " .. hex(string.rep("X", #FILES[1][2])) }
        end
        local ok3, _, lines3 = run({}, { root = dir3, rednet = scripted(bad, {}), host = 12, max_tries = 2 })
        H.check("net_bad_fail", ok3 == false, "accepted a corrupt publisher")
        H.has(lines3, "FLASH_FAIL stage=stage err=digest")
        H.eq("net_bad_untouched", H.read(dir3 .. "/system/boot.lua"), "boot v1\n")

        -- a silent publisher
        local ok4, _, lines4 = run({}, { root = H.case_dir("recovery-flash", "net-silent"),
            rednet = scripted({}, {}), host = 12 })
        H.check("net_silent_fail", ok4 == false, "accepted a silent publisher")
        H.has(lines4, "FLASH_FAIL stage=meta err=timeout")
    end
end
