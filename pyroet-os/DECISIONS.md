# Pyroet OS 决策记录（DECISIONS）

- 位置：`pyroet-os/DECISIONS.md`（P0 产物，本目录目前只有文档、工具与清单，无运行时代码）
- 仓库：`cc_tweaked`，分支 `main`；实测日期 2026-10-28
- 数据口径：本文所有字节数都是在本机 work tree 上用只读命令实测的，不取估算值；估算项显式标注“估算”。取数命令见 §4.4。
- 作用：把已由用户拍板的硬约束、以及据此定下的技术取舍写死在这里；后续 P1（vendor rpv 子集）与 P2（kernel/runtime）实现都以本文为准，改结论必须改本文。

## 0. 背景与硬约束

0.1 目标形态：Minecraft CC:Tweaked 的**掌机**（Pocket Computer），屏幕 **26x20** 字符。不是台式机、不是服务器。
0.2 来源：`pyromputer-os/`（原 unixshell）的**重度裁剪硬分支**。实测基线：**233 个跟踪文件 / 5,553,921 B**（含构建产物与 dist 的 work tree 全量为 260 文件 / 6,546,071 B，不计入）。
0.3 硬分支的意思：`pyroet-os/` 与 `pyromputer-os/` **互不覆盖、互不合并、互不回灌**；原目录零改动（规矩同 `cardkey` → `itn-pass`）。上游修复只能逐条手动 cherry-pick（§6）。
0.4 用户已确认的五条硬约束：

1. **掌机无法挂载任何磁盘** → 系统与应用全部装在机身（CC 电脑存储配额 **1,000,000 B**），**没有 `/disk` 分层**，也不存在“插盘补功能”。
2. **不做中文** → CJK 字库与三件套一律不进方案：`pyromputer-os/fontdata/` **1,375,263 B（15 文件）**，`lib/cc_fonts.lua` **19,641**、`lib/cc_chinese.lua` **20,574**、`lib/cc_font_shards.lua` **24,882**（三件合计 **65,097**）。合计省下 **1,440,360 B**。
3. **要 rpv 联网**（软目标：尽量达成，不是上线硬门槛）——注意它与“砍 DNS 客户端”的张力，见 §3.3 与 §8。
4. **容量三层门禁（G1 起；唯一口径 = `pyroet-os/tools/sizecheck.py`）**：硬门禁 **3/5 MiB = 629,145 B**（`>629,145` = `SIZE_FAIL`，发版阻断）；目标线 **1/3 MiB = 349,525 B**（`349,525 < total ≤ 629,145` = `SIZE_WARN`，只提示不判死）；`≤349,525` = `SIZE_PASS`。另有独立判定的更新窗口 **镜像 + BACKUP_CAP(200,000) ≤ 900,000 B**（`WINDOW_OK`/`WINDOW_FAIL` 行，见 §7.1/§8.4）。超目标线不判死，但必须报差额（MARGIN 行）。
5. **类 Android 的分层与权限模型**（§1）。

0.5 **网络定位（显式声明，不再动摇）**：**本项目不做设备入网鉴权**。网络层只做**连接**（rpv/UDP，
有界超时、重试）与**加密**（crypto/wrps 之于报文），**不做准入判定**——没有 radius/EAP 式的
认证服务器、没有"设备/终端 id 白名单"门禁、不要求凭证才能联网，也不存在"没有许可证就断网"的
分支。需要"这张盘能装几次"的那类额度属于装机侧（见 `itn-pass/` 的装机/分发凭证），与本系统的
联网能力**没有耦合**：网络通不通只取决于链路与配置，不取决于任何凭证状态。

## 1. 架构分层

1.1 启动链（自上而下，单向）：

```
startup.lua                       ROM 只会自动跑这一个文件，内容必须很小
  └─ bootloader                   镜像校验（SHA256）/ 单树 /system + journal 决策表 / 试启动与回退 / 首启向导
       └─ kernel + service manager  模块加载、服务注册与依赖、生命周期、权限仲裁
            └─ app runtime          每 app 一个 coroutine + 权限域 + 资源配额
                 ├─ system apps     Launcher / Settings / Net / Files
                 └─ user apps       与系统应用同一套包格式（§5）
```

1.2 **写死三条现实约束**（这三条决定了后面所有设计，不允许在实现时“乐观假设”）：

(a) **CC 没有真进程**。整机只有一个 Lua VM，并发单位只有 `coroutine`；所谓“沙盒”是 **API 收口**（把 `fs` / `net` / `peripheral` / `redstone` / `http` 换成受控代理），**不是内存隔离**。因此：app 崩溃用 `pcall` 边界隔离；app 死循环**无法抢占**，只能靠“app 必须在关键路径上 `os.pullEvent`/yield”的约定 + watchdog 记账，纯 CPU 死循环只能重启整机。这是能力上限，文档写明，不做超出该上限的承诺（例如“杀进程”）。

(b) **权限 = capabilities**。固定集合（9 项）：`fs.read`、`fs.write`、`net.rpv`、`net.rednet`、`redstone`、`peripheral`、`http`、`input`、`terminal`。三件套语义：**manifest 声明** → **首启确认**（用户点一次，落盘到权限库）→ **运行时拦截**（每次 API 调用查当前 app 的 cap 集；拒绝时返回 `nil, "EPERM"` 而不是抛错，避免 app 只能靠 pcall 活下去）。权限仲裁只有一处在 kernel 的 service manager，runtime 不得自授。后两项（`input` / `terminal`）是 O3 追加的 UI 能力，语义、拒绝路径与兼容策略见 §19；追加在表尾，旧决策文件按前缀解析不受影响。

(c) **系统应用与用户应用同一套包格式**。没有“特权格式”。Launcher/Settings/Net/Files 也是 `.app`（§5），只是它们的 cap 由镜像内的系统清单授予，且**只能用 OTA 换**（用户不能手装系统 app，否则等于绕过 OTA 的完整性保证）。

## 2. 安装与更新 = 网络 OTA（因为掌机无盘）

2.1 为什么只能是 OTA：约束 0.4.1 —— 不能挂载磁盘，就没有“插盘装系统”这条退路；机身盘只有 1,000,000 B，也放不下“安装器 + 安装包 + 系统”三份。唯一入口是**网络 + 手工粘贴的极小 bootstrap**。

2.2 **机身预置/手工粘贴一个 ≤4 KB bootstrap**（superseded by P6-3：`recovery/bootstrap.lua` 已改为 `PYROET-FLASH/2` 文件集推送，目标 `<root>/system`，无槽无指针，见 §12；下文为历史记录，不要再据此实现；预算 4,096 B，估算，P1 落地后由 `tools/sizecheck.py` 复核）。职责必须极小：纯 **rednet** 最小接收器，**不 require rpv**（rpv 子集本身就有 125 KB 量级，且一旦 rpv 坏了就没有修复通道）。只做五件事：`rednet.open`、向分发中心发 `HELLO`、收 `META`/`CHUNK`/`COMMIT`、按 offset 把 chunk 原样写入**非活动槽**、写完把 `/boot.slot` 原子指向新槽（**不写** `/boot.ok`）。**不解析镜像格式**（解析是 bootloader 的事），**不判断系统能否启动**（试启动与回退是 bootloader 的事），这样 bootstrap 才能在系统镜像损坏时仍然可用（它是唯一的救援通道）。

> **superseded by P6-design（P6-2，2026-10-29）**：下面 2.3–2.8 描述的“双槽整镜像”
> 已被 `pyroet-os/P6-design.md` 的“单树 `/system` + 三态 journal + 差异备份”取代，
> 代码落点为 `boot.lua` / `kernel/ota.lua` / `startup.lua`，现行口径见 **§13**。
> 本节内容**作为历史保留**（记录当时的空间账与取舍理由），不要再据此实现。

2.3 **槽位布局（固定路径，不做目录 rename）**（superseded by P6-design，见 §13）：

| 路径 | 内容 | 由谁写 |
| --- | --- | --- |
| `/slots/a/`、`/slots/b/` | 槽内容（整棵系统镜像） | bootstrap（安装/更新时写非活动槽） |
| `/boot.slot` | 指针，正文只有 `a` 或 `b` | bootstrap（更新时指向新槽）；bootloader（回退时改写） |
| `/boot.ok` | 提交标记：版本 + 整镜像 sha256 + 时间戳 | 新系统在健康检查通过后写（bootloader/kernel） |
| `/slots/<x>/.tries` | 该槽连续试启动次数（整数，缺失视为 0） | bootloader 每次试启动 `+1` |

- **固定路径**：`/slots/a`、`/slots/b` 永不改名、永不互换；哪个是活动槽只由 `/boot.slot` 决定，目录名不带版本号。
- `/boot.slot` 的写入必须原子：写 `/boot.slot.tmp` → 删旧 `/boot.slot` → `fs.move("/boot.slot.tmp", "/boot.slot")`。CC 的 `fs.move` 不能覆盖已存在的目标，必须先删（同 `rpv1/poc/apps/hosts.lua:243` 的 `.bak` 挪移注释）。
- `/boot.ok` 是**唯一**的已提交凭据：槽里有完整镜像但无 `/boot.ok` = 待验证的新系统，只能试启动。
- 实现落点：`pyroet-os/boot/slots.lua` 负责指针 / 提交标记 / `.tries` 的读写，`bootloader.lua` 只按这些状态决定正常启动 / 试启动 / 回退。

2.4 **稳态只保留一份系统**（superseded by P6-design，见 §13）：新系统健康检查（§2.7）通过 → 写 `/boot.ok` → **立即删除另一个槽**（连它的 `.tries` 一起删）。旧槽只在新系统被确认能起来之前保留；任何长期双份的做法都不进方案（空间账见 §2.8）。

2.5 **拉取与落盘流程（顺序即安全保证）**（superseded by P6-design，见 §13）：

1. bootstrap 读 `/boot.slot` 确定活动槽，目标槽 = 另一个（`a` → 写 `b`，`b` → 写 `a`）；读目标槽 `/slots/<target>/.tries`。
2. 向分发中心请求 `META`（镜像版本、总字节、整镜像 SHA256、chunk 大小、逐块 SHA256 表）。
3. 循环请求 `CHUNK i` → **校验该块 SHA256** → 直接流式写入**非活动槽**的对应 offset（`fs.open(path,"wb")` 后 seek 到 offset）。这就是流式直写非活动槽：不产生第三份完整拷贝，理由见 §2.8。
4. 全部收齐 → **整镜像 SHA256 校验** → 通过才继续；不通过 → 目标槽作废（删掉已写内容，`/boot.slot` 保持不变），旧槽照常启动。
5. 通过后把目标槽 `.tries` 归零，写 `/boot.slot` 指向目标槽（原子写见 §2.3），**不写** `/boot.ok`。此刻是唯一存在两份镜像的窗口：旧槽保留到新系统被健康检查确认。
6. 重启 → bootloader 按 `/boot.slot` 进入目标槽的**试启动**（§2.6）。
7. 断点续传不做位图：重连后从第 0 块重算（每块独立 SHA256，已写入的块重发即可覆盖），代价是流量而不是正确性——掌机上这比维护持久化位图更安全。
8. 断电安全性：步骤 3–5 期间断电时 `/boot.slot` 尚未指向新槽，旧槽仍是活动槽；指针写入本身原子，不会出现指针指向半个镜像的情况。

2.6 **试启动与回退（bootloader 行为，写死）**（superseded by P6-design，见 §13）：

- 只认 `/boot.slot`：读指针（值只能是 `a`/`b`）→ 启动 `/slots/<x>`。
- 该槽**有** `/boot.ok` → 直接启动（稳态路径），不计数。
- 该槽**无** `/boot.ok` → **试启动**：先把 `/slots/<x>/.tries` +1 落盘，再启动（先落盘，断电不丢计数）。
- `.tries > 2` → 判坏槽：回退到另一个存在且带 `/boot.ok` 的槽（原子改 `/boot.slot`），并**删除坏槽**。两个槽都不合格 → 进 bootstrap 救援通道（§2.2）。
- 回退不是可选清理：坏槽删除与指针改写是同一次回退动作的两半，否则坏槽会一直占着空间。

2.7 **健康判定（历史口径：write-through 的 30 秒观察窗，已被 P6 取代，见 §13）**

> **下面这份四条清单是 P6 之前的双槽口径，已作废，仅作历史记录。**
> 现行口径只有两处：§13.2（`startup.lua` 在**首帧绘制后**写全局 `/boot.ok`
> `PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..`，不等待 30 秒）与 §13.7（回滚靠
> `/boot.tries > 2`，`MAX_TRIES = 2`）。取舍理由：文件集模型下"启动后 30 秒内断电"会让本次更新
> 白测一轮；3 次试启动已能拦住坏版本，回滚成功后写 `state=rolledback` 墓碑供下次开机清理。

历史四条（**均已不适用**）：内核起来；service manager 起来；UI 首帧绘制完成；连续 30 秒无未捕获错误。

**仍然成立的一条**：rpv 网络不是 ready 的必要条件——网络失联不得导致永远无法提交，否则一台断网掌机会卡在试启动、最终回退掉一个本来可用的系统。

2.8 **空间账：单活 + 更新期暂存（实测口径，镜像按 §4.2 的 242,133 B）**（superseded by P6-design，见 §13）：

| 策略 | 峰值占用 | 判定 |
| --- | --- | --- |
| 稳态（单活槽 + `/boot.slot` + `/boot.ok`） | 1 × 242,133 = **242,133** | 采用（余 757,867） |
| 更新期（新镜像流式直写非活动槽） | 2 × 242,133 = **484,266** | 采用（余 515,734） |
| 更新期 + 第三份完整暂存 | 3 × 242,133 = 726,399（242 KB 口径尚可），但 3 × 349,525 = **1,048,575 > 1,000,000** | **永久否决**：到 1/3 MiB 档就爆配额（超 48,575） |
| 压缩单份 + 运行时解压 | 1 × 压缩体 + 解压缓冲 | 否决：CC 无 zlib，运行时解压 240 KB 镜像要吃整块内存，掌机内存与停机时间都不可接受 |
| 两槽只存差分 | 1.5 槽量级 | 否决：diff/合并 + 双侧校验的复杂度和校验面，在 <350 KB 的镜像上没有收益 |

结论：**稳态 1 × 镜像、更新期 2 × 镜像**；流式直写非活动槽，**硬性禁止第三份完整拷贝**（这是唯一会因为配额上限而翻车的点，写进验收项）。chunk 常驻缓冲控制在 ≤32 KB（具体值 P1 按 rpv/rednet 单包 MTU 实测后定）。

## 3. rpv 子集

3.1 **保留 9 个模块**（实测字节，逐文件，见 §4.4 命令）：

| 模块 | 字节 | 作用 |
| --- | --- | --- |
| `node` | 56,414 | 节点主体：接口、路由、收发、定时器 |
| `conn` | 30,317 | 面向连接/重组（流式与大消息） |
| `crypto` | 12,329 | SHA256 / ChaCha20 / PSK（**OTA 逐块校验要靠它**） |
| `ip` | 8,689 | IPv4 头、分片、校验和 |
| `arp` | 3,455 | 邻居解析 |
| `udp` | 3,120 | UDP |
| `route` | 2,751 | 路由表 |
| `util` | 2,120 | 通用工具 |
| `link` | 1,923 | 链路层（rednet 适配） |
| **小计** | **121,118** | |

另**必带** `rpv/loader.lua` **4,279 B**（“外部程序唯一需要加载的文件”，负责按依赖顺序加载全部模块）；其 `MODULES` 表在 **`pyromputer-os/rpv/loader.lua:34`**：
`local MODULES = { "crypto", "util", "ip", "route", "arp", "link", "icmp", "udp", "conn", "fabric", "wan", "services", "dv", "nat", "mcast", "qos", "wansec", "compat", "topo" }`
→ 改为 **9 项（含 `node`）**：`{ "crypto", "util", "ip", "route", "arp", "link", "udp", "conn", "node" }`（P1 实装把上游分开的 `local NODE_MODULE = "node"` 并进了 `MODULES`，这张表因此是镜像内容的唯一真相，见 `pyroet-os/rpv/loader.lua:48`）。**loader 只在表内文件都存在时可用，删模块必须同时改表**，否则启动即报错。
→ 含 loader 的 rpv 实装量 = **131,590 B**（121,118 + 4,279 = 125,397，实装多出 **6,193 B**，差额是 subset 守卫与英文化注释，见 `pyroet-os/rpv/util.lua` 的 `subset_missing`）。

3.2 **被砍模块（11 个，合计 117,059 B）**：`services` 26,456 / `wan` 13,346 / `topo` 11,917 / `dv` 11,830 / `nat` 11,698 / `wansec` 10,763 / `fabric` 9,286 / `mcast` 8,168 / `qos` 7,272 / `icmp` 4,162 / `compat` 2,161。
另有两个 rpv 文件也不进方案：`node-start.lua` 4,116（rpv 自己的 bootstrap，绑定 `role.txt` + `startup.lua` 布局与崩溃自重启，由 Pyroet OS bootloader 取代）、`MERGE-rpv.md` 12,541（文档）。

3.3 **代价（必须写清，不能只在代码里默默少功能）**：

- **没有 DNS 客户端**：`M.lookup` / `M.hosts_load` / `M.dns_register` 全在 `services.lua` 里（`services.lua:478/521/538`）。`node.lua:634` 是 `function n:lookup(name, timeout, cb) return M.lookup and M.lookup(self, name, timeout, cb) end`——砍掉后 `n:lookup` **直接返回 nil**。⇒ 一律用**静态 hosts**（`cfg/hosts.conf`，由 Pyroet OS 的 net 服务在启动时注入，必要时自己给 rpv 表补一个 `M.lookup`）。
  - 好消息：`node.lua:598` 是 `if M.services_setup then` 保护，砍掉 services **不会**让 `node:setup()` 崩，只是跳过 DHCP/名字服务。
- **没有 DHCP 服务端/客户端**（`services.lua` 的 `dhcp_*` 全无）⇒ 静态 IP，写入 `cfg/net.conf`。
- **没有 NAT / DV / QoS / mcast / icmp / wan ACL / wansec / fabric / topo / compat** ⇒ 掌机只做**端点**，不做路由/NAT/网桥；不响应 ping；没有多跳拓扑发现；没有 rpv1 兼容层。与 `rpv1/poc` 的路由器/热备等应用**不共享代码路径**。

## 4. 尺寸预算

> 门禁语义（三层，G1 起）：`>629,145` = **SIZE_FAIL**（硬门禁 3/5 MiB）；`349,525 < total ≤ 629,145` = **SIZE_WARN**（超出目标线 1/3 MiB，只提示）；`≤349,525` = **SIZE_PASS**；另独立判定更新窗口 `total + BACKUP_CAP(200,000) ≤ 900,000`（`WINDOW_OK`/`WINDOW_FAIL`）。工具：`pyroet-os/tools/sizecheck.py` + `pyroet-os/install.set`，两者是唯一口径。下面 §4.2 表里的 262,144 / 349,525 两列是 P0 估算期的历史口径，保留作对照，不再参与判定。

4.1 **实测基线（原件，全部为真实字节）**：

| 对象 | 文件数 | 字节 | 处置 |
| --- | --- | --- | --- |
| `pyromputer-os/` 全树（跟踪） | 233 | 5,553,921 | 只作对照，不进方案 |
| `usr/psh.lua` | 1 | **353,669**（8,568 行） | **单文件就超 1/3 MiB（超 4,144）→ 不复用**，新写 `pshx` |
| `usr/` 合计 | 13 | 374,532 | 其中 `psh 353,669` + `dcnet-tabs.lua 1,235` + `usr/cmd/` 11 文件 19,628 |
| `rpv/` 合计 | 23 | 259,113 | 只取 §3.1 的 9 模块 |
| `rpv/services.lua` | 1 | **26,456**（562 行） | **仅在保留 DNS 客户端时计入**（见 §8.1） |
| `lib/` 合计 | 57 | 767,444 | 精简后只留 ~10 个助手文件 |
| ├ `lib/pkg.lua` | | 88,038 | 必删（介质包仓库模型，无盘不适用） |
| ├ `lib/man.lua` | | 79,771 | 必删（帮助文档，中文/英文文档不进镜像） |
| ├ `lib/xfer.lua` | | 57,010 | 必删（磁盘传输） |
| └ `lib/bios.lua` | | 45,311 | 必删（ROM 替换/引导层，与 bootloader 冲突） |
| `lib/` 中 CJK 三件 | 3 | 65,097 | 必删（约束 0.4.2） |
| `fontdata/` | 15 | 1,375,263 | 不进方案（约束 0.4.2） |
| `etc/` | 10 | 13,545 | 现网配置参考；Pyroet 目标 8 KB 量级 |
| `startup.lua` / `firstboot.lua` / `netd.lua` / `pkgserver.lua` | 4 | 56,303 | 全部不复用（20,101+23,569+6,717+5,916） |

4.2 **新系统估算表**（除实测行外均为**估算**，P1/P2 落地后逐行替换为实测）：

| 组件 | 估算字节 | 依据 |
| --- | --- | --- |
| bootloader（校验/槽位/回退/首启） | 8,192 | 8K |
| kernel + service manager | 18,432 | 18K |
| app runtime（coroutine/cap/配额） | 22,528 | 22K |
| UI toolkit（26x20 布局/控件/输入） | 14,336 | 14K |
| system apps（Launcher/Settings/Net/Files 4 个） | 16,384 | 16K |
| rpv 子集 9 模块 | **121,118** | 实测 §3.1 |
| rpv loader（改 MODULES） | **4,279** | 实测 |
| `services.lua`（仅保留 DNS 时的预留行） | **26,456** | 实测 |
| lib 精简（path/fs/字符串/时间等 ~10 文件） | 28,672 | 28K |
| cfg（`cfg/*.conf`，对照 etc 实测 13,545） | 8,192 | 8K |
| **合计（含 services + loader + cfg）** | **268,589** | 见下方对账 |

**与任务书 ≈253,574 的对账**（数字必须能对上，否则预算表不可信）：

- 253,574 = `(8+18+22+14+16+28) × 1000` + `121,118` + `26,456` → 即**十进制 K、未计 cfg、未计 loader**。
- 同样六项按 1024 计：108,544 + 121,118 + 26,456 = **256,118**（+2,544）。
- 再加 cfg 8,192 → **264,310**（**已 > 262,144，落在 WARN 档**）。
- 再加 loader 4,279 → **268,589**（上表合计）。

⇒ **只要保留 services（DNS 客户端），任何口径都进不了 1/4 MiB**；按 §3 砍掉 services 后的实装量 = 268,589 − 26,456 = **242,133 B → SIZE_PASS，余量 20,011 B**。这是 §8.1 需要拍板的直接原因。

**两种口径（`services.lua` 去留未定，见 §8.1）**：

| 口径 | 合计 | 1/4 MiB = 262,144 | 1/3 MiB = 349,525 |
| --- | --- | --- | --- |
| 保留 `services.lua`（DNS 客户端） | **268,589** | **WARN**（超 6,445） | **PASS**（余 80,936） |
| 砍掉 `services.lua`（静态 hosts） | **242,133** | **PASS**（余 20,011） | **PASS**（余 107,392） |

推导（1024 进制，不四舍五入）：六项组件 `(8+18+22+14+16+28) × 1024 = 108,544` + rpv 实装 `121,118` + cfg `8,192` + loader `4,279` = **242,133**；再 + `services.lua` `26,456` = **268,589**。**两种口径都只算 1 × 镜像**：更新期另有一份非活动槽，见 §4.3 与 §2.8。
- **rpv 实装量修正（§3.1 实测）**：rpv 子集 + loader 实际是 **131,590 B**，不是上表的 `121,118 + 4,279 = 125,397`；差额 **6,193 B** 是 subset 守卫与英文化注释。按 131,590 重算 1024 口径：`108,544 + 131,590 + 8,192` = **248,326**（仍 PASS，余 13,818）；再加 `services.lua` `26,456` = **274,782**（进 WARN 档，仍低于 349,525 红线）。本节表格的估算值保留不动，以这一行为实测口径。

4.3 **槽位预算（见 §2.8）**：稳态 = 1 × 镜像；更新期 = 2 × 镜像；**第三份完整拷贝永久否决**。
- 1 × 242,133 = **242,133**（余 757,867）；1 × 349,525 = 349,525（余 650,475，仅红线口径）
- 2 × 242,133 = **484,266**（余 515,734）
- 2 × 262,144 = **524,288**（余 475,712）
- 2 × 349,525 = **699,050**（余 300,950，即使踩到 FAIL 上界也装得下）
- 3 × 349,525 = 1,048,575 **> 1,000,000** → 超配额 48,575，故第三份完整暂存永久否决（任何口径下都不得出现）

4.4 **取数命令（只读，可复现）**：

```powershell
git ls-files pyromputer-os | Measure-Object -Line                        # 233
Get-ChildItem pyromputer-os -File -Recurse | Measure-Object Length -Sum  # 5,553,921
(Get-Item pyromputer-os/usr/psh.lua).Length                              # 353,669
Get-ChildItem pyromputer-os/rpv -File | Sort-Object Length -Descending   # 逐模块字节
Get-ChildItem pyromputer-os/lib  -File -Recurse | Measure-Object Length -Sum  # 767,444
Get-ChildItem pyromputer-os/fontdata -File -Recurse | Measure-Object Length -Sum  # 1,375,263
python pyroet-os/tools/sizecheck.py                                      # 门禁判定
```

## 5. 应用包格式

5.1 形态：机身目录 `<name>.app/`，内含 `manifest.lua` + `main.lua`（可改名，见 `entry`）+ 可选 `res/`（图片/字符串等静态资源，只读）。

5.2 `manifest.lua` 返回一个表，字段**只有这五个**（多一个都不认，避免格式漂移）：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string | 唯一标识，必须等于目录名（不含 `.app`） |
| `version` | string | `MAJOR.MINOR.PATCH`，安装器只比较、不解析语义 |
| `capabilities` | table of string | 只能取自 §1.2(b) 的 9 个 cap，未知 cap 直接拒绝安装 |
| `entry` | string | 入口文件名，默认 `"main.lua"` |
| `size` | integer | 包内字节总和，**不含 `manifest.lua` 自己**（文件无法包含自己的最终长度）；安装前核对，不符即拒绝（口径见 §16.3） |

