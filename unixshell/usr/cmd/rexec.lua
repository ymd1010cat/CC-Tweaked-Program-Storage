-- rexec.lua - run one command on another computer (external command for ush)
--
-- Usage: rexec -t <id> [-w <sec>] [-T <sec>] [-n] [-q] command...
--
-- The command runs on the peer's shell; stdout, stderr and the exit code come
-- back together. The peer must be running netd and must allow the command
-- under its policy; every request it serves is written to the peer's audit
-- log. Exit status 124 means the peer did not answer within the timeout (its
-- netd may not be running). The reply channel lives in lib/rexec.lua, the
-- argument parsing and the report in lib/netcmds.lua.

local args, stage = ...

local netcmds = require("netcmds")

return netcmds.main(args, stage, { title = "rexec" })
