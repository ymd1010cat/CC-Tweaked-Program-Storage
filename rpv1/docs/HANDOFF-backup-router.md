# RPV1 HA 主备交换机交接与部署文档（133 主 / 灰羊总署 备）

> 状态：交接稿，对应 **main 分支 2026-10-28 工作区**（`rpv1/poc/apps/core_router.lua` 1080 行、
> `rpv1/poc/apps/backup_router.lua` 1224 行，两者在本轮之前**尚未 commit**）。
> 本文所有结论都对应到具体文件与行号，见第 10 节；代码改了要同步改这里。

## 0. 文档定位

- **给谁看**：接手 A_Sheep 侧主备交换机运维、演练和二次开发的人。
- **说什么**：角色划分、地址规划、`RPV1-HA/1` 线格式、状态机、部署 SOP、故障演练、已知限制、回滚。
- **不说什么**：不重复 `rpv` 协议栈本身的实现（看 `rpv1/poc/rpv/API.md`），不涉及 `apps/router.lua` 的 TUI。
- **口径纠正（务必遵守）**：早期设计里的**不可信设备机制已整套砍掉**——`450 Cannot Trust`、
  `Device-State`、Bootloader 状态上报、强制入网校验都不存在了。代码里保留接口但不做入网拦截，
  本文任何地方都**不要**再写“用 450 拦设备”。

## 1. 架构与角色

### 1.1 角色表

| 角色 | 机器 | 程序 | 关键职责 |
| --- | --- | --- | --- |
| 主交换机 | **133 号机** | `rpv1/poc/apps/core_router.lua` | 核心内网转发 + 末影公网出口；底部红石启动锁；静态 ARP 表；公网→核心内网隔离；内置 `RPV1-HA/1` **应答器** |
| 根服务器 | **134 号机** | 基础服务（DNS/目录/文件等，不在本文范围） | 提供服务网段地址；**不参与** HA 选举，也不监听 6710 |
| 备用交换机 | **灰羊总署** | `rpv1/poc/apps/backup_router.lua` | 共享 VIP 待机；每 5 s 同步配置；静默满 3 个 5 s 周期（15 s）→ 接管 DHCP + 免费 ARP；主恢复即回切 |

两台交换机是**共享 VIP 热备**（hot standby），不是主从复制：备用机持有同一个地址
`10.200.0.1/24`，但在待机期间保持沉默（不起 DHCP、不应答 VIP 的 ARP），所以同一时刻只有一台
在服务。接管/回切的全部依据就是第 4 节的 `RPV1-HA/1` 心跳。

### 1.2 拓扑

```
                末影公网 wire（Ender Modem，两侧同频道）
   ┌───────────────────────┬───────────────────────────────┐
   │ 133 core_router       │ 灰羊总署 backup_router         │
   │ 10.200.0.1/24 (VIP)   │ 10.200.0.1/24 (同一 VIP)       │
   │ DHCP 服务             │ 待机：DHCP off、拦 VIP 的 ARP  │
   │ HA 应答器 :6710       │ 每 5s SYNC → :6710             │
   └───────────┬───────────┴───────────────────────────────┘
               │ 192.168.1.0/24（核心内网）
       ┌───────┴────────┬──────────────┐
   终端/客户端      服务器           监控
               │
               └── 172.16.1.0/24（基础服务，134 根服务器所在）
```

### 1.3 地址规划

| 网段 | 用途 | 关键地址 | 说明 |
| --- | --- | --- | --- |
| `192.168.1.0/24` | 核心内网 | 网关 `192.168.1.1`（133 的 LAN 侧） | 133 把 `10.200.0.0/24 → 192.168.1.0/24` 的入站包直接丢弃 |
| `172.16.1.0/24` | 基础服务 | `172.16.1.2` 根服务器（134） | `rhtp_server.lua` 的内置目录回落就是 `root.server 172.16.1.2` |
| `10.200.0.0/24` | 末影公网 | VIP `10.200.0.1/24`（主备共用） | 两台交换机都用这个地址；DHCP 默认池 `10.200.0.50-10.200.0.150` |
| `10.100.0.0/16` | 动态池（规划） | — | 见下面的口径说明：**当前代码默认池不在这一段** |

**口径说明（以代码为准，不要照抄规划当事实）**：

- `backup_router.lua:119-127` 与 `core_router.lua:96-104` 的 `M.DEFAULT_DHCP_CONFIG` 都是
  `10.200.0.50-10.200.0.150 / lease 600 / gw 10.200.0.1 / dns 10.200.0.1 / prefix 24 / port 6700`。
- `rpv` 的 DHCP 服务端把**接口前缀**当租约前缀（`rpv1/poc/rpv/services.lua:184`），而池子来自
  `node.cfg.dhcp_pool`（同文件 176）。在 `10.200.0.1/24` 的接口上配 `10.100.x` 的池属于跨网段，
  接管时会记 `HA_DHCP_POOL_OFF_SUBNET`（`backup_router.lua:818-823`），客户端也拿不到可用网关。
- 所以 `10.100.0.0/16` 目前只是**规划**。要真用，得先给交换机加第二个接口/路由，再改
  `dhcp_pool`，并重新演练一遍，不要只改配置文件。

## 2. 主交换机（133）

### 2.1 启动五步（`core_router.lua:958` `setup_router`）

| 步 | 动作 | 代码 | 日志 |
| --- | --- | --- | --- |
| 0 | 打印启动横幅 | `:967` | `CORE_ROUTER_BOOT` |
| 1 | **底部红石硬锁**（无超时、无 override），未通电时 `os.sleep(0.5)` 轮询 | `:543` `wait_for_redstone`，调用点 `:971` | `CORE_ROUTER_REDSTONE_WAIT` / `CORE_ROUTER_REDSTONE_ON` |
| 2 | 读 `/disk/static_ip.conf` 并全量校验后原子提交；坏文件保留旧表 | `:329` `load_static_ips`、`:396` `apply_static_ips`，调用点 `:978` | `CORE_ROUTER_STATIC_LOAD` / `CORE_ROUTER_STATIC_SKIP` / `CORE_ROUTER_STATIC_APPLY_FAIL` |
| 3 | 5 秒 mtime 热重载 watcher | `:489` `start_watcher`，`RELOAD_INTERVAL = 5`（`:83`） | `CORE_ROUTER_STATIC_WATCH` / `CORE_ROUTER_STATIC_RELOAD` |
| 4 | 隔离 hook：源 ∈ `10.200.0.0/24` 且 目的 ∈ `192.168.1.0/24` → 丢（不产生 ICMP） | `:605` `nat_input_hook`、`:614` `install_nat_hook`，调用点 `:1005` | `CORE_ROUTER_NAT_HOOK mode=rpv` 或 `mode=node`；丢弃时 `CORE_ROUTER_ISOLATE_DROP` |
| 5 | **HA 应答器**：红石锁之后才 `node:bind(6710)` | `:906` `start_ha`（bind 在 `:937`），调用点 `:1035`；`ha_sync=false` 关闭 | `CORE_ROUTER_HA_READY` / `CORE_ROUTER_HA_OFF` / `CORE_ROUTER_HA_UNAVAILABLE` |

