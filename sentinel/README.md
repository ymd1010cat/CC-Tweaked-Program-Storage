# Sentinel 安全终端系统（协议 secure_auth_v5）

> 本项目原名 HighSafe，现更名 Sentinel（目录 `sentinel/`）。

## 0. 摘要与数据流

Sentinel 是给 ComputerCraft / CraftOS 用的一套门禁与用户管理方案：终端负责登录与发起
开门请求，认证服务器负责校验口令并**执行门禁动作**，审计服务器负责把每一次登录、开门与
管理动作按哈希链落盘。三者只通过有线 modem 通信，终端与服务器共享一段 32 字符的预共享
密钥（PSK），口令本身永不上线。

权限跟随账户：角色保存在认证服务器的 `/auth/users.db`，终端只是持有 PSK 的合法请求方，
它既不在本地校验账号，也没有任何本地授权或本地开门能力。角色权重由共享的纯模块
`/auth/role_policy.lua` 统一解释（root=4、admin=3、operator=2、user=1；`guest` 是 `user`
的历史别名）。终端每次登录都必须连上认证服务器，独立/离线模式已废弃。

一次完整动作的数据流：

```
终端 --(频道 1)--> salt_request / auth_request / open_request --> 认证服务器
认证服务器 --(回包频道)--> salt_response / auth_response / open_response --> 终端
认证服务器 --(频道 1，每 1 秒)--> heartbeat 广播
认证服务器 --(左侧红石)--> 门/金库机构（同意 open_request 时 1 秒脉冲）
终端 --(频道 2)--> audit_event（带签名，含 role）----------> 审计服务器
审计服务器 --(频道 2)--> audit_ack（针对单个事件）
审计服务器 --(频道 2，每 5 秒)--> audit_heartbeat 广播
审计服务器 --(背面红石 + 驱动器)--> 软盘归档，成功后换盘
```

登录用的是挑战-响应，不是口令传输：

- 终端先取盐：`H = sha256(password .. salt)`。
- 服务器生成一次性 `nonce_s`，终端计算 `H' = sha256(H .. "|" .. nonce_c .. "|" .. nonce_s)`。
- 只有 `H'` 会上线；服务器用自己保存的 `H` 重算并比较。
- 所有报文签名统一为 `sha256(PSK .. "|" .. 签名字符串)`，PSK 为 32 字符。

协议报文一览（`sig` 字段全部是上面的签名）：

| 报文 | 方向 | 频道 | 签名字符串 |
|---|---|---|---|
| `heartbeat` | 认证服务器 -> 广播 | 1 | 不签名 |
| `salt_request` | 终端 -> 认证服务器 | 1 | `terminal_id\|username\|nonce_c` |
| `salt_response` | 认证服务器 -> 终端回包频道 | 回包频道 | `server_id\|username\|salt\|nonce_c\|nonce_s` |
| `auth_request` | 终端 -> 认证服务器 | 1 | `terminal_id\|username\|derived\|nonce_c\|nonce_s` |
| `auth_response` | 认证服务器 -> 终端回包频道 | 回包频道 | 见下方长串 |
| `open_request` | 终端 -> 认证服务器 | 1 | `terminal_id\|username\|nonce` |
| `open_response` | 认证服务器 -> 终端回包频道 | 回包频道 | `server_id\|nonce\|tostring(ok)\|reason` |
| `audit_event` | 终端 -> 审计服务器 | 2 | `terminal_id\|username\|role\|action\|timestamp\|nonce` |
| `audit_ack` | 审计服务器 -> 终端 | 2 | `nonce\|terminal_id` |
| `audit_heartbeat` | 审计服务器 -> 广播 | 2 | 不签名 |

`auth_response` 的签名字符串较长，单独写在这里：

```
auth_response: server_id|nonce_c|nonce_s|tostring(success)|tostring(role or "")
```

`role` 是认证服务器当场从 `/auth/users.db` 读到的真实角色，原样参与签名（存的
`guest` 就发 `guest`）；服务器不再把缺失角色回退成 `guest`，角色为空或未知时直接
`success = false`。终端收到后会用 `/auth/role_policy.lua` 再校验一遍，并拒绝
`success = true` 但角色缺失/未知的回包（见 6.3）。

终端的回包频道是随机值（1000..9999）；`nonce_c`、`nonce_s` 由
`tostring(math.random()) .. tostring(os.epoch("utc"))` 生成，审计 `nonce` 是
`tostring(math.random()) .. timestamp`。盐、认证与开门三段交换各给 8 秒超时，登录前
预检 2 秒，开机自检 3 秒。协议层不自动重试：超时就重输口令。

## 1. 系统组成

| 角色 | 数量 | 职责 | 频道 | 关键要求 |
|---|---|---|---|---|
| 认证服务器 | 1 台 | 广播心跳；处理取盐、认证与 `open_request`；本机根控制台管理用户与终端密钥；用左侧红石执行开门 | 1 | 同一有线网络里必须唯一；左侧红石接门禁 |
| 审计服务器 | 1 台 | 验签、防重放、限速、去重、链式落盘、归档换盘、回执 | 2 | 需要终端密钥库副本与驱动器 |
| 客户端终端 | 1 台起 | 登录、菜单、发起 `open_request`、退出；把动作写进审计队列 | 1（发送）、随机回包频道、2（审计/回执） | 需要有线 modem 与 PSK；没有门禁红石 |

认证服务器和审计服务器可以同时在线，互不依赖；一台机器不会同时承担两种角色。认证服务器
与客户端终端都放同一份 `/auth/role_policy.lua`，让部署里的角色定义只有一份来源（审计
服务器只校验签名字符串里的 `role`，不做角色判定，因此不需要它）。

## 2. 部署文件映射（仓库目录 -> 游戏内平铺路径）

游戏内目录是平铺的：`/startup.lua`、`/auth/*.lua`、`/system/*.lua`、`/sha256.lua`。
仓库里的 `.lua` 文件保持原文件名，按下面的表放到对应路径即可。

### 2.1 认证服务器

| 游戏内路径 | 仓库来源 |
|---|---|
| `/sha256.lua` | `sentinel/common/sha256.lua` |
| `/startup.lua` | `sentinel/auth_server/startup.lua` |
| `/auth/server_crypto.lua` | `sentinel/auth_server/auth/server_crypto.lua` |
| `/auth/terminal_keys.lua` | `sentinel/auth_server/auth/terminal_keys.lua` |
| `/auth/user_manager.lua` | `sentinel/terminal/auth/user_manager.lua` |
| `/auth/role_policy.lua` | `sentinel/common/role_policy.lua` |
| `/system/auth_server.lua` | `sentinel/auth_server/system/auth_server.lua` |
| `/system/user_admin.lua` | `sentinel/auth_server/system/user_admin.lua` |

运行时生成：`/auth/server_id`（首次启动写入，24 位字母数字，之后永不更换）、
`/auth/users.db`（用户库）、`/auth/terminal_keys.db`（终端密钥库）。

### 2.2 审计服务器

| 游戏内路径 | 仓库来源 |
|---|---|
| `/sha256.lua` | `sentinel/common/sha256.lua` |
| `/startup.lua` | `sentinel/audit_server/startup.lua` |
| `/auth/server_crypto.lua` | `sentinel/auth_server/auth/server_crypto.lua` |
| `/auth/terminal_keys.lua` | `sentinel/auth_server/auth/terminal_keys.lua` |
| `/auth/terminal_keys.db` | 从认证服务器复制，见 5.1（必须） |
| `/auth/audit_config.lua` | `sentinel/audit_server/auth/audit_config.lua` |
| `/system/audit_server.lua` | `sentinel/audit_server/system/audit_server.lua` |

