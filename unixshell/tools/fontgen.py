"""fontgen.py - rasterise a TTF into the glyph files the runtime loads.

    python tools/fontgen.py --font "C:\\Windows\\Fonts\\NotoSansSC-VF.ttf" \
        --size 12 --out fontdata --json

WHAT IT PRODUCES, AND WHY THAT SHAPE
  The runtime (lib/cc_font_shards.lua) asks for two kinds of file, both plain
  Lua data that the CraftOS ROM's own loadstring() can evaluate:

      <base>_index.lua     { [codepoint] = shard_id }
      <base>_shard<N>.lua  { [codepoint] = matrix }

  A matrix is a list of strings of "0"/"1", one string per pixel ROW, so its
  height is #matrix and its width is #matrix[1]. lib/cc_chinese.lua renders a 2x3
  pixel block per character cell -- six pixels packed into one byte as
  string.char(128 + mask), mask 0 = blank, bit 0 = left-top, bit 1 = left-mid,
  bit 2 = left-bot, bit 3 = right-top, bit 4 = right-mid, bit 5 = right-bot. That
  layout is the whole reason the glyphs are stored as raw pixel rows instead of
  as packed bytes: the caller may render at any size, and the packing depends on
  the size.

WHY THE SHARDS EXIST AT ALL
  One file holding a CJK set would be read whole into memory by the runtime, and
  a machine that shows a Chinese menu would pay for every glyph it never draws.
  A shard of 500 glyphs at size 12 is about 105 KB, which is the unit the loader
  caches and evicts. The index is what makes a codepoint openable without reading
  every shard.

WHY THE OUTPUT IS ASCII AND WHY THE KEYS ARE NUMBERS
  The generator is a PC side tool, but its OUTPUT is loaded on the machine by the
  ROM's loadstring(), which knows nothing of \\u escapes. So a codepoint is
  written as a plain number key ([19968] or [0x4E2D]) and a row as a plain string
  of "0" and "1". The generated file is pure ASCII, which also keeps it inside
  this project's ASCII rule for anything a machine can receive.

WHY WINDOWS PATHS
  Python here is a Windows build: "C:\\Windows\\Fonts\\NotoSansSC-VF.ttf"
  resolves, "/c/Windows/Fonts/NotoSansSC-VF.ttf" does not (os.path.exists
  returns false), and the MSYS spelling of a path has cost this project time
  more than once. Every path this tool is given or prints is therefore in
  native form.

Exit status is 0 when the shards were written, 1 on an error.
"""

import argparse
import json
import os
import sys

# The font a run uses when --font is not given. Noto Sans SC is licensed under
# the SIL Open Font License 1.1 (the full text is in THIRD_PARTY_LICENSES at the
# repository root), so the glyph set this tool derives from it may be published
# with the project: a bitmap rendering is a derivative work of the font, and the
# OFL permits that. The file is a variable font; the tool selects the named
# instance below, because PIL would otherwise rasterise the font's default axis
# (for this file, Thin) and the shipped set must be the readable Regular weight.
# The path is in WINDOWS form on purpose: Python here is a Windows build and
# "/c/Windows/Fonts/..." does not resolve for it -- os.path.exists returns false,
# which has cost this project time twice.
DEFAULT_FONT = "C:\\Windows\\Fonts\\NotoSansSC-VF.ttf"

# The named instance a variable font is rasterised through. A static font has no
# named instances and is used as it is; a variable font without this instance is
# a build failure rather than a silent fallback to its default weight.
FONT_VARIATION = "Regular"

# The 2x3 sub-pixel block the runtime renders is defined there; the constants
# below are the cell size that block implies, and are kept here only to REPORT
# how many character cells a glyph occupies.
CELL_W_DIVISOR = 2          # two pixel columns per character
CELL_H_DIVISOR = 3          # three pixel rows per character

# The codepoint whose glyph is the placeholder a missing glyph falls back to:
# U+FFFD REPLACEMENT CHARACTER, drawn by this tool as a hollow box. It is put in
# the index like any other glyph so that the runtime needs no table of its own --
# cc_chinese.lua config.fallback names it and the shard lookup does the rest.
FALLBACK = 0xFFFD

