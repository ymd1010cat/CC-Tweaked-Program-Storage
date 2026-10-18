-- who.lua - show who is logged on (external command for ush)
--
-- Usage: who [-H] [-q] [am i]
--
--   -H      print a header line
--   -q      print only the user names and the session count
--   am i    restrict the output to the current console
--
-- The report itself lives in lib/who.lua, the data in lib/sessionlog.lua
-- (live session records under /var/lib/sessions).

local args, stage = ...

local who = require("who")

who.main(args, stage, { title = "who" })
