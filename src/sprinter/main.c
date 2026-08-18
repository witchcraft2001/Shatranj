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
 * available" stubs (S6/S7/S9 scope). See docs/sprinter-testnotes/S5.md for
 * the full checkpoint history.
 *
 * S9 chat pass: the chat panel is real now (INPUT_EDIT, SPECTRUM_OVL_
 * INPUT_EDIT=9u, src/sprinter/chat_sprinter.c, WIN3 page 2) -- ENTER opens
 * the input line below the "> " prompt, chat_input_mode routes subsequent
 * keys to it instead of the board/menu, and incoming CHAT lands in the
 * panel instead of the notice line (session_sprinter.c's own CHAT event
 * branch). See the frame loop below and chat_sprinter.c's own header.
 *
 * S9 exit + move-flash pass: ESC on the plain board screen arms a Y/N
 * exit-to-DSS prompt (exit_confirm/exit_now below -- the first and only
 * caller of im2_s1.asm's exit_stand; ZX/Next have no exit at all), and
 * every move-apply site now runs gui.c's own spectrum_gui_prepare_move/
 * apply_move (the ZX/Next from/to blink) instead of a bare two-square
 * repaint -- see net_apply_pending_local_move below and session_
 * sprinter.c's net_apply_remote_move/board_select_or_move.
 *
 * S9 follow-up (first MAME run of the two above): the frame loop now
 * dispatches a bounded BURST of queued keys per frame instead of exactly
 * one (fast chat typing was losing characters whenever a frame ran long),
 * ESC no longer doubles as the prompt's "no" answer (auto-repeat made the
 * prompt arm/cancel itself), and Y paints an acknowledgement and flips it
 * to the screen before the teardown, which can take seconds.
 */

#include "spectrum/config/session.h"
#include "spectrum/session/event.h"
#include "spectrum/session/poll.h"
#include "spectrum/session/direct.h"
#include "spectrum/session/outgoing.h"
#include "spectrum/transport/link.h"
#include "spectrum/platform/text.h"
#include "common/protocol/game_protocol.h"
#include "common/protocol/mqtt_session_protocol.h"
#include "spectrum/board/board.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/overlay/overlay_context.h"
#include "sprinter/chat_sprinter.h"
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
/* S9 follow-up (2026-08-18): screen fades, palette-only -- video.asm's own
   fade section header explains why dimming all 16 entries to black and back
   costs no pixel work at all. Callers put a screen rebuild between the two
   and none of it is seen. Neither may be called before im2_install (they
   step once per frame_wait). */
extern void fade_out(void);
extern void fade_in(void);
extern void render_board_full(void);
extern void render_coord_labels(void);
extern void render_status_clock(void);
extern void render_banner(void);
extern void render_menu_bar(void);
extern void render_status_text(void);
extern void render_input_line(void);
extern void key_poll(void);
/* im2_s1.asm's R11 exit discipline (ng_shutdown -> DI -> im2_uninstall ->
   svmod_safe -> park RGMOD/PORT_Y -> DSS_EXIT B=0), already published like
   every other platform primitive above (gen_sprinter_platform_defs.py's
   PLATFORM_SYMBOLS) but never called until S9's exit-to-DSS pass (below,
   exit_now). Does not return; ng_shutdown is idempotent (ret z on
   ng_loaded), so calling it a second time from here after a session was
   already torn down by something else is safe. */
extern void exit_stand(void);
extern void render_cursor_marker(void);
extern void render_select_marker(void);
/* S9 budget valve: shared constant for the three identical "Waiting for
   ACK" notify calls in this file (local_load_game, and the chat dispatch
   ladder's LINK_DOWN/net_send_busy and BLOCKED arms). */
static const char NOTICE_WAITING_FOR_ACK[] = "Waiting for ACK";
/* render_square_marked used to be declared here too (__z88dk_fastcall,
   spelled out rather than left to the classic default: it reads its
   argument from L, and a plain declaration makes sccz80 push it on the
   stack instead -- that compiled and even worked, purely because sccz80
   happens to leave the value in HL right before the push, the same "it
   works by accident until it doesn't" shape as this port's first two ABI
   bugs). Its last WIN1 caller, net_repaint_move, went away in the S9
   move-flash pass (spectrum_gui_apply_move repaints instead); the live
   declaration, with the same fastcall lesson, is session_sprinter.c's. */
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
/* S9 chat pass: src/sprinter/gui_log_sprinter.c -- Sprinter-only, no ZX/
   Next equivalent (gui.h's own spectrum_gui_add_chat is declared there
   and used for incoming chat, session_sprinter.c's own CHAT event branch;
   this one has no shared-header home since it is not part of ZX/Next's
   own gui.h API). Declared here, ahead of every caller (net_apply_loaded_
   snapshot below, main()'s own boot init, the frame loop) -- sccz80 has
   no forward-declaration recovery, an implicit-int call site ahead of
   this would conflict with the real prototype. */
extern void spectrum_gui_reset_chat(void);

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

/* Board cursor / selection state, shared with render_core.asm (see the
   comment on selected_row there): the renderer owns the cells because the
   asm cursor mover and the frame painters both read them, this file owns
   the selection *policy*, exactly as ZX splits app.c from screen.asm.

   Fixed low-RAM cells, not linker symbols: render_core.asm now lives in
   its own WIN3 code page (S7 step 4, the byte-budget ladder -- that file's
   own header), which is neither visible to this build's linker nor mapped
   in while WIN1 code runs. LOWRAM_RENDER_SHARED (src/sprinter/fixed_layout
   .json, whose desc pins the offsets) is the always-mapped WIN2 cell block
   both sides address by the same generated constant instead. Consequence:
   no static initialiser -- render_state_reset() below seeds them at boot. */
#define cursor_row \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 1))
#define cursor_col \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 2))
#define selected_row \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 3))
#define selected_col \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 4))
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

