# 真机实测（RPV1 on Minecraft + CC:Tweaked，M4 实机基准）

> RPV1 = **R**ednet **P**rotocol **V**ersion **1**（本项目）；代码路径与协议串仍用历史前缀 `rpv`。

环境（全部在本工作区独立目录，未触碰任何整合包实例）：

| 项 | 值 |
| --- | --- |
| 服务端 | `mc-server\`（NeoForge 21.1.253 官方 installer `--installServer` 安装，自动拉 1.21.1 官方 server.jar） |
| 模组 | CC:Tweaked **1.120.2**（`cc-tweaked-1.21.1-forge-1.120.2.jar`，NeoForge 上可用） |
| Java | **Microsoft OpenJDK 25.0.3**（实测可跑；NeoForge 21.1 名义要求 21） |
| 世界 | 超平坦（bedrock+stone+grass）、`randomTickSpeed=0`、`doMobSpawning=false`、`doDaylightCycle=false` |
| 驱动方式 | RCON（`poc/mc/rcon.py`）+ `poc/mc/run-mc.ps1`，无玩家参与 |
| 拓扑 | 3 台电脑（1 路由器 + 2 主机），每台 `facing=north`，y=-60，无线或整块有线 modem |

## 1. 验收结果（真机）

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| LAN 无线 | `run-mc.ps1 -Scenario lan -Link wireless` | **PASS**：ARP / 3×ICMP echo / ttl=2 存活 / ttl=1 触发 time-exceeded / 900 B UDP 主机侧 4 分片 → 路由器重组 → 出口 MTU 128 再分 9 片 → 对端回显，`complete=true` |
| LAN 有线 | `run-mc.ps1 -Scenario lan -Link wired` | **PASS**：同上，`LINK side=… type=wired wireless=false` |
| PMTU / DF | `run-mc.ps1 -Scenario pmtu -Link wireless` | **PASS**：200 B 带 DF=1 → 路由器 `PMTU_NEEDED mtu=128` + ICMP 3/4 → 客户端 `PMTU_UPDATE mtu=128` → 88 B 重发成功（`pmtu_ok=true`） |
| 吞吐 / 往返基准 | `run-mc.ps1 -Scenario bench -Link wireless\|wired` | **PASS**（两种链路数字一致，见下） |
| 原始探测 | `run-mc.ps1 -Scenario probe -Link wireless` | 见下（帧长上限 / 时钟粒度） |

## 2. 关键实测数据（这些是 CraftOS-PC 给不了的）

| 指标 | CraftOS-PC（仿真） | **真机 MC（NeoForge 1.21.1）** |
| --- | --- | --- |
| `os.sleep(0)` | ≈1 ms | **50 ms（1 tick）** |
| 睡眠粒度 | 任意 | **量化到 tick**：0.05→0.050、0.2→0.200、1.0→1.000 |
| 邻居间 ICMP RTT | 1~2 ms | **0.000 s（同一 tick 内完成，亚 tick）** —— 所有电脑在同一个服务器 tick 上跑 |
| 停等（ACK）往返 | ≈1 ms | **恰好 1 tick = 50 ms / RTT**（接收方 `os.sleep(0)` 后回复；有线=无线） |
| 洪泛投递 | — | **200 × 140 B 一次性发出（span=0 tick），接收 200/200 无丢包** → ≥200 帧/tick、≈560 KB/s（tick 内） |
| modem 单帧上限 | ≥128 KB | **131,072 B 完整到达**（128 B→131 KB 全部无丢包；无线距离字段=6 格） |
| 无线/有线 | 频道区分 | 均可用；有线**必须**用整块 modem 链（见坑 1） |

对 rpv 的含义：

- **ACK/重传超时不能小于 50 ms**（真机最小抖动 = 1 tick）；我们现在的 0.5 s 重传、0.25 s tick 在真机上是 5~10 tick，合理。
- 停等 FTP 的 18 块 ≈ 18 × 50 ms ≈ **0.9 s / 4.4 KB**（仿真里看不出这个瓶颈）——真机要想快，就得开窗（slide window）而不是停等。
- 单跳路由器在真机上是 **0 tick**（同 tick 转发），所以"每跳延迟"不是瓶颈，**tick 边界**才是。
- 128 KB 单帧意味着分片大小可以放心用 MTU 决定，不需要担心 modem 自身限制。

## 3. 真机踩到的坑（都已修进 harness）

1. **`computercraft:cable` 用 `/fill` 放不成有线网络**：`getNamesRemote()` 为空、消息全丢；把电缆换成 **`computercraft:wired_modem_full` 链条**后立刻通（`GOT … msg=hello-22-1`）。有线链路要用整块 modem 做"电缆"。
2. **`wired_modem_full` 没有 `facing` 属性**（`setblock` 带 `[facing=…]` 会整条命令失败），无线 modem 才需要 `facing` 指向电脑。
3. **`/setblock` 的电脑不是真电脑**：块数据只有 `{On:0b}`、没有 `ComputerId`，CC 不会为它建 ServerComputer。必须：
   `/setblock <x> <y> <z> computercraft:computer_normal[facing=north]` →
   `/data merge block <x> <y> <z> {ComputerId:<id>,On:0b}` → `/computercraft turn-on <id>`。
4. **重启 = `/computercraft shutdown <id>` + `turn-on`**：中间可以把文件写进
   `mc-server/world/computercraft/computer/<id>/`，`startup.lua` 自动执行 ✓（这就是整套 harness 的基础）。
5. 侧面命名（电脑 `facing=north`）：+X 侧的 modem 在 Lua 里叫 **`left`**，-X 侧叫 **`right`**（用探针脚本实测）。

## 2.5 后续真机场景（全部 PASS）

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| 窗口化 FTP | `run-mc.ps1 -Scenario ftp -FtpWindow 1` vs `4` | 均 **PASS**（宿主侧逐字节 `identical=True`）：窗口=1 用时 **0.15–0.25 s**，窗口=4 用时 **0.05–0.10 s** → 真机 **2–3× 加速**（18 块 4.4 KB） |
| 集群（fabric） | `-Scenario cluster` | **PASS**：`FABRIC_FWD`/`FABRIC_RECV` 真机可用，客户端 `ttl2_ok=true`（集群=1 跳） |
| rednet 作 WAN | `-Scenario wan` | **PASS**：两个网关用真 rednet 互通（`WAN_SENT`/`WAN_RECV`），客户端 `complete=true` 且 `ttl2_ok=false`（两跳） |
| rednet 兼容 shim | `-Scenario shim` | **PASS**：**未修改的 rednet 程序**在真机跨路由器工作，目录 `DIR_BCAST relayed=1`，`LEGACY_RESULT lookup_ok=true reply_ok=true` |
| 3 路由器多跳 | `-Scenario multi` | **PASS**：`ttl=4` 探针跨 3 台路由器拿到回复（`ttl_custom_ok=true`），`ttl=2` 在中间路由器被丢（`TTL_DROP`，`ttl_exceeded=3`）；R2 用 `routes.txt` 学到两条静态路由 |

## 2.6 无线 modem 距离边界（实测）

同一世界内两台电脑各带一个无线 modem，同一频道原始收发 12 帧：

| 电脑间距 | 收到帧数（两端） | 报告的 distance |
| --- | --- | --- |
| 32 格 | 11 / 12 | 32 |
| 48 格 | 12 / 11 | 48 |
| **64 格** | **12 / 11** | **64** |
| **80 格** | **0 / 0** | —（完全收不到） |

结论：CC:Tweaked 默认无线距离 = **64 格（含 64）**，`modem_message` 的第 5 个参数就是真实方块距离。
对协议的含义：无线介质是"有物理半径的共享广播域"，跨站必须靠 WAN/有线，这正好印证了设计里
"无线只做局域网段、rednet 只做 WAN"的取舍。

## 2.7 真机 harness 的两个额外坑

- **远处区块必须强制加载**：`/forceload add <x1> <z1> <x2> <z2>` 的参数是**方块坐标**（不是区块）；
  没加载时 `/setblock` 会报 "That position is not loaded"，而**同一批 `/fill ... air` 也会整条失败** →
  上一场景的残留电脑/方块不会被清掉，会出现**重复 ComputerId**（本次排查"距离测试"异常就是这个原因）。
  harness 现在每次先 `forceload -48..400` 再整带清空。
- 每个场景结束后残留的电脑会被下一场景的 `turn-on` 一起点亮，所以**清场必须在放置之前完成**。

## 2.8 连接层（rpv/conn.lua：握手 + AIMD 拥塞控制，真机实测）

`ftp_transport=conn` 走连接层（三次握手、累积 ACK、`min(cwnd, rwnd)` 窗口、AIMD、SRTT/RTTVAR RTO、快速重传），
两端都用同一份 4400 B 文件，宿主侧逐字节比对：

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| 干净链路 | `run-mc.ps1 -Scenario ftp -FtpTransport conn -DropEvery 0` | **PASS**：`identical=True`，用时 **0.70 s**，末态 **cwnd=24**、SRTT≈0.038 s、RTO≈0.11 s、`retx=1`（一次快速重传） |
| 20% 丢包（每 5 个首发分段丢 1） | `-FtpTransport conn -DropEvery 5` | **PASS**：仍**逐字节一致**，用时 **18.3 s**，`retx=23`，cwnd 塌缩到 1 / ssthresh=2，**RTO 退避到 2 s 上限**，客户端 `dupacks=41` |

结论：AIMD + RTO 退避 + 快速重传在真机 tick 尺度下按预期工作（丢包降速、恢复后重传成功）；
`conn_rto_min` 默认 50 ms（1 tick）、`conn_rto_max` 2 s 是合适区间。
（同一套场景在 CraftOS-PC 上的数字见 [measurements.md](measurements.md) §11：0.81 s / 18.7 s——两边同量级，
因为瓶颈是重传逻辑而不是介质速度。）

## 2.9 多站点大地图（`sites`：无线 LAN + rednet WAN + 超无线半径的有线直连）

拓扑：**站点 A**（无线 LAN-A）—rednet WAN（无线）— **站点 B**（转接路由器）—**66 格有线直连**（超出 64 格无线半径）
— **站点 C**（无线 LAN-C）。5 台电脑、3 台路由器、4 个网段（10.0.1.0/24、172.16.0.0/24、172.17.0.0/24、10.0.3.0/24）。

| 判据 | 实测 |
| --- | --- |
| 端到端（主机 A → 主机 C） | **PASS**：`complete=true`、`pings_replied=4`、900 B UDP 跨站回声校验通过 |
| 跳数 | `probe_ttl=4` 往返成功（`ttl_custom_ok=true`）；`ttl=2` 在站点 B 到期、`ttl=1` 在网关 A 到期（`ttl_exceeded=2`） |
| WAN（rednet） | 网关 A `WAN_SENT peer=22`，B `WAN_RECV from=21` |
| 超半径那一跳 | B `FWD … out=local:LINK-BC` → C `FWD … out=local:LAN-C`（**靠有线 modem 链跨过 66 格**） |
| 静态路由 | A/B/C 各 `ROUTES_RELOADED n=1`（advert 单跳不重分发，边缘站点各配一条） |

这条场景正是设计取舍的实物证明：**无线只做局域网段，跨站用 rednet WAN 或（超半径时）有线**。

## 2.10 性能基线（spark + 假人读聊天；Fabric 服务器）

spark 的输出不经过命令源（RCON 收到空包、日志里也没有），所以用一个**假人**（mineflayer 协议客户端）
登录 Fabric 服务器、被 op，再执行 `/spark tps` / `/spark health`，把聊天里的标题+数值一并收下：

| 指标（`lan` 场景运行中，3 台电脑） | 实测 |
| --- | --- |
| TPS（5s/10s/1m/5m/15m） | **20.0 / 20.0 / 19.32 / 19.86 / 19.95** |
| 真实 tick 时长 MSPT（min/med/95%/max；10s 与 1m 两条窗口） | **0.4 / 0.4 / 0.9 / 2.7 ms** ； 0.1 / 0.5 / 1.0 / 8.6 ms |
| CPU（10s/1m/15m，系统） | **20% / 25% / 30%** |
| `/debug` 达成速率（对照） | 20.07 TPS（tick 周期 49.83 ms —— 这是**周期**不是 MSPT） |
| `Can't keep up!` 警告 | **0** |

