; Dummy overlay for the S3 overlay-mechanism probe (port.md section
; 3.10/S3). Exercises the exact shape ovl_s3.asm's dispatcher drives: 2 KiB
; copied from the asset page into OVL_SLOT via WIN0-under-DI, then
; dispatched with a packed-args ABI byte-for-byte matching the ZX loader
; (asm/esxdos/overlay_loader.asm:54-60) -- context in DE AND HL (native ASM
; entries read DE; a future C fastcall entry would read HL), DI on entry,
; EI on return.
;
; Standalone build product: assembled separately from the resident, ORG'd
; at OVL_SLOT_ADDR so its own internal addresses are correct for wherever
; it actually runs (#7800) -- even though on disk it is packed into the
; asset page at a different byte offset (slot 36, #2400).
; tools/make_sprinter_assets_page.py's --overlay-bin embeds the resulting
; exactly-2048-byte binary there.
;
; Header: DB entry_count(2), DW entry0_addr, DW entry1_addr, DB build_tag.
;
; ovl_ctx layout (16 bytes, ovl_s3.asm/resident_s1.asm):
;   [0..1] caller-supplied args (entry 0 reads them)
;   [2]    entry 0: ctx[0]+ctx[1]
;   [3]    entry 0: ctx[0]^ctx[1]
;   [4]    entry 0: run counter, incremented every dispatch
;   [5]    entry 0: this image's build tag -- proves whether a fresh copy
;          landed or a cached dispatch is still running the old image
;          (tests/sprinter/z80/t_ovl_dispatch.asm mutates the source
;          between two dispatches and checks this byte)
;   [6..7] entry 1: checksum of the whole 2 KiB slot (16-bit wrapping add)
;          -- an independent witness that the copy landed correctly
;   [8]    entry 0: observed IFF2 (0 = DI, as required)
;   [9]    entry 0: 1 if DE==HL on entry, else 0

        DEVICE NOSLOT64K
        INCLUDE "fixed_layout.inc"

DUMMY_OVERLAY_SIZE EQU 2048
DUMMY_OVERLAY_BUILD_TAG EQU #A5

        ORG     OVL_SLOT_ADDR
overlay_header:
        DB      2                       ; entry count
        DW      overlay_entry0
        DW      overlay_entry1
overlay_build_tag:
        DB      DUMMY_OVERLAY_BUILD_TAG

; Entry 0: arg/DI/context self-checks. In: DE=HL=ovl_ctx. Clobbers AF, BC.
overlay_entry0:
        push    hl
        pop     ix                      ; ix = ctx pointer (== hl == de)

        ; ctx[9] = (DE==HL) ? 1 : 0
        ld      a,d
        cp      h
        jr      nz,.mismatch
        ld      a,e
        cp      l
        jr      nz,.mismatch
        ld      a,1
        jr      .store_de_eq
.mismatch:
        xor     a
.store_de_eq:
        ld      (ix+9),a

        ; ctx[8] = observed IFF2 (LD A,I copies IFF2 into P/V)
        ld      a,i
        jp      pe,.iff2_set
        xor     a
        jr      .store_iff2
.iff2_set:
        ld      a,1
.store_iff2:
        ld      (ix+8),a

        ; ctx[2]=ctx[0]+ctx[1], ctx[3]=ctx[0]^ctx[1]
        ld      a,(ix+0)
        ld      b,(ix+1)
        ld      c,a
        add     a,b
        ld      (ix+2),a
        ld      a,c
        xor     b
        ld      (ix+3),a

        ; ctx[4]++ (run counter: increments on every dispatch, cached or
        ; not -- distinct from ctx[5], which only changes when a real
        ; copy actually happened).
        inc     (ix+4)

        ; ctx[5] = this image's build tag.
        ld      a,(overlay_build_tag)
        ld      (ix+5),a

        ret

; Entry 1: checksum of the whole 2 KiB slot into ctx[6..7] (16-bit
; wrapping add). In: DE=HL=ovl_ctx. Clobbers AF, BC, DE, HL.
overlay_entry1:
        push    hl
        pop     ix                      ; ix = ctx pointer

        ld      hl,OVL_SLOT_ADDR
        ld      bc,DUMMY_OVERLAY_SIZE
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

        ld      (ix+6),e
        ld      (ix+7),d
        ret

        ASSERT  $ - OVL_SLOT_ADDR < DUMMY_OVERLAY_SIZE
        DS      OVL_SLOT_ADDR + DUMMY_OVERLAY_SIZE - $, 0
        ASSERT  $ - OVL_SLOT_ADDR = DUMMY_OVERLAY_SIZE

        END     overlay_header
