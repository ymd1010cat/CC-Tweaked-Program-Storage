#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the "Pyromputer OS without craftos" release variant.

    python tools/release_no_craftos.py

Stages the two deploy halves with --without-craftos and writes:

    dist/release-no-craftos/
        pyromputer-os-part1-no-craftos.zip
        pyromputer-os-part2-no-craftos.zip
        pyromputer-os-no-craftos-INSTALL.txt
        SHA256SUMS.txt
        RELEASE.md                  (body with {{COMMIT}} filled in)

The only difference from the normal image is that usr/cmd/craftos.lua is not
deployed, so the "craftos" command does not exist on the machine.
"""

import hashlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PSH = HERE.parent
REPO = PSH.parent
OUT = PSH / "dist" / "release-no-craftos"
STAGE = PSH / "dist" / ".stage-no-craftos"
MANIFEST = "deploy-manifest.json"


def run(*cmd):
    subprocess.run([sys.executable, *cmd], cwd=str(PSH), check=True)


def stage(part, target):
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    run(str(HERE / "deploy.py"), "--target", str(target), "--part", part,
        "--without-craftos", "--with-etc", "--quiet")
    manifest = target / MANIFEST
    if manifest.exists():
        manifest.unlink()


def add_tree(zf, src, extra=()):
    for path in sorted(src.rglob("*")):
        if path.is_file() and path.name != MANIFEST:
            zf.write(path, path.relative_to(src).as_posix())
    for name, text in extra:
        zf.writestr(name, text)
    zf.write(REPO / "LICENSE", "LICENSE")


def build_zip(path, src, extra=()):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_tree(zf, src, extra)
    return path


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def install_text(p1, p2):
    return """Pyromputer OS without craftos - installation
==========================================

This variant has no usr/cmd/craftos.lua: the "craftos" command does not exist.
Everything else is the same Pyromputer OS tree.

part 1 (computer's own disk): unzip %s and copy its CONTENTS to the computer
filesystem root. It fits a 1,000,000 B computer.
part 2 (system module medium): unzip %s and copy its CONTENTS to the medium
root; the root already carries the .pkgsys marker.

Boot: startup.lua starts psh. If you later want the craftos command, use the
normal Pyromputer OS build; this image is for machines that must not have it.

Sizes: part1 %d B, part2 %d B.
License: MIT (LICENSE in each zip).
""" % (p1.name, p2.name, p1.stat().st_size, p2.stat().st_size)


def main():
    if STAGE.exists():
        shutil.rmtree(STAGE)
    part1_dir = STAGE / "part1"
    part2_dir = STAGE / "part2"
    stage("base", part1_dir)
    stage("modules", part2_dir)

    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.iterdir():
        if old.is_file():
            old.unlink()

    p1 = build_zip(OUT / "pyromputer-os-part1-no-craftos.zip", part1_dir)
    p2 = build_zip(OUT / "pyromputer-os-part2-no-craftos.zip", part2_dir,
                   extra=((".pkgsys", ""),))
    (OUT / "pyromputer-os-no-craftos-INSTALL.txt").write_text(
        install_text(p1, p2), encoding="utf-8", newline="\n")

    sums = ["%s  %s" % (sha256(p), p.name) for p in (p1, p2)]
    (OUT / "SHA256SUMS.txt").write_text("\n".join(sums) + "\n",
                                       encoding="utf-8", newline="\n")

    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=str(REPO), text=True).strip()
    body = (PSH / "RELEASE-no-craftos.md").read_text(encoding="utf-8")
    (OUT / "RELEASE.md").write_text(body.replace("{{COMMIT}}", commit),
                                    encoding="utf-8", newline="\n")

    shutil.rmtree(STAGE)
    for p in sorted(OUT.iterdir()):
        print("%-40s %8d" % (p.name, p.stat().st_size))


if __name__ == "__main__":
    main()
