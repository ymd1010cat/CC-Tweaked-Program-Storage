# ITN Pass 决策记录（itn-pass）

`itn-pass/` 是 `cardkey/` 的**硬分支**：把卡密验证机改造成 InterTeamNet 的**装机/分发凭证 + 装机盘**。
**定位边界：本项目不做入网许可、不做设备入网鉴权**——凭证只决定"这张盘能不能写、能写几次"，
网络层只做连接（`netcheck` 是连通性检查，不是准入判定）。
B1 只做骨架改名（整目录复制 + 改文件名/路径名，不改行为），原 `cardkey/` 一个字节都不动
（实测 `git status --porcelain cardkey` 为空）。本文件记录与 cardkey 分道扬镳的决策、容量数字与
迁移规矩；下文所有 `文件:行号` 都指本仓库当前工作树。

## 1. 容量预算（硬数字）

### 1.1 两种介质

| 介质 | 容量 | 出处 |
| --- | --- | --- |
| CraftOS 软盘（floppy） | 1,228,800 B（1,200 KiB） | `pyromputer-os/tools/fontdisk.py:103`（注释）、`:109`（`FLOPPY = 1228800`）；`pyromputer-os/tools/release.py:66`（`FLOPPY = 1228800`） |
| 电脑自带盘（`computer_space_limit` 缺省） | 1,000,000 B | `pyromputer-os/tools/release.py:64`（`COMPUTER_LIMIT = 1000000`，`:63` 注释说明这是 `computer_space_limit` 的缺省）；`pyromputer-os/README.md:73-74` |

### 1.2 Pyromputer OS 两半装不进一张软盘

`pyromputer-os/README.md:79-81` 的 `--part` 表（实测）：

| part | 内容 | 大小 |
| --- | --- | --- |
| `base`（part1） | 启动入口 + `lib/` 的加载期闭包 + `usr/` + `etc/` + 根文件 | 781,380 B（占一张软盘 63.59%） |
| `modules`（part2） | 惰性加载的 `lib/` 模块 + `rpv/` | 614,005 B（占一张软盘 49.97%） |
| 两半之和（= 装机盘实际要写的字节） | | **1,395,385 B** |
| `all`（整棵树，同表第 3 行） | | 1,395,636 B |

- **1,395,385 B > 1,228,800 B，超出 166,585 B ⇒ 完整 Pyromputer OS 装不进一张软盘。**
- 单看每一半都装得下：part1 是一张软盘的 63.59%，part2 是 49.97%；两张软盘共 2,457,600 B，
  两半合计只占 56.78%。
- 口径注：README 的 `all` 行写 1,395,636 B，比两半之和 1,395,385 B 多 **251 B**（同一张表内的两种实测口径）。
  装机盘预算一律按"两半之和"算（实际写盘的是 part1/part2 两棵树），`all` 行只作整树规模参考；
  发行脚本对各半的实测校验见 `pyromputer-os/tools/release.py:225-236`（part1 不得超
  `COMPUTER_LIMIT`，`:231`）与 `:239-249`（part2 必须有 `.pkgsys`）。

### 1.3 payload 源盘也要放得下（B1 发现的容量约束）

验证机把 `/payload` 复制到软盘（`itn-pass/server/auth/itnpass_config.lua:23` 的
`payload_dir = "/payload"`；读取处 `itn-pass/server/system/disk_writer.lua:208` 起），而 `/payload`
位于验证机自己的电脑盘上，同样受 1,000,000 B 限制。**1,395,385 B 的 pyromputer-os payload 放不进
验证机的电脑盘（超 395,385 B）。**

- 现状约束：磁盘引擎只接受恰好一个驱动器（`itn-pass/server/system/disk_writer.lua`，
  多于一个报 `too many drives`），所以不能"源盘放另一张软盘"。
- 可行路径（**P1 已落第 1 条**，见第 2 节）：
  1. 每次只把一半放进 `/payload`（781,380 B 或 614,005 B，都 < 1,000,000 B），写一张盘换一次内容；
     这与"两张盘两次写盘事务"天然对齐，代价是操作员要切两次 payload。P1 的 profile 目录把这条
     写成规则：`pyromputer-os` 的两个 part 是 `/payload/part1` / `/payload/part2`，一次写盘只写
     一个 part；操作员也可以把那一半直接换进 `/payload`（引擎按盘上实际存在的子树选 part）。
  2. 上调验证机的 `computer_space_limit`（Minecraft 服务端配置，不是本仓库代码）；
  3. 缩小 payload（即 `pyroet-os` profile 的动机；其容量门已在代码里强制）。
- 验证机自身代码只占 16 个 lua 共 86,918 B（B3 实测；B1 记录为 15 个 81,883 B，两个数字的测量
  口径没有可逐字节对账的基线——itn-pass 尚未入库），电脑盘剩余空间几乎全留给 `/payload`。

## 2. 装机盘决策：容量按 payload profile 分别定

**不做全局一刀切。** 每个 payload profile 有自己的介质数量、写盘事务数与卡密额度。
P1 起 profile 不再是文档口径：`itn-pass/common/itnpass_profile.lua`（部署 `/itnpass_profile.lua`）
是唯一目录，站端服务、写盘引擎、批处理工具都 `dofile` 它，配置表在加载时把解析结果写进
`config.profile` / `config.profile_source`（与运行模式同一写法，见第 13 节）。

| payload profile | 介质 | 写盘事务 | 卡密额度 | 每盘字节预算 | payload 子树 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| `default` | 任意 | 1 | 站端 `default_uses`（2） | 无 | `/payload` 本身 | 兼容档：未指定 profile 时的行为 |
| `pyromputer-os` | 两张软盘（part1 + part2） | 2 次（一张盘一次事务） | `default_uses = 2` | 1,228,800 B | `/payload/part1`、`/payload/part2` | 定案（数字见第 1 节） |
| `pyroet-os` | 单张软盘（裁剪后 ≤1,228,800 B 才成立） | 1 次 | `default_uses = 1` | 1,228,800 B | `/payload` 本身 | 容量门已落代码，数字待裁剪后复核 |

