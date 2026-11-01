--[[- pyroet-os/tests/t_desktop_loop.lua -- D1: the resident desktop event loop.

Two halves, because the loop has two jobs that fail differently:

  1. `kernel/desktop.lua` on its own, against a fake app runtime and a scripted
     pull source. This is where the *dispatcher* is pinned down: one pull per
     iteration (the machine's only sleep), keycode -> key name normalization,
     `terminate` handled by the dispatcher and never delivered, foreground
     handover to an app that declares `input`, and the exit words
     (`quit` / `crash` / `terminate` / `limit`).
  2. the real boot chain (`system/startup.lua`) with `pull_event` injected, the
     real app runtime and the real launcher package: the commit happens first,
     the chain does NOT return while the loop runs, down/enter/escape work
     through `api.input.pullEvent`, the launched app really starts, and Esc
     unwinds `startup.run` with `desktop_reason=quit` so the console gets the
     machine back.
  3. `desktop_loop.screen`: the same chain driven with `tests/screen.lua`
     installed as `_G.term`, which is the only way to catch a *painting* bug
     (D1-fix: a launched app that cannot own the console used to repaint the
     screen on every tick the launcher did not, so every row grew an `s` tag and
     the selection looked stuck).

`tests/run.lua` sets `_G.PYROET_DESKTOP_TEST`, which keeps every other suite
headless; supplying `pull_event` is what turns the loop on here.

No non-ASCII bytes in this file.
]]

_G.PYROET_STARTUP_TEST = true
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

local DESKTOP = dofile("/system/kernel/desktop.lua")
local APPS = dofile("/system/kernel/apps.lua")
local S = dofile("/tests/screen.lua")

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)

-- a deliberately small key table: the test states its own vocabulary instead of
-- borrowing the emulator's keycodes
local KEYS = { up = 10, down = 11, left = 12, right = 13, enter = 14, escape = 15 }

-- the input queue the dispatcher fills and an app drains (same shape as
-- startup.default_input, written out here so the test does not depend on it)
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

-- a pull source that hands out the scripted events in order, then blocks...
-- except a test cannot block, so it returns `terminate`: an exhausted script
-- ends the loop the same way Ctrl+T would. Functions are not indexable in
-- CraftOS, so the pull count comes back in its own table.
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

