#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "sprinter/game_controls.h"
#include "spectrum/board/board.h"

int main(void)
{
    char move[6];
    char wire[24];
    uint8_t hinted_rows[8] = {0u};
    uint8_t to;

    assert(sprinter_game_control_action(13u) == SPRINTER_GAME_CONTROL_SELECT);
    assert(sprinter_game_control_action(32u) == SPRINTER_GAME_CONTROL_SELECT);
    assert(sprinter_game_control_action('m') == SPRINTER_GAME_CONTROL_TYPE);
    assert(sprinter_game_control_action('M') == SPRINTER_GAME_CONTROL_TYPE);
    assert(sprinter_game_control_action('c') == SPRINTER_GAME_CONTROL_CHAT);
    assert(sprinter_game_control_action('C') == SPRINTER_GAME_CONTROL_CHAT);
    assert(sprinter_game_control_action(0x81u) == SPRINTER_GAME_CONTROL_NAV);
    assert(sprinter_game_control_action(0x82u) == SPRINTER_GAME_CONTROL_NAV);
    assert(sprinter_game_control_action(0x83u) == SPRINTER_GAME_CONTROL_NAV);
    assert(sprinter_game_control_action(0x84u) == SPRINTER_GAME_CONTROL_NAV);
    assert(sprinter_game_control_action('x') == SPRINTER_GAME_CONTROL_NONE);

    spectrum_board_reset();
    assert(spectrum_board_is_legal_move("d2d4"));
    assert(spectrum_board_apply_trusted_move("d2d4"));
    assert(spectrum_board_is_legal_move_coords(
        sprinter_cursor_square_index(1u, 3u),
        sprinter_cursor_square_index(2u, 3u)));
    for (to = 0u; to < 64u; ++to) {
        if (spectrum_board_is_legal_move_coords(
                sprinter_cursor_square_index(1u, 3u), to)) {
            hinted_rows[to >> 3] |= (uint8_t)(1u << (to & 7u));
        }
    }
    assert(hinted_rows[2] == (uint8_t)(1u << 3));
    assert(hinted_rows[3] == (uint8_t)(1u << 3));
    assert((hinted_rows[2] & (uint8_t)(1u << 4)) == 0u);
    assert((hinted_rows[3] & (uint8_t)(1u << 4)) == 0u);
    sprinter_cursor_build_move(move, 1u, 3u, 2u, 3u, 'p');
    assert(strcmp(move, "d7d6") == 0);
    assert(snprintf(wire, sizeof(wire), "MOVE 2 %s", move) == 11);
    assert(strcmp(wire, "MOVE 2 d7d6") == 0);
    return 0;
}
