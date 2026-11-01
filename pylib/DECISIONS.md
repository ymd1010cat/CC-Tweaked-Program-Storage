# pylib 决策记录（导出后补充，2026-11-01）

本文件记录对导出件做的判断：为什么修、为什么没修、性能项为什么不现在做。
所有数字都是本机实测（CraftOS-PC headless，`pylib/tests/run-tests.ps1`）。

## 0. 结论摘要

| 项 | 决定 | 理由（详见各节） |
|----|------|------------------|
| 切片下标 `seq[a:b:c]` | **已实现** | 是唯一挡住 5 个导出模块的解析缺口，语义范围小、可完整验证 |
| `luaToPy` / `pyToLua` 前向引用 | **已修** | `cc.py` 必需的内置 `lua()` 因它必然崩，属明确 bug |
| `print(None)` 打印空行 | **已修** | `print(f())`（f 无返回值）会静默丢一个参数 |
| 调用参数里的 `None` 被丢弃 | **已修** | `f(1, None, 3)` 会把 3 当成第二个参数 |
| 负下标 `l[-1]` | **已修** | 与切片不一致（切片已归一化负界），改 3 处、可完整验证 |
| `class X(Exception)` | **未修** | 要改内置异常的数据模型 + `raise`/`except` 三处语义，超出"低风险缺口"范围 |
| `pathlib.py` 的 `os.path` | **未修** | 缺模块，不是语法缺口；补 `os.path` 等于新增内置模块语义 |
| 性能槽位化 | **押后** | 实测宿主 VM 上哈希访问不比数组槽快，收益上限约 1–3%（见 §4），重写面却覆盖全部名字解析路径 |

## 1. 切片下标（已实现）

**问题**：`Parser:parsePostfix` 的 `[` 分支只解析一个表达式再 `expect("]")`，遇到 `:`
直接抛 `Parse error at line N: Expected ']', got ':'`。导出模块里有 6 处切片
（argparse.py:38、collections.py:48、json.py:175、pathlib.py:33、string.py:18/26），
5 个模块因此连解析都过不去。

**做法**：

1. 解析：`[` 后先看是否紧跟 `:`，按 Python 语法取 `lower`/`upper`/`step`（三者都可空），
   生成 `{type="Index", obj=..., slice={lower, upper, step}}`；非切片仍是原来的
   `{type="Index", index=...}`，AST 形状向后兼容。
2. 运行：新增 `pySliceApply(obj, lo, hi, stepRaw)`，按 CPython 的边界规则归一化
   （负界加 `len`、正步长夹到 `[0,len]`、负步长夹到 `[-1,len-1]`、步长 0 抛
   `ValueError: slice step cannot be zero`）。支持 `str` / `list` / `tuple`：
   字符串返回子串，列表/元组返回**新**表（带原 `__pytype`），故切片是拷贝而非视图。
3. 赋值目标：`l[0:1] = [...]` 显式抛 `TypeError: slice assignment is not supported`，
   不让它落到 `assignTarget` 的数值分支里写出脏数据。

**有意不支持**：`dict` 切片、带 `__getitem__` 的实例切片（子集没有 `slice` 对象可传）。
两者都抛明确错误，不做"看起来能跑"的近似。

**验证**：`tests/t_slices.lua` 27 条断言（列表/字符串/元组 × 省略界/负界/负步长/
表达式边界/链式下标/拷贝语义 + 4 条"不支持必须报错"）。切片上线后
argparse、collections、json、pathlib、string 全部通过解析阶段。

## 2. 导出后的 bug 修复（post-export fix）

这四条都是导出件里既存的 bug，不改语义、不改 `.py` 文件，全部有回归断言。

### 2.1 `luaToPy` / `pyToLua` 前向引用（致命）

`getBuiltins()` 里的内置 `lua()`/`lua_call()` 引用 `luaToPy`/`pyToLua`，但这两个
`local function` 定义在文件后面（原 2198/2224 行之后）。Lua 在编译期按文本顺序决定
局部变量归属，所以那 6 处引用实际编译成了**全局**变量，调用时报：

    RuntimeError: /pythonlib.lua:1733: attempt to call global 'luaToPy' (a nil value)

