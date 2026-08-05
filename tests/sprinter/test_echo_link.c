#include <assert.h>
#include <stdint.h>
#include <string.h>

#include "spectrum/transport/link.h"

static void expect_payload(const char *expected)
{
    char payload[SPECTRUM_LINK_PAYLOAD_MAX + 1u];
    int16_t length = spectrum_link_read_payload(payload, sizeof(payload));

    assert(length == (int16_t)strlen(expected));
    assert(strcmp(payload, expected) == 0);
}

int main(void)
{
    spectrum_link_start_uart();
    assert(spectrum_link_preflight_run() == SPECTRUM_LINK_PREFLIGHT_OK);
    assert(spectrum_link_listen());
    assert(spectrum_link_wait_pc_connect());

    assert(spectrum_link_send_text("HELLO DIRECT HOST WHITE=HOST"));
    expect_payload("HELLO DIRECT GUEST");
    assert(spectrum_link_send_text("GAME START WHITE=HOST"));
    expect_payload("ACK GAME START");

    assert(spectrum_link_send_text("MOVE 1 e2e4"));
    expect_payload("ACK 1");
    assert(spectrum_link_send_text("MOVE 2 e7e5"));
    expect_payload("ACK 2");
    assert(spectrum_link_send_text("TAKEBACK 2"));
    expect_payload("ACK 2");
    assert(spectrum_link_send_text("RESET"));
    expect_payload("ACK RESET");
    assert(spectrum_link_send_text("DRAW"));
    expect_payload("ACK DRAW");
    assert(spectrum_link_send_text("RESIGN"));
    expect_payload("ACK RESIGN");
    assert(spectrum_link_send_text("PING"));
    expect_payload("ACK PING");
    assert(spectrum_link_send_text("RQ"));
    expect_payload("RY");
    assert(spectrum_link_send_text("RS00 ABC"));
    assert(spectrum_link_send_text("RS01 DEF"));
    expect_payload("RA");
    return 0;
}
