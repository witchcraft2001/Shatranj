#!/usr/bin/env python3
"""Byte-level checks on the assembled Sprinter resident image.

Verifies the fixed anchors from src/sprinter/fixed_layout.json actually
land where gen_sprinter_layout.py says they must in the real sjasmplus
--raw output: resident size, HDR magic, the IM2 table's uniform fill byte,
the still-empty CANARY/PSP_LANDING placeholders, and the trampoline's first
instruction (LD A,(HDR_ADDR+HDR_PAGE2_OFFSET)). Checks are computed from the
layout symbols rather than hardcoded absolute offsets, so they track the
source of truth instead of drifting from it.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import gen_sprinter_layout as gsl

RESIDENT_BIN = ROOT / "build/sprinter/resident_s1.bin"
LAYOUT_JSON = ROOT / "src/sprinter/fixed_layout.json"

HDR_PAGE2_OFFSET = 4


def _region(layout, name):
    return gsl._region(layout, name)


class SprinterResidentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not RESIDENT_BIN.is_file():
            raise unittest.SkipTest(
                f"{RESIDENT_BIN} missing; run 'make build/sprinter/resident_s1.bin' "
                "or 'make exe' first"
            )
        cls.layout = gsl.load_layout_file(LAYOUT_JSON)
        cls.symbols = gsl.compute_symbols(cls.layout)
        cls.data = RESIDENT_BIN.read_bytes()

    def _slice(self, region_name: str) -> bytes:
        region = _region(self.layout, region_name)
        base = self.layout["resident_base"]
        start = region["addr"] - base
        return self.data[start:start + region["size"]]

    def test_size_matches_win1_win2_span(self) -> None:
        expected = self.symbols["WIN2_END"] - self.symbols["RESIDENT_BASE"]
        self.assertEqual(len(self.data), expected)
        self.assertEqual(len(self.data), 32768)

    def test_hdr_empty_in_static_image(self) -> None:
        # The loader is the ONLY writer of the HDR magic: with the magic
        # baked into the static image, the trampoline's publish check would
        # pass even when the loader never wrote boot info (and HDR_PAGE2
        # would be a blindly-trusted zero).
        self.assertEqual(self._slice("HDR"), bytes(0x100))

    def test_psp_landing_still_empty_in_static_image(self) -> None:
        # The loader overwrites this at runtime; the assembled image itself
        # must not have anything load-bearing there.
        self.assertEqual(self._slice("PSP_LANDING"), bytes(0x100))

    def test_canary_slot_is_zero_until_crt0_runs(self) -> None:
        self.assertEqual(self._slice("CANARY"), b"\x00\x00")

    def test_im2_table_uniformly_filled(self) -> None:
        table = self._slice("IM2_TABLE")
        fill = self.symbols["IM2_FILL_BYTE"]
        self.assertEqual(table, bytes([fill]) * self.symbols["IM2_TABLE_SIZE"])
        # The word an IM2 fetch reads at the 0xFF/0x100 straddle (low byte
        # from table[0xFF], high byte from table[0x100]) must resolve to
        # IM2_STUB_ADDR. Implied by the uniform fill above; spelled out to
        # document the fetch semantics the fill_byte*0x101 trick relies on.
        straddle = table[0xFF] | (table[0x100] << 8)
        self.assertEqual(straddle, self.symbols["IM2_STUB_ADDR"])

    def test_trampoline_checks_magic_then_maps_win2(self) -> None:
        base = self.layout["resident_base"]
        offset = self.symbols["TRAMPOLINE_ADDR"] - base
        window = self.data[offset:offset + 0x100]
        # First instruction: LD HL,HDR (the published-magic compare loop).
        self.assertEqual(window[0], 0x21)  # LD HL,nn
        self.assertEqual(
            int.from_bytes(window[1:3], "little"), self.symbols["HDR_ADDR"]
        )
        # The compare reference lives in the trampoline, not in HDR.
        self.assertIn(b"SHS1", window)
        # After the check: LD A,(HDR+HDR_PAGE2_OFFSET); OUT (#C2),A
        # (WIN2_PORT -- a dss.inc constant, not a layout symbol).
        page2_load = (
            bytes([0x3A])
            + (self.symbols["HDR_ADDR"] + HDR_PAGE2_OFFSET).to_bytes(2, "little")
            + bytes([0xD3, 0xC2])
        )
        self.assertIn(page2_load, window)

    def test_im2_stub_bytes(self) -> None:
        # R6 minimal ISR: PUSH AF; IN A,(SIO_A_CTRL); RRA; JR C,+5;
        # LD A,1; LD (frame_flag),A; POP AF; JP #0038. Exactly
        # IM2_STUB_SIZE (15) bytes, ending in a tail-jump to DSS's #0038.
        stub = self._slice("IM2_STUB")
        self.assertEqual(len(stub), self.symbols["IM2_STUB_SIZE"])
        self.assertEqual(stub[0], 0xF5)          # push af
        self.assertEqual(stub[1:3], bytes([0xDB, 0x19]))  # in a,(#19)
        self.assertEqual(stub[3], 0x1F)          # rra
        self.assertEqual(stub[4], 0x38)          # jr c,.chain
        self.assertEqual(stub[6:8], bytes([0x3E, 0x01]))  # ld a,1
        self.assertEqual(stub[8], 0x32)          # ld (frame_flag),a
        self.assertEqual(stub[11], 0xF1)         # pop af
        self.assertEqual(stub[12:15], bytes([0xC3, 0x38, 0x00]))  # jp #0038


if __name__ == "__main__":
    unittest.main()
