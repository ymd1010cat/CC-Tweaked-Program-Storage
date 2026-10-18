# RPV1 —— CC:Tweaked 上的类 IPv4 传输协议：后续开发方向与执行状态

> **项目名：RPV1（Rednet Protocol Version 1）。**
> 命名约定：**名称层**（文档标题、正文、版本标签、日志里的 `version=`）统一写 **RPV1**；
> **代码层**（目录 `poc/rpv/`、文件名 `rpv-log.txt`、配置键 `rpv_host`、进程内标识符与 rednet 上的协议串 `rpv`）
> 保留历史前缀不动，避免无谓的回归风险。日志现在会打印 `version=RPV1`。

> 姊妹文档：[rednet-ipv4-feasibility.md](rednet-ipv4-feasibility.md)（可行性 + 设计 + 协议细节）、
> [rpv-security.md](rpv-security.md)（WPA2 式安全原型）、
> [poc/out/measurements.md](poc/out/measurements.md)（CraftOS-PC 实测）、
> [poc/out/measurements-mc.md](poc/out/measurements-mc.md)（**真机 Minecraft 实测**）、
> [poc/mc/ENVIRONMENT.md](poc/mc/ENVIRONMENT.md)（真机 harness 配方）。

> 约定：CraftOS-PC 调试**只用 ID 20–30**；真机调试用独立目录的专用服务器（`mc-server\`），
> **不碰用户的整合包实例**。

---

## 0. 现状盘点

已有（全部可运行、有实测证据）：

- **协议核心**：L2 帧（modem 频道）/ ARP / 类 IPv4 头 / ICMP（echo、time-exceeded、unreachable、**frag-needed**）/
  UDP（伪头校验和 + socket API）/ 最长前缀路由 / 分片与有上限重组 / **PMTU + DF**
- **链路与拓扑**：有线、无线、末影 modem；**频道命名空间仲裁**；多计算机集群（fabric，N 台 = 一台路由器一跳语义）；
  **rednet 只做 WAN**（advert 学路由、序列号防乱序、环路保护、默认路由通告、纯 rednet 设备地址映射）
- **传输层**：`rpv/conn.lua` —— 三次握手、累积 ACK、滑动窗口、**AIMD 拥塞控制**、RTO（SRTT/RTTVAR）、快速重传、FIN
- **应用层**：`rpv-selftest`（验收客户端）、`udp-echo`、`routectl`、`rednet-dir`、**rednet 兼容 shim**（未修改的
  rednet 程序可直接跑）、遥测（agent/host）、指标面板、**窗口化 / 连接式 FTP**（整文件 SHA-256 校验）
- **可运维**：配置校验、抓包环、`routes.txt` 热加载、启动看门狗（崩溃自重启）、本地 CI（`poc/ci.ps1`，不接 GitHub）
- **测试**：CraftOS-PC **22 个场景全绿**；真机 Minecraft **11 个场景全绿**

还缺 / 可做（按性价比排序，见 §1–§9）：

1. 真机规模数据（多站点、跨维度、长链路、上百台电脑的 pps 天花板）
2. 传输层的**拥塞控制调参**（现在窗口/超时是按 tick 硬编码的保守值）
3. 安全落地（WPA2 原型已有，未接入数据面）
4. 与 rednet 生态的双向互操作（现在只做了"rednet 设备 ↔ rpv"的单向映射）

---

## 1. 立即可做（性价比最高）

| # | 方向 | 为什么值得 | 产出 |
| --- | --- | --- | --- |
| 1 | **多站点大地图实测** | 已经能跑（`sites` 场景：无线 LAN + rednet WAN + 66 格有线直连），但只跑了 3 站点；真实服务器是十几个站点、跨维度 | 站点规模曲线（站数 vs 收敛时间/pps） |
| 2 | **跨维度 / 末影 modem 段** | ender modem 是"无隔离"介质，最容易出事（我们的 `CHANNEL_AUDIT` 会警告） | 跨维度 LAN 的正确性 + 隔离建议 |
| 3 | **连接层调参 + 持久连接** | 真机 1 tick = 50 ms 决定了一切超时下限；现在 `conn_rto_min=0.05`、窗口从 1 起步 | 吞吐曲线、参数推荐表 |
| 4 | **长稳测试**（看门狗 + 遥测跑几小时） | CC 服务器上"跑一夜"才会暴露内存/句柄泄漏 | 内存/任务/端口泄漏报告 |

## 2. 协议核心：正确性与规模

- ✅ 已做：ARP 队列/重试/超时、重组上限、PMTU/DF、ICMP 语义完整、TTL 与 time-exceeded、
  fabric 帧分片、频道仲裁
- ⬜ **路由规模**：现在 LPM 是线性表；上百条路由时要做前缀树或缓存（等实测数据）
- ⬜ **路由协议**：`routes.txt` 是静态的，WAN advert 只单跳。可做"站点间汇总路由"（/24 汇总成 /16 再通告）
- ⬜ **多 WAN**：库当前**每节点只支持一个 rednet WAN 接口**（转接站点需要两条 WAN 时，第二条改用直连 rpv 链路）
- ⬜ **组播 / 广播域**：现在只有有限广播（255.255.255.255，单跳）；可加 IP 组播前缀

## 3. 传输层与应用层

- ✅ 已做：窗口化 FTP（累积 ACK + 快速重传）、`conn.lua`（握手/AIMD/RTO）、rednet 兼容 shim、遥测、面板
- ⬜ **连接层接入更多应用**：把 shim 的 `rednet.send`、遥测、文件传输统一走 `conn`
- ⬜ **参数按真机自适应**：以 tick 为单位暴露配置（`conn_rto_min` 已可配，默认 1 tick）
- ⬜ **应用层协议**：远程 shell（带鉴权）、配置分发、日志收集（遥测已是一半）
- ⬜ **HTTP 风格请求/响应**：给第三方程序一个 `rpv.fetch(url)` 的简单接口

## 4. 安全（当前最大短板）

- 现状：`rpv-security.md` 已有纯 Lua 的 SHA-256/HMAC/HKDF/PBKDF2/ChaCha20 + WPA2 式四次握手 + AEAD 原型（9 项 KAT 通过），
  但**数据面还没接**（网络上跑的是明文）
- ⬜ 把 AEAD 接到 `conn` 载荷上（每帧 PN + 重放窗口已有实现）
- ⬜ 密钥管理：每节点随机密钥 + 离线分发（不要全局 PSK，PSK 可离线字典攻击）
- ⬜ 认证的路由通告（advert 目前可被伪造；seq/hops 只能防乱序和环路）

## 5. 运维与可观测性

- ✅ 已做：抓包环、`CFG_SUMMARY`、`routes.txt` 热加载、看门狗、面板、本地 CI
- ⬜ 指标落盘（现在只打日志，没有时序存储）
- ⬜ 告警（节点掉线、路由抖动、重传率超阈值）
- ⬜ 一键部署：把 `rpv/` + `apps/` + `startup.lua` 打包成可拷贝的目录或磁盘

## 6. 性能与实机基准

- ✅ 已做（真机 MC）：modem 单帧 128 KB、洪泛 200×140 B 零丢包、停等 RTT = 1 tick、
  `os.sleep(0)` = 50 ms、无线半径 64 格、窗口化 FTP 2–3×、连接层末态 cwnd=24
- ✅ **真实 MSPT 基线**（spark + 假人读聊天，Fabric 服务器；`lan` 场景 3 台电脑）：
  TPS 20.0/20.0/19.32/19.86/19.95，**tick 中位 0.4 ms、95 分位 0.9 ms、最大 2.7 ms**（预算 50 ms），
  CPU 20–30%，`Can't keep up!` = 0 → **tick 余量极大，瓶颈远在几十台电脑之外**
