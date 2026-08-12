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
 * side) callers would use. spectrum_gui_remove_last_move/spectrum_gui_
 * add_chat are not implemented here -- nothing in this port calls them yet
 * (no takeback UI, no chat input/network); gui.h still declares them, but a
 * C link only requires a definition for a symbol something actually calls.
 */

#include "spectrum/ui/render.h"
#include "spectrum/ui/layout.h"
#include "spectrum/lowram_map.h"

#include <string.h>

#define move_lines ((char *)NETCHESSZX_LOWRAM_MOVE_LOG_ADDR)
#define MOVE_TEXT_MAX 7u        /* same field width ZX's own gui_log_ovl.c
                                    copies a move into (gui_log_copy_move) */

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
