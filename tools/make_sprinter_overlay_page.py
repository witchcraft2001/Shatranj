#!/usr/bin/env python3
"""Build the Sprinter WIN3 overlay page: RULES + BOARD (plan D7-bis).

S5 substep 2's overlay mechanism (plan D2) copies a 2 KiB blob from the
assets page into a fixed slot. That ceiling does not survive contact with a
compiled C overlay of real size: BOARD (src/spectrum/overlay/board_apply_ovl.c
plus its entry table and helpers) links to 2772 bytes, and the assets page
has exactly one 2 KiB overlay slot free anyway, already spoken for by
CONTROL (tools/make_sprinter_assets_page.py's own header).

So RULES and BOARD are not copied at all. They are linked at their own ORG
inside the WIN3 window and mapped there with a single OUT
(asm/sprinter/zcc/overlay_loader_sprinter.asm's mode-1 dispatch). This tool
packs that page image: one 16384-byte WIN0-manifest asset page whose bytes,
once mapped into WIN3, appear at #C000-#FFFF.

Slot layout (asm/sprinter/zcc/overlay_atlas_table_sprinter.asm's
OVL_WIN3_BASE/OVL_WIN3_SLOT and the Makefile's -r link addresses must
match):
    0  #C000  RULES (SPECTRUM_OVL_RULES=0u)
    1  #D000  BOARD (SPECTRUM_OVL_BOARD=1u)
    2  #E000  reserved for GUI_LOG (SPECTRUM_OVL_GUI_LOG=2u) -- zero
    3  #F000  reserved for STATUS (SPECTRUM_OVL_STATUS=7u) -- zero

Published to HDR as the fourth asset page (HDR_ASSET_PAGE0_OFFSET+3);
asm/sprinter/buffers.asm's bench_init reads it into ovl_win3_page with the
same "#FF when unavailable" convention piece_page1/piece_page2 use.

The output is a pure function of the inputs (no timestamps), same contract
as tools/make_sprinter_assets_page.py.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

PAGE_SIZE = 16384

# Must match overlay_atlas_table_sprinter.asm's OVL_WIN3_BASE/OVL_WIN3_SLOT.
WIN3_BASE = 0xC000
SLOT_SIZE = 0x1000
SLOT_COUNT = PAGE_SIZE // SLOT_SIZE  # 4

RULES_SLOT = 0
BOARD_SLOT = 1
# GUI_LOG/STATUS: slots 2/3, reserved, left zero until ported.


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def slot_org(slot: int) -> int:
    """Link address (-r) an overlay in this slot must be built at."""
    return WIN3_BASE + slot * SLOT_SIZE


def build_overlay_page(rules_bin: bytes | None = None,
                        board_bin: bytes | None = None) -> bytes:
    page = bytearray(PAGE_SIZE)

    def place(slot: int, data: bytes, name: str) -> None:
        if len(data) > SLOT_SIZE:
            fail(f"{name} is {len(data)} bytes, exceeds the {SLOT_SIZE}-byte "
                 f"WIN3 overlay slot (base {slot_org(slot):#06x})")
        offset = slot * SLOT_SIZE
        page[offset:offset + len(data)] = data

    if rules_bin is not None:
        place(RULES_SLOT, rules_bin, "rules-bin")
    if board_bin is not None:
        place(BOARD_SLOT, board_bin, "board-bin")

    data = bytes(page)
    assert len(data) == PAGE_SIZE
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rules-bin", type=Path,
                        help="RULES overlay .bin (entries 0/1 only, S5 "
                             "substep 3b); omit to leave slot 0 zero")
    parser.add_argument("--board-bin", type=Path,
                        help="BOARD overlay .bin (all four entries, S5 "
                             "substep 3b); omit to leave slot 1 zero")
    parser.add_argument("--print-slot-org", type=int, metavar="SLOT",
                        help="print the -r link address for SLOT and exit "
                             "(the Makefile's link rules read it from here "
                             "instead of hardcoding #C000/#D000)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    if args.print_slot_org is not None:
        if not 0 <= args.print_slot_org < SLOT_COUNT:
            fail(f"slot {args.print_slot_org} out of range (0..{SLOT_COUNT - 1})")
        print(f"0x{slot_org(args.print_slot_org):04X}")
        return 0

    if args.output is None:
        fail("--output is required unless --print-slot-org is given")

    rules_bin = None
    if args.rules_bin is not None:
        if not args.rules_bin.is_file():
            fail(f"missing rules-bin: {args.rules_bin}")
        rules_bin = args.rules_bin.read_bytes()

    board_bin = None
    if args.board_bin is not None:
        if not args.board_bin.is_file():
            fail(f"missing board-bin: {args.board_bin}")
        board_bin = args.board_bin.read_bytes()

    page = build_overlay_page(rules_bin, board_bin)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(page)
    digest = hashlib.sha256(page).hexdigest()
    print(f"[OK] {args.output}: {len(page)} bytes, sha256 {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
