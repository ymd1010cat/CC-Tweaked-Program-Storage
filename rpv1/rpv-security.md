# RPV1 安全层：能做"类 WPA2"的协议吗？

> RPV1 = **R**ednet **P**rotocol **V**ersion **1**（项目全称）；代码路径与协议串仍用历史前缀 `rpv`。

**结论：能，而且已经在本地实现并验证。** 但**不要照抄 WPA2 的 PSK 信任模型** —— WPA2-PSK 的握手可以被离线字典攻击，
而 CC 里抓包比 Wi-Fi 更容易（打开一个频道就能听）。建议用 **每节点随机密钥** 或将来上 **PAKE（WPA3-SAE 式）**。

## 0. 已落地的应用：网桥链路认证（P0，真机 + 仿真双验收）

跨维度/无限距离 modem 只当网桥（[poc/mc/ender-bridge.lua](poc/mc/ender-bridge.lua)），网桥的链路层现在是
**fail-closed 且逐帧认证**的——这是本安全层第一个真正投入使用的部件：

| 机制 | 实现 | 验收证据 |
| --- | --- | --- |
| PSK 必需（缺省 fail-closed） | `bridge_psk`，缺失时 `BRIDGE_FAIL_CLOSED no_psk` 且**零转发** | `bridge-wrongpsk`：两侧 `paired=false relayed=0`，主机无法通信 |
| 双向认证握手 | HELLO = `Q|id|nonce_c|HMAC(k_hello)`；ACK = `A|id|nonce_c|nonce_s|HMAC(k_auth)` | 无 PSK 的攻击者 HELLO 被 `AUTH_FAIL bad hello` 拒绝、服务端不配对 |
| 会话密钥 | HKDF-SHA256(PSK, salt=nonce_c‖nonce_s, info=c2s/s2c) → 每方向独立键 | 两桥 `auth=psk paired=true` |
| 逐帧认证 | 帧 = `"S"|counter(4)|payload|tag(16)`，tag = HMAC(k_dir, …) | 真机：20 伪造帧全被丢弃（`unauth=31`） |
| 防重放 | 每方向单调计数器 + 64 帧窗口 + “未来帧”上限 | 真机：攻击者**抓到并原样重放** 16 帧 → `replay=13/16` 全拒 |
| 大小/策略 | `bridge_max_frame` 先于 HMAC 检查；ethertype 白名单（默认仅 IPv4+ARP）、可选源 MAC 白名单、广播限速 | 真机：4122 B 超大帧 → `size=1` |
| 实现隔离 | 网桥不 `require` 任何东西（SHA-256/HMAC/HKDF 内嵌并开机自检 KAT）；跑在**零 rpv 文件**的电脑上 | 两个独立进程/电脑，攻击场景下合法流量仍 `complete=true` |

复现：`pwsh -File poc\run-bridge.ps1 -Mode normal|wrongpsk`（CraftOS-PC）·
`pwsh -File poc\mc\run-mc.ps1 -Scenario endbridgesec -Target fabric`（真机，含攻击者 #25）。

### 0.8 网桥的环路防护与冗余（P5，STP-lite）

跨维度网桥可以**串联多跳**（每跳仍是"独立程序 + 点对点加密链路"），但同一对 LAN 之间有两条桥路径就成环。
网桥程序内置了简化 STP：

| 机制 | 规则 |
| --- | --- |
| 指定桥选举 | 每台桥在**两侧**定期广播 claim（LAN 侧明文、链路侧走同一套密封帧；控制以太类型 `0x88B6`，永远绕过 ethertype 白名单）；**同一 LAN 段上 id 最小的桥**成为该段的指定桥 |
| 阻塞 | 在某个 LAN 段上听到更小 id → **该桥停止在这个 LAN 侧两个方向的中继**；链路侧是点对点、**永不阻塞**（这正是"链式多跳"仍能工作的原因） |
| 撤销 | 链路对端静默超过 `bridge_stp_timeout`（默认 6 s）→ 该桥**撤回自己的 LAN 通告**（`STP_WITHDRAW`），把指定桥位置让给另一对桥 |
| 环路去重 | 按 `(入侧, 帧哈希)` 记近期中继帧（窗口 `bridge_dup_ttl`，默认 **0.5 s**）：环回帧毫秒级回到同一侧会被丢弃；而主机 ARP/ICMP **重传**字节相同但要 ≥0.5 s，正常放行（第一版把重传误判成环回，导致 ARP 永远完不成） |
| 故障模拟 | `bridge_selfstop_at=秒` 让网桥到点停止通告与中继（测试接管用） |
| 计数 | `STATS`/`BRIDGE_RESULT` 末尾追加 `stp= id= root= fwd= claims_tx= claims_rx= dup_drop= blocked=` |

