--[[- rpv-echo.lua — an EXTERNAL program that uses the RPV1 library.

It is not an app of this project: it is installed as `startup.lua` on a plain
CC:Tweaked computer, loads the library through its public entry point and builds
its own node from an inline config table. There is no role.txt, no bootstrap and
no knowledge of the project's internals.

    /rpv.lua  /rpv/*.lua  /startup.lua (= this file)

Behavior: answers ICMP echo (the library does that by default) and echoes every
UDP datagram back to its sender on ECHO_PORT.
]]
-- works with either distribution form: the folder layout (rpv.lua + rpv/) or the
-- single-file build (rpv-bundle.lua)
local rpv = (function()
    local ok, mod = pcall(require, "rpv")
    if ok and type(mod) == "table" then return mod end
    for _, path in ipairs({ "rpv-bundle.lua", "/rpv-bundle.lua" }) do
        local ok2, b = pcall(dofile, path)
        if ok2 and type(b) == "table" then return b end
    end
    error("RPV1 not found: install rpv.lua + rpv/, or put rpv-bundle.lua next to this program")
end)()

-- ==== edit these two lines to fit your network =============================
local MY_CIDR   = "10.0.1.3/24"
local MY_SIDE   = "left"              -- side the modem is on
-- ==========================================================================
local CHANNEL   = 4400                -- the modem channel = the "wire"
local ECHO_PORT = 4100

local log = fs.open("echo-log.txt", "w")
local function w(fmt, ...)
    log.writeLine(string.format("%.3f " .. fmt, os.clock(), ...))
    log.flush()
end

local node = rpv.node_new({
    role = "host",
    ifaces = { { side = MY_SIDE, name = "LAN", cidr = MY_CIDR, channel = CHANNEL,
                 mtu = 256, linktype = "wireless" } },
})
node:setup()
w("ECHO_READY addr=%s mac=%d channel=%d", MY_CIDR, node.mac, CHANNEL)

-- UDP echo: the callback gets (payload, src_ip, src_port); rpv.udp_send() sends
-- straight to the source, so the reply needs no routing knowledge at all.
node:bind(ECHO_PORT, function(data, src, sport)
    w("ECHO_RX from=%s sport=%d bytes=%d", rpv.int2ip(src), sport, #data)
    rpv.udp_send(node, src, ECHO_PORT, sport, "echo:" .. data)
end)

node:run()                            -- the library's event loop never returns
