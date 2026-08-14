/* Host-side transcript tests for src/sprinter/transport/net_frame.c's
 * portable DIRECT line-framing core (S7 step 2, port.md section 3.7) and
 * MQTT byte-stream reassembler (S8 step 7). Same .c, same behaviour as
 * the WIN2 C-blob the Sprinter target links -- no target-only header, so
 * a gcc build here is a real behavioural proof, not just a compile
 * check. mqtt_min.c (the codec S8 step 7 deliberately does NOT link into
 * the Sprinter target build yet, Makefile's own comment on
 * SPRINTER_NET_FRAME_C_SRC) is linked here only, so the round-trip test
 * below still proves the reassembler against the real codec. */
#include "sprinter/transport/net_frame.h"
#include "spectrum/transport/mqtt_min.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *label)
{
    if (!ok) {
        printf("FAIL: %s\n", label);
        ++failures;
    }
}

static void check_line(const char *label, const char *expected)
{
    char out[NC_LINE_MAX];
    int16_t rc = nc_line_pop(out, (uint8_t)sizeof(out));
    char msg[96];

    snprintf(msg, sizeof(msg), "%s: rc", label);
    check(rc == (int16_t)strlen(expected), msg);
    snprintf(msg, sizeof(msg), "%s: text", label);
    check(strcmp(out, expected) == 0, msg);
}

static void feed_str(const char *s)
{
    nc_feed((const uint8_t *)s, (uint8_t)strlen(s));
}

static void test_single_line(void)
{
    nc_init();
    feed_str("HELLO 1\n");
    check(nc_queue_count() == 1u, "single line: queued");
    check_line("single line", "HELLO 1");
    check(nc_queue_count() == 0u, "single line: drained");
    check(nc_line_pop(NULL, 0u) == NC_NO_LINE, "single line: no more data");
}

static void test_split_across_chunks(void)
{
    nc_init();
    feed_str("MOVE e2");
    check(nc_queue_count() == 0u, "split: nothing queued mid-line");
    feed_str("e4\n");
    check(nc_queue_count() == 1u, "split: queued once complete");
    check_line("split across chunks", "MOVE e2e4");

    /* Byte-at-a-time is the extreme case of the same behaviour. */
    nc_init();
    {
        const char *msg = "ACK 7\n";
        size_t i;
        for (i = 0u; i < strlen(msg); ++i) {
            nc_feed((const uint8_t *)&msg[i], 1u);
        }
    }
    check_line("byte-at-a-time split", "ACK 7");
}

static void test_queue_depth_drops_fourth(void)
{
    nc_init();
    feed_str("ONE\nTWO\nTHREE\nFOUR\n");
    check(nc_queue_count() == NC_QUEUE_DEPTH, "queue full: depth capped at 3");
    check_line("queue full: line 1", "ONE");
    check_line("queue full: line 2", "TWO");
    check_line("queue full: line 3", "THREE");
    check(nc_queue_count() == 0u, "queue full: FOUR was dropped, not queued");
    check(nc_line_pop(NULL, 0u) == NC_NO_LINE, "queue full: no residue");

    /* A line that arrives once a slot frees up must queue normally --
     * the drop must not wedge the queue shut. */
    nc_init();
    feed_str("A\nB\nC\n");
    check_line("recovery: drain one", "A");
    feed_str("D\n");
    check(nc_queue_count() == 3u, "recovery: room freed by drain is reused");
    check_line("recovery: order preserved", "B");
    check_line("recovery: order preserved", "C");
    check_line("recovery: order preserved", "D");
}

static void test_oversize_line_dropped_whole(void)
{
    char oversize[NC_LINE_MAX + 8u];
    size_t i;

    nc_init();
    /* NC_LINE_MAX-1 (47) chars is the last size that still fits; one more
     * pushes it over. Build a 60-char run of 'X' so the drop clearly
     * covers everything, not just the overflow tail. */
    for (i = 0u; i < sizeof(oversize) - 2u; ++i) {
        oversize[i] = 'X';
    }
    oversize[sizeof(oversize) - 2u] = '\n';
    oversize[sizeof(oversize) - 1u] = '\0';

    feed_str(oversize);
    check(nc_queue_count() == 0u, "oversize: whole line dropped, nothing queued");

    /* The next, well-formed line must be unaffected. */
    feed_str("FINE\n");
    check_line("oversize: next line intact", "FINE");
}