**验收**（CraftOS-PC，全部 PASS）：`pwsh -File poc\run-stp.ps1 -Mode chain`（4 台桥**串联两跳**：
LAN-A→b1→link1→b2→LAN-B→b3→link2→b4→LAN-C，4/4 桥都有中继、端到端 ping + 900 B 通）；
`-Mode loop`（两对桥并联成环：每段各一台桥 `STP_BLOCK`，活跃路径 2/4 桥中继、端到端照常、无重复风暴）；
`-Mode failover`（根桥第 22 s 自停 → 对端 `STP_PEER_TIMEOUT`+`STP_WITHDRAW`+`STP_UNBLOCK`，待机对桥接管、**端到端在切换后恢复**）。

- 密码学原语：[poc/security/crypto.lua](poc/security/crypto.lua)（纯 Lua，9 项 KAT 全过）
- WPA2 结构：[poc/security/wpa.lua](poc/security/wpa.lua)（PSK→PMK、四次握手、密钥派生、AEAD、重放窗口）
- 演示节点：[poc/security/wpa-node.lua](poc/security/wpa-node.lua)
- 一键复现：[poc/run-crypto.ps1](poc/run-crypto.ps1)（KAT + 基准）、[poc/run-wpa.ps1](poc/run-wpa.ps1)（握手 + 数据 + 负例）
- 实测输出：[poc/out/crypto-report.txt](poc/out/crypto-report.txt)、[poc/out/wpa-normal-node71.log](poc/out/wpa-normal-node71.log) 等

---

## 0.5 控制面 AEAD（P1，已接入连接层）

`conn` 现在可以整体加密认证（`conn_secure=1` + `conn_psk=<hex|口令>`）：

| 部件 | 实现 |
| --- | --- |
| 握手认证 | SYN = `C|nonce_c|HMAC(k_ctrl,"SYN"|iss|nonce_c)`；SYN-ACK = `S|nonce_s|HMAC(k_ctrl,"SYNACK"|iss|nonce_c|nonce_s)`，`k_ctrl = HKDF(psk,"","rpv-conn-ctrl-v1")` |
| 会话密钥 | `k_c2s/m_c2s = HKDF(psk, nonce_c‖nonce_s, "rpv-conn-c2s"[-mac])`，`s2c` 同理（每方向独立加密键 + MAC 键） |
| 段格式 | `header(13) | ChaCha20(payload, nonce_dir, counter=seq) | tag(16)`；header 明文（含 seq/ack/win，被 tag 覆盖）；纯 ACK/FIN 也带 tag |
| 失败姿态 | 错误 PSK → 服务端 `CONN_SEC_SYN_REJECT`（不建连）；安全节点收到明文 SYN-ACK → `CONN_SEC_PEER_PLAINTEXT` + abort（fail-closed）；坏 tag → `CONN_SEC_AUTH_FAIL` 丢弃并计数 |
| 密码学来源 | 库模块 `poc/rpv/crypto.lua`（`poc/build-crypto.ps1` 从本目录 `crypto.lua` 生成，单一实现；库用户直接可用） |
| 实测开销 | CraftOS-PC 4.4 KB 经 `conn`：**0.837 s（明文）→ 1.383 s（安全）**，≈1.65×；与 ~215 KB/s 的纯 Lua 预算吻合 ⇒ 只适合控制流/中等传输 |

复现：`pwsh -File poc\run-m3-apps.ps1 -Scenario ftp -FtpTransport conn -ConnSecure psk|wrongpsk`（仿真）·
`pwsh -File poc\mc\run-mc.ps1 -Scenario ftp -FtpTransport conn -ConnSecure psk|wrongpsk -Target fabric`（真机）。
## 1. WPA2 的每个部件 → CC 上的实现

