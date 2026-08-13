; Overlay entry table for FILEUI (SPECTRUM_OVL_FILEUI = 13u, S6 plan step
; 4): byte-for-byte the same shape as asm/overlay/fileui/entry_fileui.asm.
; src/spectrum/overlay/fileui_ovl.c is the same source ZX links (one
; ifdef'd line, its own fileui_dir -> spectrum_platform_save_dir() branch,
; same S6 decision as saveload_ovl.c's own SAVELOAD_DIR). Both entries are
; already __z88dk_fastcall(uint8_t *ctx) functions, so this is pure DEFC
; aliasing, no hand-written asm needed (entry_control_sprinter.asm's own
; precedent).

SECTION code_user

EXTERN _fileui_render_ovl
EXTERN _fileui_pick_ovl

    DEFB 2
    DW _fileui_render_ovl_entry    ; SPECTRUM_OVL_FILEUI_RENDER = 0
    DW _fileui_pick_ovl_entry      ; SPECTRUM_OVL_FILEUI_PICK = 1

DEFC _fileui_render_ovl_entry = _fileui_render_ovl
DEFC _fileui_pick_ovl_entry = _fileui_pick_ovl
