# ITN 备用节点接入规范（Standby Node Onboarding）

> 适用对象：往 ITN 里新增一台**备用交换机**（`backup_router.lua`）的人。
> 读完本文应当能做到：贴盘 → 改 `role.txt` → 开机 → 看见正确日志 → 拔掉主机电源 15 秒内接管 → 主机回来后自动回切。
>
> 本文与 `rpv1/docs/HANDOFF-backup-router.md` 的分工：那份是**实现与协议**交接（`RPV1-HA/1` 线格式、
> 状态机、代码行号），本文是**接入操作规范**（谁、按什么顺序、看到什么才算过）。
> 两者冲突时以代码与 HANDOFF 为准，并回来修本文。

## 1. 前置条件

| 项 | 要求 |
| --- | --- |
| 软件 | `rpv1/poc/rpv/`（20 个模块，由 `rpv1/poc/build-dist.ps1` 打成库包） |
| 应用 | `backup_router.lua`；可选 `ha_ctl.lua` |
| 引导 | `rpv1/poc/node2/startup.lua`（读 `role.txt` 的 `app=`） |
| 离线验收 | 提供方必须先跑过 `pwsh -NoProfile -File rpv1/poc/run-offline.ps1`：`OFFLINE_FAIL 0`、`LINT_ERRORS 0` |
| 主机侧 | 133 主交换机已在跑 `core_router`（内嵌 HA 应答器），且 `dhcp_pool` 已配置 |

未满足「主机侧有 `dhcp_pool`」这条时，备机能同步到的只有一个空配置，接管会退化成 `TAKEOVER_ABORT reason=no_synced_config`。

## 2. 地址与端口规划（不要自创）

| 用途 | 网段 / 值 | 说明 |
| --- | --- | --- |
| 末影公网（VIP） | `10.200.0.0/24`，网关/VIP = `10.200.0.1` | **主备共用同一 VIP**，这是接管成立的前提 |
| 动态池 | `10.100.0.0/16` | 跨网段池需要两侧都有该网段接口（§8） |
| 核心内网 | `192.168.1.0/24` | 主机的 LAN 侧 |
| 基础服务 | `172.16.1.0/24`（134 = `172.16.1.2`，DNS/RHTP:8080） | 备机不提供这些服务 |
| DHCP 端口 | `6700` | `dhcp_port=6700` |
| HA 同步端口 | `6710`（UDP） | `RPV1-HA/1`，默认值，不要改 |
| 末影 Modem | `side=left`、`channel=4001`、MTU `256` | 主备必须**同侧、同频道、同一末影 wire** |

## 3. 硬件清单

1. 一台 CraftOS 电脑（备机本体），电脑 ID 记下来写进台账。
2. 末影 Modem 一块，接在 `left`（或按 §2 统一改并同步改 `role.txt` 的 `iface` 行第 4 段）。
3. 底部红石锁：`rs.getInput("bottom")` 为真才继续启动。**无超时、无 override**，且只在启动时检查一次。
4. 软盘/硬盘（可选）：只用于放 `/disk/ha_ctl.cmd`，不是必需品。

## 4. 软件清单（拷进备机根目录）

```
startup.lua                 <- rpv1/poc/node2/startup.lua
role.txt                    <- 见 §5
rpv.lua                     <- rpv1/poc/rpv.lua
rpv/*.lua                   <- rpv1/poc/rpv/*.lua（20 个）
apps/backup_router.lua      <- 备机本体
apps/ha_ctl.lua             <- 可选：在线状态 / 手工撤销
```

`rpv1/dist/` 的库包**不含** `apps/`，app 要单独拷。

## 5. `role.txt`（三种形态，按需选一种）

`role.txt` 是扁平的 `key=value`；`iface` 用**竖线**分隔，不是逗号：
`iface=<side>|<name>|<cidr>|<channel>|<mtu>`。

### 5.1 最小备机

```
role=router
app=backup_router
iface=left|PUBLIC|10.200.0.1/24|4001|256
```

- **不要写 `dhcp_pool`**：写了也会被 `start_router` 停掉，池子由 SYNC 从主机拿。
- `master_ip` 不写时取 `M.MASTER_IP = 10.200.0.1`；只有当本机 `iface` 地址**等于**该 VIP 时，
  `rt.shared` 才为真，接管才被允许（否则日志 `TAKEOVER_DISABLED reason=vip_not_local`）。

### 5.2 带在线控制台（推荐）

```
role=router
app=ha_ctl
iface=left|PUBLIC|10.200.0.1/24|4001|256
```

