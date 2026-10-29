# ITN Pass 决策记录（itn-pass）

`itn-pass/` 是 `cardkey/` 的**硬分支**：把卡密验证机改造成 InterTeamNet 公网访客准入证 + 装机盘。
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

验证机把 `/payload` 复制到软盘（`itn-pass/server/auth/itnpass_config.lua:15` 的
`payload_dir = "/payload"`；读取处 `itn-pass/server/system/disk_writer.lua:208` 起），而 `/payload`
位于验证机自己的电脑盘上，同样受 1,000,000 B 限制。**1,395,385 B 的 pyromputer-os payload 放不进
验证机的电脑盘（超 395,385 B）。**

- 现状约束：磁盘引擎只接受恰好一个驱动器（`itn-pass/server/system/disk_writer.lua:122-126`，
  多于一个报 `too many drives`），所以不能"源盘放另一张软盘"。
- 可行路径（后续批次决定并落代码，本节只记录约束与候选）：
  1. 每次只把一半放进 `/payload`（781,380 B 或 614,005 B，都 < 1,000,000 B），写一张盘换一次内容；
     这与"两张盘两次写盘事务"天然对齐，代价是操作员要切两次 payload；
  2. 上调验证机的 `computer_space_limit`（Minecraft 服务端配置，不是本仓库代码）；
  3. 缩小 payload（即 `pyroet-os` profile 的动机）。
- 验证机自身代码只占 16 个 lua 共 86,918 B（B3 实测；B1 记录为 15 个 81,883 B，两个数字的测量
  口径没有可逐字节对账的基线——itn-pass 尚未入库），电脑盘剩余空间几乎全留给 `/payload`。

## 2. 装机盘决策：容量按 payload profile 分别定

**不做全局一刀切。** 每个 payload profile 有自己的介质数量、写盘事务数与卡密额度：

| payload profile | 介质 | 写盘事务 | 卡密额度 | 状态 |
| --- | --- | --- | --- | --- |
| `pyromputer-os` | 两张软盘（part1 + part2） | 2 次（一张盘一次事务） | `default_uses = 2` | 定案（数字见第 1 节） |
| `pyroet-os` | 单张软盘（裁剪后 ≤1,228,800 B 才成立） | 1 次 | 待测量后回填 | 待裁剪后测量 |

- `default_uses = 2` 出处：`itn-pass/server/auth/itnpass_config.lua:16`；管理台缺省值读同一个键
  （`itn-pass/server/system/itnpass_admin.lua:218`）。一次成功写盘扣 1
  （`itn-pass/server/auth/itnpass_store.lua:426-452` 的 `M.commit`，
  `rec.uses_left = rec.uses_left - 1` 在 `:449`），所以一张卡密 = 2 次写盘 = pyromputer-os
  profile 的两张盘。
- `pyroet-os`：Pyroet OS 是对 Pyromputer OS 大量删改的小型化硬分支（落点 `pyroet-os/`；本仓库目前
  还没有该目录）。达标线写死为"裁剪后 ≤ 1,228,800 B"：达标即单盘、单次写盘；不达标就退化成两盘、
  `default_uses = 2`。该行数字在裁剪完成并实测前**不填**。
- 写盘引擎不写死容量：`itn-pass/server/system/disk_writer.lua:97-114` 的 `diskSpace()` 先问
  `disk.getDiskSpaceTotal/Used`，回退 `fs.getFreeSpace(mount)`；容量预算因此是发卡/部署侧决策，
  不是代码常量。

## 3. 协议与频道