运行时生成：`/logs/seg_NNNN.log`、`/logs/chain.state`、`/auth/audit_fault.flag`、
`/auth/audit_error.log`、`/swap.retry`（仅换盘重试时出现）。

### 2.3 客户端终端

| 游戏内路径 | 仓库来源 |
|---|---|
| `/sha256.lua` | `sentinel/common/sha256.lua` |
| `/startup.lua` | `sentinel/terminal/startup.lua` |
| `/auth/role_policy.lua` | `sentinel/common/role_policy.lua` |
| `/auth/login.lua` | `sentinel/terminal/auth/login.lua` |
| `/auth/login_client.lua` | `sentinel/terminal/auth/login_client.lua` |
| `/auth/login_standalone.lua` | `sentinel/terminal/auth/login_standalone.lua`（仅作离线模式拒绝兜底） |
| `/auth/psk.lua` | `sentinel/terminal/auth/psk.lua` |
| `/auth/psk.txt` | `sentinel/terminal/auth/psk.txt`（换成控制台发给你的密钥） |
| `/auth/terminal_id.txt` | `sentinel/terminal/auth/terminal_id.txt`（换成控制台登记的 ID） |
| `/auth/session.lua` | `sentinel/terminal/auth/session.lua` |
| `/system/sandbox.lua` | `sentinel/terminal/system/sandbox.lua` |
| `/system/netcheck.lua` | `sentinel/terminal/system/netcheck.lua` |
| `/system/audit.lua` | `sentinel/terminal/system/audit.lua` |
| `/system/kernel.lua` | `sentinel/terminal/system/kernel.lua` |
| `/system/ui.lua` | `sentinel/terminal/system/ui.lua` |

运行时生成：`/audit_queue/<nonce>.evt`（审计队列）、`/lock.flag`（自检失败时）、
`/anti.txt`（退出 CraftOS 的两阶段标记）。客户端不部署 `/auth/users.db` 与
`/auth/user_manager.lua`，也不再有 `/auth/mode.lua`（见 2.4）。

### 2.4 独立终端（已废弃）

独立/离线终端模式在 stage-1 改造中退役：`/auth/mode.lua` 已从仓库删除，即使机器上还留着
旧文件也会被忽略；`/auth/login.lua` 始终加载 `login_client.lua`。`login_standalone.lua`
保留为拒绝模块，任何调用都会报：

```
Offline mode is disabled. Connect to the auth server.
```

所以不再有“独立终端”这第三种部署：不要往终端复制 `/auth/users.db` 或
`/auth/user_manager.lua`，终端也不做任何本地账号校验或本地授权。原独立终端机器要改为
2.3 的客户端部署（补 `/auth/psk.lua`、`/auth/psk.txt`、`/auth/terminal_id.txt`、
`/system/netcheck.lua` 与 `/auth/role_policy.lua`），原有账号迁移到认证服务器的
`/auth/users.db`（root 仍只由 `setup_root.lua` 创建）。

## 3. 前置条件与接线

- 运行环境：CraftOS（CraftOS-PC 2.8 实测；代码只使用 Lua 5.1/5.2 子集与 CraftOS 自带
  API，可在 CC:Tweaked 的 CraftOS 上运行）。所有游戏内文件必须是 ASCII 文件名与 ASCII
  内容，终端屏幕无法渲染中文文件名。
- 网络：只支持**有线 modem**。无线 modem 会被明确拒绝（认证服务器打印
  `FATAL: wireless modem is not supported`，终端自检报 `wireless modem`）。
- 认证服务器：至少一块有线 modem，接在与其他机器相同的物理有线网络上；**左侧**
  `left` 红石输出接到门/金库机构（同意 `open_request` 时输出 1 秒脉冲）。必须部署
  `/auth/role_policy.lua`：缺失时登录一律 `success = false`、开门一律拒绝，根控制台也会
  拒绝 root 登录。
- 审计服务器：至少一块有线 modem（同一网络）；一台 `drive` 外设（按名字排序取第一台）
  与配套软盘；红石输出接到换盘机构，默认背面 `back`。
- 终端：至少一块有线 modem 与 PSK；**不再需要门禁红石**，开门由认证服务器执行。
- 建议给所有机器做世界内备份：`/auth/users.db`、`/auth/terminal_keys.db`、
  `/auth/server_id`、`/logs/chain.state` 丢失的代价各不相同，见第 11 节。

## 4. 认证服务器

### 4.1 部署与启动

按 2.1 放好文件后重启。`/startup.lua` 同时运行两个程序：认证服务
（`/system/auth_server.lua`）和根控制台（`/system/user_admin.lua`）。两者共用同一块
屏幕，控制台退出后 1 秒会自动重新进入。

正常启动横幅：

```
Auth Server
Protocol:  secure_auth_v5
Server ID: <24 位字母数字>
```

之后服务每秒在频道 1 广播 `heartbeat`，并监听 `salt_request`、`auth_request` 与
`open_request`；同意开门时在本机左侧红石输出 1 秒脉冲。缺 modem 时打印
`FATAL: no wired modem` / `Attach a wired modem and reboot.`，服务停机，但本机的根控制台
仍随 `/startup.lua` 一起运行，不会掉回 shell。

### 4.2 创建第一个 root

用户库里没有任何 root 时，控制台会提示：

```
No accounts in /auth/users.db.
Run setup_root.lua to create the first root account.
```

把 `sentinel/setup_root.lua` 复制成服务器上的 `/setup_root.lua`，在 shell 里运行一次：

```
Sentinel Root Setup (one-time)

Username: <名字>
Password: <口令>
[OK] Root account '<name>' created.
```

它直接写 `/auth/users.db`（`salt` 16 位字母数字，`hash = sha256(password .. salt)`，
`role = "root"`）。只要库里已经存在任何 root，它就会打印
`A root account already exists.` 与 `Setup refused.` 并退出；因此这是纯一次性工具，
用完可以删掉，不参与日常运行。root 不能从任何菜单创建。

### 4.3 根控制台与终端密钥

用刚才的 root 账号登录控制台。登录时输入 `Username: ` 与 `Password: `（口令遮蔽）；
用户名或口令留空会直接退出控制台，1 秒后自动重启控制台。只有
`role_policy.allows(role, "root")` 通过的账号才能进入控制台（即 root 权重）；口令错误
打印 `Access denied.`，等待 1 秒后可重试。`/auth/role_policy.lua` 缺失时登录界面会打印
`WARNING: /auth/role_policy.lua is not loadable`，此时任何账号都会被拒绝。主菜单：

```
User Admin (server only)
User: <name> (root)

1. Add User
2. Delete User
3. List Users
4. Change Role
5. Manage Terminal Keys
0. Exit
```

- 增加用户、删除用户、修改角色都经过共享的 `/auth/user_manager.lua`；Add User 与
  Change Role 的提示是 `Role (admin/operator/user/guest): `，直接回车默认 `guest`。
  规则见第 11 节。
- `5. Manage Terminal Keys` 的子菜单是 `1. List`、`2. Add / Show Key`、`3. Remove`、
  `0. Back`。给终端登记时选 `2`，输入 `Terminal ID: `，输出形如：

  ```
  Terminal ID: <id>
  Key:         <32 位字母数字>

  Write this key into /auth/psk.txt
  Write the ID into /auth/terminal_id.txt
  on that terminal.
  ```

  同一个 ID 再次执行 Add 会返回原来的密钥（不会换新）。`3. Remove` 需要输入字面量
  `yes` 确认。终端 ID 允许空格，不允许 `|` 与控制字符，最长 64 字符。

