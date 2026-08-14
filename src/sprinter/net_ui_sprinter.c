/*
 * NETWORK screen (S7 step 5's DIRECT-only join panel; S8 step 8e turns it
 * into the transport/role switcher + broker/port/room editor the plan
 * calls for). Lives on the NET overlay's own WIN3 page (S8 step 8b -- see
 * that step's own header for why it moved off the WIN3 cold page).
 *
 * It IS the Sprinter implementation of ZX/Next's NET_CONNECT overlay id
 * (src/spectrum/overlay/overlay.h, SPECTRUM_OVL_NET_CONNECT=3) -- entry
 * SPECTRUM_OVL_NET_CONNECT_SCREEN, a Sprinter-only addition to that id's
 * entry set (ZX/Next have no screen of their own on this id; SETUP, id 8,
 * owns that role there -- S9 scope on this port). Reached from WIN1
 * through unet_link.c's spectrum_net_join_ui() wrapper, the same shape
 * restore.c/saveload.c/fileui.c already use for their own overlays.
 *
 * WHY IT DRAWS WITH THE FILEUI PRIMITIVES: spectrum_render_fileui_frame()
 * and spectrum_render_ikkle_at() (render_core_cold.asm) are already
 * exactly "framed panel over the board area, N rows of text" -- the same
 * shape this screen needs, already MAME-proven in S6. They live on the
 * OTHER WIN3 page (the cold page, not this overlay's own page 2), so these
 * are cross-page calls resolved through the usual tools/gen_sprinter_
 * overlay_defs.py OVERLAY_RESIDENT_SYMBOLS bridge (via the WIN1 cold-thunk
 * stubs), the same bridge FILEUI's own fileui_ovl.c already uses.
 *
 * FOCUS INDICATION: the S8 plan named spectrum_render_fileui_select() for
 * this, but that routine's own contract (fileui_ovl.c's only caller,
 * render_core_cold.asm) is "outline one slot of FILEUI's own fixed file
 * grid" -- not a general "outline row R" primitive, and there is no such
 * primitive on this port. Reusing it here would draw FILEUI's rectangle
 * at FILEUI's position, not this screen's -- a real, silent-until-tested
 * defect the CLAUDE.md "verify plan claims against source" discipline
 * exists to catch before it reaches MAME. Focus is shown instead by a
 * leading "> "/"  " column this screen already fully controls (net_ui_row
 * builds the whole line every repaint anyway, so this costs nothing extra)
 * plus a trailing "_" caret appended to the focused editable field's own
 * text -- exactly the port.md "no per-character caret" constraint the plan
 * itself called out (proportional font, no text_width, spectrum_render_
 * input_cell is a stub), just without the unusable primitive.
 *
 * MODELESS INPUT (S8 plan, avoiding the port's own "invisible modal state
 * reads as broken input" trap): UP/DOWN move the focus row, LEFT/RIGHT
 * toggle a switcher row's value, printable ASCII edits the focused text
 * field, BS deletes, ENTER attempts to connect with the current settings,
 * ESC cancels the whole screen. No sub-mode, no "press ENTER to start
 * editing" -- a focused field is always live.
 */
#include "spectrum/ui/render.h"
#include "spectrum/ui/gui.h"
#include "spectrum/lowram_map.h"
#include "spectrum/config/session.h"
#include "spectrum/transport/link.h"

#include <string.h>

/* net_gate.asm (WIN2, always mapped), bridged by tools/gen_sprinter_
   platform_defs.py -- the same funnel unet_link.c uses. Declared here for
   the same reason that file declares its own: these resolve against the
   generated platform_defs.asm, not a target header. */
extern void ng_up(void);
extern void ng_close(void);
extern void ng_lasterr_fetch(void);
extern void ng_c_connect(void);
extern char *ng_env_nethost(void);
extern char *ng_env_netport(void);
extern unsigned char ng_up_reason;
extern unsigned char ng_backend;
/* ng_env_nethost/ng_env_netport return one of these when DSS did not have
   the variable, which is how this screen can say "(DEFAULT)". */
