"""fontdisk.py - build the FONT MEDIUM: the disk (or disks) the glyphs live on.

    one medium that holds the whole set:

        python tools/fontdisk.py --out DIR

    every medium of a set that is too big for one:

        python tools/fontdisk.py --set-out DIR --disks 2

    DIR/cc_fonts.marker      the marker that makes a medium a FONT medium
    DIR/fonts/shs12_*.lua    the glyph shards and the index, as fontgen.py wrote
    DIR/fonts/shs12.set.lua  which PART of the set this medium carries
    DIR/FONTDISK.txt         what is on it, how big it is, and how to mount it

WHY THE GLYPHS GET A MEDIUM OF THEIR OWN
  The glyphs are rasterised by tools/fontgen.py from Noto Sans SC, which is
  under the SIL Open Font License 1.1; the licence text and the attribution are
  in THIRD_PARTY_LICENSES at the repository root, and every generated index
  repeats the source font's name in its first line so that a medium found later
  can still be traced to it -- ship that file with the media you distribute.
  A CraftOS computer's own filesystem is capped by computer_space_limit,
  1,000,000 B by default, and the shell plus its boot modules already use about
  73% of that. The size 12 glyph set is about 1 MB, so it cannot go on the
  computer at all -- not as a design preference but as arithmetic. This tool
  produces the second medium that carries them, because the machine can only find
  it by its marker: a file named cc_fonts.marker in the medium's root.

WHY A SET MAY NEED TWO MEDIA, AND WHAT "A PART" MEANS
  The whole of GB2312 at size 12 measures 1,375,263 B (measured, see
  tools/fontgen.py --full) and a CraftOS floppy holds 1,228,800 B, so the
  standard is 146,463 B too big for the medium it would have to live on. The
  operator's instruction was "the Chinese shards do not fit on one drive, so use
  two", so a set may be built as several media, and each one is a PART:

   * the SHARDS are dealt out, whole, one part each. A shard is the unit because
     the loader opens <base>_shard<N>.lua whole: a shard that does not fit a
     medium cannot be made to fit by splitting it, only by generating it smaller
     (tools/fontgen.py --shard-size), and that is what the error says.
   * the INDEX is SPLIT, not duplicated: fonts/shs12_index.lua on part 1 names
     only part 1's shards, and part 2's names only part 2's. Nothing is copied.
   * fonts/shs12.set.lua is the manifest: it says which set this is, which part
     this medium carries, and -- for every part -- the shards and the codepoint
     range it covers. That last one is what lets a machine holding only one
     medium answer "U+7480 is in shs12 part 2 of 2, which is not inserted"
     instead of drawing nothing and saying nothing.

WHY IT IS ALSO A PACKAGE STORE BY DEFAULT
  The package that renders with these glyphs declares
  requires_disk=cc_fonts.marker, and lib/pkg.lua looks for that marker only on
  media it already counts as package stores (pkg.store_list). A medium with the
  font marker and no store marker therefore cannot satisfy the very requirement
  that exists to check for it. So .pkgstore is written too, and NEVER .pkgsys:
  the system store marker would claim these glyphs are modules the shell itself
  needs in order to boot, which is the opposite of what they are -- data the
  shell reads when a program asks it to draw. Use --no-store for the plain medium
  instead, and then run "pkg store <n>" on the machine before installing the
  package that needs the font.

WHY A SIBLING TOOL AND NOT AN OPTION OF tools/twopart.py
  twopart.py builds an INSTALLATION -- a computer's half and a system module half.
  This is a different object: a data medium that belongs to no particular
  installation and can be shared by several machines, moved between drive bays, or
  rebuilt on its own. Its arithmetic is different too (a floppy, not the
  computer's limit) and so are its failure modes (a shard that did not come
  across). A flag on twopart.py would have made one report answer two questions.

WHY THE SPLIT IS HERE AND NOT IN tools/fontgen.py
  fontgen.py knows the glyphs; the capacity a set has to fit is a property of the
  MEDIUM, and it is a parameter here (--capacity). Splitting before the medium is
  built would mean teaching the generator about floppies, and then re-teaching it
  when a medium is not a floppy. fontgen.py's --shard-size is the knob that
  decides how big the indivisible unit is; this tool decides which unit goes
  where, measures the result, and REFUSES to write a medium it cannot fit.

Exit status is 0 when the medium (or every medium of the set) was built and
verified, 1 on an error.
"""

import argparse
import json
import os
import re
import shutil
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)

# The names the runtime, the package manager and the operator each look for.
FONT_MARKER = "cc_fonts.marker"        # lib/cc_fonts.lua
STORE_MARKER = ".pkgstore"             # lib/pkg.lua
FONTS_DIR = "fonts"                    # lib/cc_fonts.lua's cc_fonts.DIR
NOTES = "FONTDISK.txt"
SET_NOTES = "FONTSET.txt"
INDEX_SUFFIX = "_index.lua"
SHARD_MARK = "_shard"
MANIFEST_SUFFIX = ".set.lua"           # lib/cc_fonts.lua's cc_fonts.MANIFEST_SUFFIX

# The name of the directory one part is built in, inside a set directory.
PART_DIR = "part%d"

# A CraftOS floppy is 1,228,800 bytes (1,200 KiB). It is the DEFAULT capacity and
# not a constant the code assumes: "does it fit" is measured and reported rather
# than hoped for, the capacity is a parameter (--capacity), and a medium whose
# contents exceed it is refused rather than written. A set that is too big for
# the medium is the one failure an operator cannot see on a finished-looking
# disk.
FLOPPY = 1228800

# What a part costs BESIDES the glyph files it carries: its marker, the store
# marker, the manifest beside the index, and FONTDISK.txt, which lists one line
# per shard. The split is planned with this held back, and then the built tree is
# MEASURED and refused if the estimate was too small. 8 KB is deliberately
# generous: being over-generous costs a few KB of a 1.2 MB medium, being
# under-generous builds a medium that does not fit.
PART_OVERHEAD_RESERVE = 8192

# The fixed comment lines of a part's index, before its entries.
INDEX_HEADER_RESERVE = 512


class FontdiskError(Exception):
    """A failure the operator has to act on: reported, not tracebacked."""


def fail(message):
    raise FontdiskError(message)


def write_text(path, text):
    """LF endings, no BOM, whatever the host thinks a line ending is.

    newline="" is the point, and it is not a style choice: Python's default
    translates "\\n" on Windows, so a CR arrives on the machine as a byte inside
    the first line rather than as an ending.
    """
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="") as fh:
        fh.write(text)


