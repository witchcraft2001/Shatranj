#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_assets_page.py (S2 assets page)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import make_sprinter_assets_page as msap

FONT_BIN = (
    Path(__file__).resolve().parent.parent.parent
    / "extern/sprinter-libs/afnt640/font.bin"
)


class SprinterAssetsPageTests(unittest.TestCase):
    def test_pinned_font_bin_has_the_expected_size(self) -> None:
        # A hard prerequisite for every other test here: if this drifts, the
        # submodule pin moved and check_sprinter_deps.py should catch it too.
        self.assertTrue(FONT_BIN.is_file(), f"missing {FONT_BIN}")
        self.assertEqual(len(FONT_BIN.read_bytes()), msap.FONT_BIN_SIZE)

    def test_output_is_exactly_one_page(self) -> None:
        page = msap.build_assets_page(FONT_BIN.read_bytes())
        self.assertEqual(len(page), msap.PAGE_SIZE)

    def test_deterministic(self) -> None:
        font = FONT_BIN.read_bytes()
        self.assertEqual(msap.build_assets_page(font), msap.build_assets_page(font))

    def test_font_lands_at_slot_zero(self) -> None:
        font = FONT_BIN.read_bytes()
        page = msap.build_assets_page(font)
        self.assertEqual(page[0:len(font)], font)
        # The padding to the end of slot 26 must be zero, not garbage.
        pad_start = len(font)
        pad_end = (msap.FONT_SLOT_COUNT) * msap.SLOT_SIZE
        self.assertEqual(page[pad_start:pad_end], bytes(pad_end - pad_start))

    def test_tile_slots_are_populated_and_non_overlapping(self) -> None:
        font = FONT_BIN.read_bytes()
        page = msap.build_assets_page(font)
        slots = {
            msap.TILE_A_SLOT: 1,
            msap.TILE_B_SLOT: 1,
            msap.TILE_KEY_SLOT: 1,
            msap.TILE_C_SLOT: 1,
            msap.TILE_WIDE_SLOT: msap.TILE_WIDE_SLOTS,
        }
        # No two tiles claim the same slot range.
        claimed = set()
        for slot, count in slots.items():
            for s in range(slot, slot + count):
                self.assertNotIn(s, claimed, f"slot {s} claimed twice")
                claimed.add(s)
            span = page[slot * msap.SLOT_SIZE:(slot + count) * msap.SLOT_SIZE]
            self.assertTrue(any(b != 0 for b in span), f"slot {slot} is all-zero")

    def test_tile_wide_is_512_byte_aligned(self) -> None:
        self.assertEqual((msap.TILE_WIDE_SLOT * msap.SLOT_SIZE) % 512, 0)

    def test_key_tile_uses_only_full_ff_or_opaque_bytes(self) -> None:
        # port.md section 3.3: the hardware alias skips whole #FF bytes, not
        # single nibbles -- a mixed-nibble byte here would silently degrade
        # to a solid colour or a stray transparent pixel on real hardware.
        font = FONT_BIN.read_bytes()
        page = msap.build_assets_page(font)
        start = msap.TILE_KEY_SLOT * msap.SLOT_SIZE
        tile = page[start:start + msap.TILE32_STRIDE * msap.TILE32_H]
        for byte in tile:
            if byte != 0xFF:
                hi, lo = byte >> 4, byte & 0xF
                self.assertEqual(hi, lo, f"mixed-nibble byte {byte:#04x} in key tile")
        self.assertIn(0xFF, tile, "key tile never uses the transparency key")
        self.assertTrue(any(b != 0xFF for b in tile), "key tile is fully transparent")

    def test_unused_slots_stay_zero(self) -> None:
        font = FONT_BIN.read_bytes()
        page = msap.build_assets_page(font)
        gap = page[27 * msap.SLOT_SIZE:28 * msap.SLOT_SIZE]
        self.assertEqual(gap, bytes(msap.SLOT_SIZE))
        # Without --overlay-bin, slots 36-43 stay zero along with the rest
        # of the tail.
        tail = page[34 * msap.SLOT_SIZE:]
        self.assertEqual(tail, bytes(len(tail)))

    def test_font_bin_size_guard(self) -> None:
        with self.assertRaises(SystemExit):
            msap.build_assets_page(b"\x00" * (msap.FONT_BIN_SIZE - 1))

    def test_overlay_lands_at_its_slot_and_is_deterministic(self) -> None:
        font = FONT_BIN.read_bytes()
        overlay = bytes((i * 7) & 0xFF for i in range(msap.OVERLAY_SIZE))
        page = msap.build_assets_page(font, overlay)
        start = msap.OVERLAY_SLOT * msap.SLOT_SIZE
        self.assertEqual(page[start:start + msap.OVERLAY_SIZE], overlay)
        self.assertEqual(
            msap.build_assets_page(font, overlay),
            msap.build_assets_page(font, overlay),
        )

    def test_overlay_gap_and_tail_stay_zero(self) -> None:
        font = FONT_BIN.read_bytes()
        overlay = bytes((i * 7) & 0xFF for i in range(msap.OVERLAY_SIZE))
        page = msap.build_assets_page(font, overlay)
        # Slots 34-35: the deliberate gap before the overlay.
        gap = page[34 * msap.SLOT_SIZE:msap.OVERLAY_SLOT * msap.SLOT_SIZE]
        self.assertEqual(gap, bytes(len(gap)))
        # Slots 44-63: unused tail after the overlay.
        tail_start = (msap.OVERLAY_SLOT + msap.OVERLAY_SLOTS) * msap.SLOT_SIZE
        tail = page[tail_start:]
        self.assertEqual(tail, bytes(len(tail)))

    def test_overlay_does_not_collide_with_tile_wide(self) -> None:
        # TILE_WIDE occupies slots 32-33; the overlay must start strictly
        # after it, with the documented 34-35 gap intact.
        self.assertGreaterEqual(
            msap.OVERLAY_SLOT, msap.TILE_WIDE_SLOT + msap.TILE_WIDE_SLOTS
        )

    def test_overlay_bin_size_guard(self) -> None:
        # Real overlay content (e.g. build/sprinter/overlay_control_sprinter.bin,
        # S5 substep 2) varies in size and is smaller than the fixed 2 KiB
        # OVL_SLOT -- shorter is fine and zero-padded (ovl_copy_slot always
        # LDIRs exactly OVERLAY_SIZE bytes regardless of how much of that
        # span is "real"); only exceeding the slot is an error.
        font = FONT_BIN.read_bytes()
        page = msap.build_assets_page(font, b"\xAA" * (msap.OVERLAY_SIZE - 1))
        offset = msap.OVERLAY_SLOT * msap.SLOT_SIZE
        self.assertEqual(page[offset:offset + msap.OVERLAY_SIZE - 1], b"\xAA" * (msap.OVERLAY_SIZE - 1))
        self.assertEqual(page[offset + msap.OVERLAY_SIZE - 1], 0)
        with self.assertRaises(SystemExit):
            msap.build_assets_page(font, b"\x00" * (msap.OVERLAY_SIZE + 1))

    def test_overlay_omitted_is_backward_compatible(self) -> None:
        font = FONT_BIN.read_bytes()
        self.assertEqual(
            msap.build_assets_page(font),
            msap.build_assets_page(font, None),
        )

    def test_theme_lands_at_slot_27_and_is_deterministic(self) -> None:
        font = FONT_BIN.read_bytes()
        theme = bytes((i * 3) & 0xFF for i in range(84))
        page = msap.build_assets_page(font, theme_bin=theme)
        start = msap.THEME_SLOT * msap.SLOT_SIZE
        self.assertEqual(page[start:start + len(theme)], theme)
        # Padding to the end of the theme slot must be zero, not garbage.
        pad_start = start + len(theme)
        pad_end = start + msap.THEME_MAX_SIZE
        self.assertEqual(page[pad_start:pad_end], bytes(pad_end - pad_start))
        self.assertEqual(
            msap.build_assets_page(font, theme_bin=theme),
            msap.build_assets_page(font, theme_bin=theme),
        )

    def test_theme_bin_size_guard(self) -> None:
        font = FONT_BIN.read_bytes()
        with self.assertRaises(SystemExit):
            msap.build_assets_page(font, theme_bin=b"\x00" * (msap.THEME_MAX_SIZE + 1))

    def test_theme_omitted_is_backward_compatible(self) -> None:
        font = FONT_BIN.read_bytes()
        self.assertEqual(
            msap.build_assets_page(font),
            msap.build_assets_page(font, theme_bin=None),
        )

    def test_theme_does_not_collide_with_tile_a(self) -> None:
        self.assertLessEqual(msap.THEME_SLOT + msap.THEME_SLOTS, msap.TILE_A_SLOT)

    def test_ui_assets_land_at_slot_44_and_are_deterministic(self) -> None:
        font = FONT_BIN.read_bytes()
        ui_bin = bytes((i * 11) & 0xFF for i in range(msap.UI_ASSETS_MAX_SIZE))
        page = msap.build_assets_page(font, ui_bin=ui_bin)
        start = msap.UI_ASSETS_SLOT * msap.SLOT_SIZE
        self.assertEqual(page[start:start + len(ui_bin)], ui_bin)
        self.assertEqual(
            msap.build_assets_page(font, ui_bin=ui_bin),
            msap.build_assets_page(font, ui_bin=ui_bin),
        )

    def test_ui_bin_size_guard(self) -> None:
        font = FONT_BIN.read_bytes()
        with self.assertRaises(SystemExit):
            msap.build_assets_page(font, ui_bin=b"\x00" * (msap.UI_ASSETS_MAX_SIZE - 1))
        with self.assertRaises(SystemExit):
            msap.build_assets_page(font, ui_bin=b"\x00" * (msap.UI_ASSETS_MAX_SIZE + 1))

    def test_ui_bin_omitted_is_backward_compatible(self) -> None:
        font = FONT_BIN.read_bytes()
        self.assertEqual(
            msap.build_assets_page(font),
            msap.build_assets_page(font, ui_bin=None),
        )

    def test_ui_assets_start_immediately_after_the_overlay(self) -> None:
        self.assertEqual(msap.UI_ASSETS_SLOT, msap.OVERLAY_SLOT + msap.OVERLAY_SLOTS)

    def test_ui_assets_fill_the_page_to_its_end(self) -> None:
        self.assertEqual(msap.UI_ASSETS_SLOT + msap.UI_ASSETS_SLOTS, 64)


if __name__ == "__main__":
    unittest.main()
