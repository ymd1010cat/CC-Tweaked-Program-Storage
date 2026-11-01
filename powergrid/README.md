# Power Grid Controller v2.1（`powergrid/`）

一台 CC:Tweaked 控制终端上的**电站切换器**：负责在「主电网 / 备用电池 / 外部电网 / 关闭」
之间切换供电来源，并把状态写回配置、同时输出红石信号。附带一个 Windows 10 风格的蓝屏模块
和一张终端日志打印功能。

**本项目不含软件看门狗**：什么时候切电源由**物理看门狗**（红石计时/压力板/玩家/另一台电脑）决定，
它只需要让控制器执行一次 `power.apply(mode)`（或跑一条 `switch <mode>` 命令）。
这样切换判定不依赖 CC 程序是否还在跑——见下面「物理看门狗」一节。

## 文件

| 文件 | 说明 |
|---|---|
| `startup.lua` | 主程序。开机读取配置、恢复供电模式、进入命令循环（菜单 1–4 切换、5 打印日志、`version` 显示版本）。电源写入与配置读取都委托给 `power.lua`；配置坏了只记 `CONFIG_ERROR` 并按 `mode=1` 继续跑；库文件缺失走可读蓝屏（`MISSING_LIBRARY`），蓝屏只用于库缺失与写盘失败。 |
| `power.lua` | 配置与电源原语（**核心**）：解析/写回 `PowerGrid.ini`（`mode=` 新格式 + 旧的裸数字格式），`M.read()` 返回模式与错误码，`M.boot()` 坏配置时回落默认模式 `mode=1`，`M.errorLine()` 产出 `CONFIG_ERROR ...` 诊断行，`M.describe()` 给出人类可读说明与"用了什么默认值"，`M.apply(value)` 改 ini 里 `mode=` 那一行 + 驱动 `back` 模拟输出 + 播放 speaker 提示音。启动菜单、`switch.lua` 与任何外部脚本共用它。 |
| `switch.lua` | **超小命令行入口**（给物理看门狗/脚本用）：`switch <0-3>` → `power.apply(n)` → 打印结果；参数非法或写盘失败打印可读错误（不蓝屏，方便脚本调用）。也可作为模块：`dofile("switch.lua").run({"2"})`。 |
| `logger.lua` | 极简日志库：`logger.info/warn/error/debug`，每条按 `[tag] %Y.%m.%d %H:%M message` 追加到 `Main.log`。 |
| `bsod.lua` | 蓝屏模块：用 `window` API 铺满全屏、居中显示 `:(` / 错误码 / 失败文件，然后把父终端光标移出屏幕并 `error()` 退出。 |
| `tests/` | 离线测试套件：`run-tests.ps1`（CraftOS-PC headless 驱动）+ `startup.lua`（测试入口）+ `harness.lua`（断言与 `logs/suite.log`）+ `t_power.lua` / `t_switch.lua` / `t_libraries.lua`（断言）。 |
| `PowerGrid.ini` | **唯一的配置文件**：一行 `mode=0–3`（也兼容旧的单行裸数字）；切换时只重写 `mode=` 那一行，注释与未知键原样保留。详见下面「配置文件」一节。 |
| `.settings` | 该计算机的 CraftOS-PC 设置（目前只关了 `motd.enable`）；仅随归档副本保留，由本目录 `.gitignore` 排除，不入库。 |
| `Main.log` | 运行日志（部署期间的真实记录，仓库根 `.gitignore` 忽略 `*.log`，故不入库）。 |
| `.gitignore` | 目录级忽略规则：排除 `/.settings` 这个本机运行时副本，以及测试 staging 目录 `/.tests`。 |

## 配置文件 `PowerGrid.ini`

配置只有一个键：当前供电模式。文件是逐行 `key=value`，空行与以 `#` 开头的行是注释；
重复键以最后一行为准，未知键运行时不使用、但写回时**原样保留**（行序也不变）。

| 键 | 默认 | 取值 | 说明 |
|---|---|---|---|
| `mode` | `1`（主网） | `0`–`3` | 当前供电模式；缺失或非法时按默认 `mode=1` 继续跑 |

