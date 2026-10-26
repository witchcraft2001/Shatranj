/* Sprinter NETWORK editor and Direct listener/handshake, resident in NET. */
#include "spectrum/ui/render.h"
#include "spectrum/ui/gui.h"
#include "spectrum/lowram_map.h"
#include "spectrum/config/session.h"
#include "spectrum/transport/link.h"
#include "spectrum/platform/text.h"
#include "sprinter/net_ui_fields.h"

#include <string.h>
#include "sprinter/direct_host.h"
#include "common/session/session.h"
extern void net_session_begin(void);
#include "common/protocol/direct_session_protocol.h"
#include "sprinter/transport/net_frame.h"
#include "spectrum/session/direct.h"
#include "spectrum/session/event.h"

extern void host_listen(uint16_t port) __z88dk_fastcall;
extern void host_status(void);
extern void host_unlisten(void);
extern void host_rx_pause(void);
extern void host_rx_resume(void);
extern uint16_t ng_caps, ng_v_call_len, ng_v_call_flags;
extern uint8_t ng_v_last_cf, ng_v_last_nerr, ng_start_status;
extern void ng_shutdown(void);
extern void ng_getinfo_ip(void);
extern char ng_buf_ip[];
extern unsigned char net_active;


/* net_gate.asm (WIN2, always mapped), bridged by tools/gen_sprinter_
   platform_defs.py -- the same funnel unet_link.c uses. Declared here for
   the same reason that file declares its own: these resolve against the
   generated platform_defs.asm, not a target header. */
extern void ng_up(void);
extern void ng_close(void);
extern void ng_lasterr_fetch(void);
extern unsigned char ng_up_reason;
extern char ng_dll_name[];
extern unsigned char ng_v_call_status;
extern unsigned char ng_v_call_cf;
extern char ng_buf_lasterr[];

/* ng_c_connect_at (S8 step 8c, reused here since S9's NETWORK SETUP pass):
   connects to a caller-supplied host/port instead of resolving NETHOST/
   NETPORT itself -- exactly the mechanism net_mqtt_ui_sprinter.c already
   uses for its own editable BROKER field. */
extern void ng_c_connect_at(void);
extern char *ng_c_connect_host;
extern char *ng_c_connect_port;

/* S8 step 8c's generic env resolver -- MQTTHOST/MQTTPORT/MQTTROOM defaults
   for the editor below, the same "ask DSS, fall back to the compiled-in
   default" shape used for NETHOST/NETPORT, with the name and destination supplied
   from the NET overlay. */
extern void ng_c_env_get(void);
extern char *ng_c_env_name;
extern char *ng_c_env_dest;
extern unsigned char ng_c_env_capacity;
extern unsigned char ng_c_env_found;

/* src/sprinter/net_mqtt_ui_sprinter.c -- same overlay build (one zcc
   invocation compiles both .c files, then links them together), so this
   is a plain same-image call, no bridge needed. */
extern unsigned char net_mqtt_connect_start_ovl(void);
extern uint16_t net_mqtt_new_session_id(void);
extern unsigned char net_mqtt_fail_step;
extern unsigned char net_mqtt_fail_cf;
extern unsigned char net_mqtt_fail_status;

/* im2_s1.asm's frame tick and keyboard latch (WIN2). key_code is a latch,
   not a per-frame snapshot -- this loop clears it after acting, the same
   read-and-clear contract board_cursor_move uses. */
extern void frame_wait(void);
extern void key_poll(void);
extern unsigned char key_code;
extern unsigned char frame_counter;

/* net_gate.asm's NG_BACKEND_* (it has no header of its own). */

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
#define NET_UI_ROW_DETAIL2 18u
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
#ifdef SPRINTER_HOST_TEST
static char net_ui_spec[160];
#else
#define net_ui_spec ((char *)NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR)
#endif

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
static uint8_t net_ui_color;
static char net_ui_field_broker[NETCHESSZX_MQTT_HOST_MAX + 1u];
static char net_ui_field_port[6];
static char net_ui_field_room[NETCHESSZX_MQTT_CODE_MAX + 1u];
/* DIRECT's own editable HOST/PORT (S9). NOT netchesszx_direct_host/port
   (config/session.c) -- on Sprinter nothing reads those, and giving this
   overlay its own statics avoids the cross-page bridging a resident global
   would need for no benefit (this screen is the only reader/writer of the
   value for the whole run). Sized like session.h's own DIRECT_HOST_MAX
   (IPv4 dotted-quad length), not the MQTT broker's larger hostname cap. */
