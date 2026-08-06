#include <stdint.h>

#include "gfx320.h"
#include "sprinter_layout.h"
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

#define TEXT_WIDTH 4u
#define TEXT_HEIGHT 4u
#define PANEL_WIDTH 112u

/* Upper-case Ikkle glyphs, ASCII 32..95.  Each byte contains two 4-pixel
   rows.  Lowercase is deliberately folded, matching the Spectrum renderer. */
static const uint8_t ikkle_font[128] = {
    0x00,0x00,0x88,0x08,0x08,0x00,0xF9,0xF0,0xF9,0xF0,0xF9,0xF0,0xF9,0xF0,0x08,0x00,
    0x48,0x84,0x84,0x48,0x08,0x00,0x04,0xE4,0x00,0x0C,0x00,0xC0,0x00,0x08,0x24,0x48,
    0xEA,0xAE,0xC4,0x4E,0xE2,0x4E,0xE6,0x2E,0x8A,0xE2,0xEC,0x2C,0xEC,0xAE,0xE2,0x48,
    0xEE,0xAE,0xEA,0x6E,0x08,0x08,0x04,0x0C,0x06,0x86,0x0C,0x0C,0x0C,0x2C,0xE6,0x04,
    0xF9,0xF0,0xEA,0xEA,0xEE,0xAE,0xC8,0x8C,0xCA,0xAE,0xEC,0x8E,0xE8,0xC8,0xE8,0xAE,
    0xAE,0xAA,0x44,0x44,0x44,0x4C,0xAC,0xAA,0x88,0x8C,0xAE,0xEA,0xCA,0xAA,0xEA,0xAE,
    0xEA,0xE8,0xEA,0xE2,0xEA,0xCA,0xEC,0x2E,0xE4,0x44,0xAA,0xAE,0xAA,0xA4,0xAA,0xEE,
    0xA4,0x4A,0xAE,0x44,0xE6,0x8E,0xC8,0x8C,0x84,0x42,0xC4,0x4C,0x4A,0x00,0x00,0x0C
};

static uint8_t render_dirty;

extern uint8_t spectrum_gui_board_flipped;

static uint8_t slow_begin(void)
{
    return sprinter_rx_slow_enter();
}

static void slow_end(void)
{
    (void)sprinter_rx_slow_leave();
}

void sprinter_render_row4(const uint8_t *spec) __z88dk_fastcall;

static uint8_t theme_light(void)
{
    static const uint8_t colors[5] = {
        SPRINTER_THEME_0_LIGHT, SPRINTER_THEME_1_LIGHT,
        SPRINTER_THEME_2_LIGHT, SPRINTER_THEME_3_LIGHT,
        SPRINTER_THEME_4_LIGHT
    };
    uint8_t theme = netchesszx_board_theme_index;
    return colors[theme < 5u ? theme : 0u];
}

static uint8_t theme_dark(void)
{
    static const uint8_t colors[5] = {
        SPRINTER_THEME_0_DARK, SPRINTER_THEME_1_DARK,
        SPRINTER_THEME_2_DARK, SPRINTER_THEME_3_DARK,
        SPRINTER_THEME_4_DARK
    };
    uint8_t theme = netchesszx_board_theme_index;
    return colors[theme < 5u ? theme : 0u];
}

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
    gfx320_rect_t rect;
    rect.x = x;
    rect.y = y;
    rect.width = width;
    rect.height = height;
    rect.color = color;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx320_fill_rect(&rect);
    render_dirty = 1u;
}

static void outline(uint16_t x, uint8_t y, uint16_t width, uint16_t height,
                    uint8_t color)
{
    gfx320_rect_t rect;
    rect.x = x;
    rect.y = y;
    rect.width = width;
    rect.height = height;
    rect.color = color;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx320_draw_rect(&rect);
    render_dirty = 1u;
}

static void draw_char(uint16_t x, uint8_t y, char value,
                      uint8_t color, uint8_t background)
{
    uint8_t glyph;
    uint8_t row;
    uint8_t spec[7];

    if (value >= 'a' && value <= 'z') {
        value = (char)(value - ('a' - 'A'));
    }
    if ((uint8_t)value == 127u) {
        fill(x, y, TEXT_WIDTH, TEXT_HEIGHT, color);
        return;
    }
    if (value < 32 || value > 95) {
        value = ' ';
    }
    glyph = (uint8_t)(value - 32) * 2u;
    spec[0] = (uint8_t)x;
    spec[1] = (uint8_t)(x >> 8);
    spec[4] = color;
    spec[5] = background;
    for (row = 0u; row < TEXT_HEIGHT; ++row) {
        uint8_t packed = ikkle_font[(uint8_t)(glyph + (row >> 1))];
        spec[2] = (uint8_t)(y + row);
        spec[3] = (uint8_t)((row & 1u) ? packed & 0x0Fu : packed >> 4);
        spec[6] = GFX_TARGET_BUF0;
        sprinter_render_row4(spec);
    }
    render_dirty = 1u;
}

