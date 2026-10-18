-- rpvnet.lua - the network transport of the whole system.
--
-- The shell, the package manager, the licence client and the daemons used to call
-- rednet directly. This module keeps that call shape -- open, close, isOpen, send,
-- broadcast, receive -- but can carry the traffic over RPV1 instead: the vendored
-- stack in /rpv, which brings IPv4 style addressing, routing, DHCP-lite, a name
-- service, multicast domains and the AEAD control plane. When the stack is missing,
-- unusable, or switched off in /etc/network.conf, every call is handed to rednet
-- unchanged, so the old machines keep working.
--
--   transport=auto     rpv when the vendored stack loads and a modem is present,
--                      rednet otherwise (default)
--   transport=rpv      require rpv; a start failure is reported instead of falling back
--   transport=rednet   always rednet
--
-- The address of the rpv interface and the layer 2 channel default from the modem side
-- and the computer id, so a fleet needs no per machine configuration:
--
--   rpv_side=back              interface side (defaults to modem_side)
--   rpv_cidr=10.0.4.<id>/24    address (defaults to the id based address)
--   rpv_channel=4700           layer 2 channel of the rpv segment
--   rpv_mtu=512                interface MTU
--   rpv_peer_<id>=<address>    optional static id -> address map (skips discovery)
--
-- A message is one UDP datagram on a port derived from the protocol name, wrapped as
--
--   RN1|<protocol>|<computer id>|<blob>
--
-- so the receiver learns the sender id -- which is what the shell addresses -- without
-- a name service, and remembers the address it came from. rednet and rpv machines
-- cannot talk to each other: both ends of a conversation must use the same transport.

local netcfg = require("netcfg")

local rpvnet = {}

local ENVELOPE = "RN1"
local PORT_BASE = 20000
local PORT_SPAN = 20000
local DISCOVERY_PORT = 19999
local PUMP_STEP = 0.2
local RECEIVE_HARD_CAP = 900

local state = {
    backend = nil, node = nil, stack = nil, error = nil, side = nil,
    bound = {}, queue = {}, id_ip = {}, ip_id = {}, own_ip = nil, dropped = 0,
}

-- ---------------------------------------------------------------------------
-- protocol name -> port (stable across machines, no configuration needed)
-- ---------------------------------------------------------------------------
-- FNV-1a style hash, kept to Lua 5.1 arithmetic only: the shell runs on CraftOS, where
-- the bitwise operators of Lua 5.3 and later do not exist.
local function fnv1a(text)
    local h = 2166136261
    for i = 1, #text do
        h = (h * 16777619 + string.byte(text, i)) % 4294967296
    end
    return h
end

function rpvnet.port_of(protocol)
    return PORT_BASE + (fnv1a(tostring(protocol or "")) % PORT_SPAN)
end

function rpvnet.discovery_port() return DISCOVERY_PORT end

-- ---------------------------------------------------------------------------
-- configuration and backend selection
-- ---------------------------------------------------------------------------
local function conf(key) return netcfg.get(key, nil) end

-- rpv works on numbers; addresses can arrive from the configuration, from a discovery
-- answer or from the stack as dotted strings, so everything is normalised here
local function to_ip(value)
    if type(value) == "number" then return value end
    if type(value) == "string" and value ~= "" then
        local lib = rpvnet.stack()
        if lib and lib.ip2int then
            local ok, num = pcall(lib.ip2int, value)
            if ok then return num end
        end
    end
    return nil
end

function rpvnet.stack()
    if state.stack ~= nil then return state.stack or nil end
    -- the vendored entry point works out where it was loaded from and finds its siblings
    -- through the same filesystem require() is built on. It is loaded on this path only:
    -- assembling the library by hand would also install the stack's rednet shim, which
    -- must never happen behind the back of a machine that is meant to stay on rednet.
    local path = package.path or ""
    if not path:find("rpv/?.lua", 1, true) then
        package.path = path .. ";rpv/?.lua"
    end
    local ok, lib = pcall(require, "loader")
    if ok and type(lib) == "table" and type(lib.node_new) == "function" then
        state.stack = lib
        state.stack_via = "require"
        return state.stack
    end
    state.stack = false
    state.error = tostring(lib)
    return nil
