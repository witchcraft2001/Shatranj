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

static char rendered_clock[9];
static char rendered_input[64];
static char rendered_timer[32];
static char rendered_notice[32];
static char rendered_square[6];
static unsigned clock_draws;
static unsigned timer_draws;
static uint8_t timer_menu_mode;
static uint8_t frame_counter;

uint8_t sprinter_frame_counter_get(void)
{
    return frame_counter;
}

void sprinter_render_game_timer_line(const char *text, uint8_t menu_mode)
{
    strcpy(rendered_timer, text);
    timer_menu_mode = menu_mode;
    ++timer_draws;
}

void spectrum_render_clock(const char *text)
{
    memcpy(rendered_clock, text, sizeof(rendered_clock));
    ++clock_draws;
}

void spectrum_render_board(const char *board) { (void)board; }
void spectrum_render_board_coords(void) {}
void spectrum_render_board_coord_mark(const char *spec) { (void)spec; }
void spectrum_render_square(const char *spec) { (void)spec; }
void spectrum_render_square_with_hint(const char *spec)
{
    memcpy(rendered_square, spec, sizeof(rendered_square));
}
void spectrum_render_connection(uint8_t connected) { (void)connected; }
void spectrum_render_menu(uint8_t visible) { (void)visible; }
void spectrum_render_game_timer_clear(const char *text)
{
    sprinter_render_game_timer_line(text, 0u);
}
void spectrum_render_game_timer_char(const char *spec) { (void)spec; }
void spectrum_render_menu_timer_char(const char *spec) { (void)spec; }
void spectrum_render_input(const char *text)
{
    strncpy(rendered_input, text, sizeof(rendered_input) - 1u);
    rendered_input[sizeof(rendered_input) - 1u] = '\0';
}
void spectrum_render_notice(const char *text)
{
    strcpy(rendered_notice, text);
}
void spectrum_render_notice_error(const char *text) { (void)text; }
void spectrum_render_notice_success(const char *text) { (void)text; }
void spectrum_info_show_game(void) {}
void spectrum_render_moves(const char *moves) { (void)moves; }
void spectrum_render_chat(const char *chat) { (void)chat; }

int main(void)
{
    unsigned i;
    unsigned before;
    uint8_t col;
    uint8_t flipped;

    memset(netchesszx_host_gui_board, '.', sizeof(netchesszx_host_gui_board));
    spectrum_gui_set_board_pieces_visible(1u);

    spectrum_gui_set_clock(23u, 59u, 58u);
    assert(strcmp(rendered_clock, "[23:59] ") == 0);

    before = clock_draws;
    spectrum_gui_draw_board();
    spectrum_gui_draw_status();
    assert(clock_draws == before + 1u);
    assert(strcmp(rendered_clock, "[23:59] ") == 0);
    spectrum_gui_restore_side_panels();
    assert(strcmp(rendered_input,
                  "ARROWS+ENTER MOVE; M TYPE; C CHAT; F1 MENU; CTRL+ESC EXIT") == 0);
    assert(spectrum_gui_handle_menu_key(SPECTRUM_GUI_KEY_MENU) == 0u);
    assert(spectrum_gui_handle_menu_key(13u) == SPECTRUM_GUI_KEY_MENU_FILE);

    netchesszx_movement_hints = 1u;
    for (flipped = 0u; flipped < 2u; ++flipped) {
        spectrum_gui_set_board_view(flipped);
        for (col = 0u; col < 8u; ++col) {
            memset(netchesszx_hinted_rows, 0, sizeof(netchesszx_hinted_rows));
            netchesszx_hinted_rows[1] = (uint8_t)(1u << col);
            spectrum_gui_redraw_square(1u, col);
            assert((uint8_t)rendered_square[0] == (flipped ? 6u : 1u));
            assert((uint8_t)rendered_square[1] ==
                   (flipped ? (uint8_t)(7u - col) : col));
            assert((uint8_t)rendered_square[3] == 1u);
            assert((uint8_t)rendered_square[4] == col);
        }
    }
    memset(netchesszx_hinted_rows, 0, sizeof(netchesszx_hinted_rows));
    netchesszx_hinted_rows[2] = (uint8_t)(1u << 3);
    netchesszx_hinted_rows[3] = (uint8_t)(1u << 3);
    spectrum_gui_redraw_square(2u, 3u);
    assert((uint8_t)rendered_square[3] == 2u);
    assert((uint8_t)rendered_square[4] == 3u);
    spectrum_gui_redraw_square(3u, 3u);
    assert((uint8_t)rendered_square[3] == 3u);
    assert((uint8_t)rendered_square[4] == 3u);
    memset(netchesszx_hinted_rows, 0, sizeof(netchesszx_hinted_rows));
    spectrum_gui_redraw_square(2u, 3u);
    spectrum_gui_redraw_square(3u, 3u);

    for (i = 0u; i < 100u; ++i) {
        spectrum_gui_tick();
    }
    assert(strcmp(rendered_clock, "[23:59] ") == 0);

    for (i = 0u; i < 100u; ++i) {
        ++frame_counter;
        spectrum_gui_tick();
        spectrum_gui_tick();
    }
    assert(strcmp(rendered_clock, "[00:00] ") == 0);

    frame_counter = 206u;
    spectrum_gui_set_clock(12u, 59u, 59u);
    for (i = 0u; i < 50u; ++i) {
        ++frame_counter;
        spectrum_gui_tick();
    }
    assert(frame_counter == 0u);
    assert(strcmp(rendered_clock, "[13:00] ") == 0);

    timer_draws = 0u;
    spectrum_gui_game_timer_start();
    assert(timer_draws == 1u);
    assert(strcmp(rendered_timer, "GAME:00h00m TURN:00m00s ") == 0);
    assert(rendered_timer[strlen(rendered_timer) - 1u] == ' ');
    for (i = 0u; i < 49u; ++i) {
        ++frame_counter;
        spectrum_gui_tick();
        spectrum_gui_tick();
    }
    assert(timer_draws == 1u);
    ++frame_counter;
    spectrum_gui_tick();
    assert(timer_draws == 2u);
    assert(strcmp(rendered_timer, "GAME:00h00m TURN:00m01s ") == 0);

    assert(spectrum_gui_handle_menu_key(SPECTRUM_GUI_KEY_MENU) == 0u);
    assert(timer_draws == 3u);
    assert(timer_menu_mode == 1u);
    assert(spectrum_gui_handle_menu_key(13u) == SPECTRUM_GUI_KEY_MENU_FILE);
    assert(timer_draws == 4u);
    assert(timer_menu_mode == 0u);

    rendered_notice[0] = 'x';
    rendered_notice[1] = '\0';
    spectrum_gui_notify("WAIT", 0u);
    for (i = 0u; i < 250u; ++i) {
        spectrum_gui_tick();
    }
    assert(strcmp(rendered_notice, "WAIT") == 0);
    for (i = 0u; i < 250u; ++i) {
        ++frame_counter;
        spectrum_gui_tick();
    }
    assert(rendered_notice[0] == '\0');
    return 0;
}
