# RPV1 — 类 IPv4 的网络库（CC:Tweaked）

**RPV1 = Rednet Protocol Version 1**。它是一个跑在 CC:Tweaked 电脑上的**用户态网络协议栈库**：
把一堆电脑/无线或有线 modem 变成一个可路由的网络（MAC/IPv4/ARP/ICMP/UDP/路由/分片重装/拥塞控制），
再用 **rednet 只当 WAN** 把多个网段连起来。

- **可以当库用**：外部程序 `require("rpv")` 即可，不依赖本项目的 bootstrap、不需要 role.txt
- **公开 API 稳定**：[poc/rpv/API.md](poc/rpv/API.md)（本文件末尾有速查）
- **实测环境**：Minecraft 1.21.1 + NeoForge/Fabric + CC:Tweaked 1.120.2，以及 CraftOS-PC 2.8.3
- **测试**：离线套件 **22 组 / 1218 断言 / lint 0**（2026-10-25 实测）；CraftOS-PC 场景与真机套件见[测试状态](#测试状态)（历史数字已标注，未在本轮重跑）
- **可打包部署**：三种安装方式（单文件 / 目录 / 安装器），构建产物在 `dist/`
- **许可证**：随仓库根目录的 [`LICENSE`](../LICENSE)（**MIT**），本目录不另附许可声明

## 安装（三种方式，选一个）

构建发布包：

```powershell
pwsh -File poc\build-dist.ps1            # 生成 dist\ ：树 + 单文件 + 安装器 + MANIFEST + zip
```

| 方式 | 做法 | 适合 |
| --- | --- | --- |
| **A. 单文件**（最省事） | 把 `dist/rpv-bundle.lua` 拷到电脑，程序里 `local rpv = dofile("rpv-bundle.lua")` | 只想丢一个文件 |
| **B. 目录**（推荐给项目） | 拷贝 `dist/rpv.lua` + `dist/rpv/*.lua`（可选 `compat/`、`examples/`），程序里 `local rpv = require("rpv")` | 想 `require` + 模块清晰 |
| **C. 安装器**（无人值守） | 把整个发布包（含 `install.lua` + `MANIFEST.txt`）放到目录或软盘，在电脑上执行<br>`install.lua /disk` 或 `install.lua https://host/base`，可加 `--target /lib --no-examples --log /install-log.txt` | 批量部署 / 校验完整性 |

安装器会逐个文件比对 `MANIFEST.txt` 里的 **CRC32 + 大小**（纯 Lua 计算），然后加载装好的库并建一个节点自检：

```
INSTALL_OK files=<n> verified=<n> skipped=0
INSTALL_VERIFY ok=true version=RPV1 modules=19 node_new=true
```

`MANIFEST.txt` 同时给出每个文件的 **SHA256**（要强校验就在电脑外用系统工具核对）。发布包结构：

```
dist/rpv-bundle.lua        单文件库（约 234 KB，当前 239150 B）
dist/rpv.lua dist/rpv/*.lua  目录形态的库（20 个 .lua：rpv.modules 19 + node）
dist/install.lua           电脑端安装器（目录/软盘/HTTP 三种来源）
dist/compat/rednet.lua     rednet 兼容 shim
dist/examples/*.lua        外部程序示例 + 库自检
dist/API.md dist/README.md dist/MANIFEST.txt
dist/rpv-1.0.0.zip         整包
```

## 快速开始（在 CC:Tweaked 电脑里）

把 `rpv.lua` 与 `rpv/` 放进电脑（`poc/rpv.lua` + `poc/rpv/*.lua`），然后：

```lua
local rpv = require("rpv")                 -- 库入口（自动找自己的目录）

local node = rpv.node_new({                -- 配置表，不需要任何配置文件
    role = "host",
    ifaces = { { side = "left", name = "LAN", cidr = "10.0.1.2/24",
                 channel = 4001, mtu = 256, linktype = "wireless" } },
    gw = "10.0.1.1",
})
node:setup()                               -- 打开 modem、装路由、启动 tick

node:bind(4100, function(data, src, sport) -- UDP 服务
    print(rpv.int2ip(src), data)
    rpv.udp_send(node, src, 4100, sport, "pong")
end)

rpv.icmp_echo(node, rpv.ip2int("10.0.1.1"), 1, "hello")   -- ping（回包走 node.on_echo_reply）
node:run()                                 -- 事件循环
```

两个完整的**外部程序**示例（装成 `startup.lua` 直接跑，不看项目内部）：

| 文件 | 内容 |
| --- | --- |
| [poc/examples/rpv-echo.lua](poc/examples/rpv-echo.lua) | 最小主机：UDP 回显 + ICMP 应答 |
| [poc/examples/rpv-libtest.lua](poc/examples/rpv-libtest.lua) | 库自检：ARP / ICMP(带 RTT) / UDP 往返 / 4 KiB 分片重装 / 统计 |

```powershell
pwsh -File poc\run-lib.ps1                                        # CraftOS-PC 上跑示例验收
pwsh -File poc\mc\run-mc.ps1 -Scenario lib -Target fabric         # 真机（Minecraft）上跑同一套示例
```

## 能做什么

| 层 | 内容 |
| --- | --- |
| L2 | `dstMAC(4)|srcMAC(4)|ethertype(2)|body`，无线/有线 modem 均可，单帧上限受 CC modem 限制（实测 131072 B） |
| L3 | IPv4（20 B 头）、校验和、TTL、路由表（最长前缀）、转发、**分片/重装**（有界）、**PMTU/DF**（RFC 1191 ICMP type 3 code 4） |
| L4 | UDP（伪头校验和 + 端口绑定回调）；**连接层** `conn`：三次握手、滑动窗口 `min(cwnd,rwnd)`、AIMD、SRTT/RTTVAR RTO、快速重传、FIN |
| 集群 | `fabric`：多机箱背板（announce / 远程路由 / 一跳转发 / 分片） |
| WAN | **rednet 只作 WAN**：advert 交换、老化/环路抑制、默认路由、旧 rednet 设备翻译；另有 `compat/rednet.lua` 让老程序继续用 `rednet.*` |
| 运维 | `routes.txt` 热加载、`CHANNEL_AUDIT` 通道冲突审计、崩溃看门狗、`dump_stats` 遥测 |

实测数字（真机，见 [poc/out/measurements-mc.md](poc/out/measurements-mc.md)）：
停等 RTT = 1 tick（50 ms）、10 跳链 RTT 仍是 **0 tick**、协议层单路由器 ≈550–650 pps（≈30 包/tick）、
服务器 tick 中位 0.5 ms、连接层 200 kB 零丢包 ≈133 kB/s。

## 应用层 HTTP（极简 GET）与安全边界

`poc/apps/http_common.lua`、`http_server.lua`、`http_client.lua`、`http_secure.lua` 是**独立应用层模块**：不被 `poc/rpv.lua` 加载，也不导出为 `rpv.*`；用 `dofile`/`loadfile` 直接加载，测试在 `poc/tests/t_http_*.lua`。

### 范围（以代码为准）

- **仅 GET**：`http_server.start(port, routes, opts)` 只服务 GET；对已匹配的路由，HEAD/POST/PUT 等返回 `405` 且 `Allow: GET`，不会执行处理器；未知路径仍返回 404。
- **`Connection: close`**：`http_common.build_response` 默认加 `Connection: close`；服务端不主动启用 keep-alive，每个响应默认关闭（handler 若显式给出 Connection 头则以其为准）。
- **一次 datagram 一请求**：`server:handle(raw, src)` 一次只解析一个请求；没有 TCP、keep-alive、流水线或并发连接。
- **ASCII**：模块源码与默认文本响应为 ASCII；请求头/请求目标按 ASCII 校验（body 不强制 ASCII）。
- **默认端口**：`8080`（`http_common.DEFAULT_PORT`）。
- **secure 上限**：`http_secure.MAX_PLAINTEXT_BYTES = 60000`，按单条 rpv UDP datagram 设计；IPv4/UDP 数据上限 `65507` B，余量留给 `H | epoch | counter | ct | tag`。这不是 TCP 流式上限。
- **解析限制**：`MAX_PATH=1024` -> 414、`MAX_REQUEST_LINE=2048` -> 414、`MAX_HEADER_BYTES=8192` -> 431、`MAX_BODY_BYTES=65536` -> 413；错误码为 400/403/404/405/413/414/431/500，HTTP 版本不支持时为 505，handler 可返回 201/204 等状态。

### 安全边界

| 能防 | 不能防 |
| --- | --- |
| 被动监听：secure 模式下 ChaCha20 加密 payload 与头部 | DoS 根治：令牌桶只能降低速率，不能消除资源耗尽 |
| payload/头部篡改：HMAC-SHA256 tag 覆盖 epoch、counter 与 ciphertext | 流量分析：包大小、时序、epoch/counter 仍可观察 |
| 重放：每方向 counter + 64 条滑动窗口，strict 模式要求单调递增 | PSK 泄露后的历史解密：静态 PSK 无前向保密 |
| 反射：c2s/s2c 使用不同方向密钥，信封不能反向通过认证 | 本地窃取：能读文件的人可直接拿到 PSK 或 seed |
| 明文回退：strict 服务端拒绝明文；封装失败也不回退明文 | 弱口令爆破：PBKDF2 4096 次只提高成本，口令模式生产禁用 |
| 错误 PSK：认证失败 fail closed，不返回明文 | 无证书身份：不提供证书或公网身份认证 |
|  | 应用层授权：不判断“这个客户端能访问哪个路由” |

本层不声称能防公网攻击；公网部署依赖 WAN 侧频道白名单（`poc/apps/wan_acl.lua`）、限流、服主日志追溯和运维。

### 四项加固配置

1. **PSK**：默认要求 **64 hex**（解码为 32 字节）；口令模式必须 `allow_passphrase=true` 且 `psk_iter >= 4096`（默认 4096），生产环境应禁用口令模式。
2. **rate_limit**（opt-in）：`opts.rate_limit = { rate=50, burst=100, idle_ttl=300, max_sources=1024 }`（rate 为令牌/秒，idle_ttl 为秒），也接受 `true` 或数字简写（数字同时作为 rate 与 burst）；`src_label` 是同级 `opts.src_label(src, base)` 函数，不是 `rate_limit` 表内字段。三条副作用必须考虑：
   - fail-closed 有可用性代价：缺 `src`、时钟异常、`src_label` 抛错/非字符串、桶满且无可回收桶时直接拒绝，不会回退放行。
   - `max_sources` 满时拒绝新源；`make_room()` 只回收空闲超过 `idle_ttl` 的桶，活跃桶不会被驱逐。
   - 畸形/非 ASCII `src` 会归一化成 `_` 或 `unknown`，多个坏源可能共享同一个桶而误伤；可用 `src_label` 明确分桶。
3. **session_epoch**：信封为 `"H" | epoch(u32BE) | counter(u32BE) | ct | tag`；双方必须配置相同的 `opts.session_epoch`（默认 0），不匹配 fail closed。epoch 只做会话隔离，不替代 re-key，也不提供身份认证；这是破坏性 wire format，双端必须同时升级。
4. **seed_file**：默认 `<role_file 所在目录>/seed.bin`，`role_file` 默认 `role.txt`（因此默认是 `seed.bin`）；文件缺失时 `seed_loaded=false` 且不阻塞构造，`seed_file=false` 可禁用。当前实现只把它交给 `crypto.load_seed_file` 增强 DRBG，不改变 HKDF 密钥，也不改变 counter 起点（counter 固定从 1 开始）。

### 运维清单

- PSK 使用 64 hex；不要写进明文日志、公共软盘或可公开读取的文件；定期轮换。
- 轮换 PSK/epoch 时双端同步升级；epoch 变更会重置会话语义。
- `max_sources` 按并发源估算，避免被大量源占满后误拒新客户端。
- 服主日志需包含末影 Modem 发送者、频道与时间，便于追溯；HTTP 层本身不替代这些网络侧记录。

### 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File poc\run-offline.ps1
```

当前实测：**22 组 / 1218 断言 / OFFLINE_FAIL 0 / LINT_ERRORS 0**（LINT_WARNINGS 51 为既有 `rpv/*` 告警）。

## 应用层 hosts 与 WAN ACL

`poc/apps/hosts.lua`、`poc/apps/wan_acl.lua` 同样是**独立应用层模块**：不被 `poc/rpv.lua` 加载，也不导出为 `rpv.*`；用 `dofile`/`loadfile` 直接加载，测试在 `poc/tests/t_hosts.lua`、`poc/tests/t_wan_acl.lua`。网络侧只调用 node 的公开 socket API：`node:bind(port, cb)`、`sk:sendto(dst, dport, data)`、`sk:close()`。

### hosts（本地域名表）

- 表是 `hostname -> IPv4`；文件一行一条 `<hostname> <ip>`，`#` 注释，最多 1024 条 / 64 KiB。
- 接口：`hosts.load(path)`、`hosts.resolve(name)`、`hosts.set(name, ip)`、`hosts.save(path)`、`hosts.update(node, server_ip, opts)`；成功返回 `{ok=true, ...}`，失败返回 `nil, err`。
- 落盘：先写 `<path>.tmp`，再 rename 安装。CC 的 `fs.move` 拒绝覆盖已存在文件，所以旧文件先挪到 `<path>.bak`、最终安装失败时挪回；`path` 本身永不以写模式打开，不会留下半截文件。
- 更新：UDP 6702。请求 `HOSTS1 GET\n`，应答 `HOSTS1 <bytes>\n` + 文件正文；`opts.timeout`（单次，默认 2 s）、`opts.retries`（额外重试，默认 2）、`opts.wait` 可注入。只接受来自 `server_ip` 的应答；正文、主机名、IP 全部校验通过且落盘成功后才替换内存表，失败保持旧表。
- 安全：hostname 1..63 ASCII（字母/数字/`.`/`-`/`_`）；IPv4 严格点分十进制（无前导零）；路径含 `..` 或控制字节直接拒绝。
- 边界（与 rpv 内建名字服务 `services.lua` 的关系）：`apps/hosts` 是**应用层独立表**（`hosts.entries`，hostname -> 点分十进制），只由 `load/set/update` 写入、整表替换，模块自己不监听文件；它**不是** rpv 内建名字服务的补充或缓存。`services.lua` 维护另一张表 `node.hosts`（hostname -> 整数 IP）：`node:setup()` 时由 `services.hosts_load` 从 `hosts_file`（默认 `hosts.txt`）加载，`rpv/node.lua` 在 `hosts.txt` 的 mtime 变化时重载，`dns_register` 与查询命中会写入；`node:lookup()` 先查 `node.hosts`，未命中才向名字服务器发 QUERY。
- 同步：两套表**互不同步**。同名同格式、默认都叫 `hosts.txt`，但解析器、内存表和加载时机各自独立：`hosts.update()` 只改本模块表并重写文件，不碰 `node.hosts`；`dns_register`/`lookup` 只改 `node.hosts`，不碰本模块表。两者不同步时没有谁覆盖谁：应用层（HTTP 客户端/服务器、脚本）用 `hosts.resolve()`，需要 rpv services 视角（DHCP/DNS 服务器、动态注册）用 `node:lookup()`，以调用方选中的那张表为准。
- 空更新：`update()` **默认拒绝空正文**（防误清空），只有 `opts.allow_empty = true` 才接受并落盘空表；`load()` 没有这个守卫（空文件会清空表）。默认值不改。

### wan_acl（WAN 侧频道白名单）

- 默认策略 **Fail-Closed**：只允许 200..299 频段，其余一律拒绝；`wan_acl.new({ band=false })` 得到空白名单（全拒）。
- 接口：`wan_acl.new(opts)`、`acl:allow(ch)`、`acl:allow_range(lo, hi)`、`acl:deny(ch)`、`acl:check(ch)`、`acl:load(path)`、`acl:stats()`。
- 非法频道（nil、字符串、小数、NaN、越界 0..65535）一律拒绝；显式 `deny` 优先于 `allow`/band；空白名单拒绝一切。
- 日志只记计数：`check()` 只累加 `allowed`/`denied`，可选 `opts.log` 只收到 `"WAN_ACL_DENY"` 事件词，拿不到包内容。
- `acl:load(path)` 是**追加**语义：只把文件里的频道/频段并入当前策略，不撤销已有规则；重复 load 同一文件不改变 `check()` 结果，但会把频段重复追加进内部区间表（上限 `MAX_RANGES = 128`），所以启动时 load 一次即可。要整表刷新就重建实例（`wan_acl.new(...)`），要撤销某频道用 `acl:deny(ch)`（deny 优先于 allow/band）。

## 高可用主备交换机（HA）

`poc/apps/core_router.lua`（133 主交换机，内置 `RPV1-HA/1` 应答器，UDP 6710）与
`poc/apps/backup_router.lua`（灰羊总署备机，共享 VIP `10.200.0.1/24` 热备，5 s 同步 / 3 次未响应且
≥15 s 接管 / 主恢复即回切）组成一对主备交换机。两者都是**独立应用层模块**，不被 `rpv.lua` 加载，
用 `dofile`/`loadfile` 或 `role.txt` 的 `app=` 装载；定向测试在 `poc/tests/t_backup_router.lua`、
`poc/tests/t_core_router_ha.lua`（未并入 `run-offline.ps1`）。

**交接与部署文档**：[docs/HANDOFF-backup-router.md](docs/HANDOFF-backup-router.md)
（角色与地址规划、`RPV1-HA/1` 字段表、状态机与防脑裂、部署 SOP 与日志验收清单、故障演练脚本、
已知限制与回滚）。

一行入口：把 `poc/node2/startup.lua` 装成电脑的 `startup.lua`，`role.txt` 写
`app=core_router`（133）或 `app=backup_router`（备机）；库包用 `pwsh -File poc\build-dist.ps1` 生成，
`apps/*.lua` 需单独拷贝（构建产物不含 `apps/`）。

## API 速查

```lua
-- 入口
rpv.version / rpv.RPV_VERSION / rpv.modules / rpv.new_node(cfg)
rpv.install_rednet_shim(node, { dir_ip=..., port=4100 })

-- 节点
rpv.node_new(cfg | "role.txt") -> node
node:setup() node:run() node:bind(port, cb) node:add_task(name, fn) node:after(sec, fn)
node:resolve(ip) node:pick_src(ip) node:load_routes(path) node:reload_routes(why)
node:dump_stats() node:log(fmt, ...) node:capture(n) node:send_ip(dst, proto, payload, ttl, src, df)
node.on_echo_reply(src, seq, rtt_us, bytes)   node.on_icmp_error(src, type, code, inner, qseq, mtu)
node.stats  node.ifaces  node.routes  node.arp  node.udp  node.cfg

-- 工具 / 各层（完整签名见 poc/rpv/API.md）
rpv.ip2int rpv.int2ip rpv.masked rpv.cksum rpv.u16 rpv.u32 rpv.r16 rpv.r32
rpv.ip_build rpv.ip_parse rpv.ip_max_payload rpv.reasm_new rpv.reasm_push rpv.reasm_expire
rpv.route_new rpv.route_add rpv.route_connected rpv.route_default rpv.route_lookup rpv.route_path rpv.route_list
rpv.arp_new rpv.arp_send rpv.arp_resolve rpv.link_open rpv.link_send rpv.link_parse
rpv.icmp_echo rpv.icmp_send rpv.udp_send rpv.udp_bind
rpv.conn_connect rpv.conn_listen  (conn:send/close/abort/on_open/on_data/on_close/log_stats)
rpv.fabric_new rpv.fabric_setup rpv.fabric_announce ...      -- 集群背板
rpv.wan_new rpv.wan_setup rpv.wan_send rpv.wan_advert ...    -- rednet WAN
```

## 目录

```
dist/                     发布包（build-dist.ps1 生成）：树 + 单文件 + 安装器 + MANIFEST + zip
poc/rpv.lua              库入口（外部程序只需要这个 + rpv/）
poc/rpv/*.lua            20 个 .lua：util ip route arp link icmp udp conn fabric wan services dv nat mcast qos wansec compat topo crypto node（rpv.modules 19 + node）
poc/rpv/API.md           公开 API 参考（稳定面 vs 内部面）
poc/examples/            外部程序示例 + 库验收自检
poc/dist-src/install.lua 安装器源码（构建时拷进 dist/）
poc/build-dist.ps1       构建发布包（含 bundle 生成、MANIFEST、zip）
poc/apps/                项目自带应用（selftest / ftp / panel / 负载 / 网桥场景用）
poc/mc/                  真机 harness（RCON 驱动 Minecraft 服务器）+ 独立网桥程序
poc/run-*.ps1, run-all.ps1   仿真与真机回归（run-all 场景数随 harness 变化，以脚本输出为准）
poc/out/                 实测记录与证据
rpv-roadmap.md           设计、里程碑、实测结论、下一步
rednet-ipv4-feasibility.md  可行性分析
rpv-security.md          WPA2 风格安全层原型
```

真机测试用的 Minecraft 服务器运行时（NeoForge 的 `neoforge-*.jar`、Fabric 的 `server.jar`、
`libraries/`、`mods/`、`world/`）**不入库**：它们是第三方下载物与世界存档，按
[poc/mc/run-mc.ps1](poc/mc/run-mc.ps1) / [poc/mc/server.ps1](poc/mc/server.ps1) 重新准备即可。

## 测试状态

| 套件 | 结果 |
| --- | --- |
| 离线单元 + lint (`powershell -NoProfile -ExecutionPolicy Bypass -File poc\run-offline.ps1`) | **22/22 组、1218 断言、OFFLINE_FAIL 0、LINT_ERRORS 0**（2026-10-25 实测） |
| CraftOS-PC 全量 (`pwsh -File poc\run-all.ps1`) | 历史记录 PASS（未在本轮重跑；原场景计数已不适用，数量随 harness 变化） |
| 库打包形态验收 | 目录 `require("rpv")` / 单文件 `rpv-bundle.lua` / 安装器（每文件 CRC32 校验 + 装载自检）**三种都 PASS**（历史记录，未在本轮重跑） |
| 真机 Minecraft（Fabric / NeoForge） | 历史记录 lan/pmtu/ftp/conn/cluster/wan/shim/multi/sites/range/bench/probe/load/loadrpv/longchain/endbridge/lib 全部 PASS（未在本轮重跑） |

## 设计约定

- **命名**：项目名/版本标签用 **RPV1**；代码、路径、配置键、rednet 协议串保留 `rpv` 前缀
- **网桥链路是认证的（安全边界）**：`bridge_psk`（缺失即 fail-closed）、HMAC 握手 + 每方向会话键、逐帧 tag、防重放窗口、ethertype/源 MAC 白名单、广播限速；真机被攻击者伪造/重放时合法流量不受影响
- **无限距离/跨维度 modem（Ender Modem）只作网桥**，且网桥是**独立程序**
  （[poc/mc/ender-bridge.lua](poc/mc/ender-bridge.lua)）：装成 `startup.lua`、自带配置、不 import `rpv/*`；
  `poc/rpv/*` 与 `poc/apps/*` 中不出现任何 ender modem 字样
- **rednet 只作 WAN**，不是数据面的默认路径
