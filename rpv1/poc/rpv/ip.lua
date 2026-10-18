--[[- rpv/ip.lua ? IPv4-like header, fragmentation, bounded reassembly.]]
local M = ...
local u8, u16, u32, r16, r32, rawsum, cksum, sub, floor = M.u8, M.u16, M.u32, M.r16, M.r32, M.rawsum, M.cksum, M.sub, M.floor

-- df = "don't fragment" (IPv4 flag 0x4000): the sender refuses fragmentation and
-- expects ICMP type 3 code 4 with the next-hop MTU (RFC 1191) back.
function M.ip_build(src, dst, proto, ttl, id, mf, offset8, payload, df)
    local total = 20 + #payload
    local flags_off = (df and 0x4000 or 0) + (mf and 0x2000 or 0) + (offset8 % 0x2000)
    local hdr = u8(0x45) .. u8(0) .. u16(total) .. u16(id) .. u16(flags_off)
        .. u8(ttl) .. u8(proto) .. u16(0) .. u32(src) .. u32(dst)
    return sub(hdr, 1, 10) .. u16(cksum(hdr)) .. sub(hdr, 13) .. payload
end

function M.ip_parse(s)
    if #s < 20 then return nil end
    local vihl = M.byte(s, 1)
    if floor(vihl / 16) ~= 4 then return nil end
    local ihl = (vihl % 16) * 4
    if ihl < 20 or #s < ihl then return nil end
    local total = r16(s, 3)
    if total > #s then return nil end
    if rawsum(sub(s, 1, ihl)) ~= 0xFFFF then return nil end
    local fo = r16(s, 7)
    return {
        ihl = ihl, total = total, id = r16(s, 5),
        mf = floor(fo / 0x2000) % 2 == 1, df = floor(fo / 0x4000) % 2 == 1,
        offset8 = fo % 0x2000,
        ttl = M.byte(s, 9), proto = M.byte(s, 10), src = r32(s, 13), dst = r32(s, 17),
    }
end

-- max payload per fragment for a given MTU (8-byte alignment)
function M.ip_max_payload(mtu)
    local maxpay = mtu - 20
    return maxpay - (maxpay % 8)
end

-- bounded reassembly: caps on concurrent entries and buffered bytes
function M.reasm_new(max_entries, max_bytes)
    return { buf = {}, max_entries = max_entries or 16, max_bytes = max_bytes or 65536, bytes = 0, drops = 0 }
end

