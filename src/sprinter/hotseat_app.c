#include <stdint.h>
#include <string.h>

#include "spectrum/board/board.h"
#include "spectrum/config/session.h"
#include "spectrum/fileui/fileui.h"
#include "spectrum/lowram_map.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/platform/input.h"
#include "spectrum/platform/platform.h"
#include "spectrum/restore/restore.h"
#include "spectrum/saveload/saveload.h"
#include "spectrum/transport/link.h"
#include "spectrum/ui/gui.h"
#include "spectrum/ui/info_panel.h"
#include "spectrum/ui/render.h"

static uint8_t cursor_row = 6u;
static uint8_t cursor_col = 4u;
static uint8_t selected;
static uint8_t selected_row;
static uint8_t selected_col;
static uint8_t chat_editing;
static uint8_t chat_len;
static uint16_t ply;

/* SAVELOAD is deliberately transient.  Keeping its 140-byte working set in
   the permanent WIN2 scratch area avoids spending scarce base-bank BSS. */
#define SAVE_META_OFFSET 68u
#define SAVE_B64_OFFSET 80u
#define save_snapshot \
    ((spectrum_board_snapshot_t *)NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR)
#define save_meta \
    ((netchesszx_save_meta_t *)(NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR + \
                                SAVE_META_OFFSET))
#define save_b64 \
    ((char *)(NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR + SAVE_B64_OFFSET))

typedef char save_workspace_fits[
    SAVE_B64_OFFSET + NETCHESSZX_SAVE_WIRE_B64_SIZE <=
            NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_SIZE
        ? 1
        : -1];

#define chat_text ((char *)NETCHESSZX_LOWRAM_LOCAL_INPUT_ADDR)

static void show_game_input_help(void)
{
    spectrum_gui_set_input("F1 MENU; S SAVE; C CHAT; CTRL+ESC EXIT");
}

static void mark_cursor(uint8_t on)
{
    spectrum_gui_mark_cursor(cursor_row, cursor_col, on);
}

static void move_cursor(uint8_t key)
{
    mark_cursor(0u);
    if (key == 0x81u && cursor_row != 0u) {
        --cursor_row;
    } else if (key == 0x82u && cursor_row != 7u) {
        ++cursor_row;
    } else if (key == 0x83u && cursor_col != 0u) {
        --cursor_col;
    } else if (key == 0x84u && cursor_col != 7u) {
        ++cursor_col;
    }
    mark_cursor(1u);
}

static void make_move(char move[6])
{
    move[0] = (char)('a' + selected_col);
    move[1] = (char)('8' - selected_row);
    move[2] = (char)('a' + cursor_col);
    move[3] = (char)('8' - cursor_row);
    move[4] = '\0';
    move[5] = '\0';
    if ((spectrum_board_cell(selected_row, selected_col) == 'P' &&
         cursor_row == 0u) ||
        (spectrum_board_cell(selected_row, selected_col) == 'p' &&
         cursor_row == 7u)) {
        move[4] = 'q';
    }
}

