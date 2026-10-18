# CardKey 卡密验证机（cardkey_v1）

本目录在 CC:Tweaked / CraftOS-PC 上实现一套"卡密 + 服务器代写软盘"的方案：一台服务器电脑持有卡密
数据库与 pepper，负责记账和写盘；任意多台终端电脑只负责输入卡密、转发请求、显示结果。终端上没有
卡密库、没有 pepper、没有 sha256、没有磁盘代码，被拆掉也只得一个转发壳。协议名 `cardkey_v1`，
使用有线 modem、频道 3，不依赖 rednet、PSK、用户库或审计服。

本文档描述的是本目录代码的实际行为。涉及的游戏内路径、配置键、消息字段、失败原因和界面文本都
按源码逐字核对；行文里的代码标识符与路径保持 ASCII 原样。

## 0. 概述与数据流

一条典型链路：

1. 终端开机：`/system/sandbox.lua` 锁事件 → `/system/netcheck.lua` 在频道 3 上听 3 秒心跳，
   必须恰好听到 1 个不同的 `server_id`，否则锁死并写 `/lock.flag`。
2. 玩家输入卡密：终端发 `verify_request`，服务器只查库（不预留、不扣次），回
   `verify_response`，带上 `uses_left` / `uses_total`。
3. 玩家在菜单选 `1. Write Disk`：终端发 `write_request`（含 `reservation_id`）。服务器
   `reserve` 预留一次 → `/system/disk_writer.lua` 把 `/payload/` 复制到驱动器网上的那张软盘 →
   成功则 `commit` 扣 1 次，失败则 `release` 不扣。
4. 终端显示成功、失败或"写盘成功但没扣次"警示，3 秒后回到卡密输入界面。

一句话：**验证一次不收钱；只有写盘成功并且预留仍然有效时才扣次。**

## 1. 组成、两张网与协议

### 1.1 角色

| 角色 | 数量 | 说明 |
| --- | --- | --- |
| 卡密服务器 | 1 台 | 独占一台电脑，跑服务和管理台；持数据库、pepper、`SERVER_ID`、payload |
| 终端 | 任意多台 | 只跑客户端与界面；不持任何秘密 |

### 1.2 网络 A 与网络 B

服务器必须接**两个**有线 modem，形成两条物理上独立的网络：

- **网络 A（终端网）**：服务器"终端侧" modem + 所有终端。频道 3，服务器每 2 秒广播心跳，
  终端只在这一侧听到服务器。
- **网络 B（驱动器网）**：服务器"驱动器侧" modem + 恰好一个 disk drive。**这条网上只允许
  服务器自己**，不接任何其它电脑。

```
网络 A（终端网 / 频道 3）                     网络 B（驱动器网 / 仅服务器）
+--------+  +--------+  +--------+            +-----------+
|终端 #1 |  |终端 #2 |  |终端 #N |            | disk drive|
+---+----+  +---+----+  +---+----+            +-----+-----+
    |           |           |                       |
+---+-----------+-----------+---+             +-----+-----+
|  有线 modem（terminal side）   |             | 有线 modem |
+---------------+---------------+             +-----+-----+
                |                                   |
          +-----+-----------------------------+-----+
          |            卡密服务器              |
          +-----------------------------------+
```

### 1.3 为什么必须物理分开

CraftOS 的有线 modem 网络会把同一网络上所有外设共享给网络里的每台电脑。若把驱动器和终端接在
同一条网上：

- 每个终端都能看到并操作那个 drive，服务器的"正好一个驱动器"判断失去意义；
- 服务器也无法用"哪条网带驱动器"来区分哪张网是终端网，自动识别必然歧义。

网络 B 只连服务器自己的 modem 与驱动器，玩家只能物理地往驱动器里插软盘，无法接入那条网。

### 1.4 modem_side 的自动识别与拒绝文本

配置项 `modem_side` 指明"终端侧"是哪个 modem（侧名，如 `left`、`back`）。

- `modem_side` 非空：必须已连接、是 modem、且是有线 modem，否则报
  `modem_side '<x>' is not a modem` 或 `modem_side '<x>' is not a wired modem`。
- `modem_side = nil`：枚举所有**非无线** modem，按名字排序后：
  - 0 个 → `no wired modem found - attach a wired modem and reboot`；
  - 1 个 → 直接用它；
  - 多个 → **逐个** modem 调 `peripheral.call(name, "getNamesRemote")`，把返回的每个远端外设
    用 `peripheral.hasType(remote, "drive")` 判断是否驱动器；恰好一个"不带驱动器"的 modem 就是
    终端网。
  - 任何 modem 报不出自己的网络 → `cannot tell which wired modem is the terminal network
    (N wired modems, U could not report their network)`；
  - 每个都带驱动器 → `every wired modem carries a drive; the terminal network is not attached`；
  - 有多个候选 → `several wired modems could be the terminal network (a, b)`。

后三种文本末尾都会追加 `; set modem_side in /auth/cardkey_config.lua`。代码**从不猜**：无法唯一
确定时拒绝启动，把原因写进 `/auth/cardkey_fault.flag`。

关键点：判断"哪个 modem 带驱动器"只问该 modem 自己的 `getNamesRemote`，**不用**
`peripheral.getNames()`。因为 `getNames()` 会合并所有 hub 的视图，网络 B 上的 `drive_0` 看起来
像是挂在两个 modem 旁边，会把两个 modem 都误判成"带驱动器"。

### 1.5 消息速查

所有请求都由终端发到频道 3；服务器把回复发到终端的随机回复频道（1000..9999）。

- `verify_request`：`protocol`、`type="verify_request"`、`code`、`nonce`、
  `terminal_id`。`nonce` 形如 `<rand 1..1e9>-<epochMs>`。