- ✅ **跨加载器验证**：同一 `lan` 场景在 Fabric 0.19.5 + CC:Tweaked 1.120.2(fabric) 上同样 PASS
- ✅ **性能观测工具链**：vanilla `/debug`（两套服务器都能用，但只报达成 tick 速率）+
  spark（真实 MSPT/CPU/内存；命令输出只在游戏内聊天，用**假人** `poc/mc/bot/read-chat.mjs` 登录 Fabric 读取）
  + `-SparkProfile` 落盘 `.sparkprofile`（拖进 spark.lucko.me 看火焰图）
- ✅ **pps 天花板已测**（`poc/apps/mc-load.lua` + `poc/mc/load-sweep.ps1`，Fabric + spark 真 MSPT）：
  8 发送方无线 → 路由器 → 计数器：
  **原始 modem 帧**峰值 **≈2.6k 帧/秒（≈130 帧/tick）**，再加码反而下降；
  **协议层（真实 RPV1 UDP 经路由器）≈550–650 pps（≈30 包/tick）**，640 pps 时**零丢包**、再高只增丢包；
  两种负载下 **TPS 恒 20.0、tick 中位 0.5 ms / 95 分位 1.3 ms**（预算 50 ms）⇒ **瓶颈是 CC 运行时的每包成本
  （≈4.7 个 modem 帧/包），不是服务器 tick**；无背压的 flood 到顶后表现为丢包而非拖慢服务器
- ✅ **pps 扩展性 + 介质 + 预算 + 背压**（四项后续全部实测，详见
  [poc/out/measurements-mc.md](poc/out/measurements-mc.md) §2.12）：
  ① **多接收方线性扩展**（1→3 个接收方：1807→5421 fps，每个恰好 1807）⇒ 2.6k 上限是**每接收方**成本而非介质；
  ② **有线=无线**（点到点 226/904 fps 完全一致、100% 送达）⇒ 介质不是瓶颈，单发送方自身循环才是；
  ③ **`max_main_global_time` 10→25 ms 无任何变化** ⇒ CC tick 预算不是约束；
  ④ **背压优于 flood**：conn 200 kB **逐字节零丢包、1.5 s（≈133 kB/s ≈ 950 pkt/s 等效）**，而 flood 只送达 544 pps 且丢 ~70%；
  并发现 **`conn_rto_min` 默认 0.05 s（1 tick）在真机上过敏感**：200 kB 突发触发 **12 次虚假 RTO**，
  提到 **0.2 s（4 tick）→ 0 次重传且吞吐不变** ⇒ **已把默认值改为 0.2 并复验**
  （CraftOS-PC **22/22** 含 `conn`/`conn-loss`；真机 conn 干净与 20% 丢包场景均 PASS、逐字节一致）
- ✅ **长链路**（`-Scenario longchain -Count 10`，10 路由 + 2 主机）：
  10 跳 ICMP **RTT = 0 tick**（同 tick 内往返，延迟不随跳数累积）、2000 B 跨 10 跳传输成功、
  ttl=11 到达 / ttl=2 在第 2 跳超时（`ttl_exceeded=2`）；12 台电脑在线时 TPS **20.0**、tick 中位 0.6 ms、95 分位 7.3 ms
- ✅ **跨维度**（`-Scenario endbridge`）：**ender modem（`wireless_modem_advanced`）只当网桥**，
  且网桥是**独立程序** `poc/mc/ender-bridge.lua`（装成 startup.lua、自带配置、`rpv/*` 与 `apps/*` 中 0 处提及 ender modem）；
  主世界 ⇄ 下界两个网段被连成**同一子网的一个 LAN**（ARP 广播过桥），跨维度 ping 4/4、900 B 传输成功，
  两侧网桥双向计数 8/5 与 5/8、丢 0；**rpv 侧零改动**
- ✅ 附带：`-Scenario range -Distance 2000 -AdvancedModems` 验证 ender modem **2000 格仍双向通**（普通 modem 上限 64 格）

## 7. 工程化

- ✅ **作为库使用（外部程序可调用）**：
  - 入口 **[poc/rpv.lua](../poc/rpv.lua)**：`require("rpv")` 即可 —— 自己找目录、按依赖顺序加载 11 个模块，
    暴露 `rpv.version` / `rpv.modules` / `rpv.new_node` / `rpv.install_rednet_shim(node, opts)`
  - **无需配置文件**：`rpv.node_new({ role=..., ifaces={ {...} }, gw=..., routes={...}, fabric={...} })`
    直接吃 Lua 表；`rpv.node_new("role.txt")` 的旧文件形式继续兼容
  - 公开面文档 **[poc/rpv/API.md](../poc/rpv/API.md)**（明确哪些是稳定面、哪些是内部面）
  - 外部程序示例 **[poc/examples/](../poc/examples/)**：`rpv-echo.lua`（UDP 回显）与
    `rpv-libtest.lua`（ARP / ICMP+RTT / UDP 往返 / 4 KiB 分片重装 / 统计 自检），
    两者都**装成 `startup.lua` 直接跑**，不经过 `node2/startup.lua`、不读 role.txt
  - 验收：**CraftOS-PC** `pwsh -File poc\run-lib.ps1` = PASS（7/7）；
    **真机** `run-mc.ps1 -Scenario lib -Target fabric` = PASS（7/7，含 4009 B 分片重装）
  - 附带修掉一个 API 泄漏：`rpv.icmp_echo` 现在自己记录发送时间，外部程序不再需要写 `node.ping_sent[seq]`
