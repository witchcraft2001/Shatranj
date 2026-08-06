#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "spectrum/config/session.h"
#include "spectrum/ui/gui.h"
#include "spectrum/ui/layout.h"

char netchesszx_host_gui_move_lines[
    NETCHESSZX_MOVE_ROWS * NETCHESSZX_MOVE_SLOT_SIZE];
char netchesszx_host_gui_chat_lines[
    NETCHESSZX_CHAT_ROWS * NETCHESSZX_CHAT_SLOT_SIZE];
char netchesszx_host_gui_clock_save[NETCHESSZX_LOWRAM_CLOCK_SAVE_SIZE];
char netchesszx_host_gui_game_timer_save[
    NETCHESSZX_LOWRAM_GAME_TIMER_SAVE_SIZE];
char netchesszx_host_gui_notice_text[NETCHESSZX_NOTICE_TEXT_SIZE];
char netchesszx_host_gui_board[NETCHESSZX_LOWRAM_BOARD_CELL_COUNT];

uint8_t netchesszx_movement_hints;
uint8_t netchesszx_hinted_rows[8];

static char rendered_clock[8];
static char rendered_input[64];
static unsigned clock_draws;

void spectrum_render_clock(const char *text)
{
    memcpy(rendered_clock, text, sizeof(rendered_clock));
    ++clock_draws;
}

void spectrum_render_board(const char *board) { (void)board; }
void spectrum_render_board_coords(void) {}
void spectrum_render_square(const char *spec) { (void)spec; }
void spectrum_render_square_with_hint(const char *spec) { (void)spec; }
void spectrum_render_connection(uint8_t connected) { (void)connected; }
void spectrum_render_menu(uint8_t visible) { (void)visible; }
void spectrum_render_game_timer_clear(const char *text) { (void)text; }
void spectrum_render_game_timer_char(const char *spec) { (void)spec; }
void spectrum_render_menu_timer_char(const char *spec) { (void)spec; }
void spectrum_render_input(const char *text)
{
    strncpy(rendered_input, text, sizeof(rendered_input) - 1u);
    rendered_input[sizeof(rendered_input) - 1u] = '\0';
}
void spectrum_render_notice(const char *text) { (void)text; }
void spectrum_render_notice_error(const char *text) { (void)text; }
void spectrum_render_notice_success(const char *text) { (void)text; }
void spectrum_info_show_game(void) {}
void spectrum_render_moves(const char *moves) { (void)moves; }
void spectrum_render_chat(const char *chat) { (void)chat; }

int main(void)
{
    unsigned i;
    unsigned before;

    memset(netchesszx_host_gui_board, '.', sizeof(netchesszx_host_gui_board));
    spectrum_gui_set_board_pieces_visible(1u);

    spectrum_gui_set_clock(23u, 59u, 58u);
    assert(strcmp(rendered_clock, "[23:59]") == 0);

    before = clock_draws;
    spectrum_gui_draw_board();
    spectrum_gui_draw_status();
    assert(clock_draws == before + 1u);
    assert(strcmp(rendered_clock, "[23:59]") == 0);
    spectrum_gui_restore_side_panels();
    assert(strcmp(rendered_input,
                  "ARROWS+ENTER MOVE; M TYPE; C CHAT; F1 MENU; CTRL+ESC EXIT") == 0);
    assert(spectrum_gui_handle_menu_key(SPECTRUM_GUI_KEY_MENU) == 0u);
    assert(spectrum_gui_handle_menu_key(13u) == SPECTRUM_GUI_KEY_MENU_FILE);

    for (i = 0u; i < 100u; ++i) {
        spectrum_gui_tick();
    }
    assert(strcmp(rendered_clock, "[00:00]") == 0);

    spectrum_gui_set_clock(12u, 59u, 59u);
    for (i = 0u; i < 50u; ++i) {
        spectrum_gui_tick();
    }
    assert(strcmp(rendered_clock, "[13:00]") == 0);
    return 0;
}