static void draw_text_limit(uint16_t x, uint8_t y, const char *text,
                            uint8_t color, uint8_t background, uint8_t limit)
{
    while (*text != '\0' && limit != 0u && x + TEXT_WIDTH <= 320u) {
        draw_char(x, y, *text++, color, background);
        x += TEXT_WIDTH;
        --limit;
    }
}

static void clear_text_line(uint16_t x, uint8_t y, uint16_t width)
{
    fill(x, y, width, 6u, COLOR_BLACK);
}

static void draw_piece(uint8_t row, uint8_t col, char piece)
{
    uint16_t ref = sprinter_piece_ref(netchesszx_piece_set_index, piece);
    if (ref != 0xFFFFu) {
        (void)gfx320_draw_tile(ref, sprinter_piece_x(col), sprinter_piece_y(row),
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
         SPRINTER_SQUARE_SIZE, SPRINTER_SQUARE_SIZE, color);
    draw_piece(row, col, piece);
    if (mark != 0u) {
        outline(sprinter_square_x(col), sprinter_square_y(row),
                SPRINTER_SQUARE_SIZE, SPRINTER_SQUARE_SIZE,
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
    fill(0u, 0u, 320u, 256u, COLOR_BLACK);
    outline((uint16_t)(SPRINTER_BOARD_X - 1u), (uint8_t)(SPRINTER_BOARD_Y - 1u),
            SPRINTER_BOARD_SIZE + 2u, SPRINTER_BOARD_SIZE + 2u, COLOR_OUTLINE);
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
        draw_char((uint16_t)(sprinter_square_x(i) + 10u), 217u,
                  sprinter_board_file_label(i, spectrum_gui_board_flipped),
                  COLOR_GRAY, COLOR_BLACK);
        draw_char(1u, (uint8_t)(sprinter_square_y(i) + 10u),
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
        draw_char((uint16_t)(sprinter_square_x(col) + 10u), 217u,
                  sprinter_board_file_label(col, spectrum_gui_board_flipped),
                  color, COLOR_BLACK);
        draw_char(1u, (uint8_t)(sprinter_square_y(row) + 10u),
                  sprinter_board_rank_label(row, spectrum_gui_board_flipped),
                  color, COLOR_BLACK);
    }
}

void spectrum_render_status(const char *text) __z88dk_fastcall
{
    clear_text_line(0u, SPRINTER_STATUS_Y, 320u);
    draw_text_limit(4u, SPRINTER_STATUS_Y + 1u, text,
                    COLOR_WHITE, COLOR_BLACK, 72u);
}

void spectrum_render_status_error(const char *text) __z88dk_fastcall
{
    clear_text_line(0u, SPRINTER_STATUS_Y, 320u);
    draw_text_limit(4u, SPRINTER_STATUS_Y + 1u, text,
                    COLOR_ERROR, COLOR_BLACK, 72u);
}

void spectrum_render_clock(const char *text) __z88dk_fastcall
{
    fill(288u, SPRINTER_STATUS_Y, 32u, 6u, COLOR_BLACK);
    draw_text_limit(288u, SPRINTER_STATUS_Y + 1u, text,
                    COLOR_CYAN, COLOR_BLACK, 8u);
}

void spectrum_render_game_timer_clear(const char *text) __z88dk_fastcall
{
    fill(SPRINTER_INFO_X, 8u, PANEL_WIDTH, 6u, COLOR_BLACK);
    draw_text_limit(SPRINTER_INFO_X, 9u, text, COLOR_CYAN, COLOR_BLACK, 28u);
}

static void render_timer_char(const char *spec, uint8_t color)
{
    uint16_t x = (uint16_t)(SPRINTER_INFO_X + (uint8_t)spec[0] * TEXT_WIDTH);
    draw_char(x, 9u, spec[1], color, COLOR_BLACK);
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
    fill(SPRINTER_INFO_X, 16u, PANEL_WIDTH, 6u, COLOR_BLACK);
    draw_text_limit(SPRINTER_INFO_X, 17u, labels[mode < 5u ? mode : 4u],
                    (mode == 2u || mode == 3u) ? COLOR_ERROR : COLOR_WHITE,
                    COLOR_BLACK, 28u);
}

static void render_notice(const char *text, uint8_t color)
{
    clear_text_line(0u, SPRINTER_NOTICE_Y, 320u);
    draw_text_limit(4u, SPRINTER_NOTICE_Y + 1u, text,
                    color, COLOR_BLACK, 78u);
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
    fill(308u, 0u, 8u, 8u, connected ? COLOR_SUCCESS : COLOR_ERROR);
}

void spectrum_render_menu(uint8_t visible) __z88dk_fastcall
{
    static const uint8_t option_x[6] = {4u, 24u, 48u, 72u, 92u, 116u};
    static const uint8_t option_width[6] = {16u, 20u, 20u, 16u, 20u, 20u};
    uint8_t focus;

    if (!slow_begin()) {
        return;
    }
    fill(0u, 0u, 204u, 16u, COLOR_BLACK);
    if (visible) {
        draw_text_limit(4u, 5u, "FILE DISCC RESET FLIP THEME ABOUT",
                        COLOR_WHITE, COLOR_BLACK, 49u);
        focus = (visible & 0x80u) ? (uint8_t)(visible & 7u)
                                  : (uint8_t)(visible - 1u);
        if (focus < 6u) {
            outline(option_x[focus], 1u, option_width[focus], 14u,
                    COLOR_NOTICE);
        }
    } else {
        draw_text_limit(4u, 5u, "SHATRANJ", COLOR_WHITE, COLOR_BLACK, 16u);
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
             SPRINTER_SQUARE_SIZE, SPRINTER_SQUARE_SIZE,
             attr_color((uint8_t)spec[2]));
    }
}

void spectrum_render_square_with_hint(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, 0u, 0u);
    if (netchesszx_movement_hints && (uint8_t)spec[3] < 8u &&
        (uint8_t)spec[4] < 8u &&
        (netchesszx_hinted_rows[(uint8_t)spec[3]] &
         (uint8_t)(0x80u >> (uint8_t)spec[4])) != 0u) {
        outline((uint16_t)(sprinter_square_x((uint8_t)spec[1]) + 8u),
                (uint8_t)(sprinter_square_y((uint8_t)spec[0]) + 8u),
                8u, 8u, COLOR_SUCCESS);
    }
}

void spectrum_render_square_mark(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, (uint8_t)(spec[2] ? 2u : 1u), 0u);
}

