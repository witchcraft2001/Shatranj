#!/usr/bin/env python3
"""Generate the point-marker and square-frame PNGs for the board.

Manual, one-off tool (mirrors tools/rasterize_sprinter_pieces.py and
tools/prepare_sprinter_logo.py -- never part of the build): port.md section
3.6 draws frames/corners as accelerator fills, but point markers (move
hint, last move, ...) as small tiles through the hardware transparency key.
This generates the two markers scene_s4.asm demonstrates the key with:
"dot" (palette index 9, hud_hint -- the legal-move-hint marker) and "ring"
(index 10, hud_lastmove -- the last-move marker), both 16x8.

It also generates the two board-cursor frames (S5 substep 3c), which are
whole-cell 48x24 outlines rather than point markers, because that is what
ZX/Next actually draw: asm/spectrum/screen.asm's draw_square_mark paints a
one-pixel rectangle around the 2x2-character square, and adds a SECOND,
inner rectangle when the square is the selected one (its `mark_mode`
branch) -- Next carries the same distinction as its marker sprite's
NEXT_MARKER_FLAG_MARK / _SELECTED flags. So:

    cursor.png    single hairline frame  -- where the cursor is
    select.png    double hairline frame  -- the picked-up piece's square

Frame thickness is one byte-pair (2px) horizontally and one row
vertically, which is a visually even hairline in mode #82: its pixels are
about half as wide as they are tall, so 2px across reads the same weight
as 1px down (and matches ZX's own 1px frame proportionally).

Colours are the palette's own declared roles: hud_select (index 8,
"Selected square highlight") for the selection frame, accent (index 14)
for the cursor frame. NOT index 15, despite it being named "cursor": in a
keyed tile the nibble value 15 IS the hardware transparency code, so an
index-15 pixel is a hole, not a colour (build_sprinter_ui_assets.py's
KEYED_OPAQUE_INDICES enforces this). Index 15's palette entry stays what
its name says for the text input line, which is painted by text640, not
through the key.

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

# One whole board cell: BOARD_CELL_W/H in build/sprinter/generated/
# render_layout.inc (48x24 px = 24 bytes x 24 rows at 4bpp). Kept as
# literals here the same way MARKER_W/H are -- this is a manual art tool
# whose output is committed; build_sprinter_ui_assets.py is the place that
# pins the sizes for the build.
FRAME_W, FRAME_H = 48, 24
CURSOR_INDEX = 14   # accent -- see the module docstring on index 15
SELECT_INDEX = 8    # hud_select
FRAME_INNER_INSET = 2   # blocks/rows between the outer and inner hairline


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


def build_frame(color_rgb: tuple[int, int, int], double: bool,
                w_px: int = FRAME_W, h_px: int = FRAME_H) -> Image.Image:
    """A hairline rectangle around the whole cell; `double` adds a second
    rectangle inset by FRAME_INNER_INSET, which is how screen.asm's
    draw_square_mark distinguishes the selected square from the cursor."""
    inset = FRAME_INNER_INSET

    def on_rect(bx: int, y: int, bw: int, h: int, d: int) -> bool:
        if bx < d or y < d or bx >= bw - d or y >= h - d:
            return False
        return bx == d or y == d or bx == bw - 1 - d or y == h - 1 - d

    def inside(bx: int, y: int, bw: int, h: int) -> bool:
        if on_rect(bx, y, bw, h, 0):
            return True
        return double and on_rect(bx, y, bw, h, inset)

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
    cursor = build_frame(_rgb(palette, CURSOR_INDEX), double=False)
    select = build_frame(_rgb(palette, SELECT_INDEX), double=True)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, image in (("dot", dot), ("ring", ring),
                        ("cursor", cursor), ("select", select)):
        path = args.out_dir / f"{name}.png"
        image.save(path)
        print(f"[OK] {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