/* S8 relief pass: the DIRECT-session / board-interaction / menu-action
 * driver that used to fill this space (board_select_or_move through
 * handle_menu_action) has moved verbatim to src/sprinter/session_
 * sprinter.c on the WIN3 cold page -- see that file's own header for the
 * full rationale (byte-budget relief, S8's deferred plan step 2). Calling
 * side is unchanged: the six entry points below are published under their
 * original names by tools/gen_sprinter_cold_thunks.py, so the frame loop
 * and the one boot-time call further down need only a prototype.
 * fileui_process_key is NOT among them any more -- the second relief cut
 * (see this file's own save/load section further down) moved it, and
 * everything it calls, back to WIN1 outright; main()'s frame loop below
 * now reaches its definition directly, same file, no bridge at all. */
extern void board_select_or_move(void);
extern void net_poll_once(void);
extern void net_retry_tick(void);
extern void handle_menu_action(unsigned char action);
extern void net_control_key(unsigned char key);
extern void net_set_turn_label_from_side(void);
/* S9 About (second MAME round): the whole post-About screen rebuild, one
   call -- see about_close below for why it is over there and not here. */
extern void about_restore_screen(void);

/* Networked play (S7 step 5). Zero while the port is in its original
   hot-seat mode, which is still the boot state. Still WIN1-resident --
   session_sprinter.c reads/writes it through the usual resident-symbol
   bridge (see that file's own header) because the frame loop below reads
   it directly every frame, and WIN1 cannot read cold-page BSS with WIN3
   mapped elsewhere. */
static unsigned char net_active;

/* unet_link.c (WIN1, so a plain link-time neighbour here -- no bridge): the
   last send exhausted its busy-retry budget on uNet's NERR_BUSY. Nothing
   went out, and nothing about the link is broken. See its definition there,
   and session_sprinter.c's net_send_failed for the same discrimination on
   the cold-page side. */
extern unsigned char net_send_busy;

/* S9 chat pass: set while the chat input line (INPUT_EDIT overlay,
   SPECTRUM_OVL_INPUT_EDIT=9u, src/sprinter/chat_sprinter.c) owns the
   keyboard -- checked ahead of net_control_key below so a chat line in
   progress is never mistaken for a 'd'/'y'/'n' control-key answer, and
   ahead of board_cursor_move/board_select_or_move (via key_code, which
   every consuming branch below zeroes) so typing never moves the cursor
   or picks up a piece. WIN1-local only: chat_sprinter.c's own overlay
   page has no notion of this flag, it just answers whatever entry WIN1
   dispatches. */
static unsigned char chat_input_mode;


/* S8 relief pass, second cut: the cold page's own overrun (18190/16384
 * bytes with the whole session driver moved there in one piece) forced a
 * partial reversal -- everything below is the subset of that driver which
 * turned out, once mechanically checked against what it actually
 * references, to touch none of the net_active-guarded session state
 * (control_pending, takeback_*, restore_chunk_have/_prompt_pending,
 * net_ping/_hello_wait/_peer_known): save/load, the file browser, and the
 * three simple menu actions (theme/flip/not-available). It stays WIN1-
 * resident the same way it always was; only the eight state variables it
 * DOES share with the still-cold session driver (pending_local_ply/_move,
 * pending_retry_timer, control_retry_count, restore_rx_mask,
 * saveload_snapshot, saveload_b64_pending, plus net_active itself) moved
 * along with it, bridged back to session_sprinter.c the same way net_active
 * already was. menu_theme_index has no cold-side reader at all (only
 * menu_cycle_theme ever touched it, and that moved here too) -- plain WIN1
 * storage, no bridge entry needed. See session_sprinter.c's own header for
 * the full byte-budget history; the numbers there predate this second cut.
 */
#define PENDING_RETRY_TICKS 120u
#define RESTORE_TX_PENDING 0x01u    /* sent RQ, waiting for RY/RN */
#define RESTORE_TX_AWAIT_ACK 0x02u  /* sent both chunks, waiting for RA/RN */
#define RESTORE_RX_RECEIVE 0x04u    /* sent RY, waiting for the two chunks */
#define RESTORE_RX_APPLIED 0x08u    /* applied; a matching resend re-ACKs
                                        RA, a conflicting one NACKs, neither
                                        re-decodes (docs/session-core-
                                        contract.md's accepted-restore
                                        duplicate latch) */
static uint16_t pending_local_ply;
static char pending_local_move[6];
static unsigned char pending_retry_timer;
static unsigned char control_retry_count;
static unsigned char restore_rx_mask;
static spectrum_board_snapshot_t saveload_snapshot;
static char saveload_b64_pending[NETCHESSZX_SAVE_WIRE_B64_SIZE];

/* Bridged from session_sprinter.c (WIN3 cold page): board_select_or_move,
 * menu_reset_game, net_draw_offer, net_takeback_request and this file's
 * own local_load_game (below) all share the same one-operation-pending
 * guard. Declared here as a plain prototype -- the real definition stays
 * on the cold page, tools/gen_sprinter_cold_thunks.py publishes it under
 * this exact name. */
extern unsigned char net_op_busy(void);
/* Bridged the same way: every exit from a session (peer FIN, RXF_LOST, a
 * give-up past the retry budget) lands here, and local_load_game (below)
 * needs the same one-line "link's dead, make WIN1's own state honest
 * again" cleanup a failed RESTORE_RQ send hits. */
extern void net_drop(const char *why);
/* Bridged the same way (S9 chat pass): a stricter subset of net_op_busy --
 * only a pending local MOVE or an in-progress RESTORE exchange blocks
 * CHAT (docs/session-core-contract.md:315-318), not a pending RESET/DRAW/
 * RESIGN/TAKEBACK the way net_op_busy's own callers require. Checked both
 * before opening the chat line (below) and again at submit time inside
 * the overlay itself (chat_sprinter.c's own header explains why). */