- `verify_response`：`protocol`、`type`、`server_id`、`nonce`（原样回显）、`success`、
  `message`，成功时还有 `uses_left`、`uses_total`。
- `write_request`：`protocol`、`type="write_request"`、`code`、`nonce`、`terminal_id`、
  `reservation_id="<terminal_id>-<nonce>"`。
- `write_response`：`protocol`、`type`、`server_id`、`nonce`、`success`、`message`、
  `charged`；成功时还有 `uses_left`、`uses_total`、`files`、`dirs`、`bytes`；失败时可能有
  `detail`。
- `heartbeat`：`protocol`、`type="heartbeat"`、`server_id`，每 2 秒由服务器在频道 3 广播。

服务器只处理"自己终端侧 modem 上、频道 3、`protocol` 正确"的消息；协议不对则不回复，终端会
表现为超时。每个回复都带 `server_id` 和 `nonce`（包括失败回复），终端据此判断这是不是它要的答复。

## 2. 部署文件地图

### 2.1 服务器

| 游戏内路径 | 本仓库路径 | 说明 |
| --- | --- | --- |
| `/startup.lua` | `cardkey/server/startup.lua` | 并行启动服务与管理台 |
| `/sha256.lua` | `cardkey/common/sha256.lua` | 纯 Lua SHA-256；服务器**必需** |
| `/auth/cardkey_config.lua` | `cardkey/server/auth/cardkey_config.lua` | 配置表 |
| `/auth/cardkey_store.lua` | `cardkey/server/auth/cardkey_store.lua` | 数据库、pepper、预留与扣次 |
| `/system/cardkey_server.lua` | `cardkey/server/system/cardkey_server.lua` | 协议服务、限流、日志 |
| `/system/disk_writer.lua` | `cardkey/server/system/disk_writer.lua` | payload 复制到软盘 |
| `/system/cardkey_admin.lua` | `cardkey/server/system/cardkey_admin.lua` | 密码保护的管理台 |
| `/payload/...` | 自行准备 | 要写到软盘的文件；目录可由 `payload_dir` 改 |

`/sha256.lua` 是必需的：`cardkey_store.lua` 在加载时直接 `dofile("/sha256.lua")`，缺了它服务会
启动失败；管理台会打印 `[ERROR] cannot load /sha256.lua: ...`。终端**不要**放它。

### 2.2 终端

| 游戏内路径 | 本仓库路径 | 说明 |
| --- | --- | --- |
| `/startup.lua` | `cardkey/terminal/startup.lua` | 锁、网络检查、进 kernel |
| `/system/netcheck.lua` | `cardkey/terminal/system/netcheck.lua` | 数服务器 |
| `/system/sandbox.lua` | `cardkey/terminal/system/sandbox.lua` | 拦 Ctrl+T、清退出入口 |
| `/system/kernel.lua` | `cardkey/terminal/system/kernel.lua` | 登录循环 |
| `/system/ui.lua` | `cardkey/terminal/system/ui.lua` | 菜单与结果界面 |
| `/auth/cardkey_client.lua` | `cardkey/terminal/auth/cardkey_client.lua` | 协议客户端 |
| `/auth/cardkey_login.lua` | `cardkey/terminal/auth/cardkey_login.lua` | 卡密输入界面 |
| `/auth/session.lua` | `cardkey/terminal/auth/session.lua` | 内存会话表，TTL 600000 ms |

终端上没有任何数据库、pepper、sha256、payload 或磁盘代码。终端的网络参数是写死的（频道 3、
协议 `cardkey_v1`），它不读 `cardkey_config.lua`。

## 3. 第一次开机

### 3.1 开机顺序

1. 拷贝服务器文件（注意 `/sha256.lua`）与 payload，接好两条网（各一个有线 modem；网络 B 上
   只放一个驱动器）。
2. 首次启动：`/startup.lua` 并行跑服务与管理台。以下文件会自动创建：
   - `/auth/cardkey_pepper.txt`：48 个随机的 `[A-Za-z0-9]` 字符，末尾带换行；卡密派生的唯一秘密。
   - `/auth/cardkey_server_id`：24 个 `[A-Za-z0-9]` 字符；终端用心跳里的它来认服务器。
   - `/auth/admin.db`：在你于管理台创建管理员密码后生成，格式
     `{salt=<16 个 [A-Za-z0-9]>, hash=sha256(password .. salt)}`。
3. 若 modem 选择失败，服务把一行原因写进 `/auth/cardkey_fault.flag`，管理台首页显示
   `[SERVICE FAULT] <原因>`。按提示设置 `modem_side` 后重启服务器。
4. 服务成功启动时会在 `/auth/cardkey_server.log` 追加一行 `START server_id=... channel=3
   keys_usable=N keys_total=N`，并删掉旧的故障旗标。

### 3.2 pepper：必须单独备份

`/auth/cardkey_pepper.txt` 是整套系统唯一的秘密：

- **丢失** = 下次启动会自动生成一个新的 pepper，于是**所有已发出的卡密全部验证失败**
  （都会显示 `unknown code`），数据库里只剩无法对应明文的指纹。
- **泄露** = 拿到文件的人可以离线伪造任意卡密，并在你的服务器上正常使用。

做法：第一次开机后立刻把该文件复制到服务器之外（离线记录或另一台电脑），单独保管，不要和
`cardkeys.db` 放在同一份随手可取的备份里。

另有一个如实说明：代码只要求 pepper 文件内容"去空白后非空"，不校验 48 字符长度或字符集，
自动生成时才是 48 个 `[A-Za-z0-9]`。因此你也可以在**首次开机前**自己放一个真随机的 48 字符
字符串进去；一旦已经有卡密发出，再替换 pepper 就等于作废旧码。

### 3.3 生成第一批卡密