最后一行 `CORE_ROUTER_READY static_ip=... mappings=N hook=rpv`（`:1057`）表示五步都过了。
**注意顺序**：红石锁在最前，HA 应答器在最后——所以锁着的 133 连 HA 端口都不监听（`:1028-1030` 注释），
备用机自然收不到回包，这是设计意图，不是故障。

### 2.2 `/disk/static_ip.conf`

ASCII，一行 `MAC,IP`，空行和 `#` 注释忽略（`:57-71` 头注释）：

```
12,192.168.1.10
0x0000000D,192.168.1.11
00:00:00:0E,192.168.1.12
```

- MAC 是 ComputerCraft 的 32 位 computer id（就是 rpv MAC）；接受十进制、`0x` 十六进制、
  「含字母的 8 位十六进制」、四段冒号/横线十六进制。
- IP 必须是严格点分十进制；重复 MAC、重复 IP、MAC 0 / `0xFFFFFFFF`、组播/广播地址一律拒绝。
- 落点：`node.arp.cache` 永久静态邻居 + `node.static_ips` 表。热重载原子切换，坏文件保留旧表。
- 文件超过 `MAX_FILE_BYTES = 65536` 或条目超过 `MAX_ENTRIES = 1024` 会加载失败（`:112-113`）。

### 2.3 内置 HA 应答器（与 `backup_router` 逐字节兼容）

- 端口 `M.HA_PORT = 6710`（`:89`）；单包上限 `M.HA_MAX_BYTES = 512`（`:90`）；字段上限 32（`:91`）。
- 限流：每源 **5 次/1 秒**（`M.HA_RATE_LIMIT = 5`、`M.HA_RATE_WINDOW = 1`，`:92-93`），超出记
  `CORE_ROUTER_HA_RATE` 并丢弃（`:845-858`）。
- **沉默条件**：`node.ha_taken_over == true` 或 `node.ha_dhcp_active == true` 时一律不回，记
  `CORE_ROUTER_HA_SILENT`（`:809-831`）。这条是防脑裂的一半。
- 只应答、从不主动发 SYNC（`:672`）；`opts.ha_primary_client = true` 时每次应答都记
  `CORE_ROUTER_HA_REPLY`，默认只在第 1 次和每 12 次记一次（`:897`）。
- 回包目标：请求方地址是**本机自有地址**时改用 `rpv.IP_BCAST` 广播（`:798-804`），原因见 8.2。

### 2.4 隔离 hook 与防火墙的关系

133 的 `nat_input_hook` 只做「公网源 → 核心内网目的」的丢弃（`core_router.lua:585-611`），
**没有** `192.168.0.0/16` 泛封锁；泛封锁是备用机那侧的 `FIREWALL_DROP`（见 3.4）。两者不要混为一谈：
133 保护的是核心内网不被末影公网直接打到，备机防火墙保护的是「公网口进来的、目的是内网的包」，
方向一致、判据不同。

## 3. 备用交换机（灰羊总署）

### 3.1 共享 VIP 热备的三条不变量

1. **地址相同**：备用机也是 `10.200.0.1/24`（`M.CIDR`，`:84`），`M.MASTER_IP = 10.200.0.1`（`:85`）。
   `master_ip == 本地接口地址` → `rt.shared = true`（`:1070`），同步走广播；不相等 → 只单播且**禁用接管**。
2. **待机不服务**：`start_router` 一进来就把可能存在的 DHCP 停掉（`:1089-1098`，日志
   `STANDBY_DHCP_OFF`）；并用 `node.on_frame` 包装器丢弃「目标是 VIP 的 ARP 请求」（`:608-627`），
   让客户端不会把网关流量发给一台不服务的机器。
3. **同时只有一个 DHCP**：接管先 `stop_dhcp` 再 `dhcp_server_start`（`:451-485`）；回切时立刻
   `stop_dhcp` 再回 `STANDBY`（`:849-881`）。

### 3.2 待机期间的三不

- 不起 DHCP（`STANDBY_DHCP_OFF`，`:1094`/`:1096`）。
- 不答 VIP 的 ARP 请求（`install_arp_guard`，`:608`；`rt.mode == "STANDBY"` 才拦，`:614`）。
- 不转发/不接管，只发 SYNC（每 5 s 一条，`:1130-1138` 的 `ha-sync` 任务）。

### 3.3 接管与回切的动作序列

**接管**（`M.takeover`，`:792`）：

1. 前置检查：`role == "standby"`、`mode ~= "ACTIVE"`、`rt.shared`、已同步到配置、冷却已过、
   `cfg.dhcp_port ~= sync_port`；任一不满足记 `TAKEOVER_ABORT reason=...` / `HA_TAKEOVER_HOLD`。
2. `M.start_dhcp`：把同步到的配置写进 `node.cfg`（`dhcp_pool/dhcp_gw/dhcp_dns/dhcp_lease/dhcp_port`），
   强制 `dhcp_probe="0"`（不做 ICMP 冲突探测，求快），`pcall(rpv.dhcp_server_start)`，再给
   socket handler 套一层 `node.ha_dhcp_active` 守卫（`:451-485`）。
