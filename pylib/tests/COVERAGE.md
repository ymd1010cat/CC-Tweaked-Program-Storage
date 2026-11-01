# pylib 子集解释器覆盖表（实测，2026-11-01）

被测对象：`pkg/pylib/pythonlib.lua`（解释器本体，`require`/`dofile` 后返回 `py` 表）
＋ `pkg/pylib/*.py`（15 个导出模块）。
测试入口：`pylib/tests/run-tests.ps1`（staging 到 `pylib/.tests`，CraftOS-PC headless 跑
`tests/startup.lua`，判据取 `logs/suite.log`）。

    pwsh -NoProfile -File pylib\tests\run-tests.ps1

当前基线：**PYLIB_PASS 188 / PYLIB_FAIL 0 / PYLIB_GROUPS 27**（27 个 group，见下表）。
PASS 时 staging 自动删除；`-KeepStaging` 保留以便看 `logs/suite.log`。

测试分四个文件：
`t_core.lua`（核心语言特性）、`t_slices.lua`（切片）、`t_modules.lua`（15 个 .py 的
import 覆盖）、`t_legacy.lua`（旧版 `pkg/py.lua` 的状态）、`t_perf.lua`（性能证据 +
将来优化必须保持的语义网）。

## 1. 15 个 .py 模块的 import 覆盖（逐模块）

判定分两段，两段都归因到模块自己：

- `parse_error`：子集解析器连模块自身源码都解析不了（消息带 `Parse error at line N`）。
- `runtime_error`：能解析，但执行模块体失败（消息带模块名；解释器不跟踪行号，故运行期
  错误没有行号）。
- `ok`：解析 + 执行模块体都通过，且模块表至少暴露一个名字。

| # | 模块 | 状态 | 原因（一句话） |
|---|------|------|----------------|
| 1 | argparse.py | runtime_error | `class ArgumentError(Exception)`（第 80 行）：内置异常名是构造**函数**不是类，`execClass` 报 `base class not found or not a class: Exception` |
| 2 | cc.py | ok | 需要 `lua()` / `lua_call()` 内置函数；修复 `luaToPy` 前向引用后可用（暴露 110 个名字） |
| 3 | cc_utf8.py | ok | — |
| 4 | collections.py | ok | 依赖切片（第 48 行 `items[0:n]`），切片修好后即可用 |
| 5 | copy.py | runtime_error | `class Error(Exception)`（第 38 行）：同上，内置异常不可作为基类 |
| 6 | dataclasses.py | ok | — |
| 7 | datetime.py | ok | `import time as _time` 命中内置 `time` 模块 |
| 8 | enum.py | ok | — |
| 9 | functools.py | ok | — |
| 10 | itertools.py | ok | — |
| 11 | json.py | ok | 依赖切片（第 175 行 `s[start:state[0]]`），切片修好后即可用 |
| 12 | pathlib.py | runtime_error | `import os.path as _osp`（第 3 行）：内置模块表只有 `math/random/time/os`，`/pylib/os/path.py` 不存在 → `ImportError: No module named 'os.path'` |
| 13 | string.py | ok | 依赖切片（第 18/26 行 `w[1:]`），切片修好后即可用 |
| 14 | sys.py | ok | — |
| 15 | typing.py | ok | — |

合计：**12 ok / 0 parse_error / 3 runtime_error**。
（切片修复前是 10 ok / 5 parse_error / 0 runtime_error：argparse、collections、json、
pathlib、string 全部卡在解析阶段。）

`t_modules.lua` 把上表写成断言（`EXPECTED` 表），任一模块状态变化都会让套件失败，
所以本文件不会悄悄过期。

## 2. 语法 / 语义点覆盖

| 语法点 | 现状 | 证据 |
|--------|------|------|
| 算术 `+ - * / // % **`、位运算 `& \| << >>` | 支持 | `core:arith`（13 条） |
| 比较、`in`、`and`/`or` 返回值、三元表达式 | 支持 | `core:arith`、`core:control-flow` |
| 字符串（拼接、`len`、下标、`upper`/`split`/`replace`、f-string） | 支持 | `core:strings`（8 条） |
| 列表 / 字典 / 元组 / 推导式 | 支持 | `core:containers`（10 条） |
| 负下标 `l[-1]` | 支持（post-export fix） | `core:containers`；修复前抛 `IndexError` |
| `while` / `if` / `for` / `break` / `continue` | 支持 | `core:control-flow`（8 条） |
| 闭包 / `nonlocal` / `global` / 默认参数 / `*args` / 多返回值 / 递归 / `lambda` | 支持 | `core:functions`（7 条）、`perf:name-resolution-net`（9 条） |
| 类 / `__init__` / 方法 / 继承 / 实例属性 | 支持 | `core:classes`（5 条） |
| `try`/`except`/`as`/`finally`/`raise`/`assert` | 支持（内置异常类型） | `core:exceptions`（5 条） |
| `print(None)` / `f(1, None, 3)` 里的 `None` 位置参数 | 支持（post-export fix） | `core:print`、`core:nil-arguments` |
| **切片** `seq[a:b:c]`（省略上下界、负界、负步长） | 支持（post-export fix） | `slice:*` 共 27 条 |
| 切片赋值 `l[0:1] = [...]` | **不支持**，抛 `TypeError: slice assignment is not supported` | `slice:unsupported-cases-are-explicit` |
| 对 dict 切片 | **不支持**，抛 `TypeError: object is not sliceable` | 同上 |
| 切片步长 0 | 抛 `ValueError: slice step cannot be zero` | 同上 |
| `class X(Exception)` 之类以内置异常为基类 | **不支持**（见 §1 argparse/copy） | `core:exception-subclass-gap` |
| `type(x)` | 返回**类名字符串**（`"int"`/`"tuple"`），不是类对象 | `core:classes`、`slice:tuple`；与 Python 的差异已记录 |
| `None` 落在 `*args` 里 | **不支持**：打包时被丢掉（Lua 表的洞会让 `#` 行为未定义） | `core:nil-arguments` 里的 `LIMITATION` 行（不断言数值，避免依赖 Lua 的 `#` 边界规则） |
| `l[99] = x`（越界赋值） | 不检查范围（沿用原有 Lua 表语义），仅负下标被归一化 | 未断言，记录在此 |

## 3. 旧版留档文件 `pkg/py.lua`

`pkg/py.lua` 与历史文件 `legacy-py.lua` 逐字节相同（SHA256
`25c0f196ecc63e057bcbb510bd47ba379915c34e17cf814e8038345670c8b7dc`），是
`pythonlib.lua` 之前的版本，仅留档。实测：它能被 `dofile` 加载并返回 `py` 表，但
`py.runString('x = 1 + 1\nprint(x)')` 必然失败：

    Parse error at line 1: Expected NEWLINE, got NAME

即 README 描述的"`parseBlock` 在期望 INDENT 前不跳换行"。`t_legacy.lua` 对这条消息做
断言，并对照断言同一段源码在 `pythonlib.lua` 上能跑通。

## 4. 复现

    # 完整套件（实测约 2 秒，含 CraftOS 启动）
    pwsh -NoProfile -File pylib\tests\run-tests.ps1

    # 保留 staging 看日志
    pwsh -NoProfile -File pylib\tests\run-tests.ps1 -KeepStaging
    Get-Content pylib\.tests\computer\20\logs\suite.log

失败时会打印 `TEST_FAIL <group> :: <断言名> :: <详情>`，并保留 staging。
