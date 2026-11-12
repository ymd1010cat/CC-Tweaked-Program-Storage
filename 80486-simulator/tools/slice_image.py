#!/usr/bin/env python3
"""Slice a raw DOS/PC floppy image into CC:Tweaked shard files.

The 80486 simulator (80486-simulator/disk.lua) reads the image as a chain of
local shard files:

    img_00.dat, img_01.dat, ...      (about 128 KiB each by default)

This tool does the slicing on the host and, with CRC32 enabled (the default),
also writes an `image.crc32` manifest in the format disk.lua expects:

    1a2b3c4d  img_00.dat
    ...

The result directory is exactly what has to be copied to the CraftOS
computer: put it at /disk (or split the files over several mounted floppies
/disk, /disk2, ...) and run:

    runner /disk,/disk2

Usage:
    python 80486-simulator/tools/slice_image.py DOS20.img --out disk
    python 80486-simulator/tools/slice_image.py disk.img --out disk \\
        --part-size 131072 --no-crc

Requires Python 3, no third-party packages.
"""

import argparse
import sys
import zlib
from pathlib import Path

SECTOR_SIZE = 512
DEFAULT_PART_SIZE = 128 * 1024


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Slice a raw floppy image into 80486-simulator shards.")
    parser.add_argument("image", help="raw floppy/hard-disk image file")
    parser.add_argument("--out", default="disk",
                        help="output directory (default: ./disk)")
    parser.add_argument("--part-size", type=int, default=DEFAULT_PART_SIZE,
                        help="shard size in bytes (default: 131072, must be "
                             "a multiple of 512)")
    parser.add_argument("--no-crc", action="store_true",
                        help="do not write image.crc32")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if args.part_size <= 0 or args.part_size % SECTOR_SIZE != 0:
        print("error: --part-size must be a positive multiple of %d"
              % SECTOR_SIZE, file=sys.stderr)
        return 2

    image_path = Path(args.image)
    if not image_path.is_file():
        print("error: image not found: %s" % image_path, file=sys.stderr)
        return 2

    data = image_path.read_bytes()
    if not data:
        print("error: image is empty", file=sys.stderr)
        return 2
    if len(data) % SECTOR_SIZE != 0:
        print("error: image size %d is not a multiple of %d bytes"
              % (len(data), SECTOR_SIZE), file=sys.stderr)
        return 2

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = []
    parts = []
    index = 0
    for start in range(0, len(data), args.part_size):
        chunk = data[start:start + args.part_size]
        name = "img_%02d.dat" % index
        (out_dir / name).write_bytes(chunk)
        crc = zlib.crc32(chunk) & 0xFFFFFFFF
        manifest.append("%08x  %s" % (crc, name))
        parts.append((name, len(chunk), crc))
        index += 1

    if not args.no_crc:
        manifest_path = out_dir / "image.crc32"
        manifest_path.write_text("\n".join(manifest) + "\n",
                                 encoding="ascii", newline="\n")

    whole_crc = zlib.crc32(data) & 0xFFFFFFFF
    print("image:    %s" % image_path)
    print("size:     %d bytes (%d sectors)" % (len(data),
                                               len(data) // SECTOR_SIZE))
    print("parts:    %d" % len(parts))
    for name, size, crc in parts:
        print("  %s  %6d bytes  crc32=%08x" % (name, size, crc))
    if not args.no_crc:
        print("manifest: %s" % (out_dir / "image.crc32"))
    print("whole image crc32=%08x" % whole_crc)
    print("output directory: %s" % out_dir)
    print("")
    print("Deploy: copy this directory to the CraftOS computer as /disk")
    print("(or split the shards over /disk, /disk2, ...) and run:")
    print("    runner /disk")
    return 0


if __name__ == "__main__":
    sys.exit(main())
