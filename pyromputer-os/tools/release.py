#!/usr/bin/env python3
"""release.py - build the complete Pyromputer OS release asset set in one command.

    python pyromputer-os/tools/release.py --out DIR

The default is dist/release under the repository root. Every run builds from
scratch in a temporary directory below --out, then writes the seven files:

    pyromputer-os-part1-computer.zip          the computer's own disk
    pyromputer-os-part2-system-modules.zip    the system module medium
    pyromputer-os-fonts-size12-two-disks.zip  the CJK glyph media (part1/, part2/)
    pyromputer-os-gnome-<version>.zip         the desktop package (gnome/)
    pyromputer-os-pkgserver.zip               the package server
    pyromputer-os-INSTALL.txt                 the deployment note
    SHA256SUMS.txt                        sha256 of the five zips

WHY ONE TRACKED SCRIPT AND NOT THE OLD dist/build-ux/assemble.py
  The previous release was assembled ad hoc: assemble.py lived in dist/, which
  is gitignored, so the layout of the release existed only on the machine that
  happened to build it. This file is the same assembly logic kept in the tree:
  it runs tools/twopart.py and tools/fontdisk.py for the two halves and the
  glyph media, packs the gnome package and the package server, and writes the
  deployment note and checksums. dist/ is still only the output location.

WHAT THE ARCHIVES CARRY
  Every zip carries the repository LICENSE (MIT) at its zip root. Each font
  partN/ carries THIRD_PARTY_LICENSES (SIL OFL 1.1, copied here because
  tools/fontdisk.py does not ship it), and the gnome package carries it inside
  gnome/ and repo/gnome/ in the package server archive.

  The package server's require() closure is resolved statically: every module
  reached from pkgserver.lua and netd.lua, directly or transitively, is packed
  into lib/, and the whole rpv/ tree ships beside it. After the zip is written
  it is re-read, and every require() in its Lua sources must resolve to a file
  inside the zip -- the same check the previous build made.

  No zip binary is used (Python's zipfile writes the archives), and the script
  is stdlib-only. The generated text files are ASCII with LF endings.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
UX = os.path.dirname(TOOLS)
REPO = os.path.dirname(UX)

LICENSE = os.path.join(REPO, "LICENSE")
THIRD_PARTY = os.path.join(UX, "THIRD_PARTY_LICENSES")
GNOME_SRC = os.path.join(UX, "tools", "pkgs", "gnome")
PKG_CONF = os.path.join(UX, "etc", "pkg.conf")
TWOPART = os.path.join(TOOLS, "twopart.py")
FONTDISK = os.path.join(TOOLS, "fontdisk.py")
RPV_SRC = os.path.join(UX, "rpv")

# computer_space_limit's default; the whole point of the two-part split.
COMPUTER_LIMIT = 1000000
# A CraftOS floppy. tools/fontdisk.py refuses a part over it by itself.
FLOPPY = 1228800

# The same expression tools/twopart.py's neighbours use: a require() call whose
# argument is one literal module name. Dynamic requires are not resolvable
# statically and are not treated as names.
REQUIRE_RE = re.compile(
    r"require\s*,?\s*\(?\s*[\"']([A-Za-z0-9_.\-]+)[\"']")

# Modules a CraftOS/CraftOS-PC machine provides, plus the rpv stack, which is
# copied whole rather than by require() name. Exactly like the previous build.
EXPECTED_MISSING = {"rednet", "cc.crypto", "rpv"}

PKGSERVER_README = """\
psh package server
==================

This is the server side of `pkg install`, plus the data channel daemon:

    pkgserver.lua      the package repository server (channel pkg-repo)
    netd.lua           push/pull/rexec data channel daemon
    lib/               every module those two require, transitively
    rpv/               the RPV1 stack the transport layer loads when enabled
    repo/gnome/        a ready package: the Ubuntu GNOME desktop %(version)s
    etc/pkg.conf.example  the configuration both programs read

RUNNING IT
  Copy the contents of this archive to the root of the computer that serves
  packages (so that pkgserver.lua is at /pkgserver.lua and lib/ at /lib/).
  Copy etc/pkg.conf.example to /etc/pkg.conf and edit channel, key, repo_dir
  and (optionally) modem. The programs also accept the defaults baked into
  pkgserver.lua when /etc/pkg.conf is absent.

    pkgserver                  serve /repo on channel pkg-repo
    netd                       accept pushes, serve pulls and rexec

  The clients must use the same channel and key. The transport is rednet by
  default; /etc/network.conf can switch it to rpv (transport=rpv), which is
  why rpv/ ships here. rpv and rednet machines cannot talk to each other.

  repo/gnome/ is published under the package name gnome (the directory name is
  the package name; the version is read from its manifest).