### 4.4 `/auth/user_manager.lua` 与 `/auth/role_policy.lua` 是认证链路的一部分

服务通过 `/auth/user_manager.lua` 的 `getSalt(name)`、`verifyDerived(name, derived,
nonceC, nonceS)` 完成取盐与口令校验，并在每次 `open_request` 时用 `getRole(name)` 当场
读出账号在 `users.db` 里的原始角色。角色**如何解释**不在 `user_manager` 里，而由
`/auth/role_policy.lua` 决定：认证链路用 `normalize` 校验角色是否已知，然后把 `users.db`
里的真实角色原样签进 `auth_response`；角色为空或未知时 `auth_response` 直接
`success = false`。开门链路用 `allows(role, "operator")` 判断，未知角色一律不放行。

文件缺失或加载失败时：

- 取盐阶段仍然回包：返回固定假盐 `ffffffffffffffff` 并正常签名，避免把
  “用户不存在”暴露成超时。
- 认证阶段一律返回 `success = false` / `message = "Invalid credentials"`，即所有登录
  都会失败，但服务不会崩溃。
- `open_request` 一律按拒绝回包（`open_response` 的 `ok = false`、`reason = "denied"`），
  不会触发红石。
- 控制台启动时会打印 `WARNING: /auth/user_manager.lua is not loadable`；列表用户等
  操作会打印 `[Error] /auth/user_manager.lua is not loadable`。缺 `role_policy.lua` 时
  登录界面打印 `WARNING: /auth/role_policy.lua is not loadable`，任何账号都进不了控制台。

所以部署认证服务器时，务必把 `sentinel/terminal/auth/user_manager.lua` 放到
`/auth/user_manager.lua`，并把 `sentinel/common/role_policy.lua` 放到
`/auth/role_policy.lua`。

### 4.5 重放保护

服务按“终端 + 阶段 + nonce”记录最近 15 秒内见过的 nonce（每个终端最多保留 32 条，
超过 64 个终端时淘汰最久没出现的）。取盐（`salt`）、认证（`auth`）与开门（`open`）三个
阶段分别记录：正常登录中取盐与认证可以复用同一个 `nonce_c`，不会被误判；但同一阶段的
同名请求在窗口内再次出现会被直接忽略（不回包）。`open_request` 用的是它自己的 `nonce`
字段。窗口外的重放不在防护范围内。

### 4.6 开门请求 `open_request`

开门动作只发生在认证服务器：终端只能“申请”，不能自己给红石。完整流程：

1. 已登录的终端在菜单里选 `Open Vault`，用当前会话用户名生成一次性 `nonce`，发送
   `open_request`（频道 1，回包频道随机）：

   ```
   terminal_id, username, nonce, sig = sha256(PSK .. "|" .. terminal_id .. "|" .. username .. "|" .. nonce)
   ```

2. 认证服务器先用 `/auth/terminal_keys.db` 验证签名。未登记/未知终端**不会收到任何
   回包**（服务器没有它的密钥，无法签回包），终端侧表现为超时。
3. 签名通过后，服务器当场从 `/auth/users.db` 读取 `username` 的角色，调用
   `/auth/role_policy.lua` 的 `allows(role, "operator")`。因此 operator、admin、root
   都可以开门，user（含历史别名 guest）不行，未知角色一律不行。
4. 通过则在本机**左侧红石**输出 1 秒脉冲，然后回包：

   ```
   open_response: ok = true, reason = "granted"
   ```

   不通过则只回包、不脉冲红石：

   ```
   open_response: ok = false, reason = "denied"
   ```

5. `open_response` 的字段是 `protocol / type / server_id / terminal_id / nonce_c / ok /
   reason / sig`，签名字符串为：

   ```
   open_response: server_id|nonce|tostring(ok)|reason
   ```

   终端校验 `protocol`、`type`、`terminal_id`、`nonce` 与签名后才采信结果。

服务器不校验口令，只校验“这台终端是否合法”以及“该用户名当前的角色是否够用”。用户名
来自终端会话，终端软件负责只把它自己的登录用户放进请求；能改终端程序的人本来就能读到
本机 PSK（见第 11 节）。同一个 `nonce` 在 15 秒重放窗口内再次到达会被静默忽略。

## 5. 审计服务器

### 5.1 部署与 `/auth/terminal_keys.db`

按 2.2 放好文件，然后**把认证服务器上的 `/auth/terminal_keys.db` 复制到审计服务器同
路径**。审计服务器用同一份终端密钥库验签；文件缺失或过期会导致事件全部验签失败，而
审计侧对失败是静默丢弃（无回包、无错误日志），表现为“终端一直重发、日志不增长”。

### 5.2 启动横幅与致命错误

正常启动：

```
Audit Server
Channel: 2
Logs:    /logs
Ready.
```

配置缺失/语法错误、`/sha256.lua` 或 `/auth/server_crypto.lua` 加载失败、`/logs` 无法
创建、找不到可用有线 modem、配置的 `main_modem_side` 不存在或是无线 modem，都会写
故障标志 `/auth/audit_fault.flag`（格式 `reason: <文本>` 与 `time: <epoch 毫秒>` 两行），
打印 `FATAL: <原因>` 后停机。`/startup.lua` 自身加载不到
`/system/audit_server.lua` 时只打印 `FATAL: cannot load /system/audit_server.lua`。

`main_modem_side = nil` 表示自动选择：按外设名字排序后的第一块有线 modem。

### 5.3 事件处理顺序

每条 `modem_message` 先过频道、`protocol`、`type = "audit_event"` 三道门，再依次：

1. 字段与时间戳检查（`role` 必须是字符串；`timestamp` 必须是可转为非负数字的字符串）。
2. 验签：`sha256(PSK .. "|" .. terminal_id .. "|" .. username .. "|" .. role .. "|" .. action .. "|" .. timestamp .. "|" .. nonce)`。
3. 重放检查：同一终端、同一 `nonce` 已在窗口内 → 视为重复，重发同一份 `audit_ack`，
   **不再写日志**。
4. 限速：每终端 1 秒固定窗口，最多 `rate_per_sec` 条。
5. 去重：`terminal_id|username|action` 在 `dedup_window_ms` 内最多 `dedup_burst_max` 条。
6. 写日志、记 nonce、回 `audit_ack`（频道 2，签名 `nonce|terminal_id`）。

任何一步失败都只是丢弃，不发送任何错误响应。因此终端侧看到的表现只有“队列迟迟不
清空”。第 3 步的幂等回执是刻意的：ack 在网络上丢失时，终端 10 秒后会重发同一事件，
审计服务器再回一次 ack，不会产生重复日志。

### 5.4 分段、轮转与哈希链

- 日志目录默认 `/logs`，分段文件 `seg_0001.log`、`seg_0002.log`……启动时取编号最大的
  一段作为当前段；不存在则创建 `seg_0001.log`。
- 写每行之前检查当前段行数：达到 `max_segment_lines` 就切到下一段（新段为空文件）。
- 每行格式（UTC 时间，来自事件里的 `timestamp`）：

  ```
  [YYYY-MM-DD HH:MM:SS] TERMINAL=<id> USER=<user> ROLE=<role> ACTION=<action> PREV=<64 hex> HASH=<64 hex>
  ```

