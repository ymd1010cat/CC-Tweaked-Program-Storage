--[[- apps/router.lua - RPV1 router: core routing + a fixed 19x51 terminal UI.

Round 1 scope (ROUTER ROUND 1 CONTRACT v1):

  * Router.new(opts) builds the state object; Router.node_spec(opts) is the node
    spec handed to rpv.node_new when the caller does not pass a pre-built node.
  * start() configures node.cfg, runs node:setup(), installs the two static LAN
    routes the DHCP server needs (255.255.255.255/32 and 10.254.0.0/16) and only
    then starts the DHCP server. That order is what makes DHCP and NAT coexist:
    services.dhcp_reply unicasts when node:resolve(src) finds a route and
    broadcasts otherwise, so a route installed after the server started would be
    missing when the first DISCOVER is answered.
  * NAT is on by default: cfg.nat_out is forced to the WAN interface name (the
    nat_new fallback would otherwise pick the first non-WAN interface and treat
    the LAN as external) and cfg.dhcp_probe defaults to "0" (the ICMP conflict
    probe cannot work while NAT rewrites the probe replies).
  * The UI is a fixed 19 row x 51 column screen redrawn by a coroutine task
    (node:add_task "router-tui"); every normal line is padded or clipped to 51
    chars and the layout never depends on the terminal size.
  * print() is hijacked while the router runs, so any node:log/print from the
    rest of the library lands in the ring buffer instead of the screen.

All terminal access goes through pcall and missing methods are skipped, every
rpv/node call that can fail is pcalled too, and refresh/render/leases only read
the node (node.dhcp and its lease table are never mutated).
]]
local ARGV = ...

local Router = {}

Router.VERSION = "0.1"
Router.COLS = 51
Router.ROWS = 19
Router.MIN_COLS = 51
Router.MIN_ROWS = 19
Router.LOG_ROWS = 8
Router.MIN_LOG_KEEP = 8
Router.LEASE_ROWS = 5
Router.DEFAULT_INTERVAL = 0.25
Router.TOO_SMALL = "TERMINAL TOO SMALL (need 51x19)"
Router.KEYS_HELP = "q quit  r refresh  l clear  j/k log  J/K page"

local DEFAULTS = {
    lan_ip = "192.168.1.1",
    lan_prefix = 24,
    lan_name = "LAN",
    wan_name = "WAN",
    lan_side = "back",
    wan_side = "top",
    lan_channel = 1001,
    wan_channel_band = 2000,
    wan_ip = "10.0.0.2/24",
    wan_gw = "10.0.0.1",
    dhcp_range = "192.168.1.100-192.168.1.150",
    log_lines = 8,
    lease_rows = 5,
    nat = true,
    nat_out = "WAN",
    dhcp_lease = 600,
    dhcp_port = 6700,
    setup = true,
    print_hijack = true,
    interval = 0.25,
}

-- ===== small helpers ========================================================

-- the script environment (_G on Lua 5.1, _ENV on 5.2+); nil when neither exists
local function global_env()
    local g = _G
    if type(g) == "table" then return g end
    g = _ENV
    if type(g) == "table" then return g end
    return nil
end

-- the global term table when the emulator/CC provides one
local function global_term()
    local ok, t = pcall(function() return term end)
    if ok and type(t) == "table" then return t end
    return nil
end

local function fit(text, width)
    local s = tostring(text or "")
    if #s > width then return s:sub(1, width) end
    if #s < width then return s .. string.rep(" ", width - #s) end
    return s
end

-- ring entries are one line each: collapse newlines/tabs so a multi-line print
-- cannot corrupt the fixed layout
local function one_line(text)
    local s = tostring(text)
    s = s:gsub("[\r\n\t]", " ")
    return (s)
end

local function hms(t)
    t = math.max(0, math.floor(tonumber(t) or 0))
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

-- formats the REMAINING seconds reported by leases():
-- nil -> "-", <=0 -> "expired", <60 -> "<n>s", <3600 -> "<m>m<ss>s",
-- otherwise "<h>h<mm>m"
local function expiry_text(remaining)
    if remaining == nil then return "-" end
    if type(remaining) ~= "number" then return "-" end
    if remaining ~= remaining then return "-" end
    if remaining <= 0 then return "expired" end
    if remaining < 60 then return string.format("%ds", math.floor(remaining)) end
    if remaining < 3600 then
        local m = math.floor(remaining / 60)
        local s = math.floor(remaining % 60)
        return string.format("%dm%02ds", m, s)
    end
    local h = math.floor(remaining / 3600)
    local m = math.floor((remaining % 3600) / 60)
    return string.format("%dh%02dm", h, m)
