--[[- tests/t_router.lua - apps/router.lua: lifecycle, the fixed 51x19 TUI, key
handling, the lease snapshot and the log ring (offline: fake node, fake term and an
injected clock; the real route_* and dhcp_server_start run against the fake node).]]
local T, M = ...

local R = M.router
T.ok(R ~= nil, "router module loaded")
if not R then return end

-- ===== fixtures =============================================================
local MIN_COLS, MIN_ROWS = 51, 19
local SMALL_MSG = "TERMINAL TOO SMALL (need 51x19)"
local DASHES = string.rep("-", MIN_COLS)
local SPACES = string.rep(" ", MIN_COLS)
local HELP = "q quit  r refresh  l clear  j/k log  J/K page"
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

local function make_term()
    local term = { cols = MIN_COLS, rows = MIN_ROWS, out = {}, clears = 0, x = 1, y = 1 }
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
    T.eq(r:start(), true, "start returns true")
    T.eq(node.setup_calls, 1, "node:setup ran once")
    T.eq(r.running, true, "running after start")
    T.eq(r.started, true, "the started flag is set")
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
    local r, node = fixture()
    T.eq(r:start(), true, "start for the status line")
    node.dhcp = lease_set({ { ip = "192.168.1.100", client = 12, state = "bound",
                              expires = NOW + 600 } })
    r:refresh()
    local status = trim(r:status_line())
    T.eq(status, "LAN 192.168.1.1  WAN up  DHCP 1  CH 2  UP 00:00:00",
         "the status line matches the fixed format")
    T.eq(#r:status_line(), MIN_COLS, "the status line is padded to 51 columns")
    T.eq(trim(r:render()[1]), status, "row 1 carries the status line")
    local ip = M.ip2int("192.168.1.101")
    node.dhcp.by_ip[ip] = { client = 13, state = "offered", expires = NOW + 30 }
    r:refresh()
    T.eq(trim(r:status_line()), "LAN 192.168.1.1  WAN up  DHCP 1  CH 2  UP 00:00:00",
         "an offered lease is not counted as bound")
    node.dhcp.by_ip[ip] = { client = 13, state = "bound", expires = NOW + 30 }
    r:refresh()
    T.eq(trim(r:status_line()), "LAN 192.168.1.1  WAN up  DHCP 2  CH 2  UP 00:00:00",
         "a second bound lease is counted")
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
    T.eq(r:render()[3], "line 5" .. string.rep(" ", MIN_COLS - 6),
         "the first log row shows the oldest kept entry")
    T.eq(r:on_key("l"), "clear_log", "l clears again")
    T.eq(#r.logs, 0, "the ring is empty again")
    T.eq(r:render()[3], SPACES, "row 3 is blank after the clear")
end)

-- ===== 7 log scroll =======================================================
group("log-scroll", function()
    local r = fixture({ log_lines = 4 })
    T.eq(r:start(), true, "start with a four line log")
    T.eq(r:on_key("l"), "clear_log", "clear before filling")
    for _, name in ipairs({ "a", "b", "c", "d", "e", "f" }) do r:log(name) end
    local function row(i) return trim(r:render()[i]) end
    local header = trim(string.format("%-17s%-9s%s", "IP", "MAC", "EXPIRES"))
    T.eq(r.scroll, 0, "scroll starts at zero")
    T.eq(row(3), "c", "the window shows the newest four entries")
    T.eq(row(6), "f", "the newest entry is the last log row")
    T.eq(#r:render(), 11 + 4, "a four row log makes a fifteen line screen")
    T.eq(r:render()[7], DASHES, "the divider follows the four log rows")
    T.eq(row(8), header, "the lease header follows the divider")
    T.eq(row(14), "PAGE 1/1", "the page row is the second to last")
    T.eq(row(15), HELP, "the help row is the last line")
    T.eq(r:on_key("k"), "scroll", "k scrolls the log")
    T.eq(r.scroll, 1, "k moves the window back one line")
    T.eq(row(3), "b", "scroll 1 shows b first")
    T.eq(row(6), "e", "scroll 1 shows e as the last log row")
    T.eq(r:on_key("k"), "scroll", "k scrolls again")
    T.eq(r.scroll, 2, "scroll 2")
    T.eq(row(3), "a", "scroll 2 shows a first")
    T.eq(r:on_key("k"), "scroll", "k at the oldest end")
    T.eq(r.scroll, 2, "scroll clamps at the oldest entry")
    T.eq(row(3), "a", "the clamped window does not move")
    T.eq(r:on_key("j"), "scroll", "j scrolls forward")
    T.eq(r.scroll, 1, "j moves one line forward")
    T.eq(row(3), "b", "scroll 1 shows b again")
    T.eq(r:on_key("j"), "scroll", "j again")
    T.eq(r.scroll, 0, "back to the newest entries")
    T.eq(row(3), "c", "scroll 0 shows c first")
    T.eq(r:on_key("j"), "scroll", "j at the newest end")
    T.eq(r.scroll, 0, "j clamps at zero")
    T.eq(row(3), "c", "the clamped window does not move")
    T.eq(row(7), string.rep("-", MIN_COLS), "the divider stays at 3 + log_lines")
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
    T.eq(ip_of(lines[13]), "192.168.1.100", "page 1 starts at the first lease")
    T.eq(mac_of(lines[13]), "1", "the mac column is the client id")
    T.eq(trim(lines[18]), "PAGE 1/2", "two pages for seven leases")
    T.eq(ip_of(lines[17]), "192.168.1.104", "page 1 ends at the fifth lease")
    T.eq(r:on_key("J"), "page", "J pages forward")
    T.eq(r.lease_page, 2, "page 2")
    lines = r:render()
    T.eq(ip_of(lines[13]), "192.168.1.105", "page 2 starts at the sixth lease")
    T.eq(ip_of(lines[14]), "192.168.1.106", "page 2 holds the last lease")
    T.eq(lines[15], SPACES, "unused lease rows are blank")
    T.eq(trim(lines[18]), "PAGE 2/2", "the page indicator follows")
    T.eq(r:on_key("J"), "page", "J at the last page")
    T.eq(r.lease_page, 2, "paging clamps at the last page")
    T.eq(r:on_key("K"), "page", "K pages back")
    T.eq(r.lease_page, 1, "back on page 1")
    T.eq(r:on_key("K"), "page", "K at the first page")
    T.eq(r.lease_page, 1, "paging clamps at page 1")
    node.dhcp = lease_set({})
    lines = r:render()
    T.eq(trim(lines[13]), "(no leases)", "an empty lease table shows a placeholder")
    T.eq(#lines[13], MIN_COLS, "the placeholder row is padded")
    T.eq(trim(lines[18]), "PAGE 1/1", "an empty lease table has a single page")
    T.eq(#lines[18], MIN_COLS, "the page row is padded")
    T.eq(r.lease_page, 1, "the page resets when the table shrinks")
end)

-- ===== 9 expiry text ======================================================
group("expiry", function()
    local r, node = fixture()
    T.eq(r:start(), true, "start for the expiry text")
    local function expiry_for(expires)
        node.dhcp = one_lease(expires)
        r:refresh()
        return exp_of(r:render()[13])
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

-- ===== 12 small screen ====================================================
group("small-screen", function()
    local r, node, term = fixture()
    T.eq(r:start(), true, "start at 51x19")
    term.cols, term.rows = 40, 10
    local small = r:render()
    T.eq(#small, 1, "a short terminal renders one line")
    T.eq(small[1], SMALL_MSG, "the small-screen message")
    local ok = pcall(function() r:tick() end)
    T.ok(ok, "tick on a small terminal does not error")
    term.cols, term.rows = MIN_COLS, 18
    T.eq(r:render()[1], SMALL_MSG, "18 rows is still too small")
    term.cols, term.rows = 50, MIN_ROWS
    T.eq(r:render()[1], SMALL_MSG, "50 columns is still too small")
    term.cols, term.rows = MIN_COLS, MIN_ROWS
    local lines = r:render()
    T.eq(#lines, MIN_ROWS, "51x19 renders 19 rows again")
    local sized = true
    for i = 1, #lines do
        if #lines[i] ~= MIN_COLS then sized = false end
    end
    T.ok(sized, "every restored row is 51 columns")
    T.eq(node.setup_calls, 1, "resizing does not rerun setup")
end)

-- ===== 13 draw ============================================================
group("draw", function()
    local r, node, term = fixture()
    T.eq(r:start(), true, "start draws once")
    term.out = {}
    T.eq(r:draw(), true, "draw returns true")
    local lines = r:render()
    T.eq(#term.out, MIN_ROWS, "draw writes every row")
    local pos_ok, text_ok, bad = true, true, 0
    for i = 1, MIN_ROWS do
        local w = term.out[i]
        if not w or w.x ~= 1 or w.y ~= i then pos_ok = false; bad = i end
    end
    T.ok(pos_ok, "every draw row starts at column 1 (first bad row " .. tostring(bad) .. ")")
    for i = 1, MIN_ROWS do
        local w = term.out[i]
        if not w or w.text ~= lines[i] then text_ok = false; bad = i end
    end
    T.ok(text_ok, "every draw row is the render line (first bad row " .. tostring(bad) .. ")")
    term.cols, term.rows = 40, 10
    term.out = {}
    local clears_before = term.clears
    T.eq(r:draw(), true, "draw on a small terminal returns true")
    T.eq(#term.out, 1, "the small terminal draws a single line")
    local w = term.out[1]
    T.ok(w ~= nil and w.x == 1 and w.y == 1, "the small message is drawn at 1,1")
    T.eq(w and w.text, SMALL_MSG, "the small screen message text")
    T.ok(term.clears > clears_before, "the small terminal is cleared before the message")
    term.cols, term.rows = MIN_COLS, MIN_ROWS
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

-- ===== 14 the psk never reaches the screen ================================
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

-- ===== 15 resilience ======================================================
group("resilience", function()
    T.raises(function() R.new({ rpv = {} }) end, "new without a node and without rpv raises")
    local r, node = fixture()
    T.eq(r:start(), true, "start for the resilience checks")
    node.dhcp = nil
    local ok = pcall(function() r:tick() end)
    T.ok(ok, "tick without a dhcp server does not error")
    T.ok(trim(r:status_line()):find("DHCP 0", 1, true) ~= nil,
         "status reports zero leases without a dhcp server")
    r:log(nil)
    local first = r.logs[#r.logs]
    r:log(123)
    local second = r.logs[#r.logs]
    local previous = r.logs[#r.logs - 1]
    T.eq(first, "nil", "log(nil) stores tostring(nil)")
    T.eq(second, "123", "log() stringifies numbers")
    T.eq(previous, "nil", "the ring keeps insertion order")
end)

-- ===== 16 the fixed 19x51 layout ==========================================
group("layout", function()
    local r = fixture()
    T.eq(r:start(), true, "start for the layout check")
    T.eq(r:on_key("l"), "clear_log", "clear the log for a blank window")
    local lines = r:render()
    T.eq(#lines, MIN_ROWS, "a normal render is 19 rows tall")
    local sized = true
    for i = 1, MIN_ROWS do
        if #lines[i] ~= MIN_COLS then sized = false end
    end
    T.ok(sized, "every row is exactly 51 columns wide")
    T.eq(lines[2], DASHES, "row 2 is a rule")
    T.eq(lines[11], DASHES, "row 11 is a rule")
    local blank = true
    for i = 3, 10 do
        if lines[i] ~= SPACES then blank = false end
    end
    T.ok(blank, "an empty log window is blanks")
    T.eq(trim(lines[19]), HELP, "row 19 is the key help")
    local header = trim(string.format("%-17s%-9s%s", "IP", "MAC", "EXPIRES"))
    T.eq(trim(lines[12]), header, "row 12 is the lease header")
    T.eq(trim(lines[1]), trim(r:status_line()), "row 1 is the status line")
end)

-- ===== leave the console usable for the rest of the suite =================
local print_ok = (_G.print == orig_print)
_G.print = orig_print
T.ok(print_ok, "no group left the global print hijacked")
