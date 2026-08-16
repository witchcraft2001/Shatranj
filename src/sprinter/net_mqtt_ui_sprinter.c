/*
 * MQTT connect lifecycle, NET overlay entries 0/1/2/3 (S8 steps 8c/8d;
 * overlay.h's SPECTRUM_OVL_MQTT_CONNECT_START/ACTIVATE/SPECTRUM_OVL_NET_
 * PREFLIGHT/SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT -- the same four entry ids
 * ZX/Next's mqtt_connect_ovl.c implements for the same overlay id
 * (SPECTRUM_OVL_NET_CONNECT=3u), reached the same way (unet_link.c's
 * spectrum_net_mqtt_start/activate_side/probe_seat, src/spectrum/transport/
 * link.h's MQTT half).
 *
 * NOT a byte-for-byte port of mqtt_connect_ovl.c: that file builds its
 * CONNECT packet in hand-written Z80 (asm/overlay/mqtt_connect/entry_mqtt_
 * connect.asm) purely to fit ZX's 2 KiB copy slot, drives an ESP8266
 * AT-command modem through a byte-stream "enter CIPSEND mode" dance, and
 * splits SUBSCRIBE/PUBLISH-during-a-live-session across two overlay ids
 * (NET_CONNECT=3, MQTT_TX=4) purely for WIN1/copy-slot budget. None of
 * those constraints apply here: Sprinter's transport is uNet (net_gate.
 * asm's ng_* funnel), a real packet-oriented socket API, and this overlay's
 * own WIN3 page has room to spare. So this file builds the CONNECT packet
 * in C (spectrum_mqtt_subscribe/spectrum_mqtt_publish already exist for
 * SUBSCRIBE/PUBLISH; CONNECT has no such helper, hence connect_packet_ovl
 * below), and PUBLISH-during-a-live-session lives inline in unet_link.c
 * (WIN1, S8 step 8c) instead of a second overlay -- see that file's own
 * "MQTT half" comment.
 *
 * The wire CONTRACT is unchanged: same CONNECT fixed header, ClientId
 * shape, will topic/payload, subscribe/publish sequence (docs/wire-
 * contract.md) -- verified byte-for-byte against entry_mqtt_connect.asm's
 * own derivation (mqtt_remaining_base=47/mqtt_packet_base=49/
 * mqtt_client_id_fixed=7: remaining_length = 2*room_len + 47, total packet
 * length = 2*room_len + 49) before writing connect_packet_ovl below.
 */
#include "spectrum/transport/mqtt_min.h"
#include "spectrum/transport/link.h"
#include "spectrum/config/session.h"
#include "spectrum/platform/text.h"
#include "common/protocol/mqtt_session_protocol.h"

/* net_gate.asm (WIN2, always mapped), bridged by tools/gen_sprinter_
   platform_defs.py -- the same funnel unet_link.c uses. Declared here for
   the same reason that file declares its own externs. */
extern void ng_up(void);
extern void ng_close(void);
extern void ng_c_connect_at(void);
extern void ng_c_send(void);
extern unsigned char ng_up_reason;
extern char *ng_c_send_ptr;
extern unsigned char ng_c_send_len;
extern unsigned char ng_v_call_status;
extern unsigned char ng_v_call_cf;
extern char *ng_c_connect_host;
extern char *ng_c_connect_port;

/* net_frame.c's MQTT stream reassembler (WIN2 blob), bridged by tools/
   gen_sprinter_netframe_defs.py -- the same one unet_link.c's own MQTT
   read path (S8 step 8c) uses. This overlay needs it directly: the CONNACK/
   SUBACK wait below runs entirely inside this overlay's own entries, before
   unet_link.c's normal per-frame read_payload() polling has anything to do
   with the session (no game traffic exists yet). */
extern void nc_mqtt_reset(void);
extern void nc_mqtt_pump(void);
extern void nc_mqtt_feed(const unsigned char *data, unsigned char len);
extern int16_t nc_mqtt_take(void);
extern const unsigned char *nc_mqtt_packet(void);
extern void nc_mqtt_consume(unsigned char total);