static char net_ui_field_host[NETCHESSZX_DIRECT_HOST_MAX + 1u];
static char net_ui_field_dport[6];
static uint8_t net_ui_fields_seeded;

/* DSS ENVIRON, falling back to the compiled-in default -- MQTTHOST/
   MQTTPORT/MQTTROOM, the same "env overrides a compiled-in default"
   convention NETHOST/NETPORT already use for DIRECT (S7 step 1). */
static void net_ui_env_default(const char *name, char *dest, uint8_t cap,
                               const char *compiled_default)
{
    ng_c_env_name = (char *)name;
    ng_c_env_dest = dest;
    ng_c_env_capacity = cap;
    ng_c_env_get();
    if (ng_c_env_found) {
        if (ng_c_env_found == 2u) dest[0] = '\0';
        return;
    }
    net_ui_copy_capped(dest, cap, compiled_default);
}

/* Seeds MQTT's broker/port/room from MQTTHOST/MQTTPORT/MQTTROOM (env, then
   a compiled default) and DIRECT's host/port from NETHOST/NETPORT the same
   way. The ASM resolver stages each value in a full 256-byte DSS buffer
   and copies at most cap-1 bytes into the field, with a terminating NUL.
   Runs once
   per session (net_ui_fields_seeded), for BOTH transports on every call --
   so a value typed under one transport survives switching to the other and
   back, and NETHOST/NETPORT become seed-only inputs rather than being
   re-read on every DIRECT connect attempt. */
static void net_ui_seed_fields(void)
{
    if (net_ui_fields_seeded) {
        return;
    }
    net_ui_fields_seeded = 1u;
    direct_host.listening = 0u;
    net_ui_env_default("MQTTHOST", net_ui_field_broker,
                       sizeof(net_ui_field_broker), netchesszx_mqtt_host);
    net_ui_env_default("MQTTPORT", net_ui_field_port,
                       sizeof(net_ui_field_port), "1883");
    net_ui_env_default("MQTTROOM", net_ui_field_room,
                       sizeof(net_ui_field_room), netchesszx_mqtt_code);
    net_ui_env_default("NETHOST", net_ui_field_host,
                       sizeof(net_ui_field_host), "127.0.0.1");
    net_ui_env_default("NETPORT", net_ui_field_dport,
                       sizeof(net_ui_field_dport), NETCHESSZX_STRINGIFY(NETCHESSZX_PORT));
}

/* UNETLD error codes plus ng_up's TCP and NETSTART call codes (net_gate.asm).
   Kept as a switch of short
   literals rather than a table of pointers: the strings live in this page
   either way, and the switch costs less than the table plus its indexing.
   Wording names the stage, because that is what a tester can act on --
   "NO NET ENV" means `SET NET=WIFI` was never run, "DLL LOAD" means the
   .DLL is not next to the .EXE, and so on. */
static const char *net_ui_preflight_reason(unsigned char reason)
{
    switch (reason) {
    case 1u: return "NO NET ENV";
    case 2u: return "INVALID NET VALUE";
    case 3u: return "DLL LOAD FAILED";
    case 4u: return "DLL INFO FAILED";
    case 5u: return "DLL NAME MISMATCH";
    case 6u: return "DLL CALL/GETCAPS FAILED";
    case 7u: return "uNet ABI MISMATCH";
    case 8u: return "ADAPTER STATUS FAILED";
    case 9u: return "NETINIT FAILED";
    case 10u: return "BACKEND HAS NO TCP";
    case 11u: return "NETSTART CALL FAILED";
    default: return "UNKNOWN PREFLIGHT ERROR";
    }
}

static const char *net_ui_backend_name(void)
{
    return ng_dll_name[0] != '\0' ? ng_dll_name : "--";
}

/* LASTERR is the DLL's own diagnostic text. Empty is normal for failures
   that never reached the wire, so say so rather than painting a blank row
   that reads like a rendering bug.

   IT IS SECONDARY INFORMATION, not a report of this attempt, and the row it
   is painted on says so ("ADAPTER:"). The RTL backend formats it live out
   of state that persists across calls (unetrtl.asm's STAGE/LAST_NERR/
   TCP_LAST_FAIL/DIAG_*), and nothing updates it when a call fails before
   the DLL is entered -- net_gate.asm's own argument checks and libman's
   l_call both return without dispatching. A 2026-08-15 MAME round was spent
   reading a previous successful call's line as if it described the failure
   in front of it. net_ui_show_mqtt_failure() below is the authoritative
   report; this stays because when it IS fresh it names the chip-level
   cause, which nothing else here can. Painted without a label prefix on
   purpose: the line already starts with its own "RTL "/"ESP " tag, and
   net_ui_append's NET_UI_TEXT_MAX cap would eat the tail of the fixed
   layout's high-value head fields if anything were put in front of it. */