end

-- can the rpv path actually be used on this machine?
function rpvnet.available()
    if not rpvnet.stack() then return false, state.error or "rpv stack missing" end
    if type(peripheral) ~= "table" or type(peripheral.getType) ~= "function" then
        return false, "no peripheral api"
    end
    local side = conf("rpv_side") or netcfg.modem()
    local ok, kind = pcall(peripheral.getType, side)
    if not ok or kind ~= "modem" then return false, "no modem on " .. tostring(side) end
    return true
end

function rpvnet.transport()
    if state.backend then return state.backend end
    local want = tostring(conf("transport") or "auto"):lower()
    if want == "rednet" then
        state.backend = "rednet"
    elseif want == "rpv" then
        local ok, why = rpvnet.available()
        if not ok then error("transport=rpv but rpv cannot start: " .. tostring(why), 0) end
        state.backend = "rpv"
    else
        local ok, why = rpvnet.available()
        -- auto keeps talking rednet when the stack had to be assembled from files: that
        -- only happens where require() cannot see the tree (the PC side stub), and the
        -- shell should not silently change transport there
        if ok and state.stack_via == "fallback" then
            ok = false
            why = "loader unavailable"
        end
        state.backend = ok and "rpv" or "rednet"
    end
    return state.backend
end

-- tests and the shell switch transports without restarting the process
function rpvnet.reset()
    state.backend = nil
    return true
end

-- ---------------------------------------------------------------------------
-- the rpv node: created on first use, driven by pump()
-- ---------------------------------------------------------------------------
local function static_peer(id)
    local ip = conf("rpv_peer_" .. tostring(id))
    if ip and ip ~= "" then return ip end
    return nil
end

