# P6 设计：文件集（delta）系统更新

- 位置：`pyroet-os/P6-design.md`。P6-1 产物：**只有设计，没有代码**；不改 `install.set` / `DECISIONS.md` / 测试。
- 仓库 `cc_tweaked` @ `main`。本文替换 `DECISIONS.md:48-102`（§2.3–2.8 双槽整镜像）为 **B 方案：文件集更新**。
- 口径：字节数取自 `python pyroet-os/tools/sizecheck.py` 实测或据此推算；估算项标注“估算”。
## 1. 动机与取舍
### 1.1 空间账（实测）

| 项 | 字节 | 依据 |
| --- | --- | --- |
| 稳态系统 | 343,375 | sizecheck `TOTAL 343,375 / SIZE_WARN / 6,150 under 349,525`（23 条，`install.set:77-116`） |
| 双槽更新期 | **686,750** | 2 × 343,375；`install.set:15-23` 明写 “peak usage is 2 x image” |
| 文件集（改 10%） | 377,713 | 343,375 + 34,338（§7） |
| 文件集（改 30%） | 446,388 | 343,375 + 103,013（§7） |
| 文件集（改 100%） | 686,750 | 与双槽**完全相等**（§7）；机身配额 1,000,000 B 见 `DECISIONS.md:15` |

用户口径的“450–686 KB”对应改动 **30%–100%**；10% 档只有 377,713 B，比双槽省 309,037 B。按真实迭代量验算：P5a 新增
`kernel/installer.lua` 13,253 + `kernel/ota.lua` 12,912 = 26,165 B，占 343,375 的 **7.6%**（`DECISIONS.md:350-357`）
⇒ 日常更新落在 10% 档以内，“450 KB 起”是高估。
### 1.2 为什么放弃双槽
①双槽峰值是**常数** 686,750 B，与改了多少无关；物理上限 1,000,000 B（`DECISIONS.md:15`）只留 313,250 B 给用户数据、
日志（`/kernel.log`，`startup.lua:63`）与已装 app，掌机无盘、这个余量不够。②双槽靠“删坏槽”收尾（`boot.lua:369-381`、`boot.lua:527-532`）：
一次删 343,375 B 本身是断电风险点，删失败只记 `BOOT_OLD_SLOT_DELETE_FAILED`（`boot.lua:531`），空间长期“一活一废”。
③`boot.ok` 必须按槽写（理由见 `boot.lua:28-33`），代价是每槽一套凭据；改成单一 `/system/` 后这套语义全废，不如换全局凭据。
### 1.3 放弃“镜像级原子性”换来什么、失去什么
**换到**：峰值从常数 686,750 B 变成 `343,375 + 本次改动字节`（低改动省 300 KB 量级）；稳态只有一个 `/system/`，没有删不掉的死空间；
备份目录天然是回滚素材，不需要“另一份完整镜像”。
**失去**：没有“一次指针翻转 = 整机切换”的原子点——回滚变成**逐文件写回**，每步都可能断电，必须引入 journal + 逐文件 `sha256` + 幂等回滚（§4/§5）；
“一半新一半旧”的中间态从**不可达**变成**可达**，必须由 bootloader 修（§6），修不好就是 fatal；`/update.backup/` 是回滚的唯一来源，被用户删掉就永久失去回滚能力（§10.1 讨论缓解）。
## 2. 磁盘布局
```
/                     机身根（1,000,000 B 配额）
├─ startup.lua        ROM 唯一入口，3 行 stub：dofile("/system/startup.lua")，不参与更新
├─ boot.ok            全局提交凭据（替代按槽 /slots/<x>/boot.ok）
├─ boot.tries         连续试启动计数（替代按槽 /slots/<x>/.tries）
├─ update.journal.<n> 更新意图日志，按 seq 递增，保留最新两代
├─ update.backup/     只存本次会被修改的旧文件，结构与 /system/ 同构
└─ system/            唯一系统目录（boot/kernel/rpv/net/system 全部落进来）
```
### 2.1 单一 `/system/`
23 条路径现在散在根上（`/boot.lua`、`/kernel/*`、`/rpv/*`、`/system/*.app`，`install.set:77-116`）；P6 统一挂到 `/system/` 下，
`relpath` 相对 `/system/`（如 `kernel/ota.lua`）。**必须写死的例外**：`/startup.lua` 留根，因为 ROM 只自动跑这一个文件
（`startup.lua:1-4`），迁移后只做 `dofile("/system/startup.lua")`，而 `P.BOOT_PATH`（`startup.lua:57`）改为 `"/system/boot.lua"`。
根 stub ≈60 B、**不在更新集合内**：它小到不值得为它设计回滚，而它一坏整机失去唯一入口。
### 2.2 `/update.journal.<n>`：三态 + 一代墓碑
```
PYROET-UPD-JOURNAL-1
seq=7
state=prepare|applying|applied|rolledback
version=0.6.0
manifest_sha=<64 hex>
kernel/ota.lua <old_sha|-> <new_sha> 12912
```
- 三态是正常路径：`prepare`（意图落盘、系统未动）→ `applying`（逐文件替换中）→ `applied`（全部替换并回读校验完）。
- **第四值 `rolledback` 是必要墓碑**：回滚后若删日志，“回滚到一半又断电”就无法与“没回滚过”区分；保留 `applying` 又会让回滚每次开机重放。
- **为什么按 seq 留两代**：`boot.atomic_write`（`boot.lua:205-247`）的替换是“写 `.tmp` → **删旧** → move”（`boot.lua:214-219`），
  因为 CC 的 `fs.move` 不能覆盖（`boot.lua:202-204`，`installer.lua:262-267` 同坑）。于是“原地重写 journal”存在**目标已删、新的还没挪进来**
  的窗口，一次断电就丢日志 = 丢回滚意图 = 只能走 flash。两代并存消掉该窗口：bootloader 取**能解析且 seq 最大**的一代，坏代忽略。
