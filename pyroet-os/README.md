# Pyroet OS —— 掌机上的类 Android 系统（CC:Tweaked）

Pyroet OS 是 Minecraft CC:Tweaked **掌机（Pocket Computer，屏幕 26×20）**上的一个小型操作系统：
单棵 `/system` 系统树、capability 权限模型、统一的 `.app` 应用包、文件集网络 OTA，以及一套
EDL 式的恢复工具。发布版本 **1.0.0**，装机内容 **26 个文件 / 414,566 B**。

它是 `pyromputer-os/`（原 unixshell）的**重度裁剪硬分支**：不是"跟随上游的轻量分支"，而是
按掌机的现实约束重新分层、大量删改后的独立系统。两者**互不覆盖、互不合并、互不回灌**；
上游修复只能逐条手工 cherry-pick，并且要先判断"该修复在删减后的模块里是否还成立"。
原目录零改动（规矩同 `cardkey` → `itn-pass`）。设计口径见 [`DECISIONS.md`](DECISIONS.md)
与 [`P6-design.md`](P6-design.md)。

---

## 1. 定位与边界

### 1.1 它是什么

| 维度 | 取舍 |
| --- | --- |
| 形态 | 掌机单机系统，不假设有显示器、键盘、磁盘 |
| 屏幕 | 26×20 字符；所有系统界面必须完整可用，不允许横向滚动 |
| 安装 | 全部装在机身（CC 电脑存储配额 **1,000,000 B**），**没有 `/disk` 分层** |
| 更新 | 网络文件集 OTA（`PYROET-OTA/2`），无盘可插，OTA 是唯一正常升级入口 |
| 救援 | `recovery/` 三件套（拉取 / 推送两种模式），系统坏了仍能手工粘贴进去运行 |
| 语言 | 界面与日志**纯 ASCII 英文**；本文档等说明文字才是中文 |
| 应用 | 系统应用与用户应用**同一套 `.app` 格式**，没有"特权格式" |

### 1.2 它不是什么

- 不是与 Pyromputer OS 共享代码路径的分支：`rpv` 只取 9 个模块 + loader，`psh` 不复用，
  `lib/pkg`（介质包仓库）、`lib/bios`、CJK 字库三件套全部删除。
- 不是多用户 / 多进程系统：CC 只有一个 Lua VM，并发单位只有 `coroutine`，"沙盒"是 **API 收口**
  而不是内存隔离；app 死循环**无法抢占**，只能靠约定 + watchdog 记账，纯 CPU 死循环只能重启整机。
- 不是路由器 / NAT / DHCP 服务器：这些模块（`nat`/`wan`/`dhcp`/`wansec`/`fabric`/`topo`）全部裁掉，
  掌机只做**端点**。

### 1.3 三条写死的现实约束

1. **没有真进程**：app 崩溃用 `pcall` 边界隔离；无法"杀进程"，也没有抢占式调度。
2. **权限 = capabilities**：manifest 声明 → 首启/预授权决策 → 运行时逐次拦截；拒绝返回
   `nil, "capability denied: <cap>"`，不抛错。
3. **系统应用与用户应用同格式**：Launcher / Settings / Net 也是 `.app`，只是它们的 cap 由镜像内
   系统清单授予，且**只能用 OTA 换**（用户不能手装系统 app）。

---

## 2. 目录与部署布局

### 2.1 仓库树（`pyroet-os/`）

```
pyroet-os/
├─ startup.lua              ROM 唯一入口的 starter（1,070 B），只加载 /system/startup.lua
├─ system/                  镜像 payload（27 文件 / 447,310 B）
│  ├─ startup.lua           启动链：boot → kernel → apps → 权限 → 服务 → 首帧 → commit
│  ├─ boot.lua              bootloader：单树 + journal 决策表 + 按哈希回滚（45,623 B）
│  ├─ kernel/
│  │  ├─ init.lua           内核 / 服务管理器（注册、依赖拓扑、health 聚合）
│  │  ├─ apps.lua           app 运行时（`.app` 扫描、coroutine、cap、配额）
│  │  ├─ permissions.lua    capability 决策表（/etc/perms/<app>.cfg）
│  │  ├─ installer.lua      应用安装器（暂存/校验/替换/卸载保护）
│  │  └─ ota.lua            系统 OTA 客户端（PYROET-OTA/2）
│  ├─ rpv/                  rpv 子集 10 文件 = 9 模块 + loader.lua（131,590 B）
│  ├─ net/
│  │  ├─ hosts.lua          静态 hosts 解析（整文件原子生效）
│  │  └─ service.lua        kernel 服务 `net`：rpv 节点 + 静态邻居/路由 + hosts + UDP probe
│  └─ system/               系统应用（同一 `.app` 格式）
│     ├─ launcher.app/      桌面（扫 /apps 与 /system/system）
│     ├─ settings.app/      设置（严格只读）
│     ├─ installer.app/     安装器 UI（26x20：来源盘 + 两个已装根，装/卸/拒）
│     └─ net.app/           网络状态 / hosts 列表 / 单次 UDP probe
├─ recovery/                救援工具（**不进镜像、不进 install.set**）
│  ├─ proto.lua             文件集事务层：META / 校验 / 暂存 / 替换 / 逆序撤销 / journal
│  ├─ flash.lua             拉取模式：`--disk=/disk/firmware` 或 `--host=<id>`
│  └─ bootstrap.lua         推送模式：`PYROET-FLASH/2 PUSH ...`
├─ ota/                     发行端 OTA 服务（开发/发布工具，不跑在掌机上，不进镜像）
├─ tests/                   CraftOS-PC 离线套件（开发材料，不进发布包）
├─ tools/                   sizecheck.py / smoke.lua / smoke-run.ps1（开发材料）
├─ install.set              镜像清单（28 条，`sizecheck.py` 的唯一输入）
├─ DECISIONS.md             决策记录（架构与门禁的权威口径）
└─ P6-design.md             文件集更新模型的设计与崩溃窗口分析
```

