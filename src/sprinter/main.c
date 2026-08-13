/* Resident C image entry point (port.md section 3.10/S5, plan D1).
 *
 * PLACEHOLDER pending the real port: substep 4 replaces this with the
 * actual Shatranj app (hot-seat integration, session/transport wiring).
 * What this file proves right now: trampoline.asm hands off to
 * resident_crt0.asm's start, which zeroes BSS and calls this main(), which
 * calls back into platform_primitives.asm through gen_sprinter_platform_
 * defs.py's generated addresses, dispatches one real overlay (S5 substep
 * 2, CONTROL/SPECTRUM_OVL_CONTROL=14u) through overlay_loader_sprinter.asm,
 * signalling the result via ovl_test_signal's background-palette trick
 * (green/red hud_success/hud_error -- see docs/sprinter-testnotes/S5.md),
 * and (S5 substep 3b) dispatches RULES(0)/BOARD(1) for real -- board.c is
 * now linked into the resident, spectrum_board_reset() sets up the real
 * starting position, and a scripted e2e4 probe exercises is_legal_move
 * (RULES_PLAY), an illegal-move negative check, apply_trusted_move
 * (BOARD_APPLY), and the resulting cell contents end to end, folded into
 * the same green/red signal as the CONTROL probe below. Hints (RULES
 * entries 2/3) are not ported yet -- see rules_stub_sprinter.asm's own
 * header for why. (S5 substep 3) paints the board via render_core.asm's
 * render_board_full, reading src/spectrum/lowram_map.h's cross-platform
 * NETCHESSZX_LOWRAM_CHESS_BOARD buffer, plus a-h/1-8
 * coordinate labels (render_coord_labels), an RTC HH:MM status-bar clock
 * (render_status_clock), and the rest of the static HUD chrome --
 * banner title + logo (render_banner), the menu-tab row (render_menu_
 * bar), a status-bar connection placeholder (render_status_text), and
 * the input-line prompt (render_input_line) -- before clearing ovl_
 * test_signal's diagnostic background tint back to black. The frame loop
 * polls the keyboard every tick (key_poll); board_cursor_move (S5 substep
 * 3) moves a whole-cell frame cursor around the board on the four arrow
 * codes, and board_select_or_move (S5 substep 3c) picks up/drops pieces
 * with SPACE through the real RULES/BOARD overlays -- hot-seat play, both
 * sides at one keyboard.
 *
 * S5-finish, plan D8: src/spectrum/ui/gui.c (the portable UI-state layer
 * ZX/Next's app.c already uses -- clocks/timers, notices, the menu-focus
 * state, the FLIP flag, the move-list/chat buffers) is linked in
 * unmodified, with render_core.asm implementing its spectrum_render_*
 * call-out surface (that file's own "gui.c integration surface" section).
 * app.c itself is NOT linked -- it is inseparable from saveload/fileui/
 * restore/session/transport (S6-S8), while gui.c touches no screen memory
 * and no transport at all. This main() now calls gui.c's own game-start
 * sequence (spectrum_gui_game_timer_start/set_status/set_turn_label,
 * app.c's game_start_state minus everything session-shaped) once at boot,
 * feeds gui.c's wall clock from the local RTC once a second (Sprinter has
 * one; ZX/Next feed the same API from MQTT SYNC_TIME instead), ticks
 * gui.c every frame (GAME/TURN timers, the notice-line countdown), and
 * raises real notices ("Empty square"/"Not your piece"/"Bad move") from
 * board_select_or_move's own illegal-move/wrong-side paths -- closing
 * P13's "an illegal move does nothing at all, and there is no notice line
 * yet" gap.
 *
 * S5-finish plan D12: the move-list panel (GUI_LOG(2) scope) is now real
 * (src/sprinter/gui_log_sprinter.c, this port's own replacement for ZX's
 * ported overlay -- see that file's header), and the menu bar is
 * interactive (TAB opens it, LEFT/RIGHT/ENTER navigate and activate,
 * gui.c's own spectrum_gui_handle_menu_key -- see the frame loop and
 * handle_menu_action below). RESET, THEME and (real FLIP, added after
 * P17) are real menu actions; FILE/DISCONNECT/ABOUT are honest "not
 * available" stubs (S6/S7/S9 scope). The chat panel is a static
 * placeholder line (_spectrum_info_show_game, render_core.asm) -- no
 * INPUT_EDIT, no network, nothing to show yet. See docs/sprinter-
 * testnotes/S5.md for the full checkpoint history.
 */

#include "spectrum/session/event.h"
#include "spectrum/board/board.h"
#include "spectrum/overlay/overlay_context.h"
#include "common/chess/rules_compact.h"
#include "spectrum/ui/gui.h"
#include "spectrum/ui/info_panel.h"
#include "spectrum/saveload/saveload.h"
#include "spectrum/restore/restore.h"
#include "spectrum/fileui/fileui.h"

#include <string.h>

/* gui.c (S5-finish, plan D8) is linked in unmodified -- both render.h
   above's spectrum_render_* declarations and gui.h's own spectrum_gui_*
   ones are compiled by this same zcc invocation, so the calling
   convention on both sides of every gui.c<->main.c/render_core.asm call
   is settled by the compiler consistently; no hand-verification needed
   for gui.h's own API the way render_core.asm's asm-side entry points
   needed disassembly (see that file's own "gui.c integration surface"
   section for what was actually checked and one real bug it caught). */

