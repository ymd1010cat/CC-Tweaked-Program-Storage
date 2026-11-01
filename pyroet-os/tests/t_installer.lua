--[[- pyroet-os/tests/t_installer.lua -- application installer behaviour.

Covers kernel/installer.lua as behaviour: staging in /apps/.tmp-<name>, the
manifest and SHA256SUMS gate, the atomic replace with its copy fallback, rollback
(old version kept, temp deleted), the /system uninstall guard, and list() reading
both roots through the runtime's manifest parser.

Fault injection uses the instrumented fs from harness.lua (a refusing fs.move, a
partial fs.copy), so the failure paths are provoked without a second filesystem.

No non-ASCII bytes in this file.
]]

local installer = dofile("/system/kernel/installer.lua")

-- rpv/crypto.lua is loaded the way rpv/loader.lua loads it (`local M = ...`)
local function crypto()
    local mod = {}
    local chunk = loadfile("/system/rpv/crypto.lua")
    chunk(mod)
    return mod
end

return function(H)
    local sha = crypto().sha256
    -- crypto.sha256 returns the 32 raw digest bytes; the manifests are hex
    local function hex(data)
        return (tostring(data):gsub(".", function(c)
            return string.format("%02x", c:byte())
        end))
    end
    local function hx(text) return hex(sha(text)) end
    local manifest_for = function(name, version)
        return 'return { name = "' .. name .. '", version = "' .. version .. '" }'
    end

    local function package(dir, name, version, extra)
        H.rmrf(dir)
        H.mkdirp(dir)
        H.write(dir .. "/manifest.lua", manifest_for(name, version))
        H.write(dir .. "/main.lua", "return function() end\n")
        if extra then extra(dir) end
        return dir
    end

    local function new_inst(dir, opts)
        local o = opts or {}
        local fsx, calls = H.fs({ overrides = o.overrides })
        local log, lines = H.logger()
        local inst = installer.new({
            fs = fsx, log = log, sha = (o.sha ~= nil and o.sha or sha),
            media_root = dir .. "/media", apps_root = dir .. "/apps",
            system_root = dir .. "/system",
        })
        return inst, lines, calls, fsx
    end

    -- -----------------------------------------------------------------
    H.group("installer.medium")
    do
        local dir = H.case_dir("installer", "medium")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/hi.app", "hi", "1.2.3")
        local ok, report = inst:install("hi")
        H.check("ok", ok == true, "install failed: " .. tostring(report))
        H.table("report", report)
        H.eq("version", report.version, "1.2.3")
        H.eq("replaced", report.replaced, "false")
        H.eq("method", report.method, "move")
        H.eq("main_on_disk", H.read(dir .. "/apps/hi.app/main.lua"), "return function() end\n")
        H.eq("manifest_on_disk", H.read(dir .. "/apps/hi.app/manifest.lua"),
            manifest_for("hi", "1.2.3"))
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-hi"), "temp survived")
        H.has(lines, "INSTALL_OK name=hi version=1.2.3")
        H.lacks("no_fail", lines, "INSTALL_FAIL")
        H.lacks("no_replace", lines, "INSTALL_REPLACE")
        H.ascii_check("logs_ascii", table.concat(lines, "\n"))
    end

    -- -----------------------------------------------------------------
    H.group("installer.memory")
    do
        local dir = H.case_dir("installer", "memory")
        local fsx = H.fs()
        local log, lines = H.logger()
        local inst = installer.new({
            fs = fsx, log = log, sha = sha, apps_root = dir .. "/apps",
            packages = {
                chat = {
                    ["manifest.lua"] = manifest_for("chat", "0.9.0"),
                    ["main.lua"] = "return function(m, api) return api end\n",
                    ["lib/x.lua"] = "return 1\n",
                },
            },
        })
        local ok, report = inst:install("chat")
        H.check("ok", ok == true, "install failed: " .. tostring(report))
        H.eq("version", report.version, "0.9.0")
        H.eq("main", H.read(dir .. "/apps/chat.app/main.lua"),
            "return function(m, api) return api end\n")
        H.eq("nested", H.read(dir .. "/apps/chat.app/lib/x.lua"), "return 1\n")
        H.has(lines, "INSTALL_OK name=chat")
    end

    -- -----------------------------------------------------------------
    H.group("installer.missing_files")
    do
        local dir = H.case_dir("installer", "missing")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/nomain.app", "nomain", "1.0.0", function(pkg)
            H.real_fs().delete(pkg .. "/main.lua")
        end)
        local ok, err = inst:install("nomain")
        H.eq("ok", ok, "nil")
        H.contains("err", err, "main.lua")
        H.has(lines, "INSTALL_FAIL name=nomain")
        H.check("not_installed", not H.exists(dir .. "/apps/nomain.app"), "app landed anyway")
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-nomain"), "temp survived")

        package(dir .. "/media/nomanifest.app", "nomanifest", "1.0.0", function(pkg)
            H.real_fs().delete(pkg .. "/manifest.lua")
        end)
        local ok2 = inst:install("nomanifest")
        H.eq("ok2", ok2, "nil")
        H.check("not_installed2", not H.exists(dir .. "/apps/nomanifest.app"), "app landed anyway")
        H.has(lines, "INSTALL_FAIL name=nomanifest")
    end

    -- -----------------------------------------------------------------
    H.group("installer.no_source")
    do
        local dir = H.case_dir("installer", "nosource")
        local inst, lines = new_inst(dir)
        local ok, err = inst:install("ghost")
        H.eq("ok", ok, "nil")
        H.eq("err", err, "no_source")
        H.has(lines, "INSTALL_FAIL name=ghost err=no_source")
        H.check("no_apps_dir", not H.exists(dir .. "/apps/ghost.app"), "app landed anyway")
    end

    -- -----------------------------------------------------------------
    H.group("installer.bad_name")
    do
        local dir = H.case_dir("installer", "badname")
        local inst, lines = new_inst(dir)
        for _, name in ipairs({ "", "..", "a/b", "a" .. string.rep("x", 40) }) do
            local ok, err = inst:install(name)
            H.eq("rejected:" .. (name == "" and "empty" or name), ok, "nil")
            H.eq("err:" .. (name == "" and "empty" or #name), err, "bad name")
        end
        H.has(lines, "INSTALL_FAIL")
    end

    -- -----------------------------------------------------------------
    H.group("installer.manifest_name")
    do
        local dir = H.case_dir("installer", "name")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/real.app", "other", "1.0.0")
        local ok, err = inst:install("real")
        H.eq("ok", ok, "nil")
        H.contains("err", err, "manifest_name")
        H.has(lines, "INSTALL_FAIL name=real err=manifest_name:other")
        H.check("not_installed", not H.exists(dir .. "/apps/real.app"), "app landed anyway")
    end

    -- -----------------------------------------------------------------
    H.group("installer.replace")
    do
        local dir = H.case_dir("installer", "replace")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/app.app", "app", "1.0.0")
        H.check("first", inst:install("app") == true, "first install failed")
        H.lacks("no_replace_yet", lines, "INSTALL_REPLACE")

        package(dir .. "/media/app.app", "app", "2.0.0", function(pkg)
            H.write(pkg .. "/new.lua", "return 2\n")
        end)
        local ok, report = inst:install("app")
        H.check("second", ok == true, "replace failed")
        H.eq("version", report.version, "2.0.0")
        H.eq("replaced", report.replaced, "true")
        H.has(lines, "INSTALL_REPLACE name=app")
        H.eq("new_file", H.read(dir .. "/apps/app.app/new.lua"), "return 2\n")
        H.eq("manifest", H.read(dir .. "/apps/app.app/manifest.lua"),
            manifest_for("app", "2.0.0"))
    end

    -- -----------------------------------------------------------------
    H.group("installer.rollback_keeps_old")
    do
        local dir = H.case_dir("installer", "rollback")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/keep.app", "keep", "1.0.0")
        H.check("seed", inst:install("keep") == true, "seed failed")
        local old_main = H.read(dir .. "/apps/keep.app/main.lua")

        -- bad package: hash manifest that cannot match
        package(dir .. "/media/keep.app", "keep", "9.9.9", function(pkg)
            H.write(pkg .. "/SHA256SUMS", H.HEX64 .. "  main.lua\n")
        end)
        local ok, err = inst:install("keep")
        H.eq("ok", ok, "nil")
        H.contains("err", err, "digest")
        H.has(lines, "INSTALL_HASH_BAD file=main.lua")
        H.has(lines, "INSTALL_FAIL name=keep err=digest main.lua")
        -- the old version is untouched and the replace never started
        H.eq("old_manifest", H.read(dir .. "/apps/keep.app/manifest.lua"),
            manifest_for("keep", "1.0.0"))
        H.eq("old_main", H.read(dir .. "/apps/keep.app/main.lua"), old_main)
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-keep"), "temp survived")
        H.eq("replace_count", H.count(lines, "INSTALL_REPLACE"), 0)
    end

    -- -----------------------------------------------------------------
    H.group("installer.sums")
    do
        local dir = H.case_dir("installer", "sums")
        local inst, lines = new_inst(dir)
        local main = "return function() end\n"
        local sums = hx(main) .. "  main.lua\n"
            .. hx(manifest_for("ok", "1.0.0")) .. "  manifest.lua\n"
        package(dir .. "/media/ok.app", "ok", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", sums)
        end)
        local ok, report = inst:install("ok")
        H.check("ok", ok == true, "hash check rejected a good package: " .. tostring(report))
        H.eq("sums_installed", H.read(dir .. "/apps/ok.app/SHA256SUMS"), sums)

        -- one wrong digest
        package(dir .. "/media/bad.app", "bad", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", H.HEX64 .. "  main.lua\n"
                .. hx(manifest_for("bad", "1.0.0")) .. "  manifest.lua\n")
        end)
        local ok2, err2 = inst:install("bad")
        H.eq("bad_ok", ok2, "nil")
        H.contains("bad_err", err2, "digest main.lua")
        H.has(lines, "INSTALL_HASH_BAD file=main.lua")

        -- a file the manifest does not mention
        package(dir .. "/media/extra.app", "extra", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", hx("return function() end\n") .. "  main.lua\n"
                .. hx(manifest_for("extra", "1.0.0")) .. "  manifest.lua\n")
            H.write(pkg .. "/stowaway.lua", "return 3\n")
        end)
        local ok3 = inst:install("extra")
        H.eq("extra_ok", ok3, "nil")
        H.has(lines, "INSTALL_HASH_BAD file=stowaway.lua reason=unlisted")

        -- malformed line, duplicate entry, empty file
        package(dir .. "/media/malformed.app", "malformed", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", "not-a-digest  main.lua\n")
        end)
        H.eq("malformed_ok", inst:install("malformed"), "nil")
        H.has(lines, "INSTALL_HASH_BAD file=SHA256SUMS line=1")

        package(dir .. "/media/dupe.app", "dupe", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", H.HEX64 .. "  main.lua\n" .. H.HEX64 .. "  main.lua\n")
        end)
        H.eq("dupe_ok", inst:install("dupe"), "nil")
        H.has(lines, "INSTALL_HASH_BAD file=main.lua reason=duplicate")

        package(dir .. "/media/empty.app", "empty", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", "")
        end)
        H.eq("empty_ok", inst:install("empty"), "nil")
        H.has(lines, "INSTALL_HASH_BAD file=SHA256SUMS reason=empty")

        -- listed file missing from the package
        package(dir .. "/media/gone.app", "gone", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", H.HEX64 .. "  missing.lua\n")
        end)
        H.eq("gone_ok", inst:install("gone"), "nil")
        H.has(lines, "INSTALL_HASH_BAD file=missing.lua reason=missing")
    end

    -- -----------------------------------------------------------------
    H.group("installer.hash_unavailable")
    do
        local dir = H.case_dir("installer", "nohash")
        local fsx = H.fs()
        local log, lines = H.logger()
        local inst = installer.new({
            fs = fsx, log = log, sha = false, crypto_path = dir .. "/nope.lua",
            media_root = dir .. "/media", apps_root = dir .. "/apps",
        })
        H.eq("sha", inst.sha, "nil")
        package(dir .. "/media/sum.app", "sum", "1.0.0", function(pkg)
            H.write(pkg .. "/SHA256SUMS", H.HEX64 .. "  main.lua\n")
        end)
        local ok, err = inst:install("sum")
        H.eq("ok", ok, "nil")
        H.eq("err", err, "no sha256")
        H.has(lines, "INSTALL_HASH_UNAVAILABLE file=SHA256SUMS")
        H.check("not_installed", not H.exists(dir .. "/apps/sum.app"), "app landed anyway")
    end

    -- -----------------------------------------------------------------
    H.group("installer.copy_fallback")
    do
        local dir = H.case_dir("installer", "fallback")
        local inst, lines, calls = new_inst(dir, { overrides = { move = function() return nil end } })
        package(dir .. "/media/mv.app", "mv", "1.0.0")
        local ok, report = inst:install("mv")
        H.check("ok", ok == true, "fallback install failed: " .. tostring(report))
        H.eq("method", report.method, "copy")
        H.has(lines, "INSTALL_MOVE_FALLBACK")
        H.eq("main", H.read(dir .. "/apps/mv.app/main.lua"), "return function() end\n")
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-mv"), "temp survived")
        H.ge("move_attempted", H.calls_to(calls, "move"), 1)
    end

    -- -----------------------------------------------------------------
    H.group("installer.copy_partial")
    do
        local dir = H.case_dir("installer", "partial")
        local real = H.real_fs()
        local overrides = {
            move = function() return nil end,
            copy = function(from, to)
                -- only the commit copy is sabotaged; staging still works
                if not tostring(from):find(".tmp-", 1, true) then return real.copy(from, to) end
                H.mkdirp(to)   -- half a copy: one file, then "success"
                real.copy(from .. "/manifest.lua", to .. "/manifest.lua")
                return true
            end,
        }
        local inst, lines = new_inst(dir, { overrides = overrides })
        package(dir .. "/media/half.app", "half", "1.0.0")
        local ok, err = inst:install("half")
        H.eq("ok", ok, "nil")
        H.contains("err", err, "count")
        H.has(lines, "INSTALL_FAIL name=half")
        H.check("target_removed", not H.exists(dir .. "/apps/half.app"), "half copy left behind")
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-half"), "temp survived")
    end

    -- -----------------------------------------------------------------
    H.group("installer.copy_fails")
    do
        local dir = H.case_dir("installer", "copyfail")
        local overrides = { copy = function() return nil end }
        local inst, lines = new_inst(dir, { overrides = overrides })
        package(dir .. "/media/cf.app", "cf", "1.0.0")
        local ok, err = inst:install("cf")
        H.eq("ok", ok, "nil")
        H.contains("err", err, "copy failed")
        H.has(lines, "INSTALL_FAIL name=cf")
        H.check("not_installed", not H.exists(dir .. "/apps/cf.app"), "app landed anyway")
        H.check("temp_gone", not H.exists(dir .. "/apps/.tmp-cf"), "temp survived")
    end

    -- -----------------------------------------------------------------
    H.group("installer.uninstall")
    do
        local dir = H.case_dir("installer", "uninstall")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/bye.app", "bye", "1.0.0")
        H.check("seed", inst:install("bye") == true, "seed failed")
        local ok = inst:uninstall("bye")
        H.check("ok", ok == true, "uninstall failed")
        H.check("gone", not H.exists(dir .. "/apps/bye.app"), "app survived")
        H.has(lines, "INSTALL_REMOVE name=bye")
        H.lacks("no_denied", lines, "INSTALL_REMOVE_DENIED")

        -- a system app is not removable
        package(dir .. "/system/sys.app", "sys", "1.0.0")
        local ok2, err2 = inst:uninstall("sys")
        H.eq("sys_ok", ok2, "nil")
        H.eq("sys_err", err2, "system app")
        H.has(lines, "INSTALL_REMOVE_DENIED name=sys reason=system")
        H.check("sys_intact", H.exists(dir .. "/system/sys.app/main.lua"), "system app damaged")

        -- missing package
        local ok3, err3 = inst:uninstall("nope")
        H.eq("nope_ok", ok3, "nil")
        H.eq("nope_err", err3, "not installed")
        H.has(lines, "INSTALL_REMOVE_MISSING name=nope")

        -- path tricks never reach the file system
        for _, name in ipairs({ "..", "a/b", "/system/sys" }) do
            local okx = inst:uninstall(name)
            H.eq("bad:" .. name, okx, "nil")
        end
        H.check("sys_still_there", H.exists(dir .. "/system/sys.app/manifest.lua"),
            "system app damaged by a bad name")
        H.eq("denied_count", H.count(lines, "reason=bad_name"), 3)
    end

    -- -----------------------------------------------------------------
    H.group("installer.list")
    do
        local dir = H.case_dir("installer", "list")
        local inst, lines = new_inst(dir)
        package(dir .. "/media/one.app", "one", "1.0.0")
        package(dir .. "/media/one2.app", "one", "1.0.0")
        package(dir .. "/system/sys.app", "sys", "2.1.0")
        H.check("install_one", inst:install("one") == true, "install failed")
        -- a directory that is not a valid package is still listed, with "?"
        H.mkdirp(dir .. "/apps/broken.app")

        local entries = inst:list()
        H.table("entries", entries)
        H.eq("count", #entries, 3)
        H.eq("first_name", entries[1].name, "broken")
        H.eq("first_version", entries[1].version, "?")
        H.eq("first_ok", entries[1].ok, "false")
        H.truthy("first_error", entries[1].error)
        H.eq("second_name", entries[2].name, "one")
        H.eq("second_version", entries[2].version, "1.0.0")
        H.eq("second_source", entries[2].source, "apps")
        H.eq("third_name", entries[3].name, "sys")
        H.eq("third_source", entries[3].source, "system")
        H.eq("third_version", entries[3].version, "2.1.0")
        H.has(lines, "INSTALL_LIST count=3 apps=2")
        H.lacks("no_missing_root", lines, "INSTALL_LIST_MISSING")
    end

    -- -----------------------------------------------------------------
    H.group("installer.default_sha")
    do
        local dir = H.case_dir("installer", "defaultsha")
        local inst = installer.new({ fs = H.fs(), apps_root = dir .. "/apps" })
        H.check("sha_resolved", type(inst.sha) == "function", "type=" .. type(inst.sha))
        H.eq("sha_matches_crypto", hex(inst.sha("abc")), hex(sha("abc")))
        H.eq("empty_digest", hex(inst.sha("")), hex(sha("")))
    end

    -- -----------------------------------------------------------------
    H.group("installer.instances_are_independent")
    do
        local dir = H.case_dir("installer", "independent")
        local a = installer.new({ fs = H.fs(), apps_root = dir .. "/a",
            system_root = dir .. "/sys-a" })
        local b = installer.new({ fs = H.fs(), apps_root = dir .. "/b",
            system_root = dir .. "/sys-b", packages = {
            x = { ["manifest.lua"] = manifest_for("x", "1.0.0"), ["main.lua"] = "return 1\n" },
        } })
        H.eq("b_has_x", b:install("x") ~= nil, "true")
        H.eq("a_sees_nothing", #a:list(), 0)
        H.eq("b_sees_one", #b:list(), 1)
        H.eq("a_packages", type(a.packages.x), "nil")
    end

    -- -----------------------------------------------------------------
    H.group("installer.size")
    do
        -- A declared size is checked against the bytes that actually landed, in
        -- both places a package can declare one (manifest `size` = package total
        -- without manifest.lua, SHA256SUMS third column = one file). Neither is
        -- required, so a package that declares nothing still installs.
        local dir = H.case_dir("installer", "size")
        local inst, lines = new_inst(dir)
        local main = "return function() end\n"
        local len = #main

        local function pkg(name, opts)
            local o = opts or {}
            local path = dir .. "/media/" .. name .. ".app"
            H.rmrf(path)
            H.mkdirp(path)
            local manifest = o.manifest or manifest_for(name, "1.0.0")
            H.write(path .. "/manifest.lua", manifest)
            H.write(path .. "/main.lua", o.main or main)
            if o.sums then
                local out = {}
                for i = 1, #o.sums do
                    local row = o.sums[i]
                    local text = row.digest or hx(row.file == "main.lua" and main or manifest)
                    if row.size ~= nil then text = text .. "  " .. tostring(row.size) end
                    out[#out + 1] = text .. "  " .. row.file
                end
                H.write(path .. "/SHA256SUMS", table.concat(out, "\n") .. "\n")
            end
            return path
        end

        -- 1. a per-file size that matches: still installs
        pkg("sized", { sums = {
            { file = "main.lua", size = #main },
            { file = "manifest.lua" },
        } })
        local ok1, report1 = inst:install("sized")
        H.check("sized_ok", ok1 == true, "an exact size was refused: " .. tostring(report1))
        H.eq("sized_installed", H.exists(dir .. "/apps/sized.app/main.lua"), true)

        -- 2. short: the sums promise more bytes than the file has
        pkg("sums_short", { sums = {
            { file = "main.lua", size = len + 4 },
            { file = "manifest.lua" },
        } })
        local ok2, err2 = inst:install("sums_short")
        H.eq("sums_short_ok", ok2, "nil")
        H.eq("sums_short_err", err2, "size main.lua")
        H.has(lines, "INSTALL_SIZE_BAD file=main.lua got=" .. len .. " want=" .. (len + 4))
        H.has(lines, "INSTALL_FAIL name=sums_short err=size main.lua")
        H.eq("sums_short_not_installed", H.exists(dir .. "/apps/sums_short.app"), false)
        H.check("sums_short_temp_gone", not H.exists(dir .. "/apps/.tmp-sums_short"),
            "temp survived")

        -- 3. long: the sums promise fewer bytes than the file has
        pkg("sums_long", { sums = {
            { file = "main.lua", size = len - 5 },
            { file = "manifest.lua" },
        } })
        local ok3, err3 = inst:install("sums_long")
        H.eq("sums_long_ok", ok3, "nil")
        H.eq("sums_long_err", err3, "size main.lua")
        H.has(lines, "INSTALL_SIZE_BAD file=main.lua got=" .. len .. " want=" .. (len - 5))
        H.eq("sums_long_not_installed", H.exists(dir .. "/apps/sums_long.app"), false)

        -- 4. the size may also be the last column of a sums line
        pkg("sums_tail", { sums = {
            { file = "main.lua", size = len + 1 },
            { file = "manifest.lua" },
        } })
        -- rewrite the file with the size at the end instead of the middle
        H.write(dir .. "/media/sums_tail.app/SHA256SUMS",
            hx(main) .. "  main.lua  " .. tostring(len + 1) .. "\n"
            .. hx(manifest_for("sums_tail", "1.0.0")) .. "  manifest.lua\n")
        local ok4, err4 = inst:install("sums_tail")
        H.eq("sums_tail_ok", ok4, "nil")
        H.eq("sums_tail_err", err4, "size main.lua")
        H.has(lines, "INSTALL_SIZE_BAD file=main.lua got=" .. len .. " want=" .. (len + 1))

        -- 5. a package total in the manifest: main.lua is all it ships
        pkg("total_ok", { manifest = 'return { name = "total_ok", version = "1.0.0", size = '
            .. tostring(len) .. ' }' })
        H.check("total_ok_install", inst:install("total_ok") == true,
            "an exact package total was refused")

        -- 6. and a total that is not the payload is a refusal
        pkg("total_bad", { manifest = 'return { name = "total_bad", version = "1.0.0", size = '
            .. tostring(len + 9) .. ' }' })
        local ok6, err6 = inst:install("total_bad")
        H.eq("total_bad_ok", ok6, "nil")
        H.contains("total_bad_err", err6, "size " .. len .. "/" .. (len + 9))
        H.has(lines, "INSTALL_SIZE_BAD scope=package got=" .. len .. " want=" .. (len + 9))
        H.eq("total_bad_not_installed", H.exists(dir .. "/apps/total_bad.app"), false)

        -- 7. an unparsable declaration is refused instead of ignored
        pkg("total_junk", {
            manifest = 'return { name = "total_junk", version = "1.0.0", size = "big" }',
        })
        local ok7, err7 = inst:install("total_junk")
        H.eq("total_junk_ok", ok7, "nil")
        H.eq("total_junk_err", err7, "bad size")
        H.has(lines, "INSTALL_SIZE_BAD scope=package reason=declared value=big")

        -- 8. no declaration anywhere: the digest-only path still works, and a
        -- fresh logger proves it does so without a single size complaint
        pkg("plain", { sums = { { file = "main.lua" }, { file = "manifest.lua" } } })
        local inst2, lines2 = new_inst(dir)
        H.check("plain_ok", inst2:install("plain") == true,
            "a package without any size was refused")
        H.eq("plain_installed", H.exists(dir .. "/apps/plain.app/manifest.lua"), true)
        H.lacks("plain_no_size_line", lines2, "INSTALL_SIZE_BAD")

        -- 9. the total counts every file except manifest.lua, SHA256SUMS included.
        -- The declaration lives inside the package, so the number and the sums
        -- line that proves it depend on each other -- two passes settle it, which
        -- is also what a packaging tool has to do.
        local manifest_text, sums_text, total = nil, nil, #main
        for _ = 1, 2 do
            manifest_text = 'return { name = "total_sums", version = "1.0.0", size = '
                .. tostring(total) .. ' }'
            sums_text = hx(main) .. "  main.lua\n"
                .. hx(manifest_text) .. "  manifest.lua\n"
            total = #main + #sums_text
        end
        H.eq("total_sums_value", total, #main + #sums_text)
        pkg("total_sums", { manifest = manifest_text })
        H.write(dir .. "/media/total_sums.app/SHA256SUMS", sums_text)
        H.check("total_with_sums", inst:install("total_sums") == true,
            "the package total did not include SHA256SUMS")
    end
end
