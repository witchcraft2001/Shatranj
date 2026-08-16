#!/usr/bin/env python3
"""Bridge the WIN1 resident C image's symbols into the WIN3 cold-code page.

The mirror image of tools/gen_sprinter_cold_thunks.py: that tool lets WIN1
call into the cold page, this one lets the cold page call back out. Both
directions are needed because the page holds whole modules now, not leaf
routines -- src/spectrum/ui/gui.c lives there and calls the frame/key
shims, src/spectrum/platform/text.c and the session config, all of which
stay resident.

No window juggling is involved in THIS direction, which is why it is only
a defc table and not a thunk: WIN1 is always mapped, so cold-page code
reaches a resident routine with a plain `call`. What it cannot do is
resolve the address at compile time on its own -- hence the same
map-reading shape as gen_sprinter_overlay_defs.py (resident_c.map ->
overlay C) and gen_sprinter_netframe_defs.py (net_frame_c.map -> resident
C).

This is what fixed the build order: the cold page is built AFTER
resident_c.bin so this map exists, which is possible only because the
thunks in the other direction stopped needing the cold page's own map (see
gen_sprinter_cold_thunks.py's banner on the fixed entry table).

The output is a pure function of the input .map file (no timestamps), so
reruns are byte-identical -- same contract as the other gen_sprinter_*
tools.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Curated allowlist: only these resident symbols are visible to cold-page
# code. Adding a new cross-boundary call means adding its name here -- same
# discipline as OVERLAY_RESIDENT_SYMBOLS/PLATFORM_SYMBOLS/COLD_THUNK_SYMBOLS.
#
# A name here must NOT also be in COLD_THUNK_SYMBOLS: that would mean the
# same routine is claimed by both images, and the defc would silently win
# inside the page while WIN1 called the thunk. gen_sprinter_cold_thunks.py
# imports this list and the self-test below asserts the two are disjoint.
COLD_RESIDENT_SYMBOLS = [
    # render_shim.asm -- the three per-frame bridges deliberately left in
    # WIN1 because a thunk would cost more than the routine (1-9 byte
    # bodies). All three are exactly what gui.c reaches back for.
    "spectrum_frame_wait",
    "spectrum_key_poll",
    "spectrum_uart_background_pump",
    # src/common/chess/move_coords.c -- gui.c's move-log coordinate parse.
    "netchesszx_move_parse_coords",
    # src/spectrum/config/session.c -- a plain data byte, not a call. Safe
    # to read from the page for the same reason the calls above are safe to
    # make: WIN1 never leaves the address space, only WIN3 changes.
    "netchesszx_movement_hints",
    # --- S8 relief pass: src/sprinter/session_sprinter.c's own bridge -----
    # Mechanically derived from resident_c.map against that file's own
    # extracted text (every true resident symbol -- not a cold_thunks stub
    # published under the same name -- it references), plus net_active
    # itself (main.c) and netchesszx_local_color (config/session.c, reached
    # only through the netchesszx_local_is_white()/_session_has_local_turn()/
    # _local_side_name() macros in session.h, so it never appears as a
    # literal call in the source text -- found by reading the macros, not
    # by grep). See that file's own header for why everything else it uses
    # (render_core.asm, gui.c) needs no entry here: same cold-page image,
    # plain same-page calls.
    "net_active",                              # src/sprinter/main.c
    "side_to_move",                            # src/spectrum/board/board.c
    "spectrum_board_reset",
    "spectrum_board_is_legal_move",
    "spectrum_board_apply_trusted_move",
    "spectrum_board_apply_trusted_move_with_undo",
    "spectrum_board_cell",
    "spectrum_board_check_state",
    "spectrum_board_snapshot_save",
    "spectrum_board_snapshot_restore",
    "spectrum_board_undo_restore",
    "spectrum_gui_log_ply_get",                # src/sprinter/gui_log_sprinter.c
    "spectrum_gui_log_ply_set",
    "spectrum_gui_add_move",
    "spectrum_gui_remove_last_move",
    "spectrum_gui_reset_move_log",
    "spectrum_saveload_run",                   # src/spectrum/saveload/saveload.c
    "spectrum_restore_build_b64",              # src/spectrum/restore/restore.c
    "spectrum_restore_decode",
    "spectrum_fileui_open_render",             # src/spectrum/fileui/fileui.c
    "spectrum_fileui_send_key",
    "spectrum_fileui_selected_name",
    "spectrum_fileui_rerender",
    "netchesszx_local_color",                  # src/spectrum/config/session.c
    "netchesszx_host_color_ready",
    "netchesszx_session_configure",
    # S8 step 8e: menu_network()'s own post-connect follow-up branches on
    # the transport the NET screen picked (netchesszx_transport_is_mqtt(),
    # session.h's macro over this cell).
    "netchesszx_transport",
    "netchesszx_session_poll",                 # src/spectrum/session/poll.c
    "netchesszx_session_ping_reset",           # src/spectrum/session/ping.c
    "netchesszx_session_peer_reset",           # src/spectrum/session/direct.c
    "netchesszx_session_peer_mark_ready",
    "netchesszx_session_direct_send_hello",
    "netchesszx_session_direct_apply_hello",
    "netchesszx_session_direct_apply_start_side",
    "netchesszx_session_send_ack_move",        # src/spectrum/session/outgoing.c
    "netchesszx_session_send_nack_move",
    "netchesszx_session_send_ack_reset",
    "netchesszx_session_send_nack_reset",
    "netchesszx_session_send_nack_reset_busy",
    "netchesszx_session_send_ack_resign",
    "netchesszx_session_send_ack_game_start",
    "netchess_proto_parse_ack",                # src/common/protocol/game_protocol_extra.c
    "netchess_proto_parse_nack",
    "spectrum_append_text",                    # src/spectrum/platform/text.c
    "spectrum_append_u16",
    # --- S8 relief pass, second cut ----------------------------------------
    # session_sprinter.c overran the cold page's fixed 16 KiB ceiling by
    # 1806 bytes once built for real; main.c's own save/load/file-browser/
    # simple-menu-action code moved back to WIN1 to close the gap (main.c's
    # own comment ahead of pending_local_ply has the full accounting).
    # Mechanically re-derived the same way as the first batch above: every
    # true resident symbol the still-cold code (net_handle_event, retry_
    # pending_outgoing, board_select_or_move, menu_network, handle_menu_
    # action) now reaches in main.c instead of in this same file.
    "pending_local_ply",                       # src/sprinter/main.c
    "pending_local_move",
    "pending_retry_timer",
    "control_retry_count",
    "restore_rx_mask",
    "saveload_snapshot",
    "saveload_b64_pending",
    "fileui_open",
    "net_apply_loaded_snapshot",
    "menu_cycle_theme",
    "menu_flip_board",
    "menu_not_available",
    "saveload_full_redraw",
    # --- S8 relief pass, third cut ------------------------------------------
    # apply_takeback_snapshot through net_send_takeback_wire (main.c, ahead
    # of its own takeback_undo declaration) -- the second cut alone still
    # left the cold page 441 bytes over its fixed ceiling once actually
    # built. Same mechanical derivation as the two batches above.
    "takeback_undo",                           # src/sprinter/main.c
    "takeback_snapshot_ply",
    "takeback_snapshot_local",
    "apply_takeback_snapshot",
    "net_status_idle",
    "net_send_move_wire",
    "net_send_nack_sync",
    # net_repaint_move used to be here too -- removed in the S9 move-flash
    # pass along with the function itself (main.c), which replaced its one
    # call site with spectrum_gui_apply_move (gen_sprinter_cold_thunks.py's
    # COLD_THUNK_SYMBOLS, the opposite direction of this bridge).
    "net_apply_pending_local_move",
    "net_send_takeback_wire",
    # --- S8 step 8a (MQTT relief pass): src/sprinter/transport/unet_link.c
    # moved to WIN1 resident (see Makefile's SPRINTER_NET_FRAME_C_SRC
    # comment); session_sprinter.c (this cold page) reaches its link.h
    # surface -- spectrum_link_* macros, spectrum/transport/link.h -- through
    # this same defc bridge now, exactly as it already does for board.c/
    # fileui.c/config-session above. Only the subset session_sprinter.c
    # actually calls: send_text/direct_peer_mark_valid/payload_scratch/
    # start_uart, plus the new join_ui wrapper (below) that replaces the
    # cold-page-native spectrum_net_join_ui this same file used to call
    # same-page before net_ui_sprinter.c moved into the NET overlay (S8
    # step 8b) -- see gen_sprinter_cold_thunks.py's COLD_THUNK_SYMBOLS,
    # which no longer lists this name for the opposite reason.
    "spectrum_net_send_text",
    "spectrum_net_direct_peer_mark_valid",
    "spectrum_net_payload_scratch",
    "spectrum_net_start_uart",
    "spectrum_net_join_ui",
    # --- S8 step 8f: the MQTT presence half of session_sprinter.c's own
    # net_handle_event (a port of app.c's session_presence_handle_event --
    # see that function's own header for why it had to be ported at all).
    # Same homes as everything above: WIN1 C (session/event.c,
    # config/session.c, unet_link.c, mqtt_session_wire.c). NOT here:
    # netchess_mqtt_session_parse_host, which the same code calls -- it
    # lives in the WIN2 blob, and the cold page links netframe_defs.asm
    # directly, so listing it here is a duplicate definition, not a bridge.
    "netchesszx_session_role",                 # src/spectrum/config/session.c
    "netchesszx_mqtt_session_id",
    "netchesszx_session_peer_ready_state",     # src/spectrum/session/event.c
    "netchesszx_session_mqtt_host_flags",
    "spectrum_net_mqtt_activate_side",         # src/sprinter/transport/unet_link.c
    "spectrum_net_mqtt_probe_seat",
    "spectrum_net_mqtt_publish_presence",
    "spectrum_net_mqtt_publish_setup",
    "spectrum_net_mqtt_publish_offline",       # src/spectrum/transport/mqtt_session_wire.c
    # The two diagnostic groups this file's net_link_down_why/
    # net_mqtt_fail_why turn into a notice line: which layer called the link
    # down, and which MQTT overlay step gave up.
    "net_mqtt_down_reason",                    # src/sprinter/transport/unet_link.c
    # Not diagnostics: net_send_failed BRANCHES on this one -- a send that
    # exhausted its busy-retry budget on NERR_BUSY did not fail, it did not
    # happen. Same file as the group above.
    "net_send_busy",
    "net_mqtt_fail_step",
    "net_mqtt_fail_cf",
    "net_mqtt_fail_status",
    "net_mqtt_fail_detail",
    "net_mqtt_rx_count",
    "net_mqtt_rx_game_count",
    "net_mqtt_ovl_dropped",
    # S9 chat pass: session_sprinter.c's own CHAT event branch and net_drop
    # reach gui_log_sprinter.c's chat dispatchers directly, same shape as
    # spectrum_gui_reset_move_log already had (this file, S8 relief pass).
    "spectrum_gui_add_chat",
    "spectrum_gui_reset_chat",
]

GENERATED_BANNER = (
    "Generated by tools/gen_sprinter_cold_defs.py from the resident C "
    "image's .map file. Do not edit by hand."
)

# z88dk map lines: "_name    = $ADDR ; addr, public, ...". C symbols always
# carry the leading underscore z88dk adds; the allowlist omits it (to read
# the same as the C source) and this parser strips it back off.
MAP_LINE = re.compile(r"^_(\S+)\s+=\s+\$([0-9A-Fa-f]+)\s*;")

# The WIN1 resident C image's window. A symbol outside it is not something
# the cold page can call with WIN3 mapped to itself.
RESIDENT_LO = 0x4000
RESIDENT_HI = 0xBFFF


class ColdDefsError(Exception):
    pass


def parse_map(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = MAP_LINE.match(line.strip())
            if match:
                symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def render(symbols: dict[str, int], names: list[str]) -> str:
    missing = [name for name in names if name not in symbols]
    if missing:
        raise ColdDefsError(
            "missing resident symbol(s) (add to SPRINTER_RESIDENT_C_SRC or "
            "drop from COLD_RESIDENT_SYMBOLS): " + ", ".join(missing)
        )
    outside = [
        name for name in names
        if not RESIDENT_LO <= symbols[name] <= RESIDENT_HI
    ]
    if outside:
        raise ColdDefsError(
            "resident symbol(s) outside the always-mapped WIN1/WIN2 range "
            f"#{RESIDENT_LO:04X}-#{RESIDENT_HI:04X} (the cold page cannot "
            "reach those with itself mapped into WIN3): "
            + ", ".join(f"{n}=${symbols[n]:04X}" for n in outside)
        )
    lines = [
        f";; {GENERATED_BANNER}",
        ";; z88dk-z80asm syntax (linked into the WIN3 cold-code page "
        "alongside src/spectrum/ui/gui.c)",
        "",
    ]
    for name in names:
        addr = symbols[name]
        lines.append(f"PUBLIC _{name}")
        lines.append(f"defc _{name} = ${addr:04X}")
        lines.append(f"PUBLIC {name}")
        lines.append(f"defc {name} = ${addr:04X}")
    lines.append("")
    return "\n".join(lines)


def verify(defs_path: Path, map_path: Path) -> list[str]:
    """Every address the cold page baked must match the resident that shipped.

    The cold page calls WIN1 by absolute address through the defc bridge this
    tool writes. If the bridge is generated from a stale resident_c.map --
    which GNU make 3.81 managed to do, because the map's own rule carries no
    recipe -- the page calls into the middle of whatever moved, and the
    failure is a silent wrong jump, not a link error. On 2026-08-15 that
    shipped: 42 of 78 symbols wrong, spectrum_net_join_ui among them, so
    selecting DISCC jumped into the wrong WIN1 function and the network
    screen never opened. Returns the list of disagreements (empty = clean).
    """
    resident = parse_map(map_path)
    baked = dict(
        (name, int(addr, 16))
        for name, addr in re.findall(r"^defc _(\S+) = \$([0-9A-Fa-f]+)",
                                     defs_path.read_text(encoding="ascii",
                                                         errors="replace"),
                                     re.MULTILINE)
    )
    problems = []
    for name, addr in sorted(baked.items()):
        if name not in resident:
            problems.append(f"{name}: baked ${addr:04X}, absent from the resident")
        elif resident[name] != addr:
            problems.append(
                f"{name}: cold page calls ${addr:04X}, resident has ${resident[name]:04X}"
            )
    return problems


def _clean_fixture() -> str:
    lines = []
    addr = 0x7100
    for name in COLD_RESIDENT_SYMBOLS:
        lines.append(
            f"_{name:<32} = ${addr:04X} ; addr, public, , "
            "render_shim, code_user, "
            "asm/sprinter/zcc/render_shim.asm:1\n"
        )
        addr += 0x20
    lines.append(
        "i_7                              = $7100 ; addr, local, , "
        "src_spectrum_board_board_c, code_compiler, "
        "src/spectrum/board/board.c::whatever::0::0:1\n"
    )
    return "".join(lines)


def self_test() -> None:
    import tempfile

    import gen_sprinter_cold_thunks as thunks

    both = sorted(set(COLD_RESIDENT_SYMBOLS) & set(thunks.COLD_THUNK_SYMBOLS))
    if both:
        raise SystemExit(
            "[ERR] cold-defs self-test: symbol(s) claimed by BOTH images "
            "(a cold-page thunk and a resident defc): " + ", ".join(both)
        )

    with tempfile.TemporaryDirectory() as tmp:
        map_path = Path(tmp) / "clean.map"
        map_path.write_text(_clean_fixture(), encoding="ascii")
        symbols = parse_map(map_path)

        if symbols.get("spectrum_frame_wait") != 0x7100:
            raise SystemExit("[ERR] cold-defs self-test: symbol not parsed")
        if "i_7" in symbols:
            raise SystemExit("[ERR] cold-defs self-test: local label wrongly captured")

        out1 = render(symbols, COLD_RESIDENT_SYMBOLS)
        out2 = render(symbols, COLD_RESIDENT_SYMBOLS)
        if out1 != out2:
            raise SystemExit("[ERR] cold-defs self-test: rendering is not deterministic")
        if "defc _spectrum_frame_wait = $7100" not in out1:
            raise SystemExit("[ERR] cold-defs self-test: underscored defc missing")
        if "defc spectrum_frame_wait = $7100" not in out1:
            raise SystemExit("[ERR] cold-defs self-test: asm-facing defc missing")

        try:
            render(symbols, COLD_RESIDENT_SYMBOLS + ["totally_missing"])
        except ColdDefsError as exc:
            if "totally_missing" not in str(exc):
                raise SystemExit(
                    "[ERR] cold-defs self-test: wrong missing-symbol diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] cold-defs self-test: missing symbol was not rejected"
            )

        # A resident symbol that somehow resolved into the WIN3 window is
        # the one mistake that would link cleanly and then call itself.
        try:
            render({"spectrum_frame_wait": 0xC123}, ["spectrum_frame_wait"])
        except ColdDefsError as exc:
            if "outside the always-mapped" not in str(exc):
                raise SystemExit(
                    "[ERR] cold-defs self-test: wrong out-of-range diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] cold-defs self-test: WIN3-range address was not rejected"
            )

    print("[OK] Sprinter cold-defs self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map", type=Path, help="resident_c.map to read")
    parser.add_argument("--out", type=Path, help="cold_defs.asm to write")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--verify", type=Path,
                        help="cold_defs.asm to check against --map instead of writing")
    args = parser.parse_args()

    if args.self_test:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        self_test()
        return 0

    if args.verify:
        if not args.map:
            raise SystemExit("gen_sprinter_cold_defs: --verify needs --map")
        problems = verify(args.verify, args.map)
        if problems:
            print(f"[ERR] {args.verify} disagrees with {args.map}:", file=sys.stderr)
            for line in problems:
                print(f"       {line}", file=sys.stderr)
            print("       the cold page was built against a different resident "
                  "layout -- it must be rebuilt AFTER the resident, never before",
                  file=sys.stderr)
            return 1
        print(f"[OK] {args.verify}: cold-page bridge agrees with {args.map}")
        return 0

    if not args.map or not args.out:
        raise SystemExit(
            "gen_sprinter_cold_defs: --map and --out are required unless --self-test"
        )

    symbols = parse_map(args.map)
    try:
        text = render(symbols, COLD_RESIDENT_SYMBOLS)
    except ColdDefsError as exc:
        print(f"[ERR] {args.map}: {exc}", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="ascii")
    print(f"[OK] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