extern char ng_default_host[];
extern char ng_default_port[];
extern unsigned char ng_v_call_status;
extern unsigned char ng_v_call_cf;
extern char ng_buf_lasterr[];

/* S8 step 8c's generic env resolver -- MQTTHOST/MQTTPORT/MQTTROOM defaults
   for the editor below, the same "ask DSS, fall back to the compiled-in
   default" shape ng_env_nethost/ng_env_netport already use for NETHOST/
   NETPORT, just with the name/dest supplied from WIN1 C instead of being
   one more hardcoded resolver in net_gate.asm (that region has 0 bytes
   free -- see net_gate.asm's own comment on ng_c_env_get). */
extern void ng_c_env_get(void);
extern char *ng_c_env_name;
extern char *ng_c_env_dest;
extern unsigned char ng_c_env_found;

/* src/sprinter/net_mqtt_ui_sprinter.c -- same overlay build (one zcc
   invocation compiles both .c files, then links them together), so this
   is a plain same-image call, no bridge needed. */
extern unsigned char net_mqtt_connect_start_ovl(void);

/* im2_s1.asm's frame tick and keyboard latch (WIN2). key_code is a latch,
   not a per-frame snapshot -- this loop clears it after acting, the same
   read-and-clear contract board_cursor_move uses. */
extern void frame_wait(void);
extern void key_poll(void);
extern unsigned char key_code;

/* net_gate.asm's NG_BACKEND_* (it has no header of its own). */
#define NET_UI_BACKEND_NONE 0u
#define NET_UI_BACKEND_WIFI 1u
#define NET_UI_BACKEND_RTL 2u

/* unet.inc's NERR_OK, needed numerically -- see unet_link.c's own note on
   why these are duplicated rather than shared through a target header. */
#define NET_UI_NERR_OK 0u

/* render_core_cold.asm's FILEUI_ATTR_SAVED / anything-else-is-dim. */
#define NET_UI_ATTR_BRIGHT 0x05u
#define NET_UI_ATTR_DIM 0x06u

/* im2_s1.asm's key_code alphabet (S8 plan's own confirmation): printable
   ASCII passes through verbatim, BS=8, CR=0x0D, ESC=0x8A, arrows are
   0x81 (up) / 0x82 (down) / 0x83 (left) / 0x84 (right). HOME/END do not
   exist on this port -- KEY_HOME/KEY_END branches from ZX's own
   input_edit_ovl.c are not ported. */
#define NET_UI_KEY_UP 0x81u
#define NET_UI_KEY_DOWN 0x82u
#define NET_UI_KEY_LEFT 0x83u
#define NET_UI_KEY_RIGHT 0x84u
#define NET_UI_KEY_BS 8u
#define NET_UI_KEY_CANCEL 0x8au   /* ESC */
#define NET_UI_KEY_ENTER 0x0du

#define NET_UI_ROW_TITLE 5u
#define NET_UI_ROW_TRANSPORT 7u
#define NET_UI_ROW_ROLE 8u
#define NET_UI_ROW_FIELD0 10u     /* DIRECT: HOST; MQTT: BROKER */
#define NET_UI_ROW_FIELD1 11u     /* DIRECT: PORT; MQTT: PORT */
#define NET_UI_ROW_FIELD2 12u     /* MQTT only: ROOM */
#define NET_UI_ROW_BACKEND 14u
#define NET_UI_ROW_STATE 16u
#define NET_UI_ROW_DETAIL 17u
#define NET_UI_ROW_FOOTER 20u
#define NET_UI_COL 2u

