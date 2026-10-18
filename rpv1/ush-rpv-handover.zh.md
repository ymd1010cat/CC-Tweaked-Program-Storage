# 交接文档：unixshell 内置 rpv 传输层（中文版）

> 仓库内的英文版：[HANDOFF-rpv.md](C:\Users\ymd10\Documents\DSHWork\cc_tweaked\unixshell\HANDOFF-rpv.md)（仓库内必须 ASCII，因为该项目的 gate 2 会扫描 `.md`，只豁免 `README.md`）。
> 本文件在仓库外，中文，可随意阅读/修改。

## 一、这次合并做了什么

unixshell 原来直接用 rednet。现在所有联网调用都经过**一层薄传输层**：能跑 rpv 时走内置的 RPV1 协议栈，跑不了就**原样回退 rednet**。命令本身没改 —— 仍然调 `send` / `receive` / `broadcast` / `open` / `close` / `isOpen`，只是对象从 `rednet` 变成 `rpvnet`。

| 位置 | 内容 |
|---|---|
| `rpv/` | 内置的 RPV1 协议栈（19 模块 + `node.lua` + `loader.lua` + `node-start.lua` + `MERGE-rpv.md`）。**唯一本地改动**：给 `node.lua` 加了有界 `pump()`，让单线程 shell 能驱动协议栈，而不是把进程交给 `node:run()` |
| `lib/rpvnet.lua` | 传输层：rednet 同形 API、后端选择、协议名→端口映射、`RN1\|协议\|电脑ID\|载荷` 信封、发现广播 + 应答、地址归一化、rednet 委托 |
| 10 个文件 | `rednet.` → `rpvnet.`，共 **28 处**：`lib/xfer.lua`（rget/rput 的文件流）、`lib/rexec.lua`、`lib/pkg.lua`、`lib/netcfg.lua`、`lib/license.lua`、`lib/sysinfo.lua`、`netd.lua`、`pkgserver.lua`、`authserver.lua`、`usr/ush.lua` |
| `lib/netcmds.lua`、`usr/cmd/{rget,rput,rexec}.lua` | 经核对**没有直接 rednet 调用**（走 `xfer`/`rexec`）⇒ 已间接接入 ✓ |
| `etc/network.conf` | 新增 `transport`、`rpv_side`、`rpv_cidr`、`rpv_channel`、`rpv_mtu`、`rpv_peer_<id>` |
| `tests/batch3_check.lua` | 新增 rpv 传输用例（见第四节） |

## 二、怎么用

```
transport=auto     内置栈能加载且 modem 侧有 modem 时走 rpv，否则 rednet（默认）
transport=rpv      强制 rpv；起不来就报错，而不是悄悄回退
transport=rednet   一直用 rednet
```

rpv 需要地址与二层频道，二者默认都由 modem 侧与电脑 ID 推出，一队机器**不用逐台配置**：

```
rpv_side=back              接口的 modem 侧（缺省取 modem_side）
rpv_cidr=10.0.4.<id>/24    地址（缺省按电脑 ID 生成）
rpv_channel=4700           二层频道
rpv_mtu=512
rpv_peer_<id>=<地址>       可选静态 id→地址映射，省掉发现广播
```

**rpv 与 rednet 是两套线上协议，不能互通** —— 一次会话两端必须同一种传输；`auto` 既让老机器继续可用，也让 PC 侧测试套件保持跑在 rednet 路径上。

线上格式：一条消息 = 一个 UDP 数据报，端口由协议名哈希决定（`rpvnet.port_of("pkg-repo")`，稳定、落在 20000–39999），封装为 `RN1|协议|电脑ID|载荷` —— 收方因此直接得知发送方 ID 与来源地址；未知 ID 先用发现端口（19999）广播一次。

## 三、怎么验收

```powershell
# PC 侧（任一台机器）
python tests/run_all.py            # 门禁 + 套件
python tests/run_all.py --gates    # 只跑五道门禁
```

