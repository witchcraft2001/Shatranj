; z80 unit test for asm/sprinter/text640.asm's text_print clipping wrapper.
;
; DEFINEs S2_TEST_FONT_BASE (#8000) so FONT_BASE addresses a synthetic
; fixture poked directly into the flat 64 KiB image instead of a real WIN0
; remap (win0_map_di's OUT is a no-op in z88dk-ticks anyway, same as every
; other Sprinter z80 test -- see gfx_core.asm's tests).
;
; What this test can and cannot see: text_print's per-column render loop
; (.rows_general/.rows_black) reads the font mask into A, then does
; `EXX / LD A,(y_pos) / ... / AND (HL)` -- on real hardware the ACC_COPY_H
; bracket around AND/XOR makes the accelerator substitute its own latched
; mask byte for that operation (the donor's comment: "without this pair
; every glyph becomes a solid bar"); in z88dk-ticks, which has no
; accelerator model, AND (HL) is an ordinary Z80 instruction and so
; genuinely computes y_pos AND foreground_buffer_byte, not the documented
; masking formula. So the composited PIXEL VALUE this loop writes is not
; meaningful here (that is what MAME/hardware verification is for -- same
; footing as accel_smoke). What IS meaningful and fully CPU-driven: the
; clipping wrapper's pre-scan (width-table lookups, the 320-byte row-edge
; stop, the odd-X/Y>248 rejects, the empty-string case) and the render
; loop's per-column DESTINATION ADDRESS stepping (a genuine INC BC, not an
; accelerator side effect). This test therefore checks WHICH byte
; addresses get written (changed from a sentinel) rather than what value
; lands in them.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

        define S2_TEST_FONT_BASE #8000

start:
        ld      sp,#e800
        call    t_begin

        ; --- synthetic font fixture: width table @FONT_BASE, offset
        ; lo/hi @+256/+512. Raster content doesn't matter here (see the
        ; file banner), so it is left zeroed; only the widths and offsets
        ; (which the pre-scan reads to decide what fits) are set.
        ; Char 1: width 1.  Char 2: width 1.  Char 3: width 1.
        ; Char 4: width 3 (a multi-column glyph).
        ld      a,1
        ld      (#8001),a               ; width[1] = 1
        ld      (#8002),a               ; width[2] = 1
        ld      (#8003),a               ; width[3] = 1
        ld      a,3
        ld      (#8004),a               ; width[4] = 3

        ; offset[char] = #0300 + char*#10 (split across the lo/hi tables,
        ; which are not adjacent, so poked separately). Raster bytes at
        ; those offsets are left zero.
        ld      a,low #0300
        ld      (#8101),a
        ld      a,high #0300
        ld      (#8201),a
        ld      a,low #0310
        ld      (#8102),a
        ld      a,high #0310
        ld      (#8202),a
        ld      a,low #0320
        ld      (#8103),a
        ld      a,high #0320
        ld      (#8203),a
        ld      a,low #0330
        ld      (#8104),a
        ld      a,high #0330
        ld      (#8204),a

        ; --- test 1: three single-column characters step the destination
        ; one byte at a time, and nothing past the last one is touched.
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str123
        ld      ix,0
        ld      c,100
        ld      a,(2<<4)|5              ; bg=2, fg=5
        ld      hl,#c000
        call    text_print

        ld      a,(#c000)
        cp      #a5
        ld      a,1
        call    t_expect_nz
        ld      a,(#c001)
        cp      #a5
        ld      a,2
        call    t_expect_nz
        ld      a,(#c002)
        cp      #a5
        ld      a,3
        call    t_expect_nz
        ld      a,(#c003)               ; nothing past the 3 rendered columns
        cp      #a5
        ld      a,4
        call    t_expect_z

        ; --- test 2: black background (bg=0) dispatches down the
        ; text_out_640_rows_black path instead of _general and must still
        ; write its one column (proving the dispatch doesn't accidentally
        ; skip rendering).
        ld      hl,#c100
        ld      de,#c101
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str1
        ld      ix,0
        ld      c,100
        ld      a,(0<<4)|9              ; bg=0, fg=9
        ld      hl,#c100
        call    text_print

        ld      a,(#c100)
        cp      #a5
        ld      a,5
        call    t_expect_nz

        ; --- test 3: a single multi-column character (char 4, width 3)
        ; must touch exactly 3 consecutive destination bytes -- proving
        ; the width-table lookup drives the column count, not a fixed
        ; assumption.
        ld      hl,#c200
        ld      de,#c201
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str4
        ld      ix,0
        ld      c,100
        ld      a,(2<<4)|5
        ld      hl,#c200
        call    text_print

        ld      a,(#c200)
        cp      #a5
        ld      a,6
        call    t_expect_nz
        ld      a,(#c201)
        cp      #a5
        ld      a,7
        call    t_expect_nz
        ld      a,(#c202)
        cp      #a5
        ld      a,8
        call    t_expect_nz
        ld      a,(#c203)               ; nothing past the 3 columns
        cp      #a5
        ld      a,9
        call    t_expect_z

        ; --- test 4: right-edge clip, hitting the boundary exactly. Byte
        ; column 317: char 1 (width 1) fits (317+1=318<=320, scan_col
        ; becomes 318); char 4 (width 3) then lands at exactly
        ; 318+3=321, one byte past the 320-byte row (must be rejected --
        ; a boundary off by one, e.g. comparing against 322 instead of
        ; 321, would wrongly let this exact case through). Only byte 317
        ; is written; byte 318 (where char 4 would start) must stay
        ; sentinel.
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#013f
        ld      (hl),#a5
        ldir

        ld      de,str1_4
        ld      ix,317*2                ; pixel X = byte 317 * 2
        ld      c,100
        ld      a,(2<<4)|5
        ld      hl,#c000
        call    text_print

        ld      a,(#c13d)               ; #c000+317
        cp      #a5
        ld      a,10
        call    t_expect_nz
        ld      a,(#c13e)               ; #c000+318: char 4 must not land here
        cp      #a5
        ld      a,11
        call    t_expect_z

        ; --- test 5: odd X is rejected outright -- nothing drawn.
        ld      hl,#c300
        ld      de,#c301
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str1
        ld      ix,1                    ; odd pixel X
        ld      c,100
        ld      a,(2<<4)|5
        ld      hl,#c300
        call    text_print

        ld      a,(#c300)
        cp      #a5
        ld      a,12
        call    t_expect_z

        ; --- test 6: Y > 248 is rejected outright -- nothing drawn.
        ld      hl,#c400
        ld      de,#c401
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str1
        ld      ix,0
        ld      c,249
        ld      a,(2<<4)|5
        ld      hl,#c400
        call    text_print

        ld      a,(#c400)
        cp      #a5
        ld      a,13
        call    t_expect_z

        ; --- test 7: empty string draws nothing and returns cleanly.
        ld      hl,#c500
        ld      de,#c501
        ld      bc,#001f
        ld      (hl),#a5
        ldir

        ld      de,str_empty
        ld      ix,0
        ld      c,100
        ld      a,(2<<4)|5
        ld      hl,#c500
        call    text_print

        ld      a,(#c500)
        cp      #a5
        ld      a,14
        call    t_expect_z

        call    t_end
        halt

        assert  $ < TEST_RESULT

str123:     DB 1,2,3,0
str1:       DB 1,0
str4:       DB 4,0
str1_4:     DB 1,4,0
str_empty:  DB 0

        include "gfx_core.asm"
        include "text640.asm"
        ; S5-finish plan D11 (buffer flip): text_print now calls
        ; flip_log_rect (buffers.asm) after staging -- needed to assemble
        ; standalone.
        include "buffers.asm"
