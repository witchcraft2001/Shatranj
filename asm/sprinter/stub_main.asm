; Shatranj Sprinter target -- S0 infrastructure stub.
;
; Prints a banner through DSS and exits.  This body is loaded by DSS itself
; via the EXE header PRELOAD path (LOADER field != 0): DSS reads exactly
; LOADER bytes to LD_ADDR = 0x8100 and jumps there with the file handle kept
; open in the PSP.  Stage S1 replaces this body with the real PRELOAD loader
; that streams the resident pages through WIN1 (port.md section 3.2).
;
; Assembled with z88dk-z80asm: -b -r0x8100 (no ORG directive here).

DSS_PCHARS      EQU 0x5C        ; HL = NUL-terminated string
DSS_EXIT        EQU 0x41        ; B = exit code; does not return

stub_main:
        ld      hl,banner
        ld      c,DSS_PCHARS
        rst     0x10
        ld      b,0
        ld      c,DSS_EXIT
        rst     0x10
hang:
        jr      hang            ; DSS.Exit does not return; guard anyway

banner:
        defm    "Shatranj for Sprinter: S0 build-infrastructure stub."
        defb    13,10
        defm    "The game itself arrives with stages S1+ (see port.md)."
        defb    13,10,0