extern void im2_install(void);
extern void video_init(void);
extern void bench_init(void);
/* S5-finish plan D11 (buffer flip): resolve_buffers() reads PORT_RGMOD
   once and publishes front_base/back_base (buffers.asm) -- must run
   before ANY render_*() call below, since render_cursor_marker() (and
   every routine migrated to the flip-aware single-pass paint, F0/F1) now
   reads back_base as its paint target instead of a hardcoded VRAM_BUF0/1
   pair. flip_ring_reset() starts the dirty-rect ring clean right after,
   before the boot paint sequence logs anything into it. */
extern void resolve_buffers(void);
extern void flip_ring_reset(void);
/* S5-finish plan D11 fix (2026-08-11, human tester's first P15 MAME run):
   this port never actually cleared VRAM pixel content anywhere -- only
   clear_bg_signal's palette-index-0 recolour -- relying on whichever
   buffer DSS/BIOS happened to leave clean already being the one buffer
   ever displayed (true before this port had a working flip, silently
   false the moment PORT_RGMOD can actually toggle to the other one).
   Must run before resolve_buffers()/flip_ring_reset() below. */
extern void video_clear_both_buffers(void);
extern unsigned char frame_wait(void);
extern unsigned char ovl_exec(unsigned char ovl_id, unsigned char entry_id);
extern void ovl_test_signal(unsigned char pass);
extern void clear_bg_signal(void);
extern void render_board_full(void);
extern void render_coord_labels(void);
extern void render_status_clock(void);
extern void render_banner(void);
extern void render_menu_bar(void);
extern void render_status_text(void);
extern void render_input_line(void);
extern void key_poll(void);
extern void render_input_key_echo(void);
extern void render_cursor_marker(void);
extern void render_select_marker(void);
/* __z88dk_fastcall, spelled out rather than left to the classic default:
   render_square_marked reads its argument from L, and a plain declaration
   makes sccz80 push it on the stack instead. That compiled and even
   worked, purely because sccz80 happens to leave the value in HL right
   before the push -- the same "it works by accident until it doesn't"
   shape as this port's first two ABI bugs (overlay_loader_sprinter.asm's
   SP+2 decode, the ovl_ctx address split). Checked in the disassembly:
   the call site must be `ld l,<index>` + `call`, with nothing pushed. */
extern void render_square_marked(unsigned char index) __z88dk_fastcall;
extern void board_cursor_move(void);

/* S5-finish plan D12 (menu actions): spectrum_gui_reset_move_log is this
   port's own addition (src/sprinter/gui_log_sprinter.c), not part of
   gui.h's portable contract -- see that file's own header for why this
   port does not link ZX's GUI_LOG overlay. theme_set_squares is video.asm
   (bridged like every other platform_core primitive, see gen_sprinter_
   platform_defs.py) -- a palette rewrite, not a redraw (that file's own
   theme_set_squares comment). */
extern void spectrum_gui_reset_move_log(void);
extern void theme_set_squares(unsigned char index);

/* S6 (save/load + file browser, port.md section 5): gui_log_sprinter.c's
   own move-count is the true ply source (that file's own header) -- these
   two are Sprinter-native additions to it, not part of gui.h's portable
   contract, same reasoning as spectrum_gui_reset_move_log above. */
extern uint16_t spectrum_gui_log_ply_get(void);
extern void spectrum_gui_log_ply_set(uint16_t ply);

/* dss_fileio.asm (asm/sprinter/dss_fileio.asm, S6 plan step 1): resolves
   the save directory once from DSS AppInfo (saves live next to the EXE).
   Must run before any esx_fopen/esx_fcreate/esx_opendir path built from
   spectrum_platform_save_dir()'s result -- called once at boot, below. */
extern void spectrum_platform_save_dir_init(void);
extern const char *spectrum_platform_save_dir(void);
/* S6 round 5: the raw DSS error number (dss_errors.z80's own numbering,
   e.g. 24 = write protected, 10 = no free space) behind the last esx_*
   call that failed, pre-formatted as decimal ASCIIZ in asm (dss_fileio.
   asm's own comment on why: a C-side tens/ones loop alone overran the
   resident C image's 113-byte headroom by 79 bytes). */
extern const char *spectrum_platform_last_dss_error_text(void);

/* RTC bridge (video.asm, gen_sprinter_platform_defs.py) -- render_status_
   clock's own boot-time snapshot (above) already declares these as asm
   EXTERNs internally; this is the first C consumer, feeding gui.c's
   portable clock (spectrum_gui_set_clock) once a second (S5-finish step
   1) instead of the ZX-only MQTT SYNC_TIME path gui.c was written
   against -- Sprinter has a local RTC ZX/Next don't, so this is a
   Sprinter-specific wall-clock source, not a ported behaviour. */
extern void rtc_sample(void);
extern unsigned char rtc_valid;
extern unsigned char rtc_hour;
extern unsigned char rtc_minute;
extern unsigned char rtc_second;
static unsigned char rtc_tick_counter;

/* Board cursor / selection state, defined in render_core.asm (see the
   comment on selected_row there): the renderer owns the cells because the
   asm cursor mover and the frame painters both read them, this file owns
   the selection *policy*, exactly as ZX splits app.c from screen.asm. */
extern unsigned char cursor_row;
extern unsigned char cursor_col;
extern unsigned char selected_row;
extern unsigned char selected_col;
extern unsigned char key_code;

#define NO_SQUARE 0xFFu
#define KEY_SELECT 32u          /* space -- app.c's own select/move key */