### 2.2 运行时树（真机根目录）

```
/
├─ startup.lua              ROM 唯一自动执行的文件；不在 OTA 文件集内，任何更新都改不到它
├─ boot.ok                  全局提交凭据（PYROET-BOOT-OK-2 version=.. manifest_sha=.. ts=..）
├─ boot.tries               连续试启动计数（先落盘再进系统）
├─ update.journal.<seq>     更新意图日志（三态 + rolledback 墓碑，保留最新两代）
├─ update.backup/<relpath>  本次被替换文件的旧字节（回滚素材，与 /system 同构）
├─ update.stage/<relpath>.part  单文件暂存（校验通过后才 move 进 /system）
├─ kernel.log               内核/启动链日志（ASCII，一行一条，可 grep）
├─ system/                  唯一系统树
│  ├─ startup.lua           boot.lua / kernel/ / net/ / rpv/ / system/*.app
├─ apps/<name>.app/         用户应用（安装器只写这里）
├─ etc/
│  ├─ network.conf          网络服务配置（ip 必填）
│  ├─ hosts.conf            静态 hosts（`<hostname> <ipv4>`）
│  ├─ net.target            Net app 的 probe 目标（`<ipv4> <port>`，无键盘输入通道）
│  ├─ perms/<app>.cfg       capability 决策（`cap=granted|denied`）
│  ├─ install.set           可选：装机清单副本，Settings 用它显示条目数
│  └─ launcher.recent       可选：launcher 启动成功后追加的一行
└─ recovery/*.lua           救援工具（可选保留；砖机时是唯一入口）
```

### 2.3 仓库 → 运行时映射

| 仓库路径 | 目标路径 | 说明 |
| --- | --- | --- |
| `pyroet-os/startup.lua` | `/startup.lua` | ROM starter，随镜像发布但**不属于 OTA 文件集** |
| `pyroet-os/system/**` | `/system/**` | OTA 的 `relpath` 相对 `/system/` |
| `pyroet-os/recovery/**` | `/recovery/**` | 不进镜像，手工复制；砖机救援用 |
| `pyroet-os/install.set` | `/etc/install.set` | 可选；Settings 读它显示条目数 |
| `pyroet-os/DECISIONS.md`、`P6-design.md` | 任意（如 `/docs/`） | 现场无仓库时是唯一的口径来源 |

`/etc`、`/apps`、`/kernel.log`、`/boot.*`、`/update.*` 是**运行时状态**，不是 `install.set` 的条目；
`sizecheck.py` 只统计 `install.set` 列出的镜像文件。

---

## 3. 启动链

### 3.1 一次开机的顺序

```
/startup.lua（starter，1,070 B）
  └─ pcall(loadfile, "/system/startup.lua") 并调用它；失败就打印 ASCII 错误并退回 ROM shell
       ├─ 1. boot.begin()       读 /system、journal、/boot.ok；必要时先回滚，再决定 normal/trial/fatal
       ├─ 2. kernel.new()       构建服务管理器
       ├─ 3. apps.new()         扫描 /apps 与 /system/system/*.app
       ├─ 3c. permissions       在**任何 app 启动之前**挂上权限表（声明 ≠ 授权）
       ├─ 4/5. 注册并 start_all()  hello + net（仅 `/etc/network.conf` 存在时）→ 依赖拓扑启动，失败隔离；health=failed 才是硬失败
       ├─ 6. apps tick          给已启动 app 一次调度时间片
       ├─ 7. 首帧               "UI 已起来"（DECISIONS 2.7 的 ready 条件之一）
       ├─ 7b. 桌面              读权限表 → 启动 launcher（整段 pcall；缺失只记日志，回退 hello）
       ├─ 8. boot.commit()      写全局 /boot.ok，删 journal 与 /update.backup
       └─ 9. 常驻桌面对话循环    commit 后**不返回**：kernel/desktop.lua 持有一个阻塞
                                os.pullEvent，把事件规范化后投给前台应用（launcher）；
                                只有 `q` / Ctrl+T / 循环自身的正常退出才回 ROM shell
                                （`keys.escape` 在 CraftOS-PC 里不存在，Esc 不一定投递）
```

任何会让机器起不来的错误都走 `os.reboot()`（让 `/boot.tries` 记账生效），而**不** commit；
`fatal` 计划（`no_system` / `rollback_fail` / 写盘失败）**不** reboot——重启环修不了坏字节——
它打印三行可 grep 的 ASCII 报告后把控制台留给 ROM shell。

**`net` 是默认注册的第二个服务**（`/system/net/service.lua`），但它的前提是用户数据而不是镜像内容：
**仅当 `/etc/network.conf` 存在时注册**，不存在就记 `STARTUP_NET_SKIP reason=no_config` 直接跳过
（缺配置**不是**启动失败；新机本来就没有 `/etc`）。注册之后的一切问题——模块缺失
（`STARTUP_NET_SKIP reason=no_module`）、`spec()` 抛错或注册被拒（`STARTUP_NET_FAIL reason=spec|register`）、
服务启动失败（`KERNEL_SERVICE_FAIL name=net` + `STARTUP_NET_DEGRADED state=failed`）——都只让
`health=degraded` 并继续：掌机的桌面、应用与 OTA 都不依赖网络，**网络问题绝不回滚整机**。
配好并起网记 `STARTUP_NET_READY state=running`（`net` 服务自己还会记 `NET_READY` / `NET_DEGRADED`）。

