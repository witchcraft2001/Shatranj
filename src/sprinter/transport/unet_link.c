/*
 * link.h contract over uNet (S7, port.md section 3.7; MQTT half added S8
 * step 8c). Mechanics (libman/net_gate.asm/the DLL call convention) are
 * already proven by the S3 echo stand; this file is only the contract
 * adapter. DIRECT's role is still hardcoded to JOIN (host/listen stays out
 * of reach until S9's SETUP port) and its host/port still always resolve
 * from the NETHOST/NETPORT env vars (port.md section 3.7) -- MQTT is the
 * new transport this step adds, role and broker chosen by the NET screen
 * (src/sprinter/net_ui_sprinter.c, S8 step 8e).
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
#include "spectrum/overlay/overlay.h"
#include "spectrum/transport/mqtt_min.h"
#include "spectrum/config/session.h"
#include "spectrum/platform/text.h"

/* Bridged from net_gate.asm. Declared here (not through a target header)
 * for the same reason net_frame.c's nc_pump() declares its own externs:
 * the linker resolves these against the generated platform_defs.asm. */
extern void ng_up(void);
extern void ng_close(void);
extern void ng_shutdown(void);
extern void ng_lasterr_fetch(void);
extern void ng_getinfo_ip(void);
extern void ng_c_connect(void);
extern void ng_c_connect_at(void);
extern void ng_c_send(void);
extern uint8_t ng_up_reason;
extern uint8_t ng_v_last_nerr;
extern uint8_t ng_v_last_cf;
extern char ng_buf_ip[];
extern char *ng_c_send_ptr;
extern uint8_t ng_c_send_len;
extern uint8_t ng_v_call_status;
extern uint8_t ng_v_call_cf;
extern char *ng_c_connect_host;
extern char *ng_c_connect_port;

/* mqtt_session_wire.c (S8 step 8c, same WIN1 image now -- SPRINTER_RESIDENT_
 * C_SRC). Declared here rather than via spectrum/transport/net.h, which is
 * ZX/Next's own transport header (pulls in ESP-AT declarations that mean
 * nothing on Sprinter) -- same "short, portable-shaped #include list"
 * reasoning as the net_gate.asm externs above. */
extern const char *spectrum_net_mqtt_out_suffix(void);
extern const char *spectrum_net_mqtt_presence_suffix(void);
extern const char *spectrum_net_mqtt_presence_payload(void);
extern void spectrum_net_mqtt_setup_payload(char *out) NETCHESSZX_FASTCALL;

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
/* TX staging, deliberately NOT net_payload_scratch. link.h's ownership
 * contract: "send_text(), send_ping(), and background_drain() ... must not
 * destroy a queued RX payload before read_payload() copies it" -- and
 * main.c's net_poll_once() hands net_payload_scratch straight to
 * netchesszx_session_poll() as the RX destination. With one shared buffer
 * every ACK/NACK/ACK PING answer would overwrite the very line being
 * processed; that it does not misbehave today is luck of ordering (each
 * caller happens to copy what it needs into locals before replying), and
 * S8's retry ladder and RESTORE chunking are exactly the code that would
 * end that luck. 48 bytes of WIN1 BSS is the whole price. ZX pays the same
 * one differently: there send_text stages in the UART buffer and
 * payload_scratch() borrows the INACTIVE backend's storage (net.c), which
 * is the same rule expressed in the shape that platform allows. */
static char net_tx_line[SPECTRUM_LINK_PAYLOAD_MAX];
/* Set by direct_peer_mark_valid(); consumed by the session/ping layer
 * once step 4 wires it in (not yet -- link.h has no getter for this, only
 * the setter, matching ZX's own shape of a plain state flag the session
 * layer reaches into directly rather than through the link.h surface). */
static uint8_t net_peer_valid;

/* --- MQTT half (S8 step 8c) --------------------------------------------
 * Sprinter's own WIN1 budget is generous enough (unlike ZX's) that
 * publish_presence/publish_setup build and send their packet right here,
 * with no MQTT_TX overlay (id 4, overlay.h) at all -- see the S8 step 8
 * plan's own "Инвариант размещения" for why that is safe: net_mqtt_tx_
 * packet below is a WIN1 intermediate buffer, exactly like net_tx_line
 * above, safe for the same reason (ng_c_send copies out of it before
 * l_call maps the DLL over WIN1). start/activate_side/probe_seat stay
 * overlay dispatches (src/sprinter/net_mqtt_ui_sprinter.c, NET overlay
 * entries 0/1/3) because they are one-shot, user-paced connect-time
 * flows -- the same reasoning net_join_ui_ovl's DIRECT flow already
 * follows, not a byte-budget necessity like ZX's MQTT_TX split. */
