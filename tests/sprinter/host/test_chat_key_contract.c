/* Pins the contract between chat_key_ovl's return codes
 * (src/sprinter/chat_sprinter.h) and what main.c's frame loop does with
 * them: which codes keep the chat input line open and the keyboard routed
 * to it, and which mean the line is already closed.
 *
 * WHY THIS EXISTS. The rule used to be open-coded at the call site as
 * "every outcome except BLOCKED closes the line". That silently swallowed
 * CHAT_SPRINTER_KEY_OPEN -- the code every ordinary typed character
 * returns -- because OPEN is the one outcome with no arm of its own in
 * main.c's ladder (its whole meaning is "do nothing"). Result, found in
 * MAME 2026-08-18: typing "Hello" into chat showed "H" and then dropped
 * out of chat mode, so the remaining characters reached the board hotkeys
 * and a "d"/"r"/"t" raised a draw offer / resign / takeback prompt instead
 * of being typed. The fix moved the rule into a named predicate next to
 * the codes themselves; this test is what stops the next refactor of that
 * predicate from quietly changing its meaning again.
 *
 * The predicate is a macro over plain integer constants, so this is a real
 * proof of the shipped decision -- main.c compiles the very same macro. */
#include "sprinter/chat_sprinter.h"

#include <stdio.h>

static int failures;

static void check(int ok, const char *label)
{
    if (!ok) {
        printf("FAIL: %s\n", label);
        ++failures;
    }
}

static void check_keeps_open(unsigned rc, int expected, const char *label)
{
    int actual = CHAT_SPRINTER_KEY_KEEPS_LINE_OPEN(rc) ? 1 : 0;
    char msg[96];

    snprintf(msg, sizeof(msg), "%s (code %u)", label, rc);
    check(actual == expected, msg);
}

/* The two codes that leave the line open and the keyboard routed to it. */
static void test_codes_that_keep_the_line_open(void)
{
    /* An ordinary character, a backspace, a history step -- the regression
       that shipped: this MUST keep the line open. */
    check_keeps_open(CHAT_SPRINTER_KEY_OPEN, 1, "OPEN keeps the line open");
    /* Submit refused while a MOVE/RESTORE is pending: the typed text stays
       on screen so it can be re-sent once the ACK lands. */
    check_keeps_open(CHAT_SPRINTER_KEY_BLOCKED, 1, "BLOCKED keeps the line open");
}

/* Everything else means the overlay already closed the line. */
static void test_codes_that_close_the_line(void)
{
    check_keeps_open(CHAT_SPRINTER_KEY_CLOSED, 0, "CLOSED closes the line");
    check_keeps_open(CHAT_SPRINTER_KEY_LINK_DOWN, 0, "LINK_DOWN closes the line");
    check_keeps_open(CHAT_SPRINTER_KEY_CMD_DRAW, 0, "CMD_DRAW closes the line");
    check_keeps_open(CHAT_SPRINTER_KEY_CMD_RESIGN, 0, "CMD_RESIGN closes the line");
    check_keeps_open(CHAT_SPRINTER_KEY_CMD_TAKEBACK, 0, "CMD_TAKEBACK closes the line");
}

/* The predicate is a RANGE test (`rc < CLOSED`), which is what keeps it to
   a single comparison and inside WIN1's byte budget -- so the ordering it
   reads is part of the contract, not an implementation detail. Pin it
   directly: both stay-open codes below CLOSED, every closing code at or
   above it. A code inserted on the wrong side of that line would flip its
   meaning with no other symptom. */
static void test_stay_open_codes_sort_below_every_closing_code(void)
{
    check(CHAT_SPRINTER_KEY_OPEN < CHAT_SPRINTER_KEY_CLOSED,
          "OPEN sorts below CLOSED");
    check(CHAT_SPRINTER_KEY_BLOCKED < CHAT_SPRINTER_KEY_CLOSED,
          "BLOCKED sorts below CLOSED");
    check(CHAT_SPRINTER_KEY_LINK_DOWN >= CHAT_SPRINTER_KEY_CLOSED,
          "LINK_DOWN sorts at or above CLOSED");
    check(CHAT_SPRINTER_KEY_CMD_DRAW >= CHAT_SPRINTER_KEY_CLOSED,
          "CMD_DRAW sorts at or above CLOSED");
    check(CHAT_SPRINTER_KEY_CMD_RESIGN >= CHAT_SPRINTER_KEY_CLOSED,
          "CMD_RESIGN sorts at or above CLOSED");
    check(CHAT_SPRINTER_KEY_CMD_TAKEBACK >= CHAT_SPRINTER_KEY_CLOSED,
          "CMD_TAKEBACK sorts at or above CLOSED");
}

/* main.c's ladder ends with `rc >= CHAT_SPRINTER_KEY_CMD_DRAW` and indexes
   "drt"[rc - CMD_DRAW] to turn the code back into its hotkey letter. Both
   depend on the three CMD_* codes staying contiguous, in this order, and
   staying the highest codes there are -- pin that here rather than leaving
   it to a comment. */
static void test_cmd_codes_stay_contiguous_and_highest(void)
{
    check(CHAT_SPRINTER_KEY_CMD_RESIGN == CHAT_SPRINTER_KEY_CMD_DRAW + 1u,
          "CMD_RESIGN follows CMD_DRAW");
    check(CHAT_SPRINTER_KEY_CMD_TAKEBACK == CHAT_SPRINTER_KEY_CMD_DRAW + 2u,
          "CMD_TAKEBACK follows CMD_RESIGN");
    check(CHAT_SPRINTER_KEY_OPEN < CHAT_SPRINTER_KEY_CMD_DRAW,
          "OPEN below the CMD_* block");
    check(CHAT_SPRINTER_KEY_CLOSED < CHAT_SPRINTER_KEY_CMD_DRAW,
          "CLOSED below the CMD_* block");
    check(CHAT_SPRINTER_KEY_LINK_DOWN < CHAT_SPRINTER_KEY_CMD_DRAW,
          "LINK_DOWN below the CMD_* block");
    check(CHAT_SPRINTER_KEY_BLOCKED < CHAT_SPRINTER_KEY_CMD_DRAW,
          "BLOCKED below the CMD_* block");
}

/* Distinct values: two codes colliding would make the ladder above act on
   the wrong outcome, with no compiler complaint. */
static void test_codes_are_distinct(void)
{
    static const unsigned codes[7] = {
        CHAT_SPRINTER_KEY_OPEN, CHAT_SPRINTER_KEY_CLOSED,
        CHAT_SPRINTER_KEY_LINK_DOWN, CHAT_SPRINTER_KEY_BLOCKED,
        CHAT_SPRINTER_KEY_CMD_DRAW, CHAT_SPRINTER_KEY_CMD_RESIGN,
        CHAT_SPRINTER_KEY_CMD_TAKEBACK
    };
    unsigned i, j;

    for (i = 0u; i < 7u; ++i) {
        for (j = i + 1u; j < 7u; ++j) {
            char msg[64];

            snprintf(msg, sizeof(msg), "codes %u and %u are distinct", i, j);
            check(codes[i] != codes[j], msg);
        }
    }
}

int main(void)
{
    test_codes_that_keep_the_line_open();
    test_codes_that_close_the_line();
    test_stay_open_codes_sort_below_every_closing_code();
    test_cmd_codes_stay_contiguous_and_highest();
    test_codes_are_distinct();

    if (failures != 0) {
        printf("chat key contract tests failed: %d\n", failures);
        return 1;
    }
    printf("chat key contract tests ok\n");
    return 0;
}