- `old_sha = -` 表示本次新增（回滚 = 删除它）。journal **不记逐条进度**：进度由磁盘哈希推断（§5.3），这是它在任意断电点自洽的唯一办法。
### 2.3 `/update.backup/<relpath>`
只存本次会被修改的旧文件。硬约束：每个条目必须是“已被证明可用的旧字节”——先写备份、**回读校验 `old_sha`**、再动 `/system/`（§5.1 第 d 步）；
`sha256(backup) ≠ old_sha` 时**不许**用它覆盖系统文件，直接判 `ROLLBACK_FAIL`（§4.3）。
### 2.4 `/boot.ok`（全局）
替代按槽的 `boot.write_marker`/`boot.read_marker`（`boot.lua:328-367`），单行：
```
PYROET-BOOT-OK-2 version=0.6.0 manifest_sha=<64 hex> ts=<epoch ms>
```
`manifest_sha` 是清单聚合哈希（§3.2），与 journal 同源；两者相等 ⇒ 新版本已提交，这是 `applied` 与“已提交”的唯一区分手段，也是
`startup.lua:138-153`（`P.commit_info` 现在读 `/slots/<x>/.image` 的 `sha256=`）的替换点。`ts` 仍用 `%.0f`（`boot.lua:317-326` 的 `fmt_int`：
CraftOS-PC 的 `%d` 拒绝 1.79e12 量级）。
### 2.5 迁移时删除清单
删除：`/slots/`（整目录）、`/boot.slot`、`/boot.slot.tmp`、`/slots/<x>/.tries`、`/slots/<x>/boot.ok`、`/slots/<x>/.image`、
`/slots/<x>/image.bin`、`/system.tmp*` 残片；根上旧格式 `/boot.ok` 是**改写**（§2.4），不是删。**顺序写死**：先写新 `/boot.ok` →
再写 `update.journal.<1>`（`state=prepare`，`files=0`）→ 最后才删 `/slots/`。反过来（先删槽）任何一步断电都会让设备**同时**没有系统也没有提交凭据。
对应删除点：`M.paths`（`boot.lua:129-137`）、`M.slot_path`（139-144）、`M.marker_path`/`M.tries_path`（146-152）、`M.is_slot`/`M.other`（100-108）、`M.delete_slot`（369-381）。
## 3. 更新协议 `PYROET-OTA/2`
协议名仍 `pyroet-ota`，前缀 `PYROET-OTA/1`（`ota.lua:32`）→ `/2`。仍只走裸 rednet（`ota.lua:3-5`、`DECISIONS.md:249`），不许依赖 rpv。
### 3.1 报文

| 方向 | 报文 | 字段与边界 |
| --- | --- | --- |
| 请求 | `PYROET-OTA/2 GET meta` | — |
| 应答 | `PYROET-OTA/2 META version=<tok> files=<n> manifest_sha=<64 hex>` | `version` 只允许 `[%w._-]` 且 ≤32（同 `ota.lua:104-106`）；`files` 1..256 |
| 请求 | `PYROET-OTA/2 GET <idx>` | idx 十进制、0 起，指向第 idx 条 `FILE` |
| 应答 | `PYROET-OTA/2 FILE <relpath> <size> <sha256>` | `size` 1..65536（`F_max`）；`sha256` 64 hex，一律小写 |
| 请求 | `PYROET-OTA/2 GET <idx> <offset>` | offset 十进制，落在 `[0,size)` 且为 `MAX_DATA` 整数倍 |
| 应答 | `PYROET-OTA/2 DATA <relpath> <offset> <hex>` | hex ≤ `MAX_DATA` = 8,192 B 载荷（16,384 hex 字符） |

