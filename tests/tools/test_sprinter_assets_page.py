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
        tail = page[34 * msap.SLOT_SIZE:]
        self.assertEqual(tail, bytes(len(tail)))

    def test_font_bin_size_guard(self) -> None:
        with self.assertRaises(SystemExit):
            msap.build_assets_page(b"\x00" * (msap.FONT_BIN_SIZE - 1))


if __name__ == "__main__":
    unittest.main()
