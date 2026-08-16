/* Sprinter-native move-list backend (S5-finish, plan D12, GUI_LOG(2) scope).
 *
 * ZX/Next feed the move-list panel through a ported overlay (GUI_LOG, id 2,
 * asm/overlay/gui_log/entry_gui_log.asm's word-wrap/ply-parsing Z80 helpers,
 * src/spectrum/overlay/gui_log_ovl.c/overlay.c). Those helpers are ZX-only
 * hand-written asm this port cannot link, and hot-seat has no network ply
 * text to parse in the first place -- every move is generated locally, by
 * src/sprinter/main.c's own board_select_or_move, strictly in order. This
 * file is the much smaller Sprinter-native replacement for exactly the one
 * entry point main.c actually needs (spectrum_gui_add_move), writing into
 * the SAME move_lines low-RAM layout (src/spectrum/ui/layout.h's
 * NETCHESSZX_MOVE_* constants) gui.h's own declared contract already
 * assumes, and painting through the same render_core.asm entry points
 * (spectrum_render_move_at/spectrum_render_moves) gui.c's own (unused, ZX-
 * side) callers would use. spectrum_gui_remove_last_move IS implemented
 * (S8 step 5, takeback) -- see its own comment below.
 *
 * spectrum_gui_add_chat/spectrum_gui_reset_chat (S9 chat pass): unlike the
 * move list, the chat panel's own storage and word-wrap live on the
 * INPUT_EDIT overlay itself (src/sprinter/chat_sprinter.c, SPECTRUM_OVL_
 * INPUT_EDIT=9u, WIN3 page 2) -- these two are thin dispatchers, the same
 * ctx-write-then-exec shape ZX's overlay.c uses for its own spectrum_gui_
 * add_chat, just targeting chat_sprinter.h's Sprinter-only ADD_CHAT/
 * RESET_CHAT entry ids instead of GUI_LOG's. spectrum_gui_reset_chat is
 * called directly from the WIN3 cold page (session_sprinter.c's net_drop)
 * -- resident C calling another resident C function needs no dispatch of
 * its own, only the eventual ovl_exec_cached call inside it crosses a
 * window.
 *
 * spectrum_gui_log_ply_get/_set (S6, port.md section 5/S6): save/load needs
 * the true half-move count for netchesszx_save_meta_t.ply, and gui_log_ply
 * already IS that count (incremented once per spectrum_gui_add_move call,
 * i.e. once per applied move) -- a second, main.c-local counter would just
 * be the same number kept twice, with the two free to drift. The setter
 * exists for load: it does not touch gui_log_row or repaint anything (the
 * caller resets the move log separately, src/sprinter/main.c's own local_
 * load_game), it only seeds the counter so the NEXT move played after a
 * load numbers itself correctly. */

#include "spectrum/ui/render.h"
#include "spectrum/ui/layout.h"
#include "spectrum/ui/gui.h"
#include "spectrum/lowram_map.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/overlay/overlay_context.h"
#include "sprinter/chat_sprinter.h"

#include <string.h>

#define move_lines ((char *)NETCHESSZX_LOWRAM_MOVE_LOG_ADDR)
#define MOVE_TEXT_MAX 7u        /* same field width ZX's own gui_log_ovl.c
                                    copies a move into (gui_log_copy_move) */

/* asm/sprinter/zcc/overlay_loader_sprinter.asm's dispatcher, resolved
 * within this same resident C image -- board.c already calls this exact
 * function for RULES/BOARD, no bridging needed between two files linked
 * into the same resident_c.bin. */
extern uint8_t spectrum_overlay_exec_cached(uint8_t ovl_id, uint8_t entry_id);

static uint16_t gui_log_ply;
static uint8_t gui_log_row;

static char *move_row_at(uint8_t row)
{
    return move_lines + (uint16_t)row * NETCHESSZX_MOVE_SLOT_SIZE;
}

/* No arguments. Clears the move log and repaints the (now empty) panel --
   the menu RESET action's own move-list step (src/sprinter/main.c). */
void spectrum_gui_reset_move_log(void)
{
    memset(move_lines, 0, (uint16_t)NETCHESSZX_MOVE_ROWS * NETCHESSZX_MOVE_SLOT_SIZE);
    gui_log_ply = 0u;
    gui_log_row = 0u;
    spectrum_render_moves(move_lines);
}

