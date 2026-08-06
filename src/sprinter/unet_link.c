#include "sprinter/unet_link.h"

#include <stdint.h>
#include <string.h>

#include "common/protocol/game_protocol.h"
#include "common/protocol/mqtt_session_protocol.h"
#include "spectrum/config/session.h"
#include "spectrum/overlay/overlay.h"
#include "spectrum/platform/net_runtime.h"
#include "spectrum/platform/text.h"
#include "spectrum/transport/mqtt_min.h"
#include "spectrum/transport/net.h"
#include "sprinter/unet_abi.h"
#include "sprinter/unet_runtime.h"

#define UNET_RECV_BUDGET 4u
#define MQTT_STREAM_MAX 223u
#define MQTT_WAIT_POLLS 250u
#define DIRECT_SLOT_SIZE (SPECTRUM_LINK_PAYLOAD_MAX + 1u)
#define DIRECT_QUEUE_COUNT 3u
#define DIRECT_WORK_SIZE (DIRECT_SLOT_SIZE * (DIRECT_QUEUE_COUNT + 1u))

#ifdef NETCHESSZX_HOST_TEST
uint16_t sprinter_unet_host_encode_pointer(const void *pointer);
#define UNET_POINTER(pointer) sprinter_unet_host_encode_pointer(pointer)
static uint8_t host_packet[SPECTRUM_MQTT_PACKET_MAX];
static uint8_t host_stream[MQTT_STREAM_MAX];
static uint8_t host_recv[SPECTRUM_MQTT_PACKET_MAX];
static uint8_t host_info[32];
static char host_ip[18];
static char host_env[256];
#define NET_PACKET host_packet
#define NET_STREAM host_stream
#define NET_RECV host_recv
#define NET_INFO host_info
#define NET_IP host_ip
#define NET_ENV host_env
#else
#define UNET_POINTER(pointer) ((uint16_t)(uintptr_t)(pointer))
#include "sprinter_layout.h"
#define NET_PACKET ((uint8_t *)SPRINTER_NET_PACKET)
#define NET_STREAM ((uint8_t *)SPRINTER_NET_STREAM)
#define NET_RECV ((uint8_t *)SPRINTER_NET_RECV)
#define NET_INFO ((uint8_t *)SPRINTER_NET_INFO)
#define NET_IP ((char *)SPRINTER_NET_IP)
#define NET_ENV ((char *)SPRINTER_NET_ENV)
#endif

#ifndef NETCHESSZX_HOST_TEST
extern uint8_t sprinter_palette_restore(void);
#endif

typedef char mqtt_workspace_fits[
    MQTT_STREAM_MAX >= DIRECT_WORK_SIZE ? 1 : -1];

char line_buf[8];

static uint8_t unet_backend;
static uint16_t unet_caps_value;
static uint8_t link_active;
static uint8_t link_activity;
static uint8_t payload_flags;
static uint8_t terminal_closed;
static uint8_t mqtt_stream_len;
static uint16_t mqtt_next_id;
static spectrum_mqtt_broker_keepalive_t mqtt_keepalive;
static uint8_t direct_head;
static uint8_t direct_count;
static uint8_t direct_partial_len;
static uint8_t direct_dropping;

static uint8_t unet_call(uint8_t fn, shatranj_unet_regs_t *regs)
{
    if (!sprinter_unet_call(fn, regs)) {
        sprinter_unet_mark_fault();
        return 0u;
    }
    return 1u;
}

static uint8_t string_equal(const char *left, const char *right)
{
    while (1) {
        char left_char = *left++;
        char right_char = *right++;
        if (left_char >= 'a' && left_char <= 'z') {
            left_char = (char)(left_char - ('a' - 'A'));
        }
        if (right_char >= 'a' && right_char <= 'z') {
            right_char = (char)(right_char - ('a' - 'A'));
        }
        if (left_char != right_char) {
            return 0u;
        }
        if (left_char == '\0') {
            return 1u;
        }
    }
}

static uint8_t string_starts(const char *text, const char *prefix)
{
    while (*prefix != '\0') {
        if (*text++ != *prefix++) {
            return 0u;
        }
    }
    return 1u;
}