/* SPECTRUM_OVL_CTX_PTR_LO/HI (src/spectrum/overlay/overlay_context.h):
   control_classify_ovl reads a 2-byte little-endian pointer to the ASCIIZ
   payload from spectrum_overlay_context[0..1]. "MOVE e2e4" must classify as
   exactly NETCHESSZX_SESSION_EVENT_MOVE.

   Written through the portable `spectrum_overlay_context` macro, not
   through overlay_loader_sprinter.asm's own `ovl_ctx` name: they are the
   same 8 bytes (LOWRAM_OVERLAY_CONTEXT, #B32F) and must stay so, but using
   the portable name here is what keeps that true by construction. Writing
   through the loader's private name is exactly what hid the P12 context
   mismatch until the first MAME run -- board.c, the first caller to use
   the portable name, then found a different buffer than the loader passed
   to the overlay (see that file's own ovl_ctx comment). */
static const char ovl_test_payload[] = "MOVE e2e4";
unsigned char ovl_test_result;

/* Boot-time scripted probe for RULES(0)/BOARD(1) (S5 substep 3b), same
   shape as the CONTROL classify probe above: one known move exercised
   through the real dispatch path, checked, folded into the same green/red
   signal -- not a general test harness, just enough to prove is_legal_move
   (RULES_PLAY), an illegal move correctly rejected, apply_trusted_move
   (BOARD_APPLY), and the resulting board state all work end to end before
   anything on screen depends on them. e2e4 is an arbitrary legal opening
   pawn push; e2e5 (three squares) is deliberately illegal as a negative
   check -- a rules stub that always returns "legal" would pass the first
   assertion and fail this one. */
static unsigned char board_ovl_probe(void) {
    unsigned char ok;

    ok = (unsigned char)(spectrum_board_is_legal_move("e2e4") != 0u);
    ok = (unsigned char)(ok && spectrum_board_is_legal_move("e2e5") == 0u);
    ok = (unsigned char)(ok && spectrum_board_apply_trusted_move("e2e4") != 0u);
    ok = (unsigned char)(ok && spectrum_board_cell(4u, 4u) == 'P');
    ok = (unsigned char)(ok && spectrum_board_cell(6u, 4u) == '.');
    return ok;
}

/* Hot-seat pick-up/drop, ported from app.c's cursor_select_or_move
   (src/spectrum/app/app.c) with everything session-shaped removed: no
   peer, no local-side ownership, no pending-ply gate, because on Sprinter
   there is no session yet (S7) and both sides are played at the same
   keyboard. What is kept is exactly ZX's square-picking behaviour:

     - nothing selected: SPACE on an empty square or on a piece that is
       not the side to move does nothing (ZX shows an "Empty e4" / "You
       play white" notice; this port has no notice line yet, so the press
       is simply ignored -- a visible notice is later substep-3 work);
     - SPACE on the selected square itself cancels the selection;
     - SPACE on another of your own pieces moves the selection there,
       rather than attempting a self-capture (app.c:1764's branch);
     - otherwise the move is offered to RULES; illegal moves keep the
       selection so the player can pick another target, matching ZX's
       LOCAL_MOVE_REJECTED path;
     - a pawn reaching the last rank auto-promotes to a queen, which is
       what app.c's send_move does in cursor mode (app.c:1786).

   side_to_move is board.c's own global, flipped by apply_trusted_move --
   so "whose turn" needs no state of its own here, and hot-seat is simply
   not filtering by local side. */
extern unsigned char side_to_move;

static unsigned char square_index(unsigned char row, unsigned char col) {
    return (unsigned char)((row << 3) + col);
}

static unsigned char piece_is_side_to_move(char piece) {
    if (piece == '.') {
        return 0u;
    }
    if (piece >= 'a') {
        return (unsigned char)(side_to_move == NETCHESSZX_RULE_BLACK);
    }
    return (unsigned char)(side_to_move == NETCHESSZX_RULE_WHITE);
}

static void selection_clear(void) {
    unsigned char row = selected_row;
    unsigned char col = selected_col;

    if (row == NO_SQUARE) {
        return;
    }
    selected_row = NO_SQUARE;
    selected_col = NO_SQUARE;
    render_square_marked(square_index(row, col));
}

static void selection_set(unsigned char row, unsigned char col) {
    selection_clear();
    selected_row = row;
    selected_col = col;
    render_square_marked(square_index(row, col));
}

