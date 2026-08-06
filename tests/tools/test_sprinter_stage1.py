#!/usr/bin/env python3
"""Negative and determinism tests for the Sprinter monoblock tooling."""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import check_sprinter_forbidden_dss  # noqa: E402
import check_sprinter_build  # noqa: E402
import check_sprinter_imports  # noqa: E402
import gen_sprinter_cold_imports  # noqa: E402
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
    def test_cold_import_keeps_resident_bank_data_address(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp = Path(temp_name)
            plan = temp / "plan.json"
            runtime_map = temp / "runtime.map"
            definitions = temp / "defs.asm"
            manifest = temp / "manifest.json"
            plan.write_text(json.dumps({
                "version": 1,
                "modules": [{
                    "id": 8,
                    "name": "setup",
                    "objects": [],
                    "imports": [{
                        "kind": "direct",
                        "symbol": "_setup_cursor",
                        "target": 0xBAA1,
                    }],
                }],
            }), encoding="utf-8")
            runtime_map.write_text(
                "_setup_cursor = $AEB1 ; const, public, , runtime, code_user, test\n",
                encoding="utf-8",
            )
            gen_sprinter_cold_imports.finalize(SimpleNamespace(
                plan=plan,
                runtime_map=runtime_map,
                defs_out=definitions,
                manifest_out=manifest,
            ))
            self.assertIn(
                "DEFC _setup_cursor = 0xBAA1",
                definitions.read_text(encoding="utf-8"),
            )
            generated = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(
                generated["modules"][0]["imports"][0]["address"], 0xBAA1
            )

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
    def test_menu_config_is_network_setup_not_stage2_hotseat(self) -> None:
        text = (ROOT / "asm/sprinter/cold/menu_config.asm").read_text(
            encoding="ascii"
        )
        self.assertIn('"  GAME HOST"', text)
        self.assertIn('"  GAME JOIN"', text)
        self.assertIn('"  LINK MQTT"', text)
        self.assertIn('"  LINK DIRECT"', text)
        self.assertIn("ld a,(_setup_cursor)", text)
        self.assertIn("ld de,_netchesszx_mqtt_code", text)
        self.assertIn("call _sprinter_cold_text", text)
        self.assertNotIn("LOCAL HOT-SEAT", text)

    def test_stage3_restores_explicit_chat_entry_and_setup_edit_feedback(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        menu = (ROOT / "asm/sprinter/cold/menu_config.asm").read_text(
            encoding="ascii"
        )

        self.assertIn("LOCAL_INPUT_MODE_CHAT", app)
        self.assertIn("key == 'c' || key == 'C'", app)
        self.assertIn("local_input_mode == LOCAL_INPUT_MODE_CHAT", app)
        self.assertIn("send_local_chat(local_input)", app)
        self.assertIn("_setup_room_editing", menu)
        self.assertIn("menu_line_edit", menu)
        self.assertIn("ld a,'_'", menu)

    def test_network_game_loop_paces_ui_before_each_recv_poll(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        loop = app.split("static void game_message_loop(void)", 1)[1].split(
            "#ifndef NETCHESSZX_HOST_SESSION_TEST", 1
        )[0]
        frame = loop.index("spectrum_frame_wait();")
        tick = loop.index("spectrum_gui_tick();", frame)
        key = loop.index("process_local_key(spectrum_gui_poll_key())", tick)
        recv = loop.index("netchesszx_session_poll", key)
        self.assertLess(frame, tick)
        self.assertLess(tick, key)
        self.assertLess(key, recv)

    def test_cold_status_text_is_copied_before_resident_ui_gate(self) -> None:
        status = (ROOT / "src/spectrum/overlay/status_ovl.c").read_text(
            encoding="ascii"
        )
        self.assertIn('#include "sprinter/cold_text.h"', status)
        self.assertIn(
            "spectrum_gui_set_status(sprinter_cold_text(status_line_ovl));",
            status,
        )

    def test_frame_wait_has_short_fallback_and_full_video_port_address(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(
            encoding="ascii"
        )
        block = runtime.split("sprinter_frame_wait:", 1)[1].split(
            "sprinter_dss_keyscan:", 1
        )[0]
        self.assertIn("LD DE,0x0400", block)
        self.assertEqual(block.count("LD A,0xFF\n    IN A,(0xFE)"), 2)

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
        call = text.split("_gfx320_libman_call:", 1)[1].split(
            "; Fastcall filename", 1
        )[0]
        self.assertIn("IN A,(0xA2)\n    PUSH AF", call)
        self.assertIn(
            "gfx_call_return:\n    LD H,0\n    POP AF\n    OUT (0xA2),A",
            call,
        )

        unet = (ROOT / "asm/sprinter/unet_bridge.asm").read_text(
            encoding="ascii"
        )
        call = unet.split("_sprinter_unet_call:", 1)[1].split(
            "; Fastcall destination", 1
        )[0]
        self.assertIn("IN A,(PORT_WIN1)\n    PUSH AF", call)
        self.assertIn(
            "suc_return:\n    POP AF\n    OUT (PORT_WIN1),A\n    POP IY",
            call,
        )

    def test_video_mode_bridge_preserves_sdcc_frame_registers(self) -> None:
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        block = text.split("_sprinter_video_graphics:", 1)[1].split(
            "; Reapply the immutable RGB888 palette", 1
        )[0]
        self.assertIn("PUSH IX", block)
        self.assertIn("PUSH IY", block)
        self.assertEqual(block.count("POP IY"), 2)
        self.assertEqual(block.count("POP IX"), 2)

    def test_fileui_disk_wrappers_preserve_sdcc_ix_frame_register(self) -> None:
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        opendir = text.split("sprinter_esx_opendir:", 1)[1].split(
            "sprinter_esx_readdir:", 1
        )[0]
        readdir = text.split("sprinter_esx_readdir_fetch:", 1)[1].split(
            "sprinter_esx_readdir_filter:", 1
        )[0]
        for block in (opendir, readdir):
            self.assertIn(
                "PUSH IX\n    CALL sprinter_disk_gate\n    POP IX\n    RET C",
                block,
            )

    def test_win1_key_poll_gate_reads_the_frame_event_queue(self) -> None:
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        gates = text.split("; Fixed three-byte WIN2 gates.", 1)[1].split(
            "DEFS (SPRINTER_RUNTIME_ENTRY-0x8000)-$", 1
        )[0]
        self.assertIn("JP _spectrum_input_poll_event", gates)
        self.assertNotIn("JP sprinter_key_poll", gates)

    def test_raw_key_scan_uses_a_stable_win2_gate(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        api = (ROOT / "asm/sprinter/runtime_api.inc").read_text(encoding="ascii")
        gates = runtime.split("; Fixed three-byte WIN2 gates.", 1)[1].split(
            "DEFS (SPRINTER_RUNTIME_ENTRY-0x8000)-$", 1
        )[0]
        self.assertIn("DEFC _sprinter_key_scan_raw = 0x82DB", runtime)
        self.assertIn("JP sprinter_key_scan_raw_impl", gates)
        self.assertIn("DEFC SPR_API_RAW_KEY_SCAN = 0x82DB", api)


    def test_startup_uses_gfx_window_and_clear_contract(self) -> None:
        runtime = (ROOT / "src/sprinter/gfx_runtime.c").read_text(encoding="ascii")
        self.assertIn("gfx320_set_vram_window(GFX_VRAM_WINDOW)", runtime)
        self.assertIn("gfx320_clear(0u, GFX_TARGET_BUF0)", runtime)
        self.assertIn("gfx320_clear(0u, GFX_TARGET_BUF1)", runtime)
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("fill(0u, 0u, 320u, 256u", renderer)

        platform = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        video = platform.split("_sprinter_video_graphics:", 1)[1].split(
            "sprinter_video_fail:", 1
        )[0]
        self.assertNotIn("PORT_ALL_MODE", video)

    def test_runtime_uses_bounded_video_blank_and_services_keyscan_at_safe_point(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        startup = runtime.split("sprinter_runtime_start:", 1)[1].split(
            "sprinter_start_fail:", 1
        )[0]
        frame_wait = runtime.split("sprinter_frame_wait:", 1)[1].split(
            "sprinter_key_poll:", 1
        )[0]
        self.assertIn("CALL sprinter_cbl_arm", startup)
        default_irq = runtime.split("sprinter_im2_handler:", 1)[1].split(
            "DEFS 0x0200-$", 1
        )[0]
        self.assertIn("EI\n    RETI", default_irq)
        self.assertNotIn("JP 0x0038", default_irq)
        self.assertIn("LD HL,(0x003C)", frame_wait)
        self.assertIn("CALL sprinter_dss_keyscan", frame_wait)
        self.assertIn("LD DE,14", frame_wait)
        self.assertIn("JP (HL)\nsprinter_dss_keyscan_return:", frame_wait)
        self.assertNotIn("IM 1", frame_wait)
        self.assertNotIn("CALL _spectrum_input_frame_tick", frame_wait)
        self.assertNotIn("CALL _sprinter_render_present", frame_wait)
        self.assertNotIn("sprinter_dss_irq_if_key", runtime)
        self.assertIn("IN A,(0xFE)", frame_wait)
        self.assertIn("LD DE,0x0400", frame_wait)
        self.assertIn("sprinter_frame_wait_blank:", frame_wait)
        self.assertIn("sprinter_frame_wait_tick:", frame_wait)
        self.assertNotIn("HALT", frame_wait)
        self.assertIn("LD BC,PORT_CBL_DATA", runtime)
        self.assertIn("OUT (C),A\n    DJNZ sprinter_cbl_silence", runtime)
        self.assertNotIn("OUT (PORT_CTC_CH3),A", runtime)

    def test_resident_gate_does_not_service_dss_asynchronously(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        gate = runtime.split("sprinter_resident_guard_ready:", 1)[1].split(
            "sprinter_resident_entry_return:", 1
        )[0]
        self.assertNotIn("sprinter_dss_irq_if_key", gate)

    def test_ui_tick_polls_input_and_presents_without_recursive_gate(self) -> None:
        gui = (ROOT / "src/spectrum/ui/gui.c").read_text(encoding="ascii")
        tick = gui.split("void spectrum_gui_tick(void)", 1)[1].split(
            "void spectrum_gui_reset_moves", 1
        )[0]
        self.assertIn("spectrum_input_frame_tick();", tick)
        self.assertIn("sprinter_render_present();", tick)

    def test_present_never_selects_the_unstable_second_screen(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        present = renderer.split("uint8_t sprinter_render_present(void)", 1)[1]
        self.assertNotIn("gfx320_swap_buffers()", present)
        self.assertNotIn("gfx320_copy_buffer", present)
        self.assertNotIn("slow_begin()", present)

    def test_runtime_keeps_win0_on_dss_for_every_dss_rst(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        startup = runtime.split("sprinter_runtime_start:", 1)[1].split(
            "sprinter_start_fail:", 1
        )[0]
        disk_gate = runtime.split("sprinter_disk_gate:", 1)[1].split(
            "sprinter_disk_gate_rst_end:", 1
        )[0]
        self.assertIn("DEFC PORT_CACHE_OFF = 0x007B", runtime)
        self.assertIn("IN A,(PORT_CACHE_OFF)\n    IM 1\n    LD SP", startup)
        self.assertNotIn("PORT_CACHE_ON", runtime)
        self.assertIn("IN A,(PORT_CACHE_OFF)", disk_gate)
        self.assertIn("RST 0x10", disk_gate)
        for name in ("sprinter_read_rtc:", "sprinter_key_poll:", "sprinter_puts:"):
            block = runtime.split(name, 1)[1]
            self.assertIn("CALL sprinter_dss_enter\n    RST 0x10", block)

    def test_fileui_uses_a_compact_aligned_window(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("outline(40u, 48u, 128u, 144u", renderer)
        self.assertIn("88u + slot * 8u), 112u, 8u", renderer)
        self.assertIn("selected ? COLOR_NOTICE : COLOR_BLACK", renderer)

    def test_cursor_unmark_redraws_the_square_without_a_gray_outline(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("draw_square_spec(spec, (uint8_t)spec[2], 0u)", renderer)
        self.assertIn("draw_square_spec(spec, (uint8_t)spec[2], 1u)", renderer)
        self.assertIn("if (mark != 0u)", renderer)

    def test_ctrl_escape_accepts_ascii_and_positional_dss_forms(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        scan = runtime.split("sprinter_key_poll:", 1)[1].split(
            "sprinter_key_scan_raw_impl:", 1
        )[0]
        self.assertIn("BIT 5,A", scan)
        self.assertIn("CP 0x1B\n    JR Z,sprinter_key_ctrl_escape", scan)
        self.assertIn("CP 0x01\n    JR Z,sprinter_key_ctrl_escape", scan)

    def test_direct_endpoint_accepts_ascii_and_positional_decimal_keys(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        setup = (ROOT / "asm/overlay/setup/entry_setup.asm").read_text(
            encoding="ascii"
        )
        positional = runtime.split("sprinter_key_positional:", 1)[1].split(
            "sprinter_key_up:", 1
        )[0]
        self.assertIn("CP 0x32\n    JR Z,sprinter_key_dot", positional)
        self.assertIn("CP 0x4F\n    JR Z,sprinter_key_dot", positional)
        self.assertIn("sprinter_key_dot:\n    LD L,'.'", runtime)
        self.assertIn("su_rc_dot:\n    ld a, '.'", setup)

    def test_key_poll_peeks_then_consumes_one_dss_record(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        scan = runtime.split("sprinter_key_poll:", 1)[1].split(
            "sprinter_key_scan_raw_impl:", 1
        )[0]
        self.assertIn(
            "LD C,DSS_TESTKEY\n    RST 0x10\n"
            "    JP Z,sprinter_key_none_saved\n"
            "    LD C,DSS_SCANKEY\n    RST 0x10",
            scan,
        )
        self.assertNotIn("sprinter_dss_enter", scan)

    def test_palette_restore_uses_the_physical_preload_page(self) -> None:
        loader = (ROOT / "asm/sprinter/preload_loader.asm").read_text(
            encoding="ascii"
        )
        publish = loader.split("; Stage the RGB888 palette", 1)[1].split(
            "; Patch the runtime physical page", 1
        )[0]
        self.assertIn(
            "LD A,(HL)\n    LD (0xC000+(SPRINTER_PALETTE_PAGE_INDEX-0x8000)),A",
            publish,
        )
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        restore = runtime.split("_sprinter_palette_restore:", 1)[1].split(
            "; SetVMod changes the geometry", 1
        )[0]
        self.assertIn("LD A,(SPRINTER_PALETTE_PAGE_INDEX)", restore)
        self.assertIn("LD A,D\n    OUT (PORT_Y),A", restore)
        self.assertNotIn("OUT (C),A", restore)
        self.assertIn("LD (0xC3E0),A", restore)
        self.assertIn("LD (0xC3E4),A", restore)

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
        # libman/uNet require at least 256 bytes of free stack for every call.
        self.assertGreaterEqual(headroom, 0x100)
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

    def test_stale_resident_runtime_import_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            directory = Path(temp_name)
            for name in ("app", "ui", "protocol"):
                value = "0x8F5C" if name == "ui" else "0x905C"
                (directory / f"{name}_imports.asm").write_text(
                    f"PUBLIC _spectrum_uart_background_pump\n"
                    f"DEFC _spectrum_uart_background_pump = {value}\n",
                    encoding="ascii",
                )
            failures = check_sprinter_build.validate_resident_imports(
                directory, {"_spectrum_uart_background_pump": 0x905C}
            )
            self.assertEqual(len(failures), 1)
            self.assertIn("ui resident import", failures[0])

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
