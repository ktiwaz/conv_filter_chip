#!/usr/bin/env python3
"""Image / hex helpers for the single-FPGA testbench.

Hex formats:
  hex8  - one 8-bit pixel per line (input_image.hex, jtb_read_capture output)
  hex32 - four pixels per 32-bit word, little-endian (pixel 4i in bits [7:0]),
          used to initialize the input RAM.

Commands:
  pack     <in.hex8> <out.hex32>
  png2hex  <in.png>  <out.hex8> [--size 128]   (requires Pillow)
  hex2png  <in.hex8> <out.png>  [--width 128] [--scale N] [--offset K]
           (no Pillow needed; --offset places pixel k at k+K, e.g. 258 to
           line a DUT output up with its input as on the HDMI display)
  compare  <a.hex8>  <b.hex8>   [--count N]
"""
import argparse
import struct
import sys
import zlib


def read_hex8(path):
    with open(path) as f:
        return [int(tok, 16) & 0xFF for tok in f.read().split()]


def write_hex8(path, pixels):
    with open(path, "w") as f:
        f.writelines(f"{p:02x}\n" for p in pixels)


def cmd_pack(args):
    pixels = read_hex8(args.input)
    pixels += [0] * (-len(pixels) % 4)
    with open(args.output, "w") as f:
        for i in range(0, len(pixels), 4):
            word = (pixels[i] | pixels[i + 1] << 8 |
                    pixels[i + 2] << 16 | pixels[i + 3] << 24)
            f.write(f"{word:08x}\n")


def cmd_png2hex(args):
    from PIL import Image
    img = Image.open(args.input).convert("L")
    if img.size != (args.size, args.size):
        img = img.resize((args.size, args.size))
    write_hex8(args.output, list(img.getdata()))


def write_png_gray(path, width, height, pixels):
    """Write an 8-bit grayscale PNG using only the standard library."""
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(pixels[y * width:(y + 1) * width]) for y in range(height))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def cmd_hex2png(args):
    pixels = read_hex8(args.input)
    if args.offset:
        placed = [0] * (args.width * args.width)
        for k, p in enumerate(pixels):
            if k + args.offset < len(placed):
                placed[k + args.offset] = p
        pixels = placed
    width = args.width
    height = len(pixels) // width
    pixels = pixels[:width * height]
    n = args.scale
    if n > 1:
        rows = [pixels[y * width:(y + 1) * width] for y in range(height)]
        pixels = [p for row in rows for _ in range(n) for p in row for _ in range(n)]
        width, height = width * n, height * n
    write_png_gray(args.output, width, height, pixels)


def cmd_compare(args):
    a = read_hex8(args.a)
    b = read_hex8(args.b)
    n = args.count if args.count is not None else max(len(a), len(b))
    if len(a) < n or len(b) < n:
        print(f"length mismatch: {args.a} has {len(a)}, {args.b} has {len(b)}, comparing {n}")
        return 1
    diffs = [i for i in range(n) if a[i] != b[i]]
    if not diffs:
        print(f"MATCH: {n} pixels identical")
        return 0
    i = diffs[0]
    print(f"MISMATCH: {len(diffs)} of {n} pixels differ; "
          f"first at index {i}: {a[i]:02x} vs {b[i]:02x}")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pack")
    p.add_argument("input")
    p.add_argument("output")
    p.set_defaults(func=cmd_pack)

    p = sub.add_parser("png2hex")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--size", type=int, default=128)
    p.set_defaults(func=cmd_png2hex)

    p = sub.add_parser("hex2png")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--width", type=int, default=128)
    p.add_argument("--scale", type=int, default=1)
    p.add_argument("--offset", type=int, default=0)
    p.set_defaults(func=cmd_hex2png)

    p = sub.add_parser("compare")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--count", type=int)
    p.set_defaults(func=cmd_compare)

    args = parser.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