/* spectrum_render_ikkle_at's spec: [0]=row, [1]=col, [2]=attr, [3..]=text.
   One shared builder rather than one buffer per row -- every row is
   painted and gone before the next is built. Sized for the longest line
   this screen can produce (a 47-char broker host plus focus/caret marks).

   S8 step 8b: this buffer must NOT be this overlay's own WIN3 BSS (which
   is where a plain `static char[]` would land, now that this file is an
   overlay on its own WIN3 page rather than cold-page code). spectrum_
   render_ikkle_at() is reached through a WIN1 cold-thunk stub that maps
   the COLD page into WIN3 before running -- unmapping THIS overlay's own
   page first. A pointer into this overlay's own BSS would already be
   pointing at whatever the cold page keeps at that same address by the
   time the callee dereferences it, not this screen's text. Instead this
   uses LOWRAM_OVERLAY_SCRATCH (fixed_layout.json, 0xB35F, 160 bytes,
   inside WIN2 0x8000-0xC000, always mapped, reserved exactly for "scratch
   shared only by the currently loaded overlay") -- unused by anything else
   on Sprinter today, so the whole 160 bytes are available here. */
#define NET_UI_TEXT_MAX 56u
#define net_ui_spec ((char *)NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR)

static unsigned char net_ui_append(unsigned char at, const char *text)
{
    while (*text != '\0' && at < (3u + NET_UI_TEXT_MAX - 1u)) {
        net_ui_spec[at] = *text;
        ++at;
        ++text;
    }
    net_ui_spec[at] = '\0';
    return at;
}

static void net_ui_row(unsigned char row, unsigned char attr, const char *text)
{
    net_ui_spec[0] = (char)row;
    net_ui_spec[1] = (char)NET_UI_COL;
    net_ui_spec[2] = (char)attr;
    (void)net_ui_append(3u, text);
    spectrum_render_ikkle_at(net_ui_spec);
}

/* Two-part row, for "HOST: <env>:<env>" -- avoids a second scratch buffer
   just to concatenate. */
static void net_ui_row3(unsigned char row,
                        unsigned char attr,
                        const char *a,
                        const char *b,
                        const char *c)
{
    unsigned char at;

    net_ui_spec[0] = (char)row;
    net_ui_spec[1] = (char)NET_UI_COL;
    net_ui_spec[2] = (char)attr;
    at = net_ui_append(3u, a);
    at = net_ui_append(at, b);
    (void)net_ui_append(at, c);
    spectrum_render_ikkle_at(net_ui_spec);
}

/* Focus-marked row: "> " when focused, "  " otherwise, then label, then
   value, then an optional trailing "_" caret (editable fields only, only
   while focused). See this file's own header for why this replaces the
   plan's original spectrum_render_fileui_select() suggestion. */
static void net_ui_field_row(unsigned char row,
                             unsigned char focused,
                             const char *label,
                             const char *value,
                             unsigned char caret)
{
    unsigned char at;

    net_ui_spec[0] = (char)row;
    net_ui_spec[1] = (char)NET_UI_COL;
    net_ui_spec[2] = (char)(focused ? NET_UI_ATTR_BRIGHT : NET_UI_ATTR_DIM);
    at = net_ui_append(3u, focused ? "> " : "  ");
    at = net_ui_append(at, label);
    at = net_ui_append(at, value);
    if (caret && focused) {
        (void)net_ui_append(at, "_");
    }
    spectrum_render_ikkle_at(net_ui_spec);
}

/* ---------------------------------------------------------------------
 * Editor state (S8 step 8e). Switches: transport (0=DIRECT,1=MQTT), role
 * (0=HOST,1=JOIN -- NETCHESSZX_SESSION_ROLE_* values directly). Fields:
 * broker/port/room, edited in place, copied into the mutable session
 * globals (session.h's own NETCHESSZX_SPRINTER branch) only once ENTER is
 * pressed and validation passes -- so a half-typed value never leaks into
 * a live connect attempt via some other code path reading the globals
 * mid-edit.
 * --------------------------------------------------------------------- */
static uint8_t net_ui_transport;
static uint8_t net_ui_role = NETCHESSZX_SESSION_ROLE_JOIN;
static uint8_t net_ui_focus;
static char net_ui_field_broker[NETCHESSZX_MQTT_HOST_MAX + 1u];
static char net_ui_field_port[6];
static char net_ui_field_room[NETCHESSZX_MQTT_CODE_MAX + 1u];
static uint8_t net_ui_fields_seeded;