### 3.2 bootloader 决策表（摘要）

输入只有四个事实：`/system` 在不在、最新可解析 journal 的状态、`/boot.ok` 是否存在且
`manifest_sha` 是否等于 journal、`/boot.tries` 是多少。

| 磁盘事实 | 决策 |
| --- | --- |
| 没有 `/system` | `fatal(no_system)`，不 reboot |
| 无 journal + 有 `boot.ok` | normal（稳态），tries 不动 |
| 无 journal + 无 `boot.ok` | trial：`tries+1` **先落盘**再启动 |
| journal `prepare` | 下载从未应用：清理后 normal/trial |
| journal `applying` | **先回滚**，再 normal/trial |
| journal `applied` + sha 相同 | 已提交：清理 journal/backup，normal |
| journal `applied` + sha 不同（≤2 次） | 未提交：trial |
| journal `applied` + `tries > 2` | 回滚；写 `rolledback` 墓碑 |
| journal `rolledback` | 清理，normal/trial |
| 回滚无法证明 | `fatal(rollback_fail)` + `FLASH_REQUIRED tool=recovery/flash.lua` |

回滚**按内容哈希推进**，绝不写进度标志：`sha256(/system/<rel>) == old_sha` 视为已回滚并跳过、
`sha256(update.backup/<rel>) == old_sha` 则挪回并回读校验、`old_sha == "-"` 表示本次新增故删除。
`MAX_TRIES = 2`：第 3 次失败（`tries > 2`）才回滚。旧布局（`/kernel`、`/rpv`、`/net`、`/system/*.app`）
由 `boot.migrate_layout()` 在决策表之前一次性重命名迁移，失败逆序撤回到 `fatal(layout_migrate_fail)`。

---

## 4. 权限模型

### 4.1 九个 capability（固定集合，无继承）

| cap | 授予的能力 |
| --- | --- |
| `fs.read` | 受控读文件 / 列目录 / `getFreeSpace` |
| `fs.write` | 受控写 / 追加 / 删除 / 建目录（按 app 计写入配额） |
| `net.rpv` | 通过 rpv 节点收发（net 服务 / probe） |
| `net.rednet` | 裸 rednet（OTA / 救援工具用，普通 app 一般不需要） |
| `redstone` | 红石读写 |
| `peripheral` | peripheral 访问 |
| `http` | CC 的 http API（掌机上通常不可用） |
| `input` | 键盘/事件：`api.input.pullEvent(...)` + `api.input.keys` |
| `terminal` | 屏幕：`api.terminal`（term 句柄本身；授予 = 宿主对象） |

后两个是 UI 能力，**互不蕴含**：只要键盘不要屏幕、只要屏幕不要键盘都行；只声明一个时另一个仍是拒绝桩。
它们与另外七个走**完全同一套**机制（声明 → 首启决策 → 运行时拦截 → `nil, "capability denied: <cap>"`
+ `APP_CAP_DENIED`），没有另一条旁路。宿主由启动链注入：`input` = **输入队列**
（`host.push(event, ...)` 供派发器投递、`api.input.pullEvent(...)` 弹出一格，空队列返回 `nil`；
`api.input.keys` 是 ROM 的 keys 表，派发器用它把键码翻成键名），`terminal` = ROM 的 `term`
（`opts.input` / `opts.terminal` 可覆盖）。队列有上限（`INPUT_QUEUE_MAX = 32`，最旧事件先丢，
计入 `host.dropped`），阻塞的 `os.pullEvent` 只在 `host.pull` 上、由 `kernel/desktop.lua` 独占。
详见 DECISIONS §19 与 §20。

manifest 的 `capabilities` 只是**声明**：首启时 `PERMS_PROMPT app=.. caps=..` → 逐项决策 →
写 `/etc/perms/<app>.cfg`。文件存在且合法 = 那就是最终决策，不再询问；坏文件（无法解析、未知 cap、
非法值、空文件）→ `PERMS_BAD_FILE` + **全部拒绝**，且**不重写**（坏决策绝不静默变授权）；
manifest 已不再声明的陈旧行忽略并记 `PERMS_PRUNE`（陈旧 ≠ 损坏）。

```
# PYROET-PERMS-1 app=net
net.rpv=granted
fs.read=granted
```

### 4.2 拒绝语义（不崩、可继续运行）

- 未声明 / 被拒绝：`nil, "capability denied: <cap>"` + `APP_CAP_DENIED app=.. cap=..`；app 照常启动、
  照常被调度、照常退出。
- 已授予但宿主没提供：`nil, "capability unavailable: <cap>"` + `APP_CAP_UNAVAILABLE`。
- 权限表自身抛错：`APP_PERMS_FAIL` + 全拒绝（fail closed），启动继续。
- 持久化失败只记 `PERMS_SAVE_FAIL`，不阻断启动。

`api.sys`（`status()` / `apps()` / `perms(app)` / `launch(name)` / `install(name)` /
`uninstall(name)` / `list()`）**不是 cap**，而是宿主注入的只读内省面，且只交给 `/system/`
下的系统包；用户包拿到桩，`launch` 按**目录**而不是按 cap 授权。后三个由**运行时自己**实现
（只有它知道调用方 record 的 cap 集合）：`install`/`uninstall` 需 `fs.write`、`list` 需 `fs.read`，
未授权仍是 `nil, "capability denied: <cap>"` + `APP_CAP_DENIED`；目标对象由启动链构造并以
`apps.new({ installer = inst })` 注入，缺失时返回 `nil, "installer unavailable"`。详见 §5.5。