extern unsigned char net_chat_blocked(void);
/* Bridged the same way: net_apply_loaded_snapshot (below) clears the
 * board-cursor highlight before repainting, exactly like every other
 * "the board just changed under us" site in session_sprinter.c. */
extern void selection_clear(void);

/* S8 relief pass, third cut: the second cut alone (save/load, file
 * browser, three simple menu actions) still left the cold page 441 bytes
 * over its fixed 16 KiB ceiling once actually built -- these three more
 * state variables and the six functions below them (apply_takeback_
 * snapshot through net_send_takeback_wire) close the rest of the gap.
 * Same selection rule as the second cut: mechanically confirmed to touch
 * none of net_active/control_pending/restore_chunk_have/_prompt_pending/
 * net_ping/_hello_wait/_peer_known, which is why they could move without
 * dragging the whole session driver back with them. takeback_pending_ply
 * and last_accepted_takeback_ply stay on the cold page -- only takeback_
 * snapshot_save (bridged below) and net_handle_event's own TAKEBACK
 * branch ever touch those two, and both stay put. */
static spectrum_board_undo_t takeback_undo;
static uint16_t takeback_snapshot_ply;
static unsigned char takeback_snapshot_local;

/* Bridged from session_sprinter.c (WIN3 cold page): apply_takeback_
 * snapshot (below) starts with pending_local_clear() -- the same shared
 * one-operation-state reset net_apply_pending_local_move (below) also
 * needs, and net_apply_reset/net_drop/net_handle_event (still cold) reset
 * it too, which is why it stayed there rather than moving with its own
 * WIN1-resident state. */
extern void pending_local_clear(void);
/* Bridged the same way: net_apply_pending_local_move's own local-apply
 * site (below) shares this exact "record a one-ply undo snapshot" helper
 * with net_apply_remote_move's remote-apply site, which stays cold. */
extern void takeback_snapshot_save(uint16_t ply, unsigned char local_move);

static void apply_takeback_snapshot(void) {
    if (takeback_snapshot_ply == 0u) {
        return;
    }
    pending_local_clear();
    spectrum_board_undo_restore(&takeback_undo);
    spectrum_gui_log_ply_set((uint16_t)(takeback_snapshot_ply - 1u));
    spectrum_gui_remove_last_move(takeback_snapshot_ply);
    takeback_snapshot_ply = 0u;
    takeback_snapshot_local = 0u;
    selection_clear();
    render_board_full();
    render_cursor_marker();
    spectrum_gui_move_timer_reset();
    net_set_turn_label_from_side();
    spectrum_gui_notify_persistent("Takeback");
}

static void net_status_idle(void) {
    spectrum_gui_set_connected(0u);
    spectrum_gui_set_status("HOT SEAT");
}

static unsigned char net_send_move_wire(uint16_t ply, const char *move) {
    char payload[24];
    char *p = spectrum_append_text(payload, NETCHESS_PROTO_MOVE_PREFIX);

    p = spectrum_append_u16(p, ply);
    *p++ = ' ';
    (void)spectrum_append_text(p, move);
    return spectrum_link_send_text(payload);
}

/* "NACK <ply> SYNC" -- an otherwise-legal MOVE whose ply is not the next
   expected one (docs/session-core-contract.md: "SYNC is the normative
   reason token for this divergence"). Built with spectrum_append_text
   rather than app.c's own in-place buffer-splice trick (send_local_move's
   caller there overwrites "MOVE" with "NACK" and splices "SYNC" into the
   middle of the same payload buffer to save a few WIN1 bytes on ZX's much
   tighter budget) -- Sprinter has the room, and a hand-built payload is
   less fragile than reusing a buffer whose layout has to match by
   construction. */
static unsigned char net_send_nack_sync(const char *ply) {
    char payload[24];
    char *p = spectrum_append_text(payload, "NACK ");

    p = spectrum_append_text(p, ply);
    (void)spectrum_append_text(p, " SYNC");
    return spectrum_link_send_text(payload);
}

/* S8 step 3 (app.c's apply_pending_local_move): the peer's numeric ACK for
   pending_local_ply has arrived (or, in net_apply_remote_move's crossed-
   move case, an incoming MOVE resolves it implicitly) -- only now does the
   move actually land on the board. A failure here has no real runtime
   source (the move was already validated legal before it was sent, and
   nothing else can have moved this side's own pieces while a reply was
   pending), but is handled rather than assumed, matching every other
   apply site in this file. */
static void net_apply_pending_local_move(void) {
    uint16_t applied_ply;

    if (pending_local_ply == 0u) {
        return;
    }
    /* S9 (move-flash): flashes FROM (piece still on the board) before BOARD
       applies the move, matching app.c's own ordering (spectrum_gui_
       prepare_move ahead of spectrum_board_apply_trusted_move_with_undo,
       app.c:1639-1640). */
    spectrum_gui_prepare_move(pending_local_move);
    /* S8 step 5: capture the one-ply undo record here too -- a takeback
       request can only ever be offered for the move just applied, local
       or remote, and this is the local-apply site (net_apply_remote_move
       is the other). */
    if (!spectrum_board_apply_trusted_move_with_undo(pending_local_move,
                                                     &takeback_undo)) {
        pending_local_clear();
        spectrum_gui_notify("Bad move", 1u);
        return;
    }
    applied_ply = pending_local_ply;
    /* spectrum_gui_apply_move repaints from/to (plus castling rook / en-
       passant capture squares) and flashes TO -- replaces net_repaint_
       move's own bare two-square repaint. */
    spectrum_gui_apply_move(pending_local_move);
    spectrum_gui_move_timer_reset();
    net_set_turn_label_from_side();
    spectrum_gui_notify_persistent(pending_local_move);
    spectrum_gui_add_move("", pending_local_move);
    pending_local_clear();
    takeback_snapshot_save(applied_ply, 1u);
}