- 协议名：**`itnpass_v1`**。
- 频道：**33**。
- **单一来源（B3）**：协议名与频道只在 `itn-pass/common/itnpass_net.lua` 里写一次
  （`PROTOCOL = "itnpass_v1"` / `CHANNEL  = 33`）。站端配置表
  `itn-pass/server/auth/itnpass_config.lua:9-10` 用 `dofile("/itnpass_net.lua")` 的
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
  2. **预留有效期**：`reservation_ttl_ms = 300000`（5 分钟，`itn-pass/server/auth/itnpass_config.lua:19`；
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
| `/auth/admin.db` | `/auth/itnpass_admin.db` | `itn-pass/server/auth/itnpass_config.lua:13`（`admin_file`）、`itn-pass/server/system/itnpass_admin.lua:14`（缺省值） |
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
  故障排查、安全说明、离线测试（基线 488/0/29）、构建与发布、文件清单、部署顺序清单。
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
  配置键 `export_dir` 在 `itn-pass/server/auth/itnpass_config.lua:14`）：**B3 保留**（运维脚本与已拷出的
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
itn-pass/   16 个 lua（common/ server/ terminal/）
itn-pass/README.md
itn-pass/DECISIONS.md
LICENSE     （仓库根，zip 根目录）
```

- 理由：`tests/` 是开发材料（12 个文件、约 2,800 行、解包 125,572 B），解包到访客盘上既占
  空间又没有可用性——`run-tests.ps1` 依赖 Windows + `C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe`，
  在真实终端/站端上直接跑必然报错。
- 实现：`tools/build_release.py` 的 `EXCLUDE_FROM_RELEASE = {"itn-pass": ("tests/",)}`，在 `build()`
  里按"项目 → 相对路径前缀元组"过滤成员，**只对 itn-pass 生效**。`sentinel/` 也有 `tests/`，
  它的包照旧包含测试（不做全局排除，否则会改变 sentinel 现有产物的字节）。实测用 `git show
  HEAD:tools/build_release.py` 旧脚本与当前脚本各构建一遍 sentinel/cardkey/pylib：三份 sha256 完全
  相同，sentinel 包仍含 `sentinel/tests/`。
- 结论：B6 之后 31 → **19 个成员**（16 lua + README + DECISIONS + LICENSE），压缩后体积
  85,517 B → 约 60 KB。精确字节不写死：README 与本文件自己也在包内，记一个数字会让文档自身
  变成下一次构建的差异源。

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
- B1 未做（后续批次）：协议/频道切换（**B3 已完成**）、payload profile 的代码与发卡流程、README/CI（B6）。

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

- 测试期望同步换值：`itn-pass/tests/t_server.lua` 的 14 处日志断言（`log():find` / `text:find`），
  断言一条没删。
- `ITNP_WRITE` 与 `ITNP_WRITE_FAIL` 同前缀，grep `ITNP_WRITE` 会同时命中两者；按完整 tag 搜。
- `itnpass_store.lua:295` 的故障码 `STORE_DB_CORRUPT` **不加**前缀：它同时是 `store.faults()` 返回给
  调用方的故障码（`itn-pass/tests/t_store.lua:559` 直接断言这个值），只镜像进同一个日志文件，且本身
  已经不会与 cardkey / Sentinel 的 tag 撞名。
- 管理台不写日志文件（只打印屏幕），它的输出文案见第 9 节与 B3 报告，没有 tag。

## 13. 修订记录

| 批次 | 变更 |
| --- | --- |
| B1 | 从 `cardkey/` 硬分支出 `itn-pass/`：6 个文件改名、运行时路径加 `itnpass_` 前缀、行为零变化；本文件建立。 |
| B3 | 协议 `itnpass_v1` / 频道 33 收敛到 `common/itnpass_net.lua`（新文件，部署为 `/itnpass_net.lua`）；服务端日志 tag 统一 `ITNP_*`（第 12 节）；界面标题改 `ITN-Pass Disk Writer` / `InterTeamNet Access` / `ITN-Pass Station`；导出头改 `# ITN-Pass batch`；本文件的行号引用按当前工作树刷新。 |
| B6 | README 全量重写（16 节，中文，覆盖两条盘的部署布局、协议与 `netcheck` 判定、扣次语义、`ITNP_*` 日志、`.corrupt-*` 保留策略、离线测试 488/0/29、构建发布与安全风险）；发布包**排除 `tests/`**（`build_release.py` 的 `EXCLUDE_FROM_RELEASE`，仅 itn-pass 生效，31→19 成员，见 §10.1）；CI 接 itn-pass（dispatch options / tag 名单 / 分支循环 / `case` 分派）；根 `README.md` 三处同步。 |
