--[[ dcnet 示例作业：TSP 暴力搜索（按"第二个城市"切分搜索空间）

经典的分支型作业：固定从 1 号城市出发，则任何一条回路的第一步必然是 1 → k（k 是别的城市）。
于是按 k 切分：**每个任务枚举"1 → k → …"的全部排列**——各任务之间不重不漏，正好覆盖
整棵搜索树。任务里还带剪枝（当前长度已经不小于本任务已知最优就直接回头），所以能快很多。

城市坐标由种子确定性再生（消息里只传城市数与种子）。
reduce 取各任务的最小值（min 满足结合律，也与自己产出的部分结果自相容 → 两级汇总安全）。

测试里对 6 个城市用独立写法枚举 5! = 120 条回路，和作业结果对答案。
]]

local function cities(n, seed)
    local list = {}
    local x = math.floor(seed) % 2147483648
    local function next()
        x = (x * 1103515245 + 12345) % 2147483648
        return x
    end
    for i = 1, n do
        list[i] = { x = (next() % 10001) / 1000, y = (next() % 10001) / 1000 }
    end
    return list
end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

return {
    name    = "tsp",
    summary = "旅行商暴力搜索（按第二个城市切分，可对最优解）",
    params  = {
        { name = "cities", type = "number", default = 9, help = "城市数量（9 → 8! 条回路，按第二城切成 8 份）" },
        { name = "seed",   type = "number", default = 5, help = "随机种子（决定城市坐标）" },
    },

    split = function(a)
        local n = math.max(3, math.floor(a.cities))
        local tasks = {}
        for k = 2, n do
            tasks[#tasks + 1] = { n = n, seed = math.floor(a.seed), second = k }
        end
        return tasks
    end,

    map = function(task, ctx)
        local pts = cities(task.n, task.seed)
        local others = {}
        for i = 2, task.n do
            if i ~= task.second then others[#others + 1] = i end
        end

        local bestLen, bestTour = math.huge, nil
        local path, steps = {}, 0

        local function walk(depth, curLen, prev)
            if curLen >= bestLen then return end              -- 剪枝
            if depth > #others then
                local total = curLen + dist(pts[prev], pts[1])
                if total < bestLen then
                    local tour = { 1, task.second }
                    for i = 1, #others do tour[#tour + 1] = path[i] end
                    bestLen, bestTour = total, tour
                end
                return
            end
            for i = depth, #others do
                others[i], others[depth] = others[depth], others[i]
                path[depth] = others[depth]
                walk(depth + 1, curLen + dist(pts[prev], pts[path[depth]]), path[depth])
                others[i], others[depth] = others[depth], others[i]
                steps = steps + 1
                if steps % 500 == 0 then
                    ctx.tick()
                    if ctx.canceled() then return end
                end
            end
        end

        walk(1, dist(pts[1], pts[task.second]), task.second)
        return { second = task.second, len = bestLen, tour = bestTour, steps = steps }
    end,

    -- 取最小（自相容、满足结合律）
    reduce = function(results, a)
        local bestLen, bestTour, steps, parts = math.huge, nil, 0, 0
        for _, r in ipairs(results) do
            steps = steps + (r.steps or 0)
            parts = parts + 1
            local len = r.len or r.bestLen
            if len and len < bestLen then
                bestLen = len
                bestTour = r.tour or r.bestTour
            end
        end
        return { n = math.floor(a.cities), len = bestLen, tour = bestTour,
            steps = steps, parts = parts }
    end,

    format = function(res)
        local tour = {}
        for i, c in ipairs(res.tour or {}) do tour[i] = tostring(c) end
        return string.format("TSP：%d 个城市，最短回路 %.4f，路线 %s→1（枚举 %d 次，%d 个分支任务）",
            res.n, res.len, table.concat(tour, "→"), res.steps, res.parts)
    end,
}
