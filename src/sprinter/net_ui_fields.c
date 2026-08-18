/* See net_ui_fields.h for what this pair is and why it is separate from
 * net_ui_sprinter.c. */
#include "net_ui_fields.h"

uint8_t net_ui_field_len(const char *field)
{
    uint8_t len = 0u;

    while (field[len] != '\0') {
        ++len;
    }
    return len;
}

void net_ui_edit_field(char *field, uint8_t cap, char (*filter)(char),
                       unsigned char key)
{
    uint8_t len;

    if (key == 8u) {            /* backspace -- im2_s1.asm's key alphabet */
        len = net_ui_field_len(field);
        if (len != 0u) {
            field[len - 1u] = '\0';
        }
        return;
    }
    if (key < 0x20u || key > 0x7eu) {
        return;
    }
    len = net_ui_field_len(field);
    if (len >= (uint8_t)(cap - 1u)) {
        return;
    }
    {
        char filtered = filter((char)key);

        if (filtered == 0) {
            return;
        }
        field[len] = filtered;
        field[len + 1u] = '\0';
    }
}

uint8_t net_ui_port_value(const char *field, uint16_t *out)
{
    uint32_t value = 0u;
    uint8_t len = net_ui_field_len(field);
    uint8_t i;

    if (len == 0u || len > 5u) {
        return 0u;
    }
    for (i = 0u; i < len; ++i) {
        value = value * 10u + (uint8_t)(field[i] - '0');
    }
    if (value > 65535u || value == 0u) {
        return 0u;
    }
    *out = (uint16_t)value;
    return 1u;
}

char net_ui_filter_room(char c)
{
    if (c >= 'a' && c <= 'z') {
        c = (char)(c - 'a' + 'A');
    }
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
        return c;
    }
    return 0;
}

char net_ui_filter_broker(char c)
{
    if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') || c == '.' || c == '-') {
        return c;
    }
    return 0;
}

/* Spelled out as an if, not `(c >= '0' && c <= '9') ? c : 0` -- sccz80
   miscompiles a ternary whose condition contains && or ||, always taking the
   false branch (2026-08-15; tools/check_sccz80_codegen.py is the gate). */
char net_ui_filter_port(char c)
{
    if (c >= '0' && c <= '9') {
        return c;
    }
    return 0;
}

char net_ui_filter_ip(char c)
{
    if ((c >= '0' && c <= '9') || c == '.') {
        return c;
    }
    return 0;
}

/* Ported from su_validate_ip (entry_setup.asm:1020-1078) -- see this
   function's own header comment for the case-by-case trace this
   reimplementation was checked against. */
uint8_t net_ui_ipv4_ok(const char *s)
{
    uint8_t group = 0u;
    uint8_t i = 0u;

    for (;;) {
        uint8_t digits = 0u;
        uint16_t value = 0u;

        while (s[i] >= '0' && s[i] <= '9') {
            value = (uint16_t)(value * 10u + (uint8_t)(s[i] - '0'));
            ++digits;
            if (digits > 3u || value > 255u) {
                return 0u;
            }
            ++i;
        }
        if (digits == 0u) {
            return 0u;
        }
        if (s[i] == '\0') {
            ++group;
            return group == 4u ? 1u : 0u;
        }
        if (s[i] != '.') {
            return 0u;
        }
        ++group;
        if (group >= 4u) {
            return 0u;
        }
        ++i;
    }
}

void net_ui_copy_capped(char *dest, uint8_t cap, const char *src)
{
    uint8_t i;

    for (i = 0u; i < (uint8_t)(cap - 1u) && src[i] != '\0'; ++i) {
        dest[i] = src[i];
    }
    dest[i] = '\0';
}
