#include <stdint.h>

#include "gfx640.h"
#include "sprinter_layout.h"
#include "sprinter_afnt640_widths.h"
#include "sprinter/render_layout.h"
#include "sprinter_assets.h"
#include "spectrum/config/session.h"
#include "spectrum/ui/info_panel.h"
#include "spectrum/ui/layout.h"
#include "spectrum/ui/render.h"
#include "sprinter/unet_runtime.h"

#define COLOR_BLACK 0u
#define COLOR_WHITE 1u
#define COLOR_GRAY 2u
#define COLOR_ERROR 3u
#define COLOR_SUCCESS 4u
#define COLOR_BLUE 5u
#define COLOR_NOTICE 6u
#define COLOR_CYAN 7u
#define COLOR_MAGENTA 8u
#define COLOR_OUTLINE 9u

#define TEXT_HEIGHT 8u
#define PANEL_WIDTH SPRINTER_INFO_WIDTH
#define INPUT_TEXT_MAX 63u

static uint8_t render_dirty;
static char timer_text[29];
static char input_text[INPUT_TEXT_MAX + 1u];
static uint8_t input_cursor = 0xFFu;

extern uint8_t spectrum_gui_board_flipped;

static uint8_t slow_begin(void)
{
    return sprinter_rx_slow_enter();
}

static void slow_end(void)
{
    (void)sprinter_rx_slow_leave();
}

extern uint8_t sprinter_afnt_print(uint16_t x, uint8_t y, const char *text,
                                   uint8_t attribute);
extern uint8_t sprinter_palette_restore(void);
extern uint8_t sprinter_palette_about(void);

static uint8_t theme_light(void) { return SPRINTER_THEME_LIGHT_SLOT; }
static uint8_t theme_dark(void) { return SPRINTER_THEME_DARK_SLOT; }

static uint8_t attr_color(uint8_t attr)
{
    static const uint8_t colors[8] = {
        COLOR_BLACK, COLOR_BLUE, COLOR_ERROR, COLOR_MAGENTA,
        COLOR_SUCCESS, COLOR_CYAN, COLOR_NOTICE, COLOR_WHITE
    };
    return colors[attr & 7u];
}

static void fill(uint16_t x, uint8_t y, uint16_t width, uint16_t height,
                 uint8_t color)
{
    gfx640_rect_t rect;
    rect.x = x;
    rect.y = y;
    rect.width = width;
    rect.height = height;
    rect.color = color;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx640_fill_rect(&rect);
    render_dirty = 1u;
}

static void outline(uint16_t x, uint8_t y, uint16_t width, uint16_t height,
                    uint8_t color)
{
    gfx640_rect_t rect;
    rect.x = x;
    rect.y = y;
    rect.width = width;
    rect.height = height;
    rect.color = color;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx640_draw_rect(&rect);
    render_dirty = 1u;
}

static uint8_t glyph_width(char value)
{
    uint8_t code = (uint8_t)value;
    if (code < 32u || code >= 127u) {
        code = (uint8_t)' ';
    }
    return (uint8_t)(sprinter_afnt640_widths[code] * 2u);
}

static uint16_t text_width_n(const char *text, uint8_t count)
{
    uint16_t width = 0u;
    while (*text != '\0' && count != 0u) {
        width = (uint16_t)(width + glyph_width(*text++));
        --count;
    }
    return width;
}

static void draw_char(uint16_t x, uint8_t y, char value,
                      uint8_t color, uint8_t background)
{
    char text[2];
    if ((uint8_t)value == 127u) {
        fill(x, y, glyph_width(' '), TEXT_HEIGHT, color);
        return;
    }
    text[0] = value;
    text[1] = '\0';
    (void)sprinter_afnt_print(x, y, text,
                              (uint8_t)((background << 4) | color));
    render_dirty = 1u;
}

