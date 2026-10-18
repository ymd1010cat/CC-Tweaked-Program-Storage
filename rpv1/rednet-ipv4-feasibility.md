# 给 CC:Tweaked 加一个"类 IPv4"的 rednet 传输协议 —— 可行性分析

> 项目名：**RPV1**（**R**ednet **P**rotocol **V**ersion **1**）。代码里的目录/文件名、配置键和 rednet 协议串
> 仍沿用历史前缀 `rpv`（改名只落在名称层）。当前实现是模块库 [poc/rpv/](poc/rpv/) + 引导
> [poc/node2/startup.lua](poc/node2/startup.lua)（早期单文件 [poc/node/startup.lua](poc/node/startup.lua) 已删除）。

**结论：可行，而且不需要改动 CC:Tweaked 的 Java 代码**（纯用户态 Lua 协议栈即可）。
本机 CraftOS-PC 2.8.3（ROM 与 CC:Tweaked 同源）与真机 Minecraft（NeoForge 21.1.253 + CC:Tweaked 1.120.2）均已跑通：
1. 单机路由器 + 2 台主机、跨两个网段（跨网段 ping、900 字节报文跨段分片/重组、TTL 超时 ICMP —— 见 §6）；
2. **多台电脑拼成一台路由器**（2 台"线卡"计算机 + fabric 背板，TTL 语义上仍是一跳 —— 见 §7）；
3. **rednet 只做 WAN 接口**：两个站点的网关用 rednet 上行互通（WAN 上分片/重组），WAN 上的纯 rednet 设备也能被 LAN 主机访问（见 §8.2）；
4. 链路类型自检（有线/无线/末影 + 频道占用告警 —— 见 §8.1）。

> 最新进展见 [rpv-roadmap.md](rpv-roadmap.md) §11（M1–M4 + 连接层全部完成，CraftOS-PC 22 场景 / 真机 11 场景全绿）。

真正的难点不在"能不能做"，而在**性能模型**（每跳 ≥ 1 tick）和**介质语义**（CC 的 modem 是扁平广播域，无任何鉴权）。

- 代码：[poc/node/startup.lua](poc/node/startup.lua)（唯一实现：协议栈 + 集群 fabric + rednet WAN）；[poc/peer/legacy-rednet.lua](poc/peer/legacy-rednet.lua)（纯 rednet 对端）
- 一键复现：[poc/run-demo.ps1](poc/run-demo.ps1)、[poc/run-cluster.ps1](poc/run-cluster.ps1)、[poc/run-wan.ps1](poc/run-wan.ps1)、[poc/run-linktype.ps1](poc/run-linktype.ps1)
- 实测记录：[poc/out/measurements.md](poc/out/measurements.md)

---

## 1. 现状：rednet 到底给了什么（本地 ROM 实证）

本地 ROM：[rednet.lua](<C:/Program Files/CraftOS-PC/rom/apis/rednet.lua>)、[repeat.lua](<C:/Program Files/CraftOS-PC/rom/programs/rednet/repeat.lua>)、[gps.lua](<C:/Program Files/CraftOS-PC/rom/apis/gps.lua>)、[modems.txt](<C:/Program Files/CraftOS-PC/rom/help/modems.txt>)。

| 事实 | 出处 |
| --- | --- |
| 地址 = 计算机 ID，用 `id_as_channel(id) = id % 65500` 映射到频道；`MAX_ID_CHANNELS = 65500` | rednet.lua:59-69 |
| `CHANNEL_BROADCAST = 65535`，`CHANNEL_REPEAT = 65533` | rednet.lua:54-57 |
| `rednet.open` 只开两个频道：自己的 ID 频道 + 广播频道 | rednet.lua:92-99 |
| `rednet.send` 在每个已打开 modem 上**同时发两帧**：目标 ID 频道 + 重复频道 | rednet.lua:203-214 |
| 消息包装：`nMessageID / nRecipient / nSender / message / sProtocol`；收方用 9.5 s 去重窗口 + 31 位随机 ID 防重放自己 | rednet.lua:183-195, 468-477 |
| `rednet.lookup` 是**广播 + 2 秒超时**，无缓存 | rednet.lua:413-442 |
| `rednet.host` 注册前要先 `lookup` 查重（又一次广播往返） | rednet.lua:388-402 |
| `repeat` 程序把 CHANNEL_REPEAT 上的消息在**所有** modem 上全向转发，30 s 去重表 | repeat.lua:37-66 |
| GPS 占用 65534（`CHANNEL_GPS`） | gps.lua:36 |
| modem 只有 5 个方法：`open/isOpen/close/closeAll/transmit/isWireless`；事件是 `modem_message(name, channel, replyChannel, message, distance)` | modems.txt |