static void board_select_or_move(void) {
    char move[6];
    char piece;

    if (key_code != KEY_SELECT) {
        return;
    }
    key_code = 0u;              /* read-and-clear, like board_cursor_move */

    piece = spectrum_board_cell(cursor_row, cursor_col);

    if (selected_row == NO_SQUARE) {
        if (!piece_is_side_to_move(piece)) {
            /* S5-finish step 1: this port's first notice line (closes
               P13's own "an illegal move does nothing at all, and there
               is no notice line yet" gap). Two fixed, honest messages
               rather than ZX's dynamic "Empty e4"/"You play white" square-
               naming text -- info-severity (auto-expires), matching
               notify_internal's own ticks=250 info default. */
            spectrum_gui_notify(piece == '.' ? "Empty square" : "Not your piece", 0u);
            return;
        }
        selection_set(cursor_row, cursor_col);
        return;
    }

    if (selected_row == cursor_row && selected_col == cursor_col) {
        selection_clear();
        return;
    }

    if (piece_is_side_to_move(piece)) {
        selection_set(cursor_row, cursor_col);
        return;
    }

    move[0] = (char)('a' + selected_col);
    move[1] = (char)('8' - selected_row);
    move[2] = (char)('a' + cursor_col);
    move[3] = (char)('8' - cursor_row);
    move[4] = '\0';
    piece = spectrum_board_cell(selected_row, selected_col);
    if ((piece == 'P' && cursor_row == 0u) ||
        (piece == 'p' && cursor_row == 7u)) {
        move[4] = 'q';
        move[5] = '\0';
    }

    if (!spectrum_board_is_legal_move(move)) {
        /* "Bad move" is ZX's own literal (NETCHESSZX_UI_SPECTRUM_ERROR_
           MOVE_REJECTED, src/common/ui_messages.h) -- reused verbatim
           here, not invented, since it needs no square-name interpolation.
           Error severity: notify_internal makes this persistent until
           replaced, unlike the info notices above. */
        spectrum_gui_notify("Bad move", 1u);
        return;                 /* keep the selection: pick another target */
    }
    if (!spectrum_board_apply_trusted_move(move)) {
        spectrum_gui_notify("Bad move", 1u);
        return;
    }

    {
        unsigned char from = square_index(selected_row, selected_col);
        unsigned char to = square_index(cursor_row, cursor_col);

        selected_row = NO_SQUARE;
        selected_col = NO_SQUARE;
        render_square_marked(from);
        render_square_marked(to);
        /* side_to_move (board.c) has already flipped inside apply_
           trusted_move -- this reflects the NEW side to move, matching
           ZX's own turn_set_notice call right after a move lands.
           Check-state variants (SPECTRUM_GUI_TURN_*_CHECK) are not driven
           yet -- check detection isn't wired to this path (S5-finish
           scope); WHITE/BLACK only for now. */
        spectrum_gui_move_timer_reset();
        spectrum_gui_set_turn_label(side_to_move == NETCHESSZX_RULE_WHITE
                                         ? SPECTRUM_GUI_TURN_WHITE
                                         : SPECTRUM_GUI_TURN_BLACK);

        /* A prior "Bad move"/"Empty square"/etc is error-severity
           (notify_internal, gui.c) and therefore persistent until
           explicitly replaced -- it does not auto-expire, and nothing
           above touches the notice line on a SUCCESSFUL move, so it was
           staying on screen through however many further legal moves
           followed (human tester, 2026-08-12: "подсказка не исчезает
           после правильного хода"). ZX's own send_local_move (app.c)
           replaces it immediately with the move just made
           (spectrum_gui_notify_persistent(SAN)) -- this is that same
           call, using the plain coordinate move string already computed
           above instead of SAN (app.c's move_san_or_fallback is not
           linked here, same reasoning as this file's own "Empty square"/
           "Not your piece" literals over ZX's dynamic square-naming
           text). */
        spectrum_gui_notify_persistent(move);

        /* S5-finish plan D12 (GUI_LOG(2) scope): append the move just made
           to the move-list panel -- src/sprinter/gui_log_sprinter.c's own
           ply counter tracks white/black from call order alone, so no ply
           string is needed here (see that file's own header). */
        spectrum_gui_add_move("", move);
    }
}

/* --- save/load (S6, port.md section 5) ------------------------------------
 *
 * Hot-seat equivalent of src/spectrum/app/app.c's local_save_game/
 * saveload_apply_snapshot/local_load_game, with everything session-shaped
 * removed (D8: no app.c, no session/network on Sprinter): no host-only
 * gate (local_load_game's own `netchesszx_session_is_host()` check), no
 * host_color round-trip check, no peer RESTORE_TX wire-chunking branch --
 * a load either applies directly or fails outright, matching every other
 * ZX/Next platform's own local (offline) fallback path.
 *
 * host_color is meaningless without a session (there is no host/peer),
 * hardcoded to NETCHESSZX_SAVE_HOST_WHITE on save and ignored on load.
 * game_over/check-state tracking does not exist yet on Sprinter (no
 * checkmate/stalemate detection wired to board_select_or_move) -- flags
 * always report ACTIVE, plus CHECK from spectrum_board_check_state() (a
 * real, if narrow, signal already available cheaply). Timers are zeroed on
 * save and never read back on load (spectrum_gui_game_timer_start/
 * move_timer_reset restart them from zero instead) -- ZX's own app.c does
 * exactly this (local_save_game's own memset(meta.timers, ...)), not a
 * Sprinter shortcut.
 */
static spectrum_board_snapshot_t saveload_snapshot;
static char saveload_b64_pending[NETCHESSZX_SAVE_WIRE_B64_SIZE];

static unsigned char saveload_flags(void) {
    unsigned char flags = NETCHESSZX_SAVE_FLAG_ACTIVE;

    if (spectrum_board_check_state() == SPECTRUM_BOARD_CHECK) {
        flags |= NETCHESSZX_SAVE_FLAG_CHECK;
    }
    return flags;
}

/* S6 round 5 (docs/sprinter-testnotes/S6.md "MAME round 5"): the tester's
 * next report was the generic "Save failed" text, which does not say
 * whether saveload_ovl.c's own path build rejected the name, esx_fcreate
 * couldn't open the file, or esx_fwrite/esx_fclose failed against the
 * actual media -- round 4's static audit explicitly could not tell those
 * apart without a live run. saveload_ovl.c already leaves the specific
 * SPECTRUM_OVL_CTX_SAVELOAD_RESULT code (overlay_context.h) in the shared
 * context; surfacing it costs nothing extra (spectrum_overlay_context is
 * already read directly elsewhere in this file) and turns the next
 * screenshot into an answer instead of another guess.
 */
