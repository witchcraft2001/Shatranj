#!/usr/bin/env python3
"""Pack the About screen for mode #82 (640x256x4bpp) into asset pages.

Reads ONLY the committed, already-palettised assets/sprinter/about640.png
(tools/prepare_sprinter_about.py writes it; an artist may repaint it). This
tool is pure bit-packing -- no quantisation, no resampling -- so its output
is a byte-for-byte function of its input, which is what lets `make
sprinter-check` gate the smoke image on determinism. The lossy step lives
in the manual prep tool for exactly that reason (see its docstring).

WHY THE IMAGE IS STORED IN TWO HALVES. The renderer for this screen is the
resident gfx_draw_tile (asm/sprinter/gfx_core.asm) -- reused rather than
given a new full-width routine, because all three resident pools were full
when the About screen was written (WIN1 8 bytes free, WIN2 40, the WIN3
cold page 0). That routine takes its source stride from the ONE-BYTE
tile_stride cell, so a 512-pixel row (256 bytes) cannot be expressed. Two
256-pixel halves can: 128 bytes per row, stride 128. The halves are blitted
side by side and the seam is invisible because it falls on a byte boundary
with no filtering anywhere in the path.

PAGE LAYOUT (4 pages, 16384 bytes each = exactly 512*256/2 bytes total, no
padding):

    page 0   left  half, rows   0..127
    page 1   left  half, rows 128..255
    page 2   right half, rows   0..127
    page 3   right half, rows 128..255

128 rows/page is 16384/128 -- so within a page, row N starts at N*128, and
a 16-row blit chunk starts at slot (N*128)/256 = N/2. gfx_draw_tile
addresses its source as slot*256, so every chunk boundary the overlay uses
lands on a whole slot by construction.

PIXEL FORMAT. 4bpp, row-major, HIGH nibble = LEFT pixel -- the same
convention tools/build_sprinter_ui_assets.py packs tiles with. Unlike that
tool there is no #FF transparency key here: the About blit is opaque
(VRAM_ALIAS_OPAQUE), so index 15 is an ordinary colour and a whole #FF byte
is two ordinary pixels.

PALETTE. 48 bytes, 16 entries x 3 bytes RGB8 -- byte-identical in shape to
the resident's own palette_rgb table (build/sprinter/generated/
palette_base.inc), so the overlay can hand it to the same
write_palette_entry the theme code already uses. The About screen is a
full-screen takeover and owns all 16 entries while it is up; the overlay
restores the theme palette on exit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

DEFAULT_INPUT = ROOT / "assets/sprinter/about640.png"

IMAGE_W, IMAGE_H = 512, 256
HALF_W = IMAGE_W // 2            # 256 pixels
HALF_BYTES = HALF_W // 2         # 128 bytes per row per half
PAGE_SIZE = 16384
ROWS_PER_PAGE = PAGE_SIZE // HALF_BYTES   # 128
PAGE_COUNT = 4
PALETTE_COLORS = 16
PALETTE_SIZE = PALETTE_COLORS * 3

# The caption palette contract, re-checked here so a repainted or
# regenerated about640.png cannot silently take the two reserved entries
# back. tools/prepare_sprinter_about.py's own docstring explains why they
# are reserved; asm/sprinter/zcc/about_sprinter.asm hardcodes the pair as
# its text colour byte (bg<<4|fg).
IMAGE_COLORS = 14
CAPTION_BG_INDEX = 14
CAPTION_FG_INDEX = 15

MANIFEST_FORMAT = "shatranj-sprinter-about-v1"


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def load_indexed(path: Path) -> Image.Image:
    if not path.is_file():
        fail(f"missing About asset: {path}")
    image = Image.open(path)
    if image.mode != "P":
        fail(f"{path}: mode is {image.mode}, expected a palettised 'P' image "
             "(regenerate with tools/prepare_sprinter_about.py)")
    if image.size != (IMAGE_W, IMAGE_H):
        fail(f"{path}: size is {image.size}, expected {(IMAGE_W, IMAGE_H)}")
    indices = image.tobytes()
    if len(indices) != IMAGE_W * IMAGE_H:
        fail(f"{path}: index stream is {len(indices)} bytes, expected "
             f"{IMAGE_W * IMAGE_H}")
    highest = max(indices)
    if highest >= PALETTE_COLORS:
        fail(f"{path}: uses palette index {highest}, but mode #82 is 4bpp -- "
             f"only 0..{PALETTE_COLORS - 1} exist")
    if highest >= IMAGE_COLORS:
        fail(f"{path}: uses palette index {highest}, but indices "
             f"{CAPTION_BG_INDEX}/{CAPTION_FG_INDEX} are reserved for the "
             f"About caption -- the artwork may only use 0..{IMAGE_COLORS - 1} "
             "(regenerate with tools/prepare_sprinter_about.py)")
    return image


def build_palette(image: Image.Image) -> bytes:
    raw = list(image.getpalette() or [])
    raw = (raw + [0] * PALETTE_SIZE)[:PALETTE_SIZE]
    return bytes(raw)


def build_pages(image: Image.Image) -> list[bytes]:
    indices = image.tobytes()
    pages: list[bytes] = []
    for half in range(2):
        x0 = half * HALF_W
        for page_in_half in range(2):
            row0 = page_in_half * ROWS_PER_PAGE
            out = bytearray(PAGE_SIZE)
            pos = 0
            for row in range(row0, row0 + ROWS_PER_PAGE):
                base = row * IMAGE_W + x0
                for bx in range(HALF_BYTES):
                    left = indices[base + bx * 2]
                    right = indices[base + bx * 2 + 1]
                    out[pos] = (left << 4) | right
                    pos += 1
            if pos != PAGE_SIZE:
                fail(f"page {len(pages)} packed {pos} bytes, expected {PAGE_SIZE}")
            pages.append(bytes(out))
    if len(pages) != PAGE_COUNT:
        fail(f"packed {len(pages)} pages, expected {PAGE_COUNT}")
    return pages


def self_test() -> int:
    # A synthetic image whose every pixel encodes its own position, so a
    # transposed half, a flipped nibble or an off-by-one row shows up.
    img = Image.new("P", (IMAGE_W, IMAGE_H))
    img.putpalette([(i * 7) % 256 for i in range(PALETTE_SIZE)])
    px = bytearray(IMAGE_W * IMAGE_H)
    for y in range(IMAGE_H):
        for x in range(IMAGE_W):
            px[y * IMAGE_W + x] = (x + y) % PALETTE_COLORS
    img.frombytes(bytes(px))

    pages = build_pages(img)
    assert len(pages) == PAGE_COUNT
    assert all(len(p) == PAGE_SIZE for p in pages)

    # page 0 = left half, row 0: pixels (0,0) and (1,0) -> nibbles 0 and 1.
    assert pages[0][0] == 0x01, hex(pages[0][0])
    # page 1 = left half, row 128: first pixel is (0,128) -> 128 % 16 = 0.
    assert pages[1][0] == 0x01, hex(pages[1][0])
    # page 2 = right half, row 0: first pixel is (256,0) -> 256 % 16 = 0.
    assert pages[2][0] == 0x01, hex(pages[2][0])
    # Round trip one interior pixel through the packing to pin the nibble
    # order (HIGH nibble = LEFT pixel).
    y, x = 5, 300                       # right half, column 44
    byte = pages[2][(y * HALF_BYTES) + (x - HALF_W) // 2]
    expect_hi = (x + y) % PALETTE_COLORS
    expect_lo = (x + 1 + y) % PALETTE_COLORS
    assert byte == (expect_hi << 4 | expect_lo), hex(byte)

    pal = build_palette(img)
    assert len(pal) == PALETTE_SIZE
    assert build_pages(img) == pages, "not deterministic"
    print("[OK] Sprinter About packer self-test")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    ap.add_argument("--palette-out", type=Path)
    ap.add_argument("--pages-out-prefix", type=Path)
    ap.add_argument("--palette-inc-out", type=Path,
                    help="same 16 entries as --palette-out, but as a "
                          "z88dk-z80asm source include for the ABOUT overlay "
                          "(which is assembled, not linked against a blob)")
    ap.add_argument("--manifest-out", type=Path)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.palette_out or not args.pages_out_prefix:
        ap.error("--palette-out and --pages-out-prefix are required "
                 "unless --self-test")

    image = load_indexed(args.input)
    palette = build_palette(image)
    pages = build_pages(image)

    args.palette_out.parent.mkdir(parents=True, exist_ok=True)
    args.palette_out.write_bytes(palette)

    if args.palette_inc_out:
        # Emitted as SOURCE, not a binary to BINARY/INCBIN: the overlay is
        # assembled by z88dk-z80asm, and this repo has no precedent for
        # binary inclusion on that side -- but it does have one for exactly
        # this shape, build/sprinter/generated/palette_base.inc.
        lines = [
            "; Generated by tools/build_sprinter_about.py from "
            "assets/sprinter/about640.png. Do not edit by hand.",
            "; The About screen's own 16-entry palette, in write_palette's "
            "R,G,B-per-entry layout.",
            "",
            # Same SECTION as the overlay's code objects: without it this
            # object lands in the default section, which z80asm emits
            # BEFORE code_user -- putting palette bytes at the overlay's
            # ORG, where ovl_dispatch expects the entry table.
            "        SECTION code_user",
            "",
            "        PUBLIC about_palette_rgb",
            "about_palette_rgb:",
        ]
        for i in range(PALETTE_COLORS):
            r, g, b = palette[i * 3:i * 3 + 3]
            if i == CAPTION_BG_INDEX:
                note = "  ; caption background (reserved)"
            elif i == CAPTION_FG_INDEX:
                note = "  ; caption foreground (reserved)"
            else:
                note = f"  ; {i}"
            lines.append(f"        defb 0x{r:02X},0x{g:02X},0x{b:02X}{note}")
        args.palette_inc_out.parent.mkdir(parents=True, exist_ok=True)
        args.palette_inc_out.write_text("\n".join(lines) + "\n")
    written = []
    for i, page in enumerate(pages):
        path = args.pages_out_prefix.with_name(
            f"{args.pages_out_prefix.name}{i}.bin")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(page)
        written.append(path)

    if args.manifest_out:
        manifest = {
            "format": MANIFEST_FORMAT,
            "image": {"width": IMAGE_W, "height": IMAGE_H,
                       "half_bytes": HALF_BYTES,
                       "rows_per_page": ROWS_PER_PAGE},
            "pages": PAGE_COUNT,
            "page_size": PAGE_SIZE,
            "palette_bytes": PALETTE_SIZE,
            "sha256": {
                "source_png": hashlib.sha256(
                    args.input.read_bytes()).hexdigest(),
                "palette": hashlib.sha256(palette).hexdigest(),
                "pages": [hashlib.sha256(p).hexdigest() for p in pages],
            },
        }
        args.manifest_out.parent.mkdir(parents=True, exist_ok=True)
        args.manifest_out.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print(f"[OK] About packed: {PALETTE_SIZE}-byte palette + "
          f"{PAGE_COUNT} x {PAGE_SIZE} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
