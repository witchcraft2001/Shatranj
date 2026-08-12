; Overlay entry table for BOARD (SPECTRUM_OVL_BOARD = 1u, plan D7): all
; four entries, same shape as asm/overlay/board/entry_board.asm. Three are
; DEFC aliases straight onto src/spectrum/overlay/board_apply_ovl.c's
; __z88dk_fastcall functions -- the same wrapper-free pattern CONTROL
; already proved in MAME (entry_control_sprinter.asm), since __z88dk_
; fastcall is identical across both z88dk backends. The fourth
; (_board_snapshot_save_ovl_entry) is hand-written inline asm, ported
; verbatim from entry_board.asm:24-43: only byte-copies and reads/writes
; _side_to_move/_castle_rights/_ep_square as plain bytes, platform-neutral.
;
; _side_to_move/_castle_rights/_ep_square are resident symbols (board.c
; globals, S5 substep 3b): bridged from resident_c.map by tools/gen_
; sprinter_overlay_defs.py (OVERLAY_RESIDENT_SYMBOLS), the same funnel
; entry_control_sprinter.asm's build already uses for its own protocol
; constants. LOWRAM_CHESS_BOARD_ADDR is bridged from platform_core's
; sjasmplus symbol table instead (PLATFORM_SYMBOLS) -- it is a fixed
; address (src/sprinter/fixed_layout.json), not a resident-linked symbol,
; matching NETCHESSZX_LOWRAM_CHESS_BOARD_ADDR's role on ZX.

SECTION code_user

PUBLIC _board_apply_ovl_entry
PUBLIC _board_snapshot_save_ovl_entry
PUBLIC _board_snapshot_restore_ovl_entry
PUBLIC _board_undo_restore_ovl_entry
EXTERN _board_apply_trusted_ovl
EXTERN _board_snapshot_restore_ovl
EXTERN _board_undo_restore_ovl
EXTERN _side_to_move
EXTERN _castle_rights
EXTERN _ep_square
EXTERN LOWRAM_CHESS_BOARD_ADDR

    DEFB 4
    DW _board_apply_ovl_entry
    DW _board_snapshot_save_ovl_entry
    DW _board_snapshot_restore_ovl_entry
    DW _board_undo_restore_ovl_entry

DEFC _board_apply_ovl_entry = _board_apply_trusted_ovl

_board_snapshot_save_ovl_entry:
    ; DE = overlay context. Copy the 64 cells and three state bytes directly;
    ; this is the same overlay-local ABI as ZX's entry_board.asm.
    ex de, hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld hl, LOWRAM_CHESS_BOARD_ADDR
    ld bc, 64
    ldir
    ld a, (_side_to_move)
    ld (de), a
    inc de
    ld a, (_castle_rights)
    ld (de), a
    inc de
    ld a, (_ep_square)
    ld (de), a
    ld hl, 1
    ret

DEFC _board_snapshot_restore_ovl_entry = _board_snapshot_restore_ovl

DEFC _board_undo_restore_ovl_entry = _board_undo_restore_ovl
