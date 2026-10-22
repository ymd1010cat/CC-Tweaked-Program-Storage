--[[- dc.xfer — 分块文件传输（走 "dcpush" 协议）

用于把 worker.lua 从主控推给新节点。有线网络本身可靠，但消息仍可能因为
对端重启而丢失，所以用"停等 + 重传 + 结束校验"的简单可靠机制：

    发送端                          接收端
    put   i=1  ─────────────────▶   暂存，回 putack i=1
    put   i=2  ─────────────────▶   ...
    putdone    ─────────────────▶   检查 1..n 是否齐全
                                    齐全 → 组装、落盘、回 putok
                                    缺失 → 回 putmiss {缺失下标}
               ◀─────────────────
    put (缺失块) / putdone ─────▶   ...

发送端是状态机，由主控的 tick 循环驱动（不能再用一个 rednet.receive 协程，
否则会与主控唯一的接收循环重复消费同一事件）。
]]

local util   = dc_require("dc.util")
local proto  = dc_require("dc.protocol")
local net    = dc_require("dc.net")

local M = {}

M.CHUNK       = 4096     -- 每块字节数（留足余量，避免 modem 消息过大）
M.ACK_TIMEOUT = 4        -- 秒：等一个确认的上限
M.MAX_TRIES   = 6        -- 单个分块最多重发次数
M.RECV_IDLE   = 45       -- 秒：接收端多久没动静就丢弃半成品
M.RECV_WAIT   = 0.3      -- 秒：接收循环单次等待时长。
                         -- 它同时决定发送端推进的粒度（发送端由接收循环驱动），
                         -- 所以不能太长，否则大文件要等很久才能传完。

-- ── 发送队列：由"唯一的 dcpush 接收循环"统一驱动 ────────────────────────
--
-- 关键约束：一个程序里**只能有一个** rednet.receive("dcpush") 循环，否则两个循环会
-- 各自抢走一半的消息（确认帧被接收循环吃掉、数据块被发送逻辑吃掉，两边都卡死）。
-- 所以发送端不自己收消息，而是把状态机登记到 registry，由接收循环每次迭代推进它。

function M.newRegistry()
    return { senders = {}, results = {} }
end

--- 登记一次发送（不阻塞）。返回 xid / nil, err
function M.enqueue(reg, target, name, what, data, onDone)
    if type(data) ~= "string" or #data == 0 then return nil, "empty content" end
    local s = M.newSender({ target = target, name = name, what = what, data = data,
        onDone = onDone })
    reg.senders[s.xid] = s
    return s.xid
end

--- 推进所有发送端。返回"本次完成的 xid 集合"或 nil
function M.pollRegistry(reg, send)
    local done
    for xid, s in pairs(reg.senders) do
        local st = M.senderPoll(s, send)
        if st == "ok" or st == "fail" then
            reg.senders[xid] = nil
            reg.results[xid] = st
            done = done or {}
            done[xid] = st
        end
    end
    return done
end

--- 阻塞等待某个 xid 完成。需要有人调 pollRegistry 并在完成时 queueEvent("dcpush_done")。
-- 用无过滤的 pullEvent：CC 的 parallel 会把同一个事件分发给所有协程，所以不会抢别人的。
function M.waitFor(reg, xid, timeout)
    local deadline = util.mono() + (timeout or 30)
    while true do
        local st = reg.results[xid]
        if st then
            reg.results[xid] = nil
            if st == "ok" then return true end
            return nil, "transfer failed"
        end
        if util.mono() > deadline then
            reg.senders[xid] = nil
            reg.results[xid] = nil
            return nil, "transfer timeout"
        end
        os.startTimer(0.2)
        os.pullEvent()
    end
end

--- 传输一个文件大约需要多少秒（用于把它算进任务的超时预算）
function M.estimateSeconds(bytes, chunks)
    local n = chunks or math.ceil((bytes or 0) / M.CHUNK)
    return math.min(120, n * 1.5 + 3)
end

--- 给等待者发信号（接收循环在 pollRegistry 有结果时调用）
function M.notify()
    os.queueEvent("dcpush_done")
end

--- 等一下把接收端也登记进 registry（收取对方推来的文件时用）
function M.waitIncoming(reg, xid, timeout)
    return M.waitFor(reg, xid, timeout)
end