def tree_measure(root):
    """(bytes, files) of a tree: the sum of the file CONTENTS.

    Content is what a CraftOS filesystem counts against its limit, and it is what
    an operator copies: a directory entry takes no space of its own.
    """
    size, count = 0, 0
    for base, _dirs, files in os.walk(root):
        for name in files:
            size += os.path.getsize(os.path.join(base, name))
            count += 1
    return size, count


def index_entries(path):
    """The shard ids an index names, in the order the file lists them.

    Read as text rather than evaluated: this is a PC side tool and it must not
    need a Lua runtime to count what it just wrote. The lines it looks at are the
    "[codepoint]=shard," rows fontgen.py emits, whose shape is that tool's.
    """
    ids = []
    with open(path, "r", encoding="ascii") as fh:
        for line in fh:
            if not line.startswith("["):
                continue
            _, _, value = line.partition("=")
            ids.append(value.strip().rstrip(","))
    return ids


def read_index(path):
    """(header, shape, [(codepoint, shard_id)]) out of a fontgen index file.

    The comments are carried through into every per-part index, so that a part
    found on a medium still says which font, face and size it was generated
    from, and the matrix shape the runtime reads is not lost by splitting. The
    entries are kept in file order, which is codepoint order.
    """
    header, shape, entries = None, None, []
    with open(path, "r", encoding="ascii", newline="") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("-- matrix:"):
                shape = line[3:]
            elif line.startswith("-- codepoint ->") or line.startswith("-- part "):
                continue
            elif line.startswith("-- ") and header is None:
                header = line[3:]
            elif line.startswith("["):
                head, _, value = line.partition("=")
                entries.append((int(head.strip("[]")), int(value.strip().rstrip(","))))
    return header, shape, entries


def index_header(path):
    """What the index's own comment says it was generated from.

    fontgen.py writes a first line naming the font, the face and the size, and
    the medium's notes quote it for the same reason the generator writes it: a
    shard found later on a medium should say what it is instead of leaving that
    to be inferred from the numbers.
    """
    with open(path, "r", encoding="ascii") as fh:
        first = fh.readline().strip()
    if first.startswith("-- "):
        return first[3:]
    return None


def check_replaceable(path, force, fingerprint=FONT_MARKER):
    """Refuse to replace a directory this tool did not write.

    Every run replaces the medium rather than adding to it: a stale shard from an
    earlier generation would otherwise sit beside the new ones and be read for a
    codepoint the index still points at it. The fingerprint is what makes the
    replacement safe -- a directory without our own marker might be somebody's
    data, and it is left alone.
    """
    if not os.path.isdir(path) or not os.listdir(path):
        return
    if force:
        return
    if os.path.exists(os.path.join(path, fingerprint)):
        return
    fail("%s is not empty and does not look like a previous run of this tool "
         "(no %s in it); move it away or pass --force" % (path, fingerprint))


def check_own_tree(out, source):
    """--out must not be the source tree or the project root.

    A build into the tree it reads from, or over the tree itself, is how a tool
    eats its own input.
    """
    if out == REPO or out == source or out.startswith(source + os.sep):
        fail("--out must be outside --data (and not the project root): %s" % out)


def collect(source):
    """Split the glyph files in --data into (index, shards), or fail loudly."""
    if not os.path.isdir(source):
        fail("--data %s is not a directory; build the glyphs first with "
             "tools/fontgen.py --out %s" % (source, source))
    indexes, shards = [], []
    for name in sorted(os.listdir(source)):
        path = os.path.join(source, name)
        if not (os.path.isfile(path) and name.endswith(".lua")):
            continue
        item = {"file": name, "path": path, "bytes": os.path.getsize(path)}
        if name.endswith(INDEX_SUFFIX):
            indexes.append(item)
        elif SHARD_MARK in name:
            shards.append(item)
    if not indexes:
        fail("no *%s in %s: that is the file the runtime opens first"
             % (INDEX_SUFFIX, source))
    if not shards:
        fail("no *%sN.lua in %s: the index names glyphs that are not there"
             % (SHARD_MARK, source))
    # One index per medium: the loader scans <medium>/fonts for *_index.lua and
    # takes the set whose stem it was asked for, so two SETS in one directory
    # would make which one is used depend on the order of a directory listing.
    if len(indexes) > 1:
        fail("%s holds %d index files (%s); build one set at a time"
             % (source, len(indexes), ", ".join(i["file"] for i in indexes)))
    return indexes[0], shards


def shard_id_of(name, base):
    """The shard id in a shard file's name, or None when it is not one."""
    if not (name.startswith(base + SHARD_MARK) and name.endswith(".lua")):
        return None
    body = name[len(base) + len(SHARD_MARK):-len(".lua")]
    return int(body) if body.isdigit() else None


def part_index_source(header, shape, base, part, parts, entries, set_glyphs, shard_ids):
    """One medium's index: the entries whose shard is on THIS medium.

    THE INDEX IS SPLIT, NOT COPIED. A part that carried the whole index would
    claim glyphs it does not have, which is exactly the failure the loader
    cannot see: a lookup would find the codepoint, open a shard file that is on
    the other medium, and draw nothing. So a part's index names only its own
    shards, and its own comment says how many of the set's glyphs that is.
    """
    out = []
    if header:
        out.append("-- %s\n" % header)
    out.append("-- %s part %d of %d: %d of the set's %d glyph(s), shard(s) %s\n"
               % (base, part, parts, len(entries), set_glyphs,
                  ",".join(str(s) for s in shard_ids)))
    out.append("-- codepoint -> shard id, for <base>_shard<N>.lua\n")
    if shape:
        out.append("-- %s\n" % shape)
    out.append("return {\n")
    for cp, shard in entries:
        out.append("[%d]=%d,\n" % (cp, shard))
    out.append("}\n")
    return "".join(out)