end

-- "192.168.1.100-192.168.1.150" or { lo = , hi = } -> "lo-hi" (nil when invalid)
local function pool_string(range)
    if type(range) == "string" then
        local lo, hi = range:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)%s*$")
        if lo and hi then return lo .. "-" .. hi end
        return nil
    end
    if type(range) == "table" then
        local lo = range.lo or range[1]
        local hi = range.hi or range[2]
        if lo and hi then return tostring(lo) .. "-" .. tostring(hi) end
    end
    return nil
end

-- dotted quad -> integer, with the rpv implementation first and a local
-- fallback only when the namespace does not provide one
local function ip2int_value(rpv, text)
    if rpv and type(rpv.ip2int) == "function" then
        local ok, v = pcall(rpv.ip2int, text)
        if ok and type(v) == "number" then return v end
    end
    local a, b, c, d = tostring(text):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a) * 16777216 + tonumber(b) * 65536 + tonumber(c) * 256 + tonumber(d)
end

local function int2ip_value(rpv, n)
    if type(n) ~= "number" then return tostring(n) end
    if rpv and type(rpv.int2ip) == "function" then
        local ok, s = pcall(rpv.int2ip, n)
        if ok and type(s) == "string" then return s end
    end
    n = math.floor(n)
    if n < 0 then n = 0 end
    local a = math.floor(n / 16777216) % 256
    local b = math.floor(n / 65536) % 256
    local c = math.floor(n / 256) % 256
    local d = n % 256
    return string.format("%d.%d.%d.%d", a, b, c, d)
end

local function masked_value(rpv, n, prefix)
    if rpv and type(rpv.masked) == "function" then
        local ok, v = pcall(rpv.masked, n, prefix)
        if ok and type(v) == "number" then return v end
    end
    if prefix <= 0 then return 0 end
    if prefix >= 32 then return n end
    local block = 2 ^ (32 - prefix)
    return math.floor(n / block) * block
end

local function header_line(status)
    return string.format("LAN %s  WAN %s  DHCP %d  CH %d  UP %s",
        tostring(status.lan_ip), status.wan_up and "up" or "down",
        tonumber(status.dhcp_bound) or 0, tonumber(status.channels) or 0,
        tostring(status.uptime_text))
end

-- ===== option normalisation ================================================

local function resolve_opts(opts)
    opts = type(opts) == "table" and opts or {}
    local o = {}
    for k, v in pairs(DEFAULTS) do
        if opts[k] ~= nil then o[k] = opts[k] else o[k] = v end
    end
    o.node = opts.node
    o.rpv = opts.rpv
    o.term = opts.term
    -- not in DEFAULTS on purpose: nil means "use the NAT default (\"0\")", an
    -- explicit value must reach start() intact
    o.dhcp_probe = opts.dhcp_probe
    if o.term == nil then o.term = global_term() end
    if type(opts.clock) == "function" then
        o.clock = opts.clock
    elseif type(os) == "table" and type(os.clock) == "function" then
        o.clock = os.clock
    else
        o.clock = nil
    end
    o.min_cols = Router.MIN_COLS
    o.min_rows = Router.MIN_ROWS
    o.lan_prefix = tonumber(o.lan_prefix) or 24
    o.lan_channel = tonumber(o.lan_channel) or 1001
    o.wan_channel_band = tonumber(o.wan_channel_band) or 2000
    o.dhcp_lease = tonumber(o.dhcp_lease) or 600
    o.dhcp_port = tonumber(o.dhcp_port) or 6700
    o.log_lines = math.max(1, math.floor(tonumber(o.log_lines) or Router.LOG_ROWS))
    o.lease_rows = math.max(1, math.floor(tonumber(o.lease_rows) or Router.LEASE_ROWS))
    local interval = tonumber(o.interval)
    if not interval or interval ~= interval or interval <= 0 then interval = Router.DEFAULT_INTERVAL end
    o.interval = interval
    return o
