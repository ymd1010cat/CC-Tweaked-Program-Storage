--[[ dcnet 示例作业：N 体引力受力分析（有天然自检）

每个任务负责一部分天体，算出这些天体受到的全部两两引力之和：

    净外力  Σ F_i          按牛顿第三定律必须 ≈ 0（浮点残差量级 1e-10）
    Σ |F_ij|               力的总大小
    两两作用计数          每对天体被两个方向各算一次 → 应等于 n*(n-1)

所以这个作业不需要外部标准答案：**净外力≈0 就是自检**，测试里再独立算一遍总量对答案。

位置与质量由种子确定性再生（和 matmul 一样，消息里只传区间和种子）。
为了数字好看，这里取 G = 1（无量纲），质量 1~11，坐标 ±10，软化长度 eps 防除零。
]]

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
    summary = "N-body gravity: forces per body block (net force should be ~0, self-check)",
    params  = {
        { name = "bodies", type = "number", default = 64, help = "body count" },
        { name = "step",   type = "number", default = 8,  help = "bodies per task" },
        { name = "seed",   type = "number", default = 3,  help = "random seed (determines initial layout)" },
        { name = "eps",    type = "number", default = 0.5, help = "softening length to avoid divide-by-zero" },
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
            ctx.progress((i - task.from + 1) / total, string.format("body %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, fx = fx, fy = fy,
            sumAbs = sumAbs, pairs = pairs }
    end,

    -- 只做累加（自相容，两级汇总安全）
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
            "N-body: %d bodies, sum|F| = %.6f, net force = %.3e (should be ~0), pairwise terms %d (expected %d)",
            res.n, res.sumAbs, res.net, res.pairs, res.wantPairs)
    end,
}
