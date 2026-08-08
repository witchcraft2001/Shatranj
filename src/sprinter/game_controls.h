#ifndef SHATRANJ_SPRINTER_GAME_CONTROLS_H
#define SHATRANJ_SPRINTER_GAME_CONTROLS_H

#include <stdint.h>

#define SPRINTER_GAME_CONTROL_NONE 0u
#define SPRINTER_GAME_CONTROL_SELECT 1u
#define SPRINTER_GAME_CONTROL_TYPE 2u
#define SPRINTER_GAME_CONTROL_CHAT 3u
#define SPRINTER_GAME_CONTROL_NAV 4u

static uint8_t sprinter_game_control_action(uint8_t key)
{
    if (key == 13u || key == 32u) {
        return SPRINTER_GAME_CONTROL_SELECT;
    }
    if (key == 'm' || key == 'M') {
        return SPRINTER_GAME_CONTROL_TYPE;
    }
    if (key == 'c' || key == 'C') {
        return SPRINTER_GAME_CONTROL_CHAT;
    }
    if (key >= 0x81u && key <= 0x84u) {
        return SPRINTER_GAME_CONTROL_NAV;
    }
    return SPRINTER_GAME_CONTROL_NONE;
}

static void sprinter_cursor_build_move(char move[6],
                                       uint8_t from_row, uint8_t from_col,
                                       uint8_t to_row, uint8_t to_col,
                                       char piece)
{
    move[0] = (char)('a' + from_col);
    move[1] = (char)('8' - from_row);
    move[2] = (char)('a' + to_col);
    move[3] = (char)('8' - to_row);
    move[4] = '\0';
    move[5] = '\0';
    if ((piece == 'P' && to_row == 0u) ||
        (piece == 'p' && to_row == 7u)) {
        move[4] = 'q';
    }
}

static uint8_t sprinter_cursor_square_index(uint8_t row, uint8_t col)
{
    return (uint8_t)((row << 3) + col);
}

#endif