function M.reasm_push(r, h, payload)
    local key = string.format("%d-%d-%d-%d", h.src, h.dst, h.id, h.proto)
    local b = r.buf[key]
    if not b then
        local n = 0
        for _ in pairs(r.buf) do n = n + 1 end
        if n >= r.max_entries then
            r.drops = r.drops + 1
            return nil, "reasm table full"
        end
        b = { frags = {}, expires = os.clock() + 10 }
        r.buf[key] = b
    end
    if r.bytes + #payload > r.max_bytes then
        r.buf[key] = nil
        r.drops = r.drops + 1
        return nil, "reasm byte cap"
    end
    r.bytes = r.bytes + #payload
    b.frags[#b.frags + 1] = { off = h.offset8 * 8, data = payload }
    if not h.mf then b.total = h.offset8 * 8 + #payload end
    if not b.total then return nil end
    table.sort(b.frags, function(x, y) return x.off < y.off end)
    local pos, out = 0, {}
    for _, f in ipairs(b.frags) do
        if f.off ~= pos then return nil end
        out[#out + 1] = f.data
        pos = pos + #f.data
    end
    if pos ~= b.total then return nil end
    r.buf[key] = nil
    r.bytes = r.bytes - pos
    return M.concat(out)
end

function M.reasm_expire(r)
    local now, n = os.clock(), 0
    for k, b in pairs(r.buf) do
        if b.expires < now then
            for _, f in ipairs(b.frags) do r.bytes = r.bytes - #f.data end
            r.buf[k] = nil
            n = n + 1
        end
    end
    return n
end





-- ===== IPv4 special-use address classification ==============================
-- RFC 6890 / 1918 / 3927 / 5737 / 6598 style classification. Reserved segments are
-- never silently treated as ordinary unicast:
--   * loopback (127/8) stays on the node and is never put on a modem
--   * link local, this-network, reserved 240/4 and the doc/benchmark blocks are never
--     forwarded by a router
--   * private (RFC1918) is what a LAN interface is expected to use
--   * 10/8, 172.16/12 and 192.168/16 are the LAN ranges; 192/8 outside 192.168 is not
--     private (192.0.0.0/24 is IETF protocol assignments, 192.0.2.0/24 is TEST-NET-1)
local IP_CLASSES = {
    { name = "loopback",    net = "127.0.0.0",    prefix = 8,  local_only = true },
    { name = "linklocal",   net = "169.254.0.0",  prefix = 16 },
    { name = "private",     net = "192.168.0.0",  prefix = 16, private = true, forward = true },
    { name = "testnet",     net = "192.0.2.0",    prefix = 24, doc = true },
    { name = "testnet",     net = "198.51.100.0", prefix = 24, doc = true },
    { name = "testnet",     net = "203.0.113.0",  prefix = 24, doc = true },
    { name = "protocol",    net = "192.0.0.0",    prefix = 24 },
    { name = "benchmark",   net = "198.18.0.0",   prefix = 15 },
    { name = "cgnat",       net = "100.64.0.0",   prefix = 10, forward = true },
    { name = "private",     net = "172.16.0.0",   prefix = 12, private = true, forward = true },
    { name = "private",     net = "10.0.0.0",     prefix = 8,  private = true, forward = true },
    { name = "unspecified", net = "0.0.0.0",      prefix = 8 },
    { name = "multicast",   net = "224.0.0.0",    prefix = 4,  group = true },
    { name = "reserved",    net = "240.0.0.0",    prefix = 4 },
    { name = "public",      net = "0.0.0.0",      prefix = 0,  forward = true },
}
local IP_CLASS_LIST = {}
for _, c in ipairs(IP_CLASSES) do
    IP_CLASS_LIST[#IP_CLASS_LIST + 1] = {
        name = c.name, private = c.private or false, forward = c.forward or false,
        local_only = c.local_only or false, group = c.group or false, doc = c.doc or false,
        net = M.ip2int(c.net), prefix = c.prefix,
    }
end
-- longest prefix first, so the most specific block wins (192.168/16 before 192/8)
table.sort(IP_CLASS_LIST, function(x, y) return x.prefix > y.prefix end)
M.IP_CLASS_LIST = IP_CLASS_LIST

local LIMITED_BCAST = M.IP_BCAST

function M.ip_class_info(ip)
    if ip == LIMITED_BCAST then
        return { name = "broadcast", broadcast = true, forward = false }
    end
    for _, c in ipairs(IP_CLASS_LIST) do
        if M.masked(ip, c.prefix) == c.net then return c end
    end
    return IP_CLASS_LIST[#IP_CLASS_LIST]
end

function M.ip_class(ip) return M.ip_class_info(ip).name end
function M.ip_is_private(ip) return M.ip_class_info(ip).private == true end
function M.ip_is_loopback(ip) return M.ip_class_info(ip).local_only == true end
function M.ip_is_multicast(ip) return M.ip_class_info(ip).group == true end
function M.ip_is_linklocal(ip) return M.ip_class(ip) == "linklocal" end
function M.ip_is_unspecified(ip) return M.ip_class(ip) == "unspecified" end
function M.ip_is_broadcast(ip) return ip == LIMITED_BCAST end
-- may a router forward a packet with this destination? (loose source/destination
-- validation for the FORWARD path: link local, doc/benchmark, 240/4, unhandled
-- multicast and loopback are never routed onward)
function M.ip_forwardable(ip) return M.ip_class_info(ip).forward == true end

-- may a HOST put this destination on the wire at all? This is the stricter, separate
-- question: link local, multicast and the doc/benchmark blocks are legitimately
-- transmittable (they are only never forwarded), while this-network (0/8), the reserved
-- block (240/4) and loopback are invalid destinations in any role.
function M.ip_transmittable(ip)
    local cls = M.ip_class_info(ip)
    if cls.local_only or cls.broadcast then return false end
    if cls.name == "unspecified" or cls.name == "reserved" then return false end
    return true
end

-- the subnet all-ones address (directed broadcast), e.g. 10.0.1.255/24
function M.ip_directed_broadcast(net, prefix)
    if prefix >= 31 then return nil end
    return net + (2 ^ (32 - prefix) - 1)
end

function M.ip_is_directed_broadcast(ip, iface)
    if not iface or not iface.net or not iface.prefix then return false end
    if iface.prefix >= 31 then return false end
    return ip == M.ip_directed_broadcast(iface.net, iface.prefix)
end

-- configuration checks for one interface: returns a list of { code, detail }
function M.ip_iface_warnings(iface)
    local out = {}
    local cls = M.ip_class_info(iface.ip)
    local function add(code, detail) out[#out + 1] = { code = code, detail = detail } end
    if cls.broadcast or cls.local_only or cls.group or cls.name == "reserved" then
        add("ADDR_NOT_UNICAST", "class=" .. cls.name)
    end
    if iface.prefix and iface.prefix < 31 then
        if iface.ip == iface.net then add("ADDR_IS_NETWORK", "addr equals the subnet address") end
        if M.ip_is_directed_broadcast(iface.ip, iface) then
            add("ADDR_IS_BROADCAST", "addr equals the directed broadcast address")
        end
    end
    if not cls.private and not cls.local_only and not cls.broadcast
        and cls.name ~= "linklocal" and not cls.group then
        add("ADDR_NOT_PRIVATE", "class=" .. cls.name .. " (a LAN is expected to use RFC1918)")
    end
    return out
end

return M
