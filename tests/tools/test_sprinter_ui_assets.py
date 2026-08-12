#!/usr/bin/env python3
"""Unit tests for tools/build_sprinter_ui_assets.py (S4 logo/marker packer).

Uses small synthetic PNG fixtures, not the real committed logo/markers, so
these tests do not depend on tools/prepare_sprinter_logo.py or
tools/make_sprinter_markers.py having been run.
"""

from __future__ import annotations

import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import build_sprinter_ui_assets as bsua
import gen_sprinter_palette as gsp

PALETTE_JSON = ROOT / "assets/sprinter/palette.json"
RENDER_CORE_ASM = ROOT / "asm/sprinter/zcc/render_core.asm"


def _asm_equ(source: str, name: str) -> int:
    match = re.search(rf"^{name}\s+EQU\s+(\d+)\s*(?:;.*)?$", source, re.MULTILINE)
    if match is None:
        raise AssertionError(f"{name} EQU not found in render_core.asm")
    return int(match.group(1))


def _rgb(palette: dict, index: int) -> tuple[int, int, int]:
    entry = next(e for e in palette["base"] if e["index"] == index)
    return gsp._parse_rgb(entry["rgb"], "t")


class UiAssetsTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self.palette = gsp.load_palette_file(PALETTE_JSON)
        self.tmpdir = Path(tempfile.mkdtemp(prefix="sprinter-ui-assets-test-"))
        self.addCleanup(shutil.rmtree, self.tmpdir, ignore_errors=True)

    def _write_solid(self, name: str, w: int, h: int, rgb: tuple[int, int, int]) -> Path:
        img = Image.new("RGBA", (w, h), rgb + (255,))
        path = self.tmpdir / name
        img.save(path)
        return path

    def _write_all_transparent(self, name: str, w: int, h: int) -> Path:
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        path = self.tmpdir / name
        img.save(path)
        return path


class PackKeyedAssetTests(UiAssetsTestBase):
    def test_nibble_order_and_key_byte(self) -> None:
        # 4x1: left pair opaque idx4/idx4, right pair transparent.
        idx4_rgb = _rgb(self.palette, 4)
        img = Image.new("RGBA", (4, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), idx4_rgb + (255,))
        img.putpixel((1, 0), idx4_rgb + (255,))
        path = self.tmpdir / "t.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        data, w, h = bsua.pack_keyed_asset(path, ref)
        self.assertEqual((w, h), (4, 1))
        self.assertEqual(len(data), 2)
        self.assertEqual(data[0], (4 << 4) | 4)
        self.assertEqual(data[1], 0xFF)

    def test_mixed_colours_in_one_pair_pack_into_distinct_nibbles(self) -> None:
        idx1_rgb = _rgb(self.palette, 1)
        idx14_rgb = _rgb(self.palette, 14)
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), idx1_rgb + (255,))
        img.putpixel((1, 0), idx14_rgb + (255,))
        path = self.tmpdir / "t.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        data, _, _ = bsua.pack_keyed_asset(path, ref)
        self.assertEqual(data[0], (1 << 4) | 14)

    def test_mismatched_pair_transparency_is_rejected(self) -> None:
        idx4_rgb = _rgb(self.palette, 4)
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), idx4_rgb + (255,))
        # pixel (1,0) stays transparent -> mismatched pair
        path = self.tmpdir / "bad.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        with self.assertRaises(SystemExit) as cm:
            bsua.pack_keyed_asset(path, ref)
        self.assertIn(str(path), str(cm.exception))
        self.assertIn("mismatched transparency", str(cm.exception))

    def test_index_15_is_not_a_valid_opaque_colour(self) -> None:
        idx15_rgb = _rgb(self.palette, 15)
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), idx15_rgb + (255,))
        img.putpixel((1, 0), idx15_rgb + (255,))
        path = self.tmpdir / "bad15.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        self.assertNotIn(idx15_rgb, ref)
        with self.assertRaises(SystemExit) as cm:
            bsua.pack_keyed_asset(path, ref)
        self.assertIn("not one of the allowed palette colours", str(cm.exception))

    def test_off_palette_opaque_pixel_is_rejected_with_rgb(self) -> None:
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (1, 2, 3, 255))
        img.putpixel((1, 0), (1, 2, 3, 255))
        path = self.tmpdir / "offpal.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        with self.assertRaises(SystemExit) as cm:
            bsua.pack_keyed_asset(path, ref)
        self.assertIn("010203", str(cm.exception).upper())

    def test_odd_width_is_rejected(self) -> None:
        path = self._write_all_transparent("odd.png", 3, 2)
        ref = bsua._ref_rgb_to_index(self.palette)
        with self.assertRaises(SystemExit):
            bsua.pack_keyed_asset(path, ref)

    def test_size_mismatch_is_rejected(self) -> None:
        path = self._write_all_transparent("wrongsize.png", 16, 8)
        ref = bsua._ref_rgb_to_index(self.palette)
        with self.assertRaises(SystemExit):
            bsua.pack_keyed_asset(path, ref, expect_w=16, expect_h=16)

    def test_partial_alpha_is_rejected(self) -> None:
        img = Image.new("RGBA", (2, 1), (0, 0, 0, 0))
        img.putpixel((0, 0), (200, 200, 200, 128))
        img.putpixel((1, 0), (200, 200, 200, 128))
        path = self.tmpdir / "partial.png"
        img.save(path)
        ref = bsua._ref_rgb_to_index(self.palette)
        with self.assertRaises(SystemExit):
            bsua.pack_keyed_asset(path, ref)