结论：3 台电脑跑路由/分片/回显时，服务器中位 tick 只用 **0.4 ms**、95 分位 **0.9 ms**（预算 50 ms），
**余量极大** —— "路由器 pps 天花板"远高于当前规模，要压出瓶颈得开几十台电脑（路线图 §6）。

**跨加载器验证**：同一 `lan` 场景在 **Fabric 0.19.5 + CC:Tweaked 1.120.2(fabric)** 上同样 **PASS**
（ARP / ICMP / ttl / 900 B 重组+再分片 / 回显校验全过），说明协议栈不依赖 NeoForge 特有行为。

## 2.11 pps 天花板（负载扫描：逐 tick 加码，看达成/丢包/tick 时间）

工具：`poc/apps/mc-load.lua`（1 个计数器 + N 个发送方，每个发送方**每 tick 发 K 帧**）+ `poc/mc/load-sweep.ps1`
（扫 K 值，顺带用假人读 spark）。全部无线、12 秒窗口、Fabric 服务器。

### (a) 原始 modem flood（单接收方，8 发送方）

| K/发送方 | 提供 pkt/tick | 提供 fps | **到达 fps** | 到达 pkt/tick | 发送方自报 fps | **接收方 tick 中位/95%/最大 (ms)** | TPS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 32 | 640 | **452** | 24 | 640 | 0.5 / 1.3 / 4.5 | 20.0 |
| 16 | 128 | 2560 | **1807** | 96 | 2560 | 0.5 / 0.9 / 5.1 | 20.0 |
| 64 | 512 | 10240 | **2583** ← 峰值 | 517 | 6368 | 0.5 / 1.1 / 4.5 | 20.0 |
| 128 | 1024 | 20480 | **1989** ↓ | 735 | 2528 | 0.6 / 1.1 / 3.5 | 20.0 |

