# 本地实测记录（RPV1 / CraftOS-PC 2.8.3，隔离数据目录）

> RPV1 = **R**ednet **P**rotocol **V**ersion **1**（本项目）；代码路径与协议串仍用历史前缀 `rpv`。
>
> **真机数据另见 [measurements-mc.md](measurements-mc.md)**（真 Minecraft + NeoForge 21.1.253 + CC:Tweaked 1.120.2：
> modem 单帧 128 KB、`os.sleep(0)`=50 ms、停等 RTT=1 tick、`lan/pmtu/bench` 全部 PASS）。
>
> 所有实验都在 `-d <workspace>\craftos-demo` / `craftos-cluster` / `craftos-probe` 的独立数据目录里跑，
> 使用模拟计算机 ID 20–30（未触碰 0–10）。

## 1. 能力探测（poc/probe/capability.lua）

| 项目 | 结果 |
| --- | --- |
| CraftOS-PC 版本 | v2.8.3（`os.version()` = "CraftOS 1.9"） |
| 可用可挂载外设（`periphemu.names()`） | monitor, computer, chest, debugger, debug_adapter, minecraft:chest, drive, printer, **modem**, energy, tank, speaker |
| API | rednet / parallel / settings / ccemux / bit32 / utf8 / table.pack / **string.pack** 均可用 |
| `periphemu.create("back","modem")` | true（可脚本挂载 modem） |
| `modem.isWireless()` | false（模拟器里是"有线式"modem，无距离衰减） |
| 同一台电脑跨 modem 收发 | 通过：back 发送，left/right 都收到（`distance=0`） |
| 频道门控 | 通过：关闭 left 的频道后 left 不再收到 |
| 打开 200 个频道 | 在第 129 个失败：`/rom/apis/peripheral.lua:257: Too many open channels`（与 global.json `maxOpenPorts: 128` 一致） |
| 进程内多台计算机 | `ccemux.openEmu(31)` 在 `--headless` 下可用，成功创建 computer 31 |

## 2. 载荷与时序（poc/probe/payload-timing.lua）

| 项目 | 结果 |
| --- | --- |
| 单帧载荷 1000 / 4096 / 8192 / 16384 / 32768 / 65536 / 131072 / 262144 字节 | 全部收发成功（CraftOS-PC 本地实现，无 Minecraft 网络层限制） |
| 表载荷（含 1000 字节字符串字段） | 成功 |
| 11 字段表头 `#textutils.serialize(hdr)` | **152 字节** |
| 等价二进制 IPv4 式头 | **20 字节** |
| 同机 200 次 loopback 收发 | 0.012 s → **60 µs/条**（模拟器，不代表 MC） |
| `os.sleep(0)` | 1 ms（模拟器调度粒度；MC 中是 1 tick = 50 ms） |
| 连续发 500 条 / 排空 500 条 | 发送 2 ms / 排空 77 ms |

## 3. Demo A：单机路由器 + 2 台主机（poc/run-demo.ps1）

```
   模拟机 31 主机A 10.0.1.2/24                      模拟机 32 主机B 10.0.2.2/24
        modem(back) ch=4001  mtu=256                     modem(back) ch=4002 mtu=256
              |                                                |
        ===== 链路A (频道 4001) =====                  ===== 链路B (频道 4002) =====
              |                                                |
        modem(back) 10.0.1.1/24 mtu=256          modem(left) 10.0.2.1/24 mtu=128
                        \______ 模拟机 21 路由器 ______/
```

结果（原始日志：[demo-node21.log](demo-node21.log)、[demo-node31.log](demo-node31.log)、[demo-node32.log](demo-node32.log)）：

| 测试 | 结果 |
| --- | --- |
| 跨网段 ICMP echo（A → 路由器 → B） | **4/4 收到应答**（seq 1/2/3 + ttl=2 的 seq 98）；RTT 52–76 ms（含首次 ARP 解析） |
| TTL 一跳语义 | `ttl2_ok=true`：ttl=2 的报文经 1 台路由器后仍可送达；`ttl=1` 被丢弃并回 ICMP time-exceeded |
| ARP | A 解析网关 10.0.1.1 → MAC 21；路由器解析 10.0.2.2 → MAC 32 |
| 分片 / 重组 | A 900 B 载荷按 MTU 256 → **4 片**；路由器重组 908 B；出口 MTU 128 → **再分 9 片**；B 重组后 UDP 校验和通过；A 收到回显应答并校验 `large_reply_ok=true` |
| 路由器统计 | `fwd=10 ttl_drop=1 no_route=0 arp_fail=0 bad=0 recv=14` |
| 结果判定 | `RESULTS ... complete=true`（等待"满足全部预期"而非固定墙钟预算） |