static void net_ui_show_lasterr(unsigned char row)
{
    ng_lasterr_fetch();
    net_ui_row(row, NET_UI_ATTR_DIM,
               ng_buf_lasterr[0] != '\0' ? ng_buf_lasterr : "(no adapter detail)");
}

/* Keep in step with net_mqtt_ui_sprinter.c's MQTT_FAIL_* codes. */
static const char *net_ui_mqtt_step_name(unsigned char step)
{
    switch (step) {
    case 1u: return "PREFLIGHT";
    case 2u: return "TCP CONNECT";
    case 3u: return "BUILD CONNECT";
    case 4u: return "SEND CONNECT";
    case 5u: return "WAIT CONNACK";
    case 6u: return "CONNACK REJECTED";
    case 7u: return "SEND SUBSCRIBE";
    case 8u: return "WAIT SUBACK";
    case 9u: return "SUBACK REJECTED";
    case 10u: return "PUBLISH PRESENCE";
    default: return "NOT REACHED";
    }
}

/* sccz80 rejects a plain `end - net_ui_spec` here ("Pointer addition ...
   is invalid"): net_ui_spec is a cast-literal macro, not a real char*
   object, so the two operands never become a valid pointer difference.
   Subtracting the two addresses as integers is the same arithmetic and
   compiles on both toolchains. */
static unsigned char net_ui_append_u8(unsigned char at, unsigned char value)
{
    char *end = spectrum_append_u16(&net_ui_spec[at], (uint16_t)value);

    return (unsigned char)((uint16_t)end - (uint16_t)net_ui_spec);
}

/* The authoritative failure report: which step of the connect sequence gave
   up, and net_gate.asm's own per-call outcome (ng_v_call_cf/ng_v_call_status)
   at that moment. Unlike LASTERR above, both are written by ng_c_store_result
   on EVERY C-wrapper call -- including the ones that never reach the DLL --
   so this row cannot show a stale stage from an earlier, unrelated call. */
static void net_ui_show_mqtt_failure(void)
{
    unsigned char at;

    net_ui_spec[0] = (char)NET_UI_ROW_DETAIL;
    net_ui_spec[1] = (char)NET_UI_COL;
    net_ui_spec[2] = (char)NET_UI_ATTR_BRIGHT;
    at = net_ui_append(3u, "STEP ");
    at = net_ui_append_u8(at, net_mqtt_fail_step);
    at = net_ui_append(at, " ");
    at = net_ui_append(at, net_ui_mqtt_step_name(net_mqtt_fail_step));
    at = net_ui_append(at, "  CF=");
    at = net_ui_append_u8(at, net_mqtt_fail_cf);
    at = net_ui_append(at, " ST=");
    (void)net_ui_append_u8(at, net_mqtt_fail_status);
    spectrum_render_ikkle_at(net_ui_spec);
}

static uint8_t net_ui_max_focus(void)
{
    return net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? 4u : 3u;
}

static void net_ui_focus_normalize(signed char dir)
{
    (void)dir;
    if (net_ui_focus > net_ui_max_focus()) net_ui_focus = net_ui_max_focus();
}

/* Resolves which text field (if any) net_ui_focus currently names, for
   whichever transport is active -- the one place that maps a focus index
   to a field/capacity/filter triple, so the keystroke handler in
   net_join_ui_ovl() does not need a second copy of this per transport.
   Returns 0 (fields untouched) for TRANSPORT/ROLE or an index the current
   transport has no field at (MQTT's ROOM index under DIRECT). */
static uint8_t net_ui_focused_field(char **field, uint8_t *cap, char (**filter)(char))
{
    if (net_ui_transport == NETCHESSZX_TRANSPORT_DIRECT) {
        if (net_ui_focus == 2u && net_ui_role == NETCHESSZX_SESSION_ROLE_JOIN) {
            *field = net_ui_field_host;
            *cap = (uint8_t)sizeof(net_ui_field_host);
            *filter = net_ui_filter_ip;
            return 1u;
        }
        if (net_ui_focus == 3u) {
            *field = net_ui_field_dport;
            *cap = (uint8_t)sizeof(net_ui_field_dport);
            *filter = net_ui_filter_port;
            return 1u;
        }
        return 0u;
    }
    if (net_ui_focus == 2u) {
        *field = net_ui_field_broker;
        *cap = (uint8_t)sizeof(net_ui_field_broker);
        *filter = net_ui_filter_broker;
        return 1u;
    }
    if (net_ui_focus == 3u) {
        *field = net_ui_field_port;
        *cap = (uint8_t)sizeof(net_ui_field_port);
        *filter = net_ui_filter_port;
        return 1u;
    }
    if (net_ui_focus == 4u) {
        *field = net_ui_field_room;
        *cap = (uint8_t)sizeof(net_ui_field_room);
        *filter = net_ui_filter_room;
        return 1u;
    }
    return 0u;
}

