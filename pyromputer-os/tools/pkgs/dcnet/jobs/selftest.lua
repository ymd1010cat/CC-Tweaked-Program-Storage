--[[ dcnet 内置作业：集群自检

一趟跑完，验证整条分布式链路是不是真的通：

  * 任务下发 / 结果回收 / reduce 汇总   —— 24 个任务各自求平方和
  * 计算结果没有被算错或传坏           —— 与闭式解 n(n+1)(2n+1)/6 逐个比对
  * 任务一个不多一个不少               —— 检查任务号是否齐全、有没有重复
  * 容错路径                          —— fail=N 让前 N 个任务**故意报错**，
                                         看到主控日志里出现"N 次重试 → N 个失败"
                                         而作业仍然汇总成功，就说明重派逻辑正常

参数：
  tasks=24     任务数（想验证负载均衡就设成 节点数 x 10 以上）
  size=2000    每个任务求 1..size 的平方和（size 建议 <= 300000，避免浮点超精度）
  fail=0       故意让前 fail 个任务报错（验证重试与失败统计）

用法：
  run selftest                      正常自检，期望 PASS
  run selftest tasks=64 size=5000   加大批量
  run selftest fail=3               故障注入：期望 3 个任务最终失败、其余成功
]]

return {
    name    = "selftest",
    summary = "Cluster self-check: known answer + optional fault injection (validates dispatch/reduce/retry)",
    -- 这个作业的 reduce 会拿"预期任务总数"核对，不满足结合律，
    -- 所以明确拒绝两级汇总（两级汇总要求 reduce 只做累加类运算）。
    twoLevel = false,
    params  = {
        { name = "tasks", type = "number", default = 24,   help = "task count" },
        { name = "size",  type = "number", default = 2000, help = "terms per task" },
        { name = "fail",  type = "number", default = 0,    help = "deliberately failed tasks" },
    },

    split = function(a)
        local tasks = math.max(1, math.floor(a.tasks))
        local size  = math.max(1, math.floor(a.size))
        local fail  = math.max(0, math.floor(a.fail))
        local out = {}
        for i = 1, tasks do
            out[#out + 1] = { id = i, n = size, fail = i <= fail }
        end
        return out
    end,

    map = function(task, ctx)
        if task.fail then
            -- 故意报错：用来验证"报错 → 重试 → 记失败 → 作业仍能汇总"这条路径
            error("selftest deliberate failure (task " .. tostring(task.id) .. ")")
        end

        local sum = 0
        for i = 1, task.n do
            sum = sum + i * i
            if i % 256 == 0 then
                ctx.progress(i / task.n, string.format("%d/%d", i, task.n))
                ctx.tick()
                if ctx.canceled() then break end
            end
        end
        return { id = task.id, n = task.n, sum = sum }
    end,

    reduce = function(results, a)
        local tasks = math.max(1, math.floor(a.tasks))
        local fail  = math.max(0, math.floor(a.fail))
        local want  = tasks - fail

        local seen, bad, total = {}, {}, 0
        for _, r in ipairs(results) do
            if type(r) ~= "table" or type(r.id) ~= "number" then
                bad[#bad + 1] = "malformed result received"
            else
                if seen[r.id] then bad[#bad + 1] = "task " .. r.id .. " duplicated" end
                seen[r.id] = true
                -- 闭式解：1^2 + 2^2 + ... + n^2 = n(n+1)(2n+1)/6
                local expect = r.n * (r.n + 1) * (2 * r.n + 1) / 6
                if r.sum ~= expect then
                    bad[#bad + 1] = string.format("task %d check mismatch: %s != %s",
                        r.id, tostring(r.sum), tostring(expect))
                end
                total = total + r.sum
            end
        end

        local missing = {}
        for i = 1, tasks do
            if i > fail and not seen[i] then missing[#missing + 1] = i end
        end

        return {
            tasks = tasks, fail = fail, want = want, got = #results,
            bad = bad, missing = missing, total = total,
        }
    end,

    format = function(res)
        local pass = (#res.bad == 0) and (#res.missing == 0) and (res.got == res.want)
        local lines = {
            string.format("tasks %d: expected success %d, actual success %d; expected failures %d (check main log)",
                res.tasks, res.want, res.got, res.fail),
            string.format("Sum-of-squares closed-form check: %s", #res.bad == 0 and "all match" or (#res.bad .. " mismatches")),
            string.format("Task ids: %s", #res.missing == 0 and "complete, no duplicates"
                or ("missing " .. table.concat(res.missing, ","))),
            "Result: " .. (pass and "PASS - link OK" or "FAIL - see details above and main log"),
        }
        for i = 1, math.min(#res.bad, 4) do lines[#lines + 1] = "  " .. res.bad[i] end
        return table.concat(lines, "\n")
    end,
}
