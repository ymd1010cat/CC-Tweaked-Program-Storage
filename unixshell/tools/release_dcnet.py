#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the dcnet release assets.

    python tools/release_dcnet.py

Output (git-ignored):

    dist/release-dcnet/
        dcnet-1.1.0.zip                 standalone project (dcnet/ + LICENSE)
        dcnet-ush-package-1.1.0.zip     unixshell package contents + LICENSE
        dcnet-worker-1.1.0.zip          compute-node image + LICENSE
        dcnet-INSTALL.txt
        SHA256SUMS.txt
        RELEASE.md                      GitHub release body for this commit

The body is dcnet/docs/RELEASE-dcnet.md with {{COMMIT}} replaced by HEAD.
"""

import hashlib
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
USH = HERE.parent
REPO = USH.parent
DCNET = REPO / "dcnet"
PKG = HERE / "pkgs" / "dcnet"
WORKER = USH / "dist" / "worker-image"
OUT = USH / "dist" / "release-dcnet"

VERSION = "1.1.0"
SKIP_DIRS = {".git", "__pycache__", ".ccdata", ".cloud_url", ".pytest_cache"}
SKIP_SUFFIX = {".pyc", ".pyo"}


def run(*cmd):
    subprocess.run([sys.executable, *cmd], cwd=str(USH), check=True)


def skip(path: Path):
    if any(part in SKIP_DIRS for part in path.parts):
        return True
    return path.suffix in SKIP_SUFFIX


def add_tree(zf, src: Path, prefix: str, skip_root=None):
    for path in sorted(src.rglob("*")):
        if not path.is_file():
            continue
        if skip(path):
            continue
        if skip_root and path == skip_root:
            continue
        rel = path.relative_to(src).as_posix()
        zf.write(path, (prefix + "/" + rel) if prefix else rel)


def add_license(zf):
    zf.write(REPO / "LICENSE", "LICENSE")


def sha256(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_zip(name, fill):
    path = OUT / name
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        fill(zf)
        add_license(zf)
    return path


def install_text(project, package, worker):
    return """dcnet %s - installation
====================================

A. Standalone (no unixshell)
   - master: copy dist/master.lua from the project zip to the master computer.
   - worker: copy dist/worker.lua to every worker computer.
   - wire all computers to the same wired network (wired modem + cable), then
     run the two programs. Workers need no job files; the master sends job code
     with each task.

B. unixshell package (master / machine with the full shell)
   - unzip dcnet-ush-package-%s.zip into <store>/usr/pkgs/dcnet/
     (or publish it from the pkgserver repository and run "pkg install dcnet").
   - /etc/dcnet.conf:
         root=/var/lib/dcnet
         boot=master
         multishell=1
         forward=1
         #transport=rednet
         #key=...
   - reboot: tab 1 is dcnet master, tab 2 is ush. Lines typed in ush are queued
     to the master; use "dcnet log" to read its output.

C. Compute-node image
   - unzip dcnet-worker-%s.zip into the computer's filesystem root, so that
     startup.lua lands at /startup.lua.
   - boot: it runs "dcnet worker --headless" in a loop. No ush, no fonts, no UI.
   - its log is /var/lib/dcnet/logs/node-<id>.log.

Assets
------
%s  %d bytes
%s  %d bytes
%s  %d bytes

License: MIT (LICENSE in each zip).
""" % (VERSION, VERSION, VERSION,
       project.name, project.stat().st_size,
       package.name, package.stat().st_size,
       worker.name, worker.stat().st_size)


def main():
    run(str(HERE / "build_dcnet_pkg.py"))
    run(str(HERE / "build_worker.py"))

    if OUT.exists():
        for child in OUT.iterdir():
            if child.is_file():
                child.unlink()
    OUT.mkdir(parents=True, exist_ok=True)

    project = build_zip("dcnet-%s.zip" % VERSION,
                        lambda zf: add_tree(zf, DCNET, "dcnet"))
    package = build_zip("dcnet-ush-package-%s.zip" % VERSION,
                        lambda zf: add_tree(zf, PKG, ""))
    worker = build_zip("dcnet-worker-%s.zip" % VERSION,
                       lambda zf: add_tree(zf, WORKER, ""))

    (OUT / "dcnet-INSTALL.txt").write_text(
        install_text(project, package, worker), encoding="utf-8", newline="\n")

    sums = []
    for path in (project, package, worker):
        sums.append("%s  %s" % (sha256(path), path.name))
    (OUT / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n",
                                       encoding="utf-8", newline="\n")

    body = (DCNET / "docs" / "RELEASE-dcnet.md").read_text(encoding="utf-8")
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=str(REPO), text=True).strip()
    (OUT / "RELEASE.md").write_text(body.replace("{{COMMIT}}", commit),
                                    encoding="utf-8", newline="\n")

    total = sum(p.stat().st_size for p in OUT.iterdir() if p.is_file())
    print("release: %d files, %d bytes" % (
        sum(1 for p in OUT.iterdir() if p.is_file()), total))
    for p in sorted(OUT.iterdir()):
        print("  %-34s %9d" % (p.name, p.stat().st_size))


if __name__ == "__main__":
    main()
