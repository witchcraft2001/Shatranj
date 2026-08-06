#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "spectrum/config/session.h"
#include "spectrum/platform/text.h"
#include "spectrum/transport/link.h"
#include "spectrum/transport/mqtt_min.h"
#include "sprinter/unet_abi.h"
#include "sprinter/unet_link.h"
#include "sprinter/unet_runtime.h"

#define MAX_POINTERS 64u
#define MAX_EVENTS 128u
#define MAX_RECV 32u

typedef struct recv_item {
    uint8_t status;
    uint16_t flags;
    uint16_t length;
    uint8_t data[192];
} recv_item_t;

static const void *pointer_table[MAX_POINTERS];
static uint16_t pointer_count;
static uint8_t events[MAX_EVENTS];
static uint8_t event_count;
static recv_item_t recv_items[MAX_RECV];
static uint8_t recv_head;
static uint8_t recv_count;
static const char *fake_env;
static uint8_t fake_backend;
static uint16_t fake_caps;
static uint16_t fake_abi;
static uint8_t fake_fail_fn;
static uint8_t fake_status_fn;
static uint8_t fake_status;
static uint8_t fake_short_send;
static uint8_t fake_loaded;

uint16_t sprinter_unet_host_encode_pointer(const void *pointer)
{
    uint16_t token;
    for (token = 1u; token <= pointer_count; ++token) {
        if (pointer_table[token] == pointer) {
            return token;
        }
    }
    assert(pointer_count + 1u < MAX_POINTERS);
    token = ++pointer_count;
    pointer_table[token] = pointer;
    return token;
}

static void *decode_pointer(uint16_t token)
{
    assert(token != 0u && token <= pointer_count);
    return (void *)pointer_table[token];
}

static void event(uint8_t value)
{
    assert(event_count < MAX_EVENTS);
    events[event_count++] = value;
}

static void reset_fake(void)
{
    memset(pointer_table, 0, sizeof(pointer_table));
    memset(events, 0, sizeof(events));
    memset(recv_items, 0, sizeof(recv_items));
    pointer_count = 0u;
    event_count = 0u;
    recv_head = 0u;
    recv_count = 0u;
    fake_env = "WIFI";
    fake_backend = SHATRANJ_UNET_BACKEND_WIFI;
    fake_caps = 0x010fu;
    fake_abi = SHATRANJ_UNET_ABI_VERSION;
    fake_fail_fn = 0xffu;
    fake_status_fn = 0xffu;
    fake_status = SHATRANJ_NERR_OK;
    fake_short_send = 0u;
    fake_loaded = 0u;
    sprinter_unet_set_initialized(0u);
}

static void queue_recv(uint8_t status, uint16_t flags,
                       const uint8_t *data, uint16_t length)
{
    recv_item_t *item;
    uint8_t tail;
    assert(recv_count < MAX_RECV && length <= sizeof(item->data));
    tail = (uint8_t)((recv_head + recv_count) % MAX_RECV);
    item = &recv_items[tail];
    item->status = status;
    item->flags = flags;
    item->length = length;
    if (length != 0u) {
        memcpy(item->data, data, length);
    }
    ++recv_count;
}

uint8_t sprinter_unet_load(const char *name, uint8_t *info)
{
    const char *tag = fake_backend == SHATRANJ_UNET_BACKEND_WIFI
        ? "UNETESP" : "UNETRTL";
    event(0x80u);
    if ((fake_backend == SHATRANJ_UNET_BACKEND_WIFI &&
         strcmp(name, "UNETESP.DLL") != 0) ||
        (fake_backend == SHATRANJ_UNET_BACKEND_RTL &&
         strcmp(name, "UNETRTL.DLL") != 0)) {
        return 0u;
    }
    memset(info, 0, 32u);
    strcpy((char *)info + 16u, tag);
    fake_loaded = 1u;
    return 1u;
}

void sprinter_unet_unload(void)
{
    if (fake_loaded) {
        event(0x81u);
        fake_loaded = 0u;
    }
}

uint8_t sprinter_unet_getenv(char *value)
{
    if (fake_env == NULL) {
        return 0u;
    }
    strcpy(value, fake_env);
    return 1u;
}

