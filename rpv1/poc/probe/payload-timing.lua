-- Probe 3: payload sizes, timing, serialization overhead
local f = fs.open("probe.txt", "w")
local function out(...) f.writeLine(table.concat({ ... }, " ")) f.flush() end

if periphemu then
    periphemu.create("back", "modem")
    periphemu.create("left", "modem")
end

local function recv(timeout)
    local timer = os.startTimer(timeout or 1)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "modem_message" then return p1, p2, p3, p4
        elseif ev == "timer" and p1 == timer then return nil end
    end
end

local CH = 4000
peripheral.call("back", "open", CH)
peripheral.call("left", "open", CH)

-- payload size limits
for _, n in ipairs({ 1000, 4096, 8192, 16384, 32768, 32768 * 2, 65536, 131072, 262144 }) do
    local ok, err = pcall(peripheral.call, "back", "transmit", CH, 21, string.rep("A", n))
    local side, ch, reply, payload = recv(2)
    out("SIZE " .. n .. " tx_ok=" .. tostring(ok) .. " err=" .. tostring(err)
        .. " rx=" .. tostring(side ~= nil) .. " rxlen=" .. tostring(type(payload) == "string" and #payload or payload))
end

-- table payload with nested data
local tbl = { src = 167772161, dst = 3232235778, ttl = 64, proto = 17, data = string.rep("x", 1000) }
local ok, err = pcall(peripheral.call, "back", "transmit", CH, 21, tbl)
local side, ch, reply, payload = recv(2)
out("TABLE tx_ok=" .. tostring(ok) .. " err=" .. tostring(err) .. " rx=" .. tostring(side ~= nil) .. " len=" .. tostring(payload and #payload.data))

-- serialization overhead of a table header
local hdr = { v = 1, ttl = 64, proto = 17, src = 167772161, dst = 3232235778, sport = 1234, dport = 80, seq = 1, mf = 0, off = 0, id = 4242 }
out("SERIALIZED_HDR_LEN=" .. #textutils.serialize(hdr))
local bin = string.char(0x45, 0x00, 0x00, 0x28, 0x00, 0x01, 0x00, 0x00, 64, 17, 0, 0, 10, 0, 0, 1, 192, 168, 1, 2)
out("BINARY_HDR_LEN=" .. #bin .. " pack=" .. tostring(string.pack ~= nil))

-- timing: round trip through two modems (loopback within the same computer)
local N = 200
local t0 = os.clock()
for i = 1, N do
    peripheral.call("back", "transmit", CH, 21, { i = i })
    recv(1)
end
local dt = os.clock() - t0
out("LOOPBACK_N=" .. N .. " seconds=" .. string.format("%.3f", dt) .. " per_msg_us=" .. string.format("%.0f", dt / N * 1e6))

-- clock / timer granularity
local ticks = {}
for i = 1, 10 do
    local t = os.clock()
    os.sleep(0)
    ticks[#ticks + 1] = string.format("%.6f", os.clock() - t)
end
out("SLEEP0=" .. table.concat(ticks, ","))

-- queue depth: how many messages can be handled per tick-ish
local t1 = os.clock()
for i = 1, 500 do peripheral.call("back", "transmit", CH, 21, { i = i }) end
local sent = os.clock() - t1
local drained, t2 = 0, os.clock()
while recv(0.05) and drained < 1000 do drained = drained + 1 end
out("BURST_SEND_500=" .. string.format("%.3f", sent) .. " DRAINED=" .. drained .. " DRAIN_TIME=" .. string.format("%.3f", os.clock() - t2))

out("DONE")
f.close()
os.shutdown()