3. `mode = "ACTIVE"`、`node.ha_active = true`、`TAKEOVER_ACTIVE reason=master_timeout misses=3 silent=15.0s`（`:842`）。
4. 免费 ARP 突发：手搓 `op=2`、sender/target 都是 VIP、目的 MAC 广播（`:578-603`），
   `HA_ARP_ANNOUNCE`；之后每 `ANNOUNCE_INTERVAL=10 s` 再补一条（`:1020-1023`）。

**回切**（`M.on_sync_reply`，`:883` → `M.standby`，`:849`）：收到合法 CFG 就 `stop_dhcp`，
记 `HA_DHCP_STOP leases_served=N` + `STANDBY_MODE reason=master_recovered`，
ARP 拦截重新生效。回切是**立即**的，没有迟滞；防抖靠 `cooldown=10 s`（`:93`，判据在 `:809`）。

## 4. 协议 `RPV1-HA/1`

### 4.1 报文样例（ASCII，一条 UDP 一个消息）

```
请求  RPV1-HA/1 SYNC id=133 nonce=133000001
应答  RPV1-HA/1 CFG master=133 to=134 nonce=133000001 pool_start=10.200.0.50
      pool_end=10.200.0.150 lease_time=600 gateway=10.200.0.1 dns=10.200.0.1
      prefix=24 dhcp_port=6700 uptime=42
```

（应答是一条单行 datagram，这里只为可读性折行；构造见 `backup_router.lua:224-244` 与
`core_router.lua:739-755`，两边字段顺序逐字一致。）

### 4.2 请求字段

| 字段 | 必填 | 示例 | 来源 | 语义 |
| --- | --- | --- | --- | --- |
| 协议头 | 是 | `RPV1-HA/1` | `M.PROTO`（`:80`）/`M.HA_PROTO`（`:88`） | 不匹配即整包丢弃（`protocol mismatch`） |
| 类型 | 是 | `SYNC` | `build_request`（`:224`） | `SYNC` 请求 / `CFG` 应答，其它值丢弃 |
| `id` | 是 | `134` | `rt.node.id` | 请求方 computer id；应答里回填到 `to` |
| `nonce` | 是 | `133000001` | `(node.id % 100000) * 1000000 + (seq % 1000000)`（`:760`） | 应答必须原样回带；缺 nonce 的请求**不予应答**（`core_router.lua:877-883`） |

### 4.3 应答字段逐项表

| 字段 | 类型/范围 | 默认 | 来源（133 侧） | 校验与用途 |
| --- | --- | --- | --- | --- |
| `master` | 整数 id | — | `node.id` | 应答方 id；备机用 `f.master == node.id` 丢掉自己广播（`:886`） |
| `to` | 整数 id | — | 请求里的 `id` | 非本机 id 的回包直接忽略（`:887`） |
| `nonce` | 整数 | — | 回带请求 nonce | 必须落在最近 8 个 nonce 窗口内（`NONCE_KEEP = 8`，`:105`、`:739-746`），否则计入 `sync_stale` |
| `pool_start` | 可用单播地址 | `10.200.0.50` | `node.dhcp_server.lo` → `cfg.dhcp_pool` 左端 → 默认 | 必填；`start > end` 判非法 |
| `pool_end` | 可用单播地址 | `10.200.0.150` | 同上右端 | 必填 |
| `lease_time` | 30..2592000 秒 | `600` | `srv.lease` → `cfg.dhcp_lease` | 越界拒绝（`MIN_LEASE/MAX_LEASE`，`:101-102`、`:299-302`） |
| `gateway` | 可用单播地址 | `10.200.0.1` | `srv.gw` → `cfg.dhcp_gw` → 默认（**不用接口地址**，`:691-694` 注释说明原因） | 可省略；备机缺失时回落 `rt.vip`（`:906`） |
| `dns` | 可用单播地址 | `10.200.0.1` | `srv.dns` → `cfg.dhcp_dns` → 网关 | 可省略；缺失时回落网关（`:907`） |
| `prefix` | 8..30 | `24` | `srv.prefix` → `cfg.dhcp_prefix` → 默认 | 可省略；备机缺失时用本地接口前缀（`:908`）；与接口前缀不同只告警 `HA_DHCP_PREFIX_SYNCED`（`:824-827`） |
| `dhcp_port` | 1..65535 | `6700` | `srv.port` → `cfg.dhcp_port` → 默认 | 可省略；**等于 6710 直接拒收**（`:910-914`），接管时同样拦（`:814-817`） |
| `uptime` | 秒 | — | `os.clock()`（`:242`，应答端唯一直接读 `os.clock()` 的字段） | 仅诊断，参与 `SYNCED_DHCP_CONFIG ... uptime=` 日志 |

字段一律 `key=value`，键名 `[%w_]+`、值非空；重复键、未知键（无 `=`）、超过 32 个字段、
超过 512 字节整包作废（`backup_router.lua:246-266`、`core_router.lua:758-780`）。

### 4.4 传输与端口

- 默认 UDP **6710**（`backup_router.lua:86`、`core_router.lua:89`），两端必须一致。
- **共享 VIP 时必须广播**：`master_ip == iface.ip` 时请求发 `255.255.255.255`（`rpv.IP_BCAST`，
  `:761-762`），应答也在「请求方地址是本机地址」时改广播（`:953-956` / `core_router.lua:798-804`）。
- 广播噪声导致的误触发由三层过滤挡住：`nonce` 窗口、`to` 字段、`master` 字段。
- 每轮只发**一条** SYNC，不重传。miss 不再看 `pending_nonce`，而是按**已静默时长**折算：
  每满一个 `opt.interval`（默认 5 s）记一 miss，计数在发请求**之后**做、封顶 `fail_limit`，
  收到合法 CFG 立即归零（`M.ha_tick`，`:992-1017`；细节与不变量见 5.3）。

### 4.5 两侧的配置来源优先级（**不一样，别写成一样**）

| | 133 `ha_config_from_node`（`:695-729`） | 备机 `dhcp_config_from_node`（`:524-563`） |
| --- | --- | --- |
| 1 | `node.dhcp_server` 活值 | `node.dhcp_server` 活值 |
| 2 | `cfg.dhcp_pool` 等 role.txt 键 | `cfg.dhcp_pool` 等 role.txt 键 |
| 3 | `M.DEFAULT_DHCP_CONFIG` **逐字**（网关保持 `10.200.0.1`） | 默认值，但网关换成本机公网口地址（`gateway_iface`，`:495-520`） |

