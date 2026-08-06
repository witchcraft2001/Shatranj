#include <stdint.h>

#include "sprinter/unet_link.h"

uint8_t sprinter_mqtt_send_ovl(uint8_t *ctx) __z88dk_fastcall
{
    const char *text = (const char *)((uint16_t)ctx[0] |
                                      ((uint16_t)ctx[1] << 8));
    return sprinter_unet_mqtt_send_core(text);
}

uint8_t sprinter_mqtt_setup_ovl(uint8_t *ctx) __z88dk_fastcall
{
    return sprinter_unet_mqtt_publish_setup_core(ctx[0]);
}

uint8_t sprinter_mqtt_time_ovl(void)
{
    return 1u;
}