static void test_cr_and_empty_lines_are_not_events(void)
{
    nc_init();
    feed_str("PING\r\n");
    check_line("\\r stripped", "PING");

    nc_init();
    feed_str("\n");
    check(nc_queue_count() == 0u, "empty line: no event");
    feed_str("\r\n");
    check(nc_queue_count() == 0u, "empty line via bare \\r\\n: no event");
    feed_str("STILL OK\n");
    check_line("empty lines did not wedge the parser", "STILL OK");
}

static void test_closed_drains_queue_then_link_down(void)
{
    nc_init();
    feed_str("LAST\n");
    /* The tail that arrives with CLOSED: a partial line with no
     * terminating '\n' (link.h: "any DE bytes are valid first", but an
     * unterminated fragment is not a complete line). */
    feed_str("partial-no-newline");
    nc_mark_closed();

    check(nc_queue_count() == 1u, "closed: queue still holds the pre-FIN line");
    check_line("closed: queue drains first", "LAST");
    check(nc_line_pop(NULL, 0u) == NC_LINK_DOWN,
          "closed: LINK_DOWN once the queue is empty");
    check(nc_line_pop(NULL, 0u) == NC_LINK_DOWN,
          "closed: LINK_DOWN is sticky, not one-shot");
}

static void test_rxf_lost_is_fatal_after_drain(void)
{
    nc_init();
    feed_str("BEFORE-LOST\n");
    nc_mark_lost();

    check_line("rxf_lost: queue drains first", "BEFORE-LOST");
    check(nc_line_pop(NULL, 0u) == NC_LINK_DOWN,
          "rxf_lost: LINK_DOWN once drained, same as CLOSED");
}

static void test_init_resets_prior_state(void)
{
    nc_init();
    feed_str("STALE");
    nc_mark_closed();
    nc_init();

    check(nc_queue_count() == 0u, "init: queue cleared");
    /* The in-progress "STALE" fragment and the fatal latch must both be
     * gone -- completing what would have been "STALE\n" after re-init
     * must NOT resurrect the pre-init fragment or report LINK_DOWN. */
    feed_str("FRESH\n");
    check_line("init: no leftover fragment", "FRESH");
}

/* --- MQTT byte-stream reassembler (S8 step 7) --------------------------
 * nc_mqtt_take()'s header-byte allowlist accepts CONNACK (0x20), PUBLISH
 * of any QoS/DUP/RETAIN combination (0x30-0x3f), PUBACK (0x40), SUBACK
 * (0x90), PINGRESP (0xd0) -- everything else is garbage to resync past.
 */

static void check_mqtt_packet(const char *label, int16_t rc,
                               const uint8_t *expected, uint8_t expected_len)
{
    char msg[96];

    snprintf(msg, sizeof(msg), "%s: rc", label);
    check(rc == (int16_t)expected_len, msg);
    if (rc == (int16_t)expected_len) {
        snprintf(msg, sizeof(msg), "%s: bytes", label);
        check(memcmp(nc_mqtt_packet(), expected, expected_len) == 0, msg);
    }
}

static void test_mqtt_packet_across_three_feeds(void)
{
    static const uint8_t packet[] = {0x30, 5, 0x00, 0x01, 't', 'h', 'i'};

    nc_mqtt_reset();
    nc_mqtt_feed(packet, 3u);
    check(nc_mqtt_take() == 0, "mqtt split: incomplete after chunk 1");
    nc_mqtt_feed(packet + 3, 2u);
    check(nc_mqtt_take() == 0, "mqtt split: incomplete after chunk 2");
    nc_mqtt_feed(packet + 5, 2u);
    check_mqtt_packet("mqtt split: complete after chunk 3",
                       nc_mqtt_take(), packet, (uint8_t)sizeof(packet));
    nc_mqtt_consume((uint8_t)sizeof(packet));
    check(nc_mqtt_take() == 0, "mqtt split: nothing left after consume");
}