static uint16_t draw_text_width(uint16_t x, uint8_t y, const char *text,
                                uint8_t color, uint8_t background,
                                uint16_t max_width)
{
    char clipped[96];
    uint8_t length = 0u;
    uint16_t width = 0u;
    while (*text != '\0' && length + 1u < sizeof(clipped)) {
        uint8_t next = glyph_width(*text);
        if (width + next > max_width || x + width + next > SPRINTER_SCREEN_WIDTH) {
            break;
        }
        clipped[length++] = *text++;
        width = (uint16_t)(width + next);
    }
    clipped[length] = '\0';
    if (length != 0u) {
        (void)sprinter_afnt_print(x, y, clipped,
                                  (uint8_t)((background << 4) | color));
        render_dirty = 1u;
    }
    return width;
}

static void draw_text_centered(uint16_t x, uint16_t width, uint8_t y,
                               const char *text, uint8_t color)
{
    uint16_t text_width = text_width_n(text, 95u);
    uint16_t text_x = x;
    if (text_width < width) {
        text_x = (uint16_t)(x + (width - text_width) / 2u);
    }
    text_x &= 0xFFFEu;
    draw_text_width(text_x, y, text, color, COLOR_BLACK, width);
}

static void clear_text_line(uint16_t x, uint8_t y, uint16_t width)
{
    fill(x, y, width, TEXT_HEIGHT, COLOR_BLACK);
}

static void draw_piece(uint8_t row, uint8_t col, char piece)
{
    uint16_t ref = sprinter_piece_ref(netchesszx_piece_set_index, piece);
    if (ref != 0xFFFFu) {
        (void)gfx640_draw_tile_transparent(ref,
                                           sprinter_piece_x(col),
                                           sprinter_piece_y(row),
                                           GFX_TARGET_BUF0 | GFX_KEY_FF);
        render_dirty = 1u;
    }
}

static void draw_square_spec(const char *spec, uint8_t mark, uint8_t hint_piece)
{
    uint8_t row = (uint8_t)spec[0];
    uint8_t col = (uint8_t)spec[1];
    char piece = hint_piece ? spec[5] : spec[2];
    uint8_t color;

    if (row >= 8u || col >= 8u) {
        return;
    }
    color = ((row + col) & 1u) ? theme_dark() : theme_light();
    fill(sprinter_square_x(col), sprinter_square_y(row),
         SPRINTER_SQUARE_WIDTH, SPRINTER_SQUARE_HEIGHT, color);
    draw_piece(row, col, piece);
    if (mark != 0u) {
        outline(sprinter_square_x(col), sprinter_square_y(row),
                SPRINTER_SQUARE_WIDTH, SPRINTER_SQUARE_HEIGHT,
                sprinter_cursor_outline_color((uint8_t)(mark == 2u)));
    }
}

void spectrum_render_board(const char *board) __z88dk_fastcall
{
    uint8_t row;
    uint8_t col;
    char spec[3];

    if (!slow_begin()) {
        return;
    }
    (void)sprinter_palette_restore();
    fill(0u, 0u, SPRINTER_SCREEN_WIDTH, SPRINTER_SCREEN_HEIGHT, COLOR_BLACK);
    fill((uint16_t)(SPRINTER_BOARD_X - 2u), (uint8_t)(SPRINTER_BOARD_Y - 2u),
         SPRINTER_BOARD_WIDTH + 4u, 2u, COLOR_OUTLINE);
    fill((uint16_t)(SPRINTER_BOARD_X - 2u),
         (uint8_t)(SPRINTER_BOARD_Y + SPRINTER_BOARD_HEIGHT),
         SPRINTER_BOARD_WIDTH + 4u, 2u, COLOR_OUTLINE);
    fill((uint16_t)(SPRINTER_BOARD_X - 2u), SPRINTER_BOARD_Y,
         2u, SPRINTER_BOARD_HEIGHT, COLOR_OUTLINE);
    fill((uint16_t)(SPRINTER_BOARD_X + SPRINTER_BOARD_WIDTH), SPRINTER_BOARD_Y,
         2u, SPRINTER_BOARD_HEIGHT, COLOR_OUTLINE);
    for (row = 0u; row < 8u; ++row) {
        for (col = 0u; col < 8u; ++col) {
            spec[0] = (char)row;
            spec[1] = (char)col;
            spec[2] = board[(uint8_t)(row * 8u + col)];
            draw_square_spec(spec, 0u, 0u);
        }
    }
    spectrum_render_board_coords();
    slow_end();
}

