#ifndef SHATRANJ_SPRINTER_RENDER_LAYOUT_H
#define SHATRANJ_SPRINTER_RENDER_LAYOUT_H

#include <stdint.h>

#define SPRINTER_BOARD_X 8u
#define SPRINTER_BOARD_Y 24u
#define SPRINTER_BOARD_SIZE 192u
#define SPRINTER_SQUARE_SIZE 24u
#define SPRINTER_PIECE_SIZE 16u
#define SPRINTER_PIECE_INSET 4u
#define SPRINTER_INFO_X 208u
#define SPRINTER_STATUS_Y 224u
#define SPRINTER_NOTICE_Y 232u
#define SPRINTER_INPUT_Y 240u

uint16_t sprinter_square_x(uint8_t col);
uint8_t sprinter_square_y(uint8_t row);
uint16_t sprinter_piece_x(uint8_t col);
uint8_t sprinter_piece_y(uint8_t row);
uint16_t sprinter_piece_ref(uint8_t set, char piece);

#endif
