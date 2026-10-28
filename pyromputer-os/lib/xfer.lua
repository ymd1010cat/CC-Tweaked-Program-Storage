-- xfer.lua - chunked file transfer over the shared rednet channel
--
-- The protocol reuses what the rest of the system already speaks: the rednet
-- protocol name from /etc/pkg.conf, and the same shared key, so a payload is
-- serialized and encrypted with lib/crypto.lua exactly like a package request
-- (see lib/pkg.lua).
--
-- Conversation, one file at a time:
--
--   requester                                   peer
--   ---------------------------------------------------------------
--   req   {op="put"|"get", name, path, ...} -->
--                                             <--  ready {size, chunk,
--                                                  chunks, crc, name}
--   chunk {seq, crc, data}                  -->
--                                             <--  ack  {seq}
--   ...                                       (missing {list} when a hole
--                                              is detected, answered with a
--                                              resend of those chunks)
--   done  {crc, size}                       -->
--                                             <--  result {ok, reason, path}
--
-- Every message carries a CRC32: one per chunk (retransmitted when it does not
-- match) and one for the whole file, which the receiver recomputes from the
-- assembled body before the file is written. Both directions use the same
-- chunk/ack conversation, so a push and a pull share the same code path.

local netcfg   = require("netcfg")
local rpvnet  = require("rpvnet")
local checksum = require("checksum")
local mounts   = require("mounts")
-- Room for the file, asked before the first block is accepted (see the three
-- landing sites: pull, listen and serve). The receiver knows the whole size in
-- the ready/request message, which is earlier than the protocol's own ending --
-- so a transfer that cannot fit is refused before a byte reaches the disk,
-- instead of filling the volume and then failing the whole-file checksum.
local space    = require("space")

local xfer = {}

xfer.ACTION = "rfile"
xfer.MIN_CHUNK = 64
xfer.MAX_CHUNK = 32768
xfer.DEFAULT_TOTAL_TIMEOUT = 300   -- seconds for a whole transfer

