#include "sprinter/transport/net_frame.h"
#include "spectrum/transport/mqtt_min.h"

uint8_t nc_smoke(uint8_t x)
{
    return (uint8_t)(x + 1u);
}

static char nc_line_buf[NC_LINE_MAX];
static uint8_t nc_line_pos;
static uint8_t nc_line_oversize;

static char nc_queue[NC_QUEUE_DEPTH][NC_LINE_MAX];
static uint8_t nc_queue_len[NC_QUEUE_DEPTH];
static uint8_t nc_queue_head;
static uint8_t nc_queue_tail;
static uint8_t nc_queue_used;

static uint8_t nc_fatal;

void nc_init(void)
{
    nc_line_pos = 0u;
    nc_line_oversize = 0u;
    nc_queue_head = 0u;
    nc_queue_tail = 0u;
    nc_queue_used = 0u;
    nc_fatal = 0u;
}

/* Moves the in-progress line into the queue if it qualifies (non-empty,
 * not marked oversize, room left) -- a no-op drop otherwise. Caller
 * resets nc_line_pos/nc_line_oversize right after, on every path. */
static void nc_enqueue_current_line(void)
{
    uint8_t i;

    if (nc_line_pos == 0u || nc_line_oversize || nc_queue_used >= NC_QUEUE_DEPTH) {
        return;
    }

    for (i = 0u; i < nc_line_pos; ++i) {
        nc_queue[nc_queue_tail][i] = nc_line_buf[i];
    }
    nc_queue[nc_queue_tail][nc_line_pos] = '\0';
    nc_queue_len[nc_queue_tail] = nc_line_pos;

    if (++nc_queue_tail >= NC_QUEUE_DEPTH) {
        nc_queue_tail = 0u;
    }
    ++nc_queue_used;
}

void nc_feed(const uint8_t *data, uint8_t len)
{
    uint8_t i;
    uint8_t c;

    for (i = 0u; i < len; ++i) {
        c = data[i];

        if (c == (uint8_t)'\n') {
            nc_enqueue_current_line();
            nc_line_pos = 0u;
            nc_line_oversize = 0u;
            continue;
        }
        if (c == (uint8_t)'\r') {
            continue;
        }
        if (nc_line_pos < (NC_LINE_MAX - 1u)) {
            nc_line_buf[nc_line_pos++] = (char)c;
        } else {
            nc_line_oversize = 1u;
        }
    }
}

int16_t nc_line_pop(char *out, uint8_t out_cap)
{
    uint8_t len;
    uint8_t i;

    if (nc_queue_used == 0u) {
        return nc_fatal ? (int16_t)NC_LINK_DOWN : (int16_t)NC_NO_LINE;
    }

    len = nc_queue_len[nc_queue_head];
    if (out_cap != 0u && len >= out_cap) {
        len = (uint8_t)(out_cap - 1u);
    }
    for (i = 0u; i < len; ++i) {
        out[i] = nc_queue[nc_queue_head][i];
    }
    if (out_cap != 0u) {
        out[len] = '\0';
    }

    if (++nc_queue_head >= NC_QUEUE_DEPTH) {
        nc_queue_head = 0u;
    }
    --nc_queue_used;

    return (int16_t)len;
}

void nc_mark_closed(void)
{
    nc_fatal = 1u;
}

void nc_mark_lost(void)
{
    nc_fatal = 1u;
}

uint8_t nc_queue_count(void)
{
    return nc_queue_used;
}

/* MQTT byte-stream reassembler (S8 step 7) -- see net_frame.h's own
 * comment for the algorithm and the fixed-vs-local storage split this
 * mirrors from nc_pump()'s ng_* externs below. */
#ifdef NETCHESSZX_SPRINTER
#include "fixed_layout.h"
#define NC_MQTT_STREAM ((uint8_t *)SHATRANJ_SPRINTER_LOWRAM_MQTT_STREAM_ADDR)
#define NC_MQTT_PACKET ((uint8_t *)SHATRANJ_SPRINTER_LOWRAM_MQTT_PACKET_ADDR)
#else
static uint8_t nc_mqtt_stream_storage[NC_MQTT_STREAM_MAX];
static uint8_t nc_mqtt_packet_storage[SPECTRUM_MQTT_PACKET_MAX];
#define NC_MQTT_STREAM nc_mqtt_stream_storage
#define NC_MQTT_PACKET nc_mqtt_packet_storage
#endif

