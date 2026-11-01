# Power Grid Controller v2.1（`powergrid/`）

一台 CC:Tweaked 控制终端上的**电站切换器**：负责在「主电网 / 备用电池 / 外部电网 / 关闭」
之间切换供电来源，并把状态写回配置、
同时输出红石信号。附带一个 Windows 10 风格的蓝屏模块和一张终端日志打印功能。

目录里另有一个 watchdog（`watchdog.lua` + `watchdog_app.lua` + `power.lua`）：
它盯住电网健康度，**持续异常时点亮告警继电器并切到备用电源，恢复后再切回原来的模式**。
注意它是"只在状态迁移那一刻动手"的看门狗，**不是持续校正的 ATS 控制器**（见下面「Watchdog」一节）。

## 文件

| 文件 | 说明 |
|---|---|
| `startup.lua` | 主程序。开机读取配置、恢复供电模式、进入命令循环（菜单 1–4 切换、5 打印日志、`version` 显示版本）。电源写入与配置读取都委托给 `power.lua`；配置坏了只记 `CONFIG_ERROR` 并按 `mode=1` 继续跑；库文件缺失走可读蓝屏（`MISSING_LIBRARY`），蓝屏只用于库缺失与写盘失败。 |
| `power.lua` | 配置与电源原语：解析/写回 `PowerGrid.ini`（key=value 新格式 + 旧的裸数字格式），`M.read()` 返回模式与错误码，`M.boot()` 坏配置时回落默认模式 `mode=1`，`M.errorLine()` 产出 `CONFIG_ERROR ...` 诊断行，`M.describe()` 给出人类可读说明与"用了什么默认值"，`M.config()` 读出 watchdog 段，`M.apply(value)` 改 ini 里 `mode=` 那一行 + 驱动 `back` 模拟输出 + 播放 speaker 提示音。启动菜单与 watchdog 共用它。 |
| `logger.lua` | 极简日志库：`logger.info/warn/error/debug`，每条按 `[tag] %Y.%m.%d %H:%M message` 追加到 `Main.log`。 |
| `bsod.lua` | 蓝屏模块：用 `window` API 铺满全屏、居中显示 `:(` / 错误码 / 失败文件，然后把父终端光标移出屏幕并 `error()` 退出。 |
| `watchdog.lua` | watchdog 的**纯逻辑状态机**（阈值、回差、持续窗口、一次性报警、切换目标/恢复开关）。不读文件、不读时钟、不碰红石，时间、读数与配置全部由调用方注入，所以能离线测。 |
| `watchdog_app.lua` | watchdog 的**运行驱动**：从 `PowerGrid.ini` 读参数，按 `poll` 秒读一次 `redstone.getAnalogInput`、驱动状态机、写日志；报警那次采样点亮告警继电器并通过 `power.lua` 切到备用，恢复那次采样切回报警前的模式。缺 `logger.lua` 退回内置终端打印、缺 `power.lua` 只告警不切换（不退出）。可当作独立程序运行，也可作为模块被测试注入假的时钟/红石/日志/电源模块。 |
| `tests/` | 离线测试套件：`run-tests.ps1`（CraftOS-PC headless 驱动）+ `startup.lua`（测试入口）+ `harness.lua`（断言与 `logs/suite.log`）+ `t_watchdog.lua` / `t_watchdog_app.lua` / `t_power.lua` / `t_libraries.lua`（断言）。 |
| `PowerGrid.ini` | **唯一的配置文件**：逐行 `key=value`（`mode` + `watchdog.*`），也兼容旧的单行裸数字格式；模式切换时会重写 `mode=` 那一行。详见下面「配置文件」一节。 |
| `.settings` | 该计算机的 CraftOS-PC 设置（目前只关了 `motd.enable`）；仅随归档副本保留，由本目录 `.gitignore` 排除，不入库。 |
| `Main.log` | 运行日志（部署期间的真实记录，仓库根 `.gitignore` 忽略 `*.log`，故不入库）。 |
| `.gitignore` | 目录级忽略规则：排除 `/.settings` 这个本机运行时副本，以及测试 staging 目录 `/.tests`。 |

## 配置文件 `PowerGrid.ini`

**所有配置都在 `PowerGrid.ini` 里**（不使用 CraftOS 的 `settings`）。文件是逐行 `key=value`，
空行与以 `#` 开头的行是注释；重复键以最后一行为准，未知键写回时**原样保留**但运行时不使用。