在管理台选 `1. Generate card keys`：数量（最多 `max_batch`，默认 200）、每码次数（默认
`default_uses`，默认 2）、备注。明文会导出到 `/cardkeys/cardkeys_YYYYMMDD-HHMMSS.txt` 和
`/cardkeys/latest.txt`（同名时自动加 `-2`、`-3` 后缀）；数据库只保存指纹。

导出的文本文件里，前面若干行是 `#` 开头的注释（含 `# CardKey batch`、`# generated:`、
`# count:`、`# uses each:`、`# note:`、分隔用的 `#`、三行说明），空一行后每行一张
`XXXX-XXXX-XXXX-XXXX` 格式的卡密。

**把这两个文件拷出服务器（拷到游戏外），然后删除它们。** `latest.txt` 每批都会被覆盖，但历史
批次文件会一直留着，直到你手动删除。

## 4. 扣次模型

### 4.1 verify 不扣次

`verify_request` 只做 `lookup`：不预留、不扣次、不占用次数。失败也只记一次限流失败。所以
"只验证、不写盘"永远是 0 消耗；菜单选 `0. Cancel` 连请求都不发。

### 4.2 write 的一次事务

一个 `write_request` 在服务器内部是一次事务：

1. `reserve`：在数据库里该卡记录的 `reservations[reservation_id]` 写入到期时间
   （默认 `reservation_ttl_ms = 300000`，即 5 分钟），并立即落盘。
2. `disk_writer.write()`：把 payload 复制到那张唯一的软盘。
3. 成功 → `commit`：清掉预留、`uses_left` 减 1、写 `last_used`、落盘。
4. 失败 → `release`：清掉预留，不扣次。

同一 `nonce` 的重发请求会在 replay 检查处被拒（`duplicate request`），不会扣第二次。

### 4.3 预留、held 与 "in use on another terminal"

- `held` = 该卡当前未过期的预留数量；可用次数 = `uses_left - held`。
- `uses_left > 0` 但全部被预留 → `in use on another terminal`（注意：这表示"这张卡现在没有
  未预留的可用次数"，不一定是别的终端正在刷）。
- `uses_left <= 0` → `used up`。
- 预留超过 TTL 自动视为释放；服务每 5 秒做一次 `store.prune()`，真的删掉了过期预留才落盘。
- 预留保存在 `/auth/cardkeys.db` 里，没有单独的预留文件。服务器中途崩溃时，残留的预留会在 TTL
  后自动失效，期间没有扣次。

`commit` 时如果 `uses_left` 已经是 0，仍会返回成功，但 `charged=false`，消息为
`written, use not charged`，终端会显示"写盘成功但未扣次"的警示（例如最后 1 次被别处抢先花掉）。

### 4.4 什么时候绝不扣次

- 只登录 / 只验证，或菜单取消（服务器没收到 `write_request`）。
- 卡密不存在、格式不对、已撤销、已用完，或最后一次已被别的终端预留。
- 重复的 `write_request`（同一 `nonce`）。
- 请求处于限流锁定期间。
- 缺少 `reservation_id`、预留已过期、或 `commit`/`release` 找不到预留（`no such reservation`）。
- 写盘任一失败：`no drive`、`too many drives`、`no disk`、`no mount`、`no payload`、
  `empty payload`、`disk full`、`cannot create ...`、`write failed: ...`、`write truncated`，
  以及写盘抛异常。
- 终端侧网络失败、超时，或收到不属于自己的回复（服务器没动账本）。

写盘失败**不算**认证失败，不会累计到 10 次/60 秒的终端锁或 60 次/30 秒的全局锁。

一个需要如实说明的边界：终端的 30 秒写超时只是终端放弃等待，**不会取消**服务器已经开始的复制。
如果复制在超时之后才完成，服务器仍会 `commit` 扣次，而终端已经显示了失败。payload 越大越容易
遇到（见第 12 节）。

## 5. 卡密格式与密码学

- 字母表：`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`（32 个符号，去掉了 `0 O 1 I`）。
- 长度：16 个字符，展示为 `XXXX-XXXX-XXXX-XXXX`。
- 规范化 `normalize(code)`：转大写，删掉所有不属于 `A-Z0-9` 的字符，然后要求结果**正好 16 个
  字符且每个字符都在字母表内**，否则视为无效（`invalid code format`）。因此大小写、`-`、空格
  都能容错；长度不对或含 `0 O 1 I` 之类的字符会被直接拒绝。
- 指纹：`sha256(normalized .. "|" .. pepper)`，64 位小写十六进制。**数据库的键就是指纹**，库里
  永远不存明文。
- 派生：`digest = sha256(pepper .. "|cardkey|" .. label)`；取 digest 的前 32 个十六进制字符，
  每两个字符组成一个字节，`idx = byte % 32 + 1`，从字母表取第 `idx` 个字符，共 16 个。
- `label = <epochMs>:<mintCounter>:<math.random(1,2147483647)>:<computerID>`，只要求唯一，
  不要求不可预测。

为什么 `math.random` 不是保密来源：卡密是从 pepper **单向派生**的。攻击者即使拿到一张合法卡密、
知道大致的生成时间，也无法从它反推出其它卡密——除非拿到 pepper。随机数只用于挑 label、生成
pepper 与 `SERVER_ID`。真正的防线是 32 个符号的 16 位空间（约 2^80）加上限流。

数据库记录（`/auth/cardkeys.db`，`textutils.serialize` 的表）：

```
[指纹] = {
    uses_total, uses_left, created=<epochMs>, note="", revoked=<bool>,
    last_used=<epochMs|nil>, reservations = { [reservation_id] = <到期 epochMs> }
}
```