| WPA2 部件 | 作用 | 这里的实现 | 状态 |
| --- | --- | --- | --- |
| SSID + passphrase → PMK（PBKDF2-HMAC-SHA1, 4096） | 把口令变成主密钥 | PBKDF2-**HMAC-SHA256**，迭代次数可配 + **分片让出**（`yield_every`） | ✅ |
| 四次握手（ANonce/SNonce + MIC） | 双向确认、协商 PTK | M1→M2→M3→M4，MIC = HMAC-SHA256(KCK) 截 16 B | ✅ |
| PTK 派生（PRF-512） | 生成 KCK/KEK/TK | HKDF-SHA256(PMK, salt = MAC 对 ‖ nonce 对) → 64 B = KCK(16) ‖ KEK(16) ‖ TK(32) | ✅ |
| GTK 分发（AES key wrap） | 组播密钥 | ChaCha20(KEK 派生键) + HMAC-SHA256 标签 | ✅ |
| CCMP = AES-CCM（AEAD） | 数据加密 + 完整性 | **ChaCha20 + HMAC-SHA256（encrypt-then-MAC）**，帧 = PN(6) ‖ 密文 ‖ tag(16) | ✅ |
| 48 位 PN 重放保护 | 防重放 | 48 位 PN + 64 帧滑动窗口 | ✅ |
| 802.1X / EAP（企业版） | 每用户凭证 | 未实现；建议用"每节点密钥"达到类似效果（见 §4） | ❌ |
| 抵抗离线字典攻击 | WPA2 做不到 | 未实现（需要 PAKE，见 §4/§7） | ❌ |

**刻意不用 AES**：CC 没有加密库，纯 Lua 实现 AES-CCM 又慢又容易写错；ChaCha20+HMAC-SHA256 只需要 SHA-256 一个原语，
而且两者都能用 RFC 测试向量验证。Poly1305 是后续的性能优化（现在每帧 2.75 ms 已经够控制流用）。

## 2. 实测结果

**密码学 KAT（9/9 通过）**：SHA-256（空串 / "abc" / 56 字节）、HMAC-SHA256（RFC 4231 #1、#4）、
PBKDF2-SHA256（已知向量）、HKDF-SHA256（RFC 5869 #1）、ChaCha20 分组（RFC 8439 §2.4.2）、ChaCha20 往返。

**握手 + 数据（`run-wpa.ps1`，两个场景都 PASS）**：

```
normal   （双方口令一致）
  71 WPA_M2_MIC_OK → WPA_M3_SENT gtk_wrapped_bytes=48 → WPA_M4_MIC_OK → WPA_ESTABLISHED role=ap
  72 WPA_M2_SENT → WPA_M3_GTK_UNWRAP_OK → WPA_M4_SENT → WPA_ESTABLISHED role=sta
  71 WPA_DATA_RX pn=1/2/3 plaintext=secure data #1..#3      ← 密文被正确解出
  71 WPA_REPLAY_REJECTED pn=1 sender=72                      ← 原样重放被拒
  72 TEST_DONE ok=true             verdict=PASS

wrongpsk（站点用错口令）
  71 WPA_HANDSHAKE_FAIL stage=M2 reason=MIC mismatch (wrong passphrase?)
  72 WPA_HANDSHAKE_FAIL stage=M3 reason=bad M3 → TEST_DONE ok=false     verdict=PASS
```

## 3. 性能预算（CraftOS-PC 实测，真机会更慢）

| 操作 | 实测 | 说明 |
| --- | --- | --- |
| SHA-256 | ~180 KB/s（0.7 ms / 64 B 块） | 纯 Lua |
| HMAC-SHA256（64 B 报文） | 1.79 ms/次 | |
| ChaCha20 | ~215 KB/s | |
| 一帧 128 B 的 AEAD（加密 + MAC） | **2.75 ms → ≈364 帧/s** | 够控制流，不够大吞吐 |
| PBKDF2-SHA256 | **1.51 ms/迭代** | 256 迭代 ≈ 0.39 s；1024 ≈ 1.5 s；4096 ≈ 6.2 s |
| 一次握手 | ~1.5 s（PBKDF2 1024） | 一次性成本，建议缓存 PMK |

**两个必须记住的约束**：
1. 真机（CC:Tweaked）比 CraftOS-PC 慢，而且有 **"Too long without yielding" 看门狗** —— PBKDF2 必须分片让出
   （已实现 `yield_every`，每 N 轮 `os.sleep(0)`）；迭代次数要在真机上标定。
2. 数据面 ~364 帧/s 是"模拟器上、纯计算"的数字；真机受 tick（50 ms）与每 tick Lua 预算限制，
   安全层应设计成**低频控制面加密（WAN 隧道、指令）+ 高吞吐数据不加密或用链路隔离**。

## 4. 安全分析（诚实版）

**能防住**：被动窃听（密文）、帧篡改（MAC 失败）、重放（PN 窗口）、没有口令的人接入（握手失败）。

**防不住**（必须让使用者知道）：

