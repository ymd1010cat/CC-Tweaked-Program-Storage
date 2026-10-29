--[[- rpv/util.lua -- byte packing, checksums, address helpers.
Modules in this library are loaded as `function(M) ... end` files sharing one
table M (see poc/node2/startup.lua), so no require/package.path is needed and
the same files work on CC:Tweaked and CraftOS-PC.
]]
local M = ...
local floor, char, byte, sub, rep, concat = math.floor, string.char, string.byte, string.sub, string.rep, table.concat

M.floor, M.char, M.byte, M.sub, M.rep, M.concat = floor, char, byte, sub, rep, concat

function M.u8(v) return char(floor(v) % 256) end
function M.u16(v)
    v = floor(v)
    return char(floor(v / 256) % 256, v % 256)
end
function M.u32(v)
    v = floor(v)
    return char(floor(v / 16777216) % 256, floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
end
function M.r16(s, i) return byte(s, i) * 256 + byte(s, i + 1) end
function M.r32(s, i)
    return byte(s, i) * 16777216 + byte(s, i + 1) * 65536 + byte(s, i + 2) * 256 + byte(s, i + 3)
end

function M.rawsum(s)
    local sum, n = 0, #s
    for i = 1, n - 1, 2 do sum = sum + byte(s, i) * 256 + byte(s, i + 1) end
    if n % 2 == 1 then sum = sum + byte(s, n) * 256 end
    while sum > 0xFFFF do sum = sum % 65536 + floor(sum / 65536) end
    return sum
end
function M.cksum(s) return (0xFFFF - M.rawsum(s)) % 65536 end

function M.ip2int(s)
    local a, b, c, d = tostring(s):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then error("bad ip: " .. tostring(s), 2) end
    return a * 16777216 + b * 65536 + c * 256 + d
end
function M.int2ip(n)
    n = floor(n)
    return string.format("%d.%d.%d.%d", floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end
-- longest-prefix style mask helper
function M.masked(ip, prefix)
    if prefix <= 0 then return 0 end
    if prefix >= 32 then return ip end
    local size = 2 ^ (32 - prefix)
    return ip - (ip % size)
end
function M.hex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", byte(s, i)) end
    return concat(out)
end

M.ET_ARP, M.ET_IP = 0x0806, 0x0800
M.IP_ICMP, M.IP_UDP = 1, 17
M.MAC_BCAST = 4294967295
M.IP_BCAST = 4294967295

--[[- Pyroet OS rpv subset: capability gate for modules that are not vendored.

The shipped image carries only crypto/util/ip/route/arp/link/udp/conn/node (see
pyroet-os/DECISIONS.md section 3). The other 11 modules were cut to fit the
1/4 MiB budget, so a code path that would have called into one of them must
degrade instead of indexing a nil field. Every such site calls this helper: it
logs one ASCII warning per tag and lets the caller continue. The node keeps
running, the packet is dropped, and the log line names the missing capability.
Tags are stable so a smoke run or a field report can grep for them:
    RPV_SUBSET_NO_ICMP  RPV_SUBSET_NO_WAN  RPV_SUBSET_NO_FABRIC
    RPV_SUBSET_NO_NAT   RPV_SUBSET_NO_MCAST  RPV_SUBSET_NO_QOS
    RPV_SUBSET_NO_DV    RPV_SUBSET_NO_TOPO   RPV_SUBSET_NO_SERVICES
]]
M.subset_warned = M.subset_warned or {}
function M.subset_missing(node, tag, detail)
    if M.subset_warned[tag] then return end
    M.subset_warned[tag] = true
    node:log("%s%s", tag, detail and (" detail=" .. tostring(detail)) or "")
end

return M