- `HASH = sha256(PREV .. "|" .. body)`，其中 `body` 是不含 `PREV=`/`HASH=` 的前缀
  `[time] TERMINAL=... USER=... ROLE=... ACTION=...`。新链的起点 `PREV=GENESIS`。
- `/logs/chain.state` 保存当前链头（64 位十六进制，无换行）。文件缺失或内容不是 64 位
  十六进制时，链从 `GENESIS` 重新开始。
- 每次写入后屏幕顶行显示 `seg_NNNN  hash=<链头前 12 位>`。

验证链（在游戏内 shell 里用，逐段按编号顺序执行）：

```lua
local sha = dofile("/sha256.lua")
local prev = "GENESIS"
for n = 1, 99 do
    local path = string.format("/logs/seg_%04d.log", n)
    if not fs.exists(path) then break end
    local text = fs.open(path, "r").readAll()
    for line in text:gmatch("[^\n]+") do
        local body, pHash, hHash = line:match("^(.-) PREV=(%x+) HASH=(%x+)$")
        local want = sha.hash(prev .. "|" .. body)
        assert(pHash == prev, "PREV 不连续: " .. line)
        assert(hHash == want, "HASH 不匹配: " .. line)
        prev = hHash
    end
end
print("chain ok, head " .. prev)
```

注意两点：归档到软盘后的旧段会从本机删除，完整验证需要按编号把软盘里的段一起算；
`chain.state` 只证明当前链头，不证明历史，删除它会让下一条日志从 `GENESIS` 重新起链。

### 5.5 归档与换盘

归档循环每 `archive_retry_interval` 秒运行一次：

1. 列出 `/logs` 中所有段；本机至少保留最新的 `local_keep_segments` 段。
2. 在 `/disk*` 挂载点里找第一个剩余空间 ≥ `min_free_space` 的软盘。
3. 对每份要归档的旧段：复制到 `<挂载点>/seg_NNNN.log`，比较源与目标文件大小，一致才
   删除源文件。复制失败则保留源文件，下次再试。
4. 只要本轮真的归档了至少一个文件，就触发一次换盘脉冲：
   - 红石 `redstone_side` 输出 1，等待 `pulse_seconds`，输出 0，再等待
     `swap_wait_seconds`；
   - 通过驱动器 `getDiskID` 判断磁盘是否真的换了：快照取值
     `no-drive` / `empty` / `id:<磁盘ID>` / `unknown`，前后不同即成功；
   - 失败时只自动重试一次，重试资格用 `/swap.retry` 标记；成功清掉标记。
5. 换盘成功：`swap_fault` 写回 0；失败：`swap_fault` 写回 1，红石输出持续 2。

没有驱动器时没有 `/disk*` 挂载，归档循环什么也做不了（不会写日志、不会报错）；
如果 `swap()` 被直接调用而没有驱动器，会立即进入失败路径（写 `swap_fault = 1` 并输出
信号 2）。

### 5.6 故障标志、错误日志与启动恢复

- 故障标志 `/auth/audit_fault.flag`：

  ```
  reason: <文本>
  time: <epoch 毫秒>
  ```

- 运行期监督日志 `/auth/audit_error.log`，每行
  `[YYYY-MM-DD HH:MM:SS] <消息>`（UTC）。三个循环 `heartbeat`、`archive`、`listen`
  各自被监督：函数正常返回会记 `<name> exited; restarting`；抛错记
  `<name> error: <错误>`，连续错误计数加一。任意一次成功迭代都会把计数清零。达到
  `max_consecutive_errors` 时写故障标志、红石输出 2、永久停机。
- 启动时若配置里 `swap_fault == 1`，会先打印：

  ```
  SWAP FAULT DETECTED ON BOOT
  Attempting recovery swap...
  ```

  做一次不带重试的换盘尝试，然后重新读取配置：

  - 成功：删除 `/swap.retry`，把 `swap_fault` 写回 0，打印
    `RECOVERY SUCCESSFUL` 与 `swap_fault reset to 0.`；
  - 失败：打印 `RECOVERY FAILED`、`Server will run in fault mode.` 与
    `Set swap_fault = 0 in /auth/audit_config.lua to clear.`。

  最后打印 `Ready.` 并开始三个循环。若开机恢复换盘失败（包括启动时没有驱动器在内的
  任何原因），恢复流程会保持 `swap_fault = 1`，并把 `redstone_side` 输出置为 2，机器
  留在故障模式，直到维护人员按提示清除；恢复成功时红石为低电平、`swap_fault` 写回 0。

服务器改写配置时只改 `swap_fault` 这一项，但会把整个文件按“默认值 + 你的覆盖值、键名
排序”重新序列化，所以手写注释会在第一次故障/恢复后丢失；其余键保持你设置的值。

## 6. 客户端终端

### 6.1 两个数据文件

- `/auth/psk.txt`：一行 32 字符密钥；读取时去掉所有空白字符。与控制台 `Add / Show Key`
  给出的 `Key` 必须完全一致。
- `/auth/terminal_id.txt`：一行终端 ID；读取时去掉所有空白。文件缺失或为空时依次回退
  到 `os.getComputerLabel()`，再回退到 `computer_<computerID>`。建议始终显式写文件，
  与控制台登记的 ID 一致。

终端还部署纯模块 `/auth/role_policy.lua`（`sentinel/common/role_policy.lua`）：它不含
任何账号数据，只负责规范化服务器发回的角色（`normalize`/`weight`）和菜单授权判断
（`allows`）。终端上没有 `/auth/mode.lua`、`/auth/users.db`，也没有
`/auth/user_manager.lua`。

### 6.2 开机自检（netcheck）

启动顺序固定：

1. 加载 `/system/sandbox.lua`；失败打印 `FATAL: cannot load sandbox` 并停机。
2. `os.pullEvent = os.pullEventRaw`，屏蔽 Ctrl+T。
3. 加载 `/system/netcheck.lua`（失败写 `/lock.flag` = `cannot load netcheck` 并停机），
   然后调用 `check(3)`：在有线 modem 上打开频道 1，3 秒窗口内统计 `heartbeat` 里不同
   `server_id` 的个数。
4. 判定规则：
   - 恰好 1 个服务器：通过，删除 `/lock.flag`（只有通过才会删）。
   - 0 个：`no server detected`。
   - 2 个及以上：`multiple servers: N`。
   - 没有 modem：`no modem`；只有无线 modem：`wireless modem`。
   - 自检过程抛错/打开频道失败：`check interrupted`。
5. 不通过时把原因写入 `/lock.flag`，屏幕打印：

   ```
   NETWORK SECURITY CHECK FAILED
   Reason: <原因>

   Fix the network and reboot.
   ```

   然后停机等待，不进入登录。
6. `/anti.txt` 两阶段处理（见 6.6），最后才进入 `/system/kernel.lua`。

### 6.3 登录

登录界面：

```
Secure Terminal

Username: <输入>
Password: <遮蔽输入>
Authenticating...
```

用户名或口令为空会静默放弃本次登录，回到内核循环。非空时先做 2 秒网络预检，再依次：

1. `salt_request`（签名 `terminal_id|username|nonce_c`）发到频道 1，回包频道随机。
2. 等 `salt_response` 最多 8 秒，校验 `channel` 等于自己的回包频道、`protocol`、
   `type`、`terminal_id`，再用本地 `nonce_c` 验证签名（服务器回包不强制带 `nonce_c`）。
