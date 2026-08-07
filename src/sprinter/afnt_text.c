#include <stdint.h>

#include "gfx640.h"
#include "sprinter_layout.h"

extern uint8_t sprinter_afnt_handle;

#define afnt_text ((char *)SPRINTER_OVERLAY_SCRATCH)
#define AFNT_TEXT_SIZE 96u

uint8_t sprinter_afnt_print(uint16_t x, uint8_t y, const char *text,
                            uint8_t attribute)
{
    gfx640_regs_t regs;
    uint8_t length = 0u;
    uint8_t manager_error;
    while (text[length] != '\0' && length + 1u < AFNT_TEXT_SIZE) {
        char value = text[length];
        afnt_text[length] = (value >= 32 && (uint8_t)value < 127u) ? value : ' ';
        ++length;
    }
    afnt_text[length] = '\0';
    regs.a = attribute;
    regs.de = (uint16_t)afnt_text;
    regs.ix = x;
    regs.iy = y;
    manager_error = gfx640_libman_call(sprinter_afnt_handle, 3u, &regs);
    return (uint8_t)(manager_error == 0u && regs.a == 0u);
}
