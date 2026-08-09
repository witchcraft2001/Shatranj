; z80 unit test for asm/sprinter/video_s1.asm's draw_grid byte output. In
; z88dk-ticks' flat 64 KiB model PORT_Y row selects are no-ops, so all 168
; grid rows collapse onto one 320-byte span -- which is exactly what makes
; the fill BYTES themselves observable here even though row placement is
; not: every byte of stripe i must be colour i in both nibbles, for the
; full 20-byte stripe width.
;
; Regression: an A-clobbering H|L loop-counter test in the fill loop once
; wrote [colour, #13, #12 ... #01] per stripe instead of 20 colour bytes --
; on MAME that rendered as a thin multicolour "barcode" across the screen
; instead of 16 wide bands (found in the first S1 MAME run).

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; video_s1.asm references HDR (win0_probe) and svmod_safe (mode switch);
; both are defined by resident_s1.asm, not included here. Placeholders
; satisfy the symbol references; neither path runs in this test.
HDR: DS 256,0
svmod_safe: ret

start:
        ld      sp,#e800
        call    t_begin

        ; Sentinel the whole VRAM-window span the grid may touch.
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#03ff
        ld      (hl),#a5
        ldir

        ; buf0, no stripe-0 override: stripe i = colour i in both nibbles.
        ld      de,#c000
        xor     a
        call    draw_grid

        ld      hl,#c000
        ld      c,0             ; expected stripe byte: #00,#11,...,#FF
        ld      e,16            ; stripe count
.stripe:
        ld      b,20
.byte:  ld      a,(hl)
        cp      c
        ld      a,1
        call    t_expect_z
        inc     hl
        djnz    .byte
        ld      a,c
        add     a,#11
        ld      c,a
        dec     e
        jr      nz,.stripe

        ; Nothing past the 320th byte of the buffer may be touched.
        ld      a,(#c140)
        cp      #a5
        ld      a,2
        call    t_expect_z

        ; buf1 with the white marker (A=16 -> stripe 0 forced colour 15);
        ; stripe 1 keeps colour 1, including its last byte.
        ld      de,#c140
        ld      a,16
        call    draw_grid
        ld      a,(#c140)
        cp      #ff
        ld      a,3
        call    t_expect_z
        ld      a,(#c140+19)
        cp      #ff
        ld      a,4
        call    t_expect_z
        ld      a,(#c140+20)
        cp      #11
        ld      a,5
        call    t_expect_z
        ld      a,(#c140+39)
        cp      #11
        ld      a,6
        call    t_expect_z

        call    t_end
        halt

        assert $ < TEST_RESULT

        include "font_hex.asm"
        include "video_s1.asm"