| 键 | 默认 | 取值 | 说明 |
|---|---|---|---|
| `mode` | `1`（主网） | `0`–`3` | 当前供电模式，控制器与 watchdog 都读写这一行；缺失或非法时按默认 `mode=1` 继续跑 |
| `watchdog.enabled` | `true` | `true/false/1/0/yes/no/on/off` | 关掉后 watchdog 不采样、不告警、不切电源 |
| `watchdog.low` | `2` | 整数 0–15 | 低于它算"低" |
| `watchdog.high` | `10` | 整数 0–15，且必须大于 `low` | 达到它算健康/恢复 |
| `watchdog.window` | `300` | 秒，`> 0` 且 `<= 604800` | 持续低多久才告警并切备用 |
| `watchdog.poll` | `10` | 秒，`>= 0.1` 且 `<= 86400` | 采样间隔 |
| `watchdog.input_side` | `bottom` | `top/bottom/left/right/front/back` | 读 `getAnalogInput` 的面 |
| `watchdog.alarm_side` | `left` | 同上 | 告警继电器输出面 |
| `watchdog.switch_to` | `2` | 整数 0–3 | 报警时切到哪个模式（2=备用电池，0=关闭，3=外部电网） |
| `watchdog.restore` | `true` | `true/false/1/0/yes/no/on/off` | 恢复时是否切回报警前的模式；`false` 则保持 `switch_to` |

示例（watchdog 键全部缺省也可以，缺省即用上表默认值）：

```
# Power Grid Controller
mode=1

# watchdog
watchdog.enabled=true
watchdog.low=2
watchdog.high=10
watchdog.window=300
watchdog.poll=10
watchdog.input_side=bottom
watchdog.alarm_side=left
watchdog.switch_to=2
watchdog.restore=true
```

### 旧格式兼容

老控制器写的文件**只有一行裸数字**（例如 `1`）。这种文件继续可用：读作 `mode=<数字>`、
watchdog 全用默认值；而且 `power.lua` 对它**仍然只写裸数字**——不会擅自把老文件升级成
`key=value`。一旦文件里出现任何 `key=value` 行就按新格式处理：`M.apply()` **只改 `mode=` 那一行**，
其它行（注释、未知键、watchdog 键、空行）与行序全部原样保留；新格式文件里没有 `mode=` 行时，
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

watchdog（`watchdog_app.lua`）**不因此退出**，按可用能力降级并各记一行：

| 缺失 | 降级 | 日志 |
|---|---|---|
| `logger.lua` | 退回内置终端打印（同样 `[tag] date time message` 形状） | `MISSING_LIBRARY name=logger fallback=print` |
| `power.lua` | 只告警、不切电源（切换尝试记 `WATCHDOG_SWITCH_FAIL reason=no_power_module`） | `MISSING_LIBRARY name=power fallback=alarm_only` |
| `bsod.lua` | 用不到（watchdog 从不蓝屏） | 无 |


watchdog 段是"非法值回落默认 + 一条可 grep 的诊断"，不会带着半套配置运行：

| 关键字 | 级别 | 含义 |
|---|---|---|
| `WATCHDOG_CONFIG` | info | 启动时的解析摘要：`path=.. format=.. mode=.. fallback=<defaults\|none> problems=<n>`（format = `keyvalue` / `legacy` / `comments` / `empty` / `missing`） |
| `CONFIG_ERROR` | warn | 与控制器同一行的配置诊断：`code=.. file=.. fallback=defaults detail=..` |
| `WATCHDOG_CONFIG_BAD` | warn | 非法值：`key=watchdog.low value=abc fallback=2 reason=..` |
| `WATCHDOG_CONFIG_BAD` | warn | 杂行：`line=<原文> fallback=ignored` |
| `WATCHDOG_CONFIG_BAD` | warn | 未知键：`key=<键> value=<原文> fallback=ignored`（写回时保留） |
| `WATCHDOG_CONFIG_FAIL` | warn | 整个 ini 读不到：`code=CONFIG_FILE_MISSING fallback=defaults` |


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

## Watchdog（触发切备用、恢复切回；不是持续 ATS）

**它做什么：** 电网读数持续偏低满 `window` 秒 → 点亮告警继电器，并**切到备用电源
（`watchdog.switch_to`，默认 `2` 备用电池）**；读数回到 `high` → 熄灭告警，
并按 `watchdog.restore`（默认 `true`）**切报警前的那个模式**。

