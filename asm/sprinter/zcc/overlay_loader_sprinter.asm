; Overlay dispatcher (port.md section 3.10/S5 substep 2, plan D1/D2/D7).
; z88dk-z80asm module, linked alongside the C image (not sjasmplus, unlike
; platform_primitives.asm) -- assembled together with src/sprinter/*.c by
; the same zcc invocation.
;
; Same DISPATCH ABI as asm/esxdos/overlay_loader.asm (context pointer in
; BOTH DE and HL -- native ASM entries read DE; a future C fastcall entry
; would read HL --, DI on entry, `ovl_return: ei/ret`). The CALLER-side
; argument layout is NOT byte-for-byte the same, and must not be assumed to
; be: ZX/Next's ovl_exec is called from SDCC (-clib=sdcc_iy), which packs
; each uint8_t argument into its own stack byte (SP+2=ovl_id, SP+3=
; entry_id); this file is called from z88dk's *classic* compiler
; (-clib=default, the only option for +pps -- sdcc_iy is unavailable here,
; see port.md), whose Small-C-derived convention promotes every scalar
; argument to a full 16-bit stack slot regardless of C type, pushed in
; left-to-right source order. For `ovl_exec(ovl_id, entry_id)` that means:
; entry_id (pushed last) lands nearest the return address, its value in the
; LOW byte at SP+2 and a zero padding byte at SP+3; ovl_id (pushed first)
; lands past it, value at SP+4, padding at SP+5. Verified 2026-08-10 by
; compiling a probe call with this exact toolchain and inspecting the
; generated .asm (`ld hl,14 / push hl / ld l,0 / push hl / call _ovl_exec`)
; -- not a assumption ported over from the ZX side. Getting this wrong is
; what caused the first MAME boot to dispatch overlay id 0 (RULES,
; unported, atlas placeholder pointing at raw font-page bytes) instead of
; 14 (CONTROL) and jump into asset data as code.
;
; The WIN0 copy itself (win0_map_di/LDIR/win0_restore) is NOT inlined
; here -- it can't be, this file is not sjasmplus and cannot use
; win0.inc's MACROs, and R1 requires every WIN0_PORT write to go through
; win0_map_di/win0_restore, which tools/check_sprinter_win0.py enforces
; by scanning asm/sprinter/*.asm source text (this file lives in
; asm/sprinter/zcc/, outside that scan). platform_primitives.asm's
; ovl_copy_slot (plan D1) is the funnel: this file only decides WHICH
; slot to copy (via the atlas table) and calls it.
;
; overlay_atlas_table_sprinter.asm is dense across all 15 defined overlay
; ids (0-14): id 14 (CONTROL) is real, ids 0-13 are unported placeholders
; pointing at the font asset page (harmless only because nothing
; dispatches those ids yet -- see that file's own header for detail).

    MODULE overlay_loader_sprinter

    PUBLIC ovl_exec
    PUBLIC ovl_exec_cached
    PUBLIC ovl_return

    ; Underscored aliases (z88dk C always references externs with a
    ; leading underscore, matching platform_defs.asm's own PUBLIC name /
    ; PUBLIC _name pairing) are declared right next to each real label
    ; below (ovl_exec:, ovl_ctx:), NOT here. Verified 2026-08-10: a
    ; `defc _name = name` declared here, ahead of name's own definition,
    ; silently resolves against whatever the assembler's location counter
    ; was at THIS point instead of name's real final address once name
    ; lives in a later section (bit ovl_ctx, in SECTION bss_user, while
    ; this preamble is unsectioned) -- ovl_ctx's case did exactly that:
    ; _ovl_ctx resolved to ovl_atlas_table's address instead of ovl_ctx's
    ; own, so main.c's writes to ovl_ctx[0..1] silently landed on the
    ; atlas table instead, leaving the real ovl_ctx buffer zeroed and
    ; control_classify_ovl reading a null payload pointer -- the direct
    ; cause of the classify-always-fails (red) result on real hardware.
    ; ovl_exec's own forward alias happened to resolve correctly (both are
    ; in code_user), which is what let this hide until execution, not
    ; link time.

    EXTERN ovl_copy_slot
    EXTERN OVL_SLOT_ADDR

    INCLUDE "overlay_atlas_table_sprinter.asm"

OVL_ERR_BAD_ENTRY EQU 0xFF

    SECTION code_user

; SP+4=ovl_id (reserved), SP+2=entry_id (see the file banner for why these
; offsets, not SP+2/SP+3). Unconditionally invalidates the cache marker
; first, so the shared logic below always re-copies.
    PUBLIC _ovl_exec
    defc _ovl_exec = ovl_exec
ovl_exec:
    ld a,0xFF                  ; not a valid id -- forces a copy
    ld (ovl_v_loaded_id),a

; SP+4=ovl_id, SP+2=entry_id. Copies only if ovl_v_loaded_id != ovl_id.
; Out (bad entry_id only): A=OVL_ERR_BAD_ENTRY, CF=1, dispatch never
; happens. Otherwise runs the entry (DI on entry, EI on return via
; ovl_return) and returns whatever it left in the registers, CF=0.
ovl_exec_cached:
    ld hl,2
    add hl,sp
    ld a,(hl)                  ; SP+2: entry_id's low byte
    ld (ovl_v_requested_entry),a
    inc hl
    inc hl                     ; skip SP+3's zero padding byte
    ld a,(hl)                  ; SP+4: ovl_id's low byte
    ld (ovl_v_requested_id),a

    ld hl,ovl_v_loaded_id
    ld a,(ovl_v_requested_id)
    cp (hl)
    jr z,ovl_dispatch           ; already resident: skip the copy

    ld a,(ovl_v_requested_id)
    cp ovl_atlas_count
    jr nc,ovl_dispatch_fail     ; id >= count: no such overlay

    add a,a                     ; *2: word-sized atlas table entries
    ld l,a
    ld h,0
    ld de,ovl_atlas_table
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; de = slot*256 source offset (WIN0-relative)
    ex de,hl
    call ovl_copy_slot
    jr c,ovl_dispatch_fail      ; no asset page

    ld a,(ovl_v_requested_id)
    ld (ovl_v_loaded_id),a

ovl_dispatch:
    ld a,(ovl_v_requested_entry)
    ld hl,OVL_SLOT_ADDR          ; entry count byte
    cp (hl)
    jr nc,ovl_dispatch_fail      ; entry_id >= count

    add a,a                      ; *2: word-sized table entries
    ld e,a
    ld d,0
    ld hl,OVL_SLOT_ADDR+1
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                    ; de = entry target address

    ld hl,ovl_return
    push hl
    push de                      ; entry target, to be RET'd into
    ld de,ovl_ctx
    ld hl,ovl_ctx
    di
    ret

ovl_return:
    ei
    ret

ovl_dispatch_fail:
    ld a,OVL_ERR_BAD_ENTRY
    scf
    ret

; ovl_v_loaded_id needs its 0xFF ("nothing loaded yet") initial value to
; actually land in the binary -- BSS is zero-filled at load, and 0x00 is a
; real overlay id (atlas entry 0), which would make the very first
; ovl_exec_cached call (bypassing ovl_exec's unconditional invalidate)
; wrongly believe overlay 0 is already resident. SECTION data_user, not
; bss_user, for this one variable only.
    SECTION data_user

    PUBLIC ovl_v_loaded_id
ovl_v_loaded_id: defb 0xFF

    SECTION bss_user

; Context buffer, WIN2-resident by construction (this file links into the
; C image's WIN1 half, but ovl_ctx itself is small state, not code -- kept
; here rather than duplicating platform_primitives.asm's WIN2 placement
; discipline for a single 16-byte buffer; nothing here survives an
; l_call the way net_gate.asm's own state must, so WIN1 residency is fine).
    PUBLIC ovl_ctx
ovl_ctx: defs 16,0
    PUBLIC _ovl_ctx
    defc _ovl_ctx = ovl_ctx

ovl_v_requested_id:   defb 0
ovl_v_requested_entry: defb 0