extern void frame_wait(void);
extern unsigned char frame_counter;
extern unsigned char rtc_second;

/* src/sprinter/transport/unet_link.c (WIN1), bridged by tools/gen_sprinter_
   overlay_defs.py -- declared here rather than pulled from link.h because
   it is this port's own addition, not part of the shared contract. */
extern void spectrum_net_mqtt_link_reset(void);

#define NC_UNET_NERR_OK 0u
#define NC_UNET_NERR_BUSY 13u
/* unet_link.c's NC_SEND_BUSY_RETRY_MAX, same value and same reasoning: a
 * hard backstop, not an expected count. On a healthy link mqtt_ovl_send
 * loops once. */
#define MQTT_OVL_SEND_BUSY_RETRY_MAX 50u

/* sprinter/transport/net_frame.h's NC_LINK_DOWN, duplicated rather than
   pulled in via that header for the same reason this file's other unet.inc/
   net_gate.asm constants are duplicated (see this file's own top-of-file
   note): nc_mqtt_take() returns this once nc_mark_closed()/nc_mark_lost()
   latched (via nc_mqtt_pump()'s own NERR_CLOSED/RXF_LOST handling) AND the
   accumulator holds no complete packet. mqtt_ovl_wait_type() below MUST stop
   on it instead of polling out its own timeout -- see net_frame.h's own
   comment on nc_mqtt_take() for the 2026-08-15 MAME finding this fixes (a
   broker that closed the connection right after a rejected CONNECT, instead
   of ever sending a CONNACK, left the caller waiting the full ~40s with no
   way to tell "closed" from "might still arrive"). */
#define MQTT_OVL_LINK_DOWN (-2)

/*
 * Which step of the connect sequence gave up, plus net_gate.asm's OWN
 * per-call outcome cells at that moment. Read by net_ui_sprinter.c's
 * failure screen (net_ui_show_mqtt_failure).
 *
 * WHY THIS EXISTS AT ALL -- 2026-08-15 MAME finding, and the reason two
 * earlier fix rounds chased the wrong layer: the screen used to report a
 * failed connect with the DLL's own LASTERR text and nothing else. That
 * text is NOT a report of the attempt. It is formatted live out of the
 * DLL's persistent state (unetrtl.asm's STAGE/LAST_NERR/TCP_LAST_FAIL/
 * DIAG_*), all of which survive across calls and none of which is touched
 * when a call fails BEFORE the DLL is entered -- net_gate.asm's own
 * argument-validation paths (ng_connect's oversized host/port, ng_send's
 * bad length) and libman's l_call refusing to dispatch both return without
 * the DLL ever running. So a failure at those points prints the previous
 * successful call's diagnostic verbatim and reads as a fresh report of a
 * completely different stage. ng_v_call_cf/ng_v_call_status, set by
 * ng_c_store_result on EVERY C-wrapper call including the ones that never
 * reach the DLL, are the authoritative outcome; this records them together
 * with the step, so the screen can say what actually happened.
 *
 * These three cells USED to live here, in this overlay's own BSS. They
 * moved to WIN1 (unet_link.c) on 2026-08-15 for a reason that only appeared
 * once activate_side/probe_seat started being dispatched from the frame
 * loop instead of only from the NET screen: this page is not mapped once
 * the overlay returns, so a caller outside it cannot read its BSS at all.
 * The NET screen could (same image); session_sprinter.c cannot, and it is
 * now a caller that has to report why a step failed. WIN1 is the only place
 * both can see. */
extern unsigned char net_mqtt_fail_step;
extern unsigned char net_mqtt_fail_cf;
extern unsigned char net_mqtt_fail_status;
extern unsigned char net_mqtt_fail_detail;
extern unsigned char net_mqtt_ovl_dropped;

