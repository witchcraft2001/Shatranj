; z80 unit test for asm/sprinter/gfx_core.asm's gfx_draw_tile.
;
; z88dk-ticks' flat model has no Sprinter accelerator or MMU (win0_map_di's
; OUT (WIN0_PORT),a is an ordinary no-op port write there), so tile_src_slot
; addresses source data directly in the flat 64 KiB image (slot*256), and
; ACC_COPY_H's trigger (LD A,(HL) / LD (DE),A) only ever copies the ONE byte
; it literally executes -- the accelerator burst that would copy the rest of
; a real row, and the row-to-row destination stepping PORT_Y would do on
; hardware, never happen here. Since gfx_draw_tile's destination address is
; constant across rows (by design -- PORT_Y selects the row on real
; hardware) and DE is never reloaded inside the row loop, every row's
; single-byte write lands at the SAME destination address in this model, so
; only the LAST row's source byte survives to be observed. That is exactly
; what makes the source-pointer STRIDE arithmetic (HL += stride, once per
; row) provable here: if it were wrong -- e.g. the donor's original 8-bit-
; only "add a,16" trick, which wraps L without carrying into H once
; stride*rows exceeds 255 -- the wrong row's byte would land at the
; destination instead. stride=20/rows=20 (400 > 255) is exactly the case
; that trick gets wrong; stride=16/rows=16 (240 <= 255) would not have
; caught it, so both are tested.
;
; The hardware #FF transparency key (VRAM_ALIAS_KEY) is a WIN3-alias effect
; with no CPU-visible consequence in this model (the OUT to WIN3_PORT is a
; no-op here too): an #FF source byte is still literally copied through.
; That the alias parameter is read and applied is exercised below; whether
; the hardware actually treats it as a transparency key is unverifiable
; outside MAME/hardware (port.md "Риски", matching accel_smoke's own
; precedent for accelerator-dependent behaviour).

        device noslot64k
        org 0
        jp start
        include "harness.inc"

start:
        ld      sp,#e800
        call    t_begin

        ; Source fixtures live far above any code/harness address this
        ; small test could reach (org 0, well under 32 KiB assembled), so
        ; there is no risk of the LDIRs below clobbering the program itself.

        ; --- 32x16 tile, stride=16, rows=16 (240 <= 255: does not stress
        ; the 8-bit-wraparound bug, but proves the basic row walk).
        ld      hl,tile16_fixture
        ld      de,#d000                ; slot #d0
        ld      bc,16*16
        ldir

        ld      hl,#c000
        ld      de,#c001
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      hl,#c000
        ld      (tile_dest_base),hl
        xor     a
        ld      (tile_x_byte),a
        ld      a,40
        ld      (tile_y),a
        xor     a
        ld      (tile_src_page),a       ; irrelevant in the flat model
        ld      a,#d0
        ld      (tile_src_slot),a       ; slot #d0 -> #d000
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,16
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        call    gfx_draw_tile

        ld      a,(#c000)               ; last row (15) marker
        cp      #77
        ld      a,1
        call    t_expect_z

        ; --- 40x20 tile, stride=20, rows=20 (19*20 = 380 > 255): the case
        ; that catches an 8-bit-only stride bug.
        ld      hl,tile20_fixture
        ld      de,#d100                ; slot #d1 (right after the 256-byte
                                         ; block above, no overlap)
        ld      bc,20*20
        ldir

        ld      hl,#c100
        ld      de,#c101
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      hl,#c100
        ld      (tile_dest_base),hl
        xor     a
        ld      (tile_x_byte),a
        ld      a,60
        ld      (tile_y),a
        xor     a
        ld      (tile_src_page),a
        ld      a,#d1                   ; slot #d1 -> #d100
        ld      (tile_src_slot),a
        ld      a,20
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,20
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_OPAQUE
        ld      (tile_alias),a
        call    gfx_draw_tile

        ld      a,(#c100)               ; last row (19) marker
        cp      #66
        ld      a,2
        call    t_expect_z

        ; --- hardware-key alias parameter: an #FF source byte is copied
        ; through unchanged in this model (see the file banner).
        ld      hl,#c200
        ld      (hl),#a5
        ld      a,#ff
        ld      (#d000),a               ; slot #d0, row 0 (rows=1 below)

        ld      hl,#c200
        ld      (tile_dest_base),hl
        xor     a
        ld      (tile_x_byte),a
        ld      a,10
        ld      (tile_y),a
        xor     a
        ld      (tile_src_page),a
        ld      a,#d0
        ld      (tile_src_slot),a
        ld      a,16
        ld      (tile_width),a
        ld      (tile_stride),a
        ld      a,1
        ld      (tile_rows),a
        ld      a,VRAM_ALIAS_KEY
        ld      (tile_alias),a
        call    gfx_draw_tile

        ld      a,(#c200)
        cp      #ff
        ld      a,3
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

; Row-major, one marker byte at each row's start offset (row i at i*16);
; filler elsewhere is irrelevant (only one byte per row is ever latched by
; the trigger in this flat model). Row 15 (the last) carries the #77
; marker gfx_draw_tile's dest byte must end up holding.
tile16_fixture:
        REPT 15
        DB #99,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00
        ENDR
        DB #77,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00

; Same idea, stride 20: row 19 (the last) carries the #66 marker.
tile20_fixture:
        REPT 19
        DB #99,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00
        ENDR
        DB #66,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00,#00

        include "gfx_core.asm"
