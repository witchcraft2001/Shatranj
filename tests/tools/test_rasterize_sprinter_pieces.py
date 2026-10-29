#!/usr/bin/env python3
"""Unit tests for tools/rasterize_sprinter_pieces.py's pure functions.

This tool is a manual, browser-driven one-off (never run by the build), so
these tests exercise its browser-independent pieces: source classification,
coverage reduction, exterior outlines, preview geometry, clipping, and
browser discovery. No headless Chrome is required.
"""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import rasterize_sprinter_pieces as rsp

BODY = (248, 248, 240)
OUTLINE = (32, 32, 32)
BLACK_BODY = (76, 76, 76)
BLACK_OUTLINE = (200, 200, 192)


def pixels(image: Image.Image) -> list[tuple]:
    return [image.getpixel((x, y)) for y in range(image.height) for x in range(image.width)]


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

    def test_does_not_fill_an_internal_hole(self) -> None:
        img = Image.new("RGBA", (5, 5), (0, 0, 0, 0))
        for y in range(1, 4):
            for x in range(1, 4):
                if (x, y) != (2, 2):
                    img.putpixel((x, y), BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(out.getpixel((2, 2)), (0, 0, 0, 0))

    def test_does_not_bridge_two_separate_parts(self) -> None:
        img = Image.new("RGBA", (7, 5), (0, 0, 0, 0))
        img.putpixel((2, 2), BODY + (255,))
        img.putpixel((4, 2), BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertNotEqual(out.getpixel((3, 2)), BLACK_OUTLINE + (255,))

    def test_does_not_close_an_open_silhouette_gap(self) -> None:
        img = Image.new("RGBA", (7, 7), (0, 0, 0, 0))
        for x in range(2, 5):
            img.putpixel((x, 2), BODY + (255,))
            img.putpixel((x, 4), BODY + (255,))
        img.putpixel((2, 3), BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(out.getpixel((4, 3)), (0, 0, 0, 0))

    def test_does_not_touch_interior_detail_from_region_classification(self) -> None:
        # After region classification, a piece can have interior pixels in ANY of the 4 candidates (not
        # just body/outline), and the outer-boundary dilation must leave
        # them alone -- only genuinely transparent, silhouette-adjacent
        # pixels get the rim colour.
        img = Image.new("RGBA", (3, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), BLACK_BODY + (255,))
        img.putpixel((1, 0), BLACK_OUTLINE + (255,))  # interior "highlight"
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(out.getpixel((0, 0)), BLACK_BODY + (255,))
        self.assertEqual(out.getpixel((1, 0)), BLACK_OUTLINE + (255,))

    def test_rim_covers_diagonal_and_adjacent_corner_neighbours(self) -> None:
        img = Image.new("RGBA", (7, 7), (0, 0, 0, 0))
        img.putpixel((2, 3), BLACK_BODY + (255,))
        img.putpixel((3, 2), BLACK_BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(out.getpixel((3, 3)), BLACK_OUTLINE + (255,))
        self.assertEqual(out.getpixel((1, 2)), BLACK_OUTLINE + (255,))

    def test_two_pixel_gap_cannot_join_parts_through_new_rim_pixels(self) -> None:
        img = Image.new("RGBA", (10, 7), (0, 0, 0, 0))
        img.putpixel((3, 3), BLACK_BODY + (255,))
        img.putpixel((6, 3), BLACK_BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        self.assertEqual(rsp._opaque_components(out)[1], 2)
        self.assertEqual(out.getpixel((4, 3))[3], 0)
        self.assertEqual(out.getpixel((5, 3))[3], 0)

    def test_diagonal_open_cut_stays_connected_to_exterior(self) -> None:
        img = Image.new("RGBA", (9, 9), (0, 0, 0, 0))
        for y in range(2, 7):
            for x in range(2, 7):
                if x - y not in (0, 1):
                    img.putpixel((x, y), BLACK_BODY + (255,))
        out = rsp.guarantee_outline(img, BLACK_OUTLINE)
        exterior = rsp._exterior_transparency(out)
        for xy in ((3, 3), (4, 4), (5, 5)):
            self.assertEqual(out.getpixel(xy)[3], 0)
            self.assertTrue(exterior[xy[1]][xy[0]])


class ReferenceColorsTests(unittest.TestCase):
    def test_each_set_uses_its_own_import_palette(self) -> None:
        import gen_sprinter_palette as gsp

        palette = gsp.load_palette_file(
            Path(__file__).resolve().parent.parent.parent / "assets/sprinter/palette.json"
        )
        for set_name in ("california", "mpchess", "totoy"):
            colours = rsp.piece_palette(palette, set_name)
            self.assertEqual(colours[4], (248, 248, 240))
            self.assertEqual(colours[5], (32, 32, 32))
            self.assertEqual(colours[6], (76, 76, 76))
            self.assertEqual(colours[7], (200, 200, 192))


class SourceClassificationTests(unittest.TestCase):
    def test_separates_shades_for_california_black_piece(self) -> None:
        self.assertEqual(rsp.source_index((32, 32, 32), "california", "b"), 5)
        self.assertEqual(rsp.source_index((76, 76, 76), "california", "b"), 6)
        self.assertEqual(rsp.source_index((102, 102, 102), "california", "b"), 6)
        self.assertEqual(rsp.source_index((128, 128, 128), "california", "b"), 7)
        self.assertEqual(rsp.source_index((200, 200, 200), "california", "b"), 7)

    def test_mpchess_black_silhouette_stays_dark(self) -> None:
        self.assertEqual(rsp.source_index((0, 0, 0), "mpchess", "b"), 5)

    def test_coverage_downscale_keeps_dominant_regions_separate(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        img = Image.new("RGBA", (128, 64), (0, 0, 0, 0))
        for y in range(64):
            for x in range(64):
                img.putpixel((x, y), (32, 32, 32, 255))
            for x in range(64, 128):
                img.putpixel((x, y), (76, 76, 76, 255))
        out = rsp.classify_and_downscale(img, "california", "b", palette)
        self.assertEqual(out.getpixel((7, 8)), OUTLINE + (255,))
        self.assertEqual(out.getpixel((24, 8)), BLACK_BODY + (255,))

    def test_dark_stroke_wins_a_coverage_tie_without_inventing_gray(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        img = Image.new("RGBA", (80, 40), (255, 255, 255, 255))
        for y in range(40):
            for x in range(0, 80, 2):
                img.putpixel((x, y), (0, 0, 0, 255))
        out = rsp.classify_and_downscale(img, "california", "w", palette)
        self.assertEqual(set(pixels(out)), {OUTLINE + (255,)})

    def test_fill_wins_a_small_coverage_advantage_without_a_false_byte_tie(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        img = Image.new("RGBA", (160, 80), (255, 255, 255, 254))
        # Each 4x4 block has eight pixels of each class. White has one
        # extra unit of alpha: coverage 127.0625 versus 127.0. Byte masks
        # round both to 127 and incorrectly prefer the dark line.
        for y in range(80):
            for x in range(0, 160, 2):
                img.putpixel((x, y), (0, 0, 0, 254))
        for y in range(0, 80, 4):
            for x in range(1, 160, 4):
                img.putpixel((x, y), (255, 255, 255, 255))
        out = rsp.classify_and_downscale(img, "california", "w", palette)
        self.assertEqual(set(pixels(out)), {BODY + (255,)})

    def test_white_shadows_and_black_light_details_have_separate_index(self) -> None:
        self.assertEqual(rsp.source_index((128, 128, 128), "california", "w"), 7)
        self.assertEqual(rsp.source_index((242, 242, 242), "california", "b"), 7)
        self.assertEqual(rsp.source_index((255, 255, 255), "totoy", "w"), 4)

    def test_alpha_threshold_is_exactly_half_coverage(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        img = Image.new("RGBA", (80, 40), (0, 0, 0, 0))
        img.putpixel((0, 0), (0, 0, 0, 255))
        img.putpixel((0, 1), (0, 0, 0, 255))
        img.putpixel((2, 0), (0, 0, 0, 255))
        out = rsp.classify_and_downscale(img, "california", "w", palette)
        self.assertEqual(out.getpixel((0, 0)), OUTLINE + (255,))
        self.assertEqual(out.getpixel((1, 0))[3], 0)

    def test_classification_precedes_bbox_fit(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        img = Image.new("RGBA", (128, 128), (255, 255, 255, 255))
        for x in range(0, 128, 2):
            for y in range(128):
                img.putpixel((x, y), (0, 0, 0, 255))
        out = rsp.classify_and_downscale(img, "california", "w", palette, fit_size=128)
        self.assertTrue({pixel[:3] for pixel in pixels(out) if pixel[3]}
                        <= {BODY, OUTLINE})

    def test_conversion_uses_set_override_instead_of_base(self) -> None:
        palette = copy.deepcopy(rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE))
        palette["piece_sets"][1]["entries"]["5"] = "#131D27"
        img = Image.new("RGBA", (128, 64), (0, 0, 0, 255))
        out = rsp.classify_and_downscale(img, "mpchess", "b", palette)
        self.assertEqual(set(pixels(out)), {(19, 29, 39, 255)})
        self.assertEqual(rsp.piece_palette(palette, "california")[5], OUTLINE)

    def test_process_leaves_white_contour_unmodified(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        square = Image.new("RGBA", (128, 128), (0, 0, 0, 0))
        for y in range(24, 104):
            for x in range(32, 96):
                rgb = (0, 0, 0) if x < 40 or x >= 88 or y < 32 or y >= 96 else (255, 255, 255)
                square.putpixel((x, y), rgb + (255,))
        alpha, masks = rsp.source_masks(square, "california", "w", fit_size=128)
        expected, _, _ = rsp.select_grid_phase(alpha, masks, rsp.piece_palette(palette, "california"))
        with unittest.mock.patch.object(rsp, "guarantee_outline", side_effect=AssertionError("white rim")), \
             unittest.mock.patch.object(rsp, "render_svg_square", return_value=(square, 128)):
            result = rsp.process_piece(Path("unused"), Path("unused.svg"), "california", "w", palette, Path("."))
        self.assertEqual(result.tobytes(), expected.tobytes())
        self.assertIn(OUTLINE + (255,), set(pixels(result)))


class PreviewTests(unittest.TestCase):
    def test_actual_cell_geometry_both_theme_squares_and_flash(self) -> None:
        palette = rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        tile = Image.new("RGBA", (32, 16), BODY + (255,))
        tiles = {"california": {side + kind: tile for side in rsp.SIDES for kind in rsp.PIECE_KINDS}}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "preview.png"
            rsp.build_preview(tiles, palette, path)
            sheet = Image.open(path)
            # First cell starts at x=118,y=6. The tile starts at +8,+8
            # after vertical aspect correction, leaving real cell margins.
            light = rsp.gsp._parse_rgb(palette["themes"][0]["entries"]["2"], "test")
            dark = rsp.gsp._parse_rgb(palette["themes"][0]["entries"]["3"], "test")
            self.assertEqual(sheet.getpixel((118, 6)), light)
            self.assertEqual(sheet.getpixel((126, 14)), BODY)
            self.assertEqual(sheet.getpixel((158, 14)), light)
            self.assertEqual(sheet.getpixel((118, 60)), dark)
            self.assertEqual(sheet.height, 11 * 54 + 6)
            flash = next(e["rgb"] for e in palette["base"] if e["index"] == 8)
            self.assertEqual(sheet.getpixel((118, 546)), rsp.gsp._parse_rgb(flash, "test"))
            zoom = Image.open(path.with_name("preview_zoom.png"))
            self.assertEqual(zoom.getpixel((118 + 8 * 4, 6 + 8 * 4)), BODY)


class QuantizeTargetsTests(unittest.TestCase):
    def test_palette_json_lists_the_same_import_targets(self) -> None:
        raw = json.loads(
            (Path(__file__).resolve().parent.parent.parent
             / "assets/sprinter/palette.json").read_text(encoding="utf-8")
        )
        # The import baseline is deliberately narrower than what the build
        # accepts in a finished PNG (build_sprinter_piece_tiles.py's
        # PIECE_ALLOWED_INDICES) -- see that constant's comment.
        self.assertEqual(
            raw["piece_import_quantize_indices"], list(rsp.PIECE_QUANTIZE_INDICES)
        )
        self.assertTrue(
            set(raw["piece_import_quantize_indices"])
            < set(raw["piece_allowed_indices"])
        )


class SourceFeatureRegressionTests(unittest.TestCase):
    def test_committed_art_retains_real_source_parts_and_holes(self):
        # Reviewed against all 36 SVGs: MPChess black bases are separate;
        # California bishop cuts and MPChess white bishop/king have holes.
        root=Path(__file__).resolve().parents[2]/"assets/sprinter/pieces"
        expected={"california/wB":(1,1), "california/bB":(1,1),
                  "mpchess/wK":(1,2), "mpchess/wB":(1,1),
                  "mpchess/bK":(2,2), "mpchess/bQ":(2,0),
                  "mpchess/bR":(3,0), "mpchess/bB":(2,0), "mpchess/bN":(2,0)}
        for path in root.glob("*/*.png"):
            key=path.parent.name+"/"+path.stem
            with self.subTest(piece=key):
                with Image.open(path) as image:
                    self.assertEqual(rsp.topology(image.convert("RGBA")),expected.get(key,(1,0)))

    def test_diagonals_arcs_bridges_slots_and_components(self):
        from PIL import ImageDraw
        palette=rsp.gsp.load_palette_file(rsp.DEFAULT_PALETTE)
        refs=rsp.piece_palette(palette,"mpchess")
        fixtures=[]
        for shape in ("diagonal","arc","bridge","slot","parts","cross"):
            image=Image.new("RGBA",(160,80),(0,0,0,0)); draw=ImageDraw.Draw(image)
            if shape=="diagonal": draw.line((20,60,120,12),fill="black",width=6)
            if shape=="arc": draw.arc((20,12,140,68),20,300,fill="black",width=6)
            if shape=="bridge":
                draw.rectangle((12,24,56,60),fill="black"); draw.rectangle((100,24,144,60),fill="black")
                draw.rectangle((52,36,104,40),fill="black")
            if shape=="slot":
                draw.rectangle((20,12,140,68),fill="black"); draw.rectangle((76,12,83,48),fill=(0,0,0,0))
            if shape=="parts":
                draw.rectangle((20,12,140,32),fill="black"); draw.rectangle((20,44,140,68),fill="black")
            if shape=="cross":
                draw.rectangle((76,12,83,68),fill="black"); draw.rectangle((44,24,116,28),fill="black")
            alpha,masks=rsp.source_masks(image,"mpchess","b")
            result,phase,candidates=rsp.select_grid_phase(alpha,masks,refs)
            with self.subTest(shape=shape):
                self.assertEqual(len(candidates),9)
                if shape=="cross":
                    for px,py in ((11,6),(28,6),(19,3),(19,16)):
                        self.assertTrue(any(result.getpixel((x,y))[3]
                                            for x in range(px-1,px+2)
                                            for y in range(py-1,py+2)))
                if shape=="bridge":
                    self.assertTrue(all(any(result.getpixel((x,y))[3] for y in (8,9,10))
                                        for x in range(14,25)))
                self.assertEqual(rsp.topology(result),rsp.topology(image))
                again,again_phase,_=rsp.select_grid_phase(alpha,masks,refs)
                self.assertEqual((result.tobytes(),phase),(again.tobytes(),again_phase))

    def test_equal_phase_scores_prefer_zero(self):
        alpha=Image.new("F",(160,80),0)
        masks={i:alpha.copy() for i in (4,5,6,7)}
        refs={i:(i,i,i) for i in masks}
        _,phase,_=rsp.select_grid_phase(alpha,masks,refs)
        self.assertEqual(phase,(0,0))


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
