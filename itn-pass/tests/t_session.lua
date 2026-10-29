-- t_session.lua -- terminal session table: create/validate/destroy and the TTL.

local function run(H)
    H.group("session")
    local SESSION = "/auth/session.lua"

    local function fresh()
        return dofile(SESSION)
    end

    local s = fresh()
    local created, reason = s.create("user")
    H.check("session.create_rejects_non_table",
        created == nil and reason == "invalid user", tostring(reason))

    local token = s.create({ name = "alice", role = "operator" })
    H.check("session.create_token", type(token) == "string" and #token > 0,
        tostring(token))

    local record = s.validate(token)
    H.check("session.validate_ok", record ~= nil and record.user.name == "alice")
    H.check("session.validate_initial_last_seen", record.last_seen == H.now)

    H.advance(1000)
    record = s.validate(token)
    H.check("session.validate_updates_last_seen", record.last_seen == H.now)

    H.check("session.validate_unknown",
        select(2, s.validate("no-such-token")) == "invalid session")
    H.check("session.validate_nil",
        select(2, s.validate(nil)) == "invalid session")
    H.check("session.validate_number",
        select(2, s.validate(5)) == "invalid session")

    H.advance(599001)
    H.check("session.expires_after_ttl",
        select(2, s.validate(token)) == "session expired")
    H.check("session.expired_token_is_dropped",
        select(2, s.validate(token)) == "invalid session")

    local second = s.create({ name = "bob" })
    H.check("session.destroy_returns_true", s.destroy(second) == true)
    H.check("session.destroy_twice_returns_false", s.destroy(second) == false)
    H.check("session.destroy_non_string_returns_false", s.destroy(nil) == false)

    local boundary = s.create({ name = "carol" })
    H.advance(600000)
    H.check("session.ttl_boundary_still_valid", s.validate(boundary) ~= nil)
    H.advance(1)
    H.check("session.ttl_boundary_exceeded",
        select(2, s.validate(boundary)) == "session expired")

    H.check("session.new_instance_has_no_sessions",
        select(2, fresh().validate(boundary)) == "invalid session")
end

return run
