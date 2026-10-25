--[[- tests/t_router.lua - apps/router.lua: lifecycle, the adaptive TUI, the
traffic statistics, key handling, the lease snapshot and the log ring, plus the
node2/startup.lua app loader (offline: fake node, fake term and an injected clock;
the real route_* and dhcp_server_start run against the fake node).]]
local T, M = ...

local R = M.router
T.ok(R ~= nil, "router module loaded")
if not R then return end

-- ===== fixtures =============================================================
local BASE_COLS, BASE_ROWS = 51, 19
-- adaptive 51x19 layout at the default log_lines=8 / lease_rows=5: the 11 data
-- rows split 8:5, so 7 log rows and a 4 row lease page
local LOG_ROWS, LEASE_ROWS = 7, 4
local ROW_RULE_TOP = 2
local ROW_LOG_FIRST = 3
local ROW_RULE_BOTTOM = 10
local ROW_RX, ROW_TX = 11, 12
local ROW_LEASE_HEAD = 13
local ROW_LEASE_FIRST = 14
local ROW_PAGE = 18
local ROW_HELP = 19
local DASHES = string.rep("-", BASE_COLS)
local SPACES = string.rep(" ", BASE_COLS)
local HELP = "q quit  r refresh  l clear  j/k log  J/K page"
-- 51 columns: the wide shape does not fit, the third shape does
local STATUS = "LAN 192.168.1.1 up DHCP 1 FWD 0 NAT 0 UP 00:00:00"
local orig_print = _G.print

local NOW = 1000
local function clock() return NOW end