class BuildUiAssetsTests(UiAssetsTestBase):
    def setUp(self) -> None:
        super().setUp()
        idx1 = _rgb(self.palette, 1)
        idx14 = _rgb(self.palette, 14)
        self.logo_path = self._write_solid("logo.png", 40, 16, idx1)
        self.dot_path = self._write_solid(
            "dot.png", bsua.MARKER_W, bsua.MARKER_H, _rgb(self.palette, 9)
        )
        self.ring_path = self._write_solid(
            "ring.png", bsua.MARKER_W, bsua.MARKER_H, idx14
        )
        self.cursor_path = self._write_solid(
            "cursor.png", bsua.FRAME_W, bsua.FRAME_H, idx14
        )
        self.select_path = self._write_solid(
            "select.png", bsua.FRAME_W, bsua.FRAME_H, _rgb(self.palette, 8)
        )

    def test_output_is_exactly_the_ui_assets_size(self) -> None:
        blob, _ = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        self.assertEqual(len(blob), bsua.UI_ASSETS_SIZE)

    def test_deterministic(self) -> None:
        blob1, manifest1 = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        blob2, manifest2 = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        self.assertEqual(blob1, blob2)
        self.assertEqual(manifest1["entries"], manifest2["entries"])

    def test_entries_are_placed_at_their_fixed_non_overlapping_slots(self) -> None:
        _, manifest = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        entries = {e["name"]: e for e in manifest["entries"]}
        self.assertEqual(len(entries), 5)
        self.assertEqual(entries["logo_sprinter"]["slot"], bsua.LOGO_SLOT)
        self.assertEqual(entries["marker_dot"]["slot"], bsua.DOT_SLOT)
        self.assertEqual(entries["marker_ring"]["slot"], bsua.RING_SLOT)
        self.assertEqual(entries["frame_cursor"]["slot"], bsua.CURSOR_SLOT)
        self.assertEqual(entries["frame_select"]["slot"], bsua.SELECT_SLOT)
        # A whole-cell frame is three slots, not one: the "does it still
        # fit its reserved span" check below is only meaningful if the
        # span really is the asset's own size.
        self.assertEqual(entries["frame_cursor"]["slots"], bsua.CURSOR_SLOTS)
        self.assertEqual(entries["frame_select"]["slots"], bsua.SELECT_SLOTS)
        # The frames must cover exactly one board cell -- a frame sized
        # anything else would draw a rectangle that does not line up with
        # the square it is supposed to mark.
        for name in ("frame_cursor", "frame_select"):
            self.assertEqual((entries[name]["width"], entries[name]["height"]),
                             (bsua.FRAME_W, bsua.FRAME_H))
        # No entry's reserved span reaches into the next entry's slot.
        ordered = sorted(manifest["entries"], key=lambda e: e["slot"])
        for prev, nxt in zip(ordered, ordered[1:]):
            self.assertLessEqual(prev["slot"] + prev["slots"], nxt["slot"])

    def test_logo_lands_at_the_expected_offset(self) -> None:
        blob, manifest = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        logo_entry = next(e for e in manifest["entries"] if e["name"] == "logo_sprinter")
        self.assertEqual(logo_entry["slot"], bsua.LOGO_SLOT)
        offset = (logo_entry["slot"] - bsua.UI_ASSETS_BASE_SLOT) * bsua.SLOT_SIZE
        # 40-wide solid idx1 tile: every byte is (1<<4)|1.
        self.assertEqual(blob[offset], (1 << 4) | 1)

    def test_unused_tail_stays_zero(self) -> None:
        blob, manifest = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        last = max(manifest["entries"], key=lambda e: e["slot"])
        tail_start = (last["slot"] - bsua.UI_ASSETS_BASE_SLOT + last["slots"]) * bsua.SLOT_SIZE
        self.assertEqual(blob[tail_start:], bytes(len(blob) - tail_start))

    def test_gap_between_logo_budget_and_markers_stays_zero(self) -> None:
        # The synthetic logo here is 1 slot; slots 45-49 (unused headroom
        # within its 6-slot budget) must stay zero, not carry stale bytes.
        blob, manifest = bsua.build_ui_assets(self.logo_path, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        logo_entry = next(e for e in manifest["entries"] if e["name"] == "logo_sprinter")
        self.assertLess(logo_entry["slots"], bsua.LOGO_MAX_SLOTS)
        gap_start = (bsua.LOGO_SLOT - bsua.UI_ASSETS_BASE_SLOT + logo_entry["slots"]) * bsua.SLOT_SIZE
        gap_end = (bsua.DOT_SLOT - bsua.UI_ASSETS_BASE_SLOT) * bsua.SLOT_SIZE
        self.assertEqual(blob[gap_start:gap_end], bytes(gap_end - gap_start))

    def test_wrong_marker_size_is_rejected(self) -> None:
        bad_dot = self._write_solid("bad_dot.png", 8, 8, _rgb(self.palette, 9))
        with self.assertRaises(SystemExit):
            bsua.build_ui_assets(self.logo_path, bad_dot, self.ring_path,
                                  self.cursor_path, self.select_path, self.palette)

    def test_too_tall_logo_is_rejected(self) -> None:
        # A logo can overflow port.md section 3.4's 16-row banner band while
        # still fitting comfortably inside its 6-slot budget (160x18 here is
        # 1440 B), so the slot check alone cannot catch it.
        tall_logo = self._write_solid("tall.png", 160, bsua.LOGO_MAX_H + 2,
                                       _rgb(self.palette, 1))
        with self.assertRaises(SystemExit) as cm:
            bsua.build_ui_assets(tall_logo, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        self.assertIn("exceeds its band", str(cm.exception))

    def test_logo_exactly_the_band_height_is_accepted(self) -> None:
        ok_logo = self._write_solid("band.png", 160, bsua.LOGO_MAX_H,
                                     _rgb(self.palette, 1))
        blob, _ = bsua.build_ui_assets(ok_logo, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)
        self.assertEqual(len(blob), bsua.UI_ASSETS_SIZE)

    def test_oversized_logo_exceeding_its_fixed_budget_is_rejected(self) -> None:
        # LOGO_MAX_SLOTS=6 (1536 B); a logo alone claiming more than that
        # must fail cleanly instead of silently colliding with the markers'
        # fixed slots.
        huge_logo = self._write_solid(
            "huge.png", bsua.LOGO_MAX_SLOTS * bsua.SLOT_SIZE * 2, 16, _rgb(self.palette, 1)
        )
        with self.assertRaises(SystemExit):
            bsua.build_ui_assets(huge_logo, self.dot_path, self.ring_path,
                                        self.cursor_path, self.select_path,
                                        self.palette)


class RenderCoreSlotContractTests(unittest.TestCase):
    """The frame slots live in two files that never see each other: the
    packer decides where the bytes land in the assets page, render_core.asm
    decides which slot to blit from. Nothing at build time links them --
    this port has already shipped one bug of exactly that shape (the
    overlay context buffer, which had two different addresses and a boot
    probe that silently read garbage). So pin them together here."""

    def setUp(self) -> None:
        self.source = RENDER_CORE_ASM.read_text(encoding="utf-8")

    def test_frame_slots_match_the_packer(self) -> None:
        self.assertEqual(_asm_equ(self.source, "CURSOR_FRAME_SLOT"),
                         bsua.CURSOR_SLOT)
        self.assertEqual(_asm_equ(self.source, "SELECT_FRAME_SLOT"),
                         bsua.SELECT_SLOT)

    def test_frame_blit_geometry_matches_the_packed_asset(self) -> None:
        # The blit is in 4bpp bytes (2 px each) by rows; the PNG is in
        # pixels. A frame blitted at the wrong width would read into the
        # next asset's bytes and paint garbage over the board.
        self.assertEqual(_asm_equ(self.source, "FRAME_W") * 2, bsua.FRAME_W)
        self.assertEqual(_asm_equ(self.source, "FRAME_ROWS"), bsua.FRAME_H)

    def test_frames_do_not_reach_into_the_next_slot(self) -> None:
        frame_bytes = (bsua.FRAME_W // 2) * bsua.FRAME_H
        for slots in (bsua.CURSOR_SLOTS, bsua.SELECT_SLOTS):
            self.assertLessEqual(frame_bytes, slots * bsua.SLOT_SIZE)
        self.assertLessEqual(bsua.CURSOR_SLOT + bsua.CURSOR_SLOTS,
                             bsua.SELECT_SLOT)
        self.assertLessEqual(bsua.SELECT_SLOT + bsua.SELECT_SLOTS,
                             bsua.UI_ASSETS_BASE_SLOT + bsua.UI_ASSETS_SLOT_COUNT)


if __name__ == "__main__":
    unittest.main()
