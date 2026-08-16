; Overlay entry table for INPUT_EDIT (SPECTRUM_OVL_INPUT_EDIT = 9u, S9 chat
; pass), page 2 of the WIN3 overlay window (tools/make_sprinter_overlay_
; page.py's LAYOUT2). Eight entries: 0-4 are the same ids ZX/Next reserve
; on this overlay (overlay.h -- RENDER/BEGIN_EMPTY/STOP_CLEAR/KEY/
; HISTORY_ADD), 5-7 are Sprinter-only (src/sprinter/chat_sprinter.h --
; ADD_CHAT/RESET_CHAT/RENDER_CHAT, this port's own replacement for GUI_LOG's
; ADD_CHAT entry since the move-list overlay id is not ported here, see
; chat_sprinter.c's own header for why both live on this one id instead).
;
; All eight are plain uint8_t f(uint8_t *ctx) __z88dk_fastcall C functions
; (ctx in HL, same shape as entry_board_sprinter.asm's DEFC aliases) --
; pure DEFC aliasing, no hand-written asm needed.

SECTION code_user

EXTERN _input_edit_render_ovl
EXTERN _input_edit_begin_empty_ovl
EXTERN _input_edit_stop_clear_ovl
EXTERN _input_edit_key_ovl
EXTERN _input_edit_history_add_ovl
EXTERN _input_edit_add_chat_ovl
EXTERN _input_edit_reset_chat_ovl
EXTERN _input_edit_render_chat_ovl

    DEFB 8
    DW _input_edit_render_ovl_entry        ; SPECTRUM_OVL_INPUT_EDIT_RENDER = 0
    DW _input_edit_begin_empty_ovl_entry    ; SPECTRUM_OVL_INPUT_EDIT_BEGIN_EMPTY = 1
    DW _input_edit_stop_clear_ovl_entry     ; SPECTRUM_OVL_INPUT_EDIT_STOP_CLEAR = 2
    DW _input_edit_key_ovl_entry            ; SPECTRUM_OVL_INPUT_EDIT_KEY = 3
    DW _input_edit_history_add_ovl_entry    ; SPECTRUM_OVL_INPUT_EDIT_HISTORY_ADD = 4
    DW _input_edit_add_chat_ovl_entry       ; SPECTRUM_OVL_INPUT_EDIT_ADD_CHAT = 5
    DW _input_edit_reset_chat_ovl_entry     ; SPECTRUM_OVL_INPUT_EDIT_RESET_CHAT = 6
    DW _input_edit_render_chat_ovl_entry    ; SPECTRUM_OVL_INPUT_EDIT_RENDER_CHAT = 7

DEFC _input_edit_render_ovl_entry = _input_edit_render_ovl
DEFC _input_edit_begin_empty_ovl_entry = _input_edit_begin_empty_ovl
DEFC _input_edit_stop_clear_ovl_entry = _input_edit_stop_clear_ovl
DEFC _input_edit_key_ovl_entry = _input_edit_key_ovl
DEFC _input_edit_history_add_ovl_entry = _input_edit_history_add_ovl
DEFC _input_edit_add_chat_ovl_entry = _input_edit_add_chat_ovl
DEFC _input_edit_reset_chat_ovl_entry = _input_edit_reset_chat_ovl
DEFC _input_edit_render_chat_ovl_entry = _input_edit_render_chat_ovl
