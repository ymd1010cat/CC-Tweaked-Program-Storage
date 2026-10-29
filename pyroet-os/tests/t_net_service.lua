--[[- pyroet-os/tests/t_net_service.lua -- net service: config, setup, hosts,
-- static neighbours/routes, probes, stats, health, kernel registration.

Everything the service talks to is a stub: a fake rpv table with a fake node
(no modem, no sockets, no os.sleep), and an in-memory file system. Timers are
recorded by node:after and fired by the test, so the timeout path is
deterministic.

No non-ASCII bytes in this file.
]]

local NET = dofile("/system/net/service.lua")
local HOSTS = dofile("/system/net/hosts.lua")
local KERNEL = dofile("/system/kernel/init.lua")

local function ip2int(text)
    local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a) * 16777216 + tonumber(b) * 65536
        + tonumber(c) * 256 + tonumber(d)
end

local function int2ip(value)
    local n = math.floor(value)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

local function masked(ip, prefix)
    if prefix <= 0 then return 0 end
    if prefix >= 32 then return ip end
    local size = 2 ^ (32 - prefix)
    return ip - (ip % size)
end

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
        if mode ~= "r" then return nil end
        if f.files[path] == nil then return nil end
        local text = f.files[path]
        local handle = {}
        function handle.readAll() return text end
        function handle.read() return text end
        function handle.close() end
        return handle
    end
    return f
end