## 4. Demo B：多台电脑拼成一台路由器（poc/run-cluster.ps1）

```
   模拟机 31 主机A 10.0.1.2/24                         模拟机 32 主机B 10.0.2.2/24
        modem(back) ch=4001                                    modem(back) ch=4002
              |                                                       |
        == 网段A (频道 4001) ==                                 == 网段B (频道 4002) ==
              |                                                       |
   模拟机 41 线卡 10.0.1.1/24 mtu=256  <== fabric 频道 5000 ==>  模拟机 42 线卡 10.0.2.1/24 mtu=128
        （fabric 单播走成员 ID 频道：41/42，成员公告走频道 5000）
```

结果（原始日志：[cluster-node41.log](cluster-node41.log)、[cluster-node42.log](cluster-node42.log)、[cluster-node31.log](cluster-node31.log)、[cluster-node32.log](cluster-node32.log)）：

| 测试 | 结果 |
| --- | --- |
| 成员自动发现（无中心协调者） | 41 ↔ 42 互发 `FABRIC_ANNOUNCE`，各自 `peers=1`，远端路由自动生成 |
| 跨集群 ping | **4/4 应答**，`complete=true` |
| **TTL 一跳语义** | `ttl2_ok=true`：ttl=2 报文穿过两台成员组成的集群成功；41 入口把 ttl 减到 1 后交 fabric，42 原样发出（不再递减） |
| ttl=1 | 41 丢弃并回 ICMP time-exceeded（41 `ttl_drop=1`） |
| 跨集群分片 | A 侧 4 片(MTU 256) → 41 重组 908 B → fabric → 42 按 MTU 128 **再分 9 片** → 32 重组，UDP 校验和通过（`large_reply_ok=true`） |
| 成员统计 | 41：`fwd=5 fabric_fwd=5 fabric_recv=5`；42：`fwd=5 fabric_fwd=5 fabric_recv=5` |
| 延迟对比（CraftOS-PC，仅看比例） | 单机路由 RTT 52–76 ms → 集群 RTT 101–130 ms（多一次成员间转发） |
| 端到端总耗时 | 约 6.3 s |

## 5. Demo C：rednet 只做 WAN 接口（poc/run-wan.ps1，合并后的单一程序）

分支已合并进 [../node/startup.lua](../node/startup.lua)（`poc/rednet-bridge/` 已删除）。红内部署里 rednet **只**作为 WAN 接口出现。

拓扑：41/42 是两个站点的网关（LAN 各接一台主机，WAN 用 `linktype=rednet` 的接口）；
33 是 WAN 上的**纯 rednet 设备**（[../peer/legacy-rednet.lua](../peer/legacy-rednet.lua)，零 rpv 代码）。

| 步骤 | 结果 |
| --- | --- |
| 接口 | 41：`IFACE_WAN side=right name=WAN addr=172.16.0.1/24 mtu=256 link=rednet`、`WAN_MAP rednet_id=33 rpv_ip=172.16.0.9`、`WAN_REDNET_HOST protocol=rpv name=gw-a` |
| 站点互通 | 31(10.0.1.2) → 41 → **rednet WAN** → 42 → 32(10.0.2.2)：41 `WAN_SENT peer=42 dst=10.0.2.2 ttl=63 frames=1`；42 `WAN_RECV from=41 bytes=70` → `FWD … egress=local:LAN` |
| 两跳语义 | 41 减到 ttl=63、42 减到 ttl=62；`ttl_exceeded=2`、`ttl2_ok=false`（两个网关 = 两跳，正确） |
| WAN 分片 | 900 B UDP 载荷按 WAN MTU 256 → 4 帧（262/262/262/242）→ 42 `REASSEMBLED id=7 bytes=908` → 按 LAN MTU 转发；`large_reply_ok=true` |
| 纯 rednet 设备 | 41 `WAN_LEGACY_TX peer=33 to=172.16.0.9 sport=40001 dport=7 bytes=17` → 33 `LEGACY_RX from=41 src=10.0.1.2`、`LEGACY_REPLY dest=10.0.1.2 bytes=29` → 41 `WAN_LEGACY_RX to=10.0.1.2` → 31 `LEGACY_REPLY_RECV … legacy-echo:hello-legacy-peer`（`legacy_reply_ok=true`） |
| rednet DNS | 33：`LEGACY_LOOKUP protocol=rpv host=gw-a -> 41` |
| 广告/路由 | 双方 `WAN_ADVERT_SENT/RECV`，各学到 1 条 WAN 路由；41 收尾统计 `ROUTER_STATS fwd=11 ttl_drop=1 recv=15` + `WAN_STATS sent=8 recv=5 no_peer=0 legacy_tx=1 legacy_rx=1 peers=3 routes=1 mapped=1`；42 `ROUTER_STATS fwd=8 ttl_drop=1` + `WAN_STATS sent=5 recv=8 peers=2 routes=1` |
| 最终判定 | 31：`RESULTS pings_replied=3 ttl2_ok=false large_reply_bytes=900 large_reply_ok=true ttl_exceeded=2 legacy_reply_ok=true complete=true` |

