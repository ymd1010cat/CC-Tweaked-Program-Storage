-- CraftOS-PC probing v2: writes results to /ws/poc/out/probe.txt (workspace-mounted, RW)
local f = fs.open("probe.txt", "w")
local function out(...)
    f.writeLine(table.concat({ ... }, " "))
    f.flush()
end

out("ID=" .. tostring(os.getComputerID()))
out("VERSION=" .. tostring(os.version()))
out("PERIPHEMU_NAMES=" .. textutils.serialize(periphemu and periphemu.names() or nil))
out("ATTRS=" .. textutils.serialize({
    rednet = rednet ~= nil, parallel = parallel ~= nil, bit32 = bit32 ~= nil,
    stringpack = string.pack ~= nil, table_pack = table.pack ~= nil, utf8 = utf8 ~= nil,
    settings = settings ~= nil, ccemux = ccemux ~= nil,
}))

local function try(label, fn, ...)
    local ok, res = pcall(fn, ...)
    out(label .. "=" .. tostring(ok) .. " res=" .. textutils.serialize(res))
    return ok, res
end

try("CREATE_MODEM_BACK", periphemu.create, "back", "modem")
try("CREATE_MODEM_LEFT", periphemu.create, "left", "modem")
try("CREATE_MODEM_RIGHT", periphemu.create, "right", "modem")
out("NAMES=" .. textutils.serialize(peripheral.getNames()))
for _, name in ipairs(peripheral.getNames()) do
    local _, wl = pcall(peripheral.call, name, "isWireless")
    out("SIDE " .. name .. " type=" .. tostring(peripheral.getType(name)) .. " wireless=" .. tostring(wl))
end

local function recv(timeout)
    local timer = os.startTimer(timeout or 1)
    while true do
        local ev, p1, p2, p3, p4, p5 = os.pullEvent()
        if ev == "modem_message" then
            return { side = p1, channel = p2, reply = p3, payload = p4, distance = p5 }
        elseif ev == "timer" and p1 == timer then
            return nil
        end
    end
end

local CH = 4321
for _, side in ipairs({ "back", "left", "right" }) do
    if peripheral.getType(side) == "modem" then pcall(peripheral.call, side, "open", CH) end
end

-- cross-modem reception inside one computer
try("TRANSMIT_BACK", peripheral.call, "back", "transmit", CH, 111, { hello = "world", n = 42, arr = { 1, 2, 3 } })
out("RECV_AFTER_CROSS=" .. textutils.serialize(recv(1)))
out("RECV_AFTER_CROSS2=" .. textutils.serialize(recv(0.2)))

-- channel isolation: left open on a different channel should not hear back's tx
pcall(peripheral.call, "left", "close", CH)
try("TRANSMIT_BACK2", peripheral.call, "back", "transmit", CH, 112, "isolated")
out("RECV_ISOLATED=" .. textutils.serialize(recv(0.5)))

-- can we open many channels?
local okopen, err = pcall(function()
    for c = 1, 200 do peripheral.call("back", "open", c) end
end)
out("OPEN_200=" .. tostring(okopen) .. " err=" .. tostring(err))

-- extra computers in-process
if ccemux then
    out("CEMUX_FUNCS=" .. textutils.serialize({ openEmu = ccemux.openEmu ~= nil, closeEmu = ccemux.closeEmu ~= nil, attach = ccemux.attach ~= nil }))
    local ok, id = pcall(ccemux.openEmu, 31)
    out("OPEN_EMU_31=" .. tostring(ok) .. " id=" .. tostring(id))
    os.sleep(2)
end

out("DONE")
f.close()
os.shutdown()
