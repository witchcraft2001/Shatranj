; The three portable-API bridges that stay in the WIN1 resident image when
; the rest of render_core.asm moves to its own WIN3 code page (S7 step 4
; byte-budget ladder -- render_core.asm's header has the full rationale).
;
; z88dk-z80asm module, linked alongside the C image by the same zcc
; invocation, exactly as render_core.asm used to be.
;
; These three are here rather than in the cold page for one reason: they
; are the only entry points in that whole file called once per frame, and
; all three are so small (1, 3 and 9 bytes of body) that a generated
; eight-byte WIN3 thunk plus a page map/restore would cost more than the
; routines themselves. Nothing here touches VRAM, so none of the cold
; page's window reasoning applies -- frame_wait and key_code both live in
; the always-mapped WIN2 half (asm/sprinter/im2_s1.asm), reached through
; the same generated platform_defs.asm bridge everything else uses.

    MODULE render_shim

    EXTERN frame_wait
    EXTERN key_code
    ; S9 dot-highlight budget valve: saveload_full_redraw (below) is five
    ; back-to-back calls into the cold page and nothing else -- as C
    ; (main.c) each one paid a full call-with-args prologue even though
    ; none take arguments; here each is a plain 3-byte `call` into the
    ; SAME generated WIN1 thunks (build/sprinter/generated/cold_thunks.asm)
    ; the C version already used, at whatever address gen_sprinter_cold_
    ; thunks.py assigns them -- resolved as ordinary EXTERNs, the ordinary
    ; ORDER this file is linked in (SPRINTER_RESIDENT_C_SRC, Makefile)
    ; already puts cold_thunks.asm ahead of this file for.
    EXTERN _render_board_full
    EXTERN _render_hint_markers_all
    EXTERN _render_coord_labels
    EXTERN _render_select_marker
    EXTERN _render_cursor_marker
    EXTERN _spectrum_gui_set_board_view
    EXTERN _spectrum_gui_is_board_flipped

    SECTION code_user

; No arguments. platform.h's spectrum_frame_wait -- a thin alias for this
; port's own frame_wait (im2_s1.asm), which main.c already calls directly;
; gui.c needs the portable name to link.
    PUBLIC _spectrum_frame_wait
_spectrum_frame_wait:
    jp frame_wait

; No arguments. uart.h's spectrum_uart_background_pump -- Sprinter has no
; UART transport (uNet/DSS is the only network path, port.md), so this is
; a permanent no-op rather than a stub awaiting a later step.
    PUBLIC _spectrum_uart_background_pump
_spectrum_uart_background_pump:
    ret

; No arguments, returns uint8_t in L (the confirmed uint8_t-return register
; for this port's classic-ABI asm entries -- render_core.asm's own C-facing
; section header spells the convention out). render.h's spectrum_key_poll,
; gui.c's spectrum_gui_poll_key wrapper's own backing call -- a read-and-
; clear poll of the same key_code latch key_poll (im2_s1.asm) already fills
; every frame. Unreachable from this port's own wiring today (main.c drives
; key_code through key_poll/board_cursor_move/board_select_or_move
; directly, not through gui.c's poll wrapper) -- it exists so gui.c's
; compiled object resolves, ready if a future pass switches input handling
; over to gui.c's own model.
    PUBLIC _spectrum_key_poll
_spectrum_key_poll:
    ld a,(key_code)
    ld l,a
    xor a
    ld (key_code),a
    ret

; No arguments. Full post-load repaint (main.c's own former C body, moved
; here as five plain calls -- see this file's own header on why a shared
; sequence of thunk calls with no other logic compiles smaller as asm than
; as a C function with three callers): render_board_full/render_hint_
; markers_all/render_coord_labels/render_select_marker/render_cursor_
; marker, in that order. render_hint_markers_all repaints any hint dots a
; live selection still has (fileui_close/menu_flip_board have no prior
; selection_clear() to already have cleared them) -- render_board_full
; alone paints straight through draw_square_into and never touches them.
    PUBLIC saveload_full_redraw
saveload_full_redraw:
    PUBLIC _saveload_full_redraw
    defc _saveload_full_redraw = saveload_full_redraw
    call _render_board_full
    call _render_hint_markers_all
    call _render_coord_labels
    call _render_select_marker
    jp _render_cursor_marker

; No arguments. Flips the board view and repaints (session_sprinter.c's
; handle_menu_action calls this by its C name) -- same budget-valve
; reasoning as saveload_full_redraw just above, and shares its own
; repaint tail by falling straight into it. spectrum_gui_is_board_flipped
; returns uint8_t in L (this port's confirmed asm-entry return register);
; spectrum_gui_set_board_view takes uint8_t in L too (__z88dk_fastcall) --
; negating L in place (xor 1, cheaper than a real "not" since the value
; is always 0/1) needs no register shuffling between the two calls.
    PUBLIC menu_flip_board
menu_flip_board:
    PUBLIC _menu_flip_board
    defc _menu_flip_board = menu_flip_board
    call _spectrum_gui_is_board_flipped
    ld a,l
    xor 1
    ld l,a
    call _spectrum_gui_set_board_view
    jp saveload_full_redraw