static uint16_t net_mqtt_next_id = 1u;
static uint8_t net_mqtt_tx_packet[SPECTRUM_MQTT_PACKET_MAX];
static uint8_t net_mqtt_flags;

static uint16_t net_mqtt_alloc_id(void)
{
    uint16_t id = net_mqtt_next_id++;

    if (net_mqtt_next_id == 0u) {
        net_mqtt_next_id = 1u;
    }
    return id;
}

/* "netchesszx/v1/<room>/<suffix>" -- byte-identical shape to ZX's own
 * mqtt_tx_ovl.c::mqtt_tx_topic, built from the portable spectrum_append_
 * text (src/spectrum/platform/text.c, same WIN1 image now). */
static void net_mqtt_topic(char *out, const char *suffix)
{
    char *p;

    p = spectrum_append_text(out, "netchesszx/v1/");
    p = spectrum_append_text(p, netchesszx_mqtt_code);
    p = spectrum_append_text(p, "/");
    (void)spectrum_append_text(p, suffix);
}

static uint8_t net_mqtt_publish_suffix(const char *suffix,
                                       const char *payload,
                                       uint8_t retain)
{
    char topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    uint8_t len;

    net_mqtt_topic(topic, suffix);
    len = spectrum_mqtt_publish(net_mqtt_tx_packet, SPECTRUM_MQTT_PACKET_MAX,
                                net_mqtt_alloc_id(), topic, payload, retain);
    if (len == 0u) {
        return 0u;
    }
    ng_c_send_ptr = (char *)net_mqtt_tx_packet;
    ng_c_send_len = len;
    ng_c_send();
    return (!ng_v_call_cf && ng_v_call_status == NC_UNET_NERR_OK) ? 1u : 0u;
}

/* QoS1 PUBACK -- packet_id==0 (QoS0) is a deliberate no-op, matching
 * mqtt_min.c's own spectrum_mqtt_parse_publish() contract (*packet_id
 * stays 0 unless the incoming PUBLISH itself was QoS1). Built inline
 * (4 fixed bytes, MQTT spec section 3.4) rather than through mqtt_min.c,
 * which has no PUBACK encoder -- ZX's own net.c::mqtt_puback_id is the
 * same four bytes, same reasoning. */
static void net_mqtt_puback(uint16_t packet_id)
{
    uint8_t ack[4];

    if (packet_id == 0u) {
        return;
    }
    ack[0] = 0x40u;
    ack[1] = 0x02u;
    ack[2] = (uint8_t)(packet_id >> 8);
    ack[3] = (uint8_t)packet_id;
    ng_c_send_ptr = (char *)ack;
    ng_c_send_len = 4u;
    ng_c_send();
}

/* Single non-blocking poll -- pump whatever uNet has queued into the
 * reassembler, take one packet if a whole one is ready. No internal
 * frame_wait pacing (unlike the DIRECT read_payload below): poll.c calls
 * this once per frame already, and ping.c's timeout/retry cadence lives
 * above this layer, same as it does for ZX's own spectrum_net_mqtt_read_
 * payload. */
static int16_t net_mqtt_read_payload(char *payload, uint8_t payload_cap)
{
    int16_t total;
    int16_t got;
    uint16_t packet_id;
    uint8_t flags;

    net_mqtt_flags = 0u;
    nc_mqtt_pump();
    total = nc_mqtt_take();
    if (total < 0) {
        return SPECTRUM_LINK_READ_TIMEOUT;
    }

    if (spectrum_mqtt_type(nc_mqtt_packet(), (uint8_t)total) !=
        SPECTRUM_MQTT_PUBLISH) {
        nc_mqtt_consume((uint8_t)total);
        return SPECTRUM_LINK_READ_TIMEOUT;
    }

    got = spectrum_mqtt_parse_publish(nc_mqtt_packet(), (uint8_t)total,
                                      payload, payload_cap,
                                      &packet_id, &flags);
    nc_mqtt_consume((uint8_t)total);
    net_mqtt_puback(packet_id);
    if (got < 0) {
        return SPECTRUM_LINK_READ_TIMEOUT;
    }
    net_mqtt_flags = flags;
    return 0;
}