期望：`exit 0`、gate 1–5 全过、`class3 pass 111 fail 0`、`batch3 pass 110 fail 0`、套件断言 718 全过。本机用的是捆绑 Python（`…\dsh-runtimes\…\python.exe`）+ `lupa`。

```powershell
# 真机两机验收（本机可用的那条路）
pwsh -File C:\Users\ymd10\Documents\DSHWork\_ush-mc-verify.ps1
```

它会：在专用 Fabric 服务器上放两台电脑（四侧放无线 modem）+ 只部署 `lib/` 与 `rpv/` + 写入收发驱动 + 断言。期望输出：
`RESULT ush-rpv-mc done=True verdict=PASS phase1=True phase2=True server_got=True`

## 四、已验证到什么程度（三层证据）

1. **PC 侧（任何机器可跑）**：传输层能加载、形状完整、协议→端口稳定、状态可报；本环境无 modem ⇒ `auto` 回退 rednet 并把 `send` 原样交给 rednet。另外在**同一进程**里构造两个内置栈节点，用手搓以太帧把 IP/UDP 数据报投进已绑定 socket，**校验源地址与载荷** —— 这一步真的跑了 `on_frame`、IP/UDP 校验和、socket 查找与载荷。
2. **单台真机**：节点构造正确（地址/网络/前缀/MAC 全是数字）、栈的 `udp_send` 可用、`rpvnet.send` 可用。发往**自身** ID 的包是交给线上的（只有 127/8 本地投递），所以单机**无法**证明投递 —— 这点我踩过并纠正过。
3. **两台真机（Minecraft）**：两侧 `avail=true transport=rpv`、ARP 解析成功、服务端出现 `UDP_RECV`，且**两条路径都完成往返**：静态映射（`rpv_peer_21=10.0.4.21`）与移除映射后的**发现广播 + 应答**。`verdict=PASS`。

## 五、真机三条硬约束（都写进了 `rpv/MERGE-rpv.md`）

1. **磁盘配额**：完整 shell 树 1,037,846 B，而 CraftOS 电脑文件系统超过 `computer_space_limit`（`config/computercraft-server.toml`，默认 1,000,000）会**拒绝启动** —— 症状极迷惑：`turn-on` 报成功但 `startup.lua` 一行都不跑。要么调大配额（需**重启服务器**，启动时读取），要么只投 `lib/` + `rpv/`（704,497 B，够传输用）。
2. **modem 必须朝向电脑才算外设**：仅相邻不够，`facing` 不指向电脑时方块在位但 `peripheral.getNames()` 看不到。稳妥做法：四侧各放一个、各自指向电脑（`+X: facing=west`、`-X: east`、`-Z: south`、`+Z: north`），程序扫描取第一个 modem。
3. **`periphemu` 只存在于 CraftOS-PC**，真机程序要 `if periphemu then … end`。

## 六、踩过的坑（值得记住）

1. **信封标签 `RN1` 含数字，解析必须用 `%w`**；用 `%a` 会导致每个信封解析失败、收方默默吞包不回包 —— 而 node 日志**仍然显示 `UDP_RECV`**，极具迷惑性。这是合并最后一个 bug，PC 侧桩因为走 rednet 回退而覆盖不到。
2. **绝不要用 `loadfile` 手工拼装内置库**：`rpv/node.lua` 会装上 rednet shim，静默改写整机 rednet 行为（测试里打挂过 32 条用例）。`lib/rpvnet.lua` 只走 `require("loader")`，失败即回退。
3. **Lua 5.1 兼容**：CraftOS 没有 `~` 位运算（5.3+）。我第一版端口哈希用了它 —— 本机门禁全绿但上机必崩。已改纯算术。
4. **`udp_send` 要数字地址**：`rpv_peer_<id>` 从配置读出来是字符串 ⇒ 统一走 `to_ip()`。
5. **排查神器**：`computer/<id>/rpv-log.txt`（`ARP_QUEUED`/`ARP_RESOLVED`/`ARP_REPLY`/`UDP_NO_PORT`/`UDP_RECV`/`IFACE`/`CHANNEL_AUDIT`）—— 一眼分辨"链路问题"还是"协议问题"。