def manifest_source(base, part, parts, glyphs, shard_ids, plan, header=None):
    """The manifest beside the index: which part of the set this medium is.

    Read by lib/cc_fonts.lua and lib/cc_font_shards.lua with the ROM's own
    loadstring, so it is plain Lua data, ASCII, and small: one line per part of
    the set. `plan` is on EVERY part and not only on part 1, because a machine
    holding only part 2 has to be able to say which part is missing.
    """
    if not re.match(r"^[A-Za-z0-9_]+$", base):
        # The name is written into a Lua string literal. A stem with a quote or a
        # backslash in it is not a font set name, and refusing here is the
        # difference between a manifest and a syntax error on the machine.
        fail("the set name %r is not a plain name ([A-Za-z0-9_]+): rename the "
             "glyph files or pass --base to tools/fontgen.py" % base)
    out = []
    out.append("-- ush font set manifest: which PART of a multi-medium glyph set\n")
    out.append("-- this medium is. Read by lib/cc_fonts.lua and cc_font_shards.lua.\n")
    out.append("-- name   the set these glyphs belong to (the index file's stem)\n")
    out.append("-- parts  how many media the whole set needs\n")
    out.append("-- part   which one this is\n")
    out.append("-- shards the shard ids THIS medium's index names, and no others\n")
    out.append("-- plan   every part of the set, so a machine holding only this one\n")
    out.append("--        can still name the part that is missing instead of\n")
    out.append("--        drawing a blank; first/last are the codepoint range\n")
    if header:
        out.append("-- %s\n" % header)
    out.append('return {name="%s",parts=%d,part=%d,glyphs=%d,shards={%s},plan={\n'
               % (base, parts, part, glyphs,
                  ",".join(str(s) for s in shard_ids)))
    for entry in plan:
        out.append("{part=%d,shards={%s},glyphs=%d,first=%d,last=%d},\n"
                   % (entry["part"],
                      ",".join(str(s) for s in entry["shards"]),
                      entry["glyphs"], entry["first"], entry["last"]))
    out.append("}}\n")
    return "".join(out)


def manifest_fields(text):
    """name/part/parts/glyphs read out of a manifest, as text.

    This is the tool checking its OWN output with a reader that does not share
    the writer's code path: if the Lua it wrote does not say what the report
    says, the medium is wrong in a way no size report can see.
    """
    out = {}
    for key in ("name", "part", "parts", "glyphs"):
        found = re.search(r"\b%s=(\"[^\"]*\"|[0-9]+)" % key, text)
        if not found:
            return None
        value = found.group(1)
        out[key] = value.strip('"') if value.startswith('"') else int(value)
    return out


def marker_text(with_store, spec=None):
    text = (
        "ush font medium: the bitmap glyphs of the CJK renderer.\n"
        "\n"
        "This file is the marker lib/cc_fonts.lua looks for. A medium whose root\n"
        "carries it is the FONT medium: %s/*%s and the shard files beside it\n"
        "are the glyph data. It is a THIRD marker, and the three mean three\n"
        "different things:\n"
        "\n"
        "  cc_fonts.marker  this medium carries font glyphs (this file)\n"
        "  .pkgsys          the system module store: modules the shell itself needs\n"
        "  .pkgstore        an ordinary package store: extra packages%s\n"
        "\n"
        "Only a medium carrying a store marker is searched for packages, which is\n"
        "why the store marker is usually here as well: the package that renders\n"
        "with these glyphs declares requires_disk=%s, and lib/pkg.lua looks for\n"
        "that marker only on media it already counts as stores.\n"
        "\n"
        "The glyphs are on a medium of their own because they do not fit on the\n"
        "computer: a CraftOS computer holds 1,000,000 bytes and the shell already\n"
        "uses about 73%% of that. See %s for the measured numbers.\n"
        % (FONTS_DIR, INDEX_SUFFIX, " (this one)" if with_store else " (not here)",
           FONT_MARKER, NOTES)
    )
    if spec and spec.get("parts", 1) > 1:
        text += (
            "\n"
            "THIS IS PART %d OF %d OF A SET. Its index names only the glyphs on\n"
            "this medium, and %s%s beside it says which part this is and what the\n"
            "other parts carry. Mount EVERY part: with a part missing, a character\n"
            "that lives on it is reported as being on the part that is absent,\n"
            "instead of being drawn as a box or as nothing at all.\n"
            % (spec["part"], spec["parts"], spec["base"], MANIFEST_SUFFIX)
        )
    return text


def notes_text(report):
    """The medium's own README: what is on it, how big it is, how to use it."""
    out = []
    add = out.append
    add("ush font medium")
    add("===============")
    add("")
    add("Built by tools/fontdisk.py. Copy the CONTENTS of this directory to the")
    add("ROOT of the medium, so that its root carries %s and the directory %s/."
        % (FONT_MARKER, FONTS_DIR))
    add("Not into a subdirectory: the marker is looked for at the root, and a")
    add("medium without it at its root is not a font medium at all.")
    add("")
    add("THE GLYPHS")
    if report["generated_from"]:
        add("  generated  %s" % report["generated_from"])
    add("  set        %s*%s" % (report["base"], INDEX_SUFFIX))
    add("  glyphs     %d, in %d shard(s)" % (report["glyphs"], len(report["shards"])))
    add("  the cell size is in the index's comment lines: the runtime reads the")
    add("  matrix it is given, so the medium carries whatever size was built.")
    add("")
    if report["parts"] > 1:
        add("THIS IS PART %d OF %d OF THE SET %s"
            % (report["part"], report["parts"], report["base"]))
        add("  shards     %s (this medium)"
            % ", ".join(str(s) for s in report["shard_ids"]))
        add("  glyphs     %d of the set's %d" % (report["glyphs"], report["set_glyphs"]))
        add("  the split is in %s%s beside the index, and it is on every part, so a"
            % (report["base"], MANIFEST_SUFFIX))
        add("  machine holding only this one can still say which part is missing.")
        add("  MOUNT EVERY PART: with a part missing, a character that lives on it")
        add("  is reported as being on the absent part instead of being drawn as a")
        add("  box, which would claim the font does not have it.")
        add("")
    add("SIZES, measured when this medium was built")
    add("  %-24s %9s %9s" % ("file", "bytes", "glyphs"))
    for shard in report["shards"]:
        add("  %-24s %9d %9d" % (shard["file"], shard["bytes"], shard["glyphs"]))
    add("  %-24s %9d %9d" % (report["index"]["file"], report["index"]["bytes"],
                             report["index"]["entries"]))
    add("  %-24s %9d %9d" % (report["manifest"]["file"], report["manifest"]["bytes"],
                             report["manifest"]["glyphs"]))
    add("  %-24s %9d %9d" % ("TOTAL", report["bytes"], report["glyphs"]))
    add("")
    add("  the medium this was fitted to holds %d B (the capacity the build was"
        % report["capacity"])
    add("  given), so this medium is %d B of it (%.1f%%) with %d B spare."
        % (report["bytes"], report["percent"], report["spare"]))
    add("")
    add("HOW TO USE IT")
    add("  On CraftOS-PC, mount the directory as a drive:")
    add("    CraftOS-PC_console.exe --mount-rw \"/disk2=<this directory>\"")
    if report["parts"] > 1:
        add("  A set of %d parts is mounted with one --mount-rw PER PART, at"
            % report["parts"])
        add("  different drive names:")
        for index in range(1, report["parts"] + 1):
            add("    --mount-rw \"/disk%d=<the directory of part %d>\""
                % (index + 1, index))
    add("  The glyphs are then at /disk2/%s/, and lib/cc_fonts.lua finds them by"
        % FONTS_DIR)
    add("  the marker. No drive letter is recorded anywhere, so the medium is")
    add("  still found after a reboot or in another bay.")
    add("")
    add("  In the shell, \"mount /disk2 /mnt/fonts\" works too: the renderer asks")
    add("  the mount table before it looks at the drive list.")
    add("")
    add("REBUILDING")
    add("  python tools/fontgen.py --size 12 --out fontdata")
    add("  python tools/fontdisk.py --out <dir> --data fontdata")
    add("  ... or, for a set too big for one medium:")
    add("  python tools/fontdisk.py --set-out <dir> --data fontdata --disks N")
    add("")
    return "\n".join(out)