uint8_t sprinter_unet_call(uint8_t fn, shatranj_unet_regs_t *regs)
{
    event(fn);
    if (fn == fake_fail_fn) {
        regs->a = SHATRANJ_NERR_HW;
        return 1u;
    }
    regs->a = SHATRANJ_NERR_OK;
    if (fn == fake_status_fn) {
        regs->a = fake_status;
        return 1u;
    }
    if (fn == SHATRANJ_UNET_FN_GETCAPS) {
        SHATRANJ_UNET_SET_DE(regs, fake_caps);
        SHATRANJ_UNET_SET_IX(regs, fake_abi);
    } else if (fn == SHATRANJ_UNET_FN_GETINFO) {
        strcpy((char *)decode_pointer(SHATRANJ_UNET_GET_DE(regs)),
               "192.168.1.77");
    } else if (fn == SHATRANJ_UNET_FN_RECV) {
        recv_item_t *item;
        uint16_t destination = SHATRANJ_UNET_GET_DE(regs);
        uint16_t cap = SHATRANJ_UNET_GET_IX(regs);
        assert(cap <= SPECTRUM_MQTT_PACKET_MAX);
        if (recv_count == 0u) {
            SHATRANJ_UNET_SET_DE(regs, 0u);
            SHATRANJ_UNET_SET_IX(regs, 0u);
            return 1u;
        }
        item = &recv_items[recv_head];
        assert(item->length <= cap);
        regs->a = item->status;
        if (item->length != 0u) {
            memcpy(decode_pointer(destination), item->data, item->length);
        }
        SHATRANJ_UNET_SET_DE(regs, item->length);
        SHATRANJ_UNET_SET_IX(regs, item->flags);
        recv_head = (uint8_t)((recv_head + 1u) % MAX_RECV);
        --recv_count;
    } else if (fn == SHATRANJ_UNET_FN_SEND) {
        uint16_t length = SHATRANJ_UNET_GET_IX(regs);
        SHATRANJ_UNET_SET_DE(regs, fake_short_send && length != 0u
                                      ? (uint16_t)(length - 1u) : length);
    }
    return 1u;
}

char *spectrum_append_text(char *dst, const char *src)
{
    while (*src != '\0') {
        *dst++ = *src++;
    }
    *dst = '\0';
    return dst;
}

char *spectrum_append_u16(char *dst, uint16_t value)
{
    char tmp[6];
    sprintf(tmp, "%u", value);
    return spectrum_append_text(dst, tmp);
}

void spectrum_net_runtime_wait_frame_plain(void) {}
uint8_t spectrum_net_runtime_clock_ready(void) { return 1u; }

static uint8_t make_publish(uint8_t *out, const char *payload)
{
    const char *topic = "netchesszx/v1/DEVROOM/w2b";
    uint8_t topic_len = (uint8_t)strlen(topic);
    uint8_t payload_len = (uint8_t)strlen(payload);
    uint8_t remaining = (uint8_t)(2u + topic_len + 2u + payload_len);
    out[0] = 0x32u;
    out[1] = remaining;
    out[2] = 0u;
    out[3] = topic_len;
    memcpy(out + 4u, topic, topic_len);
    out[4u + topic_len] = 0u;
    out[5u + topic_len] = 7u;
    memcpy(out + 6u + topic_len, payload, payload_len);
    return (uint8_t)(2u + remaining);
}

static void preflight(uint8_t backend)
{
    fake_backend = backend;
    fake_env = backend == SHATRANJ_UNET_BACKEND_WIFI ? "WIFI" : "RTL";
    fake_caps = backend == SHATRANJ_UNET_BACKEND_WIFI ? 0x010fu : 0x000fu;
    assert(sprinter_unet_preflight_core());
    assert(strcmp(spectrum_net_last_ip(), "192.168.1.77") == 0);
}

static void test_backend_selection(void)
{
    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    sprinter_unet_shutdown();
    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_RTL);
    sprinter_unet_shutdown();
    reset_fake();
    fake_backend = SHATRANJ_UNET_BACKEND_RTL;
    fake_env = "rtl";
    fake_caps = 0x000fu;
    assert(sprinter_unet_preflight_core());
    sprinter_unet_shutdown();

    reset_fake();
    fake_env = NULL;
    assert(!sprinter_unet_preflight_core());
    reset_fake();
    fake_env = "OTHER";
    assert(!sprinter_unet_preflight_core());
    reset_fake();
    fake_caps = SHATRANJ_UNET_CAP_TCP;
    assert(!sprinter_unet_preflight_core());
    reset_fake();
    fake_abi = 0x0200u;
    assert(!sprinter_unet_preflight_core());
}

static void test_abi_and_nerr_mapping(void)
{
    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    fake_status_fn = SHATRANJ_UNET_FN_CONNECT;
    fake_status = SHATRANJ_NERR_CANCEL;
    assert(sprinter_unet_direct_connect_core() == SPECTRUM_LINK_CANCELLED);
    fake_status = SHATRANJ_NERR_CONNECT;
    assert(sprinter_unet_direct_connect_core() == 0u);

    assert(SHATRANJ_UNET_FN_COUNT == 24u);
    assert(SHATRANJ_NERR_AGAIN == 15u);
    assert(SHATRANJ_UNET_CAP_RXFLOW == 0x0100u);
    assert(SHATRANJ_UNET_RX_LOST == 0x0004u);
    assert(SHATRANJ_UNET_IF_HW == 12u);
    assert(SHATRANJ_UNET_OPT_SENDSLICE == 3u);
}

