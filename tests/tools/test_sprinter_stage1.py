#!/usr/bin/env python3
"""Negative and determinism tests for the Sprinter monoblock tooling."""

from __future__ import annotations

import json
import re
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
        asset = bytes([0x5A]) * make_sprinter_exe.PAGE_SIZE
        first, manifest1 = make_sprinter_exe.build_monoblock(
            loader,
            base.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            runtime.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            [cold], [asset], gfx_page_count=1, palette_asset_index=0,
            palette_length=768, asset_page_table=0x8160,
            palette_destination=0xB710,
        )
        second, manifest2 = make_sprinter_exe.build_monoblock(
            loader,
            base.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            runtime.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            [cold], [asset], gfx_page_count=1, palette_asset_index=0,
            palette_length=768, asset_page_table=0x8160,
            palette_destination=0xB710,
        )
        self.assertEqual(first, second)
        self.assertEqual(manifest1, manifest2)
        self.assertEqual(first[:4], b"EXE\x01")
        self.assertEqual(
            len(first),
            make_sprinter_exe.HEADER_SIZE + len(loader) +
            make_sprinter_exe.MANIFEST_SIZE + 4 * make_sprinter_exe.PAGE_SIZE,
        )
        manifest_offset = make_sprinter_exe.HEADER_SIZE + len(loader)
        binary_manifest = first[manifest_offset:manifest_offset + 32]
        self.assertEqual(binary_manifest[4], 2)
        self.assertEqual(binary_manifest[6:8], bytes((1, 1)))
        self.assertEqual(binary_manifest[20:24], bytes((2, 3, 1, 0)))
        self.assertEqual(int.from_bytes(binary_manifest[24:26], "little"), 768)

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

    def test_corrupt_asset_counts_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "cold/asset counts"):
            make_sprinter_exe.make_manifest(5, 1, 1)


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
    def test_libman_bridges_preserve_sdcc_iy_frame_registers(self) -> None:
        text = (ROOT / "asm/sprinter/gfx_bridge.asm").read_text(encoding="ascii")
        load = text.split("_sprinter_gfx_load:", 1)[1].split(
            "_sprinter_gfx_unload:", 1
        )[0]
        unload = text.split("_sprinter_gfx_unload:", 1)[1]
        for block in (load, unload):
            self.assertIn("PUSH IX", block)
            self.assertIn("PUSH IY", block)
            self.assertIn("POP IY", block)
            self.assertIn("POP IX", block)

    def test_video_mode_bridge_preserves_sdcc_frame_registers(self) -> None:
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        block = text.split("_sprinter_video_graphics:", 1)[1].split(
            "; SetVMod changes the geometry", 1
        )[0]
        self.assertIn("PUSH IX", block)
        self.assertIn("PUSH IY", block)
        self.assertEqual(block.count("POP IY"), 2)
        self.assertEqual(block.count("POP IX"), 2)

    def test_startup_uses_gfx_window_and_clear_contract(self) -> None:
        runtime = (ROOT / "src/sprinter/gfx_runtime.c").read_text(encoding="ascii")
        self.assertNotIn("gfx320_set_vram_window", runtime)
        self.assertIn("gfx320_clear(0u, GFX_TARGET_BUF0)", runtime)
        self.assertIn("gfx320_clear(0u, GFX_TARGET_BUF1)", runtime)
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("fill(0u, 0u, 320u, 256u", renderer)

    def test_image_entry_constants_match_the_manifest_tool(self) -> None:
        text = (ROOT / "asm/sprinter/image_layout.inc").read_text(encoding="ascii")
        values = {
            name: int(value, 16)
            for name, value in re.findall(
                r"DEFC\s+(SPRINTER_[A-Z_]+)\s*=\s*0x([0-9A-Fa-f]+)", text
            )
        }
        self.assertEqual(
            values["SPRINTER_RUNTIME_ENTRY"], make_sprinter_exe.RUNTIME_ENTRY
        )
        self.assertEqual(
            values["SPRINTER_BASE_TRANSITION"], make_sprinter_exe.BASE_TRANSITION
        )

    def test_project_fixed_layout_is_valid(self) -> None:
        symbols, stack_top, headroom = gen_sprinter_layout.load_layout(
            ROOT / "src/sprinter/fixed_layout.json"
        )
        self.assertEqual(stack_top, 0xBFF0)
        self.assertGreaterEqual(headroom, 0x400)
        self.assertEqual(symbols["SPRINTER_PAGE_TABLE"], 0x8101)

    def test_direct_disk_rst_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            for index, source in enumerate((
                "ld c,DSS_READ\nrst 0x10\n",
                "ll0: ld c,13h\nrst 10h\n",
                "ld c,#13\nrst #10\n",
            )):
                path = Path(temp_name) / f"bad-{index}.asm"
                path.write_text(source, encoding="ascii")
                failures = check_sprinter_forbidden_dss.scan(path)
                self.assertEqual(len(failures), 1, source)

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
