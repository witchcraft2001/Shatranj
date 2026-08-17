; Overlay entry table for RULES (SPECTRUM_OVL_RULES = 0u, plan D7): three
; entries (SPECTRUM_OVL_RULES_PLAY=0, SPECTRUM_OVL_RULES_CHECK=1,
; SPECTRUM_OVL_HINTS_SHOW=2 -- overlay.h's own shared id, S9), same
; count-byte + word-table shape asm/overlay/rules/entry_rules.asm uses for
; its full four -- entry 3 (SPECTRUM_OVL_HINTS_CLEAR) is not ported: this
; port's hints_clear() (session_sprinter.c) is a pure local mask/repaint
; with no legality recomputation, so it never needs an overlay call (see
; rules_stub_sprinter.asm's own header on entry 2 for the design). Byte-
; for-byte the same entry-table shape overlay_loader_sprinter.asm's
; ovl_dispatch reads for CONTROL (asm/sprinter/zcc/entry_control_
; sprinter.asm) -- the dispatcher is fully generic over table size, so
; this file's own DEFB is the only place the count is recorded.

SECTION code_user

EXTERN _rules_play_ovl
EXTERN _rules_check_ovl
EXTERN _rules_hints_show_ovl

    DEFB 3
    DW _rules_play_ovl
    DW _rules_check_ovl
    DW _rules_hints_show_ovl