- **这些数字是默认值，不是策略。** 配置键 `profile_capacity = { ["pyroet-os"] = N }` 按 profile 覆盖
  每盘预算（`disk_writer.cfg()` 每次写盘重读），所以换介质或改裁剪目标不用改代码。这条落实了
  §2 原来那句"容量预算因此是发卡/部署侧决策，不是代码常量"——代码只提供默认值与强制检查。
  `disk_writer` 仍然不写死容量：`diskSpace()`（`itn-pass/server/system/disk_writer.lua`）先问
  `disk.getDiskSpaceTotal/Used`，回退 `fs.getFreeSpace(mount)`；profile 预算是**在上面再加一道**字节
  上限，而不是替代剩余空间检查。
- **解析优先级**（与运行模式完全一致）：`/auth/itnpass_profile.txt` > 配置 `profile` > 内置
  `"default"`。非法覆盖文件记 `ITNP_PROFILE_BAD` 并保持配置值；非法配置值记
  `ITNP_CONFIG_BAD key=profile` 并 fail-safe 到 `default`；两者都写 `/auth/itnpass_profile.log`。
  名字区分大小写、只认小写目录键，所以拼错永远落到"被拒绝"而不是"写错盘"。
- **未指定 profile 时保持旧行为**：请求不带 `profile`、调用方用旧的
  `disk_writer.write()` / `store.mint(count, uses, note)` 三参形态时，服务按站端配置（默认
  `"default"`）处理，写盘引擎写 `/payload` 根、不做 profile 字节预算，卡不绑定 profile。
  旧库（记录里没有 `profile` 字段）读出来就是"不绑定"，任何 profile 都能用。
- **part 选择**（`pyromputer-os`）：显式 `part` 优先；不带时按盘上实际存在的子树判断——只有一个
  part 目录就用它（写第二张盘的操作方式：换 payload、重启），一个都没有就按 part1 写 `/payload`
  本身（操作员把那一半直接换进 `/payload`），两个都在则拒绝 `part required`。规则写死"猜错会写错
  盘"的方向：宁可拒绝也不替操作员选。
- **扣次按 profile 计额度**：批处理 `new --profile NAME` 把新记录绑定到该 profile（store 记录新增
  追加字段 `profile`），一张卡的次数只能花在对应 profile 的写盘上，跨 profile 得到
  `profile mismatch` 且不扣次。`store.stats()` 新增 `profiles`（按 profile 的 total/remaining/held）
  与 `unbound`（不绑定记录数），给运维核对"每种 payload 还能装几张盘"。
- **预检在预留之前**：profile 未知、part 不合法、payload 超过预算这三类拒绝都发生在 `store.reserve`
  之前，也不调用 `disk_writer` 的写盘事务，所以既不产生预留也不扣次（`t_profile.lua` 断言了
  "拒绝后 uses_left 不变、writer.write 零调用"）。超预算不算认证失败，不累计限流计数。
- `default_uses = 2` 出处：`itn-pass/server/auth/itnpass_config.lua`（管理台缺省值读同一个键）；
  一次成功写盘扣 1（`itnpass_store.lua` 的 `M.commit`），所以一张卡密 = 2 次写盘 =
  pyromputer-os profile 的两张盘；`pyroet-os` 目录写 `default_uses = 1`（单盘单次）。
- `pyroet-os` 的达标线仍写死为"裁剪后 ≤ 1,228,800 B"：达标即单盘、单次写盘；不达标就退化成两盘、
  `default_uses = 2`。容量门已由 profile 预算强制，具体裁剪数字仍等 Pyroet OS 测量后回填。

## 3. 协议与频道

- 协议名：**`itnpass_v1`**。
- 频道：**33**。
- **单一来源（B3）**：协议名与频道只在 `itn-pass/common/itnpass_net.lua` 里写一次
  （`PROTOCOL = "itnpass_v1"` / `CHANNEL  = 33`）。站端配置表
  `itn-pass/server/auth/itnpass_config.lua:17-18` 用 `dofile("/itnpass_net.lua")` 的
  `net.CHANNEL` / `net.PROTOCOL` 填 `channel` / `protocol`；终端两处读同一个文件
  （`itn-pass/terminal/system/netcheck.lua:11-12`、
  `itn-pass/terminal/auth/itnpass_client.lua:12-13`）。三处不再各写一个数字，改频道只需要改一个文件。
  `itnpass_net.lua` 里 `CHANNEL` 与 `=` 之间是两个空格（字段名对齐），所以
  `grep "CHANNEL = 3"` 不会把正确的 `33` 误报成旧值。
- **部署（B3 新增文件）**：`itn-pass/common/itnpass_net.lua` → `/itnpass_net.lua`，与 `/sha256.lua`
  同级；站端与终端都必须放，缺了它 `itnpass_config.lua` 直接加载失败（服务写 fault flag）。
  离线套件 `itn-pass/tests/run-tests.ps1` 的 staging 表已加上这一条。
- 1/2 已被 Sentinel 占用，不能再选：
  - 频道 1：`sentinel/auth_server/system/auth_server.lua:20`（`CHANNEL = 1`）、
    `sentinel/terminal/auth/login_client.lua:26`（`AUTH_CHANNEL = 1`）；
  - 频道 2：`sentinel/audit_server/system/audit_server.lua:17`（`main_channel = 2`）、
    `sentinel/terminal/system/audit.lua:12`（`AUDIT_CHANNEL = 2`）。
- **B1 冻结、B3 已完成**：B1 时代码仍是 `cardkey_v1` / 频道 3；B3 已切到最终值，实测
  `grep -rn "cardkey_v1\|CHANNEL = 3\|channel = 3" itn-pass --include=*.lua` 为空。

## 4. 已知接受风险：卡密明文走广播总线

- 风险：终端把卡密明文放进 modem 请求直接广播（请求表 `code = code` 见
  `itn-pass/terminal/auth/itnpass_client.lua:117-124`，发送见 `:133`）；服务端回包同样是无目的地址的
  广播（`itn-pass/server/system/itnpass_server.lua:494-495`）。**同一条网线上的任何 CC 电脑都能嗅探到
  卡密。**
