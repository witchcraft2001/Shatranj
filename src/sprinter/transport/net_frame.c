#include "sprinter/transport/net_frame.h"

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

#ifdef NETCHESSZX_SPRINTER

/* Bridged from net_gate.asm via tools/gen_sprinter_platform_defs.py.
 * Declared here rather than through a target header so this file's only
 * real #include stays <stdint.h> outside this ifdef -- the linker
 * resolves these against the generated platform_defs.asm, same as any
 * other WIN1 C consumer of the ng_ call surface. */
extern void ng_c_recv_poll(void);
extern uint8_t ng_buf_rx[];
extern uint8_t ng_v_call_status;
extern uint16_t ng_v_call_len;
extern uint16_t ng_v_call_flags;
extern uint8_t ng_v_call_cf;

/* unet.inc constants this file needs numerically (RXF_MORE/RXF_LOST bits,
 * NERR_CLOSED) -- duplicated rather than included so this .c keeps
 * exactly one #include across both build configurations. */
#define NC_UNET_RXF_MORE 0x0002u
#define NC_UNET_RXF_LOST 0x0004u
#define NC_UNET_NERR_CLOSED 7u

void nc_pump(void)
{
    uint8_t polls;
    uint8_t take;

    for (polls = 0u; polls < 2u; ++polls) {
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
            nc_feed(ng_buf_rx, take);
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

#endif /* NETCHESSZX_SPRINTER */
