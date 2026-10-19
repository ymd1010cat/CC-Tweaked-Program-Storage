# 作业（Job）开发指南

一个"作业"就是一个文件：`/dccomp/jobs/<名字>.lua`（**只存在于主控机上**）。
它是一段返回 table 的 Lua 代码，同时被两方使用：

- **主控**：运行 `split` 拆任务、`reduce` 汇总、`format` 显示。
- **节点**：拿到**源码文本**后在自己的沙箱里编译，运行 `map`。

所以：**节点不需要预装作业**，主控改一行代码，整网立刻生效。

---

## 1. 模板

```lua
return {
    name    = "myjob",              -- 必填，必须与文件名一致
    summary = "一句话说明",          -- 可选，jobs 列表里显示
    params  = {                     -- 可选，声明后自动解析 run 的参数
        { name = "to", type = "number", default = 100000, help = "上界" },
    },

    split = function(a)             -- 主控：拆任务
        local tasks = {}
        for lo = 1, a.to, 1000 do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + 999, a.to) }
        end
        return tasks
    end,

    map = function(task, ctx)       -- 节点：算一个任务
        local sum = 0
        for i = task.lo, task.hi do
            sum = sum + i
            if i % 256 == 0 then
                ctx.progress((i - task.lo) / (task.hi - task.lo))
                ctx.tick()          -- ★ 必须
            end
        end
        return { sum = sum }        -- 必须可序列化
    end,

    reduce = function(results, a)   -- 主控：汇总成功结果
        local total = 0
        for _, r in ipairs(results) do total = total + r.sum end
        return { total = total }
    end,

    format = function(res, a)       -- 主控：最终展示
        return "总和 = " .. res.total
    end,
}
```

四个函数里只有 `map` 和 `name` 是必须的：

| 函数 | 运行位置 | 缺省行为 |
| --- | --- | --- |
| `split(args)` | 主控 | 不写则整个参数表当成**一个**任务 |
| `map(task, ctx)` | 节点 | **必填** |
| `reduce(results, args)` | 主控 | 不写则返回结果数组 |
| `format(res, args)` | 主控 | 不写则 `textutils.serialize(res)` |

---

## 2. 参数

`params` 里每项：`{ name=, type="number"|"string"|"boolean", default=, help= }`。

解析规则（`util.parseArgs`）：

```
run myjob to=5000            -- 命名参数
run myjob 5000               -- 按声明顺序的位置参数
run myjob to=5000 extra=1    -- 未声明的参数会报错，防止打错字
```

缺少参数时用 `default`；类型转换失败会直接拒绝提交并在主控上提示。

---

## 3. ctx：节点侧上下文

| 成员 | 说明 |
| --- | --- |
| `ctx.payload` | 本任务的数据，即 `split` 返回数组里的那个元素 |
| `ctx.job` / `ctx.task` | 作业号 / 任务号（打日志用） |
| `ctx.worker` | 本节点电脑 ID |
| `ctx.progress(pct, note)` | 上报进度 `0..1`；内部节流到约 0.7 秒一次，放心高频调用 |
| `ctx.tick()` | **让出执行权 + 心跳 + 收取消指令**；内部按 50ms 节流 |
| `ctx.canceled()` | 主控是否已取消本任务 |
| `ctx.log(text)` | 在**节点**屏幕上打印一行（调试用，注意会刷屏） |
| `ctx.now()` | 墙钟毫秒（`os.epoch("utc")`） |
| `ctx.mono()` | 单调秒（`os.clock()`），测耗时用这个 |

---

## 4. 三条硬性规则

### 4.0 想让 `reduce` 也并行？它必须满足结合律

结果条数超过 `reduceThreshold`（默认 300）时，主控会把「把所有结果 reduce 成一个」
也拆成 K 个任务发给节点并行做（**两级汇总**），最后只对 K 个中间结果再做一次 reduce。

代价是对 `reduce` 有两条额外要求：

1. **结合律**：`reduce(a++b) == reduce(reduce(a) ++ reduce(b))`。求和、计数、取最大这类天然满足；
   「按行号拼成一整张图」这种就不满足。
2. **自相容**：`reduce` 必须既能吃 `map` 的结果，也能吃**自己产出的部分结果**。
   常见写法是两种字段名都认：

```lua
reduce = function(results, a)
    local total = 0
    for _, r in ipairs(results) do
        total = total + (r.count or r.primes or 0)   -- map 给 count，部分结果给 primes
    end
    return { from = a.from, to = a.to, primes = total }
end,
```

不满足就显式关掉：在作业里写 `twoLevel = false`（`mandelbrot`、`selftest` 就是这么做的）。
全局也可以 `set twoLevelReduce false`，或用 `set reduceThreshold 99999` 抬高标准。

### 4.1 热循环必须调用 `ctx.tick()`

CC:Tweaked 对"长时间不让出"的程序会直接抛错终止：