## 七、未完成 / 下一步

- **插件问题已彻底解决，而且不用降级** ✓✓：我按你的要求**自己把插件编译出来了**。
  - 事实链：插件不在任何 CraftOS-PC 发布包里（安装器/便携包我都解包确认过 ✓）；插件仓库的预编译 `x64-windows/ccemux.dll` 是 **Lua 5.1** 构建（导入 `lua51.dll`）⇒ 在 2.8.3（Lua 5.2）无法加载 ✗，**但源码已经为 5.2 适配**（提交 `7ceb0db9`，2025-12-06，"Updated for Lua 5.2"）⇒ 只是**二进制没重建** ✓。
  - 于是我装了 **VS Build Tools 2022**，取 `ccemux.cpp` + craftos2 **v2.8.3** 的 `api/*.hpp`（7 个头）+ **Lua 5.2.4** 头 + **SDL2** 开发头，用 `dumpbin`+`lib` 从 `lua52.dll`/`SDL2.dll` 生成导入库，然后：
    ```
    cl /LD /std:c++17 /EHsc /O2 /MD /I<api> /I<lua> /I<sdl-inc> ccemux.cpp ^
       /link /OUT:ccemux.dll lua52.lib SDL2.lib shell32.lib
    ```
    （必须 `/std:c++17`，SDK 头用了 `std::filesystem`；`shell32.lib` 提供 `ShellExecuteW` ✓）
  - 产物 **34,816 B**、导入 `lua52.dll` ✓。**先在 2.8.3 副本**上验证（`ccemux=table` ✓、`openEmu(21) ok=true` ✓、21 号机启动 ✓）**再**提权换回安装目录 ✓。
  - **最终状态**：安装目录 = **CraftOS-PC 2.8.3（最新版）+ `plugins\ccemux.dll`（自编译）** ✓；实测 `ccemux=table` ✓、多机派生 ✓；**rpv1 的 bridge 多机场景恢复 `verdict=PASS`**（5 台机、两桥 `paired=true`）✓、单机 `run-offline` **PASS 394 / lint 0** ✓、unixshell 门禁 **exit=0**（class3 111/0、batch3 110/0）✓。
  - 过程中我一度把安装降级到 2.7.5（Lua 5.1 + 旧预编译 DLL，能跑 ✓）作为临时可用方案；编译成功后已**恢复回 2.8.3** ✓。那次用的 2.7.5 便携版与旧预编译 DLL 已删除（可重新下载 ✓）。
- **两项待办现在都已完成** ✓（2026-10-11 更新；细节与证据见 unixshell 仓库的 `HANDOFF-rpv.md` 第 9、10 节）
  1. **A. 模拟器上补跑两机验收 —— 已完成** ✓（我做的）：用 bash 版 `tools/rpv-verify/_ush-rpv-verify3.sh` 实测 `RESULT ush-rpv-emu verdict=PASS phase1=yes phase2=yes server_got=yes` ✓ —— 客户端 `SPAWNED peripheral=modem` ✓ → `REQUIRE ok=true` ✓ → `BACKEND avail=true transport=rpv` ✓ → 静态映射回包 `PHASE1 reply from=21 reply-from-21` ✓ → 发现广播回包 `PHASE2 reply from=21 reply-disc` ✓ → `SELFTEST ok=true` ✓；服务端 `SERVER backend=rpv` ✓ + `GOT ush-test from=20` ✓ + `GOT ush-disc from=20` ✓。只投 `lib/` + `rpv/`（769,767 B）以避开 `computer_space_limit` ✓。
     - **踩坑**：若把驱动拆成 `startup-real.lua` 用 `loadfile` 加载，chunk 里**看不到 shell 的 `package` 表** ⇒ `package.path = …` 报 `attempt to index a nil value (global 'package')` ✗；改成把驱动**内联进 `startup.lua`** 即通过 ✓。
  2. **B. `rget`/`rput` 大文件分块验收 —— 已完成** ✓（**另一个会话早就做完并写进 ASCII 交接文档** ✓，我这次只是确认）：`RESULT ush-rpv-file server=PASS` ✓ —— 200,000 B 文件双向走真实命令分发（`netcmds.main`，即 `usr/cmd/rget.lua`/`rput.lua` 的入口 ✓）、49 个分块、整文件 CRC32 两端一致 ✓（`crc=4c790f2d` ✓）、`REASM_DROP` 全程 0 ✓。那轮还**揪出并修掉了 `lib/xfer.lua` 两个真 bug**：① 推送请求把整文件塞进一条消息（200 KB → 218 KB 单包 ✗ 448 个分片，对端永远重组不出来 ✗）；② 重组预算太小（原 16 项/64 KB ✗），现在可配 `reasm_bytes`/`reasm_entries`（缺省 524288/128 ✓）。