void spectrum_render_board_area(const char *board) __z88dk_fastcall
{
    uint8_t row;
    uint8_t col;
    char spec[3];
    if (!slow_begin()) {
        return;
    }
    (void)sprinter_palette_restore();
    for (row = 0u; row < 8u; ++row) {
        for (col = 0u; col < 8u; ++col) {
            spec[0] = (char)row;
            spec[1] = (char)col;
            spec[2] = board[(uint8_t)(row * 8u + col)];
            draw_square_spec(spec, 0u, 0u);
        }
    }
    spectrum_render_board_coords();
    slow_end();
}

void spectrum_render_board_coords(void)
{
    uint8_t i;
    for (i = 0u; i < 8u; ++i) {
        uint8_t file_width = glyph_width(sprinter_board_file_label(i, spectrum_gui_board_flipped));
        uint8_t rank_width = glyph_width(sprinter_board_rank_label(i, spectrum_gui_board_flipped));
        draw_char((uint16_t)((sprinter_square_x(i) +
                  (SPRINTER_SQUARE_WIDTH - file_width) / 2u) & 0xFFFEu), 216u,
                  sprinter_board_file_label(i, spectrum_gui_board_flipped),
                  COLOR_GRAY, COLOR_BLACK);
        draw_char((uint16_t)(SPRINTER_BOARD_X - rank_width - 4u),
                  (uint8_t)(sprinter_square_y(i) + 8u),
                  sprinter_board_rank_label(i, spectrum_gui_board_flipped),
                  COLOR_GRAY, COLOR_BLACK);
    }
}

void spectrum_render_board_coord_mark(const char *spec) __z88dk_fastcall
{
    uint8_t row = (uint8_t)spec[0];
    uint8_t col = (uint8_t)spec[1];
    uint8_t color = spec[2] ? COLOR_NOTICE : COLOR_GRAY;
    if (row < 8u && col < 8u) {
        uint8_t file_width = glyph_width(sprinter_board_file_label(col, spectrum_gui_board_flipped));
        uint8_t rank_width = glyph_width(sprinter_board_rank_label(row, spectrum_gui_board_flipped));
        draw_char((uint16_t)((sprinter_square_x(col) +
                  (SPRINTER_SQUARE_WIDTH - file_width) / 2u) & 0xFFFEu), 216u,
                  sprinter_board_file_label(col, spectrum_gui_board_flipped),
                  color, COLOR_BLACK);
        draw_char((uint16_t)(SPRINTER_BOARD_X - rank_width - 4u),
                  (uint8_t)(sprinter_square_y(row) + 8u),
                  sprinter_board_rank_label(row, spectrum_gui_board_flipped),
                  color, COLOR_BLACK);
    }
}

void spectrum_render_status(const char *text) __z88dk_fastcall
{
    clear_text_line(0u, SPRINTER_STATUS_Y, SPRINTER_SCREEN_WIDTH);
    draw_text_width(8u, SPRINTER_STATUS_Y, text,
                    COLOR_WHITE, COLOR_BLACK, 560u);
}

void spectrum_render_status_error(const char *text) __z88dk_fastcall
{
    clear_text_line(0u, SPRINTER_STATUS_Y, SPRINTER_SCREEN_WIDTH);
    draw_text_width(8u, SPRINTER_STATUS_Y, text,
                    COLOR_ERROR, COLOR_BLACK, 560u);
}

void spectrum_render_clock(const char *text) __z88dk_fastcall
{
    draw_text_width(576u, SPRINTER_STATUS_Y, text,
                    COLOR_CYAN, COLOR_BLACK, 64u);
}

void sprinter_render_game_timer_line(const char *text, uint8_t menu_mode)
{
    uint8_t index = 0u;
    while (text[index] != '\0' && index + 1u < sizeof(timer_text)) {
        timer_text[index] = text[index];
        ++index;
    }
    timer_text[index] = '\0';
    draw_text_width(SPRINTER_INFO_X, 8u, timer_text,
                    menu_mode ? COLOR_NOTICE : COLOR_CYAN,
                    COLOR_BLACK, PANEL_WIDTH);
}