示例：

```
# Power Grid Controller
mode=1
```

### 旧格式兼容

老控制器写的文件**只有一行裸数字**（例如 `1`）。这种文件继续可用：读作 `mode=<数字>`；
而且 `power.lua` 对它**仍然只写裸数字**——不会擅自把老文件升级成 `key=value`。
一旦文件里出现任何 `key=value` 行就按新格式处理：`M.apply()` **只改 `mode=` 那一行**，
其它行（注释、未知键、空行）与行序全部原样保留；新格式文件里没有 `mode=` 行时，
在末尾追加一行 `mode=<值>`（只有注释的文件同样保留注释、追加 `mode=`）。

### 错误码与防故障

配置坏掉**不会**蓝屏、不会退出：读不到/空/`mode` 非法/缺 `mode=` 行时，`power.lua` 记下原因、
**按默认模式 `mode=1`（主网 Main Grid）继续跑**，启动程序只写一行 `CONFIG_ERROR`：

```
CONFIG_ERROR code=CONFIG_FILE_MISSING file=PowerGrid.ini fallback=mode=1 detail=PowerGrid.ini not found or not readable
```

随后那次启动的 `apply` 会把缺失的文件**重建出来**（旧格式裸数字 `1`，保持既有行为）。

| 新错误码 | 含义 | 旧错误码（兼容映射 `M.LEGACY_CODES`） |
|---|---|---|
| `CONFIG_FILE_MISSING` | 文件不存在 / 读不到 | `FILE_NOT_FOUND` |
| `CONFIG_FILE_EMPTY` | 文件为空（或 `mode=` 没值） | `VALUE_LENGTH_IS_ZERO` |
| `MODE_NOT_A_NUMBER` | `mode` 不是数字 | `VALUE_TYPE_NOT_CORRECT` |
| `MODE_OUT_OF_RANGE` | `mode` 不在 `0–3` | `INI_VALUE_OUT_RANGE` |
| `MODE_KEY_MISSING` | key=value 文件里没有 `mode=` 行 | `MODE_MISSING` |
| `CONFIG_WRITE_FAILED` | 写不回 `PowerGrid.ini` | `WRITE_FAILED` |

每个码都有一句人类可读说明（`M.DESCRIPTIONS`）和一句"用了什么默认值"（`M.describe` 的第二返回值），
蓝屏文案就是后者：例如 `Power Value is empty. Using mode=1 (Main Grid).`。
旧码仍可传给 `M.describe`/`M.errorLine`（内部用 `M.normalizeCode` 规范化），`M.legacyOf(新码)` 能取回旧名。

**哪些是蓝屏、哪些是容错继续跑：**

| 情形 | 行为 |
|---|---|
| 配置缺失/空/`mode` 非法/缺 `mode=` 行 | **容错**：一行 `CONFIG_ERROR`，按 `mode=1` 继续，下次 `apply` 重建 ini |
| `logger.lua` 缺失 | **蓝屏**（标题 `Missing library`，缺多个时一次列全） |
| `power.lua` 缺失 | **蓝屏**，说明"电源模式无法读取/写入，请放回 power.lua 后重启" |
| `bsod.lua` 缺失 | **无法蓝屏**，改用终端可读错误 + `error()`（文案含 `MISSING_LIBRARY bsod`） |
| 写不回 `PowerGrid.ini`（磁盘满/只读） | **蓝屏** `CONFIG_WRITE_FAILED`，说明红石已按新模式驱动、修盘后重启 |

### 库丢失（蓝屏）

`startup.lua` 的 `require` 全部走可诊断加载（`loadLibrary`）：缺库时不会只抛 `module 'x' not found`，
而是统一用 `MISSING_LIBRARY name=<模块> file=<文件>.lua` 标识、写清缺哪个、怎么办：