133 之所以不用接口地址，是因为 133 的第一块网卡可能是 LAN（192.168.1.1），照抄过去会让末影公网
的客户端拿到 LAN 网关（`:691-694` 注释）。这一条是**必须保留**的行为差异。

## 5. 状态机

### 5.1 状态与字段

| 状态 | `rt.mode` | 本地 DHCP | VIP ARP 应答 | 进入方式 |
| --- | --- | --- | --- | --- |
| STANDBY | `STANDBY` | 关 | 不答（被 guard 丢） | 启动即进；跨角色回切 |
| SYNC | 仍是 `STANDBY` | 关 | 不答 | 每 5 s 的 `ha-sync` 任务发请求/收配置 |
| TAKEOVER_ACTIVE | `ACTIVE` | 开（用同步配置） | 答 + 主动免费 ARP | `evaluate` 成立后 `takeover` |
| PRIMARY | `PRIMARY` | 由 role.txt 决定 | 答 | `opts.role = "primary"`（同文件当应答端，不接管） |

`SYNC` 不是独立 mode 字段，而是 STANDBY 下的周期行为；`status_text` 只打印 `mode=`，不要指望看到
`SYNC` 这个字符串（`status_text` 在 `:1159`）。

### 5.2 迁移图

```
            ┌──────────────────────── STANDBY ◄────────────────────────┐
            │  启动 / 红石锁开  │                          ▲            │
            │                   ▼                          │ 收到合法 CFG
            │            ┌─────────────┐                   │ (master_recovered)
            └───────────►│  STANDBY    │                   │            │
                         │  + 5s SYNC  │                   │            │
                         └──────┬──────┘                   │            │
                                │ misses>=3 且 silent>=15s │            │
                                ▼                          │            │
                         ┌─────────────┐   立即 stop_dhcp   │            │
                         │   ACTIVE    │───────────────────┴────────────┘
                         │ DHCP + GARP │
                         └─────────────┘
```

### 5.3 触发条件、冷却、时间口径

- **miss 计数**（`M.ha_tick`，`:992-1017`）：每轮先发请求（`:998`），再按**已经静默的时长**折算 miss：
  `silent = now - (last_master_seen or started_at)`，`missed = floor(silent / opt.interval)`，
  封顶 `fail_limit`（`:1004-1013`）。每满一个 5 s 周期记一条 `HA_SYNC_MISS n=k/3 silent=...s`。
  `pending_nonce` 只用于「这条回包是不是我要的」的过滤（`:893-896`），**不再参与 miss 判定**——
  旧版“`pending_nonce` 还挂着就 `misses + 1`”的写法已经不存在了。
- **三条不变量**（改这块之前必须保住）：
  1. **已应答的轮次永不计 miss**：应答在 `on_sync_reply` 里先把 `misses = 0`、`last_master_seen = now`
     写好（`:925-926`）；本轮的请求是在那之后才发的，所以“这一轮有回包”不会被下一轮当成没答。
  2. **`silent < takeover_after` 时不可能达到 `fail_limit`**：默认 `fail_limit * interval == takeover_after`
     （3 × 5 = 15），`floor(silent / 5) >= 3` 与 `silent >= 15` 是同一条线；`M.evaluate` 还独立要求
     `silent >= takeover_after`（`:789`），两道门都过才接管，不存在“3 次 miss 但只静默了 10 s”。
  3. **应答到达即 miss 归零**：归零和 `last_master_seen` 更新在同一段代码里，没有中间窗口（`:925-926`）。
- **接管判据**（纯函数 `M.evaluate`，`:784-790`）：
  `misses >= fail_limit(3)` **且** `now - last_master_seen >= takeover_after(15 s)`。
  两个条件都要满足，缺一不接管——这是防止一次抖动就抢的硬约束。
- **冷却**：默认 `TAKEOVER_COOLDOWN = 10 s`（`:93`，`M.options` 里可由 `opts.cooldown` 覆盖，`:646`）。
  两次接管之间至少 10 s，不足记 `HA_TAKEOVER_HOLD cooldown=10.0s left=...`（`:809-813`）。
  注意区分：**默认值 10 s**，而 `tests/t_ha_e2e.lua` 的场景 D 为测防抖**显式覆盖成 30 s**（`:384`，
  断言见 `:386`、`:425-435`）——不要把测试里的 30 s 当成代码默认值。
- **时间口径**：所有 HA 时间戳都走 `now_of(rt)`（`:165-170`）：优先 `rt.clock`（即 `opts.clock`，
  `:650`；启动时装进 `rt.clock`，`:1071`），缺省才回落 `os.clock()`。**不以 tick 为口径**，不要用游戏
  tick 换算，也不要在文档里写“15 tick”。游戏卡顿只会让实际秒数变长，不会把判据变成 tick 计数。
- 接管前的额外否决条件：未同步到配置（`TAKEOVER_ABORT reason=no_synced_config`，`:800-807`）、
  VIP 不是本机地址（`TAKEOVER_ABORT reason=vip_not_local`，`:795-799`）、DHCP 起不来
  （`TAKEOVER_ABORT reason=dhcp_start`，`:829-833`）。

### 5.4 防脑裂：已覆盖与未覆盖

**已覆盖**

1. 备机在 `ACTIVE` 期间若收到 CFG，立即 `stop_dhcp` 回 `STANDBY`（`:941-943`）——主一回来就让位。
2. 133 在 `node.ha_taken_over` / `node.ha_dhcp_active` 为真时**拒绝应答**（`core_router.lua:809-831`），
   避免“被接管的主还在回 SYNC 造成两边都以为自己该服务”。
3. 接管前先 `stop_dhcp` 再起新服务端（`:453`），不会出现同一台机器两个 DHCP socket。
4. 只允许共享 VIP（`rt.shared`）的节点接管（`:793-799`）；地址不相同就只同步、不接管。

**未覆盖（必须知道的漏洞）**

- **单向断链分区**：如果 133 还活着、只是它与备机之间的链路断了，备机 15 s 后会接管，而 133
  仍在用同一 `10.200.0.50-150` 池发租约——两边可能把同一个 IP 发给不同客户端。现有代码没有
  quorum/租约仲裁，检测手段只有日志（备机 `HA_SYNC_MISS`，133 侧没有任何“被接管”感知）。