/* DSS ENVIRON, falling back to the compiled-in default -- MQTTHOST/
   MQTTPORT/MQTTROOM, the same "env overrides a compiled-in default"
   convention NETHOST/NETPORT already use for DIRECT (S7 step 1). */
static void net_ui_env_default(const char *name, char *dest, uint8_t cap,
                               const char *compiled_default)
{
    uint8_t i;

    ng_c_env_name = (char *)name;
    ng_c_env_dest = dest;
    ng_c_env_get();
    if (ng_c_env_found) {
        return;
    }
    for (i = 0u; i < (uint8_t)(cap - 1u) && compiled_default[i] != '\0'; ++i) {
        dest[i] = compiled_default[i];
    }
    dest[i] = '\0';
}

static void net_ui_seed_fields(void)
{
    if (net_ui_fields_seeded) {
        return;
    }
    net_ui_fields_seeded = 1u;
    net_ui_env_default("MQTTHOST", net_ui_field_broker,
                       sizeof(net_ui_field_broker), netchesszx_mqtt_host);
    net_ui_env_default("MQTTPORT", net_ui_field_port,
                       sizeof(net_ui_field_port), "1883");
    net_ui_env_default("MQTTROOM", net_ui_field_room,
                       sizeof(net_ui_field_room), netchesszx_mqtt_code);
}

/* su_room_char-shaped validators (entry_setup.asm:713-748's own rule set,
   ported to this screen's own three fields): room is A-Z/0-9 with the
   lowercase half folded up; broker is 0-9/a-z/A-Z/./-; port is digits
   only. Returns 0 to reject the character outright (silently dropped,
   same as su_room_char's own convention). */
static char net_ui_filter_room(char c)
{
    if (c >= 'a' && c <= 'z') {
        c = (char)(c - 'a' + 'A');
    }
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
        return c;
    }
    return 0;
}

static char net_ui_filter_broker(char c)
{
    if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') || c == '.' || c == '-') {
        return c;
    }
    return 0;
}

static char net_ui_filter_port(char c)
{
    return (c >= '0' && c <= '9') ? c : 0;
}

static uint8_t net_ui_field_len(const char *field)
{
    uint8_t len = 0u;

    while (field[len] != '\0') {
        ++len;
    }
    return len;
}

/* Applies `key` to `field` (capacity `cap` including the NUL) through
   `filter`. Printable ASCII is filtered and appended if there is room;
   BS removes the last character; anything else is a no-op -- the caller
   only forwards keys already known to be relevant to the focused field. */
static void net_ui_edit_field(char *field, uint8_t cap, char (*filter)(char),
                              unsigned char key)
{
    uint8_t len;

    if (key == NET_UI_KEY_BS) {
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

/* Port range check -- entry_setup.asm's own contract for the DIRECT port
   field, applied here to the MQTT one: non-empty, <=5 digits (net_ui_
   filter_port already keeps it numeric-only), value inside uint16_t. */
static uint8_t net_ui_port_value(const char *field, uint16_t *out)
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
    if (value > 65535u) {
        return 0u;
    }
    *out = (uint16_t)value;
    return 1u;
}

/* ng_up's own NG_UP_ERR_* codes (net_gate.asm). Kept as a switch of short
   literals rather than a table of pointers: the strings live in this page
   either way, and the switch costs less than the table plus its indexing.
   Wording names the stage, because that is what a tester can act on --
   "NO NET ENV" means `SET NET=WIFI` was never run, "DLL LOAD" means the
   .DLL is not next to the .EXE, and so on. */
static const char *net_ui_preflight_reason(unsigned char reason)
{
    switch (reason) {
    case 1u: return "NO NET ENV (SET NET=WIFI|RTL)";
    case 2u: return "DLL LOAD FAILED";
    case 3u: return "DLL IS NOT THE SELECTED BACKEND";
    case 4u: return "uNet ABI MISMATCH";
    case 5u: return "BACKEND HAS NO TCP";
    case 6u: return "SETOPT CANCELKEYS REJECTED";
    case 7u: return "ADAPTER STATUS FAILED";
    case 8u: return "NETINIT FAILED";
    case 9u: return "DLL CALL FAILED";
    default: return "UNKNOWN PREFLIGHT ERROR";
    }
}

static const char *net_ui_backend_name(void)
{
    if (ng_backend == NET_UI_BACKEND_WIFI) {
        return "WIFI (UNETESP.DLL)";
    }
    if (ng_backend == NET_UI_BACKEND_RTL) {
        return "RTL (UNETRTL.DLL)";
    }
    return "-- (SET NET=WIFI OR RTL)";
}

/* LASTERR is the DLL's own tail-of-last-response text. Empty is normal for
   failures that never reached the wire, so say so rather than painting a
   blank row that reads like a rendering bug. */
static void net_ui_show_lasterr(void)
{
    ng_lasterr_fetch();
    net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM,
               ng_buf_lasterr[0] != '\0' ? ng_buf_lasterr : "(no adapter detail)");
}