- ✅ **内部部署包**（不对外分发、无 License）：`pwsh -File poc\build-dist.ps1` 生成 `dist/`
  - **单文件** `rpv-bundle.lua`（93 KB，所有模块内嵌并以原 chunk 名编译 → 报错行号仍指向 `rpv/<module>.lua`）
  - **目录形态** `rpv.lua` + `rpv/*.lua` + `compat/` + `examples/`
  - **电脑端安装器** `install.lua`：来源可为目录/软盘/HTTP(S) base URL，逐文件比对 `MANIFEST.txt` 的
    **CRC32 + 大小**（纯 Lua 计算，兼容 Lua 5.2 的 `bit32` 与 5.3+ 的真实位运算），装完加载并建节点自检
    （`INSTALL_OK files=20 verified=20` / `INSTALL_VERIFY ok=true version=RPV1 modules=10`）
  - `MANIFEST.txt` 同时给 **SHA256**（外部工具强校验）；`dist/rpv-1.0.0.zip` 整包
  - 验收：`run-lib.ps1 -Mode tree|bundle|install` 三种形态全部 PASS（各 7/7 断言），
    CraftOS-PC 全量回归 **25/25**（新增 `lib-bundle`、`lib-install` 两个作业）
  - README 重写为部署向：[README.md](../README.md)（三种安装方式 + API 速查 + 目录 + 测试状态）
- ✅ 已做：模块库（`poc/rpv/*.lua`，10 个模块 + 连接层）、单一 bootstrap、25 个 CraftOS-PC 场景、
  11 个真机场景、本地 CI 脚本、文档
- ⬜ 单测（现在全靠场景测试；协议编解码可以做纯函数级单测）
- ⬜ 版本迁移（协议版本号已有 `ver=1`，需要"新旧版本共存"策略）
- ⬜ 发布流程（changelog、兼容性矩阵）——按用户决定**不接 GitHub CI**

## 8. 生态与产品化

- ⬜ 让第三方程序"零改动"用上 rpv（shim 已能做到；还差文档和示例包）
- ⬜ 与现有 rednet 程序共存：同一台电脑同时跑 rednet（WAN）与 rpv（LAN），需要明确的 API 命名空间
- ⬜ 教程：从零搭一个 3 站点网络（`sites` 场景就是现成的教学拓扑）

## 8.5 后续发展方向（P0–P5，按"安全收益 ÷ 成本"排序）

> **P0 已完成**——网桥链路安全（详见 [rpv-security.md](rpv-security.md) §0 与 [poc/mc/ENVIRONMENT.md](poc/mc/ENVIRONMENT.md)）

- ✅ **P0 网桥链路安全**：`bridge_psk` fail-closed（缺 PSK 零转发）；HELLO/ACK 双向 HMAC 握手（无 PSK 者无法配对，
  也无法让服务端在两个对端之间抖动）；HKDF-SHA256 派生每方向会话键；逐帧 `"S"|counter(4)|payload|tag(16)`（HMAC-SHA256 截 16 B）；
  每方向单调计数器 + 64 帧防重放窗口 + 未来帧上限；`bridge_max_frame` 先于 HMAC 检查；ethertype 白名单（默认仅 IPv4/ARP）、
  可选源 MAC 白名单、广播/秒限速；全部丢弃原因计数；内嵌 SHA-256 开机自检 KAT。
  **双验收**：CraftOS-PC `run-bridge.ps1 -Mode normal|wrongpsk`（20 伪造 / 8 HELLO / 8 重放 / 1 超大全部被拒；
  错误 PSK 时两侧 `paired=false relayed=0`、主机无法通信）；真机 `run-mc.ps1 -Scenario endbridgesec`
  （伪造 20、重放 16、超大 1、未来帧 5 全拒，合法跨维度流量仍 `complete=true`）。CraftOS-PC 全量 **27/27**
- ✅ **P1 rpv 控制面 AEAD 接入 conn**：`conn_secure=1` + `conn_psk=<hex|口令>`。
  握手携带认证 nonce（`HMAC(k_ctrl,...)`）；每条连接用 HKDF 从双方 nonce 派生**每方向**
  加密键与 MAC 键；所有分段 encrypt-then-MAC（`header(13) | ChaCha20(payload, counter=seq) | tag(16)`）；
  纯 ACK/FIN 也带标签；错误 PSK 无法完成握手（`CONN_SEC_SYN_REJECT`），安全节点拒绝明文对端
  （`CONN_SEC_PEER_PLAINTEXT` + abort = fail-closed）；计数 `sec_auth_fail/sec_ctrl/sec_plaintext`。
  密码学提升为库模块 **`poc/rpv/crypto.lua`**（由 `poc/build-crypto.ps1` 从 `poc/security/crypto.lua`
  生成，单一实现；库用户直接得到 `rpv.sha256/hmac_sha256/hkdf_sha256/pbkdf2_sha256/chacha20_xor/...`，bundle 同步变大到 105 KB）。
  **验收**：CraftOS-PC `conn-sec`（4400 B 逐字节一致、双方 `CONN_SEC_KEYS`、`sec_auth_fail=0`）与
  `conn-sec-wrongpsk`（零传输 + SYN 被拒）；真机 `run-mc.ps1 -Scenario ftp -FtpTransport conn -ConnSecure psk|wrongpsk` 同样 PASS。
  实测开销：4.4 KB 文件 **明文 0.837 s → 安全 1.383 s**（≈1.65×，与 ~215 KB/s 的纯 Lua 密码学预算吻合）。
  全量回归 **29/29**
