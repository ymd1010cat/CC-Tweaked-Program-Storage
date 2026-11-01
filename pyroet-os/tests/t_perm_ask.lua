--[[- pyroet-os/tests/t_perm_ask.lua -- the Android-style permission flow.

Four layers, tested where each one lives:

  1. `perm_ask.launcher`: the modal dialog -- exactly three rows ("Permission
     request" / "<app> wants <cap>" / "[Allow]  [Deny]"), A allows, D denies, no
     other key dismisses it, and the deferred start is retried after the answer.
  2. `perm_ask.desktop`: the dispatcher turns a queued request into one
     `perm_request` event for the launcher (and never repeats it).
  3. `perm_ask.runtime`: an undecided capability defers the start
     ("permission pending: <cap>"), the answer makes it startable, a denial
     starts the app with the capability refused (the old `denied` behaviour), and
     the system surface that writes decisions is gated by the host.
  4. `perm_ask.chain` + `perm_ask.settings`: the real boot chain (a headless boot
     keeps the old silent policy, an interactive one queues, an image package is
     pre-granted) and the Settings permissions screen with its toggle.

The queue itself is pinned in t_permissions.lua (`perms.queue`).

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")
local PERMS = dofile("/system/kernel/permissions.lua")
local DESKTOP = dofile("/system/kernel/desktop.lua")

rawset(_G, "PYROET_STARTUP_TEST", true)
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)

rawset(_G, "PYROET_SETTINGS_TEST", true)
local SETTINGS = assert(loadfile("/system/system/settings.app/main.lua"))()
rawset(_G, "PYROET_SETTINGS_TEST", nil)

local KEYS = { up = 10, down = 11, left = 12, right = 13, enter = 14, escape = 15 }

-- an input queue shaped like startup.default_input
local function new_host()
    local host = { queue = {}, head = 1, tail = 0 }
    function host.push(event, a, b, c)
        host.tail = host.tail + 1
        host.queue[host.tail] = { event, a, b, c }
        return true
    end
    function host.pending()
        return host.tail - host.head + 1
    end
    function host.pullEvent(...)
        local filter = { ... }
        local want = select("#", ...)
        while host.head <= host.tail do
            local item = host.queue[host.head]
            host.queue[host.head] = nil
            host.head = host.head + 1
            local match = want == 0
            if not match then
                for i = 1, want do
                    if filter[i] == item[1] then match = true break end
                end
            end
            if match then return item[1], item[2], item[3], item[4] end
        end
        return nil
    end
    return host
end

-- a pull source: the scripted events, then `terminate` (a test cannot block)
local function scripted(events)
    local stats = { pulls = 0 }
    local pull = function()
        stats.pulls = stats.pulls + 1
        local event = events[stats.pulls]
        if event == nil then return "terminate" end
        return event[1], event[2], event[3], event[4]
    end
    return pull, stats
end

-- a fake app runtime: records, status(), and one queue drain per tick
local function fake_runtime(host)
    local rt = { records = {}, ticks = 0, drained = {}, host = host }
    function rt.add(name, caps)
        rt.records[#rt.records + 1] = {
            name = name, state = "running", starts = 1, result = nil,
            manifest = { capabilities = caps },
        }
    end
    function rt.app(_, name)
        for i = 1, #rt.records do
            if rt.records[i].name == name then return rt.records[i] end
        end
        return nil
    end
    function rt.status()
        local apps = {}
        for i = 1, #rt.records do
            local record = rt.records[i]
            apps[i] = {
                name = record.name, state = record.state, starts = record.starts,
                capabilities = record.manifest.capabilities, result = record.result,
            }
        end
        return { apps = apps }
    end
    function rt.tick()
        rt.ticks = rt.ticks + 1
        if host then
            local event, a, b = host.pullEvent()
            if event ~= nil then rt.drained[#rt.drained + 1] = { event, a, b } end
        end
        if rt.on_tick then rt.on_tick(rt) end
        return true
    end
    return rt
end

-- how many times `fragment` is on a log line list
local function count_of(lines, fragment)
    local n = 0
    for i = 1, #lines do
        if tostring(lines[i]):find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

return function(H)
    local F = H.real_fs()

    local function pad(text, w)
        if #text >= w then return text:sub(1, w) end
        return text .. string.rep(" ", w - #text)
    end

    local function bootable(dir)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/kernel/ota.lua", "-- ota\n")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
        return dir
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.launcher")
    -- The dialog, verbatim: the three rows, the two keys, and the retried start.
    do
        local calls = { answered = {}, launched = {} }
        local logs = {}
        local api = {
            logs = logs,
            fs = {
                read = function() return nil, "missing" end,
                list = function() return nil, "missing" end,
                exists = function() return false end,
                write = function() return true end,
                makeDir = function() return true end,
            },
            sys = {
                perms_answer = function(app, cap, verdict)
                    calls.answered[#calls.answered + 1] =
                        app .. "/" .. cap .. "/" .. verdict
                    return true
                end,
                launch = function(name)
                    calls.launched[#calls.launched + 1] = name
                    return true
                end,
            },
            log = function(line) logs[#logs + 1] = tostring(line) end,
            yield = function() end,
        }
        local state = LAUNCHER.build(api, { cols = 26, rows = 20 })

        -- the event the desktop delivers
        H.eq("request_action", LAUNCHER.dispatch_event(state, "perm_request",
            "demo", "fs.write", api), "repaint")
        H.table("dialog_state", state.perm)
        H.eq("dialog_app", state.perm.app, "demo")
        H.eq("dialog_cap", state.perm.cap, "fs.write")
        local lines = LAUNCHER.render(state, 26, 20)
        H.eq("dialog_rows", #lines, 20)
        H.eq("dialog_row1", lines[1], pad("Permission request", 26))
        H.eq("dialog_row2", lines[2], pad("demo wants fs.write", 26))
        H.eq("dialog_row3", lines[3], pad("[Allow]  [Deny]", 26))
        H.eq("dialog_blank", lines[4], pad("", 26))
        H.eq("dialog_hint", lines[20], pad("A=allow D=deny", 26))
        for i = 1, #lines do H.eq("dialog_width_" .. tostring(i), #lines[i], 26) end

        -- a question has no "dismiss": q and enter do nothing at all
        H.eq("q_ignored", LAUNCHER.dispatch_event(state, "char", "q", nil, api), "none")
        H.eq("enter_ignored", LAUNCHER.dispatch_event(state, "key", "enter", nil, api), "none")
        H.eq("still_open", state.perm ~= nil, true)
        H.eq("no_answer_yet", #calls.answered, 0)

        -- A allows: the kernel writes, and the deferred start is retried
        H.eq("allow_action", LAUNCHER.dispatch_event(state, "char", "A", nil, api), "repaint")
        H.eq("allow_answer", calls.answered[1], "demo/fs.write/allowed")
        H.eq("allow_closed", state.perm, nil)
        H.eq("allow_relaunch", calls.launched[1], "demo")
        H.eq("allow_message", state.message, "started demo")
        H.check("allow_logged",
            table.concat(logs, "\n"):find("perm answer app=demo cap=fs.write", 1, true) ~= nil,
            table.concat(logs, "\n"))

        -- D denies: same three rows, the other verdict
        H.eq("deny_open", LAUNCHER.dispatch_event(state, "perm_request",
            "nomad", "fs.read", api), "repaint")
        local deny_lines = LAUNCHER.render(state, 26, 20)
        H.eq("deny_row2", deny_lines[2], pad("nomad wants fs.read", 26))
        H.eq("deny_action", LAUNCHER.dispatch_event(state, "char", "d", nil, api), "repaint")
        H.eq("deny_answer", calls.answered[2], "nomad/fs.read/denied")
        H.eq("deny_relaunch", calls.launched[2], "nomad")
        H.eq("deny_closed", state.perm, nil)

        -- the modal closes the other menus: it is a system-modal question
        local modal = LAUNCHER.build(api, { cols = 26, rows = 20 })
        modal.power = true
        modal.ota = { index = 1, entries = {} }
        LAUNCHER.dispatch_event(modal, "perm_request", "demo", "input", api)
        H.eq("closed_power", modal.power, nil)
        H.eq("closed_ota", modal.ota, nil)

        -- no bridge: the dialog reports it instead of hanging on a question
        local bare = LAUNCHER.build({ fs = api.fs, log = api.log, yield = api.yield },
            { cols = 26, rows = 20 })
        LAUNCHER.dispatch_event(bare, "perm_request", "demo", "fs.read", {})
        H.eq("bare_action", LAUNCHER.dispatch_event(bare, "char", "a", nil, {}), "denied")
        H.eq("bare_message", bare.message, "no permission bridge")
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.desktop")
    -- The dispatcher is the only thing that can reach the launcher while an app is
    -- deferred: it delivers `perm_request` once per request, and nothing at all
    -- when nothing is queued.
    do
        local host = new_host()
        local rt = fake_runtime(host)
        rt.add("launcher", { "input", "terminal" })
        local request = { app = "demo", cap = "fs.read" }
        rt.perm_pending = function() return request end
        local pull, pull_stats = scripted({ { "key", 10 } })
        local log, lines = H.logger()
        local d = DESKTOP.new({
            rt = rt, input = host, pullEvent = pull, keys = KEYS,
            name = "launcher", log = log, max_events = 1,
        })
        H.eq("reason", d:run(), "limit")
        H.has(lines, "DESKTOP_PERM_REQUEST app=demo cap=fs.read")
        H.eq("perm_key", d.perm_key, "demo/fs.read")
        H.eq("state_perm", d:state().perm, "demo/fs.read")

        -- the event really reached the queue, with the app and the capability
        local got = 0
        for i = 1, #rt.drained do
            local event = rt.drained[i]
            if event[1] == "perm_request" then
                got = got + 1
                H.eq("delivered_app", event[2], "demo")
                H.eq("delivered_cap", event[3], "fs.read")
            end
        end
        H.eq("delivered_once", got, 1)
        H.eq("logged_once", count_of(lines, "DESKTOP_PERM_REQUEST"), 1)
        H.eq("one_pull", pull_stats.pulls, 1)

        -- a machine with no queue at all is not a crash
        local quiet = fake_runtime(new_host())
        quiet.add("launcher", { "input" })
        local pull2 = scripted({ { "key", 10 } })
        local d2 = DESKTOP.new({ rt = quiet, input = new_host(), pullEvent = pull2,
            keys = KEYS, name = "launcher", log = function() end, max_events = 1 })
        H.eq("quiet_reason", d2:run(), "limit")
        H.eq("quiet_perm", d2.perm_key, nil)
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.runtime")
    -- Declared is not granted, and "not decided yet" is a deferral, not a denial.
    do
        local dir = H.case_dir("perm_ask", "runtime")
        local log, lines = H.logger()
        local rt = APPS.new({ fs = F, log = log, apps_root = dir .. "/apps",
            sys = function() return {} end })
        H.app_package(dir .. "/apps/demo.app", {
            manifest = 'return { name = "demo", version = "1.0.0",'
                .. ' capabilities = { "fs.read" } }',
            main = [[
return function(manifest, api)
    api.log("demo running read=" .. tostring(api.fs.read ~= nil))
    api.yield()
end
]],
        })
        H.app_package(dir .. "/apps/wire.app", {
            manifest = 'return { name = "wire", version = "1.0.0",'
                .. ' capabilities = { "fs.write" } }',
            main = [[
return function(manifest, api)
    local ok, err = api.fs.write("/tmp/probe.txt", "x")
    api.log("write ok=" .. tostring(ok) .. " err=" .. tostring(err))
    api.yield()
end
]],
        })
        rt:load(dir .. "/apps/demo.app")
        rt:load(dir .. "/apps/wire.app")
        local perms = PERMS.new({ fs = F, log = log, root = dir .. "/perms",
            ask = function() return "ask" end })
        rt:set_permissions(perms)

        -- 1. the start is deferred, not refused
        local ok, err = rt:start("demo")
        H.eq("start_deferred", ok, nil)
        H.eq("deferred_err", err, "permission pending: fs.read")
        H.has(lines, "APP_PERM_PENDING app=demo cap=fs.read")
        H.has(lines, "PERM_ASK app=demo cap=fs.read")
        H.eq("no_cfg_yet", H.exists(dir .. "/perms/demo.cfg"), false)
        H.eq("record_not_running", rt:app("demo").state, "loaded")
        local pending = rt:perm_pending()
        H.table("pending", pending)
        H.eq("pending_app", pending and pending.app, "demo")
        H.eq("pending_cap", pending and pending.cap, "fs.read")

        -- 2. the answer (through the runtime, the way the launcher calls it) makes
        -- the same start go through
        local record = rt:app("demo")
        H.eq("answer_ok", rt:sys_perms_answer(record, "demo", "fs.read", "allowed"), true)
        H.has(lines, "APP_PERM_ANSWER app=demo cap=fs.read by=demo ok=true")
        H.eq("queue_empty", rt:perm_pending(), nil)
        H.eq("started_after_answer", rt:start("demo"), true)
        H.has(lines, "APP_PERMS_APPLIED app=demo granted=1 denied=0")
        H.eq("cap_granted", rt:app("demo").caps["fs.read"], true)
        H.contains("cfg_granted", H.read(dir .. "/perms/demo.cfg") or "", "fs.read=granted")
        rt:tick()
        H.has(lines, "APP_LOG app=demo msg=demo running read=true")
        rt:kill("demo")

        -- 3. denied: the app still starts, and the capability is refused at use --
        -- which is exactly what the old silent `denied` did
        H.eq("wire_deferred", rt:start("wire"), nil)
        H.eq("wire_pending", rt:perm_pending().cap, "fs.write")
        H.eq("wire_deny", rt:sys_perms_answer(rt:app("wire"), "wire", "fs.write", "denied"),
            true)
        H.has(lines, "APP_PERM_ANSWER app=wire cap=fs.write by=wire ok=true")
        H.eq("wire_started", rt:start("wire"), true)
        H.has(lines, "APP_PERMS_APPLIED app=wire granted=0 denied=1")
        rt:tick()
        H.has(lines, "APP_LOG app=wire msg=write ok=nil err=capability denied: fs.write")
        H.has(lines, "APP_CAP_DENIED app=wire cap=fs.write")

        -- 4. the toggle: only a declared capability may be written, and the next
        -- start re-reads the file
        H.eq("set_grant", rt:sys_perms_set(record, "demo", "fs.read", "denied"), true)
        H.has(lines, "PERM_SET app=demo cap=fs.read verdict=denied by=user")
        H.eq("set_undeclared", select(1, rt:sys_perms_set(record, "demo", "http", "granted")),
            nil)
        H.contains("undeclared_reason",
            tostring(select(2, rt:sys_perms_set(record, "demo", "http", "granted"))),
            "not declared")
        H.eq("set_unknown", select(1, rt:sys_perms_set(record, "ghost", "fs.read", "denied")),
            nil)

        -- 5. the list Settings reads: name, version, capabilities and their state
        local listed, apps = rt:sys_perms_list(record)
        H.eq("list_ok", listed, true)
        local by_name = {}
        for i = 1, #(apps or {}) do by_name[apps[i].name] = apps[i] end
        H.table("listed_demo", by_name.demo)
        H.eq("listed_version", by_name.demo and by_name.demo.version, "1.0.0")
        H.eq("listed_read_state", by_name.demo and by_name.demo.states["fs.read"], "denied")
        H.eq("listed_write_state", by_name.wire and by_name.wire.states["fs.write"], "denied")

        -- 6. with no system surface the whole bridge answers "unavailable", so a
        -- user package can never grant itself anything
        local bare = APPS.new({ fs = F, log = log, apps_root = dir .. "/apps" })
        bare:load(dir .. "/apps/wire.app")
        local bapi = bare:sys_api(bare:app("wire"))
        local bok, berr = bapi.perms_answer("wire", "fs.write", "allowed")
        H.eq("gated_nil", bok, nil)
        H.contains("gated_err", tostring(berr), "system unavailable: perms_answer")
        H.has(lines, "APP_SYS_UNAVAILABLE app=wire fn=perms_answer")
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.chain.headless")
    -- A headless boot has nobody to ask: it keeps the old policy (a user package is
    -- denied silently) instead of queueing a question that can never be shown.
    do
        local dir = bootable(H.case_dir("perm_ask", "headless"))
        H.app_package(dir .. "/apps/demo.app", {
            manifest = 'return { name = "demo", version = "1.0.0",'
                .. ' capabilities = { "fs.read" } }',
            main = "return function(manifest, api) api.yield() end",
        })
        local log, lines = H.logger()
        local result = startup.run({
            fs = F, root = dir, log = log, apps_root = dir .. "/apps",
            perms_root = dir .. "/perms", system_root = false,
            launcher = "demo", loop = false, frame = function() return true end,
            reboot = function() error("rebooted unexpectedly") end,
        })
        H.check("headless_ok", result.ok == true, tostring(result.error))
        H.has(lines, "PERMS_PROMPT app=demo caps=fs.read")
        H.has(lines, "PERMS_DECISION app=demo cap=fs.read granted=false")
        H.has(lines, "APP_PERMS_APPLIED app=demo granted=0 denied=1")
        H.lacks("headless_no_ask", lines, "PERM_ASK")
        H.lacks("headless_no_pending", lines, "APP_PERM_PENDING")
        H.eq("headless_no_request", result.perms:next_request(), nil)
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.chain.interactive")
    -- An interactive boot queues the capability, the launcher is deferred, and the
    -- answer is persisted: the next boot starts the app without asking again.
    do
        local dir = bootable(H.case_dir("perm_ask", "interactive"))
        H.app_package(dir .. "/apps/demo.app", {
            manifest = 'return { name = "demo", version = "1.0.0",'
                .. ' capabilities = { "fs.read" } }',
            main = "return function(manifest, api) api.yield() end",
        })
        local function boot(log)
            return startup.run({
                fs = F, root = dir, log = log, apps_root = dir .. "/apps",
                perms_root = dir .. "/perms", system_root = false,
                launcher = "demo", loop = false, perms_interactive = true,
                frame = function() return true end,
                reboot = function() error("rebooted unexpectedly") end,
            })
        end
        local log, lines = H.logger()
        local first = boot(log)
        H.check("first_ok", first.ok == true, tostring(first.error))
        H.has(lines, "PERM_ASK app=demo cap=fs.read")
        H.has(lines, "APP_PERM_PENDING app=demo cap=fs.read")
        H.has(lines, "STARTUP_LAUNCHER_FAIL name=demo err=permission pending: fs.read")
        H.eq("first_launcher", first.launcher, nil)
        H.eq("no_file", H.exists(dir .. "/perms/demo.cfg"), false)
        local req = first.perms:next_request()
        H.eq("queued_cap", req and req.cap, "fs.read")

        -- the answer, then the same boot again: no question, the app starts
        H.eq("answer", first.perms:answer("demo", "fs.read", "allowed"), true)
        H.contains("persisted", H.read(dir .. "/perms/demo.cfg") or "", "fs.read=granted")
        local log2, lines2 = H.logger()
        local second = boot(log2)
        H.check("second_ok", second.ok == true, tostring(second.error))
        H.eq("second_launcher", second.launcher, "demo")
        H.has(lines2, "STARTUP_LAUNCHER_STARTED name=demo")
        H.has(lines2, "APP_PERMS_APPLIED app=demo granted=1 denied=0")
        H.lacks("second_no_ask", lines2, "PERM_ASK")
        H.eq("second_no_request", second.perms:next_request(), nil)
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.chain.image")
    -- An image package is pre-granted, so it never asks -- not even on an
    -- interactive boot. That is the launcher's own case: it must not depend on a
    -- dialog it would have to draw itself.
    do
        H.rmrf("/etc/perms")
        local dir = bootable(H.case_dir("perm_ask", "image"))
        local log, lines = H.logger()
        local result = startup.run({
            fs = F, root = dir, log = log, apps_root = dir .. "/apps",
            system_root = "/system/system", perms_root = "/etc/perms",
            loop = false, perms_interactive = true,
            frame = function() return true end,
            terminal = nil,
            reboot = function() error("rebooted unexpectedly") end,
        })
        H.check("image_ok", result.ok == true, tostring(result.error))
        H.eq("image_launcher", result.launcher, "launcher")
        H.has(lines, "PERMS_PREGRANT app=launcher cap=fs.read")
        H.has(lines, "APP_PERMS_APPLIED app=launcher granted=4 denied=0")
        H.lacks("image_no_ask", lines, "PERM_ASK")
        H.lacks("image_no_pending", lines, "APP_PERM_PENDING")
        H.contains("image_cfg", H.read("/etc/perms/launcher.cfg") or "",
            "input=granted")
        H.rmrf("/etc/perms")
    end

    -- -----------------------------------------------------------------
    H.group("perm_ask.settings")
    -- The Settings screen: list, capabilities with their state, Enter toggles and
    -- writes, q goes back a level and then leaves.
    do
        local apps = {
            { name = "demo", version = "1.0.0", caps = { "fs.read", "fs.write" },
                states = { ["fs.read"] = "granted", ["fs.write"] = "ask" } },
        }
        local writes = {}
        local logs = {}
        local api = {
            logs = logs,
            fs = {
                read = function() return nil, "missing" end,
                getFreeSpace = function() return 1000 end,
            },
            sys = {
                apps = function()
                    return { { name = "demo", version = "1.0.0",
                        capabilities = { "fs.read", "fs.write" } } }
                end,
                perms_list = function() return true, apps end,
                perms_set = function(app, cap, verdict)
                    writes[#writes + 1] = app .. "/" .. cap .. "/" .. verdict
                    apps[1].states[cap] = (verdict == "granted") and "granted" or "denied"
                    return true
                end,
            },
            log = function(line) logs[#logs + 1] = tostring(line) end,
            yield = function() end,
        }
        local state = SETTINGS.build(api, { cols = 26, rows = 20 })

        -- the entry row exists at the bottom of the item list, and Enter opens it
        local items = SETTINGS.items(state)
        H.eq("items_count", #items, 3)
        H.eq("items_last_key", items[3].key, "permissions")
        H.eq("items_last_value", items[3].value, "1 apps")
        state.item = 3
        H.eq("open_action", SETTINGS.handle_key(state, "enter", api), "repaint")
        H.table("perms_state", state.perms)
        H.eq("perms_level", state.perms.level, 1)

        local list_lines = SETTINGS.render(state, 26, 20)
        H.eq("list_rows", #list_lines, 20)
        H.eq("list_row1", list_lines[1], pad("Permissions", 26))
        H.eq("list_row2", list_lines[2], pad("> demo 1.0.0", 26))
        H.eq("list_hint", list_lines[20], pad("enter=open q=back", 26))

        -- level 2: the capabilities with their state, on disk, not from a cache
        H.eq("enter_level2", SETTINGS.handle_key(state, "enter", api), "repaint")
        H.eq("level2", state.perms.level, 2)
        local caps = SETTINGS.render(state, 26, 20)
        H.eq("caps_row1", caps[1], pad("Permissions", 26))
        H.eq("caps_row2", caps[2], pad("demo", 26))
        H.eq("caps_row3", caps[3], pad("> fs.read granted", 26))
        H.eq("caps_row4", caps[4], pad("  fs.write ask", 26))
        H.eq("caps_hint", caps[20], pad("enter=toggle q=back", 26))

        -- granted -> denied, written through api.sys.perms_set
        H.eq("toggle_action", SETTINGS.handle_key(state, "enter", api), "change")
        H.eq("toggle_write", writes[1], "demo/fs.read/denied")
        H.eq("toggle_message", state.perms.message, "fs.read denied")
        local after = SETTINGS.render(state, 26, 20)
        H.eq("toggled_row", after[3], pad("> fs.read denied", 26))

        -- ask -> granted (the first press is the same act as answering A)
        H.eq("down", SETTINGS.handle_key(state, "down", api), "move")
        H.eq("ask_toggle", SETTINGS.handle_key(state, "enter", api), "change")
        H.eq("ask_write", writes[2], "demo/fs.write/granted")
        local asked = SETTINGS.render(state, 26, 20)
        H.eq("ask_row", asked[4], pad("> fs.write granted", 26))

        -- q goes back one level (never out of the app from inside a list)
        H.eq("back_action", SETTINGS.dispatch_event(state, "key", "q", api), "repaint")
        H.eq("back_level", state.perms.level, 1)
        H.eq("back_kept_open", state.perms ~= nil, true)
        H.eq("still_selected", state.perms.index, 1)
        H.eq("back_close", SETTINGS.dispatch_event(state, "key", "q", api), "repaint")
        H.eq("closed", state.perms, nil)
        -- and at level 1, `q` from a *char* event closes too
        SETTINGS.handle_key(state, "enter", api)
        SETTINGS.handle_key(state, "enter", api)
        H.eq("char_back", SETTINGS.dispatch_event(state, "char", "q", api), "repaint")
        H.eq("char_back_level", state.perms.level, 1)

        -- no bridge: the screen says so instead of showing an empty list
        local bare = SETTINGS.build({ fs = api.fs, log = api.log, yield = api.yield },
            { cols = 26, rows = 20 })
        SETTINGS.perms_open(bare, { fs = api.fs })
        H.eq("bare_message", bare.perms.message, "no permission bridge")
        H.contains("bare_line", H.joined(SETTINGS.render(bare, 26, 20)),
            "no permission bridge")

        -- a refused write keeps the old state on screen
        local refuse_api = {
            fs = api.fs, log = api.log, yield = api.yield,
            sys = {
                apps = api.sys.apps,
                perms_list = function() return true, apps end,
                perms_set = function() return nil, "read-only" end,
            },
        }
        local refuse = SETTINGS.build(refuse_api, { cols = 26, rows = 20 })
        SETTINGS.perms_open(refuse, refuse_api)
        SETTINGS.handle_key(refuse, "enter", refuse_api)
        H.eq("refuse_action", SETTINGS.handle_key(refuse, "enter", refuse_api), "denied")
        H.contains("refuse_message", H.joined(SETTINGS.render(refuse, 26, 20)),
            "save failed")
    end
end