- 缓解：主备 modem 接**同一物理段**、同频道；把两侧 `HA_*` 日志接入监控；演练时优先演练“拔电”
  而不是“拔线”，后者正好落进这个盲区。

## 6. 部署 SOP（A_Sheep 侧）

### 6.1 硬件

| 项 | 要求 | 代码依据 |
| --- | --- | --- |
| 末影 Modem | 主备各一块，接在**同一侧**（默认 `left`）、**同一频道**（默认 `4001`）、同一末影 wire | `M.IFACE_SIDE="left"`、`M.IFACE_CHANNEL=4001`（`backup_router.lua:97-99`） |
| 网卡 MTU | 256（`boot()` 里写死 256；role.txt 里显式给） | `backup_router.lua:1203` |
| 底部红石锁 | 两台都要：`rs.getInput("bottom")` 为真才继续；**无超时、无 override** | `core_router.lua:541-565`、`backup_router.lua:676-703` |
| 红石锁语义 | 只在**启动时**检查；运行中关红石不会停机（不是 kill switch） | `backup_router.lua:1057` 单次调用 |
| 频道冲突 | 若同机还跑 `wan_acl`，注意其默认只放行 `200..299`，`4001` 会被拒；要么 `acl:allow(4001)`，要么把公网频道改到该频段 | `wan_acl.lua:49` `DEFAULT_BAND = {200, 299}` |

### 6.2 软件清单（拷进电脑的相对路径）

```
startup.lua                 ← 用 rpv1/poc/node2/startup.lua
role.txt                    ← 见 6.3
rpv.lua                     ← rpv1/poc/rpv.lua
rpv/*.lua                   ← rpv1/poc/rpv/*.lua（20 个）
apps/core_router.lua        ← 133
apps/backup_router.lua      ← 灰羊总署
```

- 生成库包：`pwsh -File rpv1\poc\build-dist.ps1`，产物在 `rpv1/dist/`（**不含** `apps/`，app 要单独拷）。
- 装机入口只有两个：`startup.lua` + `role.txt`；`node2/startup.lua` 读 `app=` 键去
  `loadfile("apps/<name>.lua")`（`node2/startup.lua:96-113`）。

### 6.3 配置：`role.txt`（rpv1 原生路径，bootstrap 读这个）

`role.txt` 是 `key=value`；`iface` 用**竖线**分隔（`rpv1/poc/rpv/node.lua:12-14`），不是逗号：

**133 主交换机**

```
role=router
app=core_router
iface=right|LAN|192.168.1.1/24|4100|256
iface=left|PUBLIC|10.200.0.1/24|4001|256
dhcp_pool=10.200.0.50-10.200.0.150
dhcp_gw=10.200.0.1
dhcp_dns=10.200.0.1
dhcp_lease=600
dhcp_port=6700
```

> 133 必须有 `dhcp_pool`：`node:setup()` 里只有 `if node.cfg.dhcp_pool then dhcp_server_start`
> （`rpv1/poc/rpv/services.lua:592`）。没有池子，133 自己不起 DHCP，也就没有可供同步的活值。

**灰羊总署备机**

```
role=router
app=backup_router
iface=left|PUBLIC|10.200.0.1/24|4001|256
```

> 备机的 `dhcp_pool` 可以**不写**：即使写了，`start_router` 也会主动停掉
> （`backup_router.lua:1089-1098`，`STANDBY_DHCP_OFF`）。池子由 SYNC 从 133 拿。

### 6.4 配置：`/etc/network.conf`（Pyromputer OS 路径，二选一）

如果节点是由 **Pyromputer OS**（`pyromputer-os/lib/rpvnet.lua`）起的，网络参数不在 `role.txt`，
而在 `/etc/network.conf`（同目录 `pkg.conf` 优先，`netcfg.lua:9-13`）。`rpvnet` 认的键
（`rpvnet.lua:11-23`）：

```
transport=rpv
rpv_side=left
rpv_cidr=10.200.0.1/24
rpv_channel=4001
rpv_mtu=256
```

- `rpv_peer_<id>=<address>` 可选，用于跳过发现；共享 VIP 场景**不要**给两台配同 id 的 peer。
- **两条路径互不读取**：`rpv1/poc/node2/startup.lua` 只读 `role.txt`；`rpvnet.lua` 只读
  `/etc/network.conf` + `/etc/pkg.conf`。同一台机器选一条，别指望它们互相覆盖。
- `role.txt` 的 `iface=` 改动属于重启键（`node.lua:185` 的 `RESTART_KEYS`），改了要重启电脑，
  热重载只会记 `CFG_RELOAD_RESTART_REQUIRED key=iface`（`node.lua:207-218`）。

### 6.5 启动顺序

1. **133 先上电/先给红石锁通电**。等 `CORE_ROUTER_READY` + `CORE_ROUTER_HA_READY port=6710`。
2. **灰羊总署再上电**（红石锁通电）。等 `HA_REDSTONE_ON` → `STANDBY_DHCP_OFF` → `HA_BOOT` → `HA_MODE`。
3. 5 秒内应看到备机 `HA_SYNC_TX`、133 侧 `CORE_ROUTER_HA_REPLY`、备机 `SYNCED_DHCP_CONFIG`。
4. 反向确认：备机 `M.status_text(node.ha)` 输出里 `dhcp=false`；133 的 `dhcp` 应为 true。

反着启动（备机先）也能工作，但备机在拿到第一份配置前不会有 `synced_dhcp_config`，
此时若 133 又恰好一直不上线，会反复记 `TAKEOVER_ABORT reason=no_synced_config`（`:801-806`）。

### 6.6 日志关键字验收清单

