# Pyroet OS —— 掌机上的类 Android 系统（CC:Tweaked）

Pyroet OS 是 Minecraft CC:Tweaked **掌机（Pocket Computer，屏幕 26×20）**上的一个小型操作系统：
单棵 `/system` 系统树、capability 权限模型、统一的 `.app` 应用包、文件集网络 OTA，以及一套
EDL 式的恢复工具。发布版本 **1.0.0**，装机内容 **26 个文件 / 401,778 B**。

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
├─ system/                  镜像 payload（25 文件 / 400,708 B）
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
│     └─ net.app/           网络状态 / hosts 列表 / 单次 UDP probe
├─ recovery/                救援工具（**不进镜像、不进 install.set**）
│  ├─ proto.lua             文件集事务层：META / 校验 / 暂存 / 替换 / 逆序撤销 / journal
│  ├─ flash.lua             拉取模式：`--disk=/disk/firmware` 或 `--host=<id>`
│  └─ bootstrap.lua         推送模式：`PYROET-FLASH/2 PUSH ...`
├─ ota/                     发行端 OTA 服务（开发/发布工具，不跑在掌机上，不进镜像）
├─ tests/                   CraftOS-PC 离线套件（开发材料，不进发布包）
├─ tools/                   sizecheck.py / smoke.lua / smoke-run.ps1（开发材料）
├─ install.set              镜像清单（26 条，`sizecheck.py` 的唯一输入）
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
       ├─ 4/5. 注册并 start_all()  依赖拓扑启动，失败隔离；health=failed 才是硬失败
       ├─ 6. apps tick          给已启动 app 一次调度时间片
       ├─ 7. 首帧               "UI 已起来"（DECISIONS 2.7 的 ready 条件之一）
       ├─ 7b. 桌面              读权限表 → 启动 launcher（整段 pcall；缺失只记日志，回退 hello）
       ├─ 8. boot.commit()      写全局 /boot.ok，删 journal 与 /update.backup
       └─ 9. loop 钩子（可选）  未注入时启动链返回，控制台交回 ROM shell