local function make_node()
    local lan = { side = "back", name = "LAN", channel = 1001, ip = M.ip2int("192.168.1.1"),
                  prefix = 24, net = M.masked(M.ip2int("192.168.1.1"), 24),
                  cidr = "192.168.1.1/24", is_wan = false }
    local wan = { side = "top", name = "WAN", channel = 2000, ip = M.ip2int("10.0.0.2"),
                  prefix = 24, net = M.masked(M.ip2int("10.0.0.2"), 24),
                  cidr = "10.0.0.2/24", is_wan = true }
    local node = { id = 21, mac = 21, routes = M.route_new(), cfg = {}, stats = {},
                   tasks = {}, ifaces = { lan, wan }, dhcp = nil, udp = { ports = {} },
                   logfile = { writeLine = function() end, flush = function() end } }
    function node:setup() self.setup_calls = (self.setup_calls or 0) + 1 end
    function node:log() end
    function node:add_task(name, fn) self.tasks[#self.tasks + 1] = { name = name, fn = fn } end
    function node:after() return 0 end
    function node:resolve() return nil end
    function node:tick() end
    function node:run() end
    function node:bind(port, cb)
        self.bind_calls = (self.bind_calls or 0) + 1
        self.bound = { port = port, cb = cb, entries_at_bind = #self.routes.entries }
        return { sendto = function() end, close = function() end }
    end
    return node
end

local function make_term(cols, rows)
    local term = { cols = cols or BASE_COLS, rows = rows or BASE_ROWS, out = {}, clears = 0,
                   x = 1, y = 1 }
    -- the fake behaves like a real CraftOS terminal (plain functions, no self) and also
    -- tolerates `term:method(...)` so the fixture never dictates the call style
    function term.getSize() return term.cols, term.rows end
    function term.clear() term.clears = term.clears + 1 end
    function term.setCursorPos(a, b, c)
        if a == term then term.x, term.y = b, c else term.x, term.y = a, b end
    end
    function term.write(a, b)
        local text = a
        if a == term then text = b end
        term.out[#term.out + 1] = { x = term.x, y = term.y, text = text }
    end
    function term.setTextColor() end
    function term.setTextBackgroundColor() end
    return term
end

-- every fixture starts with the print hijack off (only the print group turns it on)
local function fixture(opts)
    local node, term = make_node(), make_term()
    local o = { node = node, term = term, clock = clock, print_hijack = false }
    if opts then
        for k, v in pairs(opts) do o[k] = v end
    end
    return R.new(o), node, term
end

local function trim(s) return (tostring(s):gsub("%s+$", "")) end

-- lease row layout: %-17s ip, %-9s mac, then the expiry text
local function cells(line)
    return trim(line:sub(1, 17)), trim(line:sub(18, 26)), trim(line:sub(27))
end
local function ip_of(line) local ip = cells(line) return ip end
local function mac_of(line) local _, mac = cells(line) return mac end
local function exp_of(line) local _, _, exp = cells(line) return exp end

local function lease_set(specs)
    local by_ip, by_client = {}, {}
    for _, spec in ipairs(specs) do
        local ip = M.ip2int(spec.ip)
        by_ip[ip] = { client = spec.client, name = spec.name, state = spec.state,
                      expires = spec.expires }
        if spec.client then by_client[spec.client] = ip end
    end
    return { by_ip = by_ip, by_client = by_client }
end

local function one_lease(expires, state)
    local ip = M.ip2int("192.168.1.100")
    return { by_ip = { [ip] = { client = 5, state = state, expires = expires } },
             by_client = {} }
end

local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- a crash inside one group must not stop the rest of the file
local function group(name, fn)
    NOW = 1000
    local ok, err = pcall(fn)
    if not ok then T.ok(false, name .. " raised: " .. tostring(err)) end
end

local function sized(lines, cols)
    if #lines == 0 then return false end
    for i = 1, #lines do
        if #lines[i] ~= cols then return false end
    end
    return true
end

-- ===== 1 lifecycle ==========================================================
group("lifecycle", function()
    local r, node = fixture()
    T.ok(type(r) == "table", "new returns a router table")
    T.ok(not r.running, "a fresh router is not running")
    T.eq(r.log_lines, 8, "default log ring size")
    T.eq(r.lease_rows, 5, "default lease rows")
    T.eq(r.scroll, 0, "the log window starts unscrolled")
    T.eq(r.lease_page, 1, "the lease table starts on page 1")
    T.ok(type(r.blocked) == "table", "the blocked api list exists")
    T.eq(#r.rx_rates, 0, "the sparkline history starts empty")
    T.eq(r:start(), true, "start returns true")
    T.eq(node.setup_calls, 1, "node:setup ran once")
    T.ok(type(node.nat) == "table", "start brings NAT up when setup did not initialise it")
    T.eq(node.nat.out, node.ifaces[2], "NAT exits through the WAN iface, not the LAN")
    T.eq(node.nat.ext_ip, node.ifaces[2].ip, "the NAT external address is the WAN address")
    T.eq(r.running, true, "running after start")
    T.eq(r.started, true, "the started flag is set")
    T.eq(#r.rx_rates, 1, "start records a traffic baseline sample")
    T.eq(r:start(), true, "a second start still returns true")
    T.eq(node.setup_calls, 1, "a second start does not rerun setup")
    local task_name
    for _, task in ipairs(node.tasks) do
        if task.name == "router-tui" then task_name = task.name end
    end
    T.eq(task_name, "router-tui", "the router-tui task is registered")
    T.eq(r:stop(), true, "stop returns true")
    T.eq(r.running, false, "not running after stop")
    T.eq(r:stop(), true, "a second stop still returns true")
    T.eq(node.setup_calls, 1, "stop does not rerun setup")
end)

-- ===== 2 static routes, cfg and the dhcp bind ==============================
group("routes", function()
    local r, node = fixture()
    local before = #node.routes.entries
    T.eq(r:start(), true, "start installs the routes")
    local list = M.route_list(node.routes)
    local function find_route(dest, via)
        for _, entry in ipairs(list) do
            if entry.dest == dest and entry.via == via then return entry end
        end
        return nil
    end
    T.ok(find_route("255.255.255.255/32", "LAN") ~= nil, "broadcast route via LAN")
    T.ok(find_route("10.254.0.0/16", "LAN") ~= nil, "dhcp-temp route via LAN")
    local entries = 0
    for _, entry in ipairs(list) do
        if entry.dest == "255.255.255.255/32" then entries = entries + 1 end
    end
    T.eq(entries, 1, "the broadcast route exists once")
    T.ok(node.bound ~= nil, "the dhcp server bound a port")
    T.eq(node.bound and node.bound.port, 6700, "the dhcp server bound port 6700")
    T.ok(node.bound and node.bound.entries_at_bind >= before + 2,
         "both static routes existed before the dhcp bind")
    T.eq(#r.blocked, 0, "no api is blocked with the real rpv namespace")
    T.eq(node.cfg.role, "router", "cfg.role is set when unset")
    T.eq(node.cfg.dhcp_pool, "192.168.1.100-192.168.1.150", "dhcp pool serialised from dhcp_range")
    T.eq(node.cfg.dhcp_gw, "192.168.1.1", "dhcp gateway is the lan ip")
    T.eq(tonumber(node.cfg.dhcp_lease), 600, "dhcp lease time configured")
    T.eq(node.cfg.dhcp_port and tonumber(node.cfg.dhcp_port), 6700, "dhcp port configured")
    T.eq(node.cfg.nat, "1", "nat is enabled by default")
    T.eq(node.cfg.nat_out, "WAN", "nat exits through the wan iface")
    T.eq(node.cfg.dhcp_probe, "0", "nat disables the dhcp probe")
    local installed = #node.routes.entries
    T.eq(r:start(), true, "a second start is still ok")
    T.eq(#node.routes.entries, installed, "a second start does not duplicate the routes")
    T.eq(node.setup_calls, 1, "a second start does not rerun setup")
    T.eq(node.bind_calls, 1, "the dhcp server is not restarted")
    r:stop()
    local r2, node2 = fixture({ nat = false })
    T.eq(r2:start(), true, "start with nat off")
    T.ok(node2.cfg.nat ~= "1", "nat stays off when the option is false")
    T.eq(node2.cfg.nat_out, "WAN", "the nat exit iface is named even with nat off")
    r2:stop()
    local r3, node3 = fixture()
    node3.cfg.role = "custom"
    T.eq(r3:start(), true, "start with a preset role")
    T.eq(node3.cfg.role, "custom", "an existing role is kept")
    r3:stop()
end)

-- ===== 3 print hijack ======================================================
group("print-hijack", function()
    local before = _G.print
    local r = fixture({ print_hijack = true })
    local start_ok = r:start()
    local hooked = _G.print
    local is_hooked = (hooked ~= before)
    local ring_text
    if is_hooked then
        hooked("hello router")
        ring_text = r.logs[#r.logs]
    end
    local restored_ok = r:restore_print()
    local after = _G.print
    T.eq(start_ok, true, "start with the print hijack")
    T.ok(is_hooked, "start replaces the global print")
    T.eq(ring_text, "hello router", "the hijacked print appends one ring line")
    T.eq(restored_ok, true, "restore_print returns true")
    T.ok(after == before, "restore_print puts the original print back")
    T.eq(r:restore_print(), true, "restore_print is safe twice")
    T.ok(_G.print == before, "print stays restored after the second call")
    local r2 = fixture({ print_hijack = true })
    local r2_start = r2:start()
    local r2_hooked = (_G.print ~= before)
    local r2_stop = r2:stop()
    local r2_back = (_G.print == before)
    T.eq(r2_start, true, "the second router starts")
    T.ok(r2_hooked, "the second router hijacks print too")
    T.eq(r2_stop, true, "stop returns true")
    T.ok(r2_back, "stop restores the original print")
    local r3 = fixture({ print_hijack = false })
    local plain = _G.print
    r3:start()
    local kept = (_G.print == plain)
    r3:stop()
    T.ok(kept, "print_hijack=false leaves the global print alone")
end)

-- ===== 4 status line ======================================================
group("status", function()
    local r, node, term = fixture()
    T.eq(r:start(), true, "start for the status line")
    node.dhcp = lease_set({ { ip = "192.168.1.100", client = 12, state = "bound",
                              expires = NOW + 600 } })
    r:refresh()
    local status = trim(r:status_line())
    T.eq(status, STATUS, "the status line carries LAN/DHCP/FWD/NAT/UP")
    T.eq(#r:status_line(), BASE_COLS, "the status line is padded to the terminal width")
    T.eq(trim(r:render()[1]), status, "row 1 carries the status line")
    local ip = M.ip2int("192.168.1.101")
    node.dhcp.by_ip[ip] = { client = 13, state = "offered", expires = NOW + 30 }
    r:refresh()
    T.eq(trim(r:status_line()), STATUS, "an offered lease is not counted as bound")
    node.dhcp.by_ip[ip] = { client = 13, state = "bound", expires = NOW + 30 }
    r:refresh()
    T.ok(trim(r:status_line()):find("DHCP 2", 1, true) ~= nil, "a second bound lease is counted")
    -- forwarded packets and NAT flows are read from the node
    node.stats.fwd = 12
    node.nat = { flows = { a = {}, b = {}, c = {} } }
    r:refresh()
    local line = trim(r:status_line())
    T.ok(line:find("FWD 12", 1, true) ~= nil, "the status line shows the forwarded packet count")
    T.ok(line:find("NAT 3", 1, true) ~= nil, "the status line shows the live NAT flow count")
    T.eq(r.status.fwd, 12, "status.fwd mirrors node.stats.fwd")
    T.eq(r.status.nat_flows, 3, "status.nat_flows counts node.nat.flows")
    T.eq(#r:status_line(), BASE_COLS, "the wider stats stay inside the 51 column line")
    -- a wide terminal gets the full shape with the WAN and channel labels
    term.cols = 70
    r:refresh()
    local wide = trim(r:status_line())
    T.ok(wide:find("WAN up", 1, true) ~= nil, "a wide terminal shows the WAN label")
    T.ok(wide:find("CH 2", 1, true) ~= nil, "a wide terminal shows the channel count")
    T.eq(#r:status_line(), 70, "the wide status line fills the terminal width")
    term.cols = BASE_COLS
    r:refresh()
end)

-- ===== 5 uptime uses the injected clock ===================================
group("uptime", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the uptime check")
    T.eq(r:now(), 1000, "now() reads the injected clock")
    NOW = 1065
    r:refresh()
    T.ok(trim(r:status_line()):find("UP 00:01:05", 1, true) ~= nil,
         "uptime follows the injected clock")
    local ok = pcall(function() r:tick() end)
    T.ok(ok, "tick does not error")
    T.ok(trim(r:render()[1]):find("UP 00:01:05", 1, true) ~= nil,
         "the rendered status shows the uptime")
end)

-- ===== 6 log ring =========================================================
group("log-ring", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the log ring")
    T.eq(r:on_key("l"), "clear_log", "l clears the log")
    T.eq(#r.logs, 0, "the ring is empty after the clear")
    for i = 1, 12 do r:log("line " .. i) end
    T.eq(#r.logs, 8, "the ring keeps only log_lines entries")
    T.eq(r.logs[1], "line 5", "the oldest kept entry is line 5")
    T.eq(r.logs[8], "line 12", "the newest entry is line 12")
    -- the adaptive window is 7 rows on a 51x19 screen, so the first kept entry
    -- (line 5) is one row above the window and line 6 is the first visible one
    T.eq(r:render()[ROW_LOG_FIRST], "line 6" .. string.rep(" ", BASE_COLS - 6),
         "the first log row shows the oldest visible entry")
    T.eq(r:render()[ROW_LOG_FIRST + LOG_ROWS - 1], "line 12" .. string.rep(" ", BASE_COLS - 7),
         "the last log row shows the newest entry")
    T.eq(r:on_key("l"), "clear_log", "l clears again")
    T.eq(#r.logs, 0, "the ring is empty again")
    T.eq(r:render()[ROW_LOG_FIRST], SPACES, "the log window is blank after the clear")
end)

-- ===== 7 log scroll =======================================================
group("log-scroll", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the log scroll")
    T.eq(r:on_key("l"), "clear_log", "clear before filling")
    for i = 1, 12 do r:log("line " .. i) end
    local function row(i) return trim(r:render()[i]) end
    local header = trim(string.format("%-17s%-9s%s", "IP", "MAC", "EXPIRES"))
    T.eq(r.scroll, 0, "scroll starts at zero")
    T.eq(r:log_window(), LOG_ROWS, "the log window adapts to the 51x19 terminal")
    T.eq(row(ROW_LOG_FIRST), "line 6", "the window shows the newest seven entries")
    T.eq(row(ROW_LOG_FIRST + LOG_ROWS - 1), "line 12", "the newest entry is the last log row")
    T.eq(#r:render(), BASE_ROWS, "the screen is 19 rows tall")
    T.eq(r:render()[ROW_RULE_BOTTOM], DASHES, "the divider follows the log rows")
    T.eq(row(ROW_LEASE_HEAD), header, "the lease header follows the divider")
    T.eq(row(ROW_PAGE), "PAGE 1/1", "the page row is the second to last")
    T.eq(row(ROW_HELP), HELP, "the help row is the last line")
    T.eq(r:on_key("k"), "scroll", "k scrolls the log")
    T.eq(r.scroll, 1, "k moves the window back one line")
    T.eq(row(ROW_LOG_FIRST), "line 5", "scroll 1 shows line 5 first")
    T.eq(row(ROW_LOG_FIRST + LOG_ROWS - 1), "line 11", "scroll 1 ends at line 11")
    T.eq(r:on_key("k"), "scroll", "k at the oldest end")
    T.eq(r.scroll, 1, "scroll clamps at the oldest entry")
    T.eq(row(ROW_LOG_FIRST), "line 5", "the clamped window does not move")
    T.eq(r:on_key("j"), "scroll", "j scrolls forward")
    T.eq(r.scroll, 0, "j moves one line forward")
    T.eq(row(ROW_LOG_FIRST), "line 6", "scroll 0 shows line 6 again")
    T.eq(r:on_key("j"), "scroll", "j at the newest end")
    T.eq(r.scroll, 0, "j clamps at zero")
    T.eq(row(ROW_RULE_BOTTOM), string.rep("-", BASE_COLS),
         "the divider stays just below the log window")
    -- a bigger terminal grows the window (the ring keeps enough history for it)
    local r2, _, term = fixture()
    r2:start()
    term.cols, term.rows = 60, 24
    r2:refresh()
    T.ok(r2:log_window() > LOG_ROWS, "a taller terminal grows the log window")
    T.eq(#r2:render(), 24, "the taller terminal fills every row")
end)

-- ===== 8 lease pages ======================================================
group("lease-pages", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the lease pages")
    local specs = {}
    for i = 0, 6 do
        specs[#specs + 1] = { ip = "192.168.1." .. (100 + i), client = i + 1,
                              state = "bound", expires = NOW + 600 }
    end
    node.dhcp = lease_set(specs)
    r:refresh()
    T.eq(r.lease_page, 1, "the lease table opens on page 1")
    local lines = r:render()
    T.eq(ip_of(lines[ROW_LEASE_FIRST]), "192.168.1.100", "page 1 starts at the first lease")
    T.eq(mac_of(lines[ROW_LEASE_FIRST]), "1", "the mac column is the client id")
    T.eq(trim(lines[ROW_PAGE]), "PAGE 1/2", "two pages for seven leases")
    T.eq(ip_of(lines[ROW_LEASE_FIRST + LEASE_ROWS - 1]), "192.168.1.103",
         "page 1 ends at the fourth lease")
    T.eq(r:on_key("J"), "page", "J pages forward")
    T.eq(r.lease_page, 2, "page 2")
    lines = r:render()
    T.eq(ip_of(lines[ROW_LEASE_FIRST]), "192.168.1.104", "page 2 starts at the fifth lease")
    T.eq(ip_of(lines[ROW_LEASE_FIRST + 2]), "192.168.1.106", "page 2 holds the last lease")
    T.eq(lines[ROW_LEASE_FIRST + 3], SPACES, "unused lease rows are blank")
    T.eq(trim(lines[ROW_PAGE]), "PAGE 2/2", "the page indicator follows")
    T.eq(r:on_key("J"), "page", "J at the last page")
    T.eq(r.lease_page, 2, "paging clamps at the last page")
    T.eq(r:on_key("K"), "page", "K pages back")
    T.eq(r.lease_page, 1, "back on page 1")
    T.eq(r:on_key("K"), "page", "K at the first page")
    T.eq(r.lease_page, 1, "paging clamps at page 1")
    node.dhcp = lease_set({})
    lines = r:render()
    T.eq(trim(lines[ROW_LEASE_FIRST]), "(no leases)", "an empty lease table shows a placeholder")
    T.eq(#lines[ROW_LEASE_FIRST], BASE_COLS, "the placeholder row is padded")
    T.eq(trim(lines[ROW_PAGE]), "PAGE 1/1", "an empty lease table has a single page")
    T.eq(#lines[ROW_PAGE], BASE_COLS, "the page row is padded")
    T.eq(r.lease_page, 1, "the page resets when the table shrinks")
end)

-- ===== 9 expiry text ======================================================
group("expiry", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the expiry text")
    local function expiry_for(expires)
        node.dhcp = one_lease(expires)
        r:refresh()
        return exp_of(r:render()[ROW_LEASE_FIRST])
    end
    T.eq(expiry_for(NOW + 59), "59s", "expiry under a minute shows seconds")
    T.eq(expiry_for(NOW + 600), "10m00s", "expiry under an hour shows minutes and seconds")
    T.eq(expiry_for(NOW + 3599), "59m59s", "just under an hour stays in minutes")
    T.eq(expiry_for(NOW + 3600), "1h00m", "an hour or more shows hours and minutes")
    T.eq(expiry_for(NOW), "expired", "a lease that ends now is expired")
    T.eq(expiry_for(NOW - 5), "expired", "a lease in the past is expired")
    T.eq(expiry_for(nil), "-", "a lease without expires shows a dash")
end)

-- ===== 10 lease snapshot ==================================================
group("leases", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the lease snapshot")
    local dhcp = lease_set({
        { ip = "192.168.1.106", client = 9, state = "bound", expires = NOW + 300 },
        { ip = "192.168.1.100", client = 3, state = "bound", expires = NOW + 100 },
        { ip = "192.168.1.103", client = 7, state = "offered", expires = NOW + 200 },
    })
    node.dhcp = dhcp
    local before = count_keys(dhcp.by_ip)
    local leases = r:leases()
    T.eq(#leases, 3, "leases() returns one entry per lease")
    T.eq(leases[1].ip, "192.168.1.100", "leases are sorted by address (first)")
    T.eq(leases[2].ip, "192.168.1.103", "leases are sorted by address (second)")
    T.eq(leases[3].ip, "192.168.1.106", "leases are sorted by address (third)")
    T.eq(leases[1].mac, "3", "mac is the client id as a string")
    T.eq(leases[1].state, "bound", "the bound state is copied")
    T.eq(leases[2].state, "offered", "the offered state is copied")
    T.eq(leases[1].expires, 100, "expires is the remaining time (first)")
    T.eq(leases[2].expires, 200, "expires is the remaining time (second)")
    T.eq(leases[3].expires, 300, "expires is the remaining time (third)")
    r:refresh()
    T.eq(count_keys(dhcp.by_ip), before, "refresh does not mutate node.dhcp.by_ip")
    T.eq(dhcp.by_ip[M.ip2int("192.168.1.100")].state, "bound", "the lease table is untouched")
    node.dhcp = one_lease(NOW - 10)
    local expired = r:leases()
    T.eq(expired[1].expires, -10, "an expired lease keeps a negative remaining time")
    local no_state = one_lease(NOW + 10)
    no_state.by_ip[M.ip2int("192.168.1.100")].state = nil
    node.dhcp = no_state
    T.eq(r:leases()[1].state, "?", "a lease without a state shows a question mark")
end)

-- ===== 11 keys ============================================================
group("keys", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the key handling")
    T.eq(r:on_key("r"), "refresh", "r refreshes")
    T.eq(r:on_key("l"), "clear_log", "l clears the log")
    T.eq(r:on_key("j"), "scroll", "j scrolls")
    T.eq(r:on_key("k"), "scroll", "k scrolls")
    T.eq(r:on_key("up"), "scroll", "the up key name scrolls")
    T.eq(r:on_key("down"), "scroll", "the down key name scrolls")
    T.eq(r:on_key("J"), "page", "J pages")
    T.eq(r:on_key("K"), "page", "K pages")
    T.eq(r:on_key("x"), nil, "unknown keys are ignored")
    T.eq(r:keys_from_event("key", 200), "scroll", "key code 200 is up")
    T.eq(r:keys_from_event("key", 208), "scroll", "key code 208 is down")
    T.eq(r:keys_from_event("char", "r"), "refresh", "a char event feeds the key handler")
    T.eq(r:keys_from_event("key", 65), nil, "unknown key codes are ignored")
    local r2 = fixture()
    T.eq(r2:start(), true, "start for the quit keys")
    T.eq(r2:keys_from_event("char", "q"), "quit", "a q char event quits")
    T.eq(r2.running, false, "the char event stops the router")
    T.eq(r:on_key("q"), "quit", "q quits")
    T.eq(r.running, false, "q clears the running flag")
end)

-- ===== 12 adaptive layout =================================================
group("adaptive", function()
    local r, node, term = fixture()
    T.eq(r:start(), true, "start at 51x19")
    T.eq(#r:render(), BASE_ROWS, "a 51x19 terminal renders 19 rows")
    T.ok(sized(r:render(), BASE_COLS), "every 51x19 row is 51 columns")
    -- every supported size fills its rows and never folds a line
    for _, size in ipairs({ { 60, 24 }, { 80, 30 }, { 40, 10 }, { 51, 18 }, { 100, 12 } }) do
        local cols, rows = size[1], size[2]
        term.cols, term.rows = cols, rows
        local lines = r:render()
        T.eq(#lines, rows, "a " .. cols .. "x" .. rows .. " terminal renders " .. rows .. " rows")
        T.ok(sized(lines, cols), "every " .. cols .. "x" .. rows .. " row is " .. cols .. " columns")
        T.ok(lines[1]:find("FWD", 1, true) ~= nil,
             "the " .. cols .. "x" .. rows .. " status line still shows FWD")
        T.ok(lines[1]:find("NAT", 1, true) ~= nil,
             "the " .. cols .. "x" .. rows .. " status line still shows NAT")
        local ok = pcall(function() r:tick() end)
        T.ok(ok, "tick on a " .. cols .. "x" .. rows .. " terminal does not error")
    end
    -- below 40x10 the screen degrades to the status line only
    for _, size in ipairs({ { 39, 9 }, { 20, 5 }, { 51, 9 }, { 39, 19 } }) do
        local cols, rows = size[1], size[2]
        term.cols, term.rows = cols, rows
        local lines = r:render()
        T.eq(#lines, 1, "a " .. cols .. "x" .. rows .. " terminal shows the status line only")
        T.eq(#lines[1], cols, "the status-only line is clipped to " .. cols .. " columns")
        local ok = pcall(function() r:tick() end)
        T.ok(ok, "tick on a " .. cols .. "x" .. rows .. " status-only terminal does not error")
    end
    -- and a resize back restores the full layout
    term.cols, term.rows = BASE_COLS, BASE_ROWS
    T.eq(#r:render(), BASE_ROWS, "resizing back restores the 19 row layout")
    T.eq(node.setup_calls, 1, "resizing does not rerun setup")
    -- no terminal at all still uses the reference layout
    local saved = _G.term
    _G.term = nil
    local built, r_nt = pcall(R.new, { node = make_node() })
    _G.term = saved
    local ok, lines = pcall(function() return r_nt:render() end)
    T.ok(built, "a router without a terminal can be built")
    T.ok(ok and #lines == BASE_ROWS, "render without a terminal uses the 51x19 layout")
end)

-- ===== 13 draw ============================================================
group("draw", function()
    local r, node, term = fixture()
    T.eq(r:start(), true, "start draws once")
    term.out = {}
    T.eq(r:draw(), true, "draw returns true")
    local lines = r:render()
    T.eq(#term.out, BASE_ROWS, "draw writes every row")
    local pos_ok, text_ok, bad = true, true, 0
    for i = 1, BASE_ROWS do
        local w = term.out[i]
        if not w or w.x ~= 1 or w.y ~= i then pos_ok = false; bad = i end
    end
    T.ok(pos_ok, "every draw row starts at column 1 (first bad row " .. tostring(bad) .. ")")
    for i = 1, BASE_ROWS do
        local w = term.out[i]
        if not w or w.text ~= lines[i] then text_ok = false; bad = i end
    end
    T.ok(text_ok, "every draw row is the render line (first bad row " .. tostring(bad) .. ")")
    term.cols, term.rows = 39, 9
    term.out = {}
    local clears_before = term.clears
    T.eq(r:draw(), true, "draw on a status-only terminal returns true")
    T.eq(#term.out, 1, "the status-only terminal draws a single line")
    local w = term.out[1]
    T.ok(w ~= nil and w.x == 1 and w.y == 1, "the status line is drawn at 1,1")
    T.eq(w and w.text, r:render()[1], "the status-only text matches render")
    T.ok(term.clears > clears_before, "the terminal is cleared before the redraw")
    term.cols, term.rows = BASE_COLS, BASE_ROWS
    local saved = _G.term
    _G.term = nil
    local built, r_nt = pcall(R.new, { node = make_node() })
    local drawn, draw_ok
    if built then drawn, draw_ok = pcall(function() return r_nt:draw() end) end
    _G.term = saved
    T.ok(built, "a router without a terminal can be built")
    T.ok(drawn, "draw without a terminal does not error")
    T.eq(draw_ok, false, "draw without a terminal returns false")
end)

-- ===== 14 traffic statistics and the sparkline ============================
group("traffic", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the traffic statistics")
    T.eq(r:forwarded(), 0, "no forwarded packets yet")
    T.eq(r:nat_flows(), 0, "no NAT flows without a nat table")
    node.stats.fwd = 42
    T.eq(r:forwarded(), 42, "forwarded() reads node.stats.fwd")
    node.nat = { flows = { x = {}, y = {} } }
    T.eq(r:nat_flows(), 2, "nat_flows() counts node.nat.flows")
    node.nat = { flows = {} }
    T.eq(r:nat_flows(), 0, "an empty NAT table counts zero flows")
    -- rate sampling: packets per second over the injected clock
    node.stats.frames_rx, node.stats.frames_tx = 20, 10
    NOW = NOW + 2
    local rx, tx = r:sample_traffic()
    T.near(rx, 10, 0.0001, "the RX rate is delta packets per second")
    T.near(tx, 5, 0.0001, "the TX rate is delta packets per second")
    T.eq(#r.rx_rates, 2, "a second sample appends to the RX history")
    -- a counter reset must not produce a negative rate
    node.stats.frames_rx = 5
    NOW = NOW + 1
    T.eq(r:sample_traffic(), 0, "a decreasing frame counter clamps the RX rate to zero")
    -- a zero time delta contributes a zero rate instead of a division by zero
    T.eq(r:sample_traffic(NOW), 0, "a zero time delta yields a zero rate")
    -- the history is bounded
    for i = 1, R.SPARK_SAMPLES + 10 do r:sample_traffic(NOW + i) end
    T.eq(#r.rx_rates, R.SPARK_SAMPLES, "the RX history keeps the last SPARK_SAMPLES")
    T.eq(#r.tx_rates, R.SPARK_SAMPLES, "the TX history keeps the last SPARK_SAMPLES")
    -- the chart: two ASCII rows, scaled against the shared peak
    local ramp = R.SPARK_RAMP
    r.rx_rates = { 1, 2, 3, 4 }
    r.tx_rates = { 4, 3, 2, 1 }
    local chart = r:chart_lines(BASE_COLS)
    T.eq(#chart, 2, "the chart has an RX row and a TX row")
    T.eq(chart[1]:sub(1, 3), "RX ", "the first chart row is labelled RX")
    T.eq(chart[2]:sub(1, 3), "TX ", "the second chart row is labelled TX")
    T.eq(#chart[1], 3 + 4, "the chart shows one bar per sample")
    local ascii_ok = true
    for i = 4, #chart[1] do
        if not ramp:find(chart[1]:sub(i, i), 1, true) then ascii_ok = false end
    end
    for i = 4, #chart[2] do
        if not ramp:find(chart[2]:sub(i, i), 1, true) then ascii_ok = false end
    end
    T.ok(ascii_ok, "every bar comes from the ASCII ramp")
    T.ok(chart[1]:find("@", 1, true) ~= nil, "the busiest sample is the tallest bar")
    T.ok(chart[1]:sub(4, 4) ~= "@", "a quieter sample is a shorter bar")
    -- empty and tiny widths must not throw
    r.rx_rates, r.tx_rates = {}, {}
    local empty = r:chart_lines(BASE_COLS)
    T.eq(empty[1], "RX ", "an empty RX history is just the label")
    T.eq(empty[2], "TX ", "an empty TX history is just the label")
    for _, width in ipairs({ 1, 2, 4, 40, 51, 200 }) do
        local ok = pcall(function() return r:chart_lines(width) end)
        T.ok(ok, "chart_lines(" .. width .. ") does not error")
    end
    -- the rendered screen carries the two chart rows below the log window
    r.rx_rates = { 1, 1 }
    r.tx_rates = { 1, 1 }
    local lines = r:render()
    T.eq(lines[ROW_RX]:sub(1, 3), "RX ", "the RX chart row sits below the log divider")
    T.eq(lines[ROW_TX]:sub(1, 3), "TX ", "the TX chart row follows the RX row")
    T.ok(sized(lines, BASE_COLS), "the chart rows are padded to the screen width")
end)

-- ===== 15 the psk never reaches the screen ================================
group("security", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the security check")
    node.cfg.psk = "super-secret-psk"
    r:log("BOOT")
    r:refresh()
    local rendered = table.concat(r:render(), "\n")
    T.ok(rendered:find("super-secret-psk", 1, true) == nil, "the screen never shows the psk")
    T.ok(table.concat(r.logs, "\n"):find("super-secret-psk", 1, true) == nil,
         "the log ring never shows the psk")
    T.eq(node.cfg.psk, "super-secret-psk", "the psk stays in cfg")
end)

-- ===== 16 resilience ======================================================
group("resilience", function()
    T.raises(function() R.new({ rpv = {} }) end, "new without a node and without rpv raises")
    local r, node = fixture()
    T.eq(r:start(), true, "start for the resilience checks")
    node.dhcp = nil
    local ok = pcall(function() r:tick() end)
    T.ok(ok, "tick without a dhcp server does not error")
    T.ok(trim(r:status_line()):find("DHCP 0", 1, true) ~= nil,
         "status reports zero leases without a dhcp server")
    node.stats = nil
    T.eq(r:forwarded(), 0, "forwarded() without node.stats is zero")
    local sampled = pcall(function() r:sample_traffic() end)
    T.ok(sampled, "sample_traffic without node.stats does not error")
    r:refresh()
    T.eq(r.status.fwd, 0, "status without node.stats reports zero forwarded packets")
    node.nat = "garbage"
    T.eq(r:nat_flows(), 0, "a damaged node.nat reports zero NAT flows")
    r:log(nil)
    local first = r.logs[#r.logs]
    r:log(123)
    local second = r.logs[#r.logs]
    local previous = r.logs[#r.logs - 1]
    T.eq(first, "nil", "log(nil) stores tostring(nil)")
    T.eq(second, "123", "log() stringifies numbers")
    T.eq(previous, "nil", "the ring keeps insertion order")
end)

-- ===== 17 the adaptive 51x19 layout ======================================
group("layout", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the layout check")
    T.eq(r:on_key("l"), "clear_log", "clear the log for a blank window")
    local lines = r:render()
    T.eq(#lines, BASE_ROWS, "a normal render is 19 rows tall")
    T.ok(sized(lines, BASE_COLS), "every row is exactly 51 columns wide")
    T.eq(lines[ROW_RULE_TOP], DASHES, "row 2 is the rule under the status line")
    T.eq(lines[ROW_RULE_BOTTOM], DASHES, "row 10 is the rule under the log window")
    local blank = true
    for i = ROW_LOG_FIRST, ROW_RULE_BOTTOM - 1 do
        if lines[i] ~= SPACES then blank = false end
    end
    T.ok(blank, "an empty log window is blanks")
    T.eq(trim(lines[ROW_HELP]), HELP, "row 19 is the key help")
    local header = trim(string.format("%-17s%-9s%s", "IP", "MAC", "EXPIRES"))
    T.eq(trim(lines[ROW_LEASE_HEAD]), header, "row 13 is the lease header")
    T.eq(trim(lines[ROW_PAGE]), "PAGE 1/1", "row 18 is the page indicator")
    T.eq(lines[ROW_RX]:sub(1, 3), "RX ", "row 11 is the RX sparkline")
    T.eq(lines[ROW_TX]:sub(1, 3), "TX ", "row 12 is the TX sparkline")
    T.eq(trim(lines[1]), trim(r:status_line()), "row 1 is the status line")
end)

-- ===== 18 the startup app loader =========================================
group("startup-loader", function()
    local saved_flag = _G.RPV_BOOT_TEST
    local loaded_ok, boot = pcall(function()
        _G.RPV_BOOT_TEST = true
        local chunk = assert(loadfile("node2/startup.lua"), "cannot load node2/startup.lua")
        return chunk()
    end)
    _G.RPV_BOOT_TEST = saved_flag
    T.ok(loaded_ok, "node2/startup.lua loads under the RPV_BOOT_TEST hook")
    T.ok(type(boot) == "table", "the bootstrap returns its module table")
    if type(boot) ~= "table" then return end
    T.ok(type(boot.app_entry) == "function", "the bootstrap exposes app_entry")
    -- the round 1 function form passes straight through
    local legacy = function(M_, node_, args_) return "legacy" end
    T.eq(boot.app_entry(legacy), legacy, "a function app is used as-is")
    local rejected, why = boot.app_entry(7)
    T.eq(rejected, nil, "a non-app return value is rejected")
    T.ok(type(why) == "string", "the rejection carries a reason")
    -- the real router module goes through the startup loader
    local chunk = assert(loadfile("apps/router.lua"), "cannot load apps/router.lua")
    local router_mod = chunk()
    T.eq(type(router_mod), "table", "router.lua is a table module")
    T.eq(type(router_mod.new), "function", "router.lua exposes new")
    local entry = boot.app_entry(router_mod)
    T.eq(type(entry), "function", "app_entry normalises the router table")
    local node, term = make_node(), make_term()
    local saved_term = _G.term
    _G.term = term
    local ok, inst = pcall(entry, M, node, "")
    local stopped = false
    if ok and type(inst) == "table" and type(inst.stop) == "function" then
        stopped = pcall(inst.stop, inst)
    end
    _G.term = saved_term
    T.ok(ok, "the router starts through the startup loader without error")
    T.eq(type(inst), "table", "the loader returns the router instance")
    T.eq(inst and inst.started, true, "the loader started the router")
    T.eq(inst and inst.opts and inst.opts.setup, false,
         "the loader skips node:setup (the bootstrap already ran it)")
    T.ok(type(node.nat) == "table", "the startup path brings NAT up after the bootstrap setup")
    T.eq(inst and inst.status and inst.status.nat_flows, 0,
         "the startup path reports zero NAT flows at boot")
    T.ok(stopped, "the startup-loaded router stops cleanly")
    -- role.txt nat=1 makes the bootstrap create NAT before cfg.nat_out is known
    -- (nat_new then falls back to the LAN iface); the router must rebind it to WAN
    local node2, term2 = make_node(), make_term()
    node2.nat = { out = node2.ifaces[1], ext_ip = node2.ifaces[1].ip, flows = {} }
    local saved_term2 = _G.term
    _G.term = term2
    local ok2, inst2 = pcall(entry, M, node2, "")
    if ok2 and type(inst2) == "table" and type(inst2.stop) == "function" then
        pcall(inst2.stop, inst2)
    end
    _G.term = saved_term2
    T.ok(ok2, "the router starts when the bootstrap already created a NAT table")
    T.eq(node2.nat.out, node2.ifaces[2], "the router rebinds NAT to the WAN iface")
    T.eq(node2.nat.ext_ip, node2.ifaces[2].ip, "the rebound NAT uses the WAN address")
    local rebound = false
    for _, line in ipairs(inst2 and inst2.logs or {}) do
        if tostring(line):find("ROUTER_NAT_REBIND", 1, true) then rebound = true end
    end
    T.ok(rebound, "the rebind is logged")
    T.eq(node.setup_calls, nil, "the loader does not rerun node:setup")
    local has_task = false
    for _, task in ipairs(node.tasks) do
        if task.name == "router-tui" then has_task = true end
    end
    T.ok(has_task, "the startup-loaded router registers the router-tui task")
    -- table apps with a broken start surface a reason
    local failing = { new = function() return { start = function() return false end } end }
    local okf, errf = pcall(boot.app_entry(failing), M, node, "")
    T.ok(not okf, "a table app whose start() returns false raises")
    T.ok(tostring(errf):find("app.start returned false", 1, true) ~= nil,
         "the start failure keeps its reason")
    local empty = { new = function() return {} end }
    local oke, erre = pcall(boot.app_entry(empty), M, node, "")
    T.ok(not oke and tostring(erre):find("neither start", 1, true) ~= nil,
         "a table app with neither start nor run raises")
end)

-- ===== leave the console usable for the rest of the suite =================
local print_ok = (_G.print == orig_print)
_G.print = orig_print
T.ok(print_ok, "no group left the global print hijacked")
