--[[- pyroet-os/tests/t_apps.lua -- app runtime: manifests, capabilities, lifecycles, quotas.

No non-ASCII bytes in this file.
]]

local apps = dofile("/system/kernel/apps.lua")

return function(H)
    local F = H.real_fs()

    local function status_of(rt, name)
        local status = rt:status()
        for i = 1, #status.apps do
            if status.apps[i].name == name then return status.apps[i] end
        end
        return nil
    end

    local function new_rt(log, opts)
        local o = opts or {}
        return apps.new({
            fs = F,
            log = log,
            apps_root = o.apps_root,
            max_starts = o.max_starts,
            write_limit = o.write_limit,
            rpv = o.rpv,
            rednet = o.rednet,
            http = o.http,
        })
    end

    -- -----------------------------------------------------------------
    H.group("apps.manifest")
    do
        local m = apps.validate_manifest({
            name = "probe",
            version = "0.2.0",
            entry = "run.lua",
            capabilities = { "fs.read", "net.rpv" },
        }, "/x")
        H.table("ok_manifest", m)
        H.eq("name", m and m.name, "probe")
        H.eq("version", m and m.version, "0.2.0")
        H.eq("entry", m and m.entry, "run.lua")
        H.eq("caps_count", m and #m.capabilities, 2)

        local d = apps.validate_manifest({ name = "d" }, "/x")
        H.eq("default_version", d and d.version, "0.0.0")
        H.eq("default_entry", d and d.entry, "main.lua")
        H.eq("default_caps", d and #d.capabilities, 0)
        H.eq("default_max_starts", d and d.max_starts, nil)

        local dedup = apps.validate_manifest({
            name = "d", capabilities = { "fs.read", "fs.read" },
        }, "/x")
        H.eq("caps_deduped", dedup and #dedup.capabilities, 1)

        H.eq("max_starts_kept", (apps.validate_manifest({ name = "d", max_starts = 3 }, "/x")).max_starts, 3)

        local cases = {
            { "no_name", {}, "manifest.name" },
            { "name_space", { name = "a b" }, "manifest.name" },
            { "name_slash", { name = "a/b" }, "manifest.name" },
            { "name_dotdot", { name = ".." }, "'..'" },
            { "name_number", { name = 5 }, "manifest.name" },
            { "version_number", { name = "d", version = 5 }, "manifest.version" },
            { "version_long", { name = "d", version = string.rep("v", 40) }, "manifest.version" },
            { "entry_path", { name = "d", entry = "sub/main.lua" }, "path separator" },
            { "entry_dotdot", { name = "d", entry = ".." }, "plain file name" },
            { "entry_number", { name = "d", entry = 5 }, "manifest.entry" },
            { "caps_string", { name = "d", capabilities = "fs.read" }, "must be a list" },
            { "caps_element", { name = "d", capabilities = { 5 } }, "must be a string" },
            { "caps_unknown", { name = "d", capabilities = { "root" } }, "unknown capability" },
            { "max_starts_zero", { name = "d", max_starts = 0 }, "max_starts" },
        }
        for i = 1, #cases do
            local case = cases[i]
            local value, err = apps.validate_manifest(case[2], "/x")
            H.check(case[1], value == nil, "accepted a bad manifest")
            H.contains(case[1] .. "_error", err, case[3])
        end

        local bad = apps.validate_manifest("nope", "/x")
        H.check("not_a_table", bad == nil, "a string manifest was accepted")
    end

    -- -----------------------------------------------------------------
    H.group("apps.load")
    do
        local dir = H.case_dir("apps", "load")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local good = H.app_package(dir .. "/apps/probe.app", {
            manifest = 'return { name = "probe", version = "0.2.0", capabilities = { "fs.read" } }',
        })

        local record = rt:load(good)
        H.table("loaded", record)
        H.eq("loaded_name", record and record.name, "probe")
        H.eq("loaded_state", record and record.state, "loaded")
        H.has(lines, "APP_LOAD name=probe version=0.2.0 caps=fs.read")
        H.eq("app_getter", rt:app("probe") == record, true)

        local dup, dup_err = rt:load(good)
        H.check("duplicate_rejected", dup == nil, "ok=" .. tostring(dup))
        H.eq("duplicate_error", dup_err, "duplicate app name: probe")

        local missing, missing_err = rt:load(dir .. "/apps/nope.app")
        H.check("missing_rejected", missing == nil, "ok=" .. tostring(missing))
        H.eq("missing_error", missing_err, "missing manifest.lua")
        H.has(lines, "APP_LOAD_FAIL")

        local no_entry = H.app_package(dir .. "/apps/noentry.app", {
            manifest = 'return { name = "noentry", entry = "gone.lua" }',
        })
        local noe, noe_err = rt:load(no_entry)
        H.check("no_entry_rejected", noe == nil, "ok=" .. tostring(noe))
        H.eq("no_entry_error", noe_err, "missing entry file: gone.lua")

        local broken = H.app_package(dir .. "/apps/broken.app", {
            manifest = 'return { name = ',
        })
        local br, br_err = rt:load(broken)
        H.check("syntax_rejected", br == nil, "ok=" .. tostring(br))
        H.contains("syntax_error", br_err, "manifest load failed")

        local nilman = H.app_package(dir .. "/apps/nilman.app", { manifest = "return nil" })
        local nm, nm_err = rt:load(nilman)
        H.check("nil_manifest_rejected", nm == nil, "ok=" .. tostring(nm))
        H.contains("nil_manifest_error", nm_err, "manifest returned nil")

        local strman = H.app_package(dir .. "/apps/strman.app", { manifest = 'return "x"' })
        local sm, sm_err = rt:load(strman)
        H.check("string_manifest_rejected", sm == nil, "ok=" .. tostring(sm))
        H.contains("string_manifest_error", sm_err, "manifest must return a table")
    end

    -- -----------------------------------------------------------------
    H.group("apps.scan")
    do
        local dir = H.case_dir("apps", "scan")
        local root = dir .. "/apps"
        local log, lines = H.logger()
        local rt = new_rt(log)
        H.app_package(root .. "/a.app", {
            manifest = 'return { name = "a", version = "1.0.0" }',
        })
        H.app_package(root .. "/b.app", {
            manifest = 'return { name = "b", version = "1.0.0", capabilities = { "root" } }',
        })
        H.write(root .. "/c.app", "-- not a directory\n")
        H.write(root .. "/notes.txt", "ignore me\n")

        local loaded, failed = rt:scan(root)
        H.eq("scan_loaded", loaded, 1)
        H.eq("scan_failed", failed, 1)
        H.has(lines, "APP_SCAN root=" .. root .. " loaded=1 failed=1")
        H.has(lines, "APP_SCAN_IGNORE path=" .. root .. "/c.app reason=not_directory")
        H.eq("scanned_app", rt:app("a") ~= nil, true)
        H.eq("bad_app_absent", rt:app("b"), nil)

        local empty_rt = new_rt(H.logger())
        local l2, f2 = empty_rt:scan(dir .. "/nothing-here")
        H.eq("missing_root_loaded", l2, 0)
        H.eq("missing_root_failed", f2, 0)
        H.has(empty_rt:lines(), "APP_SCAN_MISSING root=" .. dir .. "/nothing-here")
    end

    -- -----------------------------------------------------------------
    H.group("apps.run")
    do
        local dir = H.case_dir("apps", "run")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local app = H.app_package(dir .. "/apps/run.app", {
            manifest = 'return { name = "run", version = "0.1.0", capabilities = { "fs.read" } }',
            main = [[
return function(manifest, api)
    local n = 0
    while n < 3 do
        n = n + 1
        api.log("tick " .. n)
        api.yield()
    end
    api.log("done")
end
]],
        })
        rt:load(app)

        H.check("start_ok", rt:start("run") == true, "start refused")
        H.eq("state_running", rt:app("run").state, "running")
        H.eq("starts_one", rt:app("run").starts, 1)
        H.has(lines, "APP_START name=run starts=1 caps=fs.read")
        H.lacks("body_not_run_yet", lines, "msg=tick 1")

        local again, again_err = rt:start("run")
        H.check("double_start_rejected", again == nil, "ok=" .. tostring(again))
        H.eq("double_start_error", again_err, "app already running: run")

        H.eq("tick_one", rt:tick(), 1)
        H.has(lines, "APP_LOG app=run msg=tick 1")
        H.eq("still_running", rt:app("run").state, "running")

        H.eq("tick_two", rt:tick(), 1)
        H.eq("tick_three", rt:tick(), 1)
        H.has(lines, "APP_LOG app=run msg=tick 3")
        H.eq("tick_four", rt:tick(), 1)
        H.has(lines, "APP_LOG app=run msg=done")
        H.eq("state_stopped", rt:app("run").state, "stopped")
        H.has(lines, "APP_EXIT app=run")
        H.eq("tick_idle", rt:tick(), 0)
        H.eq("status_ticks", rt:status().ticks, 5)

        local unknown, unknown_err = rt:start("ghost")
        H.check("unknown_app", unknown == nil, "ok=" .. tostring(unknown))
        H.eq("unknown_app_error", unknown_err, "no such app: ghost")
        H.eq("step_unknown", select(2, rt:step("ghost")), "no such app: ghost")
    end

    -- -----------------------------------------------------------------
    H.group("apps.caps")
    do
        local dir = H.case_dir("apps", "caps")
        local log, lines = H.logger()
        local rt = new_rt(log, { rpv = { marker = "host-rpv" } })

        H.write(dir .. "/data.txt", "DATA")
        local reader = H.app_package(dir .. "/apps/reader.app", {
            manifest = 'return { name = "reader", capabilities = { "fs.read" } }',
            main = string.format([[
return function(manifest, api)
    local text, err = api.fs.read(%q)
    api.log("read=" .. tostring(text) .. " err=" .. tostring(err))
    api.yield()
end
]], dir .. "/data.txt"),
        })
        rt:load(reader)

        local denier = H.app_package(dir .. "/apps/denier.app", {
            manifest = 'return { name = "denier", capabilities = { "fs.read" } }',
            main = string.format([[
return function(manifest, api)
    local ok, err = api.fs.write(%q, "x")
    api.log("write=" .. tostring(ok) .. " err=" .. tostring(err))
    api.log("type=" .. type(api.fs.write))
    api.yield()
end
]], dir .. "/out.txt"),
        })
        rt:load(denier)

        local netdeny = H.app_package(dir .. "/apps/netdeny.app", {
            manifest = 'return { name = "netdeny" }',
            main = [[
return function(manifest, api)
    local ok, err = api.net.rpv.connect("/x")
    api.log("rpv=" .. tostring(ok) .. " err=" .. tostring(err))
    local hok, herr = api.http("http://example")
    api.log("http=" .. tostring(hok) .. " err=" .. tostring(herr))
    api.yield()
end
]],
        })
        rt:load(netdeny)

        local netgrant = H.app_package(dir .. "/apps/netgrant.app", {
            manifest = 'return { name = "netgrant", capabilities = { "net.rpv", "net.rednet" } }',
            main = [[
return function(manifest, api)
    api.log("marker=" .. tostring(api.net.rpv.marker))
    local ok, err = api.net.rednet.send(1, "x")
    api.log("rednet=" .. tostring(ok) .. " err=" .. tostring(err))
    api.yield()
end
]],
        })
        rt:load(netgrant)

        -- denied write is a value, not an error, and the app keeps running
        rt:start("denier")
        H.eq("denier_tick", rt:tick(), 1)
        H.has(lines, "APP_LOG app=denier msg=write=nil err=capability denied: fs.write")
        H.has(lines, "APP_LOG app=denier msg=type=function")
        H.has(lines, "APP_CAP_DENIED app=denier cap=fs.write")
        H.eq("denier_alive", rt:app("denier").state, "running")
        H.eq("denied_counter", rt:app("denier").denied, 1)

        -- granted capability reaches the host
        rt:start("reader")
        rt:tick()
        H.has(lines, "APP_LOG app=reader msg=read=DATA err=nil")
        H.lacks("no_denied_for_reader", lines, "APP_CAP_DENIED app=reader")

        -- denied table access: both a method call and a direct call
        rt:start("netdeny")
        rt:tick()
        H.has(lines, "APP_LOG app=netdeny msg=rpv=nil err=capability denied: net.rpv")
        H.has(lines, "APP_LOG app=netdeny msg=http=nil err=capability denied: http")
        H.has(lines, "APP_CAP_DENIED app=netdeny cap=net.rpv")
        H.has(lines, "APP_CAP_DENIED app=netdeny cap=http")

        -- granted table capability is the host object itself; missing host is
        -- reported as unavailable, never as denied
        rt:start("netgrant")
        rt:tick()
        H.has(lines, "APP_LOG app=netgrant msg=marker=host-rpv")
        H.has(lines, "APP_LOG app=netgrant msg=rednet=nil err=capability unavailable: net.rednet")
        H.has(lines, "APP_CAP_UNAVAILABLE app=netgrant cap=net.rednet")
    end

    -- -----------------------------------------------------------------
    H.group("apps.lifecycle")
    do
        local dir = H.case_dir("apps", "lifecycle")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local app = H.app_package(dir .. "/apps/life.app", {
            manifest = 'return { name = "life", version = "1.0.0" }',
            main = [[
return function(manifest, api)
    api.log("body-1")
    api.yield()
    api.log("body-2")
    api.yield()
    api.log("body-3")
end
]],
            lifecycle = [[
return {
    on_start = function(m, api) api.log("hook:on_start") end,
    on_pause = function(m, api) api.log("hook:on_pause") end,
    on_resume = function(m, api) api.log("hook:on_resume") end,
    on_stop = function(m, api) api.log("hook:on_stop") end,
}
]],
        })
        rt:load(app)
        rt:start("life")
        H.has(lines, "APP_LOG app=life msg=hook:on_start")

        rt:tick()
        H.has(lines, "APP_LOG app=life msg=body-1")

        H.check("pause_ok", rt:pause("life") == true, "pause refused")
        H.eq("paused_state", rt:app("life").state, "paused")
        H.has(lines, "APP_PAUSE name=life")
        H.has(lines, "APP_LOG app=life msg=hook:on_pause")
        H.eq("paused_tick", rt:tick(), 0)

        H.check("resume_ok", rt:resume("life") == true, "resume refused")
        H.eq("resumed_state", rt:app("life").state, "running")
        H.has(lines, "APP_RESUME name=life")
        H.has(lines, "APP_LOG app=life msg=hook:on_resume")

        rt:tick()
        rt:tick()
        H.has(lines, "APP_LOG app=life msg=body-3")
        H.eq("exited_state", rt:app("life").state, "stopped")
        H.has(lines, "APP_LOG app=life msg=hook:on_stop")

        -- transitions that make no sense are refused, not faked
        H.eq("pause_stopped", select(2, rt:pause("life")), "app is not running: life (stopped)")
        H.eq("resume_not_paused", select(2, rt:resume("life")), "app is not paused: life (stopped)")

        -- a broken lifecycle file is reported, and the app still starts
        local broken = H.app_package(dir .. "/apps/brok.app", {
            manifest = 'return { name = "brok" }',
            lifecycle = 'error("hook-file-boom")',
        })
        rt:load(broken)
        H.check("broken_lifecycle_starts", rt:start("brok") == true, "start refused")
        H.has(lines, "APP_HOOK_FILE_FAIL app=brok")
        H.contains("broken_lifecycle_error", H.joined(lines), "hook-file-boom")

        local notatable = H.app_package(dir .. "/apps/ntl.app", {
            manifest = 'return { name = "ntl" }',
            lifecycle = 'return "nope"',
        })
        rt:load(notatable)
        rt:start("ntl")
        H.has(lines, "APP_HOOK_FILE_FAIL app=ntl err=not_a_table")

        -- a raising on_start hook is logged and the body still runs
        local throwing = H.app_package(dir .. "/apps/throw.app", {
            manifest = 'return { name = "throw" }',
            main = 'return function(manifest, api) api.log("throw-body") api.yield() end',
            lifecycle = 'return { on_start = function() error("hook-boom") end }',
        })
        rt:load(throwing)
        H.check("throwing_hook_starts", rt:start("throw") == true, "start refused")
        H.has(lines, "APP_HOOK_FAIL app=throw hook=on_start")
        rt:tick()
        H.has(lines, "APP_LOG app=throw msg=throw-body")
        H.eq("hook_error_recorded", #status_of(rt, "throw").hook_errors, 1)

        -- manifest hooks are the fallback when there is no lifecycle.lua
        local inman = H.app_package(dir .. "/apps/inman.app", {
            manifest = [[
return {
    name = "inman",
    on_stop = function(m, api) api.log("mhook:on_stop") end,
}
]],
            main = 'return function(manifest, api) api.yield() end',
        })
        rt:load(inman)
        rt:start("inman")
        rt:tick()
        rt:tick()
        H.has(lines, "APP_LOG app=inman msg=mhook:on_stop")
    end

    -- -----------------------------------------------------------------
    H.group("apps.kill")
    do
        local dir = H.case_dir("apps", "kill")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local app = H.app_package(dir .. "/apps/kill.app", {
            manifest = 'return { name = "kill" }',
            main = [[
return function(manifest, api)
    while true do
        api.log("tick")
        api.yield()
    end
end
]],
            lifecycle = 'return { on_stop = function(m, api) api.log("hook:on_stop") end }',
        })
        rt:load(app)
        rt:start("kill")
        rt:tick()
        local ticks_before = H.count(lines, "APP_LOG app=kill msg=tick")
        H.eq("ticks_before_kill", ticks_before, 1)

        H.check("kill_ok", rt:kill("kill") == true, "kill refused")
        H.eq("killed_state", rt:app("kill").state, "killed")
        H.has(lines, "APP_KILL name=kill starts=1")
        H.has(lines, "APP_LOG app=kill msg=hook:on_stop")
        H.eq("kill_drops_coroutine", rt:app("kill").co, nil)

        H.eq("killed_tick", rt:tick(), 0)
        H.eq("ticks_after_kill", H.count(lines, "APP_LOG app=kill msg=tick"), 1)

        local restart, restart_err = rt:start("kill")
        H.check("restart_refused", restart == nil, "ok=" .. tostring(restart))
        H.eq("restart_error", restart_err, "app is killed: kill")
        H.eq("resume_killed", select(2, rt:resume("kill")), "app is killed: kill")
        H.eq("pause_killed", select(2, rt:pause("kill")),
            "app is not running: kill (killed)")

        -- killing twice must not run on_stop twice
        H.check("kill_idempotent", rt:kill("kill") == true, "second kill refused")
        H.eq("on_stop_once", H.count(lines, "APP_LOG app=kill msg=hook:on_stop"), 1)
        H.eq("kill_unknown", select(2, rt:kill("ghost")), "no such app: ghost")
    end

    -- -----------------------------------------------------------------
    H.group("apps.quota")
    do
        local dir = H.case_dir("apps", "quota")
        local log, lines = H.logger()
        local rt = new_rt(log, { max_starts = 2, write_limit = 10 })

        local quick = H.app_package(dir .. "/apps/quick.app", {
            manifest = 'return { name = "quick" }',
            main = 'return function(manifest, api) api.yield() end',
        })
        rt:load(quick)
        rt:start("quick")
        rt:tick()
        rt:tick()
        H.eq("first_run_stopped", rt:app("quick").state, "stopped")
        H.check("second_start", rt:start("quick") == true, "second start refused")
        rt:tick()
        rt:tick()
        local third, third_err = rt:start("quick")
        H.check("third_refused", third == nil, "ok=" .. tostring(third))
        H.eq("third_error", third_err, "quota exceeded: starts")
        H.has(lines, "APP_QUOTA_START_DENIED app=quick limit=2 starts=2")
        H.eq("starts_counter", rt:app("quick").starts, 2)

        local manifest_quota = H.app_package(dir .. "/apps/mq.app", {
            manifest = 'return { name = "mq", max_starts = 1 }',
            main = 'return function(manifest, api) api.yield() end',
        })
        rt:load(manifest_quota)
        rt:start("mq")
        rt:tick()
        rt:tick()
        H.check("manifest_quota_refused", rt:start("mq") == nil, "manifest quota ignored")
        H.has(lines, "APP_QUOTA_START_DENIED app=mq limit=1")

        local writer = H.app_package(dir .. "/apps/writer.app", {
            manifest = 'return { name = "writer", capabilities = { "fs.write" } }',
            main = string.format([[
return function(manifest, api)
    local a, ae = api.fs.write(%q, "12345678")
    api.log("first=" .. tostring(a) .. " err=" .. tostring(ae))
    local b, be = api.fs.write(%q, "12345")
    api.log("second=" .. tostring(b) .. " err=" .. tostring(be))
    api.yield()
end
]], dir .. "/q.txt", dir .. "/q.txt"),
        })
        rt:load(writer)
        rt:start("writer")
        rt:tick()
        H.has(lines, "APP_LOG app=writer msg=first=true err=nil")
        H.has(lines, "APP_LOG app=writer msg=second=nil err=quota exceeded: fs.write")
        H.has(lines, "APP_QUOTA_WRITE_DENIED app=writer limit=10 used=8 want=5")
        H.eq("quota_file", H.read(dir .. "/q.txt"), "12345678")
        H.eq("write_bytes", rt:app("writer").write_bytes, 8)
        H.eq("quota_status_bytes", status_of(rt, "writer").write_bytes, 8)
    end

    -- -----------------------------------------------------------------
    H.group("apps.crash")
    do
        local dir = H.case_dir("apps", "crash")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local bad = H.app_package(dir .. "/apps/bad.app", {
            manifest = 'return { name = "bad" }',
            main = 'return function(manifest, api) error("body-boom") end',
        })
        local good = H.app_package(dir .. "/apps/good.app", {
            manifest = 'return { name = "good" }',
            main = 'return function(manifest, api) api.log("good") api.yield() end',
        })
        rt:load(bad)
        rt:load(good)

        rt:start("bad")
        rt:start("good")
        H.eq("crash_tick", rt:tick(), 1)
        H.eq("crashed_state", rt:app("bad").state, "crashed")
        H.has(lines, "APP_CRASH app=bad err=")
        H.contains("crash_error_text", H.joined(lines), "body-boom")
        H.has(lines, "APP_LOG app=good msg=good")
        H.eq("crash_tick_again", rt:tick(), 1)

        -- a crashed app may be started again; only kill is terminal
        H.check("restart_crashed", rt:start("bad") == true, "restart refused")
        H.eq("restart_starts", rt:app("bad").starts, 2)
    end

    -- -----------------------------------------------------------------
    H.group("apps.entry")
    do
        local dir = H.case_dir("apps", "entry")
        local log, lines = H.logger()
        local rt = new_rt(log)
        local app = H.app_package(dir .. "/apps/syn.app", {
            manifest = 'return { name = "syn" }',
            main = 'return function(',
        })
        rt:load(app)
        local ok, err = rt:start("syn")
        H.check("syntax_entry_refused", ok == nil, "ok=" .. tostring(ok))
        H.contains("syntax_entry_error", err, "cannot load entry")
        H.has(lines, "APP_START_FAIL app=syn")
        H.eq("syntax_entry_state", rt:app("syn").state, "loaded")
        H.eq("syntax_entry_starts", rt:app("syn").starts, 0)

        -- the api only knows the declared capability surface
        local probe = H.app_package(dir .. "/apps/surface.app", {
            manifest = 'return { name = "surface", capabilities = { "fs.write" } }',
            main = [[
return function(manifest, api)
    api.log("fsread=" .. type(api.fs.read))
    api.log("fsdelete=" .. type(api.fs.delete))
    api.log("peripheral=" .. type(api.peripheral))
    api.yield()
end
]],
        })
        rt:load(probe)
        rt:start("surface")
        rt:tick()
        H.has(lines, "APP_LOG app=surface msg=fsread=function")
        H.has(lines, "APP_LOG app=surface msg=peripheral=table")
    end

    -- -----------------------------------------------------------------
    H.group("apps.status")
    do
        local dir = H.case_dir("apps", "status")
        local log, lines = H.logger()
        local rt = new_rt(log)
        H.app_package(dir .. "/apps/s1.app", {
            manifest = 'return { name = "s1", version = "1.2.3", capabilities = { "fs.read" } }',
        })
        rt:scan(dir .. "/apps")
        local status = rt:status()
        H.eq("status_count", status.count, 1)
        H.eq("status_loaded", status.counts.loaded, 1)
        H.table("status_apps", status.apps)
        H.eq("status_name", status.apps[1].name, "s1")
        H.eq("status_version", status.apps[1].version, "1.2.3")
        H.eq("status_caps", status.apps[1].capabilities[1], "fs.read")
        H.eq("status_starts", status.apps[1].starts, 0)
        H.ascii_check("status_ascii", H.joined(lines))
        H.table("caps_list", apps.CAPS)
        H.eq("cap_count", #apps.CAPS, 7)
        H.eq("cap_known", apps.cap_known("http"), true)
        H.eq("cap_unknown", apps.cap_known("root"), false)
    end
end