static const char *saveload_result_code_text(unsigned char code) {
    if (code == SPECTRUM_OVL_SAVELOAD_ERR_NAME) {
        return "NAME";
    }
    if (code == SPECTRUM_OVL_SAVELOAD_ERR_OPEN) {
        return "OPEN";
    }
    if (code == SPECTRUM_OVL_SAVELOAD_ERR_IO) {
        return "IO";
    }
    if (code == SPECTRUM_OVL_SAVELOAD_ERR_DATA) {
        return "DATA";
    }
    return "?";
}

static void saveload_notify_failed(const char *prefix, unsigned char code) {
    static char msg[24];
    char *q = msg;
    const char *p;
    const char *reason = saveload_result_code_text(code);

    for (p = prefix; *p; ++p) {
        *q++ = *p;
    }
    *q++ = ':';
    for (p = reason; *p; ++p) {
        *q++ = *p;
    }
    /* S6 round 5: NAME/OPEN/IO come from an esx_* call that could have hit
       dfio_dss's RST -- append the raw DSS error number too
       (dss_errors.z80's own numbering, e.g. 24 = write protected, 10 = no
       free space) so a code alone doesn't force yet another guessing
       round. NAME/DATA never reach dfio_dss (local checks only), so the
       number would be stale there -- skip it. Formatting itself lives in
       dss_fileio.asm (spectrum_platform_last_dss_error_text's own
       comment) -- this is a plain char copy, no arithmetic here. */
    if (code == SPECTRUM_OVL_SAVELOAD_ERR_OPEN ||
        code == SPECTRUM_OVL_SAVELOAD_ERR_IO) {
        *q++ = ':';
        for (p = spectrum_platform_last_dss_error_text(); *p; ++p) {
            *q++ = *p;
        }
    }
    *q = '\0';
    spectrum_gui_notify(msg, 1u);
}

static void local_save_game(const char *name) {
    netchesszx_save_meta_t meta;

    spectrum_board_snapshot_save(&saveload_snapshot);
    meta.ply = spectrum_gui_log_ply_get();
    meta.flags = saveload_flags();
    meta.host_color = NETCHESSZX_SAVE_HOST_WHITE;
    meta.view_flags = spectrum_gui_is_board_flipped()
        ? NETCHESSZX_SAVE_VIEW_FLIPPED
        : 0u;
    memset(meta.timers, 0, sizeof(meta.timers));
    if (!spectrum_restore_build_b64(&saveload_snapshot, &meta,
                                    saveload_b64_pending)) {
        spectrum_gui_notify("Save failed:ENCODE", 1u);
        return;
    }
    if (spectrum_saveload_write(name, saveload_b64_pending)) {
        spectrum_gui_notify_success("Saved");
        return;
    }
    saveload_notify_failed("Save failed",
        spectrum_overlay_context[SPECTRUM_OVL_CTX_SAVELOAD_RESULT]);
}

/* Full post-load repaint: same board-area sequence menu_flip_board/
   menu_reset_game already use (render_board_full/render_coord_labels plus
   the selection/cursor markers) -- this port's own proven, MAME-tested
   redraw, not gui.c's spec-based path (see menu_flip_board's own comment
   for why that one has no live caller here). Also erases whatever the
   FILEUI panel painted over the board area (S6 plan step 4) -- a full
   repaint of that same screen region is a correct "close" for either
   reason, load or plain cancel. */
static void saveload_full_redraw(void) {
    render_board_full();
    render_coord_labels();
    render_select_marker();
    render_cursor_marker();
}

static void local_load_game(const char *name) {
    netchesszx_save_meta_t meta;

    /* S6 round 5: distinguish the two DoD failure modes instead of one
       generic message (same reasoning as local_save_game's own
       saveload_notify_failed) -- a missing/unreadable file (esx_fopen/
       esx_fread failure, specific code from SPECTRUM_OVL_CTX_SAVELOAD_
       RESULT) versus a corrupt one (CRC/version/board-shape rejected by
       restore_unpack_wire, which never sets that context code at all). */
    if (!spectrum_saveload_read(name, saveload_b64_pending)) {
        saveload_notify_failed("Load failed",
            spectrum_overlay_context[SPECTRUM_OVL_CTX_SAVELOAD_RESULT]);
        return;
    }
    if (!spectrum_restore_decode(saveload_b64_pending, &saveload_snapshot,
                                 &meta)) {
        spectrum_gui_notify("Load failed:DATA", 1u);
        return;
    }
    spectrum_board_snapshot_restore(&saveload_snapshot);
    spectrum_gui_set_board_view((unsigned char)
        (meta.view_flags & NETCHESSZX_SAVE_VIEW_FLIPPED));
    selected_row = NO_SQUARE;
    selected_col = NO_SQUARE;
    saveload_full_redraw();
    spectrum_gui_reset_move_log();
    spectrum_gui_log_ply_set(meta.ply);
    spectrum_gui_game_timer_start();
    spectrum_gui_move_timer_reset();
    spectrum_gui_set_turn_label(side_to_move == NETCHESSZX_RULE_WHITE
                                     ? SPECTRUM_GUI_TURN_WHITE
                                     : SPECTRUM_GUI_TURN_BLACK);
    spectrum_gui_notify_success("Loaded");
}

/* --- file browser (S6 plan step 4) -----------------------------------------
 *
 * Hot-seat equivalent of app.c's fileui_open/fileui_process_key: no
 * NETCHESSZX_NEXT_BANKING sprite-hide branch (Sprinter has no such
 * concept), no suppress_current_key() (this port's frame loop already
 * zeroes key_code itself whenever spectrum_gui_handle_menu_key/the fileui-
 * visible check below consumes a press -- see the frame loop's own
 * comment).
 */
#define FILEUI_CLOSE_KEY 0x8au   /* cancel -- im2_s1.asm's key_poll */