/* net_mqtt_fail_step values -- kept as plain numbers rather than an enum so
 * the wire between this file and net_ui_sprinter.c's step-name table is one
 * byte, and so a step that is somehow out of range still prints as a number
 * instead of vanishing. Keep in step with net_ui_mqtt_step_name(). */
#define MQTT_FAIL_PREFLIGHT 1u
#define MQTT_FAIL_TCP_CONNECT 2u
#define MQTT_FAIL_BUILD_CONNECT 3u
#define MQTT_FAIL_SEND_CONNECT 4u
#define MQTT_FAIL_WAIT_CONNACK 5u
#define MQTT_FAIL_CONNACK_REJECTED 6u
#define MQTT_FAIL_SEND_SUBSCRIBE 7u
#define MQTT_FAIL_WAIT_SUBACK 8u
#define MQTT_FAIL_SUBACK_REJECTED 9u
#define MQTT_FAIL_ACTIVATE 10u

/* Records the step and snapshots the gate's outcome cells, then returns 0
 * so every giving-up site stays a single `return mqtt_ovl_fail(...)`.
 * On the two wait steps the snapshot is the LAST ng_c_recv_poll()'s own
 * status/cf, which is exactly what is wanted there: it distinguishes "the
 * broker sent nothing" (status OK, nothing arrived) from "every poll was
 * refused" (a non-zero status repeated until the timeout ran out). */
static uint8_t mqtt_ovl_fail(uint8_t step)
{
    net_mqtt_fail_step = step;
    net_mqtt_fail_cf = ng_v_call_cf;
    net_mqtt_fail_status = ng_v_call_status;
    return 0u;
}

/* Same, for the giving-up sites that happen once the TCP channel is
 * already open: shut the channel so the screen's ENTER=RETRY is a fresh
 * CONNECT rather than a second CONNECT on a channel uNet still holds open.
 * net_ui_direct_connect() has done exactly this since S7; the MQTT branch
 * did not, so every retry after the first re-entered ng_c_connect_at()
 * against a live channel (2026-08-15). Records the step FIRST -- ng_close()
 * runs through ng_call and would otherwise overwrite the very outcome
 * cells this is trying to preserve. */
static uint8_t mqtt_ovl_abandon(uint8_t step)
{
    (void)mqtt_ovl_fail(step);
    ng_close();
    return 0u;
}

static uint8_t mqtt_ovl_hex_digit(uint8_t nibble)
{
    return (uint8_t)(nibble < 10u ? ('0' + nibble) : ('A' + nibble - 10u));
}

/* Frames to wait for a broker response before giving up -- generous
   (network round trip plus broker processing), matching ZX's own
   WAIT_LONG (2000 ticks) for the same CONNACK/SUBACK waits. */
#define MQTT_OVL_WAIT_LONG 2000u

/* Packet id allocator + staging buffer, both local to this overlay --
   independent of unet_link.c's own net_mqtt_next_id/net_mqtt_tx_packet
   (WIN1). Safe as a plain WIN3-page-local buffer: LIBMAN.l_call only ever
   displaces WIN1 (net_gate.asm's own header), and nothing in this file's
   call chain touches WIN3 itself (no render primitive, no cold-page
   thunk), so this overlay's own page stays mapped for this buffer's whole
   lifetime. */
static uint16_t mqtt_ovl_next_id = 1u;
static uint8_t mqtt_ovl_packet[SPECTRUM_MQTT_PACKET_MAX];

