--[[- ==========================================================================
  dcnet 一键安装器 v1.1.0（由 tools/build.py 生成，请勿直接编辑）

  把这一个文件拷到任何一台电脑上，就能装好 dcnet：

      install.lua                      装全部（主控 + 节点 + 拉取器 + 作业）
      install.lua master               只装主控
      install.lua worker               只装节点
      install.lua jobs                 只装作业
      install.lua all --startup=master 顺便生成开机自启（跑主控）
      install.lua all --startup=worker 顺便生成开机自启（跑节点）
      install.lua all --force          覆盖已存在的文件

  默认不覆盖已有文件，所以重复运行是安全的（作业改过也不会被冲掉）。
========================================================================== ]]

local FILES = {
    ["/dccomp/master.lua"] = [==[
--[[- ==========================================================================
  dcnet v1.1.0 — CC:Tweaked 分布式计算网络（主控 master）

  本文件由 tools/build.py 自动生成，请勿直接编辑。
  要改逻辑请改 src/ 下的源码，然后重新运行：
      python tools/build.py

  模块：dc.util, dc.protocol, dc.net, dc.console, dc.xfer, dc.jobs, dc.sched, dc.master, dc.cloud, dc.crypto, dc.panel, dc.state
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

M.VERSION    = "1.1.0"
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
M.BULK_FIELDS = { ["d"] = "dck", ["src"] = "sck" }

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

__dc_define("dc.sched", function()
local util  = dc_require("dc.util")
local proto = dc_require("dc.protocol")
local jobs  = dc_require("dc.jobs")
local net   = dc_require("dc.net")
local state = dc_require("dc.state")
local xfer  = dc_require("dc.xfer")

local M = {}

local Sched = {}
M.Sched = Sched

local C = util.colours or {}

local function colour(name, fallback)
    return (C and C[name]) or fallback
end

function Sched:log(text, colour)
    if self.logFn then self.logFn(text, colour) end
end

local STATE_TEXT = {
    queued = "排队", running = "执行中", done = "完成",
    failed = "失败", cancelled = "取消",
}

M.DEFAULTS = {
    workerTimeout   = 12,
    taskTimeout     = 90,
    taskTimeoutMin  = 15,
    taskTimeoutMax  = 900,
    adaptiveTimeout = true,
    maxTries        = 3,
    pollInterval    = 1.5,
    maxParallel     = 1,
    redundancy      = 0,
    verbose         = false,
    snapshot        = true,
    snapshotInterval = 15,
    autoResume      = true,
    cache           = true,
    cloud           = true,
    cloudFirst      = true,
    cloudChunk      = 65536,
    twoLevelReduce  = true,
    reduceThreshold = 300,
    reduceGroupSize = 100,
    standby         = false,
    beatInterval    = 3,
    takeoverAfter   = 15,
    reHelloAfter    = 8,
    rediscoverAfter = 25,
    monitor         = "",
    monitorScale    = 0.5,
    fileChannel     = true,
    inlineLimit     = 8192,
}

M.CFG_META = {
    workerTimeout   = "节点失联判定（秒）",
    taskTimeout     = "任务初始超时（秒）",
    taskTimeoutMin  = "自适应超时下限（秒）",
    taskTimeoutMax  = "自适应超时上限（秒）",
    adaptiveTimeout = "按历史耗时自适应超时",
    maxTries        = "单任务最多派发次数",
    pollInterval    = "节点空闲轮询间隔（秒）",
    maxParallel     = "同时执行的作业数",
    redundancy      = "抢尾冗余派发阈值（0=关）",
    verbose         = "打印每次任务派发",
    snapshot        = "把未完成作业写快照（断点续算）",
    snapshotInterval = "兜底快照间隔（秒）",
    autoResume      = "启动时自动接上未完成作业",
    cache           = "使用结果缓存",
    cloud           = "启用云端卸载（HTTP 计算服务）",
    cloudFirst      = "优先用云端（关闭=本机空闲时不用云端）",
    cloudChunk      = "云端请求超过多少字节就分块上传",
    twoLevelReduce  = "结果多时并行 reduce（两级汇总）",
    reduceThreshold = "超过多少条结果启用两级汇总",
    reduceGroupSize = "每个 reduce 任务处理多少条结果",
    standby         = "本机作为待命主控启动",
    beatInterval    = "在岗主控心跳间隔（秒）",
    takeoverAfter   = "收不到心跳多久后接管（秒）",
    reHelloAfter    = "节点重发 hello 的静默阈值（秒）",
    rediscoverAfter = "节点重新搜索主控的静默阈值（秒）",
    monitor         = "大屏显示器名（空=自动找）",
    monitorScale    = "大屏字号缩放",
    fileChannel     = "大负载走文件通道",
    inlineLimit     = "超过多少字节改走文件通道",
}

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Sched })
    self.cfg = {}
    for k, v in pairs(M.DEFAULTS) do self.cfg[k] = v end
    for k, v in pairs(opts.cfg or {}) do self.cfg[k] = v end

    self.logFn      = opts.log or function() end
    self.onFinished = opts.onFinished

    self.workers   = {}
    self.jobs      = {}
    self.jobOrder  = {}
    self.running   = {}
    self.paused    = false
    self.nextJobId = 1
    self.stats     = { done = 0, failed = 0, retries = 0, redundant = 0 }
    self.dirty     = false
    self.lastSnap  = 0
    self.lifetime  = state.loadWorkers()
    return self
end

function Sched:saveSnapshot()
    if not self.cfg.snapshot then return false, "快照已关闭" end
    local ok, err = state.snapshot(self)
    if ok then
        self.dirty, self.lastSnap = false, util.mono()
    end

    self.lifetime = state.mergeWorkers(self.lifetime, self.workers)
    state.saveWorkers(self.lifetime)
    return ok, err
end

function Sched:topLines(limit)
    local rows = {}
    for id, e in pairs(self.lifetime or {}) do
        rows[#rows + 1] = { id = id, name = e.name, done = e.done or 0, fail = e.fail or 0,
            totalMs = e.totalMs or 0, lastSeen = e.lastSeen }
    end

    local seen = {}
    for _, r in ipairs(rows) do seen[r.id] = r end
    for id, w in pairs(self.workers) do
        local r = seen[id]
        if not r then
            r = { id = id, name = w.name, done = 0, fail = 0, totalMs = 0 }
            rows[#rows + 1] = r
            seen[id] = r
        end
        r.done = r.done + ((w.done or 0) - (w.countedDone or 0))
        r.fail = r.fail + ((w.fail or 0) - (w.countedFail or 0))
    end
    table.sort(rows, function(a, b)
        if a.done ~= b.done then return a.done > b.done end
        return a.id < b.id
    end)

    local out = { string.format("%-7s %-12s %8s %8s %10s", "节点", "名称", "累计完成", "累计失败", "最近在线") }
    for i = 1, math.min(#rows, limit or 10) do
        local r = rows[i]
        out[#out + 1] = string.format("%-7s %-12s %8d %8d %10s", "#" .. r.id,
            util.trunc(r.name or "-", 12), r.done, r.fail,
            r.lastSeen and util.duration(util.now() - r.lastSeen) .. "前" or "-")
    end
    if #rows == 0 then out[#out + 1] = "（还没有节点贡献记录）" end
    return out
end

function Sched:restore()
    local n, err, skipped = state.restore(self, jobs)
    for _, s in ipairs(skipped or {}) do
        self:log("  无法恢复 " .. s, colour("red", 16384))
    end
    if n > 0 then self:pump() end
    return n, err
end

function Sched:setCfg(key, value)
    if self.cfg[key] == nil then return nil, "未知配置项: " .. tostring(key) end
    local old = self.cfg[key]
    if type(old) == "number" then
        local n = tonumber(value)
        if not n then return nil, "需要数字" end
        self.cfg[key] = n
    elseif type(old) == "boolean" then
        if value == true or value == "true" or value == "on" or value == "1" then
            self.cfg[key] = true
        elseif value == false or value == "false" or value == "off" or value == "0" then
            self.cfg[key] = false
        else
            return nil, "需要 true/false"
        end
    else
        self.cfg[key] = tostring(value)
    end
    return true, old
end

function Sched:worker(id, msg)
    local w = self.workers[id]
    if not w then
        w = {
            id = id, joinedAt = util.now(), done = 0, fail = 0, totalMs = 0,
            state = "idle", lastSeen = util.now(),
        }
        self.workers[id] = w
    end
    if msg then w.lastSeen = util.now() end
    return w
end

function Sched:workerCount()
    local n = 0
    for _ in pairs(self.workers) do n = n + 1 end
    return n
end

function Sched:onlineCount()
    local n = 0
    for _, w in pairs(self.workers) do
        if w.state ~= "offline" then n = n + 1 end
    end
    return n
end

function Sched:workerList()
    local list = {}
    for _, w in pairs(self.workers) do list[#list + 1] = w end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

function Sched:workerLines()
    local out = {
        string.format("%-7s %-12s %-6s %6s %6s %9s %8s  %s",
            "节点", "名称", "状态", "完成", "失败", "累计耗时", "均速", "当前"),
    }
    for _, w in ipairs(self:workerList()) do
        local speed = "-"
        if w.done > 0 and w.totalMs > 0 then
            speed = string.format("%.1f/s", w.done / (w.totalMs / 1000))
        end
        local cur = "-"
        if w.state == "busy" and w.job and w.task then
            cur = string.format("#%d.%d %d%%", w.job, w.task, math.floor((w.progress or 0) * 100))
        elseif w.state == "offline" then
            cur = "离线 " .. util.duration(util.now() - (w.lastSeen or 0))
        end
        out[#out + 1] = string.format("%-7s %-12s %-6s %6d %6d %9s %8s  %s",
            w.virtual and "云端" or ("#" .. w.id),
            util.trunc(w.name or "-", 12),
            w.virtual and "云端" or (w.state == "busy" and "忙碌" or (w.state == "offline" and "离线" or "空闲")),
            w.done, w.fail,
            util.duration(w.totalMs), speed, cur)
    end
    if #out == 1 then out[#out + 1] = "（还没有节点连接）" end
    return out
end

function Sched:addJob(def, tokens, opts)
    local args, err = jobs.resolveArgs(def, tokens)
    if not args then return nil, err end
    local taskList, err2 = jobs.split(def, args)
    if not taskList then return nil, err2 end

    local id = self.nextJobId
    self.nextJobId = id + 1

    local job = {
        id = id, name = def.name, def = def, args = args,
        priority = (opts and tonumber(opts.priority)) or 0,
        paused = false,
        phase = "map",
        source = def.source, hash = def.hash,
        tasks = {}, order = {}, queue = {}, qhead = 1,
        counts = { pending = 0, running = 0, done = 0, failed = 0 },
        state = "queued",
        submittedAt = util.now(),
        total = #taskList,
    }
    for i, payload in ipairs(taskList) do
        job.tasks[i] = { id = i, payload = payload, state = "pending", tries = 0 }
        job.order[i] = i
        job.queue[#job.queue + 1] = i
        job.counts.pending = job.counts.pending + 1
    end

    local nocache = opts and opts.nocache
    if self.cfg.cache and not nocache then
        job.cacheKey = state.cacheKey(job.source, args)
        local hit = state.cacheGet(job.cacheKey)
        if hit and hit.text then
            job.state = "done"
            job.cached = true
            job.resultText = hit.text
            job.cacheAt = hit.at
            job.startedAt, job.finishedAt = util.mono(), util.now()
            job.durationMs = 0
            job.counts.done, job.counts.pending = job.total, 0
            self.jobs[id] = job
            self.jobOrder[#self.jobOrder + 1] = id
            self:log(string.format("作业 #%d %s 命中结果缓存（%s 前算过），直接出结果",
                id, job.name, util.duration(util.now() - (hit.at or util.now()))), colour("lime", 32))
            for _, line in ipairs(util.split(job.resultText, "\n")) do
                self:log("  " .. line, colour("white", 1))
            end
            if self.onFinished then self.onFinished(job) end
            return job
        end
    end

    self.jobs[id] = job
    self.jobOrder[#self.jobOrder + 1] = id
    self.dirty = true
    self:log(string.format("作业 #%d %s 已提交：%d 个任务  %s",
        id, job.name, job.total, jobs.paramHelp(def)), colour("lime", 32))
    if #(job.source or "") > 8000 then
        self:log(string.format("  注意：作业源码 %s 偏大，每个任务下发时会附带源码，建议拆小",
            util.bytes(#job.source)), colour("orange", 2))
    end
    self:pump()
    return job
end

function Sched:pump()
    local running = 0
    for _ in pairs(self.running) do running = running + 1 end
    local limit = math.max(1, self.cfg.maxParallel or 1)
    if running >= limit then return end
    for _, id in ipairs(self.jobOrder) do
        local job = self.jobs[id]
        if job and job.state == "queued" then
            job.state = "running"
            job.startedAt = util.mono()
            self.running[id] = true
            running = running + 1
            self:log(string.format("作业 #%d %s 开始执行（%d 个任务，优先级 %d）",
                id, job.name, job.total, job.priority or 0), colour("lightBlue", 512))
            if running >= limit then return end
        end
    end
end

function Sched:runningJobs()
    local list = {}
    for _, id in ipairs(self.jobOrder) do
        if self.running[id] then list[#list + 1] = self.jobs[id] end
    end
    table.sort(list, function(a, b)
        local pa, pb = a.priority or 0, b.priority or 0
        if pa ~= pb then return pa > pb end
        return a.id < b.id
    end)
    return list
end

function Sched:runningCount()
    local n = 0
    for _ in pairs(self.running) do n = n + 1 end
    return n
end

function Sched:hasIdleLocal()
    for _, w in pairs(self.workers) do
        if not w.virtual and w.state == "idle" then return true end
    end
    return false
end

function Sched:takeTaskForCloud(workerId, epName)
    if self.paused then return nil end
    for _, job in ipairs(self:runningJobs()) do
        local want = job.def and job.def.cloud and job.def.cloud.endpoint
        if job.state == "running" and not job.paused and job.def and job.def.cloud
            and (want == nil or want == "any" or want == epName) then
            local tid = self:nextPending(job)
            if tid then
                local t = job.tasks[tid]
                local w = self:worker(workerId)
                t.state, t.worker, t.tries = "running", workerId, t.tries + 1
                t.startedAt, t.lastProgressAt = util.mono(), util.mono()
                t.deadline = t.startedAt + self:taskBudget(job, w, t)
                job.counts.pending = math.max(0, job.counts.pending - 1)
                job.counts.running = job.counts.running + 1
                w.task, w.job, w.state = tid, job.id, "busy"
                w.taskStartedAt = util.mono()
                self.dirty = true
                return job, tid
            end
        end
    end
    return nil
end

function Sched:externalResult(workerId, jobId, tid, ok, data, err, ms)
    return self:onResult(workerId, proto.msg(proto.RESULT, {
        job = jobId, task = tid, ok = ok and true or false,
        data = data, err = err, ms = ms or 0,
    }))
end

function Sched:nextPending(job)
    while job.qhead <= #job.queue do
        local cand = job.queue[job.qhead]
        job.qhead = job.qhead + 1
        local t = cand and job.tasks[cand]
        if t and t.state == "pending" then return cand end
    end
    return nil
end

function Sched:taskBudget(job, w, t)
    local base = self.cfg.taskTimeout
    if self.cfg.adaptiveTimeout then
        local m = 0
        if job.msEWMA then m = math.max(m, job.msEWMA) end
        if w and w.msEWMA then m = math.max(m, w.msEWMA) end
        if t and t.ms then m = math.max(m, t.ms) end
        if m > 0 then base = m * 4 / 1000 + 5 end
    end

    if t and t.payloadRef and t.payloadBytes then
        base = base + xfer.estimateSeconds(t.payloadBytes)
    end
    return math.max(self.cfg.taskTimeoutMin, math.min(self.cfg.taskTimeoutMax, base))
end

function Sched:dispatch(job, tid, workerId, isDup)
    local t = job.tasks[tid]
    local w = self:worker(workerId)

    if not isDup then
        t.state, t.worker, t.tries = "running", workerId, t.tries + 1
        t.startedAt, t.lastProgressAt = util.mono(), util.mono()
        t.deadline = t.startedAt + self:taskBudget(job, w, t)
        job.counts.pending = math.max(0, job.counts.pending - 1)
        job.counts.running = job.counts.running + 1
    else
        t.dups = t.dups or {}
        t.dups[#t.dups + 1] = workerId
        self.stats.redundant = self.stats.redundant + 1
    end

    w.task, w.job, w.state = tid, job.id, "busy"
    w.taskStartedAt, w.progress, w.note = util.mono(), 0, ""
    w.dup = isDup or nil

    local useFile = false
    if self.cfg.fileChannel ~= false and t.payload ~= nil then
        local ok, encoded = pcall(textutils.serialize, t.payload)
        local size = ok and #encoded or 0
        if size > (self.cfg.inlineLimit or 8192) then
            local name = string.format("task-%d-%d.dat", job.id, tid)
            local wrote, wsize = state.poolPut(name, t.payload)
            if wrote then
                t.payloadRef = name
                t.payloadBytes = #encoded
                useFile = true
                if self.cfg.verbose then
                    self:log(string.format("  任务 %d.%d 负载 %s，改走文件通道（%s）",
                        job.id, tid, util.bytes(size), name), colour("lightGray", 1024))
                end
            end
            if not wrote then
                self:log("负载落盘失败，退回内联：" .. tostring(wsize), colour("orange", 2))
            end
        end
    end

    local msg = proto.msg(proto.TASK, {
        job = job.id, task = tid, name = job.name,
        hash = job.hash,
        payloadRef = useFile and t.payloadRef or nil,
        phase = t.reduce and "reduce" or nil,
        timeout = math.floor(t.deadline - util.mono()),
        tries = t.tries, dup = isDup or nil,
    })

    if not useFile then msg.payload = t.payload end

    if t.reduce then msg.args = job.args end
    if w.have ~= job.hash then msg.src = job.source end

    net.send(workerId, msg, util.PROTO_CTRL)
    self.dirty = true
    if self.cfg.verbose or t.tries > 1 or isDup then
        self:log(string.format("  → 任务 %d.%d 派发给 #%d（第 %d 次%s）",
            job.id, tid, workerId, t.tries, isDup and "，冗余" or ""), colour("yellow", 256))
    end
    return msg
end

function Sched:assign(workerId)
    if self.paused then return nil end
    for _, job in ipairs(self:runningJobs()) do
        if job.state == "running" and not job.paused then
            local tid = self:nextPending(job)
            if tid then return self:dispatch(job, tid, workerId, false) end
        end
    end
    return nil
end

function Sched:assignRedundant(workerId)
    local tail = self.cfg.redundancy or 0
    if self.paused or tail <= 0 then return false end
    for _, job in ipairs(self:runningJobs()) do
        if job.state == "running" and not job.paused then
            local left = job.counts.pending + job.counts.running
            if job.counts.pending == 0 and left > 0 and left <= tail then
                for _, tid in ipairs(job.order) do
                    local t = job.tasks[tid]
                    if t.state == "running" and t.worker ~= workerId then
                        local dup = false
                        for _, id in ipairs(t.dups or {}) do
                            if id == workerId then dup = true end
                        end
                        if not dup then
                            self:dispatch(job, tid, workerId, true)
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

function Sched:requeue(jobId, tid, why)
    local job = self.jobs[jobId]
    if not job then return end
    local t = job.tasks[tid]
    if not t or t.state == "done" or t.state == "failed" then return end

    local oldWorker = t.worker

    if t.state == "running" then
        job.counts.running = math.max(0, job.counts.running - 1)
    elseif t.state == "pending" then
        job.counts.pending = math.max(0, job.counts.pending - 1)
    end

    if oldWorker then
        local w = self.workers[oldWorker]
        if w and w.task == tid then
            w.task, w.job = nil, nil
            w.state = (w.state == "offline") and "offline" or "idle"
        end
    end

    for _, id in ipairs(t.dups or {}) do
        local dw = self.workers[id]
        if dw and dw.task == tid then
            dw.task, dw.job, dw.dup = nil, nil, nil
            dw.state = (dw.state == "offline") and "offline" or "idle"
        end
    end
    t.dups = nil

    if t.tries >= self.cfg.maxTries then
        t.state, t.err = "failed", why
        job.counts.failed = job.counts.failed + 1
        self.stats.failed = self.stats.failed + 1
        local w = oldWorker and self.workers[oldWorker]
        if w then w.fail = w.fail + 1 end
        self:log(string.format("  x 任务 %d.%d 失败：%s（已派发 %d 次）",
            jobId, tid, why, t.tries), colour("red", 16384))
    else
        t.state, t.worker = "pending", nil
        job.queue[#job.queue + 1] = tid
        job.counts.pending = job.counts.pending + 1
        self.stats.retries = self.stats.retries + 1
        self:log(string.format("  ~ 任务 %d.%d 重新入队：%s", jobId, tid, why),
            colour("orange", 2))
    end
    self.dirty = true
    self:checkDone(job)
end

function Sched:checkDone(job)
    if job.state ~= "running" then return end
    if job.counts.pending > 0 or job.counts.running > 0 then return end

    if self:maybeTwoLevel(job) then return end
    self:finalize(job)
end

function Sched:collectResults(job)
    local out = {}
    for _, tid in ipairs(job.order) do
        local t = job.tasks[tid]
        if t and t.state == "done" and t.result ~= nil then out[#out + 1] = t.result end
    end
    return out
end

function Sched:maybeTwoLevel(job)
    if job.phase ~= "map" then return false end
    if not self.cfg.twoLevelReduce then return false end
    if job.def.twoLevel == false then return false end
    if type(job.def.reduce) ~= "function" then return false end

    local results = self:collectResults(job)
    local threshold = self.cfg.reduceThreshold or 300
    if #results < threshold then return false end

    local groupSize = math.max(2, self.cfg.reduceGroupSize or 100)
    local groups = {}
    for i = 1, #results, groupSize do
        local g = {}
        for j = i, math.min(i + groupSize - 1, #results) do g[#g + 1] = results[j] end
        groups[#groups + 1] = g
    end

    job.phase = "reduce"
    job.mapDone = #results
    job.tasks, job.order, job.queue, job.qhead = {}, {}, {}, 1
    job.total = #groups
    job.counts = { pending = #groups, running = 0, done = 0, failed = 0 }
    for i, g in ipairs(groups) do
        job.tasks[i] = { id = i, reduce = true, payload = { __reduce = g }, state = "pending", tries = 0 }
        job.order[i] = i
        job.queue[i] = i
    end
    self:log(string.format("作业 #%d 进入两级汇总：%d 条结果分成 %d 组并行 reduce",
        job.id, #results, #groups), colour("lightBlue", 512))
    self.dirty = true
    return true
end

function Sched:finalize(job)
    job.finishedAt = util.now()
    job.durationMs = math.floor((util.mono() - (job.startedAt or util.mono())) * 1000)
    self.running[job.id] = nil

    if job.counts.done == 0 then
        job.state = "failed"
        job.error = "所有任务都失败了"
    else
        local results = {}
        for _, tid in ipairs(job.order) do
            local t = job.tasks[tid]
            if t.state == "done" and t.result ~= nil then results[#results + 1] = t.result end
        end
        local res, err = jobs.reduce(job.def, results, job.args)
        if err then
            job.state, job.error = "failed", err
        else
            job.state = "done"
            job.result = res
            job.resultText = jobs.format(job.def, res, job.args)
            if job.cacheKey then
                state.cachePut(job.cacheKey, {
                    text = job.resultText, at = util.now(),
                    job = job.name, args = job.args,
                })
            end
        end
    end

    self:log(string.format("作业 #%d %s 结束：成功 %d / 失败 %d，用时 %s",
        job.id, job.name, job.counts.done, job.counts.failed, util.duration(job.durationMs)),
        job.state == "done" and colour("lime", 32) or colour("red", 16384))
    if job.state == "done" and job.resultText then
        for _, line in ipairs(util.split(job.resultText, "\n")) do
            self:log("  " .. line, colour("white", 1))
        end
    elseif job.error then
        self:log("  " .. job.error, colour("red", 16384))
    end

    for _, w in pairs(self.workers) do
        if w.job == job.id then w.job, w.task, w.state = nil, nil, "idle" end
    end

    if self.onFinished then self.onFinished(job) end
    state.appendHistory(job)
    self.dirty = true
    self:pump()
end

function Sched:cancel(jobId)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    if job.state ~= "queued" and job.state ~= "running" then
        return nil, "作业已经结束"
    end
    job.state = "cancelled"
    job.finishedAt = util.now()
    self.running[jobId] = nil

    for _, t in pairs(job.tasks) do
        if t.state == "running" and t.worker then
            net.send(t.worker, proto.msg(proto.CANCEL, { job = jobId, task = t.id }), util.PROTO_CTRL)
            local w = self.workers[t.worker]
            if w then w.task, w.job, w.state = nil, nil, "idle" end
        end
        if t.state ~= "done" then
            t.state, t.err = "failed", "已取消"
        end
    end
    job.counts = { pending = 0, running = 0, done = 0, failed = #job.order }
    self:log(string.format("作业 #%d %s 已取消", jobId, job.name), colour("orange", 2))
    self:pump()
    return true
end

function Sched:onMessage(sender, msg)
    if not proto.valid(msg) then return false end

    if msg.t == proto.WHO then
        net.send(sender, proto.msg(proto.IAM, {
            master = os.getComputerID(), version = util.VERSION,
        }), util.PROTO_CTRL)
        return true
    end

    local w = self:worker(sender, msg)

    if msg.t == proto.HELLO then
        local vok, verr = proto.compatible(msg)
        if not vok then
            self:log(string.format("节点 #%d 协议版本不兼容：%s", sender, tostring(verr)),
                colour("red", 16384))
            self:log("  请把该节点升级到与主控同一版本（主控执行 push，或重新拷贝 worker.lua）",
                colour("red", 16384))
            return true
        end
        local known = w.name ~= nil
        w.name     = msg.name or w.name or ("#" .. sender)
        w.wireless = msg.wireless
        w.have     = msg.have
        if w.state == "offline" then w.state = "idle" end
        self:log(string.format("节点 #%d 已%s：%s（%s）", sender,
            known and "重新连接" or "连接", w.name,
            w.wireless and "无线" or "有线"), colour("lime", 32))
        net.send(sender, proto.msg(proto.WELCOME, {
            master = os.getComputerID(),
            cfg = {
                pollInterval = self.cfg.pollInterval,
                taskTimeout  = self.cfg.taskTimeout,
                fileChannel  = self.cfg.fileChannel,
                inlineLimit  = self.cfg.inlineLimit,
                reHelloAfter = self.cfg.reHelloAfter,
                rediscoverAfter = self.cfg.rediscoverAfter,
            },
        }), util.PROTO_CTRL)
        return true
    end

    if msg.t == proto.PULL then
        if msg.have then w.have = msg.have end
        if w.state == "offline" then w.state = "idle" end
        if w.task then return true end
        if not (self:assign(sender) or self:assignRedundant(sender)) then
            net.send(sender, proto.msg(proto.IDLE, { wait = self.cfg.pollInterval }), util.PROTO_CTRL)
        end
        return true
    end

    if msg.t == proto.PROGRESS then
        local job = self.jobs[msg.job]
        local t = job and job.tasks[msg.task]
        if t and t.state == "running" and t.worker == sender then
            t.lastProgressAt = util.mono()
            t.deadline = t.lastProgressAt + self:taskBudget(job, w, t)
            w.progress = tonumber(msg.pct) or w.progress
            w.note = msg.note
        end
        return true
    end

    if msg.t == proto.RESULT then
        return self:onResult(sender, msg)
    end

    if msg.t == proto.BYE then
        w.state, w.task, w.job = "offline", nil, nil
        self:log(string.format("节点 #%d 主动下线：%s", sender, tostring(msg.reason or "无")),
            colour("orange", 2))
        return true
    end

    return msg.t == proto.PONG
end

function Sched:onResult(sender, msg)
    local w = self:worker(sender, msg)
    local job = self.jobs[msg.job]
    if not job then return true end
    local t = job.tasks[msg.task]
    if not t then return true end

    if msg.ok and msg.data == nil and msg.dataRef then
        local value, derr = state.poolGet(msg.dataRef)
        if value == nil then
            msg.ok, msg.err = false, "结果文件读取失败: " .. tostring(derr)
        else
            msg.data = value
        end
    end
    if t.state == "done" or t.state == "failed" then

        if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end
        return true
    end

    if t.worker ~= sender and t.state == "running" and not msg.ok then
        if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end
        for i, id in ipairs(t.dups or {}) do
            if id == sender then table.remove(t.dups, i) break end
        end
        return true
    end

    if t.state == "running" then
        job.counts.running = math.max(0, job.counts.running - 1)
    elseif t.state == "pending" then

        local removed = 0
        for i = job.qhead, #job.queue do
            if job.queue[i] == t.id then
                job.queue[i] = false
                removed = removed + 1
            end
        end
        if removed > 0 then
            job.counts.pending = math.max(0, job.counts.pending - removed)
        end
    end

    local ms = tonumber(msg.ms) or 0
    w.totalMs = w.totalMs + ms
    if ms > 0 then w.msEWMA = w.msEWMA and (w.msEWMA * 0.7 + ms * 0.3) or ms end
    if w.task == t.id then w.task, w.job, w.dup, w.state = nil, nil, nil, "idle" end

    local owner = self.workers[t.worker]
    if owner and owner.task == t.id then
        owner.task, owner.job, owner.dup, owner.state = nil, nil, nil, "idle"
    end
    for _, id in ipairs(t.dups or {}) do
        local dw = self.workers[id]
        if dw and dw.task == t.id then
            dw.task, dw.job, dw.dup, dw.state = nil, nil, nil, "idle"
        end
    end
    t.dups = nil

    if msg.ok then
        t.state, t.result, t.ms = "done", msg.data, ms
        job.counts.done = job.counts.done + 1
        if ms > 0 then job.msEWMA = job.msEWMA and (job.msEWMA * 0.7 + ms * 0.3) or ms end
        w.done = w.done + 1
        self.stats.done = self.stats.done + 1
        if self.cfg.verbose or job.total <= 40 then
            self:log(string.format("  <- 任务 %d.%d 完成于 #%d（%s）",
                job.id, t.id, sender, util.duration(ms)), colour("lightGray", 1024))
        end
    else
        local why = "节点报错: " .. tostring(msg.err or "未知")
        if t.tries >= self.cfg.maxTries then
            t.state, t.err = "failed", why
            job.counts.failed = job.counts.failed + 1
            self.stats.failed = self.stats.failed + 1
            w.fail = w.fail + 1
            self:log(string.format("  x 任务 %d.%d 失败：%s", job.id, t.id, why), colour("red", 16384))
        else
            t.state, t.worker = "pending", nil
            job.queue[#job.queue + 1] = t.id
            job.counts.pending = job.counts.pending + 1
            self.stats.retries = self.stats.retries + 1
            self:log(string.format("  ~ 任务 %d.%d 重试：%s", job.id, t.id, why), colour("orange", 2))
        end
    end

    self:checkDone(job)
    self.dirty = true
    return true
end

function Sched:tick()
    local nowMs, mono = util.now(), util.mono()

    for id, w in pairs(self.workers) do
        if not w.virtual and w.state ~= "offline"
            and (nowMs - (w.lastSeen or 0)) > self.cfg.workerTimeout * 1000 then
            w.state = "offline"
            self:log(string.format("节点 #%d 失去联系（>%ds）", id, self.cfg.workerTimeout),
                colour("red", 16384))
            if w.task and w.job then
                local job = self.jobs[w.job]
                local t = job and job.tasks[w.task]
                if t and t.state == "running" and t.worker == id then
                    self:requeue(w.job, w.task, "节点离线")
                elseif t and t.dups then

                    for i, wid in ipairs(t.dups) do
                        if wid == id then table.remove(t.dups, i) break end
                    end
                end
            end
            w.task, w.job, w.dup = nil, nil, nil
        end
    end

    for _, job in pairs(self.jobs) do
        if job.state == "running" then
            for tid, t in pairs(job.tasks) do
                if t.state == "running" and t.deadline and mono > t.deadline then
                    self:requeue(job.id, tid, string.format("超过 %.0fs 无进展",
                        t.deadline - (t.lastProgressAt or t.startedAt or mono)))
                end
            end
        end
    end

    self:pump()

    if self.cfg.snapshot then
        local now = util.mono()
        local gap = now - (self.lastSnap or 0)
        if (self.dirty and gap >= 3) or gap >= (self.cfg.snapshotInterval or 15) then
            local ok, err = self:saveSnapshot()
            if not ok and not self.snapWarned then
                self.snapWarned = true
                self:log("快照写入失败：" .. tostring(err), colour("red", 16384))
            end
        end
    end
end

function Sched:setPriority(jobId, pri)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    job.priority = tonumber(pri) or 0
    self:log(string.format("作业 #%d 优先级改为 %d", jobId, job.priority), colour("yellow", 256))
    return true
end

function Sched:pauseJob(jobId, on)
    local job = self.jobs[jobId]
    if not job then return nil, "没有这个作业" end
    job.paused = on and true or false
    self:log(string.format("作业 #%d %s", jobId, job.paused and "已暂停派发" or "已恢复派发"),
        colour("orange", 2))
    return true
end

function Sched:activeJob()
    local list = self:runningJobs()
    return list[1]
end

function Sched:progress(job)
    if not job or job.total == 0 then return 0 end
    return (job.counts.done + job.counts.failed) / job.total
end

function Sched:statusLine()
    local running = self:runningCount()
    local parts = {
        string.format("主控 #%d", os.getComputerID()),
        string.format("节点 %d/%d", self:onlineCount(), self:workerCount()),
    }
    local queued = 0
    for _, j in pairs(self.jobs) do
        if j.state == "queued" then queued = queued + 1 end
    end

    local job = self:activeJob()
    if job then
        local pct = self:progress(job)
        parts[#parts + 1] = string.format("#%d %s %s %d%% %d/%d%s", job.id, job.name,
            util.bar(pct, 8), math.floor(pct * 100),
            job.counts.done + job.counts.failed, job.total,
            job.counts.failed > 0 and (" 失败" .. job.counts.failed) or "")
    end
    if running > 1 then
        parts[#parts + 1] = string.format("并发 %d/%d", running, math.max(1, self.cfg.maxParallel or 1))
    end
    if queued > 0 then
        parts[#parts + 1] = "队列 " .. queued
    elseif running == 0 then
        parts[#parts + 1] = "空闲"
    end
    if self.cfg.redundancy and self.cfg.redundancy > 0 then
        parts[#parts + 1] = "抢尾 " .. self.cfg.redundancy
    end
    if self.paused then parts[#parts + 1] = "已暂停" end
    return table.concat(parts, " | ")
end

function Sched:jobLines(jobId)
    local out = {}
    local list = {}
    if jobId then
        list[1] = self.jobs[jobId]
    else
        for _, id in ipairs(self.jobOrder) do list[#list + 1] = self.jobs[id] end
    end
    for _, job in ipairs(list) do
        if job then
            local pct = self:progress(job)
            local elapsed = job.durationMs or (util.now() - job.submittedAt)
            out[#out + 1] = string.format("#%-3d %-12s %-6s pri%-3d %s %3d%%  任务 %d/%d 失败 %d  用时 %s%s",
                job.id, job.name, STATE_TEXT[job.state] or job.state,
                job.priority or 0, util.bar(pct, 12), math.floor(pct * 100),
                job.counts.done + job.counts.failed, job.total, job.counts.failed,
                util.duration(elapsed), job.paused and "  [已暂停]" or "")
        end
    end
    if #out == 0 then out[1] = "（还没有作业）" end
    return out
end

function Sched:failedTaskLines(jobId, limit)
    local job = self.jobs[jobId]
    if not job then return {} end
    local out = {}
    for _, tid in ipairs(job.order) do
        local t = job.tasks[tid]
        if t.state == "failed" then
            out[#out + 1] = string.format("  任务 %d 失败：%s", tid, tostring(t.err))
            if #out >= (limit or 5) then break end
        end
    end
    return out
end

return M

end)

__dc_define("dc.master", function()
local util    = dc_require("dc.util")
local proto   = dc_require("dc.protocol")
local net     = dc_require("dc.net")
local jobs    = dc_require("dc.jobs")
local xfer    = dc_require("dc.xfer")
local sched   = dc_require("dc.sched")
local console = dc_require("dc.console")
local state   = dc_require("dc.state")
local cloud   = dc_require("dc.cloud")
local panel   = dc_require("dc.panel")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local COMMANDS = {
    "help", "status", "workers", "jobs", "run", "run!", "queue", "result",
    "cancel", "pause", "resume", "pri", "limit", "redun", "set", "cfg", "net",
    "state", "cache", "history", "top", "cloud", "mon", "repo", "pull", "pullall",
    "setkey", "key", "standby",
    "push", "kick", "halt", "reboot", "save", "clear", "quit",
}

function M.run(opts)
    opts = opts or {}

    local modems, failedModems = net.openAll()
    if #modems == 0 then
        printError("[dcnet] 没有检测到调制解调器（modem）")
        print("[dcnet] 有线网络接法：电脑旁放有线调制解调器，调制解调器上接网络线缆，")
        print("[dcnet] 所有机器串到同一段线缆上即可；要多网段就给主控挂多个 modem。")
        return false
    end

    util.ensureDir(util.JOB_DIR)
    util.ensureDir(util.OUT_DIR)
    util.ensureDir(util.CONTROL_DIR)
    local created = jobs.installDefaults(opts.defaultJobs)

    local ui
    if opts.headless then
        ui = console.null({ title = "dcnet master", logFile = util.ROOT .. "/logs/master.log" })
    else
        ui = console.new({ title = "dcnet master" })
    end
    ui:setStatus("主控启动中…")
    ui:log(string.format("dcnet 主控 v%s   本机 ID #%d", util.VERSION, os.getComputerID()),
        col("lime", 32))
    ui:log(string.format("网络：已打开 %s（%s）", net.describe(modems),
        (function()
            local t = {}
            for _, md in ipairs(modems) do t[#t + 1] = md.name end
            return table.concat(t, ",")
        end)()))

    local savedKey = rawget(_G, "DCNET_KEY") or settings.get("dcnet.key")
    if savedKey and savedKey ~= "" then
        local kok, kerr = net.setKey(savedKey)
        if kok then
            ui:log("消息签名已启用（密钥指纹 " .. tostring(net.fingerprint()) ..
                "），未签名/重复消息会被丢弃", col("lime", 32))
        else
            ui:log("启用消息签名失败：" .. tostring(kerr), col("orange", 2))
        end
    end
    for _, e in ipairs(failedModems or {}) do
        ui:log("  打开 modem 失败：" .. e, col("orange", 2))
    end
    if #created > 0 then
        ui:log("已释放示例作业到 " .. util.JOB_DIR .. "：" .. table.concat(created, ", "),
            col("lightBlue", 512))
    end
    local avail = jobs.list()
    ui:log(string.format("可用作业 %d 个：%s", #avail,
        table.concat((function()
            local t = {}
            for _, j in ipairs(avail) do t[#t + 1] = j.name end
            return t
        end)(), " ")))
    ui:log("输入 help 查看指令。")

    local cfg = util.loadCfg(sched.DEFAULTS, sched.CFG_META)
    for k, v in pairs(opts.cfg or {}) do cfg[k] = v end

    local S = sched.new({
        cfg = cfg,
        log = function(text, colour) ui:log(text, colour) end,
        onFinished = function(job)

            local path = string.format("%s/job-%d-%s.txt", util.OUT_DIR, job.id, job.name)
            local lines = {
                string.format("# 作业 %d  %s", job.id, job.name),
                string.format("# 参数: %s", jobs.paramHelp(job.def)),
                string.format("# 状态: %s  任务 %d 成功 / %d 失败  用时 %s",
                    job.state, job.counts.done, job.counts.failed, util.duration(job.durationMs)),
                "",
                job.resultText or tostring(job.error or ""),
            }
            local ok = util.writeFile(path, table.concat(lines, "\n") .. "\n")
            if ok then ui:log("结果已保存：" .. path, col("lightGray", 1024)) end
        end,
    })

    local M0 = {
        ui = ui, sched = S,
        reg = xfer.newRegistry(),
        quit = false,
        halted = false,

        masterId = os.getComputerID(),
        mode = "active",
        lastBeatAt = util.mono(),
        lastBeatSent = 0,
        activeMaster = nil,
        tookOver = 0,
    }

    local CL = cloud.new({
        sched = S, cfg = S.cfg,
        log = function(text, colour) ui:log(text, colour) end,
    })
    CL:registerWorkers()
    if not CL.ok then
        ui:log("云端卸载不可用：" .. tostring(CL.reason), col("orange", 2))
    elseif #CL.endpoints > 0 then
        local names = {}
        for _, ep in ipairs(CL.endpoints) do names[#names + 1] = ep.name end
        ui:log(string.format("云端端点 %d 个：%s（cloud 查看详情）", #CL.endpoints,
            table.concat(names, ",")), col("lightBlue", 512))
    end

    local PN = panel.new({
        log = function(text, colour) ui:log(text, colour) end,
        scale = tonumber(S.cfg.monitorScale) or panel.DEFAULT_SCALE,
    })
    local monCfg = tostring(S.cfg.monitor or "")
    if monCfg ~= "off" then
        local ok, which
        if monCfg ~= "" then
            ok, which = PN:attach(monCfg)
            if not ok then ui:log("挂载显示器失败：" .. tostring(which), col("orange", 2)) end
        else
            ok, which = pcall(PN.attachAuto, PN)
            if ok and which then
                ui:log("已自动挂载显示器：" .. tostring(which) .. "（mon off 可关闭）",
                    col("lightBlue", 512))
            end
        end
    end
    if PN:attached() then PN:redraw(S, CL, true) end

    local function startPush(target, path, what)
        local data, err = util.readFile(path)
        if not data then
            ui:log("推送失败：" .. tostring(err), col("red", 16384))
            return nil
        end
        local name = util.basename(path)
        local xid, eerr = xfer.enqueue(M0.reg, target, name, what or "worker", data,
            function(state, self)
                if state ~= "ok" then
                    ui:log(string.format("推送 %s 到 #%d 失败：%s",
                        self.name, self.target, tostring(self.err)), col("red", 16384))
                elseif what == "worker" then
                    ui:log(string.format("已推送 %s 给节点 #%d（%s）",
                        self.name, self.target, util.bytes(#data)), col("lime", 32))
                    ui:log("  节点仍在跑旧代码，需要 reboot #" .. self.target .. " 才会加载新版本",
                        col("lightGray", 1024))
                else
                    ui:log(string.format("已把 %s 推给 #%d（%s）",
                        self.name, self.target, util.bytes(#data)), col("lightGray", 1024))
                end
            end)
        if not xid then
            ui:log("推送失败：" .. tostring(eerr), col("red", 16384))
            return nil
        end
        ui:log(string.format("开始推送 %s → #%d（%s）",
            name, target, util.bytes(#data)), col("lightGray", 1024))
        return xid
    end

    local function cmdHelp()
        local lines = {
            "  help                    显示本帮助",
            "  status                  作业总览 + 节点列表",
            "  workers                 只看节点列表",
            "  jobs                    列出 /dccomp/jobs 下的作业",
            "  run <作业> [参数..] [pri=N]",
            "                          提交作业，例如 run primes to=2000000 pri=5",
            "  run! <作业> ...         同上但跳过结果缓存（强制重算）",
            "  queue                   查看作业队列",
            "  result [作业号]          查看某个作业的结果（缺省=最近完成的）",
            "  cancel <作业号>          取消作业",
            "  pause [作业号]           暂停派发（不带作业号=全部）",
            "  resume [作业号]          恢复派发",
            "  pri <作业号> <优先级>    调整优先级（高者先抢任务）",
            "  limit [N]               同时执行几个作业（并发上限）",
            "  redun [N]               抢尾冗余派发阈值（0=关，抑制慢节点拖尾）",
            "  set <配置项> <值>        改配置并持久化（cfg 看全部）",
            "  cfg                     显示当前生效的全部配置",
            "  net                     显示 modem / 网络情况",
            "  state [save|clear]      断点续算快照的状态 / 立即写 / 清除",
            "  cache [clear]           结果缓存列表 / 清空",
            "  history [N]             最近的作业运行历史",
            "  top [N]                 节点累计贡献排行（跨会话）",
            "  cloud                   云端端点列表与状态",
            "  cloud add <名字> <url> [并发]   注册一个 HTTP 计算服务（持久化）",
            "  cloud del <名字>        删除端点",
            "  cloud test <名字>       探活（GET 一次）",
            "  mon [名字|off]          挂载/关闭 monitor 大屏面板（持久化）",
            "  setkey <密钥>           启用消息签名（防冒充/防重放，各机器设成一样）",
            "  key                     查看签名状态、密钥指纹与丢弃统计",
            "  standby [on|off]        待命主控：在岗主控掉线时自动接管并接续作业",
            "  repo <主控ID>           查询另一台主控的作业仓库",
            "  pull <主控ID> <作业名…> 从它那里拉作业（自动补 .lua）",
            "  pullall <主控ID>        只拉本地没有的（先 repo 看清单）",
            "  push [节点ID..]          把 " .. util.WORKER_FILE .. " 推给节点（升级用）",
            "  reboot [节点ID..]        让节点重启电脑（配合 push 加载新代码）",
            "  kick <节点ID>            让某个节点退出",
            "  halt                    让所有节点退出",
            "  save <作业号> [路径]     结果另存为文件",
            "  clear                   重绘界面",
            "  quit                    关闭主控（节点会保留，重启主控后自动重连）",
        }
        for _, l in ipairs(lines) do ui:log(l) end
    end

    local function cmdJobList()
        local list = jobs.list()
        if #list == 0 then
            ui:log("（" .. util.JOB_DIR .. " 下没有作业文件）")
            return
        end
        for _, j in ipairs(list) do
            local def = j.ok and jobs.loadName(j.name) or nil
            ui:log(string.format("  %-12s %s", j.name, j.summary))
            if def and j.params and #j.params > 0 then
                local parts = {}
                for _, p in ipairs(j.params) do
                    parts[#parts + 1] = string.format("%s=%s", p.name, tostring(p.default))
                end
                ui:log(string.format("              参数：%s", table.concat(parts, "  ")))
            end
        end
    end

    local function cmdRun(toks, nocache)
        local name = toks[1]
        if not name then
            ui:log("用法：run <作业名> [参数..] [pri=N]（用 jobs 查看可用作业）", col("orange", 2))
            return
        end

        local rest, pri = {}, 0
        for i = 2, #toks do
            local v = tostring(toks[i]):match("^prio?=(%-?%d+)$")
            if v then pri = tonumber(v) or 0 else rest[#rest + 1] = toks[i] end
        end
        local def, err = jobs.loadName(name)
        if not def then
            ui:log("加载作业失败：" .. tostring(err), col("red", 16384))
            return
        end
        local job, err2 = S:addJob(def, rest, { priority = pri, nocache = nocache })
        if not job then
            ui:log("提交失败：" .. tostring(err2), col("red", 16384))
        elseif S:onlineCount() == 0 then
            ui:log("提示：当前没有节点在线，作业会排队等待节点接入。", col("orange", 2))
        end
    end

    local function lastFinishedJob()
        for i = #S.jobOrder, 1, -1 do
            local j = S.jobs[S.jobOrder[i]]
            if j and (j.state == "done" or j.state == "failed") then return j end
        end
        return nil
    end

    local function cmdResult(toks)
        local id = tonumber(toks[1])
        local job = id and S.jobs[id] or lastFinishedJob()
        if not job then
            ui:log("还没有完成的作业。", col("orange", 2))
            return
        end
        ui:log(string.format("作业 #%d %s（%s）参数：%s", job.id, job.name,
            job.state, jobs.paramHelp(job.def)), col("lightBlue", 512))
        ui:log(string.format("任务 %d 成功 / %d 失败，用时 %s",
            job.counts.done, job.counts.failed, util.duration(job.durationMs or 0)))
        for _, line in ipairs(S:failedTaskLines(job.id, 5)) do ui:log(line, col("red", 16384)) end
        if job.resultText then
            for _, line in ipairs(util.split(job.resultText, "\n")) do ui:log("  " .. line) end
        elseif job.error then
            ui:log("  " .. job.error, col("red", 16384))
        else
            ui:log("  （作业还没有结束）", col("orange", 2))
        end
    end

    local function targetWorkers(toks)
        local list = {}
        if #toks == 0 then
            for _, w in ipairs(S:workerList()) do
                if w.state ~= "offline" then list[#list + 1] = w end
            end
        else
            for _, t in ipairs(toks) do

                local id = tonumber((tostring(t):gsub("^#", "")))
                if id and S.workers[id] then list[#list + 1] = S.workers[id] end
            end
        end
        return list
    end

    local function dispatch(line)
        local toks = util.tokenize(line)
        local c = toks[1]
        if not c then return end
        table.remove(toks, 1)

        if c == "help" or c == "?" then
            cmdHelp()
        elseif c == "status" or c == "st" then
            ui:logLines(S:jobLines())
            ui:logLines(S:workerLines())
        elseif c == "workers" then
            ui:logLines(S:workerLines())
        elseif c == "jobs" then
            cmdJobList()
        elseif c == "run" or c == "run!" then
            cmdRun(toks, c == "run!")
        elseif c == "queue" or c == "q" then
            ui:logLines(S:jobLines())
        elseif c == "result" or c == "res" then
            cmdResult(toks)
        elseif c == "cancel" then
            local id = tonumber(toks[1])
            if not id then ui:log("用法：cancel <作业号>", col("orange", 2)) else
                local ok, err = S:cancel(id)
                if not ok then ui:log("取消失败：" .. tostring(err), col("red", 16384)) end
            end
        elseif c == "pause" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, true)
                if not ok then ui:log("暂停失败：" .. tostring(err), col("red", 16384)) end
            else
                S.paused = true
                ui:log("已暂停全部派发（正在执行的任务不受影响）。", col("orange", 2))
            end
        elseif c == "resume" then
            local id = tonumber(toks[1])
            if id then
                local ok, err = S:pauseJob(id, false)
                if not ok then ui:log("恢复失败：" .. tostring(err), col("red", 16384)) end
            else
                S.paused = false
                ui:log("已恢复派发。", col("lime", 32))
            end
        elseif c == "pri" then
            local id, pri = tonumber(toks[1]), tonumber(toks[2])
            if not id or not pri then ui:log("用法：pri <作业号> <优先级>", col("orange", 2))
            else
                local ok, err = S:setPriority(id, pri)
                if not ok then ui:log("设置失败：" .. tostring(err), col("red", 16384)) end
            end
        elseif c == "limit" or c == "redun" then
            local key = (c == "limit") and "maxParallel" or "redundancy"
            local v = toks[1]
            if not v then
                ui:log(string.format("%s = %s", key, tostring(S.cfg[key])), col("lightBlue", 512))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then ui:log("设置失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s（已持久化）", key, tostring(S.cfg[key])), col("lime", 32))
                    S:pump()
                end
            end
        elseif c == "set" then
            local key, v = toks[1], toks[2]
            if not key or v == nil then
                ui:log("用法：set <配置项> <值>（用 cfg 看全部配置项）", col("orange", 2))
            else
                local ok, err = S:setCfg(key, v)
                if not ok then
                    ui:log("设置失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg(key, S.cfg[key])
                    ui:log(string.format("%s = %s（已持久化，重启后仍生效）", key, tostring(S.cfg[key])),
                        col("lime", 32))
                end
            end
        elseif c == "cfg" then
            ui:logLines(util.cfgLines(S.cfg, sched.CFG_META))
        elseif c == "net" then
            ui:log(string.format("已打开 modem：%s", net.describe(modems)))
            for _, md in ipairs(modems) do
                ui:log(string.format("  %-8s %s", md.name, md.wireless and "无线" or "有线"))
            end
            ui:log(string.format("在线节点 %d / 登记 %d", S:onlineCount(), S:workerCount()))
            if net.hasKey() then
                ui:log("消息签名：已启用，密钥指纹 " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("消息签名：未启用（setkey <密钥> 可以打开）", col("orange", 2))
            end
            ui:logLines(net.statsLines())
        elseif c == "state" then
            local sub = toks[1]
            if sub == "clear" then
                state.clearSnapshot()
                ui:log("已清除快照（下次启动不再续算）。", col("lime", 32))
            elseif sub == "save" then
                local ok, err = S:saveSnapshot()
                ui:log(ok and "快照已写入。" or ("快照失败：" .. tostring(err)),
                    ok and col("lime", 32) or col("red", 16384))
            else
                local size = util.exists(state.SNAP) and fs.getSize(state.SNAP) or 0
                ui:log(string.format("快照：%s（%s）", state.SNAP,
                    size > 0 and util.bytes(size) or "无"))
                local pending = 0
                for _, j in pairs(S.jobs) do
                    if j.state == "queued" or j.state == "running" then pending = pending + 1 end
                end
                ui:log(string.format("未完成作业 %d 个；有变化时每 ≥3s 自动写一次，兜底 %ds",
                    pending, S.cfg.snapshotInterval))
                ui:log("  state save 立即写 / state clear 清除 / set snapshot false 关闭")
            end
        elseif c == "cache" then
            if toks[1] == "clear" then
                ui:log(string.format("已清除 %d 条结果缓存。", state.cacheClear()), col("lime", 32))
            else
                local list = state.cacheList()
                ui:log(string.format("结果缓存 %d 条（%s）：", #list, state.CACHE_DIR))
                for i = 1, math.min(#list, 8) do
                    local e = list[i].entry
                    ui:log(string.format("  %s  %-10s %s前", list[i].key, tostring(e and e.job or "?"),
                        util.duration(util.now() - ((e and e.at) or util.now()))))
                end
                ui:log("  cache clear 清空 / run! 跳过缓存 / set cache false 关闭")
            end
        elseif c == "repo" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            if not id then
                ui:log("用法：repo <主控ID>（列出对方有哪些作业）", col("orange", 2))
            else
                net.send(id, proto.msg(proto.REPO, {}), util.PROTO_CTRL)
                ui:log("已向 #" .. id .. " 查询作业仓库…", col("lightBlue", 512))
            end
        elseif c == "pull" or c == "pullall" then
            local id = tonumber((tostring(toks[1] or ""):gsub("^#", "")))
            local names = {}
            if c == "pullall" then
                if not id or not M0.lastRepo or M0.lastRepo.target ~= id then
                    ui:log("用法：先 repo <主控ID> 看清单，再 pullall <主控ID>", col("orange", 2))
                    id = nil
                else
                    for _, j in ipairs(M0.lastRepo.jobs) do
                        local name = tostring(j.name or "")
                        if not util.exists(util.JOB_DIR .. "/" .. name) then names[#names + 1] = name end
                    end
                    if #names == 0 then
                        ui:log("对方的作业本地都有了。", col("lime", 32))
                        id = nil
                    end
                end
            elseif id then
                for i = 2, #toks do
                    local name = tostring(toks[i])
                    if not name:match("%.lua$") then name = name .. ".lua" end
                    names[#names + 1] = name
                end
            end
            if id and #names == 0 then
                ui:log("用法：pull <主控ID> <作业名…>（自动补 .lua）", col("orange", 2))
                id = nil
            end
            for _, name in ipairs(names) do

                net.send(id, proto.msg(proto.FETCH, {
                    xid = net.newXid("job"), what = "job", name = name,
                }), util.PROTO_PUSH)
                ui:log("请求拉取作业 " .. name .. " …", col("lightBlue", 512))
            end
        elseif c == "standby" then
            local sub = tostring(toks[1] or "")
            if sub == "on" or sub == "true" then
                util.saveCfg("standby", true)
                S.cfg.standby = true
                ui:log("已设为待命主控（下次启动生效）：只盯心跳，在岗主控掉线就接管",
                    col("lime", 32))
            elseif sub == "off" or sub == "false" then
                util.saveCfg("standby", false)
                S.cfg.standby = false
                ui:log("已取消待命设置（下次启动直接当在岗主控）", col("lime", 32))
            else
                ui:log(string.format("高可用：本机 #%d 当前是 %s 模式%s",
                    M0.masterId, M0.mode == "standby" and "待命" or "在岗",
                    M0.activeMaster and ("，最近看到在岗主控 #" .. tostring(M0.activeMaster)) or ""))
                ui:log(string.format("  心跳间隔 %ss，接管阈值 %ss（set beatInterval / takeoverAfter 可调）",
                    tostring(S.cfg.beatInterval), tostring(S.cfg.takeoverAfter)))
                ui:log("  standby on|off：本机默认以待命模式启动（会持久化）")
                if M0.mode == "standby" then
                    ui:log(string.format("  已静默 %.1f 秒", util.mono() - M0.lastBeatAt))
                elseif M0.tookOver and M0.tookOver > 0 then
                    ui:log("  本机是接管上来的（原主控掉线）", col("orange", 2))
                end
            end
        elseif c == "setkey" then
            local k = toks[1]
            if not k then
                ui:log("用法：setkey <共享密钥>（至少 8 位；各机器设成同一个才会互相接受）",
                    col("orange", 2))
                ui:log("  setkey off 关闭签名；节点上用 CC 自带的 set dcnet.key <密钥>",
                    col("lightGray", 1024))
            elseif k == "off" or k == "none" then
                net.setKey(nil)
                settings.set("dcnet.key", "")
                settings.save()
                ui:log("已关闭消息签名（同网段任何人都能冒充主控/节点）", col("orange", 2))
            else
                local ok2, kerr = net.setKey(k)
                if not ok2 then
                    ui:log("设置失败：" .. tostring(kerr), col("red", 16384))
                else
                    settings.set("dcnet.key", k)
                    settings.save()
                    ui:log("已启用消息签名，密钥指纹 " .. tostring(net.fingerprint()),
                        col("lime", 32))
                    ui:log("  其它机器要用同一个密钥（主控 setkey / 节点 set dcnet.key），" ..
                        "核对指纹一致即可", col("lightGray", 1024))
                end
            end
        elseif c == "key" then
            if net.hasKey() then
                ui:log("消息签名：已启用，密钥指纹 " .. tostring(net.fingerprint()),
                    col("lime", 32))
            else
                ui:log("消息签名：未启用（同网段任何程序都能冒充主控或节点）", col("orange", 2))
                ui:log("  用 setkey <共享密钥> 打开；自己单机玩可以不开", col("lightGray", 1024))
            end
            ui:logLines(net.statsLines())
            if M0.dropped then ui:log("  本机总计丢弃 " .. M0.dropped .. " 条消息") end
        elseif c == "mon" then
            local sub = toks[1]
            if sub == "off" then
                local old = PN:detach()
                util.saveCfg("monitor", "off")
                S.cfg.monitor = "off"
                ui:log("已关闭大屏面板" .. (old and ("（" .. tostring(old) .. "）") or ""),
                    col("lime", 32))
            elseif sub then
                local ok, err = PN:attach(sub)
                if not ok then
                    ui:log("挂载失败：" .. tostring(err), col("red", 16384))
                else
                    util.saveCfg("monitor", sub)
                    S.cfg.monitor = sub
                    PN:redraw(S, CL, true)
                    ui:log("已挂载显示器 " .. tostring(PN.name) ..
                        string.format("（%dx%d）", PN.w, PN.h), col("lime", 32))
                end
            else
                if PN:attached() then
                    ui:log(string.format("大屏：%s（%dx%d，缩放 %.2f）",
                        tostring(PN.name), PN.w, PN.h, PN.scale), col("lightBlue", 512))
                else
                    ui:log("当前没有挂载显示器。")
                end
                local list = panel.findMonitors()
                if #list == 0 then
                    ui:log("  没有检测到 monitor 外设（把显示器贴到主控侧面即可）")
                else
                    for _, m in ipairs(list) do
                        ui:log("  可用显示器：" .. m.name .. "（mon " .. m.name .. " 挂载）")
                    end
                end
                ui:log("  mon <名字> 挂载 / mon off 关闭（会持久化）；cfg 里的 monitor 也能改")
            end
        elseif c == "cloud" then
            local sub = toks[1]
            if sub == "add" then
                local name, url, slots = toks[2], toks[3], toks[4]
                if not name or not url then
                    ui:log("用法：cloud add <名字> <url> [并发数]", col("orange", 2))
                else
                    local ep, err = cloud.addEndpoint(CL.endpoints, name, url, slots)
                    if not ep then
                        ui:log("添加失败：" .. tostring(err), col("red", 16384))
                    else
                        CL:registerWorkers()
                        ui:log(string.format("已注册云端端点 %s → %s（%d 并发，已持久化）",
                            ep.name, ep.url, ep.slots), col("lime", 32))
                    end
                end
            elseif sub == "del" then
                local ep, err = cloud.removeEndpoint(CL.endpoints, toks[2])
                if not ep then
                    ui:log("删除失败：" .. tostring(err), col("red", 16384))
                else
                    S.workers[ep.id] = nil
                    ui:log("已删除端点 " .. tostring(ep.name), col("lime", 32))
                end
            elseif sub == "test" then
                local name = toks[2]
                if not name then
                    ui:log("用法：cloud test <名字>", col("orange", 2))
                else
                    local sent, terr = CL:test(name, function(ok2, data, e)
                        if ok2 then
                            local info = type(data) == "table" and data.status or data
                            ui:log(string.format("端点 %s 探活成功：%s", name,
                                util.trunc(tostring(info), 60)), col("lime", 32))
                        else
                            ui:log(string.format("端点 %s 探活失败：%s", name, tostring(e)),
                                col("red", 16384))
                        end
                    end)
                    if not sent then ui:log("探活没发出去：" .. tostring(terr), col("red", 16384)) end
                end
            else
                ui:logLines(CL:lines())
            end
        elseif c == "top" then
            ui:logLines(S:topLines(tonumber(toks[1]) or 10))
        elseif c == "history" then
            local n = tonumber(toks[1]) or 10
            local list, total = state.history(n)
            ui:log(string.format("运行历史（最近 %d / 共 %d 条）：", #list, total))
            for _, e in ipairs(list) do
                ui:log(string.format("  #%-3d %-12s %-4s 成功%d 失败%d  %s  %s", e.id, tostring(e.name),
                    e.state == "done" and "完成" or "失败", e.done or 0, e.failed or 0,
                    util.duration(e.ms or 0), util.trunc(tostring(e.summary or ""), 36)))
            end
        elseif c == "push" then
            local list = targetWorkers(toks)
            if #list == 0 then ui:log("没有可推送的节点。", col("orange", 2)) else
                for _, w in ipairs(list) do startPush(w.id, util.WORKER_FILE, "worker") end
                ui:log(string.format("开始向 %d 个节点推送 %s…", #list, util.WORKER_FILE))
            end
        elseif c == "kick" then
            local id = tonumber((toks[1] or ""):gsub("^#", ""))
            if not id then ui:log("用法：kick <节点ID>", col("orange", 2))
            else
                net.send(id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
                ui:log("已通知节点 #" .. id .. " 退出。", col("orange", 2))
            end
        elseif c == "halt" then
            local list = targetWorkers(toks)
            for _, w in ipairs(list) do
                net.send(w.id, proto.msg(proto.HALT, {}), util.PROTO_CTRL)
            end
            M0.halted = true
            ui:log(string.format("已通知 %d 个节点退出。", #list), col("orange", 2))
        elseif c == "reboot" then

            local list = targetWorkers(toks)
            if #list == 0 then ui:log("没有可重启的节点。", col("orange", 2)) else
                for _, w in ipairs(list) do
                    net.send(w.id, proto.msg(proto.HALT, { reboot = true }), util.PROTO_CTRL)
                end
                ui:log(string.format("已通知 %d 个节点重启。", #list), col("orange", 2))
                ui:log("  注意：节点电脑必须有 /startup.lua 之类的开机自启，才能自动回到集群。",
                    col("lightGray", 1024))
            end
        elseif c == "save" then
            local id = tonumber(toks[1])
            local job = id and S.jobs[id] or lastFinishedJob()
            if not job or not job.resultText then
                ui:log("没有可保存的结果。", col("orange", 2))
            else
                local path = toks[2] or string.format("%s/job-%d-%s.txt", util.OUT_DIR, job.id, job.name)
                local ok = util.writeFile(path, job.resultText .. "\n")
                ui:log(ok and ("已保存：" .. path) or "保存失败", ok and col("lime", 32) or col("red", 16384))
            end
        elseif c == "clear" then
            ui:rebuild()
        elseif c == "quit" or c == "exit" then
            ui:log("主控退出。节点会继续等待，重新运行 master.lua 后会自动重连。", col("orange", 2))
            M0.quit = true
        else
            ui:log("未知指令：" .. c .. "（输入 help 查看帮助）", col("orange", 2))
        end
    end

    local function suffixes(text, candidates)
        local cur = text:match("%S*$") or ""
        local out = {}
        for _, c in ipairs(candidates) do
            if c:sub(1, #cur) == cur then out[#out + 1] = c:sub(#cur + 1) end
        end
        return out
    end

    local function complete(text)
        local toks = util.tokenize(text)
        if #toks <= 1 and not text:match("%s$") then
            return suffixes(text, COMMANDS)
        end
        if toks[1] == "run" and not text:match("%s$") and #toks == 2 then
            local names = {}
            for _, j in ipairs(jobs.list()) do names[#names + 1] = j.name end
            return suffixes(text, names)
        end
        return {}
    end

    local function netLoop()
        while not M0.quit do
            local sender, msg = net.receive(util.PROTO_CTRL, 2)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("丢弃 #%s 的消息：%s", tostring(sender), tostring(why)),
                        col("orange", 2))
                    M0.dropped = (M0.dropped or 0) + 1
                elseif msg.t == proto.BEAT then

                    M0.lastBeatAt = util.mono()
                    M0.activeMaster = tonumber(msg.id) or sender
                    if M0.mode == "active" and M0.activeMaster and M0.activeMaster < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("主控 #%d 在岗（ID 更小），本机退回待命模式",
                            M0.activeMaster), col("orange", 2))
                    end
                elseif msg.t == proto.TAKEOVER then
                    local who = tonumber(msg.id) or sender
                    M0.activeMaster = who
                    if M0.mode == "standby" then
                        ui:log(string.format("主控 #%d 已接管，本机继续待命", who),
                            col("lightGray", 1024))
                    elseif who ~= M0.masterId and who < M0.masterId then
                        M0.mode = "standby"
                        S.paused = true
                        ui:log(string.format("#%d 宣布接管（ID 更小），本机退回待命", who),
                            col("orange", 2))
                    end
                elseif M0.mode == "standby" and msg.t ~= proto.REPO then

                    ui:log(string.format("待命模式：忽略 #%s 的 %s", tostring(sender),
                        tostring(msg.t)), col("gray", 128))
                elseif msg.t == proto.REPO then

                    local list = {}
                    for _, j in ipairs(jobs.list()) do
                        local path = util.JOB_DIR .. "/" .. j.name .. ".lua"
                        list[#list + 1] = {
                            name = j.name .. ".lua",
                            size = util.exists(path) and fs.getSize(path) or 0,
                            summary = j.summary,
                        }
                    end
                    net.send(sender, proto.msg(proto.REPOINFO, { jobs = list }), util.PROTO_CTRL)
                    ui:log(string.format("#%d 查询了作业仓库，已回复 %d 个作业", sender, #list),
                        col("lightGray", 1024))

                elseif msg.t == proto.REPOINFO then
                    local list = msg.jobs or {}
                    M0.lastRepo = { target = sender, jobs = list, at = util.now() }
                    ui:log(string.format("#%d 的作业仓库（%d 个）：", sender, #list), col("lightBlue", 512))
                    for _, j in ipairs(list) do
                        local name = tostring(j.name or "?")
                        local have = util.exists(util.JOB_DIR .. "/" .. name)
                        ui:log(string.format("  %-18s %8s  %s%s", name, util.bytes(j.size or 0),
                            util.trunc(tostring(j.summary or ""), 28), have and "  [已有]" or ""))
                    end
                    ui:log("  pull <主控ID> <作业名…> 拉取 / pullall <主控ID> 只拉本地没有的")

                else
                    local ok, err = pcall(S.onMessage, S, sender, msg)
                    if not ok then
                        ui:log("处理消息出错：" .. tostring(err), col("red", 16384))
                    end
                end
            end
        end
    end

    local function pushLoop()
        local recvs = {}
        while not M0.quit do
            local sender, msg = net.receive(util.PROTO_PUSH, xfer.RECV_WAIT)
            if msg and proto.valid(msg) then
                local vok, why = net.verify(sender, msg)
                if not vok then
                    ui:log(string.format("丢弃 #%s 的传输消息：%s", tostring(sender), tostring(why)),
                        col("orange", 2))
                elseif msg.t == proto.FETCH then
                    local what = tostring(msg.what or "worker")
                    if what == "job" then

                        local name = tostring(msg.name or "")
                        local path = util.JOB_DIR .. "/" .. name
                        if not name:match("^[%w_%-_%.]+%.lua$") or name:find("%.%.") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "非法作业名" }),
                                util.PROTO_PUSH)
                            ui:log("拒绝分发非法作业名：" .. name, col("red", 16384))
                        elseif not util.exists(path) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "没有这个作业" }),
                                util.PROTO_PUSH)
                        else
                            ui:log(string.format("节点 #%d 请求拉取作业 %s…", sender, name),
                                col("lightBlue", 512))
                            startPush(sender, path, "job")
                        end

                    elseif what == "taskdata" then

                        local name = tostring(msg.name or "")
                        if not state.validPoolName(name) or not name:match("^task%-") then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "非法负载名" }),
                                util.PROTO_PUSH)
                        elseif not util.exists(state.poolPath(name)) then
                            net.send(sender, proto.msg(proto.REFERR, { xid = msg.xid, err = "负载不存在" }),
                                util.PROTO_PUSH)
                        else
                            startPush(sender, state.poolPath(name), "taskdata")
                        end

                    elseif not util.exists(util.WORKER_FILE) then
                        net.send(sender, proto.msg(proto.REFERR, {
                            xid = msg.xid, err = "主控上没有 " .. util.WORKER_FILE,
                        }), util.PROTO_PUSH)
                        ui:log("  × " .. util.WORKER_FILE .. " 不存在，无法分发", col("red", 16384))
                    else
                        ui:log(string.format("节点 #%d 请求拉取 %s…", sender, what),
                            col("lightBlue", 512))
                        startPush(sender, util.WORKER_FILE, "worker")
                    end

                elseif msg.t == proto.PUT or msg.t == proto.PUTDONE then

                    local r = recvs[msg.xid]
                    if not r and msg.t == proto.PUT then
                        r = xfer.newReceiver(msg.xid, msg.name, msg.n)
                        recvs[msg.xid] = r
                        ui:log(string.format("开始接收 #%d 的分块传输 %s（%s 块）",
                            sender, tostring(msg.name), tostring(msg.n)), col("lightGray", 1024))
                    end
                    if not r then

                    else
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
                            local dest
                            if state.validPoolName(name) then
                                dest = state.poolPath(name)
                            elseif name:match("^[%w_%-_%.]+%.lua$") and not name:find("%.%.") then
                                dest = util.JOB_DIR .. "/" .. name
                            end
                            if not dest then
                                ui:log("拒绝保存未知文件：" .. name, col("red", 16384))
                            else
                                local ok, err = util.writeFile(dest, value)
                                if ok then
                                    net.send(sender, proto.msg(proto.PUTOK, { xid = msg.xid }),
                                        util.PROTO_PUSH)
                                    if state.validPoolName(name) then
                                        ui:log(string.format("已从 #%d 收到大结果 %s（%s）",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                        os.queueEvent("dcpool", name)
                                    else
                                        ui:log(string.format("已从 #%d 拉取作业 %s（%s）",
                                            sender, name, util.bytes(#value)), col("lime", 32))
                                    end
                                else
                                    ui:log("写入失败：" .. tostring(err), col("red", 16384))
                                end
                            end
                        end
                    end

                elseif msg.t == proto.REFERR then
                    ui:log(string.format("#%d 拒绝了拉取请求：%s", sender, tostring(msg.err)),
                        col("orange", 2))

                else

                    local s = M0.reg.senders[msg.xid]
                    if s then xfer.senderOnMsg(s, msg) end
                end
            end

            if xfer.pollRegistry(M0.reg, net.send) then xfer.notify() end
        end
    end

    local function httpLoop()
        while not M0.quit do
            local ev = table.pack(os.pullEventRaw())
            if ev[1] == "http_success" or ev[1] == "http_failure" then
                local ok, err = pcall(CL.onEvent, CL, ev)
                if not ok then ui:log("处理 HTTP 事件出错：" .. tostring(err), col("red", 16384)) end
            end
        end
    end

    local function broadcastBeat()
        M0.lastBeatSent = util.mono()
        local jobs = 0
        for _, j in pairs(S.jobs) do
            if j.state == "running" or j.state == "queued" then jobs = jobs + 1 end
        end
        net.broadcast(proto.msg(proto.BEAT, {
            id = M0.masterId, jobs = jobs, workers = S:onlineCount(),
        }), util.PROTO_CTRL)
    end

    local function takeover(why)
        M0.mode = "active"
        M0.tookOver = util.now()
        S.paused = false
        ui:log(string.format("★ 接管主控（%s）：本机 #%d 现在在岗", why, M0.masterId),
            col("lime", 32))
        net.broadcast(proto.msg(proto.TAKEOVER, { id = M0.masterId }), util.PROTO_CTRL)

        local restored, err, skipped = state.restore(S, jobs)
        if restored and restored > 0 then
            ui:log(string.format("已接续 %d 个作业（完成的任务结果直接沿用）", restored),
                col("lightBlue", 512))
        elseif err then
            ui:log("接续作业失败：" .. tostring(err), col("orange", 2))
        elseif skipped then
            ui:log(string.format("有 %d 个作业无法接续（缺少作业文件）", skipped),
                col("orange", 2))
        else
            ui:log("没有需要接续的作业。", col("lightGray", 1024))
        end
        broadcastBeat()
    end

    local function pollControl()
        local dir = util.CONTROL_DIR
        if not fs.exists(dir) then return end
        local names = fs.list(dir) or {}
        table.sort(names)
        for _, name in ipairs(names) do
            if tostring(name):match("%.cmd$") then
                local path = dir .. "/" .. name
                local f = fs.open(path, "r")
                local line = f and f.readAll() or nil
                if f then f.close() end
                pcall(fs.delete, path)
                if line then line = util.trim(line) end
                if line and line ~= "" then
                    local ok, err = pcall(dispatch, line)
                    if not ok then
                        ui:log("控制命令失败：" .. tostring(err), col("red", 16384))
                    end
                end
            end
        end
    end

    local finished = {}
    local function tickLoop()
        local lastStatus = 0
        while not M0.quit do
            pollControl()
            os.sleep(0.5)
            if M0.mode == "standby" then

                local silence = util.mono() - M0.lastBeatAt
                if silence > (S.cfg.takeoverAfter or 15) then
                    takeover(string.format("已 %.0f 秒没有主控心跳", silence))
                end
            else
                S:tick()
                if util.mono() - M0.lastBeatSent > (S.cfg.beatInterval or 3) then
                    broadcastBeat()
                end
            end
            CL:pump()
            PN:redraw(S, CL)
            state.poolClean()

            local done = xfer.pollRegistry(M0.reg, net.send)
            if done then
                xfer.notify()
                for xid, st in pairs(done) do
                    M0.reg.results[xid] = st
                end
            end
            for _, s in pairs(M0.reg.senders) do
                if not s.warned and (util.mono() - s.startedAt) > 8 then
                    s.warned = true
                    ui:log(string.format("推送 %s → #%d 迟迟没有确认（第 %d/%d 块）",
                        s.name, s.target, math.min(s.next, s.n), s.n), col("orange", 2))
                end
            end

            local now = util.now()
            if now - lastStatus > 800 then
                lastStatus = now
                ui:setStatus(S:statusLine())
            end
        end
    end

    local function uiLoop()
        while not M0.quit do
            ui:setStatus(S:statusLine())
            local line = ui:prompt("dcnet> ", complete)
            if line and util.trim(line) ~= "" then
                local ok, err = pcall(dispatch, line)
                if not ok then ui:log("指令出错：" .. tostring(err), col("red", 16384)) end
            end
        end
    end

    ui:log(string.format("配置：并发 %d，抢尾冗余 %d，任务超时 %s%s（set 改配置 / cfg 看全部）",
        S.cfg.maxParallel, S.cfg.redundancy, tostring(S.cfg.taskTimeout),
        S.cfg.adaptiveTimeout and " 秒+自适应" or " 秒"))

    if S.cfg.standby then
        M0.mode = "standby"
        S.paused = true
        ui:log(string.format("以待命主控模式启动：#%d 只盯心跳，%.0f 秒收不到就接管",
            M0.masterId, S.cfg.takeoverAfter or 15), col("lightBlue", 512))
    end

    if M0.mode == "active" and S.cfg.autoResume and state.hasSnapshot() then
        local n, err, skipped = S:restore()
        if n and n > 0 then
            ui:log(string.format("已从快照恢复 %d 个未完成作业（断点续算）", n), col("lime", 32))
        elseif err then
            ui:log("快照未恢复：" .. tostring(err), col("orange", 2))
        end
    end

    ui:setStatus(S:statusLine())
    local ok, err = pcall(parallel.waitForAny, netLoop, pushLoop, tickLoop, uiLoop, httpLoop)
    ui:close()
    if not opts.headless then
        term.clear()
        term.setCursorPos(1, 1)
    end
    if not ok then
        printError("[dcnet] 主控异常终止：" .. tostring(err))
        return false
    end
    print("[dcnet] 主控已停止。")
    return true
end

return M

end)

__dc_define("dc.cloud", function()
local util = dc_require("dc.util")

local M = {}

M.FILE    = util.ROOT .. "/cloud.dat"
M.VERSION = 1

function M.encode(value)
    if not (textutils and textutils.serializeJSON) then
        return nil, "本机没有 textutils.serializeJSON（CC 版本过旧）"
    end
    local ok, out = pcall(textutils.serializeJSON, value)
    if not ok then return nil, "JSON 编码失败: " .. tostring(out) end
    return out
end

function M.decode(text)
    if not (textutils and textutils.unserializeJSON) then
        return nil, "本机没有 textutils.unserializeJSON（CC 版本过旧）"
    end
    local ok, out = pcall(textutils.unserializeJSON, text)
    if not ok then return nil, "JSON 解码失败: " .. tostring(out) end
    return out
end

function M.httpReady()
    local ok = (type(http) == "table") and (type(http.post) == "function")
    if not ok then return false, "本机 http 不可用（服务器可能关了 http_enable）" end
    if not (textutils and textutils.serializeJSON and textutils.unserializeJSON) then
        return false, "本机缺少 JSON 支持"
    end
    return true
end

function M.load()
    local raw = util.readFile(M.FILE)
    if not raw then return {} end
    local ok, data = pcall(textutils.unserialize, raw)
    if not ok or type(data) ~= "table" then return {} end
    local list = {}
    for i, ep in ipairs(data) do
        if type(ep) == "table" and ep.url then
            ep.id = ep.id or -i
            ep.slots = tonumber(ep.slots) or 1
            list[#list + 1] = ep
        end
    end
    return list
end

function M.save(list)
    util.ensureDir(util.ROOT)
    local out = {}
    for _, ep in ipairs(list or {}) do
        out[#out + 1] = {
            id = ep.id, name = ep.name, url = ep.url, slots = ep.slots,
            sent = ep.sent, ok = ep.ok, fail = ep.fail, totalMs = ep.totalMs,
            addedAt = ep.addedAt,
        }
    end
    return util.writeFile(M.FILE, textutils.serialize(out))
end

function M.find(list, name)
    for _, ep in ipairs(list or {}) do
        if ep.name == name then return ep end
    end
    return nil
end

local function nextId(list)
    local used = {}
    for _, ep in ipairs(list) do used[ep.id] = true end
    local i = -1
    while used[i] do i = i - 1 end
    return i
end

function M.addEndpoint(list, name, url, slots, log)
    if not name or name == "" then return nil, "端点名不能为空" end
    if not url or not tostring(url):match("^https?://") then
        return nil, "URL 必须以 http:// 或 https:// 开头"
    end
    if M.find(list, name) then return nil, "端点名已存在: " .. name end
    local ep = {
        id = nextId(list), name = name, url = tostring(url),
        slots = math.max(1, math.floor(tonumber(slots) or 1)),
        addedAt = util.now(), sent = 0, ok = 0, fail = 0, totalMs = 0,
    }
    list[#list + 1] = ep
    M.save(list)
    return ep
end

function M.removeEndpoint(list, name)
    for i, ep in ipairs(list) do
        if ep.name == name then
            table.remove(list, i)
            M.save(list)
            return ep
        end
    end
    return nil, "没有这个端点: " .. tostring(name)
end

local Cloud = {}
M.Cloud = Cloud

function M.new(opts)
    local self = setmetatable({}, { __index = Cloud })
    self.sched = opts.sched
    self.cfg = opts.cfg or {}
    self.log = opts.log or function() end
    self.endpoints = M.load()
    self.inflight = {}
    self.chunks = {}
    self.tests = {}
    self.ok, self.reason = M.httpReady()
    self.sent, self.okCount, self.failCount = 0, 0, 0
    return self
end

function Cloud:enabled()
    return self.ok and (self.cfg.cloud ~= false)
end

function Cloud:find(name)
    return M.find(self.endpoints, name)
end

function Cloud:countInflight(ep)
    local n = 0
    for _, req in pairs(self.inflight) do
        if req.ep == ep then n = n + 1 end
    end
    return n
end

function Cloud:totalInflight()
    local n = 0
    for _ in pairs(self.inflight) do n = n + 1 end
    return n
end

function Cloud:buildBody(job, task)
    local jobs = dc_require("dc.jobs")
    return jobs.buildCloudRequest(job.def, task, job.args)
end

function Cloud:parseResponse(job, task, decoded)
    local jobs = dc_require("dc.jobs")
    return jobs.parseCloudResponse(job.def, decoded, task)
end

function Cloud:post(ep, bodyStr, headers, method)
    method = method or "POST"
    local hdrs = { ["Content-Type"] = "application/json" }
    for k, v in pairs(headers or {}) do hdrs[k] = v end
    local ok, handle, err
    if method == "GET" then
        ok, handle, err = pcall(http.get, ep.url, hdrs, true)
    else
        ok, handle, err = pcall(http.post, ep.url, bodyStr, hdrs, true)
    end
    if not ok then return nil, tostring(handle) end
    if not handle then return nil, tostring(err or "请求未能发出") end
    return handle
end

function Cloud:cool(ep, why)
    ep.failures = (ep.failures or 0) + 1
    local backoff = math.min(300, 10 * (2 ^ math.min(ep.failures - 1, 5)))
    ep.cooldownUntil = util.mono() + backoff
    ep.lastError = why
    self.log(string.format("云端端点 %s 不可用（%s），%d 秒内不再尝试", ep.name, tostring(why),
        backoff), 16384)
end

function Cloud:clearCool(ep)
    if ep.cooldownUntil or ep.failures then
        ep.failures, ep.cooldownUntil, ep.lastError = 0, nil, nil
    end
end

function Cloud:pump()
    if not self:enabled() then return end
    local now = util.mono()
    for _, ep in ipairs(self.endpoints) do
        while self:countInflight(ep) < (ep.slots or 1) do
            if ep.cooldownUntil and now < ep.cooldownUntil then break end

            if self.cfg.cloudFirst == false and self.sched:hasIdleLocal() then break end

            local job, tid = self.sched:takeTaskForCloud(ep.id, ep.name)
            if not job then break end
            local task = job.tasks[tid]

            local body, berr = self:buildBody(job, task)
            if not body then
                self.sched:externalResult(ep.id, job.id, tid, false, nil,
                    "云端请求打包失败: " .. tostring(berr), 0)
            else
                local bodyStr = body
                if type(body) ~= "string" then
                    local enc, eerr = M.encode(body)
                    bodyStr, berr = enc, eerr
                end
                if not bodyStr then
                    self.sched:externalResult(ep.id, job.id, tid, false, nil,
                        "云端请求编码失败: " .. tostring(berr), 0)
                elseif #bodyStr > (tonumber(self.cfg.cloudChunk) or 65536) then

                    local xid = "cl-" .. tostring(M.randomHex and M.randomHex(6) or os.clock())
                    local limit = tonumber(self.cfg.cloudChunk) or 65536
                    self.chunks[xid] = {
                        ep = ep, job = job.id, task = tid, body = bodyStr,
                        i = 0, n = math.ceil(#bodyStr / limit), limit = limit,
                    }
                    if self.cfg.verbose then
                        self.log(string.format("  云端请求 %s 超过 %d 字节，切成 %d 块上传",
                            util.bytes(#bodyStr), limit, self.chunks[xid].n), 1024)
                    end
                    self:sendNextChunk(xid)
                else
                    local handle, herr = self:post(ep, bodyStr)
                    if not handle then
                        self:cool(ep, herr)
                        self.sched:externalResult(ep.id, job.id, tid, false, nil,
                            "云端不可达: " .. tostring(herr), 0)
                    else
                        ep.sent = (ep.sent or 0) + 1
                        self.sent = self.sent + 1
                        self.inflight[handle] = {
                            ep = ep, job = job.id, task = tid, startedAt = now,
                        }
                    end
                end
            end
        end
    end
end

function Cloud:sendNextChunk(xid)
    local c = self.chunks[xid]
    if not c then return false end
    c.i = c.i + 1
    local from = (c.i - 1) * c.limit + 1
    local part = c.body:sub(from, c.i * c.limit)
    local msg = { dcnet = M.PROTO_VERSION, xid = xid, i = c.i, n = c.n, chunk = part }
    if c.i >= c.n then msg.commit = true end
    local bodyStr, eerr = M.encode(msg)
    if not bodyStr then
        self.chunks[xid] = nil
        self.sched:externalResult(c.ep.id, c.job, c.task, false, nil,
            "云端分块编码失败: " .. tostring(eerr), 0)
        return false
    end
    local handle, herr = self:post(c.ep, bodyStr)
    if not handle then
        self.chunks[xid] = nil
        self:cool(c.ep, herr)
        self.sched:externalResult(c.ep.id, c.job, c.task, false, nil,
            "云端分块上传失败: " .. tostring(herr), 0)
        return false
    end
    c.ep.sent = (c.ep.sent or 0) + 1
    self.sent = self.sent + 1
    self.inflight[handle] = {
        ep = c.ep, job = c.job, task = c.task, startedAt = util.mono(),
        chunkXid = xid, chunkIndex = c.i, chunkLast = (c.i >= c.n),
    }
    return true
end

function Cloud:onEvent(ev)
    local name, url, a, b = ev[1], ev[2], ev[3], ev[4]
    if name == "http_success" then
        local handle = a
        local test = self.tests[handle]
        local body = ""
        if handle and handle.readAll then
            local ok, data = pcall(handle.readAll)
            body = ok and tostring(data or "") or ""
            pcall(function() handle.close() end)
        end
        if test then
            self.tests[handle] = nil
            local decoded = M.decode(body)
            test(true, decoded or body)
            return
        end
        local req = self.inflight[handle]
        if not req then return end
        self.inflight[handle] = nil
        local ms = math.floor((util.mono() - req.startedAt) * 1000)
        local job = self.sched.jobs[req.job]
        local decoded, derr = M.decode(body)
        if not job then return end
        if not decoded then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                "云端响应不是合法 JSON: " .. tostring(derr), ms)
            return
        end

        if req.chunkXid then
            local c = self.chunks[req.chunkXid]
            if not c then return end
            self:clearCool(req.ep)
            if not req.chunkLast then
                if type(decoded) == "table" and decoded.ok == false then
                    self.chunks[req.chunkXid] = nil
                    req.ep.fail = (req.ep.fail or 0) + 1
                    self.failCount = self.failCount + 1
                    self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                        "云端拒绝分块: " .. tostring(decoded.err or "?"), ms)
                else
                    self:sendNextChunk(req.chunkXid)
                end
                return
            end
            self.chunks[req.chunkXid] = nil
        end
        self:clearCool(req.ep)
        req.ep.totalMs = (req.ep.totalMs or 0) + ms
        local task = job.tasks[req.task]
        if type(decoded) == "table" and decoded.ok == false then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.failCount = self.failCount + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                tostring(decoded.err or "云端返回失败"), ms)
            return
        end
        local data, perr = self:parseResponse(job, task, decoded)
        if data == nil then
            req.ep.fail = (req.ep.fail or 0) + 1
            self.failCount = self.failCount + 1
            self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
                "云端响应解析失败: " .. tostring(perr), ms)
            return
        end
        req.ep.ok = (req.ep.ok or 0) + 1
        self.okCount = self.okCount + 1
        self.sched:externalResult(req.ep.id, req.job, req.task, true, data, nil, ms)

    elseif name == "http_failure" then
        local handle = b
        local test = handle and self.tests[handle]
        if test then
            self.tests[handle] = nil
            test(false, nil, tostring(a))
            return
        end
        local req = handle and self.inflight[handle]
        if not req then return end
        self.inflight[handle] = nil
        req.ep.fail = (req.ep.fail or 0) + 1
        self.failCount = self.failCount + 1
        self:cool(req.ep, a)

        self.sched:externalResult(req.ep.id, req.job, req.task, false, nil,
            "云端请求失败: " .. tostring(a), 0)
    end
end

function Cloud:test(name, onDone)
    local ep = self:find(name)
    if not ep then return nil, "没有这个端点: " .. tostring(name) end
    if not self.ok then return nil, self.reason end
    local handle, err = self:post(ep, nil, nil, "GET")
    if not handle then
        self:cool(ep, err)
        return nil, err
    end
    self.tests[handle] = function(ok, data, e)
        if ok then self:clearCool(ep) end
        onDone(ok, data, e)
    end
    return true
end

function Cloud:lines()
    local out = {}
    if not self.ok then
        out[#out + 1] = "云端卸载不可用：" .. tostring(self.reason)
        return out
    end
    if self.cfg.cloud == false then
        out[#out + 1] = "云端卸载已关闭（set cloud true 打开）"
    end
    out[#out + 1] = string.format("端点 %d 个，在飞请求 %d，累计成功 %d / 失败 %d",
        #self.endpoints, self:totalInflight(), self.okCount, self.failCount)
    if #self.endpoints == 0 then
        out[#out + 1] = "  用 cloud add <名字> <url> [并发] 注册一个 HTTP 计算服务"
    end
    for _, ep in ipairs(self.endpoints) do
        local state = "就绪"
        if ep.cooldownUntil and util.mono() < ep.cooldownUntil then
            state = string.format("冷却中 %ds（%s）",
                math.ceil(ep.cooldownUntil - util.mono()), tostring(ep.lastError or "?"))
        end
        out[#out + 1] = string.format("  %-10s %-34s 槽位 %d 在飞 %d 成功 %d 失败 %d %s",
            ep.name, util.trunc(ep.url, 34), ep.slots or 1, self:countInflight(ep),
            ep.ok or 0, ep.fail or 0, state)
    end
    return out
end

function Cloud:registerWorkers()
    for _, ep in ipairs(self.endpoints) do
        local w = self.sched:worker(ep.id)
        w.name = "cloud:" .. ep.name
        w.virtual = true
        w.state = "idle"
        w.totalMs = ep.totalMs or 0
        w.done = ep.ok or 0
        w.fail = ep.fail or 0
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

__dc_define("dc.panel", function()
local util = dc_require("dc.util")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

M.DEFAULT_SCALE = 0.5

function M.findMonitors()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(name)
        local isMonitor = (ty == "monitor")
        if not isMonitor and type(ty) == "table" then
            for _, t in ipairs(ty) do
                if t == "monitor" then isMonitor = true end
            end
        end
        if isMonitor then
            local ok, dev = pcall(peripheral.wrap, name)
            found[#found + 1] = { name = name, periph = ok and dev or nil }
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

local Panel = {}
M.Panel = Panel

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Panel })
    self.log = opts.log or function() end
    self.scale = opts.scale or M.DEFAULT_SCALE
    self.name, self.periph = nil, nil
    self.w, self.h = 0, 0
    self.lastDraw = 0
    return self
end

function Panel:attached()
    return self.periph ~= nil
end

function Panel:attach(target)
    if type(target) == "table" then
        self.periph, self.name = target, (target.__name or "fake")
    elseif type(target) == "string" and target ~= "" then
        if peripheral.getType(target) ~= "monitor" then
            return nil, "不是显示器外设: " .. target
        end
        local ok, dev = pcall(peripheral.wrap, target)
        if not ok or not dev then return nil, "无法打开显示器: " .. target end
        self.periph, self.name = dev, target
    else
        return nil, "没有指定显示器"
    end
    pcall(function() self.periph.setTextScale(self.scale) end)
    local ok2, w, h = pcall(function() return self.periph.getSize() end)
    if ok2 and w then
        self.w, self.h = w, h
    else
        self.w, self.h = 51, 19
    end
    return true
end

function Panel:detach()
    local old = self.name
    self.periph, self.name, self.w, self.h = nil, nil, 0, 0
    return old
end

function Panel:attachAuto()
    local list = M.findMonitors()
    if #list == 0 then return nil, "没有检测到显示器" end
    local ok, err = self:attach(list[1].name)
    if not ok then return nil, err end
    return self.name
end

function Panel:refreshSize()
    if not self.periph then return end
    local ok, w, h = pcall(function() return self.periph.getSize() end)
    if ok and w then self.w, self.h = w, h end
end

function Panel:lines(sched, cloud)
    local out = {}
    local w = self.w or 51

    local function add(text, colour)
        out[#out + 1] = { text = util.trunc(text, w), colour = colour }
    end

    add(string.format("dcnet 主控 #%d   %s", os.getComputerID(), os.date("%H:%M:%S")),
        col("lime", 32))

    if w < 20 or (self.h or 19) < 4 then
        add(string.format("节点 %d/%d 作业 %d", sched:onlineCount(), sched:workerCount(),
            sched:runningCount()), col("white", 1))
        return out
    end

    local queued = 0
    for _, j in pairs(sched.jobs) do
        if j.state == "queued" then queued = queued + 1 end
    end
    add(string.format("节点 %d/%d 在线   并发 %d/%d   队列 %d%s",
        sched:onlineCount(), sched:workerCount(), sched:runningCount(),
        math.max(1, sched.cfg.maxParallel or 1), queued,
        sched.paused and "  [已暂停]" or ""), col("white", 1))

    local jobs = sched:runningJobs()
    for i = 1, math.min(#jobs, 4) do
        local job = jobs[i]
        local pct = sched:progress(job)
        add(string.format("#%d %s %s %3d%%", job.id, util.trunc(job.name, 12),
            util.bar(pct, 12), math.floor(pct * 100)),
            job.state == "running" and col("lightBlue", 512) or col("lightGray", 1024))
        add(string.format("    %d/%d 完成  失败 %d  用时 %s",
            job.counts.done + job.counts.failed, job.total, job.counts.failed,
            util.duration(util.now() - (job.submittedAt or util.now()))),
            col("lightGray", 1024))
    end

    local cells = {}
    for _, wk in ipairs(sched:workerList()) do
        local cell
        if wk.virtual then
            cell = string.format("%s:%d飞", util.trunc(wk.name or "cloud", 6),
                cloud and cloud:countInflight(wk) or 0)
        elseif wk.state == "offline" then
            cell = "#" .. wk.id .. ":离线"
        elseif wk.state == "busy" then
            cell = string.format("#%d:%d%%", wk.id, math.floor((wk.progress or 0) * 100))
        else
            cell = "#" .. wk.id .. ":闲"
        end
        cells[#cells + 1] = cell
    end
    if #cells > 0 then
        add(table.concat(cells, " "), col("yellow", 256))
    end

    if cloud and cloud.ok and #cloud.endpoints > 0 then
        add(string.format("云端 %d 端点，在飞 %d，成功 %d / 失败 %d",
            #cloud.endpoints, cloud:totalInflight(), cloud.okCount, cloud.failCount),
            col("lightGray", 1024))
    end
    add(string.format("累计任务 %d 失败 %d 重试 %d 冗余 %d",
        sched.stats.done, sched.stats.failed, sched.stats.retries, sched.stats.redundant or 0),
        col("gray", 128))

    return out
end

function Panel:redraw(sched, cloud, force)
    if not self:attached() then return false end
    local now = util.mono()
    if not force and (now - (self.lastDraw or 0)) < 0.9 then return false end
    self.lastDraw = now
    self:refreshSize()

    local ok, lines = pcall(self.lines, self, sched, cloud)
    if not ok then
        self.log("面板绘制失败：" .. tostring(lines), 16384)
        return false
    end

    local mon = self.periph
    pcall(function() mon.setBackgroundColour(col("black", 32768)) end)
    pcall(function() mon.clear() end)
    for i, line in ipairs(lines) do
        if i > (self.h or 19) then break end
        pcall(function()
            mon.setCursorPos(1, i)
            mon.setTextColour(line.colour or col("white", 1))
            mon.write(line.text)
        end)
    end
    pcall(function() mon.setCursorPos(1, 1) end)
    return true
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

_G.DC_DEFAULT_JOBS = {
    ["bigdata.lua"] = [[
return {
    name    = "bigdata",
    summary = "大负载通道：负载/结果超过阈值时自动改走文件传输",
    params  = {
        { name = "tasks", type = "number", default = 6,     help = "任务数" },
        { name = "size",  type = "number", default = 24000, help = "每个任务的负载字节数" },
        { name = "res",   type = "number", default = 12000, help = "每个任务的返回字节数" },
        { name = "seed",  type = "number", default = 12345, help = "随机种子（保证可复现）" },
    },

    split = function(a)
        local tasks = {}
        for i = 1, math.max(1, math.floor(a.tasks)) do

            local parts = {}
            local n = math.max(1, math.floor(a.size))
            local x = (math.floor(a.seed) + i * 7919) % 2147483647
            for _ = 1, math.ceil(n / 8) do
                x = (x * 16807) % 2147483647
                parts[#parts + 1] = string.format("%08x", x)
            end
            local blob = table.concat(parts):sub(1, n)
            tasks[i] = { i = i, blob = blob, res = math.max(1, math.floor(a.res)) }
        end
        return tasks
    end,

    map = function(task, ctx)

        local sum, x = 0, 0
        for idx = 1, #task.blob do
            local b = task.blob:byte(idx)
            x = (x * 31 + b) % 4294967296
            sum = sum + b
            if idx % 4096 == 0 then ctx.tick() end
        end
        local out = {}
        local y = x
        for i = 1, math.ceil(task.res / 8) do
            y = (y * 1103515245 + 12345) % 2147483648
            out[i] = string.format("%08x", y)
        end
        return {
            i = task.i, len = #task.blob, sum = sum, check = x,
            out = table.concat(out):sub(1, task.res),
        }
    end,

    reduce = function(results, a)
        local tasks, totalBytes, badLen = 0, 0, 0
        local checks = {}
        for _, r in ipairs(results) do
            tasks = tasks + 1
            totalBytes = totalBytes + (r.len or 0)
            checks[#checks + 1] = r.check or 0
            if #tostring(r.out or "") < 1 then badLen = badLen + 1 end
            if (r.len or 0) < 1 then badLen = badLen + 1 end
        end
        return { tasks = tasks, totalBytes = totalBytes, checks = checks, badLen = badLen,
            want = math.floor(a.tasks), wantSize = math.floor(a.size) }
    end,

    format = function(res)
        return string.format("大负载通道：%d/%d 个任务，负载合计 %s（每个约 %s），异常 %d",
            res.tasks, res.want, tostring(res.totalBytes) .. " 字节",
            tostring(res.wantSize) .. " 字节", res.badLen)
    end,
}

]],
    ["cloudprimes.lua"] = [[
return {
    name    = "cloudprimes",
    summary = "素数统计（有云端端点时优先卸载到云端，失败自动回落本机）",
    params  = {
        { name = "from",  type = "number", default = 2,      help = "起点（>=2）" },
        { name = "to",    type = "number", default = 200000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,  help = "每个任务的整数个数" },
        { name = "pad",   type = "number", default = 0,      help = "给云端请求塞多少字节填充（测分块上传用）" },
    },

    cloud = {
        endpoint = "any",
        build = function(task, args)
            local req = { op = "primes", from = task.lo, to = task.hi }

            local pad = tonumber(args and args.pad) or 0
            if pad > 0 then req.pad = string.rep("x", math.floor(pad)) end
            return req
        end,
        parse = function(resp, task, args)
            local d = (type(resp) == "table" and resp.data) or resp
            if type(d) ~= "table" or type(d.count) ~= "number" then
                return nil, "云端响应里没有 count 字段"
            end
            return { lo = task.lo, hi = task.hi, count = d.count, last = d.last, via = "cloud" }
        end,
    },

    split = function(a)
        local tasks = {}
        local lo = math.max(2, math.floor(a.from))
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi) }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        local function isPrime(n)
            if n < 2 then return false end
            if n % 2 == 0 then return n == 2 end
            if n % 3 == 0 then return n == 3 end
            local i = 5
            while i * i <= n do
                if n % i == 0 or n % (i + 2) == 0 then return false end
                i = i + 6
            end
            return true
        end
        local count, last = 0, nil
        local total, k = task.hi - task.lo + 1, 0
        for n = task.lo, task.hi do
            if isPrime(n) then count = count + 1 last = n end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last, via = "local" }
    end,

    reduce = function(results, a)
        local total, largest, cloud, local_ = 0, nil, 0, 0
        for _, r in ipairs(results) do
            total = total + (r.count or r.primes or 0)
            if r.last and (not largest or r.last > largest) then largest = r.last end
            if r.cloud then cloud = cloud + r.cloud end
            if r.local_ then local_ = local_ + r.local_ end
            if r.via == "cloud" then cloud = cloud + 1
            elseif r.via == "local" then local_ = local_ + 1 end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest,
            cloud = cloud, local_ = local_, tasks = cloud + local_ }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大 %s）；%d 个任务，其中云端 %d / 本机 %d",
            res.from, res.to, res.primes, tostring(res.largest),
            res.tasks, res.cloud, res.local_)
    end,
}

]],
    ["hashsearch.lua"] = [[
return {
    name    = "hashsearch",
    summary = "并行暴力搜索（演示提前终止型作业）",
    params  = {
        { name = "from",    type = "number", default = 1,       help = "起点" },
        { name = "to",      type = "number", default = 4000000, help = "终点" },
        { name = "chunk",   type = "number", default = 25000,   help = "每个任务扫描范围" },
        { name = "modulus", type = "number", default = 65536,   help = "目标整除因子" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.floor(a.from)
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        local mod = math.max(2, math.floor(a.modulus))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi), mod = mod }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)

        local function h(s)
            local x = 5381
            for i = 1, #s do
                x = (x * 33 + s:byte(i)) % 2147483647
            end
            return x
        end

        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            k = k + 1
            if h("dc" .. n) % task.mod == 0 then
                return { hit = n, scanned = k }
            end
            if k % 512 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { hit = nil, scanned = k }
    end,

    reduce = function(results, a)
        local best, scanned = nil, 0
        for _, r in ipairs(results) do
            scanned = scanned + (r.scanned or 0)
            if r.hit and (not best or r.hit < best) then best = r.hit end
        end
        return { hit = best, scanned = scanned, modulus = a.modulus }
    end,

    format = function(res)
        if res.hit then
            return string.format("最小命中 n = %d（hash(\"dc%d\") %% %d == 0），共扫描 %d 个数",
                res.hit, res.hit, res.modulus, res.scanned)
        end
        return string.format("[%d, %d] 内没有找到能被 %d 整除的哈希", 0, 0, res.modulus)
    end,
}

]],
    ["ludecomp.lua"] = [[
local function makeA(n, seed)
    local A = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        A[i] = {}
        for j = 1, n do
            A[i][j] = (next() % 2001) / 1000 - 1
        end
        A[i][i] = A[i][i] + n
    end
    return A
end

local function makeB(n, seed)
    local B = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end

    for _ = 1, n * n do next() end
    for j = 1, n do
        B[j] = {}
        for i = 1, n do B[j][i] = (next() % 2001) / 1000 - 1 end
    end
    return B
end

local function luFactor(A, n)
    for k = 1, n - 1 do
        local akk = A[k][k]
        for i = k + 1, n do
            local f = A[i][k] / akk
            A[i][k] = f
            local Ai, Ak = A[i], A[k]
            for j = k + 1, n do
                Ai[j] = Ai[j] - f * Ak[j]
            end
        end
    end
end

local function luSolve(A, n, b)
    local y = {}
    for i = 1, n do
        local s = b[i]
        for j = 1, i - 1 do s = s - A[i][j] * y[j] end
        y[i] = s
    end
    local x = {}
    for i = n, 1, -1 do
        local s = y[i]
        for j = i + 1, n do s = s - A[i][j] * x[j] end
        x[i] = s / A[i][i]
    end
    return x
end

return {
    name    = "ludecomp",
    summary = "LU 分解解线性方程组（按右端项并行；残差 max|Ax-b| 自检）",
    params  = {
        { name = "n",    type = "number", default = 24, help = "矩阵阶数" },
        { name = "cols", type = "number", default = 4,  help = "每个任务解几个右端项" },
        { name = "seed", type = "number", default = 11, help = "随机种子" },
    },

    split = function(a)
        local n = math.max(2, math.floor(a.n))
        local step = math.max(1, math.floor(a.cols))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed),
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local n = task.n
        local A = makeA(n, task.seed)
        local B = makeB(n, task.seed)
        luFactor(A, n)

        local A0 = makeA(n, task.seed)
        local maxRes, sumX, count = 0, 0, 0
        local total = task.to - task.from + 1
        for j = task.from, task.to do
            local b = B[j]
            local xv = luSolve(A, n, b)
            for i = 1, n do
                local s = 0
                for k = 1, n do s = s + A0[i][k] * xv[k] end
                local d = math.abs(s - b[i])
                if d > maxRes then maxRes = d end
                sumX = sumX + xv[i]
            end
            count = count + 1
            ctx.progress((j - task.from + 1) / total, string.format("右端项 %d/%d", j, task.to))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, maxRes = maxRes, sumX = sumX, count = count }
    end,

    reduce = function(results, a)
        local maxRes, sumX, count = 0, 0, 0
        for _, r in ipairs(results) do
            maxRes = math.max(maxRes, r.maxRes or 0)
            sumX = sumX + (r.sumX or 0)
            count = count + (r.count or 0)
        end
        return { n = math.floor(a.n), maxRes = maxRes, sumX = sumX, solved = count }
    end,

    format = function(res)
        return string.format("LU 求解：%d×%d，解了 %d 个右端项，残差 max|Ax-b| = %.3e（应≈0），Σx = %.6f",
            res.n, res.n, res.solved, res.maxRes, res.sumX)
    end,
}

]],
    ["mandelbrot.lua"] = [[
local SHADES = " .:-=+*#%@"

return {
    name    = "mandelbrot",
    summary = "并行渲染曼德博集合（演示数据块型作业）",

    twoLevel = false,
    params  = {
        { name = "width",   type = "number", default = 48,   help = "图像宽度" },
        { name = "height",  type = "number", default = 14,   help = "图像高度" },
        { name = "rows",    type = "number", default = 2,    help = "每个任务渲染的行数" },
        { name = "maxIter", type = "number", default = 32,   help = "最大迭代次数" },
        { name = "xmin",    type = "number", default = -2.1 },
        { name = "xmax",    type = "number", default = 0.7 },
        { name = "ymin",    type = "number", default = -1.1 },
        { name = "ymax",    type = "number", default = 1.1 },
    },

    split = function(a)
        local tasks = {}
        local h = math.max(1, math.floor(a.height))
        local per = math.max(1, math.floor(a.rows))
        local y = 0
        while y < h do
            tasks[#tasks + 1] = {
                y0 = y, y1 = math.min(y + per, h) - 1,
                width = math.floor(a.width), height = h,
                maxIter = math.floor(a.maxIter),
                xmin = a.xmin, xmax = a.xmax, ymin = a.ymin, ymax = a.ymax,
            }
            y = y + per
        end
        return tasks
    end,

    map = function(task, ctx)
        local w, maxIter = task.width, task.maxIter
        local lines = {}
        local total = task.y1 - task.y0 + 1
        for y = task.y0, task.y1 do
            local cy = task.ymin + (task.ymax - task.ymin) * (y / math.max(1, task.height - 1))
            local row = {}
            for x = 0, w - 1 do
                local cx = task.xmin + (task.xmax - task.xmin) * (x / math.max(1, w - 1))
                local zx, zy, i = 0, 0, 0
                while zx * zx + zy * zy <= 4 and i < maxIter do
                    zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
                    i = i + 1
                end
                local idx
                if i >= maxIter then
                    idx = #SHADES
                else
                    idx = 1 + math.floor((i / maxIter) * (#SHADES - 1))
                end
                row[#row + 1] = SHADES:sub(idx, idx)
            end
            lines[#lines + 1] = table.concat(row)
            ctx.progress((y - task.y0 + 1) / total, string.format("行 %d", y))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { y0 = task.y0, lines = lines }
    end,

    reduce = function(results)
        local byRow = {}
        local maxRow = 0
        for _, r in ipairs(results) do
            for i, line in ipairs(r.lines or {}) do
                local y = (r.y0 or 0) + i - 1
                byRow[y] = line
                if y > maxRow then maxRow = y end
            end
        end
        local out = {}
        for y = 0, maxRow do out[#out + 1] = byRow[y] or "" end
        return { art = table.concat(out, "\n"), rows = maxRow + 1 }
    end,

    format = function(res)
        return res.art
    end,
}

]],
    ["matmul.lua"] = [[
local function lcg(x)
    return (x * 1103515245 + 12345) % 2147483648
end

local function matrix(n, seed)
    local m = {}
    local x = math.floor(seed) % 2147483648
    for i = 1, n do
        m[i] = {}
        for j = 1, n do
            x = lcg(x)
            m[i][j] = (x % 2001) / 1000 - 1
        end
    end
    return m
end

return {
    name    = "matmul",
    summary = "矩阵乘法（按行分块；矩阵按种子在各节点再生，可对答案）",
    params  = {
        { name = "n",    type = "number", default = 48, help = "矩阵阶数" },
        { name = "rows", type = "number", default = 6,  help = "每个任务算几行" },
        { name = "seed", type = "number", default = 7,  help = "随机种子（决定矩阵内容）" },
    },

    split = function(a)
        local n = math.max(1, math.floor(a.n))
        local step = math.max(1, math.floor(a.rows))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed),
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local A = matrix(task.n, task.seed)
        local B = matrix(task.n, task.seed + 1)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        local total = task.to - task.from + 1
        for i = task.from, task.to do
            for j = 1, task.n do
                local acc = 0
                for k = 1, task.n do
                    acc = acc + A[i][k] * B[k][j]
                end
                sum = sum + acc
                count = count + 1
                if j == i then trace = trace + acc end
                if math.abs(acc) > maxAbs then maxAbs = math.abs(acc) end
            end
            ctx.progress((i - task.from + 1) / total, string.format("行 %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, sum = sum, trace = trace,
            maxAbs = maxAbs, count = count }
    end,

    reduce = function(results, a)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        for _, r in ipairs(results) do
            sum = sum + (r.sum or 0)
            trace = trace + (r.trace or 0)
            count = count + (r.count or 0)
            if (r.maxAbs or 0) > maxAbs then maxAbs = r.maxAbs end
        end
        return { n = math.floor(a.n), sum = sum, trace = trace, maxAbs = maxAbs, count = count }
    end,

    format = function(res)
        return string.format("%d×%d 矩阵乘积：元素和 %.6f，迹 %.6f，最大绝对值 %.4f（共 %d 个元素）",
            res.n, res.n, res.sum, res.trace, res.maxAbs, res.count)
    end,
}

]],
    ["nbody.lua"] = [[
local G = 1

local function bodies(n, seed)
    local list = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        local px = (next() % 20001) / 1000 - 10
        local py = (next() % 20001) / 1000 - 10
        local m = (next() % 1000) / 100 + 1
        list[i] = { x = px, y = py, m = m }
    end
    return list
end

return {
    name    = "nbody",
    summary = "N 体引力：按天体分块算受力（净外力应≈0，可自检）",
    params  = {
        { name = "bodies", type = "number", default = 64, help = "天体数量" },
        { name = "step",   type = "number", default = 8,  help = "每个任务算几个天体" },
        { name = "seed",   type = "number", default = 3,  help = "随机种子（决定初始分布）" },
        { name = "eps",    type = "number", default = 0.5, help = "软化长度，避免除零" },
    },

    split = function(a)
        local n = math.max(2, math.floor(a.bodies))
        local step = math.max(1, math.floor(a.step))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed), eps = a.eps,
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local list = bodies(task.n, task.seed)
        local eps2 = task.eps * task.eps
        local fx, fy, sumAbs, pairs = 0, 0, 0, 0
        local total = task.to - task.from + 1
        for i = task.from, task.to do
            local bi = list[i]
            for j = 1, task.n do
                if j ~= i then
                    local bj = list[j]
                    local dx, dy = bj.x - bi.x, bj.y - bi.y
                    local r2 = dx * dx + dy * dy + eps2
                    local r = math.sqrt(r2)
                    local fmag = G * bi.m * bj.m / r2
                    fx = fx + fmag * dx / r
                    fy = fy + fmag * dy / r
                    sumAbs = sumAbs + fmag
                    pairs = pairs + 1
                end
            end
            ctx.progress((i - task.from + 1) / total, string.format("天体 %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, fx = fx, fy = fy,
            sumAbs = sumAbs, pairs = pairs }
    end,

    reduce = function(results, a)
        local fx, fy, sumAbs, pairs, count = 0, 0, 0, 0, 0
        for _, r in ipairs(results) do
            fx = fx + (r.fx or 0)
            fy = fy + (r.fy or 0)
            sumAbs = sumAbs + (r.sumAbs or 0)
            pairs = pairs + (r.pairs or 0)
            count = count + 1
        end
        local n = math.floor(a.bodies)
        return { n = n, fx = fx, fy = fy, sumAbs = sumAbs, pairs = pairs, parts = count,
            net = math.sqrt(fx * fx + fy * fy), wantPairs = n * (n - 1) }
    end,

    format = function(res)
        return string.format(
            "N 体引力：%d 个天体，Σ|F| = %.6f，净外力 = %.3e（应≈0），两两作用 %d 次（应为 %d）",
            res.n, res.sumAbs, res.net, res.pairs, res.wantPairs)
    end,
}

]],
    ["pi.lua"] = [[
return {
    name    = "pi",
    summary = "用蒙特卡洛方法估算 π（演示随机模拟类作业）",
    params  = {
        { name = "samples", type = "number", default = 2000000, help = "总样本数" },
        { name = "chunk",   type = "number", default = 50000,   help = "每个任务的样本数" },
        { name = "seed",    type = "number", default = 12345,   help = "随机种子" },
    },

    split = function(a)
        local tasks = {}
        local step = math.max(1, math.floor(a.chunk))
        local left = math.max(0, math.floor(a.samples))
        local i = 0
        while left > 0 do
            local n = math.min(step, left)
            tasks[#tasks + 1] = { n = n, seed = math.floor(a.seed) + i * 7919 }
            left = left - n
            i = i + 1
        end
        return tasks
    end,

    map = function(task, ctx)

        local s = task.seed % 2147483647
        if s <= 0 then s = s + 2147483646 end
        local function rand()
            s = (s * 16807) % 2147483647
            return s / 2147483647
        end

        local inside = 0
        for i = 1, task.n do
            local x, y = rand(), rand()
            if x * x + y * y <= 1 then inside = inside + 1 end
            if i % 512 == 0 then
                ctx.progress(i / task.n, string.format("%d/%d", i, task.n))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { n = task.n, inside = inside }
    end,

    reduce = function(results, a)
        local n, inside = 0, 0
        for _, r in ipairs(results) do

            n = n + (r.n or r.samples or 0)
            inside = inside + (r.inside or 0)
        end
        local pi = (n > 0) and (4 * inside / n) or 0
        return { samples = n, inside = inside, pi = pi }
    end,

    format = function(res)
        return string.format("π ≈ %.6f（样本 %d，圆内 %d，相对误差 %.4f%%）",
            res.pi, res.samples, res.inside,
            res.pi > 0 and math.abs(res.pi - math.pi) / math.pi * 100 or 0)
    end,
}

]],
    ["primes.lua"] = [[
return {
    name    = "primes",
    summary = "统计 [from,to] 区间内的素数个数（可对答案的基准测试）",
    params  = {
        { name = "from",  type = "number", default = 2,       help = "起点（>=2）" },
        { name = "to",    type = "number", default = 2000000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,   help = "每个任务的整数个数" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.max(2, math.floor(a.from))
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi) }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        local function isPrime(n)
            if n < 2 then return false end
            if n % 2 == 0 then return n == 2 end
            if n % 3 == 0 then return n == 3 end
            local i = 5
            while i * i <= n do
                if n % i == 0 or n % (i + 2) == 0 then return false end
                i = i + 6
            end
            return true
        end

        local count, last = 0, nil
        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            if isPrime(n) then
                count = count + 1
                last = n
            end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last }
    end,

    reduce = function(results, a)
        local total, largest, ranges = 0, nil, 0
        for _, r in ipairs(results) do

            total = total + (r.count or r.primes or 0)
            ranges = ranges + 1
            if r.last and (not largest or r.last > largest) then largest = r.last end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest, ranges = ranges }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大素数 %s），由 %d 个任务汇总",
            res.from, res.to, res.primes, tostring(res.largest), res.ranges)
    end,
}

]],
    ["selftest.lua"] = [[
return {
    name    = "selftest",
    summary = "集群自检：已知答案 + 可选故障注入（验证调度/汇总/重派）",

    twoLevel = false,
    params  = {
        { name = "tasks", type = "number", default = 24,   help = "任务数" },
        { name = "size",  type = "number", default = 2000, help = "每任务平方和项数" },
        { name = "fail",  type = "number", default = 0,    help = "故意失败的任务数" },
    },

    split = function(a)
        local tasks = math.max(1, math.floor(a.tasks))
        local size  = math.max(1, math.floor(a.size))
        local fail  = math.max(0, math.floor(a.fail))
        local out = {}
        for i = 1, tasks do
            out[#out + 1] = { id = i, n = size, fail = i <= fail }
        end
        return out
    end,

    map = function(task, ctx)
        if task.fail then

            error("selftest 故意失败（任务 " .. tostring(task.id) .. "）")
        end

        local sum = 0
        for i = 1, task.n do
            sum = sum + i * i
            if i % 256 == 0 then
                ctx.progress(i / task.n, string.format("%d/%d", i, task.n))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { id = task.id, n = task.n, sum = sum }
    end,

    reduce = function(results, a)
        local tasks = math.max(1, math.floor(a.tasks))
        local fail  = math.max(0, math.floor(a.fail))
        local want  = tasks - fail

        local seen, bad, total = {}, {}, 0
        for _, r in ipairs(results) do
            if type(r) ~= "table" or type(r.id) ~= "number" then
                bad[#bad + 1] = "收到结构异常的结果"
            else
                if seen[r.id] then bad[#bad + 1] = "任务 " .. r.id .. " 出现重复" end
                seen[r.id] = true

                local expect = r.n * (r.n + 1) * (2 * r.n + 1) / 6
                if r.sum ~= expect then
                    bad[#bad + 1] = string.format("任务 %d 校验不符：%s ≠ %s",
                        r.id, tostring(r.sum), tostring(expect))
                end
                total = total + r.sum
            end
        end

        local missing = {}
        for i = 1, tasks do
            if i > fail and not seen[i] then missing[#missing + 1] = i end
        end

        return {
            tasks = tasks, fail = fail, want = want, got = #results,
            bad = bad, missing = missing, total = total,
        }
    end,

    format = function(res)
        local pass = (#res.bad == 0) and (#res.missing == 0) and (res.got == res.want)
        local lines = {
            string.format("任务 %d 个：预期成功 %d，实际成功 %d；预期失败 %d（与主控日志核对）",
                res.tasks, res.want, res.got, res.fail),
            string.format("平方和闭式解校验：%s", #res.bad == 0 and "全部一致" or (#res.bad .. " 个不一致")),
            string.format("任务号完整性：%s", #res.missing == 0 and "齐全且无重复"
                or ("缺少 " .. table.concat(res.missing, ","))),
            "结论：" .. (pass and "PASS —— 链路正常" or "FAIL —— 看上面的明细与主控日志"),
        }
        for i = 1, math.min(#res.bad, 4) do lines[#lines + 1] = "  " .. res.bad[i] end
        return table.concat(lines, "\n")
    end,
}

]],
    ["tsp.lua"] = [=[
local function cities(n, seed)
    local list = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        list[i] = { x = (next() % 10001) / 1000, y = (next() % 10001) / 1000 }
    end
    return list
end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

return {
    name    = "tsp",
    summary = "旅行商暴力搜索（按第二个城市切分，可对最优解）",
    params  = {
        { name = "cities", type = "number", default = 9, help = "城市数量（9 → 8! 条回路，按第二城切成 8 份）" },
        { name = "seed",   type = "number", default = 5, help = "随机种子（决定城市坐标）" },
    },

    split = function(a)
        local n = math.max(3, math.floor(a.cities))
        local tasks = {}
        for k = 2, n do
            tasks[#tasks + 1] = { n = n, seed = math.floor(a.seed), second = k }
        end
        return tasks
    end,

    map = function(task, ctx)
        local pts = cities(task.n, task.seed)
        local others = {}
        for i = 2, task.n do
            if i ~= task.second then others[#others + 1] = i end
        end

        local bestLen, bestTour = math.huge, nil
        local path, steps = {}, 0

        local function walk(depth, curLen, prev)
            if curLen >= bestLen then return end
            if depth > #others then
                local total = curLen + dist(pts[prev], pts[1])
                if total < bestLen then
                    local tour = { 1, task.second }
                    for i = 1, #others do tour[#tour + 1] = path[i] end
                    bestLen, bestTour = total, tour
                end
                return
            end
            for i = depth, #others do
                others[i], others[depth] = others[depth], others[i]
                path[depth] = others[depth]
                walk(depth + 1, curLen + dist(pts[prev], pts[path[depth]]), path[depth])
                others[i], others[depth] = others[depth], others[i]
                steps = steps + 1
                if steps % 500 == 0 then
                    ctx.tick()
                    if ctx.canceled() then return end
                end
            end
        end

        walk(1, dist(pts[1], pts[task.second]), task.second)
        return { second = task.second, len = bestLen, tour = bestTour, steps = steps }
    end,

    reduce = function(results, a)
        local bestLen, bestTour, steps, parts = math.huge, nil, 0, 0
        for _, r in ipairs(results) do
            steps = steps + (r.steps or 0)
            parts = parts + 1
            local len = r.len or r.bestLen
            if len and len < bestLen then
                bestLen = len
                bestTour = r.tour or r.bestTour
            end
        end
        return { n = math.floor(a.cities), len = bestLen, tour = bestTour,
            steps = steps, parts = parts }
    end,

    format = function(res)
        local tour = {}
        for i, c in ipairs(res.tour or {}) do tour[i] = tostring(c) end
        return string.format("TSP：%d 个城市，最短回路 %.4f，路线 %s→1（枚举 %d 次，%d 个分支任务）",
            res.n, res.len, table.concat(tour, "→"), res.steps, res.parts)
    end,
}

]=],
}

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

local util   = dc_require("dc.util")
local master = dc_require("dc.master")
local sched  = dc_require("dc.sched")

local argv = { ... }

if type(argv[1]) == "table" then argv = argv[1] end
local cfg = {}
for k, v in pairs(rawget(_G, "DCNET_CFG") or {}) do cfg[k] = v end
local headless = false
for _, a in ipairs(argv) do
    local s = tostring(a)
    if s == "-v" or s == "--verbose" then
        cfg.verbose = true
    elseif s == "--headless" or s == "headless" then
        headless = true
    elseif s == "standby" or s == "--standby" then
        cfg.standby = true
    elseif s == "active" or s == "--active" then
        cfg.standby = false
    else
        local k, v = s:match("^%-%-([%w_]+)=(.*)$")
        if k and sched.DEFAULTS[k] ~= nil then
            local dv = sched.DEFAULTS[k]
            if type(dv) == "number" then
                cfg[k] = tonumber(v) or dv
            elseif type(dv) == "boolean" then
                cfg[k] = (v == "true" or v == "1" or v == "on" or v == "yes")
            else
                cfg[k] = v
            end
        elseif k then
            print("[dcnet] 未知参数: " .. k)
        end
    end
end

local ok = master.run({
    defaultJobs = _G.DC_DEFAULT_JOBS or {},
    cfg = cfg,
    headless = headless,
})
if not ok then
    printError("[dcnet] 主控启动失败。")
    return 1
end
return 0

]==],
    ["/dccomp/worker.lua"] = [=[
--[[- ==========================================================================
  dcnet v1.1.0 — CC:Tweaked 分布式计算网络（运算节点 worker）

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

M.VERSION    = "1.1.0"
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
M.BULK_FIELDS = { ["d"] = "dck", ["src"] = "sck" }

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

]=],
    ["/dccomp/bootstrap.lua"] = [[
local PROTO_CTRL = "dccomp"
local PROTO_PUSH = "dcpush"
local DEST = "/dccomp/worker.lua"

local modemName, wireless
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
        local w = true
        local ok, dev = pcall(peripheral.wrap, n)
        if ok and dev and dev.isWireless then
            local ok2, v = pcall(dev.isWireless, dev)
            if ok2 then w = v and true or false end
        end
        if not w then
            modemName, wireless = n, false
            break
        end
        if not modemName then modemName, wireless = n, w end
    end
end
if not modemName then
    printError("没有找到调制解调器：请在有线调制解调器上接好网络线缆。")
    return
end
rednet.open(modemName)
print(string.format("[bootstrap] 使用 %s（%s），本机 ID #%d",
    modemName, wireless and "无线" or "有线", os.getComputerID()))

local target = tonumber(({...})[1])
if not target then
    for _ = 1, 5 do
        rednet.broadcast({ t = "who", ver = 1 }, PROTO_CTRL)
        local sender, msg = rednet.receive(PROTO_CTRL, 1.5)
        if type(msg) == "table" and msg.t == "iam" then
            target = tonumber(msg.master) or sender
            break
        end
    end
end
if not target then
    printError("没有找到主控：请确认主控已在同一条有线网络上运行（master.lua）。")
    return
end
print("[bootstrap] 找到主控 #" .. target)

math.randomseed(os.getComputerID() * 7919 + (os.epoch and os.epoch("utc") or 0) % 100000)
local xid = string.format("boot-%d-%d", os.getComputerID(), math.random(10000, 99999))
rednet.send(target, { t = "fetch", ver = 1, xid = xid, what = "worker" }, PROTO_PUSH)
print("[bootstrap] 正在接收 worker.lua …")

local parts, want = {}, nil
local deadline = os.clock() + 40
while os.clock() < deadline do
    local sender, msg = rednet.receive(PROTO_PUSH, 2)
    if type(msg) == "table" and msg.xid == xid then
        if msg.t == "put" then
            parts[msg.i] = msg.d
            want = tonumber(msg.n) or want
            rednet.send(sender, { t = "putack", ver = 1, xid = xid, i = msg.i }, PROTO_PUSH)

        elseif msg.t == "putdone" then
            want = tonumber(msg.n) or want
            local miss = {}
            for i = 1, (want or 0) do
                if not parts[i] then miss[#miss + 1] = i end
            end
            if #miss == 0 then
                local buf = {}
                for i = 1, want do buf[i] = parts[i] end
                local data = table.concat(buf)
                if not fs.exists("/dccomp") then fs.makeDir("/dccomp") end
                local f = fs.open(DEST, "w")
                f.write(data)
                f.close()
                rednet.send(sender, { t = "putok", ver = 1, xid = xid }, PROTO_PUSH)
                print(string.format("[bootstrap] 已写入 %s（%d 字节），启动节点…", DEST, #data))
                shell.run(DEST)
                return

            else
                print(string.format("[bootstrap] 缺 %d 块，请求重传", #miss))
                rednet.send(sender, { t = "putmiss", ver = 1, xid = xid, miss = miss }, PROTO_PUSH)
            end

        elseif msg.t == "referr" then
            printError("[bootstrap] 主控无法分发代码：" .. tostring(msg.err))
            return
        end
    end
end
printError("[bootstrap] 拉取超时。可以先用软盘把 dist/worker.lua 拷到 " .. DEST)

]],

}

local JOBS = {
    ["bigdata.lua"] = [[
return {
    name    = "bigdata",
    summary = "大负载通道：负载/结果超过阈值时自动改走文件传输",
    params  = {
        { name = "tasks", type = "number", default = 6,     help = "任务数" },
        { name = "size",  type = "number", default = 24000, help = "每个任务的负载字节数" },
        { name = "res",   type = "number", default = 12000, help = "每个任务的返回字节数" },
        { name = "seed",  type = "number", default = 12345, help = "随机种子（保证可复现）" },
    },

    split = function(a)
        local tasks = {}
        for i = 1, math.max(1, math.floor(a.tasks)) do

            local parts = {}
            local n = math.max(1, math.floor(a.size))
            local x = (math.floor(a.seed) + i * 7919) % 2147483647
            for _ = 1, math.ceil(n / 8) do
                x = (x * 16807) % 2147483647
                parts[#parts + 1] = string.format("%08x", x)
            end
            local blob = table.concat(parts):sub(1, n)
            tasks[i] = { i = i, blob = blob, res = math.max(1, math.floor(a.res)) }
        end
        return tasks
    end,

    map = function(task, ctx)

        local sum, x = 0, 0
        for idx = 1, #task.blob do
            local b = task.blob:byte(idx)
            x = (x * 31 + b) % 4294967296
            sum = sum + b
            if idx % 4096 == 0 then ctx.tick() end
        end
        local out = {}
        local y = x
        for i = 1, math.ceil(task.res / 8) do
            y = (y * 1103515245 + 12345) % 2147483648
            out[i] = string.format("%08x", y)
        end
        return {
            i = task.i, len = #task.blob, sum = sum, check = x,
            out = table.concat(out):sub(1, task.res),
        }
    end,

    reduce = function(results, a)
        local tasks, totalBytes, badLen = 0, 0, 0
        local checks = {}
        for _, r in ipairs(results) do
            tasks = tasks + 1
            totalBytes = totalBytes + (r.len or 0)
            checks[#checks + 1] = r.check or 0
            if #tostring(r.out or "") < 1 then badLen = badLen + 1 end
            if (r.len or 0) < 1 then badLen = badLen + 1 end
        end
        return { tasks = tasks, totalBytes = totalBytes, checks = checks, badLen = badLen,
            want = math.floor(a.tasks), wantSize = math.floor(a.size) }
    end,

    format = function(res)
        return string.format("大负载通道：%d/%d 个任务，负载合计 %s（每个约 %s），异常 %d",
            res.tasks, res.want, tostring(res.totalBytes) .. " 字节",
            tostring(res.wantSize) .. " 字节", res.badLen)
    end,
}

]],
    ["cloudprimes.lua"] = [[
return {
    name    = "cloudprimes",
    summary = "素数统计（有云端端点时优先卸载到云端，失败自动回落本机）",
    params  = {
        { name = "from",  type = "number", default = 2,      help = "起点（>=2）" },
        { name = "to",    type = "number", default = 200000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,  help = "每个任务的整数个数" },
        { name = "pad",   type = "number", default = 0,      help = "给云端请求塞多少字节填充（测分块上传用）" },
    },

    cloud = {
        endpoint = "any",
        build = function(task, args)
            local req = { op = "primes", from = task.lo, to = task.hi }

            local pad = tonumber(args and args.pad) or 0
            if pad > 0 then req.pad = string.rep("x", math.floor(pad)) end
            return req
        end,
        parse = function(resp, task, args)
            local d = (type(resp) == "table" and resp.data) or resp
            if type(d) ~= "table" or type(d.count) ~= "number" then
                return nil, "云端响应里没有 count 字段"
            end
            return { lo = task.lo, hi = task.hi, count = d.count, last = d.last, via = "cloud" }
        end,
    },

    split = function(a)
        local tasks = {}
        local lo = math.max(2, math.floor(a.from))
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi) }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        local function isPrime(n)
            if n < 2 then return false end
            if n % 2 == 0 then return n == 2 end
            if n % 3 == 0 then return n == 3 end
            local i = 5
            while i * i <= n do
                if n % i == 0 or n % (i + 2) == 0 then return false end
                i = i + 6
            end
            return true
        end
        local count, last = 0, nil
        local total, k = task.hi - task.lo + 1, 0
        for n = task.lo, task.hi do
            if isPrime(n) then count = count + 1 last = n end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last, via = "local" }
    end,

    reduce = function(results, a)
        local total, largest, cloud, local_ = 0, nil, 0, 0
        for _, r in ipairs(results) do
            total = total + (r.count or r.primes or 0)
            if r.last and (not largest or r.last > largest) then largest = r.last end
            if r.cloud then cloud = cloud + r.cloud end
            if r.local_ then local_ = local_ + r.local_ end
            if r.via == "cloud" then cloud = cloud + 1
            elseif r.via == "local" then local_ = local_ + 1 end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest,
            cloud = cloud, local_ = local_, tasks = cloud + local_ }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大 %s）；%d 个任务，其中云端 %d / 本机 %d",
            res.from, res.to, res.primes, tostring(res.largest),
            res.tasks, res.cloud, res.local_)
    end,
}

]],
    ["hashsearch.lua"] = [[
return {
    name    = "hashsearch",
    summary = "并行暴力搜索（演示提前终止型作业）",
    params  = {
        { name = "from",    type = "number", default = 1,       help = "起点" },
        { name = "to",      type = "number", default = 4000000, help = "终点" },
        { name = "chunk",   type = "number", default = 25000,   help = "每个任务扫描范围" },
        { name = "modulus", type = "number", default = 65536,   help = "目标整除因子" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.floor(a.from)
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        local mod = math.max(2, math.floor(a.modulus))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi), mod = mod }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)

        local function h(s)
            local x = 5381
            for i = 1, #s do
                x = (x * 33 + s:byte(i)) % 2147483647
            end
            return x
        end

        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            k = k + 1
            if h("dc" .. n) % task.mod == 0 then
                return { hit = n, scanned = k }
            end
            if k % 512 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { hit = nil, scanned = k }
    end,

    reduce = function(results, a)
        local best, scanned = nil, 0
        for _, r in ipairs(results) do
            scanned = scanned + (r.scanned or 0)
            if r.hit and (not best or r.hit < best) then best = r.hit end
        end
        return { hit = best, scanned = scanned, modulus = a.modulus }
    end,

    format = function(res)
        if res.hit then
            return string.format("最小命中 n = %d（hash(\"dc%d\") %% %d == 0），共扫描 %d 个数",
                res.hit, res.hit, res.modulus, res.scanned)
        end
        return string.format("[%d, %d] 内没有找到能被 %d 整除的哈希", 0, 0, res.modulus)
    end,
}

]],
    ["ludecomp.lua"] = [[
local function makeA(n, seed)
    local A = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        A[i] = {}
        for j = 1, n do
            A[i][j] = (next() % 2001) / 1000 - 1
        end
        A[i][i] = A[i][i] + n
    end
    return A
end

local function makeB(n, seed)
    local B = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end

    for _ = 1, n * n do next() end
    for j = 1, n do
        B[j] = {}
        for i = 1, n do B[j][i] = (next() % 2001) / 1000 - 1 end
    end
    return B
end

local function luFactor(A, n)
    for k = 1, n - 1 do
        local akk = A[k][k]
        for i = k + 1, n do
            local f = A[i][k] / akk
            A[i][k] = f
            local Ai, Ak = A[i], A[k]
            for j = k + 1, n do
                Ai[j] = Ai[j] - f * Ak[j]
            end
        end
    end
end

local function luSolve(A, n, b)
    local y = {}
    for i = 1, n do
        local s = b[i]
        for j = 1, i - 1 do s = s - A[i][j] * y[j] end
        y[i] = s
    end
    local x = {}
    for i = n, 1, -1 do
        local s = y[i]
        for j = i + 1, n do s = s - A[i][j] * x[j] end
        x[i] = s / A[i][i]
    end
    return x
end

return {
    name    = "ludecomp",
    summary = "LU 分解解线性方程组（按右端项并行；残差 max|Ax-b| 自检）",
    params  = {
        { name = "n",    type = "number", default = 24, help = "矩阵阶数" },
        { name = "cols", type = "number", default = 4,  help = "每个任务解几个右端项" },
        { name = "seed", type = "number", default = 11, help = "随机种子" },
    },

    split = function(a)
        local n = math.max(2, math.floor(a.n))
        local step = math.max(1, math.floor(a.cols))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed),
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local n = task.n
        local A = makeA(n, task.seed)
        local B = makeB(n, task.seed)
        luFactor(A, n)

        local A0 = makeA(n, task.seed)
        local maxRes, sumX, count = 0, 0, 0
        local total = task.to - task.from + 1
        for j = task.from, task.to do
            local b = B[j]
            local xv = luSolve(A, n, b)
            for i = 1, n do
                local s = 0
                for k = 1, n do s = s + A0[i][k] * xv[k] end
                local d = math.abs(s - b[i])
                if d > maxRes then maxRes = d end
                sumX = sumX + xv[i]
            end
            count = count + 1
            ctx.progress((j - task.from + 1) / total, string.format("右端项 %d/%d", j, task.to))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, maxRes = maxRes, sumX = sumX, count = count }
    end,

    reduce = function(results, a)
        local maxRes, sumX, count = 0, 0, 0
        for _, r in ipairs(results) do
            maxRes = math.max(maxRes, r.maxRes or 0)
            sumX = sumX + (r.sumX or 0)
            count = count + (r.count or 0)
        end
        return { n = math.floor(a.n), maxRes = maxRes, sumX = sumX, solved = count }
    end,

    format = function(res)
        return string.format("LU 求解：%d×%d，解了 %d 个右端项，残差 max|Ax-b| = %.3e（应≈0），Σx = %.6f",
            res.n, res.n, res.solved, res.maxRes, res.sumX)
    end,
}

]],
    ["mandelbrot.lua"] = [[
local SHADES = " .:-=+*#%@"

return {
    name    = "mandelbrot",
    summary = "并行渲染曼德博集合（演示数据块型作业）",

    twoLevel = false,
    params  = {
        { name = "width",   type = "number", default = 48,   help = "图像宽度" },
        { name = "height",  type = "number", default = 14,   help = "图像高度" },
        { name = "rows",    type = "number", default = 2,    help = "每个任务渲染的行数" },
        { name = "maxIter", type = "number", default = 32,   help = "最大迭代次数" },
        { name = "xmin",    type = "number", default = -2.1 },
        { name = "xmax",    type = "number", default = 0.7 },
        { name = "ymin",    type = "number", default = -1.1 },
        { name = "ymax",    type = "number", default = 1.1 },
    },

    split = function(a)
        local tasks = {}
        local h = math.max(1, math.floor(a.height))
        local per = math.max(1, math.floor(a.rows))
        local y = 0
        while y < h do
            tasks[#tasks + 1] = {
                y0 = y, y1 = math.min(y + per, h) - 1,
                width = math.floor(a.width), height = h,
                maxIter = math.floor(a.maxIter),
                xmin = a.xmin, xmax = a.xmax, ymin = a.ymin, ymax = a.ymax,
            }
            y = y + per
        end
        return tasks
    end,

    map = function(task, ctx)
        local w, maxIter = task.width, task.maxIter
        local lines = {}
        local total = task.y1 - task.y0 + 1
        for y = task.y0, task.y1 do
            local cy = task.ymin + (task.ymax - task.ymin) * (y / math.max(1, task.height - 1))
            local row = {}
            for x = 0, w - 1 do
                local cx = task.xmin + (task.xmax - task.xmin) * (x / math.max(1, w - 1))
                local zx, zy, i = 0, 0, 0
                while zx * zx + zy * zy <= 4 and i < maxIter do
                    zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
                    i = i + 1
                end
                local idx
                if i >= maxIter then
                    idx = #SHADES
                else
                    idx = 1 + math.floor((i / maxIter) * (#SHADES - 1))
                end
                row[#row + 1] = SHADES:sub(idx, idx)
            end
            lines[#lines + 1] = table.concat(row)
            ctx.progress((y - task.y0 + 1) / total, string.format("行 %d", y))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { y0 = task.y0, lines = lines }
    end,

    reduce = function(results)
        local byRow = {}
        local maxRow = 0
        for _, r in ipairs(results) do
            for i, line in ipairs(r.lines or {}) do
                local y = (r.y0 or 0) + i - 1
                byRow[y] = line
                if y > maxRow then maxRow = y end
            end
        end
        local out = {}
        for y = 0, maxRow do out[#out + 1] = byRow[y] or "" end
        return { art = table.concat(out, "\n"), rows = maxRow + 1 }
    end,

    format = function(res)
        return res.art
    end,
}

]],
    ["matmul.lua"] = [[
local function lcg(x)
    return (x * 1103515245 + 12345) % 2147483648
end

local function matrix(n, seed)
    local m = {}
    local x = math.floor(seed) % 2147483648
    for i = 1, n do
        m[i] = {}
        for j = 1, n do
            x = lcg(x)
            m[i][j] = (x % 2001) / 1000 - 1
        end
    end
    return m
end

return {
    name    = "matmul",
    summary = "矩阵乘法（按行分块；矩阵按种子在各节点再生，可对答案）",
    params  = {
        { name = "n",    type = "number", default = 48, help = "矩阵阶数" },
        { name = "rows", type = "number", default = 6,  help = "每个任务算几行" },
        { name = "seed", type = "number", default = 7,  help = "随机种子（决定矩阵内容）" },
    },

    split = function(a)
        local n = math.max(1, math.floor(a.n))
        local step = math.max(1, math.floor(a.rows))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed),
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local A = matrix(task.n, task.seed)
        local B = matrix(task.n, task.seed + 1)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        local total = task.to - task.from + 1
        for i = task.from, task.to do
            for j = 1, task.n do
                local acc = 0
                for k = 1, task.n do
                    acc = acc + A[i][k] * B[k][j]
                end
                sum = sum + acc
                count = count + 1
                if j == i then trace = trace + acc end
                if math.abs(acc) > maxAbs then maxAbs = math.abs(acc) end
            end
            ctx.progress((i - task.from + 1) / total, string.format("行 %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, sum = sum, trace = trace,
            maxAbs = maxAbs, count = count }
    end,

    reduce = function(results, a)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        for _, r in ipairs(results) do
            sum = sum + (r.sum or 0)
            trace = trace + (r.trace or 0)
            count = count + (r.count or 0)
            if (r.maxAbs or 0) > maxAbs then maxAbs = r.maxAbs end
        end
        return { n = math.floor(a.n), sum = sum, trace = trace, maxAbs = maxAbs, count = count }
    end,

    format = function(res)
        return string.format("%d×%d 矩阵乘积：元素和 %.6f，迹 %.6f，最大绝对值 %.4f（共 %d 个元素）",
            res.n, res.n, res.sum, res.trace, res.maxAbs, res.count)
    end,
}

]],
    ["nbody.lua"] = [[
local G = 1

local function bodies(n, seed)
    local list = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        local px = (next() % 20001) / 1000 - 10
        local py = (next() % 20001) / 1000 - 10
        local m = (next() % 1000) / 100 + 1
        list[i] = { x = px, y = py, m = m }
    end
    return list
end

return {
    name    = "nbody",
    summary = "N 体引力：按天体分块算受力（净外力应≈0，可自检）",
    params  = {
        { name = "bodies", type = "number", default = 64, help = "天体数量" },
        { name = "step",   type = "number", default = 8,  help = "每个任务算几个天体" },
        { name = "seed",   type = "number", default = 3,  help = "随机种子（决定初始分布）" },
        { name = "eps",    type = "number", default = 0.5, help = "软化长度，避免除零" },
    },

    split = function(a)
        local n = math.max(2, math.floor(a.bodies))
        local step = math.max(1, math.floor(a.step))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed), eps = a.eps,
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local list = bodies(task.n, task.seed)
        local eps2 = task.eps * task.eps
        local fx, fy, sumAbs, pairs = 0, 0, 0, 0
        local total = task.to - task.from + 1
        for i = task.from, task.to do
            local bi = list[i]
            for j = 1, task.n do
                if j ~= i then
                    local bj = list[j]
                    local dx, dy = bj.x - bi.x, bj.y - bi.y
                    local r2 = dx * dx + dy * dy + eps2
                    local r = math.sqrt(r2)
                    local fmag = G * bi.m * bj.m / r2
                    fx = fx + fmag * dx / r
                    fy = fy + fmag * dy / r
                    sumAbs = sumAbs + fmag
                    pairs = pairs + 1
                end
            end
            ctx.progress((i - task.from + 1) / total, string.format("天体 %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, fx = fx, fy = fy,
            sumAbs = sumAbs, pairs = pairs }
    end,

    reduce = function(results, a)
        local fx, fy, sumAbs, pairs, count = 0, 0, 0, 0, 0
        for _, r in ipairs(results) do
            fx = fx + (r.fx or 0)
            fy = fy + (r.fy or 0)
            sumAbs = sumAbs + (r.sumAbs or 0)
            pairs = pairs + (r.pairs or 0)
            count = count + 1
        end
        local n = math.floor(a.bodies)
        return { n = n, fx = fx, fy = fy, sumAbs = sumAbs, pairs = pairs, parts = count,
            net = math.sqrt(fx * fx + fy * fy), wantPairs = n * (n - 1) }
    end,

    format = function(res)
        return string.format(
            "N 体引力：%d 个天体，Σ|F| = %.6f，净外力 = %.3e（应≈0），两两作用 %d 次（应为 %d）",
            res.n, res.sumAbs, res.net, res.pairs, res.wantPairs)
    end,
}

]],
    ["pi.lua"] = [[
return {
    name    = "pi",
    summary = "用蒙特卡洛方法估算 π（演示随机模拟类作业）",
    params  = {
        { name = "samples", type = "number", default = 2000000, help = "总样本数" },
        { name = "chunk",   type = "number", default = 50000,   help = "每个任务的样本数" },
        { name = "seed",    type = "number", default = 12345,   help = "随机种子" },
    },

    split = function(a)
        local tasks = {}
        local step = math.max(1, math.floor(a.chunk))
        local left = math.max(0, math.floor(a.samples))
        local i = 0
        while left > 0 do
            local n = math.min(step, left)
            tasks[#tasks + 1] = { n = n, seed = math.floor(a.seed) + i * 7919 }
            left = left - n
            i = i + 1
        end
        return tasks
    end,

    map = function(task, ctx)

        local s = task.seed % 2147483647
        if s <= 0 then s = s + 2147483646 end
        local function rand()
            s = (s * 16807) % 2147483647
            return s / 2147483647
        end

        local inside = 0
        for i = 1, task.n do
            local x, y = rand(), rand()
            if x * x + y * y <= 1 then inside = inside + 1 end
            if i % 512 == 0 then
                ctx.progress(i / task.n, string.format("%d/%d", i, task.n))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { n = task.n, inside = inside }
    end,

    reduce = function(results, a)
        local n, inside = 0, 0
        for _, r in ipairs(results) do

            n = n + (r.n or r.samples or 0)
            inside = inside + (r.inside or 0)
        end
        local pi = (n > 0) and (4 * inside / n) or 0
        return { samples = n, inside = inside, pi = pi }
    end,

    format = function(res)
        return string.format("π ≈ %.6f（样本 %d，圆内 %d，相对误差 %.4f%%）",
            res.pi, res.samples, res.inside,
            res.pi > 0 and math.abs(res.pi - math.pi) / math.pi * 100 or 0)
    end,
}

]],
    ["primes.lua"] = [[
return {
    name    = "primes",
    summary = "统计 [from,to] 区间内的素数个数（可对答案的基准测试）",
    params  = {
        { name = "from",  type = "number", default = 2,       help = "起点（>=2）" },
        { name = "to",    type = "number", default = 2000000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,   help = "每个任务的整数个数" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.max(2, math.floor(a.from))
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi) }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        local function isPrime(n)
            if n < 2 then return false end
            if n % 2 == 0 then return n == 2 end
            if n % 3 == 0 then return n == 3 end
            local i = 5
            while i * i <= n do
                if n % i == 0 or n % (i + 2) == 0 then return false end
                i = i + 6
            end
            return true
        end

        local count, last = 0, nil
        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            if isPrime(n) then
                count = count + 1
                last = n
            end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last }
    end,

    reduce = function(results, a)
        local total, largest, ranges = 0, nil, 0
        for _, r in ipairs(results) do

            total = total + (r.count or r.primes or 0)
            ranges = ranges + 1
            if r.last and (not largest or r.last > largest) then largest = r.last end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest, ranges = ranges }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大素数 %s），由 %d 个任务汇总",
            res.from, res.to, res.primes, tostring(res.largest), res.ranges)
    end,
}

]],
    ["selftest.lua"] = [[
return {
    name    = "selftest",
    summary = "集群自检：已知答案 + 可选故障注入（验证调度/汇总/重派）",

    twoLevel = false,
    params  = {
        { name = "tasks", type = "number", default = 24,   help = "任务数" },
        { name = "size",  type = "number", default = 2000, help = "每任务平方和项数" },
        { name = "fail",  type = "number", default = 0,    help = "故意失败的任务数" },
    },

    split = function(a)
        local tasks = math.max(1, math.floor(a.tasks))
        local size  = math.max(1, math.floor(a.size))
        local fail  = math.max(0, math.floor(a.fail))
        local out = {}
        for i = 1, tasks do
            out[#out + 1] = { id = i, n = size, fail = i <= fail }
        end
        return out
    end,

    map = function(task, ctx)
        if task.fail then

            error("selftest 故意失败（任务 " .. tostring(task.id) .. "）")
        end

        local sum = 0
        for i = 1, task.n do
            sum = sum + i * i
            if i % 256 == 0 then
                ctx.progress(i / task.n, string.format("%d/%d", i, task.n))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { id = task.id, n = task.n, sum = sum }
    end,

    reduce = function(results, a)
        local tasks = math.max(1, math.floor(a.tasks))
        local fail  = math.max(0, math.floor(a.fail))
        local want  = tasks - fail

        local seen, bad, total = {}, {}, 0
        for _, r in ipairs(results) do
            if type(r) ~= "table" or type(r.id) ~= "number" then
                bad[#bad + 1] = "收到结构异常的结果"
            else
                if seen[r.id] then bad[#bad + 1] = "任务 " .. r.id .. " 出现重复" end
                seen[r.id] = true

                local expect = r.n * (r.n + 1) * (2 * r.n + 1) / 6
                if r.sum ~= expect then
                    bad[#bad + 1] = string.format("任务 %d 校验不符：%s ≠ %s",
                        r.id, tostring(r.sum), tostring(expect))
                end
                total = total + r.sum
            end
        end

        local missing = {}
        for i = 1, tasks do
            if i > fail and not seen[i] then missing[#missing + 1] = i end
        end

        return {
            tasks = tasks, fail = fail, want = want, got = #results,
            bad = bad, missing = missing, total = total,
        }
    end,

    format = function(res)
        local pass = (#res.bad == 0) and (#res.missing == 0) and (res.got == res.want)
        local lines = {
            string.format("任务 %d 个：预期成功 %d，实际成功 %d；预期失败 %d（与主控日志核对）",
                res.tasks, res.want, res.got, res.fail),
            string.format("平方和闭式解校验：%s", #res.bad == 0 and "全部一致" or (#res.bad .. " 个不一致")),
            string.format("任务号完整性：%s", #res.missing == 0 and "齐全且无重复"
                or ("缺少 " .. table.concat(res.missing, ","))),
            "结论：" .. (pass and "PASS —— 链路正常" or "FAIL —— 看上面的明细与主控日志"),
        }
        for i = 1, math.min(#res.bad, 4) do lines[#lines + 1] = "  " .. res.bad[i] end
        return table.concat(lines, "\n")
    end,
}

]],
    ["tsp.lua"] = [=[
local function cities(n, seed)
    local list = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        list[i] = { x = (next() % 10001) / 1000, y = (next() % 10001) / 1000 }
    end
    return list
end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

return {
    name    = "tsp",
    summary = "旅行商暴力搜索（按第二个城市切分，可对最优解）",
    params  = {
        { name = "cities", type = "number", default = 9, help = "城市数量（9 → 8! 条回路，按第二城切成 8 份）" },
        { name = "seed",   type = "number", default = 5, help = "随机种子（决定城市坐标）" },
    },

    split = function(a)
        local n = math.max(3, math.floor(a.cities))
        local tasks = {}
        for k = 2, n do
            tasks[#tasks + 1] = { n = n, seed = math.floor(a.seed), second = k }
        end
        return tasks
    end,

    map = function(task, ctx)
        local pts = cities(task.n, task.seed)
        local others = {}
        for i = 2, task.n do
            if i ~= task.second then others[#others + 1] = i end
        end

        local bestLen, bestTour = math.huge, nil
        local path, steps = {}, 0

        local function walk(depth, curLen, prev)
            if curLen >= bestLen then return end
            if depth > #others then
                local total = curLen + dist(pts[prev], pts[1])
                if total < bestLen then
                    local tour = { 1, task.second }
                    for i = 1, #others do tour[#tour + 1] = path[i] end
                    bestLen, bestTour = total, tour
                end
                return
            end
            for i = depth, #others do
                others[i], others[depth] = others[depth], others[i]
                path[depth] = others[depth]
                walk(depth + 1, curLen + dist(pts[prev], pts[path[depth]]), path[depth])
                others[i], others[depth] = others[depth], others[i]
                steps = steps + 1
                if steps % 500 == 0 then
                    ctx.tick()
                    if ctx.canceled() then return end
                end
            end
        end

        walk(1, dist(pts[1], pts[task.second]), task.second)
        return { second = task.second, len = bestLen, tour = bestTour, steps = steps }
    end,

    reduce = function(results, a)
        local bestLen, bestTour, steps, parts = math.huge, nil, 0, 0
        for _, r in ipairs(results) do
            steps = steps + (r.steps or 0)
            parts = parts + 1
            local len = r.len or r.bestLen
            if len and len < bestLen then
                bestLen = len
                bestTour = r.tour or r.bestTour
            end
        end
        return { n = math.floor(a.cities), len = bestLen, tour = bestTour,
            steps = steps, parts = parts }
    end,

    format = function(res)
        local tour = {}
        for i, c in ipairs(res.tour or {}) do tour[i] = tostring(c) end
        return string.format("TSP：%d 个城市，最短回路 %.4f，路线 %s→1（枚举 %d 次，%d 个分支任务）",
            res.n, res.len, table.concat(tour, "→"), res.steps, res.parts)
    end,
}

]=],

}

local args = { ... }
local what, startup, force, cleanup = "all", nil, false, false
for _, a in ipairs(args) do
    local s = tostring(a)
    if s == "--force" then
        force = true
    elseif s == "--cleanup" then
        cleanup = true
    elseif s:sub(1, 10) == "--startup=" then
        startup = s:sub(11)
    elseif s == "-h" or s == "--help" or s == "?" then
        what = "help"
    elseif s:sub(1, 2) ~= "--" then
        what = s
    end
end

if what == "help" then
    print("用法：install.lua [all|master|worker|jobs] [--startup=master|worker] [--force] [--cleanup]")
    print("  --cleanup  装完把安装器自己删掉（CC 电脑只有 1MB 磁盘，这个文件不小）")
    return
end

local function ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

local function put(path, data)
    ensureDir(path:match("^(.*)/[^/]*$"))
    if fs.exists(path) and not force then
        print(string.format("跳过（已存在）  %s", path))
        return false
    end
    local h = fs.open(path, "w")
    if not h then
        print("!! 无法写入 " .. path)
        return false
    end
    h.write(data)
    h.close()
    print(string.format("写入 %-30s %7d 字节", path, #data))
    return true
end

local want = {
    master    = (what == "all" or what == "master"),
    worker    = (what == "all" or what == "worker"),
    bootstrap = (what == "all" or what == "bootstrap"),
    jobs      = (what == "all" or what == "jobs"),
}
if not (want.master or want.worker or want.bootstrap or want.jobs) then
    print("不认识的选项：" .. tostring(what) .. "（all / master / worker / bootstrap / jobs）")
    return
end

local written = 0
for path, data in pairs(FILES) do
    local kind = path:find("master%.lua$") and "master"
        or path:find("worker%.lua$") and "worker"
        or path:find("bootstrap%.lua$") and "bootstrap" or "jobs"
    if want[kind] and put(path, data) then written = written + 1 end
end

if want.jobs then
    for name, data in pairs(JOBS) do
        if put("/dccomp/jobs/" .. name, data) then written = written + 1 end
    end
end

if startup == "master" or startup == "worker" then
    local target = (startup == "master") and "/dccomp/master.lua" or "/dccomp/worker.lua"
    local body = string.format("-- dcnet 开机自启（install.lua 生成）\nif fs.exists(%q) then shell.run(%q) end\n",
        target, target)
    if put("/startup.lua", body) then written = written + 1 end
elseif startup then
    print("--startup 只接受 master 或 worker")
end

ensureDir("/dccomp/jobs")
ensureDir("/dccomp")
print(string.format("完成：写入 %d 个文件。", written))
if want.master then
    print("主控：shell.run(\"/dccomp/master.lua\")")
end
if want.worker then
    print("节点：shell.run(\"/dccomp/worker.lua\")（不给参数会自动找主控）")
end

-- 安装器自己也不小，装完就没用了：提示删掉（或下次直接 --cleanup）
local self = shell and shell.getRunningProgram and shell.getRunningProgram() or nil
if cleanup then
    if self and fs.exists(self) and fs.delete(self) then
        print("已删除安装器自身：" .. self)
    end
elseif self and fs.exists(self) then
    local size = fs.getSize(self) or 0
    print(string.format("提示：安装器自身 %s，装完可删：delete %s（或用 --cleanup）",
        tostring(math.floor(size / 1024)) .. "KB", self))
end
