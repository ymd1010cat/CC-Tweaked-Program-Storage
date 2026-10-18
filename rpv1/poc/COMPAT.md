# RPV1 版本兼容矩阵 / Version compatibility

> 结论：**在下面"已验证"两套宿主上全部通过**；其它版本不保证，但每个节点开机都会跑一次
> `compat.lua` 自检并打印 `COMPAT ok=... missing=...`，缺 API 时会明确报出来（而不是神秘崩溃）。

## 1. 已验证宿主

| 宿主 | 版本 | 状态 | 证据 |
| --- | --- | --- | --- |
| CraftOS-PC（桌面模拟器） | 2.8.3（Console），Windows | ✅ 全量通过 | `poc/run-all.ps1` **40 作业**（含离线单测 194 断言、lint 0 error） |
| CC:Tweaked + Minecraft（Fabric） | 1.120.2 / MC 1.21.1 | ✅ 通过 | `poc/mc/run-mc.ps1 -Target fabric`：`svc`/`dv`/`wansec`/`endbridge`/`lib`/`ftp` 等场景 |
| CC:Tweaked + Minecraft（NeoForge） | 1.120.2 / MC 1.21.1（NeoForge 21.1.253） | ✅ 通过（同一 CC 版本） | `-Target neoforge` 场景 |
| Java | 25（跑 MC 1.21.1 + CC:Tweaked） | ✅ | `poc/mc/ENVIRONMENT.md` |

## 2. 用到的 API 与其可用性

| API | 用途 | 要求 |
| --- | --- | --- |
| `peripheral.getType/call`、`modem` 外设 | 链路层 | 必需 |
| `rednet.open/send/broadcast/host` | WAN 接口（仅 `wan=` 配置时） | 可选 |
| `fs.open/exists/list/attributes` | 配置、日志、热加载 | 必需（`fs.attributes` 缺失时热加载自动退化为关闭） |
| `os.clock/epoch/getComputerID/version` | 计时、xid、自检 | 必需（`os.epoch` 只用 `"utc"`） |
| `bit32`（或 LuaJIT 的 `bit`） | 协议编解码 | 必需 |
| `loadstring` / `loadfile` | 模块加载、离线测试 | 必需 |
| `periphemu.create` | **仅 CraftOS-PC**：无外设环境下自建 modem | 可选（真机用真实方块） |
| `ccemux.openEmu` | **仅 CraftOS-PC**：`spawn=` 开子机测试 | 可选 |
| `settings` / `shell` / `commands` | 未使用 | — |

## 3. 刻意不依赖的东西

- **不依赖 `os.pullEvent` 之外的调度器**：所有延迟都用 `node:after`（内部 `os.startTimer`）。
- **不依赖文件系统布局**：库可 `require("rpv")`（目录形态）、`dofile("rpv-bundle.lua")`（单文件形态）
  或经 `install.lua` 安装（HTTP/软盘/目录三形态，见 `dist/README.md`）。
- **不依赖 Python / 主机工具**：库和独立程序（网桥、窃听器、跳板）都是纯 Lua，零 require。
- **不使用 AES/公钥**：CC 无大整数库，纯 Lua AES 慢且易错；完整性用 HMAC-SHA256，加密用 ChaCha20。

## 4. 自检与降级行为

| 情况 | 行为 |
| --- | --- |
| 缺必需 API（如 `fs.list`） | 打 `COMPAT ok=false missing=fs.list` + `COMPAT_UNSUPPORTED ...`，节点继续启动（能跑的部分照跑） |
| 无 `rednet` | WAN 相关配置会打 `WAN_NO_MODEM`/失败，LAN 功能不受影响 |
| 无 `periphemu`/`ccemux` | 只影响 `poc/run-*.ps1` 桌面测试（真机不需要），节点侧无影响 |
| 缺 `fs.attributes` | `routes.txt`/`role.txt` 热加载自动关闭（只在启动时读一次） |
| 无 `bit32` 也无 `bit` | `COMPAT ok=false`：协议编解码无法工作，必须换宿主 |

复现自检：任意场景看节点日志首部的 `COMPAT ok=true os=... missing=- optional=...`；
离线套件里 `tests/t_compat.lua` 也断言"本宿主不缺必需 API 且库导出了全部关键函数"。