-- a fake app runtime: records, a status() view, and one drain per tick
local function fake_runtime(host)
    local rt = { records = {}, ticks = 0, drained = {}, host = host }
    function rt.add(name, caps)
        rt.records[#rt.records + 1] = {
            name = name, state = "running", starts = 1, result = nil,
            manifest = { capabilities = caps },
        }
    end
    -- colon-shaped like the real runtime (apps.lua: function A:app(name))
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
            local event, a = host.pullEvent()
            if event ~= nil then rt.drained[#rt.drained + 1] = { event, a } end
        end
        if rt.on_tick then rt.on_tick(rt) end
        return true
    end
    return rt
end

return function(H)
    local F = H.real_fs()

    local function bootable(dir)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.dispatcher")
    do
        -- keycodes become names, and the preferred names win
        local map = DESKTOP.key_map(KEYS)
        H.eq("key_up", map[10], "up")
        H.eq("key_enter", map[14], "enter")
        H.eq("key_escape", map[15], "escape")
        H.eq("key_unknown", map[999], nil)
        -- no keys table at all: no keycode names
        H.eq("key_map_no_table", DESKTOP.key_map(nil)[10], nil)

        local host = new_host()
        local rt = fake_runtime(host)
        rt.add("launcher", { "input" })
        local pull, pull_stats = scripted({ { "key", 10 }, { "key", 11 } })
        local log, lines = H.logger()
        local d = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt, input = host, pullEvent = pull, keys = KEYS,
            name = "launcher", log = log, max_events = 2,
        })
        H.eq("limit_reason", d:run(), "limit")
        H.eq("limit_pulled", d.pulled, 2)
        H.eq("limit_ticked", d.ticked, 2)
        H.eq("limit_delivered", d.delivered, 2)
        H.eq("limit_pulls", pull_stats.pulls, 2)
        -- exactly one event per tick, normalized to a name
        H.eq("drained_count", #rt.drained, 2)
        H.eq("drained_first", rt.drained[1][1] .. "/" .. tostring(rt.drained[1][2]),
            "key/up")
        H.eq("drained_second", rt.drained[2][1] .. "/" .. tostring(rt.drained[2][2]),
            "key/down")
        H.has(lines, "DESKTOP_ENTRY app=launcher keys=6")
        H.has(lines, "DESKTOP_EVENT n=1 event=key arg=up app=launcher")
        H.has(lines, "DESKTOP_EVENT n=2 event=key arg=down app=launcher")
        H.has(lines, "DESKTOP_EXIT reason=limit pulled=2 ticks=2 delivered=2")
        H.eq("state_exited", d:state().exited, true)
        H.eq("state_reason", d:state().reason, "limit")

        -- terminate is the dispatcher's own exit: it is never delivered
        local host2 = new_host()
        local rt2 = fake_runtime(host2)
        rt2.add("launcher", { "input" })
        local log2, lines2 = H.logger()
        local d2 = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt2, input = host2, keys = KEYS, name = "launcher", log = log2,
            pullEvent = scripted({ { "key", 10 }, { "terminate" } }),
        })
        H.eq("term_reason", d2:run(), "terminate")
        H.eq("term_pulled", d2.pulled, 2)
        H.eq("term_delivered", d2.delivered, 1)
        H.eq("term_drain", #rt2.drained, 1)
        H.has(lines2, "DESKTOP_EXIT reason=terminate pulled=2")

        -- the ROM has no `keys.escape`; a terminal that sends it still uses the
        -- GLFW code, and the dispatcher hands the app a name for it
        local host9 = new_host()
        local rt9 = fake_runtime(host9)
        rt9.add("launcher", { "input" })
        local d9 = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt9, input = host9, keys = KEYS, name = "launcher",
            pullEvent = scripted({ { "key", DESKTOP.ESCAPE_CODE } }), max_events = 1,
        })
        H.eq("escape_code_reason", d9:run(), "limit")
        H.eq("escape_code_delivered", #rt9.drained, 1)
        H.eq("escape_code_name", rt9.drained[1][2], "escape")

        -- the body returning "quit" is the desktop leaving the scheduler
        local host3 = new_host()
        local rt3 = fake_runtime(host3)
        rt3.add("launcher", { "input" })
        local log3, lines3 = H.logger()
        local d3 = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt3, input = host3, keys = KEYS, name = "launcher", log = log3,
            pullEvent = scripted({ { "key", 11 }, { "key", 11 } }),
        })
        rt3.on_tick = function(self)
            self:app("launcher").state = "stopped"
            self:app("launcher").result = "quit"
        end
        H.eq("quit_reason", d3:run(), "quit")
        H.eq("quit_pulled", d3.pulled, 1)
        H.has(lines3, "DESKTOP_DETACH app=launcher reason=quit")
        H.eq("quit_exited", d3.exited, true)

        -- a crashed body is reported, not hidden
        local host4 = new_host()
        local rt4 = fake_runtime(host4)
        rt4.add("launcher", { "input" })
        local log4, lines4 = H.logger()
        local d4 = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt4, input = host4, keys = KEYS, name = "launcher", log = log4,
            pullEvent = scripted({ { "key", 11 } }),
        })
        rt4.on_tick = function(self)
            self:app("launcher").state = "crashed"
        end
        H.eq("crash_reason", d4:run(), "crash")
        H.has(lines4, "DESKTOP_DETACH app=launcher reason=crash")

        -- handover: an app that declares input and starts during the step takes
        -- the keyboard, and the next event is addressed to it
        local host5 = new_host()
        local rt5 = fake_runtime(host5)
        rt5.add("launcher", { "input" })
        local log5, lines5 = H.logger()
        local d5 = DESKTOP.new({ ready_paint = false, power_menu = false,
            rt = rt5, input = host5, keys = KEYS, name = "launcher", log = log5,
            pullEvent = scripted({ { "key", 10 }, { "key", 10 } }),
            max_events = 2,
        })
        rt5.on_tick = function(self)
            if self.ticks == 1 then
                self.add("editor", { "input", "terminal" })
                self.records[#self.records].starts = 2
            end
        end
        H.eq("handover_reason", d5:run(), "limit")
        H.eq("handover_foreground", d5.foreground, "editor")
        H.eq("handover_count", d5.handovers, 1)
        H.has(lines5, "DESKTOP_FOREGROUND app=editor reason=launch")
        H.has(lines5, "DESKTOP_EVENT n=2 event=key arg=up app=editor")

        -- nothing to drive it: skip, never crash, and never pull
        local silent, silent_stats = scripted({ { "key", 10 } })
        local d6 = DESKTOP.new({ ready_paint = false, power_menu = false, rt = fake_runtime(new_host()), input = new_host(),
            name = "launcher" })
        H.eq("no_pull_reason", d6:run(), "no_pull_source")
        H.eq("no_pull_pulled", d6.pulled, 0)
        local log7, lines7 = H.logger()
        local d7 = DESKTOP.new({ ready_paint = false, power_menu = false, rt = fake_runtime(nil), pullEvent = silent,
            name = "launcher", log = log7 })
        H.eq("no_queue_reason", d7:run(), "no_input_queue")
        H.has(lines7, "DESKTOP_SKIP reason=no_input_queue")
        local log8, lines8 = H.logger()
        local d8 = DESKTOP.new({ ready_paint = false, power_menu = false, input = new_host(), pullEvent = silent,
            name = "launcher", log = log8 })
        H.eq("no_runtime_reason", d8:run(), "no_runtime")
        H.has(lines8, "DESKTOP_SKIP reason=no_runtime")
        H.eq("silent_untouched", silent_stats.pulls, 0)
        H.ascii_check("dispatcher_logs_ascii", H.joined(lines) .. H.joined(lines5))
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.queue")
    do
        local host = startup.default_input()
        H.table("queue_host", host)
        H.eq("queue_empty", host.pullEvent(), nil)
        H.eq("queue_pending_empty", host.pending(), 0)
        host.push("key", "up")
        local event, a = host.pullEvent()
        H.eq("queue_event", event, "key")
        H.eq("queue_arg", a, "up")
        H.eq("queue_drained", host.pullEvent(), nil)

        -- the os.pullEvent filter rule: non-matching events are dropped
        host.push("char", "a")
        host.push("key", "down")
        local filtered, farg = host.pullEvent("key")
        H.eq("queue_filter_event", filtered, "key")
        H.eq("queue_filter_arg", farg, "down")

        -- bounded: an app that never pulls cannot grow the machine's queue
        for i = 1, startup.INPUT_QUEUE_MAX + 5 do host.push("key", "up") end
        H.eq("queue_bounded", host.pending(), startup.INPUT_QUEUE_MAX)
        H.eq("queue_dropped", host.dropped, 5)
        for i = 1, startup.INPUT_QUEUE_MAX do host.pullEvent() end
        H.eq("queue_emptied", host.pending(), 0)

        -- the dispatcher's raw pull is the ROM's own: it must never be what an
        -- app gets (an app would block the machine)
        H.eq("queue_raw_pull", type(host.pull), "function")
        H.eq("queue_keys", host.keys, rawget(_G, "keys"))
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.boot")
    do
        H.rmrf("/etc/perms")
        local dir = H.case_dir("loop", "boot")
        bootable(dir)
        local host = new_host()
        host.keys = KEYS
        local log, lines = H.logger()
        local pulls = 0
        local committed_at_first_pull = false
        local events = {
            { "key", 11 },   -- down: the launcher moves to "net"
            { "key", 14 },   -- enter: start net.app through api.sys.launch
            -- net declares input now: Enter is a full handover (keyboard+screen),
            -- so this escape goes to net and quits it ...
            { "key", 15 },
            -- ... the launcher gets the screen back, and Ctrl+T leaves the
            -- desktop (q on the desktop is only a hint now)
            { "terminate" },
        }
        local pull = function()
            pulls = pulls + 1
            if pulls == 1 then
                -- the proof that the chain is already past the commit while the
                -- loop is pulling: the marker is in the log before event one
                committed_at_first_pull = H.found(lines, "STARTUP_COMMITTED")
            end
            local event = events[pulls]
            if event == nil then return "terminate" end
            return event[1], event[2], event[3], event[4]
        end
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            input = host,
            pull_event = pull,
            start_timer = function() return 7 end,
            desktop_events = 8,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })

        H.check("boot_ok", result.ok == true, "boot failed")
        H.eq("boot_committed", result.committed, true)
        H.table("boot_desktop", result.desktop)
        H.eq("boot_desktop_reason", result.desktop_reason, "terminate")
        H.eq("boot_pulled", result.desktop and result.desktop.pulled, 4)
        H.ge("boot_ticked", result.desktop and result.desktop.ticked, 4)
        H.ge("boot_delivered", result.desktop and result.desktop.delivered, 4)
        -- net declares input: launch handover, then the screen back to launcher
        H.eq("boot_handovers", result.desktop and result.desktop.handovers, 2)
        H.eq("boot_loans", result.desktop and result.desktop.loans, 0)
        H.check("boot_commit_before_first_pull", committed_at_first_pull,
            "the desktop pulled before the commit")

        -- four events, four pulls: no polling, no extra scheduler steps
        H.eq("boot_pulls", pulls, 4)

        -- the loop is entered after the commit and only logs its exit when it
        -- comes back
        H.has(lines, "STARTUP_DESKTOP_ENTER name=launcher source=injected")
        H.has(lines, "DESKTOP_ENTRY app=launcher keys=6")
        local commit_at = H.index_of(lines, "STARTUP_COMMITTED")
        local enter_at = H.index_of(lines, "STARTUP_DESKTOP_ENTER")
        local exit_at = H.index_of(lines, "DESKTOP_EXIT reason=terminate")
        local chain_exit = H.index_of(lines, "STARTUP_DESKTOP_EXIT reason=terminate")
        H.check("commit_before_enter", commit_at ~= nil and enter_at ~= nil
            and commit_at < enter_at, "commit=" .. tostring(commit_at)
            .. " enter=" .. tostring(enter_at))
        H.check("enter_before_exit", enter_at ~= nil and exit_at ~= nil
            and enter_at < exit_at, "enter=" .. tostring(enter_at)
            .. " exit=" .. tostring(exit_at))
        H.check("loop_before_chain_exit", exit_at ~= nil and chain_exit ~= nil
            and exit_at < chain_exit, "exit=" .. tostring(exit_at)
            .. " chain=" .. tostring(chain_exit))

        -- down moved the selection to net, enter handed keyboard+screen to net,
        -- escape quit net, the second escape quit the desktop
        H.has(lines, "DESKTOP_EVENT n=1 event=key arg=down app=launcher")
        H.has(lines, "DESKTOP_EVENT n=2 event=key arg=enter app=launcher")
        H.has(lines, "DESKTOP_EVENT n=3 event=key arg=escape app=net")
        H.has(lines, "DESKTOP_EVENT n=4 event=terminate app=-")
        H.has(lines, "DESKTOP_TERMINATE scope=desktop event=terminate")
        H.has(lines, "APP_LOG app=launcher msg=key=down action=move index=2 sel=net")
        H.has(lines, "APP_LOG app=launcher msg=key=enter action=launch"
            .. " index=2 sel=net detail=net")
        H.has(lines, "APP_START name=net")
        -- the handover: net gets both, escape quits it, the launcher takes the
        -- screen back and is told to repaint (no loan: net owns a keyboard now)
        H.has(lines, "DESKTOP_FOREGROUND app=net reason=launch")
        H.has(lines, "APP_EXIT app=net")
        H.has(lines, "DESKTOP_FOREGROUND app=launcher reason=settle")
        H.has(lines, "APP_LOG app=launcher msg=focus msg=back from net")
        -- the desktop itself does not quit on a letter: it is still running,
        -- the machine is just handed back to the shell by Ctrl+T
        H.lacks("boot_no_launcher_quit", lines, "app=launcher msg=quit")

        -- one handling per event: two keys produced two app log lines (escape
        -- quits before it logs a key action), so nothing repainted in a loop
        H.eq("boot_key_logs", H.count(lines, "APP_LOG app=launcher msg=key="), 2)
        H.eq("boot_launcher_state", result.apps:app("launcher").state, "running")
        H.ascii_check("boot_logs_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.migrate")
    -- The real-machine failure (D1 fix): the demo disk had booted the previous
    -- image once, so /etc/perms/launcher.cfg held only fs.read + fs.write. After
    -- the update the launcher declares input + terminal, both were denied by the
    -- old file, the launcher went `no_input` and the desktop pulled (and dropped)
    -- every keystroke: keys did nothing, only the mouse cursor moved. This group
    -- boots the real chain on that exact disk state and proves the desktop is
    -- usable again, so the bug cannot come back silently.
    do
        H.rmrf("/etc/perms")
        H.write("/etc/perms/launcher.cfg",
            "# PYROET-PERMS-1 app=launcher\nfs.read=granted\nfs.write=granted\n")
        local dir = H.case_dir("loop", "migrate")
        bootable(dir)
        local host = new_host()
        host.keys = KEYS
        local log, lines = H.logger()
        local pulls = 0
        local events = {
            { "key", 11 },   -- down -> net
            { "key", 14 },   -- enter -> handover to net (it declares input now)
            { "key", 15 },   -- escape -> net quits
            { "terminate" }, -- Ctrl+T -> the desktop leaves for the shell
        }
        local pull = function()
            pulls = pulls + 1
            local event = events[pulls]
            if event == nil then return "terminate" end
            return event[1], event[2], event[3], event[4]
        end
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            input = host,
            pull_event = pull,
            start_timer = function() return 7 end,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })

        H.eq("migrate_ok", result.ok, true)
        -- the stale file was extended, not ignored: the new caps are granted
        H.has(lines, "PERMS_STALE app=launcher caps=input,terminal")
        H.has(lines, "APP_PERMS_APPLIED app=launcher granted=4 denied=0")
        local cfg = H.read("/etc/perms/launcher.cfg") or ""
        H.contains("migrate_cfg_input", cfg, "input=granted")
        H.contains("migrate_cfg_terminal", cfg, "terminal=granted")
        H.lacks("migrate_no_input_denial", lines, "APP_CAP_DENIED app=launcher cap=input")
        H.lacks("migrate_no_terminal_denial", lines,
            "APP_CAP_DENIED app=launcher cap=terminal")

        -- and the keyboard works: down moved the selection, enter handed net the
        -- keyboard+screen, escape quit net, the launcher came back and quit
        H.eq("migrate_desktop_reason", result.desktop_reason, "terminate")
        H.has(lines, "STARTUP_DESKTOP_ENTER name=launcher source=injected")
        H.has(lines, "DESKTOP_EVENT n=1 event=key arg=down app=launcher")
        H.has(lines, "APP_LOG app=launcher msg=key=down action=move index=2 sel=net")
        H.has(lines, "APP_START name=net")
        H.has(lines, "DESKTOP_FOREGROUND app=net reason=launch")
        H.has(lines, "APP_EXIT app=net")
        H.has(lines, "DESKTOP_FOREGROUND app=launcher reason=settle")
        H.has(lines, "APP_LOG app=launcher msg=focus msg=back from net")
        H.eq("migrate_net_result", result.apps:app("net").result, "quit")
        H.eq("migrate_launcher_state", result.apps:app("launcher").state, "running")
        H.eq("migrate_pulls", pulls, 4)
        H.ascii_check("migrate_logs_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.grant")
    -- Declared is not granted: a desktop whose keyboard or screen was refused must
    -- not hold the console. It falls back to the shell after one log line instead
    -- of eating every event (the second half of the same fix).
    do
        local function run_with_ask(ask)
            H.rmrf("/etc/perms")
            local dir = H.case_dir("loop", "grant_" .. tostring(ask))
            bootable(dir)
            local host = new_host()
            host.keys = KEYS
            local log, lines = H.logger()
            local pulls = 0
            local result = startup.run({
                fs = F,
                root = dir,
                log = log,
                apps_root = dir .. "/apps",
                input = host,
                pull_event = function() pulls = pulls + 1 return "terminate" end,
                ask = ask,
                reboot = function() error("rebooted unexpectedly") end,
                power_menu = false,
            frame = function() return true end,
            })
            return result, lines, pulls
        end

        local result, lines, pulls = run_with_ask(function() return false end)
        H.eq("input_denied_reason", result.desktop_reason, "skip:input_denied")
        H.eq("input_denied_no_desktop", result.desktop, nil)
        H.eq("input_denied_no_pull", pulls, 0)
        H.has(lines, "STARTUP_DESKTOP_SKIP reason=input_denied app=launcher")
        H.lacks("input_denied_no_enter", lines, "DESKTOP_ENTRY")

        local result2, lines2, pulls2 = run_with_ask(function(app, cap)
            return cap ~= "terminal"
        end)
        H.eq("terminal_denied_reason", result2.desktop_reason, "skip:terminal_denied")
        H.eq("terminal_denied_no_pull", pulls2, 0)
        H.has(lines2, "STARTUP_DESKTOP_SKIP reason=terminal_denied app=launcher")
        H.eq("terminal_denied_input_granted",
            result2.apps:app("launcher").perms and result2.apps:app("launcher").perms.input,
            true)
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.screen")
    -- D1-fix round 3: a launched app that declares no `input` used to be parked,
    -- which read as "Enter did nothing". It now gets a SCREEN LOAN: it is
    -- scheduled for real, its own frame lands on the screen, the launcher is not
    -- scheduled while the loan lasts, and the loan ends when the app stops by
    -- itself or when the loan timer fires (an app without a keyboard can never
    -- hand the screen back). `_G.term` is the buffer here, so an app that paints
    -- the ROM terminal directly lands in the frame the user would see.
    do
        local function painter(name, text, stop)
            return {
                manifest = 'return { name = "' .. name .. '", version = "0.1.0",'
                    .. ' capabilities = { "fs.read" } }',
                main = string.format([[
return function(manifest, api)
    local t = rawget(_G, "term")
    for y = 1, 19 do
        t.setCursorPos(1, y)
        t.write(%q .. " " .. tostring(y) .. string.rep(" ", 40))
    end
    if %s then
        api.yield()
        return "quit"
    end
    while true do api.yield() end
end
]], text, stop and "true" or "false"),
            }
        end

        local function boot(apps, events, tag)
            H.rmrf("/apps")
            for i = 1, #apps do
                H.app_package("/apps/" .. apps[i].name .. ".app", apps[i].spec)
            end
            H.rmrf("/etc/perms")
            local dir = H.case_dir("loop", "screen_" .. tostring(tag))
            bootable(dir)
            local host = new_host()
            host.keys = KEYS
            local log, lines = H.logger()
            local buf = S.buffer(51, 19)
            local frames, pulls = {}, 0
            local function snap()
                local out = {}
                for y = 1, 19 do out[y] = buf.row(y) end
                return out
            end
            local pull = function()
                frames[pulls + 1] = snap()
                pulls = pulls + 1
                local event = events[pulls]
                if event == nil then return "terminate" end
                return event[1], event[2], event[3]
            end
            local result = nil
            local saved = rawget(_G, "PYROET_APP_NOPAINT")
            rawset(_G, "PYROET_APP_NOPAINT", nil)
            local okrun, why = pcall(function()
                local okw, value = S.with_term(buf, function()
                    return startup.run({
                        fs = F,
                        root = dir,
                        log = log,
                        apps_root = "/apps",
                        input = host,
                        pull_event = pull,
                        terminal = buf,
                        start_timer = function() return 7 end,
                        reboot = function() error("rebooted unexpectedly") end,
                        power_menu = false,
            frame = function() return true end,
                    })
                end)
                result = value
                return okw
            end)
            rawset(_G, "PYROET_APP_NOPAINT", saved)
            return {
                result = result, lines = lines, frames = frames, buf = buf,
                pulls = pulls, ok = okrun and why == true,
            }
        end

        local list_rows = { 3, 4, 5, 6 }
        local function heads(frame)
            local out = {}
            for i = 1, #list_rows do
                out[i] = ((frame or {})[list_rows[i]] or ""):sub(1, 2)
            end
            return table.concat(out, "|")
        end
        local function markers(frame)
            local count, where = 0, nil
            for i = 1, #list_rows do
                local row = (frame or {})[list_rows[i]] or ""
                if row:sub(1, 1) == ">" then count = count + 1; where = i end
            end
            return count, where
        end

        -- 1) three packages that declare no `input` are each *visible* when
        --    launched, the loan timer brings the launcher back, and the launcher
        --    refuses to start itself (logged, not silent)
        local run1 = boot({
            { name = "aainstaller", spec = painter("aainstaller", "installer ui", false) },
            { name = "aanet", spec = painter("aanet", "net probe", false) },
            { name = "aasettings", spec = painter("aasettings", "settings ui", false) },
        }, {
            { "key", 14 },    -- 1: launch aainstaller (index 1)
            { "timer", 7 },   -- 2: loan ends, launcher back
            { "key", 11 },    -- 3: down -> aanet (index 2)
            { "key", 14 },    -- 4: launch aanet
            { "timer", 7 },   -- 5: loan ends
            { "key", 11 },    -- 6: down -> aasettings (index 3)
            { "key", 14 },    -- 7: launch aasettings
            { "timer", 7 },   -- 8: loan ends
            { "key", 11 },    -- 9: down -> launcher (index 4)
            { "key", 14 },    -- 10: self-launch, refused
            { "terminate" },  -- 11
        }, "visible")

        H.check("screen_ok", run1.ok, tostring(run1.result))
        H.eq("screen_reason", run1.result and run1.result.desktop_reason, "terminate")
        -- after each Enter the app's own frame is on screen, not the launcher
        for i = 1, 3 do
            local at = ({ 2, 5, 8 })[i]
            local want = ({ "installer ui", "net probe", "settings ui" })[i]
            local joined = table.concat(run1.frames[at] or {}, "\n")
            H.contains("screen_visible_" .. tostring(i), joined, want)
            H.absent("screen_no_list_" .. tostring(i), joined, "apps sel")
        end
        H.eq("screen_loans", run1.result and run1.result.desktop.loans, 3)
        H.eq("screen_loan_ends", run1.result and run1.result.desktop.loan_ends, 3)
        for _, name in ipairs({ "aainstaller", "aanet", "aasettings" }) do
            H.has(run1.lines, "DESKTOP_LOAN app=" .. name .. " reason=no_input caps=1")
            H.has(run1.lines, "DESKTOP_LOAN_END app=" .. name .. " reason=timeout")
            H.has(run1.lines, "APP_LOG app=launcher msg=focus msg=display only: " .. name)
        end
        -- the launcher's list is back after the last loan: exactly one marker,
        -- and the verbatim first two characters of every row
        local back = run1.frames[9]
        H.eq("screen_back_markers", (markers(back)), 1)
        H.eq("screen_back_heads", heads(back), "  |  |> |  ")
        H.contains("screen_back_status", (back or {})[19] or "", "6 apps sel 3/6")
        -- the launcher launched itself: refused, logged, the screen stays
        H.has(run1.lines, "APP_START_DENIED name=launcher reason=already_running")
        H.contains("screen_self_message", (run1.frames[11] or {})[18] or "",
            "cannot start launcher")
        H.contains("screen_self_status", (run1.frames[11] or {})[19] or "",
            "6 apps sel 4/6")
        H.ascii_check("screen_logs_ascii", H.joined(run1.lines))

        -- 2) an app that stops by itself ends the loan without any timer, and the
        --    keyboard works again on the next key
        local run2 = boot({
            { name = "aastop", spec = painter("aastop", "stop ui", true) },
        }, {
            { "key", 14 },    -- 1: launch aastop (paints, yields)
            { "key", 11 },    -- 2: tick it once more -> it returns, loan ends
            { "key", 11 },    -- 3: the launcher handles this one
            { "terminate" },
        }, "stop")
        H.check("stop_ok", run2.ok, tostring(run2.result))
        H.eq("stop_reason", run2.result and run2.result.desktop_reason, "terminate")
        H.contains("stop_visible", table.concat(run2.frames[2] or {}, "\n"), "stop ui")
        H.has(run2.lines, "DESKTOP_LOAN app=aastop reason=no_input caps=1")
        H.has(run2.lines, "DESKTOP_LOAN_END app=aastop reason=stopped")
        H.has(run2.lines, "APP_LOG app=launcher msg=focus msg=display only: aastop")
        -- frame 3 is after the loan ended: launcher back with the hint;
        -- frame 4 is after the next key: the marker moved (keyboard is back)
        H.contains("stop_hint", (run2.frames[3] or {})[18] or "",
            "display only: aastop")
        H.eq("stop_back_markers", (markers(run2.frames[3])), 1)
        local count, where = markers(run2.frames[4])
        H.eq("stop_moved_markers", count, 1)
        H.eq("stop_moved_row", where, 2)
        H.eq("stop_moved_heads", heads(run2.frames[4]), "  |> |  |  ")
        H.contains("stop_status", (run2.frames[4] or {})[19] or "", "4 apps sel 2/4")
        H.ascii_check("stop_logs_ascii", H.joined(run2.lines))
        H.rmrf("/apps")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.loan_abort")
    -- Whatever happens, a loan has to end (round 5): stopped / timeout / abort.
    -- These cases drive the abort path (hard step cap, and "no timer at all"),
    -- then prove the launcher is back on screen and the next key works -- while
    -- the kernel services were never touched by the loan.
    do
        local function painter(name, text)
            return {
                manifest = 'return { name = "' .. name .. '", version = "0.1.0",'
                    .. ' capabilities = { "fs.read" } }',
                main = string.format([[
return function(manifest, api)
    local t = rawget(_G, "term")
    for y = 1, 19 do
        t.setCursorPos(1, y)
        t.write(%q .. " " .. tostring(y) .. string.rep(" ", 40))
    end
    while true do api.yield() end
end
]], text),
            }
        end

        local function once(tag, events, opts)
            H.rmrf("/apps")
            H.app_package("/apps/aaforever.app", painter("aaforever", "forever ui"))
            H.rmrf("/etc/perms")
            local dir = H.case_dir("loop", "abort_" .. tag)
            bootable(dir)
            local host = new_host()
            host.keys = KEYS
            local log, lines = H.logger()
            local buf = S.buffer(51, 19)
            local frames, pulls = {}, 0
            local function snap()
                local out = {}
                for y = 1, 19 do out[y] = buf.row(y) end
                return out
            end
            local pull = function()
                frames[pulls + 1] = snap()
                pulls = pulls + 1
                local event = events[pulls]
                if event == nil then return "terminate" end
                return event[1], event[2]
            end
            local result = nil
            local saved = rawget(_G, "PYROET_APP_NOPAINT")
            rawset(_G, "PYROET_APP_NOPAINT", nil)
            local okrun, why = pcall(function()
                local okw, value = S.with_term(buf, function()
                    return startup.run({
                        fs = F,
                        root = dir,
                        log = log,
                        apps_root = "/apps",
                        input = host,
                        pull_event = pull,
                        terminal = buf,
                        start_timer = opts.start_timer,
                        loan_seconds = 15,
                        loan_events = opts.loan_events or 1000,
                        loan_abort_events = opts.loan_abort_events,
                        reboot = function() error("rebooted unexpectedly") end,
                        power_menu = false,
            frame = function() return true end,
                    })
                end)
                result = value
                return okw
            end)
            rawset(_G, "PYROET_APP_NOPAINT", saved)
            return { result = result, lines = lines, frames = frames,
                pulls = pulls, ok = okrun and why == true }
        end

        -- 1) the loan timer is armed but never fires, so the hard step cap ends
        --    the loan: DESKTOP_LOAN_ABORT reason=events -> back to the launcher
        local run1 = once("events", {
            { "key", 14 },   -- launch aaforever (index 1)
            { "key", 11 },
            { "key", 11 },
            { "key", 11 },
            { "key", 11 },   -- 4 events: the 4th hits loan_abort_events = 4
        }, {
            start_timer = function() return 99 end,
            loan_events = 1000,
            loan_abort_events = 4,
        })
        H.check("abort_run_ok", run1.ok, tostring(run1.result))
        H.has(run1.lines, "DESKTOP_LOAN app=aaforever reason=no_input caps=1")
        H.has(run1.lines, "DESKTOP_LOAN_ABORT app=aaforever reason=events")
        H.has(run1.lines, "DESKTOP_LOAN_END app=aaforever reason=abort")
        H.has(run1.lines, "DESKTOP_PARK app=aaforever reason=loan_over")
        H.has(run1.lines, "DESKTOP_FOREGROUND app=launcher reason=loan_end")
        H.has(run1.lines, "APP_LOG app=launcher msg=focus msg=display only: aaforever")
        -- the launcher is back on screen: its list, not the app's frame
        local back = run1.frames[6]
        local joined = table.concat(back or {}, "\n")
        H.absent("abort_launcher_list", joined, "forever ui")
        H.contains("abort_launcher_status", joined, "apps sel")
        -- the loan never starved the kernel: every service is still running
        local status = run1.result and run1.result.kernel:status()
        H.eq("abort_kernel_health", status and status.health, "ok")
        H.check("abort_services_running",
            status ~= nil and (status.counts.running or 0) >= 1,
            "running=" .. tostring(status and status.counts.running))

        -- 2) no timer at all: a loan cannot be started, the app is parked and
        --    the desktop says why (never a frame that cannot be left)
        local run2 = once("notimer", {
            { "key", 14 },   -- launch aaforever
            { "key", 11 },   -- the launcher handles this one right away
        }, {
            start_timer = function() return nil end,
        })
        H.check("notimer_run_ok", run2.ok, tostring(run2.result))
        H.has(run2.lines, "DESKTOP_LOAN_TIMER_SKIP reason=no_timer")
        H.has(run2.lines, "DESKTOP_LOAN_ABORT app=aaforever reason=no_timer")
        H.has(run2.lines, "DESKTOP_PARK app=aaforever reason=no_timer")
        H.has(run2.lines, "APP_LOG app=launcher msg=focus msg=display only: aaforever")
        -- the next key moved the launcher's own marker (keyboard is back)
        local after = table.concat(run2.frames[3] or {}, "\n")
        H.contains("notimer_marker", after, "> launcher")
        H.rmrf("/apps")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.ready")
    -- Round 7: entering the desktop must be READY, not "ready after a key". The
    -- chain paints the launcher at step 7b, but the commit lines printed after it
    -- land on that frame; the desktop now paints the foreground once, after the
    -- quiet logger is installed and before the first blocking pull.
    do
        local function painter(name, text)
            return {
                manifest = 'return { name = "' .. name .. '", version = "0.1.0",'
                    .. ' capabilities = { "fs.read" } }',
                main = string.format([[
return function(manifest, api)
    local t = rawget(_G, "term")
    for y = 1, 19 do
        t.setCursorPos(1, y)
        t.write(%q .. " " .. tostring(y) .. string.rep(" ", 40))
    end
    while true do api.yield() end
end
]], text),
            }
        end

        local function boot_with(events, apps_root)
            H.rmrf("/etc/perms")
            local dir = H.case_dir("loop", "ready")
            bootable(dir)
            local host = new_host()
            host.keys = KEYS
            local log, lines = H.logger()
            local buf = S.buffer(51, 19)
            local frames, pulls = {}, 0
            local function snap()
                local out = {}
                for y = 1, 19 do out[y] = buf.row(y) end
                return out
            end
            local pull = function()
                frames[pulls + 1] = snap()
                pulls = pulls + 1
                local event = events[pulls]
                if event == nil then return "terminate" end
                return event[1], event[2]
            end
            local result = nil
            local saved = rawget(_G, "PYROET_APP_NOPAINT")
            rawset(_G, "PYROET_APP_NOPAINT", nil)
            local okrun, why = pcall(function()
                local okw, value = S.with_term(buf, function()
                    return startup.run({
                        fs = F,
                        root = dir,
                        log = log,
                        apps_root = apps_root or (dir .. "/apps"),
                        input = host,
                        pull_event = pull,
                        terminal = buf,
                        start_timer = function() return 7 end,
                        reboot = function() error("rebooted unexpectedly") end,
                        power_menu = false,
            frame = function() return true end,
                    })
                end)
                result = value
                return okw
            end)
            rawset(_G, "PYROET_APP_NOPAINT", saved)
            return { run = result, lines = lines, frames = frames,
                pulls = pulls, ok = okrun and why == true }
        end

        -- 1) ZERO keys: the frame captured before the very first pull is already
        --    the full desktop (list, marker, hint row, status row)
        local first = boot_with({ { "terminate" } })
        H.check("ready_run_ok", first.ok, tostring(first.run))
        H.has(first.lines, "DESKTOP_READY app=launcher")
        H.eq("ready_pulls", first.pulls, 1)
        local f = first.frames[1]
        H.table("ready_frame", f)
        H.contains("ready_title", (f or {})[1] or "", "ver ")
        H.eq("ready_sel_row", ((f or {})[3] or ""):sub(1, 10), "> launcher")
        H.eq("ready_hint_row", ((f or {})[18] or ""):sub(1, 15), "up/dn enter run")
        H.contains("ready_status", (f or {})[19] or "", "apps sel 1/")
        H.absent("ready_no_boot_log", table.concat(f or {}, "\n"), "STARTUP_COMMITTED")
        H.ascii_check("ready_ascii", H.joined(first.lines))

        -- 2) back from an app: escape quits net, and the frame captured at the
        --    NEXT pull is already the launcher again (no key in between)
        local back = boot_with({
            { "key", 11 },   -- down -> net
            { "key", 14 },   -- enter -> net takes the console
            { "key", 15 },   -- escape -> net quits
            { "terminate" },
        })
        H.check("back_run_ok", back.ok, tostring(back.run))
        H.eq("back_pulls", back.pulls, 4)
        local returned = back.frames[4]
        local rtext = table.concat(returned or {}, "\n")
        H.contains("back_list", rtext, "apps sel")
        H.eq("back_hint", ((returned or {})[18] or ""):sub(1, 13), "back from net")
        H.contains("back_marker", rtext, "> ")

        -- 3) back from a screen loan: the loan timer ends it and the next frame
        --    is the launcher again, still without a key press
        H.rmrf("/apps")
        H.app_package("/apps/aaforever.app", painter("aaforever", "forever ui"))
        local loan = boot_with({
            { "key", 14 },   -- launch aaforever (index 1)
            { "timer", 7 },  -- the loan timer ends the loan
            { "terminate" },
        }, "/apps")
        H.check("loan_back_run_ok", loan.ok, tostring(loan.run))
        H.has(loan.lines, "DESKTOP_LOAN_END app=aaforever reason=timeout")
        local after_loan = loan.frames[3]
        local ltext = table.concat(after_loan or {}, "\n")
        H.contains("loan_back_list", ltext, "apps sel")
        H.contains("loan_back_hint", (after_loan or {})[18] or "", "display only: ")
        H.rmrf("/apps")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.power")
    -- Round 8: Ctrl+T no longer leaves the machine. The desktop intercepts
    -- `terminate`/`shutdown` and opens a power menu drawn by the launcher
    -- (Shutdown / Reboot / Cancel). os.shutdown and os.reboot are STUBBED here:
    -- the suite must never really shut the machine down.
    do
        local saved_shutdown = rawget(_G, "os").shutdown
        local saved_reboot = rawget(_G, "os").reboot
        local calls = { shutdown = 0, reboot = 0 }

        local function stub_power(with_shutdown)
            rawget(_G, "os").shutdown = with_shutdown and function()
                calls.shutdown = calls.shutdown + 1
            end or nil
            rawget(_G, "os").reboot = function() calls.reboot = calls.reboot + 1 end
        end

        local function boot_power(events, opts)
            local o = opts or {}
            H.rmrf("/etc/perms")
            local dir = H.case_dir("loop", "power")
            bootable(dir)
            local host = new_host()
            host.keys = KEYS
            local log, lines = H.logger()
            local buf = S.buffer(51, 19)
            local frames, pulls = {}, 0
            local function snap()
                local out = {}
                for y = 1, 19 do out[y] = buf.row(y) end
                return out
            end
            local pull = function()
                frames[pulls + 1] = snap()
                pulls = pulls + 1
                local event = events[pulls]
                if event == nil then return nil end
                return event[1], event[2]
            end
            local result = nil
            local saved = rawget(_G, "PYROET_APP_NOPAINT")
            rawset(_G, "PYROET_APP_NOPAINT", nil)
            local okrun, why = pcall(function()
                local okw, value = S.with_term(buf, function()
                    return startup.run({
                        fs = F,
                        root = dir,
                        log = log,
                        apps_root = dir .. "/apps",
                        input = host,
                        pull_event = pull,
                        terminal = buf,
                        desktop_events = #events + 1,
                        start_timer = function() return 7 end,
                        reboot = function() error("rebooted unexpectedly") end,
                        frame = function() return true end,
                    })
                end)
                result = value
                return okw
            end)
            rawset(_G, "PYROET_APP_NOPAINT", saved)
            return { run = result, lines = lines, frames = frames,
                pulls = pulls, ok = okrun and why == true }
        end

        -- 1) Ctrl+T on the desktop -> the menu, and the loop never returns
        --    "terminate" (it ends on the event bound instead)
        stub_power(true)
        local one = boot_power({
            { "terminate" },      -- Ctrl+T
            { "key", "down" },    -- Update -> Shutdown
            { "key", "down" },    -- Shutdown -> Reboot
            { "key", "enter" },   -- run it (stubbed)
            { "key", "escape" },  -- cancel
        })
        H.check("power_run_ok", one.ok, tostring(one.run))
        H.eq("power_reason", one.run and one.run.desktop_reason, "limit")
        H.lacks("power_no_terminate", one.lines, "STARTUP_DESKTOP_EXIT reason=terminate")
        H.has(one.lines, "DESKTOP_POWER_MENU scope=desktop event=terminate")
        -- the menu on screen, verbatim: title, three entries, marker on row 3
        local menu = one.frames[2] or {}
        H.eq("power_title", (menu[1] or ""):sub(1, 10), "Power 0.2.")
        H.contains("power_row3", menu[3] or "", "> Update")
        H.contains("power_row4", menu[4] or "", "  Shutdown")
        H.contains("power_row5", menu[5] or "", "  Reboot")
        H.contains("power_row6", menu[6] or "", "  Cancel")
        H.eq("power_hint", (menu[19] or ""):sub(1, 19), "enter runs q=cancel")
        -- down moved the marker to Reboot
        local moved = one.frames[4] or {}
        H.contains("power_moved_off", moved[4] or "", "  Shutdown")
        H.contains("power_moved_on", moved[5] or "", "> Reboot")
        -- enter ran Reboot exactly once, logged BEFORE acting, and Shutdown was
        -- not called at all
        H.eq("power_reboot_calls", calls.reboot, 1)
        H.eq("power_shutdown_calls", calls.shutdown, 0)
        H.has(one.lines, "POWER reboot requested")
        -- Esc cancelled back to the desktop: row 18 is the normal hint again
        local back = one.frames[6] or {}
        H.eq("power_cancel_hint", (back[18] or ""):sub(1, 15), "up/dn enter run")
        H.contains("power_cancel_list", table.concat(back, "\n"), "apps sel")
        H.has(one.lines, "power menu cancel")

        -- 2) inside an app Ctrl+T leaves the APP first; only the next Ctrl+T on
        --    the desktop opens the menu
        calls.reboot, calls.shutdown = 0, 0
        stub_power(true)
        local two = boot_power({
            { "key", 11 },      -- down -> net
            { "key", 14 },      -- enter -> net takes the console
            { "terminate" },    -- scope=app: net quits, no menu
            { "terminate" },    -- now on the desktop: the menu opens
        })
        H.check("power_app_run_ok", two.ok, tostring(two.run))
        H.has(two.lines, "DESKTOP_TERMINATE scope=app app=net event=terminate")
        H.has(two.lines, "APP_EXIT app=net")
        H.eq("power_menu_once", H.count(two.lines, "DESKTOP_POWER_MENU"), 1)
        H.eq("power_app_no_reboot", calls.reboot, 0)

        -- 3) a ROM without os.shutdown: the entry says so, nothing crashes
        calls.reboot, calls.shutdown = 0, 0
        stub_power(false)
        local three = boot_power({
            { "terminate" },
            { "key", "down" },   -- move onto the unavailable Shutdown entry
        })
        H.check("power_missing_run_ok", three.ok, tostring(three.run))
        local missing = three.frames[2] or {}
        H.contains("power_missing_row3", missing[3] or "", "> Update")
        H.contains("power_missing_row4", missing[4] or "", "  Shutdown unavailable")
        H.contains("power_missing_row5", missing[5] or "", "  Reboot")
        local moved_missing = three.frames[3] or {}
        H.contains("power_missing_reason", table.concat(moved_missing, "\n"),
            "os.shutdown unavailable")

        rawget(_G, "os").shutdown = saved_shutdown
        rawget(_G, "os").reboot = saved_reboot
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.leave")
    -- Exit semantics of round 6: on the desktop q/Q/escape are only a hint -- the
    -- machine stays; Ctrl+T is the way out, and it is scoped: while an app owns
    -- the console it leaves the app, on the desktop it leaves the system.
    do
        H.rmrf("/etc/perms")
        local dir = H.case_dir("loop", "leave")
        bootable(dir)
        local host = new_host()
        host.keys = KEYS
        local log, lines = H.logger()
        local buf = S.buffer(51, 19)
        local frames, pulls = {}, 0
        local function snap()
            local out = {}
            for y = 1, 19 do out[y] = buf.row(y) end
            return out
        end
        -- 1: q on the desktop (must stay)  2: terminate (must leave the system)
        local events = { { "char", "q" }, { "terminate" } }
        local pull = function()
            frames[pulls + 1] = snap()
            pulls = pulls + 1
            local event = events[pulls]
            if event == nil then return "terminate" end
            return event[1], event[2]
        end
        local result = nil
        local saved = rawget(_G, "PYROET_APP_NOPAINT")
        rawset(_G, "PYROET_APP_NOPAINT", nil)
        local okrun, why = pcall(function()
            local okw, value = S.with_term(buf, function()
                return startup.run({
                    fs = F,
                    root = dir,
                    log = log,
                    apps_root = dir .. "/apps",
                    input = host,
                    pull_event = pull,
                    terminal = buf,
                    start_timer = function() return 7 end,
                    reboot = function() error("rebooted unexpectedly") end,
                    power_menu = false,
            frame = function() return true end,
                })
            end)
            result = value
            return okw
        end)
        rawset(_G, "PYROET_APP_NOPAINT", saved)
        H.check("leave_run_ok", okrun and why == true, tostring(result))
        -- q did NOT leave the system: the desktop ran until the terminate
        H.eq("leave_reason", result and result.desktop_reason, "terminate")
        H.eq("leave_pulled", result and result.desktop.pulled, 2)
        H.has(lines, "APP_LOG app=launcher msg=leave hint char=q scope=desktop")
        H.has(lines, "DESKTOP_TERMINATE scope=desktop event=terminate")
        H.lacks("leave_no_quit", lines, "app=launcher msg=quit")
        H.lacks("leave_no_detach_quit", lines, "reason=quit")
        -- the frame after q is still the desktop, with the hint verbatim on row 18
        local after_q = frames[2]
        local joined = table.concat(after_q or {}, "\n")
        H.contains("leave_list_still_there", joined, "apps sel")
        H.eq("leave_hint_row", ((after_q or {})[18] or ""):sub(1, 23),
            "Ctrl+T opens power menu")
        H.contains("leave_marker", joined, ">")
        H.ascii_check("leave_ascii", H.joined(lines))

        -- and while an app owns the console, terminate leaves the APP only
        H.rmrf("/etc/perms")
        local dir2 = H.case_dir("loop", "leave_app")
        bootable(dir2)
        local host2 = new_host()
        host2.keys = KEYS
        local log2, lines2 = H.logger()
        local events2 = {
            { "key", 11 },      -- down -> net
            { "key", 14 },      -- enter -> handover to net
            { "terminate" },    -- scope=app: net quits, the desktop stays
            { "terminate" },    -- scope=desktop: now it leaves
        }
        local pulls2 = 0
        local pull2 = function()
            pulls2 = pulls2 + 1
            local event = events2[pulls2]
            if event == nil then return "terminate" end
            return event[1], event[2]
        end
        local result2 = startup.run({
            fs = F,
            root = dir2,
            log = log2,
            apps_root = dir2 .. "/apps",
            input = host2,
            pull_event = pull2,
            start_timer = function() return 7 end,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("leave_app_reason", result2.desktop_reason, "terminate")
        H.has(lines2, "DESKTOP_TERMINATE scope=app app=net event=terminate")
        H.has(lines2, "APP_EXIT app=net")
        H.has(lines2, "DESKTOP_FOREGROUND app=launcher reason=settle")
        H.has(lines2, "DESKTOP_TERMINATE scope=desktop event=terminate")
        H.eq("leave_app_pulls", pulls2, 4)
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.terminate")
    do
        H.rmrf("/etc/perms")
        local dir = H.case_dir("loop", "terminate")
        bootable(dir)
        local host = new_host()
        host.keys = KEYS
        local log, lines = H.logger()
        local pulls = 0
        local pull = function()
            pulls = pulls + 1
            if pulls == 1 then return "key", 11 end
            return "terminate"
        end
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            input = host,
            pull_event = pull,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("term_ok", result.ok, true)
        H.eq("term_reason", result.desktop_reason, "terminate")
        H.eq("term_pulled", result.desktop and result.desktop.pulled, 2)
        H.eq("term_delivered", result.desktop and result.desktop.delivered, 2)
        H.has(lines, "STARTUP_DESKTOP_EXIT reason=terminate")
        -- the launcher never saw the terminate event; the dispatcher owns it
        H.lacks("term_not_delivered", lines, "msg=key=terminate")
        H.eq("term_launcher_running", result.apps:app("launcher").state, "running")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.skip")
    do
        -- the offline suite: no injection, no loop, and the chain says why
        H.rmrf("/etc/perms")
        local dir = H.case_dir("loop", "guard")
        bootable(dir)
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("guard_ok", result.ok, true)
        H.eq("guard_desktop", result.desktop, nil)
        H.eq("guard_reason", result.desktop_reason, "skip:test")
        H.has(lines, "STARTUP_DESKTOP_SKIP reason=test")

        -- an explicit headless boot
        H.rmrf("/etc/perms")
        local dir2 = H.case_dir("loop", "headless")
        bootable(dir2)
        local log2, lines2 = H.logger()
        local result2 = startup.run({
            fs = F,
            root = dir2,
            log = log2,
            apps_root = dir2 .. "/apps",
            loop = false,
            pull_event = function() return "terminate" end,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("headless_reason", result2.desktop_reason, "skip:disabled")
        H.has(lines2, "STARTUP_DESKTOP_SKIP reason=disabled")

        -- no launcher package at all: nothing to hand the console to
        H.rmrf("/etc/perms")
        local dir3 = H.case_dir("loop", "nodesktop")
        bootable(dir3)
        local log3, lines3 = H.logger()
        local pulls3 = 0
        local result3 = startup.run({
            fs = F,
            root = dir3,
            log = log3,
            apps_root = dir3 .. "/apps",
            system_root = false,
            pull_event = function() pulls3 = pulls3 + 1 return "terminate" end,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("nodesktop_reason", result3.desktop_reason, "skip:no_desktop")
        H.has(lines3, "STARTUP_DESKTOP_SKIP reason=no_desktop")
        H.eq("nodesktop_no_pull", pulls3, 0)

        -- the hello placeholder declares no `input`: a painted fallback, not a
        -- keyboard owner
        H.rmrf("/etc/perms")
        local dir4 = H.case_dir("loop", "noinput")
        bootable(dir4)
        H.app_package(dir4 .. "/apps/hello.app", {
            manifest = 'return { name = "hello", version = "0.1.0",'
                .. ' capabilities = { "fs.read" } }',
            main = "return function(manifest, api) api.yield() end",
        })
        local log4, lines4 = H.logger()
        local result4 = startup.run({
            fs = F,
            root = dir4,
            log = log4,
            apps_root = dir4 .. "/apps",
            system_root = false,
            pull_event = function() return "terminate" end,
            reboot = function() error("rebooted unexpectedly") end,
            power_menu = false,
            frame = function() return true end,
        })
        H.eq("noinput_reason", result4.desktop_reason, "skip:no_input")
        H.has(lines4, "STARTUP_DESKTOP_SKIP reason=no_input app=hello")

        -- a fatal boot never reaches the loop: there is nothing on the machine
        -- to drive, and the fatal path still reports and returns
        local dir5 = H.case_dir("loop", "fatal")
        local log5, lines5 = H.logger()
        local pulls5 = 0
        local result5 = startup.run({
            fs = F,
            root = dir5,
            log = log5,
            apps_root = dir5 .. "/apps",
            system_root = false,
            pull_event = function() pulls5 = pulls5 + 1 return "terminate" end,
            power_menu = false,
            reboot = function() error("rebooted unexpectedly") end,
        })
        H.eq("fatal_flag", result5.fatal, true)
        H.eq("fatal_error", result5.error, "no_system")
        H.eq("fatal_no_desktop", result5.desktop, nil)
        H.eq("fatal_no_pull", pulls5, 0)
        H.lacks("fatal_no_enter", lines5, "STARTUP_DESKTOP_ENTER")
        H.lacks("fatal_no_desktop_log", lines5, "DESKTOP_ENTRY")
    end

    -- -----------------------------------------------------------------
    H.group("desktop_loop.launcher_keys")
    do
        -- the launcher's pure event mapping, without a runtime: Esc and q quit,
        -- arrows move, digits select, Enter launches through api.sys
        local launched = nil
        local api = {
            fs = { read = function() return nil, "denied" end,
                list = function() return {} end,
                exists = function() return false end },
            sys = {
                apps = function() return {} end,
                launch = function(name) launched = name return true end,
            },
            log = function() end,
        }
        local state = LAUNCHER.build(api)
        -- q / Q / escape are "back" on the desktop: they only draw the hint and
        -- never leave Pyroet OS (Ctrl+T is the way out, asserted below)
        H.eq("map_escape", LAUNCHER.dispatch_event(state, "key", "escape", nil, api),
            "repaint")
        H.eq("map_escape_hint", state.message, LAUNCHER.LEAVE_HINT)
        H.eq("map_q", LAUNCHER.dispatch_event(state, "char", "q", nil, api), "repaint")
        H.eq("map_q_hint", state.message, LAUNCHER.LEAVE_HINT)
        H.eq("map_q_upper", LAUNCHER.dispatch_event(state, "char", "Q", nil, api),
            "repaint")
        H.eq("map_leave_hint", LAUNCHER.LEAVE_HINT, "Ctrl+T opens power menu")
        H.eq("map_unknown_char",
            LAUNCHER.dispatch_event(state, "char", "z", nil, api), "none")
        H.eq("map_unknown_event",
            LAUNCHER.dispatch_event(state, "rednet_message", "x", nil, api), "none")
        H.eq("map_resize", LAUNCHER.dispatch_event(state, "term_resize", nil, nil, api),
            "repaint")
        state.entries = { { name = "a", version = "1" }, { name = "b", version = "1" } }
        H.eq("map_down", LAUNCHER.dispatch_event(state, "key", "down", nil, api), "move")
        H.eq("map_index", state.index, 2)
        H.eq("map_enter", LAUNCHER.dispatch_event(state, "key", "enter", nil, api),
            "launch")
        H.eq("map_launched", launched, "b")
    end
end
