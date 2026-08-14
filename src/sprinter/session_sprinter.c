/* Networked-session / event / control driver, moved off WIN1 onto the WIN3
 * cold page (S8's own byte-budget relief pass -- the plan's original step 2,
 * "the driver moves to the cold page", was deferred while steps 3-6 grew
 * main.c straight into the ceiling instead; this is that deferred move,
 * done now because step 8's MQTT half needs WIN1 headroom neither
 * ad-hoc net_frame_c relief nor the OVL_SLOT lever has left to give -- see
 * docs/sprinter-testnotes/S8.md's "Byte budget, honestly" section).
 *
 * Everything here is a VERBATIM relocation of src/sprinter/main.c's own
 * DIRECT-session/board-interaction/menu-action code (board_select_or_move
 * through handle_menu_action, S7 step 5 through S8 step 6) -- no logic
 * changed, only where it lives and how the two remaining WIN1 call sites
 * reach it. It is exactly as safe as gui.c's own S7 step 5 move onto this
 * same page: the cold page already calls back into resident code today
 * (three render_shim.asm bridges, one resident data byte), and this file
 * needs nothing gui.c had not already proven -- tools/gen_sprinter_cold_
 * defs.py's own header explains why a resident symbol's address, once
 * resident_c.bin is built, can be baked into the cold page as a plain
 * `defc` alias with zero WIN1 cost.
 *
 * WIN1 (main.c) still owns: `net_active` itself (read every frame by the
 * two `if (net_active)` guards around net_poll_once/net_retry_tick below --
 * the one piece of this file's state WIN1 reads directly, so it cannot
 * live in cold-page BSS, per fixed_layout.json's own "global data WIN1
 * reads cannot live in the cold page" rule) and seven entry points this
 * file now defines with external linkage instead of `static`:
 * board_select_or_move, net_poll_once, net_retry_tick, fileui_process_key,
 * handle_menu_action, net_control_key, net_set_turn_label_from_side (the
 * last called once at boot, the other six from the frame loop). Calling
 * side is UNCHANGED -- tools/gen_sprinter_cold_thunks.py publishes each
 * under the exact same name it had as a resident function, so main.c's own
 * call sites needed no edits beyond an extern prototype.
 *
 * Every other identifier below (pending_local_ply, control_pending,
 * takeback_*, restore_*, menu_theme_index, net_ping, ...) is now cold-page
 * BSS, private to this file -- nothing outside it ever read them directly
 * (mechanically confirmed against resident_c.map before the move: the only
 * WIN1-side reference to anything in this file's old scope was net_active
 * itself). Calls out to board.c, gui_log_sprinter.c, saveload.c, restore.c,
 * fileui.c, config/session.c, session/{event,ping,direct,outgoing,poll}.c
 * and platform/text.c -- every one of them stays WIN1-resident (moving
 * them too was already tried for session/{ping,direct,outgoing}.c during
 * step 6 and reverted, net_frame_c's own ~4 KiB ceiling) -- reach their
 * resident entry points through the same defc-bridge tools/gen_sprinter_
 * cold_defs.py already used for netchesszx_movement_hints; the extern
 * declarations below (mirroring main.c's own former ad-hoc style for the
 * same symbols) are that bridge's C-side half. render_core.asm/gui.c calls
 * (render_board_full, spectrum_gui_notify, ...) are NOT bridged -- both
 * are linked into this SAME cold-page image, so those are plain same-page
 * calls, identical cost to any other function call in this file.
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
#include "spectrum/overlay/overlay_context.h"
#include "common/chess/rules_compact.h"
#include "spectrum/ui/gui.h"
#include "spectrum/ui/info_panel.h"
#include "spectrum/saveload/saveload.h"
#include "spectrum/restore/restore.h"
#include "spectrum/fileui/fileui.h"

#include <string.h>

/* Bridged resident symbols this file calls but does not itself define --
 * render_core.asm/gui.c entries are NOT here (same cold-page image, plain
 * calls); everything below is WIN1-resident, reached via tools/gen_
 * sprinter_cold_defs.py's COLD_RESIDENT_SYMBOLS (net_active plus the whole
 * board.c/gui_log_sprinter.c/saveload.c/restore.c/fileui.c/config/
 * session.c/session-layer surface this file needs). Declared as plain
 * externs, the same ad-hoc style main.c used for the render_core.asm/
 * gui_log_sprinter.c entries it once declared itself (lines 118-155 of
 * that file before this move) -- these are not part of any shared header
 * because, before this file existed, nothing else needed to see them. */
extern void render_board_full(void);
extern void render_coord_labels(void);
extern void render_cursor_marker(void);
extern void render_select_marker(void);
extern void render_square_marked(unsigned char index) __z88dk_fastcall;
extern void spectrum_gui_reset_move_log(void);
extern uint16_t spectrum_gui_log_ply_get(void);
extern void spectrum_gui_log_ply_set(uint16_t ply);
extern unsigned char key_code;

/* WIN1 (main.c): the one piece of this file's state the resident frame
 * loop reads directly (see this file's own header for why it cannot move
 * here too). Bridged like any other resident data symbol -- see
 * netchesszx_movement_hints (spectrum/config/session.c) for the
 * established precedent this follows. */
extern unsigned char net_active;

#define NO_SQUARE 0xFFu
#define KEY_SELECT 32u          /* space -- app.c's own select/move key */

/* Fixed WIN2 low-RAM cells shared with render_core.asm (see main.c's own
 * historical comment on selected_row, unchanged by this move -- render_
 * core.asm still owns the cells, this file still owns the selection
 * policy). No static initialiser: main.c's main() seeds them at boot,
 * before this file's first caller can run. */
#define cursor_row \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 1))
#define cursor_col \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 2))
#define selected_row \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 3))
#define selected_col \
    (*(unsigned char *)(NETCHESSZX_LOWRAM_RENDER_SHARED_ADDR + 4))

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

unsigned char square_index(unsigned char row, unsigned char col) {
    return (unsigned char)((row << 3) + col);
}

/* S8 step 3: forward declarations for what board_select_or_move (below)
   needs from the "DIRECT session" section further down this file -- same
   convention the S7 net_active/net_send_local_move forward declaration
   already used. pending_local_ply/pending_local_move/pending_retry_timer
   are declared (not just forward-declared) here, not there, since a
   static file-scope variable needs its one tentative definition to
   precede every use, not merely a prototype. PENDING_RETRY_TICKS (app.c's
   own non-NETCHESSZX_HOST_SESSION_TEST value: retransmit a pending
   outgoing MOVE/control/etc. after this many idle frame-loop ticks with no
   ACK/NACK) is a #define, so it must textually precede this same use --
   not Hz-derived, app.c uses the same raw tick count regardless of ZX's
   50 Hz vs Next's 50/60 Hz, and this port's frame rate is close enough
   that re-deriving it is not worth a second constant. */
#define PENDING_RETRY_TICKS 120u
extern uint16_t pending_local_ply;
extern char pending_local_move[6];
extern unsigned char pending_retry_timer;
extern unsigned char net_send_move_wire(uint16_t ply, const char *move);
void net_drop(const char *why);