→ **单接收方无线通道在 ≈2.6k 帧/秒（≈130 帧/tick）饱和**；再加码（K=128）反而**吞吐下降**
（发送方自己被拖慢：自报 6368→2528 fps）。**服务器 tick 完全没被压到**（中位 0.5 ms、TPS 稳 20）。

### (b) 协议层 pps（8 发送方 → 路由器 21 → 计数器 22，真实 RPV1 UDP）

| K/发送方 | 提供 pkt/tick | 提供 fps | **到达 fps** | 到达 pkt/tick | 路由器 fwd | tick 中位/95%/最大 (ms) | TPS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 32 | 640 | **452（0 丢包：fwd=7680=640×12）** | 24 | 7680 | 0.5 / 1.3 / 2.8 | 20.0 |
| 16 | 128 | 2560 | **544** | 32 | — | 0.5 / 0.8 / 3.1 | 20.0 |
| 64 | 512 | 10240 | **546** | 30 | — | 0.6 / 1.3 / 2.8 | 20.0 |

→ **单路由器 ≈ 550–650 pps（≈30 包/tick）**，K=4 时 **零丢包**；K≥16 之后再加负载**只增加丢包**，吞吐不再涨。
→ 对比 (a)：同一介质上"原始帧"能到 2583 fps，而"协议包"只到 ~545 pps ⇒ **每个 rpv 包在 CC 运行时的成本 ≈ 4.7 个 modem 帧**
（ARP 查表 + IPv4 解析 + 校验和 + 转发 + 事件调度）。**瓶颈是每包 Lua/事件成本，不是服务器 tick**。

