# Power Grid Controller v2.1（`powergrid/`）

一台 CC:Tweaked 控制终端上的**电站切换器**：负责在「主电网 / 备用电池 / 外部电网 / 关闭」
之间切换供电来源，并把状态写回配置、
同时输出红石信号。附带一个 Windows 10 风格的蓝屏模块和一张终端日志打印功能。

目录里另有一个**只监测、只告警的 watchdog**（`watchdog.lua` + `watchdog_app.lua`）：
它盯住电网健康度、持续异常时点亮告警继电器，但**绝不切换供电来源**——
自动切换（ATS）是明确出界的功能，见下面「Watchdog」一节。

## 文件

| 文件 | 说明 |
|---|---|
| `startup.lua` | 主程序。开机读取配置、恢复供电模式、进入命令循环（菜单 1–4 切换、5 打印日志、`version` 显示版本）。 |
| `logger.lua` | 极简日志库：`logger.info/warn/error/debug`，每条按 `[tag] %Y.%m.%d %H:%M message` 追加到 `Main.log`。 |
| `bsod.lua` | 蓝屏模块：用 `window` API 铺满全屏、居中显示 `:(` / 错误码 / 失败文件，然后把父终端光标移出屏幕并 `error()` 退出。 |
| `watchdog.lua` | watchdog 的**纯逻辑状态机**（阈值、回差、持续窗口、一次性报警）。不读文件、不读时钟、不碰红石，时间与读数全部由调用方注入，所以能离线测。 |
| `watchdog_app.lua` | watchdog 的**运行驱动**：按 `poll` 秒读一次 `redstone.getAnalogInput`、驱动状态机、写日志、把告警面置位/复位。可当作独立程序运行，也可作为模块被测试注入假的时钟/红石/日志。 |
| `tests/` | 离线测试套件：`run-tests.ps1`（CraftOS-PC headless 驱动）+ `startup.lua`（测试入口）+ `harness.lua`（断言与 `logs/suite.log`）+ `t_watchdog.lua` / `t_watchdog_app.lua`（断言）。 |
| `PowerGrid.ini` | 配置兼状态文件，只有一行数字 `0`–`3`，每次切换都会重写。**watchdog 的参数不放在这里**（见下）。 |
| `.settings` | 该计算机的 CraftOS-PC 设置（目前只关了 `motd.enable`）；仅随归档副本保留，由本目录 `.gitignore` 排除，不入库。 |
| `Main.log` | 运行日志（部署期间的真实记录，仓库根 `.gitignore` 忽略 `*.log`，故不入库）。 |
| `.gitignore` | 目录级忽略规则：排除 `/.settings` 这个本机运行时副本，以及测试 staging 目录 `/.tests`。 |

## 供电模式与硬件

| 值 | 含义 |
|---|---|
| `0` | 关闭（Disable Power Grid） |
| `1` | 主电网 Main Grid |
| `2` | 备用电池 Backup Battery |
| `3` | 外部电网 External Grid |

启动时执行 `applyPower(power)`：

- 以 `tostring(value) .. "\n"` 的形式写回 `PowerGrid.ini`；
- `redstone.setOutput("back", true)` 且 `setAnalogOutput("back", value)`（关闭时两者都置 0/false），
  即**红石输出固定在背面**，用模拟信号强度 1–3 区分三条供电路径；
- 若找到 `speaker` 外设，播放 `create:confirm` 提示音。

命令 5 需要 `printer` 外设：先查纸、再查墨，然后读 `Main.log`，按 40 字符宽自动折行、
每页最多 60 行分页打印（`newPage` / `endPage` + 手动 `setCursorPos` 换行）。

## 配置校验（启动时）

`PowerGrid.ini` 缺失、为空、非数字或超出 `0–3` 范围时，会先写日志再进入蓝屏，错误码分别为
`FILE_NOT_FOUND` / `VALUE_LENGTH_IS_ZERO` / `VALUE_TYPE_NOT_CORRECT` / `INI_VALUE_OUT_RANGE`。