- ⬜ **P1b WAN 隧道 AEAD**：把同一套握手/数据键用到 rednet WAN 的控制帧（advert / who-has / 隧道载荷）
- ✅ **P2-a DHCP-lite + lookup-lite**（网络能力第一项）：`poc/rpv/services.lua` ——
  **DHCP-lite**（DISCOVER/OFFER/REQUEST/ACK；客户端只配一个占位地址 `10.254.x.y/16` 就能领到真地址，
  自动改地址、重建直连路由、装默认网关；服务端在客户端不可路由时按 DHCP 惯例**广播回复**）+
  **lookup-lite**（name server 的 REGISTER/QUERY/ANSWER + 静态 `hosts.txt`，`node:lookup(name)` / `node:dns_register(name)`）。
  **验收**：CraftOS-PC `poc/run-svc.ps1`（客户端拿到 `10.0.1.100/24` + gw、注册 `client22`、解析 `host23`→`10.0.2.2`、
  跨路由器 ping 通）与真机 `run-mc.ps1 -Scenario svc` 均 **PASS**；全量回归 **30/30**。
  期间还加了**模块约定自检**（加载器发现 `return function(M)` 风格即报错）——这个坑犯过两次
- ✅ **P2-b 动态路由（距离矢量 + 环路抑制）**：`poc/rpv/dv.lua` —— 每台路由器在每条非 WAN 接口周期性广播
  `(net, prefix, metric)`（UDP 6800，默认 3 s），收到即 `metric+1` 装成 `kind="dv"` 路由；
  **毒性反转的水平分割**（回送给来源邻居时该路由通告为 16=不可达）+ **跳数上限 16** + **抑制计时（`dv_timeout`=12 s 后 `
  DV_EXPIRE`）**；路由优先级在**安装期**判定（`DV_SHADOWED`：同前缀下 connected/静态/fabric 胜过 dv，
  `rpv.ROUTE_RANK` 记录顺序），`route_upsert` 保证重复通告不会堆出重复条目。
  **验收**：CraftOS-PC `poc/run-dv.ps1 -Topology ring|chain` 双拓扑 PASS —— 环形 3 路由器**零静态路由**自动学到远端子网、
  **选最短路径**（metric=1 经 R3，而非经 R2 的 2 跳）、主机端到端 ping + 2000 B 成功、`ttl_drop=0` 无环路；
  链式 4 路由器 3 跳（`metric=3`）同样收敛；真机 `run-mc.ps1 -Scenario dv` PASS（`DV_INSTALLS=3`、`poisoned=16` 证明毒化反向在工作）。
  全量回归 **32/32**
- ✅ **P2-c NAT-lite + 组播/广播域控制**：`poc/rpv/nat.lua`（**PAT 伪装**：内网主机共享一个外部身份，
  源地址/端口改写 + 流表回程映射 + UDP 校验和重算 + ICMP echo 按 id 映射 + 流超时/池上限；
  **端口映射 DNAT**：`nat_forward=7000>10.0.1.2:7000`，同端口回程保持；无规则/无流的外部入包
  `NAT_DROP` 静默丢弃——不是"公网 NAT"，只是让一个私网子网共享一个对外身份）+ `poc/rpv/mcast.lua`
  （组播组 = `224.0.0.0/4` 的 IP 包按 L2 广播发出，接收方只收自己 join 的组；路由器按
  `mcast_domains=LAN-A>LAN-B` 决定转发域 + 每域每组的**令牌桶限速**；`bcast_relay=LAN-A>LAN-B` 顺带把
  默认永不转发的**受限广播**也纳入域控制与限速）。
  **验收**：CraftOS-PC `poc/run-p2c.ps1 -Scenario nat` PASS（`NAT_XLATE`/`NAT_ICMP_XLATE`/`NAT_FWD`/`NAT_DROP`
  + 外部主机看到源地址是 NAT 地址、且能通过映射端口反向打到内网主机）与 `-Scenario mcast` PASS
  （`MCAST_FORWARD` 13 个、`MCAST_RATE_DROP` 20 个（限速 10/s 生效）、`MCAST_DENY`（反向域被拒）、
  `BCAST_FORWARD`、对端收到组播与广播、未 join 的组被丢弃）。全量回归 **34/34**
- ✅ **P2-d QoS 多优先级队列**：`poc/rpv/qos.lua` —— `link_send` 在开启 QoS 时改为**按优先级入队**，
  由 tick 任务按预算出队（优先级 0 全清 → 1/2 按权重轮转）：**0 = 控制**（ARP/ICMP、**conn 纯 ACK**（type 3 且 len 0）、
  路由通告）、**1 = 交互**（UDP ≤ `qos_small`）、**2 = 批量**（其余）；队满时**先丢最不紧急的帧**（批量替控制背锅）。
  **验收**：CraftOS-PC `poc/run-qos.ps1` —— 同样 120 包洪泛下同一段 4 KB conn 传输，
  **关 QoS 319 ms → 接收方开 QoS 276 ms**（均 0 重传），接收方计数 `high=11 mid=1 low=66 dropped=54`
  （11 个纯 ACK 走到最高优先级、64+ 个批量回显垫底、丢弃只落在批量）；`run-all` **35/35**。
  **P2（DHCP-lite / lookup-lite / 动态路由 / NAT / 组播域 / QoS）全部完成**
- ✅ **P1b WAN 隧道 AEAD**：`poc/rpv/wansec.lua` —— rednet WAN 是整张网里最"公开"的一段（同频道任何 modem 都能听），
  开启 `wan_secure=1` + `wan_psk` 后：`rpv-sec-hello`（mac+nonce+HMAC）握手 → 双方按**有序 (mac,nonce) 对**派生
  **每对端会话键**；数据帧变 `"S"|counter(4)|ChaCha20(frame)|tag(16)`；`rpv-advert`/`rpv-who-has`/`rpv-is-at`
  用 `k_ctrl` 按规范化字段签名；**每对端重放窗口**（计数器 + 64 条，且重复 hello **不重置**会话——这点是重放能被抓到的关键）；
  明文帧/未签名表/坏 tag/无密钥对端一律丢弃并计数（fail-closed）。
  **验收**：CraftOS-PC `poc/run-wansec.ps1` 三种模式全 PASS，且带**真实的窃听者**（独立程序 `poc/wan-sniffer.lua`，
  零 rpv 依赖，开 65535/21/22 频道）：
  ① `plain` 基线——窃听者**能看到** marker `RPVSECRET`；
  ② `secure`——端到端 ping + marker 照常（`WANSEC_KEYS`/`tx=2 rx=2`），窃听者只看到 `"S"…` 密文，
  且它**伪装成 21 号**用新 rednet 消息 id 原样重放的帧被拒（`WANSEC_REPLAY from=21 counter=1 top=2`）；
  ③ `wrongpsk`——`peers=0 tx=0 rx=0 auth_fail=23`，主机 ping 失败，marker 不泄漏。`run-all` **38/38**