/* S8 step 4 (app.c's CONTROL_PENDING_*, reduced): a local RESET request or
   DRAW offer we are waiting on, or a DRAW offer the peer sent us that we
   have not answered yet. docs/session-core-contract.md's one-operation
   invariant ("only one control operation may be pending... a fresh RESET
   or DRAW which would create a second operation is NACKed BUSY") is what
   makes a single flag enough -- the same invariant pending_local_ply
   itself already relies on. board_select_or_move needs control_pending in
   scope too: app.c's own send_local_move refuses to send a MOVE while any
   control op is pending, and this port matches that.

   Deliberately NOT ported from app.c: CONTROL_PENDING_RESET_WAIT/
   _DRAW_WAIT (a long silent second wait tier after the retry budget is
   spent, ~150s, before finally cancelling) and the crossed-RESIGN/
   crossed-DRAW tie-break arithmetic (both need RESIGN's own game-over
   state, which does not exist on Sprinter yet). This port retries
   CONTROL_REPLY_RETRIES times at PENDING_RETRY_TICKS apart, then cancels
   outright -- simpler, and it tells the player something within ~12s
   rather than leaving them in limbo for two and a half minutes; recorded
   as a deliberate reduction, not an oversight. Incoming RESET is still
   auto-accepted unconditionally, exactly as it already was before S8 --
   that pre-existing behaviour is not a contract violation (nothing in the
   contract mandates a confirmation prompt, only correct wire semantics)
   and changing it is out of this step's scope. */
#define CONTROL_PENDING_NONE 0u
#define CONTROL_PENDING_RESET 1u
#define CONTROL_PENDING_DRAW_SENT 2u
#define CONTROL_PENDING_DRAW_INCOMING 3u
/* app.c's own CONTROL_REPLY_RETRIES. */
#define CONTROL_REPLY_RETRIES 5u
static unsigned char control_pending;
extern unsigned char control_retry_count;

/* S8 step 5 (app.c's takeback_pending_ply/takeback_snapshot_local): one
   variable pair does double duty for both directions, exactly matching
   app.c's own implicit design -- takeback_pending_ply != 0 means
   "something takeback-shaped is in flight"; takeback_snapshot_local (which
   ALSO always reflects "was the last applied move mine", independent of
   whether a takeback is pending) tells which direction: local==1 means
   this is MY OWN request, awaiting the peer's ACK/NACK; local==0 means the
   PEER asked to take back the move I just recorded as theirs, awaiting my
   y/n. board_select_or_move needs both in scope (a MOVE cannot be sent
   while either is true, matching app.c's own send_local_move guard).
   spectrum_board_undo_t is a 5-byte single-ply undo record (board.h) --
   takeback only ever unwinds the single most recent move, never a whole
   history, matching the wire contract's own "one-ply undo snapshot"
   language. */
extern spectrum_board_undo_t takeback_undo;
extern uint16_t takeback_snapshot_ply;
extern unsigned char takeback_snapshot_local;
static uint16_t takeback_pending_ply;
static uint16_t last_accepted_takeback_ply;

static void takeback_clear(void) {
    takeback_snapshot_ply = 0u;
    takeback_snapshot_local = 0u;
    takeback_pending_ply = 0u;
    last_accepted_takeback_ply = 0u;
}

void takeback_snapshot_save(uint16_t ply, unsigned char local_move) {
    takeback_snapshot_ply = ply;
    takeback_snapshot_local = local_move;
    last_accepted_takeback_ply = 0u;
}

/* S8 step 6 (app.c's restore_rx_mask, reduced): the DIRECT counterpart of
   loading a save file while a peer is connected -- not a join-time state
   sync (that would need SETUP's restore-on-connect flow, S9 scope), but
   what ZX's fileui LOAD action already does: local_load_game (further
   down) pushes the loaded position to the peer instead of applying it
   locally when net_active, and the peer can push one to Sprinter the same
   way. Wire shape is docs/wire-contract.md's own MQTT RESTORE section
   (RQ -> RY/RN -> RS00 -> RS01 -> RA/RN) -- the grammar is target-neutral
   ("RESTORE remains core session policy for both DIRECT and MQTT",
   docs/session-core-contract.md:527), only MQTT's "host only" restriction
   does not apply here.

   saveload_b64_pending (further down, S6) is reused as the wire workspace
   -- the same "shared retry workspace" the contract's own CHAT-blocking
   language describes, not a second 60-byte buffer. restore_chunk_have
   tracks which of the two 30-byte halves have arrived, bit0=RS00,
   bit1=RS01 -- both fixed at exactly two chunks (docs/wire-contract.md),
   so this needs no bitmask helper the way an arbitrary-N-chunk protocol
   would. */
#define RESTORE_TX_PENDING 0x01u    /* sent RQ, waiting for RY/RN */
#define RESTORE_TX_AWAIT_ACK 0x02u  /* sent both chunks, waiting for RA/RN */
#define RESTORE_RX_RECEIVE 0x04u    /* sent RY, waiting for the two chunks */
#define RESTORE_RX_APPLIED 0x08u    /* applied; a matching resend re-ACKs
                                        RA, a conflicting one NACKs, neither
                                        re-decodes (docs/session-core-
                                        contract.md's accepted-restore
                                        duplicate latch) */
extern unsigned char restore_rx_mask;
static unsigned char restore_chunk_have;
/* RQ arrived, awaiting the local player's y/n -- app.c's own implicit
   confirm_action==CONFIRM_RESTORE_ACCEPT-with-no-mask-bit-yet state, made
   explicit here the same way draw/takeback's incoming prompts are. */
static unsigned char restore_prompt_pending;

static void restore_net_clear(void) {
    restore_rx_mask = 0u;
    restore_chunk_have = 0u;
    restore_prompt_pending = 0u;
}

/* Shared one-operation-pending guard (docs/session-core-contract.md):
   true while a MOVE, RESET/DRAW, takeback, or RESTORE exchange is already
   in flight, so a fresh local action must wait rather than starting a
   second one. Every local trigger site (board_select_or_move,
   menu_reset_game, net_draw_offer, net_takeback_request,
   local_load_game) shares this one check instead of repeating the same
   five-way comparison. */
unsigned char net_op_busy(void) {
    return (unsigned char)(pending_local_ply != 0u ||
        control_pending != CONTROL_PENDING_NONE ||
        takeback_pending_ply != 0u || restore_rx_mask != 0u ||
        restore_prompt_pending);
}

/* Repeated at every "a move just landed" site (7 of them across S8 steps
   3/5/6) -- one shared call instead of the same three-line ternary each
   time. */
