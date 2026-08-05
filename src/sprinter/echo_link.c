#include "spectrum/transport/link.h"

#include <string.h>

#define ECHO_QUEUE_COUNT 3u
#define ECHO_TEXT_CAP (SPECTRUM_LINK_PAYLOAD_MAX + 1u)

static char echo_queue[ECHO_QUEUE_COUNT][ECHO_TEXT_CAP];
static char echo_scratch[ECHO_TEXT_CAP];
/* Handwritten shrink kernels retain this resident compatibility symbol even
   though the Stage-2 link never parses ESP-AT lines. */
char line_buf[8];
static uint8_t echo_head;
static uint8_t echo_count;
static uint8_t echo_hello_sent;
static uint8_t echo_activity;

static uint8_t echo_starts_with(const char *text, const char *prefix)
{
    while (*prefix != '\0') {
        if (*text++ != *prefix++) {
            return 0u;
        }
    }
    return 1u;
}

static uint8_t echo_enqueue(const char *text)
{
    uint8_t tail;
    size_t length = strlen(text);

    if (echo_count == ECHO_QUEUE_COUNT || length >= ECHO_TEXT_CAP) {
        return 0u;
    }
    tail = (uint8_t)((echo_head + echo_count) % ECHO_QUEUE_COUNT);
    memcpy(echo_queue[tail], text, length + 1u);
    ++echo_count;
    echo_activity = 1u;
    return 1u;
}

static uint8_t echo_ack_token(const char *text, uint8_t skip)
{
    char reply[12];
    uint8_t out = 4u;

    memcpy(reply, "ACK ", 4u);
    text += skip;
    while (*text != '\0' && *text != ' ' && out + 1u < sizeof(reply)) {
        reply[out++] = *text++;
    }
    reply[out] = '\0';
    return echo_enqueue(reply);
}

static void echo_reset(void)
{
    echo_head = 0u;
    echo_count = 0u;
    echo_hello_sent = 0u;
    echo_activity = 0u;
}

void spectrum_net_start_uart(void)
{
    echo_reset();
}

uint8_t spectrum_net_preflight_run(void)
{
    return SPECTRUM_LINK_PREFLIGHT_OK;
}

uint8_t spectrum_net_listen(void)
{
    echo_reset();
    return 1u;
}

uint8_t spectrum_net_connect_host(void)
{
    echo_reset();
    return 1u;
}

uint8_t spectrum_net_wait_pc_connect(void)
{
    return 1u;
}

void spectrum_net_direct_peer_mark_valid(void)
{
}

int16_t spectrum_net_read_payload(char *payload, uint8_t payload_cap)
{
    size_t length;

    if (echo_count == 0u) {
        return SPECTRUM_LINK_READ_TIMEOUT;
    }
    length = strlen(echo_queue[echo_head]);
    if (payload_cap == 0u || length >= payload_cap) {
        return -1;
    }
    memcpy(payload, echo_queue[echo_head], length + 1u);
    echo_head = (uint8_t)((echo_head + 1u) % ECHO_QUEUE_COUNT);
    --echo_count;
    return (int16_t)length;
}

uint8_t spectrum_net_send_text(const char *text) NETCHESSZX_FASTCALL
{
    echo_activity = 1u;
    if (echo_starts_with(text, "HELLO DIRECT HOST ")) {
        if (!echo_hello_sent) {
            echo_hello_sent = 1u;
            return echo_enqueue("HELLO DIRECT GUEST");
        }
        return 1u;
    }
    if (echo_starts_with(text, "GAME START")) {
        return echo_enqueue("ACK GAME START");
    }
    if (echo_starts_with(text, "MOVE ")) {
        return echo_ack_token(text, 5u);
    }
    if (echo_starts_with(text, "TAKEBACK ")) {
        return echo_ack_token(text, 9u);
    }
    if (strcmp(text, "RESET") == 0) {
        return echo_enqueue("ACK RESET");
    }
    if (strcmp(text, "DRAW") == 0) {
        return echo_enqueue("ACK DRAW");
    }
    if (strcmp(text, "RESIGN") == 0) {
        return echo_enqueue("ACK RESIGN");
    }
    if (strcmp(text, "PING") == 0) {
        return echo_enqueue("ACK PING");
    }
    if (strcmp(text, "RQ") == 0) {
        return echo_enqueue("RY");
    }
    if (echo_starts_with(text, "RS01")) {
        return echo_enqueue("RA");
    }
    return 1u;
}

uint8_t spectrum_net_send_ping(void)
{
    return spectrum_net_send_text("PING");
}

char *spectrum_net_payload_scratch(void)
{
    return echo_scratch;
}

uint8_t spectrum_net_link_activity(void)
{
    uint8_t active = echo_activity;
    echo_activity = 0u;
    return active;
}

uint8_t spectrum_net_payload_flags(void)
{
    return 0u;
}

void spectrum_net_background_drain(void)
{
}

void spectrum_uart_background_pump(void)
{
}

const char *spectrum_net_last_ip(void)
{
    return "LOCAL HOT-SEAT";
}

uint8_t spectrum_net_sync_time(void)
{
    return 0u;
}

uint8_t spectrum_net_mqtt_start(void) { return 0u; }
uint8_t spectrum_net_mqtt_activate_side(void) { return 0u; }
uint8_t spectrum_net_mqtt_probe_seat(void) { return 0u; }
uint8_t spectrum_net_mqtt_publish_presence(void) { return 0u; }
uint8_t spectrum_net_mqtt_publish_offline(uint8_t route) NETCHESSZX_FASTCALL
{
    (void)route;
    return 0u;
}
uint8_t spectrum_net_mqtt_publish_setup(uint8_t mode) NETCHESSZX_FASTCALL
{
    (void)mode;
    return 0u;
}
