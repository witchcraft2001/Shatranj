#include <stdint.h>

#include "spectrum/overlay/overlay_api.h"
#include "spectrum/overlay/overlay_context.h"
#include "sprinter/cold_text.h"
#include "sprinter/unet_link.h"

static const char preflight_net_wait[] = "\007NET WAIT";
static const char preflight_net_ok[] = "\007NET OK  ";
static const char preflight_net_fail[] = "\007SET NET=WIFI/RTL";

uint8_t sprinter_net_preflight_ovl(void)
{
    uint8_t ok;

    spectrum_overlay_context[SPECTRUM_OVL_CTX_PREFLIGHT_OK] = 0u;
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PREFLIGHT_RETRY] =
        SPECTRUM_OVL_PREFLIGHT_RETRY_DEFAULT;
    spectrum_info_show_preflight();
    spectrum_info_line(sprinter_cold_text(preflight_net_wait));
    spectrum_frame_wait();
    ok = sprinter_unet_preflight_core();
    spectrum_info_line(sprinter_cold_text(
        ok ? preflight_net_ok : preflight_net_fail));
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PREFLIGHT_OK] = ok;
    return 1u;
}
