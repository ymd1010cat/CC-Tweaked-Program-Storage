-- A *plain rednet* device living on the rpv WAN: no rpv code at all.
--
-- WAN contract (protocol "rpv"):
--   gateway -> device : { sType = "udp", to = <dest ip>, sport = , dport = , data = }
--   device  -> gateway: mirror the table (swap sport/dport, like an IP reply)
-- The device answers UDP port 7 with "legacy-echo:<payload>".
local logfile = fs.open("legacy-log.txt", "w")
local function w(fmt, ...)
    local line = string.format("%.3f [%d/legacy] ", os.clock(), os.getComputerID())
        .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    logfile.writeLine(line)
    logfile.flush()
    print(line)
end

-- emulator glue only: on real CC:Tweaked the modem is a physical block
if periphemu and peripheral.getType("back") ~= "modem" then
    periphemu.create("back", "modem")
end

local cfg = {}
if fs.exists("legacy.txt") then
    local f = fs.open("legacy.txt", "r")
    for line in f.readLine do
        line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then cfg[k] = v end
    end
    f.close()
end
local myip = cfg.ip or "172.16.0.9"

rednet.open("back")
w("LEGACY_WAN_READY id=%d ip=%s", os.getComputerID(), myip)
if cfg.host then
    rednet.host("rpv", cfg.host)
    w("LEGACY_REDNET_HOST protocol=rpv name=%s", cfg.host)
end
if cfg.lookup then
    local id = rednet.lookup("rpv", cfg.lookup)
    w("LEGACY_LOOKUP protocol=rpv host=%s -> %s", cfg.lookup, tostring(id))
end

local udp_service = { [7] = true }
local seen_adverts = 0

while true do
    local sender, message, protocol = rednet.receive("rpv")
    if protocol == "rpv" and type(message) == "table" then
        if message.sType == "rpv-advert" then
            seen_adverts = seen_adverts + 1
            if seen_adverts <= 2 then
                w("LEGACY_SEES_ADVERT gw=%s ip=%s nets=%d", tostring(message.gw), tostring(message.ip),
                    #(message.nets or {}))
            end
        elseif message.sType == "udp" then
            w("LEGACY_RX from=%d src=%s to=%s sport=%d dport=%d data=%s", sender, tostring(message.from),
                tostring(message.to), tonumber(message.sport) or 0, tonumber(message.dport) or 0, tostring(message.data))
            if udp_service[tonumber(message.dport) or 0] then
                local reply = "legacy-echo:" .. tostring(message.data)
                rednet.send(sender, {
                    sType = "udp",
                    from = message.to,
                    to = message.from or message.to,
                    sport = tonumber(message.dport) or 0,
                    dport = tonumber(message.sport) or 0,
                    data = reply,
                }, "rpv")
                w("LEGACY_REPLY to=%d dest=%s sport=%d dport=%d bytes=%d", sender, tostring(message.from),
                    tonumber(message.dport) or 0, tonumber(message.sport) or 0, #reply)
            end
        else
            w("LEGACY_IGNORED type=%s from=%d", tostring(message.sType), sender)
        end
    end
end
