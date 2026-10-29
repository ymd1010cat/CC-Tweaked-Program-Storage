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

(b) **权限 = capabilities**。固定集合：`fs.read`、`fs.write`、`net.rpv`、`net.rednet`、`redstone`、`peripheral`、`http`。三件套语义：**manifest 声明** → **首启确认**（用户点一次，落盘到权限库）→ **运行时拦截**（每次 API 调用查当前 app 的 cap 集；拒绝时返回 `nil, "EPERM"` 而不是抛错，避免 app 只能靠 pcall 活下去）。权限仲裁只有一处在 kernel 的 service manager，runtime 不得自授。

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

2.7 **健康判定（write-through 口径，其 30 秒观察窗已被 P6 取代，见 §13）**：ready = 以下四条**全部**满足：

1. 内核起来；
2. service manager 起来（服务注册与依赖全部就绪）；
3. UI 首帧绘制完成；
4. 连续 **30 秒**无未捕获错误 / 崩溃（watchdog 记账；`pcall` 边界之外的崩溃算失败）。

**rpv 网络不是 ready 的必要条件**：网络失联不得导致永远无法提交，否则一台断网掌机会卡在试启动、最终回退掉一个本来可用的系统。ready 判定通过后由系统写 `/boot.ok`（版本 + 镜像 sha256 + 时间戳），随即按 §2.4 删除旧槽。

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
| `capabilities` | table of string | 只能取自 §1.2(b) 的 7 个 cap，未知 cap 直接拒绝安装 |
| `entry` | string | 入口文件名，默认 `"main.lua"` |
| `size` | integer | 包内所有文件的字节总和（安装前先校验，失败即拒绝） |

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

9.7 **Net 系统 app**（`pyroet-os/system/net.app/`——P5b 曾移到 `examples/net.app/`，**G1 已加回镜像**，是 payload，见 §7.1/§8.4/§11.7）：manifest `name="net"`、`version="0.1.0"`、`entry="main.lua"`、`capabilities={"net.rpv","fs.read"}`。界面 26x20（标题 1、内容 2-19、状态 20），纯函数 `render(state, cols, rows)` 每行严格 pad/truncate 到列宽；`layout_selftest()` 无终端校验行数与列宽。**输入源是文件 `/etc/net.target`（一行 `<ip> <port>`，`#` 注释）**：P2 的 app 运行时只有 7 个固定 cap（§1.2(b)），没有输入/终端 cap，`os.pullEvent` 也不经 kernel 派发，键盘输入在当前运行时里不可达；`fs.read` 读一行是唯一被授权的入口，未来加 input 服务只需换读取源。能力未声明 → `nil, "capability denied: net.rpv"`；已声明但宿主未提供 → `nil, "capability unavailable: net.rpv"`；两者都只在界面显示并写 `api.log`，不崩溃（`net.app.runtime` 测试覆盖两种分支）。

9.8 **尺寸与测试口径（P3 时点，P5b 曾把 net.app 转出镜像、G1 已加回，见 §8.4）**：新增 4 文件 = `net/hosts.lua` 11,488 B + `net/service.lua` 27,504 B + `system/net.app/main.lua` 15,493 B + `system/net.app/manifest.lua` 437 B = **54,922 B**；`install.set` 18 条（18 文件），`python pyroet-os/tools/sizecheck.py` → **TOTAL 257,650 / SIZE_PASS / MARGIN 4,494 B under stretch（91,875 under upper）**。离线套件 `pwsh -NoProfile -File pyroet-os/tests/run-tests.ps1` → **OFFLINE_PASS 1,116 / FAIL 0 / GROUPS 55**（P2 基线 522/38，新增 **594** 断言：hosts 140、net service 282、net app 172）。新增 lua 的非 ASCII 计数 0。本段数字保留为 P3 记录。

## 10. 桌面 / 设置 / 权限确认（P4）

