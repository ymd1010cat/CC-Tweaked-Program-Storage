--[[- dcnet 网络屏幕入口

用法：
    screen.lua [显示器名] [--scale=0.5] [--name=屏幕名] [--key=共享密钥]
    /dccomp/screen.lua [显示器名]

给一台"接在别的电脑上的显示器"用：这台电脑不参与计算，只把主控的面板画到
自己的显示器上。主控那边不用配置——屏幕会自动广播登记（主控 `mon` 可查看）。

例：
    screen.lua                     自动找显示器，缩放 0.5
    screen.lua right --scale=0.5   指定右侧显示器
    screen.lua --name=机房大屏      主控 mon net 里显示这个名字

集群设了共享密钥时：屏幕电脑上用 CC 自带的 set 写同一个密钥，或用 --key=。
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
        if not short then error("invalid module name: " .. tostring(name), 0) end
        local tried = {}
        for _, pat in ipairs(paths) do
            local path = pat:format(short)
            tried[#tried + 1] = path
            if fs.exists(path) and not fs.isDir(path) then
                local fn, err = loadfile(path)
                if not fn then error("failed to load module " .. name .. ": " .. tostring(err), 0) end
                local mod = fn()
                cache[name] = mod
                return mod
            end
        end
        error("module not found: " .. name .. " (tried: " .. table.concat(tried, ", ") .. ")", 0)
    end
end

local screen = dc_require("dc.screen")

local argv = { ... }
-- unixshell 的命令块拿到的是 (args_table, stage)；独立运行时才是逐个字符串。
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
    printError("[dcnet] screen failed to start.")
    return 1
end
return 0