static void fileui_open(void) {
    spectrum_gui_clear_cursor_coords();
    spectrum_gui_show_fileui();
    if (!spectrum_fileui_open_render()) {
        spectrum_gui_restore_board_area();
        saveload_full_redraw();
        spectrum_gui_notify("File browser failed", 1u);
    }
}

static void fileui_close(void) {
    spectrum_gui_restore_board_area();
    saveload_full_redraw();
}

static void fileui_process_key(unsigned char key) {
    unsigned char action;

    if (key == 0u) {
        return;
    }
    if (key == FILEUI_CLOSE_KEY || key == SPECTRUM_GUI_KEY_MENU_FILE ||
        key == SPECTRUM_GUI_KEY_MENU) {
        fileui_close();
        return;
    }
    action = spectrum_fileui_send_key(key);
    if (action == SPECTRUM_FILEUI_ACT_LOAD) {
        fileui_close();
        local_load_game(spectrum_fileui_selected_name());
    } else if (action == SPECTRUM_FILEUI_ACT_SAVE) {
        local_save_game(spectrum_fileui_selected_name());
        spectrum_fileui_rerender();
    } else if (action == SPECTRUM_FILEUI_ACT_ERASE) {
        spectrum_saveload_erase(spectrum_fileui_selected_name());
        spectrum_fileui_rerender();
    }
}

/* --- menu actions (S5-finish, plan D12) -----------------------------------
 *
 * spectrum_gui_handle_menu_key (gui.c, portable) already owns menu open/
 * close and left/right tab focus navigation -- see this file's own frame
 * loop below for how its return value is dispatched. What follows is this
 * port's OWN implementation of what each tab actually DOES once ENTER/
 * SPACE activates it, since app.c (which owns that logic on ZX/Next) is
 * not linked here (D8). RESET, THEME and FLIP are real; FILE/DISCONNECT/
 * ABOUT are honest "not available" stubs -- they belong to S6 (save/load),
 * S7 (network) and S9 (About screen) respectively, none of which exist
 * yet.
 */
static unsigned char menu_theme_index;

static void menu_reset_game(void) {
    spectrum_board_reset();
    render_board_full();
    selected_row = NO_SQUARE;
    selected_col = NO_SQUARE;
    render_cursor_marker();
    spectrum_gui_reset_move_log();
    spectrum_gui_game_timer_start();
    spectrum_gui_set_turn_label(SPECTRUM_GUI_TURN_WHITE);
    spectrum_gui_notify_persistent("New game");
}

static void menu_cycle_theme(void) {
    ++menu_theme_index;
    theme_set_squares(menu_theme_index);
}

/* Real board flip, added after P17 originally shipped FLIP as an honest
 * stub: draw_square_into (render_core.asm) used to look up board content
 * AND compute screen position from the same row/col, so painting at a
 * flipped position would have silently read the WRONG cell's content the
 * moment the flip flag ever became true -- a refactor of the single most
 * heavily-relied-on rendering path in this port (every square repaint,
 * P0-P16), correctly descoped out of the P17 batch rather than shipped
 * half-correct. draw_square_into now keeps its existing row/col argument
 * as MODEL coordinates for content (unchanged, every existing caller needed
 * zero changes) and derives a separate DISPLAY row/col internally for
 * position only, read from spectrum_gui_board_flipped -- gui.c's own
 * portable flip flag, the same one board_cursor_move and render_coord_
 * labels (render_core.asm) now also read directly, so there is exactly one
 * flip flag in this whole port, not a Sprinter-local duplicate of gui.c's.
 *
 * spectrum_gui_set_board_view, not spectrum_gui_toggle_board_view: the
 * latter also calls gui.c's own spectrum_gui_redraw_board_view(), which
 * repaints through gui.c's spec-based square contract (spectrum_render_
 * square/_with_hint -- render_core.asm's gui_square_from_spec). That path
 * has no live caller on Sprinter today (app.c, gui.c's only other caller
 * of it, is not linked here, D8) and was never made flip-aware -- fixing
 * dead code is out of scope for this pass. The repaint below instead reuses
 * this port's own proven, MAME-tested board-paint routines (the same
 * render_board_full/render_select_marker/render_cursor_marker sequence
 * _spectrum_render_board already uses); render_board_full needed no
 * changes of its own to render correctly flipped, since draw_square_into's
 * flip transform is internal to it. cursor_row/col and selected_row/col
 * are left untouched -- flipping does not change which model square is
 * selected/highlighted, only where on screen it is painted. */
static void menu_flip_board(void) {
    spectrum_gui_set_board_view((unsigned char)!spectrum_gui_is_board_flipped());
    render_board_full();
    render_coord_labels();
    render_select_marker();
    render_cursor_marker();
}

static void menu_not_available(void) {
    spectrum_gui_notify("Not available", 0u);
}

static void handle_menu_action(unsigned char action) {
    if (action == SPECTRUM_GUI_KEY_MENU_REST) {
        menu_reset_game();
    } else if (action == SPECTRUM_GUI_KEY_MENU_THEME) {
        menu_cycle_theme();
    } else if (action == SPECTRUM_GUI_KEY_MENU_FLIP) {
        menu_flip_board();
    } else if (action == SPECTRUM_GUI_KEY_MENU_FILE) {
        fileui_open();
    } else if (action == SPECTRUM_GUI_KEY_MENU_DISCC ||
               action == SPECTRUM_GUI_KEY_MENU_ABOUT) {
        menu_not_available();
    }
}

