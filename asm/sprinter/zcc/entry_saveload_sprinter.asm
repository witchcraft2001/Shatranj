; Overlay entry table for SAVELOAD (SPECTRUM_OVL_SAVELOAD = 10u, S6 plan
; step 3): byte-for-byte the same shape as asm/overlay/saveload/
; entry_saveload.asm (entry-count byte + word table of absolute addresses).
; src/spectrum/overlay/saveload_ovl.c is the same source ZX links (its
; SAVELOAD_DIR is the only ifdef'd line, S6 plan step 3); all three entries
; are already __z88dk_fastcall(uint8_t *ctx) functions, so -- like
; entry_control_sprinter.asm -- this is pure DEFC aliasing, no hand-written
; asm needed.

SECTION code_user

EXTERN _saveload_load_nczs_ovl
EXTERN _saveload_save_nczs_ovl
EXTERN _saveload_erase_nczs_ovl

    DEFB 3
    DW _saveload_load_ovl_entry    ; SPECTRUM_OVL_SAVELOAD_LOAD_NCZS = 0
    DW _saveload_save_ovl_entry    ; SPECTRUM_OVL_SAVELOAD_SAVE_NCZS = 1
    DW _saveload_erase_ovl_entry   ; SPECTRUM_OVL_SAVELOAD_ERASE_NCZS = 2

DEFC _saveload_load_ovl_entry = _saveload_load_nczs_ovl
DEFC _saveload_save_ovl_entry = _saveload_save_nczs_ovl
DEFC _saveload_erase_ovl_entry = _saveload_erase_nczs_ovl
