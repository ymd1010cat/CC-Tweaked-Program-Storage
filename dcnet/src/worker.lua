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

local argv = { ... }
-- Pyromputer OS 的命令块拿到的是 (args_table, stage)；独立运行时才是逐个字符串。
if type(argv[1]) == "table" then argv = argv[1] end

local worker = dc_require("dc.worker")

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
    printError("[dcnet] worker failed to start.")
    return 1
end
return 0