### 4.3 键盘与屏幕这两条边界

`input` / `terminal` 是**新增的 opt-in 能力**（DECISIONS §19）：包不声明就拿不到，且两者互不蕴含。
"询问"仍然是**注入的回调**（`startup.P.default_ask`）：启动时还没有任何 app、也没有事件派发器，所以
`/system/` 下的系统镜像包按 manifest 原样授权（`PERMS_PREGRANT`），其它包一律拒绝；要重新询问某包，
删掉它的决策文件（`permissions.reset(app)`）。launcher 现在**两条路都在**：常驻 entry 用
`api.input.pullEvent()` 拿事件（声明了 `input` + `terminal`），而纯函数 `M.handle_key(state, key)`
与 `opts.keys` 驱动的 `M.run` 仍是离线套件用的那条路；Net app 的 probe 目标仍从 `/etc/net.target` 读一行。

两条写死的边界：①cap 是 **API 收口**，不是沙盒——app 与内核同一个 Lua VM，绕过 `api` 直接摸
`term` / `os.pullEvent` 拦不住（与另外七个 cap 同一强度）；②但**整机现在有事件循环接管了**（D1）：
`kernel/desktop.lua` 是唯一持有阻塞 `os.pullEvent` 的地方，它把事件投进输入队列并给调度器**一步**，
app 的 `api.input.pullEvent` 是这个队列的**弹出一格**——没事件时返回 `nil`（app 必须 `yield`），
所以 app 永远不会把整机阻塞在别人的事件源里。队列有上限（`INPUT_QUEUE_MAX = 32`），不抽的 app
只丢掉最旧的事件，不会无限增长。

compat：manifest **不写** `capabilities` = 声明空列表 = 全部拒绝，**没有隐式授权**；旧包在 `input` /
`terminal` 存在之前本来就拿不到这两样，现在只是这两个字段以**桩**的形式出现，包照常加载、启动、退出。
决策文件里**没有**的 cap = **未决定**（不是拒绝；拒绝一定写成 `denied`）：该包下一次启动时只对缺的 cap
重走一遍授权策略（镜像包 = 预授权 → 授予；用户包 = 默认策略仍拒绝），结果写回文件并记
`PERMS_STALE app=.. caps=..` + `PERMS_SAVED`，**迁移只发生一次**（D1-fix：镜像升级给系统包新增 cap 时
不会再被判成"永远拒绝"，真机事故见 DECISIONS §20.9）。manifest 没声明的 cap 即使文件里写了也记
`PERMS_PRUNE` 并拒绝——**manifest 是上限**。桌面进循环前还会再查一次**授予集**：拿不到 `input` /
`terminal` 时 `STARTUP_DESKTOP_SKIP reason=input_denied|terminal_denied` 并**不接管控制台**，
回 shell 让你 `permissions.reset(app)` 后重开，而不是顶着一个"吃掉所有按键"的死桌面。

---

## 5. 应用包格式 `.app`

### 5.1 目录结构

```
/apps/hello.app/
├─ manifest.lua        返回一个表（见下）
├─ main.lua            入口；chunk(manifest, api) 在独立 coroutine 里跑
├─ lifecycle.lua       可选：on_start / on_pause / on_resume / on_stop
└─ res/                可选：静态资源（只读）
```

系统应用在 `/system/system/<name>.app`，用户应用在 `/apps/<name>.app`，格式完全相同。
安装器只写 `/apps`；对 `/system/system/<name>.app` 的卸载一律拒绝（`INSTALL_REMOVE_DENIED ... reason=system`）。

### 5.2 manifest 字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `name` | 是 | 运行时索引键；建议等于目录名去掉 `.app`，同名只保留首个并进 problems |
| `version` | 否 | 字符串，默认 `0.0.0`，≤32 字节；只比较、不解析语义 |
| `entry` | 否 | 入口文件名，默认 `main.lua`；不得含路径分隔符 |
| `capabilities` | 否 | 只能是 §4.1 的 9 个 cap；未知 cap 直接拒绝加载 |
| `max_starts` | 否 | 正整数，启动次数配额（默认 8，超限 `quota exceeded: starts`） |
| `size` | 否 | 包内字节总和（**不含 `manifest.lua` 自己**：文件无法包含自己的最终长度）；安装器逐字节核对 |

> **`size` 是判据，不是说明**（`DECISIONS.md` §5.2 与 §16）：安装器在暂存副本上核对两处声明，
> 任何不符都拒绝安装且不落盘（`INSTALL_SIZE_BAD ...` + `INSTALL_FAIL ... err=size ...`）：
>
> 1. `SHA256SUMS` 的第三列——逐文件字节数，允许 `<64 hex>  <size>  <relpath>` 或
>    `<64 hex>  <relpath>  <size>` 两种列序（不写第三列就是老格式，仍然只比摘要）；
> 2. manifest 的 `size`——整包总量，统计暂存目录里除 `manifest.lua` 外的**全部**文件
>    （含 `SHA256SUMS` 自身）。
>
> 两处都**可以不写**：未声明就跳过该项校验、只验 SHA256，这样早于该字段的包照样能装
> （向后兼容是硬要求，不是宽松）。完整性从来不只靠 `size`：`SHA256SUMS` 逐文件摘要、
> 包内每个文件都必须列出，才是防篡改的那一层。

### 5.3 运行时行为

