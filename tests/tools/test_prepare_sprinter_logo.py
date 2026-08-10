#!/usr/bin/env python3
"""Unit tests for tools/prepare_sprinter_logo.py's pure functions.

Manual, one-off tool (not part of the build) -- these tests exercise the
background-keying, sizing, and quantization logic against synthetic images,
not the real committed source screenshot.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import prepare_sprinter_logo as psl

TEXT = (232, 232, 232)
ACCENT = (0, 190, 254)


class BackgroundKeyAlphaTests(unittest.TestCase):
    def test_black_pixels_become_transparent(self) -> None:
        img = Image.new("RGB", (4, 4), (0, 0, 0))
        out = psl.background_key_alpha(img)
        self.assertIsNone(out.getchannel("A").getbbox())

    def test_bright_pixels_stay_opaque_with_original_rgb(self) -> None:
        img = Image.new("RGB", (2, 2), (0, 0, 0))
        img.putpixel((0, 0), (255, 255, 255))
        out = psl.background_key_alpha(img)
        self.assertEqual(out.getpixel((0, 0)), (255, 255, 255, 255))
        self.assertEqual(out.getpixel((1, 1)), (0, 0, 0, 0))

    def test_threshold_is_configurable(self) -> None:
        img = Image.new("RGB", (1, 1), (30, 30, 30))
        self.assertIsNone(psl.background_key_alpha(img, threshold=40).getchannel("A").getbbox())
        self.assertIsNotNone(psl.background_key_alpha(img, threshold=20).getchannel("A").getbbox())


class ComputeTargetWidthTests(unittest.TestCase):
    def test_square_source_at_pixel_aspect_half_yields_double_width(self) -> None:
        # A square source (aspect 1:1) needs stored_w = 2*stored_h to look
        # square again once mode #82's ~2:1 pixel geometry stretches it
        # back out -- exactly the relationship the 32x16 piece tile relies
        # on (32 == 2*16).
        w = psl.compute_target_width(100, 100, 16, pixel_aspect_w=0.5)
        self.assertEqual(w, 32)

    def test_wide_source_yields_proportionally_wider_result(self) -> None:
        w_narrow = psl.compute_target_width(100, 100, 16)
        w_wide = psl.compute_target_width(535, 100, 16)  # ~5.35:1, like the real logo
        self.assertGreater(w_wide, w_narrow * 4)

    def test_result_is_always_even(self) -> None:
        for src_w in range(90, 110):
            w = psl.compute_target_width(src_w, 37, 16)
            self.assertEqual(w % 2, 0, f"src_w={src_w} produced odd width {w}")

    def test_result_is_at_least_two(self) -> None:
        self.assertGreaterEqual(psl.compute_target_width(1, 1000, 16), 2)


class HardQuantizeTwoTests(unittest.TestCase):
    def test_transparent_pixels_stay_transparent(self) -> None:
        img = Image.new("RGBA", (2, 2), (0, 0, 0, 0))
        out = psl.hard_quantize_two(img, TEXT, ACCENT)
        self.assertIsNone(out.getchannel("A").getbbox())

    def test_classifies_to_nearest_of_the_two_colours(self) -> None:
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (230, 230, 230, 255))     # near TEXT
        img.putpixel((1, 0), (10, 180, 240, 255))      # near ACCENT
        out = psl.hard_quantize_two(img, TEXT, ACCENT)
        self.assertEqual(out.getpixel((0, 0)), TEXT + (255,))
        self.assertEqual(out.getpixel((1, 0)), ACCENT + (255,))

    def test_dark_desaturated_ANTIALIAS_gray_classifies_as_text_not_accent(self) -> None:
        # Regression: naive RGB-distance classification pulled dark grays
        # toward ACCENT (its zero red channel makes it numerically closer
        # to low-magnitude colours) even though they are visibly
        # achromatic AA blend, not blue. Hue/saturation classification
        # must send them to TEXT instead.
        img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (100, 100, 100, 255))
        out = psl.hard_quantize_two(img, TEXT, ACCENT)
        self.assertEqual(out.getpixel((0, 0)), TEXT + (255,))

    def test_below_alpha_threshold_is_dropped(self) -> None:
        img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (255, 255, 255, 50))
        out = psl.hard_quantize_two(img, TEXT, ACCENT, alpha_threshold=128)
        self.assertEqual(out.getpixel((0, 0)), (0, 0, 0, 0))


class HardQuantizeTwoPairedTests(unittest.TestCase):
    def _assert_pair_uniform_alpha(self, img) -> None:
        w, h = img.size
        for y in range(h):
            for bx in range(w // 2):
                a0 = img.getpixel((2 * bx, y))[3]
                a1 = img.getpixel((2 * bx + 1, y))[3]
                self.assertEqual(a0, a1, f"pair ({2*bx},{2*bx+1}) row {y} mismatched")

    def test_output_has_pair_uniform_alpha_even_with_lopsided_input(self) -> None:
        img = Image.new("RGBA", (8, 2), (0, 0, 0, 0))
        # Deliberately mismatched alpha within pairs, mirroring what a
        # smooth LANCZOS resize produces at a thin stroke's edge.
        img.putpixel((0, 0), (230, 230, 230, 255))
        img.putpixel((1, 0), (230, 230, 230, 40))
        img.putpixel((2, 0), (0, 190, 254, 10))
        img.putpixel((3, 0), (0, 190, 254, 5))
        out = psl.hard_quantize_two_paired(img, TEXT, ACCENT)
        self._assert_pair_uniform_alpha(out)

    def test_pair_is_opaque_if_either_pixel_meets_the_threshold(self) -> None:
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (230, 230, 230, 255))
        img.putpixel((1, 0), (230, 230, 230, 0))
        out = psl.hard_quantize_two_paired(img, TEXT, ACCENT)
        self.assertEqual(out.getpixel((0, 0))[3], 255)
        self.assertEqual(out.getpixel((1, 0))[3], 255)

    def test_pair_stays_transparent_if_neither_pixel_meets_the_threshold(self) -> None:
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (230, 230, 230, 60))
        img.putpixel((1, 0), (230, 230, 230, 10))
        out = psl.hard_quantize_two_paired(img, TEXT, ACCENT)
        self.assertEqual(out.getpixel((0, 0))[3], 0)
        self.assertEqual(out.getpixel((1, 0))[3], 0)

    def test_odd_width_is_rejected(self) -> None:
        img = Image.new("RGBA", (3, 1), (0, 0, 0, 0))
        with self.assertRaises(SystemExit):
            psl.hard_quantize_two_paired(img, TEXT, ACCENT)


class PrepareLogoTests(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = {
            "base": [
                {"index": 1, "name": "text", "rgb": "#E8E8E8"},
                {"index": 14, "name": "accent", "rgb": "#00BEFE"},
            ]
            + [{"index": i, "name": f"x{i}", "rgb": "#000000"} for i in range(16) if i not in (1, 14)],
        }

    def test_output_has_requested_height_and_only_two_colours_or_transparent(self) -> None:
        src = Image.new("RGB", (200, 40), (0, 0, 0))
        for x in range(20, 180):
            for y in range(5, 35):
                src.putpixel((x, y), (255, 255, 255) if x < 100 else (0, 190, 254))
        logo = psl.prepare_logo(src.convert("RGBA"), self.palette, target_h=16)
        self.assertEqual(logo.height, 16)
        self.assertEqual(logo.width % 2, 0)
        seen = {logo.getpixel((x, y)) for x in range(logo.width) for y in range(16)}
        allowed = {(232, 232, 232, 255), (0, 190, 254, 255), (0, 0, 0, 0)}
        self.assertTrue(seen.issubset(allowed), seen)

    def test_all_black_source_is_rejected(self) -> None:
        src = Image.new("RGBA", (50, 20), (0, 0, 0, 255))
        with self.assertRaises(SystemExit):
            psl.prepare_logo(src, self.palette)

    def test_explicit_odd_width_is_rejected(self) -> None:
        src = Image.new("RGBA", (50, 20), (255, 255, 255, 255))
        with self.assertRaises(SystemExit):
            psl.prepare_logo(src, self.palette, target_w=33)


if __name__ == "__main__":
    unittest.main()
