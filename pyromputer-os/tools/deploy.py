"""deploy.py - copy the psh project to a target machine, differential.

Only files whose content changed are written, so running it again after a small
edit touches one or two files instead of the whole tree. The tool works on any
directory: a CraftOS-PC computer folder, a floppy image mount point, or a
staging directory that is pushed later.

    python tools/deploy.py --target "C:/Users/me/AppData/Roaming/CraftOS-PC/Computer/0"

Options
  --target DIR       destination root (required)
  --source DIR       project root (default: the parent of tools/)
  --part WHICH       which half of a two-part install to copy (default: all)
                       all      the whole tree (what a machine with room gets)
                       base     only what the machine needs to BOOT: the entry
                                points and the load-time closure of lib/
                       modules  only the rest: the lazily-reached lib/ modules
                                and rpv/, for the system module store
  --dry-run          print the plan and change nothing
  --json             print a machine readable summary instead of the plan
  --prune            delete the files this tool copied earlier that the
                     project no longer has (only entries of the manifest)
  --with-etc         also copy etc/ (config samples; the machine usually has
                     its own /etc, that is why this is off by default)
  --clean-firstboot  remove the first boot markers on the target, the same
                     thing resetfirstboot does in the shell
  --without-craftos  do not deploy usr/cmd/craftos.lua (a machine without the
                     craftos command)
  --quiet            only print the final summary line

A CraftOS computer's filesystem is capped by computer_space_limit (1,000,000 by
default) and the whole tree is about 1.1 MB, so it does not fit. "--part base"
and "--part modules" are the two halves of the answer: the shell on the
computer, its own modules on a medium marked .pkgsys. See ROADMAP.md section 6.7
for the measured sizes.

README.md is a PC side document: it is never copied to a machine and no option
can make it happen.

Exit status is 0 when the target is up to date, 1 on an error.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
MANIFEST = "deploy-manifest.json"

SKIP_DIRS = {"tests", "tools", ".git", "__pycache__", ".tmp", "output", "temp",
             # fontdata/ is the GLYPH DATA, and it is deliberately not part of any
             # deployed tree: about 1 MB of CJK bitmaps, which is more than a
             # CraftOS computer's whole 1,000,000 B filesystem and is exactly why
             # the font has a medium of its own. It is a BUILD INPUT -- the thing
             # tools/fontdisk.py lays onto that medium -- and a machine gets it by
             # mounting the medium, never by having it copied. Without this entry
             # a plain --part base deploy would put the glyphs on the computer,
             # which is the one thing the design exists to prevent.
             "fontdata",
             # build output (the worker image and any release staging); like
             # tests/ and tools/ this is host side material, never a machine.
             "dist"}
SKIP_EXT = {".py", ".pyc", ".md", ".json", ".log"}
# The manifest belongs to the target machine and README.md is PC side
# documentation: neither one is ever copied, and no option changes that.
# .gitignore and LICENSE are the repository's own bookkeeping -- a machine has no
# use for either, and .gitignore was measured to leak into the deployed tree the
# moment the repository started being a git repository (gate 5 went from 52 to 53
# files in the base half). Same rule as README.md: a control file of the PC side
# is not content. THIRD_PARTY_LICENSES joins them for the same reason: it is the
# notice for the glyph data, which no machine ever receives (fontdata/ is not
# deployed at all); a 1,000,000 B computer has no room for a copy of a licence
# text, and the medium that really carries the glyphs is distributed with it.
SKIP_FILES = {MANIFEST, "README.md", ".gitignore", "LICENSE",
              "THIRD_PARTY_LICENSES"}

# ------------------------------------------------------------------- the split
#
# What a machine needs on its own disk is the LOAD-TIME closure: the entry points
# that run at boot, plus, transitively, the top-level require of everything they
# reach. A require inside a function body runs only when that function is called,
# so such a module can live on the medium instead.
#
# Every entry point counts, and forgetting one is a mistake worth naming twice,
# because it happened twice: an earlier measurement looked at usr/psh.lua alone
# and concluded that lib/pkg.lua had to stay on the computer (an artefact of the
# probe -- it started psh.lua directly with a hand-written startup, so the real
# boot path never ran), and then firstboot.lua was missing from this tuple for
# long enough that the split never saw its requires at all.
#
# firstboot.lua is an entry point by the same rule the other two are: it RUNS AT
# BOOT. startup.lua runs it (pcall(shell.run, "firstboot")) between itself and
# the shell, on a machine whose setup marker is absent, so its load-time
# requires execute on a fresh machine before any prompt exists. Being third in
# the boot order rather than first changes nothing about which half can hold
# them: a module needed at boot must be on the computer, because that is the only
# half a machine with no system module medium has.
#
# Measured with firstboot.lua left out: its column-0 requires were ignored, so
# lib/policy.lua and lib/time.lua stayed in the modules half, and a machine with
# --part base only produced
#
#   /firstboot.lua:19: module 'policy' not found
#
# 385 times in 15 seconds -- the wizard retried until the probe gave up, so the
# settings were never written and the machine could never be set up.
#
# startup.lua requires lib/marker.lua and lib/rpvnet.lua at load time. `pkg` is
# reached only lazily (inside run_pkg), so it is NOT in the closure and belongs in
# the modules half.
ENTRY_POINTS = ("startup.lua", "usr/psh.lua", "firstboot.lua")

# startup.lua also reaches these through pcall(require, ...), which still runs at
# load time: pcall swallows the failure, but the shell still wants the module.
# REQUIRE_RE cannot see such a require -- pcall(require, "x") spells it with a
# comma, not a parenthesis -- so every module reached that way has to be named
# here or it lands in the modules half, i.e. on a medium. The pcall is there so a
# missing module costs a FEATURE instead of stopping the machine, which sounds
# forgiving and is the reason this list matters: on a machine with no medium
# inserted the module is always missing, so the fallback is not exceptional, it is
# permanent and silent.
#
# lib/boot.lua is the fifth. It is the boot identity (this boot = os.epoch("utc")
# minus os.clock()) and two boot-time features ask for it through
# pcall(require, "boot"): cron's @reboot pass and the services runner's once-per-
# boot check. Measured on a machine deployed with --part base only, with
# lib/boot.lua in the modules half:
#   * no @reboot crontab entry ever fired. lib/cron.lua:531 does
#     `local first = ok and b and b.begin(REBOOT_MARKER)`, so a failed require
#     makes `first` false and the whole specials loop is skipped. @reboot is
#     observable on a real machine: the job's output file was never created.
#   * lib/services.lua:70 started_same_boot() fell through to `return true` for
#     any existing .started file, so an rc.d unit was treated as "already started
#     in this boot" for ever: it ran on the first boot and never again.
# Both are exactly the shape of failure a fallback hides -- the machine keeps
# running, and a feature is just quietly gone.
BOOT_EXTRA = ("cron", "disk", "services", "bios", "boot")

# Functions that RUN AT BOOT even though they are defined in a file whose
# top-level requires were already counted. A require inside them is therefore a
# boot-time require, not a lazy one, and classifying it as lazy puts the module on
# the medium where the machine cannot load it -- which is exactly the bug this
# list exists to prevent: lib/bios.lua and lib/interrupt.lua were first put in the
# modules half, and startup.lua requires both before the shell can start.
#
# The heuristic that needed this: only a require at column 0 was treated as
# load-time, so a require indented inside shell_init() was missed. shell_init() is
# called at the start of every session, so its requires are boot requires.
BOOT_FUNCTIONS = ("shell_init",)

# Directories whose contents are a lazily-loaded stack rather than modules.
LAZY_DIRS = ("rpv",)

REQUIRE_RE = re.compile(r'require\(\s*"([a-z_0-9]+)"\s*\)')


def _strip_comments(src):
    """The same source with every comment blanked out; length is preserved.

    THE SPLIT MUST NOT BE DECIDED BY PROSE. This function exists because it once
    was: _requires matched REQUIRE_RE against the raw text, so a require() NAMED
    IN A COMMENT counted as a real one, and because is_top_level is decided by the
    indentation of the line the match sits on, a comment at column 0 counted as a
    load-time require.

    The consequence was not cosmetic. Commenting on the split inside
    lib/complete.lua -- writing the words `local man = require("man")` in a
    sentence -- put lib/man.lua (76,549 B of manual pages) into the base half of
    the two-part install, i.e. onto a 1 MB computer's disk, where it stayed while
    gate 5 reported `problems 0`. The project's house style is comment-heavy, so
    the trap was easy to walk into and invisible once walked into.

    Blanking rather than deleting keeps every byte offset and every line start
    where it was, so the column-0 test and the boot-function line ranges still
    refer to the real file.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            m = re.match(r"\[(=*)\[", src[i + 2:])
            if m:
                close = "]" + m.group(1) + "]"
                end = src.find(close, i + 2 + m.end())
                end = n if end < 0 else end + len(close)
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
            continue
        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == quote or src[i] == "\n":
                    i += 1
                    break
                i += 1
            continue
        i += 1
    return "".join(out)


