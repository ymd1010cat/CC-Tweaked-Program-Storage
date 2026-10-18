# RPV1 — 类 IPv4 的网络库（CC:Tweaked）

**RPV1 = Rednet Protocol Version 1**。它是一个跑在 CC:Tweaked 电脑上的**用户态网络协议栈库**：
把一堆电脑/无线或有线 modem 变成一个可路由的网络（MAC/IPv4/ARP/ICMP/UDP/路由/分片重装/拥塞控制），
再用 **rednet 只当 WAN** 把多个网段连起来。

- **可以当库用**：外部程序 `require("rpv")` 即可，不依赖本项目的 bootstrap、不需要 role.txt
- **公开 API 稳定**：[poc/rpv/API.md](poc/rpv/API.md)（本文件末尾有速查）
- **实测环境**：Minecraft 1.21.1 + NeoForge/Fabric + CC:Tweaked 1.120.2，以及 CraftOS-PC 2.8.3
- **测试**：CraftOS-PC **46/46** 场景 + 真机（Minecraft）多场景，含"纯外部程序"验收（三种打包形态各一套）
- **可打包部署**：三种安装方式（单文件 / 目录 / 安装器），构建产物在 `dist/`
- **许可证**：随仓库根目录的 [`LICENSE`](../LICENSE)（MIT），本目录不另附许可声明

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
INSTALL_VERIFY ok=true version=RPV1 modules=10 node_new=true
```

`MANIFEST.txt` 同时给出每个文件的 **SHA256**（要强校验就在电脑外用系统工具核对）。发布包结构：

```
dist/rpv-bundle.lua        单文件库（93 KB）
dist/rpv.lua dist/rpv/*.lua  目录形态的库（11 个模块）
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
poc/rpv/*.lua            11 个模块：util ip route arp link icmp udp conn fabric wan node
poc/rpv/API.md           公开 API 参考（稳定面 vs 内部面）
poc/examples/            外部程序示例 + 库验收自检
poc/dist-src/install.lua 安装器源码（构建时拷进 dist/）
poc/build-dist.ps1       构建发布包（含 bundle 生成、MANIFEST、zip）
poc/apps/                项目自带应用（selftest / ftp / panel / 负载 / 网桥场景用）
poc/mc/                  真机 harness（RCON 驱动 Minecraft 服务器）+ 独立网桥程序
poc/run-*.ps1, run-all.ps1   仿真与真机回归（run-all = 25 个场景）
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
| CraftOS-PC 全量 (`pwsh -File poc\run-all.ps1`) | **46/46 PASS**（含 `lib*` 三形态、`bridge`/`bridge-wrongpsk` 网桥安全、`conn-sec`/`conn-sec-wrongpsk` 控制面 AEAD） |
| 库打包形态验收 | 目录 `require("rpv")` / 单文件 `rpv-bundle.lua` / 安装器（每文件 CRC32 校验 + 装载自检）**三种都 PASS** |
| 真机 Minecraft（Fabric / NeoForge） | lan(无线+有线) / pmtu / ftp / conn(干净+20%丢包) / cluster / wan / shim / multi / sites / range / bench / probe / load / loadrpv / longchain / endbridge / **lib** 全部 PASS |

## 设计约定

- **命名**：项目名/版本标签用 **RPV1**；代码、路径、配置键、rednet 协议串保留 `rpv` 前缀
- **网桥链路是认证的（安全边界）**：`bridge_psk`（缺失即 fail-closed）、HMAC 握手 + 每方向会话键、逐帧 tag、防重放窗口、ethertype/源 MAC 白名单、广播限速；真机被攻击者伪造/重放时合法流量不受影响
- **无限距离/跨维度 modem（Ender Modem）只作网桥**，且网桥是**独立程序**
  （[poc/mc/ender-bridge.lua](poc/mc/ender-bridge.lua)）：装成 `startup.lua`、自带配置、不 import `rpv/*`；
  `poc/rpv/*` 与 `poc/apps/*` 中不出现任何 ender modem 字样
- **rednet 只作 WAN**，不是数据面的默认路径