**它不做什么：** 不是持续 ATS 控制器——只在**报警/恢复这两个状态迁移点各动作一次**，
不会每轮轮询去校正模式。所以报警期间你手动按 1/3 改模式，它不会跟你抢着改回去；
但恢复那一刻默认仍会切回"报警前的模式"（这是 `restore=true` 的定义），
不想要这个行为就在 ini 里写 `watchdog.restore=false`，恢复时保持备用。

### 状态机

参数为 `low`（默认 2）、`high`（默认 10）、`window`（默认 300 秒）、`poll`（默认 10 秒）。
每次采样把读数分成三档：

| 读数区间 | 含义 | 对状态的影响 |
|---|---|---|
| `level >= high` | 健康 | 解除告警（如果已告警）、清空"持续低"计时 |
| `low <= level < high` | 缓冲带（回差） | **什么都不改变**：报警保持、计时继续 |
| `level < low` | 低 | 从这一刻开始记"持续低"；满 `window` 秒触发一次告警 |

由此得到的语义：

- **只报一次、只切一次**：同一次异常里，告警与切换只在"低"采样且累计满 `window` 时发生一次；
  之后继续低、继续波动都不会重复报/重复写盘，直到恢复。
- **只有回到 `high` 才算恢复**：读数回到 `low`..`high`（缓冲带）不会解除告警，也不清累计计时
  ——这正是回差防抖。因此在 `low`..`high` 之间反复抖动的电网，`window` 秒后仍会告警并切备用。
- 计时起点取自**第一次跌破 `low` 的采样**，`poll` 只决定检测粒度（越大越迟才发现，不会提前动）。
- 状态机不读时钟：`watchdog_app` 每次把 `os.clock()` 传进去，测试则传虚拟时间。

### 切换 / 恢复语义

| 时刻 | 动作 | 日志 |
|---|---|---|
| 报警那次采样 | 告警继电器置 `true`；`power.lua` 读当前模式，若已是 `switch_to` 则什么都不写，否则写入 `switch_to` | `WATCHDOG_ALARM ...` 后接 `WATCHDOG_SWITCH from=1 to=2 reason=low level=1`（已是目标模式时 `WATCHDOG_SWITCH to=2 noop`） |
| 恢复那次采样 | 告警继电器置 `false`；`restore=true` 时切回报警前模式，`restore=false` 保持备用；报警前模式未知（当时的切换是 noop）则不动 | `WATCHDOG_CLEAR ...` 后接 `WATCHDOG_RESTORE to=1`（或 `WATCHDOG_RESTORE_SKIP reason=restore_disabled` / `reason=no_switch`） |
| 任何其它采样 | 只更新状态机与日志，**不动电源、不动继电器** | 无 |

失败路径都只写日志、不会拖垮监视：缺 `power.lua` → `WATCHDOG_SWITCH_FAIL reason=no_power_module`；
读不到当前模式 → `reason=read_fail code=<新错误码>`；写盘失败 → `reason=write_failed code=CONFIG_WRITE_FAILED`
（此时不会记"已切换"，恢复时也就不会乱切）。ini 缺失/非法时 watchdog 用默认参数继续跑，
启动的 `WATCHDOG_CONFIG` 汇总行会带 `fallback=defaults`。

### 参数

watchdog 的全部参数都在 `PowerGrid.ini` 的 `watchdog.*` 键里（键表与默认值见上面「配置文件」一节）。
watchdog 只在启动时读一次 ini，改完要重启 `watchdog_app` 才生效。`low >= high` 属于非法组合：
两个值都会回落到默认（2/10），并各记一条 `WATCHDOG_CONFIG_BAD`。

### 日志关键字

沿用 `logger.lua` 的格式 `[tag] YYYY.MM.DD HH:MM message`，所以按**关键字** grep，而不是按 tag：