def set_notes_text(report):
    """The set directory's README: every part, its size, and how to mount them."""
    out = []
    add = out.append
    add("ush font set")
    add("============")
    add("")
    add("Built by tools/fontdisk.py --set-out. The set %s does not fit one medium,"
        % report["base"])
    add("so it is %d media, one directory each:" % report["disks"])
    add("")
    add("  %-10s %9s %9s %8s  %s"
        % ("part", "bytes", "glyphs", "spare", "shards"))
    for part in report["parts"]:
        add("  %-10s %9d %9d %8d  %s"
            % ("part%d" % part["part"], part["bytes"], part["glyphs"], part["spare"],
               ", ".join(str(s) for s in part["shards"])))
    add("  %-10s %9d %9d %8d" % ("TOTAL", report["bytes"], report["glyphs"],
                                 report["spare"]))
    add("")
    add("  the capacity each medium is fitted to is %d B and is a parameter"
        % report["capacity"])
    add("  (--capacity); a part whose contents exceeded it is refused, not written.")
    add("  a CraftOS floppy is %d B." % FLOPPY)
    add("")
    add("EVERY PART IS ONE MEDIUM")
    add("  Copy the CONTENTS of each part directory to the ROOT of its own medium,")
    add("  so that each root carries %s and a %s/ directory." % (FONT_MARKER, FONTS_DIR))
    add("  The parts are not interchangeable and are not copies of one another:")
    add("  each carries its own shards and its own index, and the index names only")
    add("  the shards that are on it.")
    add("")
    add("HOW TO MOUNT THEM (CraftOS-PC, one --mount-rw per part)")
    for part in report["parts"]:
        add("    --mount-rw \"/disk%d=%s\"" % (part["part"] + 1, part["directory"]))
    add("")
    add("  On a real machine, insert every medium. lib/cc_fonts.lua finds them by")
    add("  the marker, reads each one's %s%s to learn which part it is, and unions"
        % (report["base"], MANIFEST_SUFFIX))
    add("  the indexes. A character that lives on a part that is NOT inserted is")
    add("  reported as being on that part -- \"set %s part 1 of %d, part 2 not"
        % (report["base"], report["disks"]))
    add("  inserted\" -- rather than drawn as a box or as nothing.")
    add("")
    add("A PROBE CHARACTER ON EACH PART")
    for part in report["parts"]:
        add("  part %d carries U+%04X (its first plain ideograph, ink %d pixel(s))"
            % (part["part"], part["sample"], part["sample_ink"]))
    add("")
    return "\n".join(out)


def plan_split(ids, shard_bytes, entry_bytes, capacity, disks=None):
    """Deal the shards out over the fewest media that can hold them.

    A SHARD IS INDIVISIBLE (the loader opens one shard file whole), so the split
    is a partition of the shard list into contiguous groups. The groups are made
    as even as whole shards allow, because an even split is what keeps a two
    medium set from being 12 shards on one disk and 2 on the other.
    """

    def payload(group):
        return (sum(shard_bytes[s] for s in group) +
                sum(entry_bytes[s] for s in group))

    def weight(group):
        return payload(group) + INDEX_HEADER_RESERVE + PART_OVERHEAD_RESERVE

    for sid in ids:
        if weight([sid]) > capacity:
            # No number of media fixes this: the unit is too big for a medium.
            fail("shard %d needs %d B and a medium holds %d B, so no split of "
                 "this set can fit. Regenerate the glyphs with a smaller "
                 "--shard-size (tools/fontgen.py) or raise --capacity."
                 % (sid, weight([sid]), capacity))

    wanted = int(disks) if disks else None
    if wanted is not None and wanted < 1:
        fail("--disks must be at least 1")
    if wanted is not None and wanted > len(ids):
        fail("--disks %d is more than the %d shard(s) in this set; a medium with "
             "no shard on it would be a copy of nothing"
             % (wanted, len(ids)))

    count = wanted or 1
    while True:
        parts = split_even(ids, payload, count)
        if len(parts) == count and all(weight(p) <= capacity for p in parts):
            return parts
        if wanted:
            fail("the set does not fit %d medium/media of %d B: the parts would "
                 "be %s B. Pass --disks with more media, or a larger --capacity."
                 % (count, capacity, ", ".join(str(weight(p)) for p in parts)))
        count += 1
        if count > len(ids):
            fail("the set cannot be split to fit %d B per medium" % capacity)