### 结论与后续

- **tick 层面余量极大**（中位 0.5 ms / 预算 50 ms，TPS 恒 20）→ 瓶颈在 **CC 运行时的每包成本**；
- 负载再高**不会拖垮服务器**，而是**丢包**（无背压的 flood 特性）——协议层若要保吞吐得靠连接层的
  拥塞控制（`conn.lua`）来限速，而不是无脑发；
- 下一步可做：① **多接收方/多路由器**看总 pps 是否随接收方线性扩展（判断是"每电脑成本"还是"介质"限制）；
  ② **有线链路**（排除无线竞争）；③ 调 `computercraft-server.toml` 的 `max_main_global_time`
  （默认 10 ms/tick）看天花板是否跟着变；④ 用 `conn` 的 AIMD 做"有背压"的吞吐对比。

## 2.12 扩展性 / 介质 / 预算 / 背压（路线图 §6 的四项后续，全部实测）

### (a) 多接收方扩展性 —— 天花板是"每接收方"，不是介质

同样 8 发送方 × K=16（提供 2560 帧/秒），只改接收方数量：

| 接收方数量 | 聚合到达 fps | 聚合 pkt/tick | 每接收方 |
| --- | --- | --- | --- |
| 1 | 1807 | 96 | 1807 |
| **3** | **5421** | 288 | 1807 **（完全一致）** |

