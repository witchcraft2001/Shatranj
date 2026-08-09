#!/usr/bin/env python3
"""Unit tests for tools/make_sprinter_exe.py (DSS EXE header + STM1 manifest)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "tools"))

import make_sprinter_exe as mse
import gen_sprinter_layout as gsl

LAYOUT = gsl.load_layout_file(Path(__file__).resolve().parent.parent.parent
                              / "src/sprinter/fixed_layout.json")
PAGE_SIZE = 0x4000


class SprinterExeHeaderTests(unittest.TestCase):
    def test_header_layout(self) -> None:
        loader = bytes(range(64))
        resident = bytes(range(256)) * (2 * PAGE_SIZE // 256)
        exe = mse.build_exe(loader, resident, "9.9.9", layout=LAYOUT)
        self.assertEqual(exe[0:3], b"EXE")
        self.assertEqual(exe[3], mse.EXE_VERSION)
        self.assertEqual(int.from_bytes(exe[4:8], "little"), mse.EXE_HEADER_SIZE)
        self.assertEqual(int.from_bytes(exe[8:10], "little"), len(loader))
        self.assertEqual(exe[10:16], bytes(6))
        self.assertEqual(int.from_bytes(exe[16:18], "little"), mse.LD_ADDR)
        self.assertEqual(int.from_bytes(exe[18:20], "little"), mse.PC_REG)
        self.assertEqual(int.from_bytes(exe[20:22], "little"), mse.SP_REG)
        self.assertIn(b"v9.9.9", exe[22:mse.EXE_HEADER_SIZE])

        body = exe[mse.EXE_HEADER_SIZE:]
        self.assertEqual(body[:len(loader)], loader)
        manifest = body[len(loader):len(loader) + mse.MANIFEST_SIZE]
        self.assertEqual(manifest[0:4], b"STM1")
        self.assertEqual(manifest[4], mse.MANIFEST_VERSION)
        self.assertEqual(manifest[5], 2)
        self.assertEqual(int.from_bytes(manifest[6:8], "little"), 0x4100)
        self.assertEqual(int.from_bytes(manifest[8:10], "little"), len(resident))
        self.assertEqual(manifest[10:32], bytes(22))
        resident_out = body[len(loader) + mse.MANIFEST_SIZE:]
        self.assertEqual(resident_out, resident)
        self.assertEqual(
            len(exe),
            mse.EXE_HEADER_SIZE + len(loader) + mse.MANIFEST_SIZE + len(resident),
        )

    def test_loader_field_selects_preload_path(self) -> None:
        # port.md section 3.2 invariant: LOADER@8 must be non-zero so DSS
        # takes the PRELOAD path and keeps the file handle open in the PSP.
        exe = mse.build_exe(b"\x00", bytes(2 * PAGE_SIZE), "1.0", layout=LAYOUT)
        self.assertNotEqual(exe[8:10], b"\x00\x00")

    def test_deterministic(self) -> None:
        loader = b"\xC3\x00\x81" * 100
        resident = bytes(2 * PAGE_SIZE)
        self.assertEqual(
            mse.build_exe(loader, resident, "1.2", layout=LAYOUT),
            mse.build_exe(loader, resident, "1.2", layout=LAYOUT),
        )

    def test_loader_size_guard(self) -> None:
        with self.assertRaises(SystemExit):
            mse.build_exe(b"\x00" * (mse.MAX_LOADER_SIZE + 1),
                          bytes(2 * PAGE_SIZE), "1.0", layout=LAYOUT)
        with self.assertRaises(SystemExit):
            mse.build_exe(b"", bytes(2 * PAGE_SIZE), "1.0", layout=LAYOUT)

    def test_resident_guards(self) -> None:
        with self.assertRaises(SystemExit):
            mse.build_exe(b"\xC3", b"", "1.0", layout=LAYOUT)
        with self.assertRaises(SystemExit):
            # Not a multiple of the 16 KiB page size.
            mse.build_exe(b"\xC3", bytes(PAGE_SIZE + 1), "1.0", layout=LAYOUT)

    def test_addresses_match_contract(self) -> None:
        # Loader contract from port.md section 3.2 (Estex-DSS EXE_Header.z80).
        self.assertEqual(mse.LD_ADDR, 0x8100)
        self.assertEqual(mse.PC_REG, 0x8100)
        self.assertEqual(mse.SP_REG, 0xBFF0)

    def test_manifest_entry_matches_layout_trampoline(self) -> None:
        manifest = mse.build_manifest(2, 0x4100, 2 * PAGE_SIZE)
        self.assertEqual(int.from_bytes(manifest[6:8], "little"),
                         gsl.compute_symbols(LAYOUT)["TRAMPOLINE_ADDR"])

    def test_build_manifest_guards(self) -> None:
        with self.assertRaises(SystemExit):
            mse.build_manifest(0, 0x4100, 0)
        with self.assertRaises(SystemExit):
            mse.build_manifest(2, 0x4100, 0x10000)


if __name__ == "__main__":
    unittest.main()