**结论：rednet = "ID 寻址 + 全网洪泛 + 去重"**。它没有 TTL、没有路由/子网、没有分片、没有确认与重传、没有端口、没有鉴权；每发一条消息在介质上是 2 帧 × N 个 repeat 节点的放大。这正是"类 IPv4 层"值得做的理由：**用可路由的层次结构换掉洪泛**。

> 注意：rednet 官方文档本身就声明"无安全性保证"——其他电脑可以窃听，也可以伪造发送方（rednet.lua:19-27）。

---

## 2. IPv4 概念 → CC 原语映射

| IPv4 概念 | CC 对应物 | 备注 |
| --- | --- | --- |
| 物理链路 / 以太网 | 一条 cable 网络（有线）或一个无线覆盖域，**再加一个频道号** | 有线：物理上分开的 cable 天然是不同广播域；无线：只能靠频道号做**逻辑**隔离 |
| MAC 地址 | 计算机 ID（`replyChannel` 直接给出对端 ID） | 32 位整数足够；PoC 用 4 字节大端 |
| L2 广播 | `transmit(link_channel, myID, frame)`，帧头 dstMAC=0xFFFFFFFF | 同频道所有 modem 都收到 |
| L2 单播 | 同上，dstMAC=目标 ID，收方在 Lua 里过滤 | 也可选"直接发到目标 ID 频道"（rednet 式，零过滤开销），代价是破坏网段语义 |
| 网段 / VLAN | **一个频道号**（有线时再叠加物理分离） | 频道 0–65535，别碰 65533/65534/65535 |
| 路由器 | 一台带 2–6 个 modem 的电脑 | 每面 1 个 modem → 最多 6 个接口 |
| ARP | 链路频道上广播请求帧，应答单播 | PoC 已实现 |
| TTL | 头部 1 字节，逐跳减 1 | 已实现 |
| 分片 / 重组 | 头部 flags(3) + fragOffset(13)，8 字节粒度 | **必需**，因为单帧大小受传输层限制 |
| ICMP | 协议号 1：echo / time-exceeded / unreachable | 已实现 |
| UDP | 协议号 17 + 伪头部校验和 | 已实现 |
| DHCP | 独立配置频道 + 服务器程序，或**由计算机 ID 直接推导地址** | 建议后者：零运维、无单点 |
| DNS | 复用 `rednet.host/lookup`，或自建 DNS 服务 | rednet 的 lookup 是广播 + 2 s 超时，不适合高频查询 |
| NAT / 防火墙 | 网关程序里做 | 可选 |
| WAN / 站点上行 | 一个 `linktype=rednet` 的接口 | **rednet 只在这一侧**：`rednet.open` 仅对 WAN modem，网关之间用 advert 学路由，纯 rednet 设备用 `map` 静态映射 |

---

## 3. 可行性分级

### ✅ 完全可行（PoC 已跑通，纯 Lua）
- 最长前缀匹配路由、默认网关、静态路由、TTL 递减
- ARP 式邻居发现、ARP 缓存
- ICMP echo / time-exceeded / destination-unreachable
- UDP 数据报 + 伪头部校验和
- 分片与重组（含"入口 MTU 256 → 出口 MTU 128"的再分片）
- 与 rednet 共存：频道空间天然隔离；可再写一个 rednet ↔ rpv 网关

### ⚠️ 可行但有明显取舍
- **可靠传输（TCP 式）**：可做（序号、ACK、窗口、重传），但定时器粒度、每跳 50 ms 起步、
  以及路由器吞吐限制，决定它更适合"轻量 RPC / 停等+小窗口"，而不是完整 TCP（拥塞控制、SACK 在 CC 尺度没意义）。
- **性能**：单跳延迟 ≥ 1 tick；路由器吞吐受服务器每 tick 的 Lua 执行预算与 modem 事件处理限制。
  估算为单机数十~数百 pps 量级，**必须在真实服务器上实测**（见 §8）。
- **安全**：modem 层无鉴权，源地址可随手伪造。要安全就必须自己做密钥交换 + HMAC/签名加密，
  而"网段"本身不提供任何隔离保证。
