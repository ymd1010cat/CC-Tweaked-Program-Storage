--[[- pyroet-os/tests/t_net_app.lua -- Net system app: manifest, capabilities,
-- 26x20 layout, target parsing, probe output, runtime integration.

Loads the shipped package files straight from the staged image paths
(/system/system/net.app/*.lua), so the test covers the real manifest and the real UI
code. No modem, no sockets: the network host is a stub whose probe handle the
test completes by hand.

No non-ASCII bytes in this file.
]]

local APPS = dofile("/system/kernel/apps.lua")

-- test hook (same pattern as startup.lua): ask the app file for its module
-- table instead of the entry body, so the pure UI helpers are reachable
rawset(_G, "PYROET_NET_APP_TEST", true)
local body = assert(loadfile("/system/system/net.app/main.lua"))()
rawset(_G, "PYROET_NET_APP_TEST", nil)
local manifest_raw = assert(loadfile("/system/system/net.app/manifest.lua"))()

local function fake_api(opts)
    local o = opts or {}
    local source = o.target
    local api = { logs = {} }
    api.fs = {
        read = function(path)
            if path ~= "/etc/net.target" then return nil, "not found: " .. path end
            if source == nil then return nil, "missing file: " .. path end
            return source
        end,
    }
    api.net = { rpv = o.service }
    api.log = function(message) api.logs[#api.logs + 1] = tostring(message) end
    api.yield = function() end
    api.set_target = function(text) source = text end
    return api
end

local function stub_service(opts)
    local o = opts or {}
    local svc = {
        probe_calls = {},
        handles = {},
        hosts = o.hosts or { { name = "gw", ip = 167772161, text = "10.0.0.1" } },
        deny = o.deny == true,
    }
    function svc:status()
        if svc.deny then return nil, "capability denied: net.rpv" end
        return {
            ip = o.ip or "10.0.0.5",
            prefix = 24,
            gateway = "10.0.0.1",
            health = o.health or "ok",
            probe_port = 47100,
        }
    end
    function svc:list_hosts()
        if svc.deny then return nil, "capability denied: net.rpv" end
        return svc.hosts
    end
    function svc:probe(ip, port, payload, timeout)
        if svc.deny then return nil, "capability denied: net.rpv" end
        local handle = {
            id = #svc.handles + 1, ip = ip, port = port, done = false,
        }
        svc.probe_calls[#svc.probe_calls + 1] = {
            ip = ip, port = port, payload = payload, timeout = timeout,
            handle = handle,
        }
        svc.handles[#svc.handles + 1] = handle
        return handle
    end
    return svc
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("net.app.manifest")
    do
        local m, err = APPS.validate_manifest(manifest_raw, "/system/system/net.app")
        H.table("manifest", m)
        H.eq("manifest_error", err, nil)
        H.eq("manifest_name", m and m.name, "net")
        H.eq("manifest_version", m and m.version, "0.1.0")
        H.eq("manifest_entry", m and m.entry, "main.lua")
        H.eq("manifest_cap_count", m and #m.capabilities, 2)
        H.eq("cap_net", m and m.capabilities[1], "net.rpv")
        H.eq("cap_fs_read", m and m.capabilities[2], "fs.read")
        H.eq("no_write_cap", (function()
            for i = 1, #(m and m.capabilities or {}) do
                if m.capabilities[i] == "fs.write" then return true end
            end
            return false
        end)(), false)
        H.eq("entry_exists", H.exists("/system/system/net.app/main.lua"), true)
        H.eq("entry_is_body", type(assert(loadfile("/system/system/net.app/main.lua"))()),
            "function")
        H.eq("view_cols", body.VIEW.cols, 26)
        H.eq("view_rows", body.VIEW.rows, 20)
        H.ascii_check("main_source_ascii", H.read("/system/system/net.app/main.lua") or "")

        -- the runtime refuses unknown capabilities before the app ever runs
        local bad, bad_err = APPS.validate_manifest({
            name = "net", capabilities = { "net.rpv", "root" },
        }, "/x")
        H.check("unknown_cap_rejected", bad == nil, "accepted")
        H.contains("unknown_cap_error", bad_err, "unknown capability")
    end

    -- -----------------------------------------------------------------
    H.group("net.app.ui")
    do
        local state = body.new_state()
        state.local_ip = "10.0.0.5"
        state.prefix = 24
        state.gateway = "10.0.0.1"
        state.health = "ok"
        state.hosts = {
            { name = "gw", ip = 167772161, text = "10.0.0.1" },
            { name = "box", ip = 167772169, text = "10.0.0.9" },
        }
        state.target_ip = "10.0.0.9"
        state.target_port = 9
        state.probe_line = "probe: ok 0.01s"
        local lines = body.render(state)
        H.eq("row_count", #lines, 20)
        for i = 1, #lines do
            H.eq("width_" .. tostring(i), #lines[i], 26)
        end
        H.contains("title", lines[1], "Pyroet Net 0.1.0")
        H.contains("ip_line", lines[2], "ip 10.0.0.5/24")
        H.contains("gw_line", lines[3], "gw 10.0.0.1")
        H.contains("health_line", lines[4], "health ok")
        H.contains("hosts_line", lines[5], "hosts 2")
        H.contains("hosts_header", lines[6], "--- hosts ---")
        H.contains("host_row", lines[7], "gw 10.0.0.1")
        H.contains("host_row2", lines[8], "box 10.0.0.9")
        H.contains("probe_header", H.joined(lines), "--- probe ---")
        H.contains("target_line", H.joined(lines), "target 10.0.0.9 9")
        H.contains("probe_line", H.joined(lines), "probe: ok 0.01s")
        H.contains("input_line", H.joined(lines), "input /etc/net.target")
        H.contains("status_row", lines[20], "net ok 26x20")

        -- unavailable service renders without nil-indexing
        local empty = body.new_state()
        empty.health = "degraded"
        empty.message = "capability denied: net.rpv"
        empty.probe_line = "probe: unavailable"
        local empty_lines = body.render(empty)
        H.eq("empty_rows", #empty_lines, 20)
        H.contains("empty_ip", H.joined(empty_lines), "ip unavailable")
        H.contains("empty_gw", H.joined(empty_lines), "gw none")
        H.contains("empty_target", H.joined(empty_lines), "target none")
        H.contains("empty_message", H.joined(empty_lines), "capability denied: net.rpv")

        -- more than 8 hosts: 7 rows plus a summary line
        local many = body.new_state()
        many.health = "ok"
        many.hosts = {}
        for i = 1, 12 do
            many.hosts[i] = { name = "h" .. tostring(i), text = "10.0.0." .. tostring(i) }
        end
        local many_lines = body.render(many)
        H.eq("many_rows", #many_lines, 20)
        H.contains("overflow_summary", H.joined(many_lines), "+5 more")
        H.contains("overflow_last_row", H.joined(many_lines), "h7 10.0.0.7")
        H.lacks("overflow_truncated", many_lines, "h12")

        -- smaller views stay inside the budget
        local small = body.render(state, 20, 10)
        H.eq("small_rows", #small, 10)
        for i = 1, #small do
            H.eq("small_width_" .. tostring(i), #small[i], 20)
        end
        local tiny = body.render(state, 20, 5)
        H.eq("tiny_single_row", #tiny, 1)
        H.contains("tiny_status", tiny[1], "net ok 20x5")

        H.eq("fit_short", body.fit("abc", 5), "abc  ")
        H.eq("fit_long", body.fit("abcdef", 3), "abc")
        H.eq("fit_control", body.fit("a\tb", 4), "a?b ")
        H.eq("fit_non_ascii", body.fit("a\200b", 4), "a?b ")
        H.eq("fit_zero", body.fit("abc", 0), "a")
        H.eq("host_line_text", body.host_line({ name = "gw", text = "10.0.0.1" }),
            "gw 10.0.0.1")
        H.eq("host_line_int", body.host_line({ name = "x", ip = 1 }), "x 0.0.0.1")
        H.eq("host_line_empty", body.host_line({}), "? ?")
        H.eq("describe_ok", body.describe({ ok = true, rtt_text = "0.01s" }),
            "probe: ok 0.01s")
        H.eq("describe_timeout", body.describe({ ok = false, err = "timeout" }),
            "probe: timeout")
        H.eq("describe_nil", body.describe(nil), "probe: no result")
    end

    -- -----------------------------------------------------------------
    H.group("net.app.target")
    do
        local ip, port, err = body.parse_target("10.0.0.9 9\n")
        H.eq("target_ip", ip, "10.0.0.9")
        H.eq("target_port", port, 9)
        H.eq("target_error", err, nil)
        H.eq("target_padded", select(1, body.parse_target("  10.0.0.9   9  \n")),
            "10.0.0.9")
        H.eq("target_comment", select(1, body.parse_target("# box\n10.0.0.9 9\n")),
            "10.0.0.9")
        H.eq("target_empty", select(3, body.parse_target("")), "no target")
        H.eq("target_comment_only", select(3, body.parse_target("# nothing\n")),
            "no target")
        H.eq("target_one_token", select(3, body.parse_target("10.0.0.9")),
            "usage: <ipv4> <port>")
        H.eq("target_extra", select(3, body.parse_target("10.0.0.9 9 now")),
            "usage: <ipv4> <port>")
        H.contains("target_bad_ip", select(3, body.parse_target("10.0.0.256 9")),
            "bad ipv4: 10.0.0.256")
        H.contains("target_leading_zero",
            select(3, body.parse_target("010.0.0.1 9")), "bad ipv4")
        H.contains("target_bad_port",
            select(3, body.parse_target("10.0.0.9 70000")), "bad port: 70000")
        H.contains("target_zero_port",
            select(3, body.parse_target("10.0.0.9 0")), "bad port: 0")
        H.contains("target_text_port",
            select(3, body.parse_target("10.0.0.9 http")), "bad port: http")
        H.eq("target_not_string", select(3, body.parse_target(nil)), "no target")
    end

    -- -----------------------------------------------------------------
    H.group("net.app.refresh")
    do
        local svc = stub_service()
        local api = fake_api({ service = svc, target = "10.0.0.9 9\n" })
        local state = body.new_state()
        body.refresh(state, api)
        H.eq("state_ip", state.local_ip, "10.0.0.5")
        H.eq("state_prefix", state.prefix, 24)
        H.eq("state_gateway", state.gateway, "10.0.0.1")
        H.eq("state_health", state.health, "ok")
        H.eq("state_hosts", #state.hosts, 1)
        H.eq("state_hosts_error", state.hosts_error, nil)
        H.eq("state_target_ip", state.target_ip, "10.0.0.9")
        H.eq("state_target_port", state.target_port, 9)
        H.eq("probe_calls", #svc.probe_calls, 1)
        H.eq("probe_payload", svc.probe_calls[1].payload, body.PROBE_PAYLOAD)
        H.eq("probe_timeout", svc.probe_calls[1].timeout, 2)
        H.eq("probe_line_waiting", state.probe_line, "probe: waiting")
        H.eq("summary_log", api.logs[1], "health=ok ip=10.0.0.5")

        -- an unchanged target is not re-probed on every frame
        body.refresh(state, api)
        H.eq("no_duplicate_probe", #svc.probe_calls, 1)

        -- completed handle becomes the visible probe line
        svc.handles[1].done = true
        svc.handles[1].result = { ok = true, rtt = 0.01, rtt_text = "0.01s" }
        body.refresh(state, api)
        H.eq("probe_ok_line", state.probe_line, "probe: ok 0.01s")
        H.eq("probe_cleared", state.probe, nil)
        H.eq("last_result_ok", state.last_result and state.last_result.ok, true)

        -- a changed target starts a second probe
        api.set_target("10.0.0.10 7\n")
        body.refresh(state, api)
        H.eq("reprobed", #svc.probe_calls, 2)
        H.eq("reprobe_ip", svc.probe_calls[2].ip, "10.0.0.10")
        H.eq("reprobe_port", svc.probe_calls[2].port, 7)

        svc.handles[2].done = true
        svc.handles[2].result = { ok = false, err = "timeout" }
        body.refresh(state, api)
        H.eq("timeout_line", state.probe_line, "probe: timeout")

        -- a bad line in the file is shown, and does not start a probe
        api.set_target("10.0.0.999 7\n")
        body.refresh(state, api)
        H.contains("bad_target_line", state.probe_line, "bad ipv4")
        H.eq("bad_target_no_probe", #svc.probe_calls, 2)
        H.eq("bad_target_no_ip", state.target_ip, nil)

        -- missing file is reported, not fatal
        api.set_target(nil)
        body.refresh(state, api)
        H.eq("missing_target_ip", state.target_ip, nil)
        H.contains("missing_target_error", state.target_err, "missing file")

        -- denied capability path
        local denied_svc = stub_service({ deny = true })
        local denied_api = fake_api({ service = denied_svc })
        local denied = body.new_state()
        body.refresh(denied, denied_api)
        H.eq("denied_health", denied.health, "degraded")
        H.contains("denied_message", denied.message, "capability denied: net.rpv")
        H.eq("denied_log", denied_api.logs[1], "capability denied: net.rpv")
        H.contains("denied_probe_line", denied.probe_line, "unavailable")
        H.eq("denied_probe_calls", #denied_svc.probe_calls, 0)

        -- no rpv object at all reads as a denied capability
        local none = body.new_state()
        body.refresh(none, fake_api({ target = "10.0.0.9 9\n" }))
        H.contains("no_service_message", none.message, "capability denied: net.rpv")
        H.eq("no_service_health", none.health, "degraded")

        -- a plain rpv library (no status) is "not attached", not a crash
        local raw = body.new_state()
        local raw_api = fake_api({ service = { node_new = function() end } })
        body.refresh(raw, raw_api)
        H.eq("raw_lib_message", raw.message, "net service not attached")
        H.eq("raw_lib_health", raw.health, "degraded")

        -- a non-table is "unavailable"
        local weird = body.new_state()
        body.refresh(weird, fake_api({ service = "nope" }))
        H.eq("weird_service_message", weird.message, "net service unavailable")

        -- fs.read denied: the target cannot be read, and the reason is shown
        local grant = stub_service()
        local fs_api = fake_api({ service = grant, target = "10.0.0.9 9\n" })
        fs_api.fs.read = function() return nil, "capability denied: fs.read" end
        local fs_state = body.new_state()
        body.refresh(fs_state, fs_api)
        H.contains("fs_denied", fs_state.target_err, "capability denied: fs.read")
        H.contains("fs_denied_message", fs_state.message, "capability denied: fs.read")
        H.eq("fs_denied_probes", #grant.probe_calls, 0)
    end

    -- -----------------------------------------------------------------
    H.group("net.app.terminal")
    do
        local writes = {}
        local term = {
            getSize = function() return 40, 25 end,
            setCursorPos = function(x, y) writes[#writes + 1] = { x, y } end,
            write = function(text) writes[#writes + 1] = text end,
        }
        local cols, rows = body.view_size(term)
        H.eq("clamp_cols", cols, 26)
        H.eq("clamp_rows", rows, 20)
        local small_cols, small_rows = body.view_size({
            getSize = function() return 10, 5 end,
        })
        H.eq("small_cols", small_cols, 10)
        H.eq("small_rows", small_rows, 5)
        H.check("paint_ok", body.paint({ "abc", "def" }, term) == true, "paint failed")
        H.eq("paint_first_row", writes[1][2], 1)
        H.eq("paint_second_row", writes[3][2], 2)
        H.eq("paint_text", writes[2], "abc")
        H.eq("paint_missing_term", body.paint({ "abc" }, {}), false)

        local ok, problems = body.layout_selftest()
        H.check("layout_selftest", ok, table.concat(problems or {}, ","))
        H.eq("layout_problems", #(problems or {}), 0)

        local seen = nil
        local run_state = body.run(nil, fake_api({ service = stub_service() }), {
            max_frames = 3,
            paint = false,
            each = function(value) seen = value end,
        })
        H.table("run_state", run_state)
        H.eq("run_frames_state", run_state and run_state.local_ip, "10.0.0.5")
        H.eq("run_each_state", seen and seen.local_ip, "10.0.0.5")
    end

    -- -----------------------------------------------------------------
    H.group("net.app.runtime")
    do
        local apps = APPS
        local main_src = assert(H.read("/system/system/net.app/main.lua"))
        local man_src = assert(H.read("/system/system/net.app/manifest.lua"))

        -- denied: a manifest that does not declare net.rpv gets a denying
        -- stub, so the real app code sees nil, "capability denied: net.rpv"
        local denied_manifest = [[
return {
    name = "net",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read" },
}
]]
        local dir = H.case_dir("netapp", "denied")
        H.app_package(dir .. "/apps/net.app", {
            manifest = denied_manifest, main = main_src,
        })
        local log, lines = H.logger()
        local rt = apps.new({ fs = H.real_fs(), log = log, apps_root = dir .. "/apps" })
        H.eq("denied_scan", rt:scan(), 1)
        H.eq("loaded_name", rt:app("net") ~= nil and rt:app("net").name, "net")
        H.eq("denied_loaded_caps", #rt:app("net").manifest.capabilities, 1)
        H.check("denied_start", rt:start("net") == true, "start refused")
        rt:tick()
        H.has(lines, "APP_CAP_DENIED app=net cap=net.rpv")
        H.has(lines, "APP_LOG app=net msg=capability denied: net.rpv")
        H.eq("denied_still_running", rt:app("net").state, "running")
        rt:kill("net")

        -- granted but no host object supplied: "unavailable", never a crash
        local dir1 = H.case_dir("netapp", "unavailable")
        H.app_package(dir1 .. "/apps/net.app", { manifest = man_src, main = main_src })
        local missing_log, missing_lines = H.logger()
        local rt1 = apps.new({
            fs = H.real_fs(), log = missing_log, apps_root = dir1 .. "/apps",
        })
        H.eq("unavailable_scan", rt1:scan(), 1)
        H.eq("unavailable_caps", #rt1:app("net").manifest.capabilities, 2)
        rt1:start("net")
        rt1:tick()
        H.has(missing_lines, "APP_CAP_UNAVAILABLE app=net cap=net.rpv")
        H.has(missing_lines, "APP_LOG app=net msg=capability unavailable: net.rpv")
        H.eq("unavailable_running", rt1:app("net").state, "running")
        rt1:kill("net")

        -- granted: the net service facade is the rpv host object
        local dir2 = H.case_dir("netapp", "granted")
        H.app_package(dir2 .. "/apps/net.app", { manifest = man_src, main = main_src })
        local svc = stub_service()
        local log2, lines2 = H.logger()
        local rt2 = apps.new({
            fs = H.real_fs(), log = log2, apps_root = dir2 .. "/apps", rpv = svc,
        })
        H.eq("granted_scan", rt2:scan(), 1)
        H.write("/etc/net.target", "10.0.0.9 9\n")
        H.check("granted_start", rt2:start("net") == true, "start refused")
        rt2:tick()
        H.eq("granted_probe_calls", #svc.probe_calls, 1)
        H.eq("granted_probe_ip", svc.probe_calls[1] and svc.probe_calls[1].ip,
            "10.0.0.9")
        H.has(lines2, "APP_LOG app=net msg=health=ok ip=10.0.0.5")
        H.lacks("no_cap_denied_when_granted", lines2, "APP_CAP_DENIED app=net")
        H.eq("granted_state", rt2:app("net").state, "running")

        -- the probe handle still drives the UI on the next frame
        svc.handles[1].done = true
        svc.handles[1].result = { ok = true, rtt = 0.02, rtt_text = "0.02s" }
        rt2:tick()
        H.eq("granted_after_result", rt2:app("net").state, "running")
        H.eq("granted_single_probe", #svc.probe_calls, 1)
        rt2:kill("net")
        H.rmrf("/etc/net.target")
    end
end