- **验收脚本已出 bash 版** ✓（本机 shell 是 Git for Windows bash 且没有 `pwsh` ✓）：`tools/rpv-verify/` 下 `_ush-rpv-probe.sh`、`_ush-rpv-verify3.sh`、`_ush-mc-verify.sh`、`_ush-mc-rawlink.sh`、`_ush-mc-probe.sh`（全部 `bash -n` 通过 ✓，其中探针与模拟器两机验收已实跑 ✓）；PowerShell 原版移到 `tools/rpv-verify/ps1/` ✓，仍可用 `powershell -File "ps1\<脚本>.ps1"` 运行 ✓（那里面另有 5 个只有 PS 版的脚本，其中 `_ush-mc-file.ps1`/`_ush-rpv-file.ps1` 就是 B 用的那两个 —— 已跑通 ✓，改成 bash 只是可选的便利 ✓）。





## 八、产物位置（已按"DSHWork 只放工作区"整理过）

**验收脚本（随项目走，在 unixshell 仓库里）**：

```
C:\Users\ymd10\Documents\DSHWork\cc_tweaked\unixshell\tools\rpv-verify\
  README.md              这套脚本的说明（英文/ASCII，因为仓库 gate 2 只豁免 README.md）
  *.sh                   bash 版（当前 shell 用这套）：_ush-rpv-probe / _ush-rpv-verify3 /
                         _ush-mc-verify / _ush-mc-rawlink / _ush-mc-probe
  ps1\                   PowerShell 原版（用 powershell -File 跑）；另含 5 个只有 PS 版的
                         脚本：_ush-mc-file / _ush-rpv-file（B 用的那两个，已跑通）、
                         _ush-disk-probe / _ush-disk-store、_ush-mc-server
```

**机器本地工件（不在 DSHWork，也不在仓库里）**：

```
C:\Users\ymd10\AppData\Local\rpv-craftos\
  plugin\src\            ccemux.cpp + SDK 头 + 编好的 ccemux.dll
  plugin\headers\        Lua 5.2.4 头 + SDL2 头（重建插件用）
  backup-283\            CraftOS-PC 2.8.3 安装副本（回滚用）
  work\                  脚本用的探针数据目录（ccemux-probe / ush-rpv-test）
  install-283-with-plugin.ps1   提权恢复 2.8.3 + 装插件（路径已改好）
```

**本文件**：`C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\ush-rpv-handover.zh.md`（放在 rpv1 工作区里，这样 DSHWork 根目录只留工作区 ✓）。

> 已删除的临时件：VS 引导器、便携版 CraftOS-PC（2.7.5 / 2.8.3）、插件下载缓存（Lua/SDL2 压缩包）、旧预编译 DLL、以及被取代的中间脚本（`_ush-rpv-verify.ps1/2`、`_ush-rpv-loop.ps1`、`_ush-mc-bisect.ps1`）——都可重新下载/重建 ✓。


> 说明：Fabric 测试服务器我用官方安装器补回了 `libraries/`（动的是 `rpv1\mc-server-fabric\`，你的整合包没碰），验收跑完已停 ✓。
