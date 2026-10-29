-- t_netcheck.lua -- terminal network check: 0 / 1 / many stations on the shared
-- channel.

local function run(H)
    H.group("netcheck")

    local function heartbeats(ids)
        for _, id in ipairs(ids) do
            H.pushEvent("modem_message", "left", 33, 33, {
                protocol = "itnpass_v1",
                type = "heartbeat",
                server_id = id,
            })
        end
    end

    local function count(ids)
        local n = 0
        for _ in pairs(ids or {}) do
            n = n + 1
        end
        return n
    end

    local ok, ids, reason

    H.installPeripheral({ names = {} })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.no_modem", ok == false and reason == "no modem", tostring(reason))
    H.check("netcheck.no_modem_empty_ids", type(ids) == "table" and count(ids) == 0)

    H.installPeripheral({
        names = { "top" },
        types = { top = "modem" },
        wireless = { top = true },
    })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.wireless_only", ok == false and reason == "wireless modem",
        tostring(reason))

    H.installPeripheral({
        names = { "top", "left" },
        types = { top = "modem", left = "modem" },
        wireless = { top = true },
    })
    heartbeats({ "S1" })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.wired_modem_preferred", ok == true and ids.S1 == true,
        tostring(reason))
    H.check("netcheck.one_server_reason_nil", reason == nil, tostring(reason))

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.zero_servers", ok == false)
    H.check("netcheck.zero_servers_reason",
        reason == "no card key server detected", tostring(reason))
    H.check("netcheck.zero_servers_ids_empty", count(ids) == 0)

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeats({ "S1", "S1", "S1" })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.repeated_heartbeat_is_one_server",
        ok == true and count(ids) == 1, count(ids))

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeats({ "S1", "S2" })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.two_servers_rejected", ok == false, tostring(reason))
    H.check("netcheck.two_servers_reason", reason == "multiple servers: 2",
        tostring(reason))
    H.check("netcheck.two_servers_ids_kept",
        ids.S1 == true and ids.S2 == true and count(ids) == 2)

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeats({ "S1", "S2", "S3" })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.three_servers_reason", reason == "multiple servers: 3",
        tostring(reason))

    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    H.pushEvent("modem_message", "left", 33, 33, {
        protocol = "other_v1", type = "heartbeat", server_id = "X",
    })
    H.pushEvent("modem_message", "left", 33, 33, {
        protocol = "itnpass_v1", type = "verify_request", server_id = "Y",
    })
    H.pushEvent("modem_message", "left", 33, 33, {
        protocol = "itnpass_v1", type = "heartbeat", server_id = "",
    })
    H.pushEvent("modem_message", "left", 33, 33, {
        protocol = "itnpass_v1", type = "heartbeat",
    })
    H.pushEvent("modem_message", "left", 33, 33, "garbage")
    H.pushEvent("modem_message", "right", 33, 33, {
        protocol = "itnpass_v1", type = "heartbeat", server_id = "Z",
    })
    H.pushEvent("modem_message", "left", 4, 4, {
        protocol = "itnpass_v1", type = "heartbeat", server_id = "W",
    })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.ignores_foreign_traffic",
        ok == false and reason == "no card key server detected", tostring(reason))

    H.installPeripheral({
        names = { "left" },
        types = { left = "modem" },
        openError = true,
    })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.open_error", ok == false and reason == "cannot open channel",
        tostring(reason))

    local rec = H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    heartbeats({ "S1" })
    ok, ids, reason = dofile("/system/netcheck.lua").check(2)
    H.check("netcheck.opens_and_closes_channel",
        ok == true and rec.opens == 1 and rec.closes == 1,
        tostring(rec.opens) .. "/" .. tostring(rec.closes))

    -- The listen window defaults to 3 seconds when the caller passes nothing.
    H.installPeripheral({ names = { "left" }, types = { left = "modem" } })
    ok, ids, reason = dofile("/system/netcheck.lua").check(nil)
    H.check("netcheck.default_window", ok == false
        and reason == "no card key server detected", tostring(reason))
end

return run
