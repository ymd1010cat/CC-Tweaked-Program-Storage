#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the compute-node image: dcnet worker only, no Pyromputer OS UI or fonts.

    python tools/build_worker.py

The image is written to dist/worker-image/ (ignored by git, like the other
build products). It contains just:

    startup.lua          boots dcnet worker --headless, forever
    usr/pkgs/dcnet/      the dcnet package (worker modules, jobs, worker seed)
    README

A compute node therefore has no psh shell, no firstboot wizard, no BIOS setup
screen, no font data and no CJK/font modules. The master side keeps the full
Pyromputer OS installation.
"""

import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PKG = HERE / "pkgs" / "dcnet"
OUT = ROOT / "dist" / "worker-image"

STARTUP = """-- dcnet worker image: a compute node, not an interactive machine.
-- There is no Pyromputer OS, no font data and no operator UI here: the package
-- worker owns the computer, retries after a clean or failed exit, and writes
-- its log to <root>/logs/node-<id>.log.
local BIN = "/usr/pkgs/dcnet/bin/dcnet.lua"

while true do
    local ok, rc = pcall(shell.run, BIN, "worker", "--headless")
    if not ok then
        print("[dcnet] worker failed: " .. tostring(rc))
    end
    sleep(5)
end
"""

README = """dcnet worker image
==================

A compute node only. Copy this directory onto a CraftOS computer (or mount it
as the computer root) and boot: startup.lua runs `dcnet worker --headless` in a
retry loop and never opens a shell.

It deliberately contains none of the Pyromputer OS user-facing pieces:
  * no usr/psh.lua, no firstboot, no BIOS menu, no man pages or usr/cmd tools;
  * no fontdata/ and no lib/cc_chinese / cc_font* modules;
  * no desktop or other interactive packages.

The master still runs the full Pyromputer OS installation, with dcnet in one
multishell tab and psh in another (see the repository README).

Configuration: /etc/dcnet.conf (root=, transport=, key=). Without it the
worker uses the package defaults: root /var/lib/dcnet, rednet transport.
"""


def main():
    if not (PKG / "manifest").exists():
        sys.exit("build tools/pkgs/dcnet first (python tools/build_dcnet_pkg.py)")

    if OUT.exists():
        shutil.rmtree(OUT)
    dst = OUT / "usr" / "pkgs" / "dcnet"
    (dst / "lib" / "dcnet").mkdir(parents=True, exist_ok=True)

    # Only the modules a worker loads. The master-only modules (master, sched,
    # panel, cloud), the example jobs and the push seed stay off this image.
    WORKER_MODULES = (
        "util", "protocol", "net", "console", "xfer", "jobs",
        "worker", "crypto", "state",
    )
    for name in WORKER_MODULES:
        shutil.copy2(PKG / "lib" / "dcnet" / (name + ".lua"),
                     dst / "lib" / "dcnet" / (name + ".lua"))
    for rel in ("manifest", "bin/dcnet.lua", "etc/dcnet.conf.example", "README"):
        src = PKG / rel
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, target)

    (OUT / "startup.lua").write_text(STARTUP, encoding="utf-8", newline="\n")
    (OUT / "README").write_text(README, encoding="utf-8", newline="\n")

    total = sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
    print("worker image: %d files, %d bytes" % (
        sum(1 for p in OUT.rglob("*") if p.is_file()), total))
    print("output: %s" % OUT)


if __name__ == "__main__":
    main()