- 每个 app 一个 coroutine，`rt:tick()` 推进；`main.lua` 可以 `while true do api.yield() end`。
- 配额从"拒绝而不截断"：启动次数、`fs.write` 字节数超限都返回 `nil, "quota exceeded: ..."`。
- 生命周期钩子失败只记 `APP_HOOK_FAIL`，不中断状态迁移；`kill` 之后不会再被调度。
- 安装器（`kernel/installer.lua`）：暂存到 `/apps/.tmp-<name>/` → 校验（摘要 + 声明的 `size`）→ 替换；
  `fs.move` 被拒时降级为 copy + 逐文件校验 + 删临时目录；任何失败保留旧版本。

### 5.4 四个系统应用的 cap（写死）

| 包 | version | capabilities |
| --- | --- | --- |
| `launcher.app` | 0.2.0 | `fs.read`, `fs.write`（写只用于 `/etc/launcher.recent`，被拒就忽略）, `input`, `terminal`（D1：常驻桌面对话循环） |
| `settings.app` | 0.1.0 | `fs.read`（**严格只读**，没有写路径） |
| `installer.app` | 0.1.0 | `fs.read`, `fs.write`（读来源盘与两个已装根；写只发生在安装事务里） |
| `net.app` | 0.1.0 | `net.rpv`, `fs.read` |

### 5.5 安装器 UI（`installer.app`）

图形入口，26x20，与桌面/设置共用同一套布局自检（`layout_selftest()`）。

```
installer 0.1.0
disk ok 3 installed
> d box          0.2.0    <- d = 来源盘 /disk/apps 上的包（Enter 安装/覆盖）
  d zeta         1.0.0
  i notes        0.3.0    <- i = 已装在 /apps（Enter 卸载）
  s launcher     0.2.0    <- s = 镜像自带的系统包（Enter 拒绝）
  ...
enter install              <- 或 enter remove / system app locked / 结果文案
d2 i1 s2 sel 1/5
```

- **按键是纯函数**（`M.handle_key(state, key, api, opts)`）：上/下（或左/右）移动、数字键跳转、
  回车/return 执行、`escape`/`q`/`c` 取消当前提示行；`M.run` 的键从 `opts.keys` 取
  （安装器没有声明 `input`，见 §4.3）。
- **来源**：`/disk/apps/*.app`（有驱动器时；没有驱动器是正常状态，文案是 `no disk, no apps`）、
  `/apps`（用户包）、`/system/system`（镜像包）。版本号：来源盘上的包从 `manifest.lua`
  **按文本匹配**读取（绝不执行来源盘里的代码），已装的包从 `api.sys.apps()` 取。
- **安装走宿主桥**，三种桥来源按顺序取第一个可用的：`opts.installer` → `api.sys.install` /
  `api.sys.uninstall` → `api.installer`。桥函数签名为平函数：
  `install(name) -> true, info | nil, err`、`uninstall(name) -> true | nil, err`、
  `list() -> entries`，即 `kernel/installer.lua` 的契约（对象绑定由宿主完成）。应用**从不**
  `dofile`/`loadfile` 内核模块；**桥对象完全缺失**时显示 `installer unavailable` 并继续运行，
  不报错、不崩；桥在但内核没装安装器时同一行文案由 `M.error_text` 的 `unavailable` 映射给出。
