-- rput.lua - send a file to another computer (external command for psh)
--
-- Usage: rput -t <id> [-p <path>] [-c <bytes>] [-w <sec>] [-r <n>] [-f] [-q] file...
--
-- The file is pushed in chunks, every chunk is acknowledged with a CRC32 and
-- the peer checks the assembled body again before writing it, so a damaged
-- transfer never lands on the peer's disk. Protocol and retransmission live
-- in lib/xfer.lua, argument parsing and the report in lib/netcmds.lua. The
-- peer must be running netd, and must hold the same key; both sides read it
-- from /etc/pkg.conf.

local args, stage = ...

local netcmds = require("netcmds")

return netcmds.main(args, stage, { title = "rput" })