5.3 安装器校验：先比 `size`，再对**每个文件**算 SHA256（值来自分发清单）并与清单比对，最后对整包再算一次；任何不一致 → 拒绝安装且不落盘（先写 `.staging/` 再 move；改版是“先删旧目录再 move”，因为 CC 的 `fs.move` 不能覆盖已存在目标——与 §2.3 的 `/boot.slot` 原子写同一约束）。运行时启动前再验一次 `entry` 的 SHA256，防止落盘后被改。

5.4 **与 `pyromputer-os` 的 `pkg` / `.pkgsys` 不兼容**（硬分支，两边互不读取）：`pyromputer-os/lib/pkg.lua:324` 有 `local PKG_SYS_MARKER = ".pkgsys"`，那是**“介质上的系统模块仓库”**模型（`pkg.lua:301` 注释：携带 `.pkgsys` 的介质被挂载），依赖可挂载磁盘与 `/disk` 分层——掌机没有磁盘（约束 0.4.1），这套模型整体不成立。因此：扩展名、目录布局、清单字段、校验方式**全部不同**，`pyroet-os` 不读 `.pkgsys`，`pyromputer-os` 也不认 `.app`。任何“让两边兼容”的需求都应被拒绝，并指向本条。

## 6. 迁移规矩

6.1 **不合并、不回灌**：`pyroet-os/` 的改动不得写回 `pyromputer-os/`；禁止 `git merge` / `subtree` / 整目录 vendored 同步。原目录零改动是硬规矩。
6.2 **不整目录复制 rpv**：只按 §3.1 逐文件复制 9 模块 + loader，复制后把“源 commit + 复制的文件清单”记进 `pyroet-os/CHERRY-PICK.md`。
6.3 **上游修复 = 逐条手动 cherry-pick**：每条都要先判断“该修复在删减后的模块里是否还成立”（例如只影响 `nat`/`wan` 的修复直接跳过），再决定是否落地；落地后在 **`pyroet-os/CHERRY-PICK.md`** 记：上游 commit / 涉及文件 / 是否适用 / 落地方式（原样/改写/跳过 + 原因）/ 日期。该文件 P1 创建，本 P0 不创建。
6.4 **目录边界**：只在 `pyroet-os/` 下改文件；不得触碰 `pyromputer-os/`、`rpv1/`、`cardkey/`、`itn-pass/`、根 `README.md`、CI 配置。

## 7. 验收指标

7.1 **尺寸三层门禁 + 更新窗口**（唯一口径 = `python pyroet-os/tools/sizecheck.py`）：`>629,145`（硬门禁 3/5 MiB）→ `SIZE_FAIL`（exit 1，发版阻断）；`349,525 < total ≤ 629,145`（超出目标线 1/3 MiB）→ `SIZE_WARN`（exit 0，只提示）；`≤349,525` → `SIZE_PASS`（exit 0）。**更新窗口独立判定**：`total + backup_cap ≤ 900,000` → `WINDOW_OK sum=.. limit=900000`；超出 → `WINDOW_FAIL total=.. cap=.. sum=.. limit=900000` 且 exit 1（`--backup-cap` 默认 200,000；`SIZE_FAIL` 时也照常打印 WINDOW 行）。`install.set` 缺路径 → ERROR（exit 2）。**超目标线不判死，但必须报差额**（工具输出 MARGIN 行）。为什么从 349,525 放宽到 629,145，见 §8.4。
7.2 **26x20 布局自检**：所有系统界面必须在 26x20 内完整可用；硬规则——标题行 1 行、内容区 2–19 行、状态行 20 行、任何文本不超 26 列、**不允许横向滚动**；更小尺寸（如 26x20 以下的 monitor）降级为单行状态。每个系统 app 自带一个 `layout_selftest()`，CI 里跑纯函数校验（不依赖真实终端）。
7.3 **低 TPS（掉刻）**：TPS < 20 时 app 切换不丢事件、网络操作有界超时（用 tick 计数或 `os.epoch` 截止时间，**不用** `os.sleep` 硬等），切换前后 cap 与配额不泄漏（app 退出必须回收 coroutine、socket、buffer）。
7.4 **OTA**（P6-2 口径，取代按槽整镜像；历史见 §2.3–2.8 与 §11.3–11.5 的 superseded 标注）：断点续传（重连从第 0 块重算并覆盖写）、逐块与整镜像校验、试启动计数 `/boot.tries`、`tries > 2` 回滚到 `/update.backup` 的旧字节并写 `rolledback` 墓碑；校验失败/断电 → `/system` 与 `/boot.ok` 都不动（回滚有效）；连续 3 次失败不锁死设备（bootstrap 仍可用）。健康判定见 §2.7（rpv 网络不是必要条件）。

## 8. 待拍板 / 已知分歧（需要用户确认）

8.1 **`services.lua`（DNS 客户端）去留**——直接决定档位：砍 = **242,133 · PASS**（余 20,011）；留 = **268,589 · WARN**（超余量目标 6,445）。建议按 §3 砍，用静态 hosts。
8.2 **“要 rpv 联网”与“砍 DNS”的张力**：软目标下是否接受“只有静态 hosts、无域名解析”算达成联网？建议接受（静态 IP + hosts 已能跑 TCP/UDP 端点），并把“DNS 客户端”列为 OTA 后可选模块（但那会再吃 26,456 B）。
8.3 **OTA bootstrap 的信任边界**：bootstrap 走**裸 rednet**（不依赖 rpv/crypto，才能在 rpv 损坏时救援），意味着 OTA 的传输层没有加密与身份认证，靠逐块 SHA256 + 分发中心频道约定保证完整性。是否接受“完整性有、机密性无”？
8.4 **门禁三层口径（G1 改定，2026-10-29）**：**硬门禁 = `≤629,145` B（3/5 MiB = floor(1,048,576×3/5)）**——`pyroet-os/tools/sizecheck.py` 的 `--budget` 默认值，`>629,145` 即 `SIZE_FAIL`（exit 1），不砍体积不能发版。**目标线 = 349,525 B（1/3 MiB = floor(1,048,576/3)）**——`--stretch` 默认值，落在 `349,525 < total ≤ 629,145` 是 `SIZE_WARN`（exit 0，**不判死**），报告里如实给出超出目标线的差额。**更新窗口 = 镜像 + `BACKUP_CAP` ≤ 900,000 B**——`--backup-cap` 默认 200,000（OTA 换槽期间保留的备份副本），`WINDOW_OK`/`WINDOW_FAIL` 与尺寸判定**互相独立**（`SIZE_FAIL` 时也照常打印），超出即 exit 1；硬门禁顶格时 629,145 + 200,000 = **829,145**，距 900,000 还有 **70,855 B**、距机身 1,000,000 B 配额还有 **170,855 B**。

**为什么从 349,525 硬门禁放宽**：P6 的文件集更新会让 boot/ota 侧增约 **13.6 KB**，且要保留 `conn` 流连接层（30,317 B）——若硬门禁停在 349,525，“能联网（conn）”与“能更新（boot/ota）”会被逼成二选一，而门禁不该反过来替功能做取舍。介质/机身侧的真约束是**更新窗口 900,000**（镜像 + 备份）与**机身配额 1,000,000**；629,145 让最坏情况仍稳在窗口内，也不允许“两份完整镜像”那种 2×image 布局。**原 P4 口径“硬门禁 349,525、262,144 仅作 stretch 报告”作废**（262,144 从此不参与判定，只作历史对照）。G1 实测：`install.set` 25 条、TOTAL **359,305 B** → `SIZE_WARN`（超目标线 9,780 B，距硬门禁余 269,840 B）、`WINDOW_OK sum=559,305 limit=900000`。**已知遗留（G1 未改）**：`pyroet-os/system/settings.app` 的 `M.BUDGET` 与 §10.6 仍显示旧的 349,525 B——改它会同时改镜像字节数与 `tests/t_settings.lua` 的两条断言，故留给后续任务与 §10.6 一起同步。

## 9. 网络服务与静态解析

9.1 **静态 hosts 格式**（`pyroet-os/net/hosts.lua`）：文件 `/etc/hosts.conf`，每行 `<hostname> <ipv4>`，`#` 起到行尾为注释、空行忽略，CRLF 容忍。hostname 只允许 `[%w%.%-_]+`（ASCII 字母/数字、`.`、`-`、`_`）；IPv4 必须是四段点分十进制：每段 0..255、无前导零（`010` 拒绝、`0` 允许）、无符号无空格，`1.2.3` / `1.2.3.4.5` / `1..3.4` 一律拒绝。**整文件原子生效**：任何一行非法则整份拒绝，旧表保留并记 `HOSTS_BAD_FILE`（错误串带行号）。同名重复定义取**后出现者**（位置保留首次出现）。理由：能改 hosts 文件的人也能删它，半生效的表比旧表更难排查；而“跳过坏行继续”会让一个错字静默改变解析结果。

9.2 **注入 rpv 的方式（选择 + 理由）**：`net/hosts.lua` 同时提供 `M.hosts_load(node, path)`，签名与 `rpv/node.lua:246` 的 `M.hosts_load(self, hosts_path)` 一致，把 `hostname -> 整数 IPv4` 整表写进 `node.hosts`；net 服务在启动时调用它，并在自己按 mtime 的 5 s 重载里再次注入。**不设置 `node.cfg.hosts_file`**。理由：

- `cfg.hosts_file` 在子集里只会触发 `RPV_SUBSET_NO_SERVICES`（`rpv/node.lua:669-672`：`services_setup` 未 vendor），带不来 DNS，反而把“预期告警”留在正常开机日志里；
- rpv 的定时热重载（`rpv/node.lua:245-250`）只在 `M.hosts_load` 存在且 `cfg.hosts_file` 的 mtime 变化时触发；不设该键时它盯的是写死的 `hosts.txt`，不参与，于是重载时钟只有一个来源：`hosts:reload_if_changed(now)` + 服务用 `node:after()` 每 `hosts_interval` 秒检查一次；
- 解析器只有一份（`H.parse`），`node.hosts` 与 net 服务 / Net app 的视图不可能漂移——`rpv1/poc/apps/hosts.lua` 与 `services.lua` 两套表互不同步就是前车之鉴；
- `hosts_load` 仍然实现，是因为未来 cherry-pick `services.lua` 时 `node:tick` 会直接调用它，签名兼容即可零改动接入。副作用写清：该函数整表替换会清掉动态注册/查询缓存；子集没有这些缓存，故当前无影响。

9.3 **重载语义**：`H:reload_if_changed(now)` 先过最小间隔（默认 5 s，`min_interval` 可配），再比 `fs.attributes().modification`；变化才重新 `load`，整文件校验通过才替换并记 `HOSTS_RELOAD`；坏文件返回 `false, "bad file"` 且**不更新 mtime**——下一个间隔会重试，文件修好后无需重启。CC 的 mtime 是秒级，同一秒内的两次写算一次变化。

9.4 **`/etc/network.conf`**（`pyroet-os/net/service.lua`）：`key=value` 行，`#` 注释；支持 `ip`（必填）、`prefix`(24)、`gateway`、`iface_side`(back)、`iface_name`(NET)、`channel`(4100，1..65532，65533-65535 留给 rednet)、`mtu`(256，>=68)、`linktype`(wired)、`role`(host)、`hosts_file`(/etc/hosts.conf)、`probe_port`(47100)、`hosts_interval`(5)、`neighbor_ttl`(3600)，以及可重复的 `static_neighbor=<ip>,<mac>` 与 `static_route=<net>/<prefix> via <gw>`。未知键记 `NET_CONFIG_UNKNOWN` 且不降级（前向兼容）；坏值返回带行号的错误。

9.5 **启动顺序与降级**：`start` = 读配置 → `rpv.node_new(spec)` → `node:setup()` → 静态邻居写进 `node.arp.cache[ip] = {mac, expires=now+neighbor_ttl, static=true}` → 静态路由用 `rpv.route_add(..., "file")` → hosts 加载并注入 `node.hosts` → `node:bind(probe_port)` → `node:after(hosts_interval)` 挂重载。**邻居/路由必须在 `setup()` 之后**：connected 路由由 setup 建立，先加静态路由会被同前缀的 connected 覆盖。配置缺失/非法、rpv 缺失、setup 抛错、hosts 被显式配置却加载失败、probe socket 被拒，一律 `health="degraded"` + `NET_*` 日志，`start` 仍返回 true：kernel 的就绪判定接受 degraded（§2.7），一个配置错字不该让整机回滚。静态邻居的 `expires` 用 `neighbor_ttl` 而不是 rpv 的 120 s 缓存 TTL，避免静态条目 2 分钟后被 `arp_tick` 回收。

9.6 **无 DNS / 无 ICMP 的边界（写死）**：

- `node:lookup(name)` 仍是 **nil**（`M.lookup` 在未 vendor 的 `services.lua` 里）；静态 hosts 只服务 net 服务的 `resolve()` 与 Net app 的列表，`node.hosts` 只是给 rpv 未来接口准备好的表；
- 没有 ICMP：**没有 ping**。`probe(ip, port, payload, timeout)` 用 UDP 发一发一收，因此“端口无响应”“主机不在线”“被 ACL 丢弃”三者对外表现**只能是 timeout**；只有 `sendto` 直接失败（无路由/保留地址）才报 `unreachable`。`stats()` 分 `sent` / `received` / `timeouts` 三类，另有 `inflight` 供排查；`probe` 是异步句柄（`done`/`result`，可带回调），不发阻塞等待，符合 §7.3“不用 os.sleep 硬等”；
- 单次 probe 只能证明“这一发这一收在同一时刻可用”，不是连通性 SLA；连续探测由调用方自己节流。

9.7 **Net 系统 app**（`pyroet-os/system/net.app/`——P5b 曾移到 `examples/net.app/`，**G1 已加回镜像**，是 payload，见 §7.1/§8.4/§11.7）：manifest `name="net"`、`version="0.1.0"`、`entry="main.lua"`、`capabilities={"net.rpv","fs.read"}`。界面 26x20（标题 1、内容 2-19、状态 20），纯函数 `render(state, cols, rows)` 每行严格 pad/truncate 到列宽；`layout_selftest()` 无终端校验行数与列宽。**输入源是文件 `/etc/net.target`（一行 `<ip> <port>`，`#` 注释）**：O3 之后运行时虽然有 `input` cap，但它要求包自己声明、并且要有人驱动事件循环（启动链 commit 后没有调度者，见 §19.5）；Net app 至今不声明 `input`，`fs.read` 读一行仍是它唯一被授权的入口，未来换成按键只需再加一行声明与一个输入源。能力未声明 → `nil, "capability denied: net.rpv"`；已声明但宿主未提供 → `nil, "capability unavailable: net.rpv"`；两者都只在界面显示并写 `api.log`，不崩溃（`net.app.runtime` 测试覆盖两种分支）。

9.8 **尺寸与测试口径（P3 时点，P5b 曾把 net.app 转出镜像、G1 已加回，见 §8.4）**：新增 4 文件 = `net/hosts.lua` 11,488 B + `net/service.lua` 27,504 B + `system/net.app/main.lua` 15,493 B + `system/net.app/manifest.lua` 437 B = **54,922 B**；`install.set` 18 条（18 文件），`python pyroet-os/tools/sizecheck.py` → **TOTAL 257,650 / SIZE_PASS / MARGIN 4,494 B under stretch（91,875 under upper）**。离线套件 `pwsh -NoProfile -File pyroet-os/tests/run-tests.ps1` → **OFFLINE_PASS 1,116 / FAIL 0 / GROUPS 55**（P2 基线 522/38，新增 **594** 断言：hosts 140、net service 282、net app 172）。新增 lua 的非 ASCII 计数 0。本段数字保留为 P3 记录。

## 10. 桌面 / 设置 / 权限确认（P4）

10.1 **启动顺序（写死）**：`/startup.lua` 的顺序是 boot.begin → kernel → apps（`/apps` 与 `/system` 各 scan 一次，系统包在 `/system`）→ **权限表挂载（第 3c 步，任何 app 启动前）** → 系统服务 → `start_all` → 一次调度 → 首帧 → **读权限表 + 启动 launcher（第 7b 步）** → `boot.commit()` → loop。理由：首帧证明机器能起来，权限表在任何 app 启动前挂上才不会"先跑后问"；launcher 在 commit 前启动，但整段被 `pcall` 包住（`STARTUP_DESKTOP_FAIL`），启动器写错也绝不把好启动变成回滚环；launcher 缺失 → `STARTUP_LAUNCHER_MISSING` 并回退 hello（已在运行只记 `state=running`），不算失败。launcher 只拿一次时间片（`ctx.rt:step(launcher)`，`STARTUP_DESKTOP_TICK advanced=true`），不动其它已启动的 app 的时间片。

10.2 **权限确认语义**：`manifest.capabilities` 只是"声明"，不是授权。首次启动某个 app 时（`/etc/perms/<app>.cfg` 不存在）：`PERMS_PROMPT app=.. caps=a,b` → 逐项询问/判定 → 每条 `PERMS_DECISION app=.. cap=.. granted=true|false` → 写入 `cap=granted|denied` 单行格式。文件存在且合法 = 那就是决策，**不再询问**。坏文件（无法解析、未知 cap 名、非法值、空文件）→ `PERMS_BAD_FILE` + **全拒绝**，且**不重写文件**（坏决策文件绝不静默变成授权），下次启动按同样结果处理。cap 名合法但 manifest 已不再声明 = 陈旧行，忽略并记 `PERMS_PRUNE`（陈旧不是损坏，两者语义必须分开）。持久化路径固定 `/etc/perms/<app>.cfg`（`key=value`，`#` 注释，首行 `# PYROET-PERMS-1 app=<name>`）；`permissions.reset(app)` 删除该 app 的决策文件（测试与未来的 Settings 用），实例方法为 `P:forget(app)`，`P:prefetch(apps)` 只读不写、用于启动时把已有决策读进内存。

10.3 **拒绝不崩**：被拒绝的 cap 从 record 的 cap 集里移除，走与"未声明"完全相同的桩路径——`nil, "capability denied: <cap>"` + `APP_CAP_DENIED app=.. cap=..`，**不抛错**；app 仍然启动、仍然被调度、仍然能正常退出。权限表自身抛错 → `APP_PERMS_FAIL app=..` + **全拒绝** + 启动继续（fail closed）；持久化失败只记 `PERMS_SAVE_FAIL`，不阻断启动。

10.4 **权限询问仍不是交互式（O3 之后的口径，D1 不变）**："询问"仍是**注入的回调**（`permissions.new({ask=function(app,cap,info)})`），默认实现一律 `false`（fail closed）。O3 加了 `input` cap，D1 加了事件循环，但那不等于"启动时能弹问询屏"：询问发生在任何 app 启动之前、也在桌面循环开始之前，此时没有谁在跑事件派发器，`input` 也还没被任何包声明（§19.5、§20）。启动链的默认策略（`startup.P.default_ask`）不变：`/system/` 下的**系统镜像包**按 manifest 原样授权（记 `PERMS_PREGRANT`），其它包一律拒绝。launcher 的按键在 D1 之后有两条路：常驻 entry 用 `api.input.pullEvent()`（声明了 `input`），纯函数 `M.handle_key(state, key)` 与 `opts.keys` 驱动的 `M.run` 保留给离线套件——包不声明 `input` 就拿不到键盘，那仍是有意的默认。`api.sys` 之外的输入通道只有 `api.input`（需 `input` cap）。

10.5 **launcher（桌面）**：`pyroet-os/system/launcher.app/`，**0.2.0**，`capabilities = {"fs.read","fs.write","input","terminal"}`（写**只**用于成功后追加一行 `/etc/launcher.recent`，被拒绝就忽略；两个 UI cap 见 §19，D1 起它是**常驻**的，见 §20）。扫描 `/apps` 与 `/system/system` 下的 `<name>.app`（目录里必须有 `manifest.lua`），名称 = 目录名去掉 `.app`，版本取自运行时索引（`api.sys.apps()`）；运行时没有加载的包仍然列出、版本显示 `?`（桌面上"介质里有什么"不等于"运行时加载了什么"）。排序按名称升序，同名重复只取首个并进 problems。顶部两行状态：`ver <version> sha <8 位十六进制>`（只读全局 `/boot.ok` 的 `version` 与 `manifest_sha` 前 8 位；`manifest_sha=none` 或非十六进制时省略 `sha` 段，标记读不到就 `ver ?`——单树没有槽位指针，G2 已删掉全部槽位兜底）与 `net <ok|degraded|down|off> free <n>`（`fs.getFreeSpace("/")`，读不到就 `n/a`）。启动**只**走 `api.sys.launch(name)`（运行时 `rt:start`），绝不自己起 coroutine。键位（D1 之后真机也生效）：`up`/`down`（`left`/`right` 同向）移动选择、数字键直选、`enter` 启动、**`escape` 或 `q` 退出到 shell**；事件由 `kernel/desktop.lua` 投递，`nil` = 没有投递（只 `yield`，不重画）。布局：行 1–2 头部、行 3..n-2 列表、行 n-1 提示或单条消息、行 n 选择计数；**列 < 16 或行 < 6 → 降级成单行状态**，列 < 26 → 列表降级为单列（去掉版本列），任何行都 pad/truncate 到列宽，越界写屏不可能发生。

10.6 **settings（设置）**：`pyroet-os/system/settings.app/`，`capabilities = {"fs.read"}`——**严格只读**，没有写路径。离线套件用 instrumented fs 断言 `write/append/delete/makeDir` 调用数为 0、没有非 `"r"` 模式的 `open`，并断言运行时确实对 `fs.write` 返回 `capability denied: fs.write`。内容：系统版本、镜像版本 + `manifest_sha` 前 8 位（只读全局 `/boot.ok`）、net health、应用清单与每个 cap 的 granted/denied/pending、`/etc/network.conf` 关键项（键名含 `psk`/`pass`/`secret`/`key`/`token` 的值一律显示 `***`，明文永不进屏幕）、存储（free + 硬门禁 349,525 B + `/etc/install.set` 条目数）。缺文件时是固定降级文案（`apps n/a` / `conf n/a` / `install.set n/a` / `free n/a`），不抛错、不空白屏。与 launcher 共用同一套 26x20 规则和 `layout_selftest()`。

10.7 **`api.sys` 不是 cap**：它是宿主注入的**只读系统内省面**（`apps.new({sys = <table> | function(record) -> table|nil})`），四件事：`status()`（kernel 健康）、`apps()`（运行时 `status().apps`）、`perms(app)`（该 app 的决策表）、`launch(name)`（`rt:start`）。没注入的函数返回 `nil, "system unavailable: <fn>"` 并记 `APP_SYS_UNAVAILABLE`，所以 app 问什么都不会 nil-index。startup 的 `sys_for` 只把整表交给 `/system/` 下的包，用户包拿到桩：`launch` 是唯一有副作用的入口，按**目录**而不是按 cap 授权——cap 列表是 app 自己声明的，用它去决定"谁能启动别的 app"等于让被约束方自己发权限。`api.fs.getFreeSpace` 作为 `fs.read` 的一部分提供（读介质容量不写任何东西），宿主没有这个方法时返回 `capability unavailable: fs.read`。

## 11. 安装与 OTA

11.1 **两个模块，一个交付边界**：`kernel/installer.lua`（应用包安装/卸载/列表）与
`kernel/ota.lua`（系统镜像 OTA 客户端）都只依赖 `fs` 与 `rednet`，不 require rpv。
manifest 的解析不复制：installer 通过 `kernel/apps.lua` 的 `A:read_manifest(dir)`
读取，因此安装器与运行时对“什么是合法包”永远同源（launcher 的版本号也来自运行时）。

11.2 **应用安装器**（`installer.new{...}`，冒号风格）：

| 步骤 | 行为 | 日志 |
| --- | --- | --- |
| 定位来源 | `opts.dir` → `packages[name]`（内存包表）→ `/disk/apps/<name>.app` | — |
| 暂存 | 全部写进 `/apps/.tmp-<name>/`，真正的 `/apps/<name>.app` 在校验通过前不动 | — |
| 校验 | 必须有 `manifest.lua` + `main.lua`；manifest 由 apps.lua 校验；可选 `SHA256SUMS`（`<64 hex>  <relpath>`）逐文件校验，且包内每个文件都必须被列出 | `INSTALL_HASH_BAD file=..` |
| 覆盖 | 同名已存在 → 先记 `INSTALL_REPLACE`，删旧目录，`fs.move` 把临时目录挪进去 | `INSTALL_REPLACE name=..` |
| 降级 | `fs.move` 被拒（CC 的 move 不覆盖）→ copy + 逐文件字节比对 + 删临时目录（同一 copy 降级也用于文件集替换） | `INSTALL_MOVE_FALLBACK` |
| 失败 | 任何一步失败：删临时目录（已开始的替换连目标一起删），旧版本原样保留 | `INSTALL_FAIL name=.. err=..` |
| 卸载 | 只删 `/apps/<name>.app`；`/system/<name>.app` 一律拒绝（系统 app 只随 OTA 换） | `INSTALL_REMOVE` / `INSTALL_REMOVE_DENIED .. reason=system` |
| 列表 | `list()` 读 `/apps` 与 `/system`，version 经运行时 parser 得到（坏包不隐藏，版本记 `?` 并带 error） | `INSTALL_LIST count=..` |

> **superseded by P6-design §3 / §13（P6-2，2026-10-29）**：11.3–11.5 的 `PYROET-OTA/1`
> 整镜像协议、槽位写入顺序与失败语义已被 `PYROET-OTA/2` 文件集协议取代（校验时机、8 步
> 应用顺序、`BACKUP_CAP`、重试语义见 **§13.2–13.6**）。11.2（应用安装器）与 11.6（与救援
> 通道的关系）仍然成立；11.7、11.8 的字节数与测试组数是时点记录。

11.3 **OTA 协议 `PYROET-OTA/1`**（ASCII，一行一包；rednet 协议名 `pyroet-ota`；
块下标 0 起）：