- **桥已接通（T4）**：`kernel/apps.lua` 的 `A.SYS_FUNCTIONS` 增加 `install`/`uninstall`/`list`，
  `startup.lua` 启动时构造 `/system/kernel/installer.lua` 实例（真实 fs、`/apps` 与
  `/system/system` 根）并以 `apps.new({ installer = inst })` 注入，构造失败只记
  `STARTUP_INSTALLER_UNAVAILABLE`、不阻塞启动。能力：`install`/`uninstall` 需 `fs.write`、
  `list` 需 `fs.read`（未授权 = `nil, "capability denied: <cap>"` + `APP_CAP_DENIED`）；参数只接受
  包名 `[%w_%-]+`、≤40 B（`..`、`/`、`\`、`.`、空串、非字符串 = `nil, "bad name"`）；`uninstall`
  拒绝 `/system/system` 下的包（`nil, "system app"` + `APP_SYS_PROTECT name=..`，桥一次都不调用）。
  日志每次调用恰好一行：`APP_INSTALL name=.. ok=..` / `APP_UNINSTALL name=.. ok=..` /
  `APP_LIST n=..`。
- **失败文案**（`M.error_text()` 是唯一映射点，返回值第二个是分类）：
  `hash check failed`（digest/sums/sha256/unlisted）、`size check failed`（size）、
  `cancelled` / `cancelled: no source`、`system app locked`、`not installed`、
  `capability denied: fs.write`、其他 `failed: <原串>`。
- **卸载保护**：`/system/system` 的包在应用层就拒绝（`system app locked`，桥一次都不调用），
  即使宿主返回 `system app` 也显示同一行；只有 `/apps/<name>.app` 能被卸载。
- **没有可装项**时给 ASCII 提示：`no apps to install`（有盘无包）或 `no disk, no apps`
  （无盘也无包）；`fs.read` 被拒时直接显示 `capability denied: fs.read`。
- **测试钩子**（真机永不设置）：`_G.PYROET_INSTALLER_TEST` 让入口返回模块本身，
  `_G.PYROET_APP_NOPAINT` 跳过绘制。

---

## 6. 更新与恢复

### 6.1 文件集 OTA：`PYROET-OTA/2`（rednet 协议名 `pyroet-ota`）

只走**裸 rednet**（不依赖 rpv——网络栈本身可能就是坏的），另用 `/system/rpv/crypto.lua` 的 SHA-256。
一行一包：

| 方向 | 报文 |
| --- | --- |
| 请求 | `PYROET-OTA/2 GET meta` |
| 应答 | `PYROET-OTA/2 META version=<t> files=<n> manifest_sha=<64 hex>` |
| 请求 | `PYROET-OTA/2 GET <idx>`（0 起，取第 idx 条 FILE） |
| 应答 | `PYROET-OTA/2 FILE <relpath> <size> <sha256>` |
| 请求 | `PYROET-OTA/2 GET <idx> <offset>`（offset 为 `MAX_DATA` 整数倍） |
| 应答 | `PYROET-OTA/2 DATA <relpath> <offset> <hex>` |

`MAX_DATA = 8,192` B 载荷/包，`F_MAX = 65,536` B/文件，`MAX_FILES = 256`，丢包/坏块各算一次尝试
（1..3 次，`OTA_RETRY`），不做位图（重连从第 0 块重算并覆盖写）。

**顺序即安全保证**：

1. 取 `META` 与全部 `FILE` 行——此时**一个字节都还没下**。
2. 对清单算**聚合哈希**（`relpath` 升序拼 `<relpath>\0<size>\0<sha256 小写>\n`，整串一次 SHA-256）
   与 `META.manifest_sha` 比对；不符 → `OTA_REJECT stage=verify`，系统未动，可 `retry()`。
3. `BACKUP_CAP` 预检（只算"会被备份的已存在文件"的字节）；超限 → `OTA_REJECT stage=cap`，仍未动盘。
4. `journal(state=prepare)`：意图落盘，`old_sha` 由**本地现算**、不信服务器。
5. `journal(state=applying)`，逐文件：a/b 下 `.part` 并回读校验**字节数与** `new_sha` → c/d 旧文件 move 进
   `/update.backup/` 并回读校验 `old_sha`（备份不可信就立刻挪回并放弃整次更新）→ e/f `.part`
   move 进 `/system/`、**再量一次字节数**并回读校验 `new_sha` → g 删残片。
6. `journal(state=applied)`：**只有到这一步才允许重启**去试新版本；bootloader 接手（§3.2）。

**`size` 与摘要同等对待**（声明了就核对，没声明不会凭空拦人）：

- 下载时只按 `size` 请求 DATA，末块必须正好 `want` 字节（短包按坏块重试，不是"少收一点也算完"）。
- `.part` 写完先量字节再比摘要：`fs.getSize` ≠ 声明 `size` → `OTA_REJECT stage=verify reason=size
  file=<relpath> got=<实际> want=<声明>`，此时**磁盘一字节未动**，状态 `rejected`，可 `retry()`。
- move 进 `/system/` 之后**再量一次**（`OTA_FAIL stage=install err=size got=.. want=..` + 回滚）：
  防的是"写短了但摘要碰巧对上"和替换后被截断——摘要是内容证明，字节数是长度证明，两者都要。

失败语义：`prepare`/`applying` 阶段任何失败立即按 journal 逆序回滚（`OTA_FAIL stage=..` +
`OTA_ROLLED_BACK`）；回滚本身失败 → `OTA_ROLLBACK_FAIL` + `FLASH_REQUIRED`，只能走 `recovery/flash.lua`。
`rejected`（verify/cap）与 `rolled_back` 都可 `retry()`；`fatal` 不可重试。`status()` 报
`idle/fetching/verifying/ready/rejected/failed` + 字节进度 + 状态轨迹。

**路径白名单**（防穿越，硬规则）：`relpath` ≤96 字节纯 ASCII 可打印、不以 `/` 开头或结尾、
不含 `//`、任何一段都不是 `..`、每段只允许 `[%w_%-%.]` 且不以 `.` 开头、扩展名只允许
`.lua`/`.txt`/`.conf`/`.cfg`、不得出现保留名 `update.journal`/`update.backup`/`boot.ok`/`boot.tries`/`startup.lua`。

### 6.2 救援与刷写（EDL 类比）：`PYROET-FLASH/2`

`recovery/` 三件套**不进镜像、不进 `install.set`**（当前实测 22,876 + 5,642 + 5,108 = 33,626 B），
是系统坏掉时手工粘贴到机上的工具；只用 ROM 全局（`fs`/`term`/`os`/`rednet`）与 `crypto.lua` 的
SHA-256，不加载任何 rpv 模块。目标永远是 `<root>/system`——**没有槽、没有指针**，
`/system` 缺失正是它要处理的砖机状态。

- **拉取**：`recovery/flash.lua`。有驱动器时读 `/disk/firmware/meta.txt` + 按 relpath 摆好的文件；
  无驱动器时走 rednet `pyroet-flash`（`GET meta` / `GET <relpath> <idx>` → `META` / `DATA`）。
- **推送**：`recovery/bootstrap.lua`。`PUSH meta ...` 后跟 `PUSH DATA ...`，分片可乱序，
  坏块丢弃并计一次 miss 等发布端重发；不需要请求通道，所以小到能手抄。
- **事务**：`recovery/proto.lua` 统一做"描述 → 暂存并证伪 → 逐个替换（旧字节进 `/update.backup`，
  两处 move 都回读校验）→ 失败按内容哈希逆序撤销"。成功后写一份 `applied` journal，让 bootloader
  把刚刷进去的镜像当"未提交"试启动，三次起不来就从备份回滚。

```
FLASH_TARGET path=/system state=present|missing
FLASH_SOURCE kind=disk|rednet
FLASH_META version=.. files=.. manifest_sha=..
FLASH_OK files=.. written=.. skipped=.. bytes=.. version=.. manifest_sha=.. journal=..
FLASH_FAIL stage=<prepare|source|meta|stage|backup|apply> err=..
```

### 6.3 常用命令（在掌机 ROM shell 里）

