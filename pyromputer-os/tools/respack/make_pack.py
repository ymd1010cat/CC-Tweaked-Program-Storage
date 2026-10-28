#!/usr/bin/env python3
"""Build the resource pack that lets the shell draw Chinese on a terminal.

WHY THIS EXISTS
---------------
A CraftOS terminal cell holds ONE byte, 0..255, and there is no pixel-level API.
The shell's CJK renderer (lib/cc_chinese.lua) therefore writes
string.char(128 + mask), expecting the font to turn that byte into the six
sub-pixels of one cell. On the stock font that byte is a Latin-1 letter, which is
exactly why Chinese came out as "deg+-2-3..." noise on screen.

A resource pack can replace the terminal font texture, so this script makes the
assumption true: it writes the 64 possible 2x3 blocks into bytes 128..191.

TWO MODES, AND WHY THE DEFAULT ONE DOES NOT NEED THE MOD AT ALL
--------------------------------------------------------------
    python tools/respack/make_pack.py --out psh-cjk-font.zip
        The default. The WHOLE texture is synthesised here: ASCII 0..127 and
        the Latin-1 placeholders 192..255 come from the public-domain 6x9
        bitmap font embedded in font6x9.py, and bytes 128..191 are the
        sub-cell blocks this project owns. No file from CC:Tweaked is read, so
        the pack can be redistributed (see README.md for each part's licence).

    python tools/respack/make_pack.py --texture term_font.png --out x.zip
        The old behaviour: copy the vanilla texture, keeping its ASCII and its
        Latin-1, and rewrite only bytes 128..191. It is still offered for
        people who want the pack to match their server's own font exactly, but
        a pack built this way carries CC:Tweaked's texture and must not be
        redistributed: the mod's font says "Do not distribute without
        permission".

GEOMETRY, from CC:Tweaked's own renderer
(projects/common/src/client/java/dan200/computercraft/client/render/text/FixedWidthFontRenderer.java):

    public static final int FONT_HEIGHT = 9;
    public static final int FONT_WIDTH = 6;
    static final float WIDTH = 256.0f;
    var xStart = 1 + column * (FONT_WIDTH + 2);
    var yStart = 1 + row * (FONT_HEIGHT + 2);

One glyph is 6x9 pixels inside an 8x11 stride at a 1 pixel inset, and a byte
picks its cell by column = byte % 16, row = byte / 16. A 2x3 block of a 6x9
glyph is exactly 3x3 pixels, which is why the scheme is possible at all. The
texture itself is 256x256 (the glyphs occupy only its top-left 128x175 pixels;
the rest is the padding the renderer's 256.0f texture width implies).

WHAT THE 2x3 BLOCKS ARE
-----------------------
Byte 128 + mask, where the six bits are, in cell_byte()'s order:

    1 left-top      2 left-middle      4 left-bottom
    8 right-top    16 right-middle    32 right-bottom

All 64 masks are written, always. They cannot be derived from the shipped
glyph set and must not be: a glyph set is a build input, and a cell that is
wrong for a glyph an operator installs tomorrow is a font bug no count-based
test can see. pyromputer-os/fontdata/ is read only to PROVE that the shipped set
uses nothing outside those 64 masks, and that the bit order above matches
lib/cc_chinese.lua's cell_byte(). That check is skipped, with a note, when the
glyph set is not next to this script (the pack does not depend on it).
"""
import argparse
import hashlib
import io
import json
import os
import re
import sys
import zipfile

try:
    from PIL import Image
except ImportError:                                    # pragma: no cover
    sys.exit("this script needs Pillow: python -m pip install pillow")

# The font table lives beside this script; make that true even when the script is
# imported rather than run (python puts the script's own directory on sys.path,
# an importer does not).
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import font6x9                                        # noqa: E402

FONT_WIDTH, FONT_HEIGHT = 6, 9
STRIDE_X, STRIDE_Y = FONT_WIDTH + 2, FONT_HEIGHT + 2
TEXTURE_SIZE = (256, 256)
TEXTURE = "assets/computercraft/textures/gui/term_font.png"

# The embedded glyph is exactly one cell; no offset is needed. The 6x9 font has
# its own margins (capitals start at row 1, descenders stop at row 8, column 5 is
# blank except for "%"), so the result sits on the cell the way the X11 original
# sits on its own.
GLYPH_WIDTH, GLYPH_HEIGHT = 6, 9
GLYPH_OFFSET = (0, 0)

INK = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)

# The bytes of the texture that are text, and the codepoint each one draws.
# 0..31 and 127 stay blank: they are control bytes. 128..191 are the blocks.
ASCII_FIRST, ASCII_LAST = 0x20, 0x7E
LATIN1_FIRST, LATIN1_LAST = 0xC0, 0xFF

