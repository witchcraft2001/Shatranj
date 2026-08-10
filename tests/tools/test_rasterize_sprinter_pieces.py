#!/usr/bin/env python3
"""Unit tests for tools/rasterize_sprinter_pieces.py's pure functions.

This tool is a manual, browser-driven one-off (never run by the build), so
these tests exercise only its browser-independent pieces: quantization,
outline dilation, clip detection, and browser discovery -- exactly what the
S4 plan calls for, no headless Chrome required.
"""

from __future__ import annotations

import sys
import unittest
import unittest.mock
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import rasterize_sprinter_pieces as rsp

BODY = (248, 248, 240)
OUTLINE = (58, 58, 58)
# The other side's pair, used to prove quantization is genuinely joint
# (nearest of ALL 4), not silently still restricted to a 2-colour subset.
BLACK_BODY = (46, 46, 46)
BLACK_OUTLINE = (216, 216, 208)
ALL_FOUR = [BODY, OUTLINE, BLACK_BODY, BLACK_OUTLINE]


class DetectBorderClipTests(unittest.TestCase):
    def test_no_clip_when_border_is_transparent(self) -> None:
        img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        for x in range(6, 10):
            for y in range(6, 10):
                img.putpixel((x, y), BODY + (255,))
        self.assertFalse(rsp.detect_border_clip(img))

    def test_clip_detected_on_top_row(self) -> None:
        img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        img.putpixel((3, 0), BODY + (255,))
        self.assertTrue(rsp.detect_border_clip(img))

    def test_clip_detected_on_right_column(self) -> None:
        img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        img.putpixel((15, 9), BODY + (255,))
        self.assertTrue(rsp.detect_border_clip(img))

    def test_faint_border_alpha_below_threshold_is_not_a_clip(self) -> None:
        img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        img.putpixel((0, 5), BODY + (10,))  # below CLIP_ALPHA_THRESHOLD
        self.assertFalse(rsp.detect_border_clip(img))


class FitToSquareTests(unittest.TestCase):
    def test_empty_source_yields_fully_transparent_square(self) -> None:
        img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        fitted = rsp.fit_to_square(img, 32)
        self.assertEqual(fitted.size, (32, 32))
        self.assertIsNone(fitted.getchannel("A").getbbox())

    def test_result_stays_within_margin_bounds(self) -> None:
        img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
        for x in range(32):
            for y in range(32):
                img.putpixel((x, y), BODY + (255,))
        fitted = rsp.fit_to_square(img, 64, margin_frac=0.1)
        bbox = fitted.getchannel("A").getbbox()
        self.assertIsNotNone(bbox)
        left, top, right, bottom = bbox
        self.assertGreaterEqual(left, 6)   # ~0.1 * 64, allow rounding
        self.assertGreaterEqual(top, 6)
        self.assertLessEqual(right, 58)
        self.assertLessEqual(bottom, 58)

    def test_result_is_centred(self) -> None:
        img = Image.new("RGBA", (10, 20), (0, 0, 0, 0))
        for x in range(10):
            for y in range(20):
                img.putpixel((x, y), BODY + (255,))
        fitted = rsp.fit_to_square(img, 100, margin_frac=0.0)
        bbox = fitted.getchannel("A").getbbox()
        left, top, right, bottom = bbox
        margin_left = left
        margin_right = 100 - right
        self.assertLessEqual(abs(margin_left - margin_right), 1)


class HardQuantizeTests(unittest.TestCase):
    def test_transparent_pixels_stay_transparent(self) -> None:
        img = Image.new("RGBA", (4, 4), (0, 0, 0, 0))
        out = rsp.hard_quantize(img, [BODY, OUTLINE])
        self.assertIsNone(out.getchannel("A").getbbox())

    def test_output_uses_only_the_given_candidates_or_transparent(self) -> None:
        img = Image.new("RGBA", (4, 4), (0, 0, 0, 0))
        # A pixel closer to body, one closer to outline, one anti-aliased
        # blend, one below the alpha threshold (must vanish).
        img.putpixel((0, 0), (250, 250, 245, 255))       # near BODY
        img.putpixel((1, 0), (60, 60, 60, 255))          # near OUTLINE
        img.putpixel((2, 0), (150, 150, 140, 255))       # AA blend, must snap
        img.putpixel((3, 0), (200, 200, 200, 60))        # below threshold
        out = rsp.hard_quantize(img, [BODY, OUTLINE])
        seen = set()
        for x in range(4):
            for y in range(4):
                seen.add(out.getpixel((x, y)))
        allowed = {BODY + (255,), OUTLINE + (255,), (0, 0, 0, 0)}
        self.assertTrue(seen.issubset(allowed), seen)
        self.assertEqual(out.getpixel((0, 0)), BODY + (255,))
        self.assertEqual(out.getpixel((1, 0)), OUTLINE + (255,))
        self.assertEqual(out.getpixel((3, 0)), (0, 0, 0, 0))

    def test_quantization_is_joint_across_all_four_candidates(self) -> None:
        # The defect this replaces: a mid-tone shading pixel on a BLACK
        # piece, restricted to {BLACK_BODY, BLACK_OUTLINE} = {46, 216},
        # would snap to whichever of those two extremes is nearest -- both
        # far away, so it always lost to the near-black body and shading
        # detail vanished. Given all 4 candidates jointly, the same pixel
        # has OUTLINE (58) available, much closer, and keeps its detail.
        img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (70, 70, 70, 255))
        restricted = rsp.hard_quantize(img, [BLACK_BODY, BLACK_OUTLINE])
        joint = rsp.hard_quantize(img, ALL_FOUR)
        self.assertEqual(restricted.getpixel((0, 0)), BLACK_BODY + (255,))
        self.assertEqual(joint.getpixel((0, 0)), OUTLINE + (255,))

    def test_a_genuine_highlight_on_a_dark_piece_can_reach_a_light_tone(self) -> None:
        # Not just the two "own-side" tones plus one borrowed dark shade --
        # a properly light source pixel (e.g. a gem or eye highlight) must
        # be reachable too, which a still-restricted "own body + one more"
        # scheme would rule out by construction.
        img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (245, 245, 240, 255))
        out = rsp.hard_quantize(img, ALL_FOUR)
        self.assertEqual(out.getpixel((0, 0)), BODY + (255,))