void spectrum_render_game_timer_clear(const char *text) __z88dk_fastcall
{
    fill(SPRINTER_INFO_X, 8u, PANEL_WIDTH, TEXT_HEIGHT, COLOR_BLACK);
    sprinter_render_game_timer_line(text, 0u);
}

static void render_timer_char(const char *spec, uint8_t color)
{
    uint8_t index = (uint8_t)spec[0];
    if (index < sizeof(timer_text) - 1u) {
        timer_text[index] = spec[1];
        if (timer_text[index + 1u] == '\0' && spec[1] != '\0') {
            timer_text[index + 1u] = '\0';
        }
        draw_text_width(SPRINTER_INFO_X, 8u, timer_text,
                        color, COLOR_BLACK, PANEL_WIDTH);
    }
}

void spectrum_render_game_timer_char(const char *spec) __z88dk_fastcall
{
    render_timer_char(spec, COLOR_CYAN);
}

void spectrum_render_menu_timer_char(const char *spec) __z88dk_fastcall
{
    render_timer_char(spec, COLOR_NOTICE);
}

void spectrum_render_turn_label(uint8_t mode) __z88dk_fastcall
{
    static const char *const labels[5] = {
        "WHITE TO MOVE", "BLACK TO MOVE", "WHITE CHECK", "BLACK CHECK", ""
    };
    fill(SPRINTER_INFO_X, 16u, PANEL_WIDTH, TEXT_HEIGHT, COLOR_BLACK);
    draw_text_width(SPRINTER_INFO_X, 16u, labels[mode < 5u ? mode : 4u],
                    (mode == 2u || mode == 3u) ? COLOR_ERROR : COLOR_WHITE,
                    COLOR_BLACK, PANEL_WIDTH);
}

static void render_notice(const char *text, uint8_t color)
{
    clear_text_line(0u, SPRINTER_NOTICE_Y, SPRINTER_SCREEN_WIDTH);
    draw_text_width(8u, SPRINTER_NOTICE_Y, text,
                    color, COLOR_BLACK, 624u);
}

void spectrum_render_notice(const char *text) __z88dk_fastcall
{
    render_notice(text, COLOR_NOTICE);
}

void spectrum_render_notice_error(const char *text) __z88dk_fastcall
{
    render_notice(text, COLOR_ERROR);
}

void spectrum_render_notice_success(const char *text) __z88dk_fastcall
{
    render_notice(text, COLOR_SUCCESS);
}

void spectrum_render_connection(uint8_t connected) __z88dk_fastcall
{
    fill(624u, 0u, 16u, 8u, connected ? COLOR_SUCCESS : COLOR_ERROR);
}

void spectrum_render_menu(uint8_t visible) __z88dk_fastcall
{
    static const char *const labels[6] = {
        "FILE", "DISCC", "RESET", "FLIP", "THEME", "ABOUT"
    };
    uint8_t focus;
    uint8_t option;
    uint16_t x = 8u;

    if (!slow_begin()) {
        return;
    }
    fill(0u, 0u, 408u, 16u, COLOR_BLACK);
    if (visible) {
        focus = (visible & 0x80u) ? (uint8_t)(visible & 7u)
                                  : (uint8_t)(visible - 1u);
        for (option = 0u; option < 6u; ++option) {
            uint16_t width = text_width_n(labels[option], 8u);
            draw_text_width(x, 4u, labels[option], COLOR_WHITE, COLOR_BLACK, width);
            if (focus == option) {
                outline((uint16_t)(x - 4u), 0u, width + 8u, 16u, COLOR_NOTICE);
            }
            x = (uint16_t)(x + width + 16u);
        }
    } else {
        draw_text_width(8u, 4u, "SHATRANJ", COLOR_WHITE, COLOR_BLACK, 96u);
    }
    slow_end();
}

void spectrum_render_square(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, 0u, 0u);
}

