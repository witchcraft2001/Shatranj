#!/usr/bin/env python3
"""Unit tests for tools/build_sprinter_piece_tiles.py (S4 piece tile packer).

Uses synthetic fixtures plus a round trip of all 108 tiles from the
committed PNGs. No browser or SVG regeneration is required.
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


class CommittedPieceRoundTripTests(unittest.TestCase):
    def test_all_108_tiles_pixels_padding_and_page_boundaries(self):
        palette = gsp.load_palette_file(PALETTE_JSON)
        sets = json.loads((ROOT / "assets/lichess/selected_next_sets.json").read_text())["selected"]
        root = ROOT / "assets/sprinter/pieces"
        pages, info = bspt.build_pages(root, sets, palette, 40, 20)
        self.assertEqual(list(map(len, pages)), [16384]*4)
        occupied = set()
        checked = 0
        for record in info["sets"]:
            self.assertEqual([g["piece"] for g in record["groups"]], bspt.PIECE_ORDER)
            refs = bspt.piece_colours(palette, record["name"])
            for group in record["groups"]:
                png = Image.open(root / record["name"] / (group["piece"] + ".png")).convert("RGBA")
                page = bspt.ASSET_PAGE_INDICES.index(group["asset_page_index"])
                self.assertLessEqual(group["slot_base"]+6,64)
                for bg, index in enumerate((2,3,8)):
                    offset = (group["slot_base"]+bg*2)*256
                    block = pages[page][offset:offset+512]
                    self.assertEqual(block[400:],bytes(112))
                    for pos in range(offset,offset+512):
                        self.assertNotIn((page,pos),occupied)
                        occupied.add((page,pos))
                    for y in range(20):
                        for x in range(40):
                            byte=block[y*20+x//2]
                            decoded=byte>>4 if x%2==0 else byte&15
                            pixel=png.getpixel((x,y))
                            self.assertEqual(decoded,refs[pixel[:3]] if pixel[3] else index)
                    checked+=1
        self.assertEqual(checked,108)
        for page, data in enumerate(pages):
            self.assertNotIn(255,data)
            self.assertTrue(all(value==0 for pos,value in enumerate(data) if (page,pos) not in occupied))
        self.assertEqual(bspt.build_pages(root,sets,palette,40,20),(pages,info))
        locations=bspt.render_set_locations_inc(info,palette)
        self.assertEqual(locations.count("    DB "),36)
        with self.assertRaises(ValueError):
            bspt.render_set_locations_inc({"sets":list(reversed(info["sets"]))},palette)
        import copy
        for key,value in (("asset_page_index",3),("slot_base",60),("slot_base",1)):
            broken=copy.deepcopy(info)
            broken["sets"][0]["groups"][0][key]=value
            with self.assertRaises(ValueError): bspt.render_set_locations_inc(broken,palette)

    def test_transitions_within_each_set(self):
        palette=gsp.load_palette_file(PALETTE_JSON)
        sets=[r["name"] for r in palette["piece_sets"]]
        _,info=bspt.build_pages(ROOT/"assets/sprinter/pieces",sets,palette,40,20)
        self.assertEqual([[g["asset_page_index"] for g in r["groups"]] for r in info["sets"]],
                         [[1]*10+[2]*2,[2]*8+[10]*4,[10]*6+[11]*6])


class PieceTilesTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = _with_sets(gsp.load_palette_file(PALETTE_JSON),
                                   ["setA", "setB", "setC"])
        self.tmpdir = Path(tempfile.mkdtemp(prefix="sprinter-piece-tiles-test-"))
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)
        self.pieces_root = self.tmpdir / "pieces"

    def _write_solid_piece(self, set_name: str, key: str, rgb: tuple[int, int, int],
                            cell_w: int = 40, cell_h: int = 20) -> Path:
        out_dir = self.pieces_root / set_name
        out_dir.mkdir(parents=True, exist_ok=True)
        img = Image.new("RGBA", (cell_w, cell_h), rgb + (255,))
        path = out_dir / f"{key}.png"
        img.save(path)
        return path

    def _write_full_set(self, set_name: str, cell_w: int = 40, cell_h: int = 20,
                         w_body: tuple[int, int, int] | None = None,
                         b_body: tuple[int, int, int] | None = None) -> None:
        w_body = w_body or _rgb(self.palette, 4)
        b_body = b_body or _rgb(self.palette, 6)
        for key in bspt.PIECE_ORDER:
            rgb = w_body if key.startswith("w") else b_body
            self._write_solid_piece(set_name, key, rgb, cell_w, cell_h)


class ValidationTests(PieceTilesTestBase):
    def test_wrong_canvas_size_is_rejected_with_filename(self) -> None:
        path = self._write_solid_piece("bad", "wK", _rgb(self.palette, 4),
                                        cell_w=16, cell_h=16)
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 40, 20, {})
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("size", str(cm.exception))

    def test_partial_alpha_is_rejected(self) -> None:
        img = Image.new("RGBA", (40, 20), (0, 0, 0, 0))
        img.putpixel((5, 5), (250, 250, 240, 128))  # neither 0 nor 255
        path = self.pieces_root / "bad" / "wK.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path)
        ref = {_rgb(self.palette, 4): 4}
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 40, 20, ref)
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("alpha", str(cm.exception))

    def test_off_palette_opaque_pixel_is_rejected_with_rgb(self) -> None:
        img = Image.new("RGBA", (40, 20), (0, 0, 0, 0))
        img.putpixel((3, 2), (1, 2, 3, 255))  # not a reference colour
        path = self.pieces_root / "bad" / "wK.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        img.save(path)
        ref = {_rgb(self.palette, 4): 4, _rgb(self.palette, 5): 5}
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 40, 20, ref)
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("010203", str(cm.exception).upper())

    def test_missing_file_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.load_and_validate_piece(self.pieces_root / "nope" / "wK.png",
                                          40, 20, {})

    def test_wrong_set_count_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.build_pages(self.pieces_root, ["only-one-set"], self.palette, 40, 20)


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
        self.assertEqual(bspt.parse_cell("40x20"), (40, 20))

    def test_rejects_malformed_spec(self) -> None:
        with self.assertRaises(SystemExit):
            bspt.parse_cell("not-a-cell-spec")


class StrideTests(unittest.TestCase):
    def test_defaults_to_the_packed_row_length(self) -> None:
        self.assertEqual(bspt.resolve_stride(32, None), 16)

    def test_matching_stride_is_accepted(self) -> None:
        self.assertEqual(bspt.resolve_stride(40, 20), 20)

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
                piece = bspt.load_and_validate_piece(path, 40, 20, self._allowed_map())
                tile = bspt.precompose_tile(
                    piece, 40, 20,
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
                    bspt.load_and_validate_piece(path, 40, 20, self._allowed_map())
                self.assertIn(str(path), str(cm.exception))

    def test_diagnostic_names_the_allowed_colours_by_index(self) -> None:
        path = self._write_solid_piece("bad", "wK", (1, 2, 3))
        with self.assertRaises(SystemExit) as cm:
            bspt.load_and_validate_piece(path, 40, 20, self._allowed_map())
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
                                     palette, 40, 20)
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
                              palette, 40, 20)
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
                              self.palette, 40, 20)
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
                                    self.palette, 40, 20)
        manifest = bspt.build_manifest(info, 40, 20, 20, PALETTE_JSON)
        self.assertEqual(manifest["format"], "shatranj-sprinter-tiles-v2")
        self.assertEqual(manifest["layout"], "row-major-packed-4bpp-high-nibble-left")
        self.assertEqual(manifest["cell"], {"w": 40, "h": 20})
        self.assertEqual(manifest["tile_bytes"], 400)
        self.assertEqual(len(manifest["piece_order"]), 12)
        self.assertEqual(manifest["flash_tiles_per_set"], 12)
        self.assertEqual(manifest["flash_background_palette_index"], 8)
        self.assertEqual(len(manifest["sets"]), 3)
        self.assertEqual(len(manifest["sha256"]["pieces"]), 3 * 12)
        self.assertEqual(len(manifest["sha256"]["palette_json"]), 64)

    def test_manifest_deterministic(self) -> None:
        _, info1 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 40, 20)
        _, info2 = bspt.build_pages(self.pieces_root, ["setA", "setB", "setC"],
                                     self.palette, 40, 20)
        m1 = bspt.build_manifest(info1, 40, 20, 20, PALETTE_JSON)
        m2 = bspt.build_manifest(info2, 40, 20, 20, PALETTE_JSON)
        self.assertEqual(m1, m2)


if __name__ == "__main__":
    unittest.main()