static void test_slow_guards(void)
{
    uint16_t i;

    /* A classified operation may begin before NETINIT (the preflight cold
       gate itself does exactly that) and finish after NETINIT succeeds.  It
       did not pause a live receiver, so its matching exit must consume the
       pre-init token without issuing RXRESUME or reporting underflow. */
    reset_fake();
    assert(sprinter_rx_slow_enter());
    event(0x70u);
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_leave());
    assert(event_count == 1u);
    assert(events[0] == 0x70u);
    assert(!sprinter_unet_faulted());

    /* A nested slow operation entered after NETINIT still owns a normal
       RXPAUSE/RXRESUME pair; the outer pre-init token remains independent. */
    reset_fake();
    assert(sprinter_rx_slow_enter());
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_enter());
    event(0x71u);
    assert(sprinter_rx_slow_leave());
    assert(sprinter_rx_slow_leave());
    assert(event_count == 3u);
    assert(events[0] == SHATRANJ_UNET_FN_RXPAUSE);
    assert(events[1] == 0x71u);
    assert(events[2] == SHATRANJ_UNET_FN_RXRESUME);
    assert(!sprinter_unet_faulted());

    reset_fake();
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_enter());
    event(0x70u);                 /* classified work */
    assert(sprinter_rx_slow_enter());
    assert(sprinter_rx_slow_leave());
    assert(sprinter_rx_slow_leave());
    assert(event_count == 3u);
    assert(events[0] == SHATRANJ_UNET_FN_RXPAUSE);
    assert(events[1] == 0x70u);
    assert(events[2] == SHATRANJ_UNET_FN_RXRESUME);
    assert(!sprinter_rx_slow_leave());
    assert(sprinter_unet_faulted());

    reset_fake();
    sprinter_unet_set_initialized(1u);
    fake_fail_fn = SHATRANJ_UNET_FN_RXPAUSE;
    assert(!sprinter_rx_slow_enter());
    assert(event_count == 1u);    /* work was cancelled */

    reset_fake();
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_enter());
    fake_fail_fn = SHATRANJ_UNET_FN_RXRESUME;
    assert(!sprinter_rx_slow_leave());
    assert(!sprinter_unet_can_recv());

    reset_fake();
    fake_loaded = 1u;
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_enter());
    sprinter_unet_shutdown();
    assert(events[0] == SHATRANJ_UNET_FN_RXPAUSE);
    assert(events[1] == SHATRANJ_UNET_FN_RXRESUME);
    assert(events[2] == SHATRANJ_UNET_FN_CLOSE);
    assert(events[3] == SHATRANJ_UNET_FN_NETDONE);
    assert(events[4] == 0x81u);

    reset_fake();
    fake_loaded = 1u;
    sprinter_unet_set_initialized(1u);
    assert(sprinter_rx_slow_enter());
    fake_fail_fn = SHATRANJ_UNET_FN_RXRESUME;
    sprinter_unet_shutdown();
    assert(events[0] == SHATRANJ_UNET_FN_RXPAUSE);
    assert(events[1] == SHATRANJ_UNET_FN_RXRESUME);
    assert(events[2] == SHATRANJ_UNET_FN_CLOSE);
    assert(events[3] == SHATRANJ_UNET_FN_NETDONE);
    assert(events[4] == 0x81u);

    reset_fake();
    sprinter_unet_set_initialized(1u);
    for (i = 0u; i < 255u; ++i) {
        assert(sprinter_rx_slow_enter());
    }
    assert(!sprinter_rx_slow_enter());
    assert(sprinter_unet_faulted());
    sprinter_unet_shutdown();
}

