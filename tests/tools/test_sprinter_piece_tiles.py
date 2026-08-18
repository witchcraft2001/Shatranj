#!/usr/bin/env python3
"""Unit tests for tools/build_sprinter_piece_tiles.py (S4 piece tile packer).

Uses small synthetic PNG fixtures (solid reference-colour cells), not the
real rasterized pieces, so these tests do not depend on
tools/rasterize_sprinter_pieces.py having been run.
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build_sprinter_piece_tiles as bspt
import gen_sprinter_palette as gsp

PALETTE_JSON = ROOT / "assets/sprinter/palette.json"


def _rgb(palette: dict, index: int) -> tuple[int, int, int]:
    entry = next(e for e in palette["base"] if e["index"] == index)
    return gsp._parse_rgb(entry["rgb"], "t")


def _hex(rgb: tuple[int, int, int]) -> str:
    return "#{:02X}{:02X}{:02X}".format(*rgb)


def _with_sets(palette: dict, names: list[str],
                overrides: dict[str, dict[int, tuple[int, int, int]]] | None = None
                ) -> dict:
    """The real palette with its piece_sets renamed to the fixtures' set
    names (and optionally re-coloured), so these tests stay independent of
    whichever three sets selected_next_sets.json currently names."""
    base_entries = {
        str(i): _hex(_rgb(palette, i)) for i in bspt.PIECE_SET_INDICES
    }
    piece_sets = []
    for name in names:
        entries = dict(base_entries)
        for index, rgb in (overrides or {}).get(name, {}).items():
            entries[str(index)] = _hex(rgb)
        piece_sets.append({"name": name, "entries": entries})
    return {**palette, "piece_sets": piece_sets}


class PieceTilesTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = _with_sets(gsp.load_palette_file(PALETTE_JSON),
                                   ["setA", "setB", "setC"])
        self.tmpdir = Path(tempfile.mkdtemp(prefix="sprinter-piece-tiles-test-"))
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.pieces_root = self.tmpdir / "pieces"

    def _write_solid_piece(self, set_name: str, key: str, rgb: tuple[int, int, int],
                            cell_w: int = 32, cell_h: int = 16) -> Path:
        out_dir = self.pieces_root / set_name
        out_dir.mkdir(parents=True, exist_ok=True)
        img = Image.new("RGBA", (cell_w, cell_h), rgb + (255,))
        path = out_dir / f"{key}.png"
        img.save(path)
        return path

    def _write_full_set(self, set_name: str, cell_w: int = 32, cell_h: int = 16,
                         w_body: tuple[int, int, int] | None = None,
                         b_body: tuple[int, int, int] | None = None) -> None:
        w_body = w_body or _rgb(self.palette, 4)
        b_body = b_body or _rgb(self.palette, 6)
        for key in bspt.PIECE_ORDER:
            rgb = w_body if key.startswith("w") else b_body
            self._write_solid_piece(set_name, key, rgb, cell_w, cell_h)


class BuildPagesTests(PieceTilesTestBase):
    def setUp(self) -> None:
        super().setUp()
        for name in ("setA", "setB", "setC"):
            self._write_full_set(name)

    def test_produces_exactly_two_pages_of_16384_bytes(self) -> None:
        pages, _ = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        self.assertEqual(len(pages), 2)
        for page in pages:
            self.assertEqual(len(page), bspt.PAGE_SIZE)

    def test_deterministic(self) -> None:
        pages1, info1 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                          self.palette, 32, 16)
        pages2, info2 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                          self.palette, 32, 16)
        self.assertEqual(pages1, pages2)
        self.assertEqual(info1["sets"], info2["sets"])

    def test_slot_base_arithmetic(self) -> None:
        _, info = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                    self.palette, 32, 16)
        by_name = {s["name"]: s for s in info["sets"]}
        self.assertEqual(by_name["setA"]["asset_page_index"], 1)
        self.assertEqual(by_name["setA"]["slot_base"], 0)
        self.assertEqual(by_name["setB"]["asset_page_index"], 1)
        self.assertEqual(by_name["setB"]["slot_base"], 24)
        self.assertEqual(by_name["setC"]["asset_page_index"], 2)
        self.assertEqual(by_name["setC"]["slot_base"], 0)

    def test_corner_slot_47_is_setB_last_piece_dark_background(self) -> None:
        pages, _ = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        page0 = pages[0]
        # setB base 24, PIECE_ORDER[-1] == 'bP' at index 11, background 1
        # (dark) -> slot 24 + 11*2 + 1 = 47.
        slot = 24 + 11 * 2 + 1
        self.assertEqual(slot, 47)
        tile = page0[slot * bspt.SLOT_SIZE:(slot + 1) * bspt.SLOT_SIZE]
        self.assertTrue(any(b != 0 for b in tile), "corner slot 47 is all-zero")
        # bP is a solid opaque black-piece body colour everywhere -> every
        # nibble pair in the tile packs to the same index twice.
        b_body_idx = 6
        expected_byte = (b_body_idx << 4) | b_body_idx
        stride = 32 // 2
        first_row = tile[:stride]
        self.assertTrue(all(b == expected_byte for b in first_row))

    def test_unused_tail_of_page_stays_zero(self) -> None:
        pages, _ = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        page1 = pages[1]
        # setC occupies slots 0-23 of page 1 (0-based index 1) and the three
        # sets' flash blocks slots 24-59; the rest (slots 60-63) stays zero.
        tail = page1[60 * bspt.SLOT_SIZE:]
        self.assertEqual(tail, bytes(len(tail)))

    def test_flash_blocks_follow_the_last_normal_block(self) -> None:
        _, info = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                    self.palette, 32, 16)
        by_name = {s["name"]: s for s in info["sets"]}
        for name, base in (("setA", 24), ("setB", 36), ("setC", 48)):
            self.assertEqual(by_name[name]["flash_asset_page_index"], 2)
            self.assertEqual(by_name[name]["flash_slot_base"], base)

    def test_flash_tile_is_the_piece_on_the_flash_background(self) -> None:
        pages, info = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                        self.palette, 32, 16)
        base = next(s for s in info["sets"] if s["name"] == "setA")["flash_slot_base"]
        # The fixture pieces are fully opaque, so a flash tile is solid piece
        # colour; the fully-transparent-piece case below is what pins the
        # flash BACKGROUND index itself.
        slot = base + bspt.PIECE_ORDER.index("wK")
        tile = pages[1][slot * bspt.SLOT_SIZE:(slot + 1) * bspt.SLOT_SIZE]
        expected_byte = (4 << 4) | 4
        self.assertTrue(all(b == expected_byte for b in tile[:16]))

    def test_flash_background_is_the_hud_select_index(self) -> None:
        # A fully transparent piece leaves nothing but background, which is
        # what pins FLASH_BACKGROUND_INDEX into the packed bytes.
        for key in bspt.PIECE_ORDER:
            out_dir = self.pieces_root / "clear"
            out_dir.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (32, 16), (0, 0, 0, 0)).save(out_dir / f"{key}.png")
        pages, info = bspt.build_pages(self.pieces_root, ["clear", "setB", "setC"],
                                        _with_sets(self.palette,
                                                   ["clear", "setB", "setC"]),
                                        32, 16)
        base = next(s for s in info["sets"] if s["name"] == "clear")["flash_slot_base"]
        tile = pages[1][base * bspt.SLOT_SIZE:(base + 1) * bspt.SLOT_SIZE]
        idx = bspt.FLASH_BACKGROUND_INDEX
        self.assertTrue(all(b == ((idx << 4) | idx) for b in tile[:16]))

    def test_render_core_asm_flash_slot_base_matches_the_manifest(self) -> None:
        # The resident hand-copies set 0's flash block position (there is no
        # generated .inc between this tool and the .asm); this is the machine
        # check that keeps the two honest -- a layout change here without the
        # matching EQU edit would otherwise blit garbage tiles.
        import re

        source = (ROOT / "asm/sprinter/zcc/render_core.asm").read_text(encoding="utf-8")
        match = re.search(r"^PIECE_FLASH_SLOT_BASE\s+EQU\s+(\d+)", source, re.M)
        self.assertIsNotNone(match, "PIECE_FLASH_SLOT_BASE EQU not found")
        _, info = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                    self.palette, 32, 16)
        set0 = info["sets"][0]
        self.assertEqual(int(match.group(1)), set0["flash_slot_base"])
        # ...and that the block really is on the page the .asm reads
        # (piece_page2 = HDR asset page index 2).
        self.assertEqual(set0["flash_asset_page_index"], 2)

    def test_no_0xff_byte_in_opaque_tiles(self) -> None:
        pages, _ = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        for page in pages:
            self.assertNotIn(0xFF, page)


class ValidationTests(PieceTilesTestBase):
    def test_wrong_canvas_size_is_rejected_with_filename(self) -> None:
        path = self._write_solid_piece("bad", "wK", _rgb(self.palette, 4),
                                        cell_w=16, cell_h=16)
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 32, 16, {})
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("size", str(cm.exception))

    def test_partial_alpha_is_rejected(self) -> None:
        img = Image.new("RGBA", (32, 16), (0, 0, 0, 0))
        img.putpixel((5, 5), (250, 250, 240, 128))  # neither 0 nor 255
        path = self.pieces_root / "bad" / "wK.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path)
        ref = {_rgb(self.palette, 4): 4}
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 32, 16, ref)
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("alpha", str(cm.exception))

    def test_off_palette_opaque_pixel_is_rejected_with_rgb(self) -> None:
        img = Image.new("RGBA", (32, 16), (0, 0, 0, 0))
        img.putpixel((3, 2), (1, 2, 3, 255))  # not a reference colour
        path = self.pieces_root / "bad" / "wK.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path)
        ref = {_rgb(self.palette, 4): 4, _rgb(self.palette, 5): 5}
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 32, 16, ref)
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("010203", str(cm.exception).upper())

    def test_missing_file_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.load_and_validate_piece(self.pieces_root / "nope" / "wK.png",
                                          32, 16, {})

    def test_wrong_set_count_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.build_pages(self.pieces_root, ["only-one-set"], self.palette, 32, 16)


class PrecomposeTileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = gsp.load_palette_file(PALETTE_JSON)

    def test_nibble_order_high_nibble_is_left_pixel(self) -> None:
        # 2x2 canvas: left column opaque (piece colour), right column
        # transparent (background colour) -- one byte per row.
        piece_rgb = _rgb(self.palette, 4)
        bg_rgb = _rgb(self.palette, 2)
        img = Image.new("RGBA", (2, 2), (0, 0, 0, 0))
        img.putpixel((0, 0), piece_rgb + (255,))
        img.putpixel((0, 1), piece_rgb + (255,))
        data = bspt.precompose_tile(
            img, 2, 2, {bg_rgb: 2}, bg_rgb, {piece_rgb: 4}
        )
        self.assertEqual(len(data), 2)  # stride 1, 2 rows
        expected_byte = (4 << 4) | 2  # left=piece idx4, right=bg idx2
        self.assertEqual(data[0], expected_byte)
        self.assertEqual(data[1], expected_byte)

    def test_fully_transparent_piece_yields_solid_background_tile(self) -> None:
        bg_rgb = _rgb(self.palette, 3)
        img = Image.new("RGBA", (4, 2), (0, 0, 0, 0))
        data = bspt.precompose_tile(img, 4, 2, {bg_rgb: 3}, bg_rgb, {})
        expected_byte = (3 << 4) | 3
        self.assertTrue(all(b == expected_byte for b in data))


class CellParsingTests(unittest.TestCase):
    def test_parses_wxh(self) -> None:
        self.assertEqual(bspt.parse_cell("32x16"), (32, 16))

    def test_rejects_malformed_spec(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.parse_cell("not-a-cell-spec")


class StrideTests(unittest.TestCase):
    def test_defaults_to_the_packed_row_length(self) -> None:
        self.assertEqual(bspt.resolve_stride(32, None), 16)

    def test_matching_stride_is_accepted(self) -> None:
        self.assertEqual(bspt.resolve_stride(32, 16), 16)

    def test_mismatched_stride_is_rejected(self) -> None:
        # precompose_tile packs rows tightly; a padded stride would only
        # ever reach the manifest, describing a geometry the bytes do not
        # have (and the resident blits from that geometry).
        with self.assertRaises(SystemExit) as cm:
            bspt.resolve_stride(32, 20)
        self.assertIn("does not match the packed row length", str(cm.exception))

    def test_odd_cell_width_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.resolve_stride(33, None)


class AllowedPieceColoursTests(PieceTilesTestBase):
    """The widened piece palette (pieces are no longer a 4-colour ramp).

    An artist reads the allowed list out of assets/sprinter/palette.json,
    which ships in the handoff zip; the packer derives its own. These
    tests are the join between the two."""

    def _allowed_map(self) -> dict:
        return bspt._rgb_set(self.palette, bspt.PIECE_ALLOWED_INDICES)

    def test_palette_json_lists_the_same_indices_as_the_packer(self) -> None:
        raw = json.loads(PALETTE_JSON.read_text(encoding="utf-8"))
        self.assertEqual(raw["piece_allowed_indices"], bspt.PIECE_ALLOWED_INDICES)

    def test_only_the_precompose_backgrounds_and_the_key_nibble_are_excluded(self) -> None:
        self.assertEqual(
            bspt.PIECE_EXCLUDED_INDICES,
            set(bspt.BACKGROUND_INDICES)
            | {bspt.FLASH_BACKGROUND_INDEX, bspt.KEY_NIBBLE_INDEX},
        )
        self.assertEqual(bspt.PIECE_EXCLUDED_INDICES, {2, 3, 8, 15})

    def test_hud_colours_are_legal_in_piece_art(self) -> None:
        # The point of the widening: entries 9-14 exist for the HUD but a
        # piece may spend them too, so a set is not confined to one light
        # ramp and one dark ramp.
        for index in (0, 1, 9, 10, 11, 12, 13, 14):
            with self.subTest(index=index):
                rgb = _rgb(self.palette, index)
                path = self._write_solid_piece("hud", "wK", rgb)
                piece = bspt.load_and_validate_piece(path, 32, 16, self._allowed_map())
                tile = bspt.precompose_tile(
                    piece, 32, 16,
                    bspt._rgb_set(self.palette, bspt.BACKGROUND_INDICES),
                    _rgb(self.palette, 2), self._allowed_map(),
                )
                self.assertEqual(set(tile), {(index << 4) | index})

    def test_board_square_colour_in_a_piece_is_rejected(self) -> None:
        # Painting with the square's own colour would be invisible on that
        # square and would follow the board theme -- caught at build time,
        # not by eye in MAME.
        for index in sorted(bspt.PIECE_EXCLUDED_INDICES):
            with self.subTest(index=index):
                path = self._write_solid_piece("bad", "wK", _rgb(self.palette, index))
                with self.assertRaises(SystemExit) as cm:
                    bspt.load_and_validate_piece(path, 32, 16, self._allowed_map())
                self.assertIn(str(path), str(cm.exception))

    def test_diagnostic_names_the_allowed_colours_by_index(self) -> None:
        path = self._write_solid_piece("bad", "wK", (1, 2, 3))
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 32, 16, self._allowed_map())
        message = str(cm.exception)
        self.assertIn("11 #D6453A", message)   # a HUD colour, spelled out
        self.assertNotIn(" 8 #", message)      # ... and the excluded ones are not


class PerSetPaletteTests(PieceTilesTestBase):
    """Each set carries its own four colours (palette.json's piece_sets).

    The tiles are unchanged by this -- they store indices -- so what these
    tests pin down is the VALIDATION side: a colour that is legal in one
    set must not be legal in another, or the artist's per-set gamut is a
    fiction."""

    SET_B_BODY = (0xEF, 0xD6, 0xA8)   # setB's own "white body", nobody else's

    def _palette_with_recoloured_setb(self) -> dict:
        return _with_sets(gsp.load_palette_file(PALETTE_JSON),
                           ["setA", "setB", "setC"],
                           {"setB": {4: self.SET_B_BODY}})

    def test_a_sets_own_colour_packs_as_index_4(self) -> None:
        palette = self._palette_with_recoloured_setb()
        self._write_full_set("setA")
        self._write_full_set("setB", w_body=self.SET_B_BODY)
        self._write_full_set("setC")
        pages, _ = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     palette, 32, 16)
        # setB is the second set on page 1: slot_base 24, wK light square.
        tile = pages[0][24 * 256:24 * 256 + 8]
        self.assertEqual(set(tile), {(4 << 4) | 4})

    def test_one_sets_colour_is_not_legal_in_another(self) -> None:
        palette = self._palette_with_recoloured_setb()
        self._write_full_set("setA", w_body=self.SET_B_BODY)  # setB's colour
        self._write_full_set("setB", w_body=self.SET_B_BODY)
        self._write_full_set("setC")
        with self.assertRaises(SystemExit) as cm:
            bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                              palette, 32, 16)
        self.assertIn("EFD6A8", str(cm.exception).upper())

    def test_shared_accents_stay_legal_in_every_set(self) -> None:
        palette = self._palette_with_recoloured_setb()
        accent = _rgb(self.palette, 14)
        for name in ("setA", "setB", "setC"):
            colours = bspt.piece_colours(palette, name)
            self.assertEqual(colours[accent], 14)

    def test_set_without_a_palette_record_is_rejected(self) -> None:
        with self.assertRaises(SystemExit) as cm:
            bspt.piece_colours(self.palette, "no-such-set")
        self.assertIn("no-such-set", str(cm.exception))

    def test_set_order_must_match_the_palette(self) -> None:
        for name in ("setA", "setB", "setC"):
            self._write_full_set(name)
        with self.assertRaises(SystemExit) as cm:
            bspt.build_pages(self.pieces_root, ["setB", "setA", "setC"],
                              self.palette, 32, 16)
        self.assertIn("same order", str(cm.exception))

    def test_real_palette_names_the_real_sets(self) -> None:
        # The shipped join: palette.json's piece_sets vs the set list the
        # build actually packs.
        selected = json.loads(
            (ROOT / "assets/lichess/selected_next_sets.json").read_text(encoding="utf-8")
        )["selected"]
        palette = gsp.load_palette_file(PALETTE_JSON)
        self.assertEqual([s["name"] for s in palette["piece_sets"]], selected)


class ManifestTests(PieceTilesTestBase):
    def setUp(self) -> None:
        super().setUp()
        for name in ("setA", "setB", "setC"):
            self._write_full_set(name)

    def test_manifest_has_expected_shape(self) -> None:
        _, info = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                    self.palette, 32, 16)
        manifest = bspt.build_manifest(info, 32, 16, 16, PALETTE_JSON)
        self.assertEqual(manifest["format"], "shatranj-sprinter-tiles-v1")
        self.assertEqual(manifest["layout"], "row-major-packed-4bpp-high-nibble-left")
        self.assertEqual(manifest["cell"], {"w": 32, "h": 16})
        self.assertEqual(manifest["tile_bytes"], 256)
        self.assertEqual(len(manifest["piece_order"]), 12)
        self.assertEqual(manifest["flash_tiles_per_set"], 12)
        self.assertEqual(manifest["flash_background_palette_index"], 8)
        self.assertEqual(len(manifest["sets"]), 3)
        self.assertEqual(len(manifest["sha256"]["pieces"]), 3 * 12)
        self.assertEqual(len(manifest["sha256"]["palette_json"]), 64)

    def test_manifest_deterministic(self) -> None:
        _, info1 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        _, info2 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 32, 16)
        m1 = bspt.build_manifest(info1, 32, 16, 16, PALETTE_JSON)
        m2 = bspt.build_manifest(info2, 32, 16, 16, PALETTE_JSON)
        self.assertEqual(m1, m2)


if __name__ == "__main__":
    unittest.main()