## Watchdog（只监测告警，不做 ATS）

**范围边界：watchdog 只做两件事——记录 + 点亮告警继电器。它不调用 `applyPower`、
不写 `PowerGrid.ini`、不碰控制器背面的模拟输出，因此不会自动切换供电来源。
自动切换（ATS）是明确出界的，切换电源仍然只能由人在控制器菜单里按 1–4。**

### 状态机

参数为 `low`（默认 2）、`high`（默认 10）、`window`（默认 300 秒）、`poll`（默认 10 秒）。
每次采样把读数分成三档：

| 读数区间 | 含义 | 对状态的影响 |
|---|---|---|
| `level >= high` | 健康 | 解除告警（如果已告警）、清空"持续低"计时 |
| `low <= level < high` | 缓冲带（回差） | **什么都不改变**：报警保持、计时继续 |
| `level < low` | 低 | 从这一刻开始记"持续低"；满 `window` 秒触发一次告警 |

由此得到的语义：

- **只报一次**：同一次异常里，报警只在"低"采样且累计满 `window` 时触发一次；
  之后继续低、继续正常波动都不会重复报，直到恢复。
- **只有回到 `high` 才算恢复**：读数回到 `low`..`high` 之间（缓冲带）不会解除告警，
  也不会清掉累计计时——这正是回差防抖：电网必须真正恢复健康才清除告警。
  因此一个在 `low`..`high` 之间反复抖动的电网，`window` 秒后仍会告警（这是刻意的）。
- 计时起点取自**第一次跌破 `low` 的采样**，`poll` 只决定检测的粒度（`poll` 越大越迟才发现，
  不会提前报）。
- 状态机不读时钟：`watchdog_app` 每次把 `os.clock()` 传进去，测试则传虚拟时间。

### 参数（CraftOS `settings`，每台电脑单独保存）

`PowerGrid.ini` 的语义保持"单值 0–3"不变，所以 watchdog 的参数放到 CraftOS 的 `settings`，
用 shell 的 `set` 命令改（`set` 程序会调用 `settings.save()`，所以重启后仍然有效；
如果自己写 `settings.set`，要记得再 `settings.save()`）；非法值一律回落到默认值并写一条
`WATCHDOG_CONFIG_BAD`（不会带着半套配置运行）。

| settings 键 | 默认 | 合法值 | 说明 |
|---|---|---|---|
| `powergrid.watchdog.enabled` | `true` | `true/false/1/0/yes/no/on/off` | 关闭后完全不采样、不驱动红石，只写一条 `WATCHDOG_DISABLED` |
| `powergrid.watchdog.low` | `2` | 整数 0–15 | 低于它算"低" |
| `powergrid.watchdog.high` | `10` | 整数 0–15，且必须大于 `low` | 达到它算健康/恢复 |
| `powergrid.watchdog.window` | `300` | 秒，`> 0` 且 `<= 604800` | 持续低多久才告警 |
| `powergrid.watchdog.poll` | `10` | 秒，`>= 0.1` 且 `<= 86400` | 采样间隔 |
| `powergrid.watchdog.input_side` | `back` | `top/bottom/left/right/front/back` | 读 `getAnalogInput` 的面 |
| `powergrid.watchdog.alarm_side` | `left` | 同上 | 告警继电器输出面 |

`low >= high` 属于非法组合：两个值都会回落到默认（2/10），并记一条 `WATCHDOG_CONFIG_BAD`。

### 日志关键字

沿用 `logger.lua` 的格式 `[tag] YYYY.MM.DD HH:MM message`，所以按**关键字** grep，而不是按 tag：