void net_set_turn_label_from_side(void) {
    spectrum_gui_set_turn_label(side_to_move == NETCHESSZX_RULE_WHITE
                                     ? SPECTRUM_GUI_TURN_WHITE
                                     : SPECTRUM_GUI_TURN_BLACK);
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

void selection_clear(void) {
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

void board_select_or_move(void) {
    char move[6];
    char piece;

    if (key_code != KEY_SELECT) {
        return;
    }
    key_code = 0u;              /* read-and-clear, like board_cursor_move */

    piece = spectrum_board_cell(cursor_row, cursor_col);

    /* Hot-seat plays both sides at one keyboard; a DIRECT session does not.
       This is the only place the two modes differ before the move is made,
       and it is a refusal rather than a filter on purpose: the tester needs
       to be told why the press did nothing (invisible modal state is a bug
       this port has already shipped once). */
    if (net_active && !netchesszx_session_has_local_turn(
            (unsigned char)(side_to_move == NETCHESSZX_RULE_WHITE))) {
        spectrum_gui_notify("Not your turn", 0u);
        return;
    }

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

    /* S8 step 3: a networked move is SENT here but not yet APPLIED --
       docs/session-core-contract.md:265-267 requires the board to wait for
       the peer's numeric ACK (net_apply_pending_local_move, net_handle_
       event's ACK_MOVE branch). Hot-seat (below) is untouched: both sides
       are at the same keyboard, so there is no peer to wait for and no
       contract that applies. */
    if (net_active) {
        if (net_op_busy()) {
            /* A previous move, a RESET/DRAW request, a takeback, or a
               RESTORE exchange is still in flight -- app.c's own
               send_local_move guard (control_pending, then
               pending_local_ply/takeback_pending_ply, checked before ever
               computing a move; restore_rx_mask/restore_prompt_pending
               are S8 step 6's own addition to the same one-operation
               invariant). Keep the selection so the player can simply try
               again once it resolves. */
            spectrum_gui_notify("Waiting for ACK", 0u);
            return;
        }
        {
            uint16_t ply = (uint16_t)(spectrum_gui_log_ply_get() + 1u);
            unsigned char from = square_index(selected_row, selected_col);

            if (!net_send_move_wire(ply, move)) {
                net_drop("Link down");
                return;
            }
            pending_local_ply = ply;
            (void)spectrum_append_text(pending_local_move, move);
            pending_retry_timer = PENDING_RETRY_TICKS;
            control_retry_count = 0u;

            selected_row = NO_SQUARE;
            selected_col = NO_SQUARE;
            render_square_marked(from);    /* clears the selection highlight
                                               only -- board content at
                                               `from` is unchanged until the
                                               move is actually applied */
            spectrum_gui_notify_persistent(move);
        }
        return;
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
        net_set_turn_label_from_side();

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
extern spectrum_board_snapshot_t saveload_snapshot;
extern char saveload_b64_pending[NETCHESSZX_SAVE_WIRE_B64_SIZE];

/* Bridged from main.c (WIN1): net_handle_event's RESTORE_RS branch (below)
 * shares this exact "apply a decoded snapshot" path with main.c's own
 * local_load_game -- see that function's own comment (main.c) for why it
 * stayed resident (net_op_busy/restore_rx_mask, both bridged the other
 * direction) while this caller did not move with it. */
extern void net_apply_loaded_snapshot(const netchesszx_save_meta_t *meta);

/* Bridged from main.c (WIN1): menu_network (below) closes the join screen
 * through the same full board-area repaint local_load_game/fileui_open/
 * fileui_close use -- see saveload_full_redraw's own comment (main.c) for
 * why it stayed with them rather than moving back here. */
extern void saveload_full_redraw(void);

/* Bridged from main.c (WIN1): handle_menu_action's THEME/FLIP/ABOUT tabs
 * (below) -- none of the three touch net_active-guarded state, so they
 * moved back to WIN1 with the rest of the save/load section in the second
 * relief cut (main.c's own comment ahead of pending_local_ply). */
extern void menu_cycle_theme(void);
extern void menu_flip_board(void);
extern void menu_not_available(void);

/* Bridged from main.c (WIN1): handle_menu_action's FILE tab (below) --
 * fileui_open moved back with the rest of the file-browser code (main.c's
 * own local_load_game/fileui_process_key own the rest of that flow). */
extern void fileui_open(void);

/* Bridged from main.c (WIN1): a third relief cut moved the takeback-apply/
 * move-send/move-repaint cluster back too, once the second cut alone still
 * left the cold page 441 bytes over its fixed 16 KiB ceiling. None of the
 * six touch net_active/control_pending/restore_chunk_have/_prompt_pending/
 * net_ping -- only takeback_undo/_snapshot_ply/_local (moved with them,
 * see main.c's own comment ahead of their declarations) and the eight
 * already-bridged
 * variables from the second cut. Every one of these still has at least one
 * caller here (net_handle_event, net_apply_remote_move, net_takeback_reply,
 * retry_pending_outgoing, net_drop, net_takeback_request) -- that is why
 * they need a prototype instead of just disappearing from this file. */
extern unsigned char net_send_move_wire(uint16_t ply, const char *move);
extern unsigned char net_send_nack_sync(const char *ply);
extern void net_repaint_move(const char *move);
extern void net_apply_pending_local_move(void);
extern unsigned char net_send_takeback_wire(uint16_t ply);
extern void apply_takeback_snapshot(void);
extern void net_status_idle(void);

#define NET_HELLO_REANNOUNCE_TICKS 80u
/* PENDING_RETRY_TICKS itself is defined earlier in this file, next to
   board_select_or_move's forward declarations -- that function (which
   comes first) is the initial arm site, board_select_or_move needs the
   constant in scope there too. */

/* net_gate.asm (WIN2). Only the teardown half is needed here -- bringing
   the backend up is net_ui_sprinter.c's job (it owns the screen while it
   blocks), and this file never sees the DLL. */
extern void ng_close(void);

/* src/sprinter/net_ui_sprinter.c, in the WIN3 cold page: the whole modal
   join screen (preflight, connect, retry/cancel) behind one call. */
extern unsigned char spectrum_net_join_ui(void);

static netchesszx_session_ping_t net_ping;
static unsigned char net_hello_wait;
static unsigned char net_peer_known;

/* S8 step 3: the local half of the deferred-apply model. pending_local_ply/
   pending_local_move/pending_retry_timer are declared earlier in this file
   (with board_select_or_move's other forward declarations -- that
   function needs them and comes first). game_ply itself is NOT duplicated
   here -- gui_log_sprinter.c's own spectrum_gui_log_ply_get()/_set()
   already is the true half-move counter (incremented exactly once per
   applied move, local or remote, see that file's own header), so it plays
   app.c's game_ply role directly. pending_retry_timer counts idle
   frame-loop ticks down from PENDING_RETRY_TICKS to the next retransmit;
   net_retry_tick owns it. */

void pending_local_clear(void) {
    pending_local_ply = 0u;
    pending_local_move[0] = '\0';
}

/* app.c's own parse_u16: a thin wrapper so call sites read as a value
   rather than an out-parameter -- 0 for "not a valid decimal token",
   which this protocol never uses as a real ply (ply numbers start at 1). */
static uint16_t net_parse_u16(const char *text) {
    uint16_t value = 0u;

    return netchess_mqtt_session_parse_u16_token(text, &value) == 0
               ? 0u : value;
}

/* The CONTROL_PENDING_* constants, control_pending and control_retry_count
   are declared earlier in this file, with board_select_or_move's other
   forward declarations -- that function guards a fresh MOVE send on
   control_pending too (app.c's own send_local_move does the same). */

static void control_pending_clear(void) {
    control_pending = CONTROL_PENDING_NONE;
    control_retry_count = 0u;
}

/* Shared by both reset paths: a peer-initiated RESET (auto-accepted) and a
   locally-initiated one once the peer's ACK RESET arrives -- both sides
   always end up here, whichever one asked. */
static void net_apply_reset(void) {
    pending_local_clear();
    control_pending_clear();
    takeback_clear();
    restore_net_clear();
    spectrum_board_reset();
    selection_clear();
    render_board_full();
    render_cursor_marker();
    spectrum_gui_reset_move_log();
    spectrum_gui_game_timer_start();
    spectrum_gui_set_turn_label(SPECTRUM_GUI_TURN_WHITE);
    spectrum_gui_notify_persistent("New game");
}

/* Shared by net_handle_event's ACK_DRAW branch (we offered, peer
   accepted) and its crossed-DRAW branch (both offered -- see
   NETCHESSZX_SESSION_EVENT_DRAW's own comment): the side whose offer was
   just accepted drives the post-draw rematch RESET. */
static void net_draw_start_rematch(void) {
    control_pending = CONTROL_PENDING_RESET;
    control_retry_count = 0u;
    pending_retry_timer = PENDING_RETRY_TICKS;
    spectrum_gui_notify_persistent("Draw agreed - new game");
    if (!spectrum_link_send_text(NETCHESS_PROTO_RESET)) {
        net_drop("Link down");
    }
}

/* S8 step 5 (app.c's apply_takeback_snapshot, reduced): unwind the single
   most recent move via its captured undo record. Caller's responsibility
   to have already decided this is valid and to clear takeback_pending_ply
   -- this function only ever touches takeback_snapshot_*, matching
   pending_local_clear/control_pending_clear's own narrow scope. A full
   board repaint (not a two-square net_repaint_move) because the undone
   move might have been a castle or an en-passant capture, touching more
   than the two squares its own coordinate string names. */
/* Every exit from a session lands here: the link is already gone (or is
   being given up on), so this only has to make the local state honest
   again. ng_close is idempotent (unet.inc), so calling it after a link the
   peer already dropped is fine. pending_local_clear/control_pending_clear/
   takeback_clear/restore_net_clear (S8 steps 3/4/5/6): a half-sent move,
   an outstanding RESET/DRAW, a pending takeback, or a RESTORE exchange
   must not survive into the next session -- there is no peer left to
   ACK/NACK it, and stale pending state would silently block every local
   action after a reconnect. */
void net_drop(const char *why) {
    net_active = 0u;
    net_peer_known = 0u;
    pending_local_clear();
    control_pending_clear();
    takeback_clear();
    restore_net_clear();
    netchesszx_session_peer_reset();
    ng_close();
    net_status_idle();
    spectrum_gui_notify(why, 1u);
}

/* "MOVE <ply> <coords>" -- byte-for-byte app.c's own send_move_wire
   (src/spectrum/app/app.c), built with the same two append helpers rather
   than game_protocol_format.c's netchess_proto_format_move: that TU is not
   linked on any Spectrum-family target, and pulling it in for one caller
   would cost more than the six lines below. Unlike the S7 shape this
   replaces (net_send_local_move), ply is now an explicit argument rather
   than read from gui_log_sprinter.c's counter after the fact -- S8 step 3's
   deferred-apply model sends the move BEFORE it is applied/logged, and
   retry_pending_outgoing below reuses this same function to retransmit. */
/* "RS0<chunk> " + 30 bytes of saveload_b64_pending -- byte-for-byte the
   wire shape src/common/session/session.c's session_build_restore_chunk
   proves (the canonical reducer's own helper): a 5-byte header, then
   exactly the 30-byte half the chunk digit selects, no NUL on the wire. */
static unsigned char net_send_restore_chunk(unsigned char chunk) {
    char payload[36];

    payload[0] = 'R';
    payload[1] = 'S';
    payload[2] = '0';
    payload[3] = (char)('0' + chunk);
    payload[4] = ' ';
    memcpy(payload + 5, saveload_b64_pending + (chunk == 0u ? 0u : 30u), 30);
    payload[35] = '\0';
    return spectrum_link_send_text(payload);
}

/* Sends both chunks in order -- docs/wire-contract.md: "while waiting for
   RA, it retries the two chunks in order", the same shape on every retry
   as on the first send. */
static unsigned char restore_send_chunks(void) {
    if (!net_send_restore_chunk(0u)) {
        return 0u;
    }
    return net_send_restore_chunk(1u);
}

/* app.c's retry_pending_outgoing. S8 step 4 added the two control_pending
   branches; step 5 added takeback (only ever retransmitted by the side
   that SENT the request -- takeback_snapshot_local==1 -- an incoming
   request awaiting our own y/n has nothing to retransmit, the peer is the
   one on a timer); step 6 adds RESTORE the same way (RESTORE_TX_PENDING
   retransmits RQ, RESTORE_TX_AWAIT_ACK retransmits both chunks -- an
   incoming exchange, RESTORE_RX_RECEIVE, has nothing to retransmit
   either, the sender drives it). This function is meant to grow, not be
   replaced. Order matters only in that at most one branch can ever be
   true at once (the one-operation-pending invariant, guarded at every
   site that sets one of these). */
static unsigned char retry_pending_outgoing(void) {
    if (pending_local_ply != 0u) {
        return net_send_move_wire(pending_local_ply, pending_local_move);
    }
    if (control_pending == CONTROL_PENDING_RESET) {
        return spectrum_link_send_text(NETCHESS_PROTO_RESET);
    }
    if (control_pending == CONTROL_PENDING_DRAW_SENT) {
        return spectrum_link_send_text(NETCHESS_PROTO_DRAW);
    }
    if (takeback_pending_ply != 0u && takeback_snapshot_local) {
        return net_send_takeback_wire(takeback_pending_ply);
    }
    if ((restore_rx_mask & RESTORE_TX_PENDING) != 0u) {
        return spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RQ);
    }
    if ((restore_rx_mask & RESTORE_TX_AWAIT_ACK) != 0u) {
        return restore_send_chunks();
    }
    return 1u;
}

static unsigned char local_retry_pending(void) {
    return (unsigned char)(pending_local_ply != 0u ||
        control_pending == CONTROL_PENDING_RESET ||
        control_pending == CONTROL_PENDING_DRAW_SENT ||
        (takeback_pending_ply != 0u && takeback_snapshot_local) ||
        (restore_rx_mask & (RESTORE_TX_PENDING | RESTORE_TX_AWAIT_ACK)) != 0u);
}

/* S8 step 4: the retry budget ran out (CONTROL_REPLY_RETRIES retransmits,
   ~12s at PENDING_RETRY_TICKS apart) with no ACK/NACK at all -- not a
   rejection, just silence. A pending RESET/DRAW is withdrawn with its own
   CANCEL verb so the peer's (if any) incoming-offer prompt clears too; a
   pending RESTORE request (step 6) is withdrawn the same way, but only
   before any chunk has gone out (docs/wire-contract.md: "after chunk
   transmission starts, local cancel is ignored" -- once
   RESTORE_TX_AWAIT_ACK, falls to the net_drop below, same as a stuck
   MOVE/takeback). A pending MOVE/takeback/in-flight-restore has no
   peer-visible state to unwind, and app.c's own shape treats an
   unanswered one past this budget the same as a dead link (a peer that
   stops responding to everything is not distinguishable from a lost link
   at the protocol level). Best-effort on the CANCEL/RN send -- if the
   link is actually down, poll.c's own liveness timeout will reach the
   same conclusion independently. */
static void net_give_up_pending(void) {
    if (control_pending == CONTROL_PENDING_RESET) {
        control_pending_clear();
        (void)spectrum_link_send_text(NETCHESS_PROTO_CANCEL_RESET);
        spectrum_gui_notify("Reset cancelled", 1u);
        return;
    }
    if (control_pending == CONTROL_PENDING_DRAW_SENT) {
        control_pending_clear();
        (void)spectrum_link_send_text(NETCHESS_PROTO_CANCEL_DRAW);
        spectrum_gui_notify("Draw cancelled", 1u);
        return;
    }
    if ((restore_rx_mask & RESTORE_TX_PENDING) != 0u) {
        restore_net_clear();
        (void)spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RN);
        spectrum_gui_notify("Load cancelled", 1u);
        return;
    }
    net_drop("Link down");
}

/* Called once per frame while net_active (main frame loop, below). Cheap
   when idle: one comparison. app.c's own PENDING_RETRY_TICKS cadence,
   re-armed on every fresh send (board_select_or_move and the control
   triggers further down) as well as here. */
void net_retry_tick(void) {
    if (!local_retry_pending()) {
        pending_retry_timer = 0u;
        control_retry_count = 0u;
        return;
    }
    if (pending_retry_timer != 0u) {
        --pending_retry_timer;
        return;
    }
    pending_retry_timer = PENDING_RETRY_TICKS;
    if (control_retry_count >= CONTROL_REPLY_RETRIES) {
        net_give_up_pending();
        return;
    }
    ++control_retry_count;
    if (!retry_pending_outgoing()) {
        net_drop("Link down");
    }
}

static void net_apply_remote_move(const char *payload) {
    char ply[6];
    char move[6];
    char notation[8];
    uint16_t incoming_ply;

    if (!netchess_proto_parse_move(payload, ply, sizeof(ply),
                                   move, sizeof(move),
                                   notation, sizeof(notation))) {
        return;                 /* malformed line: not a move, not an event */
    }
    incoming_ply = net_parse_u16(ply);
    if (incoming_ply == 0u) {
        spectrum_gui_notify("Bad move", 1u);
        (void)netchesszx_session_send_nack_move(ply);
        return;
    }
    /* The peer missed our ACK and retransmitted an already-applied move:
       re-ACK without re-applying (docs/session-core-contract.md's
       accepted-ply latch/idempotent-re-ACK requirement). */
    if (incoming_ply <= spectrum_gui_log_ply_get()) {
        if (!netchesszx_session_send_ack_move(ply)) {
            net_drop("Link down");
        }
        return;
    }
    /* S8 steps 4/5/6 (app.c's own guard): a RESET/DRAW request, a
       takeback, or a RESTORE exchange is outstanding -- a MOVE cannot be
       evaluated against a board that might be about to reset, unwind, or
       be replaced out from under it. */
    if (control_pending != CONTROL_PENDING_NONE || takeback_pending_ply != 0u ||
        restore_rx_mask != 0u || restore_prompt_pending) {
        spectrum_gui_notify("Waiting for ACK", 1u);
        (void)netchesszx_session_send_nack_move(ply);
        return;
    }
    /* Crossed with our own pending local move (app.c's own
       pending_local_ply handling in its incoming-MOVE path): the same move
       arriving back is a duplicate, ignored outright; the peer's next ply
       resolves our pending send as if it had been ACKed, then falls
       through to be evaluated against the now-updated board. Anything else
       means the peer moved before resolving ours -- NACK and wait. */
    if (pending_local_ply != 0u) {
        if (incoming_ply == pending_local_ply &&
            strcmp(move, pending_local_move) == 0) {
            return;
        }
        if (incoming_ply == (uint16_t)(pending_local_ply + 1u)) {
            net_apply_pending_local_move();
        }
        if (pending_local_ply != 0u) {
            spectrum_gui_notify("Waiting for ACK", 1u);
            (void)netchesszx_session_send_nack_move(ply);
            return;
        }
    }
    if (netchesszx_session_has_local_turn(
            (unsigned char)(side_to_move == NETCHESSZX_RULE_WHITE))) {
        spectrum_gui_notify("Opponent's turn", 1u);
        (void)netchesszx_session_send_nack_move(ply);
        return;
    }
    if (incoming_ply != (uint16_t)(spectrum_gui_log_ply_get() + 1u)) {
        spectrum_gui_notify("Bad move", 1u);
        if (!net_send_nack_sync(ply)) {
            net_drop("Link down");
        }
        return;
    }
    /* The peer is not trusted to have checked its own move: this port runs
       the same RULES overlay against it that a local move goes through,
       and NACKs rather than corrupting the board. That is the contract
       (docs/session-core-contract.md), not extra caution. S8 step 5: the
       _with_undo variant captures the one-ply undo record here too -- this
       is the remote-apply site, net_apply_pending_local_move is the
       other. */
    if (!spectrum_board_is_legal_move(move) ||
        !spectrum_board_apply_trusted_move_with_undo(move, &takeback_undo)) {
        (void)netchesszx_session_send_nack_move(ply);
        spectrum_gui_notify("Peer sent an illegal move", 1u);
        return;
    }
    selection_clear();
    net_repaint_move(move);
    spectrum_gui_move_timer_reset();
    net_set_turn_label_from_side();
    spectrum_gui_notify_persistent(notation[0] != '\0' ? notation : move);
    spectrum_gui_add_move(ply, move);
    takeback_snapshot_save(incoming_ply, 0u);
    if (!netchesszx_session_send_ack_move(ply)) {
        net_drop("Link down");
    }
}

/* The peer's HELLO is what settles which colour this side plays, so the
   board view can only be oriented once it arrives -- until then the board
   is drawn white-at-the-bottom, which is also what a JOIN playing white
   will keep. */
static void net_apply_hello(const char *payload) {
    if (!netchesszx_session_direct_apply_hello(payload)) {
        /* Saying nothing here is what made the 2026-08-13 round
           unreadable: a refused HELLO left the screen looking exactly like
           a peer that had never answered, so a colour disagreement and a
           dead RX path were the same picture. Now they are not -- silence
           still means nothing arrived, and this notice means something
           did and we turned it down. */
        spectrum_gui_notify("Bad HELLO from opponent", 1u);
        return;
    }
    net_peer_known = 1u;
    netchesszx_session_peer_mark_ready();
    spectrum_link_direct_peer_mark_valid();
    /* Every accepted HELLO starts a fresh session from this side's point of
       view -- JOIN is the only role this port supports (S9's SETUP scope),
       so there is no "resume the same game" case to special-case here.
       Found by MAME testing (2026-08-14): a host-side Disconnect, then a
       fresh reconnect into a NEW host game, left Sprinter showing the OLD
       board/move-list from the session that just ended -- net_apply_hello
       used to only re-orient and repaint whatever spectrum_board already
       held. Worse than cosmetic: the new game's own MOVE 1 then looked
       like an already-applied duplicate of the stale ply counter
       (net_apply_remote_move's `incoming_ply <= spectrum_gui_log_ply_get()`
       guard) and got silently re-ACKed instead of applied -- the client
       would stay frozen on the old position until the new game's ply
       count caught up past the old one. Mirrors net_apply_reset's own
       reset sequence (that function's in-session RESET counterpart to
       this one's join-time reset), minus the "New game" notice this
       function already has its own success notice for. */
    pending_local_clear();
    control_pending_clear();
    takeback_clear();
    restore_net_clear();
    spectrum_board_reset();
    selection_clear();
    spectrum_gui_set_board_view((unsigned char)(!netchesszx_local_is_white()));
    render_board_full();
    render_coord_labels();
    render_select_marker();
    render_cursor_marker();
    spectrum_gui_reset_move_log();
    spectrum_gui_game_timer_start();
    net_set_turn_label_from_side();
    spectrum_gui_set_status(netchesszx_local_side_name());
    spectrum_gui_notify_success("Opponent ready");
}

static void net_handle_event(unsigned char event, const char *payload) {
    if (event == NETCHESSZX_SESSION_EVENT_DIRECT_HELLO) {
        net_apply_hello(payload);
        return;
    }
    /* Before the peer has identified itself there is no agreed colour, so
       acting on game traffic would be acting on a guess. ZX's own loop
       makes the same cut (its `!netchesszx_session_peer_ready_state`
       continue). */
    if (!net_peer_known) {
        return;
    }
    if (event == NETCHESSZX_SESSION_EVENT_MOVE) {
        net_apply_remote_move(payload);
    } else if (event == NETCHESSZX_SESSION_EVENT_ACK_MOVE) {
        /* S8 step 3: the board is not touched here directly any more --
           net_apply_pending_local_move does that, and its own
           spectrum_gui_notify_persistent(move) is the success feedback
           (the move text landing on the notice line), replacing the old
           generic "Move acknowledged". S8 step 5: the same ACK verb also
           carries a takeback's own ply-as-token (net_takeback_request
           sends "TAKEBACK <ply>", the reply is the generic ACK/NACK
           <token> sender with that ply) -- takeback_snapshot_local==1
           picks out "this is a reply to MY OWN request", matching
           retry_pending_outgoing's own use of the same test. An ACK
           whose ply does not match either is a stale/duplicate ACK
           (nothing left to do -- app.c's own SESSION_DISPATCH_HANDLED,
           no notice). */
        char ply_text[6];
        char notation[8];

        if (netchess_proto_parse_ack(payload, ply_text, sizeof(ply_text),
                                     notation, sizeof(notation))) {
            uint16_t ack_ply = net_parse_u16(ply_text);

            if (takeback_pending_ply != 0u && ack_ply == takeback_pending_ply &&
                takeback_snapshot_local) {
                takeback_pending_ply = 0u;
                apply_takeback_snapshot();
            } else if (pending_local_ply != 0u && ack_ply == pending_local_ply) {
                net_apply_pending_local_move();
            }
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_NACK_MOVE) {
        /* Only a NACK for the move/takeback actually in flight is real;
           anything else is stale and silently ignored (app.c's own
           guard). The move was never applied locally (S8 step 3's
           deferred-apply model), so there is nothing to undo -- just
           clear the pending slot so the player can try again. */
        char ply_text[6];

        if (netchess_proto_parse_nack(payload, ply_text, sizeof(ply_text),
                                      0, 0u)) {
            uint16_t nack_ply = net_parse_u16(ply_text);

            if (takeback_pending_ply != 0u && nack_ply == takeback_pending_ply &&
                takeback_snapshot_local) {
                takeback_pending_ply = 0u;
                spectrum_gui_notify("Takeback rejected", 1u);
            } else if (pending_local_ply != 0u && nack_ply == pending_local_ply) {
                pending_local_clear();
                spectrum_gui_notify("Move rejected by opponent", 1u);
            }
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_TAKEBACK) {
        /* app.c's own guard chain, reduced (no game_over/game_status_
           active/confirm_action -- see this section's own header for
           why): a retransmit of a request we already hold, still
           awaiting our y/n, is a no-op; a retransmit of one we already
           applied is idempotently re-ACKed (last_accepted_takeback_ply,
           the same dup-guard app.c uses -- "receivers must treat
           duplicates idempotently", docs/wire-contract.md); anything
           that doesn't name exactly the move we just recorded as the
           peer's is NACKed; otherwise the request is queued for the
           player's y/n (net_control_key, net_takeback_reply). */
        const char *tail = netchess_after_prefix(payload,
                                                  NETCHESS_PROTO_TAKEBACK_PREFIX);
        uint16_t requested_ply = tail != 0 ? net_parse_u16(tail) : 0u;
        char ply_text[8];

        if (requested_ply != 0u && requested_ply == takeback_pending_ply &&
            !takeback_snapshot_local) {
            /* still waiting on the player's y/n -- nothing to do */
        } else if (requested_ply != 0u &&
                   requested_ply == last_accepted_takeback_ply) {
            (void)spectrum_append_u16(ply_text, requested_ply);
            if (!netchesszx_session_send_ack_move(ply_text)) {
                net_drop("Link down");
            }
        } else if (requested_ply == 0u ||
                   control_pending != CONTROL_PENDING_NONE ||
                   pending_local_ply != 0u || takeback_pending_ply != 0u ||
                   takeback_snapshot_local ||
                   requested_ply != spectrum_gui_log_ply_get() ||
                   requested_ply != takeback_snapshot_ply) {
            (void)spectrum_append_u16(ply_text, requested_ply);
            (void)netchesszx_session_send_nack_move(ply_text);
        } else {
            takeback_pending_ply = requested_ply;
            spectrum_gui_notify(
                "Opponent wants takeback: Y/N", 0u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_CHAT) {
        char text[SPECTRUM_LINK_PAYLOAD_MAX];

        if (netchess_proto_parse_chat(payload, text, (unsigned char)sizeof(text))) {
            spectrum_gui_notify_persistent(text);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESET) {
        /* S8 step 4 (app.c's own guard order): a RESET crossed with our own
           pending RESET, or arriving while a MOVE is in flight, is BUSY --
           the board must not move out from under either. A RESET crossed
           with a pending DRAW gets a plain NACK (no BUSY reason -- app.c's
           own distinction: DRAW/RESET-vs-RESET are the "really busy" case,
           a bare NACK just says "not right now"). Otherwise: still
           auto-accepted unconditionally, unchanged from before S8 (this
           section's own header explains why that stays as-is). */
        if (control_pending == CONTROL_PENDING_RESET || pending_local_ply != 0u) {
            (void)netchesszx_session_send_nack_reset_busy();
        } else if (control_pending != CONTROL_PENDING_NONE) {
            (void)netchesszx_session_send_nack_reset();
        } else {
            net_apply_reset();
            if (!netchesszx_session_send_ack_reset()) {
                net_drop("Link down");
            }
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_ACK_RESET) {
        /* Our own RESET request was accepted -- both sides now reset,
           whichever one asked (net_apply_reset is shared). A stray
           ACK_RESET with nothing of ours pending is ignored. */
        if (control_pending == CONTROL_PENDING_RESET) {
            net_apply_reset();
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_NACK_RESET) {
        if (control_pending == CONTROL_PENDING_RESET) {
            control_pending_clear();
            spectrum_gui_notify("Reset rejected", 1u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESIGN) {
        spectrum_gui_notify_persistent("Opponent resigned");
        (void)netchesszx_session_send_ack_resign();
    } else if (event == NETCHESSZX_SESSION_EVENT_DRAW) {
        /* app.c's own crossed-DRAW rule: "crossed DRAW is ACKed and
           advances to RESET" -- if we ALSO have a draw offer outstanding,
           accept this one and drive the rematch ourselves (send_reset=1
           in app.c's shape; ACK_DRAW below does the same for the
           non-crossed accepted-offer case). A retransmit of an offer we
           have not answered yet is a no-op (still incoming, still
           waiting). Anything else pending -> decline outright: this port
           has no confirm-queueing, so a second simultaneous request is
           simply refused rather than staged (S9 scope, if ever). */
        if (control_pending == CONTROL_PENDING_DRAW_INCOMING) {
            /* still waiting on the player's y/n -- nothing to do */
        } else if (control_pending == CONTROL_PENDING_DRAW_SENT) {
            control_pending_clear();
            if (!netchesszx_session_send_ack_move("DRAW")) {
                net_drop("Link down");
                return;
            }
            net_draw_start_rematch();
        } else if (control_pending != CONTROL_PENDING_NONE ||
                   pending_local_ply != 0u) {
            (void)netchesszx_session_send_nack_move("DRAW");
        } else {
            control_pending = CONTROL_PENDING_DRAW_INCOMING;
            spectrum_gui_notify("Opponent offers a draw: Y/N", 0u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_ACK_DRAW) {
        /* Our own offer was accepted -- this side drives the rematch
           (app.c's start_draw_rematch(1u) for the ACK_DRAW case; the
           accepting side, net_draw_reply below, does not). */
        if (control_pending == CONTROL_PENDING_DRAW_SENT) {
            net_draw_start_rematch();
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_NACK_DRAW) {
        if (control_pending == CONTROL_PENDING_DRAW_SENT) {
            control_pending_clear();
            spectrum_gui_notify("Draw declined", 1u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_CANCEL_DRAW) {
        /* The peer withdrew an offer we have not answered yet -- clear the
           prompt without sending anything back (CANCEL is unilateral, not
           itself ACKed/NACKed by the wire grammar). */
        if (control_pending == CONTROL_PENDING_DRAW_INCOMING) {
            control_pending_clear();
            spectrum_gui_notify("Draw offer withdrawn", 1u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESTORE_RQ) {
        /* S8 step 6: the peer wants to push a loaded game to us. app.c's
           own duplicate/busy guard chain, reduced (no game_over/
           confirm_action -- this section's own header explains why). */
        if ((restore_rx_mask & RESTORE_RX_APPLIED) != 0u) {
            /* "A later RQ clears the applied duplicate latch and starts a
               fresh [exchange]" (docs/session-core-contract.md). */
            restore_net_clear();
        }
        if (restore_prompt_pending ||
            (restore_rx_mask & RESTORE_RX_RECEIVE) != 0u) {
            /* Decision still open, or already accepted: re-send RY
               without a second prompt/decision (contract). */
            if (!spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RY)) {
                net_drop("Link down");
            }
            return;
        }
        if (net_op_busy()) {
            /* net_op_busy()'s own restore_rx_mask != 0u already covers the
               RESTORE_TX_PENDING/_AWAIT_ACK bits this branch used to check
               separately -- nothing else could set restore_rx_mask while
               restore_prompt_pending/RESTORE_RX_RECEIVE are both clear
               (the two branches above already returned). */
            (void)spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RN);
            return;
        }
        restore_prompt_pending = 1u;
        spectrum_gui_notify(
            "Opponent wants to load a game: Y/N", 0u);
    } else if (event == NETCHESSZX_SESSION_EVENT_RESTORE_RY) {
        /* Our own pending RQ was accepted -- start sending chunks. A
           stray RY with nothing of ours pending is ignored. */
        if ((restore_rx_mask & RESTORE_TX_PENDING) != 0u) {
            restore_rx_mask = RESTORE_TX_AWAIT_ACK;
            control_retry_count = 0u;
            pending_retry_timer = PENDING_RETRY_TICKS;
            if (!restore_send_chunks()) {
                net_drop("Link down");
            }
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESTORE_RN) {
        /* Peer rejected our RQ, NACKed a chunk, or cancelled its own
           pending RQ to us -- either way, nothing of this exchange
           survives it. A stray RN with nothing pending is a no-op. */
        if (restore_rx_mask != 0u || restore_prompt_pending) {
            restore_net_clear();
            spectrum_gui_notify("Load cancelled", 1u);
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESTORE_RS) {
        /* One of the two fixed 30-byte chunks (docs/wire-contract.md:
           exactly two, "RS00"/"RS01", no arbitrary chunk count). Payload
           shape mirrors src/common/session/session.c's own
           session_build_restore_chunk byte-for-byte: "RS0" + digit + ' '
           + 30 bytes, no NUL on the wire (poll.c null-terminates the
           copy it hands up). */
        unsigned char chunk;

        if (memcmp(payload, "RS0", 3) != 0 ||
            (payload[3] != '0' && payload[3] != '1') || payload[4] != ' ') {
            return;
        }
        chunk = (unsigned char)(payload[3] - '0');

        if ((restore_rx_mask & RESTORE_RX_APPLIED) != 0u) {
            /* Already applied this exchange: an exact resend re-ACKs RA
               without decoding again; a conflicting one NACKs
               (docs/session-core-contract.md's accepted-restore
               duplicate latch -- the same idea as ACK_MOVE's stale-ACK
               and TAKEBACK's last_accepted_takeback_ply guards). */
            if (memcmp(payload + 5, saveload_b64_pending +
                           (chunk == 0u ? 0u : 30u), 30) == 0) {
                if (!spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RA)) {
                    net_drop("Link down");
                }
            } else {
                (void)spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RN);
            }
            return;
        }
        if ((restore_rx_mask & RESTORE_RX_RECEIVE) == 0u) {
            /* "RS00/RS01 are accepted only after the receiver has handed
               off RY" (docs/session-core-contract.md) -- a chunk arriving
               before our own RY (or after we declined) is simply
               ignored. */
            return;
        }
        memcpy(saveload_b64_pending + (chunk == 0u ? 0u : 30u), payload + 5,
               30);
        restore_chunk_have = (unsigned char)(restore_chunk_have |
                                             (1u << chunk));
        if (restore_chunk_have != 3u) {
            return;                 /* still waiting for the other half */
        }

        {
            netchesszx_save_meta_t meta;

            if (!spectrum_restore_decode(saveload_b64_pending,
                                         &saveload_snapshot, &meta)) {
                (void)spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RN);
                restore_net_clear();
                return;
            }
            pending_local_clear();
            control_pending_clear();
            takeback_clear();
            net_apply_loaded_snapshot(&meta);
            spectrum_gui_notify_success("Loaded from opponent");
        }
        restore_rx_mask = RESTORE_RX_APPLIED;
        restore_chunk_have = 0u;
        if (!spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RA)) {
            net_drop("Link down");
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_RESTORE_RA) {
        /* Peer confirms it applied the game we pushed. A stray RA with
           nothing of ours pending is ignored. */
        if ((restore_rx_mask & RESTORE_TX_AWAIT_ACK) != 0u) {
            restore_rx_mask = 0u;
            spectrum_gui_notify_success("Opponent loaded the game");
        }
    } else if (event == NETCHESSZX_SESSION_EVENT_BYE) {
        net_drop("Opponent left");
    } else if (event == NETCHESSZX_SESSION_EVENT_GAME_START) {
        (void)netchesszx_session_direct_apply_start_side(payload);
        (void)netchesszx_session_send_ack_game_start();
    }
}

/* S8 step 4: local triggers for RESET/DRAW confirmation. No portable menu
   tab exists for "offer draw"/"accept draw" (gui.h's SPECTRUM_GUI_KEY_
   MENU_* set has no such entries -- on ZX these are typed text commands,
   SPECTRUM_INPUT_CMD_DRAW/_RESIGN via INPUT_EDIT, which this port has not
   built, see net_ui_sprinter.c/S8's editor scope). Rather than build a
   typed-command line for three letters, this port dedicates plain ASCII
   hotkeys -- Sprinter-native, not a port of anything, deliberately not
   touching the shared gui.c/gui.h menu surface ZX/Next also use. 'd' offers
   a draw; 'y'/'n' answer an incoming offer. There is no local resign
   trigger yet (S8 does not add one -- see this section's own header). */
static void net_draw_offer(void) {
    if (net_op_busy()) {
        spectrum_gui_notify("Waiting for ACK", 0u);
        return;
    }
    if (!spectrum_link_send_text(NETCHESS_PROTO_DRAW)) {
        net_drop("Link down");
        return;
    }
    control_pending = CONTROL_PENDING_DRAW_SENT;
    control_retry_count = 0u;
    pending_retry_timer = PENDING_RETRY_TICKS;
    spectrum_gui_notify("Draw offered", 0u);
}

static void net_draw_reply(unsigned char accept) {
    if (control_pending != CONTROL_PENDING_DRAW_INCOMING) {
        return;
    }
    control_pending_clear();
    if (accept) {
        if (!netchesszx_session_send_ack_move("DRAW")) {
            net_drop("Link down");
            return;
        }
        /* app.c's own asymmetry: the accepting side does not drive the
           rematch RESET -- the offering side does, once our ACK reaches
           it (this file's ACK_DRAW branch above). */
        spectrum_gui_notify_persistent("Draw agreed - new game");
    } else {
        (void)netchesszx_session_send_nack_move("DRAW");
        spectrum_gui_notify("Draw declined", 0u);
    }
}

/* S8 step 5: request a takeback of the move THIS side just made
   (takeback_snapshot_local guards that -- you cannot ask to take back the
   peer's move, only your own, matching the wire's own semantics: the
   receiver's mirror-image guard in net_handle_event's TAKEBACK branch
   checks the same flag from its own point of view). */
static void net_takeback_request(void) {
    if (net_op_busy()) {
        spectrum_gui_notify("Waiting for ACK", 0u);
        return;
    }
    if (!takeback_snapshot_local || takeback_snapshot_ply == 0u) {
        spectrum_gui_notify("Nothing to take back", 0u);
        return;
    }
    if (!net_send_takeback_wire(takeback_snapshot_ply)) {
        net_drop("Link down");
        return;
    }
    takeback_pending_ply = takeback_snapshot_ply;
    control_retry_count = 0u;
    pending_retry_timer = PENDING_RETRY_TICKS;
    spectrum_gui_notify("Takeback requested", 0u);
}

/* Answers an INCOMING takeback request (takeback_pending_ply set by
   net_handle_event's TAKEBACK branch, with takeback_snapshot_local==0 --
   this is the peer's move we are being asked to unwind, not ours). */
static void net_takeback_reply(unsigned char accept) {
    char ply_text[8];
    uint16_t ply = takeback_pending_ply;

    if (ply == 0u || takeback_snapshot_local) {
        return;
    }
    takeback_pending_ply = 0u;
    (void)spectrum_append_u16(ply_text, ply);
    if (accept) {
        apply_takeback_snapshot();
        if (!netchesszx_session_send_ack_move(ply_text)) {
            net_drop("Link down");
            return;
        }
        last_accepted_takeback_ply = ply;
    } else {
        (void)netchesszx_session_send_nack_move(ply_text);
        spectrum_gui_notify("Takeback declined", 0u);
    }
}

/* Answers an incoming RESTORE_RQ (restore_prompt_pending set by
   net_handle_event's RESTORE_RQ branch). */
static void net_restore_reply(unsigned char accept) {
    if (!restore_prompt_pending) {
        return;
    }
    restore_prompt_pending = 0u;
    if (accept) {
        restore_rx_mask = RESTORE_RX_RECEIVE;
        restore_chunk_have = 0u;
        if (!spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RY)) {
            net_drop("Link down");
            return;
        }
        spectrum_gui_notify("Waiting for saved game", 0u);
    } else {
        (void)spectrum_link_send_text(NETCHESS_PROTO_RESTORE_RN);
        spectrum_gui_notify("Load request declined", 0u);
    }
}

void net_control_key(unsigned char key) {
    if (!net_active) {
        return;
    }
    if (control_pending == CONTROL_PENDING_DRAW_INCOMING) {
        if (key == 'y' || key == 'Y') {
            key_code = 0u;
            net_draw_reply(1u);
        } else if (key == 'n' || key == 'N') {
            key_code = 0u;
            net_draw_reply(0u);
        }
        return;
    }
    if (takeback_pending_ply != 0u && !takeback_snapshot_local) {
        if (key == 'y' || key == 'Y') {
            key_code = 0u;
            net_takeback_reply(1u);
        } else if (key == 'n' || key == 'N') {
            key_code = 0u;
            net_takeback_reply(0u);
        }
        return;
    }
    if (restore_prompt_pending) {
        if (key == 'y' || key == 'Y') {
            key_code = 0u;
            net_restore_reply(1u);
        } else if (key == 'n' || key == 'N') {
            key_code = 0u;
            net_restore_reply(0u);
        }
        return;
    }
    if (key == 'd' || key == 'D') {
        key_code = 0u;
        net_draw_offer();
    } else if (key == 't' || key == 'T') {
        key_code = 0u;
        net_takeback_request();
    }
}

/* One frame's worth of session work, called from the frame loop. Cheap
   when idle: netchesszx_session_poll's empty path is two non-blocking uNet
   polls and at most two frame waits (unet_link.c's own pacing comment). */
void net_poll_once(void) {
    char *payload = spectrum_link_payload_scratch();
    netchesszx_session_poll_result_t poll;
    unsigned char status;

    /* Re-announce until the peer answers: on DIRECT either side may finish
       connecting first, and a HELLO sent before the other end was listening
       is simply lost. */
    if (!net_peer_known) {
        if (net_hello_wait != 0u) {
            --net_hello_wait;
        } else {
            net_hello_wait = NET_HELLO_REANNOUNCE_TICKS;
            if (!netchesszx_session_direct_send_hello()) {
                net_drop("Link down");
                return;
            }
        }
    }

    status = netchesszx_session_poll(&net_ping, payload,
                                     SPECTRUM_LINK_PAYLOAD_MAX, &poll);
    if (status == NETCHESSZX_SESSION_POLL_DISCONNECTED) {
        net_drop("Link down");
        return;
    }
    if (status == NETCHESSZX_SESSION_POLL_EVENT) {
        net_handle_event((unsigned char)poll.event, payload);
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
/* S8 step 4: network-aware. Hot-seat keeps the original instant reset --
   both sides are at the same keyboard, there is no peer to ask. Networked
   play sends a RESET request instead and waits for the peer's ACK/NACK
   (net_handle_event's ACK_RESET/NACK_RESET branches, net_apply_reset does
   the actual reset once accepted) -- the menu tab itself is deliberately
   not gated on being able to reach the menu at all while something else
   is pending; the request is simply queued behind whatever is already in
   flight via the usual guard. */
static void menu_reset_game(void) {
    if (net_active) {
        if (net_op_busy()) {
            spectrum_gui_notify("Waiting for ACK", 0u);
            return;
        }
        if (!spectrum_link_send_text(NETCHESS_PROTO_RESET)) {
            net_drop("Link down");
            return;
        }
        control_pending = CONTROL_PENDING_RESET;
        control_retry_count = 0u;
        pending_retry_timer = PENDING_RETRY_TICKS;
        spectrum_gui_notify("Reset requested", 0u);
        return;
    }
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


/* S7 step 5: the tab ZX/Next label DISCONNECT is this port's NETWORK tab
   (there is nothing to disconnect from until there is something to
   connect to, and one tab has to do both jobs until SETUP arrives in S9).
   It toggles: with no session it opens the modal join screen, with a live
   one it hangs up. The modal owns the whole screen while it runs, so the
   board area is repainted on the way back either way -- the same "close"
   fileui_close already does, for the same reason. */
static void menu_network(void) {
    unsigned char joined;

    if (net_active) {
        (void)spectrum_link_send_text(NETCHESS_PROTO_BYE);
        net_drop("Disconnected");
        return;
    }

    spectrum_gui_clear_cursor_coords();
    joined = spectrum_net_join_ui();
    spectrum_gui_restore_board_area();
    saveload_full_redraw();

    if (!joined) {
        spectrum_gui_notify("Not connected", 1u);
        return;
    }

    /* S8 step 8e: spectrum_net_join_ui() (the NET screen) now configures
       the session itself -- role/transport/host_color the user picked,
       plus the host_color_ready JOIN fix (net_ui_sprinter.c's own
       net_ui_try_connect() comment has the full post-mortem this used to
       live here, verbatim, for the DIRECT-only role-is-always-JOIN case).
       Only the transport-neutral follow-up stays here. */
    if (!netchesszx_transport_is_mqtt()) {
        spectrum_link_start_uart();
    }
    netchesszx_session_ping_reset(&net_ping);
    netchesszx_session_peer_reset();
    net_peer_known = 0u;
    net_hello_wait = 0u;
    net_active = 1u;

    spectrum_gui_set_connected(netchesszx_transport_is_mqtt() ? 1u : 2u);
    spectrum_gui_set_status("WAITING");
    spectrum_gui_notify_persistent("Waiting for opponent");
}

void handle_menu_action(unsigned char action) {
    if (action == SPECTRUM_GUI_KEY_MENU_REST) {
        menu_reset_game();
    } else if (action == SPECTRUM_GUI_KEY_MENU_THEME) {
        menu_cycle_theme();
    } else if (action == SPECTRUM_GUI_KEY_MENU_FLIP) {
        menu_flip_board();
    } else if (action == SPECTRUM_GUI_KEY_MENU_FILE) {
        fileui_open();
    } else if (action == SPECTRUM_GUI_KEY_MENU_DISCC) {
        menu_network();
    } else if (action == SPECTRUM_GUI_KEY_MENU_ABOUT) {
        menu_not_available();
    }
}