- **规模**：一台电脑最多 6 个 modem（6 个面）→ 6 个接口；要更多端口就把多台电脑拼成一台路由器
  （**集群模式，见 §7，本地已验证**），或在协议层做分层（核心/汇聚/接入）。

### ❌ 不建议 / 做不到
- **无限介质上的物理隔离**：无线 modem 同频道/同覆盖范围内所有电脑都能收到每一帧；
  频道只能挡住"没打开的监听者"，挡不住"故意打开偷听的机器"。
  真正隔离只能靠有线 + 物理分离的 cable 网络。
- **把 32 位 IP 直接映射成频道号**：频道只有 65536 个，而且**每个 modem 最多 128 个打开频道**
  （本地实测：第 129 个报 `Too many open channels`），路由表要留在 Lua 里而不是频道空间里。
- **为了"给 rednet 加路由"去改 Java 核心**：会破坏 rednet 语义（ID 寻址、洪泛重复、9.5 s 去重）、
  存档兼容和多人服务器预期，而且改不掉 tick 与无线介质这两个根本约束。用户态已经足够。

---

## 4. 硬约束（本地实测 + 需在游戏内复核的部分）

| # | 约束 | 来源 | 影响 | 对策 |
| --- | --- | --- | --- | --- |
| 1 | 每个 modem 最多 128 个打开频道 | 本地实测 `Too many open channels`（第 129 个失败）；global.json `maxOpenPorts: 128` | 不能"每个目的地一个频道" | 每条链路 1 个频道；路由器 6 个接口 = 6 个频道 |
| 2 | 频道 0–65535，其中 65533/65534/65535 已被 rednet/GPS 占用，0–65499 是 rednet ID 频道 | rednet.lua:54-69、gps.lua:36 | 频道冲突 | 新协议固定区间（如 1000–50000），PoC 用 4001/4002 |
| 3 | 单帧载荷大小：CraftOS-PC 本地实测 256 KB 字符串可传 | 本地实测（poc/out/measurements.md） | 不代表 Minecraft：真实上限由 Java 网络层决定 | **MTU 取 1–4 KB 并实现分片**，PoC 用 256 B，并演示出口 128 B 再分片 |
| 4 | 头部表示：11 字段表 `textutils.serialize` = 152 B，二进制 IPv4 式头 = 20 B | 本地实测 | 表头浪费带宽、不利于 MTU 计算 | 用二进制头；用 `string.char/byte` + 算术实现（不依赖 `bit32`/`string.pack`，Cobalt 与 CraftOS-PC 都能跑） |
| 5 | 每跳延迟 ≥ 1 tick（20 tps → 50 ms） | CC 计算机按 tick 处理事件 | 3 跳网络 RTT ≥ 150 ms；不适合实时控制 | 路由层级尽量扁平；把交互设计成请求-响应而不是高频流 |
| 6 | 路由器要同时收包/转发/服务应用 | 单线程事件循环 | 递归 pullEvent 容易丢包 | 生产实现用"待发包队列 + 邻居请求在途"（PoC 里是简化版，见 measurements.md 已知瑕疵） |
| 7 | 磁盘空间 `computerSpaceLimit = 1 MB`（本地配置） | [global.json](<C:/Users/ymd10/AppData/Roaming/CraftOS-PC/config/global.json>) | 重组缓冲/路由表要控规模 | 重组超时 10 s、限制并发重组数、路由表用前缀压缩 |
| 8 | `periphemu` / `attach` 只在 CraftOS-PC 存在 | [attach.lua](<C:/Program Files/CraftOS-PC/rom/programs/attach.lua>)、[attach.txt](<C:/Program Files/CraftOS-PC/rom/help/attach.txt>) | 模拟器里可以脚本挂 modem；真实 MC 中 modem 是物理方块 | 引导代码用 `if periphemu then ...` 包住，真实环境按侧面找 `/ peripheral.find("modem")` |
| 9 | 计算机 ID 会 `% 65500` 回绕，服务器也可分配大 ID | rednet.lua:59-69 | 不能把 ID 当稳定地址 | IP 与 ID 解耦：ID 只当 MAC；IP 由配置/DHCP/推导得到 |

---

## 5. 建议的协议设计（PoC 已验证的形状）

