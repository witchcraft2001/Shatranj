; z80 unit test for video.asm's screen fade -- the scale arithmetic and the
; palette-entry byte layout it feeds.
;
; WHY THIS EXISTS. Every palette write on this port now runs through
; fade_scale (video.asm), including the ones that are not fading: video_init
; at boot, the THEME action, the About screen's own table. So an off-by-one
; in the multiply's shift count does not show up as "the fade looks wrong" --
; it shows up as every colour in the game being wrong, permanently, on a
; screen nobody can read to work out why. The identity case (level = FADE_MAX
; must reproduce the source byte EXACTLY) is the one that has to hold.
;
; z88dk-ticks' flat 64 KiB model has no banking: WIN3_PORT/PORT_Y writes are
; ordinary no-op port I/O, so both palette banks land at their literal
; #C3E0/#C3E4 addresses and are directly readable. That makes the entry
; layout observable here in a way it never is on hardware.
;
; Assembles video.asm from source rather than INCBINning the shipped image:
; there is no fixed load address involved and nothing here depends on where
; the linker put it -- the arithmetic is the subject. t_about_restore.asm is
; the one that runs shipped bytes, for a defect class that needs it.

        device noslot64k
        org 0
        jp start
        include "harness.inc"

; video.asm's fade ramps step once per frame_wait (im2_s1.asm, not part of
; this test). Stubbed as a counter, plus one observation -- what the palette
; held the FIRST time it was called. Assertions 18-20 need both.
frame_wait:
        push    af
        push    hl
        ld      hl,wait_count
        inc     (hl)
        ld      a,(hl)
        dec     a
        jr      nz,.done
        ld      a,(BANK0)
        ld      (first_wait_bank0),a
.done:
        pop     hl
        pop     af
        ret
wait_count:       DB 0
first_wait_bank0: DB 0

BANK0 EQU #C3E0
BANK1 EQU #C3E4