end

-- ===== construction ========================================================

function Router.node_spec(opts)
    local o = resolve_opts(opts)
    return {
        role = "router",
        gw = o.wan_gw,
        ifaces = {
            {
                side = o.lan_side, name = o.lan_name,
                cidr = tostring(o.lan_ip) .. "/" .. tostring(o.lan_prefix),
                channel = o.lan_channel, mtu = 256, linktype = "wireless",
            },
            {
                side = o.wan_side, name = o.wan_name, cidr = tostring(o.wan_ip),
                channel = o.wan_channel_band, mtu = 512, linktype = "wireless",
            },
        },
    }
end

function Router.new(opts)
    local o = resolve_opts(opts)
    local rpv = o.rpv or ARGV
    local node = o.node
    if node == nil then
        if not (type(rpv) == "table" and type(rpv.node_new) == "function") then
            error("router.new: opts.node is required", 2)
        end
        local ok, built = pcall(rpv.node_new, Router.node_spec(o))
        if not ok then error("router.new: node_new failed: " .. tostring(built), 2) end
        if type(built) ~= "table" then error("router.new: node_new returned no node", 2) end
        node = built
    end
    local r = setmetatable({}, Router)
    r.node = node
    r.opts = o
    r.rpv = rpv or {}
    r.logs = {}
    r.scroll = 0
    r.lease_page = 1
    r.log_lines = o.log_lines
    -- the ring always buffers at least a full window, so a small log_lines still
    -- leaves older lines to scroll to (j/k is otherwise unreachable)
    r.log_keep = math.max(o.log_lines, Router.MIN_LOG_KEEP)
    r.lease_rows = o.lease_rows
    r.running = false
    r.started = false
    r.started_at = nil
    r.print_hijacked = false
    r.blocked = {}
    r.status = nil
    -- internal bookkeeping (not part of the documented field set)
    r.saved_print = nil
    r.dhcp_pool = nil
    r.lease_list = {}
    r.pages = 1
    r.stopped = false
    return r
end

-- ===== print hijack ========================================================