| 关键字 | logger 级别 | 含义 |
|---|---|---|
| `WATCHDOG_START` | info | 监视启动（含 input/alarm/low/high/window/poll/switch_to/restore） |
| `WATCHDOG_ALARM` | error | 告警拉高（含 side/level/low/high/window/sustained） |
| `WATCHDOG_SWITCH` | info | 切到备用：`from=X to=Y reason=low level=Z`；已是目标模式则 `to=Y noop` |
| `WATCHDOG_SWITCH_FAIL` | warn | 切换没做成：`reason=no_power_module` / `read_fail code=..` / `write_failed code=..` |
| `WATCHDOG_CLEAR` | info | 恢复到 `high`，告警复位 |
| `WATCHDOG_RESTORE` | info | 恢复切回：`to=<报警前模式>`（或 `to=.. noop`） |
| `WATCHDOG_RESTORE_SKIP` | info | 不切回：`reason=restore_disabled` / `reason=no_switch` |
| `WATCHDOG_RESTORE_FAIL` | warn | 恢复时读/写失败（保留记录，可在下一轮再试） |
| `WATCHDOG_DISABLED` | warn | `enabled=false`，不采样不驱动不动电源 |
| `WATCHDOG_CONFIG_BAD` | warn | 一条非法的 ini 值 / 杂行 / 未知键（见上面「配置文件」一节） |
| `WATCHDOG_CONFIG` | info | 启动时的 ini 解析摘要（path/format/mode） |
| `WATCHDOG_CONFIG_FAIL` | warn | 整个 ini 读不到，加载默认值 |
| `WATCHDOG_READ_FAIL` | warn | 读不到传感器（第一次，之后每 60 次一条） |
| `WATCHDOG_RELAY_FAIL` | warn | 告警面写不出去（无 redstone API 等） |
| `WATCHDOG_STATUS` | info | 按需输出的单行状态（`M.report`） |
| `WATCHDOG_CRASH` | error | 主循环异常退出（只记录，不重启循环） |

### 接线建议

- **输入**：把电网健康度（电压/电量比例）用比较器或能量感应器变成 0–15 的模拟红石，
  接到 `input_side`（默认下方）。断网/空载时读数自然掉到 0，正好落在"低"。
- **告警**：`alarm_side`（默认左面）接红石灯、警报器或红石无线发送器；告警时输出 `true`，
  恢复/启动时输出 `false`。
- **电源输出**：watchdog 切换模式时用的是它自己这台电脑背面的模拟输出（和控制器同一套
  `power.lua`）。所以要把**监看电脑的背面输出与控制器背面输出接到同一路电源选择信号**
  （红石线并接、或用红石无线发送器转一次），实际电源切换机构才能看到 `2`/`1`。
- **两台电脑各自记一份 ini**：`PowerGrid.ini` 是每台电脑本地的。watchdog 只写自己这台；
  控制器界面显示的模式在切换后可能变旧，人工在控制器上按一次对应模式即可对齐
  （或者干脆以监看电脑的 `Main.log` / ini 为准）。
- **独立电脑**：一台 CC 电脑同时只能跑一个程序，控制器菜单会阻塞在 `io.read()`，
  所以推荐用另一台监看电脑跑 `watchdog_app`。把轮询塞进控制器主循环本项目刻意不做——
  那就变成持续 ATS 了。

### 运行、部署与真机自测

监看电脑根目录放 `power.lua`、`watchdog.lua`、`watchdog_app.lua`、`logger.lua`
与 `PowerGrid.ini`（`mode=` 加上需要的 `watchdog.*` 键；只写一行裸数字也行，watchdog 全用默认值），然后：

```
watchdog_app
```

即可按 `poll` 秒循环监视；想开机自启就把 `watchdog_app.lua` 复制成 `startup.lua`
（注意那时这台电脑就没有控制器菜单了）。`watchdog_app.lua` 只有在"它自己就是正在运行的程序"
时才自动进入循环，被别的程序 `dofile`/`require` 时只返回模块表。

真机自测顺序（把节奏调快，改 ini 后重启 `watchdog_app`）：

1. ini 里设 `watchdog.window=10`、`watchdog.poll=1`；
2. `watchdog_app`，确认日志出现 `WATCHDOG_CONFIG path=PowerGrid.ini format=keyvalue mode=1`
   与 `WATCHDOG_START ... switch_to=2 restore=1`；
3. 把输入面的模拟信号**拉到 0**（断开比较器输入），约 10 秒后应看到
   `WATCHDOG_ALARM ...` + `WATCHDOG_SWITCH from=1 to=2 reason=low level=0`，
   ini 里 `mode=` 变成 `2`、背面模拟输出变 2、告警面亮；
4. 把输入**拉回 10 以上**，应看到 `WATCHDOG_CLEAR ...` + `WATCHDOG_RESTORE to=1`，
   `mode=` 回到 `1`、背面输出 1、告警灭；
5. 把 `watchdog.restore=true` 改成 `false` 再跑 3/4：切到 2 后恢复时保持 2
   （日志 `WATCHDOG_RESTORE_SKIP reason=restore_disabled`）；
