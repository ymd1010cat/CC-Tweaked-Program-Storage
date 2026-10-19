--[[ 性能基线测量（在真 CraftOS 里跑一遍各作业的 map）

    CraftOS-PC_console.exe --headless --directory <tmp> --script tests/bench.lua

输出形如：
    BENCH primes 25000 12.3 2032.5 ops/s
    BENCH 表头：<作业> <规模> <单任务毫秒> <吞吐>

注意：这里量的是 **CraftOS-PC**（PC 上跑，比游戏内电脑快几十倍）。docs/PERF.md 里
说明了怎么换算成游戏内估算，以及在游戏里怎么自己量。
]]

_G.dc_require = function(name)
    local short = name:match("^dc%.(.+)$")
    return dofile("/project/src/lib/" .. short .. ".lua")
end

local jobs = _G.dc_require("dc.jobs")

local function loadJob(name)
    local f = fs.open("/project/src/jobs/" .. name .. ".lua", "r")
    if not f then return nil end
    local src = f.readAll()
    f.close()
    return jobs.loadSource(src, "@" .. name)
end

-- 一个"什么都不做"的 ctx：基准测试里不需要让出/上报
local function benchCtx()
    return {
        progress = function() end,
        tick = function() end,
        canceled = function() return false end,
        log = function() end,
        now = function() return os.epoch("utc") end,
        mono = os.clock,
    }
end

local function measure(jobName, params, label, unitOf)
    local def = loadJob(jobName)
    if not def then
        print("BENCHFAIL " .. jobName .. " " .. label .. " 装载失败")
        return
    end
    local args = {}
    for k, v in pairs(params) do args[k] = v end
    local ok, tasks = pcall(def.split, args)
    if not ok or type(tasks) ~= "table" or #tasks == 0 then
        print("BENCHFAIL " .. jobName .. " " .. label .. " split 失败: " .. tostring(tasks))
        return
    end
    -- 只量"一个任务"的时间（这就是节点实际感受的粒度）。
    -- os.clock 在真机上是毫秒级，所以太快的用例要重复多次再取平均，否则会量成 0。
    local task = tasks[math.max(1, math.floor(#tasks / 2))]
    local ctx = benchCtx()
    local ms = 0
    local reps = 1
    for _ = 1, 2 do
        local t0 = os.clock()
        for _ = 1, reps do
            def.map(task, ctx)
        end
        ms = (os.clock() - t0) * 1000 / reps
        if ms >= 3 or reps >= 200 then break end
        reps = math.min(200, math.max(2, math.ceil(30 / math.max(ms, 0.05))))
    end
    local res = def.map(task, ctx)
    local units = unitOf and unitOf(args, tasks, task, res) or 0
    local rate = (ms > 0) and (units / (ms / 1000)) or 0
    -- 行要短：CraftOS 控制台会按屏幕宽度折行，折了就没法解析了
    print(string.format("BENCH %s %s %.2f %.0f", jobName, label, ms, rate))
    print(string.format("BENCHINFO %s %s 单位=%d 重复=%d 任务数=%d",
        jobName, label, units, reps, #tasks))
end

print("BENCH 开始（CraftOS-PC，Lua " .. _VERSION .. "）")

-- 素数：区间越大越慢
measure("primes", { from = 2, to = 25000, chunk = 25000 }, "25k区间",
    function(a) return 25000 end)
measure("primes", { from = 2, to = 200000, chunk = 200000 }, "200k区间",
    function(a) return 200000 end)

-- 蒙特卡洛：按样本数
measure("pi", { samples = 20000, chunk = 20000, seed = 1 }, "2万样本",
    function(a) return 20000 end)
measure("pi", { samples = 200000, chunk = 200000, seed = 1 }, "20万样本",
    function(a) return 200000 end)

-- 矩阵乘法：n^3 次乘加
measure("matmul", { n = 24, rows = 24, seed = 7 }, "n=24",
    function(a) return a.n * a.n * a.n end)
measure("matmul", { n = 48, rows = 48, seed = 7 }, "n=48",
    function(a) return a.n * a.n * a.n end)

-- N 体：n^2 次两两作用
measure("nbody", { bodies = 32, step = 32, seed = 3, eps = 0.5 }, "32体",
    function(a) return a.bodies * (a.bodies - 1) end)
measure("nbody", { bodies = 96, step = 96, seed = 3, eps = 0.5 }, "96体",
    function(a) return a.bodies * (a.bodies - 1) end)

-- 大负载：主要是序列化 + 数据量
measure("bigdata", { tasks = 1, size = 24000, res = 12000, seed = 1 }, "负载24KB",
    function(a) return 24000 + 12000 end)

-- 暴力搜索：区间大小
measure("hashsearch", { from = 1, to = 100000, chunk = 100000, modulus = 1048576 }, "10万区间",
    function(a) return 100000 end)

print("BENCH 结束")
os.shutdown()