| 缺失的库 | 行为 | 可见信息 |
|---|---|---|
| `bsod.lua` | 无法用蓝屏自己 → 终端铺蓝底、打印可读错误后 `error()` | 屏幕首行 `Missing library`，逐行 `MISSING_LIBRARY name=bsod file=bsod.lua`；抛出的错误文本也含 `MISSING_LIBRARY bsod` |
| `logger.lua` | 仍走蓝屏（不会因为要写日志再崩一次） | 蓝屏 `file=logger`，extra 说明 `logger.lua is not in /; log lines are skipped` |
| `power.lua` | 蓝屏 | 蓝屏 `file=power`，extra 说明 `power.lua is not in /; the power mode cannot be read or written`，并在末行要求放回后重启 |
| 多个同时缺 | 一次列全 | 例如 `file=logger, power`，extra 每个一行 `MISSING_LIBRARY name=...`；可用 logger 时也逐条写日志 |

`switch.lua` 缺 `power.lua` 时**不蓝屏**（它要能被脚本调用）：打印
`switch: MISSING_LIBRARY name=power file=power.lua (cannot switch the grid)` 后返回。

## 供电模式与硬件

| 值 | 含义 |
|---|---|
| `0` | 关闭（Disable Power Grid） |
| `1` | 主电网 Main Grid |
| `2` | 备用电池 Backup Battery |
| `3` | 外部电网 External Grid |

启动时（以及每次在菜单里切换时）调用 `power.lua` 的 `M.apply(value)`：

- 写回 `PowerGrid.ini`：新格式文件只改 `mode=` 那一行，旧格式（裸数字）仍写裸数字；
- `redstone.setOutput("back", true)` 且 `setAnalogOutput("back", value)`（关闭时两者都置 0/false），
  即**红石输出固定在背面**，用模拟信号强度 1–3 区分三条供电路径；
- 若找到 `speaker` 外设，播放 `create:confirm` 提示音。

命令 5 需要 `printer` 外设：先查纸、再查墨，然后读 `Main.log`，按 40 字符宽自动折行、
每页最多 60 行分页打印（`newPage` / `endPage` + 手动 `setCursorPos` 换行）。

## 物理看门狗

**为什么不做软件看门狗：** 切换电源这件事，判定用的传感器/计时器如果也跑在 CC 里，
一旦程序崩溃、电脑被拆走或服务器卡顿，看门狗会跟着失效。把判定放到物理层（红石计时器、
压力板、玩家、另一台只发信号的电脑），控制器只负责"执行一次切换"，链路更短也更可靠；
本仓库上一版的软件 watchdog 已删除，需要时可在 git 历史里找回那套实现。

**接线：**

```
电网健康度传感器 ──(判定：物理看门狗)──> 触发信号
                                         ├─ 直接给控制器发一次命令（switch 2）
                                         └─ 或让红石信号进到控制器，由程序调 power.apply(2)
控制器背面（back）模拟输出 1–3 ──> 电源选择机构（和原来完全一样）
```

- 判定侧可以用红石比较器 + 中继器延时、漏斗计时器、玩家按按钮等；**不需要**跑任何 Lua。
- 触发侧两种做法：
  1. **命令型**：让触发信号启动/唤醒控制器上的一个程序（或用另一台电脑通过无线调制解调器
     `rednet` 发一条消息），最终执行 `switch 2`；
  2. **原语型**：在控制器的程序里直接调 `power.apply(2)`。

**直接调原语（推荐，最少代码）：**

```lua
local power = require("power")   -- 或 dofile("power.lua")

local boot = power.boot()        -- 坏配置也不会崩：回落 mode=1 并给出原因
if not boot.ok then
    logger.error(power.errorLine(boot.code, { message = boot.message }))
end

-- 物理看门狗判定"该切备用"时执行一次：
power.apply(2)                   -- 写 mode=2 + back 模拟输出 2 + speaker 响一声
```

**命令行（给脚本/别的程序调用）：**

```
switch 2      -- 切到备用电池（写 PowerGrid.ini、驱动背面模拟输出、打印结果）
switch 1      -- 回主电网
switch 0      -- 关闭
```

