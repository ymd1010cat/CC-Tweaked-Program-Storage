--[[ dcnet 示例作业：线性方程组 LU 分解求解（有残差自检）

算的是：A·x = b，其中 A 是 n×n 对角占优矩阵（对角加 n，保证免选主元也稳定），
B 是 n 个右端项（把右端项排成矩阵，每一列是一个独立的问题）。

并行方式：**分解部分各任务各做一次，求解按右端项切分**——每个任务解一部分列，
彼此完全独立。虽然分解被重复算了，但换来的是零同步开销（这也是 map/reduce 型
分布式计算里常见的取舍）。

自检：解完之后自己回代算残差 max|A·x − b|。数值上应该在 1e-12 量级，
所以这个作业**不需要外部标准答案**；测试里另外独立写一份 LU 对 Σx 做二次确认。

参数：
  n=24      矩阵阶数
  cols=4    每个任务解几个右端项（n/cols = 任务数）
  seed=11   随机种子（决定 A 与 b）
]]

local function makeA(n, seed)
    local A = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        A[i] = {}
        for j = 1, n do
            A[i][j] = (next() % 2001) / 1000 - 1
        end
        A[i][i] = A[i][i] + n          -- 对角占优
    end
    return A
end

local function makeB(n, seed)
    local B = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    -- 先跳过 makeA 用掉的 n*n 个数，保证两边序列一致
    for _ = 1, n * n do next() end
    for j = 1, n do
        B[j] = {}
        for i = 1, n do B[j][i] = (next() % 2001) / 1000 - 1 end
    end
    return B
end

--- 原地 LU 分解（不选主元：对角占优所以够稳）
local function luFactor(A, n)
    for k = 1, n - 1 do
        local akk = A[k][k]
        for i = k + 1, n do
            local f = A[i][k] / akk
            A[i][k] = f
            local Ai, Ak = A[i], A[k]
            for j = k + 1, n do
                Ai[j] = Ai[j] - f * Ak[j]
            end
        end
    end
end

--- 用已分解的 A 解一个右端项
local function luSolve(A, n, b)
    local y = {}
    for i = 1, n do
        local s = b[i]
        for j = 1, i - 1 do s = s - A[i][j] * y[j] end
        y[i] = s
    end
    local x = {}
    for i = n, 1, -1 do
        local s = y[i]
        for j = i + 1, n do s = s - A[i][j] * x[j] end
        x[i] = s / A[i][i]
    end
    return x
end

return {
    name    = "ludecomp",
    summary = "LU 分解解线性方程组（按右端项并行；残差 max|Ax-b| 自检）",
    params  = {
        { name = "n",    type = "number", default = 24, help = "矩阵阶数" },
        { name = "cols", type = "number", default = 4,  help = "每个任务解几个右端项" },
        { name = "seed", type = "number", default = 11, help = "随机种子" },
    },

    split = function(a)
        local n = math.max(2, math.floor(a.n))
        local step = math.max(1, math.floor(a.cols))
        local tasks = {}
        for from = 1, n, step do
            tasks[#tasks + 1] = {
                from = from, to = math.min(from + step - 1, n),
                n = n, seed = math.floor(a.seed),
            }
        end
        return tasks
    end,

    map = function(task, ctx)
        local n = task.n
        local A = makeA(n, task.seed)
        local B = makeB(n, task.seed)
        luFactor(A, n)

        local A0 = makeA(n, task.seed)          -- 原矩阵，用来算残差
        local maxRes, sumX, count = 0, 0, 0
        local total = task.to - task.from + 1
        for j = task.from, task.to do
            local b = B[j]
            local xv = luSolve(A, n, b)
            for i = 1, n do
                local s = 0
                for k = 1, n do s = s + A0[i][k] * xv[k] end
                local d = math.abs(s - b[i])
                if d > maxRes then maxRes = d end
                sumX = sumX + xv[i]
            end
            count = count + 1
            ctx.progress((j - task.from + 1) / total, string.format("右端项 %d/%d", j, task.to))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, maxRes = maxRes, sumX = sumX, count = count }
    end,

    -- 取最大残差 + 累加 Σx（自相容，两级汇总安全）
    reduce = function(results, a)
        local maxRes, sumX, count = 0, 0, 0
        for _, r in ipairs(results) do
            maxRes = math.max(maxRes, r.maxRes or 0)
            sumX = sumX + (r.sumX or 0)
            count = count + (r.count or 0)
        end
        return { n = math.floor(a.n), maxRes = maxRes, sumX = sumX, solved = count }
    end,

    format = function(res)
        return string.format("LU 求解：%d×%d，解了 %d 个右端项，残差 max|Ax-b| = %.3e（应≈0），Σx = %.6f",
            res.n, res.n, res.solved, res.maxRes, res.sumX)
    end,
}
