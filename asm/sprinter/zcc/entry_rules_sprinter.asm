; Overlay entry table for RULES (SPECTRUM_OVL_RULES = 0u, plan D7): two
; entries (SPECTRUM_OVL_RULES_PLAY=0, SPECTRUM_OVL_RULES_CHECK=1), same
; count-byte + word-table shape asm/overlay/rules/entry_rules.asm uses for
; its full four -- only entries 0/1 are ported to Sprinter (see rules_stub_
; sprinter.asm's own header for why 2/3 are not). Byte-for-byte the same
; entry-table shape overlay_loader_sprinter.asm's ovl_dispatch reads for
; CONTROL (asm/sprinter/zcc/entry_control_sprinter.asm).

SECTION code_user

EXTERN _rules_play_ovl
EXTERN _rules_check_ovl

    DEFB 2
    DW _rules_play_ovl
    DW _rules_check_ovl
