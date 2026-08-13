; Minimal crt0 for the Sprinter net_frame.c WIN2 C-blob (port.md section
; 3.7/S7, the fourth independently zcc-built image tools/make_sprinter_
; resident.py splices in -- see fixed_layout.json's NET_FRAME_C region and
; platform_primitives.asm's matching ASSERT/DS reservation right before
; OVL_SLOT).
;
; Unlike resident_crt0.asm (the WIN1 resident image, entered once at boot
; via trampoline.asm's JP and running an infinite frame loop from _main),
; this blob has no entry point of its own: nothing ever jumps to
; CRT_ORG_CODE. It is a pure library -- src/sprinter/transport/unet_link.c
; (WIN1) calls its exported nc_* functions directly by fixed address, the
; same way WIN1 already calls net_gate.asm's ng_* routines, via addresses
; tools/gen_sprinter_netframe_defs.py bridges out of this blob's own .map.
; Because nothing ever reaches this file's `start` label, this crt0 does
; NOT rely on it for BSS initialisation either: net_frame.c's own resident
; state is reset by an explicit nc_init() call from WIN1 startup instead
; (the flat image is loaded fresh every boot, same discipline platform_
; primitives.asm's DS-zeroed ng_ state already follows).
;
; `start` still runs crt0_init (z88dk's stock BSS clear, from crt_section.
; inc, reused verbatim) before trapping, purely as a safety net if a stray
; jump ever lands here -- never as the real init path.

    MODULE  sprinter_net_core_crt0

    defc    crt0 = 1
    INCLUDE "zcc_opt.def"

IF !DEFINED_CRT_ORG_CODE
    defc CRT_ORG_CODE = $9D00
ENDIF

    ; SP is already STACK_TOP (WIN1 resident owns it) by the time anything
    ; in WIN2 could conceivably run; crt_init_sp.inc must not touch it.
    defc TAR__register_sp = -1
    defc TAR__clib_exit_stack_size = 32
    INCLUDE "crt/classic/crt_rules.inc"

    org     CRT_ORG_CODE

start:
    call    crt0_init       ; defensive only -- see banner; never the real init path
halt_forever:
    halt
    jr      halt_forever

    INCLUDE "crt/classic/crt_runtime_selection.inc"
    INCLUDE "crt/classic/crt_section.inc"
