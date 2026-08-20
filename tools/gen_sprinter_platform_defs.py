#!/usr/bin/env python3
"""Bridge sjasmplus's resident symbol table into z88dk-linkable defc's.

Mirrors tools/gen_overlay_defs.py's role for the ZX/Next overlay ABI (plan
D1, port.md section 3.10/S5): sjasmplus assembles the Sprinter platform
primitives (asm/sprinter/platform_core.asm, once restructured from
resident_s1.asm) with --sym, producing a flat "NAME: EQU 0xADDR" table with
every label and manifest constant in the file, local labels included as
dotted parent.child names. This tool filters that table down to
PLATFORM_SYMBOLS -- the curated set of primitives the C image and the two
z88dk-z80asm modules (render_core.asm, overlay_loader_sprinter.asm) are
allowed to call -- and renders sjasmplus-syntax-compatible z80asm output:
both the plain name (for the raw-ASM consumers, matching sjasmplus's own
spelling) and an underscore-prefixed alias (for C externs, which z88dk
always references with a leading underscore regardless of whether the
symbol is C- or ASM-defined). Both point at the same address; the
duplication costs nothing in the linked image (defc's carry no bytes).

The output is a pure function of the input .sym file (no timestamps), so
reruns are byte-identical -- same contract as gen_sprinter_layout.py.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Curated allowlist: only these platform_core primitives are exposed to the
# C image / render_core.asm / overlay_loader_sprinter.asm. Adding a new
# platform_core routine to that call surface means adding its name here --
# same discipline as gen_overlay_defs.py's REQUIRED_SYMBOLS for the ZX/Next
# overlay ABI. A name absent from the assembled .sym is a hard error: the
# call surface must never silently shrink.
PLATFORM_SYMBOLS = [
    # gfx_core.asm -- tile/rect primitives, all __z88dk_fastcall-style
    # (args in fixed memory locations set by the caller, see gfx_core.asm).
    "gfx_swap_buffers",
    "gfx_clear_buffer",
    "gfx_fill_rect",
    "gfx_hline",
    "gfx_draw_tile",
    "gfx_blit_rows",
    # text640.asm
    "text_print",
    # buffers.asm (production subset of bench_s2.asm)
    "bench_init",
    "resolve_buffers",
    # S5-finish plan D11 (buffer flip): main() calls this once, right
    # after resolve_buffers(), to start the dirty-rect ring clean before
    # any drawing begins -- see buffers.asm's own flip_ring_reset comment.
    "flip_ring_reset",
    "bench_asset_page",
    "piece_page1",
    "piece_page2",
    "ovl_win3_page",
    # S7 step 4 (byte-budget ladder): the fifth asset page, holding the
    # whole of render_core.asm/render_core_cold.asm. Read by the trampoline
    # tools/gen_sprinter_cold_thunks.py generates into the WIN1 resident,
    # which maps it into WIN3 for the duration of one painter call.
    "cold_win3_page",
    # S8 step 8b: the NET overlay's own second WIN3 page (sixth asset page,
    # >=6 gate) -- overlay_loader_sprinter.asm's ovl_atlas_page_table reads
    # this cell instead of ovl_win3_page for id 3 only; every other mode-1
    # id is unaffected.
    "ovl_win3_page2",
    "front_base",
    "back_base",
    # gfx_core.asm's tile_* parameter cells: gfx_draw_tile/gfx_blit_rows take
    # their arguments through these module-level cells rather than
    # registers (S2, port.md section 5) -- fine for other sjasmplus files
    # sharing the same assembly job, but render_core.asm (a z88dk-z80asm
    # module, substep 3) needs each cell bridged individually, the same way
    # OVL_SLOT_ADDR/OVL_SLOT_SIZE already are for overlay_loader_sprinter.asm.
    "tile_dest_base",
    "tile_x_byte",
    "tile_x_hi",
    "tile_y",
    "tile_src_page",
    "tile_src_slot",
    "tile_stride",
    "tile_width",
    "tile_rows",
    "tile_alias",
    # render_layout.inc / fixed_layout.inc EQU constants (S5 substep 3):
    # sjasmplus-only "#XX" hex literal syntax means render_core.asm cannot
    # INCLUDE either file directly (see platform_primitives.asm's own
    # comment) -- these are the board geometry and shared cross-platform
    # board-buffer address it needs, bridged the same way OVL_SLOT_ADDR is.
    "BOARD_X",
    "BOARD_Y",
    "BOARD_COLS",
    "BOARD_ROWS",
    "BOARD_CELL_W",
    "BOARD_CELL_H",
    "LOWRAM_CHESS_BOARD_ADDR",
    # Move-log low-RAM ring (S5-finish plan D12, GUI_LOG(2) scope):
    # src/sprinter/gui_log_sprinter.c and render_core.asm's move-list
    # painter both need the fixed address src/spectrum/lowram_map.h's
    # Sprinter branch already reserves for it (src/sprinter/fixed_
    # layout.json's LOWRAM_MOVE_LOG region).
    "LOWRAM_MOVE_LOG_ADDR",
    # Chat panel low-RAM ring (S9 chat pass): render_chat_row (render_core.
    # asm) needs the same fixed address chat_sprinter.c (INPUT_EDIT
    # overlay, WIN3 page 2) writes through, the same bridging reason
    # LOWRAM_MOVE_LOG_ADDR above already has.
    "LOWRAM_CHAT_LOG_ADDR",
    # Overlay call context (S5 substep 3b): the ONE buffer both sides of the
    # overlay ABI must agree on. Portable resident C reaches it by the
    # cross-platform name (src/spectrum/overlay/overlay_context.h's
    # spectrum_overlay_context -> NETCHESSZX_LOWRAM_OVERLAY_CONTEXT_ADDR);
    # overlay_loader_sprinter.asm hands its address to every entry in DE/HL.
    # Bridging it here is what keeps those two the same address -- they were
    # NOT, before this pass (the loader had its own private BSS buffer), and
    # nothing caught it until board.c became the first portable caller.
    "LOWRAM_OVERLAY_CONTEXT_ADDR",
    # RULES(0) overlay scratch board (S5 substep 3b, rules_stub_sprinter.asm):
    # r_tmp must equal this exact address, the same way rules_stub.asm's own
    # r_tmp EQU is required to equal ZX's NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR.
    "LOWRAM_OVERLAY_SCRATCH_ADDR",
    # RULES(0) engine board + the S9 dot-highlight bitmap. Both are read or
    # written from BOTH sides of the overlay boundary -- render_core.asm's
    # render_hint_enumerate_ovl/render_hint_marker (cold WIN3 page) and
    # rules_stub_sprinter.asm's _rules_hints_show_ovl (RULES overlay page) --
    # and neither side can EXTERN the other's symbols across that boundary,
    # so both used to hardcode the addresses as literal EQUs. That is exactly
    # how S9 shipped a silent bug (2026-08-16): render_core.asm's copies were
    # taken from src/spectrum/lowram_map.h's ZX/Next branch ($5FA0/$5FE0)
    # rather than Sprinter's own ($B30F/$B34F), so the enumeration filled a
    # context nothing read and pointed the engine at a board that was not
    # there -- the mask came back all zeros and no dot ever painted, with no
    # build-time signal at all. Bridged here so the fixed_layout.json values
    # reach the asm mechanically instead of by hand-copied literal.
    "LOWRAM_RULES_BOARD_ADDR",
    "LOWRAM_HINTED_ROWS_ADDR",
    # MOVE band (S5 substep 3, coordinate labels): the a-h file letters
    # paint into this band, above the board (render_layout.json).
    "MOVE_Y",
    # STATUS band (S5 substep 3, status-bar clock): render_status_clock
    # paints the RTC HH:MM readout into this band (render_layout.json).
    "STATUS_Y",
    # BANNER/MENU/INPUT bands (S5 substep 3, HUD chrome batch): title +
    # logo, the static menu-tab row, and the input-line prompt
    # (render_layout.json).
    "BANNER_Y",
    "MENU_Y",
    "INPUT_Y",
    # Info panel geometry (S5-finish, gui.c integration surface, plan D8/D9):
    # spectrum_info_show_game (panel chrome) and the notice line both live
    # in the right-hand panel column (render_layout.json's "panel" object),
    # not one of the fixed-width bands above -- these are the panel's own
    # x-origin and three of its sections' y-origins.
    "PANEL_X",
    "PANEL_HEADER_Y",
    "PANEL_DIVIDER_Y",
    "PANEL_NOTICE_Y",
    # Move-list panel section (S5-finish, GUI_LOG(2) scope, plan D12): the
    # only remaining panel-section y-origin render_core.asm's move-list
    # painter needs (src/sprinter/gui_log_sprinter.c's Sprinter-native
    # replacement for the ZX/Next GUI_LOG overlay -- see that file's own
    # header for why this port does not link the ZX overlay's Z80 word-
    # wrap/ply-parsing helpers).
    "PANEL_MOVES_Y",
    "PANEL_CHAT_Y",
    # video.asm (production subset of video_s1.asm): palette/video_init
    # setup, and RTC sampling for the HUD clock
    "write_palette_entry",
    "video_init",
    # S9 follow-up (2026-08-18): screen fades. Palette-only -- see video.asm's
    # own fade section header for why a 96-byte rewrite is the whole effect.
    "fade_out",
    "fade_in",
    # palette_apply_from is video_init's own body with the table passed in
    # (HL): the S9 About overlay swaps the whole 16-entry palette for its
    # image and hands back through video_init on exit. Bridged because the
    # overlay lives in WIN3 and so cannot be mapped while the palette
    # registers are -- see video.asm's own comment.
    "palette_apply_from",
    # buffers.asm's four About image page cells (S9 About pass). The overlay
    # reads them to know which physical pages to blit from.
    "about_page0",
    # Explicit whole-screen invalidation for the About screen. The 32
    # gfx_draw_tile calls it makes would overflow the flip ring and promote
    # to dirty_all on their own, but relying on overflow is relying on a
    # ring size nobody promised -- say it outright instead.
    "flip_mark_dirty_all",
    "rtc_sample",
    "rtc_present",
    "rtc_valid",
    "rtc_hour",
    "rtc_minute",
    "rtc_second",
    # S5-finish plan D12 (THEME menu action): cycles the board light/dark
    # square palette entries (2/3) through a small preset table -- see
    # video.asm's own theme_set_squares comment for why this is a palette
    # rewrite, not a redraw, unlike ZX's ATTR-based board_theme_apply.
    "theme_set_squares",
    # im2_s1.asm -- boot/interrupt/exit primitives, called once each from
    # crt0/_main rather than from the frame loop.
    "im2_install",
    "im2_uninstall",
    "canary_check",
    "frame_wait",
    "exit_stand",
    # im2_s1.asm -- non-blocking keyboard poll, called every frame from
    # the frame loop (S5 substep 3, input handling's first slice).
    "key_poll",
    "key_code",
    # S8 step 8c: free-running frame counter (im2_frame_core's own comment
    # has the full rationale) -- the MQTT ClientId/session-id nonce source,
    # read from src/sprinter/transport/unet_link.c.
    "frame_counter",
    # net_gate.asm -- the funnel into LIBMAN.l_call (ng_* wrappers take no
    # caller-supplied pointers; buffers are net_gate's own WIN2-resident
    # ones, per port.md's "R5" note).
    "ng_up",
    "ng_connect",
    "ng_send",
    "ng_recv",
    "ng_close",
    "ng_lasterr_fetch",
    "ng_shutdown",
    # S7 (port.md section 3.7): src/sprinter/transport/unet_link.c's link.h
    # winders need the peer IP for last_ip/sync_time-adjacent diagnostics,
    # NETHOST/NETPORT env config for connect_host/preflight_run, and enough
    # of net_gate's own diagnostic state (ng_buf_rx for the framing core to
    # read received bytes from, ng_buf_lasterr/ng_up_reason/ng_backend for
    # NERR_*/ng_up_reason -> text mapping) to report something meaningful
    # on failure instead of a bare status code.
    "ng_getinfo_ip",
    "ng_env_nethost",
    "ng_env_netport",
    # ng_env_* return one of these two pointers when DSS did not have the
    # variable, so a pointer compare tells the join panel whether it is
    # showing a real NETHOST/NETPORT or a compiled-in default -- see the
    # ng_env_nethost banner in net_gate.asm.
    "ng_default_host",
    "ng_default_port",
    "ng_buf_ip",
    "ng_buf_rx",
    "ng_buf_lasterr",
    "ng_up_reason",
    "ng_backend",
    "ng_v_last_nerr",
    "ng_v_last_cf",
    # C-callable wrappers for ng_connect/ng_send/ng_recv (register-ABI
    # functions unet_link.c cannot call directly) plus their parameter/
    # result cells -- see net_gate.asm's own "C-callable wrappers" banner.
    "ng_c_connect",
    "ng_c_send",
    "ng_c_recv_poll",
    "ng_c_send_ptr",
    "ng_c_send_len",
    "ng_v_call_status",
    "ng_v_call_len",
    "ng_v_call_flags",
    "ng_v_call_cf",
    # S8 step 7: ng_recv's per-poll request ceiling, lowered by net_frame.c's
    # nc_mqtt_pump() to the MQTT stream accumulator's free room before each
    # poll -- see net_gate.asm's own comment on the cell.
    "ng_c_recv_max",
    # S8 step 8c: MQTT connect (arbitrary broker, not NETHOST/NETPORT) and a
    # generic env resolver -- see net_gate.asm's own comments on each.
    "ng_c_connect_at",
    "ng_c_connect_host",
    "ng_c_connect_port",
    "ng_c_env_get",
    "ng_c_env_name",
    "ng_c_env_dest",
    "ng_c_env_found",
    # dss_fileio.asm -- esx-ABI-over-DSS file I/O gate (S6, port.md section
    # 3.10 item 4). Called from the SAVELOAD/RESTORE/FILEUI overlay C
    # sources (src/spectrum/overlay/{saveload,fileui}_ovl.c), which are
    # linked separately from the resident, so this call surface -- like
    # net_gate's ng_* one above -- has to be bridged the same way.
    "esx_handle",
    "esx_buf",
    "esx_count",
    "esx_result",
    "esx_fopen",
    "esx_fcreate",
    "esx_fread",
    "esx_fwrite",
    "esx_fclose",
    "esx_funlink",
    "esx_opendir",
    "esx_readdir",
    "spectrum_net_runtime_fat_date",
    "spectrum_net_runtime_fat_time",
    # spectrum_net_background_drain moved to OVERLAY_RESIDENT_SYMBOLS in
    # gen_sprinter_overlay_defs.py (S7): dss_fileio.asm's S6-era no-op
    # placeholder is gone, superseded by unet_link.c's real WIN1
    # implementation (nc_pump) -- SAVELOAD/FILEUI overlays now resolve
    # the SAME name against resident_c.map instead of this sjasmplus
    # bridge, the same way they already reach netchess_after_prefix.
    "spectrum_platform_save_dir",
    "spectrum_platform_save_dir_init",
    "spectrum_platform_last_dss_error_text",
    # overlay slot copy (substep 2's overlay_loader_sprinter.asm is a
    # z88dk-z80asm module and must not touch WIN0_PORT itself -- R1)
    "ovl_copy_slot",
    "OVL_SLOT_ADDR",
    "OVL_SLOT_SIZE",
    # WIN3-paged overlays (plan D7-bis, S5 substep 3b): the 2 KiB copy slot
    # above cannot hold a compiled C overlay of real size (BOARD links to
    # 2772 bytes), so RULES/BOARD are instead linked at their own ORG inside
    # the WIN3 window and mapped with a single OUT rather than copied. The
    # port number itself is bridged (rather than spelled #E2 in the z88dk-
    # z80asm loader) so dss.inc stays the one place that names it.
    "WIN3_PORT",
    # S7 step 4 (byte-budget ladder): render_core_cold.asm (WIN2 net_frame_c
    # blob) reads gui.c's spectrum_gui_board_flipped, a fixed lowram address
    # on Sprinter now (gui.c's own comment on the same build-order gap
    # config/session.h documents). platform_primitives.asm INCLUDEs
    # fixed_layout.inc, so this EQU is already in its own .sym -- no new
    # sjasmplus-side plumbing needed, just adding it to this allowlist.
    "LOWRAM_RENDER_SHARED_ADDR",
]

GENERATED_BANNER = (
    "Generated by tools/gen_sprinter_platform_defs.py from a sjasmplus "
    "--sym file. Do not edit by hand."
)

SYM_LINE = re.compile(r"^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)\s*$")


class PlatformDefsError(Exception):
    pass


def parse_sym(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = SYM_LINE.match(line.strip())
            if match:
                symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def render(symbols: dict[str, int], names: list[str]) -> str:
    missing = [name for name in names if name not in symbols]
    if missing:
        raise PlatformDefsError(
            "missing platform symbol(s) (add to platform_core.asm or drop "
            "from PLATFORM_SYMBOLS): " + ", ".join(missing)
        )
    lines = [f";; {GENERATED_BANNER}", ";; z88dk-z80asm syntax (consumed by"
             " render_core.asm / overlay_loader_sprinter.asm / the C image)",
             ""]
    for name in names:
        addr = symbols[name]
        lines.append(f"PUBLIC {name}")
        lines.append(f"defc {name} = ${addr:04X}")
        lines.append(f"PUBLIC _{name}")
        lines.append(f"defc _{name} = ${addr:04X}")
    lines.append("")
    return "\n".join(lines)


# Curated fixture list for tests/sprinter/z80/t_net_mqtt_read.asm, which
# INCBINs the SHIPPED spliced resident image and stubs uNet out at exactly
# these two entry points (patching a JP over each after the INCBIN), reading
# and writing net_gate.asm's own result cells around them. Separate from
# PLATFORM_SYMBOLS above for the same reason gen_sprinter_overlay_defs.py
# keeps RESIDENT_TEST_SYMBOLS apart: that list is a shipping contract, this
# one is a test fixture.
PLATFORM_TEST_SYMBOLS = [
    "ng_c_recv_poll",
    "ng_c_send",
    "ng_buf_rx",
    "ng_c_recv_max",
    "ng_c_send_ptr",
    "ng_c_send_len",
    "ng_v_call_status",
    "ng_v_call_len",
    "ng_v_call_flags",
    "ng_v_call_cf",
    # tests/sprinter/z80/t_menu_flip.asm: the cold-call thunks refuse to
    # dispatch while this is #FF (nothing published yet -- see cold_thunks'
    # own cold_no_page guard), which is exactly the state a freshly INCBINed
    # resident image is in, so that test has to publish a page itself.
    "cold_win3_page",
    # tests/sprinter/z80/t_net_mqtt_read.asm patches this to a counting stub
    # to assert on Sprinter's read-payload pacing (S9 MQTT-lag fix,
    # 2026-08-19).
    "frame_wait",
]


def render_sjasmplus(symbols: dict[str, int], names: list[str]) -> str:
    """Same addresses, sjasmplus EQU syntax, for the z80 test harness.

    Only the handful of names the harness pokes, prefixed, rather than the
    whole .sym file: sjasmplus rejects a duplicate EQU, and the .sym shares
    plenty of names (CANARY_ADDR, STACK_TOP, ...) with fixed_layout.inc,
    which the same test also includes.
    """
    missing = [name for name in names if name not in symbols]
    if missing:
        raise PlatformDefsError(
            "missing platform symbol(s): " + ", ".join(missing)
        )
    lines = [f";; {GENERATED_BANNER}",
             ";; sjasmplus syntax (consumed by tests/sprinter/z80/"
             "t_net_mqtt_read.asm)",
             ""]
    for name in names:
        lines.append(f"plat_{name}: EQU ${symbols[name]:04X}")
    lines.append("")
    return "\n".join(lines)


def _clean_fixture() -> str:
    return (
        "GFX_SLOT: EQU 0x00000010\n"
        "gfx_swap_buffers: EQU 0x00004774\n"
        "gfx_swap_buffers.local: EQU 0x00004777\n"
        "gfx_clear_buffer: EQU 0x0000477B\n"
        "gfx_fill_rect: EQU 0x000047B2\n"
        "gfx_hline: EQU 0x00004881\n"
        "gfx_draw_tile: EQU 0x00004902\n"
        "gfx_blit_rows: EQU 0x0000496B\n"
        "text_print: EQU 0x000049C6\n"
        "bench_init: EQU 0x00008200\n"
        "resolve_buffers: EQU 0x00008210\n"
        "flip_ring_reset: EQU 0x00008216\n"
        "bench_asset_page: EQU 0x00008220\n"
        "front_base: EQU 0x00008222\n"
        "back_base: EQU 0x00008224\n"
        "piece_page1: EQU 0x00008226\n"
        "piece_page2: EQU 0x00008227\n"
        "ovl_win3_page: EQU 0x00008228\n"
        "cold_win3_page: EQU 0x00008229\n"
        "ovl_win3_page2: EQU 0x0000822A\n"
        "tile_dest_base: EQU 0x00004920\n"
        "tile_x_byte: EQU 0x00004922\n"
        "tile_x_hi: EQU 0x00004923\n"
        "tile_y: EQU 0x00004924\n"
        "tile_src_page: EQU 0x00004925\n"
        "tile_src_slot: EQU 0x00004926\n"
        "tile_stride: EQU 0x00004927\n"
        "tile_width: EQU 0x00004928\n"
        "tile_rows: EQU 0x00004929\n"
        "tile_alias: EQU 0x0000492A\n"
        "BOARD_X: EQU 0x00000010\n"
        "BOARD_Y: EQU 0x00000028\n"
        "BOARD_COLS: EQU 0x00000008\n"
        "BOARD_ROWS: EQU 0x00000008\n"
        "BOARD_CELL_W: EQU 0x00000030\n"
        "BOARD_CELL_H: EQU 0x00000018\n"
        "LOWRAM_CHESS_BOARD_ADDR: EQU 0x0000B2AF\n"
        "LOWRAM_MOVE_LOG_ADDR: EQU 0x0000B36F\n"
        "LOWRAM_CHAT_LOG_ADDR: EQU 0x0000B0E0\n"
        "LOWRAM_OVERLAY_CONTEXT_ADDR: EQU 0x0000B32F\n"
        "LOWRAM_OVERLAY_SCRATCH_ADDR: EQU 0x0000B33F\n"
        "LOWRAM_RULES_BOARD_ADDR: EQU 0x0000B2EF\n"
        "LOWRAM_HINTED_ROWS_ADDR: EQU 0x0000B347\n"
        "MOVE_Y: EQU 0x0000001C\n"
        "STATUS_Y: EQU 0x000000E8\n"
        "BANNER_Y: EQU 0x00000000\n"
        "MENU_Y: EQU 0x00000010\n"
        "INPUT_Y: EQU 0x000000F4\n"
        "PANEL_X: EQU 0x00000198\n"
        "PANEL_HEADER_Y: EQU 0x00000028\n"
        "PANEL_DIVIDER_Y: EQU 0x0000008D\n"
        "PANEL_NOTICE_Y: EQU 0x000000DC\n"
        "PANEL_MOVES_Y: EQU 0x00000034\n"
        "PANEL_CHAT_Y: EQU 0x00000094\n"
        "write_palette_entry: EQU 0x000044CA\n"
        "video_init: EQU 0x00004600\n"
        "palette_apply_from: EQU 0x00004603\n"
        "about_page0: EQU 0x0000469A\n"
        "flip_mark_dirty_all: EQU 0x000046A0\n"
        "fade_out: EQU 0x00004650\n"
        "fade_in: EQU 0x00004660\n"
        "rtc_sample: EQU 0x000045B6\n"
        "rtc_present: EQU 0x00004700\n"
        "rtc_valid: EQU 0x00004701\n"
        "rtc_hour: EQU 0x00004702\n"
        "rtc_minute: EQU 0x00004703\n"
        "rtc_second: EQU 0x00004704\n"
        "im2_install: EQU 0x0000811F\n"
        "im2_uninstall: EQU 0x00008130\n"
        "canary_check: EQU 0x00008140\n"
        "frame_wait: EQU 0x00008150\n"
        "exit_stand: EQU 0x00008160\n"
        "key_poll: EQU 0x00008165\n"
        "key_code: EQU 0x00008170\n"
        "frame_counter: EQU 0x00008172\n"
        "ng_up: EQU 0x0000899F\n"
        "ng_connect: EQU 0x000089A0\n"
        "ng_send: EQU 0x000089B0\n"
        "ng_recv: EQU 0x000089C0\n"
        "ng_close: EQU 0x000089D0\n"
        "ng_lasterr_fetch: EQU 0x000089E0\n"
        "ng_shutdown: EQU 0x000089F0\n"
        "ng_getinfo_ip: EQU 0x000089F8\n"
        "ng_env_nethost: EQU 0x00008C00\n"
        "ng_env_netport: EQU 0x00008C08\n"
        "ng_default_host: EQU 0x00008C10\n"
        "ng_default_port: EQU 0x00008C1A\n"
        "ng_buf_ip: EQU 0x00008C40\n"
        "ng_buf_rx: EQU 0x00008C50\n"
        "ng_buf_lasterr: EQU 0x00008D00\n"
        "ng_up_reason: EQU 0x00008D40\n"
        "ng_backend: EQU 0x00008D41\n"
        "ng_v_last_nerr: EQU 0x00008D42\n"
        "ng_v_last_cf: EQU 0x00008D43\n"
        "ng_c_connect: EQU 0x00008E00\n"
        "ng_c_send: EQU 0x00008E10\n"
        "ng_c_recv_poll: EQU 0x00008E20\n"
        "ng_c_send_ptr: EQU 0x00008F94\n"
        "ng_c_send_len: EQU 0x00008F96\n"
        "ng_v_call_status: EQU 0x00008F97\n"
        "ng_v_call_len: EQU 0x00008F98\n"
        "ng_v_call_flags: EQU 0x00008F9A\n"
        "ng_v_call_cf: EQU 0x00008F9C\n"
        "ng_c_recv_max: EQU 0x00008F9D\n"
        "ng_c_connect_at: EQU 0x00008FA0\n"
        "ng_c_connect_host: EQU 0x00008FA2\n"
        "ng_c_connect_port: EQU 0x00008FA4\n"
        "ng_c_env_get: EQU 0x00008FA6\n"
        "ng_c_env_name: EQU 0x00008FA8\n"
        "ng_c_env_dest: EQU 0x00008FAA\n"
        "ng_c_env_found: EQU 0x00008FAC\n"
        "esx_handle: EQU 0x00008B00\n"
        "esx_buf: EQU 0x00008B01\n"
        "esx_count: EQU 0x00008B03\n"
        "esx_result: EQU 0x00008B05\n"
        "esx_fopen: EQU 0x00008B10\n"
        "esx_fcreate: EQU 0x00008B20\n"
        "esx_fread: EQU 0x00008B30\n"
        "esx_fwrite: EQU 0x00008B40\n"
        "esx_fclose: EQU 0x00008B50\n"
        "esx_funlink: EQU 0x00008B60\n"
        "esx_opendir: EQU 0x00008B70\n"
        "esx_readdir: EQU 0x00008B80\n"
        "spectrum_net_runtime_fat_date: EQU 0x00008B90\n"
        "spectrum_net_runtime_fat_time: EQU 0x00008BA0\n"
        "spectrum_platform_save_dir: EQU 0x00008BC0\n"
        "spectrum_platform_save_dir_init: EQU 0x00008BD0\n"
        "spectrum_platform_last_dss_error_text: EQU 0x00008BE0\n"
        "ovl_copy_slot: EQU 0x00008A00\n"
        "OVL_SLOT_ADDR: EQU 0x0000A800\n"
        "OVL_SLOT_SIZE: EQU 0x00000800\n"
        "WIN3_PORT: EQU 0x000000E2\n"
        "LOWRAM_RENDER_SHARED_ADDR: EQU 0x0000B400\n"
        "theme_set_squares: EQU 0x00004680\n"
    )


def self_test() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        sym_path = Path(tmp) / "clean.sym"
        sym_path.write_text(_clean_fixture(), encoding="ascii")
        symbols = parse_sym(sym_path)

        if symbols.get("GFX_SLOT") != 0x10:
            raise SystemExit("[ERR] platform-defs self-test: manifest constant not parsed")
        if "gfx_swap_buffers.local" not in symbols:
            raise SystemExit("[ERR] platform-defs self-test: dotted local label not parsed")

        out1 = render(symbols, PLATFORM_SYMBOLS)
        out2 = render(symbols, PLATFORM_SYMBOLS)
        if out1 != out2:
            raise SystemExit("[ERR] platform-defs self-test: rendering is not deterministic")
        if "PUBLIC gfx_swap_buffers" not in out1:
            raise SystemExit("[ERR] platform-defs self-test: plain name missing from output")
        if "PUBLIC _gfx_swap_buffers" not in out1:
            raise SystemExit("[ERR] platform-defs self-test: underscored alias missing")
        if "defc _gfx_swap_buffers = $4774" not in out1:
            raise SystemExit("[ERR] platform-defs self-test: address mismatch")
        # A local label sneaking into PLATFORM_SYMBOLS should resolve fine
        # (the allowlist controls the call surface, not the .sym parser) --
        # what must fail is a name genuinely absent from the .sym.
        try:
            render(symbols, PLATFORM_SYMBOLS + ["gfx_totally_missing"])
        except PlatformDefsError as exc:
            if "gfx_totally_missing" not in str(exc):
                raise SystemExit(
                    "[ERR] platform-defs self-test: wrong missing-symbol diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] platform-defs self-test: missing symbol was not rejected"
            )

        sj = render_sjasmplus(symbols, PLATFORM_TEST_SYMBOLS)
        if "plat_ng_c_recv_poll: EQU $" not in sj:
            raise SystemExit(
                "[ERR] platform-defs self-test: sjasmplus mode missing a symbol"
            )
        if sj != render_sjasmplus(symbols, PLATFORM_TEST_SYMBOLS):
            raise SystemExit(
                "[ERR] platform-defs self-test: sjasmplus mode not deterministic"
            )

    print("[OK] Sprinter platform-defs self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sym", type=Path, help="sjasmplus --sym output to read")
    parser.add_argument("--out", type=Path, help="platform_defs.asm to write")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--mode",
        choices=["defc", "sjasmplus"],
        default="defc",
        help="output syntax: z88dk defc (the shipping builds, "
             "PLATFORM_SYMBOLS) or sjasmplus EQU (the z80 resident test "
             "harness, PLATFORM_TEST_SYMBOLS)",
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.sym or not args.out:
        raise SystemExit(
            "gen_sprinter_platform_defs: --sym and --out are required unless --self-test"
        )

    symbols = parse_sym(args.sym)
    try:
        if args.mode == "sjasmplus":
            text = render_sjasmplus(symbols, PLATFORM_TEST_SYMBOLS)
        else:
            text = render(symbols, PLATFORM_SYMBOLS)
    except PlatformDefsError as exc:
        print(f"[ERR] {args.sym}: {exc}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="ascii")
    print(f"[OK] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