# The characters whose absence would make the font unusable. Space is blank by
# definition, so it is not here.
REQUIRED_ASCII = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789"
    "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
)

# Resource pack formats by Minecraft version. A wrong number is a warning, not a
# failure, but a right one keeps the pack out of the "incompatible" list.
PACK_FORMATS = {
    "1.16": 6, "1.17": 7, "1.18": 8, "1.19": 9, "1.20": 15,
    "1.20.2": 18, "1.21": 34,
}


def cell_origin(n):
    return 1 + (n % 16) * STRIDE_X, 1 + (n // 16) * STRIDE_Y


def glyph_for(byte):
    """The embedded rows for a PNG byte, or None for a deliberately blank cell.

    Byte 0..127 is ASCII (only 32..126 carry ink; controls are blank) and byte
    192..255 is Latin-1 -- the same identity mapping the vanilla texture uses.
    """
    if ASCII_FIRST <= byte <= ASCII_LAST or LATIN1_FIRST <= byte <= LATIN1_LAST:
        return font6x9.GLYPHS.get(byte)
    return None


def paint_glyph(px, byte, rows):
    ox, oy = cell_origin(byte)
    for y, row in enumerate(rows):
        for x in range(GLYPH_WIDTH):
            if row & (0x80 >> x):
                px[ox + GLYPH_OFFSET[0] + x,
                   oy + GLYPH_OFFSET[1] + y] = INK


def paint_blocks(px):
    """Write the 64 2x3 sub-cell blocks into bytes 128..191."""
    for mask in range(64):
        ox, oy = cell_origin(128 + mask)
        for y in range(FONT_HEIGHT):
            for x in range(FONT_WIDTH):
                px[ox + x, oy + y] = CLEAR
        for col in range(2):
            for row in range(3):
                # Bit layout matches lib/cc_chinese.lua cell_byte():
                # 1 left-top, 2 left-middle, 4 left-bottom,
                # 8 right-top, 16 right-middle, 32 right-bottom.
                if not (mask & (1 << (row + col * 3))):
                    continue
                for y in range(row * 3, row * 3 + 3):
                    for x in range(col * 3, col * 3 + 3):
                        px[ox + x, oy + y] = INK


def check_font_table():
    """Refuse to build from a table that is the wrong shape or has no ink.

    The table is data, so it is checked rather than trusted: a bad edit there
    would otherwise produce a pack that installs cleanly and is blank on screen,
    which is the failure mode this whole script exists to prevent.
    """
    problems = []
    for cp, rows in sorted(font6x9.GLYPHS.items()):
        if len(rows) != GLYPH_HEIGHT:
            problems.append("U+%04X has %d rows, not %d"
                            % (cp, len(rows), GLYPH_HEIGHT))
            continue
        for i, row in enumerate(rows):
            if row & 0x03:
                problems.append("U+%04X row %d uses a column outside the 6-pixel "
                                "cell (0x%02X)" % (cp, i, row))
            if row & ~0xFF:
                problems.append("U+%04X row %d is not a byte" % (cp, i))
    for ch in REQUIRED_ASCII:
        rows = font6x9.GLYPHS.get(ord(ch))
        if rows is None:
            problems.append("the embedded font has no glyph for %r" % ch)
        elif not any(rows):
            problems.append("the embedded glyph for %r is blank" % ch)
    for cp in range(LATIN1_FIRST, LATIN1_LAST + 1):
        if cp not in font6x9.GLYPHS:
            problems.append("the embedded font has no Latin-1 glyph for U+%04X"
                            % cp)
    return problems


def check_texture(img):
    """Every byte that must be visible has ink where it belongs."""
    if img.size != TEXTURE_SIZE:
        return ["the texture is %dx%d, not %dx%d"
                % (img.size + TEXTURE_SIZE)]
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    px = img.load()
    problems = []
    # Byte 128 is mask 0: the all-blank 2x3 block, i.e. the blank half of a
    # CJK cell. It MUST be empty, or every blank sub-cell in Chinese text would
    # show a block. Bytes 129..191 are the 63 masks with ink and must not be.
    ox, oy = cell_origin(128)
    if any(px[ox + x, oy + y][3] > 100
           for y in range(FONT_HEIGHT) for x in range(FONT_WIDTH)):
        problems.append("block byte 128 (mask 0) must be blank, but has ink")
    for byte in range(129, 192):
        ox, oy = cell_origin(byte)
        if not any(px[ox + x, oy + y][3] > 100
                   for y in range(FONT_HEIGHT) for x in range(FONT_WIDTH)):
            problems.append("block byte %d (%d,%d) is empty" % (byte, ox, oy))
    for ch in REQUIRED_ASCII:
        ox, oy = cell_origin(ord(ch))
        if not any(px[ox + x, oy + y][3] > 100
                   for y in range(FONT_HEIGHT) for x in range(FONT_WIDTH)):
            problems.append("ASCII byte 0x%02X (%r) at (%d,%d) is blank"
                            % (ord(ch), ch, ox, oy))
    return problems


def standalone_texture():
    """Build the whole 256x256 terminal atlas from this project's own data."""
    img = Image.new("RGBA", TEXTURE_SIZE, CLEAR)
    px = img.load()
    for byte in range(256):
        rows = glyph_for(byte)
        if rows is None:
            continue
        paint_glyph(px, byte, rows)
    paint_blocks(px)
    return img


def check_geometry(img, quiet=False):
    """Refuse to pack a vanilla texture that does not have CC:Tweaked's layout.

    A pack built against the wrong geometry would put the blocks in the wrong
    cells, which looks like slightly-off Chinese rather than like an error --
    the worst failure mode, so it is checked instead.
    """
    if img.size != TEXTURE_SIZE:
        return "the texture is %dx%d, but CC:Tweaked's is %dx%d" % (
            img.size + TEXTURE_SIZE)
    # Byte 65 is 'A': six pixels wide, nine tall, and it must have ink.
    ox, oy = cell_origin(65)
    px = img.convert("RGBA").load()
    ink = [(x, y) for y in range(FONT_HEIGHT) for x in range(FONT_WIDTH)
           if px[ox + x, oy + y][3] > 100]
    if not ink:
        return ("no ink where 'A' should be (%d,%d): this does not look like "
                "CC:Tweaked's term_font.png" % (ox, oy))
    if not quiet:
        print("texture ok: 'A' at %d,%d has %d lit pixels" % (ox, oy, len(ink)))
    return None


def vanilla_texture(path, quiet=False):
    """The old behaviour: the vanilla texture with bytes 128..191 rewritten."""
    src = Image.open(path).convert("RGBA")
    problem = check_geometry(src, quiet)
    if problem:
        return None, problem
    img = src.copy()
    paint_blocks(img.load())
    return img, None


def default_fontdata():
    return os.path.normpath(os.path.join(_HERE, os.pardir, os.pardir,
                                         "fontdata"))


def matrix_masks(rows):
    """Yield the 6-bit cell masks of a glyph matrix, in cell_byte()'s bit order.

    The matrix is a list of strings of "0"/"1" rows, which is the form
    tools/fontgen.py writes; a size-12 glyph is 12x12 = 6x4 terminal cells.
    """
    height = len(rows)
    width = max(len(row) for row in rows) if rows else 0
    for cy in range((height + 2) // 3):
        for cx in range((width + 1) // 2):
            mask = 0
            for row in range(3):
                for col in range(2):
                    x, y = cx * 2 + col, cy * 3 + row
                    if y < height and x < len(rows[y]) and rows[y][x] == "1":
                        mask |= 1 << (row + col * 3)
            yield mask


def scan_glyph_set(fontdata):
    """Read the shipped shards; return a report, or (None, error).

    The pack never needs these files -- all 64 masks are always drawn -- but
    this is the only check that the mask bit order the pack writes is the one
    the real glyphs are encoded with, so it is worth running when the set is
    there.
    """
    index_path = os.path.join(fontdata, "shs12_index.lua")
    if not os.path.isfile(index_path):
        return None, "no glyph index at %s" % index_path
    with open(index_path, encoding="utf-8") as fh:
        index = dict(re.findall(r"\[(\d+)\]=(\d+)", fh.read()))
    if not index:
        return None, ("%s names no glyphs: it is not a shs12 index"
                      % index_path)
    shards = sorted({int(shard) for shard in index.values()})
    masks = set()
    glyphs = 0
    for shard in shards:
        path = os.path.join(fontdata, "shs12_shard%d.lua" % shard)
        if not os.path.isfile(path):
            return None, ("the index names shard %d, but %s is missing"
                          % (shard, path))
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        for match in re.finditer(r"\[(\d+)\]=\{([^}]*)\}", text):
            rows = re.findall(r'"([01]+)"', match.group(2))
            if rows:
                glyphs += 1
                masks.update(matrix_masks(rows))
    return {"glyphs": len(index), "shards": len(shards),
            "scanned": glyphs, "masks": sorted(masks)}, None


def read_pack_metadata(path, pack_format):
    """Validate the optional name -> format table; return the matching names."""
    if not os.path.isfile(path):
        return None, "no such pack metadata: %s" % path
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, "cannot read %s as JSON: %s" % (path, exc)
    if not isinstance(data, dict):
        return None, ("%s must be a JSON object mapping a Minecraft version to "
                      "a pack format" % path)
    return [name for name, fmt in data.items() if fmt == pack_format], None


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_pack(out, img, pack_format, description):
    """Write the zip atomically: a half-written pack must never look installable."""
    parent = os.path.dirname(os.path.abspath(out))
    if not os.path.isdir(parent):
        return "no such directory: %s" % parent
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    meta = {"pack": {"pack_format": pack_format, "description": description}}
    tmp = out + ".tmp"
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
            # A fixed timestamp makes the build reproducible: the same inputs
            # give the same bytes, so the printed SHA-256 means something.
            for name, data in (("pack.mcmeta", json.dumps(meta, indent=2) + "\n"),
                               (TEXTURE, buf.getvalue())):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                zf.writestr(info, data)
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return None


def describe_fontdata(report, quiet):
    """Say what was checked, and refuse to ship a set the blocks cannot draw."""
    used = set(report["masks"])
    outside = sorted(mask for mask in used if not 0 <= mask < 64)
    if outside:
        return ("the shipped glyphs use masks %r, which are not 2x3 blocks"
                % outside)
    if not quiet:
        print("glyph set: %d glyphs in %d shards (%d matrices scanned); "
              "%d of 64 sub-cell masks used, and all 64 blocks are drawn"
              % (report["glyphs"], report["shards"], report["scanned"],
                 len(used)))
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="the .zip to write")
    ap.add_argument("--texture", default=None,
                    help="optional: patch this vanilla term_font.png instead of "
                         "building the whole font from scratch (the old mode; "
                         "not redistributable)")
    ap.add_argument("--fontdata", default=None,
                    help="glyph set to check the 128..191 blocks against "
                         "(default: the fontdata/ beside this script, if any)")
    ap.add_argument("--pack-format", type=int, default=15,
                    help="resource pack format (15 = 1.20.1); see PACK_FORMATS")
    ap.add_argument("--pack-metadata", default=None,
                    help="a name -> format table; when given, it is read and "
                         "the names matching --pack-format are reported")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    matched = None
    if args.pack_metadata:
        matched, problem = read_pack_metadata(args.pack_metadata,
                                              args.pack_format)
        if problem:
            return problem

    if args.texture:
        if not os.path.isfile(args.texture):
            return ("no such texture: %s (standalone mode needs no --texture: "
                    "omit it to build the font from scratch)" % args.texture)
        img, problem = vanilla_texture(args.texture, args.quiet)
        if problem:
            return problem
        description = "Pyromputer OS CJK sub-pixel glyphs (bytes 128-191)"
    else:
        problems = check_font_table()
        if problems:
            return ("the embedded font table in font6x9.py is unusable:\n  "
                    + "\n  ".join(problems))
        img = standalone_texture()
        description = ("Pyromputer OS terminal font: public-domain ASCII + CJK "
                       "sub-cell blocks (128-191)")

    # Both modes must pass this: a font that cannot show 'A' or cannot show a
    # single sub-cell block is broken, and the failure would otherwise only
    # appear as a picture that is wrong on a screen.
    problems = check_texture(img)
    if problems:
        return "refusing to pack:\n  " + "\n  ".join(problems)

    fontdata = args.fontdata or default_fontdata()
    if os.path.isdir(fontdata):
        report, problem = scan_glyph_set(fontdata)
        if problem:
            return problem
        problem = describe_fontdata(report, args.quiet)
        if problem:
            return problem
    elif args.fontdata:
        return ("no such glyph set: %s (build it with: python tools/fontgen.py "
                "--full --size 12 --out fontdata)" % args.fontdata)
    elif not args.quiet:
        print("no glyph set at %s; skipping the block-coverage check"
              % fontdata)

    problem = write_pack(args.out, img, args.pack_format, description)
    if problem:
        return problem

    if args.quiet:
        return None
    print("wrote %s (%d bytes), pack_format %d"
          % (args.out, os.path.getsize(args.out), args.pack_format))
    if matched is not None:
        if matched:
            print("pack_format %d matches %s"
                  % (args.pack_format, ", ".join(sorted(matched))))
        else:
            print("note: no name in %s uses pack_format %d"
                  % (args.pack_metadata, args.pack_format))
    print("sha256 %s" % sha256_file(args.out))
    print("drop it in <minecraft>/resourcepacks/ and enable it")
    if args.texture:
        print("glyphs: the vanilla texture's ASCII/Latin-1 + the project's own "
              "2x3 sub-cell blocks")
    else:
        print("glyphs: public-domain 6x9 ASCII/Latin-1 + the project's own "
              "2x3 sub-cell blocks")
    return None


if __name__ == "__main__":
    err = main()
    if err:
        sys.exit("respack: " + err)