static uint8_t nc_mqtt_stream_len;

void nc_mqtt_reset(void)
{
    nc_mqtt_stream_len = 0u;
    nc_fatal = 0u;
}

void nc_mqtt_feed(const uint8_t *data, uint8_t len)
{
    uint8_t room = (uint8_t)(NC_MQTT_STREAM_MAX - nc_mqtt_stream_len);
    uint8_t take = (len > room) ? room : len;
    uint8_t i;

    for (i = 0u; i < take; ++i) {
        NC_MQTT_STREAM[nc_mqtt_stream_len++] = data[i];
    }
}

int16_t nc_mqtt_take(void)
{
    uint8_t discard = 0u;
    uint8_t remaining;
    uint8_t header_len;
    uint8_t total;
    uint8_t b;
    uint8_t i;

    /* Resync: discard bytes from the front that cannot start a real MQTT
     * fixed header, one at a time, until one does or fewer than 2 bytes
     * are left (mqtt_take_stream_packet()'s own header-byte allowlist --
     * CONNACK/PUBLISH (any QoS bits)/PUBACK/SUBACK/PINGRESP). Keep the last
     * byte when nothing survives: it may be the first byte of the next,
     * still-arriving packet. */
    while ((uint8_t)(nc_mqtt_stream_len - discard) >= 2u) {
        b = NC_MQTT_STREAM[discard];
        if ((b & 0xf0u) == 0x30u || b == 0x20u || b == 0x40u ||
            b == 0x90u || b == 0xd0u) {
            break;
        }
        ++discard;
    }
    if (discard != 0u) {
        nc_mqtt_stream_len = (uint8_t)(nc_mqtt_stream_len - discard);
        for (i = 0u; i < nc_mqtt_stream_len; ++i) {
            NC_MQTT_STREAM[i] = NC_MQTT_STREAM[i + discard];
        }
    }
    if (nc_mqtt_stream_len < 2u) {
        return nc_fatal ? (int16_t)NC_LINK_DOWN : 0;
    }

    /* *(P + k), NOT P[k]. sccz80 miscompiles a CONSTANT index on a
     * cast-literal pointer macro: it folds the address and then assigns the
     * folded LOW BYTE as the value instead of loading through it, so this
     * line read the remaining-length as 7 -- the low byte of 0xB707 -- and
     * the reassembler waited for a packet length no CONNACK ever has
     * (2026-08-15 MAME finding; tests/sprinter/z80/t_net_frame_blob.asm
     * runs the compiled blob so this cannot come back silently). A variable
     * index compiles correctly, which is why only these two lines were hit.
     * The form below is also correct for the host build's plain arrays. */
    b = *(NC_MQTT_STREAM + 1u);
    remaining = (uint8_t)(b & 0x7fu);
    header_len = 2u;
    if ((b & 0x80u) != 0u) {
        if (nc_mqtt_stream_len < 3u) {
            return nc_fatal ? (int16_t)NC_LINK_DOWN : 0;
        }
        b = *(NC_MQTT_STREAM + 2u);   /* see the [1u] note above */
        if ((b & 0x80u) != 0u || b > 1u) {
            /* A third varint byte, or a second byte encoding more than
             * fits SPECTRUM_MQTT_PACKET_MAX two bytes in: not a length
             * this codec (or ZX's) ever produces. Discard everything and
             * let the next nc_mqtt_take() resync from the following
             * bytes, rather than guess at a corrupt length. */
            nc_mqtt_stream_len = 0u;
            return -1;
        }
        remaining = (uint8_t)(remaining + (uint8_t)(b << 7));
        header_len = 3u;
    }
    if (remaining > (uint8_t)(SPECTRUM_MQTT_PACKET_MAX - header_len)) {
        nc_mqtt_stream_len = 0u;
        return -1;
    }
    total = (uint8_t)(header_len + remaining);
    if (nc_mqtt_stream_len < total) {
        return nc_fatal ? (int16_t)NC_LINK_DOWN : 0;
    }

    for (i = 0u; i < total; ++i) {
        NC_MQTT_PACKET[i] = NC_MQTT_STREAM[i];
    }
    return (int16_t)total;
}