`ha_ctl` 是**一次性** CLI：跑一条命令就返回，不是常驻界面。命令来源优先级：

1. 启动参数：`app=ha_ctl:takeover --yes`（冒号后整串作为 args）
2. `/disk/ha_ctl.cmd` 的**第一行有效内容**（≤256 B，`--path=` 可换路径，但文件里禁止再指向文件）
3. 都没有 ⇒ 默认 `status`

可用命令：`status` / `standby` / `takeover --yes` / `help`。
`takeover` **必须**带 `--yes`，否则记 `HA_CTL reject reason=no_confirm` 并打印用法。
`app:start()` 恒返回 `true`：被拒的命令不会拖垮开机。

### 5.3 跨网段池（`10.100.0.0/16`）

池不在 VIP 网段时，主备**两侧**都要有覆盖该池的接口，否则备机接管会被拒
（`HA_DHCP_POOL_OFF_SUBNET ... hint=needs_pool_iface` + `TAKEOVER_ABORT reason=pool_off_subnet`）。

`role.txt` 装不下这个 spec 表，只能走代码侧的 `opts.pool_iface`：

```lua
-- 133 侧（core_router 调用点）
setup_router(node, rpv, {
  pool_iface = { side = "right", channel = 4100, cidr = "10.100.0.1/16",
                 mtu = 256, name = "POOL",
                 pool_start = "10.100.0.10", pool_end = "10.100.0.250",
                 set_pool = true, set_gateway = true },
})
```

- 成功后日志 `CORE_ROUTER_POOL_IFACE_READY`（幂等重入是 `_REUSE`）。
- 若池接口不是**第一块**网卡，租约前缀仍取 `node.ifaces[1].prefix`，会记
  `CORE_ROUTER_POOL_IFACE_PREFIX hint=move_pool_iface_first` —— 这是已知限制，别指望日志消失。

## 6. 上机步骤

1. **贴盘**：按 §4 的文件树拷齐，`rpv/` 与 `apps/` 分目录。
2. **写 `role.txt`**：选 §5 的形态；`iface` 的 side/channel 与 §2 计划一致。
3. **插末影 Modem**：`left`，频道 `4001`（与 133 同一末影 wire）。
4. **接红石锁**：底部输入接一个可控红石源；拉闸前不要通电。
5. **上电**：先看见红石锁等待，再看见 `HA_*` 日志（§7）。
6. **等一轮同步**：5 秒一次 SYNC；第一轮回来后会拿到 `pool_start/pool_end/lease_time/gateway/dns/prefix/dhcp_port` 七项。
7. **确认待机**：`ha_ctl status`（或 `/disk/ha_ctl.cmd` 写 `status`）应报 `STANDBY`。
8. **登记**：电脑 ID、VIP、频道、池分段写进运营台账。

## 7. 上线判据（看到这些才算过）

按顺序出现（时间以 `runtime` 为准）：

```
RHTP...  (与本节点无关，可忽略)
HA_SYNC ...                     <- 发起第一轮 SYNC
STANDBY_MODE ...                <- 保持在待机
（每 5 s 一轮，无异常）
```

`ha_ctl status` 打印**一行**（字段顺序固定）：

```
HA_CTL status mode=<..> role=<..> vip=<..> shared=<true|false> pool=<起-止|none> \
master=<VIP|-> synced=<true|false> dhcp=<true|false> misses=<n> silent=<sec>s last_change=<sec>s|never
```

待机且已同步时应满足：`mode=STANDBY`、`shared=true`、`synced=true`、`pool` 不是 `none`、
`master=10.200.0.1`、`misses=0`。

**不通过的样子**（出现即停，不要继续演练）：

| 日志 | 含义 | 处置 |
| --- | --- | --- |
| `TAKEOVER_DISABLED reason=vip_not_local` | 本机地址不是 VIP | 改 `iface` 的 cidr 为 `10.200.0.1/24` |
| `TAKEOVER_ABORT reason=no_synced_config` | 从没拿到过主机的配置 | 检查 133 是否配了 `dhcp_pool`、两侧频道是否一致 |
| `HA_DHCP_POOL_OFF_SUBNET ... hint=needs_pool_iface` | 池不在本机任何接口网段内 | 按 §5.3 配池接口，两侧都要 |
| `HA_SEND_FAIL` / 一直 `HA_SYNC_MISS n=1/3` | 链路不通 | 查 modem side/channel、`wan_acl` 是否拦了 4001 |

## 8. 演练（接管与回切）