- ✅ **P3 传输层打磨**：`poc/rpv/conn.lua` ——
  **SACK**（`conn_sack`，默认开：接收方缓存乱序段并用 `T_SACK` 段上报已持有的块，发送方只补最低空洞
  `CONN_SACK_RETX`，不再靠 3 个重复 ACK 猜）；**窗口缩放**（`conn_wscale=N`，两端一致：通告窗口按 `rwnd>>N` 发送、
  对端左移还原，并让发送方真正尊重对端窗口 `peer_rwnd`）；**慢启动曲线**（`conn_slow_start=1` 改为
  `cwnd += 1 MSS`/ACK 即每 RTT 翻倍，替代旧的"每 ACK 翻倍"；`conn_iw` 初始窗口）；
  **多流公平**（`conn_global_max_inflight=N` 限制**整个节点**的在途段总数，但**零在途的流总可先发一段**，
  避免新流被饿死；`cwnd_limited` 计数）；**keepalive**（`conn_keepalive=秒`：空闲时发空 `T_SACK` 探针，
  对端以纯 ACK 应答；连续 3 次无应答即 `CONN_KEEPALIVE_TIMEOUT` 断开）。另有测试钩子 `block_egress=1`（整机不出网）。
  **验收**：CraftOS-PC `poc/run-p3.ps1` = PASS —— 确定性丢包（`drop_every=3`）下 SACK 路径做了 **11 次定向补洞**
  且重传数不高于经典路径；两条 4 KB 并发流在**开/关**全局上限下都完成（上限生效时 `cwnd_limited=18/20` 说明它在仲裁）；
  keepalive 在对端存活时探测 3 次、对端"变黑"后 7.5 s 内触发超时（`ka_miss=4`）。全量回归 **39/39**
- ✅ **P4-a 离线单元测试 + lint（luacheck 替代）**：`poc/tests/`（10 个测试组、**194 条断言**，纯逻辑：
  编解码、IP 校验和、路由表、crypto KAT、WAN AEAD 状态机、NAT 改写与校验和、组播域判定、QoS 分类、compat）
  + `poc/tools/lint.lua`（零依赖静态检查：BOM/语法/模块约定/已知坑（`os.epoch("ms")`、`p1 == timer`、
  `string.concat`）/行尾空白/疑似全局变量），**33 个文件 0 error**；用 `poc/run-offline.ps1` 单进程 headless 跑
  （零拓扑、零 spawn、约 2 秒），并附 `tests/host.lua` 让桌面 Lua 5.1 也能跑同一套。
- ✅ **P4-b 全量配置热加载**：运行中监听 `routes.txt` / `role.txt` / `hosts.txt`（每 2 s 比对 mtime）——
  路由重载 `ROUTES_RELOADED`；配置重载 `CFG_RELOAD changed=N restart_required=M` + 逐键 `CFG_CHANGED key=old->new`，
  不可热改的键明确报 `CFG_RELOAD_RESTART_REQUIRED key=...`（role/iface/wan/fabric/app/spawn/dhcp…），
  可热改的键同步推给在跑的服务（dv/qos/mcast 参数）；`hosts.txt` 重载后 `lookup` 立即生效。
  **验收**：`poc/run-hotreload.ps1` PASS —— 重载前 ping 失败、重载后成功；静态命名重载前查不到、重载后查到；
  路由器日志同时出现 `ROUTES_RELOADED (file change)`、`CFG_RELOAD`、`CFG_CHANGED stats_at=40->45`、
  `CFG_RELOAD_RESTART_REQUIRED key=app`、`HOSTS_RELOADED`。
- ✅ **P4-c 版本兼容矩阵**：`poc/COMPAT.md`（已验证宿主、用到的 API 与可用性、刻意不依赖项、降级行为）
  + `poc/rpv/compat.lua` 开机自检 `COMPAT ok=... os=... missing=... optional=...`。
- ✅ **P4-d 拓扑自动发现 + 网络图输出**：`poc/rpv/topo.lua` —— 每个节点周期性（默认 5 s）把**已有的**状态
  用一个文本报文上报（自身 id/role、`IFACE` 接口、`PEER` 邻居（来自 ARP 缓存 / DV 路由 / fabric / WAN 对端）、
  `SVC` 服务：dhcp/leases/dns/nat/mcast/qos/dv）；收集器（`topo_collect=1`，UDP 6900）按 id 合并、
  把对端地址反查成"拥有它的节点"从而**画出链路**、按 `topo_ttl` 过期消失的节点，并可周期性输出网络图
  （`netmap.txt` + `NETMAP_BEGIN/NODE/LINK/NETMAP_END` 行）。
  **验收**：CraftOS-PC `poc/run-topo.ps1` PASS —— 2 路由器（跑 DV）+ 3 主机 ~12 s 内发现**5 个节点、5 条链路**
  （路由器↔路由器 + 每台主机↔其路由器），网络图成帧写出；`tests/t_topo.lua` 离线覆盖解析/建链/过期逻辑。
  **P4 五项（离线单测、lint、全量热加载、兼容矩阵、拓扑图）全部完成**