void main(void) {
    unsigned char pass;

    bench_init();
    video_init();
    video_clear_both_buffers();
    resolve_buffers();
    flip_ring_reset();

    /* S6: resolve the save directory once, before the first possible
       esx_fopen/esx_fcreate/esx_opendir call (any of which could in
       principle happen as soon as the frame loop starts handling menu
       keys) -- asm/sprinter/dss_fileio.asm's own comment on why this is a
       one-time boot call outside the dfio_dss WIN3-remap funnel. */
    spectrum_platform_save_dir_init();

    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_LO] =
        (unsigned char)((unsigned int)ovl_test_payload & 0xFFu);
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_HI] =
        (unsigned char)((unsigned int)ovl_test_payload >> 8);
    ovl_test_result = ovl_exec(14u, 0u);

    pass = (unsigned char)(ovl_test_result == (unsigned char)NETCHESSZX_SESSION_EVENT_MOVE);

    spectrum_board_reset();
    pass = (unsigned char)(pass && board_ovl_probe());
    ovl_test_signal(pass);

    /* The probe left its own e2e4 on the board. Reset again so the game
       actually starts from the start position now that moves can be made
       by hand (S5 substep 3c): P12's "the pawn is visibly on e4" was the
       right evidence while nothing else could move a piece, but keeping a
       scripted opening move on the board would now just be a wrong
       position to play from. The probe still runs, and still decides the
       green/red boot signal -- only its side effect is undone. */
    spectrum_board_reset();

    render_board_full();
    render_coord_labels();
    render_status_clock();
    render_banner();
    render_menu_bar();
    render_status_text();
    render_input_line();
    render_cursor_marker();

    /* S5-finish plan D11: render_cursor_marker() is the first migrated
       (single-pass, back_base-only) paint in this port's life, called
       before the frame loop below has ever flipped -- the cursor frame
       therefore sits only in the currently-hidden buffer until the
       loop's first frame_wait() call requests and confirms a flip. This
       is deliberately NOT special-cased with an extra flip_ring_reset()
       here: the boot painters above (still two-pass, but routed through
       the same shared VRAM-writing primitives) already log far more than
       the 16-entry ring holds, so flip_dirty_all is already set by this
       point, and dropping it here would strand the cursor's paint in the
       hidden buffer with nothing left to trigger the flip that reveals
       it. Letting the first frame_wait() do the one-time sync (~one
       frame, imperceptible) is simpler and correct; see buffers.asm's
       flip_ring_reset comment for the two places state IS legitimately
       dropped (right after resolve_buffers() above, and at the end of a
       completed flip_sync). */

    /* Every render_*() call above must run before clear_bg_signal() below,
       not just after: their text/label boxes paint with palette index 0
       (bg) so they blend into whatever the background is once clear_bg_
       signal restores it to black (render_core.asm's own COORD_COLOR/
       STATUS_COLOR/BANNER_COLOR/MENU_COLOR/STATUS_TEXT_COLOR/INPUT_COLOR
       comments). Swapping this order would leave the boxes stuck on the
       diagnostic tint. render_cursor_marker() does not itself depend on
       this order (it is hardware-keyed, not a bg=0 box), but it does need
       to run after render_board_full() so the cell it overlays already
       has real content -- grouped with the rest of the boot paint here
       for that reason, not the bg-blend one. */

    /* ovl_test_signal's green/red background tint (above) was diagnostic
       scaffolding for S5 substep 2, before there was any real content on
       screen to look at (docs/sprinter-testnotes/S5.md, P0/P1). Now that
       the board and coordinate labels have painted (P2/P3), that same
       proof is visible in the actual game content, so the tint is
       cleared back to the real black background here -- matching
       video.asm's own ovl_test_signal comment ("S5 substep 3's render.c
       replaces this with real board/panel painting ... not this palette
       trick"). The diagnostic still ran and was visible for the ~74ms+
       spent painting the board/labels above; only the steady-state
       screen changes here. */
    clear_bg_signal();

    /* im2_install() deferred to here (2026-08-10, S5 substep 3 crash
       investigation): frame_flag/canary_check have no consumer before
       frame_wait()'s first call below, so nothing before this point needs
       IM2 armed. Doing so means the one-shot CONTROL dispatch and the
       ~74ms board paint above both run under DSS's own default interrupt
       mode instead of interleaving with our IM2 stub for the first time
       ever in this port's life -- render_board_full is the first code
       here that runs long enough to take a real frame tick mid-flight
       (several 20ms periods), a combination S1-S4's stand never exercised
       this early after boot. Not confirmed as the crash's exact mechanism
       (see port.md/docs/sprinter-testnotes/S5.md, 2026-08-10), but this
       removes the whole class of "interrupt lands between two back-to-
       back accelerated draws" risk from the one part of main() that is
       new and unproven, at zero cost -- nothing here needs a frame tick
       yet. */
    im2_install();

    /* S5-finish step 1: gui.c integration (plan D8) -- the hot-seat
       equivalent of app.c's game_start_state (app.c:1435-1456), stripped
       of everything session-shaped the same way board_select_or_move
       above already is: no board-view flip yet (Step 3), no real
       connection/session state to report (S7), no piece-reveal animation.
       side_to_move is WHITE right after spectrum_board_reset() above, so
       this is the correct boot state, not a guess. spectrum_gui_set_
       status("HOT SEAT") overwrites render_status_text's own "NO SESSION"
       boot placeholder at the exact same screen cell (render_core.asm's
       own comment on that pair) -- both still exist, only one is visible
       from here on. */
    spectrum_gui_game_timer_start();
    spectrum_gui_set_status("HOT SEAT");
    spectrum_gui_set_turn_label(side_to_move == NETCHESSZX_RULE_WHITE
                                     ? SPECTRUM_GUI_TURN_WHITE
                                     : SPECTRUM_GUI_TURN_BLACK);
    spectrum_info_show_game();

    /* S6 round 5 diagnosis (docs/sprinter-testnotes/S6.md "MAME round 5"):
       SAVE now visibly fails ("Save failed") in MAME, but round 4's static
       audit could not tell a bad DSS AppInfo-resolved directory apart from
       a genuine write failure against the real media -- "no amount of
       static reading can distinguish from here" (that section's own
       words). Surface the resolved directory once, right here, before any
       real notice (a bad move, a save attempt) can overwrite the notice
       line: this is the last one-time boot step, everything above it has
       already painted, and spectrum_gui_notify_persistent's ticks=0 means
       it stays on screen until the first later spectrum_gui_notify*
       call -- normal play does not force one before the tester can look
       at the very first post-boot screenshot. Truncated to the notice
       line's own NETCHESSZX_NOTICE_TEXT_SIZE-1 budget (gui.c's strncpy);
       an over-long path just loses its tail, not a crash. */
    spectrum_gui_notify_persistent(spectrum_platform_save_dir());

    /* First slice of real input handling (S5 substep 3): key_poll()
       (im2_s1.asm) does a non-blocking DSS keyboard poll every frame,
       translates the result into this port's own semantic key codes
       (0x81-0x84 arrows, 0x8A cancel, matching ZX/Next's own gui.h/
       screen.asm convention -- key_poll's own comment has the full
       mapping and how it was cross-checked against Estex-DSS's KEYINTER.
       ASM), and latches it into key_code; render_input_key_echo()
       (render_core.asm) paints that latched code as two hex digits next
       to the "> " prompt. Not yet a real key handler -- see render_
       input_key_echo's own comment for why: this exists to make the
       whole DSS-to-semantic-code path checkable on screen before
       anything acts on it. Safe to call gfx_*-family/text_print routines
       here even though IM2 is now installed: the
       IM2 stub (resident_s1.asm) chains to DSS's own #0038 handler for
       anything that is not a frame tick, so nothing about this loop
       changes how DSS's keyboard FIFO or interrupt handling behaves
       (port.md's R6) -- this is, however, the first time any WIN0/WIN3-
       remapping call in this port runs with IM2 actively installed
       (every earlier render_*() call above runs before im2_install()),
       so treat a MAME regression here as a new data point, not something
       already ruled out.

       board_cursor_move() (render_core.asm) is the first real consumer of
       key_code: it acts on the four arrow codes (moves the highlighted
       square, clamped to the board edges) and clears key_code itself once
       it does, read-and-clear rather than key_poll's own plain latch --
       see that routine's own comment for why this is deliberately
       different from render_input_key_echo's behaviour. Runs before the
       echo repaint so the echo reflects whatever key_code holds after
       consumption, not before it.

       S5-finish plan D12: spectrum_gui_handle_menu_key (gui.c, portable)
       gets first look at key_code, ahead of board_cursor_move/board_
       select_or_move -- when the menu is open it owns every key (LEFT/
       RIGHT navigate tabs, ENTER/SPACE activates the focused one, anything
       else is swallowed) so the board cursor cannot also react to the same
       press; when the menu is closed it returns the key unchanged and
       falls straight through to the cursor/select handling below exactly
       as before this pass -- zero behaviour change to P13's already-MAME-
       confirmed hot-seat play. See handle_menu_action above for what each
       tab actually does.

       S6 plan step 4: spectrum_gui_fileui_visible() is checked before even
       the menu-key call -- app.c's own central dispatcher (src/spectrum/
       app/app.c) uses this exact precedence, so that while the file
       browser is open it owns every keypress outright and neither the
       menu-tab layer nor the board cursor/select layer ever sees it. */
    for (;;) {
        frame_wait();
        key_poll();
        {
            unsigned char key = key_code;

            if (key != 0u) {
                if (spectrum_gui_fileui_visible()) {
                    key_code = 0u;
                    fileui_process_key(key);
                } else {
                    unsigned char handled = spectrum_gui_handle_menu_key(key);

                    if (handled != key) {
                        key_code = 0u;      /* menu consumed/transformed it --
                                                don't let the cursor also see it */
                        if (handled != 0u) {
                            handle_menu_action(handled);
                        }
                    }
                }
            }
        }
        board_cursor_move();
        board_select_or_move();
        render_input_key_echo();

        /* Wall clock (S5-finish step 1): sampled once a second, not every
           frame -- rtc_sample RSTs into DSS, and nothing here needs
           finer resolution than the HH:MM/HH:MM:SS display gui.c already
           renders. 50 frames matches gui.c's own internal 1 Hz cadence
           for the GAME/TURN timers (spectrum_gui_tick's clock_frames
           counter), just counted here instead since Sprinter's RTC is a
           local peripheral gui.c has no knowledge of (ZX/Next feed this
           same API from an MQTT SYNC_TIME message instead). */
        if (++rtc_tick_counter >= 50u) {
            rtc_tick_counter = 0u;
            rtc_sample();
            if (rtc_valid) {
                spectrum_gui_set_clock(rtc_hour, rtc_minute, rtc_second);
            }
        }
        /* GAME/TURN timers (1 Hz internal counter) and the notice-line
           countdown both live inside gui.c's own tick -- this is the
           first thing in this port's frame loop that calls it. */
        spectrum_gui_tick();
    }
}