/* One-slot holding area for a session PUBLISH that arrives while this
 * overlay is waiting for a CONNACK/SUBACK.
 *
 * WHY. mqtt_ovl_wait_type used to simply throw such packets away, under the
 * assumption its own banner states -- "no game session is live at any point
 * this helper is used". S8 step 8f ended that by dispatching activate_side/
 * probe_seat from the frame loop, and the connect-time `meta` subscribe was
 * never safe either: a broker delivers a topic's RETAINED message the
 * instant the subscription lands, which is exactly while this code is still
 * waiting for the SUBACK. The discard is permanent -- the helper never
 * PUBACKs, and this client connects with a clean session, so the broker owes
 * no redelivery before a reconnect.
 *
 * Measured, not assumed: the 2026-08-15 MAME round reported `d1`, one
 * session PUBLISH destroyed, and the guest correspondingly never saw the
 * host's retained H (it recovered only because the host re-announces on a
 * timer).
 *
 * So: hold it instead, and feed it back into the reassembler when the entry
 * returns, where the normal frame-loop read path picks it up. Re-injection
 * puts it after anything that arrived meanwhile -- these are independent
 * MQTT packets, and nothing in this protocol depends on their relative
 * order. A second one while the slot is full is still counted as lost, so
 * net_mqtt_ovl_dropped keeps reporting real loss rather than becoming a
 * number that is always zero. */
static uint8_t mqtt_ovl_defer[SPECTRUM_MQTT_PACKET_MAX];
static uint8_t mqtt_ovl_defer_len;

static void mqtt_ovl_defer_flush(void)
{
    if (mqtt_ovl_defer_len != 0u) {
        nc_mqtt_feed(mqtt_ovl_defer, mqtt_ovl_defer_len);
        mqtt_ovl_defer_len = 0u;
    }
}

static uint16_t mqtt_ovl_alloc_id(void)
{
    uint16_t id = mqtt_ovl_next_id++;

    if (mqtt_ovl_next_id == 0u) {
        mqtt_ovl_next_id = 1u;
    }
    return id;
}

static void mqtt_ovl_topic(char *out, const char *suffix)
{
    char *p;

    p = spectrum_append_text(out, "netchesszx/v1/");
    p = spectrum_append_text(p, netchesszx_mqtt_code);
    p = spectrum_append_text(p, "/");
    (void)spectrum_append_text(p, suffix);
}

/* Busy-retry ladder as documented in docs/UNETRTL.md and already run by
 * unet_link.c's DIRECT send_text and its net_mqtt_send_raw: a BUSY TCP
 * channel is drained, given a frame, and retried -- it is not a failure.
 * This mattered once activate_side started running from the frame loop
 * (S8 step 8f) rather than only from the NET screen: four SUBSCRIBEs
 * back-to-back with SUBACKs still arriving is exactly when uNet says BUSY,
 * and reporting that as a dead link produced "Activate side failed" on a
 * perfectly healthy connection.
 *
 * NOT `return (!cf && status == OK) ? 1u : 0u;` -- sccz80 miscompiles a
 * ternary whose condition contains && or ||, and this one silently made
 * every MQTT CONNECT look like a failed send (2026-08-15 MAME finding,
 * three rounds). tools/check_sccz80_codegen.py is the gate; see its own
 * header for the emitted-code signature. */
static uint8_t mqtt_ovl_send(uint8_t len)
{
    uint8_t retry;

    if (len == 0u) {
        return 0u;
    }
    for (retry = 0u; retry < MQTT_OVL_SEND_BUSY_RETRY_MAX; ++retry) {
        /* Drain BEFORE the send. UNETRTL.md: "The consumer must drain
         * pending data before another SEND on the same channel" -- the DLL
         * retains a payload-bearing ACK in the channel's own queue while
         * SEND waits, and a SEND issued with that queue occupied cannot
         * finish its stop-and-wait handshake. Harmless at connect time
         * (nothing is queued); load-bearing from the frame loop, where the
         * broker is mid-burst. */
        nc_mqtt_pump();
        ng_c_send_ptr = (char *)mqtt_ovl_packet;
        ng_c_send_len = len;
        ng_c_send();
        if (ng_v_call_cf) {
            return 0u;
        }
        if (ng_v_call_status == NC_UNET_NERR_OK) {
            return 1u;
        }
        if (ng_v_call_status != NC_UNET_NERR_BUSY) {
            return 0u;
        }
        nc_mqtt_pump();
        frame_wait();
    }
    return 0u;
}

