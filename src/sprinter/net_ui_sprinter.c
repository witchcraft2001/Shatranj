/*
 * DIRECT join UI (S7 step 5). Sprinter-only, WIN3 cold-code page.
 *
 * This is the modal screen the NETWORK menu tab opens: bring the uNet
 * backend up (ng_up), connect to NETHOST:NETPORT (ng_c_connect), and show
 * what happened at each step. It is the Sprinter equivalent of ZX/Next's
 * NET_CONNECT overlay (src/spectrum/overlay/, SPECTRUM_OVL_NET_CONNECT=3),
 * but it is NOT an overlay: it lives in the cold page alongside gui.c and
 * the painters, reached through one generated WIN1 thunk. An overlay would
 * have bought nothing here -- the whole flow runs a handful of times per
 * session, and the cold page has room the 2 KiB copy slot does not.
 *
 * WHY IT DRAWS WITH THE FILEUI PRIMITIVES: spectrum_render_fileui_frame()
 * and spectrum_render_ikkle_at() (render_core_cold.asm) are already
 * exactly "framed panel over the board area, N rows of text" -- the same
 * shape this screen needs, already MAME-proven in S6, and already in this
 * page (so these are direct calls, not thunks). Adding a second, nearly
 * identical panel painter to make the network screen "its own" would have
 * cost bytes and a fresh set of geometry bugs for no visible difference.
 * The row/col/attr units are that routine's own (row 5..20 at a 12px
 * pitch, col in 8px cells).
 *
 * Attr bytes are deliberately only FILEUI_ATTR_SAVED (bright) and the dim
 * fallback: the third value, FILEUI_ATTR_HEADER, makes the painter ignore
 * the column and force the " SAVED GAMES" centring X, which is wrong for
 * every string here.
 *
 * BLOCKING BY DESIGN. Everything here is one-shot and user-driven, so this
 * runs its own frame_wait/key_poll loop and returns only on CONNECTED or
 * cancel -- the same shape ZX's preflight has. main.c repaints the board
 * area afterwards. The one thing that must not block invisibly is ng_up(),
 * which can sit inside NETINIT for seconds: the panel therefore paints its
 * "working" state and flips BEFORE making the call, so the screen never
 * shows a stale line while the DLL is busy.
 */
#include "spectrum/ui/render.h"
#include "spectrum/ui/gui.h"

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

#define NET_UI_KEY_CANCEL 0x8au   /* im2_s1.asm: ESC */
#define NET_UI_KEY_ENTER 0x0du

#define NET_UI_ROW_TITLE 5u
#define NET_UI_ROW_HOST 8u
#define NET_UI_ROW_BACKEND 10u
#define NET_UI_ROW_STATE 13u
#define NET_UI_ROW_DETAIL 15u
#define NET_UI_ROW_FOOTER 20u
#define NET_UI_COL 2u

/* spectrum_render_ikkle_at's spec: [0]=row, [1]=col, [2]=attr, [3..]=text.
   One shared builder rather than one buffer per row -- every row is
   painted and gone before the next is built. Sized for the longest line
   this screen can produce (a 24-char host plus ":65535"). */
#define NET_UI_TEXT_MAX 40u
static char net_ui_spec[3u + NET_UI_TEXT_MAX];

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

/* "(DEFAULT)" is the whole point of the pointer compare: without it a
   missing NETHOST and a NETHOST deliberately set to 127.0.0.1 paint the
   same line, so a mis-set environment reads as a bug in the reader. The
   call and the compare are separate statements because sccz80 does not
   promise an argument evaluation order. */
static void net_ui_frame(void)
{
    const char *value;

    spectrum_render_fileui_frame();
    net_ui_row(NET_UI_ROW_TITLE, NET_UI_ATTR_BRIGHT, "NETWORK - DIRECT JOIN");

    value = ng_env_nethost();
    net_ui_row3(NET_UI_ROW_HOST, NET_UI_ATTR_BRIGHT, "HOST ", value,
                value == ng_default_host ? "  (DEFAULT)" : "");

    value = ng_env_netport();
    net_ui_row3(NET_UI_ROW_HOST + 1u, NET_UI_ATTR_BRIGHT, "PORT ", value,
                value == ng_default_port ? "  (DEFAULT)" : "");

    net_ui_row(NET_UI_ROW_BACKEND, NET_UI_ATTR_DIM, net_ui_backend_name());
}

/* Paint, then let one frame actually reach the screen. Every painter here
   is single-pass into back_base (render_core_cold.asm's own convention),
   so without the flip the "WORKING" line would still be invisible when
   ng_up() blocks for seconds inside NETINIT. */
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

/* uint8_t spectrum_net_join_ui(void) -- the whole modal flow.
   Returns 1 with a live TCP session, or 0 with nothing brought up that the
   caller has to tear down (a failed ng_up leaves the library either
   unloaded or closed by ng_close below).

   Reached from WIN1 through the generated thunk of the same name, which is
   why it takes no arguments and returns a byte: the trampoline is
   register-transparent but the simplest possible contract is still the
   right one for a once-per-session entry. */
unsigned char spectrum_net_join_ui(void)
{
    net_ui_frame();

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
