/* INPUT_EDIT overlay (SPECTRUM_OVL_INPUT_EDIT=9u), Sprinter's own chat
 * feature (S9 chat pass). Lives on WIN3 overlay page 2, in the slot that
 * used to be RESERVE2 (tools/make_sprinter_overlay_page.py's LAYOUT2) --
 * the only unfragmented room left on either WIN3 overlay page once page
 * 1's own slack and the rest of page 2 were already spoken for (this
 * file's own Makefile rule comment has the numbers).
 *
 * WHY ONE FILE OWNS BOTH THE LINE EDITOR AND THE CHAT LOG: ZX/Next split
 * these across two overlay ids (INPUT_EDIT=9 for the editor,
 * GUI_LOG(2)'s ADD_CHAT entry for the log) because GUI_LOG already existed
 * for the move list and ZX had spare entries on it. This port's move list
 * is Sprinter-native C (src/sprinter/gui_log_sprinter.c, WIN1-resident,
 * no spare WIN3 slot of its own), and the two features share state that
 * must never desync -- a submitted line becomes a chat-log row in the same
 * keystroke that closes the editor -- so keeping both here, one self-
 * contained overlay, avoids a second cross-page round trip for every send
 * and keeps chat_line_count/local_input_len as the only two counters that
 * matter (no gui.c-side shadow copy to keep in step -- gui.c's own
 * chat_lines/chat_line_count statics exist too, but are unreachable dead
 * code on this port: they belong to spectrum_gui_reset_logs/_restore_
 * side_panels, both app.c-only callers, and app.c is not linked here).
 *
 * NO PER-CHARACTER CURSOR: unlike ZX's input_edit_ovl.c (which repaints
 * one character cell at a time through spectrum_gui_input_cell, keyed to
 * a fixed-width font), this port's font is proportional and spectrum_
 * render_input_cell has no real implementation (render_core.asm's own
 * comment on that stub) -- the same constraint net_ui_sprinter.c's own
 * header already worked around for the NET screen's editable fields.
 * Editing is append/backspace-at-the-end only (no LEFT/RIGHT mid-string
 * cursor), and the caret is a single trailing "_" appended to whatever is
 * being sent to spectrum_render_input -- cheap, and exactly what the
 * player needs to see while typing a short line.
 *
 * CROSS-PAGE CALL DISCIPLINE (see docs/sprinter-testnotes and this port's
 * "no pointers from overlay BSS outward" rule): every pointer this file
 * hands to a cross-page call (spectrum_render_input/_chat/_chat_at,
 * spectrum_net_send_text) points at LOWRAM or a WIN1-resident buffer
 * (spectrum_net_payload_scratch(), the C stack -- always mapped regardless
 * of which WIN3 page is live) -- NEVER at a string literal or local array
 * living in this overlay's own compiled bytes, which would already be the
 * WRONG page's content by the time the callee dereferences it. String
 * literals used only for a same-page, synchronous read (chat_copy_clock_
 * line's "--:-- " fallback, chat_history_down's "" reset) are fine --
 * this page is still mapped while THIS file's own code is running.
 *
 * NEVER call spectrum_overlay_exec_cached (spectrum_gui_add_chat/
 * _reset_chat, gui_log_sprinter.c) FROM this file: that dispatcher saves
 * the caller's current WIN3 page into a single global cell
 * (overlay_loader_sprinter.asm's ovl_v_saved_win3) and restores it on
 * return -- reentering it while already inside a dispatched call (this
 * overlay only runs BECAUSE that same mechanism dispatched it) would
 * overwrite that cell with THIS page's number, and the outer dispatch
 * would restore the wrong page when it finally returns. The local send
 * echo therefore calls chat_add_line() directly (this file's own static),
 * not spectrum_gui_add_chat -- and errors are reported to WIN1 via the
 * KEY entry's own return code (chat_sprinter.h's CHAT_SPRINTER_KEY_*),
 * not by calling net_drop/spectrum_gui_notify from here.
 */
