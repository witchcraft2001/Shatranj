#include <stdint.h>

#include "spectrum/overlay/overlay.h"
#include "spectrum/session/event.h"

netchesszx_session_event_t netchesszx_session_classify_game_payload(
    const char *payload)
{
    uint16_t address = (uint16_t)payload;

    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_LO] = (uint8_t)address;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_HI] = (uint8_t)(address >> 8);
    return (netchesszx_session_event_t)spectrum_overlay_exec_cached(
        SPECTRUM_OVL_CONTROL, SPECTRUM_OVL_CONTROL_CLASSIFY);
}
