# python 解释器导出件（来自 Marvis「lua开发」会话）

用途：这是一个**独立导出**，**不参与 Pyromputer OS 项目**；之后再打成包管理服务器的包。
导出对象是原 CC:Tweaked 会话里手写的 Python 子集解释器及其配套模块。

## 内容

    pkg/                        按会话最终文件树还原的包内容
        pylib/pythonlib.lua     解释器本体（Lua 手写，4222 行，130760 -> 152406 字节，见 MANIFEST.md 的 post-export fix）
        pylib/*.py              解释器 import 的 Python 模块（15 个，未改动）
        pyrepl.lua              REPL 前端（会话里写好但尚未集成进 psh）
        py.lua                  被 pythonlib.lua 取代的早期解释器（仅留档）
        manifest                本项目包管理器格式的清单（name/version/bin/file）
    tests/                      离线回归套件（本轮新增）
        run-tests.ps1           入口：staging -> CraftOS-PC headless -> PASS/FAIL
        startup.lua, run.lua    引导与驱动（自动发现 t_*.lua）
        harness.lua             断言/日志工具（每行同时写 logs/suite.log）
        t_core.lua              核心语言特性（算术/字符串/容器/控制流/函数/类/异常/异常类/print/None）
        t_slices.lua            切片下标（含"不支持必须报错"的 4 条）
        t_modules.lua           15 个 .py 的 import 覆盖（ok/parse_error/runtime_error）+ 三个旧失败模块的功能验证
        t_os_path.lua           内置 os.path、os 写操作（makedirs/mkdir/remove/rmdir/rename）、dotted import
        t_dict_none.lua         dict 里的 None 键/值（含 json 与 **kwargs 路径）
        t_legacy.lua            pkg/py.lua（旧版）的状态
        t_perf.lua              性能实测 + 将来优化必须保持的语义网
        COVERAGE.md             覆盖表（逐模块状态 + 语法点现状 + 已知缺口）
    DECISIONS.md                决策记录（修了什么/为什么没修/性能项为什么押后）
    MANIFEST.md                 还原说明：每个文件的字节数、行数、块位置、修订数
    SHA256SUMS                  每个导出文件的 SHA256（路径相对 pkg/）

## 来源与还原方法

- 源：Marvis 会话 `lua开发`（`conv_c761312b431a4aa8935c6961ce2b1767`，11760 条消息）
  保存的 DeepSeek 分享原文
  `%APPDATA%\Tencent\Marvis\User\BEE8C8819ED0EAC0E38D844A06450AE8\workspace\
   conv_c761312b431a4aa8935c6961ce2b1767\output\
   deepseek-share-t7l9c9g3h0h72ijjy2-dialogue-original.md`（2,579,284 字节，89,895 行）
- 还原脚本：`..\_extract_pythonlib.py`（只读源文件，只写导出目录）。
  归属规则：代码块只有在**自身带文件头**（`-- pythonlib.lua - ...`、`# json.py`）或
  **文件名就在块前 3000 字符内**时才算该文件；否则会把 tar 用法块错挂到别的文件上。
  同一文件有多个版本时，优先选"自带文件头且以 `return <module>` 结尾"的整文件块，
  再按体积取最大——单看"最后一块"会选到会话里引用的补丁片段。

## 测试入口（本轮实测，2026-11-01）

`pwsh -NoProfile -File pylib\tests\run-tests.ps1`：把 `pkg/pylib/pythonlib.lua`、15 个 `.py`
（放到 `/pylib/`）、`pkg/py.lua`（放到 `/legacy-py.lua`）和 `tests/` staging 到
`pylib/.tests/computer/20`，用 CraftOS-PC console headless 跑 `tests/startup.lua`，判据取自
`/logs/suite.log`（CraftOS 对重定向 stdout 做块缓冲，只看 stdout 会误判）。
PASS 自动删 staging；失败保留；`-KeepStaging` 成功后也保留。

当前基线：**PYLIB_PASS 290 / PYLIB_FAIL 0 / PYLIB_GROUPS 43**（实测整跑约 2 秒，含 CraftOS 启动）。

## 已验证

- 本轮环境限制：本机没有 `lua`/`lua5.1`/`lua54`/`luajit` 可执行文件，所以"在
  lua51/52/53/54/luajit21 下都能编译"这条**无法在本轮复验**（那是导出时的会话记录）；
  本轮的实际验证环境是 CraftOS-PC 的 Lua 5.2，套件在它上面完整跑通。
- 15 个 `.py` 都能被子集解析器解析（0 个 `parse_error`），并且**全部能 import 并执行
  模块体**（15 ok / 0 runtime_error）。此前卡住的三个模块已由异常类与 `os.path` 补齐：
  argparse、copy 的 `class X(Exception)`，pathlib 的 `import os.path`。逐条原因见
  `tests/COVERAGE.md` §1。
- 异常类模型：`class MyError(Exception): pass` 可用作基类，`raise MyError("x")` 抛出的
  仍是原来的 `{__pyexception, type, value}` 表，`except MyError` / `except Exception`
  （父类捕获子类）/ 裸 `except` / `except ... as e` / `isinstance(e, X)` / `raise MyError`
  （类本身）都可用；`str(e)`/`repr(e)` 文案与上一轮完全一致（`ValueError: boom`）。
  `os.path` 是内置模块，最小面上只有 join/basename/dirname/splitext/exists/isfile/isdir。
- **dict 里的 `None`**（第二轮）：`None` 可以作为 dict 的键或值存取，`len`/`in`/`repr`/
  `get`/`pop`/`json.dumps` 都按 CPython 语义工作；`get`/`pop` 能区分"存的是 None"和
  "键不存在"（后者仍是 `KeyError`）。`**kwargs` 里的 `f(a=None)` 也不再丢键。
- **`os` 写操作**（第二轮）：`os.makedirs(path[, exist_ok])`（递归 + CPython 的 exist_ok
  语义）、`os.mkdir`、`os.remove`、`os.rmdir`、`os.rename`，错误用
  `FileExistsError`/`FileNotFoundError`/`OSError`（后两者是 `OSError` 的子类）。
  `pathlib` 的 `mkdir(parents=True)`/`write_text`/`read_text`/`unlink`/`rename` 因此可跑。
- **argparse 最小路径**（第二轮）：`ArgumentParser()` + `add_argument`（含 `type=int`）+
  `parse_args([...])` 不再 `KeyError: action`，`ns.count + 1` 得到 6（证明真的转成了 int）。
- 解释器核心语言特性在 CraftOS 里实测可用：算术与 print、字符串/列表/字典/元组、
  推导式、闭包与 `nonlocal`/`global`、默认参数、类与 `__init__`、继承、
  `try/except/finally`、`while`/`if`/`for`/`break`/`continue`、f-string。
- 切片下标 `seq[a:b:c]`（省略界、负界、负步长、表达式边界）已实现并验证；
  负下标 `l[-1]`、`print(None)`、位置参数里的 `None` 一并修好（`DECISIONS.md` §2）。
- 旧版 `pkg/py.lua` 能加载但跑不了任何程序，报
  `Parse error at line 1: Expected NEWLINE, got NAME`——与本文档原描述一致，已断言。

## 已知限制（交付时请留意）

- **异常子类的自定义 `__init__` 不执行**：`class E(Exception): pass` 是推荐写法；
  如果写了 `def __init__(self, code, msg)`，`E(1, "x")` 只把第一个参数当作异常值
  （`str(e)` 里显示的就是它）。异常值也不支持属性访问（`e.value`/`e.args` 报
  `object has no attribute`），要拿类型和消息用 `str(e)`。见 `tests/COVERAGE.md` §2。
- **切片赋值不支持**（`l[0:1] = [...]` 抛 `TypeError: slice assignment is not supported`）；
  **dict 切片不支持**（`TypeError: object is not sliceable`）；对带 `__getitem__` 的实例
  也不传 `slice` 对象（子集没有 `slice` 类型）。
- **`None` 落在 `*args` 里、或存进 list 里都会被丢掉**：Lua 表存不了 nil（保留洞会让
  `#`/`len()`/下标都不可用）。dict 里的 None 已支持，但把含 None 的 dict 展开成 list
  （`values()`/`items()`/`copy.deepcopy`）会丢掉那一项，`[None]` 也无法表示。
- **`os.path` 只有最小面**：join/basename/dirname/splitext/exists/isfile/isdir 七个函数，
  没有 abspath/normpath 等；`os` 写操作也只有 makedirs/mkdir/remove/rmdir/rename 五个
  （没有 stat/chmod/walk/listdir 之外的扩展）。CraftOS 路径固定 `/` 分隔，不做 Windows 语义。
- **`os.makedirs`/`mkdir` 的报错信息是简化版**：异常**类型**对齐 CPython
  （FileExistsError/FileNotFoundError/OSError），但消息文本不是 CPython 的
  `[Errno N] ...` 格式；`os.rename` 不能可靠地覆盖已存在的目标（CraftOS fs.move 的边界）。
- **`type(x)` 返回类名字符串**（`"int"`、`"tuple"`），不是类对象；`l[99] = x` 不检查范围。
  都列在 `tests/COVERAGE.md` §2。
- **性能槽位化未做（押后）**，附实测依据：宿主 VM 上字符串键哈希访问并不比数组槽慢
  （边际 4.5ns 量级，数组槽 4.5-5.0ns，差异在噪声内），解释器每迭代 2450ns 里名字查找只占十几纳秒，槽位化收益
  上限约 1–3%，而重写面覆盖全部名字解析路径。更划算的顺序是先补 AST 缓存（本导出件里
  **没有** AST 缓存或常量折叠代码，旧说法"AST 缓存与常量折叠已做"在这个导出件上不成立）、
  再降每次调用的 scope 拷贝与 `pcall` 开销（`DECISIONS.md` §4）。
- REPL `pyrepl.lua` 仍未集成进 psh（与导出时记录一致，本轮未动）。
