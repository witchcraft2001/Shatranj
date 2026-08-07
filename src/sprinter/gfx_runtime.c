#include <stdint.h>

#include "gfx640.h"
#include "sprinter_assets.h"
#include "sprinter_layout.h"

#define GFX_REQUIRED_CAPS 0x00DFu
#define GFX_ABI_1_0 0x0100u
#define GFX_VRAM_WINDOW 3u

extern uint8_t sprinter_gfx_load(const char *name) __z88dk_fastcall;
extern void sprinter_gfx_unload(uint8_t handle) __z88dk_fastcall;
extern uint8_t sprinter_video_graphics(void);

static uint8_t gfx_handle = 0xFFu;
uint8_t sprinter_afnt_handle = 0xFFu;

enum {
    AFNT_FNSTYLE = 2,
    AFNT_APRINT = 3,
    AFNT_SET_WINDOW = 4,
    AFNT_SET_TARGET = 5,
    AFNT_TARGET_BUF0 = 0,
    AFNT_TARGET_BUF1 = 1
};

static uint8_t afnt_call(uint8_t entry, uint8_t a, uint16_t de,
                         uint16_t ix, uint16_t iy)
{
    gfx640_regs_t regs;
    uint8_t manager_error;
    regs.a = a;
    regs.de = de;
    regs.ix = ix;
    regs.iy = iy;
    manager_error = gfx640_libman_call(sprinter_afnt_handle, entry, &regs);
    return manager_error ? manager_error : regs.a;
}

static uint8_t afnt_select(uint8_t target)
{
    return (uint8_t)(afnt_call(AFNT_SET_TARGET, 0u, target, 0u, 0u) == 0u);
}

uint8_t sprinter_gfx_start(void)
{
    gfx640_config_t *config = (gfx640_config_t *)SPRINTER_GFX_CONFIG;
    volatile uint8_t *stage = (volatile uint8_t *)SPRINTER_PLATFORM_ERROR;
    uint16_t version;
    uint16_t capabilities;

    *stage = 0x21u;
    gfx_handle = sprinter_gfx_load("GFX640.DLL");
    if (gfx_handle == 0xFFu) {
        return 0u;
    }
    gfx640_bind(gfx_handle);
    *stage = 0x22u;
    if (gfx640_get_version(&version, &capabilities) != 0u ||
        version != GFX_ABI_1_0 ||
        (capabilities & GFX_REQUIRED_CAPS) != GFX_REQUIRED_CAPS ||
        gfx640_get_config(config) != 0u ||
        config->required_mode != 0x82u || config->width != 640u ||
        config->height != 256u || config->tile_width != 16u ||
        config->tile_height != 32u) {
        /* Startup immediately exits through DSS on failure.  Do not enter
           libman l_free from a partially initialized loader state; DSS owns
           and reclaims the process allocation at Exit. */
        gfx_handle = 0xFFu;
        return 0u;
    }

    /* libman invokes gfx_init while it has temporarily mapped the DLL.  The
       automatic choice made there is therefore loader-state dependent.  WIN1
       holds base/cold code and WIN2 holds the runtime stack, so GFX must use
       only WIN3 as its VRAM aperture. */
    if (gfx640_set_vram_window(GFX_VRAM_WINDOW) != 0u) {
        gfx_handle = 0xFFu;
        return 0u;
    }

    sprinter_afnt_handle = sprinter_gfx_load("AFNT640.DLL");
    if (sprinter_afnt_handle == 0xFFu ||
        afnt_call(AFNT_SET_WINDOW, 0u, GFX_VRAM_WINDOW, 0u, 0u) != GFX_VRAM_WINDOW) {
        gfx_handle = 0xFFu;
        sprinter_afnt_handle = 0xFFu;
        return 0u;
    }

    /* Keep every filesystem/libman operation in DSS text mode.  Only switch
       to #82 after both DLLs are loaded and their non-drawing ABI is valid. */
    *stage = 0x23u;
    if (!sprinter_video_graphics() ||
        !afnt_select(AFNT_TARGET_BUF0) ||
        afnt_call(AFNT_FNSTYLE, 0u, 0u, 0u, 0u) != 0u ||
        !afnt_select(AFNT_TARGET_BUF1) ||
        afnt_call(AFNT_FNSTYLE, 0u, 0u, 0u, 0u) != 0u ||
        !afnt_select(AFNT_TARGET_BUF0) ||
        gfx640_set_page_table((const uint8_t *)SPRINTER_ASSET_PAGE_TABLE,
                              SPRINTER_GFX_SOURCE_PAGE_COUNT) != 0u) {
        gfx_handle = 0xFFu;
        return 0u;
    }
    *stage = 0u;
    return 1u;
}

void sprinter_gfx_stop(void)
{
    if (sprinter_afnt_handle != 0xFFu) {
        sprinter_gfx_unload(sprinter_afnt_handle);
        sprinter_afnt_handle = 0xFFu;
    }
    if (gfx_handle != 0xFFu) {
        sprinter_gfx_unload(gfx_handle);
        gfx_handle = 0xFFu;
    }
}
