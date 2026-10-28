#!/usr/bin/env python3
"""Preview Chinese text the way the resource pack will make it appear.

The emulator cannot be restyled (CraftOS-PC's font is compiled into the binary, and
hdfont.bmp next to it is not read), so the only honest way to see the result before
installing the pack on a server is to render it here: ASCII from the same source
the pack uses, Chinese from the project's real glyph shards, encoded the way the
runtime encodes it -- one terminal cell per byte 128 + mask.

The default needs no CC:Tweaked texture at all, matching the default build of the
pack:

    python tools/respack/preview.py --out preview.png
    python tools/respack/preview.py --text sample.txt --out preview.png

ASCII comes from the embedded public-domain 6x9 table (font6x9.py), placed in its
6x9 cell exactly as make_pack.py places it. To preview the old "patch the vanilla
texture" mode -- or the term_font.png extracted from a pack you already built --
pass the texture:

    python tools/respack/preview.py --texture term_font.png --out preview.png

A size 12 glyph is 12x12 pixels, which is 6x4 terminal cells; each of those cells
holds a 2x3 block of the glyph. That is the whole scheme.
"""
import argparse
import os
import re
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:                                    # pragma: no cover
    sys.exit("this script needs Pillow: python -m pip install pillow")

# The font table lives beside this script; make that true even when the script is
# imported rather than run.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import font6x9                                        # noqa: E402

FONT_WIDTH, FONT_HEIGHT = 6, 9
STRIDE_X, STRIDE_Y = FONT_WIDTH + 2, FONT_HEIGHT + 2
CELLS_W, CELLS_H = 6, 4            # a size 12 glyph, in terminal cells
SCALE = 3

# Used when no --text file is given. Written as escapes so this file stays ASCII.
SAMPLE = (
    "psh 1.0 - \u8f93\u5165 help \u67e5\u770b\u547d\u4ee4\n"
    "admin@cc-0:/$ lang zh\n"
    "\u8bed\u8a00\u5df2\u5207\u6362\u4e3a zh\n"
    "\u5df2\u63d2\u5165\u5b57\u5f62\u5e93\u4ecb\u8d28\n"
    "Sphinx of black quartz, judge my vow! 0123456789 @#$%&*()\n"
)