/* "TAKEBACK <ply>" -- byte-for-byte app.c's own send_takeback_wire shape,
   reused for both the initial send (net_takeback_request, further down)
   and every retransmit (retry_pending_outgoing below). */
static unsigned char net_send_takeback_wire(uint16_t ply) {
    char payload[24];
    char *p = spectrum_append_text(payload, NETCHESS_PROTO_TAKEBACK_PREFIX);

    (void)spectrum_append_u16(p, ply);
    return spectrum_link_send_text(payload);
}

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
   the selection/cursor markers, plus render_hint_markers_all for a live
   selection's hint dots -- fileui_close's own call site has no prior
   selection_clear() to have already cleared them) -- this port's own
   proven, MAME-tested redraw, not gui.c's spec-based path (see menu_flip_
   board's own comment for why that one has no live caller here). Also
   erases whatever the FILEUI panel painted over the board area (S6 plan
   step 4) -- a full repaint of that same screen region is a correct
   "close" for either reason, load or plain cancel. S9 budget valve: the
   body is five plain cold-page thunk calls and nothing else, so it moved
   to render_shim.asm (asm/sprinter/zcc) as hand-written asm -- a C
   function paid a full call prologue per call site (three of them) for
   work that is otherwise just five 3-byte `call`s in a row. */
extern void saveload_full_redraw(void);

/* Shared by local_load_game's local-apply path and net_handle_event's
   RESTORE_RS completion (S8 step 6) -- both end up applying a decoded
   snapshot the exact same way; only the notice text and the pending-state
   clears around the call site differ. saveload_snapshot is already
   populated by the caller's own spectrum_restore_decode. */
static void net_apply_loaded_snapshot(const netchesszx_save_meta_t *meta) {
    spectrum_board_snapshot_restore(&saveload_snapshot);
    spectrum_gui_set_board_view((unsigned char)
        (meta->view_flags & NETCHESSZX_SAVE_VIEW_FLIPPED));
    selection_clear();
    saveload_full_redraw();
    spectrum_gui_reset_move_log();
    /* app.c's own net_apply_loaded_snapshot equivalent clears BOTH logs
       here (spectrum_gui_reset_logs, app.c:1121) -- a loaded/restored
       position has no relationship to whatever chat happened before it.
       Unlike RESET (session_sprinter.c's menu_reset_game/net_apply_reset,
       app.c's own game_start_state), which keeps chat across a rematch
       with the same still-connected peer. */
    spectrum_gui_reset_chat();
    spectrum_gui_log_ply_set(meta->ply);
    spectrum_gui_game_timer_start();
    spectrum_gui_move_timer_reset();
    net_set_turn_label_from_side();
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
    /* S8 step 6 (app.c's own fileui-while-connected shape): with a peer
       connected, loading a file pushes the position to them instead of
       applying it locally -- app.c's send_local_move guard, reused here
       for the same one-operation invariant. spectrum_restore_decode's b64
       parameter is const (restore.c), so saveload_b64_pending is still
       exactly the 60-char wire text read from disk -- no need to rebuild
       it from the just-decoded snapshot the way app.c does (that
       rebuild's own comment there is about ITS overlay-local scratch
       aliasing, which does not apply to this port's shape). */
    if (net_active) {
        if (net_op_busy()) {
            spectrum_gui_notify(NOTICE_WAITING_FOR_ACK, 0u);
            return;
        }
        if (!spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RQ)) {
            /* net_send_busy: uNet refused for its whole retry budget with
               NERR_BUSY, which means nothing went out and the link is fine
               (unet_link.c). session_sprinter.c's net_send_failed does the
               same discrimination for every send site on its side; this one
               and the chat send below are the two that live in WIN1, where
               net_send_busy is a plain neighbour symbol rather than a cold-
               page bridge. Nothing is pending yet at this point, so there is
               nothing to retransmit -- the honest answer is to say so and
               leave the player to press it again. */
            if (net_send_busy) {
                spectrum_gui_notify("Link busy - try again", 1u);
            } else {
                net_drop("Link down");
            }
            return;
        }
        restore_rx_mask = RESTORE_TX_PENDING;
        control_retry_count = 0u;
        pending_retry_timer = PENDING_RETRY_TICKS;
        spectrum_gui_notify("Sending to opponent...", 0u);
        return;
    }
    net_apply_loaded_snapshot(&meta);
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

/* --- About screen (S9 About pass) -------------------------------------------
 *
 * A full-screen picture with the version caption, drawn by the ABOUT
 * overlay (asm/sprinter/zcc/about_sprinter.asm -- see its header for why it
 * stays in the ordinary 640x256 mode instead of switching to 320x256x8bpp).
 *
 * It deliberately reuses the FILE browser's own "a modal screen owns the
 * display" machinery rather than adding a second one: gui.c's about_visible
 * gate already suppresses every board-area repaint path, and it is shared
 * source with ZX/Next, so giving Sprinter its own value there would mean
 * editing a shared file for one platform -- and the ZX/Next artifacts must
 * stay byte-identical. spectrum_gui_show_fileui() therefore raises the gate
 * for both screens and this one byte says WHICH of them is up. The cost is
 * one flag; the alternative was ~40 bytes of duplicated gate code on a cold
 * page that had none to give.
 *
 * The screen is a STATE, not a blocking loop: the frame loop keeps running
 * underneath, so a networked game's link stays alive (and its clock keeps
 * ticking) while About is on screen -- a blocking wait would stall the
 * session and could drop it.
 */
static unsigned char about_screen;

static void about_open(void) {
    /* Fade the game screen out, swap the whole screen behind a black
       palette, fade the picture in. The overlay applies its own 16-entry
       palette through palette_apply_from, which honours the fade level like
       every other palette write -- so it lands black, and the fade_in below
       is what reveals it. Without this the tester watched the picture blit
       in over the board, band by band (2026-08-18). */
    fade_out();
    spectrum_gui_clear_cursor_coords();
    spectrum_gui_show_fileui();
    about_screen = 1u;
    spectrum_overlay_exec_cached(SPECTRUM_OVL_ABOUT,
                                  SPECTRUM_OVL_ABOUT_RENDER);
    fade_in();
}

