--[[- ==========================================================================
  dcnet v1.2.0 — CC:Tweaked 分布式计算网络（运算节点 worker）

  本文件由 tools/build.py 自动生成，请勿直接编辑。
  要改逻辑请改 src/ 下的源码，然后重新运行：
      python tools/build.py

  模块：dc.util, dc.protocol, dc.net, dc.console, dc.xfer, dc.jobs, dc.worker, dc.crypto, dc.state
========================================================================== ]]
local __dc_modules, __dc_cache = {}, {}
local function __dc_define(name, fn) __dc_modules[name] = fn end
local function __dc_load(name)
    local cached = __dc_cache[name]
    if cached ~= nil then return cached end
    local fn = __dc_modules[name]
    if not fn then error("dcnet: 找不到模块 " .. tostring(name), 0) end
    local mod = fn()
    if mod == nil then mod = true end
    __dc_cache[name] = mod
    return mod
end
_G.dc_require = __dc_load

__dc_define("dc.util", function()
local M = {}

M.VERSION    = "1.2.0"
M.PROTO_CTRL = "dccomp"
M.PROTO_PUSH = "dcpush"
M.ROOT       = rawget(_G, "DCNET_ROOT") or "/dccomp"
M.JOB_DIR    = M.ROOT .. "/jobs"
M.OUT_DIR    = M.ROOT .. "/out"
M.CONTROL_DIR = M.ROOT .. "/ctl"
M.WORKER_FILE = rawget(_G, "DCNET_WORKER_FILE") or (M.ROOT .. "/worker.lua")

M.unpack  = table.unpack or unpack
M.colours = rawget(_G, "colors") or rawget(_G, "colours")

function M.now()
    if os.epoch then
        local ok, v = pcall(os.epoch, "utc")
        if ok and type(v) == "number" then return v end
    end
    return math.floor(os.clock() * 1000)
end

function M.mono()
    return os.clock()
end

function M.duration(ms)
    ms = tonumber(ms) or 0
    if ms < 0 then ms = 0 end
    if ms < 1000 then return string.format("%dms", math.floor(ms)) end
    local s = ms / 1000
    if s < 60 then return string.format("%.1fs", s) end
    local m = math.floor(s / 60)
    s = s - m * 60
    if m < 60 then return string.format("%dm%02ds", m, math.floor(s)) end
    local h = math.floor(m / 60)
    m = m - h * 60
    return string.format("%dh%02dm", h, m)
end

function M.bytes(n)
    n = tonumber(n) or 0
    if n < 1024 then return n .. "B" end
    if n < 1024 * 1024 then return string.format("%.1fKB", n / 1024) end
    return string.format("%.2fMB", n / 1024 / 1024)
end

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.split(s, sep)
    s, sep = tostring(s or ""), tostring(sep or " ")
    local out, i = {}, 1
    if sep == "" then
        for c in s:gmatch(".") do out[#out + 1] = c end
        return out
    end
    while true do
        local a, b = s:find(sep, i, true)
        if not a then
            out[#out + 1] = s:sub(i)
            return out
        end
        out[#out + 1] = s:sub(i, a - 1)
        i = b + 1
    end
end

function M.tokenize(line)
    local out, i, n = {}, 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == " " or c == "\t" then
            i = i + 1
        elseif c == '"' or c == "'" then
            local j = line:find(c, i + 1, true)
            if not j then
                out[#out + 1] = line:sub(i + 1)
                break
            end
            out[#out + 1] = line:sub(i + 1, j - 1)
            i = j + 1
        else
            local j = line:find("[ \t]", i)
            if not j then
                out[#out + 1] = line:sub(i)
                break
            end
            out[#out + 1] = line:sub(i, j - 1)
            i = j
        end
    end
    return out
end

function M.textWidth(s)
    s = tostring(s or "")
    local w, i, n = 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            w, i = w + 1, i + 1
        elseif b < 0xE0 then
            w, i = w + 1, i + 2
        elseif b < 0xF0 then
            w, i = w + 2, i + 3
        else
            w, i = w + 2, i + 4
        end
    end
    return w
end

function M.fit(s, cols)
    s = tostring(s or "")
    cols = math.floor(tonumber(cols) or 0)
    if cols <= 0 then return "" end
    if M.textWidth(s) <= cols then return s end

    local ell = "…"
    local limit = math.max(0, cols - M.textWidth(ell))
    local out, w, i, n = {}, 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = (b < 0x80) and 1 or ((b < 0xE0) and 2 or ((b < 0xF0) and 3 or 4))
        local cw = (len == 1) and 1 or 2
        if w + cw > limit then break end
        out[#out + 1] = s:sub(i, i + len - 1)
        w = w + cw
        i = i + len
    end
    return table.concat(out) .. ell
end

function M.trunc(s, n)
    return M.fit(s, n)
end

function M.padRight(s, n)
    s = tostring(s or "")
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

function M.padLeft(s, n)
    s = tostring(s or "")
    if #s >= n then return s:sub(1, n) end
    return string.rep(" ", n - #s) .. s
end

function M.bar(pct, width)
    width = width or 10
    pct = math.max(0, math.min(1, tonumber(pct) or 0))
    local fill = math.floor(pct * width + 0.5)
    return string.rep("#", fill) .. string.rep("-", width - fill)
end

function M.hash(s)
    s = tostring(s or "")
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return string.format("%08x%04x", h, #s % 65536)
end

function M.exists(path)
    return fs.exists(path)
end

function M.isDir(path)
    return fs.exists(path) and fs.isDir(path)
end

function M.ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then
        fs.makeDir(path)
    end
end

function M.readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil, "文件不存在: " .. tostring(path) end
    local h = fs.open(path, "r")
    if not h then return nil, "无法打开: " .. tostring(path) end
    local data = h.readAll()
    h.close()
    return data
end

function M.writeFile(path, data)
    local dir = path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then M.ensureDir(dir) end
    local h = fs.open(path, "w")
    if not h then return false, "无法写入: " .. tostring(path) end
    h.write(data)
    h.close()
    return true
end

function M.basename(path)
    return (tostring(path):match("([^/]*)$"))
end

function M.listDir(path)
    if not M.isDir(path) then return {} end
    local ok, names = pcall(fs.list, path)
    if not ok or type(names) ~= "table" then return {} end
    return names
end

function M.appendLog(path, line, maxBytes)
    maxBytes = maxBytes or 64 * 1024
    local dir = path:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then M.ensureDir(dir) end
    local ok, size = pcall(function() return fs.getSize(path) end)
    if ok and size and size > maxBytes then
        local data = M.readFile(path) or ""
        M.writeFile(path, data:sub(-math.floor(maxBytes / 2)))
    end
    local h = fs.open(path, "a")
    if not h then return false end
    h.write(tostring(line) .. "\n")
    h.close()
    return true
end

function M.logLine(text)
    return string.format("[%s] %s", os.date("%H:%M:%S"), tostring(text))
end

M.CFG_PREFIX = "dcnet."

function M.loadCfg(defaults, meta)
    local out = {}
    for k, v in pairs(defaults or {}) do
        local name = M.CFG_PREFIX .. k
        if settings and settings.define and settings.get then
            local def = { default = v }
            if type(v) == "number" then def.type = "number"
            elseif type(v) == "boolean" then def.type = "boolean"
            else def.type = "string" end
            if meta and meta[k] then def.description = meta[k] end
            settings.define(name, def)
            local cur = settings.get(name)
            out[k] = (cur ~= nil) and cur or v
        else
            out[k] = v
        end
    end
    return out
end

function M.saveCfg(key, value)
    if settings and settings.set then
        settings.set(M.CFG_PREFIX .. key, value)
        return true
    end
    return false, "本机没有 settings API"
end

function M.cfgLines(cfg, meta)
    local out = {}
    for _, k in ipairs(M.sortedKeys(cfg)) do
        out[#out + 1] = string.format("  %-16s = %-10s %s", k, tostring(cfg[k]),
            (meta and meta[k]) or "")
    end
    return out
end

function M.loadChunk(src, chunkname, env)
    chunkname = chunkname or "=dcchunk"
    local fn, err
    if setfenv and loadstring then
        fn, err = loadstring(src, chunkname)
        if fn and env then setfenv(fn, env) end
    elseif env ~= nil then
        fn, err = load(src, chunkname, "t", env)
    else
        fn, err = load(src, chunkname, "t")
    end
    return fn, err
end

function M.runChunk(src, chunkname, env)
    local fn, err = M.loadChunk(src, chunkname, env)
    if not fn then return nil, "编译失败: " .. tostring(err) end
    local ok, res = pcall(fn)
    if not ok then return nil, "运行失败: " .. tostring(res) end
    return res
end

function M.copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

function M.sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "number" then return a < b end
            return tostring(a) < tostring(b)
        end
        return ta == "number"
    end)
    return keys
end

function M.parseArgs(tokens, params)
    local named, positional = {}, {}
    for _, tok in ipairs(tokens or {}) do
        local k, v = tostring(tok):match("^([%w_%-%.]+)=(.*)$")
        if k then named[k] = v else positional[#positional + 1] = tok end
    end

    local out, unknown = {}, {}
    params = params or {}
    for i, p in ipairs(params) do
        local raw = named[p.name]
        if raw == nil then raw = positional[i] end
        if raw == nil then
            out[p.name] = p.default
        else
            local v, err = M.coerce(raw, p.type)
            if err then return nil, string.format("参数 %s 无效: %s", p.name, err) end
            out[p.name] = v
        end
        named[p.name] = nil
    end
    for k, v in pairs(named) do unknown[#unknown + 1] = k .. "=" .. tostring(v) end
    if #unknown > 0 then
        return nil, "未知参数: " .. table.concat(unknown, ", ")
    end
    return out
end

function M.coerce(raw, kind)
    if kind == "number" then
        local n = tonumber(raw)
        if not n then return nil, "不是数字" end
        return n
    elseif kind == "boolean" then
        if raw == true or raw == "true" or raw == "1" or raw == "yes" then return true end
        if raw == false or raw == "false" or raw == "0" or raw == "no" then return false end
        return nil, "不是布尔值"
    elseif kind == "string" or kind == nil then
        return tostring(raw)
    end
    return raw
end

return M

end)

__dc_define("dc.protocol", function()
local M = {}

M.VERSION = 1
M.CTRL    = "dccomp"
M.PUSH    = "dcpush"

M.WHO      = "who"
M.HELLO    = "hello"
M.PULL     = "pull"
M.RESULT   = "result"
M.PROGRESS = "progress"
M.BYE      = "bye"
M.PONG     = "pong"

M.IAM      = "iam"
M.WELCOME  = "welcome"
M.TASK     = "task"
M.IDLE     = "idle"
M.CANCEL   = "cancel"
M.HALT     = "halt"
M.PING     = "ping"

M.BEAT     = "beat"
M.TAKEOVER = "takeover"
M.REPO     = "repo"
M.REPOINFO = "repoinfo"

M.SCREEN    = "screen"
M.SCREENBYE = "screenbye"
M.DISP      = "disp"
M.SCREENOFF = "screenoff"

M.FETCH    = "fetch"
M.PUT      = "put"
M.PUTACK   = "putack"
M.PUTDONE  = "putdone"
M.PUTOK    = "putok"
M.PUTMISS  = "putmiss"
M.REFERR   = "referr"

function M.msg(t, fields)
    local m = { t = t, ver = M.VERSION }
    for k, v in pairs(fields or {}) do m[k] = v end
    return m
end

function M.valid(m)
    return type(m) == "table" and type(m.t) == "string"
end

function M.compatible(m)
    local v = tonumber(m and m.ver) or 0
    if v ~= M.VERSION then
        return false, string.format("协议版本不匹配（对端 %d，本机 %d）", v, M.VERSION)
    end
    return true
end

return M

end)

__dc_define("dc.net", function()
local util = dc_require("dc.util")
local crypto = dc_require("dc.crypto")

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

M.SEQ_SKEW = 120

M.BULK_FIELDS = { ["d"] = "dck", ["src"] = "sck", ["lines"] = "lck" }

M.key = nil
M.seq = 0
M.sid = nil
M.stats = { signed = 0, badSig = 0, replay = 0, stale = 0, unsigned = 0, fresh = 0 }
M.seenSids = {}
M.lastBad = nil

function M.signingSupported()
    return crypto.available == true
end

function M.hasKey()
    return (M.key ~= nil and #M.key >= 8)
end

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

function M.fingerprint()
    if not M.hasKey() then return nil end
    local h = crypto.sha256("dcnet-key:" .. M.key)
    return h and h:sub(1, 8) or nil
end

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

function M.verify(sender, msg)
    if not M.hasKey() then return true end
    if type(msg) ~= "table" then return false, "消息格式非法" end
    if not (msg.sid and msg.seq and msg.ts and msg.sig) then
        M.stats.unsigned = M.stats.unsigned + 1
        M.lastBad = string.format("#%s 发来未签名的消息（type=%s）", tostring(sender), tostring(msg.t))
        return false, "未签名"
    end

    local now = os.epoch and os.epoch("utc") or (os.time() * 1000)
    if type(msg.ts) ~= "number" or math.abs(now - msg.ts) > M.SEQ_SKEW * 1000 then
        M.stats.stale = M.stats.stale + 1
        M.lastBad = string.format("#%s 的消息时间戳偏差过大", tostring(sender))
        return false, "时间戳无效"
    end

    local bare = M._bare(msg)
    local want = crypto.hmacSha256(M.key, crypto.canonical(bare))
    if not want or not crypto.equal(want, tostring(msg.sig)) then
        M.stats.badSig = M.stats.badSig + 1
        M.lastBad = string.format("#%s 的消息签名不对（type=%s）", tostring(sender), tostring(msg.t))
        return false, "签名错误"
    end

    local rec = M.seenSids[msg.sid]
    if rec and tonumber(msg.seq) and tonumber(msg.seq) <= rec.seq then
        M.stats.replay = M.stats.replay + 1
        M.lastBad = string.format("#%s 重复/回退的消息被丢弃（seq %s ≤ %s）",
            tostring(sender), tostring(msg.seq), tostring(rec.seq))
        return false, "重复消息"
    end
    M.seenSids[msg.sid] = { seq = tonumber(msg.seq) or 0, at = util.mono() }

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

function M.statsLines()
    local s = M.stats
    local out = { string.format("签名：已签 %d　放行 %d　丢弃 %d", s.signed, s.fresh,
        s.badSig + s.replay + s.stale + s.unsigned) }
    out[#out + 1] = string.format("  未签名 %d　签名错误 %d　重复 %d　时间戳无效 %d",
        s.unsigned, s.badSig, s.replay, s.stale)
    if M.lastBad then out[#out + 1] = "  最近一次拒绝：" .. M.lastBad end
    return out
end

function M.findModems()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(name)
        local isModem = false
        if ty == "modem" then
            isModem = true
        elseif type(ty) == "table" then
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
        if a.wireless ~= b.wireless then return (not a.wireless) end
        return a.name < b.name
    end)
    return found
end

function M.open()
    local modems = M.findModems()
    if #modems == 0 then
        return nil, "没有检测到调制解调器（modem）"
    end

    for _, md in ipairs(modems) do
        if netlib.isOpen(md.name) then return md.name, md.wireless end
    end
    for _, md in ipairs(modems) do
        local ok, err = pcall(netlib.open, md.name)
        if ok then return md.name, md.wireless end

        if err then M.lastError = tostring(err) end
    end
    return nil, "无法打开任何调制解调器" .. (M.lastError and (": " .. M.lastError) or "")
end

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

function M.describe(list)
    local wired, wireless = 0, 0
    for _, md in ipairs(list or {}) do
        if md.wireless then wireless = wireless + 1 else wired = wired + 1 end
    end
    if wired + wireless == 0 then return "无" end
    return string.format("%d 有线 / %d 无线", wired, wireless)
end

function M.send(target, msg, proto)
    if type(target) ~= "number" then return false, "目标 ID 非法" end

    if target <= 0 then return false, "目标不是网络节点" end
    if type(msg) == "table" then M.sign(msg) end
    local ok, res = pcall(netlib.send, target, msg, proto or util.PROTO_CTRL)
    if not ok then return false, tostring(res) end
    if res == false then return false, "网络未打开（" .. tostring(TRANSPORT) .. "）" end
    return true
end

function M.broadcast(msg, proto)
    if type(msg) == "table" then M.sign(msg) end
    local ok, res = pcall(netlib.broadcast, msg, proto or util.PROTO_CTRL)
    if not ok then return false, tostring(res) end
    if res == false then return false, "网络未打开（" .. tostring(TRANSPORT) .. "）" end
    return true
end

function M.receive(proto, timeout)
    local sender, msg = netlib.receive(proto, timeout)
    if not sender then return nil end
    return sender, msg
end

local xidCounter = 0
function M.newXid(tag)
    xidCounter = xidCounter + 1
    return string.format("%d-%d-%d-%s", os.getComputerID(), xidCounter,
        math.random(1000, 9999), tostring(tag or "x"))
end

return M

end)

__dc_define("dc.console", function()
local util = dc_require("dc.util")

local M = {}

local Console = {}
M.Console = Console

local BLACK = (util.colours and util.colours.black) or 32768
local WHITE = (util.colours and util.colours.white) or 1
local BLUE  = (util.colours and util.colours.blue) or 8

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Console })
    self.history   = {}
    self.title     = opts.title or "dccomp"
    self.hasPrompt = opts.hasPrompt ~= false
    self.bg        = opts.statusColour or BLUE
    self.fg        = opts.statusTextColour or WHITE
    self.statusText = ""
    term.clear()
    term.setCursorPos(1, 1)
    self:build()
    return self
end

function Console:build()
    local w, h = term.getSize()
    self.parent = term.current()
    self.w, self.h = w, h
    self.statusWin = window.create(self.parent, 1, 1, w, 1, true)
    if self.hasPrompt then
        self.logWin    = window.create(self.parent, 1, 2, w, math.max(1, h - 2), true)
        self.promptWin = window.create(self.parent, 1, h, w, 1, true)
    else
        self.logWin    = window.create(self.parent, 1, 2, w, math.max(1, h - 1), true)
        self.promptWin = nil
    end
    self:redrawStatus()
    term.redirect(self.hasPrompt and self.promptWin or self.logWin)
end

function Console:rebuild()
    term.redirect(self.parent)
    term.clear()
    term.setCursorPos(1, 1)
    self:build()
end

function Console:redrawStatus()
    local win = self.statusWin
    win.setBackgroundColour(self.bg)
    win.setTextColour(self.fg)
    win.clearLine()
    win.setCursorPos(1, 1)
    win.write(util.trunc(" " .. tostring(self.statusText), self.w))
    win.setBackgroundColour(BLACK)
    win.setTextColour(WHITE)
    win.setCursorPos(1, 1)
end

function Console:setStatus(text)
    self.statusText = text
    self:redrawStatus()
end

function Console:log(text, colour)
    term.redirect(self.logWin)
    if colour then term.setTextColour(colour) end
    print(tostring(text))
    if colour then term.setTextColour(WHITE) end
    term.redirect(self.hasPrompt and self.promptWin or self.logWin)
end

function Console:logLines(lines, colour)
    for _, l in ipairs(lines or {}) do self:log(l, colour) end
end

function Console:clearLog()
    self.logWin.clear()
    self.logWin.setCursorPos(1, 1)
end

function Console:prompt(prefix, completeFn)
    if not self.hasPrompt then return nil end
    local win = self.promptWin
    win.setCursorPos(1, 1)
    win.clearLine()
    win.setTextColour(WHITE)
    win.write(util.trunc(prefix or "> ", self.w))
    term.redirect(win)
    local line = read(nil, self.history, completeFn, nil)
    if line and util.trim(line) ~= "" then self.history[#self.history + 1] = line end
    term.redirect(win)
    return line
end

function Console:close()
    term.redirect(self.parent)
    term.setBackgroundColour(BLACK)
    term.setTextColour(WHITE)
    term.setCursorPos(1, self.h)
    term.clearLine()
end

local Null = {}
Null.__index = Null

function M.null(opts)
    opts = opts or {}
    local self = setmetatable({}, Null)
    self.logFile = opts.logFile
    self.title = opts.title
    self.statusText = ""
    if self.logFile then
        local dir = self.logFile:match("^(.*)/[^/]*$")
        if dir and dir ~= "" then util.ensureDir(dir) end
    end
    return self
end

function Null:setStatus(text) self.statusText = text end
function Null:log(text)
    if self.logFile then util.appendLog(self.logFile, util.logLine(text)) end
end
function Null:logLines(lines)
    for _, line in ipairs(lines or {}) do self:log(line) end
end
function Null:clearLog() end
function Null:prompt() sleep(1) return nil end
function Null:rebuild() end
function Null:close() end

return M

end)

__dc_define("dc.xfer", function()
local util   = dc_require("dc.util")
local proto  = dc_require("dc.protocol")
local net    = dc_require("dc.net")

local M = {}

M.CHUNK       = 4096
M.ACK_TIMEOUT = 4
M.MAX_TRIES   = 6
M.RECV_IDLE   = 45
M.RECV_WAIT   = 0.3

function M.newRegistry()
    return { senders = {}, results = {} }
end

function M.enqueue(reg, target, name, what, data, onDone)
    if type(data) ~= "string" or #data == 0 then return nil, "内容为空" end
    local s = M.newSender({ target = target, name = name, what = what, data = data,
        onDone = onDone })
    reg.senders[s.xid] = s
    return s.xid
end

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

function M.waitFor(reg, xid, timeout)
    local deadline = util.mono() + (timeout or 30)
    while true do
        local st = reg.results[xid]
        if st then
            reg.results[xid] = nil
            if st == "ok" then return true end
            return nil, "传输失败"
        end
        if util.mono() > deadline then
            reg.senders[xid] = nil
            reg.results[xid] = nil
            return nil, "传输超时"
        end
        os.startTimer(0.2)
        os.pullEvent()
    end
end

function M.estimateSeconds(bytes, chunks)
    local n = chunks or math.ceil((bytes or 0) / M.CHUNK)
    return math.min(120, n * 1.5 + 3)
end

function M.notify()
    os.queueEvent("dcpush_done")
end

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

function M.newSender(opts)
    local parts = chunkify(opts.data or "", opts.chunk or M.CHUNK)
    return {
        xid    = opts.xid or net.newXid("put"),
        target = opts.target,
        name   = opts.name or "file",
        what   = opts.what or "file",
        parts  = parts,
        n      = #parts,
        next   = 1,
        resent = {},
        state  = "data",
        awaiting = nil,
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

function M.senderPoll(s, send)
    if s.state == "ok" or s.state == "fail" then return s.state end
    local now = util.mono()

    if s.state == "data" then
        if s.awaiting then
            if now - s.sentAt < M.ACK_TIMEOUT then return s.state end
            s.tries = s.tries + 1
            if s.tries > M.MAX_TRIES then
                s.state, s.err = "fail", "分块确认超时"
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

    if now - s.sentAt > M.ACK_TIMEOUT then
        s.tries = s.tries + 1
        if s.tries > M.MAX_TRIES then
            s.state, s.err = "fail", "结束确认超时"
            if s.onDone then s.onDone(s.state, s) end
            return s.state
        end
        s.sentAt = now
        send(s.target, proto.msg(proto.PUTDONE, { xid = s.xid, n = s.n }), util.PROTO_PUSH)
    end
    return s.state
end

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
        return string.format("%s 已送达 #%d（%d 块，%s）", s.name, s.target, s.n, util.duration((util.mono() - s.startedAt) * 1000))
    elseif s.state == "fail" then
        return string.format("%s → #%d 失败：%s", s.name, s.target, tostring(s.err))
    end
    return string.format("%s → #%d 传输中 %d/%d", s.name, s.target, math.min(s.next - 1, s.n), s.n)
end

function M.newReceiver(xid, name, n)
    return {
        xid = xid, name = name, n = n,
        parts = {}, count = 0,
        updatedAt = util.mono(),
        written = false,
    }
end

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

function M.recvExpired(r)
    return (util.mono() - r.updatedAt) > M.RECV_IDLE
end

M.chunkify = chunkify

return M

end)

__dc_define("dc.jobs", function()
local util = dc_require("dc.util")

local M = {}

function M.validate(def)
    if type(def) ~= "table" then return nil, "作业必须 return 一个 table" end
    if type(def.name) ~= "string" or def.name == "" then return nil, "缺少 name 字段" end
    if type(def.map) ~= "function" and type(def.cloud) ~= "table" then
        return nil, "缺少 map 函数（或用于云端卸载的 cloud 定义）"
    end
    if def.map ~= nil and type(def.map) ~= "function" then return nil, "map 必须是函数" end
    if def.cloud ~= nil then
        if type(def.cloud) ~= "table" then return nil, "cloud 必须是 table" end
        if type(def.cloud.build) ~= "function" then return nil, "cloud.build 必须是函数" end
        if type(def.cloud.parse) ~= "function" then return nil, "cloud.parse 必须是函数" end
        if def.cloud.endpoint ~= nil and type(def.cloud.endpoint) ~= "string" then
            return nil, "cloud.endpoint 必须是字符串"
        end
    end
    if def.split ~= nil and type(def.split) ~= "function" then return nil, "split 必须是函数" end
    if def.reduce ~= nil and type(def.reduce) ~= "function" then return nil, "reduce 必须是函数" end
    if def.format ~= nil and type(def.format) ~= "function" then return nil, "format 必须是函数" end
    if def.params ~= nil and type(def.params) ~= "table" then return nil, "params 必须是数组" end
    return true
end

function M.buildCloudRequest(def, task, args)
    if not (def and def.cloud and def.cloud.build) then
        return nil, "作业没有定义 cloud.build"
    end
    local ok, body = pcall(def.cloud.build, task, args)
    if not ok then return nil, tostring(body) end
    if body == nil then return nil, "cloud.build 返回了 nil" end
    return body
end

function M.parseCloudResponse(def, decoded, task, args)
    if not (def and def.cloud and def.cloud.parse) then
        return nil, "作业没有定义 cloud.parse"
    end
    local ok, data = pcall(def.cloud.parse, decoded, task, args)
    if not ok then return nil, tostring(data) end
    if data == nil then return nil, "cloud.parse 返回了 nil" end
    return data
end

function M.runReduce(src, payload, args, ctx)
    if type(payload) ~= "table" or type(payload.__reduce) ~= "table" then
        return nil, "reduce 任务负载格式不对（缺少 __reduce）"
    end
    local env = setmetatable({}, { __index = _G })
    env.ctx = ctx
    local fn, err = util.loadChunk(src, "=dcjob", env)
    if not fn then return nil, "作业源码编译失败: " .. tostring(err) end
    local ok, def = pcall(fn)
    if not ok then return nil, "作业初始化失败: " .. tostring(def) end
    local vok, verr = M.validate(def)
    if not vok then return nil, verr end
    if type(def.reduce) ~= "function" then
        return nil, "该作业没有 reduce，不能做两级汇总"
    end

    local rok, res = pcall(def.reduce, payload.__reduce, args)
    if not rok then return nil, tostring(res) end
    if res == nil then return nil, "reduce 返回了 nil" end
    local sok = pcall(textutils.serialize, res)
    if not sok then return nil, "reduce 返回值无法序列化" end
    return res
end

function M.loadSource(src, chunkname)
    local def, err = util.runChunk(src, chunkname or "=dcjob")
    if not def then return nil, err end
    local ok, verr = M.validate(def)
    if not ok then return nil, verr end
    def.source = src
    def.hash   = util.hash(src)
    return def
end

function M.loadFile(path)
    local src, err = util.readFile(path)
    if not src then return nil, err end
    local def, err2 = M.loadSource(src, "@" .. tostring(path))
    if not def then return nil, err2 end
    def.path = path
    return def
end

function M.safeName(name)
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
        return nil, "作业名只能包含字母、数字、下划线和短横线"
    end
    return name
end

function M.loadName(name)
    local ok, err = M.safeName(name)
    if not ok then return nil, err end
    return M.loadFile(util.JOB_DIR .. "/" .. name .. ".lua")
end

function M.list()
    local out = {}
    for _, f in ipairs(util.listDir(util.JOB_DIR)) do
        local name = f:match("^(.*)%.lua$")
        if name then
            local def, err = M.loadName(name)
            out[#out + 1] = {
                name    = name,
                ok      = def ~= nil,
                summary = def and (def.summary or "") or ("加载失败: " .. tostring(err)),
                params  = def and def.params or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.installDefaults(sources)
    util.ensureDir(util.JOB_DIR)
    local created = {}
    for name, src in pairs(sources or {}) do
        local path = util.JOB_DIR .. "/" .. name
        if not fs.exists(path) then
            local ok = util.writeFile(path, src)
            if ok then created[#created + 1] = name end
        end
    end
    table.sort(created)
    return created
end

function M.resolveArgs(def, tokens)
    return util.parseArgs(tokens, def.params or {})
end

function M.paramHelp(def)
    local parts = {}
    for _, p in ipairs(def.params or {}) do
        parts[#parts + 1] = string.format("%s=%s", p.name, tostring(p.default))
    end
    return table.concat(parts, " ")
end

function M.split(def, args)
    if not def.split then return { args } end
    local ok, tasks = pcall(def.split, args)
    if not ok then return nil, "split 执行失败: " .. tostring(tasks) end
    if type(tasks) ~= "table" or #tasks == 0 then
        return nil, "split 必须返回非空的任务数组"
    end
    return tasks
end

function M.reduce(def, results, args)
    if not def.reduce then return results end
    local ok, res = pcall(def.reduce, results, args)
    if not ok then return nil, "reduce 执行失败: " .. tostring(res) end
    return res
end

function M.format(def, res, args)
    if def.format then
        local ok, text = pcall(def.format, res, args)
        if ok and text ~= nil then return tostring(text) end
        if not ok then return "format 执行失败: " .. tostring(text) end
    end
    local ok, text = pcall(textutils.serialize, res)
    if ok then return text end
    return tostring(res)
end

function M.runMap(src, payload, ctx)
    local env = setmetatable({}, { __index = _G })
    env.ctx = ctx
    local fn, err = util.loadChunk(src, "=dcjob", env)
    if not fn then return nil, "作业源码编译失败: " .. tostring(err) end
    local ok, def = pcall(fn)
    if not ok then return nil, "作业初始化失败: " .. tostring(def) end
    local vok, verr = M.validate(def)
    if not vok then return nil, verr end
    if type(def.map) ~= "function" then
        return nil, "该作业没有本地 map（只能交给云端执行）"
    end

    local callOk, res = pcall(def.map, payload, ctx)
    if not callOk then return nil, tostring(res) end

    if res == nil then
        return nil, "map 返回了 nil（要表达\"没找到\"请返回显式结构，例如 { hit = false }）"
    end

    local sok = pcall(textutils.serialize, res)
    if not sok then return nil, "map 返回值无法序列化（可能包含函数或协程）" end
    return res
end

return M

end)

__dc_define("dc.worker", function()
local util    = dc_require("dc.util")
local proto   = dc_require("dc.protocol")
local net     = dc_require("dc.net")
local jobs    = dc_require("dc.jobs")
local console = dc_require("dc.console")
local xfer    = dc_require("dc.xfer")
local state   = dc_require("dc.state")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local YIELD_INTERVAL = 0.05
local REPORT_INTERVAL = 0.7

M.DEFAULTS = {
    maxRestarts  = 5,
    restartDelay = 5,
    rebootAfter  = 0,
}
M.CFG_META = {
    maxRestarts  = "异常后最多自动重启次数",
    restartDelay = "自动重启间隔（秒）",
    rebootAfter  = "失联多久重启电脑（0=关）",
}

local function runOnce(opts)
    opts = opts or {}

    local LOG = util.ROOT .. "/logs/node-" .. os.getComputerID() .. ".log"
    local function fileLog(text)
        util.appendLog(LOG, util.logLine(text))
    end
    fileLog("节点启动 v" .. util.VERSION)

    local modems, failedModems = net.openAll()
    if #modems == 0 then
        printError("[dcnet] 没有检测到调制解调器（modem）")
        print("[dcnet] 请在有线调制解调器上接好网络线缆，并用 peripheral.getNames() 确认。")
        fileLog("没有检测到调制解调器")
        return false, "没有检测到调制解调器"
    end

    local ui
    if opts.headless then
        ui = console.null({ title = "dcnet worker", hasPrompt = false, logFile = LOG })
    else
        ui = console.new({ title = "dcnet worker", hasPrompt = false })
    end
    ui:log(string.format("dcnet 运算节点 v%s", util.VERSION), col("lime", 32))
    ui:log(string.format("网络：已打开 %s（%s）  本机 ID #%d",
        net.describe(modems),
        (function()
            local t = {}
            for _, md in ipairs(modems) do t[#t + 1] = md.name end
            return table.concat(t, ",")
        end)(),
        os.getComputerID()))
    for _, e in ipairs(failedModems or {}) do
        ui:log("  打开 modem 失败：" .. e, col("orange", 2))
    end

    local S = {
        id       = os.getComputerID(),
        name     = opts.name or os.getComputerLabel() or ("node-" .. os.getComputerID()),
        master   = tonumber(opts.master),
        wireless = (modems[1] and modems[1].wireless) or false,
        cfg      = { pollInterval = 1.5, taskTimeout = 90, fileChannel = true, inlineLimit = 8192 },
        have     = nil,
        cache    = {},
        cacheOrder = {},
        state    = "connecting",
        task     = nil,
        inbox    = {},
        running  = true,
        lastMasterMsg = util.now(),
        idleUntil = 0,
        lastPull = 0,
        done = 0, fail = 0, totalMs = 0,
        progress = 0, note = "",
        curLabel = "",
    }

    local function discover()
        for _ = 1, 6 do
            net.broadcast(proto.msg(proto.WHO, {}), util.PROTO_CTRL)
            local sender, msg = net.receive(util.PROTO_CTRL, 1.2)
            if msg and proto.valid(msg) and msg.t == proto.IAM then
                S.master = tonumber(msg.master) or sender
                return true
            end
        end
        return false
    end

    local function hello()
        S.state = "connecting"
        net.send(S.master, proto.msg(proto.HELLO, {
            name = S.name, wireless = S.wireless, have = S.have,
        }), util.PROTO_CTRL)
        S.lastMasterMsg = util.now()
    end

    if not S.master then
        ui:log("正在寻找主控…")
        if not discover() then
            ui:log("没有找到主控。", col("red", 16384))
            ui:log("请确认：① 主控程序已在同一条有线网络上运行；② 网络线缆接好。")
            ui:log("也可以用 worker <主控ID> 直接指定。")
            fileLog("找不到主控")
            return false, "找不到主控"
        end
    end
    ui:log("已找到主控 #" .. tostring(S.master))
    fileLog("已找到主控 #" .. tostring(S.master))
    hello()

    local function statusText()
        local st = ({ connecting = "握手", idle = "空闲", busy = "运算" })[S.state] or S.state
        local cur = ""
        if S.state == "busy" then
            cur = string.format("  %s %d%%", util.trunc(S.curLabel, 18), math.floor((S.progress or 0) * 100))
        end
        return string.format("节点 #%d %s | 主控 #%s | %s%s | 完成 %d 失败 %d",
            S.id, util.trunc(S.name, 10), tostring(S.master or "?"), st, cur, S.done, S.fail)
    end

    local function refresh()
        ui:setStatus(statusText())
    end

    local function trimCache()
        while #S.cacheOrder > 3 do
            local old = table.remove(S.cacheOrder, 1)
            S.cache[old] = nil
        end
    end

    local M0 = { reg = xfer.newRegistry() }

    local function fetchPool(name, timeout)
        local deadline = util.mono() + (timeout or 45)
        local lastAsk = 0
        while util.mono() < deadline do
            if util.mono() > lastAsk + 3 then
                lastAsk = util.mono()
                net.send(S.master, proto.msg(proto.FETCH, {
                    xid = net.newXid("gett"), what = "taskdata", name = name,
                }), util.PROTO_PUSH)
            end
            os.startTimer(0.5)
            local ev = { os.pullEvent() }
            if ev[1] == "dcpool" and ev[2] == name and util.exists(state.poolPath(name)) then
                return state.poolGet(name)
            end
        end
        return nil, "等待负载超时"
    end

    local function runTask(msg)

        if msg.payloadRef and msg.payload == nil then
            local value, ferr = fetchPool(msg.payloadRef)
            if value == nil then
                S.state = "idle"
                S.curLabel = nil
                net.send(S.master, proto.msg(proto.RESULT, {
                    job = msg.job, task = msg.task, ok = false,
                    err = "取任务负载失败: " .. tostring(ferr), ms = 0,
                }), util.PROTO_CTRL)
                ui:log(string.format("任务 %d.%d 取负载失败：%s",
                    msg.job or 0, msg.task or 0, tostring(ferr)), col("red", 16384))
                return
            end
            msg.payload = value
        end

        local t0 = util.mono()
        S.state = "busy"
        S.progress, S.note = 0, ""
        S.curLabel = string.format("%d.%d", msg.job or 0, msg.task or 0)

        local src = msg.src or S.cache[msg.hash]

        if src and msg.hash and util.hash(src) ~= msg.hash then
            S.state = "idle"
            S.curLabel = nil
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false,
                err = "作业源码校验失败（哈希不符）", ms = 0,
            }), util.PROTO_CTRL)
            ui:log(string.format("任务 %d.%d 的源码哈希不符，拒绝执行",
                msg.job or 0, msg.task or 0), col("red", 16384))
            S.cache[msg.hash] = nil
            return
        end
        if not src then
            S.state = "idle"
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false,
                err = "本地没有该作业源码（哈希 " .. tostring(msg.hash) .. "）", ms = 0,
            }), util.PROTO_CTRL)
            ui:log(string.format("任务 %d.%d 缺少作业源码", msg.job or 0, msg.task or 0), col("red", 16384))
            return
        end
        if msg.src and not S.cache[msg.hash] then
            S.cache[msg.hash] = msg.src
            S.cacheOrder[#S.cacheOrder + 1] = msg.hash
            trimCache()
            ui:log(string.format("已接收作业源码 %s（%s）", tostring(msg.name), util.bytes(#msg.src)))
        end
        S.have = msg.hash

        local cur = { job = msg.job, task = msg.task, cancelled = false }
        S.task = cur
        local lastYield, lastReport = util.mono(), util.mono()

        local function report(force)
            local now = util.mono()
            if not force and now - lastReport < REPORT_INTERVAL then return end
            lastReport = now
            net.send(S.master, proto.msg(proto.PROGRESS, {
                job = msg.job, task = msg.task,
                pct = S.progress, note = S.note,
            }), util.PROTO_CTRL)
        end

        local ctx = {
            worker = S.id, job = msg.job, task = msg.task,
            payload = msg.payload,
            now = util.now, mono = util.mono,

            progress = function(pct, note)
                S.progress = math.max(0, math.min(1, tonumber(pct) or S.progress))
                if note then S.note = tostring(note) end
                report(false)
            end,

            log = function(text) ui:log("  " .. tostring(text), col("lightGray", 1024)) end,

            canceled = function() return cur.cancelled end,

            tick = function()
                local now = util.mono()
                if now - lastYield < YIELD_INTERVAL then return end
                lastYield = now
                report(false)
                os.queueEvent("dc_yield")
                os.pullEvent("dc_yield")
            end,
        }

        local res, err
        if msg.phase == "reduce" then

            res, err = jobs.runReduce(src, msg.payload, msg.args, ctx)
        else
            res, err = jobs.runMap(src, msg.payload, ctx)
        end
        local ms = math.floor((util.mono() - t0) * 1000)
        S.task = nil

        if cur.cancelled then
            ui:log(string.format("任务 %d.%d 已取消（%.1fs）", msg.job or 0, msg.task or 0, ms / 1000),
                col("orange", 2))
        elseif res == nil and err then
            S.fail = S.fail + 1
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = false, err = err, ms = ms,
            }), util.PROTO_CTRL)
            ui:log(string.format("任务 %d.%d 失败：%s", msg.job or 0, msg.task or 0, tostring(err)),
                col("red", 16384))
        else
            S.done = S.done + 1
            S.totalMs = S.totalMs + ms

            local dataRef
            if S.cfg.fileChannel ~= false then
                local okEnc, encoded = pcall(textutils.serialize, res)
                if okEnc and type(encoded) == "string"
                    and #encoded > (S.cfg.inlineLimit or 8192) then
                    local name = string.format("res-%d-%d.dat", msg.job or 0, msg.task or 0)
                    if state.poolPut(name, res) then
                        local xid = xfer.enqueue(M0.reg, S.master, name, "resdata", encoded)
                        if xid then
                            local okPush, perr = xfer.waitFor(M0.reg, xid, 60)
                            if okPush then
                                dataRef = name
                                ui:log(string.format("任务 %d.%d 结果 %s，走文件通道推给主控",
                                    msg.job or 0, msg.task or 0, util.bytes(#encoded)),
                                    col("lightGray", 1024))
                            else
                                ui:log("结果推送失败，改回内联：" .. tostring(perr), col("orange", 2))
                            end
                        end
                    end
                end
            end
            net.send(S.master, proto.msg(proto.RESULT, {
                job = msg.job, task = msg.task, ok = true,
                data = dataRef and nil or res, dataRef = dataRef, ms = ms,
            }), util.PROTO_CTRL)
            ui:log(string.format("任务 %d.%d 完成（%s）", msg.job or 0, msg.task or 0, util.duration(ms)),
                col("lime", 32))
        end

        S.state = "idle"
        S.progress, S.note, S.curLabel = 0, "", ""
        refresh()
    end

    local function netLoop()
        while S.running do
            local sender, msg = net.receive(util.PROTO_CTRL, 2)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("丢弃 #%s 的消息：%s", tostring(sender), tostring(why)),
                        col("orange", 2))
                    S.dropped = (S.dropped or 0) + 1
                else
                local fromMaster = (sender == S.master)
                if fromMaster then S.lastMasterMsg = util.now() end

                if msg.t == proto.WELCOME and fromMaster then
                    local vok, verr = proto.compatible(msg)
                    if not vok then
                        ui:log("主控协议版本不兼容：" .. tostring(verr), col("red", 16384))
                        ui:log("请把本节点与主控升级到同一版本后重试。", col("red", 16384))
                        S.running = false
                        return
                    end
                    if type(msg.cfg) == "table" then
                        S.cfg.pollInterval = msg.cfg.pollInterval or S.cfg.pollInterval
                        S.cfg.taskTimeout  = msg.cfg.taskTimeout or S.cfg.taskTimeout
                        if msg.cfg.fileChannel ~= nil then
                            S.cfg.fileChannel = msg.cfg.fileChannel
                        end
                        S.cfg.inlineLimit = msg.cfg.inlineLimit or S.cfg.inlineLimit
                        S.cfg.reHelloAfter = msg.cfg.reHelloAfter or S.cfg.reHelloAfter
                        S.cfg.rediscoverAfter = msg.cfg.rediscoverAfter or S.cfg.rediscoverAfter
                    end
                    if S.state == "connecting" then
                        S.state = "idle"
                        ui:log("已在主控登记，等待任务。", col("lime", 32))
                        refresh()
                    end

                elseif msg.t == proto.TASK and fromMaster then
                    S.inbox[#S.inbox + 1] = msg
                    os.queueEvent("dc_inbox")

                elseif msg.t == proto.IDLE and fromMaster then
                    S.idleUntil = util.mono() + math.max(0.2, tonumber(msg.wait) or S.cfg.pollInterval)

                elseif msg.t == proto.CANCEL and fromMaster then

                    if S.task and S.task.job == msg.job and S.task.task == msg.task then
                        S.task.cancelled = true
                    end

                elseif msg.t == proto.HALT and fromMaster then
                    S.running = false
                    net.send(S.master, proto.msg(proto.BYE, {
                        reason = msg.reboot and "reboot" or "halt",
                    }), util.PROTO_CTRL)
                    if msg.reboot then
                        ui:log("收到主控的重启指令，正在重启电脑…", col("orange", 2))
                        ui:log("（重启后由 /startup.lua 自动拉起新版本的 worker.lua）",
                            col("lightGray", 1024))
                        os.sleep(0.6)
                        os.reboot()
                    end
                    ui:log("收到主控的 halt 指令，节点退出。", col("orange", 2))
                    return

                elseif msg.t == proto.PING and fromMaster then
                    net.send(S.master, proto.msg(proto.PONG, {}), util.PROTO_CTRL)

                elseif msg.t == proto.IAM then

                    local who = tonumber(msg.master) or sender
                    if who and who ~= S.master then
                        S.master = who
                        S.lastMasterMsg = util.now()
                        ui:log("发现主控 #" .. tostring(who) .. "，重新登记…", col("lime", 32))
                        hello()
                    end
                end
                end
            end
        end
    end

    local function workLoop()
        while S.running do
            local msg = table.remove(S.inbox, 1)
            if msg then
                runTask(msg)
            else
                os.pullEvent("dc_inbox")
            end
        end
    end

    local function pushLoop()
        local recvs = {}
        while S.running do
            local sender, msg = net.receive(util.PROTO_PUSH, xfer.RECV_WAIT)
            local got = (msg and proto.valid(msg) and msg.xid and net.verify(sender, msg))
            if got then
                if msg.t == proto.PUT or msg.t == proto.PUTDONE then
                    local r = recvs[msg.xid]
                    if not r and msg.t == proto.PUT then
                        r = xfer.newReceiver(msg.xid, msg.name, msg.n)
                        recvs[msg.xid] = r
                    end
                    if r then
                        local action, value = xfer.recvOnMsg(r, msg)

                        if action == "ack" then
                            net.send(sender, proto.msg(proto.PUTACK, { xid = msg.xid, i = value }),
                                util.PROTO_PUSH)

                        elseif action == "miss" then
                            net.send(sender, proto.msg(proto.PUTMISS, { xid = msg.xid, miss = value }),
                                util.PROTO_PUSH)

                        elseif action == "complete" then
                            recvs[msg.xid] = nil
                            local name = tostring(r.name or "")
                            if state.validPoolName(name) and name:match("^task%-") then

                                state.poolPut(name, nil)
                                local ok, err = util.writeFile(state.poolPath(name), value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    os.queueEvent("dcpool", name)
                                else
                                    ui:log("负载写入失败：" .. tostring(err), col("red", 16384))
                                end
                            elseif name == "worker.lua" and #value <= 512 * 1024 then
                                local ok, err = util.writeFile(util.WORKER_FILE, value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    ui:log(string.format("已收到新版本（%s），用主控的 reboot 指令重启后生效",
                                        util.bytes(#value)), col("lime", 32))
                                else
                                    ui:log("写入失败：" .. tostring(err), col("red", 16384))
                                end
                            else
                                ui:log("拒绝写入未知文件：" .. name, col("red", 16384))
                            end

                        elseif xfer.recvExpired(r) then
                            recvs[msg.xid] = nil
                        end
                    end
                else

                    local s = M0.reg.senders[msg.xid]
                    if s then xfer.senderOnMsg(s, msg) end
                end
            end

            if xfer.pollRegistry(M0.reg, net.send) then xfer.notify() end
        end
    end

    local function beatLoop()
        local lastUi = 0
        while S.running do
            os.sleep(0.5)
            local nowMs, mono = util.now(), util.mono()

            local silent = nowMs - S.lastMasterMsg
            local reHello = (S.cfg.reHelloAfter or 8) * 1000
            local reDiscover = (S.cfg.rediscoverAfter or 25) * 1000
            if silent > reDiscover then
                ui:log("与主控失联，重新搜索…", col("orange", 2))
                S.master = nil
                if discover() then
                    ui:log("重新找到主控 #" .. tostring(S.master))
                    hello()
                    S.lastMasterMsg = util.now()
                else
                    S.state = "connecting"

                    S.lastMasterMsg = util.now() - (reDiscover - 3000)
                end
            elseif silent > reHello and S.state ~= "busy" then
                hello()
            end

            local rebootAfter = tonumber(opts.rebootAfter) or 0
            if rebootAfter > 0 and S.master == nil
                and (nowMs - (S.lastMasterMsg or nowMs)) > rebootAfter * 1000 then
                ui:log(string.format("已经 %d 秒找不到主控，按看门狗设置重启电脑…", rebootAfter),
                    col("orange", 2))
                fileLog("看门狗：联系不上主控，重启电脑")
                sleep(0.5)
                os.reboot()
            end

            if S.state == "idle" and S.master and mono >= (S.idleUntil or 0)
                and (mono - S.lastPull) > S.cfg.pollInterval then
                S.lastPull = mono
                net.send(S.master, proto.msg(proto.PULL, { have = S.have }), util.PROTO_CTRL)
            end

            if nowMs - lastUi > 400 then
                lastUi = nowMs
                refresh()
            end
        end
    end

    refresh()
    ui:log(string.format("节点名：%s（用 label set <名字> 可以改名）", S.name))

    local savedKey = rawget(_G, "DCNET_KEY") or settings.get("dcnet.key")
    if savedKey and savedKey ~= "" then
        local kok, kerr = net.setKey(savedKey)
        if kok then
            ui:log("消息签名已启用（密钥指纹 " .. tostring(net.fingerprint()) .. "）",
                col("lime", 32))
        else
            ui:log("启用消息签名失败：" .. tostring(kerr), col("orange", 2))
        end
    end
    ui:log("按 Ctrl+T 可以终止节点。")

    local ok, err = pcall(parallel.waitForAny, netLoop, workLoop, beatLoop, pushLoop)
    if not opts.headless then term.redirect(term.native()) end
    if not ok then
        printError("[dcnet] 节点异常终止: " .. tostring(err))
        fileLog("节点异常终止：" .. tostring(err))
        return false, tostring(err)
    end
    print("[dcnet] 节点已停止。")
    fileLog("节点正常停止")
    return true
end

function M.run(opts)
    opts = opts or {}

    local cfg = util.loadCfg(M.DEFAULTS, M.CFG_META)
    for k, v in pairs(opts) do cfg[k] = v end

    local maxRestarts = tonumber(cfg.maxRestarts) or 5
    local delay = tonumber(cfg.restartDelay) or 5
    local restarts = 0

    while true do
        local ok, err = runOnce(cfg)
        if ok then return true end

        restarts = restarts + 1
        util.appendLog(util.ROOT .. "/logs/node-" .. os.getComputerID() .. ".log",
            util.logLine(string.format("第 %d 次异常：%s", restarts, tostring(err))))

        if restarts > maxRestarts then
            printError(string.format("[dcnet] 节点连续异常 %d 次，停止自动重启：%s",
                restarts, tostring(err)))
            return false, err
        end
        print(string.format("[dcnet] 节点异常（%s），%d 秒后自动重启（第 %d/%d 次）",
            tostring(err), delay, restarts, maxRestarts))
        sleep(delay)
    end
end

return M

end)

__dc_define("dc.crypto", function()
local M = {}

local B = rawget(_G, "bit32")
if not B and rawget(_G, "bit") then
    local bit = rawget(_G, "bit")
    B = {
        band = bit.band, bor = bit.bor, bxor = bit.bxor, bnot = bit.bnot,
        lshift = bit.lshift, rshift = bit.rshift,
    }
end
M.available = (B ~= nil and type(B.band) == "function")

local MASK = 0xFFFFFFFF

local function add(...)
    local s = 0
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v then s = s + v end
    end
    return B.band(s, MASK)
end

local function ror(x, n)
    return B.bor(B.rshift(x, n), B.lshift(x, 32 - n))
end

local function toWord(a, b, c, d)
    return B.band(a * 0x1000000 + b * 0x10000 + c * 0x100 + d, MASK)
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function M.sha256bin(msg)
    if not M.available then return nil, "本机没有 bit32，无法计算哈希" end
    msg = tostring(msg or "")
    local h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    local len = #msg
    local bits = len * 8
    local zeroPad = (55 - len) % 64
    local tail = string.char(0x80) .. string.rep("\0", zeroPad)
    local hi = math.floor(bits / 4294967296) % 4294967296
    local lo = bits % 4294967296
    for shift = 24, 0, -8 do
        tail = tail .. string.char(math.floor(hi / (2 ^ shift)) % 256)
    end
    for shift = 24, 0, -8 do
        tail = tail .. string.char(math.floor(lo / (2 ^ shift)) % 256)
    end
    local data = msg .. tail

    local w = {}
    for base = 1, #data, 64 do
        local chunk = data:sub(base, base + 63)
        for i = 0, 15 do
            local o = i * 4 + 1
            w[i + 1] = toWord(chunk:byte(o, o + 3))
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = B.bxor(ror(x, 7), ror(x, 18), B.rshift(x, 3))
            local s1 = B.bxor(ror(y, 17), ror(y, 19), B.rshift(y, 10))
            w[i] = add(w[i - 16], s0, w[i - 7], s1)
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local S1 = B.bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = B.bxor(B.band(e, f), B.band(B.bnot(e), g))
            local t1 = add(hh, S1, ch, K[i], w[i])
            local S0 = B.bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = B.bxor(B.band(a, b), B.band(a, c), B.band(b, c))
            local t2 = add(S0, maj)
            hh, g, f = g, f, e
            e = add(d, t1)
            d, c, b = c, b, a
            a = add(t1, t2)
        end
        h[1], h[2], h[3], h[4] = add(h[1], a), add(h[2], b), add(h[3], c), add(h[4], d)
        h[5], h[6], h[7], h[8] = add(h[5], e), add(h[6], f), add(h[7], g), add(h[8], hh)
    end

    local out = {}
    for i = 1, 8 do
        out[i] = string.char(
            math.floor(h[i] / 0x1000000) % 256,
            math.floor(h[i] / 0x10000) % 256,
            math.floor(h[i] / 0x100) % 256,
            h[i] % 256)
    end
    return table.concat(out)
end

function M.sha256(msg)
    local bin, err = M.sha256bin(msg)
    if not bin then return nil, err end
    return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.hmacSha256bin(key, msg)
    if not M.available then return nil, "本机没有 bit32，无法计算 HMAC" end
    key = tostring(key or "")
    msg = tostring(msg or "")
    if #key > 64 then
        local k = M.sha256bin(key)
        if not k then return nil, "密钥哈希失败" end
        key = k
    end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local b = key:byte(i)
        ipad[i] = string.char(B.bxor(b, 0x36))
        opad[i] = string.char(B.bxor(b, 0x5c))
    end
    local inner = M.sha256bin(table.concat(ipad) .. msg)
    if not inner then return nil, "内部哈希失败" end
    return M.sha256bin(table.concat(opad) .. inner)
end

function M.hmacSha256(key, msg)
    local bin, err = M.hmacSha256bin(key, msg)
    if not bin then return nil, err end
    return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function M.equal(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

function M.canonical(value, seen)
    local t = type(value)
    if t == "number" then
        return string.format("%.17g", value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "nil" then
        return "nil"
    elseif t ~= "table" then
        return t
    end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    local parts = { "{" }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = M.canonical(tostring(k), seen)
        parts[#parts + 1] = "="
        parts[#parts + 1] = M.canonical(value[k], seen)
        parts[#parts + 1] = ","
    end
    parts[#parts + 1] = "}"
    seen[value] = nil
    return table.concat(parts)
end

local counter = 0
function M.randomHex(bytes)
    bytes = bytes or 8
    counter = counter + 1
    local id = (os.getComputerID and os.getComputerID()) or 0
    local epoch = os.epoch and os.epoch("utc") or 0
    local seed = tostring(id) .. "|" .. tostring(counter) .. "|"
        .. tostring(math.floor(epoch)) .. "|"
        .. tostring(math.floor((os.clock() or 0) * 1000000)) .. "|"
        .. tostring(math.random(1, 2147483646))
    local h = M.sha256(seed) or string.rep("0", 64)
    return h:sub(1, bytes * 2)
end

function M.selftest()
    local out = {}
    local function expect(what, got, want)
        out[#out + 1] = { name = what, ok = (got == want), got = got, want = want }
    end
    expect("sha256(\"\")",
        M.sha256(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    expect("sha256(\"abc\")",
        M.sha256("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect("sha256(长串)",
        M.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

    expect("hmac-sha256(RFC4231 #1)",
        M.hmacSha256(string.rep("\11", 20), "Hi There"),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")

    expect("hmac-sha256(RFC4231 #2)",
        M.hmacSha256("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    return out
end

return M

end)

__dc_define("dc.state", function()
local util = dc_require("dc.util")

local M = {}

M.DIR       = util.ROOT .. "/state"
M.SNAP      = M.DIR .. "/jobs.dat"
M.CACHE_DIR = util.ROOT .. "/cache"
M.HISTORY   = util.ROOT .. "/history.log"
M.SNAP_VERSION = 1

function M.ensureDirs()
    util.ensureDir(M.DIR)
    util.ensureDir(M.CACHE_DIR)
end

function M.snapshot(sched)
    M.ensureDirs()
    local snap = {
        version = M.SNAP_VERSION,
        savedAt = util.now(),
        nextJobId = sched.nextJobId,
        jobOrder = {},
        jobs = {},
    }
    for _, id in ipairs(sched.jobOrder) do
        local job = sched.jobs[id]
        if job and (job.state == "queued" or job.state == "running") then
            snap.jobOrder[#snap.jobOrder + 1] = id
            local tasks = {}
            for tid, t in pairs(job.tasks) do
                tasks[tid] = {
                    state = (t.state == "done") and "done" or "pending",
                    payload = t.payload,
                    result = t.result,
                    ms = t.ms,
                    tries = t.tries or 0,
                    err = t.err,
                    reduce = t.reduce or nil,
                }
            end
            snap.jobs[id] = {
                id = id, name = job.name, args = job.args,
                source = job.source, hash = job.hash,
                priority = job.priority, paused = job.paused,
                submittedAt = job.submittedAt, order = job.order, tasks = tasks,
            }
        end
    end
    local ok, err = util.writeFile(M.SNAP, textutils.serialize(snap))
    if not ok then return false, err end
    return true, snap
end

function M.hasSnapshot()
    return util.exists(M.SNAP)
end

function M.restore(sched, jobsModule)
    if not util.exists(M.SNAP) then return 0, "没有快照" end
    local raw, err = util.readFile(M.SNAP)
    if not raw then return 0, err end

    local ok, snap = pcall(textutils.unserialize, raw)
    if not ok or type(snap) ~= "table" or snap.version ~= M.SNAP_VERSION then
        return 0, "快照格式不认识（版本不符或文件损坏）"
    end

    local restored, skipped = 0, {}
    for _, id in ipairs(snap.jobOrder or {}) do
        local sj = snap.jobs[id]
        if type(sj) == "table" then
            local def, derr = jobsModule.loadSource(sj.source, "@restore-" .. tostring(id))
            if not def then
                skipped[#skipped + 1] = string.format("#%d %s（源码无法装载：%s）",
                    id, tostring(sj.name), tostring(derr))
            else
                def.hash = sj.hash or def.hash
                def.source = sj.source
                local job = {
                    id = id, name = sj.name, def = def, args = sj.args,
                    priority = sj.priority or 0, paused = sj.paused or false,
                    source = sj.source, hash = sj.hash,
                    tasks = {}, order = {}, queue = {}, qhead = 1,
                    counts = { pending = 0, running = 0, done = 0, failed = 0 },
                    state = "queued",
                    submittedAt = sj.submittedAt or util.now(),
                    restored = true,
                    phase = "map",
                    total = #(sj.order or {}),
                }
                for i, tid in ipairs(sj.order or {}) do
                    local st = sj.tasks[tid] or { state = "pending" }
                    local t = {
                        id = tid, payload = st.payload, state = "pending",
                        tries = st.tries or 0, reduce = st.reduce or nil,
                    }
                    if st.reduce then job.phase = "reduce" end
                    if st.state == "done" and st.result ~= nil then
                        t.state, t.result, t.ms = "done", st.result, st.ms
                        job.counts.done = job.counts.done + 1
                    else
                        job.counts.pending = job.counts.pending + 1
                        job.queue[#job.queue + 1] = tid
                    end
                    job.tasks[tid] = t
                    job.order[i] = tid
                end
                sched.jobs[id] = job
                sched.jobOrder[#sched.jobOrder + 1] = id
                sched.nextJobId = math.max(sched.nextJobId, id + 1)
                restored = restored + 1
            end
        end
    end
    return restored, nil, skipped
end

function M.clearSnapshot()
    if util.exists(M.SNAP) then fs.delete(M.SNAP) end
end

M.WORKERS = M.DIR .. "/workers.dat"

function M.loadWorkers()
    local raw = util.readFile(M.WORKERS)
    if not raw then return {} end
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

function M.saveWorkers(data)
    M.ensureDirs()
    return util.writeFile(M.WORKERS, textutils.serialize(data or {}))
end

function M.mergeWorkers(lifetime, workers)
    lifetime = lifetime or {}
    for id, w in pairs(workers or {}) do
        local e = lifetime[id]
        if not e then
            e = { name = w.name, done = 0, fail = 0, totalMs = 0, firstSeen = util.now() }
            lifetime[id] = e
        end
        e.name = w.name or e.name
        local dDone = (w.done or 0) - (w.countedDone or 0)
        local dFail = (w.fail or 0) - (w.countedFail or 0)
        if dDone > 0 then e.done = (e.done or 0) + dDone end
        if dFail > 0 then e.fail = (e.fail or 0) + dFail end
        w.countedDone, w.countedFail = w.done or 0, w.fail or 0
        e.lastSeen = util.now()
    end
    return lifetime
end

function M.cacheKey(source, args)
    local parts = {}
    for _, k in ipairs(util.sortedKeys(args or {})) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(args[k])
    end
    return util.hash((source or "") .. "|" .. table.concat(parts, "&"))
end

function M.cachePath(key) return M.CACHE_DIR .. "/" .. key .. ".txt" end

function M.cacheGet(key)
    if not key then return nil end
    local raw = util.readFile(M.cachePath(key))
    if not raw then return nil end
    local ok, entry = pcall(textutils.unserialize, raw)
    if not ok or type(entry) ~= "table" then return nil end
    return entry
end

function M.cachePut(key, entry)
    if not key then return false end
    M.ensureDirs()
    return util.writeFile(M.cachePath(key), textutils.serialize(entry))
end

function M.cacheList()
    local out = {}
    for _, name in ipairs(util.listDir(M.CACHE_DIR)) do
        if name:sub(-4) == ".txt" then
            local entry = M.cacheGet(name:sub(1, -5))
            out[#out + 1] = { key = name:sub(1, -5), entry = entry }
        end
    end
    table.sort(out, function(a, b) return (a.entry and a.entry.at or 0) > (b.entry and b.entry.at or 0) end)
    return out
end

function M.cacheClear()
    local n = 0
    for _, name in ipairs(util.listDir(M.CACHE_DIR)) do
        if name:sub(-4) == ".txt" then
            fs.delete(M.CACHE_DIR .. "/" .. name)
            n = n + 1
        end
    end
    return n
end

M.POOL_DIR = util.ROOT .. "/pool"
M.POOL_TTL = 900

function M.ensurePool()
    util.ensureDir(M.POOL_DIR)
end

function M.validPoolName(name)
    name = tostring(name or "")
    if #name > 60 or name:find("%.%.") or name:find("[/\\]") then return false end
    return (name:match("^task%-[%w_%-]+%.dat$") ~= nil
        or name:match("^res%-[%w_%-]+%.dat$") ~= nil)
end

function M.poolPath(name)
    return M.POOL_DIR .. "/" .. name
end

function M.poolPut(name, value)
    M.ensurePool()
    local ok, data = pcall(textutils.serialize, value)
    if not ok then return nil, "序列化失败: " .. tostring(data) end
    local wrote, err = util.writeFile(M.poolPath(name), data)
    if not wrote then return nil, err end
    return name, #data
end

function M.poolGet(name, keep)
    if not M.validPoolName(name) then return nil, "非法池子文件名" end
    local raw = util.readFile(M.poolPath(name))
    if not raw then return nil, "池子里没有 " .. tostring(name) end
    local ok, value = pcall(textutils.unserialize, raw)
    if not ok or value == nil then return nil, "池子文件解析失败: " .. tostring(name) end
    if not keep and fs.exists(M.poolPath(name)) then fs.delete(M.poolPath(name)) end
    return value
end

function M.poolList()
    local out = {}
    for _, name in ipairs(util.listDir(M.POOL_DIR)) do
        if name:sub(-4) == ".dat" then
            out[#out + 1] = { name = name, size = fs.getSize(M.poolPath(name)) or 0 }
        end
    end
    return out
end

function M.poolClean(nowMs)
    nowMs = nowMs or util.now()
    local n = 0
    for _, f in ipairs(M.poolList()) do
        local mt = fs.attributes(M.poolPath(f.name))
        local mtime = (type(mt) == "table" and mt.modified) or 0
        if mtime > 0 and (nowMs / 1000 - mtime) > M.POOL_TTL then
            fs.delete(M.poolPath(f.name))
            n = n + 1
        end
    end
    return n
end

function M.appendHistory(job)
    M.ensureDirs()
    local line = textutils.serialize({
        at = util.now(),
        id = job.id, name = job.name, state = job.state,
        done = job.counts and job.counts.done or 0,
        failed = job.counts and job.counts.failed or 0,
        ms = job.durationMs or 0,
        args = job.args,
        summary = job.resultText and util.trunc((job.resultText:gsub("\n", " ")), 120) or nil,
    })
    local h = fs.open(M.HISTORY, "a")
    if h then
        h.write(line .. "\n")
        h.close()
        return true
    end
    return false
end

function M.history(limit)
    local raw = util.readFile(M.HISTORY)
    if not raw then return {} end
    local out = {}
    for line in raw:gmatch("[^\n]+") do
        local ok, entry = pcall(textutils.unserialize, line)
        if ok and type(entry) == "table" then out[#out + 1] = entry end
    end

    local recent = {}
    for i = #out, math.max(1, #out - (limit or 10) + 1), -1 do recent[#recent + 1] = out[i] end
    return recent, #out
end

return M

end)

-- ── 入口 ────────────────────────────────────────────────────────────
if not _G.dc_require then
    local cache = {}
    local self = (arg and arg[0]) or (shell and shell.getRunningProgram and shell.getRunningProgram())
    local dir = self and self:match("^(.*)/[^/]*$") or nil
    local paths = {}
    if dir then paths[#paths + 1] = dir .. "/lib/%s.lua" end
    paths[#paths + 1] = "lib/%s.lua"
    paths[#paths + 1] = "src/lib/%s.lua"
    paths[#paths + 1] = "/dccomp/lib/%s.lua"

    _G.dc_require = function(name)
        if cache[name] then return cache[name] end
        local short = tostring(name):match("^dc%.(.+)$")
        if not short then error("模块名非法: " .. tostring(name), 0) end
        local tried = {}
        for _, pat in ipairs(paths) do
            local path = pat:format(short)
            tried[#tried + 1] = path
            if fs.exists(path) and not fs.isDir(path) then
                local fn, err = loadfile(path)
                if not fn then error("加载模块 " .. name .. " 失败: " .. tostring(err), 0) end
                local mod = fn()
                cache[name] = mod
                return mod
            end
        end
        error("找不到模块 " .. name .. "（已尝试: " .. table.concat(tried, ", ") .. "）", 0)
    end
end

local worker = dc_require("dc.worker")

local argv = { ... }

if type(argv[1]) == "table" then argv = argv[1] end

local opts = {}
for k, v in pairs(rawget(_G, "DCNET_CFG") or {}) do opts[k] = v end
for _, a in ipairs(argv) do
    local s = tostring(a)
    if s == "--headless" or s == "--daemon" or s == "headless" then
        opts.headless = true
    elseif tonumber(s) and not opts.master then
        opts.master = tonumber(s)
    elseif s:sub(1, 1) ~= "-" and not opts.name then
        opts.name = s
    else
        local k, v = s:match("^%-%-([%w_]+)=(.*)$")
        if k then
            local n = tonumber(v)
            opts[k] = n or v
        end
    end
end

local ok = worker.run(opts)
if not ok then
    printError("[dcnet] 节点启动失败。")
    return 1
end
return 0
