#!/usr/bin/env python3
"""Pack the S4 About screen image for mode #81 (320x256x8bpp).

Reads only the committed assets/sprinter/about.png (320x256 RGB, prepared
manually once -- see the module docstring's "Manual prep" note below for
the exact command used) and quantizes it to 256 colours with MEDIANCUT
(anti-aliasing is fine here: mode #81 is a photo-style full-screen image,
not a hardware-keyed tile, so port.md section 4's "no AA" rule for tiles
does not apply).

Deliberately NOT wired into the Sprinter EXE build (port.md section 4/S4
decision D4): nothing consumes the About screen until S9's mode-switch UI
(SetVMod #82 -> #81 -> #82 is itself a mechanic already proven by S1's
mode_switch_probe, but *displaying* this image is S9's job, not S4's).
Keeping it out of the EXE also keeps make sprinter-check's smoke-image
byte-determinism gate independent of the Pillow version's MEDIANCUT
implementation, which is not guaranteed stable release to release.

Output format, matching the hardware palette-register layout the port
already writes for mode #82 (asm/sprinter/video_s1.asm's
write_palette_entry: R, G, B, then a zeroed 4th byte, per entry -- port.md
section 3.6's "R,G,B,0 x 256, writer format"):

    palette:  256 x 4 bytes = 1024 bytes (R, G, B, 0)
    pixels:   320*256 = 81920 bytes, row-major 8bpp, split into 5 x 16384-
              byte pages (the same page size every other Sprinter asset
              page uses)

Manual prep (one-off, not part of the build): the source photo
assets/pc-client/about/about-shatranj.png is 1254x1254 (square) -- a
centre-crop to 320:256 would clip the "Shatranj" title sitting close to
the bottom edge, so it is pillarboxed instead (zero content loss, and the
source's own edges are already near-black so the bars blend in):

    from PIL import Image
    src = Image.open("assets/pc-client/about/about-shatranj.png").convert("RGB")
    scaled = src.resize((256, 256), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (320, 256), (0, 0, 0))
    canvas.paste(scaled, (32, 0))
    canvas.save("assets/sprinter/about.png")
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

TARGET_W, TARGET_H = 320, 256
PALETTE_COLORS = 256
PALETTE_ENTRY_SIZE = 4  # R, G, B, 0
PALETTE_SIZE = PALETTE_COLORS * PALETTE_ENTRY_SIZE  # 1024
PAGE_SIZE = 16384
PIXEL_TOTAL = TARGET_W * TARGET_H  # 81920
PAGE_COUNT = -(-PIXEL_TOTAL // PAGE_SIZE)  # 5

DEFAULT_INPUT = Path("assets/sprinter/about.png")


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def quantize(image: Image.Image) -> Image.Image:
    if image.size != (TARGET_W, TARGET_H):
        fail(f"input is {image.size}, expected {(TARGET_W, TARGET_H)}")
    rgb = image.convert("RGB")
    method = getattr(getattr(Image, "Quantize", None), "MEDIANCUT", 0)
    return rgb.quantize(colors=PALETTE_COLORS, method=method)


def build_palette_bytes(quantized: Image.Image) -> bytes:
    raw = quantized.getpalette() or []
    raw = (raw + [0] * (PALETTE_COLORS * 3))[:PALETTE_COLORS * 3]
    out = bytearray(PALETTE_SIZE)
    for i in range(PALETTE_COLORS):
        r, g, b = raw[i * 3:i * 3 + 3]
        out[i * 4:i * 4 + 4] = bytes((r, g, b, 0))
    return bytes(out)


def build_pixel_pages(quantized: Image.Image) -> list[bytes]:
    flat = quantized.tobytes()
    if len(flat) != PIXEL_TOTAL:
        fail(f"quantized pixel stream is {len(flat)} bytes, expected {PIXEL_TOTAL}")
    padded = flat + bytes(PAGE_COUNT * PAGE_SIZE - PIXEL_TOTAL)
    return [padded[i * PAGE_SIZE:(i + 1) * PAGE_SIZE] for i in range(PAGE_COUNT)]


def reconstruct_preview(palette_bytes: bytes, pixel_pages: list[bytes]) -> Image.Image:
    """Decodes the packed outputs back into an RGB image -- proves the
    round trip is lossless relative to the quantized source, for the
    preview a human reviews."""
    flat_pixels = b"".join(pixel_pages)[:PIXEL_TOTAL]
    img = Image.frombytes("P", (TARGET_W, TARGET_H), flat_pixels)
    pal_rgb = []
    for i in range(PALETTE_COLORS):
        r, g, b, _reserved = palette_bytes[i * 4:i * 4 + 4]
        pal_rgb += [r, g, b]
    img.putpalette(pal_rgb)
    return img.convert("RGB")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--palette-out", required=True, type=Path)
    parser.add_argument("--pages-out-prefix", required=True, type=Path)
    parser.add_argument("--preview-out", type=Path, default=None)
    args = parser.parse_args()

    if not args.input.is_file():
        fail(f"missing input: {args.input}")

    quantized = quantize(Image.open(args.input))
    palette_bytes = build_palette_bytes(quantized)
    pages = build_pixel_pages(quantized)

    args.palette_out.parent.mkdir(parents=True, exist_ok=True)
    args.palette_out.write_bytes(palette_bytes)
    print(f"[OK] {args.palette_out}: {len(palette_bytes)} bytes")

    args.pages_out_prefix.parent.mkdir(parents=True, exist_ok=True)
    for i, page in enumerate(pages):
        page_path = args.pages_out_prefix.with_name(
            f"{args.pages_out_prefix.name}{i}.bin"
        )
        page_path.write_bytes(page)
        print(f"[OK] {page_path}: {len(page)} bytes")

    if args.preview_out is not None:
        preview = reconstruct_preview(palette_bytes, pages)
        args.preview_out.parent.mkdir(parents=True, exist_ok=True)
        preview.save(args.preview_out)
        print(f"[OK] {args.preview_out}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
