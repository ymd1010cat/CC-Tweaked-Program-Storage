-- net_harness.lua - offline test rig for the network / data channel work of
-- the psh project (PC side assertions only, not a CraftOS-PC result).
--
-- It provides
--   * a bit32 shim when the host Lua lacks the library (test side only, the
--     project sources are never touched);
--   * a virtual clock driven through os.epoch, so timeouts and retransmissions
--     are exercised without waiting for real seconds;
--   * a rednet bus with per computer mailboxes, so a client and a server can
--     talk to each other inside one Lua state;
--   * a cooperative scheduler that runs client and daemon tasks until they
--     block, then moves the clock to the nearest deadline;
--   * terminal plumbing: everything the programs print is collected, and
--     term.redirect is implemented so the stdout capture of rexec works.
--
-- Load it after cc_env_stub.lua.

local H = {}
_G.__H = H

-- --------------------------------------------------------------- bit32 shim
if not rawget(_G, "bit32") then
    local M = 4294967296
    local function u32(x)
        x = math.floor(tonumber(x) or 0) % M
        if x < 0 then x = x + M end
        return x
    end
    -- band/bor/bxor are VARIADIC, like the real bit32: the SHA-256 compression
    -- function calls bxor(a, b, c) with three arguments, and a two-argument
    -- shim silently drops the third. That produced a digest which was stable,
    -- wrong, and passed every assertion that only asked "is it stable" -- so this
    -- shim is itself part of why the fake digest went unnoticed.
    local function fold2(x, y, op)
        local a, b = u32(x), u32(y)
        local r, bit = 0, 1
        for _ = 1, 32 do
            local xb, yb = a % 2, b % 2
            if op(xb, yb) == 1 then r = r + bit end
            a, b, bit = (a - xb) / 2, (b - yb) / 2, bit * 2
        end
        return r
    end
    local function variadic(op)
        return function(first, ...)
            local acc = u32(first)
            for i = 1, select("#", ...) do
                acc = fold2(acc, select(i, ...), op)
            end
            return acc
        end
    end
    local band = variadic(function(a, b) return (a == 1 and b == 1) and 1 or 0 end)
    local bor  = variadic(function(a, b) return (a == 1 or b == 1) and 1 or 0 end)
    local bxor = variadic(function(a, b) return (a ~= b) and 1 or 0 end)
    local function bnot(x) return M - 1 - u32(x) end
    local function lshift(x, n)
        n = tonumber(n) or 0
        if n >= 32 or n <= -32 then return 0 end
        if n >= 0 then return (u32(x) * 2 ^ n) % M end
        return math.floor(u32(x) / 2 ^ (-n))
    end
    local function rshift(x, n) return lshift(x, -(tonumber(n) or 0)) end
    local function arshift(x, n)
        n = tonumber(n) or 0
        local v = u32(x)
        if v >= M / 2 then v = v - M end
        if n >= 0 then
            v = math.floor(v / 2 ^ n)
        else
            v = v * 2 ^ (-n)
        end
        return u32(v)
    end
    local bit32 = {
        band = band, bor = bor, bxor = bxor, bnot = bnot,
        lshift = lshift, rshift = rshift, arshift = arshift,
        btest = function(a, b) return band(a, b) ~= 0 end,
        extract = function(x, f, w)
            f = tonumber(f) or 0
            w = tonumber(w) or 1
            return band(rshift(x, f), (2 ^ w - 1))
        end,
        replace = function(x, v, f, w)
            f = tonumber(f) or 0
            w = tonumber(w) or 1
            local mask = (2 ^ w - 1) * 2 ^ f
            return bor(band(x, bnot(mask)), band(lshift(v, f), mask))
        end,
    }
    _G.bit32 = bit32
end

-- ------------------------------------------------------------------ the bus
H.my_id = 5
H.me = H.my_id
H.now = 1000000          -- virtual milliseconds
H.mail = {}
H.sent = 0
H.tasks = {}
H.errors = {}
H.lines = {}
H.drop_fn = nil
H.stop = false
H.max_steps = 40000

local function box(id)
    local b = H.mail[id]
    if not b then b = {}; H.mail[id] = b end
    return b
end
H.box = box

-- A datagram that arrives wakes only the task that owns that mailbox, so a
-- task waiting for a message is never re-run before the clock advances.
function H.wake(id)
    for _, t in ipairs(H.tasks) do
        if t.id == id and t.state == "waiting" then t.state = "ready" end
    end
