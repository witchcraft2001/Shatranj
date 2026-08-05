#include <assert.h>

#include "sprinter/render_layout.h"

int main(void)
{
    assert(sprinter_square_x(0) == 8u);
    assert(sprinter_square_x(7) == 176u);
    assert(sprinter_square_y(0) == 24u);
    assert(sprinter_square_y(7) == 192u);
    assert(sprinter_piece_x(7) == 180u);
    assert(sprinter_piece_y(7) == 196u);
    assert(sprinter_piece_ref(0, 'K') == 0u);
    assert(sprinter_piece_ref(0, 'p') == 11u);
    assert(sprinter_piece_ref(2, 'q') == 31u);
    assert(sprinter_piece_ref(3, 'X') == 0xFFFFu);
    assert(SPRINTER_INFO_X > SPRINTER_BOARD_X + SPRINTER_BOARD_SIZE);
    assert(SPRINTER_STATUS_Y == 224u);
    assert(SPRINTER_NOTICE_Y == 232u);
    assert(SPRINTER_INPUT_Y == 240u);
    return 0;
}