/* Non-blocking poll, retried up to `frames` times: pump whatever uNet has
   queued into the reassembler, take one packet, check its type. wanted==0
   accepts any type (unused here, kept for shape parity with ZX's own
   mqtt_wait_packet_into). Any OTHER packet type seen while waiting is
   simply dropped -- no game session is live yet at any point this helper
   is used (open_session/subscribe run before the caller's own configure()
   has anything for poll.c to classify), so there is nothing to preserve
   it for. */
static uint8_t mqtt_ovl_wait_type(uint8_t wanted, uint16_t frames)
{
    while (frames-- != 0u) {
        int16_t total;

        nc_mqtt_pump();
        total = nc_mqtt_take();
        if (total == (int16_t)MQTT_OVL_LINK_DOWN) {
            return 0u;
        }
        if (total > 0) {
            uint8_t type = spectrum_mqtt_type(nc_mqtt_packet(), (uint8_t)total);

            if (wanted == 0u || type == wanted) {
                if ((uint16_t)total <= SPECTRUM_MQTT_PACKET_MAX) {
                    const uint8_t *src = nc_mqtt_packet();
                    uint8_t i;

                    for (i = 0u; i < (uint8_t)total; ++i) {
                        mqtt_ovl_packet[i] = src[i];
                    }
                }
                nc_mqtt_consume((uint8_t)total);
                return 1u;
            }
            /* Not what we are waiting for. A PUBLISH is session traffic and
               must survive (see mqtt_ovl_defer above); anything else --
               PUBACK, a stale SUBACK, PINGRESP -- carries nothing this
               session needs and is dropped as before. */
            if (type == SPECTRUM_MQTT_PUBLISH) {
                if ((uint16_t)(mqtt_ovl_defer_len + total) <=
                        SPECTRUM_MQTT_PACKET_MAX) {
                    const uint8_t *src = nc_mqtt_packet();
                    uint8_t j;

                    /* Appended, not one-slot: activate_side runs FOUR
                       subscribes and each one's retained snapshot arrives
                       inside the next one's SUBACK wait, so a single slot
                       would still lose three of them. The buffer is a byte
                       stream exactly like the accumulator it feeds back
                       into, so packets simply stack. */
                    for (j = 0u; j < (uint8_t)total; ++j) {
                        mqtt_ovl_defer[mqtt_ovl_defer_len + j] = src[j];
                    }
                    mqtt_ovl_defer_len = (uint8_t)(mqtt_ovl_defer_len + total);
                } else if (net_mqtt_ovl_dropped != 255u) {
                    ++net_mqtt_ovl_dropped;
                }
            }
            nc_mqtt_consume((uint8_t)total);
        }
        frame_wait();
    }
    return 0u;
}

static uint8_t mqtt_ovl_subscribe_suffix(const char *suffix)
{
    char topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    uint8_t len;
    uint16_t id;

    mqtt_ovl_topic(topic, suffix);
    id = mqtt_ovl_alloc_id();
    len = spectrum_mqtt_subscribe(mqtt_ovl_packet, SPECTRUM_MQTT_PACKET_MAX,
                                  id, topic);
    if (!mqtt_ovl_send(len)) {
        return mqtt_ovl_fail(MQTT_FAIL_SEND_SUBSCRIBE);
    }
    if (!mqtt_ovl_wait_type(SPECTRUM_MQTT_SUBACK, MQTT_OVL_WAIT_LONG)) {
        return mqtt_ovl_fail(MQTT_FAIL_WAIT_SUBACK);
    }
    if (mqtt_ovl_packet[1u] != 3u ||
        mqtt_ovl_packet[2u] != (uint8_t)(id >> 8) ||
        mqtt_ovl_packet[3u] != (uint8_t)id ||
        mqtt_ovl_packet[4u] > 2u) {
        return mqtt_ovl_fail(MQTT_FAIL_SUBACK_REJECTED);
    }
    return 1u;
}