static char *append_u16(char *out, uint16_t value)
{
    char reversed[5];
    uint8_t count = 0u;

    do {
        reversed[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0u);
    while (count != 0u) {
        *out++ = reversed[--count];
    }
    *out = '\0';
    return out;
}

static uint8_t checked_send(const uint8_t *data, uint16_t length)
{
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    if (!link_active || sprinter_unet_faulted()) {
        return 0u;
    }
    regs.a = 0u;
    SHATRANJ_UNET_SET_DE(&regs, UNET_POINTER(data));
    SHATRANJ_UNET_SET_IX(&regs, length);
    if (!unet_call(SHATRANJ_UNET_FN_SEND, &regs) ||
        regs.a != SHATRANJ_NERR_OK || SHATRANJ_UNET_GET_DE(&regs) != length) {
        sprinter_unet_mark_fault();
        link_active = 0u;
        return 0u;
    }
    link_activity = 1u;
    return 1u;
}

static void close_channel(void)
{
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    /* CLOSE must never leave the ESP UART paused, even on an error path. */
    (void)sprinter_rx_slow_unwind();
    if (sprinter_unet_is_initialized() &&
        (!sprinter_unet_call(SHATRANJ_UNET_FN_CLOSE, &regs) ||
         regs.a != SHATRANJ_NERR_OK)) {
        sprinter_unet_mark_fault();
    }
    link_active = 0u;
}

/* Returns byte count, zero for live/idle, or a negative NERR value. */
static int16_t checked_recv(uint16_t capacity, uint16_t *flags)
{
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    *flags = 0u;
    if (!link_active || !sprinter_unet_can_recv()) {
        return -(int16_t)SHATRANJ_NERR_STATE;
    }
    regs.a = 0u;
    SHATRANJ_UNET_SET_DE(&regs, UNET_POINTER(NET_RECV));
    SHATRANJ_UNET_SET_IX(&regs, capacity);
    SHATRANJ_UNET_SET_IY(&regs, 1u);
    if (!unet_call(SHATRANJ_UNET_FN_RECV, &regs)) {
        return -(int16_t)SHATRANJ_NERR_STATE;
    }
    *flags = SHATRANJ_UNET_GET_IX(&regs);
    if ((*flags & SHATRANJ_UNET_RX_LOST) != 0u) {
        sprinter_unet_mark_fault();
        link_active = 0u;
        return -(int16_t)SHATRANJ_NERR_PROTO;
    }
    if (regs.a == SHATRANJ_NERR_OK) {
        if (SHATRANJ_UNET_GET_DE(&regs) != 0u) {
            link_activity = 1u;
        }
        return (int16_t)SHATRANJ_UNET_GET_DE(&regs);
    }
    if (regs.a == SHATRANJ_NERR_RECV_TIMEOUT) {
        return 0;
    }
    if (regs.a == SHATRANJ_NERR_CLOSED) {
        terminal_closed = 1u;
        link_active = 0u;
        return -(int16_t)SHATRANJ_NERR_CLOSED;
    }
    sprinter_unet_mark_fault();
    link_active = 0u;
    return -(int16_t)regs.a;
}

static void reset_link_state(void)
{
    link_active = 0u;
    link_activity = 0u;
    payload_flags = 0u;
    terminal_closed = 0u;
    mqtt_stream_len = 0u;
    mqtt_next_id = 1u;
    direct_head = 0u;
    direct_count = 0u;
    direct_partial_len = 0u;
    direct_dropping = 0u;
    spectrum_mqtt_broker_keepalive_reset(&mqtt_keepalive);
}

static uint8_t validate_info_tag(const char *tag)
{
    const char *actual = (const char *)NET_INFO + 16u;

    while (*tag != '\0') {
        if (*actual++ != *tag++) {
            return 0u;
        }
    }
    return 1u;
}

uint8_t sprinter_unet_preflight_core(void)
{
    const char *dll;
    const char *tag;
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};
    uint16_t abi;

    sprinter_unet_shutdown();
    reset_link_state();
    NET_IP[0] = '\0';
    NET_ENV[0] = '\0';
    if (!sprinter_unet_getenv(NET_ENV)) {
        return 0u;
    }
    if (string_equal(NET_ENV, "WIFI")) {
        unet_backend = SHATRANJ_UNET_BACKEND_WIFI;
        dll = "UNETESP.DLL";
        tag = "UNETESP";
    } else if (string_equal(NET_ENV, "RTL")) {
        unet_backend = SHATRANJ_UNET_BACKEND_RTL;
        dll = "UNETRTL.DLL";
        tag = "UNETRTL";
    } else {
        unet_backend = SHATRANJ_UNET_BACKEND_NONE;
        return 0u;
    }
    if (!sprinter_unet_load(dll, NET_INFO) || !validate_info_tag(tag)) {
        sprinter_unet_shutdown();
        return 0u;
    }
    if (!unet_call(SHATRANJ_UNET_FN_GETCAPS, &regs) ||
        regs.a != SHATRANJ_NERR_OK) {
        sprinter_unet_shutdown();
        return 0u;
    }
    unet_caps_value = SHATRANJ_UNET_GET_DE(&regs);
    abi = SHATRANJ_UNET_GET_IX(&regs);
    if ((uint8_t)(abi >> 8) != SHATRANJ_UNET_ABI_MAJOR ||
        (unet_caps_value & SHATRANJ_UNET_CAP_TCP) == 0u ||
        (unet_backend == SHATRANJ_UNET_BACKEND_WIFI &&
         (unet_caps_value & SHATRANJ_UNET_CAP_RXFLOW) == 0u)) {
        sprinter_unet_shutdown();
        return 0u;
    }
    regs.a = 0xffu;
    if (!unet_call(SHATRANJ_UNET_FN_STATUS, &regs) ||
        (regs.a != SHATRANJ_NERR_OK && regs.a != SHATRANJ_NERR_NONET)) {
        sprinter_unet_shutdown();
        return 0u;
    }
    regs.a = 0u;
    if (!unet_call(SHATRANJ_UNET_FN_NETINIT, &regs) ||
        regs.a != SHATRANJ_NERR_OK) {
        sprinter_unet_shutdown();
        return 0u;
    }
    sprinter_unet_set_initialized(1u);
    regs.a = SHATRANJ_UNET_IF_IP;
    SHATRANJ_UNET_SET_DE(&regs, UNET_POINTER(NET_IP));
    SHATRANJ_UNET_SET_IX(&regs, 18u);
    if (!unet_call(SHATRANJ_UNET_FN_GETINFO, &regs) ||
        regs.a != SHATRANJ_NERR_OK || NET_IP[0] == '\0') {
        sprinter_unet_shutdown();
        return 0u;
    }
    /* Some network card initializers touch the shared video/ISA aperture.
       Reapply the immutable palette only after NETINIT/GETINFO have finished;
       the WIN2 startup palette workspace is network-owned from this point. */
#ifndef NETCHESSZX_HOST_TEST
    (void)sprinter_palette_restore();
#endif
    return 1u;
}