#include "spectrum/ui/render.h"
#include "spectrum/lowram_map.h"
#include "spectrum/config/session.h"
#include "spectrum/transport/link.h"
#include "spectrum/platform/text.h"
#include "common/protocol/game_protocol.h"
#include "spectrum/overlay/overlay_context.h"
#include "sprinter/chat_sprinter.h"

#include <string.h>

/* src/sprinter/session_sprinter.c (WIN3 cold page), bridged through this
 * overlay's own gen_sprinter_overlay_defs.py OVERLAY_RESIDENT_SYMBOLS
 * entry -- same funnel spectrum_net_send_text below already uses. Checked
 * at submit time (not just at ENTER-open time in main.c) because a MOVE
 * this player just sent, or a RESTORE the peer just started, can become
 * pending in the frames between opening the chat line and pressing ENTER
 * to send it. */
extern unsigned char net_chat_blocked(void);

#define LOCAL_INPUT_MAX ((uint8_t)(NETCHESSZX_LOWRAM_LOCAL_INPUT_SIZE - 1u))
#define INPUT_HISTORY_SIZE 2u
#define INPUT_HISTORY_NONE 0xffu
#define INPUT_HISTORY_TEXT_MAX \
    ((uint8_t)((NETCHESSZX_LOWRAM_INPUT_HISTORY_SIZE / INPUT_HISTORY_SIZE) - 1u))

#define CHAT_ROWS 9u
#define CHAT_SLOT_SIZE 28u
#define CHAT_TEXT_OFFSET 7u     /* first row: who(1) + "HH:MM "(6) + text  */
#define CHAT_TEXT_LIMIT 25u     /* both row shapes stop writing text here  */

#define KEY_BS 8u
#define KEY_UP 0x81u
#define KEY_DOWN 0x82u
#define KEY_CANCEL 0x8au
#define KEY_ENTER 0x0du

#define local_input ((char *)NETCHESSZX_LOWRAM_LOCAL_INPUT_ADDR)
#define input_history ((char *)NETCHESSZX_LOWRAM_INPUT_HISTORY_ADDR)
#define input_history_slot(index) \
    (input_history + ((uint16_t)(index) * (INPUT_HISTORY_TEXT_MAX + 1u)))
#define chat_lines ((char *)NETCHESSZX_LOWRAM_CHAT_LOG_ADDR)
#define chat_scratch ((char *)NETCHESSZX_LOWRAM_OVERLAY_SCRATCH_ADDR)

static uint8_t local_input_len;
static uint8_t input_history_count;
static uint8_t input_history_pos;
static uint8_t chat_line_count;

static uint8_t chat_has_text(const char *text)
{
    while (*text != '\0') {
        if (*text != ' ') {
            return 1u;
        }
        ++text;
    }
    return 0u;
}

/* Composes local_input (plus a trailing "_" caret when show_caret) into
 * the shared WIN2 scratch buffer and repaints the input line through it --
 * never through a pointer into this page's own local_input/literal bytes
 * (see this file's header). */
static void chat_repaint(uint8_t show_caret)
{
    uint8_t n = 0u;

    while (n < local_input_len) {
        chat_scratch[n] = local_input[n];
        ++n;
    }
    if (show_caret) {
        chat_scratch[n++] = '_';
    }
    chat_scratch[n] = '\0';
    spectrum_render_input(chat_scratch);
}

static void chat_history_nav_reset(void)
{
    input_history_pos = INPUT_HISTORY_NONE;
}

static void chat_set_text(const char *text)
{
    uint8_t n = 0u;

    while (n < LOCAL_INPUT_MAX && text[n] != '\0') {
        local_input[n] = text[n];
        ++n;
    }
    local_input[n] = '\0';
    local_input_len = n;
    chat_repaint(1u);
}

static void chat_insert_char(uint8_t key)
{
    if (key < 0x20u || key > 0x7eu || local_input_len >= LOCAL_INPUT_MAX) {
        return;
    }
    local_input[local_input_len] = (char)key;
    ++local_input_len;
    local_input[local_input_len] = '\0';
    chat_history_nav_reset();
    chat_repaint(1u);
}