static void test_mqtt_two_packets_glued_in_one_feed(void)
{
    static const uint8_t packet1[] = {0x40, 2, 0xAA, 0xBB};
    static const uint8_t packet2[] = {0x90, 3, 0x11, 0x22, 0x33};
    uint8_t both[sizeof(packet1) + sizeof(packet2)];

    memcpy(both, packet1, sizeof(packet1));
    memcpy(both + sizeof(packet1), packet2, sizeof(packet2));

    nc_mqtt_reset();
    nc_mqtt_feed(both, (uint8_t)sizeof(both));
    check_mqtt_packet("mqtt glued: first packet",
                       nc_mqtt_take(), packet1, (uint8_t)sizeof(packet1));
    nc_mqtt_consume((uint8_t)sizeof(packet1));
    check_mqtt_packet("mqtt glued: second packet",
                       nc_mqtt_take(), packet2, (uint8_t)sizeof(packet2));
    nc_mqtt_consume((uint8_t)sizeof(packet2));
    check(nc_mqtt_take() == 0, "mqtt glued: nothing left after both consumed");
}

static void test_mqtt_garbage_before_header_resyncs(void)
{
    static const uint8_t garbage[] = {0x01, 0x02, 0x03};
    static const uint8_t packet[] = {0x20, 1, 0x55};
    uint8_t fed[sizeof(garbage) + sizeof(packet)];

    memcpy(fed, garbage, sizeof(garbage));
    memcpy(fed + sizeof(garbage), packet, sizeof(packet));

    nc_mqtt_reset();
    nc_mqtt_feed(fed, (uint8_t)sizeof(fed));
    check_mqtt_packet("mqtt resync: garbage discarded, packet recovered",
                       nc_mqtt_take(), packet, (uint8_t)sizeof(packet));
}

static void test_mqtt_two_byte_varint(void)
{
    /* remaining=150 needs a 2-byte varint: low 7 bits (22=0x16) with the
     * continuation bit set (0x96), then the high bits (1). Filler content
     * is a sequential byte pattern so a truncated/misaligned copy would
     * be caught, not just a wrong length. */
    uint8_t packet[3 + 150];
    uint16_t i;

    packet[0] = 0x30;
    packet[1] = 0x96;
    packet[2] = 0x01;
    for (i = 0u; i < 150u; ++i) {
        packet[3u + i] = (uint8_t)i;
    }

    nc_mqtt_reset();
    nc_mqtt_feed(packet, 53u);
    check(nc_mqtt_take() == 0, "mqtt 2-byte varint: incomplete after header+50");
    nc_mqtt_feed(packet + 53, (uint8_t)(sizeof(packet) - 53u));
    check_mqtt_packet("mqtt 2-byte varint: complete",
                       nc_mqtt_take(), packet, (uint8_t)sizeof(packet));
}

static void test_mqtt_malformed_length_clears_and_recovers(void)
{
    /* A second varint byte greater than 1 cannot happen for any length
     * <= SPECTRUM_MQTT_PACKET_MAX (160) -- mqtt_take_stream_packet()'s own
     * malformed case, not merely "not yet enough data". */
    static const uint8_t malformed[] = {0x30, 0x96, 0x02, 'X', 'X'};
    static const uint8_t recovery[] = {0x40, 1, 0x77};

    nc_mqtt_reset();
    nc_mqtt_feed(malformed, (uint8_t)sizeof(malformed));
    check(nc_mqtt_take() == -1, "mqtt malformed: rejected, not just incomplete");
    check(nc_mqtt_take() == 0,
          "mqtt malformed: stream fully cleared, not stuck rejecting");

    nc_mqtt_feed(recovery, (uint8_t)sizeof(recovery));
    check_mqtt_packet("mqtt malformed: next packet unaffected",
                       nc_mqtt_take(), recovery, (uint8_t)sizeof(recovery));
}

