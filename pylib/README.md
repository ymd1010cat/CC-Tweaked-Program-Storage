# python 解释器导出件（来自 Marvis「lua开发」会话）

用途：这是一个**独立导出**，**不参与 Pyromputer OS 项目**；之后再打成包管理服务器的包。
导出对象是原 CC:Tweaked 会话里手写的 Python 子集解释器及其配套模块。

## 内容

    pkg/                        按会话最终文件树还原的包内容
        pylib/pythonlib.lua     解释器本体（Lua 手写，3647 行）
        pylib/*.py              解释器 import 的 Python 模块（15 个）
        pyrepl.lua              REPL 前端（会话里写好但尚未集成进 psh）
        legacy-py.lua           被 pythonlib.lua 取代的早期解释器（仅留档）
        manifest                本项目包管理器格式的清单（name/version/bin/file）
    MANIFEST.md                 还原说明：每个文件的字节数、行数、块位置、修订数
    SHA256SUMS                  每个导出文件的 SHA256

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

## 已验证

- 3 个 Lua 文件在 lua51/52/53/54/luajit21 下都能编译。
- 15 个 `.py` 都能被 Python 3 的 `ast.parse` 解析（语法完整、未被截断）。
- 解释器在 CraftOS 桩环境（`fs`/`term`/`print`）里能加载并跑通核心语言特性：
  算术与 print、字符串/列表、函数闭包、类与 `__init__`、`try/except`、`while`/`if`。

## 已知限制（交付时请留意）

- 14 项"未完成"里的 Python 相关项：会话末尾明确列着 **REPL 尚未集成进 psh**、
  **性能槽位化未做**（AST 缓存与常量折叠已做）。
- 用子集解释器 `import` 导出的 pylib 模块时，个别模块会触发子集解析器的语法限制
  （例如 `json.py` 第 175 行的下标里出现 `:`），说明这些 `.py` 用的是比解释器当前
  解析器更新的语法，或解释器仍有未覆盖的语法点。模块本身是**合法 Python 3**
  （`ast.parse` 通过），但这不等于子集解释器能跑它们——**上机后再确认一次**。
- 早期解释器 `legacy-py.lua` 正是"`Parser:parseBlock` 在期望 INDENT 前不跳过换行"
  的那一版，会报 `Parse error at line 1: Expected NEWLINE, got NAME`；保留只为留档。
