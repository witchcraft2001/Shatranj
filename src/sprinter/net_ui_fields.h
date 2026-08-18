/* Portable field-editing/validation helpers for the NET overlay's editable
 * rows (src/sprinter/net_ui_sprinter.c) -- extracted so they can be proven
 * by a plain host test (tests/sprinter/host/test_net_ui_fields.c) instead
 * of only ever running for the first time inside MAME. No dependency on
 * anything Sprinter-specific: no overlay/render/session headers, just
 * <stdint.h>, so this pair builds unmodified under gcc.
 */
#ifndef NET_UI_FIELDS_H
#define NET_UI_FIELDS_H

#include <stdint.h>

uint8_t net_ui_field_len(const char *field);

/* Applies `key` to `field` (capacity `cap`, including the NUL) through
   `filter`. Printable ASCII is filtered and appended if there is room; a
   backspace (ASCII 8) removes the last character; anything else is a
   no-op -- the caller only forwards keys already known to be relevant to
   the focused field. */
void net_ui_edit_field(char *field, uint8_t cap, char (*filter)(char),
                       unsigned char key);

/* Non-empty, <=5 digits, value inside uint16_t AND non-zero (su_parse_port's
   own rule -- asm/overlay/setup/entry_setup.asm:1080-1116 -- port 0 is not a
   valid TCP port). */
uint8_t net_ui_port_value(const char *field, uint16_t *out);

/* su_room_char-shaped filters (entry_setup.asm:713-748's own rule set):
   room is A-Z/0-9 with the lowercase half folded up; broker is
   0-9/a-z/A-Z/./-; port and IPv4 octets are digits (IPv4 also allows '.').
   Each returns 0 to reject the character outright (silently dropped). */
char net_ui_filter_room(char c);
char net_ui_filter_broker(char c);
char net_ui_filter_port(char c);
char net_ui_filter_ip(char c);

/* Ported from su_validate_ip (entry_setup.asm:1020-1078): exactly 4
   dot-separated groups, each 1-3 digits, each group's value <=255; an
   empty group, a leading/trailing dot, a 5th group, or any trailing
   non-digit/non-dot character is a reject. Returns 1 (ok) or 0 (reject). */
uint8_t net_ui_ipv4_ok(const char *s);

/* Copies at most cap-1 bytes of src into dest and NUL-terminates -- the
   capped counterpart to net_ui_sprinter.c's own net_ui_env_default() copy
   loop (which copies without a limit; that risk is accepted there and not
   repeated here since dest may be a small fixed-size overlay field). */
void net_ui_copy_capped(char *dest, uint8_t cap, const char *src);

#endif