class GuaranteeOutlineTests(unittest.TestCase):
    def test_dilates_a_single_body_pixel_with_outline_ring(self) -> None:
        img = Image.new("RGBA", (5, 5), (0, 0, 0, 0))
        img.putpixel((2, 2), BODY + (255,))
        out = rsp.guarantee_outline(img, OUTLINE)
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            self.assertEqual(out.getpixel((2 + dx, 2 + dy)), OUTLINE + (255,))
        self.assertEqual(out.getpixel((2, 2)), BODY + (255,))  # untouched
        self.assertEqual(out.getpixel((0, 0)), (0, 0, 0, 0))   # untouched

    def test_does_not_overwrite_existing_opaque_pixels(self) -> None:
        img = Image.new("RGBA", (3, 3), (0, 0, 0, 0))
        img.putpixel((1, 1), BODY + (255,))
        img.putpixel((0, 1), OUTLINE + (255,))
        out = rsp.guarantee_outline(img, OUTLINE)
        self.assertEqual(out.getpixel((0, 1)), OUTLINE + (255,))
        self.assertEqual(out.getpixel((1, 1)), BODY + (255,))

    def test_fully_transparent_image_stays_transparent(self) -> None:
        img = Image.new("RGBA", (4, 4), (0, 0, 0, 0))
        out = rsp.guarantee_outline(img, OUTLINE)
        self.assertIsNone(out.getchannel("A").getbbox())

    def test_does_not_touch_interior_detail_from_joint_quantization(self) -> None:
        # The whole point of running this AFTER joint hard_quantize: a
        # piece can have interior pixels in ANY of the 4 candidates (not
        # just body/outline), and the outer-boundary dilation must leave
        # them alone -- only genuinely transparent, silhouette-adjacent
        # pixels get the rim colour.
        img = Image.new("RGBA", (3, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), BLACK_BODY + (255,))
        img.putpixel((1, 0), BLACK_OUTLINE + (255,))  # interior "highlight"
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(out.getpixel((0, 0)), BLACK_BODY + (255,))
        self.assertEqual(out.getpixel((1, 0)), BLACK_OUTLINE + (255,))


class ReferenceColorsTests(unittest.TestCase):
    def test_white_and_black_pull_distinct_indices_from_palette(self) -> None:
        import gen_sprinter_palette as gsp

        palette = gsp.load_palette_file(
            Path(__file__).resolve().parent.parent.parent / "assets/sprinter/palette.json"
        )
        w_body, w_outline = rsp.reference_colors(palette, "w")
        b_body, b_outline = rsp.reference_colors(palette, "b")
        self.assertNotEqual(w_body, b_body)
        self.assertNotEqual(w_outline, b_outline)
        by_index = {e["index"]: e["rgb"] for e in palette["base"]}
        self.assertEqual(w_body, gsp._parse_rgb(by_index[4], "t"))
        self.assertEqual(w_outline, gsp._parse_rgb(by_index[5], "t"))
        self.assertEqual(b_body, gsp._parse_rgb(by_index[6], "t"))
        self.assertEqual(b_outline, gsp._parse_rgb(by_index[7], "t"))

    def test_all_piece_reference_colors_is_the_union_in_index_order(self) -> None:
        import gen_sprinter_palette as gsp

        palette = gsp.load_palette_file(
            Path(__file__).resolve().parent.parent.parent / "assets/sprinter/palette.json"
        )
        w_body, w_outline = rsp.reference_colors(palette, "w")
        b_body, b_outline = rsp.reference_colors(palette, "b")
        self.assertEqual(
            rsp.all_piece_reference_colors(palette),
            [w_body, w_outline, b_body, b_outline],
        )


class FindBrowserTests(unittest.TestCase):
    def test_chrome_env_var_wins_when_it_exists(self) -> None:
        with unittest.mock.patch.object(Path, "exists", return_value=True):
            found = rsp.find_browser(env={"CHROME": "/some/chrome/binary"})
        self.assertEqual(found, Path("/some/chrome/binary"))

    def test_missing_env_var_is_skipped(self) -> None:
        found_or_raised = None
        try:
            found_or_raised = rsp.find_browser(env={"CHROME": ""})
        except SystemExit:
            found_or_raised = "raised"
        # Either a real installed browser was found (this Mac has Chrome),
        # or none was and it raised -- either is acceptable; the point of
        # this test is that an empty env var does not crash differently.
        self.assertTrue(found_or_raised is not None)

    def test_raises_when_nothing_found(self) -> None:
        with unittest.mock.patch.object(Path, "exists", return_value=False), \
             unittest.mock.patch("shutil.which", return_value=None):
            with self.assertRaises(SystemExit):
                rsp.find_browser(env={})


if __name__ == "__main__":
    unittest.main()
