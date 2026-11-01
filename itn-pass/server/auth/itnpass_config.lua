-- itnpass_config.lua -- ITN-Pass station tunables.
-- Deploy as /auth/itnpass_config.lua on the station.
-- protocol and channel are not written here: they come from /itnpass_net.lua so
-- the station and the terminal share a single copy of both values.
--
-- Run mode (resolved by /itnpass_mode.lua, see README "run modes"):
--   "pass" -- default: a card key is needed for every disk write;
--   "free" -- public open mode: no card key at all, nothing is charged.
-- Any other value fails safe to "pass". /auth/itnpass_mode.txt overrides this
-- field when it holds a valid value, so the disk can be switched without a code
-- change (reboot the station / terminal to apply).

local net = dofile("/itnpass_net.lua")

local config = {
    mode = "pass",
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

-- Resolve the effective mode once, at load time, so every reader (station,
-- terminal, console) sees the same value with the same priority: mode file
-- first, then the field above, then the built-in default "pass".
local okMode, modeModule = pcall(dofile, "/itnpass_mode.lua")
if okMode and type(modeModule) == "table" then
    config.mode, config.mode_source = modeModule.resolve(config)
else
    -- The resolver itself is missing: keep the paid mode rather than opening
    -- the station by accident.
    if config.mode ~= "pass" and config.mode ~= "free" then
        config.mode = "pass"
    end
    config.mode_source = "default"
end

return config