3 个计数器的到达数正好是 1 个的 **3 倍（30720 → 92160）**⇒ 介质把每一帧都投递给了所有接收方，
**聚合吞吐随接收方线性扩展**；此前的 2.6k 上限是**单个接收方脚本/事件**的成本，不是广播介质。

### (b) 有线 vs 无线（点到点同负载）

| 介质 | K=16（提供 320 fps） | K=64（提供 1280 fps） | 送达 |
| --- | --- | --- | --- |
| 无线 | **226 fps** | **904 fps** | **100%（3840 / 15360 帧，与提供完全相等）** |
| 有线 | **226 fps** | **904 fps** | **100%** |

**两者数字完全相同**⇒ 在单发送方规模下**介质不是瓶颈**（发送方自身的脚本循环才是：单机上限 ≈900–1000 帧/秒）。
> 附带约束（CC 实现层）：`computercraft:wired_modem_full` **只连接水平邻居** —— 把它放在电脑的 +z/−z
> （front/back，实测 `Side-Name`：+x=left、−x=right、+z=front、−z=back）时电脑**看不到它**（`IFACE_NO_MODEM side=front`）。
> 所以"一条电缆总线 + 电脑不在线上"的拓扑在 CC 里做不到；有线对照只能做点到点/双 modem 链。

### (c) `max_main_global_time`（CC 每 tick 全局电脑预算，默认 10 ms）

| 场景 | 预算 10 ms | 预算 25 ms |
| --- | --- | --- |
| 无线 8 发送方 / 1 计数器 K=16 | 30720 帧 / 1807 fps | **30720 帧 / 1807 fps（完全一致）** |
| 无线 8 发送方 / 3 计数器 K=16 | 92160 帧 / 5421 fps | **92160 帧 / 5421 fps（完全一致）** |

**调预算毫无影响** ⇒ 这些负载下 CC 的 tick 预算**不是**约束；瓶颈在每包 Lua/事件成本本身
（也解释了为什么 TPS 一直稳在 20.0、tick 中位 0.5 ms）。

### (d) 背压（conn）vs flood

| 方式 | 送达 | 丢包 | 时间 | 等效速率 |
| --- | --- | --- | --- | --- |
| flood（8 发送方 ×K=16，提供 2560 fps） | 544 fps | **~70% 丢** | — | 544 pkt/s |
| **conn（1 条连接，20 kB）** | **20000/20000 字节** | **0** | 0.75 s | ~27 kB/s |
| **conn（1 条连接，200 kB）** | **200000/200000 字节** | **0** | **1.5 s** | **≈133 kB/s ≈ 950 pkt/s 等效** |

⇒ **有背压的连接层不仅零丢包，goodput 还高于 flood**（950 vs 544 pkt/s 等效）。

**真机发现的一个可调默认值**：200 kB 突发 + `conn_rto_min=0.05`（1 tick）时出现
**12 次虚假 RTO**（`CONN_RTO rto=0.100 cwnd=1 ssthresh=…` 反复塌缩）；把 `conn_rto_min` 提到
**0.2 s（4 tick）→ 0 次重传、耗时不变（1.5 s）**；0.5 s（10 tick）→ 0 次、1.6 s（略慢）。
⇒ **已把 `poc/rpv/conn.lua` 的默认值从 0.05 改为 0.2**，并复验：CraftOS-PC **22/22 PASS**
（含 `conn` / `conn-loss`）、真机 conn 干净（0.70 s 级）与 `-DropEvery 5`（20% 丢包）两场景均 **PASS、逐字节一致**。

复现：`run-mc.ps1 -Scenario load -Count 8 -Counters 3 -PerTick 16` ·
`-Scenario loadwired` · `-Scenario loadconn -LoadConnBytes 200000 -RtoMin 0.2`

## 2.13 长链路（10 跳）与跨维度（ender modem 只作网桥）

### (a) 长链路：hostA — R1 — … — R10 — hostB（每跳一个 /24，10 个路由器全静态路由）