- ✅ **P5-a/b 多跳（串联）网桥 + 环路防护（STP-lite）+ 桥冗余**：网桥程序
  [poc/mc/ender-bridge.lua](poc/mc/ender-bridge.lua) 新增——① **claim 控制帧**（控制以太类型 `0x88B6`，LAN 侧明文、链路侧走同一套密封帧且绕过 ethertype 白名单）；
  ② **每 LAN 段指定桥**（id 最小者；听到更小 id 就停止该 LAN 侧两个方向的中继，链路侧永不阻塞 ⇒ 链式多跳仍可用）；
  ③ **撤销**（链路对端静默超时就撤回自己的 LAN 通告，让另一对桥接管 ⇒ 这才是端到端冗余）；
  ④ **环路去重**（按 `(入侧, 帧哈希)` + 0.5 s 窗口，避免把主机 ARP/ICMP 重传误当环回）；⑤ 故障模拟 `bridge_selfstop_at`。
  **验收**：CraftOS-PC `poc/run-stp.ps1` 三模式全 PASS ——
  `-Mode chain`：4 台桥**串联两跳**（LAN-A→b1→link1→b2→LAN-B→b3→link2→b4→LAN-C），4/4 桥中继、端到端 ping + 900 B 通；
  `-Mode loop`：两对桥并联成环，每段一台桥 `STP_BLOCK`、活跃路径 2/4 桥中继、端到端照常且无重复风暴；
  `-Mode failover`：根桥第 22 s 自停 → `STP_PEER_TIMEOUT`/`STP_WITHDRAW`/`STP_UNBLOCK`，待机对桥接管、**端到端恢复**。
- ✅ **P5-c 大规模压测**（控制面离线 + 真机网格 + 100+ 台仿真，用户批准 ID 100–300）：
  **控制面 100 节点**（离线 `tests/t_scale.lua`）：100 节点/180 链路合并 57 ms；100 节点 DV 直径 7、**8 轮收敛**、35 ms。
  **数据面网格**（`poc/run-mesh.ps1`，3 路由器三角网格）：4 并发 conn 流 6000 B / 1288 ms / **4658 B/s** / 0 重传。
  **100+ 台仿真**（`poc/run-scale.ps1 -Stage Z|Y|A|B|D`，ID 100–209）：**110 台全部启动、DV 99–100/100 收敛**，
  但计时滞后 3.4 s（最差 27 s）⇒ **100+ 台数据面在本机（12 核）不可用**；22 台滞后仅 26–33 ms 时跨行 ping 仍 0–17% ⇒
  发现 **≥3 跳网格路径的确定性转发问题**（路由表正确、无 `FWD` 记录、`DV_REMOVE reason=poisoned` 大量抖动；
  `dv-chain` 线性链路全 PASS ⇒ 等代价网格特有，怀疑多跳选路回指入接口），**列为下一步待修项**。
  **WAN 介质**（用户要求）：WAN 端口接受有线/无线 modem，真机 `-Scenario wanlink -WanLink wired|wireless` 双介质全 PASS。
  **P5 三项（多跳桥+STP-lite、桥冗余、大规模压测）全部完成**
- ✅ **P5 平台**：跨维度多跳桥 + 环路防护（STP-lite）、桥冗余、大规模压测（多路由器网格 / 100+ 电脑）

## 8.6 下一步方向（按建议优先级）

1. ✅ **≥3 跳网格转发问题已修**（协议正确性）：根因是 `dv.lua` 把"非网关邻居的毒化反转"当成路由失效，
   导致远端路由反复 INSTALL/REMOVE（3 跳网格实测抖动 20 次、`NO_ROUTE_FWD`）。修复＝毒化失效判定收紧到
   当前网关 + 有限报文刷新也按网关；另加 `dv_jitter` 与逐包 `trace=1`。复验：3×3 100%、4×4 PASS、
   6×6（44 台）70% PASS、110 台 46.7%（瓶颈是模拟器计时而非路由）。
2. ✅ **DHCP-lite 升级完成**：租约按 client-id(mac) 记账、OFFER 前 ICMP 冲突探测、`DHCP_EXPIRE` 过期回收
   （环形分配）、客户端 T1 续租（`DHCP_RENEW`）、`RELEASE`/`DECLINE`；离线 [poc/tests/t_services.lua](poc/tests/t_services.lua)
   + `run-svc.ps1` 续租断言；见 [poc/rpv/API.md](poc/rpv/API.md) 的 DHCP-lite 一节。
3. ✅ **IPv4 保留网段语义**：`ip.lua` 地址分类（127/8 环回、10/8+172.16/12+192.168/16 局域网、
   100.64/10 CGNAT、169.254/16 链路本地、0/8、224/4 组播、240/4 保留、文档/基准段、公有）+ 数据面落地
   （每节点自带 `lo`、环回本地投递零 modem 流量、定向广播本段投递、路由器不转发保留段、伪造环回/0/8 入站丢弃、
   `reserved_drop`/`directed_bcast_drop` 计数）+ 配置告警（`IFACE_CLASS`、`CFG_WARN ADDR_NOT_UNICAST/
   ADDR_IS_NETWORK/ADDR_IS_BROADCAST/ADDR_NOT_PRIVATE`、`ADDR_WARN_SUMMARY`）。验收：离线
   [poc/tests/t_addr.lua](poc/tests/t_addr.lua) + CraftOS-PC [poc/run-addr.ps1](poc/run-addr.ps1)（PASS）。
4. **规模可行性固化**：`run-scale.ps1` 的 Stage Z 已在 CI；A/B/D 作为按需长测（B 70%、D 46.7% 已记录）。
5. **真机大规模**：真机上跑 20–30 台路由器网格 + 主机，验证同样的 3 跳路径在真实 tick 下的表现。
6. **地址冲突检测（可选加固）**：库内加同频道重复 IP 检测/免费 ARP 式 DAD 与可选 IP 头校验和校验。
7. **可观测性**：`routectl`/`panel` 增加多跳路径可视化（结合 `topo` 的网络图输出每条流实际走的下一跳）。


## 9. 不建议做（反范围）

- ⚠️ NAT / 端口转发：**公网意义上的 NAT** 依然不做（CC 没有公网）；P2-c 实现的是它的另一半——
  一个私网子网共享一个对外身份（PAT）+ 把单个端口映射到内网主机（DNAT），见 [poc/rpv/nat.lua](poc/rpv/nat.lua)
- ❌ 完整 TCP（拥塞控制 + 选择重传 + 时间等待）：CC 的 tick 尺度下收益远小于复杂度
- ❌ 依赖外部服务（DNS、证书、公司服务器）：CC 环境经常离线
- ❌ 在一个 modem 频道上跑"分层协议栈"：频道数上限 128，分层会迅速耗尽

