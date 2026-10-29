#!/usr/bin/env python3
"""sizecheck.py - read-only install-size gate for pyroet-os.

Reads an install set (default: pyroet-os/install.set), one repo-root-relative
path per line ('#' starts a comment, blank lines ignored), walks every entry
(file, or directory recursively), sums file count and bytes, prints a table
grouped by component, then applies the three-tier budget gate.

Gate (defaults, three tiers - DECISIONS.md 0.4 / 7.1 / 8.4):
    total >  629145            -> SIZE_FAIL    exit 1   (hard gate, 3/5 MiB)
    total >  349525            -> SIZE_WARN    exit 0   (over the target line)
    total <= 349525            -> SIZE_PASS    exit 0   (target line, 1/3 MiB)
    missing install set / any
    listed path missing        -> SIZE_ERROR   exit 2

Hard gate  = 629,145 B = floor(1,048,576 * 3 / 5) = 3/5 MiB. Release blocker.
Target line = 349,525 B = floor(1,048,576 / 3) = 1/3 MiB. WARN only, never fails.

Update window (checked independently of the size verdict, so a SIZE_FAIL run
still prints its WINDOW line):
    total + backup_cap <= 900,000 B     -> WINDOW_OK   sum=<total+cap>
    total + backup_cap >  900,000 B     -> WINDOW_FAIL ... exit 1
backup_cap defaults to 200,000 B (the copy an OTA keeps while swapping slots),
so the widest image the gate can ever bless (629,145) plus that copy (200,000)
sums to 829,145: 70,855 B of headroom under the 900,000 window and 170,855 B
under the 1,000,000 B device quota (/boot.slot, logs, app data).

Component naming: by default the leading container segment ("pyroet-os", i.e.
the directory that holds the install set) is stripped, then the first remaining
segment is the component name; a file directly inside the container is reported
as "(root)". This keeps the table per-component - the literal first segment of
every path would be "pyroet-os" for the whole install set and the table would
collapse to a single row. Pass --group first for the literal rule.

Output is pure ASCII. Standard library only. This tool never writes files.
"""

from __future__ import annotations

import argparse
import os
import sys

DEFAULT_BUDGET = 629145           # 3/5 MiB, hard gate
DEFAULT_STRETCH = 349525          # 1/3 MiB, target line (WARN only)
DEFAULT_BACKUP_CAP = 200000       # bytes the updater keeps while swapping slots
WINDOW_LIMIT = 900000             # image + backup must fit under this
DEFAULT_INSTALL_SET = os.path.join("pyroet-os", "install.set")


def fail(message: str) -> None:
    print("ERROR " + message)