static void about_close(void) {
    about_screen = 0u;
    /* The whole rebuild is one call on the cold page (session_sprinter.c).
       It started here, as ten calls into that page, and grew wrong twice:
       the first MAME run came back to a correct board framed by leftover
       picture (no pixel clear at all), the second to a cleared screen
       missing the move list, the chat log, the notice line, the clock and
       the turn label -- every field that is repainted from state this
       resident cannot see. Moving it to the page that owns that state fixed
       both, and cost WIN1 nine calls rather than adding any. It owns the
       fade around the rebuild too (2026-08-18), for the same reason and one
       more: the two calls are 6 bytes, and this pool has none to spare. */
    about_restore_screen();
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

/* --- DIRECT session (S7 step 5, port.md section 3.7) ------------------------
 *
 * JOIN role only: the host side needs the SETUP screen (colour choice,
 * listen) which is S9 scope, and port.md's own S7 definition-of-done is a
 * Sprinter(join) <-> Qt(host) game. Host/port come from the NETHOST/NETPORT
 * environment variables (net_gate.asm's ng_env_*), with no interactive
 * entry this milestone.
 *
 * DELIBERATE DEVIATION from ZX/Next's shape: app.c runs a separate
 * game_message_loop() for the whole networked game, because on ZX the
 * hot-seat and networked paths are genuinely different loops. This port
 * has one frame loop that is already MAME-proven for key handling, cursor,
 * clocks, notices and the flip, so the session poll is folded INTO it
 * (net_poll_once below, called once per frame when net_active) instead of
 * being duplicated. Anything the session does to the screen goes through
 * the same gui.c/render path hot-seat play already uses, so there is no
 * second rendering path to keep in sync -- and no way for the two loops to
 * drift apart, which is what a duplicated 300-line loop would eventually
 * do. What is NOT ported from game_message_loop, and is honestly missing
 * rather than stubbed: the control cancel timers, takeback, and RESTORE
 * chunking (S8 steps 4-6).
 *
 * S8 step 3: the pending-outgoing retry ladder for local MOVE, and with it
 * the deferred-apply model docs/session-core-contract.md:265-267 actually
 * requires ("The MOVE is not applied locally" until its numeric ACK
 * arrives) -- board_select_or_move used to apply a networked move to the
 * board immediately and send it after, which is a real contract violation
 * carried over from the hot-seat path this file's own header once
 * described as having "no pending-ply gate, because on Sprinter there is
 * no session yet (S7)". That comment stopped being true the moment S7 gave
 * this file a session; nothing had exercised the gap until now. See
 * pending_local_ply/pending_local_move, net_send_move_wire,
 * net_apply_pending_local_move, retry_pending_outgoing/net_retry_tick
 * below, and net_apply_remote_move's crossed-move/SYNC guards (app.c's
 * send_local_move/apply_pending_local_move/retry_pending_outgoing, ported
 * without SAN, takeback, or the control-pending guards those need (S8
 * steps 4/5 add them to net_apply_remote_move's guard chain)). No parity
 * judge exists for this bespoke Sprinter event loop the way one does for
 * the common session reducer -- this is checked by static gates and the
 * S8 step 6 MAME handoff only, not by a host-side transcript judge.
 *
 * Ping/keepalive is entirely the session layer's (poll.c answers PING with
 * ACK PING and drives the miss counter); nothing here re-implements it.
 */
static unsigned char menu_theme_index;
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
/* S9 budget valve: moved to render_shim.asm (asm/sprinter/zcc) alongside
   saveload_full_redraw, whose repaint tail it shares by falling straight
   into it -- see that file's own comment on both. Flip leaves cursor_row/
   col and selected_row/col untouched (this function's OLD header comment,
   above, still describes the real behaviour) -- a live selection's hint
   dots must still show, now at their flipped screen positions, which is
   exactly what render_hint_markers_all in the shared tail gives it. */
extern void menu_flip_board(void);

/* --- chat (S9 chat pass) ----------------------------------------------
 *
 * Thin dispatchers onto INPUT_EDIT's own entries (chat_sprinter.c, WIN3
 * page 2) -- overlay_loader_sprinter.asm's spectrum_overlay_exec_cached is
 * already resolved within this resident C image (board.c calls it the
 * same way for RULES/BOARD), so no bridge of its own is needed. */
extern unsigned char spectrum_overlay_exec_cached(unsigned char ovl_id,
                                                    unsigned char entry_id);

static unsigned char chat_key(unsigned char key) {
    spectrum_overlay_context[SPECTRUM_OVL_CTX_INPUT_KEY] = key;
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_INPUT_EDIT,
                                        SPECTRUM_OVL_INPUT_EDIT_KEY);
}

static void chat_open(void) {
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_INPUT_EDIT,
                                       SPECTRUM_OVL_INPUT_EDIT_BEGIN_EMPTY);
}

static void chat_stop_clear(void) {
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_INPUT_EDIT,
                                       SPECTRUM_OVL_INPUT_EDIT_STOP_CLEAR);
}

#define CHAT_OPEN_KEY 0x0du   /* ENTER, im2_s1.asm's key_poll */

/* --- exit to DSS (S9) -------------------------------------------------
 *
 * ZX/Next have no exit at all (hard reset only) -- this is Sprinter-only,
 * modelled on app.c's own confirm_action Y/N pattern (a persistent
 * error-severity notice, 'y'/'n' answer it, everything else while it is
 * pending is swallowed) rather than on anything ZX/Next actually do.
 * KEY_CANCEL matches FILEUI_CLOSE_KEY's own value (im2_s1.asm's key_poll,
 * ESC) -- named separately here since this file's ESC handling is no
 * longer only about the file browser.
 */