**L2 帧（10 B）**：`dstMAC(4) | srcMAC(4) | ethertype(2)`，ethertype `0x0806`=ARP、`0x0800`=IPv4 式。
用 `modem.transmit(link_channel, myID, frame)`，`replyChannel` 顺带把发送方 ID 带出去。

**L3 头（20 B，与 IPv4 逐字段对齐）**：
`ver/IHL | TOS | total_len(2) | id(2) | flags(3)+fragOff(13) | TTL | proto | hdr_cksum(2) | src(4) | dst(4)`

**上层**：ICMP（1）、UDP（17）；可靠层以后再加。

**地址规划建议**：
- `10.<区域>.<网段>.<主机>`：区域 = 维度/基地，网段 = 一个频道，主机 = 该段内的第 N 台。
- 或"零配置"：`10.<网段>.<ID % 250 + 1>`——不需要 DHCP 服务器，代价是不能自由分配。
- 保留 `255.255.255.255` 做本地广播；`0.0.0.0` 做"未配置"。

**频道规划建议**：
- 1000–50000：链路频道（网段 = 频道）
- 50001–65499：管理/配置/DHCP 频道
- 65533/65534/65535：**不要碰**，留给 rednet/GPS

**互操作**：网关电脑一边跑 rpv 接口、一边 `rednet.open`，把 `rednet_message` 与 rpv UDP/IP 双向转换；
rednet 名字解析可桥接 `rednet.host/lookup`，但建议自建带缓存的 DNS 服务，避免每次 2 s 广播。

---

## 6. 本次 PoC 实测结果（本地 CraftOS-PC）

拓扑：ID 21 = 路由器（back=链路A/ch4001/10.0.1.1，left=链路B/ch4002/10.0.2.1，MTU 256/128）；
ID 31 = 主机A 10.0.1.2（默认网关 10.0.1.1，测试发起方）；ID 32 = 主机B 10.0.2.2（回显服务）。
所有模拟计算机都在**隔离数据目录**里创建（ID 21/31/32），没有触碰 0–10。

| 测试项 | 结果 |
| --- | --- |
| 跨网段 ICMP echo（A→路由器→B） | **4/4 应答**（seq 1/2/3 + ttl=2 的 seq 98），RTT 52–76 ms（含首包 ARP） |
| TTL 一跳语义 | ttl=2 报文经 1 台路由器后仍送达（`ttl2_ok=true`）；ttl=1 被丢弃并回送 ICMP time-exceeded |
| ARP | A 解析网关 → MAC 21；路由器解析 10.0.2.2 → MAC 32 |
| 分片/重组 | A 的 900 B 载荷按 MTU 256 分 4 片 → 路由器重组 908 B → 出口 MTU 128 再分 9 片 → B 重组，UDP 校验和通过 |
| 大报文端到端校验 | A 收到回显应答 `bytes=900 ok=true` |
| 路由器统计 | `fwd=10 ttl_drop=1 no_route=0 arp_fail=0 bad=0 recv=14` |
| 结果判定 | `RESULTS ... complete=true`（等"满足全部预期"，不依赖固定墙钟预算） |

复现：`powershell -ExecutionPolicy Bypass -File poc\run-demo.ps1`（脚本会重建隔离数据目录并打印三台节点的日志）。

**诚实标注**：CraftOS-PC 的调度是 1 ms 级、且没有 Minecraft 的网络包大小限制，所以它只能证明
**协议逻辑与实现正确**，不能代表真实服务器的延迟/吞吐/单帧上限。这些必须在游戏内实测。

---

## 7. 把几台电脑拼成一台路由器（集群模式，本地已验证）

**能。** 用 4 台模拟机跑通：41 / 42 两台"线卡"计算机 + 31 / 32 两台主机。41 面向网段 A，42 面向网段 B，
两台通过一条 fabric 背板链路（频道 5000）拼成**一台逻辑路由器**。主机 A → 主机 B 的完整路径：

```
31 (10.0.1.2) --网段A/ch4001--> 41 --fabric/ch5000--> 42 --网段B/ch4002--> 32 (10.0.2.2)
```