启动时 `cardkey_store.lua` 会先播种 PRNG：`os.epoch("utc") % 2147483647` 与
`floor(os.clock() * 1000000)`、`os.getComputerID() * 7919` 做 `bit32.bxor` 混合。服务与管理台各自
加载一份 store，各自播种，但不会在每次菜单操作时重新播种。

## 6. 写盘规则与失败文本

复制由服务器完成，终端全程不碰磁盘。规则如下。

payload 先验（在查看驱动器之前）：

- `payload_dir`（默认 `/payload`）不存在 → 原因 `no payload`，说明 `<dir> is missing on the server`。
- 目录存在但递归列表为空 → 原因 `empty payload`，说明 `<dir> contains nothing to write`。

驱动器：

- 扫描 `peripheral.getNames()` 中 `peripheral.hasType(name, "drive")` 的项：
  - 0 个 → `no drive` / `no disk drive is visible; check the drive network`；
  - 多于 1 个 → `too many drives` / `<n> drives visible (a, b); exactly one is allowed`。
- 正好一个：
  - `disk.isPresent` 为假 → `no disk` / `insert a disk into <name>`；
  - `disk.getMountPath` 失败或返回空 → `no mount` / `disk in <name> has no readable filesystem`；
  - 挂载点不存在或不是目录 → `no mount` / `disk in <name> is not mounted at <path>`。

空间预检：如果系统能提供空间数据（优先使用同时存在 `disk.getDiskSpaceTotal` 与
`disk.getDiskSpaceUsed` 的 shim；否则退到 `fs.getFreeSpace(mount)`），且 payload 总字节数大于
可用空间 → `disk full` / `need <B> bytes, <F> free`，**在写之前**拒绝。若两者都不可用则跳过
预检，靠逐文件写入与事后尺寸校验兜底。

复制：

- 按排序后的条目先建目录、再写文件；源文件以 `rb` 打开，目标以 `wb` 打开，每块 8192 字节。
- 每个文件写完后用 `fs.getSize(dst)` 与源大小比较。
- 目标已存在同名文件时先读出旧内容作为备份；目标位置是目录时直接失败。
- 任何一步失败都会回滚：本次新建的文件删除，**已存在的文件写回旧内容**，本次新建的目录删除。
  因此写盘失败不会破坏盘上原有的文件。
- 失败原因与说明（服务器把它们拼成 `disk write error` 的 `detail`）：
  - `cannot create <dst>` + 说明（`makeDir failed` / `a file with that name is in the way` /
    `a directory with that name is in the way`）；
  - `write failed: <dst>` + 说明（`cannot read the existing file` / `cannot read <src>` /
    `cannot open destination` / 具体错误 / `the disk refused the data`）；
  - `write truncated` + `<dst>: wrote X bytes, expected Y`。

接口：

- `write()` → `true, {drive, mount, files, dirs, bytes, free_after}`
  或 `false, reason, detail`。
- `status()` → `{state = "no drive" | "too many drives" | "no disk" | "no mount" | "ready",
  drives, drive?, mount?, free?, total?}`。

终端看到的失败界面是：`[Failed] disk write error`，下一行是 `detail`（例如
`no disk: insert a disk into drive_0`）。`dirs` 统计的是 payload 里的目录条目数（包含本来就在
盘上的同名目录）；`bytes` 是 payload 文件总字节数。

## 7. 终端界面

### 7.1 开机与锁死

终端 `/startup.lua`：加载 sandbox → `lockEvents()`（丢掉所有 `terminate` 事件，Ctrl+T 无效）→
`netcheck.check(3)`。检查失败时：

- 把原因写入 `/lock.flag`；
- 屏幕显示 `NETWORK SECURITY CHECK FAILED`、`Reason: <原因>`、`Fix the network and reboot.`；
- 然后挂起，没有返回 CraftOS 的路径，**只能重启这台电脑**。

可能的原因：`no modem`、`wireless modem`、`no card key server detected`、`multiple servers: N`，
以及 modem 打开频道失败时的 `cannot open channel`。无线 modem 不允许参与（只有在没有任何
有线 modem 时才报 `wireless modem`；有有线 modem 时优先使用有线的那个）。

### 7.2 卡密界面

```
Secure Terminal
(空行)
Enter your card key.
(空行)
Card key: <明文输入>
Checking...
```

- 失败：空行 + `[Error] <原因>`，停 2 秒，回到卡密界面。
- 成功：空行 + `[OK] Card key accepted.`，若服务器给了剩余次数则再显示
  `Uses left on this key: <n>`，停 1 秒后进菜单。

### 7.3 菜单

```
Secure System
(空行)
1. Write Disk
0. Cancel
(空行)
Select: 
```

除 `1` 以外的任何输入都**静默返回**卡密界面，不发请求、不扣次。选 `1` 后显示：

```
Writing disk...
(the server is copying the payload)
(空行)
```

然后等待服务器回 `write_response`（写盘超时 30 秒）。

### 7.4 成功 / 未扣次警告 / 失败

成功（`charged` 为真）：

```
[OK] Disk written and key charged.
(空行)
Files: <n>
Dirs:  <n>            (仅当 dirs > 0)
Bytes: <n>
(空行)
Uses left on this key: <n>   (服务器给了才显示)
(空行)
Logging out...
```

`charged == false` 时：

```
[OK] Disk written.
(空行)
[Warning] Use was NOT charged:
the server could not confirm it.
(空行)
Files: <n>
...
```

失败：

```
[Failed] <原因>
<detail>                 (有才显示，例如 no disk: insert a disk into drive_0)
(空行)
Your card key was NOT charged.
No use was consumed.
(空行)
Logging out...
```