static uint8_t tcp_connect(const char *host, uint16_t port)
{
    char port_text[6];
    shatranj_unet_regs_t regs = {0u, 0u, 0u, 0u, 0u, 0u, 0u};

    if (sprinter_unet_faulted() && !sprinter_unet_preflight_core()) {
        return 0u;
    }
    (void)append_u16(port_text, port);
    regs.a = 0u;
    SHATRANJ_UNET_SET_DE(&regs, UNET_POINTER(host));
    SHATRANJ_UNET_SET_IX(&regs, UNET_POINTER(port_text));
    if (!unet_call(SHATRANJ_UNET_FN_CONNECT, &regs)) {
        return 0u;
    }
    if (regs.a == SHATRANJ_NERR_CANCEL) {
        return SPECTRUM_LINK_CANCELLED;
    }
    if (regs.a != SHATRANJ_NERR_OK) {
        return 0u;
    }
    reset_link_state();
    link_active = 1u;
    return 1u;
}

static uint8_t mqtt_take_packet(uint8_t *total)
{
    uint16_t remaining;
    uint16_t multiplier = 1u;
    uint8_t pos = 1u;
    uint8_t encoded;

    if (mqtt_stream_len < 2u) {
        return 0u;
    }
    remaining = 0u;
    do {
        if (pos >= mqtt_stream_len || pos >= 3u) {
            return pos >= 3u ? 2u : 0u;
        }
        encoded = NET_STREAM[pos++];
        remaining += (uint16_t)(encoded & 0x7fu) * multiplier;
        multiplier <<= 7;
    } while ((encoded & 0x80u) != 0u);
    if (remaining + pos > SPECTRUM_MQTT_PACKET_MAX) {
        return 2u;
    }
    *total = (uint8_t)(remaining + pos);
    return mqtt_stream_len >= *total ? 1u : 0u;
}

