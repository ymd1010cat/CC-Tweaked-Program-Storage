#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""轻量一致性检查（不需要 Lua 解释器）：

  1. 所有 dc_require("dc.X") 的目标模块都存在
  2. 所有 proto.NAME 引用都在 protocol.lua 里有定义（拼错常量会静默失效）
  3. 发送过的消息类型都有对应处理分支（防止漏处理/写错名字）
  4. dist 产物包含全部模块与入口，且没有残留的未定义模块引用
  5. 作业文件都满足最基本的结构（return { name=, map= }）

    python tools/check.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
LIB = os.path.join(SRC, "lib")
JOBS = os.path.join(SRC, "jobs")
DIST = os.path.join(ROOT, "dist")

problems = []


def read(path):
    with open(path, "r", encoding="utf-8", newline="\n") as f:
        return f.read()


def lua_sources():
    out = {}
    for base, _, files in os.walk(SRC):
        for name in files:
            if name.endswith(".lua"):
                p = os.path.join(base, name)
                out[os.path.relpath(p, ROOT).replace("\\", "/")] = read(p)
    for name in ("master.lua", "worker.lua", "screen.lua", "bootstrap.lua"):
        p = os.path.join(DIST, name)
        if os.path.exists(p):
            out["dist/" + name] = read(p)
    return out


def check_requires(srcs):
    have = set()
    for path in srcs:
        m = re.match(r"src/lib/(.+)\.lua$", path)
        if m:
            have.add("dc." + m.group(1))
    for path, text in srcs.items():
        for name in set(re.findall(r'dc_require\(\s*"([^"]+)"\s*\)', text)):
            if name.startswith("dc.") and name not in have:
                problems.append("%s: dc_require(\"%s\") 找不到对应模块" % (path, name))


def check_proto(srcs):
    proto_src = srcs.get("src/lib/protocol.lua")
    if proto_src is None:
        problems.append("缺少 src/lib/protocol.lua")
        return
    defined = set(re.findall(r"^M\.([A-Z_][A-Z0-9_]*)\s*=", proto_src, re.M))
    if not defined:
        problems.append("protocol.lua 里没有解析到任何常量")
    for path, text in srcs.items():
        if path.endswith("protocol.lua"):
            continue
        for name in sorted(set(re.findall(r"proto\.([A-Z_][A-Z0-9_]*)", text))):
            if name not in defined:
                problems.append("%s: proto.%s 未在 protocol.lua 中定义" % (path, name))

    # 主控/节点各自应该处理对方发来的全部类型
    sched = srcs.get("src/lib/sched.lua", "")
    worker = srcs.get("src/lib/worker.lua", "")
    handled_by_sched = set(re.findall(r"msg\.t\s*==\s*proto\.([A-Z_]+)", sched))
    handled_by_worker = set(re.findall(r"msg\.t\s*==\s*proto\.([A-Z_]+)", worker))
    sent_by_worker = set(re.findall(r"proto\.msg\(proto\.([A-Z_]+)", worker))
    sent_by_sched = set(re.findall(r"proto\.msg\(proto\.([A-Z_]+)", sched))
    # 主控发给节点的所有类型，节点都要能处理。
    # 例外：PUT* / FETCH 走 dcpush；RESULT 是「节点 → 主控」方向，主控里出现它只是
    # 为了复用记账流程（云端结果注入 Sched:externalResult），并不会真的发出去。
    # SCREEN/DISP/SCREENOFF/SCREENBYE 走屏幕节点（dc.screen），不是 worker。
    transport = {"PUT", "PUTACK", "PUTDONE", "PUTOK", "PUTMISS", "FETCH", "REFERR", "RESULT",
                 "SCREEN", "SCREENBYE", "DISP", "SCREENOFF"}
    for name in sorted(sent_by_sched - handled_by_worker - transport):
        problems.append("sched 发送了 proto.%s，但 worker 没有处理分支" % name)
    for name in sorted(sent_by_worker - handled_by_sched - transport):
        problems.append("worker 发送了 proto.%s，但 sched 没有处理分支" % name)


def check_jobs():
    if not os.path.isdir(JOBS):
        problems.append("缺少 src/jobs 目录")
        return
    names = [n for n in os.listdir(JOBS) if n.endswith(".lua")]
    if not names:
        problems.append("src/jobs 下没有作业文件")
    for name in sorted(names):
        text = read(os.path.join(JOBS, name))
        if "return {" not in text:
            problems.append("src/jobs/%s: 没有 return 一个 table" % name)
        if not re.search(r"\bmap\s*=\s*function", text):
            problems.append("src/jobs/%s: 缺少 map 函数" % name)
        if not re.search(r"\bsplit\s*=\s*function", text):
            problems.append("src/jobs/%s: 缺少 split 函数" % name)
        base = name[:-4]
        m = re.search(r'name\s*=\s*"([^"]+)"', text)
        if not m:
            problems.append("src/jobs/%s: 缺少 name 字段" % name)
        elif m.group(1) != base:
            problems.append("src/jobs/%s: name=%s 与文件名不一致" % (name, m.group(1)))
        if "ctx.tick()" not in text:
            problems.append("src/jobs/%s: 热循环里没有 ctx.tick()，CC 会以"
                            "'Too long without yielding' 杀掉节点" % name)


def check_dist():
    for name in ("master.lua", "worker.lua", "screen.lua", "bootstrap.lua"):
        p = os.path.join(DIST, name)
        if not os.path.exists(p):
            problems.append("缺少产物 dist/%s（先运行 tools/build.py）" % name)


def main():
    srcs = lua_sources()
    check_requires(srcs)
    check_proto(srcs)
    check_jobs()
    check_dist()

    if problems:
        print("发现 %d 个问题：" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("一致性检查通过（%d 个文件）" % len(srcs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