# The Unicode general categories that ARE pictures of a character, so they are
# the only ones drawn. The list is stated positively on purpose: it used to be
# the negative form -- everything except a list of non-graphic categories -- and
# that silently turned every UNASSIGNED codepoint into a placeholder box, because
# an unassigned codepoint's category is "Cn" and "Cn" was in the exclusion list.
# A font's cmap is full of unassigned slots that map to glyph 0, so a range like
# U+4E00-U+9FFF would have come back as thousands of boxes.
GRAPHIC = {"Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me",
           "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
           "Sm", "Sc", "Sk", "So"}

# The characters that are blank on purpose. They are listed rather than left to
# the ink test because a font is free to give them an outline, and a box drawn
# for a space would be wrong in a way a reader would see immediately.
NO_INK = (0x20, 0x00A0, 0x3000)

# The punctuation of GB2312's row 1, in the standard's order. A CJK document
# needs these before it needs its 3000th ideograph, and they are 24 glyphs, so a
# default run always draws them (the cap below counts them first).
PUNCTUATION = (
    "\u3000\u3001\u3002\u00b7\u02c7\u02c9\u2014\uff5e\u2016\u2018\u2019\u201c"
    "\u201d\u3014\u3015\u3008\u3009\u300a\u300b\u300c\u300d\u300e\u300f"
)

# What a default run draws: 5400 glyphs. The number is a BUDGET and not a
# preference, and it is worth writing down where it comes from.
#
# The glyphs are the reason this font lives on a medium of its own. A CraftOS
# floppy holds 1,228,800 B, and one glyph at size 12 costs about 191 B of Lua
# source: the matrix is 12 rows of 12 characters, but the runtime asks for the
# PACKED form, so six rows, plus the table syntax around those. 6000 glyphs plus
# their index measure about 1.22 MB, which is the entire floppy with nothing left
# for the package that would use them.
#
# 5400 glyphs measure about 1.10 MB, which leaves about 130 KB: room for the
# package that renders with these glyphs to be installed onto the same medium,
# and room for a second, smaller set (size 8) to share the disk. It is also well
# past the 3500 characters of GB2312's own "commonly used" list, so a menu, a
# filename or a paragraph of ordinary Chinese is covered.
#
# THE WHOLE OF GB2312 DOES NOT FIT ONE MEDIUM. 6763 ideographs plus the
# punctuation row and the fallback box measure 1,375,263 B (measured, not
# estimated) against the 1,228,800 B floppy: the standard is 146,463 B too big
# for the medium it would have to live on. That is why there is a cap at all.
#
# There are therefore TWO named sets, and which one a run builds is the only
# difference between them:
#   DEFAULT_GLYPHS  5400 glyphs, 1.09 MB: the set that fits ONE floppy, with room
#                   left for the package that renders with it;
#   FULL_GLYPHS     6786 codepoints, 1.38 MB: the WHOLE standard, which the
#                   operator asked for and which needs TWO media (--full).
# The characters are taken in GB2312 level 1's own order, which is by pinyin and
# not by usefulness. That means the 5400 cap drops an arbitrary tail rather than
# the rarest characters, and it is said here because it is a real limitation:
# character 5401 is dropped even when it is commoner than one of the 5399 kept
# before it. --full removes the cap; a caller that wants a different set passes
# --chars with its list, or runs the generator again onto another medium.
DEFAULT_GLYPHS = 5400

# The whole standard: every ideograph GB2312 level 1 actually encodes (6763) plus
# the punctuation row of 23 marks that a CJK document needs first. The generator
# adds U+FFFD on top of whatever it is given, and drops the codepoints whose
# glyph has no ink, so the set that comes out is a few glyphs short of the sum --
# the report prints what the medium really gets. Splitting this set across media
# is tools/fontdisk.py's job (--set-out), because the capacity it has to fit is a
# property of the medium and not of the glyphs.
FULL_GLYPHS = 6763 + 23

# GB2312 LEVEL 1: the 3755 ideographs of the standard's first level, its order
# being by pinyin and not by usefulness. The ranking inside a level is the
# standard's business; what matters here is that the SET is a real, reproducible,
# complete-in-itself selection a reader of Chinese will recognise -- the level
# covers the characters a news page actually uses. The generator reads the
# standard's own layout rather than shipping a word list of its own, so the set
# is a property of the standard and not of this file's opinion.
#
# Rows 0xB0..0xF7 and columns 0xA1..0xFE, which is 72 rows of 94 = 6768 slots.
# The last row is short by five, and the ideographic space (row 0xA1) is outside
# the range, so this is 3755 characters -- LEVEL 1 ONLY. Rows 0xF8..0xFE are the
# standard's level 2 (3008 rarer ideographs) and are deliberately not read: they
# would treble the glyph set for characters a screen almost never shows.
GB2312_LEVEL1 = (0xB0, 0xA1, 0xF7, 0xFE)      # first row, first col, last row, last col