- 为什么接受：卡密不是身份凭据，只是一次性安装额度；嗅探者仍要抢在合法终端之前用掉，收益有限。
- 缓解（已在代码里，B1 未改行为）：
  1. **写盘额度**：每成功写盘扣 1，用完即废（`itn-pass/server/auth/itnpass_store.lua:426-452`，
     扣次在 `:449`）；
  2. **预留有效期**：`reservation_ttl_ms = 300000`（5 分钟，`itn-pass/server/auth/itnpass_config.lua:27`；
     读取处 `itn-pass/server/auth/itnpass_store.lua:392`），预留过期自动回收；
  3. **管理台撤销/恢复**：`itn-pass/server/auth/itnpass_store.lua:701`（`M.revoke`）、`:743`
     （`M.unrevoke`），入口 `itn-pass/server/system/itnpass_admin.lua:197-198`。
- 边界（写清楚，免得被读成"卡密会过期"）：**卡密本身目前没有独立的到期时间**，只有"预留 5 分钟内
  要写完"。真要做"有效期"就得给记录加时间字段（后续批次候选），本文件不假装已有。

## 5. 不引入 PSK 挑战应答

PSK 签名/验签是 Sentinel 的认证范畴（`sentinel/terminal/auth/psk.lua:1-4`，签名原语
`sha256(key .. "|" .. data)`；`sentinel/README.md:36`），本版 ITN Pass **不做**：

- 不复制 `/auth/psk.lua`、不引入 `/auth/psk.txt`；
- 不做服务端 nonce 挑战 + 客户端签名；
- 卡密在总线上就是明文（第 4 节）。
- 将来若必须防嗅探，方向是"服务端一次性授权 + 写盘额度绑定"，而不是给 itn-pass 引入 Sentinel 的 PSK。

## 6. 与 pyromputer-os 的关系

- **独立项目，不 vendored rpv**：itn-pass 不复制 `pyromputer-os/` 的 rpv 网络栈，全链路只用
  modem + drive 两类外设——终端侧 modem（`itn-pass/terminal/system/netcheck.lua`、
  `itn-pass/terminal/auth/itnpass_client.lua`），服务端 drive/disk
  （`itn-pass/server/system/disk_writer.lua:97-139`）。`itn-pass/` 里没有 `rpv/` 目录，也没有任何
  rpv 模块。
- 装机盘里装的是"用户自己的 payload"（任意文件树），验证机只负责逐字节复制，不解释 payload。
  所以 itn-pass 与 Pyromputer OS / Pyroet OS 之间没有代码级耦合，只有"payload 大小"这一层预算耦合
  （第 1、2 节）。

## 7. 迁移规矩

- **本 fork 与原 `cardkey/` 不合并、不回灌。** 原 `cardkey/` 一个字节都不许改（B1 实测
  `git status --porcelain cardkey` 为空）；itn-pass 的修复也不许反向打补丁到 cardkey。
- 需要 cardkey 侧的行为改动时，在 itn-pass 里重新实现，不从 cardkey 拉分支、不做 cherry-pick。
- 运行时持久化路径全部加 `itnpass_` 前缀（B1 已完成），两套系统即使同机部署也不会互相踩
  pepper / 数据库 / 日志：

| 原路径（cardkey） | 新路径（itn-pass） | 常量位置 |
| --- | --- | --- |
| `/auth/cardkey_pepper.txt` | `/auth/itnpass_pepper.txt` | `itn-pass/server/auth/itnpass_store.lua:14` |
| `/auth/cardkeys.db` | `/auth/itnpass_passes.db` | `itn-pass/server/auth/itnpass_store.lua:15` |
| `/auth/cardkey_server_id` | `/auth/itnpass_station_id` | `itn-pass/server/system/itnpass_server.lua:16` |
| `/auth/cardkey_server.log` | `/auth/itnpass_server.log` | `itn-pass/server/system/itnpass_server.lua:14` |
| `/auth/cardkey_fault.flag` | `/auth/itnpass_fault.flag` | `itn-pass/server/system/itnpass_server.lua:15` |
| `/auth/admin.db` | `/auth/itnpass_admin.db` | `itn-pass/server/auth/itnpass_config.lua:21`（`admin_file`）、`itn-pass/server/system/itnpass_admin.lua:14`（缺省值） |
| `/lock.flag` | `/auth/itnpass_lock.flag` | `itn-pass/terminal/startup.lua:17`（写）、`:32-33`（查/删） |

- 锁死文件从根目录挪到 `/auth/` 的部署前提：终端盘上必须有 `/auth/` 目录。按文档部署时必然存在
  （客户端模块就装在 `/auth/`）；只手工拷一个启动脚本的极端部署会写不进锁死标志（后续批次若在意，
  可就地 `fs.makeDir("/auth")`）。

## 8. 外部/悬空引用与未同步文档（只记录，不顺手改）

- **悬空引用**：`itn-pass/terminal/auth/itnpass_client.lua:18`（原
  `cardkey/terminal/auth/cardkey_client.lua:16`）注释写 "(see DECISIONS.md)"，但 `cardkey/` 下没有
  DECISIONS.md。本文件就是它指向的文档；原 cardkey 侧按"零改动"规矩不修。
- `itn-pass/README.md` 在 B1 时是 `cardkey/README.md` 的原样拷贝；**B6 已按 ITN-Pass 的实际行为
  全量重写**（中文，含部署布局、协议/频道、扣次语义、`ITNP_*` 日志、测试基线、构建发布、安全风险与
  运维）。B1 记录的旧路径问题（`:119-140` 部署表、`:152-154` 持久化文件、`:551-575` 配置参考、
  `:711-767` 文件清单与部署步骤）随重写一并消失。
- ~~`itn-pass/README.md:744` 说锁死文件在根 `/lock.flag`~~：B6 重写后统一写 `/auth/itnpass_lock.flag`。
- `tools/build_release.py` 的 `VERSIONS` 已加 `"itn-pass": "1.0.0"`（`:19`），产物名机制见 `:38`；
  `.github/` 的 CI 已在 B6 接上 itn-pass（dispatch options、tag 名单、分支构建循环、`case` 分派）。
