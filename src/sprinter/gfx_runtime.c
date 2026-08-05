#include <stdint.h>

#include "gfx320.h"
#include "sprinter_assets.h"
#include "sprinter_layout.h"

#define GFX_REQUIRED_CAPS 0x00DFu
#define GFX_ABI_1_0 0x0100u

extern uint8_t sprinter_gfx_load(const char *name) __z88dk_fastcall;
extern void sprinter_gfx_unload(uint8_t handle) __z88dk_fastcall;
extern uint8_t sprinter_video_graphics(void);

static uint8_t gfx_handle = 0xFFu;

uint8_t sprinter_gfx_start(void)
{
    gfx320_config_t *config = (gfx320_config_t *)SPRINTER_GFX_CONFIG;
    volatile uint8_t *stage = (volatile uint8_t *)SPRINTER_PLATFORM_ERROR;
    uint16_t version;
    uint16_t capabilities;

    *stage = 0x21u;
    gfx_handle = sprinter_gfx_load("GFX320.DLL");
    if (gfx_handle == 0xFFu) {
        return 0u;
    }
    gfx320_bind(gfx_handle);
    *stage = 0x22u;
    if (gfx320_get_version(&version, &capabilities) != 0u ||
        version != GFX_ABI_1_0 ||
        (capabilities & GFX_REQUIRED_CAPS) != GFX_REQUIRED_CAPS ||
        gfx320_get_config(config) != 0u ||
        config->required_mode != 0x81u || config->width != 320u ||
        config->height != 256u || config->tile_width != 16u ||
        config->tile_height != 16u) {
        /* Startup immediately exits through DSS on failure.  Do not enter
           libman l_free from a partially initialized loader state; DSS owns
           and reclaims the process allocation at Exit. */
        gfx_handle = 0xFFu;
        return 0u;
    }

    /* Keep every filesystem/libman operation in DSS text mode.  Only switch
       to #81 after the DLL is loaded and its non-drawing ABI is validated. */
    *stage = 0x23u;
    if (!sprinter_video_graphics() ||
        gfx320_set_page_table((const uint8_t *)SPRINTER_ASSET_PAGE_TABLE,
                              SPRINTER_GFX_SOURCE_PAGE_COUNT) != 0u ||
        gfx320_palette_load256((const uint8_t *)SPRINTER_GFX_PALETTE,
                               GFX_PAL_BOTH) != 0u ||
        gfx320_clear(0u, GFX_TARGET_BUF0) != 0u ||
        gfx320_clear(0u, GFX_TARGET_BUF1) != 0u) {
        gfx_handle = 0xFFu;
        return 0u;
    }
    *stage = 0u;
    return 1u;
}

void sprinter_gfx_stop(void)
{
    if (gfx_handle != 0xFFu) {
        sprinter_gfx_unload(gfx_handle);
        gfx_handle = 0xFFu;
    }
}
