; Minimal crt0 for the Sprinter WIN3 cold-code page (S7 step 4 byte-budget
; ladder). Direct clone of net_core_crt0.asm -- same "pure library, nothing
; ever enters here" shape, different home: this image is linked at #C000
; and shipped as a whole 16 KiB asset page (tools/make_sprinter_cold_page.
; py) rather than spliced into the resident, because it is mapped into WIN3
; on demand instead of living in the always-mapped WIN1/WIN2 halves.
;
; What is in it: asm/sprinter/zcc/render_core.asm + render_core_cold.asm
; (every board/HUD/FILEUI painter) and, since S7 step 5, the C modules that
; are not in the hot render cycle -- src/spectrum/ui/gui.c first. See
; render_core.asm's header for why WIN3 placement is safe for rendering
; code specifically (it is not safe for the WIN0 window, and that asymmetry
; is the whole subtlety).
;
; ENTRY TABLE (S7 step 5). The first bytes of the image are a generated
; `jp` table, one slot per name in tools/gen_sprinter_cold_thunks.py's
; ordered allowlist, so entry i is at $C000+3*i no matter where the linker
; puts the body behind it. That fixed contract is what lets the WIN1 thunks
; be generated WITHOUT this build's .map -- which in turn lets this page be
; built AFTER resident_c.bin and call back into it (the defc bridge
; tools/gen_sprinter_cold_defs.py generates). Before the table existed the
; page could only hold leaf code; gui.c, which calls the session config and
; text.c, could not have moved at all. The table's placement is re-checked
; against the built .map on every build (`--mode verify`), so an
; accidentally-relocated table fails the build instead of dispatching into
; the middle of a routine.
;
; Like net_core_crt0.asm this crt0 has no real entry point: nothing ever
; jumps to `start`, which now sits just past the table rather than at
; CRT_ORG_CODE. It still runs crt0_init before trapping, purely as a safety
; net if a stray jump ever lands there -- never as the real init path. The
; page image is loaded fresh from the EXE every boot, so its data/bss bytes
; are already whatever tools/make_sprinter_cold_page.py packed (zero fill
; past the linked image).

    MODULE  sprinter_cold_page_crt0

    defc    crt0 = 1
    INCLUDE "zcc_opt.def"

IF !DEFINED_CRT_ORG_CODE
    defc CRT_ORG_CODE = $C000
ENDIF

    ; SP is already STACK_TOP (WIN1 resident owns it) by the time anything
    ; in this page could conceivably run; crt_init_sp.inc must not touch it.
    defc TAR__register_sp = -1
    defc TAR__clib_exit_stack_size = 32
    INCLUDE "crt/classic/crt_rules.inc"

    org     CRT_ORG_CODE

    ; MUST stay the very first thing emitted at CRT_ORG_CODE -- the WIN1
    ; thunks call $C000+3*i by construction (see banner).
    INCLUDE "cold_entry_table.inc"

start:
    call    crt0_init       ; defensive only -- see banner; never the real init path
halt_forever:
    halt
    jr      halt_forever

    INCLUDE "crt/classic/crt_runtime_selection.inc"
    INCLUDE "crt/classic/crt_section.inc"