static void chat_backspace(void)
{
    if (local_input_len == 0u) {
        return;
    }
    --local_input_len;
    local_input[local_input_len] = '\0';
    chat_history_nav_reset();
    chat_repaint(1u);
}

/* Same ring-of-2, dedup-against-last-entry shape as ZX's own input_edit_
 * history_add_ovl (asm/overlay/gui_log's input_edit_ovl.c) -- ported to C
 * verbatim, only the storage macros differ. */
static void chat_history_add(const char *text)
{
    char *slot;
    uint8_t i;

    if (!chat_has_text(text)) {
        return;
    }
    if (input_history_count != 0u) {
        const char *last = input_history_slot(input_history_count - 1u);

        i = 0u;
        while (i <= INPUT_HISTORY_TEXT_MAX && last[i] == text[i]) {
            if (last[i] == '\0') {
                return;
            }
            ++i;
        }
    }
    if (input_history_count < INPUT_HISTORY_SIZE) {
        slot = input_history_slot(input_history_count);
        ++input_history_count;
    } else {
        char *dst = input_history_slot(0u);
        const char *src = input_history_slot(1u);

        for (i = 0u; i <= INPUT_HISTORY_TEXT_MAX; ++i) {
            dst[i] = src[i];
        }
        slot = input_history_slot(INPUT_HISTORY_SIZE - 1u);
    }
    for (i = 0u; i < INPUT_HISTORY_TEXT_MAX && text[i] != '\0'; ++i) {
        slot[i] = text[i];
    }
    slot[i] = '\0';
}

static void chat_history_up(void)
{
    uint8_t index;

    if (input_history_count == 0u) {
        return;
    }
    if (input_history_pos == INPUT_HISTORY_NONE) {
        input_history_pos = 0u;
    } else if ((uint8_t)(input_history_pos + 1u) < input_history_count) {
        ++input_history_pos;
    }
    index = (uint8_t)(input_history_count - 1u - input_history_pos);
    chat_set_text(input_history_slot(index));
}

static void chat_history_down(void)
{
    if (input_history_pos == INPUT_HISTORY_NONE) {
        return;
    }
    if (input_history_pos == 0u) {
        input_history_pos = INPUT_HISTORY_NONE;
        chat_set_text("");
        return;
    }
    --input_history_pos;
    chat_set_text(input_history_slot(
        (uint8_t)(input_history_count - 1u - input_history_pos)));
}

/* --- chat log (word-wrap ported byte-for-byte from asm/overlay/gui_log/
 * entry_gui_log.asm's _chat_clean_char/_chat_word_len/_chat_copy_clock_
 * line/_scroll_chat_lines/_log_line_at, and gui_log_ovl.c's own gui_log_
 * add_chat C driver around them) ------------------------------------- */

static char chat_clean_char(uint8_t c)
{
    if (c < ' ' || c > '~') {
        return ' ';
    }
    return (char)c;
}

static uint8_t chat_word_len(const char *text)
{
    uint8_t len = 0u;

    while (len < 24u && text[len] != '\0' && text[len] != ' ') {
        ++len;
    }
    return len;
}

static void chat_copy_clock_line(char *line)
{
    const char *clock = (const char *)NETCHESSZX_LOWRAM_CLOCK_SAVE_ADDR;
    uint8_t i;

    if (clock[0] == '\0') {
        clock = "--:-- ";
    }
    for (i = 0u; i < 6u; ++i) {
        line[1u + i] = clock[i];
    }
}

static char *chat_line_at(uint8_t index)
{
    return chat_lines + (uint16_t)index * CHAT_SLOT_SIZE;
}

static char *chat_new_line(uint8_t index)
{
    char *line;

    if (index >= CHAT_ROWS) {
        memmove(chat_lines, chat_lines + CHAT_SLOT_SIZE,
                (uint16_t)(CHAT_ROWS - 1u) * CHAT_SLOT_SIZE);
        spectrum_render_chat_scroll();
        index = CHAT_ROWS - 1u;
    }
    line = chat_line_at(index);
    memset(line, 0, CHAT_SLOT_SIZE);
    return line;
}