-- ============================================================
-- Base64 (keeps chunk bodies ASCII inside the serialized message)
-- ============================================================

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_encode(data)
    local out = {}
    local n = #data
    for i = 1, n, 3 do
        local a = string.byte(data, i) or 0
        local b = string.byte(data, i + 1) or 0
        local c = string.byte(data, i + 2) or 0
        local group = a * 65536 + b * 256 + c
        local c1 = math.floor(group / 262144) % 64
        local c2 = math.floor(group / 4096) % 64
        local c3 = math.floor(group / 64) % 64
        local c4 = group % 64
        local pad = n - i + 1
        table.insert(out, B64:sub(c1 + 1, c1 + 1))
        table.insert(out, B64:sub(c2 + 1, c2 + 1))
        table.insert(out, pad > 1 and B64:sub(c3 + 1, c3 + 1) or "=")
        table.insert(out, pad > 2 and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

local b64_index = {}
for i = 1, #B64 do b64_index[B64:sub(i, i)] = i - 1 end

local function b64_decode(text)
    if type(text) ~= "string" then return nil end
    local out = {}
    local acc, bits = 0, 0
    for i = 1, #text do
        local ch = text:sub(i, i)
        local value = b64_index[ch]
        if value then
            acc = acc * 64 + value
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(acc / (2 ^ bits)) % 256
                table.insert(out, string.char(byte))
                -- Keep only the bits that are still pending. An accumulator
                -- that is never trimmed grows past the range where a double
                -- still holds every integer, and the bytes derived from it are
                -- then wrong, or out of range for string.char.
                acc = acc % (2 ^ bits)
            end
        elseif ch == "=" then
            break
        else
            return nil
        end
    end
    return table.concat(out)
end

xfer.base64_encode = b64_encode
xfer.base64_decode = b64_decode

-- ============================================================
-- Paths
-- ============================================================

local function basename(path)
    local name = tostring(path):match("([^/]+)$")
    return name or tostring(path)
end

xfer.basename = basename

-- A name that arrives over the network is never trusted with a directory
-- part: it may only name a file inside the directory the receiver picked.
local function safe_name(name)
    local clean = tostring(name or ""):gsub("\\", "/")
    clean = clean:match("([^/]+)$") or ""
    clean = clean:gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" or clean == "." or clean == ".." then return nil end
    return clean
end

local function has_traversal(path)
    for part in tostring(path):gmatch("[^/]+") do
        if part == ".." then return true end
    end
    return false
end

local function normalize(path)
    local cwd = require("cwd")
    local ok, abs = pcall(cwd.resolve, path)
    if not ok or type(abs) ~= "string" then return nil, "invalid path: " .. tostring(path) end
    return abs
end

-- Destination check for anything that is about to be written: no upward
-- traversal, stay inside the allowed root, honour a read-only mount and the
-- permission records, exactly as the filesystem built-ins do.
local function check_destination(path, opts, root)
    if has_traversal(path) then
        return nil, "refusing path traversal: " .. path
    end
    if root and path:sub(1, #root) ~= root then
        return nil, "destination outside " .. root .. ": " .. path
    end
    if mounts.is_readonly(path) then
        return nil, path .. ": read-only file system"
    end
    local ok, allowed = pcall(require("perm").can_write, path)
    if ok and allowed == false then
        return nil, path .. ": permission denied"
    end
    return true
end

local function ensure_parent(path)
    local dir = path:match("^(.*)/[^/]*$")
    if not dir or dir == "" or fs.exists(dir) then return end
    fs.makeDir(dir)
end

-- ============================================================
-- Channel helpers
-- ============================================================

local function opened()
    if rpvnet.isOpen and rpvnet.isOpen() then return true end
    return netcfg.open()
end

-- Milliseconds on the wall clock. Declared here, above every user, because a Lua
-- local that is used as an upvalue before its declaration is a GLOBAL nil (silently):
-- the early-block buffer below stamps entries with it, so it has to come first.
local function now_ms() return os.epoch("utc") end

-- Requests that arrived while one was being served.
--
-- xfer.serve() answers one request and runs to completion before it returns, so a driver
-- answers one request at a time (netd does, and so do the acceptance peers). A client that
-- sends its next request during that window used to have it dropped on the floor: measured
-- on real hardware, a push request was lost exactly that way while the peer was still
-- finishing the previous pull, the client waited out its request timeout, and the peer then
-- reported every chunk of that transfer missing.
--
-- Nothing here is a protocol change: the waiting loops below hand a request they see to
-- this queue instead of ignoring it, and a driver serves what is queued (see
-- xfer.serve_pending) before it goes back to waiting for the next one.
local pending_requests = {}

local function stash_request(sender, msg)
    if type(msg) ~= "table" then return false end
    if not (msg.op == "put" or msg.op == "get") then return false end
    pending_requests[#pending_requests + 1] = { sender = sender, msg = msg }
    return true
end

-- Blocks that arrived before the transfer they belong to was accepted.
--
-- A push no longer waits for the peer's `ready`: the requester sends its request and
-- the first block straight away (see xfer.send). That opens a window the old protocol
-- did not have -- while the peer is still finishing the PREVIOUS transfer, both the
-- request and that first block arrive. The request is queued (above); the block is not
-- a request, so without this buffer it would be discarded, and the peer would then ask
-- for block 1 again. Holding it here costs nothing and saves a round trip.
--
-- Keyed by sender, because a block is only meaningful to the transfer it came with.
-- Entries are handed to stream_receive when it starts for that sender; a sender whose
-- transfer never starts is bounded by MAX_EARLY_BLOCKS and by age, so a stray block
-- cannot accumulate or leak into a later transfer.
local early_blocks = {}
local MAX_EARLY_BLOCKS = 8
local EARLY_BLOCK_TTL = 60      -- seconds

local function stash_block(sender, msg)
    if type(msg) ~= "table" then return false end
    if msg.t ~= "chunk" or type(msg.seq) ~= "number" then return false end
    local box = early_blocks[sender]
    if not box then box = {}; early_blocks[sender] = box end
    box[#box + 1] = { seq = msg.seq, crc = msg.crc, data = msg.data, at = now_ms() }
    while #box > MAX_EARLY_BLOCKS do table.remove(box, 1) end
    return true
end

-- Take the buffered blocks for one sender, dropping anything stale. The caller
-- (stream_receive) installs them before it waits for anything.
local function take_early_blocks(sender)
    local box = early_blocks[sender]
    early_blocks[sender] = nil
    if not box then return {} end
    local now = now_ms()
    local out = {}
    for _, item in ipairs(box) do
        if now - (item.at or now) <= EARLY_BLOCK_TTL * 1000 then out[#out + 1] = item end
    end
    return out
end

function xfer.early_blocks_pending(sender)
    local box = early_blocks[sender]
    return box and #box or 0
end

-- Drop whatever is buffered for one sender. stream_receive calls this when its
-- transfer ends: blocks that arrive DURING a transfer are late retries of that same
-- transfer, and leaving them there would let them leak into the sender's NEXT
-- transfer (the sequence numbers restart at 1, so a stale block 1 would be offered to
-- a file it does not belong to -- the CRC would reject it, but the round trip is
-- wasted and the trace reads as a mystery).
local function drop_early_blocks(sender)
    early_blocks[sender] = nil
end

function xfer.clear_early_blocks()
    early_blocks = {}
end

-- A block that outran its request, offered to the buffer. Not part of the public
-- API; the suites use it to check what is absorbed and what is not.
function xfer.test_stash_block(sender, msg)
    return stash_block(sender, msg)
end

-- The next request that arrived while one was being served, or nil.
function xfer.next_request()
    return table.remove(pending_requests, 1)
end

-- How many requests are waiting.
function xfer.pending_requests()
    return #pending_requests
end

-- Forget anything queued. A driver calls this when it starts, so a previous run cannot be
-- served again.
function xfer.clear_requests()
    pending_requests = {}
end

-- Queue a request by hand. Not part of the public API: the suites use it to check the
-- queue's own rules (what counts as a request, and that the drain takes each one once)
-- without racing a transfer against the virtual clock.
function xfer.test_stash(sender, msg)
    return stash_request(sender, msg)
end

-- Serve everything that was queued while a transfer was running, oldest first. A driver
-- calls this after every request it serves:
--
--     local served = xfer.serve(sender, msg, opts)
--     xfer.serve_pending(opts)
--
-- Returns how many queued requests were served. One that fails is reported and the next
-- one is still served: a client that gave up must not block the requests behind it.
function xfer.serve_pending(opts)
    local served = 0
    while true do
        local item = xfer.next_request()
        if not item then return served end
        local ok, info = xfer.serve(item.sender, item.msg, opts)
        served = served + 1
        if opts and opts.on_served then opts.on_served(item.sender, item.msg, ok, info) end
        if not ok then
            local mod = opts and opts.report
            if mod then mod(string.format("queued request from %s failed: %s",
                                          tostring(item.sender), tostring(info))) end
        end
    end
end

local function send_message(peer, msg)
    local blob, err = netcfg.pack(msg)
    if not blob then return nil, err end
    local ok, sent = pcall(rpvnet.send, peer, blob, netcfg.channel())
    if not ok or sent == false then
        return nil, "could not reach computer " .. tostring(peer)
    end
    return true
end

-- Wait for one matching message. Returns the message plus the sender, or nil
-- plus a reason. Messages from other computers or that do not decrypt are
-- skipped; the wait still honours the original deadline.
--
-- opts.stash (the peer side) queues a request that arrives while we wait for something
-- else, instead of dropping it; the requester side leaves it off.
--
-- The stash is deliberately NOT restricted to the computer being served. It used to
-- be: the sender test wrapped the whole branch, so while the peer served client A, a
-- request from client B was filtered out and lost -- the same bug 1.1 fixed, one
-- client further out. Only the ANSWER is restricted to opts.peer (it is that peer's
-- reply that this wait is for); a REQUEST from anyone is worth queueing, because the
-- driver serves one transfer at a time and will drain the queue afterwards.
local function wait_message(opts, filter)
    local deadline = os.epoch("utc") + (opts.timeout or netcfg.timeout()) * 1000
    local channel = netcfg.channel()
    while true do
        local remain = (deadline - os.epoch("utc")) / 1000
        if remain <= 0 then return nil, "timeout" end
        local sender, blob = rpvnet.receive(channel, remain)
        if sender == nil then return nil, "timeout" end
        local msg = netcfg.unpack(blob)
        if msg and msg.action == xfer.ACTION then
            if (sender == opts.peer or opts.peer == nil) and filter(msg) then
                return msg, sender
            elseif opts.stash then
                -- a request from any computer goes on the queue; anything that is
                -- not a request is offered to the early-block buffer, so a block
                -- that outran its request is kept instead of discarded
                if not stash_request(sender, msg) then
                    stash_block(sender, msg)
                end
            end
        end
    end
end

local function cwd_path()
    local ok, cwd = pcall(require, "cwd")
    if ok and cwd.get then return cwd.get() end
    return "/"
end

-- ============================================================
-- Progress reporting
-- ============================================================

-- Build a progress printer: one line per 10% step, plus a final line. The
-- callback shape is fn(done_bytes, total_bytes, done_chunks, total_chunks).
function xfer.make_progress(printer, label)
    local last_bucket = -1
    local started = now_ms()
    return function(done, total, done_chunks, total_chunks)
        local percent = total > 0 and math.floor(done * 100 / total) or 100
        local bucket = math.floor(percent / 10)
        if bucket == last_bucket and done < total then return end
        last_bucket = bucket
        local elapsed = (now_ms() - started) / 1000
        local rate = elapsed > 0 and (done / elapsed) or 0
        printer(string.format("%s %3d%% (%d/%d bytes, %d/%d chunks, %.1f B/s)",
            label or "transfer", percent, done, total,
            done_chunks or 0, total_chunks or 0, rate))
    end
end

-- ============================================================
-- Chunked conversation
-- ============================================================

local function split_chunks(body, size)
    local chunks = {}
    local i = 1
    while i <= #body do
        table.insert(chunks, body:sub(i, i + size - 1))
        i = i + size
    end
    return chunks
end

xfer.split_chunks = split_chunks

-- Sender side of the chunk/ack conversation. Returns true, or nil plus a
-- reason; "stats" collects the retransmission counters.
--
-- opts.trace is an optional function called at every state change of this loop:
-- the wire can be captured (rpvnet does that), but only the sender knows which branch
-- of the conversation it took, and that is what a stalled push needs to be read from.
--
-- opts.opener is the push's first block, already on the wire and already answered:
-- { seq = n, reply = <the ack/missing it got back> }. When it is present the first
-- iteration uses that answer instead of sending the block again, which is what keeps
-- the block from going out twice. Everything below the send/wait pair -- the hole
-- list, the silence retry, the give-up -- is deliberately untouched: a previous
-- attempt at this fix restructured them and regressed the pull.
local function stream_send(peer, meta, body, opts, progress)
    local chunks = meta.chunks_data
    local total = #body
    local acked = 0
    local attempts = 0
    local resends = 0
    local retries = opts.retries or netcfg.retries()
    local opener = opts.opener
    local function trace(fmt, ...)
        if opts.trace then opts.trace(string.format(fmt, ...)) end
    end

    trace("send start chunks=%d bytes=%d retries=%d timeout=%s", #chunks, total, retries,
          tostring(opts.timeout))

    while acked < #chunks do
        local seq = acked + 1
        local payload = chunks[seq]
        local reply
        if opener and tonumber(opener.seq) == seq then
            -- This block went out with the request. Its answer is already in hand, so
            -- it must not be sent again here; the recovery branches below still apply
            -- to it if the answer was a hole list.
            reply = opener.reply
            opener = nil
            trace("chunk %d/%d was sent with the request; answer=%s", seq, #chunks,
                  reply and tostring(reply.t) or "none")
        else
            trace("sending chunk %d/%d bytes=%d attempt=%d", seq, #chunks, #payload,
                  attempts + 1)
            local ok, err = send_message(peer, {
                action = xfer.ACTION, t = "chunk", seq = seq,
                crc = checksum.crc32(payload), data = b64_encode(payload),
            })
            if not ok then
                trace("chunk %d could not be sent: %s", seq, tostring(err))
                return nil, err
            end

            reply = wait_message(opts, function(m)
                -- Only an answer to THIS block counts: a stale ack for a block that
                -- was already accepted (the receiver re-acks duplicates, and a hole
                -- list is answered with a burst of blocks, so several acks can be in
                -- flight at once) must not be mistaken for "no answer" and spend a
                -- retry. Skipping it here keeps the loop below exactly as it was.
                return m.t == "missing" or
                       (m.t == "ack" and tonumber(m.seq) == seq)
            end)
            trace("chunk %d answer=%s seq=%s list=%s", seq,
                  reply and tostring(reply.t) or "none",
                  reply and tostring(reply.seq) or "-",
                  reply and tostring(#(reply and reply.list or {})) or "-")
        end

        if reply and reply.t == "ack" and tonumber(reply.seq) == seq then
            acked = seq
            attempts = 0
            local done_bytes = 0
            for i = 1, acked do done_bytes = done_bytes + #chunks[i] end
            if progress then progress(done_bytes, total, acked, #chunks) end
        elseif reply and reply.t == "missing" then
            -- The receiver found holes: answer with those chunks only.
            attempts = attempts + 1
            resends = resends + 1
            trace("missing list of %d answered (attempt %d/%d)", #(reply.list or {}),
                  attempts, retries)
            for _, want in ipairs(reply.list or {}) do
                local index = tonumber(want)
                if index and index >= 1 and index <= #chunks then
                    trace("resending chunk %d because the receiver asked for it", index)
                    send_message(peer, {
                        action = xfer.ACTION, t = "chunk", seq = index,
                        crc = checksum.crc32(chunks[index]),
                        data = b64_encode(chunks[index]),
                    })
                end
            end
        else
            -- No acknowledgement in time: the block goes on the wire again,
            -- and that is what the counters reported to the caller mean.
            attempts = attempts + 1
            resends = resends + 1
            trace("no answer for chunk %d (attempt %d/%d)", seq, attempts, retries)
        end

        if attempts > retries then
            trace("gave up on chunk %d after %d retries", seq, retries)
            return nil, "no acknowledgement for chunk " .. seq ..
                        " after " .. retries .. " retries"
        end
    end

    trace("all %d chunks acknowledged, sending done", #chunks)
    local ok, err = send_message(peer, {
        action = xfer.ACTION, t = "done", crc = meta.crc, size = total,
    })
    if not ok then return nil, err end

    -- The receiver reports whether the file reached the disk.
    local result = wait_message(opts, function(m) return m.t == "result" end)
    if not result then
        trace("no result from the receiver")
        return nil, "no result from the receiver (the file may still have been written)"
    end
    trace("result ok=%s reason=%s", tostring(result.ok), tostring(result.reason))
    if result.ok ~= true then
        return nil, result.reason or "receiver rejected the file"
    end
    return true, { resends = resends, remote = result.path }
end

-- Receiver side of the chunk/ack conversation. Returns the reassembled body,
-- or nil plus a reason.
local function stream_receive(peer, meta, opts, progress)
    local total_chunks = tonumber(meta.chunks) or 0
    local timeout = opts.timeout or netcfg.timeout()
    local retries = opts.retries or netcfg.retries()
    local chunks = {}
    local received = 0
    local requests = 0
    local saw_done = nil
    local deadline = now_ms() + (opts.total_timeout or xfer.DEFAULT_TOTAL_TIMEOUT) * 1000
    local function trace(fmt, ...)
        if opts.trace then opts.trace(string.format(fmt, ...)) end
    end

    trace("receive start chunks=%d bytes=%s retries=%d timeout=%s", total_chunks,
          tostring(meta.size), retries, tostring(timeout))

    local function holes()
        local list = {}
        for i = 1, total_chunks do
            if not chunks[i] then table.insert(list, i) end
        end
        return list
    end

    -- Blocks that arrived before this transfer started: the push sends block 1 with
    -- its request, so by the time the peer got here that block may already be sitting
    -- in the early-block buffer. Install them first, and acknowledge them the way the
    -- normal path does -- the sender is waiting for an ack, not for a `ready`.
    local early = take_early_blocks(peer)
    for _, item in ipairs(early) do
        local seq = tonumber(item.seq)
        if seq and seq >= 1 and seq <= total_chunks and not chunks[seq] then
            local body = b64_decode(item.data)
            if body and checksum.crc32(body) == tonumber(item.crc) then
                chunks[seq] = body
                received = received + 1
                trace("early chunk %d accepted from before the request", seq)
                send_message(peer, { action = xfer.ACTION, t = "ack", seq = seq })
            else
                trace("early chunk %d did not survive its checksum, asking again", seq)
                send_message(peer, { action = xfer.ACTION, t = "missing", list = { seq } })
            end
        end
    end

    while received < total_chunks do
        if now_ms() > deadline then
            trace("deadline reached with %d/%d received", received, total_chunks)
            return nil, "transfer timed out"
        end

        local msg, reason = wait_message(opts, function(m)
            return m.t == "chunk" or m.t == "done"
        end)
        trace("receive got t=%s seq=%s reason=%s", msg and tostring(msg.t) or "none",
              msg and tostring(msg.seq) or "-", tostring(reason))

        if msg and msg.t == "done" then
            saw_done = msg
        elseif msg and msg.t == "chunk" then
            local seq = tonumber(msg.seq)
            if seq and seq >= 1 and seq <= total_chunks and not chunks[seq] then
                local body = b64_decode(msg.data)
                if body and checksum.crc32(body) == tonumber(msg.crc) then
                    chunks[seq] = body
                    received = received + 1
                    send_message(peer, { action = xfer.ACTION, t = "ack", seq = seq })
                    local done_bytes = 0
                    for i = 1, total_chunks do
                        if chunks[i] then done_bytes = done_bytes + #chunks[i] end
                    end
                    if progress then progress(done_bytes, tonumber(meta.size) or 0,
                                             received, total_chunks) end
                else
                    requests = requests + 1
                    trace("chunk %d failed its checksum (request %d/%d)", seq, requests, retries)
                    if requests > retries then
                        return nil, "chunk " .. seq .. " failed its checksum after " ..
                                    retries .. " requests"
                    end
                    send_message(peer, { action = xfer.ACTION, t = "missing", list = { seq } })
                end
            else
                send_message(peer, { action = xfer.ACTION, t = "ack", seq = seq })
            end
        else
            -- Silence: ask for whatever is still missing.
            requests = requests + 1
            local list = holes()
            trace("silence %s: %d/%d received, %d missing (request %d/%d)", tostring(reason),
                  received, total_chunks, #list, requests, retries)
            if #list == 0 then
                -- Everything arrived; only the end marker is outstanding.
                if now_ms() > deadline then
                    trace("everything arrived but the done marker never did")
                    return nil, "transfer timed out"
                end
            elseif requests > retries then
                trace("stalled: giving up on %d missing chunk(s)", #list)
                return nil, "transfer stalled (" .. reason .. "): missing chunk(s) " ..
                            table.concat(list, ",")
            else
                send_message(peer, { action = xfer.ACTION, t = "missing", list = list })
            end
            timeout = math.min(timeout, 1)
            opts.timeout = timeout
        end
    end

    if not saw_done then
        saw_done = wait_message(opts, function(m) return m.t == "done" end)
    end

    -- Anything still buffered for this sender arrived during the transfer: it is a
    -- late retry of the file that just landed, and its sequence numbers would collide
    -- with the next transfer's. Drop it rather than let it leak forward.
    drop_early_blocks(peer)

    local body = table.concat(chunks)
    if tonumber(meta.size) and #body ~= tonumber(meta.size) then
        return nil, "size mismatch after transfer (" .. #body .. " of " .. tostring(meta.size) .. " bytes)"
    end
    if checksum.crc32(body) ~= tonumber(meta.crc) then
        return nil, "whole file checksum mismatch"
    end

    local payload_count = 0
    for i = 1, total_chunks do
        if not chunks[i] then return nil, "chunk " .. i .. " never arrived" end
        payload_count = payload_count + 1
    end

    return body, { chunks = payload_count, requests = requests }
end

-- ============================================================
-- ============================================================
-- Opening a PULL: the request is retried, not sent once
-- ============================================================
--
-- This is the PULL's opener, and the only caller left is xfer.pull. The push used to
-- come through here too; it now opens with its first block instead (see open_push
-- below), because retrying a request does not fix a lost `ready`, it only survives it.
-- A pull has no block to open with -- the file is the peer's to send -- so it keeps the
-- request/ready shape and this retry.
--
-- The measurement behind the retry: on real hardware the peer received a push request,
-- entered its receive loop and reported the stall a full 22 seconds later, while the
-- requester had given up after one request timeout and never saw the `ready` that was
-- sent back. A pull survived the same loss because its whole request is retried by the
-- caller (`rget` runs the command again), so a pull that needed two or three attempts
-- still finished.
--
--   * the peer is idempotent about a repeated request: the answer is the same ready/refusal,
--     and it keeps serving the first conversation it accepted
--   * a refusal (`result`, e.g. "file exists") does not change on a retry, so it ends the
--     attempts immediately rather than burning them
--   * the wait after each attempt is shortened so the total stays near one request timeout
--     plus the retry budget (2 * 15 s of waiting is no better than 1 * 30 s, and on a busy
--     peer neither fits inside one timeout)
local REQUEST_TRIES = 2

local function open_transfer(run, request, what, opts)
    local tries = tonumber(opts and opts.request_tries) or REQUEST_TRIES
    local last = "timeout"
    for attempt = 1, tries do
        local sent, serr = send_message(run.peer, request)
        if not sent then
            last = tostring(serr)
        else
            if run.trace then
                run.trace(string.format("%s request sent (attempt %d/%d)", what, attempt, tries))
            end
            local wait = run
            if attempt > 1 then
                wait = {}
                for k, v in pairs(run) do wait[k] = v end
                local total = opts and tonumber(opts.request_timeout) or run.timeout or 15
                wait.timeout = math.max(2, total / tries)
            end
            local reply = wait_message(wait,
                function(m) return m.t == "ready" or m.t == "result" end)
            if run.trace then
                run.trace(string.format("%s answer: %s reason=%s (attempt %d/%d)", what,
                    reply and tostring(reply.t) or "none",
                    tostring(reply and reply.reason), attempt, tries))
            end
            if reply then
                if reply.t == "result" then
                    -- A refusal is an ANSWER, not a silence: the third value
                    -- tells the caller so, because "no answer" is reported as
                    -- exit 124 and a script would then retry or give up on a
                    -- peer that had already said why it refused.
                    return nil, reply.reason or "peer refused the file", { refused = true }
                end
                return reply
            end
            last = "no answer"
        end
    end
    -- The peer never answered; the caller reports this as exit status 124.
    return nil, "peer did not answer the transfer request (" .. tostring(last) .. ")", {
        timeout = true,
    }
end

-- ============================================================
-- Opening a PUSH: the first block goes with the request
-- ============================================================
--
-- The round trip that kept failing on hardware was the peer's `ready`. It is a small
-- control message with no checksum and no retransmission, and a push paid exactly one
-- request timeout when it went missing, while a pull survived because its caller
-- re-ran the whole command. Removing the round trip is more fundamental than adding
-- another retry layer: the first block is already protected by the chunk layer
-- (CRC32 plus ack/missing), so using its answer as the acceptance turns a message that
-- can be lost silently into one whose loss is detected and retried.
--
-- So the push now sends: request, then block 1, back to back. What comes back is either
--   * `result`            -- the peer refused (bad name, file exists, ...): stop
--   * `ack`/`missing`     -- an answer to block 1: accepted, and the answer is handed to
--                            stream_send as its opener so the block is not sent twice
--   * `ready`             -- a peer that still announces first; block 1 is already on
--                            its way, so keep waiting for the answer to THAT block
--   * nothing             -- retry the whole opening, block 1 included
--
-- The three things this had to get right at once (a first attempt failed on each):
--   1. a block that arrives before the peer read its request must not be treated as a
--      request -- xfer.serve buffers it (stash_block) instead of answering `nil`;
--   2. the receiver must accept that early block -- stream_receive installs the buffer
--      before it waits for anything;
--   3. the requester must not send block 1 twice -- stream_send takes the already-sent
--      block's answer as opts.opener and skips its own send for that sequence.
local function open_push(run, req, first_chunk, opts)
    local tries = tonumber(opts and opts.request_tries) or REQUEST_TRIES
    local last = "timeout"
    local total_chunks = tonumber(req.chunks) or 0

    -- The request and the opener are one unit: the peer may see the block first, and
    -- both are retried together.
    local function send_opening()
        local sent, serr = send_message(run.peer, req)
        if not sent then return nil, tostring(serr) end
        if first_chunk then
            local ok, cerr = send_message(run.peer, first_chunk)
            if not ok then return nil, tostring(cerr) end
        end
        return true
    end

    for attempt = 1, tries do
        local sent, serr = send_opening()
        if not sent then
            last = tostring(serr)
        else
            if run.trace then
                run.trace(string.format("put request sent (attempt %d/%d) with %s",
                    attempt, tries,
                    first_chunk and ("block 1/" .. tostring(total_chunks)) or "no block"))
            end
            local wait = run
            local attempt_timeout = run.timeout or 15
            if attempt > 1 then
                local total = opts and tonumber(opts.request_timeout) or run.timeout or 15
                attempt_timeout = math.max(2, total / tries)
            end
            if attempt_timeout ~= run.timeout then
                wait = {}
                for k, v in pairs(run) do wait[k] = v end
                wait.timeout = attempt_timeout
            end

            -- Keep waiting until something conclusive arrives: a refusal, or an answer
            -- to the block that opened the transfer. A `ready` alone is not conclusive
            -- here, because block 1 is already on the wire -- unless there is no block 1
            -- at all (an empty file has zero chunks), in which case `ready` is the only
            -- acceptance the peer will send and it has to be taken.
            --
            -- The whole wait is bounded by ONE deadline: wait_message starts a fresh
            -- deadline on every call, so looping on it without a bound of our own would
            -- let an unrelated message (a `ready`, an ack for another sequence) extend
            -- the wait indefinitely.
            local reply
            local deadline = os.epoch("utc") + math.floor(attempt_timeout * 1000)
            while true do
                local remain = (deadline - os.epoch("utc")) / 1000
                if remain <= 0 then break end
                local step = {}
                for k, v in pairs(wait) do step[k] = v end
                step.timeout = remain
                local got = wait_message(step, function(m)
                    return m.t == "result" or m.t == "ack" or m.t == "missing" or
                           m.t == "ready"
                end)
                if not got then break end
                if got.t == "result" then reply = got; break end
                if got.t == "ack" and tonumber(got.seq) == 1 then reply = got; break end
                if got.t == "missing" then reply = got; break end
                if got.t == "ready" and not first_chunk then reply = got; break end
                -- `ready` while a block is in flight (or an ack for another sequence):
                -- keep waiting for block 1's answer, inside the same deadline
            end

            if run.trace then
                run.trace(string.format("put answer: %s reason=%s (attempt %d/%d)",
                    reply and tostring(reply.t) or "none",
                    tostring(reply and reply.reason), attempt, tries))
            end

            if reply then
                if reply.t == "result" then
                    return nil, reply.reason or "peer refused the file", { refused = true }
                end
                -- accepted: the answer to block 1 becomes stream_send's opener, so the
                -- block is not sent a second time from its loop
                if first_chunk then return { seq = 1, reply = reply } end
                return {}
            end
            last = "no answer"
        end
    end
    return nil, "peer did not answer the transfer request (" .. tostring(last) .. ")", {
        timeout = true,
    }
end

-- ============================================================
-- Requester side
-- ============================================================

local function common_opts(opts)
    local out = {
        peer = opts.target or opts.peer,
        timeout = opts.timeout or netcfg.timeout(),
        retries = opts.retries or netcfg.retries(),
        total_timeout = opts.total_timeout or xfer.DEFAULT_TOTAL_TIMEOUT,
        progress = opts.progress,
        -- xfer.trace is a module level sink a caller may install (the MC acceptance does)
        -- so the conversation can be read branch by branch; opts wins when both are set.
        trace = opts.trace or xfer.trace,
    }
    if out.peer == nil then return nil, "no target computer: use -t <id>" end
    local id, iderr = netcfg.resolve_target(out.peer)
    if not id then return nil, iderr end
    out.peer = id
    local ok, err = opened()
    if not ok then return nil, err end
    return out
end

-- Push a local file to another computer.
-- opts: target, path (local), remote (path on the peer), chunk, timeout,
--       retries, total_timeout, progress, overwrite
function xfer.send(opts)
    local body
    if opts.data then
        body = opts.data
    else
        local path, err = normalize(opts.path)
        if not path then return nil, err end
        local f = fs.open(path, "r")
        if not f then return nil, path .. ": cannot open for reading" end
        body = f.readAll() or ""
        f.close()
    end

    local size = #body
    local chunk = math.max(xfer.MIN_CHUNK, math.min(xfer.MAX_CHUNK,
        tonumber(opts.chunk) or netcfg.chunk_size()))
    local chunks = split_chunks(body, chunk)

    local run, err = common_opts(opts)
    if not run then return nil, err end

    local name = safe_name(opts.name or basename(opts.path or "file"))
    if not name then return nil, "invalid file name" end

    -- The remote path belongs to the peer: it is passed through untouched (the
    -- peer resolves it against its own working directory) and only checked for
    -- upward traversal here.
    local remote = opts.remote
    if remote and has_traversal(remote) then
        return nil, "refusing path traversal: " .. remote
    end

    -- The request that opens the conversation carries the description of the file
    -- only: size, chunk size, chunk count and the whole-file CRC. The payload
    -- itself lives in "chunks", which stream_send() walks one datagram at a time.
    -- Keeping the two apart matters: putting the chunk list on the request made
    -- every push serialize the whole file into its first datagram (a 200 KB file
    -- became one 218 KB message, 448 fragments, which never reaches the peer).
    local req = {
        action = xfer.ACTION, op = "put", name = name, path = remote,
        size = size, chunk = chunk, chunks = #chunks,
        crc = checksum.crc32(body), overwrite = opts.overwrite and true or nil,
    }
    -- a separate table on purpose: stream_send() reads the chunk list from its meta
    -- argument, and putting that list on the request (or aliasing the request as the
    -- meta) would serialize the whole file into the request datagram
    local meta = {
        action = xfer.ACTION, op = "put", name = name, path = remote,
        size = size, chunk = chunk, chunks = #chunks, chunks_data = chunks,
        crc = req.crc,
    }

    -- The push opens with its first block instead of waiting for the peer's `ready`
    -- (see open_push above). An empty file has no block to open with, so it keeps the
    -- old request/ready shape.
    local first_chunk
    if #chunks >= 1 then
        first_chunk = {
            action = xfer.ACTION, t = "chunk", seq = 1,
            crc = checksum.crc32(chunks[1]), data = b64_encode(chunks[1]),
        }
    end

    local opener, oerr, why = open_push(run, req, first_chunk, opts)
    if not opener then
        -- The peer's own "no" (file exists, not enough space, bad name) exits 1;
        -- only a silence is a timeout (124), which a script reads differently.
        if why and why.refused then return nil, oerr end
        return nil, oerr, { timeout = true }
    end

    -- A copy, so the opener is only seen by this transfer's stream_send.
    local send_opts = {}
    for k, v in pairs(run) do send_opts[k] = v end
    if opener.seq then send_opts.opener = opener end

    local sent, stats = stream_send(run.peer, meta, body, send_opts, run.progress)
    if not sent then return nil, stats end

    return true, {
        bytes = size, chunks = #chunks,
        resends = (stats and stats.resends) or 0,
        crc = string.format("%08x", meta.crc),
        remote = (stats and stats.remote) or remote or name,
        direction = "put",
    }
end

-- Pull a file from another computer.
-- opts: target, remote (path on the peer), path (local destination; defaults
--       to the peer file name in the current directory), chunk, timeout,
--       retries, progress, overwrite
function xfer.pull(opts)
    local run, err = common_opts(opts)
    if not run then return nil, err end
    if not opts.remote then return nil, "no remote path given" end
    if has_traversal(opts.remote) then
        return nil, "refusing path traversal: " .. opts.remote
    end

    local abs, nerr = normalize(opts.remote)
    if not abs then return nil, nerr end

    local chunk = math.max(xfer.MIN_CHUNK, math.min(xfer.MAX_CHUNK,
        tonumber(opts.chunk) or netcfg.chunk_size()))

    -- The same retry as the push: a lost `ready` on a pull was survivable only because the
    -- caller ran the command again, which hid the loss rather than handling it.
    local reply, oerr, why = open_transfer(run, {
        action = xfer.ACTION, op = "get", path = abs, chunk = chunk,
    }, "get", opts)
    if not reply then
        if why and why.refused then return nil, oerr end
        return nil, oerr, { timeout = true }
    end

    local name = safe_name(reply.name or basename(abs))
    if not name then return nil, "peer sent an invalid file name" end

    local dest = opts.path or name
    local dest_abs, derr = normalize(dest)
    if not dest_abs then return nil, derr end
    if has_traversal(dest) then return nil, "refusing path traversal: " .. dest end

    -- Before the first block: the ready message carries the whole size, so a
    -- pull that cannot fit is refused here rather than after the download has
    -- filled the disk. The peer is told, and its sender gives up on its own
    -- timeout because we send no ack.
    local room, why = space.need(dest_abs, tonumber(reply.size) or 0)
    if not room then
        send_message(run.peer, { action = xfer.ACTION, t = "result", ok = false, reason = why })
        return nil, why
    end

    local body, stats = stream_receive(run.peer, reply, run, run.progress)
    if not body then
        send_message(run.peer, { action = xfer.ACTION, t = "result", ok = false, reason = stats })
        return nil, stats
    end

    local allowed, reason = check_destination(dest_abs, opts, opts.root)
    if not allowed then
        send_message(run.peer, { action = xfer.ACTION, t = "result", ok = false, reason = reason })
        return nil, reason
    end
    if fs.exists(dest_abs) and not opts.overwrite then
        send_message(run.peer, { action = xfer.ACTION, t = "result", ok = false,
                                 reason = dest_abs .. ": file exists" })
        return nil, dest_abs .. ": file exists (use -f to overwrite)"
    end

    -- And again with the bytes that actually arrived: the ready's size is the
    -- peer's word, and a body that grew (or a disk that filled in between) has to
    -- be refused before the old file is truncated.
    local room2, why2 = space.need(dest_abs, #body)
    if not room2 then
        send_message(run.peer, { action = xfer.ACTION, t = "result", ok = false, reason = why2 })
        return nil, why2
    end

    ensure_parent(dest_abs)
    local out = fs.open(dest_abs, "w")
    if not out then return nil, dest_abs .. ": cannot open for writing" end
    out.write(body)
    out.close()

    send_message(run.peer, {
        action = xfer.ACTION, t = "result", ok = true, path = dest_abs, size = #body,
    })

    return true, {
        bytes = #body, chunks = (stats and stats.chunks) or 0,
        resends = (stats and stats.requests) or 0,
        crc = string.format("%08x", checksum.crc32(body)),
        path = dest_abs, direction = "get",
    }
end

-- Wait for an incoming push and store it. opts: save_dir, as (explicit local
-- path), wait (seconds to wait for a request, default 60), overwrite, root.
function xfer.listen(opts)
    local run, err = common_opts(opts)
    if not run then return nil, err end
    run.peer = nil
    run.total_timeout = opts.total_timeout or xfer.DEFAULT_TOTAL_TIMEOUT
    run.timeout = tonumber(opts.wait) or run.timeout

    local req, sender = wait_message(run, function(m) return m.op == "put" or m.op == "get" end)
    if not req then return nil, "no incoming transfer within " .. run.timeout .. "s" end
    run.peer = sender
    run.timeout = tonumber(opts.timeout) or netcfg.timeout()

    if req.op ~= "put" then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                               reason = "this endpoint only accepts pushes (op=put)" })
        return nil, "computer " .. tostring(sender) .. " requested a download, not a push"
    end

    local name = safe_name(req.name)
    if not name then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                               reason = "invalid file name" })
        return nil, "peer sent an invalid file name"
    end

    local dest = opts.as or ((opts.save_dir or cwd_path()) .. "/" .. name)
    local dest_abs, derr = normalize(dest)
    if not dest_abs then return nil, derr end

    local allowed, reason = check_destination(dest_abs, opts, opts.root)
    if not allowed then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = reason })
        return nil, reason
    end
    if fs.exists(dest_abs) and not opts.overwrite then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                               reason = dest_abs .. ": file exists" })
        return nil, dest_abs .. ": file exists (use -f to overwrite)"
    end

    -- The request carries the whole size, so a push that cannot fit is refused
    -- BEFORE the ready: the sender is told why instead of being fed block by
    -- block to a disk that cannot hold the file.
    local room, why = space.need(dest_abs, tonumber(req.size) or 0)
    if not room then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = why })
        return nil, why
    end

    send_message(sender, { action = xfer.ACTION, t = "ready", name = name })
    local body, stats = stream_receive(sender, req, run, run.progress)
    if not body then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = stats })
        return nil, stats
    end

    -- And with the bytes that actually arrived, before the destination is
    -- truncated: the request's size is the sender's word.
    local room2, why2 = space.need(dest_abs, #body)
    if not room2 then
        send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = why2 })
        return nil, why2
    end

    ensure_parent(dest_abs)
    local out = fs.open(dest_abs, "w")
    if not out then return nil, dest_abs .. ": cannot open for writing" end
    out.write(body)
    out.close()

    send_message(sender, { action = xfer.ACTION, t = "result", ok = true,
                           path = dest_abs, size = #body })

    return true, {
        bytes = #body, chunks = (stats and stats.chunks) or 0,
        resends = (stats and stats.requests) or 0,
        crc = string.format("%08x", checksum.crc32(body)),
        path = dest_abs, sender = sender, direction = "listen",
    }
end

-- ============================================================
-- Peer side (used by netd)
-- ============================================================

-- Answer one request: op="put" stores the file, op="get" streams one back.
-- opts: save_dir (where pushes land, default "/"), root (allowed subtree),
--       overwrite, progress, report (a function the queued-request path logs through).
function xfer.serve(sender, req, opts)
    opts = opts or {}

    -- A block that outran its request.
    --
    -- The push sends block 1 immediately after its request, so a driver's receive
    -- loop can hand this function that block BEFORE the request is read. That used to
    -- be the hardware failure this project spent a day on: the peer answered a bare
    -- block with `unsupported operation: nil`, and its log held nothing else
    -- (`[5 t=chunk op=nil]`). A block is not an error -- it is buffered here and the
    -- request that follows installs it (see stream_receive), so no driver has to know
    -- about the ordering.
    if type(req) == "table" and req.op ~= "put" and req.op ~= "get" then
        if stash_block(sender, req) then
            local why = string.format("block %s from %s arrived before its request (buffered)",
                                      tostring(req.seq), tostring(sender))
            if opts.report then opts.report(why) end
            return nil, why, "buffered"
        end
    end

    local peer_opts = {
        peer = sender,
        -- a request that arrives while this one runs is queued, not dropped: the caller
        -- drains it with xfer.serve_pending() when this returns
        stash = true,
        timeout = opts.timeout or netcfg.timeout(),
        retries = opts.retries or netcfg.retries(),
        total_timeout = opts.total_timeout or xfer.DEFAULT_TOTAL_TIMEOUT,
        progress = opts.progress,
    }

    if req.op == "put" then
        local name = safe_name(req.name)
        if not name then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                                   reason = "invalid file name" })
            return nil, "invalid file name"
        end
        local dest, derr = normalize(req.path or ((opts.save_dir or "/") .. "/" .. name))
        if not dest then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = derr })
            return nil, derr
        end
        local allowed, reason = check_destination(dest, opts, opts.root)
        if not allowed then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = reason })
            return nil, reason
        end
        if fs.exists(dest) and not (opts.overwrite or req.overwrite) then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                                   reason = dest .. ": file exists" })
            return nil, dest .. ": file exists"
        end

        -- Same preflight as xfer.listen: the request names the size, so the peer
        -- of a push is refused before the blocks start arriving.
        local room, why = space.need(dest, tonumber(req.size) or 0)
        if not room then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = why })
            return nil, why
        end

        send_message(sender, { action = xfer.ACTION, t = "ready", name = name })
        local body, stats = stream_receive(sender, req, peer_opts, peer_opts.progress)
        if not body then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = stats })
            return nil, stats
        end

        -- The second look, with the bytes that really arrived, before the open
        -- truncates whatever the destination held.
        local room2, why2 = space.need(dest, #body)
        if not room2 then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = why2 })
            return nil, why2
        end

        ensure_parent(dest)
        local out = fs.open(dest, "w")
        if not out then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                                   reason = dest .. ": cannot open for writing" })
            return nil, dest .. ": cannot open for writing"
        end
        out.write(body)
        out.close()
        send_message(sender, { action = xfer.ACTION, t = "result", ok = true,
                               path = dest, size = #body })

        return true, {
            bytes = #body, chunks = (stats and stats.chunks) or 0,
            resends = (stats and stats.requests) or 0,
            path = dest, sender = sender, direction = "put",
        }
    elseif req.op == "get" then
        if has_traversal(req.path or "") then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                                   reason = "refusing path traversal" })
            return nil, "refusing path traversal: " .. tostring(req.path)
        end
        local source, serr = normalize(req.path or "")
        if not source then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false, reason = serr })
            return nil, serr
        end
        local f = fs.open(source, "r")
        if not f then
            send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                                   reason = source .. ": no such file" })
            return nil, source .. ": no such file"
        end
        local body = f.readAll() or ""
        f.close()

        local chunk = math.max(xfer.MIN_CHUNK, math.min(xfer.MAX_CHUNK,
            tonumber(req.chunk) or netcfg.chunk_size()))
        local chunks = split_chunks(body, chunk)
        local meta = {
            action = xfer.ACTION, t = "ready", name = basename(source),
            size = #body, chunk = chunk, chunks = #chunks,
            crc = checksum.crc32(body), chunks_data = chunks,
        }
        local ok, err = send_message(sender, {
            action = xfer.ACTION, t = "ready", name = meta.name, size = meta.size,
            chunk = meta.chunk, chunks = meta.chunks, crc = meta.crc,
        })
        if not ok then return nil, err end

        local sent, stats = stream_send(sender, meta, body, peer_opts, peer_opts.progress)
        if not sent then return nil, stats end
        return true, {
            bytes = #body, chunks = #chunks,
            resends = (stats and stats.resends) or 0,
            path = source, sender = sender, direction = "get",
        }
    end

    send_message(sender, { action = xfer.ACTION, t = "result", ok = false,
                           reason = "unsupported operation: " .. tostring(req.op) })
    return nil, "unsupported operation: " .. tostring(req.op)
end

return xfer