-- fake rpv library whose node records every call the service makes
local function fake_rpv(opts)
    local o = opts or {}
    local rpv = {}
    rpv.calls = { nodes = {}, routes = {} }
    rpv.ip2int = ip2int
    rpv.int2ip = int2ip
    rpv.masked = masked
    rpv.route_add = function(routes, prefix, net, iface, gw, kind)
        local record = { prefix = prefix, net = net, iface = iface, gw = gw, kind = kind }
        routes.entries[#routes.entries + 1] = record
        rpv.calls.routes[#rpv.calls.routes + 1] = record
        return record
    end
    rpv.node_new = function(spec)
        local node = {
            cfg = {},
            ifaces = {},
            arp = { cache = {} },
            routes = { entries = {} },
            udp = { ports = {} },
            logs = {},
            timers = {},
            setup_calls = 0,
            binds = {},
            sockets = {},
        }
        function node:log(fmt, ...)
            local text
            if select("#", ...) > 0 then
                text = string.format(fmt, ...)
            else
                text = tostring(fmt)
            end
            node.logs[#node.logs + 1] = text
        end
        function node:setup()
            node.setup_calls = node.setup_calls + 1
            if o.setup_error then error(o.setup_error) end
        end
        function node:bind(port, cb)
            if o.bind_error then return nil, o.bind_error end
            local socket = { port = port, handler = cb, sent = {}, closed = false }
            function socket:sendto(dst, dport, data, ttl)
                socket.sent[#socket.sent + 1] = {
                    dst = dst, dport = dport, data = data, ttl = ttl,
                }
                if o.send_error then return false end
                return true
            end
            function socket:close() socket.closed = true end
            node.sockets[port] = socket
            node.binds[#node.binds + 1] = { port = port, socket = socket }
            return socket
        end
        function node:after(seconds, fn)
            node.timers[#node.timers + 1] = {
                seconds = seconds, fn = fn, fired = false,
            }
            return #node.timers
        end
        rpv.calls.nodes[#rpv.calls.nodes + 1] = { spec = spec, node = node }
        return node
    end
    return rpv
end

local function fire_timer(node, seconds)
    local fired = 0
    for i = 1, #node.timers do
        local timer = node.timers[i]
        if not timer.fired and timer.seconds == seconds then
            timer.fired = true
            timer.fn()
            fired = fired + 1
        end
    end
    return fired > 0
end

return function(H)
    -- -----------------------------------------------------------------
    H.group("net.config")
    do
        local cfg, err = NET.parse_config("ip=10.0.0.5\n")
        H.table("minimal_ok", cfg)
        H.eq("minimal_error", err, nil)
        H.eq("ip", cfg and cfg.ip, "10.0.0.5")
        H.eq("ip_int", cfg and cfg.ip_int, ip2int("10.0.0.5"))
        H.eq("prefix_default", cfg and cfg.prefix, 24)
        H.eq("gateway_default", cfg and cfg.gateway, nil)
        H.eq("side_default", cfg and cfg.iface_side, "back")
        H.eq("name_default", cfg and cfg.iface_name, "NET")
        H.eq("channel_default", cfg and cfg.channel, 4100)
        H.eq("mtu_default", cfg and cfg.mtu, 256)
        H.eq("role_default", cfg and cfg.role, "host")
        H.eq("linktype_default", cfg and cfg.linktype, "wired")
        H.eq("hosts_default", cfg and cfg.hosts_file, "/etc/hosts.conf")
        H.eq("hosts_not_explicit", cfg and cfg.hosts_file_explicit, false)
        H.eq("probe_port_default", cfg and cfg.probe_port, 47100)
        H.eq("interval_default", cfg and cfg.hosts_interval, 5)
        H.eq("ttl_default", cfg and cfg.neighbor_ttl, 3600)
        H.eq("neighbors_default", cfg and #cfg.neighbors, 0)
        H.eq("routes_default", cfg and #cfg.routes, 0)
        H.eq("unknown_default", cfg and #cfg.unknown, 0)

        local full = table.concat({
            "# edge node for the pocket",
            "",
            "ip=192.168.4.9",
            "prefix=26",
            "gateway=192.168.4.1",
            "iface_side=top",
            "iface_name=lan0-1",
            "channel=4101",
            "mtu=512",
            "linktype=wireless",
            "role=host",
            "hosts_file=/etc/hosts.conf",
            "probe_port=47200",
            "hosts_interval=7",
            "neighbor_ttl=60",
            "static_neighbor=192.168.4.2,1001",
            "static_neighbor = 192.168.4.3,1002",
            "static_route=10.9.0.0/16 via 192.168.4.1",
            "static_route = 10.10.0.0/24 via 192.168.4.1",
            "future_key=1",
        }, "\n")
        local full_cfg, full_err = NET.parse_config(full)
        H.table("full_ok", full_cfg)
        H.eq("full_error", full_err, nil)
        H.eq("full_prefix", full_cfg and full_cfg.prefix, 26)
        H.eq("full_gateway", full_cfg and full_cfg.gateway, "192.168.4.1")
        H.eq("full_side", full_cfg and full_cfg.iface_side, "top")
        H.eq("full_name", full_cfg and full_cfg.iface_name, "lan0-1")
        H.eq("full_channel", full_cfg and full_cfg.channel, 4101)
        H.eq("full_mtu", full_cfg and full_cfg.mtu, 512)
        H.eq("full_linktype", full_cfg and full_cfg.linktype, "wireless")
        H.eq("full_hosts_explicit", full_cfg and full_cfg.hosts_file_explicit, true)
        H.eq("full_probe_port", full_cfg and full_cfg.probe_port, 47200)
        H.eq("full_interval", full_cfg and full_cfg.hosts_interval, 7)
        H.eq("full_ttl", full_cfg and full_cfg.neighbor_ttl, 60)
        H.eq("full_neighbors", full_cfg and #full_cfg.neighbors, 2)
        H.eq("neighbor_ip", full_cfg and full_cfg.neighbors[1].ip,
            ip2int("192.168.4.2"))
        H.eq("neighbor_text", full_cfg and full_cfg.neighbors[1].ip_text,
            "192.168.4.2")
        H.eq("neighbor_mac", full_cfg and full_cfg.neighbors[1].mac, 1001)
        H.eq("neighbor_mac2", full_cfg and full_cfg.neighbors[2].mac, 1002)
        H.eq("full_routes", full_cfg and #full_cfg.routes, 2)
        H.eq("route_prefix", full_cfg and full_cfg.routes[1].prefix, 16)
        H.eq("route_net", full_cfg and full_cfg.routes[1].net, ip2int("10.9.0.0"))
        H.eq("route_net_text", full_cfg and full_cfg.routes[1].net_text, "10.9.0.0")
        H.eq("route_gw", full_cfg and full_cfg.routes[1].gw, ip2int("192.168.4.1"))
        H.eq("route2_prefix", full_cfg and full_cfg.routes[2].prefix, 24)
        H.eq("unknown_keys", full_cfg and full_cfg.unknown[1], "future_key")

        local masked_net = NET.parse_config("ip=10.0.0.5\nstatic_route=10.9.4.5/16 via 10.0.0.1\n")
        H.eq("route_masked", masked_net and masked_net.routes[1].net_text, "10.9.0.0")

        local bad = {
            { "missing_ip", "prefix=24", "missing required key 'ip'" },
            { "empty_ip", "ip=", "missing required key 'ip'" },
            { "bad_ip", "ip=10.0.0", "bad ipv4" },
            { "leading_zero", "ip=010.0.0.1", "bad ipv4" },
            { "bad_prefix", "ip=10.0.0.1\nprefix=33", "bad prefix" },
            { "prefix_zero", "ip=10.0.0.1\nprefix=0", "bad prefix" },
            { "prefix_text", "ip=10.0.0.1\nprefix=wide", "bad prefix" },
            { "bad_gateway", "ip=10.0.0.1\ngateway=10.0.0.256", "bad gateway" },
            { "bad_side", "ip=10.0.0.1\niface_side=left right", "bad iface_side" },
            { "bad_name", "ip=10.0.0.1\niface_name=bad name", "bad iface_name" },
            { "bad_channel", "ip=10.0.0.1\nchannel=0", "bad channel" },
            { "reserved_channel", "ip=10.0.0.1\nchannel=65534", "bad channel" },
            { "bad_mtu", "ip=10.0.0.1\nmtu=64", "bad mtu" },
            { "bad_linktype", "ip=10.0.0.1\nlinktype=red net", "bad linktype" },
            { "bad_role", "ip=10.0.0.1\nrole=host!", "bad role" },
            { "bad_hosts_path", "ip=10.0.0.1\nhosts_file=etc/hosts.conf", "bad hosts_file" },
            { "hosts_dotdot", "ip=10.0.0.1\nhosts_file=/etc/../hosts.conf", "bad hosts_file" },
            { "bad_probe_port", "ip=10.0.0.1\nprobe_port=0", "bad probe_port" },
            { "bad_interval", "ip=10.0.0.1\nhosts_interval=-1", "bad hosts_interval" },
            { "bad_ttl", "ip=10.0.0.1\nneighbor_ttl=abc", "bad neighbor_ttl" },
            { "bad_neighbor", "ip=10.0.0.1\nstatic_neighbor=10.0.0.2", "static_neighbor" },
            { "bad_neighbor_mac", "ip=10.0.0.1\nstatic_neighbor=10.0.0.2,abc", "static_neighbor" },
            { "bad_mac_range", "ip=10.0.0.1\nstatic_neighbor=10.0.0.2,4294967296", "static_neighbor" },
            { "bad_neighbor_ip", "ip=10.0.0.1\nstatic_neighbor=10.0.0.999,1", "static_neighbor" },
            { "bad_route", "ip=10.0.0.1\nstatic_route=10.9.0.0/16", "static_route" },
            { "bad_route_prefix", "ip=10.0.0.1\nstatic_route=10.9.0.0/33 via 10.0.0.1", "static_route" },
            { "bad_route_gw", "ip=10.0.0.1\nstatic_route=10.9.0.0/16 via nope", "static_route" },
            { "no_equals", "ip 10.0.0.1", "expected key=value" },
        }
        for i = 1, #bad do
            local case = bad[i]
            local value, perr = NET.parse_config(case[2])
            H.check(case[1], value == nil, "accepted: " .. case[2])
            H.contains(case[1] .. "_error", perr, case[3])
        end
        H.eq("not_a_string", select(1, NET.parse_config(nil)), nil)
        H.eq("not_a_string_error", select(2, NET.parse_config(nil)),
            "network text must be a string")
    end

    -- -----------------------------------------------------------------
    H.group("net.start")
    do
        local path = "/etc/network.conf"
        local files = {}
        files[path] = table.concat({
            "ip=10.0.0.5",
            "gateway=10.0.0.1",
            "static_neighbor=10.0.0.9,1001",
            "static_route=10.9.0.0/16 via 10.0.0.1",
            "unknown_key=1",
        }, "\n")
        local fsx = mem_fs(files)
        local rpv = fake_rpv()
        local log, lines = H.logger()
        local svc = NET.new({
            rpv = rpv, fs = fsx, log = log, hosts_module = HOSTS,
        })
        H.eq("name", NET.NAME, "net")
        H.eq("health_before_start", svc:health(), "degraded")
        H.check("start_true", svc:start() == true, "start refused")

        local node = svc.node
        H.table("node", node)
        H.eq("health_after_start", svc:health(), "ok")
        H.eq("node_new_calls", #rpv.calls.nodes, 1)
        local spec = rpv.calls.nodes[1].spec
        H.eq("spec_role", spec.role, "host")
        H.eq("spec_gw", spec.gw, "10.0.0.1")
        H.eq("spec_ifaces", #spec.ifaces, 1)
        H.eq("spec_side", spec.ifaces[1].side, "back")
        H.eq("spec_name", spec.ifaces[1].name, "NET")
        H.eq("spec_cidr", spec.ifaces[1].cidr, "10.0.0.5/24")
        H.eq("spec_channel", spec.ifaces[1].channel, 4100)
        H.eq("spec_mtu", spec.ifaces[1].mtu, 256)
        H.eq("setup_calls", node.setup_calls, 1)

        -- static neighbour is written where rpv's arp_resolve reads it
        local cache = node.arp.cache[ip2int("10.0.0.9")]
        H.table("neighbor_entry", cache)
        H.eq("neighbor_mac", cache and cache.mac, 1001)
        H.check("neighbor_expires", type(cache and cache.expires) == "number"
            and cache.expires > 0, "expires=" .. tostring(cache and cache.expires))
        H.eq("neighbor_static", cache and cache.static, true)
        H.has(lines, "NET_NEIGHBOR ip=10.0.0.9 mac=1001 ttl=3600")

        -- static route via rpv.route_add(kind="file")
        H.eq("route_calls", #rpv.calls.routes, 1)
        local route = rpv.calls.routes[1]
        H.eq("route_prefix", route.prefix, 16)
        H.eq("route_net", route.net, ip2int("10.9.0.0"))
        H.eq("route_gw", route.gw, ip2int("10.0.0.1"))
        H.eq("route_kind", route.kind, "file")
        H.has(lines, "NET_ROUTE dst=10.9.0.0/16 via=10.0.0.1 kind=file")

        -- defaults: no explicit hosts file, so a missing one is a note, not a fault
        H.has(lines, "NET_HOSTS_MISSING path=/etc/hosts.conf")
        H.has(lines, "NET_PROBE_SOCKET port=47100 ip=10.0.0.5")
        H.has(lines, "NET_READY ip=10.0.0.5/24 gw=10.0.0.1 iface=back ch=4100 hosts=0")
        H.has(lines, "NET_CONFIG_UNKNOWN key=unknown_key")
        H.check("probe_socket", svc.probe_socket ~= nil, "no probe socket")
        H.eq("probe_socket_port", svc.probe_socket and svc.probe_socket.port, 47100)
        H.eq("bind_calls", #node.binds, 1)

        local status = svc:status()
        H.eq("status_started", status.started, true)
        H.eq("status_health", status.health, "ok")
        H.eq("status_ip", status.ip, "10.0.0.5")
        H.eq("status_prefix", status.prefix, 24)
        H.eq("status_gateway", status.gateway, "10.0.0.1")
        H.eq("status_iface", status.iface, "back")
        H.eq("status_channel", status.channel, 4100)
        H.eq("status_hosts", status.hosts, 0)
        H.eq("status_probe_port", status.probe_port, 47100)
        H.eq("status_reasons", #status.reasons, 0)

        local stats = svc:stats()
        H.eq("stats_sent_initial", stats.sent, 0)
        H.eq("stats_received_initial", stats.received, 0)
        H.eq("stats_timeouts_initial", stats.timeouts, 0)
        H.eq("stats_inflight_initial", stats.inflight, 0)

        -- restart is idempotent, not a second node
        H.check("restart_true", svc:start() == true, "restart refused")
        H.eq("restart_single_node", #rpv.calls.nodes, 1)
        H.ascii_check("service_logs_ascii", H.joined(lines))

        -- hosts reload timer is armed at the configured interval
        local armed = false
        for i = 1, #node.timers do
            if node.timers[i].seconds == 5 then armed = true end
        end
        H.eq("reload_timer_armed", armed, true)
    end

    -- -----------------------------------------------------------------
    H.group("net.degraded")
    do
        local path = "/etc/network.conf"
        local log, lines = H.logger()

        local missing = NET.new({
            rpv = fake_rpv(), fs = mem_fs({}), log = log, hosts_module = HOSTS,
        })
        H.check("missing_start_true", missing:start() == true, "missing config crashed")
        H.eq("missing_health", missing:health(), "degraded")
        H.eq("missing_node", missing.node, nil)
        H.eq("missing_ip", missing:status().ip, nil)
        H.eq("missing_hosts", #missing:list_hosts(), 0)
        H.has(lines, "NET_CONFIG_BAD path=/etc/network.conf")
        H.has(lines, "NET_DEGRADED reasons=config")

        local bad_files = { [path] = "ip=10.0.0.300\n" }
        local bad = NET.new({
            rpv = fake_rpv(), fs = mem_fs(bad_files), log = log,
            hosts_module = HOSTS,
        })
        H.check("bad_start_true", bad:start() == true, "bad config crashed")
        H.eq("bad_health", bad:health(), "degraded")
        H.has(lines, "NET_CONFIG_BAD path=/etc/network.conf")
        H.contains("bad_config_error", H.joined(lines), "err=bad ipv4")

        local no_rpv = NET.new({
            fs = mem_fs({ [path] = "ip=10.0.0.5\n" }), log = log,
            hosts_module = HOSTS,
        })
        H.check("no_rpv_start_true", no_rpv:start() == true, "no rpv crashed")
        H.eq("no_rpv_health", no_rpv:health(), "degraded")
        H.has(lines, "NET_RPV_MISSING")
        H.eq("no_rpv_node", no_rpv.node, nil)

        local boom = fake_rpv({ setup_error = "modem boom" })
        local setup_fail = NET.new({
            rpv = boom, fs = mem_fs({ [path] = "ip=10.0.0.5\n" }), log = log,
            hosts_module = HOSTS,
        })
        H.check("setup_fail_start_true", setup_fail:start() == true, "setup crash")
        H.eq("setup_fail_health", setup_fail:health(), "degraded")
        H.has(lines, "NET_SETUP_FAIL")
        H.contains("setup_fail_detail", H.joined(lines), "modem boom")
        H.check("setup_fail_node_kept", setup_fail.node ~= nil, "node dropped")

        local explicit_bad = {
            [path] = "ip=10.0.0.5\nhosts_file=/etc/bad.conf\n",
            ["/etc/bad.conf"] = "host 10.0.0.999\n",
        }
        local hosts_bad = NET.new({
            rpv = fake_rpv(), fs = mem_fs(explicit_bad), log = log,
            hosts_module = HOSTS,
        })
        hosts_bad:start()
        H.eq("hosts_bad_health", hosts_bad:health(), "degraded")
        H.has(lines, "NET_HOSTS_BAD path=/etc/bad.conf")
        H.has(lines, "HOSTS_BAD_FILE path=/etc/bad.conf")
        H.eq("hosts_bad_items", hosts_bad:status().hosts, 0)

        local bind_fail = NET.new({
            rpv = fake_rpv({ bind_error = "port busy" }),
            fs = mem_fs({ [path] = "ip=10.0.0.5\n" }),
            log = log, hosts_module = HOSTS,
        })
        bind_fail:start()
        H.eq("bind_fail_health", bind_fail:health(), "degraded")
        H.has(lines, "NET_PROBE_SOCKET_FAIL port=47100")
        H.eq("bind_fail_probe", select(1, bind_fail:probe("10.0.0.9", 9)), nil)
        H.eq("bind_fail_probe_error", select(2, bind_fail:probe("10.0.0.9", 9)),
            "probe socket unavailable")
    end

    -- -----------------------------------------------------------------
    H.group("net.hosts")
    do
        local path = "/etc/network.conf"
        local hosts_path = "/etc/hosts.conf"
        local files = {
            [path] = "ip=10.0.0.5\nhosts_file=/etc/hosts.conf\n",
            [hosts_path] = "gw 10.0.0.1\nbox 10.0.0.9\n",
        }
        local mtimes = { [hosts_path] = 300 }
        local fsx = mem_fs(files, mtimes)
        local log, lines = H.logger()
        local svc = NET.new({
            rpv = fake_rpv(), fs = fsx, log = log, hosts_module = HOSTS,
        })
        svc:start()
        H.eq("hosts_health", svc:health(), "ok")
        H.eq("hosts_count", svc:status().hosts, 2)
        H.eq("hosts_resolve", select(1, svc:resolve("box")), ip2int("10.0.0.9"))
        H.eq("hosts_resolve_text", select(2, svc:resolve("box")), "10.0.0.9")
        H.eq("hosts_miss", select(1, svc:resolve("nope")), nil)
        H.eq("hosts_miss_error", select(2, svc:resolve("nope")),
            "unknown host: nope")
        H.eq("hosts_list_count", #svc:list_hosts(), 2)
        H.eq("hosts_list_first", svc:list_hosts()[1].name, "box")
        H.eq("node_hosts_injected", svc.node.hosts.box, ip2int("10.0.0.9"))
        H.eq("node_hosts_gw", svc.node.hosts.gw, ip2int("10.0.0.1"))
        H.has(lines, "NET_HOSTS path=/etc/hosts.conf entries=2")
        H.has(lines, "HOSTS_LOAD path=/etc/hosts.conf entries=2")

        files[hosts_path] = "gw 10.0.0.1\nbox 10.0.0.10\nc 10.0.0.11\n"
        mtimes[hosts_path] = 500
        local changed, count = svc:reload_hosts(200)
        H.eq("reload_changed", changed, true)
        H.eq("reload_count", count, 3)
        H.eq("reload_resolve", select(1, svc:resolve("box")), ip2int("10.0.0.10"))
        H.eq("reload_node_hosts", svc.node.hosts.box, ip2int("10.0.0.10"))
        H.has(lines, "NET_HOSTS_RELOAD entries=3")
        H.eq("reload_too_soon", select(1, svc:reload_hosts(201)), false)
        H.eq("reload_too_soon_reason", select(2, svc:reload_hosts(202)), "too soon")
        H.eq("reload_unchanged", select(2, svc:reload_hosts(205)), "unchanged")

        local no_hosts_engine = NET.new({
            rpv = fake_rpv(), fs = mem_fs({ [path] = "ip=10.0.0.5\n" }),
            log = log, hosts_module = HOSTS,
        })
        no_hosts_engine:start()
        -- the engine exists even when the file is absent
        H.table("empty_hosts_engine", no_hosts_engine.hosts)
        H.eq("empty_hosts_list", #no_hosts_engine:list_hosts(), 0)
    end

    -- -----------------------------------------------------------------
    H.group("net.probe")
    do
        local path = "/etc/network.conf"
        local files = { [path] = "ip=10.0.0.5\nprobe_port=47200\n" }
        local rpv = fake_rpv()
        local log, lines = H.logger()
        local svc = NET.new({
            rpv = rpv, fs = mem_fs(files), log = log, hosts_module = HOSTS,
        })
        svc:start()
        local node = svc.node
        H.eq("socket_port", svc.probe_socket.port, 47200)

        local callbacks = {}
        local probe = svc:probe("10.0.0.9", 9, "hello", 2, function(result)
            callbacks[#callbacks + 1] = result
        end)
        H.table("probe_handle", probe)
        H.eq("probe_pending", probe and probe.done, false)
        H.eq("probe_ip", probe and probe.ip, "10.0.0.9")
        H.eq("probe_port", probe and probe.port, 9)
        H.eq("stats_sent", svc:stats().sent, 1)
        local sent = svc.probe_socket.sent[1]
        H.table("send_record", sent)
        H.eq("send_dst", sent and sent.dst, ip2int("10.0.0.9"))
        H.eq("send_dport", sent and sent.dport, 9)
        H.contains("send_token", sent and sent.data, "PYROET-NET-PROBE-1")
        H.contains("send_payload", sent and sent.data, "hello")
        H.has(lines, "NET_PROBE_SEND dst=10.0.0.9 port=9 timeout=2.00s")

        svc.probe_socket.handler(sent.data, ip2int("10.0.0.9"), 9, svc.probe_socket)
        H.eq("probe_done", probe.done, true)
        H.eq("probe_ok", probe.result.ok, true)
        H.eq("probe_bytes", probe.result.bytes, #sent.data)
        H.check("probe_rtt", type(probe.result.rtt) == "number", "no rtt")
        H.eq("callback_count", #callbacks, 1)
        H.eq("callback_ok", callbacks[1] and callbacks[1].ok, true)
        H.eq("stats_received", svc:stats().received, 1)
        H.eq("stats_timeouts_after_ok", svc:stats().timeouts, 0)
        H.has(lines, "NET_PROBE_REPLY dst=10.0.0.9 port=9")

        -- an unrelated datagram is ignored (no probe completes)
        local other = svc:probe("10.0.0.10", 9, "x", 2)
        svc.probe_socket.handler("not ours", ip2int("10.0.0.11"), 9, svc.probe_socket)
        H.eq("unmatched_still_pending", other.done, false)

        -- timeout: the node timer fires, no reply arrived
        H.check("timeout_timer_armed", fire_timer(node, 2), "no 2 s timer")
        H.eq("timeout_done", other.done, true)
        H.eq("timeout_ok", other.result.ok, false)
        H.eq("timeout_err", other.result.err, "timeout")
        H.eq("stats_timeouts", svc:stats().timeouts, 1)
        H.eq("stats_sent_total", svc:stats().sent, 2)
        H.eq("stats_received_total", svc:stats().received, 1)
        H.eq("inflight_after_timeout", svc:stats().inflight, 0)
        H.has(lines, "NET_PROBE_TIMEOUT dst=10.0.0.10 port=9")

        -- bad arguments never reach the socket
        H.eq("bad_ip", select(1, svc:probe("10.0.0.256", 9)), nil)
        H.eq("bad_ip_error", select(2, svc:probe("10.0.0.256", 9)),
            "bad ipv4: 10.0.0.256")
        H.eq("bad_port_zero", select(2, svc:probe("10.0.0.9", 0)), "bad port: 0")
        H.eq("bad_port_text", select(2, svc:probe("10.0.0.9", "http")),
            "bad port: http")
        H.eq("bad_port_high", select(2, svc:probe("10.0.0.9", 70000)),
            "bad port: 70000")
        H.eq("bad_ip_sent", svc:stats().sent, 2)

        -- a refused send (no route / reserved address) is not a timeout
        local refused = fake_rpv({ send_error = true })
        local refused_log, refused_lines = H.logger()
        local refused_svc = NET.new({
            rpv = refused, fs = mem_fs({ [path] = "ip=10.0.0.5\n" }),
            log = refused_log, hosts_module = HOSTS,
        })
        refused_svc:start()
        local failed = refused_svc:probe("10.0.0.9", 9)
        H.eq("send_fail_done", failed.done, true)
        H.eq("send_fail_ok", failed.result.ok, false)
        H.eq("send_fail_error", failed.result.err, "unreachable")
        H.eq("send_fail_sent", refused_svc:stats().sent, 1)
        H.eq("send_fail_received", refused_svc:stats().received, 0)
        H.eq("send_fail_timeouts", refused_svc:stats().timeouts, 0)
        H.has(refused_lines, "NET_PROBE_FAIL dst=10.0.0.9 port=9 err=unreachable")

        -- stop closes the socket, fails in-flight probes and refuses new ones
        svc:stop()
        H.eq("stop_closes_socket", svc.probe_socket.closed, true)
        H.eq("stop_health", svc:health(), "degraded")
        H.check("stop_idempotent", svc:stop() == true, "second stop refused")
        H.has(lines, "NET_STOP socket_closed=1")
        H.eq("probe_after_stop", select(1, svc:probe("10.0.0.9", 9)), nil)
        H.eq("probe_after_stop_error", select(2, svc:probe("10.0.0.9", 9)),
            "service stopped")
    end

    -- -----------------------------------------------------------------
    H.group("net.register")
    do
        local path = "/etc/network.conf"
        local files = { [path] = "ip=10.0.0.5\n" }
        local log, lines = H.logger()
        local spec = NET.spec({
            rpv = fake_rpv(), fs = mem_fs(files), log = log,
            hosts_module = HOSTS,
        })
        H.eq("spec_name", spec.name, "net")
        H.eq("spec_deps", #spec.deps, 0)
        H.eq("spec_start", type(spec.start), "function")
        H.eq("spec_stop", type(spec.stop), "function")
        H.eq("spec_health", type(spec.health), "function")
        H.eq("spec_service", type(spec.service), "table")

        local kernel = KERNEL.new({ log = log })
        local registered, register_err, service = NET.register(kernel, {
            rpv = fake_rpv(), fs = mem_fs(files), log = log,
            hosts_module = HOSTS,
        })
        H.check("register_ok", registered ~= nil, "register failed: " .. tostring(register_err))
        H.eq("register_error", register_err, nil)
        H.table("register_service", service)
        local status = kernel:start_all()
        H.eq("kernel_health", status.health, "ok")
        H.eq("kernel_running", status.counts.running, 1)
        H.eq("kernel_service_name", status.services[1].name, "net")
        H.eq("kernel_service_state", status.services[1].state, "running")
        H.eq("kernel_service_healthy", status.services[1].healthy, "ok")
        H.eq("service_health", service:health(), "ok")
        H.has(lines, "KERNEL_SERVICE_START name=net")

        -- a config failure degrades one service, it does not fail the kernel
        local degraded_log, degraded_lines = H.logger()
        local k2 = KERNEL.new({ log = degraded_log })
        local ok2, err2, svc2 = NET.register(k2, {
            rpv = fake_rpv(), fs = mem_fs({}), log = degraded_log,
            hosts_module = HOSTS,
        })
        H.check("degraded_register", ok2 ~= nil, "register failed: " .. tostring(err2))
        local status2 = k2:start_all()
        H.eq("degraded_kernel_health", status2.health, "degraded")
        H.eq("degraded_kernel_running", status2.counts.running, 1)
        H.eq("degraded_kernel_failed", status2.counts.failed, 0)
        H.eq("degraded_service_state", status2.services[1].state, "running")
        H.eq("degraded_service_healthy", status2.services[1].healthy, "degraded")
        H.eq("degraded_service_health", svc2:health(), "degraded")
        H.has(degraded_lines, "KERNEL_DEGRADED health=degraded")

        H.eq("register_needs_kernel", select(1, NET.register(nil, {})), nil)
        H.eq("register_kernel_error", select(2, NET.register(nil, {})),
            "kernel table required")
        H.ascii_check("service_source_ascii", H.read("/system/net/service.lua") or "")
    end
end