static void chat_add_line(char who, const char *text)
{
    char *line;
    uint8_t first = 1u;
    uint8_t col;

    do {
        line = chat_new_line(chat_line_count);
        if (chat_line_count < CHAT_ROWS) {
            ++chat_line_count;
        }
        if (first) {
            line[0] = who;
            chat_copy_clock_line(line);
            col = CHAT_TEXT_OFFSET;
            first = 0u;
        } else {
            line[0] = '\0';
            col = 1u;
        }

        while (*text == ' ') {
            ++text;
        }
        while (*text != '\0' && col < CHAT_TEXT_LIMIT) {
            uint8_t word_len = chat_word_len(text);
            uint8_t add_space;

            if (line[0] != '\0') {
                add_space = (uint8_t)(col > CHAT_TEXT_OFFSET);
            } else {
                add_space = (uint8_t)(col > 1u);
            }

            if (word_len == 0u) {
                ++text;
                continue;
            }
            if ((uint8_t)(word_len + add_space) >
                (uint8_t)(CHAT_TEXT_LIMIT - col)) {
                if (!add_space) {
                    while (*text != '\0' && *text != ' ' &&
                           col < CHAT_TEXT_LIMIT) {
                        line[col++] = chat_clean_char((uint8_t)*text++);
                    }
                }
                break;
            }
            if (add_space) {
                line[col++] = ' ';
            }
            while (word_len-- != 0u && col < CHAT_TEXT_LIMIT) {
                line[col++] = chat_clean_char((uint8_t)*text++);
            }
            while (*text == ' ') {
                ++text;
            }
        }
        line[CHAT_TEXT_LIMIT] = '\0';
        spectrum_render_chat_at(line);
    } while (*text != '\0');
}

/* Empty/whitespace-only -> just close (matches ZX's own send_local_chat:
 * input_has_text guards the send, an empty line is not an error). Common
 * to ESC and an empty ENTER. */
static uint8_t chat_close_empty(void)
{
    local_input[0] = '\0';
    local_input_len = 0u;
    chat_history_nav_reset();
    chat_repaint(0u);
    return CHAT_SPRINTER_KEY_CLOSED;
}

static uint8_t chat_submit(void)
{
    char *payload;
    char *p;
    char *end;
    const char *text;

    if (!chat_has_text(local_input)) {
        return chat_close_empty();
    }
    /* S9 slash commands, byte-for-byte app.c's own strcmp shape (process_
       local_key's "/resign"/"/draw"/"/takeback" branches) -- exact,
       case-sensitive match, no trim/lowercase (that is Qt's own local_
       input handling, a different input-line family). An unrecognised
       "/foo" falls straight through to the ordinary CHAT send below,
       matching both existing platforms: only these three strings are
       commands, everything else typed is a message. Checked before
       net_chat_blocked() below on purpose -- main.c's net_control_key
       dispatch reports its own "Waiting for ACK"/busy notices the same
       way the 'd'/'t' hotkeys already do, so this file does not need to
       duplicate that guard. */
    if (strcmp(local_input, "/draw") == 0) {
        (void)chat_close_empty();
        return CHAT_SPRINTER_KEY_CMD_DRAW;
    }
    if (strcmp(local_input, "/resign") == 0) {
        (void)chat_close_empty();
        return CHAT_SPRINTER_KEY_CMD_RESIGN;
    }
    if (strcmp(local_input, "/takeback") == 0) {
        (void)chat_close_empty();
        return CHAT_SPRINTER_KEY_CMD_TAKEBACK;
    }
    if (net_chat_blocked()) {
        return CHAT_SPRINTER_KEY_BLOCKED;   /* line stays open, unsent */
    }

    /* "CHAT " + text, byte-for-byte app.c's own send_local_chat shape. */
    payload = spectrum_net_payload_scratch();
    p = spectrum_append_text(payload, NETCHESS_PROTO_CHAT_PREFIX);
    end = payload + SPECTRUM_LINK_PAYLOAD_MAX - 1u;
    text = local_input;
    while (*text != '\0' && p < end) {
        *p++ = *text++;
    }
    *p = '\0';

    if (!spectrum_net_send_text(payload)) {
        local_input[0] = '\0';
        local_input_len = 0u;
        chat_history_nav_reset();
        chat_repaint(0u);
        return CHAT_SPRINTER_KEY_LINK_DOWN;
    }

    chat_history_add(local_input);
    /* Direct call, not spectrum_gui_add_chat -- see this file's header. */
    chat_add_line(netchesszx_local_side_char(), payload + 5u);

    local_input[0] = '\0';
    local_input_len = 0u;
    chat_history_nav_reset();
    chat_repaint(0u);
    return CHAT_SPRINTER_KEY_CLOSED;
}

