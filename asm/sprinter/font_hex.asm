; Minimal 8x8 bitmap font for the S1 stand: hex digits 0-F plus a handful
; of status letters (P/I/R/T/Q/-/space), used by the on-screen tick counter
; (step 5) and hotkey acknowledgements (step 6). Position-independent code
; and data: INCLUDEd once from resident_s1.asm's flexible code area.
;
; Each glyph is 8 rows; row bits 7..2 are 6 pixel flags (bit7=leftmost),
; bits 1..0 are always 0 (a blank spacer column pair). Digit bitmaps were
; generated from a 7-segment model, not hand-transcribed, to avoid pixel
; errors; status letters were hand-authored on the same 6-wide grid.
;
; draw_glyph renders opaque with color1=lit, color0=blank (the palette set
; up by fill_screen_demo/video_s1.asm), via a 64-entry expansion LUT rather
; than per-pixel bit tests: font byte bits 7..2 rotate (via two RRCA, valid
; because bits 1..0 are always 0) into a 6-bit LUT index whose 3 precomputed
; bytes are the VRAM nibbles for that row, generated the same way (see the
; comment above expand_lut).

        IFNDEF SPRINTER_FONT_HEX_INC
        DEFINE SPRINTER_FONT_HEX_INC

GLYPH_0 EQU 0
GLYPH_1 EQU 1
GLYPH_2 EQU 2
GLYPH_3 EQU 3
GLYPH_4 EQU 4
GLYPH_5 EQU 5
GLYPH_6 EQU 6
GLYPH_7 EQU 7
GLYPH_8 EQU 8
GLYPH_9 EQU 9
GLYPH_A EQU 10
GLYPH_B EQU 11
GLYPH_C EQU 12
GLYPH_D EQU 13
GLYPH_E EQU 14
GLYPH_F EQU 15
GLYPH_P EQU 16
GLYPH_I EQU 17
GLYPH_R EQU 18
GLYPH_T EQU 19
GLYPH_Q EQU 20
GLYPH_DASH  EQU 21
GLYPH_SPACE EQU 22
GLYPH_WIDTH EQU 8              ; pixel cell width/height (6 lit cols + 2 blank)

; Destination VRAM buffer base for draw_glyph, and so for draw_hex16/
; draw_rtc too: #C000 for buffer 0, #C140 for buffer 1. Defaults to buffer
; 0 -- the buffer the S1 stand always draws into -- so every S1 call site
; behaves exactly as before; bench_s2.asm retargets it around its own
; buffer flip and restores it afterwards, because a result drawn into the
; buffer that is no longer displayed is simply invisible.
glyph_dest_base: DW #C000