---

## 11. 执行状态（M1–M4 + 传输层，全部完成）

### 当前代码结构

```
poc/rpv/util.lua        字节打包 / 校验和 / 地址工具
poc/rpv/ip.lua          IPv4 式头 + 分片 + 有上限的重组（并发条目 / 字节上限）
poc/rpv/route.lua       路由表 + 最长前缀匹配 + path 解析
poc/rpv/arp.lua         邻居发现：请求排队 + 重试 + 超时
poc/rpv/link.lua        modem 频道链路层（dstMAC/srcMAC/ethertype 帧）
poc/rpv/icmp.lua        echo / time-exceeded / unreachable / frag-needed
poc/rpv/udp.lua         UDP + socket API（bind / sendto / reply / on_receive / close）
poc/rpv/conn.lua        连接管理 + AIMD 拥塞控制（握手 / 窗口 / RTO / 快速重传）
poc/rpv/fabric.lua      集群：成员公告、远端路由、FAB_FORWARD（一跳语义）、帧分片
poc/rpv/wan.lua         rednet WAN：advert（seq/hops/default）、分片、纯 rednet 设备翻译
poc/rpv/node.lua        接口、配置校验、转发、事件循环、协程任务、定时器、
                        抓包环、routes.txt 热加载、频道仲裁、统计、启动看门狗
poc/node2/startup.lua   引导（loadfile 加载库 + role.txt + shim + app + 看门狗）
poc/compat/rednet.lua   rednet 兼容 shim（drop-in API，走 UDP 可路由）
poc/apps/               socket-echo / m1-selftest / routectl / rpv-selftest / mc-probe /
                        mc-bench / mc-range / mc-wiredtest / udp-echo / rednet-dir /
                        legacy-chat / monitor-agent / monitor-host / panel /
                        ftp-server / ftp-client
poc/peer/legacy-rednet.lua   纯 rednet 设备（WAN 对端）
poc/security/           crypto.lua / wpa.lua / wpa-node.lua（安全原型）
poc/mc/                 Minecraft 真机 harness（rcon.py / run-mc.ps1 / server.ps1 / ENVIRONMENT.md）
```

> 旧的单文件 `poc/node/startup.lua` **已删除**；集群与 WAN 现在都在 `poc/rpv/` 里。

### M1 可用 —— ✅

| 场景 | 结果 |
| --- | --- |
| `m1` | traceroute hop1=10.0.2.1（路由器）、hop2=10.0.1.2（主机）；3/3 ping 应答；socket 收发成功 |
| `routectl` | 接口/路由/ARP/socket/统计/抓包报表 |
| `badcfg` | 4 条配置告警（重复频道、MTU<68、占用 rednet 频道、子网重叠） |

### M2 稳健 —— ✅

- ✅ ARP 请求队列化 + 重试 + 超时（`ARP_QUEUE → ARP_RESOLVED queued=1`）
- ✅ 重组资源上限（并发 16 条 / 64 KB，超限记 `REASM_DROP`）
- ✅ 配置校验（重复接口/频道、保留频道、MTU 下限、子网重叠）
- ✅ fabric（集群）与 rednet WAN 迁进库存，旧单文件删除
- ✅ **PMTU / DF**：`df=1` 时超出 MTU 不分片，路由器回 ICMP type 3 code 4（RFC 1191，带 next-hop MTU）；
  发送端学 `PMTU_UPDATE`，本机出口不够时记 `PMTU_LOCAL` 并本地回调。
  实测：`PMTU_NEEDED … mtu=128` → 客户端 `PMTU_UPDATE dst=10.0.2.2 mtu=128` → 88 B 重发成功（`pmtu_ok=true`）
- ✅ **advert 序列号 / 环路保护 / 默认路由**：重复或乱序 advert 记 `WAN_ADVERT_STALE` 丢弃、
  `hops > max_advert_hops` 记 `WAN_ADVERT_LOOP` 丢弃；`advert_default=1` 让无静态网关的站点自动装
  `WAN_DEFAULT_ROUTE`（实测：伪造 seq=5/5/9 分别被接收 / 判陈旧 / 判环路）
- ✅ **fabric 帧分片 + 频道仲裁**：超 fabric MTU 的载荷按 8 字节对齐分片（接收侧 8 条并发 + 5 s 过期）；
  启动记 `CHANNEL_POLICY` / `CHANNEL_CONFLICT`（实测：908 B → 10 片；故意同侧冲突 → `conflicts=3`）
- ✅ **连接管理 + 拥塞控制（`rpv/conn.lua`）**：三次握手（含重传与退避）、序号 / 累积 ACK、
  `min(cwnd, rwnd)` 滑动窗口、**AIMD**（慢启动 cwnd×2 → 拥塞避免 +1；RTO 塌缩 cwnd=1 & ssthresh=cwnd/2 & RTO 退避）、
  重复 ACK×3 快速重传、基于 SRTT/RTTVAR 的 RTO（`conn_rto_min` / `conn_rto_max`）、FIN/close。
  实测（`ftp_transport=conn`，**真机**）：干净链路 4.4 KB / **0.70 s**（末态 cwnd=24、RTO≈0.11 s）；
  每 5 个首发分段丢 1 时仍**逐字节一致**完成，`retx=23`、cwnd 收缩、RTO 退避到 **2 s 上限**（18.3 s）。
  CraftOS-PC 同场景 0.81 s / 18.7 s（[poc/out/measurements.md](poc/out/measurements.md) §11）。

### M3 有用 —— ✅

- **rednet 兼容 shim**（`poc/compat/rednet.lua` + `apps/rednet-dir.lua`）：
  **未修改的 rednet 程序**（`apps/legacy-chat.lua` 只调用 `rednet.*`）跨路由器工作：
  `rednet.lookup("chat","host-23") -> 23`、按计算机 ID 发送、收到 `pong from 23`、`broadcast` 由目录中继
- **遥测**（`monitor-agent` / `monitor-host`）：跨路由器 2 节点 `MON_RESULT nodes=2 ok=true`
- **文件传输**（`ftp-server` / `ftp-client`）：窗口化（`ftp_window`，默认 4），累积 ACK + 重复 ACK 快速重传；
  4400 B / 18 块，`FTPC_VERIFY sha_ok=true`，**宿主侧逐字节比对 identical=true**；
  真机实测窗口 4 比停等快 **2–3×**；`ftp_transport=conn` 可切到连接层