void spectrum_render_square_attr(const char *spec) __z88dk_fastcall
{
    uint8_t row = (uint8_t)spec[0];
    uint8_t col = (uint8_t)spec[1];
    if (row < 8u && col < 8u) {
        fill(sprinter_square_x(col), sprinter_square_y(row),
             SPRINTER_SQUARE_WIDTH, SPRINTER_SQUARE_HEIGHT,
             attr_color((uint8_t)spec[2]));
    }
}

static void draw_hint_spec(const char *spec)
{
    if (netchesszx_movement_hints && (uint8_t)spec[3] < 8u &&
        (uint8_t)spec[4] < 8u &&
        (netchesszx_hinted_rows[(uint8_t)spec[3]] &
         sprinter_hint_mask((uint8_t)spec[4])) != 0u) {
        outline((uint16_t)(sprinter_square_x((uint8_t)spec[1]) + 16u),
                (uint8_t)(sprinter_square_y((uint8_t)spec[0]) + 8u),
                16u, 8u, COLOR_SUCCESS);
    }
}

void spectrum_render_square_with_hint(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, 0u, 0u);
    draw_hint_spec(spec);
}

void spectrum_render_square_mark(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, (uint8_t)(spec[2] ? 2u : 1u), 0u);
}

void spectrum_render_square_mark_with_hint(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, (uint8_t)(spec[2] ? 2u : 1u), 1u);
    draw_hint_spec(spec);
}

static void draw_move_line(const char *line, uint8_t row)
{
    uint8_t color = ((uint8_t)line[0] & 0x80u) ? COLOR_ERROR : COLOR_WHITE;
    draw_text_width(424u, (uint8_t)(48u + row * 8u), line,
                    color, COLOR_BLACK, 96u);
    draw_text_width(528u, (uint8_t)(48u + row * 8u), line + 18u,
                    COLOR_WHITE, COLOR_BLACK, 112u);
}

void spectrum_render_moves(const char *moves) __z88dk_fastcall
{
    uint8_t row;
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 48u, PANEL_WIDTH, 56u, COLOR_BLACK);
    for (row = 0u; row < NETCHESSZX_MOVE_ROWS; ++row) {
        draw_move_line(moves + row * NETCHESSZX_MOVE_SLOT_SIZE, row);
    }
    slow_end();
}

void spectrum_render_move_at(const char *line) __z88dk_fastcall
{
    uint16_t offset = (uint16_t)line - NETCHESSZX_LOWRAM_MOVE_LOG_ADDR;
    uint8_t row = (uint8_t)(offset / NETCHESSZX_MOVE_SLOT_SIZE);
    if (row < NETCHESSZX_MOVE_ROWS) {
        fill(SPRINTER_INFO_X, (uint8_t)(48u + row * 8u),
             PANEL_WIDTH, TEXT_HEIGHT, COLOR_BLACK);
        draw_move_line(line, row);
    }
}

static void scroll_panel(uint8_t y, uint8_t height)
{
    gfx640_scroll_rect_t rect;
    rect.x = SPRINTER_INFO_X;
    rect.y = y;
    rect.width = PANEL_WIDTH;
    rect.height = height;
    rect.dx = 0;
    rect.dy = -8;
    rect.fill_color = COLOR_BLACK;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx640_scroll_rect(&rect);
    render_dirty = 1u;
}

void spectrum_render_moves_scroll(void)
{
    if (slow_begin()) {
        scroll_panel(48u, 56u);
        slow_end();
    }
}

static void draw_chat_line(const char *line, uint8_t row)
{
    uint8_t side = (uint8_t)line[0];
    uint8_t color = side == 'W' ? COLOR_WHITE :
                    side == 'B' ? COLOR_GRAY : COLOR_NOTICE;
    draw_text_width(424u, (uint8_t)(112u + row * 8u), line + 1u,
                    color, COLOR_BLACK, 216u);
}

