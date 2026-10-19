--[[ dcnet 内置作业：素数统计

用途：验证集群是否正常 + 一个可对答案的基准测试。
  π(1e6)  = 78498
  π(2e6)  = 148933
  π(1e7)  = 664579

参数：
  from=2          起点
  to=2000000      终点
  chunk=25000     每个任务负责的整数个数

注意 ctx.tick()：CC 会杀掉长时间不让出的程序，热循环里必须周期性调用。
]]

return {
    name    = "primes",
    summary = "统计 [from,to] 区间内的素数个数（可对答案的基准测试）",
    params  = {
        { name = "from",  type = "number", default = 2,       help = "起点（>=2）" },
        { name = "to",    type = "number", default = 2000000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,   help = "每个任务的整数个数" },
    },

    split = function(a)
        local tasks = {}
        local lo = math.max(2, math.floor(a.from))
        local hi = math.floor(a.to)
        local step = math.max(1, math.floor(a.chunk))
        while lo <= hi do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + step - 1, hi) }
            lo = lo + step
        end
        return tasks
    end,

    map = function(task, ctx)
        local function isPrime(n)
            if n < 2 then return false end
            if n % 2 == 0 then return n == 2 end
            if n % 3 == 0 then return n == 3 end
            local i = 5
            while i * i <= n do
                if n % i == 0 or n % (i + 2) == 0 then return false end
                i = i + 6
            end
            return true
        end

        local count, last = 0, nil
        local total = task.hi - task.lo + 1
        local k = 0
        for n = task.lo, task.hi do
            if isPrime(n) then
                count = count + 1
                last = n
            end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()                       -- 必须：让出执行权并上报心跳
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last }
    end,

    reduce = function(results, a)
        local total, largest, ranges = 0, nil, 0
        for _, r in ipairs(results) do
            -- map 给 count；两级汇总产出的部分结果给 primes（自相容，满足结合律）
            total = total + (r.count or r.primes or 0)
            ranges = ranges + 1
            if r.last and (not largest or r.last > largest) then largest = r.last end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest, ranges = ranges }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大素数 %s），由 %d 个任务汇总",
            res.from, res.to, res.primes, tostring(res.largest), res.ranges)
    end,
}
