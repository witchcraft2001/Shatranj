#!/usr/bin/env python3
"""Generate the two demo point-marker PNGs for the S4 scene.

Manual, one-off tool (mirrors tools/rasterize_sprinter_pieces.py and
tools/prepare_sprinter_logo.py -- never part of the build): port.md section
3.6 draws frames/corners as accelerator fills, but point markers (move
hint, last move, ...) as small tiles through the hardware transparency key.
This generates the two markers scene_s4.asm demonstrates the key with:
"dot" (palette index 9, hud_hint -- the legal-move-hint marker) and "ring"
(index 10, hud_lastmove -- the last-move marker), both 16x8.

Transparency is constructed in even-aligned pixel PAIRS by design, not
validated after the fact: each output pixel is decided at 2-pixel-block
granularity (both pixels in a byte-pair opaque or both transparent), which
is what tools/build_sprinter_ui_assets.py's packer requires -- the
hardware alias skips whole #FF bytes, not single nibbles (the same rule
make_sprinter_assets_page.py's _key_tile already follows for the S1/S2
bench fixture).
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import gen_sprinter_palette as gsp  # noqa: E402

DEFAULT_PALETTE = ROOT / "assets/sprinter/palette.json"
DEFAULT_OUT_DIR = ROOT / "assets/sprinter/markers"

MARKER_W, MARKER_H = 16, 8
DOT_INDEX = 9     # hud_hint
RING_INDEX = 10   # hud_lastmove


def _uniform_pair_tile(color_rgb: tuple[int, int, int], w_px: int, h_px: int,
                        inside) -> Image.Image:
    """inside(block_x, y, block_w, h) -> bool decides opacity for BOTH
    pixels of byte-pair block_x at once, guaranteeing pair-uniform alpha
    by construction."""
    img = Image.new("RGBA", (w_px, h_px), (0, 0, 0, 0))
    block_w = w_px // 2
    for y in range(h_px):
        for bx in range(block_w):
            if inside(bx, y, block_w, h_px):
                img.putpixel((2 * bx, y), color_rgb + (255,))
                img.putpixel((2 * bx + 1, y), color_rgb + (255,))
    return img


def build_dot(color_rgb: tuple[int, int, int], w_px: int = MARKER_W,
              h_px: int = MARKER_H) -> Image.Image:
    block_w = w_px // 2
    cx, cy = (block_w - 1) / 2.0, (h_px - 1) / 2.0
    radius = min(block_w, h_px) * 0.28

    def inside(bx: int, y: int, bw: int, h: int) -> bool:
        dx, dy = bx - cx, y - cy
        return dx * dx + dy * dy <= radius * radius

    return _uniform_pair_tile(color_rgb, w_px, h_px, inside)


def build_ring(color_rgb: tuple[int, int, int], w_px: int = MARKER_W,
               h_px: int = MARKER_H) -> Image.Image:
    block_w = w_px // 2
    cx, cy = (block_w - 1) / 2.0, (h_px - 1) / 2.0
    r_out = min(block_w, h_px) * 0.46
    r_in = r_out - 1.3

    def inside(bx: int, y: int, bw: int, h: int) -> bool:
        dx, dy = bx - cx, y - cy
        d2 = dx * dx + dy * dy
        return r_in * r_in <= d2 <= r_out * r_out

    return _uniform_pair_tile(color_rgb, w_px, h_px, inside)


def _rgb(palette: dict, index: int) -> tuple[int, int, int]:
    entry = next(e for e in palette["base"] if e["index"] == index)
    return gsp._parse_rgb(entry["rgb"], "marker")


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--palette", type=Path, default=DEFAULT_PALETTE)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    palette = gsp.load_palette_file(args.palette)
    errors = gsp.validate_palette(palette)
    if errors:
        raise SystemExit(f"Error: {args.palette} is invalid: " + "; ".join(errors))

    dot = build_dot(_rgb(palette, DOT_INDEX))
    ring = build_ring(_rgb(palette, RING_INDEX))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    dot_path = args.out_dir / "dot.png"
    ring_path = args.out_dir / "ring.png"
    dot.save(dot_path)
    ring.save(ring_path)
    print(f"[OK] {dot_path}")
    print(f"[OK] {ring_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