def split_even(ids, payload, count):
    """`count` contiguous groups of `ids`, as even by payload as whole shards allow.

    THE SMALLEST POSSIBLE LARGEST GROUP, found by binary search, and not "cut when
    the running total passes a share". The share rule looks right and is wrong
    whenever a group costs something fixed besides its shards: with a small set
    the first shard alone can pass half the target, and the answer is one shard on
    one medium and the rest on the other -- an even split is the whole point of
    asking for N media. Binary search on the payload bound, with a greedy pack
    that is optimal for this shape, gives the minimum possible maximum group.

    Deterministic by construction: the same set and the same capacity always cut
    at the same shard, so two runs of this tool produce media that can be mixed
    without a rebuild.
    """
    if count <= 1:
        return [list(ids)]

    def needed(bound):
        groups, current = 1, []
        for sid in ids:
            if current and payload(current + [sid]) > bound:
                groups += 1
                current = [sid]
            else:
                current = current + [sid]
        return groups

    low = max(payload([sid]) for sid in ids)
    high = payload(list(ids))
    while low < high:
        middle = (low + high) // 2
        if needed(middle) <= count:
            high = middle
        else:
            low = middle + 1

    parts, current = [], []
    for sid in ids:
        if current and payload(current + [sid]) > low:
            parts.append(current)
            current = [sid]
        else:
            current = current + [sid]
    if current:
        parts.append(current)

    # The greedy can end with fewer groups than asked for when a group cannot be
    # made smaller (one shard is indivisible). A caller that asked for N media
    # gets N back, and if the extra groups break the capacity the check in
    # plan_split says so loudly rather than the split quietly answering a
    # different question.
    while len(parts) < count and len(parts) < len(ids):
        big = max(range(len(parts)), key=lambda i: len(parts[i]))
        moved = parts[big].pop()
        parts.insert(big + 1, [moved])
    return parts


