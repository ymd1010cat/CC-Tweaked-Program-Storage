#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""量一量产物的体积构成：代码 / 注释 / 字符串 / 中文各占多少。

    python tools/size_report.py

用来回答"注释和中文到底吃掉多少空间"这类问题——注释在 dist 产物里是纯浪费，
这个脚本给出确切数字（顺带给打包器做回归：剥注释后应该显著变小）。
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")


def scan(src):
    """单遍扫描 Lua 源码，统计各类字节数（识别长注释/长字符串/转义）。"""
    i, n = 0, len(src)
    counts = {"code": 0, "comment": 0, "string": 0}
    cjk = {"code": 0, "comment": 0, "string": 0}
    state = None          # None | "comment" | "string"

    def bump(chunk, kind):
        counts[kind] += len(chunk.encode("utf-8"))
        cjk[kind] += sum(1 for c in chunk if ord(c) > 0x2E7F)

    while i < n:
        c = src[i]

        if state is None:
            # 长注释 / 长字符串
            if c == "-" and src.startswith("--", i):
                j = i + 2
                level = 0
                if src.startswith("[", j):
                    k = j + 1
                    while k < n and src[k] == "=":
                        level += 1
                        k += 1
                    if k < n and src[k] == "[":
                        close = "]" + "=" * level + "]"
                        end = src.find(close, k + 1)
                        end = n if end < 0 else end + len(close)
                        bump(src[i:end], "comment")
                        i = end
                        continue
                # 行注释
                end = src.find("\n", i)
                end = n if end < 0 else end
                bump(src[i:end], "comment")
                i = end
                continue
            if c == "[":
                k = i + 1
                level = 0
                while k < n and src[k] == "=":
                    level += 1
                    k += 1
                if k < n and src[k] == "[":
                    close = "]" + "=" * level + "]"
                    end = src.find(close, k + 1)
                    end = n if end < 0 else end + len(close)
                    bump(src[i:end], "string")
                    i = end
                    continue
            if c in "\"'":
                j = i + 1
                while j < n:
                    if src[j] == "\\":
                        j += 2
                        continue
                    if src[j] == c or src[j] == "\n":
                        j += 1
                        break
                    j += 1
                bump(src[i:j], "string")
                i = j
                continue
            bump(c, "code")
            i += 1
        else:                              # pragma: no cover - 上面的分支已内联处理
            i += 1

    return counts, cjk


def main():
    if not os.path.isdir(DIST):
        print("还没有 dist/，先运行 tools/build.py")
        return 2

    grand = {"code": 0, "comment": 0, "string": 0}
    grand_cjk = {"code": 0, "comment": 0, "string": 0}
    rows = []
    for name in sorted(os.listdir(DIST)):
        if not name.endswith(".lua"):
            continue
        path = os.path.join(DIST, name)
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
        counts, cjk = scan(src)
        for k in grand:
            grand[k] += counts[k]
            grand_cjk[k] += cjk[k]
        rows.append((name, len(src.encode("utf-8")), counts, cjk))

    print("%-16s %9s %9s %9s %9s   %s" % ("文件", "总字节", "注释", "字符串", "其它代码", "中文占字节（注/串/码）"))
    for name, total, counts, cjk in rows:
        print("%-16s %9d %9d %9d %9d   %d / %d / %d" % (
            name, total, counts["comment"], counts["string"], counts["code"],
            cjk["comment"], cjk["string"], cjk["code"]))
    total = sum(r[1] for r in rows)
    print("-" * 78)
    print("%-16s %9d %9d %9d %9d   %d / %d / %d" % (
        "合计", total, grand["comment"], grand["string"], grand["code"],
        grand_cjk["comment"], grand_cjk["string"], grand_cjk["code"]))
    if total:
        print("\n注释占 %.1f%%（%d 字节），字符串占 %.1f%%，其中中文（字符串里）%d 字节 ≈ %.1f%%" % (
            grand["comment"] * 100.0 / total, grand["comment"],
            grand["string"] * 100.0 / total,
            grand_cjk["string"], grand_cjk["string"] * 100.0 / total))
    print("CC 电脑默认磁盘上限 1,000,000 字节（1MB），可作为对照。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