static uint8_t net_mqtt_send_text(const char *text) NETCHESSZX_FASTCALL
{
    return net_mqtt_publish_suffix(spectrum_net_mqtt_out_suffix(), text, 0u);
}

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

    if (netchesszx_transport_is_mqtt()) {
        return net_mqtt_read_payload(payload, payload_cap);
    }

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

    if (netchesszx_transport_is_mqtt()) {
        return net_mqtt_send_text(text);
    }

    len = 0u;
    while (text[len] != '\0' && len < (SPECTRUM_LINK_PAYLOAD_MAX - 2u)) {
        net_tx_line[len] = text[len];
        ++len;
    }
    net_tx_line[len] = '\n';
    ++len;

    ng_c_send_ptr = net_tx_line;
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
     * concepts. net_mqtt_flags is set by net_mqtt_read_payload() above,
     * the same "last read's flags" contract net_link_activity uses for
     * activity (link.h: payload_flags() describes the payload the most
     * recent read_payload() call produced). */
    return netchesszx_transport_is_mqtt() ? net_mqtt_flags : 0u;
}

void spectrum_net_background_drain(void)
{
    if (netchesszx_transport_is_mqtt()) {
        nc_mqtt_pump();
        return;
    }
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

/* S8 step 8a/8b: thin WIN1 wrapper dispatching the NET overlay's own
 * DIRECT-join/config screen (src/sprinter/net_ui_sprinter.c, moved off the
 * WIN3 cold page onto its own WIN3 page -- that file's own header has the
 * full rationale). Same shape as restore.c/saveload.c/fileui.c's own thin
 * wrappers around spectrum_overlay_exec_cached: the whole body is the
 * dispatch, no local state of its own. Replaces the cold-page-native
 * spectrum_net_join_ui() session_sprinter.c used to call same-page before
 * this move -- gen_sprinter_cold_defs.py's COLD_RESIDENT_SYMBOLS bridges
 * that caller to this WIN1 symbol now. */
uint8_t spectrum_net_join_ui(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_NET_CONNECT,
                                        SPECTRUM_OVL_NET_CONNECT_SCREEN);
}

/* --- link.h's MQTT half (S8 step 8c) ------------------------------------
 * start/activate_side/probe_seat dispatch the NET overlay's own MQTT
 * connect-lifecycle entries (src/sprinter/net_mqtt_ui_sprinter.c, entries
 * 0/1/3 -- see entry_net_sprinter.asm); publish_presence/publish_setup
 * build and send their packet inline above (net_mqtt_publish_suffix).
 * publish_offline (link.h's sixth MQTT entry) is NOT here -- src/spectrum/
 * transport/mqtt_session_wire.c already implements it portably, calling
 * back into publish_presence/publish_setup below, the same way it does on
 * ZX/Next. */
uint8_t spectrum_net_mqtt_start(void)
{
    nc_mqtt_reset();
    net_mqtt_next_id = 1u;
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_START);
}

uint8_t spectrum_net_mqtt_activate_side(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE);
}

uint8_t spectrum_net_mqtt_probe_seat(void)
{
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_CONNECT,
                                        SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT);
}

uint8_t spectrum_net_mqtt_publish_presence(void)
{
    return net_mqtt_publish_suffix(spectrum_net_mqtt_presence_suffix(),
                                   spectrum_net_mqtt_presence_payload(), 1u);
}

uint8_t spectrum_net_mqtt_publish_setup(uint8_t mode) NETCHESSZX_FASTCALL
{
    char setup[32];

    if (mode == SPECTRUM_LINK_MQTT_SETUP_CLEAR) {
        return net_mqtt_publish_suffix("meta", "", 1u);
    }
    spectrum_net_mqtt_setup_payload(setup);
    return net_mqtt_publish_suffix(
        "meta", setup,
        (uint8_t)(mode == SPECTRUM_LINK_MQTT_SETUP_RETAINED));
}