`pwsh -File poc\mc\run-mc.ps1 -Scenario longchain -Count 10 -Target fabric -SparkText`

| 指标 | 实测 |
| --- | --- |
| 3 个 ICMP echo（跨 10 跳） | **RTT = 0 µs（同一 tick 内往返）**，4/4 全部应答 |
| 自定义 TTL 探测（ttl=11 → 到达时 ttl=1） | **收到应答**（`ttl_custom_ok=true`） |
| TTL=2 探测（第 2 跳必死） | `ttl2_ok=false`、`ttl_exceeded=2` ✓ 与 10 跳一致 |
| 2000 B 跨 10 跳传输 | **ok=true**（8.2 s 发出 → 9.2 s 收到） |
| 12 台电脑同时在线（10 路由 + 2 主机） | TPS **20.0**，tick 中位 **0.6 ms**、95 分位 **7.3 ms**、最大 **45.6 ms** |

→ **延迟不随跳数累积**：所有电脑在同一个服务端 tick 里推进，10 跳转发的往返仍然小到测不出（0 tick）。
代价只体现在 tick 时间上（95 分位 0.9 → 7.3 ms），**仍未触到 50 ms 预算**。

### (b) 跨维度：两个独立网桥把主世界/下界的两个网段连成"一个 LAN"

设计约束（按项目决定）：**无限距离/跨维度 modem 只当网桥**，且网桥是**独立程序**
（`poc/mc/ender-bridge.lua`：装成 `startup.lua`、自带 `bridge.txt`、不 import 任何 `rpv/*`；
`poc/rpv/*` 与 `poc/apps/*` 里 **0 处**提到 ender/advanced modem）。

拓扑：主世界 `hostA 10.0.9.2` — `bridgeA`（本地无线 modem + **ender modem**
= `computercraft:wireless_modem_advanced`）⇢ 下界(y=100) `bridgeB` — `hostB 10.0.9.3`；
两侧**同一子网、无网关**（网桥做 L2 透传，ARP 广播也过桥）。

| 指标 | 实测 |
| --- | --- |
| hostA → hostB 跨维度 ping | **4/4 应答**（`rtt_us=500000`，即一个 ping 超时窗口内到达） |
| 900 B 跨维度传输 | **ok=true**（`SELFTEST_LARGE_REPLY from=10.0.9.3`） |
| bridgeA 双向计数 | `lan_to_link=8 link_to_lan=5 dropped=0` |
| bridgeB 双向计数 | `lan_to_link=5 link_to_lan=8 dropped=0` |
| rpv 侧改动 | **零**（主机照常用 ARP/IPv4，不知道中间有网桥、更不知道跨了维度） |

### (c) ender modem 的距离能力（`wireless_modem_advanced`）

`-Scenario range -Distance 2000 -AdvancedModems`：两端相距 **2000 格**（普通无线 modem 的 64 格早已失效）
仍然双向收到全部帧（`RANGE_RESULT frames=11 / 12 max_distance=2000`）⇒ **实际无限距离**成立。

复现：`run-mc.ps1 -Scenario longchain -Count 10` · `-Scenario endbridge` · `-Scenario range -Distance 2000 -AdvancedModems`

## 4. 复现

```powershell
# 1) 启动服务器（独立目录，不碰任何整合包）
cd C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\mc-server
& "C:\Program Files\Microsoft\jdk-25.0.3.9-hotspot\bin\java.exe" -Xmx3G -Xms1G `
  "@libraries/net/neoforged/neoforge/21.1.253/win_args.txt" nogui

# 2) 跑场景（另开一个终端；harness 自己放方块、写文件系统、开机、读回日志）
pwsh -File ..\poc\mc\run-mc.ps1 -Scenario lan   -Link wireless
pwsh -File ..\poc\mc\run-mc.ps1 -Scenario lan   -Link wired
pwsh -File ..\poc\mc\run-mc.ps1 -Scenario pmtu
pwsh -File ..\poc\mc\run-mc.ps1 -Scenario bench -Link wired
pwsh -File ..\poc\mc\run-mc.ps1 -Scenario probe
```

日志落在 `poc/out/mc-<scenario>-<link>-*.log|txt`，服务器日志在 `mc-server/logs/latest.log`。
