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
| `startup.lua` | 主程序。开机读取配置、恢复供电模式、进入命令循环（菜单 1–4 切换、5 打印日志、`version` 显示版本）。电源写入与配置校验都委托给 `power.lua`，输出与错误码保持原样。 |
| `power.lua` | 电源模式原语（从旧 `startup.lua` 的 `applyPower`/校验逻辑抽出，行为逐字不变）：`M.read()` 读 `PowerGrid.ini` 并校验（返回旧错误码），`M.describe()` 给出旧日志行与蓝屏文案，`M.apply(value)` 写 ini + 驱动 `back` 模拟输出 + 播放 speaker 提示音。启动菜单与 watchdog 共用它。 |
| `logger.lua` | 极简日志库：`logger.info/warn/error/debug`，每条按 `[tag] %Y.%m.%d %H:%M message` 追加到 `Main.log`。 |
| `bsod.lua` | 蓝屏模块：用 `window` API 铺满全屏、居中显示 `:(` / 错误码 / 失败文件，然后把父终端光标移出屏幕并 `error()` 退出。 |
| `watchdog.lua` | watchdog 的**纯逻辑状态机**（阈值、回差、持续窗口、一次性报警、切换目标/恢复开关）。不读文件、不读时钟、不碰红石，时间与读数全部由调用方注入，所以能离线测。 |
| `watchdog_app.lua` | watchdog 的**运行驱动**：按 `poll` 秒读一次 `redstone.getAnalogInput`、驱动状态机、写日志；报警那次采样点亮告警继电器并通过 `power.lua` 切到备用，恢复那次采样切回报警前的模式。可当作独立程序运行，也可作为模块被测试注入假的时钟/红石/日志/电源模块。 |
| `tests/` | 离线测试套件：`run-tests.ps1`（CraftOS-PC headless 驱动）+ `startup.lua`（测试入口）+ `harness.lua`（断言与 `logs/suite.log`）+ `t_watchdog.lua` / `t_watchdog_app.lua` / `t_power.lua`（断言）。 |
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

启动时（以及每次在菜单里切换时）调用 `power.lua` 的 `M.apply(value)`：

- 以 `tostring(value) .. "\n"` 的形式写回 `PowerGrid.ini`；
- `redstone.setOutput("back", true)` 且 `setAnalogOutput("back", value)`（关闭时两者都置 0/false），
  即**红石输出固定在背面**，用模拟信号强度 1–3 区分三条供电路径；
- 若找到 `speaker` 外设，播放 `create:confirm` 提示音。

命令 5 需要 `printer` 外设：先查纸、再查墨，然后读 `Main.log`，按 40 字符宽自动折行、
每页最多 60 行分页打印（`newPage` / `endPage` + 手动 `setCursorPos` 换行）。

## 配置校验（启动时）

`PowerGrid.ini` 缺失、为空、非数字或超出 `0–3` 范围时，会先写日志再进入蓝屏，错误码分别为
`FILE_NOT_FOUND` / `VALUE_LENGTH_IS_ZERO` / `VALUE_TYPE_NOT_CORRECT` / `INI_VALUE_OUT_RANGE`
（`power.lua` 返回码，`startup.lua` 原样传给蓝屏，日志文案与之前逐字一致）。

## Watchdog（触发切备用、恢复切回；不是持续 ATS）

**它做什么：** 电网读数持续偏低满 `window` 秒 → 点亮告警继电器，并**切到备用电源
（`powergrid.watchdog.switch_to`，默认 `2` 备用电池）**；读数回到 `high` → 熄灭告警，
并按 `powergrid.watchdog.restore`（默认 `true`）**切报警前的那个模式**。

**它不做什么：** 不是持续 ATS 控制器——只在**报警/恢复这两个状态迁移点各动作一次**，
不会每轮轮询去校正模式。所以报警期间你手动按 1/3 改模式，它不会跟你抢着改回去；
但恢复那一刻默认仍会切回"报警前的模式"（这是 `restore=true` 的定义），
不想要这个行为就 `set powergrid.watchdog.restore false`，恢复时保持备用。

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
读不到当前模式 → `reason=read_fail code=<错误码>`；写盘失败 → `reason=write_failed code=WRITE_FAILED`
（此时不会记"已切换"，恢复时也就不会乱切）。

### 参数（CraftOS `settings`，每台电脑单独保存）

`PowerGrid.ini` 的语义保持"单值 0–3"不变，所以 watchdog 的参数放到 CraftOS 的 `settings`，
用 shell 的 `set` 命令改（`set` 程序会调用 `settings.save()`，所以重启后仍然有效；
如果自己写 `settings.set`，要记得再 `settings.save()`）；非法值一律回落到默认值并写一条
`WATCHDOG_CONFIG_BAD`（不会带着半套配置运行）。

| settings 键 | 默认 | 合法值 | 说明 |
|---|---|---|---|
| `powergrid.watchdog.enabled` | `true` | `true/false/1/0/yes/no/on/off` | 关闭后完全不采样、不告警、不切换，只写一条 `WATCHDOG_DISABLED` |
| `powergrid.watchdog.low` | `2` | 整数 0–15 | 低于它算"低" |
| `powergrid.watchdog.high` | `10` | 整数 0–15，且必须大于 `low` | 达到它算健康/恢复 |
| `powergrid.watchdog.window` | `300` | 秒，`> 0` 且 `<= 604800` | 持续低多久才告警并切备用 |
| `powergrid.watchdog.poll` | `10` | 秒，`>= 0.1` 且 `<= 86400` | 采样间隔 |
| `powergrid.watchdog.input_side` | `back` | `top/bottom/left/right/front/back` | 读 `getAnalogInput` 的面 |
| `powergrid.watchdog.alarm_side` | `left` | 同上 | 告警继电器输出面 |
| `powergrid.watchdog.switch_to` | `2` | 整数 0–3 | 报警时切到哪个模式（2=备用电池；0=关闭；3=外部电网） |
| `powergrid.watchdog.restore` | `true` | `true/false/1/0/yes/no/on/off` | 恢复时是否切回报警前的模式；`false` 则保持 `switch_to` |