客户端先取 `META`、再逐 idx 取 `FILE`；**收齐全部描述行后**算聚合哈希与 `META.manifest_sha` 比对，不符 → `OTA_FAIL stage=manifest`，一字节不写。
`MAX_DATA = 8192`：v1 的 `MAX_CHUNK = 32768`（`ota.lua:33`）hex 编码后是 65,536 字符、已贴 rednet 单包上限；v2 降到 8,192 给 `relpath`/`offset` 留余量。
按 `(idx, offset)` 取块，丢包只花一次请求（沿用 `ota.lua:217-230` 的重试语义，1..3 次 + `OTA_RETRY`）；**不做位图**（理由同 `DECISIONS.md:72`）。
### 3.2 清单聚合哈希（唯一定义）
对每条文件按 `relpath` 字节序升序拼一行 `<relpath>\0<size>\0<sha256 小写>\n`，整串做一次 SHA-256 取 64 位小写 hex = `manifest_sha`。
分隔符用 `\0` 而非空格，是为让 relpath 里的空白/斜杠无法改变分帧（§3.3 已禁空格，`\0` 是冗余保险）。`size` 十进制无前导零；
空清单（`files=0`）的聚合哈希定义为 `sha256("")`，供 §2.5 迁移用的空 journal。
### 3.3 路径白名单 / 防穿越（硬规则）
`relpath` 必须**全部**满足，否则 `OTA_FAIL stage=file reason=bad_path`：①非空、≤96 字节、纯 ASCII 可打印；②不以 `/` 开头或结尾、不含 `//`；
③**任何一段都不是 `..`**（现有代码只查整串：`installer.lua:154`、`installer.lua:202`，v2 逐段查）；④每段只允许 `[%w_%-%.]` 且**不以 `.` 开头**
（把 `.tries`/`.image`/`.tmp` 挡在更新集合外；同类思路见 `installer.lua:138-141` 的 `valid_name`）；⑤扩展名只允许 `.lua`/`.txt`/`.conf`/`.cfg`
（估算：现有 23 条全落在其中）；⑥不得出现保留名 `update.journal`、`update.backup`、`boot.ok`、`boot.tries`、`startup.lua`；⑦最终路径永远是
`"/system/" .. relpath`，写前逐级确认父目录是目录而非文件（防“用文件占位目录”）。
## 4. 状态机与崩溃窗口（下表即 §4.1“逐态崩溃窗口”）
`idle → prepare →(清单校验过) applying →(逐文件替换+回读校验) applied → commit 清理`；`applying`/`applied` 的失败分支都汇到回滚（§4.2/§4.3）。
`MAX_TRIES = 2`（`boot.lua:67`）不变：第 3 次仍失败即回滚，判据沿用 `trial_step`（`boot.lua:397-413`）的 `tries > MAX_TRIES`。

| 态 / 窗口 | 此刻断电会怎样 | 谁修 |
| --- | --- | --- |
| 无 journal | 等同“从未更新”，旧系统完整 | 无事 |
| `prepare`（日志写前） | 日志没写成功 ⇒ 见“无 journal”；只留空 `/update.backup/` | bootloader 删空目录 |
| `prepare`（日志写后） | 系统一字节没动，日志说“准备更新” | bootloader 删日志+删残片，正常启动（§6 第 4 行） |
| `prepare→applying` 改写窗口 | 两代同时存在（老代 prepare、新代 applying 或反之） | bootloader 取 seq 最大且可解析的一代（§2.2） |
| `applying`（每文件 a–h 之间） | 部分文件已新、部分已旧、可能残留 `.part` | bootloader **启动前**先回滚（§4.2），再按旧版本启动 |
| `applying→applied` 改写窗口 | 同上代际窗口 | 取最大 seq；有 `applied` 代就按 `applied` 走 |
| `applied`（未 commit） | 新版本在盘上，但没有凭据证明提交过 | 试启动新版本，`boot.tries` +1 **先落盘**（沿用 `boot.lua:397-404` 的 persist-first） |
| `applied` + 内核三次失败 | 新版本起不来 | 回滚到 backup（§4.3）；成功后写旧 `boot.ok`、日志置 `rolledback` |
| commit（写 `boot.ok` 后、删日志前） | 新版本已提交，日志还在 | 下次开机见 `applied` + `boot.ok.manifest_sha` 相等 ⇒ 直接清理 |
| `rolledback` | 已回滚完成 | 清理日志与备份，正常启动 |

