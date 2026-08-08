#include <assert.h>

#include "sprinter/render_layout.h"

int main(void)
{
    uint8_t col;

    assert(sprinter_square_x(0) == 16u);
    assert(sprinter_square_x(7) == 352u);
    assert(sprinter_square_y(0) == 24u);
    assert(sprinter_square_y(7) == 192u);
    assert(sprinter_piece_x(7) == 360u);
    assert(sprinter_piece_y(7) == 196u);
    assert(sprinter_piece_ref(0, 'K') == 0u);
    assert(sprinter_piece_ref(0, 'p') == 11u);
    assert(sprinter_piece_ref(2, 'q') == 31u);
    assert(sprinter_piece_ref(2, 'r') == 32u);
    assert(sprinter_piece_ref(2, 'b') == 33u);
    assert(sprinter_piece_ref(2, 'n') == 34u);
    assert(sprinter_piece_ref(2, 'p') == 35u);
    assert(sprinter_piece_ref(3, 'X') == 0xFFFFu);
    assert(sprinter_cursor_outline_color(0u) == SPRINTER_CURSOR_GRAY);
    assert(sprinter_cursor_outline_color(1u) == SPRINTER_CURSOR_SELECTED);
    for (col = 0u; col < 8u; ++col) {
        assert(sprinter_hint_mask(col) == (uint8_t)(1u << col));
    }
    assert(sprinter_hint_mask(8u) == 0u);
    assert(SPRINTER_CURSOR_GRAY != SPRINTER_CURSOR_SELECTED);
    assert(sprinter_board_file_label(0u, 0u) == 'A');
    assert(sprinter_board_file_label(7u, 0u) == 'H');
    assert(sprinter_board_rank_label(0u, 0u) == '8');
    assert(sprinter_board_rank_label(7u, 0u) == '1');
    assert(sprinter_board_file_label(0u, 1u) == 'H');
    assert(sprinter_board_file_label(7u, 1u) == 'A');
    assert(sprinter_board_rank_label(0u, 1u) == '1');
    assert(sprinter_board_rank_label(7u, 1u) == '8');
    assert(SPRINTER_INFO_X > SPRINTER_BOARD_X + SPRINTER_BOARD_SIZE);
    assert(SPRINTER_BOARD_WIDTH == 384u);
    assert(SPRINTER_BOARD_HEIGHT == 192u);
    assert(SPRINTER_SQUARE_WIDTH == 48u);
    assert(SPRINTER_SQUARE_HEIGHT == 24u);
    assert(SPRINTER_PIECE_WIDTH == 32u);
    assert(SPRINTER_PIECE_HEIGHT == 16u);
    assert(SPRINTER_STATUS_Y == 224u);
    assert(SPRINTER_NOTICE_Y == 232u);
    assert(SPRINTER_INPUT_Y == 240u);
    return 0;
}