这正是 `cc.py`（源码里写明"Requires pythonlib.lua with lua()/lua_call() builtins"）
import 失败的原因。修法：在文件前部加 `local luaToPy, pyToLua` 前向声明，后面的
`local function luaToPy(v)` 改成 `luaToPy = function(v)`（`pyToLua` 同理）。
**行为变化**：无——之前这两条路径必崩。

### 2.2 `print(None)` 打印空行

`["print"]` 用 `local a = {...}` 收集参数，nil 会截断 `#a`，所以 `print(None)` 打印
空行、`def f(): pass` 后 `print(f())` 也打印空行。改为 `select("#", ...)` 取真实参数
个数，再 `select(i, ...)` 逐个别取。**行为变化**：之前输出空行，现在输出 `None`
（与 Python 一致）。

### 2.3 调用参数里的 `None` 被丢掉

`evalCall` 用 `table.insert(args, self:eval(a))` 收集位置参数，`table.insert(t, nil)`
是空操作，于是 `f(1, None, 3)` 实际只传了 `1, 3`（3 落在第二个形参上）。改为手工维护
`argCount`，并用 `unpack(args, 1, argCount)` / `makeInstance(func, args, argCount, self)`
传递，保证 nil 占位不丢。顺带把 `bindArgs` 的 kwargs 判定从 `#args` 改成 `argCount`
（否则最后一个位置参数是 None 时会漏掉 `**kwargs`）。

**已知残留**：`*args` 打包仍用 `table.insert`，所以 `None` 落在 `*args` 里会被丢掉
（保留洞会让 Lua 的 `#` 未定义，反而连 `len()`/下标都不可用）。这条写在
COVERAGE.md §2。**行为变化**：位置参数里的 None 现在按 Python 语义占位。

### 2.4 负下标

`eval` 的下标分支原来是 `local i = idx + 1`，负数一律 `IndexError`（`l[-1]` 取不到
最后一个元素），而切片早已支持负界——两者不一致。新增 `pyIndexPos(idx, len)`
（负数加 `len`），在字符串分支、列表/元组分支、`assignTarget` 的列表分支三处调用。
**行为变化**：`l[-1]` 从抛错变成返回最后一个元素；越界赋值仍不检查范围（沿用原语义，
记录在 COVERAGE.md）。

## 3. 未修的两个缺口（保持 fail-loud）

### 3.1 `class X(Exception)` → `base class not found or not a class: Exception`

内置异常名在 `getBuiltins()` 里是构造**函数**（`function(m) return makeException("Exception", m) end`），
而 `execClass` 要求基类 `__pytype == "class"`。`except` 的匹配又完全是**字符串比较**
（`handler.excType == tryException.type`），`raise` 只认 `__pyexception` 表。
所以要让 `class X(Exception)` 真正可用，需要同时改三处：把内置异常改成可调用的类表、
让 `raise <实例>` 转成 `makeException(类名, …)`、让 `except` 认识继承链。这是新增语义
（不是修缺口），一旦半做就会出现"能 import 但 raise 出来的是 RuntimeError"的更坏状态，
因此本次只把它写成断言（`core:exception-subclass-gap`）并在覆盖表里标明根因。

受影响：`argparse.py:80`、`copy.py:38`（两个模块的其余部分都正常）。

### 3.2 `pathlib.py` 的 `import os.path`

`importModule` 的内置表只有 `math/random/time/os`，且只按全名精确匹配（`os.path`
不是 `os` 的属性回退），`/pylib/os/path.py` 也不在导出里。补它等于新增内置模块语义，
留待需要时明确决定（补 `__init__.py` 或给 `importModule` 加"父模块属性回退"）。

## 4. 性能槽位化：押后（有实测依据）

**"槽位化"指什么**：把函数帧里的局部名从 `scopes[i][name]` 哈希查找改成编号数组槽
（`frame[slot]`），AST 的 `Name`/赋值目标在函数创建时绑定槽号。这是经典 AST 解释器
优化，收益前提是"数组槽访问显著快于字符串键哈希访问"。

