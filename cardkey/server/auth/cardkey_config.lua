-- cardkey_config.lua -- CardKey server tunables.
-- Deploy as /auth/cardkey_config.lua on the card key server.
--
-- Run mode (resolved by /cardkey_mode.lua, see README section 15):
--   "pass" -- default: a card key is needed for every disk write;
--   "free" -- public open mode: no card key at all, nothing is charged.
-- Any other value fails safe to "pass". /auth/cardkey_mode.txt overrides this
-- field when it holds a valid value, so the disk can be switched without a
-- code change (reboot the server and the terminals to apply).
--
-- /cardkey_mode.lua is optional: a deployment without it keeps the paid mode
-- instead of failing, so an existing installation can be upgraded one machine
-- at a time. Every reader (service, console, terminal) follows the same rule.

local config = {
    mode = "pass",
    channel = 3,
    protocol = "cardkey_v1",
    modem_side = nil,
    heartbeat_interval = 2,
    admin_file = "/auth/admin.db",
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

-- Resolve the effective mode once, at load time, so every reader sees the same
-- value with the same priority: mode file first, then the field above, then
-- the built-in default "pass". A missing resolver is not an error -- the
-- station keeps the paid mode rather than opening by accident.
local okMode, modeModule = pcall(dofile, "/cardkey_mode.lua")
if okMode and type(modeModule) == "table" then
    config.mode, config.mode_source = modeModule.resolve(config)
else
    config.mode = "pass"
    config.mode_source = "default"
end

return config