def assemble(out, force, with_store, capacity, spec):
    """Write ONE medium from `spec`, verify it, and return its report.

    Everything that decides whether a medium is usable is checked here, because
    each of them is a way the medium looks finished and is not: a shard that did
    not come across, a marker in the wrong place, an index naming a shard that is
    not beside it, a manifest that disagrees with the index, a set that does not
    fit. The size is MEASURED from the finished tree, and a medium that does not
    fit its capacity is refused and removed rather than written.
    """
    check_replaceable(out, force)
    staged = out + ".staged"
    shutil.rmtree(staged, ignore_errors=True)
    fonts_dir = os.path.join(staged, FONTS_DIR)
    os.makedirs(fonts_dir, exist_ok=True)

    write_text(os.path.join(fonts_dir, spec["index_file"]), spec["index_text"])
    for item in spec["shard_items"]:
        shutil.copy2(item["path"], os.path.join(fonts_dir, item["file"]))
    write_text(os.path.join(fonts_dir, spec["manifest_file"]), spec["manifest_text"])

    write_text(os.path.join(staged, FONT_MARKER), marker_text(with_store, spec))
    if with_store:
        write_text(os.path.join(staged, STORE_MARKER),
                   "an ordinary ush package store (NOT the system module store).\n"
                   "This marker is here so the package that renders with this\n"
                   "medium's glyphs can be installed: it declares\n"
                   "requires_disk=%s, and lib/pkg.lua looks for that marker only\n"
                   "on media it already counts as package stores.\n" % FONT_MARKER)

    # ------------------------------------------------------------- verification
    checks = []

    def check(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return bool(ok)

    on_medium = sorted(os.listdir(fonts_dir))
    expected = set([spec["index_file"], spec["manifest_file"]] +
                   [item["file"] for item in spec["shard_items"]])
    missing_files = sorted(expected - set(on_medium))
    extra_files = sorted(set(on_medium) - expected)
    check("the medium carries every file of the set", not missing_files,
          "missing: " + ", ".join(missing_files) if missing_files
          else "%d file(s)" % len(expected))
    check("and carries nothing else in %s/" % FONTS_DIR, not extra_files,
          "unexpected: " + ", ".join(extra_files) if extra_files else "no extras")
    check("the font marker is at the medium's ROOT",
          os.path.isfile(os.path.join(staged, FONT_MARKER)), FONT_MARKER)
    check("the shards are in %s/, where the runtime looks for them" % FONTS_DIR,
          os.path.isfile(os.path.join(fonts_dir, spec["index_file"])),
          os.path.join(FONTS_DIR, spec["index_file"]))
    if with_store:
        check("the store marker is %s and NOT .pkgsys" % STORE_MARKER,
              os.path.isfile(os.path.join(staged, STORE_MARKER)) and
              not os.path.isfile(os.path.join(staged, ".pkgsys")),
              "%s; .pkgsys would claim these glyphs are the shell's own modules"
              % STORE_MARKER)
    else:
        check("no store marker was written (--no-store)", True,
              "run 'pkg store <n>' on the machine before an install that needs "
              "the font")

    # The index has to name the shards that are on the medium, which is the one
    # property no size report can see: a stale index sending lookups to a file
    # this generation did not write draws nothing and raises nothing. With a set
    # split over media it is also the property that makes a part a PART: an index
    # that named a shard on another medium would send a lookup to a file that is
    # not there.
    named = index_entries(os.path.join(fonts_dir, spec["index_file"]))
    base = spec["base"]
    present = set()
    for name in on_medium:
        sid = shard_id_of(name, base)
        if sid is not None:
            present.add(sid)
    absent = [sid for sid in named if sid.isdigit() and int(sid) not in present]
    extra = sorted(present - set(int(sid) for sid in named if sid.isdigit()))
    check("every shard the index names is on the medium", not absent,
          "missing shard(s): " + ", ".join(sorted(set(absent))) if absent
          else "%d id(s) named, %d present" % (len(named), len(present)))
    check("no shard on the medium is one the index never names", not extra,
          "unused shard(s): " + ", ".join(str(s) for s in extra) if extra
          else "%d shard(s)" % len(present))
    check("the index names at least one glyph", len(named) > 0,
          "%d glyph(s)" % len(named))

    # The manifest is what the loader believes about which part this is, so it has
    # to agree with the index beside it: same set name as the index's file stem,
    # and the same shard ids as the files that are really here.
    with open(os.path.join(fonts_dir, spec["manifest_file"]),
              "r", encoding="ascii") as fh:
        manifest_text_value = fh.read()
    fields = manifest_fields(manifest_text_value)
    check("the manifest says which set and which part this is",
          fields is not None and fields["name"] == base and
          fields["part"] == spec["part"] and fields["parts"] == spec["parts"],
          "%s (%d of %d expected)" % (fields, spec["part"], spec["parts"])
          if fields else "the manifest could not be read")
    check("and the shard ids in it are the shards in %s/" % FONTS_DIR,
          fields is not None and
          set(str(s) for s in spec["shard_ids"]) == set(str(s) for s in present),
          "manifest %s vs present %s"
          % (sorted(str(s) for s in spec["shard_ids"]), sorted(str(s) for s in present)))

    # ASCII with LF endings, because the ROM's loadstring() reads these files and
    # a byte above 127 in a Lua string literal is either a syntax error or a
    # wrong glyph, while a CR ends up inside the first line.
    non_ascii = []
    for name in on_medium:
        with open(os.path.join(fonts_dir, name), "rb") as fh:
            data = fh.read()
        if any(byte > 127 for byte in data):
            non_ascii.append(name)
        elif b"\r" in data:
            non_ascii.append(name + " (CR)")
    check("every glyph file is ASCII with LF endings", not non_ascii,
          ", ".join(non_ascii) if non_ascii else "%d file(s) checked" % len(on_medium))

    # ---------------------------------------------------------------- the report
    per_shard = []
    for item in spec["shard_items"]:
        sid = shard_id_of(item["file"], base)
        per_shard.append({"file": item["file"], "shard": sid,
                          "bytes": os.path.getsize(os.path.join(fonts_dir, item["file"])),
                          "glyphs": len([n for n in named if n == str(sid)])})

    report = {
        "tool": "tools/fontdisk.py",
        "mode": "medium",
        "ok": all(c["ok"] for c in checks),
        "out": out,
        "data": spec.get("data"),
        "marker": FONT_MARKER,
        "store_marker": STORE_MARKER if with_store else None,
        "fonts_dir": FONTS_DIR,
        "base": base,
        "set": base,
        "part": spec["part"],
        "parts": spec["parts"],
        "shard_ids": spec["shard_ids"],
        "generated_from": index_header(os.path.join(fonts_dir, spec["index_file"])),
        "glyphs": len(named),
        "set_glyphs": spec["set_glyphs"],
        "shards": per_shard,
        "index": {"file": spec["index_file"],
                  "bytes": os.path.getsize(os.path.join(fonts_dir, spec["index_file"])),
                  "entries": len(named)},
        "manifest": {"file": spec["manifest_file"],
                     "bytes": os.path.getsize(os.path.join(fonts_dir, spec["manifest_file"])),
                     "name": fields["name"] if fields else None,
                     "part": fields["part"] if fields else None,
                     "parts": fields["parts"] if fields else None,
                     "glyphs": fields["glyphs"] if fields else None},
        "capacity": capacity,
        "floppy": FLOPPY,
        "checks": checks,
        "bytes": 0, "files": 0, "percent": 0.0, "spare": capacity,
    }

    # The notes are part of the medium's size, so they are written first and the
    # totals are measured from the finished tree. A report that left its own
    # README out of the total would be describing a medium that does not exist.
    write_text(os.path.join(staged, NOTES), notes_text(report))
    report["bytes"], report["files"] = tree_measure(staged)
    report["percent"] = round(report["bytes"] * 100.0 / capacity, 1)
    report["spare"] = capacity - report["bytes"]

    # THE REFUSAL. A medium whose contents exceed the capacity it is being fitted
    # to is not written at all: it is the one failure an operator cannot see on a
    # finished-looking disk, and "it was written and the tool said 103%" is not a
    # refusal. The staged tree is removed so nothing half-true is left behind.
    if report["bytes"] > capacity:
        shutil.rmtree(staged, ignore_errors=True)
        fail("the medium does not fit: %d B of glyphs, index, manifest and notes "
             "against a capacity of %d B (%d B over). Raise --capacity, or pass "
             "the set to --set-out so that it is split over several media."
             % (report["bytes"], capacity, report["bytes"] - capacity))
    check("the medium fits the %d B capacity it was fitted to" % capacity,
          True, "%d B of %d B (%d B spare)" % (report["bytes"], capacity,
                                               report["spare"]))
    report["ok"] = all(c["ok"] for c in checks)

    if os.path.isdir(out):
        shutil.rmtree(out)
    shutil.move(staged, out)
    return report


def build(out, source, force, with_store, capacity=None):
    """Build ONE medium carrying the whole of the set in --data.

    This is the mode for a set that fits a medium -- the shipped 5400 glyph set
    does, at 1,093,371 B of a 1,228,800 B floppy. For the whole standard, which
    does not, see build_set().
    """
    capacity = FLOPPY if capacity is None else int(capacity)
    out = os.path.abspath(out)
    source = os.path.abspath(source)
    check_own_tree(out, source)

    index, shards = collect(source)
    base = index["file"][:-len(INDEX_SUFFIX)]
    header, shape, entries = read_index(index["path"])
    ids = sorted(set(sid for _cp, sid in entries))

    by_id = {}
    for item in shards:
        sid = shard_id_of(item["file"], base)
        if sid is None:
            fail("%s is not a shard file of the set %s" % (item["file"], base))
        by_id[sid] = item
    unknown = sorted(set(ids) - set(by_id))
    if unknown:
        fail("the index of %s names shard(s) %s that are not in %s"
             % (base, ", ".join(str(s) for s in unknown), source))

    plan = [{"part": 1, "shards": ids, "glyphs": len(entries),
             "first": min(cp for cp, _s in entries),
             "last": max(cp for cp, _s in entries)}]
    spec = spec_for_part(base, header, shape, entries, by_id, plan, 1, 1, source)
    return assemble(out, force, with_store, capacity, spec)


def spec_for_part(base, header, shape, entries, by_id, plan, part, parts, source):
    """The files, the index text and the manifest for one part of a set."""
    entry = plan[part - 1]
    chosen = [sid for sid in entry["shards"]]
    mine = [(cp, sid) for cp, sid in entries if sid in chosen]
    return {
        "base": base,
        "part": part,
        "parts": parts,
        "set_glyphs": len(entries),
        "shard_ids": chosen,
        "shard_items": [by_id[sid] for sid in chosen],
        "index_file": base + INDEX_SUFFIX,
        "index_text": part_index_source(header, shape, base, part, parts, mine,
                                        len(entries), chosen),
        "manifest_file": base + MANIFEST_SUFFIX,
        "manifest_text": manifest_source(base, part, parts, len(mine), chosen,
                                         plan, header),
        "data": source,
    }


def build_set(set_out, source, force, with_store, capacity=None, disks=None):
    """Build EVERY medium of a set, one directory per part, in one command.

    Returns a report with the per-medium and the total arithmetic, a probe
    character on each part, and the checks that the parts really are a partition
    of the set: every shard on exactly one medium, every glyph on exactly one
    medium, and no medium over its capacity.
    """
    capacity = FLOPPY if capacity is None else int(capacity)
    set_out = os.path.abspath(set_out)
    source = os.path.abspath(source)
    check_own_tree(set_out, source)
    check_replaceable(set_out, force, fingerprint=SET_NOTES)

    index, shards = collect(source)
    base = index["file"][:-len(INDEX_SUFFIX)]
    header, shape, entries = read_index(index["path"])
    ids = sorted(set(sid for _cp, sid in entries))

    by_id = {}
    for item in shards:
        sid = shard_id_of(item["file"], base)
        if sid is None:
            fail("%s is not a shard file of the set %s" % (item["file"], base))
        by_id[sid] = item
    unknown = sorted(set(ids) - set(by_id))
    if unknown:
        fail("the index of %s names shard(s) %s that are not in %s"
             % (base, ", ".join(str(s) for s in unknown), source))

    shard_bytes = dict((sid, by_id[sid]["bytes"]) for sid in ids)
    entry_bytes = {}
    for _cp, sid in entries:
        # The exact cost of this shard's rows in the index text, so that the
        # split is planned from the bytes that will really be written.
        entry_bytes[sid] = entry_bytes.get(sid, 0) + len("[%d]=%d,\n" % (_cp, sid))

    groups = plan_split(ids, shard_bytes, entry_bytes, capacity, disks)
    parts = len(groups)
    plan = []
    for number, group in enumerate(groups, 1):
        mine = [(cp, sid) for cp, sid in entries if sid in group]
        plan.append({"part": number, "shards": list(group), "glyphs": len(mine),
                     "first": mine[0][0], "last": mine[-1][0]})

    reports = []
    for number, group in enumerate(groups, 1):
        out = os.path.join(set_out, PART_DIR % number)
        spec = spec_for_part(base, header, shape, entries, by_id, plan, number,
                             parts, source)
        report = assemble(out, force, with_store, capacity, spec)
        report["directory"] = out
        report["sample"], report["sample_ink"] = probe_sample(entries, group, by_id,
                                                              spec["index_text"])
        reports.append(report)

    total = sum(report["bytes"] for report in reports)
    checks = []

    def check(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return bool(ok)

    # THE PARTS HAVE TO BE A PARTITION. Two media with the same shard are wasted
    # room and a codepoint drawn from whichever index answered first; a shard on
    # no medium is a set of glyphs nothing can draw and nothing reports.
    seen = {}
    for report in reports:
        for sid in report["shard_ids"]:
            seen.setdefault(sid, []).append(report["part"])
    twice = sorted(sid for sid, where in seen.items() if len(where) > 1)
    never = sorted(set(ids) - set(seen))
    check("every shard of the set is on exactly one medium", not twice and not never,
          ("shard(s) on two media: " + ", ".join(str(s) for s in twice))
          if twice else
          ("shard(s) on no medium: " + ", ".join(str(s) for s in never))
          if never else "%d shard(s) over %d medium/media" % (len(ids), parts))
    glyphs = sum(report["glyphs"] for report in reports)
    check("every glyph of the set is on exactly one medium", glyphs == len(entries),
          "%d glyph(s) over the parts vs %d in the set" % (glyphs, len(entries)))
    check("every medium fits the capacity it was fitted to",
          all(report["spare"] >= 0 for report in reports),
          ", ".join("part%d %d/%d" % (r["part"], r["bytes"], capacity)
                    for r in reports))
    check("every medium carries only its own shards",
          all(set(report["shard_ids"]) ==
              set(int(n) for n in index_entries(
                  os.path.join(report["out"], FONTS_DIR, report["index"]["file"])))
              for report in reports),
          "; ".join("part%d: %s" % (r["part"], ",".join(str(s) for s in r["shard_ids"]))
                    for r in reports))

    # A part left over from a previous build with more media would sit beside the
    # new ones and look like part of the set.
    leftovers = []
    number = len(reports) + 1
    while True:
        stale = os.path.join(set_out, PART_DIR % number)
        if not os.path.isdir(stale):
            break
        if not (force or os.path.exists(os.path.join(stale, FONT_MARKER))):
            fail("%s is left over from an earlier build and is not ours; move it "
                 "away or pass --force" % stale)
        shutil.rmtree(stale)
        leftovers.append(stale)
        number += 1

    report = {
        "tool": "tools/fontdisk.py",
        "mode": "set",
        "ok": all(c["ok"] for c in checks) and all(r["ok"] for r in reports),
        "set_out": set_out,
        "data": source,
        "base": base,
        "set": base,
        "disks": parts,
        "capacity": capacity,
        "floppy": FLOPPY,
        "glyphs": len(entries),
        "shards": len(ids),
        "parts": [{"part": r["part"], "out": r["out"], "directory": r["directory"],
                   "bytes": r["bytes"], "percent": r["percent"], "spare": r["spare"],
                   "glyphs": r["glyphs"], "shards": r["shard_ids"],
                   "first": plan[r["part"] - 1]["first"],
                   "last": plan[r["part"] - 1]["last"],
                   "sample": r["sample"], "sample_ink": r["sample_ink"],
                   "files": r["files"]} for r in reports],
        "plan": plan,
        "bytes": total,
        "percent": round(total * 100.0 / (capacity * parts), 1),
        "spare": capacity * parts - total,
        "removed": leftovers,
        "checks": checks,
        "mediums": reports,
    }
    write_text(os.path.join(set_out, SET_NOTES), set_notes_text(report))
    # The set directory's own README is not copied to any medium, so it is NOT
    # part of the total an operator carries: the total is the sum of the media.
    # What the whole directory measures is reported separately, because it is what
    # the build wrote.
    report["set_bytes"], report["set_files"] = tree_measure(set_out)
    report["ok"] = report["ok"] and all(c["ok"] for c in checks)
    return report


def probe_sample(entries, group, by_id, index_text):
    """One codepoint on this part that a probe can draw: its first real ideograph.

    U+4E00 and above is CJK, which is what the whole design is for; the
    punctuation at U+00B7..U+300F sorts before it and would make a poor probe
    character. The ink count is measured from the shard on disk, so the number in
    the report and the number the probe asserts on come from the same bytes.
    """
    mine = [(cp, sid) for cp, sid in entries if sid in group]
    chosen = None
    for cp, _sid in mine:
        if cp >= 0x4E00:
            chosen = cp
            break
    if chosen is None and mine:
        chosen = mine[0][0]
    if chosen is None:
        return None, 0
    sid = None
    for cp, s in mine:
        if cp == chosen:
            sid = s
            break
    ink = 0
    path = by_id[sid]["path"]
    with open(path, "r", encoding="ascii") as fh:
        for line in fh:
            if line.startswith("[%d]=" % chosen):
                # The lit pixels are counted inside the ROW STRINGS only: the
                # codepoint's own digits sit on the same line, and "[19968]" would
                # otherwise contribute a "1" to every glyph whose codepoint has
                # one in it -- an 11 where the glyph has 10.
                for row in re.findall(r'"([01]+)"', line):
                    ink += row.count("1")
                break
    return chosen, ink


def print_report(report):
    print("fontdisk: %s" % report["out"])
    print("  %-16s the font medium marker (at the root)" % report["marker"])
    if report["store_marker"]:
        print("  %-16s an ordinary package store, so an install can find it"
              % report["store_marker"])
    if report["generated_from"]:
        print("  glyphs: %s" % report["generated_from"])
    if report["parts"] > 1:
        print("  %-16s part %d of %d, shard(s) %s"
              % ("set " + report["base"], report["part"], report["parts"],
                 ", ".join(str(s) for s in report["shard_ids"])))
    print("  %-16s %d glyph(s) in %d file(s)"
          % (report["fonts_dir"] + "/", report["glyphs"],
             len(report["shards"]) + 2))
    for shard in report["shards"]:
        print("    %-24s %9d B  %5d glyph(s)" % (shard["file"], shard["bytes"],
                                                 shard["glyphs"]))
    print("    %-24s %9d B  %5d entr(y|ies)" % (report["index"]["file"],
                                                report["index"]["bytes"],
                                                report["index"]["entries"]))
    print("    %-24s %9d B  %5d glyph(s)" % (report["manifest"]["file"],
                                             report["manifest"]["bytes"],
                                             report["manifest"]["glyphs"]))
    print("  total %9d B in %d file(s) = %.1f%% of the %d B capacity (%d B spare)"
          % (report["bytes"], report["files"], report["percent"],
             report["capacity"], report["spare"]))
    print("  checks:")
    for item in report["checks"]:
        print("    %-4s %-52s %s" % ("ok" if item["ok"] else "FAIL",
                                     item["name"], item["detail"]))
    print("  copy the CONTENTS of %s to the ROOT of the medium; mount it with"
          % report["out"])
    print("    CraftOS-PC_console.exe --mount-rw \"/disk2=%s\"" % report["out"])


def print_set_report(report):
    print("fontdisk: %s" % report["set_out"])
    print("  set %s: %d glyph(s) in %d shard(s) over %d medium/media, each fitted"
          % (report["base"], report["glyphs"], report["shards"], report["disks"]))
    print("  to a capacity of %d B (a CraftOS floppy is %d B)" % (report["capacity"],
                                                                  FLOPPY))
    print("  %-8s %-28s %9s %7s %8s  %s"
          % ("part", "directory", "bytes", "glyphs", "spare", "shards"))
    for part in report["parts"]:
        print("  %-8s %-28s %9d %7d %8d  %s"
              % ("part%d" % part["part"], part["directory"], part["bytes"],
                 part["glyphs"], part["spare"],
                 ",".join(str(s) for s in part["shards"])))
    print("  %-8s %-28s %9d %7d %8d" % ("TOTAL", "", report["bytes"],
                                        report["glyphs"], report["spare"]))
    print("  the whole set is %.1f%% of the %d B the %d media hold together"
          % (report["percent"], report["capacity"] * report["disks"], report["disks"]))
    print("  probe characters (one per medium, for an acceptance run):")
    for part in report["parts"]:
        print("    part %d  U+%04X  ink %d pixel(s)  %s"
              % (part["part"], part["sample"], part["sample_ink"], part["out"]))
    if report["removed"]:
        for stale in report["removed"]:
            print("  removed a left-over part directory from an earlier build: %s"
                  % stale)
    print("  checks:")
    for item in report["checks"]:
        print("    %-4s %-52s %s" % ("ok" if item["ok"] else "FAIL",
                                     item["name"], item["detail"]))
    print("  mount every part, one --mount-rw each:")
    for part in report["parts"]:
        print("    CraftOS-PC_console.exe --mount-rw \"/disk%d=%s\""
              % (part["part"] + 1, part["directory"]))


def main(argv):
    ap = argparse.ArgumentParser(
        description="build the removable medium (or media) that carry the CJK glyphs")
    ap.add_argument("--out",
                    help="directory to build ONE medium in: one command, one medium")
    ap.add_argument("--set-out",
                    help="directory to build EVERY medium of a set in: one "
                         "subdirectory per part, plus FONTSET.txt")
    ap.add_argument("--disks", type=int, default=None,
                    help="how many media the set must fit (--set-out only; "
                         "default: as many as it needs). A set that does not fit "
                         "the number asked for is refused, not squeezed")
    ap.add_argument("--capacity", type=int, default=FLOPPY,
                    help="bytes one medium holds, which a medium's contents may "
                         "not exceed (default: %d, a CraftOS floppy). A medium "
                         "over its capacity is refused, not written" % FLOPPY)
    ap.add_argument("--data", default=os.path.join(REPO, "fontdata"),
                    help="the glyph files tools/fontgen.py wrote (default: %(default)s)")
    ap.add_argument("--force", action="store_true",
                    help="replace a directory this tool did not write")
    ap.add_argument("--no-store", action="store_true", dest="no_store",
                    help="do not write .pkgstore: build the plain font medium, "
                         "which then needs 'pkg store <n>' on the machine")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="print a machine readable report instead of the summary")
    args = ap.parse_args(argv)

    if bool(args.out) == bool(args.set_out):
        print("fontdisk: pass exactly one of --out (one medium) and --set-out "
              "(every medium of a set)")
        return 1
    if args.capacity < 1:
        print("fontdisk: --capacity must be at least 1 byte")
        return 1
    try:
        if args.set_out:
            report = build_set(args.set_out, args.data, args.force,
                               not args.no_store, args.capacity, args.disks)
        else:
            if args.disks is not None:
                fail("--disks is a --set-out option: --out builds one medium")
            report = build(args.out, args.data, args.force, not args.no_store,
                           args.capacity)
    except FontdiskError as exc:
        if args.as_json:
            print(json.dumps({"tool": "tools/fontdisk.py", "ok": False,
                              "error": str(exc)}, indent=1, sort_keys=True))
        else:
            print("fontdisk: %s" % exc)
        return 1
    if args.as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
    else:
        if report["mode"] == "set":
            print_set_report(report)
        else:
            print_report(report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