| 关键字 | logger 级别 | 含义 |
|---|---|---|
| `WATCHDOG_START` | info | 监视启动（含 input/alarm/low/high/window/poll） |
| `WATCHDOG_ALARM` | error | 告警拉高（含 side/level/low/high/window/sustained） |
| `WATCHDOG_CLEAR` | info | 恢复到 `high`，告警复位 |
| `WATCHDOG_DISABLED` | warn | `enabled=false`，不采样不驱动 |
| `WATCHDOG_CONFIG_BAD` | warn | 一条非法的 settings 值（该值回落默认） |
| `WATCHDOG_READ_FAIL` | warn | 读不到传感器（第一次，之后每 60 次一条） |
| `WATCHDOG_RELAY_FAIL` | warn | 告警面写不出去（无 redstone API 等） |
| `WATCHDOG_STATUS` | info | 按需输出的单行状态（`M.report`） |
| `WATCHDOG_CRASH` | error | 主循环异常退出（只记录，不重启循环） |

### 接线建议

- **输入**：把电网健康度（电压/电量比例）用比较器或能量感应器变成 0–15 的模拟红石，
  接到 `input_side`（默认背面）。空载/断网时读数自然掉到 0，正好落在"低"。
- **告警**：`alarm_side`（默认左面）接红石灯、警报器、或红石无线发送器；告警时输出 `true`，
  恢复或启动时输出 `false`。**不要把告警面接到控制器背面的电源输出上**——那个面是电源模式，
  由 `applyPower` 独占。
- **独立电脑**：一台 CC 电脑同时只能跑一个程序，控制器的菜单会阻塞在 `io.read()`，
  所以推荐用**另一台监看电脑**跑 `watchdog_app`：它只读传感器、只点灯，与控制器互不干扰。
  真要合到同一台电脑，需要自己把轮询塞进控制器主循环——本项目刻意不做这件事。

### 运行与部署

监看电脑根目录放 `watchdog.lua`、`watchdog_app.lua`、`logger.lua`，然后：

```
watchdog_app
```

即可按 `poll` 秒循环监视；想开机自启就把 `watchdog_app.lua` 复制成 `startup.lua`。
`watchdog_app.lua` 只有在"它自己就是正在运行的程序"时才自动进入循环，
被别的程序 `dofile`/`require` 时只返回模块表。

### 测试

```
pwsh -NoProfile -File powergrid/tests/run-tests.ps1
```

- staging 目录 `powergrid/.tests`，PASS 后自动删除；`-KeepStaging` 保留（可读 `logs/suite.log`），
  `-DataDir` 可换位置，`-TimeoutSec` 可调超时。
- 套件把假的红石 API、假 logger、假 settings 与虚拟时钟注入 `watchdog_app`，
  并断言：告警只报一次、恢复必须到 `high`、缓冲带不动作、非法/禁用配置的行为、
  `status()` 文本、**只有 `alarm_side` 被写过**、以及源码里没有 `applyPower` /
  `PowerGrid.ini` / `setAnalogOutput`；跑完还检查 staged 的 `PowerGrid.ini` 字节不变、
  没有生成 `.settings`。
- 当前基线：`OFFLINE_PASS 314` / `OFFLINE_FAIL 0` / `OFFLINE_GROUPS 18`。

## 部署

**控制器**：把 `startup.lua`、`logger.lua`、`bsod.lua` 与 `PowerGrid.ini`（内容为 `0`–`3`）
放到计算机根目录，重启即自动运行。`Main.log` 会在首次运行后自动生成，无需预置。

**监看电脑**（可选）：放 `watchdog.lua`、`watchdog_app.lua`、`logger.lua`，按上面「Watchdog」一节运行。

## 归档说明

- 入库范围：`startup.lua`、`logger.lua`、`bsod.lua`、`watchdog.lua`、`watchdog_app.lua`、
  `PowerGrid.ini`、`tests/` 与本说明。
- 新增/修改的 `.lua`/`.ps1` 保持纯 ASCII（`tests/run-tests.ps1` 会检查）；`bsod.lua`
  的注释与本文档是既有中文内容，不受该规则约束。
