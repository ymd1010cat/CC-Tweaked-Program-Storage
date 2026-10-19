--[[- dcnet 运算节点入口

用法：
    worker.lua [主控ID] [节点名]
    /dccomp/worker.lua [主控ID] [节点名]

不给主控 ID 时会自动在有线网络上广播寻找主控。
]]

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
local masterId = tonumber(argv[1])
local name = argv[2]

local ok = worker.run({ master = masterId, name = name })
if not ok then
    printError("[dcnet] 节点启动失败。")
end