| 关键字 | 出现位置 | 含义 / 期望 | 缺失时先看 |
| --- | --- | --- | --- |
| `CORE_ROUTER_BOOT` | 133 | 启动开始 | startup.lua 有没有执行 |
| `CORE_ROUTER_REDSTONE_WAIT` → `CORE_ROUTER_REDSTONE_ON` | 133 | 红石锁等到了 | 底部红石信号 |
| `HA_REDSTONE_LOCK` → `HA_REDSTONE_ON` | 备机 | 同上（备机前缀不同） | 底部红石信号 |
| `CORE_ROUTER_STATIC_LOAD count=N` | 133 | 静态表装上了 | `/disk/static_ip.conf` 缺失/格式错 |
| `CORE_ROUTER_NAT_HOOK mode=rpv` | 133 | 隔离 hook 挂到了 rpv | 若 `mode=node` 或 `ISOLATION_UNAVAILABLE`，检查 rpv 表 |
| `STANDBY_DHCP_OFF` | 备机 | 待机确认没在发租约 | 若报 `pool=...` 说明它曾起过 DHCP，已被停 |
| `HA_BOOT mode=standby ... transport=broadcast` | 备机 | 共享 VIP 判定成立、走广播 | `transport=unicast` 说明 `master_ip != 本机地址` |
| `HA_SYNC_TX n=...` | 备机 | 心跳发出（第 1 次和每 12 次记一次） | 端口/socket 绑定失败 |
| `CORE_ROUTER_HA_REPLY` | 133 | 应答发出（默认第 1/12 次） | 见 `CORE_ROUTER_HA_SILENT`（主以为自己是备）或 `HA_RATE` |
| `SYNCED_DHCP_CONFIG pool=...` | 备机 | 配置到手（变化时必记） | `HA_SYNC_BAD reason=...` |
| `TAKEOVER_ACTIVE reason=master_timeout misses=3 silent=15.0s` | 备机 | 接管成功 | `TAKEOVER_ABORT` / `HA_TAKEOVER_HOLD` |
| `HA_ARP_ANNOUNCE` | 备机 | 免费 ARP 已发，客户端应换网关 MAC | 接口不在 `10.200.0.0/24` |
| `STANDBY_MODE reason=master_recovered` | 备机 | 回切完成 | 一直 ACTIVE 说明收不到 CFG |
| `FIREWALL_DROP src=... dst=192.168.1.x` | 备机 | 公网→内网包被拦（正常防线生效） | `HA_FIREWALL_READY mode=...` 是否出现 |
| `CORE_ROUTER_ISOLATE_DROP` | 133 | 同上，核心侧隔离生效 | 同上 |
| `HA_SYNC_MISS n=k/3` | 备机 | 心跳缺失计数（演练时按秒看） | 133 是否关机/锁着 |

## 7. 故障演练脚本（拔 133 电源 → 15 秒内接管 → 恢复回切）

### 7.1 演练前检查（全部满足才开始）

1. 133 `CORE_ROUTER_READY` + `CORE_ROUTER_HA_READY port=6710` 都在。
2. 备机 `SYNCED_DHCP_CONFIG` 至少出现过一次，且 `M.status_text` 里 `synced=true dhcp=false`。
3. 备机 `HA_MODE mode=STANDBY responder=false firewall=true`。
4. 记下当前时间与备机 `stats.sync_tx`，方便事后对账。

### 7.2 步骤与观察点

| 时刻 | 动作 | 观察点（备机日志） | 判据（通过） | 失败判据与处置 |
| --- | --- | --- | --- | --- |
| T0 | 断 133 电源（或断其红石锁后重启，使其停在锁上） | 无 | 133 不再回包 | 若 133 仍在回包，检查是不是还有第二个应答器 |
| T+5s | 等一轮 | `HA_SYNC_MISS n=1/3 silent=5.0s` | 恰好 1 条 miss | 没有 miss → SYNC 根本没发（看 `HA_SYNC_TX`） |
| T+10s | 等一轮 | `HA_SYNC_MISS n=2/3 silent=10.0s` | 计数递增 | 计数回 0 → 说明收到了回包（133 没真断） |
| T+15s | 等一轮 | `TAKEOVER_ACTIVE reason=master_timeout misses=3 silent=15.0s pool=...` | **15 s 内**出现；随后 `HA_ARP_ANNOUNCE n=1/3` | 出现 `TAKEOVER_ABORT reason=no_synced_config` → 备机从未同步成功；`reason=vip_not_local` → 备机地址不是 VIP；`HA_TAKEOVER_HOLD` → 10 s 冷却没过 |
| T+15s | 查 DHCP | 紧邻 `DHCP_SERVER_START pool=...`（rpv 侧日志，`services.lua:190`） | 有 | 看 `TAKEOVER_ABORT reason=dhcp_start` |
| T+20s | 客户端续租 | 客户端能 ping 通 `10.200.0.1`、能拿到租约 | 通 | 通不了 → 免费 ARP 没发或频道不对 |
| T+60s | 稳态 | 每 10 s 一条 `HA_ARP_ANNOUNCE ... reason=renew` | 周期性出现 | 缺失 → `rt.next_announce` 没走到（`ha_tick` 的 ACTIVE 分支） |

**回切步骤**：

| 时刻 | 动作 | 观察点 | 判据 |
| --- | --- | --- | --- |
| R0 | 133 上电/给红石锁通电 | 133：`CORE_ROUTER_READY`、`CORE_ROUTER_HA_READY`；133 自己 `DHCP_SERVER_START` | 两边都起 |
| R+5s | 备机下一轮 SYNC | 备机 `SYNCED_DHCP_CONFIG`（若配置有变）→ `HA_DHCP_STOP leases_served=N` → `STANDBY_MODE reason=master_recovered` | 一个轮次内完成；备机 `dhcp=false` |
| R+10s | 确认没有双 DHCP | 133 只有一份 `DHCP_SERVER_START`；备机没有新的 `DHCP_LEASE` | 无重复租约 |
| R+30s | 客户端再验 | 断网重连能续租，网关不变 | 通 |

> 回切是「收到第一条 CFG 就停」的即时行为，没有等待窗口。所以 R+5s 内看到 `STANDBY_MODE`
> 才算对；如果备机在 133 恢复后仍是 ACTIVE，几乎一定是 CFG 没到（查广播、频道、`to`/`nonce` 过滤）。

### 7.3 演练记录模板

```
日期/操作者：
133 关机方式：（断电 / 红石锁重启）
T0=            TAKEOVER_ACTIVE=            Δt=        （要求 ≤15 s）
客户端续租结果：
回切时刻=      STANDBY_MODE 出现=          Δt=        （要求 ≤1 轮 5 s）
异常日志（原样贴）：
```

## 8. 已知限制（改之前先读）

### 8.1 rpv 没有 `dhcp_server_stop`