- 根 `README.md` 的项目表 / 构建命令表 / tag 名单已在 B6 加入 itn-pass。
- **B3 已改**：`itn-pass/common/sha256.lua:4-5`、`itn-pass/terminal/startup.lua:1` 等处的 "CardKey"
  品牌注释全部换成 "ITN-Pass"（注释，不改行为）；`grep -rn "CardKey\|Card Key" itn-pass --include=*.lua`
  现在为空。大写品牌只剩本文件与 README 的叙述性引用（README 已在 B6 重写）。
- 新的共享常量文件 `itn-pass/common/itnpass_net.lua` 需要部署成 `/itnpass_net.lua`，B6 已在
  README 的部署表与文件清单里补上这一条。

## 8.1 README 与文档同步（B6 完成）

- `itn-pass/README.md` 全量重写为 16 节：定位与角色、部署布局（站端/终端两张盘）、协议与频道
  （`itnpass_v1` / 33 / `netcheck` 唯一站端判定）、扣次语义、格式与密码学（含 `"|cardkey|"` 盐
  不可改）、写盘规则、终端界面、管理台、配置参考、运维（`ITNP_*` 日志与 `.corrupt-*` 保留策略）、
  故障排查、安全说明、离线测试（基线 702/0/40）、构建与发布、文件清单、部署顺序清单。
- 界面字面量按源码照抄：`InterTeamNet Access` / `ITN-Pass Disk Writer` / `ITN-Pass Station` /
  `# ITN-Pass batch`；`netcheck` 的 `no card key server detected` 是未改名的代码字面量，README
  照抄并在 3.2 注明了这一点。

## 9. B1 保留的非路径功能字符串（B3 逐项定案）

这些字符串不是文件/路径名，改动会改变行为；B1 一个都没动，B3 按下面逐项处理：

- **协议名**：B1 冻结 `cardkey_v1`，**B3 改成 `itnpass_v1`**；**频道** 3 → **33**。两值现在只在
  `itn-pass/common/itnpass_net.lua` 写一次（第 3 节），站端配置与终端两处都从它读。
- **指纹域分隔符 `"|cardkey|"`**（`itn-pass/server/auth/itnpass_store.lua:260`）：**B3 仍未改**。它参与
  `sha256(pepper|cardkey|label)` 的卡密派生，改了会让同一 pepper 派生出不同卡密、已入库指纹全部失配
  （已发出的卡密全部失效）。将来若要改，必须与"换库/重发卡"一起宣布。
- **导出口录 `/cardkeys` 与文件名 `cardkeys_<stamp>.txt`**（`itn-pass/server/auth/itnpass_store.lua:625-633`，
  配置键 `export_dir` 在 `itn-pass/server/auth/itnpass_config.lua:22`）：**B3 保留**（运维脚本与已拷出的
  批次文件都依赖这两个名字；它们不是品牌文案）。
- **导出文件头**：B1 保留 `# CardKey batch`（`itn-pass/server/auth/itnpass_store.lua:586`），**B3 改成
  `# ITN-Pass batch`**。它只是 `#` 开头的注释行，解析侧只看能被 `normalize` 认出的卡密行，旧批次文件
  照旧可读；`itn-pass/tests/t_store.lua` 的 `store.export_header` 期望同步改了值。
- **会话显示名 `name = "cardkey"`**（`itn-pass/terminal/auth/itnpass_login.lua:35`）：**B3 保留**（内部标识，
  UI 不显示；改了只会让代码里的会话名与路径前缀对不上，没有收益）。

## 10. 发布与构建

- `tools/build_release.py:19` 的 `VERSIONS` 新增 `"itn-pass": "1.0.0"`。它同时驱动 `--project` 的
  合法值（`:53`，`choices=sorted(VERSIONS)`）与产物名（`:38`，`<project>-v<version>.zip`）。
- 构建命令（仓库根）：`python tools/build_release.py --project itn-pass --out dist/release`
  → `dist/release/itn-pass-v1.0.0.zip`（`dist/` 在 `.gitignore` 里，不入库）。
- 版本口径：itn-pass 从 `1.0.0` 起，与 cardkey 的 `2.0.0` 分开走，互不影响。
- B3 构建：`dist/release/itn-pass-v1.0.0.zip` 当时有 **31 个成员**（B1 是 18：15 个 lua + README +
  DECISIONS + LICENSE；B3 加入 `tests/` 的 11 个 lua + `run-tests.ps1`，以及新的
  `common/itnpass_net.lua`，18 + 12 + 1 = 31）。字节数与 sha256 不写进这里：本文件自己也进包，
  记一个数字会让文档自身变成下一次构建的差异源；精确值看当次 `build_release.py` 的输出。

### 10.1 发布包内容口径（B6 定案：不放 `tests/`）

发布 zip **只放运行时 + 文档 + 许可证**，明确**不包含 `tests/`**：

```
itn-pass/   19 个 lua（common/ server/ terminal/）
itn-pass/README.md
itn-pass/DECISIONS.md
itn-pass/docs/DISTRIBUTION.md
itn-pass/INSTALL.txt
LICENSE     （仓库根，zip 根目录）
```

- 理由：`tests/` 是开发材料（T3 后 14 个文件、5,330 行、解包 221,455 B；P1 后 15 个文件、6,155 行），
  解包到访客盘上既占空间又没有可用性——`run-tests.ps1` 依赖 Windows +
  `C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe`，在真实终端/站端上直接跑必然报错。
- 实现：`tools/build_release.py` 的 `EXCLUDE_FROM_RELEASE = {"itn-pass": ("tests/",)}`，在 `build()`
  里按"项目 → 相对路径前缀元组"过滤成员，**只对 itn-pass 生效**。`sentinel/` 也有 `tests/`，
  它的包照旧包含测试（不做全局排除，否则会改变 sentinel 现有产物的字节）。实测用 `git show
  HEAD:tools/build_release.py` 旧脚本与当前脚本各构建一遍 sentinel/cardkey/pylib：三份 sha256 完全
  相同，sentinel 包仍含 `sentinel/tests/`。
