--[[- dc.net — 网络层：有线调制解调器发现 + rednet 收发封装

有线网络搭建（游戏内）：
    [电脑]─[有线调制解调器]══[网络线缆]══[有线调制解调器]─[电脑]
    所有接在同一段网络线缆上的有线调制解调器构成一个"有线网络"，
    同一网络内广播可达全部机器，不同网络之间互相隔离。

本模块优先选择有线调制解调器；没有有线时退回无线（便于单机调试）。
]]

local util = dc_require("dc.util")
local crypto = dc_require("dc.crypto")

-- 传输后端：默认 rednet；unixshell 里若装了 lib/rpvnet.lua，可以把
-- DCNET_TRANSPORT 设成 "rpv" 或 "auto" 走 RPV1（rednet 形状的 API）。
-- 独立运行（没有 ush）时仍是 rednet，行为不变。
local function select_netlib()
    local want = tostring(rawget(_G, "DCNET_TRANSPORT") or "rednet"):lower()
    if want == "rednet" then return rednet, "rednet" end
    local ok, rpv = pcall(require, "rpvnet")
    if not ok or type(rpv) ~= "table" then
        if want == "rpv" then
            error("dcnet: transport=rpv 但 lib/rpvnet.lua 不可用: " .. tostring(rpv), 0)
        end
        return rednet, "rednet"
    end
    if want == "rpv" then return rpv, "rpv" end
    local can = false
    if type(rpv.available) == "function" then
        local ok2, avail = pcall(rpv.available)
        can = ok2 and avail and true or false
    end
    if can then return rpv, "rpv" end
    return rednet, "rednet"
end

local netlib, TRANSPORT = select_netlib()

local M = {}
M.transport = TRANSPORT

-- ── 消息签名与防重放 ────────────────────────────────────────────────────
--
-- 局域网里任何一台电脑（甚至别人的脚本）都能往我们的频道上发消息，所以主控/节点
-- 之间可以共用一个密钥给消息签名：没签名、签名不对、重复发过的消息一律丢弃。
--
-- 设计取舍（为了游戏内电脑也能跑得动）：
--   * 签名用 HMAC-SHA256，覆盖消息的**结构化内容**（键名排序后序列化，保证可复现）。
--   * 大块内容（分块传输的 d、作业源码 src）不直接参与哈希——4KB 在游戏内要算 1 秒，
--     所以改成只把它们的 64 位校验和纳入签名；源码/文件本身另用 util.hash 校验。
--   * 防重放：每条消息带 (sid, seq, ts)。sid 是进程启动时随机生成的会话号，
--     seq 单调递增，ts 是发送时刻；接收端拒绝 seq 回退、重复 (sid,seq)、时间偏差过大。

M.SEQ_SKEW = 120          -- 秒：时间戳容许的偏差
M.BULK_FIELDS = { ["d"] = "dck", ["src"] = "sck" }

M.key = nil
M.seq = 0
M.sid = nil
M.stats = { signed = 0, badSig = 0, replay = 0, stale = 0, unsigned = 0, fresh = 0 }
M.seenSids = {}           -- sid -> { seq = n, at = mono }
M.lastBad = nil

--- 本机是否支持签名（需要 bit32）
function M.signingSupported()
    return crypto.available == true
end

