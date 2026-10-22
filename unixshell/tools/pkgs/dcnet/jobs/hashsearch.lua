--[[ dcnet 内置作业：并行暴力搜索

在 [from,to] 里找最小的 n，使得 hash("dc"..n) 能被 modulus 整除。
这是"搜索类"作业的范例：每个任务扫描一段，找到就提前返回。

参数：
  from=1          起点
  to=4000000      终点
  chunk=25000     每个任务的扫描范围
  modulus=65536   目标整除因子（越大越难找）

预期命中密度 = 1/modulus。默认设置下大约会命中 60 次，reduce 取最小值。
把 modulus 设成 1048576 可以体会到"任务全部扫完才有答案"的情况。
]]

return {
    name    = "hashsearch",
    summary = "Parallel brute-force search (early-termination job demo)",
    params  = {
        { name = "from",    type = "number", default = 1,       help = "start" },
        { name = "to",      type = "number", default = 4000000, help = "end" },
        { name = "chunk",   type = "number", default = 25000,   help = "scan range per task" },
        { name = "modulus", type = "number", default = 65536,   help = "target divisor" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.floor(a.from)
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        local mod = math.max(2, math.floor(a.modulus))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi), mod = mod }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        -- 与 dc.util.hash 同源的 31 进制滚动哈希
        local function h(s)
            local x = 5381
            for i = 1, #s do
                x = (x * 33 + s:byte(i)) % 2147483647
            end
            return x
        end

        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            k = k + 1
            if h("dc" .. n) % task.mod == 0 then
                return { hit = n, scanned = k }
            end
            if k % 512 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { hit = nil, scanned = k }
    end,

    reduce = function(results, a)
        local best, scanned = nil, 0
        for _, r in ipairs(results) do
            scanned = scanned + (r.scanned or 0)
            if r.hit and (not best or r.hit < best) then best = r.hit end
        end
        return { hit = best, scanned = scanned, modulus = a.modulus }
    end,

    format = function(res)
        if res.hit then
            return string.format("min hit n = %d (hash(\"dc%d\") %% %d == 0), scanned %d values",
                res.hit, res.hit, res.modulus, res.scanned)
        end
        return string.format("[%d, %d] no hash divisible by %d found", 0, 0, res.modulus)
    end,
}