function Router:install_print()
    if self.print_hijacked then return true end
    local g = global_env()
    if not g then return false end
    local original = g.print
    if type(original) ~= "function" then return false end
    local self_ref = self
    local function hook(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        pcall(self_ref.log, self_ref, table.concat(parts, " "))
    end
    self.saved_print = original
    local ok = pcall(function() g.print = hook end)
    if not ok or g.print ~= hook then
        self.saved_print = nil
        return false
    end
    self.print_hijacked = true
    return true
end

function Router:restore_print()
    if not self.print_hijacked then return true end
    local g = global_env()
    local restored = false
    if g and type(self.saved_print) == "function" then
        restored = pcall(function() g.print = self.saved_print end)
        if not restored then restored = false end
    end
    self.print_hijacked = false
    self.saved_print = nil
    return restored and true or false
end

-- ===== routing helpers =====================================================

function Router:lan_iface()
    local node = self.node
    local ifaces = type(node) == "table" and node.ifaces or nil
    if type(ifaces) ~= "table" then return nil end
    local want = self.opts.lan_name
    for _, iface in ipairs(ifaces) do
        if type(iface) == "table" and iface.name == want then return iface end
    end
    for _, iface in ipairs(ifaces) do
        if type(iface) == "table" and not iface.is_wan and not iface.is_fabric then return iface end
    end
    return nil
end

function Router:block(api)
    local name = tostring(api)
    for i = 1, #self.blocked do
        if self.blocked[i] == name then return false end
    end
    self.blocked[#self.blocked + 1] = name
    self:log("ROUTER_BLOCKED api=" .. name)
    return true
end

-- install one static route through the LAN interface; idempotent on prefix+net
function Router:install_route(prefix, net_text)
    local node = self.node
    local rpv = self.rpv or {}
    local ipint = ip2int_value(rpv, net_text)
    if ipint == nil then
        self:block("ip2int")
        return false
    end
    local net = masked_value(rpv, ipint, prefix)
    local rt = type(node) == "table" and node.routes or nil
    if type(rt) ~= "table" then
        if type(rpv.route_new) ~= "function" then
            self:block("route_new")
            return false
        end
        local ok, made = pcall(rpv.route_new)
        if not ok or type(made) ~= "table" then
            self:block("route_new")
            return false
        end
        rt = made
        if type(node) == "table" then node.routes = rt end
    end
    local entries = rt.entries
    if type(entries) ~= "table" then
        entries = {}
        rt.entries = entries
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and entry.prefix == prefix and entry.net == net then
            return false
        end
    end
    if type(rpv.route_add) ~= "function" then
        self:block("route_add")
        return false
    end
    local ok, err = pcall(rpv.route_add, rt, prefix, net, self:lan_iface(), nil, "static")
    if not ok then
        self:log("ROUTER_ROUTE_ERROR net=" .. tostring(net_text) .. " err=" .. tostring(err))
        return false
    end
    return true
end

-- ===== lifecycle ===========================================================

function Router:now()
    local clock = self.opts.clock
    if type(clock) ~= "function" then return 0 end
    local ok, value = pcall(clock)
    if ok and type(value) == "number" then return value end
    return 0
end

function Router:start()
    if self.started then return true end
    local node = self.node
    if type(node) ~= "table" then
        error("router.start: node is missing", 2)
    end
    local opts = self.opts
    self.dhcp_pool = pool_string(opts.dhcp_range)
    if opts.print_hijack then self:install_print() end

    local cfg = node.cfg
    if type(cfg) ~= "table" then
        cfg = {}
        node.cfg = cfg
    end
    if cfg.role == nil then cfg.role = "router" end
    cfg.dhcp_gw = opts.lan_ip
    cfg.dhcp_dns = opts.lan_ip
    cfg.dhcp_lease = opts.dhcp_lease
    cfg.dhcp_port = opts.dhcp_port
    if opts.dhcp_probe ~= nil then
        cfg.dhcp_probe = tostring(opts.dhcp_probe)
    elseif opts.nat then
        cfg.dhcp_probe = "0"
    end
    if opts.nat then cfg.nat = "1" end
    -- nat_new falls back to the first non-WAN interface when cfg.nat_out does not
    -- name one, which would make the LAN look like the external side
    local nat_iface = opts.wan_name or opts.nat_out
    if nat_iface then cfg.nat_out = nat_iface end

    if opts.setup and type(node.setup) == "function" then
        local ok, err = pcall(node.setup, node)
        if not ok then
            self.running = false
            self:log("ROUTER_SETUP_ERROR err=" .. tostring(err))
            self:restore_print()
            return false
        end
    end

    -- real node.ifaces is empty before setup(), so the LAN interface object only
    -- exists here; the DHCP server must find these routes already installed
    self:install_route(32, "255.255.255.255")
    self:install_route(16, "10.254.0.0")

    cfg.dhcp_pool = self.dhcp_pool
    if self.dhcp_pool and not node.dhcp then
        local rpv = self.rpv
        if not (type(rpv) == "table" and type(rpv.dhcp_server_start) == "function") then
            self:block("dhcp_server_start")
        else
            local ok, err = pcall(rpv.dhcp_server_start, node)
            if not ok then self:log("ROUTER_DHCP_ERROR err=" .. tostring(err)) end
        end
    end

    -- the task tests self.running on its first line, so arm it before registering
    self.running = true
    if type(node.add_task) == "function" then
        local ok, err = pcall(node.add_task, node, "router-tui", function()
            while self.running do
                os.sleep(self.opts.interval)
                pcall(self.tick, self)
            end
        end)
        if not ok then self:log("ROUTER_TASK_ERROR err=" .. tostring(err)) end
    end
    self.started = true
    self.started_at = self:now()
    self:refresh()
    self:draw()
    self:log(string.format("ROUTER_START lan=%s/%s wan=%s", tostring(opts.lan_ip),
        tostring(opts.lan_prefix), tostring(opts.wan_name)))
    return true
end

function Router:stop()
    self.running = false
    self:restore_print()
    if not self.stopped then
        self.stopped = true
        self:log("ROUTER_STOP")
    end
    return true
end

-- ===== ring buffer / status ================================================

function Router:clamp_scroll()
    -- one window is log_lines tall, so at most (#logs - log_lines) entries can be
    -- scrolled back out of view
    local max_scroll = #self.logs - self.log_lines
    if max_scroll < 0 then max_scroll = 0 end
    if self.scroll > max_scroll then self.scroll = max_scroll end
    if self.scroll < 0 then self.scroll = 0 end
    return max_scroll
end

function Router:log(text)
    local line = tostring(text)
    self.logs[#self.logs + 1] = line
    local keep = self.log_keep or math.max(self.log_lines, Router.MIN_LOG_KEEP)
    while #self.logs > keep do
        table.remove(self.logs, 1)
    end
    self:clamp_scroll()
    return line
end

function Router:wan_up()
    local node = self.node
    if type(node) ~= "table" then return false end
    local ifaces = node.ifaces
    if type(ifaces) == "table" then
        for _, iface in ipairs(ifaces) do
            if type(iface) == "table" and iface.is_wan then return true end
        end
    end
    return type(node.wan) == "table"
end

function Router:bound_count()
    local node = self.node
    local srv = type(node) == "table" and node.dhcp or nil
    local by_ip = type(srv) == "table" and srv.by_ip or nil
    if type(by_ip) ~= "table" then return 0 end
    local n = 0
    for _, lease in pairs(by_ip) do
        if type(lease) == "table" and lease.state == "bound" then n = n + 1 end
    end
    return n
end

function Router:channel_count()
    local node = self.node
    local ifaces = type(node) == "table" and node.ifaces or nil
    if type(ifaces) ~= "table" then return 0 end
    local seen, n = {}, 0
    for _, iface in ipairs(ifaces) do
        local ch = type(iface) == "table" and iface.channel or nil
        if type(ch) == "number" and not seen[ch] then
            seen[ch] = true
            n = n + 1
        end
    end
    return n
end

function Router:uptime_seconds(now)
    local base = self.started_at
    if type(base) ~= "number" then return 0 end
    local t = math.floor((now or self:now()) - base)
    if t ~= t or t < 0 then t = 0 end
    return t
end

function Router:leases()
    local out = {}
    local node = self.node
    local srv = type(node) == "table" and node.dhcp or nil
    local by_ip = type(srv) == "table" and srv.by_ip or nil
    if type(by_ip) ~= "table" then return out end
    local now = self:now()
    local rpv = self.rpv or {}
    local rows = {}
    for key, lease in pairs(by_ip) do
        if type(lease) == "table" then
            local sortkey
            local ip_text
            if type(key) == "number" then
                sortkey = key
                ip_text = int2ip_value(rpv, key)
            else
                ip_text = tostring(key)
                sortkey = ip2int_value(rpv, ip_text) or 0
            end
            local mac
            if lease.client ~= nil then
                mac = tostring(lease.client)
            elseif lease.mac ~= nil then
                mac = tostring(lease.mac)
            else
                mac = "?"
            end
            local expires = nil
            if type(lease.expires) == "number" then expires = lease.expires - now end
            rows[#rows + 1] = {
                sortkey = sortkey,
                lease = {
                    ip = ip_text,
                    mac = mac,
                    expires = expires,
                    state = lease.state or "?",
                },
            }
        end
    end
    table.sort(rows, function(a, b) return a.sortkey < b.sortkey end)
    for i = 1, #rows do out[i] = rows[i].lease end
    return out
end

function Router:pages_for(count)
    local rows = math.max(1, self.lease_rows)
    local pages = math.ceil(count / rows)
    if pages < 1 then pages = 1 end
    return pages
end

function Router:refresh()
    local now = self:now()
    local leases = self:leases()
    self.lease_list = leases
    local pages = self:pages_for(#leases)
    self.pages = pages
    if self.lease_page < 1 then self.lease_page = 1 end
    if self.lease_page > pages then self.lease_page = pages end
    self:clamp_scroll()
    local uptime = self:uptime_seconds(now)
    local status = {
        lan_ip = self.opts.lan_ip,
        lan_prefix = self.opts.lan_prefix,
        wan_up = self:wan_up(),
        dhcp_bound = self:bound_count(),
        channels = self:channel_count(),
        uptime = uptime,
        uptime_text = hms(uptime),
        page = self.lease_page,
        pages = pages,
        leases = #leases,
        logs = #self.logs,
    }
    self.status = status
    return status
end

function Router:status_line()
    local status = self.status or self:refresh()
    return fit(header_line(status), Router.COLS)
end

-- ===== terminal ============================================================

function Router:term_size()
    local term = self.opts.term
    if type(term) ~= "table" or type(term.getSize) ~= "function" then return nil end
    local ok, cols, rows = pcall(term.getSize)
    if not ok then return nil end
    if type(cols) ~= "number" or type(rows) ~= "number" then return nil end
    return cols, rows
end

function Router:render()
    local status = self:refresh()
    local cols, rows = self:term_size()
    if cols and (cols < Router.MIN_COLS or rows < Router.MIN_ROWS) then
        return { Router.TOO_SMALL }
    end
    local lines = {}
    lines[#lines + 1] = fit(header_line(status), Router.COLS)
    lines[#lines + 1] = string.rep("-", Router.COLS)
    -- the log window is log_lines rows tall (the sum of every block gives
    -- 11 + log_lines lines: 19 at the default log_lines=8) and ends at
    -- #logs - scroll; idx counts back from that end
    local endidx = #self.logs - self.scroll
    for row = 1, self.log_lines do
        local idx = endidx - self.log_lines + row
        local text = nil
        if idx >= 1 then text = self.logs[idx] end
        lines[#lines + 1] = fit(text and one_line(text) or "", Router.COLS)
    end
    lines[#lines + 1] = string.rep("-", Router.COLS)
    lines[#lines + 1] = fit(string.format("%-17s%-9s%s", "IP", "MAC", "EXPIRES"), Router.COLS)
    local leases = self.lease_list or {}
    if #leases == 0 then
        lines[#lines + 1] = fit("(no leases)", Router.COLS)
        for _ = 2, Router.LEASE_ROWS do lines[#lines + 1] = fit("", Router.COLS) end
    else
        local per_page = math.max(1, self.lease_rows)
        for row = 1, Router.LEASE_ROWS do
            local lease = nil
            if row <= per_page then
                lease = leases[(self.lease_page - 1) * per_page + row]
            end
            if lease then
                lines[#lines + 1] = fit(string.format("%-17s%-9s%s", lease.ip, lease.mac,
                    expiry_text(lease.expires)), Router.COLS)
            else
                lines[#lines + 1] = fit("", Router.COLS)
            end
        end
    end
    lines[#lines + 1] = fit(string.format("PAGE %d/%d", self.lease_page, self.pages or 1),
        Router.COLS)
    lines[#lines + 1] = fit(Router.KEYS_HELP, Router.COLS)
    return lines
end

function Router:draw()
    local term = self.opts.term
    if type(term) ~= "table" then return false end
    local okr, lines = pcall(self.render, self)
    if not okr or type(lines) ~= "table" then return false end
    local ok = pcall(function()
        if type(term.clear) == "function" then term.clear() end
        for i = 1, #lines do
            local line = lines[i]
            if type(term.setCursorPos) == "function" then
                term.setCursorPos(1, i)
                if type(term.write) == "function" then term.write(line) end
            elseif type(term.write) == "function" then
                term.write(line .. "\n")
            end
        end
    end)
    return ok and true or false
end

function Router:tick()
    self:draw()
    return true
end

-- ===== key handling ========================================================

function Router:on_key(key)
    if key == "q" then
        self.running = false
        return "quit"
    elseif key == "r" then
        self:refresh()
        return "refresh"
    elseif key == "l" then
        self.logs = {}
        self.scroll = 0
        return "clear_log"
    elseif key == "j" or key == "down" then
        self.scroll = math.max(0, self.scroll - 1)
        return "scroll"
    elseif key == "k" or key == "up" then
        local max_scroll = self:clamp_scroll()
        self.scroll = math.min(max_scroll, self.scroll + 1)
        return "scroll"
    elseif key == "J" then
        local pages = self:pages_for(#self:leases())
        self.lease_page = math.min(pages, self.lease_page + 1)
        return "page"
    elseif key == "K" then
        self.lease_page = math.max(1, self.lease_page - 1)
        return "page"
    end
    return nil
end

function Router:keys_from_event(ev, a)
    if ev == "char" then return self:on_key(a) end
    if ev == "key" then
        if a == 200 or a == "up" then return self:on_key("up") end
        if a == 208 or a == "down" then return self:on_key("down") end
    end
    return nil
end

Router.__index = Router

return Router