local function push(port, sender, blob, proto)
    state.queue[#state.queue + 1] = { port = port, sender = sender, blob = blob, proto = proto }
end

local function on_datagram(port, data, src)
    -- the tag is alphanumeric (RN1), not letters only: a %a pattern silently failed to match
    -- every envelope, which made receive() return nothing on a real machine
    local tag, proto, sid, blob = tostring(data):match("^(%w+)|([^|]*)|(%d+)|(.*)$")
    if tag ~= ENVELOPE then state.dropped = state.dropped + 1 return end
    local id = tonumber(sid)
    if id then
        -- every datagram teaches the pair: the id of the sender and the address it
        -- came from, so a reply never needs a lookup
        local sip = to_ip(src)
        state.ip_id[sip] = id
        state.id_ip[id] = sip
    end
    -- discovery runs on its own port: "who|<id>" is answered by the owner, and the
    -- answer "here|<id>|<address>" is what fills the map for everybody else
    if port == DISCOVERY_PORT then
        local kind, arg1, arg2 = tostring(blob):match("^(%a+)|([^|]*)|?(.*)$")
        local me = os.getComputerID()
        if kind == "who" and tonumber(arg1) == me and id then
            local answer = ENVELOPE .. "|discovery|" .. tostring(me) .. "|here|" .. tostring(me) .. "|" .. tostring(state.own_ip or 0)
            local n = state.node
            local dip = to_ip(src)
            if n and dip then pcall(rpvnet.stack().udp_send, n, dip, DISCOVERY_PORT, DISCOVERY_PORT, answer) end
        elseif kind == "here" and tonumber(arg1) then
            local ip = tonumber(arg2)
            if ip then state.id_ip[tonumber(arg1)] = to_ip(ip) end
        end
        return
    end
    push(port, id, blob, proto)
end

local function ensure_bound(port)
    if state.bound[port] then return end
    local n = state.node
    if not n then return end
    state.bound[port] = true
    n:bind(port, function(data, src) on_datagram(port, data, src) end)
end

local function node()
    if state.node then return state.node end
    local rpv = rpvnet.stack()
    if not rpv then return nil end
    local id = os.getComputerID()
    local side = conf("rpv_side") or netcfg.modem()
    local cidr = conf("rpv_cidr") or ("10.0.4." .. tostring(id) .. "/24")
    local channel = tonumber(conf("rpv_channel")) or 4700
    local mtu = tonumber(conf("rpv_mtu")) or 512
    local ok, n = pcall(rpv.node_new, {
        role = "host",
        ifaces = { { side = side, name = "LAN", cidr = cidr, channel = channel,
                     mtu = mtu, linktype = "wireless" } },
        dv = "0",
        -- A file transfer puts one datagram per chunk on the wire, so a single 4 KB
        -- chunk is thirteen fragments at MTU 512: the stock 64 KB reassembly cap is
        -- reached by a burst, and every datagram dropped that way leaves the peer
        -- silent until the fragments expire. Both limits are configurable, with a
        -- budget that fits a chunked transfer by default.
        reasm_bytes = tonumber(conf("rpv_reasm_bytes")) or 524288,
        reasm_entries = tonumber(conf("rpv_reasm_entries")) or 128,
        -- Fragment pacing, off by default. A real modem handed a whole datagram in one
        -- loop drops most of it (measured on the Minecraft server: 144 FRAGMENTED, 0
        -- REASSEMBLED), so a hardware machine sets rpv_frag_pace=1 and the middle
        -- fragments of a datagram follow on a timer instead of in a burst.
        frag_pace = conf("rpv_frag_pace"),
        frag_pace_ms = tonumber(conf("rpv_frag_pace_ms")) or 10,
        -- Size cap of the live node log. It is written on every frame event, so a
        -- large transfer appends ~14.5 KB per 200 KB moved (measured) into a computer
        -- whose whole disk is about 1 MB; reading it back over a Minecraft world file
        -- system has timed out while the transfer itself was healthy. The stack
        -- rotates to rpv-log.txt.1 once the live log passes this; 0 disables it.
        log_max_bytes = tonumber(conf("rpv_log_max_bytes")) or 131072,
    })
    -- A node that fails to build used to be reported as "rpv unavailable", which says
    -- nothing about the cause: carry the error (and a traceback where the ROM has the
    -- debug library) into state.error, so netcfg.open() and the callers can print it.
    if not ok or type(n) ~= "table" then
        local trace = "n/a"
        if debug and debug.traceback then
            local okt, tb = pcall(debug.traceback)
            if okt then trace = tostring(tb) end
        end
        state.error = "rpv node_new failed: " .. tostring(n) .. " trace=" .. trace
        return nil
    end
    local oks, serr = pcall(function() n:setup() end)
    if not oks then
        state.error = "rpv node setup failed: " .. tostring(serr)
        return nil
    end
    state.node = n
    state.own_ip = n.ifaces[1] and n.ifaces[1].ip or nil
    ensure_bound(DISCOVERY_PORT)
    return n
end

function rpvnet.node() return node() end
function rpvnet.own_address() return state.own_ip end

function rpvnet.pump(seconds)
    local n = state.node or node()
    if not n or not n.pump then return false end
    return n:pump(seconds or PUMP_STEP)
end

-- ask the segment who owns an id: one broadcast, a short pump, then the cache decides
local function discover(id)
    local n = state.node
    if not n then return nil end
    local rpv = rpvnet.stack()
    ensure_bound(DISCOVERY_PORT)
    local payload = ENVELOPE .. "|discovery|" .. tostring(os.getComputerID()) .. "|who|" .. tostring(id)
    rpv.udp_send(n, rpv.IP_BCAST, DISCOVERY_PORT, DISCOVERY_PORT, payload)
    rpvnet.pump(0.5)
    return state.id_ip[id]
end

-- ---------------------------------------------------------------------------
-- the rednet shaped API
-- ---------------------------------------------------------------------------
function rpvnet.open(side)
    if rpvnet.transport() ~= "rpv" then
        local ok, err = pcall(rednet.open, side or netcfg.modem())
        if not ok then return nil, tostring(err) end
        return true
    end
    local n = node()
    if not n then return nil, state.error or "rpv unavailable" end
    state.side = side or (n.ifaces[1] and n.ifaces[1].side)
    rpvnet.pump(0.05)
    return true
end

function rpvnet.close(side)
    if rpvnet.transport() ~= "rpv" then return rednet.close(side) end
    state.side = nil
    return true
end

function rpvnet.isOpen(side)
    if rpvnet.transport() ~= "rpv" then return rednet.isOpen(side) end
    return (state.node ~= nil) or (node() ~= nil)
end

function rpvnet.send(target, blob, protocol)
    if rpvnet.transport() ~= "rpv" then
        return rednet.send(target, blob, protocol)
    end
    local n = node()
    if not n then return nil, state.error or "rpv unavailable" end
    local port = rpvnet.port_of(protocol)
    ensure_bound(port)
    local id = tonumber(target)
    local ip = (id and state.id_ip[id]) or (id and static_peer(id)) or nil
    if not ip then
        if not id then return nil, "rpv addresses computer ids" end
        ip = discover(id)
    end
    if not ip then return nil, "unknown peer id " .. tostring(target) end
    -- the address may come from the config or from a discovery answer: rpv works on
    -- numbers, so a dotted string has to be converted before it reaches udp_send
    ip = to_ip(ip)
    if not ip then return nil, "bad address for peer id " .. tostring(target) end
    local payload = ENVELOPE .. "|" .. tostring(protocol) .. "|" .. tostring(os.getComputerID()) .. "|" .. tostring(blob)
    local ok, err = pcall(rpvnet.stack().udp_send, n, ip, port, port, payload)
    if not ok then return nil, tostring(err) end
    return true
end

function rpvnet.broadcast(blob, protocol)
    if rpvnet.transport() ~= "rpv" then
        return rednet.broadcast(blob, protocol)
    end
    local n = node()
    if not n then return nil, state.error or "rpv unavailable" end
    local rpv = rpvnet.stack()
    local port = rpvnet.port_of(protocol)
    ensure_bound(port)
    local payload = ENVELOPE .. "|" .. tostring(protocol) .. "|" .. tostring(os.getComputerID()) .. "|" .. tostring(blob)
    local ok, err = pcall(rpv.udp_send, n, rpv.IP_BCAST, port, port, payload)
    if not ok then return nil, tostring(err) end
    return true
end

-- rednet.receive(protocol, timeout) returns sender, message (or nil on timeout)
function rpvnet.receive(protocol, timeout)
    if rpvnet.transport() ~= "rpv" then
        return rednet.receive(protocol, timeout)
    end
    local want = rpvnet.port_of(protocol)
    ensure_bound(want)
    ensure_bound(DISCOVERY_PORT)
    local waited = 0
    while true do
        for i = 1, #state.queue do
            local item = state.queue[i]
            if item.port == want then
                table.remove(state.queue, i)
                return item.sender, item.blob, item.proto
            end
        end
        if timeout and waited >= timeout then return nil end
        if not timeout and waited >= RECEIVE_HARD_CAP then return nil end
        rpvnet.pump(PUMP_STEP)
        waited = waited + PUMP_STEP
    end
end

function rpvnet.stats()
    local n = 0
    for _ in pairs(state.bound) do n = n + 1 end
    return { backend = rpvnet.transport(), bound = n, queued = #state.queue,
             dropped = state.dropped, own_ip = state.own_ip }
end

return rpvnet
