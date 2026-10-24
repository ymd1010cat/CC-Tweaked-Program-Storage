# Power Grid Controller v2.1（`powergrid/`）

一台 CC:Tweaked 控制终端上的**电站切换器**：负责在「主电网 / 备用电池 / 外部电网 / 关闭」
之间切换供电来源，并把状态写回配置、
同时输出红石信号。附带一个 Windows 10 风格的蓝屏模块和一张终端日志打印功能。

## 文件

| 文件 | 说明 |
|---|---|
| `startup.lua` | 主程序。开机读取配置、恢复供电模式、进入命令循环（菜单 1–4 切换、5 打印日志、`version` 显示版本）。 |
| `logger.lua` | 极简日志库：`logger.info/warn/error/debug`，每条按 `[tag] %Y.%m.%d %H:%M message` 追加到 `Main.log`。 |
| `bsod.lua` | 蓝屏模块：用 `window` API 铺满全屏、居中显示 `:(` / 错误码 / 失败文件，然后把父终端光标移出屏幕并 `error()` 退出。 |
| `PowerGrid.ini` | 配置兼状态文件，只有一行数字 `0`–`3`，每次切换都会重写。 |
| `.settings` | 该计算机的 CraftOS-PC 设置（目前只关了 `motd.enable`）；仅随归档副本保留，由本目录 `.gitignore` 排除，不入库。 |
| `Main.log` | 运行日志（部署期间的真实记录，仓库根 `.gitignore` 忽略 `*.log`，故不入库）。 |
| `.gitignore` | 目录级忽略规则：只为排除 `/.settings` 这个本机运行时副本。 |

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

## 部署

把 `startup.lua`、`logger.lua`、`bsod.lua` 与 `PowerGrid.ini`（内容为 `0`–`3`）放到计算机根目录，
重启即自动运行。`Main.log` 会在首次运行后自动生成，无需预置。

## 归档说明

- 入库范围：`startup.lua`、`logger.lua`、`bsod.lua`、`PowerGrid.ini` 与本说明。
