-- w.lua - show who is logged on and what they are doing (external command
-- for ush)
--
-- Usage: w [-H] [-q] [am i]
--
-- Same data as "who" (lib/who.lua over lib/sessionlog.lua), plus an uptime
-- header line and the LOGIN/IDLE/WHAT columns. IDLE is not tracked on a
-- CC:Tweaked console, so it is always reported as "-".

local args, stage = ...

local who = require("who")

who.main(args, stage, { title = "w" })
