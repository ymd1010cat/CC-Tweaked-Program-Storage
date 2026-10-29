#!/usr/bin/env python3
"""Build the release zips for the project directories.

Each archive holds `<project>/` at its root plus the repository `LICENSE` at the
zip root. Members use fixed timestamps and modes, so repeated builds are
byte-identical (this is what the release workflow publishes).

`EXCLUDE_FROM_RELEASE` drops development-only material from a project's archive
(only `itn-pass` ships without its `tests/` tree; the other projects are
unchanged, byte for byte).

Usage:
    python tools/build_release.py                      # all projects -> dist/release
    python tools/build_release.py --project cardkey --out dist/release
"""
from __future__ import annotations

import argparse
import hashlib
import zipfile
from pathlib import Path

VERSIONS = {"sentinel": "2.0.0", "cardkey": "2.0.0", "pylib": "1.0.0", "itn-pass": "1.0.0"}
# project -> relative-path prefixes that stay out of the release archive.
EXCLUDE_FROM_RELEASE = {"itn-pass": ("tests/",)}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def _add(zf: zipfile.ZipFile, src: Path, arc: str) -> None:
    info = zipfile.ZipInfo(arc, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    zf.writestr(info, src.read_bytes())


def build(repo: Path, out: Path, project: str) -> Path:
    src = repo / project
    if not src.is_dir():
        raise SystemExit(f"missing source tree: {src}")
    license_file = repo / "LICENSE"
    if not license_file.is_file():
        raise SystemExit(f"missing LICENSE: {license_file}")

    dest = out / f"{project}-v{VERSIONS[project]}.zip"
    files = sorted((p for p in src.rglob("*") if p.is_file()), key=lambda p: p.as_posix())
    skip = EXCLUDE_FROM_RELEASE.get(project, ())
    if skip:
        files = [p for p in files if not p.relative_to(src).as_posix().startswith(skip)]
    with zipfile.ZipFile(dest, "w") as zf:
        for path in files:
            _add(zf, path, project + "/" + path.relative_to(src).as_posix())
        _add(zf, license_file, "LICENSE")
    return dest


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="build the project release zips")
    parser.add_argument("--project", choices=sorted(VERSIONS), help="build one project (default: all)")
    parser.add_argument("--out", default="dist/release", help="output directory (default: dist/release)")
    parser.add_argument("--repo", default=".", help="repository root (default: .)")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    out = (repo / args.out).resolve() if not Path(args.out).is_absolute() else Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for project in [args.project] if args.project else sorted(VERSIONS):
        dest = build(repo, out, project)
        with zipfile.ZipFile(dest) as zf:
            members = zf.namelist()
            top = sorted({name.split("/", 1)[0] for name in members})
        print(f"{dest}  {dest.stat().st_size} B  sha256={sha256(dest)}  files={len(members)}  top={top}")


if __name__ == "__main__":
    main()