- 结论：N2 之后 33 → **20 个成员**（N2 时是 17 lua + README + DECISIONS + LICENSE），压缩后体积
  85,517 B → 约 60 KB。精确字节不写死：README 与本文件自己也在包内，记一个数字会让文档自身
  变成下一次构建的差异源。
- T3 追加：`/system/itnpass_batch.lua` 进包（18 个 lua / 22 个成员），新增的
  `itn-pass/docs/DISTRIBUTION.md` **也进包**。理由：它是运维文档，README 8.6 直接引用它，
  不放进去就会出现"包里的 README 让读者去看一个包内不存在的文件"。与 `tests/` 的区别是
  "文档有用、测试没用且跑不起来"，所以 `EXCLUDE_FROM_RELEASE` 仍然只排除 `tests/`，
  `docs/` 靠"不排除"自动进包，**构建脚本一行都不用改**（改脚本会影响其它项目的产物字节）。
- T4（2026-11-01）：新增 `itn-pass/INSTALL.txt`（**纯 ASCII 英文**装机速查：两张部署表、硬件两条网、
  首次开机建密码、`pass`/`free` 切换、期望日志、常见故障文案、构建/测试命令）。成员 22 → **23**。
  与 README 的分工：README 是中文手册（协议、账本、管理台、批次流程），INSTALL.txt 是"在游戏里
  贴盘时照着抄"的一页纸，所以它必须 ASCII——原版 CC 字体在没有字库介质时显示不了中文。
  同样靠"不排除"进包，`build_release.py` 零改动。
- P1（payload profile）：新增 `itn-pass/common/itnpass_profile.lua` 进包（19 个 lua / **24 个成员**）。
  它靠"不排除"自动进包，构建脚本零改动；发布包成员数只写稳定事实（成员集合），字节与 sha256
  仍以构建输出为准（自指规则）。

## 11. B1 变更清单（骨架事实）

- 复制：`cardkey/` → `itn-pass/`（保留全部子目录结构），原目录零改动。
- 改名 6 个文件：`cardkey_config.lua → itnpass_config.lua`、`cardkey_store.lua → itnpass_store.lua`、
  `cardkey_server.lua → itnpass_server.lua`、`cardkey_admin.lua → itnpass_admin.lua`、
  `cardkey_client.lua → itnpass_client.lua`、`cardkey_login.lua → itnpass_login.lua`。
- 内容同步：11 个 lua 文件共 40 处字符串替换（dofile / os.run / 路径常量 / 部署注释），行为零变化。
- B1 实测：`grep -rn "cardkey_" itn-pass --include=*.lua` 只剩协议名 `cardkey_v1`（路径与文件名已清零）；
  B3 之后该 grep 只剩指纹盐 `"|cardkey|"` 一处（第 9 节），协议名已清零。
- 全部 lua 纯 ASCII（无 >127 字节）；`itn-pass/tests/run-tests.ps1` 每次运行都重查整棵 `itn-pass/`
  的 `.lua`/`.ps1`。
- B1 未做（后续批次）：协议/频道切换（**B3 已完成**）、payload profile 的代码与发卡流程
  （**P1 已完成**，见第 2 节）、README/CI（**B6 已完成**）。

## 12. 服务端日志 tag（B3 统一为 `ITNP_*`）

`itn-pass/server/system/itnpass_server.lua` 的每一行日志都以 tag 开头，全部单行 ASCII、可 grep。
B3 给所有 tag 加 `ITNP_` 前缀，避免与 cardkey / Sentinel 的日志混在一起：

| B1 tag | B3 tag | 含义 |
| --- | --- | --- |
| `START` | `ITNP_START` | 服务启动（server_id、channel、可用卡密数） |
| `CHECK` | `ITNP_CHECK` | 验证通过（不扣次） |
| `DENY` | `ITNP_DENY` | 拒绝（坏码、重复 nonce、预留失败等） |
| `LOCKED` | `ITNP_LOCKED` | 终端锁定 / 全局锁定 |
| `GRANT` | `ITNP_GRANT` | 预留成功，开始写盘 |
| `WRITEFAIL` | `ITNP_WRITE_FAIL` | 写盘失败，预留已释放 |
| `WRITE!` | `ITNP_WRITE` | 写盘完成（文件/目录/字节统计） |
| `COMMIT!` | `ITNP_COMMIT` | 扣次提交完成 |
| `ERROR` | `ITNP_ERROR` | 内部错误 / fault flag（同一行也写进日志） |
| — | `ITNP_FREE_VERIFY` | `free` 模式验证直接放行（默认 `ITNP_FREE_VERIFY terminal=7 uses=none`） |
| — | `ITNP_FREE_WRITE` | `free` 模式写盘：`ok=1 files=.. dirs=.. bytes=..`，失败 `ok=0 reason=.. detail=..` |
| — | `ITNP_FREE_SESSION` | 终端侧写 `/auth/itnpass_mode.log`：跳过登录进菜单 |
| — | `ITNP_CONFIG_BAD` | `/auth/itnpass_mode.log`：配置 `mode` 非法，已按 `pass` 处理；`/auth/itnpass_profile.log`：配置 `profile` 非法，已按 `default` 处理 |
| — | `ITNP_MODE_BAD` | `/auth/itnpass_mode.log`：`/auth/itnpass_mode.txt` 非法，已忽略 |
| — | `ITNP_PROFILE_BAD` | `/auth/itnpass_profile.log`：`/auth/itnpass_profile.txt` 非法，已忽略并保持配置值（P1） |

运行模式诊断（`ITNP_FREE_SESSION` / `ITNP_CONFIG_BAD` / `ITNP_MODE_BAD`）写在单独的
`/auth/itnpass_mode.log`，不混进服务日志（终端也可能写，见第 13 节）。payload profile 的诊断
（`ITNP_PROFILE_BAD`、profile 版的 `ITNP_CONFIG_BAD`）同样单独一份 `/auth/itnpass_profile.log`。
P1 起服务日志的 `ITNP_START` / `ITNP_CHECK` / `ITNP_DENY` / `ITNP_GRANT` / `ITNP_WRITE` /
`ITNP_COMMIT` / `ITNP_FREE_VERIFY` / `ITNP_FREE_WRITE` 行末追加 `profile=`（写盘行还有 `part=`）；
全部是**追加**字段，B3/N2 的断言（`find` 前缀匹配）不需要改动。