成功与失败都停 3 秒，然后回到卡密输入界面；kernel 随后 `session.destroy` 并进入下一轮。菜单层
拿不到 `shell`/`commands`/`fs.delete`/`fs.move`/`os.shutdown`/`os.reboot`，所以没有回 CraftOS
的入口（唯一出路是重启电脑）。

### 7.5 客户端协议细节

- 每次请求前随机选回复频道 `math.random(1000, 9999)`，**先 `open` 再 `transmit`**，收到回复或
  超时后 `close`。
- `nonce = <rand 1..1e9>-<epochMs>`，`terminal_id = tostring(os.getComputerID())`，
  `reservation_id = terminal_id .. "-" .. nonce`。
- 超时：验证 8 秒，写盘 30 秒（`os.startTimer`）。
- 只接受同时满足以下条件的 `modem_message`：事件里的 `side` 是终端自己的有线 modem、
  `channel` 是本次回复频道、`protocol` 正确、`type` 正确、`nonce` 一致、`server_id` 在
  netcheck 见过的集合里。任一不符的回复会被丢弃并继续等，直到超时。
- 失败后清空缓存的服务器集合，**下一次请求**重新跑 3 秒 netcheck；成功时不会重复 netcheck。
  因此开机时会 netcheck 一次，第一次输卡密还会再 netcheck 一次（约多 3 秒），之后请求直接用缓存。
- 本地可能显示的原因还包括：`empty code`、`no modem`、`wireless modem not allowed`、
  `cannot open channel`、`server timeout`、`answer from unknown server`、
  `network check: <原因>`，以及服务器拒绝但没给 `message` 时的兜底 `refused`。

## 8. 管理台

`/startup.lua` 同时跑服务与管理台；管理台退出后 1 秒重启，所以密码界面总会回来。

### 8.1 登录

首次运行（没有 `/auth/admin.db`）：

```
=== First run: create admin password ===
New password: 
Confirm password: 
```

- 少于 4 字符 → `[Error] Password must be at least 4 characters.`
- 两次不一致 → `[Error] Passwords do not match.`
- 成功 → `[OK] Admin password set.`，写 `{salt, hash=sha256(password .. salt)}`。

`/auth/admin.db` 损坏（不是含 `salt`/`hash` 的表）→
`[Error] Admin database is corrupt. Delete /auth/admin.db to start over.`

之后每次：

```
Card Key Admin
Password: 
```

共 3 次机会，从第 2 次起先打印 `Attempt N of 3`；错一次打印 `[Error] Wrong password.`；3 次都错
打印 `Access denied.` 并**停 5 秒**再回到密码界面（不是瞬间死循环）。

### 8.2 首页

```
Card Key Admin
usable=<可用卡数>  remaining=<剩余总次数>
[SERVICE FAULT] <故障旗标第一行>     (有旗标才显示)
disk: <no drive|too many drives|no disk|no mount|ready> ( (<驱动器名>) )
free: <n> bytes                     (ready 且能拿到空间数据时)
(空行)
1. Generate card keys
2. List / revoke
3. Restore revoked key
0. Exit
Select: 
```

`usable` 是"未撤销且还有次数"的卡数；`remaining` 是所有卡 `uses_left` 之和（含已撤销的卡，
撤销不会回收次数）。`0` 或直接回车退出（随后被重启）。

### 8.3 生成

依次提示：

- `How many? (1-<max_batch>): `：非数字或小于 1 → `Cancelled.`（停 1 秒返回）；超过
  `max_batch` → `Too many, capped at <max>.` 并按上限截断。
- `Uses per key? (default <default_uses>): `：无效或小于 1 时用默认值。
- `Note (optional): `：可空。

导出顺序：先写 `/cardkeys/cardkeys_YYYYMMDD-HHMMSS.txt`，再写 `/cardkeys/latest.txt`，两份都
写成功并逐张回读校验通过后，才把这一批写入数据库（`commitBatch`）。任何一份写失败：

```
[ERROR] Could not save the plaintext file:
<原因>
Nothing was stored. No keys were created, and no
uses were consumed. Fix the problem and try again.
```

此时数据库不入库、不扣次。

成功：

```
=== <n> card key(s), <n> use(s) each ===
  XXXX-XXXX-XXXX-XXXX        (仅当 n <= 5，逐张列出)
Saved to:
<批次文件路径>
<latest.txt 路径>
Stored <n> key(s) in the database.
Copy one of these files off the server, then delete it.
```

`Press Enter to continue...` 后返回首页。

注意一个边角：如果第一份导出成功、第二份（`latest.txt`）失败，第一份文件会留在 `/cardkeys/`
里，但数据库没有入库，这些明文码不可用；请把它们删掉。

### 8.4 列表 / 撤销

```
=== Card keys ===
total=<n>  usable=<n>  used-up=<n>  revoked=<n>
remaining uses: <n>
fp            left/total  status
-----------------------------------   (35 个 '-')
<12 位指纹>   <left>/<total>   <ok|used up|REVOKED>
...
(空行)
Enter = back
revoke by fp prefix or full code: 
```

- 直接回车返回。
- 输入完整卡密（会规范化）或至少 4 位十六进制指纹前缀（必须唯一）→ `[OK] revoked`；
  否则 `[Error] prefix too short (min 4 chars)` / `[Error] no match` /
  `[Error] ambiguous prefix, N matches`。
- 撤销只改 `revoked` 标志，不影响已发出的剩余次数。

### 8.5 恢复

```
=== Restore a revoked key ===
Needs the FULL code (prefixes are ambiguous).
Card key: 
```

成功 `[OK] restored`；失败 `[Error] invalid code format` 或
`[Error] no match (unrevoke needs the full code)`（前缀无法恢复，必须完整卡密）。之后
`Press Enter to continue...`。

## 9. 配置参考（`/auth/cardkey_config.lua`）