/* Repaints exactly one focus row (TRANSPORT/ROLE/one field), not the whole
   screen. net_ui_frame() calls spectrum_render_fileui_frame() (redraws the
   whole panel border) plus every row -- fine once per screen entry or
   layout change, but MAME testing showed it visibly lagging when called on
   every single keystroke while typing BROKER/ROOM (2026-08-14 finding). The
   high-frequency inputs (UP/DOWN, ROLE toggle, one character typed/deleted)
   only ever change ONE row's text/attr/caret, so they repaint just that row
   through this helper instead. net_ui_frame() itself is still used whenever
   the row SET changes -- TRANSPORT toggle adds/removes/relabels rows and
   changes what the backend row means. */
static void net_ui_paint_focus_row(uint8_t idx, uint8_t focused)
{
    if (idx == 0u) {
        char transport_text[16];

        strcpy(transport_text,
              net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? "< MQTT >" : "< DIRECT >");
        net_ui_field_row(NET_UI_ROW_TRANSPORT, focused, "TRANSPORT: ", transport_text, 0u);
    } else if (idx == 1u) {
        net_ui_field_row(NET_UI_ROW_ROLE, focused, "ROLE: ",
                         net_ui_role == NETCHESSZX_SESSION_ROLE_HOST ? "< HOST >" : "< JOIN >", 0u);
    } else if (net_ui_transport == NETCHESSZX_TRANSPORT_DIRECT) {
        if (idx == 2u) {
            if (net_ui_role == NETCHESSZX_SESSION_ROLE_HOST) {
                net_ui_field_row(NET_UI_ROW_FIELD0, focused, "COLOR: ",
                                 net_ui_color ? "< BLACK >" : "< WHITE >", 0u);
            } else {
                net_ui_field_row(NET_UI_ROW_FIELD0, focused, "HOST: ", net_ui_field_host, 1u);
            }
        } else if (idx == 3u) {
            net_ui_field_row(NET_UI_ROW_FIELD1, focused, "PORT: ", net_ui_field_dport, 1u);
        }
    } else {
        if (idx == 2u) {
            net_ui_field_row(NET_UI_ROW_FIELD0, focused, "BROKER: ", net_ui_field_broker, 1u);
        } else if (idx == 3u) {
            net_ui_field_row(NET_UI_ROW_FIELD1, focused, "PORT: ", net_ui_field_port, 1u);
        } else if (idx == 4u) {
            net_ui_field_row(NET_UI_ROW_FIELD2, focused, "ROOM: ", net_ui_field_room, 1u);
        }
    }
}

/* Full repaint: title, the two switcher rows, the field rows (DIRECT's own
   HOST/PORT are editable exactly like MQTT's BROKER/PORT/ROOM, S9 --
   net_ui_paint_focus_row is the single source of truth for both), and the
   backend line. */
