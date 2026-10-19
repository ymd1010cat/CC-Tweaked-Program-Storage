# 云端卸载（把任务发给互联网上的计算服务）

dcnet 不只能用自己的电脑算：**任何会 HTTP + JSON 的服务**都可以当算力用。
云函数（Cloudflare Worker / Vercel / AWS Lambda function URL）、自己的小服务器、
NAS、甚至同一台机器上的脚本都行。

## 它是怎么接进调度器的

**云端端点 = 一种虚拟 worker**（在 `workers` 表里显示成 `cloud:<名字>`）：

```
         ┌──────────┐   POST /dcnet  {job,task,payload}   ┌──────────────┐
         │  主控    │ ──────────────────────────────────▶ │ HTTP 计算服务 │
         │ (master) │ ◀────────────────────────────────── │ (你的云函数)  │
         └────┬─────┘   {ok:true, data:{...}}             └──────────────┘
              │ 派任务 / 收结果（和真节点完全一样的记账流程）
         ┌────┴─────┐
         │ 本机节点  │  ← 云端慢/挂了，任务自动回到这里
         └──────────┘
```

所以这些是白拿的：

| 情况 | 行为 |
| --- | --- |
| 云端比本机慢 | 任务的 per-task 截止时间到了 → 重新入队 → 本机节点接手 |
| 云端进程挂了 / 端口不通 | `http.post` 立刻失败 → 端点进入**冷却退避**（10s 起，最多 5 分钟）→ 任务回落本机 |
| 云端返回 `{ok:false}` | 按任务失败处理（走正常的重试/失败统计） |
| 云端连续失败 | 冷却期内主控不再尝试该端点，本地集群照常干活 |

> 注意：**回落是自然发生的**，不需要在作业里写任何 try/catch。任务只有在
> `maxTries`（默认 3）次都失败后才会被记为失败。

## 前提：本机 http 可用

| 环境 | 默认 |
| --- | --- |
| 单人游戏 | `http_enable=true`，可直接访问互联网 |
| 服务器 | 管理员可能关掉 http（`http_enable=false`），或用 `http.rules` 限定域名——那就连不出去 |
| 内网/回环地址 | **较新版本的 CC:Tweaked 默认连内网也拦**（`host = "$private"` 规则），要连局域网里的服务得让管理员放行；CraftOS-PC 默认不拦（本项目的真机测试就是打 `127.0.0.1`） |

**推荐部署：放公网**（云函数 / VPS + 域名 + HTTPS）——不受内网拦截影响，只要服务器
`http.rules` 放行你的域名即可。若管理员把 HTTP 整个关掉，任何绕法都没用。


主控启动时会检查：不可用就打一行"云端卸载不可用：本机 http 不可用…"，其它功能不受影响。

## 快速上手（用自带的参考服务端）

在**一台能跑 Python 的机器**上（可以是同一台电脑，也可以是局域网里的服务器）：

```
python cloud/server.py                # 默认 0.0.0.0:8080
python cloud/server.py --port 9000 --quiet
```

它会打印出该填什么，例如：

```
dcnet-cloud/1.0 监听 http://127.0.0.1:8080/dcnet
ops: echo, hashsearch, pi, primes, sleep
在游戏里的主控输入：cloud add local http://127.0.0.1:8080/dcnet 2
```

然后在**主控**里：

```
cloud add local http://192.168.1.20:8080/dcnet 2      # 名字 并发数
cloud test local                                      # 探活（GET 一次）
workers                                               # 应该能看到 cloud:local
run cloudprimes to=200000                             # 这是个带云端定义的作业
```

结果里会写清楚有多少任务走了云端：

```
[2, 200000] 内素数个数 = 17984（最大 199999）；8 个任务，其中云端 6 / 本机 2
```

## 协议 v1

请求（`POST <你注册的 URL>`，`Content-Type: application/json`）：

```json
{
  "dcnet": 1,
  "job": "cloudprimes",
  "task": 7,
  "payload": { "op": "primes", "from": 150001, "to": 175000 },
  "args": { "from": 2, "to": 200000, "chunk": 25000 }
}
```

响应：