### 设计（PoC 已实现）
| 机制 | 做法 |
| --- | --- |
| 背板（fabric） | 独立频道；**单播发到成员的 ID 频道**（`memberID % 65500`），只有目标成员的 modem 被唤醒，其他成员零过滤开销；公告用 fabric 广播频道 |
| 控制面（去中心化） | 每个成员启动时及之后每 2 s 广播 `FAB_ANNOUNCE`（自己的接口名 + CIDR）；各成员据此自动生成"远端路由"（前缀 → 归属成员 + 接口序号）。**不需要中心协调者** |
| 数据面 | 入口成员查到出口属于别的成员 → 发 `FAB_FORWARD{idx, ttl, proto, src, dst, payload}`；出口成员按**自己网段的 MTU** 做 ARP + 分片后原样发出（不改 TTL、不再查路由） |
| 一跳语义 | TTL 只在集群入口减 1 → **N 台电脑组成的集群 = 1 个路由跳**；实测 ttl=2 的报文能穿过集群，ttl=1 被丢弃并回 ICMP 超时 |
| 端口扩展 | 每个成员 6 面 → 1 面做 fabric，剩最多 5 个真实网段；k 台成员 ≈ 最多 5k 个网段，且转发能力按成员数叠加 |
| 冗余 | 同一个网段可以由两个成员各自接入（把一个成员当备份），路由表里改归属即可切换 |

### 实测结果（[poc/run-cluster.ps1](poc/run-cluster.ps1)，原始日志 [41](poc/out/cluster-node41.log) / [42](poc/out/cluster-node42.log) / [31](poc/out/cluster-node31.log) / [32](poc/out/cluster-node32.log)）

| 项目 | 结果 |
| --- | --- |
| 成员自动发现 | 41 ↔ 42 互发 `FABRIC_ANNOUNCE`，各自 `peers=1`，远端路由自动生成 |
| 跨集群 ping | **4/4 应答**（seq 1/2/3 + ttl=2 的 seq 98） |
| **TTL 一跳语义** | `ttl2_ok=true`：ttl=2 的报文穿过集群成功；41 日志显示入口把它减到 1 交给 fabric，42 原样发出 |
| ttl=1 | 在 41 被丢弃并回 ICMP time-exceeded（41 `ttl_drop=1`） |
| 跨集群分片 | A 侧 4 片（MTU 256）→ 41 重组 908 B → fabric → 42 按 MTU 128 再分 9 片 → 32 重组，UDP 校验和通过（`large_reply_ok=true`） |
| 成员统计 | 41：`fwd=5 fabric_fwd=5 fabric_recv=5 peers=1`；42：`fwd=5 fabric_fwd=5 fabric_recv=5 peers=1` |
| 端到端总耗时 | 约 6.3 s，`complete=true`（结果等待改为"满足预期即结束"，不再依赖固定墙钟预算） |

### 代价与边界（重要）
- **延迟**：逻辑上一跳，物理上多一次成员间传输。真实服务器里每个集群内部跳约 **+1 tick（50 ms）**：
  实测单机路由 RTT 52–76 ms，集群 RTT 101–130 ms（CraftOS-PC 数值不代表 MC 绝对值，但比例关系成立）。
- **背板带宽共享**：所有成员共用一条 fabric 频道。用 ID 频道单播能省掉无关成员的过滤开销，但介质本身仍是共享的；
  成员多时建议 fabric 走**有线 cable**（独占介质），或按成员对拆分频道。
- **fabric 帧暂不分片**：PoC 里 fabric MTU 设 1024 一次装下重组后的报文；生产实现要么把 fabric MTU 设得足够大，要么给 fabric 也加一套分片。
- **控制面还很朴素**：目前是"公告 + 6 s 过期"，没有序列号/版本号，成员重启会短暂撤路由；生产版应加序列号、路由版本、心跳与计数校验。
- **尚未实现**：跨成员的广播/多播（`FAB_BCAST`）、成员级冗余切换、集群内认证、fabric 拥塞控制。
- **拓扑限制**：单条 fabric 不会成环；如果做多 fabric，必须在入口加跳数上限/环路检测。

## 8. 合并后的单一程序：rednet 只做 WAN 接口（本地已验证）

分支已经**合并进主程序**：[poc/node/startup.lua](poc/node/startup.lua) 现在是唯一实现（`poc/rednet-bridge/` 已删除）。
**rednet 只出现在一个地方：WAN 接口。** 段内/基地内的链路仍走原始 modem 频道（rpv 自己的 L2），rednet 只做站点之间的上行（uplink）。

```
iface=back|LAN|10.0.1.1/24|4001|256|wired     # 普通网段接口（modem 频道）
iface=right|WAN|172.16.0.1/24|rednet|256      # WAN 接口：链路层是 rednet
advert=1                                      # 在 WAN 上通告自己的直连网段
rpv_host=gw-a                                 # 可选：注册进 rednet 的 DNS
map=33:172.16.0.9                             # WAN 上的纯 rednet 设备（静态映射）
```