文件返回一张纯表，键与默认值如下。"谁读"列是实际引用该键的模块。

| 键 | 默认值 | 谁读 | 含义 |
| --- | --- | --- | --- |
| `channel` | `3` | 服务 | 终端网频道；终端写死 3，不读配置 |
| `protocol` | `"cardkey_v1"` | 服务 | 协议名；终端写死，不读配置 |
| `modem_side` | `nil` | 服务 | 终端侧 modem 的侧名；`nil` = 自动识别 |
| `heartbeat_interval` | `2` | 服务 | 心跳间隔，秒 |
| `admin_file` | `"/auth/admin.db"` | 管理台 | 管理员密码库 |
| `export_dir` | `"/cardkeys"` | store | 明文批次导出目录 |
| `payload_dir` | `"/payload"` | disk_writer | 要写到软盘的源目录 |
| `default_uses` | `2` | 管理台 | 生成时"每码次数"的默认值 |
| `max_batch` | `200` | 管理台 | 单批数量上限 |
| `challenge_ttl_ms` | `15000` | 服务 | nonce 去重窗口，毫秒 |
| `reservation_ttl_ms` | `300000` | store | 写盘预留有效期，毫秒 |
| `max_fail_per_terminal` | `10` | 服务 | 单终端连续失败多少次后锁 |
| `lockout_ms` | `60000` | 服务 | 单终端锁时长，毫秒 |
| `max_fail_global` | `60` | 服务 | 全局连续失败多少次后锁 |
| `global_lockout_ms` | `30000` | 服务 | 全局锁时长，毫秒 |

生效时机：`channel`、`protocol`、`modem_side`、`heartbeat_interval` 在服务启动时读取一次，改后
需要重启服务器；`reservation_ttl_ms` 在每次 `reserve` 时重读，`export_dir` 在每次生成时重读，
`payload_dir` 在每次写盘时重读；管理台每次启动（约每秒）重读 `admin_file`、`max_batch`、
`default_uses`。也就是说，改这些值大多不用重启，但网络相关的四项必须重启。

计失败的是 `lookup`/`reserve` 的失败（不存在、格式错、撤销、用完、被预留）；空卡密、重复
nonce、限流期间的请求、写盘失败都不计入。任意一次成功（verify 或 write）会清空该终端的计数和
全局计数。锁状态只在内存里，重启服务器即清零。

## 10. 日常运维

### 10.1 日志

服务只往 `/auth/cardkey_server.log` 追加，从不打印到屏幕。每行格式：

```
YYYY-MM-DD HH:MM:SS  <消息>
```

标签与含义：

| 标签 | 示例 / 含义 |
| --- | --- |
| `START` | `START server_id=... channel=3 keys_usable=N keys_total=N`，服务成功启动 |
| `CHECK` | `CHECK terminal=7 success=1 uses_left=2`，验证成功（不扣次） |
| `DENY` | `DENY terminal=7 reason=unknown code`，验证或预留被拒 |
| `LOCKED` | 达到阈值 `LOCKED terminal=<id> seconds=60`、全局 `...=global seconds=30`、锁期间 `...=<id> blocked=1` |
| `GRANT` | `GRANT terminal=7 reservation=... fp=<64 位指纹>`，预留成功、开始写盘 |
| `WRITEFAIL` | `WRITEFAIL terminal=7 reservation=... reason=... detail=...`，写盘失败、已释放不扣次 |
| `WRITE!` | `WRITE! reservation=... files=3 dirs=1 bytes=4096`，复制完成 |
| `COMMIT!` | `COMMIT! reservation=... charged=1 uses_left=1`，提交结果 |
| `ERROR` | 启动故障（`ERROR fault: ...`）、心跳/回复发送失败、处理异常、prune 异常、commit 找不到预留 |

日志只增不减；需要清理时可以直接删掉或清空文件（服务以追加方式打开，不会因此崩溃）。

### 10.2 故障旗标

`/auth/cardkey_fault.flag` 只有一行，由服务在启动失败时写入：store/writer/config 加载失败、
modem 选择失败、频道打不开。成功选定 modem 后会被删除；若之后又出错会重新写入。管理台首页把
它的第一行显示为 `[SERVICE FAULT] <文本>`。修复后重启服务器即可。

### 10.3 服务器 ID

`/auth/cardkey_server_id` 是 24 个 `[A-Za-z0-9]`，内容不合法（长度不对或含其它字符）会自动
重新生成并覆盖。终端靠心跳里的这个值识别服务器。

**不要把同一个 ID 复制到另一台同时开机的服务器。** 终端只数"不同 `server_id`"，两台 ID 相同的
服务器在网络 A 上看起来就是一台，两台都会响应请求，扣次结果不可预期。复制整份服务器文件到新
机器时，删掉这个文件让它重新生成。

### 10.4 payload 维护

- 放到 `payload_dir` 下的文件和子目录会被递归复制；条目按名字排序，目录先于其内容。
- 目标盘上已存在的同名文件会被覆盖（失败时回滚恢复旧内容）；payload 里没有的旧文件不会删除。
- payload 为空或目录不存在时拒绝写盘，且不扣次。
- 别放太大的东西：终端等 30 秒，复制可能在超时后才完成（见第 12 节）。

### 10.5 备份与搬迁

必须备份：`/auth/cardkey_pepper.txt`（丢了全废）、`/auth/cardkeys.db`（次数与撤销状态）、
`/auth/admin.db`（管理员密码）。`/auth/cardkey_server_id` 可备份，但只能属于一台同时开机的
服务器。payload、配置和代码按需备份。

搬服务器时把这四个文件一起带上，尤其是 pepper；否则旧卡密全部变成 `unknown code`。

### 10.6 服务器侧的 shell 入口