end

-- ------------------------------------------------------------ virtual clock
os.epoch = function(kind) return H.now end
H.advance = function(sec) H.now = H.now + math.floor((tonumber(sec) or 0) * 1000) end

-- ------------------------------------------------------------- terminal sink
local redirect = nil
local base_write = term.write
term.redirect = function(t)
    local prev = redirect
    redirect = t
    return prev
end
local function emit(text)
    text = tostring(text)
    if redirect and redirect.write then
        redirect.write(text)
    else
        H.lines[#H.lines + 1] = text
    end
end
term.write = emit
H.out = emit
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    emit(table.concat(parts, "\t") .. "\n")
end
_G.io.write = emit
_G.write = emit

H.text = function() return table.concat(H.lines) end
H.clear = function() H.lines = {} end

-- A "stage" as psh hands it to an external command: _out collects the output.
H.stage = function()
    local buf = {}
    return {
        _out = {
            write = function(text) buf[#buf + 1] = tostring(text) end,
        },
        text = function() return table.concat(buf) end,
    }
end

function H.read(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

function H.write(path, text)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

function H.exists(path) return fs.exists(path) end

-- ------------------------------------------------------------------ rednet
rednet = rednet or {}
rednet.open = function(side)
    if not side then error("rednet: no side", 0) end
    H.opened = true
end
rednet.close = function() H.opened = false end
rednet.isOpen = function(side) return H.opened == true end

-- ------------------------------------------------------------------- wire log
-- Every datagram that goes on the wire, in order, with the direction and the
-- decoded body when it can be decoded. rednet.send is handed the packed blob,
-- so the raw datagram is available for BOTH directions -- including the peer's
-- own replies, which a test body never sees as a decoded message. A loss
-- predicate can therefore name a control message ("hold the peer's ready") and
-- an assertion can afterwards point at the datagram it held.
--
-- Each entry: { at, seq, from, to, protocol, blob, msg }
--   at    virtual milliseconds (H.now)
--   seq   1-based index on the wire, so a test can say "the 3rd datagram"
--   msg   the decoded table, or nil when the blob does not decode
H.wire = {}
H.wire_seq = 0

function H.record_wire(from, to, protocol, blob)
    H.wire_seq = H.wire_seq + 1
    local entry = { at = H.now, seq = H.wire_seq, from = from, to = to,
                    protocol = protocol, blob = blob }
    if H.decode then
        local ok, msg = pcall(H.decode, blob)
        if ok and type(msg) == "table" then entry.msg = msg end
    end
    H.wire[#H.wire + 1] = entry
    return entry
end

function H.wire_clear()
    H.wire = {}
    H.wire_seq = 0
end

-- Datagrams matching pred(entry), in wire order.
function H.wire_matching(pred)
    local out = {}
    for _, entry in ipairs(H.wire) do
        if pred(entry) then out[#out + 1] = entry end
    end
    return out
end

-- A predicate for H.wire_matching / H.delay that names a decoded message field,
-- in either direction: H.by_t("ready"), H.by_msg({ t = "chunk", seq = 2 }).
function H.by_t(t)
    return function(entry)
        return entry.msg ~= nil and entry.msg.t == t
    end
end

function H.by_msg(want)
    return function(entry)
        local msg = entry.msg
        if not msg then return false end
        for k, v in pairs(want) do
            if msg[k] ~= v then return false end
        end
        return true
    end
end

rednet.send = function(target, message, protocol)
    H.sent = H.sent + 1
    if type(target) ~= "number" or target <= 0 then return false end
    local from = H.me or H.my_id
    local entry = H.record_wire(from, target, protocol, message)
    if H.drop_fn and H.drop_fn(from, target, message, protocol) then
        entry.dropped = true
        return true          -- dropped on the wire, the sender is not told
    end
    if H.delay_fn then
        local hold = H.delay_fn(from, target, message, protocol)
        if hold and hold > 0 then
            -- held on the wire: it arrives after the delay, so the receiver can
            -- see a hole and ask for the block again
            entry.held = hold
            table.insert(H.held, { at = H.now + math.floor(hold * 1000), target = target,
                                   from = from, blob = message, protocol = protocol,
                                   entry = entry })
            return true
        end
    end
    table.insert(box(target), { from = from, blob = message, protocol = protocol })
    H.wake(target)
    return true
end

rednet.broadcast = function(message, protocol)
    H.sent = H.sent + 1
    local from = H.me or H.my_id
    for id in pairs(H.mail) do
        if id ~= from then
            table.insert(box(id), { from = from, blob = message, protocol = protocol })
            H.wake(id)
        end
    end
    return true
end

-- Returns sender, blob (like CraftOS) or nil when the wait ran out.
rednet.receive = function(protocol, timeout)
    local deadline
    if timeout ~= nil then deadline = H.now + math.max(0, tonumber(timeout) or 0) * 1000 end
    while true do
        local b = box(H.me)
        if #b > 0 then
            local item = table.remove(b, 1)
            if protocol == nil or item.protocol == nil or item.protocol == protocol then
                return item.from, item.blob
            end
        elseif deadline ~= nil and H.now >= deadline then
            return nil
        else
            coroutine.yield("block", deadline)
        end
    end
end

-- -------------------------------------------------------------- shell.run
H.runs = {}
H.shell_run = nil
shell.run = function(...)
    local args = { ... }
    if #args == 1 and type(args[1]) == "table" then args = args[1] end
    local line = table.concat(args, " ")
    H.runs[#H.runs + 1] = line
    if H.shell_run then return H.shell_run(line) end
    print("(peer) " .. line)
    return true
end

-- ----------------------------------------------------------- scheduler
local wake_done = false

local function resume_one()
    for _, t in ipairs(H.tasks) do
        if t.state == "ready" then
            t.state = "running"
            H.me = t.id
            local ok, res, extra = coroutine.resume(t.co)
            if not ok then
                t.state = "dead"
                t.error = tostring(res)
                H.errors[#H.errors + 1] = t.name .. ": " .. tostring(res)
            elseif coroutine.status(t.co) == "dead" then
                t.state = "dead"
            elseif res == "block" then
                t.blocked = extra
                t.state = H.stop and "dead" or "waiting"
            else
                t.state = "ready"
            end
            wake_done = false
            return true
        end
    end
    return false
end

local function wake_all()
    local n = 0
    for _, t in ipairs(H.tasks) do
        if t.state == "waiting" then t.state = "ready"; n = n + 1 end
    end
    return n
end

local function jump_to_deadline()
    local best
    for _, t in ipairs(H.tasks) do
        if t.state == "waiting" and t.blocked and (best == nil or t.blocked < best) then
            best = t.blocked
        end
    end
    -- a datagram held on the wire is a deadline too: advance to it and deliver
    local held = H.next_held_at and H.next_held_at() or nil
    if held and (best == nil or held < best) then best = held end
    if best == nil then return false end
    if best > H.now then H.now = best end
    if H.release_held then H.release_held() end
    wake_all()
    wake_done = false
    return true
end

local function step_once()
    if resume_one() then return "ran" end
    if jump_to_deadline() then return "jump" end
    return "stuck"
end

function H.spawn(id, fn, name)
    local t = { id = id, name = name or ("task-" .. tostring(id)), state = "ready" }
    t.co = coroutine.create(function() t.status = fn() end)
    H.tasks[#H.tasks + 1] = t
    if H.delay_fn then
        -- the test wants this peer's inbound traffic held, so the task has to be
        -- driven on a timer rather than woken by an arriving datagram
        t.state = "waiting"
        t.blocked = H.now + 250
    end
    return t
end

function H.run(target)
    local steps = 0
    while true do
        if target == nil then
            local alive = false
            for _, t in ipairs(H.tasks) do
                if t.state ~= "dead" then alive = true end
            end
            if not alive then return true end
        elseif target.state == "dead" then
            return true
        end
        local what = step_once()
        if what == "stuck" then
            if H.stop then return true end
            H.stuck = true
            return false
        end
        steps = steps + 1
        if steps > H.max_steps then
            H.stuck = true
            return false
        end
    end
end

-- Run tasks until `target` blocks on the network, then stop. H.run() would keep
-- going to the task's deadline, which for a requester that is waiting for an
-- answer means running it to a timeout. This is how a test gets a requester to
-- the point where its request is on the wire and it is waiting for the reply.
function H.run_until_blocked(target)
    local steps = 0
    while target.state ~= "dead" and target.state ~= "waiting" do
        local what = step_once()
        if what == "stuck" then return false end
        steps = steps + 1
        if steps > H.max_steps then return false end
    end
    return target.state == "waiting"
end

-- Stop every background task (daemons) so the run can end.
function H.freeze()
    H.stop = true
    wake_all()
end

-- Run one command task to completion, then return its exit status.
function H.exec(id, fn, name)
    local t = H.spawn(id, fn, name)
    local ok = H.run(t)
    return t.status, ok
end

-- Run a function that talks on the network to completion, from inside a test.
--
-- This is the "re-entrant pump" ROADMAP 1.3 asks for, and it is only a name for
-- what H.spawn + H.run already do: a test body is NOT a coroutine, so calling a
-- network function from it dies with "attempt to yield from outside a
-- coroutine". Spawning the call as a harness task puts it in one, and H.run
-- then drives it to completion -- the daemon's own coroutine keeps running
-- meanwhile, because the scheduler interleaves every task.
--
--   local ok, err = H.pump(5, function() return xfer.serve_pending(opts) end, "drain")
--
-- Returns the function's return value(s) (nil plus the error when it raised).
function H.pump(id, fn, name)
    local t = H.spawn(id, fn, name)
    H.run(t)
    if t.state == "dead" and t.error then return nil, t.error end
    return t.status, nil
end

-- -------------------------------------------------------------- daemon
-- Mirrors what netd.lua does with a request: dispatch on msg.action.
function H.daemon(id, opts)
    opts = opts or {}
    local wait = opts.wait or 5
    local netcfg = _G.netcfg or require("netcfg")
    local xfer = _G.xfer or require("xfer")
    local rexec = _G.rexec or require("rexec")
    return function()
        while not H.stop do
            local sender, blob = rednet.receive(netcfg.channel(), wait)
            if sender then
                local msg = netcfg.unpack(blob)
                if msg then
                    if msg.action == xfer.ACTION then
                        xfer.serve(sender, msg, opts.xfer or {})
                    elseif msg.action == rexec.ACTION then
                        rexec.serve(sender, msg, opts.rexec or {})
                    elseif opts.pkg then
                        opts.pkg(sender, msg)
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------ computer identity
-- The scheduler switches H.me to the id of the running task, so every task
-- (daemon or client) sees its own rednet mailbox and its own computer id.
H.computers = {}
H.next_id = 100
function H.new_computer(role)
    local id = H.next_id
    H.next_id = id + 1
    local c = { id = id, role = role or "client" }
    H.computers[id] = c
    return c
end
os.getComputerID = function() return H.me or H.my_id end

-- Drop datagrams on the wire; the sender is not told (used to force resends).
function H.drop(pred) H.drop_fn = pred end

-- Delay datagrams instead of dropping them: the receiver sees a hole, asks for
-- the missing block, and the held copy arrives later. Timeouts and retransmission
-- run on the virtual clock, so a delay costs no real time.
--
-- Two shapes are accepted, because both read naturally at a call site:
--
--   H.delay(pred, seconds)   every datagram pred matches is held for `seconds`
--   H.delay(pred)            the same, held for the default 1 s
--
-- A predicate that returns a number does NOT set the duration: the duration is
-- the second argument, and the wrapper below is the only place it is read. (An
-- earlier version let the predicate's return value through, so a call that
-- returned 1.5 was silently held for 1 s instead. The existing loss runs passed
-- either way, which is exactly why the bug went unnoticed -- a hole opened is a
-- hole opened. Use the second argument.)
--
-- pred(from, target, message, protocol) -> truthy to hold. `message` is the raw
-- packed datagram, so a predicate may decode it (see H.decode) or match on
-- direction alone. Either way the datagram is in H.wire for an assertion.
H.held = {}
H.delay_fn = nil
function H.delay(pred, seconds)
    if pred == nil then
        H.delay_fn = nil
        return
    end
    local hold = tonumber(seconds) or 1
    H.delay_fn = function(from, target, message, protocol)
        if pred(from, target, message, protocol) then
            return hold
        end
        return nil
    end
end

local function release_held()
    local n = 0
    local i = 1
    while i <= #H.held do
        local item = H.held[i]
        if item.at <= H.now then
            table.remove(H.held, i)
            table.insert(box(item.target), { from = item.from, blob = item.blob,
                                             protocol = item.protocol })
            H.wake(item.target)
            n = n + 1
        else
            i = i + 1
        end
    end
    return n
end

local function next_held_at()
    local best
    for _, item in ipairs(H.held) do
        if best == nil or item.at < best then best = item.at end
    end
    return best
end

H.release_held = release_held
H.next_held_at = next_held_at

return H
