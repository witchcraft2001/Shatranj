#include "sprinter/unet_runtime.h"
#include "sprinter/cold_text.h"

#ifdef NETCHESSZX_HOST_TEST
static uint8_t guard_initialized;
static uint8_t guard_depth;
static uint8_t guard_paused;
static uint8_t guard_fault;
static uint8_t guard_preinit_depth;
#define GUARD_INITIALIZED guard_initialized
#define GUARD_DEPTH guard_depth
#define GUARD_PAUSED guard_paused
#define GUARD_FAULT guard_fault
#define GUARD_PREINIT_DEPTH guard_preinit_depth
#else
#include "spectrum/lowram_map.h"
#include "sprinter_layout.h"
#define GUARD_INITIALIZED (*(volatile uint8_t *)SPRINTER_UNET_INITIALIZED)
#define GUARD_DEPTH (*(volatile uint8_t *)SPRINTER_RX_SLOW_DEPTH)
#define GUARD_PAUSED (*(volatile uint8_t *)SPRINTER_RX_PAUSED)
#define GUARD_FAULT (*(volatile uint8_t *)SPRINTER_TRANSPORT_FAULT)
#define GUARD_PREINIT_DEPTH \
    (*(volatile uint8_t *)SPRINTER_RX_PREINIT_DEPTH)

char *sprinter_cold_text(const char *source) NETCHESSZX_FASTCALL
{
    char *const start =
        (char *)NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR;
    char *out = start;
    uint8_t left = (uint8_t)(NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_SIZE - 1u);

    while (left != 0u && *source != '\0') {
        *out++ = *source++;
        --left;
    }
    *out = '\0';
    return start;
}
#endif

static uint8_t flow_call(uint8_t fn)
{
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    if (!sprinter_unet_call(fn, &regs)) {
        return 0u;
    }
    return (uint8_t)(regs.a == SHATRANJ_NERR_OK);
}

void sprinter_unet_set_initialized(uint8_t initialized) NETCHESSZX_FASTCALL
{
    GUARD_INITIALIZED = (uint8_t)(initialized != 0u);
    if (!initialized) {
        GUARD_DEPTH = 0u;
        GUARD_PAUSED = 0u;
        GUARD_FAULT = 0u;
    }
}

uint8_t sprinter_unet_is_initialized(void)
{
    return GUARD_INITIALIZED;
}

void sprinter_unet_mark_fault(void)
{
    GUARD_FAULT = 1u;
}

uint8_t sprinter_unet_faulted(void)
{
    return GUARD_FAULT;
}

uint8_t sprinter_unet_can_recv(void)
{
    if (!GUARD_INITIALIZED || GUARD_FAULT || GUARD_DEPTH != 0u ||
        GUARD_PAUSED != 0u) {
        GUARD_FAULT = 1u;
        return 0u;
    }
    return 1u;
}

uint8_t sprinter_rx_slow_enter(void)
{
    if (!GUARD_INITIALIZED) {
        if (GUARD_FAULT || GUARD_PREINIT_DEPTH == 0xffu) {
            GUARD_FAULT = 1u;
            return 0u;
        }
        ++GUARD_PREINIT_DEPTH;
        return 1u;
    }
    if (GUARD_FAULT || GUARD_DEPTH == 0xffu) {
        GUARD_FAULT = 1u;
        return 0u;
    }
    if (GUARD_DEPTH == 0u) {
        if (!flow_call(SHATRANJ_UNET_FN_RXPAUSE)) {
            GUARD_FAULT = 1u;
            return 0u;
        }
        GUARD_PAUSED = 1u;
    }
    ++GUARD_DEPTH;
    return 1u;
}

uint8_t sprinter_rx_slow_leave(void)
{
    if (GUARD_DEPTH == 0u && GUARD_PREINIT_DEPTH != 0u) {
        --GUARD_PREINIT_DEPTH;
        return (uint8_t)!GUARD_FAULT;
    }
    if (!GUARD_INITIALIZED || GUARD_DEPTH == 0u) {
        GUARD_FAULT = 1u;
        return 0u;
    }
    --GUARD_DEPTH;
    if (GUARD_DEPTH == 0u) {
        if (!flow_call(SHATRANJ_UNET_FN_RXRESUME)) {
            GUARD_FAULT = 1u;
            return 0u;
        }
        GUARD_PAUSED = 0u;
    }
    return (uint8_t)!GUARD_FAULT;
}

uint8_t sprinter_rx_slow_unwind(void)
{
    if (!GUARD_INITIALIZED) {
        if (GUARD_DEPTH != 0u || GUARD_PAUSED != 0u) {
            GUARD_FAULT = 1u;
            return 0u;
        }
        return (uint8_t)!GUARD_FAULT;
    }
    if (GUARD_DEPTH == 0u && GUARD_PAUSED == 0u) {
        return (uint8_t)!GUARD_FAULT;
    }
    if (GUARD_DEPTH == 0u || GUARD_PAUSED == 0u) {
        GUARD_FAULT = 1u;
    }
    GUARD_DEPTH = 1u;
    return sprinter_rx_slow_leave();
}

void sprinter_unet_shutdown(void)
{
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    if (GUARD_INITIALIZED) {
        (void)sprinter_rx_slow_unwind();
        regs.a = 0u;
        (void)sprinter_unet_call(SHATRANJ_UNET_FN_CLOSE, &regs);
        regs.a = 0u;
        (void)sprinter_unet_call(SHATRANJ_UNET_FN_NETDONE, &regs);
    }
    sprinter_unet_set_initialized(0u);
    sprinter_unet_unload();
}