`rpv1/poc/rpv/services.lua` 里只有 `dhcp_server_start`（`:173`），**没有** stop。
停止全靠 `backup_router.M.stop_dhcp`（`:432-449`）手工做五件事：

```lua
node.ha_dhcp_active = false          -- 守卫，先关掉
srv.sk:close()                       -- 关 socket（pcall 包住）
srv.by_ip = {}; srv.by_client = {}   -- 清表，让 rpv 自带的 expire 任务空转
node.dhcp_server = nil; node.dhcp = nil; node.ha_dhcp_srv = nil
node.cfg.dhcp_pool = nil             -- 关键：否则重启时 setup 又会起一个
```

顺序不能反：`M.start_dhcp` 第一句就是 `M.stop_dhcp(node)`（`:451-453`），先关旧 socket、清空
`by_ip/by_client`（`:437-446`），再 `pcall(rpv.dhcp_server_start, node, {})`（`:462`）；新服务端
不会继承旧租约表，rpv 自带的 expire 任务也不会再碰一个已经关掉的 socket。

### 8.2 共享 VIP 时向 VIP 单播会被 rpv 自投递

`rpv/node.lua:556-568` 的 `send_ip` 对「本机持有的地址」直接本地投递，不发上线。
所以备机若向 `10.200.0.1` 单播 SYNC，包会回到自己身上，永远到不了 133。
对策：`master_ip == 本机接口地址` 时请求与应答都改走 `255.255.255.255`（`backup_router.lua:761-762`、
`953-956`；`core_router.lua:798-804`）。**改这一段前先读这段注释**，不要“优化”回单播。

### 8.3 备用机地址不是 VIP 时禁用接管

`rt.shared = (master == pub.ip)`（`:1070`）。不相等时只单播同步，并在启动时记
`TAKEOVER_DISABLED reason=vip_not_local local=... master=... (unicast sync only)`（`:1120-1123`），
`takeover` 里再拦一次（`:793-799`）。原因同上：rpv 只把自有地址的包投递给本机，不是 VIP 的机器
永远收不到发给 VIP 的流量，接管了也是黑洞。

### 8.4 时间判定用 5 s / 15 s，不以 tick 为口径

`SYNC_INTERVAL=5`、`FAIL_LIMIT=3`、`TAKEOVER_AFTER=15`、`TAKEOVER_COOLDOWN=10`（`:87-89`、`:93`）。
所有 HA 时间戳统一走 `now_of(rt)`（`:165-170`）：优先 `rt.clock`——由 `opts.clock` 注入（`:650`），
启动时装进 `rt.clock`（`:1071`）——只有没注入时才回落 `os.clock()`。离线测试就是靠这条钩子
（`tests/t_ha_e2e.lua:27-34` 造 `clock()`，`:227` 传给 `M.options`）把时间变成确定值，所以
“接管正好发生在最后一次应答后 15 s”可以被断言，不依赖跑得多快。仍直接读 `os.clock()` 的只有
两处诊断值：应答里的 `uptime=`（`:242`）与红石锁的 `waited=`（`:684`、`:690`）。
不要写成 “15 tick”，也不要按服务器 TPS 折算：游戏卡顿只会让实际秒数变长。

### 8.5 附加限制（本轮新增，同样要知道）

- **HA 协议无认证**：明文 ASCII，同频道任何主机发一条 SYNC 就能拿到 DHCP 参数；`master/to/nonce`
  只防串包，不防冒充。不要把 6710 暴露到不该看到的网段。
- **分区脑裂未解**：见 5.4 的“未覆盖”。
- **红石锁不是运行期开关**：只在启动时检查一次（`backup_router.lua:1057`、`core_router.lua:971`）。
- **备机不持久化**：重启即 STANDBY，必须重新同步一轮才有 `synced_dhcp_config`；这期间 133 掉线
  会连续记 `TAKEOVER_ABORT reason=no_synced_config`。
- **`10.100.0.0/16` 池跨网段**：见 1.3 口径说明。
- **`4001` 与 `wan_acl` 默认白名单冲突**：见 6.1。

### 8.6 接管时刻是 3 个 5 s 周期（15 s），不是 20 s

- **结论**：从最后一次收到主应答起，接管落在**第 3 个周期（15 s）**，既不会更早、也不多等一个周期。
  判据由 5.3 的两道门共同保证：`misses >= fail_limit(3)` 且 `silent >= takeover_after(15)`（`:784-790`）。
- **离线实测**：`rpv1/poc/tests/t_ha_e2e.lua` 的**场景 B**（`:294-328`）把这个过程整个跑了一遍——
  第 1/2 轮只记 1/2 次 miss 不接管（`:301-314`），第 3 轮（15 s）接管（`:324-326`），并用
  `NOW - brt.last_master_seen == 15` 断言接管正好在最后一次应答后 15 s（`:327-328`）。
  代码注释把这套规则写成“3 × 5 s = 15 s”（`:782-783`、`:999-1003`）。
- **不要照抄旧数字**：改写前按 `pending_nonce` 计 miss，实际会晚一个周期（≈20 s）；现在按静默时长
  折算（`:1004-1013`），15 s 与判据是同一条线。演练时看到 `HA_SYNC_MISS n=1/3` → `n=2/3` →
  `TAKEOVER_ACTIVE ... silent=15.0s` 的顺序就是对的。

## 9. 回滚办法

> 目标：从「备机在服务」退回到「133 在服务、备机纯待机」。按风险从低到高选一条。

**路径 A（推荐，最干净）：先让 133 回来，等自动回切**

1. 133 上电/解锁，确认 `CORE_ROUTER_READY` + `CORE_ROUTER_HA_READY` + `DHCP_SERVER_START`。
2. 备机下一轮（≤5 s）收到 CFG → `HA_DHCP_STOP` → `STANDBY_MODE reason=master_recovered`。
3. 验收：备机 `dhcp=false`；133 有租约日志；无重复 `DHCP_LEASE`。

**路径 B：停备机（133 暂时回不来时，先止血）**

1. 在备机上 `shutdown`（或断其电源）。没有在线停 HA 的命令，因为 `wait_for_redstone` 只在启动时检查。
2. 重新上电时**不要给底部红石锁通电**，它会停在 `HA_REDSTONE_LOCK side=bottom waiting`，
   HA 服务、DHCP、hook 都不会启动（`:1057` 之前）。
