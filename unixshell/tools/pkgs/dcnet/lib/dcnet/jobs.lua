--[[- dc.jobs — 作业（Job）框架

一个"作业"就是 /dccomp/jobs/<名字>.lua 这样一个文件，内容是一段返回 table 的
Lua 代码：

    return {
        name    = "primes",                     -- 必填，与文件名一致
        summary = "统计区间内素数个数",           -- 可选，列表里显示
        params  = { {name="from", type="number", default=2, help="..."} },
        split   = function(args) ... end,       -- 主控运行：把作业拆成任务数组
        map     = function(task, ctx) ... end,  -- 节点运行：算一个任务
        reduce  = function(results, args) ... end, -- 主控运行：汇总
        format  = function(res, args) ... end,  -- 主控运行：格式化最终结果
    }

关键点：主控下发任务时会把 **整份源码** 发给节点，节点在自己的沙箱里
load 后调用 map。所以节点不需要预装作业，主控改一行作业代码，全网立刻生效。

节点上的约束：
  * map 里不能 require 别的文件（源码是独立片段）。
  * map 必须周期性调用 ctx.tick()：CC 对"长时间不让出"的程序会直接报错终止
    （Too long without yielding）。ctx.tick() 会在需要时让出并上报进度。
  * map 的返回值必须是可序列化的（number/string/boolean/table，不能有函数）。
]]

local util = dc_require("dc.util")

local M = {}

-- ── 校验与装载 ──────────────────────────────────────────────────────────

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

-- ── 云端卸载：由作业自己决定怎么打包请求、怎么解析响应 ─────────────────

--- 调 job.cloud.build(task, args) 生成请求体（table 或字符串）。
-- 返回 nil, err 表示打包失败。
function M.buildCloudRequest(def, task, args)
    if not (def and def.cloud and def.cloud.build) then
        return nil, "作业没有定义 cloud.build"
    end
    local ok, body = pcall(def.cloud.build, task, args)
    if not ok then return nil, tostring(body) end
    if body == nil then return nil, "cloud.build 返回了 nil" end
    return body
end

--- 调 job.cloud.parse(decoded, task, args) 把响应变成任务结果。
function M.parseCloudResponse(def, decoded, task, args)
    if not (def and def.cloud and def.cloud.parse) then
        return nil, "作业没有定义 cloud.parse"
    end
    local ok, data = pcall(def.cloud.parse, decoded, task, args)
    if not ok then return nil, tostring(data) end
    if data == nil then return nil, "cloud.parse 返回了 nil" end
    return data
end

--- 两级汇总的中间任务：在节点上跑 def.reduce（负载里带着一组结果）。
-- 返回的是"部分汇总结果"，主控最后再对这些部分结果做一次 reduce。
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

--- 从源码字符串装载作业定义（主控与节点共用）
function M.loadSource(src, chunkname)
    local def, err = util.runChunk(src, chunkname or "=dcjob")
    if not def then return nil, err end
    local ok, verr = M.validate(def)
    if not ok then return nil, verr end
    def.source = src
    def.hash   = util.hash(src)
    return def
end

--- 从文件装载（主控侧）
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

--- 列出所有可用作业
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

--- 首次启动时把随包附带的示例作业写到磁盘（不覆盖已有文件）
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

-- ── 参数 ────────────────────────────────────────────────────────────────

--- 把 {"to=1000000"} 之类的 token 按 params 声明归一化
function M.resolveArgs(def, tokens)
    return util.parseArgs(tokens, def.params or {})
end

--- 生成一行参数说明
function M.paramHelp(def)
    local parts = {}
    for _, p in ipairs(def.params or {}) do
        parts[#parts + 1] = string.format("%s=%s", p.name, tostring(p.default))
    end
    return table.concat(parts, " ")
end

-- ── 主控侧：拆分 / 汇总 ─────────────────────────────────────────────────

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

-- ── 节点侧：沙箱执行 map ────────────────────────────────────────────────

--- 在受限环境里执行一个作业的 map。
-- ctx 会作为第二个参数传入，同时注入环境全局 ctx。
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

    -- 返回 nil 视为失败：既方便排错，也避免结果数组里出现空洞
    if res == nil then
        return nil, "map 返回了 nil（要表达\"没找到\"请返回显式结构，例如 { hit = false }）"
    end

    -- 结果必须可序列化，否则在网络上会静默丢失
    local sok = pcall(textutils.serialize, res)
    if not sok then return nil, "map 返回值无法序列化（可能包含函数或协程）" end
    return res
end

return M
