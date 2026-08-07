#include <stdint.h>

#include "spectrum/overlay/overlay_api.h"
#include "spectrum/overlay/overlay_context.h"
#include "sprinter/cold_text.h"
#include "sprinter/unet_link.h"

static const char preflight_net_wait[] = "\007NET WAIT";
static const char preflight_net_ok[] = "\007NET OK  ";
static const char preflight_net_fail[] = "\007SET NET=WIFI/RTL";
static const char preflight_env_value_fail[] = "\007NET E2 BAD VALUE";
static const char preflight_load_fail[] = "\007NET E3 LOAD DLL";
static const char preflight_caps_call_fail[] = "\007NET E4 GETCAPS";
static const char preflight_caps_fail[] = "\007NET E5 ABI/CAPS";
static const char preflight_status_fail[] = "\007NET E6 STATUS";
static const char preflight_init_fail[] = "\007NET E7 NETINIT";
static const char preflight_ip_fail[] = "\007NET E8 GETINFO";
static const char preflight_info_fail[] = "\007NET E9 DLL INFO";

static const char *preflight_failure_text(uint8_t error)
{
    switch (error) {
    case 2u: return preflight_env_value_fail;
    case 3u: return preflight_load_fail;
    case 4u: return preflight_caps_call_fail;
    case 5u: return preflight_caps_fail;
    case 6u: return preflight_status_fail;
    case 7u: return preflight_init_fail;
    case 8u: return preflight_ip_fail;
    case 9u: return preflight_info_fail;
    default: return preflight_net_fail;
    }
}

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
    spectrum_info_line(sprinter_cold_text(ok ? preflight_net_ok :
        preflight_failure_text(sprinter_unet_preflight_error())));
    spectrum_overlay_context[SPECTRUM_OVL_CTX_PREFLIGHT_OK] = ok;
    return 1u;
}