#define KEY_CANCEL 0x8au

/* How many queued keys one frame may dispatch (the frame loop's own
   comment has the why). Four covers a burst of typing at any realistic
   rate against a slow frame without letting a held key monopolise the
   frame: the worst case is four consecutive board moves, each with its
   own blocking flash animation. */
#define KEY_BURST_MAX 4u

static unsigned char exit_confirm;
/* One copy, two call sites (arm + re-paint, both in the frame loop). */
static const char exit_prompt_msg[] = "Exit to DSS? Y/N";

static const char exit_going_msg[] = "Exiting to DSS...";

static void exit_now(void) {
    /* Acknowledge the Y on screen BEFORE the teardown, and give it two
       frames to get there. Every painter in this port writes the BACK
       buffer and frame_wait is what flips it, so one frame_wait makes the
       message visible and the second leaves both buffers holding it.
       Without this the tester presses Y and watches an unchanged board
       with the prompt still up for as long as the teardown takes -- a live
       session's BYE/offline presence goes through the busy-retry ladder,
       ng_shutdown unloads the DLL, and DSS itself reloads its shell from
       disk after DSS_EXIT ("по подтверждении ничего не происходит долгое
       время", S9 MAME run 2026-08-16). The status band gets it too: it is
       the widest, most obvious text cell on screen, and nothing repaints
       it again before the video mode is restored. */
    spectrum_gui_set_status("EXITING");
    spectrum_gui_notify(exit_going_msg, 0u);
    frame_wait();
    frame_wait();
    if (net_active) {
        /* Same teardown menu DISCC already does while connected (BYE, MQTT
           offline presence, net_drop) -- handle_menu_action's own DISCC
           branch (session_sprinter.c's menu_network) returns immediately
           after net_drop when net_active, it does not open the NET
           screen. */
        handle_menu_action(SPECTRUM_GUI_KEY_MENU_DISCC);
    }
    exit_stand();          /* does not return */
}

