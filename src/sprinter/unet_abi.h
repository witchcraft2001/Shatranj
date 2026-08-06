#ifndef SHATRANJ_SPRINTER_UNET_ABI_H
#define SHATRANJ_SPRINTER_UNET_ABI_H

#include <stdint.h>

/* Stable uNet L1 ABI.  Keep this local: the pinned 0.2.1 ESP header predates
   names for a few additive flags even though their numeric ABI is stable. */
#define SHATRANJ_UNET_ABI_VERSION 0x0100u
#define SHATRANJ_UNET_ABI_MAJOR 1u

#define SHATRANJ_UNET_FN_INIT 0u
#define SHATRANJ_UNET_FN_FINI 1u
#define SHATRANJ_UNET_FN_GETCAPS 2u
#define SHATRANJ_UNET_FN_NETINIT 3u
#define SHATRANJ_UNET_FN_NETDONE 4u
#define SHATRANJ_UNET_FN_CONNECT 5u
#define SHATRANJ_UNET_FN_SEND 6u
#define SHATRANJ_UNET_FN_RECV 7u
#define SHATRANJ_UNET_FN_CLOSE 8u
#define SHATRANJ_UNET_FN_STATUS 9u
#define SHATRANJ_UNET_FN_UDPOPEN 10u
#define SHATRANJ_UNET_FN_RESOLVE 11u
#define SHATRANJ_UNET_FN_PING 12u
#define SHATRANJ_UNET_FN_RXPAUSE 13u
#define SHATRANJ_UNET_FN_RXRESUME 14u
#define SHATRANJ_UNET_FN_GETINFO 15u
#define SHATRANJ_UNET_FN_LASTERR 16u
#define SHATRANJ_UNET_FN_SETOPT 17u
#define SHATRANJ_UNET_FN_RESERVED18 18u
#define SHATRANJ_UNET_FN_RESERVED19 19u
#define SHATRANJ_UNET_FN_RESERVED20 20u
#define SHATRANJ_UNET_FN_RESERVED21 21u
#define SHATRANJ_UNET_FN_RESERVED22 22u
#define SHATRANJ_UNET_FN_RESERVED23 23u
#define SHATRANJ_UNET_FN_COUNT 24u

#define SHATRANJ_NERR_OK 0u
#define SHATRANJ_NERR_HW 1u
#define SHATRANJ_NERR_NONET 2u
#define SHATRANJ_NERR_DNS 3u
#define SHATRANJ_NERR_CONNECT 4u
#define SHATRANJ_NERR_SEND 5u
#define SHATRANJ_NERR_RECV_TIMEOUT 6u
#define SHATRANJ_NERR_CLOSED 7u
#define SHATRANJ_NERR_CANCEL 8u
#define SHATRANJ_NERR_PARAM 9u
#define SHATRANJ_NERR_NOTSUP 10u
#define SHATRANJ_NERR_STATE 11u
#define SHATRANJ_NERR_TIMEOUT 12u
#define SHATRANJ_NERR_BUSY 13u
#define SHATRANJ_NERR_PROTO 14u
#define SHATRANJ_NERR_AGAIN 15u

#define SHATRANJ_UNET_CAP_TCP 0x0001u
#define SHATRANJ_UNET_CAP_UDP 0x0002u
#define SHATRANJ_UNET_CAP_RESOLVE 0x0004u
#define SHATRANJ_UNET_CAP_PING 0x0008u
#define SHATRANJ_UNET_CAP_MULTICHAN 0x0010u
#define SHATRANJ_UNET_CAP_LISTEN 0x0020u
#define SHATRANJ_UNET_CAP_RAWETH 0x0040u
#define SHATRANJ_UNET_CAP_TRANSPARENT 0x0080u
#define SHATRANJ_UNET_CAP_RXFLOW 0x0100u
#define SHATRANJ_UNET_CAP_ASYNCSEND 0x0200u

#define SHATRANJ_UNET_ST_CONN 0x0002u
#define SHATRANJ_UNET_ST_RXPEND 0x0004u

#define SHATRANJ_UNET_RX_TRUNC 0x0001u
#define SHATRANJ_UNET_RX_MORE 0x0002u
#define SHATRANJ_UNET_RX_LOST 0x0004u
#define SHATRANJ_UNET_RX_XCHAN 0x0008u

#define SHATRANJ_UNET_IF_BACKEND 0u
#define SHATRANJ_UNET_IF_IP 1u
#define SHATRANJ_UNET_IF_MASK 2u
#define SHATRANJ_UNET_IF_GW 3u
#define SHATRANJ_UNET_IF_MAC 4u
#define SHATRANJ_UNET_IF_DNS1 5u
#define SHATRANJ_UNET_IF_DNS2 6u
#define SHATRANJ_UNET_IF_IPSRC 7u
#define SHATRANJ_UNET_IF_SSID 8u
#define SHATRANJ_UNET_IF_BAUD 9u
#define SHATRANJ_UNET_IF_NTP 10u
#define SHATRANJ_UNET_IF_TZ 11u
#define SHATRANJ_UNET_IF_HW 12u

#define SHATRANJ_UNET_OPT_CANCELKEYS 1u
#define SHATRANJ_UNET_OPT_RXTRIG 2u
#define SHATRANJ_UNET_OPT_SENDSLICE 3u

#define SHATRANJ_UNET_BACKEND_NONE 0u
#define SHATRANJ_UNET_BACKEND_WIFI 1u
#define SHATRANJ_UNET_BACKEND_RTL 2u

/* Byte fields avoid host/compiler padding and match the assembly bridge. */
typedef struct shatranj_unet_regs {
    uint8_t a;
    uint8_t de_lo;
    uint8_t de_hi;
    uint8_t ix_lo;
    uint8_t ix_hi;
    uint8_t iy_lo;
    uint8_t iy_hi;
} shatranj_unet_regs_t;

#define SHATRANJ_UNET_GET_DE(r) \
    ((uint16_t)((r)->de_lo | ((uint16_t)(r)->de_hi << 8)))
#define SHATRANJ_UNET_GET_IX(r) \
    ((uint16_t)((r)->ix_lo | ((uint16_t)(r)->ix_hi << 8)))
#define SHATRANJ_UNET_SET_DE(r, value) do { \
    uint16_t shatranj_unet_value_ = (uint16_t)(value); \
    (r)->de_lo = (uint8_t)shatranj_unet_value_; \
    (r)->de_hi = (uint8_t)(shatranj_unet_value_ >> 8); \
} while (0)
#define SHATRANJ_UNET_SET_IX(r, value) do { \
    uint16_t shatranj_unet_value_ = (uint16_t)(value); \
    (r)->ix_lo = (uint8_t)shatranj_unet_value_; \
    (r)->ix_hi = (uint8_t)(shatranj_unet_value_ >> 8); \
} while (0)
#define SHATRANJ_UNET_SET_IY(r, value) do { \
    uint16_t shatranj_unet_value_ = (uint16_t)(value); \
    (r)->iy_lo = (uint8_t)shatranj_unet_value_; \
    (r)->iy_hi = (uint8_t)(shatranj_unet_value_ >> 8); \
} while (0)

#endif