终端有 sandbox，服务器没有。服务器上 Ctrl+T 的第一次按下会终止服务（启动脚本把异常吞掉后
停驻，屏幕出现 `Terminated`，此时终端会看不到服务器）；**再按一次**才会退出启动脚本回到
CraftOS shell。回到 shell 后可以查看或拷贝 `/auth/cardkey_server.log`、备份 pepper（例如把软盘
插进网络 B 的驱动器后 `copy /auth/cardkey_pepper.txt /disk/`），完事重启电脑恢复服务。这同样
意味着服务器屏幕不是安全边界：能坐在服务器前的人本来就能拿走 pepper。

## 11. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 终端开机锁死，`Reason: no modem` | 终端没有（或有线 modem 没接上）；接有线 modem 后重启 |
| `Reason: wireless modem` | 只有无线 modem，没有任何有线 modem；换有线 |
| `Reason: no card key server detected` | 服务器没开/崩溃、频道或协议被改、modem 不在网络 A、或服务器启动失败（看故障旗标与日志） |
| `Reason: multiple servers: N` | 网络 A 上有 N 个不同的 `server_id`：多开了一台服务器，或复制了服务器 ID；只保留一台或删掉复制的 ID 文件 |
| `Reason: cannot open channel` | 有线 modem 打不开频道 3；检查 modem 是否被拔掉/网络异常，重启 |
| 一直 `Checking...` 后 `[Error] server timeout` | 没拿到可接受回复：服务没跑、协议不符、或 `server_id` 不在心跳集合；查日志 `CHECK`/`DENY`；失败后清缓存重查 |
| `[Error] answer from unknown server` | 有机器用本终端的 nonce 回了消息，但它的 `server_id` 不是 netcheck 见过的那个；通常是另一台服务器/伪造回复，检查网络 A |
| `[Error] unknown code` | 卡密打错、少位，或 pepper 丢了/换了；核对输入与 pepper 备份 |
| `[Error] invalid code format` | 规范化后不是 16 个合法字符（含 `0 O 1 I` 或长度不对） |
| `[Error] revoked` | 卡密被撤销；用管理台 3 输入完整卡密恢复 |
| `[Error] used up` | 次数用完了；生成新批次 |
| `[Error] in use on another terminal` | 最后几次正被未过期预留占着；等 `reservation_ttl_ms`（默认 5 分钟）或等对方写完 |
| `[Error] too many attempts, wait Ns` | 触发限流（单终端 10 次/60 秒或全局 60 次/30 秒）；等 N 秒 |
| `[Failed] disk write error` + `no drive: ...` | 驱动器没接/网络 B 没通；检查网络 B |
| 同上 + `too many drives: N drives visible (...); exactly one is allowed` | 网络 B 上多于一个驱动器；只留一个 |
| 同上 + `no disk: insert a disk into drive_0` | 驱动器里没有软盘 |
| 同上 + `no mount: disk in ... has no readable filesystem` / `is not mounted at ...` | 软盘文件系统不可用或挂载失败；换盘 |
| 同上 + `no payload: /payload is missing on the server` | 服务器没有 payload 目录或 `payload_dir` 写错 |
| 同上 + `empty payload: ... contains nothing to write` | payload 目录是空的 |
| 同上 + `disk full: need B bytes, F free` | 软盘空间不够；换盘或减小 payload |
| 同上 + `cannot create ...` / `write failed: ...` / `write truncated ...` | 软盘写入失败；本次已回滚、没扣次，换盘后重试 |
| `[OK] Disk written.` 但 `[Warning] Use was NOT charged:` | 写盘成功，但提交时该卡已无剩余次数（例如最后一次被别处抢先花掉）；盘已写、没扣到 |
| 管理台反复 `Access denied.` | 密码错；每轮停 5 秒后可再试 3 次。忘记密码就删 `/auth/admin.db` 重建（不影响卡密） |
| 所有卡密突然都 `unknown code` | pepper 丢了/被换，或搬迁服务器时没带 pepper；恢复备份 |
| 管理台首页 `[SERVICE FAULT] ...` | 看旗标文本：多为 modem 选错（设 `modem_side`）或加载失败；修好后重启 |
| 服务启动即报 `cannot open modem channel 3: ...` | 选中的 modem 打不开频道；检查硬件或改 `modem_side` |

## 12. 安全说明与诚实边界

1. **modem 是广播总线。** 网络 A 上任何带 modem 的电脑都能在频道 3 看到 `verify_request` /
   `write_request` 里的**明文卡密**。不要把其它 CC 电脑接到网络 A，也不要假设"只有我的终端能
   看到"。想要更强的链路保密需要另一套带密钥的协议，本方案没有 PSK。
2. **`terminal_id` 是客户端自报的。** 服务器把它当限流键，但它来自消息里的
   `tostring(os.getComputerID())` 或任意伪造值；改一个数字就能绕过"单终端 10 次/60 秒"。
   真正兜底的是全局"60 次/30 秒"；需要更严就调小 `max_fail_global`（代价是更容易被恶意全锁）。
3. **没有 PSK，服务器响应任何协议正确的请求。** 防线是卡密的随机性（约 80 位）与限流，不是
   "只有我的终端能问"。
4. **pepper 是全部秘密。** 泄露 = 可离线伪造任意卡密；丢失 = 全部已发卡密作废。它用平台
   `math.random` 生成（种子是首次启动的时间、`os.clock` 和 computerID 的混合），不是密码学
   RNG；能精确复现首次启动种子的人理论上可重建 pepper。稳妥做法是首次开机前自己放入真随机的
   48 字符，并单独备份。
5. **纯 Lua SHA-256。** 用 `bit32` 实现，能算对，但不是常数时间、也不抗侧信道；在这个游戏内
   威胁模型里够用，不要拿去保护游戏外的真实秘密。
