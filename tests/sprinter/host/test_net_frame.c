/* Host-side transcript tests for src/sprinter/transport/net_frame.c's
 * portable DIRECT line-framing core (S7 step 2, port.md section 3.7).
 * Same .c, same behaviour as the WIN2 C-blob the Sprinter target links --
 * no target-only header, so a gcc build here is a real behavioural proof,
 * not just a compile check. */
#include "sprinter/transport/net_frame.h"

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

    if (failures != 0) {
        printf("net_frame tests failed: %d\n", failures);
        return 1;
    }
    printf("net_frame tests ok\n");
    return 0;
}