### 4.2 `applying` 中崩溃 = 启动前先回滚
回滚只依赖三个磁盘事实：journal 的 `(relpath, old_sha, new_sha)`、`/update.backup/<relpath>` 的内容、`/system/<relpath>` 的内容。逐条：
① `sha256(/system/<relpath>) == old_sha` → 已就位，跳过；② `sha256(/update.backup/<relpath>) == old_sha` → 挪回 `/system/` 并回读校验；
③ `old_sha = -` 且目标存在 → 删掉；④ 都不成立 → §4.3。关键是**用哈希判定进度**而非标志位：任何“写标志位”的动作本身都会断电，
而哈希是内容的函数、天然不可骗。残留 `.part` 在回滚后统一删。
### 4.3 回滚失败 = `ROLLBACK_FAIL` → `recovery/flash.lua`
任一成立即判失败，**既不启动新版本、也不假装启动旧版本**：三事实都不成立；备份存在但 `sha256 ≠ old_sha`（备份损坏）；
写回后回读不符（CC 无 `fsync`，回读是唯一证明）；journal 不可解析且只剩一代（§2.2 兜底没了）。输出固定三行便于 grep：
```
BOOT_ROLLBACK_FAIL seq=<n> relpath=<path> want=<old_sha 前12位> got=<实际前12位>
BOOT_FATAL reason=rollback_fail
FLASH_REQUIRED tool=recovery/flash.lua slot=<n/a> hint=reboot_and_run
```
最后一行必须指向 `recovery/flash.lua`（`flash.lua:21-49`），且 bootloader **不许 `os.reboot()` 死循环**——理由同 `startup.lua:17-22`：
重启环修不了坏字节。此时停在全屏提示，把控制台交给用户。
## 5. 应用顺序与原子性边界
### 5.1 逐文件 8 步（顺序即安全保证）

| 步 | 动作 | 断电后果 |
| --- | --- | --- |
| a | 建 `/update.stage/<relpath>.part`，按 offset 顺序 append | 只有半成品，`/system/` 未动 → 回滚第 ③ 步删它 |
| b | 回读 `.part`：长度 == `size` 且 `sha256 == new_sha` | 同上；不通过就删掉重下 |
| c | `fs.move("/system/<relpath>", "/update.backup/<relpath>")` | 系统“少一个文件”，备份可能不完整 → 见 d |
| d | 回读备份：`sha256 == old_sha`，否则立刻挪回并放弃本次更新 | 见 §4.2 第 ② 步 |
| e | `fs.move("/update.stage/<relpath>.part", "/system/<relpath>")` | 目标不存在 ⇒ 无需先删 |
| f | 回读 `/system/<relpath>`：`sha256 == new_sha` | 不通过 → `ROLLBACK_FAIL`（§4.3） |
| g | 删 `.part` 残留（正常已被 e 移走） | 无事 |
| h | 本文件完成；最后一条完成后把 journal 改写为 `state=applied` | 见 §2.2 代际窗口 |

**为什么 c 用 move 不用 copy**：CC 没有 rename-overwrite（`boot.lua:202-204`），但 move 到**不存在的目标**可靠；先把旧文件移走，
既省一次 60 KB 级复制，又让 e 的 move 不需要“先删目标”这个破坏性动作——`boot.lua:214-219` 的窗口在 e 步被彻底消掉。
代价是 c 之后 `/system/` 短暂缺文件，那正是 journal 存在的意义。
### 5.2 journal 落盘顺序（只在三处写）
①下载前 `state=prepare`（含全部 `(relpath, old_sha, new_sha, bytes)`，`old_sha` 由**本地现算**、不信服务器）；②清单校验通过、第一个文件替换前
`state=applying`；③最后一个文件 f 步通过后 `state=applied`。回滚成功再写 `state=rolledback`；commit 不写 journal，直接删。
**每次写都是“写新一代 → 保留上一代”，没有原地覆盖的路径。**
### 5.3 无 `fsync` 的最强保证与“为什么校验必须在下载完成时”
CraftOS 的 `open/write/close` 不提供 `fsync`、也不保证脏页落盘，因此**不承诺**跨文件原子性，只承诺：单文件级“要么完整 `old_sha`、要么完整
`new_sha`、要么备份副本存在且可读”，由 b/d/f 三次**回读校验**证明（回读是 CC 上唯一可用的落盘确认）；系统级“任意断电点都能靠
journal + backup 回到旧版本完备状态”（例外见 §4.3）；**不承诺** `applying` 的中间态有可运行性。
校验必须在下载完成时，因为**校验是回滚能力的来源**：`old_sha`/`new_sha` 是两边的凭据，一旦进入 `applying` 系统随时处于中间态，
若此时才发现内容不可信，唯一出路是用备份回到旧版本——而备份的可信度依赖 `old_sha` 在**动手之前**就正确。把校验放到替换之后，
等于“拿被写坏的系统验证自己被写坏”，那时已无可回滚字节，只能走 `recovery/flash.lua`。现有代码正是这个顺序（`ota.lua:232-262` 逐块 →
`ota.lua:292-298` 全量 → `ota.lua:303-312` 才翻指针）；P6 前移成“收齐清单即算聚合哈希”，因为文件集没有“整个镜像”这个天然边界。
用户要求的三段职责第一条即此项：校验失败时 journal 仍停在 `prepare`，`/system/` 一字节未动，删日志即恢复原状。
## 6. bootloader 决策表
输入只有三个：`journal`（无 / 最大代状态）、`/boot.ok`（无 / 有，带 `manifest_sha`）、`/boot.tries`。`/system/` 缺失是独立第 1 类。

