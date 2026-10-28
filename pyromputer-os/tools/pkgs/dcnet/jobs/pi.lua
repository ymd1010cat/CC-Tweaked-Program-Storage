--[[ dcnet 内置作业：蒙特卡洛估算 π

把 samples 个随机点分给各节点，统计落在单位圆内的比例，π ≈ 4 * inside / total。
误差量级 ~ 1/sqrt(N)：一千万个样本大约能精确到小数点后 3 位。

参数：
  samples=2000000   总样本数
  chunk=50000       每个任务的样本数
  seed=12345        随机种子（每个任务用 seed+任务序号，结果可复现）

注意：这里用 Park–Miller 线性同余发生器自己实现随机数，一是结果可复现，
二是避免 math.random 在不同 CC 版本上序列不同。所有中间量都在 2^53 以内，
不会丢精度。
]]

return {
    name    = "pi",
    summary = "Estimate pi by Monte Carlo (random simulation job demo)",
    params  = {
        { name = "samples", type = "number", default = 2000000, help = "total samples" },
        { name = "chunk",   type = "number", default = 50000,   help = "samples per task" },
        { name = "seed",    type = "number", default = 12345,   help = "random seed" },
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
        -- Park–Miller：s = s * 16807 mod (2^31-1)，最大中间值约 3.6e13，安全
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
            -- map 给 n；两级汇总产出的部分结果给 samples（自相容，满足结合律）
            n = n + (r.n or r.samples or 0)
            inside = inside + (r.inside or 0)
        end
        local pi = (n > 0) and (4 * inside / n) or 0
        return { samples = n, inside = inside, pi = pi }
    end,

    format = function(res)
        return string.format("pi ~ %.6f (samples %d, inside %d, relative error %.4f%%)",
            res.pi, res.samples, res.inside,
            res.pi > 0 and math.abs(res.pi - math.pi) / math.pi * 100 or 0)
    end,
}