def find_repo_root(start: str) -> str:
    """Walk up from the script location until a directory holds pyroet-os/install.set."""
    current = os.path.abspath(start)
    for _ in range(12):
        if os.path.isfile(os.path.join(current, "pyroet-os", "install.set")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    # Fall back to the conventional layout: <repo>/pyroet-os/tools/sizecheck.py
    return os.path.abspath(os.path.join(start, os.pardir, os.pardir))


def read_install_set(path: str) -> list[str]:
    entries: list[str] = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(line.rstrip("/\\"))
    return entries


def walk_entry(root: str, entry: str, files: list[tuple[str, int]], errors: list[str]) -> None:
    """Collect (repo-relative-forward-slash-path, size) for one install-set entry."""
    native = entry.replace("/", os.sep)
    if os.path.isabs(native):
        errors.append("absolute path not allowed: " + entry)
        return
    target = os.path.normpath(os.path.join(root, native))
    if not (target == root or target.startswith(root + os.sep)):
        errors.append("path escapes repo root: " + entry)
        return
    if os.path.isfile(target):
        files.append((_rel(root, target), os.path.getsize(target)))
        return
    if os.path.isdir(target):
        found = False
        for dirpath, dirnames, filenames in os.walk(target):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                if os.path.isfile(full):
                    files.append((_rel(root, full), os.path.getsize(full)))
                    found = True
        if not found:
            errors.append("directory holds no files: " + entry)
        return
    errors.append("missing path: " + entry)


def _rel(root: str, target: str) -> str:
    return os.path.relpath(target, root).replace(os.sep, "/")


def component_of(relpath: str, container: str, group_by: str) -> str:
    parts = relpath.split("/")
    if group_by == "container" and len(parts) > 1 and parts[0] == container:
        parts = parts[1:]
    if group_by == "first":
        return parts[0]
    return parts[0] if len(parts) > 1 else "(root)"


def verdict_of(total: int, budget: int, stretch: int) -> tuple[str, int]:
    if total > budget:
        return "SIZE_FAIL", 1
    if total > stretch:
        return "SIZE_WARN", 0
    return "SIZE_PASS", 0


def print_window(total: int, backup_cap: int, window_sum: int, window_ok: bool) -> None:
    """Print the update-window verdict (independent of the size verdict)."""
    if window_ok:
        print("WINDOW_OK  sum=%d limit=%d" % (window_sum, WINDOW_LIMIT))
    else:
        print(
            "WINDOW_FAIL total=%d cap=%d sum=%d limit=%d"
            % (total, backup_cap, window_sum, WINDOW_LIMIT)
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read-only install-size gate for pyroet-os (three-tier budget).",
        add_help=True,
    )
    parser.add_argument("--root", default=None, help="repo root (default: auto-detected)")
    parser.add_argument(
        "--install-set",
        default=None,
        help="install set file, repo-root-relative (default: " + DEFAULT_INSTALL_SET + ")",
    )
    parser.add_argument("--budget", type=int, default=DEFAULT_BUDGET, help="hard gate in bytes (default: 629145 = 3/5 MiB)")
    parser.add_argument("--stretch", type=int, default=DEFAULT_STRETCH, help="target line in bytes, WARN only (default: 349525 = 1/3 MiB)")
    parser.add_argument(
        "--backup-cap",
        type=int,
        default=DEFAULT_BACKUP_CAP,
        help="bytes reserved for the update backup copy (default: 200000)",
    )
    parser.add_argument(
        "--group",
        choices=("container", "first"),
        default="container",
        help="component naming rule (default: container)",
    )
    parser.add_argument("--list", action="store_true", help="also list every counted file")
    args = parser.parse_args(argv)

    if args.budget < 0 or args.stretch < 0 or args.backup_cap < 0:
        fail("budget, stretch and backup-cap must be >= 0")
        return 2

    root = os.path.abspath(args.root) if args.root else find_repo_root(os.path.dirname(os.path.abspath(__file__)))
    install_set = (
        os.path.normpath(os.path.join(root, args.install_set))
        if args.install_set
        else os.path.normpath(os.path.join(root, DEFAULT_INSTALL_SET))
    )

    print("pyroet-os size check (read-only)")
    print("repo root  : " + root)
    print("install set: " + _rel(root, install_set))

    try:
        entries = read_install_set(install_set)
    except OSError as error:
        fail("cannot read install set: " + str(error))
        print("VERDICT    SIZE_ERROR")
        return 2

    container = _rel(root, os.path.dirname(install_set)) or "."
    files: list[tuple[str, int]] = []
    errors: list[str] = []
    for entry in entries:
        walk_entry(root, entry, files, errors)

    for message in errors:
        fail(message)
    if not entries and not errors:
        fail("install set is empty: " + _rel(root, install_set))

    dir_count = sum(1 for e in entries if os.path.isdir(os.path.join(root, e.replace("/", os.sep))))
    print(
        "entries    : %d (%d files, %d dirs, %d missing)"
        % (len(entries), len(entries) - dir_count, dir_count, len(errors))
    )
    print("")

    counted: dict[str, list[int]] = {}
    for relpath, size in files:
        key = component_of(relpath, container, args.group)
        slot = counted.setdefault(key, [0, 0])
        slot[0] += 1
        slot[1] += size

    total_bytes = sum(size for _, size in files)
    rows = sorted(counted.items(), key=lambda item: (-item[1][1], item[0]))

    header = "%-21s  %5s  %11s  %6s" % ("COMPONENT", "FILES", "BYTES", "SHARE")
    rule = "%-21s  %5s  %11s  %6s" % ("-" * 21, "-" * 5, "-" * 11, "-" * 6)
    print(header)
    print(rule)
    for name, (count, size) in rows:
        share = (100.0 * size / total_bytes) if total_bytes else 0.0
        print("%-21s  %5d  %11s  %5.1f%%" % (name, count, "{:,}".format(size), share))
    print(rule)
    print("%-21s  %5d  %11s  %5.1f%%" % ("TOTAL", len(files), "{:,}".format(total_bytes), 100.0 if total_bytes else 0.0))
    print("")

    if args.list:
        for relpath, size in sorted(files):
            print("  %11s  %s" % ("{:,}".format(size), relpath))
        print("")

    verdict, code = verdict_of(total_bytes, args.budget, args.stretch)
    window_sum = total_bytes + args.backup_cap
    window_ok = window_sum <= WINDOW_LIMIT
    print(
        "BUDGET     upper %s  stretch %s  backup cap %s  window limit %s"
        % (
            "{:,}".format(args.budget),
            "{:,}".format(args.stretch),
            "{:,}".format(args.backup_cap),
            "{:,}".format(WINDOW_LIMIT),
        )
    )
    if errors:
        print("VERDICT    SIZE_ERROR (%d problem(s) above; no size verdict)" % len(errors))
        print_window(total_bytes, args.backup_cap, window_sum, window_ok)
        return 2
    if total_bytes > args.budget:
        print("VERDICT    %s  (total %s > upper %s)" % (verdict, "{:,}".format(total_bytes), "{:,}".format(args.budget)))
        print("MARGIN     %s bytes over upper bound" % "{:,}".format(total_bytes - args.budget))
    elif total_bytes > args.stretch:
        print(
            "VERDICT    %s  (stretch %s < total %s <= upper %s)"
            % (verdict, "{:,}".format(args.stretch), "{:,}".format(total_bytes), "{:,}".format(args.budget))
        )
        print(
            "MARGIN     %s bytes over stretch; %s bytes under upper"
            % ("{:,}".format(total_bytes - args.stretch), "{:,}".format(args.budget - total_bytes))
        )
    else:
        print("VERDICT    %s  (total %s <= stretch %s)" % (verdict, "{:,}".format(total_bytes), "{:,}".format(args.stretch)))
        print(
            "MARGIN     %s bytes under stretch; %s bytes under upper"
            % ("{:,}".format(args.stretch - total_bytes), "{:,}".format(args.budget - total_bytes))
        )
    print_window(total_bytes, args.backup_cap, window_sum, window_ok)
    if not window_ok:
        return 1
    return code


if __name__ == "__main__":
    sys.exit(main())