原始日志：[wan-node41.log](wan-node41.log)、[wan-node42.log](wan-node42.log)、[wan-node31.log](wan-node31.log)、[wan-node33-legacy.log](wan-node33-legacy.log)。

> 注意：rednet 每帧都会**双发**（目标 ID 频道 + 65533 重复频道）且是洪泛语义，所以 WAN 只适合站点上行，不要承载 LAN 内部流量。

## 6. Demo D：链路类型 / 频道占用自检（poc/run-linktype.ps1）

单台模拟机 51，三个接口分别声明 wireless / ender / 保留频道 65535：

```
IFACE side=back ... linktype=wireless
LINKTYPE_WARN side=back declared=wireless reported=wired          <- 声明与实际不符
LINK side=left type=ender reported_wireless=false note=ender ...   <- 模拟器无法区分末影
CHANNEL_WARN side=right ch=65535 is reserved by rednet/GPS         <- 频道被 rednet 占用
```

说明：CraftOS-PC 的 modem 恒为 `isWireless()=false`，所以这里只能验证**自检逻辑**；
真实 Minecraft 里把 `linktype` 填对即可静默通过，并可用同一套日志确认无线/有线/末影的实际类型。
原始日志：[linktype-node51.log](linktype-node51.log)。

## 7. M2 稳健性实测（PMTU/DF、advert、fabric 分片、频道仲裁）

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| PMTU / DF | `poc/run-m2.ps1 -Scenario pmtu` | `verdict=PASS`：200 B UDP 带 `DF=1` 在 LAN-B（mtu 128）被路由器拒收 → `PMTU_NEEDED … mtu=128` + ICMP type 3 code 4 → 客户端 `PMTU_UPDATE dst=10.0.2.2 mtu=128` → 用 88 B 重发成功（`pmtu_ok=true`、`complete=true`） |
| advert 序列号/环路/默认路由 | `poc/run-m2.ps1 -Scenario advert` | `verdict=PASS`：伪造 `seq=5` 被接收，重复 `seq=5` → `WAN_ADVERT_STALE`，`seq=6 hops=9` → `WAN_ADVERT_LOOP`；对端（无静态网关）学到 `WAN_DEFAULT_ROUTE gw=21 via=172.16.0.1` |
| fabric 帧分片 | `poc/run-m2.ps1 -Scenario fabricfrag` | `verdict=PASS`：fabric MTU 128 下 908 B 载荷 → `FABRIC_FRAG_TX … parts=10` → 出口成员 `FABRIC_FRAG_RX … bytes=908 parts=10` → 本段再按 128 分片，`complete=true` |
| 频道命名空间仲裁 | `poc/run-m2.ps1 -Scenario channels` | `verdict=PASS`：`fabric_bcast=21`/`fabric_ucast=21` 撞 LAN 频道、fabric 与 rednet WAN 同侧 → 3 条 `CHANNEL_CONFLICT` + `CHANNEL_AUDIT conflicts=3` |

