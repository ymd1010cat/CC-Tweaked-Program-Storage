-- dcnet 示例作业：大负载数据通道（B2 的演示与回归用）
--
-- 每个任务拿一大块"负载"（默认 24KB 的确定性伪随机文本），算一个简单校验和再返回。
-- 负载与结果都超过内联阈值（默认 8KB），所以会走文件通道：
--   * 负载：主控写进池子，节点收到名字后自己来取（payloadRef）
--   * 结果：节点先把数据推给主控，再发一条只带名字的结果（dataRef）
--
-- 参数：
--   tasks=6      任务数
--   size=24000   每个任务负载的字节数
--   res=12000    每个任务返回结果的字节数
return {
    name    = "bigdata",
    summary = "Big payload channel: payloads/results above the threshold switch to file transfer",
    params  = {
        { name = "tasks", type = "number", default = 6,     help = "task count" },
        { name = "size",  type = "number", default = 24000, help = "payload bytes per task" },
        { name = "res",   type = "number", default = 12000, help = "result bytes per task" },
        { name = "seed",  type = "number", default = 12345, help = "random seed (reproducible)" },
    },

    split = function(a)
        local tasks = {}
        for i = 1, math.max(1, math.floor(a.tasks)) do
            -- 负载本身是个大字符串，故意做得不好压缩
            local parts = {}
            local n = math.max(1, math.floor(a.size))
            local x = (math.floor(a.seed) + i * 7919) % 2147483647
            for _ = 1, math.ceil(n / 8) do       -- 每段 8 个十六进制字符
                x = (x * 16807) % 2147483647
                parts[#parts + 1] = string.format("%08x", x)
            end
            local blob = table.concat(parts):sub(1, n)
            tasks[i] = { i = i, blob = blob, res = math.max(1, math.floor(a.res)) }
        end
        return tasks
    end,

    map = function(task, ctx)
        -- 简单累加校验（只为了证明整块数据真的完整传过来了）
        local sum, x = 0, 0
        for idx = 1, #task.blob do
            local b = task.blob:byte(idx)
            x = (x * 31 + b) % 4294967296
            sum = sum + b
            if idx % 4096 == 0 then ctx.tick() end
        end
        local out = {}
        local y = x
        for i = 1, math.ceil(task.res / 8) do
            y = (y * 1103515245 + 12345) % 2147483648
            out[i] = string.format("%08x", y)
        end
        return {
            i = task.i, len = #task.blob, sum = sum, check = x,
            out = table.concat(out):sub(1, task.res),
        }
    end,

    reduce = function(results, a)
        local tasks, totalBytes, badLen = 0, 0, 0
        local checks = {}
        for _, r in ipairs(results) do
            tasks = tasks + 1
            totalBytes = totalBytes + (r.len or 0)
            checks[#checks + 1] = r.check or 0
            if #tostring(r.out or "") < 1 then badLen = badLen + 1 end
            if (r.len or 0) < 1 then badLen = badLen + 1 end
        end
        return { tasks = tasks, totalBytes = totalBytes, checks = checks, badLen = badLen,
            want = math.floor(a.tasks), wantSize = math.floor(a.size) }
    end,

    format = function(res)
        return string.format("Big payload channel: %d/%d tasks, total payload %s (about %s each), anomalies %d",
            res.tasks, res.want, tostring(res.totalBytes) .. " bytes",
            tostring(res.wantSize) .. " bytes", res.badLen)
    end,
}
