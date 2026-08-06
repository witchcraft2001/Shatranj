#ifndef SHATRANJ_SPRINTER_UNET_RUNTIME_H
#define SHATRANJ_SPRINTER_UNET_RUNTIME_H

#include <stdint.h>

#include "sprinter/unet_abi.h"

#ifndef NETCHESSZX_FASTCALL
#ifdef NETCHESSZX_SDCC_IY
#define NETCHESSZX_FASTCALL __z88dk_fastcall
#else
#define NETCHESSZX_FASTCALL
#endif
#endif

/* Permanent WIN2/libman bridge.  The dispatcher result is separate from the
   function status in regs->a; callers must never interpret carry as NERR. */
uint8_t sprinter_unet_load(const char *name, uint8_t *info);
void sprinter_unet_unload(void);
uint8_t sprinter_unet_call(uint8_t fn, shatranj_unet_regs_t *regs);
uint8_t sprinter_unet_getenv(char *value) NETCHESSZX_FASTCALL;
void sprinter_unet_set_initialized(uint8_t initialized) NETCHESSZX_FASTCALL;
uint8_t sprinter_unet_is_initialized(void);
uint8_t sprinter_unet_can_recv(void);
void sprinter_unet_mark_fault(void);
uint8_t sprinter_unet_faulted(void);

uint8_t sprinter_rx_slow_enter(void);
uint8_t sprinter_rx_slow_leave(void);
uint8_t sprinter_rx_slow_unwind(void);
void sprinter_unet_shutdown(void);

#endif
