; z80 unit test for the S9 hint dot's BLIT PARAMETERS, run against the bytes
; that actually ship.
;
; WHY THIS EXISTS. t_hint_marker.asm (next door) pins the hint bitmap
; convention -- which squares light up -- by re-implementing the algorithm.
; It cannot see what render_hint_marker then hands the blitter, and that is
; where this feature kept breaking: across three separate builds the human
; tester photographed a black-and-magenta garbage block instead of a green
; dot on the hinted squares, and three rounds of READING render_core.asm
; failed to find it. Running the shipped cold page under z88dk-ticks and
; reading tile_src_slot back answered it in one shot: the slot was 8, not
; DOT_SLOT 50.
;
; The cause was a fall-through hazard. render_hint_marker loads A=DOT_SLOT
; and jumps to draw_frame_at_sized, which unpacks D/E/H/L into the four
; frame_* cells using A as scratch for every step, then fell into
; draw_frame_at -- whose first instruction is "ld (draw_frame_at_slot),a".
; By then A held the LAST unpacked value (frame_oy = 8), so the blit sourced
; slot 8: font glyph bytes, all index-0/index-15 nibbles. Index 15 is the
; hardware transparency key only as a WHOLE #FF byte -- a mixed 0F/F0 pair
; renders as literal magenta, which is exactly what the screenshots showed.
;
; So: INCBIN build/sprinter/cold_win3_page.bin at its real ORG (#C000) and
; CALL render_hint_marker at the address its own .map reports (via
; tools/gen_sprinter_coldrender_defs.py), with the resident blitter stubbed
; out to a RET so the parameter block can be inspected instead of consumed.
; The code under test is byte-identical to the code in SHATRANJ.EXE.
;
; What this canNOT cover: whether the accelerator/hardware key then paint
; the right pixels (unverifiable outside MAME/hardware, same caveat
; t_draw_tile.asm and accel_smoke carry). It covers the parameter handoff,
; which is where every failure so far has actually lived.

        device  noslot64k
        org     0
        jp      start
        ds      #0100-$,0

        include "harness.inc"
        include "fixed_layout.inc"
        include "platform_test_defs.inc"
        include "coldrender_test_defs.inc"

DOT_SLOT_EXPECT     EQU 50          ; build_sprinter_ui_assets.py's DOT_SLOT
DOT_W_EXPECT        EQU 8           ; 16px / 2 (4bpp), MARKER_W
DOT_ROWS_EXPECT     EQU 8           ; MARKER_H
TEST_ASSET_PAGE     EQU #20         ; any page but #FF (the "none" sentinel)
CAP                 EQU #B800       ; capture buffer, clear of everything

start:
        ld      sp,#7000
        call    t_begin

        ld      a,1
        ld      (_netchesszx_movement_hints),a
        ld      a,TEST_ASSET_PAGE
        ld      (bench_asset_page),a
        ld      hl,#C000
        ld      (back_base),hl
        xor     a
        ld      (_spectrum_gui_board_flipped),a

        ; Only square 27 (row 3, col 3) is a legal target.
        ld      hl,LOWRAM_HINTED_ROWS_ADDR
        ld      b,8
.clear:
        ld      (hl),0
        inc     hl
        djnz    .clear
        ld      a,#10                   ; row 3: col 3 (MSB = col 0)
        ld      (LOWRAM_HINTED_ROWS_ADDR+3),a

        ; The blitter lives in the WIN1 resident, which this harness does
        ; not load; stub it so the parameter block survives for inspection.
        ld      a,#C9                   ; RET
        ld      (gfx_draw_tile),a

        ; Poison the slot cell first: if render_hint_marker never reaches
        ; the store at all, the assertion below must fail rather than pass
        ; on a leftover value that happens to be right.
        ld      a,#5A
        ld      (tile_src_slot),a

        ld      l,27
        call    render_hint_marker

        ld      a,(tile_src_slot)
        ld      (CAP+0),a
        ld      a,(tile_width)
        ld      (CAP+1),a
        ld      a,(tile_rows)
        ld      (CAP+2),a
        ld      a,(tile_stride)
        ld      (CAP+3),a
        ld      a,(tile_src_page)
        ld      (CAP+4),a

        ; --- 1. THE REGRESSION. The source slot must be the dot's, not
        ; whatever the size/offset unpack happened to leave in A.
        ld      a,(CAP+0)
        cp      DOT_SLOT_EXPECT
        ld      a,1
        call    t_expect_z

        ; --- 2. Geometry: 8 bytes x 8 rows, stride = width (the source is
        ; a tightly packed 16x8 marker, not a slice of a wider tile).
        ld      a,(CAP+1)
        cp      DOT_W_EXPECT
        ld      a,2
        call    t_expect_z
        ld      a,(CAP+2)
        cp      DOT_ROWS_EXPECT
        ld      a,3
        call    t_expect_z
        ld      a,(CAP+3)
        cp      DOT_W_EXPECT
        ld      a,4
        call    t_expect_z

        ; --- 3. Source page is the UI asset page, not a stale/sentinel one.
        ld      a,(CAP+4)
        cp      TEST_ASSET_PAGE
        ld      a,5
        call    t_expect_z

        ; --- 4. A square that is NOT hinted must not blit at all: poison
        ; the slot again, call on square 0, and require the poison to
        ; survive untouched.
        ld      a,#5A
        ld      (tile_src_slot),a
        ld      l,0                     ; row 0 col 0 -- mask bit is clear
        call    render_hint_marker
        ld      a,(tile_src_slot)
        cp      #5A
        ld      a,6
        call    t_expect_z

        ; --- 5. Hints globally off must also suppress the blit, even on a
        ; square whose mask bit IS set.
        xor     a
        ld      (_netchesszx_movement_hints),a
        ld      a,#5A
        ld      (tile_src_slot),a
        ld      l,27
        call    render_hint_marker
        ld      a,(tile_src_slot)
        cp      #5A
        ld      a,7
        call    t_expect_z

        ; --- 6. The cursor frame still gets its OWN whole-cell geometry
        ; after a dot has been drawn -- the frame_* cells are shared and
        ; persistent, so a dot must not leave the next frame at 8x8.
        ld      a,1
        ld      (_netchesszx_movement_hints),a
        ld      l,27
        call    render_hint_marker      ; leaves frame_* at the dot's 8/8/8/8
        call    render_cursor_marker
        ld      a,(frame_tw)
        cp      24
        ld      a,8
        call    t_expect_z
        ld      a,(frame_th)
        cp      24
        ld      a,9
        call    t_expect_z
        ld      a,(frame_ox)
        or      a
        ld      a,10
        call    t_expect_z
        ld      a,(frame_oy)
        or      a
        ld      a,11
        call    t_expect_z

        call    t_end
        halt

; The real cold page at its real load address. Padded with "ds", not "org":
; --raw writes a flat file from address 0, and an "org" jump leaves the gap
; UNWRITTEN, so the page would never land at #C000 in the emulated image
; (t_net_frame_blob.asm pads the same way for the same reason).
        ds      #C000-$,0
        incbin  "cold_win3_page.bin"