local function chunkify(data, size)
    local parts, i, n = {}, 1, #data
    if n == 0 then return { "" } end
    while i <= n do
        parts[#parts + 1] = data:sub(i, i + size - 1)
        i = i + size
    end
    return parts
end

-- ── 发送端 ──────────────────────────────────────────────────────────────

--- opts: { target, name, data, what, onDone(state, s) }
function M.newSender(opts)
    local parts = chunkify(opts.data or "", opts.chunk or M.CHUNK)
    return {
        xid    = opts.xid or net.newXid("put"),
        target = opts.target,
        name   = opts.name or "file",
        what   = opts.what or "file",
        parts  = parts,
        n      = #parts,
        next   = 1,          -- 下一个要发的分块
        resent = {},         -- 需要重传的分块队列
        state  = "data",     -- data | done | ok | fail
        awaiting = nil,      -- 正在等待确认的分块下标（或 "done"）
        sentAt = 0,
        tries  = 0,
        startedAt = util.mono(),
        err    = nil,
        onDone = opts.onDone,
    }
end

local function sendChunk(s, send, idx)
    send(s.target, proto.msg(proto.PUT, {
        xid = s.xid, name = s.name, what = s.what,
        i = idx, n = s.n, d = s.parts[idx],
    }), util.PROTO_PUSH)
    s.awaiting, s.sentAt, s.tries = idx, util.mono(), 0
end

--- 驱动发送端。send(target, msg, proto) 由调用方提供（主控是 net.send）。
function M.senderPoll(s, send)
    if s.state == "ok" or s.state == "fail" then return s.state end
    local now = util.mono()

    if s.state == "data" then
        if s.awaiting then
            if now - s.sentAt < M.ACK_TIMEOUT then return s.state end
            s.tries = s.tries + 1
            if s.tries > M.MAX_TRIES then
                s.state, s.err = "fail", "chunk ack timeout"
                if s.onDone then s.onDone(s.state, s) end
                return s.state
            end
            sendChunk(s, send, s.awaiting)
            return s.state
        end

        local idx
        if #s.resent > 0 then
            idx = table.remove(s.resent, 1)
        elseif s.next <= s.n then
            idx = s.next
            s.next = s.next + 1
        else
            s.state, s.awaiting, s.sentAt, s.tries = "done", "done", now, 0
            send(s.target, proto.msg(proto.PUTDONE, { xid = s.xid, n = s.n }), util.PROTO_PUSH)
            return s.state
        end
        sendChunk(s, send, idx)
        return s.state
    end

    -- state == "done"：等待 putok / putmiss
    if now - s.sentAt > M.ACK_TIMEOUT then
        s.tries = s.tries + 1
        if s.tries > M.MAX_TRIES then
            s.state, s.err = "fail", "final ack timeout"
            if s.onDone then s.onDone(s.state, s) end
            return s.state
        end
        s.sentAt = now
        send(s.target, proto.msg(proto.PUTDONE, { xid = s.xid, n = s.n }), util.PROTO_PUSH)
    end
    return s.state
end

--- 发送端收到回包。返回 true 表示消息属于本传输。
function M.senderOnMsg(s, msg)
    if type(msg) ~= "table" or msg.xid ~= s.xid then return false end
    if msg.t == proto.PUTACK then
        if s.awaiting == msg.i then
            s.awaiting, s.tries = nil, 0
        end
        return true
    elseif msg.t == proto.PUTOK then
        if s.state ~= "ok" then
            s.state = "ok"
            if s.onDone then s.onDone(s.state, s) end
        end
        return true
    elseif msg.t == proto.PUTMISS then
        s.resent = {}
        for _, i in ipairs(msg.miss or {}) do
            if type(i) == "number" and s.parts[i] then s.resent[#s.resent + 1] = i end
        end
        s.state, s.awaiting, s.next, s.tries = "data", nil, s.n + 1, 0
        return true
    end
    return false
end

function M.senderSummary(s)
    if s.state == "ok" then
        return string.format("%s delivered to #%d (%d chunks, %s)", s.name, s.target, s.n, util.duration((util.mono() - s.startedAt) * 1000))
    elseif s.state == "fail" then
        return string.format("%s -> #%d failed: %s", s.name, s.target, tostring(s.err))
    end
    return string.format("%s -> #%d transferring %d/%d", s.name, s.target, math.min(s.next - 1, s.n), s.n)
end

-- ── 接收端 ──────────────────────────────────────────────────────────────

function M.newReceiver(xid, name, n)
    return {
        xid = xid, name = name, n = n,
        parts = {}, count = 0,
        updatedAt = util.mono(),
        written = false,
    }
end

--- 处理一个分块消息。
-- 返回: "ack", i | "miss", list | "complete", data | "ignore"
function M.recvOnMsg(r, msg)
    if type(msg) ~= "table" or msg.xid ~= r.xid then return "ignore" end
    r.updatedAt = util.mono()

    if msg.t == proto.PUT then
        local i = tonumber(msg.i)
        if not i or i < 1 then return "ignore" end
        if r.n == nil and tonumber(msg.n) then r.n = tonumber(msg.n) end
        if r.parts[i] == nil then r.count = r.count + 1 end
        r.parts[i] = msg.d
        if msg.name then r.name = msg.name end
        return "ack", i

    elseif msg.t == proto.PUTDONE then
        if tonumber(msg.n) then r.n = tonumber(msg.n) end
        local miss = {}
        for i = 1, (r.n or 0) do
            if r.parts[i] == nil then miss[#miss + 1] = i end
        end
        if #miss > 0 then return "miss", miss end
        local buf = {}
        for i = 1, r.n do buf[i] = r.parts[i] end
        return "complete", table.concat(buf)
    end
    return "ignore"
end

--- 接收端是否已经超时废弃
function M.recvExpired(r)
    return (util.mono() - r.updatedAt) > M.RECV_IDLE
end

M.chunkify = chunkify

return M
