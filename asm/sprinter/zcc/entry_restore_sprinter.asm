; Overlay entry table for RESTORE (SPECTRUM_OVL_RESTORE = 11u, S6 plan step
; 3): byte-for-byte the same shape as asm/overlay/restore/entry_restore.asm.
; src/spectrum/overlay/restore_ovl.c is the same source ZX links, byte-for-
; byte unchanged (a pure b64+CRC codec, no I/O, no platform ifdef at all).
; Both entries are already __z88dk_fastcall(uint8_t *ctx) functions, so this
; is pure DEFC aliasing, no hand-written asm needed (entry_control_
; sprinter.asm's own precedent).

SECTION code_user

EXTERN _restore_build_frame_ovl
EXTERN _restore_decode_ovl

    DEFB 2
    DW _restore_build_frame_ovl_entry  ; SPECTRUM_OVL_RESTORE_BUILD_FRAME = 0
    DW _restore_decode_ovl_entry       ; SPECTRUM_OVL_RESTORE_DECODE = 1

DEFC _restore_build_frame_ovl_entry = _restore_build_frame_ovl
DEFC _restore_decode_ovl_entry = _restore_decode_ovl
