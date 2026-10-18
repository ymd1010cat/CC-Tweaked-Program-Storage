-- gnome.apps.shellwin - the project's shell running INSIDE a window of the
-- desktop, which is what the Terminal and the Console both are.
--
-- WHY THE SHELL CAN LIVE IN A RECTANGLE
-- A shell reads lines with a blocking read, positions its cursor itself, and
-- clears the screen when a full screen program asks it to: written naively, it
-- would need the whole screen, and every program it starts would paint outside
-- the window. This desktop already has the two mechanisms that make the other
-- shape work:
--   * a ROM window (window.create) below the desktop's own terminal, invisible,
--     that the shell is redirected into and whose cells are copied into the
--     desktop's screen every frame. window.getLine is what makes that possible:
--     on CraftOS-PC 2.8.3 a created window has getLine (it answers text, fg and bg
--     per row) while term.native() and term.getLine do not have it at all -- both
--     measured -- so the only readable surface on this machine is a window this
--     package created itself;
--   * the desktop's event pump, which answers the shell's blocking read from the
--     desktop's own event stream, and re-asserts term.redirect, so the desktop
--     keeps drawing, keeps its clock, and another window stays usable while the
--     shell sits at a prompt. term.redirect is one global target: re-asserting it
--     before every slice is what makes two windows two shells instead of two views
--     of one.
--
-- MANY SHELLS, EACH WITH ITS OWN WINDOW AND ITS OWN TERMINAL
-- Every copy of the app creates its own ROM window under the DESKTOP's terminal
-- (d.term_target), never under term.current(): with a second shell window open,
-- term.current() IS the first one's window, so building under it would nest the
-- second window inside the first. The pump is told which terminal the program owns
-- (opts.term) and re-asserts it before every slice, so window 1's command output
-- goes to window 1 even though window 2 redirected term more recently.
--
-- WHAT IT COSTS, STATED IN THE WINDOW RATHER THAN HIDDEN
-- Only the focused window is offered the keyboard, and a command that blocks
-- without reading -- 'sleep', for instance -- still stops the frame for as long as
-- it runs, because nothing on this machine can preempt a coroutine. Both are
-- properties of the machine; the first is the desktop's rule, the second has no
-- rule that could fix it.
--
-- THE API IS (api, win, opts) WITH opts.title AND opts.banner
-- The two applications that wrap this module are one mechanism with two names, so
-- the difference between them is a name and a banner, not a code path: a wrapper
-- passes its own and nothing else. That is deliberate -- see ROADMAP 6.9 and the
-- headers of terminal.lua and console.lua for why both names are kept.
local shellwin = {}

-- The colour letters `term.blit` uses, and the constants `screen.cell` wants. The
-- letter is the bit position, which is why this is a table and not arithmetic.
local BLIT = {
    ["0"] = 1, ["1"] = 2, ["2"] = 4, ["3"] = 8, ["4"] = 16, ["5"] = 32,
    ["6"] = 64, ["7"] = 128, ["8"] = 256, ["9"] = 512, ["a"] = 1024,
    ["b"] = 2048, ["c"] = 4096, ["d"] = 8192, ["e"] = 16384, ["f"] = 32768,
}

local function from_blit(letter)
    return BLIT[letter]
end

local function has_window_api()
    if type(window) ~= "table" or type(window.create) ~= "function" then return false end
    if type(term) ~= "table" or type(term.current) ~= "function" then return false end
    return true
end

function shellwin.main(api, win, opts)
    opts = opts or {}
    local d = api.desktop
    win.state = win.state or {}
    -- Kept on the window so draw() can name the window even when the host calls it
    -- without the opts table (the desktop calls app.draw(api, win)).
    win.state.title = tostring(opts.title or win.title or "shell")
    win.state.banner = tostring(opts.banner or win.state.title)
    if not has_window_api() then
        win.state.problem = "this machine has no window API, so there is no shell here"
        return
    end
    local body = api.body
    local root = d.term_target
    if type(root) ~= "table" then
        local okc, current = pcall(term.current)
        root = okc and current or nil
    end
    if type(root) ~= "table" then
        win.state.problem = "this machine has no terminal to build a window under"
        return
    end
    local okw, screen_win = pcall(window.create, root, body.x, body.y,
                                 math.max(1, body.w), math.max(1, body.h), false)
    if not okw or screen_win == nil then
        win.state.problem = "window.create answered nothing: no shell on this machine"
        return
    end
    win.state.win = screen_win
    local runner = d.run_shell
    if type(runner) ~= "function" then
        runner = function(path)
            if type(shell) ~= "table" or type(shell.run) ~= "function" then
                error("this machine has no shell.run: cannot start " .. tostring(path), 0)
            end
            return shell.run(path)
        end
    end
    -- The program is the shell, and the pump owns the redirect for it: opts.term
    -- is the window below, re-asserted before every slice (see the header), so a
    -- shell that leaves `term` redirected cannot poison the frame and a second
    -- shell window cannot steal this one's output.
    local ok, err = api.task.pump(function()
        return runner(api.shell)
    end, { window = win, term = screen_win })
    win.state.exited = true
    if ok then
        win.state.result = "the shell left; press F10 to close"
    else
        win.state.result = "the shell stopped: " .. tostring(err)
    end
end

-- What the window shows. While the shell is alive the window IS the shell -- the
-- copied cells are the picture, and no banner of ours belongs on top of them. When
-- there is nothing to copy, the window says why, names this window (the banner)
-- and names the shell it starts, in that order: the reason is the line an operator
-- has to act on. `the shell left` is written on the body's last row, and only
-- after the program has really ended.
function shellwin.draw(api, win, opts)
    opts = opts or {}
    local st = win.state or {}
    local title = tostring(st.title or opts.title or win.title or "shell")
    local banner = tostring(st.banner or opts.banner or title)
    if st.problem then
        -- app_api clips to the window: the reason is longer than many windows and
        -- this is the path that used to paint it across the desktop.
        api.write(1, 1, tostring(st.problem))
        api.write(1, 2, banner)
        api.write(1, 3, "the shell is " .. tostring(api.shell))
        return
    end
    local sw = st.win
    if sw == nil or type(sw.getLine) ~= "function" then
        api.write(1, 1, banner)
        api.write(1, 2, "the shell's window is gone")
        return
    end
    local h = api.h
    if type(sw.getSize) == "function" then
        local okh, wh = pcall(sw.getSize)
        if okh and tonumber(wh) then h = math.min(h, math.floor(wh)) end
    end
    for y = 1, h do
        local ok, text, fg, bg = pcall(sw.getLine, y)
        if ok and type(text) == "string" then
            for x = 1, math.min(api.w, #text) do
                api.cell(x, y, text:sub(x, x),
                         from_blit(fg and fg:sub(x, x)), from_blit(bg and bg:sub(x, x)))
            end
        end
    end
    if st.exited and st.result then
        api.write(1, api.h, tostring(st.result))
    end
end

return shellwin
