--[[ dcnet 示例作业：矩阵乘法（按行分块，可对答案）

设计要点：矩阵**不通过消息传输**，而是由每个任务按同一个种子各自生成——
"确定性再生"换来的是消息极小（只传行区间和种子），代价是每台节点各算一遍生成。

    A、B 都是 n×n，元素由 LCG 生成到 [-1, 1]
    任务 i 负责 A 的第 from..to 行，算出 C 的对应行
    map 返回局部：元素和 / 迹的贡献 / 最大绝对值 / 元素个数
    reduce 只做累加（自相容，满足结合律，所以能走两级汇总）

自检：format 里给出的元素和与迹可以用别的方式独立算出来对照（测试里就是这么做的）。
]]

local function lcg(x)
    return (x * 1103515245 + 12345) % 2147483648
end

--- 按种子生成 n×n 矩阵，元素落在 [-1, 1]
local function matrix(n, seed)
    local m = {}
    local x = math.floor(seed) % 2147483648
    for i = 1, n do
        m[i] = {}
        for j = 1, n do
            x = lcg(x)
            m[i][j] = (x % 2001) / 1000 - 1
        end
    end
    return m
end

return {
    name    = "matmul",
    summary = "Matrix multiply (row blocks; matrices regenerated from seed per node, verifiable)",
    params  = {
        { name = "n",    type = "number", default = 48, help = "matrix order" },
        { name = "rows", type = "number", default = 6,  help = "rows per task" },
        { name = "seed", type = "number", default = 7,  help = "random seed (determines matrix)" },
    },

    split = function(a)
        local n = math.max(1, math.floor(a.n))
        local step = math.max(1, math.floor(a.rows))
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
        local A = matrix(task.n, task.seed)
        local B = matrix(task.n, task.seed + 1)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        local total = task.to - task.from + 1
        for i = task.from, task.to do
            for j = 1, task.n do
                local acc = 0
                for k = 1, task.n do
                    acc = acc + A[i][k] * B[k][j]
                end
                sum = sum + acc
                count = count + 1
                if j == i then trace = trace + acc end
                if math.abs(acc) > maxAbs then maxAbs = math.abs(acc) end
            end
            ctx.progress((i - task.from + 1) / total, string.format("row %d/%d", i, task.n))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { from = task.from, to = task.to, sum = sum, trace = trace,
            maxAbs = maxAbs, count = count }
    end,

    -- 只做累加：既吃 map 的结果，也吃自己产出的部分结果（两级汇总安全）
    reduce = function(results, a)
        local sum, trace, maxAbs, count = 0, 0, 0, 0
        for _, r in ipairs(results) do
            sum = sum + (r.sum or 0)
            trace = trace + (r.trace or 0)
            count = count + (r.count or 0)
            if (r.maxAbs or 0) > maxAbs then maxAbs = r.maxAbs end
        end
        return { n = math.floor(a.n), sum = sum, trace = trace, maxAbs = maxAbs, count = count }
    end,

    format = function(res)
        return string.format("%dx%d matrix product: element sum %.6f, trace %.6f, max abs %.4f (%d elements)",
            res.n, res.n, res.sum, res.trace, res.maxAbs, res.count)
    end,
}
