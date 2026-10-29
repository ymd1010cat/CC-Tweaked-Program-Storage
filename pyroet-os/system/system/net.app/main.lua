--[[- pyroet-os/system/net.app/main.lua -- the Net system app (26x20 terminal UI).

Shows the live network state, the static host table and the result of one UDP
probe. It only uses the two capabilities its manifest declares:

    net.rpv    the network host object (normally the net service instance)
    fs.read    reading /etc/net.target

The network host object is expected to expose `status()`, `list_hosts()` and
`probe(ip, port, payload, timeout, cb)`; that is exactly what
pyroet-os/net/service.lua provides. When the runtime hands over a plain rpv
library instead (no `status`), the UI degrades to "net service not attached"
rather than indexing a nil field.

Input: the P2 app runtime has seven fixed capabilities and none of them is an
input/terminal capability (DECISIONS.md 1.2(b), 9.6), so the probe target is a
one-line file rather than a keystroke prompt:

    /etc/net.target          "<ipv4> <port>", '#' starts a comment

A later input service can feed this file without touching the app.

Layout (DECISIONS.md 7.2): title row 1, content rows 2..cols-1..19, status row
20. Every line is padded or truncated to the view width, never wider, and a
view shorter than 8 rows collapses to the single status line. `layout_selftest`
checks both rules without a real terminal.

No non-ASCII bytes in this file.
]]

local M = {}

M.VERSION = "0.1.0"
M.VIEW = { cols = 26, rows = 20 }
M.TARGET_PATH = "/etc/net.target"
M.PROBE_PAYLOAD = "PYROET-NET-APP-1"
M.PROBE_TIMEOUT = 2

local function int2ip(value)
    local n = math.floor(tonumber(value) or 0)
    return table.concat({
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256,
    }, ".")
end

M.int2ip = int2ip

-- strict dotted-decimal; no leading zero, each octet 0..255
local function parse_ip(text)
    if type(text) ~= "string" then return nil end
    local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    local parts = { a, b, c, d }
    local value = 0
    for i = 1, 4 do
        local part = parts[i]
        if #part > 3 then return nil end
        if #part > 1 and part:sub(1, 1) == "0" then return nil end
        local octet = tonumber(part)
        if octet == nil or octet > 255 then return nil end
        value = value * 256 + octet
    end
    return value
end

M.parse_ip = parse_ip

