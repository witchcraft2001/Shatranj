#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_overlay_page.py (S5 substep 3b,
plan D7-bis's WIN3-mapped overlay page)."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import make_sprinter_overlay_page as msop

ATLAS_ASM = ROOT / "asm/sprinter/zcc/overlay_atlas_table_sprinter.asm"


class SprinterOverlayPageTests(unittest.TestCase):
    def test_output_is_exactly_one_page(self) -> None:
        self.assertEqual(len(msop.build_overlay_page()), msop.PAGE_SIZE)

    def test_empty_page_is_all_zero(self) -> None:
        self.assertEqual(msop.build_overlay_page(), bytes(msop.PAGE_SIZE))

    def test_deterministic(self) -> None:
        rules, board = b"\x01" * 100, b"\x02" * 200
        self.assertEqual(msop.build_overlay_page(rules, board),
                         msop.build_overlay_page(rules, board))

    def test_rules_and_board_land_at_their_own_slots(self) -> None:
        rules = b"\xAA" * msop.SLOT_SIZE
        board = b"\xBB" * msop.SLOT_SIZE
        page = msop.build_overlay_page(rules, board)
        self.assertNotEqual(msop.RULES_SLOT, msop.BOARD_SLOT)
        for slot, expected in ((msop.RULES_SLOT, rules), (msop.BOARD_SLOT, board)):
            span = page[slot * msop.SLOT_SIZE:(slot + 1) * msop.SLOT_SIZE]
            self.assertEqual(span, expected)

    def test_oversized_overlay_is_rejected(self) -> None:
        too_big = b"\x00" * (msop.SLOT_SIZE + 1)
        with self.assertRaises(SystemExit):
            msop.build_overlay_page(too_big)
        with self.assertRaises(SystemExit):
            msop.build_overlay_page(None, too_big)

    def test_slot_orgs_are_inside_the_win3_window(self) -> None:
        # The whole point of D7-bis: these are addresses the overlay is
        # LINKED at, so they must land in WIN3 (#C000-#FFFF), not anywhere
        # in the resident's own #4000-#BFFF.
        for slot in range(msop.SLOT_COUNT):
            org = msop.slot_org(slot)
            self.assertGreaterEqual(org, 0xC000)
            self.assertLess(org, 0x10000)
        self.assertEqual(msop.slot_org(msop.RULES_SLOT), 0xC000)
        self.assertEqual(msop.slot_org(msop.BOARD_SLOT), 0xD000)

    def test_atlas_table_agrees_with_this_packing(self) -> None:
        """The atlas table's mode-1 entries are absolute WIN3 addresses; if
        this tool's packing and that table ever disagree, the loader
        dispatches into the middle of another overlay. Pin them together."""
        text = ATLAS_ASM.read_text(encoding="utf-8")
        base = re.search(r"^OVL_WIN3_BASE EQU (0x[0-9A-Fa-f]+)", text, re.M)
        slot = re.search(r"^OVL_WIN3_SLOT EQU (0x[0-9A-Fa-f]+)", text, re.M)
        self.assertIsNotNone(base, "OVL_WIN3_BASE missing from the atlas table")
        self.assertIsNotNone(slot, "OVL_WIN3_SLOT missing from the atlas table")
        self.assertEqual(int(base.group(1), 16), msop.WIN3_BASE)
        self.assertEqual(int(slot.group(1), 16), msop.SLOT_SIZE)

        # RULES/BOARD must be declared mode 1 (mapped), not mode 0 (copied):
        # a 2772-byte BOARD silently truncated into the 2 KiB copy slot is
        # exactly the failure this pass exists to avoid.
        modes = re.search(r"^ovl_atlas_mode_table:\n((?:\s+defb.*\n)+)",
                          text, re.M)
        self.assertIsNotNone(modes, "ovl_atlas_mode_table missing")
        entries = re.findall(r"defb\s+(OVL_MODE_\w+)", modes.group(1))
        self.assertEqual(len(entries), 15, "mode table must cover ids 0-14")
        self.assertEqual(entries[0], "OVL_MODE_WIN3")   # RULES
        self.assertEqual(entries[1], "OVL_MODE_WIN3")   # BOARD
        self.assertEqual(entries[14], "OVL_MODE_COPY")  # CONTROL, unchanged


if __name__ == "__main__":
    unittest.main()
