#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_overlay_page.py (S6 plan step 2's
declarative WIN3 overlay-page layout table, replacing the original uniform
4x4 KiB scheme)."""

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

    def test_layout_budgets_sum_to_one_page(self) -> None:
        self.assertEqual(sum(budget for _, budget in msop.LAYOUT), msop.PAGE_SIZE)

    def test_deterministic(self) -> None:
        rules, board = b"\x01" * 100, b"\x02" * 200
        self.assertEqual(msop.build_overlay_page(rules=rules, board=board),
                         msop.build_overlay_page(rules=rules, board=board))

    def test_each_overlay_lands_at_its_own_slot(self) -> None:
        fills = {name.lower(): bytes([i + 1]) * msop.slot_budget(name)
                 for i, name in enumerate(msop.OVERLAY_NAMES)}
        page = msop.build_overlay_page(**fills)
        orgs = sorted(msop.slot_org(name) for name in msop.OVERLAY_NAMES)
        self.assertEqual(len(orgs), len(set(orgs)), "overlay orgs must be distinct")
        for i, name in enumerate(msop.OVERLAY_NAMES):
            data = fills[name.lower()]
            offset = msop.slot_org(name) - msop.WIN3_BASE
            span = page[offset:offset + len(data)]
            self.assertEqual(span, data, f"{name} did not land at its own slot")

    def test_oversized_overlay_is_rejected(self) -> None:
        for name in msop.OVERLAY_NAMES:
            too_big = b"\x00" * (msop.slot_budget(name) + 1)
            with self.assertRaises(SystemExit):
                msop.build_overlay_page(**{name.lower(): too_big})

    def test_unknown_overlay_keyword_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            msop.build_overlay_page(nonexistent=b"\x00")

    def test_slot_orgs_are_inside_the_win3_window(self) -> None:
        # The whole point of D7-bis: these are addresses the overlay is
        # LINKED at, so they must land in WIN3 (#C000-#FFFF), not anywhere
        # in the resident's own #4000-#BFFF.
        for name in msop.OVERLAY_NAMES:
            org = msop.slot_org(name)
            self.assertGreaterEqual(org, 0xC000)
            self.assertLess(org, 0x10000)
        self.assertEqual(msop.slot_org("RULES"), 0xC000)
        self.assertEqual(msop.slot_org("BOARD"), 0xC800)
        self.assertEqual(msop.slot_org("SAVELOAD"), 0xD400)
        self.assertEqual(msop.slot_org("RESTORE"), 0xDE00)
        self.assertEqual(msop.slot_org("FILEUI"), 0xEA00)

    def test_unknown_name_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            msop.slot_org("NOT_A_REAL_OVERLAY")
        with self.assertRaises(SystemExit):
            msop.slot_budget("NOT_A_REAL_OVERLAY")

    def test_atlas_table_agrees_with_this_packing(self) -> None:
        """The atlas table's mode-1 entries are absolute WIN3 addresses; if
        this tool's packing and that table ever disagree, the loader
        dispatches into the middle of another overlay. Pin them together."""
        text = ATLAS_ASM.read_text(encoding="utf-8")
        for name in msop.OVERLAY_NAMES + msop.OVERLAY_NAMES2:
            match = re.search(rf"^OVL_WIN3_{name}_ORG\s+EQU\s+(0x[0-9A-Fa-f]+)",
                              text, re.M)
            self.assertIsNotNone(match, f"OVL_WIN3_{name}_ORG missing from the atlas table")
            self.assertEqual(int(match.group(1), 16), msop.slot_org(name))

        # RULES/BOARD/SAVELOAD/RESTORE/FILEUI/NET/INPUT_EDIT must be
        # declared mode 1 (mapped), not mode 0 (copied): a 2772-byte BOARD
        # silently truncated into a 2 KiB copy slot is exactly the failure
        # this pass exists to avoid.
        modes = re.search(r"^ovl_atlas_mode_table:\n((?:\s+defb.*\n)+)",
                          text, re.M)
        self.assertIsNotNone(modes, "ovl_atlas_mode_table missing")
        entries = re.findall(r"defb\s+(OVL_MODE_\w+)", modes.group(1))
        self.assertEqual(len(entries), 15, "mode table must cover ids 0-14")
        win3_ids = {0: "RULES", 1: "BOARD", 3: "NET", 9: "INPUT_EDIT",
                    10: "SAVELOAD", 11: "RESTORE", 13: "FILEUI"}
        for idx, name in win3_ids.items():
            self.assertEqual(entries[idx], "OVL_MODE_WIN3", name)
        self.assertEqual(entries[14], "OVL_MODE_COPY")  # CONTROL, unchanged

    def test_page2_layout_budgets_sum_to_one_page(self) -> None:
        self.assertEqual(sum(budget for _, budget in msop.LAYOUT2), msop.PAGE_SIZE)

    def test_page2_output_is_exactly_one_page_and_zero_when_empty(self) -> None:
        page = msop.build_overlay_page(page=2)
        self.assertEqual(len(page), msop.PAGE_SIZE)
        self.assertEqual(page, bytes(msop.PAGE_SIZE))

    def test_net_lands_at_its_own_slot_on_page_2(self) -> None:
        data = b"\x2au" * (msop.slot_budget("NET") // 2)
        page = msop.build_overlay_page(page=2, net=data)
        offset = msop.slot_org("NET") - msop.WIN3_BASE
        self.assertEqual(page[offset:offset + len(data)], data)

    def test_net_org_restarts_at_win3_base_like_page_1(self) -> None:
        # Both pages map into the same #C000-#FFFF hardware window -- only
        # one is ever mapped at a time -- so page 2's own first slot must
        # restart at WIN3_BASE exactly like page 1's RULES does.
        self.assertEqual(msop.slot_org("NET"), 0xC000)

    def test_input_edit_lands_at_its_own_slot_on_page_2(self) -> None:
        data = b"\x2au" * (msop.slot_budget("INPUT_EDIT") // 2)
        page = msop.build_overlay_page(page=2, input_edit=data)
        offset = msop.slot_org("INPUT_EDIT") - msop.WIN3_BASE
        self.assertEqual(page[offset:offset + len(data)], data)

    def test_input_edit_org_follows_net(self) -> None:
        # INPUT_EDIT is the second slot on page 2 (S9 chat pass), right
        # after NET's own 8192 bytes.
        self.assertEqual(msop.slot_org("INPUT_EDIT"),
                         msop.slot_org("NET") + msop.slot_budget("NET"))

    def test_page2_oversized_overlay_is_rejected(self) -> None:
        too_big = b"\x00" * (msop.slot_budget("NET") + 1)
        with self.assertRaises(SystemExit):
            msop.build_overlay_page(page=2, net=too_big)

    def test_page1_keyword_is_rejected_on_page_2(self) -> None:
        with self.assertRaises(SystemExit):
            msop.build_overlay_page(page=2, rules=b"\x00")


if __name__ == "__main__":
    unittest.main()
