#!/usr/bin/env python3
"""Convert the source PNG icons into alpha artwork for AtomGL.

AtomGL draws an rgba8888 image against the background colour the item
names: a pixel with alpha 0xFF is copied straight in, and any other pixel is
blended onto that colour (dcs_lcd_draw.c:79). So the icons carry real alpha
and the firmware picks the background per skin at draw time.

The source art is black-or-colour on an opaque white background with
anti-aliased edges. Keying out pure white alone would leave light halos, so
the white component is taken as transparency per pixel instead:

  greyscale art  ->  alpha = 255 - P, written as a mask; the firmware tints it
  colour art     ->  alpha = 255 - min(R,G,B), colour un-premultiplied

Greyscale is detected per file: if every pixel has R == G == B the art is
monochrome and becomes a one-byte-per-pixel .mask, otherwise it keeps its
colour as .rgba.

Output goes to firmware/assets/icons/<name>@<w>x<h>.{rgba,mask}, named by
meaning rather than by colour so the firmware never has to know that the
square is red. Badge.Icons globs that directory at compile time.

Large monochrome art in assets/src/art goes to assets/art instead, stored at
half size and already tinted once per glyph colour, for the assets partition
rather than the firmware. Badge.Art draws it at 2x, like the splash logo.

Usage: python3 firmware/tools/icons.py [--check]
  --check  report what would change without writing
"""

import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "src", "icons")
OUT = os.path.join(ROOT, "assets", "icons")
ART_SRC = os.path.join(ROOT, "assets", "src", "art")
ART_OUT = os.path.join(ROOT, "assets", "art")

# The glyph colours the skins use, mirroring Badge.Icons.tints/0.
ART_TINTS = [0xFFFFFF, 0x000000]

# Source art is named for how it looks; the firmware wants what it means.
RENAME = {
    "red-rectangle": "square",
    "orange-triangle": "triangle",
    "yellow-cross": "cross",
    "green-circle": "circle",
    "blue-clover": "clover",
    "purple-diamond": "diamond",
}


def decode_png(path):
    """Decode a non-interlaced 8-bit RGBA PNG to (width, height, pixels)."""
    blob = open(path, "rb").read()
    if blob[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")

    pos, idat, header = 8, b"", None
    while pos < len(blob):
        (length,) = struct.unpack(">I", blob[pos : pos + 4])
        kind = blob[pos + 4 : pos + 8]
        data = blob[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", data)
        elif kind == b"IDAT":
            idat += data
        pos += 12 + length

    width, height, depth, colour, _comp, _filt, interlace = header
    if (depth, colour, interlace) != (8, 6, 0):
        raise ValueError(
            f"{path}: need 8-bit RGBA non-interlaced, got depth={depth} "
            f"colour_type={colour} interlace={interlace}"
        )

    raw = zlib.decompress(idat)
    bpp, stride = 4, width * 4
    out, prev, pos = bytearray(), bytearray(stride), 0

    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride

        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            upleft = prev[i - bpp] if i >= bpp else 0

            if filter_type == 1:
                line[i] = (line[i] + left) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + up) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                pa, pb, pc = abs(up - upleft), abs(left - upleft), abs(left + up - 2 * upleft)
                if pa <= pb and pa <= pc:
                    pred = left
                elif pb <= pc:
                    pred = up
                else:
                    pred = upleft
                line[i] = (line[i] + pred) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"{path}: unknown filter {filter_type}")

        out += line
        prev = line

    return width, height, bytes(out)


def is_greyscale(pixels):
    return all(
        pixels[i] == pixels[i + 1] == pixels[i + 2] for i in range(0, len(pixels), 4)
    )


def to_mask(pixels):
    """One alpha byte per pixel: black is opaque, white is clear."""
    return bytes(255 - pixels[i] for i in range(0, len(pixels), 4))


