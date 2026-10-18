-- cardkey_config.lua -- CardKey server tunables (plain table, no code runs).
-- Deploy as /auth/cardkey_config.lua on the card key server.

return {
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
