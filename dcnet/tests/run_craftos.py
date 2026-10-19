#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 CraftOS-PC（真 CraftOS 实现）跑 tests/craftos_test.lua。

    python tests/run_craftos.py [--exe <路径>] [--keep]

做的事：
  1. 找一个干净的临时数据目录
  2. 把项目目录以读写方式挂载到真机里的 /project
  3. headless 启动真机，运行 tests/craftos_test.lua
  4. 抓 stdout，判定 "ALL PASS" / "FAILED"（挂了就杀掉并报超时）

真机覆盖的是模拟器覆盖不到的部分：真 read()、真 parallel.lua、真 textutils、
CraftOS-PC 的 5.1 装载分支、真 os.clock 粒度、以及 master.run/worker.run 的
完整进程结构。
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_EXES = [
    r"C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe",
    r"C:\Program Files (x86)\CraftOS-PC\CraftOS-PC_console.exe",
    "/usr/local/bin/craftos",
    "/usr/bin/craftos",
]

MARKERS = re.compile(r"^(== |  \[ok\]|  \[XX\]|  _VERSION|  ——|  \||结果：|ALL PASS|FAILED)")


def start_cloud_server():
    """在测试进程里起一个 dcnet 云端参考服务端，返回 (url, shutdown)。

    真机测试会通过 http 真发请求到这个 127.0.0.1 服务端——既验证云端卸载链路，
    也验证 CraftOS 的 http 栈本身能用。CraftOS-PC 的 http 黑名单是空的，
    所以允许访问本机地址（CC:Tweaked 默认会拦 localhost，届时用内网 IP 即可）。
    """
    import importlib.util
    import threading
    from http.server import ThreadingHTTPServer

    path = os.path.join(ROOT, "cloud", "server.py")
    spec = importlib.util.spec_from_file_location("dcnet_cloud_server", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.VERBOSE = False

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    url = "http://127.0.0.1:%d/dcnet" % httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return url, httpd.shutdown


def find_exe(explicit):
    for cand in ([explicit] if explicit else []) + DEFAULT_EXES:
        if cand and os.path.exists(cand):
            return cand
    found = shutil.which("craftos") or shutil.which("CraftOS-PC_console")
    if found:
        return found
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe")
    ap.add_argument("--keep", action="store_true", help="保留真机数据目录")
    ap.add_argument("--data", help="真机数据目录（缺省 <项目>/tests/.ccdata，必须可写）")
    ap.add_argument("--timeout", type=int, default=240)
    args = ap.parse_args()

    exe = find_exe(args.exe)
    if not exe:
        print("找不到 CraftOS-PC（可用 --exe 指定 CraftOS-PC_console 的路径）")
        return 2

    # 真机数据目录默认放在工作区内：DSH 的 workspace-write 沙箱只允许写工作区，
    # 用 tempfile 建到 %TEMP% 会在受限策略下直接失败（执行 CraftOS-PC 本身没问题）。
    data = args.data or os.path.join(HERE, ".ccdata")
    shutil.rmtree(data, ignore_errors=True)
    try:
        os.makedirs(data, exist_ok=True)
    except OSError as e:
        print("无法创建真机数据目录 %s：%s" % (data, e))
        print("（可加 --data <某个可写目录> 换位置）")
        return 2
    # 开机自检文件：万一 --script 没跑起来，这里能看到真机是否被拉起来了
    probe = os.path.join(data, "_writable_probe")
    with open(probe, "w", encoding="utf-8") as f:
        f.write("ok")
    os.remove(probe)

    # 起云端参考服务端，把 URL 交给真机测试（真机会读 /project/tests/.cloud_url）
    url_file = os.path.join(HERE, ".cloud_url")
    cloud_shutdown = None
    try:
        url, cloud_shutdown = start_cloud_server()
        with open(url_file, "w", encoding="utf-8") as f:
            f.write(url)
        print("云端参考服务端: " + url)
    except Exception as e:                             # noqa: BLE001
        print("云端服务端未启动（云端相关测试会跳过）: %s" % e)
        if os.path.exists(url_file):
            os.remove(url_file)

    # 注意 CraftOS-PC 的写法是 <CC 里的挂载点>=<宿主目录>（和 --help 的字面顺序相反）
    cmd = [
        exe, "--headless",
        "--directory", data,
        "--id", "7",
        "--mount-rw", "/project=%s" % ROOT,
        "--script", os.path.join(HERE, "craftos_test.lua"),
    ]
    print("启动: " + " ".join('"%s"' % c if " " in c else c for c in cmd))
    t0 = time.time()
    timed_out = False
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=args.timeout)
        stdout = proc.stdout.decode("utf-8", "replace")
        stderr = proc.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as e:
        timed_out = True
        stdout = (e.stdout or b"").decode("utf-8", "replace")
        stderr = (e.stderr or b"").decode("utf-8", "replace")

    # 优先读真机里写下的结果文件（headless 的 stdout 会按终端刷屏，很吵）
    result_path = os.path.join(data, "computer", "7", "craftos_test_result.txt")
    text = ""
    if os.path.exists(result_path):
        with open(result_path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        if text.strip():
            print(text)
    else:
        picked = []
        for line in stdout.splitlines():
            line = line.rstrip()
            if MARKERS.match(line) and (not picked or picked[-1] != line):
                picked.append(line)
        print("\n".join(picked) if picked else "（没有抓到任何标记行）")

    dur = time.time() - t0

    if cloud_shutdown:
        cloud_shutdown()
    if os.path.exists(url_file):
        os.remove(url_file)
    if not args.keep:
        shutil.rmtree(data, ignore_errors=True)
    else:
        print("数据目录保留在: " + data)

    if timed_out:
        print("\n[超时] CraftOS-PC 在 %ds 内没有退出（脚本可能报错后落回交互 shell）" % args.timeout)
        if stderr.strip():
            print("[stderr]\n" + stderr[-2000:])
        return 1

    if "ALL PASS" in text or "ALL PASS" in stdout:
        print("\n真机测试通过（%.1fs）" % dur)
        return 0
    print("\n真机测试失败（%.1fs）" % dur)
    if not text:
        tail = stdout.splitlines()[-40:]
        print("--- 输出尾部 ---")
        print("\n".join(tail))
    if stderr.strip():
        print("[stderr]\n" + stderr[-2000:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
