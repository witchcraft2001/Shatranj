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
extern void nc_mqtt_pump(void);
extern int16_t nc_mqtt_take(void);
extern const unsigned char *nc_mqtt_packet(void);
extern void nc_mqtt_consume(unsigned char total);

extern void frame_wait(void);
extern unsigned char frame_counter;
extern unsigned char rtc_second;

#define NC_UNET_NERR_OK 0u

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

static uint8_t mqtt_ovl_send(uint8_t len)
{
    if (len == 0u) {
        return 0u;
    }
    ng_c_send_ptr = (char *)mqtt_ovl_packet;
    ng_c_send_len = len;
    ng_c_send();
    return (!ng_v_call_cf && ng_v_call_status == NC_UNET_NERR_OK) ? 1u : 0u;
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
    if (!mqtt_ovl_send(len) ||
        !mqtt_ovl_wait_type(SPECTRUM_MQTT_SUBACK, MQTT_OVL_WAIT_LONG)) {
        return 0u;
    }
    return (uint8_t)(mqtt_ovl_packet[1u] == 3u &&
                     mqtt_ovl_packet[2u] == (uint8_t)(id >> 8) &&
                     mqtt_ovl_packet[3u] == (uint8_t)id &&
                     mqtt_ovl_packet[4u] <= 2u);
}

/* Own presence too: its retained snapshot reveals a seat already held by
   another client -- classify_event (event.c, already resident since S8
   step 8c) reads the resulting PUBLISH the normal session-poll path, the
   same way ZX's own mqtt_subscribe_all_ovl comment describes. */
static uint8_t mqtt_ovl_subscribe_all(void)
{
    return mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_in_suffix()) &&
           mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_in_ack_suffix()) &&
           mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_peer_presence_suffix()) &&
           mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_presence_suffix());
}

static uint8_t mqtt_ovl_activate_side(void)
{
    return mqtt_ovl_subscribe_all() &&
           spectrum_net_mqtt_publish_presence();
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

/* SPECTRUM_OVL_MQTT_CONNECT_START = 0u. */
unsigned char net_mqtt_connect_start_ovl(void)
{
    uint8_t len;

    mqtt_ovl_next_id = 1u;

    ng_up();
    if (ng_up_reason != 0u) {
        return 0u;
    }

    ng_c_connect_host = netchesszx_mqtt_host;
    {
        static char port_text[6];

        (void)spectrum_append_u16(port_text, netchesszx_mqtt_port);
        ng_c_connect_port = port_text;
    }
    ng_c_connect_at();
    if (ng_v_call_cf || ng_v_call_status != NC_UNET_NERR_OK) {
        return 0u;
    }

    len = mqtt_ovl_connect_packet();
    if (!mqtt_ovl_send(len) ||
        !mqtt_ovl_wait_type(SPECTRUM_MQTT_CONNACK, MQTT_OVL_WAIT_LONG) ||
        mqtt_ovl_packet[1u] != 2u || mqtt_ovl_packet[3u] != 0u) {
        return 0u;
    }

    if (!mqtt_ovl_subscribe_suffix("meta")) {
        return 0u;
    }
    if (netchesszx_session_is_host() || netchesszx_host_color_ready) {
        if (!mqtt_ovl_activate_side()) {
            return 0u;
        }
        (void)spectrum_net_mqtt_publish_setup(
            netchesszx_session_is_host()
                ? SPECTRUM_LINK_MQTT_SETUP_RETAINED
                : SPECTRUM_LINK_MQTT_SETUP_LIVE);
    }
    return 1u;
}

/* SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE = 1u. */
unsigned char net_mqtt_activate_side_ovl(void)
{
    if (!mqtt_ovl_activate_side()) {
        return 0u;
    }
    (void)spectrum_net_mqtt_publish_setup(
        netchesszx_session_is_host()
            ? SPECTRUM_LINK_MQTT_SETUP_RETAINED
            : SPECTRUM_LINK_MQTT_SETUP_LIVE);
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
    return mqtt_ovl_subscribe_suffix(spectrum_net_mqtt_presence_suffix());
}
