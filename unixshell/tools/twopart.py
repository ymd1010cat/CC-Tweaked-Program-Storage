"""twopart.py - build a complete two-part ush installation in one command.

    python tools/twopart.py --out DIR

    DIR/part1/      the computer's own disk: the boot entry points and their
                    load-time module closure
    DIR/part2/      the removable medium: the shell's own modules, laid out as
                    packages under usr/pkgs, with the marker .pkgsys at the root
    DIR/README.txt  what to copy where, and what part 2 is for

WHY ONE COMMAND AND NOT TWO DEPLOY CALLS AND A LOOP
  The two-part shape was assembled by hand: tools/rpv-verify/_ush-twopart.sh runs
  deploy.py twice and then moves each module into a package directory of its own.
  That is right for an acceptance script, which has to build the shape it is
  testing, and wrong for an operator, who would have to know that the medium is
  not "the modules half copied to a disk" but a package store -- a marker at the
  root, one directory per package, and <package>/lib/<module>.lua inside it,
  because that is the only layout lib/mounts.lua and lib/pkg.lua resolve. This
  tool is that knowledge, once.

NOTHING HERE DECIDES WHICH FILE IS IN WHICH HALF
  tools/deploy.py owns the split: part_of(), load_time_modules() and the
  BOOT_FUNCTIONS note that records what went wrong when a boot module was
  classified as a lazy one. This tool imports it and calls its main(), and reads
  the modules half back with deploy.collect() to check what it placed. A second
  copy of the rule would be a second answer to "where does this module go", and
  the wrong answer is only found on a machine that will not boot.

WHY THE MEDIUM IS A STORE AND NOT JUST A DIRECTORY OF MODULES
  Mounting the medium is the only thing that wires the modules in: lib/mounts.lua
  scans every mounted medium's <root>/usr/pkgs/<package>/lib and puts those
  directories on package.path. A medium carrying loose .lua files is therefore
  invisible to require() no matter how complete it is, and a medium with no
  marker is not searched at all. The marker is also the difference between two
  promises: .pkgsys says "these are the shell's own modules, their absence costs
  functionality", .pkgstore says "extra packages, their absence costs nothing".
  This tool writes .pkgsys, and says so in its output, because building part 2
  with the wrong marker would turn a required half into an optional one.

WHAT IT DOES ABOUT /etc AND ABOUT sys_required
  etc/ comes along, which is not deploy.py's own default: a machine usually has
  its /etc already, and a DISK IMAGE does not. Then the documented
  sys_required=1 switch in the deployed /etc/pkgstore.conf is turned on, because
  the machine this describes is exactly the one the switch is for -- its own
  modules live on a medium -- so it should report itself incomplete while the
  medium is out (pkg store, the install preflight, pkg.completeness_warning())
  instead of running on quietly with modules missing. It WARNS and does not
  refuse: the switch that refuses is store_required=1, which the same sample
  documents and this tool leaves off. --no-etc and --sys-optional undo either
  choice.

Exit status is 0 when the installation was built and verified, 1 on an error.
"""

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)

# The split, the copy and the ASCII question are all tools/deploy.py's, and it
# lives next to this file rather than in a package.
sys.path.insert(0, TOOLS)
import deploy                                                    # noqa: E402

# What lib/pkg.lua looks for at a medium's root to know it is the SYSTEM MODULE
# store. The other marker, .pkgstore, marks an ordinary package store; writing
# that one instead would claim the shell's own modules are optional extras.
MARKER = ".pkgsys"

# The store's root inside the medium (lib/pkg.lua: <medium>/usr/pkgs), and the
# layout below it: <package>/lib/<module>.lua.
STORE_ROOT = "usr/pkgs"

# The installation's own modules are built from one tree at one time, so they
# share a version. A package that is upgraded on the machine later gets its own.
PKG_VERSION = "1.0.0"

# computer_space_limit's default. Part 1 has to fit in it, and the whole point of
# the split is that number, so it is measured and reported rather than assumed: a
# machine may be configured higher, and this tool can only warn about the default.
LIMIT = 1000000