```lua
-- 系统 OTA（发布端在 rednet id 12 上）
local ota = dofile("/system/kernel/ota.lua").new({ host = 12, log = print })
ota:update()
print(ota:status().state, ota:status().bytes)

-- 从驱动器刷写 /system
recovery/flash.lua --disk=/disk/firmware
-- 从 rednet 刷写 /system
recovery/flash.lua --host=12
-- 推送模式接收（发布端推，不请求）
recovery/bootstrap.lua

-- 安装/卸载/列出用户应用（来源：/disk/apps、内存包表或 opts.dir）
local inst = dofile("/system/kernel/installer.lua").new({ log = print })
inst:install("hello"); inst:uninstall("hello"); inst:list()

-- 图形入口：launcher 的列表里选 installer.app（26x20；行前缀 d/i/s 分别表示
-- 来源盘上的包、已装在 /apps、镜像自带）。它自己不实现安装，只通过宿主桥调用上面的
-- 安装器；桥的接法与降级见 §5.5。
```

注意：OTA 正常更新与救援刷写是**同一信任模型的两条链路**（裸 rednet + SHA-256 + 帧定界，
无握手、无加密），区别只在入口：`ota.lua` 是镜像内的正常客户端（复用 `boot.lua` 的写入口），
`recovery/` 是系统坏掉时的手工入口。发布端（回答 `GET meta` / `GET <idx>` 的那一端）可以用
`ota/server.lua`：它只跑在带 modem 的普通 CraftOS 电脑上，不跑在掌机上，也不进镜像。
`recovery/` 失败**不破坏旧系统**：暂存期失败只花一次下载。

---

## 7. 容量口径与门禁

唯一口径是 `pyroet-os/install.set` + `pyroet-os/tools/sizecheck.py`：

| 口径 | 数值 | 语义 |
| --- | --- | --- |
| 硬门禁（upper） | **629,145 B**（3/5 MiB） | `> 629,145` = `SIZE_FAIL`，exit 1，发版阻断 |
| 目标线（stretch） | **349,525 B**（1/3 MiB） | `349,525 < total ≤ 629,145` = `SIZE_WARN`，**只 WARN、不判死** |
| 备份上限（BACKUP_CAP） | **200,000 B** | OTA 换文件期间保留的旧字节上限 |
| 更新窗口 | **900,000 B** | `total + BACKUP_CAP ≤ 900,000` = `WINDOW_OK`，超出 exit 1 |
| 机身配额 | **1,000,000 B** | CC 电脑默认存储配额（含用户数据、日志、已装 app） |

当前实测（v1.0.0 + N1 修正 + T1 安装器 UI）：

```
entries    : 28 (28 files, 0 dirs, 0 missing)
TOTAL      : 448,380 B   (system 27 文件 447,310 + 根 starter 1,070)
VERDICT    : SIZE_WARN   (stretch 349,525 < total 448,380 <= upper 629,145)
MARGIN     : 98,855 bytes over stretch; 180,765 bytes under upper
WINDOW_OK  : sum=648380 limit=900000
```

- **`SIZE_WARN` 不是失败**：超目标线只报差额；硬门禁才是发版阻断线。
- 更新窗口是**独立判定**（`SIZE_FAIL` 时也照常打印 `WINDOW` 行）：`448,380 + 200,000 = 648,380`，
  距 900,000 还有 251,620 B，距机身 1,000,000 B 还有 351,620 B。
- **发布包 ≠ 镜像**：发布 zip 是完整源码集（含 `recovery/` 与两份文档），`install.set` 统计的才是镜像；
  不要拿 zip 体积当门禁，也不要因为包里有 `recovery/` 就以为它在镜像里。

---

## 8. 已知限制（v1.0.0，明确不做超出上限的承诺）

| 限制 | 具体表现 / 影响 |
| --- | --- |
| **无 DNS 客户端** | `services.lua` 未 vendor，`node:lookup(name)` 返回 `nil`；域名解析只能用 `/etc/hosts.conf` 静态表 |
| **无 ICMP / 无 ping** | `icmp` 模块已裁；`probe()` 用 UDP 一发一收，所以"端口无响应 / 主机不在线 / 被丢弃"对外都只能表现为 timeout |
| **无 DHCP / NAT / 路由 / WAN ACL / 多跳** | `nat`/`wan`/`wansec`/`fabric`/`topo`/`qos`/`mcast`/`dv` 全部裁掉；掌机只做端点，不转发、不做网关 |
| **cap 只是 API 收口，不是沙盒** | app 与内核共享一个 Lua VM 与全局表；`fs`/`net`/`term`/`os.pullEvent` 的约束只对"经过 `api` 的调用"成立，绕过 `api` 直接摸全局拦不住（`input`/`terminal` 与另外七个 cap 同一强度） |
| **桌面只有 launcher 是交互的** | D1 之后整机有事件循环（`kernel/desktop.lua`），但键盘归**前台应用**：镜像里只有 launcher 声明了 `input`；settings / installer / net 是只读或一次性 body，启动后由调度器推进、拿不到按键。要交互，包必须自己声明 `input`（启动时就会**接管键盘**，停掉再把键盘交回 launcher） |
| **没有 `/etc/network.conf` 就没有网络** | `net` 服务由启动链默认注册（§3.1），但配置是用户数据：文件不存在就跳过（`STARTUP_NET_SKIP reason=no_config`），不猜默认地址、不写默认配置 |
| **settings 严格只读** | 只声明 `fs.read`，没有任何写路径；看得到配置，改不了配置 |
| **无中文** | CJK 字库与三件套全部删除（省 1,440,360 B）；界面与日志纯 ASCII，原版 CC 字体即可显示 |
| **无进程隔离 / 无法抢占** | app 共享一个 Lua VM；死循环只能重启整机；"杀进程"只是不再调度它的 coroutine |
| **单文件更新上限 65,536 B** | 任何单文件超过 `F_MAX` 就永远无法通过文件集更新（当前最大 `rpv/node.lua` 60,498 B） |