static uint8_t net_ui_max_focus(void)
{
    return net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? 4u : 1u;
}

/* Repaints exactly one focus row (TRANSPORT/ROLE/one MQTT field), not the
   whole screen. net_ui_frame() calls spectrum_render_fileui_frame() (redraws
   the whole panel border) plus every row -- fine once per screen entry or
   layout change, but MAME testing showed it visibly lagging when called on
   every single keystroke while typing BROKER/ROOM (2026-08-14 finding). The
   high-frequency inputs (UP/DOWN, ROLE toggle, one character typed/deleted)
   only ever change ONE row's text/attr/caret, so they repaint just that row
   through this helper instead. net_ui_frame() itself is still used whenever
   the row SET changes -- TRANSPORT toggle adds/removes the three MQTT field
   rows and changes what the backend row means. */
static void net_ui_paint_focus_row(uint8_t idx, uint8_t focused)
{
    if (idx == 0u) {
        char transport_text[16];

        strcpy(transport_text,
              net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? "< MQTT >" : "< DIRECT >");
        net_ui_field_row(NET_UI_ROW_TRANSPORT, focused, "TRANSPORT: ", transport_text, 0u);
    } else if (idx == 1u) {
        char role_text[16];

        strcpy(role_text,
              net_ui_role == NETCHESSZX_SESSION_ROLE_HOST ? "< HOST >" : "< JOIN >");
        net_ui_field_row(NET_UI_ROW_ROLE, focused, "ROLE: ", role_text, 0u);
    } else if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT) {
        if (idx == 2u) {
            net_ui_field_row(NET_UI_ROW_FIELD0, focused, "BROKER: ", net_ui_field_broker, 1u);
        } else if (idx == 3u) {
            net_ui_field_row(NET_UI_ROW_FIELD1, focused, "PORT: ", net_ui_field_port, 1u);
        } else if (idx == 4u) {
            net_ui_field_row(NET_UI_ROW_FIELD2, focused, "ROOM: ", net_ui_field_room, 1u);
        }
    }
}

/* Full repaint: title, the two switcher rows, the three-or-two field rows
   (DIRECT shows read-only env host/port, matching S7's own screen;
   MQTT shows the editable broker/port/room), and the backend line. */