10.1 **启动顺序（写死）**：`/startup.lua` 的顺序是 boot.begin → kernel → apps（`/apps` 与 `/system` 各 scan 一次，系统包在 `/system`）→ **权限表挂载（第 3c 步，任何 app 启动前）** → 系统服务 → `start_all` → 一次调度 → 首帧 → **读权限表 + 启动 launcher（第 7b 步）** → `boot.commit()` → loop。理由：首帧证明机器能起来，权限表在任何 app 启动前挂上才不会"先跑后问"；launcher 在 commit 前启动，但整段被 `pcall` 包住（`STARTUP_DESKTOP_FAIL`），启动器写错也绝不把好启动变成回滚环；launcher 缺失 → `STARTUP_LAUNCHER_MISSING` 并回退 hello（已在运行只记 `state=running`），不算失败。launcher 只拿一次时间片（`ctx.rt:step(launcher)`，`STARTUP_DESKTOP_TICK advanced=true`），不动其它已启动的 app 的时间片。

10.2 **权限确认语义**：`manifest.capabilities` 只是"声明"，不是授权。首次启动某个 app 时（`/etc/perms/<app>.cfg` 不存在）：`PERMS_PROMPT app=.. caps=a,b` → 逐项询问/判定 → 每条 `PERMS_DECISION app=.. cap=.. granted=true|false` → 写入 `cap=granted|denied` 单行格式。文件存在且合法 = 那就是决策，**不再询问**。坏文件（无法解析、未知 cap 名、非法值、空文件）→ `PERMS_BAD_FILE` + **全拒绝**，且**不重写文件**（坏决策文件绝不静默变成授权），下次启动按同样结果处理。cap 名合法但 manifest 已不再声明 = 陈旧行，忽略并记 `PERMS_PRUNE`（陈旧不是损坏，两者语义必须分开）。持久化路径固定 `/etc/perms/<app>.cfg`（`key=value`，`#` 注释，首行 `# PYROET-PERMS-1 app=<name>`）；`permissions.reset(app)` 删除该 app 的决策文件（测试与未来的 Settings 用），实例方法为 `P:forget(app)`，`P:prefetch(apps)` 只读不写、用于启动时把已有决策读进内存。

10.3 **拒绝不崩**：被拒绝的 cap 从 record 的 cap 集里移除，走与"未声明"完全相同的桩路径——`nil, "capability denied: <cap>"` + `APP_CAP_DENIED app=.. cap=..`，**不抛错**；app 仍然启动、仍然被调度、仍然能正常退出。权限表自身抛错 → `APP_PERMS_FAIL app=..` + **全拒绝** + 启动继续（fail closed）；持久化失败只记 `PERMS_SAVE_FAIL`，不阻断启动。

10.4 **没有键盘这条边界（沿用 §9.7）**：P2 运行时没有 input cap，所以"询问"是**注入的回调**（`permissions.new({ask=function(app,cap,info)})`），默认实现一律 `false`（fail closed）。启动链的默认策略（`startup.P.default_ask`）：`/system/` 下的**系统镜像包**按 manifest 原样授权（记 `PERMS_PREGRANT`），其它包一律拒绝，等输入服务落地再把回调换成真询问。launcher 的按键是纯函数 `M.handle_key(state, key)`，由 `opts.keys`（表或迭代器）驱动；真实键盘同样等 input 服务。`api.sys` 之外的输入通道一律不开。

