-- rget.lua - fetch a file from another computer (external command for ush)
--
-- Usage: rget -t <id> [-o <local>] [-c <bytes>] [-w <sec>] [-r <n>] [-f] [-q] remote...
--        rget --listen [-s <dir>] [--as <path>] [-W <sec>] [-f] [-q]
--
-- The file is fetched in chunks, every chunk is checked with a CRC32 and the
-- assembled body is checked again before it replaces anything on disk, so a
-- damaged transfer never overwrites a good file. Protocol and retransmission
-- live in lib/xfer.lua, argument parsing and the report in lib/netcmds.lua.
-- The peer must be running netd (or "rget --listen") and must hold the same
-- key; both sides read it from /etc/pkg.conf.

local args, stage = ...

local netcmds = require("netcmds")

return netcmds.main(args, stage, { title = "rget" })