def _requires(path):
    """(name, is_top_level) for every require in a file.

    is_top_level means "runs when this file loads, or at boot". A require at
    column 0 is part of the module's header. A require inside one of
    BOOT_FUNCTIONS also counts, because those functions run at boot even though
    they are indented -- see the note on BOOT_FUNCTIONS for the bug that made this
    distinction necessary.

    Only CODE is scanned: the source goes through _strip_comments first, so a
    require named in a comment cannot move a module between the two halves. See
    that function for the 76 KB of manual pages that this cost once.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError:
        return []
    src = _strip_comments(src)
    # The line ranges of the boot functions, so a require inside one is known to
    # be a boot require. A function ends at the first line that is exactly "end".
    boot_lines = []
    lines = src.split("\n")
    for fn in BOOT_FUNCTIONS:
        for i, line in enumerate(lines):
            if re.match(r"^local function %s\s*\(" % re.escape(fn), line):
                for j in range(i + 1, len(lines)):
                    if lines[j] == "end":
                        boot_lines.append((i, j))
                        break
                break

    out = []
    for m in REQUIRE_RE.finditer(src):
        line_start = src.rfind("\n", 0, m.start()) + 1
        line = src[line_start:src.find("\n", m.start())]
        top = not line.startswith((" ", "\t"))
        if not top and boot_lines:
            lineno = src.count("\n", 0, m.start())
            for start, stop in boot_lines:
                if start < lineno <= stop:
                    top = True
                    break
        out.append((m.group(1), top))
    return out


_MODULE_CACHE = {}


def load_time_modules(source):
    """The lib/ module names reached at load time from the boot entry points.

    Memoised by source path: wanted() is called once per file and the closure
    needs every lib file, so recomputing it per path would re-read the tree
    dozens of times. The cache is module level rather than an instance attribute
    because Options is reached two ways -- constructed directly, and by swapping
    an argparse Namespace's __class__ (which skips __init__).
    """
    key = os.path.abspath(source)
    if key in _MODULE_CACHE:
        return _MODULE_CACHE[key]
    lib = os.path.join(source, "lib")
    seed = set(BOOT_EXTRA)
    for rel in ENTRY_POINTS:
        for name, is_top in _requires(os.path.join(source, rel.replace("/", os.sep))):
            if is_top:
                seed.add(name)
    seen, stack = set(), list(seed)
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        path = os.path.join(lib, name + ".lua")
        if not os.path.isfile(path):
            continue
        for sub, is_top in _requires(path):
            if is_top and sub not in seen:
                stack.append(sub)
    _MODULE_CACHE[key] = seen
    return seen


def part_of(rel, base_modules):
    """Which half a path belongs to: "base", "modules", or None when neither.

    Only lib/ and the lazy stack directories are split; everything else (usr/,
    etc/, the root files) is the base half, because that is what runs at boot.
    """
    rel = rel.replace("\\", "/")
    parts = rel.split("/")
    if parts[0] in LAZY_DIRS:
        return "modules"
    if parts[0] == "lib" and len(parts) == 2 and parts[1].endswith(".lua"):
        name = parts[1][:-4]
        return "base" if name in base_modules else "modules"
    return "base"


def parse_args(argv):
    ap = argparse.ArgumentParser(add_help=True, description="differential deploy of the psh project")
    ap.add_argument("--target", required=True)
    ap.add_argument("--source", default=REPO)
    ap.add_argument("--part", default="all", choices=("all", "base", "modules"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true", dest="as_json")
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--with-etc", action="store_true")
    ap.add_argument("--clean-firstboot", action="store_true")
    ap.add_argument("--without-craftos", action="store_true",
                    help="do not deploy usr/cmd/craftos.lua")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    args.__class__ = Options          # keep one definition of the option set
    return args


class Options:
    """The option set wanted() reads, so it can be asked without an argument list.

    tests/run_all.py asks this module which files a machine receives (the ASCII
    rule only applies to those), and it must not have to invent an option object
    of its own shape: Options() is the default set, and parse_args hands back the
    very same type.

    part="all" is the default, so the ASCII gate keeps looking at the whole tree.
    """

    def __init__(self):
        self.target = None
        self.source = REPO
        self.part = "all"
        self.dry_run = False
        self.as_json = False
        self.prune = False
        self.with_etc = False
        self.clean_firstboot = False
        self.without_craftos = False
        self.quiet = False

    def base_modules(self):
        return load_time_modules(self.source)


def wanted(rel, opts):
    """Decide whether a project relative path belongs on the machine."""
    parts = rel.replace("\\", "/").split("/")
    if any(p in SKIP_DIRS for p in parts[:-1]):
        return False
    name = parts[-1]
    if name in SKIP_FILES:
        return False
    if parts[0] == "etc":
        return opts.with_etc
    if getattr(opts, "without_craftos", False) and \
            rel.replace("\\", "/") == "usr/cmd/craftos.lua":
        return False
    if os.path.splitext(name)[1] in SKIP_EXT:
        return False
    part = getattr(opts, "part", "all")
    if part != "all":
        if part_of(rel, opts.base_modules()) != part:
            return False
    return True


def hash_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def collect(source, opts):
    out = []
    for root, dirs, files in os.walk(source):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, source).replace("\\", "/")
            if wanted(rel, opts):
                out.append(rel)
    out.sort()
    return out


def load_manifest(target):
    path = os.path.join(target, MANIFEST)
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return list(data.get("files", []))
    except Exception:
        return []


def save_manifest(target, rels, source):
    path = os.path.join(target, MANIFEST)
    data = {"tool": "tools/deploy.py", "source": source, "files": sorted(rels)}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
    return path


def marker_paths(source):
    """Read the first boot marker list out of lib/marker.lua (single source)."""
    path = os.path.join(source, "lib", "marker.lua")
    if not os.path.isfile(path):
        return []
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    block = re.search(r"LOCATIONS\s*=\s*\{(.*?)\}", text, re.S)
    if not block:
        return []
    return re.findall(r'"([^"]+)"', block.group(1))


def clean_firstboot(target, source, report):
    for rel in marker_paths(source):
        path = os.path.join(target, rel.lstrip("/").replace("/", os.sep))
        if os.path.isfile(path):
            os.remove(path)
            report["markers_removed"].append(rel)
        else:
            report["markers_absent"].append(rel)


def main(argv):
    opts = parse_args(argv)
    source = os.path.abspath(opts.source)
    target = os.path.abspath(opts.target)
    if not os.path.isdir(source):
        print("deploy: no such source: %s" % source)
        return 1
    if os.path.abspath(target) == source or source.startswith(target + os.sep):
        print("deploy: the target must not contain the source")
        return 1

    rels = collect(source, opts)
    report = {"target": target, "source": source, "part": opts.part,
              "mode": "dry-run" if opts.dry_run else "apply",
              "added": [], "updated": [], "unchanged": 0, "pruned": [],
              "markers_removed": [], "markers_absent": [], "manifest": None}

    if not opts.quiet and not opts.as_json:
        print("deploy: %s -> %s (%s, part %s)" % (source, target, report["mode"],
                                                  opts.part))

    if not opts.dry_run and not os.path.isdir(target):
        os.makedirs(target)

    for rel in rels:
        src = os.path.join(source, rel.replace("/", os.sep))
        dst = os.path.join(target, rel.replace("/", os.sep))
        if os.path.isfile(dst):
            if hash_file(src) == hash_file(dst):
                report["unchanged"] += 1
                continue
            report["updated"].append(rel)
        else:
            report["added"].append(rel)
        if not opts.dry_run:
            os.makedirs(os.path.dirname(dst) or target, exist_ok=True)
            shutil.copy2(src, dst)
        if not opts.quiet and not opts.as_json:
            print("  %-8s %s" % ("update" if rel in report["updated"] else "add", rel))

    if opts.prune:
        known = load_manifest(target)
        current = set(rels)
        for rel in known:
            if rel in current:
                continue
            dst = os.path.join(target, rel.replace("/", os.sep))
            if os.path.isfile(dst):
                report["pruned"].append(rel)
                if not opts.dry_run:
                    os.remove(dst)
                if not opts.quiet and not opts.as_json:
                    print("  %-8s %s" % ("prune", rel))
        if not known and not opts.quiet and not opts.as_json:
            print("  prune: no manifest on the target, nothing to remove")

    if opts.clean_firstboot:
        if opts.dry_run:
            report["markers_absent"] = marker_paths(source)
        else:
            clean_firstboot(target, source, report)
        if not opts.quiet and not opts.as_json:
            for rel in report["markers_removed"]:
                print("  %-8s %s" % ("marker", rel))

    if not opts.dry_run:
        report["manifest"] = save_manifest(target, rels, source)

    if opts.as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
    else:
        print("deploy: +%d ~%d =%d prune %d markers %d"
              % (len(report["added"]), len(report["updated"]),
                 report["unchanged"], len(report["pruned"]),
                 len(report["markers_removed"])))
        if not opts.quiet:
            print("deploy: %d file(s) considered, manifest %s"
                  % (len(rels), report["manifest"] or "not written (dry run)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