**只演练"拔电"，不要用"拔线"**：拔线属于单向断链分区，代码里没有 quorum / 租约仲裁（§8 已知限制），
会造成两台同时发租约。

1. 确认备机 `STANDBY` 且已 `synced=yes`。
2. `133` 直接断电（或关掉它的电脑）。
3. 观察备机：`HA_SYNC_MISS n=1/3` → `n=2/3` → `n=3/3` → `TAKEOVER_ACTIVE ... silent=15.0s`，
   **落在最后一次收到应答后第 3 个 5 s 周期（15 s）**，不会更早。
4. 客户端验证：连在公网段的机器应重新拿到 `10.200.0.x` 租约，能 `GET /` 到 134。
5. 给 133 上电：备机收到 CFG 立即 `STANDBY_MODE`（停 DHCP、放掉 VIP），133 继续当主机。
6. 记录：接管耗时（应 ≈15 s）、回切耗时、期间丢包量。冷却期 `TAKEOVER_COOLDOWN=10 s`，不要连拔两次。

## 9. 回滚

| 目的 | 做法 |
| --- | --- |
| 让备机立刻放弃接管 | `role.txt` 或 `/disk/ha_ctl.cmd` 写 `standby`，或直接跑 `ha_ctl standby`；幂等，已待机时打印 `noop` |
| 让备机永不接管 | 杀掉进程/断电；或把 `iface` 地址改成非 VIP（`rt.shared` 变 `false`，接管被拒） |
| 恢复 133 主控 | 上电即可；不需要在备机侧做任何动作 |

`ha_ctl` **不改任何持久化状态**：重启后备机仍是 `STANDBY`，必须重新同步一轮。

## 10. 已知限制（接入前必须知道）

1. **HA 协议无认证**：`RPV1-HA/1` 是明文 ASCII，同频道任何主机发一条 SYNC 就能拿到 DHCP 参数；
   `master/to/nonce` 只防串包，不防冒充。**不要把 6710 暴露到不该看到的网段**。
2. **单向断链分区未解**：拔线（而不是拔电）会让备机 15 s 后接管，而 133 还在发租约，两边可能发同一个 IP。
3. **备机不持久化**：重启即待机，重新同步前主机掉线会连续记 `TAKEOVER_ABORT reason=no_synced_config`。
4. **红石锁不是 kill switch**：只在启动时检查一次；运行中关红石不会停机。
5. **`4001` 与 `wan_acl` 默认白名单冲突**：`wan_acl` 默认只放行 `200..299`，`4001` 会被拒。
   要么 `acl:allow(4001)`，要么把公网频道改到 `200..299` 内——**改频道必须主备与 133 同步改**。
6. **租约前缀取第一块网卡**：池接口不是第一块时，租约前缀可能不对；见 §5.3 的 hint。
7. **`ha_ctl` 是一次性 CLI**：不是常驻交互界面，也不改持久化状态。

## 11. 排错表

| 现象 | 先查 | 说明 |
| --- | --- | --- |
| 开机卡住无输出 | `rs.getInput("bottom")` | 红石锁未满足；无超时，必须给信号 |
| `TAKEOVER_DISABLED vip_not_local` | `role.txt` 的 `iface` cidr | VIP 必须是本机地址，否则接管必成黑洞 |
| `HA_SYNC_MISS` 一直涨到 3 但没接管 | 是否 `synced=yes` | 没有同步配置就不接管（防脑裂） |
| 能同步但接管后客户端拿不到 IP | 池是否在本机接口网段内 | 见 §5.3；或主机侧池写错 |
| 回切后两台都在发 DHCP | 是否拔线而非拔电 | 已知分区缺陷，先断电一台止血 |
| `UDP_NO_PORT` / 收不到回包 | 6710 是否被 `wan_acl` 拦 | 见限制 5 |

## 12. 验收与参考

- 离线（提供方必须跑）：`pwsh -NoProfile -File rpv1/poc/run-offline.ps1`
  基线（2026-11-01）：`OFFLINE_PASS 2866 / FAIL 0 / GROUPS 31 / LINT_ERRORS 0 / LINT_WARNINGS 51`。
  跑完必须清理 staging：`git restore -- rpv1/craftos-offline` + `git clean -fd -- rpv1/craftos-offline`。
- 应用层协议：`rpv1/docs/RHTP-1.0.md`（备机不提供 RHTP，但排障时常要区分哪台在服务）。
- 实现交接：`rpv1/docs/HANDOFF-backup-router.md`（`RPV1-HA/1` 线格式、状态机、代码行号、演练记录）。