void spectrum_render_square_mark_with_hint(const char *spec) __z88dk_fastcall
{
    draw_square_spec(spec, (uint8_t)(spec[2] ? 2u : 1u), 1u);
}

static void draw_move_line(const char *line, uint8_t row)
{
    uint8_t color = ((uint8_t)line[0] & 0x80u) ? COLOR_ERROR : COLOR_WHITE;
    draw_text_limit(212u, (uint8_t)(51u + row * 6u), line,
                    color, COLOR_BLACK, 14u);
    draw_text_limit(268u, (uint8_t)(51u + row * 6u), line + 18u,
                    COLOR_WHITE, COLOR_BLACK, 13u);
}

void spectrum_render_moves(const char *moves) __z88dk_fastcall
{
    uint8_t row;
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 50u, PANEL_WIDTH, 43u, COLOR_BLACK);
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
        fill(SPRINTER_INFO_X, (uint8_t)(50u + row * 6u), PANEL_WIDTH, 6u, COLOR_BLACK);
        draw_move_line(line, row);
    }
}

static void scroll_panel(uint8_t y, uint8_t height)
{
    gfx320_scroll_rect_t rect;
    rect.x = SPRINTER_INFO_X;
    rect.y = y;
    rect.width = PANEL_WIDTH;
    rect.height = height;
    rect.dx = 0;
    rect.dy = -6;
    rect.fill_color = COLOR_BLACK;
    rect.flags = GFX_TARGET_BUF0;
    rect.reserved[0] = rect.reserved[1] = rect.reserved[2] = 0u;
    (void)gfx320_scroll_rect(&rect);
    render_dirty = 1u;
}

void spectrum_render_moves_scroll(void)
{
    if (slow_begin()) {
        scroll_panel(51u, 42u);
        slow_end();
    }
}

