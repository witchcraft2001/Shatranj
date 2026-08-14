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
; ids (0-14) and now carries TWO tables, because there are two dispatch
; mechanisms (S5 substep 3b, plan D7-bis):
;
;   mode 0 (COPY, plan D2) -- LDIR OVL_SLOT_SIZE bytes from the assets page
;     into OVL_SLOT_ADDR via ovl_copy_slot, dispatch out of the slot. Used
;     by CONTROL (id 14). Unchanged from substep 2, deliberately: this is
;     the path already confirmed end-to-end in MAME, and every instruction
;     of it below is the same one that ran there.
;
;   mode 1 (MAP WIN3) -- map ovl_win3_page into WIN3 with a single OUT and
;     dispatch in place at the overlay's own linked address inside
;     #C000-#FFFF. No copy. Used by RULES (id 0) and BOARD (id 1), whose
;     compiled size (BOARD: 2772 bytes) does not fit the 2 KiB copy slot at
;     all. See the atlas table's own header for which overlays may use this
;     and why these two qualify.
;
; The WIN3 map/restore discipline here is the same one gfx_core.asm and
; text640.asm already use for their VRAM-alias windows: read the current
; value, replace it, and restore THAT value (never a constant) before
; re-enabling interrupts. That is what makes the two compose -- a mode-1
; overlay that calls a resident render primitive gets its own page back on
; return, because the primitive restores what it read rather than assuming
; VRAM. (RULES/BOARD make no such call today; the property is what makes it
; safe for later overlays that do.)

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
    ; Mode-1 (WIN3-mapped) dispatch: the page number(s) published by
    ; buffers.asm's bench_init from HDR (ovl_win3_page2 added S8 step 8b, a
    ; second WIN3 page for the NET overlay -- see ovl_atlas_page_table's own
    ; header for which ids read which cell), and the window port itself
    ; (dss.inc stays the one place that spells #E2).
    EXTERN ovl_win3_page
    EXTERN ovl_win3_page2
    EXTERN WIN3_PORT
    ; The shared overlay-argument buffer (see ovl_ctx's own comment below).
    EXTERN LOWRAM_OVERLAY_CONTEXT_ADDR

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

    cp ovl_atlas_count
    jp nc,ovl_dispatch_fail     ; id >= count: no such overlay

    ; Atlas word. What it MEANS depends on the mode byte read next: a
    ; WIN0-relative source offset (mode 0) or an absolute WIN3-window entry-
    ; table address (mode 1). The bounds check above covers both tables.
    add a,a                     ; *2: word-sized atlas table entries
    ld l,a
    ld h,0
    ld de,ovl_atlas_table
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld (ovl_v_atlas_word),de

    ld a,(ovl_v_requested_id)
    ld l,a
    ld h,0
    ld de,ovl_atlas_mode_table
    add hl,de
    ld a,(hl)
    or a
    jr nz,ovl_map_win3

    ; --- mode 0: copy from the assets page into OVL_SLOT ----------------
    ; Identical to substep 2's dispatch (the MAME-proven path), with the
    ; two fixed OVL_SLOT_ADDR references now going through ovl_v_slot_base
    ; so ovl_dispatch below can serve both modes.
    ld hl,OVL_SLOT_ADDR
    ld (ovl_v_slot_base),hl
    ld hl,ovl_return
    ld (ovl_v_return_addr),hl

    ld hl,ovl_v_loaded_id
    ld a,(ovl_v_requested_id)
    cp (hl)
    jr z,ovl_dispatch           ; already resident: skip the copy

    ld hl,(ovl_v_atlas_word)    ; slot*256 source offset (WIN0-relative)
    call ovl_copy_slot
    jp c,ovl_dispatch_fail      ; no asset page

    ld a,(ovl_v_requested_id)
    ld (ovl_v_loaded_id),a
    jr ovl_dispatch

    ; --- mode 1: map ovl_win3_page into WIN3 and dispatch in place ------
    ; No copy, so ovl_v_loaded_id is deliberately left alone: it tracks
    ; what physically sits in OVL_SLOT, which this path never disturbs, so
    ; a later mode-0 dispatch of an already-copied overlay still correctly
    ; skips its own copy.
ovl_map_win3:
    ; S8 step 8b: which page CELL to read is per-id now (ovl_win3_page for
    ; every id already on page 1, ovl_win3_page2 for NET) -- ovl_atlas_
    ; page_table holds the cell's ADDRESS, not its value, so this is an
    ; extra indirection ahead of the same "#FF means unavailable" check the
    ; single-page version already did.
    ld a,(ovl_v_requested_id)
    add a,a
    ld l,a
    ld h,0
    ld de,ovl_atlas_page_table
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                  ; de = address of this id's page cell
    ld a,(de)
    cp 0xFF
    jp z,ovl_dispatch_fail      ; no overlay page published (HDR < 4/6 pages)
    ld b,a
    di                          ; R7: WIN3 replaced only under DI, whole
                                ; duration, restored before EI
    in a,(WIN3_PORT)
    ld (ovl_v_saved_win3),a
    ld a,b
    out (WIN3_PORT),a
    ld a,1
    ld (ovl_v_win3_mapped),a

    ld hl,(ovl_v_atlas_word)    ; absolute entry-table address in WIN3
    ld (ovl_v_slot_base),hl
    ld hl,ovl_return_win3
    ld (ovl_v_return_addr),hl

ovl_dispatch:
    ld a,(ovl_v_requested_entry)
    ld hl,(ovl_v_slot_base)      ; entry count byte
    cp (hl)
    jr nc,ovl_dispatch_fail      ; entry_id >= count

    add a,a                      ; *2: word-sized table entries
    ld e,a
    ld d,0
    inc hl                       ; past the count byte
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                    ; de = entry target address

    ld hl,(ovl_v_return_addr)
    push hl
    push de                      ; entry target, to be RET'd into
    ld de,ovl_ctx
    ld hl,ovl_ctx
    di
    ret

ovl_return:
    ei
    ret

; Mode-1 return trampoline: unmap WIN3 before re-enabling interrupts.
; Preserves HL (the C return value) and, via push/pop af, the flags the
; entry left -- ovl_return's own contract, just with the window put back.
ovl_return_win3:
    push af
    xor a
    ld (ovl_v_win3_mapped),a
    ld a,(ovl_v_saved_win3)
    out (WIN3_PORT),a
    pop af
    ei
    ret

ovl_dispatch_fail:
    ; Reachable with WIN3 already mapped (a bad entry id on a mode-1
    ; overlay), so undo that first -- restoring the value that was read,
    ; never a constant.
    ld a,(ovl_v_win3_mapped)
    or a
    jr z,ovl_fail_ret
    xor a
    ld (ovl_v_win3_mapped),a
    ld a,(ovl_v_saved_win3)
    out (WIN3_PORT),a
    ei
ovl_fail_ret:
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

; Overlay call context: NOT a buffer this file owns. It is the fixed
; low-RAM region LOWRAM_OVERLAY_CONTEXT (src/sprinter/fixed_layout.json,
; #B32F, 8 bytes, ABI-contractual size), which is the same address the
; portable resident C reaches through src/spectrum/overlay/overlay_context.h's
; `spectrum_overlay_context` macro. Both sides MUST name the same bytes:
; the resident writes the arguments there, this loader hands that address
; to the entry in DE/HL, and the entry reads them back.
;
; This was a real bug, fixed 2026-08-11 after the first MAME run of P12
; (docs/sprinter-testnotes/S5.md): ovl_ctx used to be a private 16-byte BSS
; buffer here (at #5875, inside the C image), while board.c wrote its
; arguments to #B32F. Nothing caught it because the only caller until then
; was main.c's CONTROL probe, which wrote through THIS name rather than the
; portable one -- so the two addresses never had to agree. RULES then read
; whatever main.c had last left in the private buffer (a pointer to the
; string "MOVE e2e4") as its board pointer and answered "illegal" for every
; move. tests/tools/test_sprinter_overlay_dispatch.py now pins the two
; together so a future divergence fails the build instead of the board.
    PUBLIC ovl_ctx
    defc ovl_ctx = LOWRAM_OVERLAY_CONTEXT_ADDR
    PUBLIC _ovl_ctx
    defc _ovl_ctx = LOWRAM_OVERLAY_CONTEXT_ADDR

    SECTION bss_user

; Portable-API aliases (S5 substep 3b): src/spectrum/board/board.c calls
; the cross-platform names src/spectrum/overlay/overlay.h declares --
; spectrum_overlay_exec(ovl_id, entry_id)/spectrum_overlay_exec_cached(...)
; -- not this file's own ovl_exec/ovl_exec_cached names (the only caller
; before board.c was linked in, main.c's CONTROL probe, calls ovl_exec
; directly by its own C-visible _ovl_exec alias above). Same two-uint8_t-
; args classic-ABI shape ovl_exec/ovl_exec_cached already implement --
; board.c's own argument order (ovl_id first, entry_id second) matches
; exactly. Placed here, after both ovl_exec: and ovl_exec_cached: are
; fully defined, not forward-declared next to them -- this file's own
; header explains why a defc alias ahead of its target's definition is
; a latent bug (ovl_ctx's own history), not a style choice.
    PUBLIC _spectrum_overlay_exec
    defc _spectrum_overlay_exec = ovl_exec
    PUBLIC _spectrum_overlay_exec_cached
    defc _spectrum_overlay_exec_cached = ovl_exec_cached

ovl_v_requested_id:   defb 0
ovl_v_requested_entry: defb 0

; Per-dispatch state resolved from the atlas (S5 substep 3b's two modes):
; the raw atlas word, the base address the entry table is read from
; (OVL_SLOT_ADDR in mode 0, the WIN3 link address in mode 1), and which
; return trampoline the entry RETs into.
ovl_v_atlas_word:  defw 0
ovl_v_slot_base:   defw 0
ovl_v_return_addr: defw 0

; WIN3 bookkeeping for mode 1. ovl_v_win3_mapped must start 0 (BSS zero-fill
; gives that) so the very first ovl_dispatch_fail cannot wrongly "restore"
; WIN3 from an unset saved value.
ovl_v_saved_win3:  defb 0
ovl_v_win3_mapped: defb 0
