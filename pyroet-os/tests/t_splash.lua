--[[- pyroet-os/tests/t_splash.lua -- the boot splash: what it draws, when it is
-- cleared, and when it must not draw at all.

The splash lives in system/startup.lua itself (P.SPLASH_*), so this suite drives
the real chain. The offline runner boots headless and sets
`_G.PYROET_DESKTOP_TEST`, which turns the splash off; the one override that turns
it back on for a headless run is `opts.splash = true`, and that is what the
drawing cases below pass. The skip cases pass nothing and prove the splash stays
away for a headless boot, an explicit `splash = false` and the suite itself.

Every screen assertion reads cells out of tests/screen.lua (the same buffer the
BIOS suite uses), and every log assertion reads the chain's own injected logger.

No non-ASCII bytes in this file.
]]

local S = dofile("/tests/screen.lua")

rawset(_G, "PYROET_STARTUP_TEST", true)
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

return function(H)
    local F = H.real_fs()
    local BANNER = "Pyroet OS " .. startup.VERSION
    local LOGO = startup.SPLASH_LOGO

    local function pad(text, w)
        if #text >= w then return text:sub(1, w) end
        return text .. string.rep(" ", w - #text)
    end

    -- a sandbox root the bootloader accepts: it insists on a /system dir
    local function system_tree(dir)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/kernel/ota.lua", "-- ota\n")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=0.2.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
        return dir
    end

    -- one full chain run: `opts` carries what the case is about, the buffer is
    -- the screen and `shots` is every splash frame (a snapshot per step wait)
    local function drive(dir, opts)
        local o = opts or {}
        local buf = S.buffer(51, 19)
        local log, lines = H.logger()
        local shots = {}
        local result, why = nil, nil
        local ok, err = S.with_term(buf, function()
            local frame = startup.default_frame({ term = buf })
            result = startup.run({
                fs = F,
                root = dir,
                log_path = dir .. "/kernel.log",
                term = buf,
                log = o.log or log,
                apps_root = dir .. "/apps",
                system_root = false,
                reboot = function() error("rebooted unexpectedly") end,
                splash = o.splash,
                headless = o.headless,
                loop = o.loop,
                clock = o.clock,
                sleep = o.sleep or function() shots[#shots + 1] = buf.snapshot() end,
                frame = o.frame or frame,
            })
        end)
        why = err
        return { buf = buf, log = log, lines = lines, shots = shots,
            result = result, ok = ok, why = why }
    end

    -- -----------------------------------------------------------------
    H.group("splash.lines")
    do
        -- the bar: exact cells, then the two ends clamped
        H.eq("bar_0", startup.splash_bar(0), "[            ]   0%")
        H.eq("bar_33", startup.splash_bar(33), "[####        ]  33%")
        H.eq("bar_66", startup.splash_bar(66), "[########    ]  66%")
        H.eq("bar_100", startup.splash_bar(100), "[############] 100%")
        H.eq("bar_low", startup.splash_bar(-9), "[            ]   0%")
        H.eq("bar_high", startup.splash_bar(250), "[############] 100%")
        H.eq("bar_width_6", startup.splash_bar(50, 6), "[###   ]  50%")

        -- a 20 row screen: logo on rows 4..7, version 9, bar 12, step 13
        local lines = startup.splash_lines(
            { version = "9.9.9", pct = 33, step = "starting services" }, 26, 20)
        H.eq("rows", #lines, 20)
        local widest = 0
        for i = 1, #lines do
            if #lines[i] > widest then widest = #lines[i] end
            H.eq("width_" .. tostring(i), #lines[i], 26)
        end
        H.eq("widest", widest, 26)
        H.eq("logo_1", lines[4], pad(LOGO[1], 26))
        H.eq("logo_2", lines[5], pad(LOGO[2], 26))
        H.eq("logo_3", lines[6], pad(LOGO[3], 26))
        H.eq("logo_4", lines[7], pad(LOGO[4], 26))
        H.eq("logo_row3_blank", lines[3], pad("", 26))
        H.eq("version", lines[9], pad("Pyroet OS 9.9.9", 26))
        H.eq("bar", lines[12], pad("[####        ]  33%", 26))
        H.eq("step", lines[13], pad("starting services", 26))
        H.eq("blank_below", lines[14], pad("", 26))
        H.eq("logo_cells", lines[4]:sub(5, 16), LOGO[1]:sub(5, 16))

        -- a 19 row console keeps the same key rows
        local console = startup.splash_lines({ version = "0.2.0", pct = 0, step = "checking system" }, 51, 19)
        H.eq("console_rows", #console, 19)
        H.eq("console_logo_1", console[4], pad(LOGO[1], 51))
        H.eq("console_version", console[9], pad("Pyroet OS 0.2.0", 51))
        H.eq("console_bar", console[12], pad(startup.splash_bar(0), 51))
        H.eq("console_step", console[13], pad("checking system", 51))

        -- a short screen drops the logo and keeps the words
        local short = startup.splash_lines({ version = "0.2.0", pct = 100, step = "desktop" }, 26, 10)
        H.eq("short_rows", #short, 10)
        H.eq("short_version", short[2], pad("Pyroet OS 0.2.0", 26))
        H.eq("short_bar", short[5], pad("[############] 100%", 26))
        H.eq("short_step", short[6], pad("desktop", 26))
        for i = 1, #short do
            if #short[i] ~= 26 then H.check("short_width_" .. tostring(i), false, #short[i]) end
        end

        -- one row, and one column: clamped, never wider than the screen
        local tiny = startup.splash_lines({ version = "0.2.0", pct = 0, step = "x" }, 4, 1)
        H.eq("tiny_rows", #tiny, 1)
        H.eq("tiny_width", #tiny[1], 4)

        -- the steps the bar follows, in order
        H.eq("step_count", #startup.SPLASH_STEPS, 3)
        H.eq("step_1", startup.SPLASH_STEPS[1], "checking system")
        H.eq("step_2", startup.SPLASH_STEPS[2], "starting services")
        H.eq("step_3", startup.SPLASH_STEPS[3], "desktop")
        H.eq("sleep_is_short", startup.SPLASH_SLEEP, 0.05)

        -- the enable rules, as a table
        H.eq("off_explicit", select(2, startup.splash_enabled({ splash = false })), "disabled")
        H.eq("off_splash_false", startup.splash_enabled({ splash = false }), false)
        H.eq("on_forced", startup.splash_enabled({ splash = true }), true)
        H.eq("off_headless", startup.splash_enabled({ headless = true }), false)
        H.eq("headless_reason", select(2, startup.splash_enabled({ headless = true })), "headless")
        H.eq("off_loop_false", startup.splash_enabled({ loop = false }), false)
        H.eq("off_test", startup.splash_enabled({}), false)
        H.eq("test_reason", select(2, startup.splash_enabled({})), "test")
    end

    -- -----------------------------------------------------------------
    H.group("splash.draw")
    -- A normal boot with the splash forced on: four frames (0/33/66/100%), each one
    -- asserted as cells, and the last one cleared again before the first frame.
    do
        local dir = system_tree(H.case_dir("splash", "draw"))
        local frames = {}
        for i = 1, #startup.SPLASH_STEPS do
            frames[i] = {
                pct = math.floor((i * 100) / #startup.SPLASH_STEPS),
                step = startup.SPLASH_STEPS[i],
            }
        end
        local run = drive(dir, {
            splash = true,
            clock = (function()
                local n = 0
                return function()
                    n = n + 1
                    if n == 1 then return 0 end
                    return 0.25
                end
            end)(),
        })

        H.check("run_ok", run.ok, tostring(run.why))
        H.check("boot_ok", run.result ~= nil and run.result.ok == true,
            "result=" .. tostring(run.result and run.result.ok))
        H.eq("boot_plan", run.result and run.result.plan.action, "normal")
        H.eq("frames", #run.shots, #startup.SPLASH_STEPS + 1)
        H.has(run.lines, "SPLASH_BEGIN version=" .. startup.VERSION)
        H.has(run.lines, "SPLASH_DONE ms=250")
        H.lacks("no_abort", run.lines, "SPLASH_ABORT")
        H.lacks("no_skip", run.lines, "SPLASH_SKIP")
        -- the splash is announced before anything the boot decided
        local begin_at = H.index_of(run.lines, "SPLASH_BEGIN")
        local plan_at = H.index_of(run.lines, "STARTUP_PLAN action=normal")
        H.check("begin_after_plan", begin_at ~= nil and plan_at ~= nil and plan_at < begin_at,
            "plan=" .. tostring(plan_at) .. " begin=" .. tostring(begin_at))
        local done_at = H.index_of(run.lines, "SPLASH_DONE")
        local ready_at = H.index_of(run.lines, "STARTUP_UI_READY")
        H.check("done_before_frame", done_at ~= nil and ready_at ~= nil and done_at < ready_at,
            "done=" .. tostring(done_at) .. " ready=" .. tostring(ready_at))

        -- frame 1 is the 0% picture: logo, version, an empty bar, step 1
        local first = run.shots[1]
        H.check("first_shot", first ~= nil, "no snapshot was taken")
        H.eq("first_clears", first and first.clears, 1)
        H.eq("first_logo_1", first and first.rows[4], pad(LOGO[1], 51))
        H.eq("first_logo_4", first and first.rows[7], pad(LOGO[4], 51))
        H.eq("first_version", first and first.rows[9], pad("Pyroet OS " .. startup.VERSION, 51))
        H.eq("first_bar", first and first.rows[12], pad("[            ]   0%", 51))
        H.eq("first_step", first and first.rows[13], pad("checking system", 51))

        -- every frame after it: the bar filled further, the step name advanced
        for i = 1, #frames do
            local snap = run.shots[i + 1]
            local want = frames[i]
            H.check("shot_" .. tostring(i) .. "_taken", snap ~= nil, "no snapshot")
            if snap ~= nil then
                H.eq("shot_" .. tostring(i) .. "_bar",
                    snap.rows[12], pad(startup.splash_bar(want.pct), 51))
                H.eq("shot_" .. tostring(i) .. "_step",
                    snap.rows[13], pad(want.step, 51))
                H.eq("shot_" .. tostring(i) .. "_logo",
                    snap.rows[4], pad(LOGO[1], 51))
            end
        end
        H.eq("last_bar", run.shots[4] and run.shots[4].rows[12],
            pad("[############] 100%", 51))
        H.eq("last_step", run.shots[4] and run.shots[4].rows[13], pad("desktop", 51))

        -- and the screen the boot moved on to: the first frame, no logo left
        H.eq("final_row1", run.buf.row(1), pad(BANNER, 51))
        H.eq("final_no_logo", run.buf.find_row(".----------."), nil)
        H.eq("final_no_bar", run.buf.find_row("[############]"), nil)
        -- 4 splash paints + the one clear `splash_done` takes + the frame's own
        H.eq("final_clears", run.buf.stats.clears, 6)
        H.eq("final_no_scroll", run.buf.stats.scrolls, 0)
        H.eq("final_text_has_no_logo",
            run.buf.text():find("PYROET", 1, true), nil)
    end

    -- -----------------------------------------------------------------
    H.group("splash.fatal")
    -- No /system: the plan is fatal before the splash is ever drawn, so the FATAL
    -- lines own the screen from row 1 and no logo is painted -- not even once.
    do
        local dir = H.case_dir("splash", "fatal")
        local buf = S.buffer(51, 19)
        local log, lines = H.logger()
        -- the real shape of the console: the boot logger both records and prints
        -- (`print` renders through the installed buffer), which is what makes the
        -- "the FATAL lines own the screen" assertion a screen assertion
        local function sink(line)
            log(line)
            print(line)
        end
        local drawn = 0
        local result = nil
        local ok, why = S.with_term(buf, function()
            result = startup.run({
                fs = F,
                root = dir,
                log = sink,
                log_path = dir .. "/kernel.log",
                term = buf,
                apps_root = dir .. "/apps",
                system_root = false,
                splash = true,
                sleep = function() drawn = drawn + 1 end,
                reboot = function() error("rebooted unexpectedly") end,
            })
        end)
        H.check("fatal_run_ok", ok, tostring(why))
        H.check("fatal", result ~= nil and result.fatal == true,
            "fatal=" .. tostring(result and result.fatal))
        H.eq("fatal_error", result and result.error, "no_system")
        H.eq("no_splash_waits", drawn, 0)
        H.lacks("no_begin", lines, "SPLASH_BEGIN")
        H.lacks("no_abort", lines, "SPLASH_ABORT")
        H.lacks("no_done", lines, "SPLASH_DONE")
        H.eq("no_clear", buf.stats.clears, 0)
        H.eq("no_logo", buf.find_row(".----------."), nil)
        H.eq("fatal_row", buf.find_row("BOOT_FATAL reason=no_system") ~= nil, true)
        H.has(lines, "BOOT_FATAL reason=no_system")
        H.has(lines, "STARTUP_FATAL reason=no_system")
    end

    -- -----------------------------------------------------------------
    H.group("splash.skip")
    -- The three ways the splash stays off. None of them may clear the screen: the
    -- frame is the first thing drawn, exactly like before the splash existed.
    do
        local function skipped(label, opts)
            local dir = system_tree(H.case_dir("splash", label))
            local run = drive(dir, opts)
            H.check(label .. "_ok", run.ok, tostring(run.why))
            H.check(label .. "_boot", run.result ~= nil and run.result.ok == true, "boot failed")
            H.eq(label .. "_clears", run.buf.stats.clears, 1)
            H.eq(label .. "_no_logo", run.buf.find_row(".----------."), nil)
            H.eq(label .. "_banner", run.buf.row(1), pad(BANNER, 51))
            return run
        end

        local off = skipped("off", { splash = false })
        H.has(off.lines, "SPLASH_SKIP reason=disabled")
        H.lacks("off_no_begin", off.lines, "SPLASH_BEGIN")

        local headless = skipped("headless", { headless = true })
        H.has(headless.lines, "SPLASH_SKIP reason=headless")

        local loopless = skipped("loopless", { loop = false })
        H.has(loopless.lines, "SPLASH_SKIP reason=headless")

        -- the suite's own skip is silent on purpose: every other screen suite
        -- counts boot-log rows, and a new line would shift them
        local suite = skipped("suite", {})
        H.lacks("suite_no_begin", suite.lines, "SPLASH_BEGIN")
        H.lacks("suite_no_skip", suite.lines, "SPLASH_SKIP")
    end

    -- -----------------------------------------------------------------
    H.group("splash.no_terminal")
    -- A boot with no terminal at all (a monitor-only host) still boots; the splash
    -- reports why it is not drawing and nothing raises.
    do
        local dir = system_tree(H.case_dir("splash", "noterm"))
        local log, lines = H.logger()
        local result = nil
        local saved = rawget(_G, "term")
        rawset(_G, "term", nil)
        local ok, why = pcall(function()
            result = startup.run({
                fs = F,
                root = dir,
                log = log,
                log_path = dir .. "/kernel.log",
                apps_root = dir .. "/apps",
                system_root = false,
                splash = true,
                frame = function() return true end,
                reboot = function() error("rebooted unexpectedly") end,
            })
        end)
        rawset(_G, "term", saved)
        H.check("noterm_run_ok", ok, tostring(why))
        H.check("noterm_boot", result ~= nil and result.ok == true, "boot failed")
        H.has(lines, "SPLASH_SKIP reason=no_terminal")
        H.lacks("noterm_no_begin", lines, "SPLASH_BEGIN")
    end
end
