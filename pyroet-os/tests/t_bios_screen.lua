--[[- pyroet-os/tests/t_bios_screen.lua -- what the BIOS/boot screen actually says.

The kernel/boot chain's screen was never asserted: the other suites drive
`startup.run` with `frame = function() return true end`, so they prove the frame
was *called* and never prove it drew anything.  This file reads the cells.

Everything here renders into the screen buffer from tests/screen.lua, which
installs itself as `term` so the ROM's own `print`/`write` go into it (measured on
CraftOS-PC 2.8.3).  Three screens are asserted, and each one is driven by the
production code:

  1. the first frame of a normal boot: `Pyroet OS <version>` / `kernel ok` /
     `normal journal none`, drawn from the real plan and the real kernel status,
     on an otherwise empty screen.  It is captured at the moment the frame
     returns, because the boot chain keeps logging over it afterwards -- asserting
     the final screen instead would assert the log echo, not the frame.
  2. the same frame during a trial boot, where the third line names the journal
     that is on trial (`trial journal applied`): the two branches are told apart
     by the cells, not by a log line.
  3. a boot with no /system tree: the frame never runs, so the screen keeps the
     boot log, starting at row 1 with `BOOT_NO_SYSTEM`, and the banner is absent.
  4. the root starter (`/startup.lua`) when /system/startup.lua cannot be loaded:
     the three ASCII lines it prints, at rows 1..3, columns 1, 10 and 1.

Every assertion that reads a cell says which row and column it read, so a failure
names the cell instead of only saying "the screen was wrong".

No non-ASCII bytes in this file.
]]

local S = dofile("/tests/screen.lua")

rawset(_G, "PYROET_STARTUP_TEST", true)
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

local BOOT = dofile("/system/boot.lua")
local STARTER = "/tests/root-startup.lua"