static void mqtt_consume(uint8_t total)
{
    mqtt_stream_len = (uint8_t)(mqtt_stream_len - total);
    if (mqtt_stream_len != 0u) {
        memmove(NET_STREAM, NET_STREAM + total, mqtt_stream_len);
    }
}

static int16_t mqtt_fill(void)
{
    uint8_t budget = UNET_RECV_BUDGET;

    while (budget-- != 0u && mqtt_stream_len < MQTT_STREAM_MAX) {
        uint16_t flags;
        uint16_t capacity = (uint16_t)(MQTT_STREAM_MAX - mqtt_stream_len);
        int16_t got;

        if (capacity > SPECTRUM_MQTT_PACKET_MAX) {
            capacity = SPECTRUM_MQTT_PACKET_MAX;
        }
        got = checked_recv(capacity, &flags);

        if (got > 0) {
            memcpy(NET_STREAM + mqtt_stream_len, NET_RECV, (uint16_t)got);
            mqtt_stream_len = (uint8_t)(mqtt_stream_len + (uint8_t)got);
        } else if (got < 0) {
            return got;
        } else {
            break;
        }
        if ((flags & SHATRANJ_UNET_RX_MORE) == 0u) {
            break;
        }
    }
    return mqtt_stream_len;
}

static int16_t mqtt_next_packet(void)
{
    uint8_t total = 0u;
    uint8_t state = mqtt_take_packet(&total);

    if (state == 1u) {
        return total;
    }
    if (state == 2u) {
        sprinter_unet_mark_fault();
        return -1;
    }
    if (mqtt_fill() < 0) {
        state = mqtt_take_packet(&total);
        return state == 1u ? total : -2;
    }
    state = mqtt_take_packet(&total);
    if (state == 2u) {
        sprinter_unet_mark_fault();
        return -1;
    }
    return state == 1u ? total : SPECTRUM_LINK_READ_TIMEOUT;
}

static uint8_t mqtt_wait_type(uint8_t wanted)
{
    uint16_t polls = MQTT_WAIT_POLLS;

    while (polls-- != 0u) {
        int16_t got = mqtt_next_packet();

        if (got == SPECTRUM_LINK_READ_TIMEOUT) {
            spectrum_net_runtime_wait_frame_plain();
            continue;
        }
        if (got <= 0) {
            return 0u;
        }
        if (spectrum_mqtt_type(NET_STREAM, (uint8_t)got) == wanted) {
            memcpy(NET_PACKET, NET_STREAM, (uint8_t)got);
            mqtt_consume((uint8_t)got);
            return 1u;
        }
        mqtt_consume((uint8_t)got);
    }
    return 0u;
}

static uint16_t mqtt_alloc_id(void)
{
    uint16_t id = mqtt_next_id++;

    if (mqtt_next_id == 0u) {
        mqtt_next_id = 1u;
    }
    return id;
}

static char *mqtt_topic(char *out, const char *suffix)
{
    out = spectrum_append_text(out, "netchesszx/v1/");
    out = spectrum_append_text(out, netchesszx_mqtt_code);
    out = spectrum_append_text(out, "/");
    return spectrum_append_text(out, suffix);
}

static uint8_t mqtt_publish_suffix(const char *suffix,
                                   const char *payload,
                                   uint8_t retain)
{
    char topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    uint8_t length;

    (void)mqtt_topic(topic, suffix);
    length = spectrum_mqtt_publish(NET_PACKET, SPECTRUM_MQTT_PACKET_MAX,
                                   mqtt_alloc_id(), topic, payload, retain);
    return (uint8_t)(length != 0u && checked_send(NET_PACKET, length));
}

static uint8_t mqtt_subscribe_suffix(const char *suffix)
{
    char topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    uint16_t id = mqtt_alloc_id();
    uint8_t length;

    (void)mqtt_topic(topic, suffix);
    length = spectrum_mqtt_subscribe(NET_PACKET, SPECTRUM_MQTT_PACKET_MAX,
                                     id, topic);
    if (length == 0u || !checked_send(NET_PACKET, length) ||
        !mqtt_wait_type(SPECTRUM_MQTT_SUBACK)) {
        return 0u;
    }
    return (uint8_t)(NET_PACKET[1u] == 3u &&
                     NET_PACKET[2u] == (uint8_t)(id >> 8) &&
                     NET_PACKET[3u] == (uint8_t)id &&
                     NET_PACKET[4u] <= 2u);
}