/* Own presence too: its retained snapshot reveals a seat already held by
   another client -- classify_event (event.c, already resident since S8
   step 8c) reads the resulting PUBLISH the normal session-poll path, the
   same way ZX's own mqtt_subscribe_all_ovl comment describes. */
static uint8_t mqtt_ovl_subscribe_all(void)
{
    /* net_mqtt_fail_detail carries WHICH of the four failed, so the notice
       can separate "the channel was already unusable when activate_side
       started" (#1) from "one subscribe's own answer broke the next" (#2-4).
       Set before each attempt, cleared on success. */
    net_mqtt_fail_detail = 1u;
    if (!mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_in_suffix())) {
        return 0u;
    }
    net_mqtt_fail_detail = 2u;
    if (!mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_in_ack_suffix())) {
        return 0u;
    }
    net_mqtt_fail_detail = 3u;
    if (!mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_peer_presence_suffix())) {
        return 0u;
    }
    net_mqtt_fail_detail = 4u;
    if (!mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_presence_suffix())) {
        return 0u;
    }
    net_mqtt_fail_detail = 0u;
    return 1u;
}

static uint8_t mqtt_ovl_activate_side(void)
{
    if (!mqtt_ovl_subscribe_all()) {
        /* mqtt_ovl_subscribe_suffix already recorded the precise step. */
        return 0u;
    }
    if (!spectrum_net_mqtt_publish_presence()) {
        return mqtt_ovl_fail(MQTT_FAIL_ACTIVATE);
    }
    return 1u;
}

/* CONNECT packet, built directly into mqtt_ovl_packet -- see this file's
   own header for the byte-layout derivation this mirrors exactly
   (entry_mqtt_connect.asm's mqtt_remaining_base/mqtt_packet_base/
   mqtt_client_id_fixed constants). Returns the total packet length, or 0
   if the room code is somehow longer than NETCHESSZX_MQTT_CODE_MAX already
   guarantees it cannot be (defensive only). */
static uint8_t mqtt_ovl_connect_packet(void)
{
    uint8_t room_len;
    uint8_t *p;
    char side;
    uint8_t nonce_hi;
    uint8_t nonce_lo;

    room_len = 0u;
    while (netchesszx_mqtt_code[room_len] != '\0') {
        ++room_len;
    }
    if (room_len > NETCHESSZX_MQTT_CODE_MAX) {
        return 0u;
    }

    mqtt_ovl_packet[0] = 0x10u;                       /* CONNECT */
    mqtt_ovl_packet[1] = (uint8_t)(room_len * 2u + 47u); /* remaining length */

    p = mqtt_ovl_packet + 2u;
    *p++ = 0u; *p++ = 4u;                             /* protocol name len */
    *p++ = 'M'; *p++ = 'Q'; *p++ = 'T'; *p++ = 'T';
    *p++ = 4u;                                        /* protocol level */
    *p++ = 0x06u;                                     /* connect flags: clean
                                                          session + will, will
                                                          NOT retained -- see
                                                          entry_mqtt_connect.
                                                          asm's own comment on
                                                          why $06 not $26 */
    *p++ = 0u; *p++ = 20u;                             /* keepalive: 20s */

    *p++ = 0u;                                        /* ClientId len hi */
    *p++ = (uint8_t)(room_len + 7u);                  /* ClientId len lo */
    *p++ = 'Z'; *p++ = 'X';
    {
        uint8_t i;

        for (i = 0u; i < room_len; ++i) {
            *p++ = (uint8_t)netchesszx_mqtt_code[i];
        }
    }
    *p++ = (uint8_t)(netchesszx_session_role * 2u + 'H'); /* HOST='H', JOIN='J' */
    /* 4 hex digits from the frame_counter/rtc_second nonce (im2_s1.asm's
       own comment on frame_counter has the full rationale for this source;
       ZX uses the ROM FRAMES sysvar for the same purpose). */
    nonce_hi = frame_counter;
    nonce_lo = rtc_second;
    *p++ = mqtt_ovl_hex_digit((uint8_t)(nonce_hi >> 4));
    *p++ = mqtt_ovl_hex_digit((uint8_t)(nonce_hi & 0x0fu));
    *p++ = mqtt_ovl_hex_digit((uint8_t)(nonce_lo >> 4));
    *p++ = mqtt_ovl_hex_digit((uint8_t)(nonce_lo & 0x0fu));

    *p++ = 0u;                                        /* will topic len hi */
    *p++ = (uint8_t)(room_len + 21u);                 /* will topic len lo */
    p = (uint8_t *)spectrum_append_text((char *)p, "netchesszx/v1/");
    {
        uint8_t i;

        for (i = 0u; i < room_len; ++i) {
            *p++ = (uint8_t)netchesszx_mqtt_code[i];
        }
    }
    p = (uint8_t *)spectrum_append_text((char *)p, "/pres_");
    side = netchesszx_local_side_char();
    *p++ = (uint8_t)(side | 0x20u);                   /* lowercase, matches
                                                          the retained-topic
                                                          convention every
                                                          subscriber uses */

    *p++ = 0u; *p++ = 3u;                              /* will payload len */
    *p++ = 'F'; *p++ = ' '; *p++ = (uint8_t)side;

    return (uint8_t)(room_len * 2u + 49u);
}