static void net_ui_frame(void)
{
    char role_text[16];
    char transport_text[16];

    spectrum_render_fileui_frame();
    net_ui_row(NET_UI_ROW_TITLE, NET_UI_ATTR_BRIGHT, "NETWORK SETUP");

    strcpy(transport_text,
          net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? "< MQTT >" : "< DIRECT >");
    net_ui_field_row(NET_UI_ROW_TRANSPORT, net_ui_focus == 0u,
                     "TRANSPORT: ", transport_text, 0u);

    strcpy(role_text,
          net_ui_role == NETCHESSZX_SESSION_ROLE_HOST ? "< HOST >" : "< JOIN >");
    net_ui_field_row(NET_UI_ROW_ROLE, net_ui_focus == 1u,
                     "ROLE: ", role_text, 0u);

    if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT) {
        net_ui_seed_fields();
        net_ui_field_row(NET_UI_ROW_FIELD0, net_ui_focus == 2u,
                         "BROKER: ", net_ui_field_broker, 1u);
        net_ui_field_row(NET_UI_ROW_FIELD1, net_ui_focus == 3u,
                         "PORT: ", net_ui_field_port, 1u);
        net_ui_field_row(NET_UI_ROW_FIELD2, net_ui_focus == 4u,
                         "ROOM: ", net_ui_field_room, 1u);
        /* Same backend line DIRECT shows -- ng_backend is set by ng_up(),
           which the MQTT connect flow also calls (net_mqtt_ui_sprinter.c's
           net_mqtt_connect_start_ovl). Leaving this blank was the source of
           a 2026-08-14 MAME finding: "unclear whether the backend is loaded
           and which one" after a failed connect attempt. */
        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
    } else {
        const char *value;

        value = ng_env_nethost();
        net_ui_row3(NET_UI_ROW_FIELD0, NET_UI_ATTR_DIM, "  HOST ", value,
                    value == ng_default_host ? "  (DEFAULT)" : "");
        value = ng_env_netport();
        net_ui_row3(NET_UI_ROW_FIELD1, NET_UI_ATTR_DIM, "  PORT ", value,
                    value == ng_default_port ? "  (DEFAULT)" : "");
        net_ui_row(NET_UI_ROW_FIELD2, NET_UI_ATTR_DIM, "");
        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
    }
}

/* Paint, then let one frame actually reach the screen. Every painter here
   is single-pass into back_base (render_core_cold.asm's own convention),
   so without the flip a "WORKING" line would still be invisible when
   ng_up()/the CONNACK wait blocks for a while. */
static void net_ui_state(const char *text)
{
    net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, text);
    frame_wait();
    frame_wait();
}

/* ENTER retries, ESC gives up. Anything else is ignored rather than
   treated as "either", so a stray keypress cannot silently drop a session
   attempt. */
static unsigned char net_ui_wait_retry(void)
{
    net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "ENTER = RETRY    ESC = CANCEL");
    key_code = 0u;
    for (;;) {
        frame_wait();
        key_poll();
        if (key_code == NET_UI_KEY_ENTER) {
            key_code = 0u;
            return 1u;
        }
        if (key_code == NET_UI_KEY_CANCEL) {
            key_code = 0u;
            return 0u;
        }
        key_code = 0u;
    }
}

/* DIRECT connect attempt -- unchanged from S7/step 8b's own flow, just
   renamed (it used to be the whole overlay entry; now it is the DIRECT
   branch net_join_ui_ovl's ENTER handling dispatches to). */
static unsigned char net_ui_direct_connect(void)
{
    for (;;) {
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM, "");
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "ESC CANCELS AT ANY STAGE");
        net_ui_state("PREFLIGHT: LOADING BACKEND...");

        ng_up();
        /* ng_backend is only known after ng_up has read the NET env, so
           the backend row is repainted here rather than only in
           net_ui_frame(). */
        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());

        if (ng_up_reason != 0u) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "PREFLIGHT FAILED");
            net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM,
                       net_ui_preflight_reason(ng_up_reason));
            if (net_ui_wait_retry()) {
                continue;
            }
            return 0u;
        }

        net_ui_state("CONNECTING...");
        ng_c_connect();
        if (ng_v_call_cf || ng_v_call_status != NET_UI_NERR_OK) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "CONNECT FAILED");
            net_ui_show_lasterr();
            /* Leave the backend up but the channel shut, so a retry is a
               fresh CONNECT rather than a second library load. */
            ng_close();
            if (net_ui_wait_retry()) {
                continue;
            }
            return 0u;
        }

        net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "CONNECTED");
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM, "STARTING SESSION...");
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "");
        frame_wait();
        frame_wait();
        return 1u;
    }
}

