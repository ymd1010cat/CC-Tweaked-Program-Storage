-- gnome.apps.console - the console view of the windowed shell that
-- gnome.apps.shellwin implements.
--
-- WHY THIS FILE IS STILL HERE (1.6.0)
-- Since 1.6.0 the Terminal runs the shell in its window through exactly this
-- mechanism, so the Console is not a second implementation any more: it is the same
-- shell behind a second name. Both wrappers pass a title and a banner; the pump, the
-- ROM window, the terminal re-assert and the "the shell left" state all live in
-- shellwin.lua, so there is one place to fix and one behaviour to test.
--
-- Two names are kept because they are two doors into one room, and the room is
-- worth two doors: the Terminal is the traditional name for the machine's shell
-- (dock favourite, first card, `>_`), while the Console is the sixth overview card
-- that 1.5.0 shipped and the name the machine acceptance's two-console scenario
-- (C2, C3) drives, which is how "two shells, two windows, one event each" is
-- proven on a real machine. Deleting it and handing its card to the Terminal would
-- change labels, not behaviour, and would weaken that evidence. See ROADMAP 6.9.
--
-- The long explanation of the mechanism -- why a window can hold a blocking shell
-- at all, why the ROM window is built under the DESKTOP's terminal rather than
-- term.current(), why the per-slice terminal re-assert is what makes two windows
-- two shells, and what this costs (only the focused window gets the keyboard; a
-- command that blocks without reading stops the frame) -- moved with the code to
-- lib/gnome/apps/shellwin.lua.
local console = {}
local shellwin = require("gnome.apps.shellwin")

console.OPTS = { title = "Console", banner = "Pyromputer OS console" }

function console.main(api, win)
    return shellwin.main(api, win, console.OPTS)
end

function console.draw(api, win)
    return shellwin.draw(api, win, console.OPTS)
end

return console