static void draw_chat_line(const char *line, uint8_t row)
{
    uint8_t side = (uint8_t)line[0];
    uint8_t color = side == 'W' ? COLOR_WHITE :
                    side == 'B' ? COLOR_GRAY : COLOR_NOTICE;
    draw_text_limit(212u, (uint8_t)(110u + row * 6u), line + 1u,
                    color, COLOR_BLACK, 27u);
}

void spectrum_render_chat(const char *chat) __z88dk_fastcall
{
    uint8_t row;
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 108u, PANEL_WIDTH, 67u, COLOR_BLACK);
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
        fill(SPRINTER_INFO_X, (uint8_t)(108u + row * 6u), PANEL_WIDTH, 6u, COLOR_BLACK);
        draw_chat_line(line, row);
    }
}

void spectrum_render_chat_scroll(void)
{
    if (slow_begin()) {
        scroll_panel(110u, 54u);
        slow_end();
    }
}

void spectrum_render_input(const char *text) __z88dk_fastcall
{
    clear_text_line(0u, SPRINTER_INPUT_Y, 320u);
    draw_text_limit(0u, SPRINTER_INPUT_Y + 1u, "> ",
                    COLOR_CYAN, COLOR_BLACK, 2u);
    draw_text_limit(8u, SPRINTER_INPUT_Y + 1u, text,
                    COLOR_WHITE, COLOR_BLACK, 61u);
}

void spectrum_render_input_cell(const char *spec) __z88dk_fastcall
{
    uint16_t x = (uint16_t)(8u + (uint8_t)spec[0] * TEXT_WIDTH);
    draw_char(x, SPRINTER_INPUT_Y + 1u, spec[1],
              spec[2] ? COLOR_BLACK : COLOR_WHITE,
              spec[2] ? COLOR_WHITE : COLOR_BLACK);
}

uint8_t spectrum_render_about(void)
{
    uint8_t row;
    uint8_t col;
    if (!slow_begin()) {
        return 0u;
    }
    fill(0u, 0u, 320u, 224u, COLOR_BLACK);
    for (row = 0u; row < 12u; ++row) {
        for (col = 0u; col < 16u; ++col) {
            uint16_t tile = (uint16_t)(64u + row * 16u + col);
            uint16_t ref = (uint16_t)(((tile >> 6) << 8) | (tile & 63u));
            if (gfx320_draw_tile(ref, (uint16_t)(32u + col * 16u),
                                 (uint8_t)(32u + row * 16u),
                                 GFX_TARGET_BUF0) != 0u) {
                slow_end();
                return 0u;
            }
        }
    }
    render_dirty = 1u;
    slow_end();
    return (uint8_t)!sprinter_unet_faulted();
}

void spectrum_render_ikkle_at(const char *spec) __z88dk_fastcall
{
    draw_text_limit((uint16_t)((uint8_t)spec[1] * TEXT_WIDTH),
                    (uint8_t)((uint8_t)spec[0] * 8u + 2u), spec + 3u,
                    attr_color((uint8_t)spec[2]), COLOR_BLACK, 64u);
}

void spectrum_render_fileui_frame(void)
{
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_BOARD_X, SPRINTER_BOARD_Y,
         SPRINTER_BOARD_SIZE, SPRINTER_BOARD_SIZE, COLOR_BLACK);
    outline(40u, 48u, 128u, 144u, COLOR_CYAN);
    slow_end();
}

void spectrum_render_fileui_select(uint16_t slot_on) __z88dk_fastcall
{
    uint8_t slot = (uint8_t)slot_on;
    uint8_t selected = (uint8_t)(slot_on >> 8);
    if (slot < 10u) {
        outline(48u, (uint8_t)(88u + slot * 8u), 112u, 8u,
                selected ? COLOR_NOTICE : COLOR_BLACK);
    }
}

static void info_header(const char *title)
{
    if (!slow_begin()) {
        return;
    }
    fill(SPRINTER_INFO_X, 24u, PANEL_WIDTH, 198u, COLOR_BLACK);
    draw_text_limit(212u, 27u, title, COLOR_CYAN, COLOR_BLACK, 27u);
    slow_end();
}

void spectrum_info_show_game(void)
{
    info_header("WHITE       BLACK");
    draw_text_limit(212u, 99u, "CHAT", COLOR_CYAN, COLOR_BLACK, 27u);
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
        fill(212u, (uint8_t)(y - 1u), 108u, 7u, COLOR_BLACK);
        draw_text_limit(212u, y, line, COLOR_WHITE, COLOR_BLACK, 27u);
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
