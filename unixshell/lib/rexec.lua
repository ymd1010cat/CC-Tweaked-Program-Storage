-- rexec.lua - run one command on another computer over the shared channel
--
-- Same transport as the file transfer and the package manager: serialized,
-- encrypted with the shared key from /etc/pkg.conf, sent on the configured
-- rednet protocol name. Only a peer that holds the key can produce a request
-- that decrypts, and every request is logged to the audit log on the machine
-- that runs it.
--
-- Request : {action="rexec", t="request", id, command, user, version, budget}
-- Reply   : {action="rexec", t="result", id, stdout, stderr, code, truncated,
--            elapsed, note}
--
-- The id belongs to the request and the reply echoes it, so an answer can be
-- matched to the request that asked for it. Without that pairing a LATE answer
-- to a previous request to the same peer (the requester had already timed out
-- and the peer's result arrived afterwards) was read as the answer to the NEXT
-- request: "rexec -t 2 echo two" printed the output of "echo one". Only a
-- refusal needs no command output to be visibly wrong, and a refusal is paired
-- here too. A peer that predates ids echoes none; that fallback is described at
-- answers() and rexec.serve().
--
-- Honest limits of the CraftOS terminal model (they matter on real hardware):
--   * a program's own error output goes through the same terminal as its
--     normal output, so "stdout" holds everything the program printed. The
--     "stderr" field carries the error text raised by the interpreter itself.
--   * there is no way to interrupt a running program: the timeout guards the
--     answer on the channel, not the execution. A command that never returns
--     keeps the daemon busy until it does; the budget is reported as a note.

local netcfg = require("netcfg")
local rpvnet  = require("rpvnet")

local rexec = {}

rexec.ACTION = "rexec"
rexec.MAX_COMMAND = 512
rexec.DEFAULT_WAIT = 30          -- seconds the requester waits for a reply
rexec.DEFAULT_BUDGET = 60        -- seconds a command is expected to take
rexec.MIN_BUDGET = 1             -- a peer cannot ask for an instant answer
rexec.MAX_BUDGET = 600           -- nor for an open ended wait

-- Bound a budget that arrived in a request, or that the local caller asked
-- for. nil means "no opinion": the caller then uses its own default.
function rexec.clamp_budget(value)
    local n = tonumber(value)
    if n == nil then return nil end
    if n < rexec.MIN_BUDGET then n = rexec.MIN_BUDGET end
    if n > rexec.MAX_BUDGET then n = rexec.MAX_BUDGET end
    return math.floor(n)
end

-- Request ids. The same shape lib/pkg.lua uses for its requests: the computer
-- id makes the number unique on the channel between machines, the counter makes
-- it unique between the requests one machine sends. A nonce would do the same
-- job; a counter is enough here because both ends of a
-- rexec exchange are the same two computers and the requester only ever holds
-- the ids it minted itself.
local request_seq = 0

local function next_request_id()
    request_seq = request_seq + 1
    return tostring(os.getComputerID()) .. "-" .. tostring(request_seq)
end

-- Is this result the answer to the request that carried `id`?
--
-- The id is authoritative when the answer carries one. A peer that predates ids
-- echoes none, and its answer is accepted as it always was -- that is the
-- compatibility fallback. It leaves this limit, stated rather than hidden: with
-- an id-less peer, TWO requests waiting at the same time on this computer
-- cannot be told apart, because nothing on the answer says which request it
-- belongs to; the first answer that arrives goes to whichever waiter sees it
-- first. Every peer built from this tree echoes ids, so the limit only exists
-- while an old daemon is still running on the other end.
local function answers(reply, id)
    if reply.id == nil then return true end
    return tostring(reply.id) == tostring(id)
end

-- ============================================================
-- Output capture
-- ============================================================

-- A terminal target for term.redirect: it keeps the text a program prints,
-- bounded by a limit so that a chatty program cannot exhaust the computer's
-- memory. Everything else the terminal interface asks for is a no-op.
local function make_buffer(limit)
    local buf = { chunks = {}, size = 0, truncated = false, limit = limit or 8192 }

    local function write(text)
        text = tostring(text)
        if buf.size >= buf.limit then
            buf.truncated = true
            return
        end
        local room = buf.limit - buf.size
        if #text > room then
            text = text:sub(1, room)
            buf.truncated = true
        end
        buf.size = buf.size + #text
        table.insert(buf.chunks, text)
    end

    local buffer = {
        write = write,
        writeLine = function(text) write(text or "") write("\n") end,
    }

    -- Terminal interface: the parts that matter keep state, the rest returns
    -- a plausible value so that programs using them keep working.
    local cursor_x, cursor_y = 1, 1
    local colour, background = colours and colours.white or 1, colours and colours.black or 1
    local blink = false

    buffer.getCursorPos = function() return cursor_x, cursor_y end
    buffer.setCursorPos = function(x, y) cursor_x, cursor_y = x or 1, y or 1 end
    buffer.getSize = function() return 51, 19 end
    buffer.clear = function() buf.chunks, buf.size = {}, 0 end
    buffer.clearLine = function() end
    buffer.scroll = function() end
    buffer.setTextColour = function(c) colour = c end
    buffer.setBackgroundColour = function(c) background = c end
    buffer.setTextColor = function(c) colour = c end
    buffer.setBackgroundColor = function(c) background = c end
    buffer.getTextColour = function() return colour end
    buffer.getBackgroundColour = function() return background end
    buffer.getTextColor = function() return colour end
    buffer.getBackgroundColor = function() return background end
    buffer.isColour = function() return true end
    buffer.isColor = function() return true end
    buffer.setCursorBlink = function(v) blink = v and true or false end
    buffer.getCursorBlink = function() return blink end
    buffer.blit = function(text, fg, bg) write(text) end
    buffer.setPaletteColour = function() end
    buffer.setPaletteColor = function() end
    buffer.nativePaletteColour = function() return 0 end

    buffer.text = function() return table.concat(buf.chunks) end
    buffer.is_truncated = function() return buf.truncated end
    return buffer
end

rexec.make_buffer = make_buffer

-- Run one command line locally and collect its output and exit status. The
-- unixshell interpreter is used when it is installed, so that built-ins, pipes
-- and the shell status behave exactly as they do in a session.
function rexec.execute(command, opts)
    opts = opts or {}
    local buffer = make_buffer(opts.max_output or netcfg.max_output())
    local started = os.epoch("utc")

    local previous
    local ok_redirect = pcall(function() previous = term.redirect(buffer) end)

    local ok, result = pcall(function()
        if fs.exists("/usr/ush.lua") then
            return shell.run("/usr/ush.lua", "-c", command)
        end
        return shell.run(command)
    end)

    if ok_redirect then pcall(term.redirect, previous) end

    local stdout = buffer.text()
    local stderr = ""
    local code = 0

    if not ok then
        stderr = tostring(result)
        code = 1
    elseif type(result) == "number" then
        code = result
    elseif result == false then
        code = 1
        if stdout:find("No such program", 1, true) or stdout:find("not found", 1, true) then
            code = 127
        end
    end

    local elapsed = (os.epoch("utc") - started) / 1000
    local note = nil
    local budget = tonumber(opts.budget) or rexec.DEFAULT_BUDGET
    if budget > 0 and elapsed > budget then
        note = string.format("command took %.1fs, over the %.0fs budget", elapsed, budget)
    end

    return {
        stdout = stdout,
        stderr = stderr,
        code = code,
        truncated = buffer.is_truncated(),
        elapsed = elapsed,
        note = note,
    }
end

-- ============================================================
-- Policy
-- ============================================================

-- opts.allow is either "all", "none", or a list of command names. The first
-- word of the command line is what gets checked.
function rexec.allowed(command, opts)
    local allow = opts and opts.allow
    if allow == nil or allow == "all" then return true end
    if allow == "none" then
        return false, "remote execution is disabled on this computer"
    end
    if type(allow) == "table" then
        local head = tostring(command):match("^%s*(%S+)") or ""
        for _, name in ipairs(allow) do
            if name == head then return true end
        end
        return false, "not allowed by the policy on this computer: " .. head
    end
    return false, "invalid policy"
end

function rexec.parse_allow(text)
    if text == nil or text == "" then return "all" end
    if text == "all" or text == "none" then return text end
    local list = {}
    for name in tostring(text):gmatch("[^,%s]+") do table.insert(list, name) end
    if #list == 0 then return "none" end
    return list
end

local function audit(entry)
    local ok, log = pcall(require, "audit")
    if ok and log and log.log then pcall(log.log, entry) end
end

-- ============================================================
-- Requester side
-- ============================================================

-- Run "opts.command" on "opts.target".
-- Returns true plus the result table, or nil plus a reason and an extra table
-- ({timeout=true} when the peer never answered).
function rexec.run(opts)
    if type(opts.command) ~= "string" or opts.command:match("^%s*$") then
        return nil, "no command given"
    end
    if #opts.command > rexec.MAX_COMMAND then
        return nil, "command too long (" .. #opts.command .. " of " .. rexec.MAX_COMMAND .. " characters)"
    end
    if opts.target == nil then return nil, "no target computer: use -t <id>" end
    local target, terr = netcfg.resolve_target(opts.target)
    if not target then return nil, terr, {} end

    local opened, oerr = netcfg.open()
    if not opened then return nil, oerr, {} end

    local id = next_request_id()
    local blob, perr = netcfg.pack({
        action = rexec.ACTION, t = "request", id = id, command = opts.command,
        user = opts.user, version = 1, budget = rexec.clamp_budget(opts.budget),
    })
    if not blob then return nil, perr, {} end

    local channel = netcfg.channel()
    local ok, sent = pcall(rpvnet.send, target, blob, channel)
    if not ok or sent == false then
        return nil, "could not reach computer " .. tostring(target), {}
    end

    -- One deadline for the whole wait. A message that is not this request's
    -- answer must not restart the budget, or a channel that keeps producing
    -- strays would keep this call alive for as long as they keep coming.
    local timeout = tonumber(opts.timeout) or rexec.DEFAULT_WAIT
    local deadline = os.epoch("utc") + timeout * 1000
    while true do
        local remain = (deadline - os.epoch("utc")) / 1000
        if remain <= 0 then
            return nil, string.format("no response from computer %s within %.0fs (is netd running there?)",
                tostring(target), timeout), { timeout = true }
        end
        local sender, reply_blob = rpvnet.receive(channel, remain)
        if sender ~= nil and (sender == target or target == nil) then
            local msg = netcfg.unpack(reply_blob)
            if msg and msg.action == rexec.ACTION and msg.t == "result" and
               answers(msg, id) then
                if msg.ok == false then
                    return nil, msg.reason or "peer refused the command", {}
                end
                return true, {
                    stdout = msg.stdout or "",
                    stderr = msg.stderr or "",
                    code = tonumber(msg.code) or 0,
                    truncated = msg.truncated and true or false,
                    elapsed = tonumber(msg.elapsed) or 0,
                    note = msg.note,
                    peer = sender,
                }
            end
            -- Not this request's answer: somebody else's result (an earlier
            -- request's, whose requester gave up waiting), or another message
            -- on the channel. Ignore it and keep waiting for the answer that
            -- carries this request's id.
        end
    end
end

-- ============================================================
-- Peer side (used by netd)
-- ============================================================

-- Every answer, the refusals included, echoes the id of the request it answers:
-- a requester that has already given up on a request must be able to tell that
-- answer apart from the one it is still waiting for. A requester old enough to
-- send no id gets no id back -- there is nothing to echo, and its own wait does
-- not look at the field, so it keeps working.
local function reply(sender, fields, request_id)
    fields.action = rexec.ACTION
    fields.t = "result"
    if request_id ~= nil then fields.id = request_id end
    local blob = netcfg.pack(fields)
    if blob then
        local ok = pcall(rpvnet.send, sender, blob, netcfg.channel())
        if not ok then return nil, "could not send the result back" end
    end
    return true, fields
end

function rexec.serve(sender, msg, opts)
    opts = opts or {}
    local command = msg.command
    if type(command) ~= "string" or command:match("^%s*$") then
        return reply(sender, { ok = false, reason = "empty command" }, msg.id)
    end

    local allowed, reason = rexec.allowed(command, opts)
    if not allowed then
        audit({ actor = "remote:" .. tostring(sender), action = "rexec",
                target = command, result = "denied", note = reason })
        return reply(sender, { ok = false, reason = reason }, msg.id)
    end

    -- The caller's budget wins over the daemon setting when it sent a usable
    -- one: whoever asked for the command knows best how long it should take.
    local exec_opts = {
        allow = opts.allow,
        max_output = opts.max_output,
        budget = rexec.clamp_budget(msg.budget) or tonumber(opts.budget),
    }
    local result = rexec.execute(command, exec_opts)
    audit({ actor = "remote:" .. tostring(sender), action = "rexec",
            target = command, result = "granted",
            note = string.format("exit %d in %.2fs", result.code, result.elapsed) })

    return reply(sender, {
        ok = true, stdout = result.stdout, stderr = result.stderr,
        code = result.code, truncated = result.truncated,
        elapsed = result.elapsed, note = result.note,
    }, msg.id)
end

return rexec
