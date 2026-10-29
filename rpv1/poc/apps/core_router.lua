--[[- apps/core_router.lua - RPV1 core router boot template.

What this file is
  A single-file, pure Lua 5.1 startup template for an RPV1 node. It performs
  five jobs, in this order:

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
   5. HA configuration sync. After the lock the node binds UDP 6710 and answers
      the RPV1-HA/1 SYNC requests a hot-standby switch sends: the reply is the
      CFG datagram apps/backup_router.lua builds (master/to/nonce plus
      pool_start/pool_end/lease_time/gateway/dns/prefix/dhcp_port/uptime), so a
      backup can start the very same DHCP service after a takeover. Values come
      from the live node.dhcp_server, then from the role.txt dhcp_pool keys, then
      from M.DEFAULT_DHCP_CONFIG. The responder never sends a request itself,
      stays silent while node.ha_taken_over or node.ha_dhcp_active is set, caps
      one datagram at 512 bytes and drops a source that sends more than five
      requests per second.

Usage
  local core = dofile("apps/core_router.lua")
  core.setup_router(node)            -- blocks until bottom redstone is on
  -- or, when the caller already holds the rpv module table:
  core.setup_router(node, rpv)
  -- setup_router also finds the rpv table in node.rpv, _G.rpv or
  -- package.loaded.rpv (for example after `local rpv = require("rpv")`).

  The third argument is optional and only tunes the template, so the two
  argument call keeps working:
  core.setup_router(node, rpv, { ha_sync = false })   -- no HA responder
  core.setup_router(node, rpv, { ha_port = 6711 })     -- another sync port
  core.setup_router(node, rpv, { ha_primary_client = true }) -- log every reply

  The global setup_router(node[, rpv, opts]) is installed as a convenience so a
  startup script can call it without keeping the returned table.

HA log tags (all lines are ASCII)
  CORE_ROUTER_HA_READY CORE_ROUTER_HA_OFF CORE_ROUTER_HA_UNAVAILABLE
  CORE_ROUTER_HA_REPLY CORE_ROUTER_HA_SILENT CORE_ROUTER_HA_RATE
  CORE_ROUTER_HA_BAD CORE_ROUTER_HA_SEND_FAIL

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

-- HA configuration sync responder (RPV1-HA/1, wire-compatible with backup_router)
M.HA_PROTO = "RPV1-HA/1"
M.HA_PORT = 6710               -- UDP port of the HA protocol
M.HA_MAX_BYTES = 512           -- one datagram; larger packets are never parsed
M.HA_MAX_TOKENS = 32           -- fields per datagram
M.HA_RATE_LIMIT = 5            -- requests accepted per source per window
M.HA_RATE_WINDOW = 1           -- seconds of that window

-- what the switch reports when it has neither a DHCP server nor a pool spec
M.DEFAULT_DHCP_CONFIG = {
    pool_start = "10.200.0.50",
    pool_end = "10.200.0.150",
    lease_time = 600,
    gateway = "10.200.0.1",
    dns = "10.200.0.1",
    prefix = 24,
    dhcp_port = 6700,
}

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
    local bits = tonumber(prefix)
    if not i or not n or not bits then return false end
    if bits <= 0 then return true end
    if bits >= 32 then return i == n end
    local size = 2 ^ (32 - bits)
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
function M.load_static_ips(source)
    local path = source or M.STATIC_IP_PATH
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
function M.start_watcher(node, watch_path)
    local path = watch_path or M.path or M.STATIC_IP_PATH
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
function M.wait_for_redstone(node, lock_side)
    local side = lock_side or M.REDSTONE_SIDE
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

-- ===== HA configuration sync responder ======================================
-- Wire-compatible subset of apps/backup_router.lua. A hot-standby switch sends
--   RPV1-HA/1 SYNC id=<id> nonce=<n>
-- to UDP 6710 and this node answers
--   RPV1-HA/1 CFG master=<id> to=<id> nonce=<n> pool_start=... ... uptime=<n>
-- with exactly the field set and order backup_router builds, so its
-- parse_message/parse_config/on_sync_reply accept the reply unchanged. The
-- primary only answers: it never sends a SYNC request of its own.
--
-- The two files must not drift apart, so the parser below keeps the backup
-- parser's rules: protocol token, SYNC or CFG kind, `key=value` fields,
-- no duplicate key, no more than M.HA_MAX_TOKENS fields, no packet above
-- M.HA_MAX_BYTES bytes.

function M.ha_copy_config(cfg)
    return {
        pool_start = cfg.pool_start, pool_end = cfg.pool_end,
        lease_time = cfg.lease_time, gateway = cfg.gateway, dns = cfg.dns,
        prefix = cfg.prefix, dhcp_port = cfg.dhcp_port,
    }
end

-- Values reported to a backup, in the same priority order backup_router uses:
--   1. the live DHCP server (the truth: it is what clients are served now)
--   2. the role.txt pool keys (a configured but not yet started server; using
--      the live pool keeps both switches on one address range)
--   3. M.DEFAULT_DHCP_CONFIG verbatim. Like the backup, the defaults are used
--      as written; unlike it, the gateway is not replaced by the first
--      interface address, because on the core switch that interface may be the
--      LAN side, and a backup that takes over must inherit the public gateway.
function M.ha_config_from_node(node)
    local d = M.DEFAULT_DHCP_CONFIG
    if type(node) ~= "table" then return M.ha_copy_config(d) end

    local srv = node.dhcp_server
    if type(srv) == "table" and type(srv.lo) == "number" then
        return {
            pool_start = M.int_to_ip(srv.lo),
            pool_end = M.int_to_ip(srv.hi),
            lease_time = tonumber(srv.lease) or d.lease_time,
            gateway = M.int_to_ip(srv.gw),
            dns = M.int_to_ip(srv.dns),
            prefix = tonumber(srv.prefix) or d.prefix,
            dhcp_port = tonumber(srv.port) or d.dhcp_port,
        }
    end

    local cfg = type(node.cfg) == "table" and node.cfg or {}
    local pool = tostring(cfg.dhcp_pool or "")
    local lo, hi = pool:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)%s*$")
    if lo and M.parse_ipv4(lo) and M.parse_ipv4(hi) then
        local gw = cfg.dhcp_gw or d.gateway
        return {
            pool_start = lo,
            pool_end = hi,
            lease_time = tonumber(cfg.dhcp_lease) or d.lease_time,
            gateway = gw,
            dns = cfg.dhcp_dns or gw,
            prefix = tonumber(cfg.dhcp_prefix) or d.prefix,
            dhcp_port = tonumber(cfg.dhcp_port) or d.dhcp_port,
        }
    end

    return M.ha_copy_config(d)
end

function M.ha_config_text(cfg)
    return string.format("pool=%s-%s lease=%ds gw=%s dns=%s prefix=%d port=%d",
        tostring(cfg.pool_start), tostring(cfg.pool_end), floor(cfg.lease_time or 0),
        tostring(cfg.gateway), tostring(cfg.dns), floor(cfg.prefix or 0),
        floor(cfg.dhcp_port or 0))
end

-- the reply text, byte for byte what backup_router.build_reply() produces
function M.ha_build_reply(cfg, to_id, nonce, master_id)
    return table.concat({
        M.HA_PROTO,
        "CFG",
        "master=" .. tostring(floor(master_id or 0)),
        "to=" .. tostring(floor(to_id or 0)),
        "nonce=" .. tostring(floor(nonce or 0)),
        "pool_start=" .. tostring(cfg.pool_start),
        "pool_end=" .. tostring(cfg.pool_end),
        "lease_time=" .. tostring(floor(cfg.lease_time or 600)),
        "gateway=" .. tostring(cfg.gateway),
        "dns=" .. tostring(cfg.dns),
        "prefix=" .. tostring(floor(cfg.prefix or 24)),
        "dhcp_port=" .. tostring(floor(cfg.dhcp_port or 6700)),
        "uptime=" .. tostring(floor(os.clock())),
    }, " ")
end

-- same acceptance rules as backup_router.parse_message()
function M.ha_parse(text)
    if type(text) ~= "string" or text == "" then return nil, "empty datagram" end
    if #text > M.HA_MAX_BYTES then return nil, "datagram too large" end

    local tokens = {}
    for token in text:gmatch("%S+") do
        tokens[#tokens + 1] = token
        if #tokens > M.HA_MAX_TOKENS then return nil, "too many fields" end
    end
    if tokens[1] ~= M.HA_PROTO then return nil, "protocol mismatch" end
    if tokens[2] ~= "SYNC" and tokens[2] ~= "CFG" then
        return nil, "unknown message kind " .. tostring(tokens[2])
    end

    local msg = { kind = tokens[2], fields = {} }
    for i = 3, #tokens do
        local key, value = tokens[i]:match("^([%w_]+)=(.+)$")
        if not key then return nil, "malformed field " .. tostring(tokens[i]) end
        if msg.fields[key] then return nil, "duplicate field " .. key end
        msg.fields[key] = value
    end
    return msg
end

-- is this one of our own addresses? rpv delivers a datagram addressed to an
-- address the node owns to the node itself (rpv/node.lua send_ip), so a reply to
-- a peer that shares the VIP would never leave the box.
function M.ha_is_local_ip(node, ip)
    if type(node) ~= "table" or type(ip) ~= "number" then return false end
    if type(node.ifaces) == "table" then
        for _, iface in ipairs(node.ifaces) do
            if type(iface) == "table" and iface.ip == ip then return true end
        end
    end
    if type(node.lo) == "table" and node.lo.ip == ip then return true end
    return false
end

-- answer on the limited broadcast when the requester shares our address,
-- exactly the shared-VIP case backup_router documents
function M.ha_reply_dst(rt, src)
    if type(src) ~= "number" then return src end
    if not M.ha_is_local_ip(rt.node, src) then return src end
    local bcast = type(rt.rpv) == "table" and rt.rpv.IP_BCAST or nil
    if type(bcast) == "number" then return bcast end
    return src
end

-- why the responder must stay mute right now, or nil when it may answer.
-- Both flags exist in the fleet: backup_router raises ha_dhcp_active while its
-- own DHCP server runs, a takeover wrapper may raise ha_taken_over.
function M.ha_answer_blocked(node)
    if type(node) ~= "table" then return "node_is_not_a_table" end
    if node.ha_taken_over == true then return "ha_taken_over" end
    if node.ha_dhcp_active == true then return "ha_dhcp_active" end
    return nil
end

-- One datagram. Returns the decision as a string ("replied", "silent",
-- "rate", "bad", "ignored", "send_fail") so callers and tests do not have to
-- infer it from the log.
function M.ha_handle(rt, data, src, sport)
    if type(rt) ~= "table" or type(rt.node) ~= "table" then return "bad" end
    local node = rt.node
    local stats = rt.stats
    stats.requests = stats.requests + 1

    local reason = M.ha_answer_blocked(node)
    if reason then
        stats.silent = stats.silent + 1
        log(node, "CORE_ROUTER_HA_SILENT src=%s reason=%s (responder is muted)",
            ip_text(src), reason)
        return "silent"
    end

    if type(data) ~= "string" or data == "" then
        stats.bad = stats.bad + 1
        log(node, "CORE_ROUTER_HA_BAD src=%s reason=empty_datagram", ip_text(src))
        return "bad"
    end
    if #data > M.HA_MAX_BYTES then
        stats.bad = stats.bad + 1
        log(node, "CORE_ROUTER_HA_BAD src=%s reason=datagram_too_large bytes=%d max=%d",
            ip_text(src), #data, M.HA_MAX_BYTES)
        return "bad"
    end

    local now = rt.clock and rt.clock() or os.clock()
    local key = tostring(src)
    local bucket = rt.rates[key]
    if type(bucket) ~= "table" or (now - bucket.started) >= M.HA_RATE_WINDOW then
        bucket = { started = now, count = 0 }
        rt.rates[key] = bucket
    end
    bucket.count = bucket.count + 1
    if bucket.count > M.HA_RATE_LIMIT then
        stats.rate_limited = stats.rate_limited + 1
        log(node, "CORE_ROUTER_HA_RATE src=%s count=%d window=%ds limit=%d (dropped)",
            ip_text(src), bucket.count, M.HA_RATE_WINDOW, M.HA_RATE_LIMIT)
        return "rate"
    end

    local msg, err = M.ha_parse(data)
    if not msg then
        stats.bad = stats.bad + 1
        log(node, "CORE_ROUTER_HA_BAD src=%s reason=%s", ip_text(src), tostring(err))
        return "bad"
    end
    if msg.kind ~= "SYNC" then return "ignored" end

    local want = tonumber(msg.fields.id)
    if not want then
        stats.bad = stats.bad + 1
        log(node, "CORE_ROUTER_HA_BAD src=%s reason=id_is_missing", ip_text(src))
        return "bad"
    end
    want = floor(want)
    if want == node.id then return "ignored" end

    -- the nonce must be echoed, so a request without one cannot be answered
    local nonce = tonumber(msg.fields.nonce)
    if not nonce then
        stats.bad = stats.bad + 1
        log(node, "CORE_ROUTER_HA_BAD src=%s reason=nonce_is_missing", ip_text(src))
        return "bad"
    end

    local cfg = M.ha_config_from_node(node)
    local reply = M.ha_build_reply(cfg, want, floor(nonce), node.id)
    local port = rt.port
    local dst = M.ha_reply_dst(rt, src)
    local ok, send_err = pcall(rt.rpv.udp_send, node, dst, port, sport or port, reply)
    if not ok then
        stats.send_fail = stats.send_fail + 1
        log(node, "CORE_ROUTER_HA_SEND_FAIL to=%d err=%s", want, tostring(send_err))
        return "send_fail"
    end

    stats.replies = stats.replies + 1
    if rt.primary_client or stats.replies == 1 or stats.replies % 12 == 0 then
        log(node, "CORE_ROUTER_HA_REPLY to=%d nonce=%d %s",
            want, floor(nonce), M.ha_config_text(cfg))
    end
    return "replied"
end

-- bind the responder. Idempotent for one node; the socket is kept on the
-- runtime so a takeover wrapper can close it. rt.clock may be replaced by tests.
function M.start_ha(node, rpv, opts)
    if type(node) ~= "table" then return nil, "node is required" end
    if type(node.core_router_ha) == "table" and node.core_router_ha.started then
        return node.core_router_ha
    end

    local base = type(opts) == "table" and opts or {}
    local port = tonumber(base.ha_port) or M.HA_PORT
    if not port or port < 1 or port > 65535 then
        return nil, "bad ha_port " .. tostring(base.ha_port)
    end
    port = floor(port)

    if type(node.bind) ~= "function" then return nil, "node:bind is missing" end
    local target = rpv
    if type(target) ~= "table" or type(target.udp_send) ~= "function" then
        target = find_rpv(node, rpv)
    end
    if type(target) ~= "table" or type(target.udp_send) ~= "function" then
        return nil, "rpv.udp_send is required to answer"
    end

    local rt = {
        node = node, rpv = target, port = port,
        primary_client = (base.ha_primary_client == true),
        started = false, socket = nil, clock = nil, rates = {},
        stats = { requests = 0, replies = 0, bad = 0, rate_limited = 0,
                  silent = 0, send_fail = 0 },
    }
    node.core_router_ha = rt

    local ok, socket = pcall(node.bind, node, port, function(data, src, sport)
        M.ha_handle(rt, data, src, sport)
    end)
    if not ok or type(socket) ~= "table" then
        node.core_router_ha = nil
        return nil, "cannot bind HA port " .. tostring(port) .. ": " .. tostring(socket)
    end

    rt.socket = socket
    rt.started = true
    log(node, "CORE_ROUTER_HA_READY port=%d proto=%s primary_client=%s",
        port, M.HA_PROTO, tostring(rt.primary_client))
    return rt
end

-- ===== public entry point ===================================================

-- Call this as the first thing in the boot script. It blocks on the redstone
-- lock, then loads the static map, starts the 5 s watcher, installs the
-- isolation hook and (unless opts.ha_sync == false) binds the HA responder.
-- rpv is optional; it is auto-detected when possible. opts is optional too.
function M.setup_router(node, rpv, opts)
    if type(node) ~= "table" then return nil, "node is required" end
    if node.core_router_started then
        log(node, "CORE_ROUTER_ALREADY_SETUP")
        return node.core_router_runtime
    end

    local base = type(opts) == "table" and opts or {}

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

    -- 5. HA configuration sync responder, always after the redstone lock, so a
    -- locked switch answers nothing at all
    local ha, ha_port = nil, nil
    if base.ha_sync == false then
        log(node, "CORE_ROUTER_HA_OFF")
    else
        local ha_err
        ha, ha_err = M.start_ha(node, target, base)
        if ha then
            ha_port = ha.port
        else
            log(node, "CORE_ROUTER_HA_UNAVAILABLE err=%s", tostring(ha_err))
        end
    end

    local runtime = {
        ok = mode ~= "none",
        path = M.STATIC_IP_PATH,
        redstone = M.REDSTONE_SIDE,
        mappings = applied,
        hook = mode,
        ha = ha,
        ha_port = ha_port,
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
    local base = type(opts) == "table" and opts or {}
    local app = { node = base.node, rpv = base.rpv, opts = base }
    function app:start()
        local runtime, err = M.setup_router(self.node, self.rpv, self.opts)
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