void main(void) {
    unsigned char pass;

    bench_init();

    /* LOWRAM_RENDER_SHARED is a fixed address block, so nothing zero-fills
       or pre-initialises it the way C storage would (fixed_layout.json's
       own note, which also pins these offsets). Seed every cell here,
       before the first painter or key handler can read one: +0 is gui.c's
       spectrum_gui_board_flipped (0 = white at the bottom, its former BSS
       value), +1/+2 the board cursor (e4, the same arbitrary visually
       centred square render_core.asm's data_user section used to hold as
       defb 4,4) and +3/+4 the selection (NO_SQUARE, its former defb $FF).
       Deliberately ahead of video_init(): bench_init() has just published
       the WIN3 code page these cells are shared with, and the very next
       call already runs out of it. */
    *(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 0) = 0u;
    cursor_row = 4u;
    cursor_col = 4u;
    selected_row = NO_SQUARE;
    selected_col = NO_SQUARE;

    /* S9 dot-highlight: netchesszx_hinted_rows is fixed low RAM, never
       zero-filled by crt0 -- but unlike LOWRAM_RENDER_SHARED just above,
       it genuinely needs no explicit boot seed. netchesszx_movement_hints
       (config/session.c, ordinary resident BSS) starts at crt0's own 0 --
       hints off by default, same as ZX/Next's own SETUP-screen-gated
       default, toggled on with 'h' (net_control_key, session_sprinter.c)
       -- and every reader of netchesszx_hinted_rows (render_hint_marker/
       render_hint_markers_all, render_core.asm; hints_clear/hints_show,
       session_sprinter.c) checks netchesszx_movement_hints or hints_from
       first, never reading the mask's stale boot content before the
       first real hints_show() call rebuilds it from scratch (RULES entry
       SPECTRUM_OVL_HINTS_SHOW zeroes it before setting any bit). */

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

    /* The probe left its own e2e4 on the board. Reset again so the game
       actually starts from the start position now that moves can be made
       by hand (S5 substep 3c): P12's "the pawn is visibly on e4" was the
       right evidence while nothing else could move a piece, but keeping a
       scripted opening move on the board would now just be a wrong
       position to play from. The probe still runs, and its result is
       reported below -- only its side effect is undone. */
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

    /* render_cursor_marker() must run after render_board_full() so the cell
       it overlays already has real content. Nothing else in the group above
       has an order requirement any more: they used to have to precede
       clear_bg_signal(), since their text/label boxes paint with palette
       index 0 and that call was what put index 0 back to black after the
       boot diagnostic had tinted it (render_core.asm's own COORD_COLOR/
       STATUS_COLOR/BANNER_COLOR/MENU_COLOR/STATUS_TEXT_COLOR/INPUT_COLOR
       comments). Index 0 is never anything but black now -- see the fade
       note below. */

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
    net_set_turn_label_from_side();
    spectrum_info_show_game();

    /* The boot notice line used to hold spectrum_platform_save_dir()'s
       resolved directory (S6 round 5): SAVE was failing in MAME and static
       reading could not tell a bad DSS AppInfo-resolved path apart from a
       real write failure against the media, so the port printed the path it
       had actually resolved. That question is long since answered -- save
       and load both work, and the file browser lists the same directory on
       demand -- leaving a diagnostic string as the first thing the game says
       on every boot (human tester, 2026-08-18). Removed; the resolver itself
       (spectrum_platform_save_dir_init above) obviously stays. */

    /* S9 chat pass: the chat panel's own LOWRAM buffer is not zeroed by
       the loader (only C BSS is, and this buffer is a fixed low-RAM
       region shared with the INPUT_EDIT overlay, not linker-owned
       storage) -- without this, the very first RENDER/repaint would
       paint whatever garbage happened to be there at boot. One-time,
       same reasoning as the LOWRAM_RENDER_SHARED seeding at the top of
       this function. */
    spectrum_gui_reset_chat();

    /* The overlay probe's verdict, now that there is somewhere to say it.
       It used to be a green/red repaint of palette index 0 (ovl_test_signal
       plus clear_bg_signal to undo it, both deleted here) -- S5 substep 2
       scaffolding from before this port could put anything on screen at all,
       and by now just a green flash across the whole background before the
       real screen appeared (human tester, 2026-08-18). An error notice is
       both quieter and more informative, and it stays: gui.c gives error
       notices ticks=0, so nothing ages it out. Only on failure -- a passing
       probe is the normal case and has nothing to report. It stays the last
       thing boot writes to the notice line -- nothing after it may claim
       that line, or a real failure would be reported and then hidden. Uses
       the _persistent (fastcall, one argument) form rather than notify(text,
       1u): sccz80 spells the two-argument call out in 13 bytes against six,
       and this pool had four to spare, not eleven. */
    if (!pass) {
        spectrum_gui_notify_persistent("Overlay probe failed");
    }

    /* Everything painted so far went onto a screen whose palette is still
       all black (video.asm's fade_level starts at 0), so none of it has been
       seen: no flash of a half-built screen, no diagnostic tint, no board
       appearing cell by cell. This is what reveals it. It has to come after
       im2_install above -- a fade is one palette step per frame, and
       frame_wait waits on a flag only the IM2 tick sets. */
    fade_in();

    /* First slice of real input handling (S5 substep 3): key_poll()
       (im2_s1.asm) does a non-blocking DSS keyboard poll every frame,
       translates the result into this port's own semantic key codes
       (0x81-0x84 arrows, 0x8A cancel, matching ZX/Next's own gui.h/
       screen.asm convention -- key_poll's own comment has the full
       mapping and how it was cross-checked against Estex-DSS's KEYINTER.
       ASM), and latches it into key_code. Safe to call gfx_*-family/
       text_print routines here even though IM2 is now installed: the
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
       it does, read-and-clear rather than key_poll's own plain latch.

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
        /* One frame_wait per iteration, but as many queued keys as
           the burst budget allows: key_poll() dequeues ONE DSS
           keyboard event per call into a single latch, so a frame
           that runs long (a network poll through the busy-retry
           ladder, a blocking move animation, a chat repaint) used
           to drop every keypress but the last one -- fast typing in
           the chat line visibly lost characters (human tester, S9
           MAME run 2026-08-16). Bounded rather than "drain until
           empty" on purpose: each pass can start something
           expensive (a move with its ~1s flash, a send), and an
           unbounded loop would let a stuck-key repeat stream starve
           the session poll at the bottom of the frame.

           key_code is cleared at the end of each pass so the next
           key_poll() can be told "nothing new" (it leaves the latch
           untouched when the queue is empty) -- that also drops the
           old "last key stays latched forever" behaviour, which no
           consumer here ever wanted and which only existed for a
           debug echo that is long gone. */
        unsigned char keys_left = KEY_BURST_MAX;
        unsigned char key;

        frame_wait();
        for (;;) {
            key_poll();
            key = key_code;
            if (key != 0u) {
                if (exit_confirm) {
                    /* Highest-priority layer, same as app.c's own confirm_
                       action (CONFIRM > OVERLAY > MENU > GAME): swallows
                       every key except the answer, so fileui/menu/chat/
                       board can never see a press while this prompt is up
                       -- exit_confirm can only ever have been set (below)
                       from the plain board screen with nothing else open,
                       so this can never itself interrupt one of those. */
                    key_code = 0u;
                    if (key == 'y' || key == 'Y') {
                        exit_now();                /* does not return */
                    } else if (key == 'n' || key == 'N') {
                        exit_confirm = 0u;
                        spectrum_gui_notify("", 0u);
                    } else {
                        /* ESC deliberately does NOT answer this prompt, even
                           though it is the key that raised it and cancels
                           every other overlay in this file. DSS's keyboard
                           FIFO delivers auto-repeat, so one held ESC arrives
                           as a burst -- with ESC meaning "cancel" here, the
                           burst armed and cancelled the prompt over and over
                           and the tester saw the notice line blink and clear
                           itself ("нажатие на Esc приводит к скрытию
                           сообщения", S9 MAME run 2026-08-16). Repeats now
                           just re-paint the same prompt, which is stable
                           whatever the repeat rate. Y or N answers it, as
                           the prompt itself says. */
                        /* Swallowed -- but re-paint the prompt rather than
                           stay silent. The session keeps polling below
                           while this is armed, so an incoming event
                           (opponent's move, "Disconnected", a draw offer)
                           can overwrite the notice text while the prompt
                           state stays up; without this, the next key
                           press would vanish into a screen that no longer
                           shows any prompt at all -- the exact "invisible
                           modal state reads as broken input" failure this
                           port has already shipped once (S5 menu focus,
                           docs/sprinter-testnotes/S5.md). ZX sidesteps it
                           differently: its incoming-event paths check
                           confirm_action and refuse to raise a competing
                           notice, which this port's state-based net_
                           control_key does not do. */
                        spectrum_gui_notify(exit_prompt_msg, 1u);
                    }
                } else if (spectrum_gui_fileui_visible()) {
                    key_code = 0u;
                    if (about_screen) {
                        /* About is a picture, not a UI: ANY key dismisses
                           it. Both screens share gui.c's modal gate (see
                           about_open above), so this flag is what tells
                           them apart here. */
                        about_close();
                    } else {
                        fileui_process_key(key);
                    }
                } else {
                    /* S9 chat pass: TAB closes an open chat line before the
                       menu toggle below runs -- gui.c's own spectrum_gui_
                       handle_menu_key always consumes SPECTRUM_GUI_KEY_MENU
                       itself (toggle_menu_bar), so this only cleans up the
                       chat overlay's own state first; the menu still opens
                       on the very same press, exactly as it would without
                       chat involved. */
                    if (chat_input_mode && key == SPECTRUM_GUI_KEY_MENU) {
                        chat_stop_clear();
                        chat_input_mode = 0u;
                    }

                    {
                        unsigned char handled = spectrum_gui_handle_menu_key(key);

                        if (handled != key) {
                            key_code = 0u;      /* menu consumed/transformed it --
                                                    don't let the cursor also see it */
                            if (handled != 0u) {
                                handle_menu_action(handled);
                            }
                        } else if (chat_input_mode) {
                            /* The line is open -- every key that reaches
                               here (not fileui, not a menu key) belongs to
                               it, not the board/control layer. chat_key's
                               return code decides what happens next
                               (chat_sprinter.h). */
                            unsigned char rc = chat_key(key);

                            key_code = 0u;
                            /* Every outcome except BLOCKED closes the line
                               -- hoisted here once instead of repeating it
                               in three of the four arms below (WIN1 budget
                               valve). */
                            if (rc != CHAT_SPRINTER_KEY_BLOCKED) {
                                chat_input_mode = 0u;
                            }
                            if (rc == CHAT_SPRINTER_KEY_LINK_DOWN) {
                                if (net_send_busy) {
                                    /* Transient BUSY, not a dead link -- see
                                       the RESTORE_RQ send above. CHAT has no
                                       retransmit ladder behind it (it is not
                                       an ACKed operation), so the line is
                                       genuinely lost; ending the session over
                                       it would be far worse. */
                                    spectrum_gui_notify("Link busy - not sent",
                                                        1u);
                                } else {
                                    net_drop("Link down");
                                }
                            } else if (rc == CHAT_SPRINTER_KEY_BLOCKED) {
                                spectrum_gui_notify(NOTICE_WAITING_FOR_ACK, 0u);
                            } else if (rc >= CHAT_SPRINTER_KEY_CMD_DRAW) {
                                /* S9 slash commands: chat_submit already
                                   closed the line (chat_sprinter.c) -- each
                                   is a strict alias of the matching hotkey,
                                   so all the actual policy (busy/pending
                                   guards, confirmation, retry) lives once,
                                   in net_control_key, not duplicated here.
                                   No upper bound needed: CMD_TAKEBACK (6)
                                   is chat_key's own highest possible return
                                   value (chat_sprinter.h), and this is the
                                   last arm of the ladder. "drt"[rc-CMD_DRAW]
                                   turns the three consecutive CMD_* codes
                                   (DRAW=4, RESIGN=5, TAKEBACK=6) back into
                                   their hotkey letters without a three-way
                                   branch. CHAT_SPRINTER_KEY_CLOSED itself
                                   needs no branch at all now -- closing the
                                   line was this whole ladder's only effect
                                   for that outcome, already done above. */
                                static const char cmd_keys[4] = "drt";

                                net_control_key((unsigned char)
                                    cmd_keys[rc - CHAT_SPRINTER_KEY_CMD_DRAW]);
                            }
                        } else if (key == CHAT_OPEN_KEY) {
                            /* ENTER, chat closed: open the line unless
                               there is no session/peer to talk to, or a
                               local MOVE/RESTORE is in flight -- app.c's
                               own send_local_chat guard, checked here
                               instead since Sprinter has no separate
                               input_submit dispatcher (net_chat_blocked,
                               session_sprinter.c). */
                            key_code = 0u;
                            if (!net_active) {
                                spectrum_gui_notify("Not connected", 0u);
                            } else if (!netchesszx_session_peer_ready_state) {
                                spectrum_gui_notify("Waiting for opponent", 0u);
                            } else if (net_chat_blocked()) {
                                spectrum_gui_notify(NOTICE_WAITING_FOR_ACK, 0u);
                            } else {
                                chat_open();
                                chat_input_mode = 1u;
                                spectrum_gui_notify("Type chat", 0u);
                            }
                        } else if (key == KEY_CANCEL) {
                            /* ESC on the plain board screen (fileui/chat/
                               menu all intercept ESC themselves above, so
                               this is only ever reached with none of them
                               open): arm the exit prompt. is_error=1 makes
                               it red and persistent (ticks=0), same as
                               app.c's own notify_error_msg for a CONFIRM
                               prompt -- it does not auto-expire, it waits
                               for Y or N. A repeat of this same ESC lands
                               in the exit_confirm branch above instead,
                               which re-paints the prompt rather than
                               answering it (see there for why). */
                            key_code = 0u;
                            exit_confirm = 1u;
                            spectrum_gui_notify(exit_prompt_msg, 1u);
                        } else {
                            /* S8 step 4: not a menu key -- gui.c returned it
                               unchanged (menu closed or not one of its keys).
                               net_control_key clears key_code itself only if
                               it actually consumes 'd'/'y'/'n', so an ordinary
                               board key (space, arrows) still reaches
                               board_cursor_move/board_select_or_move below
                               exactly as before. */
                            net_control_key(key);
                        }
                    }
                }
            }
            board_cursor_move();
            board_select_or_move();
            if (key == 0u) {
                break;                  /* keyboard queue empty */
            }
            key_code = 0u;
            --keys_left;
            if (keys_left == 0u) {
                break;
            }
        }

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

        /* S7 step 5: the DIRECT session, when there is one. Deliberately
           last in the frame, after every local effect has been applied and
           painted -- an incoming move should never race a local one that
           was made in the same frame. Costs nothing in hot-seat mode.
           S8 step 3: net_retry_tick runs after net_poll_once, not before --
           an ACK/NACK that arrived THIS frame must resolve pending_local_ply
           before the retry countdown looks at it, so a reply already in
           hand is never raced by a redundant retransmit. Re-checking
           net_active is deliberate: net_poll_once/net_apply_pending_local_
           move can drop the session (net_drop) inside this same call. */
        if (net_active) {
            net_poll_once();
        }
        if (net_active) {
            net_retry_tick();
        }
    }
}
