-- audit_config.lua -- Sentinel audit server configuration.
-- Deploy as /auth/audit_config.lua on the audit server computer.
--
-- The server reads this table once at boot. It rewrites the file in place
-- (same keys, sorted, values re-serialised) only when the redstone swap
-- mechanism faults or recovers, so swap_fault always reflects reality.

return {
    main_channel = 2,
    protocol = "secure_auth_v5",
    main_modem_side = nil,
    heartbeat_interval = 5,
    logs_dir = "/logs",
    max_segment_lines = 500,
    local_keep_segments = 2,
    min_free_space = 8192,
    archive_retry_interval = 30,
    rate_per_sec = 5,
    nonce_window = 10000,
    dedup_window_ms = 2000,
    dedup_burst_max = 5,
    dedup_cleanup_interval = 10000,
    redstone_side = "back",
    pulse_seconds = 2,
    swap_wait_seconds = 5,
    max_consecutive_errors = 5,
    fault_flag = "/auth/audit_fault.flag",
    error_log = "/auth/audit_error.log",
    users_db = "/auth/users.db",
    role_check = true,
    reject_log = "/auth/audit_reject.log",
    restart_delay_seconds = 3,
    swap_fault = 0,
}