10.5 **launcher（桌面）**：`pyroet-os/system/launcher.app/`，`capabilities = {"fs.read","fs.write"}`（写**只**用于成功后追加一行 `/etc/launcher.recent`，被拒绝就忽略）。扫描 `/apps` 与 `/system` 下的 `<name>.app`（目录里必须有 `manifest.lua`），名称 = 目录名去掉 `.app`，版本取自运行时索引（`api.sys.apps()`）；运行时没有加载的包仍然列出、版本显示 `?`（桌面上"介质里有什么"不等于"运行时加载了什么"）。排序按名称升序，同名重复只取首个并进 problems。顶部两行状态：`ver <version> sha <8 位十六进制>`（只读全局 `/boot.ok` 的 `version` 与 `manifest_sha` 前 8 位；`manifest_sha=none` 或非十六进制时省略 `sha` 段，标记读不到就 `ver ?`——单树没有槽位指针，G2 已删掉全部槽位兜底）与 `net <ok|degraded|down|off> free <n>`（`fs.getFreeSpace("/")`，读不到就 `n/a`）。启动**只**走 `api.sys.launch(name)`（运行时 `rt:start`），绝不自己起 coroutine。布局：行 1–2 头部、行 3..n-2 列表、行 n-1 提示或单条消息、行 n 选择计数；**列 < 16 或行 < 6 → 降级成单行状态**，列 < 26 → 列表降级为单列（去掉版本列），任何行都 pad/truncate 到列宽，越界写屏不可能发生。

10.6 **settings（设置）**：`pyroet-os/system/settings.app/`，`capabilities = {"fs.read"}`——**严格只读**，没有写路径。离线套件用 instrumented fs 断言 `write/append/delete/makeDir` 调用数为 0、没有非 `"r"` 模式的 `open`，并断言运行时确实对 `fs.write` 返回 `capability denied: fs.write`。内容：系统版本、镜像版本 + `manifest_sha` 前 8 位（只读全局 `/boot.ok`）、net health、应用清单与每个 cap 的 granted/denied/pending、`/etc/network.conf` 关键项（键名含 `psk`/`pass`/`secret`/`key`/`token` 的值一律显示 `***`，明文永不进屏幕）、存储（free + 硬门禁 349,525 B + `/etc/install.set` 条目数）。缺文件时是固定降级文案（`apps n/a` / `conf n/a` / `install.set n/a` / `free n/a`），不抛错、不空白屏。与 launcher 共用同一套 26x20 规则和 `layout_selftest()`。

10.7 **`api.sys` 不是第 8 个 cap**：它是宿主注入的**只读系统内省面**（`apps.new({sys = <table> | function(record) -> table|nil})`），四件事：`status()`（kernel 健康）、`apps()`（运行时 `status().apps`）、`perms(app)`（该 app 的决策表）、`launch(name)`（`rt:start`）。没注入的函数返回 `nil, "system unavailable: <fn>"` 并记 `APP_SYS_UNAVAILABLE`，所以 app 问什么都不会 nil-index。startup 的 `sys_for` 只把整表交给 `/system/` 下的包，用户包拿到桩：`launch` 是唯一有副作用的入口，按**目录**而不是按 cap 授权——cap 列表是 app 自己声明的，用它去决定"谁能启动别的 app"等于让被约束方自己发权限。`api.fs.getFreeSpace` 作为 `fs.read` 的一部分提供（读介质容量不写任何东西），宿主没有这个方法时返回 `capability unavailable: fs.read`。

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

13.3 **校验时机（写死）**：清单校验必须在**下载完成时、`/system` 一字节未动之前**：收齐全部 `FILE` 行后按 P6-design §3.2 算聚合哈希（按 `relpath` 升序拼 `<relpath>\0<size>\0<sha 小写>\n`，整串一次 SHA-256）与 `META.manifest_sha` 比对，不符即 `OTA_REJECT stage=verify reason=manifest_sha got=.. want=..`、状态 `rejected`、可 `retry()` 从第 0 块重来，系统不动。理由：`old_sha`/`new_sha` 是回滚能力的来源；一旦进入 `applying`，系统随时处于中间态，那时才发现内容不可信，唯一出路是用备份回旧版本，而备份的可信度取决于 `old_sha` 在动手之前就是对的。同理 `old_sha` 一律**本地现算**，不信服务器。

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