const uint8_t *nc_mqtt_packet(void)
{
    return NC_MQTT_PACKET;
}

void nc_mqtt_consume(uint8_t total)
{
    uint8_t i;

    nc_mqtt_stream_len = (uint8_t)(nc_mqtt_stream_len - total);
    for (i = 0u; i < nc_mqtt_stream_len; ++i) {
        NC_MQTT_STREAM[i] = NC_MQTT_STREAM[i + total];
    }
}

#ifdef NETCHESSZX_SPRINTER

/* Bridged from net_gate.asm via tools/gen_sprinter_platform_defs.py.
 * Declared here rather than through a target header so this file's only
 * real #include stays <stdint.h> (plus mqtt_min.h above) across both
 * build configurations -- the linker resolves these against the
 * generated platform_defs.asm, same as any other WIN1 C consumer of the
 * ng_ call surface. */
extern void ng_c_recv_poll(void);
extern uint8_t ng_buf_rx[];
extern uint8_t ng_v_call_status;
extern uint16_t ng_v_call_len;
extern uint16_t ng_v_call_flags;
extern uint8_t ng_v_call_cf;
extern uint16_t ng_c_recv_max;

/* unet.inc constants this file needs numerically (RXF_MORE/RXF_LOST bits,
 * NERR_CLOSED) -- duplicated rather than included so this .c keeps
 * exactly one #include across both build configurations. */
#define NC_UNET_RXF_MORE 0x0002u
#define NC_UNET_RXF_LOST 0x0004u
#define NC_UNET_NERR_CLOSED 7u
/* net_gate.asm's own NG_RX_CAPACITY -- the DLL's per-poll ceiling
 * regardless of what any C caller asks for via ng_c_recv_max. */
#define NC_UNET_RX_CAPACITY_MAX 255u

typedef void (*nc_sink_fn)(const uint8_t *data, uint8_t len);
typedef uint16_t (*nc_cap_fn)(void);

static uint16_t nc_pump_cap_direct(void)
{
    return NC_UNET_RX_CAPACITY_MAX;
}

/* Recomputed on every call (nc_pump_sink() below calls this fresh before
 * each of its up to two polls, not once up front) so the second poll of
 * a call sees whatever room the first poll's nc_mqtt_feed() left, not a
 * stale value from before it ran. */
static uint16_t nc_pump_cap_mqtt(void)
{
    return (uint16_t)(NC_MQTT_STREAM_MAX - nc_mqtt_stream_len);
}

/* Shared ng_recv polling glue (S8 step 7 -- previously nc_pump()'s own
 * body, factored out so nc_mqtt_pump() below can reuse the exact same
 * two-poll/RXF_MORE/RXF_LOST/NERR_CLOSED handling instead of a second,
 * drifting copy): `cap` sets net_gate.asm's ng_c_recv_max before each
 * poll -- see that cell's own comment in net_gate.asm for why Sprinter,
 * unlike ZX's UART ring, cannot just ask for the max and drop the tail
 * after the fact. */
static void nc_pump_sink(nc_sink_fn sink, nc_cap_fn cap)
{
    uint8_t polls;
    uint8_t take;

    for (polls = 0u; polls < 2u; ++polls) {
        ng_c_recv_max = cap();
        ng_c_recv_poll();

        if (ng_v_call_cf) {
            /* Dispatcher-level failure: not one of the documented per-
             * call NERR_* outcomes, so there is nothing more specific to
             * latch than "the link is gone". */
            nc_mark_lost();
            return;
        }

        if (ng_v_call_len > 0u) {
            take = (ng_v_call_len > 255u) ? 255u : (uint8_t)ng_v_call_len;
            sink(ng_buf_rx, take);
        }

        if (ng_v_call_flags & NC_UNET_RXF_LOST) {
            nc_mark_lost();
        }
        if (ng_v_call_status == NC_UNET_NERR_CLOSED) {
            nc_mark_closed();
            return;
        }
        if (!(ng_v_call_flags & NC_UNET_RXF_MORE)) {
            return;
        }
    }
}

void nc_pump(void)
{
    nc_pump_sink(nc_feed, nc_pump_cap_direct);
}

void nc_mqtt_pump(void)
{
    nc_pump_sink(nc_mqtt_feed, nc_pump_cap_mqtt);
}

#endif /* NETCHESSZX_SPRINTER */
