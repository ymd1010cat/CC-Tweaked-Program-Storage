--[[- rpv/node.lua ? interfaces, routing, forwarding, event loop, timers, capture.]]
local M = ...
local int2ip, u16, u32, sub, byte = M.int2ip, M.u16, M.u32, M.sub, M.byte

-- The node log is written on every frame event, so a long session -- or a single
-- large file transfer, which is thousands of fragments -- keeps appending into a
-- computer whose whole disk is about 1 MB, and reading it back over a Minecraft
-- world file system is slow enough to time a worker out (both were measured: a
-- 200 KB rget/rput pair writes ~14.5 KB of log, and reading the file has timed out
-- while the transfer itself was fine). The live log is therefore capped: once it
-- passes log_max_bytes it rotates to "rpv-log.txt.1" (one generation, replaced each
-- time) and a fresh file is opened, so the live log always holds the most recent
-- activity and the directory stays bounded. 0 disables the cap.
--
-- Local change to the vendored stack, alongside the bounded pump(); see
-- rpv/MERGE-rpv.md.
local LOG_FILE = "rpv-log.txt"
local DEFAULT_LOG_MAX_BYTES = 131072

local function parse_cfg(path)
    local cfg, ifaces, fabric = {}, {}, nil
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    for line in f.readLine do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k == "iface" then
            local side, name, cidr, channel, mtu, linktype = v:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|?([^|]*)|?([^|]*)$")
            if side then ifaces[#ifaces + 1] = { side = side, name = name, cidr = cidr, channel = channel, mtu = tonumber(mtu) or 256, linktype = (linktype ~= "" and linktype) or "wired" } end
        elseif k == "fabric" then
            -- fabric=<side>|<channel>|<mtu>   (cluster backplane)
            local side, channel, mtu = v:match("^([^|]+)|([^|]+)|?([^|]*)$")
            if side then fabric = { side = side, channel = tonumber(channel), mtu = tonumber(mtu) or 1024 } end
        elseif k then
            cfg[k] = v
        end
    end
    f.close()
    return cfg, ifaces, fabric
end

-- channel namespace arbitration (M2): LAN channels, fabric broadcast/unicast and
-- rednet's reserved space (65533..65535 + the 0..65499 ID channels) must not
-- collide on the same modem, and a node should be able to see the whole plan.
function M.channel_audit(node)
    local conflicts = 0
    local lan = {}
    for _, i in ipairs(node.ifaces) do
        if not i.is_wan then lan[i.channel] = lan[i.channel] or i.side end
    end
    local parts = {}
    for ch, side in pairs(lan) do parts[#parts + 1] = string.format("%d(%s)", ch, side) end
    table.sort(parts)
    local f = node.fabric
    local f_bcast = f and f.channel or nil
    local f_ucast = f and f.ucast or nil
    node:log("CHANNEL_POLICY lan=[%s] fabric_bcast=%s fabric_ucast=%s rednet_reserved=65533-65535,0-65499",
        M.concat(parts, ","), tostring(f_bcast), tostring(f_ucast))
    if f_bcast and lan[f_bcast] then
        conflicts = conflicts + 1
        node:log("CHANNEL_CONFLICT fabric_bcast=%d collides with LAN iface on %s", f_bcast, lan[f_bcast])
    end
    if f_ucast and lan[f_ucast] then
        conflicts = conflicts + 1
        node:log("CHANNEL_CONFLICT fabric_ucast=%d collides with LAN iface on %s", f_ucast, lan[f_ucast])
    end
    if f and node.wan and f.side == node.wan.side then
        conflicts = conflicts + 1
        node:log("CHANNEL_CONFLICT fabric and rednet WAN share side=%s (ucast=%s would clash with ID channels)", f.side, tostring(f_ucast))
    end
    if f_ucast and f_ucast >= 65499 then
        conflicts = conflicts + 1
        node:log("CHANNEL_CONFLICT fabric_ucast=%d is inside rednet's ID/reserved range", f_ucast)
    end
    node:log("CHANNEL_AUDIT conflicts=%d", conflicts)
    return conflicts
end

-- fs.attributes throws (rather than returning nil) when the file is missing on
-- some implementations, so wrap it
local function mtime_of(path)
    if not (fs.attributes and fs.exists(path)) then return nil end
    local ok, attr = pcall(fs.attributes, path)
    return ok and attr and attr.modification or nil
end

function M.node_new(path)
    local n = {
        id = os.getComputerID(), mac = os.getComputerID(),
        role = "host", cfg = {}, ifaces = {}, by_side = {}, by_channel = {},
        routes = M.route_new(), arp = M.arp_new(), udp = M.udp_new(),
        reasm = M.reasm_new(16, 65536),
        fabric = nil, wan = nil, fabric_spec = nil, pmtu = {},
        -- Fragment pacing: opt-in, and defined here so the send path never has to
        -- test for nil. The config keys are read a few lines below.
        frag_pace = false, frag_pace_ms = 10, frag_queue = nil,
        timers = {}, ping_sent = {},
        stats = { frames_tx = 0, frames_rx = 0, bytes_tx = 0, bytes_rx = 0, ip_rx = 0, ip_bad = 0,
            fwd = 0, ttl_drop = 0, no_route = 0, frags = 0, reasm_drops = 0,
            icmp_replies = 0, icmp_time_exceeded = 0, icmp_unreachable = 0 },
        cap = {}, cap_max = 64, capture_on = false, ipid = 0,
        logfile = fs.open(LOG_FILE, "w"),
        log_bytes = 0, log_max_bytes = DEFAULT_LOG_MAX_BYTES, log_lines = 0,
        log_rotations = 0,
    }

    -- Append one line, rotating to a single kept generation when the live log has
    -- grown past log_max_bytes. The counter is kept in memory rather than asking
    -- fs.getSize() every line: the file is flushed on every write, and a stat per
    -- logged frame would cost more than the write.
    local function log_write(self, line)
        self.logfile.writeLine(line)
        self.logfile.flush()
        self.log_bytes = self.log_bytes + #line + 1
        self.log_lines = self.log_lines + 1
        local cap_bytes = tonumber(self.log_max_bytes) or 0
        if cap_bytes > 0 and self.log_bytes >= cap_bytes then
            -- Rotate: close, drop the previous generation, move the live file, reopen.
            -- Every step is guarded because a file system may refuse any of them, and a
            -- node that cannot rotate must still keep logging.
            pcall(function() self.logfile.close() end)
            pcall(function()
                if fs.exists(LOG_FILE .. ".1") then fs.delete(LOG_FILE .. ".1") end
                fs.move(LOG_FILE, LOG_FILE .. ".1")
            end)
            local fresh = fs.open(LOG_FILE, "w")
            self.logfile = fresh or self.logfile
            self.log_bytes = 0
            self.log_rotations = self.log_rotations + 1
            if fresh then
                fresh.writeLine(string.format("%.3f [%d/%s] LOG_ROTATED kept=%s cap=%d",
                    os.clock(), self.id, self.role, LOG_FILE .. ".1", cap_bytes))
                fresh.flush()
                self.log_bytes = #tostring(cap_bytes) + 48
            end
        end
    end

    function n:log(fmt, ...)
        local line = string.format("%.3f [%d/%s] ", os.clock(), self.id, self.role)
            .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
        log_write(self, line)
        print(line)
    end

    -- Reassembly budget. The stock 16 entries / 64 KB is sized for a few hosts on a
    -- quiet segment. A shell that streams a file in large chunks puts a whole
    -- datagram per chunk on the wire (4096 bytes at MTU 512 is thirteen fragments),
    -- and a burst that overruns the byte cap is dropped, which leaves the peer busy
    -- and silent until the fragments expire. Both limits are therefore configurable:
    -- reasm_bytes / reasm_entries in the node spec, rpv_reasm_bytes and
    -- rpv_reasm_entries in /etc/network.conf for the shell.
    --
    -- The values are read straight from the argument: the spec-table form below fills
    -- n.cfg only after this point, so n.cfg is not the place to look here. The file
    -- form keeps its settings in the parsed cfg, which is why both are consulted.
    do
        local src = path
        if type(src) ~= "table" then src = n.cfg end
        local rb = src and tonumber(src.reasm_bytes)
        local re = src and tonumber(src.reasm_entries)
        if rb or re then
            n.reasm = M.reasm_new(re or n.reasm.max_entries, rb or n.reasm.max_bytes)
            n:log("REASM_LIMITS entries=%d bytes=%d", n.reasm.max_entries, n.reasm.max_bytes)
        end
        -- Fragment pacing (see n:send_frags). Off unless asked for, so the emulator
        -- path keeps transmitting a whole datagram in one burst:
        --   frag_pace=1        pace the middle fragments of a datagram
        --   frag_pace_ms=10    delay between them
        local pace = src and tostring(src.frag_pace or "")
        n.frag_pace = (pace == "1" or pace == "on" or pace == "yes" or pace == "true")
        local pace_ms = src and tonumber(src.frag_pace_ms)
        if pace_ms then n.frag_pace_ms = pace_ms end
        -- Size cap of the live node log (see log_write). 0 turns the cap off; the
        -- shell reads rpv_log_max_bytes from /etc/network.conf for this.
        local cap_bytes = src and tonumber(src.log_max_bytes)
        if cap_bytes then n.log_max_bytes = cap_bytes end
    end

    function n:cap_push(dir, iface, dstmac, etype, frame)
        self.cap[#self.cap % self.cap_max + 1] = {
            t = os.clock(), dir = dir, iface = iface.name, len = #frame,
            dst = dstmac, etype = string.format("0x%04X", etype), frame = frame,
        }
    end

    function n:capture(count)
        local out, total, start = {}, #self.cap, math.max(1, #self.cap - (count or 8) + 1)
        for i = start, total do out[#out + 1] = self.cap[i] end
        return out
    end

    function n:next_ipid()
        self.ipid = self.ipid % 65535 + 1
        return self.ipid
    end

    function n:after(sec, fn)
        local t = os.startTimer(sec)
        self.timers[t] = fn
        return t
    end

    -- One step of a paced datagram: send the next fragment of every queued datagram,
    -- then arm the timer again while anything is left. Pacing is per datagram, not a
    -- global serialisation: fragments of different datagrams interleave, which is what
    -- a link would do anyway, and the receiver reassembles by (src, id) regardless of
    -- the order the fragments of different datagrams arrive in.
    function n:send_frag_step()
        local queue = self.frag_queue
        if not queue or #queue == 0 then
            self.frag_queue = nil
            return
        end
        local left = {}
        for i = 1, #queue do
            local item = queue[i]
            M.link_send(self, item.iface, item.mac, M.ET_IP, item.parts[item.next])
            item.next = item.next + 1
            if item.next <= #item.parts then
                left[#left + 1] = item
            else
                self.frag_done = (self.frag_done or 0) + 1
            end
        end
        self.frag_queue = #left > 0 and left or nil
        if self.frag_queue then
            self:after(self.frag_pace_ms / 1000, function() self:send_frag_step() end)
        end
    end

    -- periodic housekeeping: ARP retries/timeouts and reassembly expiry must run
    -- even when no app scheduled a timer of its own
    function n:tick()
        M.arp_tick(self)
        if M.reasm_expire(self.reasm) > 0 then self:log("REASM_EXPIRED some") end
        if self.fabric then M.fabric_tick(self, self.fabric) end
        if self.wan then M.wan_tick(self, self.wan) end
        -- hot reload of routes.txt / role.txt / hosts.txt (checked at most every 2 s)
        if fs.attributes and (self.route_check or 0) < os.clock() then
            self.route_check = os.clock() + 2
            if mtime_of("routes.txt") ~= self.routes_mtime then self:reload_routes("file change") end
            if mtime_of("role.txt") ~= self.cfg_mtime then self:reload_cfg("file change") end
            if M.hosts_load and mtime_of("hosts.txt") ~= self.hosts_mtime then
                M.hosts_load(self, "hosts.txt")
                self.hosts_mtime = mtime_of("hosts.txt")
                self:log("HOSTS_RELOADED path=hosts.txt (file change)")
            end
        end
        self:after(0.25, function() self:tick() end)
    end

    -- routes.txt lines:  <net>/<prefix> via <gw>   |   <net>/<prefix> dev <iface>
    function n:load_routes(path)
        path = path or "routes.txt"
        if not fs.exists(path) then return 0 end
        local keep = {}
        for _, r in ipairs(self.routes.entries) do
            if r.kind ~= "file" then keep[#keep + 1] = r end
        end
        self.routes.entries = keep
        local f = fs.open(path, "r")
        local added = 0
        for line in f.readLine do
            line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                local net, prefix, gw = line:match("^([%d%.]+)/(%d+)%s+via%s+([%d%.]+)$")
                local dev = line:match("^([%d%.]+)/(%d+)%s+dev%s+(%S+)$")
                if net and gw then
                    M.route_add(self.routes, tonumber(prefix), M.masked(M.ip2int(net), tonumber(prefix)), nil, M.ip2int(gw), "file")
                    added = added + 1
                elseif net and dev then
                    local iface
                    for _, i in ipairs(self.ifaces) do
                        if i.name == dev then iface = i end
                    end
                    M.route_add(self.routes, tonumber(prefix), M.masked(M.ip2int(net), tonumber(prefix)), iface, nil, "file")
                    added = added + 1
                else
                    self:log("ROUTES_BAD_LINE %s", line)
                end
            end
        end
        f.close()
        return added
    end

    function n:reload_routes(why)
        local count = self:load_routes()
        self.routes_mtime = mtime_of("routes.txt")
        self:log("ROUTES_RELOADED n=%d (%s)", count, tostring(why))
        return count
    end

    -- keys that cannot be applied to a running node: they change the interfaces, the
    -- WAN/fabric attachment, the app or the address configuration
    local RESTART_KEYS = {
        role = true, iface = true, wan = true, fabric = true, app = true, spawn = true,
        dhcp = true, dhcp_pool = true, nat_out = true, rpv_host = true,
    }

    -- hot reload of role.txt: safe keys are applied live (and logged), the rest are
    -- reported as needing a restart instead of being silently ignored
    function n:reload_cfg(why)
        self.cfg_mtime = mtime_of("role.txt")
        if not fs.exists("role.txt") then
            self:log("CFG_RELOAD_SKIP role.txt missing (%s)", tostring(why))
            return 0
        end
        local f = fs.open("role.txt", "r")
        local text = f.readAll()
        f.close()
        local changed, restart = {}, {}
        for line in tostring(text):gmatch("[^\r\n]+") do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then
                local old = self.cfg[k]
                if old ~= v then
                    if RESTART_KEYS[k] then
                        restart[#restart + 1] = k
                    else
                        self.cfg[k] = v
                        changed[#changed + 1] = string.format("%s=%s->%s", k, tostring(old), tostring(v))
                    end
                end
            end
        end
        self:log("CFG_RELOAD changed=%d restart_required=%d (%s)", #changed, #restart, tostring(why))
        for _, c in ipairs(changed) do self:log("CFG_CHANGED %s", c) end
        for _, k in ipairs(restart) do self:log("CFG_RELOAD_RESTART_REQUIRED key=%s", k) end
        -- apply the reload to already-running services (their loops re-read these)
        if self.dv then
            self.dv.interval = tonumber(self.cfg.dv_interval) or self.dv.interval
            self.dv.timeout = tonumber(self.cfg.dv_timeout) or self.dv.timeout
            self.dv.port = tonumber(self.cfg.dv_port) or self.dv.port
        end
        if self.qos then
            self.qos.budget = tonumber(self.cfg.qos_budget) or self.qos.budget
            self.qos.budget_bytes = tonumber(self.cfg.qos_budget_bytes) or self.qos.budget_bytes
            self.qos.max_queue = tonumber(self.cfg.qos_max_queue) or self.qos.max_queue
        end
        if self.mcast then
            self.mcast.rate = tonumber(self.cfg.mcast_rate) or self.mcast.rate
            self.mcast.bcast_rate = tonumber(self.cfg.bcast_rate) or self.mcast.bcast_rate
        end
        return #changed
    end

    function n:pick_src(dst)
        local path = self:resolve(dst)
        if path and path.iface then return path.iface.ip end
        return self.ifaces[1] and self.ifaces[1].ip or 0
    end

    -- route resolution: local routes, then cluster-fabric remote routes, then
    -- rednet WAN routes (longest prefix wins, locals win ties)
    function n:resolve(dst)
        local best = M.route_path(self.routes, dst)
        local bestprefix = best and (best.prefix or 0) or -1
        if self.fabric then
            for _, fr in ipairs(self.fabric.routes) do
                if M.masked(dst, fr.prefix) == fr.net and fr.prefix > bestprefix then
                    best = { fabric = self.fabric, member = fr.remote, idx = fr.idx, prefix = fr.prefix }
                    bestprefix = fr.prefix
                end
            end
        end
        if self.wan then
            for _, wr in pairs(self.wan.routes) do
                if M.masked(dst, wr.prefix) == wr.net and wr.prefix > bestprefix then
                    best = {
                        wan = self.wan, peer = wr.gw_id or self.wan.peers[wr.gw_ip], peer_ip = wr.gw_ip,
                        legacy = self.wan.legacy[wr.gw_ip] ~= nil, prefix = wr.prefix,
                    }
                    bestprefix = wr.prefix
                end
            end
        end
        return best
    end

    function n:bind(port, cb) return M.udp_bind(self, port, cb) end

    function n:setup()
        self.role = self.cfg.role or "host"
        self.echo_icmp = self.cfg.echo_icmp ~= "0"
        self.icmp_port_unreachable = self.cfg.icmp_port_unreachable == "1"
        self.capture_on = self.cfg.capture == "1"

        for _, spec in ipairs(self.iface_specs) do
            local ipstr, prefix = spec.cidr:match("^([%d%.]+)/(%d+)$")
            if not ipstr then error("bad iface cidr: " .. tostring(spec.cidr)) end
            local is_wan = (tostring(spec.channel) == "rednet") or (spec.linktype == "rednet")
            local iface = {
                side = spec.side, name = spec.name,
                channel = is_wan and "wan" or (tonumber(spec.channel) or 0),
                mtu = spec.mtu, is_wan = is_wan,
                linktype = is_wan and "rednet" or spec.linktype,
                ip = M.ip2int(ipstr), prefix = tonumber(prefix), cidr = spec.cidr,
            }
            iface.net = M.masked(iface.ip, iface.prefix)
            iface.wireless = false
            self.ifaces[#self.ifaces + 1] = iface
            self.by_side[spec.side] = iface
            if is_wan then
                if self.wan then self:log("WAN_DUPLICATE side=%s (WAN already on %s)", spec.side, self.wan.side) end
                self.wan = M.wan_new(spec.side, spec.mtu)
                self.wan.iface = iface
            else
                self.by_channel[iface.channel] = iface
            end
            M.route_connected(self.routes, iface)
        end

        -- IPv4 loopback semantics: every node owns 127.0.0.0/8. `lo` is deliberately kept
        -- OUT of self.ifaces (no modem, no channel, never announced by DV, never a
        -- broadcast target) but it does get a connected route, so 127.x resolves locally
        -- and is delivered through ip_input without ever touching a modem.
        self.lo = { side = "lo", name = "lo", channel = "lo", loopback = true, mtu = 65535,
                    ip = M.ip2int("127.0.0.1"), prefix = 8, net = M.ip2int("127.0.0.0"),
                    cidr = "127.0.0.1/8", linktype = "loopback", wireless = false }
        self.by_side["lo"] = self.lo
        M.route_connected(self.routes, self.lo)

        if self.cfg.gw then M.route_default(self.routes, M.ip2int(self.cfg.gw)) end

        -- ---- configuration validation (M4) ----
        local warns, seen_ch, seen_side, seen_name = 0, {}, {}, {}
        local function cfgwarn(fmt, ...)
            warns = warns + 1
            self:log("CFG_WARN " .. string.format(fmt, ...))
        end
        for _, iface in ipairs(self.ifaces) do
            if seen_side[iface.side] then cfgwarn("duplicate side=%s", iface.side) end
            seen_side[iface.side] = true
            if seen_name[iface.name] then cfgwarn("duplicate interface name=%s", iface.name) end
            seen_name[iface.name] = true
            if seen_ch[iface.channel] then
                cfgwarn("duplicate channel=%d on %s and %s", iface.channel, seen_ch[iface.channel], iface.side)
            else
                seen_ch[iface.channel] = iface.side
            end
            if iface.channel == 65533 or iface.channel == 65534 or iface.channel == 65535 then
                cfgwarn("channel=%d on %s is reserved by rednet/GPS", iface.channel, iface.name)
            end
            if iface.mtu < 68 then cfgwarn("mtu=%d on %s is below the IPv4 minimum (68)", iface.mtu, iface.name) end
            if iface.prefix < 8 then cfgwarn("prefix /%d on %s is very broad", iface.prefix, iface.name) end
        end
        for i = 1, #self.ifaces do
            for j = i + 1, #self.ifaces do
                local a, b = self.ifaces[i], self.ifaces[j]
                if M.masked(a.net, b.prefix) == b.net or M.masked(b.net, a.prefix) == a.net then
                    cfgwarn("overlapping subnets %s and %s", a.cidr, b.cidr)
                end
            end
        end
        if not self.cfg.gw and self.role == "host" and #self.ifaces > 0 then
            self:log("CFG_NOTE host without a default gateway (local subnet only)")
        end
        self:log("CFG_SUMMARY warnings=%d", warns)

        -- runtime API self-check (compat.lua): reported before the network is set up
        if M.compat_setup then M.compat_setup(self) end

        if periphemu then
            -- emulator-only: attach the modem blocks. The kind can be requested per side
            -- (modem_<side>=modem|wired_modem_full) or for the WAN (wan_modem=...); the
            -- default is the plain wireless "modem". Wired and wireless modems are both
            -- accepted everywhere -- they report peripheral type "modem" and the library
            -- never assumes wireless (see the LINK / WAN_READY lines).
            for _, iface in ipairs(self.ifaces) do
                if peripheral.getType(iface.side) ~= "modem" then
                    local kind = self.cfg["modem_" .. tostring(iface.side)]
                        or (iface.is_wan and self.cfg.wan_modem) or "modem"
                    local ok, err = periphemu.create(iface.side, kind)
                    if not ok then self:log("MODEM_ATTACH_FAIL side=%s kind=%s err=%s", iface.side, tostring(kind), tostring(err)) end
                    if peripheral.getType(iface.side) ~= "modem" then
                        self:log("MODEM_ATTACH_MISSING side=%s kind=%s (emulator cannot provide it)", iface.side, tostring(kind))
                    else
                        self:log("MODEM_ATTACH side=%s kind=%s type=modem", iface.side, tostring(kind))
                    end
                end
            end
            if self.fabric_spec and peripheral.getType(self.fabric_spec.side) ~= "modem" then
                local ok, err = periphemu.create(self.fabric_spec.side, "modem")
                if not ok then self:log("MODEM_ATTACH_FAIL side=%s err=%s", self.fabric_spec.side, tostring(err)) end
            end
        end
        local addrWarns = 0
        for _, iface in ipairs(self.ifaces) do
            if iface.is_wan then
                M.wan_setup(self, self.wan, iface.cidr)
            elseif peripheral.getType(iface.side) == "modem" then
                M.link_open(iface)
                local ok, isw = pcall(peripheral.call, iface.side, "isWireless")
                iface.wireless = ok and isw or false
                local declared = iface.linktype
                -- no special-casing of any modem variant here: linktype is just a
                -- free-form label, and ender/infinite-range modems are used only as
                -- a bridge by a separate program (see poc/mc/ender-bridge.lua)
                if declared == "wireless" and not iface.wireless then
                    self:log("LINKTYPE_WARN side=%s declared=wireless reported=wired", iface.side)
                elseif declared == "wired" and iface.wireless then
                    self:log("LINKTYPE_WARN side=%s declared=wired reported=wireless", iface.side)
                else
                    local ptype = peripheral.getType(iface.side)
                    local pwireless = nil
                    if ptype == "modem" then
                        local okw, w = pcall(peripheral.call, iface.side, "isWireless")
                        pwireless = okw and w or nil
                    end
                    self:log("LINK side=%s type=%s wireless=%s ok peripheral=%s phys_wireless=%s",
                        iface.side, declared, tostring(iface.wireless), tostring(ptype), tostring(pwireless))
                end
                if iface.channel and iface.channel >= 65499 then
                    self:log("CHANNEL_WARN side=%s ch=%d collides with rednet's reserved range", iface.side, iface.channel)
                end
                self:log("IFACE side=%s name=%s addr=%s ch=%d mtu=%d", iface.side, iface.name, iface.cidr, iface.channel, iface.mtu)
                -- IPv4 address semantics: classify the address and warn about reserved,
                -- network/broadcast or non-private assignments on a LAN interface
                self:log("IFACE_CLASS side=%s name=%s addr=%s class=%s private=%s",
                    iface.side, iface.name, iface.cidr, M.ip_class(iface.ip), tostring(M.ip_is_private(iface.ip)))
                for _, warn in ipairs(M.ip_iface_warnings(iface)) do
                    self:log("CFG_WARN %s side=%s addr=%s (%s)", warn.code, iface.side, tostring(iface.cidr), warn.detail)
                    addrWarns = addrWarns + 1
                end
            else
                self:log("IFACE_NO_MODEM side=%s", iface.side)
            end
        end
        self:log("ADDR_WARN_SUMMARY warnings=%d loopback=%s class_private=%s", addrWarns, M.int2ip(self.lo.ip), tostring(#self.ifaces > 0 and M.ip_is_private(self.ifaces[1].ip)))
        self:log("NODE id=%d mac=%d role=%s ifaces=%d routes=%d version=%s", self.id, self.mac, self.role, #self.ifaces, #self.routes.entries, M.RPV_VERSION or "?")
        self:after(0.25, function() self:tick() end)

        -- rednet WAN: static map of plain rednet devices (id -> rpv ip)
        if self.cfg.map then
            if self.wan then
                for entry in self.cfg.map:gmatch("[^,]+") do
                    local id, ip = entry:match("^(%d+):([%d%.]+)$")
                    if id and ip then
                        local nid, nip = tonumber(id), M.ip2int(ip)
                        self.wan.legacy[nip] = nid
                        self.wan.peers[nip] = nid
                        self:log("WAN_LEGACY_MAP rednet_id=%d rpv_ip=%s", nid, ip)
                    end
                end
            else
                self:log("WAN_MAP_IGNORED (no rednet WAN interface declared)")
            end
        end

        -- cluster fabric
        if self.fabric_spec then
            self.fabric = M.fabric_new(self.fabric_spec.side, self.fabric_spec.channel, self.fabric_spec.mtu)
            if M.fabric_setup(self, self.fabric) then
                self:after(0.3, function() M.fabric_announce_loop(self, self.fabric) end)
            end
        end

        -- static routes from routes.txt (hot reloadable)
        if fs.exists("routes.txt") then self:reload_routes("boot") end

        -- remember the config/hosts timestamps so the watcher only reports real changes
        self.cfg_mtime = mtime_of("role.txt")
        self.hosts_mtime = mtime_of("hosts.txt")

        -- channel namespace arbitration: LAN channels vs fabric vs rednet space
        M.channel_audit(self)

        if self.cfg.spawn and ccemux then
            -- CraftOS-PC races when several emulators are opened back to back (they
            -- fight over reading the BIOS file), so space them out and retry a failed
            -- open. Use node timers, NOT os.sleep: os.sleep pulls and discards events,
            -- which would swallow the `after` timers scheduled above.
            local i = 0
            for id in self.cfg.spawn:gmatch("%d+") do
                local target = tonumber(id)
                local function open(try)
                    local ok, res = pcall(ccemux.openEmu, target)
                    self:log("SPAWN id=%s ok=%s res=%s try=%d", tostring(target), tostring(ok), tostring(res), try)
                    if not ok and try < 3 then
                        self:after(1.0 * try, function() open(try + 1) end)
                    end
                end
                self:after(i * 0.5, function() open(1) end)
                i = i + 1
            end
        end
        if self.cfg.stats_at then
            self:after(tonumber(self.cfg.stats_at), function() self:dump_stats() end)
        end

        -- DHCP-lite / lookup-lite (services.lua): driven entirely by config keys.
        -- Guarded: a service misconfiguration must never take the node's boot down.
        if M.services_setup then
            local ok, err = pcall(M.services_setup, self)
            if not ok then self:log("SERVICES_ERROR %s", tostring(err)) end
        end

        -- dynamic routing (dv.lua): opt-in with dv=1
        if self.cfg.dv == "1" and M.dv_setup then
            local ok, err = pcall(M.dv_setup, self)
            if not ok then self:log("DV_ERROR %s", tostring(err)) end
        end

        -- NAT-lite (nat.lua) and multicast domains (mcast.lua): opt-in, guarded
        if self.cfg.nat == "1" and M.nat_setup then
            local ok, err = pcall(M.nat_setup, self)
            if not ok then self:log("NAT_ERROR %s", tostring(err)) end
        end
        if self.cfg.mcast == "1" and M.mcast_setup then
            local ok, err = pcall(M.mcast_setup, self)
            if not ok then self:log("MCAST_ERROR %s", tostring(err)) end
        end

        -- QoS egress queues (qos.lua): opt-in with qos=1
        if self.cfg.qos == "1" and M.qos_setup then
            local ok, err = pcall(M.qos_setup, self)
            if not ok then self:log("QOS_ERROR %s", tostring(err)) end
        end

        -- topology discovery / network map (topo.lua): opt-in
        if (self.cfg.topo == "1" or self.cfg.topo_collect == "1") and M.topo_setup then
            local ok, err = pcall(M.topo_setup, self)
            if not ok then self:log("TOPO_ERROR %s", tostring(err)) end
        end
    end

    -- name registry conveniences (see rpv/services.lua)
    function n:dns_register(name) return M.dns_register and M.dns_register(self, name) end
    function n:lookup(name, timeout, cb) return M.lookup and M.lookup(self, name, timeout, cb) end

    function n:dump_stats()        local s = self.stats
        self:log("STATS fwd=%d ttl_drop=%d no_route=%d ip_rx=%d ip_bad=%d frags=%d reasm_drops=%d tx=%d rx=%d",
            s.fwd, s.ttl_drop, s.no_route, s.ip_rx, s.ip_bad, s.frags, s.reasm_drops, s.frames_tx, s.frames_rx)
        local a = self.arp
        self:log("ARP_STATS cache=%d pending=%d requests=%d hits=%d timeouts=%d", (function()
            local c = 0 for _ in pairs(a.cache) do c = c + 1 end return c end)(), (function()
            local c = 0 for _ in pairs(a.pending) do c = c + 1 end return c end)(), a.requests, a.hits, a.timeouts)
        local ports = {}
        for p in pairs(self.udp.ports) do ports[#ports + 1] = p end
        table.sort(ports)
        self:log("UDP_STATS tx=%d rx=%d dropped=%d bad_cksum=%d ports=%s", self.udp.tx, self.udp.rx, self.udp.dropped, self.udp.bad_cksum,
            M.concat(ports, ","))
        if self.fabric then
            local peers = 0
            for _ in pairs(self.fabric.peers) do peers = peers + 1 end
            self:log("FABRIC_STATS fwd=%d recv=%d peers=%d routes=%d announces=%d",
                self.stats.fabric_fwd or 0, self.stats.fabric_recv or 0, peers, #self.fabric.routes, self.fabric.announces or 0)
        end
        if self.wan then
            local routes, peers = 0, 0
            for _ in pairs(self.wan.routes) do routes = routes + 1 end
            for _ in pairs(self.wan.peers) do peers = peers + 1 end
            self:log("WAN_STATS sent=%d recv=%d no_peer=%d legacy_tx=%d legacy_rx=%d peers=%d routes=%d adverts=%d stale=%d",
                self.stats.wan_sent or 0, self.stats.wan_recv or 0, self.stats.wan_no_peer or 0,
                self.wan.legacy_tx, self.wan.legacy_rx, peers, routes, self.wan.advert, self.stats.wan_advert_stale or 0)
        end
        local pm = {}
        for dst, e in pairs(self.pmtu or {}) do
            pm[#pm + 1] = string.format("%s=%s", int2ip(dst), tostring(e.mtu))
        end
        table.sort(pm)
        self:log("PMTU_STATS updates=%d entries=%s", self.stats.pmtu_updates or 0, M.concat(pm, ","))
    end

    function n:send_ip(dst, proto, payload, ttl, src, df)
        ttl = ttl or 64
        if df == nil then df = (self.cfg.df == "1") end
        if dst == M.IP_BCAST then return self:send_broadcast(proto, payload, ttl) end
        -- IPv4 loopback: 127.x is delivered through the receive path and never reaches a
        -- modem (the source is our loopback address, exactly like a real loopback iface)
        if self.lo and M.masked(dst, self.lo.prefix) == self.lo.net then
            self.stats.lo_sent = (self.stats.lo_sent or 0) + 1
            return self:ip_deliver(self.lo, { ttl = ttl, proto = proto, src = self.lo.ip, dst = dst, id = 0, ihl = 20 }, payload)
        end
        for _, iface in ipairs(self.ifaces) do
            if iface.ip == dst then
                return self:ip_deliver(iface, { ttl = ttl, proto = proto, src = dst, dst = dst, id = 0, ihl = 20 }, payload)
            end
            -- directed broadcast (the subnet all-ones address): one frame on that subnet
            -- only, with the L2 broadcast MAC and the directed address as the IP dst
            if M.ip_is_directed_broadcast(dst, iface) then
                M.link_send(self, iface, M.MAC_BCAST, M.ET_IP,
                    M.ip_build(iface.ip, dst, proto, ttl or 64, self:next_ipid(), false, 0, payload))
                self.stats.broadcasts = (self.stats.broadcasts or 0) + 1
                self.stats.directed_bcast = (self.stats.directed_bcast or 0) + 1
                return true
            end
        end
        -- invalid destinations must not be put on the wire at all. Note this is NOT the
        -- forwarding rule: link local / multicast / doc-benchmark addresses are fine to
        -- send (they are only never routed onward by a router).
        if not M.ip_transmittable(dst) then
            self.stats.reserved_drop = (self.stats.reserved_drop or 0) + 1
            self:log("RESERVED_TX_DROP dst=%s class=%s", int2ip(dst), M.ip_class(dst))
            return false
        end
        local path = self:resolve(dst)
        if not path then
            self.stats.no_route = self.stats.no_route + 1
            self:log("NO_ROUTE dst=%s", int2ip(dst))
            return false
        end
        local src_ip = src
        if not src_ip then
            if path.iface then src_ip = path.iface.ip
            elseif path.wan and self.wan then src_ip = self.wan.iface.ip
            else src_ip = self.ifaces[1] and self.ifaces[1].ip or 0 end
        end
        return self:send_via_path(path, src_ip, dst, proto, ttl, payload, df)
    end

    -- path MTU learned from ICMP frag-needed, capped by the egress interface
    function n:effective_mtu(iface, dst)
        local pm = self.pmtu and self.pmtu[dst]
        if pm and pm.expires > os.clock() and pm.mtu and pm.mtu < iface.mtu then return pm.mtu end
        return iface.mtu
    end

    -- limited broadcast: one frame per interface, no ARP (stays on the subnet,
    -- exactly like IPv4 255.255.255.255). WAN/fabric interfaces are skipped:
    -- rednet broadcast is the shim's business, not the IP layer's.
    function n:send_broadcast(proto, payload, ttl)
        local n_if = 0
        for _, iface in ipairs(self.ifaces) do
            if not iface.is_wan and not iface.is_fabric then
                M.link_send(self, iface, M.MAC_BCAST, M.ET_IP,
                    M.ip_build(iface.ip, M.IP_BCAST, proto, ttl or 64, self:next_ipid(), false, 0, payload))
                n_if = n_if + 1
            end
        end
        self.stats.broadcasts = (self.stats.broadcasts or 0) + n_if
        return n_if > 0
    end

    -- transmit out of one local interface (ARP + fragmentation, honouring DF)
    function n:send_local(iface, next_hop, src, dst, proto, ttl, payload, df)
        M.arp_resolve(self, iface, next_hop, function(mac, err)
            if not mac then
                self:log("SEND_FAIL dst=%s next_hop=%s arp=%s", int2ip(dst), int2ip(next_hop), tostring(err))
                return
            end
            local id = self:next_ipid()
            local mtu = self:effective_mtu(iface, dst)
            local maxpay = M.ip_max_payload(mtu)
            if #payload <= maxpay then
                M.link_send(self, iface, mac, M.ET_IP, M.ip_build(src, dst, proto, ttl, id, false, 0, payload, df))
            elseif df then
                -- can't fragment and the sender asked us not to: RFC 1191 error
                self.stats.pmtu_needed = (self.stats.pmtu_needed or 0) + 1
                local local_src = false
                for _, i in ipairs(self.ifaces) do
                    if i.ip == src then local_src = true end
                end
                if local_src then
                    -- our own packet: report locally instead of ICMP-ing ourselves
                    self.pmtu[dst] = { mtu = mtu, expires = os.clock() + 300, source = "local" }
                    self.stats.pmtu_updates = (self.stats.pmtu_updates or 0) + 1
                    self:log("PMTU_LOCAL dst=%s mtu=%d bytes=%d (egress too small, DF set)", int2ip(dst), mtu, #payload)
                    if self.on_icmp_error then self.on_icmp_error(src, 3, 4, nil, nil, mtu) end
                else
                    self:log("PMTU_NEEDED dst=%s mtu=%d bytes=%d (DF set, ICMP sent)", int2ip(dst), mtu, #payload)
                    M.icmp_frag_needed(self, iface, { src = src, dst = dst, proto = proto, ttl = ttl, id = id }, payload, mtu)
                end
            else
                local count = 0
                local parts = {}
                for off = 0, #payload - 1, maxpay do
                    local chunk = sub(payload, off + 1, math.min(off + maxpay, #payload))
                    local mf = (off + #chunk) < #payload
                    parts[#parts + 1] = M.ip_build(src, dst, proto, ttl, id, mf, off / 8, chunk, false)
                end
                count = #parts
                if self.frag_pace and count > 2 then
                    -- Paced: the first fragment goes now and the rest follow on a
                    -- timer. A real modem that is handed a whole datagram in one loop
                    -- drops most of it (measured: 144 FRAGMENTED, 0 REASSEMBLED), and
                    -- this is the knob that spreads the burst. The first fragment is
                    -- sent here rather than on the timer so that a caller which never
                    -- runs the event loop still puts something on the wire.
                    M.link_send(self, iface, mac, M.ET_IP, parts[1])
                    self.frag_queue = self.frag_queue or {}
                    self.frag_queue[#self.frag_queue + 1] = {
                        iface = iface, mac = mac, parts = parts, next = 2, id = id,
                    }
                    self.frag_sent = (self.frag_sent or 0) + 1
                    self:after(self.frag_pace_ms / 1000, function() self:send_frag_step() end)
                    self:log("FRAG_PACED id=%d bytes=%d frags=%d mtu=%d gap=%dms out=%s",
                             id, #payload, count, mtu, self.frag_pace_ms, iface.name)
                else
                    for i = 1, count do
                        M.link_send(self, iface, mac, M.ET_IP, parts[i])
                    end
                end
                self.stats.frags = self.stats.frags + count
                if not self.frag_pace or count <= 2 then
                    self:log("FRAGMENTED id=%d bytes=%d frags=%d mtu=%d out=%s", id, #payload, count, mtu, iface.name)
                end
            end
        end)
        return true
    end

    function n:send_via_path(path, src, dst, proto, ttl, payload, df)
        -- trace=1: one line per packet emitted, so a multi-hop path can be followed
        -- host -> first router -> ... -> destination (used by the grid debugging)
        if self.cfg.trace == "1" then
            local egress = path.fabric and ("fabric" .. tostring(path.member))
                or path.wan and ("wan:peer" .. tostring(path.peer))
                or path.iface and path.iface.is_wan and ("wan:" .. M.int2ip(path.next_hop or 0))
                or ("local:" .. tostring(path.iface and path.iface.name))
            self:log("IP_TX src=%s dst=%s proto=%d ttl=%d bytes=%d out=%s nh=%s",
                M.int2ip(src), M.int2ip(dst), proto, ttl, #payload, egress, M.int2ip(path.next_hop or 0))
        end
        if path.fabric then
            return M.fabric_forward(self, path.fabric, path.member, path.idx, src, dst, proto, ttl, payload)
        end
        if path.wan then
            return M.wan_send(self, path.wan, path, src, dst, proto, ttl, payload)
        end
        if path.iface and path.iface.is_wan then
            -- directly connected WAN peer: resolve its rednet id from the peer table
            local w = self.wan
            local peer_ip = path.next_hop
            return M.wan_send(self, w, {
                peer = w.peers[peer_ip], peer_ip = peer_ip, legacy = w.legacy[peer_ip] ~= nil,
            }, src, dst, proto, ttl, payload)
        end
        return self:send_local(path.iface, path.next_hop, src, dst, proto, ttl, payload, df)
    end

    function n:ip_input(iface, pkt)
        local h = M.ip_parse(pkt)
        if not h then
            self.stats.ip_bad = self.stats.ip_bad + 1
            return
        end
        if self.cfg.trace == "1" then
            self:log("IP_RX src=%s dst=%s proto=%d ttl=%d bytes=%d on=%s",
                M.int2ip(h.src), M.int2ip(h.dst), h.proto, h.ttl, #pkt, tostring(iface and iface.name))
        end
        -- IPv4 reserved-segment rules for anything that came off a modem: loopback and
        -- this-network addresses are never valid on the wire, so a forged packet carrying
        -- them is dropped (and counted) instead of being delivered or forwarded
        if not (iface and iface.loopback) then
            if M.ip_is_loopback(h.dst) or M.ip_is_loopback(h.src) or M.ip_is_unspecified(h.dst) then
                self.stats.reserved_drop = (self.stats.reserved_drop or 0) + 1
                self:log("RESERVED_DROP src=%s dst=%s class=%s on=%s", M.int2ip(h.src), M.int2ip(h.dst),
                    M.ip_class(M.ip_is_loopback(h.dst) and h.dst or h.src), tostring(iface and iface.name))
                return
            end
        end
        self.stats.ip_rx = self.stats.ip_rx + 1
        local payload = sub(pkt, h.ihl + 1, h.total)
        if h.mf or h.offset8 > 0 then
            local full, err = M.reasm_push(self.reasm, h, payload)
            if not full then
                if err then
                    self.stats.reasm_drops = self.stats.reasm_drops + 1
                    self:log("REASM_DROP %s", err)
                end
                return
            end
            self:log("REASSEMBLED id=%d bytes=%d", h.id, #full)
            payload = full
        end
        return self:ip_deliver(iface, h, payload)
    end

    function n:ip_deliver(iface, h, payload)
        -- multicast groups + broadcast/multicast domain control (mcast.lua)
        local mc_local = false
        if M.mcast_input_hook then
            local action, egress = M.mcast_input_hook(self, iface, h, payload)
            if action == "drop" then return end
            if action == "forward" and egress then
                local sent = 0
                for _, name in ipairs(egress) do
                    for _, i in ipairs(self.ifaces) do
                        if i.name == name then
                            M.link_send(self, i, M.MAC_BCAST, M.ET_IP,
                                M.ip_build(h.src, h.dst, h.proto, h.ttl - 1, self:next_ipid(), false, 0, payload))
                            sent = sent + 1
                        end
                    end
                end
                return sent > 0
            end
            if action == "local" then mc_local = true end
        end
        -- NAT-lite (nat.lua): translate before local delivery or forwarding. "drop"
        -- discards, "forward" hands the rewritten packet to an internal host,
        -- "rewrite" lets the normal forwarding path carry the translated packet.
        if M.nat_input_hook then
            local action, ns, nd, np = M.nat_input_hook(self, iface, h, payload)
            if action == "drop" then return end
            if action == "forward" then
                local npath = self:resolve(nd)
                if npath then return self:send_via_path(npath, ns, nd, h.proto, h.ttl - 1, np, h.df) end
                self.stats.no_route = self.stats.no_route + 1
                self:log("NO_ROUTE_NAT dst=%s", int2ip(nd))
                return
            end
            if action == "rewrite" then
                h.src, h.dst, payload = ns, nd, np
            end
        end
        -- local delivery must consider EVERY local address, not just the ingress
        -- interface's (multi-homed nodes: router receiving on LAN-B a packet for
        -- its LAN-A address is still "for me")
        local owner = nil
        if h.dst == M.IP_BCAST or mc_local then
            owner = iface
        else
            for _, i in ipairs(self.ifaces) do
                if i.ip == h.dst then owner = i end
            end
            if not owner and self.lo and self.lo.ip == h.dst then owner = self.lo end
        end
        -- a directed broadcast for a subnet we are attached to is delivered here (like a
        -- limited broadcast); it is never relayed to another subnet
        if not owner and iface and M.ip_is_directed_broadcast(h.dst, iface) then
            self.stats.directed_bcast = (self.stats.directed_bcast or 0) + 1
            if h.proto == M.IP_ICMP then return M.icmp_input(self, iface, h, payload) end
            if h.proto == M.IP_UDP then return M.udp_input(self, iface, h, payload) end
            return
        end
        if owner then
            if h.proto == M.IP_ICMP then return M.icmp_input(self, owner, h, payload) end
            if h.proto == M.IP_UDP then return M.udp_input(self, owner, h, payload) end
            self:log("LOCAL_PROTO_%d", h.proto)
            return
        end
        if self.role ~= "router" then
            self:log("NOT_MINE dst=%s", int2ip(h.dst))
            return
        end
        -- routers never forward a directed broadcast (that is a smurf amplifier): the
        -- packet is only valid on the subnet it belongs to
        for _, i in ipairs(self.ifaces) do
            if M.ip_is_directed_broadcast(h.dst, i) then
                self.stats.directed_bcast_drop = (self.stats.directed_bcast_drop or 0) + 1
                self:log("DIRECTED_BCAST_DROP dst=%s (not forwarded)", int2ip(h.dst))
                return
            end
        end
        -- reserved destinations are never routed (link local, doc/benchmark blocks,
        -- 240/4, multicast that no local group took)
        if not M.ip_forwardable(h.dst) then
            self.stats.reserved_drop = (self.stats.reserved_drop or 0) + 1
            self:log("RESERVED_DROP src=%s dst=%s class=%s (not forwarded)", int2ip(h.src), int2ip(h.dst), M.ip_class(h.dst))
            M.icmp_error(self, iface, h, payload, 3, 0)
            return
        end
        if h.ttl <= 1 then
            self.stats.ttl_drop = self.stats.ttl_drop + 1
            self:log("TTL_DROP dst=%s src=%s", int2ip(h.dst), int2ip(h.src))
            if h.proto ~= M.IP_ICMP or byte(payload, 1) ~= 11 then M.icmp_error(self, iface, h, payload, 11, 0) end
            return
        end
        local path = self:resolve(h.dst)
        if not path then
            self.stats.no_route = self.stats.no_route + 1
            self:log("NO_ROUTE_FWD dst=%s", int2ip(h.dst))
            M.icmp_error(self, iface, h, payload, 3, 0)
            return
        end
        self.stats.fwd = self.stats.fwd + 1
        local egress
        if path.fabric then egress = "fabric:member" .. tostring(path.member)
        elseif path.wan then egress = "wan:peer" .. tostring(path.peer) .. (path.legacy and "(legacy)" or "")
        else egress = "local:" .. (path.iface and path.iface.name or "?") end
        self:log("FWD src=%s dst=%s proto=%d ttl=%d bytes=%d out=%s", int2ip(h.src), int2ip(h.dst), h.proto, h.ttl - 1, #payload, egress)
        return self:send_via_path(path, h.src, h.dst, h.proto, h.ttl - 1, payload, h.df)
    end

    function n:on_frame(iface, frame)
        local dstmac, srcmac, etype, body = M.link_parse(frame)
        if not dstmac then return end
        if dstmac ~= self.mac and dstmac ~= M.MAC_BCAST then return end
        self.stats.frames_rx = self.stats.frames_rx + 1
        self.stats.bytes_rx = self.stats.bytes_rx + #frame
        if self.capture_on then self:cap_push("rx", iface, dstmac, etype, frame) end
        if etype == M.ET_FABRIC and self.fabric then return M.fabric_input(self, self.fabric, body, srcmac) end
        if etype == M.ET_ARP then return M.arp_input(self, iface, body) end
        if etype == M.ET_IP then return self:ip_input(iface, body) end
        self:log("DROP_ETHERTYPE 0x%04X", etype)
    end

    -- one already-received event (shared by run() and the bounded pump)
    function n:pump_event(ev, p1, p2, p3, p4, p5)
        if ev == "modem_message" then
            local iface = self.by_channel[p2]
            if iface then
                local ok, err = pcall(self.on_frame, self, iface, p4)
                if not ok then self:log("FRAME_ERROR %s", tostring(err)) end
            end
        elseif ev == "rednet_message" then
            if self.wan then
                local ok, err = pcall(M.wan_input, self, self.wan, p1, p2, p3)
                if not ok then self:log("WAN_ERROR %s", tostring(err)) end
            end
        elseif ev == "timer" then
            local fn = self.timers[p1]
            if fn then
                self.timers[p1] = nil
                local ok, err = pcall(fn)
                if not ok then self:log("TIMER_ERROR %s", tostring(err)) end
            end
            M.arp_tick(self)
            if M.reasm_expire(self.reasm) > 0 then self:log("REASM_EXPIRED some") end
        end
        -- hand the event to coroutine tasks (blocking-style apps, rednet shim)
        self:dispatch_event(ev, p1, p2, p3, p4, p5)
    end

    function n:run()
        while true do
            -- modem_message carries 5 params (side, channel, reply, message, distance)
            self:pump_event(os.pullEvent())
        end
    end

    -- bounded pump for a single threaded host (unixshell integration): drive the node
    -- for about `seconds` and return, so a shell command can let the stack make
    -- progress without handing the process over to run(). A timer is armed for the
    -- remaining time each pass, so the loop cannot wait longer than asked for.
    function n:pump(seconds)
        local deadline = os.clock() + (tonumber(seconds) or 0)
        while os.clock() < deadline do
            os.startTimer(math.max(0.02, deadline - os.clock()))
            self:pump_event(os.pullEvent())
        end
        return true
    end

    -- ===== coroutine task scheduler =====
    -- Tasks yield a filter string (that is what os.pullEvent does inside a
    -- coroutine), so `os.sleep` / `os.pullEvent` / the rednet shim's blocking
    -- receive all work inside a task.
    n.tasks = {}

    function n:add_task(name, fn)
        local t = { name = name or "task", co = coroutine.create(fn), filter = nil }
        self.tasks[#self.tasks + 1] = t
        self:log("TASK_START name=%s", t.name)
        self:resume_task(t)
        return t
    end

    function n:resume_task(t, ...)
        if t.dead or coroutine.status(t.co) == "dead" then
            t.dead = true
            return
        end
        local ok, y = coroutine.resume(t.co, ...)
        if not ok then
            t.dead = true
            self:log("TASK_ERROR name=%s err=%s", t.name, tostring(y))
            return
        end
        if coroutine.status(t.co) == "dead" then
            t.dead = true
            self:log("TASK_DONE name=%s", t.name)
            return
        end
        t.filter = y -- nil means "any event"
    end

    function n:has_waiter(filter)
        for _, t in ipairs(self.tasks) do
            if not t.dead and (t.filter == nil or t.filter == filter) then return true end
        end
        return false
    end

    function n:dispatch_event(ev, ...)
        for _, t in ipairs(self.tasks) do
            if not t.dead and (t.filter == nil or t.filter == ev) then
                t.filter = nil
                self:resume_task(t, ev, ...)
            end
        end
    end

    -- inject a synthetic event (used by the rednet shim for incoming messages)
    function n:emit_event(ev, ...)
        self:dispatch_event(ev, ...)
    end

    -- two accepted forms, so external programs can use the library without any
    -- config files:
    --   rpv.node_new("role.txt")                     -- classic file form
    --   rpv.node_new({ role="host", ifaces={...}, routes={...}, gw="10.0.1.1" })
    if type(path) == "table" then
        local spec = path
        local cfg, ifaces, fabric = {}, {}, nil
        for k, v in pairs(spec) do
            if k == "ifaces" then
                for _, i in ipairs(v) do
                    ifaces[#ifaces + 1] = {
                        side = i.side, name = i.name or i.side, cidr = i.cidr,
                        channel = i.channel, mtu = tonumber(i.mtu) or 256,
                        linktype = i.linktype,                    -- nil => no declaration
                    }
                end
            elseif k == "fabric" and type(v) == "table" then
                fabric = { side = v.side, channel = tonumber(v.channel), mtu = tonumber(v.mtu) or 1024 }
            elseif k ~= "routes" then
                cfg[k] = tostring(v)
            end
        end
        n.cfg, n.iface_specs, n.fabric_spec = cfg, ifaces, fabric
        -- inline static routes: { { net="10.0.2.0", prefix=24, gw="10.0.1.1" } }
        if spec.routes then
            for _, r in ipairs(spec.routes) do
                M.route_add(n.routes, tonumber(r.prefix), M.masked(M.ip2int(r.net), tonumber(r.prefix)),
                    nil, M.ip2int(r.gw), "api")
            end
        end
        return n
    end

    local cfg, ifaces, fabric = parse_cfg(path)
    if not cfg then
        n:log("NO_ROLE_FILE %s", tostring(path))
        n.iface_specs = {}
        return n
    end
    n.cfg, n.iface_specs, n.fabric_spec = cfg, ifaces, fabric
    return n
end

-- display name/version label only: the project is RPV1 (Rednet Protocol Version 1);
-- code, paths, config keys and the rednet protocol string keep the `rpv` prefix
M.RPV_VERSION = "RPV1"

return M
