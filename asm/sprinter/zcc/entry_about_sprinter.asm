; Overlay entry table for ABOUT (SPECTRUM_OVL_ABOUT = 12u, S9 About pass),
; page 2 of the WIN3 overlay window (tools/make_sprinter_overlay_page.py's
; LAYOUT2). One entry -- SPECTRUM_OVL_ABOUT_RENDER = 0, the same id ZX/Next
; reserve on this overlay (src/spectrum/overlay/overlay.h).
;
; The entry is a uint8_t f(uint8_t *ctx) __z88dk_fastcall (ctx in HL, result
; in L), same shape as every other Sprinter overlay entry; the body is asm
; rather than C, so this is a straight alias with no thunk -- see
; about_sprinter.asm's own header for why it is asm.

SECTION code_user

EXTERN _about_render_ovl

    DEFB 1
    DW _about_render_ovl_entry              ; SPECTRUM_OVL_ABOUT_RENDER = 0

DEFC _about_render_ovl_entry = _about_render_ovl