3. 确认备机日志没有新的 `DHCP_LEASE`。

**路径 C：在线手工撤销接管（仅在你能拿到 `node` 引用时可用）**

`node2/startup.lua` 起的不保留全局 `node`，所以这条只适用于自己写启动脚本、手里有 `node` 的场景：

```lua
local ha  = dofile("apps/backup_router.lua")
local node = ...                          -- 你的启动脚本里保留的 node 引用
ha.standby(node.ha, "manual")             -- stop_dhcp + mode=STANDBY（backup_router.lua:849-881）
node.ha.mode = "STANDBY"                  -- 双保险：ARP 拦截重新生效
print(ha.status_text(node.ha))            -- 期望 dhcp=false mode=STANDBY
```

> 拿不到 `node` 就别硬来：重启备机（路径 B）比在线改状态安全。仓库里没有 CLI 级的
> `takeover` 撤销命令，本文不虚构一个。

**恢复 DHCP（三条路径共同）**

1. 133 侧确认 `DHCP_SERVER_START pool=...`（来自 `role.txt` 的 `dhcp_pool`，`services.lua:592`）。
2. 客户端断开重连或等租约续期，确认拿到 `10.200.0.x` 且网关 `10.200.0.1`。
3. 备机回到 `STANDBY_DHCP_OFF` 语义：`dhcp=false`、`synced=true`、无 `DHCP_LEASE`。

## 10. 代码核对表（写文档时逐条 Select-String 过）

| 文档结论 | 代码位置 |
| --- | --- |
| 133 启动五步、红石锁在最前 | `rpv1/poc/apps/core_router.lua:958-1060`，锁 `:543-565`，调用 `:971` |
| `/disk/static_ip.conf` 格式与原子提交 | `rpv1/poc/apps/core_router.lua:57-71`、`:329`、`:396` |
| 5 秒热重载 | `rpv1/poc/apps/core_router.lua:83`、`:489` |
| 隔离 hook 判据（10.200.0.0/24 → 192.168.1.0/24） | `rpv1/poc/apps/core_router.lua:585-611`，常量 `:107-110` |
| HA 应答器端口/上限/限流/沉默 | `rpv1/poc/apps/core_router.lua:88-93`、`:809-831`、`:845-858`、`:906-950` |
| 应答在共享 VIP 时改广播 | `rpv1/poc/apps/core_router.lua:785-804` |
| 133 配置来源优先级（网关不用接口地址） | `rpv1/poc/apps/core_router.lua:695-729`，原因注释 `:691-694` |
| 备机共享 VIP / 主地址 / 端口常量 | `rpv1/poc/apps/backup_router.lua:84-106` |
| 请求/应答构造与字段顺序 | `rpv1/poc/apps/backup_router.lua:224-244`（与 core `:739-755` 逐字一致） |
| 报文校验（512 B / 32 字段 / 重复键） | `rpv1/poc/apps/backup_router.lua:246-266`、`core_router.lua:758-780` |
| 应答字段校验范围 | `rpv1/poc/apps/backup_router.lua:277-334` |
| 共享 VIP 走广播的原因 | `rpv1/poc/apps/backup_router.lua:45-54`、`:761-762`、`rpv1/poc/rpv/node.lua:556-568` |
| nonce 窗口 8 | `rpv1/poc/apps/backup_router.lua:105`、`:739-746` |
| 5 s / 3 次 / 15 s / 10 s 冷却 | `rpv1/poc/apps/backup_router.lua:87-93`、`:992-1017`、`:784-790`、`:809` |
| miss 由静默时长折算（不是 `pending_nonce`），应答即归零 | `rpv1/poc/apps/backup_router.lua:999-1013`、`:925-926` |
| 可注入时钟 `now_of` / `opts.clock` | `rpv1/poc/apps/backup_router.lua:165-170`、`:650`、`:1071` |
| 接管正好 15 s（场景 B 离线实测） | `rpv1/poc/tests/t_ha_e2e.lua:294-328` |
| 接管动作序列 + 免费 ARP | `rpv1/poc/apps/backup_router.lua:792-847`、`:578-603` |
| 回切（收到 CFG 立即停 DHCP） | `rpv1/poc/apps/backup_router.lua:849-881`、`:941-943` |
| 待机拦 VIP 的 ARP | `rpv1/poc/apps/backup_router.lua:608-627` |
| 没有 `dhcp_server_stop`，手工停 | `rpv1/poc/apps/backup_router.lua:432-449`；`rpv1/poc/rpv/services.lua:173`（只有 start） |
| 防火墙判据 `192.168.0.0/16` | `rpv1/poc/apps/backup_router.lua:373-384`、`:394-427`、`:115-116` |
| 非 VIP 禁用接管 | `rpv1/poc/apps/backup_router.lua:1070`、`:1120-1123`、`:793-799` |
| 备机待机停 DHCP 日志 | `rpv1/poc/apps/backup_router.lua:1089-1098` |
| 启动顺序与 `HA_BOOT`/`HA_MODE` | `rpv1/poc/apps/backup_router.lua:1028-1142`（`:1125`、`:1139`） |
| `role.txt` 的 `app=` 加载 | `rpv1/poc/node2/startup.lua:96-113` |
| `role.txt` 的 `iface=` 用竖线、改动需重启 | `rpv1/poc/rpv/node.lua:12-14`、`:185`、`:207-218` |
| 133 的 DHCP 由 `dhcp_pool` 自动起 | `rpv1/poc/rpv/services.lua:592`、`:173-192`（前缀取接口） |
| `/etc/network.conf` 键与优先级 | `pyromputer-os/lib/rpvnet.lua:11-23`、`pyromputer-os/lib/netcfg.lua:9-13` |
| `wan_acl` 默认只放行 200..299 | `rpv1/poc/apps/wan_acl.lua:49` |
| 根服务器地址 `172.16.1.2` | `rpv1/poc/apps/rhtp_server.lua:31` |
| 定向测试（未并入 `run-offline.ps1`） | `rpv1/poc/tests/t_backup_router.lua`、`rpv1/poc/tests/t_core_router_ha.lua`、`rpv1/poc/tests/t_ha_e2e.lua` |
