#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跑性能基线：在真 CraftOS-PC 里量各作业"单任务"的耗时，生成 markdown 表格。

    python tools/bench.py              # 打印表格
    python tools/bench.py --write      # 把表格写进 docs/PERF.md 的标记区间

    CraftOS-PC 跑在 PC 上，比游戏内电脑快几十倍；docs/PERF.md 里说明了换算与
    游戏内自测方法，报告表格时务必保留这个前提。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = r"C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
PERF = os.path.join(ROOT, "docs", "PERF.md")

BEGIN = "<!-- BENCH:BEGIN -->"
END = "<!-- BENCH:END -->"
LINE = re.compile(r"^BENCH\s+(\S+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s*$")
INFO = re.compile(r"^BENCHINFO\s+(\S+)\s+(\S+)\s+单位=(\d+)\s+重复=(\d+)\s+任务数=(\d+)\s*$")


def run_bench(timeout=600):
    data = os.path.join(ROOT, "tests", ".bench")
    shutil.rmtree(data, ignore_errors=True)
    cmd = [EXE, "--headless", "--directory", data, "--id", "9",
           "--mount-rw", "/project=" + ROOT,
           "--script", os.path.join(ROOT, "tests", "bench.lua")]
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, timeout=timeout)
    out = proc.stdout.decode("utf-8", "replace")
    shutil.rmtree(data, ignore_errors=True)
    return out, time.time() - t0


def parse(out):
    """解析 BENCH / BENCHINFO 行。CraftOS 的控制台会重绘屏幕、行尾还带填充空格，
    所以按 (作业, 规模) 去重并保留最后一次。"""
    rows, seen = [], {}
    info = {}
    for line in out.splitlines():
        s = line.strip()
        m = INFO.match(s)
        if m:
            info[(m.group(1), m.group(2))] = {"units": int(m.group(3)),
                                              "reps": int(m.group(4)),
                                              "tasks": int(m.group(5))}
            continue
        m = LINE.match(s)
        if not m:
            continue
        key = (m.group(1), m.group(2))
        row = {"job": m.group(1), "size": m.group(2),
               "ms": float(m.group(3)), "rate": float(m.group(4))}
        if key in seen:
            rows[seen[key]] = row
        else:
            seen[key] = len(rows)
            rows.append(row)
    for r in rows:
        r.update(info.get((r["job"], r["size"]), {}))
    return rows


def table(rows):
    lines = ["| 作业 | 规模 | 单任务耗时（CraftOS-PC） | 吞吐 | 每任务单位数 | 任务数 | 重复 |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        lines.append("| `%s` | %s | %.1f ms | %s /s | %s | %s | %s |"
                     % (r["job"], r["size"], r["ms"], "{:,.0f}".format(r["rate"]),
                        r.get("units", "-"), r.get("tasks", "-"), r.get("reps", "-")))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", help="写进 docs/PERF.md 的标记区间")
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()

    if not os.path.exists(EXE):
        print("找不到 CraftOS-PC: " + EXE)
        return 1

    out, dur = run_bench(args.timeout)
    rows = parse(out)
    fails = [l.strip() for l in out.splitlines() if l.strip().startswith("BENCHFAIL")]
    if not rows:
        print("没有解析到基准数据，原始输出尾部：")
        print("\n".join(out.splitlines()[-15:]))
        return 1

    md = table(rows)
    print("测量完成（总耗时 %.1fs，%d 组）\n" % (dur, len(rows)))
    print(md)
    if fails:
        print("\n未能测量的用例（%d 个）：" % len(fails))
        for f in dict.fromkeys(fails):
            print("  " + f)

    if args.write:
        with open(PERF, "r", encoding="utf-8") as f:
            text = f.read()
        if BEGIN in text and END in text:
            head, rest = text.split(BEGIN, 1)
            _, tail = rest.split(END, 1)
            text = head + BEGIN + "\n\n" + md + "\n\n" + END + tail
            with open(PERF, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            print("\n已写入 " + os.path.relpath(PERF, ROOT))
        else:
            print("\n%s 里没有 %s / %s 标记，未写入" % (PERF, BEGIN, END))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