**实测（同一台 CraftOS-PC 的 Lua 5.2 宿主，200 万次循环，取 3 次最小值）**：

    PERF host.base_read_per_2M=0.0120        # 只有 acc = acc + 1 的基线
    PERF host.hash_read_marginal_ns=4.50     # 多一次 t.name 的边际成本
    PERF host.array_read_marginal_ns=4.50~5.00  # 多一次 t[1] 的边际成本（多次运行波动）
    PERF host.hash_write_per_2M=0.0140
    PERF host.array_write_per_2M=0.0140

即：**数组槽访问并不比字符串键哈希访问快**（读取边际 4.50ns vs 4.50-5.00ns，多次运行的波动就有 ±0.5ns，两者在同一噪声带；写入相同）。
槽位化唯一能省掉的是 `Interpreter:lookup` 的那层 for 循环与 `rawget` 调用，
量级也就是每次名字访问十几纳秒。

**解释器端实测**：

    PERF interp.loop_20000_best=0.0490       # 408163 次迭代/秒 -> 2450 ns/迭代
    PERF interp.calls_5000_best=0.0300       # 166667 次调用/秒 -> 6000 ns/调用

while+s+i 那一轮每迭代约 10 次名字读写，2450ns 里宿主原语只占约 50ns，
其余是 AST 分派、每次调用新建 scope 表、`pcall` 包装。也就是说：**即使把名字访问
优化到 0，上限也只有个位数百分比**；而代价是要重写所有 `Name`/赋值目标/闭包/
`global`/`nonlocal`/推导式/类体的名字解析路径，风险与收益不成比例。

`tests/t_perf.lua` 的 `perf:name-resolution-net`（9 条）把今天的名字解析语义固定下来
（三层闭包、局部遮蔽全局、`global` 写模块作用域、`nonlocal` 写外层帧、形参不外泄、
默认参数只求值一次、赋值顺序、实例属性跨调用、递归帧隔离）——将来真要槽位化，这组
断言是验收网。

**如果将来要提速，按这个顺序更划算**（都在本文件之外，未实施）：

1. **AST 缓存**：本导出件里没有任何 AST 缓存或常量折叠代码（全文只有 `MODULE_CACHE`
   模块缓存和 `__slots__` 属性检查），`py.runString`/`py.runFile` 每次都重新
   词法+解析。旧 README 里"AST 缓存与常量折叠已做"的说法在这个导出件上不成立。
2. **每次调用新建 scope 表和 `capturedScopes` 拷贝**（`makeFunction`）：每个调用都
   `newScopes` 逐项拷贝一遍闭包作用域链，深度越大越贵，且每次都新建表。
3. `pcall` 包装：每次函数调用、每个 `try` 块都套一层 `pcall`。
4. 槽位化（最后做，且需要先有一组基准测试才知道有没有用）。

## 5. 校验和 / 文档口径修正

- `SHA256SUMS` 里旧名 `legacy-py.lua` 与实际文件名 `pkg/py.lua` 不符（文件从来没改名，
  是清单沿用了导出前的名字），导致该行无法校验；已改成 `py.lua`，哈希未变。
- 同文件补了 `pythonlib.lua` 的新哈希（post-export fix 后），其余 15 个 `.py`、`pyrepl.lua`、
  `manifest` 的哈希与导出时一致（未被改动）。
- `MANIFEST.md` 追加"post-export fixes"小节记录新字节数/行数/原因；导出段的历史数字
  保持原样（那是还原记录，且比磁盘实测少 1 字节，属导出脚本口径差，不追改）。

## 6. 复现

    pwsh -NoProfile -File pylib\tests\run-tests.ps1            # PYLIB_PASS 188 / FAIL 0
    pwsh -NoProfile -File pylib\tests\run-tests.ps1 -KeepStaging
    Get-Content pylib\.tests\computer\20\logs\suite.log        # GROUP / NOTE PERF / MODULE 全量