def cell_origin(n):
    return 1 + (n % 16) * STRIDE_X, 1 + (n // 16) * STRIDE_Y


class Fonts:
    """ASCII from the embedded table (default) or from a texture, plus the shards."""

    def __init__(self, texture_path, fontdata):
        self.tex = None
        self.px = None
        if texture_path:
            self.tex = Image.open(texture_path).convert("RGBA")
            self.px = self.tex.load()
        self.fontdata = fontdata
        self.index = None
        self.shards = {}
        self.cache = {}

    def ascii_bitmap(self, code):
        if self.px is not None:
            gx, gy = cell_origin(code & 0xFF)
            return [[self.px[gx + x, gy + y][3] > 100 for x in range(FONT_WIDTH)]
                    for y in range(FONT_HEIGHT)]
        rows = font6x9.GLYPHS.get(code)
        if rows is None:
            return [[False] * FONT_WIDTH for _ in range(FONT_HEIGHT)]
        return [[bool(rows[y] & (0x80 >> x)) if y < len(rows) else False
                 for x in range(FONT_WIDTH)] for y in range(FONT_HEIGHT)]

    def _load_index(self):
        text = open(os.path.join(self.fontdata, "shs12_index.lua"),
                    encoding="utf-8").read()
        self.index = {int(cp): int(shard)
                      for cp, shard in re.findall(r"\[(\d+)\]=(\d+)", text)}

    def matrix(self, cp):
        if cp in self.cache:
            return self.cache[cp]
        if self.index is None:
            self._load_index()
        shard = self.index.get(cp)
        if shard is None:
            self.cache[cp] = None
            return None
        if shard not in self.shards:
            path = os.path.join(self.fontdata, "shs12_shard%d.lua" % shard)
            text = open(path, encoding="utf-8").read()
            table = {}
            for m in re.finditer(r"\[(\d+)\]=\{([^}]*)\}", text):
                table[int(m.group(1))] = re.findall(r'"([01]+)"', m.group(2))
            self.shards[shard] = table
        self.cache[cp] = self.shards[shard].get(cp)
        return self.cache[cp]


def cell_mask(mat, cx, cy):
    """The 6-bit mask for terminal cell (cx, cy), bit order of cell_byte()."""
    m = 0
    for row in range(3):
        for col in range(2):
            px, py = cx * 2 + col, cy * 3 + row
            if 0 <= py < len(mat) and 0 <= px < len(mat[py]) and mat[py][px] == "1":
                m |= 1 << (row + col * 3)
    return m


def default_fontdata():
    return os.path.normpath(os.path.join(_HERE, os.pardir, os.pardir,
                                         "fontdata"))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--texture", default=None,
                    help="optional: read ASCII from this term_font.png instead "
                         "of the embedded public-domain table (the vanilla "
                         "texture, or the one inside a pack you built)")
    ap.add_argument("--fontdata", default=None,
                    help="the generated glyph set (default: the fontdata/ "
                         "beside this script)")
    ap.add_argument("--text", default=None,
                    help="a UTF-8 file to render (default: a built-in sample)")
    ap.add_argument("--out", default="preview.png")
    ap.add_argument("--scale", type=int, default=SCALE)
    args = ap.parse_args(argv)

    if args.texture and not os.path.isfile(args.texture):
        return "no such texture: %s" % args.texture
    fontdata = args.fontdata or default_fontdata()
    if not os.path.isdir(fontdata):
        return ("no glyph set at %s (build it with: python tools/fontgen.py "
                "--full --size 12 --out fontdata)" % fontdata)

    text = SAMPLE
    if args.text:
        with open(args.text, encoding="utf-8") as fh:
            text = fh.read()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    fonts = Fonts(args.texture, fontdata)
    cols = max(40, max((sum(1 for c in ln if ord(c) < 128) +
                        sum(CELLS_W for c in ln if ord(c) >= 128) for ln in lines),
                       default=40))
    rows = max(6, len(lines) * CELLS_H)

    img = Image.new("RGBA", (cols * FONT_WIDTH, rows * FONT_HEIGHT),
                    (25, 25, 25, 255))
    drw = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)

    for li, line in enumerate(lines):
        x, y = 0, li * CELLS_H
        for ch in line:
            if ord(ch) < 128:
                bm = fonts.ascii_bitmap(ord(ch))
                for gy in range(FONT_HEIGHT):
                    for gx in range(FONT_WIDTH):
                        if bm[gy][gx]:
                            drw.point((x * FONT_WIDTH + gx,
                                       y * FONT_HEIGHT + gy), white)
                x += 1
            else:
                mat = fonts.matrix(ord(ch))
                if mat is None:
                    x += CELLS_W
                    continue
                for cy in range(CELLS_H):
                    for cx in range(CELLS_W):
                        mask = cell_mask(mat, cx, cy)
                        for row in range(3):
                            for col in range(2):
                                if not (mask & (1 << (row + col * 3))):
                                    continue
                                for py in range(row * 3, row * 3 + 3):
                                    for px in range(col * 3, col * 3 + 3):
                                        drw.point(((x + cx) * FONT_WIDTH + px,
                                                   (y + cy) * FONT_HEIGHT + py),
                                                  white)
                x += CELLS_W

    if args.scale != 1:
        img = img.resize((img.width * args.scale, img.height * args.scale),
                         Image.NEAREST)
    img.save(args.out)
    print("wrote %s (%dx%d), ASCII from %s"
          % (args.out, img.width, img.height,
             args.texture or "the embedded 6x9 table"))
    return None


if __name__ == "__main__":
    err = main()
    if err:
        sys.exit("respack: " + err)
