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
 * loop after every dispatched key.
 *
 * ORDERED, not arbitrary: the two codes that LEAVE THE LINE OPEN sort
 * below every code that closes it, so "does the line stay open?" is a
 * single `<` against CLOSED (the first closing code) rather than a list of
 * equality tests -- see CHAT_SPRINTER_KEY_KEEPS_LINE_OPEN below for why
 * that predicate has to be cheap as well as correct. Anything inserted
 * here must be placed on the correct side of CLOSED.
 *
 *   OPEN       stays in chat-input mode: an ordinary character, a
 *              backspace, a history step -- nothing happened except that
 *              the line's own text changed.
 *   BLOCKED    also stays open, with the text intact so it can be re-sent:
 *              the submit was refused because a MOVE/RESTORE went pending
 *              between ENTER opening the line and this submit. The caller
 *              shows a "Waiting for ACK" notice.
 *   CLOSED     the overlay closed the line itself (submitted, or cancelled).
 *   LINK_DOWN  closed, AND the send itself failed -- the caller must
 *              net_drop ("Link down") unless this was a transient BUSY. */
#define CHAT_SPRINTER_KEY_OPEN 0u
#define CHAT_SPRINTER_KEY_BLOCKED 1u
#define CHAT_SPRINTER_KEY_CLOSED 2u
#define CHAT_SPRINTER_KEY_LINK_DOWN 3u

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

/* THE contract between the codes above and main.c's frame loop: exactly two
 * of them leave the input line open and keep the keyboard routed to it --
 * OPEN (an ordinary character, a backspace, a history step: nothing
 * happened except the line changed) and BLOCKED (the submit was refused, so
 * the typed text must stay on screen to be re-sent). Every other code means
 * the line is already closed inside the overlay and main.c must clear its
 * own chat_input_mode to match.
 *
 * Spelled out HERE, next to the codes themselves, and not as an
 * "everything except X" test at the call site: main.c's ladder has an arm
 * for CLOSED/LINK_DOWN/BLOCKED/CMD_* but none for OPEN (OPEN's whole
 * meaning is "do nothing"), so an author folding the shared `chat_input_
 * mode = 0u` out of those arms naturally writes "every outcome except
 * BLOCKED" and silently swallows OPEN with it. That is exactly what
 * happened (commit 00d6974, found in MAME 2026-08-18): the first typed
 * character closed the line, and every character after it fell through to
 * the board hotkeys instead -- typing "Hello" showed "H" and then, as soon
 * as a "d"/"r"/"t" was typed, raised a draw offer / resign / takeback
 * prompt. Use this predicate, never an open-coded comparison.
 *
 * WHY IT IS A RANGE TEST. The obvious spelling -- `rc == OPEN || rc ==
 * BLOCKED` -- is correct but costs a second compare, and WIN1 had 15 bytes
 * left when this was fixed: it overran the C image by 6. Ordering the
 * codes so the two stay-open outcomes sit below CLOSED makes the predicate
 * one comparison, i.e. no more expensive than the buggy single `!=` it
 * replaces. That is also why the ordering above is part of the contract
 * and not an implementation detail.
 *
 * Kept on ONE physical line at every call site: sccz80 mistokenizes a macro
 * invocation whose arguments are split across lines (port.md, S8 step 8c).
 *
 * tests/sprinter/host/test_chat_key_contract.c pins the whole table,
 * including the ordering this depends on. */
#define CHAT_SPRINTER_KEY_KEEPS_LINE_OPEN(rc) ((rc) < CHAT_SPRINTER_KEY_CLOSED)

#endif