`size` 与 `net` 都不在这个表里了：`size` 现在**声明即校验**（三处，见 §5.2 与 §6.1），
`net` 现在**默认注册**（判据是 `/etc/network.conf` 存在，见 §3.1）。需要手工注入 spec 的场景仍然
存在——但那只是为了**替换**默认服务（例如注入带自定义 `rpv` 的实例），不是为了补上缺失的注册：

```lua
local specs = { dofile("/system/net/service.lua").spec({ log = print }) }
-- opts.services 里出现同名 "net" 时，默认 registration 会让位给注入的这一份
```

---

## 9. 测试与构建

### 9.1 离线测试（CraftOS-PC headless）

```powershell
pwsh -NoProfile -File pyroet-os/tests/run-tests.ps1
# 可选：-Keep 保留 staging，-TimeoutSec 180，-Exe <CraftOS-PC_console.exe>
```

脚本把镜像 stage 到 `pyroet-os/.tests/computer/20`（与真机同布局：`/system` + `/system/system/*.app`），
headless 启动、读取 `/offline-report.txt` 判分，**PASS 后自动删除 staging**（`-Keep` 保留）。

基线（v1.0.0 + N1 修正 + T1 安装器 UI + T4 + M2 画面测试 + O3 能力）：**OFFLINE_PASS 4239 / FAIL 0 / GROUPS 210**。
M2 之后新增的是 PC 侧渲染测试：`tests/screen.lua`（屏幕缓冲 harness，替换 `_G.term`）与
`tests/t_bios_screen.lua`（首帧 / 试启动帧 / 无 `/system` 的 fatal 屏 / 根 starter 失败文案 / 10x4 小屏），
细节见 `DECISIONS.md` §18；O3 新增 `tests/t_caps.lua`（`input` / `terminal` 的拒绝、放行、unavailable、
旧包兼容与决策文件语义），细节见 §19。

另有 P1 的 rpv 子集冒烟测试（可选）：

```powershell
pwsh -File pyroet-os/tools/smoke-run.ps1      # SMOKE_PASS / SMOKE_FAIL / SMOKE_DONE
```

### 9.2 体积门禁

```powershell
python pyroet-os/tools/sizecheck.py
# 可选：--budget 629145 --stretch 349525 --backup-cap 200000 --list
```

### 9.3 发布包

```powershell
python tools/build_release.py --project pyroet-os --out dist/release
# -> dist/release/pyroet-os-v1.0.0.zip
```

- zip 根是 `pyroet-os/` 前缀 + 仓库根 `LICENSE`；成员按路径排序、固定 1980-01-01 时间戳与 0644，
  同内容重复构建**字节相同**。
- **排除** `tests/` 与 `tools/`（开发材料）；**包含** `recovery/`（砖机的唯一救援通道）、
  `DECISIONS.md`、`P6-design.md`、`install.set`、`README.md`、`INSTALL.txt`。
- 成员口径：`pyroet-os/` 下除 `tests/`、`tools/` 之外的**全部文件** + 根 `LICENSE`；
  不要手算成员数，构建输出（`files=<n>` 与 zip 成员表）才是权威。
- CI 用同一条命令（`.github/workflows/release-builds.yml`，tag 名 `pyroet-os`）；现场没有 git 历史，
  所以两份设计文档必须随包发。

---

## 10. 版本与文档

| 组件 | 版本 / 字节 |
| --- | --- |
| 发布版本 | 1.0.0（`pyroet-os-v1.0.0.zip`） |
| `/startup.lua` starter | 1,070 B（`DECISIONS.md` §13.11 的 1,071 B 为旧读数） |
| 启动链 `/system/startup.lua` | `P.VERSION = 0.2.0`，38,870 B（D1：+8,896 B，输入队列宿主 + 第 9 步常驻循环；D1-fix：+786 B，进循环前的授予集检查；T4：+2,345 B；O3：+821 B） |
| bootloader | `M.VERSION = 2.0`，45,623 B |
| kernel / apps / permissions / desktop | 1.0 / 1.0 / 1.0 / 1.0（13,958 / 38,453 / 21,449 / 14,180 B；D1：apps +808 B 记录 body 返回值、新增 desktop.lua；D1-fix：permissions +2,628 B，陈旧决策文件按"未决定"迁移） |
| installer / ota | 1.0 / 2.0（17,295 / 31,877 B；N1：+3,854 / +3,566 B，size 校验） |
| rpv 子集 | 10 文件 / 131,590 B（9 模块 + loader） |
| 系统应用 | launcher 0.2.0（D1：+5,209 B，常驻桌面循环）/ settings 0.1.0 / installer 0.1.0 / net 0.1.0 |
| `installer.app`（T1/T4） | 0.1.0，34,853 B（main.lua 33,774 + manifest.lua 1,079） |
| OTA 服务端（`ota/server.lua`） | 1.0，27,927 B（不进镜像） |
| 镜像 | 29 条 / 494,894 B / `SIZE_WARN` / `WINDOW_OK sum=694894` |

设计口径以 [`DECISIONS.md`](DECISIONS.md)（架构、门禁、发布）与 [`P6-design.md`](P6-design.md)
（文件集更新、journal、崩溃窗口、bootloader 决策表）为准；本文是面向使用者的入口，
两者冲突时以 `DECISIONS.md` 为准。装机步骤见 [`INSTALL.txt`](INSTALL.txt)。