/* MQTT connect attempt -- net_mqtt_connect_start_ovl() (net_mqtt_ui_
   sprinter.c) does the whole open_session/CONNECT/subscribe/activate
   sequence in one call; this wrapper only paints the "working"/result
   state around it, the same shape net_ui_direct_connect() uses for its
   own multi-stage flow. */
static unsigned char net_ui_mqtt_connect(void)
{
    for (;;) {
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM, "");
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "ESC CANCELS AT ANY STAGE");
        net_ui_state("CONNECTING TO BROKER...");

        if (!net_mqtt_connect_start_ovl()) {
            /* net_mqtt_connect_start_ovl() calls ng_up() first (net_mqtt_ui_
               sprinter.c) -- ng_up_reason tells apart "backend never loaded"
               (env/DLL/ABI problem, nothing about broker/port/room to check)
               from "backend loaded fine, MQTT CONNECT/CONNACK itself
               failed". Reporting both as a flat "CONNECT FAILED / CHECK
               BROKER/PORT/ROOM" was a 2026-08-14 MAME finding -- a broker
               address that matched the Qt peer's own still failed with no
               way to tell whether the backend had even loaded. */
            net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT,
                      ng_up_reason != 0u ? "PREFLIGHT FAILED" : "CONNECT FAILED");
            net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM,
                      ng_up_reason != 0u ? net_ui_preflight_reason(ng_up_reason)
                                          : "CHECK BROKER/PORT/ROOM");
            if (net_ui_wait_retry()) {
                continue;
            }
            return 0u;
        }

        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
        net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "CONNECTED");
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM, "STARTING SESSION...");
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "");
        frame_wait();
        frame_wait();
        return 1u;
    }
}

/* ENTER handling: validate the MQTT fields (DIRECT has none of its own --
   its host/port come from NETHOST/NETPORT, unchanged since S7), commit
   them into the mutable session globals, configure the session, and
   dispatch the chosen transport's own connect flow.

   Session-configure order is deliberate, not incidental -- this is S7's
   own trap in MQTT clothing (S8 step 8d's plan section has the full
   post-mortem): netchesszx_session_configure() ALWAYS sets host_color_
   ready = 1u (config/session.c:46), which for a JOIN means "colours are
   already settled" and makes the connect flow claim a seat by a guessed
   colour instead of activating once the peer's own HELLO/H arrives. The
   explicit `= 0u` right after is what turns the guess back into a
   decision -- session_sprinter.c's own DIRECT flow already depends on
   this same fix (2026-08-13 MAME finding). */
static unsigned char net_ui_try_connect(void)
{
    if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT) {
        uint16_t port_value;

        if (net_ui_field_len(net_ui_field_room) == 0u) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "ROOM REQUIRED");
            (void)net_ui_wait_retry();
            return 0u;
        }
        if (net_ui_field_len(net_ui_field_broker) == 0u) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "BROKER REQUIRED");
            (void)net_ui_wait_retry();
            return 0u;
        }
        if (!net_ui_port_value(net_ui_field_port, &port_value)) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "BAD PORT");
            (void)net_ui_wait_retry();
            return 0u;
        }
        strcpy(netchesszx_mqtt_host, net_ui_field_broker);
        netchesszx_mqtt_port = port_value;
        strcpy(netchesszx_mqtt_code, net_ui_field_room);
    }

    netchesszx_session_configure(net_ui_role,
                                 net_ui_transport,
                                 NETCHESSZX_COLOR_WHITE);
    if (net_ui_role == NETCHESSZX_SESSION_ROLE_JOIN) {
        netchesszx_host_color_ready = 0u;
    }

    return net_ui_transport == NETCHESSZX_TRANSPORT_MQTT
        ? net_ui_mqtt_connect()
        : net_ui_direct_connect();
}