static void net_ui_frame(void)
{
    char transport_text[16];

    spectrum_render_fileui_frame();
    net_ui_row(NET_UI_ROW_TITLE, NET_UI_ATTR_BRIGHT, "NETWORK SETUP");

    strcpy(transport_text,
          net_ui_transport == NETCHESSZX_TRANSPORT_MQTT ? "< MQTT >" : "< DIRECT >");
    net_ui_field_row(NET_UI_ROW_TRANSPORT, net_ui_focus == 0u,
                     "TRANSPORT: ", transport_text, 0u);

    net_ui_seed_fields();
    net_ui_paint_focus_row(1u, net_ui_focus == 1u);
    net_ui_paint_focus_row(2u, net_ui_focus == 2u);
    net_ui_paint_focus_row(3u, net_ui_focus == 3u);

    if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT) {
        net_ui_paint_focus_row(4u, net_ui_focus == 4u);
        /* Same backend line DIRECT shows -- the DLL name is set by ng_up(),
           which the MQTT connect flow also calls (net_mqtt_ui_sprinter.c's
           net_mqtt_connect_start_ovl). Leaving this blank was the source of
           a 2026-08-14 MAME finding: "unclear whether the backend is loaded
           and which one" after a failed connect attempt. */
        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
    } else {
        /* No fifth row under DIRECT -- blank it out so a ROOM value left
           over from a prior MQTT visit does not linger on screen. */
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

/* DIRECT connect attempt. Dials net_ui_field_host/net_ui_field_dport (S9 --
   both already validated by net_ui_try_connect() before this is reached)
   through ng_c_connect_at(), the same caller-supplied-address mechanism
   net_mqtt_ui_sprinter.c's own connect flow uses for BROKER. The pointers
   are safe to hand across: ng_connect (net_gate.asm) copies both ASCIIZ
   strings into its own WIN2 staging buffers before ever dispatching to the
   DLL, so nothing depends on this overlay's own BSS surviving past the
   call. */
static unsigned char net_ui_direct_connect(void)
{
    for (;;) {
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM, "");
        net_ui_row(NET_UI_ROW_DETAIL2, NET_UI_ATTR_DIM, "");
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "ESC CANCELS AT ANY STAGE");
        net_ui_state("PREFLIGHT: LOADING BACKEND...");

        ng_up();
        /* The DLL name is only known after ng_up has read NET, so
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

        spectrum_link_start_uart();
        net_ui_state("CONNECTING...");
        ng_c_connect_host = net_ui_field_host;
        ng_c_connect_port = net_ui_field_dport;
        ng_c_connect_at();
        if (ng_v_call_cf || ng_v_call_status != NET_UI_NERR_OK) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "CONNECT FAILED");
            net_ui_show_lasterr(NET_UI_ROW_DETAIL);
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

/* Stop listening before CLOSE: CLOSE alone can re-arm a uNet listener. */
unsigned char net_host_close_ovl(void)
{
    if (direct_host.listening) {
        host_unlisten();
        direct_host.listening = 0u;
        if (ng_v_call_cf || ng_v_call_status) {
            ng_shutdown(); /* NETDONE prevents a failed UNLISTEN re-arming on CLOSE. */
            return 0u;
        }
    }
    ng_close();
    return 1u;
}

static void net_ui_host_failure(const char *stage)
{
    unsigned char at;
    uint8_t cf = ng_v_call_cf;
    uint8_t status = ng_v_call_status;
    net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, stage);
    net_ui_spec[0] = NET_UI_ROW_DETAIL;
    net_ui_spec[1] = NET_UI_COL;
    net_ui_spec[2] = NET_UI_ATTR_BRIGHT;
    at = net_ui_append(3u, "CF=");
    at = net_ui_append_u8(at, cf);
    at = net_ui_append(at, " STATUS=");
    (void)net_ui_append_u8(at, status);
    spectrum_render_ikkle_at(net_ui_spec);
}

unsigned char net_host_wait_ovl(void)
{
    for (;;) {
        net_ui_frame();
        net_ui_state("PREFLIGHT: LOADING BACKEND...");
        ng_up();
        net_ui_frame();
        if (ng_up_reason) {
            ng_v_call_cf = 0u;
            ng_v_call_status = ng_start_status;
            net_ui_host_failure(net_ui_preflight_reason(ng_up_reason));
            goto retry;
        }
        if (!(ng_caps & 32u)) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "HOST NEEDS CAP_LISTEN");
            goto retry;
        }
        spectrum_link_start_uart();
        ng_close();
        ng_getinfo_ip();
        net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_BRIGHT, ng_buf_ip);
        net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
        net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM, "ESC CANCEL");
        net_ui_state("WAITING FOR GUEST - ESC CANCEL");
        /* Finish painting before opening the port. A guest can send HELLO
         * immediately; no drawing or frame sleep may delay the first RECV. */
        direct_host.listening = 1u;
        host_listen(direct_host.port);
        if (ng_v_call_cf || ng_v_call_status) {
            net_ui_host_failure("LISTEN FAILED");
            goto cleanup;
        }
        host_rx_resume();
        key_code = 0u;
        for (;;) {
            key_poll();
            if (key_code == NET_UI_KEY_CANCEL) {
                key_code = 0u;
                net_host_close_ovl();
                direct_host.enabled = 0u;
                return 0u;
            }
            key_code = 0u;
            /* RECV drives accept and queues any coalesced HELLO/MOVE. */
            nc_pump();
            if (!ng_v_call_cf && (ng_v_call_status == 7u || (ng_v_call_flags & 4u))) {
                /* A guest can disappear before STATUS observes ACCEPT.
                 * Discard this attempt and start a fresh framing session. */
                net_host_close_ovl();
                goto next_guest;
            }
            if (ng_v_call_cf || ng_v_call_status || (ng_v_call_flags & 4u)) {
                net_ui_host_failure("ACCEPT RECV FAILED");
                break;
            }
            host_status();
            if (ng_v_call_cf || ng_v_call_status) {
                net_ui_host_failure("STATUS FAILED");
                break;
            }
            if ((ng_v_call_len & 10u) == 10u) {
                host_unlisten();
                if (ng_v_call_cf || ng_v_call_status) {
                    net_ui_host_failure("UNLISTEN FAILED");
                    break;
                }
                direct_host.listening = 0u;
                direct_host.restart = 0u;
                host_rx_pause(); /* protect RX while NETWORK restores the board */
                return 1u;
            }
        }
