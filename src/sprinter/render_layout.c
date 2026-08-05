#include "sprinter/render_layout.h"

uint16_t sprinter_square_x(uint8_t col)
{
    return (uint16_t)(SPRINTER_BOARD_X + (uint16_t)col * SPRINTER_SQUARE_SIZE);
}

uint8_t sprinter_square_y(uint8_t row)
{
    return (uint8_t)(SPRINTER_BOARD_Y + row * SPRINTER_SQUARE_SIZE);
}

uint16_t sprinter_piece_x(uint8_t col)
{
    return (uint16_t)(sprinter_square_x(col) + SPRINTER_PIECE_INSET);
}

uint8_t sprinter_piece_y(uint8_t row)
{
    return (uint8_t)(sprinter_square_y(row) + SPRINTER_PIECE_INSET);
}

uint16_t sprinter_piece_ref(uint8_t set, char piece)
{
    static const char order[] = "KQRBNP";
    uint8_t index;
    uint8_t black = (uint8_t)(piece >= 'a' && piece <= 'z');
    char folded = black ? (char)(piece - ('a' - 'A')) : piece;

    if (set >= 3u) {
        set = 0u;
    }
    for (index = 0u; index < 6u; ++index) {
        if (order[index] == folded) {
            return (uint16_t)(set * 12u + black * 6u + index);
        }
    }
    return 0xFFFFu;
}