```json
{ "ok": true,  "data": { "count": 2113, "last": 174989 } }
{ "ok": false, "err": "op not supported" }
```

`cloud test` 会对你注册的 URL 发一次 **GET**，任何 JSON 响应都算成功
（参考服务端对所有 GET 路径都回服务描述）。

### 大请求：分块上传

HTTP 单次请求有大小上限（CC 的 `http_max_upload`，默认 4MB 量级），所以主控在请求体超过
`cloudChunk`（默认 64KB）时会**切成 N 块依次 POST**，最后一块带 `commit`：

```json
{ "dcnet": 1, "xid": "cl-3f9a…", "i": 1, "n": 4, "chunk": "<原始 JSON 的前 64KB 文本>" }
{ "dcnet": 1, "xid": "cl-3f9a…", "i": 4, "n": 4, "chunk": "<最后一段>", "commit": true }
```

服务端按 `xid` 攒块（300 秒没动静就清掉），收到 `commit` 后把各段拼起来、**解析成原来的
那份 JSON** 再照常执行——所以作业侧完全不用关心分块（`cloud.build` 照旧返回 table）。

- 中间块回 `{"ok":true,"partial":i,"n":n}`，**只有最后一块的响应才是任务结果**；
- 任何一块发失败 → 按云端不可达处理（冷却 + 任务回队 → 本机节点接手）；
- 参考服务端已经实现（`_handle_chunk` / `_run`）。

## 两种使用模式

```
set cloudFirst true     # 默认：有云端就优先往云端发（本地集群当兜底）
set cloudFirst false    # 溢出模式：本机还有空闲节点时先用本机，忙不过来才用云端
set cloud false         # 彻底关闭云端卸载
```

并发数在 `cloud add` 的第三个参数（每个端点独立，例如 2 表示同时最多 2 个请求在飞）。

## 写自己的服务

最小实现只要一个 POST 处理 + JSON 返回。参考 `cloud/server.py` 里的 `OPS` 表，
加一个函数就是加一种能力：

```python
def op_primes(payload, body):
    lo, hi = int(payload["from"]), int(payload["to"])
    ...
    return {"count": count, "last": last}     # 会变成 {ok:true, data:{...}}

OPS["primes"] = op_primes
```

想让云端干别的（比如调 GPU、调大模型 API、查数据库），就在 op 里做——
dcnet 不关心你返回什么，只要求是 JSON。

## 作业侧怎么写

作业里加一段 `cloud`，**build / parse 都在主控上跑**，云端不需要懂 dcnet：

```lua
cloud = {
    endpoint = "any",                    -- 端点名，或 "any"（谁都行）
    build = function(task, args)         -- 返回请求体（table 会自动转 JSON）
        return { op = "primes", from = task.lo, to = task.hi }
    end,
    parse = function(resp, task, args)   -- 把响应变成任务结果；返回 nil,err 表示失败
        local d = resp.data
        if type(d) ~= "table" then return nil, "响应缺少 data" end
        return { lo = task.lo, hi = task.hi, count = d.count, via = "cloud" }
    end,
},
map = function(task, ctx) ... end        -- 本地兜底（也可以不写，那就只能云端算）
```

关键点：**`map` 与 `cloud.parse` 应该返回同一种结构**，这样 `reduce` 不用关心
结果是从哪来的（`cloudprimes` 就是这么做的，只在里面多带一个 `via` 字段用于统计）。

## 安全与限制

- `payload` 会离开你的电脑：**不要把敏感数据放进任务参数**。
- 云端响应是**不可信输入**：`cloud.parse` 里要校验字段（作业里返回 `nil, err` 就会走重试）。
- 主控承担 HTTP I/O，云端并发受 `cloud add` 的槽位数限制；几十个并发在 CC 上不现实，
  一般 2~8 比较合适。
- 只有 `http` / `https`；请求体大小受 CC 的 `http_max_upload`（默认 4MB）限制，
  大负载请等 B2（大负载走文件通道）落地后再用。
- 端点在 `/dccomp/cloud.dat` 里持久化（含名称、URL、并发、累计成功/失败），重启后自动加载。
