#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""End-to-end check: the dcnet package under a real ush on CraftOS-PC.

    python tools/dcnet_pkg_verify.py [--exe PATH] [--keep]

Deploys the shell's base part into a throwaway computer directory, copies
tools/pkgs/dcnet to /usr/pkgs/dcnet, writes the setup marker (so firstboot is
not entered), and runs a ush script:

    dcnet version
    dcnet config

The test passes when the machine prints the dcnet version and the config block.
It is the only check that exercises the package layout, the manifest's bin
resolution and the debug/self-directory path on a real CraftOS.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DIST = ROOT / "tools" / "pkgs" / "dcnet"
DATA = ROOT / "tests" / ".dcnet_pkg_verify"
COMPUTER = DATA / "computer" / "7"

DEFAULT_EXES = [
    r"C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe",
    r"C:\Program Files (x86)\CraftOS-PC\CraftOS-PC_console.exe",
    "/usr/local/bin/craftos",
    "/usr/bin/craftos",
]


def find_exe(explicit):
    for cand in ([explicit] if explicit else []) + DEFAULT_EXES:
        if cand and os.path.exists(cand):
            return cand
    found = shutil.which("craftos") or shutil.which("CraftOS-PC_console")
    return found


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    exe = find_exe(args.exe)
    if not exe:
        print("CraftOS-PC not found (use --exe)")
        return 2

    shutil.rmtree(DATA, ignore_errors=True)
    COMPUTER.mkdir(parents=True, exist_ok=True)

    deploy = run([sys.executable, str(ROOT / "tools" / "deploy.py"),
                  "--target", str(COMPUTER), "--part", "base", "--with-etc",
                  "--quiet"])
    if deploy.returncode != 0:
        print(deploy.stdout)
        print(deploy.stderr)
        return 1

    pkg_dir = COMPUTER / "usr" / "pkgs" / "dcnet"
    if pkg_dir.exists():
        shutil.rmtree(pkg_dir)
    shutil.copytree(DIST, pkg_dir)

    # The setup marker firstboot would write; the gate only needs this computer.
    (COMPUTER / "etc").mkdir(parents=True, exist_ok=True)
    (COMPUTER / "etc" / ".configured").write_text(
        '{ computerId = "7", setup = true, at = 0 }\n', encoding="utf-8")

    (COMPUTER / "pkgcheck.ush").write_text(
        "dcnet version\ndcnet config\n", encoding="utf-8", newline="\n")
    check = COMPUTER / "pkgcheck.lua"
    check.write_text(
        'print("CHECK_START")\n'
        'local ok, rc = pcall(shell.run, "/usr/ush.lua", "/pkgcheck.ush")\n'
        'print("CHECK_RC " .. tostring(ok) .. " " .. tostring(rc))\n'
        'os.shutdown()\n', encoding="utf-8", newline="\n")

    try:
        proc = subprocess.run(
            [exe, "--headless", "--directory", str(DATA), "--id", "7",
             "--script", str(check)],
            capture_output=True, timeout=180)
        out = proc.stdout.decode("utf-8", "replace")
        err = proc.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"").decode("utf-8", "replace")
        err = (exc.stderr or b"").decode("utf-8", "replace")

    text = re.sub(r"\r", "", out)
    # 版本号以包 manifest 为准，避免每次发版都要改测试脚本
    version = ""
    manifest = DIST / "manifest"
    if manifest.exists():
        m = re.search(r"^version=(\S+)\s*$", manifest.read_text(encoding="utf-8"), re.M)
        if m:
            version = m.group(1)
    want = "dcnet %s" % version if version else "dcnet "
    ok = (version != "" and want in text and "transport: rednet" in text
          and "root:" in text and "jobs:" in text)
    print("dcnet version: %s (%s)" % ("yes" if want in text else "no", version or "?"))
    print("config block:  %s" % ("yes" if "transport: rednet" in text else "no"))
    if not ok:
        tail = "\n".join(text.splitlines()[-30:])
        print("--- output tail ---")
        print(tail)
        if err.strip():
            print("--- stderr ---")
            print("\n".join(err.splitlines()[-20:]))
    if not args.keep:
        shutil.rmtree(DATA, ignore_errors=True)
    print("RESULT dcnet-pkg " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
