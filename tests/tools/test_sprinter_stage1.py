#!/usr/bin/env python3
"""Negative and determinism tests for the Sprinter Stage-1 tooling."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import check_sprinter_forbidden_dss  # noqa: E402
import check_sprinter_imports  # noqa: E402
import gen_sprinter_layout  # noqa: E402
import make_sprinter_exe  # noqa: E402
import pack_sprinter_banks  # noqa: E402


class SprinterMonoblockTests(unittest.TestCase):
    def test_monoblock_is_deterministic_and_exactly_paged(self) -> None:
        loader = bytes(range(64))
        base = b"base"
        runtime = b"runtime"
        cold = bytes([0xA5]) * make_sprinter_exe.PAGE_SIZE
        first, manifest1 = make_sprinter_exe.build_monoblock(
            loader,
            base.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            runtime.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            [cold],
        )
        second, manifest2 = make_sprinter_exe.build_monoblock(
            loader,
            base.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            runtime.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            [cold],
        )
        self.assertEqual(first, second)
        self.assertEqual(manifest1, manifest2)
        self.assertEqual(first[:4], b"EXE\x01")
        self.assertEqual(
            len(first),
            make_sprinter_exe.HEADER_SIZE + len(loader) +
            make_sprinter_exe.MANIFEST_SIZE + 3 * make_sprinter_exe.PAGE_SIZE,
        )

    def test_short_packed_bank_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "short.bin"
            path.write_bytes(b"short")
            with self.assertRaisesRegex(ValueError, "exactly 16 KiB"):
                make_sprinter_exe.require_page(path, allow_short=False)

    def test_too_many_banks_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "page count"):
            make_sprinter_exe.make_manifest(
                make_sprinter_exe.MAX_PAGES + 1,
                make_sprinter_exe.MAX_PAGES - 1,
            )


class SprinterBankTests(unittest.TestCase):
    def test_oversized_module_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "2 KiB"):
            pack_sprinter_banks.allocate_modules([0x801])

    def test_exactly_two_kib_module_is_allowed(self) -> None:
        self.assertEqual(pack_sprinter_banks.allocate_modules([0x800]), [(0, 0x4000)])

    def test_oversized_bank_rolls_to_next_page(self) -> None:
        placements = pack_sprinter_banks.allocate_modules([0x800] * 9)
        self.assertEqual(placements[-1], (1, 0x4000))

    def test_invalid_entry_is_rejected(self) -> None:
        data = b"\x01\x00\x60" + b"\0" * 8
        with self.assertRaisesRegex(ValueError, "outside module"):
            pack_sprinter_banks.validate_entry_table(data, 0x4000, "bad")


class SprinterPolicyTests(unittest.TestCase):
    def test_project_fixed_layout_is_valid(self) -> None:
        symbols, stack_top, headroom = gen_sprinter_layout.load_layout(
            ROOT / "src/sprinter/fixed_layout.json"
        )
        self.assertEqual(stack_top, 0xBFF0)
        self.assertGreaterEqual(headroom, 0x400)
        self.assertEqual(symbols["SPRINTER_PAGE_TABLE"], 0x8101)

    def test_direct_disk_rst_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "bad.asm"
            path.write_text("ld c,DSS_READ\nrst 0x10\n", encoding="ascii")
            failures = check_sprinter_forbidden_dss.scan(path)
            self.assertEqual(len(failures), 1)

    def test_win3_and_win1_shared_imports_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            map_path = temp / "cold.map"
            map_path.write_text(
                "SPRINTER_BAD_SHARED = $5000 ; const, local\n"
                "SPRINTER_BAD_WIN3 = $C100 ; const, local\n",
                encoding="ascii",
            )
            source = temp / "cold.asm"
            source.write_text("ret\n", encoding="ascii")
            manifest = {
                "modules": [{"id": 1, "base": 0x4000, "length": 16,
                             "map": str(map_path)}]
            }
            failures = check_sprinter_imports.validate(manifest, [source])
            self.assertEqual(len(failures), 2)

    def test_nested_dispatch_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            source = Path(temp_name) / "cold.asm"
            source.write_text("call _spectrum_overlay_exec_cached\n", encoding="ascii")
            failures = check_sprinter_imports.validate({"modules": []}, [source])
            self.assertEqual(len(failures), 1)

    def test_insufficient_stack_headroom_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "layout.json"
            path.write_text(
                json.dumps({
                    "stack_top": "0xBFF0",
                    "stack_headroom": "0x0400",
                    "symbols": {"SPRINTER_BAD": "0xBC00"},
                }),
                encoding="ascii",
            )
            with self.assertRaisesRegex(ValueError, "outside persistent WIN2|headroom"):
                gen_sprinter_layout.load_layout(path)

    def test_overlapping_fixed_symbols_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            path = Path(temp_name) / "layout.json"
            path.write_text(
                json.dumps({
                    "stack_top": "0xBFF0",
                    "stack_headroom": "0x0400",
                    "symbols": {
                        "SPRINTER_WORD": "0xA000",
                        "SPRINTER_BYTE": "0xA001",
                    },
                    "symbol_sizes": {"SPRINTER_WORD": "0x0002"},
                }),
                encoding="ascii",
            )
            with self.assertRaisesRegex(ValueError, "overlap"):
                gen_sprinter_layout.load_layout(path)


if __name__ == "__main__":
    unittest.main()