- 测试期望同步换值：`itn-pass/tests/t_server.lua` 的 14 处日志断言（`log():find` / `text:find`），
  断言一条没删。
- `ITNP_WRITE` 与 `ITNP_WRITE_FAIL` 同前缀，grep `ITNP_WRITE` 会同时命中两者；按完整 tag 搜。
- `itnpass_store.lua:295` 的故障码 `STORE_DB_CORRUPT` **不加**前缀：它同时是 `store.faults()` 返回给
  调用方的故障码（`itn-pass/tests/t_store.lua:559` 直接断言这个值），只镜像进同一个日志文件，且本身
  已经不会与 cardkey / Sentinel 的 tag 撞名。
- 管理台不写日志文件（只打印屏幕），它的输出文案见第 9 节与 B3 报告，没有 tag。

## 13. 运行模式（N2：`pass` / `free`）

### 13.1 定位

itn-pass 是**装机/分发凭证**系统，不是网络准入系统：它只回答"这张盘能不能写、能写几次"。
**本项目不做入网许可、不做设备入网鉴权**；网络层只做连接（以及将来的加密），不做准入判定。
`pass`（默认，需要凭证）与 `free`（公开免费，不需要凭证）是同一个系统的两种运行形态，
不是两套产品。

### 13.2 解析优先级（三处读取方完全一致）

`itn-pass/common/itnpass_mode.lua`（部署为 `/itnpass_mode.lua`，站端与终端都必须放）是唯一解析器：

1. `/auth/itnpass_mode.txt` 存在且内容合法 → 用它（最高优先，"盘上切换"靠它）；
2. 否则用 `/auth/itnpass_config.lua` 的 `mode` 字段（默认 `"pass"`，配置表在加载时即调用解析器）；
3. 否则内置默认 `"pass"`。

读取方分别是：站端服务（`itnpass_server.lua` 的局部函数 `modeOf`）、终端 kernel 与 client
（`itnpass_mode.current()`）、管理台首页（`itnpass_admin.lua` 的 `modeText`）。

- 合法值是且只是小写字面量 `pass` / `free`；`parse()` 忽略空行与 `#` 注释，并要求整个文件只
  出现一个有效值（`pass` / `free` 两行冲突视为非法）。
- **fail-safe 规则**：配置值非法 → 记 `ITNP_CONFIG_BAD key=mode`（写 `/auth/itnpass_mode.log`）
  并按 `pass` 处理；覆盖文件非法 → 记 `ITNP_MODE_BAD` 并保持配置值。写错的唯一后果是继续收费，
  不会误放开。
- 模式在启动时解析一次，改文件必须重启站端/终端才生效。

### 13.3 free 模式只影响"是否需要凭证"

| 环节 | `pass` | `free` |
| --- | --- | --- |
| 终端登录 | 凭证输入界面 | 跳过；合成身份 `name="guest"`、`code=""`、无次数；日志 `ITNP_FREE_SESSION` |
| `verify_request` | `store.lookup` + 失败计数/锁 | 直接成功，**不碰 store**；回 `free=true`、`mode="free"`，省略 `uses_left`/`uses_total` |
| `write_request` | reserve → write → commit/release，扣 1 次 | **跳过 reserve/commit/release 与扣次**；仍走完整 `disk_writer` 事务 |
| 写盘校验 / 失败回滚 / 空间预检 | 照旧 | **照旧** |
| `netcheck` | 开机检查，失败锁死 | **照旧**（盘仍由站端写，必须先连通） |
| 管理台首页 | `MODE: pass` | `MODE: free` |
| 服务日志 | `ITNP_CHECK` / `ITNP_GRANT` / `ITNP_WRITE` / `ITNP_COMMIT` | `ITNP_FREE_VERIFY` / `ITNP_FREE_WRITE ok=.. files=.. bytes=..` |

**free 模式不扣次**是设计结论，不是实现巧合：没有库记录可扣，也没有"额度"这个概念；
`reservation_id` 仍然必须存在，只是不再对应任何预留记录。

### 13.4 两端必须一致

站端 `pass` + 终端 `free`：终端发空 `code`，站端回 `empty code`，写盘失败且不扣次（盘不受影响）。
站端 `free` + 终端 `pass`：终端照旧先要凭证，站端不查库直接放行。切换步骤见 README 2.5。

### 13.5 为什么默认是 `pass`

`free` 等于"任何能连到网络 A 的终端都能无限写盘"，没有身份、没有配额。默认值选 `pass`，让
"忘记配置/配置写坏"的结果停留在保守的一侧，而不是把站端变成公共写盘机。

## 14. 批处理工具（T3：脚本化入口与存储边界）

### 14.1 定位

管理台（README 8）是给人手点的；`/system/itnpass_batch.lua` 是**同一套库的命令行入口**：
`new` / `list` / `export` / `revoke` / `unrevoke` / `prune`，一条命令一次执行，输出
"每项一行 JSON-ish + 最后一行 ASCII 摘要"（`ITNP_BATCH <命令> count=.. ok=..`），便于脚本消费。
它不参与开机（`/startup.lua` 不加载它）、不监听网络、不读运行模式；屏幕被服务占着时按两次
`Ctrl+T` 回 shell 再跑（README 10.7）。

### 14.2 工具与存储的边界（唯一的数据入口是 store）

- 工具只调用 `/auth/itnpass_store.lua` 的 `mint` / `commitBatch` / `export` / `list` / `stats` /
  `revoke` / `unrevoke` / `prune`；**从不打开 `/auth/itnpass_passes.db`、从不自己派生卡密、
  从不自己算指纹**。改 pepper 盐、改指纹算法、改预留语义只改 store 一处，工具的每条命令天然
  获得与站端服务相同的语义（`t_batch.lua` 的 `batch.consistency` 组就是用来钉这一点的）。
