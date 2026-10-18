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
assumption true: it rewrites bytes 128..191 of the texture to the 64 possible 2x3
blocks.

GEOMETRY, from CC:Tweaked's own renderer
(projects/common/src/client/java/dan200/computercraft/client/render/text/FixedWidthFontRenderer.java):

    public static final int FONT_HEIGHT = 9;
    public static final int FONT_WIDTH = 6;
    static final float WIDTH = 256.0f;
    var xStart = 1 + column * (FONT_WIDTH + 2);
    var yStart = 1 + row * (FONT_HEIGHT + 2);

One glyph is 6x9 pixels inside an 8x11 stride at a 1 pixel inset, and a byte picks
its cell by column = byte % 16, row = byte / 16. A 2x3 block of a 6x9 glyph is
exactly 3x3 pixels, which is why the scheme is possible at all.

WHAT YOU MUST SUPPLY
--------------------
The vanilla texture, taken from the same CC:Tweaked jar your server runs:

    assets/computercraft/textures/gui/term_font.png

It is NOT bundled here. CC:Tweaked's source says "Do not distribute without
permission", so the pack has to be built from a copy the user already has -- which
also keeps the pack matched to the server's version.

    python tools/respack/make_pack.py --texture term_font.png --out ush-cjk-font.zip
"""
import argparse
import json
import os
import sys
import zipfile

try:
    from PIL import Image
except ImportError:                                    # pragma: no cover
    sys.exit("this script needs Pillow: python -m pip install pillow")

FONT_WIDTH, FONT_HEIGHT = 6, 9
STRIDE_X, STRIDE_Y = FONT_WIDTH + 2, FONT_HEIGHT + 2
TEXTURE = "assets/computercraft/textures/gui/term_font.png"

# Resource pack formats by Minecraft version. A wrong number is a warning, not a
# failure, but a right one keeps the pack out of the "incompatible" list.
PACK_FORMATS = {
    "1.16": 6, "1.17": 7, "1.18": 8, "1.19": 9, "1.20": 15,
    "1.20.2": 18, "1.21": 34,
}


def cell_origin(n):
    return 1 + (n % 16) * STRIDE_X, 1 + (n // 16) * STRIDE_Y


def build_texture(src):
    """Return a copy of the vanilla texture with bytes 128..191 as 2x3 blocks."""
    img = src.copy()
    px = img.load()
    for mask in range(64):
        ox, oy = cell_origin(128 + mask)
        for y in range(FONT_HEIGHT):
            for x in range(FONT_WIDTH):
                px[ox + x, oy + y] = (0, 0, 0, 0)
        for col in range(2):
            for row in range(3):
                # Bit layout matches lib/cc_chinese.lua cell_byte():
                # 1 left-top, 2 left-middle, 4 left-bottom,
                # 8 right-top, 16 right-middle, 32 right-bottom.
                if not (mask & (1 << (row + col * 3))):
                    continue
                for y in range(row * 3, row * 3 + 3):
                    for x in range(col * 3, col * 3 + 3):
                        px[ox + x, oy + y] = (255, 255, 255, 255)
    return img


def check_geometry(img, quiet=False):
    """Refuse to pack a texture that does not have CC:Tweaked's layout.

    A pack built against the wrong geometry would put the blocks in the wrong
    cells, which looks like slightly-off Chinese rather than like an error --
    the worst failure mode, so it is checked instead.
    """
    if img.size != (256, 256):
        return "the texture is %dx%d, but CC:Tweaked's is 256x256" % img.size
    # Byte 65 is 'A': six pixels wide, nine tall, and it must have ink.
    ox, oy = cell_origin(65)
    px = img.convert("RGBA").load()
    ink = [(x, y) for y in range(FONT_HEIGHT) for x in range(FONT_WIDTH)
           if px[ox + x, oy + y][3] > 100]
    if not ink:
        return ("no ink where 'A' should be (%d,%d): this does not look like "
                "CC:Tweaked's term_font.png" % (ox, oy))
    if not quiet:
        print("geometry ok: 'A' at %d,%d has %d lit pixels" % (ox, oy, len(ink)))
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--texture", required=True,
                    help="the vanilla term_font.png from the CC:Tweaked jar")
    ap.add_argument("--out", required=True, help="the .zip to write")
    ap.add_argument("--pack-format", type=int, default=15,
                    help="resource pack format (15 = 1.20.1); see PACK_FORMATS")
    ap.add_argument("--pack-metadata", default=None,
                    help="a name -> format table to pick the format from")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.texture):
        return "no such texture: %s" % args.texture
    src = Image.open(args.texture).convert("RGBA")
    problem = check_geometry(src, args.quiet)
    if problem:
        return problem

    out = build_texture(src)
    meta = {
        "pack": {
            "pack_format": args.pack_format,
            "description": "unixshell CJK sub-pixel glyphs (bytes 128-191)",
        }
    }

    staging = args.out + ".d"
    os.makedirs(os.path.join(staging, os.path.dirname(TEXTURE)), exist_ok=True)
    tex_path = os.path.join(staging, TEXTURE.replace("/", os.sep))
    out.save(tex_path)
    with open(os.path.join(staging, "pack.mcmeta"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)

    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(staging):
            for name in files:
                full = os.path.join(root, name)
                arc = os.path.relpath(full, staging).replace(os.sep, "/")
                zf.write(full, arc)
    for root, dirs, files in os.walk(staging, topdown=False):
        for name in files:
            os.remove(os.path.join(root, name))
        for name in dirs:
            os.rmdir(os.path.join(root, name))
    os.rmdir(staging)

    if not args.quiet:
        print("wrote %s (%d bytes), pack_format %d"
              % (args.out, os.path.getsize(args.out), args.pack_format))
        print("drop it in <minecraft>/resourcepacks/ and enable it")
    return None


if __name__ == "__main__":
    err = main()
    if err:
        sys.exit("respack: " + err)
