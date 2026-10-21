--[[- ==========================================================================
  dcnet v1.2.0 — CC:Tweaked 分布式计算网络（网络屏幕 screen）

  本文件由 tools/build.py 自动生成，请勿直接编辑。
  要改逻辑请改 src/ 下的源码，然后重新运行：
      python tools/build.py

  模块：dc.util, dc.protocol, dc.net, dc.screen, dc.crypto, dc.panel
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

__dc_define("dc.screen", function()
local util  = dc_require("dc.util")
local proto = dc_require("dc.protocol")
local net   = dc_require("dc.net")
local panel = dc_require("dc.panel")

local M = {}

M.DEFAULTS = {
    monitor  = "",
    scale    = 0.5,
    name     = "",
    interval = 3,
    timeout  = 15,
}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local function clampScale(v)
    v = tonumber(v) or M.DEFAULTS.scale
    if v < 0.5 then v = 0.5 end
    if v > 5 then v = 5 end
    return v
end

function M.run(opts)
    opts = opts or {}
    local scale = clampScale(opts.scale)

    local modems, failed = net.openAll()
    if #modems == 0 then
        printError("[dcnet] 网络屏幕：没有检测到调制解调器（modem）")
        print("[dcnet] 屏幕电脑也要接在有线网络（或同一无线网络）里。")
        return false
    end
    for _, e in ipairs(failed or {}) do
        print("[dcnet] 网络屏幕：打开 modem 失败：" .. tostring(e))
    end

    local key = opts.key
    if key == nil or key == "" then
        key = rawget(_G, "DCNET_KEY") or (settings and settings.get("dcnet.key")) or ""
    end
    key = tostring(key)
    if key ~= "" then
        local ok, err = net.setKey(key)
        if not ok then
            print("[dcnet] 网络屏幕：启用消息签名失败：" .. tostring(err))
        else
            print("[dcnet] 网络屏幕：消息签名已启用（指纹 " ..
                tostring(net.fingerprint()) .. "）")
        end
    end

    local monitors = panel.findMonitors()
    if #monitors == 0 then
        printError("[dcnet] 网络屏幕：这台电脑上没有显示器（monitor）")
        print("[dcnet] 把显示器贴在电脑侧面，或用 screen.lua <外设名> 指定。")
        return false
    end
    local want = tostring(opts.monitor or "")
    local pick
    for _, m in ipairs(monitors) do
        if want == "" or m.name == want then pick = m break end
    end
    if not pick then
        local names = {}
        for _, m in ipairs(monitors) do names[#names + 1] = m.name end
        printError("[dcnet] 网络屏幕：找不到显示器 " .. want ..
            "；可用：" .. table.concat(names, ", "))
        return false
    end
    if not pick.periph then
        printError("[dcnet] 网络屏幕：无法打开显示器 " .. pick.name)
        return false
    end

    local dev, monName = pick.periph, pick.name
    local w, h = 51, 19
    local function resize()
        pcall(function() dev.setTextScale(scale) end)
        local ok, nw, nh = pcall(function() return dev.getSize() end)
        if ok and nw then w, h = nw, nh end
    end
    resize()

    local name = tostring(opts.name or "")
    if name == "" then
        local ok, label = pcall(function() return os.getComputerLabel() end)
        if ok and label and label ~= "" then name = label end
    end
    if name == "" then name = "screen-" .. tostring(os.getComputerID()) end

    local interval = math.max(1, tonumber(opts.interval) or M.DEFAULTS.interval)
    local timeout = math.max(3, tonumber(opts.timeout) or M.DEFAULTS.timeout)

    local masterId, masterSeen = nil, 0
    local frames, lastHello, lastStatus, lastBad = 0, -interval, 0, 0
    local offWhy = nil

    local function statusLines()
        local out = {}
        out[#out + 1] = { text = string.format("dcnet 网络屏幕 #%d", os.getComputerID()),
            colour = col("lime", 32) }
        out[#out + 1] = { text = string.format("显示器 %s  %dx%d", monName, w, h),
            colour = col("lightGray", 1024) }
        if masterId and util.mono() - masterSeen <= timeout then
            out[#out + 1] = { text = string.format("已连接主控 #%d", masterId),
                colour = col("lime", 32) }
            out[#out + 1] = { text = string.format("已收到 %d 帧面板", frames),
                colour = col("white", 1) }
        elseif offWhy == "off" then
            out[#out + 1] = { text = "主控已关闭网络屏幕推送", colour = col("orange", 2) }
            out[#out + 1] = { text = "在主控上执行 mon net on 重新开启",
                colour = col("lightGray", 1024) }
        elseif offWhy == "full" then
            out[#out + 1] = { text = "主控的网络屏幕数量已满", colour = col("orange", 2) }
            out[#out + 1] = { text = "在主控上 mon net 看列表 / 踢掉不用的屏幕",
                colour = col("lightGray", 1024) }
        elseif offWhy == "ver" then
            out[#out + 1] = { text = "协议版本不兼容", colour = col("red", 16384) }
            out[#out + 1] = { text = "请把 screen.lua 更新到与主控相同的版本",
                colour = col("lightGray", 1024) }
        elseif offWhy == "kick" then
            out[#out + 1] = { text = "已被主控断开", colour = col("orange", 2) }
            out[#out + 1] = { text = "下次心跳会自动重连", colour = col("lightGray", 1024) }
        else
            out[#out + 1] = { text = "正在寻找主控…", colour = col("yellow", 256) }
            out[#out + 1] = { text = "在主控上输入 mon 查看网络屏幕",
                colour = col("lightGray", 1024) }
        end
        out[#out + 1] = { text = os.date("%H:%M:%S"), colour = col("gray", 128) }
        return out
    end

    local function redrawStatus()
        local now = util.mono()
        if now - lastStatus < 2 then return end
        lastStatus = now
        panel.draw(dev, statusLines(), h)
    end

    panel.draw(dev, statusLines(), h)
    print(string.format("[dcnet] 网络屏幕 %s 已启动：显示器 %s（%dx%d），等待主控…",
        name, monName, w, h))

    while true do
        local now = util.mono()

        local ok, nw, nh = pcall(function() return dev.getSize() end)
        if ok and nw and (nw ~= w or nh ~= h) then
            w, h = nw, nh
            resize()
            lastHello = now - interval
        end

        if now - lastHello >= interval then
            lastHello = now
            net.broadcast(proto.msg(proto.SCREEN, {
                name = name, w = w, h = h, scale = scale,
            }), util.PROTO_CTRL)
        end

        local sender, msg = net.receive(util.PROTO_CTRL, 0.5)
        local gotFrame = false
        if msg and proto.valid(msg) then
            local vok, why = net.verify(sender, msg)
            if not vok then
                if now - lastBad > 10 then
                    lastBad = now
                    print("[dcnet] 网络屏幕：丢弃一条消息（" .. tostring(why) .. "）")
                end
            elseif msg.t == proto.DISP and type(msg.lines) == "string" then
                local parsed, lines = pcall(textutils.unserialize, msg.lines)
                if parsed and type(lines) == "table" then
                    masterId, masterSeen = sender, util.mono()
                    frames, offWhy = frames + 1, nil
                    panel.draw(dev, lines, msg.h or h)
                    gotFrame = true
                end
            elseif msg.t == proto.SCREENOFF then
                masterId, offWhy = nil, tostring(msg.why or "off")
                redrawStatus()
            end
        end

        if not gotFrame and util.mono() - masterSeen > timeout then
            redrawStatus()
        end
    end
    return true
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

local function typesOf(ty)
    local out = {}
    if type(ty) == "string" then
        out[1] = ty
    elseif type(ty) == "table" then
        for _, t in ipairs(ty) do out[#out + 1] = t end
    end
    return out
end

local function isMonitorType(ty)
    for _, t in ipairs(typesOf(ty)) do
        if t == "monitor" then return true end
    end
    return false
end

function M.typeOf(name, modems)
    local ok, ty = pcall(peripheral.getType, name)
    if ok and ty ~= nil then return ty end
    for _, md in ipairs(modems or {}) do
        if type(md.getTypeRemote) == "function" then
            local ok2, t = pcall(md.getTypeRemote, name)
            if ok2 and t ~= nil then return t end
        end
    end
end

function M.findMonitors()
    local order, remote, modems, seen = {}, {}, {}, {}

    local function add(name, isRemote)
        name = tostring(name)
        if seen[name] then
            if isRemote then remote[name] = true end
            return
        end
        seen[name] = true
        order[#order + 1] = name
        if isRemote then remote[name] = true end
    end

    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        names[#names + 1] = name
        add(name, false)
    end

    for _, name in ipairs(names) do
        for _, t in ipairs(typesOf(M.typeOf(name))) do
            if t == "modem" then
                local ok, dev = pcall(peripheral.wrap, name)
                if ok and dev and type(dev.getNamesRemote) == "function" then
                    modems[#modems + 1] = dev
                    local ok2, list = pcall(dev.getNamesRemote)
                    if ok2 and type(list) == "table" then
                        for _, rn in ipairs(list) do add(rn, true) end
                    end
                end
                break
            end
        end
    end

    local found = {}
    for _, name in ipairs(order) do
        if isMonitorType(M.typeOf(name, modems)) then
            local ok, dev = pcall(peripheral.wrap, name)
            found[#found + 1] = { name = name, periph = ok and dev or nil, net = remote[name] or false }
        end
    end
    table.sort(found, function(a, b)
        if a.net ~= b.net then return not a.net end
        return a.name < b.name
    end)
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
        if not isMonitorType(M.typeOf(target)) then
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

function M.linesFor(sched, cloud, w, h)
    local out = {}
    w = math.max(1, tonumber(w) or 51)
    h = math.max(1, tonumber(h) or 19)

    local function add(text, colour)
        out[#out + 1] = { text = util.trunc(text, w), colour = colour }
    end

    add(string.format("dcnet 主控 #%d   %s", os.getComputerID(), os.date("%H:%M:%S")),
        col("lime", 32))

    if w < 20 or h < 4 then
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

function Panel:lines(sched, cloud)
    return M.linesFor(sched, cloud, self.w, self.h)
end

function M.draw(dev, lines, h)
    if not dev or type(lines) ~= "table" then return false end
    h = math.max(1, tonumber(h) or 19)
    pcall(function() dev.setBackgroundColour(col("black", 32768)) end)
    pcall(function() dev.clear() end)
    local all = true
    for i = 1, math.min(#lines, h) do
        local line = lines[i] or {}
        local ok = pcall(function()
            dev.setCursorPos(1, i)
            dev.setTextColour(line.colour or col("white", 1))
            dev.write(tostring(line.text or ""))
        end)
        if not ok then all = false end
    end
    pcall(function() dev.setCursorPos(1, 1) end)
    return all
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

    local drawn = M.draw(self.periph, lines, self.h)
    if not drawn then
        self.log("面板写入显示器失败（尺寸 " .. tostring(self.w) .. "x" .. tostring(self.h) .. "）", 16384)
    end
    return drawn
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

local screen = dc_require("dc.screen")

local argv = { ... }

if type(argv[1]) == "table" then argv = argv[1] end

local opts = {}
for k, v in pairs(rawget(_G, "DCNET_CFG") or {}) do opts[k] = v end
for _, a in ipairs(argv) do
    local s = tostring(a)
    local k, v = s:match("^%-%-([%w_]+)=(.*)$")
    if k then
        local n = tonumber(v)
        opts[k] = n or v
    elseif s:sub(1, 1) ~= "-" and not opts.monitor then
        opts.monitor = s
    end
end

local ok = screen.run(opts)
if not ok then
    printError("[dcnet] 网络屏幕启动失败。")
    return 1
end
return 0