`low >= high` 属于非法组合：两个值都会回落到默认（2/10），并记一条 `WATCHDOG_CONFIG_BAD`。

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
| `WATCHDOG_CONFIG_BAD` | warn | 一条非法的 settings 值（该值回落默认） |
| `WATCHDOG_READ_FAIL` | warn | 读不到传感器（第一次，之后每 60 次一条） |
| `WATCHDOG_RELAY_FAIL` | warn | 告警面写不出去（无 redstone API 等） |
| `WATCHDOG_STATUS` | info | 按需输出的单行状态（`M.report`） |
| `WATCHDOG_CRASH` | error | 主循环异常退出（只记录，不重启循环） |

### 接线建议

- **输入**：把电网健康度（电压/电量比例）用比较器或能量感应器变成 0–15 的模拟红石，
  接到 `input_side`（默认背面）。断网/空载时读数自然掉到 0，正好落在"低"。
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
与内容为 `1`（或当前模式）的 `PowerGrid.ini`，然后：

```
watchdog_app
```

即可按 `poll` 秒循环监视；想开机自启就把 `watchdog_app.lua` 复制成 `startup.lua`
（注意那时这台电脑就没有控制器菜单了）。`watchdog_app.lua` 只有在"它自己就是正在运行的程序"
时才自动进入循环，被别的程序 `dofile`/`require` 时只返回模块表。

真机自测顺序（把节奏调快）：

1. `set powergrid.watchdog.window 10`，`set powergrid.watchdog.poll 1`；
2. `watchdog_app`，确认日志出现 `WATCHDOG_START ... switch_to=2 restore=1`；
3. 把输入面的模拟信号**拉到 0**（断开比较器输入），约 10 秒后应看到
   `WATCHDOG_ALARM ...` + `WATCHDOG_SWITCH from=1 to=2 reason=low level=0`，
   `PowerGrid.ini` 变成 `2`、背面模拟输出变 2、告警面亮；
4. 把输入**拉回 10 以上**，应看到 `WATCHDOG_CLEAR ...` + `WATCHDOG_RESTORE to=1`，
   ini 回到 `1`、背面输出 1、告警灭；
5. `set powergrid.watchdog.restore false` 再跑 3/4：切到 2 后恢复时保持 2
   （日志 `WATCHDOG_RESTORE_SKIP reason=restore_disabled`）；
6. 想把"备用"改成别的目标就 `set powergrid.watchdog.switch_to 3`；
   `set powergrid.watchdog.enabled false` 则完全不告警、不动电源。

### 测试

```
pwsh -NoProfile -File powergrid/tests/run-tests.ps1
```

- staging 目录 `powergrid/.tests`，PASS 后自动删除；`-KeepStaging` 保留（可读 `logs/suite.log`），
  `-DataDir` 可换位置，`-TimeoutSec` 可调超时。
- `t_watchdog.lua`：纯状态机（注入虚拟时钟）——窗口、回差、一次性报警、恢复条件、配置校验、
  `status()` 文本、`switch_to`/`restore` 参数。
- `t_watchdog_app.lua`：用假红石/假 logger/假时钟 + **真实的 `power.lua`**（写测试专用 ini）断言：
  报警那次只切一次（ini 变 `2\n`、`back` 得到 `setOutput(true)`+`setAnalogOutput(2)`、speaker 响一声）、
  恢复切回 `1\n`、`restore=false` 保持 2、已在目标模式 noop、手动改模式不被每轮校正、
  `enabled=false` 全程不动电源/继电器、缺模块/读失败/写失败的日志与"不记已切换"。
- `t_power.lua`：`power.lua` 与旧 `startup.lua` 内联实现的**逐项等价回归**——同一组输入比较
  ini 字节、红石调用序列、speaker 调用序列；错误码/日志文案按旧字符串钉住；并断言
  `startup.lua` 已改为委托 `power.lua`（5 处 `power_api.apply(power)`）、printer/版本/菜单文本未变。
- 跑完还检查 staged 的 `PowerGrid.ini` 字节不变、没有生成 `.settings`。
- 当前基线：`OFFLINE_PASS 584` / `OFFLINE_FAIL 0` / `OFFLINE_GROUPS 27`。

## 部署

**控制器**：把 `startup.lua`、`power.lua`、`logger.lua`、`bsod.lua` 与 `PowerGrid.ini`（内容为 `0`–`3`）
放到计算机根目录，重启即自动运行。`Main.log` 会在首次运行后自动生成，无需预置。

**监看电脑**（可选）：放 `power.lua`、`watchdog.lua`、`watchdog_app.lua`、`logger.lua`
与 `PowerGrid.ini`，按上面「Watchdog」一节运行。

## 归档说明

- 入库范围：`startup.lua`、`power.lua`、`logger.lua`、`bsod.lua`、`watchdog.lua`、
  `watchdog_app.lua`、`PowerGrid.ini`、`tests/` 与本说明。
- 新增/修改的 `.lua`/`.ps1` 保持纯 ASCII（`tests/run-tests.ps1` 会检查）；`bsod.lua`
  的注释与本文档是既有中文内容，不受该规则约束。