| # | journal | `/boot.ok` | tries | 行为 | fatal |
| --- | --- | --- | --- | --- | --- |
| 1 | 任意 | 任意 | 任意 | `/system/` 不存在/不可读 → `BOOT_FATAL reason=no_system` | **是** |
| 2 | 两代都不可解析 | 任意 | 任意 | 按“无 journal”处理，记 `BOOT_JOURNAL_BAD` | 否 |
| 3 | 无 | 有 | ≤2 | 正常启动，tries 不动（稳态） | 否 |
| 4 | `prepare` | 有/无 | 任意 | 下载未应用：删 journal + 删空备份，转第 3/5 行 | 否 |
| 5 | 无 | 无 | 任意 | 有系统无凭据 → 按“首装未提交”试启动（tries+1 先落盘） | 否 |
| 6 | 无 | 有 | >2 | 不该出现：`BOOT_TRIES_STALE`、tries 归零、正常启动 | 否 |
| 7 | `applying` | 有 | 任意 | **先回滚** → 成功后按第 3 行启动旧版本 | 否 |
| 8 | `applying` | 无 | 任意 | **先回滚** → 成功后按第 5 行试启动（回滚不改版本，tries 不动） | 否 |
| 9 | `applying` | 任意 | 任意 | 回滚失败（§4.3 四种）→ `BOOT_ROLLBACK_FAIL` + `FLASH_REQUIRED` | **是** |
| 10 | `applied` | 有且 sha==journal | ≤2 | 已提交：清理 journal/backup/`.part`，正常启动 | 否 |
| 11 | `applied` | 有但 sha≠journal | 任意 | 未提交：试启动新版本（tries+1 先落盘）；tries>2 转第 13 | 否 |
| 12 | `applied` | 无 | 任意 | 未提交：试启动新版本（tries+1 先落盘）；tries>2 转第 13 | 否 |
| 13 | `applied` | 任意 | >2 | 回滚到旧版本，写旧 `boot.ok`、日志置 `rolledback` | 否 |
| 14 | `applied` | 任意 | >2 | 回滚失败 → `BOOT_ROLLBACK_FAIL` + `FLASH_REQUIRED` | **是** |
| 15 | `rolledback` | 有 | ≤2 | 清理 journal/backup，正常启动旧版本 | 否 |
| 16 | `rolledback` | 无 | 任意 | 回滚完成但凭据丢了 → 按第 5 行试启动 | 否 |
| 17 | 任意 | 有且 sha==journal，version 不同 | ≤2 | `BOOT_VERSION_MISMATCH`，**以 manifest_sha 为准** | 否 |

fatal 只有三类：`no_system`（1）、`rollback_fail`（9/14）、写盘失败（`/boot.ok` 或 journal 写不进去，沿用 `boot.lua:400-404` 的
`BOOT_FATAL reason=tries_unwritable` 思路）。fatal **不 reboot**（`startup.lua:17-22`）。
## 7. 空间账
`S = 343,375`、`b` = 本次改动字节、`F_max = 65,536`（实测最大文件 `rpv/node.lua` 60,498 B）。峰值 = `S + b`；**暂存不叠加**：
第 k 个文件的 `.part` 完整时，它自己就是“还没备份的那一个”，故峰值恰为 `S + Σ(已备份)`，末次取到 `S + b`（§5.1 c 步用 move 的第二个收益）。

| 改动 | b | 峰值 | 折算 | 与双槽比 |
| --- | --- | --- | --- | --- |
| 10% | 34,338 | **377,713** | 369 KiB | −309,037 |
| 30% | 103,013 | **446,388** | 436 KiB | −240,362 |
| 60% | 206,025 | **549,400** | 537 KiB | −137,350 |
| 100% | 343,375 | **686,750** | 671 KiB | **0（完全相等）** |

- **稳态** = `S` + journal（≤8 KiB）+ `boot.ok`/`boot.tries`（<100 B）≈ 343,375 B，无第二份系统。
- **上限一（物理）**：`b ≤ 1,000,000 − S = 656,625`。100% 改动也装得下，但仍剩 313,250 B。
- **上限二（策略，建议）**：`BACKUP_CAP = 200,000`，超出则在下载**开始前**拒绝：`OTA_REFUSE reason=too_big need=<b> cap=200000`；
  此时峰值 ≤ 543,375 B，留 456,625 B 给用户数据。取值待拍板（§10.1）。