void spectrum_render_chat(const char *chat) __z88dk_fastcall
{
    uint8_t row;
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 104u, PANEL_WIDTH, 80u, COLOR_BLACK);
    for (row = 0u; row < NETCHESSZX_CHAT_ROWS; ++row) {
        draw_chat_line(chat + row * NETCHESSZX_CHAT_SLOT_SIZE, row);
    }
    slow_end();
}

void spectrum_render_chat_at(const char *line) __z88dk_fastcall
{
    uint16_t offset = (uint16_t)line - NETCHESSZX_LOWRAM_CHAT_LOG_ADDR;
    uint8_t row = (uint8_t)(offset / NETCHESSZX_CHAT_SLOT_SIZE);
    if (row < NETCHESSZX_CHAT_ROWS) {
        fill(SPRINTER_INFO_X, (uint8_t)(112u + row * 8u),
             PANEL_WIDTH, TEXT_HEIGHT, COLOR_BLACK);
        draw_chat_line(line, row);
    }
}

void spectrum_render_chat_scroll(void)
{
    if (slow_begin()) {
        scroll_panel(112u, 72u);
        slow_end();
    }
}

static void render_input_line(void)
{
    uint16_t x;
    clear_text_line(0u, SPRINTER_INPUT_Y, SPRINTER_SCREEN_WIDTH);
    x = draw_text_width(0u, SPRINTER_INPUT_Y, "> ",
                        COLOR_CYAN, COLOR_BLACK, 16u);
    if (input_cursor == 0xFFu) {
        draw_text_width(x, SPRINTER_INPUT_Y, input_text,
                        COLOR_WHITE, COLOR_BLACK,
                        (uint16_t)(SPRINTER_SCREEN_WIDTH - x));
    } else {
        char saved = input_text[input_cursor];
        uint16_t cursor_x;
        input_text[input_cursor] = '\0';
        cursor_x = (uint16_t)(x + draw_text_width(
            x, SPRINTER_INPUT_Y, input_text, COLOR_WHITE, COLOR_BLACK,
            (uint16_t)(SPRINTER_SCREEN_WIDTH - x)));
        input_text[input_cursor] = saved;
        draw_char(cursor_x, SPRINTER_INPUT_Y,
                  saved == '\0' ? ' ' : saved, COLOR_BLACK, COLOR_WHITE);
        if (saved != '\0') {
            draw_text_width((uint16_t)(cursor_x + glyph_width(saved)),
                            SPRINTER_INPUT_Y, input_text + input_cursor + 1u,
                            COLOR_WHITE, COLOR_BLACK,
                            (uint16_t)(SPRINTER_SCREEN_WIDTH - cursor_x - glyph_width(saved)));
        }
    }
}

void spectrum_render_input(const char *text) __z88dk_fastcall
{
    uint8_t length = 0u;
    while (text[length] != '\0' && length < INPUT_TEXT_MAX) {
        input_text[length] = text[length];
        ++length;
    }
    input_text[length] = '\0';
    input_cursor = 0xFFu;
    render_input_line();
}

void spectrum_render_input_cell(const char *spec) __z88dk_fastcall
{
    uint8_t position = (uint8_t)spec[0];
    if (position <= INPUT_TEXT_MAX) {
        if (!spec[2] && position < INPUT_TEXT_MAX && spec[1] != '\0') {
            input_text[position] = spec[1];
        }
        input_cursor = spec[2] ? position : 0xFFu;
        render_input_line();
    }
}