| 机制 | 做法 |
| --- | --- |
| WAN 链路层 | WAN 接口没有频道号：发出的 L2 帧用 `rednet.send(<对端 rednet ID>, frame, "rpv")`；收到 `rednet_message`（protocol `rpv`）时把字符串帧交给**同一套** `handle_frame`。MAC 就是 rednet ID（= 计算机 ID） |
| 只开 WAN | `rednet.open()` 只在 WAN 接口那一侧调用 → rednet 的 ID 频道/广播频道只出现在 WAN modem 上，LAN modem 完全不参与 rednet |
| 路由学习 | 网关每 3 s `rednet.broadcast({sType="rpv-advert", gw=, ip=, nets={...}}, "rpv")` 通告直连网段；其他站点据此安装 `wan_routes`（9 s 过期），并从 `gw_ip → gw_id` 学到下一跳 |
| 数据面 | 命中 WAN 路由的包按 WAN MTU 分片，逐帧 `rednet.send`；对端重组后按自己 LAN 的 MTU 再转发 |
| 频道空间 | 不碰 65533（rednet 重复）/65534（GPS）/65535（rednet 广播），也不占用 0–65499（rednet 的 ID 频道区）；启动时逐接口告警 |
| 名字系统 | 网关用 `rednet.host("rpv", <name>)` 注册；旧程序 `rednet.lookup("rpv", <name>)` 能找到它（实测 → `41`） |
| 纯 rednet 设备 | `map=<rednet id>:<rpv ip>` 把它当 WAN 上的主机：网关把 UDP 数据报翻译成 `{sType="udp", from=, to=, sport=, dport=, data=}`，设备镜像回表，网关再翻回 UDP（回程源地址是网关地址，等价家用路由器的 SNAT） |

### 8.1 无线 / 有线 / 末影 modem 都能跑吗？

**能，三类都能跑。** 协议只用标准 modem 外设 API：`open / isOpen / close / transmit / isWireless` + `modem_message` 事件，
三类 modem 的差别只在**介质语义**，不在 API。程序把链路类型做成显式配置
（`iface=<side>|<name>|<cidr>|<channel>|<mtu>|<linktype>`，`linktype` ∈ `wired` / `wireless` / `ender`），
启动时用 `isWireless()` 自检并给出告警：

| 介质 | API 特性 | 网段隔离 | 适合 | 注意 |
| --- | --- | --- | --- | --- |
| 有线 wired | `isWireless()=false`；每条 cable 网络是独立广播域 | **真实物理隔离**（物理分开的 cable 就是不同网段） | 基地/机房主干、路由器之间的链路 | 要布线；同一条 cable 上所有电脑都能听到该 cable 的广播 |
| 无线 wireless | `isWireless()=true`；同频道、范围内的 modem 共享介质；`modem_message` 带 `distance` | 只有**逻辑隔离**（靠频道号） | 移动设备、跨楼、临时链路 | 范围有限、可被干扰；无隐私；频道要全网规划 |
| 末影 ender | 无线式，但无距离限制、可跨维度 | 无隔离（全服/跨维度一个大介质） | WAN 主干、跨维度连接 | **绝不要用末影当"内网"**；它与 rednet/GPS 同介质 |
| 混搭 | 一台电脑可同时插不同种类的 modem | 每个接口独立 | 家用路由器拓扑：有线=LAN，末影/无线=WAN | 每接口一个频道；接口数受 6 面限制 |

**本地验证的边界**：CraftOS-PC 的 `periphemu` 只提供一种 modem（`isWireless()` 恒为 `false`，且所有 modem 共享同一介质），
**无法模拟无线范围/干扰/独立 cable 网络**。所以：本地已验证 API 层兼容、链路类型自检、距离字段的采集路径；
**必须进游戏实测**无线范围与干扰对多跳的影响、独立 cable 网络的隔离效果、末影跨维度链路。

自检实测（[poc/out/linktype-node51.log](poc/out/linktype-node51.log)）：

```
LINKTYPE_WARN side=back declared=wireless reported=wired          <- 声明与实际不符会告警
LINK side=left type=ender reported_wireless=false note=...         <- 模拟器无法区分末影
CHANNEL_WARN side=right ch=65535 is reserved by rednet/GPS         <- 占用 rednet/GPS 频道会告警
```

