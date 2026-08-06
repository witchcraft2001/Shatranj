#include <stdint.h>

#include "sprinter/unet_link.h"

uint8_t sprinter_direct_listen_ovl(void)
{
    return 0u;
}

uint8_t sprinter_direct_wait_ovl(void)
{
    return 0u;
}

uint8_t sprinter_direct_read_ovl(uint8_t *ctx) __z88dk_fastcall
{
    char *payload = (char *)((uint16_t)ctx[0] | ((uint16_t)ctx[1] << 8));
    return (uint8_t)sprinter_unet_direct_read_core(payload, ctx[2]);
}

uint8_t sprinter_direct_send_ovl(uint8_t *ctx) __z88dk_fastcall
{
    const char *text = (const char *)((uint16_t)ctx[0] |
                                      ((uint16_t)ctx[1] << 8));
    return sprinter_unet_direct_send_core(text);
}