LICENSES
  LICENSE is the MIT license of the psh project. THIRD_PARTY_LICENSES inside
  repo/gnome/ carries the SIL Open Font License 1.1 notices for the font
  renderings used by the desktop.
"""


class ReleaseError(Exception):
    """A failure the operator has to act on: reported, not tracebacked."""


def fail(message):
    raise ReleaseError(message)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_tool(script, argv):
    """Run a project tool and stop on failure."""
    command = [sys.executable, script] + argv
    print("release: %s %s" % (os.path.basename(script), " ".join(argv)))
    result = subprocess.run(command, cwd=UX)
    if result.returncode != 0:
        fail("%s failed (exit %s)"
             % (os.path.basename(script), result.returncode))


def add_file(zf, src, arcname):
    with open(src, "rb") as handle:
        data = handle.read()
    zf.writestr(arcname, data)


def add_tree(zf, src_root, arc_prefix=""):
    if not os.path.isdir(src_root):
        fail("missing directory: %s" % src_root)
    total = 0
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src_root).replace(os.sep, "/")
            add_file(zf, full, arc_prefix + rel)
            total += 1
    return total


def tree_measure(root):
    """(bytes, files) of a tree: the sum of the file contents."""
    size, count = 0, 0
    for base, _dirs, files in os.walk(root):
        for name in files:
            size += os.path.getsize(os.path.join(base, name))
            count += 1
    return size, count


def write_text(path, text):
    with open(path, "w", encoding="ascii", newline="\n") as handle:
        handle.write(text)


def gnome_version():
    """The version the gnome manifest carries; the zip name uses it."""
    manifest = os.path.join(GNOME_SRC, "manifest")
    if not os.path.isfile(manifest):
        fail("missing gnome manifest: %s" % manifest)
    with open(manifest, "r", encoding="ascii", errors="replace") as handle:
        for line in handle:
            key, _, value = line.partition("=")
            if key.strip() == "version" and value.strip():
                return value.strip()
    fail("gnome manifest carries no version: %s" % manifest)


def module_path(name):
    for candidate in (os.path.join(UX, "lib", name + ".lua"),
                      os.path.join(UX, "rpv", name + ".lua")):
        if os.path.isfile(candidate):
            return candidate
    return None


def static_closure(start_files):
    """Every module reached from the start files by a require() in the source.

    This is a superset of the load-time closure on purpose: a module that is
    only loaded inside a function (pcall(require, "osguard") in perm) is still
    needed the first time that function runs.
    """
    seen = {}
    todo = list(start_files)
    missing = set()
    while todo:
        name, path = todo.pop()
        if name in seen:
            continue
        seen[name] = path
        with open(path, "r", encoding="ascii", errors="replace") as handle:
            text = handle.read()
        for dep in REQUIRE_RE.findall(text):
            if dep in seen:
                continue
            dep_path = module_path(dep)
            if dep_path is None:
                missing.add(dep)
                continue
            todo.append((dep, dep_path))
    return seen, missing


def build_part1(twopart_dir, zip_path):
    tree = os.path.join(twopart_dir, "part1")
    if not os.path.isdir(tree):
        fail("tools/twopart.py produced no part1/: %s" % tree)
    size, files = tree_measure(tree)
    if size > COMPUTER_LIMIT:
        fail("part1 is %d B, over computer_space_limit %d B"
             % (size, COMPUTER_LIMIT))
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_tree(zf, tree)
        add_file(zf, LICENSE, "LICENSE")
    return size, files


def build_part2(twopart_dir, zip_path):
    tree = os.path.join(twopart_dir, "part2")
    if not os.path.isdir(tree):
        fail("tools/twopart.py produced no part2/: %s" % tree)
    if not os.path.isfile(os.path.join(tree, ".pkgsys")):
        fail("part2 has no .pkgsys marker at its root: %s" % tree)
    if not os.path.isdir(os.path.join(tree, "usr")):
        fail("part2 has no usr/ directory: %s" % tree)
    size, files = tree_measure(tree)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_tree(zf, tree)
        # an explicit directory entry so the archive says usr/ exists even for
        # tools that do not infer it from the files below it
        zf.writestr("usr/", b"")
        add_file(zf, LICENSE, "LICENSE")
    return size, files


def font_parts(fonts_dir):
    """The partN directories tools/fontdisk.py wrote, in ascending order."""
    if not os.path.isdir(fonts_dir):
        fail("tools/fontdisk.py produced no set directory: %s" % fonts_dir)
    parts = []
    for name in sorted(os.listdir(fonts_dir)):
        path = os.path.join(fonts_dir, name)
        if os.path.isdir(path) and re.fullmatch(r"part[0-9]+", name):
            parts.append(name)
    if not parts:
        fail("no partN/ directory under %s" % fonts_dir)
    if parts != ["part1", "part2"]:
        # the asset is defined as two media; a set of another size is not the
        # file this release promises (fontdisk.py refuses a set that does not
        # fit, so this is about the shape, not about capacity)
        fail("expected the two font media part1/ and part2/, got: %s"
             % ", ".join(parts))
    return parts


def build_fonts(fonts_dir, zip_path):
    # fontdisk.py does not copy the notices: put them in every part root so a
    # medium that is copied to a real floppy carries the OFL text with it.
    parts = font_parts(fonts_dir)
    for part in parts:
        shutil.copyfile(THIRD_PARTY,
                        os.path.join(fonts_dir, part, "THIRD_PARTY_LICENSES"))
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for part in parts:
            add_tree(zf, os.path.join(fonts_dir, part), part + "/")
        fontset = os.path.join(fonts_dir, "FONTSET.txt")
        if os.path.isfile(fontset):
            add_file(zf, fontset, "FONTSET.txt")
        add_file(zf, LICENSE, "LICENSE")
    sizes = {part: tree_measure(os.path.join(fonts_dir, part))[0]
             for part in parts}
    return sizes


def build_gnome(zip_path):
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_tree(zf, GNOME_SRC, "gnome/")
        add_file(zf, THIRD_PARTY, "gnome/THIRD_PARTY_LICENSES")
        add_file(zf, LICENSE, "LICENSE")
    return os.path.getsize(zip_path)


def build_pkgserver(zip_path, gnome_version_text):
    closure, missing = static_closure([
        ("pkgserver", os.path.join(UX, "pkgserver.lua")),
        ("netd", os.path.join(UX, "netd.lua")),
    ])
    unexpected = sorted(missing - EXPECTED_MISSING)
    if unexpected:
        fail("unresolved require(s): " + ", ".join(unexpected))
    rpv_root = os.path.abspath(RPV_SRC)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        add_file(zf, os.path.join(UX, "pkgserver.lua"), "pkgserver.lua")
        add_file(zf, os.path.join(UX, "netd.lua"), "netd.lua")
        for name in sorted(closure):
            if name in ("pkgserver", "netd"):
                continue
            src = closure[name]
            # rpv/ is copied whole below, in its own layout: publishing its
            # modules flat would promise names nothing asks for
            if os.path.dirname(os.path.abspath(src)) == rpv_root:
                continue
            arc = "lib/" + name + ".lua"
            add_file(zf, src, arc)
        add_tree(zf, RPV_SRC, "rpv/")
        add_tree(zf, GNOME_SRC, "repo/gnome/")
        add_file(zf, THIRD_PARTY, "repo/gnome/THIRD_PARTY_LICENSES")
        add_file(zf, PKG_CONF, "etc/pkg.conf.example")
        zf.writestr("README.txt",
                    PKGSERVER_README % {"version": gnome_version_text})
        add_file(zf, LICENSE, "LICENSE")

    # Verification: every require() in the archive's Lua sources must resolve
    # to a file inside the archive. Re-read the finished zip so the check is
    # about what was written, not about what was meant to be written.
    with zipfile.ZipFile(zip_path) as zf:
        names = set(zf.namelist())
        problems = []
        for entry in sorted(names):
            if not entry.endswith(".lua"):
                continue
            text = zf.read(entry).decode("ascii", "replace")
            for dep in REQUIRE_RE.findall(text):
                if dep in EXPECTED_MISSING:
                    continue
                if ("lib/%s.lua" % dep) in names or \
                   ("rpv/%s.lua" % dep) in names:
                    continue
                if entry.startswith("repo/gnome/"):
                    # the gnome package resolves its own modules through the
                    # package path of the installing machine, not this server
                    continue
                problems.append("%s requires %s" % (entry, dep))
    if problems:
        fail("closure check failed:\n  " + "\n  ".join(problems))
    return len(closure), sorted(closure)


def install_text(sizes):
    """The deployment note: what each archive is, where it goes, licenses."""
    p1, p1f = sizes["part1"]
    p2, p2f = sizes["part2"]
    fonts = sizes["fonts"]
    lines = []
    add = lines.append
    add("psh release set")
    add("===============")
    add("")
    add("Built by tools/release.py from the psh project tree. It runs")
    add("tools/twopart.py (part1/, part2/) and tools/fontdisk.py (the CJK glyph")
    add("media), then packs the desktop package and the package server. Sizes")
    add("below are measured when this build was made. A CraftOS computer's")
    add("filesystem is capped by computer_space_limit, %d B by default, and a"
        % COMPUTER_LIMIT)
    add("CraftOS floppy holds %d B:" % FLOPPY)
    add("")
    archive = [
        ("pyromputer-os-part1-computer.zip", p1,
         "%2d files  the computer" % p1f),
        ("pyromputer-os-part2-system-modules.zip", p2,
         "%2d files  the medium" % p2f),
        ("pyromputer-os-fonts-size12-two-disks.zip", sizes["fonts_zip"],
         "the glyph media"),
        ("pyromputer-os-gnome-%s.zip" % sizes["gnome_version"],
         sizes["gnome_zip"], "the desktop package"),
        ("pyromputer-os-pkgserver.zip", sizes["pkgserver_zip"],
         "the package server"),
    ]
    for name, size, note in archive:
        add("  %-38s %9d B  %s" % (name, size, note))
    add("")
    add("WHAT EACH ARCHIVE IS")
    add("")
    add("  part1 is the shell on the computer's own disk: startup.lua, lib/ (the")
    add("  load-time closure), usr/, etc/ and the root files. It boots on its own;")
    add("  the machine reaches a login prompt without the medium.")
    add("")
    add("  part2 is the shell's own optional modules on a removable medium: the")
    add("  file transfer, the package manager, the manual pages, the services and")
    add("  the RPV1 network stack. They live at usr/pkgs/<package>/lib/<module>.lua")
    add("  and are reached by MOUNTING the medium, which puts those directories on")
    add("  package.path. This is why the medium root must carry the marker .pkgsys:")
    add("  it marks a SYSTEM MODULE store (modules that are part of the")
    add("  installation), which is different from .pkgstore (an ordinary store of")
    add("  extra packages). Without the medium the machine still boots and runs;")
    add("  those modules are the part that goes missing.")
    add("")
    add("  The font archive holds the CJK glyph set at size 12 split over two")
    add("  media: part1/ and part2/ are each one medium, and FONTSET.txt says")
    add("  which part carries what. Each part root carries cc_fonts.marker and a")
    add("  fonts/ directory; the parts are not interchangeable.")
    add("")
    add("  The gnome archive is the desktop package: gnome/manifest, gnome/bin/")
    add("  and gnome/lib/gnome/. The manifest names it gnome and versions it.")
    add("")
    add("  The package server archive is the server side of pkg install plus the")
    add("  data channel daemon: pkgserver.lua and netd.lua at its root, their")
    add("  require() closure in lib/, the RPV1 stack in rpv/, a ready package in")
    add("  repo/gnome/, and the configuration sample in etc/.")
    add("")
    add("WHERE TO COPY EACH ARCHIVE")
    add("")
    add("  part1  Copy the CONTENTS of the archive (startup.lua, lib/, usr/, etc/,")
    add("         .settings, ...) to the ROOT of the computer's filesystem. On")
    add("         CraftOS-PC a computer is one directory, for example")
    add("         %APPDATA%\\CraftOS-PC\\computer\\<id>.")
    add("")
    add("  part2  Copy the CONTENTS of the archive (the file .pkgsys and the")
    add("         directory usr/) to the ROOT of the removable medium. Not into a")
    add("         subdirectory: the marker is looked for at the medium root, and a")
    add("         medium without it is not a store.")
    add("")
    add("  fonts  Copy the CONTENTS of partN/ (cc_fonts.marker and fonts/) to the")
    add("         ROOT of its own medium, one medium per part. part1 is %d B and"
        % fonts.get("part1", 0))
    add("         part2 is %d B; a CraftOS floppy holds %d B."
        % (fonts.get("part2", 0), FLOPPY))
    add("")
    add("  gnome  Copy the gnome/ directory (a directory named gnome) into a")
    add("         package store's usr/pkgs/: on the computer that is")
    add("         /usr/pkgs/gnome/, on an ordinary store <medium>/usr/pkgs/gnome/.")
    add("         The manifest names the package, so no extra registration is")
    add("         needed.")
    add("")
    add("  pkgserver  Copy the CONTENTS of the archive to the ROOT of the computer")
    add("         that serves packages, so pkgserver.lua is at /pkgserver.lua, lib/")
    add("         at /lib/ and repo/gnome/ at /repo/gnome/. Then copy")
    add("         etc/pkg.conf.example to /etc/pkg.conf and edit channel, key,")
    add("         repo_dir and (optionally) modem.")
    add("")
    add("LICENSES")
    add("  Every archive carries LICENSE at its zip root: the MIT license of the")
    add("  psh project (Copyright (c) 2026 ymd1010cat).")
    add("")
    add("  THIRD_PARTY_LICENSES is the SIL Open Font License 1.1 notice for Noto")
    add("  Sans SC, the font the CJK glyph renderings are derived from. It is")
    add("  included in each font medium's root (part1/ and part2/), inside the")
    add("  gnome package (gnome/), and inside repo/gnome/ in the package server")
    add("  archive. The font software itself is not redistributed; the bitmap")
    add("  data derived from it is.")
    add("")
    add("  Full texts: LICENSE (MIT) and THIRD_PARTY_LICENSES (OFL 1.1).")
    add("")
    return "\n".join(lines)


def build(out):
    if not os.path.isfile(LICENSE):
        fail("missing repository LICENSE: %s" % LICENSE)
    if not os.path.isfile(THIRD_PARTY):
        fail("missing THIRD_PARTY_LICENSES: %s" % THIRD_PARTY)

    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix=".release-", dir=out)
    try:
        staging = os.path.join(work, "zips")
        os.makedirs(staging)

        twopart_dir = os.path.join(work, "twopart")
        run_tool(TWOPART, ["--out", twopart_dir])
        fonts_dir = os.path.join(work, "fonts")
        run_tool(FONTDISK, ["--set-out", fonts_dir])

        version = gnome_version()
        names = {
            "part1": "pyromputer-os-part1-computer.zip",
            "part2": "pyromputer-os-part2-system-modules.zip",
            "fonts": "pyromputer-os-fonts-size12-two-disks.zip",
            "gnome": "pyromputer-os-gnome-%s.zip" % version,
            "pkgserver": "pyromputer-os-pkgserver.zip",
        }
        paths = {key: os.path.join(staging, name)
                 for key, name in names.items()}

        sizes = {}
        sizes["part1"] = build_part1(twopart_dir, paths["part1"])
        sizes["part2"] = build_part2(twopart_dir, paths["part2"])
        sizes["fonts"] = build_fonts(fonts_dir, paths["fonts"])
        sizes["fonts_zip"] = os.path.getsize(paths["fonts"])
        sizes["gnome_version"] = version
        sizes["gnome_zip"] = build_gnome(paths["gnome"])
        _count, closure = build_pkgserver(paths["pkgserver"], version)
        sizes["pkgserver_zip"] = os.path.getsize(paths["pkgserver"])

        write_text(os.path.join(staging, "pyromputer-os-INSTALL.txt"),
                   install_text(sizes))

        sums = []
        for key in ("part1", "part2", "fonts", "gnome", "pkgserver"):
            sums.append("%s  %s" % (sha256(paths[key]), names[key]))
        write_text(os.path.join(staging, "SHA256SUMS.txt"),
                   "\n".join(sums) + "\n")

        # Move everything into place only once the whole set is built, so a
        # failure halfway leaves a previous release untouched.
        final_names = [names[k] for k in
                       ("part1", "part2", "fonts", "gnome", "pkgserver")]
        final_names += ["pyromputer-os-INSTALL.txt", "SHA256SUMS.txt"]
        for name in final_names:
            os.replace(os.path.join(staging, name), os.path.join(out, name))

        print("release: %s" % out)
        for key in ("part1", "part2", "fonts", "gnome", "pkgserver"):
            print("  %9d B  %s"
                  % (os.path.getsize(os.path.join(out, names[key])),
                     names[key]))
        print("  closure: %d modules (%s)"
              % (len(closure) - 2,
                 " ".join(n for n in closure
                          if n not in ("pkgserver", "netd"))))
        print("  sha256: see SHA256SUMS.txt")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(
        description="build the complete Pyromputer OS release asset set")
    parser.add_argument(
        "--out", default=os.path.join(REPO, "dist", "release"),
        help="directory to write the seven release files in "
             "(default: <repository>/dist/release)")
    args = parser.parse_args(argv)
    try:
        build(os.path.abspath(args.out))
    except ReleaseError as exc:
        print("release: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
