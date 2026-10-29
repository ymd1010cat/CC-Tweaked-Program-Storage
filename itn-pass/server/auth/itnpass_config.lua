-- itnpass_config.lua -- ITN-Pass station tunables.
-- Deploy as /auth/itnpass_config.lua on the station.
-- protocol and channel are not written here: they come from /itnpass_net.lua so
-- the station and the terminal share a single copy of both values.

local net = dofile("/itnpass_net.lua")

return {
    channel = net.CHANNEL,
    protocol = net.PROTOCOL,
    modem_side = nil,
    heartbeat_interval = 2,
    admin_file = "/auth/itnpass_admin.db",
    export_dir = "/cardkeys",
    payload_dir = "/payload",
    default_uses = 2,
    max_batch = 200,
    challenge_ttl_ms = 15000,
    reservation_ttl_ms = 300000,
    max_fail_per_terminal = 10,
    lockout_ms = 60000,
    max_fail_global = 60,
    global_lockout_ms = 30000,
}