### 8.2 WAN 实测（[poc/run-wan.ps1](poc/run-wan.ps1)，全部通过）

拓扑：41 / 42 是**两个站点的网关**（各自 LAN 上挂一台主机，WAN 用 rednet 接口），
33 是**WAN 上的纯 rednet 设备**（[poc/peer/legacy-rednet.lua](poc/peer/legacy-rednet.lua)，零 rpv 代码）。

| 步骤 | 结果 |
| --- | --- |
| 站点互通（LAN→WAN→LAN） | 31(10.0.1.2) → 41 → **rednet WAN** → 42 → 32(10.0.2.2)：`WAN_SENT peer=42 … frames=1` / `WAN_RECV from=41 …`，往返成功，`pings_replied=3` |
| 两跳语义 | TTL 在 41 减到 63、在 42 减到 62 → `ttl_exceeded=2`、`ttl2_ok=false`（两个网关就是两跳，符合预期） |
| WAN 分片 | 900 B 的 UDP 载荷按 WAN MTU 256 分成 4 帧（262/262/262/242）→ 42 重组 → 再按 LAN MTU 转发，`large_reply_ok=true` |
| 纯 rednet 设备 | 41：`WAN_LEGACY_TX peer=33 to=172.16.0.9 sport=40001 dport=7` → 33：`LEGACY_REPLY dest=10.0.1.2` → 41：`WAN_LEGACY_RX` → 31：`LEGACY_REPLY_RECV … legacy-echo:hello-legacy-peer`（`legacy_reply_ok=true`） |
| rednet DNS | 33 用 `rednet.lookup("rpv","gw-a") -> 41` 找到网关；41 日志 `WAN_REDNET_HOST protocol=rpv name=gw-a` |
| 广告与路由 | 双方 `WAN_ADVERT_SENT/RECV`，各学到 1 条 WAN 路由；41：`WAN_STATS sent=8 recv=5 peers=3 routes=1 mapped=1` |
| 最终判定 | `RESULTS … complete=true`（3 个 ping + 大报文 + 2 次 TTL 超时 + 旧设备回显全部符合预期） |

> 代价：每一帧 WAN 流量，rednet 都会**发两次**（目标 ID 频道 + 重复频道 65533），而且 rednet 本身是洪泛/去重语义 →
> WAN 只适合站点间上行，**不要拿它承载 LAN 内部流量**（这正是"rednet 只做 WAN 接口"的原因）。
>
> 顺带修掉一个真实 bug：角色配置解析原先用 `%w+` 匹配键名，导致 `start_delay`、`large_bytes`、`rpv_host` 这类
> 带下划线的键被**静默忽略**（所有参数走默认值）。已改为 `[%w_]+`，四个 demo 全部重跑通过。

## 9. 落地路线（建议分期）

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P1 | 协议库（帧/头/校验和）+ LPM 路由 + ARP + ICMP + 单跳转发 | 两台电脑 + 一台路由器跑通跨网段 ping（PoC 已完成） |
| P2 | 多跳、TTL 错误、ICMP unreachable、PMTU 探测、路由表落盘与 `route add/del/show` | 3 跳往返；断链时有明确 ICMP 错误 |
| P2.5 | **集群模式**：fabric 背板、成员公告、远端路由、FAB_FORWARD 一跳语义（PoC 已完成） | 2 台成员拼成 1 台路由器，ttl=2 报文可穿过集群 |
| P3 | UDP socket API（bind/sendto/recvfrom/reply）+ 端口复用 + 一两个示例应用 | 两个应用同时用不同端口互不干扰 |
| P4 | 可靠层（邻居请求队列化、窗口化重传、RTO 从 50 ms 起、乱序缓冲） | 丢包 20% 情况下文件传输仍完整 |
| P5 | 自动配置（ID 推导或 DHCP 服务）、DNS（自建/桥接 rednet）、**rednet 作为 WAN 接口**（已实现，见 §8） | 旧 rednet 程序与新协议互通 |
| P6 | 运维与分发：`routectl` 状态页、ping/traceroute、日志、打包成 ROM 资源包 / 安装脚本 | 一条命令部署到服务器 |