# The paths a machine needs before anything on it can run. This is the boot path
# and not a second copy of the split rule: the rule is deploy.py's. The list is
# here because a break in it is the failure with the worst symptom -- a computer
# that reports as on and runs nothing -- so it is named, not inferred. The
# modules below are the ones the split has already got wrong once (bios.lua and
# interrupt.lua were on the medium, reached from startup.lua and from
# shell_init(), and the machine could not start).
BOOT_PATHS = (
    "startup.lua", "firstboot.lua", "usr/ush.lua",
    "lib/mounts.lua", "lib/perm.lua",
    "lib/protect.lua", "lib/bios.lua", "lib/interrupt.lua",
    "lib/path.lua", "lib/sha256.lua", "lib/bitops.lua",
)

# ------------------------------------------------------------------ the groups
#
# The modules half is published as PACKAGES because that is the only shape a
# store has: lib/mounts.lua puts <root>/<package>/lib on package.path, and
# lib/pkg.lua lists, versions and removes packages. The unit chosen here is the
# concern a module belongs to, not "one package per module" (what the acceptance
# script builds: nineteen packages that all carry the same version and say
# nothing about the medium by their names). A package is what an operator sees in
# "pkg list" and what an upgrade would replace, so it is named after what it
# holds.
#
# A lib module that is not named here is an ERROR and not a guess. deploy.py
# decides which half a module goes in, so a new module arriving in the modules
# half is a decision somebody has to make; a package that quietly omits it is
# found only on a machine that cannot require it, which is the failure this whole
# file exists to make impossible.
GROUPS = {
    # man is the manual pages: 76 KB of prose, and it belongs on the medium. The
    # system module store is documented as the home of "manual pages, file
    # transfer, services", and until lib/complete.lua stopped requiring it at load
    # time it sat on the computer's disk instead -- 76,549 B of an 808,370 B part 1
    # on a 1 MB machine, purely so that Tab could complete a command's options.
    "ush-shell":  ("boot", "man", "time"),
    "ush-crypto": ("base64", "checksum", "cksum", "crypto", "md5"),
    "ush-admin":  ("logrotate", "policy", "sessionlog", "sudocache",
                   "sudorules", "who"),
    "ush-net":    ("netcmds", "rexec", "xfer"),
    "ush-pkg":    ("pkg", "semver"),
    # The CJK renderer. It belongs on the medium like the rest of the lazily
    # reached modules -- a machine that never draws Chinese does not need it at
    # boot -- and its GLYPHS belong on a medium too, but a DIFFERENT one: they are
    # about 1 MB, which is more than a whole CraftOS floppy can hold alongside the
    # system module store, so tools/fontdisk.py builds them their own medium,
    # marked cc_fonts.marker. Three modules, one concern, one package.
    "ush-cjk":    ("cc_chinese", "cc_font_shards", "cc_fonts"),
}

# The vendored rpv stack is a package of its own and keeps its directory shape
# inside it. Its loader loads its sibling modules by PATH (loadfile), so they are
# not require() names at all, and publishing them flat would promise names
# nothing asks for while colliding with the shell's own: rpv/crypto.lua and
# lib/crypto.lua would both answer to require("crypto").
RPV_GROUP = "rpv"

# Where each lib module goes, so a module named twice in GROUPS is a loud error
# here rather than a silent winner at build time.
GROUP_OF = {}
for _group, _members in GROUPS.items():
    for _name in _members:
        if _name in GROUP_OF:
            raise SystemExit("twopart: %s is in two groups (%s and %s)"
                             % (_name, GROUP_OF[_name], _group))
        GROUP_OF[_name] = _group

# The switch in the sample /etc/pkgstore.conf that this installation turns on.
SYS_REQUIRED = "sys_required=1"


class TwoPartError(Exception):
    """A failure the operator has to act on: reported, not tracebacked."""


def fail(message):
    raise TwoPartError(message)