static uint8_t mqtt_connect_packet(void)
{
    char client[28];
    char will_topic[SPECTRUM_MQTT_TOPIC_MAX + 1u];
    char will_payload[12];
    char *p;
    uint8_t client_len;
    uint8_t topic_len;
    uint8_t payload_len;
    uint8_t remaining;
    uint8_t pos = 0u;
    uint16_t nonce = netchesszx_mqtt_session_id;

    p = spectrum_append_text(client, "ZX");
    p = spectrum_append_text(p, netchesszx_mqtt_code);
    *p++ = netchesszx_session_is_host() ? 'H' : 'J';
    *p++ = (char)('A' + (uint8_t)((nonce >> 12) & 15u));
    *p++ = (char)('A' + (uint8_t)((nonce >> 8) & 15u));
    *p++ = (char)('A' + (uint8_t)((nonce >> 4) & 15u));
    *p++ = (char)('A' + (uint8_t)(nonce & 15u));
    *p = '\0';
    (void)mqtt_topic(will_topic, spectrum_net_mqtt_presence_suffix());
    p = spectrum_append_text(will_payload, "F ");
    *p++ = netchesszx_local_side_char();
    *p = '\0';
    client_len = (uint8_t)strlen(client);
    topic_len = (uint8_t)strlen(will_topic);
    payload_len = (uint8_t)strlen(will_payload);
    remaining = (uint8_t)(10u + 2u + client_len + 2u + topic_len +
                          2u + payload_len);
    if (remaining >= 128u) {
        return 0u;
    }
    NET_PACKET[pos++] = 0x10u;
    NET_PACKET[pos++] = remaining;
    NET_PACKET[pos++] = 0u;
    NET_PACKET[pos++] = 4u;
    memcpy(NET_PACKET + pos, "MQTT", 4u);
    pos = (uint8_t)(pos + 4u);
    NET_PACKET[pos++] = 4u;
    NET_PACKET[pos++] = 0x06u;
    NET_PACKET[pos++] = 0u;
    NET_PACKET[pos++] = 20u;
#define MQTT_PUT_STRING(value, value_len) do { \
    NET_PACKET[pos++] = 0u; \
    NET_PACKET[pos++] = (value_len); \
    memcpy(NET_PACKET + pos, (value), (value_len)); \
    pos = (uint8_t)(pos + (value_len)); \
} while (0)
    MQTT_PUT_STRING(client, client_len);
    MQTT_PUT_STRING(will_topic, topic_len);
    MQTT_PUT_STRING(will_payload, payload_len);
#undef MQTT_PUT_STRING
    return pos;
}

static uint8_t mqtt_subscribe_side(void)
{
    return (uint8_t)(
        mqtt_subscribe_suffix(spectrum_net_mqtt_in_suffix()) &&
        mqtt_subscribe_suffix(spectrum_net_mqtt_in_ack_suffix()) &&
        mqtt_subscribe_suffix(spectrum_net_mqtt_peer_presence_suffix()) &&
        mqtt_subscribe_suffix(spectrum_net_mqtt_presence_suffix()));
}

uint8_t sprinter_unet_mqtt_publish_setup_core(uint8_t mode)
{
    char setup[32];

    if (mode == SPECTRUM_LINK_MQTT_SETUP_CLEAR) {
        return mqtt_publish_suffix("meta", "", 1u);
    }
    spectrum_net_mqtt_setup_payload(setup);
    return mqtt_publish_suffix("meta", setup,
        (uint8_t)(mode == SPECTRUM_LINK_MQTT_SETUP_RETAINED));
}

uint8_t sprinter_unet_mqtt_publish_presence_core(void)
{
    return mqtt_publish_suffix(spectrum_net_mqtt_presence_suffix(),
                               spectrum_net_mqtt_presence_payload(), 1u);
}

uint8_t sprinter_unet_mqtt_activate_core(void)
{
    uint8_t result = (uint8_t)(
        mqtt_subscribe_side() &&
        sprinter_unet_mqtt_publish_presence_core() &&
        sprinter_unet_mqtt_publish_setup_core(SPECTRUM_LINK_MQTT_SETUP_LIVE));

    if (!result) {
        close_channel();
    }
    return result;
}

