-- gnome.apps.terminal - the Terminal window: the project's shell running INSIDE
-- the window, which is also what the Console is.
--
-- WHY IT IS NO LONGER A FULL SCREEN HANDOVER (1.6.0)
-- Through 1.5.0 the Terminal gave the whole machine to `psh`: the desktop released
-- the screen, the shell owned it until it exited, and the desktop repainted after.
-- That was honest, and it was also not a window: the panel and the dock vanished
-- for the length of the session, nothing else could be used next to it, and a
-- machine report ("the text ran out of the window") was about the other problem of
-- that shape. The mechanism for running a blocking program inside a rectangle is
-- already here: a ROM window, which is the only surface this machine can read back
-- (window.create windows have getLine on CraftOS-PC 2.8.3; term.native() and
-- term.getLine have none, measured), plus the desktop's event pump, with the
-- terminal re-asserted before every slice of the shell because term.redirect is one
-- global target. This window therefore runs the shell in its own cells.
-- Desktop:handover is still there as a desktop capability (a host may still hand
-- the machine over, and tests/batch10_check.lua exercises it through a synthetic
-- app); it is simply not what the Terminal does.
--
-- TERMINAL AND CONSOLE ARE ONE MECHANISM WITH TWO NAMES, AND THAT IS STATED
-- Both this file and gnome.apps.console are thin wrappers over
-- gnome.apps.shellwin: same pump, same ROM window, same "the shell left" state.
-- Two doors into one room rather than two shells to keep in step:
--   * Terminal is the traditional name for "this machine's shell", it is the dock
--     favourite and the first overview card, and its `>_` icon and name are the
--     ones the picture uses;
--   * Console is the sixth overview card that 1.5.0 shipped, and the machine
--     acceptance's two-console scenario (C2, C3) drives it. Removing it would have
--     meant rewriting those checks against another name for no gain in behaviour.
-- The alternative -- deleting the Console and giving its card to the Terminal --
-- is a naming decision, not a mechanism one: it would leave the operator with one
-- fewer way to say "a shell in a window" and the acceptance with one fewer shell
-- to prove independence with. The cost of keeping both is one name, not a copy of
-- the code: the shell lives in shellwin.lua and both wrappers pass only a title
-- and a banner.
local terminal = {}
local shellwin = require("gnome.apps.shellwin")

-- What this wrapper contributes: the name and the banner. The shell it starts is
-- api.shell, the desktop's own shell path -- there is no second copy of
-- "/usr/psh.lua" here that would have to be kept in step with desktop.SHELL.
terminal.OPTS = { title = "Terminal", banner = "Pyromputer OS terminal" }

function terminal.main(api, win)
    return shellwin.main(api, win, terminal.OPTS)
end

function terminal.draw(api, win)
    return shellwin.draw(api, win, terminal.OPTS)
end

return terminal