## 8. M3 应用层实测（新库 poc/rpv/*，模块化实现）

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| rednet 兼容 shim | `poc/run-m3-shim.ps1` | `verdict=PASS`：**未修改的 rednet 程序**在 10.0.1.2 ↔ 10.0.2.2 之间跨路由器工作 —— `rednet.lookup("chat","host-23") -> 23`、按计算机 ID 发送、收到 `pong from 23`、`rednet.broadcast` 被目录中继（`DIR_BCAST relayed=1`） |
| 遥测 | `poc/run-m3-apps.ps1 -Scenario mon` | `verdict=PASS`：`MON_RESULT nodes=2 ok=true`（两个 agent 跨路由器上报，每 5 s 汇总） |
| 文件传输 | `poc/run-m3-apps.ps1 -Scenario ftp` | `verdict=PASS`：4400 B / 18 个 256 B 块跨路由器，`FTPC_VERIFY sha_ok=true`，宿主侧逐字节比对 `identical=True` |

全量回归（CI 入口）：`pwsh -File poc\run-all.ps1` → **TOTAL=20 FAILED=0**（[runall-report.txt](runall-report.txt)）。

新库中修掉的库级 bug（都影响真实部署）：

- **多归属本地投递**：路由器收到"发给自身另一个接口 IP"的包曾按转发处理（遥测只收到一个节点就是这个原因）→ 现按"任意本地地址"判定本地投递。
- **ARP 首个请求被速率限制吞掉**：刚开机（在线 <0.5 s）时 `now - 0 < 0.5`，请求不发、包永久排队。
- **缺少周期性 housekeeping**：没有应用定时器时 ARP 重试/重组过期永不执行 → 新增 0.25 s tick。
- app 文件 `return function(...)` 被当 chunk 直接调用（函数返回后从未执行，既无日志也无报错）。
- ARP body 偏移差 10 字节（沿用了"整帧偏移"，而库已剥离 L2 头）。

## 8. M4 可运维实测（本地 CI、不接 GitHub）

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| routes.txt 热加载 | `poc/run-m4.ps1 -Scenario reload` | `verdict=PASS`：`ROUTES_RELOADED n=1 (boot)` → 宿主改写文件 → `ROUTES_RELOADED n=2 (file change)` |
| 指标面板 | `poc/run-m4.ps1 -Scenario panel` | `verdict=PASS`：`PANEL_DRAW nodes=2 target=term ok=true` + `PANEL_OK`（headless 无法创建 monitor，自动退回终端） |
| 启动看门狗 | `poc/run-m4.ps1 -Scenario watchdog` | `verdict=PASS`：首次启动 `BOOT_CRASH`（写 `crash.log`）→ `os.reboot()` → 第二次启动 `WATCHDOG_RECOVERED` |

**本地 CI**：`pwsh -File poc\ci.ps1` → 报告写到 `poc/out/ci-<时间戳>.txt`，退出码即结果（刻意不接 GitHub）。
全量回归：`poc/run-all.ps1` → **TOTAL=16 FAILED=0**（[runall-report.txt](runall-report.txt)），且全部运行日志中无
`TIMER_ERROR` / `APP_ERROR` / `FRAME_ERROR`。

## 9. 迁移说明（旧单文件已删除）

集群 fabric 与 rednet WAN 已迁入 `poc/rpv/fabric.lua` / `poc/rpv/wan.lua`，旧的 `poc/node/startup.lua` **已删除**；
LAN / cluster / WAN 三个 harness 现在全部跑在模块化库 + `poc/node2/startup.lua` 上（pass 标记统一为 `verdict=PASS`）。

## 11. 传输层（连接 + 拥塞控制）实测（**CraftOS-PC** 仿真）

`rpv/conn.lua`：三次握手 / 累积 ACK / `min(cwnd, rwnd)` 窗口 / AIMD / SRTT-RTTVAR RTO / 快速重传 / FIN。
用 `run-m3-apps.ps1 -Scenario ftp -FtpTransport conn` 验收（宿主侧逐字节比对）：

| 场景 | 结果 |
| --- | --- |
| 干净链路 | `verdict=PASS`、`identical=True`：用时 **0.81 s**，**cwnd 1 → 34**，`retx=0` |
| `-DropEvery 5`（每 5 个首发分段丢 1） | `verdict=PASS`、`identical=True`：用时 **18.7 s**，`retx=21`，cwnd 塌缩 1 / ssthresh 2，RTO 退避封顶 2 s |

> **真机（Minecraft）同场景数字见 [measurements-mc.md](measurements-mc.md) §2.8**：0.70 s / 18.3 s。

## 11.5 P5-c 大规模压测（控制面离线 100 节点 + 数据面网格）

**控制面 100 节点**（`tests/t_scale.lua`，离线纯 Lua，随 `run-offline.ps1` 一起跑）：

