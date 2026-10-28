--[[- apps/core_router.lua - RPV1 core router boot template.

What this file is
  A single-file, pure Lua 5.1 startup template for an RPV1 node. It performs
  four jobs, in this order:

  1. Startup lock. setup_router() spins on the redstone signal of the BOTTOM
     face. While the signal is off it yields with os.sleep(0.5); nothing below
     that loop is started. The lock is the first action of setup_router().
  2. Static IP map. load_static_ips() reads /disk/static_ip.conf, an ASCII
     `MAC,IP` file (one pair per line, blank lines and `#` comments ignored).
     Every pair is installed as a permanent static ARP/neighbour entry on
     node.arp.cache, so traffic to that IP is sent to that MAC without an ARP
     request. The map is also exposed as node.static_ips / M.static_ips with
     lookup helpers for DHCP, DNS and firewall layers.
  3. Hot reload. A background node task checks the file mtime every 5 s. When
     the mtime changes the file is parsed again and the static entries are
     swapped atomically: a missing or broken file keeps the previous map.
  4. Isolation. nat_input_hook() drops, without generating an ICMP error and
     with one log line, any packet whose SOURCE is in the public zone
     10.200.0.0/24 and whose DESTINATION is in the internal zone
     192.168.1.0/24. The hook then chains to the original rpv NAT hook, so
     normal NAT translation keeps working.

Usage
  local core = dofile("apps/core_router.lua")
  core.setup_router(node)            -- blocks until bottom redstone is on
  -- or, when the caller already holds the rpv module table:
  core.setup_router(node, rpv)
  -- setup_router also finds the rpv table in node.rpv, _G.rpv or
  -- package.loaded.rpv (for example after `local rpv = require("rpv")`).

  The global setup_router(node[, rpv]) is installed as a convenience so a
  startup script can call it without keeping the returned table.

/disk/static_ip.conf
  ASCII, one `MAC,IP` pair per line, blank lines and `#` comments ignored:

      12,192.168.1.10
      0x0000000D,192.168.1.11
      00:00:00:0E,192.168.1.12

  MAC is ComputerCraft's 32-bit computer ID (the rpv MAC). Accepted spellings:
  decimal ("12"), 0x-prefixed hex ("0x0000000D"), exactly 8 hex digits that
  contain a letter ("A1B2C3D4"), or four colon/dash separated hex bytes
  ("00:00:00:0E"). IP must be a strict dotted quad. Duplicate MACs, duplicate
  IPs, MAC 0 / 0xFFFFFFFF and multicast or broadcast IPs are rejected.

  The whole file is validated before the map is committed. A syntax error
  leaves the previous map in place and returns nil, "<path>:<line>: <reason>".

All terminal/internal log lines are ASCII. The file itself is ASCII and uses
no dependency outside the CraftOS fs/rs APIs and the rpv node object.
]]

local M = {}

M.VERSION = "0.1"

-- template knobs
M.STATIC_IP_PATH = "/disk/static_ip.conf"
M.RELOAD_INTERVAL = 5          -- seconds between mtime checks
M.REDSTONE_SIDE = "bottom"
M.REDSTONE_POLL = 0.5          -- os.sleep while the lock is closed

-- zone rule: source in the public zone AND destination in the internal zone
M.PUBLIC_NET = "10.200.0.0"
M.PUBLIC_PREFIX = 24
M.INTERNAL_NET = "192.168.1.0"
M.INTERNAL_PREFIX = 24

M.MAX_FILE_BYTES = 65536
M.MAX_ENTRIES = 1024
M.IP_BROADCAST = 4294967295
M.MULTICAST_LO = 3758096384    -- 224.0.0.0
M.MULTICAST_HI = 4026531839    -- 239.255.255.255
M.STATIC_ARP_TTL = 315360000   -- 10 years; refreshed by every reload

-- current map: mac(int) -> { mac, ip, ipstr, line }
M.static_ips = {}
M.by_ip = {}                   -- ip(int) -> mac(int)
M.path = M.STATIC_IP_PATH
M.owner = nil                  -- node that node.static_ips is mirrored on
M.loaded_at = nil
M.last_error = nil
M.stats = { loads = 0, failures = 0, reloads = 0, applied = 0, isolated = 0 }