uint8_t sprinter_unet_mqtt_probe_core(void)
{
    uint8_t result =
        mqtt_subscribe_suffix(spectrum_net_mqtt_presence_suffix());

    if (!result) {
        close_channel();
    }
    return result;
}

uint8_t sprinter_unet_mqtt_start_core(void)
{
    uint8_t length;
    uint8_t connect_result = tcp_connect(netchesszx_mqtt_host,
                                         netchesszx_mqtt_port);

    if (connect_result != 1u) {
        return 0u;
    }
    length = mqtt_connect_packet();
    if (length == 0u || !checked_send(NET_PACKET, length) ||
        !mqtt_wait_type(SPECTRUM_MQTT_CONNACK) || NET_PACKET[1u] != 2u ||
        NET_PACKET[3u] != 0u || !mqtt_subscribe_suffix("meta")) {
        close_channel();
        return 0u;
    }
    if (netchesszx_session_is_host() || netchesszx_host_color_ready) {
        return sprinter_unet_mqtt_activate_core();
    }
    return 1u;
}

uint8_t sprinter_unet_mqtt_send_core(const char *text)
{
    if (string_starts(text, "ACK GAME START") ||
        string_starts(text, netchesszx_text_game_start)) {
        return mqtt_publish_suffix("meta", text, 0u);
    }
    if (string_starts(text, "ACK ")) {
        return mqtt_publish_suffix(spectrum_net_mqtt_out_ack_suffix(), text, 0u);
    }
    return mqtt_publish_suffix(spectrum_net_mqtt_out_suffix(), text, 0u);
}

static void mqtt_puback(uint16_t id)
{
    if (id != 0u) {
        uint8_t ack[4];
        ack[0u] = 0x40u;
        ack[1u] = 2u;
        ack[2u] = (uint8_t)(id >> 8);
        ack[3u] = (uint8_t)id;
        (void)checked_send(ack, 4u);
    }
}

static int16_t mqtt_read_payload(char *payload, uint8_t payload_cap)
{
    for (;;) {
        uint16_t id;
        uint8_t flags;
        int16_t got = mqtt_next_packet();
        int16_t length;
        uint8_t type;

        if (got == SPECTRUM_LINK_READ_TIMEOUT) {
            uint8_t keepalive = spectrum_mqtt_broker_keepalive_timeout(
                &mqtt_keepalive);
            if (keepalive == SPECTRUM_MQTT_KEEPALIVE_LOST) {
                return -2;
            }
            if (keepalive == SPECTRUM_MQTT_KEEPALIVE_SEND) {
                static const uint8_t ping[2] = {0xc0u, 0u};
                if (!checked_send(ping, 2u)) {
                    return -2;
                }
            }
            return SPECTRUM_LINK_READ_TIMEOUT;
        }
        if (got <= 0) {
            return -2;
        }
        type = spectrum_mqtt_type(NET_STREAM, (uint8_t)got);
        if (type == SPECTRUM_MQTT_PINGRESP) {
            spectrum_mqtt_broker_keepalive_reset(&mqtt_keepalive);
            mqtt_consume((uint8_t)got);
            continue;
        }
        if (type != SPECTRUM_MQTT_PUBLISH) {
            mqtt_consume((uint8_t)got);
            continue;
        }
        length = spectrum_mqtt_parse_publish(NET_STREAM, (uint8_t)got,
                                             payload, payload_cap, &id,
                                             &flags);
        mqtt_consume((uint8_t)got);
        mqtt_puback(id);
        if (length < 0) {
            sprinter_unet_mark_fault();
            return -2;
        }
        payload_flags = flags;
        spectrum_mqtt_broker_keepalive_reset(&mqtt_keepalive);
        return 0;
    }
}

static char *direct_slot(uint8_t slot)
{
    return (char *)NET_STREAM + (uint16_t)slot * DIRECT_SLOT_SIZE;
}

static char *direct_partial(void)
{
    return direct_slot(DIRECT_QUEUE_COUNT);
}

static uint8_t direct_queue_partial(void)
{
    uint8_t tail;

    if (direct_partial_len == 0u) {
        return 1u;
    }
    if (direct_count == DIRECT_QUEUE_COUNT) {
        return 0u;
    }
    tail = (uint8_t)((direct_head + direct_count) % DIRECT_QUEUE_COUNT);
    memcpy(direct_slot(tail), direct_partial(), direct_partial_len);
    direct_slot(tail)[direct_partial_len] = '\0';
    direct_partial_len = 0u;
    ++direct_count;
    return 1u;
}

