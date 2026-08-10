#!/usr/bin/env python3
"""Build the Sprinter S2 assets page: font + deterministic bench test tiles.

port.md section 3.3 maps the AFNT640 proportional font ("font.bin", the
6888-byte original Anton format) into WIN0 for the duration of a text
string instead of baking it into the flat 32 KiB resident. This tool packs
that font, plus a handful of deterministic 32x16/40x20 test tiles used by
asm/sprinter/bench_s2.asm, into one 16384-byte "asset page" -- the same
64-slot/256-byte-per-slot model gfx640.asm's tile blitter uses (slot*256 =
byte offset within the page).

Slot layout (asm/sprinter/bench_s2.asm's ASSET_* EQUs must match):
    0..26   font.bin (6888 bytes, zero-padded to fill slot 26)
    27      unused (zero)
    28      TILE_A: opaque 32x16 checker, colours 2/3 (board squares)
    29      TILE_B: opaque 32x16 checker, colours 4/5 (white piece body/outline)
    30      TILE_KEY: 32x16 diamond, colour 8 on a #FF hardware-key background
    31      TILE_C: opaque 32x16 checker, colours 6/7 (black piece body/outline)
    32..33  TILE_WIDE: opaque 40x20 checker, colours 9/10 (512-byte aligned:
            32*256 = 8192 = 16*512, proving the parametric blitter's second
            stride)
    34..35  unused (zero) -- gap before the overlay probe
    36..43  dummy overlay (S3, asm/sprinter/dummy_overlay.asm): exactly
            2048 bytes, copied at runtime by ovl_s3.asm's ovl_exec via
            win0_map_di/LDIR/win0_restore into OVL_SLOT (#7800)
    44..63  unused (zero)

Tiles are generated in code, not stored as binary fixtures, so the page is
reproducible from this file plus the pinned extern/sprinter-libs font.bin
alone. The output is a pure function of the inputs (no timestamps).
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PAGE_SIZE = 16384
SLOT_SIZE = 256

FONT_BIN_SIZE = 6888
FONT_SLOT_BASE = 0
FONT_SLOT_COUNT = -(-FONT_BIN_SIZE // SLOT_SIZE)  # ceil division = 27

TILE_A_SLOT = 28
TILE_B_SLOT = 29
TILE_KEY_SLOT = 30
TILE_C_SLOT = 31
TILE_WIDE_SLOT = 32
TILE_WIDE_SLOTS = 2

OVERLAY_SLOT = 36
OVERLAY_SLOTS = 8
OVERLAY_SIZE = OVERLAY_SLOTS * SLOT_SIZE  # 2048

TILE32_W, TILE32_H, TILE32_STRIDE = 32, 16, 16
TILE40_W, TILE40_H, TILE40_STRIDE = 40, 20, 20


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def _checker_tile(color_a: int, color_b: int, w_px: int, h_px: int,
                   stride: int, block: int = 4) -> bytes:
    """Row-major raster, one byte per 2 packed pixels, high nibble = left."""
    rows = bytearray()
    for y in range(h_px):
        row = bytearray(stride)
        for bx in range(w_px // 2):
            square_l = ((2 * bx) // block + y // block) % 2
            square_r = ((2 * bx + 1) // block + y // block) % 2
            left = color_a if square_l == 0 else color_b
            right = color_a if square_r == 0 else color_b
            row[bx] = ((left & 0xF) << 4) | (right & 0xF)
        rows += row
    data = bytes(rows)
    assert len(data) == stride * h_px
    return data


def _key_tile(color_inside: int, w_px: int, h_px: int, stride: int) -> bytes:
    """Row-major raster with a diamond of color_inside on a #FF (hardware
    transparency key) background. Fully byte-granular (no mixed-nibble
    bytes): the hardware alias skips whole #FF bytes, not single nibbles
    (port.md section 3.3), so every byte here is either fully opaque
    (both nibbles = color_inside) or fully the #FF key."""
    rows = bytearray()
    cx, cy = w_px / 2.0, h_px / 2.0
    for y in range(h_px):
        row = bytearray(stride)
        for bx in range(w_px // 2):
            px = 2 * bx
            dx = abs(px + 0.5 - cx)
            dy = abs(y + 0.5 - cy)
            inside = (dx / (w_px / 2.0) + dy / (h_px / 2.0)) <= 0.65
            row[bx] = ((color_inside & 0xF) << 4) | (color_inside & 0xF) if inside else 0xFF
        rows += row
    data = bytes(rows)
    assert len(data) == stride * h_px
    return data


def build_assets_page(font_bin: bytes, overlay_bin: bytes | None = None) -> bytes:
    if len(font_bin) != FONT_BIN_SIZE:
        fail(f"font.bin is {len(font_bin)} bytes, expected {FONT_BIN_SIZE}")
    if overlay_bin is not None and len(overlay_bin) != OVERLAY_SIZE:
        fail(f"overlay-bin is {len(overlay_bin)} bytes, expected "
             f"{OVERLAY_SIZE} (the fixed OVL_SLOT size)")

    page = bytearray(PAGE_SIZE)
    page[0:len(font_bin)] = font_bin

    def place(slot: int, data: bytes, expected_slots: int) -> None:
        offset = slot * SLOT_SIZE
        span = expected_slots * SLOT_SIZE
        if len(data) > span:
            fail(f"tile at slot {slot} is {len(data)} bytes, exceeds "
                 f"{expected_slots} slot(s) ({span} bytes)")
        page[offset:offset + len(data)] = data

    place(TILE_A_SLOT, _checker_tile(2, 3, TILE32_W, TILE32_H, TILE32_STRIDE), 1)
    place(TILE_B_SLOT, _checker_tile(4, 5, TILE32_W, TILE32_H, TILE32_STRIDE), 1)
    place(TILE_KEY_SLOT, _key_tile(8, TILE32_W, TILE32_H, TILE32_STRIDE), 1)
    place(TILE_C_SLOT, _checker_tile(6, 7, TILE32_W, TILE32_H, TILE32_STRIDE), 1)
    place(TILE_WIDE_SLOT, _checker_tile(9, 10, TILE40_W, TILE40_H, TILE40_STRIDE),
          TILE_WIDE_SLOTS)
    if overlay_bin is not None:
        place(OVERLAY_SLOT, overlay_bin, OVERLAY_SLOTS)

    data = bytes(page)
    assert len(data) == PAGE_SIZE
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font-bin", type=Path,
                        default=Path("extern/sprinter-libs/afnt640/font.bin"))
    parser.add_argument("--overlay-bin", type=Path,
                        help="S3 dummy overlay (asm/sprinter/dummy_overlay.asm "
                             "build product); omit to leave slots 36-43 zero")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not args.font_bin.is_file():
        fail(f"missing font.bin: {args.font_bin} "
             "(run 'git submodule update --init extern/sprinter-libs')")

    overlay_bin = None
    if args.overlay_bin is not None:
        if not args.overlay_bin.is_file():
            fail(f"missing overlay-bin: {args.overlay_bin}")
        overlay_bin = args.overlay_bin.read_bytes()

    page = build_assets_page(args.font_bin.read_bytes(), overlay_bin)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(page)
    digest = hashlib.sha256(page).hexdigest()
    print(f"[OK] {args.output}: {len(page)} bytes, sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