| 威胁 | 说明 | 对策 |
| --- | --- | --- |
| **离线字典攻击** | 抓到一次握手就能离线爆破口令 —— WPA2-PSK 的固有问题，CC 里抓包更容易 | **每节点随机密钥**（32 B，离线生成）；长随机口令（≥20 字符）；将来上 PAKE |
| **无前向保密** | PSK 泄露 → 历史流量可解 | 引入 DH/PAKE（需评估纯 Lua 大数/椭圆曲线性能） |
| **DoS / 握手干扰** | 任何人都能灌包、伪造 ANonce、打断握手（类似 deauth 攻击） | 握手限速、超时重传上限、对失败源做黑名单 |
| **端点被攻破** | CC 的文件系统没有保护，拿到磁盘 = 拿到密钥 | 密钥不落盘（每次输入）或接受风险；标注威胁模型 |
| **旁路** | 如果攻击者能直接在 LAN modem 上注入帧，而安全层只包在 WAN 上，LAN 就没保护 | 明确保护边界：先做 WAN 隧道，LAN 依赖有线物理隔离 |

**推荐路线**：跳过"全网一个 PSK"，直接做 **每节点密钥 + 离线签发**（效果接近 WPA2-Enterprise，但不引入 RADIUS 复杂度）；
真要抗离线字典，再评估 PAKE。

## 5. CC 特有的熵问题（最容易踩的坑）

CC 没有 `/dev/urandom`，`math.random` 也不可靠。当前 `crypto.random_bytes` 是用
`os.epoch/os.clock/计算机 ID/时序抖动` 喂养的 SHA-256 DRBG —— **只适合演示和握手，不适合当长期密钥**。

正确做法：
1. **离线生成**：在真实 PC 上 `openssl rand -hex 32` 生成每节点密钥/种子，通过软盘、文件或 `settings` 导入；
   代码里已经留了 `crypto.load_seed_file(path)` 和 `crypto.add_entropy(s)` 两个入口。
2. 操作员输入一段长口令混入熵池（一次性）。
3. 把"信任根"留在游戏外 —— 这是目前最实用的方案。

## 6. 怎么接进 rpv

两种放法，建议先做第一种：

| 方案 | 位置 | 类比 | 适合 |
| --- | --- | --- | --- |
| **WAN 隧道**（推荐先做） | 网关之间的 WAN 链路上包一层 `wpa.seal/open`，网关上线时握手 | IPsec/WireGuard | 站点间流量，规模小、价值高；LAN 内网不管 |
| **链路层加密** | 在 rpv 的 `frame_send`/`handle_frame` 外面包一层，per-neighbor 会话密钥 | WPA2 本身 | 每段都不可信（无线/末影段）时 |

集成点很小：握手完成后拿到 `keys.tx/keys.rx`，把 `send_local_iface`/`handle_frame` 的载荷换成
`wpa.seal(...)` / `wpa.open(...)`，失败就丢包并计数。电台层的 PN 窗口可以直接替换 rpv 里现在的"无重放保护"。

## 7. 后续工作清单

| 优先级 | 工作 | 工作量 | 备注 |
| --- | --- | --- | --- |
| P0 | 集成到 WAN 隧道（先做站点间） | 2 天 | 复用现有握手代码 |
| P0 | 每节点密钥 + 离线签发工具（生成/导入/轮换） | 1–2 天 | 解决离线字典攻击的实际风险 |
| P1 | ChaCha20-Poly1305 替换 EtM（少一次哈希） | 1 天 | 需要实现 Poly1305（纯 Lua，130 位运算） |
| P1 | 握手加固：超时/重传上限/限速/黑名单 | 1 天 | 抗 DoS |
| P1 | rekey（PTK 轮换，含 PN 重置语义） | 1 天 | 长连接必需 |
| P2 | PAKE（SAE-lite / SRP-6a）可行性评估 | 3–5 天 | 取决于纯 Lua 大数/椭圆曲线性能，先做基准 |
| P2 | 集成到 LAN 侧（每段一个 PSK 或每节点密钥） | 2 天 | 只有无线/末影段真的需要 |
| P2 | 安全日志与审计（握手失败、重放、MAC 失败计数） | 0.5 天 | 并入 `routectl` |
| P3 | 与 rednet 兼容层共存（旧程序怎么办） | 1 天 | 老程序无法签名 → 只能隔离到单独频道 |

## 8. 一句话总结

WPA2 的**结构**（PSK 派生 + 四次握手 + PTK/GTK + AEAD + 重放窗口）在 CC 上完全能实现，本地已经跑通；
但 WPA2 的**信任模型**（一个口令全网共用、可离线爆破、无前向保密）不适合 CC ——
落地时换成"每节点随机密钥 + 离线签发"，并优先只保护 WAN 隧道。