static uint8_t direct_feed(const uint8_t *data, uint16_t length)
{
    while (length-- != 0u) {
        uint8_t byte = *data++;

        if (byte == '\r') {
            continue;
        }
        if (byte == '\n') {
            if (direct_dropping) {
                direct_dropping = 0u;
                direct_partial_len = 0u;
                sprinter_unet_mark_fault();
                return 0u;
            }
            if (!direct_queue_partial()) {
                sprinter_unet_mark_fault();
                return 0u;
            }
            continue;
        }
        if (direct_dropping) {
            continue;
        }
        if (direct_partial_len >= SPECTRUM_LINK_PAYLOAD_MAX) {
            direct_partial_len = 0u;
            direct_dropping = 1u;
            continue;
        }
        direct_partial()[direct_partial_len++] = (char)byte;
    }
    return 1u;
}

static void direct_drain(void)
{
    uint8_t budget = UNET_RECV_BUDGET;

    while (budget-- != 0u && direct_count != DIRECT_QUEUE_COUNT && link_active) {
        uint16_t flags;
        int16_t got = checked_recv(SPECTRUM_MQTT_PACKET_MAX, &flags);

        if (got > 0) {
            if (!direct_feed(NET_RECV, (uint16_t)got)) {
                link_active = 0u;
                return;
            }
        } else {
            return;
        }
        if ((flags & SHATRANJ_UNET_RX_MORE) == 0u) {
            return;
        }
    }
}

uint8_t sprinter_unet_direct_connect_core(void)
{
    return tcp_connect(netchesszx_direct_host, netchesszx_direct_port);
}

int16_t sprinter_unet_direct_read_core(char *payload, uint8_t payload_cap)
{
    uint8_t length;

    if (direct_count == 0u && link_active) {
        direct_drain();
    }
    if (direct_count != 0u) {
        length = (uint8_t)strlen(direct_slot(direct_head));
        if (payload_cap == 0u || length >= payload_cap) {
            sprinter_unet_mark_fault();
            return -1;
        }
        memcpy(payload, direct_slot(direct_head), (uint8_t)(length + 1u));
        direct_head = (uint8_t)((direct_head + 1u) % DIRECT_QUEUE_COUNT);
        --direct_count;
        return 0;
    }
    if (terminal_closed || sprinter_unet_faulted()) {
        return -2;
    }
    return SPECTRUM_LINK_READ_TIMEOUT;
}

uint8_t sprinter_unet_direct_send_core(const char *text)
{
    uint8_t length = (uint8_t)strlen(text);

    if (length >= SPECTRUM_NET_DIRECT_TX_PAYLOAD_CAP) {
        return 0u;
    }
    memcpy(NET_PACKET, text, length);
    NET_PACKET[length++] = '\n';
    return checked_send(NET_PACKET, length);
}

void spectrum_net_start_uart(void)
{
    reset_link_state();
}

uint8_t spectrum_net_preflight_run(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_preflight_core()
        ? SPECTRUM_LINK_PREFLIGHT_OK : SPECTRUM_LINK_PREFLIGHT_FAILED;
#else
    if (!spectrum_overlay_exec_cached(SPECTRUM_OVL_NET_CONNECT,
                                      SPECTRUM_OVL_NET_PREFLIGHT)) {
        return SPECTRUM_LINK_PREFLIGHT_OVL_FAIL;
    }
    return spectrum_overlay_context[SPECTRUM_OVL_CTX_PREFLIGHT_OK]
        ? SPECTRUM_LINK_PREFLIGHT_OK : SPECTRUM_LINK_PREFLIGHT_FAILED;
#endif
}

uint8_t spectrum_net_listen(void)
{
    /* CAP_LISTEN is deliberately not present in either pinned backend. */
    return 0u;
}

uint8_t spectrum_net_connect_host(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_direct_connect_core();
#else
    return spectrum_overlay_exec(SPECTRUM_OVL_DIRECT,
                                 SPECTRUM_OVL_DIRECT_CONNECT);
#endif
}

uint8_t spectrum_net_wait_pc_connect(void)
{
    return 0u;
}

void spectrum_net_direct_peer_mark_valid(void)
{
    link_activity = 1u;
}

