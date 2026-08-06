#include <stdint.h>

#include "spectrum/board/board.h"
#include "spectrum/lowram_map.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/ui/gui.h"

#include "sprinter_layout.h"

extern uint8_t side_to_move;
extern uint8_t castle_rights;
extern int8_t ep_square;

/* Internal UI-bank startup entry.  The resident runtime reaches this through
   its generated page thunk after GFX initialization. */
void sprinter_gui_publish_clock(void)
{
    spectrum_gui_set_clock(*(volatile uint8_t *)SPRINTER_RTC_HOUR,
                           *(volatile uint8_t *)SPRINTER_RTC_MINUTE,
                           *(volatile uint8_t *)SPRINTER_RTC_SECOND);
}

void spectrum_board_clear_legal_hints(void)
{
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_HINTS,
                                       SPECTRUM_OVL_HINTS_CLEAR);
}

void spectrum_board_show_legal_hints(uint8_t from_row, uint8_t from_col)
{
    uint16_t address = NETCHESSZX_LOWRAM_RULES_BOARD_ADDR;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_BOARD_LO] =
        (uint8_t)address;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_BOARD_HI] =
        (uint8_t)(address >> 8);
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_SIDE_TO_MOVE] = side_to_move;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_SQUARE] =
        (uint8_t)((from_row << 3) + from_col);
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_CASTLE] = castle_rights;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_HINTS_EP] = (uint8_t)ep_square;
    (void)spectrum_overlay_exec_cached(SPECTRUM_OVL_HINTS,
                                       SPECTRUM_OVL_HINTS_SHOW);
}