void spectrum_gui_add_move(const char *ply, const char *move)
{
    char *row_base;
    char *out;
    uint8_t i;

    /* Sprinter hot-seat has no ply-string transport (no network in S5) --
       every ply is generated locally, strictly in order, so ZX's string-
       parsed ply (gui_log_parse_ply, asm/overlay/gui_log) is unneeded; a
       plain counter already knows white/black from its own parity. */
    (void)ply;
    ++gui_log_ply;

    if ((gui_log_ply & 1u) == 0u) {
        /* black half-move: same row the white half-move just claimed */
        row_base = move_row_at((uint8_t)(gui_log_row - 1u));
        out = row_base + NETCHESSZX_MOVE_BLACK_OFFSET;
    } else {
        if (gui_log_row >= NETCHESSZX_MOVE_ROWS) {
            memmove(move_lines, move_lines + NETCHESSZX_MOVE_SLOT_SIZE,
                    (uint16_t)(NETCHESSZX_MOVE_ROWS - 1u) * NETCHESSZX_MOVE_SLOT_SIZE);
            memset(move_row_at((uint8_t)(NETCHESSZX_MOVE_ROWS - 1u)), 0,
                   NETCHESSZX_MOVE_SLOT_SIZE);
            --gui_log_row;
            spectrum_render_moves(move_lines);
        }
        row_base = move_row_at(gui_log_row);
        ++gui_log_row;
        out = row_base;
    }

    for (i = 0u; move[i] != '\0' && i < MOVE_TEXT_MAX; ++i) {
        out[i] = move[i];
    }
    out[i] = '\0';

    spectrum_render_move_at(row_base);
}

/* S8 step 5 (takeback): undo exactly the last spectrum_gui_add_move call.
   The ply argument is ignored -- gui_log_ply's own parity already knows
   which half of which row the last add touched, matching add_move's own
   internal logic exactly in reverse. Not perfectly reversible across a
   scroll event: the panel is a fixed-size ring, and a takeback of the
   move that triggered add_move's memmove cannot bring back the row that
   scrolled out. Accepted as a display-only edge case -- the real game
   state (spectrum_board_undo_restore, board.c) is always restored
   correctly by the caller regardless; only the move-list panel can be one
   row stale in that rare case. */
void spectrum_gui_remove_last_move(uint16_t ply)
{
    (void)ply;

    if (gui_log_ply == 0u) {
        return;
    }
    if ((gui_log_ply & 1u) == 0u) {
        /* undo a black half-move: same row stays, just clear that half */
        char *row_base = move_row_at((uint8_t)(gui_log_row - 1u));

        row_base[NETCHESSZX_MOVE_BLACK_OFFSET] = '\0';
        spectrum_render_move_at(row_base);
    } else {
        /* undo a white half-move: the row it claimed goes away */
        if (gui_log_row != 0u) {
            --gui_log_row;
        }
        memset(move_row_at(gui_log_row), 0, NETCHESSZX_MOVE_SLOT_SIZE);
        spectrum_render_moves(move_lines);
    }
    --gui_log_ply;
}

uint16_t spectrum_gui_log_ply_get(void)
{
    return gui_log_ply;
}

void spectrum_gui_log_ply_set(uint16_t ply)
{
    gui_log_ply = ply;
}

/* S9 chat pass. who/text land in the shared overlay context and INPUT_EDIT
 * (SPECTRUM_OVL_INPUT_EDIT=9u)'s own ADD_CHAT entry (chat_sprinter.c) does
 * the actual word-wrap/storage/repaint -- see that file's own header for
 * why the chat log lives there rather than here alongside the move list.
 * `text` must point at WIN1-resident memory (a C stack local or a
 * resident static, never a WIN3-page pointer): the callee dereferences it
 * only after this dispatch has already mapped WIN3 to page 2. */
void spectrum_gui_add_chat(char who, const char *text)
{
    uint16_t text_addr = (uint16_t)text;

    spectrum_overlay_context[SPECTRUM_OVL_CTX_GUI_CHAT_WHO] = (uint8_t)who;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_GUI_CHAT_TEXT_LO] =
        (uint8_t)text_addr;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_GUI_CHAT_TEXT_HI] =
        (uint8_t)(text_addr >> 8);
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_INPUT_EDIT,
                                       SPECTRUM_OVL_INPUT_EDIT_ADD_CHAT);
}

/* Clears the chat panel and repaints it empty -- the net_drop (link torn
 * down) counterpart of spectrum_gui_reset_move_log above, called directly
 * from the WIN3 cold page (session_sprinter.c), same as that function. */
void spectrum_gui_reset_chat(void)
{
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_INPUT_EDIT,
                                       SPECTRUM_OVL_INPUT_EDIT_RESET_CHAT);
}