成功打印 `Power mode set to 2.`；参数错打印用法；写盘失败打印
`switch: CONFIG_WRITE_FAILED (...): the redstone output was still driven to 2`
（红石仍已切换，只是 ini 没写成功）。

**注意：** `power.apply()` 每次都会重写 ini 的 `mode=` 行并驱动背面输出，所以天然幂等；
物理看门狗可以随便重复触发，不需要额外状态机。真正需要"持续判定 + 回差 + 自动切回"的场合，
请在物理层实现（例如用红石锁存器记住已切到备用），而不是让 CC 程序轮询。

## 部署

**控制器**：把 `startup.lua`、`power.lua`、`switch.lua`、`logger.lua`、`bsod.lua` 与
`PowerGrid.ini`（`mode=<0–3>`；也可以仍是旧的裸数字单行）放到计算机根目录，重启即自动运行。
`Main.log` 会在首次运行后自动生成，无需预置。

**只想用切换原语**（不装控制器菜单）：放 `power.lua` + `PowerGrid.ini`（需要 speaker 时再说），
在自己的程序里 `require("power").apply(n)`；或放 `switch.lua` 直接用命令切换。

## 测试

```
pwsh -NoProfile -File powergrid/tests/run-tests.ps1
```

- staging 目录 `powergrid/.tests`，PASS 后自动删除；`-KeepStaging` 保留（可读 `logs/suite.log`），
  `-DataDir` 可换位置，`-TimeoutSec` 可调超时。
- `t_power.lua`：ini 解析矩阵（裸数字旧格式、key=value、注释/空行、未知键、缺 `mode`、非法值、
  越界码）、写回保真（只改 `mode=` 行、旧格式仍写裸数字、注释/未知键/行序/CRLF 不丢）、
  **错误码表**（新码 + `LEGACY_CODES` 旧→新映射 + `describe` 文案）、**防故障矩阵**
  （缺失/空/非数字/越界/缺 `mode=` 行 → `M.boot()` 回落 `mode=1` + 对应新码，之后 `M.apply`
  能重建 ini）、以及 `CONFIG_ERROR` 行格式，外加与旧 `startup.lua` 内联实现的**逐项等价回归**
  （同一组输入比较 ini 字节、红石调用序列、speaker 调用序列）。
- `t_switch.lua`：`switch.lua` 的参数解析（0–3 / 越界 / 非数字 / 缺参）、成功切换（ini 只改
  `mode=` 行、未知键保留、红石/ speaker 调用）、旧格式仍写裸数字、缺 `power.lua` 与写盘失败的
  可读错误、`report()` 文案、模块解析与源码钉住（不加载任何 watchdog 模块）。
- `t_libraries.lua`：用注入的 `require`/`shell`/`term` 真正执行 `startup.lua`（在缺库守卫处停下，
  不会进菜单循环），覆盖缺 `power`（蓝屏点名 + 说明读写不了）、缺 `logger`（仍蓝屏且不二次崩）、
  缺 `bsod`（终端回退 + 错误文本含 `MISSING_LIBRARY bsod`，不是裸 `module 'bsod' not found`）、
  多个同时缺（一次列全）、三个全缺。
- 跑完还检查 staged 的 `PowerGrid.ini` 字节不变、没有生成 `.settings`。
- 当前基线：`OFFLINE_PASS 388` / `OFFLINE_FAIL 0` / `OFFLINE_GROUPS 24`。

## 归档说明

- 入库范围：`startup.lua`、`power.lua`、`switch.lua`、`logger.lua`、`bsod.lua`、`PowerGrid.ini`、
  `tests/` 与本说明。
- 新增/修改的 `.lua`/`.ps1` 保持纯 ASCII（`tests/run-tests.ps1` 会检查）；`bsod.lua`
  的注释与本文档是既有中文内容，不受该规则约束。
- 历史：软件看门狗（`watchdog.lua` / `watchdog_app.lua`，含回差、一次性报警、自动切备用/切回、
  缺库降级）已按用户决定移除，实现留在 git 历史里；现在只保留 `power.lua` 的切换原语，
  由物理看门狗触发。
