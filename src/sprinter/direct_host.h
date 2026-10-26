#ifndef SHATRANJ_DIRECT_HOST_H
#define SHATRANJ_DIRECT_HOST_H
#include "spectrum/session/ping.h"
/* No pointers into banked windows survive a dispatch. */
typedef struct direct_host_state {
    uint8_t enabled;
    uint8_t restart;
    uint8_t peer_known;
    uint8_t hello_wait;
    netchesszx_session_ping_t ping;
    uint8_t color;
    uint8_t hello_retries;
    uint8_t hello_seen;
    uint8_t start_pending;
    uint8_t listening;
    uint16_t port;
    uint8_t hello_frame_last;
} direct_host_state_t;
#ifdef SPRINTER_HOST_TEST
extern direct_host_state_t direct_host;
#else
#include "fixed_layout.h"
typedef char direct_host_state_fits_lowram[
    sizeof(direct_host_state_t) <= SHATRANJ_SPRINTER_LOWRAM_DIRECT_HOST_SIZE ? 1 : -1];
#define direct_host (*(direct_host_state_t *)SHATRANJ_SPRINTER_LOWRAM_DIRECT_HOST_ADDR)
#endif
#define net_peer_known direct_host.peer_known
#define net_hello_wait direct_host.hello_wait
#define net_ping direct_host.ping
#define SPRINTER_NET_HOST_WAIT 5u
#define SPRINTER_NET_PREPARE 6u
#define SPRINTER_NET_HELLO 7u
#define SPRINTER_NET_CLOSE 8u
#define SPRINTER_NET_NETWORK 9u
#define SPRINTER_NET_HELLO_TICK 10u
/* Dispatch result: defer cleanup to the application after NET has returned.
 * The overlay dispatcher has one saved WIN3 page and cannot nest. */
#define SPRINTER_NET_FAILED 2u
#endif
