#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_about.py (S4 About screen packer).

Structural tests only, deliberately no pinned sha256 of the quantized
output: Pillow's MEDIANCUT implementation is not guaranteed byte-stable
across versions, and the About screen is not embedded in the EXE or the
smoke image (port.md section 4/S4 decision D4), so this suite checks
shape/format invariants and same-process determinism instead.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import make_sprinter_about as msa

ABOUT_PNG = (
    Path(__file__).resolve().parent.parent.parent / "assets/sprinter/about.png"
)


def _synthetic_source() -> Image.Image:
    img = Image.new("RGB", (msa.TARGET_W, msa.TARGET_H))
    px = img.load()
    for y in range(msa.TARGET_H):
        for x in range(msa.TARGET_W):
            px[x, y] = (x % 256, y % 256, (x + y) % 256)
    return img


class QuantizeTests(unittest.TestCase):
    def test_wrong_size_is_rejected(self) -> None:
        img = Image.new("RGB", (100, 100))
        with self.assertRaises(SystemExit):
            msa.quantize(img)

    def test_output_is_mode_p_at_target_size(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        self.assertEqual(quantized.mode, "P")
        self.assertEqual(quantized.size, (msa.TARGET_W, msa.TARGET_H))


class PaletteTests(unittest.TestCase):
    def test_palette_is_exactly_1024_bytes_rgb0_quads(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        palette = msa.build_palette_bytes(quantized)
        self.assertEqual(len(palette), msa.PALETTE_SIZE)
        self.assertEqual(msa.PALETTE_SIZE, 256 * 4)
        for i in range(256):
            self.assertEqual(palette[i * 4 + 3], 0, f"entry {i}'s 4th byte is not zero")

    def test_deterministic_within_one_process(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        p1 = msa.build_palette_bytes(quantized)
        p2 = msa.build_palette_bytes(quantized)
        self.assertEqual(p1, p2)


class PixelPageTests(unittest.TestCase):
    def test_exactly_five_pages_of_16384_bytes(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        pages = msa.build_pixel_pages(quantized)
        self.assertEqual(len(pages), 5)
        for page in pages:
            self.assertEqual(len(page), msa.PAGE_SIZE)

    def test_total_payload_covers_every_pixel_plus_padding(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        pages = msa.build_pixel_pages(quantized)
        total = b"".join(pages)
        self.assertEqual(len(total), 5 * msa.PAGE_SIZE)
        self.assertEqual(msa.PIXEL_TOTAL, msa.TARGET_W * msa.TARGET_H)
        # Padding past the real pixel data (81920..81920+.. ) must be zero.
        self.assertEqual(total[msa.PIXEL_TOTAL:], bytes(len(total) - msa.PIXEL_TOTAL))

    def test_deterministic_within_one_process(self) -> None:
        quantized = msa.quantize(_synthetic_source())
        pages1 = msa.build_pixel_pages(quantized)
        pages2 = msa.build_pixel_pages(quantized)
        self.assertEqual(pages1, pages2)


class RoundTripTests(unittest.TestCase):
    def test_reconstruct_preview_matches_quantized_source_exactly(self) -> None:
        source = _synthetic_source()
        quantized = msa.quantize(source)
        palette = msa.build_palette_bytes(quantized)
        pages = msa.build_pixel_pages(quantized)
        preview = msa.reconstruct_preview(palette, pages)
        self.assertEqual(preview.size, (msa.TARGET_W, msa.TARGET_H))
        self.assertEqual(preview.convert("RGB").tobytes(), quantized.convert("RGB").tobytes())


class RealAboutPngTests(unittest.TestCase):
    def test_committed_about_png_is_the_right_size(self) -> None:
        self.assertTrue(ABOUT_PNG.is_file(), f"missing {ABOUT_PNG}")
        img = Image.open(ABOUT_PNG)
        self.assertEqual(img.size, (msa.TARGET_W, msa.TARGET_H))

    def test_committed_about_png_packs_without_error(self) -> None:
        quantized = msa.quantize(Image.open(ABOUT_PNG))
        palette = msa.build_palette_bytes(quantized)
        pages = msa.build_pixel_pages(quantized)
        self.assertEqual(len(palette), msa.PALETTE_SIZE)
        self.assertEqual(len(pages), 5)


if __name__ == "__main__":
    unittest.main()
