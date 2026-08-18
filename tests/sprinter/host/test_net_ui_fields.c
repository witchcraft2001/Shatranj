/* Host-side tests for src/sprinter/net_ui_fields.{c,h} -- the field-editing
 * and validation helpers behind the NET overlay's editable rows (S9's
 * NETWORK SETUP pass). No target-only header, so a gcc build here is a
 * real behavioural proof of the same code the Sprinter target links, the
 * same shape tests/sprinter/host/test_net_frame.c already uses for
 * net_frame.c. */
#include "sprinter/net_ui_fields.h"

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

static void check_ipv4_ok(const char *s)
{
    char msg[64];

    snprintf(msg, sizeof(msg), "ipv4 accept: %s", s);
    check(net_ui_ipv4_ok(s) == 1u, msg);
}

static void check_ipv4_bad(const char *s)
{
    char msg[64];

    snprintf(msg, sizeof(msg), "ipv4 reject: %s", s);
    check(net_ui_ipv4_ok(s) == 0u, msg);
}

static void test_ipv4_accepts_valid_addresses(void)
{
    check_ipv4_ok("127.0.0.1");
    check_ipv4_ok("0.0.0.0");
    check_ipv4_ok("255.255.255.255");
}

static void test_ipv4_rejects_malformed_addresses(void)
{
    check_ipv4_bad("");
    check_ipv4_bad("1.2.3");
    check_ipv4_bad("1.2.3.4.5");
    check_ipv4_bad("256.1.1.1");
    check_ipv4_bad("1..2.3");
    check_ipv4_bad(".1.2.3");
    check_ipv4_bad("1.2.3.");
    check_ipv4_bad("1234.1.1.1");
    check_ipv4_bad("1.2.3.4x");
}

static void check_port(const char *s, int expect_ok, uint16_t expect_value)
{
    uint16_t value = 0xFFFFu;
    uint8_t ok = net_ui_port_value(s, &value);
    char msg[64];

    snprintf(msg, sizeof(msg), "port %s: ok flag", s);
    check((ok != 0u) == (expect_ok != 0), msg);
    if (expect_ok) {
        snprintf(msg, sizeof(msg), "port %s: value", s);
        check(value == expect_value, msg);
    }
}

static void test_port_value_range(void)
{
    check_port("5000", 1, 5000u);
    check_port("65535", 1, 65535u);
    check_port("0", 0, 0u);
    check_port("65536", 0, 0u);
    check_port("", 0, 0u);
    check_port("123456", 0, 0u);
}

static void test_edit_field_append_bs_cap_filter(void)
{
    char field[5];

    field[0] = '\0';
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'1');
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'2');
    check(strcmp(field, "12") == 0, "edit_field: append builds up the string");

    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, 8u);
    check(strcmp(field, "1") == 0, "edit_field: backspace removes the last char");

    /* Letters are filtered out by net_ui_filter_port -- silently dropped. */
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'x');
    check(strcmp(field, "1") == 0, "edit_field: filtered character is dropped");

    /* cap=5 means at most 4 chars + NUL; a 5th append must be a no-op. */
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'2');
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'3');
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'4');
    check(strcmp(field, "1234") == 0, "edit_field: fills exactly to capacity");
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, (unsigned char)'5');
    check(strcmp(field, "1234") == 0, "edit_field: append beyond capacity is a no-op");

    /* Backspace on an empty field is a no-op, not underflow. */
    field[0] = '\0';
    net_ui_edit_field(field, sizeof(field), net_ui_filter_port, 8u);
    check(strcmp(field, "") == 0, "edit_field: backspace on empty field is a no-op");
}

static void test_filter_room_upcases_and_rejects(void)
{
    check(net_ui_filter_room('a') == 'A', "filter_room: lowercase folds up");
    check(net_ui_filter_room('Z') == 'Z', "filter_room: uppercase passes");
    check(net_ui_filter_room('7') == '7', "filter_room: digit passes");
    check(net_ui_filter_room('-') == 0, "filter_room: punctuation rejected");
    check(net_ui_filter_room(' ') == 0, "filter_room: space rejected");
}

static void test_filter_ip_keeps_digits_and_dot(void)
{
    check(net_ui_filter_ip('3') == '3', "filter_ip: digit passes");
    check(net_ui_filter_ip('.') == '.', "filter_ip: dot passes");
    check(net_ui_filter_ip('a') == 0, "filter_ip: letter rejected");
    check(net_ui_filter_ip('-') == 0, "filter_ip: dash rejected");
}

static void test_copy_capped_truncates_and_terminates(void)
{
    char dest[4];

    net_ui_copy_capped(dest, sizeof(dest), "ab");
    check(strcmp(dest, "ab") == 0, "copy_capped: short string copied whole");

    net_ui_copy_capped(dest, sizeof(dest), "abcdef");
    check(strcmp(dest, "abc") == 0, "copy_capped: long string truncated to cap-1");

    net_ui_copy_capped(dest, sizeof(dest), "");
    check(strcmp(dest, "") == 0, "copy_capped: empty source yields empty dest");
}

int main(void)
{
    test_ipv4_accepts_valid_addresses();
    test_ipv4_rejects_malformed_addresses();
    test_port_value_range();
    test_edit_field_append_bs_cap_filter();
    test_filter_room_upcases_and_rejects();
    test_filter_ip_keeps_digits_and_dot();
    test_copy_capped_truncates_and_terminates();

    if (failures != 0) {
        printf("net_ui_fields tests failed: %d\n", failures);
        return 1;
    }
    printf("net_ui_fields tests ok\n");
    return 0;
}
