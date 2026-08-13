#include <stdint.h>

#include "spectrum/overlay/overlay.h"
#include "spectrum/overlay/overlay_context.h"
#include "spectrum/session/event.h"

/* src/spectrum/overlay/overlay.c's own netchesszx_session_classify_game_
   payload, extracted rather than linked whole: that file's other
   dispatchers (spectrum_gui_add_move/add_chat/notify_msg/remove_last_move,
   GUI_LOG-routed) collide with src/sprinter/gui_log_sprinter.c's own
   already-ported definitions of the same names, and the STATUS/INPUT_EDIT
   dispatchers there target overlay ids not ported to Sprinter at all.
   CONTROL (id 14) is ported (S5, MAME-proven); this is the one dispatcher
   S7's session/event.c needs from that file. */
netchesszx_session_event_t netchesszx_session_classify_game_payload(
    const char *payload)
{
    uint16_t payload_addr = (uint16_t)payload;

    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_LO] = (uint8_t)payload_addr;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PTR_HI] =
        (uint8_t)(payload_addr >> 8);
    return (netchesszx_session_event_t)
        spectrum_overlay_exec_cached(SPECTRUM_OVL_CONTROL,
                                     SPECTRUM_OVL_CONTROL_CLASSIFY);
}
