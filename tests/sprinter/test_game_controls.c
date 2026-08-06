#include <assert.h>

#include "sprinter/game_controls.h"

int main(void)
{
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
    return 0;
}