/* --- overlay entries (SPECTRUM_OVL_INPUT_EDIT=9u; 0-4 share ZX/Next's own
 * ids and semantics, 5-7 are Sprinter-only, chat_sprinter.h) ----------- */

uint8_t input_edit_render_ovl(uint8_t *ctx) __z88dk_fastcall
{
    (void)ctx;
    chat_repaint(1u);
    return 1u;
}

uint8_t input_edit_begin_empty_ovl(uint8_t *ctx) __z88dk_fastcall
{
    (void)ctx;
    local_input[0] = '\0';
    local_input_len = 0u;
    chat_history_nav_reset();
    chat_repaint(1u);
    return 1u;
}

uint8_t input_edit_stop_clear_ovl(uint8_t *ctx) __z88dk_fastcall
{
    (void)ctx;
    local_input[0] = '\0';
    local_input_len = 0u;
    chat_history_nav_reset();
    chat_repaint(0u);
    return 1u;
}

uint8_t input_edit_key_ovl(uint8_t *ctx) __z88dk_fastcall
{
    uint8_t key = ctx[SPECTRUM_OVL_CTX_INPUT_KEY];

    if (key == KEY_BS) {
        chat_backspace();
        return CHAT_SPRINTER_KEY_OPEN;
    }
    if (key == KEY_UP) {
        chat_history_up();
        return CHAT_SPRINTER_KEY_OPEN;
    }
    if (key == KEY_DOWN) {
        chat_history_down();
        return CHAT_SPRINTER_KEY_OPEN;
    }
    if (key == KEY_CANCEL) {
        return chat_close_empty();
    }
    if (key == KEY_ENTER) {
        return chat_submit();
    }
    chat_insert_char(key);
    return CHAT_SPRINTER_KEY_OPEN;
}

uint8_t input_edit_history_add_ovl(uint8_t *ctx) __z88dk_fastcall
{
    const char *text =
        (const char *)((uint16_t)ctx[SPECTRUM_OVL_CTX_PTR_LO] |
                       ((uint16_t)ctx[SPECTRUM_OVL_CTX_PTR_HI] << 8));

    chat_history_add(text);
    return 1u;
}

uint8_t input_edit_add_chat_ovl(uint8_t *ctx) __z88dk_fastcall
{
    char who = (char)ctx[SPECTRUM_OVL_CTX_GUI_CHAT_WHO];
    const char *text =
        (const char *)((uint16_t)ctx[SPECTRUM_OVL_CTX_GUI_CHAT_TEXT_LO] |
                       ((uint16_t)ctx[SPECTRUM_OVL_CTX_GUI_CHAT_TEXT_HI] << 8));

    chat_add_line(who, text);
    return 1u;
}

uint8_t input_edit_reset_chat_ovl(uint8_t *ctx) __z88dk_fastcall
{
    (void)ctx;
    memset(chat_lines, 0, (uint16_t)CHAT_ROWS * CHAT_SLOT_SIZE);
    chat_line_count = 0u;
    spectrum_render_chat(chat_lines);
    return 1u;
}

uint8_t input_edit_render_chat_ovl(uint8_t *ctx) __z88dk_fastcall
{
    (void)ctx;
    spectrum_render_chat(chat_lines);
    return 1u;
}
