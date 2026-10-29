--[[- pyroet-os/tests/t_permissions.lua -- first start capability decisions:
-- parsing, persistence, prompt/ask, bad files, reset, and the runtime stub.

The permission table is exercised twice: as a pure module (parse decisions out of
text, no fs) and attached to the real app runtime, where a denied capability has
to answer exactly like an undeclared one -- `nil, "capability denied: <cap>"` --
while the app keeps running.

No non-ASCII bytes in this file.
]]

local PERMS = dofile("/system/kernel/permissions.lua")
local APPS = dofile("/system/kernel/apps.lua")

-- an app body that reports what each capability answered; the paths are wired
-- in per case, so the read really hits the file system
local function probe_main(data_path, out_path)
    return "return function(manifest, api)\n"
        .. "    local read_ok = api.fs.read(\"" .. data_path .. "\")\n"
        .. "    local write_ok = api.fs.write(\"" .. out_path .. "\", \"payload\")\n"
        .. "    api.log(\"read=\" .. tostring(read_ok ~= nil)"
        .. " .. \" write=\" .. tostring(write_ok ~= nil))\n"
        .. "    api.yield()\n"
        .. "end\n"
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("perms.parse")
    do
        local p = PERMS.new({})
        local decisions = p:parse("fs.read=granted\nfs.write=denied\n")
        H.table("parsed", decisions)
        H.eq("granted_true", decisions and decisions["fs.read"], true)
        H.eq("denied_false", decisions and decisions["fs.write"], false)

        local with_comments = p:parse("# PYROET-PERMS-1 app=probe\n\nfs.read=granted\n")
        H.eq("comments_skipped", with_comments and with_comments["fs.read"], true)

        local crlf = p:parse("fs.read=granted\r\nnet.rpv=denied\r\n")
        H.eq("crlf_read", crlf and crlf["fs.read"], true)
        H.eq("crlf_net", crlf and crlf["net.rpv"], false)

        local spaced = p:parse("  fs.read = granted  \n")
        H.eq("spaces_tolerated", spaced and spaced["fs.read"], true)

        local dup = p:parse("fs.read=granted\nfs.read=denied\n")
        H.eq("last_line_wins", dup and dup["fs.read"], false)

        local bad, why = p:parse("fs.read\n")
        H.eq("missing_value_rejected", bad, nil)
        H.contains("missing_value_reason", why, "expected cap=value")
        H.contains("missing_value_line", why, "line 1")

        local unknown, uwhy = p:parse("root=granted\n")
        H.eq("unknown_cap_rejected", unknown, nil)
        H.contains("unknown_cap_reason", uwhy, "unknown capability 'root'")

        local value, vwhy = p:parse("fs.read=maybe\n")
        H.eq("bad_value_rejected", value, nil)
        H.contains("bad_value_reason", vwhy, "bad value 'maybe'")

        local empty, ewhy = p:parse("")
        H.eq("empty_rejected", empty, nil)
        H.eq("empty_reason", ewhy, "no decisions")

        local comments_only, cwhy = p:parse("# nothing here\n")
        H.eq("comments_only_rejected", comments_only, nil)
        H.eq("comments_only_reason", cwhy, "no decisions")

        -- a caller can narrow the known set (apps.lua hands its own in)
        local narrowed, nwhy = p:parse("net.rpv=granted\n", { ["fs.read"] = true })
        H.eq("narrow_rejected", narrowed, nil)
        H.contains("narrow_reason", nwhy, "unknown capability 'net.rpv'")

        H.eq("cap_list_matches_runtime", #PERMS.CAPS, #APPS.CAPS)
        for i = 1, #APPS.CAPS do
            H.eq("cap_" .. tostring(i) .. "_same", PERMS.CAPS[i], APPS.CAPS[i])
        end
        H.eq("default_root", PERMS.ROOT, "/etc/perms")
        H.eq("file_header", PERMS.FILE_HEADER, "# PYROET-PERMS-1")
        local lines = PERMS.prompt_lines("probe", { "fs.read" }, 26, 20)
        H.eq("fit_pads", PERMS.fit("ab", 4), "ab  ")
        H.eq("prompt_first", lines[1]:sub(1, 18), "Permission request")
        H.ascii_check("prompt_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("perms.persist")
    do
        local dir = H.case_dir("perms", "persist")
        local root = dir .. "/etc/perms"
        local log, lines = H.logger()
        local p = PERMS.new({ fs = H.real_fs(), log = log, root = root })

        H.eq("path", p:path("probe"), root .. "/probe.cfg")
        H.eq("trailing_slash_trimmed", PERMS.new({ root = root .. "/" }):path("x"),
            root .. "/x.cfg")

        local decisions = { ["fs.read"] = true, ["fs.write"] = false }
        local saved = p:save("probe", decisions, { order = { "fs.read", "fs.write" } })
        H.eq("saved", saved, true)
        local text = H.read(root .. "/probe.cfg")
        H.contains("file_header", text, "# PYROET-PERMS-1 app=probe")
        H.contains("file_granted", text, "fs.read=granted")
        H.contains("file_denied", text, "fs.write=denied")
        H.has(lines, "PERMS_SAVED app=probe")
        H.has(lines, "granted=1 denied=1")

        local loaded, source = p:load("probe")
        H.eq("load_source", source, "file")
        H.eq("load_granted", loaded and loaded["fs.read"], true)
        H.eq("load_denied", loaded and loaded["fs.write"], false)

        local missing, msource = p:load("ghost")
        H.eq("missing_load", missing, nil)
        H.eq("missing_source", msource, "none")

        local listed = p:list()
        H.eq("list_count", #listed, 1)
        H.eq("list_name", listed[1], "probe")

        local reset = PERMS.reset("probe", { fs = H.real_fs(), root = root, log = log })
        H.eq("reset_ok", reset, true)
        H.eq("file_gone", H.exists(root .. "/probe.cfg"), false)
        H.has(lines, "PERMS_RESET app=probe")
        H.has(lines, "existed=true")
        PERMS.reset("probe", { fs = H.real_fs(), root = root, log = log })
        H.has(lines, "existed=false")

        -- prefetch reads what is decided, counts what is not, and never writes
        local apps = {
            { name = "one", dir = "/system/one.app", manifest = { capabilities = { "fs.read" } } },
            { name = "two", dir = "/system/two.app", manifest = { capabilities = { "fs.read" } } },
            { name = "three", dir = "/etc/three.app", manifest = { capabilities = {} } },
            { name = "four", dir = "/system/four.app", manifest = { capabilities = { "net.rpv" } } },
        }
        p:save("one", { ["fs.read"] = true }, { order = { "fs.read" } })
        H.write(root .. "/two.cfg", "this is not a decision file\n")
        local stats = p:prefetch(apps)
        H.eq("prefetch_apps", stats.apps, 3)
        H.eq("prefetch_loaded", stats.loaded, 1)
        H.eq("prefetch_bad", stats.bad, 1)
        H.eq("prefetch_pending", stats.pending, 1)
        H.has(lines, "PERMS_BAD_FILE app=two")
        H.eq("prefetch_did_not_write", H.exists(root .. "/four.cfg"), false)
    end

    -- -----------------------------------------------------------------
    H.group("perms.prompt")
    do
        local dir = H.case_dir("perms", "prompt")
        local root = dir .. "/etc/perms"

        -- all granted
        local log, lines = H.logger()
        local p = PERMS.new({ fs = H.real_fs(), log = log, root = root,
            ask = function() return true end })
        local decisions, info = p:ensure("net", { "net.rpv", "fs.read" })
        H.eq("all_source", info.source, "prompt")
        H.eq("all_prompted", info.prompted, true)
        H.eq("all_granted_count", info.granted, 2)
        H.eq("all_rpv", decisions["net.rpv"], true)
        H.eq("all_fs", decisions["fs.read"], true)
        H.has(lines, "PERMS_PROMPT app=net caps=net.rpv,fs.read")
        H.has(lines, "PERMS_DECISION app=net cap=net.rpv granted=true")
        H.has(lines, "PERMS_DECISION app=net cap=fs.read granted=true")
        H.eq("all_prompt_once", p:count("PERMS_PROMPT"), 1)
        H.eq("all_file", H.exists(root .. "/net.cfg"), true)

        local again, again_info = p:ensure("net", { "net.rpv", "fs.read" })
        H.eq("cache_source", again_info.source, "cache")
        H.eq("cache_same", again["net.rpv"], true)
        H.eq("cache_no_prompt", p:count("PERMS_PROMPT"), 1)

        -- a fresh instance reads the file instead of asking
        local log2, lines2 = H.logger()
        local p2 = PERMS.new({ fs = H.real_fs(), log = log2, root = root,
            ask = function() error("must not ask again") end })
        local from_file, file_info = p2:ensure("net", { "net.rpv", "fs.read" })
        H.eq("file_source", file_info.source, "file")
        H.eq("file_no_prompt", H.count(lines2, "PERMS_PROMPT"), 0)
        H.eq("file_granted", from_file["net.rpv"], true)

        -- partial: grant fs.read, deny net.rpv
        local log3, lines3 = H.logger()
        local p3 = PERMS.new({ fs = H.real_fs(), log = log3, root = root,
            ask = function(app, cap) return cap == "fs.read" end })
        local partial, partial_info = p3:ensure("box", { "net.rpv", "fs.read" })
        H.eq("partial_granted", partial["fs.read"], true)
        H.eq("partial_denied", partial["net.rpv"], false)
        H.eq("partial_counts", partial_info.granted, 1)
        H.eq("partial_denied_count", partial_info.denied, 1)
        H.has(lines3, "PERMS_DECISION app=box cap=net.rpv granted=false")
        local box_text = H.read(root .. "/box.cfg")
        H.contains("partial_file_granted", box_text, "fs.read=granted")
        H.contains("partial_file_denied", box_text, "net.rpv=denied")

        -- no ask callback at all: fail closed
        local p4 = PERMS.new({ fs = H.real_fs(), log = log3, root = root })
        local defaulted = p4:ensure("quiet", { "fs.write" })
        H.eq("default_denied", defaulted["fs.write"], false)
        H.has(lines3, "PERMS_DECISION app=quiet cap=fs.write granted=false")

        -- an ask that raises is a denial, not a crash
        local p5 = PERMS.new({ fs = H.real_fs(), log = log3, root = root,
            ask = function() error("no input channel") end })
        local raised = p5:ensure("boom", { "fs.read" })
        H.eq("ask_raise_denied", raised["fs.read"], false)
        H.has(lines3, "PERMS_ASK_FAIL app=boom cap=fs.read")

        -- prompt = false reads only
        local p6 = PERMS.new({ fs = H.real_fs(), log = log3, root = root,
            ask = function() error("must not ask") end })
        local pending, pending_info = p6:ensure("later", { "fs.read" }, { prompt = false })
        H.eq("pending_nil", pending, nil)
        H.eq("pending_source", pending_info.source, "none")
        H.lacks("pending_no_prompt", lines3, "PERMS_PROMPT app=later")

        -- a bad file denies everything and is left alone
        H.write(root .. "/broken.cfg", "fs.read=sure\n")
        local p7 = PERMS.new({ fs = H.real_fs(), log = log3, root = root,
            ask = function() return true end })
        local broken, broken_info = p7:ensure("broken", { "fs.read" })
        H.eq("bad_source", broken_info.source, "bad")
        H.eq("bad_denied", broken["fs.read"], false)
        H.has(lines3, "PERMS_BAD_FILE app=broken")
        H.lacks("bad_no_prompt", lines3, "PERMS_PROMPT app=broken")
        H.eq("bad_file_kept", H.read(root .. "/broken.cfg"), "fs.read=sure\n")

        -- a line for a capability the manifest dropped is stale, not corrupt
        H.write(root .. "/stale.cfg", "fs.read=granted\nfs.write=granted\n")
        local p8 = PERMS.new({ fs = H.real_fs(), log = log3, root = root })
        local stale = p8:ensure("stale", { "fs.read" })
        H.eq("stale_kept", stale["fs.read"], true)
        H.eq("stale_dropped", stale["fs.write"], nil)
        H.has(lines3, "PERMS_PRUNE app=stale cap=fs.write")

        -- an app that declares nothing needs no decision at all
        local p9 = PERMS.new({ fs = H.real_fs(), log = log3, root = root })
        local none, none_info = p9:ensure("capsule", {})
        H.table("none_decisions", none)
        H.eq("none_source", none_info.source, "none")
        H.lacks("none_no_prompt", lines3, "PERMS_PROMPT app=capsule")

        H.ascii_check("prompt_logs_ascii", H.joined(lines3))
    end

    -- -----------------------------------------------------------------
    H.group("perms.prompt_screen")
    do
        local lines = PERMS.prompt_lines("net", { "net.rpv", "fs.read" }, 26, 20)
        H.eq("screen_rows", #lines, 20)
        for i = 1, #lines do
            H.eq("screen_width_" .. tostring(i), #lines[i], 26)
        end
        H.contains("screen_title", lines[1], "Permission request")
        H.contains("screen_app", lines[2], "app net")
        H.contains("screen_cap1", lines[3], "[y/N] net.rpv")
        H.contains("screen_cap2", lines[4], "[y/N] fs.read")
        H.contains("screen_default", lines[20], "[y/N] default N")

        -- more capabilities than lines: the list is merged, the tail summarised
        local many = PERMS.prompt_lines("fat", {
            "fs.read", "fs.write", "net.rpv", "net.rednet",
            "redstone", "peripheral", "http",
        }, 26, 8)
        H.eq("merged_rows", #many, 8)
        H.contains("merged_more", H.joined(many), "more")
        for i = 1, #many do H.eq("merged_width_" .. tostring(i), #many[i], 26) end

        -- a tiny screen still shows one question instead of blowing up
        local tiny = PERMS.prompt_lines("net", { "fs.read" }, 10, 3)
        H.eq("tiny_rows", #tiny, 3)
        for i = 1, #tiny do H.eq("tiny_width_" .. tostring(i), #tiny[i], 10) end
        H.contains("tiny_cap", H.joined(tiny), "[y/N]")
        H.ascii_check("screen_ascii", H.joined(lines) .. H.joined(many) .. H.joined(tiny))
    end

    -- -----------------------------------------------------------------
    H.group("perms.runtime")
    do
        local dir = H.case_dir("perms", "runtime")
        local root = dir .. "/etc/perms"
        local data = dir .. "/data.txt"
        H.write(data, "hello")
        local out = dir .. "/out.txt"

        -- partial grant: fs.read works, fs.write is a denial stub
        local app_dir = dir .. "/apps/probe.app"
        H.app_package(app_dir, {
            manifest = 'return { name = "probe", version = "0.1.0",'
                .. ' capabilities = { "fs.read", "fs.write" } }',
            main = probe_main(data, out),
        })
        local perms = PERMS.new({ fs = H.real_fs(), log = H.logger(), root = root,
            ask = function(app, cap) return cap == "fs.read" end })
        local log, lines = H.logger()
        local rt = APPS.new({ fs = H.real_fs(), log = log, apps_root = dir .. "/apps" })
        H.eq("scan", rt:scan(), 1)
        H.check("attach", rt:set_permissions(perms) == true, "set_permissions refused")
        H.has(lines, "APP_PERMS_ATTACHED")
        H.check("start_ok", rt:start("probe") == true, "start refused")
        H.has(lines, "APP_PERMS_APPLIED app=probe granted=1 denied=1")
        rt:tick()
        H.has(lines, "APP_LOG app=probe msg=read=true write=false")
        H.has(lines, "APP_CAP_DENIED app=probe cap=fs.write")
        H.eq("app_still_running", rt:app("probe").state, "running")
        H.eq("out_not_written", H.exists(out), false)
        H.eq("grant_recorded", rt:app("probe").perms["fs.read"], true)
        local status = rt:status()
        H.eq("status_grant", status.apps[1].grants["fs.read"], true)
        H.eq("status_denied", status.apps[1].grants["fs.write"], false)
        rt:kill("probe")

        -- a denied read is the same stub, and the app still runs
        local dir2 = H.case_dir("perms", "runtime_deny")
        local root2 = dir2 .. "/etc/perms"
        H.app_package(dir2 .. "/apps/probe.app", {
            manifest = 'return { name = "probe", version = "0.1.0",'
                .. ' capabilities = { "fs.read", "fs.write" } }',
            main = probe_main(dir2 .. "/data.txt", dir2 .. "/out.txt"),
        })
        local deny_perms = PERMS.new({ fs = H.real_fs(), log = H.logger(), root = root2,
            ask = function() return false end })
        local log2, lines2 = H.logger()
        local rt2 = APPS.new({ fs = H.real_fs(), log = log2,
            apps_root = dir2 .. "/apps" })
        rt2:scan()
        rt2:set_permissions(deny_perms)
        H.check("deny_start_ok", rt2:start("probe") == true, "a denied app must still start")
        rt2:tick()
        H.has(lines2, "APP_LOG app=probe msg=read=false write=false")
        H.has(lines2, "APP_CAP_DENIED app=probe cap=fs.read")
        H.has(lines2, "APP_PERMS_APPLIED app=probe granted=0 denied=2")
        H.eq("deny_running", rt2:app("probe").state, "running")
        H.eq("deny_read_stub", H.count(lines2, "APP_CAP_DENIED app=probe"), 2)
        rt2:kill("probe")

        -- reset drops the file, so the next start asks again
        H.eq("decision_file", H.exists(root2 .. "/probe.cfg"), true)
        local perms_reset = PERMS.reset("probe", { fs = H.real_fs(), root = root2 })
        H.eq("reset_true", perms_reset, true)
        H.eq("reset_gone", H.exists(root2 .. "/probe.cfg"), false)
        local regrant = PERMS.new({ fs = H.real_fs(), log = H.logger(), root = root2,
            ask = function() return true end })
        local prompts_before = regrant:count("PERMS_PROMPT")
        regrant:ensure("probe", { "fs.read", "fs.write" })
        H.eq("reset_reprompts", regrant:count("PERMS_PROMPT") - prompts_before, 1)
        H.eq("reset_file_back", H.exists(root2 .. "/probe.cfg"), true)

        -- no permission table: the P2 behaviour stays (declared is granted)
        local dir3 = H.case_dir("perms", "runtime_open")
        H.app_package(dir3 .. "/apps/probe.app", {
            manifest = 'return { name = "probe", version = "0.1.0",'
                .. ' capabilities = { "fs.read", "fs.write" } }',
            main = probe_main(dir3 .. "/data.txt", dir3 .. "/out.txt"),
        })
        H.write(dir3 .. "/data.txt", "hello")
        local log3, lines3 = H.logger()
        local rt3 = APPS.new({ fs = H.real_fs(), log = log3, apps_root = dir3 .. "/apps" })
        rt3:scan()
        rt3:start("probe")
        rt3:tick()
        H.has(lines3, "APP_LOG app=probe msg=read=true write=true")
        H.lacks("open_no_perms_log", lines3, "APP_PERMS_APPLIED")
        H.eq("open_out_written", H.read(dir3 .. "/out.txt"), "payload")
        rt3:kill("probe")

        -- a permission table that raises is a denial, not a failed start
        local dir4 = H.case_dir("perms", "runtime_broken")
        H.app_package(dir4 .. "/apps/probe.app", {
            manifest = 'return { name = "probe", version = "0.1.0",'
                .. ' capabilities = { "fs.read" } }',
            main = probe_main(dir4 .. "/data.txt", dir4 .. "/out.txt"),
        })
        local log4, lines4 = H.logger()
        local rt4 = APPS.new({ fs = H.real_fs(), log = log4, apps_root = dir4 .. "/apps" })
        rt4:scan()
        rt4:set_permissions({ root = "/t/never", ensure = function() error("table-boom") end })
        H.check("broken_start_ok", rt4:start("probe") == true, "start refused")
        rt4:tick()
        H.has(lines4, "APP_PERMS_FAIL app=probe")
        H.has(lines4, "APP_CAP_DENIED app=probe cap=fs.read")
        H.eq("broken_running", rt4:app("probe").state, "running")
        rt4:kill("probe")
    end
end