3. 计算 `H'` 并发送 `auth_request`，再等 8 秒，校验 `auth_response`（含
   `success`/`role`/`message`）的签名：签名覆盖 `success` 与 `role`，服务端角色必须存在，
   客户端还要用 `/auth/role_policy.lua` 的 `normalize` 验证；`success = true` 但角色
   缺失/未知的回包按登录失败处理，绝不默认成 `guest`。
4. 成功返回 `{ name, role }` 并让内核建立会话；失败按原因打印：

   | 情况 | 屏幕输出 |
   |---|---|
   | 取盐 8 秒无回包 | `[Error] salt timeout` |
   | 取盐回包验签失败 | `[Error] salt signature invalid` |
   | 认证 8 秒无回包 | `[Error] Server timeout.` |
   | 认证回包验签失败 | `[Error] signature invalid` |
   | 服务器返回 success=false | `[Error] Invalid credentials` |
   | success=true 但没有合法角色 | `[Error] Server returned no usable role.` |
   | 预检失败 | `[Error] network check: <原因>` |
   | PSK 文件缺失/为空 | `[Error] PSK file not found: /auth/psk.txt` 或 `[Error] PSK is empty.` |

登录成功写审计动作 `LOGIN_SUCCESS`（带服务器下发的 role）；凭据错误、验签失败与角色异常
写 `LOGIN_FAIL`（role 记为空串）；超时写 `LOGIN_FAIL_TIMEOUT`（role 为空串）。协议层
不重试，用户看到错误后重新输入。

会话只存在内存里，令牌有效期 1 小时；`Logout` 会销毁令牌。

### 6.4 菜单与权限

```
Secure System
User: <name> (<role>)

1. Open Vault
2. ...
0. Logout (shortcut)

Select an option: 
```

条目按顺序动态生成：

| 序号 | 条目 | 可见条件 |
|---|---|---|
| 1 | `Open Vault` | 所有人 |
| 2..4 | `Add User`、`Delete User`、`Change Role` | `role_policy.allows(role, "root")` 通过且 `/auth/user_manager.lua` 可加载 |
| 最后 | `Exit to CraftOS` | `role_policy.allows(role, "root")` 通过 |
| 末条 | `Logout` | 所有人 |

`0` 是 `Logout (shortcut)`，始终存在。客户端终端不部署 `user_manager.lua`，所以即使
是 root，在客户端也只会看到 `Open Vault`、`Exit to CraftOS`、`Logout` 三项；
Add/Delete/Change Role 只有在机器上额外部署了 `/auth/user_manager.lua` 时才会出现。
角色判断统一走 `/auth/role_policy.lua`，不再有硬编码的 `role == "root"`。

输入数字选择；非法输入被静默忽略并重新显示菜单。条目执行后等待 0.5 秒再回到菜单。

子菜单与提示：

- Add User：`=== Add User ===`，依次问 `Username: `、`Password: `、
  `Role (admin/operator/user/guest): `（直接回车 = `user`；`guest` 仍接受，是 `user` 的
  历史别名）。角色非法时打印 `[Error] Invalid role: <r>`、
  `Allowed: admin, operator, user, guest`；填 `root` 时额外打印
  `Root accounts cannot be created through UI.`。
- Delete User：`=== Delete User ===`，问 `Confirm delete '<u>'? (yes/no): `，只有字面量
  `yes` 才会执行，其他输入静默取消。
- Change Role：`=== Change Role ===`，问用户名与新角色，规则同上。
- 结果统一打印 `[OK] <消息>` 或 `[Error] <消息>`，随后 `Press Enter to return...`。

### 6.5 Open Vault

打印 `Requesting vault access from auth server...`，先做 2 秒网络预检，再向认证服务器发送
带签名的 `open_request`（见 4.6），然后只按服务器回包显示结果：

| 结果 | 屏幕输出 | 后续 |
|---|---|---|
| 服务器 `ok = true` | `[OK] Vault opened by auth server.` | 结束本次会话，回到登录 |
| 服务器拒绝（`ok = false`） | `[Denied] Access denied by auth server.` | 等待 2 秒回到菜单 |
| 网络预检失败/无 modem | `[Error] Auth server unreachable.` | 等待 2 秒回到菜单 |
| 8 秒内没有回包 | `[Error] Auth server did not answer.` | 等待 2 秒回到菜单 |
| 回包字段/签名不合法 | `[Denied] Invalid response ...` | 等待 2 秒回到菜单 |

终端**不接门禁红石、也不输出任何开门信号**；1 秒脉冲由认证服务器在本机左侧执行。服务器
对未登记终端根本不回包，所以那种情况在终端上表现为
`[Error] Auth server did not answer.`，而不是明确的拒绝。

### 6.6 Exit to CraftOS 与 `/anti.txt`

只有 `role_policy.allows(role, "root")` 通过的账号能选。流程是两阶段的：

1. 菜单中选退出：打印 `Security Check Required` 与 `Enter password: `，重新走一次完整
   网络认证（由认证服务器校验）。
2. 口令错误：打印 `Incorrect password.`，等待 2 秒，回到菜单。
3. 口令正确：打印 `Password correct. Exiting to CraftOS...`，把 `/anti.txt` 写成
   `anti=1`，等待 1 秒，恢复沙箱（把砍掉的函数装回去），然后 `os.reboot()`。
4. 下次开机时 `/anti.txt` 已经是 `anti=1`，启动脚本把它改写成 `anti=2` 并**直接返回**，
   这一次启动会落到 CraftOS shell，而不是重新进登录。
5. 再下一次启动看到 `anti=2`，删除该文件，正常进入内核与登录。

所以完全退到 shell 需要两次重启，这是为了避免一次重启就永久留在 shell；普通重启（没有
`/anti.txt`）不受影响。

### 6.7 沙箱

内核启动后立即 `sandbox.init()`：

- `os.pullEvent` 被替换为 `os.pullEventRaw`，Ctrl+T 触发的 `terminate` 不会结束会话。
- `shell`、`commands`、`fs.delete`、`fs.move`、`os.shutdown`、`os.reboot` 全部置空，
  登录后的用户拿不到删除文件、移动文件、关机、重启、开 shell 的入口。
- 只有 `Exit to CraftOS` 成功时会调用 `sandbox.restore()` 把这些函数和事件通道恢复，
  随后立刻重启。其它路径不恢复。

### 6.8 审计队列（每 10 秒重发，收到有效 ack 才删除）

内核在另一个协程里运行审计：

- `audit.start()` 要求有 PSK、有有线 modem，并在频道 2 上 `open` 后才开始循环；
  失败原因 `no psk` / `no modem` / `wireless modem` 由内核每 5 秒重试。
- `log(username, role, action)` 生成 `timestamp` 与 `nonce`，签名串为
  `terminal_id|username|role|action|timestamp|nonce`，把**完整事件表**（含 `role` 字段）
  序列化到 `/audit_queue/<nonce>.evt`，然后尽力发送一次。登录失败时 `role` 记为空串。
  没有 PSK 时它不会入队（返回 false），因为无法签名的事件永远不会被审计服务器接受。
- 每 10 秒扫描一次队列，把所有 `.evt` 重新发到频道 2。
- 收到 `audit_ack` 时校验：`protocol`、`type`、`terminal_id` 等于自己、签名
  `nonce|terminal_id` 用本机 PSK 验证通过；只有通过才删除对应队列文件。签名错误、
  别家的 ack、其它频道上的 ack 都会被忽略。
- 队列文件跨重启保留，下次启动会继续重发；重复事件由审计服务器的幂等回执兜底，不会
  写重复日志。