cleanup:
        net_host_close_ovl();
retry:
        if (!net_ui_wait_retry()) {
            direct_host.enabled = 0u;
            return 0u;
        }
next_guest:
        ;
    }
}

/* Preparation never resets framing: accept may already have queued data. */
unsigned char net_prepare_ovl(void)
{
    if (direct_host.enabled) host_rx_resume();
    netchesszx_session_ping_reset(&net_ping);
    netchesszx_session_peer_reset();
    net_peer_known = 0u;
    net_hello_wait = 0u;
    direct_host.hello_frame_last = frame_counter;
    direct_host.hello_retries = 0u;
    direct_host.hello_seen = 0u;
    direct_host.start_pending = 0u;
    direct_host.restart = 0u;
    net_active = 1u;
    return 1u;
}

static unsigned char net_start_send(void)
{
    return spectrum_link_send_text(netchesszx_local_is_white()
        ? "GAME START WHITE=HOST" : "GAME START WHITE=GUEST");
}

static unsigned char net_handshake_failed(const char *reason)
{
    char *text = spectrum_link_payload_scratch();
    (void)spectrum_link_send_text(NETCHESS_PROTO_BYE);
    strcpy(text, reason);
    return SPRINTER_NET_FAILED;
}

/* Consume HELLO/START acknowledgments before game dispatch. All parsers
 * and strings follow the common Direct contract; duplicate HELLO is inert. */