int16_t spectrum_net_read_payload(char *payload, uint8_t payload_cap)
{
    payload_flags = 0u;
    if (netchesszx_transport_is_mqtt()) {
        return mqtt_read_payload(payload, payload_cap);
    }
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_direct_read_core(payload, payload_cap);
#else
    {
        uint16_t address = (uint16_t)(uintptr_t)payload;
        uint8_t result;
        spectrum_overlay_context[0] = (uint8_t)address;
        spectrum_overlay_context[1] = (uint8_t)(address >> 8);
        spectrum_overlay_context[2] = payload_cap;
        result = spectrum_overlay_exec_cached(SPECTRUM_OVL_DIRECT,
                                              SPECTRUM_OVL_DIRECT_READ);
        return (int16_t)(int8_t)result;
    }
#endif
}

uint8_t spectrum_net_send_text(const char *text) NETCHESSZX_FASTCALL
{
#ifdef NETCHESSZX_HOST_TEST
    return netchesszx_transport_is_mqtt()
        ? sprinter_unet_mqtt_send_core(text)
        : sprinter_unet_direct_send_core(text);
#else
    uint16_t address = (uint16_t)(uintptr_t)text;
    spectrum_overlay_context[0] = (uint8_t)address;
    spectrum_overlay_context[1] = (uint8_t)(address >> 8);
    return spectrum_overlay_exec_cached(
        netchesszx_transport_is_mqtt() ? SPECTRUM_OVL_MQTT_TX
                                       : SPECTRUM_OVL_DIRECT,
        netchesszx_transport_is_mqtt() ? SPECTRUM_OVL_MQTT_TX_SEND_TEXT
                                       : SPECTRUM_OVL_DIRECT_SEND);
#endif
}

uint8_t spectrum_net_send_ping(void)
{
    return spectrum_net_send_text(NETCHESS_PROTO_PING);
}

char *spectrum_net_payload_scratch(void)
{
    return (char *)NET_PACKET;
}

uint8_t spectrum_net_link_activity(void)
{
    uint8_t result = link_activity;
    link_activity = 0u;
    return result;
}

uint8_t spectrum_net_payload_flags(void)
{
    return payload_flags;
}

void spectrum_net_background_drain(void)
{
    if (netchesszx_transport_is_mqtt()) {
        (void)mqtt_fill();
    } else if (direct_count != DIRECT_QUEUE_COUNT) {
        direct_drain();
    }
}

const char *spectrum_net_last_ip(void)
{
    return NET_IP;
}

uint8_t spectrum_net_sync_time(void)
{
    /* DSS RTC/FAT state was captured before graphics startup. */
    return spectrum_net_runtime_clock_ready();
}

uint8_t spectrum_net_mqtt_start(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_mqtt_start_core();
#else
    return spectrum_overlay_exec(SPECTRUM_OVL_MQTT_CONNECT,
                                 SPECTRUM_OVL_MQTT_CONNECT_START);
#endif
}

uint8_t spectrum_net_mqtt_activate_side(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_mqtt_activate_core();
#else
    return spectrum_overlay_exec(SPECTRUM_OVL_MQTT_CONNECT,
                                 SPECTRUM_OVL_MQTT_CONNECT_ACTIVATE);
#endif
}

uint8_t spectrum_net_mqtt_probe_seat(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_mqtt_probe_core();
#else
    return spectrum_overlay_exec(SPECTRUM_OVL_MQTT_CONNECT,
                                 SPECTRUM_OVL_MQTT_CONNECT_PROBE_SEAT);
#endif
}

uint8_t spectrum_net_mqtt_publish_presence(void)
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_mqtt_publish_presence_core();
#else
    return spectrum_overlay_exec_cached(
        SPECTRUM_OVL_MQTT_TX, SPECTRUM_OVL_MQTT_TX_PUBLISH_PRESENCE);
#endif
}

uint8_t spectrum_net_mqtt_publish_setup(uint8_t mode) NETCHESSZX_FASTCALL
{
#ifdef NETCHESSZX_HOST_TEST
    return sprinter_unet_mqtt_publish_setup_core(mode);
#else
    spectrum_overlay_context[0] = mode;
    return spectrum_overlay_exec_cached(SPECTRUM_OVL_MQTT_TX,
                                        SPECTRUM_OVL_MQTT_TX_PUBLISH_SETUP);
#endif
}