**分发方式三选一**：
1. 纯用户态：把库/程序放磁盘或 `pastebin`，玩家 `wget` 后运行（零改动，推荐起步）；
2. ROM 资源包：把 `rom/modules/main/rpv.lua` 与 `rom/programs/rpv/*` 打进资源包/模组（需要打包，不改 Java 逻辑）；
3. 改核心 Java：**不推荐**（见 §3）。

---

## 10. 必须在真实 Minecraft 里复核的项

1. **单帧上限**：modem payload 的最大字节数（Java 网络层限制），据此定 MTU。
2. **每跳真实延迟与吞吐**：在 20 tps 服务器上测 ping RTT 与路由器 pps（用 PoC 的计数器直接改造即可）。
3. **有线 vs 无线**：分别验证"频道隔离"与"物理隔离"的实际行为；无线是否会被范围/干扰影响多跳。
4. **多人服务器**：modem/rednet 是否受权限或反作弊限制；伪造源地址的可行性（安全设计前提）。
5. **末影 modem / 跨维度**：跨维度链路对 TTL 与路由的意义。
6. **服务器每 tick 的 Lua 预算**：决定路由器能带多少节点（server 配置项，需按实际服主配置实测）。

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 广播风暴 / 洪泛 | 全网络中继放大，卡服务器 | 不做全网广播；ARP/DNS 限制在链路内；限速 |
| 频道冲突 | 通信串台 | 固定频道分配表 + 启动自检 + 配置校验 |
| 路由器单点故障 | 整段失联 | 冗余网关、多路径、健康检查 |
| 消息伪造 / 窃听 | 数据被篡改或泄露 | HMAC + 密钥交换；敏感场景加密；不要依赖"网段"做安全 |
| 性能不足 | 卡顿、丢包 | 小 MTU、窗口化、批量、避免逐包 `textutils.serialize` |
| 依赖模拟器特性 | 换到真实 MC 就跑不起来 | 引导层隔离：所有 `periphemu` 相关代码用 `if periphemu then` 包住（PoC 已如此） |

---

## 附录：PoC 文件清单

| 文件 | 说明 |
| --- | --- |
| [poc/node/startup.lua](poc/node/startup.lua) | **唯一实现**：帧编解码、LPM 路由、ARP、ICMP、UDP、分片、链路类型自检、集群 fabric、**rednet WAN 接口**、场景脚本 |
| [poc/peer/legacy-rednet.lua](poc/peer/legacy-rednet.lua) | **纯 rednet** 设备（零 rpv 代码），跑在 WAN 上，证明互通 |
| [poc/run-demo.ps1](poc/run-demo.ps1) | 一键复现单机路由器三节点 demo |
| [poc/run-cluster.ps1](poc/run-cluster.ps1) | 一键复现**集群路由器**四节点 demo（41/42 线卡 + 31/32 主机） |
| [poc/run-wan.ps1](poc/run-wan.ps1) | 一键复现 **rednet WAN** 五节点 demo（41/42 网关 + 31/32 主机 + 33 纯 rednet 设备） |
| [poc/run-linktype.ps1](poc/run-linktype.ps1) | 链路类型 / 频道占用自检（有线·无线·末影 + 保留频道告警） |
| [poc/probe/capability.lua](poc/probe/capability.lua) | 能力探测：128 频道上限、跨 modem 收发、进程内多机 |
| [poc/probe/payload-timing.lua](poc/probe/payload-timing.lua) | 载荷大小、序列化开销、时序测量 |
| [poc/out/measurements.md](poc/out/measurements.md) | 全部实测数据汇总（LAN / 集群 / WAN / 自检） |
| [poc/out/demo-node21.log](poc/out/demo-node21.log) 等 | 单机路由器 demo 的原始日志 |
| [poc/out/cluster-node41.log](poc/out/cluster-node41.log) 等 | 集群 demo 的原始日志 |
| [poc/out/wan-node41.log](poc/out/wan-node41.log) 等 | rednet WAN demo 的原始日志（含 [33 纯 rednet 设备](poc/out/wan-node33-legacy.log)） |
| [poc/out/linktype-node51.log](poc/out/linktype-node51.log) | 链路类型 / 频道自检日志 |

> 复现方式：`powershell -ExecutionPolicy Bypass -File poc\run-demo.ps1` / `run-cluster.ps1` / `run-wan.ps1` / `run-linktype.ps1`
> （都在独立数据目录 `craftos-demo` / `craftos-cluster` / `craftos-wan` / `craftos-linktype` 里创建模拟机，不影响 0–10 号机）。