unsigned char net_hello_ovl(void)
{
    char *text = spectrum_link_payload_scratch();
    if (netchess_after_prefix(text, NETCHESS_PROTO_GAME_START)) {
        const char *reply;
        uint8_t owner;
        if (netchesszx_session_is_host()) reply = "NACK GAME START HOST";
        else if (!netchesszx_session_peer_ready_state ||
                 !netchess_direct_parse_start_white_owner(text, &owner)) reply = "NACK GAME START BAD";
        else return 0u; /* validated guest START is handled by the game driver */
        if (!spectrum_link_send_text(reply)) return net_handshake_failed("START reply failed");
        return 1u;
    }
    if (direct_host.start_pending && !strcmp(text, "ACK GAME START")) {
        direct_host.start_pending = 0u;
        netchesszx_session_peer_mark_ready();
        host_rx_pause();
        net_session_begin();
        host_rx_resume();
        return 1u;
    }
    if (!netchess_direct_is_hello(text)) return 0u;
    if (!netchesszx_session_direct_apply_hello(text)) {
        return net_handshake_failed("Bad HELLO from opponent");
    }
    if (direct_host.hello_seen) return 1u;
    direct_host.hello_seen = 1u;
    spectrum_link_direct_peer_mark_valid();
    if (!netchesszx_session_direct_send_hello()) {
        return net_handshake_failed("HELLO send failed");
    }
    if (netchesszx_session_is_host()) {
        direct_host.start_pending = 1u;
        direct_host.hello_retries = 0u;
        net_hello_wait = SESSION_DIRECT_REPLY_TICKS;
        if (!net_start_send()) return net_handshake_failed("START send failed");
        direct_host.hello_frame_last = frame_counter;
    } else {
        netchesszx_session_peer_mark_ready();
        net_session_begin();
    }
    return 1u;
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
        net_ui_row(NET_UI_ROW_DETAIL2, NET_UI_ATTR_DIM, "");
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
            if (ng_up_reason != 0u) {
                net_ui_row(NET_UI_ROW_DETAIL, NET_UI_ATTR_DIM,
                          net_ui_preflight_reason(ng_up_reason));
                net_ui_row(NET_UI_ROW_DETAIL2, NET_UI_ATTR_DIM, "");
            } else {
                /* Backend loaded, so the failure is somewhere in TCP
                   connect / MQTT CONNECT / CONNACK -- the DLL's own last
                   AT/driver response tail (LASTERR) says which, the same
                   diagnostic net_ui_direct_connect() already shows on its
                   own CONNECT FAILED. A static "CHECK BROKER/PORT/ROOM"
                   here was a 2026-08-15 MAME finding: a broker address
                   that matched the Qt peer's own (and that Qt connected to
                   successfully) still failed with zero information on
                   which stage -- DNS, TCP, or the MQTT handshake itself --
                   actually rejected it -- and 2026-08-15's follow-up round
                   then showed WHY that was still not enough: LASTERR alone
                   is not a report of the attempt at all (see net_ui_show_
                   lasterr's own comment). The step/CF/status row is. */
                net_ui_show_mqtt_failure();
                net_ui_show_lasterr(NET_UI_ROW_DETAIL2);
            }
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

/* ENTER handling: validate the focused transport's own fields (MQTT's
   broker/port/room, or DIRECT's host/port since S9), commit them into the
   mutable session globals, configure the session, and dispatch the chosen
   transport's own connect flow.

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
    uint8_t role = net_ui_role;

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
    } else {
        uint16_t port_value;

        if (role == NETCHESSZX_SESSION_ROLE_JOIN && !net_ui_ipv4_ok(net_ui_field_host)) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "BAD IP");
            (void)net_ui_wait_retry();
            return 0u;
        }
        if (!net_ui_port_value(net_ui_field_dport, &port_value)) {
            net_ui_row(NET_UI_ROW_STATE, NET_UI_ATTR_BRIGHT, "BAD PORT");
            (void)net_ui_wait_retry();
            return 0u;
        }
        direct_host.port = port_value;
        direct_host.color = net_ui_color;
    }

    netchesszx_session_configure(role,
                                 net_ui_transport,
                                 net_ui_transport == NETCHESSZX_TRANSPORT_DIRECT ? net_ui_color : NETCHESSZX_COLOR_WHITE);
    if (role == NETCHESSZX_SESSION_ROLE_JOIN) {
        netchesszx_host_color_ready = 0u;
    }
    /* app.c's session_setup_start does exactly this, and skipping it was a
       2026-08-15 MAME finding: an MQTT HOST announced "H W 0" and a guest
       that adopted session id 0 could never reach GAME START (event.c's
       netchesszx_session_mqtt_can_accept_game_start requires a non-zero id).
       A JOIN must start at 0 for the opposite reason -- it learns the id
       from the host's own H, and mqtt.c's apply_host_color treats a
       DIFFERENT non-zero id as "a new live session" and resets peer state,
       which a leftover id from a previous room would trigger spuriously. */
    /* Spelled as an if, not a ternary: sccz80 miscompiles an &&/|| inside a
       conditional expression (tools/check_sccz80_codegen.py gates exactly
       this, and caught the first draft of these four lines). */
    netchesszx_mqtt_session_id = 0u;
    if (net_ui_transport == NETCHESSZX_TRANSPORT_MQTT &&
        role == NETCHESSZX_SESSION_ROLE_HOST) {
        netchesszx_mqtt_session_id = net_mqtt_new_session_id();
    }

    direct_host.enabled = 0u;
    if (net_ui_transport == NETCHESSZX_TRANSPORT_DIRECT && role == NETCHESSZX_SESSION_ROLE_HOST) {
        direct_host.enabled = 1u;
        return net_host_wait_ovl();
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
    /* Preserve valid focus across screen visits and transport changes. */
    net_ui_focus_normalize(1);
    net_ui_frame();
    net_ui_row(NET_UI_ROW_FOOTER, NET_UI_ATTR_DIM,
              "UP/DN SELECT  L/R CHANGE  ENTER CONNECT  ESC CANCEL");
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
                      "UP/DN SELECT  L/R CHANGE  ENTER CONNECT  ESC CANCEL");
            continue;
        }
        if (key_code == NET_UI_KEY_UP) {
            uint8_t old_focus = net_ui_focus;

            net_ui_focus = net_ui_focus == 0u ? net_ui_max_focus() : (uint8_t)(net_ui_focus - 1u);
            net_ui_focus_normalize(-1);
            key_code = 0u;
            net_ui_paint_focus_row(old_focus, 0u);
            net_ui_paint_focus_row(net_ui_focus, 1u);
            continue;
        }
        if (key_code == NET_UI_KEY_DOWN) {
            uint8_t old_focus = net_ui_focus;

            net_ui_focus = net_ui_focus == net_ui_max_focus() ? 0u : (uint8_t)(net_ui_focus + 1u);
            net_ui_focus_normalize(1);
            key_code = 0u;
            net_ui_paint_focus_row(old_focus, 0u);
            net_ui_paint_focus_row(net_ui_focus, 1u);
            continue;
        }
        if (key_code == NET_UI_KEY_LEFT || key_code == NET_UI_KEY_RIGHT) {
            if (net_ui_focus == 0u) {
                /* TRANSPORT toggle changes which rows exist/mean (MQTT's
                   ROOM row, ROLE's focusability, the backend row) -- full
                   repaint. */
                net_ui_transport = net_ui_transport == NETCHESSZX_TRANSPORT_MQTT
                    ? NETCHESSZX_TRANSPORT_DIRECT
                    : NETCHESSZX_TRANSPORT_MQTT;
                if (net_ui_focus > net_ui_max_focus()) {
                    net_ui_focus = net_ui_max_focus();
                }
                net_ui_focus_normalize(1);
                key_code = 0u;
                net_ui_frame();
            } else if (net_ui_focus == 1u) {
                /* HOST changes the DIRECT address row into a colour switch. */
                net_ui_role = net_ui_role == NETCHESSZX_SESSION_ROLE_HOST
                    ? NETCHESSZX_SESSION_ROLE_JOIN
                    : NETCHESSZX_SESSION_ROLE_HOST;
                key_code = 0u;
                net_ui_frame();
            } else if (net_ui_transport == NETCHESSZX_TRANSPORT_DIRECT &&
                       net_ui_role == NETCHESSZX_SESSION_ROLE_HOST && net_ui_focus == 2u) {
                net_ui_color ^= 1u;
                key_code = 0u;
                net_ui_paint_focus_row(2u, 1u);
            } else {
                key_code = 0u;
            }
            continue;
        }

        /* Printable ASCII or BS on the focused text field, for either
           transport -- repaint only that field's row (this loop's own hot
           path: one call per keystroke while typing). */
        {
            char *field;
            uint8_t cap;
            char (*filter)(char);

            if (net_ui_focused_field(&field, &cap, &filter)) {
                net_ui_edit_field(field, cap, filter, key_code);
                net_ui_paint_focus_row(net_ui_focus, 1u);
            }
        }
        key_code = 0u;
    }
}