## 7. 独立终端（已退役）

stage-1 改造后只有一种终端部署：必须连接认证服务器的客户端终端（2.3）。离线校验在本机
完成、开门也在本机授权的那套独立终端已从架构中删除，原因很直接：

- 终端持有对称 PSK，能在本地伪造任意 role 的 `auth_response`；
- 终端在本机执行红石，所以“终端侧权限门”只能防误操作，挡不住改程序的人。

改造后的边界是：权限跟随账户（角色只在认证服务器的 `/auth/users.db`），终端只用 PSK
证明自己是合法终端，开门由认证服务器执行。具体变化：

| 项目 | 旧独立终端 | 现在 |
|---|---|---|
| 登录模块 | `/auth/login_standalone.lua` 本地比对 | `login.lua` 始终加载 `login_client.lua`；`login_standalone.lua` 只负责报 `Offline mode is disabled. Connect to the auth server.` |
| `/auth/mode.lua` | 切换 client/standalone | 已删除；旧文件被忽略 |
| 本地账号库 | 终端 `/auth/users.db` + `user_manager.lua` | 终端不部署；账号只在认证服务器 |
| 开机自检 | 不做 | 始终做 3 秒 netcheck，失败锁机 |
| 审计 | 不写队列、不联网 | 始终签名入队并发往审计服务器 |
| 开门 | 本机 left 红石 | 发 `open_request`，由认证服务器脉冲 |
| Exit to CraftOS 复核 | 本地库 | 网络重认证 |

把旧独立终端改为客户端部署的步骤：删掉本机 `/auth/users.db`、`/auth/user_manager.lua`
与 `/auth/mode.lua`；按 2.3 补齐 `/auth/psk.lua`、`/auth/psk.txt`、
`/auth/terminal_id.txt`、`/system/netcheck.lua` 与 `/auth/role_policy.lua`；在认证服务器
控制台登记该终端（见 4.3），并把原有账号重建到认证服务器的 `/auth/users.db`（没有自动
迁移工具；root 仍只由 `setup_root.lua` 创建）。

## 8. `/auth/audit_config.lua` 全量参考

服务器启动时读取一次这个表，缺省值在代码里另有一份，文件里的键会覆盖缺省值。键名、
默认值、含义：

| 键 | 默认值 | 含义 |
|---|---|---|
| `main_channel` | `2` | 审计频道（收发都用它） |
| `protocol` | `"secure_auth_v5"` | 协议字符串，必须与终端一致 |
| `main_modem_side` | `nil` | 指定 modem 侧；`nil` 表示自动取排序后第一块有线 modem |
| `heartbeat_interval` | `5` | `audit_heartbeat` 广播间隔（秒） |
| `logs_dir` | `"/logs"` | 日志目录 |
| `max_segment_lines` | `500` | 单个分段文件的最大行数，写前检查并轮转 |
| `local_keep_segments` | `2` | 本机保留的最新段数，其余归档到软盘 |
| `min_free_space` | `8192` | 归档盘的最小剩余空间（字节） |
| `archive_retry_interval` | `30` | 归档循环间隔（秒） |
| `rate_per_sec` | `5` | 每终端 1 秒窗口内允许的事件数 |
| `nonce_window` | `10000` | 每终端 nonce 记忆条数上限，超过后丢最旧一半 |
| `dedup_window_ms` | `2000` | 去重窗口（毫秒） |
| `dedup_burst_max` | `5` | 去重窗口内同一 `terminal_id\|username\|action` 的最大条数 |
| `dedup_cleanup_interval` | `10000` | 去重表清理间隔（毫秒） |
| `redstone_side` | `"back"` | 换盘信号输出侧 |
| `pulse_seconds` | `2` | 换盘脉冲高电平持续时间（秒） |
| `swap_wait_seconds` | `5` | 脉冲后等待换盘完成的秒数 |
| `max_consecutive_errors` | `5` | 连续错误达到该值时写故障标志并停机 |
| `fault_flag` | `"/auth/audit_fault.flag"` | 故障标志文件 |
| `error_log` | `"/auth/audit_error.log"` | 监督错误日志 |
| `restart_delay_seconds` | `3` | 循环重启前的等待（秒） |
| `swap_fault` | `0` | 换盘故障状态；服务器会在故障/恢复时改写它 |

注意：为了持久化 `swap_fault`，服务器会把整个文件重新序列化（键名排序、默认值合并），
因此手写注释会在第一次改写后丢失；修改配置后建议重启审计服务器。

## 9. 接线与部署检查

```
[认证服务器]---有线 modem---+
                            |
[审计服务器]---有线 modem---+--- 同一个有线网络（频道 1、2 共用）
                            |
[客户端终端 1..N]---有线 modem---+

[认证服务器 left 红石] ---> 门/金库机构（同意 open_request 时 1 秒脉冲）
[审计服务器 back 红石] ---> 换盘机构（信号 1 = 换盘脉冲，信号 2 = 故障）
[审计服务器 drive] <--- 软盘（插入后出现 /disk* 挂载点）
```

部署前检查：

- 所有 modem 都是**有线** modem，且在同一物理有线网络里。
- 认证服务器只有一台在广播；多台会让终端自检报 `multiple servers: N`。
- 认证服务器的左侧红石确实接到门禁；`Open Vault` 只是 1 秒脉冲，不会保持常亮。
- 审计服务器的 `redstone_side` 与实际接线一致；驱动器与换盘机构可用。
- 终端不需要、也不应该接门禁红石；它的开门能力只来自认证服务器的回包。
- 认证服务器与客户端终端都放了同一份 `/auth/role_policy.lua`，且认证服务器的
  `/auth/users.db` 里每个账号都有合法角色。
- 所有文件名、路径为 ASCII；CraftOS 屏幕不显示中文文件名。
- 认证服务器与审计服务器的时间不必同步，但日志时间取自终端上报的 `timestamp`。