def to_rgba8888(pixels):
    """Straight alpha: the most saturated pixel is the opaque body, pure white is clear."""
    out = bytearray(len(pixels))
    whites = [min(pixels[i], pixels[i + 1], pixels[i + 2]) for i in range(0, len(pixels), 4)]
    body = min(whites)
    span = 255 - body

    for i, white in enumerate(whites):
        alpha = min((255 - white) * 255 // span, 255) if span else 255
        rgb = pixels[4 * i : 4 * i + 3]

        # Undo the composite onto white so the driver can redo it onto any colour.
        if alpha:
            rgb = [max(0, min(255, 255 * (c - 255 + alpha) // alpha)) for c in rgb]
        else:
            rgb = [0, 0, 0]

        out[4 * i : 4 * i + 4] = bytes(rgb) + bytes([alpha])

    return bytes(out)


def main():
    check = "--check" in sys.argv

    convert(SRC, OUT, check)
    convert_art(ART_SRC, ART_OUT, check)


def convert(src, out, check):
    if not os.path.isdir(src):
        sys.exit(f"no source directory: {src}")

    if not check:
        os.makedirs(out, exist_ok=True)

    sources = sorted(f for f in os.listdir(src) if f.endswith(".png"))
    if not sources:
        sys.exit(f"no PNGs in {src}")

    written, total = [], 0

    for filename in sources:
        stem = filename[:-4]
        name = RENAME.get(stem, stem).replace("-", "_")

        width, height, pixels = decode_png(os.path.join(src, filename))
        greyscale = is_greyscale(pixels)

        if greyscale:
            data, suffix, mode = to_mask(pixels), "mask", "mask"
            assert len(data) == width * height
        else:
            data, suffix, mode = to_rgba8888(pixels), "rgba", "colour"
            assert len(data) == width * height * 4

        target = os.path.join(out, f"{name}@{width}x{height}.{suffix}")
        total += len(data)

        if check:
            state = "same" if _same(target, data) else "differs"
            print(f"{filename:24} -> {os.path.basename(target):26} {mode:6} {state}")
        else:
            with open(target, "wb") as handle:
                handle.write(data)
            written.append(os.path.basename(target))
            print(f"{filename:24} -> {os.path.basename(target):26} {mode:6} {len(data):6} bytes")

    print(f"\n{len(sources)} files, {total} bytes total\n")

    if not check:
        _prune(out, written)


def convert_art(src, out, check):
    """Half-size rgba8888 per tint: alpha is the mean of each 2x2 block."""
    if not os.path.isdir(src):
        sys.exit(f"no source directory: {src}")

    if not check:
        os.makedirs(out, exist_ok=True)

    sources = sorted(f for f in os.listdir(src) if f.endswith(".png"))
    if not sources:
        sys.exit(f"no PNGs in {src}")

    written, total = [], 0

    for filename in sources:
        name = filename[:-4].replace("-", "_")
        width, height, pixels = decode_png(os.path.join(src, filename))

        if not is_greyscale(pixels):
            sys.exit(f"{filename}: art must be greyscale")
        if width % 2 or height % 2:
            sys.exit(f"{filename}: {width}x{height} does not halve")

        mask = to_mask(pixels)
        half_w, half_h = width // 2, height // 2
        alphas = [
            (mask[2 * y * width + 2 * x]
             + mask[2 * y * width + 2 * x + 1]
             + mask[(2 * y + 1) * width + 2 * x]
             + mask[(2 * y + 1) * width + 2 * x + 1] + 2) // 4
            for y in range(half_h)
            for x in range(half_w)
        ]

        for tint in ART_TINTS:
            rgb = bytes([tint >> 16, (tint >> 8) & 0xFF, tint & 0xFF])
            data = b"".join(rgb + bytes([alpha]) for alpha in alphas)
            assert len(data) == half_w * half_h * 4

            target = os.path.join(out, f"{name}@{half_w}x{half_h}.{tint:06x}.rgba")
            total += len(data)

            if check:
                state = "same" if _same(target, data) else "differs"
                print(f"{filename:24} -> {os.path.basename(target):33} {state}")
            else:
                with open(target, "wb") as handle:
                    handle.write(data)
                written.append(os.path.basename(target))
                print(f"{filename:24} -> {os.path.basename(target):33} {len(data):6} bytes")

    print(f"\n{len(sources)} pictures, {total} bytes total\n")

    if not check:
        _prune(out, written)


def _same(path, data):
    return os.path.exists(path) and open(path, "rb").read() == data


def _prune(out, written):
    """Drop outputs whose source PNG is gone, so a rename cannot leave a stale icon."""
    for stale in sorted(set(os.listdir(out)) - set(written)):
        if stale.endswith((".rgba", ".mask")):
            os.remove(os.path.join(out, stale))
            print(f"removed stale {stale}")


if __name__ == "__main__":
    main()