- **单文件上限** `F_max = 65,536`，超过即 `OTA_FAIL stage=file reason=too_large`。`rpv/node.lua` 60,498 B 是现状天花板，它一旦超过 64 KiB 就永远无法通过文件集更新——先做 P1 裁剪。
- **拒绝时机**：`BACKUP_CAP` 检查在收到全部 `FILE`、算出 `b` 之后、写 `prepare` 之前 ⇒ 空间不足时系统一字节不动。
## 8. 对现有模块的改动清单
行数为当前实测（`Get-Content | Measure-Object -Line`）。变化量按“删/增”列。

| 模块 | 现在 | 预计 | 删/增 | 具体改动 |
| --- | --- | --- | --- | --- |
| `boot.lua` | 581 行 / 21,826 B | ≈660 行 | −200/+280 | 删 `is_slot`/`other`（100-108）、指针读写（199-272）、`marker_path`/`tries_path`（146-152）、`delete_slot`（369-381）、按槽 `trial_step`/`rollback`/`recover`/`begin`（397-502）、`commit`（508-534）、`BOUND`（551-554）；加 journal 两代读写与三态改写、`/update.backup` 遍历、按哈希的幂等回滚（§4.2）、`boot.ok` 新格式、§6 决策表、§2.5 迁移清理 |
| `kernel/ota.lua` | 320 行 / 12,912 B | ≈520 行 | −110/+310 | `PREFIX`/`VERSION`（32）、`parse_meta`（96-112）、`parse_data`（114-127）换协议 2；`write_image`（232-262）拆成“收清单/收单文件/应用单文件”；`update`（264-318）改三态；`discard`（174-181）改成删 journal 与残片；新增聚合哈希、路径白名单、`BACKUP_CAP` 预检 |
| `kernel/installer.lua` | 340 行 / 13,253 B | ≈360 行 | −10/+30 | 复用同一清单格式：`SHA256SUMS`（`installer.lua:28`）格式不变，但两端都按 §3.2 归一化比较，使 app 包与系统更新共用一张表、一个 `manifest_sha`；`verify_sums`（145-186）的路径检查从整串 `..` 升级为逐段规则（§3.3③） |
| `recovery/flash.lua` + `recovery/proto.lua` | 54 + 111 行 / 2,496 + 5,435 B | 同左 | 0 | **不动**：仍走 `recovery/proto.lua:65-93` 的 `/slots/<x>` 写入与 `proto.lua:51-55` 的 `/boot.slot`。因此它是“回到旧布局”的最后手段，恢复后还要再跑一次迁移（§2.5）——约束见 §10.2 |
| `startup.lua` | 506 行 / 19,372 B | ≈512 行 | −25/+31 | `P.BOOT_PATH`（57）改 `/system/boot.lua`；`commit_info`（138-153）不再读 `.image`，改为把 journal 的 `manifest_sha` 传给 `boot.commit`；调用点（466-475）改成“写全局 `/boot.ok` → 删 journal → 删备份”，`STARTUP_COMMITTED` 字段换成 `manifest_sha` |
| `tests/t_boot.lua` | 344 行 / 8 组 | ≈420 行 | +76 | **6 组必须重写**：`boot.trial`（57）、`boot.rollback_impossible`（100）、`boot.recover`（120）、`boot.commit`（182）、`boot.pointer`（248）、`boot.pointer_fallback`（283）；`boot.normal`（34）与 `boot.guards`（349）留骨架 |
| `tests/t_startup.lua` | 432 行 / 11 组 | ≈450 行 | +18 | **3 组要改**：`startup.chain`（44，commit 字段）、`startup.commit_fail`（285）、`startup.modules`（349，`/system/boot.lua` 路径）；其余 8 组不动 |
| `tests/t_ota.lua` | 441 行 / 15 组 | ≈620 行 | +179 | **15 组全重写**（协议 1 的解析在 122/157、槽语义在 246、指针在 410 全部消失），另加文件集用例 |
| 新增 `tests/t_update_journal.lua` | 0 | ≈260 行 | +260 | journal 三态/两代/坏代、按哈希的幂等回滚、§4.3 四条失败路径 |