| 方向 | 内容 | 字段 |
| --- | --- | --- |
| 请求 | `PYROET-OTA/1 GET meta` | — |
| 请求 | `PYROET-OTA/1 GET <idx>` | idx 十进制，0 起 |
| 应答 | `PYROET-OTA/1 META version=<tok> total=<bytes> chunk=<bytes> sha256=<64 hex>` | version 只允许 `%w._-` 且 ≤32；total 1..524288；chunk 1..32768 |
| 应答 | `PYROET-OTA/1 DATA idx=<n> sha256=<64 hex> <hex payload>` | payload 十六进制（可打印 ASCII），digest 只覆盖本块 |

DATA 的 digest 只能发现传输损坏；整镜像的信任锚点是 META 的 `sha256`，收齐后对组装
文件全量重算再比对。请求失败（超时/坏包/块 digest 不符）都算一次尝试，最多 3 次并记
`OTA_RETRY attempt=.. max=3 err=..`；块按下标取用，丢包只花一次请求。协议无握手、无加密：
与 §8.2/§8.3 一致，这是被明确接受的风险（SHA256 + 频道 + 帧定界）。

11.4 **槽位写入顺序（与 §2.5 同序，写死）**：读 `/boot.slot` → 目标槽 = 另一个 →
取 META → 删目标槽并逐块流式写入 `/slots/<x>/image.bin`（内存里只留一块）→ 全量
sha256 比对 META → 用 `boot.atomic_write` 写 `/slots/<x>/.image`（`version=` /
`sha256=` / `bytes=`）→ 用 `boot.write_pointer` 原子翻转 `/boot.slot`。
**不写 `/boot.ok`**（新系统首启健康后由 `boot.commit` 自己写，§2.4/§2.7），
**不删旧槽**（旧槽保留到新系统提交）。

11.5 **失败语义**：翻转之前的任何失败 → 删掉写了一半的槽、`/boot.slot` 不动，记
`OTA_FAIL stage=<prepare|pointer|meta|slot|chunk|verify|descriptor> err=..`；翻转本身
失败 → 镜像已完整且已校验，保留在目标槽（`boot.lua` 的 recover 路径可试启动它），并
把旧指针写回（`OTA_POINTER_RESTORE`，因为 `boot.atomic_write` 是先删后挪）。`status()`
给出 `idle/fetching/verifying/ready/failed` + 字节进度 + 目标槽 + 已重试次数 + 状态轨迹。

11.6 **与救援通道（`recovery/flash.lua`、`recovery/bootstrap.lua`，见 §12）的关系**：两者是
**同一信任模型的两条链路**——都只用裸 rednet、都只做 SHA256 + 帧定界、都不解析镜像格式、都
只写目标文件集（P6-3 起是 `<root>/system`，无槽无指针）、都不写 `/boot.ok`。区别只在入口：`flash.lua`/`bootstrap.lua` 是系统
坏掉时手工粘贴的极小接收器（§2.2，bootstrap ≤4 KB，拉/推两种模式），`ota.lua` 是镜像内
的正常更新客户端（复用 `boot.lua` 的写入口、crypto 与日志）。因此 `ota.lua` 失败时永远
退回 flash 那条路：OTA 代码本身不承担救援职责，也不引入握手/密钥。

11.7 **体积账与方案 D 落定（2026-10-29 实测）**：`kernel/installer.lua` 13,253 B +
`kernel/ota.lua` 12,912 B = **26,165 B**；把 `system/net.app/`（15,930 B）移出镜像改成可
安装示例 `pyroet-os/examples/net.app/` 后，`install.set` 从 333,140 B 变成
333,140 − 15,930 + 26,165 = **343,375 B / SIZE_WARN**，距硬门禁 349,525 B 余 6,150 B。
两条安装/Ota 路径已同时启用（P5a 注释里写死的“两条一起加”约束）。**G1 更正**：net.app 已
加回镜像（`system/net.app`，15,930 B），不再由 `kernel/installer.lua` 从介质安装它——上面的
333,140 → 343,375 裁剪账只作 P5b 时点记录；G1 后 TOTAL **359,305 B**（硬门禁改为 629,145 B，
见 §8.4）。launcher/settings 的扫描本来就是通用 `<name>.app`
扫描，startup 也没有默认启动 net.app 的分支（P5b 测试证明缺包时桌面与启动链照常）。

11.8 **测试口径**：`pyroet-os/tests/t_installer.lua`（21 组）与 `tests/t_ota.lua`
（10 组）全部离线：假 fs/假 rednet/注入时钟，覆盖 manifest 校验、`SHA256SUMS` 各类
坏输入、临时目录回滚、覆盖、copy 降级与半拷贝、卸载保护、`list()`；OTA 侧覆盖 META/
DATA 解析、逐块 digest 不符的重传、丢包重试 3 次、整镜像不符、指针翻转时机（失败不
翻）、翻转失败后的指针恢复、`status()` 状态机。套件基线 **OFFLINE_PASS 2,089 /
FAIL 0 / GROUPS 109**（P4 基线 1,807/0/77，本任务 +282 断言 / +32 组）。


## 12. 恢复与刷写（EDL 类比）

12.1 **不进镜像**：`pyroet-os/recovery/proto.lua`、`flash.lua`、`bootstrap.lua` 不进 `install.set`，
`sizecheck` 不计它们。三个文件是手工复制到故障机上的救援工具，只用 ROM 全局（fs/term/os、rednet）
与 `/system/rpv/crypto.lua` 的 SHA-256，不加载任何 rpv 模块。`proto.lua` 是共用的“文件集事务”层：
协议解析、canonical manifest 摘要、逐文件 SHA-256、`P.target()`（单树目标）、`P.write_file_set()`
（暂存 → 校验 → 替换 → 失败逆序撤销 → 写 journal）；flash 与 bootstrap 只提供“拉/推”两种来源与 CLI，
避免两份漂移。

12.2 **单树目标（没有槽、没有指针）**：目标永远是 `<root>/system`。`P.target(fs, root)` 是旧 `P.ptr()`
的等价物，返回 `dir` / `nil,"missing"` / `nil,"not_a_dir"` —— 砖机正是 `/system` 缺失的情形，所以这是
信息而不是拒绝。`--slot` 参数已删除；`/boot.slot`、`/slots/<x>` 不再读也不再写。

12.3 **两条来源（`flash.lua`）**：
- 有驱动器：`/disk/firmware/meta.txt` + 按 relpath 摆好的文件。`meta.txt` 就是 META 报文的正文
  （`version=`、`manifest_sha=`、`files=` + 每行 `<relpath> <size> <sha256>`），与 rednet 共用同一个解析器。
- 无驱动器：rednet 协议 `pyroet-flash`、前缀 `PYROET-FLASH/2`；请求 `GET meta` / `GET <relpath> <idx>`，
  应答 `META` / `DATA <relpath> idx=<i> sha256=<64 hex> <hex>`；`idx = offset / MAX_DATA`，
  `MAX_DATA = 8,192`（16,384 hex 字符，稳在 rednet 单包上限内；v1 的 32,768 B 分块 hex 后已贴上限）。
  丢包/坏块各算一次尝试，最多 3 次。
- `bootstrap.lua` 是推送模式：`PUSH meta ...` 后跟 `PUSH DATA <relpath> idx=<i> sha256=<hex> <hex>`。
  分片可乱序（还用不到的先缓冲），坏块被丢弃并计一次 miss，等发布端重发该分片。

12.4 **写顺序（写死；失败不破坏系统）**：①`P.target` 只做记录；②逐文件先下到
`/update.stage/<relpath>.part` 并回读校验 `size + sha256`（目标已是同一 sha256 的文件直接跳过 —— 幂等
的来源）；③**全部通过后**才逐文件替换：旧字节 `move` 到 `/update.backup/<relpath>` 并回读校验旧 sha，
再把 `.part` `move` 进 `/system/<relpath>` 并回读校验新 sha；④任何失败按内容哈希**逆序撤销**已应用文件
并清掉半成品，`/system` 回到旧字节；⑤成功后删 `/update.stage`，保留 `/update.backup` 作为试启动回滚素材。
校验必须在 `/system` 一字节未动之前完成：暂存期失败只花一次下载，替换期失败才需要撤销动作。
日志：`FLASH_TARGET path= state=present|missing`、`FLASH_SOURCE kind=disk|rednet`、
`FLASH_META version= files= manifest_sha=`、
`FLASH_OK files= written= skipped= bytes= version= manifest_sha= journal=`、
`FLASH_FAIL stage=<prepare|source|meta|manifest|stage|backup|apply> err=`；bootstrap 只换前缀（`BOOTSTRAP_*`）。

12.5 **刷完会写一份 `applied` journal**：文件集写入成功后，`proto` 在根上写 `update.journal.<seq>`
（`PYROET-UPD-JOURNAL-1` / `state=applied` / `version=` / `manifest_sha=` + 每个改动文件
`<relpath> <old_sha|-> <new_sha> <bytes>`），`/boot.ok` 保持旧值。于是 bootloader 把新镜像当“未提交”
试启动，三次起不来就用 `/update.backup` 按哈希回滚（§13.5/13.7）。journal 写失败不算刷写失败
（文件已在盘上且逐字节校验过）——只体现在 `journal=none`。

12.6 **测试口径**：`tests/t_recovery_proto.lua` 覆盖哈希、canonical manifest、relpath 白名单、
META/DATA 解析、`P.target`、原子写与文件集事务（成功、幂等第二遍、暂存失败、摘要失败、manifest 不符、
替换失败逆序撤销）与请求重试；`t_recovery_flash.lua` 覆盖磁盘与 rednet 两来源、请求序列、坏块重试、
坏 meta/manifest、缺失文件、幂等第二遍与“失败保留旧系统”；`t_recovery_bootstrap.lua` 覆盖推送、
乱序分片、坏块重发、超时、断线、坏 meta/manifest，以及失败不破坏旧系统。离线基线见修订记录。


## 13. 系统更新模型（P6-2 落地：单树 + journal + 差异备份）

13.1 **权威设计**：`pyroet-os/P6-design.md` 是本节的口径来源；§2.3–2.8 的双槽整镜像模型已被它取代（历史保留，见各节头部的 superseded 标注）。代码落点：`boot.lua`（决策表 + 按哈希的幂等回滚）、`kernel/ota.lua`（`PYROET-OTA/2` 文件集协议）、`startup.lua`（commit 写全局 `/boot.ok`）。

13.2 **磁盘布局（单一系统树）**：

| 路径 | 内容 | 写者 |
| --- | --- | --- |
| `/system/` | 唯一系统树；`relpath` 相对它（如 `kernel/ota.lua`） | OTA 逐文件替换 |
| `/update.journal.<seq>` | 更新意图日志，三态 + `rolledback` 墓碑；按 seq 递增，保留最新两代 | OTA（prepare/applying/applied）、回滚（rolledback） |
| `/update.backup/<relpath>` | 只存本次会被改的旧文件，结构与 `/system/` 同构 | OTA（替换前 move 进来并回读校验） |
| `/update.stage/<relpath>.part` | 单文件暂存，校验通过后 move 进 `/system/`（失败/回滚后删） | OTA |
| `/boot.ok` | **全局**提交凭据：`PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..` | `startup.lua`（首帧后） |
| `/boot.tries` | 连续试启动计数（全局，不再按槽） | `boot.lua`（先落盘再启动） |

journal 行格式 `<relpath> <old_sha> <new_sha> <bytes>`；`old_sha = -` 表示本次新增（回滚 = 删除该文件）。**写 journal 永远“写新一代 + 保留上一代”**，不原地重写：CraftOS 的 `fs.move` 不能覆盖，原地替换必然有“目标已删、新的还没挪进来”的窗口，一次断电就丢回滚意图。bootloader 取“能解析且 seq 最大”的一代，坏代忽略；两代都坏且磁盘上有 `/update.backup` 素材时按回滚失败处理。

13.3 **校验时机（写死）**：清单校验必须在**下载完成时、`/system` 一字节未动之前**：收齐全部 `FILE` 行后按 P6-design §3.2 算聚合哈希（按 `relpath` 升序拼 `<relpath>\0<size>\0<sha 小写>\n`，整串一次 SHA-256）与 `META.manifest_sha` 比对，不符即 `OTA_REJECT stage=verify reason=manifest_sha got=.. want=..`、状态 `rejected`、可 `retry()` 从第 0 块重来，系统不动。理由：`old_sha`/`new_sha` 是回滚能力的来源；一旦进入 `applying`，系统随时处于中间态，那时才发现内容不可信，唯一出路是用备份回旧版本，而备份的可信度取决于 `old_sha` 在动手之前就是对的。同理 `old_sha` 一律**本地现算**，不信服务器。同一个时机还校验**字节数**：`.part` 必须恰是 `FILE` 行声明的 `size`（`fs.getSize` 复核），不符即 `OTA_REJECT stage=verify reason=size file=.. got=.. want=..`；`move` 进 `/system/` 之后再量一次（`OTA_FAIL stage=install err=size ..` + 回滚）——摘要证明内容、字节数证明长度，缺一不可（§16.1）。

13.4 **BACKUP_CAP = 200,000 B（策略上限，写死）**：在收到全部 `FILE`、算出“会被备份的字节数”（只算已存在的目标文件）之后、写 `prepare` 之前检查；超限即 `OTA_REJECT stage=cap reason=too_big need=<b> cap=200000`，系统一字节不动。与 `sizecheck.py` 的窗口门禁同口径：`TOTAL + 200,000 ≤ 900,000`（当前 `592,500`）。物理上限仍是机身配额；单文件上限 `F_max = 65,536 B`，超限 `stage=file`。

13.5 **应用顺序（8 步）**：`journal(prepare)` → `journal(applying)` → 每个文件 a 暂存 `.part`、b 回读校验 `new_sha`、c 旧文件 move 进备份、d 回读备份校验 `old_sha`、e `.part` move 进 `/system`、f 回读校验 `new_sha`、g 删残片 → 全部完成后 `journal(applied)`。**先备份、再替换**：备份不可信就立刻挪回并放弃整次更新（`OTA_FAIL stage=backup`）；应用期任何失败立即按已写入部分回滚（`OTA_FAIL stage=.. err=..` + `OTA_ROLLED_BACK`），系统回到旧状态；回滚本身失败 → `OTA_ROLLBACK_FAIL` + `FLASH_REQUIRED`。只有 `applied` 之后才允许重启进新版本。

13.6 **重试语义**：`rejected`（verify/cap 拒绝）没有改动任何字节，`retry()` 从头拉取；`rolled_back`（应用期失败但回滚成功）同样可重试；回滚无法证明（`fatal`）不可重试，只能走 `recovery/flash.lua`。传输层丢包/坏块各算一次尝试（1..3 次 + `OTA_RETRY`），文件级摘要不符则整个文件重下——与 v1 一致，不做位图。

13.7 **bootloader 决策表（17 行，见 P6-design §6）**：输入只有“`/system` 在不在、最新可解析 journal 的状态、`/boot.ok` 有没有且 `manifest_sha` 是否等于 journal、`/boot.tries`”。fatal 只有三类：`no_system`、`rollback_fail`、写盘失败（`tries_unwritable`），且**一律不 reboot**（重启环修不了坏字节），固定输出三行便于 grep：`BOOT_ROLLBACK_FAIL seq=.. relpath=.. want=.. got=..` / `BOOT_FATAL reason=rollback_fail` / `FLASH_REQUIRED tool=recovery/flash.lua slot=n/a hint=reboot_and_run`。回滚按**内容哈希**判定进度（绝不写进度标志）：`sha256(/system/<rel>) == old_sha` 已就位跳过、`sha256(backup) == old_sha` 挪回并回读校验、`old_sha == -` 删掉、都不成立即 fatal。`MAX_TRIES = 2` 保留：第 3 次失败（`tries > 2`）回滚；回滚成功后写 `state=rolledback` 墓碑，下一次开机清理。

13.8 **迁移（顺序写死）**：先写新 `/boot.ok` → 再写 `update.journal.<1>`（`state=prepare`、`files=0`）→ 最后才删 `/slots/`、`/boot.slot`、`/boot.slot.tmp`、`system.tmp*`；反过来任何一步断电都会让设备同时没有系统也没有提交凭据。bootloader 开机检测到遗留即执行一次（`BOOT_MIGRATED`），随后空 `prepare` 日志按“下载未应用”清理。

13.9 **P6-3 已清账（2026-10-29）**：原遗留四项全部落地 —— (1) `recovery/proto.lua`、`flash.lua`、`bootstrap.lua` 改写为 `PYROET-FLASH/2` 文件集、目标 `<root>/system`、无槽无指针（§12 已同步）；(2) `system/settings.app` 门禁文案改为三层（`M.BUDGET=629,145` / `M.STRETCH=349,525` / `M.WINDOW=900,000` / `M.BACKUP_CAP=200,000`），`launcher.app` 与 `settings.app` 的系统应用扫描根改为 `/system/system`；(3) `kernel/installer.lua` 仍只装应用（应用安装逻辑不变），但其 system 根改为 `/system/system`、crypto 改为 `/system/rpv/crypto.lua`；(4) `/kernel`、`/rpv`、`/net` 已搬进 `/system/`，老镜像由 `boot.migrate_layout()` 迁移（§13.11）。**保留的兼容读已清理（G2，2026-10-29）**：`launcher.app`/`settings.app` 不再读 `/boot.slot`、`/slots/<x>/boot.ok`、`/slots/<x>/.image`，也不再渲染 `slot ?` 占位；两者只读全局 `/boot.ok`（`version` + `manifest_sha` 前 8 位），`M.SLOT_PATH` 由 `M.BOOT_OK` 取代，`read_boot()` 不再返回 `slot` 字段。全仓其余旧路径字面量只剩两类，都不是读取：`boot.migrate_layout()` 的删除动作（源码里是 `join(root, "boot.slot")`/`join(root, "slots")`）与 `tests/t_boot.lua`/`t_startup.lua` 的旧布局 fixture（证明迁移会把它们删掉）。

13.10 **测试口径（P6-2 实测）**：`tests/t_boot.lua`（23 组：决策表 17 行 + 交叉、journal 两代与坏代、按哈希的幂等回滚、P6-design §9.3 五条回滚失败路径、迁移、崩溃窗口）、`tests/t_ota.lua`（18 组：协议边界、路径白名单、聚合哈希唯一定义、`verify`/`cap` 拒绝与重试、应用期失败回滚、重跑）、`tests/t_startup.lua`（14 组：manifest 来源、commit 失败保留意图、`rolledback` 启动、迁移）；`tests/t_desktop.lua`、`t_budget.lua` 的 fixture 从槽位改成全局凭据。离线套件 **OFFLINE_PASS 2,651 / FAIL 0 / GROUPS 149**（P6-2 前 2,313/128）；体积 `boot.lua` 38,721 B（581→1,031 行）、`kernel/ota.lua` 28,304 B（320→712 行）、`startup.lua` 20,280 B（506→517 行），TOTAL **392,500 B / SIZE_WARN**（超目标线 42,975 B，距硬门禁余 236,645 B）、`WINDOW_OK sum=592,500`。

13.11 **布局与迁移（P6-3，2026-10-29）**

**根目录只留一个 starter**：`/startup.lua`（1,071 B，上限 1.5 KB）只做两件事 —— `pcall(loadfile, "/system/startup.lua")` 并调用它；加载失败或它抛错时打印 ASCII 行（`Pyroet OS: cannot load /system/startup.lua` 或 `Pyroet OS: startup failed`，加原因摘要和 `shell only. Run recovery/flash.lua to reflash /system.`）然后返回，把控制台交回 ROM shell。**不 reboot**：重启环修不了坏字节。它不在 OTA 文件集内（OTA 的 relpath 相对 `/system/`），任何更新都改不到它；但它列在 `install.set` 里，装机时一并写入。

**前后对照**：

| 内容 | P6-2（旧） | P6-3（单树） |
| --- | --- | --- |
| ROM 入口 | `/startup.lua`（20 KB，整条引导链） | `/startup.lua` starter（1,071 B）+ `/system/startup.lua`（引导链） |
| bootloader | `/system/boot.lua` | 不变 |
| kernel | `/kernel/*.lua` | `/system/kernel/*.lua` |
| rpv 子集 | `/rpv/*.lua` | `/system/rpv/*.lua` |
| 网络服务 | `/net/*.lua` | `/system/net/*.lua` |
| 系统应用 | `/system/<name>.app` | `/system/system/<name>.app` |
| 用户应用 | `/apps/*` | 不变 |
| 配置 | `/etc/*` | 不变 |
| 恢复工具 | `/recovery/*.lua`（写 `/slots/<x>` + `/boot.slot`） | 同位置，目标改 `<root>/system` |

**迁移算法（`boot.migrate_layout`，在决策表第 1 行之前执行）**：
1. `legacy_layout()` 逐个检查根上的 `kernel`/`rpv`/`net`：存在且 `<root>/system/<name>` 不存在 → 待搬；目标已存在 → 记 `BOOT_MIGRATE_LAYOUT_SKIP name=.. why=target_exists` 并**保留**旧副本（删旧不是迁移的决定）。
2. `legacy_apps()` 把 `/system/*.app`（排序后）搬到 `/system/system/`。
3. `ensure_dir(/system)` 之后逐条 `fs.move`，**只做重命名、不做复制**（复制无法廉价撤销；rename 要么发生要么没有）。成功记 `BOOT_MIGRATE_LAYOUT name=<entry> to=<dst> via=move`，全部成功再记 `BOOT_MIGRATE_LAYOUT_DONE dirs=<n> apps=<m>`。
4. 任一条失败：把已搬的按**逆序**重命名回去，记 `BOOT_MIGRATE_LAYOUT_ROLLED_BACK stage=<mkdir|move> restored=<n> of=<m>`，返回 `nil,<stage>`；`boot.begin()` 记 `BOOT_MIGRATE_LAYOUT_ABORT stage=..` 并返回 `fatal(layout_migrate_fail)`（**不 reboot、不半搬**）。撤销本身失败 → `BOOT_MIGRATE_LAYOUT_ROLLBACK_FAIL name=..`，返回 `nil,"rollback_fail"`，同样 fatal 并把现场留给用户。
5. 可重入：迁移成功后根上已无这些条目，下一次开机直接返回 `false` 且不写 `BOOT_MIGRATE_LAYOUT*`（有 skip 时只写 skip 行）。

它不写 journal：只做重命名、一个字节都没改，所以没有“内容中间态”需要描述。

**路径引用**：`startup.lua` 的 `P.KERNEL_PATH`/`P.APPS_PATH`/`P.PERMISSIONS_PATH` 指向 `/system/kernel/*`，新增 `P.SYSTEM_APPS_ROOT = "/system/system"`；`boot.lua` 的 `M.CRYPTO = "/system/rpv/crypto.lua"`，`M.paths()` 新增 `system_apps`；`kernel/ota.lua` 的 `CRYPTO`、`kernel/installer.lua` 的 `SYS`/`CRYPTO`、`net/service.lua` 的 hosts 模块候选路径、`system/launcher.app` 的 `M.ROOTS` 同步；`tests/run-tests.ps1` 的 staging 与 `$required` 按同一布局。

## 14. 发布口径（release packaging）

14.1 **版本号 1.0.0，产物 `dist/release/pyroet-os-v1.0.0.zip`**，用仓库通用脚本构建：
`python tools/build_release.py --project pyroet-os --out dist/release`（本目录**没有**自己的 release 脚本，也没有
`RELEASE.md`，所以 tag 发布时 release 正文为空）。zip 根是 `pyroet-os/` 前缀 + 仓库根的 `LICENSE`；成员按
路径排序、固定 `1980-01-01 00:00:00` 时间戳与 0644 权限，同一内容重复构建字节相同（CI 的
`release-builds.yml` 用同一条命令，见 14.5）。

14.2 **进包**（32 个 `pyroet-os/` 成员）：`startup.lua`（ROM starter）、`system/**`（bootloader、`kernel/`、`rpv/`
子集、`net/`、三个系统 app）、`recovery/**`（`proto.lua` / `flash.lua` / `bootstrap.lua`）、`install.set`、
`DECISIONS.md`、`P6-design.md`。`recovery/` **必须**随包发：`/system` 缺文件的砖机只能靠用户把它拷到机上，
包里没有就等于没有救援通道；两份文档同理——现场没有仓库、也没有 git 历史，出故障时
`DECISIONS.md`/`P6-design.md` 是唯一在场的口径来源。

14.3 **不进包**：`tests/`（CraftOS-PC 离线套件、harness、fixture）与 `tools/`（`sizecheck.py`、`smoke.lua`、
`smoke-run.ps1`）——纯开发材料，装机用不到。口径写在 `tools/build_release.py` 的
`EXCLUDE_FROM_RELEASE["pyroet-os"] = ("tests/", "tools/")`，按相对路径**前缀**匹配；对其它项目零影响
（`itn-pass` 仍只排 `tests/`，sentinel / cardkey / pylib / itn-pass 四包与本改动前逐字节相同）。

14.4 **发布包 ≠ 运行时镜像**：发布包是完整源码集（含不进 `install.set` 的 `recovery/` 与两份文档），而
`install.set` + `sizecheck.py` 统计的是**镜像**（26 条、`SIZE_WARN`、`WINDOW_OK`，当前口径见修订记录最新行）。
两者成员集合不同：不要拿 zip 体积当体积门禁，也不要因为包里有 `recovery/` 就以为它在镜像里。

14.5 **CI 接线**：`.github/workflows/release-builds.yml` 里 `pyroet-os` 与 sentinel/cardkey/pylib/itn-pass 走同一条
通用分支——dispatch 选项、tag 名单（tag 名就叫 `pyroet-os`）、分支推送的全项目构建循环、`case` 分派四处；
tag 推送时建/刷新该 tag 的 release 并上传这个 zip。根 `README.md` 的项目表、构建命令表、tag 名单同步维护。

## 15. OTA 服务端（分发中心）

15.1 **部署形态**：跑在分发中心（134）——一台**普通 CC 电脑 + 裸 rednet**，不装 rpv、不依赖 `/system` 树。
全部部署物 = `ota/server.lua` 一个文件 + 一个发布目录；`M.new{fs,log,rednet,channel,manifest|dir}`，`M.serve()` 阻塞循环收包，`M.stop()` 退出。
`channel` 就是 rednet 的**协议串**（裸 rednet 没有数字频道），默认 `pyroet-ota`，必须与客户端 `kernel/ota.lua` 的 `PROTOCOL` 一致——不一致时客户端只会看到超时。