| 测试 | 数字 |
| --- | --- |
| 拓扑合并（10×10 网格的上报） | **100 节点 / 180 链路**，合并 **57 ms**，渲染 + 过期全部正确 |
| 距离矢量（10 簇×10 节点、簇首成环） | 直径 **7**，**8 轮收敛**（≈ 直径+1），逐节点跳数与最短路径**完全一致**，最大 metric 7，耗时 **35 ms** |
| 协议上限 | `INF=16` ⇒ 支持的网络直径 ≤ 15 跳（超出即不可达，这是设计取舍） |

**数据面网格**（`run-mesh.ps1`，3 台路由器三角网格 + 冗余路径，DV 收敛后）：

| 指标 | 数字 |
| --- | --- |
| 并发 conn 流 | **4 条**同时，各 1500 B，**4/4 逐字节到达**（6000 B） |
| 用时 / 聚合吞吐 | **1288 ms / 4658 B/s** |
| 重传 | **0** |
| 控制面在负载下 | 传输期间持续 ping，收到应答；3/3 路由器 DV 收敛（`learned=1 neighbors=2`） |
| 环路迹象 | 所有路由器 `ttl_drop=0` |

> 诚实说明：本机无法同时运行 100 个 CraftOS 实例，因此"100+ 电脑"的**算法层**结论来自上面的离线压测。

## 11.6 真机 WAN 介质（有线 / 无线）与 100+ 台仿真实测

**WAN 端口的介质支持**（用户要求"WAN 端口需要允许有线/无线 modem 接入"）：
库只要求外设类型为 `modem`（有线/无线/高级都满足），并把实测介质写进日志
（`WAN_READY ... phys_wireless=nil` 即有线 modem —— 有线 modem 没有 `isWireless()` 方法）。
新增配置 `wan_modem` / `modem_<side>`（仿真器建 modem 的型号）与 `wan_peer=<ip>:<id>`（静态邻居）。

| 验收（真机 Fabric，两台机**只有 WAN**、同网段，无 LAN 跳数干扰） | 结果 |
| --- | --- |
| `run-mc.ps1 -Scenario wanlink -WanLink wired` | **PASS**：`WAN_LINK=wired`（`phys_wireless=nil`）、4/4 ICMP、900 B UDP echo |
| `run-mc.ps1 -Scenario wanlink -WanLink wireless` | **PASS**：`WAN_LINK=wireless`、4/4 ICMP、900 B UDP echo |

> CraftOS-PC 的 `periphemu` **无法创建**有线 modem（`kind=wired_modem*` → `type=none`），
> 所以有线 WAN 只能在真机验收。

**100+ 台仿真实测**（用户批准 ID 100–300；`poc/run-scale.ps1`，12 逻辑核 / 32 GB / 实测 44 MB 每实例）：

| Stage | 规模 | 启动 | DV 收敛 | 跨节点 ping | 定时器滞后（平均 / 最差） |
| --- | --- | --- | --- | --- | --- |
| Z | 6（2×2 网格 + 2 主机） | 6/6 | 4/4 | **2/2（100%）** | 0 ms / 1 ms |
| Y | 11（3×3 + 2 主机） | 11/11 | 9/9 | 1/2（50%） | 11 ms / 65 ms |
| A | 22（4×4 + 6 主机） | 22/22 | 16/16 | **0–3/18** | 26–231 ms |
| B | 44（6×6 + 8 主机） | 44/44 | 36/36 | **0/40** | 345–503 ms |
| D | **110**（10 簇×10 路由器 + 10 主机，ID 100–209） | **110/110** | **99–100/100** | **0/72–0/90** | **3383–3854 ms** / 24–27 s |

**结论**：① 110 台**全部能启动**、**控制面 DV 基本全收敛**，但模拟器计时崩坏（滞后 3.4 s、最差 27 s）⇒
**100+ 台的数据面在本机不可用**（内存不是瓶颈，CPU 12 核才是）；② 22 台滞后仅 26–33 ms 时跨行 ping 仍几乎全灭 ⇒
这不是纯负载问题，而是**≥3 跳的网格路径的确定性转发问题**（见下）；③ 可用规模：小网格（6–11 台）100% 通。

**IPv4 保留网段语义**（`run-addr.ps1`：1 路由器 + 2 主机 + 1 台故意配公网地址的主机）：