static void test_mqtt_stream_overflow_drops_excess(void)
{
    /* Fill to 1 byte short of NC_MQTT_STREAM_MAX with garbage, then feed
     * a 2-byte header declaring 5 more bytes are coming (total 7) -- the
     * header itself just fits, but the buffer is then completely full.
     * If the 5-byte payload that follows were wrongly accepted instead of
     * dropped, the packet would complete; it must not. */
    static uint8_t filler[NC_MQTT_STREAM_MAX - 2u];
    static const uint8_t header[] = {0x40, 5};
    static const uint8_t payload_attempt[] = {1, 2, 3, 4, 5};
    uint16_t i;

    for (i = 0u; i < sizeof(filler); ++i) {
        filler[i] = 0xAAu;
    }

    nc_mqtt_reset();
    nc_mqtt_feed(filler, (uint8_t)sizeof(filler));
    nc_mqtt_feed(header, (uint8_t)sizeof(header));
    nc_mqtt_feed(payload_attempt, (uint8_t)sizeof(payload_attempt));
    check(nc_mqtt_take() == 0,
          "mqtt overflow: payload past the cap was dropped, packet stays incomplete");
}

static void test_mqtt_lone_header_byte_is_not_discarded(void)
{
    static const uint8_t packet[] = {0x30, 5, 0x00, 0x01, 't', 'h', 'i'};

    nc_mqtt_reset();
    nc_mqtt_feed(packet, 1u);
    check(nc_mqtt_take() == 0,
          "mqtt lone byte: too short to judge, not treated as garbage");
    nc_mqtt_feed(packet + 1, (uint8_t)(sizeof(packet) - 1u));
    check_mqtt_packet("mqtt lone byte: completes once the rest arrives",
                       nc_mqtt_take(), packet, (uint8_t)sizeof(packet));
}

static void test_mqtt_round_trip_with_real_codec(void)
{
    uint8_t built[32];
    uint8_t built_len;
    char payload_out[16];
    uint16_t packet_id_out;
    uint8_t flags_out;
    int16_t payload_len;

    built_len = spectrum_mqtt_publish(built, (uint8_t)sizeof(built), 7u,
                                       "chess", "e2e4", 0u);
    check(built_len != 0u, "mqtt round trip: publish() built a packet");

    nc_mqtt_reset();
    nc_mqtt_feed(built, built_len);
    check_mqtt_packet("mqtt round trip: reassembled bytes match the codec's own",
                       nc_mqtt_take(), built, built_len);

    check(spectrum_mqtt_type(nc_mqtt_packet(), built_len) == SPECTRUM_MQTT_PUBLISH,
          "mqtt round trip: type() sees PUBLISH");
    payload_len = spectrum_mqtt_parse_publish(nc_mqtt_packet(), built_len,
                                              payload_out, (uint8_t)sizeof(payload_out),
                                              &packet_id_out, &flags_out);
    check(payload_len == 4, "mqtt round trip: payload length");
    check(strcmp(payload_out, "e2e4") == 0, "mqtt round trip: payload text");
    check(packet_id_out == 7u, "mqtt round trip: packet id");
}

int main(void)
{
    test_single_line();
    test_split_across_chunks();
    test_queue_depth_drops_fourth();
    test_oversize_line_dropped_whole();
    test_cr_and_empty_lines_are_not_events();
    test_closed_drains_queue_then_link_down();
    test_rxf_lost_is_fatal_after_drain();
    test_init_resets_prior_state();

    test_mqtt_packet_across_three_feeds();
    test_mqtt_two_packets_glued_in_one_feed();
    test_mqtt_garbage_before_header_resyncs();
    test_mqtt_two_byte_varint();
    test_mqtt_malformed_length_clears_and_recovers();
    test_mqtt_stream_overflow_drops_excess();
    test_mqtt_lone_header_byte_is_not_discarded();
    test_mqtt_round_trip_with_real_codec();

    if (failures != 0) {
        printf("net_frame tests failed: %d\n", failures);
        return 1;
    }
    printf("net_frame tests ok\n");
    return 0;
}
