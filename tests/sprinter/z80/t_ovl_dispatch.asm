; z80 unit test for asm/sprinter/ovl_s3.asm's ovl_exec/ovl_exec_cached
; against the real asm/sprinter/dummy_overlay.asm (INCLUDEd here, ORG'd at
; OVL_SLOT_ADDR exactly as it is in the resident image -- its entry code
; must be assembled at its eventual run address so self-references like
; "ld a,(overlay_build_tag)" stay correct after being LDIR-copied verbatim
; by the dispatcher under test; see the file's own banner).
;
; This test's own job is emitting the "source image at #2400" the plan
; describes: it snapshots the pristine dummy-overlay bytes assembled above
; into scratch (SCRATCH_V1 = "source v1"), derives SCRATCH_V2 by poking a
; different build-tag byte into a copy of it ("source v2" -- a mutated
; source, without needing a second real assembly), then stages whichever
; version is needed at #2400 before each dispatch. The flat z88dk-ticks
; model makes win0_map_di's OUT a no-op, so plain memory at #2400 already
; is "the WIN0-mapped view" as far as ovl_exec_cached's LDIR is concerned.
;
; Scenarios: copy+checksum (an independently-computed sum, not overlay_
; entry1's own code path), packed-args unpacking (SP+2/SP+3 -> ovl_id/
; entry_id), DE==HL context, DI-entry/EI-return, the cache asymmetry
; (ovl_exec_cached must NOT observe a source mutation; ovl_exec must), a
; bad entry_id (error, ovl_ctx untouched), and OVL_SLOT staying byte-
; identical to the cached version across a cache-hit dispatch.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; ovl_s3.asm references these (bench_s2.asm/gfx_core.asm/font_hex.asm/
; resident_s1.asm symbols, none included here -- this test drives
; ovl_exec/ovl_exec_cached directly, never ovl_probe).
bench_asset_page:   DB 0
glyph_dest_base:    DW 0
front_base:         DW 0
resolve_buffers:    ret
draw_hex16:         ret
restore_glyph_base: ret
ovl_ctx: DS 16, 0

; Pure-arithmetic helpers, independent of overlay_entry1's own code path.
;
; HL, DE = two buffers, BC = length. Z if byte-identical. Clobbers AF, BC,
; DE, HL.
memcmp_equal:
.loop:
        ld      a,(de)
        cp      (hl)
        ret     nz
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.loop
        ret

; HL=source, BC=length. Out: DE=16-bit wrapping sum. Clobbers AF, BC, DE, HL.
memsum_16:
        ld      de,0
.loop:
        ld      a,(hl)
        add     a,e
        ld      e,a
        jr      nc,.noc
        inc     d
.noc:
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.loop
        ret

SCRATCH_V1          EQU #9000
SCRATCH_V2           EQU #9800
SCRATCH_CTX_SNAPSHOT EQU #A000
CORRUPT_FILL          EQU #CC

start:
        ld      sp,#e800
        call    t_begin

        ; Snapshot the pristine template into SCRATCH_V1 ("source v1").
        ld      hl,OVL_SLOT_ADDR
        ld      de,SCRATCH_V1
        ld      bc,DUMMY_OVERLAY_SIZE
        ldir

        ; SCRATCH_V2 = a copy of v1 with a different build tag ("source
        ; v2" -- a mutated source; the entry code itself is unchanged).
        ld      hl,SCRATCH_V1
        ld      de,SCRATCH_V2
        ld      bc,DUMMY_OVERLAY_SIZE
        ldir
        ld      a,#22
        ld      (SCRATCH_V2 + (overlay_build_tag - OVL_SLOT_ADDR)),a

        ; Corrupt OVL_SLOT so a later "the copy landed" check cannot pass
        ; by accident (leftover assembly-time content already correct).
        ld      hl,OVL_SLOT_ADDR
        ld      (hl),CORRUPT_FILL
        ld      de,OVL_SLOT_ADDR+1
        ld      bc,DUMMY_OVERLAY_SIZE-1
        ldir

        ; --- ovl_exec (always fresh): stage v1 at #2400, dispatch entry 0
        ; with caller args ctx[0]=7, ctx[1]=3. --------------------------
        ld      hl,SCRATCH_V1
        ld      de,#2400
        ld      bc,DUMMY_OVERLAY_SIZE
        ldir

        ld      hl,ovl_ctx
        ld      (hl),7
        inc     hl
        ld      (hl),3

        ld      l,0                     ; ovl_id (reserved, ignored)
        ld      h,0                     ; entry_id = 0
        push    hl
        call    ovl_exec
        pop     hl
        ld      a,1
        call    t_expect_nc

        ; Copy landed: OVL_SLOT now matches staged source v1 exactly.
        ld      hl,OVL_SLOT_ADDR
        ld      de,SCRATCH_V1
        ld      bc,DUMMY_OVERLAY_SIZE
        call    memcmp_equal
        ld      a,2
        call    t_expect_z

        ld      a,(ovl_ctx+2)           ; sum = ctx[0]+ctx[1] = 7+3
        cp      10
        ld      a,3
        call    t_expect_z
        ld      a,(ovl_ctx+3)           ; xor = ctx[0]^ctx[1] = 7^3
        cp      4
        ld      a,4
        call    t_expect_z
        ld      a,(ovl_ctx+8)           ; observed IFF2: 0 = DI on entry
        or      a
        ld      a,5
        call    t_expect_z
        ld      a,(ovl_ctx+9)           ; DE==HL context
        cp      1
        ld      a,6
        call    t_expect_z
        ld      a,(ovl_ctx+5)           ; build tag: v1
        cp      DUMMY_OVERLAY_BUILD_TAG
        ld      a,7
        call    t_expect_z
        ld      a,(ovl_ctx+4)           ; run counter: first dispatch
        cp      1
        ld      a,8
        call    t_expect_z

        ; Interrupts back on after return (ovl_return's EI) -- checked
        ; from the test's own context immediately after the call.
        ld      a,i
        jp      pe,.iff_ok
        xor     a
        jr      .iff_store
.iff_ok:
        ld      a,1
.iff_store:
        cp      1
        ld      a,9
        call    t_expect_z

        ; --- entry 1: checksum vs an independently-computed sum. -------
        ld      l,0
        ld      h,1                     ; entry_id = 1
        push    hl
        call    ovl_exec_cached         ; same id as above: cache hit
        pop     hl
        ld      a,10
        call    t_expect_nc

        ld      hl,SCRATCH_V1
        ld      bc,DUMMY_OVERLAY_SIZE
        call    memsum_16
        push    de
        ld      hl,(ovl_ctx+6)
        pop     de
        or      a
        sbc     hl,de
        ld      a,11
        call    t_expect_z

        ; --- Cache test: stage v2 (mutated tag) at #2400, dispatch via
        ; ovl_exec_cached with the SAME id -- must be a cache hit: no
        ; recopy, old tag, OVL_SLOT still == v1. -------------------------
        ld      hl,SCRATCH_V2
        ld      de,#2400
        ld      bc,DUMMY_OVERLAY_SIZE
        ldir

        ld      l,0
        ld      h,0                     ; entry_id = 0
        push    hl
        call    ovl_exec_cached
        pop     hl
        ld      a,12
        call    t_expect_nc

        ld      a,(ovl_ctx+5)
        cp      DUMMY_OVERLAY_BUILD_TAG ; still the OLD tag: no recopy
        ld      a,13
        call    t_expect_z

        ld      hl,OVL_SLOT_ADDR
        ld      de,SCRATCH_V1
        ld      bc,DUMMY_OVERLAY_SIZE
        call    memcmp_equal            ; slot untouched: still == v1
        ld      a,14
        call    t_expect_z

        ld      a,(ovl_ctx+4)           ; run counter still advances --
        cp      2                       ; dispatch happened, only the copy
        ld      a,15                    ; was skipped (only entry 0
        call    t_expect_z              ; increments it: disp 1 and this
                                         ; one; the entry-1 dispatch above
                                         ; does not touch ctx[4])

        ; --- Same source (still v2 at #2400), but ovl_exec (always
        ; fresh) -- must observe the mutation this time. -----------------
        ld      l,0
        ld      h,0                     ; entry_id = 0
        push    hl
        call    ovl_exec
        pop     hl
        ld      a,16
        call    t_expect_nc

        ld      a,(ovl_ctx+5)
        cp      #22                     ; the NEW tag: recopy happened
        ld      a,17
        call    t_expect_z

        ld      hl,OVL_SLOT_ADDR
        ld      de,SCRATCH_V2
        ld      bc,DUMMY_OVERLAY_SIZE
        call    memcmp_equal            ; slot now matches v2
        ld      a,18
        call    t_expect_z

        ; --- Bad entry_id: error, ovl_ctx completely untouched. --------
        ld      hl,ovl_ctx
        ld      de,SCRATCH_CTX_SNAPSHOT
        ld      bc,16
        ldir

        ld      l,0
        ld      h,5                     ; only entries 0,1 exist
        push    hl
        call    ovl_exec_cached
        pop     hl
        push    af                      ; preserve the real A/CF: t_expect_c
        ld      a,19                    ; below clobbers A for the assertion
        call    t_expect_c              ; id, and cp needs the original A
        pop     af
        cp      OVL_ERR_BAD_ENTRY
        ld      a,20
        call    t_expect_z

        ld      hl,ovl_ctx
        ld      de,SCRATCH_CTX_SNAPSHOT
        ld      bc,16
        call    memcmp_equal
        ld      a,21
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

        include "fixed_layout.inc"
        include "render_layout.inc"
        include "win0.inc"
        include "ovl_s3.asm"

        ; sjasmplus does not pad --raw output across a forward ORG gap
        ; (resident_s1.asm's own banner note): dummy_overlay.asm's ORG
        ; OVL_SLOT_ADDR jumps far ahead of where this file's own content
        ; ends, and without an explicit bridge the skipped bytes shift
        ; every later file offset out from under its intended memory
        ; address -- exactly the hazard that note describes.
        DS      OVL_SLOT_ADDR - $, 0
        ASSERT  $ = OVL_SLOT_ADDR

        ; dummy_overlay.asm ends with its own END directive (sjasmplus
        ; treats END as ending the WHOLE assembly, even reached via an
        ; INCLUDE -- confirmed empirically, not just documentation), so it
        ; must be the LAST thing included; nothing after this line is ever
        ; assembled. That END's own target (overlay_header) becomes this
        ; whole test binary's entry point instead of `start` -- harmless
        ; here since z88dk-ticks is launched with an explicit -pc 0, not
        ; the assembler-recorded entry point.
        include "dummy_overlay.asm"
