#!/usr/bin/env python3
"""Byte-level checks on the linked CONTROL overlay (build/sprinter/overlay_control_sprinter.bin).

CONTROL (SPECTRUM_OVL_CONTROL=14u, plan D7) is the first real overlay ported
to Sprinter -- src/spectrum/overlay/control_ovl.c, the same source ZX links,
compiled with the zcc+z80asm pipeline proven in S5 substep 1/2 and linked
against the resident's own game_protocol.c/mqtt_session_protocol.c via
tools/gen_sprinter_overlay_defs.py's generated externs (not duplicated into
the overlay slot -- see the Makefile comment above
$(SPRINTER_OVL_CONTROL_BIN)). This is a build-product/size check only: the
blob is not yet embedded in the assets page or
asm/sprinter/zcc/overlay_atlas_table_sprinter.asm (port.md explains why --
the current assets page has room for exactly one 2 KiB overlay slot, still
holding the S3 proof payload).
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OVL_BIN = ROOT / "build/sprinter/overlay_control_sprinter.bin"
LAYOUT_JSON = ROOT / "src/sprinter/fixed_layout.json"


def _layout_symbol(name: str) -> int:
    out = subprocess.run(
        [sys.executable, str(ROOT / "tools/gen_sprinter_layout.py"),
         "--layout", str(LAYOUT_JSON), "--print-symbol", name],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return int(out, 16)


class SprinterOverlayControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not OVL_BIN.is_file():
            raise unittest.SkipTest(
                f"{OVL_BIN} missing; run 'make build/sprinter/overlay_control_sprinter.bin' first"
            )
        cls.data = OVL_BIN.read_bytes()
        cls.slot_addr = _layout_symbol("OVL_SLOT_ADDR")
        cls.slot_size = _layout_symbol("OVL_SLOT_SIZE")

    def test_fits_the_ovl_slot_budget(self) -> None:
        # The whole point: -clib=default's classic backend is noticeably
        # bulkier than ZX's SDCC build of the same source (an early attempt
        # that duplicated game_protocol.c/mqtt_session_protocol.c into this
        # same slot measured 3072 bytes, over budget -- externing the
        # resident's one copy instead brought it back under 2 KiB).
        self.assertGreater(len(self.data), 0)
        self.assertLessEqual(len(self.data), self.slot_size)

    def test_entry_count_byte_is_one(self) -> None:
        # Same slot-header shape as asm/overlay/control/entry_control.asm
        # and overlay_loader_sprinter.asm's ovl_dispatch: byte 0 = entry
        # count.
        self.assertEqual(self.data[0], 1)

    def test_entry_table_word_is_a_valid_in_slot_address(self) -> None:
        # Bytes 1-2 = the one entry's absolute address (little-endian),
        # produced by z80asm's -r<OVL_SLOT_ADDR> relocation -- must land
        # strictly after the 3-byte header and before the slot's end.
        entry_addr = int.from_bytes(self.data[1:3], "little")
        self.assertGreaterEqual(entry_addr, self.slot_addr + 3)
        self.assertLess(entry_addr, self.slot_addr + self.slot_size)

    def test_entry_target_is_inside_the_linked_blob(self) -> None:
        entry_addr = int.from_bytes(self.data[1:3], "little")
        offset = entry_addr - self.slot_addr
        self.assertLess(offset, len(self.data))


if __name__ == "__main__":
    unittest.main()