15.2 **发布目录与 manifest 生成**：`<dir>/meta.txt`（`version=<tok>` 必需；`files=`/`manifest_sha=` 是可选钉，把镜像钉在“就是这批字节”上）
+ 按 relpath 展开的 `/system` 镜像树（`<dir>/kernel/ota.lua` → relpath `kernel/ota.lua`；`meta.txt` 是唯一不进更新集合的根文件）。
`M.build_manifest(dir)` 递归读取、按 relpath 排序、逐文件算 SHA-256，再用 §3.2 的唯一定义算 `manifest_sha`（空集 = `sha256("")`）。
发布侧 **fail-closed**：白名单外路径、0 字节、> `F_MAX`(65,536)、> `MAX_FILES`(256)、`meta.txt` 的钉不符（`files=`/`manifest_sha=`）一律拒绝构建并记
`OTA_SERVER_BAD_FILE`/`OTA_SERVER_BUILD_FAIL`，不把“客户端必然拒收”的清单发出去。清单常驻内存（每条带字节），分发中心内存占用 ≈ 发布目录体量。

15.3 **签名边界**：**无签名，只有完整性**。SHA-256 + 帧格式就是全部信任模型（同 §8.3）；`manifest_sha` 是“这一批 (relpath,size,sha256)”的指纹，
客户端收齐 FILE 行后**本地重算**比对，不符即 `OTA_REJECT stage=verify`、一字节不写；分发中心被改 → 客户端拒收。
但协议里没有“发布者是谁”：能同时改写 manifest 与字节的中间人仍可通过（rednet 无认证）。要真认证必须在 §3 协议上加签名，属未决项，本轮不做。

15.4 **与客户端严格同口径**（`tests/t_ota_server.lua` 差分，任一项漂移即测试失败）：`MAX_DATA=8192`、`F_MAX=65536`、`MAX_FILES=256`、
路径白名单（≤96 字节、逐段非 `.`/`..`/不以 `.` 开头、`[%w_%-%.]`、五个保留名、`.lua/.txt/.conf/.cfg`）、
hex 一律小写、offset 必须 `MAX_DATA` 对齐且 `chunk = min(MAX_DATA, size - offset)`（末块可短）、
`manifest_sha` = 按 relpath 排序的 `<relpath>\0<size>\0<sha256>\n` 单次 SHA-256。
白名单在服务端是**复制 + 双向差分测试**而不是 require 客户端：分发中心不一定有 `/system/kernel/ota.lua`（复制来源在 `ota/server.lua` 的注释里点名到 `system/kernel/ota.lua:235-260`）。

15.5 **协议与容错**：只有三个请求（`GET meta` / `GET <idx>` / `GET <idx> <offset>`，idx 0 起）。
本协议前缀但请求非法 → `PYROET-OTA/2 ERR reason=<bad_verb|bad_request|bad_idx|bad_offset|no_data|no_manifest>`；
**非本协议前缀的报文静默忽略**（不抢答裸 rednet 上别人的流量）。无会话、无位图：一个请求一个回包，丢包只花客户端一次重传。
服务端**不在请求时重算** manifest：构建期算一次，之后按记录原样发。构建后被篡改的记录服务器不会“顺手修正”，只会被客户端拒绝——这是刻意的，服务端不猜作者意图。

15.6 **不进镜像 / 不进 install.set**：`ota/` 是分发侧工具，装机用不到。`install.set` 仍 26 条、`python pyroet-os/tools/sizecheck.py`
→ TOTAL **401,778 B / SIZE_WARN / `WINDOW_OK sum=601,778`**（与 B7 逐字节相同）。注意它**会**随 §14.2 的源码发布 zip 一起发：
`tools/build_release.py` 只按前缀排除 `tests/`、`tools/`，所以发布 zip 里的 `pyroet-os/` 成员由 32 变 33（+`ota/server.lua`）。
要不要从发布包里剔除是另一个决定，本轮不动 `build_release.py`。

15.7 **测试口径**：`tests/t_ota_server.lua` 把 `system/kernel/ota.lua`（客户端）与 `ota/server.lua`（服务端）放在同一进程，
stub rednet 只替换 modem（客户端 `send` → 服务端 `dispatch` → 回包进客户端 `receive`），其余全是真代码。覆盖：
正常更新（小文件 + 一个 `8192+100` 的多块文件，逐条断言 8 条线上请求）、`valid_path` 双向差分（29 条路径 × 判定 + 原因）、
`manifest_hash` 双向一致、客户端解析服务端 FILE/DATA 行后再哈希回服务端 `manifest_sha`、META 说谎 → 客户端 `rejected`、
字节被改 → 下载校验失败 → 回滚到原字节、丢 DATA 回包 / 丢请求 → 重传后成功、`files=0`（服务端合法 `sha256("")`、客户端拒 `bad files`）、
超大文件与非法路径两侧都拒、越界 idx、`retry()` 从 `rejected` 恢复、`serve()/stop()` 循环与 `receive` 抛错。基线见修订记录。

## 16. N1 修正（size 校验与 net 默认注册）

> 两条此前写在 README「已知限制」里的缺口，N1 起不再是缺口：manifest 的 `size` 运行时会校验，
> `net` 服务由默认启动链注册。本节是这两件事的权威口径；README 面向使用者，这里是给实现者的。

16.1 **OTA 客户端（`system/kernel/ota.lua`）：三处字节数校验，全部 fail-closed**

1. **下载请求**只按声明 `size` 推进，末块长度必须正好 `want`；短包按坏块重试（`OTA_RETRY ... err=file size ...`），
   不是"少收一点也算完"。
2. **`.part` 写完先量字节**（`fs.getSize`，取不到则整文件回读计数）再比摘要：不等即
   `OTA_REJECT stage=verify reason=size file=<relpath> got=<实际> want=<声明>`。此时磁盘一字节未动：
   若本次更新**还没有任何文件落地**，先 `boot.cleanup()` 丢掉 journal/stage，再进 `rejected`（可 `retry()`）；
   已经有文件落地则改走 `OTA_FAIL stage=verify` + `OTA_ROLLED_BACK`（备份已存在，必须回滚）。
3. **`move` 进 `/system/<relpath>` 之后再量一次**：不等即 `OTA_FAIL stage=install err=size got=.. want=..` + 回滚。
   防的是"写短了但摘要碰巧对上"以及替换后被截断——摘要证明内容，字节数证明长度，两者都要。

16.2 **安装器（`system/kernel/installer.lua`）：两处声明，缺省即跳过**（向后兼容是硬要求，不是宽松）

- `SHA256SUMS` 第三列：`<64 hex>  <size>  <relpath>` 或 `<64 hex>  <relpath>  <size>`（两种列序都收，
  不写第三列就是老格式）。逐文件比对，不符 → `INSTALL_SIZE_BAD file=<rel> got=.. want=..` +
  `INSTALL_FAIL ... err=size <rel>`，不落盘、保留旧版本。
- manifest 的 `size`：整包总量，统计暂存目录里除 `manifest.lua` 外的全部文件（含 `SHA256SUMS` 自身）。
  运行时校验后的 manifest 只保留白名单字段，原始表放在 `manifest.raw`，安装器从那里读声明值
  （`manifest.size` 与 `manifest.raw.size` 都认）。不符 → `INSTALL_SIZE_BAD scope=package got=.. want=..` +
  `INSTALL_FAIL ... err=size <实际>/<声明>`；声明值不是整数 → `INSTALL_SIZE_BAD scope=package
  reason=declared value=..`（拒绝，不静默忽略）。
- 两处都可以不写；不写就是只验摘要的老行为。

16.3 **`size` 的口径**：`manifest.lua` **不计入**包总量。这是实现约束而非口味——文件无法包含自己的
最终长度，把 `manifest.lua` 计入会让声明值自指。`SHA256SUMS` 计入是安全的：它的长度只取决于摘要
字面长度（恒 64）与被列文件名的长度，不取决于内容（打包工具因此可以两遍定稿）。

16.4 **OTA 服务端（`ota/server.lua`）同样 fail-closed**：`size` 与持有的字节数不符一律
`OTA_SERVER_BAD_FILE path=.. reason=size got=.. want=..`，并在三个时机各查一次——按目录构建清单时
（文件系统报的字节数 vs 实际读到的字节数）、装载清单时（声明 vs 载荷）、FILE/DATA 应答前（防加载后
被改写）。构建/装载失败即 `self.error`，一个请求也不服务（`ERR reason=size`）。

16.5 **`net` 服务默认注册（`system/startup.lua`）**

- 判据是**用户数据**：仅当 `/etc/network.conf` 存在时注册 `net`（`/system/net/service.lua` 的 `spec()`），
  否则记 `STARTUP_NET_SKIP reason=no_config path=..` 并继续。缺配置**不是**启动失败（新机本来没有 `/etc`）。
- 之后的任何问题都只记日志并让 `health=degraded`，**绝不 reboot、绝不回滚整机**：模块缺失
  `STARTUP_NET_SKIP reason=no_module`、`spec()` 抛错 `STARTUP_NET_FAIL reason=spec`、注册被拒
  `STARTUP_NET_FAIL reason=register`、启动失败 `KERNEL_SERVICE_FAIL name=net` +
  `STARTUP_NET_DEGRADED state=failed health=n/a`；跑起来但没起网 `STARTUP_NET_DEGRADED state=running
  health=degraded`；起网 `STARTUP_NET_READY state=running`（服务自己另有 `NET_READY`/`NET_DEGRADED`）。
- 顺序不变：权限表 → 服务注册（hello + net）→ 首帧 → 启动 launcher → `boot.commit()`。
- `opts.services` 里若已含同名 `net`，默认注册让位给注入的那一份（不重复注册）。
- 为什么不同时加载 rpv：注册服务不等于替它准备 `rpv` 表——注入 `opts.rpv` 才真起网。把 131 KB 的
  rpv 栈绑进每次开机不在 N1 范围内；没有 rpv 时 `net` 服务自己记 `NET_RPV_MISSING` 并 degraded。

16.6 **测试与体积口径（N1 实测）**：`OFFLINE_PASS 3,379 / FAIL 0 / GROUPS 176`（O2 基线 3,258/168，
+121 断言 / +8 组：`t_ota` 的 `ota.size_verify`、`ota.size_apply`，`t_installer` 的 `installer.size`，
`t_ota_server` 的 `ota_server.size`，`t_startup` 的 `startup.net_default`/`net_skip`/`net_degraded`/`net_fail`）；
`python pyroet-os/tools/sizecheck.py` → `install.set` 仍 26 条、TOTAL **414,566 B / SIZE_WARN /
MARGIN 65,041**、`WINDOW_OK sum=614,566`（+12,788 B：`startup.lua` 20,654→26,022、
`kernel/installer.lua` 13,441→17,295、`kernel/ota.lua` 28,311→31,877）；改动 lua 非 ASCII 计数 0；
门禁参数与 `install.set` 未动。

## 17. 安装器 UI（`installer.app`，T1）

17.1 **为什么是应用而不是内核功能**：安装器（`kernel/installer.lua`）是事务层，UI 是表现层。
把 UI 做成普通 `.app` 包（`/system/system/installer.app`，26x20，与桌面/设置同一套布局自检），
意味着它只能拿到 manifest 声明的两个 capability；删掉它不影响系统的安装能力，也不会把
"界面代码"塞进内核。代价是它必须通过**宿主桥**才能拿到安装器对象。

17.2 **宿主桥契约（写死）**：应用按顺序取第一个可用来源——
`opts.installer` → `api.sys.install` / `api.sys.uninstall` / `api.sys.list` → `api.installer`。
桥函数是**平函数**（不是对象方法）：

    install(name)   -> true, { version = <string> }   或  nil, <错误串>
    uninstall(name) -> true                            或  nil, <错误串>
    list()          -> { { name, dir, root, source, version, ok, error }, ... }

即 `kernel/installer.lua` 的返回契约，只是把 `self` 的绑定放在宿主侧完成。**应用绝不
`dofile`/`loadfile` 任何镜像模块**（能加载内核模块就等于拿到全系统权限），测试对源码做了
`/system/kernel` 字面量断言。**桥对象完全缺失**（`M.bridge` 返回 nil）→ `installer unavailable`，
照常运行、照常重扫；桥在但内核没装安装器时，同一行文案由 §17.4 的 `unavailable` 映射给出。