```

任何会让机器起不来的错误都走 `os.reboot()`（让 `/boot.tries` 记账生效），而**不** commit；
`fatal` 计划（`no_system` / `rollback_fail` / 写盘失败）**不** reboot——重启环修不了坏字节——
它打印三行可 grep 的 ASCII 报告后把控制台留给 ROM shell。

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

### 4.1 七个 capability（固定集合，无继承）

| cap | 授予的能力 |
| --- | --- |
| `fs.read` | 受控读文件 / 列目录 / `getFreeSpace` |
| `fs.write` | 受控写 / 追加 / 删除 / 建目录（按 app 计写入配额） |
| `net.rpv` | 通过 rpv 节点收发（net 服务 / probe） |
| `net.rednet` | 裸 rednet（OTA / 救援工具用，普通 app 一般不需要） |
| `redstone` | 红石读写 |
| `peripheral` | peripheral 访问 |
| `http` | CC 的 http API（掌机上通常不可用） |

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

`api.sys`（`status()` / `apps()` / `perms(app)` / `launch(name)`）**不是第 8 个 cap**，而是宿主注入的
只读内省面，且只交给 `/system/` 下的系统包；用户包拿到桩，`launch` 按**目录**而不是按 cap 授权。

### 4.3 没有键盘这条边界

P2 运行时没有 input cap，所以"询问"是注入的回调：默认实现（`startup.P.default_ask`）对
`/system/` 下的系统镜像包按 manifest 原样授权（`PERMS_PREGRANT`），其它包一律拒绝，
等输入服务落地再把回调换成真询问。launcher 的按键是纯函数 `M.handle_key(state, key)`，
由 `opts.keys` 驱动；Net app 的 probe 目标从 `/etc/net.target` 读一行。

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
| `capabilities` | 否 | 只能是 §4.1 的 7 个 cap；未知 cap 直接拒绝加载 |
| `max_starts` | 否 | 正整数，启动次数配额（默认 8，超限 `quota exceeded: starts`） |

> `DECISIONS.md` §5.2 的设计口径还列了 `size`（包内字节总和）；当前运行时**不校验** `size`，
> 完整性靠安装器的可选 `SHA256SUMS`（`<64 hex>  <relpath>`，逐文件校验、包内每个文件都必须列出）。

### 5.3 运行时行为

- 每个 app 一个 coroutine，`rt:tick()` 推进；`main.lua` 可以 `while true do api.yield() end`。
- 配额从"拒绝而不截断"：启动次数、`fs.write` 字节数超限都返回 `nil, "quota exceeded: ..."`。
- 生命周期钩子失败只记 `APP_HOOK_FAIL`，不中断状态迁移；`kill` 之后不会再被调度。
- 安装器（`kernel/installer.lua`）：暂存到 `/apps/.tmp-<name>/` → 校验 → 替换；`fs.move` 被拒时
  降级为 copy + 逐文件校验 + 删临时目录；任何失败保留旧版本。

### 5.4 三个系统应用的 cap（写死）

| 包 | version | capabilities |
| --- | --- | --- |
| `launcher.app` | 0.1.0 | `fs.read`, `fs.write`（写只用于 `/etc/launcher.recent`，被拒就忽略） |
| `settings.app` | 0.1.0 | `fs.read`（**严格只读**，没有写路径） |
| `net.app` | 0.1.0 | `net.rpv`, `fs.read` |

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
5. `journal(state=applying)`，逐文件：a/b 下 `.part` 并回读校验 `new_sha` → c/d 旧文件 move 进
   `/update.backup/` 并回读校验 `old_sha`（备份不可信就立刻挪回并放弃整次更新）→ e/f `.part`
   move 进 `/system/` 并回读校验 `new_sha` → g 删残片。
6. `journal(state=applied)`：**只有到这一步才允许重启**去试新版本；bootloader 接手（§3.2）。

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

当前实测（v1.0.0）：

```
entries    : 26 (26 files, 0 dirs, 0 missing)
TOTAL      : 401,778 B   (system 25 文件 400,708 + 根 starter 1,070)
VERDICT    : SIZE_WARN   (stretch 349,525 < total 401,778 <= upper 629,145)
MARGIN     : 52,253 bytes over stretch; 227,367 bytes under upper
WINDOW_OK  : sum=601778 limit=900000
```

- **`SIZE_WARN` 不是失败**：超目标线只报差额；硬门禁才是发版阻断线。
- 更新窗口是**独立判定**（`SIZE_FAIL` 时也照常打印 `WINDOW` 行）：`401,778 + 200,000 = 601,778`，
  距 900,000 还有 298,222 B，距机身 1,000,000 B 还有 398,222 B。
- **发布包 ≠ 镜像**：发布 zip 是完整源码集（含 `recovery/` 与两份文档），`install.set` 统计的才是镜像；
  不要拿 zip 体积当门禁，也不要因为包里有 `recovery/` 就以为它在镜像里。

---

## 8. 已知限制（v1.0.0，明确不做超出上限的承诺）

| 限制 | 具体表现 / 影响 |
| --- | --- |
| **无 DNS 客户端** | `services.lua` 未 vendor，`node:lookup(name)` 返回 `nil`；域名解析只能用 `/etc/hosts.conf` 静态表 |
| **无 ICMP / 无 ping** | `icmp` 模块已裁；`probe()` 用 UDP 一发一收，所以"端口无响应 / 主机不在线 / 被丢弃"对外都只能表现为 timeout |
| **无 DHCP / NAT / 路由 / WAN ACL / 多跳** | `nat`/`wan`/`wansec`/`fabric`/`topo`/`qos`/`mcast`/`dv` 全部裁掉；掌机只做端点，不转发、不做网关 |
| **无 `input` capability** | 运行时的 7 个 cap 里没有输入/终端 cap；launcher 的按键是纯函数 + `opts.keys`，Net app 的 probe 目标从 `/etc/net.target` 读一行 |
| **没有事件循环接管** | 启动链 commit 后返回（starter 不传 `loop` 钩子），ROM shell 接管；首帧与桌面是**静态渲染**，按键事件无处派发 |
| **net 服务未默认注册** | 默认启动链只注册 `hello` 占位；`net` 服务随镜像提供（`S.spec()` / `S.register()`），需在启动时注入 `services = { ... }` 才启动（见下） |
| **settings 严格只读** | 只声明 `fs.read`，没有任何写路径；看得到配置，改不了配置 |
| **无中文** | CJK 字库与三件套全部删除（省 1,440,360 B）；界面与日志纯 ASCII，原版 CC 字体即可显示 |
| **无 installer UI** | 安装器是模块 API（`inst:install(...)`），没有图形包管理器；安装需要手动执行或等输入服务 |
| **无进程隔离 / 无法抢占** | app 共享一个 Lua VM；死循环只能重启整机；"杀进程"只是不再调度它的 coroutine |
| **单文件更新上限 65,536 B** | 任何单文件超过 `F_MAX` 就永远无法通过文件集更新（当前最大 `rpv/node.lua` 60,498 B） |

`net` 服务的注入点（当前镜像**未**默认接线；接上后 net.app 才能拿到 `net.rpv` 宿主对象）：

```lua
local specs = { dofile("/system/net/service.lua").spec({ log = print }) }
-- 启动链的 opts.services 接受这样的 spec 列表
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

基线（v1.0.0）：**OFFLINE_PASS 2890 / FAIL 0 / GROUPS 158**。

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
| 启动链 `/system/startup.lua` | `P.VERSION = 0.2.0`，20,654 B |
| bootloader | `M.VERSION = 2.0`，45,623 B |
| kernel / apps / permissions | 1.0 / 1.0 / 1.0（13,958 / 28,804 / 18,387 B） |
| installer / ota | 1.0 / 2.0（13,441 / 28,311 B） |
| rpv 子集 | 10 文件 / 131,590 B（9 模块 + loader） |
| 系统应用 | launcher / settings / net，均 0.1.0 |
| 镜像 | 26 条 / 401,778 B / `SIZE_WARN` / `WINDOW_OK` |

设计口径以 [`DECISIONS.md`](DECISIONS.md)（架构、门禁、发布）与 [`P6-design.md`](P6-design.md)
（文件集更新、journal、崩溃窗口、bootloader 决策表）为准；本文是面向使用者的入口，
两者冲突时以 `DECISIONS.md` 为准。装机步骤见 [`INSTALL.txt`](INSTALL.txt)。