; A=glyph index (GLYPH_*), DE=pixel X (even, 0..639), C=pixel Y (top row,
; 0..247). Draws 8 rows through WIN3 (caller must have it mapped to VRAM
; and hold DI, matching fill_screen_demo/video_s1.asm's convention) into
; the buffer selected by glyph_dest_base. Clobbers AF, BC, DE, HL, IX.
draw_glyph:
        push    bc              ; C is the caller's Y: the pointer math
                                 ; below needs BC (ADD IX,HL is not a legal
                                 ; Z80 opcode), so save it around
        ld      h,0
        ld      l,a
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; HL = index*8
        ld      b,h
        ld      c,l
        ld      ix,font_table
        add     ix,bc
        pop     bc              ; C = Y again

        ld      h,d
        ld      l,e
        srl     h
        rr      l               ; HL = X/2 (byte offset within a VRAM row)
        ld      de,(glyph_dest_base)
        add     hl,de
        ld      (.dest_col),hl

        ld      b,GLYPH_WIDTH
.rowloop:
        push    bc
        ld      a,c
        out     (PORT_Y),a
        ld      a,(ix+0)
        inc     ix
        rrca
        rrca                    ; A = 6-bit LUT index (0..63)
        ld      l,a
        ld      h,0
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,de           ; HL = index*3
        ld      de,expand_lut
        add     hl,de
        ld      d,h
        ld      e,l             ; DE = &expand_lut[index*3]
        ld      hl,(.dest_col)
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        ld      a,(de)
        ld      (hl),a
        pop     bc
        inc     c
        djnz    .rowloop
        ret
.dest_col: DW 0

; Draw a 16-bit value in DE as 4 hex glyphs starting at pixel (X,Y): IX=X
; (even, start column) on entry, C=Y (top row). Cell pitch is GLYPH_WIDTH
; pixels.
;
; draw_glyph clobbers IX internally (its own font-table pointer) and
; advances its own C by GLYPH_WIDTH per row, so neither the running X
; cursor nor Y can be carried in a register across the call: both are
; stashed in memory and reloaded fresh before every glyph.
; Clobbers AF, BC, DE, HL, IX.
draw_hex16:
        push    ix
        pop     hl
        ld      (.x),hl
        ld      a,c
        ld      (.y),a
        ld      (.value),de             ; .digit clobbers DE (and everything
                                         ; else), so the value lives in memory
                                         ; like the cursor, not in a register
        ld      a,(.value+1)
        rrca
        rrca
        rrca
        rrca
        and     #0F
        call    .digit
        ld      a,(.value+1)
        and     #0F
        call    .digit
        ld      a,(.value)
        rrca
        rrca
        rrca
        rrca
        and     #0F
        call    .digit
        ld      a,(.value)
        and     #0F
        call    .digit
        ret
.digit:
        push    af
        ld      hl,(.x)
        ld      d,h
        ld      e,l
        ld      a,(.y)
        ld      c,a
        pop     af
        call    draw_glyph
        ld      hl,(.x)
        ld      bc,GLYPH_WIDTH
        add     hl,bc
        ld      (.x),hl
        ret
.x: DW 0
.y: DB 0
.value: DW 0

; 8 rows per glyph (row 7 always blank); order matches GLYPH_* above.
font_table:
        DB #70,#88,#88,#00,#88,#88,#70,#00     ; 0
        DB #00,#08,#08,#00,#08,#08,#00,#00     ; 1
        DB #70,#08,#08,#70,#80,#80,#70,#00     ; 2
        DB #70,#08,#08,#70,#08,#08,#70,#00     ; 3
        DB #00,#88,#88,#70,#08,#08,#00,#00     ; 4
        DB #70,#80,#80,#70,#08,#08,#70,#00     ; 5
        DB #70,#80,#80,#70,#88,#88,#70,#00     ; 6
        DB #70,#08,#08,#00,#08,#08,#00,#00     ; 7
        DB #70,#88,#88,#70,#88,#88,#70,#00     ; 8
        DB #70,#88,#88,#70,#08,#08,#70,#00     ; 9
        DB #70,#88,#88,#70,#88,#88,#00,#00     ; A
        DB #00,#80,#80,#70,#88,#88,#70,#00     ; B
        DB #70,#80,#80,#00,#80,#80,#70,#00     ; C
        DB #00,#08,#08,#70,#88,#88,#70,#00     ; D
        DB #70,#80,#80,#70,#80,#80,#70,#00     ; E
        DB #70,#80,#80,#70,#80,#80,#00,#00     ; F
        DB #F0,#88,#88,#F0,#80,#80,#80,#00     ; P
        DB #70,#20,#20,#20,#20,#20,#70,#00     ; I
        DB #F0,#88,#88,#F0,#A0,#90,#88,#00     ; R
        DB #F8,#20,#20,#20,#20,#20,#20,#00     ; T
        DB #70,#88,#88,#88,#A8,#90,#68,#00     ; Q
        DB #00,#00,#00,#F8,#00,#00,#00,#00     ; -
        DB #00,#00,#00,#00,#00,#00,#00,#00     ; space

; index (0-63, bit5=pixel0..bit0=pixel5) -> 3 VRAM nibble bytes
; (color1=lit,color0=blank); generated by tools' Python one-liner in the
; commit that added this file, not hand-transcribed.
expand_lut:
        DB #00,#00,#00,#00,#00,#01,#00,#00,#10,#00,#00,#11,#00,#01,#00,#00,#01,#01,#00,#01,#10,#00,#01,#11
        DB #00,#10,#00,#00,#10,#01,#00,#10,#10,#00,#10,#11,#00,#11,#00,#00,#11,#01,#00,#11,#10,#00,#11,#11
        DB #01,#00,#00,#01,#00,#01,#01,#00,#10,#01,#00,#11,#01,#01,#00,#01,#01,#01,#01,#01,#10,#01,#01,#11
        DB #01,#10,#00,#01,#10,#01,#01,#10,#10,#01,#10,#11,#01,#11,#00,#01,#11,#01,#01,#11,#10,#01,#11,#11
        DB #10,#00,#00,#10,#00,#01,#10,#00,#10,#10,#00,#11,#10,#01,#00,#10,#01,#01,#10,#01,#10,#10,#01,#11
        DB #10,#10,#00,#10,#10,#01,#10,#10,#10,#10,#10,#11,#10,#11,#00,#10,#11,#01,#10,#11,#10,#10,#11,#11
        DB #11,#00,#00,#11,#00,#01,#11,#00,#10,#11,#00,#11,#11,#01,#00,#11,#01,#01,#11,#01,#10,#11,#01,#11
        DB #11,#10,#00,#11,#10,#01,#11,#10,#10,#11,#10,#11,#11,#11,#00,#11,#11,#01,#11,#11,#10,#11,#11,#11

        ENDIF
