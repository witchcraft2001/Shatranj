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
