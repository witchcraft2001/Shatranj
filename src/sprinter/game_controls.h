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

#endif