static void test_direct_stream(void)
{
    static const uint8_t a[] = "HELLO DIR";
    static const uint8_t b[] = "ECT\r\nMOVE 1 e2";
    static const uint8_t c[] = "e4\n";
    char payload[49];

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_MORE, a, sizeof(a) - 1u);
    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_MORE, b, sizeof(b) - 1u);
    queue_recv(SHATRANJ_NERR_OK, 0u, c, sizeof(c) - 1u);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "HELLO DIRECT") == 0);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "MOVE 1 e2e4") == 0);
    queue_recv(SHATRANJ_NERR_CLOSED, 0u, NULL, 0u);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == -2);

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_RTL);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_MORE,
               (const uint8_t *)"FINAL\n", 6u);
    queue_recv(SHATRANJ_NERR_CLOSED, 0u, NULL, 0u);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "FINAL") == 0);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == -2);

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_RTL);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    {
        uint8_t oversized[SPECTRUM_LINK_PAYLOAD_MAX + 2u];
        memset(oversized, 'X', sizeof(oversized));
        oversized[sizeof(oversized) - 1u] = '\n';
        queue_recv(SHATRANJ_NERR_OK, 0u, oversized, sizeof(oversized));
    }
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == -2);
    assert(sprinter_unet_faulted());

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_RTL);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    fake_short_send = 1u;
    assert(!sprinter_unet_direct_send_core("PING"));
    assert(sprinter_unet_faulted());
    fake_short_send = 0u;
    assert(sprinter_unet_direct_connect_core() == 1u);
    assert(!sprinter_unet_faulted());

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_RTL);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    queue_recv(SHATRANJ_NERR_OK, 0u,
               (const uint8_t *)"ONE\nTWO\nTHREE\nFOUR\n", 19u);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "ONE") == 0);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "TWO") == 0);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "THREE") == 0);
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == -2);
}

static void test_recv_rejected_while_paused(void)
{
    char payload[49];
    uint8_t before;

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_DIRECT,
                                 NETCHESSZX_COLOR_WHITE);
    assert(sprinter_unet_direct_connect_core() == 1u);
    assert(sprinter_rx_slow_enter());
    before = event_count;
    assert(sprinter_unet_direct_read_core(payload, sizeof(payload)) == -2);
    assert(event_count == before); /* No path from paused state to RECV. */
    assert(sprinter_unet_faulted());
    (void)sprinter_rx_slow_leave();
}

static void test_mqtt_stream(void)
{
    uint8_t startup[] = {0x20u, 2u, 0u, 0u,
                         0x90u, 3u, 0u, 1u, 1u};
    uint8_t packets[160];
    uint8_t first;
    uint8_t second;
    char payload[49];

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_MQTT,
                                 NETCHESSZX_COLOR_WHITE);
    netchesszx_host_color_ready = 0u;
    strcpy(netchesszx_mqtt_code, "DEVROOM");
    queue_recv(SHATRANJ_NERR_OK, 0u, startup, sizeof(startup));
    assert(sprinter_unet_mqtt_start_core());

    first = make_publish(packets, "PING");
    second = make_publish(packets + first, "ACK PING");
    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_MORE,
               packets, (uint16_t)(first - 3u));
    queue_recv(SHATRANJ_NERR_OK, 0u, packets + first - 3u,
               (uint16_t)(second + 3u));
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "PING") == 0);
    assert((spectrum_net_payload_flags() &
            SPECTRUM_LINK_PAYLOAD_GAME_ROUTE) != 0u);
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "ACK PING") == 0);

    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_LOST,
               (const uint8_t *)"X", 1u);
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == -2);

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_MQTT,
                                 NETCHESSZX_COLOR_WHITE);
    netchesszx_host_color_ready = 0u;
    strcpy(netchesszx_mqtt_code, "DEVROOM");
    queue_recv(SHATRANJ_NERR_OK, 0u, startup, sizeof(startup));
    assert(sprinter_unet_mqtt_start_core());
    first = make_publish(packets, "FINAL");
    queue_recv(SHATRANJ_NERR_OK, SHATRANJ_UNET_RX_MORE, packets, first);
    queue_recv(SHATRANJ_NERR_CLOSED, 0u, NULL, 0u);
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == 0);
    assert(strcmp(payload, "FINAL") == 0);
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == -2);

    reset_fake();
    preflight(SHATRANJ_UNET_BACKEND_WIFI);
    netchesszx_session_configure(NETCHESSZX_SESSION_ROLE_JOIN,
                                 NETCHESSZX_TRANSPORT_MQTT,
                                 NETCHESSZX_COLOR_WHITE);
    netchesszx_host_color_ready = 0u;
    strcpy(netchesszx_mqtt_code, "DEVROOM");
    queue_recv(SHATRANJ_NERR_OK, 0u, startup, sizeof(startup));
    assert(sprinter_unet_mqtt_start_core());
    packets[0] = 0x30u;
    packets[1] = 0xffu;
    packets[2] = 0xffu;
    queue_recv(SHATRANJ_NERR_OK, 0u, packets, 3u);
    assert(spectrum_net_read_payload(payload, sizeof(payload)) == -2);
    assert(sprinter_unet_faulted());
}

int main(void)
{
    test_backend_selection();
    test_abi_and_nerr_mapping();
    test_slow_guards();
    test_direct_stream();
    test_recv_rejected_while_paused();
    test_mqtt_stream();
    return 0;
}