class FontgenError(Exception):
    """A failure the operator has to act on: reported, not tracebacked."""


def fail(message):
    raise FontgenError(message)


def cell_size(size):
    """The character cells a glyph of this pixel size occupies, as (w, h)."""
    return -(-size // CELL_W_DIVISOR), -(-size // CELL_H_DIVISOR)


def gb2312_level1():
    """The 3755 ideographs of GB2312 level 1, in the standard's own order.

    A GB2312 row/column pair (r, c) is the character at that address in the
    standard's code space, so the level is read out of the encoding itself rather
    than out of a table that could drift: decoding the two bytes as gb2312 gives
    the Unicode character the standard puts there.
    """
    r0, c0, r1, c1 = GB2312_LEVEL1
    out = []
    for row in range(r0, r1 + 1):
        for col in range(c0, c1 + 1):
            try:
                text = bytes((row, col)).decode("gb2312")
            except UnicodeDecodeError:
                continue                       # the five unused last positions
            if len(text) == 1:
                out.append(ord(text))
    return out


def default_charset(limit):
    """What a default run draws: at most `limit` codepoints.

    The list EXCLUDES the placeholder (generate() adds U+FFFD itself), so this
    answers with `limit` or fewer, never more.

    The punctuation is taken first and the ideographs fill the rest, so the cap
    can never drop a full stop: a run asked for 30 glyphs gets the punctuation
    and the four characters that fit, never 30 characters and no marks.
    """
    budget = DEFAULT_GLYPHS if limit is None else limit
    if budget <= 0:
        fail("--limit must be at least 1")
    cps, seen = [], set()
    for ch in PUNCTUATION:
        cp = ord(ch)
        if cp not in seen and len(cps) < budget:
            seen.add(cp)
            cps.append(cp)
    for cp in gb2312_level1():
        if len(cps) >= budget:
            break
        if cp not in seen:
            seen.add(cp)
            cps.append(cp)
    return cps


def top_up_for_blanks(cps, extra, seen=None):
    """Extend a set by `extra` more codepoints from the same standard.

    A codepoint with no ink is dropped from the index on purpose -- a space has no
    glyph by definition -- which would leave the medium holding fewer glyphs than
    the documented number. So the set is topped up from further down the same
    standard, and the number in the report stays the number of glyphs the medium
    really gets.

    `extra` is exactly one per blank, which is why this takes a COUNT and not a
    target: asking for a target is how the arithmetic came apart by five once, on
    a list that had already been extended with replacements.
    """
    if extra <= 0:
        return cps
    taken = set(cps) if seen is None else seen
    added = 0
    for cp in gb2312_level1():
        if added >= extra:
            break
        if cp not in taken:
            taken.add(cp)
            cps.append(cp)
            added += 1
    return cps


def parse_range(text):
    """One --chars or --probe argument: "U+4E00-U+9FFF", "0x4e00", "19968", "ABC".

    A range is inclusive and either end may be in any of the spellings; a single
    value is a range of one. Anything that is not a number is taken as literal
    text, so --chars "ABC" adds three codepoints, which is what a user typing a
    short string means.

    THE WHOLE TOKEN IS TRIED FIRST, and only then split on a range separator.
    The other order looks right and is wrong: "U+4E2D" is a single codepoint
    written in the form every Unicode document uses, and splitting it on "-" or
    ".." first finds no separator, falls through to "literal text", and draws the
    seven characters of the SPELLING (U, +, 4, E, 2, D) instead of the character
    they name. That is a silent wrong answer -- the run succeeds and the glyph
    that comes out is of the letter D -- so the order is the point.
    """
    text = text.strip()
    whole = parse_codepoint(text)
    if whole is not None:
        return [whole]
    for dash in ("..", "-"):
        if dash in text:
            left, _, right = text.partition(dash)
            a = parse_codepoint(left)
            b = parse_codepoint(right)
            if a is not None and b is not None:
                if b < a:
                    fail("--chars %s: the range runs backwards" % text)
                return list(range(a, b + 1))
    return [ord(ch) for ch in text]


def parse_codepoint(text):
    """A number in the spellings a font tool's user writes, or None.

    "U+4E2D", "u4e2d", "0x4e2d" and "20013" all name the same codepoint. The two
    prefixed hexadecimal spellings are decided by the PREFIX and not left to the
    fall-through, which is a trap this file already fell into: after "U+" was
    stripped the remainder went to int(body, 10), so "U+4E00" happened to parse
    as decimal 4E00 is not a decimal -- 4000 -- while "U+4E2D" raised and came
    back as None, and a None turns the whole argument into literal text. The
    result was a run that succeeded while drawing the letter D instead of the
    character asked for.
    """
    text = text.strip()
    if not text:
        return None
    tag = text[:2].lower()
    if tag == "u+":
        body, base = text[2:], 16
    elif tag == "0x":
        body, base = text, 16
    elif text[:1].lower() == "u" and len(text) > 1:
        body, base = text[1:], 16
    else:
        body, base = text, 10
    try:
        return int(body, base)
    except ValueError:
        return None


def read_chars_file(path):
    """Every character of a UTF-8 text file, in order, duplicates removed.

    The point of accepting a file is that a user can hand over the text they
    actually want on the screen -- a menu, a set of labels -- and get exactly
    those glyphs instead of a 3755 character standard.
    """
    if not os.path.isfile(path):
        fail("no such --chars file: %s" % path)
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    out, seen = [], set()
    for ch in text:
        cp = ord(ch)
        if cp not in seen and ch not in "\r\n\t":
            seen.add(cp)
            out.append(cp)
    return out


def load_face(spec, size):
    """Open the font described by --font, which may be a TTC with several faces.

    "path", "path#1" and "path:1" all name a face; a .ttc holds several fonts and
    a wrong pick is silent (the wrong shapes, not an error), so the face actually
    opened is printed and recorded in the report.
    """
    from PIL import ImageFont

    path, index = spec, 0
    for sep in ("#", ":"):
        head, found, tail = path.rpartition(sep)
        if found and tail.isdigit() and os.path.isfile(head):
            path, index = head, int(tail)
            break
    if not os.path.isfile(path):
        # The two spellings differ by one character and one of them silently
        # resolves to nothing on Windows Python, so the message says which one.
        fail("no such font: %s (use a Windows path like "
             "C:\\Windows\\Fonts\\NotoSansSC-VF.ttf, not the MSYS spelling)" % path)
    try:
        font = ImageFont.truetype(path, size, index=index)
    except Exception as exc:                    # PIL has many failure modes
        fail("cannot open %s face %d at size %d: %s" % (path, index, size, exc))
    # A variable font is rasterised through a named instance. Left alone, PIL
    # picks the font's default axis, which is not necessarily the weight the
    # screen needs; the generated header and report must name what was used.
    instance = None
    try:
        names = font.get_variation_names()
    except Exception:
        names = None
    if names:
        decoded = [n.decode("utf-8", "ignore") if isinstance(n, bytes) else str(n)
                   for n in names]
        if FONT_VARIATION not in decoded:
            fail("%s has no %r instance (has: %s)"
                 % (path, FONT_VARIATION, ", ".join(decoded)))
        try:
            font.set_variation_by_name(FONT_VARIATION)
        except Exception as exc:
            fail("cannot select %r in %s: %s" % (FONT_VARIATION, path, exc))
        instance = FONT_VARIATION
    try:
        name = font.getname()
    except Exception:
        name = "?"
    return font, path, index, name, instance


SUPERSAMPLE = 4
# A target pixel is ink when it is covered at least this much of the way. Measured
# at size 12 for U+4E2D on the face this set was first built from: the inked
# pixels spread from 48 to 199, so a 0.5 threshold kept 16 of 54 and the glyph
# lost its box sides and its feet, while 0.35 kept the whole character. Above
# ~0.45 complex characters break up. Re-measured on the OFL face (Noto Sans SC)
# at the same size the same thing happens: 0.5 keeps 27 of the 56 covered pixels
# and drops the box sides, 0.35 keeps 34. The threshold is a property of a 12
# pixel CJK cell, not of one particular font.
INK_FRACTION = 0.35


def rasterise(font, cp, size):
    """One codepoint as a list of "0"/"1" rows, top row first.

    The pen is placed on a FIXED baseline rather than at each glyph's own ink
    bounding box. That is what makes a line of text sit on one line: a glyph's
    ink box moves with the character (a character with no descender has a
    different box from one with), so centring each glyph by its own box would
    make the characters of a word wander up and down.

    The cell is the full ascent+descent em box, centred vertically. Centring the
    em box (rather than anchoring its top) is right for CJK, where a glyph fills
    its em box and a pixel of the top or bottom margin is a pixel of the
    character.

    TWO THINGS ARE FIXED HERE THAT WERE BOTH REAL AND INVISIBLE UNTIL THE SCREEN
    WAS LOOKED AT:

    1. SUPERSAMPLING. Drawing straight into a size x size canvas and thresholding
       at 128 throws CJK strokes away, because at 12 pixels a stroke lands between
       pixel centres and comes out as mid grey. Measured: the whole of U+4E2D at
       size 12 rasterised to 54 lit pixels of which 34 were between 64 and 127, so
       the 128 threshold kept 16 -- and those 16 were the two horizontal bars of
       the character's box. The bitmap was "correct" by every count-based test and
       the screen showed two loose bars. Rendering at SUPERSAMPLE x and averaging
       down with a box filter gives each target pixel its true coverage, and
       INK_FRACTION then decides on coverage rather than on one grey value.
    2. THE CENTRING SIGN. The crop used to step UP the canvas by (em - size) // 2,
       so the window sat above the glyph and clipped its feet; at size 12 the
       em box is 13 pixels for a 12 pixel grid and the glyph was cut in half. The
       window has to step DOWN from the em box's top.
    """
    from PIL import Image, ImageDraw

    ss = SUPERSAMPLE
    big_size = size * ss
    big = font.font_variant(size=big_size) if hasattr(font, "font_variant") else font
    ascent, descent = big.getmetrics()
    em = ascent + descent
    pad = max(2, size // 4) * ss
    # Canvas tall enough for the whole em box, drawn with the baseline inside it,
    # then cropped. Drawing straight into the target canvas would clip before the
    # crop could decide what to keep.
    canvas_h = em + 2 * pad
    img = Image.new("L", (big_size + 2 * pad, canvas_h), 0)
    draw = ImageDraw.Draw(img)
    pen_y = pad + ascent
    draw.text((pad, pen_y), chr(cp), fill=255, font=big, anchor="ls")

    # The em box occupies canvas rows [pad, pad + em). Take the window centred on
    # it: DOWN from its top when the box is taller than the grid, up (but never
    # above the canvas) when it is shorter.
    top = pad + (em - big_size) // 2
    top = max(0, min(top, canvas_h - big_size))
    cell = img.crop((pad, top, pad + big_size, top + big_size))
    small = cell.resize((size, size), Image.BOX)
    px = small.load()

    peak = 0
    for y in range(size):
        for x in range(size):
            if px[x, y] > peak:
                peak = px[x, y]
    if peak == 0:
        return ["0" * size for _ in range(size)]

    cut = peak * INK_FRACTION
    rows = []
    for y in range(size):
        rows.append("".join("1" if px[x, y] >= cut else "0" for x in range(size)))
    return rows


def blank_rows(size):
    return ["0" * size for _ in range(size)]


def box_rows(size):
    """A hollow box: the visible placeholder for a codepoint with no glyph.

    It has to be visible and it has to be distinguishable from a real character,
    because its whole job is to say "the font does not have this one" instead of
    leaving a hole that looks like a space.
    """
    rows = []
    for y in range(size):
        if y in (0, size - 1):
            rows.append("1" * size)
        elif y == 1 or y == size - 2:
            rows.append("1" + "0" * (size - 2) + "1")
        else:
            rows.append("1" + "0" * (size - 2) + "1")
    return rows


def glyph_rows(font, cp, size):
    """The rows of this codepoint, or None when it has no business being drawn.

    None is not "the font has no glyph for it": a space has no ink BY DEFINITION
    and must not become a box, so the decision is made from the character's
    Unicode category and then from the ink -- never from "is there a glyph in the
    cmap", because a font that maps U+3000 to an empty outline would otherwise
    turn every ideographic space into a visible box.
    """
    import unicodedata

    try:
        category = unicodedata.category(chr(cp))
    except ValueError:
        return None
    if category not in GRAPHIC:
        return None
    if cp in NO_INK:
        return None
    rows = rasterise(font, cp, size)
    for row in rows:
        if "1" in row:
            return rows
    return None


def lua_string(text):
    """A Lua string literal for the row data.

    The rows are runs of "0" and "1" and contain no character Lua treats as
    special, so quoting is all that is needed. %q was considered and rejected:
    it is the ROM's own quoter, and a quoter's job is to escape, which is exactly
    the way a byte the machine's loadstring() cannot read gets into the file.
    write_text() writes with encoding="ascii" and so refuses anything else.
    """
    return '"%s"' % text


def shard_source(header, glyphs, size):
    """One shard file's text: a plain table literal, one glyph per line.

    One glyph per LINE is not cosmetic: a machine reads this file whole with
    fs.open/readAll, and a line is the smallest thing an operator can grep when
    a glyph looks wrong. It costs one byte per glyph over a run-on file.
    """
    cw, ch = cell_size(size)
    out = []
    if header:
        out.append("-- %s\n" % header)
    out.append("-- %d x %d pixels per glyph -> %d x %d character cells on screen\n"
               % (size, size, cw, ch))
    out.append("return {\n")
    for cp, rows in glyphs:
        body = ",".join(lua_string(r) for r in rows)
        out.append("[%d]={%s},\n" % (cp, body))
    out.append("}\n")
    return "".join(out)


def index_source(header, entries, size, total):
    """The index: what a lookup needs, and nothing else.

    It carries no glyph data at all, because the whole point of sharding is that
    the index is cheap to read and hold. One key per glyph of five to six
    characters is about 45 KB for a full level 1 set.
    """
    cw, ch = cell_size(size)
    out = []
    if header:
        out.append("-- %s\n" % header)
    out.append("-- codepoint -> shard id, for <base>_shard<N>.lua; %d glyph(s)\n"
               % total)
    out.append("-- matrix: %d rows of %d chars of \"0\"/\"1\" -> %d x %d cells\n"
               % (size, size, cw, ch))
    out.append("return {\n")
    for cp, shard in entries:
        out.append("[%d]=%d,\n" % (cp, shard))
    out.append("}\n")
    return "".join(out)


def write_text(path, text):
    """LF endings and no BOM, whatever the host's idea of a line ending is.

    newline="" is the point: Python's default translates "\\n" on Windows, and a
    CR then arrives on the machine as a byte inside the first line rather than as
    an ending. The project has been bitten by exactly that family of mistake (a
    BOM in /.settings made the machine look configured while every setting in it
    was ignored).
    """
    with open(path, "w", encoding="ascii", newline="") as fh:
        fh.write(text)


def generate(font_spec, size, out_dir, chars, shard_size, base, quiet, as_json,
             limit):
    """Rasterise, write the shards and the index, and return the report."""
    if size < 3:
        fail("--size %d is too small to render a 2x3 block" % size)
    if shard_size < 1:
        fail("--shard-size must be at least 1")

    if chars:
        cps = []
        seen = set()
        for item in chars:
            if os.path.isfile(item):
                found = read_chars_file(item)
            else:
                found = parse_range(item)
            for cp in found:
                if cp not in seen:
                    seen.add(cp)
                    cps.append(cp)
    else:
        cps = default_charset(limit)
    if not cps:
        fail("nothing to draw: the character set came out empty")

    out_of_range = [cp for cp in cps if cp < 0 or cp > 0x10FFFF]
    if out_of_range:
        fail("not a Unicode codepoint: %s" % ", ".join(str(c) for c in out_of_range[:4]))
    # A surrogate cannot be encoded and PIL refuses it with an unhelpful error.
    bad = [cp for cp in cps if 0xD800 <= cp <= 0xDFFF]
    if bad:
        fail("surrogate codepoints cannot be drawn: %s"
             % ", ".join("U+%04X" % c for c in bad[:4]))

    font, path, face, name, instance = load_face(font_spec, size)

    if not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    # The comment in the generated files names what produced them, so a shard
    # found later on a medium says which font, which instance and which size it
    # is rather than leaving that to be guessed from the numbers.
    header = ("generated by tools/fontgen.py from %s face %d%s at size %d - "
              "do not edit by hand"
              % (os.path.basename(path), face,
                 (" " + instance) if instance else "", size))

    # The placeholder is drawn first and included as a normal glyph, so the
    # runtime needs no special case: it looks up FALLBACK like any codepoint.
    if FALLBACK not in cps:
        cps = [FALLBACK] + cps
    glyphs = [(FALLBACK, box_rows(size))]
    blanks = []
    for cp in cps:
        if cp == FALLBACK:
            continue
        rows = glyph_rows(font, cp, size)
        if rows is None:
            blanks.append(cp)
            continue
        glyphs.append((cp, rows))

    # A WHITESPACE CODEPOINT IS REPLACED, NOT MERELY DROPPED, so that a set made
    # for a documented number really holds that many glyphs. It has to be a real
    # glyph: a medium that came out 200 short because a font maps the ideographic
    # space to an empty outline is a medium whose size report is wrong. The
    # replacement is only done for the DEFAULT set, because a caller who named
    # codepoints on the command line asked for those codepoints and not for others.
    if not chars and blanks:
        wanted = limit or DEFAULT_GLYPHS
        extra = wanted - len(glyphs)
        if extra > 0:
            before = len(cps)
            cps = top_up_for_blanks(cps, extra)
            # Only the codepoints just ADDED are drawn: re-drawing the whole list
            # would be the same work twice, and iterating the whole list again
            # would append characters that are already in the set.
            for cp in cps[before:]:
                rows = glyph_rows(font, cp, size)
                if rows is not None:
                    glyphs.append((cp, rows))

    # Sorted, because the shard a codepoint lands in then depends only on the
    # set, not on the order the user happened to name it in: two runs with the
    # same characters produce the same shard files, and a diff of two builds is
    # about the font rather than about the command line.
    glyphs.sort(key=lambda item: item[0])

    # ------------------------------------------------------------------ shards
    shards = []
    entries = []
    for start in range(0, len(glyphs), shard_size):
        chunk = glyphs[start:start + shard_size]
        shard_id = start // shard_size
        name_out = "%s_shard%d.lua" % (base, shard_id)
        target = os.path.join(out_dir, name_out)
        write_text(target, shard_source(header, chunk, size))
        for cp, _rows in chunk:
            entries.append((cp, shard_id))
        shards.append({
            "id": shard_id, "file": name_out, "path": target,
            "glyphs": len(chunk), "bytes": os.path.getsize(target),
            "first": chunk[0][0], "last": chunk[-1][0],
        })

    index_name = "%s_index.lua" % base
    index_path = os.path.join(out_dir, index_name)
    write_text(index_path, index_source(header, entries, size, len(glyphs)))

    total_bytes = os.path.getsize(index_path) + sum(s["bytes"] for s in shards)
    cw, ch = cell_size(size)
    report = {
        "tool": "tools/fontgen.py",
        "ok": True,
        "font": path,
        "face": face,
        "font_name": "%s %s" % (name[0], name[1]) if isinstance(name, tuple) else str(name),
        "variation": instance,
        "size": size,
        "cell": {"w": cw, "h": ch},
        "shard_size": shard_size,
        "base": base,
        "out": out_dir,
        "glyphs": len(glyphs),
        "blank": len(blanks),
        "index": {"file": index_name, "path": index_path,
                  "bytes": os.path.getsize(index_path), "entries": len(entries)},
        "shards": shards,
        "bytes": total_bytes,
        "files": len(shards) + 1,
    }
    if not quiet:
        print_report(report, blanks)
    if as_json:
        print(json.dumps(report, indent=1, sort_keys=True))
    return report


def print_report(report, blanks):
    print("fontgen: %s face %d (%s) size %d -> %d x %d character cells"
          % (os.path.basename(report["font"]), report["face"], report["font_name"],
             report["size"], report["cell"]["w"], report["cell"]["h"]))
    print("  %d glyph(s) in %d shard(s) of at most %d, plus the index"
          % (report["glyphs"], len(report["shards"]), report["shard_size"]))
    for shard in report["shards"]:
        print("    %-18s U+%04X..U+%04X  %4d glyph(s)  %8d B"
              % (shard["file"], shard["first"], shard["last"],
                 shard["glyphs"], shard["bytes"]))
    print("    %-18s %-19s %4d entr(y|ies)  %8d B"
          % (report["index"]["file"], "", report["index"]["entries"],
             report["index"]["bytes"]))
    print("  total %d B in %d file(s)  (%.1f KB)"
          % (report["bytes"], report["files"], report["bytes"] / 1024.0))
    if blanks:
        print("  %d codepoint(s) are blank in this font and were left out of the "
              "index (a space has no ink on purpose)" % len(blanks))
    print("  the files are plain ASCII Lua data: the machine reads them with "
          "loadstring()")


def main(argv):
    ap = argparse.ArgumentParser(
        description="rasterise a font into the shard files the runtime loads")
    ap.add_argument("--font", default=DEFAULT_FONT,
                    help="TTF/TTC to rasterise; a Windows path, optionally with "
                         "#N for a face of a collection (default: %(default)s)")
    ap.add_argument("--size", type=int, default=12,
                    help="pixel size of the square glyph cell (default: 12, the "
                         "size this project shipped its glyph set at)")
    ap.add_argument("--shard-size", type=int, default=500, dest="shard_size",
                    help="glyphs per shard file (default: 500, about 105 KB at "
                         "size 12, which is the unit the loader caches)")
    ap.add_argument("--out", default=".",
                    help="directory to write <base>_index.lua and <base>_shardN.lua")
    ap.add_argument("--base", default=None,
                    help="file name stem (default: shs<size>, so the index is "
                         "shs12_index.lua)")
    ap.add_argument("--chars", action="append", default=None,
                    help="what to draw: a codepoint range (U+4E00-U+9FFF, 0x4e00, "
                         "19968), literal text, or the path of a UTF-8 text file "
                         "whose characters are all drawn; repeatable (default: the "
                         "GB2312 level 1 ideographs and CJK punctuation)")
    ap.add_argument("--limit", type=int, default=None,
                    help="cap the default set (only used when --chars is absent)")
    ap.add_argument("--full", action="store_true",
                    help="draw the WHOLE standard: every GB2312 ideograph plus "
                         "the punctuation, about 1.37 MB, which does NOT fit one "
                         "1,228,800 B floppy and is built as two media by "
                         "tools/fontdisk.py --set-out. Implies --limit %d and is "
                         "only used when --chars is absent" % FULL_GLYPHS)
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="print a machine readable report")
    ap.add_argument("--quiet", action="store_true",
                    help="print nothing but the --json report")
    ap.add_argument("--probe", metavar="CHARS", action="append",
                    help="print the bitmap of each character of CHARS and exit; "
                         "this is how a size or a baseline is chosen, and how a "
                         "glyph is checked without a machine")
    args = ap.parse_args(argv)

    try:
        if args.probe:
            return probe(args)
        if args.full and args.limit is not None:
            fail("--full and --limit set the same cap; pass only one of them")
        base = args.base or ("shs%d" % args.size)
        report = generate(args.font, args.size, os.path.abspath(args.out),
                          args.chars, args.shard_size, base, args.quiet,
                          args.as_json,
                          FULL_GLYPHS if args.full else args.limit)
    except FontgenError as exc:
        if args.as_json:
            print(json.dumps({"tool": "tools/fontgen.py", "ok": False,
                              "error": str(exc)}, indent=1, sort_keys=True))
        else:
            print("fontgen: %s" % exc)
        return 1
    return 0 if report["ok"] else 1


def probe(args):
    """Print the bitmaps named on the command line; this is the eyeball check.

    It is how a size is chosen and how a glyph is checked, and it needs no
    machine -- the tool that decides what the pixels are is also the tool that
    shows them.
    """
    font, path, face, name, instance = load_face(args.font, args.size)
    label = "%s %s" % (name[0], name[1]) if isinstance(name, tuple) else str(name)
    print("size %d from %s face %d (%s%s)"
          % (args.size, path, face, label, (", " + instance) if instance else ""))
    rows_shown = 0
    for item in args.probe:
        cps = read_chars_file(item) if os.path.isfile(item) else parse_range(item)
        for cp in cps:
            print("U+%04X" % cp)
            for row in rasterise(font, cp, args.size):
                print("  " + row.replace("1", "#").replace("0", "."))
            rows_shown += 1
    if rows_shown == 0:
        print("fontgen: --probe drew nothing")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