/* unsigned char net_join_ui_ovl(void) -- the whole modal flow, NET overlay
   entry SPECTRUM_OVL_NET_CONNECT_SCREEN.
   Returns 1 with a live session (of whichever transport the user picked),
   or 0 on ESC / nothing left to retry.

   Takes no arguments and returns a byte, the same shape ZX's own NET_
   CONNECT entries use (mqtt_connect_ovl.c) -- the loader hands every entry
   a context pointer in DE/HL regardless, this one simply has nothing to
   read from it. */
unsigned char net_join_ui_ovl(void)
{
    net_ui_frame();
    net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM,
              "UP/DN LR EDIT  ENTER CONNECT  ESC CANCEL");
    key_code = 0u;

    for (;;) {
        frame_wait();
        key_poll();
        if (key_code == 0u) {
            continue;
        }

        if (key_code == NET_UI_KEY_CANCEL) {
            key_code = 0u;
            return 0u;
        }
        if (key_code == NET_UI_KEY_ENTER) {
            key_code = 0u;
            if (net_ui_try_connect()) {
                return 1u;
            }
            net_ui_frame();
            net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM,
                      "UP/DN LR EDIT  ENTER CONNECT  ESC CANCEL");
            continue;
        }
        if (key_code == NET_UI_KEY_UP) {
            uint8_t old_focus = net_ui_focus;

            net_ui_focus = net_ui_focus == 0u ? net_ui_max_focus() : (uint8_t)(net_ui_focus - 1u);
            key_code = 0u;
            net_ui_paint_focus_row(old_focus, 0u);
            net_ui_paint_focus_row(net_ui_focus, 1u);
            continue;
        }
        if (key_code == NET_UI_KEY_DOWN) {
            uint8_t old_focus = net_ui_focus;

            net_ui_focus = net_ui_focus == net_ui_max_focus() ? 0u : (uint8_t)(net_ui_focus + 1u);
            key_code = 0u;
            net_ui_paint_focus_row(old_focus, 0u);
            net_ui_paint_focus_row(net_ui_focus, 1u);
            continue;
        }
        if (key_code == NET_UI_KEY_LEFT || key_code == NET_UI_KEY_RIGHT) {
            if (net_ui_focus == 0u) {
                /* TRANSPORT toggle changes which rows exist (MQTT's three
                   fields, the backend row's meaning) -- full repaint. */
                net_ui_transport = net_ui_transport == NETCHESSZX_TRANSPORT_MQTT
                    ? NETCHESSZX_TRANSPORT_DIRECT
                    : NETCHESSZX_TRANSPORT_MQTT;
                if (net_ui_focus > net_ui_max_focus()) {
                    net_ui_focus = net_ui_max_focus();
                }
                key_code = 0u;
                net_ui_frame();
            } else if (net_ui_focus == 1u) {
                /* ROLE toggle only changes its own row's text. */
                net_ui_role = net_ui_role == NETCHESSZX_SESSION_ROLE_HOST
                    ? NETCHESSZX_SESSION_ROLE_JOIN
                    : NETCHESSZX_SESSION_ROLE_HOST;
                key_code = 0u;
                net_ui_paint_focus_row(1u, 1u);
            } else {
                key_code = 0u;
            }
            continue;
        }

        /* Printable ASCII or BS on one of the three MQTT fields -- repaint
           only that field's row (this loop's own hot path: one call per
           keystroke while typing BROKER/PORT/ROOM). */
        if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT) {
            switch (net_ui_focus) {
            case 2u:
                net_ui_edit_field(net_ui_field_broker, sizeof(net_ui_field_broker),
                                  net_ui_filter_broker, key_code);
                net_ui_paint_focus_row(2u, 1u);
                break;
            case 3u:
                net_ui_edit_field(net_ui_field_port, sizeof(net_ui_field_port),
                                  net_ui_filter_port, key_code);
                net_ui_paint_focus_row(3u, 1u);
                break;
            case 4u:
                net_ui_edit_field(net_ui_field_room, sizeof(net_ui_field_room),
                                  net_ui_filter_room, key_code);
                net_ui_paint_focus_row(4u, 1u);
                break;
            default:
                break;
            }
        }
        key_code = 0u;
    }
}