- 反过来的约束：**工具不能提供 store 没有的能力**。三个直接后果：
  1. `unrevoke` 只能按完整卡密恢复（`store.unrevoke(code)` 的签名如此，README 8.5 也这么写）。
     按 ID 恢复意味着要把明文存进库，等于放弃"库泄露 != 卡密泄露"这条性质（第 4 节接受风险的
     缓解层之一）。所以本工具对 ID 输入直接返回 `error=needs_full_key`，**不是**绕过 store 去
     直接改写库文件。任务书里写的 `unrevoke <id-prefix>` 因此实现为"完整卡密"语义 —— 这是唯一
     与任务书字面不同的地方，理由是它需要动 store 源码才能做到，而 T3 的边界不允许改 store。
  2. `--expires` 无法由站端自己判断：`lookup` 只认 `revoked` 与 `uses_left`，没有日期判断。
     因此到期被实现为"把到期时间记进备注 + `prune` 时把到期证 `revoke` 掉"，即**到期是运维动作，
     不是站端运行时判定**。想当硬门禁就必须把 `prune` 排进日常维护（DISTRIBUTION 6.3）。
     文档里反复写这一条，因为"设了 30 天就自动失效"是最容易误读的期待。
  3. 批次元数据（batch / profile / prefix / uses / expires）只能进 `note` 字段——store 的公开接口
     只有 `mint(count, uses, note[, profile])`。好处：**数据库结构零改动**，老版本读到只是一条普通
     备注；代价：`note` 是自由文本，工具只认自己写的 `itnp-batch/1 ...` 前缀，管理台手写的备注按
     "无元数据"处理（profile 空、expires=0），不会被误当成批次记录。
     **P1 的补充**：P1 给 `mint` 加了可选第 4 个参数 `profile`，它写的是记录上的**绑定字段**
     （`rec.profile`），不是元数据——元数据仍只在 `note` 里。两者分工：`note` 记录"这批是谁发的、
     什么时候到期"，`rec.profile` 决定"这张卡的次数能花在哪种 payload 上"（第 2 节）。三参调用
     （管理台、旧脚本）不写绑定字段，因此产出的卡任何 profile 都能用，与 T3 时代的行为一致。

### 14.3 为什么不打印完整卡密

明文只存在两个瞬间：`new` 进程的内存里，和它写出的 staging 文件里。屏幕会留下更多痕迹
（旁边的人、截图、shell 的复制粘贴），所以：

- `new` 只打印 `id`（12 位指纹前缀）与 `fp6`（前 6 位）；
- `export --out PATH` 是**唯一**写出分发文件的命令，`PATH` 必须显式给出（缺了就是
  `error=no_out`），没有"默认写到固定位置"的方便路径；
- `revoke` 即使接受完整卡密，回显也换成该证的 12 位 ID（`t_batch.lua` 的
  `batch.revoke_full_key_masked` / `*.no_plaintext*` 断言钉住）；
- 日志行只写 ID（`target=` / `id=`）。

已知副作用（接受）：`new` 之后必须 `export` 才能拿到明文；staging 写失败时整批**不入库**
（明文与库保持"要么都有、要么都没有"）。staging 路径是
`<export_dir>/.stage/<批次 ID>.txt`（默认 `/cardkeys/.stage/`），刻意与管理台的
`cardkeys_*.txt`/`latest.txt` 分开。

### 14.4 `revoke` 的 `--yes` 与 `prune` 的删除策略

- `revoke` 没有 `--yes` 就是 `ok=0 error=confirmation_required`，库零改动，但**仍然留一行日志**。
  理由：撤销不可逆（明文已删、次数不回收），防误触的价值高于少敲一次；失败尝试也要可审计。
- `prune` 三件事，全部经 store：①清过期预留（`store.prune`）；②撤销 `expires` 已过的证；
  ③删除"整批已死"（本批所有记录都已撤销/到期）的 staging 文件。
  **孤儿 staging 保留**：找不到对应库记录的 staging 文件可能是库损坏后唯一的明文副本，
  静默删除的代价高于留一份明文。`count` 报告实际改动数，便于对账。

### 14.5 与 `free` 模式的关系

`free` 下 `new`/`export` 照常工作（库照写），但站端不查库，卡密在 free 期间**没有约束力**；
切回 `pass` 后它们立刻恢复有效。所以 free 期间发出的批次要么缩短 `--expires` 并跑 `prune`，
要么事后 `revoke`。工具本身不读 `/itnpass_mode.lua`：生成与否是人的决定，约束力是站端的决定，
让工具"以为自己处于 free 就不生成记录"只会制造半自动状态。

### 14.6 测试

`tests/t_batch.lua`：**289 断言 / 13 组**（离线 702/0/40 → **991/0/53**）。覆盖参数解析与边界、
`note` 往返、状态优先级、`new` 默认/自定义/越界（count/uses/expires/profile/prefix、配置
`max_batch` 与 `default_uses`）、staging 写失败时不入库、`list` 四种过滤、`export` 的路径与内容
（字节回读、staging 清理、多批次歧义、`--batch`、`--keep`、目录/同路径/空批次）、`revoke` 的
`--yes` 与失败原因、`unrevoke` 的完整卡密规则、`prune` 三类清理与孤儿保留、坏库（
`STORE_DB_CORRUPT` 仍在、`.corrupt-*` 保留）、store 缺失时的 `store_unavailable`、日志关键字、
以及与 store 扣次语义一致（`new` 不扣次、`commit` 扣 1、用完 `used up`）。

P1 起同一套件新增 `tests/t_profile.lua`：**186 断言 / 7 组**（离线 991/0/53 → **1177/0/60**）。
覆盖 profile 目录与 `parse`/`capacity`/`default_uses`、三档解析优先级与两种非法值的 fail-safe 与
日志、store 的按 profile 计额度（绑定/不匹配/commit 复核/`stats().profiles`/`unbound`）、**旧库
兼容**（手工写一份没有 `profile` 字段的记录再重新加载 store，三种口径都能读能用）、写盘引擎的
part 自动识别与显式 part、字节预算拒绝且不碰盘、旧调用形态 `write()` 仍然写 `/payload` 根并回
`profile=nil`、站端 verify/write 的 profile 与 part 贯通（未知 profile / 超预算在预留之前拒绝、
不扣次、`writer.write` 零调用）、`free` 模式同样校验 profile、批处理的 `--profile` 校验、默认次数与
记录绑定。

