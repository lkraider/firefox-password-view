#!/usr/bin/env python3
"""Writes win/icon.ico from the artwork macos/Icon.icns already carries.

Run it after changing the artwork:

    python3 scripts/make-ico.py

The .ico is committed, so a build needs neither this script nor macOS.

macos/scripts/make-icon.swift draws the artwork at 1024 pixels and stores
that raster in Icon.icns. docs/images/icon.png is 96 pixels wide, and a
256-pixel entry scaled up from it is blurry. sips reads the largest raster
in the .icns, so the entries below all come from the 1024-pixel one.

Every entry holds a PNG. Windows has accepted a PNG inside an ICO since
Vista, so the writer is a 6-byte header, one 16-byte directory entry per
size, and the PNG bytes.
"""

import os
import struct
import subprocess
import sys
import tempfile

SIZES = [16, 24, 32, 48, 64, 128, 256]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO_ROOT, "macos", "Icon.icns")
OUTPUT = os.path.join(REPO_ROOT, "win", "icon.ico")


def sips(*args):
    subprocess.run(["sips", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def render(work_dir):
    """Returns the PNG bytes for each size in SIZES, in that order."""
    base = os.path.join(work_dir, "base.png")
    sips("-s", "format", "png", SOURCE, "--out", base)

    images = []
    for size in SIZES:
        scaled = os.path.join(work_dir, f"{size}.png")
        sips("-z", str(size), str(size), base, "--out", scaled)
        with open(scaled, "rb") as f:
            images.append(f.read())
    return images


def write_ico(path, images):
    # A width or height of 256 is stored as 0, since the field is one byte.
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)

    directory = b""
    for size, data in zip(SIZES, images):
        side = 0 if size == 256 else size
        directory += struct.pack(
            "<BBBBHHII", side, side, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)

    with open(path, "wb") as f:
        f.write(header)
        f.write(directory)
        for data in images:
            f.write(data)


def main():
    if not os.path.exists(SOURCE):
        sys.exit(f"missing {SOURCE}")
    with tempfile.TemporaryDirectory() as work_dir:
        write_ico(OUTPUT, render(work_dir))
    print(f"wrote {OUTPUT} ({os.path.getsize(OUTPUT)} bytes, {len(SIZES)} sizes)")


if __name__ == "__main__":
    main()
