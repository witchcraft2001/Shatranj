/*
 * link.h contract over uNet (S7, port.md section 3.7). Mechanics (libman/
 * net_gate.asm/the DLL call convention) are already proven by the S3 echo
 * stand; this file is only the contract adapter: DIRECT-only, JOIN role
 * hardcoded (host/listen stays out of reach until S9's SETUP port), host
 * and port always resolved from the NETHOST/NETPORT env vars (no
 * interactive entry this milestone -- port.md section 3.7).
 *
 * Every call into net_gate.asm crosses into WIN2-resident code/state that
 * survives a blocking libman l_call with WIN1 mapped to the DLL (R5); this
 * file never talks to the DLL or libman directly, only through net_gate's
 * ng_ / ng_c_ funnel (bridged by tools/gen_sprinter_platform_defs.py) and
 * net_frame.c's nc_ line-framing core (bridged by tools/gen_sprinter_
 * netframe_defs.py).
 */
#include "spectrum/transport/link.h"
#include "sprinter/transport/net_frame.h"
#include "common/protocol/game_protocol.h"

/* Bridged from net_gate.asm. Declared here (not through a target header)
 * for the same reason net_frame.c's nc_pump() declares its own externs:
 * the linker resolves these against the generated platform_defs.asm. */
extern void ng_up(void);
extern void ng_close(void);
extern void ng_shutdown(void);
extern void ng_lasterr_fetch(void);
extern void ng_getinfo_ip(void);
extern void ng_c_connect(void);
extern void ng_c_send(void);
extern uint8_t ng_up_reason;
extern uint8_t ng_v_last_nerr;
extern uint8_t ng_v_last_cf;
extern char ng_buf_ip[];
extern char *ng_c_send_ptr;
extern uint8_t ng_c_send_len;
extern uint8_t ng_v_call_status;
extern uint8_t ng_v_call_cf;

extern void frame_wait(void);

/* unet.inc's NERR_OK/NERR_BUSY, needed numerically here (see net_frame.c's
 * own NC_UNET_* comment for why these are duplicated rather than shared
 * via a target header: keeping this file's real #include list short and
 * portable-shaped matters more than avoiding two small literal copies). */
#define NC_UNET_NERR_OK 0u
#define NC_UNET_NERR_BUSY 13u

/* docs/UNETRTL.md's documented recovery for a busy TCP channel: drain RX
 * (frees the receive queue SEND was blocked behind), wait a frame, retry.
 * 50 attempts is a hard backstop, not an expected count -- on a healthy
 * link this loop runs once. Exhausting it means the peer stopped
 * acknowledging entirely; send_text() reports failure and the session
 * layer (step 4) treats that as connection loss, per link.h's contract. */
#define NC_SEND_BUSY_RETRY_MAX 50u

static uint8_t net_link_activity;
static char net_payload_scratch[SPECTRUM_LINK_PAYLOAD_MAX];
/* Set by direct_peer_mark_valid(); consumed by the session/ping layer
 * once step 4 wires it in (not yet -- link.h has no getter for this, only
 * the setter, matching ZX's own shape of a plain state flag the session
 * layer reaches into directly rather than through the link.h surface). */
static uint8_t net_peer_valid;

void spectrum_net_start_uart(void)
{
    /* Nothing to pre-warm: uNet's "UART" lives entirely inside the DLL,
     * brought up by preflight_run()'s ng_up(). This hook's real job is
     * resetting local framing/activity state before a fresh attempt. */
    nc_init();
    net_link_activity = 0u;
    net_peer_valid = 0u;
}

uint8_t spectrum_net_listen(void)
{
    /* Host role is out of reach until S9 (SETUP overlay not yet ported;
     * port.md section 3.7's "listen/accept stubs"). */
    return 0u;
}

uint8_t spectrum_net_wait_pc_connect(void)
{
    return 0u;
}

uint8_t spectrum_net_preflight_run(void)
{
    ng_up();
    return (ng_up_reason == 0u)
        ? SPECTRUM_LINK_PREFLIGHT_OK
        : SPECTRUM_LINK_PREFLIGHT_FAILED;
}

uint8_t spectrum_net_connect_host(void)
{
    ng_c_connect();
    return (!ng_v_call_cf && ng_v_call_status == NC_UNET_NERR_OK) ? 1u : 0u;
}

void spectrum_net_direct_peer_mark_valid(void)
{
    net_peer_valid = 1u;
}

int16_t spectrum_net_read_payload(char *payload, uint8_t payload_cap)
{
    int16_t rc;

    /* Empty queue: up to two non-blocking polls, each followed by a
     * frame wait if it still found nothing -- the ZX pacing (direct_ovl.
     * c's direct_read_payload_ovl/direct_drain_uart_ovl) this port must
     * stay tick-compatible with, since ping.c's constants (75/3/2 ticks)
     * are unmodified. A queue that already has data skips this entirely,
     * same as ZX's own `direct_rx_count == 0u` guard. */
    if (nc_queue_count() == 0u) {
        nc_pump();
        if (nc_queue_count() == 0u) {
            frame_wait();
            nc_pump();
            if (nc_queue_count() == 0u) {
                frame_wait();
            }
        }
    }

    rc = nc_line_pop(payload, payload_cap);
    if (rc >= 0) {
        net_link_activity = 1u;
    }
    return rc;
}

uint8_t spectrum_net_send_text(const char *text) NETCHESSZX_FASTCALL
{
    uint8_t len;
    uint8_t retry;

    spectrum_net_background_drain();

    len = 0u;
    while (text[len] != '\0' && len < (SPECTRUM_LINK_PAYLOAD_MAX - 2u)) {
        net_payload_scratch[len] = text[len];
        ++len;
    }
    net_payload_scratch[len] = '\n';
    ++len;

    ng_c_send_ptr = net_payload_scratch;
    ng_c_send_len = len;

    for (retry = 0u; retry < NC_SEND_BUSY_RETRY_MAX; ++retry) {
        ng_c_send();
        if (ng_v_call_cf) {
            return 0u;
        }
        if (ng_v_call_status != NC_UNET_NERR_BUSY) {
            return (ng_v_call_status == NC_UNET_NERR_OK) ? 1u : 0u;
        }
        nc_pump();
        frame_wait();
    }
    return 0u;
}

uint8_t spectrum_net_send_ping(void)
{
    return spectrum_net_send_text(NETCHESS_PROTO_PING);
}

char *spectrum_net_payload_scratch(void)
{
    return net_payload_scratch;
}

uint8_t spectrum_net_link_activity(void)
{
    uint8_t activity = net_link_activity;

    net_link_activity = 0u;
    return activity;
}

uint8_t spectrum_net_payload_flags(void)
{
    /* DIRECT never sets retained/route flags -- those are MQTT-only
     * concepts (S7 is DIRECT-only, NETCHESSZX_DIRECT_ONLY). */
    return 0u;
}

void spectrum_net_background_drain(void)
{
    nc_pump();
}

const char *spectrum_net_last_ip(void)
{
    ng_getinfo_ip();
    return (ng_v_last_nerr == NC_UNET_NERR_OK) ? ng_buf_ip : "";
}

uint8_t spectrum_net_sync_time(void)
{
    /* Sprinter already has a hardware RTC (BIOS_CMOS_TEST, sampled by
     * trampoline.asm into rtc_present -- see platform_primitives.asm's
     * RTC_PRESENT banner); unlike ZX's ESP-AT NTP path, there is no
     * network-sourced clock to sync here. */
    return 0u;
}