净增：实现 **+471 行**（boot +79、ota +200、installer +20、startup +6），测试 **+533 行**。**体积影响**：`boot.lua` +4,900 B、
`ota.lua` +8,700 B（按行密度 21,826/581 ≈ 37.6 B/行、12,912/320 ≈ 40.4 B/行推算）→ **+13,600 B**，TOTAL 343,375 → ≈**356,975 B**，
**撞 349,525 B 硬门禁（`sizecheck.py:32`），超 7,450 B**。所以 P6 落地必须先砍掉等量体积（`system` 组件实测共 44,323 B，是最大的可裁项）——
不在本文范围，但**实现前要有结论**。
## 9. 测试计划
### 9.1 状态机用例矩阵（22 条 = §6 的 17 行 + 5 条交叉）
①`/system` 缺失 → `no_system`；②无 journal+`boot.ok`+tries=0 → normal；③同上 tries=3 → `BOOT_TRIES_STALE`+归零；④无 journal+无 `boot.ok`+有系统 → 试启动、tries 先落盘；
⑤`prepare`+有 `boot.ok` → 清理后 normal；⑥`prepare`+无 `boot.ok` → 清理后试启动；⑦`applying`+有 `boot.ok` → 回滚 → normal（旧版）；⑧`applying`+无 `boot.ok` → 回滚 → 试启动；
⑨`applied`+sha 相等 → 清理+normal；⑩`applied`+sha 不等 → 试启动 tries=1；⑪`applied`+无 `boot.ok` → 试启动 tries=1；⑫`applied`+tries=3 → 回滚+写旧 `boot.ok`+`rolledback`；
⑬`rolledback`+有凭据 → 清理；⑭`rolledback`+无凭据 → 试启动；⑮`version` 与 sha 不一致 → 以哈希为准；⑯两代日志都坏 → 退化“无 journal”；⑰只剩一代且坏 → 按 `applying` 保守回滚；
⑱`old_sha` 全 `-`（纯新增）→ 回滚=删文件；⑲纯删除的更新（`size=0`）→ 替换=移入备份、不写回；⑳空清单 `files=0` → `prepare` 直接被当清理；
㉑路径白名单拒绝 → `stage=file`、系统未动；㉒`BACKUP_CAP` 超限 → `OTA_REFUSE`、系统未动。
### 9.2 崩溃注入点（每步之间各一次）
在 fake `fs` 上按“第 N 次 `write`/`move`/`delete` 之后抛错”注入，覆盖 §5.1 的 a–h **每两步之间**（7 点）× 每条记录，加 §5.2 的 3 个 journal 写点前后（6 点）
与 §2.5 的 3 个删除点，固定成 **16 个注入点**。每点断言两件事：`boot.begin()` 的 `action` 符合预期（`rollback`/`normal`/`fatal`），且回滚后**所有**文件
`sha256 == old_sha`（不是“看起来能启动”，是逐文件哈希）。
### 9.3 回滚校验失败路径
五条都必须断言 `BOOT_ROLLBACK_FAIL` + `BOOT_FATAL reason=rollback_fail` + `FLASH_REQUIRED` 指向 `recovery/flash.lua`，且**不删任何现场文件**（保留证据）：
备份内容与 `old_sha` 不符；`/system/<relpath>` 既非 old 也非 new（第三方写坏）；备份缺失而 `old_sha ≠ -`；回滚写回后回读不符（fake fs 让 `write` 静默截断）；journal 不可解析且只剩一代。
### 9.4 协议解析边界
`META`：`files=0`/`257`/非数字、`manifest_sha` 63 或 65 hex、`version` 含 `/`、缺字段、多余字段。`FILE`：`size=0`/`65537`、大写 sha（接受并转小写）、
`relpath` 含 `..`/以 `/` 开头/含 `//`/含以 `.` 开头的段/长度 97/非 ASCII。`DATA`：`offset` 非 `MAX_DATA` 倍数、`offset ≥ size`、hex 奇数长度、hex 含 `G`、载荷超 `MAX_DATA`、`relpath` 与请求不符、重复 `offset`。聚合哈希：换行序不影响结果、`relpath` 插 `\0` 被拒、sha 大小写归一。
### 9.5 建议新增断言数
`t_boot` +180、`t_ota` +320、`t_startup` +60、新增 `t_update_journal` +140 → **合计 +700 断言 / +36 组**。
当前基线 **2,089 pass / 0 fail / 109 groups**（`DECISIONS.md:363-364`），P6 落地后应约 **2,789 pass / 145 groups**。
`tests/` 是开发材料、不进镜像（`install.set:87-89`），故测试增量不影响门禁。
## 10. 未决问题（需要用户拍板）
1. **`BACKUP_CAP` 取多少**：200,000 B（峰值 ≤543,375，留 456,625 给用户数据）/ 300,000 B（峰值 ≤643,375）/ 不设（只靠物理上限 656,625）。取值决定“多大的更新会被拒绝”，也决定 §1 里“避免为更新预留大空间”能兑现多少。
2. **是否保留 `/boot.slot` 作为兼容遗留**：`recovery/flash.lua` 与 `recovery/proto.lua:51-93` 仍按 `/slots/<x>` + `/boot.slot` 工作且本次要求“不动”。保留 = 迁移后要留一个最小兼容层（估算 40 行，写死在 bootloader 里），“单一 `/system/`”打折扣；不保留 = P7 必须同步改 `flash.lua` 写 `/system/`。
3. **`/boot.ok` 写得太早的风险边界**：`DECISIONS.md:88` 要求“连续 30 秒无未捕获错误”才算 ready，但 commit 在首帧后就写（`startup.lua:466-475`）。双槽里这个激进做法最多让坏槽试启动 3 次；文件集方案里 `boot.ok` 一旦写成新版本，回滚只能靠 tries 超限（3 次开机）。是否把 commit 推迟到 30 秒观察窗结束，需要在“回滚可靠性”与“启动后 30 秒内断电会白测一轮”之间选一个。