uint8_t spectrum_render_about(void)
{
    uint8_t row;
    uint8_t col;
    if (!slow_begin()) {
        return 0u;
    }
    if (!sprinter_palette_about()) {
        slow_end();
        return 0u;
    }
    fill(SPRINTER_BOARD_X, SPRINTER_BOARD_Y,
         SPRINTER_BOARD_WIDTH, SPRINTER_BOARD_HEIGHT, COLOR_BLACK);
    for (row = 0u; row < 12u; ++row) {
        for (col = 0u; col < 12u; ++col) {
            uint16_t tile = (uint16_t)(36u + row * 12u + col);
            uint16_t ref = (uint16_t)(((tile >> 6) << 8) | (tile & 63u));
            if (gfx640_draw_tile(ref,
                                 (uint16_t)(SPRINTER_BOARD_X + col * 32u),
                                 (uint8_t)(SPRINTER_BOARD_Y + row * 16u),
                                 GFX_TARGET_BUF0) != 0u) {
                (void)sprinter_palette_restore();
                slow_end();
                return 0u;
            }
        }
    }
    draw_text_centered(SPRINTER_BOARD_X, SPRINTER_BOARD_WIDTH, 192u,
                       "ONLINE CHESS FOR SPRINTER", COLOR_WHITE);
    draw_text_centered(SPRINTER_BOARD_X, SPRINTER_BOARD_WIDTH, 208u,
                       "GPL-2.0", COLOR_CYAN);
    render_dirty = 1u;
    slow_end();
    return (uint8_t)!sprinter_unet_faulted();
}

void spectrum_render_ikkle_at(const char *spec) __z88dk_fastcall
{
    draw_text_width((uint16_t)((uint8_t)spec[1] * 8u),
                    (uint8_t)((uint8_t)spec[0] * 8u), spec + 3u,
                    attr_color((uint8_t)spec[2]), COLOR_BLACK,
                    (uint16_t)(SPRINTER_SCREEN_WIDTH - (uint8_t)spec[1] * 8u));
}

void spectrum_render_fileui_frame(void)
{
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_BOARD_X, SPRINTER_BOARD_Y,
         SPRINTER_BOARD_WIDTH, SPRINTER_BOARD_HEIGHT, COLOR_BLACK);
    outline(80u, 48u, 256u, 144u, COLOR_CYAN);
    slow_end();
}

void spectrum_render_fileui_select(uint16_t slot_on) __z88dk_fastcall
{
    uint8_t slot = (uint8_t)slot_on;
    uint8_t selected = (uint8_t)(slot_on >> 8);
    if (slot < 10u) {
        outline(96u, (uint8_t)(88u + slot * 8u), 224u, 8u,
                selected ? COLOR_NOTICE : COLOR_BLACK);
    }
}

static void info_header(const char *title)
{
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 24u, PANEL_WIDTH, 198u, COLOR_BLACK);
    draw_text_width(424u, 24u, title, COLOR_CYAN, COLOR_BLACK, 216u);
    slow_end();
}

void spectrum_info_show_game(void)
{
    info_header("WHITE       BLACK");
    draw_text_width(424u, 96u, "CHAT", COLOR_CYAN, COLOR_BLACK, 216u);
}

void spectrum_info_show_setup(void)
{
    info_header("GAME SETUP");
}

void spectrum_info_show_game_setup(void)
{
    info_header("STARTING LOCAL GAME");
}

void spectrum_info_show_preflight(void)
{
    info_header("CHECKING LINK");
}

void spectrum_info_clear_tail(uint8_t row) __z88dk_fastcall
{
    uint8_t y = (uint8_t)(row * 8u);
    if (y < 224u && slow_begin()) {
        fill(SPRINTER_INFO_X, y, PANEL_WIDTH, (uint8_t)(224u - y), COLOR_BLACK);
        slow_end();
    }
}

void spectrum_info_line(const char *line) __z88dk_fastcall
{
    uint8_t row = (uint8_t)*line++;
    uint8_t y;
    if (row < 32u) {
        y = (uint8_t)(row * 8u + 2u);
    } else {
        --line;
        y = 34u;
    }
    if (y < 224u) {
        fill(424u, (uint8_t)(y - 2u), 216u, TEXT_HEIGHT, COLOR_BLACK);
        draw_text_width(424u, (uint8_t)(y - 2u), line,
                        COLOR_WHITE, COLOR_BLACK, 216u);
    }
}

uint8_t sprinter_render_present(void)
{
    if (!render_dirty) {
        return 1u;
    }
    /* The pinned DSS/MAME screen-1 descriptor path intermittently exposes a
       partial raster although both VRAM buffers remain byte-complete.  Keep
       the stable screen zero selected and publish primitives there directly. */
    render_dirty = 0u;
    return (uint8_t)!sprinter_unet_faulted();
}