local floor = math.floor

-- ===== small helpers ========================================================

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function count_map(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- node:log is the only output path of the library; a missing log method must
-- never break packet processing, so every call is protected
local function log(node, fmt, ...)
    if type(node) == "table" and type(node.log) == "function" then
        pcall(node.log, node, fmt, ...)
    end
end

-- ===== addresses and MACs ===================================================

-- strict dotted quad; nil when invalid. Leading zeros are rejected so that
-- "010.0.0.1" cannot silently mean one address in one parser and another here.
function M.parse_ipv4(s)
    if type(s) ~= "string" then return nil end
    s = trim(s)
    local a, b, c, d = s:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
    if not a then return nil end
    local parts = { a, b, c, d }
    local values = {}
    for i = 1, 4 do
        local part = parts[i]
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
        local v = tonumber(part)
        if not v or v > 255 then return nil end
        values[i] = v
    end
    return values[1] * 16777216 + values[2] * 65536 + values[3] * 256 + values[4]
end

function M.int_to_ip(n)
    n = floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    return string.format("%d.%d.%d.%d",
        floor(n / 16777216) % 256,
        floor(n / 65536) % 256,
        floor(n / 256) % 256,
        n % 256)
end

local function to_ip_int(v)
    if type(v) == "number" then
        if v ~= v or v < 0 or v > M.IP_BROADCAST then return nil end
        return floor(v)
    end
    if type(v) == "string" then return M.parse_ipv4(v) end
    return nil
end

-- MAC forms: decimal computer ID, 0x hex, 8 hex digits with a letter, or four
-- colon/dash separated hex bytes. Returns the 32-bit integer or nil.
function M.parse_mac(s)
    if type(s) ~= "string" then return nil end
    s = trim(s)
    if s == "" then return nil end

    local a, b, c, d = s:match("^(%x%x?)[:%-](%x%x?)[:%-](%x%x?)[:%-](%x%x?)$")
    if a then
        local value = 0
        for _, part in ipairs({ a, b, c, d }) do
            value = value * 256 + tonumber(part, 16)
        end
        return value
    end

    if s:match("^0[xX]%x+$") then
        local digits = s:sub(3)
        if #digits > 8 then return nil end
        local value = tonumber(digits, 16)
        if not value or value > M.IP_BROADCAST then return nil end
        return value
    end

    if s:match("^%d+$") then
        local value = tonumber(s)
        if not value or value > M.IP_BROADCAST then return nil end
        return value
    end

    if #s == 8 and s:match("^%x+$") then
        return tonumber(s, 16)
    end

    return nil
end

function M.mac_to_text(mac)
    local n = tonumber(mac)
    if not n then return "?" end
    return string.format("%08X", floor(n) % 4294967296)
end

-- ===== subnet rule ==========================================================

function M.in_subnet(ip, net, prefix)
    local i = to_ip_int(ip)
    local n = to_ip_int(net)
    prefix = tonumber(prefix)
    if not i or not n or not prefix then return false end
    if prefix <= 0 then return true end
    if prefix >= 32 then return i == n end
    local size = 2 ^ (32 - prefix)
    return (i - (i % size)) == n
end

M.PUBLIC_NET_INT = M.parse_ipv4(M.PUBLIC_NET)
M.INTERNAL_NET_INT = M.parse_ipv4(M.INTERNAL_NET)

function M.is_public(ip)
    return M.in_subnet(ip, M.PUBLIC_NET_INT, M.PUBLIC_PREFIX)
end

function M.is_internal(ip)
    return M.in_subnet(ip, M.INTERNAL_NET_INT, M.INTERNAL_PREFIX)
end

-- the isolation predicate: public source -> internal destination
function M.should_isolate(src, dst)
    return M.is_public(src) and M.is_internal(dst)
end

-- ===== static IP file =======================================================

-- pure parser; returns a fresh map or nil, err. Nothing is committed here.
function M.parse_static_ips(text, origin)
    if type(text) ~= "string" then return nil, "config must be text" end
    if #text > M.MAX_FILE_BYTES then
        return nil, "config is larger than " .. M.MAX_FILE_BYTES .. " bytes"
    end

    local map = {}
    local seen_mac, seen_ip = {}, {}
    local n = 0
    local lineno = 0
    local payload = text .. "\n"

    for raw in payload:gmatch("(.-)\n") do
        lineno = lineno + 1
        local line = trim(raw:gsub("#.*$", ""))
        if line ~= "" then
            local where = string.format("%s:%d", tostring(origin or M.STATIC_IP_PATH), lineno)
            local mac_s, ip_s = line:match("^([^,]+),([^,]+)$")
            if not mac_s then
                return nil, where .. ": expected MAC,IP"
            end

            local mac = M.parse_mac(mac_s)
            if not mac then
                return nil, where .. ": bad MAC '" .. trim(mac_s) .. "'"
            end
            if mac == 0 or mac == M.IP_BROADCAST then
                return nil, where .. ": MAC must be a unicast host ID (1..0xFFFFFFFE)"
            end

            local ip = M.parse_ipv4(ip_s)
            if not ip then
                return nil, where .. ": bad IPv4 '" .. trim(ip_s) .. "'"
            end
            if ip == 0 or ip == M.IP_BROADCAST then
                return nil, where .. ": IP must be a unicast address"
            end
            if ip >= M.MULTICAST_LO and ip <= M.MULTICAST_HI then
                return nil, where .. ": IP must not be multicast"
            end

            if seen_mac[mac] then
                return nil, where .. ": duplicate MAC " .. M.mac_to_text(mac)
            end
            if seen_ip[ip] then
                return nil, where .. ": duplicate IP " .. M.int_to_ip(ip)
            end

            seen_mac[mac] = true
            seen_ip[ip] = true
            map[mac] = { mac = mac, ip = ip, ipstr = M.int_to_ip(ip), line = lineno }
            n = n + 1
            if n > M.MAX_ENTRIES then
                return nil, "too many entries (max " .. M.MAX_ENTRIES .. ")"
            end
        end
    end

    return map
end

-- read /disk/static_ip.conf and commit a fully valid map in one step. On any
-- error the previous M.static_ips / M.by_ip stay untouched.
function M.load_static_ips(path)
    path = path or M.STATIC_IP_PATH
    if type(fs) ~= "table" then
        M.stats.failures = M.stats.failures + 1
        M.last_error = "fs API is unavailable"
        return nil, M.last_error
    end

    if type(fs.exists) == "function" then
        local ok, present = pcall(fs.exists, path)
        if not ok or not present then
            M.stats.failures = M.stats.failures + 1
            M.last_error = "not found: " .. tostring(path)
            return nil, M.last_error
        end
    end

    local attr = nil
    if type(fs.attributes) == "function" then
        local ok, value = pcall(fs.attributes, path)
        if ok and type(value) == "table" then attr = value end
    end
    if attr and type(attr.size) == "number" and attr.size > M.MAX_FILE_BYTES then
        M.stats.failures = M.stats.failures + 1
        M.last_error = "file is larger than " .. M.MAX_FILE_BYTES .. " bytes"
        return nil, M.last_error
    end

    local ok_open, handle = pcall(fs.open, path, "r")
    if not ok_open or not handle then
        M.stats.failures = M.stats.failures + 1
        M.last_error = "cannot open " .. tostring(path)
        return nil, M.last_error
    end

    local ok_read, text = pcall(handle.readAll, handle)
    pcall(handle.close, handle)
    if not ok_read or type(text) ~= "string" then
        M.stats.failures = M.stats.failures + 1
        M.last_error = "cannot read " .. tostring(path)
        return nil, M.last_error
    end

    local map, err = M.parse_static_ips(text, path)
    if not map then
        M.stats.failures = M.stats.failures + 1
        M.last_error = err
        return nil, err
    end

    local by_ip = {}
    for mac, entry in pairs(map) do by_ip[entry.ip] = mac end

    M.static_ips = map
    M.by_ip = by_ip
    M.path = path
    M.loaded_at = os.clock()
    M.last_error = nil
    M.stats.loads = M.stats.loads + 1
    if type(M.owner) == "table" then M.owner.static_ips = map end

    return { ok = true, path = path, count = count_map(map) }
end

-- install the current map as static ARP entries. Entries from a previous
-- reload are removed only when this module still owns them, so a dynamic ARP
-- reply is never deleted by mistake.
function M.apply_static_ips(node)
    if type(node) ~= "table" then return 0, "node is required" end

    M.owner = node
    node.static_ips = M.static_ips
    node.static_ip_path = M.path

    local arp = node.arp
    if type(arp) ~= "table" or type(arp.cache) ~= "table" then
        return 0, "node.arp.cache is missing"
    end

    local local_ips = {}
    if type(node.ifaces) == "table" then
        for _, iface in ipairs(node.ifaces) do
            if type(iface) == "table" and type(iface.ip) == "number" then
                local_ips[iface.ip] = true
            end
        end
    end
    if type(node.lo) == "table" and type(node.lo.ip) == "number" then
        local_ips[node.lo.ip] = true
    end

    local previous = node.core_router_static_arp or {}
    for ip in pairs(previous) do
        local entry = arp.cache[ip]
        if type(entry) == "table" and entry.core_router then arp.cache[ip] = nil end
    end

    local now = os.clock()
    local installed = {}
    local applied, skipped = 0, 0

    for mac, entry in pairs(M.static_ips) do
        if local_ips[entry.ip] then
            skipped = skipped + 1
            log(node, "CORE_ROUTER_STATIC_SKIP ip=%s mac=%s reason=local_address",
                entry.ipstr, M.mac_to_text(mac))
        else
            arp.cache[entry.ip] = {
                mac = mac,
                expires = now + M.STATIC_ARP_TTL,
                core_router = true,
            }
            installed[entry.ip] = true
            applied = applied + 1
        end
    end

    node.core_router_static_arp = installed
    M.stats.applied = applied
    if skipped > 0 then
        log(node, "CORE_ROUTER_STATIC_APPLY applied=%d skipped=%d", applied, skipped)
    end
    return applied
end

function M.lookup_ip(mac)
    local n = type(mac) == "number" and floor(mac) or M.parse_mac(mac)
    if not n then return nil end
    local entry = M.static_ips[n]
    return entry and entry.ipstr or nil
end

function M.lookup_mac(ip)
    local n = to_ip_int(ip)
    if not n then return nil end
    local mac = M.by_ip[n]
    if not mac then return nil end
    return mac, M.mac_to_text(mac)
end

function M.count()
    return count_map(M.static_ips)
end

-- ===== hot reload watcher ===================================================

function M.file_mtime(path)
    if type(fs) ~= "table" then return nil end
    if type(fs.exists) == "function" then
        local ok, present = pcall(fs.exists, path)
        if not ok or not present then return nil end
    end
    if type(fs.attributes) ~= "function" then return nil end
    local ok, attr = pcall(fs.attributes, path)
    if not ok or type(attr) ~= "table" then return nil end
    return attr.modification
end

-- background coroutine task: poll mtime every M.RELOAD_INTERVAL seconds and
-- apply a changed file. Parse failures are logged and keep the old map.
function M.start_watcher(node, path)
    path = path or M.path or M.STATIC_IP_PATH
    if type(node) ~= "table" or type(node.add_task) ~= "function" then
        return nil, "node.add_task is missing"
    end
    if node.core_router_watch and not node.core_router_watch.dead then
        return true
    end

    local last = M.file_mtime(path)
    local task = node:add_task("core-router-static-ip", function()
        while true do
            os.sleep(M.RELOAD_INTERVAL)
            local mtime = M.file_mtime(path)
            if mtime ~= last then
                last = mtime
                local result, err = M.load_static_ips(path)
                if result then
                    local applied, apply_err = M.apply_static_ips(node)
                    M.stats.reloads = M.stats.reloads + 1
                    if apply_err then
                        log(node, "CORE_ROUTER_STATIC_RELOAD_APPLY_FAIL path=%s err=%s",
                            path, tostring(apply_err))
                    else
                        log(node, "CORE_ROUTER_STATIC_RELOAD path=%s count=%d", path, applied)
                    end
                else
                    log(node, "CORE_ROUTER_STATIC_RELOAD_FAIL path=%s err=%s",
                        path, tostring(err))
                end
            end
        end
    end)

    node.core_router_watch = task
    log(node, "CORE_ROUTER_STATIC_WATCH path=%s interval=%ds", path, M.RELOAD_INTERVAL)
    return true
end

-- ===== redstone startup lock ================================================

function M.redstone_input(side)
    local api = rawget(_G, "rs")
    if type(api) ~= "table" then api = rawget(_G, "redstone") end
    if type(api) ~= "table" or type(api.getInput) ~= "function" then
        return false, "redstone API is unavailable"
    end
    local ok, value = pcall(api.getInput, side or M.REDSTONE_SIDE)
    if not ok then return false, tostring(value) end
    return value and true or false
end

-- block until the bottom face is powered. This is intentionally a hard lock:
-- there is no timeout and no override.
function M.wait_for_redstone(node, side)
    side = side or M.REDSTONE_SIDE
    local start = os.clock()
    local announced = false

    while true do
        local on, err = M.redstone_input(side)
        if on then
            log(node, "CORE_ROUTER_REDSTONE_ON side=%s waited=%.1fs",
                side, os.clock() - start)
            return true
        end
        if not announced then
            announced = true
            if err then
                log(node, "CORE_ROUTER_REDSTONE_WAIT side=%s reason=%s", side, tostring(err))
            else
                log(node, "CORE_ROUTER_REDSTONE_WAIT side=%s", side)
            end
        end
        os.sleep(M.REDSTONE_POLL)
    end
end

-- ===== packet isolation hook ===============================================

local saved_nat_hook = nil

local function iface_text(iface)
    if type(iface) == "table" then
        return tostring(iface.name or iface.side or "?")
    end
    return tostring(iface or "-")
end

local function ip_text(value)
    local n = to_ip_int(value)
    if n then return M.int_to_ip(n) end
    return tostring(value)
end

-- shared by the rpv NAT hook and the node.ip_deliver fallback
local function acl_drop(node, iface, h)
    if type(h) ~= "table" or not M.should_isolate(h.src, h.dst) then
        return false
    end

    M.stats.isolated = M.stats.isolated + 1
    local msg = string.format(
        "CORE_ROUTER_ISOLATE_DROP src=%s dst=%s proto=%s iface=%s",
        ip_text(h.src), ip_text(h.dst), tostring(h.proto), iface_text(iface))

    if type(node) == "table" and type(node.log) == "function" then
        pcall(node.log, node, "%s", msg)
    else
        print(msg)
    end
    return true
end

-- Replaces rpv.nat_input_hook. Order matters: the isolation check happens
-- before any NAT translation, and a "drop" here means no ICMP is generated.
function M.nat_input_hook(node, iface, h, payload)
    if acl_drop(node, iface, h) then return "drop" end
    if type(saved_nat_hook) == "function" then
        return saved_nat_hook(node, iface, h, payload)
    end
    return nil
end

-- chain our hook in front of the real NAT hook; safe to call more than once
function M.install_nat_hook(rpv)
    if type(rpv) ~= "table" then return nil, "rpv module table is required" end
    if rpv.nat_input_hook == M.nat_input_hook then
        M.nat_hook_target = rpv
        return true
    end
    if rpv.nat_input_hook ~= nil and type(rpv.nat_input_hook) ~= "function" then
        return nil, "rpv.nat_input_hook is not a function"
    end
    saved_nat_hook = rpv.nat_input_hook
    rpv.nat_input_hook = M.nat_input_hook
    M.nat_hook_target = rpv
    return true
end

-- fallback when setup_router() cannot find the rpv module table: wrap the
-- node's own delivery method. This check also runs before NAT and forwards
-- untouched packets to the original method.
function M.install_node_guard(node)
    if type(node) ~= "table" or type(node.ip_deliver) ~= "function" then
        return nil, "node.ip_deliver is missing"
    end
    if node.core_router_guard == M then return true end

    local base = node.ip_deliver
    node.ip_deliver = function(self, iface, h, payload)
        if acl_drop(self, iface, h) then return end
        return base(self, iface, h, payload)
    end
    node.core_router_guard = M
    return true
end

local function looks_like_rpv(t)
    return type(t) == "table"
        and (type(t.node_new) == "function" or type(t.nat_input_hook) == "function")
end

local function find_rpv(node, explicit)
    if looks_like_rpv(explicit) then return explicit end
    if type(node) == "table" and looks_like_rpv(node.rpv) then return node.rpv end
    if looks_like_rpv(rawget(_G, "rpv")) then return rawget(_G, "rpv") end

    local package_table = rawget(_G, "package")
    if type(package_table) == "table" and type(package_table.loaded) == "table" then
        local cached = package_table.loaded.rpv
        if looks_like_rpv(cached) then return cached end
    end
    return nil
end

-- ===== public entry point ===================================================

-- Call this as the first thing in the boot script. It blocks on the redstone
-- lock, then loads the static map, starts the 5 s watcher and installs the
-- isolation hook. rpv is optional; it is auto-detected when possible.
function M.setup_router(node, rpv)
    if type(node) ~= "table" then return nil, "node is required" end
    if node.core_router_started then
        log(node, "CORE_ROUTER_ALREADY_SETUP")
        return node.core_router_runtime
    end

    log(node, "CORE_ROUTER_BOOT static_ip=%s redstone=%s",
        M.STATIC_IP_PATH, M.REDSTONE_SIDE)

    -- 1. startup lock: nothing below runs until the bottom face is powered
    M.wait_for_redstone(node, M.REDSTONE_SIDE)

    -- 2. floppy static map; a missing or broken file is not fatal
    M.owner = node
    node.static_ips = M.static_ips
    node.static_ip_path = M.STATIC_IP_PATH

    local loaded, load_err = M.load_static_ips(M.STATIC_IP_PATH)
    local applied = 0
    if loaded then
        local apply_err
        applied, apply_err = M.apply_static_ips(node)
        if apply_err then
            log(node, "CORE_ROUTER_STATIC_APPLY_FAIL path=%s err=%s",
                loaded.path, tostring(apply_err))
        else
            log(node, "CORE_ROUTER_STATIC_LOAD path=%s count=%d", loaded.path, applied)
        end
    else
        log(node, "CORE_ROUTER_STATIC_SKIP path=%s err=%s",
            M.STATIC_IP_PATH, tostring(load_err))
    end

    -- 3. background mtime watcher (node coroutine task)
    local watched, watch_err = M.start_watcher(node, M.STATIC_IP_PATH)
    if not watched then
        log(node, "CORE_ROUTER_STATIC_WATCH_FAIL err=%s", tostring(watch_err))
    end

    -- 4. isolation hook, chained in front of the real NAT hook when available
    local target = find_rpv(node, rpv)
    local mode, hook_err = "none", nil

    if target then
        local ok, err = M.install_nat_hook(target)
        if ok then
            mode = "rpv"
        else
            hook_err = err
        end
    end

    if mode == "none" then
        local ok, err = M.install_node_guard(node)
        if ok then
            mode = "node"
        else
            hook_err = err
        end
    end

    if mode == "none" then
        log(node, "CORE_ROUTER_ISOLATION_UNAVAILABLE err=%s", tostring(hook_err))
    else
        log(node, "CORE_ROUTER_NAT_HOOK mode=%s", mode)
    end

    local runtime = {
        ok = mode ~= "none",
        path = M.STATIC_IP_PATH,
        redstone = M.REDSTONE_SIDE,
        mappings = applied,
        hook = mode,
    }

    node.core_router = M
    node.core_router_runtime = runtime
    node.core_router_started = true

    log(node, "CORE_ROUTER_READY static_ip=%s mappings=%d hook=%s",
        M.STATIC_IP_PATH, applied, mode)
    return runtime
end

-- optional table-module form for the node2/startup.lua app loader, so
-- role.txt can use `app=core_router` as well as `dofile("apps/core_router.lua")`
function M.new(opts)
    opts = opts or {}
    local app = { node = opts.node, rpv = opts.rpv }
    function app:start()
        local runtime, err = M.setup_router(self.node, self.rpv)
        if not runtime then return false, err end
        return true
    end
    return app
end

-- convenience global for boot scripts that use dofile() and do not keep M
if type(_G) == "table" then
    _G.setup_router = M.setup_router
end

return M
