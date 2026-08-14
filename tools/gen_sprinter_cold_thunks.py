#!/usr/bin/env python3
"""Generate the two halves of the Sprinter WIN3 cold-code page's call ABI.

S7 step 4 put asm/sprinter/zcc/render_core.asm into a 16 KiB page mapped
into WIN3 on demand instead of into the always-mapped WIN1 resident C
image; S7 step 5 turned that page into a general home for every part of
the program that is not in the hot render cycle (src/spectrum/ui/gui.c
first). Both halves of the boundary are emitted here, from ONE ordered
allowlist, so they cannot drift apart:

  --mode entry-table  ->  the cold page's own dispatch table, INCLUDEd by
      asm/sprinter/zcc/cold_page_crt0.asm at the very top of the image so
      entry i is at COLD_ENTRY_BASE + 3*i, forever, whatever the linker
      does with the bodies behind it.

  --mode thunks       ->  the WIN1 stubs, published under the exact same
      public names the routines had when they were resident. Nothing on
      the calling side changed: this is a placement change, not an API
      change.

WHY A FIXED TABLE AND NOT THE PAGE'S .map (the S7 step 4 shape): with the
stub addresses fixed by construction, the resident no longer has to be
built after the cold page. That freed the build order to be reversed --
resident_c.bin first, cold page second -- which is what lets cold-page
code CALL BACK into the resident (tools/gen_sprinter_cold_defs.py bridges
resident_c.map the other way). Without that, only leaf code could ever
live in the page, and gui.c (which calls the session config, text.c and
the frame/key shims) could not have moved at all. The three bytes per
entry buy the whole bidirectional bridge.

The table is still checked against reality after the link: --mode verify
reads the built page's .map and fails if any entry is not exactly where
the stubs believe it is.

ABI: each stub is register-transparent -- AF and HL are saved and restored
before the target runs, and BC/DE/IX/IY are never touched -- so the target
keeps whatever calling convention it had as a resident routine, whether
that is z88dk classic's stack arguments or a fastcall value in HL. The
target's return registers and flags survive the restore path unchanged.

Deliberate deviation from rule R7 ("WIN3 replaced only under DI, whole
duration"): the trampoline holds DI across each port write, but re-enables
interrupts for the target call itself. asm/sprinter/zcc/render_core.asm's
header records why that is safe here specifically -- im2_s1.asm's ISR core
touches only PORT_RGMOD and fixed WIN2 cells, and every SLOT3 user inside
Estex-DSS brackets its own save/restore -- and why the same is NOT true of
the WIN0 window.

The output is a pure function of the allowlist (no timestamps, no clock),
so reruns are byte-identical -- same contract as the other gen_sprinter_*
tools.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The WIN3 window base. The entry table is the first thing in the page
# image (cold_page_crt0.asm INCLUDEs it immediately after `org
# CRT_ORG_CODE`), so entry i lives at COLD_ENTRY_BASE + COLD_ENTRY_STRIDE*i.
COLD_ENTRY_BASE = 0xC000
COLD_ENTRY_STRIDE = 3          # one `jp nnnn`

# Curated, ORDER-SIGNIFICANT allowlist: every cold-page entry point WIN1
# (or a WIN3 overlay calling through WIN1) may reach. The index of a name
# in this list IS its address, so:
#
#   * APPEND new entries, never insert -- an insert silently renumbers
#     every entry after it. (A stale resident linked against a renumbered
#     table would call the wrong routine, which is why --mode verify runs
#     on every build.)
#   * Removing an entry is fine and renumbers freely, because both halves
#     are regenerated from this one list in the same build.
#
# Names are spelled without z88dk's leading underscore (so they read like
# the C source); both generated halves carry it.
#
# NOT in this list, deliberately: spectrum_frame_wait, spectrum_key_poll
# and spectrum_uart_background_pump. Those three are the only once-per-
# frame entries of the original render_core.asm and have 1-9 byte bodies,
# so they stayed resident in asm/sprinter/zcc/render_shim.asm instead --
# a thunk would have cost more than the routine. They are also what the
# cold page itself calls back into (gui.c uses both), which only works
# because they are resident.
COLD_THUNK_SYMBOLS = [
    # --- asm-facing names main.c calls directly (S5 substep 3 wiring) ---
    "video_clear_both_buffers",
    "render_banner",
    "render_board_full",
    "render_coord_labels",
    "render_menu_bar",
    "render_status_clock",
    "render_status_text",
    "render_input_line",
    "render_input_key_echo",
    "render_square",
    "render_square_marked",
    "render_cursor_marker",
    "render_select_marker",
    "board_cursor_move",
    # --- portable render.h/gui.h API gui.c and the overlays link against ---
    "spectrum_render_board",
    "spectrum_render_board_area",
    "spectrum_render_board_coords",
    "spectrum_render_board_coord_mark",
    "spectrum_render_square",
    "spectrum_render_square_attr",
    "spectrum_render_square_with_hint",
    "spectrum_render_square_mark",
    "spectrum_render_square_mark_with_hint",
    "spectrum_render_clock",
    "spectrum_render_game_timer_clear",
    "spectrum_render_game_timer_char",
    "spectrum_render_menu_timer_char",
    "spectrum_render_turn_label",
    "spectrum_render_status",
    "spectrum_render_status_error",
    "spectrum_render_connection",
    "spectrum_render_notice",
    "spectrum_render_notice_error",
    "spectrum_render_notice_success",
    "spectrum_render_input",
    "spectrum_render_input_cell",
    "spectrum_render_moves",
    "spectrum_render_move_at",
    "spectrum_render_moves_scroll",
    "spectrum_render_chat",
    "spectrum_render_chat_at",
    "spectrum_render_chat_scroll",
    "spectrum_info_show_game",
    "spectrum_render_menu",
    "spectrum_render_about",
    # --- FILEUI (S6 plan step 4): called from the FILEUI overlay, which is
    # itself WIN3-resident -- the stub saves whatever page it finds mapped
    # and puts that page back, so the overlay resumes normally on return.
    "spectrum_render_fileui_frame",
    "spectrum_render_ikkle_at",
    "spectrum_render_fileui_select",
    # --- src/spectrum/ui/gui.c (S7 step 5) ---------------------------------
    # gui.c moved into the page whole. These are the entries WIN1 actually
    # calls (main.c's frame loop and menu actions, fileui.c, saveload.c);
    # everything else gui.c publishes is reached from inside the page and
    # needs no stub. Unlike every entry above, several of these take
    # ORDINARY STACK ARGUMENTS -- that is what forced the trampoline to
    # stop using `call` (see its header).
    "spectrum_gui_tick",
    "spectrum_gui_handle_menu_key",
    "spectrum_gui_notify",
    "spectrum_gui_notify_persistent",
    "spectrum_gui_notify_success",
    "spectrum_gui_set_status",
    "spectrum_gui_set_connected",
    "spectrum_gui_set_clock",
    "spectrum_gui_set_turn_label",
    "spectrum_gui_set_board_view",
    "spectrum_gui_is_board_flipped",
    "spectrum_gui_redraw_board_view",
    "spectrum_gui_restore_board_area",
    "spectrum_gui_show_fileui",
    "spectrum_gui_fileui_visible",
    "spectrum_gui_clear_cursor_coords",
    "spectrum_gui_game_timer_start",
    "spectrum_gui_move_timer_reset",
    # --- src/sprinter/net_ui_sprinter.c (S7 step 5) ------------------------
    # The whole modal DIRECT-join screen behind one entry: main.c's NETWORK
    # tab calls it and gets back "connected" or "not".
    "spectrum_net_join_ui",
    # --- src/sprinter/session_sprinter.c (S8 relief pass) ------------------
    # The DIRECT-session/board-interaction/menu-action driver, moved here
    # verbatim off WIN1 (that file's own header has the full rationale).
    # These are the entry points main.c's frame loop and one boot-time call
    # still reach directly -- everything else this file defines is called
    # only from inside itself and needs no stub. fileui_process_key is NOT
    # here -- the second relief cut (main.c's own save/load section) moved
    # it, and everything it calls, back to WIN1 outright.
    "net_set_turn_label_from_side",
    "board_select_or_move",
    "net_retry_tick",
    "net_control_key",
    "net_poll_once",
    "handle_menu_action",
    # --- S8 relief pass, second cut -----------------------------------------
    # main.c's own save/load/file-browser/simple-menu-action code (moved
    # BACK to WIN1 once the whole-driver move above overran the cold page's
    # fixed 16 KiB ceiling by 1806 bytes -- see main.c's own comment ahead
    # of pending_local_ply for which subset and why) still needs these
    # three session_sprinter.c entries: the shared one-operation-pending
    # guard, the shared link-teardown path, and the shared "clear the board
    # highlight" helper -- each already has several OTHER callers that stay
    # on the cold page, so moving them too was not worth it for three call
    # sites total.
    "net_op_busy",
    "net_drop",
    "selection_clear",
    # --- S8 relief pass, third cut ------------------------------------------
    # The second cut alone still left the cold page 441 bytes over its
    # fixed ceiling once actually built; apply_takeback_snapshot and five
    # more functions (main.c, ahead of its own takeback_undo declaration)
    # moved back too. These three are their shared cold-page helpers --
    # each still has other callers here (board_select_or_move, net_apply_
    # reset, net_apply_remote_move, net_handle_event, ...) so they stayed
    # put instead of moving a third time.
    "pending_local_clear",
    "takeback_snapshot_save",
    "square_index",
]

GENERATED_BANNER = (
    "Generated by tools/gen_sprinter_cold_thunks.py from its own ordered "
    "allowlist. Do not edit by hand."
)

# z88dk map lines: "_name    = $ADDR ; addr, public, ...". Same parser the
# other gen_sprinter_* map readers use.
MAP_LINE = re.compile(r"^_(\S+)\s+=\s+\$([0-9A-Fa-f]+)\s*;")

# The shared trampoline, emitted once ahead of the stubs. Written out here
# rather than kept in a checked-in .asm file so the whole mechanism (stub
# shape and trampoline) stays in one place and cannot drift apart.
#
# Stack discipline, reading the stub below first:
#   push af / push hl   -> [HL][AF][ret_caller][args...]
#   ld hl,entry         -> HL = the cold-page table slot to run
#   jp cold_call
TRAMPOLINE = """; --- shared trampoline ---------------------------------------------------
;
; Entered from a stub below with HL = cold-page entry-table slot and the
; caller's HL/AF pushed (in that order).
;
; IT DOES NOT `call` THE TARGET -- and that is the whole point of this
; shape (S7 step 5). A `call` would push one more word, so a target
; reading its arguments at SP+2 (z88dk classic's ordinary convention)
; would read the caller's return address instead. The S7 step 4 version
; got away with `call` only because every entry it served was declared
; `void f(void)` or `__z88dk_fastcall` (src/spectrum/ui/render.h -- one
; argument, in HL, none on the stack). gui.c's API is not: it has
; three-argument functions, so the frame must survive untouched.
;
; Instead the trampoline SWAPS the caller's return address for cold_ret
; (stashing the real one), maps the page and `jp`s to the target. The
; target therefore sees exactly the frame its caller built -- [ret][args]
; -- and its own `ret` lands in cold_ret, which restores the window and
; jumps on to the real caller. Callee-cleans-stack targets work too: the
; callee pops its own arguments and returns into cold_ret just the same.
;
; Register-transparent: AF, BC and HL are saved and restored before the
; target runs, DE/IX/IY are never touched, and the target's own return
; registers and flags survive cold_ret.
;
; RE-ENTRANT. The saved page and return address go on cold_v_stack, three
; bytes per level, because cold-page code now calls back into the resident
; (gui.c -> text.c, the session config, the frame/key shims) and that
; resident code calls painters again through these very stubs. With single
; cells the inner call would overwrite the outer call's saved page with
; the cold page itself, and the outer restore would leave the wrong page
; mapped. Real nesting is two or three levels; COLD_SAVE_DEPTH is 6, and
; the depth guard below refuses (paints nothing) instead of walking off
; the end of the buffer.
;
; The two self-modified jump operands need no such stack: each is written
; and then consumed a few instructions later with no thunk entry in
; between, and the final `ei` delays one instruction so the jump it guards
; always executes before any interrupt can be taken.
;
; Interrupts are ON for the target call, not just at the end of it: the
; original render_core.asm routines each ended with their own EI, but
; compiled C in the page does not, and running a whole gui.c call with
; interrupts disabled would stall the frame counter. R7's real requirement
; -- the window write itself under DI -- is still honoured on both edges.
;
; cold_win3_page is #FF until asm/sprinter/buffers.asm's bench_init has
; read it out of HDR; mapping that would be catastrophic rather than
; merely wrong, so the guard below turns "no page published" into a silent
; no-op call, matching overlay_loader_sprinter.asm's own #FF check.
    defc COLD_SAVE_DEPTH = 6

cold_call:
    ld (cold_v_jp+1),hl         ; patch the tail jump to the entry slot
    di                          ; R7: the window write itself is under DI
    push bc                     ; [BC][HL][AF][ret_caller][args...]
    ld a,(cold_v_depth)
    inc a
    ld (cold_v_depth),a
    cp COLD_SAVE_DEPTH+1
    jr nc,cold_too_deep         ; refuse before writing anything

    in a,(WIN3_PORT)
    ld bc,(cold_v_sp)
    ld (bc),a                   ; +0  the page we found mapped
    inc bc
    ld hl,6
    add hl,sp                   ; -> caller's return address, low byte
    ld a,(hl)
    ld (bc),a                   ; +1  real return address, low
    inc bc
    inc hl
    ld a,(hl)
    ld (bc),a                   ; +2  real return address, high
    inc bc
    ld (cold_v_sp),bc

    ld bc,cold_ret              ; the target must return to us, not past us
    ld (hl),b
    dec hl
    ld (hl),c

    ld a,(cold_win3_page)
    inc a
    jr z,cold_no_page
    dec a
    out (WIN3_PORT),a
    pop bc
    pop hl
    pop af
    ei
cold_v_jp:
    jp 0                        ; patched above; target sees [cold_ret][args]

; Nothing published yet: return through cold_ret anyway (it unwinds the
; save entry and the depth), just without ever running the target. The
; `ret` below lands on the cold_ret we already patched into the caller's
; return slot, leaving exactly the stack cold_ret expects.
cold_no_page:
    pop bc
    pop hl
    pop af
    ei
    ret

; Refused before anything was saved, so the caller's return address is
; still its own: undo the depth and return straight to it.
cold_too_deep:
    ld a,(cold_v_depth)
    dec a
    ld (cold_v_depth),a
    pop bc
    pop hl
    pop af
    ei
    ret

; The target returned here. Stack holds whatever the target left (the
; caller's own frame); HL/AF/DE may all carry return values, so every one
; of them is preserved across the window restore.
cold_ret:
    push af
    push hl
    push bc
    di
    ld hl,(cold_v_sp)
    dec hl
    ld b,(hl)                   ; +2  real return address, high
    dec hl
    ld c,(hl)                   ; +1  real return address, low
    dec hl
    ld a,(hl)                   ; +0  the page the caller had mapped
    ld (cold_v_sp),hl
    out (WIN3_PORT),a
    ld a,(cold_v_depth)
    dec a
    ld (cold_v_depth),a
    ld (cold_v_ret+1),bc
    pop bc
    pop hl
    pop af
    ei
cold_v_ret:
    jp 0                        ; patched two instructions ago

cold_v_depth: defb 0
cold_v_stack: defs COLD_SAVE_DEPTH*3
cold_v_sp: defw cold_v_stack
"""


class ColdThunksError(Exception):
    pass


def entry_addr(index: int) -> int:
    return COLD_ENTRY_BASE + COLD_ENTRY_STRIDE * index


def parse_map(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = MAP_LINE.match(line.strip())
            if match:
                symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def render_entry_table(names: list[str]) -> str:
    """The cold-page side: a fixed `jp` per entry, at the top of the image."""
    if entry_addr(len(names)) > 0x10000:
        raise ColdThunksError("entry table does not fit in the WIN3 window")
    lines = [
        f";; {GENERATED_BANNER}",
        ";; z88dk-z80asm syntax (INCLUDEd by asm/sprinter/zcc/cold_page_crt0.asm",
        ";; immediately after `org CRT_ORG_CODE`, so slot i is at "
        f"${COLD_ENTRY_BASE:04X}+{COLD_ENTRY_STRIDE}*i).",
        "",
    ]
    for name in names:
        lines.append(f"    EXTERN _{name}")
    lines.append("")
    for index, name in enumerate(names):
        lines.append(f"    PUBLIC _cold_e_{name}")
        lines.append(f"_cold_e_{name}:            ; ${entry_addr(index):04X}")
        lines.append(f"    jp _{name}")
    lines.append("")
    return "\n".join(lines)


def render_thunks(names: list[str]) -> str:
    """The WIN1 side: one eight-byte stub per entry, plus the trampoline."""
    lines = [
        f";; {GENERATED_BANNER}",
        ";; z88dk-z80asm syntax (linked into the WIN1 resident C image "
        "alongside src/sprinter/main.c)",
        "",
        "    MODULE cold_thunks",
        "",
        "    EXTERN cold_win3_page",
        "    EXTERN WIN3_PORT",
        "",
        "    SECTION code_user",
        "",
        TRAMPOLINE,
        "; --- entry stubs (eight bytes each) --------------------------------------",
        "",
    ]
    for index, name in enumerate(names):
        lines.append(f"    PUBLIC _{name}")
        lines.append(f"_{name}:")
        lines.append("    push af")
        lines.append("    push hl")
        lines.append(f"    ld hl,${entry_addr(index):04X}   ; cold entry {index}")
        lines.append("    jp cold_call")
        lines.append("")
    return "\n".join(lines)


# How many generic stubs the z80 unit test gets. Four is enough to cover
# a plain call, a nested one, and one past the depth guard.
SJASMPLUS_TEST_STUBS = 4


def render_thunks_sjasmplus() -> str:
    """The same trampoline, in the dialect tests/sprinter/z80 speaks.

    tests/sprinter/z80/t_cold_thunk.asm runs this under z88dk-ticks, which
    is the only way to prove the parts that are runtime-only: that the
    target still finds its stack arguments where it expects them, that a
    nested call unwinds to the same state it started from, and that the
    depth guard refuses cleanly instead of walking off the save stack. A
    static test cannot see any of that, and getting it wrong crashes on
    the first frame in MAME.

    The INSTRUCTIONS come from the same TRAMPOLINE constant the real
    z80asm output uses, so the two cannot drift; only the directives
    (MODULE/SECTION/PUBLIC/EXTERN/defc, none of which sjasmplus takes in
    this form) differ, and the stubs are given generic index-named labels
    because the index -- not the symbol -- is what the ABI actually is.
    """
    body = TRAMPOLINE.replace("    defc COLD_SAVE_DEPTH = 6",
                              "COLD_SAVE_DEPTH EQU 6")
    lines = [
        f";; {GENERATED_BANNER}",
        ";; sjasmplus syntax, for tests/sprinter/z80/t_cold_thunk.asm only.",
        ";; The instruction sequence is the same string the real WIN1 stubs",
        ";; are emitted from -- see gen_sprinter_cold_thunks.py.",
        "",
        body,
        "; --- entry stubs (eight bytes each) --------------------------------------",
        "",
    ]
    for index in range(SJASMPLUS_TEST_STUBS):
        lines.append(f"cold_stub_{index}:")
        lines.append("    push af")
        lines.append("    push hl")
        lines.append(f"    ld hl,${entry_addr(index):04X}   ; cold entry {index}")
        lines.append("    jp cold_call")
        lines.append("")
    return "\n".join(lines)


def verify(symbols: dict[str, int], names: list[str]) -> None:
    """Post-link check: the built page really does place the table as promised."""
    missing = [name for name in names if f"cold_e_{name}" not in symbols]
    if missing:
        raise ColdThunksError(
            "entry-table label(s) absent from the cold page's .map (is the "
            "generated table still INCLUDEd by cold_page_crt0.asm?): "
            + ", ".join(missing)
        )
    wrong = [
        (name, symbols[f"cold_e_{name}"], entry_addr(index))
        for index, name in enumerate(names)
        if symbols[f"cold_e_{name}"] != entry_addr(index)
    ]
    if wrong:
        raise ColdThunksError(
            "entry-table slot(s) not at the address the WIN1 stubs call "
            "(something was emitted ahead of the table): "
            + ", ".join(f"{n}=${got:04X} want ${want:04X}" for n, got, want in wrong)
        )
    bodies = [
        name for name in names
        if name in symbols and not 0xC000 <= symbols[name] <= 0xFFFF
    ]
    if bodies:
        raise ColdThunksError(
            "cold-page symbol(s) outside the WIN3 window #C000-#FFFF "
            "(is the page linked at the right ORG?): "
            + ", ".join(f"{n}=${symbols[n]:04X}" for n in bodies)
        )


def _clean_fixture() -> str:
    """A synthetic cold-page .map with the same shape z88dk emits."""
    lines = []
    body = 0xD000
    for index, name in enumerate(COLD_THUNK_SYMBOLS):
        lines.append(
            f"_cold_e_{name:<26} = ${entry_addr(index):04X} ; addr, public, , "
            "sprinter_cold_page_crt0, code_user, "
            "build/sprinter/generated/cold_entry_table.inc:1\n"
        )
        lines.append(
            f"_{name:<32} = ${body:04X} ; addr, public, , "
            "asm_sprinter_zcc_render_core_asm, code_user, "
            "asm/sprinter/zcc/render_core.asm:1\n"
        )
        body += 0x20
    # A local label and a non-addr symbol, both of which must be ignored.
    lines.append(
        "i_2                              = $C100 ; addr, local, , "
        "asm_sprinter_zcc_render_core_asm, code_user, "
        "asm/sprinter/zcc/render_core.asm:1\n"
    )
    return "".join(lines)


def self_test() -> None:
    import tempfile

    table = render_entry_table(COLD_THUNK_SYMBOLS)
    thunks = render_thunks(COLD_THUNK_SYMBOLS)

    if table != render_entry_table(COLD_THUNK_SYMBOLS) or \
            thunks != render_thunks(COLD_THUNK_SYMBOLS):
        raise SystemExit("[ERR] cold-thunks self-test: rendering is not deterministic")
    if thunks.count("    jp cold_call") != len(COLD_THUNK_SYMBOLS):
        raise SystemExit("[ERR] cold-thunks self-test: wrong stub count")
    if table.count("    jp _") != len(COLD_THUNK_SYMBOLS):
        raise SystemExit("[ERR] cold-thunks self-test: wrong entry-table count")
    if "PUBLIC _render_board_full" not in thunks:
        raise SystemExit("[ERR] cold-thunks self-test: underscored name missing")
    # The two halves must agree on where entry 0 is.
    if f"ld hl,${COLD_ENTRY_BASE:04X}" not in thunks:
        raise SystemExit("[ERR] cold-thunks self-test: first stub misaddressed")
    if f"; ${COLD_ENTRY_BASE:04X}" not in table:
        raise SystemExit("[ERR] cold-thunks self-test: first entry misaddressed")

    with tempfile.TemporaryDirectory() as tmp:
        map_path = Path(tmp) / "clean.map"
        map_path.write_text(_clean_fixture(), encoding="ascii")
        symbols = parse_map(map_path)

        if "i_2" in symbols:
            raise SystemExit("[ERR] cold-thunks self-test: local label wrongly captured")
        verify(symbols, COLD_THUNK_SYMBOLS)

        shifted = dict(symbols)
        shifted["cold_e_" + COLD_THUNK_SYMBOLS[1]] += 1
        try:
            verify(shifted, COLD_THUNK_SYMBOLS)
        except ColdThunksError as exc:
            if "not at the address" not in str(exc):
                raise SystemExit(
                    "[ERR] cold-thunks self-test: wrong displaced-slot diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] cold-thunks self-test: displaced entry slot was not rejected"
            )

        dropped = {k: v for k, v in symbols.items()
                   if k != "cold_e_" + COLD_THUNK_SYMBOLS[0]}
        try:
            verify(dropped, COLD_THUNK_SYMBOLS)
        except ColdThunksError as exc:
            if COLD_THUNK_SYMBOLS[0] not in str(exc):
                raise SystemExit(
                    "[ERR] cold-thunks self-test: wrong missing-slot diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] cold-thunks self-test: missing entry slot was not rejected"
            )

        outside = dict(symbols)
        outside[COLD_THUNK_SYMBOLS[0]] = 0x7000
        try:
            verify(outside, COLD_THUNK_SYMBOLS)
        except ColdThunksError as exc:
            if "outside the WIN3 window" not in str(exc):
                raise SystemExit(
                    "[ERR] cold-thunks self-test: wrong out-of-window diagnostic"
                )
        else:
            raise SystemExit(
                "[ERR] cold-thunks self-test: non-WIN3 body was not rejected"
            )

    print("[OK] Sprinter cold-thunks self-test")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("thunks", "entry-table", "verify",
                                           "thunks-sjasmplus"))
    parser.add_argument("--map", type=Path, help="cold page .map (--mode verify)")
    parser.add_argument("--out", type=Path, help="file to write")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0

    if not args.mode:
        raise SystemExit(
            "gen_sprinter_cold_thunks: --mode is required unless --self-test"
        )

    if args.mode == "verify":
        if not args.map:
            raise SystemExit("gen_sprinter_cold_thunks: --mode verify needs --map")
        try:
            verify(parse_map(args.map), COLD_THUNK_SYMBOLS)
        except ColdThunksError as exc:
            print(f"[ERR] {args.map}: {exc}", file=sys.stderr)
            return 1
        print(f"[OK] cold entry table verified ({len(COLD_THUNK_SYMBOLS)} entries)")
        return 0

    if not args.out:
        raise SystemExit("gen_sprinter_cold_thunks: --out is required")
    if args.mode == "thunks":
        text = render_thunks(COLD_THUNK_SYMBOLS)
    elif args.mode == "thunks-sjasmplus":
        text = render_thunks_sjasmplus()
    else:
        text = render_entry_table(COLD_THUNK_SYMBOLS)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding="ascii")
    print(f"[OK] {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
