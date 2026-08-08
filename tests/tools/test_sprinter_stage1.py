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
            [cold], [asset, asset], gfx_page_count=1, palette_asset_index=1,
            palette_length=768, asset_page_table=0x8160,
            palette_destination=0xB710,
        )
        second, manifest2 = make_sprinter_exe.build_monoblock(
            loader,
            base.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            runtime.ljust(make_sprinter_exe.PAGE_SIZE, b"\0"),
            [cold], [asset, asset], gfx_page_count=1, palette_asset_index=1,
            palette_length=768, asset_page_table=0x8160,
            palette_destination=0xB710,
        )
        self.assertEqual(first, second)
        self.assertEqual(manifest1, manifest2)
        self.assertEqual(first[:4], b"EXE\x01")
        self.assertEqual(
            len(first),
            make_sprinter_exe.HEADER_SIZE + len(loader) +
            make_sprinter_exe.MANIFEST_SIZE + 5 * make_sprinter_exe.PAGE_SIZE,
        )
        manifest_offset = make_sprinter_exe.HEADER_SIZE + len(loader)
        binary_manifest = first[manifest_offset:manifest_offset + 32]
        self.assertEqual(binary_manifest[4], 2)
        self.assertEqual(binary_manifest[6:8], bytes((1, 2)))
        self.assertEqual(binary_manifest[20:24], bytes((2, 3, 1, 1)))
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

    def test_palette_must_follow_the_gfx_pages(self) -> None:
        with self.assertRaisesRegex(ValueError, "palette page after GFX"):
            make_sprinter_exe.make_manifest(4, 1, 1, gfx_page_count=1)
        with self.assertRaisesRegex(ValueError, "must follow GFX"):
            make_sprinter_exe.make_manifest(5, 1, 2, gfx_page_count=1,
                                             palette_asset_index=0)


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

    def test_rtc_is_published_through_the_ui_bank_after_gfx_start(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        startup = runtime.split("sprinter_runtime_start:", 1)[1].split(
            "sprinter_start_fail:", 1
        )[0]
        gfx = startup.index("CALL _sprinter_gfx_start")
        publish = startup.index("CALL _sprinter_gui_publish_clock", gfx)
        app = startup.index("CALL SPRINTER_CLIENT_ENTRY", publish)
        self.assertLess(gfx, publish)
        self.assertLess(publish, app)

        glue = (ROOT / "src/sprinter/client_glue.c").read_text(encoding="ascii")
        block = glue.split("void sprinter_gui_publish_clock(void)", 1)[1].split(
            "void spectrum_board_clear_legal_hints", 1
        )[0]
        self.assertIn("spectrum_gui_set_clock", block)
        self.assertIn("SPRINTER_RTC_HOUR", block)
        self.assertIn("SPRINTER_RTC_MINUTE", block)
        self.assertIn("SPRINTER_RTC_SECOND", block)

    def test_sprinter_gameplay_hint_is_restored_by_modal_exit_paths(self) -> None:
        gui = (ROOT / "src/spectrum/ui/gui.c").read_text(encoding="ascii")
        self.assertIn(
            '"ARROWS+ENTER MOVE; M TYPE; C CHAT; F1 MENU; CTRL+ESC EXIT"',
            gui,
        )
        set_input = gui.split("void spectrum_gui_set_input", 1)[1].split(
            "void spectrum_gui_set_input_edit", 1
        )[0]
        restore = gui.split("void spectrum_gui_restore_side_panels", 1)[1].split(
            "uint8_t spectrum_gui_side_panels_visible", 1
        )[0]
        self.assertIn("text[0] == '\\0' && side_panels_visible", set_input)
        self.assertIn("text = sprinter_gameplay_hint;", set_input)
        self.assertIn('spectrum_gui_set_input("");', restore)

    def test_sprinter_game_controls_keep_contextual_enter_priority(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        process = app.split("static uint8_t process_local_key", 1)[1].split(
            "static void handle_opponent_disconnected_with", 1
        )[0]
        fileui = process.index("spectrum_gui_fileui_visible()")
        menu = process.index("spectrum_gui_handle_menu_key(key)", fileui)
        editor = process.index("if (local_input_mode)", menu)
        typed = process.index("SPRINTER_GAME_CONTROL_TYPE", editor)
        selected = process.index("SPRINTER_GAME_CONTROL_SELECT", typed)
        self.assertLess(fileui, menu)
        self.assertLess(menu, editor)
        self.assertLess(editor, typed)
        self.assertLess(typed, selected)
        self.assertIn("#ifndef NETCHESSZX_SPRINTER\n    if (key == 13u)", process)
        self.assertIn("return cursor_select_or_move(key);", process)

        move = app.split("static void cursor_move", 1)[1].split(
            "static uint8_t cursor_select_or_move", 1
        )[0]
        self.assertLess(
            move.index("cursor_redraw_square(old_row, old_col)"),
            move.index("spectrum_gui_mark_cursor"),
        )

    def test_sprinter_duplicate_select_keeps_the_source_selected(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        select = app.split("static uint8_t cursor_select_or_move", 1)[1].split(
            "static uint8_t restore_transfer_pending", 1
        )[0]
        same_square = select.split(
            "if (selected_row == cursor_row && selected_col == cursor_col)", 1
        )[1].split("if (!is_spectrum_piece", 1)[0]
        sprinter = same_square.split("#ifdef NETCHESSZX_SPRINTER", 1)[1].split(
            "#else", 1
        )[0]
        self.assertIn("cursor_show();", sprinter)
        self.assertIn("return 1u;", sprinter)
        self.assertNotIn("selected_row = NO_SQUARE", sprinter)

    def test_sprinter_select_records_are_debounced_before_app_dispatch(self) -> None:
        platform = (ROOT / "src/sprinter/platform.c").read_text(encoding="ascii")
        tick = platform.split("void spectrum_input_frame_tick(void)", 1)[1].split(
            "uint8_t spectrum_input_poll_event", 1
        )[0]
        self.assertIn("SPRINTER_SELECT_DEBOUNCE_FRAMES", platform)
        self.assertIn("if (is_select_key(key))", tick)
        self.assertIn("if (select_debounce != 0u)", tick)
        self.assertIn("select_debounce = SPRINTER_SELECT_DEBOUNCE_FRAMES", tick)

    def test_sprinter_raw_input_is_polled_even_without_a_new_vblank(self) -> None:
        platform = (ROOT / "src/sprinter/platform.c").read_text(encoding="ascii")
        tick = platform.split("void spectrum_input_frame_tick(void)", 1)[1].split(
            "uint8_t spectrum_input_poll_event", 1
        )[0]
        frame_gate = tick.index("frame_advanced =")
        raw_poll = tick.index("key = sprinter_key_scan_raw();")
        debounce = tick.index("if (frame_advanced && select_debounce")
        self.assertLess(frame_gate, raw_poll)
        self.assertLess(raw_poll, debounce)
        self.assertNotIn("frame == input_last_frame) {\n        return;", tick)
        released = tick.split("if (key == 0u) {", 1)[1].split("return;", 1)[0]
        self.assertIn("key_last = 0u;", released)
        self.assertIn("key_repeat_timer = 0u;", released)
        self.assertIn("key_suppress = 0u;", released)
        self.assertNotIn("frame_advanced", released)

    def test_sprinter_piece_set_switch_uses_preloaded_tiles(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        switch = app.split("static void session_setup_apply_set", 1)[1].split(
            "static uint8_t session_setup_step", 1
        )[0]
        sprinter = switch.split("#ifdef NETCHESSZX_SPRINTER", 1)[1].split(
            "#else", 1
        )[0]
        self.assertIn("setup_focus_piece_set >= NETCHESSZX_PIECE_SET_COUNT", sprinter)
        self.assertNotIn("netchesszx_piece_set_load", sprinter)

    def test_direct_guest_hello_redraws_when_it_corrects_board_orientation(self) -> None:
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        hello = app.split("NETCHESSZX_SESSION_EVENT_DIRECT_HELLO", 1)[1].split(
            "NETCHESSZX_SESSION_EVENT_MQTT_EMPTY", 1
        )[0]
        orient = hello.index("spectrum_gui_set_board_view")
        redraw = hello.index("spectrum_gui_redraw_board_view", orient)
        wait = hello.index("notify_wait_msg(SPECTRUM_GUI_MSG_OPPONENT_READY_WAIT)", redraw)
        self.assertLess(orient, redraw)
        self.assertLess(redraw, wait)

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

    def test_frame_wait_has_independent_bounded_phases_and_full_port_address(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(
            encoding="ascii"
        )
        block = runtime.split("sprinter_frame_wait:", 1)[1].split(
            "sprinter_dss_keyscan:", 1
        )[0]
        self.assertEqual(block.count("LD DE,0x8000"), 2)
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
        call = text.split("_gfx640_libman_call:", 1)[1].split(
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
        getenv = unet.split("_sprinter_unet_getenv:", 1)[1]
        self.assertIn("JR C,suge_fail\n    OR A\n    JR Z,suge_fail", getenv)
        self.assertNotIn("CP 0xFF", getenv)

    def test_libman_retains_graphics_font_and_network_handles(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(
            encoding="ascii"
        )
        self.assertIn("DEFC LIBMAN_MAX_LIBS = 3", runtime)

    def test_video_mode_bridge_preserves_sdcc_frame_registers(self) -> None:
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        block = text.split("_sprinter_video_graphics:", 1)[1].split(
            "_sprinter_palette_restore:", 1
        )[0]
        self.assertIn("PUSH IX", block)
        self.assertIn("PUSH IY", block)
        self.assertEqual(block.count("POP IY"), 2)
        self.assertEqual(block.count("POP IX"), 2)

    def test_esx_wrappers_never_return_the_dss_ix_to_sdcc_callers(self) -> None:
        """DSS hands its own IX back from several disk functions.

        The resident libman adapter needs that result, so the gate keeps
        returning it.  Every esx-style wrapper is instead reached from SDCC
        code that keeps its frame pointer in IX and whose epilogue executes
        LD SP,IX, so a single wrapper that calls the raw gate installs a stack
        pointer outside the WIN2 reserve.  All of them must route through the
        preserving entry rather than carry the protection individually.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        keep = text.split("sprinter_disk_gate_keep_ix:", 1)[1].split("RET", 1)[0]
        self.assertIn("PUSH IX", keep)
        self.assertIn("CALL sprinter_disk_gate", keep)
        self.assertIn("POP IX", keep)
        wrappers = text.split("; esx-style file ABI over DSS", 1)[1].split(
            "; RTC/FAT timestamp", 1
        )[0]
        self.assertNotIn("PUSH IX", wrappers)
        for line in wrappers.splitlines():
            stripped = line.strip()
            if stripped.endswith("sprinter_disk_gate"):
                self.fail(f"esx wrapper reaches the raw gate: {stripped}")
        self.assertEqual(wrappers.count("sprinter_disk_gate_keep_ix"), 9)

    def test_k_clear_cannot_chain_into_a_blocking_dss_function(self) -> None:
        """DSS K_CLEAR ends with LD C,B / JP RST_10.

        It flushes the ring first and then chains to the function number in B
        whenever that number is WaitKey..EDIT, so leaving B undefined can turn
        a buffer flush into DSS WaitKey.  Under IM2 the DSS keyboard scanner
        only runs from frame_wait, so WaitKey never returns.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        self.assertIn(
            "LD B,0\n    LD C,DSS_K_CLEAR\n"
            "    CALL sprinter_dss_enter\n    RST 0x10",
            text,
        )

    def test_far_call_gate_keeps_its_upstream_shape(self) -> None:
        """The cold-to-resident gate is deliberately left as committed.

        Its single shared slot set is not re-entrant, but two attempts to change
        that here made things worse: rejecting a nested call turned silent
        corruption into an immediate exit, and staging the frame on the stack
        moved the failure earlier, into the connect path.  Neither could be
        exercised locally, so the gate stays as it is until a nested call is
        actually observed rather than inferred.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        gate = text.split("sprinter_far_call:", 1)[1].split(
            'INCLUDE "sprinter_far_thunks.inc"', 1
        )[0]
        self.assertNotIn("SPRINTER_FAR_BUSY", gate)
        self.assertNotIn("sprinter_far_nested", gate)
        self.assertIn("LD (SPRINTER_FAR_RETURN),HL", gate)
        self.assertIn("LD (SPRINTER_FAR_IX),IX", gate)

    def test_im2_handler_reports_a_stack_pointer_outside_the_reserve(self) -> None:
        """A lost frame is only observable from an interrupt.

        Once a bad return address transfers control into a blocking DSS
        routine, frame_wait never runs again, so the interrupt is the only code
        left that can turn the freeze into a diagnosed exit.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        handler = text.split("sprinter_im2_handler:", 1)[1].split(
            "sprinter_im2_frame_lost:", 1
        )[0]
        self.assertIn("LD A,(SPRINTER_SP_WATCH)", handler)
        self.assertIn("LD DE,SPRINTER_STACK_FLOOR", handler)
        self.assertIn("LD DE,SPRINTER_STACK_TOP+1", handler)
        self.assertEqual(handler.count("JR C,sprinter_im2_frame_lost"), 1)
        self.assertEqual(handler.count("JR NC,sprinter_im2_frame_lost"), 1)
        # The reconstruction must match what the interrupt and this handler
        # have pushed, or a legitimately deep frame reads as a fault.
        self.assertEqual(handler.count("LD HL,8\n    ADD HL,SP"), 2)
        self.assertEqual(handler.count("PUSH AF") + handler.count("PUSH HL")
                         + handler.count("PUSH DE"), 3)
        lost = text.split("sprinter_im2_frame_lost:", 1)[1].split(
            "sprinter_frame_counter_get:", 1
        )[0]
        # The discarded stack is the only record of where the frame was lost.
        self.assertIn("LD (SPRINTER_FAULT_IX),IX", lost)
        self.assertIn("LD (SPRINTER_FAULT_SP),HL", lost)
        self.assertIn("LD (SPRINTER_FAULT_PC),DE", lost)
        self.assertIn("LD (SPRINTER_FAULT_EXIT),A", lost)
        self.assertIn("LD SP,SPRINTER_STACK_TOP", lost)
        self.assertIn("LD A,7", lost)
        self.assertIn("JP sprinter_cleanup", lost)
        self.assertIn("msg_frame_fail:", text)

    def test_fault_exit_does_not_re_enter_libman_or_the_dlls(self) -> None:
        """The diagnosis must not become a second crash.

        A lost frame leaves libman, the loaded DLLs and the WIN1 mapping in an
        unknown state, and the fault exit has already disabled the watchdog, so
        nothing would catch a fault inside the shutdown path.  DSS reclaims the
        process allocation at Exit, so both libman entries are skipped.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        cleanup = text.split("sprinter_cleanup:", 1)[1].split(
            "sprinter_exit:", 1
        )[0]
        for guarded, target in (
            ("JR NZ,sprinter_cleanup_video", "CALL _sprinter_unet_shutdown"),
            ("JR NZ,sprinter_cleanup_gfx_done", "CALL _sprinter_gfx_stop"),
        ):
            self.assertIn(
                f"LD A,(SPRINTER_FAULT_EXIT)\n    OR A\n    {guarded}\n",
                cleanup,
            )
            skip = cleanup.split(guarded, 1)[1]
            self.assertIn(target, skip.split("\n\n", 1)[0] + skip[:400])
        self.assertEqual(cleanup.count("LD A,(SPRINTER_FAULT_EXIT)"), 2)

    def test_every_dss_call_reinstates_the_shell_win0_page(self) -> None:
        """Dss.Exit restores SLOT1/2/3 but never SLOT0.

        The DSS API entry at #0010 exists only while WIN0 holds the system
        page, so a library that repoints WIN0 turns every later RST #10 into a
        silent no-op: the video restore and Exit both do nothing and the
        process ends halted with the game still on screen.
        """
        text = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        self.assertIn("DEFC PORT_WIN0 = 0x82", text)
        startup = text.split("sprinter_runtime_start:", 1)[1].split(
            "LD SP,SPRINTER_STACK_TOP", 1
        )[0]
        self.assertIn("IN A,(PORT_WIN0)", startup)
        self.assertIn("LD (SPRINTER_LOADER_WIN0),A", startup)
        enter = text.split("sprinter_dss_enter:", 1)[1].split(
            "sprinter_dss_leave:", 1
        )[0]
        self.assertIn("IN A,(PORT_CACHE_OFF)", enter)
        self.assertIn("LD A,(SPRINTER_LOADER_WIN0)", enter)
        self.assertIn("OUT (PORT_WIN0),A", enter)
        # Cache-off must land before the page write, or it undoes it.
        self.assertLess(enter.index("IN A,(PORT_CACHE_OFF)"),
                        enter.index("OUT (PORT_WIN0),A"))
        exit_block = text.split("sprinter_exit:", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(exit_block.count("RST 0x10"), 2)

    def test_applied_move_restores_the_board_cursor(self) -> None:
        """The cursor is an overlay on a square, not part of it.

        spectrum_gui_apply_move repaints the squares a move touched, so an
        opponent move or an ACK landing under the cursor erases it and nothing
        redraws it until the next arrow key.
        """
        app = (ROOT / "src/spectrum/app/app.c").read_text(encoding="ascii")
        finish = app.split("static void finish_applied_move(", 1)[1].split(
            "\nstatic ", 1
        )[0]
        self.assertIn("movement_hints_show();", finish)
        self.assertIn("cursor_show();", finish)
        # Hints paint the square, the cursor sits on top of them.
        self.assertLess(finish.index("movement_hints_show();"),
                        finish.rindex("cursor_show();"))
        # Other platforms keep their existing redraw behaviour.
        self.assertIn("#ifdef NETCHESSZX_SPRINTER", finish)

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

    def test_frame_counter_uses_an_append_only_win2_gate(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        api = (ROOT / "asm/sprinter/runtime_api.inc").read_text(encoding="ascii")
        gates = runtime.split("; Fixed three-byte WIN2 gates.", 1)[1].split(
            "DEFS (SPRINTER_RUNTIME_ENTRY-0x8000)-$", 1
        )[0]
        self.assertIn("DEFC _sprinter_frame_counter_get = 0x82DE", runtime)
        self.assertIn("JP sprinter_frame_counter_get", gates)
        self.assertIn("DEFC SPR_API_FRAME_COUNTER_GET = 0x82DE", api)

    def test_frame_wait_counts_only_a_real_active_to_blank_edge(self) -> None:
        runtime = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        arm = runtime.split("sprinter_cbl_arm:", 1)[1].split(
            "sprinter_cbl_disarm:", 1
        )[0]
        wait = runtime.split("sprinter_frame_wait:", 1)[1].split(
            "sprinter_dss_keyscan:", 1
        )[0]
        self.assertGreaterEqual(arm.count("LD A,CBL_IDLE"), 2)
        self.assertEqual(wait.count("LD DE,0x8000"), 2)
        self.assertEqual(wait.count("INC A"), 1)


    def test_startup_uses_gfx_window_and_clear_contract(self) -> None:
        runtime = (ROOT / "src/sprinter/gfx_runtime.c").read_text(encoding="ascii")
        self.assertIn("gfx640_set_vram_window(GFX_VRAM_WINDOW)", runtime)
        self.assertEqual(runtime.count("afnt_call(AFNT_FNSTYLE"), 2)
        self.assertIn('sprinter_gfx_load("AFNT640.DLL")', runtime)
        self.assertIn("AFNT_TARGET_BUF1", runtime)
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("SPRINTER_SCREEN_WIDTH, SPRINTER_SCREEN_HEIGHT", renderer)

        platform = (ROOT / "asm/sprinter/runtime.asm").read_text(encoding="ascii")
        video = platform.split("_sprinter_video_graphics:", 1)[1].split(
            "sprinter_video_fail:", 1
        )[0]
        self.assertEqual(video.count("LD A,0x82"), 2)
        self.assertNotIn("PORT_ALL_MODE", video)

    def test_afnt_text_keeps_case_clips_and_redraws_partial_state(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("sprinter_afnt640_widths", renderer)
        self.assertIn("draw_text_width", renderer)
        self.assertNotIn("value - ('a' - 'A')", renderer)
        self.assertIn("static char timer_text[29]", renderer)
        self.assertIn("static char input_text[INPUT_TEXT_MAX + 1u]", renderer)
        self.assertIn("render_input_line();", renderer)
        self.assertIn("COLOR_BLACK, COLOR_WHITE", renderer)
        self.assertIn("sprinter_palette_about()", renderer)
        self.assertGreaterEqual(renderer.count("sprinter_palette_restore()"), 3)

    def test_timer_and_clock_updates_are_single_afnt_draws_without_fill(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        clock = renderer.split("void spectrum_render_clock", 1)[1].split(
            "void sprinter_render_game_timer_line", 1
        )[0]
        timer = renderer.split("void sprinter_render_game_timer_line", 1)[1].split(
            "void spectrum_render_game_timer_clear", 1
        )[0]
        self.assertNotIn("fill(", clock)
        self.assertNotIn("fill(", timer)
        self.assertEqual(clock.count("draw_text_width("), 1)
        self.assertEqual(timer.count("draw_text_width("), 1)

    def test_sprinter_hint_overlay_redraws_show_and_clear_squares_immediately(self) -> None:
        rules = (ROOT / "asm/overlay/rules/rules_stub.asm").read_text(
            encoding="ascii"
        )
        show = rules.split("rh_draw_to:", 1)[1].split(
            "_rules_hints_clear_ovl:", 1
        )[0]
        clear = rules.split("_rules_hints_clear_ovl:", 1)[1].split(
            "draw_square_hint:", 1
        )[0]
        sprinter_draw = rules.split("draw_square_hint:", 1)[1].split(
            "IFNDEF NETCHESSZX_SPRINTER", 1
        )[0]
        self.assertIn("scf\n    ld a, 0", show)
        self.assertIn("call _spectrum_board_view_redraw_square", clear)
        self.assertIn("call _spectrum_board_view_redraw_square", sprinter_draw)
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        marked = renderer.split("void spectrum_render_square_mark_with_hint", 1)[1].split(
            "static void draw_move_line", 1
        )[0]
        self.assertIn("draw_hint_spec(spec);", marked)

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
        self.assertEqual(frame_wait.count("LD DE,0x8000"), 2)
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
        self.assertNotIn("gfx640_swap_buffers()", present)
        self.assertNotIn("gfx640_copy_buffer", present)
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
        self.assertIn("IN A,(PORT_CACHE_OFF)", startup)
        self.assertLess(startup.index("IN A,(PORT_CACHE_OFF)"),
                        startup.index("IM 1"))
        self.assertNotIn("PORT_CACHE_ON", runtime)
        self.assertIn("IN A,(PORT_CACHE_OFF)", disk_gate)
        self.assertIn("OUT (PORT_WIN0),A", disk_gate)
        self.assertIn("RST 0x10", disk_gate)
        for name in ("sprinter_read_rtc:", "sprinter_key_poll:", "sprinter_puts:"):
            block = runtime.split(name, 1)[1]
            self.assertIn("CALL sprinter_dss_enter\n    RST 0x10", block)

    def test_fileui_uses_a_compact_aligned_window(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("outline(80u, 48u, 256u, 144u", renderer)
        self.assertIn("88u + slot * 8u), 224u, 8u", renderer)
        self.assertIn("selected ? COLOR_NOTICE : COLOR_BLACK", renderer)

    def test_cursor_marks_use_gray_focus_and_yellow_selection(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertEqual(
            renderer.count("draw_square_spec(spec, (uint8_t)(spec[2] ? 2u : 1u)"),
            2,
        )
        self.assertIn("sprinter_cursor_outline_color", renderer)
        self.assertIn("if (mark != 0u)", renderer)

    def test_sprinter_board_labels_follow_the_flipped_view(self) -> None:
        renderer = (ROOT / "src/sprinter/render.c").read_text(encoding="ascii")
        self.assertIn("extern uint8_t spectrum_gui_board_flipped;", renderer)
        self.assertGreaterEqual(renderer.count("sprinter_board_file_label("), 2)
        self.assertGreaterEqual(renderer.count("sprinter_board_rank_label("), 2)

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
        # libman/GFX640/uNet each need 256 free bytes at their own call site, on
        # top of the SDCC chain that reaches them from the app FSM.  A reserve
        # that only covers the DLL requirement overflows into the resident gate
        # state and the protocol bank on the deepest gameplay path.
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
