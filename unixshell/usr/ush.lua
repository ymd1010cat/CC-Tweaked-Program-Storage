-- ush.lua - a Unix-like shell for CC:Tweaked

-- ------------------------------------------------------------------
-- Module search paths: /lib/?.lua and /usr/?.lua so that
-- require("perm"), require("cwd"), ... resolve on CC:Tweaked.
-- The shell is always started by its absolute path (startup.lua, rexec, a
-- CraftOS shell, or a PC side run), so it cannot count on the launcher having
-- patched package.path first: it installs the two entries itself, before the
-- first require. The loop is idempotent, an entry already present is not
-- added a second time.
--
-- The list is written inline rather than in a named local: this file is at Lua's
-- ceiling of 200 local variables in the main chunk ("too many local variables
-- (limit is 200) in main function"), so every top-level name costs a slot that a
-- feature needs more than a table used twice does.
-- ------------------------------------------------------------------
for _, entry in ipairs({ "/lib/?.lua", "/usr/?.lua" }) do
    if not package.path:find(entry, 1, true) then
        package.path = entry .. ";" .. package.path
    end
end

local perm  = require("perm")
local protect = require("protect")
local rpvnet  = require("rpvnet")
local audit = require("audit")
local cwd   = require("cwd")
local vars  = require("vars")
local glob  = require("glob")
local alias = require("alias")
local history = require("history")
local complete = require("complete")
local sysinfo = require("sysinfo")
local mounts  = require("mounts")
local jobs    = require("jobs")
local cron    = require("cron")
local params  = require("params")
local cond    = require("cond")
local theme   = require("theme")
local arith   = require("arith")

-- lib/space.lua answers "is there room for this write?" for every writer below.
-- It is required HERE, at column 0, rather than lazily inside each writer, so
-- that tools/deploy.py puts it in the base half: a machine whose system module
-- store (part 2 of a two-part install) is not inserted must still be able to
-- refuse a write. A lazy require would raise "module not found" on exactly the
-- machine that has least room, instead of failing the write.
--
-- No local is bound for it: the main chunk is at Lua's ceiling of 200 locals, so
-- each writer asks require("space") -- a lookup in package.loaded, which is what
-- require does for an already loaded module anyway.
require("space")

-- lib/danger.lua is the destructive-command blacklist (rm -rf / and the system
-- directories). Like lib/space.lua above it is required HERE, at column 0, so
-- that tools/deploy.py puts it on the computer rather than on the system module
-- medium: the blacklist is what stops root from deleting the machine's own
-- system, and a machine whose medium (part 2) is not inserted must still refuse
-- "rm -rf /". A lazy require at the point of use would raise "module not found"
-- on exactly that machine instead of refusing the command -- measured: the
-- indented require() in run_stage left lib/danger.lua on part 2, and without
-- the medium the blacklist simply was not there.
require("danger")

-- lib/sessionlog.lua is the login accounting ledger ("who", "w", "last" read
-- it). It is required HERE, at column 0, for the same reason as space and
-- danger above, and the failure it prevents was the worst kind: login was the
-- LAST step before the prompt, so the session opened the shell's ledger file and
-- died there. The interactive block used to ask for it with an INDENTED require
-- inside the function that starts the session, which tools/deploy.py reads as a
-- lazy require (it runs when called, not when loaded) and therefore put
-- lib/sessionlog.lua on the system module medium. Measured on a machine deployed
-- with --part base and no medium inserted:
--
--   ush 1.0 - type 'help' for commands
--   /usr/ush.lua:8574: module 'sessionlog' not found
--
-- repeated once per turn of the session loop, so the machine never reached a
-- prompt at all. The release shipped with this defect; it is not a regression of
-- the two-part split, only one that the split made fatal. A column-0 require
-- puts the module on the computer, where the session that needs it lives, and it
-- costs 8,450 B of a 1 MB disk. The use at the point of need below still says
-- require("sessionlog"): that is a lookup in package.loaded now, not a file
-- search, so the single column-0 require both fixes the boot and leaves the
-- code reading locally.
require("sessionlog")

-- lib/lang.lua is the message catalogue and the one place the interface language
-- is chosen. It is required HERE, at column 0, for the reason the block above
-- explains: the "lang" built-in and the console writer both live in the session,
-- so a machine whose system module medium (part 2) is not inserted must still be
-- able to run the shell in English and to say why Chinese is unavailable. A lazy
-- require would turn "lang" into "module not found" on exactly that machine.
require("lang")

local BUILTINS = {}

-- Shell functions defined in this session ("name() { ... }"): name -> body.
local FUNCTIONS = {}

-- Set by the "exit" built-in. The error raised by exit unwinds to the nearest
-- script frame (or to run(), for a session line) and the code is picked up
-- from here, so "exit 3" inside a nested loop still ends the whole script.
local EXIT_REQUEST = nil

-- Forward declaration: call_function() is defined with the control flow layer,
-- but run_stage() (defined earlier) has to dispatch shell functions.
local call_function

-- Forward declarations: the trap engine is defined with the command flow layer,
-- because the text of a trap goes back through the parser and needs tokenize()
-- and run_control(). The command runner, the sub shell helpers and the session
-- are defined before that point and still have to reach it: a command that is
-- stopped, a command that fails and a shell that is about to leave all have a
-- trap waiting for them.
local trap_fire, trap_run_exit, is_interrupt_error
local trap_frame_enter, trap_frame_leave

-- ------------------------------------------------------------
-- Mount aware path resolution
-- ------------------------------------------------------------

-- lib/cwd.lua stays the single source of truth for absolute paths (it is not
-- modified); the mount table is applied on top of it, so walking into
-- /mnt/floppy transparently reaches the real directory /disk. Without any
-- mount entry this is exactly cwd.resolve().
local function resolve_path(p)
    return mounts.map(cwd.resolve(p))
end

-- Reverse mapping, used by pwd so a user standing inside /disk/a sees the
-- logical mount point again.
local function display_path(p)
    return mounts.unmap(p)
end

-- Shell wide state: the last exit status (used by $? and by the && / || lists)
-- and the options of "set". Every option starts out off, so a shell that has
-- read no "set -e" behaves the way it always did.
local SHELL = {
    status = 0,
    errexit = false,   -- "set -e": stop on the first command that fails
    nounset = false,   -- "set -u": an undefined variable is a fault
    pipefail = false,  -- "set -o pipefail": a pipeline fails with the first
                       -- stage that fails, not with its last one
    xtrace = false,    -- "set -x": print every command before it runs
    bootguard = true,  -- "set -o bootguard": refuse to overwrite a boot file.
                       -- ON by default; the value here is what "set -o" reports
                       -- before /etc/boot.conf is read, and protect.enabled()
                       -- is the authority (it reads the file).
    noexit = true,     -- "set -o noexit": the shell may not be left. Same shape:
                       -- the authority is protect.no_exit(), which reads the file.
    -- True only while the INTERACTIVE session is running. It lives in SHELL
    -- rather than beside it because ush.lua is at Lua 5.1's ceiling of 200 local
    -- variables in the main chunk ("main function has more than 200 local
    -- variables"): every top-level local is a slot, and a field of the state
    -- table costs none. "ush cannot be exited" is a rule about the session, not
    -- about the shell binary: "ush -c 'exit 3'" is a one-shot command line whose
    -- whole purpose is to return a status, and a script ending in "exit N" is how
    -- it returns its own. Neither is a session, so neither is refused.
    interactive = false,
}

-- ============================================================
-- I/O helpers
-- ============================================================

-- The shell idle hook. CraftOS is single threaded, so background jobs and
-- scheduled tasks can only be serviced when the shell is not running a
-- command: the line editor keeps a timer armed, which gives us that chance
-- between keystrokes.
local idle_hook = nil
local IDLE_INTERVAL = 1.0

local function set_idle_hook(fn)
    idle_hook = fn
end

local function run_idle_hook()
    if not idle_hook then return end
    local ok, err = pcall(idle_hook)
    if not ok then
        print("ush: idle hook: " .. tostring(err))
    end
end

-- Peripheral events reach the prompt through the editor loop below. The mount
-- action itself lives in lib/disk.lua, so the mount table, mount(8) and umount(8)
-- all see the same entries.
local function disk_event_lines(name, side)
    local ok, disk = pcall(require, "disk")
    if not ok or not disk then return {} end
    local ran, report = pcall(disk.on_event, name, side)
    if not ran or type(report) ~= "table" then return {} end
    return report
end

-- Bridge for library commands that write whole lines to a stage object
-- (disk/main, service/main, logrotate/main), so their output runs through the
-- normal pipeline when the shell hands us one.
local function module_stage(stage)
    local out = stage and stage._out or nil
    return {
        _out = out,
        write = function(text)
            if out then out.write(text) else write(text) end
        end,
    }
end

-- The console rules, in one table. The main chunk of this file sits close to
-- the limit of local names a Lua chunk may declare, so the rules share a
-- single name instead of taking a name each. The table is declared before its
-- members are filled in: a closure written inside the constructor of a local
-- would still see the global of that name, not the local one.
local console = {}

-- The line breaks of the editor. A "\n" handed to term.write() never reaches
-- the console as a break; write() is the routine that knows the line breaks of
-- the console, so the breaks the interactive shell makes (the Enter key, the
-- Tab candidate list, the report of a disk event) go through it. break_line()
-- ends the line from its first column, so where the editing left the cursor
-- does not matter, and line() prints a whole line.
console.break_line = function()
    term.setCursorPos(1, select(2, term.getCursorPos()))
    write("\n")
end

console.line = function(text)
    write(tostring(text) .. "\n")
end

-- A key press can reach the console twice: as the key event of the key, and,
-- when the key stands for a printable character, as the char event of that
-- character. The char event of a key that stands for no character carries a
-- NUL byte; nothing else at the console produces a control character. Such a
-- byte would sit in the edited line -- invisible, but counted by the cursor --
-- so a line holding nothing but blanks would stop looking like an empty line
-- to the shell, and a password read from the console would carry a byte nobody
-- typed. Control bytes are dropped at the reader, the way a terminal drops
-- them.
console.char = function(c)
    if type(c) ~= "string" or c == "" then return false end
    local b = c:byte(1)
    return b ~= nil and b >= 32 and b ~= 127
end

-- The console belongs to the machine administrator, the level 1 account of
-- /etc/passwd; root is a session identity that su hands out, and it is meant to
-- last as long as that session, not as long as the machine. A console left as
-- root -- a su whose shell was never exited, or a machine that lost power on
-- one -- is put back on its own account whenever the shell starts, so a reboot
-- never hands the superuser to whoever turns the computer on. root is still
-- reached the normal way, with su and sudo.
console.owner = function()
    local ok, list = pcall(perm.list_users)
    if not ok or type(list) ~= "table" then return nil end
    for _, name in ipairs(list) do
        if name ~= "root" and perm.user_level(name) == 1 then
            return name
        end
    end
    return nil
end

console.claim = function()
    if perm.get_current_user() ~= "root" then return false end
    local owner = console.owner()
    if not owner then return false end
    perm.set_current_user(owner)
    return true
end

console.claim()

-- Interactive line reader: cursor movement, command history (up/down) and Tab
-- completion. The prompt is written here so that the cursor can always be
-- positioned correctly while redrawing the edited line.
local complete_ctx = { builtins = {}, aliases = {}, users = {} }

local function refresh_complete_ctx()
    complete_ctx.builtins = {}
    for name in pairs(BUILTINS) do
        complete_ctx.builtins[#complete_ctx.builtins + 1] = name
    end
    table.sort(complete_ctx.builtins)
    complete_ctx.aliases = alias.names()
    -- "sudo -u" completes against the accounts. lib/complete.lua stays away
    -- from /etc/passwd, so the shell hands the list over; an account file that
    -- cannot be read leaves the list empty instead of breaking the Tab key.
    local ok_users, list = pcall(perm.list_users)
    if ok_users and type(list) == "table" then
        complete_ctx.users = list
    else
        complete_ctx.users = {}
    end
end

-- ---------------------------------------------------------------- prompt
-- lib/theme.lua owns the templates, lib/vars.lua the variables; the glue below
-- turns one of them into the prompt the line editor draws. PS1 wins over the
-- theme while it is set to a non empty value, and a template that cannot be
-- rendered falls back to a plain prompt, so no configuration can keep the
-- prompt away (see "man theme", "man PS1" and "man theme.conf").

-- The account of the session. The prompt reads $USER from lib/vars.lua, but
-- "su" and "sudo" move /etc/current_user on their own: the name a prompt
-- shows belongs to the account that really owns the console, so it is read
-- back from lib/perm.lua every time a prompt is about to be drawn. HOME
-- follows the account the first time that account is seen, so a home
-- directory the user set by hand survives the next prompt.
local session_account = nil

local function session_user()
    local user = perm.get_current_user()
    vars.set("USER", user)
    vars.export("USER")
    if user ~= session_account then
        session_account = user
        vars.set("HOME", "/home/" .. user)
        vars.export("HOME")
    end
    return user
end

-- The prompt of the superuser ends with "#" where an account shows "$". The
-- themes and "man PS1" carry the dollar as a literal ("\$ "), so
-- lib/theme.lua hands the sign back as it is written and it is settled here,
-- on the finished prompt: the last "$" of a line becomes "#" while the shell
-- runs as root. The two signs are one column wide, so the width of the
-- prompt, and with it the cursor arithmetic of the line editor, does not
-- change.
local function root_sign(text)
    local head, blanks = text:match("^(.-)(%s*)$")
    if head == nil or head:sub(-1) ~= "$" then return text, false end
    return head:sub(1, #head - 1) .. "#" .. blanks, true
end

-- Put the sign of the account on a rendered prompt, a plain string as well as
-- one { parts, width, plain } table of lib/theme.lua.
local function prompt_sign(rendered)
    if type(rendered) == "string" then
        local marked = root_sign(rendered)
        return marked
    end
    if type(rendered) ~= "table" then return rendered end
    if type(rendered.plain) == "string" then
        local marked, changed = root_sign(rendered.plain)
        if changed then rendered.plain = marked end
    end
    local parts = rendered.parts
    if type(parts) == "table" then
        -- The dollar is the last thing the prompt draws: the last segment
        -- that carries one is the one to change.
        for i = #parts, 1, -1 do
            local part = parts[i]
            if type(part) == "table" and type(part.text) == "string" then
                local marked, changed = root_sign(part.text)
                if changed then
                    part.text = marked
                    break
                end
            end
        end
    end
    return rendered
end

-- The rendered prompt of one line: { parts, width, plain } of lib/theme.lua.
local function prompt_render()
    local user = session_user()
    local ps1 = vars.get("PS1")
    if type(ps1) ~= "string" or ps1 == "" then ps1 = nil end
    local ok, rendered = pcall(theme.render, ps1, vars.get)
    if not ok or type(rendered) ~= "table" then
        rendered = theme.expand("$USER@$HOST:$PWD\\$ ", vars.get)
    end
    if user == "root" then rendered = prompt_sign(rendered) end
    return rendered
end

-- Write one rendered prompt: the colours go to the terminal, the plain text is
-- what the editor counts for the cursor, so both agree on the screen.
local function prompt_write(rendered)
    local colour = nil
    for _, part in ipairs(rendered.parts or {}) do
        if part.colour ~= nil and part.colour ~= colour then
            term.setTextColour(part.colour)
            colour = part.colour
        end
        write(part.text)
    end
    if colour ~= nil then term.setTextColour(theme.colour()) end
    return rendered.plain or ""
end

-- True when a key code is one of the Ctrl keys. CraftOS reports a modifier as
-- a key event of its own (Ctrl+A arrives as the key event of "a" while the
-- Ctrl key is held), so holding Ctrl has to be tracked here by hand.
local function is_ctrl_key(code)
    if code == nil then return false end
    if keys.leftCtrl ~= nil and code == keys.leftCtrl then return true end
    if keys.rightCtrl ~= nil and code == keys.rightCtrl then return true end
    return false
end

-- safe_read(prompt): prompt is either a plain string or one rendered prompt of
-- prompt_render(), in which case the segments are drawn with their colours.
--
-- Keys: Enter accepts the line, Backspace/Delete rub out, Left/Right/Home/End
-- move the cursor, Up/Down walk the history, Tab completes. The control keys
-- are Ctrl+A (start of line), Ctrl+E (end of line), Ctrl+W (rub out the word
-- in front of the cursor), Ctrl+C (drop the line and start a new one, keeping
-- the session) and Ctrl+L (clear the screen and draw the line again). Ctrl+T
-- stays the system terminate key and is ignored here: it is what stops a
-- foreground command, never the shell.
local function safe_read(prompt)
    local rendered = nil
    if type(prompt) == "table" then
        rendered = prompt
        prompt = rendered.plain or ""
    end
    prompt = prompt or ""

    local buf = {}
    local cursor = 1               -- insertion index, 1 .. #buf + 1
    local row = select(2, term.getCursorPos())

    local hist_index = nil         -- nil while editing a fresh line
    local saved_line = ""

    -- Set while a Ctrl key is down, so that the key event of a letter can be
    -- told apart from a plain character ("Ctrl+letter").
    local ctrl_down = false

    local function write_the_prompt()
        if rendered then prompt_write(rendered) else write(prompt) end
    end

    local function draw()
        term.setCursorPos(1, row)
        term.clearLine()
        write_the_prompt()
        write(table.concat(buf))
        term.setCursorPos(#prompt + cursor, row)
    end

    local function set_text(text)
        buf = {}
        for i = 1, #text do buf[i] = text:sub(i, i) end
        cursor = #buf + 1
    end

    -- THE CURSOR HAS TO BE ASKED FOR.
    --
    -- The terminal starts with the cursor blink OFF; CraftOS's own line reader
    -- turns it on while it reads, and this editor replaces that reader. Without
    -- this call the prompt has no cursor at all, so Left/Right/Home/End move an
    -- insertion point nobody can see -- reported from the demo machine as "no
    -- position highlight on the command line". It is hidden again when the line is
    -- accepted, the way the ROM's shell hides it while a command runs.
    if term.setCursorBlink then term.setCursorBlink(true) end
    write_the_prompt()

    -- The idle timer is what gives background jobs and scheduled tasks a slice
    -- while the user is thinking or typing.
    local idle_timer = os.startTimer(IDLE_INTERVAL)

    while true do
        local ev = { os.pullEventRaw() }
        local e = ev[1]
        if e == "timer" and ev[2] == idle_timer then
            idle_timer = os.startTimer(IDLE_INTERVAL)
            run_idle_hook()
        elseif e == "disk" or e == "disk_eject" then
            -- A medium appeared or disappeared: mount or unmount it, print the
            -- report above the prompt and redraw the edited line.
            local lines = disk_event_lines(e, ev[2])
            if #lines > 0 then
                console.break_line()
                for _, line in ipairs(lines) do
                    console.line(line)
                end
                row = select(2, term.getCursorPos())
                draw()
            end
        elseif e == "terminate" then
            -- ignore Ctrl+T
        elseif e == "key_up" then
            -- The Ctrl key came back up: plain letters are characters again.
            if is_ctrl_key(ev[2]) then ctrl_down = false end
        elseif e == "shutdown" then
            return nil
        elseif e == "char" then
            if console.char(ev[2]) then
                table.insert(buf, cursor, ev[2])
                cursor = cursor + 1
                draw()
            end
        elseif e == "paste" then
            local text = tostring(ev[2]):gsub("[\r\n]+", " ")
            for i = 1, #text do
                local ch = text:sub(i, i)
                if console.char(ch) then
                    table.insert(buf, cursor, ch)
                    cursor = cursor + 1
                end
            end
            draw()
        elseif e == "key" then
            local k = ev[2]
            if is_ctrl_key(k) then
                ctrl_down = true
            elseif ctrl_down and k == keys.c then
                -- Ctrl+C: throw the half typed line away and start a new one.
                -- The session carries on, so a changed mind at the prompt can
                -- never end the shell.
                write("^C")
                console.break_line()
                buf = {}
                cursor = 1
                hist_index = nil
                saved_line = ""
                row = select(2, term.getCursorPos())
                draw()
            elseif ctrl_down and k == keys.l then
                -- Ctrl+L: clear the screen and draw prompt and line again at
                -- the top, so a screen full of output is out of the way.
                term.clear()
                row = 1
                term.setCursorPos(1, row)
                draw()
            elseif ctrl_down and k == keys.a then
                cursor = 1
                draw()
            elseif ctrl_down and k == keys.e then
                cursor = #buf + 1
                draw()
            elseif ctrl_down and k == keys.w then
                -- Ctrl+W: rub out the word in front of the cursor, together
                -- with the blanks that lead up to it. "Word" is a run of non
                -- blanks and blanks are single spaces, which is what Ctrl+W
                -- has to do in a line editor.
                local removed = 0
                while cursor > 1 and buf[cursor - 1] == " " do
                    table.remove(buf, cursor - 1)
                    cursor = cursor - 1
                    removed = removed + 1
                end
                while cursor > 1 and buf[cursor - 1] ~= " " do
                    table.remove(buf, cursor - 1)
                    cursor = cursor - 1
                    removed = removed + 1
                end
                if removed > 0 then draw() end
            elseif k == keys.enter then
                -- Accept the line. The break is written from the first column
                -- of the row the cursor sits on, so where the editing left the
                -- cursor never matters: an empty line ends the line as well and
                -- the next prompt starts at the left margin of the row below.
                console.break_line()
                if term.setCursorBlink then term.setCursorBlink(false) end
                return table.concat(buf)
            elseif k == keys.backspace then
                if cursor > 1 then
                    table.remove(buf, cursor - 1)
                    cursor = cursor - 1
                    draw()
                end
            elseif k == keys.delete then
                if cursor <= #buf then
                    table.remove(buf, cursor)
                    draw()
                end
            elseif k == keys.left then
                if cursor > 1 then
                    cursor = cursor - 1
                    draw()
                end
            elseif k == keys.right then
                if cursor <= #buf then
                    cursor = cursor + 1
                    draw()
                end
            elseif k == keys.home then
                cursor = 1
                draw()
            elseif k == keys["end"] then
                cursor = #buf + 1
                draw()
            elseif k == keys.up then
                local total = history.count()
                if total > 0 then
                    if hist_index == nil then
                        saved_line = table.concat(buf)
                        hist_index = total + 1
                    end
                    if hist_index > 1 then
                        hist_index = hist_index - 1
                        set_text(history.get(hist_index) or "")
                        draw()
                    end
                end
            elseif k == keys.down then
                if hist_index ~= nil then
                    local total = history.count()
                    if hist_index < total then
                        hist_index = hist_index + 1
                        set_text(history.get(hist_index) or "")
                    else
                        hist_index = nil
                        set_text(saved_line)
                    end
                    draw()
                end
            elseif k == keys.tab then
                refresh_complete_ctx()
                local new_line, new_cursor, cands =
                    complete.complete(table.concat(buf), cursor, complete_ctx)
                if #cands == 1 then
                    set_text(new_line)
                    cursor = math.min(new_cursor, #buf + 1)
                    draw()
                elseif #cands > 1 then
                    if new_line ~= table.concat(buf) then
                        set_text(new_line)
                        cursor = math.min(new_cursor, #buf + 1)
                    end
                    console.break_line()
                    console.line(table.concat(cands, "  "))
                    row = select(2, term.getCursorPos())
                    draw()
                end
            end
        end
    end
end

local function safe_read_password()
    -- The same visible cursor the line editor asks for: a password prompt with no
    -- cursor gives no clue that the keys are being taken at all.
    if term.setCursorBlink then term.setCursorBlink(true) end
    local buf = {}
    while true do
        local ev = { os.pullEventRaw() }
        local e = ev[1]
        if e == "terminate" then
            -- ignore
        elseif e == "key" then
            local k = ev[2]
            if k == keys.enter then
                console.break_line()
                if term.setCursorBlink then term.setCursorBlink(false) end
                return table.concat(buf)
            elseif k == keys.backspace then
                if #buf > 0 then table.remove(buf) end
            end
        elseif e == "char" then
            if console.char(ev[2]) then table.insert(buf, ev[2]) end
        elseif e == "shutdown" then
            return nil
        end
    end
end

local function emit(stage, text)
    if stage and stage._out then
        -- A redirection or a command substitution wants BYTES: a file written in
        -- Chinese mode must contain UTF-8, and a capture must be usable as data.
        -- Only the console needs glyphs, so only the console branch below asks
        -- the renderer (see lib/lang.lua: "a write to a file is bytes").
        stage._out.write(text)
        stage._out.write("\n")
    else
        local s = tostring(text)
        -- Plain ASCII goes to print() untouched. That is not an optimisation: it
        -- keeps the English interface byte-for-byte what it always was, and it
        -- keeps print()'s "write at the cursor, then newline" behaviour, which a
        -- partial line (a progress bar, "echo -n") depends on. Only text that
        -- actually carries multibyte characters needs the bitmap renderer.
        if s:find("[\128-\255]") then
            require("lang").say(s)
        else
            print(s)
        end
    end
end

-- Print a shell level message that is not attached to a running stage.
local function write_stdout(text)
    print(text)
end

-- Capture stack of a command substitution. While a capture is open the
-- standard output of every stage goes into its buffer instead of the console;
-- the shell's own messages keep going to the console, they are diagnostics on
-- the standard error and not part of what a command writes.
local capture_stack = {}

local function capture_push()
    local buf = { chunks = {} }
    -- The same shape a stage output has: emit() calls write() on it. A
    -- capture has no file to close, its close() is the empty one.
    buf.write = function(text) buf.chunks[#buf.chunks + 1] = tostring(text) end
    buf.close = function() end
    capture_stack[#capture_stack + 1] = buf
    return buf
end

local function capture_pop()
    if #capture_stack > 0 then return table.remove(capture_stack) end
    return nil
end

local function capture_top()
    return capture_stack[#capture_stack]
end

-- Report a diagnostic ("ush: cmd: command not found"). A command substitution
-- captures the standard output of its command only, so while a capture is open
-- the message goes to the console stream instead of the buffer.
local function emit_diag(stage, text)
    -- A redirection of the diagnostic stream wins over everything: that is what
    -- "2> f" asked for. _err_console is the case where that stream is explicitly
    -- the console even though the stage's stdout is a file ("2>&1 > f").
    if stage and stage._err then
        stage._err.write(text)
        stage._err.write("\n")
    elseif stage and stage._err_console then
        print(text)
    elseif capture_top() then
        print(text)
    else
        emit(stage, text)
    end
end

-- ------------------------------------------------------------
-- The options of the shell: "set -e -u -x", "set -o pipefail"
-- ------------------------------------------------------------

-- The options of "set", all in one table: the list that "set -o" walks in the
-- order it lists them (the long name and the one letter form that "-e", "-u"
-- and "-x" use; pipefail has no letter of its own, a shell reports it only by
-- name), the two indexes that let "set -e" and "set -o errexit" name the same
-- thing, and the count of the commands that are not affected by "set -e".
--
-- POSIX keeps "set -e" out of a command whose status is only tested: the left
-- side of "&&" and "||", the condition of "if", "while" and "until", and a
-- command that "!" negates. A caller raises "muted" while one of them runs.
local SET_OPTIONS = {
    list = {
        { name = "errexit",  letter = "e" },
        { name = "nounset",  letter = "u" },
        { name = "pipefail", letter = nil },
        { name = "xtrace",   letter = "x" },
        -- Not a POSIX option: it is a rule about this machine, and it persists
        -- in /etc/boot.conf the way the package store rules persist in
        -- /etc/pkgstore.conf. Changing it goes through SET_OPTIONS.set() below,
        -- which writes the file as well as the in-memory flag.
        { name = "bootguard", letter = nil, persistent = true, rule = "boot_guard" },
        -- "set +o noexit" is how a root user lets the shell be left again. On by
        -- default: on a console that has to stay up, an accidental "exit" is the
        -- one command that ends everything.
        { name = "noexit", letter = nil, persistent = true, rule = "no_exit" },
    },
    by_name = {},
    by_letter = {},
    muted = 0,
}
for _, opt in ipairs(SET_OPTIONS.list) do
    SET_OPTIONS.by_name[opt.name] = opt
    if opt.letter then SET_OPTIONS.by_letter[opt.letter] = opt end
end

-- Turn an option on or off. A plain option only changes the in-memory flag; a
-- persistent one (bootguard) also writes its rule to /etc/boot.conf, because a
-- guard that came back on at the next boot without the operator asking would be
-- worse than no guard: the write they made would silently start failing.
--
-- The privileged option is root-only. Turning the boot guard OFF is exactly the
-- kind of change that has to be attributable, and the in-memory flag alone would
-- let an unprivileged session disable it for the commands it runs.
function SET_OPTIONS.set(opt, want, stage)
    if opt.persistent then
        local actor = perm.get_current_user()
        if actor ~= "root" then
            emit(stage or { _out = nil }, "set: " .. opt.name ..
                 ": only root may change this option")
            return false, 1
        end
        local okp, why
        if opt.rule == "no_exit" then
            okp, why = protect.set_no_exit(want)
        else
            okp, why = protect.set_enabled(want)
        end
        if not okp then
            emit(stage or { _out = nil }, "set: " .. opt.name .. ": " .. tostring(why))
            return false, 1
        end
        SHELL[opt.name] = want
        return true, 0
    end
    SHELL[opt.name] = want
    return true, 0
end

-- "$-": the letters of the options that are in force. POSIX has no letter for
-- pipefail, so it never shows up here.
function SET_OPTIONS.letters()
    local out = {}
    for _, opt in ipairs(SET_OPTIONS.list) do
        if opt.letter and SHELL[opt.name] then
            out[#out + 1] = opt.letter
        end
    end
    return table.concat(out)
end

-- One line of the listing "set -o" writes with no name: the name padded and its
-- state. The column is nine characters, as it has always been, and a name at least
-- that long gets ONE space after it instead of none -- "bootguard" is exactly nine,
-- and a plain 9 - #name ran the name into its value ("bootguardon"). Widening the
-- column for every name instead would move the four POSIX options, which is a
-- change no reader asked for.
function SET_OPTIONS.line(opt)
    local width = 9
    if #opt.name + 1 > width then width = #opt.name + 1 end
    return opt.name .. string.rep(" ", width - #opt.name) ..
           (SHELL[opt.name] and "on" or "off")
end

-- One line of the listing that "set +o" writes with no name: the command that
-- puts the option back the way it is now, ready to be run again.
function SET_OPTIONS.command(opt)
    return "set " .. (SHELL[opt.name] and "-o " or "+o ") .. opt.name
end

-- Run "fn" with "set -e" held back. A command whose status is only tested
-- never ends the shell, and neither do the commands it calls in turn (POSIX):
-- the left side of "&&" and "||", the condition of "if", "while" and "until"
-- and a command that "!" negates all run through here. The control tables that
-- "exit", "return", "break" and "continue" raise pass through unchanged.
function SET_OPTIONS.hold(fn, ...)
    SET_OPTIONS.muted = SET_OPTIONS.muted + 1
    local ok, first, second = pcall(fn, ...)
    SET_OPTIONS.muted = SET_OPTIONS.muted - 1
    if not ok then error(first, 0) end
    return first, second
end

-- "set -e": a command that fails ends the shell at once. The error carries the
-- marker of "exit", so it unwinds to the nearest script frame or to the line
-- runner exactly like an exit does, and the status the shell is left with is
-- the status of the command that failed.
function SET_OPTIONS.check(status)
    if SET_OPTIONS.muted > 0 or not SHELL.errexit then return end
    if type(status) ~= "number" or status == 0 then return end
    SHELL.status = status
    vars.set_status(status)
    error({ __ush_exit = status }, 0)
end

-- "set -x": the command, after the expansions, is written out before it runs.
-- The assignments that stood in front of it and its redirections are shown
-- with it, and the pipes separate the stages of a pipeline. The text goes to
-- the console: it is a report of the shell and not a part of what a command
-- writes, so a command substitution does not capture it.
function SET_OPTIONS.trace(stages, assigns)
    if not SHELL.xtrace then return end
    local parts = {}
    for _, a in ipairs(assigns or {}) do
        parts[#parts + 1] = tostring(a)
    end
    for _, st in ipairs(stages) do
        local words = {}
        for _, f in ipairs(st.fields or {}) do
            words[#words + 1] = f.name .. "=" .. tostring(f.value)
        end
        for _, w in ipairs(st.words) do words[#words + 1] = w end
        local text = table.concat(words, " ")
        if st.redirect then
            text = text .. (st.append and " >> " or " > ") .. st.redirect
        elseif st.input then
            text = text .. " < " .. st.input
        elseif st.here then
            text = text .. " << " .. tostring(st.here.word or "EOF")
        end
        parts[#parts + 1] = text
    end
    if #parts == 0 then return end
    write_stdout("+ " .. table.concat(parts, " | "))
end

-- Write guard for read-only mounts. Every filesystem modifying built-in calls
-- this before touching the disk, the way a kernel would return EROFS.
--
-- "path" must be the logical path (the user's argument after cwd resolution
-- but before the mount map): the read-only flag belongs to the mount point the
-- command writes through, and the same source may be mounted twice with
-- different flags at different mount points.
local function guard_write(path, stage)
    if mounts.is_readonly(path) then
        local msg = "ush: " .. path .. ": read-only file system"
        if stage then emit(stage, msg) else print(msg) end
        return false
    end
    -- The boot guard: a write that would land on /startup.lua, /usr/ush.lua,
    -- /firstboot.lua or anything under /lib/ is refused unless the operator has
    -- turned the guard off (set +o bootguard). This runs HERE, on the one path
    -- every writer goes through, so no individual command can forget it.
    local okp, why = protect.check(path)
    if not okp then
        if stage then emit(stage, why) else print(why) end
        return false
    end
    return true
end

-- Open the standard output of a stage. Returns the handle, or nil when the
-- redirection was REFUSED (a read-only mount point, or a boot file with the boot
-- guard on). In that case stage._denied is set, and run_stage turns it into a
-- failing status: the message has already been printed, but a command whose
-- output went nowhere must not report success, or a script would carry on as if
-- the write had happened.
local function open_output(stage)
    if stage.redirect then
        -- The guard runs on the logical target so that a read-only mount point
        -- is honoured even when its source is mounted elsewhere as well.
        if not guard_write(cwd.resolve(stage.redirect), nil) then
            -- The EROFS style message has already been printed; returning nil
            -- makes the command fall back to the console instead of silently
            -- dropping its output.
            stage._denied = true
            return nil
        end
        -- The permission database is asked as well. guard_write only knows about
        -- mounts and boot files; a redirect straight into /etc or /usr would
        -- otherwise be the one writer that skipped perm.can_write.
        local target = resolve_path(stage.redirect)
        if not perm.can_write(target) then
            emit(stage, "ush: " .. tostring(stage.redirect) ..
                 ": permission denied")
            stage._denied = true
            return nil
        end
        local path = target
        -- Is there any room at all? The size of a redirect is not known when it
        -- is opened -- the command has not produced a byte yet -- so the only
        -- honest preflight here is "the filesystem is not already full". It is
        -- worth having: on a full disk fs.open "w" succeeds and truncates the
        -- file, and the command then writes nothing, so the old contents are gone
        -- and the output went nowhere. Refusing before the open keeps them.
        local room, why = require("space").need(path, 1)
        if not room then
            emit(stage, "ush: " .. tostring(stage.redirect) .. ": " .. why)
            stage._denied = true
            return nil
        end
        local mode = stage.append and "a" or "w"
        return fs.open(path, mode)
    end
    return nil
end

-- The diagnostic stream: "2>", "2>>" and "2>&1".
--
-- THE SHELL HAD NO SECOND STREAM. emit_diag wrote exactly where emit writes, so
-- "2>" was not rejected and not honoured -- it was read as the ARGUMENT "2"
-- followed by a plain stdout redirect. Measured before this existed:
-- `echo hi 2> f` put the text "hi 2" into f and exited 0, `echo hi 2> /dev/null`
-- exited 0 having discarded "hi 2" instead of the diagnostics, and
-- `echo hi > f 2>&1` exited 127 with "command not found". Silent wrong output is
-- worse than an error, which is why the operator is now real.
--
-- Called AFTER open_output, because "2>&1" means "whatever stdout is now".
local function open_stderr(stage)
    if stage.err_to_out then
        -- "2>&1 > f": the duplication happened BEFORE stdout was sent to the
        -- file, so the diagnostic stream follows the stdout of that moment. Every
        -- other arrangement (including a plain "2>&1", where there is no file to
        -- open anyway) wants whatever stdout ended up being.
        --
        -- KNOWN LIMITATION, stated rather than hidden: "> a 2>&1 > b" should keep
        -- diagnostics on a. This model gives b, because only the two-redirection
        -- orders are tracked. Three redirections on one stream are rare enough to
        -- name rather than to model.
        if stage.err_to_prior and stage.redirect then
            -- The stdout of that moment: a command substitution's buffer if one
            -- is open, otherwise the console. Returning nil would be read by
            -- emit_diag as "no redirection at all" and fall through to emit(),
            -- which writes to the very file this case exists to avoid -- so the
            -- console is marked explicitly instead.
            local top = capture_top()
            if top then return top end
            stage._err_console = true
            return nil
        end
        return stage._out
    end
    if not stage.err then return nil end
    if not guard_write(cwd.resolve(stage.err), nil) then
        stage._denied = true
        return nil
    end
    local path = resolve_path(stage.err)
    -- Same preflight as stdout: the size of the diagnostics is not known when
    -- the stream is opened, so a full filesystem refuses rather than truncating
    -- the file the operator redirected into.
    local room, why = require("space").need(path, 1)
    if not room then
        emit(stage, "ush: " .. tostring(stage.err) .. ": " .. why)
        stage._denied = true
        return nil
    end
    return fs.open(path, stage.err_append and "a" or "w")
end

local function read_all(stage)
    if not stage._in then return nil end
    return stage._in.readAll()
end

local function read_lines(stage)
    if not stage._in then return {} end
    local lines = {}
    for line in stage._in.readLine do table.insert(lines, line) end
    return lines
end

local run_stage    -- forward declaration
local run_pipeline -- forward declaration
local run_script_text -- forward declaration (control flow layer below)
local read_script_text -- forward declaration (control flow layer below)

-- ============================================================
-- Tokenizer, expansion and command lists
-- ============================================================

-- Tokenize a command line into a flat token stream.
-- Token kinds: word, blank, assign, comment, op.
local function make_word(text, segs, quoted, plain)
    return { type = "word", text = text, segs = segs, quoted = quoted, plain = plain or text }
end

local function is_blank_char(c)
    return c == " " or c == "\t"
end

-- A newline ends a word as well: a script is tokenized as one piece of text,
-- so without it the tail of a line would be glued onto the first word of the
-- next line and "echo a<newline>echo b" would become a single command.
-- "{" and "}" are deliberately absent: they only act as operators when they
-- stand alone as a word ("{ cmd; }"), so a word such as "-I{}" (xargs) or
-- "a{}b" keeps its braces instead of being split into several tokens.
local function is_special_char(c)
    return is_blank_char(c) or c == "\n" or c == "|" or c == "&" or c == ";" or
           c == "(" or c == ")" or
           c == "<" or c == ">" or c == "=" or c == "#"
end

local function is_name_char(c)
    return c:match("[%w_]") ~= nil
end

-- The operators of "${VAR<op>word}". The two character forms are tried first
-- so that "%%" is never read as "%" followed by a pattern.
local PEXP_OPS = { ":-", ":=", ":+", ":?", "%%", "##", "-", "=", "+", "?",
                   "%", "#" }

-- Index of the "}" that closes the "${" at i. Nested braces are counted, so
-- the word of "${A:-${B}}" ends where the user means it to end.
local function closing_brace(line, i)
    local depth = 0
    local j = i
    while j <= #line do
        local c = line:sub(j, j)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return j end
        end
        j = j + 1
    end
    return nil
end

-- Read the parameter name inside "${...}": one of the specials "? $ ! # @ * -",
-- a run of digits ("${10}") or a shell name. Returns the name and the index
-- that follows it, or nil when there is no name at all ("${}").
local function read_param_name(line, i, stop)
    local c = line:sub(i, i)
    if c == "" then return nil, i end
    if c == "?" or c == "$" or c == "!" or c == "#" or c == "@" or c == "*" or
       c == "-" then
        return c, i + 1
    end
    if c:match("%d") then
        local j = i
        while j <= stop and line:sub(j, j):match("%d") do j = j + 1 end
        return line:sub(i, j - 1), j
    end
    local j = i
    while j <= stop and is_name_char(line:sub(j, j)) do j = j + 1 end
    if j == i then return nil, i end
    return line:sub(i, j - 1), j
end

-- A "${...}" word or pattern is a segment list of its own, so "$" references
-- work inside it ("${A:-$B}" and "${A:-${B}}"). Quotes are not special in this
-- position, which is what POSIX says for the operands of "-", "=", "+", "?"
-- and for the patterns of "#" and "%".
local read_segments

-- Read one "$((EXPR))" reference. The "(" at i and the second "(" at i+1 are
-- already known to be there. Parentheses inside the expression are counted, so
-- the ")" of "$(( (1+2) * 3 ))" is not taken for the end of the reference.
local function read_arith(line, i, n)
    local depth, j = 0, i
    local close = nil
    while j <= n do
        local c = line:sub(j, j)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                close = j
                break
            end
        end
        j = j + 1
    end
    -- The reference is "$((" .. EXPR .. "))": the expression ends two
    -- characters before the ")" that closed the count, so both closing
    -- parentheses stay outside of it.
    local raw = "$" .. line:sub(i, close or n)
    local expr = line:sub(i + 2, (close and close - 2) or n)
    return { k = "arith", expr = expr, raw = raw }, raw,
           (close and close + 1) or n + 1
end

-- Read one "$(CMD)" reference. The "(" at i is the first one, the "$" sits at
-- i - 1. The ")" that closes the reference is found by counting parentheses,
-- so the ")" of a nested "$( ... )" or of a plain "( ... )" inside CMD is
-- skipped over; a single or double quoted string is skipped as a whole, so
-- "echo a)b" does not end the reference early.
local function read_cmdsub(line, i, n)
    local depth, j = 0, i
    local close, quote = nil, nil
    while j <= n do
        local c = line:sub(j, j)
        if quote then
            if c == quote then quote = nil end
        elseif c == "'" or c == '"' then
            quote = c
        elseif c == "\\" then
            j = j + 1
        elseif c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                close = j
                break
            end
        end
        j = j + 1
    end
    -- The reference is "$(" .. CMD .. ")". An unclosed "$(" reads to the end
    -- of the text, the same way an unclosed "${" reads the name it holds.
    local raw = line:sub(i - 1, close or n)
    local text = line:sub(i + 1, (close and close - 1) or n)
    return { k = "cmdsub", text = text, raw = raw }, raw,
           (close and close + 1) or n + 1
end

-- Read one "`CMD`" reference. The backquote at i opens it. A backslash keeps
-- its meaning for "$", "`" and "\" only, so "\`" is a literal backquote while
-- "\x" stays the two characters it is (POSIX).
local function read_backquote(line, i, n)
    local buf = {}
    local j, close = i + 1, nil
    while j <= n do
        local c = line:sub(j, j)
        if c == "\\" then
            local nx = line:sub(j + 1, j + 1)
            if nx == "$" or nx == "`" or nx == "\\" then
                buf[#buf + 1] = nx
                j = j + 2
            else
                buf[#buf + 1] = c
                j = j + 1
            end
        elseif c == "`" then
            close = j
            break
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    -- The raw text keeps the backquotes: a background command is rendered
    -- with them and started later on exactly as it was typed.
    local raw = line:sub(i, close or n)
    return { k = "cmdsub", text = table.concat(buf), raw = raw }, raw,
           (close and close + 1) or n + 1
end

-- Read one "$..." reference starting right after the "$" at index i.
-- Handles "${NAME}", "$NAME", "$?" and "$$", the parameter expansion
-- operators "${VAR:-word}", "${VAR:=word}", "${VAR:+word}", "${VAR:?word}"
-- (and their forms without the colon), the length "${#VAR}", the pattern
-- removal "${VAR#pat}", "${VAR##pat}", "${VAR%pat}", "${VAR%%pat}", the
-- arithmetic expansion "$((EXPR))" and the command substitution "$(CMD)".
-- Returns the segment, its text for the quote-removal view, and the index that
-- follows the reference.
local function read_var(line, i, n)
    if line:sub(i, i) == "(" then
        if line:sub(i + 1, i + 1) == "(" then
            return read_arith(line, i, n)
        end
        return read_cmdsub(line, i, n)
    end
    if line:sub(i, i) == "{" then
        local close = closing_brace(line, i)
        local stop = close and close - 1 or n
        local next_i = close and close + 1 or n + 1
        -- The raw text is both the fallback value and what a token renders as.
        local raw = "$" .. line:sub(i, close or n)
        local from = i + 1
        local length = false
        if from < stop and line:sub(from, from) == "#" then
            -- "${#VAR}" is the length of the value. "${#}" is not a length,
            -- it is the old plain reference to the number of parameters.
            length = true
            from = from + 1
        end
        local name, after = read_param_name(line, from, stop)
        if name == nil then
            -- "${}" holds no reference at all, keep the text as it is.
            return { k = "lit", v = raw }, raw, next_i
        end
        local body = line:sub(after, stop)
        local op
        if not length then
            for _, cand in ipairs(PEXP_OPS) do
                if body:sub(1, #cand) == cand then
                    op = cand
                    break
                end
            end
        end
        if op == nil and body ~= "" then
            -- Not an operator this shell knows ("${A:~x}"): keep the old
            -- behaviour, the whole text is a name and expands to nothing.
            local whole = line:sub(i + 1, stop)
            return { k = "var", name = whole }, "$" .. whole, next_i
        end
        if op == nil then
            -- "${NAME}" stays the plain reference it always was.
            if length then
                return { k = "pexp", name = name, op = "len", raw = raw },
                       raw, next_i
            end
            return { k = "var", name = name }, "$" .. name, next_i
        end
        local word = line:sub(after + #op, stop)
        return { k = "pexp", name = name, op = op, word = read_segments(word),
                 raw = raw }, raw, next_i
    end
    local j = i
    while j <= n do
        local cj = line:sub(j, j)
        if is_name_char(cj) then
            j = j + 1
        elseif j == i and (cj == "?" or cj == "$" or cj == "!" or
           cj == "#" or cj == "@" or cj == "*" or cj == "-") then
            -- Positional parameters: "$1", "$#", "$@", "$*", "$0" and "$-",
            -- the letters of the options of "set".
            j = j + 1
        else
            break
        end
    end
    local nm = line:sub(i, j - 1)
    return { k = "var", name = nm }, "$" .. nm, j
end

-- Read the segments of a piece of text: literal runs, "$name" references,
-- "$((EXPR))" and "$(CMD)" substitutions. ESCAPES turns on the backslash of a
-- here document body whose delimiter was not quoted: there a backslash keeps
-- the character it quotes, so "\$NAME" is the text "$NAME" and no reference,
-- while "\<newline>" joins two lines.
read_segments = function(text, escapes)
    local segs, buf = {}, {}
    local function flush()
        if #buf > 0 then
            segs[#segs + 1] = { k = "lit", v = table.concat(buf) }
            buf = {}
        end
    end
    local i, n = 1, #text
    while i <= n do
        local ch = text:sub(i, i)
        if escapes and ch == "\\" then
            -- The backslash of a here document body quotes the next
            -- character; a backslash before a newline joins the two lines.
            local nx = text:sub(i + 1, i + 1)
            if nx == "$" or nx == "`" or nx == "\\" then
                buf[#buf + 1] = nx
                i = i + 2
            elseif nx == "\n" then
                i = i + 2
            else
                buf[#buf + 1] = ch
                i = i + 1
            end
        elseif ch == "$" then
            flush()
            local seg, _, next_i = read_var(text, i + 1, n)
            segs[#segs + 1] = seg
            i = next_i
        elseif ch == "`" then
            -- The old form of a command substitution, still read inside the
            -- word of a "${VAR:-`cmd`}" style operator.
            flush()
            local seg, _, next_i = read_backquote(text, i, n)
            segs[#segs + 1] = seg
            i = next_i
        else
            buf[#buf + 1] = ch
            i = i + 1
        end
    end
    flush()
    return segs
end

-- Literal text of a segment list, with "$name" written back for variable
-- segments and "$((EXPR))" for arithmetic ones. Only used for display and for
-- tokens built by the tokenizer.
local function segs_to_text(segs)
    local buf = {}
    for _, s in ipairs(segs) do
        if s.k == "lit" then
            buf[#buf + 1] = s.v
        elseif s.k == "pexp" then
            buf[#buf + 1] = s.raw or ("${" .. tostring(s.name) .. "}")
        elseif s.k == "arith" then
            buf[#buf + 1] = s.raw or "$(( ))"
        elseif s.k == "cmdsub" then
            buf[#buf + 1] = s.raw or "$( )"
        else
            buf[#buf + 1] = "$" .. s.name
        end
    end
    return table.concat(buf)
end

-- ------------------------------------------------------------ here documents

-- The word that ends a here document ("<<WORD" and "<<-WORD"). Quotes are
-- dropped from it and remembered: a delimiter that was quoted ('EOF', "EOF")
-- keeps the body of the document as it was typed, while a bare one leaves the
-- references inside the body live. Returns the word, whether it was quoted
-- and the index that follows it (nil for the word when there is none at all).
local function read_heredoc_delim(text, from, n)
    local buf, quoted = {}, false
    local i = from
    while i <= n do
        local c = text:sub(i, i)
        if c == "'" or c == '"' then
            quoted = true
            local j = i + 1
            while j <= n and text:sub(j, j) ~= c do j = j + 1 end
            buf[#buf + 1] = text:sub(i + 1, j - 1)
            i = j + 1
        elseif c == "\\" then
            -- A backslash quotes the delimiter as well, so "\EOF" and "'EOF'"
            -- mean the same thing for the body.
            quoted = true
            buf[#buf + 1] = text:sub(i + 1, i + 1)
            i = i + 2
        elseif is_special_char(c) then
            break
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    if #buf == 0 then return nil, quoted, i end
    return table.concat(buf), quoted, i
end

-- The body of a here document: every line behind the one that holds the
-- operator, up to the line that holds the delimiter all by itself. That line
-- is not part of the body and the text behind it is tokenized as usual. With
-- "<<-" every body line loses its leading tabs. Returns the body (each line
-- keeps its newline), the index that follows the delimiter line, and whether
-- that line was found at all.
local function heredoc_body(text, from, delim, tabstrip)
    local out = {}
    local pos = from
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        local stop = (nl and nl - 1) or #text
        local line = text:sub(pos, stop)
        if tabstrip then line = line:gsub("^\t+", "") end
        if line == delim then
            return table.concat(out), (nl and nl + 1) or (#text + 1), true
        end
        out[#out + 1] = line
        out[#out + 1] = "\n"
        if nl == nil then break end
        pos = nl + 1
    end
    return table.concat(out), #text + 1, false
end

-- The here documents left open by the last tokenize() call: their delimiter
-- was never met because the text ended first. The interactive loop reads this
-- list to ask for the missing body lines.
local heredocs_open = {}

local function tokenize(line)
    local raw = {}
    -- The here documents opened by the line being read, in the order they
    -- appear: their bodies start behind the newline that ends that line.
    local pending = {}
    local i, n = 1, #line

    while i <= n do
        local c = line:sub(i, i)
        if is_blank_char(c) then
            while i <= n and is_blank_char(line:sub(i, i)) do i = i + 1 end
            table.insert(raw, { type = "blank" })
        elseif c == "#" then
            -- A comment runs to the end of its own line only. Script files are
            -- tokenized as one piece of text, so a "#!" line (or any comment)
            -- must leave the following lines alone.
            local nl = line:find("\n", i, true)
            local stop = (nl and nl - 1) or n
            table.insert(raw, { type = "comment", text = line:sub(i + 1, stop) })
            i = stop + 1
        elseif c == "|" then
            if line:sub(i + 1, i + 1) == "|" then
                table.insert(raw, { type = "op", op = "||" }); i = i + 2
            else
                table.insert(raw, { type = "op", op = "|" }); i = i + 1
            end
        elseif c == "&" then
            if line:sub(i + 1, i + 1) == "&" then
                table.insert(raw, { type = "op", op = "&&" }); i = i + 2
            else
                table.insert(raw, { type = "op", op = "&" }); i = i + 1
            end
        elseif c == ";" then
            table.insert(raw, { type = "op", op = ";" }); i = i + 1
        elseif c == "\n" then
            -- A newline separates statements exactly like ";". Script files
            -- (and pasted multi-line input) rely on this. It is also where the
            -- body of every here document opened by that line begins: the
            -- bodies are read in the order their operators appeared.
            table.insert(raw, { type = "op", op = "\n" }); i = i + 1
            while #pending > 0 do
                local job = table.remove(pending, 1)
                local body, after = heredoc_body(line, i, job.delim,
                                                 job.tabstrip)
                job.body = body
                i = after
            end
        elseif c == "(" or c == ")" or c == "{" or c == "}" then
            table.insert(raw, { type = "op", op = c }); i = i + 1
        elseif c == "<" then
            if line:sub(i + 1, i + 1) == "<" then
                -- "<<" opens a here document, "<<-" the same with the leading
                -- tabs of its body stripped. The body itself is read when the
                -- end of the line is reached.
                local tabstrip = (line:sub(i + 2, i + 2) == "-")
                local j = i + (tabstrip and 3 or 2)
                while j <= n and is_blank_char(line:sub(j, j)) do j = j + 1 end
                local delim, quoted, after = read_heredoc_delim(line, j, n)
                if delim == nil then
                    table.insert(raw, { type = "op", op = "<<", bad = true })
                else
                    local tok = { type = "op", op = "<<", delim = delim,
                                  tabstrip = tabstrip, expand = not quoted,
                                  body = "" }
                    table.insert(raw, tok)
                    table.insert(pending, tok)
                end
                i = after
            else
                table.insert(raw, { type = "op", op = "<" }); i = i + 1
            end
        elseif (c == "1" or c == "2") and line:sub(i + 1, i + 1) == ">" then
            -- A file descriptor in front of ">": "2>" sends the DIAGNOSTIC stream
            -- somewhere else, and "1>" is the plain stdout redirection written out
            -- in full. Recognised only when the digit is IMMEDIATELY followed by
            -- the ">", which is what POSIX does: "echo 2 > f" is the argument "2"
            -- plus a stdout redirect, while "echo 2>f" sends diagnostics to f.
            --
            -- "2>&1" duplicates the diagnostic stream onto standard output. The
            -- reverse ("1>&2") is deliberately not accepted: it would need a
            -- stream to duplicate INTO, and refusing an operator is better than
            -- quietly treating "1>&2" as an argument, which is exactly the bug
            -- this branch exists to fix.
            local nxt = line:sub(i + 2, i + 2)
            if c == "2" and nxt == "&" and line:sub(i + 3, i + 3) == "1" then
                table.insert(raw, { type = "op", op = "2>&1" })
                i = i + 4
            elseif nxt == ">" then
                table.insert(raw, { type = "op", op = (c == "2") and "2>>" or ">>" })
                i = i + 3
            else
                table.insert(raw, { type = "op", op = (c == "2") and "2>" or ">" })
                i = i + 2
            end
        elseif c == ">" then
            if line:sub(i + 1, i + 1) == ">" then
                table.insert(raw, { type = "op", op = ">>" }); i = i + 2
            else
                table.insert(raw, { type = "op", op = ">" }); i = i + 1
            end
        elseif c == "=" then
            if line:sub(i + 1, i + 1) == "=" then
                -- "==" is a test operator, not an assignment: one word token.
                table.insert(raw, make_word("==", { { k = "lit", v = "==" } }, false, "=="))
                i = i + 2
            else
                table.insert(raw, { type = "op", op = "=" }); i = i + 1
            end
        else
            local segs, text, cur, quoted, plain = {}, {}, {}, false, {}
            local function flush()
                if #cur > 0 then
                    table.insert(segs, { k = "lit", v = table.concat(cur) })
                    table.insert(plain, table.concat(cur))
                    cur = {}
                end
            end
            local function add_raw(s)
                table.insert(text, s)
                table.insert(cur, s)
            end
            while i <= n do
                local ch = line:sub(i, i)
                if ch == "\\" then
                    i = i + 1
                    if i <= n then add_raw(line:sub(i, i)); i = i + 1 end
                elseif ch == "'" or ch == '"' then
                    quoted = true
                    local q = ch
                    i = i + 1
                    table.insert(text, q)
                    flush()
                    local run = {}
                    local function flush_run()
                        if #run > 0 then
                            table.insert(segs, { k = "lit", v = table.concat(run) })
                            table.insert(plain, table.concat(run))
                            run = {}
                        end
                    end
                    while i <= n and line:sub(i, i) ~= q do
                        local cc = line:sub(i, i)
                        local nx = line:sub(i + 1, i + 1)
                        if q == '"' and cc == "\\" and
                           (nx == '"' or nx == "\\" or nx == "$") then
                            table.insert(text, "\\" .. nx)
                            table.insert(run, nx)
                            i = i + 2
                        elseif q == '"' and cc == "$" then
                            -- Double quotes keep expanding variables.
                            flush_run()
                            i = i + 1
                            local vseg, vplain, vnext = read_var(line, i, n)
                            if vseg.k == "cmdsub" then
                                -- Keep the whole "$(CMD)" in the rendered text.
                                table.insert(text, vplain)
                            else
                                table.insert(text, cc)
                            end
                            table.insert(segs, vseg)
                            table.insert(plain, vplain)
                            i = vnext
                        elseif q == '"' and cc == "`" then
                            -- A quoted command substitution: the result stays
                            -- one field, it is not split and not globbed.
                            flush_run()
                            local cseg, cplain, cnext = read_backquote(line, i, n)
                            table.insert(text, cplain)
                            table.insert(segs, cseg)
                            table.insert(plain, cplain)
                            i = cnext
                        else
                            table.insert(text, cc)
                            table.insert(run, cc)
                            i = i + 1
                        end
                    end
                    flush_run()
                    if i <= n then
                        table.insert(text, q)
                        i = i + 1
                    end
                elseif ch == "$" then
                    flush()
                    i = i + 1
                    local vseg, vplain, vnext = read_var(line, i, n)
                    if vseg.k == "cmdsub" then
                        -- The rendered text of the token keeps the whole
                        -- "$(CMD)": a background unit is started from it.
                        table.insert(text, vplain)
                    else
                        table.insert(text, ch)
                    end
                    table.insert(segs, vseg)
                    table.insert(plain, vplain)
                    i = vnext
                elseif ch == "`" then
                    -- The old form of a command substitution. Inside a word it
                    -- is one segment, exactly like "$(CMD)".
                    flush()
                    local cseg, cplain, cnext = read_backquote(line, i, n)
                    table.insert(text, cplain)
                    table.insert(segs, cseg)
                    table.insert(plain, cplain)
                    i = cnext
                elseif is_special_char(ch) then
                    break
                else
                    add_raw(ch)
                    i = i + 1
                end
            end
            -- Flush the pending literal run first: only then can we tell
            -- whether the word produced any segment at all.
            flush()
            if #segs == 0 then
                table.insert(segs, { k = "lit", v = "" })
            end
            table.insert(raw, make_word(table.concat(text), segs, quoted, table.concat(plain)))
        end
    end

    -- Second pass:
    --   * "NAME=value" at the head of a simple command becomes an assignment
    --     token ("x=1");
    --   * an "=" written without blanks around it is folded back into the
    --     surrounding word, so "/usr/local/bin/x=y" stays one argument;
    --   * a spaced "=" stays a plain argument, which is what the test built-in
    --     and other commands expect ("[ $a = $b ]").
    local out = {}
    local at_head = true
    local k = 1
    while k <= #raw do
        local tok = raw[k]
        if tok.type == "blank" then
            table.insert(out, tok)
            k = k + 1
        elseif tok.type == "comment" then
            table.insert(out, tok)
            table.insert(out, { type = "op", op = ";" })
            at_head = true
            k = k + 1
        elseif tok.type == "op" then
            table.insert(out, tok)
            at_head = (tok.op == ";" or tok.op == "&&" or tok.op == "||" or
                       tok.op == "&" or tok.op == "\n")
            k = k + 1
        else
            local nxt = raw[k + 1]
            local plain_name = (not tok.quoted) and #tok.segs == 1 and
                tok.segs[1].k == "lit" and tok.segs[1].v:match("^[%a_][%w_]*$") ~= nil
            if at_head and plain_name and nxt and nxt.type == "op" and nxt.op == "=" then
                local val = raw[k + 2]
                local is_val = val and val.type == "word"
                table.insert(out, {
                    type = "assign",
                    name = tok.segs[1].v,
                    segs = is_val and val.segs or { { k = "lit", v = "" } },
                })
                k = k + (is_val and 3 or 2)
            elseif nxt and nxt.type == "op" and nxt.op == "=" and
                   raw[k + 2] and raw[k + 2].type == "word" then
                -- "a=b" written as one argument: glue the three tokens back
                -- together (a blank after the "=" means it was meant as an
                -- ordinary argument instead).
                local segs = {}
                for _, s in ipairs(tok.segs) do segs[#segs + 1] = s end
                segs[#segs + 1] = { k = "lit", v = "=" }
                for _, s in ipairs(raw[k + 2].segs) do segs[#segs + 1] = s end
                local text = segs_to_text(segs)
                table.insert(out, {
                    type = "word", text = text, segs = segs,
                    quoted = tok.quoted, plain = text,
                })
                at_head = false
                k = k + 3
            else
                table.insert(out, tok)
                at_head = false
                k = k + 1
            end
        end
    end
    if #pending > 0 then
        -- The text ended with a here document still open: its body stops at
        -- the end of the text, and the delimiters that were never met are left
        -- for the interactive loop, which asks for the missing lines.
        for _, job in ipairs(pending) do
            job.body = (heredoc_body(line, i, job.delim, job.tabstrip))
        end
    end
    heredocs_open = pending
    return out
end

-- The here documents that the given text leaves open, in the order they
-- appear. The interactive loop uses the delimiters to read the missing body
-- lines, so that "cat <<EOF" typed at the prompt waits for its body instead of
-- running with an empty one.
local function heredoc_scan(text)
    local saved = heredocs_open
    heredocs_open = {}
    tokenize(text)
    local open = heredocs_open
    heredocs_open = saved
    return open
end

-- Read the body lines of every here document that LINE leaves open. MORE is
-- the routine that asks the user for one more line; without it the text is
-- handed back unchanged (a script or "ush -c" is never asked anything).
local function heredoc_more(line, more)
    if not more then return line end
    local open = heredoc_scan(line)
    if #open == 0 then return line end
    local out = line
    for _, job in ipairs(open) do
        while true do
            local next_line = more()
            if next_line == nil then return out end
            next_line = (next_line:gsub("\r", ""))
            out = out .. "\n" .. next_line
            local probe = next_line
            if job.tabstrip then probe = probe:gsub("^\t+", "") end
            if probe == job.delim then break end
        end
    end
    return out
end

-- ------------------------------------------------------------
-- Simple commands: expansion and execution
-- ------------------------------------------------------------

-- Value of a "$name" reference. Positional parameters ($0, $1..$9, $#, $@, $*)
-- live in lib/params.lua, "$-" is the letters of the options of "set" and
-- everything else is a shell variable.
local function var_value(name)
    if name == "-" then return SET_OPTIONS.letters() end
    if params.is_param(name) then return params.get(name) end
    return vars.get(name)
end

local function quote_remove(tok)
    local buf = {}
    for _, s in ipairs(tok.segs) do
        if s.k == "lit" then
            buf[#buf + 1] = s.v
        elseif s.k == "pexp" then
            buf[#buf + 1] = s.raw or ("${" .. tostring(s.name) .. "}")
        elseif s.k == "arith" then
            buf[#buf + 1] = s.raw or "$(( ))"
        else
            buf[#buf + 1] = "$" .. s.name
        end
    end
    return table.concat(buf)
end

-- A token with a variable, a parameter expansion or an arithmetic expansion
-- may expand to nothing, and such a word is dropped instead of becoming an
-- empty argument (POSIX).
local function has_var(tok)
    for _, s in ipairs(tok.segs) do
        if s.k == "var" or s.k == "pexp" or s.k == "arith" or
           s.k == "cmdsub" then
            return true
        end
    end
    return false
end

-- The message of a failing "${VAR:?word}" or of a bad arithmetic expansion,
-- set while the token is expanded and turned into a status by build_stages().
local expand_failure = nil

-- Value of a plain "$NAME" reference, with "set -u" in force: a name that is
-- not set is a fault ("NAME: unbound variable") instead of an empty value, the
-- way POSIX nounset wants it. The fault is reported through expand_failure, so
-- build_stages() ends the command with a non zero status and nothing of it
-- runs. The positional parameters and "$-" are always considered set: what
-- they stand for is decided by the shell, not by a variable.
local function var_read(name)
    local value = var_value(name)
    if value == nil and SHELL.nounset and not params.is_param(name) and
       name ~= "-" then
        expand_failure = name .. ": unbound variable"
    end
    return value
end

-- Command substitution: "$(CMD)" and "`CMD`" run CMD in a sub shell and stand
-- for what it wrote on the standard output. That run belongs to the control
-- flow layer far below, which is why the hook is declared here for the
-- expander above; lib/cwd.lua is restored by the sub shell itself.
local cmdsub_run
-- Status of the last command substitution of the command being expanded. A
-- command that holds nothing but substitutions ("x=$(false)") ends with this
-- status; build_stages() clears it for every new command.
local cmdsub_status = nil
-- While a unit is only rendered (a background job waiting in the job table,
-- for instance) a substitution in it must not run yet: it is written out as it
-- was typed and runs when the unit really starts.
local cmdsub_suppress = 0

-- Value of one "$(CMD)" or "`CMD`" reference.
local function cmdsub_value(seg)
    if cmdsub_suppress > 0 then return seg.raw or "" end
    return cmdsub_run(seg.text)
end

-- Value of one "$((EXPR))" reference. The expression is read by lib/arith.lua
-- on the exact integers of lib/bignum.lua; a name in it is simply the text of
-- that shell variable. A bad expression or a division by zero is a fault: the
-- reason is kept and build_stages() ends the command with a non zero status.
local function arith_value(seg)
    local text, why = arith.eval(seg.expr, function(name)
        -- A name inside "$((EXPR))" is a reference like any other, so "set -u"
        -- reports it when it is not set.
        return var_read(name)
    end)
    if text == nil then
        expand_failure = why
        return ""
    end
    return text
end

-- Forward declaration: pexp_value() expands the word of an operator, which is
-- the job of expand_plain().
local pexp_value

-- Expand a segment list without field splitting or globbing.
local function expand_plain(segs)
    local buf = {}
    for _, s in ipairs(segs) do
        if s.k == "lit" then
            buf[#buf + 1] = s.v
        elseif s.k == "pexp" then
            buf[#buf + 1] = pexp_value(s)
        elseif s.k == "arith" then
            buf[#buf + 1] = arith_value(s)
        elseif s.k == "cmdsub" then
            buf[#buf + 1] = cmdsub_value(s)
        else
            buf[#buf + 1] = var_read(s.name) or ""
        end
    end
    return table.concat(buf)
end

-- A read only handle over a string, so that the body of a here document feeds
-- the standard input of a command through the same interface the console and
-- fs.open() offer: readLine in a for loop, readAll and close.
local function text_reader(text)
    local handle = { lines = {}, pos = 1 }
    local start = 1
    while start <= #text do
        local nl = text:find("\n", start, true)
        if nl == nil then
            handle.lines[#handle.lines + 1] = text:sub(start)
            break
        end
        handle.lines[#handle.lines + 1] = text:sub(start, nl - 1)
        start = nl + 1
    end
    function handle.readLine(self)
        self = self or handle
        if self.pos > #self.lines then return nil end
        local line = self.lines[self.pos]
        self.pos = self.pos + 1
        return line
    end
    function handle.readAll(self)
        self = self or handle
        if self.pos > #self.lines then return "" end
        local body = table.concat(self.lines, "\n", self.pos) .. "\n"
        self.pos = #self.lines + 1
        return body
    end
    function handle.close(self)
        self = self or handle
        self.pos = #self.lines + 1
    end
    return handle
end

-- The text a here document hands to its command. A delimiter that was not
-- quoted leaves the references of the body live: "$NAME", "$(( ))" and "$( )"
-- are expanded as they are inside a quoted string, and a backslash keeps the
-- character it quotes. The body is never split into fields and no pattern is
-- tried on it; a quoted delimiter ('EOF' or "EOF") keeps the text exactly as
-- it was typed.
local function heredoc_text(here)
    local body = here.body or ""
    if here.expand == false then return body end
    return expand_plain(read_segments(body, true))
end

-- Strip the shortest ("#" and "%") or the longest ("##" and "%%") matching
-- prefix or suffix of VALUE off it. The pattern is a shell glob, and "*" also
-- matches "/" here, so "${path##*/}" is the basename idiom and "${path%/*}"
-- the dirname one, as in a POSIX shell.
local function pattern_remove(value, op, pat)
    local prefix = (op == "#" or op == "##")
    local longest = (op == "##" or op == "%%")
    local last = #value
    for step = 0, last do
        local len = longest and (last - step) or step
        local piece, rest
        if prefix then
            piece, rest = value:sub(1, len), value:sub(len + 1)
        else
            piece, rest = value:sub(last - len + 1), value:sub(1, last - len)
        end
        if glob.match_value(piece, pat) then return rest end
    end
    return value
end

-- The word of a "${VAR:-word}" style operator, expanded with the variables of
-- this moment.
local function pexp_word(seg)
    if seg.word == nil then return "" end
    return expand_plain(seg.word)
end

-- Value of one "${VAR...}" reference. The colon forms treat a set but empty
-- value as missing, the forms without a colon only look at unset variables,
-- which is what POSIX prescribes.
pexp_value = function(seg)
    local name = seg.name
    local op = seg.op or ""
    local value = var_value(name)
    if op == "len" then
        return tostring(value ~= nil and #value or 0)
    end
    local colon = op:sub(1, 1) == ":"
    local base = op:sub(-1)
    local missing = (value == nil) or (colon and value == "")
    if base == "#" or base == "%" then
        return pattern_remove(value or "", op, pexp_word(seg))
    end
    if base == "-" then
        -- The default value is used, the variable is left alone.
        if missing then return pexp_word(seg) end
        return value or ""
    end
    if base == "=" then
        if missing then
            local word = pexp_word(seg)
            -- A positional parameter has no name to assign to, so "${1:=x}"
            -- only yields the word.
            if not params.is_param(name) then vars.set(name, word) end
            return word
        end
        return value or ""
    end
    if base == "+" then
        -- The word is only used when the variable is set.
        if missing then return "" end
        return pexp_word(seg)
    end
    if base == "?" then
        if missing then
            local word = pexp_word(seg)
            local why = name .. ": parameter not set or null"
            if word ~= "" then why = name .. ": " .. word end
            expand_failure = why
            return ""
        end
        return value or ""
    end
    if op == "" then
        -- A plain reference "${NAME}" is read the same way "$NAME" is, so
        -- "set -u" reports an undefined name here as well.
        return var_read(name) or ""
    end
    return value or ""
end

-- Render a token list back into a command line. Job control uses it to hand a
-- background unit to a new coroutine and to echo the command in "jobs".
local function render_tokens(tokens)
    local parts = {}
    -- A substitution inside a rendered unit is written out as it was typed
    -- instead of being run right away: the unit starts later (job control) and
    -- the substitution has to run at that moment, exactly once.
    cmdsub_suppress = cmdsub_suppress + 1
    for _, tok in ipairs(tokens) do
        if tok.type == "word" then
            parts[#parts + 1] = tok.text or ""
        elseif tok.type == "blank" then
            parts[#parts + 1] = " "
        elseif tok.type == "assign" then
            parts[#parts + 1] = tok.name .. "=" .. expand_plain(tok.segs)
        elseif tok.type == "op" then
            -- A newline separator is rendered as ";" so the string stays a
            -- valid single line for job control.
            parts[#parts + 1] = (tok.op == "\n") and ";" or tok.op
        end
    end
    cmdsub_suppress = cmdsub_suppress - 1
    return (table.concat(parts):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split a bare (unquoted) value on the default IFS, like POSIX word splitting
-- does: "a b" becomes two fields, "\t" and "\n" count as separators just like
-- a blank.
local function split_ifs(value)
    local pieces, buf = {}, {}
    for i = 1, #value do
        local ch = value:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\n" then
            pieces[#pieces + 1] = table.concat(buf)
            buf = {}
        else
            buf[#buf + 1] = ch
        end
    end
    pieces[#pieces + 1] = table.concat(buf)
    return pieces
end

-- Expand a segment list with field splitting on variable values and with
-- pathname expansion. Unmatched patterns are kept literally (POSIX).
local function expand_glob(segs)
    local parts, at = { [1] = "" }, 1
    for _, s in ipairs(segs) do
        if s.k == "lit" then
            parts[at] = parts[at] .. s.v
        else
            -- Only the value itself splits: the field being built keeps its
            -- first piece and every further piece opens a new field. A literal
            -- that follows the parameter is appended to the last field, so
            -- "a-$1-x" stays one word.
            local value
            if s.k == "pexp" then
                value = pexp_value(s)
            elseif s.k == "arith" then
                value = arith_value(s)
            elseif s.k == "cmdsub" then
                value = cmdsub_value(s)
            else
                value = var_read(s.name)
            end
            local pieces = split_ifs(value or "")
            parts[at] = parts[at] .. pieces[1]
            for k = 2, #pieces do
                at = at + 1
                parts[at] = pieces[k]
            end
        end
    end

    local out, seen = {}, {}
    for _, p in ipairs(parts) do
        if p ~= "" and glob.has_magic(p) then
            local matches = glob.expand(p)
            if #matches == 0 then
                out[#out + 1] = p
            else
                for _, m in ipairs(matches) do
                    -- glob.expand() already keeps the prefix the user typed:
                    -- relative patterns yield relative names, absolute ones
                    -- stay absolute.
                    if not seen[m] then
                        seen[m] = true
                        out[#out + 1] = m
                    end
                end
            end
        elseif p ~= "" then
            out[#out + 1] = p
        end
    end
    return out
end

-- The words one token expands to. An unquoted "$@" is the one form that yields
-- several words at once (POSIX field splitting of the positional parameters);
-- every other token goes through the normal expansion path. A quoted "$@" is
-- joined with blanks and stays a single word.
local function expand_token_words(tok)
    if not tok.quoted and #tok.segs == 1 and tok.segs[1].k == "var" and
       tok.segs[1].name == "@" then
        return params.all()
    end
    if tok.quoted then return { expand_plain(tok.segs) } end
    local val = expand_glob(tok.segs)
    if #val == 0 then
        if has_var(tok) then return {} end
        return { quote_remove(tok) }
    end
    return val
end

local function set_field(stage, name, value)
    for _, f in ipairs(stage.fields) do
        if f.name == name then
            f.value = value
            return
        end
    end
    table.insert(stage.fields, { name = name, value = value })
end

-- Build the pipeline stages of one simple command from its tokens. On a
-- failing "${VAR:?word}" the expansion stops the command: nil and the reason
-- are returned instead of the stages.
local function build_stages(tokens, first)
    local stages = {}
    expand_failure = nil
    -- Every command starts with a clean slate: the status of a command
    -- substitution only counts for the command it belongs to.
    cmdsub_status = nil
    -- The assignments that stood in front of the command, in the shape they
    -- are traced with: a leading assignment has already gone into the
    -- variables, so its text is kept here for "set -x".
    local trace = {}
    -- err/err_append/err_to_out are the diagnostic stream of "2>", "2>>" and
    -- "2>&1". They are three fields rather than one because "2>&1" has no target
    -- of its own: it means "wherever stdout ends up".
    local st = { words = {}, fields = {}, redirect = nil, append = false,
                 input = nil, here = nil,
                 err = nil, err_append = false, err_to_out = false,
                 err_to_prior = false }
    local function push()
        if #st.words > 0 then table.insert(stages, st) end
        st = { words = {}, fields = {}, redirect = nil, append = false,
               input = nil, here = nil,
               err = nil, err_append = false, err_to_out = false,
               err_to_prior = false }
    end

    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        if tok.type == "blank" or tok.type == "comment" then
            i = i + 1
        elseif tok.type == "assign" then
            if first and #stages == 0 and #st.words == 0 then
                local value = expand_plain(tok.segs)
                vars.set(tok.name, value)
                trace[#trace + 1] = tok.name .. "=" .. tostring(value)
            else
                set_field(st, tok.name, expand_plain(tok.segs))
            end
            i = i + 1
        elseif tok.type == "op" then
            if tok.op == "|" then
                push()
                i = i + 1
            elseif tok.op == "=" then
                -- A spaced "=" is an ordinary argument ("[ $a = $b ]"). The
                -- unspaced form was already folded back into its word by the
                -- tokenizer.
                st.words[#st.words + 1] = "="
                i = i + 1
            elseif tok.op == "2>&1" then
                -- The diagnostic stream becomes whatever standard output is AT
                -- THIS POINT, which is why the position of the operator matters:
                -- "> f 2>&1" sends diagnostics to f, while "2>&1 > f" leaves them
                -- on the stdout that existed before f was opened. Recorded as a
                -- flag rather than resolved here, because _out is not known until
                -- the stage runs -- err_to_prior says "the stdout from before the
                -- later redirect", and open_stderr reads it.
                st.err_to_out = true
                if not st.redirect then st.err_to_prior = true end
                i = i + 1
            elseif tok.op == ">" or tok.op == ">>" or tok.op == "2>"
                   or tok.op == "2>>" then
                -- Blanks may separate the operator from its target word.
                local j = i + 1
                while j <= #tokens and (tokens[j].type == "blank" or
                       tokens[j].type == "comment") do
                    j = j + 1
                end
                local nxt = tokens[j]
                if nxt and nxt.type == "word" then
                    local target = expand_plain(nxt.segs)
                    if tok.op == "2>" then
                        st.err = target
                    elseif tok.op == "2>>" then
                        st.err = target
                        st.err_append = true
                    elseif tok.op == ">>" then
                        st.append = true
                        st.redirect = target
                    else
                        st.redirect = target
                    end
                    i = j + 1
                else
                    i = i + 1
                end
            elseif tok.op == "<" then
                local j = i + 1
                while j <= #tokens and (tokens[j].type == "blank" or
                       tokens[j].type == "comment") do
                    j = j + 1
                end
                local nxt = tokens[j]
                if nxt and nxt.type == "word" then
                    st.input = expand_plain(nxt.segs)
                    -- "<" and "<<" want the same input: the redirection that
                    -- appears last wins, so the other one is dropped here.
                    st.here = nil
                    i = j + 1
                else
                    i = i + 1
                end
            elseif tok.op == "<<" then
                if tok.bad then
                    write_stdout("ush: syntax error near unexpected token 'newline'")
                    return {}
                end
                -- A here document: the body read by the tokenizer is the
                -- standard input of this command. It shares one slot with
                -- "<", and the last of the two to appear wins.
                st.input = nil
                st.here = { body = tok.body or "",
                            expand = tok.expand ~= false,
                            word = tok.delim }
                i = i + 1
            elseif tok.op == "(" or tok.op == ")" then
                write_stdout("ush: syntax error near unexpected token '" .. tok.op .. "'")
                return {}
            else
                i = i + 1
            end
        else
            for _, w in ipairs(expand_token_words(tok)) do
                st.words[#st.words + 1] = w
            end
            i = i + 1
        end
    end
    push()
    if expand_failure then
        local why = expand_failure
        expand_failure = nil
        return nil, why
    end
    stages.trace = trace
    return stages
end

local function exec_unit(stages)
    if #stages == 0 then
        -- A command that holds no word to run (only expansions) ends with the
        -- status of its last command substitution, so "$(false)" fails and
        -- "x=$(false)" reports 1.
        return cmdsub_status or SHELL.status
    end
    if #stages == 1 then return run_stage(stages[1]) end
    return run_pipeline(stages)
end

run_stage = function(stage)
    -- The destructive-command blacklist runs first, before redirections, so a
    -- refused command does not even create the file it would have written.
    local danger_reason = require("danger").check(stage.words)
    if danger_reason then
        emit(stage, "ush: " .. danger_reason)
        return 1
    end
    local cmd = stage.words[1]
    local args = {}
    for i = 2, #stage.words do table.insert(args, stage.words[i]) end

    -- A redirection of the stage wins; otherwise the stage writes into the
    -- buffer of the command substitution that is being expanded, if any.
    stage._out = open_output(stage) or capture_top()
    -- After _out, because "2>&1" is "wherever stdout just went".
    stage._err = open_stderr(stage)
    stage._in = nil
    local input_path = stage.input and resolve_path(stage.input) or nil
    if stage.here then
        -- The body of the here document of this command is its standard
        -- input. It wins over the pipe of a pipeline, exactly like "<".
        stage._in = text_reader(heredoc_text(stage.here))
    elseif input_path and fs.exists(input_path) then
        stage._in = fs.open(input_path, "r")
    elseif _G.__ush_stdin and fs.exists(_G.__ush_stdin) then
        stage._in = fs.open(_G.__ush_stdin, "r")
    end

    -- Every stage reports a numeric exit status so that "$?" and the "&&"/"||"
    -- lists can act on it: 0 success, 1 error, 126 not executable,
    -- 127 command not found.
    local status = 0

    if cmd == nil then
        -- No word left to run (the expansions of the command produced no
        -- field): the status of the command substitution is the status of the
        -- command, as POSIX asks.
        status = cmdsub_status or 0
    elseif BUILTINS[cmd] then
        local result = BUILTINS[cmd](args, stage)
        if type(result) == "number" then status = result end
        -- A built-in is a command like any other: one that was found and
        -- reports a status that is not 0 runs the trap of ERR, the way the
        -- manual tells it.
        if type(status) == "number" and status ~= 0 then
            trap_fire("ERR", status)
        end
    elseif FUNCTIONS and FUNCTIONS[cmd] then
        -- A shell function: it runs with its own positional parameters and
        -- "return" ends the call with its status.
        status = call_function(FUNCTIONS[cmd], args, stage)
        if type(status) == "number" and status ~= 0 then
            trap_fire("ERR", status)
        end
    else
        local pathlib = require("path")
        local full = nil
        local script = nil
        if cmd:find("/", 1, true) then
            -- Command given as a path: use it directly, with or without the
            -- deployed ".lua" extension.
            local abs = resolve_path(cmd)
            if fs.exists(abs) then full = abs
            elseif fs.exists(abs .. ".lua") then full = abs .. ".lua" end
        else
            full = pathlib.find(cmd)
        end
        if not full then
            local ok, pkg = pcall(require, "pkg")
            if ok then full = pkg.resolve_command(cmd) end
        end
        -- A shell script found on PATH (or given as a path) is executed as a
        -- script, not loaded as Lua. A file without a script suffix is still
        -- taken as a script when its first line names ush as the interpreter
        -- ("#!/usr/bin/env ush"), so a deployed tool can be called by name.
        if full and pathlib.is_script(full) then
            script = full
            full = nil
        elseif full and is_ush_script_file(full) then
            script = full
            full = nil
        end
        if not full and not script then
            script = pathlib.find_script(cmd)
        end
        if not full and not script and not cmd:find("/", 1, true) then
            -- Last resort: a tool on PATH whose name carries no script suffix
            -- but whose first line names ush as its interpreter.
            for _, dir in ipairs(pathlib.dirs()) do
                local candidate = (dir == "/" and "" or dir) .. "/" .. cmd
                if is_ush_script_file(candidate) then
                    script = candidate
                    break
                end
            end
        end
        if script then
            local text, rerr = read_script_text(script)
            if not text then
                emit_diag(stage, "ush: " .. cmd .. ": " .. tostring(rerr))
                status = 1
            elseif not perm.can_exec(script) then
                emit_diag(stage, "ush: " .. cmd .. ": permission denied")
                status = 126
                trap_fire("ERR", status)
            else
                -- A command script is isolated: "exit" inside it only ends the
                -- script, its code becomes the status of the command.
                status = run_script_text(text, script, args, { isolate = true })
            end
        elseif full and fs.exists(full) then
            if not perm.can_exec(full) then
                emit_diag(stage, "ush: " .. cmd .. ": permission denied")
                status = 126
                trap_fire("ERR", status)
            else
                local chunk, err = loadfile(full)
                if not chunk then
                    emit_diag(stage, "ush: " .. cmd .. ": " .. tostring(err))
                    status = 1
                    trap_fire("ERR", status)
                else
                    -- A command file runs in an environment of its own whose
                    -- __index is the SHELL's environment, which is what the ROM
                    -- does for a program it starts (rom/programs/shell.lua,
                    -- createShellEnv). This is not tidiness: the ROM keeps
                    -- require, package and shell in that environment and NOT in
                    -- _G, while loadfile() hands a chunk the default environment.
                    -- Measured on CraftOS-PC 2.8.3, a command loaded here saw
                    -- require as nil, so every external command of this project
                    -- that loads a module failed with
                    --   usr/cmd/w.lua:12: attempt to call global 'require'
                    -- on a real machine -- while the PC suite, whose stub has a
                    -- global require, stayed green. The fresh table is what keeps
                    -- a command's own globals out of the shell.
                    if setfenv and getfenv then
                        local penv = setmetatable({}, { __index = getfenv(1) })
                        -- Which shell a command is running under is a fact about
                        -- the MOMENT, not about the program: the same screen
                        -- command can be started from a session, from a boot
                        -- script that runs it directly, or from the CraftOS
                        -- prompt. A program that takes the whole screen and
                        -- gives it back asks this to decide whether returning to
                        -- its caller already IS the shell prompt, or whether the
                        -- operator would be left outside the machine's own
                        -- system. Only the command's own table carries it, so a
                        -- nested shell or another program never sees it.
                        penv.__ush_command = true
                        pcall(setfenv, chunk, penv)
                    end
                    if shell and shell.setDir then shell.setDir(cwd.get()) end
                    local ok, e = pcall(chunk, args, stage)
                    if not ok then
                        if is_interrupt_error(e) then
                            -- Ctrl+T stopped the command: the trap of INT runs
                            -- and the status becomes the one of an interrupted
                            -- command, the way a shell reports 128 + SIGINT.
                            status = trap_fire("INT", 130)
                        else
                            emit_diag(stage, "ush: " .. cmd .. ": runtime error: " .. tostring(e))
                            status = 1
                            trap_fire("ERR", status)
                        end
                    elseif type(e) == "number" then
                        status = e
                        -- A trap of ERR runs for a command that fails, the way
                        -- POSIX does it. A command that is not found is a fault
                        -- of the shell and does not run the trap.
                        if status ~= 0 then trap_fire("ERR", status) end
                    end
                end
            end
        else
            emit_diag(stage, "ush: " .. cmd .. ": command not found")
            status = 127
        end
    end

    if stage._out then stage._out.close() end
    -- Only when it is a handle of its own: with "2>&1" it IS _out, and closing
    -- the same handle twice would close whatever fs handed back for it.
    if stage._err and stage._err ~= stage._out then stage._err.close() end
    if stage._in then stage._in.close() end
    -- A refused redirection is a failure of the command, whatever the command
    -- itself thought: its output went nowhere. The message is already printed
    -- (guard_write wrote it), and a non-zero status is what stops a script from
    -- carrying on as if the write had happened. The command's own status wins
    -- only when it is already a failure, so the first real problem is the one
    -- reported.
    if stage._denied and status == 0 then
        status = 1
        trap_fire("ERR", status)
    end
    return status
end

run_pipeline = function(stages)
    local tmp_in = nil
    local status = 0
    -- "set -o pipefail": the status of a pipeline is the status of its first
    -- failing stage instead of the status of the stage that ran last.
    local broken = nil
    for idx, stage in ipairs(stages) do
        if #stage.words == 0 then break end
        -- Only the intermediate stages write into a pipe file; the last stage
        -- keeps its own redirection (or the console), otherwise its output
        -- would disappear together with the temporary file.
        local tmp_out = idx < #stages and ("/tmp/.ush_pipe_" .. idx) or nil
        local saved_redirect = stage.redirect
        if tmp_out then
            stage.redirect = tmp_out
            stage.append = false
        end

        local saved_stdin = _G.__ush_stdin
        _G.__ush_stdin = tmp_in

        status = run_stage(stage)

        -- The first stage that failed is remembered for "pipefail"; a stage
        -- that never ran (a command that was not found stops there) does not
        -- count.
        if status ~= 0 and broken == nil then broken = status end

        _G.__ush_stdin = saved_stdin
        stage.redirect = saved_redirect

        if tmp_in then fs.delete(tmp_in) end
        tmp_in = tmp_out
    end
    if tmp_in then fs.delete(tmp_in) end
    if SHELL.pipefail and broken then return broken end
    return status
end

-- ------------------------------------------------------------
-- Command lists: ";" "&&" "||"
-- ------------------------------------------------------------

local function split_units(tokens)
    local units, connectors = {}, {}
    local cur, depth = {}, 0
    local function flush()
        table.insert(units, cur)
        cur = {}
    end
    for _, tok in ipairs(tokens) do
        if tok.type == "op" and tok.op == "{" then
            depth = depth + 1
            if depth > 1 then table.insert(cur, tok) end
        elseif tok.type == "op" and tok.op == "}" then
            if depth > 1 then
                depth = depth - 1
                table.insert(cur, tok)
            elseif depth == 1 then
                depth = 0
                flush()
            end
        elseif depth == 0 and tok.type == "op" and (tok.op == ";" or tok.op == "\n" or
           tok.op == "&&" or tok.op == "||" or tok.op == "&") then
            flush()
            connectors[#units] = tok.op
        else
            table.insert(cur, tok)
        end
    end
    flush()
    return units, connectors
end

-- A command group "{ ... }" and any unit that still contains a connector has
-- to go back through the command list runner instead of a single pipeline.
local function unit_has_connector(unit)
    for _, t in ipairs(unit) do
        if t.type == "op" and (t.op == ";" or t.op == "\n" or t.op == "&&" or
           t.op == "||" or t.op == "&") then
            return true
        end
    end
    return false
end

local function at_command_head(out)
    local j = #out
    while j >= 1 do
        local t = out[j]
        if t.type == "blank" or t.type == "assign" then
            j = j - 1
        elseif t.type == "op" then
            return true
        else
            return false
        end
    end
    return true
end

-- Replace the command word of each simple command by its alias body.
local function expand_aliases(tokens, depth)
    depth = depth or 0
    local out = {}
    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        local name = nil
        if tok.type == "word" and not tok.quoted and not has_var(tok) and
           #tok.segs == 1 and tok.segs[1].v ~= "" and
           tok.segs[1].v:match("^[%a_][%w_%-%.]*$") then
            name = tok.segs[1].v
        end
        local body = name and alias.get(name) or nil
        if body and depth < 10 and at_command_head(out) then
            local expanded = expand_aliases(tokenize(body), depth + 1)
            local join_next = #expanded > 0 and expanded[#expanded].type == "blank"
            if join_next then table.remove(expanded) end
            for _, t in ipairs(expanded) do table.insert(out, t) end
            if join_next then
                local nxt = tokens[i + 1]
                if nxt and nxt.type == "word" then
                    table.insert(out, { type = "blank" })
                end
            end
            i = i + 1
        else
            table.insert(out, tok)
            i = i + 1
        end
    end
    return out
end

local function run_tokens(tokens)
    tokens = expand_aliases(tokens, 0)
    local units, connectors = split_units(tokens)
    local status = SHELL.status
    -- "A && B || C" has to work like in POSIX: when A fails, B is skipped and
    -- C still runs, because the status the "||" tests is the status of the
    -- last command that actually ran. A single "stop" flag cannot express
    -- that (it would keep C silent as well), so the decision for the next
    -- unit is recomputed after every unit, skipped ones included.
    local run_next = true

    for idx = 1, #units do
        local unit = units[idx]
        if run_next then
            local meaningful = false
            for _, t in ipairs(unit) do
                if t.type == "word" or t.type == "assign" then
                    meaningful = true
                    break
                end
            end
            if meaningful then
                -- One unit of the list, as a function of its own so that "set
                -- -e" can be held back while a command whose status is only
                -- tested runs.
                local function run_unit()
                    if connectors[idx] == "&" then
                        -- "cmd &" is a cooperative background job: a coroutine
                        -- is created here and advanced from the idle hook.
                        local job, jerr = jobs.spawn(render_tokens(unit))
                        if job then
                            write_stdout("[" .. job.id .. "] " ..
                                         tostring(job.command or ""))
                            return 0
                        end
                        write_stdout("ush: " .. tostring(jerr))
                        return 1
                    end
                    if unit_has_connector(unit) then
                        -- "{ a; b }" and nested command lists run through the
                        -- command list runner again.
                        return run_tokens(unit)
                    end
                    local stages, why = build_stages(unit, idx == 1)
                    if stages == nil then
                        -- "${VAR:?word}" failed: the shell reports it and the
                        -- command exits non zero without running anything.
                        write_stdout("ush: " .. tostring(why))
                        return 1
                    end
                    if #stages == 0 then
                        -- Only assignments (or nothing but expansions): the
                        -- status of a command substitution in them is the
                        -- status of the command ("x=$(false)" reports 1).
                        SET_OPTIONS.trace({}, stages.trace)
                        return cmdsub_status or 0
                    end
                    -- "set -x" writes the command out before it runs.
                    SET_OPTIONS.trace(stages, stages.trace)
                    return exec_unit(stages)
                end

                local conn = connectors[idx]
                -- A unit that a "&&" or "||" follows is only there to have its
                -- status read by the connector, so "set -e" passes it by: it is
                -- the last command of the list that "set -e" acts on (POSIX).
                local tested = (conn == "&&" or conn == "||")
                if tested then
                    status = SET_OPTIONS.hold(run_unit)
                else
                    status = run_unit()
                end
                SHELL.status = status
                -- Keep "$?" up to date for the unit that comes next, so that
                -- "false; echo $?" prints 1 like in a POSIX shell.
                vars.set_status(status)
                -- "set -e": a unit that failed ends the shell here, unless its
                -- status is only being tested.
                if not tested then SET_OPTIONS.check(status) end
            end
        end
        local conn = connectors[idx]
        if conn == "&&" then
            run_next = status == 0
        elseif conn == "||" then
            run_next = status ~= 0
        elseif conn == "&" then
            -- The unit before "&" has already been handed to the job table;
            -- the command list simply continues with the next unit.
            status = 0
            run_next = true
        else
            run_next = true
        end
    end
    return SHELL.status
end

-- ============================================================
-- Control flow: if / for / while / until / case and functions
-- ============================================================
--
-- run_tokens() only understands simple commands joined by ";", "&&", "||" and
-- "&". Compound commands need a parser in front of it, so the token stream is
-- first turned into a small control tree and the tree is then evaluated:
--
--   * parse_block() splits the stream into items at separators; a separator is
--     ";" or a newline, while "&&", "||" and "&" are kept as the connector of
--     the item that follows them;
--   * an item that starts with a reserved word (if, for, while, until, case)
--     or with "name()" becomes a node, everything else stays a token slice;
--   * the evaluator runs the slices through run_tokens(), which is what keeps
--     pipes, redirections and the logic operators working inside a body;
--   * break / continue / return / exit leave their construct by raising a
--     control table that the loop, function and script runners catch.
--
-- Reserved words are only recognised at the head of an item, exactly like in a
-- POSIX shell, so "echo done" still prints "done". For the same reason "then",
-- "do", "done", "fi", "esac", "elif" and "else" have to be separated from the
-- previous word by ";" or a newline ("if test -f x; then", "while true; do").

-- Safety net: a loop that never ends must not lock up the computer.
local MAX_LOOP_ITERATIONS = 100000

local RESERVED_WORDS = {
    ["if"] = true, ["then"] = true, ["elif"] = true, ["else"] = true,
    ["fi"] = true, ["for"] = true, ["while"] = true, ["until"] = true,
    ["do"] = true, ["done"] = true, ["case"] = true, ["esac"] = true,
    ["in"] = true,
}

-- The subset of the reserved words that may open a compound command. Every
-- other reserved word ("then", "fi", "do", "done", ...) belongs to the
-- construct that is already open, so seeing one at the start of an item is a
-- genuine syntax error.
local ITEM_STARTERS = {
    ["if"] = true, ["for"] = true, ["while"] = true, ["until"] = true,
    ["case"] = true,
}

local Parser = {}
Parser.__index = Parser

local function new_parser(tokens)
    return setmetatable({ toks = tokens, i = 1 }, Parser)
end

function Parser:cur()
    return self.toks[self.i]
end

function Parser:at_end()
    return self.i > #self.toks
end

-- Blanks and comment tokens are invisible to the parser, the same way
-- build_stages() ignores them.
function Parser:skip_trivia()
    while true do
        local t = self:cur()
        if t and (t.type == "blank" or t.type == "comment") then
            self.i = self.i + 1
        else
            return t
        end
    end
end

-- Skip trivia and statement separators. Returns true when a ";" or a newline
-- was crossed, which is what makes "cmd; then" legal and "cmd then" not.
function Parser:skip_separators()
    local saw = false
    while true do
        local t = self:cur()
        if t and (t.type == "blank" or t.type == "comment") then
            self.i = self.i + 1
        elseif t and t.type == "op" and (t.op == ";" or t.op == "\n") then
            saw = true
            self.i = self.i + 1
        else
            return saw
        end
    end
end

-- Head word of the current item, plus its token index. Only a single literal
-- segment counts: "i" is a name, "$i" and "a b" are not.
function Parser:head_word()
    local j = self.i
    while self.toks[j] and (self.toks[j].type == "blank" or
                            self.toks[j].type == "comment") do
        j = j + 1
    end
    local t = self.toks[j]
    if t and t.type == "word" and not t.quoted and not has_var(t) and
       #t.segs == 1 and t.segs[1].k == "lit" then
        return t.segs[1].v, j
    end
    return nil
end

local function is_literal_word(tok, text)
    return tok ~= nil and tok.type == "word" and not tok.quoted and
           #tok.segs == 1 and tok.segs[1].k == "lit" and tok.segs[1].v == text
end

local function is_name_word(tok)
    return tok ~= nil and tok.type == "word" and not tok.quoted and
           not has_var(tok) and
           #tok.segs == 1 and tok.segs[1].k == "lit" and
           tok.segs[1].v:match("^[%a_][%w_]*$") ~= nil
end

-- Tokens of the current item, up to (not including) the first separator at
-- nesting depth 0. The separator stays for the caller.
function Parser:take_item()
    local out = {}
    local depth = 0
    while true do
        local t = self:cur()
        if t == nil then break end
        if t.type == "op" then
            if t.op == "{" or t.op == "(" then
                depth = depth + 1
            elseif t.op == "}" or t.op == ")" then
                if depth == 0 then break end
                depth = depth - 1
            elseif depth == 0 and (t.op == ";" or t.op == "\n") then
                break
            end
        end
        out[#out + 1] = t
        self.i = self.i + 1
    end
    return out
end

-- Expect a keyword ("then", "do", "done", "fi", "in", "esac", "elif",
-- "else"). The keyword may follow a separator or a blank, but it must be a
-- word of its own.
local function expect_keyword(P, word)
    P:skip_separators()
    P:skip_trivia()
    local t = P:cur()
    if is_literal_word(t, word) then
        P.i = P.i + 1
        return true
    end
    local got = "end of input"
    if t then
        if t.type == "word" then
            got = tostring(t.text or "")
        elseif t.type == "op" then
            got = (t.op == "\n") and "newline" or t.op
        end
    end
    return false, "syntax error: expected '" .. word .. "', got '" .. got .. "'"
end

local function no_word_message(toks)
    for _, t in ipairs(toks) do
        if t.type == "word" or t.type == "assign" then return nil end
    end
    return "syntax error: empty command"
end

-- True when the current item looks like a "case" pattern list, i.e. a ")"
-- appears before the next separator ("a)", "a|b)"). A ") " inside a body
-- statement is not reached by this check because the body is parsed item by
-- item and the pattern list is only looked for at an item head.
local function looks_like_pattern(P)
    local j = P.i
    while P.toks[j] do
        local t = P.toks[j]
        if t.type == "op" then
            if t.op == ")" then return true end
            if t.op == ";" or t.op == "\n" or t.op == "(" or t.op == "{" then
                return false
            end
        end
        j = j + 1
    end
    return false
end

local function token_slice(toks, from, to)
    local out = {}
    for i = from, to do
        if toks[i] then out[#out + 1] = toks[i] end
    end
    return out
end

local parse_block   -- forward declaration
local eval_block    -- forward declaration
local eval_slice    -- forward declaration

-- ---- parser: compound commands ----

-- "{ list; }"
local function parse_group(P)
    P:skip_trivia()
    local t = P:cur()
    if not (t and t.type == "op" and t.op == "{") then
        return nil, "syntax error: expected '{'"
    end
    P.i = P.i + 1
    local body, err = parse_block(P, { ["}"] = true })
    if not body then return nil, err end
    P:skip_separators()
    P:skip_trivia()
    local c = P:cur()
    if not (c and c.type == "op" and c.op == "}") then
        return nil, "syntax error: expected '}'"
    end
    P.i = P.i + 1
    return { k = "group", body = body }
end

-- "name() { list; }"
local function parse_function(P)
    local name = P:head_word()
    -- Walk to the closing ")" of the "()" part.
    while true do
        local t = P:cur()
        if t == nil then
            return nil, "syntax error: unterminated function definition"
        end
        P.i = P.i + 1
        if t.type == "op" and t.op == ")" then break end
    end
    local body, err = parse_group(P)
    if not body then return nil, err end
    return { k = "func", name = name, body = body.body }
end

-- True when the item is "name()" rather than a command call.
local function is_function_def(P)
    local name, j = P:head_word()
    if not name or RESERVED_WORDS[name] then return false end
    local k = j + 1
    while P.toks[k] and P.toks[k].type == "blank" do k = k + 1 end
    if not (P.toks[k] and P.toks[k].type == "op" and P.toks[k].op == "(") then
        return false
    end
    k = k + 1
    while P.toks[k] and P.toks[k].type == "blank" do k = k + 1 end
    return P.toks[k] ~= nil and P.toks[k].type == "op" and P.toks[k].op == ")"
end

-- "if list; then list; [elif list; then list;]... [else list;] fi"
local function parse_if(P)
    P:skip_trivia()
    P.i = P.i + 1                       -- "if"
    local branches = {}
    local cond = P:take_item()
    local cmsg = no_word_message(cond)
    if cmsg then return nil, cmsg end
    local ok, err = expect_keyword(P, "then")
    if not ok then return nil, err end

    local stops = { ["elif"] = true, ["else"] = true, ["fi"] = true }
    local body, berr = parse_block(P, stops)
    if not body then return nil, berr end
    branches[#branches + 1] = { cond = cond, body = body }

    local else_body = nil
    while true do
        P:skip_separators()
        P:skip_trivia()
        local head = P:head_word()
        if head == "elif" then
            P.i = P.i + 1
            local c2 = P:take_item()
            local m2 = no_word_message(c2)
            if m2 then return nil, m2 end
            local ok2, err2 = expect_keyword(P, "then")
            if not ok2 then return nil, err2 end
            local b2, e2 = parse_block(P, stops)
            if not b2 then return nil, e2 end
            branches[#branches + 1] = { cond = c2, body = b2 }
        elseif head == "else" then
            P.i = P.i + 1
            local b3, e3 = parse_block(P, { ["fi"] = true })
            if not b3 then return nil, e3 end
            else_body = b3
            break
        else
            break
        end
    end

    local ok3, err3 = expect_keyword(P, "fi")
    if not ok3 then return nil, err3 end
    return { k = "if", branches = branches, else_ = else_body }
end

-- "while list; do list; done" and the "until" variant.
local function parse_while(P, until_)
    P:skip_trivia()
    P.i = P.i + 1                       -- "while" / "until"
    local cond = P:take_item()
    local cmsg = no_word_message(cond)
    if cmsg then return nil, cmsg end
    local ok, err = expect_keyword(P, "do")
    if not ok then return nil, err end
    local body, berr = parse_block(P, { ["done"] = true })
    if not body then return nil, berr end
    local ok2, err2 = expect_keyword(P, "done")
    if not ok2 then return nil, err2 end
    return { k = "while", until_ = until_, cond = cond, body = body }
end

-- "for name [in list]; do list; done". Without "in" the loop walks "$@".
local function parse_for(P)
    P:skip_trivia()
    P.i = P.i + 1                       -- "for"
    P:skip_trivia()
    local name_tok = P:cur()
    if not is_name_word(name_tok) then
        return nil, "syntax error: expected a name after 'for'"
    end
    local name = name_tok.segs[1].v
    P.i = P.i + 1

    local list_toks = nil
    P:skip_trivia()
    if is_literal_word(P:cur(), "in") then
        P.i = P.i + 1
        list_toks = P:take_item()
    end
    local ok, err = expect_keyword(P, "do")
    if not ok then return nil, err end
    local body, berr = parse_block(P, { ["done"] = true })
    if not body then return nil, berr end
    local ok2, err2 = expect_keyword(P, "done")
    if not ok2 then return nil, err2 end
    return { k = "for", name = name, list = list_toks, body = body }
end

-- "case word in [pat|pat) list ;;]... esac"
local function parse_case(P)
    P:skip_trivia()
    P.i = P.i + 1                       -- "case"
    P:skip_trivia()
    local subject_tok = P:cur()
    if subject_tok == nil or subject_tok.type ~= "word" then
        return nil, "syntax error: expected a word after 'case'"
    end
    local subject = { subject_tok }
    P.i = P.i + 1
    local ok, err = expect_keyword(P, "in")
    if not ok then return nil, err end

    local arms = {}
    while true do
        P:skip_separators()
        P:skip_trivia()
        local t = P:cur()
        if t == nil then
            return nil, "syntax error: expected 'esac'"
        end
        if is_literal_word(t, "esac") then
            P.i = P.i + 1
            break
        end

        -- pattern list: [ "(" ] pat [ "|" pat ]... ")"
        local pats = {}
        local cur = {}
        if t.type == "op" and t.op == "(" then P.i = P.i + 1 end
        local closed = false
        while true do
            local tk = P:cur()
            if tk == nil then break end
            if tk.type == "op" and tk.op == ")" then
                closed = true
                P.i = P.i + 1
                break
            end
            if tk.type == "op" and tk.op == "|" then
                pats[#pats + 1] = cur
                cur = {}
                P.i = P.i + 1
            else
                cur[#cur + 1] = tk
                P.i = P.i + 1
            end
        end
        if not closed then
            return nil, "syntax error: expected ')' in case pattern"
        end
        pats[#pats + 1] = cur

        local body, berr = parse_block(P, { ["esac"] = true }, looks_like_pattern)
        if not body then return nil, berr end
        arms[#arms + 1] = { pats = pats, body = body }
    end
    return { k = "case", subject = subject, arms = arms }
end

-- ---- parser: simple commands ----

local function parse_simple(P)
    local toks = P:take_item()
    local t = P:cur()
    if t and t.type == "op" and (t.op == ";" or t.op == "\n" or t.op == "&&" or
       t.op == "||" or t.op == "&" or t.op == ")" or t.op == "}") then
        local msg = no_word_message(toks)
        if msg then
            local got = (t.op == "\n") and "newline" or t.op
            return nil, "syntax error near unexpected token '" .. got .. "'"
        end
    end
    return { k = "simple", toks = toks }
end

local function parse_item(P, head, stops)
    if head == "if" then return parse_if(P) end
    if head == "while" then return parse_while(P, false) end
    if head == "until" then return parse_while(P, true) end
    if head == "for" then return parse_for(P) end
    if head == "case" then return parse_case(P) end
    if is_function_def(P) then return parse_function(P) end
    return parse_simple(P)
end

-- Split the token stream into items until the end of the input or until a
-- stop keyword / stop operator that belongs to the caller.
parse_block = function(P, stops, stop_pred)
    stops = stops or {}
    local items = {}
    while true do
        P:skip_separators()
        if P:at_end() then break end

        local conn = ";"
        local had_conn = false
        local t = P:cur()
        if t.type == "op" and (t.op == "&&" or t.op == "||") then
            conn = t.op
            had_conn = true
            P.i = P.i + 1
            P:skip_trivia()
        end

        if P:at_end() then
            if had_conn then
                return nil, "syntax error near unexpected token 'end of input'"
            end
            break
        end

        local t2 = P:cur()
        if t2.type == "op" and stops[t2.op] then
            if had_conn then
                return nil, "syntax error near unexpected token '" .. t2.op .. "'"
            end
            break
        end

        local head = P:head_word()
        if head and stops[head] then
            if had_conn then
                return nil, "syntax error near unexpected token '" .. head .. "'"
            end
            break
        end
        if head and RESERVED_WORDS[head] and not ITEM_STARTERS[head] then
            return nil, "syntax error near unexpected token '" .. head .. "'"
        end
        if stop_pred and stop_pred(P) then
            if had_conn then
                return nil, "syntax error near unexpected token ')'"
            end
            break
        end

        local from = P.i
        local node, err = parse_item(P, head, stops)
        if not node then return nil, err end

        -- "{ ...; } &" hands the whole construct to the job table.
        if node.k ~= "simple" then
            local saved = P.i
            P:skip_trivia()
            local bg = P:cur()
            if bg and bg.type == "op" and bg.op == "&" then
                P.i = P.i + 1
                node = { k = "bg", inner = node,
                         toks = token_slice(P.toks, from, saved - 1) }
            else
                P.i = saved
            end
        end

        items[#items + 1] = { node = node, conn = conn }
    end
    return { items = items }
end

-- ---- evaluator ----

eval_slice = function(toks)
    if #toks == 0 then return 0 end
    return run_tokens(toks)
end

local function strip_negation(toks)
    local i = 1
    while toks[i] and toks[i].type == "blank" do i = i + 1 end
    local t = toks[i]
    if is_literal_word(t, "!") then
        local rest = {}
        for k = i + 1, #toks do rest[#rest + 1] = toks[k] end
        return true, rest
    end
    return false, toks
end

local function eval_simple(node)
    local negate, toks = strip_negation(node.toks)
    -- A command that "!" negates only has its status turned around, so "set
    -- -e" does not act on it (POSIX), and neither on the commands it calls.
    local status
    if negate then
        status = SET_OPTIONS.hold(eval_slice, toks)
    else
        status = eval_slice(toks)
    end
    if negate then
        status = (status == 0) and 1 or 0
        SHELL.status = status
        vars.set_status(status)
    end
    return status
end

local function eval_group(node)
    return eval_block(node.body)
end

local function eval_function(node)
    FUNCTIONS[node.name] = node
    return 0
end

local function eval_if(node)
    for _, br in ipairs(node.branches) do
        -- The condition of "if" and "elif" only has its status tested, so
        -- "set -e" does not act on it (POSIX).
        if SET_OPTIONS.hold(eval_slice, br.cond) == 0 then
            return eval_block(br.body)
        end
    end
    if node.else_ then return eval_block(node.else_) end
    return 0
end

-- Run a loop body once, translating break/continue into a signal.
local function eval_loop_body(body)
    local status = 0
    local ok, err = pcall(function() status = eval_block(body) end)
    if ok then return nil, status end
    if type(err) == "table" then
        if err.__ush_break then return "break", status end
        if err.__ush_continue then return "continue", status end
    end
    error(err, 0)
end

local function eval_while(node)
    local status = 0
    local iterations = 0
    while true do
        -- The condition of "while" and "until" only has its status tested, so
        -- "set -e" does not act on it (POSIX).
        local cond = SET_OPTIONS.hold(eval_slice, node.cond)
        local run = (cond == 0)
        if node.until_ then run = not run end
        if not run then break end

        iterations = iterations + 1
        if iterations > MAX_LOOP_ITERATIONS then
            write_stdout("ush: loop: stopped after " ..
                         tostring(MAX_LOOP_ITERATIONS) .. " iterations")
            return 1
        end

        local signal, st = eval_loop_body(node.body)
        status = st
        if signal == "break" then break end
    end
    return status
end

-- The words of a "for" list: expanded (and globbed) like the arguments of a
-- command would be. A failing "${VAR:?word}" returns nil, the caller then ends
-- the loop with a non zero status.
local function word_list(toks)
    if toks == nil then return params.all() end
    local stages, why = build_stages(toks, true)
    if stages == nil then
        write_stdout("ush: " .. tostring(why))
        return nil
    end
    if #stages == 0 then return {} end
    local out = {}
    for _, w in ipairs(stages[1].words) do out[#out + 1] = w end
    return out
end

local function eval_for(node)
    local words = word_list(node.list)
    if words == nil then return 1 end
    local status = 0
    for idx, w in ipairs(words) do
        if idx > MAX_LOOP_ITERATIONS then
            write_stdout("ush: loop: stopped after " ..
                         tostring(MAX_LOOP_ITERATIONS) .. " iterations")
            return 1
        end
        vars.set(node.name, w)
        local signal, st = eval_loop_body(node.body)
        status = st
        if signal == "break" then break end
    end
    return status
end

-- Pattern text of a case arm: variables expand, blanks between the tokens are
-- dropped ("a b)" is the pattern "ab").
local function pattern_text(toks)
    local buf = {}
    for _, t in ipairs(toks) do
        if t.type == "word" then
            buf[#buf + 1] = expand_plain(t.segs)
        end
    end
    return table.concat(buf)
end

-- Case patterns are matched with the same wildcard engine as filename
-- expansion: "*", "?" and "[...]".
local function pattern_matches(pattern, text)
    local glob = require("glob")
    if glob.match then
        -- lib/glob.lua takes the subject first and the pattern second.
        local ok, res = pcall(glob.match, text, pattern)
        if ok and res ~= nil then return res and true or false end
    end
    -- Fall back to a literal comparison when the pattern has no wildcards.
    if not pattern:find("[%*%?%[]") then return pattern == text end
    return false
end

local function eval_case(node)
    local subject = expand_plain(node.subject[1].segs)
    for _, arm in ipairs(node.arms) do
        for _, pat in ipairs(arm.pats) do
            if pattern_matches(pattern_text(pat), subject) then
                return eval_block(arm.body)
            end
        end
    end
    return 0
end

-- "cmd &" on a compound command: hand it to the job table, like run_tokens()
-- does for a simple command.
local function eval_bg(node)
    local cmd = render_tokens(node.toks)
    local job, jerr = jobs.spawn(cmd)
    if job then
        write_stdout("[" .. job.id .. "] " .. tostring(job.command or cmd))
        return 0
    end
    write_stdout("ush: " .. tostring(jerr))
    return 1
end

local eval_node = function(node)
    local kind = node.k
    if kind == "simple" then return eval_simple(node) end
    if kind == "list" or kind == "group" then return eval_group(node) end
    if kind == "if" then return eval_if(node) end
    if kind == "while" then return eval_while(node) end
    if kind == "for" then return eval_for(node) end
    if kind == "case" then return eval_case(node) end
    if kind == "func" then return eval_function(node) end
    if kind == "bg" then return eval_bg(node) end
    error("unknown node kind " .. tostring(kind), 0)
end

-- Evaluate a block: every item runs unless the connector of the item and the
-- status of the previous one say otherwise ("a && b", "a || b").
eval_block = function(block)
    local status = 0
    for _, item in ipairs(block.items) do
        local run = true
        if item.conn == "&&" and status ~= 0 then run = false end
        if item.conn == "||" and status == 0 then run = false end
        if run then
            status = eval_node(item.node)
            SHELL.status = status
            vars.set_status(status)
        end
    end
    return status
end

-- Shell functions run with their own positional parameters, so "$1" inside a
-- function is the first argument of the call and the caller's "$@" is back as
-- soon as the function returns. "return" ends the call with its status.
call_function = function(node, args, stage)
    params.push(node.name, args)
    local status = 0
    local ok, err = pcall(function() status = eval_block(node.body) end)
    params.pop()
    if ok then return status end
    if type(err) == "table" and err.__ush_return then
        return tonumber(err.__ush_return) or 0
    end
    error(err, 0)
end

-- Run a token stream through the control flow layer. Returns the status.
local function run_control(tokens)
    local P = new_parser(tokens)
    local block, err = parse_block(P)
    if not block then
        write_stdout("ush: " .. tostring(err))
        SHELL.status = 2
        vars.set_status(2)
        return 2
    end
    return eval_block(block)
end

-- ============================================================
-- Command substitution: "$(CMD)" and "`CMD`"
-- ============================================================

-- The state a substitution has to put back when it is over: the variables and
-- their export flags, the positional parameters and the working directory.
-- This is what makes a substitution a sub shell - a "cd" or an assignment
-- inside it is gone the moment the reference ends, exactly like in a child
-- process. lib/cwd.lua itself is never touched: the substitution walks in and
-- out of the directory it borrowed.
local function subshell_enter()
    local snap = { values = {}, flags = {} }
    for _, name in ipairs(vars.names()) do
        snap.values[name] = vars.get(name)
        snap.flags[name] = vars.is_exported(name)
    end
    snap.dir = cwd.get()
    snap.status = vars.get("?")
    snap.shell_status = SHELL.status
    -- The options of "set" are inherited by the sub shell, the ones it turns
    -- on or off inside the reference are not the ones of the shell that opened
    -- it: "(set -e; false)" changes nothing outside the parentheses.
    snap.options = {}
    for _, opt in ipairs(SET_OPTIONS.list) do
        snap.options[opt.name] = SHELL[opt.name]
    end
    -- The commands of the sub shell are its own: a "set -e" held back in the
    -- shell that opened it says nothing about them.
    snap.muted = SET_OPTIONS.muted
    -- A sub shell starts with the default dispositions of the signals, the
    -- traps of the shell that opened it come back when it is over (POSIX).
    snap.traps = trap_frame_enter()
    params.push(params.zero(), params.all())
    return snap
end

local function subshell_leave(snap)
    params.pop()
    cwd.set(snap.dir)
    -- Variables the substitution invented are dropped again, the ones it
    -- changed get their old value and export flag back.
    for _, name in ipairs(vars.names()) do
        if snap.values[name] == nil then vars.unset(name) end
    end
    for name, value in pairs(snap.values) do
        vars.set(name, value)
        vars.set_exported(name, snap.flags[name] and true or false)
    end
    -- "$?" itself is not touched by a substitution; the caller reads the
    -- status of the substitution from cmdsub_status instead.
    vars.set_status(tonumber(snap.status) or 0)
    SHELL.status = snap.shell_status
    for _, opt in ipairs(SET_OPTIONS.list) do
        SHELL[opt.name] = snap.options[opt.name]
    end
    SET_OPTIONS.muted = snap.muted
    trap_frame_leave(snap.traps)
end

-- ============================================================
-- Signals: the trap built-in
-- ============================================================

-- The signals a shell may wait for. CraftOS is single threaded and delivers
-- exactly one of them: holding Ctrl+T makes a blocking call give up with
-- "Terminated", which the shell reports as INT. The other names are accepted
-- so that a script written for a Unix shell still says what it means, they are
-- never raised here; KILL cannot be caught the way POSIX refuses it.
local TRAP_SIGNALS = {
    { name = "HUP",  number = 1 },
    { name = "INT",  number = 2 },
    { name = "QUIT", number = 3 },
    { name = "KILL", number = 9, locked = true },
    { name = "TERM", number = 15 },
    { name = "EXIT", number = 0 },
    { name = "ERR" },
}

-- name -> the text to run when the signal is delivered. An empty string is an
-- ignored signal (POSIX), a name that is missing has its default disposition.
-- A sub shell and a script that runs as a command get a table of their own,
-- so a trap set inside them does not outlive them.
local TRAPS = {}

local trap_by_name, trap_by_number = {}, {}
for _, sig in ipairs(TRAP_SIGNALS) do
    trap_by_name[sig.name] = sig
    if sig.number then trap_by_number[sig.number] = sig end
end

-- A trap that is running must not be re-entered by a signal it causes itself.
local trap_guard = false

-- "INT", "int", "SIGINT" and "2" all name the same signal; nil for a name the
-- shell does not know.
local function trap_signal_of(word)
    if word == nil then return nil end
    local text = tostring(word)
    local number = tonumber(text)
    if number then
        return trap_by_number[math.floor(number)]
    end
    text = text:upper()
    if #text > 3 and text:sub(1, 3) == "SIG" then text = text:sub(4) end
    return trap_by_name[text]
end

-- A trap text in the shape it can be handed back to the shell: one single
-- quoted word, with a quote inside the text escaped the POSIX way.
local function trap_quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- One trap as "trap" and "trap -p" print it, ready to be run again.
local function trap_line(name, text)
    if text == "" then return "trap -- '' " .. name end
    return "trap -- " .. trap_quote(text) .. " " .. name
end

-- Run the trap of one signal. The text goes back through the parser, so a trap
-- may hold a whole command list. A trap that fails is reported and the status
-- the shell was in stands. The status of a trap of EXIT replaces the status of
-- the shell that is leaving; an exit inside any other trap only ends the trap.
local function trap_run(name, status)
    status = tonumber(status) or 0
    local text = TRAPS[name]
    if text == nil or text == "" or trap_guard then return status end
    -- A trap of EXIT runs once, a second exit has nothing left to run.
    if name == "EXIT" then TRAPS[name] = nil end
    trap_guard = true
    local ok, err = pcall(run_control, tokenize(text))
    trap_guard = false
    if ok then return status end
    if type(err) == "table" and err.__ush_exit then
        if name ~= "EXIT" then return status end
        local code = tonumber(err.__ush_exit) or 0
        SHELL.status = code
        vars.set_status(code)
        return code
    end
    write_stdout("ush: trap: " .. tostring(err))
    return status
end

-- A signal of the shell was delivered. The caller keeps the status it was
-- given unless the trap of EXIT asked for another one.
trap_fire = function(name, status)
    return trap_run(name, status)
end

-- The shell is about to leave: its trap of EXIT runs once with the status the
-- shell is about to exit with.
trap_run_exit = function(status)
    return trap_run("EXIT", status)
end

-- A sub shell starts with the default dispositions (POSIX) and gets the traps
-- of the shell that opened it back when it is over. The caller keeps the table
-- it gets here and hands it back to trap_frame_leave().
trap_frame_enter = function()
    local saved = TRAPS
    TRAPS = {}
    return saved
end

trap_frame_leave = function(saved)
    if saved then TRAPS = saved end
end

-- True when the error of a pcall is the one CraftOS raises when the user holds
-- Ctrl+T: every blocking call gives up with "Terminated". This is the moment a
-- running command tells the shell that it was asked to stop.
is_interrupt_error = function(err)
    if type(err) ~= "string" then return false end
    return err:find("Terminated", 1, true) ~= nil or
           err:find("Interrupted", 1, true) ~= nil
end

-- Run the command of a "$(CMD)" or "`CMD`" reference and return what it wrote
-- on the standard output, with the trailing newlines taken off (POSIX).
--
-- The standard output of the command is collected in a buffer instead of the
-- console, so a substitution can be used in the middle of a command line. CMD
-- is a whole command line of its own: it may hold a pipeline, a list, a loop
-- or another substitution, which is how nesting works. A failure to parse CMD
-- is reported like any other syntax error, its status travels back through
-- cmdsub_status so that "$(false)" and "x=$(false)" both fail.
cmdsub_run = function(text)
    local tokens = tokenize(text)
    local buf = capture_push()
    local snap = subshell_enter()
    local ok, status = pcall(run_control, tokens)
    if not ok then
        if type(status) == "table" then
            -- "exit" inside the substitution only ends the sub shell: its code
            -- becomes the status of the substitution, the shell lives on.
            status = tonumber(status.__ush_exit or status.__ush_return) or 0
        else
            write_stdout("ush: " .. tostring(status))
            status = 1
        end
    end
    -- The sub shell is over: its trap of EXIT runs while what it writes still
    -- belongs to the substitution, and the traps of the shell come back. The
    -- status of the substitution is the status the sub shell left with.
    status = trap_run_exit(status)
    capture_pop()
    subshell_leave(snap)
    cmdsub_status = tonumber(status) or 0
    -- The line ends where the shell's output ends: every newline at the end of
    -- the captured text is dropped, the ones in the middle are kept.
    return (table.concat(buf.chunks):gsub("\n+$", ""))
end

-- Read a script file as one piece of text. Control flow spans lines, so a
-- script is tokenized as a whole instead of line by line.
read_script_text = function(path)
    if not fs.exists(path) or fs.isDir(path) then
        return nil, "no such file or directory"
    end
    local handle = fs.open(path, "r")
    if not handle then return nil, "cannot open" end
    local data = handle.readAll()
    handle.close()
    return (tostring(data or ""):gsub("\r", ""))
end

-- A shell script may name its interpreter on the first line:
--   #!/usr/bin/env ush
--   #!/bin/ush
-- For the tokenizer a shebang is an ordinary comment, so such a script would
-- run anyway. The interpreter is still checked, so that a script written for
-- a different shell fails with a clear message instead of quietly doing the
-- wrong thing.
local USH_INTERPRETERS = { ["ush"] = true, ["ush.lua"] = true, ["cc"] = true }

local function script_interpreter(text)
    local first = text:match("^#!([^\n]*)")
    if not first then return nil end
    local words = {}
    for w in first:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return nil end
    local raw = words[1]
    local base = raw:match("([^/\\]+)$") or raw
    if base == "env" then
        -- "#!/usr/bin/env ush" and "#!/usr/bin/env -S ush -x".
        for k = 2, #words do
            local w = words[k]
            if w:sub(1, 1) ~= "-" then
                base = w:match("([^/\\]+)$") or w
                break
            end
        end
    end
    return base, raw
end

local function check_interpreter(text)
    local base, raw = script_interpreter(text)
    if base == nil then return true end
    if USH_INTERPRETERS[base] then return true end
    return false, "unsupported interpreter '" .. tostring(raw) .. "'"
end

-- Run script text with its own positional parameters.
--   opts.isolate - the script behaves like a separate process: "exit" ends the
--                  script and its code becomes the status instead of leaving
--                  the interactive shell.
--   opts.quiet   - do not report a missing file (used by the startup files).
run_script_text = function(text, name, args, opts)
    opts = opts or {}

    local okinterp, ierr = check_interpreter(text)
    if not okinterp then
        write_stdout("ush: " .. tostring(name) .. ": " .. tostring(ierr))
        SHELL.status = 126
        vars.set_status(126)
        return 126
    end

    -- A script that runs as a command behaves like a shell of its own: it
    -- starts with the default dispositions and it runs its own trap of EXIT
    -- when it is over. A sourced script is a part of this shell, it keeps the
    -- traps of the shell and starts with none of its own.
    local saved_traps = nil
    local saved_options = nil
    if opts.isolate then
        saved_traps = trap_frame_enter()
        -- A command script is a shell of its own: it inherits the options of
        -- "set" and the ones it turns on or off inside die with it, the way
        -- they do in a child process.
        saved_options = {}
        for _, opt in ipairs(SET_OPTIONS.list) do
            -- A PERSISTENT option is not restored here: its authority is the file
            -- it is recorded in (/etc/boot.conf), not the in-memory flag, and a
            -- script that turned the guard off as root must not have it silently
            -- turned back on at the end of the script -- the operator's later
            -- writes would start failing for a reason nothing explains.
            if not opt.persistent then
                saved_options[opt.name] = SHELL[opt.name]
            end
        end
    end

    params.push(name, args or {})
    local ok, err = pcall(run_control, tokenize(text))
    params.pop()

    local code, report = nil, nil
    if ok then
        code = SHELL.status
    elseif type(err) == "table" then
        if err.__ush_exit then
            code = tonumber(err.__ush_exit) or 0
            -- A sourced script is part of this shell, so "exit" leaves the
            -- shell; a script run as a command only returns its status.
            if not opts.isolate then EXIT_REQUEST = code end
        elseif err.__ush_return then
            code = tonumber(err.__ush_return) or 0
        end
    end
    if code == nil then
        if is_interrupt_error(err) then
            -- Ctrl+T stopped the script: its trap of INT runs and the status
            -- becomes the one of a command that was interrupted.
            code = trap_fire("INT", 130)
        else
            report = tostring(err)
            code = 1
        end
    end
    if report and not opts.quiet then
        write_stdout("ush: " .. report)
    end
    if saved_traps ~= nil then
        -- The command script leaves: its trap of EXIT runs with the status the
        -- script ended with, then the traps of the shell come back.
        code = trap_run_exit(code)
        trap_frame_leave(saved_traps)
    end
    if saved_options then
        for _, opt in ipairs(SET_OPTIONS.list) do
            -- Persistent options were never saved (see above): their state lives
            -- in /etc/boot.conf and outlives the script on purpose.
            if not opt.persistent then
                SHELL[opt.name] = saved_options[opt.name]
            end
        end
    end
    SHELL.status = code
    vars.set_status(code)
    return code
end

-- A file that is not named "*.sh"/"*.ush" can still be a script: what decides
-- is the interpreter named on its first line. Files that are Lua commands by
-- extension are never probed, so ordinary commands keep their current cost.
is_ush_script_file = function(path)
    if type(path) ~= "string" or path:match("%.lua$") then return false end
    if not fs.exists(path) or fs.isDir(path) then return false end
    local handle = fs.open(path, "r")
    if not handle then return false end
    local first = handle.readLine()
    handle.close()
    local base = script_interpreter(tostring(first or ""))
    return base ~= nil and USH_INTERPRETERS[base] == true
end

-- Run the text of a script file. Returns the status of the last command, or
-- the status of "exit"/"return" when the script ends that way. Used by
-- "source" and by the startup files.
local function run_script_file(path, quiet, args)
    local text, rerr = read_script_text(path)
    if not text then
        if quiet then return 0 end
        write_stdout("source: " .. path .. ": " .. tostring(rerr))
        return 1
    end
    return run_script_text(text, path, args or {}, { quiet = quiet })
end

local function run(line)
    if type(line) ~= "string" then return SHELL.status end
    line = line:gsub("\r", "")
    EXIT_REQUEST = nil
    -- While this line runs, Ctrl+C means "stop the command" (lib/interrupt.lua).
    -- It is marked around the whole line and cleared in every exit path, so the
    -- line editor -- which runs outside run() -- keeps Ctrl+C as "discard this
    -- line". The require is inline rather than a top-level local because this
    -- file is at Lua's 200-local ceiling in the main chunk.
    local intr = require("interrupt")
    intr.begin_command()
    local ok, err = pcall(run_control, tokenize(line))
    intr.end_command()
    if not ok then
        if type(err) == "table" and err.__ush_exit then
            -- "exit" typed at the prompt (or in "ush -c"): leave the shell with
            -- this status. The interactive loop reads EXIT_REQUEST.
            EXIT_REQUEST = tonumber(err.__ush_exit) or 0
            SHELL.status = EXIT_REQUEST
        elseif type(err) == "table" and
               (err.__ush_return or err.__ush_break or err.__ush_continue) then
            local what = "return"
            if err.__ush_break then what = "break" end
            if err.__ush_continue then what = "continue" end
            write_stdout("ush: " .. what .. ": not inside a loop or function")
            SHELL.status = 1
        elseif is_interrupt_error(err) then
            -- Ctrl+T reached the shell itself while the line was running, the
            -- way an interrupt arrives between two commands of a list: the
            -- trap of INT runs and the shell keeps on running.
            SHELL.status = trap_fire("INT", 130)
        else
            write_stdout("ush: " .. tostring(err))
            -- A command that raised is a command that FAILED, and the status has
            -- to say so: without this line "$?" still answered whatever ran
            -- before the crash, so a script could not tell that its line had
            -- died. Measured on a real machine: after a crash the next
            -- "echo $?" printed 0. The interrupt above keeps its 130, and
            -- "exit"/"return"/"break"/"continue" keep their own statuses.
            SHELL.status = 1
        end
    end
    vars.set_status(SHELL.status)
    return SHELL.status
end

-- ============================================================
-- Built-in commands
-- ============================================================

-- ---- Signals ----
-- trap                    the traps of the shell, one line for each
-- trap -p [SIGNAL ...]    the trap of a signal, in a form that can be run again
-- trap 'CMD' SIGNAL ...   run CMD when the signal is delivered
-- trap '' SIGNAL ...      ignore the signal
-- trap - SIGNAL ...       put the default disposition of the signal back
--
-- A trap is carried by the shell that set it: a sub shell and a command script
-- start with the default dispositions and their own traps die with them. The
-- trap of EXIT runs when the shell leaves, with the status it leaves with.
BUILTINS["trap"] = function(args, stage)
    local action, reset, print_only = nil, false, false
    local names = {}
    -- The words in front of the action: "trap -p" asks for the listing and
    -- "trap -" puts the dispositions back. "trap --" ends the options, so that
    -- an action which starts with a dash, as the one "trap -p" writes, is
    -- still read as the action.
    local first = 1
    if args[first] == "-p" then
        print_only = true
        first = first + 1
    end
    if args[first] == "--" then
        first = first + 1
    elseif args[first] == "-" and not print_only then
        reset = true
        first = first + 1
    end
    -- The word behind the options is the action of the trap, the words behind
    -- it are the signals it is set for. With "-" there is no action at all.
    if not reset and not print_only then
        action = args[first]
        first = first + 1
    end
    for idx = first, #args do names[#names + 1] = args[idx] end

    -- The listing: "trap" and "trap -p" with no signal name show every trap
    -- that is set, "trap -p SIGNAL" shows the trap of one signal.
    if print_only or (action == nil and not reset and #names == 0) then
        local wanted = names
        if #wanted == 0 then
            wanted = {}
            for _, sig in ipairs(TRAP_SIGNALS) do wanted[#wanted + 1] = sig.name end
        end
        local lines = {}
        for _, word in ipairs(wanted) do
            local sig = trap_signal_of(word)
            if not sig then
                emit(stage, "ush: trap: " .. word ..
                     ": invalid signal specification")
                return 1
            end
            local text = TRAPS[sig.name]
            if text ~= nil then
                lines[#lines + 1] = trap_line(sig.name, text)
            end
        end
        if #lines > 0 then emit(stage, table.concat(lines, "\n")) end
        return 0
    end

    -- "trap SIGNAL" with no action is a usage fault, the action comes first.
    if action == nil and not reset then
        emit(stage, "ush: trap: usage: trap [-p] [ACTION] SIGNAL ...")
        return 1
    end

    -- "trap -" with no signal name puts every disposition back.
    if reset and #names == 0 then
        TRAPS = {}
        return 0
    end

    if #names == 0 then
        emit(stage, "ush: trap: usage: trap [-p] [ACTION] SIGNAL ...")
        return 1
    end

    -- Every name has to be known, and none of them may be locked, before
    -- anything is changed.
    local chosen = {}
    for _, word in ipairs(names) do
        local sig = trap_signal_of(word)
        if not sig then
            emit(stage, "ush: trap: " .. word ..
                 ": invalid signal specification")
            return 1
        end
        chosen[#chosen + 1] = sig
    end
    for _, sig in ipairs(chosen) do
        if sig.locked then
            -- POSIX: KILL may never be caught, ignored or reset.
            emit(stage, "ush: trap: " .. sig.name .. ": cannot be caught")
            return 1
        end
    end

    -- "-" puts the default disposition back: the entry goes away, which is
    -- not the same as an ignored signal, whose action is the empty text. Any
    -- other action is kept as it was typed and read again when the signal
    -- comes, so a trap may hold a whole command list.
    for _, sig in ipairs(chosen) do
        if reset then
            TRAPS[sig.name] = nil
        else
            TRAPS[sig.name] = action
        end
    end
    return 0
end

-- ---- Directory ----
BUILTINS["ls"] = function(args, stage)
    local show_all, show_long = false, false
    local paths = {}
    for _, a in ipairs(args) do
        if a == "-a" then show_all = true
        elseif a == "-l" then show_long = true
        elseif a == "-la" or a == "-al" then show_all, show_long = true, true
        else table.insert(paths, a) end
    end
    if #paths == 0 then paths = { cwd.get() } end

    local function list_one(spec)
        local p = resolve_path(spec)
        if not fs.exists(p) then
            emit(stage, "ls: " .. spec .. ": no such file or directory")
            return
        end
        if not fs.isDir(p) then
            -- "ls *.lua" must list the matched files instead of nothing.
            if show_long then
                local rec = perm.get_mode(p)
                local mode = rec and rec.mode or "rw-r--r--"
                local owner = rec and rec.owner or "root"
                emit(stage, "-" .. mode .. "  1  " .. owner ..
                     string.format("  %8d  ", fs.getSize(p) or 0) .. spec)
            else
                emit(stage, p:match("[^/]*$") or spec)
            end
            return
        end
        for _, name in ipairs(fs.list(p)) do
            if show_all or name:sub(1,1) ~= "." then
                local full = (p == "/" and "/" or p .. "/") .. name
                if show_long then
                    local rec = perm.get_mode(full)
                    local mode = rec and rec.mode or "rw-r--r--"
                    local owner = rec and rec.owner or "root"
                    local kind = fs.isDir(full) and "d" or "-"
                    local size = fs.isDir(full) and 0 or (fs.getSize(full) or 0)
                    emit(stage, kind .. mode .. "  1  " .. owner ..
                         string.format("  %8d  ", size) .. name)
                else
                    emit(stage, name)
                end
            end
        end
    end
    for _, p in ipairs(paths) do list_one(p) end
end

-- pwd prints the logical path, so a directory reached through a mount shows
-- the mount point the user typed instead of the physical /disk behind it.
BUILTINS["pwd"] = function(args, stage) emit(stage, display_path(cwd.get())) end

BUILTINS["cd"] = function(args, stage)
    local target = args[1] or "/"
    local path = resolve_path(target)
    if not fs.exists(path) then
        emit(stage, "cd: " .. target .. ": no such file or directory")
        return 1
    end
    if not fs.isDir(path) then
        emit(stage, "cd: " .. target .. ": not a directory")
        return 1
    end
    local ok, err = cwd.set(path)
    if not ok then
        emit(stage, "cd: " .. target .. ": " .. tostring(err))
        return 1
    end
    vars.set("PWD", display_path(cwd.get()))
    if shell and shell.setDir then shell.setDir(cwd.get()) end
end

BUILTINS["mkdir"] = function(args, stage)
    local parents = false
    local status = 0
    for _, a in ipairs(args) do
        if a == "-p" then
            parents = true
        else
            local p = resolve_path(a)
            local made = true
            if not guard_write(cwd.resolve(a), stage) then
                status = 1
                made = false
            elseif not perm.can_write(p) then
                emit(stage, "mkdir: " .. a .. ": permission denied")
                status = 1
                made = false
            else
                -- fs.makeDir answers NOTHING on this platform even when it
                -- works (measured: it returns nil on a real machine), so its
                -- return value says not one word about success or failure. The
                -- only honest check is to ask whether the directory is there
                -- now; before this, a guarded makeDir created nothing and
                -- mkdir still reported status 0.
                if parents then
                    local parts = {}
                    for seg in p:gmatch("[^/]+") do table.insert(parts, seg) end
                    local acc = ""
                    for _, seg in ipairs(parts) do
                        acc = acc .. "/" .. seg
                        if not fs.exists(acc) then
                            fs.makeDir(acc)
                            if not fs.exists(acc) then
                                emit(stage, "mkdir: " .. a ..
                                     ": cannot create directory")
                                status = 1
                                made = false
                                break
                            end
                        end
                    end
                else
                    fs.makeDir(p)
                    if not fs.exists(p) then
                        emit(stage, "mkdir: " .. a ..
                             ": cannot create directory")
                        status = 1
                        made = false
                    end
                end
            end
            if made and not perm.get_mode(p) then
                perm.set_mode(p, "rwxr-xr-x")
            end
        end
    end
    return status
end

BUILTINS["rmdir"] = function(args, stage)
    local status = 0
    for _, a in ipairs(args) do
        local p = resolve_path(a)
        if not guard_write(p, stage) then
            status = 1
        elseif fs.isDir(p) then
            if #fs.list(p) == 0 then
                fs.delete(p)
                perm.remove(p)
            else
                emit(stage, "rmdir: " .. a .. ": directory not empty")
                status = 1
            end
        else
            emit(stage, "rmdir: " .. a .. ": not a directory")
            status = 1
        end
    end
    return status
end

-- ---- File ----
BUILTINS["cat"] = function(args, stage)
    local numbered = false
    local files = {}
    for _, a in ipairs(args) do
        if a == "-n" then numbered = true else table.insert(files, a) end
    end
    local n = 0
    local status = 0
    local function out(line)
        n = n + 1
        if numbered then emit(stage, string.format("%6d\t%s", n, line))
        else emit(stage, line) end
    end
    if #files == 0 then
        for _, line in ipairs(read_lines(stage)) do out(line) end
    else
        for _, a in ipairs(files) do
            local p = resolve_path(a)
            if not perm.can_read(p) then
                emit(stage, "cat: " .. p .. ": permission denied")
                status = 1
            else
                local f = fs.open(p, "r")
                if f then
                    for line in f.readLine do out(line) end
                    f.close()
                elseif fs.isDir(p) then
                    emit(stage, "cat: " .. p .. ": is a directory")
                    status = 1
                elseif fs.exists(p) then
                    -- The file IS there and cannot be opened: that is a refusal
                    -- (the shadow file for an ordinary account, a read-only
                    -- medium), and calling it "no such file" sent the operator
                    -- looking for a file that exists. Measured on the guarded
                    -- machine, where fs.open answers nil for both cases.
                    emit(stage, "cat: " .. p .. ": permission denied")
                    status = 1
                else
                    emit(stage, "cat: " .. p .. ": no such file")
                    status = 1
                end
            end
        end
    end
    return status
end

BUILTINS["cp"] = function(args, stage)
    local recursive = false
    local srcs, dst = {}, nil
    for i, a in ipairs(args) do
        if a == "-r" or a == "-R" then recursive = true
        elseif i == #args then dst = a
        else table.insert(srcs, a) end
    end
    -- A copy that did not happen must be reported as a failure. The guards below
    -- (permission, boot guard) can each refuse, and returning without a status
    -- made "cp" report success for a file it never wrote -- which a script would
    -- then build on.
    local failed = false
    -- Room for the whole copy, asked once before the first byte is written. A
    -- tree that does not fit must not leave half of itself behind: the per-file
    -- check inside copy() would only notice on the file that runs out, by which
    -- time the earlier files are on the disk. The total is a whole tree's
    -- (space.need_tree says why that name exists). A source whose size cannot be
    -- measured skips this and relies on the per-file check.
    local space_api = require("space")
    local total = 0
    for _, s in ipairs(srcs) do
        local bytes = space_api.size(resolve_path(s))
        if bytes == nil then total = nil break end
        total = total + bytes
    end
    if total and total > 0 then
        local room, why = space_api.need_tree(target_dir, total)
        if not room then
            emit(stage, "cp: " .. tostring(dst) .. ": " .. why)
            return 1
        end
    end
    local function copy(src, d, logical)
        if not perm.can_read(src) then
            emit(stage, "cp: " .. src .. ": permission denied")
            failed = true
            return
        end
        if not guard_write(logical, stage) then
            failed = true
            return
        end
        if fs.isDir(src) then
            if not recursive then return end
            if not fs.exists(d) then fs.makeDir(d) end
            for _, f in ipairs(fs.list(src)) do
                copy(src .. "/" .. f, d .. "/" .. f, logical .. "/" .. f)
            end
        else
            -- The preflight above covers the ordinary case; this is the last line
            -- of defence for a copy whose total could not be measured, and it also
            -- catches a disk that filled up while the tree was being walked.
            local room, why = space_api.need(d, fs.getSize(src) or 0)
            if not room then
                emit(stage, "cp: " .. d .. ": " .. why)
                failed = true
                return
            end
            -- fs.copy returns NOTHING on success on the real ROM (measured on
            -- CraftOS-PC 2.8.3: pcall(fs.copy, a, b) is true and its value nil),
            -- while the test stub returns true. "if not fs.copy(...)" therefore
            -- made every successful copy on a real machine report status 1 --
            -- the stub was more permissive than the hardware again. It also
            -- RAISES when the destination exists, so a failure is caught here and
            -- printed instead of unwinding out of the shell.
            local copied, copy_err = pcall(fs.copy, src, d)
            if not copied then
                emit(stage, "cp: " .. d .. ": " .. tostring(copy_err))
                failed = true
                return
            end
            if not perm.get_mode(d) then perm.set_mode(d, "rw-r--r--") end
        end
    end
    local target_dir = resolve_path(dst)
    local target_logical = cwd.resolve(dst)
    for _, s in ipairs(srcs) do copy(resolve_path(s), target_dir, target_logical) end
    return failed and 1 or 0
end

BUILTINS["mv"] = function(args, stage)
    if #args ~= 2 then emit(stage, "usage: mv <src> <dst>") return 1 end
    local src, dst = resolve_path(args[1]), resolve_path(args[2])
    if not guard_write(cwd.resolve(args[1]), stage) or
       not guard_write(cwd.resolve(args[2]), stage) then
        return 1
    end
    if not fs.exists(src) then
        emit(stage, "mv: " .. args[1] .. ": no such file or directory")
        return 1
    end
    fs.move(src, dst)
    local rec = perm.get_mode(src)
    if rec then
        perm.set_mode(dst, rec.mode, rec.owner, rec.group)
        perm.remove(src)
    end
    return 0
end

BUILTINS["rm"] = function(args, stage)
    local recursive, force = false, false
    local targets = {}
    for _, a in ipairs(args) do
        if a == "-r" or a == "-R" then recursive = true
        elseif a == "-f" then force = true
        elseif a == "-rf" or a == "-fr" then recursive, force = true, true
        else table.insert(targets, a) end
    end
    local status = 0
    local function rm(p, logical)
        if not fs.exists(p) then
            if not force then emit(stage, "rm: " .. p .. ": no such file") end
            status = 1
            return
        end
        if not guard_write(logical or p, stage) then
            status = 1
            return
        end
        if not perm.can_write(p) then
            emit(stage, "rm: " .. p .. ": permission denied"); status = 1
            return
        end
        if fs.isDir(p) then
            if not recursive then
                emit(stage, "rm: " .. p .. ": is a directory"); status = 1
                return
            end
            for _, f in ipairs(fs.list(p)) do
                rm(p .. "/" .. f, (logical or p) .. "/" .. f)
            end
        end
        fs.delete(p)
        perm.remove(p)
    end
    for _, t in ipairs(targets) do rm(resolve_path(t), cwd.resolve(t)) end
    return status
end

BUILTINS["touch"] = function(args, stage)
    local status = 0
    for _, a in ipairs(args) do
        local p = resolve_path(a)
        if not guard_write(cwd.resolve(a), stage) then
            status = 1
        elseif not perm.can_write(p) then
            -- Asked BEFORE the open. The permission database (and the OS level
            -- guard that wraps the fs table under it) refuses this path for this
            -- account, and the answer an operator can act on is "permission
            -- denied". Without this step the built-in walked straight into the
            -- open and indexed the nil it got back: measured on a real machine,
            -- "touch /usr/x" as an ordinary account died with
            -- "attempt to index local 'f'".
            emit(stage, "touch: " .. a .. ": permission denied")
            status = 1
        elseif not fs.exists(p) then
            local f = fs.open(p, "w")
            if not f then
                -- Something below the shell can still refuse the open (a full
                -- file system, a medium that went read-only). That is a failed
                -- command, not a crash: the line must reach its status.
                emit(stage, "touch: " .. a .. ": cannot create file")
                status = 1
            else
                f.close()
                perm.set_mode(p, "rw-r--r--")
            end
        end
    end
    return status
end

BUILTINS["ln"] = function(args, stage)
    if #args < 2 then emit(stage, "usage: ln <src> <dst>") return 1 end
    if not guard_write(cwd.resolve(args[2]), stage) then return 1 end
    local src, dst = resolve_path(args[1]), resolve_path(args[2])
    -- This "link" is a byte copy on CraftOS, so it needs the same room as cp.
    local room, why = require("space").need(dst, fs.getSize(src) or 0)
    if not room then
        emit(stage, "ln: " .. tostring(args[2]) .. ": " .. why)
        return 1
    end
    fs.copy(src, dst)
    return 0
end

-- ---- Text processing ----
--
-- The second batch is the text filter family: grep, sed, awk, sort, uniq, cut,
-- tr, head, tail, wc, tee and xargs. Every command reads the stage input when
-- no file operand is given, so all of them compose with the pipes,
-- redirections, globs, variables and control flow of the earlier batches in
-- exactly the same way as the commands of the first batch.
--
-- The heavy machinery lives in library modules: lib/regex.lua (the regular
-- expression engine), lib/sed.lua (the sed subset) and lib/awk.lua (the awk
-- subset). The small helpers shared by the built-ins are grouped in the local
-- table TP, so the chunk does not need a dozen extra local slots.

local TP = {}
TP.regex = require("regex")
TP.sed = require("sed")
TP.awk = require("awk")

-- Reads a file as one string; nil when it cannot be opened.
function TP.read(path)
    local h = fs.open(path, "r")
    if not h then return nil end
    local text = h.readAll()
    h.close()
    return text
end

-- Splits a text on "\n". A trailing newline does not produce a final empty
-- line, the way a text file reader behaves.
function TP.lines(text)
    local lines = {}
    if text == nil or text == "" then return lines end
    local pos = 1
    while pos <= #text do
        local stop = text:find("\n", pos, true)
        if stop then
            lines[#lines + 1] = text:sub(pos, stop - 1)
            pos = stop + 1
        else
            lines[#lines + 1] = text:sub(pos)
            pos = #text + 1
        end
    end
    return lines
end

-- Splits a line into fields. A nil or empty separator means "runs of blanks",
-- a string separator is matched literally.
function TP.fields(line, sep)
    local parts = {}
    if sep == nil or sep == "" then
        for word in line:gmatch("%S+") do parts[#parts + 1] = word end
        return parts
    end
    local pos = 1
    while true do
        local stop = line:find(sep, pos, true)
        if not stop then
            parts[#parts + 1] = line:sub(pos)
            return parts
        end
        parts[#parts + 1] = line:sub(pos, stop - 1)
        pos = stop + #sep
    end
end

-- Feeds the callback with the content of every input source, the stage input
-- first when there is no file operand. The callback gets the text and the
-- display name (nil for the stage input). Missing files are reported with the
-- usual "<command>: <path>: no such file" wording and counted.
function TP.each(files, stage, who, fn)
    if #files == 0 then
        fn(read_all(stage) or "", nil)
        return 0
    end
    local missing = 0
    for _, operand in ipairs(files) do
        local path = resolve_path(operand)
        if not perm.can_read(path) then
            emit(stage, who .. ": " .. operand .. ": permission denied")
            missing = missing + 1
        else
            local text = TP.read(path)
            if text == nil then
                emit(stage, who .. ": " .. operand .. ": no such file")
                missing = missing + 1
            else
                fn(text, operand)
            end
        end
    end
    return missing
end

-- The loop of the *sum commands: every operand is handed to FN and the standard
-- input is used when there is no operand at all. An operand that cannot be read
-- is reported the way wc reports it -- a checksum command has no "permission
-- denied" line of its own -- and makes the status 1. FN receives the name nil for
-- the standard input, because cksum prints no name there while sha256sum and
-- md5sum print "-"; only the caller knows which of the two it is.
function TP.digest(files, stage, who, fn)
    if #files == 0 then
        fn(read_all(stage) or "", nil)
        return 0
    end
    local status = 0
    for _, operand in ipairs(files) do
        local path = resolve_path(operand)
        local text = perm.can_read(path) and TP.read(path) or nil
        if text == nil then
            emit(stage, who .. ": " .. operand .. ": no such file")
            status = 1
        else
            fn(text, operand)
        end
    end
    return status
end

-- Parses a GNU style option list. "spec" maps an option letter to "value" when
-- the option takes an argument and to true when it is a plain flag;
-- spec.numeric names the letter a bare "-5" is shorthand for. Values are
-- collected as well ("opt.list") so that a repeated option such as "-v a=1"
-- can keep every occurrence.
function TP.options(spec, args, who, stage)
    local opt = { flags = {}, values = {}, list = {}, operands = {} }
    local numeric = spec.numeric
    local i = 1
    while i <= #args do
        local arg = args[i]
        local bare = numeric and arg:match("^%-(%d+)$")
        if arg == "--" then
            for j = i + 1, #args do opt.operands[#opt.operands + 1] = args[j] end
            break
        elseif bare then
            opt.values[numeric] = bare
            opt.list[numeric] = opt.list[numeric] or {}
            table.insert(opt.list[numeric], bare)
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            local j = 2
            while j <= #arg do
                local letter = arg:sub(j, j)
                local kind = spec[letter]
                if kind == nil then
                    emit(stage, who .. ": invalid option -- '" .. letter .. "'")
                    return nil
                elseif kind == "value" then
                    local inline = arg:sub(j + 1)
                    if inline == "" then
                        i = i + 1
                        inline = args[i]
                    end
                    if inline == nil then
                        emit(stage, who .. ": option requires an argument -- '" ..
                             letter .. "'")
                        return nil
                    end
                    opt.values[letter] = inline
                    opt.list[letter] = opt.list[letter] or {}
                    table.insert(opt.list[letter], inline)
                    j = #arg + 1
                else
                    opt.flags[letter] = true
                    j = j + 1
                end
            end
        else
            opt.operands[#opt.operands + 1] = arg
        end
        i = i + 1
    end
    return opt
end

-- Parses "1,3-5" (cut -f/-c, the key of sort) into a sorted list of numbers.
function TP.numlist(text)
    local list = {}
    for piece in tostring(text):gmatch("[^,]+") do
        local first, last = piece:match("^(%d+)%-(%d+)$")
        if first then
            for value = tonumber(first), tonumber(last) do
                list[#list + 1] = value
            end
        elseif piece:match("^%d+$") then
            list[#list + 1] = tonumber(piece)
        else
            return nil
        end
    end
    if #list == 0 then return nil end
    table.sort(list)
    return list
end

-- Collects every regular file below "root" (grep -r, xargs -r style walk).
function TP.walk(root)
    local found = {}
    local function step(dir)
        local entries = fs.list(dir)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = (dir == "/" and "" or dir) .. "/" .. name
            if fs.isDir(full) then
                step(full)
            else
                found[#found + 1] = full
            end
        end
    end
    step(root)
    return found
end

-- -- head ------------------------------------------------------------------
BUILTINS["head"] = function(args, stage)
    local opt = TP.options({ n = "value", q = true, v = true, numeric = "n" },
                           args, "head", stage)
    if not opt then return 1 end
    local count = 10
    if opt.values.n then
        count = tonumber(opt.values.n)
        if not count then
            emit(stage, "head: invalid number of lines: '" .. opt.values.n .. "'")
            return 1
        end
    end
    local files = opt.operands
    local names = #files > 1 or opt.flags.v == true
    if opt.flags.q then names = false end
    local first = true
    TP.each(files, stage, "head", function(text, name)
        if names and name then
            if not first then emit(stage, "") end
            first = false
            emit(stage, "==> " .. name .. " <==")
        end
        local lines = TP.lines(text)
        for i = 1, math.min(count, #lines) do emit(stage, lines[i]) end
    end)
    return 0
end

-- -- tail ------------------------------------------------------------------
BUILTINS["tail"] = function(args, stage)
    local opt = TP.options({ n = "value", q = true, v = true, numeric = "n" },
                           args, "tail", stage)
    if not opt then return 1 end
    local count, from_start = 10, false
    if opt.values.n then
        local raw = opt.values.n
        local plus = raw:match("^%+(%d+)$")
        if plus then
            count, from_start = tonumber(plus), true
        else
            local plain = raw:match("^%-(%d+)$") or raw:match("^(%d+)$")
            if not plain then
                emit(stage, "tail: invalid number of lines: '" .. raw .. "'")
                return 1
            end
            count = tonumber(plain)
        end
    end
    local files = opt.operands
    local names = #files > 1 or opt.flags.v == true
    if opt.flags.q then names = false end
    local first = true
    TP.each(files, stage, "tail", function(text, name)
        if names and name then
            if not first then emit(stage, "") end
            first = false
            emit(stage, "==> " .. name .. " <==")
        end
        local lines = TP.lines(text)
        local start
        if from_start then
            -- "-n +N": start at the Nth line of the input.
            start = math.max(1, math.min(count, #lines + 1))
        else
            start = math.max(1, #lines - count + 1)
        end
        for i = start, #lines do emit(stage, lines[i]) end
    end)
    return 0
end

-- -- wc --------------------------------------------------------------------
BUILTINS["wc"] = function(args, stage)
    local opt = TP.options({ l = true, w = true, c = true }, args, "wc", stage)
    if not opt then return 1 end
    local want_lines = opt.flags.l
    local want_words = opt.flags.w
    local want_chars = opt.flags.c
    local default = not (want_lines or want_words or want_chars)
    local total = { lines = 0, words = 0, chars = 0 }
    local seen = 0

    -- Lines are counted the way the GNU tool counts them for a text file: one
    -- per newline character, so a last line without a newline is not counted.
    local function measure(text)
        local lines = 0
        for _ in text:gmatch("\n") do lines = lines + 1 end
        local words = 0
        for _ in text:gmatch("%S+") do words = words + 1 end
        return lines, words, #text
    end

    local function report(lines, words, chars, name)
        local parts = {}
        if default or want_lines then parts[#parts + 1] = tostring(lines) end
        if default or want_words then parts[#parts + 1] = tostring(words) end
        if default or want_chars then parts[#parts + 1] = tostring(chars) end
        local body = table.concat(parts, " ")
        if name then body = body .. " " .. name end
        emit(stage, body)
    end

    local files = opt.operands
    if #files == 0 then
        local lines, words, chars = measure(read_all(stage) or "")
        report(lines, words, chars, nil)
        return 0
    end
    for _, operand in ipairs(files) do
        local path = resolve_path(operand)
        local text = perm.can_read(path) and TP.read(path) or nil
        if text == nil then
            emit(stage, "wc: " .. operand .. ": no such file")
        else
            local lines, words, chars = measure(text)
            total.lines = total.lines + lines
            total.words = total.words + words
            total.chars = total.chars + chars
            seen = seen + 1
            report(lines, words, chars, operand)
        end
    end
    if seen > 1 then
        report(total.lines, total.words, total.chars, "total")
    end
    return 0
end

-- -- grep ------------------------------------------------------------------
BUILTINS["grep"] = function(args, stage)
    local opt = TP.options({ i = true, v = true, n = true, c = true, l = true,
                             q = true, r = true, E = true, F = true, e = "value" },
                           args, "grep", stage)
    if not opt then return 1 end
    local pattern = opt.values.e
    local files = {}
    if pattern then
        files = opt.operands
    else
        pattern = opt.operands[1]
        for i = 2, #opt.operands do files[#files + 1] = opt.operands[i] end
    end
    if pattern == nil then
        emit(stage, "usage: grep [-ivnclqrEF] PATTERN [FILE...]")
        return 2
    end
    if opt.flags.i then pattern = pattern:lower() end
    local syntax = opt.flags.E and "extended" or "basic"
    if opt.flags.F then
        -- -F is a fixed string, so every character of the pattern is escaped and
        -- the engine can only match it literally. The escaped text is compiled
        -- as EXTENDED, and that is not cosmetic: in basic syntax an escaped
        -- \( \) \+ \? \| is still an operator, so "fgrep 'a+b'" would be read as
        -- "one or more a, then b" and match "aaab" instead of the literal "a+b".
        -- A fixed string has no syntax of its own, so which grammar reads the
        -- escapes is an internal choice that cannot change what the pattern means.
        pattern = TP.regex.escape(pattern)
        syntax = "extended"
    end
    local matcher = TP.regex.compile(pattern, syntax)
    local show_names = #files > 1 and not opt.flags.l

    local function matched(line)
        local subject = opt.flags.i and line:lower() or line
        local hit = matcher:find(subject, 1) ~= nil
        if opt.flags.v then return not hit end
        return hit
    end

    -- Returns true when the source contained at least one selected line.
    local function scan(text, name)
        local lines = TP.lines(text)
        local count = 0
        local label = name or "(standard input)"
        for index = 1, #lines do
            if matched(lines[index]) then
                count = count + 1
                if opt.flags.l then
                    break
                elseif not opt.flags.c and not opt.flags.q then
                    local prefix = ""
                    if show_names then prefix = prefix .. label .. ":" end
                    if opt.flags.n then prefix = prefix .. index .. ":" end
                    emit(stage, prefix .. lines[index])
                end
            end
        end
        if opt.flags.l then
            if count > 0 then emit(stage, label) end
        elseif opt.flags.c then
            if show_names then
                emit(stage, label .. ":" .. count)
            else
                emit(stage, tostring(count))
            end
        end
        return count > 0
    end

    local function scan_path(operand)
        local path = resolve_path(operand)
        if not perm.can_read(path) then
            emit(stage, "grep: " .. operand .. ": permission denied")
            return false
        end
        local text = TP.read(path)
        if text == nil then
            emit(stage, "grep: " .. operand .. ": no such file")
            return false
        end
        return scan(text, operand)
    end

    local found = false
    if #files == 0 and not opt.flags.r then
        found = scan(read_all(stage) or "", nil)
    else
        local targets = files
        if opt.flags.r then
            targets = {}
            if #files == 0 then
                targets[1] = cwd.get()
            else
                for _, operand in ipairs(files) do
                    local path = resolve_path(operand)
                    if fs.isDir(path) then
                        for _, deep in ipairs(TP.walk(path)) do
                            targets[#targets + 1] = deep
                        end
                    else
                        targets[#targets + 1] = operand
                    end
                end
            end
            show_names = #targets > 1 and not opt.flags.l
        end
        for _, operand in ipairs(targets) do
            if scan_path(operand) then found = true end
            if opt.flags.q and found then break end
        end
    end
    if opt.flags.q then
        if found then return 0 end
        return 1
    end
    -- grep reports "no line selected" with status 1 and an error with 2, the
    -- usual convention for a filter used inside a pipeline.
    if found then return 0 end
    return 1
end

-- -- sed -------------------------------------------------------------------
BUILTINS["sed"] = function(args, stage)
    local opt = TP.options({ n = true, i = true, e = "value", E = true,
                             r = true }, args, "sed", stage)
    if not opt then return 1 end
    local script = opt.values.e
    local files = opt.operands
    if script == nil then
        script = opt.operands[1]
        files = {}
        for i = 2, #opt.operands do files[#files + 1] = opt.operands[i] end
    end
    if script == nil then
        emit(stage, "usage: sed [-n] [-i] SCRIPT [FILE...]")
        return 2
    end
    local program, err = TP.sed.compile(script)
    if not program then
        emit(stage, "sed: " .. tostring(err))
        return 2
    end
    local quiet = opt.flags.n == true

    if opt.flags.i then
        if #files == 0 then
            emit(stage, "sed: -i may not be used with the standard input")
            return 2
        end
        for _, operand in ipairs(files) do
            local path = resolve_path(operand)
            if not guard_write(path, stage) then return 1 end
            local text = nil
            if perm.can_read(path) and perm.can_write(path) then
                text = TP.read(path)
            end
            if text == nil then
                emit(stage, "sed: " .. operand .. ": cannot read or write")
                return 1
            end
            local lines = TP.sed.run(program, TP.lines(text), quiet)
            -- The new text is known before the file is truncated, which is the one
            -- case in this file where the preflight can use the real size. A
            -- writeLine also emits the break, so each line costs one more byte.
            local wanted = 0
            for _, line in ipairs(lines) do wanted = wanted + #line + 1 end
            local room, why = require("space").need(path, wanted)
            if not room then
                emit(stage, "sed: " .. operand .. ": " .. why)
                return 1
            end
            local handle = fs.open(path, "w")
            if not handle then
                emit(stage, "sed: " .. operand .. ": cannot write")
                return 1
            end
            for _, line in ipairs(lines) do handle.writeLine(line) end
            handle.close()
        end
        return 0
    end

    local chunks = {}
    if #files == 0 then
        chunks[1] = read_all(stage) or ""
    else
        for _, operand in ipairs(files) do
            local path = resolve_path(operand)
            local text = perm.can_read(path) and TP.read(path) or nil
            if text == nil then
                emit(stage, "sed: " .. operand .. ": no such file")
            else
                chunks[#chunks + 1] = text
            end
        end
    end
    local result = TP.sed.run(program, TP.lines(table.concat(chunks)), quiet)
    for _, line in ipairs(result) do emit(stage, line) end
    return 0
end

-- -- ed --------------------------------------------------------------------
-- A line editor, deliberately the smallest useful subset of ed. Commands are
-- read from the standard input when there is one (a pipe or a here document)
-- and from the console otherwise, so the same session can be scripted and
-- typed. An address is a line number, "$" for the last line or "." for the
-- current one; a bare address moves the current line.
BUILTINS["ed"] = function(args, stage)
    local name = args[1]          -- as typed, used in messages and for "w"
    local path = name and resolve_path(name) or nil
    local lines = {}
    local cur = 0                 -- 0 means "no current line"
    local dirty = false           -- changed since the last successful write
    local status = 0

    -- Load the file when one was named. Nothing is printed: an ed that echoed
    -- the file would bury the first command of a session. A file that is not
    -- there is not an error, it is an empty buffer that "w" creates.
    if path then
        if fs.isDir(path) then
            emit(stage, "ed: " .. name .. ": is a directory")
            return 1
        end
        local handle = nil
        if perm.can_read(path) then handle = fs.open(path, "r") end
        if handle then
            for line in handle.readLine do lines[#lines + 1] = line end
            handle.close()
        elseif fs.exists(path) then
            emit(stage, "ed: " .. name .. ": permission denied")
            return 1
        end
        cur = #lines
    end

    local source = stage and stage._in or nil
    local eof = false
    local function next_line()
        local line
        if source then
            line = source:readLine()
        else
            -- The console editor the shell prompt uses: an interactive ed must
            -- be able to take the same keys (and Ctrl+C) as the prompt line.
            line = safe_read("")
        end
        if line == nil then eof = true end
        return line
    end

    local function invalid()
        if #lines == 0 then emit(stage, "ed: no current line")
        else emit(stage, "ed: invalid address") end
        status = 1
    end

    -- Read the body of a, i and c: lines up to one that holds just ".".
    local function read_body()
        local added = {}
        while true do
            local line = next_line()
            if line == nil or line == "." then return added end
            added[#added + 1] = line
        end
    end

    local function write_buffer(given)
        local target = given or name
        if target == nil or target == "" then
            emit(stage, "ed: no file name (use w FILE)")
            status = 1
            return false
        end
        local target_path = resolve_path(target)
        -- Asked BEFORE the open, the rule touch and mkdir follow as well: a
        -- refusal is a sentence, not the nil handle a bare fs.open() indexes.
        if not perm.can_write(target_path) then
            emit(stage, "ed: " .. target .. ": permission denied")
            status = 1
            return false
        end
        if not guard_write(cwd.resolve(target), stage) then
            status = 1
            return false
        end
        -- The new text is known before the file is truncated, so its size can
        -- be preflighted: a write that cannot fit must be refused, not started.
        local wanted = 0
        for _, line in ipairs(lines) do wanted = wanted + #line + 1 end
        local room, why = require("space").need(target_path, wanted)
        if not room then
            emit(stage, "ed: " .. target .. ": " .. why)
            status = 1
            return false
        end
        local handle = fs.open(target_path, "w")
        if not handle then
            emit(stage, "ed: " .. target .. ": cannot create file")
            status = 1
            return false
        end
        local bytes = 0
        for _, line in ipairs(lines) do
            handle.writeLine(line)
            bytes = bytes + #line + 1
        end
        handle.close()
        name = target
        dirty = false
        emit(stage, tostring(bytes) .. " bytes")
        return true
    end

    local HELP = "a i c d p n = w [FILE] wq q q! h or ?" ..
                 "; an address is N, $ (last) or . (current)"

    while not eof do
        local line = next_line()
        if line == nil then break end
        local text = line:match("^%s*(.-)%s*$")
        if text ~= "" then
            local addr = nil
            local rest = text
            local digits = rest:match("^(%d+)")
            if digits then
                addr = tonumber(digits)
                rest = rest:sub(#digits + 1)
            elseif rest:sub(1, 1) == "$" then
                addr = #lines
                rest = rest:sub(2)
            elseif rest:sub(1, 1) == "." then
                addr = cur
                rest = rest:sub(2)
            end
            rest = rest:match("^%s*(.-)%s*$")
            if rest == "" then
                -- A bare address moves the current line; an empty line does
                -- nothing at all, the way ed treats it.
                if addr ~= nil then
                    if addr < 0 or addr > #lines then invalid()
                    else cur = addr end
                end
            elseif rest:match("^q!") then
                return 0
            elseif rest:match("^wq") then
                local given = rest:match("^wq%s+(.+)$")
                if write_buffer(given) then return 0 end
            else
                local cmd = rest:sub(1, 1)
                local target = addr or cur
                if cmd == "a" then
                    if target < 0 or target > #lines then
                        invalid()
                    else
                        local added = read_body()
                        for j = #added, 1, -1 do
                            table.insert(lines, target + 1, added[j])
                        end
                        if #added > 0 then
                            cur = target + #added
                            dirty = true
                        end
                    end
                elseif cmd == "i" then
                    if target < 0 or target > #lines then
                        invalid()
                    else
                        local added = read_body()
                        local at = target == 0 and 1 or target
                        for j = #added, 1, -1 do
                            table.insert(lines, at, added[j])
                        end
                        if #added > 0 then
                            cur = at + #added - 1
                            dirty = true
                        end
                    end
                elseif cmd == "c" then
                    if target < 1 or target > #lines then
                        invalid()
                    else
                        local added = read_body()
                        table.remove(lines, target)
                        for j = #added, 1, -1 do
                            table.insert(lines, target, added[j])
                        end
                        if #added > 0 then cur = target + #added - 1
                        else cur = math.min(target, #lines) end
                        dirty = true
                    end
                elseif cmd == "d" then
                    if target < 1 or target > #lines then
                        invalid()
                    else
                        table.remove(lines, target)
                        cur = math.min(target, #lines)
                        dirty = true
                    end
                elseif cmd == "p" or cmd == "n" then
                    if target < 1 or target > #lines then
                        invalid()
                    elseif cmd == "p" then
                        emit(stage, lines[target])
                    else
                        emit(stage, tostring(target) .. "\t" .. lines[target])
                    end
                elseif cmd == "=" then
                    if target < 0 or target > #lines then invalid()
                    else emit(stage, tostring(target)) end
                elseif cmd == "w" then
                    write_buffer(rest:match("^w%s+(.+)$"))
                elseif cmd == "q" then
                    if dirty then
                        emit(stage,
                             "ed: warning: buffer modified; use q! to quit")
                        status = 1
                    else
                        return 0
                    end
                elseif cmd == "h" or cmd == "?" then
                    emit(stage, HELP)
                else
                    emit(stage, "ed: unknown command: " .. cmd)
                    status = 1
                end
            end
        end
    end
    return status
end

-- -- awk -------------------------------------------------------------------
BUILTINS["awk"] = function(args, stage)
    local opt = TP.options({ F = "value", v = "value", f = "value" },
                           args, "awk", stage)
    if not opt then return 1 end
    local source = opt.operands[1]
    if source == nil then
        emit(stage, "usage: awk [-F sep] [-v var=value] 'program' [FILE...]")
        return 2
    end
    local program, err = TP.awk.compile(source)
    if not program then
        emit(stage, "awk: " .. tostring(err))
        return 2
    end
    local vars = {}
    for _, assignment in ipairs(opt.list.v or {}) do
        local name, value = assignment:match("^([%w_]+)=(.*)$")
        if not name then
            emit(stage, "awk: invalid -v argument: '" .. assignment .. "'")
            return 2
        end
        vars[name] = tonumber(value) or value
    end
    local files = {}
    for i = 2, #opt.operands do files[#files + 1] = opt.operands[i] end
    local chunks = {}
    if #files == 0 then
        chunks[1] = read_all(stage) or ""
    else
        for _, operand in ipairs(files) do
            local path = resolve_path(operand)
            local text = perm.can_read(path) and TP.read(path) or nil
            if text == nil then
                emit(stage, "awk: " .. operand .. ": no such file")
            else
                chunks[#chunks + 1] = text
            end
        end
    end
    local options = { fs = opt.values.F, vars = vars }
    local ok, result = pcall(TP.awk.run, program, table.concat(chunks), options)
    if not ok then
        emit(stage, "awk: " .. tostring(result))
        return 2
    end
    for _, line in ipairs(result) do emit(stage, line) end
    return 0
end

-- -- sort ------------------------------------------------------------------
BUILTINS["sort"] = function(args, stage)
    local opt = TP.options({ n = true, r = true, u = true, f = true,
                             k = "value", t = "value" }, args, "sort", stage)
    if not opt then return 1 end
    local numeric = opt.flags.n == true
    local key = nil
    if opt.values.k then
        local first, rest = opt.values.k:match("^(%d+)(.*)$")
        local last, modifier = nil, rest or ""
        if rest then
            last = rest:match("^,?(%d*)") or ""
            modifier = rest:match("([%a]+)$") or ""
        end
        if not first then
            emit(stage, "sort: invalid key: '" .. opt.values.k .. "'")
            return 2
        end
        if modifier:find("n") then numeric = true end
        key = { first = tonumber(first),
                last = tonumber(last and last ~= "" and last or first) }
    end
    local separator = opt.values.t
    local lines = {}
    TP.each(opt.operands, stage, "sort", function(text)
        for _, line in ipairs(TP.lines(text)) do lines[#lines + 1] = line end
    end)

    local function key_of(line)
        if not key then return line end
        local parts = TP.fields(line, separator)
        local picked = {}
        for index = key.first, key.last do
            picked[#picked + 1] = parts[index] or ""
        end
        return table.concat(picked, " ")
    end

    local function less(a, b)
        local ka, kb = key_of(a), key_of(b)
        if numeric then
            local na, nb = tonumber(ka), tonumber(kb)
            if na and nb then
                if na == nb then return a < b end
                return na < nb
            end
            if na then return true end
            if nb then return false end
        end
        if opt.flags.f then
            ka, kb = ka:lower(), kb:lower()
        end
        if ka == kb then return a < b end
        return ka < kb
    end

    local function ordered(a, b)
        if opt.flags.r then return less(b, a) end
        return less(a, b)
    end

    table.sort(lines, ordered)
    local previous = nil
    local first_row = true
    for _, line in ipairs(lines) do
        local current = key_of(line)
        if not opt.flags.u or first_row or current ~= previous then
            emit(stage, line)
            previous = current
            first_row = false
        end
    end
    return 0
end

-- -- uniq ------------------------------------------------------------------
BUILTINS["uniq"] = function(args, stage)
    local opt = TP.options({ c = true, d = true, u = true, i = true },
                           args, "uniq", stage)
    if not opt then return 1 end
    local lines = {}
    TP.each(opt.operands, stage, "uniq", function(text)
        for _, line in ipairs(TP.lines(text)) do lines[#lines + 1] = line end
    end)
    local function same(a, b)
        if opt.flags.i then return a:lower() == b:lower() end
        return a == b
    end
    local index = 1
    while index <= #lines do
        local run = 1
        while index + run <= #lines and same(lines[index], lines[index + run]) do
            run = run + 1
        end
        local show = true
        if opt.flags.d then
            show = run > 1
        elseif opt.flags.u then
            show = run == 1
        end
        if show then
            if opt.flags.c then
                emit(stage, string.format("%7d %s", run, lines[index]))
            else
                emit(stage, lines[index])
            end
        end
        index = index + run
    end
    return 0
end

-- -- cut -------------------------------------------------------------------
BUILTINS["cut"] = function(args, stage)
    local opt = TP.options({ d = "value", f = "value", c = "value", s = true },
                           args, "cut", stage)
    if not opt then return 1 end
    local separator = opt.values.d or "\t"
    local fields = opt.values.f and TP.numlist(opt.values.f)
    local chars = opt.values.c and TP.numlist(opt.values.c)
    if opt.values.f and not fields then
        emit(stage, "cut: invalid field list: '" .. opt.values.f .. "'")
        return 2
    end
    if opt.values.c and not chars then
        emit(stage, "cut: invalid character list: '" .. opt.values.c .. "'")
        return 2
    end
    if fields and chars then
        emit(stage, "cut: only one type of list may be specified")
        return 2
    end
    if not fields and not chars then
        emit(stage, "cut: you must specify a list of bytes, characters or fields")
        return 2
    end
    TP.each(opt.operands, stage, "cut", function(text)
        for _, line in ipairs(TP.lines(text)) do
            if fields then
                local parts = TP.fields(line, separator)
                if #parts > 1 or line:find(separator, 1, true) then
                    local picked = {}
                    for _, index in ipairs(fields) do
                        picked[#picked + 1] = parts[index] or ""
                    end
                    emit(stage, table.concat(picked, separator))
                elseif not opt.flags.s then
                    -- A line without the delimiter is printed unchanged unless
                    -- -s asks for a silent skip.
                    emit(stage, line)
                end
            else
                local picked = {}
                for _, index in ipairs(chars) do
                    picked[#picked + 1] = line:sub(index, index)
                end
                emit(stage, table.concat(picked))
            end
        end
    end)
    return 0
end

-- -- tr --------------------------------------------------------------------
local TR_CLASSES = {
    alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    digit = "0123456789",
    alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    lower = "abcdefghijklmnopqrstuvwxyz",
    upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    space = " \t\n\r\f\v",
    blank = " \t",
    punct = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
    xdigit = "0123456789abcdefABCDEF",
}

-- Expands the escapes and the "[:class:]" names tr understands, then the
-- "a-z" ranges. The result is a plain string whose characters are the set.
function TP.set(text)
    local items = {}
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if c == "\\" and i < #text then
            local d = text:sub(i + 1, i + 1)
            local escapes = { n = "\n", t = "\t", r = "\r", a = "\a", b = "\b",
                              f = "\f", v = "\v", ["0"] = "\0", ["\\"] = "\\" }
            items[#items + 1] = escapes[d] or d
            i = i + 2
        elseif c == "[" and text:sub(i + 1, i + 1) == ":" then
            local close = text:find(":]", i + 2, true)
            local name = close and text:sub(i + 2, close - 1) or ""
            local class = TR_CLASSES[name]
            if class then
                items[#items + 1] = class
                i = close + 2
            else
                items[#items + 1] = c
                i = i + 1
            end
        else
            items[#items + 1] = c
            i = i + 1
        end
    end
    local out = {}
    local index = 1
    while index <= #items do
        local item = items[index]
        local dash = items[index + 1]
        local last_item = items[index + 2]
        -- "a-z" is a range only when the dash sits between two single
        -- characters; a dash anywhere else (or at the end) is a literal.
        if dash == "-" and last_item and #item == 1 and #last_item == 1 then
            local low, high = item:byte(), last_item:byte()
            if low > high then low, high = high, low end
            for code = low, high do out[#out + 1] = string.char(code) end
            index = index + 3
        else
            out[#out + 1] = item
            index = index + 1
        end
    end
    return table.concat(out)
end

BUILTINS["tr"] = function(args, stage)
    local opt = TP.options({ d = true, s = true }, args, "tr", stage)
    if not opt then return 1 end
    local source = opt.operands[1]
    local target = opt.operands[2]
    if source == nil then
        emit(stage, "usage: tr [-d] SET1 [SET2]")
        return 2
    end
    local set1 = TP.set(source)
    local set2 = target and TP.set(target) or nil
    -- SET2 belongs to the plain translation form and to "-s SET1 SET2";
    -- "-d SET1" and "-s SET1" are complete on their own.
    if not opt.flags.d and not opt.flags.s and set2 == nil then
        emit(stage, "tr: missing operand after '" .. source .. "'")
        return 2
    end
    local text = read_all(stage) or ""
    local out = {}
    local function map_text(body, mapping)
        local parts = {}
        for i = 1, #body do
            local c = body:sub(i, i)
            parts[#parts + 1] = mapping[c] or c
        end
        return table.concat(parts)
    end
    local function build_map()
        local mapping = {}
        for i = 1, #set1 do
            local c = set1:sub(i, i)
            -- A short SET2 is padded with its last character, as tr does.
            local r = set2:sub(i, i)
            if r == "" then r = set2:sub(-1) end
            mapping[c] = r
        end
        return mapping
    end
    if opt.flags.d then
        local drop = {}
        for i = 1, #set1 do drop[set1:sub(i, i)] = true end
        for i = 1, #text do
            local c = text:sub(i, i)
            if not drop[c] then out[#out + 1] = c end
        end
    elseif opt.flags.s then
        local body = set2 and map_text(text, build_map()) or text
        local squeeze = {}
        for i = 1, #set1 do squeeze[set1:sub(i, i)] = true end
        local previous = nil
        for i = 1, #body do
            local c = body:sub(i, i)
            if not (squeeze[c] and c == previous) then out[#out + 1] = c end
            previous = c
        end
    else
        local mapping = build_map()
        for i = 1, #text do
            local c = text:sub(i, i)
            out[#out + 1] = mapping[c] or c
        end
    end
    for _, line in ipairs(TP.lines(table.concat(out))) do emit(stage, line) end
    return 0
end

-- -- tee -------------------------------------------------------------------
BUILTINS["tee"] = function(args, stage)
    local opt = TP.options({ a = true, i = true }, args, "tee", stage)
    if not opt then return 1 end
    local text = read_all(stage) or ""
    local failed = false
    for _, operand in ipairs(opt.operands) do
        local path = resolve_path(operand)
        if not guard_write(path, stage) then
            failed = true
        elseif perm.get_mode(path) and not perm.can_write(path) then
            emit(stage, "tee: " .. operand .. ": permission denied")
            failed = true
        else
            -- tee holds the whole input in memory ("text"), so the size this
            -- write needs is known exactly -- the one filter where the preflight
            -- is not a guess about "not full".
            local room, why = require("space").need(path, #text)
            if not room then
                emit(stage, "tee: " .. operand .. ": " .. why)
                failed = true
            else
                local handle = fs.open(path, opt.flags.a and "a" or "w")
                if not handle then
                    emit(stage, "tee: " .. operand .. ": cannot open")
                    failed = true
                else
                    handle.write(text)
                    handle.close()
                end
            end
        end
    end
    -- tee passes its input through untouched, so it can sit in the middle of a
    -- pipeline while it writes the file copies.
    for _, line in ipairs(TP.lines(text)) do emit(stage, line) end
    if failed then return 1 end
    return 0
end

-- -- xargs -----------------------------------------------------------------
BUILTINS["xargs"] = function(args, stage)
    local opt = TP.options({ n = "value", I = "value" }, args, "xargs", stage)
    if not opt then return 1 end
    local command = opt.operands[1] or "echo"
    local template = { command }
    for i = 2, #opt.operands do template[#template + 1] = opt.operands[i] end
    local items = {}
    for word in (read_all(stage) or ""):gmatch("%S+") do
        items[#items + 1] = word
    end

    -- A built-in is called on a stage that shares the output of the caller, so
    -- the batch output stays inside the pipeline; an external command is
    -- started through the normal loader.
    local function launch(parts)
        local head = parts[1]
        if not head then return 0 end
        local rest = {}
        for i = 2, #parts do rest[#rest + 1] = parts[i] end
        if BUILTINS[head] then
            local sub = { words = parts, fields = {}, _out = stage._out }
            local result = BUILTINS[head](rest, sub)
            if type(result) == "number" then return result end
            return 0
        end
        local ok, status = pcall(run_stage, { words = parts, fields = {} })
        if not ok then
            emit(stage, "xargs: " .. tostring(status))
            return 1
        end
        if type(status) == "number" then return status end
        return 0
    end

    local failed = 0
    local function build(extra)
        local parts = {}
        for i = 1, #template do parts[i] = template[i] end
        for i = 1, #extra do parts[#parts + 1] = extra[i] end
        return parts
    end

    if opt.values.I then
        local marker = opt.values.I
        local escaped = marker:gsub("(%W)", "%%%1")
        for _, item in ipairs(items) do
            local parts = {}
            for i = 1, #template do
                parts[i] = (template[i]:gsub(escaped, function() return item end))
            end
            if launch(parts) ~= 0 then failed = failed + 1 end
        end
    else
        local batch = tonumber(opt.values.n) or #items
        if batch < 1 then batch = 1 end
        local index = 1
        while index <= #items do
            local extra = {}
            for j = index, math.min(index + batch - 1, #items) do
                extra[#extra + 1] = items[j]
            end
            if launch(build(extra)) ~= 0 then failed = failed + 1 end
            index = index + batch
        end
    end
    if failed > 0 then return 1 end
    return 0
end

BUILTINS["tac"] = function(args, stage)
    local lines = read_lines(stage)
    for i = #lines, 1, -1 do emit(stage, lines[i]) end
end

BUILTINS["rev"] = function(args, stage)
    for _, line in ipairs(read_lines(stage)) do emit(stage, line:reverse()) end
end

-- ---- Find / info ----
BUILTINS["find"] = function(args, stage)
    local root = args[1]
    if not root or root:sub(1, 1) == "-" then root = cwd.get() end
    root = resolve_path(root)
    local name_filter
    for i, a in ipairs(args) do
        if a == "-name" then name_filter = args[i + 1] end
    end
    local function walk(p)
        for _, f in ipairs(fs.list(p)) do
            local full = (p == "/" and "/" or p .. "/") .. f
            if not name_filter or f:find(name_filter:gsub("%*", ".*"):gsub("%?", ".")) then
                emit(stage, full)
            end
            if fs.isDir(full) then walk(full) end
        end
    end
    walk(root)
end

BUILTINS["stat"] = function(args, stage)
    for _, a in ipairs(args) do
        local p = resolve_path(a)
        if fs.exists(p) then
            local kind = fs.isDir(p) and "directory" or "regular file"
            local size = fs.isDir(p) and 0 or fs.getSize(p)
            emit(stage, "  File: " .. p)
            emit(stage, "  Type: " .. kind)
            emit(stage, "  Size: " .. size)
        else emit(stage, "stat: " .. p .. ": no such file") end
    end
end

BUILTINS["du"] = function(args, stage)
    local total = 0
    local function walk(p)
        for _, f in ipairs(fs.list(p)) do
            local full = (p == "/" and "/" or p .. "/") .. f
            if fs.isDir(full) then walk(full)
            else
                local s = fs.getSize(full) or 0
                total = total + s
                emit(stage, s .. "\t" .. full)
            end
        end
    end
    walk(resolve_path(args[1] or cwd.get()))
    emit(stage, total .. "\ttotal")
end

-- Shared size formatter for df/free/top. The input is KiB, which is the unit
-- fs.getCapacity()/fs.getFreeSpace() use.
local function fmt_size(kb, human)
    kb = kb or 0
    if not human then return tostring(kb) end
    if kb >= 1024 * 1024 then return string.format("%.1fG", kb / (1024 * 1024)) end
    if kb >= 1024 then return string.format("%.1fM", kb / 1024) end
    return kb .. "K"
end

-- df: real numbers per filesystem from fs.getCapacity()/fs.getFreeSpace().
-- Mounts registered in the mount table appear under their logical target.
-- When a single path is asked for, the device that serves it is reported under
-- that path, the way mount(8)/df(1) do it: "df /mnt/floppy" says the floppy
-- filesystem is mounted on /mnt/floppy, not on the device behind it.
BUILTINS["df"] = function(args, stage)
    local human = false
    local only = nil
    for _, a in ipairs(args) do
        if a == "-h" then human = true
        elseif a:sub(1, 1) ~= "-" then only = a end
    end

    emit(stage, string.format("%-16s %10s %10s %10s %5s %s",
         "Filesystem", "1K-blocks", "Used", "Available", "Use%", "Mounted on"))

    local shown, tot_cap, tot_used, tot_free = 0, 0, 0, 0
    for _, m in ipairs(sysinfo.filesystems()) do
        local show = true
        local target = m.mount
        if only then
            local p = resolve_path(only)
            show = (m.mount == only or m.probe == p or m.probe == only)
            if show and m.mount ~= only and mounts.map(only) == m.probe then
                target = only
            end
        end
        if show then
            shown = shown + 1
            tot_cap, tot_used, tot_free =
                tot_cap + m.capacity, tot_used + m.used, tot_free + m.free
            local pct = m.capacity > 0 and
                        math.floor(m.used * 100 / m.capacity + 0.5) or 0
            if m.readonly then target = target .. " (ro)" end
            emit(stage, string.format("%-16s %10s %10s %10s %4d%% %s",
                 m.probe, fmt_size(m.capacity, human), fmt_size(m.used, human),
                 fmt_size(m.free, human), pct, target))
        end
    end

    if shown == 0 then
        emit(stage, "df: " .. (only or "?") .. ": no such filesystem")
        return 1
    end

    if shown > 1 then
        local pct = tot_cap > 0 and math.floor(tot_used * 100 / tot_cap + 0.5) or 0
        emit(stage, string.format("%-16s %10s %10s %10s %4d%% %s",
             "total", fmt_size(tot_cap, human), fmt_size(tot_used, human),
             fmt_size(tot_free, human), pct, "-"))
    end
    return 0
end

-- free: CraftOS has no RAM figure to report. What really exists is the storage
-- space of the mounted filesystems plus the Lua heap of the running VM, so
-- both are shown, with their data source spelled out.
BUILTINS["free"] = function(args, stage)
    local human = false
    for _, a in ipairs(args) do
        if a == "-h" then human = true end
    end

    local cap, free = sysinfo.storage_total()
    local heap_kb = sysinfo.heap_bytes()
    heap_kb = heap_kb and math.floor(heap_kb / 1024) or nil
    local id = sysinfo.computer()

    emit(stage, string.format("%-12s %10s %10s %10s  %s",
         "", "total", "used", "free", "source"))
    emit(stage, string.format("%-12s %10s %10s %10s  %s",
         "Storage", fmt_size(cap, human), fmt_size(cap - free, human),
         fmt_size(free, human), "fs.getCapacity/getFreeSpace"))
    if heap_kb then
        emit(stage, string.format("%-12s %10s %10s %10s  %s",
             "Lua heap", fmt_size(heap_kb, human), fmt_size(heap_kb, human), "-",
             'collectgarbage("count")'))
    else
        emit(stage, string.format("%-12s %10s %10s %10s  %s",
             "Lua heap", "-", "-", "-", "not available on this runtime"))
    end

    emit(stage, "")
    emit(stage, string.format("Computer: %s (%s), id %d, host %s",
         id.label, id.version, id.id, id.host))
    emit(stage, string.format("Uptime:   %d s (os.clock), boot at %s",
         math.floor(sysinfo.uptime_seconds()),
         sysinfo.boot_epoch_ms() and
             os.date("%Y-%m-%d %H:%M:%S",
                     math.floor(sysinfo.boot_epoch_ms() / 1000)) or "unknown"))
    local modems = {}
    for _, n in ipairs(sysinfo.network()) do
        modems[#modems + 1] = n.side .. (n.wireless and " (wireless)" or " (wired)")
    end
    emit(stage, string.format("Network:  %s",
         #modems > 0 and table.concat(modems, ", ") or "no modem attached"))
    emit(stage, "Note:     CraftOS is single threaded and reports no RAM or swap;")
    emit(stage, "          the Lua heap is the only runtime memory figure available.")
    return 0
end

-- top: repeated sampling of the same sources as df/free/ps.
BUILTINS["top"] = function(args, stage)
    local iterations = 0   -- 0 means: run until Ctrl+T interrupts the loop
    for _, a in ipairs(args) do
        local n = a:match("^%-n(%d+)$") or a:match("^%-(%d+)$")
        if n then iterations = tonumber(n) end
    end
    local redirected = (stage and stage.redirect) and true or false
    if redirected then iterations = 1 end

    local function snapshot()
        local lines = {}
        local id = sysinfo.computer()
        local cap, free = sysinfo.storage_total()
        local heap_kb = sysinfo.heap_bytes()
        heap_kb = heap_kb and math.floor(heap_kb / 1024) or nil
        lines[#lines + 1] = string.format(
            "ush top - %s (%s) - up %ds%s", id.label, id.version,
            math.floor(sysinfo.uptime_seconds()),
            redirected and "" or "  (Ctrl+T to quit)")
        lines[#lines + 1] = string.format(
            "Storage %s total / %s used / %s free   Lua heap %s",
            fmt_size(cap, true), fmt_size(cap - free, true), fmt_size(free, true),
            heap_kb and fmt_size(heap_kb, true) or "n/a")
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  PID  TTY      STAT    CMD"
        for _, t in ipairs(sysinfo.tasks()) do
            lines[#lines + 1] = string.format("%5d  %-7s  %-6s  %s",
                t.pid, t.kind or "?", t.state or "?", t.command or "")
        end
        return lines
    end

    local i = 0
    while true do
        i = i + 1
        if not redirected then
            term.clear()
            term.setCursorPos(1, 1)
        end
        for _, line in ipairs(snapshot()) do emit(stage, line) end
        if redirected then break end
        if iterations > 0 and i >= iterations then break end
        if not pcall(os.sleep, 1) then break end
    end
    if not redirected then print("") end
    return 0
end

BUILTINS["file"] = function(args, stage)
    for _, a in ipairs(args) do
        local p = resolve_path(a)
        if fs.isDir(p) then emit(stage, p .. ": directory")
        elseif fs.exists(p) then emit(stage, p .. ": ASCII text")
        else emit(stage, p .. ": cannot open") end
    end
end

BUILTINS["basename"] = function(args, stage)
    for _, p in ipairs(args) do
        local b = p:match("([^/]+)/*$")
        if b then emit(stage, b) end
    end
end

BUILTINS["dirname"] = function(args, stage)
    for _, p in ipairs(args) do
        local d = p:match("^(.*)/[^/]+/*$")
        emit(stage, d == "" and "/" or (d or "."))
    end
end

-- ---- System ----
BUILTINS["clear"] = function() term.clear(); term.setCursorPos(1,1) end
BUILTINS["date"] = function(args, stage)
    local tz = require("time")
    emit(stage, tz.format("%a %b %d %H:%M:%S %Y"))
end
BUILTINS["uname"] = function(args, stage)
    local a = false
    for _, x in ipairs(args) do if x == "-a" then a = true end end
    if a then emit(stage, "ush 1.0 CC-Tweaked lua localhost")
    else emit(stage, "ush") end
end
BUILTINS["hostname"] = function(args, stage)
    emit(stage, os.getComputerLabel() or ("cc-" .. os.getComputerID()))
end
BUILTINS["whoami"] = function(args, stage) emit(stage, perm.get_current_user()) end
BUILTINS["id"] = function(args, stage)
    local u = perm.get_current_user()
    local lvl = perm.user_level(u)
    local gs = table.concat(perm.get_groups(u), ",")
    emit(stage, "uid=" .. lvl .. "(" .. u .. ") gid=" .. lvl ..
         "(" .. u .. ") groups=" .. gs)
end
-- uptime: os.clock() counts the seconds since the computer booted, and
-- os.epoch("utc") gives the wall clock, so the boot timestamp is derived from
-- the two instead of being invented.
BUILTINS["uptime"] = function(args, stage)
    local tz = require("time")
    local secs = math.floor(sysinfo.uptime_seconds())
    local days = math.floor(secs / 86400)
    local hours = math.floor(secs % 86400 / 3600)
    local mins = math.floor(secs % 3600 / 60)

    local parts = {}
    if days > 0 then
        parts[#parts + 1] = days .. (days == 1 and " day" or " days")
    end
    if days > 0 or hours > 0 then
        parts[#parts + 1] = string.format("%d:%02d", hours, mins)
    else
        parts[#parts + 1] = mins .. (mins == 1 and " minute" or " minutes")
    end

    local boot = sysinfo.boot_epoch_ms()
    local extra = ""
    if boot then
        extra = " (booted " .. os.date("%Y-%m-%d %H:%M:%S",
                                       math.floor(boot / 1000)) .. ")"
    end

    emit(stage, string.format("%s up %s, 1 user, load average: n/a%s",
         tz.format("%H:%M:%S"), table.concat(parts, ", "), extra))
    emit(stage, "note: load average is not available on CraftOS (single threaded runtime)")
    return 0
end

-- ps: CraftOS has no kernel process table. The view below is built from what
-- really exists - multishell tabs (each tab is a Lua coroutine), this shell,
-- and the ush internal job table.
BUILTINS["ps"] = function(args, stage)
    local wide = false
    for _, a in ipairs(args) do
        if a == "-ef" or a == "-e" or a == "-A" then wide = true end
    end
    if wide then
        emit(stage, "  PID  TTY      STAT    START      CMD")
    else
        emit(stage, "  PID  TTY      STAT    CMD")
    end
    for _, t in ipairs(sysinfo.tasks()) do
        if wide then
            emit(stage, string.format("%5d  %-7s  %-6s  %-9s  %s",
                 t.pid, t.kind or "?", t.state or "?",
                 t.started and os.date("%H:%M:%S", t.started) or "-",
                 t.command or ""))
        else
            emit(stage, string.format("%5d  %-7s  %-6s  %s",
                 t.pid, t.kind or "?", t.state or "?", t.command or ""))
        end
    end
    return 0
end
-- ---- Mounts ----
-- CraftOS has no kernel mount namespace: a floppy drive simply appears as the
-- directory /disk. mount(8)/umount(8) therefore maintain a user space table
-- (lib/mounts.lua, persisted in /var/lib/mounts) that path resolution honours:
-- after "mount /disk /mnt/a" the path /mnt/a resolves to the real /disk.
BUILTINS["mount"] = function(args, stage)
    local opts = nil
    local positional = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-o" then
            opts = args[i + 1] or opts
            i = i + 1
        elseif a:match("^%-o.+") then
            opts = a:sub(3)
        elseif a == "-r" then
            opts = opts and (opts .. ",ro") or "ro"
        elseif a:sub(1, 1) == "-" then
            emit(stage, "mount: unknown option " .. a)
            return 1
        else
            positional[#positional + 1] = a
        end
        i = i + 1
    end

    if #positional == 0 then
        if #mounts.list() == 0 then
            emit(stage, "mount: the user mount table is empty")
            emit(stage, "mount: use df(1) to see the real filesystems (/, /rom, /disk)")
            return 0
        end
        for _, e in ipairs(mounts.list()) do
            emit(stage, mounts.format(e))
        end
        return 0
    end

    local source = resolve_path(positional[1])
    -- The target must NOT go through the mount map: it is a new logical path.
    local target = positional[2] and cwd.resolve(positional[2]) or nil
    local ok, res = mounts.mount(source, target, opts, perm.get_current_user())
    if not ok then
        emit(stage, "mount: " .. tostring(res))
        return 1
    end
    emit(stage, mounts.format(res))
    return 0
end

BUILTINS["umount"] = function(args, stage)
    local targets, all = {}, false
    for _, a in ipairs(args) do
        if a == "-a" then all = true
        elseif a:sub(1, 1) ~= "-" then targets[#targets + 1] = a end
    end
    if all then
        for _, e in ipairs(mounts.list()) do targets[#targets + 1] = e.target end
    end
    if #targets == 0 then
        emit(stage, "umount: usage: umount [-a] <target|source>")
        return 1
    end

    local status = 0
    for _, spec in ipairs(targets) do
        local ok, res = mounts.umount(cwd.resolve(spec), cwd.get())
        if not ok then ok, res = mounts.umount(spec, cwd.get()) end
        if ok then
            emit(stage, "umount: " .. res.target .. " unmounted (was " ..
                 res.source .. ")")
        else
            emit(stage, "umount: " .. tostring(res))
            status = 1
        end
    end
    return status
end

-- ---- Network ----
-- Everything network related goes through rednet, which is what really exists
-- on CC:Tweaked. There is no IP stack, no DNS and no port number, so these
-- commands speak in terms of computer IDs, modem sides and protocols.
local function ensure_rednet(stage)
    local modems = sysinfo.network()
    if #modems == 0 then
        emit(stage, "ush: no modem attached (attach a modem or wireless modem)")
        return nil
    end
    for _, m in ipairs(modems) do
        if m.open then return m.side end
    end
    local side = modems[1].side
    local ok = pcall(rpvnet.open, side)
    if ok then
        emit(stage, "ush: rednet opened on " .. side)
        return side
    end
    emit(stage, "ush: cannot open rednet on " .. side)
    return nil
end

BUILTINS["netstat"] = function(args, stage)
    local modems = sysinfo.network()
    if #modems == 0 then
        emit(stage, "netstat: no modem attached")
        return 1
    end
    emit(stage, string.format("%-8s %-10s %-9s %-8s %s",
         "Iface", "Kind", "Wireless", "Rednet", "Hostname"))
    for _, m in ipairs(modems) do
        emit(stage, string.format("%-8s %-10s %-9s %-8s %s",
             m.side, "modem", m.wireless and "yes" or "no",
             m.open and "open" or "closed",
             tostring(os.getComputerID())))
    end
    emit(stage, "note: CraftOS has no sockets; rednet messages travel over the")
    emit(stage, "      modem channel and are filtered by protocol name.")
    return 0
end

BUILTINS["ping"] = function(args, stage)
    local target, count, timeout = nil, 4, 1.0
    local i = 1
    while i <= #args do
        local a = args[i]
        local n = a:match("^%-c(%d+)$")
        local t = a:match("^%-W([%d%.]+)$")
        if a == "-c" then
            count = tonumber(args[i + 1]) or count
            i = i + 1
        elseif n then count = tonumber(n)
        elseif a == "-W" then
            timeout = tonumber(args[i + 1]) or timeout
            i = i + 1
        elseif t then timeout = tonumber(t)
        elseif a:sub(1, 1) == "-" then
            emit(stage, "ping: unknown option " .. a)
            return 1
        elseif not target then
            target = tonumber(a)
        else
            count = tonumber(a) or count
        end
        i = i + 1
    end

    if not target then
        emit(stage, "ping: usage: ping [-c count] [-W timeout] <computer id>")
        return 1
    end
    if not ensure_rednet(stage) then return 1 end

    emit(stage, string.format("PING %d (rednet) 4 data bytes", target))
    local received, sent, total_ms = 0, 0, 0

    for seq = 1, count do
        sent = sent + 1
        local replied, rtt = false, nil
        local ok = pcall(function()
            local timer = os.startTimer(timeout)
            local start = os.clock()
            rpvnet.send(target, "ping " .. seq, "ush-ping")
            while true do
                local ev, a = os.pullEvent()
                if ev == "timer" and a == timer then break end
                if ev == "rednet_message" and a == target then
                    replied, rtt = true, (os.clock() - start) * 1000
                    break
                end
            end
        end)

        if ok and replied then
            received = received + 1
            total_ms = total_ms + rtt
            emit(stage, string.format("4 bytes from %d: seq=%d time=%.1f ms",
                 target, seq, rtt))
            if seq < count then os.sleep(0.2) end
        elseif ok then
            emit(stage, string.format("Request to %d timed out (seq=%d)", target, seq))
        else
            emit(stage, "ping: interrupted")
            break
        end
    end

    local loss = sent > 0 and math.floor((sent - received) * 100 / sent + 0.5) or 0
    emit(stage, string.format("--- %d ping statistics ---", target))
    emit(stage, string.format("%d packets transmitted, %d received, %d%% packet loss",
         sent, received, loss))
    if received > 0 then
        emit(stage, string.format("rtt avg = %.1f ms", total_ms / received))
    end
    return received > 0 and 0 or 1
end

BUILTINS["netsend"] = function(args, stage)
    if #args < 2 then
        emit(stage, "netsend: usage: netsend <id|broadcast> <message>")
        return 1
    end
    if not ensure_rednet(stage) then return 1 end

    local dest = args[1]
    local text = table.concat(args, " ", 2)
    local ok, err
    if dest == "broadcast" or dest == "-b" or dest == "*" then
        ok, err = pcall(rpvnet.broadcast, text, "ush-msg")
    else
        local id = tonumber((dest:gsub("^%%", "")))
        if not id then
            emit(stage, "netsend: invalid destination " .. dest)
            return 1
        end
        ok, err = pcall(rpvnet.send, id, text, "ush-msg")
    end

    if not ok then
        emit(stage, "netsend: " .. tostring(err))
        return 1
    end
    emit(stage, "netsend: sent to " .. dest)
    return 0
end

BUILTINS["netrecv"] = function(args, stage)
    local timeout, protocol = 5, nil
    local i = 1
    while i <= #args do
        local a = args[i]
        local t = a:match("^%-t([%d%.]+)$")
        if a == "-t" then
            timeout = tonumber(args[i + 1]) or timeout
            i = i + 1
        elseif t then timeout = tonumber(t)
        elseif a:sub(1, 1) == "-" then
            emit(stage, "netrecv: unknown option " .. a)
            return 1
        else
            protocol = a
        end
        i = i + 1
    end

    if not ensure_rednet(stage) then return 1 end
    emit(stage, string.format("netrecv: waiting up to %.1fs%s", timeout,
         protocol and (" for protocol " .. protocol) or ""))

    local ok, sender, msg, proto = pcall(rpvnet.receive, protocol, timeout)
    if not ok then
        emit(stage, "netrecv: interrupted")
        return 130
    end
    if sender == nil then
        emit(stage, "netrecv: timeout")
        return 1
    end
    emit(stage, string.format("%s: %s (protocol %s)",
         tostring(sender), tostring(msg), tostring(proto)))
    return 0
end

BUILTINS["netopen"] = function(args, stage)
    local side = args[1]
    if not side then
        local modems = sysinfo.network()
        if #modems == 0 then
            emit(stage, "netopen: no modem attached")
            return 1
        end
        side = modems[1].side
    end
    local ok, err = pcall(rpvnet.open, side)
    if not ok then
        emit(stage, "netopen: " .. tostring(err))
        return 1
    end
    emit(stage, "netopen: rednet open on side " .. side)
    return 0
end

BUILTINS["netclose"] = function(args, stage)
    local modems = sysinfo.network()
    if #modems == 0 then
        emit(stage, "netclose: no modem attached")
        return 1
    end
    for _, m in ipairs(modems) do
        if m.open then pcall(rpvnet.close, m.side) end
    end
    emit(stage, "netclose: rednet closed")
    return 0
end

-- ---- Job control ----
-- Honest semantics: CraftOS is single threaded and a Lua coroutine can only be
-- suspended where the code yields. "cmd &" therefore starts a cooperative job
-- that the idle hook advances between keystrokes; a command that never yields
-- runs to completion in one slice, exactly like a foreground command.
BUILTINS["jobs"] = function(args, stage)
    local list = jobs.list()
    if #list == 0 then
        emit(stage, "jobs: no background jobs")
        return 0
    end
    for _, j in ipairs(list) do
        local mark = (j.state == "running") and "+" or "-"
        emit(stage, string.format("[%d]%s %-8s %s",
             j.id, mark, j.state, j.command))
    end
    return 0
end

local function job_arg(args, stage)
    if args[1] == nil then return nil end
    local id = jobs.resolve(args[1])
    if id == nil then
        emit(stage, "ush: " .. args[1] .. ": invalid job specification")
        return nil
    end
    return id
end

BUILTINS["fg"] = function(args, stage)
    local id = job_arg(args, stage)
    if args[1] == nil then
        local list = jobs.list()
        if #list == 0 then
            emit(stage, "fg: no current job")
            return 1
        end
        id = list[#list].id
    elseif id == nil then
        return 1
    end

    local job = jobs.get(id)
    if not job then
        emit(stage, "fg: " .. tostring(args[1]) .. ": no such job")
        return 1
    end
    if job.state ~= "running" then
        emit(stage, string.format("fg: %d: job is %s", id, job.state))
        return 1
    end

    emit(stage, job.command)
    if not jobs.foreground(id) then
        emit(stage, "fg: " .. tostring(args[1]) .. ": no such job")
        return 1
    end
    if job.state == "running" then
        -- The job yielded again: a service style loop cannot be run to the
        -- end without locking the shell, so it goes back to the job table.
        emit(stage, string.format("fg: job %d yielded again and keeps running in the background", id))
    end
    return 0
end

BUILTINS["bg"] = function(args, stage)
    local id = job_arg(args, stage)
    if id == nil then
        if args[1] == nil then
            emit(stage, "bg: usage: bg <%job>")
        end
        return 1
    end
    local job, err = jobs.background(id)
    if not job then
        emit(stage, "bg: " .. tostring(err))
        return 1
    end
    emit(stage, string.format("[%d] %s", job.id, job.command))
    return 0
end

BUILTINS["kill"] = function(args, stage)
    if #args == 0 then
        emit(stage, "kill: usage: kill <%job> ...")
        return 1
    end
    local status = 0
    for _, a in ipairs(args) do
        local id = jobs.resolve(a)
        if id == nil then
            emit(stage, "kill: " .. a .. ": invalid job specification")
            status = 1
        else
            local job, err = jobs.kill(id)
            if job then
                emit(stage, string.format("[%d] killed (%s)", job.id, job.command))
            else
                emit(stage, "kill: " .. tostring(err))
                status = 1
            end
        end
    end
    return status
end

BUILTINS["disown"] = function(args, stage)
    local before = #jobs.list()
    jobs.clean()
    local removed = before - #jobs.list()
    if removed < 0 then removed = 0 end
    emit(stage, string.format("disown: %d finished job(s) removed", removed))
    return 0
end

-- ---- Scheduled tasks ----
-- crontab entries live in /etc/crontab ("m h dom mon dow user command"), at
-- jobs in /var/spool/at. They are fired by the idle hook (see shell_idle).
local function crontab_user(args, stage)
    local user = perm.get_current_user()
    local rest = {}
    local i = 1
    while i <= #args do
        if args[i] == "-u" then
            user = args[i + 1] or user
            i = i + 1
        else
            rest[#rest + 1] = args[i]
        end
        i = i + 1
    end
    if user ~= perm.get_current_user() and perm.user_level(perm.get_current_user()) < 1 then
        emit(stage, "crontab: only root may use -u")
        return nil, rest
    end
    if not perm.user_exists(user) then
        emit(stage, "crontab: unknown user " .. user)
        return nil, rest
    end
    return user, rest
end

-- Accept both "m h dom mon dow user cmd" and the user level "m h dom mon dow
-- cmd" form (the owner is then the calling user). Special time specs are passed
-- through unchanged, lib/cron.lua validates them: "@reboot user cmd" for the
-- system table and "@reboot cmd" for a user table (owner = calling user).
local function normalize_cron_line(line, owner)
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" or trimmed:sub(1, 1) == "#" then return trimmed end
    local words = {}
    for w in trimmed:gmatch("%S+") do words[#words + 1] = w end

    if (words[1] or ""):sub(1, 1) == "@" then
        if #words < 3 then
            return nil, "expected '@reboot user command'"
        end
        if perm.user_exists(words[2]) then return trimmed end
        return words[1] .. " " .. owner .. " " .. table.concat(words, " ", 2)
    end

    if #words < 6 then
        return nil, "expected 'minute hour dom month dow command'"
    end
    if perm.user_exists(words[6]) then return trimmed end
    local cmd = table.concat(words, " ", 6)
    return table.concat({ words[1], words[2], words[3], words[4], words[5],
                          owner, cmd }, " ")
end

BUILTINS["crontab"] = function(args, stage)
    local user, rest = crontab_user(args, stage)
    if not user then return 1 end

    local mode, file = "list", nil
    for _, a in ipairs(rest) do
        if a == "-l" then mode = "list"
        elseif a == "-r" then mode = "remove"
        elseif a == "-e" then mode = "edit"
        elseif a == "-h" then
            emit(stage, "usage: crontab [-u user] -l | -r | -e | <file>")
            emit(stage, "       entries: minute hour dom month dow command")
            return 0
        elseif a:sub(1, 1) ~= "-" then
            mode, file = "install", a
        end
    end

    if mode == "list" then
        local list = cron.entries_for(user)
        emit(stage, "# crontab for " .. user .. " (/etc/crontab)")
        if #list == 0 then
            emit(stage, "# no entries")
        end
        for i, e in ipairs(list) do
            local note = ""
            -- next_time() walks the calendar minute by minute, so only the
            -- first entries get a prediction.
            if e.special then
                note = "  # " .. e.alias .. ": runs at next boot"
            elseif i <= 20 then
                local next_at = cron.next_time(e)
                if next_at then
                    note = "  # next " .. os.date("%Y-%m-%d %H:%M", next_at)
                end
            end
            emit(stage, e.line .. note)
        end
        local _, bad = cron.entries()
        for _, b in ipairs(bad) do
            emit(stage, "# invalid: " .. b.line .. " (" .. b.reason .. ")")
        end
        return 0
    elseif mode == "remove" then
        local ok, err = cron.remove_for(user)
        if not ok then
            emit(stage, "crontab: " .. tostring(err))
            return 1
        end
        emit(stage, "crontab: entries of " .. user .. " removed")
        return 0
    elseif mode == "edit" then
        cron.ensure()
        if not fs.exists("/var/tmp") then fs.makeDir("/var/tmp") end
        local tmp = "/var/tmp/crontab." .. user
        local f = fs.open(tmp, "w")
        for _, e in ipairs(cron.entries()) do
            if e.user == user then f.writeLine(e.line) end
        end
        f.close()

        if not shell or not shell.run then
            emit(stage, "crontab: no editor available, edit " .. tmp ..
                 " and run: crontab " .. tmp)
            return 1
        end
        pcall(shell.run, "edit", tmp)

        local ok, lines = pcall(function()
            local out = {}
            local fh = fs.open(tmp, "r")
            while true do
                local line = fh.readLine()
                if line == nil then break end
                out[#out + 1] = line
            end
            fh.close()
            return out
        end)
        if not ok then
            emit(stage, "crontab: cannot read " .. tmp)
            return 1
        end
        local normalized, status = {}, 0
        for _, line in ipairs(lines) do
            local n, why = normalize_cron_line(line, user)
            if n == nil then
                emit(stage, "crontab: " .. why .. ": " .. line)
                status = 1
            elseif n ~= "" then
                normalized[#normalized + 1] = n
            end
        end
        if status ~= 0 then
            emit(stage, "crontab: nothing installed, fix the lines above")
            return 1
        end
        local saved, err = cron.install_for(user, normalized)
        if not saved then
            emit(stage, "crontab: " .. tostring(err))
            return 1
        end
        emit(stage, string.format("crontab: %d entries installed for %s",
             #normalized, user))
        return 0
    end

    -- install from a file
    local path = resolve_path(file)
    local f = fs.open(path, "r")
    if not f then
        emit(stage, "crontab: " .. file .. ": no such file")
        return 1
    end
    local normalized, status = {}, 0
    while true do
        local line = f.readLine()
        if line == nil then break end
        local n, why = normalize_cron_line(line, user)
        if n == nil then
            emit(stage, "crontab: " .. why .. ": " .. line)
            status = 1
        elseif n ~= "" then
            normalized[#normalized + 1] = n
        end
    end
    f.close()
    if status ~= 0 then
        emit(stage, "crontab: nothing installed, fix the lines above")
        return 1
    end
    local saved, err = cron.install_for(user, normalized)
    if not saved then
        emit(stage, "crontab: " .. tostring(err))
        return 1
    end
    emit(stage, string.format("crontab: %d entries installed for %s",
         #normalized, user))
    return 0
end

BUILTINS["at"] = function(args, stage)
    local when, file, list, remove = nil, nil, false, nil
    local text
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-l" then list = true
        elseif a == "-r" then remove = args[i + 1]; i = i + 1
        elseif a == "-f" then file = args[i + 1]; i = i + 1
        elseif a == "-t" then when = args[i + 1]; i = i + 1
        elseif when == nil and (a:match("^%+%d+$") or a:match("^%d%d?:%d%d$")
                                or a:match("^%d+$")) then
            when = a
        elseif a:sub(1, 1) == "-" then
            emit(stage, "at: unknown option " .. a)
            return 1
        else
            text = text and (text .. " " .. a) or a
        end
        i = i + 1
    end

    if list or (when == nil and file == nil and not list and remove == nil and text == nil) then
        local queue = cron.at_list()
        if #queue == 0 then
            emit(stage, "at: no queued jobs")
            return 0
        end
        for _, j in ipairs(queue) do
            emit(stage, string.format("%s  %s  %s", j.name,
                 os.date("%Y-%m-%d %H:%M:%S", j.when_epoch),
                 j.command or ""))
        end
        return 0
    end

    if remove then
        local target = remove
        local ok = false
        if fs.exists(target) then
            ok = cron.at_remove(target)
        else
            for _, j in ipairs(cron.at_list()) do
                if j.name == target or j.name == target .. ".job" then
                    ok = cron.at_remove(j.path)
                end
            end
        end
        if ok then
            emit(stage, "at: job " .. target .. " removed")
            return 0
        end
        emit(stage, "at: " .. target .. ": no such job")
        return 1
    end

    local command = text
    if file then
        local p = resolve_path(file)
        local fh = fs.open(p, "r")
        if not fh then
            emit(stage, "at: " .. file .. ": no such file")
            return 1
        end
        local buf = {}
        while true do
            local line = fh.readLine()
            if line == nil then break end
            buf[#buf + 1] = line
        end
        fh.close()
        command = table.concat(buf, "; ")
    end

    if not command or command == "" then
        emit(stage, "at: usage: at <+N|HH:MM|epoch> <command>")
        emit(stage, "at:        at -f <file> <time> | at -l | at -r <job>")
        return 1
    end

    local epoch, kind = cron.parse_at_time(when)
    if not epoch then
        emit(stage, "at: " .. tostring(kind))
        return 1
    end
    local path = cron.at_add(epoch, command, perm.get_current_user())
    if not path then
        emit(stage, "at: cannot queue the job")
        return 1
    end
    emit(stage, string.format("at: job %s will run at %s (%s)",
         path:match("([^/]+)$"), os.date("%Y-%m-%d %H:%M:%S", epoch), kind))
    return 0
end

-- cronlog [-n N] [-u USER] [FILTER]
-- Reads /var/log/cron.log. -u USER keeps the lines of one user, FILTER keeps
-- the lines containing the text (a command fragment works), --archive N reads
-- the rotated generation N instead of the live file.
BUILTINS["cronlog"] = function(args, stage)
    local n, user, archive, filter = 20, nil, nil, nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-n" then
            n = tonumber(args[i + 1]) or n
            i = i + 1
        elseif a == "-u" then
            user = args[i + 1]
            i = i + 1
        elseif a == "--archive" or a == "-a" then
            archive = tonumber(args[i + 1]) or 1
            i = i + 1
        elseif a == "-h" or a == "--help" then
            emit(stage, "usage: cronlog [-n N] [-u USER] [--archive N] [FILTER]")
            return 0
        else
            filter = a
        end
        i = i + 1
    end

    if user then
        local want = "user=" .. user
        if filter then
            if not filter:find(want, 1, true) then return 0 end
        else
            filter = want
        end
    end

    local lines
    if archive then
        local lr = require("logrotate")
        lines = lr.read_archive(cron.log_file, archive, n) or {}
        if #lines == 0 then
            emit(stage, "cronlog: no rotated log " .. tostring(archive))
            return 0
        end
    else
        lines = cron.logs(n, filter)
    end
    if #lines == 0 then
        emit(stage, "cronlog: no log entries")
        return 0
    end
    for _, line in ipairs(lines) do emit(stage, line) end
    return 0
end

-- ---- Peripherals and services ----

-- disk: state of the removable media, automount switch and a manual scan.
BUILTINS["disk"] = function(args, stage)
    local ok, disk = pcall(require, "disk")
    if not ok or not disk then
        emit(stage, "disk: lib/disk.lua is not available")
        return 1
    end
    return disk.main(args, module_stage(stage))
end

-- service: /etc/rc.d units (start, stop, restart, status, boot, shutdown, log).
BUILTINS["service"] = function(args, stage)
    local ok, svc = pcall(require, "services")
    if not ok or not svc then
        emit(stage, "service: lib/services.lua is not available")
        return 1
    end
    return svc.main(args, module_stage(stage))
end

-- logrotate: limits, current sizes and manual cuts of the log files.
BUILTINS["logrotate"] = function(args, stage)
    local ok, lr = pcall(require, "logrotate")
    if not ok or not lr then
        emit(stage, "logrotate: lib/logrotate.lua is not available")
        return 1
    end
    return lr.main(args, module_stage(stage))
end

BUILTINS["env"] = function(args, stage)
    for _, item in ipairs(vars.env()) do
        emit(stage, item.name .. "=" .. item.value)
    end
    return 0
end
BUILTINS["path"] = function(args, stage)
    for _, d in ipairs(require("path").dirs()) do emit(stage, d) end
    return 0
end

-- ---- Shell variables ----
-- set                     the variables, one "NAME=value" per line
-- set NAME=value ...      give a variable a value
-- set -e / set +e         end the shell when a command fails, and stop that
-- set -u / set +u         an undefined variable is a fault, and stop that
-- set -x / set +x         write every command out before it runs, and stop that
-- set -o pipefail         a pipeline fails with its first failing stage
-- set -o / set +o         the options, one line each ("set +o" writes them as
--                         the commands that put them back)
--
-- The options may be written together ("set -eu"), by their long name ("set
-- -o errexit") or with a "+" to turn them off, and an assignment may stand
-- beside them ("set -e NAME=value"), the way POSIX reads it.
BUILTINS["set"] = function(args, stage)
    if #args == 0 then
        for _, name in ipairs(vars.names()) do
            emit(stage, name .. "=" .. tostring(vars.get(name)))
        end
        return 0
    end
    local list_long = false
    local list_commands = false
    local status = 0
    local end_of_options = false
    local i = 1
    while i <= #args do
        local a = args[i]
        if not end_of_options and a == "--" then
            -- "set --" ends the options, so that a name that starts with a
            -- dash is still read as a name.
            end_of_options = true
            i = i + 1
        elseif not end_of_options and (a == "-o" or a == "+o") then
            local want = (a == "-o")
            local name = args[i + 1]
            if name == nil then
                -- "set -o" and "set +o" with no name list the options: the
                -- first writes their state, the second the command that puts
                -- each of them back.
                list_long = true
                list_commands = not want
                i = i + 1
            else
                local opt = SET_OPTIONS.by_name[name]
                if opt then
                    local ok_set, set_status = SET_OPTIONS.set(opt, want, stage)
                    if not ok_set then status = set_status end
                else
                    emit(stage, "set: " .. name .. ": invalid option name")
                    status = 1
                end
                i = i + 2
            end
        elseif not end_of_options and a:match("^[%-%+][%a]+$") then
            -- "set -eux" and "set +eux": the letters of the options, in any
            -- number.
            local enable = a:sub(1, 1) == "-"
            local bad = nil
            for k = 2, #a do
                local letter = a:sub(k, k)
                local opt = SET_OPTIONS.by_letter[letter]
                if opt then
                    local ok_set, set_status = SET_OPTIONS.set(opt, enable, stage)
                    if not ok_set then status = set_status end
                else
                    bad = letter
                end
            end
            if bad then
                emit(stage, "set: -" .. bad .. ": invalid option")
                status = 1
            end
            i = i + 1
        else
            local name, value = a:match("^([%a_][%w_]*)=(.*)$")
            if name then
                vars.set(name, value)
            elseif a:match("^[%a_][%w_]*$") then
                -- "set NAME" with no value shows the one variable, when it is
                -- set; an unset name writes nothing.
                local value = vars.get(a)
                if value ~= nil then emit(stage, a .. "=" .. tostring(value)) end
            else
                emit(stage, "set: usage: set [-eux] [-o option] [NAME=value ...]")
                status = 1
            end
            i = i + 1
        end
    end
    if list_long then
        for _, opt in ipairs(SET_OPTIONS.list) do
            if list_commands then
                emit(stage, SET_OPTIONS.command(opt))
            else
                emit(stage, SET_OPTIONS.line(opt))
            end
        end
    end
    return status
end

BUILTINS["export"] = function(args, stage)
    if #args == 0 then
        for _, item in ipairs(vars.env()) do
            emit(stage, "export " .. item.name .. "=" .. item.value)
        end
        return 0
    end
    local status = 0
    local unexport = false
    for _, a in ipairs(args) do
        local name, value = a:match("^([%a_][%w_]*)=(.*)$")
        if a == "-n" then
            unexport = true
        elseif name then
            vars.set(name, value)
            vars.set_exported(name, not unexport)
        elseif a:match("^[%a_][%w_]*$") then
            vars.export(a)
            vars.set_exported(a, not unexport)
        else
            emit(stage, "export: invalid name: " .. a)
            status = 1
        end
    end
    return status
end

BUILTINS["unset"] = function(args, stage)
    if #args == 0 then
        emit(stage, "unset: usage: unset NAME...")
        return 1
    end
    local status = 0
    for _, a in ipairs(args) do
        if not vars.unset(a) then
            emit(stage, "unset: cannot unset " .. a)
            status = 1
        end
    end
    return status
end

-- ---- Aliases ----
BUILTINS["alias"] = function(args, stage)
    if #args == 0 then
        for _, name in ipairs(alias.names()) do
            emit(stage, "alias " .. name .. "='" .. tostring(alias.get(name)) .. "'")
        end
        return 0
    end
    local status = 0
    for _, a in ipairs(args) do
        local name, value = a:match("^([^=]+)=(.*)$")
        if name then
            local ok, err = alias.define(name, value)
            if not ok then
                emit(stage, err)
                status = 1
            end
        else
            local body = alias.get(a)
            if body then
                emit(stage, "alias " .. a .. "='" .. body .. "'")
            else
                emit(stage, "alias: " .. a .. ": not found")
                status = 1
            end
        end
    end
    refresh_complete_ctx()
    return status
end

BUILTINS["unalias"] = function(args, stage)
    if #args == 0 then
        emit(stage, "unalias: usage: unalias [-a] name...")
        return 1
    end
    local status = 0
    for _, a in ipairs(args) do
        if a == "-a" then
            alias.remove_all()
        elseif not alias.remove(a) then
            emit(stage, "unalias: " .. a .. ": not found")
            status = 1
        end
    end
    refresh_complete_ctx()
    return status
end

-- ---- History ----
BUILTINS["history"] = function(args, stage)
    if args[1] == "-c" then
        history.clear()
        return 0
    end
    local list = history.all()
    local want = tonumber(args[1])
    local first = 1
    if want and want > 0 then first = math.max(1, #list - want + 1) end
    for i = first, #list do
        emit(stage, string.format("%4d  %s", i, list[i]))
    end
    return 0
end

-- ---- Prompt themes (lib/theme.lua) ----
-- A theme is one prompt template. The two built-in ones are dark (the default)
-- and light, /etc/theme.conf may replace them and add more, and PS1 wins while
-- it is set. Selecting a theme changes the session only, "theme save" is the
-- one writer of the file and asks before it writes (see "man theme.conf").
BUILTINS["theme"] = function(args, stage)
    local action = args[1]

    if action == "-h" or action == "--help" then
        emit(stage, "usage: theme            show the current theme")
        emit(stage, "       theme -l         list the themes")
        emit(stage, "       theme -c [NAME]  print the template of a theme")
        emit(stage, "       theme NAME       use NAME for this session")
        emit(stage, "       theme -d [NAME]  back to the built-in templates")
        emit(stage, "       theme save [-f]  write " .. theme.CONF)
        return 0
    end

    if action == nil then
        emit(stage, "theme: " .. tostring(theme.current()))
        emit(stage, "file:  " .. tostring(theme.source() or "(built-in defaults)"))
        local ps1 = vars.get("PS1")
        if type(ps1) == "string" and ps1 ~= "" then
            emit(stage, "PS1:   " .. ps1 .. "   (wins over the theme)")
        end
        emit(stage, "prompt: " .. theme.render(nil, vars.get).plain)
        for _, line in ipairs(theme.warnings()) do
            emit(stage, "warning: " .. line)
        end
        return 0
    end

    if action == "-l" or action == "--list" then
        for _, name in ipairs(theme.names()) do
            local mark = (name == theme.current()) and "*" or " "
            emit(stage, string.format("%s %-8s %s", mark, name, theme.template(name)))
        end
        return 0
    end

    if action == "-c" or action == "--cat" then
        local name = args[2] or theme.current()
        if not theme.exists(name) then
            emit(stage, "theme: " .. tostring(name) .. ": no such theme")
            return 1
        end
        emit(stage, theme.template(name))
        return 0
    end

    if action == "-d" or action == "--default" then
        local name = args[2]
        if name and not theme.builtin(name) then
            emit(stage, "theme: " .. tostring(name) .. ": no built-in theme")
            return 1
        end
        theme.reset()
        if name then theme.select(name) end
        emit(stage, "theme: built-in templates, " .. tostring(theme.current()) ..
                    " is current (the next shell reads " .. theme.CONF .. " again)")
        return 0
    end

    if action == "save" then
        local flag = args[2]
        if flag ~= nil and flag ~= "-f" and flag ~= "--force" then
            emit(stage, "theme: unknown option " .. tostring(flag))
            return 1
        end
        if flag == nil then
            io.write("write " .. theme.CONF .. " (y/N)? ")
            local answer = string.lower(safe_read() or "")
            if answer ~= "y" and answer ~= "yes" then
                emit(stage, "theme: nothing written")
                return 1
            end
        end
        local ok, err = theme.save()
        if not ok then
            emit(stage, "theme: " .. tostring(err))
            return 1
        end
        emit(stage, "theme: wrote " .. theme.CONF)
        return 0
    end

    if action:sub(1, 1) == "-" then
        emit(stage, "theme: unknown option " .. action)
        return 1
    end

    local ok, err = theme.select(action)
    if not ok then
        emit(stage, "theme: " .. tostring(err))
        return 1
    end
    emit(stage, "theme: " .. action .. " is current for this session")
    return 0
end

-- ---- Startup scripts ----
-- run_script_file() lives in the control flow layer: a script is tokenized as
-- one piece of text, so "if ...; then ...; fi" spread over several lines works
-- in /etc/profile and ~/.ushrc as well.

BUILTINS["source"] = function(args, stage)
    if not args[1] then
        emit(stage, "source: usage: source FILE")
        return 1
    end
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    return run_script_file(resolve_path(args[1]), false, rest)
end
BUILTINS["."] = BUILTINS["source"]

-- ---- Utilities ----
BUILTINS["echo"] = function(args, stage) emit(stage, table.concat(args, " ")) end
BUILTINS["sleep"] = function(args) os.sleep(tonumber(args[1]) or 1) end
BUILTINS["seq"] = function(args, stage)
    local first, step, last = 1, 1, nil
    if #args == 1 then last = tonumber(args[1])
    elseif #args == 2 then first, last = tonumber(args[1]), tonumber(args[2])
    elseif #args == 3 then
        first, step, last = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    end
    if not last then return end
    for i = first, last, step do emit(stage, tostring(i)) end
end
BUILTINS["yes"] = function(args, stage)
    local t = args[1] or "y"
    for i = 1, (stage.redirect and 1000 or 20) do emit(stage, t) end
end
BUILTINS["true"]  = function() return 0 end
BUILTINS["false"] = function() return 1 end

-- ---- Control flow ----
-- "test" and "[" share the evaluator of lib/cond.lua, so
-- "if test $a -eq 3; then ..." and "[ $a -eq 3 ] && ..." always agree.
local function run_cond(args, stage, name)
    local value, err = cond.eval(args, nil)
    if value == nil then
        emit(stage, name .. ": " .. tostring(err))
        return 2
    end
    if value then return 0 end
    return 1
end

BUILTINS["test"] = function(args, stage)
    return run_cond(args, stage, "test")
end

BUILTINS["["] = function(args, stage)
    if #args == 0 or args[#args] ~= "]" then
        emit(stage, "[: missing ']'")
        return 2
    end
    local inner = {}
    for i = 1, #args - 1 do inner[i] = args[i] end
    return run_cond(inner, stage, "[")
end

-- Control transfer. These built-ins raise a control table that the construct
-- in charge catches: the loop runner catches break/continue, call_function
-- catches return, run_script_text catches return and exit.
BUILTINS["exit"] = function(args)
    local code = 0
    if args[1] then
        local n = tonumber(args[1])
        if not n then
            write_stdout("exit: " .. tostring(args[1]) ..
                         ": numeric argument required")
            code = 2
        else
            code = math.floor(n) % 256
        end
    end
    error({ __ush_exit = code }, 0)
end

BUILTINS["return"] = function(args)
    if params.depth() <= 1 then
        write_stdout("return: not inside a script, a sourced file or a function")
        return 1
    end
    local code = 0
    if args[1] then
        local n = tonumber(args[1])
        if not n then
            write_stdout("return: " .. tostring(args[1]) ..
                         ": numeric argument required")
            return 2
        end
        code = math.floor(n) % 256
    end
    error({ __ush_return = code }, 0)
end

BUILTINS["break"] = function()
    error({ __ush_break = true }, 0)
end

BUILTINS["continue"] = function()
    error({ __ush_continue = true }, 0)
end

BUILTINS["shift"] = function(args, stage)
    local ok, err = params.shift(args[1])
    if not ok then
        emit(stage, "shift: " .. tostring(err))
        return 1
    end
    return 0
end

-- ---- Archive ----
BUILTINS["tar"] = function(args, stage)
    local mode, archive_arg, files = nil, nil, {}
    for i, a in ipairs(args) do
        if a == "-cf" then mode, archive_arg = "create", args[i + 1]
        elseif a == "-xf" then mode, archive_arg = "extract", args[i + 1]
        elseif a ~= archive_arg then table.insert(files, a) end
    end
    local archive = archive_arg and resolve_path(archive_arg) or nil
    local space_api = require("space")
    if mode == "create" then
        local entries = {}
        for _, p in ipairs(files) do
            local rp = resolve_path(p)
            local f = fs.open(rp, "r")
            if f then entries[rp] = f.readAll(); f.close() end
        end
        -- The serialized form is built once so that its size can be measured
        -- before the archive is truncated (the reason string for a refusal has to
        -- name the real number, not an estimate).
        local blob = textutils.serialize(entries)
        local room, why = space_api.need(archive, #blob)
        if not room then
            emit(stage, "tar: " .. tostring(archive_arg) .. ": " .. why)
            return 1
        end
        local out = fs.open(archive, "w")
        out.write(blob); out.close()
    elseif mode == "extract" then
        local f = fs.open(archive, "r")
        if f then
            local entries = textutils.unserialize(f.readAll()) or {}
            f.close()
            -- The whole archive is measured before the first entry is written:
            -- an extraction that fits three of four entries is worse than a
            -- refusal, because the directory now looks populated.
            local total = 0
            for _, content in pairs(entries) do
                total = total + #tostring(content)
            end
            local room, why = space_api.need_tree(archive, total)
            if not room then
                emit(stage, "tar: " .. tostring(archive_arg) .. ": " .. why)
                return 1
            end
            for name, content in pairs(entries) do
                local p = resolve_path(name)
                local entry_room, entry_why = space_api.need(p, #tostring(content))
                if not entry_room then
                    emit(stage, "tar: " .. tostring(name) .. ": " .. entry_why)
                    return 1
                end
                local w = fs.open(p, "w"); w.write(content); w.close()
                emit(stage, p)
            end
        end
    else
        emit(stage, "usage: tar -cf archive files | tar -xf archive")
    end
end
-- ============================================================
-- User and privilege commands
-- ============================================================

BUILTINS["which"] = function(args, stage)
    local name = args[1]
    if not name then emit(stage, "usage: which <cmd>") return end
    if BUILTINS[name] then emit(stage, name .. ": shell builtin"); return end
    if FUNCTIONS and FUNCTIONS[name] then
        emit(stage, name .. ": shell function"); return
    end
    local full = require("path").find(name)
    if full then emit(stage, full)
    else emit(stage, name .. ": not found") end
end

BUILTINS["help"] = function(args, stage)
    if args[1] then
        -- help NAME prints the same page as man NAME, so there is one place
        -- that owns the manual text (lib/man.lua).
        return require("man").main(args, stage)
    end
    -- A translated heading, and the English list below it. The list is command
    -- NAMES and short English group words: a name cannot be translated (typing
    -- the Chinese word for "file" would not run ls), and the groups are one word
    -- each, so they stay in English rather than becoming a Chinese column that no
    -- command answers to. What the interface can honestly translate here is the
    -- heading and the hint that tells the operator how to get more.
    if require("lang").get() ~= "en" then
        emit(stage, require("lang").text("help_title"))
        emit(stage, require("lang").text("help_more"))
    end
    local lines = {
        "Files:     ls cd pwd cat echo mkdir rm rmdir mv cp touch head tail wc",
        "           grep sort uniq cut tr tac rev find which man stat du file ln",
        "Monitor:   df free ps top uptime",
        "Mounts:    mount umount   (disks automount on disk/disk_eject)",
        "Devices:   disk           (media, mount points, automount switch)",
        "Services:  service        (/etc/rc.d units, start at boot)",
        "Logs:      logrotate      (limits, generations, manual cut)",
        "Schedule:  crontab at cronlog   (-u USER, @reboot, execution log)",
        "Network:   ping netstat netsend netrecv netopen netclose",
        "           rget rput rexec   (rednet file transfer and remote run)",
        "Jobs:      jobs fg bg kill disown   (cmd & runs it in the background)",
        "Util:      env path basename dirname seq sleep yes true false tar",
        "Packages:  pkg update/upgrade/search/install/remove/purge/clean/list",
        "           or apt   upgrade [-f] reinstalls, list -u shows upgrades",
        "           install/remove/purge/update/upgrade need root - use sudo",
        "Control:   if/elif/else/fi  for  while  until  case/esac  { ... ; }",
        "           function name() { ... }  break continue return shift test [",
        "Args:      $0 $1..$9 $# $@ $* shift   (scripts and functions)",
        "Accounts:  passwd useradd userdel usermod groupadd groupdel gpasswd",
        "           su sudo su -c sudo -u sudo -k sudo -l sudo -n",
        "Session:   who w last lastlog",
        "Shell:     set export unset alias unalias history source theme help",
        "           clear date whoami hostname uname id   (help NAME or man NAME)",
        "Admin:     reboot [bios]  bios  audit [n]  resetfirstboot [-f]  exit",
    }
    for _, l in ipairs(lines) do emit(stage, l) end
end

-- man(8): the manual pages themselves live in lib/man.lua, this is only the
-- shell entry point. help NAME goes through the same table.
BUILTINS["man"] = function(args, stage)
    return require("man").main(args, stage)
end

-- lang(1): which language the interface speaks, and whether it can speak it.
--
-- WHY A COMMAND AND NOT A SETTING FILE. The operator has to be able to ask "why
-- is this still English?" at the moment the question occurs, and the answer is
-- one of two concrete things (the renderer is not on this machine / the glyph
-- medium is not inserted). A configuration file alone would answer neither.
--
-- THE TWO ARGUMENTS ARE DELIBERATELY DIFFERENT IN SCOPE. "lang zh" switches THIS
-- session and needs no privilege: it is a view preference, and making it root
-- only would mean a user cannot read the machine in their own language.
-- "lang --save zh" decides for every future boot, so it is root only, the same
-- split as "desktop --autostart".
BUILTINS["lang"] = function(args, stage)
    local lang = require("lang")
    local save, want = false, nil
    for _, a in ipairs(args) do
        if a == "--save" then
            save = true
        elseif a == "-h" or a == "--help" then
            emit(stage, lang.text("lang_usage"))
            return 0
        elseif want == nil then
            want = a
        else
            emit(stage, lang.text("lang_usage"))
            return 2
        end
    end

    if want == nil and not save then
        -- status: what is on, what could be, and if not, why not.
        emit(stage, lang.text("lang_now") .. ": " .. lang.get())
        for _, code in ipairs(lang.LANGUAGES) do
            local ok, why = lang.available(code)
            local state
            if code == "en" then
                state = "always"
            elseif ok then
                state = lang.text("lang_fonts_ok")
            else
                state = lang.text("lang_fonts_no") .. " (" .. tostring(why) .. ")"
            end
            emit(stage, "  " .. code .. "  " .. state)
        end
        return 0
    end

    if want == nil then
        emit(stage, lang.text("lang_usage"))
        return 2
    end

    local ok, why = lang.set(want)
    if not ok then
        -- Two different refusals, two different sentences: an unknown code is a
        -- typo, a known code that cannot run is a missing medium. Saying
        -- "unknown language" for the second would send the operator looking for
        -- a spelling mistake that is not there.
        if lang.available(want) == false and want ~= "en" and want ~= "zh" then
            emit(stage, "lang: " .. lang.text("lang_unknown") .. ": " .. tostring(want))
        else
            emit(stage, "lang: " .. tostring(why))
            if want == "zh" then emit(stage, "lang: " .. lang.text("lang_no_font")) end
        end
        return 1
    end

    if save then
        local is_root = (perm.get_current_user() == "root")
        if not is_root then
            emit(stage, "lang: " .. lang.text("lang_need_root") .. " (sudo lang --save " .. want .. ")")
            return 1
        end
        local saved, serr = lang.save(want)
        if not saved then
            emit(stage, "lang: " .. tostring(serr))
            return 1
        end
        emit(stage, lang.text("lang_set") .. " " .. want .. " (" .. lang.text("lang_saved") .. ")")
    else
        emit(stage, lang.text("lang_set") .. " " .. want)
    end
    return 0
end

BUILTINS["passwd"] = function(args, stage)
    local policy = require("policy")
    local target = args[1] or perm.get_current_user()
    local actor = perm.get_current_user()
    local proved = nil          -- the old password, when an account change needs one

    if not perm.user_exists(target) then
        emit(stage, "passwd: user " .. target .. " does not exist"); return
    end
    if actor ~= "root" and target ~= actor then
        audit.log({ actor = actor, action = "passwd", target = target,
                    result = "denied", note = "not root" })
        emit(stage, "passwd: permission denied"); return
    end

    if actor ~= "root" then
        io.write("Current password: ")
        local old = safe_read_password() or ""
        if not perm.check_password(actor, old) then
            audit.log({ actor = actor, action = "passwd", target = target,
                        result = "denied", note = "bad old password" })
            emit(stage, "passwd: authentication failure"); return
        end
        -- perm.set_password re-checks this one: it writes the shadow file through
        -- the unguarded open, so the rule is enforced there as well.
        proved = old
    end

    while true do
        io.write("New password: ")
        local p1 = safe_read_password() or ""
        if #p1 == 0 then
            emit(stage, "passwd: password cannot be empty"); return
        end
        local ok, reason = policy.check_password(p1)
        if not ok then
            emit(stage, "passwd: " .. reason)
        else
            io.write("Retype new password: ")
            local p2 = safe_read_password() or ""
            if p1 == p2 then
                local saved, why = perm.set_password(target, p1, proved)
                if not saved then
                    emit(stage, "passwd: " .. tostring(why)); return
                end
                audit.log({ actor = actor, action = "passwd",
                            target = target, result = "granted" })
                emit(stage, "passwd: password updated successfully")
                return
            else
                emit(stage, "passwd: passwords do not match")
            end
        end
    end
end

BUILTINS["useradd"] = function(args, stage)
    local name, opts = nil, { level = 0, groups = nil, password = "" }
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-g" then opts.groups = args[i + 1]; i = i + 2
        elseif a == "-p" then opts.password = args[i + 1] or ""; i = i + 2
        elseif a == "-u" then opts.level = tonumber(args[i + 1]) or 0; i = i + 2
        elseif a:sub(1, 1) == "-" then
            emit(stage, "useradd: unknown option " .. a); return
        else name = a; i = i + 1 end
    end
    if not name then emit(stage, "usage: useradd [-g group] [-p pwd] [-u level] name"); return end
    local ok, err = perm.add_user(name, opts)
    local actor = perm.get_current_user()
    if ok then
        audit.log({ actor = actor, action = "useradd", target = name, result = "granted" })
        emit(stage, "useradd: user " .. name .. " added")
    else
        audit.log({ actor = actor, action = "useradd", target = name,
                    result = "denied", note = err })
        emit(stage, "useradd: " .. err)
    end
end

BUILTINS["userdel"] = function(args, stage)
    local rh, name = false, nil
    for _, a in ipairs(args) do
        if a == "-r" then rh = true else name = a end
    end
    if not name then emit(stage, "usage: userdel [-r] <name>"); return end
    local ok, err = perm.del_user(name, rh)
    local actor = perm.get_current_user()
    if ok then
        audit.log({ actor = actor, action = "userdel", target = name, result = "granted" })
        emit(stage, "userdel: user " .. name .. " removed")
    else
        audit.log({ actor = actor, action = "userdel", target = name,
                    result = "denied", note = err })
        emit(stage, "userdel: " .. err)
    end
end

BUILTINS["usermod"] = function(args, stage)
    local name, opts = nil, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-g" then opts.groups = args[i + 1]; i = i + 2
        elseif a == "-l" then opts.name = args[i + 1]; i = i + 2
        elseif a == "-u" then opts.level = tonumber(args[i + 1]) or 0; i = i + 2
        elseif a:sub(1, 1) == "-" then emit(stage, "usermod: unknown option " .. a); return
        else name = a; i = i + 1 end
    end
    if not name then emit(stage, "usage: usermod [-g group] [-l newname] [-u level] name"); return end
    local ok, err = perm.mod_user(name, opts)
    if ok then emit(stage, "usermod: user " .. name .. " updated")
    else emit(stage, "usermod: " .. err) end
end

BUILTINS["groupadd"] = function(args, stage)
    local name = args[1]
    if not name then emit(stage, "usage: groupadd <group>"); return end
    local ok, err = perm.add_group(name)
    if ok then emit(stage, "groupadd: group " .. name .. " added")
    else emit(stage, "groupadd: " .. err) end
end

BUILTINS["groupdel"] = function(args, stage)
    local name = args[1]
    if not name then emit(stage, "usage: groupdel <group>"); return end
    local ok, err = perm.del_group(name)
    if ok then emit(stage, "groupdel: group " .. name .. " removed")
    else emit(stage, "groupdel: " .. err) end
end

BUILTINS["gpasswd"] = function(args, stage)
    if #args < 3 then emit(stage, "usage: gpasswd {-a|-d} user group"); return end
    local mode, user, group = args[1], args[2], args[3]
    if mode == "-a" then
        perm.add_to_group(user, group)
        emit(stage, "gpasswd: added " .. user .. " to " .. group)
    elseif mode == "-d" then
        perm.remove_from_group(user, group)
        emit(stage, "gpasswd: removed " .. user .. " from " .. group)
    else emit(stage, "gpasswd: unknown mode " .. mode) end
end

BUILTINS["su"] = function(args, stage)
    local login_shell, run_command, target = false, nil, nil
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-" or a == "-l" or a == "--login" then
            login_shell = true; i = i + 1
        elseif a == "-c" then
            run_command = args[i + 1]; i = i + 2
        elseif a:sub(1, 1) == "-" then
            emit(stage, "su: unknown option " .. a); return
        else target = a; i = i + 1 end
    end
    target = target or "root"

    local actor = perm.get_current_user()
    if not perm.user_exists(target) then
        audit.log({ actor = actor, action = "su", target = target,
                    result = "denied", note = "no such user" })
        emit(stage, "su: user " .. target .. " does not exist"); return
    end
    if actor ~= "root" then
        io.write("Password: ")
        local pwd = safe_read_password() or ""
        if not perm.check_password(target, pwd) then
            audit.log({ actor = actor, action = "su", target = target,
                        result = "denied", note = "bad password" })
            emit(stage, "su: authentication failure"); return
        end
    end
    audit.log({ actor = actor, action = "su", target = target,
                result = "granted",
                command = run_command or (login_shell and "login" or nil) })

    if run_command then
        local saved = perm.get_current_user()
        perm.set_current_user(target)
        session_user()
        local words = {}
        for w in run_command:gmatch("%S+") do table.insert(words, w) end
        local inner = { words = words, redirect = nil, append = false,
                        input = nil, _out = stage._out, _in = stage._in }
        pcall(run_stage, inner)
        perm.set_current_user(saved)
        session_user()
    else
        perm.set_current_user(target)
        -- The console changed hands: publish the account as the variables of
        -- the session first, then close the old login record and open a new
        -- one so that "who" reports the user actually using the shell.
        session_user()
        require("sessionlog").switch_user(target, "su")
        emit(stage, "switched to " .. target)
    end
end

BUILTINS["sudo"] = function(args, stage)
    local sc = require("sudocache")
    local target_user, clear_cache, non_interactive, list_only = "root", false, false, false
    local cmd_start = 1
    while cmd_start <= #args do
        local a = args[cmd_start]
        if a == "-u" then target_user = args[cmd_start + 1]; cmd_start = cmd_start + 2
        elseif a == "-k" then clear_cache = true; cmd_start = cmd_start + 1
        elseif a == "-n" then non_interactive = true; cmd_start = cmd_start + 1
        elseif a == "-l" then list_only = true; cmd_start = cmd_start + 1
        elseif a == "--" then cmd_start = cmd_start + 1; break
        elseif a:sub(1, 1) == "-" then
            emit(stage, "sudo: unknown option " .. a); return
        else break end
    end

    local actor = perm.get_current_user()

    if clear_cache then
        sc.clear(actor)
        audit.log({ actor = actor, action = "sudo", target = "-", result = "cache-cleared" })
        emit(stage, "sudo: authentication cache cleared for " .. actor)
        if cmd_start > #args then return end
    end

    if list_only then
        if actor ~= "root" and not perm.is_sudoer(actor) then
            emit(stage, "sudo: " .. actor .. " is not in the sudoers file"); return
        end
        local rules = require("sudorules").for_user(actor)
        emit(stage, "User " .. actor .. " may run the following commands:")
        if #rules > 0 then
            for _, line in ipairs(rules) do emit(stage, "    " .. line) end
        else
            emit(stage, "    (ALL : ALL) ALL")
        end
        return
    end

    if cmd_start > #args then
        emit(stage, "usage: sudo [-u user] [-k] [-n] [-l] <command> [args...]")
        return
    end

    if not perm.user_exists(target_user) then
        emit(stage, "sudo: unknown user: " .. target_user); return
    end

    local rule_note = nil
    if actor ~= "root" then
        -- Fine grained rules from /etc/sudo.conf are checked first. check()
        -- answers true (rule matched), false (rules exist for this user but
        -- none matches) or nil (no rule at all: fall back to /etc/sudoers).
        local pathlib = require("path")
        local name = args[cmd_start]
        local is_builtin = BUILTINS[name] ~= nil
        local resolved = nil
        if not is_builtin then
            if name:find("/", 1, true) then
                -- The command was given as a path: resolve it like the
                -- executor does, accepting the deployed command file with or
                -- without its ".lua" extension.
                local abs = resolve_path(name)
                if fs.exists(abs) then resolved = abs
                elseif fs.exists(abs .. ".lua") then resolved = abs end
            else
                resolved = pathlib.find(name)
            end
            if not resolved then
                local ok, pkgmod = pcall(require, "pkg")
                if ok then resolved = pkgmod.resolve_command(name) end
            end
        end

        local allowed, reason = require("sudorules").check(
            actor, target_user, resolved, name, is_builtin)

        if allowed == false then
            audit.log({ actor = actor, action = "sudo", target = target_user,
                        result = "denied", note = tostring(reason),
                        command = table.concat(args, " ", cmd_start) })
            emit(stage, "sudo: " .. actor .. " is not allowed to run '" ..
                 tostring(name) .. "' as " .. target_user .. " on this host.")
            return
        end

        if allowed == true then rule_note = tostring(reason) end

        if allowed == nil and not perm.is_sudoer(actor) then
            audit.log({ actor = actor, action = "sudo", target = target_user,
                        result = "denied", note = "not in sudoers",
                        command = table.concat(args, " ", cmd_start) })
            emit(stage, "sudo: " .. actor .. " is not in the sudoers file.")
            return
        end
        if not sc.is_valid(actor) then
            if non_interactive then
                emit(stage, "sudo: a password is required"); return
            end
            -- The password sudo asks for is the ROOT account's, not the caller's:
            -- this machine has one privileged credential and it belongs to root.
            -- The cached approval (sudocache) stays per actor -- it records that
            -- this caller was authenticated recently, not how they proved it.
            io.write("[sudo] password for root: ")
            local pwd = safe_read_password() or ""
            if not perm.check_password("root", pwd) then
                audit.log({ actor = actor, action = "sudo", target = target_user,
                            result = "denied", note = "bad password" })
                emit(stage, "sudo: authentication failure"); return
            end
            sc.touch(actor)
        end
    end

    local cmdline = table.concat(
        (function()
            local t = {}; for i = cmd_start, #args do t[#t+1] = args[i] end; return t
        end)(), " ")
    audit.log({ actor = actor, action = "sudo", target = target_user,
                result = "granted", command = cmdline, note = rule_note })

    local saved = perm.get_current_user()
    perm.set_current_user(target_user)
    session_user()
    local words = {}
    for i = cmd_start, #args do table.insert(words, args[i]) end
    local inner = { words = words, redirect = nil, append = false,
                    input = nil, _out = stage._out, _in = stage._in }
    pcall(run_stage, inner)
    perm.set_current_user(saved)
    session_user()
end

BUILTINS["audit"] = function(args, stage)
    local n = tonumber(args[1]) or 20
    for _, line in ipairs(audit.tail(n)) do emit(stage, line) end
end

-- reboot [bios] - restart the computer, optionally straight into the setup screen.
--
-- This REPLACES the old "craftos" command. That command dropped to the CraftOS
-- shell by asking startup.lua to stop relaunching ush; it was the only way out of
-- the shell and it was a poor one: it left the machine running something this
-- project does not manage, so the operator lost the rules they had set (the boot
-- guard, noexit) along with the shell. Rebooting is the honest operation -- the
-- machine comes back up through startup.lua, with the BIOS window in front of it
-- exactly as after a power cycle -- and "reboot bios" reaches the setup screen
-- without racing the three second window.
--
-- os.reboot() is the CC:Tweaked API call (rom/programs/reboot.lua uses it). It
-- does not return: the whole Lua state is torn down and startup.lua runs again
-- from the top.
BUILTINS["reboot"] = function(args, stage)
    local actor = perm.get_current_user()
    if actor ~= "root" then
        audit.log({ actor = actor, action = "reboot", target = "-",
                    result = "denied", note = "not root" })
        emit(stage, "reboot: must be root")
        return 1
    end

    local to_bios = false
    local force = false
    for _, a in ipairs(args) do
        if a == "bios" then to_bios = true
        elseif a == "-f" or a == "--force" then force = true
        elseif a == "shutdown" or a == "halt" or a == "poweroff" then
            -- A restart is what this command is for; shutting down is a different
            -- act with a different outcome, so it is refused rather than guessed.
            emit(stage, "reboot: shutdown is not this command; use shutdown")
            return 1
        end
    end

    -- The noexit rule is a rule about the session, and a reboot ends the session.
    -- Refusing here would be the only consistent reading: a machine that may not
    -- be left is a machine that may not be restarted from the shell either.
    if SHELL.interactive and protect.no_exit() and not force then
        emit(stage, "reboot: the shell is not allowed to be left on this " ..
                    "machine (set +o noexit as root to allow it, or reboot -f)")
        return 1
    end

    if not force then
        io.write(to_bios and "Restart into the BIOS setup screen? [y/N] "
                            or "Restart the computer? [y/N] ")
        local ans = (safe_read() or ""):lower()
        if ans ~= "y" and ans ~= "yes" then
            emit(stage, "reboot: cancelled")
            return 1
        end
    end

    -- The flag is written before the reboot, so the setup screen is already armed
    -- when startup.lua next runs. It is a one shot: lib/bios.lua consumes it, so a
    -- machine left unattended does not come up in setup after an unrelated reboot.
    if to_bios then
        local okb, bios = pcall(require, "bios")
        if okb and type(bios) == "table" and bios.arm_setup then
            bios.arm_setup()
        else
            emit(stage, "reboot: cannot arm the setup screen: " .. tostring(bios))
            return 1
        end
    end

    audit.log({ actor = actor, action = "reboot",
                target = to_bios and "bios" or "-", result = "granted" })
    emit(stage, to_bios and "Restarting into the BIOS setup screen..."
                        or "Restarting...")
    -- Flush anything buffered before the state goes away, so the message is seen.
    local okr, err = pcall(os.reboot)
    if not okr then
        emit(stage, "reboot: " .. tostring(err))
        return 1
    end
    -- os.reboot does not return on a real machine. If it somehow does, do not
    -- report success for a restart that did not happen.
    return 0
end

-- bios - open the setup screen from inside the shell.
--
-- The same screen the three second window at power on offers, reachable without a
-- reboot. It exists because the settings it changes are the ones that decide
-- whether the shell may be left or a boot file overwritten, and needing a reboot
-- to change a rule about reboots is a poor trade.
--
-- The screen itself checks the BIOS password (lib/bios.lua), so this built-in does
-- not repeat that check: the rule and its enforcement stay in one place.
BUILTINS["bios"] = function(args, stage)
    local ok, bios = pcall(require, "bios")
    if not ok or type(bios) ~= "table" then
        emit(stage, "bios: the setup screen is not available: " .. tostring(bios))
        return 1
    end
    local actor = perm.get_current_user()
    audit.log({ actor = actor, action = "bios", target = "setup",
                result = "granted" })
    -- skip_window: the DEL prompt is a power on thing, and asking for it here
    -- would just make the user wait three seconds for a screen they asked for.
    local ran, err = pcall(bios.run, { skip_window = true })
    if not ran then
        emit(stage, "bios: " .. tostring(err))
        return 1
    end
    return 0
end

BUILTINS["resetfirstboot"] = function(args, stage)
    local marker = require("marker")
    local actor = perm.get_current_user()

    if actor ~= "root" then
        audit.log({ actor = actor, action = "resetfirstboot",
                    target = "-", result = "denied", note = "not root" })
        emit(stage, "resetfirstboot: must be root")
        return
    end

    local force = false
    for _, a in ipairs(args) do
        if a == "-f" or a == "--force" then force = true end
    end

    if not force then
        io.write("Erase first-boot markers? This will allow setup again. [y/N] ")
        local ans = (safe_read() or ""):lower()
        if ans ~= "y" and ans ~= "yes" then
            emit(stage, "resetfirstboot: cancelled")
            return
        end
    end

    io.write("Root password: ")
    local pwd = safe_read_password() or ""
    if not perm.check_password("root", pwd) then
        audit.log({ actor = actor, action = "resetfirstboot",
                    target = "-", result = "denied",
                    note = "bad root password" })
        emit(stage, "resetfirstboot: authentication failure")
        return
    end

    marker.clear()
    audit.log({ actor = actor, action = "resetfirstboot",
                target = "-", result = "granted",
                note = "markers cleared; reboot to re-run setup" })
    emit(stage, "Markers cleared. Reboot to run first-boot setup again.")
end

-- ============================================================
-- Package management: pkg and apt
-- ============================================================

-- Packages are unpacked here, so this directory is system territory.
local PKG_STORE = "/usr/pkgs"

-- Subcommands that change the system. Everything else (search, list) is a
-- read and needs no privilege.
local PKG_WRITE_SUBS = {
    install = true, remove = true, purge = true, update = true, upgrade = true,
    clean = true,
}

-- Privilege gate shared by pkg and apt. apt is the same command under a
-- familiar name, so it must have the same threshold and the same message.
-- The effective user comes from lib/perm.lua, which is also the user sudo
-- switches to while it runs: after "sudo pkg install ..." the caller is root,
-- so one identity test covers both "root" and "already elevated by sudo".
-- The mount table (lib/mounts.lua) and the mode bits (lib/perm.lua) are
-- consulted as well, so a read only mount blocks the write even for root and
-- the reason matches what every other tool would report.
local function pkg_gate(name, sub, stage)
    local actor = perm.get_current_user()
    if actor ~= "root" then
        -- The policy sources are the ones the sudo builtin already uses: the
        -- fine grained rules of lib/sudorules.lua (/etc/sudo.conf) first, and
        -- /etc/sudoers through lib/perm.lua when no rule mentions the user.
        local allowed = select(1, require("sudorules").check(
            actor, "root", nil, name, true))
        local can_sudo = allowed == true
            or (allowed == nil and perm.is_sudoer(actor))
        audit.log({ actor = actor, action = "pkg", target = sub,
                    result = "denied", note = "not root" })
        if can_sudo then
            emit(stage, name .. ": " .. sub .. ": permission denied - must be " ..
                 "root, use sudo: \"sudo " .. name .. " " .. sub .. " <name>\"")
        else
            emit(stage, name .. ": " .. sub .. ": permission denied - must be " ..
                 "root (" .. actor .. " may not use sudo)")
        end
        return false
    end
    if mounts.is_readonly(PKG_STORE) then
        emit(stage, name .. ": " .. sub .. ": " .. PKG_STORE ..
             " is on a read-only mount")
        return false
    end
    if not perm.check(PKG_STORE, "w") then
        emit(stage, name .. ": " .. sub .. ": permission denied (write): " ..
             PKG_STORE)
        return false
    end
    audit.log({ actor = actor, action = "pkg", target = sub,
                result = "granted" })
    return true
end

local function run_pkg(name, args, stage)
    local pkg = require("pkg")
    local sub = args[1]
    local usage = "usage: " .. name ..
                  " {update|upgrade [-f]|search|install [--store N]|remove|purge|" ..
                  "clean|list [-u|-s]|requires|store [N ...|remove N|auto|" ..
                  "required|optional|--json]}"

    if sub == nil or sub == "help" then
        emit(stage, usage)
        return 0
    end
    if not (sub == "search" or sub == "list" or sub == "requires" or sub == "store"
            or PKG_WRITE_SUBS[sub]) then
        emit(stage, usage)
        return 1
    end

    if PKG_WRITE_SUBS[sub] and not pkg_gate(name, sub, stage) then
        return 1
    end

    -- Report a failed call to the package server. A machine with no update
    -- server (offline mode, or a server_id that was never set) is a normal
    -- state, not a crash: say what failed, and when the server is simply not
    -- configured, say how to configure one later. The shell stays usable and
    -- nothing waits for a reply that cannot come.
    local function pkg_error(msg)
        emit(stage, "error: " .. tostring(msg))
        if not pkg.server_ready() then
            emit(stage, name .. ": " .. pkg.setup_hint())
        end
        return 1
    end

    if sub == "update" then
        local ok, msg = pkg.update()
        if ok then
            emit(stage, "updated: " .. msg)
            return 0
        end
        return pkg_error(msg)
    elseif sub == "upgrade" then
        -- Version aware: pkg.upgrade() refreshes the index and compares what
        -- is installed with what the repository carries (lib/semver.lua), so a
        -- package that is already current is left alone instead of being
        -- reinstalled. "-f / --all" reinstalls everything, which is what a
        -- repository that publishes no versions needs.
        local force = false
        for i = 2, #args do
            local a = args[i]
            if a == "-f" or a == "--all" or a == "--force" then force = true end
        end
        local ok, report = pkg.upgrade({ all = force })
        if not ok then return pkg_error(report) end
        if report.note then
            emit(stage, "upgrade: " .. report.note)
            return 0
        end
        for _, item in ipairs(report.upgraded) do
            emit(stage, "upgraded " .. item.name .. " " .. item.from .. " -> " ..
                 item.to)
        end
        for _, item in ipairs(report.skipped) do
            -- Only the interesting kind of skip is worth a line; "up to date"
            -- for every installed package would bury the upgrades.
            if item.why ~= "up to date" then
                emit(stage, "kept " .. item.name .. " " .. item.version ..
                     " (" .. item.why .. ")")
            end
        end
        for _, item in ipairs(report.failed) do
            emit(stage, "error: " .. item.name .. ": " .. item.error)
        end
        if (report.pruned or 0) > 0 then
            emit(stage, "cleaned " .. report.pruned ..
                 " file(s) a previous version left behind")
        end
        if (report.unsigned or 0) > 0 then
            emit(stage, report.unsigned .. " package(s) are not signed")
        end
        emit(stage, "upgraded " .. #report.upgraded .. " package(s), " ..
             #report.skipped .. " unchanged, " .. #report.failed .. " failed")
        return #report.failed == 0 and 0 or 1
    elseif sub == "requires" then
        -- What a package needs before it may be installed: a mounted medium
        -- with a marker file, or a file on one. Read only, so no root needed.
        local target = args[2]
        if target == nil or target == "" then
            emit(stage, usage)
            return 1
        end
        local needs, err = pkg.requires(target)
        if not needs then
            return pkg_error(err)
        end
        if #needs == 0 then
            emit(stage, target .. ": no extra requirements")
            return 0
        end
        local all_ok = true
        for _, pair in ipairs(needs) do
            local ok, note = pkg.check_requirements({ pair })
            if not ok then all_ok = false end
            emit(stage, string.format("%-18s %s", pkg.describe_requirement(pair),
                ok and ("ok: " .. tostring(note)) or ("missing: " .. tostring(note))))
        end
        return all_ok and 0 or 1
    elseif sub == "store" then
        -- Which removable media carry this machine's package data, in what
        -- order, and whether the packages have to live on one at all. Reading
        -- needs no privilege; changing it is part of administering the machine,
        -- so it goes through the same gate as the write subcommands.
        --
        --   pkg store                   show the list, the roots and what is on
        --                               each medium
        --   pkg store 2                 make disk 2 an ordinary package store
        --   pkg store 2 3               make both of them stores
        --   pkg store sys 2             make disk 2 the SYSTEM MODULE store
        --   pkg store sys               show the system module store
        --   pkg store sys-required      this machine needs its system store
        --   pkg store sys-optional      it does not
        --   pkg store remove 2          take the marker off disk 2
        --   pkg store auto              take the marker off every medium
        --   pkg store required/optional a medium is required, or is not
        --   pkg store --json            the same, as JSON for a script
        local pkgstore = require("pkg")
        local function human_size(bytes)
            if type(bytes) ~= "number" then return "?" end
            if bytes >= 1048576 then return string.format("%.1fM", bytes / 1048576) end
            if bytes >= 1024 then return string.format("%dK", math.floor(bytes / 1024)) end
            return tostring(bytes) .. "B"
        end
        local function describe(summary_only)
            local report = pkgstore.store_report()
            if #report.stores == 0 then
                emit(stage, "package stores: none (packages are installed on this " ..
                            "computer)")
            else
                -- Each store is labelled with its kind, because the two kinds mean
                -- different things: one is part of the installation, the other is
                -- extra packages. A reader who cannot tell them apart cannot tell
                -- whether the machine is complete.
                local names = {}
                for _, item in ipairs(report.stores) do
                    names[#names + 1] = item.side ..
                        (item.kind == "sys" and " (system modules)" or "")
                end
                emit(stage, "package stores: " .. table.concat(names, ", ") ..
                            (report.required and " (required)" or ""))
            end
            if report.sys_required or report.sys_present then
                emit(stage, "system modules: " ..
                    (report.sys_present and ("on " .. tostring(report.sys_side))
                        or "MISSING") ..
                    (report.sys_required and " (required)" or ""))
            end
            emit(stage, "install root:   " .. tostring(report.install_root))
            if summary_only then return end
            -- What each root holds: a machine with several media is only
            -- understandable when the answer is per medium, not one total.
            local function line(group, label)
                local used = group.capacity and group.free and
                    (group.capacity - group.free) or nil
                local where = label
                if group.capacity then
                    where = where .. "  " .. human_size(used) .. " of " ..
                        human_size(group.capacity)
                end
                where = where .. "  " .. tostring(group.count) .. " package(s)"
                if group.count > 0 then
                    local names = {}
                    for _, p in ipairs(group.packages) do
                        names[#names + 1] = p.name ..
                            (p.version and (" " .. p.version) or "")
                    end
                    where = where .. ": " .. table.concat(names, ", ")
                end
                emit(stage, where)
            end
            for _, store in ipairs(report.stores) do
                line(store, "  " .. tostring(store.side) .. " -> " .. tostring(store.root) ..
                     (store.kind == "sys" and "  (system modules)" or ""))
            end
            line(report.internal, "  this computer -> " .. tostring(report.internal.root))
        end
        if args[2] == nil or args[2] == "" then
            describe(false)
            return 0
        end
        if args[2] == "--json" then
            local text = pkgstore.store_report_json()
            if not text then
                emit(stage, name .. ": store: cannot render json")
                return 1
            end
            emit(stage, text)
            return 0
        end
        if args[2] == "--verbose" or args[2] == "-v" or args[2] == "detail" then
            describe(false)
            return 0
        end
        if not pkg_gate(name, sub, stage) then return 1 end
        local verb = args[2]
        local function report(ok, res, what)
            if not ok then
                emit(stage, name .. ": store: " .. tostring(res))
                return 1
            end
            audit.log({ actor = perm.get_current_user(), action = "pkg",
                        target = "store " .. what .. "=" .. tostring(res),
                        result = "granted" })
            if res == "auto" then
                emit(stage, "package stores: none (packages are installed on this " ..
                            "computer)")
            elseif what == "remove" then
                emit(stage, "package stores: " .. tostring(res) .. " released")
            else
                emit(stage, "package stores: " .. tostring(res))
            end
            return 0
        end
        if verb == "required" or verb == "require" then
            return report(pkgstore.set_store_required(true), "a medium is required",
                          "required on")
        end
        if verb == "optional" or verb == "any" then
            return report(pkgstore.set_store_required(false), "any root is allowed",
                          "required off")
        end
        -- The system module store: the medium carrying .pkgsys, which holds the
        -- modules the shell itself needs. Its own verb because it is not just
        -- another store: naming one is what tells the machine which medium its
        -- own modules live on, and "sys-required" is the rule that makes a
        -- missing one visible instead of silent.
        if verb == "sys" then
            if args[3] == nil then
                local st = pkgstore.sys_status()
                emit(stage, "system module store: " ..
                    (st.present and tostring(st.side) or "none inserted") ..
                    (st.required and " (required)" or ""))
                return 0
            end
            local ok, res = pkgstore.store_claim_sys(args[3])
            return report(ok, res, "sys")
        end
        if verb == "sys-required" or verb == "sysrequire" then
            return report(pkgstore.set_sys_required(true),
                          "the system module store is required", "sys-required on")
        end
        if verb == "sys-optional" then
            return report(pkgstore.set_sys_required(false),
                          "the system module store is optional", "sys-required off")
        end
        if verb == "remove" then
            if args[3] == nil then
                emit(stage, name .. ": store remove: needs a disk number")
                return 1
            end
            local ok, res = pkgstore.store_release(args[3])
            return report(ok, res, "remove")
        end
        if verb == "auto" or verb == "none" then
            return report(pkgstore.store_release_all(), "auto", "auto")
        end
        -- "pkg store <n> [more ...]": make each named medium a store by writing
        -- the marker on it.
        local made = {}
        for i = 2, #args do
            local ok, res = pkgstore.store_claim(args[i])
            if not ok then
                emit(stage, name .. ": store: " .. tostring(res))
                return 1
            end
            made[#made + 1] = res
        end
        return report(true, made[#made], "claim")
    elseif sub == "search" then
        local ok, result = pkg.search(args[2] or "")
        if not ok then return pkg_error(result) end
        for _, e in ipairs(result) do emit(stage, e.name .. " " .. e.version) end
        return 0
    elseif sub == "install" then
        -- "install [--store N] NAME": --store is a one-off choice of medium for
        -- this install, without changing what the machine uses afterwards.
        local given, install_name = {}, nil
        local i = 2
        while args[i] do
            local a = args[i]
            if a == "--store" or a == "-s" then
                local v = args[i + 1]
                if v == nil then
                    emit(stage, name .. ": install: " .. a .. " needs a disk number")
                    return 1
                end
                given.store = v
                i = i + 1
            elseif a:sub(1, 8) == "--store=" then
                given.store = a:sub(9)
            elseif a:sub(1, 1) ~= "-" then
                install_name = a
            else
                emit(stage, name .. ": install: " .. a .. ": unknown option")
                return 1
            end
            i = i + 1
        end
        local ok, msg = pkg.install(install_name, given)
        if ok then emit(stage, tostring(msg)); return 0 end
        return pkg_error(msg)
    elseif sub == "remove" then
        local ok, msg = pkg.remove(args[2])
        if ok then emit(stage, tostring(msg)); return 0 end
        return pkg_error(msg)
    elseif sub == "purge" then
        local ok, msg = pkg.purge(args[2])
        if ok then emit(stage, tostring(msg)); return 0 end
        return pkg_error(msg)
    elseif sub == "clean" then
        local ok, msg = pkg.clean()
        if ok then emit(stage, tostring(msg)); return 0 end
        return pkg_error(msg)
    elseif sub == "list" then
        -- "list -u" narrows the answer to what the cached index carries a
        -- newer version of, which is the version aware half of "upgrade".
        if args[2] == "-u" or args[2] == "--upgradable" then
            local out, err = pkg.upgradable()
            if not out then emit(stage, "error: " .. tostring(err)); return 1 end
            if #out == 0 then emit(stage, name .. ": everything is up to date") end
            for _, item in ipairs(out) do
                emit(stage, item.name .. " " .. item.from .. " -> " .. item.to)
            end
            return 0
        end
        -- "list -s" answers "which medium is this package on", which is the
        -- question a machine with several stores actually has.
        if args[2] == "-s" or args[2] == "--stores" then
            for _, group in ipairs(pkg.list_by_root()) do
                local label = group.removable and
                    (tostring(group.side) .. " (" .. tostring(group.root) .. ")")
                    or ("this computer (" .. tostring(group.root) .. ")")
                if group.count == 0 then
                    emit(stage, label .. ": nothing")
                else
                    local names = {}
                    for _, p in ipairs(group.packages) do
                        names[#names + 1] = p.name ..
                            (p.version and (" " .. p.version) or "")
                    end
                    emit(stage, label .. ": " .. table.concat(names, ", "))
                end
            end
            return 0
        end
        for _, pname in ipairs(pkg.list()) do emit(stage, pname) end
        return 0
    end
    return 0
end

BUILTINS["pkg"] = function(args, stage) return run_pkg("pkg", args, stage) end

-- apt is a front end for the same package manager: same subcommands, same
-- root threshold, same messages.
BUILTINS["apt"] = function(args, stage) return run_pkg("apt", args, stage) end

-- ============================================================
-- Digests, encodings, expressions and machine facts
-- ============================================================

-- -- sha256sum, md5sum, cksum ------------------------------------------------
-- The three digest commands print "<digest>  <name>" with the two spaces GNU
-- uses. The algorithm belongs to the module that owns it; the operands, the
-- standard input and the failure style are the same for all three, so that part
-- is TP.digest and only the printed line differs.
BUILTINS["sha256sum"] = function(args, stage)
    return TP.digest(args, stage, "sha256sum", function(text, name)
        emit(stage, require("sha256").hex(text) .. "  " .. (name or "-"))
    end)
end

BUILTINS["md5sum"] = function(args, stage)
    return TP.digest(args, stage, "md5sum", function(text, name)
        emit(stage, require("md5").hex(text) .. "  " .. (name or "-"))
    end)
end

-- cksum is POSIX cksum and not the zlib CRC-32 of lib/checksum.lua: the two
-- print a different number for the same bytes (3421780262 against 930766865 for
-- "123456789"), which is the whole reason lib/cksum.lua exists. The line is
-- "<value> <length>" and, with an operand, "<value> <length> <name>".
BUILTINS["cksum"] = function(args, stage)
    local posix = require("cksum")
    return TP.digest(args, stage, "cksum", function(text, name)
        local value, length = posix.of(text)
        if name == nil then
            emit(stage, value .. " " .. length)
        else
            emit(stage, value .. " " .. length .. " " .. name)
        end
    end)
end

-- -- base64 ------------------------------------------------------------------
-- Encode writes one line. Decode writes the bytes themselves and not a line:
-- decoded output is not text, and a break the input did not carry would corrupt
-- a file that is piped straight into another one. That is why the decoded text
-- goes to the stage output directly instead of through emit(), which always adds
-- the break. A stream that cannot be decoded is a failure with a reason, never a
-- shorter answer.
BUILTINS["base64"] = function(args, stage)
    local opt = TP.options({ d = true }, args, "base64", stage)
    if not opt then return 1 end
    local operand = opt.operands[1]
    local text
    if operand == nil then
        text = read_all(stage) or ""
    else
        local path = resolve_path(operand)
        text = perm.can_read(path) and TP.read(path) or nil
        if text == nil then
            emit(stage, "base64: " .. operand .. ": no such file")
            return 1
        end
    end
    local codec = require("base64")
    if opt.flags.d then
        local decoded, why = codec.decode(text)
        if decoded == nil then
            emit(stage, "base64: " .. tostring(why))
            return 1
        end
        if stage and stage._out then
            stage._out.write(decoded)
        else
            write(decoded)
        end
    else
        emit(stage, codec.encode(text))
    end
    return 0
end

-- -- expr --------------------------------------------------------------------
-- expr is a filter, not a calculator: the status is what a script reads, and
-- POSIX says it is 0 only for a value that is neither "0" nor empty. The words
-- are joined back into one expression because the shell has already split them,
-- and lib/arith.lua does the parsing. A fault is status 2, the usage error, so a
-- broken expression cannot be mistaken for a comparison that was merely false.
BUILTINS["expr"] = function(args, stage)
    local value, why = arith.eval(table.concat(args, " "), vars.get)
    if value == nil then
        emit(stage, "expr: " .. tostring(why))
        return 2
    end
    emit(stage, value)
    if value ~= "" and value ~= "0" then return 0 end
    return 1
end

-- -- egrep, fgrep ------------------------------------------------------------
-- The two historical spellings of "grep -E" and "grep -F". Each is an entry of
-- its own rather than an alias so that it has a manual page naming its syntax,
-- and each forwards to grep instead of repeating it, so a fix in grep reaches
-- all three names.
BUILTINS["egrep"] = function(args, stage)
    local forwarded = { "-E" }
    for i = 1, #args do forwarded[#forwarded + 1] = args[i] end
    return BUILTINS["grep"](forwarded, stage)
end

BUILTINS["fgrep"] = function(args, stage)
    local forwarded = { "-F" }
    for i = 1, #args do forwarded[#forwarded + 1] = args[i] end
    return BUILTINS["grep"](forwarded, stage)
end

-- -- printenv ----------------------------------------------------------------
-- Without a name the exported environment is printed, which is exactly the set
-- env lists: printenv and env are one list, so this goes through vars.env()
-- rather than reading the variable store a second way. With names, printenv is
-- asked for values, so no NAME= is printed, and a name that is not set prints
-- nothing and makes the status 1 -- that status is how a script tests whether a
-- name reached it.
BUILTINS["printenv"] = function(args, stage)
    if #args == 0 then
        for _, item in ipairs(vars.env()) do
            emit(stage, item.name .. "=" .. item.value)
        end
        return 0
    end
    local status = 0
    for _, name in ipairs(args) do
        local value = vars.get(name)
        if value == nil then
            status = 1
        else
            emit(stage, tostring(value))
        end
    end
    return status
end

-- -- groups, users -----------------------------------------------------------
-- groups reads the group list of the account through lib/perm.lua, the same list
-- useradd, usermod and gpasswd write, so there is no second copy to drift.
BUILTINS["groups"] = function(args, stage)
    local name = args[1] or perm.get_current_user()
    if not perm.user_exists(name) then
        emit(stage, "groups: " .. name .. ": no such user")
        return 1
    end
    emit(stage, table.concat(perm.get_groups(name), " "))
    return 0
end

-- users asks lib/sessionlog.lua who is logged in rather than listing /etc/passwd:
-- a machine may carry more than one live session (a second computer reaching
-- this one over rpvnet logs in on a tty of its own), and only the session
-- records know which of the accounts are actually in use.
BUILTINS["users"] = function(args, stage)
    local names = {}
    for _, record in ipairs(require("sessionlog").online()) do
        names[#names + 1] = record.user
    end
    emit(stage, table.concat(names, " "))
    return 0
end

-- -- tty, nproc --------------------------------------------------------------
-- CraftOS has one console and no device files, so there is nothing for tty to
-- open and nothing that can fail: the name is a constant and the status is
-- always 0.
BUILTINS["tty"] = function(args, stage)
    emit(stage, "/dev/console")
    return 0
end

-- One Lua VM with a cooperative scheduler: every command of this shell runs on
-- the one processor, so the answer is always 1 and never depends on the machine.
BUILTINS["nproc"] = function(args, stage)
    emit(stage, "1")
    return 0
end

-- -- tput --------------------------------------------------------------------
-- tput speaks for the terminal the machine really has. CraftOS is not a terminal
-- that reads escape sequences: the colour of text is set by calling into the
-- terminal API, there is no bold, underline or standout attribute at all, and a
-- function call cannot be put on standard output for a pipe to carry. So the
-- attribute capabilities a script may ask for are accepted and write NOTHING --
-- a script that wants emphasis must not fail -- while the capabilities that do
-- exist are answered from the terminal itself: cols and lines from its size,
-- colors from the 16 colour palette, cup by moving the cursor (the arguments are
-- ROW and COL, the terminal API takes COL and ROW), clear by clearing it.
BUILTINS["tput"] = function(args, stage)
    local capability = args[1]
    if capability == nil then
        emit(stage, "tput: no capability given")
        return 1
    end
    local width, height = term.getSize()
    if capability == "cols" then
        emit(stage, tostring(width))
    elseif capability == "lines" then
        emit(stage, tostring(height))
    elseif capability == "colors" then
        emit(stage, "16")
    elseif capability == "bold" or capability == "smul" or capability == "rmul" or
           capability == "sgr0" then
        -- Nothing to write: this terminal has no such attribute (see above).
        -- Emitting an ANSI sequence here would make the terminal print it.
    elseif capability == "cup" then
        local row, column = tonumber(args[2]), tonumber(args[3])
        if row == nil or column == nil then
            emit(stage, "tput: cup needs a row and a column")
            return 1
        end
        term.setCursorPos(column, row)
    elseif capability == "clear" then
        term.clear()
        term.setCursorPos(1, 1)
    else
        emit(stage, "tput: unknown capability: " .. capability)
        return 1
    end
    return 0
end

-- -- realpath ----------------------------------------------------------------
-- The canonical path of an operand is the path this shell itself would use:
-- resolve_path() folds "." and ".." away (lib/cwd.lua) and applies the mount
-- table, so /mnt/floppy/x becomes the path of the drive it is mounted from --
-- the same mapping every other builtin sees, not a second opinion about paths.
-- An operand that does not exist is reported and the status is 1, the way GNU
-- realpath behaves without -m.
BUILTINS["realpath"] = function(args, stage)
    if #args == 0 then
        emit(stage, "usage: realpath PATH...")
        return 1
    end
    local status = 0
    for _, operand in ipairs(args) do
        local path = resolve_path(operand)
        if fs.exists(path) then
            emit(stage, path)
        else
            emit(stage, "realpath: " .. operand .. ": no such file")
            status = 1
        end
    end
    return status
end

-- -- mktemp ------------------------------------------------------------------
-- The trailing run of X in the template is replaced by random alphanumerics, and
-- the name is created only while it is still free: this file system has no
-- exclusive open, so the exists() test followed by the create IS the exclusivity,
-- and a name that was taken makes the loop draw again instead of writing over a
-- file that belongs to someone else.
--
-- The new path gets the project's own permission record rather than the default
-- one: a temporary file is exactly the place where another user would listen, so
-- the mode is "rw-------" for a file and "rwx------" for a directory.
BUILTINS["mktemp"] = function(args, stage)
    local opt = TP.options({ d = true }, args, "mktemp", stage)
    if not opt then return 1 end
    if opt.operands[2] ~= nil then
        emit(stage, "mktemp: too many arguments")
        return 1
    end
    local template = opt.operands[1] or "/var/tmp/tmp.XXXXXX"
    -- The default template lives in /var/tmp, which a stock machine does not
    -- have. crontab -e creates it in the same place and the same way.
    if not fs.exists("/var/tmp") then fs.makeDir("/var/tmp") end
    local stem, xs = template:match("^(.-)(X+)$")
    if stem == nil then
        emit(stage, "mktemp: too few X's in template '" .. template .. "'")
        return 1
    end
    -- Lua starts math.random from a fixed seed, so without this every machine
    -- would offer the same names in the same order and a copied data directory
    -- could predict them. The flag that remembers the seeding is a field of the
    -- TP table: the main chunk of this file may not declare another local.
    if not TP.mktemp_seeded then
        TP.mktemp_seeded = true
        local ok, now = pcall(os.epoch, "utc")
        if ok and type(now) == "number" then pcall(math.randomseed, now) end
    end
    local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for _ = 1, 100 do
        local drawn = {}
        for i = 1, #xs do
            local pick = math.random(1, #alphabet)
            drawn[i] = alphabet:sub(pick, pick)
        end
        local path = stem .. table.concat(drawn)
        if not fs.exists(path) then
            local made = false
            if opt.flags.d then
                -- fs.makeDir returns NOTHING on CraftOS: measured on the ROM,
                -- makeDir on a brand new directory returns nil (type nil), and so
                -- does makeDir on one that already exists. Asking for its return
                -- value made every one of the hundred attempts look like a
                -- failure on a real machine -- "mktemp: cannot create a name from
                -- '/var/tmp/tmp.XXXXXX'" -- while passing under the test stub,
                -- whose makeDir returned true. The directory is confirmed by
                -- looking for it, which is true on both.
                pcall(fs.makeDir, path)
                made = fs.exists(path) and true or false
            else
                local handle = fs.open(path, "w")
                if handle then
                    handle.close()
                    made = true
                end
            end
            if made then
                perm.set_mode(path, opt.flags.d and "rwx------" or "rw-------")
                emit(stage, path)
                return 0
            end
        end
    end
    emit(stage, "mktemp: cannot create a name from '" .. template .. "'")
    return 1
end
-- ============================================================
-- Shell startup and interactive loop
-- ============================================================

-- Run one scheduled command. cron.run_due() calls this; the command goes
-- through the normal shell pipeline, so redirections, pipes and builtins
-- behave exactly as in an interactive session.
local function cron_run(command, user)
    local saved_user = perm.get_current_user()
    if user and user ~= saved_user and perm.user_exists(user) then
        perm.set_current_user(user)
    end
    local saved_status = SHELL.status
    local ok, err = pcall(run, command)
    if not ok then
        print("ush: cron: " .. tostring(err))
    end
    SHELL.status = saved_status
    vars.set_status(saved_status)
    perm.set_current_user(saved_user)
    return ok
end

local last_cron_check = 0
-- The 5 is the seconds between two crontab scans; it is inline rather than a
-- named local because the main chunk is at Lua's 200-local ceiling (see the note
-- on the module search paths at the top of this file).

-- Wall clock seconds. os.clock() must not be used to throttle the scheduler:
-- on CraftOS it counts CPU time, which barely advances while the shell sits
-- idle, so an idle hook throttled with it would almost never look for due
-- tasks.
local function wall_seconds()
    local ok, epoch = pcall(os.epoch, "utc")
    if ok and type(epoch) == "number" then return math.floor(epoch / 1000) end
    return os.time()
end

-- Entry argument parsing.
--   "ush -c <line>"       runs a single command line and exits, which is how
--                         the watchdog fires due tasks while no interactive
--                         session is running;
--   "ush FILE [args...]"  runs a shell script with its own positional
--                         parameters, like any other shell.
-- Anything else falls through to the interactive loop. Arguments go through
-- the normal pipeline, so builtins, pipes and redirections behave exactly as
-- in a session.
local function parse_entry_args(argv)
    local command, script, rest = nil, nil, nil
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "-c" then
            command = argv[i + 1] or ""
            i = i + 2
        elseif a == "--" then
            if not script and argv[i + 1] then
                script = argv[i + 1]
                rest = {}
                for k = i + 2, #argv do rest[#rest + 1] = argv[k] end
            end
            break
        elseif not script and a:sub(1, 1) ~= "-" then
            script = a
            rest = {}
            for k = i + 1, #argv do rest[#rest + 1] = argv[k] end
            break
        else
            i = i + 1
        end
    end
    return command, script, rest
end

-- Announce the tasks that just ran, so a scheduled command is visible in the
-- session that fired it. Used at boot and by the idle hook.
local function report_due(summary)
    if type(summary) ~= "table" then return end
    for _, e in ipairs(summary.reboot or {}) do
        print("[reboot] " .. (e.user or "root") .. ": " .. e.command)
    end
    for _, e in ipairs(summary.cron or {}) do
        print("[cron] " .. e.user .. ": " .. e.command)
    end
    for _, e in ipairs(summary.at or {}) do
        print("[at] " .. (e.user or "root") .. ": " .. e.command)
    end
end

-- Idle hook: advance the background jobs, then look for due tasks. Everything
-- here is cooperative, so the shell status is saved and restored around it.
local function shell_idle()
    local saved_status = SHELL.status
    jobs.pump()
    SHELL.status = saved_status
    vars.set_status(saved_status)

    local now = wall_seconds()
    if now - last_cron_check >= 5 then
        last_cron_check = now
        local ok, summary = pcall(cron.run_due, nil, cron_run)
        if not ok then
            print("ush: cron: " .. tostring(summary))
        else
            report_due(summary)
        end
    end
end

-- Shell state: variables, aliases and command history. The history file lives
-- in the user's home directory, one command per line.
-- The account and home directory of the session, read once at start-up. They
-- live in a table so that a session switch can write them without taking a
-- name of their own in the main chunk, which sits close to the limit of local
-- variables a Lua chunk may declare.
local session = { user = perm.get_current_user(), home = nil }
session.home = "/home/" .. session.user

-- Prepare everything that both the interactive loop and the startup scripts
-- need: variables, history file and the profile files.
local function shell_init()
    -- Ctrl+C stops the running command instead of the session (lib/interrupt.lua).
    -- Installed before the boot scripts run, so a command started by /etc/profile
    -- can be interrupted like any other. A ROM without os.pullEvent is reported
    -- as not installed rather than failing: the shell works, the key does not.
    pcall(function() require("interrupt").install() end)
    -- The boot guard and the exit rule are machine rules kept in /etc/boot.conf,
    -- so the in-memory flags are read from it rather than assumed: "set -o" must
    -- report what will actually happen, and a machine left with either rule
    -- changed must say so.
    SHELL.bootguard = protect.enabled()
    SHELL.noexit = protect.no_exit()
    vars.init({
        user = session.user,
        home = session.home,
        shell = "/usr/ush.lua",
        path = table.concat(require("path").dirs(), ":"),
        pwd = cwd.get(),
        computer_id = os.getComputerID(),
    })
    -- The variables start on the account of the console: publishing it here
    -- keeps the prompt and "su" in step from the first line on.
    session_user()
    history.init(session.home .. "/.history")

    -- Prompt themes: /etc/theme.conf may replace the built-in dark and light
    -- templates, add new ones and pick the theme of the session. A missing or
    -- unreadable file is not an error, the built-in templates are used then and
    -- "theme" reports what was read. This runs before the start up scripts so a
    -- profile may call "theme NAME" or edit the template of the session.
    -- The templates expand $HOST, so the machine name becomes a variable.
    vars.set("HOST", theme.hostname())
    vars.export("HOST")
    pcall(theme.load)

    -- Startup scripts: /etc/profile first, then the user's own ~/.ushrc.
    -- Missing files are skipped without an error.
    run_script_file("/etc/profile", true)
    run_script_file(session.home .. "/.ushrc", true)

    -- Background jobs run through the normal command runner, and both jobs and
    -- scheduled tasks are driven from the idle hook.
    jobs.set_runner(function(line) return run(line) end)
    set_idle_hook(shell_idle)

    mounts.ensure()
    cron.ensure()

    refresh_complete_ctx()
    return true
end

-- Run one input line exactly the way the interactive loop does: history
-- expansion, recording, execution and status update. Returns false when the
-- shell has to exit.
--
-- "ush cannot be exited" is enforced HERE, at the session boundary, and not in the
-- "exit" built-in. That distinction is load bearing: a script ending with "exit 3"
-- raises the same control table, and a script MUST still be able to end -- that is
-- how it returns its status. What is refused is leaving the SESSION. Refusing it
-- in the built-in would break every script that uses exit.
local function execute_line(line)
    line = (line or ""):gsub("\r", "")
    local leaving = (line == "exit" or line == "logout")
    if leaving and SHELL.interactive and protect.no_exit() then
        write_stdout("ush: exit: the shell is not allowed to be left on this " ..
                     "machine (set +o noexit as root to allow it)")
        SHELL.status = 1
        vars.set_status(SHELL.status)
        return true
    end
    if leaving then return false end
    if not line:match("%S") then return true end

    -- "!!" and "!n" are expanded first; the expanded form is what runs, while
    -- the typed form is what gets recorded.
    local expanded, herr = history.expand(line)
    if not expanded then
        write_stdout("ush: " .. tostring(herr))
        SHELL.status = 1
    else
        history.add(line)
        local ok, err = pcall(run, expanded)
        if not ok then
            print("ush: " .. tostring(err))
            SHELL.status = 1
        end
    end
    -- "exit [n]" at the prompt sets the exit request, which ends the session.
    if EXIT_REQUEST ~= nil then
        local code = EXIT_REQUEST
        EXIT_REQUEST = nil
        -- The second way out, and the one a user actually types: "exit 3" reaches
        -- the built-in, which sets EXIT_REQUEST, and the session would end here.
        -- The rule is checked again at this point so that both spellings ("exit"
        -- and "exit N") are refused, and refused at the same place, rather than
        -- one of them slipping through because it took the other route.
        if SHELL.interactive and protect.no_exit() then
            write_stdout("ush: exit: the shell is not allowed to be left on this " ..
                         "machine (set +o noexit as root to allow it)")
            SHELL.status = 1
            vars.set_status(SHELL.status)
            return true
        end
        -- The shell is leaving: its trap of EXIT runs once, with the status of
        -- the exit, and the status it leaves is the status of the shell. A
        -- trap of EXIT that has already run is not run a second time.
        code = trap_run_exit(code)
        SHELL.status = code
        vars.set_status(code)
        return false
    end
    vars.set_status(SHELL.status)
    vars.set("PWD", display_path(cwd.get()))
    return true
end

if _G.__USH_TEST then
    -- Test hook: the interactive loop is not started. The shell entry points
    -- are published instead, so that the automated tests can drive them.
    _G.__ush_test = {
        run = run,
        feed = execute_line,
        init = shell_init,
        user = session.user,
        home = session.home,
        vars = vars,
        history = history,
        alias = alias,
        jobs = jobs,
        cron = cron,
        mounts = mounts,
        sysinfo = sysinfo,
        -- Prompt glue: one rendered prompt (PS1 or the theme of the session)
        -- and the drawing routine the line editor uses for it.
        theme = theme,
        prompt = prompt_render,
        prompt_write = prompt_write,
        -- The console account rules: the tests check that a console left as
        -- root comes back on its own account when the shell starts.
        console_owner = console.owner,
        claim_console = console.claim,
        -- One read of the line editor, driven by the event queue of the
        -- tests: the same routine the interactive loop asks for a line.
        read_line = function(prompt)
            return safe_read(prompt or prompt_render())
        end,
        -- Same entry point the line editor uses for a Tab press.
        complete_line = function(text, cursor)
            refresh_complete_ctx()
            return complete.complete(text, cursor, complete_ctx)
        end,
        -- Entry argument parsing ("ush -c <line>"), exercised by the tests.
        parse_args = parse_entry_args,
        -- Whether this run is an interactive session. The real loop sets it below;
        -- the tests drive execute_line() directly, so they have to say which of
        -- the two things they are simulating. It defaults to false (a one-shot
        -- run, where "exit 3" is how a status is returned), and a test that wants
        -- the session rule turns it on.
        set_interactive = function(flag) SHELL.interactive = flag and true or false end,
        is_interactive = function() return SHELL.interactive end,
    }
else
    shell_init()

    -- Non-interactive entry: "ush -c <line>" runs the line once and exits with
    -- the shell status; "ush FILE [args...]" runs a script. The watchdog uses
    -- the "-c" form to fire scheduled tasks when no session is running.
    local entry_command, entry_script, entry_args = parse_entry_args({ ... })
    if entry_command then
        execute_line(entry_command)
        -- The shell is over after one command line: its trap of EXIT runs (it
        -- has already run when the line was an exit) and the status it leaves
        -- is the one the shell exits with.
        local code = trap_run_exit(SHELL.status)
        history.save()
        return code
    end
    if entry_script then
        local path = resolve_path(entry_script)
        local text, rerr = read_script_text(path)
        if not text then
            print("ush: " .. entry_script .. ": " .. tostring(rerr))
            history.save()
            return 127
        end
        local code = run_script_text(text, path, entry_args or {},
                                     { quiet = true })
        code = trap_run_exit(code or 0)
        history.save()
        return code
    end

    -- The language is read from /etc/locale.conf here, once per session, and the
    -- banner is the first thing it affects: a machine set to Chinese says so
    -- before the first prompt rather than after the first command.
    --
    -- No local is bound: the main chunk is AT Lua's ceiling of 200 locals (lua54
    -- rejects a 201st with "too many local variables", and the other five
    -- runtimes do not, which is why gate 1 runs all six). require() is a lookup
    -- in package.loaded after the column-0 require at the top of this file.
    require("lang").load()
    if require("lang").get() == "en" then
        print("ush 1.0 - type 'help' for commands")
    else
        require("lang").say("ush 1.0 - " .. require("lang").text("banner_hint"))
    end
    if shell and shell.setDir then shell.setDir(cwd.get()) end
    -- From here on this is a session, so the "the shell may not be left" rule
    -- applies to it. It is set here and nowhere else: the "-c" and script entries
    -- above returned before reaching this point, so a one-shot run is never
    -- mistaken for a session.
    SHELL.interactive = true

    -- Boot sequence: the /etc/rc.d units marked enabled come up in file name
    -- order first, then the "@reboot" tasks. A unit or task that fails is
    -- reported and the boot carries on, so a broken service can never keep the
    -- shell from starting.
    local ok_boot, services = pcall(require, "services")
    if ok_boot and services then
        local ran, res = pcall(services.boot)
        if not ran then
            print("ush: service: " .. tostring(res))
        elseif res then
            for _, n in ipairs(res.started or {}) do
                print("[service] " .. n .. " started")
            end
            for _, item in ipairs(res.failed or {}) do
                print("[service] " .. item.name .. " failed: " .. item.reason)
            end
        end
    end
    local ran_cron, boot_summary = pcall(cron.run_due, nil, cron_run)
    if ran_cron then
        report_due(boot_summary)
    else
        print("ush: cron: " .. tostring(boot_summary))
    end

    -- Login accounting: open a session record for this console and close it
    -- when the shell exits, so that "who"/"w" and "last"/"lastlog" have real
    -- data.
    local sessionlog = require("sessionlog")
    pcall(sessionlog.login, session.user, "console")

    while true do
        -- The prompt is rendered once per line: PS1 when the user set it, the
        -- template of the current theme otherwise.
        local line = safe_read(prompt_render())
        if line == nil then break end
        -- A line that opens a here document is not run yet: its body follows,
        -- line after line, until every delimiter has been met, so "cat <<EOF"
        -- typed at the prompt waits for its body as in a real shell.
        line = heredoc_more(line, function() return safe_read("> ") end)
        if not execute_line(line) then break end
        -- A full screen program can ask for the SESSION to end: the desktop's
        -- "log out" writes this file while it runs, and the shell honours it
        -- here, on the session boundary, exactly where a typed "logout" is
        -- decided -- so the machine comes back through the boot script instead
        -- of being left outside its own system.
        if fs.exists("/var/lib/.logout") then
            fs.delete("/var/lib/.logout")
            -- write_stdout() is print(): it ends the line itself. An earlier
            -- version appended NL, which is not defined anywhere in this file --
            -- the path was only reachable by clicking "log out" in the desktop on
            -- a real machine, so no suite ever ran it, and the machine answered
            -- "attempt to concatenate global 'NL' (a nil value)" at the moment the
            -- operator asked to leave. Measured on the GUI: leaving the desktop
            -- printed /usr/ush.lua:8747 attempt to concatenate global 'NL'.
            write_stdout("ush: logging out")
            break
        end
    end
    -- The session is over (an exit or the end of the input): the trap of EXIT
    -- of the shell runs with the status the shell leaves with. A trap that has
    -- already run for an exit is not run again.
    SHELL.status = trap_run_exit(SHELL.status)
    pcall(sessionlog.logout, "exit")
    history.save()
    print("bye")
end