## 10. 故障排查

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 开机 `NETWORK SECURITY CHECK FAILED` / `Reason: no modem` | 没接 modem 或只接了无线 modem | 接有线 modem 后重启 |
| `Reason: wireless modem` | 网络里只有无线 modem | 换有线 modem；协议不支持无线 |
| `Reason: no server detected` | 认证服务器没开、没接同一网络，或心跳没发出 | 看认证服务器横幅；检查 modem 与网络 |
| `Reason: multiple servers: N` | 网络里有多台认证服务器在广播 | 只保留一台，其余关机或拆 modem |
| `Reason: check interrupted` | 打开频道失败或自检被打断 | 重启终端；检查 modem 是否被其它程序占用 |
| 登录总是 `[Error] salt timeout` | `terminal_id` 未登记，或 PSK 与服务器登记不一致（验签失败不回包） | 控制台 `Manage Terminal Keys` 核对后重写两个文件 |
| `[Error] Server timeout.` | 认证请求 8 秒内无回包 | 检查网络与服务器负载；重启认证服务器 |
| `[Error] Invalid credentials` | 口令错误；服务器缺 `/auth/user_manager.lua`；或账号角色缺失/未知导致服务端 `success = false` | 先确认口令与账号角色；再检查服务器文件与 `/auth/role_policy.lua` |
| `[Error] Server returned no usable role.` | 服务器回了 `success = true`，但 role 为空或不在合法集合内；常见于 `users.db` 角色字段拼错/缺失，或终端缺 `/auth/role_policy.lua` | 在认证服务器用 `Change Role` 写成 admin/operator/user/guest；确认终端部署了 `role_policy.lua` |
| 终端报 `Offline mode is disabled. Connect to the auth server.` | 旧部署仍调用 `login_standalone.lua`（例如未更新 `login.lua`）；终端已没有本地账号库 | 按 2.3 更新登录模块，删除 `/auth/mode.lua`、`/auth/users.db` 与 `/auth/user_manager.lua` |
| `Open Vault` 显示 `[Denied] Access denied by auth server.` | 账号角色低于 operator（user/guest）；角色未知；或认证服务器缺 `/auth/role_policy.lua` | 用 root 控制台把账号改成 operator/admin；确认服务器部署了 role_policy |
| `Open Vault` 显示 `[Error] Auth server did not answer.` | 认证服务器离线/频道不对；或该终端未登记、PSK 不匹配（服务器无法验签就不回包） | 查认证服务器横幅与 `Manage Terminal Keys`；核对 `terminal_id.txt` 与 `psk.txt` |
| 有权限但门禁不动，终端显示 `[Denied]` | 认证服务器脉冲失败：没有 `redstone` API 或左侧被占用/接线错，服务器会按 denied 回包 | 检查认证服务器左侧红石接线后重试 |
| 控制台 `WARNING: /auth/role_policy.lua is not loadable` | 认证服务器缺 `role_policy.lua` | 按 2.1 部署 `/auth/role_policy.lua` |
| `[Error] salt signature invalid` / `[Error] signature invalid` | 服务器登记的密钥与终端 `psk.txt` 不一致 | 用控制台显示的原密钥重写 psk.txt |
| `[Error] network check: ...` | 登录前 2 秒预检失败 | 按冒号后的原因处理，同上面的自检原因 |
| `[Error] PSK file not found: /auth/psk.txt` | 客户端部署缺 psk.txt | 补文件并写入正确密钥 |
| 审计日志不增加，终端队列一直重发 | 审计服务器缺/旧 `terminal_keys.db`（静默丢弃）、故障停机或频道不同 | 重新复制密钥库；查审计屏幕与故障标志 |
| `/auth/audit_fault.flag` 存在 | 换盘失败、配置错误、modem 缺失或连续错误 | 读 `reason`/`time`；修复后把 `swap_fault` 改回 0 再重启 |
| 启动打印 `SWAP FAULT DETECTED ON BOOT` 后 `RECOVERY FAILED` | 上次换盘失败，磁盘/驱动器/红石未就绪 | 检查驱动器、软盘、红石接线；恢复后手动清 `swap_fault` |
| 屏幕顶上 `hash=...` 不更新 | 没有新事件写入（验签失败、限速、去重、频道不对） | 对照本节“审计日志不增加” |
| `FATAL: cannot load /system/audit_server.lua` | 审计服务器文件缺失或路径不对 | 按 2.2 补齐文件 |
| `FATAL: no wired modem` | 认证/审计服务器没有可用有线 modem | 接好有线 modem 重启 |
| 控制台 `Access denied.` | 口令错误 | 1 秒后重试；确认用的是 root 账号 |
| 控制台 `No accounts in /auth/users.db.` | 用户库为空 | 运行 `setup_root` 创建第一个 root |
| `System error, returning to login...` | 登录/菜单/审计某模块运行期抛错 | 常见于部署文件缺失或版本混搭；按第 12 节核对文件 |
| 终端屏幕被锁在自检失败画面 | `/lock.flag` 存在且自检未通过 | 修复原因后重启；只有通过 3 秒自检才会删除该文件 |

## 11. 安全说明与边界

这是“玩家可物理接触机器”的 Minecraft 场景下的实用方案，不是通用密码学产品。以下几点
需要如实了解：

1. modem 是广播介质。同一有线网络上的任何计算机都能收到频道 1 与频道 2 的报文；协议
   不做加密。口令从不上线，但用户名、角色、动作、时间、结果、`H'`、签名都是明文可见的。
2. PSK 以明文保存：终端 `/auth/psk.txt`、服务器 `/auth/terminal_keys.db`。拿到任意一份
   就能冒充对应终端签名，因此**物理安全就是系统的安全上限**；终端失窃等价于密钥泄露。
3. 纯 Lua 的 SHA-256 实现能通过行为测试，但没有常数时间/侧信道加固，也不与系统密码学
   库做兼容性承诺；不要用它保护真正重要的秘密。
4. 没有文件锁。`users.db`、`terminal_keys.db`、`audit_config.lua` 都是整读整写；服务与
   根控制台并发写同一文件时可能丢更新（terminal_keys 每次调用重读文件，缓解但不消除
   竞争）。不要在同一台机器上同时手工改这些文件。
5. 服务器身份不等于 `server_id`：`server_id` 公开用于识别，真正的身份证明是服务器用
   终端 PSK 计算的签名；没有 PSK 的第三方无法伪造响应。
6. 重放保护只覆盖 15 秒窗口，且按“终端 + 阶段 + nonce”记忆、每终端最多 32 条。更早的
   重放不会被拦截；能构造合法签名的人本来就已经持有 PSK。
7. 审计回执是幂等的：同一事件（同 `nonce`）在窗口内重复到达且签名有效时只重发 ack，不
   写第二条日志。这解决 ack 丢失导致的重复重发，但队列文件在收到有效 ack 前会一直保留。
8. 哈希链能发现行被修改、删除或插入，但 `chain.state` 和整条链都在本机文件系统上；有
   文件写权限的人可以把整条链和链头一起重写。删除 `chain.state` 会让下一行从 `GENESIS`
   起链，看起来像“新链”，因此备份与外部留存才有意义。
9. 审计事件无法签名时不会入队（不会产生永远得不到确认的 `.evt` 垃圾）。
10. root 不能从任何 UI 创建，只能在本机运行一次性的 `setup_root`；删除最后一个 root
    会被拒绝，root 账号本身不能被改角色。
11. 限速与去重是为了抑制重复与噪声，不是抗 DoS：有线网络上的第三方仍可大量发送合法
    格式的报文（但无法通过签名）。
12. 会话令牌只在内存中，有效期 1 小时；退出登录即销毁。终端的 Ctrl+T、文件删除、移动、
    关机、重启在登录期间被沙箱屏蔽，只有在 Exit to CraftOS 流程中短暂恢复。
13. 换盘故障的红石信号 2 由换盘流程与开机恢复流程共同保证：归档后的换盘失败、以及开机
    恢复换盘失败（包括启动时没有驱动器在内的任何原因），都会把 `redstone_side` 输出
    置为 2 并保持 `swap_fault = 1`，机器留在故障模式直到维护人员按提示清除；成功换盘
    或恢复成功时红石为低电平、`swap_fault = 0`。故障细节以 `/auth/audit_fault.flag` 为准。
14. 权限跟随账户而不是终端：角色只存在于认证服务器的 `/auth/users.db`，由
    `/auth/role_policy.lua` 解释；终端上报/回显的角色不被采信，未知角色一律拒绝
    （fail-closed）。
15. 开门执行机构在认证服务器：终端连门禁红石都没有。`open_request` 只证明“这台终端
    持有登记的 PSK”和“它声称的用户名”；服务器不校验口令，用户名由终端软件从当前会话
    填入。能改终端程序的人本来就能读本机 PSK，所以物理安全仍是系统的安全上限（第 2 条）。
16. 离线模式是明确拒绝而不是静默降级：`login.lua` 不读 `/auth/mode.lua`，
    `login_standalone.lua` 只会报 `Offline mode is disabled. Connect to the auth server.`。

