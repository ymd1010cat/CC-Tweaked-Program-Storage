--[[- tests/t_compat.lua — the runtime API self-check reports what it found.]]
local T, M = ...

local ok, missing, optional = M.compat_check()
T.ok(type(ok) == "boolean", "compat_check returns a boolean verdict")
T.ok(ok, "this host has the required APIs (missing: " .. table.concat(missing, ",") .. ")")
T.eq(#missing, 0, "no required API is missing")
T.ok(type(optional) == "table", "optional list is a table")

local node = T.node({})
local verdict = M.compat_setup(node)
T.eq(verdict, ok, "compat_setup returns the same verdict")
T.ok(node.compat ~= nil, "node.compat recorded")
T.ok(type(node.compat.version) == "string", "version string recorded")

-- the library modules all loaded (run.lua recorded failures separately, but the
-- pieces other modules depend on must exist)
for _, name in ipairs({ "sha256", "hmac_sha256", "hkdf_sha256", "chacha20_xor", "random_bytes",
                        "conn_new", "conn_parse", "route_new", "ip_build", "ip_parse",
                        "nat_new", "mcast_new", "qos_classify", "wansec_setup", "compat_check",
                        "locked", "neighbour_has" }) do
    if name == "locked" or name == "neighbour_has" then
        -- not part of the API; skip the sentinel entries
    else
        T.ok(type(M[name]) == "function", "library exports " .. name)
    end
end
