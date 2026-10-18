# 真机（Minecraft）测试环境 —— RPV1 已就绪

> RPV1 = **R**ednet **P**rotocol **V**ersion **1**（本项目）；代码路径与协议串仍用历史前缀 `rpv`。
>
> 本目录的脚本可以在**独立的** NeoForge 服务器里跑 RPV1，全程无玩家参与。
> （你的整合包实例 `齿轮の松饼小镇\.minecraft` 从未被读写。）

## 两套服务器（同一套 harness，用 `-Target` 切换）

| target | 目录 | 游戏端口 | RCON | 加载器/模组 | 为什么两套 |
| --- | --- | --- | --- | --- | --- |
| `neoforge`（默认） | `mc-server\` | 25565 | 25575 | NeoForge 21.1.253 + CC:Tweaked 1.120.2（你的 spark 1.10.124） | 参考环境；`/debug` 的 TPS 可用，但 **spark 命令输出只在游戏内聊天里可见**，且 NeoForge **硬性拒绝原版协议客户端**，假人连不进来 |
| `fabric` | `mc-server-fabric\` | 25566 | 25576 | Fabric 0.19.5 + Fabric API 0.116.17 + CC:Tweaked 1.120.2(fabric) + spark 1.10.109(fabric) | **接受原版协议客户端** → **假人**能登录读到 spark 的 TPS/MSPT/CPU；同时是**跨加载器验证**（同一场景在 Fabric 上同样 PASS） |

```powershell
pwsh -File poc\mc\server.ps1 -Action start|stop|status                  # neoforge
pwsh -File poc\mc\server.ps1 -Action start|stop|status -Target fabric   # fabric
pwsh -File poc\mc\run-mc.ps1 -Scenario lan -Target fabric -SparkText    # 场景 + spark 读数
```

## 假人读 spark（`poc/mc/bot/read-chat.mjs`）

spark 把输出直接发给"观众"：**RCON 只收到一个空包、服务器日志里也没有**（已实测）。所以：

1. mineflayer（已装在 `poc/mc/bot/`）以离线模式登录 Fabric 服务器；
2. 假人一 spawn 就写 ready 文件 → harness 用 RCON 执行 `op rpvbot` → 写 start 文件放行；
3. 假人执行 `/spark tps`、`/spark health`，把标题与数值一起收下并输出结构化摘要；
4. 落盘 `poc/out/mc-<scenario>-<link>-spark.txt`：

```
tps=20.0, 20.0, 19.32, 19.86, 19.95
tick_ms=0.4/0.4/0.9/2.7;  0.1/0.5/1.0/8.6   ← 真实 MSPT(min/med/95%/max)，两条=10s/1m 窗口
cpu=20%, 25%, 30%  (system)
```

> `-TpsWindowSec N` 走 vanilla `/debug start|stop`（两套服务器都能用），但它只报**达成 tick 速率**
> （`tps=20.07`、`tick_period_ms=49.83`），**不是 MSPT**；真 MSPT/火焰图用假人 + `-SparkProfile`。
> `-SparkProfile` 生成的 `.sparkprofile`（`config\spark\`，已复制到 `poc/out/`）拖进
> https://spark.lucko.me/ 就能看每 tick 热点。

## 现状（已完成，可直接复跑）

| 项 | 值 |
| --- | --- |
| 服务端目录 | `rpv1\mc-server\`（NeoForge）/ `rpv1\mc-server-fabric\`（Fabric） |
| MC / 加载器 / 模组 | Minecraft **1.21.1** + NeoForge **21.1.253** + CC:Tweaked **1.120.2** |
| Java | `C:\Program Files\Microsoft\jdk-25.0.3.9-hotspot\bin\java.exe`（实测可用） |
| RCON | `127.0.0.1:25575`，密码 `rpvtest`（见 `mc-server\server.properties`） |
| 启动 | `mc-server\start-server.ps1`（见下） |
| 场景 | `poc\mc\run-mc.ps1 -Scenario lan|pmtu|bench|probe|wiredtest -Link wireless|wired` |

## 启动 / 停止

```powershell
# 启动（后台窗口）
pwsh -File poc\mc\server.ps1 -Action start
# 状态 / 停止（停止走 RCON 的 stop，干净退出）
pwsh -File poc\mc\server.ps1 -Action status
pwsh -File poc\mc\server.ps1 -Action stop
```

## harness 怎么工作（CC 真机要点）

1. `/setblock <x> <y> <z> computercraft:computer_normal[facing=north]`
2. `/data merge block <x> <y> <z> {ComputerId:<id>,On:0b}` —— 只有这一步才会让 CC 建出真电脑
3. 把 `startup.lua` / `role.txt` / `rpv/` / `apps/` 写进
   `mc-server\world\computercraft\computer\<id>\`
4. `/computercraft turn-on <id>` —— 开机即执行我们的 `startup.lua`
5. 跑完从同一目录读回 `rpv-log.txt`（程序每行 flush）判定 PASS/FAIL
6. 重跑：`/computercraft shutdown <id>` → 重写文件 → `turn-on` 清空重来

几何与命名（电脑 `facing=north`，y=-60, z=0）——**全部探针实测**：

- 侧面命名：**+X = `left`、−X = `right`、+Z(南) = `front`、−Z(北) = `back`**
  （`run-mc.ps1` 的 `Side-Name($dx,$dz)` 按此映射）
- 无线：`computercraft:wireless_modem_normal[facing=…]`，`facing` 指向电脑 —— 四个方向都能挂载
- 有线：`computercraft:wired_modem_full`（**没有 `facing` 属性**）；
  段间用 **`wired_modem_full` 链**连接 —— `/fill` 放的 `computercraft:cable` **不成网**（实测无消息）
- ⚠️ **`wired_modem_full` 只连水平邻居**：放在电脑的 +Z/−Z 侧时电脑看不到它（`IFACE_NO_MODEM side=front`），
  所以"一条横线电缆总线 + 电脑都挪出线外"的拓扑在 CC 里做不到；有线要用水平 modem + 把电缆填在两机之间
- ⚠️ **`setblock`/`data merge` 与 `computercraft turn-on` 不能放同一批 RCON**：同批里刚建出的电脑
  还没进注册表，`turn-on` 会报 `Turned on 0/0 computers`。必须分两批（中间隔 ≥1 tick；harness 已是这样）

## 场景

| 场景 | 拓扑 | 判据 |
| --- | --- | --- |
| `lan` | 路由器(10.0.1.1/10.0.2.1) + 主机 10.0.1.2（rpv-selftest）+ 10.0.2.2（udp-echo:7） | `complete=true` + `ttl2_ok=true` + `large_reply_ok=true` |
| `pmtu` | 同上，出口 MTU 128，客户端 `df_probe=1` | `pmtu_ok=true` + 路由器 `PMTU_NEEDED` |
| `ftp` | 两台直连，服务端 `ftp-server` + 客户端 `ftp-client`（`-FtpWindow N`） | 客户端 `sha_ok=true` + 宿主侧逐字节一致 |
| `cluster` | 21/22 集群成员（fabric）+ 主机 23/24 | 客户端 `complete=true` + `ttl2_ok=true` + `FABRIC_FWD/RECV` |
| `wan` | 21/22 两网关（真 rednet 作 WAN）+ 主机 23/24 | `WAN_SENT/RECV` + 客户端 `complete=true` + `ttl2_ok=false` |
| `shim` | 21 路由器+目录，22/23 跑**未修改的 rednet 程序**（`shim=1`） | `LEGACY_RESULT lookup_ok=true reply_ok=true` + `DIR_BCAST` |
| `multi` | 3 台路由器（S1–S4，R2 用 `routes.txt`）+ 两端主机 | `ttl=4` 跨 3 跳成功、`ttl=2` 中途丢弃（`TTL_DROP`） |
| `range` | 两台相距 `-Distance N` 格，原始无线收发 12 帧 | 两端 `RANGE_DONE`；实测边界 **64 格可通、80 格零帧** |
| `load` | `-Counters M` 个计数器 + `-Count N` 发送方，每方每 tick `-PerTick K` 帧原始 flood（`-Link wired` 时 modem 移到 z=+1 电缆排） | `LOAD_RESULT`（聚合达成 fps）+ spark 真 MSPT |
| `loadwired` | 点到点有线：两机 modem 在水平两侧、电缆填中间空隙 | 有线/无线介质对照 |
| `loadconn` | 1 条**连接**（conn.lua：握手/窗口/AIMD）stream `-LoadConnBytes` 字节（`-RtoMin` 可调） | 零丢包 goodput、RTO 调参对照 |
| `ftp -FtpTransport conn -ConnSecure psk\|wrongpsk` | 控制面 AEAD：握手认证 + 每方向会话键 + 逐段 encrypt-then-MAC | `CONN_SEC_KEYS` 与 `CONN_STATS ... secure=true sec_auth_fail=0`；wrongpsk 时零传输 + `CONN_SEC_SYN_REJECT` |
| `loadrpv` | 同上但发**真实 RPV1 UDP** 经路由器（路由器 fwd 计数） | `LOAD_RESULT` + 路由器 `FWD `；协议层 pps |
| `wanlink` | 两台机器只配 WAN（同网段 172.16.0.0/24），直接在 WAN 上做 ICMP + 900 B UDP echo；`-WanLink wired|wireless` 选 modem 型号。判据 `verdict=PASS` 且 `WAN_LINK=wired|wireless` 与所选一致 |
| (PC-only) `p2c` / `qos` / `p3` / `offline` / `hotreload` / `topo` / `stp-*` / `mesh` | P2-c NAT+组播域、P2-d QoS：仅有 CraftOS-PC harness（`poc/run-p2c.ps1`、`poc/run-qos.ps1`），未做真机场景 | 对应 run-all 作业 `p2c-nat`/`p2c-mcast`/`qos` |
| `dv` | 动态路由（距离矢量）环形拓扑：21/22/23 三台路由器**零静态路由**，24/25 两端主机 | `DV_INSTALLS>0` + 主机 `complete=true` + 最短路径 `metric=1` + `ttl_drop=0` |
| `svc` | DHCP-lite + lookup-lite：21 = 路由器兼 DHCP/DNS 服务器，22 只有占位地址（领租约→改地址→注册名字→解析 host23→跨路由 ping），23 = LAN-B 上的 host23 | `SVC_BOUND/LOOKUP/PING/LEASE/DNS_REGS` 全 True |
| `longchain` | `-Count N` 个路由器串成链 + 两端主机，全静态路由 | 跨 N 跳的 `SELFTEST_PING_REPLY rtt_us` / 大包传输 / 路由器 FWD |
| `endbridge` | **跨维度网桥**：主世界 ⇄ 下界各一台独立网桥（ender modem 只作桥），两侧同子网无网关；桥带 PSK 认证 | 主机 `complete=true` + 两侧网桥双向计数 |
| `endbridgesec` | 同上 + **攻击者 #25** 在链路频道上伪造/HELLO/重放/超大帧 | 主机 `complete=true`（合法流量不受影响）+ 桥 `auth=psk paired=true unauth>0 replay>0` + 攻击者 `ATTACK_RESULT` |
| `range -Distance N -AdvancedModems` | 用 ender modem（`wireless_modem_advanced`）测距离/跨维度能力 | `RANGE_RESULT frames/ max_distance` |
| `lib` | **库验收**：两台普通电脑把 `poc/examples/` 的程序**装成 `startup.lua`** 直接跑（`require("rpv")` + 配置表，无 role.txt/bootstrap） | 主机 `LIBTEST_RESULT pass=true` |
| `bench` | 两台直连，原始 modem 洪泛 + 停等往返 | 两侧 `BENCH_*` 记录（帧/tick、ticks per RTT） |
| `probe` | 两台直连，测 `os.sleep` 粒度 + modem 单帧上限 | `mc-probe.txt` |
| `wiredtest` | 两台直连，最小原始收发诊断（`getNamesRemote` + 通道 6200） | `mc-wired.txt` 里有 `GOT` |

### 跨维度 / ender modem 的硬约束（实测）

- CC:Tweaked **没有** `computercraft:ender_modem` 这个方块；跨维度 + 无限距离的是
  **`computercraft:wireless_modem_advanced`（Ender Modem）**（`wireless_modem_normal` 上限 64 格）
- 非主世界要 `execute in minecraft:<dim> run <setblock|data merge|fill|forceload>`；
  `computercraft turn-on <id>` **不需要**维度前缀（按 id 全局）；电脑文件系统也跨维度共用
- 下界可用高度从 y=0 起（y=-60 无效）：本 harness 在下界用 **y=100** 并先 `fill … air` 开洞
- **网桥必须是独立程序**（项目决定）：`poc/mc/ender-bridge.lua` 装成 `startup.lua`、自带 `bridge.txt`/`bridge-log.txt`、
  不 import `rpv/*`（文件里 0 处 `require`/`dofile`/`loadfile`）；`rpv/*` 与 `apps/*` 里不许出现 ender modem 字样（0 处检测）
- **独立性是可证明的**：`run-mc.ps1` 对 `boot=ender-bridge` 的电脑**只**装 `startup.lua` + `bridge.txt`
  （不拷 `rpv/`、`apps/`、`compat/`、`crypto.lua`、`rpv.lua`）——这些电脑跑完只有
  `startup.lua / bridge.txt / bridge-log.txt` 三个文件，跨维度场景照样 **PASS**
- 客户端/服务端是**同一份程序**的两个角色（`bridge.txt` 里 `bridge_role=server|client`）：两侧各一台电脑、
  各一份配置 = 两个独立实例；**不是两个文件**（要物理拆成 `*-client.lua`/`*-server.lua` 另说）
- 独立程序的自检坑：只用 `os.pullEvent("modem_message")` 会在空闲时**阻塞**，计数/握手都不会刷新；
  必须加 `os.startTimer` 周期唤醒（已修）。另外独立程序崩了 CC 只把错误打到终端 → 用 `pcall(main)` 写进日志

**注意**：harness 每次会先 `forceload add -48 -16 400 16`（**方块坐标**）再整带清空 ——
远处区块没加载时 `/setblock` 会失败，而且同批的 `/fill ... air` 会整条不生效，留下上一场景的电脑
（会出现重复 ComputerId，导致结果错乱）。

实测数字见 [poc/out/measurements-mc.md](../out/measurements-mc.md)。

> 注：`wansec` 真机场景的判定只看**安全证据**（握手派生密钥、真实流量穿过隧道、窃听者读不到明文、伪装重放被拒）；"近端主机自检"（ping/回显往返）在真机上受无线 LAN 偶发 ARP 超时影响，因此由 CraftOS-PC 的 `poc/run-wansec.ps1` 三模式覆盖（ARP 确定性）。