| 检查 | 实测 |
| --- | --- |
| `ping 127.0.0.1`（环回） | 有应答，且 `tx_before=0 tx_after=0` —— **零 modem 发送**（`lo_sent=2`） |
| 环回 UDP 往返 | `got=loopback-udp no_tx=true` |
| 保留目的地（`0.0.0.1`/`169.254.1.1`/`240.0.0.1`/`224.0.0.9`） | `reserved_drops=4`（一个都没发出去） |
| 定向广播 `10.0.1.255` | 同段主机收到并回包，`bcast_replies=1`（0.2 s） |
| 分类与告警 | 路由器 `class=private private=true`；公网主机 `class=public` + `CFG_WARN ADDR_NOT_PRIVATE` + `ADDR_WARN_SUMMARY warnings=1` |
| 离线单测 | `tests/t_addr.lua`（分类矩阵 + 转发决策 + 定向广播 + 告警码） |

**≥3 跳网格转发问题：已定位并修复**（真协议 bug）。根因在 `poc/rpv/dv.lua` 的毒化反转分支：
只判断"毒化来自同一**接口**"就删本地路由，而共享网段上有多台路由器时（网格正是如此），
**非网关**邻居会把它从我这儿学到的那条路由毒化后广播回来 ⇒ 我把它当成"该路由失效"删掉 ⇒
下一周期再装回 ⇒ 路由反复抖动（实测 R(1,1) 到 `10.3.0.0/24` 抖动 20 次），流量恰好落在无路由窗口
（表现为 `NO_ROUTE_FWD`，而不是 TTL 丢弃）。修复＝把失效判定收紧到**毒化必须来自当前网关**
（`have.gw == src`），有限报文的刷新条件同样按网关；另加 `dv_jitter`（大拓扑 0.3–0.5）与逐包
`trace=1`（`IP_TX`/`IP_RX`）。修复后：

| Stage | 规模 | 修复前 | 修复后 |
| --- | --- | --- | --- |
| T | 3×3 + 3 主机（3 跳） | 2/6（33%） | **6/6 = 100% PASS** |
| Z | 2×2（6 台） | 2/2 | **2/2 PASS** |
| A | 4×4（22 台） | 0/18（0%） | **14–18/18 PASS**（滞后 24 ms） |
| B | 6×6（44 台） | 0/40（0%） | **28/40 = 70% PASS** |
| D | **110 台**（10 簇×10 路由器 + 10 主机） | 0/90（0%） | **42/90 = 46.7%**（滞后 338 ms，未达 50% 阈值） |

结论：**转发层已正确**（小中规模全绿）；110 台仍有约一半丢包，瓶颈是 12 逻辑核上的模拟器计时
（滞后 338 ms 且出现 8 s 尖峰），不是路由逻辑。`run-scale.ps1` 还内置了 `(channel, ip)` 唯一性自检：
注入重复地址会硬失败并列出冲突项（这类错误此前两次伪装成"协议 bug"）。

## 12. 已知小瑕疵（PoC 有意简化，非协议问题）

- ARP 等待期间到达的转发包会各自再发一次 ARP 请求（日志里 32 收到多次 ARP_REPLY）。
  生产实现应改为"邻居请求在途 + 待发包队列"，而不是在事件等待里递归处理。
- 定时任务在宿主负载高时会漂移（早期版本的固定 4 s 结果判定因此误判）；已改为"满足预期才结束"。
- CraftOS-PC 里所有 modem 共享同一介质，所以"网段"是靠**频道 = 逻辑网段**实现的；
  真实 Minecraft 中"有线 + 物理分离的 cable 网络"才能提供真正的物理隔离。
- fabric 帧目前不分片（PoC 把 fabric MTU 设为 1024 一次装下重组后的报文）。
- **已合并分支**：rednet 互通实现已并进 [../node/startup.lua](../node/startup.lua) 单一程序，`poc/rednet-bridge/` 已删除；
  rednet 只作为 `linktype=rednet` 的 WAN 接口存在（LAN 侧完全不调用 rednet）。
- **已修 bug**：配置解析原用 `%w+` 匹配键名，`rpv_host` / `start_delay` / `large_bytes`（以及当时存在的 `bridge_port`）
  等下划线键被静默忽略（所有参数走默认值）；已改为 `[%w_]+`，四个 demo 全部重跑通过。
- WAN 侧的已知简化：`advert` 没有序列号/版本号（仅 9 s 过期），WAN 帧按 WAN MTU 分片但不做 PMTU 探测；
  每个 WAN 帧 rednet 会双发（目标 ID 频道 + 65533 重复频道）。
