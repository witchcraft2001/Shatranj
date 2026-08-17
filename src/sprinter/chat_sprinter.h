/* Sprinter-only entry ids on the INPUT_EDIT overlay (SPECTRUM_OVL_INPUT_EDIT
 * = 9u, src/spectrum/overlay/overlay.h). Entries 0-4 on that id are shared
 * with ZX/Next (RENDER/BEGIN_EMPTY/STOP_CLEAR/KEY/HISTORY_ADD, overlay.h's
 * own definitions -- chat_sprinter.c implements all five with the same
 * semantics); entries 5-7 below exist only on this port (the chat log this
 * overlay also owns, ZX/Next's own equivalent is GUI_LOG(2)'s ADD_CHAT).
 *
 * Deliberately NOT added to src/spectrum/overlay/overlay.h: that header's
 * id/entry numbering is machine-checked against docs/abi_manifest.baseline.
 * json for ZX (tools/gen_abi_manifest.py) -- appending Sprinter-only entries
 * there would shift that baseline for a platform this change must not
 * touch (CLAUDE.md rule 3, PR discipline: "дифф только добавляющий"). This
 * header is the Sprinter-side extension point instead, read by both
 * gui_log_sprinter.c (WIN1, the caller) and chat_sprinter.c (the overlay
 * page 2, the callee) so the two ends cannot drift apart.
 */
#ifndef SHATRANJ_SPRINTER_CHAT_SPRINTER_H
#define SHATRANJ_SPRINTER_CHAT_SPRINTER_H

#define SPECTRUM_OVL_INPUT_EDIT_ADD_CHAT 5u
#define SPECTRUM_OVL_INPUT_EDIT_RESET_CHAT 6u
#define SPECTRUM_OVL_INPUT_EDIT_RENDER_CHAT 7u

/* chat_key_ovl's own return value (L register), read by main.c's frame
 * loop after every dispatched key: 0 stays in chat-input mode, 1 closes it
 * (submitted or cancelled), 2 closes it AND the caller must net_drop
 * ("Link down" -- the send itself failed), 3 leaves it open but the
 * caller should show a "Waiting for ACK" notice (a MOVE/RESTORE became
 * pending between ENTER opening the line and this submit). */
#define CHAT_SPRINTER_KEY_OPEN 0u
#define CHAT_SPRINTER_KEY_CLOSED 1u
#define CHAT_SPRINTER_KEY_LINK_DOWN 2u
#define CHAT_SPRINTER_KEY_BLOCKED 3u

/* S9 slash commands: chat_submit recognises "/draw", "/resign", "/takeback"
 * (exact strcmp, case-sensitive, ZX's own convention -- see app.c's own
 * process_local_key) and returns one of these instead of sending a CHAT.
 * This overlay cannot itself send a control verb or show a notice (this
 * file's own header: no spectrum_overlay_exec_cached, no cross-page
 * pointers) -- main.c's frame loop maps each straight onto the matching
 * hotkey already wired in session_sprinter.c's net_control_key, so all the
 * actual policy (guards, confirmation, retry) lives in exactly one place. */
#define CHAT_SPRINTER_KEY_CMD_DRAW 4u
#define CHAT_SPRINTER_KEY_CMD_RESIGN 5u
#define CHAT_SPRINTER_KEY_CMD_TAKEBACK 6u

#endif
