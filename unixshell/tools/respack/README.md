# respack - the font the Chinese interface needs

## Why this exists

A CraftOS terminal cell holds **one byte, 0..255**, and there is no pixel-level API.
`lib/cc_chinese.lua` draws Chinese by writing `string.char(128 + mask)` and
expecting the font to turn that byte into the six sub-pixels of a cell.

The stock font does not do that. Bytes 128..255 are Latin-1 letters, which is why
Chinese came out on screen as `deg+-2-3`-style noise while every count-based test
passed. Measured by drawing all 128 high bytes on a real screen: 0xB2..0xFF
rendered as `deg+-2-3(4)(5)(6)(7)(8)(9)>>1/4 1/2 3/4` then `A-ring, AE, C-cedilla`
and so on.

A resource pack can replace the terminal font texture, so these scripts make the
assumption true instead of hoping.

## What you need

The vanilla texture from **the same CC:Tweaked jar your server runs**:

    assets/computercraft/textures/gui/term_font.png

It is not bundled here: CC:Tweaked's source says "Do not distribute without
permission", and building from your own copy keeps the pack matched to your
version.

## Build the pack

    python tools/respack/make_pack.py --texture term_font.png --out ush-cjk-font.zip

Add `--pack-format N` if your Minecraft version is not 1.20.1 (the table of
formats is in the script). The script **refuses** a texture whose geometry does
not match CC:Tweaked's, because blocks written into the wrong cells look like
slightly-off Chinese rather than like an error.

## See it before installing

    python tools/respack/preview.py --texture term_font.png --out preview.png

That renders ASCII from the real CC:T texture and Chinese from the project's real
glyph shards, encoded exactly as the runtime encodes it. It is the only way to see
the result on a machine whose emulator cannot be restyled.

## Install

1. Put `ush-cjk-font.zip` in `<minecraft>/resourcepacks/` and enable it.
2. If the server forces its own pack list, have the operator whitelist this pack.

## Geometry, for anyone changing this

From CC:Tweaked's renderer
(`projects/common/src/client/java/dan200/computercraft/client/render/text/FixedWidthFontRenderer.java`):

    FONT_WIDTH = 6, FONT_HEIGHT = 9
    xStart = 1 + column * (FONT_WIDTH + 2)
    yStart = 1 + row * (FONT_HEIGHT + 2)

A glyph is 6x9 pixels in an 8x11 stride with a 1 pixel inset; the byte picks its
cell by column = byte % 16, row = byte / 16. A 2x3 block of a 6x9 glyph is exactly
3x3 pixels, which is why the scheme works at all.

Bit order, the same in the pack and in `cell_byte()`:

    1 left-top      2 left-middle      4 left-bottom
    8 right-top    16 right-middle    32 right-bottom

## Limits, honestly

* The pack changes bytes 128..191 only; 192..255 keep their Latin-1 glyphs.
* A size 12 glyph is 12x12 pixels = **6x4 terminal cells**, so one character is
  six columns and four rows wide. On a 51-column screen that is eight characters
  per line. That is a property of the terminal, not of the pack.
* Without the pack the shell should not claim to be in Chinese: `lang zh` already
  refuses when the glyph medium is missing, and the same reasoning applies here.
  This is a display font, so the check cannot be made from Lua -- the operator has
  to install the pack. That is why it is a separate, documented step.
