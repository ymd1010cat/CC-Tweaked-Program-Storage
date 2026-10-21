--[[- dc.util — 通用工具

时间、字符串、哈希、文件读写、作业代码加载、参数解析。
所有模块通过 dc_require("dc.util") 取得本表。

注意：本文件会被 tools/build.py 打包成单文件，模块内不要依赖相对路径。
]]

local M = {}

-- ── 常量 ────────────────────────────────────────────────────────────────
M.VERSION    = "1.2.0"
M.PROTO_CTRL = "dccomp"          -- 控制 / 任务协议
M.PROTO_PUSH = "dcpush"          -- 代码分发协议（push / bootstrap）
M.ROOT       = rawget(_G, "DCNET_ROOT") or "/dccomp" -- 安装根目录（ush 包会覆盖）
M.JOB_DIR    = M.ROOT .. "/jobs" -- 作业定义目录（只存在于主控）
M.OUT_DIR    = M.ROOT .. "/out"  -- 结果导出目录
M.CONTROL_DIR = M.ROOT .. "/ctl" -- 外壳转交命令的队列目录
M.WORKER_FILE = rawget(_G, "DCNET_WORKER_FILE") or (M.ROOT .. "/worker.lua")

M.unpack  = table.unpack or unpack
M.colours = rawget(_G, "colors") or rawget(_G, "colours")

-- ── 时间 ────────────────────────────────────────────────────────────────

--- 墙钟毫秒（用于跨机比较 / 展示）
function M.now()
    if os.epoch then
        local ok, v = pcall(os.epoch, "utc")
        if ok and type(v) == "number" then return v end
    end
    return math.floor(os.clock() * 1000)
end

--- 单调秒（用于测时长；os.clock 在 CC 里是开机以来的秒数）
function M.mono()
    return os.clock()
end

--- 毫秒时长格式化：950 -> "950ms"，12345 -> "12.3s"，3900000 -> "1h05m"
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

--- 字节数格式化
function M.bytes(n)
    n = tonumber(n) or 0
    if n < 1024 then return n .. "B" end
    if n < 1024 * 1024 then return string.format("%.1fKB", n / 1024) end
    return string.format("%.2fMB", n / 1024 / 1024)
end

-- ── 字符串 ──────────────────────────────────────────────────────────────

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 纯文本切分（sep 不做模式匹配）
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

--- 把一行命令拆成 token，支持单/双引号
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

--- 估算显示宽度（列）：ASCII 记 1 列，其他多字节字符（中日韩等）记 2 列。
-- CC 终端里中文占两列，按字节截断会把字切成两半，所以这里按"列"来算。
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

--- 按显示宽度截断（不会切断多字节字符），超长补省略号
function M.fit(s, cols)
    s = tostring(s or "")
    cols = math.floor(tonumber(cols) or 0)
    if cols <= 0 then return "" end
    if M.textWidth(s) <= cols then return s end
    -- 省略号本身也占宽度（"…" 是 2 列），必须一起算进去
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

--- 截断到 n 列（超出加省略号）。按显示宽度算，中英混排不会切碎字符。
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

--- 百分比条：[####------]  42%
function M.bar(pct, width)
    width = width or 10
    pct = math.max(0, math.min(1, tonumber(pct) or 0))
    local fill = math.floor(pct * width + 0.5)
    return string.rep("#", fill) .. string.rep("-", width - fill)
end

-- ── 哈希（用于作业源码缓存键、传输校验） ─────────────────────────────────

--- 31 进制滚动哈希，取模 2^31-1，避免浮点精度溢出
function M.hash(s)
    s = tostring(s or "")
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return string.format("%08x%04x", h, #s % 65536)
end

-- ── 文件 ────────────────────────────────────────────────────────────────

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

-- ── 日志 ────────────────────────────────────────────────────────────────

--- 追加一行日志（超过 maxBytes 就砍掉前一半，做最简轮转）
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

--- 带时间戳的日志行
function M.logLine(text)
    return string.format("[%s] %s", os.date("%H:%M:%S"), tostring(text))
end

-- ── 配置持久化（走 CC 的 settings API，写到 /<id>/.settings） ────────────

M.CFG_PREFIX = "dcnet."

--- 把 defaults 注册进 CC 的 settings（带默认值与类型），返回"当前生效"的配置表。
-- meta 可选：key -> 说明文字
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

--- 持久化一项配置（下次启动仍生效）
function M.saveCfg(key, value)
    if settings and settings.set then
        settings.set(M.CFG_PREFIX .. key, value)
        return true
    end
    return false, "本机没有 settings API"
end

--- 生成配置表的多行展示
function M.cfgLines(cfg, meta)
    local out = {}
    for _, k in ipairs(M.sortedKeys(cfg)) do
        out[#out + 1] = string.format("  %-16s = %-10s %s", k, tostring(cfg[k]),
            (meta and meta[k]) or "")
    end
    return out
end

-- ── Lua 代码装载（Lua 5.1 / 5.4 双兼容） ────────────────────────────────

--- 编译一段源码，可选地设置其环境表。
-- Cobalt(Lua 5.1) 用 loadstring+setfenv；Lua 5.2+ 用 load(...,"t",env)。
-- 注意：Lua 5.2+ 里显式传 env=nil 会把 _ENV 设成 nil（连全局表都访问不到），
-- 所以 env 为 nil 时必须只传三个参数。
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

--- 编译并立刻执行，返回执行结果
function M.runChunk(src, chunkname, env)
    local fn, err = M.loadChunk(src, chunkname, env)
    if not fn then return nil, "编译失败: " .. tostring(err) end
    local ok, res = pcall(fn)
    if not ok then return nil, "运行失败: " .. tostring(res) end
    return res
end

--- 给一个表做浅拷贝
function M.copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

--- 有序遍历 key（数字优先，其次字符串字典序）
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

--- 作业参数声明解析：把 {"from=2","100"} + params 声明 归一化成命名参数表
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