/* app.c's own mqtt_new_session_id, on this port's nonce source instead of
   ZX's FRAMES sysvar (the same frame_counter/rtc_second pair the ClientId
   suffix above uses -- im2_s1.asm's comment on frame_counter has the full
   rationale).

   A HOST's session id MUST be non-zero. Zero reads as "there is no session"
   throughout the shared session core -- netchesszx_session_mqtt_can_accept_
   game_start() refuses to start a game on it, and mqtt.c's side_relation()
   only marks a presence SIDE_CURRENT when the parsed id matches -- so a host
   announcing "H W 0" advertises a room nobody can take a seat in. */
uint16_t net_mqtt_new_session_id(void)
{
    uint16_t id = (uint16_t)(((uint16_t)frame_counter << 8) | rtc_second);

    return id == 0u ? 1u : id;
}

/* SPECTRUM_OVL_MQTT_CONNECT_START = 0u. */
unsigned char net_mqtt_connect_start_ovl(void)
{
    uint8_t len;

    mqtt_ovl_next_id = 1u;
    net_mqtt_fail_step = 0u;

    /* The reassembler state THIS overlay is about to poll -- accumulator
     * plus the nc_fatal latch it SHARES with the DIRECT line splitter.
     * unet_link.c's spectrum_net_mqtt_start() (WIN1) resets it before
     * dispatching this overlay, but the NET screen calls this entry
     * directly (same overlay image), so on that path nothing reset it at
     * all: a DIRECT session that ended with a peer FIN leaves nc_fatal
     * latched, and since nc_mqtt_take() started honouring that latch it
     * would abort the CONNACK wait instantly on a link that is in fact
     * fine. Leftover bytes in the accumulator are the same class of bug
     * one step milder -- the resync would chew through them looking for a
     * fixed header. Reset here, not in the caller, so every route into
     * this entry gets it. */
    nc_mqtt_reset();

    ng_up();
    if (ng_up_reason != 0u) {
        return mqtt_ovl_fail(MQTT_FAIL_PREFLIGHT);
    }

    ng_c_connect_host = netchesszx_mqtt_host;
    {
        static char port_text[6];

        (void)spectrum_append_u16(port_text, netchesszx_mqtt_port);
        ng_c_connect_port = port_text;
    }
    ng_c_connect_at();
    if (ng_v_call_cf || ng_v_call_status != NC_UNET_NERR_OK) {
        return mqtt_ovl_fail(MQTT_FAIL_TCP_CONNECT);
    }

    len = mqtt_ovl_connect_packet();
    if (len == 0u) {
        return mqtt_ovl_abandon(MQTT_FAIL_BUILD_CONNECT);
    }
    if (!mqtt_ovl_send(len)) {
        return mqtt_ovl_abandon(MQTT_FAIL_SEND_CONNECT);
    }
    if (!mqtt_ovl_wait_type(SPECTRUM_MQTT_CONNACK, MQTT_OVL_WAIT_LONG)) {
        return mqtt_ovl_abandon(MQTT_FAIL_WAIT_CONNACK);
    }
    if (mqtt_ovl_packet[1u] != 2u || mqtt_ovl_packet[3u] != 0u) {
        return mqtt_ovl_abandon(MQTT_FAIL_CONNACK_REJECTED);
    }

    /* The broker session is live from here on -- clear WIN1's per-link MQTT
       state before the frame loop starts polling it. Not optional and not
       symmetry: unet_link.c's broker-keepalive counters are file statics
       that survive a previous attempt, and spectrum_net_mqtt_start() (which
       also resets them) is NOT on this path -- net_ui_mqtt_connect calls
       this entry directly. See spectrum_net_mqtt_link_reset's own comment
       for what a stale miss counter looks like on screen. */
    spectrum_net_mqtt_link_reset();

    if (!mqtt_ovl_subscribe_suffix("meta")) {
        return mqtt_ovl_abandon(net_mqtt_fail_step);
    }
    if (netchesszx_session_is_host() || netchesszx_host_color_ready) {
        if (!mqtt_ovl_activate_side()) {
            return mqtt_ovl_abandon(net_mqtt_fail_step);
        }
        (void)spectrum_net_mqtt_publish_setup(
            netchesszx_session_is_host()
                ? SPECTRUM_LINK_MQTT_SETUP_RETAINED
                : SPECTRUM_LINK_MQTT_SETUP_LIVE);
    }
    /* Hand back anything the SUBACK waits above had to hold -- the retained
       `meta` announcement lands during exactly that window. */
    mqtt_ovl_defer_flush();
    return 1u;
}

/* SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE = 1u. */
unsigned char net_mqtt_activate_side_ovl(void)
{
    if (!mqtt_ovl_activate_side()) {
        mqtt_ovl_defer_flush();
        return 0u;
    }
    (void)spectrum_net_mqtt_publish_setup(
        netchesszx_session_is_host()
            ? SPECTRUM_LINK_MQTT_SETUP_RETAINED
            : SPECTRUM_LINK_MQTT_SETUP_LIVE);
    /* Four subscriptions land here, and each one's retained snapshot
       arrives while the NEXT one is still waiting for its SUBACK. */
    mqtt_ovl_defer_flush();
    return 1u;
}

/* SPECTRUM_OVL_NET_PREFLIGHT = 2u. Not wired as unet_link.c's own
   spectrum_net_preflight_run() target (that function calls ng_up()
   directly, matching net_join_ui_ovl's DIRECT flow -- see that file's own
   comment); kept for API completeness against overlay.h's shared entry
   contract, same category as SPECTRUM_OVL_MQTT_TX staying unused here. */
unsigned char net_preflight_ovl(void)
{
    ng_up();
    return (ng_up_reason == 0u)
        ? SPECTRUM_LINK_PREFLIGHT_OK
        : SPECTRUM_LINK_PREFLIGHT_FAILED;
}

/* SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT = 3u. Subscribes to our own
   presence topic WITHOUT claiming the seat (no O publish) -- its retained
   snapshot reveals an occupant already on our side, read by the normal
   session-poll path once this returns, same as ZX's own mqtt_probe_seat_
   ovl. */
unsigned char net_mqtt_probe_seat_ovl(void)
{
    unsigned char ok = mqtt_ovl_subscribe_suffix(
        spectrum_net_mqtt_presence_suffix());

    /* The whole point of the probe is the retained O this subscription
       delivers -- and it arrives inside the SUBACK wait. Dropping it made
       the probe unable to ever see an occupied seat. */
    mqtt_ovl_defer_flush();
    return ok;
}
