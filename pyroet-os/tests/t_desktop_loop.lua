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

`tests/run.lua` sets `_G.PYROET_DESKTOP_TEST`, which keeps every other suite
headless; supplying `pull_event` is what turns the loop on here.

No non-ASCII bytes in this file.
]]

_G.PYROET_STARTUP_TEST = true
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

local DESKTOP = dofile("/system/kernel/desktop.lua")
local APPS = dofile("/system/kernel/apps.lua")

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
        local d = DESKTOP.new({
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
        local d2 = DESKTOP.new({
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
        local d9 = DESKTOP.new({
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
        local d3 = DESKTOP.new({
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
        local d4 = DESKTOP.new({
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
        local d5 = DESKTOP.new({
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
        local d6 = DESKTOP.new({ rt = fake_runtime(new_host()), input = new_host(),
            name = "launcher" })
        H.eq("no_pull_reason", d6:run(), "no_pull_source")
        H.eq("no_pull_pulled", d6.pulled, 0)
        local log7, lines7 = H.logger()
        local d7 = DESKTOP.new({ rt = fake_runtime(nil), pullEvent = silent,
            name = "launcher", log = log7 })
        H.eq("no_queue_reason", d7:run(), "no_input_queue")
        H.has(lines7, "DESKTOP_SKIP reason=no_input_queue")
        local log8, lines8 = H.logger()
        local d8 = DESKTOP.new({ input = new_host(), pullEvent = silent,
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
            { "key", 11 },  -- down: the launcher moves to "net"
            { "key", 14 },  -- enter: start net.app through api.sys.launch
            { "key", 15 },  -- escape: quit, hand the machine back
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
            desktop_events = 8,
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })

        H.check("boot_ok", result.ok == true, "boot failed")
        H.eq("boot_committed", result.committed, true)
        H.table("boot_desktop", result.desktop)
        H.eq("boot_desktop_reason", result.desktop_reason, "quit")
        H.eq("boot_pulled", result.desktop and result.desktop.pulled, 3)
        H.eq("boot_ticked", result.desktop and result.desktop.ticked, 3)
        H.eq("boot_delivered", result.desktop and result.desktop.delivered, 3)
        H.eq("boot_handovers", result.desktop and result.desktop.handovers, 0)
        H.check("boot_commit_before_first_pull", committed_at_first_pull,
            "the desktop pulled before the commit")

        -- three events, three pulls: no polling, no extra scheduler steps
        H.eq("boot_pulls", pulls, 3)

        -- the loop is entered after the commit and only logs its exit when it
        -- comes back
        H.has(lines, "STARTUP_DESKTOP_ENTER name=launcher source=injected")
        H.has(lines, "DESKTOP_ENTRY app=launcher keys=6")
        local commit_at = H.index_of(lines, "STARTUP_COMMITTED")
        local enter_at = H.index_of(lines, "STARTUP_DESKTOP_ENTER")
        local exit_at = H.index_of(lines, "DESKTOP_EXIT reason=quit")
        local chain_exit = H.index_of(lines, "STARTUP_DESKTOP_EXIT reason=quit")
        H.check("commit_before_enter", commit_at ~= nil and enter_at ~= nil
            and commit_at < enter_at, "commit=" .. tostring(commit_at)
            .. " enter=" .. tostring(enter_at))
        H.check("enter_before_exit", enter_at ~= nil and exit_at ~= nil
            and enter_at < exit_at, "enter=" .. tostring(enter_at)
            .. " exit=" .. tostring(exit_at))
        H.check("loop_before_chain_exit", exit_at ~= nil and chain_exit ~= nil
            and exit_at < chain_exit, "exit=" .. tostring(exit_at)
            .. " chain=" .. tostring(chain_exit))

        -- down moved the selection to net, enter started it, escape quit
        H.has(lines, "DESKTOP_EVENT n=1 event=key arg=down app=launcher")
        H.has(lines, "DESKTOP_EVENT n=2 event=key arg=enter app=launcher")
        H.has(lines, "DESKTOP_EVENT n=3 event=key arg=escape app=launcher")
        H.has(lines, "APP_LOG app=launcher msg=key=down action=move index=2 sel=net")
        H.has(lines, "APP_LOG app=launcher msg=key=enter action=launch"
            .. " index=2 sel=net detail=net")
        H.has(lines, "APP_START name=net")
        H.eq("boot_net_running", result.apps:app("net").state, "running")
        H.has(lines, "APP_LOG app=launcher msg=quit key=escape")
        H.has(lines, "APP_EXIT app=launcher")
        H.has(lines, "DESKTOP_DETACH app=launcher reason=quit")

        -- one handling per event: two keys produced two app log lines (escape
        -- quits before it logs a key action), so nothing repainted in a loop
        H.eq("boot_key_logs", H.count(lines, "APP_LOG app=launcher msg=key="), 2)
        H.eq("boot_launcher_state", result.apps:app("launcher").state, "stopped")
        H.eq("boot_launcher_result", result.apps:app("launcher").result, "quit")
        H.ascii_check("boot_logs_ascii", H.joined(lines))
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
            frame = function() return true end,
        })
        H.eq("term_ok", result.ok, true)
        H.eq("term_reason", result.desktop_reason, "terminate")
        H.eq("term_pulled", result.desktop and result.desktop.pulled, 2)
        H.eq("term_delivered", result.desktop and result.desktop.delivered, 1)
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
        H.eq("map_escape", LAUNCHER.dispatch_event(state, "key", "escape", nil, api),
            "quit")
        H.eq("map_q", LAUNCHER.dispatch_event(state, "char", "q", nil, api), "quit")
        H.eq("map_q_upper", LAUNCHER.dispatch_event(state, "char", "Q", nil, api),
            "quit")
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
