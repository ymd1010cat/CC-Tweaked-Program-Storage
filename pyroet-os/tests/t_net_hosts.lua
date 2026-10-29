--[[- pyroet-os/tests/t_net_hosts.lua -- static hosts: parser, table, reload, rpv hook.

Covers the five failure paths the P3 brief names: legal/illegal lines, a bad
file keeping the old table, mtime hot reload, leading-zero rejection, illegal
hostname rejection, and a resolve miss. No real modem, no services.lua.

No non-ASCII bytes in this file.
]]

local HOSTS = dofile("/system/net/hosts.lua")

-- in-memory file system: exists / attributes / open("r") / open("w")
local function mem_fs(files, mtimes)
    local f = {}
    f.files = files or {}
    f.mtimes = mtimes or {}
    function f.exists(path) return f.files[path] ~= nil end
    function f.attributes(path)
        if f.files[path] == nil then error("No such file", 0) end
        return { modification = f.mtimes[path] or 1, size = #f.files[path] }
    end
    function f.open(path, mode)
        if mode ~= "r" and mode ~= "w" and mode ~= "a" then return nil end
        if f.files[path] == nil then return nil end
        local text = f.files[path]
        local handle = {}
        function handle.readAll() return text end
        function handle.read() return text end
        function handle.write(data) f.files[path] = (f.files[path] or "") .. tostring(data) end
        function handle.close() end
        return handle
    end
    return f
end

local function ip2int(text)
    local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a) * 16777216 + tonumber(b) * 65536
        + tonumber(c) * 256 + tonumber(d)
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("hosts.parse")
    do
        local text = table.concat({
            "# static table for the pocket",
            "",
            "gw 10.0.0.1",
            "ns1 10.0.0.53   # trailing comment",
            "box-1 192.168.1.20",
            "under_score 172.16.0.9",
            "0.0.0.0 255.255.255.255",
        }, "\n")
        local parsed, err = HOSTS.parse(text)
        H.table("parsed", parsed)
        H.eq("parse_error", err, nil)
        H.eq("parse_count", parsed and parsed.count, 5)
        local by_name = {}
        for i = 1, #(parsed and parsed.entries or {}) do
            local entry = parsed.entries[i]
            by_name[entry.name] = entry
        end
        H.eq("gw_ip", by_name.gw and by_name.gw.ip, ip2int("10.0.0.1"))
        H.eq("gw_text", by_name.gw and by_name.gw.text, "10.0.0.1")
        H.eq("trailing_comment", by_name.ns1 and by_name.ns1.text, "10.0.0.53")
        H.eq("dash_underscore", by_name.under_score and by_name.under_score.text,
            "172.16.0.9")
        H.eq("all_ones_value", by_name["0.0.0.0"] and by_name["0.0.0.0"].ip,
            4294967295)
        H.eq("all_ones_text", by_name["0.0.0.0"] and by_name["0.0.0.0"].text,
            "255.255.255.255")

        H.eq("crlf_count", select(1, HOSTS.parse("a 1.2.3.4\r\nb 5.6.7.8\r\n")).count, 2)
        H.eq("no_trailing_newline",
            select(1, HOSTS.parse("a 1.2.3.4")).count, 1)
        H.eq("blank_comments_only",
            select(1, HOSTS.parse("\n\n# x\n")).count, 0)
        H.eq("empty_text", select(1, HOSTS.parse("")).count, 0)
        H.check("not_a_string", HOSTS.parse(nil) == nil, "nil accepted")
        H.eq("not_a_string_error", select(2, HOSTS.parse(nil)),
            "hosts text must be a string")

        -- duplicates: the later definition wins, one row stays
        local dup = HOSTS.parse("dup 10.0.0.1\ndup 10.0.0.2\n")
        H.eq("dup_count", dup and dup.count, 1)
        H.eq("dup_ip", dup and dup.entries[1].ip, ip2int("10.0.0.2"))

        -- strict octets
        H.eq("ip_zero", HOSTS.parse_ip("0.0.0.0"), 0)
        H.eq("ip_all_255", HOSTS.parse_ip("255.255.255.255"), 4294967295)
        H.eq("ip_leading_zero", HOSTS.parse_ip("010.0.0.1"), nil)
        H.eq("ip_leading_zero_short", HOSTS.parse_ip("1.2.3.04"), nil)
        H.eq("ip_octet_256", HOSTS.parse_ip("1.2.3.256"), nil)
        H.eq("ip_three_octets", HOSTS.parse_ip("1.2.3"), nil)
        H.eq("ip_five_octets", HOSTS.parse_ip("1.2.3.4.5"), nil)
        H.eq("ip_empty_octet", HOSTS.parse_ip("1..3.4"), nil)
        H.eq("ip_alpha", HOSTS.parse_ip("1.2.3.x"), nil)
        H.eq("ip_negative", HOSTS.parse_ip("1.2.3.-1"), nil)
        H.eq("ip_spaces", HOSTS.parse_ip(" 1.2.3.4"), nil)
        H.eq("ip_text_roundtrip", HOSTS.int2ip(ip2int("10.0.0.1")), "10.0.0.1")

        -- hostname charset is exactly [%w%.%-_]+
        H.eq("hostname_ok", HOSTS.valid_hostname("host-1_a.b"), true)
        H.eq("hostname_space", HOSTS.valid_hostname("bad host"), false)
        H.eq("hostname_slash", HOSTS.valid_hostname("bad/host"), false)
        H.eq("hostname_empty", HOSTS.valid_hostname(""), false)
        H.eq("hostname_bang", HOSTS.valid_hostname("host!"), false)

        local bad = {
            { "missing_ip", "gw", "expected" },
            { "extra_token", "gw 10.0.0.1 10.0.0.2", "extra token" },
            { "bad_hostname", "bad/host 10.0.0.1", "bad hostname" },
            { "leading_zero", "gw 010.0.0.1", "bad ipv4" },
            { "octet_256", "gw 10.0.0.256", "bad ipv4" },
            { "short_ip", "gw 10.0.0", "bad ipv4" },
            { "long_ip", "gw 1.2.3.4.5", "bad ipv4" },
            { "empty_octet", "gw 1..3.4", "bad ipv4" },
            { "alpha_ip", "gw 1.2.3.x", "bad ipv4" },
            { "key_line", "key=value", "expected" },
        }
        for i = 1, #bad do
            local case = bad[i]
            local value, perr = HOSTS.parse(case[2])
            H.check(case[1], value == nil, "accepted: " .. case[2])
            H.contains(case[1] .. "_error", perr, case[3])
        end
        H.contains("line_number", select(2, HOSTS.parse("a 1.2.3.4\nbad 1.2.3.999\n")),
            "line 2")
    end

    -- -----------------------------------------------------------------
    H.group("hosts.load")
    do
        local files = { ["/etc/hosts.conf"] = "b 10.0.0.2\na 10.0.0.1\n" }
        local mtimes = { ["/etc/hosts.conf"] = 100 }
        local fsx = mem_fs(files, mtimes)
        local log, lines = H.logger()
        local h = HOSTS.new({
            fs = fsx, log = log, path = "/etc/hosts.conf", min_interval = 5,
        })
        H.eq("empty_initially", h:count(), 0)
        local ok, count = h:load()
        H.check("load_ok", ok == true, "load refused")
        H.eq("load_count", count, 2)
        H.eq("count_after_load", h:count(), 2)
        H.eq("resolve_ip", select(1, h:resolve("a")), ip2int("10.0.0.1"))
        H.eq("resolve_text", select(2, h:resolve("a")), "10.0.0.1")
        H.eq("resolve_miss", select(1, h:resolve("ghost")), nil)
        H.eq("resolve_miss_error", select(2, h:resolve("ghost")),
            "unknown host: ghost")
        H.eq("resolve_not_a_string", select(1, h:resolve(nil)), nil)
        H.eq("list_count", #h:list(), 2)
        H.eq("list_sorted_first", h:list()[1].name, "a")
        H.eq("list_sorted_last", h:list()[2].name, "b")
        H.eq("mtime_recorded", h.mtime, 100)
        H.has(lines, "HOSTS_LOAD path=/etc/hosts.conf entries=2")

        -- a bad file keeps the live table and logs HOSTS_BAD_FILE
        files["/etc/hosts.conf"] = "a 10.0.0.1\nbroken 10.0.0.300\n"
        mtimes["/etc/hosts.conf"] = 200
        local bad_ok, bad_err = h:load()
        H.check("bad_file_rejected", bad_ok == nil, "bad file accepted")
        H.contains("bad_file_error", bad_err, "line 2")
        H.eq("bad_file_keeps_count", h:count(), 2)
        H.eq("bad_file_keeps_entry", select(1, h:resolve("b")), ip2int("10.0.0.2"))
        H.has(lines, "HOSTS_BAD_FILE path=/etc/hosts.conf")
        H.eq("mtime_survives_bad", h.mtime, 100)

        -- a missing file also keeps the table
        files["/etc/hosts.conf"] = nil
        local missing_ok, missing_err = h:load()
        H.check("missing_rejected", missing_ok == nil, "missing file accepted")
        H.contains("missing_error", missing_err, "missing file")
        H.eq("missing_keeps_count", h:count(), 2)
        H.has(lines, "HOSTS_MISSING")

        H.check("load_uses_new_path", h:load("/etc/other.conf") == nil, "ghost file loaded")
        H.contains("new_path_error", select(2, h:load("/etc/other.conf")), "/etc/other.conf")
    end

    -- -----------------------------------------------------------------
    H.group("hosts.reload")
    do
        local path = "/etc/hosts.conf"
        local files = { [path] = "a 10.0.0.1\nb 10.0.0.2\n" }
        local mtimes = { [path] = 100 }
        local log, lines = H.logger()
        local h = HOSTS.new({ fs = mem_fs(files, mtimes), log = log, path = path })
        h:load()
        H.eq("baseline", h:count(), 2)

        local changed, why = h:reload_if_changed(10)
        H.eq("first_check", changed, false)
        H.eq("first_check_reason", why, "unchanged")

        files[path] = "a 10.0.0.1\nb 10.0.0.2\nc 10.0.0.3\n"
        mtimes[path] = 200
        local soon_ok, soon_why = h:reload_if_changed(12)
        H.eq("interval_gate", soon_ok, false)
        H.eq("interval_reason", soon_why, "too soon")
        H.eq("interval_keeps_count", h:count(), 2)

        local reloaded, reload_count = h:reload_if_changed(15)
        H.eq("interval_elapsed", reloaded, true)
        H.eq("reloaded_entries", reload_count, 3)
        H.eq("reloaded_resolve", select(1, h:resolve("c")), ip2int("10.0.0.3"))
        H.eq("reload_counter", h.reloads, 1)
        H.has(lines, "HOSTS_RELOAD path=/etc/hosts.conf entries=3")

        H.eq("second_unchanged", select(1, h:reload_if_changed(16)), false)
        H.eq("second_unchanged_reason", select(2, h:reload_if_changed(17)),
            "too soon")
        H.eq("third_unchanged", select(2, h:reload_if_changed(21)), "unchanged")

        -- a bad change is never applied; the table survives and the mtime gate
        -- retries on the next interval rather than skipping the file forever
        files[path] = "a 10.0.0.1\nbroken 10.0.0.999\n"
        mtimes[path] = 300
        local bad_ok, bad_why = h:reload_if_changed(26)
        H.eq("bad_reload", bad_ok, false)
        H.eq("bad_reload_reason", bad_why, "bad file")
        H.eq("bad_reload_keeps", h:count(), 3)
        H.has(lines, "HOSTS_BAD_FILE path=/etc/hosts.conf")
        H.eq("bad_reload_mtime_still_old", h.mtime, 200)

        files[path] = "a 10.0.0.1\nb 10.0.0.2\nc 10.0.0.3\nd 10.0.0.4\n"
        mtimes[path] = 400
        local fixed, fixed_count = h:reload_if_changed(31)
        H.eq("fixed_reload", fixed, true)
        H.eq("fixed_count", fixed_count, 4)
        H.eq("hosts_reload_logs", H.count(lines, "HOSTS_RELOAD"), 2)

        files[path] = nil
        H.eq("missing_reload", select(1, h:reload_if_changed(36)), false)
        H.eq("missing_reload_reason", select(2, h:reload_if_changed(37)), "too soon")

        local no_attr = HOSTS.new({ fs = { exists = function() return true end },
            log = log, path = path })
        H.eq("no_attributes", select(1, no_attr:reload_if_changed(1)), false)
        H.eq("no_attributes_reason", select(2, no_attr:reload_if_changed(6)),
            "no attributes")

        local fast = HOSTS.new({ fs = mem_fs(files, mtimes), log = log, path = path,
            min_interval = 0 })
        files[path] = "z 10.0.0.9\n"
        mtimes[path] = 500
        H.eq("zero_interval_reloads", select(1, fast:reload_if_changed(1)), true)
        H.eq("zero_interval_count", fast:count(), 1)
    end

    -- -----------------------------------------------------------------
    H.group("hosts.rpv_hook")
    do
        local node = { hosts = { keeper = 7 }, logs = {} }
        function node:log(fmt, ...)
            local text
            if select("#", ...) > 0 then
                text = string.format(fmt, ...)
            else
                text = tostring(fmt)
            end
            node.logs[#node.logs + 1] = text
        end
        local files = { ["/etc/hosts.conf"] = "a 10.0.0.1\nb 10.0.0.2\n" }
        local fsx = mem_fs(files)

        local count = HOSTS.hosts_load(node, "/etc/hosts.conf", { fs = fsx })
        H.eq("hook_count", count, 2)
        H.eq("hook_a", node.hosts.a, ip2int("10.0.0.1"))
        H.eq("hook_b", node.hosts.b, ip2int("10.0.0.2"))
        H.eq("hook_replaces_table", node.hosts.keeper, nil)
        H.eq("hook_entries_only", (function()
            local n = 0
            for _ in pairs(node.hosts) do n = n + 1 end
            return n
        end)(), 2)
        H.has(node.logs, "HOSTS_LOAD path=/etc/hosts.conf entries=2 source=rpv")

        -- the second value is an integer, that is what rpv expects
        H.eq("hook_types", type(node.hosts.a), "number")

        files["/etc/hosts.conf"] = "bad 10.0.0.256\n"
        local bad_count, bad_err = HOSTS.hosts_load(node, "/etc/hosts.conf", { fs = fsx })
        H.check("hook_bad_rejected", bad_count == nil, "bad file injected")
        H.eq("hook_bad_keeps_a", node.hosts.a, ip2int("10.0.0.1"))
        H.contains("hook_bad_error", bad_err, "bad ipv4")
        H.has(node.logs, "HOSTS_BAD_FILE path=/etc/hosts.conf")

        files["/etc/hosts.conf"] = nil
        local miss_count, miss_err = HOSTS.hosts_load(node, "/etc/hosts.conf", { fs = fsx })
        H.check("hook_missing_rejected", miss_count == nil, "missing injected")
        H.contains("hook_missing_error", miss_err, "missing file")
        H.eq("hook_missing_keeps_a", node.hosts.a, ip2int("10.0.0.1"))
        H.has(node.logs, "HOSTS_MISSING path=/etc/hosts.conf")

        H.check("hook_needs_node", HOSTS.hosts_load(nil, "/x") == nil, "nil node ok")
        H.eq("hook_node_error", select(2, HOSTS.hosts_load(nil, "/x")),
            "node table required")

        -- H.apply is the shared injection step
        local applied = HOSTS.apply(node, { { name = "z", ip = 1, text = "0.0.0.1" } })
        H.eq("apply_count", applied, 1)
        H.eq("apply_map", node.hosts.z, 1)
        H.eq("apply_drops_old", node.hosts.a, nil)
        H.eq("apply_bad_node", select(1, HOSTS.apply(nil, {})), nil)
        H.eq("apply_bad_node_error", select(2, HOSTS.apply(nil, {})),
            "node table required")
        H.eq("apply_bad_list", select(1, HOSTS.apply(node, nil)), nil)
    end

    -- -----------------------------------------------------------------
    H.group("hosts.module")
    do
        H.eq("default_path", HOSTS.DEFAULT_PATH, "/etc/hosts.conf")
        H.eq("default_interval", HOSTS.DEFAULT_MIN_INTERVAL, 5)
        H.eq("version", HOSTS.VERSION, "1.0")
        H.ascii_check("module_ascii", H.read("/system/net/hosts.lua") or "")
        local h = HOSTS.new({ fs = mem_fs({}), log = H.logger() })
        H.eq("new_defaults_to_path", h.path, "/etc/hosts.conf")
        H.eq("new_empty_count", h:count(), 0)
        H.eq("new_loads", h.loads, 0)
        H.eq("new_bad", h.bad, 0)
    end
end