相对旧实现的刻意改进（都已在代码里）：

- 认证响应里的角色来自 `users.db` 的真实值，不再回退 `guest`；角色缺失/未知时登录失败。
- 开门从终端本地红石改为认证服务器执行，终端侧无法自行授权或开门。
- 角色比较统一走 `/auth/role_policy.lua` 的权重，未知角色 fail-closed。
- 独立/离线模式退役，终端不再部署本地账号库。
- 认证服务器按终端与阶段记忆 nonce，15 秒内拒绝重复请求（旧实现没有重放保护）。
- 认证心跳改为 1 秒，2..3 秒的自检窗口能稳定看到心跳。
- 审计日志携带完整 64 位 `PREV`/`HASH`，哈希链真正可验证。
- 审计服务器对“已接受事件的重复重发”重发同一 ack 且不重复落盘（幂等回执）。
- 审计连续错误计数在每次成功迭代后清零，不会因为历史错误累积而永久停机。
- 审计终端在无法签名时拒绝入队，而不是写一个永远不会被 ack 的文件。
- 客户端正确解析 `modem_message` 的 `(side, channel, replyChannel, message)` 参数，并
  只在频道与 `terminal_id` 匹配时接受回包。

## 12. 文件清单

| 仓库文件 | 部署路径 | 所属机器 | 作用 |
|---|---|---|---|
| `sentinel/common/sha256.lua` | `/sha256.lua` | 全部 | 纯 Lua SHA-256，`hash(s)` |
| `sentinel/common/role_policy.lua` | `/auth/role_policy.lua` | 认证服务器/客户端终端 | 角色规范化、权重与 `allows` |
| `sentinel/terminal/startup.lua` | `/startup.lua` | 客户端终端 | 启动、沙箱、自检、anti 两阶段 |
| `sentinel/terminal/auth/login.lua` | `/auth/login.lua` | 客户端终端 | 始终加载 login_client（登录/复核/开门请求） |
| `sentinel/terminal/auth/login_client.lua` | `/auth/login_client.lua` | 客户端终端 | 网络挑战-响应、角色校验、`open_request` |
| `sentinel/terminal/auth/login_standalone.lua` | `/auth/login_standalone.lua` | 客户端终端 | 旧部署兜底：只报离线模式已禁用 |
| `sentinel/terminal/auth/psk.lua` | `/auth/psk.lua` | 客户端终端 | 读取 PSK、签名、验签 |
| `sentinel/terminal/auth/psk.txt` | `/auth/psk.txt` | 客户端终端 | 32 字符 PSK（需替换） |
| `sentinel/terminal/auth/terminal_id.txt` | `/auth/terminal_id.txt` | 客户端终端 | 终端 ID（需替换） |
| `sentinel/terminal/auth/session.lua` | `/auth/session.lua` | 客户端终端 | 内存会话令牌，TTL 1 小时 |
| `sentinel/terminal/auth/user_manager.lua` | `/auth/user_manager.lua` | 认证服务器 | 用户库与 `getSalt`/`verifyDerived`/`getRole` |
| `sentinel/terminal/system/sandbox.lua` | `/system/sandbox.lua` | 客户端终端 | 事件锁与危险函数屏蔽 |
| `sentinel/terminal/system/netcheck.lua` | `/system/netcheck.lua` | 客户端终端 | 3 秒网络自检 |
| `sentinel/terminal/system/audit.lua` | `/system/audit.lua` | 客户端终端 | 审计队列（含 role）、重发、ack 删除 |
| `sentinel/terminal/system/kernel.lua` | `/system/kernel.lua` | 客户端终端 | 登录/菜单循环与审计循环 |
| `sentinel/terminal/system/ui.lua` | `/system/ui.lua` | 客户端终端 | 菜单、开门请求、退出、用户管理 |
| `sentinel/setup_root.lua` | `/setup_root.lua`（临时） | 认证服务器 | 一次性创建 root |
| `sentinel/auth_server/startup.lua` | `/startup.lua` | 认证服务器 | 服务 + 控制台并行启动 |
| `sentinel/auth_server/auth/server_crypto.lua` | `/auth/server_crypto.lua` | 认证/审计服务器 | 服务器侧签名与验签 |
| `sentinel/auth_server/auth/terminal_keys.lua` | `/auth/terminal_keys.lua` | 认证/审计服务器 | 终端密钥库读写 |
| `sentinel/auth_server/system/auth_server.lua` | `/system/auth_server.lua` | 认证服务器 | 心跳、取盐、认证、`open_request` 与门禁红石 |
| `sentinel/auth_server/system/user_admin.lua` | `/system/user_admin.lua` | 认证服务器 | 根控制台 |
| `sentinel/audit_server/startup.lua` | `/startup.lua` | 审计服务器 | 加载并运行审计服务器 |
| `sentinel/audit_server/auth/audit_config.lua` | `/auth/audit_config.lua` | 审计服务器 | 审计配置 |
| `sentinel/audit_server/system/audit_server.lua` | `/system/audit_server.lua` | 审计服务器 | 验签、日志、归档、换盘 |

部署时不需要附带测试文件；`sentinel/tests/`（`run.lua`、`run-tests.ps1`）只存在于仓库里。

## 13. 部署顺序清单

1. 把 `sentinel/common/sha256.lua` 复制成每台机器根目录的 `/sha256.lua`，把
   `sentinel/common/role_policy.lua` 复制成认证服务器与客户端终端的
   `/auth/role_policy.lua`。
2. 认证服务器：按 2.1 放好 8 个文件（含 `role_policy.lua`），重启，确认横幅里的
   `Protocol:  secure_auth_v5` 与服务 ID。
3. 认证服务器：把 `setup_root.lua` 临时放到根目录运行一次，创建 root，然后删除。
4. 认证服务器：用 root 登录控制台，`5. Manage Terminal Keys` → `2. Add / Show Key`，
   登记每台终端，记下 ID 与 Key。
5. 终端：把 ID 写进 `/auth/terminal_id.txt`，把 Key 写进 `/auth/psk.txt`，按 2.3 放好
   其余文件（含 `role_policy.lua`）。从旧独立终端迁移时先删掉 `/auth/mode.lua`、
   `/auth/users.db` 与 `/auth/user_manager.lua`。
6. 审计服务器：按 2.2 放好文件，**从认证服务器复制
   `/auth/terminal_keys.db`**，按现场修改 `/auth/audit_config.lua`（`protocol` 保持
   `secure_auth_v5`），重启，确认 `Ready.` 与频道 2。
7. 接好红石：认证服务器**左侧**接门禁/金库机构，审计服务器 `back` 接换盘机构；终端不接
   门禁红石。插好软盘，确认 `/disk*` 出现。
8. 开机一台终端：应通过 3 秒自检并出现登录界面；登录后确认审计服务器写入了带
   `ROLE=<role>` 的 `LOGIN_SUCCESS` 日志行与正确的哈希链。
9. 用 root（或 operator/admin）在终端测试一次 `Open Vault`（由认证服务器脉冲 1 秒），
   再用一个 user 账号确认会被拒绝；顺带测 `Exit to CraftOS`（两次重启后落到 shell，
   再重启回到登录）。
10. 备份 `/auth/users.db`、`/auth/terminal_keys.db`、`/auth/server_id` 与
    `/logs/chain.state`；终端密钥库变更后重新同步到审计服务器。角色修改由认证服务器
    实时读取，不需要重启终端。

## 许可证

本项目以 **MIT** 许可证发布，详见仓库根目录的 `LICENSE`。