```
Too long without yielding
```

它的判定是**连续不让出的真实执行时长**：CC 给每个 Lua 虚拟机 7 秒预算
（`TimeoutState.TIMEOUT`，见 CC:Tweaked 源码），一次事件处理完会重新充满；
7 秒内不让出就抛 `Too long without yielding`，再拖 1.5 秒会硬中止并关掉电脑。

`ctx.tick()` 的实现是 `os.queueEvent("dc_yield") + os.pullEvent("dc_yield")`：
在 CC 内部这算"收到一个新事件"，**预算会被重置回 7 秒**，所以只要周期性调用就
永远不会撞上超时。经验值：每 256 ~ 4096 次内层迭代调一次，让两次调用之间的
真实耗时落在**几百毫秒以内**（素数判定这种重活 → 256 次；简单加法 → 4096 次）。

`ctx.tick()` 不只是让出，它还负责：

- 上报进度（让主控知道任务还活着，**避免被 90 秒超时重派**）；
- 处理 `cancel`（主控把任务重派给别人后，本节点要及时放弃，别白算）。

### 4.2 `map` 的返回值必须可序列化
允许：`number`、`string`、`boolean`、以及由它们组成的 `table`。
不允许：函数、协程、元表、userdata。

返回 `nil` 会被当作任务失败（会触发重试，重试到上限后该任务记为失败）。
想表达"没找到"，请返回 `{ hit = false }` 这类显式结构。

### 4.3 源码要自包含

作业源码被当作独立片段编译，**不能 `require` 其他文件**，也不要读写节点上的
文件、不要调用 `os.exit`/`shell.run` 等破坏性接口。需要的辅助函数就在文件里
用 `local function` 定义好（`primes` 作业里的 `isPrime` 就是范例）。

---

## 5. 任务粒度怎么定

| 粒度 | 结果 |
| --- | --- |
| 太细（每任务 < 50ms） | 网络往返还是一来一回两条消息，开销占比过高，集群加速比很差 |
| 合适（每任务 0.2s ~ 5s） | 负载均衡和开销都合适 |
| 太粗（每任务 > 60s） | 负载不均（快的节点闲着）、重算代价大；注意 `taskTimeout` 默认 90 秒 |

经验：让**任务数 ≥ 节点数 × 20**，这样抢任务式的负载均衡才平滑。

---

## 6. 调试技巧

### 6.1 先在主控上本地验证 split/reduce

作业文件本身就是普通 Lua 代码，可以在主控的 shell 里直接跑：

```lua
local def = dofile("/dccomp/jobs/myjob.lua")   -- 或 loadstring
local tasks = def.split({ to = 1000 })
print(#tasks, textutils.serialize(tasks[1]))
print(textutils.serialize(def.map(tasks[1], {
    progress = function() end, tick = function() end, canceled = function() return false end,
    log = print,
})))
print(def.format and def.format(def.reduce({ def.map(tasks[1], {
    progress=function() end, tick=function() end, canceled=function() return false end }) }, { to = 1000 }), { to = 1000 }))
```

这一段能立刻抓出 90% 的语法错误和逻辑错误，比排队等节点快得多。

### 6.2 用 `ctx.log` 看节点内部

```lua
ctx.log(("task %d: lo=%d hi=%d"):format(ctx.task, task.lo, task.hi))
```

节点屏幕上会多出一行；`ctx.log` 不要放在超高频循环里。

### 6.3 单机自测

一台电脑上可以同时跑主控和节点（CC 的 `bg` 后台运行 + rednet 回环）：

```
/dccomp/master.lua            -- 前台
# 按 Ctrl+T 不行，另开：先在主控里用 multishell
bg /dccomp/worker.lua
```

两者会共用同一块屏幕、互相刷屏，但协议流程（注册 → 派任务 → 回结果）是完整的，
适合快速验证作业能不能跑通。真正的性能测试还是要多台机器。

### 6.4 观察重派

主控加 `-v` 启动可以看到每一次派发/完成；任务失败时的原因会直接打在日志里：

```
/dccomp/master.lua -v
```

---

## 7. 参考实现

| 文件 | 演示的东西 |
| --- | --- |
| [src/jobs/selftest.lua](../src/jobs/selftest.lua) | 最小可用作业 + 已知答案校验 + 故障注入（照着改最省事） |
| [src/jobs/primes.lua](../src/jobs/primes.lua) | 最标准的数值型作业；任务结果可累加 |
| [src/jobs/pi.lua](../src/jobs/pi.lua) | 自己实现固定种子随机数，保证结果可复现 |
| [src/jobs/mandelbrot.lua](../src/jobs/mandelbrot.lua) | 结果不是数字而是**数据块**（按行号拼接） |
| [src/jobs/hashsearch.lua](../src/jobs/hashsearch.lua) | **提前终止**型搜索：找到就 `return`，其余任务照跑 |