## 15. 修订记录

| 批次 | 变更 |
| --- | --- |
| B1 | 从 `cardkey/` 硬分支出 `itn-pass/`：6 个文件改名、运行时路径加 `itnpass_` 前缀、行为零变化；本文件建立。 |
| B3 | 协议 `itnpass_v1` / 频道 33 收敛到 `common/itnpass_net.lua`（新文件，部署为 `/itnpass_net.lua`）；服务端日志 tag 统一 `ITNP_*`（第 12 节）；界面标题改 `ITN-Pass Disk Writer` / `InterTeamNet Access` / `ITN-Pass Station`；导出头改 `# ITN-Pass batch`；本文件的行号引用按当前工作树刷新。 |
| B6 | README 全量重写（16 节，中文，覆盖两条盘的部署布局、协议与 `netcheck` 判定、扣次语义、`ITNP_*` 日志、`.corrupt-*` 保留策略、离线测试 488/0/29、构建发布与安全风险）；发布包**排除 `tests/`**（`build_release.py` 的 `EXCLUDE_FROM_RELEASE`，仅 itn-pass 生效，31→19 成员，见 §10.1）；CI 接 itn-pass（dispatch options / tag 名单 / 分支循环 / `case` 分派）；根 `README.md` 三处同步。 |
| N2 | 新增 `common/itnpass_mode.lua`（部署 `/itnpass_mode.lua`）+ 配置键 `mode`（默认 `"pass"`），解析优先级 = `/auth/itnpass_mode.txt` > 配置 > 默认，非法值 **fail-safe 到 `pass`**（日志 `ITNP_CONFIG_BAD` / `ITNP_MODE_BAD`，写 `/auth/itnpass_mode.log`）；`free` 模式：终端 kernel 跳过登录（合成 `guest`、`ITNP_FREE_SESSION`）、client 允许空 `code`、服务端 `verify` 不查库、`write` 不预留不扣次但照走 `disk_writer`（`ITNP_FREE_WRITE ok=.. files=.. bytes=..`）、管理台首页加 `MODE: pass` 与 `MODE: free`；写盘校验/回滚/空间预检/`netcheck` 在两种模式下完全一致（见 §13）。README 措辞统一改为"装机/分发凭证"（37 处词替换，不再出现旧称）；新增 2.5 运行模式一节；新增 `tests/t_mode.lua`（214 断言 / 11 组，离线 488/0/29 → **702/0/40**），`run-tests.ps1` 多 stage `/itnpass_mode.lua` 与 `tests/terminal_startup.lua`。 |
| T3 | 新增 `/system/itnpass_batch.lua`（命令行批处理：`new <count> [--uses N] [--prefix P] [--profile NAME] [--expires DAYS]`、`list [--status ...]`、`export --out PATH [--batch ID] [--keep]`、`revoke <id-prefix|完整卡密> --yes`、`unrevoke <完整卡密>`、`prune`；一行摘要 + 每项一行 JSON-ish；明文只落 `<export_dir>/.stage/`，导出后默认删除；**不打印完整卡密**；每次执行一行 `ITNP_BATCH ...` 进 `/auth/itnpass_server.log`；全部数据操作经 store，见 §14）；新增 `docs/DISTRIBUTION.md`（批次生成/导出/带出站端/模式关系/到期与撤销/三条示例/故障表）；README 新增 8.6 批处理工具小节，同步 §10.1 日志表、§12 安全风险第 14 条、§13 基线、§14 发布包口径（18 lua / 22 成员 / `docs/` 进包）、§15 文件清单、§16 部署清单；新增 `tests/t_batch.lua`（289 断言 / 13 组，离线 702/0/40 → **991/0/53**），`run-tests.ps1` 多 stage `/system/itnpass_batch.lua`。 |
| P1 | payload profile 从文档口径变成代码：新增 `common/itnpass_profile.lua`（部署 `/itnpass_profile.lua`，目录含 `default` / `pyroet-os` / `pyromputer-os`：介质、写盘事务数、每盘字节预算、payload 子树、默认卡密次数），解析优先级 = `/auth/itnpass_profile.txt` > 配置 `profile` > `default`（非法值 fail-safe 到 `default`，日志 `ITNP_PROFILE_BAD` / `ITNP_CONFIG_BAD key=profile` 写 `/auth/itnpass_profile.log`）；配置新增 `profile`、`profile_capacity`（按 profile 覆盖预算）；`disk_writer` 新增 `plan()`，`write([profile[, part]])` 按 profile 选 payload 子树（多 part 时显式 part 优先、按盘上现有子树自动识别、两个都在则拒绝 `part required`）并做字节预算预检（超预算 `payload too large`，不碰磁盘）；`store` 的 `mint` 增加可选第 4 参 `profile` 写绑定字段，`lookup`/`reserve`/`commit` 增加可选 profile 参数做绑定校验（不匹配 `profile mismatch`，不扣次），`stats()` 增加 `profiles`/`unbound`；站端 verify/write 贯通 `profile`/`part`（未知 profile、part 不合法、超预算都在预留之前拒绝，回包与 `ITNP_*` 日志追加 `profile=` / `part=`），`free` 模式同样校验；批处理 `new --profile` 只接受目录内的名字，省略时用配置 `profile`，省略 `--uses` 时用 profile 的默认次数，并把绑定写进记录（note 元数据口径不变，见 §14.2 补充）；`run-tests.ps1` 多 stage `/itnpass_profile.lua`；新增 `tests/t_profile.lua`（186 断言 / 7 组，离线 991/0/53 → **1177/0/60**）；README 新增 2.6、同步 1.3/2.1/4.4/5.5/6/8.6/9/10.1/11/13/14/15/16；发布包成员 23 → 24（19 lua）。 |