6. 想把"备用"改成别的目标就设 `watchdog.switch_to=3`；
   `watchdog.enabled=false` 则完全不告警、不动电源。

### 测试

```
pwsh -NoProfile -File powergrid/tests/run-tests.ps1
```

- staging 目录 `powergrid/.tests`，PASS 后自动删除；`-KeepStaging` 保留（可读 `logs/suite.log`），
  `-DataDir` 可换位置，`-TimeoutSec` 可调超时。
- `t_watchdog.lua`：纯状态机（注入虚拟时钟）——窗口、回差、一次性报警、恢复条件、配置校验、
  `status()` 文本、`switch_to`/`restore` 参数（非法值以结构化问题记录回落默认）。
- `t_watchdog_app.lua`：用假红石/假 logger/假时钟 + **真实的 `power.lua`**（写测试专用 ini）断言：
  参数全部来自 ini（并注入一个"会说 enabled=false"的 settings 假实现，证明运行时完全忽略它）、
  非法值/杂行/未知键的 `WATCHDOG_CONFIG_BAD` 行、`WATCHDOG_CONFIG` 汇总行的 `fallback=` 标记、
  缺 ini 时记 `CONFIG_ERROR` 但继续采样/报警、报警那次只切一次（ini 变 `2\n`、`back` 得到
  `setOutput(true)`+`setAnalogOutput(2)`、speaker 响一声）、恢复切回 `1\n`、`restore=false` 保持 2、
  已在目标模式 noop、手动改模式不被每轮校正、`enabled=false` 全程不动电源/继电器、
  缺模块/读失败/写失败的日志与"不记已切换"。
- `t_power.lua`：ini 解析矩阵（裸数字旧格式、key=value、注释/空行、未知键、缺 `mode`、非法值、
  越界码）、写回保真（只改 `mode=` 行、旧格式仍写裸数字、注释/未知键/行序/CRLF 不丢）、
  `M.config()` 的 watchdog 段与 `M.WATCHDOG_KEYS` 映射、**错误码表**（新码 + `LEGACY_CODES` 旧→新
  映射 + `describe` 文案）、**防故障矩阵**（缺失/空/非数字/越界/缺 `mode=` 行 → `M.boot()` 回落
  `mode=1` + 对应新码，之后 `M.apply` 能重建 ini）、以及 `CONFIG_ERROR` 行格式，外加与旧
  `startup.lua` 内联实现的**逐项等价回归**（同一组输入比较 ini 字节、红石调用序列、speaker 调用序列）。
- `t_libraries.lua`：用注入的 `require`/`shell`/`term` 真正执行 `startup.lua`（在缺库守卫处停下，不会进菜单循环），
  覆盖缺 `power`（蓝屏点名 + 说明读写不了）、缺 `logger`（仍蓝屏且不二次崩）、缺 `bsod`（终端回退 +
  错误文本含 `MISSING_LIBRARY bsod`，不是裸 `module 'bsod' not found`）、多个同时缺（一次列全）、
  三个全缺；以及 watchdog 缺 `logger`/`power` 的降级行（`MISSING_LIBRARY name=.. fallback=..`）与内置打印回退。
- 跑完还检查 staged 的 `PowerGrid.ini` 字节不变、没有生成 `.settings`。
- 当前基线：`OFFLINE_PASS 864` / `OFFLINE_FAIL 0` / `OFFLINE_GROUPS 41`。

## 部署

**控制器**：把 `startup.lua`、`power.lua`、`logger.lua`、`bsod.lua` 与 `PowerGrid.ini`
（`mode=<0–3>`，可以带 `watchdog.*` 键；也可以仍是旧的裸数字单行）放到计算机根目录，
重启即自动运行。`Main.log` 会在首次运行后自动生成，无需预置。

**监看电脑**（可选）：放 `power.lua`、`watchdog.lua`、`watchdog_app.lua`、`logger.lua`
与 `PowerGrid.ini`（`mode=` + 需要的 `watchdog.*`），按上面「Watchdog」一节运行。

## 归档说明

- 入库范围：`startup.lua`、`power.lua`、`logger.lua`、`bsod.lua`、`watchdog.lua`、
  `watchdog_app.lua`、`PowerGrid.ini`、`tests/` 与本说明。
- 新增/修改的 `.lua`/`.ps1` 保持纯 ASCII（`tests/run-tests.ps1` 会检查）；`bsod.lua`
  的注释与本文档是既有中文内容，不受该规则约束。
