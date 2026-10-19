--[[- dcnet 主控入口

用法：
    master.lua           直接从源码目录运行（开发用，模块从 lib/ 读）
    /dccomp/master.lua   打包后的单文件版本（推荐，dist/master.lua）

本文件在打包版里由 tools/build.py 追加在模块表后面，因此开头的
"开发模式加载器"在 dist 版本中会自动跳过。
]]

-- ── 开发模式：从磁盘加载模块 ────────────────────────────────────────────
-- （打包版：dist/master.lua 会在前面内置模块表并定义 dc_require）
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

-- ── 启动 ────────────────────────────────────────────────────────────────
local util   = dc_require("dc.util")
local master = dc_require("dc.master")
local sched  = dc_require("dc.sched")

-- 命令行参数优先于 settings 里持久化的配置：
--   master.lua -v --maxParallel=2 --redundancy=2 --workerTimeout=8
--   master.lua standby            以待命主控启动（在岗主控掉线就接管）
local argv = { ... }
local cfg  = {}
for _, a in ipairs(argv) do
    local s = tostring(a)
    if s == "-v" or s == "--verbose" then
        cfg.verbose = true
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
})
if not ok then
    printError("[dcnet] 主控启动失败。")
end