/* NETWORK application entry. Renderer arguments are staged in WIN2 because
 * each painter maps the cold page over this NET page. */
extern void saveload_full_redraw(void);
unsigned char net_network_ovl(void)
{
    unsigned char joined;
    char *text = spectrum_link_payload_scratch();
    spectrum_gui_clear_cursor_coords();
    joined = net_join_ui_ovl();
    spectrum_gui_restore_board_area();
    saveload_full_redraw();
    if (!joined) {
        strcpy(text, "Not connected");
        spectrum_gui_notify(text, 1u);
        return 0u;
    }
    net_prepare_ovl();
    spectrum_gui_set_connected(netchesszx_transport_is_mqtt() ? 1u : 2u);
    strcpy(text, "WAITING");
    spectrum_gui_set_status(text);
    strcpy(text, "Waiting for opponent");
    spectrum_gui_notify_persistent(text);
    return 1u;
}

unsigned char net_hello_tick_ovl(void)
{
    uint8_t elapsed;
    if (netchesszx_transport_is_mqtt() || net_peer_known) return 1u;
    /* Shared polling still answers peer PING, but its game liveness clock
     * must not expire or originate PING during the bounded handshake. */
    netchesszx_session_ping_reset(&net_ping);
    elapsed = (uint8_t)(frame_counter - direct_host.hello_frame_last);
    direct_host.hello_frame_last = frame_counter;
    if (net_hello_wait > elapsed) {
        net_hello_wait -= elapsed;
        return 1u;
    }
    if (direct_host.hello_retries < (direct_host.start_pending ? SESSION_DIRECT_REPLY_RETRIES : SESSION_DIRECT_HELLO_RETRIES + 1u)) {
        ++direct_host.hello_retries;
        if (direct_host.start_pending) {
            net_hello_wait = SESSION_DIRECT_REPLY_TICKS;
            if (net_start_send()) {
                direct_host.hello_frame_last = frame_counter;
                return 1u;
            }
        } else {
            net_hello_wait = SESSION_DIRECT_HELLO_TICKS;
            if (netchesszx_session_direct_send_hello()) {
                direct_host.hello_frame_last = frame_counter;
                return 1u;
            }
        }
    }
    return net_handshake_failed("Handshake failed");
}
