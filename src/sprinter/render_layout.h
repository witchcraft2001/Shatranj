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
#define SPRINTER_CURSOR_GRAY 2u
#define SPRINTER_CURSOR_SELECTED 6u

uint16_t sprinter_square_x(uint8_t col);
uint8_t sprinter_square_y(uint8_t row);
uint16_t sprinter_piece_x(uint8_t col);
uint8_t sprinter_piece_y(uint8_t row);
uint16_t sprinter_piece_ref(uint8_t set, char piece);
uint8_t sprinter_cursor_outline_color(uint8_t selected);
char sprinter_board_file_label(uint8_t col, uint8_t flipped);
char sprinter_board_rank_label(uint8_t row, uint8_t flipped);

#endif