### M4 可运维 —— ✅（含实机基准）

- ✅ `routectl` + `capture=1` 抓包环（最近 64 帧）
- ✅ **启动看门狗**：顶层异常写 `crash.log` + 3 s 后 `os.reboot()`，重启后记 `WATCHDOG_RECOVERED`
- ✅ **`routes.txt` 热加载**：启动加载 + 每 2 s 检查 mtime（`n=1 (boot)` → 改文件 → `n=2 (file change)`）
- ✅ **指标面板** `apps/panel.lua`：有 monitor 就画 monitor，否则退回终端
- ✅ **本地 CI**：`poc/ci.ps1` → `poc/out/ci-<时间戳>.txt`，退出码即结果（**刻意不接 GitHub**）
- ✅ **真机基准（真 Minecraft）**：独立 NeoForge 21.1.253 + CC:Tweaked 1.120.2 服务器（`mc-server\`，
  未触碰你的整合包），RCON 驱动、无玩家参与：

  | 场景 | 结果 |
  | --- | --- |
  | `lan` 无线 / 有线 | **PASS**：ARP、ICMP（echo / ttl=2 / ttl=1 time-exceeded）、900 B 重组 + 出口 MTU 128 再分 9 片、UDP 回显校验 |
  | `pmtu` | **PASS**：DF=1 撞 128 → `PMTU_NEEDED` → 学 `PMTU_UPDATE mtu=128` → 88 B 重发成功 |
  | `ftp -FtpWindow 1` vs `4` | 均 PASS（逐字节一致）：停等 0.15–0.25 s → 窗口 4 用 **0.05–0.10 s** |
  | `conn` / `conn-loss` | **PASS**：`ftp_transport=conn` 干净 **0.70 s**（末态 cwnd=24、RTO≈0.11 s）；每 5 个首发分段丢 1 时仍逐字节一致完成（**18.3 s**、retx=23、cwnd 塌缩、RTO 退避到 2 s 上限） |
  | `cluster`（fabric） | PASS：`FABRIC_FWD/RECV`，客户端 `ttl2_ok=true`（集群 = 1 跳） |
  | `wan`（rednet 作 WAN） | PASS：`WAN_SENT/RECV`，两跳 `ttl2_ok=false` |
  | `shim`（rednet 兼容层） | PASS：未修改的 rednet 程序真机跨路由器工作 |
  | `multi`（3 路由器） | PASS：`ttl=4` 跨 3 跳；`ttl=2` 中途丢弃；R2 用 `routes.txt` 学路由 |
  | `sites`（多站点） | PASS：无线 LAN + **rednet WAN** + **66 格（超无线半径）有线直连** + 3 路由器；`ttl=4` 往返成功 |
  | `range` | 边界实测：**64 格可通、80 格零帧**（默认无线半径 64；`modem_message` 距离 = 真实方块距离） |
  | `bench` | 洪泛 200×140 B：**span=0 tick、接收 200/200 零丢包**；停等往返 **恰好 1 tick = 50 ms** |
  | `probe` | **modem 单帧 131,072 B 完整到达**；`os.sleep(0)` = **50 ms(1 tick)**；邻居间 RTT = **0.000 s（同 tick）** |

  对协议的结论：**ACK/重传超时下限 50 ms**（真机最小抖动 1 tick）；"每跳延迟"不是瓶颈、**tick 边界**才是；
  停等文件传输 18 块 ≈ 0.9 s / 4.4 KB → 必须开窗；modem 本身不限制分片大小。
  详见 [poc/out/measurements-mc.md](poc/out/measurements-mc.md)。

### 真机 harness 的坑（都已在脚本里绕开）

1. `/setblock` 出来的电脑**不是真电脑**（无 `ComputerId`，CC 不会建 ServerComputer）：必须
   `/data merge block … {ComputerId:<id>,On:0b}` + `/computercraft turn-on <id>`；重启用
   `/computercraft shutdown` → 写文件 → `turn-on`。
2. `/fill` 放的 `computercraft:cable` **不成有线网络**（`getNamesRemote()` 空、消息全丢）；
   要用 **`computercraft:wired_modem_full` 链**。
3. `wired_modem_full` **没有 `facing` 属性**（带 `[facing=…]` 整条命令失败）；无线 modem 才需要。
4. 电脑 `facing=north` 时：+X 侧 modem = Lua 的 `left`，-X 侧 = `right`（探针实测）。
5. **远处区块必须 `/forceload add -48 -16 400 16`（方块坐标）**；未加载时 `/setblock` 报
   "That position is not loaded"，且同一批的 `/fill … air` 会整条失效 → 上一场景的电脑残留 →
   **重复 ComputerId**、结果错乱。**清场必须在放置之前**，并且先用 `computercraft shutdown` 停掉
   （否则 `turn-on` 是空操作，旧进程会继续用旧 `role.txt`）。
6. 服务端用 **Java 25** 实测可跑（NeoForge 21.1 名义要求 21）；RCON 端口 25575。

### 回归

```powershell
pwsh -File poc\run-all.ps1            # CraftOS-PC：22 个场景，约 10 分钟，失败退出码 1
pwsh -File poc\ci.ps1                 # 本地 CI：跑同一套 + 报告落盘（不接 GitHub）
pwsh -File poc\mc\server.ps1 -Action start|stop|status   # 真机服务器生命周期
pwsh -File poc\mc\run-mc.ps1 -Scenario lan|pmtu|ftp|cluster|wan|shim|multi|sites|range|bench|probe
```

当前 **CraftOS-PC 22/22 全绿**、**真机 11/11 全绿**（报告：[poc/out/runall-report.txt](poc/out/runall-report.txt)）。

### 需要你决定的事

1. **下一个方向**：多站点规模实测（§1.1）/ 跨维度（§1.2）/ 连接层调参（§1.3）/ 长稳测试（§1.4）？
2. **安全要不要接数据面**（§4）：接上后所有流量走 AEAD（真机速率要重测）
3. 真机测试是否继续用这台独立服务器（**Java 25 + NeoForge 21.1.253 + CC:T 1.120.2**），
   要不要按你正式服务器的版本/模组组合再跑一遍