start:
        ld      sp,#E800
        call    t_begin

        ; --- 1..4. IDENTITY. At FADE_MAX every component must come out bit
        ; for bit, in both banks, with the 4th byte zeroed -- this is what
        ; every non-fading palette write in the port relies on.
        ld      a,FADE_MAX
        ld      (fade_level),a
        call    poison_banks
        ld      hl,src_probe
        xor     a                       ; palette entry 0
        call    write_palette_entry

        ld      hl,BANK0
        ld      de,src_probe
        ld      b,1
        call    expect_triple           ; assertions 1 (bank 0)
        ld      hl,BANK1
        ld      de,src_probe
        ld      b,2
        call    expect_triple           ; assertions 2 (bank 1)

        ld      a,(BANK0+3)             ; 4th byte, zeroed per bank
        or      a
        ld      a,3
        call    t_expect_z
        ld      a,(BANK1+3)
        or      a
        ld      a,4
        call    t_expect_z

        ; --- 5. The source pointer is left one past the three bytes read.
        ; palette_refresh walks the whole 16-entry table on that advance
        ; alone; a wrong one silently paints entry N from entry N-1's bytes.
        ; Re-run rather than reuse the HL above -- the checks did their own
        ; pointer walking.
        ld      hl,src_probe
        xor     a
        call    write_palette_entry
        ld      de,src_probe+3
        or      a
        sbc     hl,de
        ld      a,h
        or      l
        ld      a,5
        call    t_expect_z

        ; --- 6..8. HALF BRIGHTNESS. #12/#34/#56 = 18/52/86; at level 8 that
        ; is 9/26/43 = #09/#1A/#2B. Wrong by a factor of two either way and
        ; a fade would either skip its first half or never reach black.
        ld      a,8
        ld      (fade_level),a
        call    poison_banks
        ld      hl,src_probe
        xor     a
        call    write_palette_entry
        ld      a,(BANK0+0)
        cp      #09
        ld      a,6
        call    t_expect_z
        ld      a,(BANK0+1)
        cp      #1A
        ld      a,7
        call    t_expect_z
        ld      a,(BANK0+2)
        cp      #2B
        ld      a,8
        call    t_expect_z

        ; --- 9..11. ONE SIXTEENTH, the dimmest step a fade passes through
        ; before black: 18/52/86 >> 4 = 1/3/5.
        ld      a,1
        ld      (fade_level),a
        call    poison_banks
        ld      hl,src_probe
        xor     a
        call    write_palette_entry
        ld      a,(BANK0+0)
        cp      1
        ld      a,9
        call    t_expect_z
        ld      a,(BANK0+1)
        cp      3
        ld      a,10
        call    t_expect_z
        ld      a,(BANK0+2)
        cp      5
        ld      a,11
        call    t_expect_z

        ; --- 12..14. BLACK. Level 0 must be exactly zero, not "nearly": the
        ; whole point of the blackout is that a screen rebuilt under it is
        ; invisible, and a residual 1/16 of a bright palette is not.
        xor     a
        ld      (fade_level),a
        call    poison_banks
        ld      hl,src_probe
        xor     a
        call    write_palette_entry
        ld      a,(BANK0+0)
        or      a
        ld      a,12
        call    t_expect_z
        ld      a,(BANK0+1)
        or      a
        ld      a,13
        call    t_expect_z
        ld      a,(BANK0+2)
        or      a
        ld      a,14
        call    t_expect_z

        ; --- 15. SATURATION. #FF at full level must stay #FF: the product
        ; 255*16 is the largest this multiply ever forms, and the four left
        ; shifts that divide it are exactly where an overflow would show.
        ld      a,FADE_MAX
        ld      (fade_level),a
        call    poison_banks
        ld      hl,src_white
        xor     a
        call    write_palette_entry
        ld      a,(BANK0+0)
        cp      #FF
        ld      a,15
        call    t_expect_z

        ; --- 16/17. THE WHOLE TABLE. palette_refresh walks all 16 entries of
        ; whatever palette_apply_from last saw. In this flat model every entry
        ; lands at the same literal address, so the LAST one written is what
        ; remains -- entry 15 of a table whose entry i is {i,i,i}. Reading 15
        ; back proves the loop ran the full count AND advanced correctly; a
        ; short walk or a stuck pointer both leave a different number here.
        ld      hl,ramp_table
        call    palette_apply_from
        ld      a,(BANK0+0)
        cp      15
        ld      a,16
        call    t_expect_z
        ld      a,(BANK1+2)
        cp      15
        ld      a,17
        call    t_expect_z

        ; --- 18/19. THE PRE-RAMP FLUSH. A screen rebuilt behind a fade
        ; leaves paint logged in buffers.asm's dirty ring, and whichever
        ; frame_wait clears it pays for flip_sync's 320x256 front->back copy
        ; -- hundreds of milliseconds. That has to be spent BEFORE the first
        ; palette step, where the screen still holds its starting level;
        ; inside the ramp it reads as the fade freezing a couple of steps in
        ; and then resuming (MAME, 2026-08-18). Neither the ring nor the
        ; flip exists in this test, so what is pinned here is the ORDER:
        ; poison the banks, ramp from black, and the first frame_wait must
        ; arrive while the palette is still untouched (18). It must also
        ; cost exactly ONE frame beyond the sixteen steps (19) -- a flush
        ; that ended up inside the loop would spend one per step and show
        ; up here as 32.
        call    poison_banks
        xor     a
        ld      (fade_level),a
        ld      (wait_count),a
        call    fade_in                 ; pal_src is still ramp_table
        ld      a,(first_wait_bank0)
        cp      #A5                     ; poison: nothing written yet
        ld      a,18
        call    t_expect_z
        ld      a,(wait_count)
        cp      FADE_MAX+1
        ld      a,19
        call    t_expect_z

        call    t_end
        halt

; HL -> written triple, DE -> expected triple, B = first assertion id.
; Clobbers everything.
expect_triple:
        ld      c,3
.next:
        ld      a,(de)
        cp      (hl)
        ld      a,b
        call    t_expect_z
        inc     hl
        inc     de
        dec     c
        jr      nz,.next
        ret

; Fills both banks' 8 bytes with a value no expectation below uses, so a
; write that never happens fails instead of passing on a leftover.
poison_banks:
        ld      hl,BANK0
        ld      b,8
.fill:  ld      (hl),#A5
        inc     hl
        djnz    .fill
        ret

src_probe:  DB #12,#34,#56
src_white:  DB #FF,#FF,#FF

; Entry i = {i,i,i}, 16 entries -- see assertions 16/17.
ramp_table:
        DB 0,0,0,      1,1,1,      2,2,2,      3,3,3
        DB 4,4,4,      5,5,5,      6,6,6,      7,7,7
        DB 8,8,8,      9,9,9,      10,10,10,   11,11,11
        DB 12,12,12,   13,13,13,   14,14,14,   15,15,15

        assert  $ < TEST_RESULT

        include "video.asm"