6. **服务与管理台各有一份 store。** 每次操作前会比对并重读库文件（`refresh`），但没有文件锁；
   两个进程恰好同时"读-改-写"时仍可能丢掉一次更新（例如管理台生成的同时服务正在 commit）。
   概率不高，操作上避免在写盘高峰批量生成，生成后核对 `usable`/`remaining`。
7. **限流与 nonce 去重都在内存。** 重启服务器会清空锁与 15 秒的 nonce 窗口；这不是持久审计。
8. **终端没有秘密。** 破解终端只会得到一个转发壳；但链路上的明文问题见第 1 条。
9. **写超时不取消服务器工作。** 终端 30 秒超时后复制可能还在继续；若随后成功，服务器仍会
   `commit` 扣次，而终端已经显示失败。payload 大时要意识到这一点。
10. **`server_id` 克隆会造成双活服务器。** 见 10.3；换机时删掉旧 ID 文件。
11. **管理员密码只有 4 字符下限。** 管理台本身不联网，风险主要来自物理接触；建议用长密码，
    并记住服务器物理访问者本来就能读到 pepper 和数据库。

## 13. 文件清单

服务器代码与必需依赖：

| 路径 | 作用 |
| --- | --- |
| `/startup.lua` | 并行启动服务与管理台；服务失败时停在原地而不是掉回 shell |
| `/sha256.lua` | SHA-256 实现，`cardkey_store.lua` 加载时必需 |
| `/auth/cardkey_config.lua` | 配置表（见第 9 节） |
| `/auth/cardkey_store.lua` | 指纹库、pepper、预留、commit/release、生成与导出 |
| `/system/cardkey_server.lua` | 协议、心跳、限流、nonce 去重、日志、写盘事务 |
| `/system/disk_writer.lua` | payload 复制、空间预检、尺寸校验、回滚 |
| `/system/cardkey_admin.lua` | 管理台：生成、列表/撤销、恢复 |
| `/payload/...` | 要写盘的内容（可用 `payload_dir` 改路径） |

服务器运行期文件：

| 路径 | 产生方式 |
| --- | --- |
| `/auth/cardkeys.db` | store 自动创建/更新；指纹与次数、预留、撤销、备注 |
| `/auth/cardkey_pepper.txt` | 首次加载自动创建；48 字符 + 换行；**必须备份** |
| `/auth/cardkey_server_id` | 首次启动自动创建；24 字符；每台服务器唯一 |
| `/auth/admin.db` | 首次设置管理员密码时创建 |
| `/auth/cardkey_server.log` | 服务追加写的日志 |
| `/auth/cardkey_fault.flag` | 仅启动失败时出现，一行原因 |
| `/cardkeys/cardkeys_*.txt`、`/cardkeys/latest.txt` | 生成批次时的明文导出；拷出后手动删除 |

终端代码：

| 路径 | 作用 |
| --- | --- |
| `/startup.lua` | 加载 sandbox、锁事件、netcheck、失败锁死、进 kernel |
| `/system/netcheck.lua` | 3 秒窗口内数不同 `server_id` |
| `/system/sandbox.lua` | 拦 `terminate`、清 `shell` 等退出入口 |
| `/system/kernel.lua` | 登录→会话→界面→销毁会话的循环 |
| `/system/ui.lua` | 菜单与成功/失败界面 |
| `/auth/cardkey_client.lua` | 协议客户端、服务器集合缓存 |
| `/auth/cardkey_login.lua` | 卡密输入界面 |
| `/auth/session.lua` | 内存会话，TTL 600000 ms |

终端运行期文件：只有锁死时的 `/lock.flag`（下一次成功开机时删除；失败会挂起，只能重启）；
终端上没有任何卡密数据。

## 14. 部署顺序清单

1. 准备硬件：服务器电脑配两个有线 modem（一个给网络 A、一个给网络 B）和网络 B 上**恰好一个**
   disk drive；每台终端一个有线 modem。
2. 拷贝服务器文件：`/startup.lua`、`/sha256.lua`、`/auth/cardkey_config.lua`、
   `/auth/cardkey_store.lua`、`/system/cardkey_server.lua`、`/system/disk_writer.lua`、
   `/system/cardkey_admin.lua`，以及 `/payload/`。
3. 接线：网络 A = 服务器终端侧 modem + 所有终端；网络 B = 服务器驱动器侧 modem + 驱动器。
   **网络 B 不接任何其它电脑。**
4. 第一次开机服务器：看是否出现 `/auth/cardkey_fault.flag`；若 modem 选择报错，按文本设置
   `modem_side`（写侧名）后重启。
5. 首次进入管理台：设置管理员密码；立刻把 `/auth/cardkey_pepper.txt` 备份到服务器之外。
6. 放好 payload，把软盘插进驱动器；管理台选 `1` 生成一批卡密；把 `/cardkeys/*.txt` 拷出
   服务器后删除。
7. 把终端文件拷到每台终端（**不要**拷 `/sha256.lua`，不要拷 `/auth` 下的数据库）。
8. 依次开机终端：应出现 `Secure Terminal`。若锁死，按第 11 节排查网络 A、服务器状态与
   `modem_side`。
9. 用一张测试卡密走一遍 `1. Write Disk`：确认软盘内容正确、终端显示
   `[OK] Disk written and key charged.`、管理台 `usable`/`remaining` 变化、日志出现
   `GRANT`/`WRITE!`/`COMMIT!`。
10. 建立备份习惯：`/auth/cardkey_pepper.txt` 与 `/auth/cardkeys.db`（以及 `/auth/admin.db`）
    分开保存；换服务器时一起带走 pepper。

## 许可证

本项目以 **MIT** 许可证发布，详见仓库根目录的 `LICENSE`。
