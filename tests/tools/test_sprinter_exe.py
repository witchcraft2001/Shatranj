#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_exe.py (DSS EXE header format)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import make_sprinter_exe as mse


class SprinterExeHeaderTests(unittest.TestCase):
    def test_header_layout(self) -> None:
        body = bytes(range(64))
        exe = mse.build_exe(body, "9.9.9")
        self.assertEqual(len(exe), mse.EXE_HEADER_SIZE + len(body))
        self.assertEqual(exe[0:3], b"EXE")
        self.assertEqual(exe[3], mse.EXE_VERSION)
        self.assertEqual(int.from_bytes(exe[4:8], "little"), mse.EXE_HEADER_SIZE)
        self.assertEqual(int.from_bytes(exe[8:10], "little"), len(body))
        self.assertEqual(exe[10:16], bytes(6))
        self.assertEqual(int.from_bytes(exe[16:18], "little"), mse.LD_ADDR)
        self.assertEqual(int.from_bytes(exe[18:20], "little"), mse.PC_REG)
        self.assertEqual(int.from_bytes(exe[20:22], "little"), mse.SP_REG)
        self.assertIn(b"v9.9.9", exe[22:mse.EXE_HEADER_SIZE])
        self.assertEqual(exe[mse.EXE_HEADER_SIZE:], body)

    def test_loader_field_selects_preload_path(self) -> None:
        # port.md section 3.2 invariant: LOADER@8 must be non-zero so DSS
        # takes the PRELOAD path and keeps the file handle open in the PSP.
        exe = mse.build_exe(b"\x00", "1.0")
        self.assertNotEqual(exe[8:10], b"\x00\x00")

    def test_deterministic(self) -> None:
        body = b"\xC3\x00\x81" * 100
        self.assertEqual(mse.build_exe(body, "1.2"), mse.build_exe(body, "1.2"))

    def test_body_size_guard(self) -> None:
        with self.assertRaises(SystemExit):
            mse.build_exe(b"\x00" * (mse.MAX_BODY_SIZE + 1), "1.0")
        with self.assertRaises(SystemExit):
            mse.build_exe(b"", "1.0")

    def test_addresses_match_contract(self) -> None:
        # Loader contract from port.md section 3.2 (Estex-DSS EXE_Header.z80).
        self.assertEqual(mse.LD_ADDR, 0x8100)
        self.assertEqual(mse.PC_REG, 0x8100)
        self.assertEqual(mse.SP_REG, 0xBFF0)


if __name__ == "__main__":
    unittest.main()