## 11. 实现回写（P6-3，2026-10-29；不改上面任何历史结论）

§1–§10 是 P6-1 的设计记录。P6-2 已按 §2–§6 落地“单树 + journal + 差异备份”（口径见 `DECISIONS.md` §13），P6-3 再把“系统镜像内容全部落到 `/system/`”与 recovery 一起收口。以下只记**与本文不一致**的地方：

1. **§2.1 根 stub 的体积与内容**：设计写“≈60 B、只做 dofile”，实现是 **1,071 B**：多出来的是失败兜底（`pcall(loadfile)`、两行 ASCII 错误 + `shell only. Run recovery/flash.lua to reflash /system.`）和一段说明注释。它同样不在 OTA 文件集内（OTA 的 relpath 相对 `/system/`），但列进 `install.set` 作为装机内容。
2. **§2 布局里 `/system` 的下一层**：设计只写“boot/kernel/rpv/net/system 全部落进来”；实现把**系统应用**放在 `/system/system/<name>.app`（不是 `/system/<name>.app`），于是 `/system` 顶层只剩 `startup.lua`、`boot.lua`、`kernel/`、`rpv/`、`net/`、`system/` 六个条目，launcher/settings 的扫描根是 `/system/system`。`/apps` 与 `/etc` 仍是根目录。
3. **§2.1 “`P.BOOT_PATH` 改为 `/system/boot.lua`” 的连带改动**：`P.KERNEL_PATH`/`P.APPS_PATH`/`P.PERMISSIONS_PATH` 也一起指向 `/system/kernel/*`，并新增 `P.SYSTEM_APPS_ROOT = "/system/system"`；`boot.lua` 的 `M.CRYPTO`、`kernel/ota.lua` 的 `CRYPTO`、`kernel/installer.lua` 的 `SYS`/`CRYPTO`、`net/service.lua` 的 hosts 候选路径同步。老镜像由 `boot.migrate_layout()` 重命名迁移（`DECISIONS.md` §13.11），不在本文设计范围内。
4. **§3.1 协议只覆盖 OTA**：recovery 侧没有沿用“idx 顺序 + FILE 行”的请求形态，而是 `PYROET-FLASH/2`：`META` 报文自带完整 `<relpath> <size> <sha256>` 清单（多行正文；磁盘上的 `meta.txt` 就是这段正文），请求是 `GET <relpath> <idx>`（`idx = offset / 8192`），`DATA` 带逐块 sha256；`MAX_DATA = 8192` 与 §3.1 一致。与 §3 的唯一差别：recovery 的 journal 由 `proto` 直接写成 `state=applied`（供 bootloader 试启动回滚），OTA 仍走 `prepare → applying → applied` 三态。
5. **§8 的“recovery 不动”条**：该条已被 P6-3 取代 —— `recovery/proto.lua`/`flash.lua`/`bootstrap.lua` 全部改写为文件集模型，写 `<root>/system`，不再写 `/slots/<x>` 与 `/boot.slot`；`P.ptr()` 由 `P.target()` 取代，`P.write()` 由 `P.write_file_set()` 取代。§10 第 2 条（是否保留 `/boot.slot` 兼容）由此关闭：**不保留**。
6. **§8 的体积影响估算**：估算 `+13,600 B`、TOTAL ≈356,975；实测 P6-2 后 TOTAL **392,500 B**，P6-3 后 **401,640 B / SIZE_WARN**、`WINDOW_OK sum=601,640`（`install.set` 26 条，含 1,071 B 的根 starter）。门禁本身在 G1 已放宽为三层（硬门禁 629,145 / 目标线 349,525 / 更新窗口 900,000），见 `DECISIONS.md` §8.4。
7. **§9.5 断言数**：估算 +700；实际 P6-2 达成 2,651 pass / 149 groups，P6-3 再 +229 断言 / +9 组到 **2,880 pass / 0 fail / 158 groups**（新增 `tests/t_layout.lua`，三个 recovery 套件按文件集模型重写）。