function M.hasKey()
    return (M.key ~= nil and #M.key >= 8)
end

--- 设置共享密钥（"" 或 nil = 关闭签名）
function M.setKey(key)
    if key == nil or key == "" then
        M.key, M.sid, M.seq = nil, nil, 0
        return true
    end
    if not M.signingSupported() then
        return nil, "本机没有 bit32，无法启用消息签名"
    end
    if #key < 8 then
        return nil, "密钥太短（至少 8 个字符）"
    end
    M.key = tostring(key)
    if not M.sid then
        M.sid = crypto.randomHex(8)
        M.seq = 0
    end
    return true
end

--- 密钥指纹（只用来核对两端是否一致，不泄露密钥本身）
function M.fingerprint()
    if not M.hasKey() then return nil end
    local h = crypto.sha256("dcnet-key:" .. M.key)
    return h and h:sub(1, 8) or nil
end

--- 便宜的 64 位校验和（FNV-1a 变体，两个 32 位半区拼起来）
function M.checksum(s)
    s = tostring(s or "")
    local B = rawget(_G, "bit32")
    if not B then
        local h = 2166136261
        for i = 1, #s do
            h = (h * 31 + s:byte(i)) % 4294967296
        end
        return string.format("%08x%08x", h, #s)
    end
    local h1, h2 = 2166136261, 16777619
    for i = 1, #s do
        local b = s:byte(i)
        h1 = B.bxor(h1, b)
        h1 = B.band(h1 * 16777619, 0xFFFFFFFF)
        h2 = B.band(h2 + b * (i % 251 + 1), 0xFFFFFFFF)
    end
    return string.format("%08x%08x", h1, h2)
end

--- 给消息加上签名相关字段（没设密钥就原样返回）
function M.sign(msg)
    if not M.hasKey() or type(msg) ~= "table" then return msg end
    if not M.sid then
        M.sid = crypto.randomHex(8)
        M.seq = 0
    end
    M.seq = M.seq + 1
    msg.sid = M.sid
    msg.seq = M.seq
    msg.ts = os.epoch and os.epoch("utc") or (os.time() * 1000)
    local bare = M._bare(msg)
    local mac = crypto.hmacSha256(M.key, crypto.canonical(bare))
    msg.sig = mac or ""
    M.stats.signed = M.stats.signed + 1
    return msg
end

--- 生成"参与签名的副本"：大块字段换成校验和
function M._bare(msg)
    local bare = {}
    for k, v in pairs(msg) do
        if k ~= "sig" then
            local repl = M.BULK_FIELDS[k]
            if repl and type(v) == "string" then
                bare[repl] = M.checksum(v)
                bare[k .. "len"] = #v
            else
                bare[k] = v
            end
        end
    end
    return bare
end

--- 校验一条收到的消息。返回 true / false, 原因
function M.verify(sender, msg)
    if not M.hasKey() then return true end                 -- 没启用签名：放行
    if type(msg) ~= "table" then return false, "消息格式非法" end
    if not (msg.sid and msg.seq and msg.ts and msg.sig) then
        M.stats.unsigned = M.stats.unsigned + 1
        M.lastBad = string.format("#%s 发来未签名的消息（type=%s）", tostring(sender), tostring(msg.t))
        return false, "未签名"
    end
    -- 时间戳
    local now = os.epoch and os.epoch("utc") or (os.time() * 1000)
    if type(msg.ts) ~= "number" or math.abs(now - msg.ts) > M.SEQ_SKEW * 1000 then
        M.stats.stale = M.stats.stale + 1
        M.lastBad = string.format("#%s 的消息时间戳偏差过大", tostring(sender))
        return false, "时间戳无效"
    end
    -- 签名
    local bare = M._bare(msg)
    local want = crypto.hmacSha256(M.key, crypto.canonical(bare))
    if not want or not crypto.equal(want, tostring(msg.sig)) then
        M.stats.badSig = M.stats.badSig + 1
        M.lastBad = string.format("#%s 的消息签名不对（type=%s）", tostring(sender), tostring(msg.t))
        return false, "签名错误"
    end
    -- 防重放：同一会话号必须严格递增
    local rec = M.seenSids[msg.sid]
    if rec and tonumber(msg.seq) and tonumber(msg.seq) <= rec.seq then
        M.stats.replay = M.stats.replay + 1
        M.lastBad = string.format("#%s 重复/回退的消息被丢弃（seq %s ≤ %s）",
            tostring(sender), tostring(msg.seq), tostring(rec.seq))
        return false, "重复消息"
    end
    M.seenSids[msg.sid] = { seq = tonumber(msg.seq) or 0, at = util.mono() }
    -- 清理过期会话记录，别让它无限涨
    local count = 0
    for _ in pairs(M.seenSids) do count = count + 1 end
    if count > 64 then
        for sid, r in pairs(M.seenSids) do
            if util.mono() - r.at > 600 then M.seenSids[sid] = nil end
        end
    end
    M.stats.fresh = M.stats.fresh + 1
    return true
end

--- 认证失败时的统计行（给 net 指令用）
function M.statsLines()
    local s = M.stats
    local out = { string.format("签名：已签 %d　放行 %d　丢弃 %d", s.signed, s.fresh,
        s.badSig + s.replay + s.stale + s.unsigned) }
    out[#out + 1] = string.format("  未签名 %d　签名错误 %d　重复 %d　时间戳无效 %d",
        s.unsigned, s.badSig, s.replay, s.stale)
    if M.lastBad then out[#out + 1] = "  最近一次拒绝：" .. M.lastBad end
    return out
end

--- 枚举所有 modem 外设，返回 { {name=, wireless=}, ... }
function M.findModems()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(name)
        local isModem = false
        if ty == "modem" then
            isModem = true
        elseif type(ty) == "table" then          -- CC 1.99+ 外设可有多个类型
            for _, t in ipairs(ty) do
                if t == "modem" then isModem = true end
            end
        end
        if isModem then
            local wireless = true
            local ok, dev = pcall(peripheral.wrap, name)
            if ok and dev and dev.isWireless then
                local ok2, w = pcall(dev.isWireless, dev)
                if ok2 then wireless = w and true or false end
            end
            found[#found + 1] = { name = name, wireless = wireless }
        end
    end
    table.sort(found, function(a, b)
        if a.wireless ~= b.wireless then return (not a.wireless) end  -- 有线优先
        return a.name < b.name
    end)
    return found
end

--- 打开 rednet。返回 modemName, wireless；失败返回 nil, err
function M.open()
    local modems = M.findModems()
    if #modems == 0 then
        return nil, "没有检测到调制解调器（modem）"
    end
    -- 已经有打开的就直接复用，避免重复 open 报错
    for _, md in ipairs(modems) do
        if netlib.isOpen(md.name) then return md.name, md.wireless end
    end
    for _, md in ipairs(modems) do
        local ok, err = pcall(netlib.open, md.name)
        if ok then return md.name, md.wireless end
        -- 换下一个 modem 再试
        if err then M.lastError = tostring(err) end
    end
    return nil, "无法打开任何调制解调器" .. (M.lastError and (": " .. M.lastError) or "")
end

--- 打开**所有**调制解调器。
-- rednet.send 会在每个已打开的 modem 上各发一份，所以主控只要在每条网段上各挂一个
-- modem，就能把互相隔离的两段有线网络桥接起来（消息本身不跨网段，但主控能转发）。
-- 返回 { {name=, wireless=}, ... }（已打开的）与失败列表。
function M.openAll()
    local openedList, failed = {}, {}
    for _, md in ipairs(M.findModems()) do
        if netlib.isOpen(md.name) then
            openedList[#openedList + 1] = md
        else
            local ok, err = pcall(netlib.open, md.name)
            if ok then
                openedList[#openedList + 1] = md
            else
                failed[#failed + 1] = md.name .. ": " .. tostring(err)
            end
        end
    end
    return openedList, failed
end

--- 一句话描述 modem 清单
function M.describe(list)
    local wired, wireless = 0, 0
    for _, md in ipairs(list or {}) do
        if md.wireless then wireless = wireless + 1 else wired = wired + 1 end
    end
    if wired + wireless == 0 then return "无" end
    return string.format("%d 有线 / %d 无线", wired, wireless)
end

--- 发送单播。返回 true / false, err
function M.send(target, msg, proto)
    if type(target) ~= "number" then return false, "目标 ID 非法" end
    -- 负数 ID 是云端虚拟端点，不走 rednet
    if target <= 0 then return false, "目标不是网络节点" end
    if type(msg) == "table" then M.sign(msg) end
    local ok, res = pcall(netlib.send, target, msg, proto or util.PROTO_CTRL)
    if not ok then return false, tostring(res) end
    if res == false then return false, "网络未打开（" .. tostring(TRANSPORT) .. "）" end
    return true
end

--- 广播
function M.broadcast(msg, proto)
    if type(msg) == "table" then M.sign(msg) end
    local ok, res = pcall(netlib.broadcast, msg, proto or util.PROTO_CTRL)
    if not ok then return false, tostring(res) end
    if res == false then return false, "网络未打开（" .. tostring(TRANSPORT) .. "）" end
    return true
end

--- 带超时的接收（在 parallel 协程里调用）。
-- 注意：rednet.receive 带 timeout 时内部用 os.pullEvent(nil)，会醒在任何事件上，
-- 但 CC 的 parallel 会把同一个事件分发给所有匹配的协程，所以不会抢走别人的事件。
function M.receive(proto, timeout)
    local sender, msg = netlib.receive(proto, timeout)
    if not sender then return nil end
    return sender, msg
end

--- 生成一次性传输 ID
local xidCounter = 0
function M.newXid(tag)
    xidCounter = xidCounter + 1
    return string.format("%d-%d-%d-%s", os.getComputerID(), xidCounter,
        math.random(1000, 9999), tostring(tag or "x"))
end

return M