def under(root, rel):
    """A project relative path as a host path below root.

    Forward slashes are what the reports and the manifests use (they are what the
    machine sees); os.path.join would hand Windows backslashes, so the parts are
    split here instead of substituted.
    """
    return os.path.join(root, *rel.split("/"))


def write_text(path, text):
    """Write a file the machine reads: LF endings, no BOM, no translation.

    newline="" is the whole point: Python's default translates "\\n" to the
    platform's line ending, and a CR is then a byte inside the first line rather
    than an ending. That family of mistake is not hypothetical here -- a BOM or a
    leading "return " in /.settings made the file parse as nil, so the machine
    looked protected while every setting it carried was quietly ignored.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def deploy_report(argv):
    """Run tools/deploy.py's main() and return its --json report.

    Called in-process rather than as a subprocess so the split comes from the
    module the tests also ask. Its stdout is captured because this tool prints a
    report of its own; --json is the report worth reading programmatically.
    """
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = deploy.main(list(argv))
    text = buf.getvalue()
    if code != 0:
        fail("tools/deploy.py failed (exit %s): %s"
             % (code, text.strip() or "it printed nothing"))
    start = text.find("{")
    if start < 0:
        fail("tools/deploy.py printed no report: %s" % text.strip())
    return json.loads(text[start:])


def modules_options(source):
    """The option set deploy.collect() needs to list the modules half."""
    opts = deploy.Options()
    opts.source = source
    opts.part = "modules"
    return opts


def medium_path(rel):
    """(package, path on the medium) for a file of the modules half, or None.

    None means "this file has no place in a store LAYOUT": the halves come from
    deploy.py, so a file arriving here that is not a lib module or part of the
    rpv stack is a decision someone has to make, and the caller turns that into a
    named error instead of dropping the file.
    """
    parts = rel.split("/")
    if parts[0] == "lib" and len(parts) == 2 and parts[1].endswith(".lua"):
        group = GROUP_OF.get(parts[1][:-4])
        if group is None:
            return None
        return group, "%s/%s/lib/%s" % (STORE_ROOT, group, parts[1])
    if parts[0] == RPV_GROUP and len(parts) >= 2:
        return RPV_GROUP, "%s/%s/lib/%s" % (STORE_ROOT, RPV_GROUP, rel)
    return None


def check_replaceable(path, fingerprint, force):
    """Refuse to replace a directory this tool did not write.

    Every run replaces both halves rather than adding to them: a stale file from
    an earlier tree would otherwise sit on the medium and be loaded in place of
    the one the installation means to ship. The fingerprint is what makes that
    safe to do without asking -- a directory that does not carry our own marker
    might be somebody's data, and it is left alone.
    """
    if os.path.isdir(path) and os.listdir(path):
        if not force and not os.path.exists(os.path.join(path, fingerprint)):
            fail("%s is not empty and does not look like a previous run of this "
                 "tool (no %s in it); move it away or pass --force"
                 % (path, fingerprint))


def replace_half(staged, final):
    """Put a finished half in place, replacing whatever was there."""
    if os.path.isdir(final):
        shutil.rmtree(final)
    shutil.move(staged, final)


def tree_measure(root):
    """(bytes, files) of a tree. Bytes of file CONTENT: the disk's own overhead
    is not what computer_space_limit measures, and every file's size is exact."""
    size, count = 0, 0
    for base, _dirs, files in os.walk(root):
        for name in files:
            size += os.path.getsize(os.path.join(base, name))
            count += 1
    return size, count


def switch_line(line):
    """The switch a configuration line carries, comments taken off."""
    return line.strip().lstrip("#").strip()


