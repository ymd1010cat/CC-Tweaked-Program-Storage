--[[- tests/run.lua ? offline unit-test + lint runner (no topology, no peripherals).

Runs the library's pure logic under a single headless host: the modules are plain
Lua (fs/os/string/table/bit32 only), so nothing here needs a modem, a second
computer or any of the poc/run-*.ps1 harnesses. On a desktop Lua 5.1 you only need
the tiny `fs` shim in tests/host.lua.

    startup stub:  dofile("tests/run.lua")
Output:
    TEST name ok=true            per assertion group
    TEST_FAIL name err=...       on failure
    OFFLINE_RESULT pass=N fail=M
    LINT_RESULT errors=N warnings=M files=K
    TEST_DONE
]]
local function load_module(path, M)
    local fn = assert(loadfile(path), "cannot load " .. path)
    local ret = fn(M)
    if type(ret) == "function" then
        error("module " .. path .. " returns a function; use `local M = ...` + `return M`")
    end
    return ret
end

local M = { RPV_VERSION = "RPV1", tests = {} }

-- the library is loaded exactly like node2/startup.lua does it, minus the network
for _, mod in ipairs({ "crypto", "util", "ip", "route", "arp", "link", "icmp", "udp",
                       "conn", "fabric", "wan", "services", "dv", "nat", "mcast", "qos",
                       "wansec", "compat", "topo", "node" }) do
    local ok, err = pcall(load_module, "rpv/" .. mod .. ".lua", M)
    if not ok then
        print("TEST_FAIL module:" .. mod .. " err=" .. tostring(err))
    end
end

-- app-layer modules are plain tables, so each one is loaded on its own
for _, mod in ipairs({ "http_common", "http_server", "http_client", "http_secure",
                       "hosts", "wan_acl" }) do
    if fs.exists("apps/" .. mod .. ".lua") then
        local ok, ret = pcall(load_module, "apps/" .. mod .. ".lua", M)
        if ok and type(ret) == "table" then
            M[mod] = ret
        else
            print("TEST_FAIL module:" .. mod .. " err=" .. tostring(ret))
        end
    end
end

-- ===== tiny assertion harness ==============================================
local T = { pass = 0, fail = 0, current = "?" , failures = {} }
local function report(name, ok, detail)
    if ok then
        T.pass = T.pass + 1
    else
        T.fail = T.fail + 1
        T.failures[#T.failures + 1] = name .. " " .. tostring(detail or "")
        print("  TEST_FAIL " .. name .. " " .. tostring(detail or ""))
    end
end

function T.eq(got, want, name)
    report(name, got == want, "got=" .. tostring(got) .. " want=" .. tostring(want))
end

function T.ok(cond, name)
    report(name, cond and true or false, "condition was falsy")
end

function T.near(got, want, tol, name)
    report(name, type(got) == "number" and math.abs(got - want) <= tol,
        "got=" .. tostring(got) .. " want~=" .. tostring(want) .. " tol=" .. tostring(tol))
end

function T.raises(fn, name)
    local ok = pcall(fn)
    report(name, not ok, "expected an error, none raised")
end

-- a node stub: no peripherals, no sockets, just enough for the pure logic
function T.node(cfg, ifaces)
    local n = {
        id = 21, mac = 21, role = cfg and cfg.role or "router",
        cfg = cfg or {}, ifaces = ifaces or {}, routes = M.route_new(),
        stats = {}, log = function(self, fmt, ...) self.logged = (self.logged or 0) + 1 end,
    }
    function n:log(fmt, ...) self.logged = (self.logged or 0) + 1 end
    return n
end

local files = {
    "tests/t_util.lua", "tests/t_ip.lua", "tests/t_route.lua", "tests/t_crypto.lua",
    "tests/t_conn.lua", "tests/t_wansec.lua", "tests/t_nat.lua", "tests/t_mcast.lua",
    "tests/t_qos.lua", "tests/t_topo.lua", "tests/t_scale.lua", "tests/t_services.lua", "tests/t_services_hosts.lua", "tests/t_addr.lua", "tests/t_compat.lua",
    "tests/t_http_common.lua", "tests/t_http_server.lua", "tests/t_http_client.lua",
    "tests/t_http_secure.lua", "tests/t_http_integration.lua", "tests/t_http_hardening.lua",
    "tests/t_hosts.lua", "tests/t_wan_acl.lua",
}
local groups = 0
for _, path in ipairs(files) do
    local chunk = loadfile(path)
    if not chunk then
        T.fail = T.fail + 1
        T.failures[#T.failures + 1] = path .. " (loadfile failed)"
        print("TEST_FAIL " .. path .. " (loadfile failed)")
    else
        local name = path:gsub("^tests/t_", ""):gsub("%.lua$", "")
        local ok, err = pcall(chunk, T, M)
        groups = groups + 1
        print(string.format("TEST %s ok=%s%s", name, tostring(ok), ok and "" or (" err=" .. tostring(err))))
        if not ok then
            T.fail = T.fail + 1
            T.failures[#T.failures + 1] = name .. " (threw: " .. tostring(err) .. ")"
        end
    end
end

print(string.format("OFFLINE_RESULT pass=%d fail=%d groups=%d", T.pass, T.fail, groups))
-- short lines (the CC console wraps long ones, which breaks harness parsing)
print("OFFLINE_PASS " .. T.pass)
print("OFFLINE_FAIL " .. T.fail)
print("OFFLINE_GROUPS " .. groups)
for _, f in ipairs(T.failures) do print("OFFLINE_FAILURE " .. f) end

-- ===== lint =================================================================
local lint, lintErr = loadfile("tools/lint.lua")
if lint then
    local ok, res = pcall(lint, T, M)
    if not ok then
        print("LINT_CRASH " .. tostring(res))
        print("LINT_ERRORS 1")
        print("LINT_WARNINGS 0")
        print("LINT_FILES 0")
    end
else
    print("LINT_SKIP " .. tostring(lintErr))
    print("LINT_ERRORS 1")
    print("LINT_WARNINGS 0")
    print("LINT_FILES 0")
end

print("TEST_DONE")
