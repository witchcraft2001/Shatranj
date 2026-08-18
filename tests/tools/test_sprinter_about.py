#!/usr/bin/env python3
"""Unit tests for tools/build_sprinter_about.py (S9 About screen packer).

Unlike the S4 packer this replaces, the quantiser is NOT part of the build
any more (tools/prepare_sprinter_about.py runs by hand and its result is
committed), so this suite can and does pin exact bytes: the packing is pure
bit-shuffling and must be reproducible for `make sprinter-check`'s smoke
image determinism gate to mean anything.

The committed-asset tests are the ones that would catch an artist's repaint
breaking the contract -- wrong size, a stray index in the two reserved
caption entries, or a palette that no longer has 16 usable entries.
"""

from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build_sprinter_about as bsa  # noqa: E402

ABOUT_PNG = ROOT / "assets/sprinter/about640.png"


def _synthetic() -> Image.Image:
    """Every pixel encodes its own position, so a transposed half, a
    flipped nibble or an off-by-one row is visible in the output."""
    img = Image.new("P", (bsa.IMAGE_W, bsa.IMAGE_H))
    img.putpalette([(i * 7) % 256 for i in range(bsa.PALETTE_SIZE)])
    px = bytearray(bsa.IMAGE_W * bsa.IMAGE_H)
    for y in range(bsa.IMAGE_H):
        for x in range(bsa.IMAGE_W):
            px[y * bsa.IMAGE_W + x] = (x + y) % bsa.PALETTE_COLORS
    img.frombytes(bytes(px))
    return img


class PackingTests(unittest.TestCase):
    def test_exactly_four_pages_of_16384_bytes(self) -> None:
        pages = bsa.build_pages(_synthetic())
        self.assertEqual(len(pages), 4)
        for page in pages:
            self.assertEqual(len(page), bsa.PAGE_SIZE)

    def test_pages_cover_every_pixel_with_no_padding(self) -> None:
        # 512*256 pixels at 2 per byte is exactly 4 * 16384.
        self.assertEqual(bsa.IMAGE_W * bsa.IMAGE_H // 2,
                         4 * bsa.PAGE_SIZE)

    def test_high_nibble_is_the_left_pixel(self) -> None:
        pages = bsa.build_pages(_synthetic())
        # Right half (pages 2/3), row 5, image column 300.
        y, x = 5, 300
        byte = pages[2][y * bsa.HALF_BYTES + (x - bsa.HALF_W) // 2]
        self.assertEqual(byte >> 4, (x + y) % bsa.PALETTE_COLORS)
        self.assertEqual(byte & 0x0F, (x + 1 + y) % bsa.PALETTE_COLORS)

    def test_page_order_is_left_top_left_bottom_right_top_right_bottom(self) -> None:
        """The overlay derives BOTH the destination column and the starting
        row from the page index alone (bit 1 = half, bit 0 = top/bottom), so
        this order is load-bearing, not cosmetic."""
        img = Image.new("P", (bsa.IMAGE_W, bsa.IMAGE_H))
        img.putpalette([0] * bsa.PALETTE_SIZE)
        px = bytearray(bsa.IMAGE_W * bsa.IMAGE_H)
        # Mark one pixel per quadrant with a distinct index.
        marks = {
            (0, 0): 1,                                   # left half, top
            (0, bsa.IMAGE_H - 1): 2,                     # left half, bottom
            (bsa.HALF_W, 0): 3,                          # right half, top
            (bsa.HALF_W, bsa.IMAGE_H - 1): 4,            # right half, bottom
        }
        for (x, y), v in marks.items():
            px[y * bsa.IMAGE_W + x] = v
        img.frombytes(bytes(px))
        pages = bsa.build_pages(img)
        self.assertEqual(pages[0][0] >> 4, 1)
        self.assertEqual(pages[1][(bsa.ROWS_PER_PAGE - 1) * bsa.HALF_BYTES] >> 4, 2)
        self.assertEqual(pages[2][0] >> 4, 3)
        self.assertEqual(pages[3][(bsa.ROWS_PER_PAGE - 1) * bsa.HALF_BYTES] >> 4, 4)

    def test_palette_is_16_rgb_triples(self) -> None:
        pal = bsa.build_palette(_synthetic())
        self.assertEqual(len(pal), bsa.PALETTE_SIZE)
        self.assertEqual(bsa.PALETTE_SIZE, 48)

    def test_packing_is_deterministic(self) -> None:
        img = _synthetic()
        first = bsa.build_pages(img)
        self.assertEqual(bsa.build_pages(img), first)
        self.assertEqual(bsa.build_palette(img), bsa.build_palette(img))


class InputValidationTests(unittest.TestCase):
    def test_rgb_input_is_rejected(self) -> None:
        path = ROOT / "assets/pc-client/about/about-shatranj.png"
        if not path.is_file():
            self.skipTest("master artwork not present")
        with self.assertRaises(SystemExit):
            bsa.load_indexed(path)

    def test_reserved_caption_indices_are_enforced(self) -> None:
        img = _synthetic()          # uses indices 0..15, including 14/15
        out = ROOT / "build/sprinter/_test_about_reserved.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        img.save(out)
        try:
            with self.assertRaises(SystemExit):
                bsa.load_indexed(out)
        finally:
            out.unlink(missing_ok=True)


class CommittedAssetTests(unittest.TestCase):
    def setUp(self) -> None:
        if not ABOUT_PNG.is_file():
            self.skipTest(f"{ABOUT_PNG} not present")

    def test_committed_asset_matches_the_contract(self) -> None:
        image = bsa.load_indexed(ABOUT_PNG)   # raises on any violation
        self.assertEqual(image.size, (bsa.IMAGE_W, bsa.IMAGE_H))
        self.assertLess(max(image.tobytes()), bsa.IMAGE_COLORS)

    def test_committed_asset_packs_reproducibly(self) -> None:
        image = bsa.load_indexed(ABOUT_PNG)
        a = [hashlib.sha256(p).hexdigest() for p in bsa.build_pages(image)]
        b = [hashlib.sha256(p).hexdigest()
             for p in bsa.build_pages(bsa.load_indexed(ABOUT_PNG))]
        self.assertEqual(a, b)

    def test_caption_entries_are_black_and_light(self) -> None:
        pal = bsa.build_palette(bsa.load_indexed(ABOUT_PNG))
        bg = tuple(pal[bsa.CAPTION_BG_INDEX * 3:bsa.CAPTION_BG_INDEX * 3 + 3])
        fg = tuple(pal[bsa.CAPTION_FG_INDEX * 3:bsa.CAPTION_FG_INDEX * 3 + 3])
        self.assertEqual(bg, (0, 0, 0))
        # Readable means "clearly brighter than its own background".
        self.assertGreater(sum(fg), 3 * 128)


if __name__ == "__main__":
    unittest.main()
