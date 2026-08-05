; Permanent Sprinter WIN1 base bank.  The PRELOAD loader patches the physical
; runtime page into the transition stub before jumping here.

SECTION code_user

INCLUDE "sprinter_layout.inc"

PUBLIC sprinter_base_transition
PUBLIC sprinter_base_probe
PUBLIC sprinter_base_canary
PUBLIC _overlay_code_slot

DEFC _overlay_code_slot = 0x4000

sprinter_base_transition:
    LD A,0                         ; patched at 0x4001 by the PRELOAD loader
    OUT (0xC2),A                  ; install the permanent WIN2 runtime page
    LD A,(SPRINTER_LOADER_WIN3)
    OUT (0xE2),A                  ; WIN3 is scratch-only after publication
    JP 0x8240

    DEFS 0x0020-$,0

; Used through a generated WIN2 far-call thunk from each diagnostic cold bank.
sprinter_base_probe:
    LD HL,0xBACE
    XOR A
    RET

    DEFS 0x0030-$,0
sprinter_base_canary:
    DEFW 0x5348                   ; "SH"

base_banner:
    DEFB "Shatranj Sprinter base bank",13,10,0
