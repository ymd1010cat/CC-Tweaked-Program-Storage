--[[- pyroet-os/tests/t_recovery_bootstrap.lua -- recovery/bootstrap.lua: pushed
META + PUSH DATA file sets, out-of-order and corrupt chunks, timeout, dead link,
manifest/digest failures, and "a failed push keeps the old system".

The target is always <root>/system (no slot, no slot pointer).
No non-ASCII bytes in this file.
]]

local P = dofile("/recovery/proto.lua")
local BOOT = assert(loadfile("/recovery/bootstrap.lua"))()

return function(H)
    local F = H.real_fs()
    local SHA = P.sha({})

    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end

    local function file_list(files)
        local list = {}
        for i = 1, #files do
            list[i] = { relpath = files[i][1], size = #files[i][2],
                sha256 = P.dg(SHA, files[i][2]) }
        end
        return list
    end

    local function push_meta(files, version)
        local list = file_list(files)
        local text = P.PREFIX .. " PUSH meta version=" .. tostring(version or "3.1.0")
            .. " manifest_sha=" .. P.manifest_sha(SHA, list)
            .. " files=" .. tostring(#list)
        for i = 1, #list do
            text = text .. "\n" .. list[i].relpath .. " " .. tostring(list[i].size)
                .. " " .. list[i].sha256
        end
        return text
    end

    local function push_data(relpath, index, chunk, digest)
        return P.PREFIX .. " PUSH DATA " .. relpath .. " idx=" .. tostring(index)
            .. " sha256=" .. tostring(digest or P.dg(SHA, chunk)) .. " " .. hex(chunk)
    end

    local function scripted(items)
        local i = 0
        local net = { calls = 0 }
        net.receive = function()
            i = i + 1
            net.calls = net.calls + 1
            local item = items[i]
            if item == "raise" then error("modem gone") end
            if item == nil then return nil end
            return item[1], item[2]
        end
        return net
    end

    local function run(opts)
        local log, lines = H.logger()
        local base = { fs = F, print = log, sha = SHA }
        for k, v in pairs(opts or {}) do base[k] = v end
        local ok = BOOT.main(base)
        return ok, log, lines
    end

    local FILES = { { "boot.lua", "boot v2\n" }, { "kernel/a.lua", "a v2\n" } }
    local META = push_meta(FILES)

    -- a machine already running the old set
    local function old_machine(name)
        local dir = H.case_dir("recovery-boot", name)
        H.mkdirp(dir .. "/system/kernel")
        H.write(dir .. "/system/boot.lua", "boot v1\n")
        H.write(dir .. "/system/kernel/a.lua", "a v1\n")
        return dir
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.bootstrap.push")
    do
        local dir = old_machine("ok")
        local net = scripted({
            { 4, META },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
        })
        local ok, _, lines = run({ root = dir, rednet = net })
        H.check("push_ok", ok == true, "bootstrap failed")
        H.has(lines, "BOOTSTRAP_TARGET path=" .. dir .. "/system state=present")
        H.has(lines, "BOOTSTRAP_META version=3.1.0 files=2 manifest_sha=")
        H.has(lines, "BOOTSTRAP_OK files=2 written=2 skipped=0 bytes=13")
        H.eq("push_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
        H.eq("push_kernel", H.read(dir .. "/system/kernel/a.lua"), "a v2\n")
        H.eq("push_backup_boot", H.read(dir .. "/update.backup/boot.lua"), "boot v1\n")
        H.eq("push_journal", H.exists(dir .. "/update.journal.1"), true)
        H.eq("push_receives", net.calls, 3)

        -- a blank machine has no /system: the push creates it
        local blank = H.case_dir("recovery-boot", "blank")
        local net2 = scripted({
            { 4, META },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
        })
        local ok2, _, lines2 = run({ root = blank, rednet = net2 })
        H.check("push_blank_ok", ok2 == true, "bootstrap failed on a blank machine")
        H.has(lines2, "BOOTSTRAP_TARGET path=" .. blank .. "/system state=missing")
        H.eq("push_blank_boot", H.read(blank .. "/system/boot.lua"), "boot v2\n")

        -- the same set again writes nothing
        local net3 = scripted({
            { 4, META },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
        })
        local ok3, _, lines3 = run({ root = dir, rednet = net3 })
        H.check("push_again_ok", ok3 == true, "second push failed")
        H.has(lines3, "BOOTSTRAP_OK files=2 written=0 skipped=2 bytes=0")
        H.eq("push_again_backup", H.read(dir .. "/update.backup/boot.lua"), "boot v1\n")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.bootstrap.order")
    do
        -- chunks for the second file arrive before the first one's
        local dir = old_machine("order")
        local net = scripted({
            { 4, META },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
        })
        local ok, _, lines = run({ root = dir, rednet = net })
        H.check("order_ok", ok == true, "out-of-order chunks were not buffered")
        H.eq("order_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
        H.eq("order_kernel", H.read(dir .. "/system/kernel/a.lua"), "a v2\n")
        H.eq("order_receives", net.calls, 3)
        H.has(lines, "BOOTSTRAP_OK files=2 written=2 skipped=0 bytes=13")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.bootstrap.retry")
    do
        -- the publisher resends a chunk after a corrupt one; the corrupt packet
        -- is dropped and counted as a miss, the good one is used
        local dir = old_machine("retry")
        local net = scripted({
            { 4, META },
            { 4, push_data("boot.lua", 0, "boot v2\n", P.dg(SHA, "bad")) },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
        })
        local ok, _, lines = run({ root = dir, rednet = net })
        H.check("retry_ok", ok == true, "a corrupt chunk was not recovered")
        H.eq("retry_receives", net.calls, 4)
        H.eq("retry_boot", H.read(dir .. "/system/boot.lua"), "boot v2\n")
        H.has(lines, "BOOTSTRAP_OK files=2 written=2 skipped=0 bytes=13")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.bootstrap.fail")
    do
        local dir = old_machine("timeout")
        local net = scripted({ { 4, META } })
        local ok, _, lines = run({ root = dir, rednet = net, max_tries = 2 })
        H.check("timeout_fail", ok == false, "accepted a stalled push")
        H.has(lines, "BOOTSTRAP_FAIL stage=stage err=timeout")
        H.eq("timeout_old_boot", H.read(dir .. "/system/boot.lua"), "boot v1\n")
        H.eq("timeout_no_journal", H.exists(dir .. "/update.journal.1"), false)

        local dead = H.case_dir("recovery-boot", "dead")
        local net2 = scripted({ { 4, META }, "raise", "raise" })
        local ok2, _, lines2 = run({ root = dead, rednet = net2, max_tries = 2 })
        H.check("dead_fail", ok2 == false, "accepted a dead link")
        H.has(lines2, "BOOTSTRAP_FAIL stage=stage err=receive")

        local silent = H.case_dir("recovery-boot", "silent")
        local ok3, _, lines3 = run({ root = silent, rednet = scripted({}), max_tries = 2 })
        H.check("meta_fail", ok3 == false, "accepted a silent publisher")
        H.has(lines3, "BOOTSTRAP_FAIL stage=meta err=timeout")

        local bad_meta = H.case_dir("recovery-boot", "bad-meta")
        local bad = META:gsub("version=%S+", "version=9/9")
        local ok4, _, lines4 = run({ root = bad_meta, rednet = scripted({ { 4, (bad) } }), max_tries = 2 })
        H.check("bad_meta_fail", ok4 == false, "accepted a bad META")
        H.has(lines4, "BOOTSTRAP_FAIL stage=meta err=version")

        local mismatch = H.case_dir("recovery-boot", "manifest")
        local wrong = META:gsub("manifest_sha=%x+", "manifest_sha=" .. string.rep("0", 64))
        local ok5, _, lines5 = run({ root = mismatch,
            rednet = scripted({ { 4, (wrong) } }), max_tries = 2 })
        H.check("manifest_fail", ok5 == false, "accepted a wrong manifest digest")
        H.has(lines5, "BOOTSTRAP_FAIL stage=meta err=manifest_sha_mismatch")

        local no_rednet = H.case_dir("recovery-boot", "no-net")
        local ok6, _, lines6 = run({ root = no_rednet, rednet = {} })
        H.check("no_rednet_fail", ok6 == false, "accepted an empty rednet table")
        H.has(lines6, "BOOTSTRAP_FAIL stage=prepare err=rednet")
    end

    -- ---------------------------------------------------------------------
    H.group("recovery.bootstrap.keep_old")
    do
        local dir = old_machine("keep")
        local real = H.real_fs()
        local fails = 1
        local flaky = H.fs({ overrides = { move = function(a, b)
            if fails > 0 and b:find("/system/kernel/a.lua", 1, true) then
                fails = fails - 1
                return false
            end
            return real.move(a, b)
        end } })
        local net = scripted({
            { 4, META },
            { 4, push_data("boot.lua", 0, "boot v2\n") },
            { 4, push_data("kernel/a.lua", 0, "a v2\n") },
        })
        local ok, _, lines = run({ root = dir, rednet = net, fs = flaky })
        H.check("keep_fail", ok == false, "accepted a refusing fs")
        H.has(lines, "BOOTSTRAP_FAIL stage=apply err=move")
        H.eq("keep_boot_old", H.read(dir .. "/system/boot.lua"), "boot v1\n")
        H.eq("keep_kernel_old", H.read(dir .. "/system/kernel/a.lua"), "a v1\n")
        H.eq("keep_no_journal", H.exists(dir .. "/update.journal.1"), false)
        H.eq("keep_stage_gone", H.exists(dir .. "/update.stage"), false)
    end
end