return function(H)
    local F = H.real_fs()
    local BANNER = "Pyroet OS " .. startup.VERSION
    local HINT = "shell only. Run recovery/flash.lua to reflash /system."

    -- the screen with every whitespace run collapsed: a long printed message may
    -- be wrapped onto the next row, and the wrap point drops the space it broke at
    local function flat(text)
        return (tostring(text):gsub("[\r\n\t]+", " "):gsub(" +", " "))
    end

    local function pad(text, w)
        if #text >= w then return text:sub(1, w) end
        return text .. string.rep(" ", w - #text)
    end

    local function row_is(name, buf, y, want)
        local got = buf.row(y)
        return H.check(name, got == want,
            "row " .. tostring(y) .. "=[" .. got .. "] want=[" .. want .. "]")
    end

    local function cell_is(name, buf, x, y, want)
        local got = buf.char(x, y)
        return H.check(name, got == want,
            "cell " .. tostring(x) .. "," .. tostring(y) .. "=["
            .. tostring(got) .. "] want=[" .. tostring(want) .. "]")
    end

    local function rows_blank(name, buf, from)
        local bad = nil
        for y = from, buf.h do
            if buf.trim(y) ~= "" then bad = y; break end
        end
        return H.check(name, bad == nil,
            "row " .. tostring(bad) .. " is not blank: ["
            .. tostring(bad and buf.trim(bad) or "") .. "]")
    end

    local function snap_row_is(name, snap, y, want)
        local got = snap and snap.rows[y] or nil
        return H.check(name, got == want,
            "row " .. tostring(y) .. "=[" .. tostring(got) .. "] want=[" .. want .. "]")
    end

    local function snap_rows_blank(name, snap, from)
        local bad = nil
        for y = from, (snap and snap.h or 0) do
            local text = snap.rows[y] or ""
            if text:gsub("%s+$", "") ~= "" then bad = y; break end
        end
        return H.check(name, bad == nil,
            "row " .. tostring(bad) .. " is not blank: ["
            .. tostring(bad and (snap.rows[bad] or "") or "") .. "]")
    end

    -- a sandbox root the bootloader will accept: it insists on a /system dir
    local function system_tree(dir)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/kernel/ota.lua", "-- ota\n")
        return dir
    end

    local function commit_marker(dir, version, manifest)
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=" .. version
            .. " manifest_sha=" .. manifest .. " ts=1700000000000")
    end

    -- -----------------------------------------------------------------
    H.group("bios.screen")
    -- The harness comes first.  A buffer that is wrong about the cursor, a colour
    -- or a scroll makes every screen assertion below agree with a wrong boot, so
    -- the buffer is pinned against the behaviour measured on the emulator.
    do
        local b = S.buffer()
        local w, h = b.size()
        H.eq("default_width", w, S.DEFAULT_W)
        H.eq("default_height", h, S.DEFAULT_H)
        H.eq("blank_char", b.char(1, 1), " ")
        H.eq("blank_fg", b.fg(1, 1), S.WHITE)
        H.eq("blank_bg", b.bg(1, 1), S.BLACK)
        H.eq("row_padded_to_width", #b.row(1), S.DEFAULT_W)
        H.eq("row_out_of_range", b.row(0), "")
        H.check("cell_out_of_range_is_nil", b.char(52, 1) == nil,
            "got=" .. tostring(b.char(52, 1)))

        -- write() clips at the right edge and does NOT clamp the cursor
        local t = S.buffer(4, 1)
        t.write("abcdef")
        row_is("write_clipped", t, 1, "abcd")
        local tx = t.getCursorPos()
        H.eq("write_cursor_past_edge", tx, 7)
        H.eq("write_clipped_cells", t.stats.clipped, 2)

        -- the current colour pair is what write() uses; blit() carries its own
        local c = S.buffer(6, 2)
        c.setBackgroundColor(S.BLACK)
        c.write("ab")
        H.eq("write_fg", c.fg(1, 1), S.WHITE)
        H.eq("write_bg", c.bg(1, 1), S.BLACK)
        c.setBackgroundColor(2 ^ 11)
        c.write("cd")
        H.eq("write_new_bg", c.bg(3, 1), 2 ^ 11)
        c.setCursorPos(1, 2)
        c.blit("ef", "f0", "0f")
        cell_is("blit_char", c, 1, 2, "e")
        H.eq("blit_fg", c.fg(1, 2), S.BLACK)
        H.eq("blit_bg", c.bg(1, 2), S.WHITE)
        local bx = c.getCursorPos()
        H.eq("blit_advances_cursor", bx, 3)

        -- clear() keeps the cursor where it was (measured on CraftOS-PC 2.8.3)
        local k = S.buffer(3, 2)
        k.setCursorPos(2, 2)
        k.setBackgroundColor(S.BLACK)
        k.clear()
        local kx, ky = k.getCursorPos()
        H.eq("clear_cursor_x", kx, 2)
        H.eq("clear_cursor_y", ky, 2)
        cell_is("clear_cleared", k, 1, 1, " ")
        H.eq("clear_bg", k.bg(1, 1), S.BLACK)

        -- scroll(n) moves rows up, blanks the bottom rows, keeps the cursor
        local s = S.buffer(3, 3)
        s.write("one")
        s.setCursorPos(1, 2)
        s.write("two")
        s.setCursorPos(1, 3)
        s.write("tre")
        s.scroll(1)
        row_is("scroll_row1", s, 1, "two")
        row_is("scroll_row2", s, 2, "tre")
        row_is("scroll_row3", s, 3, "   ")
        H.eq("scroll_count", s.stats.scrolls, 1)
        local sx, sy = s.getCursorPos()
        H.eq("scroll_cursor_x", sx, 4)
        H.eq("scroll_cursor_y", sy, 3)

        -- the ROM print renders through the installed buffer.  It wraps a line by
        -- width itself and, when the line ends on the last row, it scrolls after
        -- writing it (measured order: write, setCursorPos(1,h), scroll(1)), so the
        -- last chunk moves one row up and the bottom row is blank.
        local p = S.buffer(5, 3)
        local okp, errp = S.with_term(p, function() print(string.rep("X", 12)) end)
        H.check("print_renders", okp, tostring(errp))
        row_is("print_chunk1", p, 1, "XXXXX")
        row_is("print_chunk2", p, 2, "XX   ")
        row_is("print_chunk3", p, 3, "     ")
        local px, py = p.getCursorPos()
        H.eq("print_cursor_x", px, 1)
        H.eq("print_cursor_y", py, 3)
        H.eq("print_scrolled_once", p.stats.scrolls, 1)

        -- three short prints on a three row screen scroll one line per newline
        local q = S.buffer(3, 3)
        local okq, errq = S.with_term(q, function()
            print("a")
            print("b")
            print("c")
        end)
        H.check("print_short_ok", okq, tostring(errq))
        row_is("print_short_row1", q, 1, "b  ")
        row_is("print_short_row2", q, 2, "c  ")
        row_is("print_short_row3", q, 3, "   ")

        -- read-back helpers a failing suite needs
        H.eq("find_column", q.find(2, "c"), 1)
        H.eq("find_missing", q.find(2, "z"), nil)
        local fy = q.find_row("b")
        H.eq("find_row_row", fy, 1)
        H.eq("trim_row", q.trim(2), "c")
        H.eq("text_rows", select(2, q.text():gsub("\n", "\n")), 2)
        H.eq("count_calls_write", q.count_calls("write"), 3)
        local snap = q.snapshot()
        H.eq("snapshot_row2", snap.rows[2], "c  ")
        H.eq("snapshot_clears", snap.clears, 0)

        -- the log a suite reads is only every write up to a marker, which is how
        -- "the boot log was on the screen before the frame cleared it" is proven
        local logbuf = S.buffer(10, 2)
        logbuf.write("before")
        logbuf.clear()
        local clear_at = logbuf.call_index("clear")
        H.check("wrote_before_clear", logbuf.wrote_before(clear_at):find("before", 1, true) ~= nil,
            "got=[" .. logbuf.wrote_before(clear_at) .. "]")
        H.check("wrote_after_clear_empty", logbuf.wrote_before(clear_at + 1) == "before",
            "got=[" .. logbuf.wrote_before(clear_at + 1) .. "]")
    end

    -- -----------------------------------------------------------------
    H.group("bios.frame")
    -- A normal boot: the frame is the whole boot screen.  It is captured when the
    -- frame returns, before the commit and the desktop log over it.
    do
        local dir = system_tree(H.case_dir("bios", "frame"))
        commit_marker(dir, "0.2.0", H.HEX64)

        local buf = S.buffer(51, 19)
        local snap = nil
        local pre = nil
        local reboots = 0
        local result = nil
        local frame_scrolls = 0
        local frame = startup.default_frame({ term = buf })
        local okrun, why = S.with_term(buf, function()
            result = startup.run({
                fs = F,
                root = dir,
                log_path = dir .. "/kernel.log",
                term = buf,
                apps_root = dir .. "/apps",
                system_root = false,
                reboot = function() reboots = reboots + 1 end,
                frame = function(plan, status, rt)
                    pre = buf.snapshot()
                    local scrolls_before = buf.stats.scrolls
                    local ok = frame(plan, status, rt)
                    snap = buf.snapshot()
                    frame_scrolls = buf.stats.scrolls - scrolls_before
                    return ok
                end,
            })
        end)
        H.check("frame_run_ok", okrun, tostring(why))
        H.check("frame_boot_ok", result ~= nil and result.ok == true,
            "result=" .. tostring(result and result.ok))
        H.eq("frame_plan", result and result.plan.action, "normal")
        H.eq("frame_journal", result and result.plan.journal, nil)
        H.eq("frame_reboots", reboots, 0)
        H.eq("frame_version", startup.VERSION, "0.2.0")
        H.check("frame_snapshot_taken", snap ~= nil, "the frame never returned")

        -- the screen the frame itself drew, and nothing else
        H.eq("frame_clears", snap and snap.clears, 1)
        H.eq("frame_scrolls", frame_scrolls, 0)
        snap_row_is("frame_row1", snap, 1, pad(BANNER, 51))
        snap_row_is("frame_row2", snap, 2, pad("kernel ok", 51))
        snap_row_is("frame_row3", snap, 3, pad("normal journal none", 51))
        snap_rows_blank("frame_rows_4_19_blank", snap, 4)
        H.eq("frame_cursor_line", snap and snap.y, 3)
        H.eq("frame_cursor_column", snap and snap.x, 20)

        -- the cells that make up the banner, at their own columns
        cell_is("frame_cell_1_1", buf, 1, 1, "P")
        cell_is("frame_cell_8_1", buf, 8, 1, "O")
        cell_is("frame_cell_1_2", buf, 1, 2, "k")
        cell_is("frame_cell_8_2", buf, 8, 2, "o")
        cell_is("frame_cell_1_3", buf, 1, 3, "n")

        -- the screen the frame was handed: the boot log, not the banner.  The
        -- frame's job is to replace exactly that, so both halves are asserted.
        H.check("pre_frame_snapshot", pre ~= nil, "the frame was never called")
        H.eq("pre_frame_no_clear", pre and pre.clears, 0)
        H.check("pre_frame_has_log",
            pre ~= nil and pre.rows[1] ~= string.rep(" ", pre.w),
            "the console was blank before the frame: ["
            .. tostring(pre and pre.rows[1]) .. "]")
        H.check("pre_frame_no_banner",
            pre ~= nil and table.concat(pre.rows, "\n"):find(BANNER, 1, true) == nil,
            "the banner was already on the screen before the frame drew it")
        local pre_plan = nil
        for y = 1, (pre and pre.h or 0) do
            if pre.rows[y]:find("STARTUP_PLAN action=normal journal=none tries=0", 1, true) then
                pre_plan = y
            end
        end
        H.check("pre_frame_plan_line", pre_plan ~= nil,
            "STARTUP_PLAN not on the pre-frame screen: ["
            .. tostring(pre and pre.rows[1]) .. "] ... ["
            .. tostring(pre and pre.rows[(pre and pre.h or 1)]) .. "]")
        -- and in the call record the banner comes after the frame's clear
        local clear_at = buf.call_index("clear")
        local banner_at = nil
        for i = 1, #buf.calls do
            if buf.calls[i].name == "write"
                and tostring(buf.calls[i].a):find(BANNER, 1, true) then
                banner_at = i
                break
            end
        end
        H.check("banner_after_clear",
            clear_at ~= nil and banner_at ~= nil and banner_at > clear_at,
            "clear=" .. tostring(clear_at) .. " banner=" .. tostring(banner_at))

        -- and the console keeps echoing after the frame: the chain's own log
        -- lands on the line the frame stopped at, then on the rows below it
        row_is("final_banner", buf, 1, pad(BANNER, 51))
        row_is("final_kernel_line", buf, 2, pad("kernel ok", 51))
        H.eq("final_row3_head", buf.row(3):sub(1, 19), "normal journal none")
        H.eq("final_row3_tail", buf.row(3):sub(20, 35), "STARTUP_UI_READY")
        H.eq("final_row4_perms", buf.trim(4),
            "STARTUP_PERMS_TABLE apps=0 loaded=0 pending=0 bad=0")
        H.eq("final_row5_launcher", buf.trim(5),
            "STARTUP_LAUNCHER_MISSING name=launcher")
        local commit_row = buf.find_row("BOOT_COMMIT version=0.2.0")
        H.check("final_commit_echo", commit_row ~= nil,
            "BOOT_COMMIT not on the screen: [" .. buf.text():sub(1, 200) .. "]")
        local done_row = buf.find_row("STARTUP_COMMITTED version=0.2.0")
        H.check("final_committed_echo", done_row ~= nil,
            "STARTUP_COMMITTED not on the screen")
        H.check("banner_still_on_top", buf.find_row(BANNER) == 1,
            "banner row=" .. tostring(buf.find_row(BANNER)))
    end

    -- -----------------------------------------------------------------
    H.group("bios.frame.trial")
    -- The same frame during a trial boot: row 3 names the journal on trial, which
    -- is what tells an update-in-progress boot apart from a steady one.
    do
        local dir = system_tree(H.case_dir("bios", "trial"))
        local seq = BOOT.write_journal({
            state = "applied",
            version = "2.0.0",
            manifest_sha = H.HEX64,
            files = { { relpath = "kernel/ota.lua", old_sha = "-",
                        new_sha = H.HEX64, bytes = 8 } },
        }, { fs = F, root = dir, log = function() end })
        H.eq("trial_journal_seq", seq, 1)

        local buf = S.buffer(51, 19)
        local snap = nil
        local pre = nil
        local result = nil
        local frame = startup.default_frame({ term = buf })
        local okrun, why = S.with_term(buf, function()
            result = startup.run({
                fs = F,
                root = dir,
                log_path = dir .. "/kernel.log",
                term = buf,
                apps_root = dir .. "/apps",
                system_root = false,
                reboot = function() error("rebooted unexpectedly") end,
                frame = function(plan, status, rt)
                    pre = buf.snapshot()
                    local ok = frame(plan, status, rt)
                    snap = buf.snapshot()
                    return ok
                end,
            })
        end)
        H.check("trial_run_ok", okrun, tostring(why))
        H.check("trial_ok", result ~= nil and result.ok == true, "boot failed")
        H.eq("trial_plan", result and result.plan.action, "trial")
        H.eq("trial_plan_journal", result and result.plan.journal.state, "applied")
        H.eq("trial_plan_tries", result and result.plan.tries, 1)

        H.eq("trial_clears", snap and snap.clears, 1)
        snap_row_is("trial_row1", snap, 1, pad(BANNER, 51))
        snap_row_is("trial_row2", snap, 2, pad("kernel ok", 51))
        snap_row_is("trial_row3", snap, 3, pad("trial journal applied", 51))
        snap_rows_blank("trial_rows_4_19_blank", snap, 4)
        H.eq("trial_cursor_column", snap and snap.x, 22)

        H.check("trial_pre_frame_snapshot", pre ~= nil, "the frame was never called")
        local pre_trial = nil
        for y = 1, (pre and pre.h or 0) do
            if pre.rows[y]:find("BOOT_TRIAL tries=1", 1, true) then pre_trial = y end
        end
        H.check("trial_pre_frame_trial_line", pre_trial ~= nil,
            "BOOT_TRIAL not on the pre-frame screen: ["
            .. tostring(pre and pre.rows[1]) .. "]")
        H.check("trial_normal_line_absent", buf.text():find("normal journal none", 1, true) == nil,
            "a trial boot drew the normal third line")
        H.eq("trial_final_row3_tail", buf.row(3):sub(22, 37), "STARTUP_UI_READY")
    end

    -- -----------------------------------------------------------------
    H.group("bios.no_system")
    -- No /system tree: the bootloader is fatal, the frame never runs, so the
    -- screen keeps the boot log from row 1 and there is no banner anywhere.
    do
        local dir = H.root .. "/ns"
        H.rmrf(dir)
        H.mkdirp(dir)

        local buf = S.buffer(51, 19)
        local result = nil
        local okrun, why = S.with_term(buf, function()
            result = startup.run({
                fs = F,
                root = dir,
                log_path = dir .. "/kernel.log",
                term = buf,
                apps_root = dir .. "/apps",
                system_root = false,
                reboot = function() error("rebooted unexpectedly") end,
            })
        end)
        H.check("nosys_run_ok", okrun, tostring(why))
        H.check("nosys_fatal", result ~= nil and result.fatal == true,
            "fatal=" .. tostring(result and result.fatal))
        H.eq("nosys_error", result and result.error, "no_system")

        -- the whole screen: five log lines, row by row, in boot order
        row_is("nosys_row1_boot", buf, 1,
            pad("BOOT_NO_SYSTEM path=" .. dir .. "/system why=missing", 51))
        row_is("nosys_row2_fatal", buf, 2, pad("BOOT_FATAL reason=no_system", 51))
        row_is("nosys_row3_action", buf, 3, pad("BOOT_ACTION action=fatal", 51))
        row_is("nosys_row4_plan", buf, 4,
            pad("STARTUP_PLAN action=fatal journal=none tries=0", 51))
        row_is("nosys_row5_startup_fatal", buf, 5,
            pad("STARTUP_FATAL reason=no_system", 51))
        rows_blank("nosys_rows_6_19_blank", buf, 6)
        cell_is("nosys_cell_1_1", buf, 1, 1, "B")
        H.check("nosys_no_banner", buf.find_row("Pyroet OS ") == nil,
            "the banner was on the screen: row=" .. tostring(buf.find_row("Pyroet OS ")))
        H.eq("nosys_no_clear", buf.stats.clears, 0)
        H.eq("nosys_cursor_line", select(2, buf.getCursorPos()), 6)
    end

    -- -----------------------------------------------------------------
    H.group("bios.starter")
    -- The computer-root starter is the only thing between a broken /system and a
    -- dead console, so its three lines are asserted as screen cells.
    do
        local function drive_starter(loader)
            local buf = S.buffer(51, 19)
            local chunk = assert(loadfile(STARTER))
            local saved = _G.loadfile
            _G.loadfile = loader
            local ok, why = S.with_term(buf, function() return chunk() end)
            _G.loadfile = saved
            return buf, ok, why
        end

        -- every line the starter prints goes through its say(), so every line
        -- starts with this prefix; a line longer than the screen is wrapped by
        -- the ROM's print, not by the starter.
        local function said(text) return "Pyroet OS: " .. text end
        local LOAD_LINE = said("cannot load /system/startup.lua")
        -- measured on the emulator: print wraps this line at the space before
        -- "reflash", so the hint is two rows
        local HINT_ROW1 = said("shell only. Run recovery/flash.lua to")
        local HINT_ROW2 = "reflash /system."
        H.check("hint_rebuilds_line",
            HINT_ROW1 .. " " .. HINT_ROW2 == said(HINT),
            "[" .. HINT_ROW1 .. "]+[" .. HINT_ROW2 .. "] != [" .. said(HINT) .. "]")

        -- 1. loadfile reports a failure: "cannot load" + the reason + the hint
        local b1, ok1, why1 = drive_starter(function() return nil, "disk fault" end)
        H.check("starter_load_ok", ok1, tostring(why1))
        row_is("starter_load_row1", b1, 1, pad(LOAD_LINE, 51))
        row_is("starter_load_row2", b1, 2, pad(said("disk fault"), 51))
        row_is("starter_load_row3", b1, 3, pad(HINT_ROW1, 51))
        row_is("starter_load_row4", b1, 4, pad(HINT_ROW2, 51))
        rows_blank("starter_load_rows_5_19_blank", b1, 5)
        cell_is("starter_cell_1_1", b1, 1, 1, "P")
        cell_is("starter_cell_10_1", b1, 10, 1, ":")
        cell_is("starter_cell_1_3", b1, 1, 3, "P")

        -- 2. loadfile raises: pcall turns it into a message, same three rows
        local b2, ok2, why2 = drive_starter(function() error("loader exploded") end)
        H.check("starter_raise_ok", ok2, tostring(why2))
        row_is("starter_raise_row1", b2, 1, pad(LOAD_LINE, 51))
        H.check("starter_raise_message",
            flat(b2.text()):find("loader exploded", 1, true) ~= nil,
            "screen=[" .. b2.trim(2) .. "] / [" .. b2.trim(3) .. "]")
        H.check("starter_raise_hint",
            flat(b2.text()):find("shell only. Run recovery/flash.lua to reflash /system.", 1, true) ~= nil,
            "the hint is not on the screen: [" .. b2.trim(3) .. "]")

        -- 3. /system/startup.lua loads but raises: "startup failed"
        local b3, ok3, why3 = drive_starter(function()
            return function() error("starter probe boom") end
        end)
        H.check("starter_runfail_ok", ok3, tostring(why3))
        row_is("starter_runfail_row1", b3, 1, pad(said("startup failed"), 51))
        H.check("starter_runfail_message",
            flat(b3.text()):find("starter probe boom", 1, true) ~= nil,
            "screen=[" .. b3.trim(2) .. "] / [" .. b3.trim(3) .. "]")
        H.check("starter_runfail_hint",
            flat(b3.text()):find("shell only. Run recovery/flash.lua to reflash /system.", 1, true) ~= nil,
            "the hint is not on the screen: [" .. b3.trim(3) .. "]")

        -- 4. the happy path draws nothing: a working boot never sees these words
        local b4, ok4, why4 = drive_starter(function() return function() end end)
        H.check("starter_ok_ok", ok4, tostring(why4))
        H.eq("starter_silent_writes", b4.stats.writes, 0)
        H.eq("starter_silent_screen", b4.trim(1), "")
        H.check("starter_silent_no_hint", b4.find_row("shell only") == nil,
            "the hint was printed on a good boot")
    end

    -- -----------------------------------------------------------------
    H.group("bios.frame.small")
    -- A frame on a screen narrower than its longest line: write() clips, the
    -- frame's own row positioning still holds.  This is the documented limit of
    -- the buffer (no wrapping inside write), pinned so a later "improvement" to
    -- wrap there cannot silently change what the frame looks like.
    do
        local plan = { action = "normal", journal = nil }
        local status = { health = "ok" }
        local buf = S.buffer(10, 4)
        local okf, whyf = S.with_term(buf, function()
            local frame = startup.default_frame({ term = buf })
            return frame(plan, status)
        end)
        H.check("small_frame_ok", okf, tostring(whyf))
        row_is("small_row1_clipped", buf, 1, "Pyroet OS ")
        row_is("small_row2", buf, 2, "kernel ok ")
        row_is("small_row3_clipped", buf, 3, "normal jou")
        row_is("small_row4_blank", buf, 4, "          ")
        H.check("small_clipped_cells", buf.stats.clipped > 0,
            "clipped=" .. tostring(buf.stats.clipped))
    end
end
