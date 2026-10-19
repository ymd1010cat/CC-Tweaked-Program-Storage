--[[ dcnet 示例作业：素数统计（支持云端卸载）

和内置的 primes 算的是同一件事，区别是它自带 **cloud** 定义：

  * 本机节点执行 map（唯一的区别是结果里标记 via="local"）
  * 主控也把同样的任务 POST 给已注册的 HTTP 计算服务（job.cloud.build/parse）
  * 云端不可达或超时 → 任务自动回到队列 → 本机节点接手（不需要写任何额外逻辑）
  * reduce 会统计有多少任务走了云端，输出里直接看得到

参数：
  from=2  to=200000  chunk=25000   同 primes

用法（先注册一个云端端点，参考 cloud/server.py）：
  cloud add local http://127.0.0.1:8080/dcnet 2
  cloud test local
  run cloudprimes to=200000
  set cloudFirst false      -- 改成"本机节点都忙时才用云端"
]]

return {
    name    = "cloudprimes",
    summary = "素数统计（有云端端点时优先卸载到云端，失败自动回落本机）",
    params  = {
        { name = "from",  type = "number", default = 2,      help = "起点（>=2）" },
        { name = "to",    type = "number", default = 200000, help = "终点" },
        { name = "chunk", type = "number", default = 25000,  help = "每个任务的整数个数" },
        { name = "pad",   type = "number", default = 0,      help = "给云端请求塞多少字节填充（测分块上传用）" },
    },

    -- 云端卸载：这两段在**主控**上运行，云端只需要会 HTTP + JSON
    cloud = {
        endpoint = "any",               -- 用哪个端点：端点名，或 "any"
        build = function(task, args)
            local req = { op = "primes", from = task.lo, to = task.hi }
            -- pad > 0 时故意把请求撑大，用来验证云端分块上传（服务器会忽略这个字段）
            local pad = tonumber(args and args.pad) or 0
            if pad > 0 then req.pad = string.rep("x", math.floor(pad)) end
            return req
        end,
        parse = function(resp, task, args)
            local d = (type(resp) == "table" and resp.data) or resp
            if type(d) ~= "table" or type(d.count) ~= "number" then
                return nil, "云端响应里没有 count 字段"
            end
            return { lo = task.lo, hi = task.hi, count = d.count, last = d.last, via = "cloud" }
        end,
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

    -- 本机节点走这里（云端不可达时的兜底）
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
        local total, k = task.hi - task.lo + 1, 0
        for n = task.lo, task.hi do
            if isPrime(n) then count = count + 1 last = n end
            k = k + 1
            if k % 256 == 0 then
                ctx.progress(k / total, string.format("%d/%d", k, total))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { lo = task.lo, hi = task.hi, count = count, last = last, via = "local" }
    end,

    -- 两级汇总要求 reduce 既能吃 map 的结果，也能吃自己产出的部分结果（自相容 + 结合律）
    reduce = function(results, a)
        local total, largest, cloud, local_ = 0, nil, 0, 0
        for _, r in ipairs(results) do
            total = total + (r.count or r.primes or 0)          -- map 给 count，部分结果给 primes
            if r.last and (not largest or r.last > largest) then largest = r.last end
            if r.cloud then cloud = cloud + r.cloud end          -- 部分结果里的计数
            if r.local_ then local_ = local_ + r.local_ end
            if r.via == "cloud" then cloud = cloud + 1           -- map 结果的来源标记
            elseif r.via == "local" then local_ = local_ + 1 end
        end
        return { from = a.from, to = a.to, primes = total, largest = largest,
            cloud = cloud, local_ = local_, tasks = cloud + local_ }
    end,

    format = function(res)
        return string.format("[%d, %d] 内素数个数 = %d（最大 %s）；%d 个任务，其中云端 %d / 本机 %d",
            res.from, res.to, res.primes, tostring(res.largest),
            res.tasks, res.cloud, res.local_)
    end,
}
