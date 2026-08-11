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
 * and (S5 substep 3) paints a real starting chess position via render_
 * core.asm's render_board_full, reading src/spectrum/lowram_map.h's
 * cross-platform NETCHESSZX_LOWRAM_CHESS_BOARD buffer, plus a-h/1-8
 * coordinate labels (render_coord_labels), an RTC HH:MM status-bar clock
 * (render_status_clock), and the rest of the static HUD chrome --
 * banner title + logo (render_banner), the menu-tab row (render_menu_
 * bar), a status-bar connection placeholder (render_status_text), and
 * the input-line prompt (render_input_line) -- before clearing ovl_
 * test_signal's diagnostic background tint back to black. The frame loop
 * polls the keyboard every tick (key_poll) and now has its first real
 * consumer of the result: board_cursor_move moves a ring-marker cursor
 * (render_cursor_marker) around the board on the four arrow codes,
 * read-and-clear rather than key_poll's own latch. Move-list/chat panel
 * content, a menu/game key handler, and hot-seat wiring are still later
 * substep-3/4 work (docs/sprinter-testnotes/S5.md).
 */

#include "spectrum/session/event.h"
#include "spectrum/lowram_map.h"

extern void im2_install(void);
extern void video_init(void);
extern void bench_init(void);
extern unsigned char frame_wait(void);
extern unsigned char ovl_exec(unsigned char ovl_id, unsigned char entry_id);
extern unsigned char ovl_ctx[16];
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
extern void board_cursor_move(void);

/* SPECTRUM_OVL_CTX_PTR_LO/HI (src/spectrum/overlay/overlay_context.h):
   control_classify_ovl reads a 2-byte little-endian pointer to the ASCIIZ
   payload from ovl_ctx[0..1]. "MOVE e2e4" must classify as exactly
   NETCHESSZX_SESSION_EVENT_MOVE. */
static const char ovl_test_payload[] = "MOVE e2e4";
unsigned char ovl_test_result;

/* Stand-in for spectrum_board_reset() (src/spectrum/board/board.c):
   that function is the real, cross-platform "new game" setup ZX/Next call,
   but board.c also links spectrum_overlay_exec[_cached]-dispatching
   functions (is_legal_move_coords/check_state/apply_trusted_move) that
   need the RULES(0)/BOARD(1) overlays -- still unported placeholders in
   overlay_atlas_table_sprinter.asm, pointing at raw font-page bytes (the
   exact shape of this session's first MAME crash, port.md 2026-08-10).
   z80asm links whole object files, so pulling in board.c at all would
   require those symbols to resolve even though nothing here calls them;
   rather than alias them into something callable-but-landmined, this
   duplicates just the cell-population half of spectrum_board_reset's own
   logic (same ASCII encoding: uppercase white, lowercase black, '.'
   empty), so swapping to the real function is a one-line change once the
   overlays it needs exist. */
static void init_starting_position(void) {
    static const char backrank[] = "rnbqkbnr";
    char *board = (char *)NETCHESSZX_LOWRAM_CHESS_BOARD_ADDR;
    unsigned char i;

    for (i = 0u; i < 64u; ++i) {
        unsigned char row = i >> 3;
        unsigned char col = i & 7u;

        if (row == 0u) {
            board[i] = backrank[col];
        } else if (row == 1u) {
            board[i] = 'p';
        } else if (row == 6u) {
            board[i] = 'P';
        } else if (row == 7u) {
            board[i] = (char)(backrank[col] & (char)~0x20);
        } else {
            board[i] = '.';
        }
    }
}

void main(void) {
    unsigned char pass;

    bench_init();
    video_init();

    ovl_ctx[0] = (unsigned char)((unsigned int)ovl_test_payload & 0xFFu);
    ovl_ctx[1] = (unsigned char)((unsigned int)ovl_test_payload >> 8);
    ovl_test_result = ovl_exec(14u, 0u);

    pass = (unsigned char)(ovl_test_result == (unsigned char)NETCHESSZX_SESSION_EVENT_MOVE);
    ovl_test_signal(pass);

    init_starting_position();
    render_board_full();
    render_coord_labels();
    render_status_clock();
    render_banner();
    render_menu_bar();
    render_status_text();
    render_input_line();
    render_cursor_marker();

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
       consumption, not before it. Still not a menu/game key handler --
       only the board cursor moves; ASCII/cancel/backspace remain
       unconsumed, same as before this pass. */
    for (;;) {
        frame_wait();
        key_poll();
        board_cursor_move();
        render_input_key_echo();
    }
}