-- printable ASCII only, truncated or padded to exactly `cols` columns
function M.fit(text, cols)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    if cols < 1 then cols = 1 end
    local s = tostring(text == nil and "" or text):gsub("[^\32-\126]", "?")
    if #s > cols then
        s = s:sub(1, cols)
    elseif #s < cols then
        s = s .. string.rep(" ", cols - #s)
    end
    return s
end

-- "<ipv4> <port>" -> ip text, port, nil | nil, nil, reason
function M.parse_target(text)
    local body = tostring(text == nil and "" or text)
    body = body:gsub("#[^\r\n]*", "")
    body = body:gsub("[\r\n\t]+", " ")
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    if body == "" then return nil, nil, "no target" end
    local ip_text, port_text, extra = body:match("^(%S+)%s+(%S+)%s*(.*)$")
    if not ip_text then return nil, nil, "usage: <ipv4> <port>" end
    if extra ~= "" then return nil, nil, "usage: <ipv4> <port>" end
    local ip = parse_ip(ip_text)
    if not ip then return nil, nil, "bad ipv4: " .. ip_text end
    local port = tonumber(port_text)
    if not port or port % 1 ~= 0 or port < 1 or port > 65535 then
        return nil, nil, "bad port: " .. port_text
    end
    return int2ip(ip), math.floor(port), nil
end

function M.new_state(opts)
    local o = opts or {}
    return {
        cols = o.cols or M.VIEW.cols,
        rows = o.rows or M.VIEW.rows,
        payload = o.payload or M.PROBE_PAYLOAD,
        timeout = o.timeout or M.PROBE_TIMEOUT,
        local_ip = nil,
        prefix = nil,
        gateway = nil,
        health = "unknown",
        hosts = {},
        hosts_error = nil,
        target_text = nil,
        target_ip = nil,
        target_port = nil,
        target_err = nil,
        probe = nil,
        probe_line = "probe: idle",
        last_result = nil,
        message = "",
        note_message = nil,
        note_summary = nil,
        service = nil,
    }
end

-- ---------------------------------------------------------------------------
-- capability plumbing
-- ---------------------------------------------------------------------------

-- Resolve the network host object. A denied capability is a normal result:
-- kernel/apps.lua hands back a callable stub, so the app sees a table whose
-- methods answer `nil, "capability denied: net.rpv"`.
function M.read_service(api)
    local net = api and api.net
    if type(net) ~= "table" then return nil, "capability denied: net.rpv" end
    local rpv = net.rpv
    if rpv == nil then return nil, "capability denied: net.rpv" end
    if type(rpv) ~= "table" then return nil, "net service unavailable" end
    if type(rpv.status) ~= "function" then return nil, "net service not attached" end
    return rpv, nil
end

function M.host_line(entry)
    local name = tostring(entry.name or "?")
    local text = entry.text
    if type(text) ~= "string" then
        text = type(entry.ip) == "number" and int2ip(entry.ip) or "?"
    end
    return name .. " " .. text
end

function M.describe(result)
    if type(result) ~= "table" then return "probe: no result" end
    if result.ok then
        return "probe: ok " .. tostring(result.rtt_text or "?")
    end
    return "probe: " .. tostring(result.err or "failed")
end

-- ---------------------------------------------------------------------------
-- state refresh
-- ---------------------------------------------------------------------------

function M.poll_probe(state)
    local handle = state.probe
    if type(handle) ~= "table" then return false end
    if not handle.done then return false end
    state.probe_line = M.describe(handle.result)
    state.last_result = handle.result
    state.probe = nil
    return true
end

function M.start_probe(state, service)
    if type(service) ~= "table" or type(service.probe) ~= "function" then
        state.probe_line = "probe: unavailable"
        return false
    end
    state.probe = nil
    state.probe_line = "probe: waiting"
    local called, handle, err = pcall(service.probe, service,
        state.target_ip, state.target_port, state.payload, state.timeout)
    if not called then
        state.probe_line = "probe: " .. tostring(handle)
        return false
    end
    if type(handle) ~= "table" then
        state.probe_line = "probe: " .. tostring(err or "no probe")
        if tostring(err or ""):find("capability denied", 1, true) then
            state.message = tostring(err)
        end
        return false
    end
    state.probe = handle
    return true
end

function M.read_target(api, state)
    local fsx = api and api.fs
    if not (fsx and type(fsx.read) == "function") then
        state.target_err = "fs.read unavailable"
        state.probe_line = "probe: " .. state.target_err
        return false
    end
    local called, text, err = pcall(fsx.read, M.TARGET_PATH)
    if not called then text, err = nil, text end
    if text == nil then
        state.target_text = nil
        state.target_ip, state.target_port = nil, nil
        state.target_err = tostring(err or "no target")
        state.probe_line = "probe: " .. state.target_err
        if state.target_err:find("capability denied", 1, true) then
            state.message = state.target_err
        end
        return false
    end
    if text == state.target_text then return false end
    state.target_text = text
    local ip, port, reason = M.parse_target(text)
    if not ip then
        state.target_ip, state.target_port = nil, nil
        state.target_err = reason
        state.probe_line = "probe: " .. tostring(reason)
        return false
    end
    state.target_ip, state.target_port, state.target_err = ip, port, nil
    return M.start_probe(state, state.service)
end

function M.note(state, api)
    if state.message ~= state.note_message then
        state.note_message = state.message
        if state.message and state.message ~= ""
            and type(api.log) == "function" then
            api.log(state.message)
        end
    end
    local summary = "health=" .. tostring(state.health)
        .. " ip=" .. tostring(state.local_ip)
    if summary ~= state.note_summary then
        state.note_summary = summary
        if type(api.log) == "function" then api.log(summary) end
    end
end

function M.refresh(state, api)
    local service, service_err = M.read_service(api)
    state.service = service
    if not service then
        state.health = "degraded"
        state.local_ip, state.prefix, state.gateway = nil, nil, nil
        state.hosts, state.hosts_error = {}, tostring(service_err)
        state.probe_line = "probe: unavailable"
        state.message = tostring(service_err)
    else
        local called, status, status_err = pcall(service.status, service)
        local service_ok = called and type(status) == "table"
        if service_ok then
            state.local_ip = status.ip
            state.prefix = status.prefix
            state.gateway = status.gateway
            state.health = status.health or "unknown"
            state.probe_port = status.probe_port
            state.message = ""
        else
            local why = called and (status_err or "status unavailable") or status
            state.health = "degraded"
            state.local_ip, state.prefix, state.gateway = nil, nil, nil
            state.message = tostring(why)
            state.probe_line = "probe: unavailable"
        end
        local hcalled, hosts, hosts_err = pcall(service.list_hosts, service)
        if hcalled and type(hosts) == "table" then
            state.hosts, state.hosts_error = hosts, nil
        else
            state.hosts = {}
            state.hosts_error = tostring(hcalled and (hosts_err or hosts) or hosts)
        end
        M.poll_probe(state)
        if service_ok then M.read_target(api, state) end
    end
    M.note(state, api)
    return state
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

function M.render(state, cols, rows)
    cols = math.floor(tonumber(cols) or M.VIEW.cols)
    rows = math.floor(tonumber(rows) or M.VIEW.rows)
    if cols < 1 then cols = 1 end
    if rows < 1 then rows = 1 end
    local health = tostring(state.health or "unknown")
    local status = "net " .. health .. " " .. tostring(cols) .. "x" .. tostring(rows)
    if rows < 8 then
        return { M.fit(status, cols) }
    end
    local out = {}
    local limit = rows - 1
    local function add(text)
        if #out >= limit then return false end
        out[#out + 1] = M.fit(text, cols)
        return true
    end
    add("Pyroet Net " .. M.VERSION)
    if state.local_ip then
        add("ip " .. tostring(state.local_ip) .. "/" .. tostring(state.prefix or "?"))
    else
        add("ip unavailable")
    end
    add("gw " .. tostring(state.gateway or "none"))
    add("health " .. health)
    local hosts = state.hosts or {}
    add("hosts " .. tostring(#hosts) .. (state.hosts_error and " (denied)" or ""))
    add("--- hosts ---")
    local capacity = 8
    if #hosts > 8 then capacity = 7 end
    for i = 1, math.min(#hosts, capacity) do
        add(M.host_line(hosts[i]))
    end
    if #hosts > 8 then add("+" .. tostring(#hosts - 7) .. " more") end
    add("--- probe ---")
    if state.target_ip then
        add("target " .. tostring(state.target_ip) .. " " .. tostring(state.target_port or "?"))
    else
        add("target none")
    end
    add(state.probe_line or "probe: idle")
    add("input " .. M.TARGET_PATH)
    if state.message and state.message ~= "" then add(state.message) end
    while #out < limit do out[#out + 1] = M.fit("", cols) end
    out[rows] = M.fit(status, cols)
    return out
end

function M.paint(lines, term_api)
    local t = term_api or rawget(_G, "term")
    if type(t) ~= "table" or type(t.setCursorPos) ~= "function"
        or type(t.write) ~= "function" then
        return false
    end
    local ok = pcall(function()
        for i = 1, #lines do
            t.setCursorPos(1, i)
            t.write(lines[i])
        end
    end)
    return ok
end

function M.view_size(term_api)
    local cols, rows = M.VIEW.cols, M.VIEW.rows
    local t = term_api or rawget(_G, "term")
    if type(t) == "table" and type(t.getSize) == "function" then
        local ok, w, h = pcall(t.getSize)
        if ok and type(w) == "number" and type(h) == "number" then
            cols = math.min(cols, math.max(1, math.floor(w)))
            rows = math.min(rows, math.max(1, math.floor(h)))
        end
    end
    return cols, rows
end

-- ---------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------

function M.run(manifest, api, opts)
    local o = opts or {}
    local state = M.new_state(o)
    state.manifest = manifest
    local frames = 0
    while true do
        local cols, rows = M.view_size(o.term)
        M.refresh(state, api)
        local lines = M.render(state, cols, rows)
        if o.paint ~= false then M.paint(lines, o.term) end
        if type(o.each) == "function" then pcall(o.each, state, lines) end
        frames = frames + 1
        if o.max_frames and frames >= o.max_frames then break end
        if api and type(api.yield) == "function" then api.yield() end
    end
    return state
end

-- DECISIONS.md 7.2 self test: no terminal, no service, pure layout rules
function M.selftest()
    local sample = M.new_state()
    sample.local_ip = "10.0.0.5"
    sample.prefix = 24
    sample.gateway = "10.0.0.1"
    sample.health = "ok"
    sample.hosts = { { name = "gw", text = "10.0.0.1" } }
    sample.target_ip = "10.0.0.9"
    sample.target_port = 9
    sample.probe_line = "probe: ok 0.01s"
    local problems = {}
    local lines = M.render(sample, M.VIEW.cols, M.VIEW.rows)
    if #lines ~= M.VIEW.rows then
        problems[#problems + 1] = "rows=" .. tostring(#lines)
    end
    for i = 1, #lines do
        if #lines[i] > M.VIEW.cols then
            problems[#problems + 1] = "row " .. tostring(i)
                .. " width " .. tostring(#lines[i])
        end
    end
    local bottom = lines[#lines] or ""
    if not bottom:find("net ok", 1, true) then
        problems[#problems + 1] = "status row missing"
    end
    local small = M.render(sample, 20, 10)
    if #small ~= 10 then
        problems[#problems + 1] = "small rows=" .. tostring(#small)
    end
    for i = 1, #small do
        if #small[i] > 20 then
            problems[#problems + 1] = "small row " .. tostring(i)
                .. " width " .. tostring(#small[i])
        end
    end
    return #problems == 0, problems
end

-- The app entry convention: the file returns the body function. A function
-- cannot carry fields, so the offline suite asks for the module table through a
-- flag (same convention as startup.lua's PYROET_STARTUP_TEST). Real boots never
-- set it.
M.layout_selftest = M.selftest

local function body(manifest, api)
    return M.run(manifest, api)
end

if rawget(_G, "PYROET_NET_APP_TEST") then
    return M
end

return body
