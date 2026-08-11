; Overlay entry table for CONTROL (SPECTRUM_OVL_CONTROL = 14u, plan D7):
; one entry, byte-for-byte the same shape as asm/overlay/control/entry_control.asm
; (entry-count byte + word table of absolute addresses), read by
; overlay_loader_sprinter.asm's ovl_dispatch (OVL_SLOT_ADDR = count byte,
; OVL_SLOT_ADDR+1.. = the table). control_ovl.c is the same source ZX links --
; only this entry stub and the link step (z80asm -r0x<OVL_SLOT_ADDR> instead
; of ZX's z80asm -r0x<slot>) are Sprinter-specific.

SECTION code_user

EXTERN _control_classify_ovl

    DEFB 1
    DW _control_classify_ovl_entry

DEFC _control_classify_ovl_entry = _control_classify_ovl