def enable_sys_required(path):
    """Turn on the documented sys_required switch in a deployed pkgstore.conf.

    The sample ships it commented because a machine that is not built in two
    parts has nothing to be incomplete about. A machine built by this tool is:
    the shell's own modules are on the medium, and sys_required=1 is what makes
    it say so (pkg store, the install preflight, pkg.completeness_warning())
    instead of quietly running with modules missing. The line's own ending and
    indentation are kept, so the copy is otherwise byte for byte the sample.
    """
    with open(path, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if switch_line(line) != SYS_REQUIRED:
            continue
        if not line.strip().startswith("#"):
            return False                               # already on
        end = "\r\n" if line.endswith("\r\n") else "\n"
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = indent + SYS_REQUIRED + end
        write_text(path, "".join(lines))
        return True
    end = "\r\n" if "\r\n" in text else "\n"
    if text and not text.endswith(("\n", "\r")):
        text += end
    write_text(path, text + SYS_REQUIRED + end)
    return True


def mark_medium(part2, packages):
    """Write the packages' manifests and the store marker.

    A manifest is what makes a directory a PACKAGE to lib/pkg.lua (its name and
    version are read from it), and the marker is what makes the MEDIUM a store.
    Both are written here so the medium is complete on its own: nothing about
    this installation is recorded on the computer.
    """
    for name in sorted(packages):
        write_text(under(part2, "%s/%s/manifest" % (STORE_ROOT, name)),
                   "name=%s\nversion=%s\n" % (name, PKG_VERSION))
    write_text(under(part2, MARKER),
               "ush system module store: the modules half of a two-part "
               "installation.\n"
               "This file is the marker lib/pkg.lua reads. A medium whose root "
               "carries it is\n"
               "the SYSTEM MODULE store: the shell's own modules live here and "
               "their absence\n"
               "costs functionality. An ordinary package store carries .pkgstore "
               "instead, for\n"
               "extras that cost nothing when they are lost -- do not add that "
               "marker here.\n")


def readme_text(source, part1, part2, packages):
    p1, p2 = part1, part2
    out = []
    add = out.append
    add("ush two-part installation")
    add("=========================")
    add("")
    add("Built by tools/twopart.py from:")
    add("  %s" % source)
    add("")
    add("Sizes, measured when this installation was built. A CraftOS computer's")
    add("filesystem is capped by computer_space_limit, %d B by default:" % LIMIT)
    add("  part1/  %d B in %d file(s)  (%s%% of the limit, %d B spare)"
        % (p1["bytes"], p1["files"], p1["pct"], p1["spare"]))
    add("  part2/  %d B in %d file(s)  (%d package(s), the medium)"
        % (p2["bytes"], p2["files"], len(p2["packages"])))
    add("")
    add("WHAT TO COPY WHERE")
    add("  part1/  -> the computer's own disk. Copy the CONTENTS of part1/ "
        "(startup.lua,")
    add("             lib/, usr/, ...) to the root of the computer's filesystem. "
        "This half")
    add("             boots on its own: the shell starts without the medium.")
    add("  part2/  -> the removable medium. Copy the CONTENTS of part2/ to the "
        "ROOT of the")
    add("             medium, so that its root carries the file .pkgsys and the "
        "directory")
    add("             usr/pkgs/. Not into a subdirectory: the marker is looked "
        "for at the")
    add("             root, and a medium with no marker at its root is not a "
        "store at all.")
    add("             (deploy-manifest.json in part1/ is tools/deploy.py's own "
        "record of what")
    add("             it copied; the machine does not read it.)")
    add("")
    add("PART 2 IS REQUIRED, AND ITS MARKER SAYS WHICH KIND OF STORE IT IS")
    add("  The shell's own modules -- the file transfer (xfer), the package "
        "manager (pkg),")
    add("  the manual pages, the services -- are NOT in part1/. They are here, at")
    add("  usr/pkgs/<package>/lib/<module>.lua, and the shell reaches them by "
        "MOUNTING the")
    add("  medium: mounting is what puts those directories on package.path "
        "(lib/mounts.lua).")
    add("  Without the medium the machine still boots and runs, but every one of "
        "those")
    add("  modules is missing.")
    add("")
    add("  .pkgsys marks this medium as the SYSTEM MODULE store. The other "
        "marker,")
    add("  .pkgstore, marks an ordinary package store: extra packages whose "
        "absence costs")
    add("  nothing. The two are different promises, so this medium must carry "
        ".pkgsys and")
    add("  never .pkgstore. Because it is a system store:")
    add("    * it is searched before an ordinary store, so a module the shell "
        "depends on")
    add("      wins when two media carry the same name;")
    add("    * it is never the place a new package is installed, so extras do "
        "not mix into")
    add("      the installation's own modules;")
    add("    * %s in /etc/pkgstore.conf (part1/etc/pkgstore.conf, "
        % SYS_REQUIRED)
    add("      see below) tells the machine to expect it, so a machine without "
        "the medium")
    add("      reports itself incomplete -- in \"pkg store\", in the install "
        "preflight, and")
    add("      in pkg.completeness_warning() -- instead of quietly losing "
        "functionality.")
    add("  The switch that REFUSES to work without a medium is store_required=1, "
        "which is")
    add("  off here: a missing system store is a missing feature, not a reason to "
        "block")
    add("  work that can still be done. Turn it off with \"pkg store "
        "sys-optional\".")
    add("")
    if packages:
        add("WHAT IS ON THE MEDIUM")
        for item in sorted(packages, key=lambda p: p["name"]):
            add("  %-11s %s" % (item["name"], " ".join(sorted(item["modules"]))))
        add("")
    add("REBUILDING")
    add("  python tools/twopart.py --out <dir>   (again, in place: both halves "
        "are rebuilt)")
    add("  bash tools/rpv-verify/_ush-twopart-build.sh   (boots both halves on "
        "CraftOS-PC)")
    add("")
    return "\n".join(out)


def build(source, out, with_etc, sys_required, force):
    """Produce both halves, verify them, and return the report as a table.

    The halves are assembled in a scratch directory inside --out and moved into
    place only once they verify. A build that fails in the middle therefore
    leaves a previous installation exactly as it was, rather than a half written
    part1/part2 that the next run has to decide whether it may overwrite.
    """
    if not os.path.isdir(source):
        fail("no such source: %s" % source)
    if out == source or out.startswith(source + os.sep):
        # A deploy would copy what is being built into the tree it is built from,
        # and the next run would find it there.
        fail("--out must be outside the project tree: %s" % out)

    final1 = os.path.join(out, "part1")
    final2 = os.path.join(out, "part2")
    os.makedirs(out, exist_ok=True)
    # Both guards run before either half is replaced, so a refusal for one of
    # them cannot leave the installation half old and half new.
    check_replaceable(final1, deploy.MANIFEST, force)
    check_replaceable(final2, MARKER, force)

    work = tempfile.mkdtemp(prefix=".twopart-", dir=out)
    try:
        report = assemble(source, work, out, with_etc, sys_required)
        replace_half(os.path.join(work, "part1"), final1)
        replace_half(os.path.join(work, "part2"), final2)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    write_text(os.path.join(out, "README.txt"),
               readme_text(source, report["part1"], report["part2"],
                           report["part2"]["packages"]))
    return report


def assemble(source, work, out, with_etc, sys_required):
    """Build both halves in the scratch directory, measure and verify them."""
    part1 = os.path.join(work, "part1")
    part2 = os.path.join(work, "part2")
    os.makedirs(part1)
    os.makedirs(part2)

    # ---- part 1: the computer's own disk ------------------------------------
    base_argv = ["--target", part1, "--source", source, "--part", "base", "--json"]
    if with_etc:
        base_argv.append("--with-etc")
    base_report = deploy_report(base_argv)

    sys_note = "off (--sys-optional)"
    if sys_required:
        conf = under(part1, "etc/pkgstore.conf")
        if os.path.isfile(conf):
            sys_note = "on" if enable_sys_required(conf) else "on (already on)"
        else:
            sys_note = ("not written: part1/etc/pkgstore.conf is not there "
                        "(--no-etc?)")

    # ---- part 2: the medium --------------------------------------------------
    # The modules half is deployed to a staging directory first because deploy.py
    # writes what it copies in the project's own layout; the medium needs the
    # package layout, which is this tool's job and not the deploy tool's.
    stage = tempfile.mkdtemp(prefix="ush-twopart-stage-")
    try:
        mod_report = deploy_report(["--target", stage, "--source", source,
                                    "--part", "modules", "--json"])
        staged = []
        for base, _dirs, files in os.walk(stage):
            for name in files:
                rel = os.path.relpath(os.path.join(base, name), stage)
                rel = rel.replace("\\", "/")
                if rel != deploy.MANIFEST:
                    staged.append(rel)
        staged.sort()

        packages = {}
        placed = []
        for rel in staged:
            where = medium_path(rel)
            if where is None:
                fail("the modules half carries %s and this tool does not know "
                     "which package it belongs to; name it in GROUPS in "
                     "tools/twopart.py" % rel)
            group, inside = where
            dst = under(part2, inside)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(under(stage, rel), dst)
            placed.append(rel)
            item = packages.setdefault(group, {"name": group,
                                               "version": PKG_VERSION,
                                               "modules": [], "bytes": 0})
            item["modules"].append(rel)
            item["bytes"] += os.path.getsize(dst)
    finally:
        shutil.rmtree(stage, ignore_errors=True)

    mark_medium(part2, packages)

    # ---- verification: what was produced, not what was intended -------------
    # Every check is a way the installation is useless while looking finished: a
    # boot module left on the medium (the machine does not start), a module
    # dropped by the regrouping (require fails on the machine), a medium with no
    # marker (the shell never looks at it), a part 1 that does not fit.
    checks = []

    def check(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return bool(ok)

    missing = [rel for rel in BOOT_PATHS if not os.path.isfile(under(part1, rel))]
    check("part 1 carries the boot path", not missing,
          "missing " + ", ".join(missing) if missing
          else "%d file(s) checked" % len(BOOT_PATHS))

    closure = [name for name in sorted(deploy.load_time_modules(source))
               if os.path.isfile(os.path.join(source, "lib", name + ".lua"))]
    absent = [name for name in closure
              if not os.path.isfile(os.path.join(part1, "lib", name + ".lua"))]
    check("part 1 carries the load-time closure", not absent,
          "missing " + ", ".join("lib/%s.lua" % n for n in absent) if absent
          else "%d module(s) reached at load time" % len(closure))

    decided = set(deploy.collect(source, modules_options(source)))
    dropped = sorted(decided - set(placed))
    extra = sorted(set(placed) - decided)
    check("every module of the modules half is on the medium",
          not dropped and not extra,
          "missing " + ", ".join(dropped) if dropped
          else "unexpected " + ", ".join(extra) if extra
          else "%d file(s) in %d package(s)" % (len(placed), len(packages)))

    check("the medium is not empty", bool(placed),
          "%d module file(s)" % len(placed))

    check("the medium claims the system module role",
          os.path.isfile(under(part2, MARKER)),
          "%s at the medium root %s" % (MARKER, STORE_ROOT))

    # A module that must be on the computer and is on the medium as well is the
    # failure this check exists for: the split is deploy.py's, so the two halves
    # are compared as built rather than trusted.
    base_lib = set()
    libdir = os.path.join(part1, "lib")
    if os.path.isdir(libdir):
        base_lib = {name for name in os.listdir(libdir) if name.endswith(".lua")}
    medium_lib = {os.path.basename(rel) for rel in placed
                  if rel.startswith("lib/")}
    both = sorted(base_lib & medium_lib)
    check("the two halves share no module", not both,
          "in both: " + ", ".join(both) if both
          else "%d base module(s), %d medium module(s)" % (len(base_lib),
                                                           len(medium_lib)))

    part1_bytes, part1_files = tree_measure(part1)
    part2_bytes, part2_files = tree_measure(part2)
    fits = part1_bytes <= LIMIT
    check("part 1 fits on a 1 MB computer", fits,
          "%d B of %d B, %s" % (part1_bytes, LIMIT,
                                ("%d B spare" % (LIMIT - part1_bytes)) if fits
                                else ("over by %d B" % (part1_bytes - LIMIT))))

    package_list = sorted(packages.values(), key=lambda p: p["name"])
    report = {
        "tool": "tools/twopart.py",
        "ok": all(item["ok"] for item in checks),
        "out": out,
        "source": source,
        "deploy": {
            "base": {"part": "base", "added": len(base_report["added"]),
                     "updated": len(base_report["updated"]),
                     "unchanged": base_report["unchanged"]},
            "modules": {"part": "modules", "added": len(mod_report["added"]),
                        "updated": len(mod_report["updated"]),
                        "unchanged": mod_report["unchanged"]},
        },
        "part1": {"root": os.path.join(out, "part1"),
                  "bytes": part1_bytes, "files": part1_files,
                  "with_etc": with_etc, "limit": LIMIT,
                  "pct": round(part1_bytes * 100.0 / LIMIT, 1),
                  "spare": LIMIT - part1_bytes, "fits": fits},
        "part2": {"root": os.path.join(out, "part2"),
                  "bytes": part2_bytes, "files": part2_files,
                  "kind": "sys", "marker": MARKER, "store_root": STORE_ROOT,
                  "sys_required": sys_note, "packages": package_list},
        "checks": checks,
    }
    return report


def print_report(report):
    p1, p2 = report["part1"], report["part2"]
    print("twopart: %s" % report["out"])
    print("  part 1 (the computer's disk)  %8d B  %2d file(s)   %s%% of %d B, %s"
          % (p1["bytes"], p1["files"], p1["pct"], p1["limit"],
             ("%d B spare" % p1["spare"]) if p1["fits"]
             else ("OVER by %d B" % (-p1["spare"]))))
    print("  part 2 (the medium)           %8d B  %2d file(s)   %d package(s) "
          "under %s"
          % (p2["bytes"], p2["files"], len(p2["packages"]), p2["store_root"]))
    print("  part 2 is the SYSTEM MODULE store (marker %s), not an ordinary "
          "package store (.pkgstore):" % MARKER)
    print("    the shell's own modules are on it. Without the medium the machine "
          "still boots")
    print("    and the shell runs, and every one of those modules is missing; "
          "sys_required is %s." % p2["sys_required"])
    print("  deploy: base +%d, modules +%d (the split is tools/deploy.py's)"
          % (report["deploy"]["base"]["added"],
             report["deploy"]["modules"]["added"]))
    print("  checks:")
    for item in report["checks"]:
        print("    %-4s %-42s %s" % ("ok" if item["ok"] else "FAIL",
                                     item["name"], item["detail"]))
    print("  copy the CONTENTS of part1/ to the computer's filesystem root and "
          "the CONTENTS")
    print("  of part2/ to the root of the medium; see %s"
          % os.path.join(report["out"], "README.txt"))


def main(argv):
    ap = argparse.ArgumentParser(
        description="build a complete two-part ush installation")
    ap.add_argument("--out", required=True,
                    help="directory to build part1/, part2/ and README.txt in")
    ap.add_argument("--source", default=REPO,
                    help="project root (default: the parent of tools/)")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="print a machine readable report instead of the summary")
    ap.add_argument("--force", action="store_true",
                    help="replace half directories this tool did not write")
    ap.add_argument("--no-etc", action="store_true", dest="no_etc",
                    help="do not copy etc/ (tools/deploy.py's own default)")
    ap.add_argument("--sys-optional", action="store_true",
                    help="leave sys_required off: the machine does not report "
                         "the missing medium")
    args = ap.parse_args(argv)
    try:
        report = build(os.path.abspath(args.source), os.path.abspath(args.out),
                       with_etc=not args.no_etc,
                       sys_required=not args.sys_optional,
                       force=args.force)
    except TwoPartError as exc:
        if args.as_json:
            print(json.dumps({"tool": "tools/twopart.py", "ok": False,
                              "error": str(exc)}, indent=1, sort_keys=True))
        else:
            print("twopart: %s" % exc)
        return 1
    if args.as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
    else:
        print_report(report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
