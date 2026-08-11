; Minimal crt0 for the Sprinter resident C image (port.md section 3.10/S5,
; plan D1: the sjasmplus<->z88dk bridge). Assembled by z88dk's own
; z88dk-z80asm (zcc's linker), NOT sjasmplus -- this file and the other
; z80asm-side sources belong in this zcc/ subdirectory precisely so the two
; assembler dialects never mix in one directory.
;
; z88dk's stock crt0 for this target (lib/target/pps/classic/pps_crt0.asm)
; is built for a *standalone DSS EXE*: it embeds a 512-byte DSS EXE header
; (magic, load/stack addresses, PSP) as its very first bytes, then parses
; the DSS-issued PSP for argv. That model does not apply here. The resident
; C is never loaded by DSS's native EXE loader at all: preload_loader.asm
; is the (separate, sjasmplus-built) stage-1 EXE DSS does load, and it
; streams the flat 32 KiB resident page itself via PRELOAD/GETMEM, then JPs
; directly into platform_core's trampoline -- which sets SP=STACK_TOP and
; owns interrupts (IM2 is installed by platform_core, not here) before
; handing off to this crt0's entry. Embedding a DSS EXE header in the
; middle of that flat page would corrupt it.
;
; This crt0 is deliberately narrow: reuse z88dk's own crt0_init (BSS clear
; + the crt_model-0 no-op data copy, both from the stock
; crt/classic/crt_section.inc, included verbatim below) so C globals are
; zeroed the standard way, then call _main with a null argv/argc (the
; resident never receives a DSS command line). No PSP handling, no argv
; parsing, no heap/EI-DI setup, no DSS EXE header -- all of that is either
; unneeded (this is not a spawned DSS program) or owned by platform_core.
;
; Proven by static build+inspection (2026-08-10, D1 de-risk): a probe C
; TU calling one platform_core primitive resolved via a hand-written defc
; compiled and linked to a headerless 203-byte raw image; CRT_ORG_CODE
; landed exactly at the requested address with no EXE magic ahead of it.
; Not yet exercised in MAME/hardware (CLAUDE.md rule 6 -- pending until a
; full resident round-trips through the real trampoline).

    MODULE  sprinter_resident_crt0

    defc    crt0 = 1
    INCLUDE "zcc_opt.def"

    EXTERN  _main

; Overridden per-build via -pragma-define:CRT_ORG_CODE=<addr> once
; src/sprinter/fixed_layout.json's real C-image base is fixed (plan D1/D2);
; this fallback only matters for ad-hoc standalone probes of this file.
IF !DEFINED_CRT_ORG_CODE
    defc CRT_ORG_CODE = $4200
ENDIF

    ; SP is already STACK_TOP by the time platform_core's trampoline JPs
    ; here (fixed_layout.json's STACK region) -- crt_init_sp.inc must not
    ; touch it.
    defc TAR__register_sp = -1
    defc TAR__clib_exit_stack_size = 32
    INCLUDE "crt/classic/crt_rules.inc"

    org     CRT_ORG_CODE

start:
    call    crt0_init       ; BSS clear (crt_section.inc, reused unmodified)
    ld      hl,0
    push    hl              ; argv = NULL
    push    hl              ; argc = 0
    call    _main
    pop     bc
    pop     bc
; _main (the resident's frame loop) is not expected to return; trap here
; rather than falling into whatever follows in memory if it ever does.
halt_forever:
    halt
    jr      halt_forever

    INCLUDE "crt/classic/crt_runtime_selection.inc"
    INCLUDE "crt/classic/crt_section.inc"
