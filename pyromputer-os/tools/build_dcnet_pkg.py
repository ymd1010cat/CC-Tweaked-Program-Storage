#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the Pyromputer OS dcnet package from the top-level dcnet/ project.

    python tools/build_dcnet_pkg.py

Copies (and only copies) the files that belong to the package:

    dcnet/src/lib/*.lua     ->  tools/pkgs/dcnet/lib/dcnet/*.lua
    dcnet/src/jobs/*.lua    ->  tools/pkgs/dcnet/jobs/*.lua
    dcnet/dist/worker.lua   ->  tools/pkgs/dcnet/share/worker.lua

bin/dcnet.lua, manifest, etc/dcnet.conf.example and README are hand written and
are not touched.  dist/ is rebuilt first so the packaged worker always matches
the source tree.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DCNET = REPO / "dcnet"
OUT = HERE / "pkgs" / "dcnet"


def read(path):
    return path.read_text(encoding="utf-8")


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def rebuild_dist():
    script = DCNET / "tools" / "build.py"
    if not script.exists():
        sys.exit("dcnet/tools/build.py not found: %s" % DCNET)
    subprocess.run([sys.executable, str(script)], cwd=str(DCNET), check=True)


def copy_tree(src, dst, suffix=".lua"):
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for path in sorted(src.iterdir()):
        if path.is_file() and path.suffix == suffix:
            write(dst / path.name, read(path))
            n += 1
    return n


def main():
    if not (DCNET / "src" / "lib").is_dir():
        sys.exit("dcnet source tree not found: %s" % DCNET)

    rebuild_dist()

    libs = copy_tree(DCNET / "src" / "lib", OUT / "lib" / "dcnet")
    jobs = copy_tree(DCNET / "src" / "jobs", OUT / "jobs")

    worker = DCNET / "dist" / "worker.lua"
    if not worker.exists():
        sys.exit("missing %s (run dcnet/tools/build.py)" % worker)
    write(OUT / "share" / "worker.lua", read(worker))

    print("dcnet package: %d modules, %d jobs, worker %d bytes"
          % (libs, jobs, (OUT / "share" / "worker.lua").stat().st_size))
    print("output: %s" % OUT)


if __name__ == "__main__":
    main()