static void append_u16(char *dst, uint16_t value)
{
    char digits[5];
    uint8_t count = 0u;
    do {
        digits[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0u);
    while (count != 0u) {
        *dst++ = digits[--count];
    }
    *dst = '\0';
}

static uint8_t echo_move_ack(const char *move)
{
    char wire[24] = "MOVE ";
    char reply[20];
    char expected[12] = "ACK ";
    char *end = wire + 5u;
    int16_t length;

    append_u16(end, ply);
    append_u16(expected + 4u, ply);
    end += strlen(end);
    *end++ = ' ';
    strcpy(end, move);
    if (!spectrum_net_send_text(wire)) {
        return 0u;
    }
    length = spectrum_net_read_payload(reply, sizeof(reply));
    return length == (int16_t)strlen(expected) &&
           memcmp(reply, expected, (uint8_t)length) == 0;
}

static uint8_t echo_handshake(void)
{
    char reply[32];
    int16_t length;

    if (!spectrum_net_send_text("HELLO DIRECT HOST LOCAL")) {
        return 0u;
    }
    length = spectrum_net_read_payload(reply, sizeof(reply));
    if (length < 5 || memcmp(reply, "HELLO", 5u) != 0) {
        return 0u;
    }
    if (!spectrum_net_send_text("GAME START WHITE=HOST")) {
        return 0u;
    }
    length = spectrum_net_read_payload(reply, sizeof(reply));
    return length > 9 && memcmp(reply, "ACK GAME ", 9u) == 0;
}

static uint8_t echo_control_ack(const char *command)
{
    char reply[20];
    int16_t length;
    uint8_t command_len = (uint8_t)strlen(command);

    if (!spectrum_net_send_text(command)) {
        return 0u;
    }
    length = spectrum_net_read_payload(reply, sizeof(reply));
    return length == (int16_t)(command_len + 4u) &&
           memcmp(reply, "ACK ", 4u) == 0 &&
           memcmp(reply + 4u, command, command_len) == 0;
}

static void set_turn_status(void)
{
    uint8_t check = spectrum_board_check_state();

    spectrum_gui_set_turn_label(check == SPECTRUM_BOARD_CHECK
        ? ((ply & 1u) ? SPECTRUM_GUI_TURN_WHITE_CHECK
                      : SPECTRUM_GUI_TURN_BLACK_CHECK)
        : ((ply & 1u) ? SPECTRUM_GUI_TURN_WHITE : SPECTRUM_GUI_TURN_BLACK));
    spectrum_gui_notify_persistent((ply & 1u) ? "WHITE TO MOVE"
                                              : "BLACK TO MOVE");
}

static void restore_game_view(void)
{
    chat_editing = 0u;
    selected = 0u;
    spectrum_board_clear_legal_hints();
    spectrum_gui_draw_board();
    spectrum_gui_restore_side_panels();
    spectrum_gui_set_connected(1u);
    set_turn_status();
    show_game_input_help();
    mark_cursor(1u);
}

static void reset_game(void)
{
    spectrum_board_reset();
    spectrum_gui_reset_logs();
    spectrum_gui_set_board_pieces_visible(1u);
    spectrum_gui_draw_board();
    spectrum_gui_restore_side_panels();
    spectrum_gui_set_connected(1u);
    spectrum_gui_set_turn_label(SPECTRUM_GUI_TURN_WHITE);
    spectrum_gui_notify_persistent("LOCAL HOT-SEAT");
    spectrum_gui_set_status("LOCAL DIRECT / ECHO");
    spectrum_gui_game_timer_start();
    show_game_input_help();
    chat_editing = 0u;
    selected = 0u;
    ply = 1u;
    cursor_row = 6u;
    cursor_col = 4u;
    mark_cursor(1u);
}

static void chat_begin(void)
{
    chat_text[0] = '\0';
    chat_len = 0u;
    chat_editing = 1u;
    spectrum_gui_set_input_edit(chat_text, 0u, 0u);
    spectrum_input_flush_until_release();
}

static void chat_process_key(uint8_t key)
{
    if (key == 0u) {
        return;
    }
    if (key == 0x8au) {
        chat_editing = 0u;
        show_game_input_help();
    } else if (key == 13u) {
        if (chat_len != 0u) {
            spectrum_gui_add_chat((ply & 1u) ? 'W' : 'B', chat_text);
        }
        chat_editing = 0u;
        show_game_input_help();
    } else if (key == 8u) {
        if (chat_len != 0u) {
            chat_text[--chat_len] = '\0';
            spectrum_gui_set_input_edit(chat_text, chat_len, chat_len);
        }
    } else if (key >= 32u && key < 127u &&
               chat_len < NETCHESSZX_LOWRAM_LOCAL_INPUT_SIZE - 1u) {
        chat_text[chat_len++] = (char)key;
        chat_text[chat_len] = '\0';
        spectrum_gui_set_input_edit(chat_text, chat_len, chat_len);
    }
}

static void fileui_open(void)
{
    chat_editing = 0u;
    selected = 0u;
    spectrum_board_clear_legal_hints();
    spectrum_gui_clear_cursor_coords();
    (void)spectrum_gui_show_fileui();
    if (!spectrum_fileui_open_render()) {
        restore_game_view();
        spectrum_gui_notify("FILE BROWSER ERROR", 1u);
    }
    spectrum_input_flush_until_release();
}

static uint8_t save_game(const char *name)
{
    spectrum_board_snapshot_save(save_snapshot);
    save_meta->ply = (uint16_t)(ply - 1u);
    save_meta->flags = NETCHESSZX_SAVE_FLAG_ACTIVE;
    save_meta->host_color = NETCHESSZX_SAVE_HOST_WHITE;
    save_meta->view_flags = spectrum_gui_is_board_flipped()
        ? NETCHESSZX_SAVE_VIEW_FLIPPED
        : 0u;
    memset(save_meta->timers, 0, sizeof(save_meta->timers));
    return spectrum_restore_build_b64(save_snapshot, save_meta, save_b64) &&
           spectrum_saveload_write(name, save_b64);
}

static uint8_t load_game(const char *name)
{
    if (!spectrum_saveload_read(name, save_b64) ||
        !spectrum_restore_decode(save_b64, save_snapshot, save_meta) ||
        save_meta->host_color != NETCHESSZX_SAVE_HOST_WHITE ||
        save_meta->ply == 65535u) {
        return 0u;
    }
    spectrum_board_snapshot_restore(save_snapshot);
    ply = (uint16_t)(save_meta->ply + 1u);
    spectrum_gui_set_board_view(
        (uint8_t)((save_meta->view_flags & NETCHESSZX_SAVE_VIEW_FLIPPED) != 0u));
    cursor_row = (ply & 1u) ? 6u : 1u;
    cursor_col = 4u;
    spectrum_gui_reset_logs();
    spectrum_gui_add_move((save_meta->ply & 1u) ? "1" : "2", 0);
    return 1u;
}

static void fileui_process_key(uint8_t key)
{
    uint8_t action;
    const char *name;

    if (key == 0u) {
        return;
    }
    if (key == 0x8au || key == SPECTRUM_GUI_KEY_MENU ||
        key == SPECTRUM_GUI_KEY_MENU_FILE) {
        restore_game_view();
        spectrum_input_flush_until_release();
        return;
    }
    action = spectrum_fileui_send_key(key);
    name = spectrum_fileui_selected_name();
    if (action == SPECTRUM_FILEUI_ACT_LOAD) {
        if (load_game(name)) {
            restore_game_view();
            spectrum_gui_notify_success("GAME LOADED");
        } else {
            spectrum_gui_notify("LOAD FAILED", 1u);
            (void)spectrum_fileui_rerender();
        }
    } else if (action == SPECTRUM_FILEUI_ACT_SAVE) {
        if (save_game(name)) {
            spectrum_gui_notify_success("GAME SAVED");
        } else {
            spectrum_gui_notify("SAVE FAILED", 1u);
        }
        (void)spectrum_fileui_rerender();
    } else if (action == SPECTRUM_FILEUI_ACT_ERASE) {
        if (!spectrum_saveload_erase(name)) {
            spectrum_gui_notify("ERASE FAILED", 1u);
        }
        (void)spectrum_fileui_rerender();
    }
    spectrum_input_flush_until_release();
}

static void show_setup(void)
{
    spectrum_render_board(spectrum_board_cells());
    if (!spectrum_overlay_exec_cached(SPECTRUM_OVL_MENU_CONFIG,
                                      SPECTRUM_OVL_MENU_CONFIG_RENDER)) {
        spectrum_info_show_setup();
        spectrum_info_line("\004SETUP OVERLAY ERROR");
    }
    spectrum_render_notice("STAGE 2 LOCAL HOT-SEAT");
    spectrum_render_input("ENTER STARTS; CTRL+ESC EXITS");
}

static void setup_loop(void)
{
    uint8_t key;
    show_setup();
    for (;;) {
        spectrum_frame_wait();
        spectrum_gui_tick();
        key = spectrum_key_poll();
        if (key == 13u) {
            return;
        }
        if (key == 't' || key == 'T') {
            netchesszx_board_theme_apply(
                (uint8_t)((netchesszx_board_theme_index + 1u) %
                          NETCHESSZX_BOARD_THEME_COUNT));
            show_setup();
        } else if (key == 'p' || key == 'P') {
            (void)netchesszx_piece_set_load(
                (uint8_t)((netchesszx_piece_set_index + 1u) %
                          NETCHESSZX_PIECE_SET_COUNT));
            show_setup();
        } else if (key == 'h' || key == 'H') {
            netchesszx_movement_hints = (uint8_t)!netchesszx_movement_hints;
            show_setup();
        }
    }
}

static void menu_action(uint8_t key)
{
    if (key == SPECTRUM_GUI_KEY_MENU_FILE || key == 's' || key == 'S') {
        fileui_open();
    } else if (key == SPECTRUM_GUI_KEY_MENU_DISCC) {
        spectrum_gui_notify_persistent("LOCAL LINK ALWAYS ON");
    } else if (key == 't' || key == 'T' ||
               key == SPECTRUM_GUI_KEY_MENU_THEME) {
        netchesszx_board_theme_apply(
            (uint8_t)((netchesszx_board_theme_index + 1u) %
                      NETCHESSZX_BOARD_THEME_COUNT));
        spectrum_gui_redraw_board_view();
    } else if (key == 'p' || key == 'P') {
        (void)netchesszx_piece_set_load(
            (uint8_t)((netchesszx_piece_set_index + 1u) %
                      NETCHESSZX_PIECE_SET_COUNT));
        spectrum_gui_redraw_board_view();
    } else if (key == 'f' || key == 'F' ||
               key == SPECTRUM_GUI_KEY_MENU_FLIP) {
        spectrum_gui_toggle_board_view();
    } else if (key == 'a' || key == 'A' ||
               key == SPECTRUM_GUI_KEY_MENU_ABOUT) {
        if (!spectrum_gui_show_about()) {
            spectrum_gui_notify("ABOUT ASSET ERROR", 1u);
        } else {
            spectrum_input_flush_until_release();
        }
    } else if (key == 'h' || key == 'H') {
        netchesszx_movement_hints = (uint8_t)!netchesszx_movement_hints;
        spectrum_gui_redraw_board_view();
    } else if (key == 'c' || key == 'C') {
        chat_begin();
    } else if (key == 'r' || key == 'R' ||
               key == SPECTRUM_GUI_KEY_MENU_REST) {
        if (echo_control_ack("RESET")) {
            reset_game();
        } else {
            spectrum_gui_notify("LOCAL RESET ACK FAILED", 1u);
        }
    }
}

static void select_square(void)
{
    char move[6];

    if (!selected) {
        char piece = spectrum_board_cell(cursor_row, cursor_col);
        uint8_t white = (uint8_t)(ply & 1u);
        if ((white && piece >= 'A' && piece <= 'Z') ||
            (!white && piece >= 'a' && piece <= 'z')) {
            selected = 1u;
            selected_row = cursor_row;
            selected_col = cursor_col;
            spectrum_gui_mark_cursor(cursor_row, cursor_col, 1u);
            if (netchesszx_movement_hints) {
                spectrum_board_show_legal_hints(cursor_row, cursor_col);
            }
        }
        return;
    }
    make_move(move);
    spectrum_board_clear_legal_hints();
    if (!spectrum_board_is_legal_move(move)) {
        selected = 0u;
        spectrum_gui_notify("ILLEGAL MOVE", 1u);
        spectrum_gui_redraw_board_view();
        mark_cursor(1u);
        return;
    }
    spectrum_gui_prepare_move(move);
    if (!echo_move_ack(move) || !spectrum_board_apply_trusted_move(move)) {
        spectrum_gui_notify("LOCAL ACK FAILED", 1u);
        return;
    }
    spectrum_gui_apply_move(move);
    spectrum_gui_add_move((ply & 1u) ? "W" : "B", move);
    ++ply;
    selected = 0u;
    spectrum_gui_move_timer_reset();
    set_turn_status();
    mark_cursor(1u);
}

int main(void)
{
    uint8_t key;

    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_HOST,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    spectrum_net_start_uart();
    if (!echo_handshake()) {
        spectrum_gui_notify_persistent("LOCAL LINK FAILED");
    }
    spectrum_board_reset();
    spectrum_gui_set_clock(*(volatile uint8_t *)SPRINTER_RTC_HOUR,
                           *(volatile uint8_t *)SPRINTER_RTC_MINUTE,
                           0u);
    setup_loop();
    reset_game();

    for (;;) {
        spectrum_frame_wait();
        spectrum_gui_tick();
        key = spectrum_key_poll();
        if (spectrum_gui_fileui_visible()) {
            fileui_process_key(key);
            continue;
        }
        if (spectrum_gui_about_visible()) {
            if (key != 0u) {
                restore_game_view();
                spectrum_input_flush_until_release();
            }
            continue;
        }
        if (chat_editing) {
            chat_process_key(key);
            continue;
        }
        key = spectrum_gui_handle_menu_key(key);
        if (key >= 0x81u && key <= 0x84u) {
            move_cursor(key);
        } else if (key == 13u || key == 32u) {
            select_square();
        } else if (key == 0x8au) {
            selected = 0u;
            spectrum_board_clear_legal_hints();
            spectrum_gui_redraw_board_view();
            mark_cursor(1u);
        } else if (key != 0u) {
            menu_action(key);
        }
    }
}