> **T4 已接通。** `kernel/apps.lua` 的 `A.SYS_FUNCTIONS` 现在是
> `status`/`apps`/`perms`/`launch`/`install`/`uninstall`/`list`：前四个仍由 `opts.sys` 宿主表提供，
> 后三个由**运行时自己**实现——只有它知道调用方 record 的 cap 集合，授权必须在进安装器之前发生。
> - **能力要求**：`install`/`uninstall` 需 `fs.write`，`list` 需 `fs.read`；未授权返回
>   `nil, "capability denied: <cap>"` + `APP_CAP_DENIED`（沿用 §4.2 的拒绝语义，不抛错；拒绝时
>   安装器一次都不被调用）。
> - **入口授权**：这三个函数和 api.sys 其余入口走**同一份**授权——宿主只给 `/system/` 下的包
>   `opts.sys` 表（`startup.lua` 的 `sys_for`），没拿到系统面的用户包仍然只拿到
>   `nil, "system unavailable: <fn>"` 桩，装/卸能力不会随 `fs.write` 外泄（§8.6 不变）。
> - **参数**：只接受包名 `[%w_%-]+`、≤40 B（与 `installer.NAME_MAX` 同口径），`..`、`/`、`\`、`.`、
>   空串、非字符串一律 `nil, "bad name"`——名字在拼成 `<root>/<name>.app` 之前就被拒。
> - **`/system` 保护**：`uninstall` 只允许卸 `/apps/` 下的包。名字在 `inst.system_root`（默认
>   `/system/system`）下存在即 `nil, "system app"` + `APP_SYS_PROTECT name=..`，**桥一次都不调用**；
>   即使同名包同时装在 `/apps` 也照拒（§17.5 的应用层保护之外的第二层）。
> - **注入**：`startup.lua` 在启动链第 3b 步构造 `/system/kernel/installer.lua`（真实 `fs`、`/apps` 与
>   `/system/system` 根、`apps` 模块复用）并以 `apps.new({ installer = inst })` 注入；构造失败只记
>   `STARTUP_INSTALLER_UNAVAILABLE`，**不阻塞启动**，此时三个函数返回
>   `nil, "installer unavailable"`（T1 的降级文案原样保留）。
> - **日志**：每次调用恰好一行 `APP_INSTALL name=.. ok=..` / `APP_UNINSTALL name=.. ok=..` /
>   `APP_LIST n=..`；拒绝走 `APP_CAP_DENIED`，系统包保护额外一行 `APP_SYS_PROTECT`。
> - **应用侧的触发条件**：`installer unavailable` 只由"桥对象完全缺失"触发（`M.bridge` 返回 nil），
>   不再表示"内核没暴露"——T4 之后内核恒定暴露三者，桥的 `list` 也算桥。

17.3 **界面口径（26x20，见 §7.2）**：行 1 `installer <version>`；行 2
`disk <ok|none> <n> installed`；行 3..n-2 列表（`>` 选中；第二列 `d`=来源盘、`i`=/apps、
`s`=/system/system；26 列时带版本列，窄于 26 列丢掉版本列而不是截名字）；行 n-1 提示或结果文案；
行 n 计数器 `d<i> i<i> s<i> sel <i>/<total>`。低于 16 列或 6 行折叠成单行；`layout_selftest()`
不需要终端即可证明"行数 = rows、每行不超过 cols、退化单行、空机可渲染、拒权可渲染"。

17.4 **失败文案单点映射**：`M.error_text(err)` 是唯一映射点，返回 `文案, 分类`：
`hash check failed`（digest / sums / sha256 / unlisted）、`size check failed`（size）、
`cancelled`、`cancelled: no source`、`system app locked`、`not installed`、
`capability denied[: fs.write]`、其他 `failed: <原串>`。分类同时作为动作码返回，测试不必
重解析文字。判定顺序写死：cancel → no_source → capability denied → hash → size →
unavailable → system app → not installed → 兜底。

17.5 **卸载保护是双层的**：应用层先拒 `/system/system` 的行（桥一次都不调用，`system app locked`），
宿主返回 `system app` 时显示同一行。只有 `/apps/<name>.app` 能被卸载——与
`kernel/installer.lua` 的 `INSTALL_REMOVE_DENIED .. reason=system` 一致，UI 不新增语义。

17.6 **扫描与版本**：来源盘上的包版本从 `manifest.lua` **文本匹配**读取（绝不执行来源盘的代码），
读不到就是 `?`；已装包的版本来自 `api.sys.apps()`（运行时校验过的那份），未知也是 `?`。
没有驱动器 = `disk_ok=false`（`no disk, no apps` / `disk none`）；`fs.read` 被拒 =
`capability denied: fs.read` 直接上屏。扫描按 `M.SCAN_INTERVAL` 节流，安装/卸载后强制重扫。

17.7 **测试口径（T1 实测）**：新增 `tests/t_installer_app.lua`（10 组 **391** 断言：manifest /
scan / render / install / failures / remove / keys / run / selftest / package），
`tests/run.lua` 的 FILES 追加 `t_installer_app`；离线 **3,770 pass / 0 fail / 186 groups**
（N1 基线 3,379/176，+391 断言 / +10 组）。`install.set` 26 → **28 条**、TOTAL
**448,380 B / SIZE_WARN / MARGIN 98,855**、`WINDOW_OK sum=648,380`（+33,814 B =
`installer.app/main.lua` 32,735 + `manifest.lua` 1,079）。`tests/t_budget.lua` 的两处
`install_entries`（26 → 28）随清单同步，断言强度不变。

17.8 **测试 stage 位置（一处必须说明的偏离）**：`installer.app` 在 `run-tests.ps1` 里 stage 到
**`/tests/installer.app`**，而不是 `/system/system/installer.app`。原因：`t_desktop`
（`APP_SCAN ... loaded=3`、`STARTUP_PERMS_TABLE apps=3`、launcher 列表 `launcher,net,settings`）、
`t_settings`（`rt:scan() == 3`）把 stage 后的系统根写死为三个包，而这些文件不在 T1 的修改边界内；
为了不弱化它们，测试改从 `/tests` 读真实源码，并另加 `installer.package` 组证明它**属于**
`/system/system/installer.app`：`/install.set` 两条路径断言 + 把源文件复制进 case dir 后用
真运行时扫一遍（`APP_LOAD name=installer version=0.1.0 caps=fs.read,fs.write`、
`record.entry_path`、两个 cap 都可用）。将来统一系统根计数时，把 fixture 位置一并挪回去即可。

17.9 **T4 实测口径**：新增 `tests/t_installer_bridge.lua`（9 组 **227** 断言：surface /
authorization / unavailable / names / system / e2e / ui / startup / shape），`tests/run.lua` 的
FILES 追加 `t_installer_bridge`（排在 `t_installer_app` 之后）；离线 **3,997 pass / 0 fail /
195 groups**（T1 基线 3,770/186）。`install.set` 仍 **28 条**，TOTAL **458,100 B / SIZE_WARN /
MARGIN 108,575**、`WINDOW_OK sum=658,100`（+9,720 B = `kernel/apps.lua` 28,804→35,140
+6,336、`system/startup.lua` 26,022→28,367 +2,345、`installer.app/main.lua` 32,735→33,774
+1,039）；改动 lua 非 ASCII 计数 0。端到端用**真实** `kernel/installer.lua` + 真实文件系统
（`/t/installer_bridge/<case>` 下的 medium/`/apps`//system 三根）：装包 → `<apps_root>/box.app`
出现 → `list()` 报 `apps:box`（`list()` 只报两个**已装**根，来源盘不算安装）→ `uninstall` 删除 →
`list()` 为空，中间断言 `INSTALL_OK`/`INSTALL_REPLACE`/`INSTALL_REMOVE`/`APP_*` 日志与
`.tmp-box` 不残留；UI 侧再用 `api.sys` 当桥按回车，装/卸都成功，缺 `fs.write` 时显示
`capability denied: fs.write` 且不落盘。

## 18. PC 侧画面测试（M2）

18.1 **为什么需要**：CraftOS-PC 2.8.3 **没有 `term.getLine`**（实测），画到屏幕上的格子读不回来，
而 M2 之前所有启动链套件都传 `frame = function() return true end` 桩——它们只能证明"首帧被调用过"，
不能证明首帧画了什么。M2 加一层屏幕缓冲：把 `term` 换成可读的字符网格，让**生产代码**往上画，
断言读格子。

18.2 **harness 的做法（`tests/screen.lua`）**：`S.buffer(w, h)` 返回一个终端样子的表，实现启动链
用到的 term 子集（`write` / `blit` / `clear` / `clearLine` / `scroll` / `setCursorPos` /
`getCursorPos` / `getSize` / `set{Text,Background}Color(Colour)` / `get{Text,Background}Color(Colour)` /
`setCursorBlink` / `isColor`），另加断言读面（`char` / `fg` / `bg` / `row` / `trim` / `text` /
`find` / `find_row` / `snapshot` / `call_index` / `count_calls` / `wrote_before`）；`S.install(buf)` /
`S.with_term(buf, fn)` 把 `_G.term` 换成缓冲并保证还原（测试失败时也还原，否则 runner 自己的
`OFFLINE_*` 标记会写进缓冲）。**下面五条是实测出来的，不是照论文写的**——错一条，缓冲就会
和错误的启动画面一致：

- ROM 的 `print`/`write` 在**调用时**查 `term` 全局，所以只换表就够（实测：两次 `print` 两次
  `term.write`）；
- `print` 自己按 `getSize()` 切行并**显式** `setCursorPos`，所以缓冲的 `write` 必须**不折行、不夹光标**
  （实测 51 列屏写 60 字符后光标在 (61, 1)，只有屏内格子变）——若 `write` 自己折行，一条长日志会被
  画三遍；
- `clear()` **不移动光标**（实测 (1,19) → (1,19)）——首帧写完三行后自己 `setCursorPos` 就是为此；
- `blit()` **会推进光标**（实测 (1,1) + "abc" → (4,1)），颜色走 `0..f` 十六进制字母 → CraftOS 位掩码；
- `scroll(n)` 把行上移、用当前背景色清空底部、光标不动。`print` 在最后一行写完的顺序是
  `write` → `setCursorPos(1, h)` → `scroll(1)`，所以最后那次换行会把刚写的行顶上一行、底行留空
  （实测 19 行屏打 20 行后的状态）。

18.3 **断言了哪几屏（`tests/t_bios_screen.lua`，6 组 141 断言）**：

- `bios.frame`：真实启动链（真 `/system/boot.lua` + `/system/kernel/init.lua`，sandbox root + 真
  `PYROET-BOOT-OK-2` marker）的 **normal 首帧**。快照取在 `frame` **返回的那一瞬间**，因为链随后还会
  继续打日志把它盖掉。断言 51x19 上：第 1 行 `Pyroet OS 0.2.0`、第 2 行 `kernel ok`、第 3 行
  `normal journal none`、第 4–19 行**全空**、光标 (20,3)、`clear` 恰好 1 次、该帧自身 0 次 scroll；
  接着断言**调用顺序**（banner 的 `write` 在 `clear` 之后）与**帧前的屏**（是 boot 日志：有
  `STARTUP_PLAN action=normal journal=none tries=0`、没有 banner）；最后断言帧之后的日志落点：
  第 3 行第 20 列起 `STARTUP_UI_READY`、第 4 行 `STARTUP_PERMS_TABLE apps=0 loaded=0 pending=0 bad=0`、
  第 5 行 `STARTUP_LAUNCHER_MISSING name=launcher`、其后 `BOOT_COMMIT` / `STARTUP_COMMITTED`。
- `bios.frame.trial`：同一帧的**试启动**分支，第 3 行 `trial journal applied`，且全屏找不到
  `normal journal none`——两种分支靠格子区分，不靠日志。
- `bios.no_system`：root 下**没有 `/system`** → bootloader fatal、首帧不跑、屏幕保留 5 行日志，逐行断言
  `BOOT_NO_SYSTEM path=/t/ns/system why=missing` / `BOOT_FATAL reason=no_system` /
  `BOOT_ACTION action=fatal` / `STARTUP_PLAN action=fatal journal=none tries=0` /
  `STARTUP_FATAL reason=no_system`；第 6 行起空白、全屏**没有** `Pyroet OS `、`clear` 0 次。
- `bios.starter`：根 starter 的失败文案（`say()` 前缀 `Pyroet OS: `）：
  `Pyroet OS: cannot load /system/startup.lua` / `Pyroet OS: disk fault` /
  `Pyroet OS: shell only. Run recovery/flash.lua to` + `reflash /system.`
  （真实 `print` 在该空格处折行，故两条行断言 + 一条"两行拼回原句"的不变式）；`loadfile` 抛错与
  `startup failed` 两条同法断言（折行位置随消息长度变，用空白归一化后的整屏匹配）；**成功路径一帧都不画**
  （`write == 0`）。
- `bios.frame.small`：10x4 屏上首帧按"`write` 不折行"截断（`Pyroet OS ` / `normal jou`），把 18.2 的
  这条限制钉住，防止后来把折行塞进 `write` 悄悄改掉首帧。
- `bios.screen`：harness 自检——18.2 的每条实测行为各一条断言（光标越界、clip 计数、颜色、blit 推进、
  clear 不动光标、scroll、真 `print` 的折行与滚动、快照与调用记录）。

18.4 **限制（写死，别指望它做更多）**：缓冲只实现启动链用到的 term 子集，**缺的方法会直接 Lua 报错**
（不静默 nil，否则一个漏掉的 API 会表现为"画了个空白屏却通过"）；不做 monitor / window / 16 色以外的
颜色映射；**没有 `term.getLine`**（真机也没有）；`write` 不折行是模拟真机而非缺陷，要断言整句话时用
空白归一化（`flat`）；首帧之后的日志会覆盖第 3 行第 20 列起，所以"首帧"只认 `frame` 返回瞬间的快照，
"最终屏"只认第 1/2 行与位置无关的 `find_row`。

18.5 **测试口径（M2 实测）**：新增 `tests/screen.lua`（12,809 B）与 `tests/t_bios_screen.lua`
（25,283 B），两者非 ASCII 计数 0；`tests/run.lua` 的 FILES 追加 `t_bios_screen`（`run-tests.ps1` 本就把
`tests/*.lua` 整体 stage，**未改**）。离线 **4,138 pass / 0 fail / 201 groups**（T4 基线 3,997/195，
**+141 断言 / +6 组**）。`tests/` 不进 `install.set`，`sizecheck.py` 不变：仍 **28 条**、TOTAL
**458,100 B / SIZE_WARN / MARGIN 108,575**、`WINDOW_OK sum=658,100`。

## 19. `input` / `terminal` capability（O3）

19.1 **为什么是两个而不是一个 `ui`**：键盘与屏幕不是一回事。只读状态的包（画一屏就走）不该顺手拿到键盘；只处理按键的包（菜单/快捷键）不该能乱画。两个 cap 都在 §1.2(b) 的**扁平集合**里，**无继承、无蕴含**：只声明一个就只拿到一个。合起来才是"能交互的界面"。

19.2 **语义（运行时 `api` 面上只新增这两个字段）**：

| cap | app 拿到的 api | 宿主注入方式（`startup.lua` 已在做） |
| --- | --- | --- |
| `input` | `api.input.pullEvent(...)`（受控函数，参数/返回值原样透传；**D1 起是输入队列的弹出一格**，空队列返回 `nil`）+ `api.input.keys`（键名表，如 `keys.getName`） | `apps.new({ input = { pullEvent = fn, keys = <keys api> } })`；启动链传 `startup.P.default_input()` 的队列宿主（`push` / `pullEvent` / `pull` 三面，见 §20） |
| `terminal` | `api.terminal`（就是 term 句柄本身，不是副本） | `apps.new({ terminal = <term 类表> })`；启动链默认传 ROM 的 `term`（`opts.terminal` 可覆盖） |

- 形状刻意与既有 api 一致：`api.input.pullEvent` 是**函数**（同 `api.fs.read`），`api.input.keys` 与 `api.terminal` 是**表**（同 `api.peripheral`）。所以拒绝时 app 拿到的仍是**同形状的桩**，只会收到 `nil, "capability denied: <cap>"`，不会 nil-index（§10.3 的 404 语义）。
- 两者互不蕴含；宿主缺失时是 `capability unavailable: <cap>`（§4.2 口径），**不是** denied——"没声明"和"声明了但机器没这块"必须能区分。
- 生产宿主：`startup.P.default_input()` 返回一个**输入队列**（`push(event, ...)` 给派发器投递、`pullEvent(...)` 给 app 弹出一格、`pull` 是包装后的 `os.pullEvent` 且**只给** `kernel/desktop.lua`），`terminal = opts.terminal or term`。`opts.input` / `opts.terminal` 仍可注入（测试与未来的输入服务）；D1 的派发器复用同一个宿主表，否则 app 拿到的队列和派发器填的队列不是同一个（§20）。

19.3 **可观测面（拒绝路径与 status 可见性）**：

- 日志不新增 tag，沿用 `APP_CAP_DENIED app=.. cap=..` / `APP_CAP_UNAVAILABLE app=.. cap=..`：新能力进的是同一套拒绝机制，而不是另一条旁路。
- `rt:status().apps[i]` 新增 **`denied_caps = { [cap] = 次数 }`**：聚合的 `denied` 分不清"缺键盘"和"拒写盘"，而 UI/设置页要能分清（settings 展示的 cap 决策表因此也能落到具体 cap）。`capabilities` 仍是声明表、`grants` 仍是决策表，两者都包含这两个新 cap。
- `api.sys` 不因此扩张：`A.SYS_FUNCTIONS` 仍是 7 项（`status/apps/perms/launch/install/uninstall/list`），`input` / `terminal` **不是**系统调用（§10.7）。

19.4 **向后兼容（写死；§19.6 每条都有断言）**：

1. 旧包（manifest **没写** `capabilities`）= 声明空列表 = **全部拒绝**，**没有隐式授权**。这不构成回退：O3 之前 `api.input` / `api.terminal` **根本不存在**，旧包因此"本来就拿不到键盘和屏幕"；现在只是这两个字段以**桩**的形式出现，包照常加载、启动、被调度、退出。
2. 只声明其中一个就只拿到一个；另一个是 denied 桩。
3. `/etc/perms/<app>.cfg` 里**没有**的 cap = **未决定**，不是 denied（拒绝一定会被写成 `denied` 行）。旧决策文件只写了旧 cap 时，这些 cap 在该包**下一次 start** 走同一个 `ask` 策略：镜像包（`/system/` 下）= 预授权 → 授予；用户包 = 默认策略仍拒绝 → 记 denied。结果**落盘**（`PERMS_STALE app=.. caps=..` + `PERMS_DECISION` + `PERMS_SAVED`），所以迁移只发生一次；`ensure(..., {prompt=false})` 的只读 pass 不迁移、不写盘。这一条是 **D1-fix** 改写的：D1 给 launcher 加 `input`/`terminal` 后，真实 demo 盘上那份旧文件把两者判 denied，桌面拿不到键盘、把每个按键都吃掉（§20.9 有日志与复现）。坏文件仍是**全拒绝且不重写**（第 3 条上半段不受影响）。
4. 反过来，决策文件里出现 manifest **没声明**的 cap 是陈旧行：记 `PERMS_PRUNE`、仍然拒绝——**manifest 是上限**，文件只能收紧或确认，不能扩权。
5. 未知 cap 仍在 manifest 校验阶段硬失败（`unknown capability '<name>'`）：`keyboard`、`key`、`term`、`input.pullEvent` 都不是别名，也不做前缀匹配。

19.5 **它不做什么（写死，避免过度承诺）**：`input` / `terminal` 是 **API 收口**，不是沙盒（§1.2(a)）：app 与内核共享一个 Lua VM 与全局表，绕过 `api` 直接摸 `term` / `os.pullEvent` 的代码**拦不住**——cap 只约束"经过 api 的调用"，与既有 7 个 cap **同一强度**，不单独加码。O3 当时整机**还没有事件循环接管**（commit 后启动链返回、ROM shell 接管）；那条尾巴已由 **D1（§20）** 补上：commit 之后由 `kernel/desktop.lua` 持有唯一阻塞 `os.pullEvent` 并把事件派发给前台 app。

19.6 **测试与数字（O3 实测）**：新增 `tests/t_caps.lua`（**9 组 101 断言**）：cap 列表与 `permissions.CAPS` 逐项一致、缺 cap 被拒（含 `keys` 的方法调用、`type()` 形状不变）、有 cap 放行（宿主对象同一性、参数透传、真正写出的字节）、声明但宿主缺失 = unavailable（且不是 denied）、未知 cap 硬失败（4 个近似名）、旧包（无 `capabilities`）无隐式授权且照常运行、决策文件缺行 = 拒（且不追问）、文件授予未声明的 cap = `PERMS_PRUNE` + 仍拒、**真启动链端到端**（`startup.run` 注入的 `input`/`terminal` 就是 app 看到的那两个宿主：`STARTUP_LAUNCHER_STARTED name=ui` + `api.terminal.marker` + `api.input.pullEvent` 透传）。`tests/t_apps.lua` 的 `cap_count` 7 → 9，并补 `input` / `terminal` 的 `cap_known`；`tests/run.lua` 的 FILES 追加 `t_caps`。离线 **4,239 pass / 0 fail / 210 groups**（M2 基线 4,138/201，**+101 断言 / +9 组**）；`install.set` 仍 **28 条**、TOTAL **461,860 B / SIZE_WARN / MARGIN 112,335 / 距硬门禁余 167,285**、`WINDOW_OK sum=661,860`（+3,760 B = `kernel/apps.lua` +2,505 + `kernel/permissions.lua` +434 + `system/startup.lua` +821）；`tests/` 不进镜像，`tests/t_budget.lua` 的 `install_entries` 仍 28 未变；改动 lua 非 ASCII 计数 0。

## 20. 桌面常驻事件循环（D1）

20.1 **问题**：P2 起启动链走到 commit 就 `return`，CraftOS 拿回控制台 → 掉回 ROM shell（实机与 headless 都复现：launcher 只画一帧 `4 apps sel 1/4`，随后 `STARTUP_COMMITTED` 与三个 `>` 提示符）。launcher 的按键在 D1 之前是纯函数 + `opts.keys`，只有测试能驱动。D1 补的就是"commit 之后谁持有机器"。

20.2 **职责切分（唯一持有阻塞 pull 的地方）**：

- `system/kernel/desktop.lua`（新模块，**内核代码不是 app**）：`run()` 每轮**恰好一次** `opts.pullEvent`（生产 = 输入宿主的 `host.pull`，即 ROM 的 `os.pullEvent`），把事件规范化后 `host.push(...)` 投进输入队列，然后给调度器**恰好一步** `rt:tick()`。它不画屏、不碰文件、不调用 `os.shutdown`/`os.reboot`/`shell`。
- `system/startup.lua`：第 9 步从"调用可选 `opts.loop` 钩子"改成"进入常驻循环"，返回时带 `result.desktop` / `result.desktop_reason`。`opts.loop` 仍是**一次性交接钩子**（老测试用），`opts.loop = false` = headless。
- `launcher.app`（0.2.0，manifest 增加 `input` + `terminal`）：entry body 变成常驻循环——先画一帧，然后每步 `api.input.pullEvent()` 取一个事件；`nil` 就 `api.yield()`（**没有事件就没有重绘、没有 tick**），拿到 `key`/`char` 走 `M.handle_key`，只在动作非 `none` 时重画一帧。纯函数 `M.handle_key` 与 `opts.keys` 驱动的 `M.run` 原样保留（离线套件与布局自检靠它）。

20.3 **事件规范化（app 不该知道键码）**：`key` 事件投递为 `("key", "<name>")`，名字来自 `keys` 表反查（`D.KEY_NAMES` 里的名字优先：up/down/left/right/enter/escape/backspace/tab/delete/space），未识别的键码原样投递（数字，没有 app 需要理解它）。其余事件（`char`/`mouse_click`/`term_resize`/`rednet_message`/`peripheral`…）原样透传。

20.4 **前台与交接（写死）**：

- 前台 = **声明了 `input` 且 state=running 的 app 中 `starts` 最大者**，平局时保持当前前台。D1 时镜像里只有 launcher 声明 `input`，所以它就是桌面。
- 交接规则：某一步 tick 之后**新出现的** input app 接管键盘（`DESKTOP_FOREGROUND app=.. reason=launch`）——即 launcher 启动一个全屏交互 app 后，按键归它；它停掉后按上面规则回落到 launcher（`reason=settle`）。
- 换目标时各记一行 `DESKTOP_FOREGROUND`；`DESKTOP_EVENT n=<pull序号> event=<名> arg=<第一参数> app=<前台>` 每个事件一行，`n` 同时是 pull 计数。

20.5 **退出语义（写死）**：

| 条件 | 结果 |
| --- | --- |
| launcher 的 body 返回 `"quit"`（Esc / `q`） | `desktop_reason=quit` / `DESKTOP_DETACH reason=quit` → 启动链返回 → ROM shell |
| body 崩溃（`APP_CRASH`） | `reason=crash`（照实报告，不吞） |
| body 返回别的值 | 原样作为 reason（截断 24 字节） |
| 事件 `terminate` / `shutdown`（Ctrl+T） | 派发器**自己**处理，**不投给 app** → `reason=terminate` |
| `opts.max_events` 到上限（仅测试） | `reason=limit` |
| 没有 runtime / 没有 pull 源 / 没有输入队列 | `DESKTOP_SKIP reason=..` / `STARTUP_DESKTOP_SKIP`，绝不崩、绝不空转 |
| 前台 app 声明了 `input` 但**没被授予**键盘 | `STARTUP_DESKTOP_SKIP reason=input_denied app=..`，**不接管控制台**（回 shell 才能 `permissions.reset(app)`） |
| 同上，但缺的是屏幕（`terminal`） | `STARTUP_DESKTOP_SKIP reason=terminal_denied app=..`，同样回 shell |
| boot 计划 `fatal` | 走原 fatal 路径，**根本不进循环**（没有可交互的机器） |

循环返回是**正常结果**（`ok=true` + `committed=true` + `desktop_reason`），不是回滚信号：commit 已经发生，桌面坏掉不该把一台能开机的机器拖进重启环。`STARTUP_DESKTOP_ENTER/EXIT/SKIP/FAIL` 与 `DESKTOP_ENTRY/EVENT/FOREGROUND/DETACH/EXIT/SKIP/PULL_FAIL/TICK_FAIL/DELIVER_FAIL` 是全部可 grep 的 ASCII 日志。

20.6 **注入点与测试口径（关键）**：`startup.run` 的 `opts.pull_event` 就是那条阻塞 pull 的注入点；`opts.desktop_events` 限步数；`opts.desktop` / `opts.desktop_path` 可替换模块。**无事件时是阻塞等待，不是空转**：`tests/t_desktop_loop.lua` 用计数断言锁死（N 个事件 = N 次 pull = N 次 tick = N 次投递，`DESKTOP_EXIT pulled=N ticks=N`）。离线套件默认 headless 靠 `tests/run.lua` 里的 `_G.PYROET_DESKTOP_TEST`（否则 CraftOS 会在第一次 pull 上挂死），所以 `t_desktop_loop` 是**显式注入 pull** 来跑真循环的唯一套件。

20.7 **已知边界**：①键盘归前台 app，不是窗口系统：没有切换键、没有并发 UI，镜像里只有 launcher 声明 `input`；②`rt:tick()` 每事件推进**所有** running app 一步（launcher 之外的 app 照旧被调度），但只有前台拿到事件；③`api.input.pullEvent` 是队列弹出（`nil` = 没有投递），app 必须 `yield` 而不是忙等；队列上限 `INPUT_QUEUE_MAX = 32`，不抽的 app 只丢最旧事件（`host.dropped` 计数）；④`terminate` 一定回 shell，但 launcher 被权限拒到拿不到键盘时（`input` denied）只有 Ctrl+T 这一条出路——派发器仍然负责它；⑤Esc/`q` 是 launcher 自己的语义，其它 app 想退出得自己返回 `"quit"`。

20.8 **测试与数字（D1 + D1-fix 实测）**：新增 `tests/t_desktop_loop.lua`（**9 组 186 断言**）：`dispatcher`（键码→键名（含 GLFW 256 兜底）、每次 pull 一个 tick、terminate 不投递、quit/crash/limit 三种 reason、交接给新 input app、三种 skip）、`queue`（空队列 nil、过滤规则、上限丢最旧、`pull` 与 `keys` 面）、`boot`（真启动链 + 注入 pull：commit 在第一次 pull 之前、down/enter/escape 全链、`APP_START name=net`、`APP_EXIT ... result=quit`、`desktop_reason=quit`、3 事件=3 pull=3 tick=3 投递、每次事件只有一行 app 日志）、**`migrate`（真机回归：`/etc/perms/launcher.cfg` 只有旧两行 → `PERMS_STALE caps=input,terminal` → `granted=4 denied=0` → 文件补上两行 → down 移动 / enter 启动 net / escape 退出，且没有任何 `APP_CAP_DENIED cap=input|terminal`）**、**`grant`（显式拒绝 `input` / 只拒 `terminal` → `STARTUP_DESKTOP_SKIP reason=input_denied|terminal_denied`、0 次 pull、不接管控制台）**、`terminate`（Ctrl+T 回 shell 且 launcher 仍在跑）、`skip`（test 守卫 / `loop=false` / 无 launcher / hello 无 `input` / fatal 不进循环且 0 次 pull）、`launcher_keys`（Esc/q/Q/未知键/`term_resize`/方向键/回车）。同步改动：`t_desktop`（launcher `APP_LOAD ... 0.2.0 caps=fs.read,fs.write,input,terminal`、`granted=4`、新增 `STARTUP_DESKTOP_SKIP reason=test` 与 denied 路径的 `no_input`）、`t_permissions`（新增 `perms.stale` 组 24 断言：只读 pass 不迁移不写盘、start 迁移只在缺的 cap 上问一次、用户包不扩张、完整文件零写入）、`t_caps`（旧断言按新语义改写：文件缺 `input` → 询问一次 → `grants.input=false` 且落盘 `input=denied`）、`t_launcher`（manifest 0.2.0 / 4 cap）、`t_budget`（`install_entries` 28 → **29**）、`install.set`（+ `system/kernel/desktop.lua`）、`run-tests.ps1`（`$required` 增 `system/kernel/desktop.lua`）。离线 **4,606 pass / 0 fail / 229 groups**（O3 基线 4,239/210，**+180 断言 / +9 组**）；`install.set` **29 条**、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 **85,664**）、`WINDOW_OK sum=743481`；`tests/` 不进镜像；改动 lua 非 ASCII 计数 0。

20.9 **D1-fix：真机「只有鼠标有反应」（2026-11-01，已修，含真机日志）**。现象：升级到 D1 镜像后桌面停住，按键（上下/数字/回车）完全无反应，只有鼠标光标在动；拖滚动条时 `/kernel.log` 里 `DESKTOP_EVENT ... event=mouse_scroll` 疯涨。真机日志（demo 盘 `/kernel.log`）给出的因果链：

```
APP_LOAD name=launcher version=0.2.0 caps=fs.read,fs.write,input,terminal
APP_PERMS_APPLIED app=launcher granted=2 denied=2
APP_CAP_DENIED app=launcher cap=terminal
APP_LOG app=launcher msg=ready index=1 of=4
APP_CAP_DENIED app=launcher cap=input
APP_LOG app=launcher msg=no_input reason=capability denied: input
STARTUP_DESKTOP_ENTER name=launcher source=auto
DESKTOP_ENTRY app=launcher keys=115
DESKTOP_EVENT n=728 event=key arg=up app=launcher      <- 键事件已经到了派发器
```

**根因**：`/etc/perms/launcher.cfg` 是上一版镜像写下的（只有 `fs.read` / `fs.write` 两行）。旧规则"文件没写的 cap = 拒绝"把新声明的 `input` / `terminal` 判成 denied：launcher 于是**画不了**（terminal 拒绝）、**也拉不到事件**（input 拒绝），body 进 `M.idle` 永远挂起；而派发器照常 pull 所有事件（包括按键）并投进无人读取的队列——所以按键看起来"没反应"，只有 emulator 自己画的鼠标光标在动。事件/键名/队列/线程模型**都没有问题**（真机日志里 `event=key arg=up` 证明键码已翻成键名并投给了 launcher）。这是 **OTA 语义缺陷**，不是 launcher 缺陷：任何"镜像包在升级后新增 cap"的场景都会踩。

**修法（两处，都是通用规则而非 launcher 特判）**：①`kernel/permissions.lua`：文件里**没有**的 cap 视为**未决定**而不是拒绝；该包下一次 `start` 时只对缺失的 cap 重新走 `ask` 策略（镜像包 = 预授权 → 授予；用户包 = 默认策略仍拒绝），结果写回文件并记 `PERMS_STALE app=.. caps=..` + `PERMS_DECISION` + `PERMS_SAVED`，迁移只发生一次；只读 pass（`prompt=false`）不迁移、不写盘、也不缓存未决表（否则随后的 start 会命中缓存而跳过迁移）。②`system/startup.lua`：进循环前检查**授予集**而不只是声明——缺少 `input` / `terminal` 就 `STARTUP_DESKTOP_SKIP reason=input_denied|terminal_denied app=..` 并**不接管控制台**，回 shell 让用户能 `permissions.reset(app)`；桌面再也不会"吃掉键盘还什么都不画"。

**真机复验（在 demo 盘副本上做，原盘未动）**：把修复后的镜像文件覆盖进副本、**保留**旧 `launcher.cfg` → 开机日志出现 `PERMS_STALE app=launcher caps=input,terminal` → `PERMS_PREGRANT`/`PERMS_DECISION granted=true` ×2 → `PERMS_SAVED granted=4 denied=0` → `APP_PERMS_APPLIED app=launcher granted=4 denied=0` → launcher 画出 `up/dn enter run` / `4 apps sel 1/4`；随后用 `os.queueEvent("key", keys.down)` 注入真实 ROM 键码：`DESKTOP_EVENT n=1 event=key arg=down app=launcher` → `msg=key=down action=move index=2`、再 `key down` → `index=3 sel=net`（屏幕上是 `4 apps sel 3/4`），`os.queueEvent("char","q")` → `msg=quit key=q` → `APP_EXIT ... result=quit` → `DESKTOP_EXIT reason=quit pulled=3 ticks=3 delivered=3` → `STARTUP_DESKTOP_EXIT reason=quit` → 启动链返回、控制台出现 `>`（shell）。顺带确认本 ROM（CraftOS-PC 2.8.3）的 `keys` 表**没有** `escape`（`keys.escape`=nil），所以**退出用 `q`（或 Ctrl+T）**，Esc 只有终端真投递 256 时才生效（`D.ESCAPE_CODE` 兜底）。

20.10 **D1-fix 第二轮：方向键"不动" + 每行前面多一个 s（2026-11-01，真机日志 + 离线画面抓帧）**。权限修好之后按键仍然"选不动"，而且任何一次按键之后每一行前面都多一个 s。真机日志证明 launcher 的**数据层是好的**（`APP_LOG app=launcher msg=key=down action=move index=2`），问题在**屏幕所有权**。用 `tests/screen.lua` 把缓冲装成 `_G.term`、在 demo 盘副本上按真实事件流（CraftOS-PC 每次按键发 `key` 再发 `key_up`）抓帧，复现如下：

```
=== after key enter (launcher frame)     === after key_up enter (the bug)
 3|> installer          0.1.0       |      3|> s installer        0.1.0 |
 4|  launcher           0.2.0       |      4|  s launcher         0.2.0 |
 5|  net                0.1.0       |      5|  s net              0.1.0 |
 6|  settings           0.1.0       |      6|  s settings         0.1.0 |
19|4 apps sel 1/4                   |     19|d0 i0 s4 sel 1/4           |
```

**根因（两个独立缺陷叠加）**：①**被启动的 app 还在被调度**：`installer.app` 不声明 `input`/`terminal`，但它的 body 走 `M.run` 无限循环、每 tick 用 `M.paint(lines)` 重画自己的 `s <pkg>` 列表（term 缺省取 `rawget(_G,"term")`，绕过 cap——cap 是 API 收口不是沙盒）。调度顺序 installer 在 launcher 之前，所以 `key` 那一 tick 是 launcher 最后画（看起来正常），而 `key_up` 那一 tick launcher 不重画（action=none）→ **installer 的帧留在屏幕上**：每行一个 `s`、`>` 停在它自己的第 1 行 → 用户看到的就是"每行前面一个 S + 选项不动"。真机上 Enter 落在 index 1（字母序 `installer` 第一）所以必现。②启动链的日志在桌面阶段仍然 `print` 到控制台（`P.default_log`），每条 `DESKTOP_EVENT`/`APP_LOG` 都把桌面帧往上顶一行。**修法**：①`kernel/desktop.lua` 加"停车"：本步新启动、且**没有声明 `input`** 的 app 永远当不了前台，于是记 `DESKTOP_PARK app=.. reason=no_input caps=..` 并作为 skip 表交给 `rt:tick(skip)`——它保持 `running` 但不再获得时间片，因此不可能画到别人的屏幕上（`kernel/apps.lua` 的 `A:tick(skip)` 是唯一的运行时改动）；声明了 `input` 的 app 仍走原来的交接（`DESKTOP_FOREGROUND reason=launch`）。②`system/startup.lua` 的桌面阶段改用 `P.quiet_log`（只写 `/kernel.log`、不 `print`）并在进入时记 `STARTUP_DESKTOP_QUIET path=..`；只有**默认** logger 被换，测试注入的 `log` 原样保留（断言靠它）。③`launcher.app` 的按键**两种形态都收**：名字（派发器投递的 `"up"`/`"down"`）和原始键码（`key_up`、别的宿主或测试带进来的数字）；键码→名字映射由 `api.input.keys`（ROM 自己的 keys 表）运行时构建（`M.key_map`/`M.code_name`），所以 CraftOS-PC 的 `up=200 down=208 enter=28` 与 CC:Tweaked 的 `265/264/257` 都对，不硬编码；`M.dispatch_event` 对数字 `p1` 也先归一化。**测试**：新增 `desktop_loop.screen`（`t_desktop_loop` 共 **9 组 186 断言**，`_G.term` 换成 `tests/screen.lua` 缓冲）：被启动的 app 被停车（`DESKTOP_PARK`、`parked_count=1`）、停车后每一帧仍是 launcher 的列表（行首只能是 `"  "`/`"> "`、无 `s ` 前缀、只有一行有 `>`）、`down` 后标记下移（逐字断言行首字符 `screen_row3_head`..`screen_row6_head`）、名字形态与数字形态都能移动（含自造 keys 表证明不硬编码）。**真机复验**（demo 盘副本，原盘未动）：修复后同一事件流抓帧，`key_up` 帧与 `key` 帧一致，`> installer → > launcher → > net → > launcher` 随 down/down/up 移动，日志出现 `STARTUP_DESKTOP_QUIET` 与 `DESKTOP_PARK app=installer reason=no_input caps=2`。离线 **4,606 pass / 0 fail / 229 groups**；`install.set` 29 条、TOTAL **501,795 B / SIZE_WARN**（超 stretch 152,270、距硬门禁余 127,350）、`WINDOW_OK sum=701795`；改动 lua 非 ASCII 计数 0。

20.11 **D1-fix 第三轮：启动"没有反应"——把 parking 换成屏幕租借（2026-11-01，真机日志 + 画面抓帧）**。上一轮把"新启动且未声明 `input` 的 app"停车（parking），屏幕因此不再被抢，但用户按 Enter 启动 `installer`/`launcher` 时**屏幕上什么都没有**——parking 把"看不见"当成了"安全"。这一轮改成语义正确的**屏幕租借（screen loan）**：

1. **启动一个声明了 `input` 的 app**：照旧交接（键盘+屏幕都给它，`DESKTOP_FOREGROUND reason=launch`）。
2. **启动任何其它 app**：给它**屏幕租借**——它被真正调度（`DESKTOP_LOAN app=.. reason=no_input caps=..`），启动链立刻多给一步让它画出自己的首帧（`self:tick()`），期间**只调度它**（launcher 完全不跑，所以不可能覆盖它）；租借结束时该 app 被停车（`DESKTOP_PARK reason=loan_over`），launcher 拿回屏幕并被显式通知（`desk_focus` 事件 → `APP_LOG app=launcher msg=focus msg=display only: <name>`），**立刻重画**而不是等一个不会到来的按键。
3. **租借怎么结束**：①app 自己停下（body 返回 → `DESKTOP_LOAN_END reason=stopped`）；②**定时器**（`DESKTOP_LOAN_TIMER id=.. seconds=15` → `reason=timeout`）——没有键盘的 app 永远无法自己交还屏幕，这是硬兜底；③事件数兜底（`D.LOAN_EVENTS=40`，`reason=events`），给"事件源不提供 startTimer"的机器用。三者都不会留下死屏。
4. **不再有静默**：`kernel/apps.lua` 的 `start` 在拒绝路径上记一行 `APP_START_DENIED name=.. reason=no_such_app|killed|already_running|..`——**launcher 从桌面再启动自己**就是这条路径（`APP_START_DENIED name=launcher reason=already_running state=running`），同时 launcher 的提示行显示 `cannot start launcher`；日志 `DESKTOP_EVENT n=.. event=.. app=-` 把租借期间被丢弃的按键也记下来。

**真机复现与验证**（demo 盘副本，原盘零改动）。用注入 pull 抓帧可以看到"Enter → 屏幕变成 installer 自己的界面"：

```
=== pulled #2  (after key enter)
 3|> s installer        0.1.0 |
 4|  s launcher         0.2.0 |
 5|  s net              0.1.0 |
 6|  s settings         0.1.0 |
18|system app locked          |
19|d0 i0 s4 sel 1/4           |
```

再用**生产模式**（`os.queueEvent("key", keys.enter)` + 真 `P.run()`，不注入 pull）跑满 22 秒，`/kernel.log` 给出完整生命周期：

```
DESKTOP_EVENT n=1 event=key arg=enter app=launcher
APP_START name=installer
DESKTOP_LOAN app=installer reason=no_input caps=2
DESKTOP_LOAN_TIMER id=2 seconds=15
DESKTOP_EVENT n=2 event=timer arg=2 app=installer
DESKTOP_PARK app=installer reason=loan_over
DESKTOP_LOAN_END app=installer reason=timeout
DESKTOP_FOREGROUND app=launcher reason=loan_end
APP_LOG app=launcher msg=focus msg=display only: installer
```

注：注入 pull 的探针里 `os.pullEvent` 在某些嵌套 pcall 上下文里不会恢复（`bios.lua` 的 `native` 报错），这是**探针脚手架**的限制，不是产品路径——生产模式下 `host.pull`（同一个 `os.pullEvent` 包装）的定时器与队列都正常，上面就是证据。

**测试**：`t_desktop_loop` 重写 `desktop_loop.screen`（9 组 186 断言）：①三个不声明 `input` 的包（`aainstaller`/`aanet`/`aasettings`）依次 Enter → 屏幕变成**它们自己的界面**（逐帧断言内容、且不再含 launcher 的 `apps sel` 行）→ 定时器事件让 launcher 回来（`DESKTOP_LOAN_END reason=timeout` + `focus msg=display only: ..`）；②回到桌面后行首逐字断言（`"  |  |> |  "`）与 `6 apps sel 3/6`；③**自启动被拒**：`APP_START_DENIED name=launcher reason=already_running` + 提示行 `cannot start launcher` 且列表不变；④自停 app（`aastop`）→ `DESKTOP_LOAN_END reason=stopped`、launcher 立刻回来、下一键按键有效（标记移动到第 2 行）。`desktop_loop.boot`/`migrate` 的事件流加入 `timer` 事件，断言 `DESKTOP_LOAN`/`DESKTOP_LOAN_END`/`focus`。离线 **4,606 pass / 0 fail / 229 groups**（上一轮 4,457/220，+11 断言）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 85,664）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。

## 21. 系统应用真正可键盘操作（D1-fix 第四轮，T14）

21.1 **问题**：第三轮把"未声明 `input` 的 app"做成**屏幕租借**——可见，但约 15 秒后自动收回，因为它们拿不到键盘。用户拍板"做"：`settings` / `installer` / `net` 是本机唯一的三个用户界面，必须能真正用键盘操作，而不是租一屏静止画面。

21.2 **改动**：三个包都升到 **0.2.0**，manifest 追加 `input` + `terminal`（原有 cap 全部保留：settings 且新增 `fs.write`、installer 保留 `fs.write`、net 保留 `net.rpv`），body 从"无限自绘循环"改成**常驻事件循环**（与 launcher 同一套形态）：首帧绘制 → 每步 `api.input.pullEvent()` → 按键 → **只在有动作时重绘** → `q`/`escape` 返回 `"quit"`。每包自带 `M.KEY_NAMES`/`M.key_map`/`M.code_name`（键名 + 原始键码两种形态，映射由 `api.input.keys` 运行时构建）、`M.paint_once`（refresh+render+paint+clear）、`M.dispatch_event`（`desk_focus`/`term_resize` → 重绘）。

21.3 **每个应用能做什么（真的操作，不造桥）**：

| 应用 | 键位 | 操作 |
| --- | --- | --- |
| `settings` 0.2.0 | up/down 选行、left/right/enter 改值、`q`/escape 退出 | 编辑 `/etc/network.conf` 白名单键（`prefix` 24/16/8、`iface_side` back/top/front/bottom/left/right），**只重写那一行**，注释/顺序/未知键逐字保留；成功后立刻 `M.refresh` 回读，屏幕显示 `saved <key>=<value>`；写被拒显示 `save failed: <err>` |
| `net` 0.2.0 | up/down 滚动主机表、enter 或 `r` 刷新、`q`/escape 退出 | 重读 `api.net.rpv.status()` / `list_hosts()` / probe 目标（`/etc/net.target`）；无 `net.rpv` 时显示 `health degraded` + 原因，绝不假装在线 |
| `installer` 0.2.0 | up/down 选行、数字键直选、enter 执行、`c` 取消确认、`q`/escape 退出 | 列 `/disk/apps` + `/apps` + `/system/system` 的包并执行 install/remove（经宿主桥 `api.sys.install/uninstall`）；系统包 → `action=locked`；**没有可安装源时首帧显示 `disk none`**，没有桥时执行报 `unavailable`（T1 文案）——都不假装能装 |

21.4 **桌面侧的配套修复（本轮发现的真 bug）**：交接（launcher → input app）时**两个 app 都在被调度**，而输入队列是**共享**的，于是 launcher（记录序号在前）会把本该给前台应用的按键**抢走**——表现是"进入应用后按 q 退不出去"。修法：`kernel/desktop.lua` 的 `D:tick` 把"所有权"落到唯一 app 上——屏幕租借期间只有被租借的 app 被调度，否则只有**前台** app 被调度，其它 running app 一律进 skip 表（它们仍是 `running`，只是没有时间片）。另外 `settle` 在前台 app 消失、launcher 重新接管时投一个 `desk_focus`（`back from <app>`）并立刻 tick，所以**退出后回到 launcher 且键盘立刻可用**，不会把死应用的最后一帧留在屏幕上。

21.5 **测试**：新增 `tests/t_apps_ui.lua`（4 组，`tests/run.lua` 已注册）：`apps_ui.manifests`（三个 manifest 静态含 `input`/`terminal`、版本 0.2.0、原 cap 保留）、`apps_ui.settings`（首帧逐字断言 `Settings 0.2.0` / `> prefix 24` / `iface back` / `up/dn enter q=back`；down 后 enter 改值并**落盘**，断言 `/etc/network.conf` 只换一行：注释 + `prefix` + `keep` 保留、旧值消失；`q` → `"quit"`）、`apps_ui.net`（首帧 `ip 10.0.0.5/24`/`gw`/`health ok`；enter 与 `r` 各刷新一次）、`apps_ui.installer`（首帧列出已装包、`disk none`；enter 对系统包回答 `action=locked`）。同步更新：`t_settings`（cap 1→4、写入能力、`settings.write` 组改成"只改一行"的真实断言）、`t_net_app`/`t_installer_app`（版本与 cap）、`t_desktop`（`APP_LOAD` 行与 net 的首帧日志）、`t_budget`（net 版本）、`t_desktop_loop`（net 现在是 `input` 应用：`boot`/`migrate` 从"租借 + 定时器"改为"交接 + escape 退出 + `back from net`"）。离线 **4,606 pass / 0 fail / 229 groups**（上一轮 4,468/220，**+61 断言 / +4 组**）；`install.set` **29 条**、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 **85,664**）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。

21.6 **边界（写死）**：①`settings` 只改白名单里的两个键，不做自由文本编辑；②`net` 不写任何配置，只读 + 刷新；③`installer` 仍然只经桥（`api.sys.install/uninstall`），没有桥就报 `unavailable`；④屏幕租借（§20.11）保留，但从此只对**第三方**未声明 `input` 的包生效——镜像里的三个系统应用都已经是前台应用。

## 22. 可操作应用的退出与租借兜底（D1-fix 第五轮，T14 之后）

22.1 **真机现象（demo 盘 `/kernel.log` 直读）**：settings 进去后屏幕停在 "no editable settings / need /etc/network.conf"，按上下/左右全部 `action=none`，所以**画面永远不动**（用户以为死机/退不出去）；而 `q` 其实在日志里是成功退出的（`msg=quit key=q` → `APP_EXIT app=settings tick=144 result=quit` → `DESKTOP_FOREGROUND app=launcher reason=settle` + `focus msg=back from settings`）。另有一批旧记录 `DESKTOP_LOAN app=settings reason=no_input caps=1`（T14 之前）。

22.2 **根因（两个，都是"看起来像坏掉"）**：
1. **没有配置文件的机器上 settings 是死屏**：`M.ITEMS` 只在 `/etc/network.conf` 里**已有**该行时才出现 → 全新盘（`/etc` 里只有 perms）时 `items=0`，上下左右全部 `none`，屏幕一帧不变。它不是退不出去，而是**没有任何东西可操作**。
2. **退出只认部分事件形态**：三个应用的退出判断在"键码归一化之后"才做，`keys.escape` 在本 ROM 不存在（256 → `code_name` 返回 nil → 直接 `none`），所以 Esc 退不出；另外 `key` 数字形态（q=16）同样落不到退出分支。

22.3 **修法**：
1. `settings`：缺行/缺文件时**给默认值并允许写**（`prefix` 24、`iface_side` back），首次修改用 `M.save_item` 创建父目录与文件；`M.refresh` 记 `conf_missing`。全新机器上也是"两行可操作 + 改完立即落盘"。
2. 三个应用统一 `M.quit_key(key, api)` 并在**任何归一化之前**先判：接受键名 `q`/`Q`/`escape`/`quit`、原始键码（先查 ROM keys 表的 `q=16`、GLFW 的 `81`，再接受 `256` 作 Esc），另外 `dispatch` 收到 `terminate`/`shutdown` 也返回 `"quit"`（Ctrl+T 兜底）。`char "q"/"Q"` 原本就支持，现在三条路径并列。
3. **租借硬兜底**（`kernel/desktop.lua`）：①`start_timer` 不可用、或它返回 nil → **不开始租借**：记 `DESKTOP_LOAN_ABORT app=.. reason=no_timer`，直接停车 + `desk_focus`（`display only: <name>`），屏幕立刻回桌面；②租借期间除 `loan_events`(40) 的软上限外，新增**硬上限** `LOAN_ABORT_EVENTS=200` 与 `LOAN_ABORT_SECONDS=60`（时钟可注入），命中记 `DESKTOP_LOAN_ABORT ... reason=events|clock` 再 `DESKTOP_LOAN_END reason=abort`，一律停车 + 回桌面 + 键盘立即可用；③`startup.lua` 把 `loan_events`/`loan_abort_events`/`loan_abort_seconds`/`clock` 透传给桌面（此前只传了 `startTimer`/`loan_seconds`，测试与真机都拿不到这些旋钮）。

22.4 **测试**：`t_apps_ui` 新增 `apps_ui.settings_exit`（八种形态各跑一遍：键名 `q`/`Q`、`char q`/`Q`、原始键码 q、键名 `escape`、键码 256、`terminate`，全部返回 `"quit"`）与 `apps_ui.settings_fresh`（先删 `/etc/network.conf`：首帧仍有两行默认值、down+enter 改成 `iface_side=top` 并**创建**文件）；`t_desktop_loop` 新增 `desktop_loop.loan_abort`：①定时器"装了但永不触发"→ 硬步数上限触发 `DESKTOP_LOAN_ABORT reason=events` → `DESKTOP_LOAN_END reason=abort` → `DESKTOP_PARK reason=loan_over` → launcher 重画（帧里不再有应用界面、有 `apps sel`），且 `kernel:status().health == "ok"`（**租借不饿死服务**）；②`start_timer` 返回 nil → `DESKTOP_LOAN_TIMER_SKIP` + `DESKTOP_LOAN_ABORT reason=no_timer` + 停车 + 下一个按键就能移动 launcher 标记。另：`tests/run.lua` 在**每个套件之间 `os.queueEvent` + `os.pullEvent` 让出一次**——CraftOS-PC 的 "Too long without yielding" 看门狗按**一个事件循环回合**计时，而 run.lua 整个文件跑在一个回合里，套件变大后 t_ota/t_recovery_flash 会被看门狗打断（实测），让出后每个套件单独计时。

22.5 **真机复验（demo 盘副本，生产模式：队列事件 + 真 `P.run()`）**：
```
APP_LOG app=settings msg=ready item=1 items=2          <- 没有 conf 也有两行
DESKTOP_FOREGROUND app=settings reason=launch
DESKTOP_EVENT n=5 event=key arg=down app=settings
APP_LOG app=settings msg=key=down action=move item=2   <- 以前这里是 action=none
DESKTOP_EVENT n=6 event=key arg=enter app=settings
APP_LOG app=settings msg=saved iface_side=top          <- 文件被创建
APP_LOG app=settings msg=key=enter action=change item=2 detail=top
DESKTOP_EVENT n=7 event=char arg=q app=settings
APP_LOG app=settings msg=quit key=q                    <- 打字形态的 q 也能退
APP_EXIT app=settings tick=8 result=quit
DESKTOP_FOREGROUND app=launcher reason=settle
```
`/etc/network.conf` 内容 = `iface_side=top`（原文件不存在，本轮创建）。同一盘的另一次探测把 `down` 落到 `net` 上，`char q` 同样让它退出（`APP_EXIT app=net result=quit` + `DESKTOP_FOREGROUND app=launcher reason=settle`）。

22.6 **数字**：离线 **4,606 pass / 0 fail / 229 groups**（上一轮 4,529/224，**+40 断言 / +3 组**）；`install.set` **29 条**、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 **85,664**）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。

23. q 留在桌面，Ctrl+T 才是出口（D1-fix 第六轮）

23.1 **真机反馈**：在 launcher 上按 `q` 直接掉回 CraftOS shell —— 用户的意思是"回上一级/回桌面"，不是"退出整套系统"。根因很直白：launcher 的 `M.dispatch_event` 把 `escape` 与 `char q/Q` 都返回 `"quit"`，而启动链把 launcher 的 body 返回值当作"离开桌面"，于是整机交回 ROM shell。

23.2 **语义（写死）**：

| 位置 | `q` / `Q` / `Esc` | Ctrl+T（`terminate`） |
| --- | --- | --- |
| launcher（桌面） | **不离开**：提示行写 `Ctrl+T leaves Pyroet OS` 并重绘（`APP_LOG app=launcher msg=leave hint ... scope=desktop`） | 离开桌面回 shell（`DESKTOP_TERMINATE scope=desktop`） |
| 应用内（settings/net/installer/launcher 之外的 input 应用） | 退出该应用回 launcher | 也先退出该应用回 launcher（`DESKTOP_TERMINATE scope=app app=<name>`），**不**直接回 shell |
| 屏幕租借中的包 | 按键本来就不投递给它 | 结束租借回 launcher（`DESKTOP_TERMINATE scope=app app=<loaned>`） |

23.3 **实现**：launcher 新增 `M.LEAVE_HINT = "Ctrl+T leaves Pyroet OS"` 与 `M.quit_key`（键名 / 原始键码 / 256 三种形态），命中后**只**设提示并返回 `"repaint"`，不再返回 `"quit"`；`kernel/desktop.lua` 的 `terminate` 分支改成带作用域：租借中 → `DESKTOP_TERMINATE scope=app` + `loan_end("terminate")`；前台是应用 → 把 `terminate` **投递给该应用**（应用自己的退出路径）再 tick/settle，日志 `scope=app`；前台就是桌面 → `scope=desktop` 并返回 `"terminate"`（启动链随后回 shell）。启动链本身没有改动：桌面仍在跑时 terminate 只是让循环正常结束。

23.4 **测试**：`t_desktop_loop` 新增 `desktop_loop.leave`：①桌面上按 `q` → `result.desktop_reason == "terminate"`（不是 quit）、`pulled == 2`（q 之后还继续拉事件）、`APP_LOG ... msg=leave hint char=q scope=desktop`、无 `app=launcher msg=quit`、无 `reason=quit`，且**第 18 行逐字** `Ctrl+T leaves Pyroet OS`、帧里仍是 `apps sel` 列表；随后 `terminate` → `DESKTOP_TERMINATE scope=desktop`。②应用在前台时 `terminate` → `DESKTOP_TERMINATE scope=app app=net` + `APP_EXIT app=net` + `DESKTOP_FOREGROUND app=launcher reason=settle`，再按一次才 `scope=desktop` 离开。`launcher_keys` 组同步：`map_escape`/`map_q`/`map_q_upper` 由 `"quit"` 改为 `"repaint"` 并断言提示文本；`boot`/`migrate` 的退出从 `escape` 改成 `terminate`，`desktop_reason=terminate`，launcher 保持 `running`（不再有 `APP_EXIT app=launcher`）。

23.5 **数字**：离线 **4,606 pass / 0 fail / 229 groups**（上一轮 4,569/227，**+18 断言 / +1 组**）；`install.set` **29 条**、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 **85,664**）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。

24. 进入桌面即就绪，不需要先按一下键（D1-fix 第七轮）

24.1 **现象**：开机进桌面（或从应用/租借回到桌面）后画面不是立刻可用，按一下方向键才"出来"。用户以为要"按键才进 GUI"。

24.2 **根因（两个，且都真实存在）**：
1. **首帧被 boot 日志和 APP_LOG 盖住**：启动链第 7b 步先 tick 一次 launcher 让它画首帧，但紧接着的提交日志（`STARTUP_COMMITTED`/`BOOT_*`）走的是控制台打印，落在那帧上面；更关键的是 **app 运行时的日志 sink 还是控制台 logger**，所以桌面循环里每一条 `APP_LOG app=launcher msg=...` 也继续印在屏幕上——首帧（以及后来每次重画）画完就被日志抹掉，只有按键触发的下一次重画才看得到完整界面。
2. **桌面循环在第一次 pull 之前没有任何"画一帧"的动作**：`desktop.run()` 直接进 `while` 拉事件；首帧完全依赖 7b 那一次 tick。换言之进入桌面这个动作本身不画。

24.3 **修法**：
1. `kernel/desktop.lua`：`run()` 在进入循环前**主动画一次**——投一个 `desk_focus`（消息为空，不改提示行）+ `tick()`，并记 `DESKTOP_READY app=<前台>`；`desktop.new{ ready_paint = false }` 可关（纯单元测试的假运行时用）。
2. `kernel/apps.lua` 新增 `A:set_log(fn)`；`system/startup.lua` 在切到 `quiet_log` 之后把运行时的日志 sink 也指过去（`STARTUP_DESKTOP_QUIET` 之后）。这样桌面阶段所有 `APP_LOG`/`DESKTOP_*` 只进 `/kernel.log`，不再打印到屏幕——这是"漏网的 print"。
3. 返回路径本来就会投 `desk_focus`（应用退出 `reason=settle`、租借结束 `reason=loan_end`），launcher 收到就重画；本轮把这一点钉进测试（返回后的**下一帧**就是桌面，不需要额外按键，也不多消耗 pull）。

24.4 **测试**：`t_desktop_loop` 新增 `desktop_loop.ready`：①**0 个按键**时，第一次 pull 之前抓到的帧就是完整桌面——`ver ` 标题行、`> launcher` 选中行、第 18 行 `up/dn enter run`、第 19 行 `apps sel 1/N`，且帧里**没有** `STARTUP_COMMITTED` 等 boot 文本，`DESKTOP_READY app=launcher` 出现在日志里；②从应用退出（enter 进 net → escape）后，下一次 pull 前的帧已经是桌面，第 18 行 `back from net`，`pulls == 4`（没有多出一个"画一帧"用的 pull）；③租借结束（timer）后同理，第 18 行 `display only: <name>`。`dispatcher` 组的假运行时统一 `ready_paint = false`（它用假 tick 逐事件排空队列，不该被首帧事件干扰）；`terminate` 组的 `delivered` 期望 +1。

24.5 **真机复验（demo 盘副本，注入一次 pull，事件流只有一个 `terminate`）**：第一次 pull 之前抓到的帧即
```
 1|ver 0.2.0
 2|net degraded free 231177M
 3|> installer          0.2.0
 4|  launcher           0.2.0
 5|  net                0.2.0
 6|  settings           0.2.0
18|up/dn enter run
19|4 apps sel 1/4
pulls=1
```
日志：`STARTUP_DESKTOP_ENTER name=launcher source=injected` → `DESKTOP_READY app=launcher` → `DESKTOP_TERMINATE scope=desktop`。**没有任何按键**就已是完整桌面。

24.6 **数字**：离线 **4,606 pass / 0 fail / 229 groups**（上一轮 4,587/228，**+19 断言 / +1 组**）；`install.set` **29 条**、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 **85,664**）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。

25. Ctrl+T 打开电源菜单，不再退回 shell（D1-fix 第八轮）

25.1 **新要求**：禁用"退出系统"操作 —— 在桌面按 Ctrl+T（ROM 的 `terminate`）原本会让启动链回 CraftOS shell，用户不要这个；改成**拦截后打开电源菜单**。

25.2 **语义（写死，最终版）**：

| 位置 | `q` / `Q` / `Esc` | Ctrl+T（`terminate` / `shutdown`） |
| --- | --- | --- |
| 桌面（launcher） | 只写提示 `Ctrl+T opens power menu`，留在桌面 | **打开电源菜单**（`DESKTOP_TERMINATE scope=desktop` → `DESKTOP_POWER_MENU scope=desktop`） |
| 电源菜单内 | 取消，回桌面并重绘 | 仍在菜单内（重新打开） |
| 应用内 | 退出该应用回桌面 | **先**退出该应用回桌面（`DESKTOP_TERMINATE scope=app app=<name>`），回到桌面后再按才开菜单 |
| 屏幕租借中 | 本就不投递 | 结束租借回桌面（`scope=app`） |

菜单项固定三项：`Shutdown` / `Reboot` / `Cancel`；`up/down` 选择、`enter` 执行、`Esc`/`q` 取消。`Shutdown` 调 `os.shutdown()`，`Reboot` 调 `os.reboot()`，**执行前先写日志**（`POWER shutdown requested` / `POWER reboot requested`）；ROM 上没有该函数时该行显示 `unavailable` 并在下面一行给出原因（`os.shutdown unavailable`），不崩、不调用。桌面循环**任何分支都不再返回 "terminate"**，启动链里的 terminate 处理保留但正常流程走不到。

25.3 **实现**：launcher 内新增电源菜单（不新开 app 包、不加能力）：`M.POWER_ITEMS = {shutdown,reboot,cancel}`、`M.POWER_TITLE = "Power"`、`M.POWER_HOOKS`（测试替换，避免真关机）、`M.power_fn/power_available/power_reason/power_open/power_close/power_move/power_run/power_lines`；`M.render` 在 `state.power` 时走 `power_lines`（row1 `Power <ver>`，row3-5 三项带 `>` 标记，不可用项后面缀 `unavailable` 并另起一行原因，row19 `enter runs q=cancel`）；`M.dispatch_event` 在菜单打开时接管键盘（up/down/enter/Esc/q），并把 `power_menu`/`terminate`/`shutdown` 事件都变成"打开菜单"。`kernel/desktop.lua` 的桌面分支改投 `power_menu` 事件 + tick 后 `return false`；`power_menu = false` 是**测试专用**开关（单元测试断言旧 terminate 路径用）。`system/startup.lua` 透传 `power_menu`。

25.4 **测试**：`t_desktop_loop` 新增 `desktop_loop.power`（`os.shutdown`/`os.reboot` 用 stub，绝不真关机）：①桌面 Ctrl+T → 屏幕出现菜单（逐字断言 row3 `> Shutdown`、row4 `  Reboot`、row5 `  Cancel`、row19 `enter runs q=cancel`），日志 `DESKTOP_POWER_MENU scope=desktop event=terminate`，且**没有** `STARTUP_DESKTOP_EXIT reason=terminate`（循环是靠事件上限结束的 `limit`）；②down+enter → Reboot stub 被调用一次、`POWER reboot requested` 在日志里、Shutdown 零调用；③Esc 取消 → 回桌面且 row18 恢复 `up/dn enter run`；④应用内 Ctrl+T 先退应用（`scope=app`，`APP_EXIT app=net`），`DESKTOP_POWER_MENU` 只出现一次（桌面那一次）；⑤`os.shutdown = nil` 时菜单行显示 `> Shutdown unavailable` 且下方有 `os.shutdown unavailable`。旧的 `boot`/`migrate`/`leave`/`ready`/`screen`/`grant`/`dispatcher`/`loan_abort` 组统一加 `power_menu = false`（它们断言的是旧的 terminate 结束路径），`launcher_keys` 与 `leave` 的提示文本同步改成 `Ctrl+T opens power menu`。

25.5 **数字**：离线 **4,633 pass / 0 fail / 230 groups**（上一轮 4,606/229，**+27 断言 / +1 组**）；`install.set` **29 条**、TOTAL 见 sizecheck（**SIZE_WARN**，距硬门禁 629,145 仍有余量）；`WINDOW_OK` 同步；改动 lua 非 ASCII 计数 0。

26. installer 宿主桥（已接通）与桌面 OTA 入口（T5）

26.1 **installer 桥状态**：`api.sys.install / uninstall / list` 在 T4 就已实现并被 `startup.lua` 第 3b 步的对象接上（`P.build_installer` → `ctx.installer` → 运行时 `self.installer`），本轮**没有新增文件**，只补了 OTA 面并在测试里把四类断言钉住。接口（平函数，返回值固定）：

| 调用 | 成功 | 失败（第二返回值） |
| --- | --- | --- |
| `api.sys.install(name)` | `true, {version=...}` | `"bad name"` / `"installer unavailable"` / `"no_source"` / `"copy failed ..."` / `"manifest_name:..."` / hash/size 文案 / `"capability denied: fs.write"` |
| `api.sys.uninstall(name)` | `true` | `"system app"` / `"not installed"` / `"cannot remove"` / `"bad name"` / `"capability denied: fs.write"` |
| `api.sys.list()` | `true, {..}` | `"capability denied: fs.read"` |

调用方校验：运行时按**调用记录自己的 cap 集**判定（installer 声明 `fs.write`，只读应用拿不到写面）；`installer unavailable` 表示宿主没送来 installer 对象；应用永远拿不到 `/system/kernel` 的文件句柄——`sys_api` 只给函数。

26.2 **OTA 面（本轮新增）**：`api.sys.ota_list()` / `api.sys.ota_apply(name)`，cap 分别是 `fs.read` / `fs.write`，实现全在内核：

- 源规则（按顺序合并）：①`/disk/ota/meta.txt` 是**镜像更新**，内容是一条 PYROET-OTA/2 报文（`PYROET-OTA/2 META version=.. files=.. manifest_sha=<64hex>`），由 `kernel/ota.lua` 的 `O.parse_meta` 解析，条目 `{name="image", version=, kind="image", files=}`；②`/disk/apps/<name>.app` 是**包更新**，版本取自该目录的 manifest，条目 `{name=, version=, kind="package"}`。二者都没有 → `nil, "no source"`；meta 解析失败 → `nil, "bad meta"`；读不出 → `nil, "unreadable meta"`；没有 ota 模块 → `nil, "ota unavailable"`。
- 应用规则：`ota_apply("image")` 永远返回 `nil, "image ota needs recovery"`（镜像级更新归 §12 恢复/刷写，桌面不越权）；`ota_apply(<package>)` 走**与 `api.sys.install` 同一个 installer 对象**（同一套校验与错误文案），日志 `APP_OTA_APPLY name=<n> ok=..`。
- 日志：`APP_OTA_LIST ok=true entries=N`、`APP_OTA_LIST ok=false reason=no_source|bad_meta|no_module|unreadable`、`APP_OTA_NO_MODULE`、`APP_OTA_APPLY ...`。

26.3 **桌面入口**：电源菜单由三项变四项 —— `Update` / `Shutdown` / `Reboot` / `Cancel`（`Update` 永远可选，不依赖 `os` 函数）。`Update` 打开 **Updates** 屏（launcher 自绘，事件驱动，不新开 app）：

```
Updates 0.2.0
> demo 1.0.1 package
...
enter install q=back
```
没有源时第二行是 `no updates`，第三行是内核给的原因（`no source` / `bad meta` / `no ota bridge`）；`up/down` 移动、`enter` 应用（日志 `ota apply name=.. ok=..`，失败显示内核文案如 `hash check failed`，不崩）、`q` 返回桌面。**不用 Esc**（ROM 不投递）。

26.4 **测试**：新增 `tests/t_sys_ota.lua`（3 组 65 断言，已注册）：`ota.list`（无源 / 包源 / 镜像 meta / 坏 meta / cap 门槛）、`ota.apply`（包安装成功且落盘、镜像被拒 `image ota needs recovery`、缺包 `no_source`、卸载回滚）、`ota.launcher`（菜单第一项是 `Update`、四行渲染逐字、up/down/enter/q、无源时 `no updates`+原因、apply 失败显示 `hash check failed`、无桥时 `no ota bridge` 不崩）。`t_ota.lua`（kernel/ota.lua 协议套件，930 行）**保持原样**。电源菜单的四项也在 `t_desktop_loop` 的 `desktop_loop.power` 里逐字断言（已随本轮更新：`Update` 在第 3 行）。

26.5 **数字**：离线 **4,699 pass / 0 fail / 233 groups**（上一轮 4,633/230，**+66 断言 / +3 组**）；`install.set` **29 条**（无新增文件）、TOTAL **560,258 B / SIZE_WARN**（超 stretch 210,733、距硬门禁 629,145 余 **68,887**）、`WINDOW_OK sum=760258`；改动 lua 非 ASCII 计数 0。

## 修订记录

- 2026-10-28: slot policy = single-active + trial boot + delete old after boot.ok (supersedes earlier A/B wording); streaming write to inactive slot; budget restated at 1024-byte components
- 2026-10-29: P2 落地引导链 / 服务管理 / 应用运行时——新增 `boot.lua`（槽位状态机、`.tries` 先落盘再进槽、第三次回退并删坏槽、指针原子写 tmp → 删旧 → move，`fs.move` 被拒时降级为复制 + 校验 + 删源）、`kernel/init.lua`（注册 / 依赖拓扑 / 单服务失败隔离 + health 聚合）、`kernel/apps.lua`（`<name>.app` 包、每 app 一 coroutine + 权限域、未授权返回 `nil, "capability denied: <cap>"` 不抛错、生命周期与配额）、`startup.lua`（boot → kernel → 系统服务 → 首帧 → `boot.commit()`；内核 fatal / 首帧失败 / commit 失败一律 `os.reboot()` 让 `.tries` 生效）。**两处与本文档的偏差在此写死**：(1) `/boot.ok` 按槽写 `/slots/<x>/boot.ok`——§2.4/§2.6 只有在标记随槽消亡时才能成立（否则 OTA 后新槽继承旧槽的提交、永不试启动，回退时也无法问“另一个槽是否已提交”）；(2) 提交标记里的整镜像 sha256 取自 bootstrap 写在槽内的 `/slots/<x>/.image` 描述行，缺失时记 `sha256=none`，bootloader 不自己哈希整棵槽（每次开机数百 KB I/O 不可接受）。rpv 子集按 §3.1 修正为 9 项含 `node`、实装 **131,590 B**；`tools/sizecheck.py` 实测 TOTAL **202,728 B / SIZE_PASS（余 59,416）**；`tests/` 是开发材料，不进镜像、不进 `install.set`。
- 2026-10-29: P3 落地网络服务层 + 静态 hosts + Net 系统 app——新增 `net/hosts.lua`（严格解析、整文件原子生效、mtime 5 s 重载、rpv 兼容 `hosts_load`）、`net/service.lua`（kernel 服务 `net`：读 `/etc/network.conf`、`node_new`+`setup`、静态邻居/路由、hosts 注入、UDP probe 与 `stats()`，失败一律 degraded + `NET_*` 日志不 panic）、`system/net.app`（26x20 UI，`net.rpv`+`fs.read`，目标从 `/etc/net.target` 读）；`install.set` 增至 18 条，TOTAL **257,650 B / SIZE_PASS / 余 4,494 B**；离线 **1,116 pass / 0 fail / 55 groups**。边界写死：`node:lookup()` 仍为 nil、无 ICMP/ping、probe 只有 timeout/unreachable 两态；不设 `cfg.hosts_file` 以免 `RPV_SUBSET_NO_SERVICES`（§9.2）。
- 2026-10-29: P4 落地桌面 + 设置 + 首次启动权限确认——新增 `kernel/permissions.lua`（`/etc/perms/<app>.cfg` 决策文件、首启一屏询问、坏文件全拒绝且不重写、`PERMS_PRUNE` 区分陈旧行、`permissions.reset(app)`）、`system/launcher.app`（扫 `/apps`+`/system`、名称/版本列表、方向键/数字键+回车经 `api.sys.launch` 启动、slot/version/net/free 状态行、26x20 自检与窄屏单列降级）、`system/settings.app`（严格只读：只声明 `fs.read`，应用/cap 决策清单、`/etc/network.conf` 脱敏、存储与门禁口径、同一套布局自检）；`kernel/apps.lua` 增 `set_permissions`/`apply_permissions`（拒绝走 `capability denied` 桩、app 照常运行）、`api.sys` 内省面、`api.fs.getFreeSpace`；`startup.lua` 增 3c 挂权限表、7b 读表 + 启动 launcher + hello 回退（整段 pcall，失败不影响 commit）。**§8.4 按用户拍板改写**：硬门禁 349,525 B（1/3 MiB），262,144 仅作 stretch 报告。`install.set` 增至 23 条，TOTAL **333,140 B / SIZE_WARN（超 stretch 70,996 B，距硬门禁余 16,385 B）**；离线 **1,807 pass / 0 fail / 77 groups**（P3 基线 1,116/55，新增 **691** 断言 / 22 组）；新增 lua 非 ASCII 计数 0。
- 2026-10-29: P5a 应用安装器与系统 OTA 客户端。新增 `kernel/installer.lua`（暂存/校验/原子替换与 copy 降级/卸载保护/list）与 `kernel/ota.lua`（PYROET-OTA/1 协议、逐块与全量 SHA256、写非活动槽、原子翻指针、不写 /boot.ok，与 bootstrap 救援通道同一信任模型）。测试基线 **2,089 pass / 0 fail / 109 groups**（+282 断言 / +32 组）。体积：两个文件共 26,165 B，超出当前剩余空间 16,385 B，**尚未加入 install.set**（门禁保持绿，TOTAL 333,140 / MARGIN 16,385）；建议裁剪项见 11.7。
- 2026-10-29: P5b 落定方案 D + 恢复/刷写工具。`install.set` 启用 `kernel/installer.lua` 与 `kernel/ota.lua`，把 `system/net.app`（15,930 B）移到 `pyroet-os/examples/net.app/`（可安装示例，不进镜像），23 条、TOTAL **343,375 B / SIZE_WARN（距硬门禁余 6,150）**；测试改为从 `examples/` stage 同名 fixture（断言未删）。新增 `recovery/proto.lua`（5,444 B）、`recovery/flash.lua`（2,496 B）、`recovery/bootstrap.lua`（1,867 B），三文件合计 **9,807 B**、不进镜像、不进 install.set；launcher/settings 本来就是通用 `<name>.app` 扫描，startup 无默认 net.app 分支（见 §12）。离线 **2,311 pass / 0 fail / 128 groups**（P5a 基线 2,089/109，+222 断言 / +19 组）；新增 lua 非 ASCII 计数 0。
- 2026-10-29: **G1 门禁改三层 + net.app 加回镜像**。`tools/sizecheck.py` 默认值改为 `--budget 629,145`（3/5 MiB 硬门禁）、`--stretch 349,525`（1/3 MiB 目标线，SIZE_WARN 不判死）；新增 `--backup-cap`（默认 200,000）与更新窗口检查 `total + cap <= 900,000`，输出 `WINDOW_OK sum=.. limit=900000` / `WINDOW_FAIL total=.. cap=.. sum=.. limit=900000`（后者 exit 1，且 `SIZE_FAIL` 时照常打印）。`system/net.app/`（main.lua 15,493 + manifest.lua 437 = 15,930 B）从 `examples/net.app/` 移回 `pyroet-os/system/net.app/`，`examples/` 不再保留任何副本；`install.set` 增至 25 条、TOTAL **359,305 B** → `SIZE_WARN`（超目标线 9,780 B，距硬门禁余 269,840 B）、`WINDOW_OK sum=559,305`。`tests/run-tests.ps1` 只 stage `system/net.app` 一份（删掉 examples staging 与 fixture 双份）；`tests/t_budget.lua` 的 install_set / 示例断言按新布局反转（`has_net_app_*`、`has_system_net_text`、`no_examples_copy`，install_entries 25），`t_desktop`/`t_settings` 的 `loaded=3`/`apps=3`/`rt:scan()==3` 断言原样保留。离线 **2,313 pass / 0 fail / 128 groups**（P5b 2,311/128，+2 断言）；改动文件非 ASCII 计数 0。§0.4/§4/§7.1/§8.4 同步为三层口径，settings.app 的 `M.BUDGET` 与 §10.6 明确记为待同步遗留（改它会计入镜像体积并牵动两条断言）。
- 2026-10-29: **P6-2 系统更新模型改为“单树 + journal + 差异备份”**（设计见 `P6-design.md`，口径见 §13）。`boot.lua` 从“双槽整镜像 + 指针”改为单一 `/system/` 树 + 全局 `/boot.ok`（`PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..`）+ 全局 `/boot.tries`：17 行决策表、journal 三态（`prepare|applying|applied`）+ `rolledback` 墓碑、按 seq 保留两代、回滚按内容哈希幂等推进、fatal 只有 `no_system`/`rollback_fail`/写盘失败且不 reboot、2.5 迁移顺序（`boot.ok` → 空 `prepare` journal → 删 `/slots`）；删除 `/boot.slot`、指针原子写、按槽 `boot.ok`/`.tries`/`.image` 全套逻辑。`kernel/ota.lua` 改为 `PYROET-OTA/2` 文件集协议（`META version= files= manifest_sha=` / `FILE <relpath> <size> <sha256>` / `DATA <relpath> <offset> <hex>`，`MAX_DATA=8192`、`F_max=65536`）：收齐清单即算聚合哈希（`relpath\0size\0sha\n` 排序后一次 SHA-256）比对，不符 `OTA_REJECT stage=verify`、状态 `rejected`、`retry()` 可重拉；`BACKUP_CAP=200,000` 在写 `prepare` 前检查（`stage=cap`）；通过后才 `journal(prepare)` → 逐文件 “`.part` → 备份并校验 `old_sha` → move 进 `/system` → 回读校验 `new_sha`” → `journal(applied)`；应用期失败立即回滚（`OTA_FAIL` + `OTA_ROLLED_BACK`）。`startup.lua` 的 commit 改为写全局 `/boot.ok`，`manifest_sha` 取自 journal（无更新记录时保留旧 marker 的 `manifest_sha`，均无则记 `none`），日志字段换成 `manifest_sha`。§2.3–2.8 与 §11.3–11.5 标记 superseded（历史保留）。测试：`t_boot` 23 组 / `t_ota` 18 组 / `t_startup` 14 组重写（含 §9.3 五条回滚失败路径与 5 个崩溃窗口），`t_desktop`/`t_budget` fixture 改全局凭据；离线 **2,651 pass / 0 fail / 149 groups**（P6-2 前 2,313/128，+338 断言 / +21 组）；TOTAL **392,500 B / SIZE_WARN**（+33,195 B：`boot.lua` 38,721、`kernel/ota.lua` 28,304、`startup.lua` 20,280），`WINDOW_OK sum=592,500`；改动文件非 ASCII 计数 0。遗留：`recovery/*`、`settings.app`/`launcher.app` 的槽位读取与 `/kernel`、`/rpv` 的源码路径迁移未动（见 §13.9）。
- 2026-10-29: **P6-3 布局统一到单一 `/system` 树 + 恢复工具改文件集**。根的 `/startup.lua` 改成 1,071 B starter（只 `pcall(loadfile, "/system/startup.lua")` 并调用；加载失败/抛错打印 ASCII 并落回 shell，不 reboot）；`/kernel`、`/rpv`、`/net` 搬进 `/system/`，系统应用搬到 `/system/system/<name>.app`（`/etc`、`/apps` 留在根）；新增 `boot.migrate_layout()`（重命名式迁移、目标已存在则 skip、失败逆序回滚、fatal `layout_migrate_fail`，日志 `BOOT_MIGRATE_LAYOUT*`，可重入）；`recovery/proto.lua`/`flash.lua`/`bootstrap.lua` 改写为 `PYROET-FLASH/2` 文件集（`META version= manifest_sha= files=` + `<relpath> <size> <sha256>`、`GET <relpath> <idx>`、`DATA <relpath> idx= sha256= <hex>`，`MAX_DATA=8192`；无槽无指针，`P.target()` 取代 `P.ptr()`；暂存校验后才替换、失败按哈希逆序撤销、成功后写 `applied` journal 供试启动回滚）；`settings.app` 门禁文案改三层（`M.BUDGET=629145`/`M.STRETCH=349525`/`M.WINDOW=900000`/`M.BACKUP_CAP=200000`），launcher/settings 的系统应用扫描根改 `/system/system`；`install.set` 26 条、TOTAL **401,640 B / SIZE_WARN**、`WINDOW_OK sum=601,640`；离线 **2,880 pass / 0 fail / 158 groups**（P6-2 基线 2,651/149，+229 断言 / +9 组；新增 `tests/t_layout.lua`，三个 recovery 套件按文件集模型重写）；改动 lua 非 ASCII 计数 0。
- 2026-10-29: **G2 清掉槽位时代的兜底读取**。`system/system/launcher.app/main.lua` 与 `system/system/settings.app/main.lua` 删除对 `/boot.slot`、`/slots/<x>/boot.ok`、`/slots/<x>/.image` 的全部读取分支和 `slot <x>`/`slot ?` 文案：`M.SLOT_PATH` → `M.BOOT_OK = "/boot.ok"`，`read_boot()` 只解析全局 `PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..`（`manifest_sha` 为主键，P6 之前留在同一文件上的 `sha256` 作同义兜底，`none` 丢弃），新增 `M.short_sha()` 取前 8 位十六进制；launcher 行 1 变 `ver <v> sha <8hex>`（21 列），settings 变 `os <v>` + `image <v> sha <8hex>`（24 列），26x20 不越界、纯 ASCII；两个 app 的 `layout_selftest()` 各加一条“任何行不得再出现 slot”的检查。`tests/t_launcher.lua`/`t_settings.lua` 的 fixture 改全局 `/boot.ok`，槽位断言逐条替换为等价的全局标记断言（`slot a` → `no_slot_field` + `source=/boot.ok` + `sha abababab`、`.image` 兜底 → `manifest_sha=none` 被丢弃、`/boot.slot` 垃圾输入 → `/boot.ok` 垃圾输入、`H.absent(...,"slot")`），断言未删；`t_desktop` 的 fixture 本来已是全局凭据，未改。文档 §1.1/§2.2/§7.4/§10.5/§10.6/§11.2/§11.6 同步或标注 superseded，§13.9 记为已清账。离线 **2,890 pass / 0 fail / 158 groups**（P6-3 2,880/158，+10 断言）；TOTAL **401,769 B / SIZE_WARN**（+129 B）、`WINDOW_OK sum=601,769`；改动 lua 非 ASCII 计数 0。
- 2026-10-29: **B7 接通发布（CI + 打包 + 根 README），口径见 §14**。`tools/build_release.py`：`VERSIONS` 增 `"pyroet-os": "1.0.0"`，`EXCLUDE_FROM_RELEASE` 增 `"pyroet-os": ("tests/", "tools/")`（按相对路径前缀匹配，`recovery/` 与两份文档保留在包内）。`.github/workflows/release-builds.yml` 按 itn-pass 同一模式补四处：dispatch 选项 `- pyroet-os`、tag `fromJSON` 名单加 `"pyroet-os"`、分支构建循环 `for project in sentinel cardkey pylib itn-pass pyroet-os`、`case` 分派 `sentinel|cardkey|pylib|itn-pass|pyroet-os)`；未重构任何行。根 `README.md` 加项目表一行（掌机类 Android OS、单树 + journal 文件集更新、含 EDL 式 `recovery/`）、构建命令一行（`python tools/build_release.py --project pyroet-os --out dist/release` → `dist/release/pyroet-os-v1.0.0.zip`，注明不含 `tests/`、`tools/`）、tag 名单一处。实测 `pyroet-os-v1.0.0.zip` **33 成员**（32 个 `pyroet-os/` 成员 + 根 `LICENSE`），同一内容重跑字节相同；**zip 的字节数与 sha256 刻意不写进本文档**——`DECISIONS.md` 自己是包内成员，写进去就改变哈希（构建输出与 release 页面才是可信来源）；成员含 `recovery/`(3)、`DECISIONS.md`、`P6-design.md`、`install.set`、`startup.lua`、`system/`(25)，不含 `tests/`、`tools/`。**其它项目零影响**：sentinel / cardkey / pylib / itn-pass 四包用 HEAD 版与新版脚本各构建一次，sha256 逐一相同（`d0fa417d…` / `686e1bb4…` / `e67772f1…` / `46575505…`）。本任务未改任何 `.lua`。
- 2026-10-29: **O2 落地 OTA 服务端（分发中心侧）**。新增 `ota/server.lua`（636 行纯 ASCII，表模块 `local M = ... return M`）：`M.new{fs,log,rednet,channel,manifest|dir}`、`M.build_manifest(dir)`（发布目录 + `meta.txt` 侧车，按 relpath 排序算逐文件 sha256 与 §3.2 聚合哈希，`files=`/`manifest_sha=` 可选钉，白名单/0 字节/`F_MAX`/`MAX_FILES` 不合一律 fail-closed）、`M.handle(msg,sender)`（`GET meta`/`GET <idx>`/`GET <idx> <offset>` → `META`/`FILE`/`DATA`，非法请求回 `ERR reason=..`，非本协议前缀静默忽略）、`M.serve()`/`M.stop()`；常量、路径白名单、hex 大小写、offset 步长与末块长度全部与客户端逐项对齐（白名单是复制 + 双向差分，来源注释点名 `system/kernel/ota.lua:235-260`）。新增 `tests/t_ota_server.lua`（897 行 / **368 断言 / 10 组**），在同一进程用 stub rednet 把客户端与服务端接起来跑完整更新，含 `valid_path` 与 `manifest_hash` 双向交叉、线上 8 条请求逐条断言、META 说谎/字节改坏/丢 DATA 回包/丢请求/`files=0`/超大文件/非法路径/越界 idx/`retry()`/`serve()` 全路径。`tests/run.lua` 的 FILES 追加 `t_ota_server`，`tests/run-tests.ps1` stage `ota/*.lua` 并把 `ota\server.lua` 列入 `$required`。**不进镜像**：`install.set` 仍 26 条、TOTAL **401,778 B / SIZE_WARN / MARGIN 52,253**、`WINDOW_OK sum=601,778`；离线 **3,258 pass / 0 fail / 168 groups**（基线 2,890/158，**+368 断言 / +10 组**）；新增/改动 lua 非 ASCII 计数 0。文档新增 §15；发布 zip 的 `pyroet-os/` 成员会因 `build_release.py` 的 `rglob` 自动 +1（见 §15.6），本轮不改打包脚本。
- 2026-11-01: **网络定位声明（N2，跨项目口径）**。在 §0.5 写死：**本项目不做设备入网鉴权**；网络层只做连接（rpv/UDP）与加密，**不做准入判定**（无认证服务器、无设备白名单、不要求凭证才能联网）。同时声明：装机侧额度（`itn-pass/` 的装机/分发凭证）与联网能力无耦合，网络通不通只取决于链路与配置。本条只改本文档，未动 `pyroet-os/` 任何代码或测试。
- 2026-11-01: **N1 关掉两条「已知限制」——`size` 运行时校验 + `net` 默认注册**（口径见 §16）。`kernel/ota.lua`（+3,566 B）：下载/`.part`/`move` 后三处比字节数，`.part` 不符在"没有文件落地"时 `boot.cleanup()` 后 `OTA_REJECT stage=verify reason=size file=.. got=.. want=..`（可 `retry()`），已有落地则 `OTA_FAIL stage=verify` + 回滚；`move` 进 `/system/` 后再量一次（`OTA_FAIL stage=install`）防截断。`kernel/installer.lua`（+3,854 B）：`SHA256SUMS` 第三列（两种列序）逐文件比对 + manifest `size` 整包总量（`manifest.lua` 不计，原始表从 `manifest.raw` 读），不符 `INSTALL_SIZE_BAD ...` + `INSTALL_FAIL ... err=size ...`、不落盘；两处缺省即跳过（向后兼容）。`ota/server.lua`（不进镜像）：构建（`getSize` vs 实际字节）/装载/应答前三点 fail-closed，`OTA_SERVER_BAD_FILE path=.. reason=size got=.. want=..`（装载拒绝理由由 `size_mismatch` 统一为 `size`）。`startup.lua`（+5,368 B）：仅当 `/etc/network.conf` 存在时注册 `net`（`P.register_net`），否则 `STARTUP_NET_SKIP reason=no_config`；`P.report_net` 在 `start_all()` 后记 `STARTUP_NET_READY` / `STARTUP_NET_DEGRADED`，模块缺失/`spec()` 抛错/注册被拒/启动失败全部只 degraded、不 reboot；`opts.services` 里的同名 `net` 优先于默认注册；顺序仍是权限表 → 注册 → 首帧 → launcher → commit。测试：新增 8 组 121 断言，离线 **3,379 pass / 0 fail / 176 groups**（O2 3,258/168）；TOTAL **414,566 B / SIZE_WARN / MARGIN 65,041**、`WINDOW_OK sum=614,566`；门禁与 `install.set` 未动；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **T1 图形安装器 `installer.app`**（口径见 §17）。新增 `system/system/installer.app/`（`manifest.lua` 1,079 + `main.lua` 32,735 = **33,814 B**，纯 ASCII，26x20）：扫 `/disk/apps`（无驱动器即 `no disk`）+ `/apps` + `/system/system`，行前缀 `d`/`i`/`s`，回车装/卸/拒，结果与失败文案上屏（`installed <name> <ver>`、`hash check failed`、`size check failed`、`cancelled`、`system app locked`、`installer unavailable`），`layout_selftest()` 与桌面/设置同一套规则；安装器对象只经**宿主桥**取得（`opts.installer` → `api.sys.install`/`api.sys.uninstall` → `api.installer`，平函数 `install(name) -> true, info | nil, err`），源码不含任何内核路径字面量。`install.set` 26 → **28 条**、TOTAL **448,380 B / SIZE_WARN / MARGIN 98,855**、`WINDOW_OK sum=648,380`。新增 `tests/t_installer_app.lua`（10 组 **391** 断言），`tests/run.lua` 的 FILES 追加；`tests/run-tests.ps1` 把 app stage 到 `/tests/installer.app` 并列入 `$required`（理由见 §17.8）；离线 **3,770 pass / 0 fail / 186 groups**（N1 3,379/176）。`tests/t_budget.lua` 的 `install_entries` 26 → 28 随清单同步（强度不变）。README 删掉「无 installer UI」这条限制、新增 §5.5 用法，§2.1/§5.4/§6.3/§7/§9.1/§10 的数字同步。**未接内核桥**：`api.sys` 仍只有四个函数，真机上 UI 显示 `installer unavailable`（§17.2 末尾）。
- 2026-11-01: **T4 把 `installer.app` 真正接通**（口径见 §17.2/§17.9）。`kernel/apps.lua`：`A.SYS_FUNCTIONS` 增 `install`/`uninstall`/`list`（+6,336 B），后三个由运行时自己实现并按调用方 record 授权——`install`/`uninstall` 需 `fs.write`、`list` 需 `fs.read`，未授权 `nil, "capability denied: <cap>"` + `APP_CAP_DENIED`；包名白名单 `[%w_%-]+`/≤40 B（`..`、路径分隔、绝对路径、空、非字符串 → `nil, "bad name"`）；`uninstall` 对 `<system_root>/<name>.app` 一律 `nil, "system app"` + `APP_SYS_PROTECT name=..` 且不调安装器；无实例时 `nil, "installer unavailable"`（T1 文案）；日志 `APP_INSTALL name=.. ok=..` / `APP_UNINSTALL name=.. ok=..` / `APP_LIST n=..`。`system/startup.lua`：新增第 3b 步 `P.build_installer`（+2,345 B），构造 `/system/kernel/installer.lua` 实例并以 `apps.new({ installer = inst })` 注入，失败只记 `STARTUP_INSTALLER_UNAVAILABLE`、不阻塞启动。`installer.app`（+1,039 B）：`M.bridge` 的检测改为"桥对象是否存在"（`M.BRIDGE_FUNCTIONS = install/uninstall/list`），`installer unavailable` 只由桥完全缺失触发。新增 `tests/t_installer_bridge.lua`（9 组 227 断言，含真实安装器 + 真实 fs 的端到端与 UI 回车链路），离线 **3,997 pass / 0 fail / 195 groups**（T1 3,770/186）；`install.set` 仍 28 条、TOTAL **458,100 B / SIZE_WARN / MARGIN 108,575**、`WINDOW_OK sum=658,100`（+9,720 B）；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **M2 补上 PC 侧画面测试**（口径见 §18）。`CraftOS-PC 2.8.3` 没有 `term.getLine`，此前所有启动链套件都用 `frame` 桩，只证明首帧被调用、不证明画了什么。新增 `tests/screen.lua`：屏幕缓冲 harness，实现启动链用到的 term 子集、以 `_G.term` 替换让 ROM 的 `print`/`write` 落进缓冲（`S.install` / `S.with_term` 保证还原），语义按实测写死（`write` 不折行不夹光标、`clear` 不动光标、`blit` 推进光标、`scroll` 上移并清底、`print` 在底部 `write → setCursorPos(1,h) → scroll(1)`）。新增 `tests/t_bios_screen.lua`（6 组 **141** 断言）：normal 首帧（在 `frame` 返回瞬间快照：`Pyroet OS 0.2.0` / `kernel ok` / `normal journal none`，第 4–19 行空、光标 (20,3)、1 次 clear、帧前那屏是 boot 日志且无 banner、帧后日志从第 3 行第 20 列续写）、trial 首帧（`trial journal applied`，全屏无 `normal journal none`）、无 `/system` 的 fatal 屏（5 行 `BOOT_NO_SYSTEM`/`BOOT_FATAL`/`BOOT_ACTION`/`STARTUP_PLAN`/`STARTUP_FATAL`，无 banner）、根 starter 的三行失败文案（`Pyroet OS: cannot load /system/startup.lua`、`Pyroet OS: disk fault`、提示折成两行）、10x4 小屏截断、harness 自检。`tests/run.lua` 的 FILES 追加 `t_bios_screen`（`run-tests.ps1` 已按 `tests/*.lua` 整体 stage，**未改**）。离线 **4,138 pass / 0 fail / 201 groups**（T4 基线 3,997/195，**+141 断言 / +6 组**）；`install.set` 与 `sizecheck` 未动（28 条 / 458,100 B / MARGIN 108,575 / `WINDOW_OK sum=658,100`）；新增文件非 ASCII 计数 0。
- 2026-11-01: **O3 落地 `input` / `terminal` 两个 UI capability**（口径见 §19）。`kernel/apps.lua`：`A.CAPS` 7 → **9**（追加在表尾，旧决策文件按前缀解析不受影响）；`build_api` 新增 `api.input = { pullEvent = <受控函数>, keys = <受控表> }` 与 `api.terminal`（受控表，授予时就是宿主句柄本身），复用既有 `gate` / `tree` 桩形态，拒绝时形状不变、只回 `nil, "capability denied: <cap>"`；宿主经 `apps.new({ input = ..., terminal = ... })` 注入；`record.denied_caps` 逐 cap 记账并进 `status().apps[i].denied_caps`（日志仍用 `APP_CAP_DENIED` / `APP_CAP_UNAVAILABLE`，不新增 tag）。`kernel/permissions.lua`：`P.CAPS` 同步 9 项；文档写死"文件里没有的 cap = 未授予，不静默扩权、不在运行时追问，要重问用 `permissions.reset(app)`"。`system/startup.lua`：新增 `P.default_input()`（包装 `os.pullEvent` + `keys` 表）并在 3 步注入 `input` / `terminal`（`opts.input` / `opts.terminal` 可覆盖）。**兼容策略**：manifest 不写 `capabilities` = 空列表 = 全拒绝，无隐式授权（`api.input`/`api.terminal` 是新增字段，旧包不是回退）；manifest 是上限、决策文件只能收紧。新增 `tests/t_caps.lua`（9 组 **101** 断言，含 `startup.run` 端到端），`tests/t_apps.lua` 的 `cap_count` 7 → 9、`tests/run.lua` 的 FILES 追加 `t_caps`。离线 **4,239 pass / 0 fail / 210 groups**（M2 4,138/201，**+101 断言 / +9 组**）；`install.set` 仍 28 条、TOTAL **461,860 B / SIZE_WARN / MARGIN 112,335**、`WINDOW_OK sum=661,860`（+3,760 B）；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **D1 加上桌面常驻事件循环**（口径见 §20）。此前启动链 commit 后直接返回，CraftOS 掉回 shell（实机与 headless 都复现：launcher 只画一帧 `4 apps sel 1/4`，接着 `STARTUP_COMMITTED` 与三个 `>`）。新增 `system/kernel/desktop.lua`（**14,180 B**，内核模块而非 app）：`run()` 每次循环**恰好一次** `opts.pullEvent`（生产 = 输入宿主的 `host.pull`，即 ROM 的 `os.pullEvent`）→ 规范化（`key` 事件投递为 `("key","<name>")`，键码经 `keys` 表反查；其余事件透传）→ `host.push(...)` 投进输入队列 → `rt:tick()` **一步**；前台 = 声明 `input` 且 running 且 `starts` 最大者（平局保持），某步新起的 input app 接管键盘（`DESKTOP_FOREGROUND reason=launch`），它停掉后回落（`reason=settle`）；退出语义：body 返回 `"quit"` → `quit`、崩溃 → `crash`、`terminate`/`shutdown`（Ctrl+T）由派发器自己处理**不投给 app** → `terminate`、`max_events` → `limit`、缺 runtime/pull/队列 → `DESKTOP_SKIP`，而 **fatal 计划根本不进循环**。`system/startup.lua`（+8,896 B）：`P.default_input()` 改成**输入队列**宿主（`push` / `pullEvent` / `pending` / `pull`，`INPUT_QUEUE_MAX = 32` 丢最旧并计 `dropped`），`ctx.input` 由运行时与派发器**共用同一张表**；第 9 步从"可选 `opts.loop` 钩子"改成进入常驻循环并返回 `desktop` / `desktop_reason`；`opts.loop` 仍是一次性交接钩子（老测试用）、`opts.loop = false` = headless，`opts.pull_event` / `desktop_events` / `desktop` / `desktop_path` 是注入点；`_G.PYROET_DESKTOP_TEST` 让离线套件默认 headless（否则第一次 pull 就挂死）。`kernel/apps.lua`（+808 B）：`A:step` 记下 body 的返回值（`record.result` / `status().apps[i].result`，`APP_EXIT ... result=..`），桌面循环据此读 `"quit"`；`start` 时清零。`launcher.app` 0.1.0 → **0.2.0**（main.lua +5,209 B、manifest 632 → 1,159 B）：manifest 增 `input` + `terminal`，entry body 变常驻循环（先画一帧 → 每步 `api.input.pullEvent()`；`nil` 只 `yield` 不重画；动作非 `none` 才重画一帧，常驻首帧 `term.clear()` 盖掉 boot 日志）；Esc / `q` 返回 `"quit"`；`M.handle_key` 与 `opts.keys` 驱动的 `M.run` 原样保留。新增 `tests/t_desktop_loop.lua`（6 组 **122** 断言，含真启动链 + 注入 pull 的 `commit → down → enter(启动 net) → escape → 回 shell` 全链，并断言 3 事件 = 3 pull = 3 tick = 3 投递），`tests/run.lua` 追加 `t_desktop_loop` 与 `PYROET_DESKTOP_TEST`；`t_desktop` / `t_launcher` / `t_budget`（`install_entries` 28 → **29**）/ `install.set`（+`system/kernel/desktop.lua`）/ `run-tests.ps1`（`$required`）同步。离线 **4,368 pass / 0 fail / 216 groups**（O3 4,239/210，**+129 断言 / +6 组**）；`install.set` **29 条**、TOTAL **491,480 B / SIZE_WARN**（超 stretch 141,955、距硬门禁余 **137,665**）、`WINDOW_OK sum=691480`；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **D1-fix 修好真机「桌面只有鼠标有反应」**（口径见 §20.9，规则改写见 §19.4 第 3 条）。真机日志定位：/etc/perms/launcher.cfg 是上一版镜像写的（只有 s.read/s.write），旧规则「文件没写的 cap = 拒绝」把 D1 新声明的 input/	erminal 判成 denied → APP_PERMS_APPLIED granted=2 denied=2 + APP_CAP_DENIED cap=terminal + cap=input → launcher 画不了也拉不到事件（msg=no_input reason=capability denied: input）→ 派发器照常 pull 并投进无人读的队列，所以按键全无反应、只有 emulator 的鼠标光标在动（日志里 DESKTOP_EVENT ... event=key arg=up 证明键码翻译与投递本来是对的）。修两处：①kernel/permissions.lua（+2,628 B）——文件里没有的 cap 改为「未决定」，该包下一次 start 只对缺失 cap 重走 sk（镜像包预授权 → 授予，用户包仍拒绝），写回文件并记 PERMS_STALE/PERMS_DECISION/PERMS_SAVED，只发生一次；只读 pass（prompt=false）不迁移、不写、不缓存未决表。②system/startup.lua（+786 B）——进循环前检查**授予集**，缺 input/	erminal 就 STARTUP_DESKTOP_SKIP reason=input_denied|terminal_denied 且不接管控制台（回 shell 才能 permissions.reset(app)）。测试：	_desktop_loop 新增 migrate（真机回归：旧 cfg → 迁移 → granted=4 → down/enter/escape 全链无 APP_CAP_DENIED）与 grant（显式拒绝 → 0 次 pull、不接管），	_permissions 新增 perms.stale（24 断言），	_caps 旧断言按新语义改写。离线 **4,606 pass / 0 fail / 229 groups**（D1 4,368/216，+51 断言 / +3 组）；install.set 仍 29 条、TOTAL **494,894 B / SIZE_WARN / MARGIN 145,369**、WINDOW_OK sum=694894（+3,414 B）；改动 lua 非 ASCII 计数 0。真机复验在 demo 盘**副本**上完成（原盘未动）：保留旧 cfg → 开机日志 PERMS_STALE → granted=4 → 注入真实 ROM 键码 down/down 得 ction=move index=2/3、屏幕 4 apps sel 3/4，char q → DESKTOP_EXIT reason=quit → 回到 shell。顺带确认本 ROM 的 keys 表没有 scape（keys.escape=nil），退出用 q 或 Ctrl+T。
- 2026-11-01: **D1-fix 第二轮：真机「方向键不动 + 每行前面一个 s」**（口径见 §20.10）。根因=屏幕所有权，不是键盘：权限修好后真机日志已有 `APP_LOG app=launcher msg=key=down action=move index=2`（数据层正常），但按 Enter（真机 index 1 = 字母序 `installer`）启动的 `installer.app` 不声明 `input`/`terminal` 却仍然每 tick 被调度、用 `M.paint` 重画自己的 `s <pkg>` 列表（term 缺省取 `_G.term`，绕过 cap）；`key` 那一 tick launcher 最后画，`key_up` 那一 tick launcher 不重画——于是 installer 的帧留在屏幕上：每行一个 `s`、`>` 停在它自己第 1 行（"选项不动"）。附带：启动链日志在桌面阶段仍 `print`，每条事件都把桌面帧顶上一行。修三处：①`kernel/desktop.lua` 停车（新启动且未声明 `input` 的 app → `DESKTOP_PARK`，作为 skip 表交给 `rt:tick(skip)`，保持 running 但不再有时间片；`kernel/apps.lua` 的 `A:tick(skip)` 是唯一运行时改动）；②`system/startup.lua` 桌面阶段换 `P.quiet_log`（只写 /kernel.log，`STARTUP_DESKTOP_QUIET`；测试注入的 log 不变）；③`launcher.app` 按键两种形态都收（名字 + 原始键码，映射由 `api.input.keys` 运行时构建，不硬编码；`M.dispatch_event` 对数字 p1 也归一化）。测试：新增 `desktop_loop.screen`（`_G.term` 换成 `tests/screen.lua` 缓冲、真实 `key`+`key_up` 事件流）逐字断言行首字符、只有一行有 `>`、无 `s ` 前缀，并断言两种按键形态都能移动；离线 **4,606 pass / 0 fail / 229 groups**（D1-fix 4,419/219）；`install.set` 29 条、TOTAL **501,795 B / SIZE_WARN**（+6,901 B：desktop +2,790、launcher +2,476、startup +1,247、apps +388）、`WINDOW_OK sum=701795`；改动 lua 非 ASCII 计数 0。真机复验在 demo 盘副本上完成（原盘未动）：`key_up` 帧与 `key` 帧一致，`> installer → > launcher → > net → > launcher`，日志 `STARTUP_DESKTOP_QUIET` + `DESKTOP_PARK app=installer reason=no_input caps=2`。
- 2026-11-01: **D1-fix 第三轮：启动"没有反应"改成屏幕租借**（口径见 §20.11）。第二轮把未声明 `input` 的 app 停车，屏幕不再被抢，但 Enter 启动 installer/launcher 时屏幕毫无变化（用户看到"启动没反应"）；`settings`/`net` 同理。真机日志证明启动本身成功（`APP_START name=installer` + `DESKTOP_PARK`），所以根因是 (b) 启动了但被 parking 成后台、看不见，不是 (a) `api.sys.launch` 失败也不是 (c) 应用崩溃。修法：①`kernel/desktop.lua` 换成**屏幕租借**——未声明 `input` 的 app 被真正调度并立刻多跑一步画出首帧（`DESKTOP_LOAN app=.. reason=no_input caps=..`），租借期间只调度它（launcher 不跑，无法覆盖），结束时停车（`DESKTOP_PARK reason=loan_over`）并给 launcher 发 `desk_focus` 让它立刻重画（`APP_LOG ... msg=focus msg=display only: <name>`）；结束条件三选一：app 自停（`reason=stopped`）、定时器（`DESKTOP_LOAN_TIMER id=.. seconds=15` → `reason=timeout`，硬兜底）、事件数兜底（`LOAN_EVENTS=40` → `reason=events`）。②`kernel/apps.lua` 的 `start` 在拒绝路径记 `APP_START_DENIED name=.. reason=no_such_app|killed|already_running`——launcher 从桌面启动自己即此路径（不再静默）。③`launcher.app` 处理 `desk_focus`：设置提示行并立即重画。真机验证（demo 盘副本，原盘零改动）：注入 pull 抓帧显示 Enter 后屏幕变成 installer 自己的界面（`> s installer` / `d0 i0 s4 sel 1/4`）；生产模式（queueEvent + 真 `P.run()`）跑满 22 秒的 kernel.log 依次出现 `DESKTOP_LOAN` → `DESKTOP_LOAN_TIMER seconds=15` → `DESKTOP_EVENT n=2 event=timer arg=2 app=installer` → `DESKTOP_PARK reason=loan_over` → `DESKTOP_LOAN_END reason=timeout` → `focus msg=display only: installer`。已知限制（写进 §20.11）：注入 pull 的探针里 `os.pullEvent` 在深层嵌套 pcall 上下文不恢复（`bios.lua` 的 `native` 报错），是脚手架限制，生产路径正常。测试：`desktop_loop.screen` 重写为三个非 input 包可见启动 + 定时器返回 + 自启动被拒 + 自停 app 返回后按键恢复（`t_desktop_loop` 9 组 186 断言），`desktop_loop.boot`/`migrate` 事件流加 `timer`；离线 **4,606 pass / 0 fail / 229 groups**（4,457/220，+11 断言）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN / MARGIN 193,956**、`WINDOW_OK sum=743481`（+7,508 B：desktop +5,832、launcher +403、apps +955、startup +318）；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **T14 三个系统应用真正可键盘操作**（口径见 §21）。`system/system/{settings,installer,net}.app` 全部 0.2.0，manifest 追加 `input`+`terminal`（settings 另加 `fs.write`，原有 `net.rpv`/`fs.write` 保留），body 从无限自绘循环改成常驻事件循环（首帧 → `api.input.pullEvent()` → 按键 → 只在有动作时重绘 → `q`/escape 返回 `"quit"`，键名与原始键码两种形态都收）。真操作：settings 用 up/down 选行、left/right/enter 循环并**只重写 `/etc/network.conf` 的一行**（`prefix` 24/16/8、`iface_side` back/top/front/bottom/left/right，注释与其它键逐字保留，落盘后回读显示 `saved <key>=<value>`）；net 用 up/down 滚主机表、enter/`r` 重读 rpv 状态与 probe（无 `net.rpv` 时显示 degraded 与原因）；installer 用 up/down/数字选行、enter 经宿主桥装/卸/报 `locked`，无源盘时首帧 `disk none`、无桥时报 `unavailable`。**桌面侧修掉一个真 bug**：交接时 launcher 与前台 app 都在调度、共享队列被 launcher 抢走按键（表现"进入应用后 q 退不出去"）——`kernel/desktop.lua` 的 `D:tick` 改为"租借期间只调度被租借 app、否则只调度前台 app"，并在前台消失时投 `desk_focus`（`back from <app>`）让 launcher 立刻重画。测试新增 `tests/t_apps_ui.lua`（4 组，逐帧逐字断言 + settings 落盘断言 + 三 manifest 静态 cap 断言），并同步 `t_settings`（cap 1→4 与"只改一行"的真实断言）、`t_net_app`/`t_installer_app`（版本/cap）、`t_desktop`、`t_budget`、`t_desktop_loop`（net 变 input 应用后 boot/migrate 改成交接语义）。离线 **4,606 pass / 0 fail / 229 groups**（4,468/220，+61 断言 / +4 组）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN**（超 stretch 193,956、距硬门禁余 85,664）、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **T14 之后：退出形态与租借兜底**（口径见 §22）。真机日志定位两处：①settings 在**没有 `/etc/network.conf`** 的盘上 `items=0`，上下左右全 `action=none`、画面一帧不动（不是退不出，是**没有可操作的东西**）；②退出判断排在键码归一化之后，而本 ROM 没有 `keys.escape`（256→nil→none），且 `key` 数字形态落不到退出分支。修法：settings 缺行/缺文件时给默认值并允许创建文件（`M.save_item` 建父目录）；三个应用统一 `M.quit_key` 并**先于归一化**判定（键名 q/Q/escape/quit、原始键码 q=16 / GLFW 81 / Esc 256、`terminate`/`shutdown` 兜底），`char q/Q` 原本已支持；`kernel/desktop.lua` 加租借硬兜底（`start_timer` 不可用或返回 nil → 不租借、`DESKTOP_LOAN_ABORT reason=no_timer` + 停车 + `desk_focus`；租借进行中新增 `LOAN_ABORT_EVENTS=200` / `LOAN_ABORT_SECONDS=60` 硬上限 → `DESKTOP_LOAN_ABORT reason=events|clock` → `DESKTOP_LOAN_END reason=abort`），`startup.lua` 透传这些旋钮。测试：`t_apps_ui` 新增 `apps_ui.settings_exit`（八种退出形态）与 `apps_ui.settings_fresh`（无配置文件仍可操作并创建文件），`t_desktop_loop` 新增 `desktop_loop.loan_abort`（events 硬上限与 no_timer 两条 abort 路径、回到 launcher、下一键生效、`kernel:status().health=ok` 证明不饿死服务）；`tests/run.lua` 在套件之间让出一次以避免 CraftOS-PC "Too long without yielding" 看门狗（套件变大后 t_ota/t_recovery_flash 实测被打断）。离线 **4,606 pass / 0 fail / 229 groups**（4,529/224）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN / MARGIN 193,956**、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。真机复验（demo 盘副本、生产模式）：`ready items=2` → `key=down action=move item=2` → `saved iface_side=top`（文件被创建）→ `char q` → `quit key=q` → `APP_EXIT result=quit` → `DESKTOP_FOREGROUND launcher reason=settle`。
- 2026-11-01: **q 留在桌面，Ctrl+T 才是出口**（口径见 §23）。真机反馈"launcher 上按 q 直接回 CraftOS shell"：根因是 launcher 的 `dispatch_event` 把 `escape` 与 `char q/Q` 返回 `"quit"`，启动链据此离开桌面。改法：launcher 新增 `M.LEAVE_HINT="Ctrl+T leaves Pyroet OS"`，三种键形态命中后只设提示 + `"repaint"`（日志 `APP_LOG app=launcher msg=leave hint ... scope=desktop`），不再 `"quit"`；`kernel/desktop.lua` 的 `terminate` 分支带作用域——租借中 `DESKTOP_TERMINATE scope=app` + `loan_end("terminate")`，前台是应用则把 terminate 投递给应用再 settle（`scope=app`），前台是桌面才 `scope=desktop` 并回 shell。测试：`t_desktop_loop` 新增 `desktop_loop.leave`（桌面 q 不退 + 第 18 行逐字提示 + 应用内 terminate 先退应用再退系统），`launcher_keys` 三处 quit→repaint，`boot`/`migrate` 的退出改用 `terminate` 且 launcher 保持 running。离线 **4,606 pass / 0 fail / 229 groups**（4,569/227）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN / MARGIN 193,956**、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。
- 2026-11-01: **进入桌面即就绪，不需要按键**（口径见 §24）。现象是开机/应用返回后要按一下方向键画面才"出来"。两个真因：①启动链第 7b 步画的 launcher 首帧被随后的提交日志、以及**仍然指向控制台的 app 运行时日志 sink**（每条 `APP_LOG` 都打印）反复盖掉；②`desktop.run()` 在第一次 pull 之前不画任何东西。修法：`desktop.run()` 进循环前投一次 `desk_focus`（空消息）+ tick 并记 `DESKTOP_READY app=..`（可用 `ready_paint=false` 关掉），`apps.lua` 新增 `A:set_log` 且 `startup.lua` 在 `quiet_log` 之后把运行时 sink 指过去，桌面阶段日志只进 `/kernel.log`。测试新增 `desktop_loop.ready`（零按键首帧逐字断言 + 应用退出/租借结束的返回帧 + pull 计数不增），`dispatcher` 假运行时统一 `ready_paint=false`。离线 **4,606 pass / 0 fail / 229 groups**（4,587/228）；`install.set` 29 条、TOTAL **543,481 B / SIZE_WARN / MARGIN 193,956**、`WINDOW_OK sum=743481`；改动 lua 非 ASCII 计数 0。真机复验：注入一个 terminate、pulls=1，首帧即完整桌面（row3 `> installer`、row18 `up/dn enter run`、row19 `4 apps sel 1/4`），日志 `DESKTOP_READY app=launcher`。
- 2026-11-01: **Ctrl+T 打开电源菜单，不再退回 shell**（口径见 §25）。桌面收到 `terminate`/`shutdown` 不再返回 "terminate"（那会回 CraftOS shell），而是 `DESKTOP_TERMINATE scope=desktop` + `DESKTOP_POWER_MENU scope=desktop` + 投 `power_menu` 事件并 tick；launcher 自己画三项菜单（Shutdown/Reboot/Cancel，`up/down` 选、`enter` 执行、`Esc`/`q` 取消），执行前写 `POWER shutdown requested`/`POWER reboot requested`，缺 `os.shutdown`/`os.reboot` 时该行 `unavailable` 并给出原因；应用内 Ctrl+T 仍先退应用（`scope=app`）。launcher 的 `q/Q/Esc` 提示改为 `Ctrl+T opens power menu`。测试新增 `desktop_loop.power`（os stub、菜单逐字、Reboot 调用一次、Esc 回桌面、应用内不弹菜单、缺 os.shutdown 显示 unavailable），旧组统一 `power_menu = false`。离线 **4,633 pass / 0 fail / 230 groups**（4,606/229）；未 commit。
- 2026-11-01: **桌面 OTA 入口 + installer 桥复核**（口径见 §26）。`api.sys.install/uninstall/list` 是 T4 的既有实现（本轮只补断言，未改语义）；新增 `api.sys.ota_list()` / `api.sys.ota_apply(name)`（cap `fs.read` / `fs.write`）：源 = `/disk/ota/meta.txt`（镜像更新，`kernel/ota.lua` 的 `O.parse_meta` 解析）+ `/disk/apps/<name>.app`（包更新）；无源 `no source`、坏 meta `bad meta`、镜像 apply 一律 `image ota needs recovery`（归 recovery），包 apply 复用同一 installer 对象。launcher 电源菜单由三项变四项（`Update` 在首位），`Update` 打开自绘 Updates 屏（`no updates` + 原因、`up/down/enter/q`、不用 Esc）。新增 `tests/t_sys_ota.lua`（3 组 65 断言），`t_ota.lua` 原样保留。离线 **4,699 pass / 0 fail / 233 groups**（4,633/230）；`install.set` 29 条、TOTAL **560,258 B / SIZE_WARN / MARGIN 210,733**（余 68,887）、`WINDOW_OK sum=760258`；无新增镜像文件。
